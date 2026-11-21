-- Pruebas del escáner propio de la subasta (Scanner.lua, 0.6.0) en el cliente simulado de Forever. Desde la raíz del
-- repositorio: lua5.1 test-lua/test_scanner.lua
-- Core le pasa los eventos de la subasta (§2.1 de SPEC.md) y le da el callback listen(on), que registra o quita
-- REPLICATE_ITEM_LIST_UPDATE en su marco de eventos. Aquí se envuelven los callbacks que Core le pasa a Scanner.Init
-- para apuntar lo que el escáner cuenta (escaneos terminados, resúmenes soltados, líneas del chat).
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local json = require("json")
local realPrint = print
Stub.install()

local DIR = "addon/OroHermandad/"
local KEY = "Forever-Alliance"
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; realPrint("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end

-- Serializa con las claves ordenadas (para buscar nombres en lo guardado).
local function dump(value)
  if type(value) ~= "table" then return type(value) == "string" and string.format("%q", value) or tostring(value) end
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = "[" .. dump(k) .. "]=" .. dump(value[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end

---------------------------------------------------------------------------
-- Sesión: el addon cargado (Core le pasa los eventos al escáner) y lo que el escáner le cuenta a Core
---------------------------------------------------------------------------
local ns, Scanner, History, Spec
local BUMP = 299999 -- objeto no vigilado de la primera fila (Stub.ah.autoBump)
local log = {done = {}, released = {}, states = 0, say = {}}
local windowShown = false

-- El marco de eventos de Core (el que registró ADDON_LOADED).
local function coreFrame()
  for _, f in ipairs(Stub.frames) do if f.__events.ADDON_LOADED then return f end end
end
local shim = setmetatable({}, {__index = function(_, k) return coreFrame()[k] end})

-- Envuelve los callbacks que Core le pasa a Scanner.Init: se apunta lo que pasa y se llama a lo de Core. La ventana
-- del addon, «abierta» o no según windowShown.
local function wrapInit(loaded)
  local init = loaded.Scanner.Init
  loaded.Scanner.Init = function(db, cdb, callbacks)
    local wrapped = {}
    for k, fn in pairs(callbacks) do wrapped[k] = fn end
    wrapped.onScanDone = function(kind, whole, t)
      log.done[#log.done + 1] = {kind = kind, whole = whole, t = t}
      return callbacks.onScanDone(kind, whole, t)
    end
    wrapped.onSummaryRelease = function(summary, record)
      log.released[#log.released + 1] = {summary = summary, record = record}
      return callbacks.onSummaryRelease(summary, record)
    end
    wrapped.onState = function() log.states = log.states + 1; return callbacks.onState() end
    wrapped.say = function(text) log.say[#log.say + 1] = text; return callbacks.say(text) end
    wrapped.windowShown = function() return windowShown end
    return init(db, cdb, wrapped)
  end
end

local function afterLoad()
  Scanner, History, Spec = ns.Scanner, ns.History, ns.Spec
end

-- Sesión nueva (sin nada guardado) o con sv = {db, cdb, hist}.
local function boot(sv)
  Stub.frames, Stub.timers = {}, {}
  for k, v in pairs(Stub.ahOriginals) do C_AuctionHouse[k] = v end
  Stub.ah.refirePending, Stub.ah.pumping, Stub.ah.autoBump = 0, false, BUMP
  _G.OroHermandadDB, _G.OroHermandadCharDB, _G.OroHermandadHist = sv and sv.db, sv and sv.cdb, sv and sv.hist
  ns = Stub.loadAddon(DIR)
  wrapInit(ns)
  log = {done = {}, released = {}, states = 0, say = {}}
  Stub.fire("ADDON_LOADED", "OroHermandad")
  afterLoad()
end

-- /reload: PLAYER_LOGOUT (Core: History.Flush, Relay.Flush, BeforeSave de todo), los SavedVariables copiados (como si
-- se escribieran y leyeran) y el addon otra vez.
local function reload(beforeLoad)
  log = {done = {}, released = {}, states = 0, say = {}}
  ns = Stub.reload(DIR, beforeLoad, wrapInit)
  afterLoad()
end

-- La subasta: filas de cada objeto vigilado y relleno de objetos no vigilados. La primera fila (un objeto no vigilado)
-- cambia con cada escaneo pedido: una subasta de verdad nunca da dos veces la misma respuesta (la huella la descartaría).
local bumpSeq = 0
local function house(spec, filler)
  bumpSeq = bumpSeq + 1000
  local rows = {Stub.row(BUMP, bumpSeq, 100, {band = 2})}
  for _, r in ipairs(spec) do rows[#rows + 1] = Stub.row(r[1], r[2], r[3], r[4]) end
  for i = 1, filler or 50 do rows[#rows + 1] = Stub.row(200000 + i, 1, 100 + i, {band = 2}) end
  Stub.ah.rows = rows
end

-- Hierro (2772): 3 niveles; cobre (2770): uno.
local function standardHouse(extra)
  local spec = {
    {2772, 20, 100, {band = 3}}, {2772, 5, 100, {band = 2}}, {2772, 30, 104, {band = 3}}, {2772, 50, 130, {band = 3}},
    {2770, 40, 30, {band = 3}}, {2770, 10, 31, {band = 2}},
  }
  for _, r in ipairs(extra or {}) do spec[#spec + 1] = r end
  house(spec)
end

local function state() return Scanner.State().state end
local function busy()
  local s = state()
  return s == "queued" or s == "requested" or s == "reading" or s == "other"
end

-- Escaneo completo pedido por el jugador; corre hasta que termina (o falla).
local function scanNow()
  local ok, why = Scanner.Request(true)
  assert(ok, "no se pudo pedir: " .. tostring(why))
  Stub.runUntil(function() return not busy() end, 120)
  Stub.runUntil(function() return History.Pending() == 0 end, 30) -- History escribe por tandas
end

local function points(id, key)
  local m = OroHermandadHist.markets[key or KEY]
  local item = m and m.items[id]
  return item and Spec.DecodePoints(item.p) or {}
end
local function lastPoint(id) local p = points(id); return p[#p] end

-- Primer segundo de un día de Especular más h horas.
local function dayStart(h)
  local d = Spec.DayIndex(math.floor(Stub.now)) + 1
  return Spec.DAY0 + d * 86400 + (h or 0) * 3600
end
local function setNow(t) Stub.now = t end

boot()

---------------------------------------------------------------------------
-- 1. Casa de subastas (regla por regla)
---------------------------------------------------------------------------
test("Casa: regla 1 (subastador de tu facción) apunta la zona y las referencias de depósito", function()
  Stub.mapID = 1519 -- un micro mapa dentro de la zona 1453 (Ventormenta)
  Stub.openAH({npcFaction = "Alliance", npcGUID = "Creature-0-4170-0-12-8719-00002A1B2C"})
  eq(Scanner.House(), "faction")
  local info = Scanner.HouseInfo()
  eq(info.rule, 1); eq(info.npcID, 8719); eq(info.zone, 1453, "la zona es el primer mapa de tipo zona"); eq(info.map, 1519)
  eq(OroHermandadDB.scanner.houseZones[1453], true, "zona apuntada")
  local refs = OroHermandadDB.scanner.depRef[KEY]
  assert(refs and refs:match("^2589:%d+,2592:%d+,2770:%d+,2771:%d+,2772:%d+$"), "referencias: " .. tostring(refs))
  eq(state(), "ready")
  eq(Scanner.StateText(), "Escaneo de la subasta: listo (unos segundos).")
  Stub.closeAH()
  eq(Scanner.House(), nil, "cerrada")
end)

test("Casa: neutral por zona goblin, por el depósito (x5), dudosa (x2) y las reglas 4, 5 y 6", function()
  -- Tanaris: un micro mapa (9001) dentro de la zona 1446.
  Stub.mapID = 9001
  Stub.openAH({npcFaction = false})
  eq(Scanner.House(), "neutral"); eq(Scanner.HouseInfo().rule, 2)
  eq(Scanner.StateText(), "Subasta neutral (goblin): es otro mercado y sus precios no se guardan.")
  Stub.closeAH()
  Stub.openAH({npcFaction = "Neutral", mapID = 1453})
  eq(Scanner.House(), "neutral", "npc Neutral"); Stub.closeAH()
  -- Sin facción del subastador en otra zona: el depósito decide.
  Stub.openAH({npcFaction = false, mapID = 2001, depositFactor = 5})
  eq(Scanner.House(), "neutral"); eq(Scanner.HouseInfo().rule, 3)
  assert(Scanner.HouseInfo().ratio >= 4.9, "x5"); Stub.closeAH()
  Stub.openAH({npcFaction = false, mapID = 2001, depositFactor = 1})
  eq(Scanner.House(), "faction"); eq(Scanner.HouseInfo().rule, 3); eq(Scanner.HouseInfo().guess, true); Stub.closeAH()
  -- x2 no decide: en una zona donde ya valió la regla 1, la tuya (regla 4); en otra, no se sabe (regla 6).
  Stub.openAH({npcFaction = false, mapID = 1519, depositFactor = 2})
  eq(Scanner.House(), "faction"); eq(Scanner.HouseInfo().rule, 4); Stub.closeAH()
  Stub.openAH({npcFaction = false, mapID = 2001, depositFactor = 2})
  eq(Scanner.House(), "unknown"); eq(Scanner.HouseInfo().rule, 6)
  eq(state(), "unknown")
  assert(has(Scanner.StateText(), "No sé si esta es la subasta de tu facción o la neutral (goblin)"), Scanner.StateText())
  -- Ni petición propia, ni respuesta de otro addon, ni grabado, ni caché de precios.
  standardHouse()
  local ok, why = Scanner.Request(true)
  eq(ok, false); eq(why, "unknown")
  eq(Scanner.Command(""), "no sé si esta es la subasta de tu facción: aquí no se guardan precios.")
  local calls = #Stub.ah.calls
  C_AuctionHouse.ReplicateItems() -- Auctionator u otro addon
  eq(#Stub.ah.calls, calls + 1)
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, nil, "no se escucha la respuesta")
  Stub.advance(10)
  eq(#log.done, 0, "nada leído"); eq(OroHermandadDB.scanPrices[KEY], nil, "sin caché")
  eq(Scanner.StartSweep(), false, "ni la lista")
  Stub.closeAH()
  Stub.depositFactor = 1
  Stub.ah.lastSuccess = nil
end)

test("Casa: en una cuenta nueva sin referencias, la tuya (regla 5, como la 0.5.1)", function()
  local db = OroHermandadDB
  local saved = {zones = db.scanner.houseZones, refs = db.scanner.depRef}
  db.scanner.houseZones, db.scanner.depRef = {}, {}
  Stub.openAH({npcFaction = false, mapID = 2001})
  eq(Scanner.House(), "faction"); eq(Scanner.HouseInfo().rule, 5); eq(Scanner.HouseInfo().guess, true)
  Stub.closeAH()
  db.scanner.houseZones, db.scanner.depRef = saved.zones, saved.refs
  Stub.mapID = 1453
end)

---------------------------------------------------------------------------
-- 2. La ventana de la respuesta (R1): gancho, huella, una sola lectura
---------------------------------------------------------------------------
test("Petición propia: la respuesta se escucha solo en su ventana, se lee una vez aunque sigan los avisos de la caché", function()
  setNow(dayStart(1))
  standardHouse({{2772, 3, 99, {band = 3, uncached = true}}, {3858, 7, 400, {uncached = true}}})
  for i = 1, 200 do Stub.ah.rows[#Stub.ah.rows + 1] = Stub.row(210000 + i, 1, 50, {uncached = true}) end
  Stub.openAH()
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, nil, "fuera de ventana: sin escuchar")
  local before = Stub.now
  local ok, why = Scanner.Request(true)
  assert(ok, why); eq(why, "queued", "espera los 2 s tras abrir")
  Stub.runUntil(function() return state() == "requested" end, 5)
  eq(state(), "requested"); eq(Scanner.StateText(), "Pidiendo la subasta entera…")
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, true, "en ventana: escuchando")
  local reqT = OroHermandadDB.scanner.lastOwnRequest
  assert(reqT and reqT >= before + 2, "petición a los 2 s de abrir")
  Stub.runUntil(function() return not busy() end, 60)
  eq(#log.done, 1, "una lectura"); eq(log.done[1].kind, "full")
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, nil, "tras aceptar la respuesta ya no se escucha")
  assert(Stub.ah.refired > 0, "hubo avisos de la caché de objetos")
  Stub.strayReplicateEvents(500)
  Stub.advance(30)
  eq(#log.done, 1, "los avisos de después no leen otra vez")
  eq(OroHermandadDB.scanner.lastSuccess, reqT, "lastSuccess = hora de la PETICIÓN")
  eq(state(), "done")
  local p = lastPoint(2772)
  eq(p.lo, 99); eq(p.qty, 108); eq(p.qty5, 28, "3 a 99 y 20 + 5 a 100 (104 pasa del 5 %)")
  assert(has(Scanner.StateText(), "guardado: 3 objetos vigilados a la venta."), Scanner.StateText())
  -- La siguiente, exactamente 905 s después de la petición.
  Stub.runUntil(function() return Stub.now >= reqT + 904 end, 1000)
  setNow(reqT + 904)
  local ok2, why2 = Scanner.Request(true)
  eq(ok2, false); eq(why2, "throttle")
  assert(Scanner.Command(""):match("^la subasta deja un escaneo completo cada 15 min por cuenta: el siguiente, a las %d%d:%d%d%.$"))
  setNow(reqT + 905)
  eq(Scanner.Request(true), true, "a los 905 s")
  Stub.runUntil(function() return not busy() end, 60)
  eq(#log.done, 2)
  Stub.closeAH()
end)

test("Respuesta rechazada en silencio: los avisos sueltos tienen la huella de la última; a los 60 s, sin respuesta", function()
  Stub.advance(1000)
  Stub.openAH()
  Stub.advance(3)
  local fp = OroHermandadDB.scanner.fp
  local before = dump(OroHermandadHist)
  Stub.ah.refuseAll = true
  assert(Scanner.Request(true))
  Stub.advance(5)
  eq(state(), "requested")
  local stray = Scanner.Internals().stats.strayRejected
  Stub.strayReplicateEvents(40)
  Stub.advance(2)
  eq(Scanner.Internals().stats.strayRejected, stray + 1, "misma huella: rechazada")
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, true, "se sigue esperando")
  Stub.strayReplicateEvents(3)
  Stub.advance(60)
  eq(state(), "timeout")
  assert(has(Scanner.StateText(), "La subasta no ha respondido (quizá otro addon escaneó hace menos de 15 min)"), Scanner.StateText())
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, nil)
  eq(dump(OroHermandadHist), before, "nada grabado"); eq(OroHermandadDB.scanner.fp, fp)
  -- Una respuesta vacía (n = 0) tampoco cuenta: se espera.
  Stub.ah.refuseAll = false
  local rows = Stub.ah.rows
  Stub.ah.rows = {}
  Stub.advance(905)
  assert(Scanner.Request(true))
  Stub.advance(10)
  eq(state(), "requested", "n = 0: sigue esperando")
  Stub.advance(60)
  eq(state(), "timeout")
  Stub.ah.rows = rows
  Stub.closeAH()
end)

test("Tres sin respuesta: «no responde» hasta el /reload; un DROPPED reenvía una vez; el botón sigue valiendo", function()
  Stub.advance(1000)
  Stub.openAH()
  Stub.advance(3)
  Stub.ah.refuseAll = true
  assert(Scanner.Request(true)); Stub.advance(65)
  eq(state(), "noresponse", "tercera seguida")
  eq(Scanner.StateText(), "La subasta no responde al escaneo completo. Prueba «Escanear la lista» (2-3 min).")
  eq(Scanner.OfferSweep(), true)
  Stub.ah.refuseAll = false
  -- Un DROPPED en los 5 s siguientes a nuestra petición: se pide otra vez cuando la subasta está lista.
  Stub.advance(905)
  Stub.ah.ready = false
  local calls = #Stub.ah.calls
  assert(Scanner.Request(true))
  Stub.advance(1)
  eq(#Stub.ah.calls, calls, "espera a que la subasta esté lista")
  eq(state(), "queued"); eq(Scanner.StateText(), "Esperando a la subasta…")
  Stub.ah.ready = true
  Stub.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  eq(#Stub.ah.calls, calls + 1, "sale en cuanto está lista")
  Stub.ah.ready = false
  Stub.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  Stub.advance(1)
  Stub.ah.ready = true
  Stub.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  eq(#Stub.ah.calls, calls + 2, "un reenvío")
  Stub.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  Stub.advance(1)
  eq(#Stub.ah.calls, calls + 2, "solo uno")
  Stub.runUntil(function() return not busy() end, 70)
  Stub.closeAH()
  -- Tras un /reload se vuelve a intentar solo.
  reload()
  Stub.advance(1000)
  Stub.openAH()
  eq(Scanner.Internals().noresponse, false)
  Stub.closeAH()
end)

test("Otro addon pide la subasta (Auctionator): se lee su respuesta por el gancho, una vez; una copia guardada antes no se ve", function()
  Stub.advance(1000)
  Stub.openAH()
  Stub.advance(3)
  local done = #log.done
  -- Auctionator llama a C_AuctionHouse.ReplicateItems() al empezar su escaneo completo.
  C_AuctionHouse.ReplicateItems()
  eq(state(), "other"); eq(Scanner.StateText(), "Otro addon ha pedido la subasta entera: se usa su respuesta.")
  eq(Scanner.Command(""), "otro addon acaba de pedir la subasta entera: se usará su respuesta.")
  Stub.runUntil(function() return not busy() end, 60)
  eq(#log.done, done + 1, "leída una vez")
  -- Y Auctionator la lee también: sus llamadas avisan otra vez de la caché, pero no hay una segunda lectura.
  for i = 0, C_AuctionHouse.GetNumReplicateItems() - 1 do C_AuctionHouse.GetReplicateItemInfo(i) end
  Stub.advance(30)
  eq(#log.done, done + 1)
  eq(OroHermandadDB.scanner.lastSuccess, OroHermandadDB.scanner.lastAnyRequest, "su petición abre el turno de 15 min")
  -- Una copia de la función guardada antes del gancho: no se ve (límite documentado).
  Stub.advance(1000)
  local any = OroHermandadDB.scanner.lastAnyRequest
  Stub.ahOriginals.ReplicateItems()
  eq(OroHermandadDB.scanner.lastAnyRequest, any, "no se ve")
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, nil)
  Stub.advance(10)
  eq(#log.done, done + 1)
  Stub.closeAH()
end)

test("Auctionator pide la subasta entera al mostrar su marco, antes de nuestro AUCTION_HOUSE_SHOW: se lee y se graba", function()
  boot()
  setNow(dayStart(1))
  Stub.autoscan, Stub.replicateScan = true, true
  standardHouse()
  local s = OroHermandadDB.scanner
  local calls = #Stub.ah.calls
  -- Auctionator: AuctionatorAHFrameMixin:OnShow -> InitiateScan -> C_AuctionHouse.ReplicateItems(), y después el evento.
  Stub.openAH({onShow = function() C_AuctionHouse.ReplicateItems() end})
  eq(#Stub.ah.calls, calls + 1); eq(Stub.ah.calls[#Stub.ah.calls].accepted, true)
  assert(s.lastAnyRequest, "la petición se ve")
  eq(state(), "other", "se escucha su respuesta"); eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, true)
  Stub.runUntil(function() return not busy() end, 60)
  Stub.runUntil(function() return History.Pending() == 0 end, 30)
  eq(#log.done, 1, "leída una vez"); eq(s.lastSuccess, s.lastAnyRequest, "su petición abre el turno de 15 min")
  eq(state(), "done"); eq(s.recorded[KEY], log.done[1].t, "grabado")
  eq(#points(2772), 1); eq(lastPoint(2772).lo, 100)
  -- Su aviso de escaneo completo (EventBus) no graba otra vez.
  Stub.scanComplete("full")
  Stub.runUntil(function() return History.Pending() == 0 end, 30)
  eq(#points(2772), 1)
  Stub.closeAH()
  -- Una petición con la subasta cerrada de hace más de 5 s no abre nada; en la neutral, tampoco.
  Stub.advance(1000)
  C_AuctionHouse.ReplicateItems()
  Stub.advance(6)
  Stub.openAH()
  eq(Scanner.Internals().windowOpen, false); eq(state(), "auctionator")
  Stub.closeAH()
  Stub.advance(1000)
  Stub.openAH({npcFaction = "Neutral", onShow = function() C_AuctionHouse.ReplicateItems() end})
  eq(Scanner.Internals().windowOpen, false); eq(state(), "neutral")
  eq(shim.__events.REPLICATE_ITEM_LIST_UPDATE, nil)
  Stub.advance(10)
  eq(#log.done, 1)
  Stub.closeAH()
  eq(Scanner.Internals().early, nil)
  Stub.autoscan, Stub.replicateScan = false, false
end)

test("La lista crece durante la lectura: la huella pasa a ser la de la lista entera (la misma foto no se lee dos veces)", function()
  boot()
  setNow(dayStart(1) + 7200)
  standardHouse()
  local full
  Stub.ah.onRowRead = function(i)
    if full and i == 10 and #Stub.ah.list < #full then
      for k = #Stub.ah.list + 1, #full do Stub.ah.list[k] = full[k] end
    end
  end
  Stub.openAH(); Stub.advance(3)
  local s = OroHermandadDB.scanner
  local answers = Stub.ah.answers or 0
  assert(Scanner.Request(true))
  -- La respuesta llega con 40 filas; el resto aparece mientras se lee (§2.6).
  Stub.runUntil(function() return (Stub.ah.answers or 0) > answers end, 10)
  full = {}
  for k, r in ipairs(Stub.ah.list) do full[k] = r end
  while #Stub.ah.list > 40 do table.remove(Stub.ah.list) end
  Stub.runUntil(function() return not busy() end, 60)
  Stub.runUntil(function() return History.Pending() == 0 end, 30)
  Stub.ah.onRowRead = nil
  eq(#log.done, 1); eq(Scanner.Internals().stats.lastRead.n, #full, "leída entera")
  eq(s.fp, Scanner.Fingerprint(#full), "huella de la lista entera")
  local success, baseT = s.lastSuccess, OroHermandadCharDB.scanBase[KEY].t
  -- 10 min después otro addon pide (el servidor no responde) y llegan avisos sueltos a su ventana: no es nuevo.
  Stub.advance(600)
  local stray = Scanner.Internals().stats.strayRejected
  C_AuctionHouse.ReplicateItems()
  eq(Stub.ah.calls[#Stub.ah.calls].accepted, false)
  Stub.strayReplicateEvents(3)
  Stub.advance(70)
  eq(#log.done, 1, "no se lee otra vez"); eq(Scanner.Internals().stats.strayRejected, stray + 1)
  eq(s.lastSuccess, success, "el turno de 15 min no se mueve"); eq(OroHermandadCharDB.scanBase[KEY].t, baseT, "ni la referencia")
  Stub.closeAH()
end)

test("Por respuesta: un solo temporizador y nada de memoria por aviso (20 000 avisos)", function()
  Stub.advance(1000)
  Stub.openAH()
  Stub.advance(3)
  Stub.ah.answerDelay = 30
  assert(Scanner.Request(true))
  Stub.advance(1)
  eq(state(), "requested")
  local timers = Stub.timerCalls
  collectgarbage("collect"); collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, 20000 do Scanner.OnReplicate() end
  local grown = collectgarbage("count") - before
  collectgarbage("restart")
  eq(Stub.timerCalls, timers + 1, "un temporizador")
  assert(grown < 2, string.format("memoria por los avisos: %.2f KB", grown))
  Stub.ah.answerDelay = 2
  Stub.runUntil(function() return not busy() end, 90)
  Stub.closeAH()
end)

test("Huella: FNV-1a (el de Relay) del texto «n,itemID,count,buyout,...» de 32 filas repartidas", function()
  for _, text in ipairs({"", "a", "abc", "Oro de Hermandad", ("x"):rep(300)}) do eq(Scanner.Fnv1a32(text), ns.Relay.Fnv1a32(text), text) end
  local list = {}
  for i = 1, 100 do list[i] = Stub.row(1000 + i, i, 50 + i, {band = 2}) end
  Stub.ah.list = list
  local parts = {"100"}
  for k = 0, 31 do
    local r = list[math.floor(k * 100 / 32) + 1]
    parts[#parts + 1] = tostring(r.id); parts[#parts + 1] = tostring(r.count); parts[#parts + 1] = tostring(r.buyout)
  end
  eq(Scanner.Fingerprint(100), ns.Relay.Fnv1a32(table.concat(parts, ",")))
  assert(Scanner.Fingerprint(100):match("^%x%x%x%x%x%x%x%x$"))
  list[1].count = list[1].count + 1
  assert(Scanner.Fingerprint(100) ~= ns.Relay.Fnv1a32(table.concat(parts, ",")), "otra respuesta, otra huella")
  Stub.ah.list = {}
end)

---------------------------------------------------------------------------
-- 3. Lectura por tandas (presupuesto de 1,5 ms)
---------------------------------------------------------------------------
test("150 000 filas: tandas de 1,5 ms como mucho (+ 63 filas), al menos n/500; sin debugprofilestop, 256 filas; sin tablas por fila", function()
  local rows = {Stub.row(BUMP, 1, 100, {band = 2})}
  for i = 1, 150000 do rows[#rows + 1] = Stub.row(220000 + i % 5000, 1 + i % 3, 100 + i % 700, {band = i % 4}) end
  for i = 1, 30 do rows[#rows + 1] = Stub.row(2772, 10, 120 + i, {band = 3}) end
  Stub.ah.rows = rows
  Stub.advance(1000)
  Stub.fakeProfile(3)
  Stub.openAH()
  Stub.advance(3)
  assert(Scanner.Request(true))
  Stub.runUntil(function() return state() == "reading" end, 10)
  collectgarbage("collect"); collectgarbage("stop")
  local before = collectgarbage("count")
  Stub.runUntil(function() return not busy() end, 600)
  local grown = collectgarbage("count") - before
  collectgarbage("restart")
  local r = Scanner.Internals().stats.lastRead
  eq(r.rows, 150031)
  assert(r.maxMs <= 1.5 + 63 * 0.003 + 1e-9, string.format("tanda más larga %.3f ms", r.maxMs))
  assert(r.frames >= 150031 / 500, "tandas: " .. r.frames)
  -- La memoria que crece es la de los objetos vistos (un mínimo por objeto) y los vigilados, nunca una tabla por fila.
  assert(grown < 1500, string.format("memoria durante la lectura: %.0f KB", grown))
  realPrint(string.format("  150 000 filas: %d tandas, la más larga %.3f ms (falsos), %.0f KB", r.frames, r.maxMs, grown))
  Stub.fakeProfile(nil)
  Stub.advance(1000)
  assert(Scanner.Request(true))
  Stub.runUntil(function() return not busy() end, 600)
  r = Scanner.Internals().stats.lastRead
  eq(r.frames, math.ceil(150031 / 256), "256 filas por tanda sin debugprofilestop")
  -- La lista crece mientras se lee: se sigue hasta el final nuevo.
  standardHouse()
  local grown = false
  Stub.ah.onRowRead = function(i)
    -- Ya leyendo (no en la huella, que mira 32 filas antes): la lista crece 100 filas.
    if i == 40 and Scanner.State().state == "reading" and not grown then
      grown = true
      for k = 1, 100 do Stub.ah.list[#Stub.ah.list + 1] = Stub.row(2589, 1, 12, {band = 3}) end
    end
  end
  Stub.advance(1000)
  assert(Scanner.Request(true))
  Stub.runUntil(function() return not busy() end, 60)
  Stub.runUntil(function() return History.Pending() == 0 end, 30)
  Stub.ah.onRowRead = nil
  r = Scanner.Internals().stats.lastRead
  eq(r.rows, #Stub.ah.rows + 100, "las 100 filas nuevas también")
  eq(Scanner.OwnPrice(2589), 12, "y su precio")
  Stub.closeAH()
end)

---------------------------------------------------------------------------
-- 4. Filtro de grabado (D5) y buzón de la hermandad
---------------------------------------------------------------------------
test("Filtro: escaneos a los 0, 15 y 30 min graban el primero y el último; el 9.º del día solo refresca", function()
  setNow(dayStart(1))
  standardHouse()
  Stub.openAH()
  Stub.advance(3)
  local outbox = #OroHermandadCharDB.relay.out
  local t0 = Stub.now
  scanNow()
  eq(state(), "done")
  local first = lastPoint(2772).t
  eq(Scanner.RecordedToday(KEY), 1)
  setNow(t0 + 910)
  scanNow()
  eq(state(), "done-refresh")
  assert(has(Scanner.StateText(), "precios al día (el de las "), Scanner.StateText())
  eq(lastPoint(2772).t, first, "a los 15 min no se graba")
  setNow(t0 + 1820)
  scanNow()
  eq(state(), "done")
  eq(Scanner.RecordedToday(KEY), 2)
  assert(lastPoint(2772).t > first, "a los 30 min sí")
  for k = 3, 9 do
    setNow(t0 + k * 1900)
    scanNow()
    Stub.advance(5)
  end
  eq(Scanner.RecordedToday(KEY), 8, "8 al día")
  eq(state(), "done-refresh", "el 9.º solo refresca")
  eq(#OroHermandadCharDB.relay.out - outbox, 8, "8 en el buzón de la hermandad")
  Stub.closeAH()
end)

---------------------------------------------------------------------------
-- 5. Ventas estimadas entre dos escaneos del mismo personaje
---------------------------------------------------------------------------
test("Niveles de la referencia: «149:3200,220;150:310», y el corte de 40 niveles y 200 subastas", function()
  local levels = Scanner.DecodeLevels("149:3200,220;150:310")
  eq(dump(levels), dump({{149, {{3, 200}, {2, 20}}}, {150, {{3, 10}}}}))
  eq((Scanner.EncodeLevels(levels)), "149:3200,220;150:310")
  local many = {}
  for p = 1, 50 do many[p] = {100 + p, {{3, 1}, {2, 2}}} end
  local text, n = Scanner.EncodeLevels(many)
  eq(#Scanner.DecodeLevels(text), 40, "40 niveles"); eq(n, 80)
  local big = {}
  for p = 1, 10 do
    local list = {}
    for k = 1, 30 do list[k] = {3, k} end
    big[p] = {100 + p, list}
  end
  local text2, n2 = Scanner.EncodeLevels(big)
  eq(#Scanner.DecodeLevels(text2), 6, "un nivel que pasaría de 200 subastas se queda fuera con los de encima"); eq(n2, 180)
  local huge = {}
  for k = 1, 201 do huge[k] = {3, 1} end
  eq((Scanner.EncodeLevels({{100, huge}})), "", "si es el primero, sin referencia")
  for _, bad in ipairs({"", "x", "100:", "100:4,1", "100:31;99:31", "0:31", "100:3"}) do eq(Scanner.DecodeLevels(bad), nil, bad) end
end)

test("Ventas: referencia guardada tras /reload, dt 2700, compras propias descontadas, dt 8000 nada", function()
  setNow(dayStart(1))
  Stub.advance(10)
  -- Hierro: 2 niveles. A los 45 min: el primero desapareció (tramo largo: no pudo caducar), el segundo, comprado en parte.
  house({{2772, 20, 100, {band = 2}}, {2772, 30, 105, {band = 2}}, {2772, 50, 110, {band = 2}}, {2770, 40, 30, {band = 3}}})
  Stub.openAH()
  Stub.advance(3)
  scanNow()
  eq(state(), "done")
  local base = OroHermandadCharDB.scanBase[KEY]
  eq(base.items[2772], "100:220;105:230;110:250")
  eq(base.off, 1, "tramos 1..4 en este cliente")
  Stub.closeAH()
  reload()
  eq(OroHermandadCharDB.scanBase[KEY].items[2772], "100:220;105:230;110:250", "sigue tras el /reload")
  Stub.advance(2000)
  -- Compraste 12 unidades de hierro entre los dos escaneos.
  Stub.fire("COMMODITY_PURCHASED", 2772, 12)
  house({{2772, 25, 105, {band = 2}}, {2772, 50, 110, {band = 2}}, {2770, 40, 30, {band = 3}}})
  Stub.advance(700)
  Stub.openAH()
  Stub.advance(3)
  local t0 = OroHermandadCharDB.scanBase[KEY].t
  scanNow()
  eq(state(), "done")
  local p = lastPoint(2772)
  local dt = p.t - t0
  assert(dt >= 2700 and dt <= 2800, "dt " .. dt)
  eq(p.dt, dt); eq(p.sold, 20 + 5 - 12, "20 desaparecidas + 5 compradas de 30 - tus 12")
  eq(lastPoint(2770).sold, 0, "el cobre no se movió")
  assert(has(Scanner.StateText(), "Ventas medidas desde las "), Scanner.StateText())
  local s = Scanner.Internals().stats.lastSamples
  eq(s.own, 12); eq(s.partial, 5)
  Stub.closeAH()
  -- dt de más de 2 h: sin ventas.
  Stub.advance(8000)
  Stub.openAH(); Stub.advance(3)
  scanNow()
  eq(state(), "done"); eq(lastPoint(2772).dt, nil, "dt 8000: sin venta")
  Stub.closeAH()
end)

test("Ventas: un escaneo que solo refresca mueve la referencia y el siguiente grabado lleva dt = 1200", function()
  Stub.advance(4000)
  standardHouse()
  Stub.openAH(); Stub.advance(3)
  scanNow(); eq(state(), "done")
  local recorded = OroHermandadCharDB.scanBase[KEY].t
  Stub.advance(1200)
  scanNow(); eq(state(), "done-refresh")
  local refresh = OroHermandadCharDB.scanBase[KEY].t
  assert(refresh > recorded, "la referencia se movió")
  -- La respuesta llega 2 s después de pedir: la hora del escaneo es la de su primer aviso.
  setNow(refresh + 1198)
  scanNow(); eq(state(), "done")
  eq(lastPoint(2772).t, refresh + 1200)
  eq(lastPoint(2772).dt, 1200, "dt desde el que solo refrescó")
  Stub.closeAH()
end)

test("Tramos: 0..3 o 1..4 según el cliente; sin saberlo, sin ventas", function()
  -- Cuenta nueva: el cliente da 0..3 (algún 0).
  boot()
  Stub.ah.bandBase = 0
  standardHouse({{2770, 1, 33, {band = 0}}})
  setNow(dayStart(2))
  Stub.openAH(); Stub.advance(3)
  scanNow()
  eq(OroHermandadDB.scanner.bandOffset, 0, "un 0 lo demuestra")
  eq(OroHermandadCharDB.scanBase[KEY].off, 0)
  Stub.closeAH()
  -- Otra cuenta nueva con solo 1..3 (ningún 0 ni 4): desfase desconocido, la referencia no sirve para ventas.
  boot()
  Stub.ah.bandBase = 1
  house({{2772, 20, 100, {band = 1}}, {2772, 30, 105, {band = 1}}})
  setNow(dayStart(2) + 7200)
  Stub.openAH(); Stub.advance(3)
  scanNow()
  eq(OroHermandadDB.scanner.bandOffset, nil); eq(OroHermandadCharDB.scanBase[KEY].off, nil)
  house({{2772, 30, 105, {band = 1}}})
  Stub.advance(2700)
  scanNow()
  eq(state(), "done"); eq(lastPoint(2772).dt, nil, "sin desfase conocido: sin ventas")
  Stub.closeAH()
end)

test("Por personaje: las subastas de tu alter son ajenas para el principal y al revés; nunca se cruzan referencias", function()
  boot()
  local chars, current = {}, "Javi"
  local function switch(name)
    Stub.fire("PLAYER_LOGOUT")
    chars[current] = Stub.deepCopy(OroHermandadCharDB)
    reload(function()
      _G.OroHermandadCharDB = chars[name]
      _G.UnitName = function() return name end
    end)
    current = name
  end
  setNow(dayStart(3))
  -- El alter (Alto) tiene 15 de hierro a 100: para Javi son ajenas.
  house({{2772, 20, 100, {band = 3}}, {2772, 15, 100, {band = 3, owner = "Alto"}}, {2772, 30, 106, {band = 3}},
         {2772, 4, 98, {band = 3, owner = "Javi"}}})
  Stub.openAH(); Stub.advance(3)
  scanNow()
  local T = OroHermandadCharDB.scanBase[KEY].t
  eq(OroHermandadCharDB.scanBase[KEY].items[2772], "100:320,315;106:330", "las de Alto cuentan, las tuyas (98) no")
  eq(OroHermandadCharDB.scanner.ownSeen, "yes")
  Stub.closeAH()
  -- Alto escanea 40 min después: sus subastas ya no cuentan (son suyas) y no tiene referencia: sin ventas.
  switch("Alto")
  setNow(T + 2400)
  Stub.openAH(); Stub.advance(3)
  scanNow()
  eq(state(), "done")
  eq(lastPoint(2772).dt, nil, "sin referencia del alter: sin ventas")
  eq(OroHermandadCharDB.scanBase[KEY].items[2772], "98:34;100:320;106:330", "su referencia, sin sus 15")
  Stub.closeAH()
  -- Javi a los 80 min: compara con SU escaneo de T (las 15 de Alto siguen ahí: no son ventas).
  switch("Javi")
  eq(OroHermandadCharDB.scanBase[KEY].t, T, "la referencia de Javi no se tocó")
  setNow(T + 4800)
  house({{2772, 12, 100, {band = 3}}, {2772, 15, 100, {band = 3, owner = "Alto"}}, {2772, 30, 106, {band = 3}},
         {2772, 4, 98, {band = 3, owner = "Javi"}}})
  Stub.openAH(); Stub.advance(3)
  scanNow()
  local p = lastPoint(2772)
  eq(p.dt, p.t - T); eq(p.sold, 8, "8 compradas de las 20; las 15 de Alto no se movieron")
  Stub.closeAH()
  -- Javi tiene subastas seguidas pero dos escaneos seguidos no ven ninguna suya: no se miden ventas (ownSeen = "no").
  -- Con uno solo, todavía sí (pudo venderse justo antes).
  OroHermandadCharDB.auctions[555] = table.concat({2772, 101, 5, 3, math.floor(Stub.now), KEY, "c"}, ",")
  house({{2772, 12, 100, {band = 3}}, {2772, 30, 106, {band = 3}}})
  Stub.advance(1900)
  Stub.openAH(); Stub.advance(3)
  scanNow()
  eq(OroHermandadCharDB.scanner.ownSeen, "yes", "un escaneo sin las tuyas no basta"); eq(OroHermandadCharDB.scanner.ownMiss, 1)
  assert(lastPoint(2772).dt, "con ventas")
  Stub.advance(1900)
  scanNow()
  eq(OroHermandadCharDB.scanner.ownSeen, "no"); eq(lastPoint(2772).dt, nil, "sin ventas")
  local probe = table.concat(Scanner.ProbeLines(), "\n")
  assert(has(probe, "Tus subastas no se reconocen en el escaneo: no se miden ventas en este personaje."), probe)
  -- Un escaneo posterior que sí ve las tuyas lo arregla.
  house({{2772, 12, 100, {band = 3}}, {2772, 30, 106, {band = 3}}, {2772, 5, 101, {band = 3, owner = "Javi"}}})
  Stub.advance(1900)
  scanNow()
  eq(OroHermandadCharDB.scanner.ownSeen, "yes"); eq(OroHermandadCharDB.scanner.ownMiss, nil)
  Stub.closeAH()
end)

test("Ventas: tus subastas de mercancía vendidas ya no cuentan como tuyas en el escaneo (la pareja sigue midiendo)", function()
  boot()
  setNow(dayStart(5))
  local me = UnitName("player")
  -- Dos lotes tuyos de hierro con precio de compra y uno tuyo de solo puja (también es tuyo).
  standardHouse({{2772, 10, 99, {band = 3, owner = me}}, {2772, 10, 99, {band = 3, owner = me}},
                 {2772, 5, 120, {band = 3, owner = me, bid = 500}}})
  Stub.openAH(); Stub.advance(3)
  Stub.asUser(function() C_AuctionHouse.PostCommodity({itemID = 2772}, 3, 10, 99) end)
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 5001)
  Stub.asUser(function() C_AuctionHouse.PostCommodity({itemID = 2772}, 3, 10, 99) end)
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 5002)
  Stub.advance(20)
  scanNow()
  eq(OroHermandadCharDB.scanner.ownSeen, "yes"); eq(Scanner.Internals().stats.lastRead.ownRows, 3, "la de solo puja, también")
  Stub.closeAH()
  -- Se venden: siguen apuntadas para la línea de ventas, marcadas como vendidas (una vez).
  Stub.advance(1200)
  Stub.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "", 5001)
  Stub.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "", 5002)
  Stub.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "", 5001) -- otra compra parcial
  assert(OroHermandadCharDB.auctions[5001]:match(",c,s$"), OroHermandadCharDB.auctions[5001])
  assert(OroHermandadCharDB.auctions[5002]:match(",c,s$"), OroHermandadCharDB.auctions[5002])
  eq(#Scanner.Sales(KEY), 3, "tres avisos de venta")
  -- La pestaña Subastas: dos vendidas esperando en el correo y una de solo puja: ninguna debería salir con precio.
  Stub.ah.ownedList = {{status = 1, buyoutAmount = 990, bidder = "Comprador"}, {status = 1, buyoutAmount = 990},
                       {status = 0, bidAmount = 500}}
  -- La pareja: dos escaneos a 40 min sin ninguna tuya en la subasta.
  Stub.advance(2400)
  standardHouse()
  Stub.openAH(); Stub.advance(3)
  scanNow()
  Stub.closeAH()
  Stub.advance(2400)
  standardHouse()
  Stub.openAH(); Stub.advance(3)
  eq(Scanner.PairDue(KEY), true); eq(Scanner.Proposal().reason, "pareja")
  scanNow()
  assert(lastPoint(2772).dt, "con ventas")
  eq(OroHermandadCharDB.scanner.ownSeen, "yes"); eq(OroHermandadCharDB.scanner.ownMiss, nil)
  local probe = table.concat(Scanner.ProbeLines(), "\n")
  assert(has(probe, "la subasta dice 0 a la venta de 3"), probe)
  assert(not has(probe, "Comprador"), "el pujador nunca se lee")
  Stub.closeAH()
  -- Una subasta tuya activa con precio que no sale en dos escaneos seguidos: entonces sí, «no».
  Stub.ah.ownedList = {{status = 0, buyoutAmount = 990}}
  for k = 1, 2 do
    Stub.advance(1900)
    Stub.openAH(); Stub.advance(3)
    scanNow()
    Stub.closeAH()
    eq(OroHermandadCharDB.scanner.ownSeen, k == 1 and "yes" or "no", "escaneo " .. k)
  end
  Stub.ah.ownedList = {}
  -- Lo guardado: «,s» solo en mercancías; lo demás, fuera al cargar.
  reload(function()
    OroHermandadCharDB.auctions[6001] = "2772,99,10,3,1800000000,Forever-Alliance,i,s"
    OroHermandadCharDB.auctions[6002] = "2772,99,10,3,1800000000,Forever-Alliance,c,s,s"
  end)
  assert(OroHermandadCharDB.auctions[5001], "la vendida sigue"); eq(OroHermandadCharDB.auctions[6001], nil)
  eq(OroHermandadCharDB.auctions[6002], nil); eq(OroHermandadCharDB.scanner.ownSeen, "no")
end)

test("Ventas con un alter de la misma cuenta: las dos medidas no se pisan (una compra cuenta una vez)", function()
  boot()
  local realName = _G.UnitName
  local chars, current = {}, "Javi"
  local function switch(name)
    chars[current] = Stub.deepCopy(OroHermandadCharDB)
    reload(function()
      _G.OroHermandadCharDB = chars[name]
      _G.UnitName = function() return name end
    end)
    current = name
  end
  _G.UnitName = function() return "Javi" end
  local function houseWith(big)
    local spec = {{2772, 5, 100, {band = 2}}, {2772, 30, 104, {band = 3}}, {2772, 50, 130, {band = 3}},
                  {2770, 40, 30, {band = 3}}, {2770, 10, 31, {band = 2}}}
    if big then table.insert(spec, 1, {2772, 20, 99, {band = 3}}) end
    house(spec)
  end
  local function scanAt(t, expected)
    setNow(t)
    Stub.openAH(); Stub.advance(3)
    scanNow()
    eq(state(), expected)
    Stub.closeAH()
    return lastPoint(2772)
  end
  local T0 = dayStart(8)
  houseWith(true)
  scanAt(T0, "done")                                   -- Javi, grabado
  switch("Alto")
  scanAt(T0 + 16 * 60, "done-refresh")                 -- Alto: su referencia
  houseWith(false)                                     -- se compran las 20 a 99
  switch("Javi")
  local a = scanAt(T0 + 46 * 60, "done")               -- Javi: mide (T0, T0+46]
  eq(a.sold, 20); eq(OroHermandadDB.scanner.sampledUntil[KEY], a.t)
  switch("Alto")
  local altBase = OroHermandadCharDB.scanBase[KEY].t
  setNow(T0 + 76 * 60)
  Stub.openAH(); Stub.advance(3)
  eq(Scanner.PairDue(KEY), false, "su referencia es de antes de la última medida")
  Stub.closeAH()
  local b = scanAt(T0 + 76 * 60, "done")               -- Alto: (T0+16, T0+76] se pisaría con la de Javi
  eq(b.dt, nil, "sin ventas")
  assert(OroHermandadCharDB.scanBase[KEY].t > altBase, "la referencia de Alto se movió")
  local c = scanAt(T0 + 110 * 60, "done")              -- y el siguiente de Alto ya mide desde ahí
  eq(c.dt, c.t - b.t)
  -- Ninguna medida se pisa con otra.
  local samples = {}
  for _, p in ipairs(points(2772)) do if p.dt then samples[#samples + 1] = p end end
  eq(#samples, 2)
  for i = 2, #samples do assert(samples[i].t - samples[i].dt >= samples[i - 1].t, "se pisan") end
  _G.UnitName = realName
end)

---------------------------------------------------------------------------
-- 6. Modos: automático, proponer y solo con el botón
---------------------------------------------------------------------------
test("Automático: pide a los 2 s de abrir; con la subasta abierta, solo si toca grabar o medir ventas; nada en el chat", function()
  boot()
  Stub.printed = {} -- (las propuestas de las pruebas de antes, en modo proponer con la ventana cerrada)
  setNow(dayStart(4))
  Scanner.SetMode("auto")
  standardHouse()
  Stub.openAH(); Stub.advance(1)
  eq(#Stub.ah.calls > 0 and Stub.ah.calls[#Stub.ah.calls].at >= Stub.now - 1 and "temprano" or "no", "no", "ni antes de 2 s")
  local calls = #Stub.ah.calls
  Stub.runUntil(function() return not busy() and #log.done == 1 end, 30)
  eq(#Stub.ah.calls, calls + 1); eq(state(), "done")
  local T = OroHermandadDB.scanner.recorded[KEY]
  -- Abierta 29 min: el turno se abre a los 15 min pero no toca grabar ni medir.
  Stub.runUntil(function() return Stub.now >= T + 29 * 60 end, 1800)
  eq(#Stub.ah.calls, calls + 1, "nada hasta los 30 min")
  Stub.runUntil(function() return #log.done == 2 end, 200)
  eq(#log.done, 2, "a los 30 min, otro (grabado, con ventas)")
  eq(state(), "done")
  Stub.closeAH()
  -- Visita 20 min después de un escaneo grabado: se escanea igual (solo refresca) y la referencia se mueve.
  Stub.advance(20 * 60 - 60)
  local baseBefore = OroHermandadCharDB.scanBase[KEY].t
  Stub.openAH()
  Stub.runUntil(function() return #log.done == 3 end, 30)
  eq(state(), "done-refresh"); assert(OroHermandadCharDB.scanBase[KEY].t > baseBefore, "referencia movida")
  Stub.closeAH()
  eq(#log.say, 0, "nada en el chat")
  for _, line in ipairs(Stub.printed) do assert(not has(line, "scane"), line) end
end)

test("Automático: nunca con el escaneo completo de Auctionator activado (se usa el suyo) ni mientras publicas o compras", function()
  Stub.advance(4000)
  Stub.autoscan, Stub.replicateScan = true, true
  local calls = #Stub.ah.calls
  Stub.openAH()
  Stub.advance(5)
  eq(#Stub.ah.calls, calls, "no pide")
  eq(state(), "auctionator")
  eq(Scanner.StateText(), "Auctionator escanea la subasta entera al abrirla: Oro de Hermandad usa ese escaneo.")
  eq(Scanner.Proposal(), nil, "ni propone")
  -- Auctionator pide la suya: se lee por el gancho.
  local done = #log.done
  C_AuctionHouse.ReplicateItems()
  Stub.runUntil(function() return not busy() end, 30)
  eq(#log.done, done + 1, "leída")
  Stub.closeAH()
  Stub.autoscan, Stub.replicateScan = false, false
  -- Publicando: el marco de venta tiene algo, o hace menos de 15 s de un PostCommodity o de una compra.
  Stub.advance(4000)
  Stub.sellItem = {bag = 0, slot = 1}
  calls = #Stub.ah.calls
  Stub.openAH()
  Stub.advance(10)
  eq(#Stub.ah.calls, calls, "con algo en el marco de venta, no")
  Stub.advance(40)
  Stub.sellItem = nil
  Stub.asUser(function() C_AuctionHouse.PostCommodity({itemID = 2772}, 1, 5, 101) end)
  Stub.advance(15) -- la revisión del minuto llega 10 s después de publicar
  eq(#Stub.ah.calls, calls, "15 s tras publicar, no")
  Stub.advance(60)
  eq(#Stub.ah.calls, calls + 1, "luego sí")
  Stub.runUntil(function() return not busy() end, 30)
  Stub.closeAH()
  Stub.advance(4000)
  Stub.openAH()
  Stub.fire("COMMODITY_PURCHASE_SUCCEEDED")
  calls = #Stub.ah.calls
  Stub.advance(5)
  eq(#Stub.ah.calls, calls, "tras comprar, no")
  Stub.closeAH()
  -- Un clic sí vale aunque estés publicando.
  Stub.advance(1000)
  Stub.sellItem = {bag = 0, slot = 1}
  calls = #Stub.ah.calls
  Stub.openAH(); Stub.advance(3)
  eq(#Stub.ah.calls, calls, "solo, no")
  eq(Scanner.Request(true), true, "manual: sí")
  Stub.runUntil(function() return not busy() end, 30)
  Stub.sellItem = nil
  Stub.closeAH()
  Scanner.SetMode("propose")
end)

test("Proponer: «pareja» con tu escaneo de hace 40 min, «nadie escanea» a los 30 min, franja con pocos datos; chat solo con la ventana cerrada", function()
  boot()
  windowShown = true
  setNow(dayStart(5))
  eq(Scanner.Mode(), "propose", "por defecto")
  standardHouse()
  Stub.openAH(); Stub.advance(3)
  local p = Scanner.Proposal()
  eq(p.reason, "stale"); eq(p.text, "Nadie de la hermandad ha escaneado aún esta subasta.")
  scanNow()
  Stub.closeAH()
  local T = OroHermandadDB.scanner.recorded[KEY]
  -- Un compañero escaneó hace 5 min.
  local m = History.Market(KEY, true)
  m.obs = {["0badcafe"] = {seen = T + 2100, s = tostring(T + 2100), items = {[2772] = {d = "", p = (T + 2100) .. ",100,5,5"}}}}
  setNow(T + 2400)
  Stub.openAH(); Stub.advance(3)
  p = Scanner.Proposal()
  eq(p.reason, "pareja")
  eq(p.text, "Escaneaste hace 40 min: si escaneas ahora, el addon mide lo que se ha vendido entre los dos escaneos.")
  Stub.closeAH()
  -- Sin tu referencia en el plazo (2 h después) y el compañero de hace 5 min: la franja con pocos datos (Timing).
  setNow(T + 7400)
  m.obs["0badcafe"].seen = Stub.now - 300
  ns.Timing = {Coverage = function(market, block) eq(market, KEY); return 1 end}
  Stub.openAH(); Stub.advance(3)
  p = Scanner.Proposal()
  eq(p.reason, "thin")
  assert(p.text:match("^La franja %d+%-%d+ h tiene pocos datos para «Cuándo vender»%.$"), p.text)
  ns.Timing = {Coverage = function() return 3 end}
  eq(Scanner.Proposal(), nil, "con datos de sobra, nada")
  ns.Timing = nil
  Stub.closeAH()
  -- Nadie desde hace 40 min: «Hace 40 min que nadie...»; en el chat solo con la ventana cerrada, una vez por visita.
  m.obs = nil
  OroHermandadDB.scanner.recorded[KEY] = Stub.now - 2400
  OroHermandadCharDB.scanBase = {}
  windowShown = true
  Stub.openAH(); Stub.advance(130)
  eq(#log.say, 0, "ventana abierta: nada en el chat")
  Stub.closeAH()
  windowShown = false
  Stub.openAH(); Stub.advance(3)
  eq(#log.say, 1)
  assert(log.say[1]:match("^Hace 4%d min que nadie de la hermandad escanea esta subasta%. Escribe /oro escanear %(unos segundos%)%.$"), log.say[1])
  Stub.advance(200)
  eq(#log.say, 1, "una por visita")
  Stub.closeAH(); Stub.advance(60)
  Stub.openAH(); Stub.advance(130)
  eq(#log.say, 1, "y como mucho cada 30 min")
  Stub.closeAH()
  Stub.advance(1800)
  OroHermandadDB.scanner.recorded[KEY] = Stub.now - 2400
  Stub.openAH(); Stub.advance(3)
  eq(#log.say, 2, "pasados 30 min, otra")
  Stub.closeAH()
  -- Solo con el botón: nada propuesto; el botón sigue valiendo.
  eq(Scanner.Command("off"), "escanear la subasta: solo con el botón o /oro escanear.")
  Stub.advance(1800)
  Stub.openAH(); Stub.advance(130)
  eq(#log.say, 2)
  eq(Scanner.Request(true), true)
  Stub.runUntil(function() return not busy() end, 30)
  Stub.closeAH()
  eq(Scanner.Command("proponer"), "escanear la subasta: te lo propone el addon.")
  eq(Scanner.Command("auto"), "escanear la subasta: automático cada vez que la abres.")
  eq(OroHermandadDB.scanner.auto, "auto")
  Scanner.SetMode("propose")
  eq(Scanner.Command(""), "abre la subasta y vuelve a escribirlo.")
end)

---------------------------------------------------------------------------
-- 7. Resúmenes de Auctionator retenidos (R2)
---------------------------------------------------------------------------
local function summary(t, price)
  return {t = t, rows = 3, market = KEY, data = Stub.scanRows("summary", nil, {{id = 2772, price = price, qty = 30}})}
end

test("Resumen al abrir y luego el escaneo completo: graba el completo (con ventas) y el resumen se tira", function()
  boot()
  setNow(dayStart(6))
  standardHouse()
  Stub.openAH(); Stub.advance(3)
  scanNow()
  Stub.closeAH()
  Stub.advance(2700)
  Stub.openAH(); Stub.advance(1)
  local held = math.floor(Stub.now)
  eq(Scanner.HoldSummary(summary(held, 77)), true, "retenido")
  Stub.advance(2)
  scanNow()
  eq(state(), "done")
  eq(Scanner.Held(KEY), nil, "tirado")
  Stub.closeAH()
  eq(#log.released, 0, "nunca soltado")
  local p = lastPoint(2772)
  assert(p.t ~= held and p.lo ~= 77 and p.dt, "el punto es el del completo, con su venta")
end)

test("Resumen sin clic en «proponer»: se graba al cerrar con su hora; con «no responde» o en «off», en el acto; sin hueco, solo precios", function()
  Stub.advance(4000)
  Stub.openAH(); Stub.advance(3)
  local t = math.floor(Stub.now)
  eq(Scanner.HoldSummary(summary(t, 81)), true)
  Stub.advance(100)
  Stub.closeAH()
  eq(#log.released, 1); eq(log.released[1].record, true)
  Stub.advance(5)
  eq(lastPoint(2772).t, t, "con la hora del resumen"); eq(lastPoint(2772).lo, 81)
  -- A los 10 min retenido, también se suelta.
  Stub.advance(4000)
  Stub.openAH(); Stub.advance(3)
  Scanner.HoldSummary(summary(math.floor(Stub.now), 82))
  Stub.advance(601)
  eq(#log.released, 2, "a los 10 min")
  Stub.closeAH()
  -- En «off» sin ventana abierta: en el acto.
  Stub.advance(4000)
  Scanner.SetMode("off")
  Stub.openAH(); Stub.advance(3)
  eq(Scanner.HoldSummary(summary(math.floor(Stub.now), 83)), false, "soltado en el acto")
  eq(#log.released, 3)
  Stub.closeAH()
  Scanner.SetMode("propose")
  -- Con el turno de 15 min cerrado más de 10 min: no puede llegar el completo.
  Stub.advance(4000)
  Stub.openAH(); Stub.advance(3)
  scanNow()
  Stub.advance(100)
  eq(Scanner.HoldSummary(summary(math.floor(Stub.now), 84)), false, "sin escaneo completo posible en 10 min")
  eq(log.released[4].record, false, "a 100 s del último grabado: solo precios")
  Stub.closeAH()
end)

test("Subasta neutral o que no se sabe: los escaneos de Auctionator solo refrescan (nada grabado, compartido ni fechado)", function()
  Stub.advance(4000)
  local before, out, recorded = #points(2772), #OroHermandadCharDB.relay.out, OroHermandadDB.scanner.recorded[KEY]
  local fullScan, rows, released = OroHermandadDB.fullScan[KEY], OroHermandadDB.scanRows[KEY], #log.released
  for _, o in ipairs({{npcFaction = false, mapID = 9001}, {npcFaction = false, mapID = 2001, depositFactor = 2}}) do
    Stub.openAH(o); Stub.advance(3)
    assert(Scanner.House() == "neutral" or Scanner.House() == "unknown", tostring(Scanner.House()))
    Stub.scanComplete("summary", 1000)                 -- entero
    Stub.scanComplete("summary", 10)                   -- parcial
    Stub.scanComplete("full")
    eq(Scanner.HoldSummary(summary(math.floor(Stub.now), 70)), "drop"); eq(Scanner.Held(KEY), nil)
    Stub.advance(5)
    Stub.runUntil(function() return History.Pending() == 0 end, 30)
    Stub.closeAH()
    Stub.scanComplete("summary", 1000)                 -- el aviso llega justo después de cerrar: igual
    Stub.advance(5)
  end
  eq(#points(2772), before, "ningún punto"); eq(#OroHermandadCharDB.relay.out, out, "nada compartido")
  eq(OroHermandadDB.scanner.recorded[KEY], recorded, "el filtro del mercado no se gasta")
  eq(OroHermandadDB.fullScan[KEY], fullScan, "ni se fecha"); eq(OroHermandadDB.scanRows[KEY], rows); eq(#log.released, released)
  -- En la de tu facción, el mismo resumen se retiene como siempre.
  Stub.openAH({mapID = 1453}); Stub.advance(3)
  eq(Scanner.House(), "faction")
  eq(Scanner.HoldSummary(summary(math.floor(Stub.now), 71)), true)
  Stub.closeAH()
  eq(#log.released, released + 1)
end)

test("Resumen retenido y /reload (o «Guardar y subir») con la subasta abierta: se graba antes de que el juego escriba", function()
  Stub.advance(4000)
  Stub.openAH({mapID = 1453}); Stub.advance(3)
  local t = math.floor(Stub.now)
  eq(Scanner.HoldSummary(summary(t, 86)), true)
  eq(state(), "ready", "«Guardar y subir» no espera")
  local out = #OroHermandadCharDB.relay.out
  reload() -- PLAYER_LOGOUT sin AUCTION_HOUSE_CLOSED antes
  eq(lastPoint(2772).t, t, "con la hora del resumen"); eq(lastPoint(2772).lo, 86)
  eq(OroHermandadDB.scanner.recorded[KEY], t)
  eq(#OroHermandadCharDB.relay.out, out + 1, "compartido")
end)

---------------------------------------------------------------------------
-- 8. «Escanear la lista»
---------------------------------------------------------------------------
test("Lista: espera los datos de cada objeto, 1,2 s entre búsquedas (50 por minuto), pausa al vender; entera solo si responde todo", function()
  boot()
  setNow(dayStart(7))
  Stub.ah.keyCached, Stub.ah.queries = {}, {}
  Stub.commodity[2772] = {{100, 20, 0}, {104, 30, 0}, {130, 50, 5}}
  Stub.commodity[2770] = {{30, 40, 10}, {31, 10, 0}}
  Stub.notCommodity[12404] = true
  Stub.ah.ignore[3858] = true
  Stub.openAH(); Stub.advance(3)
  local sent = {}
  local orig = C_AuctionHouse.SendSearchQuery
  C_AuctionHouse.SendSearchQuery = function(key, ...)
    sent[#sent + 1] = {at = Stub.gameTime, id = key.itemID, cached = Stub.ah.keyCached[key.itemID] == true}
    return orig(key, ...)
  end
  eq(Scanner.StartSweep(), true)
  eq(state(), "sweep")
  assert(Scanner.StateText():match("^Escaneando la lista vigilada: 0/161 %(unos %d+ min%)%. No vendas ni compres mientras dura; «Parar» lo detiene%.$"), Scanner.StateText())
  Stub.advance(20)
  -- Pausa en la pestaña Subastas (o vendiendo).
  _G.AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Auctions)
  Stub.advance(2)
  local paused = #sent
  Stub.advance(20)
  eq(#sent, paused, "en pausa")
  eq(Scanner.StateText(), "Escaneo de la lista en pausa mientras vendes o miras tus subastas.")
  _G.AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.CommoditiesSell)
  Stub.advance(10)
  eq(#sent, paused, "vendiendo, también")
  _G.AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
  Stub.runUntil(function() return state() ~= "sweep" end, 900)
  Stub.runUntil(function() return History.Pending() == 0 end, 30)
  C_AuctionHouse.SendSearchQuery = orig
  for i, q in ipairs(sent) do
    assert(q.cached, "solo con los datos del objeto: " .. q.id)
    if i > 1 then assert(q.at - sent[i - 1].at >= 1.2 - 1e-9, "1,2 s entre búsquedas") end
    local inMinute = 0
    for _, other in ipairs(sent) do if other.at >= q.at and other.at < q.at + 60 - 1e-6 then inMinute = inMinute + 1 end end
    assert(inMinute <= 50, "50 por minuto como mucho: " .. inMinute)
  end
  local ignored = 0
  for _, q in ipairs(sent) do if q.id == 3858 then ignored = ignored + 1 end end
  eq(ignored, 2, "la ignorada: un reintento y nada más")
  local sw = Scanner.Internals().stats.lastSweep
  eq(sw.total, 161); eq(sw.answered, 160); eq(sw.whole, false, "una sin respuesta: parcial")
  local p = lastPoint(2772)
  eq(p.lo, 100); eq(p.qty, 95, "sin tus 5"); eq(p.qty5, 50)
  eq(lastPoint(2770).lo, 30); eq(lastPoint(2770).qty, 40, "sin tus 10")
  eq(log.done[#log.done].kind, "lista"); eq(log.done[#log.done].whole, false)
  Stub.closeAH()
  Stub.ah.ignore[3858] = nil
end)

test("Lista entera: graba el día; «Parar» la deja parcial y no se comparte; nunca SearchForItemKeys", function()
  Stub.advance(4000)
  Stub.openAH(); Stub.advance(3)
  local outbox = #OroHermandadCharDB.relay.out
  eq(Scanner.StartSweep(), true)
  Stub.runUntil(function() return state() ~= "sweep" end, 900)
  local sw = Scanner.Internals().stats.lastSweep
  eq(sw.whole, true); eq(sw.recorded, true)
  Stub.advance(10)
  eq(#OroHermandadCharDB.relay.out, outbox + 1, "una lista entera se comparte como un escaneo entero")
  Stub.advance(2000)
  eq(Scanner.StartSweep(), true)
  Stub.advance(15)
  eq(Scanner.Command("parar"), "escaneo de la lista parado: se guarda lo leído.")
  sw = Scanner.Internals().stats.lastSweep
  eq(sw.whole, false)
  Stub.advance(10)
  eq(#OroHermandadCharDB.relay.out, outbox + 1, "una parcial no se comparte")
  eq(Scanner.Command("parar"), "no hay ningún escaneo en marcha.")
  -- Al cerrar la subasta a medias, también parcial.
  Stub.advance(2000)
  Scanner.StartSweep()
  Stub.advance(10)
  Stub.closeAH()
  eq(Scanner.Internals().stats.lastSweep.whole, false)
  assert(not read(DIR .. "Scanner.lua"):find("SearchForItemKeys", 1, true), "sin SearchForItemKeys (D18)")
end)

---------------------------------------------------------------------------
-- 9. Tus ventas y tus compras (solo en este PC)
---------------------------------------------------------------------------
local function notify(kind, text, auctionID)
  Stub.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", Enum.AuctionHouseNotification[kind], text, auctionID)
end

test("Ventas: publicar, crear y vender (por auctionID y por nombre); mercancía = veces, objeto = 1; el texto nunca se guarda", function()
  boot()
  setNow(dayStart(8))
  Stub.openAH(); Stub.advance(3)
  -- PostCommodity y su confirmación 90 s después: una sola publicación.
  Stub.asUser(function() C_AuctionHouse.PostCommodity({itemID = 2772}, 2, 20, 101) end)
  Stub.advance(90)
  Stub.asUser(function() C_AuctionHouse.ConfirmPostCommodity({itemID = 2772}, 2, 20, 101) end)
  eq(#Scanner.Internals().pending, 1, "una publicación")
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 7001)
  local created = math.floor(Stub.now)
  eq(OroHermandadCharDB.auctions[7001], table.concat({2772, 101, 20, 2, created, KEY, "c"}, ","))
  -- PostItem de 2 piezas: dos subastas de 1.
  Stub.asUser(function() C_AuctionHouse.PostItem({itemID = 5000}, 3, 2, nil, 9000) end)
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 7002)
  Stub.advance(2)
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 7003)
  eq(OroHermandadCharDB.auctions[7003], table.concat({5000, 4500, 1, 3, math.floor(Stub.now), KEY, "i"}, ","))
  Stub.closeAH()
  Stub.advance(3600)
  -- Lejos de la subasta: dos compras parciales de la mercancía (aviso con auctionID) y una pieza (por nombre).
  notify("AuctionSold", "Hierro", 7001)
  notify("AuctionSold", "Hierro", 7001)
  notify("AuctionSold", "Espada verde", nil)
  local sales = Scanner.Sales(KEY)
  eq(#sales, 3)
  local t = math.floor(Stub.now)
  eq(dump(sales[1]), dump({t, 2772, 101, 0, 2, t - created}), "mercancía: qty 0")
  eq(sales[3][2], 5000); eq(sales[3][4], 1, "pieza: 1")
  assert(OroHermandadCharDB.auctions[7001], "la mercancía sigue hasta caducar")
  eq((OroHermandadCharDB.auctions[7002] and 1 or 0) + (OroHermandadCharDB.auctions[7003] and 1 or 0), 1, "la pieza vendida se quita")
  -- Desconocido: id 0. Caducada: se quita. Cancelada: se quita.
  notify("AuctionSold", "Algo que no conozco", nil)
  eq(Scanner.Sales(KEY)[4][2], 0)
  notify("AuctionExpired", "Hierro", 7001)
  eq(OroHermandadCharDB.auctions[7001], nil)
  OroHermandadCharDB.auctions[7009] = table.concat({2772, 1, 1, 1, math.floor(Stub.now), KEY, "c"}, ",")
  Stub.fire("AUCTION_CANCELED", 7009)
  eq(OroHermandadCharDB.auctions[7009], nil)
  local text = dump(OroHermandadDB.sales) .. dump(OroHermandadCharDB.auctions)
  assert(not has(text, "Hierro") and not has(text, "Espada") and not has(text, "conozco"), "sin el texto de los avisos")
end)

test("Ventas: publicaciones de más de 5 min fuera, nada en la subasta neutral, «sales = false» no apunta (las compras sí)", function()
  Stub.openAH(); Stub.advance(3)
  Stub.asUser(function() C_AuctionHouse.PostCommodity({itemID = 2770}, 1, 5, 30) end)
  Stub.advance(301)
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 8001)
  eq(OroHermandadCharDB.auctions[8001], nil, "más de 300 s: fuera")
  Stub.closeAH()
  Stub.mapID = 9001
  Stub.openAH({npcFaction = false})
  eq(Scanner.House(), "neutral")
  Stub.asUser(function() C_AuctionHouse.PostCommodity({itemID = 2770}, 1, 5, 30) end)
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 8002)
  eq(OroHermandadCharDB.auctions[8002], nil, "neutral: no se sigue")
  Stub.closeAH()
  Stub.mapID = 1453
  local n = #Scanner.Sales(KEY)
  Scanner.SetSales(false)
  notify("AuctionSold", "Hierro", nil)
  eq(#Scanner.Sales(KEY), n, "apagado: no se apunta")
  local buys = OroHermandadDB.scanner.buys
  Stub.fire("COMMODITY_PURCHASED", 2772, 3)
  assert(OroHermandadDB.scanner.buys ~= buys, "las compras sí")
  Scanner.SetSales(true)
end)

test("Compras: «t,id,qty», 7800 s y 300 como mucho; ventas: 28 días, 2000 por mercado y 4 mercados", function()
  OroHermandadDB.scanner.buys = ""
  setNow(math.floor(Stub.now))
  local t0 = Stub.now
  for i = 1, 320 do Stub.fire("COMMODITY_PURCHASED", 2772, 1); Stub.now = Stub.now + 1 end
  local _, n = OroHermandadDB.scanner.buys:gsub(";", "")
  eq(n + 1, 300, "300 como mucho")
  assert(OroHermandadDB.scanner.buys:match("^%d+,2772,1;"))
  eq(Scanner.BoughtBetween(2772, t0 - 1, Stub.now), 300)
  Stub.now = Stub.now + 7801
  Stub.fire("ITEM_PURCHASED", 5000)
  eq(OroHermandadDB.scanner.buys, (Stub.now) .. ",5000,1", "lo de hace más de 7800 s fuera")
  -- 28 días y 2000 ventas por mercado.
  local list = {}
  for i = 1, 2100 do list[i] = (Stub.now - 2100 + i) .. ",2772,1,0,1,60" end
  list[1] = (Stub.now - 29 * 86400) .. ",2772,1,0,1,60"
  OroHermandadDB.sales[KEY] = table.concat(list, ";")
  notify("AuctionSold", "Hierro", nil)
  local sales = Scanner.Sales(KEY)
  eq(#sales, 2000, "2000 como mucho")
  -- 4 mercados como mucho (fuera el menos visitado).
  for i = 1, 5 do
    local key = "Reino" .. i .. "-Horde"
    OroHermandadDB.sales[key] = Stub.now .. ",1,1,0,1,1"
    OroHermandadDB.scanner.visited[key] = Stub.now - 1000 + i
  end
  OroHermandadDB.scanner.visited[KEY] = Stub.now
  Scanner.BeforeSave()
  local markets = 0
  for key in pairs(OroHermandadDB.sales) do markets = markets + 1 end
  eq(markets, 4); assert(OroHermandadDB.sales[KEY] and OroHermandadDB.sales["Reino5-Horde"], "se quedan los más visitados")
end)

---------------------------------------------------------------------------
-- 10. Caché de precios y las dos fuentes (con y sin Auctionator)
---------------------------------------------------------------------------
test("Precios: el más reciente de Auctionator y del escáner; a igualdad, el propio; History.Import sigue igual", function()
  boot()
  setNow(dayStart(9))
  -- Auctionator: hierro 120 (hoy), piedra densa 300 (hace 2 días).
  Stub.prices[2772], Stub.ages[2772], Stub.prices[12365], Stub.ages[12365] = 120, 0, 300, 2
  house({{2772, 10, 95, {band = 3}}, {210001, 1, 777, {band = 2}}})
  Stub.openAH(); Stub.advance(3)
  scanNow()
  Stub.closeAH()
  ns.Prices.Invalidate()
  eq(ns.Prices.Price(2772), 95, "mismo día: el propio"); eq(ns.Prices.Age(2772), 0)
  eq(ns.Prices.Price(210001), 777, "uno no vigilado, de la caché propia")
  eq(ns.Prices.Price(12365), 300, "solo Auctionator")
  eq(ns.Prices.AuctionatorPrice(2772), 120, "Auctionator sigue a mano")
  -- Dos días después, Auctionator ve el hierro hoy: gana el suyo.
  setNow(math.floor(Stub.now) + 2 * 86400)
  ns.Prices.Invalidate()
  eq(ns.Prices.Price(2772), 120); eq(ns.Prices.Age(2772), 0)
  local price, age = ns.Prices.Quote(210001)
  eq(price, 777); eq(age, 2)
  eq(ns.Prices.Available(), true)
  eq(ns.Prices.Capabilities().age, true)
  Stub.history["2772"] = {{rawDay = tostring(Spec.DayIndex(Stub.now) - 30), minSeen = 90, maxSeen = 99}}
  eq(History.Import(true), "started", "la importación de Auctionator sigue")
end)

test("Caché de precios: solo se decodifica el mercado actual; 900 KB entre todos (fuera el más viejo); 21 días", function()
  setNow(math.floor(Stub.now))
  local function text(n, base, d)
    local parts = {}
    for i = 1, n do parts[i] = (base + i) .. ":" .. (1000 + i) .. ":" .. d end
    return table.concat(parts, ",")
  end
  local today = Spec.DayIndex(math.floor(Stub.now))
  OroHermandadDB.scanPrices["Viejo-Horde"] = {t = Stub.now - 5000, text = text(20000, 100000, today)}
  OroHermandadDB.scanPrices["Nuevo-Horde"] = {t = Stub.now - 100, text = text(20000, 150000, today)}
  reload()
  eq(Scanner.CacheInfo().decodes, 0, "al cargar no se decodifica nada")
  eq(ns.Prices.Price(2772) ~= nil, true)
  local info = Scanner.CacheInfo()
  eq(info.decodes, 1, "solo el actual"); eq(info.decoded, KEY)
  -- Entre todos pasan de 40 000 entradas / 900 000 bytes: al salir se va el de t más vieja.
  Scanner.BeforeSave()
  eq(OroHermandadDB.scanPrices["Viejo-Horde"], nil, "el más viejo fuera")
  assert(OroHermandadDB.scanPrices["Nuevo-Horde"] and OroHermandadDB.scanPrices[KEY], "los demás se quedan")
  local after = Scanner.CacheInfo()
  assert(after.entries <= 40000 and after.bytes <= 900000, after.entries .. " " .. after.bytes)
  -- Un mercado solo que no cabe pierde sus entradas más viejas.
  OroHermandadDB.scanPrices = {[KEY] = {t = Stub.now, text = text(30000, 100000, today - 1) .. "," .. text(15000, 300000, today)}}
  reload()
  ns.Prices.Price(2772)
  Scanner.BeforeSave()
  local entries = select(2, OroHermandadDB.scanPrices[KEY].text:gsub(",", "")) + 1
  assert(entries <= 40000 and #OroHermandadDB.scanPrices[KEY].text <= 900000, "cabe")
  assert(OroHermandadDB.scanPrices[KEY].text:find("300001:1001:" .. today, 1, true), "se quedan las de hoy")
  -- Más de 21 días: fuera al decodificar.
  OroHermandadDB.scanPrices = {[KEY] = {t = Stub.now, text = "2770:30:" .. (today - 22) .. ",2772:99:" .. (today - 3)}}
  reload()
  eq(Scanner.OwnPrice(2770), nil, "22 días: fuera")
  local lo, age = Scanner.OwnPrice(2772)
  eq(lo, 99); eq(age, 3)
end)

test("Tamaño de toda la cuenta en el peor caso: lo tuyo (2 MB) + compañeros (4 MB) + OroHermandadDB con 4 mercados < 9 MB", function()
  setNow(math.floor(Stub.now))
  local today = Spec.DayIndex(Stub.now)
  -- Caché de precios en su tope (40 000 entradas / 900 000 bytes, repartidas en 4 mercados).
  local db = {scanPrices = {}, sales = {}, timing = {}, scanner = {buys = ""}}
  local id = 100000
  for m = 1, 4 do
    local parts = {}
    for _ = 1, 10000 do id = id + 1; parts[#parts + 1] = id .. ":" .. (1000000 + id) .. ":" .. today end
    db.scanPrices["Reino" .. m .. "-Alliance"] = {t = Stub.now, text = table.concat(parts, ",")}
  end
  local cacheBytes = 0
  for _, e in pairs(db.scanPrices) do cacheBytes = cacheBytes + #e.text end
  assert(cacheBytes <= Scanner.PRICE_BYTES, "la caché cabe en su tope: " .. cacheBytes)
  -- Ventas: 2000 por mercado en 4 mercados; «Cuándo vender»: 64 KB por mercado (el formato es de Timing.lua).
  for m = 1, 4 do
    local list = {}
    for i = 1, Scanner.SALES_MAX do list[i] = (Stub.now - i * 600) .. ",13446,240000,0,3,43200" end
    db.sales["Reino" .. m .. "-Alliance"] = table.concat(list, ";")
    db.timing["Reino" .. m .. "-Alliance"] = {text = ("9"):rep(64 * 1024)}
  end
  local buys = {}
  for i = 1, Scanner.BUYS_MAX do buys[i] = (Stub.now - i) .. ",13446,200" end
  db.scanner.buys = table.concat(buys, ";")
  local dbBytes = Spec.EstimateSize(db, "OroHermandadDB")
  local total = dbBytes + Spec.MAX_BYTES + History.OBS_MAX_BYTES
  realPrint(string.format("  cuenta en el peor caso: OroHermandadDB %.0f KB + 2048 KB + 4096 KB = %.0f KB", dbBytes / 1024, total / 1024))
  assert(dbBytes <= 1.5 * 1024 * 1024, "OroHermandadDB: " .. dbBytes)
  assert(total < 9 * 1024 * 1024, "toda la cuenta: " .. total)
  -- La referencia de ventas de un personaje: 161 objetos con 200 subastas cada uno (el máximo por objeto) caben en
  -- 400 KB; con un tope menor, se van primero los objetos con más subastas.
  boot()
  local rows = {}
  for i, w in ipairs(History.WatchList()) do
    for k = 1, (i % 2 == 0) and 200 or 20 do rows[#rows + 1] = {w.id, 100000 + k, 10000 + (k % 5) * 37, {band = k % 4}} end
  end
  house(rows, 0)
  setNow(dayStart(12))
  Stub.openAH(); Stub.advance(3)
  scanNow()
  local baseBytes, n = 0, 0
  for _, text in pairs(OroHermandadCharDB.scanBase[KEY].items) do baseBytes, n = baseBytes + #text, n + 1 end
  assert(baseBytes <= Scanner.BASE_BYTES, "referencia: " .. baseBytes)
  eq(n, #History.WatchList(), "caben todos")
  -- El cierre del escaneo (precios, ventas, referencia) también va por tandas: 16 objetos por tanda sin debugprofilestop.
  local frames = Scanner.Internals().stats.finishFrames
  assert(frames >= 2 * 161 / 16, "cierre en tandas (orden y referencia de 161 objetos): " .. tostring(frames))
  local cap, half = Scanner.BASE_BYTES, math.floor(baseBytes / 2)
  Scanner.BASE_BYTES = half
  Stub.advance(1000)
  scanNow()
  Scanner.BASE_BYTES = cap
  Stub.closeAH()
  local kept, bigKept = 0, 0
  baseBytes = 0
  for _, text in pairs(OroHermandadCharDB.scanBase[KEY].items) do
    kept, baseBytes = kept + 1, baseBytes + #text
    if #text > 1000 then bigKept = bigKept + 1 end
  end
  assert(baseBytes <= half, "dentro del tope: " .. baseBytes .. " de " .. half)
  assert(kept < n and kept >= 80, "fuera los de 200 subastas primero: " .. kept)
  assert(bigKept < 80, "los de 20 subastas se quedan: " .. bigKept)
end)

test("hist-v060.lua (contrato C3): Scanner.Init lee su OroHermandadDB sin perder nada (escáner, caché, ventas, compras)", function()
  eq(Stub.sha256File("test-lua/fixtures/v06/hist-v060.lua"), Stub.V06_SHA256["hist-v060.lua"])
  local env = {}
  local chunk = assert(loadstring(read("test-lua/fixtures/v06/hist-v060.lua")))
  setfenv(chunk, env)
  chunk()
  local before = dump(env.OroHermandadDB)
  local M = "GritodeGuerra-Alliance"
  local S2 = {Data = ns.Data, Items = ns.Items, Spec = ns.Spec, History = ns.History, Prices = ns.Prices}
  assert(loadfile(DIR .. "Scanner.lua"))("OroHermandad", S2)
  local db, cdb = env.OroHermandadDB, {}
  S2.Scanner.Init(db, cdb, {})
  eq(db.scanner.auto, "propose"); eq(db.scanner.fp, "5f3a9c21"); eq(db.scanner.lastSuccess, 1796478290)
  eq(db.scanner.recorded[M], 1796478300); eq(db.scanner.recordedDay[M], "2530:3"); eq(db.scanner.buys, "1796477000,2772,5")
  eq(db.scanner.sales, true, "por defecto, apuntar ventas")
  eq(db.scanPrices[M].text, "2770:39:2530,2772:149:2530,12365:306:2530,200001:100:2530")
  eq(db.sales[M], "1796470000,2772,155,0,3,7200;1796476000,0,0,0,0,0")
  eq(db.relay.subidor, "auto", "lo demás no se toca"); assert(db.guilds)
  -- Nada se reinicia: lo que había sigue igual (solo se añaden las tablas que faltaban).
  for _, key in ipairs({"scanPrices", "sales", "relay", "guilds"}) do
    assert(has(dump(db[key]), dump(env.OroHermandadDB[key])), key)
  end
  assert(#dump(db) >= #before)
  -- Tipos equivocados: solo esa tabla se reinicia.
  local bad = {scanner = {auto = "x", recorded = "y", buys = 5, houseZones = {[1] = true, x = 1}}, scanPrices = 3,
               sales = {[M] = "a,b"}, relay = {keep = true}}
  S2.Scanner.Init(bad, {auctions = "x", scanBase = {[M] = {t = "no"}}}, {})
  eq(bad.scanner.auto, "propose"); eq(next(bad.scanner.recorded), nil); eq(bad.scanner.buys, "")
  eq(bad.scanner.houseZones[1], true); eq(bad.scanner.houseZones.x, nil)
  eq(next(bad.scanPrices), nil); eq(bad.sales[M], nil); eq(bad.relay.keep, true)
end)

---------------------------------------------------------------------------
-- 11. Privacidad, funciones protegidas, sondeo
---------------------------------------------------------------------------
test("Nombres: vendedores, pujadores y tus personajes nunca se guardan ni se envían; tus subastas fuera de precios y referencia", function()
  boot()
  setNow(dayStart(10))
  house({{2772, 20, 100, {band = 3, shown = "Vendedor"}}, {2772, 5, 90, {band = 3, owner = "Javi"}},
         {2770, 10, 30, {band = 2, shown = "Vendedor", bidder = "Pujador"}}, {2770, 1, 0, {bid = 50, bidder = "Pujador"}}})
  Stub.openAH(); Stub.advance(3)
  scanNow()
  Stub.closeAH()
  eq(lastPoint(2772).lo, 100, "tu subasta a 90 no es el precio")
  eq(OroHermandadCharDB.scanBase[KEY].items[2772], "100:320", "ni la referencia")
  eq(Scanner.OwnPrice(2772), 100, "ni la caché")
  Stub.advance(60)
  Stub.fire("PLAYER_LOGOUT")
  local saved = dump(OroHermandadHist) .. dump(OroHermandadDB.scanPrices) .. dump(OroHermandadDB.sales)
    .. dump(OroHermandadDB.scanner) .. dump(OroHermandadDB.timing or {}) .. dump(OroHermandadCharDB.scanBase)
    .. dump(OroHermandadCharDB.auctions) .. dump(OroHermandadCharDB.relay and OroHermandadCharDB.relay.out or {})
  for _, sent in ipairs(Stub.sent) do saved = saved .. sent.msg end
  for _, name in ipairs({"Vendedor", "Pujador", "Javi", "Alto"}) do assert(not has(saved, name), "no debe salir: " .. name) end
  local probe = table.concat(Scanner.ProbeLines(), "\n")
  for _, name in ipairs({"Vendedor", "Pujador", "Javi"}) do assert(not has(probe, name), "sondeo: " .. name) end
  assert(has(probe, "con dueño ajeno 2"), probe)
end)

test("Sin llamadas protegidas del addon (publicar, pujar, cancelar, comprar): los ganchos solo miran", function()
  eq(#Stub.ah.protectedCalls, 0, "llamadas: " .. table.concat(Stub.ah.protectedCalls, ", "))
  eq(Scanner.hooked, true, "gancho puesto")
end)

test("/oro sondeo del escáner: cifras (casa, peticiones, lectura, tramos, caché, ventas)", function()
  Stub.openAH(); Stub.advance(3)
  local lines = table.concat(Scanner.ProbeLines(), "\n")
  Stub.closeAH()
  for _, want in ipairs({"Escáner: modo proponer", "gancho sí", "Casa: facción (regla 1; npc: Alliance, id 8719, mapa 1453, zona 1453",
                         "Peticiones: tuya ", "rechazadas por huella", "Última lectura: ", "tramo bruto ", "GetTimeLeftBandInfo 0/1800/7200/43200",
                         "saleStatus 0", "Grabados hoy: 1 de 8", "Referencia de ventas: ", "Caché de precios: ", "Ventas: "}) do
    assert(has(lines, want), "falta: " .. want .. "\n" .. lines)
  end
end)

---------------------------------------------------------------------------
-- 12. Sin Auctionator (H2)
---------------------------------------------------------------------------
test("Sin Auctionator: se abre la subasta, se escanea y los precios salen del escáner propio", function()
  Stub.install({auctionator = false})
  boot()
  eq(_G.Auctionator, nil)
  setNow(dayStart(11))
  eq(ns.Prices.Available(), false, "aún sin precios")
  house({{2772, 10, 95, {band = 3}}, {210001, 1, 777, {band = 2}}})
  Stub.openAH(); Stub.advance(3)
  scanNow()
  eq(state(), "done")
  Stub.closeAH()
  eq(ns.Prices.Available(), true)
  eq(ns.Prices.Price(210001), 777, "de la caché propia")
  eq(ns.Prices.Price(2772), 95)
  eq(lastPoint(2772).lo, 95)
  eq(ns.Prices.Capabilities().prices, true)
  eq(Scanner.DeferToAuctionator(), false)
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

test("Ningún fallo interno del escáner en toda la sesión", function()
  eq(Scanner.lastError, nil)
  eq(ns.History.lastError, nil)
end)

realPrint(string.format("escáner: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

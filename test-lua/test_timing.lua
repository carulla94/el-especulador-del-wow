-- Pruebas de «Cuándo vender» en el juego (Timing.lua, 0.6.0) en el cliente simulado de Forever. Desde la raíz del
-- repositorio: lua5.1 test-lua/test_timing.lua
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local json = require("json")
local realPrint = print
Stub.install()

local DIR = "addon/OroHermandad/"
local V06 = "test-lua/fixtures/v06/"
local KEY = "Forever-Alliance"
local BASE = 1800000000 -- viernes 15-1-2027, 09:00 en España (invierno, UTC+1)
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; realPrint("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local HL = 14 * 86400
local function decayed(t) return 2 ^ (-(math.floor(Stub.now) - t) / HL) end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end
local function near(a, b, tol, msg)
  if type(a) ~= "number" or math.abs(a - b) > (tol or 1e-9) then
    error((msg or "") .. ": esperado " .. tostring(b) .. " (± " .. tostring(tol) .. "), obtenido " .. tostring(a), 2)
  end
end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local function printed(sub) for _, line in ipairs(Stub.printed) do if has(line, sub) then return line end end return nil end

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
-- Sesión
---------------------------------------------------------------------------
local ns, Timing, History, Spec

local function boot(sv, skip)
  Stub.frames, Stub.timers = {}, {}
  for k, v in pairs(Stub.ahOriginals) do C_AuctionHouse[k] = v end
  _G.OroHermandadDB, _G.OroHermandadCharDB, _G.OroHermandadHist = sv and sv.db, sv and sv.cdb, sv and sv.hist
  ns = Stub.loadAddon(DIR, skip)
  Stub.fire("ADDON_LOADED", "OroHermandad")
  Timing, History, Spec = ns.Timing, ns.History, ns.Spec
end

local function I() return Timing.Internals() end
local function passDone(key) return I().passDone[key or History.CurrentMarket() or KEY] == true end
local function queueEmpty() local i = I(); return i.head > #i.queue end

local function login(wait)
  Stub.fire("PLAYER_LOGIN")
  Stub.fire("PLAYER_ENTERING_WORLD", true, false)
  if wait ~= false then assert(Stub.runUntil(function() return Timing and passDone() end, 200), "primera pasada") end
end

local function reload(skip)
  ns = Stub.reload(DIR, nil, nil, skip)
  Timing, History, Spec = ns.Timing, ns.History, ns.Spec
end

-- Medianoche en España (CET en enero) del día de t.
local function midnight(t)
  local _, hour = Spec.MadridSlot(t)
  return t - t % 3600 - hour * 3600
end
local D = 0 -- medianoche de hoy (se fija tras cada boot)

-- Punto con venta cuya mitad cae en la franja b del día D - k, con dt segundos: t = mitad + dt/2.
local function at(k, b, dt, minutes)
  return D - k * 86400 + (4 * b + 2) * 3600 + (minutes or 0) * 60 + math.floor((dt or 0) / 2)
end

-- Un escaneo de un compañero (o tuyo, "self") tal como lo avisan Relay/History: un punto por objeto y el final.
local function liveScan(obs, t, items)
  local ids = {}
  for id in pairs(items) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local it = items[id]
    History.NotifyPoint(KEY, obs, id, t, it.lo or 100, it.qty or 10, it.dt, it.sold)
  end
  History.NotifyDone(KEY, obs, t)
  assert(Stub.runUntil(queueEmpty, 60), "cola vacía")
end

local function item(id, key) local m = I().markets[key or KEY]; return m and m.items[id] end
local function blocksOf(id, key) return Timing.ItemBlocks(id, key or KEY, Stub.now) end

-- Días propios de un objeto con un valor por día: {[d] = lo} (lo = hi).
local function ownDays(id, values)
  local market = History.Market(KEY, true)
  local recs = {}
  for d, lo in pairs(values) do recs[#recs + 1] = {d = d, lo = lo, hi = lo, last = lo, qty = 10, scans = 1, src = "o"} end
  market.items[id] = market.items[id] or {n = "x", c = "metal", v = 0, d = "", p = ""}
  market.items[id].d = Spec.EncodeDays(recs)
  if Timing then I().refCache[KEY] = nil end
end

local function fresh()
  Stub.now, Stub.gameTime = BASE, 1000
  GetNormalizedRealmName = function() return "Forever" end
  boot()
  D = midnight(BASE)
end

---------------------------------------------------------------------------
-- 1. Regla C11 (timing-advice.json)
---------------------------------------------------------------------------
test("C11: Timing.Advice da lo mismo que el panel en cada caso de timing-advice.json (copia exacta)", function()
  eq(Stub.sha256File(V06 .. "timing-advice.json"), Stub.V06_SHA256["timing-advice.json"], "copia exacta (SHA-256)")
  fresh()
  local fx = json.decode(read(V06 .. "timing-advice.json"))
  local function plain(v) if v == json.null then return nil end return v end
  eq(Timing.SALES.minN, fx.sales.minN); eq(Timing.SALES.minDays, fx.sales.minDays); eq(Timing.SALES.minSec, fx.sales.minSec)
  eq(Timing.SALES.minBlocks, fx.sales.minBlocks); eq(Timing.SALES.minUnits, fx.sales.minUnits); eq(Timing.SALES.faster, fx.sales.faster)
  eq(Timing.PRICE.minBlocks, fx.price.minBlocks); eq(Timing.PRICE.spreadBp, fx.price.spreadBp)
  local n = 0
  for _, c in ipairs(fx.cases) do
    local blocks = {}
    for i, b in ipairs(c.blocks) do
      blocks[i] = {priceOK = b.priceOK, p = plain(b.p), n = b.n, days = b.days, sec = b.sec, u = b.u, mu = b.mu, msec = b.msec}
    end
    local a = Timing.Advice(blocks)
    for i = 1, 6 do
      eq(a.salesOK[i], c.salesOK[i], c.note .. ": salesOK " .. i)
      local want = plain(c.rateIdx[i])
      if want == nil then eq(a.rateIdx[i], nil, c.note .. ": rateIdx " .. i) else near(a.rateIdx[i], want, 1e-4, c.note .. ": rateIdx " .. i) end
    end
    eq(a.best, plain(c.best), c.note .. ": best"); eq(a.reason, c.reason, c.note .. ": reason")
    local hint = plain(c.hint)
    if hint == nil then eq(a.hint, nil, c.note .. ": hint") else eq(a.hint[1], hint[1], c.note); eq(a.hint[2], hint[2], c.note) end
    n = n + 1
  end
  eq(n, 12, "todos los casos")
end)

---------------------------------------------------------------------------
-- 2. Sumas: olvido, referencia de precio, franja de cada venta, mayor venta y días
---------------------------------------------------------------------------
test("Olvido: media vida de 14 días al leer, al sumar algo nuevo y al sumar algo de antes", function()
  fresh()
  local x = I()
  local it = x.newItem()
  local t0 = BASE
  x.addPrice(it, 2, t0, 1000)
  local b = x.blocksAt(it, t0 + 14 * 86400)[3]
  near(b.w, 0.5, 1e-12, "a los 14 días pesa la mitad"); near(b.p, 1000, 1e-9, "el índice no cambia")
  x.addPrice(it, 2, t0 + 14 * 86400, 0)
  eq(it.tRef, t0 + 14 * 86400)
  near(it.b[3].w, 1.5, 1e-12); near(it.b[3].sbp, 500, 1e-9, "lo de antes, a la mitad")
  x.addPrice(it, 2, t0, 300) -- de antes de tRef: entra ya olvidado
  near(it.b[3].w, 2.0, 1e-12); near(it.b[3].sbp, 650, 1e-9)
  eq(x.blocksAt(it, t0 + 14 * 86400)[3].priceOK, false, "2 escaneos: aún no (2,5)")
  x.addPrice(it, 2, t0 + 14 * 86400, 0)
  eq(x.blocksAt(it, t0 + 14 * 86400)[3].priceOK, true, "3: sí")
  -- Se guarda y se lee igual (texto corto, sin perder lo que cuenta).
  local back = x.decodeItem(x.encodeItem(it))
  near(back.b[3].w, it.b[3].w, 1e-3); near(back.b[3].sbp, it.b[3].sbp, 0.1); eq(back.tRef, it.tRef)
end)

test("Referencia de precio: mediana de los 7 días anteriores con 3 como mínimo; el punto va a la franja de su hora", function()
  fresh()
  login()
  local T = Spec.DayIndex(BASE)
  local x = I()
  ownDays(2772, {[T - 1] = 100, [T - 2] = 120})
  eq(x.refFor(KEY, 2772, T), nil, "2 días: sin referencia")
  ownDays(2772, {[T - 1] = 100, [T - 2] = 120, [T - 3] = 110, [T - 9] = 5000})
  eq(x.refFor(KEY, 2772, T), 110, "mediana de 100, 110 y 120 (el de hace 9 días no cuenta)")
  -- Un escaneo tuyo a las 21:30 (franja 20-24) a 121: +10 %.
  local t = D + 21 * 3600 + 1800
  liveScan("self", t, {[2772] = {lo = 121}})
  local b = blocksOf(2772)
  near(b[6].w, 1, 1e-9, "franja 20-24"); near(b[6].p, 1000, 1e-9, "+10 % = 1000 pb")
  eq(b[1].w, 0)
  -- Recorte a ±50 %.
  liveScan("self", t + 3600, {[2772] = {lo = 1000}})
  local f = 2 ^ (-3600 / HL)
  near(blocksOf(2772)[6].p, (1000 * f + 5000) / (f + 1), 1e-6, "un precio absurdo cuenta como +50 %")
end)

test("Ventas: van a la franja de la mitad del intervalo; la mayor de la franja y los dos días más nuevos", function()
  fresh()
  login()
  -- Escaneo a las 20:30 con dt 2 h: mitad a las 19:30, franja 16-20 (no 20-24).
  local t = D - 86400 + 20 * 3600 + 1800
  liveScan("aaaaaaaa", t, {[2770] = {dt = 7200, sold = 5}})
  local b = blocksOf(2770)
  local f = decayed(t - 3600)
  near(b[5].n, f, 1e-6, "franja 16-20"); eq(b[6].n, 0, "no la del punto")
  near(b[5].sec, 7200 * f, 1e-3); near(b[5].u, 5 * f, 1e-6)
  eq(b[5].days, 1)
  -- Otra el día anterior y otra más vieja: días = 2 (los dos más nuevos); la mayor, la de 30.
  liveScan("aaaaaaaa", t - 86400, {[2770] = {dt = 7200, sold = 30}})
  liveScan("aaaaaaaa", t - 3 * 86400, {[2770] = {dt = 7200, sold = 3}})
  local it = item(2770).b[5]
  eq(it.d1, Spec.DayIndex(t - 3600)); eq(it.d2, Spec.DayIndex(t - 86400 - 3600), "el de hace 3 días no")
  eq(it.mu, 30, "la mayor"); eq(it.msec, 7200)
  b = blocksOf(2770)
  eq(b[5].days, 2)
  near(b[5].mu, 30 * 2 ^ (-(Stub.now - it.mt) / (14 * 86400)), 1e-6, "la mayor, con el peso de su hora")
end)

test("Ventas en verano: los días son fechas de España (de 00:00 a 01:00 ya es el día siguiente), como en el panel", function()
  -- Mitades el domingo 12-7-2026 a las 02:00 y 03:00 y el lunes 13 a las 00:30 (hora de verano): franja 00-04 h. Con
  -- Spec.DayIndex serían el mismo día (2384) y el panel, que suma la celda del domingo y la del lunes, diría 2.
  Stub.now, Stub.gameTime = 1783915200, 1000 -- lunes 13-7-2026, 06:00
  GetNormalizedRealmName = function() return "Forever" end
  boot()
  login()
  for _, mid in ipairs({1783814400, 1783818000, 1783895400}) do
    liveScan("aaaaaaaa", mid + 1800, {[2770] = {dt = 3600, sold = 5}})
  end
  local it = item(2770).b[1]
  eq(it.d1, 2385, "el lunes"); eq(it.d2, 2384, "el domingo")
  eq(blocksOf(2770)[1].days, 2)
  near(blocksOf(2770)[1].n, 3, 0.2, "las tres (olvidadas un día)")
end)

test("Solapes: la de otro observador que se solapa más de la mitad no cuenta; del mismo sí; justo la mitad, también", function()
  fresh()
  login()
  local x = I()
  local A = {}
  x.bucketAdd(A, BASE, 1800, 1)
  eq(x.overlaps(A, BASE + 900, 1800, 2), false, "justo la mitad (900 de 1800): cuenta")
  eq(x.overlaps(A, BASE + 899, 1800, 2), true, "más de la mitad: no")
  eq(x.overlaps(A, BASE + 100, 1800, 1), false, "el mismo observador: cuenta")
  eq(x.overlaps(A, BASE + 1000, 3600, 2), true, "más de la mitad del más corto (1000 de 1800)")
  eq(x.overlaps(A, BASE + 1799 + 3600, 7200, 2), true, "una de 2 h que lo cubre entero, aunque su t esté 1 h después")
  eq(x.overlaps(A, BASE + 7200 + 1800, 7200, 2), false, "fuera")
  -- De punta a punta, con escaneos de compañeros.
  local t = at(1, 3, 1800, 60)
  liveScan("bbbbbbbb", t, {[2772] = {dt = 1800, sold = 300}})
  local before = x.stats.overlaps
  liveScan("cccccccc", t + 300, {[2772] = {dt = 1800, sold = 290}})
  eq(I().stats.overlaps, before + 1, "la de C se solapa con la de B (25 de 30 min)")
  liveScan("bbbbbbbb", t + 2700, {[2772] = {dt = 1800, sold = 7}})
  liveScan("eeeeeeee", t + 900, {[2772] = {dt = 1800, sold = 9}})
  eq(I().stats.overlaps, before + 1, "B otra vez y E justo a la mitad: cuentan")
  near(blocksOf(2772)[4].u, (300 + 7 + 9) * decayed(t), 0.5, "300 + 7 + 9 (sin los 290)")
end)

---------------------------------------------------------------------------
-- 3. Primera pasada
---------------------------------------------------------------------------
local function loadFixture()
  local env = {}
  local chunk = assert(loadstring(read(V06 .. "hist-v060.lua")))
  setfenv(chunk, env)
  chunk()
  return env
end

local GKEY = "GritodeGuerra-Alliance"
local FIX_NOW = 1796479200

local function bootFixture(sv)
  Stub.now, Stub.gameTime = FIX_NOW, 1000
  GetNormalizedRealmName = function() return "GritodeGuerra" end
  local env = sv or loadFixture()
  boot({db = env.OroHermandadDB or env.db, hist = env.OroHermandadHist or env.hist, cdb = env.cdb})
end

local function aggregates(key)
  local m = I().markets[key]
  local out = {}
  for id, it in pairs(m and m.items or {}) do out[id] = Timing.ItemBlocks(id, key, FIX_NOW + 3600) end
  return out
end
-- Lo mismo salvo el redondeo de lo guardado (3 cifras decimales): sumado una vez y no dos.
local function sameAggregates(a, b, msg)
  for id, blocks in pairs(a) do
    assert(b[id], msg .. ": falta " .. id)
    for i = 1, 6 do
      for _, f in ipairs({"w", "n", "sec", "u", "mu", "msec", "days"}) do
        local x, y = blocks[i][f], b[id][i][f]
        assert(math.abs(x - y) <= 1e-3 * math.max(1, math.abs(x)), msg .. ": " .. id .. " franja " .. i .. " " .. f .. " " .. x .. " / " .. y)
      end
    end
  end
  for id in pairs(b) do assert(a[id], msg .. ": sobra " .. id) end
end

test("Primera pasada con hist-v060.lua: lee lo tuyo (14 días) y lo de compañeros (72 h); de dos ventas solapadas, la de más tiempo", function()
  eq(Stub.sha256File(V06 .. "hist-v060.lua"), Stub.V06_SHA256["hist-v060.lua"])
  bootFixture()
  eq(passDone(GKEY), false, "aún no")
  login(false)
  Stub.advance(20)
  eq(passDone(GKEY), false, "a los 20 s aún no")
  assert(Stub.runUntil(function() return passDone(GKEY) end, 120), "a los 30 s")
  local m = I().markets[GKEY]
  -- 2770: tu venta (2700 s, 25) y la del compañero 47da174e (3000 s, 12) se solapan 30 min: queda la de 3000 s.
  local b2770 = Timing.ItemBlocks(2770, GKEY, FIX_NOW)
  local n, u = 0, 0
  for i = 1, 6 do n, u = n + b2770[i].n, u + b2770[i].u end
  near(n, 1, 0.01, "una venta en 2770"); near(u, 12, 0.05, "la del compañero")
  local _, _, block = Spec.MadridSlot(1796477400 - 1500)
  near(b2770[block + 1].n, 1, 0.01, "en la franja de su mitad")
  assert(I().stats.overlaps >= 2, "2770 y 2772: " .. I().stats.overlaps)
  -- Precios: con referencia (3 días o más antes), los puntos suman en su franja.
  local w = 0
  for i = 1, 6 do w = w + b2770[i].w end
  assert(w > 0, "precios sumados")
  -- Lo sumado queda apuntado: tuyos 14 días, compañeros 72 h.
  assert(m.seen.self[1796478300] and m.seen.self[1796148000], "tus escaneos")
  assert(m.seen["47da174e"][1796477400] and m.seen["47da174e"][1796241600], "del compañero (sus puntos son de las últimas 72 h)")
end)

test("Sin doble cuenta: salir antes de que la pasada termine no cambia nada y la siguiente suma una vez", function()
  bootFixture()
  login(false)
  assert(Stub.runUntil(function() return I().pass ~= nil end, 60), "pasada en marcha")
  eq(passDone(GKEY), false)
  reload()
  local saved = OroHermandadDB.timing and OroHermandadDB.timing[GKEY]
  local items = 0
  for _ in pairs(saved and saved.items or {}) do items = items + 1 end
  eq(items, 0, "nada sumado"); eq(next(saved and saved.seen or {}), nil, "ningún escaneo apuntado")
  login()
  local once = aggregates(GKEY)
  -- Otra sesión: no hay nada nuevo que sumar.
  reload()
  login()
  sameAggregates(aggregates(GKEY), once, "la tercera sesión no suma nada otra vez")
  -- Igual que hacerlo en una sola sesión.
  bootFixture()
  login()
  sameAggregates(aggregates(GKEY), once, "lo mismo que de una vez")
end)

test("Antes de la pasada, lo que llega en directo se descarta y la pasada lo lee una vez de lo guardado", function()
  fresh()
  local T = Spec.DayIndex(BASE)
  ownDays(2772, {[T - 1] = 100, [T - 2] = 100, [T - 3] = 100})
  local t = BASE - 600
  assert(History.RecordAggregate("full", {[2772] = {lo = 110, qty = 5, qty5 = 5}}, true, {t = t}))
  Stub.runUntil(function() return History.Pending() == 0 end, 10)
  assert(I().stats.dropped > 0, "descartado en directo")
  login()
  local _, _, block = Spec.MadridSlot(t)
  near(blocksOf(2772)[block + 1].w, decayed(t), 1e-6, "sumado una vez por la pasada")
  -- El mismo aviso otra vez (ya apuntado): nada.
  liveScan("self", t, {[2772] = {lo = 110}})
  near(blocksOf(2772)[block + 1].w, decayed(t), 1e-6, "no se suma dos veces")
end)

test("La pasada espera a que Relay esté quieto y a que el historial no esté escribiendo", function()
  fresh()
  local idle = ns.Relay.Idle
  ns.Relay.Idle = function() return false end
  login(false)
  Stub.advance(120)
  eq(passDone(), false, "Relay aplicando: espera")
  ns.Relay.Idle = idle
  local pending = History.Pending
  History.Pending = function() return 1 end
  Stub.advance(30)
  eq(passDone(), false, "historial escribiendo: espera")
  History.Pending = pending
  assert(Stub.runUntil(passDone, 30), "y luego sí")
end)

test("Una sesión sin Timing.lua seguida de una con él suma lo que se perdió, una vez", function()
  Stub.now, Stub.gameTime = BASE, 1000
  boot(nil, {["Timing.lua"] = true})
  eq(ns.Timing, nil)
  D = midnight(BASE)
  Stub.fire("PLAYER_LOGIN")
  Stub.runUntil(nil, 40)
  local T = Spec.DayIndex(math.floor(Stub.now))
  ownDays(2772, {[T - 1] = 100, [T - 2] = 100, [T - 3] = 100})
  local t = math.floor(Stub.now)
  assert(History.RecordAggregate("full", {[2772] = {lo = 120, qty = 5, qty5 = 5}}, true, {t = t}))
  Stub.runUntil(function() return History.Pending() == 0 end, 10)
  -- /cuando sin Timing.lua: el aviso de salir del juego.
  Stub.printed = {}
  SlashCmdList.OROHERMANDAD("cuando")
  assert(printed("tras actualizar el addon, sal del juego del todo y vuelve a entrar"), "aviso")
  reload()
  assert(ns.Timing, "ahora sí")
  login()
  local _, _, block = Spec.MadridSlot(t)
  near(blocksOf(2772)[block + 1].w, decayed(t), 1e-6, "sumado una vez")
  near(blocksOf(2772)[block + 1].p, 2000, 1e-6, "+20 %")
  reload()
  login()
  near(blocksOf(2772)[block + 1].w, decayed(t), 1e-3, "y no otra vez")
end)

test("Un compañero vuelto a aplicar tras salir de la memoria (tope de 40) no se cuenta dos veces", function()
  fresh()
  login()
  local t = at(1, 4, 3600)
  liveScan("abcdef01", t, {[2772] = {dt = 3600, sold = 8}, [2770] = {dt = 3600, sold = 2}})
  local before = dump({blocksOf(2772), blocksOf(2770)})
  local skipped = I().stats.skippedSeen
  -- Se le echa (History.ShrinkObs o el tope de 40) y su escaneo vuelve a llegar en una puesta al día.
  local market = History.Market(KEY, true)
  if market.obs then market.obs.abcdef01 = nil end
  liveScan("abcdef01", t, {[2772] = {dt = 3600, sold = 8}, [2770] = {dt = 3600, sold = 2}})
  eq(dump({blocksOf(2772), blocksOf(2770)}), before, "igual")
  eq(I().stats.skippedSeen, skipped + 2, "los dos puntos saltados")
  -- Ese conjunto se guarda (4 días de compañeros) y sobrevive a /reload.
  reload()
  login()
  assert(OroHermandadDB.timing[KEY].seen.abcdef01:find(tostring(t), 1, true), "apuntado")
end)

test("Al salir, el escaneo que se estaba sumando se termina; los que aún no habían empezado quedan para la pasada", function()
  fresh()
  login()
  local units = Timing.UNITS
  Timing.UNITS = 5
  local t1, t2 = at(1, 2, 0), at(1, 3, 0)
  local T = Spec.DayIndex(math.floor(Stub.now))
  local items = {}
  for i, id in ipairs(History.FixedIDs()) do
    if i <= 20 then items[id] = {lo = 100}; ownDays(id, {[T - 2] = 100, [T - 3] = 100, [T - 4] = 100}) end
  end
  -- Lo que avisaría Relay: 20 puntos y el final de un compañero; después, otro escaneo que aún no ha empezado.
  local ids = {}
  for id in pairs(items) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do History.NotifyPoint(KEY, "aaaa0001", id, t1, 100, 10) end
  History.NotifyDone(KEY, "aaaa0001", t1)
  for _, id in ipairs(ids) do History.NotifyPoint(KEY, "aaaa0002", id, t2, 100, 10) end
  History.NotifyDone(KEY, "aaaa0002", t2)
  -- Una sola tanda (5 puntos del primero).
  table.sort(Stub.timers, function(a, b) return a.at < b.at end)
  local first = table.remove(Stub.timers, 1)
  first.fn()
  eq(I().head, 6, "5 sumados")
  Timing.UNITS = units
  reload()
  local seen = OroHermandadDB.timing[KEY].seen
  assert(seen.aaaa0001 and seen.aaaa0001:find(tostring(t1), 1, true), "el empezado, terminado y apuntado")
  eq(seen.aaaa0002, nil, "el otro no")
  login()
  local _, _, b1 = Spec.MadridSlot(t1)
  local _, _, b2 = Spec.MadridSlot(t2)
  for _, id in ipairs(ids) do
    near(blocksOf(id)[b1 + 1].w, decayed(t1), 1e-3, "los 20 del primero, una vez: " .. id)
  end
  eq(blocksOf(ids[1])[b2 + 1].w, 0, "el segundo no estaba guardado en History (solo avisado): no se inventa")
end)

---------------------------------------------------------------------------
-- 4. Consejo de punta a punta: una ballena o dos personas que miden la misma compra no cambian la mejor franja
---------------------------------------------------------------------------
-- 6 días con una venta de 1 h en las franjas 08-12, 12-16, 16-20 y 20-24 (2, 3, 4 y 10 unidades) de dos objetos.
local function pattern(ids)
  for k = 1, 6 do
    for b, sold in pairs({[2] = 2, [3] = 3, [4] = 4, [5] = 10}) do
      local scan = {}
      for _, id in ipairs(ids) do scan[id] = {dt = 3600, sold = sold} end
      liveScan("aaaaaaaa", at(k, b, 3600), scan)
    end
  end
end

test("Consejo: el patrón de ventas manda; una ballena y dos personas que miden la misma compra no lo cambian", function()
  fresh()
  login()
  pattern({2772, 2770})
  local a = Timing.Advice(blocksOf(2772))
  eq(a.best, 5); eq(a.reason, "ventas"); eq(a.hint[1], 19); eq(a.hint[2], 20)
  -- Una ballena de 400 unidades en 08-12.
  liveScan("dddddddd", at(1, 2, 1800, 60), {[2772] = {dt = 1800, sold = 400}})
  local whale = Timing.Advice(blocksOf(2772))
  eq(whale.best, 5, "la ballena no cambia la mejor franja"); eq(whale.reason, "ventas")
  -- Dos personas miden la misma compra grande en 12-16: la segunda no cuenta y la primera es la mayor de la franja.
  liveScan("bbbbbbbb", at(1, 3, 1800, 60), {[2772] = {dt = 1800, sold = 300}})
  liveScan("cccccccc", at(1, 3, 1800, 65), {[2772] = {dt = 1800, sold = 290}})
  local two = Timing.Advice(blocksOf(2772))
  eq(two.best, 5, "ni dos que miden lo mismo"); eq(two.reason, "ventas")
end)

---------------------------------------------------------------------------
-- 5. Vista, descripción, cobertura y «Capas»
---------------------------------------------------------------------------
test("Vista /oro cuando: tabla (Precio, Ventas, Medido, Escaneos), mejor franja, tus ventas y una línea por objeto", function()
  fresh()
  login()
  pattern({2772, 2770})
  -- Tus ventas (solo en este PC): 3 en 20-24 y 1 en 16-20 de hace dos días.
  local s = {}
  for _, b in ipairs({5, 5, 5, 4}) do s[#s + 1] = at(2, b, 0) .. ",2772,155,0,3,7200" end
  OroHermandadDB.sales[KEY] = table.concat(s, ";")
  local title, text, line = Timing.View("")
  eq(title, "Oro de Hermandad · cuándo vender")
  local lines = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  eq(lines[1], "Cuándo vender · tu hermandad · últimas semanas (hora de España)")
  eq(lines[2], "Franja        00-04   04-08   08-12   12-16   16-20   20-24")
  eq(lines[3], "Precio            —       —       —       —       —       —", "sin referencia de precio")
  assert(lines[4]:match("^Ventas            —       —    ×0,%d    ×0,%d    ×%d,%d    ×%d,%d$"), lines[4])
  assert(lines[5]:match("^Medido          0 h     0 h     %d h     %d h     %d h     %d h$"), lines[5])
  eq(lines[6], "Escaneos          0       0       0       0       0       0", "sin precios no hay escaneos con precio")
  eq(lines[7], "Mejor franja para vender: 20-24 h (más ventas). Pon o iguala el precio hacia las 19-20 h, con 2 h (u 8 h si no vas a volver).")
  eq(lines[8], "Tus ventas (28 días): 20-24 h 3 · 16-20 h 1 (veces que se vendió algo tuyo).")
  assert(has(lines[9], "«—» = pocos datos: hacen falta 3 mediciones en 2 días distintos") and has(lines[9], "estimación")
    and has(lines[9], "El depósito de 8 h es 4 veces el de 2 h; el de 24 h, 12 veces."), lines[9])
  assert(has(text, "\nMetal:\n  Hierro: 20-24 h, más ventas ×"), text)
  eq(line, "cuándo vender: 20-24 h (más ventas). Pon o iguala el precio hacia las 19-20 h, con 2 h (u 8 h si no vas a volver).")
  -- Un objeto: su tabla.
  local _, one = Timing.View("hierro")
  assert(has(one, "Cuándo vender · Hierro · últimas semanas (hora de España)") and has(one, "Ventas            —       —    ×"), one)
  assert(has(one, "Tus ventas (28 días): 20-24 h 3 · 16-20 h 1"), one)
  -- Medido: segundos en horas, redondeado a media hora.
  local b = blocksOf(2772)
  assert(has(lines[5], tostring(math.floor(b[6].sec / 1800 + 0.5) / 2):gsub("%.0$", ""):gsub("%.", ",") .. " h"), lines[5])
end)

test("/oro cuando con nombre (sin tildes), número o enlace; la descripción del objeto; un objeto sin datos", function()
  fresh()
  login()
  pattern({2772})
  for _, arg in ipairs({"hierro", "HIERRO", "2772", "|cffffffff|Hitem:2772::::::::32:::::|h[Hierro]|h|r"}) do
    Stub.printed = {}
    SlashCmdList.OROHERMANDAD("cuando " .. arg)
    assert(printed("Oro de Hermandad:|r Hierro: 20-24 h (más ventas)"), arg .. ": " .. tostring(Stub.printed[1]))
    assert(has(_G.OroHermandadTextFrame.text, "Cuándo vender · Hierro"), arg)
  end
  Stub.printed = {}
  SlashCmdList.OROHERMANDAD("cuando zanahoria")
  assert(printed("no encuentro «zanahoria» entre los objetos vigilados"), Stub.printed[1])
  eq(Timing.TooltipLine(2772), "Cuándo vender: 20-24 h (más ventas)")
  eq(Timing.TooltipLine(3575), "Cuándo vender: aún pocos datos", "vigilado sin datos")
  eq(Timing.TooltipLine(5000), nil, "no vigilado")
  -- En la descripción (Core, con su caché de 30 s).
  local tip = _G.GameTooltip
  tip.__lines = {}
  Stub.tooltipPost(tip, {id = 2772})
  assert(has(table.concat(tip.__lines, " | "), "Cuándo vender: 20-24 h (más ventas)"), table.concat(tip.__lines, " | "))
  -- La ventana: el botón «Cuándo vender» abre la vista.
  _G.OroHermandadFrame.cuandoButton.__scripts.OnClick(_G.OroHermandadFrame.cuandoButton)
  assert(has(_G.OroHermandadTextFrame.text, "Cuándo vender · tu hermandad"), "botón")
end)

test("Cobertura de una franja (la usa la propuesta «franja con pocos datos»)", function()
  fresh()
  login()
  eq(Timing.Coverage(KEY, 2), 0, "sin datos")
  local T = Spec.DayIndex(BASE)
  ownDays(2772, {[T - 1] = 100, [T - 2] = 100, [T - 3] = 100})
  ownDays(2770, {[T - 1] = 100, [T - 2] = 100, [T - 3] = 100})
  for k = 0, 2 do liveScan("self", D + 9 * 3600 + k * 1800 - 3600 * 0, {[2772] = {lo = 100}}) end
  liveScan("self", D + 9 * 3600 + 3 * 1800, {[2770] = {lo = 100}})
  near(Timing.Coverage(KEY, 2), (3 + 1) / 2, 0.01, "media de w de los fijos con datos")
  eq(Timing.Coverage(KEY, 5), 0)
  -- La propuesta del escáner con la subasta abierta y nadie escaneó hace poco no: franja con pocos datos.
  local market = History.Market(KEY, true)
  market.obs = market.obs or {}
  local now = math.floor(Stub.now)
  market.obs.abcdabcd = {seen = now - 60, s = tostring(now - 60), items = {[2772] = {d = "", p = ""}}}
  OroHermandadDB.scanner.recorded[KEY] = now - 2000
  Stub.openAH()
  Stub.advance(3)
  local p = ns.Scanner.Proposal()
  assert(p and p.reason == "thin" and p.text == "La franja 8-12 h tiene pocos datos para «Cuándo vender».", p and p.text)
  Stub.closeAH()
end)

test("«Capas»: pares de escaneos tuyos y de compañeros a menos de 10 min y cuántos coinciden en el precio", function()
  fresh()
  login()
  local market = History.Market(KEY, true)
  local t = BASE - 3600
  market.items[2772] = {n = "Hierro", c = "metal", v = 0, d = "", p = Spec.EncodePoints({{t = t, lo = 150, qty = 10, qty5 = 5}})}
  market.items[2770] = {n = "Cobre", c = "metal", v = 0, d = "", p = Spec.EncodePoints({{t = t, lo = 30, qty = 10, qty5 = 5}})}
  market.obs = {
    ["11112222"] = {seen = t, s = tostring(t + 300), items = {
      [2772] = {d = "", p = Spec.EncodePoints({{t = t + 300, lo = 150, qty = 9, qty5 = 5}})},
      [2770] = {d = "", p = Spec.EncodePoints({{t = t + 300, lo = 31, qty = 9, qty5 = 5}})}}},
    ["33334444"] = {seen = t, s = tostring(t + 2000), items = {
      [2772] = {d = "", p = Spec.EncodePoints({{t = t + 2000, lo = 150, qty = 9, qty5 = 5}})}}},
  }
  eq(Timing.LayerLine(KEY), "Capas: 1 par de escaneos tuyos y de compañeros a menos de 10 min; mismo precio más bajo en 1 de 2 objetos.")
  local probe = table.concat(Timing.ProbeLines(), "\n")
  assert(has(probe, "Cuándo vender: ") and has(probe, "primera pasada hecha") and has(probe, "Capas: 1 par"), probe)
end)

---------------------------------------------------------------------------
-- 6. Rendimiento, combate, guardado y privacidad
---------------------------------------------------------------------------
test("Tandas de 1,5 ms: primera pasada con 40 compañeros y 161 objetos, y un escaneo de 161 objetos en directo", function()
  Stub.now, Stub.gameTime = BASE, 1000
  GetNormalizedRealmName = function() return "Forever" end
  D = midnight(BASE)
  -- 40 compañeros con 15 días y 24 puntos con venta en cada objeto de la lista fija.
  local hist = {schema = 2, addon = "0.6.0", markets = {[KEY] = {items = {}, dep = {}, obs = {}}}}
  local T = math.floor((BASE - 1577833200) / 86400)
  local fixed = {}
  do
    local probe = {}
    assert(loadfile(DIR .. "Data.lua"))("OroHermandad", probe)
    for _, cat in ipairs(probe.Data.CATEGORY_ORDER) do for _, id in ipairs(probe.Data.WATCH[cat] or {}) do fixed[#fixed + 1] = id end end
  end
  local function days(seed)
    local parts = {}
    for d = T - 14, T do local p = 100 + (seed + d) % 50; parts[#parts + 1] = table.concat({d, p, p + 5, p, 20, 2, "o"}, ",") end
    return table.concat(parts, ";")
  end
  for o = 1, 40 do
    local h = string.format("%08x", 0x20000000 + o * 7919)
    local items = {}
    for i, id in ipairs(fixed) do
      local pts = {}
      for k = 1, 24 do pts[#pts + 1] = table.concat({BASE - 72 * 3600 + k * 10700 + o, 100 + (i + k) % 40, 30, 10, 1800, k % 5}, ",") end
      items[id] = {d = days(i * o), p = table.concat(pts, ";")}
    end
    hist.markets[KEY].obs[h] = {seen = BASE - 600, s = tostring(BASE - 600), items = items}
  end
  boot({hist = hist})
  collectgarbage("collect")
  -- Como en test_relay: cada tanda de Timing se mide con la basura ya recogida (fuera de la medida) y el recolector
  -- parado (sus pausas y la memoria nueva del proceso de pruebas no son del addon); solo las tandas de Timing.
  _G.debugprofilestop = function() return os.clock() * 1000 end
  local after, maxMs, ticks, skipFirst = C_Timer.After, 0, 0, true
  C_Timer.After = function(delay, fn)
    local info = debug.getinfo(2, "S")
    local mine = info and info.short_src:find("Timing.lua", 1, true) ~= nil
    after(delay, function()
      if mine then collectgarbage("collect"); collectgarbage("stop") end
      local t0 = os.clock()
      fn()
      if mine then
        local ms = (os.clock() - t0) * 1000
        ticks = ticks + 1
        -- La tanda que empieza la pasada es la primera que pide memoria tras montar los 40 compañeros: paga que el
        -- sistema devuelva memoria al proceso de pruebas (como en test_relay, no se cuenta).
        if skipFirst and Timing.Internals().pass then skipFirst = false
        elseif ms > maxMs then maxMs = ms end
      end
    end)
  end
  local ok, err = pcall(function()
    login()
    local passMax, passTicks = maxMs, ticks
    maxMs = 0
    local agg = {}
    for i, id in ipairs(fixed) do agg[id] = {lo = 100 + i, qty = 30, qty5 = 10} end
    assert(History.RecordAggregate("full", agg, true, {t = math.floor(Stub.now)}))
    assert(Stub.runUntil(function() return History.Pending() == 0 and queueEmpty() end, 60))
    realPrint(string.format("  primera pasada con 40 compañeros: %d tandas, la más larga %.2f ms; escaneo de %d objetos en directo: %.2f ms",
      passTicks, passMax, #fixed, maxMs))
    assert(passMax < 2, string.format("primera pasada: %.2f ms", passMax))
    assert(maxMs < 2, string.format("en directo: %.2f ms", maxMs))
    assert(passDone(), "hecha")
  end)
  C_Timer.After, _G.debugprofilestop = after, nil
  collectgarbage("restart")
  if not ok then error(err, 0) end
end)

test("Nunca en combate ni con el historial escribiendo; se sigue al terminar", function()
  fresh()
  login()
  Stub.combat = true
  local t = at(1, 4, 3600)
  for _, id in ipairs({2772, 2770}) do History.NotifyPoint(KEY, "aaaaaaaa", id, t, 100, 10, 3600, 5) end
  History.NotifyDone(KEY, "aaaaaaaa", t)
  Stub.advance(5)
  eq(I().head, 1, "nada en combate")
  Stub.combat = false
  local pending = History.Pending
  History.Pending = function() return 1 end
  Stub.advance(5)
  eq(I().head, 1, "nada con el historial escribiendo")
  History.Pending = pending
  assert(Stub.runUntil(queueEmpty, 5), "al terminar")
  near(blocksOf(2772)[5].u, 5 * decayed(t - 1800), 1e-6)
end)

test("Guardado: 64 KB por mercado (fuera lo que lleva más tiempo sin nada) y 4 mercados como mucho", function()
  fresh()
  login()
  local m = I().markets[KEY]
  local x = I()
  for id = 1000, 1600 do
    local it = x.newItem()
    for b = 0, 5 do
      x.addPrice(it, b, BASE - id, 123.456)
      x.addSale(it, b, BASE - id - 10, 3600, 17)
    end
    m.items[id] = it
  end
  m.dirty = true
  Timing.BeforeSave()
  local total = 0
  local kept = 0
  for id, text in pairs(OroHermandadDB.timing[KEY].items) do total, kept = total + #text + 12, kept + 1 end
  for _, text in pairs(OroHermandadDB.timing[KEY].seen) do total = total + #text + 12 end
  assert(total <= 64 * 1024, "64 KB: " .. total)
  assert(kept < 601 and OroHermandadDB.timing[KEY].items[1000] and not OroHermandadDB.timing[KEY].items[1600],
    "fuera los más viejos: " .. kept)
  for i = 1, 5 do
    OroHermandadDB.timing["Reino" .. i .. "-Horde"] = {t = BASE - i * 1000, items = {}, seen = {}}
  end
  Timing.BeforeSave()
  local n = 0
  for _ in pairs(OroHermandadDB.timing) do n = n + 1 end
  eq(n, 4, "4 mercados")
  assert(OroHermandadDB.timing[KEY], "el actual se queda")
  -- Lo guardado se vuelve a leer igual.
  local before = Timing.ItemBlocks(1000, KEY, BASE)
  reload()
  local after = Timing.ItemBlocks(1000, KEY, BASE)
  for b = 1, 6 do near(after[b].w, before[b].w, 1e-3); near(after[b].u, before[b].u, 0.05) end
end)

test("Privacidad: lo guardado de «Cuándo vender» solo lleva cifras, «self» y códigos de 8 cifras", function()
  fresh()
  login()
  pattern({2772})
  liveScan("self", at(0, 1, 0), {[2772] = {lo = 100}})
  reload()
  local text = dump(OroHermandadDB.timing)
  for _, name in ipairs({"Javi", "Vendedor", "Pujador", "Ána", "Borja"}) do assert(not has(text, name), name) end
  for obs in pairs(OroHermandadDB.timing[KEY].seen) do assert(obs == "self" or obs:match("^%x%x%x%x%x%x%x%x$"), obs) end
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

test("Ningún fallo interno de «Cuándo vender»", function()
  eq(Timing.lastError, nil)
end)

realPrint(string.format("cuándo vender: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

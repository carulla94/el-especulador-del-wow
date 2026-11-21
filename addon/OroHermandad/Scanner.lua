-- Oro de Hermandad: escáner propio de la subasta (0.6.0). Auctionator ya no hace falta para tener precios.
-- Lee la subasta entera (C_AuctionHouse.ReplicateItems, el «escaneo completo») con un presupuesto de 1,5 ms por
-- fotograma, reconoce si es la subasta de tu facción o la neutral de los goblins (que es otro mercado: de allí no se
-- guardan precios ni ventas, solo el número de las subastas que creas para no confundir sus avisos de venta con los de
-- aquí), decide qué escaneos se graban en el historial (uno cada 30 min y 8 al día por mercado), estima lo que se vendió
-- entre dos escaneos del mismo personaje (Spec.InferSold), apunta tus ventas y tus compras (solo en este PC) y guarda
-- una caché con el precio más bajo de todo lo visto. También «Escanear la lista»: una búsqueda por objeto vigilado,
-- solo cuando lo pides (molesta en las pestañas Comprar y Vender, así que nunca va sola).
-- Las peticiones se ven con un gancho en C_AuctionHouse.ReplicateItems (las tuyas, las de Auctionator y las de otros
-- addons): la respuesta (REPLICATE_ITEM_LIST_UPDATE) solo se escucha durante 60 s tras una petición, porque el cliente
-- también lanza ese evento por cada subasta cuyos datos de objeto llegan después (miles por fotograma). Una respuesta
-- con la misma huella que la última leída no es un escaneo nuevo.
-- Invisible: nada en el chat salvo respuestas a comandos y, en modo «proponer» con la ventana cerrada, una línea por
-- visita (y como mucho cada 30 min). Nunca llama a funciones protegidas (publicar, comprar, pujar, cancelar): los
-- ganchos solo miran. Los nombres de vendedores, compradores y pujadores nunca se guardan ni se envían: el dueño de una
-- fila solo se compara en memoria con tu nombre para que tus subastas no cuenten como precio de mercado, y el texto de
-- los avisos de venta no se guarda. Los fallos van a Scanner.lastError (/oro sondeo).
-- Core le pasa los eventos de la subasta (Scanner.OnShow, OnClose, OnReplicate, ...) con sus llamadas protegidas: tras
-- actualizar con solo un /reload este archivo no se carga y el addon sigue como la 0.5.1.
local _, ns = ...
local Data, Items, Spec, History = ns.Data, ns.Items, ns.Spec, ns.History
local Scanner = {}
ns.Scanner = Scanner

Scanner.THROTTLE = 905          -- la subasta deja un escaneo completo cada 15 min por cuenta (y 5 s de margen)
Scanner.WINDOW = 60             -- segundos que se espera la respuesta tras pedir la subasta entera
Scanner.SETTLE = 1              -- desde el primer aviso de la respuesta hasta leerla (llega a trozos)
Scanner.BUDGET_MS = 1.5         -- lectura: ms por fotograma como mucho
Scanner.CHECK_ROWS = 64         -- filas entre dos miradas al reloj
Scanner.ROWS_PER_STEP = 256     -- sin debugprofilestop
Scanner.FINISH_UNITS = 16       -- al cerrar el escaneo, sin debugprofilestop: objetos por tanda
Scanner.RECORD_GAP = 1800       -- un escaneo grabado cada 30 min por mercado
Scanner.RECORD_PER_DAY = 8      -- y 8 al día
Scanner.SAMPLE_MIN, Scanner.SAMPLE_MAX = 905, 7200 -- ventas solo entre dos escaneos de 15 min a 2 h de distancia
Scanner.PAIR_MAX = 6600         -- la «pareja» se propone hasta 1 h 50 min después del primero
Scanner.HOLD = 600              -- un resumen de Auctionator espera 10 min por si llega el escaneo completo
Scanner.TICK = 60               -- con la subasta abierta, se revisa cada minuto
Scanner.BUSY = 15               -- sin peticiones solas en los 15 s siguientes a publicar, comprar o cancelar
Scanner.OPEN_DELAY = 2          -- ni en los 2 primeros segundos (la subasta pide favoritos y pujas al abrirse)
Scanner.READY_POLL, Scanner.READY_WAIT, Scanner.SUMMARY_WAIT = 0.5, 10, 120
Scanner.TIMEOUTS = 3            -- 3 peticiones propias sin respuesta seguidas: «no responde» hasta el /reload
Scanner.EARLY = 5               -- una petición hecha mientras se abre la subasta (antes de AUCTION_HOUSE_SHOW) vale 5 s
Scanner.OWN_MISSES = 2          -- 2 escaneos seguidos sin tus subastas (y con alguna a la venta): no se miden ventas
Scanner.OWNED_MAX = 200         -- subastas tuyas que se miran en GetOwnedAuctionInfo como mucho (un fotograma)
Scanner.DROP_RESEND = 5
Scanner.CHAT_SPACING = 1800
Scanner.STALE = 1800
Scanner.BASE_LEVELS, Scanner.BASE_AUCTIONS, Scanner.BASE_BYTES, Scanner.BASE_MARKETS = 40, 200, 400 * 1024, 2
Scanner.PRICE_ENTRIES, Scanner.PRICE_BYTES, Scanner.PRICE_DAYS = 40000, 900000, 21
Scanner.SALES_DAYS, Scanner.SALES_MAX, Scanner.SALES_MARKETS = 28, 2000, 4
Scanner.BUYS_SECONDS, Scanner.BUYS_MAX = 7200 + 600, 300
Scanner.POST_SECONDS, Scanner.POST_REPEAT = 300, 5
Scanner.POST_FLIGHT = 2         -- una publicación nueva descarta las pendientes de hace más de 2 s (no se crearon)
Scanner.OTHER_MAX = 200         -- subastas creadas en la neutral (o en una que no se sabe) que se recuerdan como mucho
Scanner.SWEEP_SPACING, Scanner.SWEEP_KEY_WAIT, Scanner.SWEEP_ANSWER, Scanner.SWEEP_POLL = 1.2, 2, 5, 0.5
Scanner.ZONES_MAX, Scanner.DEPREF_MARKETS, Scanner.VISITED_MAX = 32, 4, 16

local BAND_FALLBACK = {0, 1800, 7200, 43200}
local DURATION_HOURS = {2, 8, 24}
local PET_CAGE = 82800
local ID_MAX = 2147483647
local SOLD, EXPIRED = 4, 5      -- Enum.AuctionHouseNotification.AuctionSold / AuctionExpired
local ACTIVE = 0                -- Enum.AuctionStatus.Active (1 = Sold: vendida, esperando en el correo)
local TIME_MAX = Spec.TIME_MAX

local floor, max, min = math.floor, math.max, math.min
local isInt = Spec.IsInt

Scanner.lastError = nil
Scanner.hooked = nil            -- true si el gancho de ReplicateItems está puesto (false: no se pudo)

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------
local function protect(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then Scanner.lastError = label .. ": " .. tostring(err) end
  return ok, err
end

local function now() return History.Now() end

local function clock()
  if type(GetTime) == "function" then
    local ok, t = pcall(GetTime)
    if ok and type(t) == "number" then return t end
  end
  return 0
end

local function after(seconds, fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then C_Timer.After(seconds, fn) end
end

local isSecret = type(issecretvalue) == "function" and issecretvalue or nil
local function readable(value)
  if isSecret and isSecret(value) then return nil end
  return value
end

local function api() return type(C_AuctionHouse) == "table" and C_AuctionHouse or nil end

-- pcall de C_AuctionHouse[name]: ok y lo que devuelva (false si no existe).
local function ah(name, ...)
  local a = api()
  if not a or type(a[name]) ~= "function" then return false end
  return pcall(a[name], ...)
end

local function hhmm(t)
  if type(date) ~= "function" or not t then return "--:--" end
  local ok, text = pcall(date, "%H:%M", t)
  return ok and text or "--:--"
end

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

local function minutesOrHours(seconds)
  local minutes = floor(max(0, seconds) / 60)
  if minutes < 120 then return minutes .. " min" end
  return floor(minutes / 60) .. " h"
end

local function market() return History.CurrentMarket() end
local validMarket = History.ValidMarketKey

-- FNV-1a de 32 bits (el de Relay.lua, sin la librería bit): 8 cifras hexadecimales en minúsculas.
local XOR4 = {}
for a = 0, 15 do
  for b = 0, 15 do
    local out, bit, x, y = 0, 1, a, b
    for _ = 1, 4 do
      if x % 2 ~= y % 2 then out = out + bit end
      x, y, bit = floor(x / 2), floor(y / 2), bit * 2
    end
    XOR4[a * 16 + b] = out
  end
end
local function fnv(text)
  local h = 2166136261
  for i = 1, #text do
    local low = h % 256
    local byte = text:byte(i)
    h = h - low + XOR4[floor(low / 16) * 16 + floor(byte / 16)] * 16 + XOR4[(low % 16) * 16 + byte % 16]
    h = (h * 403 + (h % 256) * 16777216) % 4294967296
  end
  return string.format("%04x%04x", floor(h / 65536), h % 65536)
end
Scanner.Fnv1a32 = fnv

---------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------
local db, cdb                   -- OroHermandadDB y OroHermandadCharDB
local S, cs                     -- db.scanner y cdb.scanner
local cb = {}                   -- llamadas de Core: listen, onScanDone, onSummaryRelease, onState, say, windowShown
local hooksInstalled = false
local ahOpen, showAt, visitToken, visitScanned = false, -math.huge, 0, false
local house, houseInfo = nil, {}
local visitHouse = nil          -- la casa de la última visita (sigue tras cerrar, hasta el siguiente AUCTION_HOUSE_SHOW)
local early = nil               -- {t, ours, at}: petición vista con la subasta aún cerrada (se está abriendo)
local sending, resendNext = false, false
local req = nil                 -- {t, ours, resent}: la última petición vista con la subasta abierta
local windowOpen, windowToken, events, firstAt, firstT, settleFor = false, 0, 0, nil, nil, -1
local reading = nil             -- lectura en marcha
local queued = nil              -- petición propia esperando a la subasta
local phase = nil               -- "queued", "requested", "other", "reading" o nil
local result = nil              -- {state, at, ...}: lo último que pasó (done, done-refresh, timeout, noresponse, interrupted)
local noresponse, sessionTimeouts = false, 0
local lastUserAction = nil
local held = {}                 -- mercado -> resumen de Auctionator retenido {t, rows, data, market, at}
local chattedVisit, lastChat = false, nil
local sweep = nil               -- «Escanear la lista» en marcha
local pending = {}              -- publicaciones vistas y aún sin subasta creada
local sessionAuctions = {}      -- auctionID -> true: subastas seguidas creadas en esta sesión (desde que se cargó)
local depRefDay = {}            -- mercado -> día en que se tomaron las referencias de depósito en esta sesión
local stats = {otherRequests = 0, otherUnanswered = 0, strayRejected = 0, timeouts = 0, requestsWhileReading = 0,
               priceDecodes = 0, queries = 0}
local listening = false

local function notify()
  if cb.onState then protect("ventana", cb.onState) end
end

local function listen(on)
  listening = on and true or false
  if cb.listen then protect("evento", cb.listen, listening) end
end

---------------------------------------------------------------------------
-- Datos guardados: limpieza al cargar (un tipo equivocado reinicia solo esa tabla)
---------------------------------------------------------------------------
local function cleanMap(map, keyOK, valueOK, cap)
  local out, n = {}, 0
  for k, v in pairs(type(map) == "table" and map or {}) do
    if keyOK(k) and valueOK(v) and (not cap or n < cap) then out[k] = v; n = n + 1 end
  end
  return out
end

local function isTime(v) return isInt(v, 1, TIME_MAX) end
local function isDayCount(v) return type(v) == "string" and v:match("^%d+:%d+$") ~= nil end
local function isZone(k) return isInt(k, 1, 999999) end
local function isTrue(v) return v == true end
local function isRefs(v) return type(v) == "string" and #v <= 200 and v:match("^[%d:,]+$") ~= nil end

local function sanitizeScanner(s)
  s = type(s) == "table" and s or {}
  if s.auto ~= "propose" and s.auto ~= "auto" and s.auto ~= "off" then s.auto = "propose" end
  if type(s.sales) ~= "boolean" then s.sales = true end
  for _, key in ipairs({"lastOwnRequest", "lastSuccess", "lastAnyRequest"}) do
    if not isTime(s[key]) then s[key] = nil end
  end
  if type(s.fp) ~= "string" or not s.fp:match("^%x%x%x%x%x%x%x%x$") then s.fp = nil end
  if not isInt(s.timeouts, 0, 1000000) then s.timeouts = 0 end
  if s.bandOffset ~= 0 and s.bandOffset ~= 1 then s.bandOffset = nil end
  s.recorded = cleanMap(s.recorded, validMarket, isTime)
  s.recordedDay = cleanMap(s.recordedDay, validMarket, isDayCount)
  s.houseZones = cleanMap(s.houseZones, isZone, isTrue, Scanner.ZONES_MAX)
  s.depRef = cleanMap(s.depRef, validMarket, isRefs, Scanner.DEPREF_MARKETS)
  s.visited = cleanMap(s.visited, validMarket, isTime, Scanner.VISITED_MAX)
  s.sampledUntil = cleanMap(s.sampledUntil, validMarket, isTime, Scanner.VISITED_MAX)
  if type(s.buys) ~= "string" or not s.buys:match("^[%d,;]*$") then s.buys = "" end
  return s
end

local function sanitizePrices(p)
  return cleanMap(p, validMarket, function(v)
    return type(v) == "table" and isTime(v.t) and type(v.text) == "string" and v.text:match("^[%d:,]*$") ~= nil
  end)
end

local function sanitizeSales(p)
  return cleanMap(p, validMarket, function(v) return type(v) == "string" and v:match("^[%d,;]*$") ~= nil end)
end

-- ",s" al final: una subasta de mercancía que ya avisó de una venta (sigue para la línea de ventas, pero ya no cuenta
-- como subasta tuya que debería salir en el escaneo).
local function isAuction(v)
  return type(v) == "string" and #v <= 120 and (v:match("^%d+,%d+,%d+,%d,%d+,[^,]+,[ci]$") ~= nil
    or v:match("^%d+,%d+,%d+,%d,%d+,[^,]+,c,s$") ~= nil)
end

-- Referencia de ventas: {t = hora del escaneo (el primer aviso de la respuesta), q = hora de su petición, off, items}.
local function sanitizeBase(p)
  return cleanMap(p, validMarket, function(v)
    if type(v) ~= "table" or not isTime(v.t) or type(v.items) ~= "table" then return false end
    if v.off ~= nil and v.off ~= 0 and v.off ~= 1 then v.off = nil end
    if v.q ~= nil and not (isTime(v.q) and v.q <= v.t) then v.q = nil end
    for id, text in pairs(v.items) do
      if not (isInt(id, 1, ID_MAX) and type(text) == "string" and text:match("^[%d:,;]+$")) then v.items[id] = nil end
    end
    return true
  end, Scanner.BASE_MARKETS)
end

-- Desde cuándo puede faltar algo en la foto de una referencia: la subasta la toma al pedirla (base.q), no cuando llega
-- la respuesta (base.t, unos segundos después). Una referencia guardada sin q, su t.
local function snapOf(base) return base.q or base.t end

-- cdb.scanner.cancelAt[mercado] = hora de la última subasta tuya cancelada allí. Solo sirve mientras la foto de la
-- referencia de ventas de ese mercado es de antes (§2.9): el resto se quita al cargar y al guardar una referencia, así
-- que quedan 2 mercados como mucho. No al cancelar: sin referencia aún, la del escaneo en marcha (pedido antes de
-- cancelar) puede tener lo cancelado como del mercado, y se decide al guardarla.
local function pruneCancels()
  for key, at in pairs(cs.cancelAt) do
    local base = cdb.scanBase[key]
    if not base or at < snapOf(base) then cs.cancelAt[key] = nil end
  end
end

-- En ADDON_LOADED (Core, después de History.Load y Relay.Init). callbacks (todas opcionales):
--   listen(on): registra o quita REPLICATE_ITEM_LIST_UPDATE en el marco de eventos de Core;
--   onScanDone(kind, whole, t): un escaneo propio terminó ("full" o "lista"), grabado o no;
--   onSummaryRelease(summary, record): un resumen de Auctionator retenido se suelta; record = pasa el filtro de
--     grabado (Core lo graba con History.Record("summary", summary.data, true, {t = summary.t})) o solo refresca;
--   onState(): cambió el estado del escáner (repintar la ventana);
--   say(text): una línea en el chat (solo la propuesta con la ventana cerrada);
--   windowShown(): ¿está abierta la ventana del addon?
function Scanner.Init(accountDB, charDB, callbacks)
  db = type(accountDB) == "table" and accountDB or {}
  cdb = type(charDB) == "table" and charDB or {}
  cb = type(callbacks) == "table" and callbacks or {}
  db.scanner = sanitizeScanner(db.scanner)
  db.scanPrices = sanitizePrices(db.scanPrices)
  db.sales = sanitizeSales(db.sales)
  cdb.auctions = cleanMap(cdb.auctions, function(k) return isInt(k, 1, 2 ^ 53) end, isAuction)
  cdb.otherAuctions = cleanMap(cdb.otherAuctions, function(k) return isInt(k, 1, 2 ^ 53) end, isTime, Scanner.OTHER_MAX)
  cdb.scanBase = sanitizeBase(cdb.scanBase)
  cdb.scanner = type(cdb.scanner) == "table" and cdb.scanner or {}
  if cdb.scanner.ownSeen ~= "yes" and cdb.scanner.ownSeen ~= "no" then cdb.scanner.ownSeen = nil end
  if not isInt(cdb.scanner.ownMiss, 1, 1000) then cdb.scanner.ownMiss = nil end
  if cdb.scanner.ownEver ~= true then cdb.scanner.ownEver = cdb.scanner.ownSeen == "yes" or nil end
  cdb.scanner.cancelAt = cleanMap(cdb.scanner.cancelAt, validMarket, isTime)
  S, cs = db.scanner, cdb.scanner
  pruneCancels()
  Scanner.InstallHooks()
end

function Scanner.Mode() return S and S.auto or nil end

---------------------------------------------------------------------------
-- Mercados vistos (para quitar primero lo del menos visitado)
---------------------------------------------------------------------------
local function capByVisit(map, keep, maxKeys)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  if #keys <= maxKeys then return end
  table.sort(keys, function(a, b)
    local ta, tb = S.visited[a] or 0, S.visited[b] or 0
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  local extra = #keys - maxKeys
  for _, k in ipairs(keys) do
    if extra <= 0 then break end
    if k ~= keep then map[k] = nil; extra = extra - 1 end
  end
end

local function touchVisited(key)
  if not key then return end
  S.visited[key] = now() or S.visited[key]
  capByVisit(S.visited, key, Scanner.VISITED_MAX)
end

---------------------------------------------------------------------------
-- Casa de subastas: la de tu facción, la neutral (goblin) o no se sabe
---------------------------------------------------------------------------
local NEUTRAL_ZONE = {}
for _, id in ipairs(Data.NEUTRAL_AH_ZONES or {}) do NEUTRAL_ZONE[id] = true end

local function unitFaction(unit)
  if type(UnitFactionGroup) ~= "function" then return nil end
  local ok, faction = pcall(UnitFactionGroup, unit)
  faction = ok and readable(faction) or nil
  return type(faction) == "string" and faction ~= "" and faction or nil
end

-- Número del PNJ (solo cifras) sacado de UnitGUID("npc"): "Creature-0-...-<npcID>-...".
local function npcID()
  if type(UnitGUID) ~= "function" then return nil end
  local ok, guid = pcall(UnitGUID, "npc")
  guid = ok and readable(guid) or nil
  if type(guid) ~= "string" then return nil end
  local id = guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)")
  return id and tonumber(id) or nil
end

-- Mapa del jugador, su zona (el primer mapa de tipo zona subiendo por los padres) y si algún mapa de esa cadena es
-- de una zona con subasta neutral.
local function mapChain()
  local maps = type(C_Map) == "table" and C_Map or nil
  if not maps or type(maps.GetBestMapForUnit) ~= "function" then return nil, nil, false end
  local ok, id = pcall(maps.GetBestMapForUnit, "player")
  id = ok and readable(id) or nil
  if not isInt(id, 1, 999999) then return nil, nil, false end
  local zoneType = type(Enum) == "table" and type(Enum.UIMapType) == "table" and Enum.UIMapType.Zone or 3
  local mapID, zoneID, neutral, cur = id, nil, false, id
  for _ = 1, 12 do
    if NEUTRAL_ZONE[cur] then neutral = true end
    if type(maps.GetMapInfo) ~= "function" then break end
    local okInfo, info = pcall(maps.GetMapInfo, cur)
    if not okInfo or type(info) ~= "table" then break end
    if info.mapType == zoneType then zoneID = cur; break end
    local parent = readable(info.parentMapID)
    if not isInt(parent, 1, 999999) or parent == cur then break end
    cur = parent
  end
  return mapID, zoneID or mapID, neutral
end

-- Depósito de 200 unidades a 24 h (el de las referencias), o nil.
local function probeDeposit(id)
  local ok, copper = ah("CalculateCommodityDeposit", id, 3, 200)
  copper = ok and readable(copper) or nil
  if type(copper) == "number" and copper == copper and copper > 0 and copper < 1e12 then return floor(copper + 0.5) end
  return nil
end

local function takeReferences(key)
  local parts = {}
  for _, id in ipairs(Data.HOUSE_PROBE_IDS or {}) do
    local copper = probeDeposit(id)
    if copper then parts[#parts + 1] = id .. ":" .. copper end
  end
  if #parts > 0 then
    S.depRef[key] = table.concat(parts, ",")
    capByVisit(S.depRef, key, Scanner.DEPREF_MARKETS)
  end
end

-- Mediana de depósito actual / referencia sobre las referencias de este mercado (3 como mínimo), o nil.
local function depositRatio(key)
  local text = key and S.depRef[key]
  if type(text) ~= "string" then return nil end
  local refs = 0
  local ratios = {}
  for id, copper in text:gmatch("(%d+):(%d+)") do
    refs = refs + 1
    local ref, current = tonumber(copper), probeDeposit(tonumber(id))
    if ref and ref > 0 and current then ratios[#ratios + 1] = current / ref end
  end
  if refs < 3 or #ratios == 0 then return nil end
  table.sort(ratios)
  local m = #ratios
  if m % 2 == 1 then return ratios[(m + 1) / 2] end
  return (ratios[m / 2] + ratios[m / 2 + 1]) / 2
end

local function capZones()
  local zones = {}
  for z in pairs(S.houseZones) do zones[#zones + 1] = z end
  if #zones <= Scanner.ZONES_MAX then return end
  table.sort(zones)
  for i = 1, #zones - Scanner.ZONES_MAX do S.houseZones[zones[i]] = nil end
end

-- Se decide una vez en cada AUCTION_HOUSE_SHOW. Primera regla que vale: (1) el subastador es de tu facción; (2) es
-- neutral o estás en una zona de subasta goblin; (3) el depósito comparado con el de tu facción (x3 o más: neutral;
-- x1,5 o menos: tuya); (4) en esta zona ya valió la regla 1; (5) la regla 1 nunca valió en esta cuenta (lo de la
-- 0.5.1); (6) no se sabe.
local function detectHouse()
  local info = {}
  local me, npc = unitFaction("player"), unitFaction("npc")
  info.npc, info.npcID = npc, npcID()
  info.map, info.zone, info.neutralZone = mapChain()
  local key = market()
  local today = Spec.DayIndex(now())
  local kind, rule, guess
  if npc and me and npc == me then
    kind, rule = "faction", 1
    if info.zone then S.houseZones[info.zone] = true; capZones() end
    if key and depRefDay[key] ~= today then
      takeReferences(key)
      depRefDay[key] = today
    end
  elseif npc == "Neutral" or info.neutralZone then
    kind, rule = "neutral", 2
  else
    local ratio = depositRatio(key)
    info.ratio = ratio
    if ratio and ratio >= 3 then
      kind, rule = "neutral", 3
    elseif ratio and ratio <= 1.5 then
      kind, rule, guess = "faction", 3, true
    elseif info.zone and S.houseZones[info.zone] then
      kind, rule, guess = "faction", 4, true
    elseif next(S.houseZones) == nil and next(S.depRef) == nil then
      kind, rule, guess = "faction", 5, true
    else
      kind, rule = "unknown", 6
    end
  end
  info.rule, info.guess = rule, guess or false
  house, houseInfo, visitHouse = kind, info, kind
  return kind
end

-- "faction", "neutral", "unknown" o nil (subasta cerrada).
function Scanner.House()
  if not ahOpen then return nil end
  return house
end

function Scanner.HouseInfo() return houseInfo end

-- La casa de la visita actual o de la última (nil si aún no se abrió la subasta en esta sesión). Core no guarda los
-- escaneos de Auctionator hechos en la neutral o en una que no se sabe.
function Scanner.VisitHouse() return visitHouse end

local function otherHouse() return visitHouse == "neutral" or visitHouse == "unknown" end

---------------------------------------------------------------------------
-- Filtro de grabado: un escaneo cada 30 min y 8 al día por mercado
---------------------------------------------------------------------------
local function recordedOn(key, d)
  local text = S and key and S.recordedDay[key]
  if type(text) ~= "string" then return 0 end
  local day, n = text:match("^(%d+):(%d+)$")
  if day and tonumber(day) == d then return tonumber(n) end
  return 0
end

function Scanner.RecordedToday(key, t)
  return recordedOn(key, Spec.DayIndex(t or now()))
end

function Scanner.AllowRecord(key, t)
  if not S or not validMarket(key) or not isTime(t) then return false end
  local last = S.recorded[key]
  if last and t - last < Scanner.RECORD_GAP then return false end
  return recordedOn(key, Spec.DayIndex(t)) < Scanner.RECORD_PER_DAY
end

local function markRecorded(key, t)
  S.recorded[key] = max(S.recorded[key] or 0, t)
  local d = Spec.DayIndex(t)
  S.recordedDay[key] = d .. ":" .. (recordedOn(key, d) + 1)
end

-- ¿Toca grabar un escaneo ya (recordDue)? ¿Y medir ventas con la pareja del anterior de este personaje (pairDue)?
function Scanner.RecordDue(key, t)
  t = t or now()
  if not S or not key or not t then return false end
  local last = S.recorded[key]
  return (not last or t - last >= Scanner.RECORD_GAP) and recordedOn(key, Spec.DayIndex(t)) < Scanner.RECORD_PER_DAY
end

-- ¿Cancelaste una subasta tuya en este mercado desde la foto de la referencia (snapOf: también mientras llegaba o se
-- leía su respuesta), sin que conste que el escaneo reconoce las tuyas (ownSeen «yes»)? Entonces esa referencia pudo
-- tenerla como del mercado y, al no salir ya, contaría como vendida: esa pareja no mide (la siguiente parte de un
-- escaneo posterior). Cubre también lo que el «no» no ve: tras entrar o un /reload, las subastas de antes no suman
-- escaneos sin las tuyas (podrían haberse vendido sin conexión).
local function cancelledSince(key, base)
  return cs.ownSeen ~= "yes" and not cs.ownEver and (cs.cancelAt[key] or 0) >= snapOf(base)
end

local expectedOwn

-- La misma regla que la medida de finishBegin, salvo lo que solo sabe el escaneo (tramos, si salen tus subastas).
function Scanner.PairDue(key, t)
  t = t or now()
  if not Scanner.RecordDue(key, t) then return false end
  if cs.ownSeen == "no" and not (cs.ownEver and expectedOwn(key, t) == 0) then return false end
  local base = cdb.scanBase[key]
  if not base or base.t < (S.sampledUntil[key] or 0) or cancelledSince(key, base) then return false end
  local age = t - base.t
  if age < Scanner.SAMPLE_MIN or age > Scanner.PAIR_MAX then return false end
  -- Con la cuenta de escaneos sin las tuyas empezada y sin constar que se reconocen, si ya consta que no tienes ninguna
  -- a la venta aquí, el escaneo quitará la cuenta y no medirá: no es una pareja.
  if cs.ownSeen == nil and cs.ownMiss ~= nil then
    local _, none = expectedOwn(key, t)
    if none then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- Caché de precios propia: db.scanPrices[mercado] = {t, text = "id:lo:d,..."} (d = día del escaneo que lo vio)
---------------------------------------------------------------------------
-- Solo se decodifica la del mercado actual, la primera vez que se pide un precio o se junta un escaneo; se vuelve a
-- escribir al salir y solo si cambió. Topes para todos los mercados juntos: 40 000 entradas y 900 000 bytes.
local priceKey, priceLo, priceDay, priceDirty = nil, {}, {}, false

local function encodePrices()
  local ids = {}
  for id in pairs(priceLo) do ids[#ids + 1] = id end
  table.sort(ids)
  local parts = {}
  for i, id in ipairs(ids) do parts[i] = id .. ":" .. priceLo[id] .. ":" .. priceDay[id] end
  return table.concat(parts, ","), #ids
end

local function countEntries(text)
  if text == "" then return 0 end
  local _, commas = text:gsub(",", ",")
  return commas + 1
end

-- Quita de un texto de caché las entradas más viejas (por día; a igualdad, el ID menor) hasta quitar overEntries
-- entradas y overBytes bytes.
local function trimOldest(text, overEntries, overBytes)
  local list = {}
  for id, lo, d in text:gmatch("(%d+):(%d+):(%d+)") do
    list[#list + 1] = {id = tonumber(id), d = tonumber(d), text = id .. ":" .. lo .. ":" .. d}
  end
  table.sort(list, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  local k = 1
  while (overEntries > 0 or overBytes > 0) and k <= #list do
    overEntries, overBytes = overEntries - 1, overBytes - #list[k].text - 1
    list[k].gone = true
    k = k + 1
  end
  local kept = {}
  for _, e in ipairs(list) do if not e.gone then kept[#kept + 1] = e end end
  table.sort(kept, function(a, b) return a.id < b.id end)
  local parts = {}
  for i, e in ipairs(kept) do parts[i] = e.text end
  return table.concat(parts, ",")
end

-- Topes globales: fuera primero el mercado con la t más vieja (nunca el actual mientras haya otro) y, si solo queda
-- uno, sus entradas más viejas.
local function capPrices()
  local list, entries, bytes = {}, 0, 0
  for key, entry in pairs(db.scanPrices) do
    local n = countEntries(entry.text)
    list[#list + 1] = {key = key, t = entry.t, n = n, bytes = #entry.text}
    entries, bytes = entries + n, bytes + #entry.text
  end
  table.sort(list, function(a, b)
    if (a.key == priceKey) ~= (b.key == priceKey) then return b.key == priceKey end
    if a.t ~= b.t then return a.t < b.t end
    return a.key < b.key
  end)
  local i = 1
  while (entries > Scanner.PRICE_ENTRIES or bytes > Scanner.PRICE_BYTES) and i < #list do
    db.scanPrices[list[i].key] = nil
    entries, bytes = entries - list[i].n, bytes - list[i].bytes
    i = i + 1
  end
  if entries <= Scanner.PRICE_ENTRIES and bytes <= Scanner.PRICE_BYTES then return end
  local last = list[#list]
  local entry = db.scanPrices[last.key]
  entry.text = trimOldest(entry.text, entries - Scanner.PRICE_ENTRIES, bytes - Scanner.PRICE_BYTES)
  if last.key == priceKey then priceKey, priceLo, priceDay, priceDirty = nil, {}, {}, false end
end

local function flushPrices()
  if priceKey and priceDirty and db.scanPrices[priceKey] then
    db.scanPrices[priceKey].text = encodePrices()
    priceDirty = false
  end
  capPrices()
end
Scanner.FlushPrices = function() if db then flushPrices() end end

local function loadPrices(key)
  if priceKey == key then return end
  if priceKey and priceDirty and db.scanPrices[priceKey] then db.scanPrices[priceKey].text = encodePrices() end
  priceKey, priceLo, priceDay, priceDirty = key, {}, {}, false
  local entry = db.scanPrices[key]
  if not entry then return end
  stats.priceDecodes = stats.priceDecodes + 1
  local oldest = (Spec.DayIndex(now()) or 0) - Scanner.PRICE_DAYS
  for id, lo, d in entry.text:gmatch("(%d+):(%d+):(%d+)") do
    id, lo, d = tonumber(id), tonumber(lo), tonumber(d)
    if d > oldest and isInt(lo, 1, Spec.PRICE_MAX) and isInt(id, 1, ID_MAX) then
      priceLo[id], priceDay[id] = lo, d
    else
      priceDirty = true
    end
  end
end

-- Precio propio del objeto en el mercado actual: cobre por unidad y días desde que se vio (0 = hoy), o nil.
function Scanner.OwnPrice(id)
  if not db then return nil end
  local key = market()
  if not key then return nil end
  if priceKey ~= key then
    if not db.scanPrices[key] then return nil end
    loadPrices(key)
  end
  local lo = priceLo[id]
  if not lo then return nil end
  return lo, max(0, (Spec.DayIndex(now()) or priceDay[id]) - priceDay[id])
end

function Scanner.HasPrices()
  if not db then return false end
  local key = market()
  if not key then return false end
  if priceKey == key then return next(priceLo) ~= nil end
  local entry = db.scanPrices[key]
  return entry ~= nil and entry.text ~= ""
end

local function mergePrices(key, scanLo, t)
  loadPrices(key)
  local d = Spec.DayIndex(t)
  for id, lo in pairs(scanLo) do priceLo[id], priceDay[id] = lo, d end
  db.scanPrices[key] = db.scanPrices[key] or {text = ""}
  db.scanPrices[key].t = max(db.scanPrices[key].t or 0, t)
  priceDirty = true
end

-- Para /oro sondeo y las pruebas: entradas y bytes de la caché, y cuántas veces se decodificó un mercado.
function Scanner.CacheInfo()
  local entries, bytes, markets = 0, 0, 0
  for key, entry in pairs(db and db.scanPrices or {}) do
    markets = markets + 1
    if key == priceKey then
      local text, n = encodePrices()
      entries, bytes = entries + n, bytes + #text
    else
      entries, bytes = entries + countEntries(entry.text), bytes + #entry.text
    end
  end
  return {entries = entries, bytes = bytes, markets = markets, decodes = stats.priceDecodes, decoded = priceKey}
end

---------------------------------------------------------------------------
-- Niveles de la referencia de ventas: "precio:BC,BC;precio:BC" (B = tramo 0..3, C = unidades de esa subasta)
---------------------------------------------------------------------------
-- levels: {{precio, {{tramo, unidades}, ...}}, ...} de más barato a más caro. Se guardan los niveles enteros más
-- baratos hasta 40 niveles y 200 subastas (un nivel que pasaría de 200 se queda fuera con todos los de encima; si es el
-- primero, el objeto no tiene referencia). Devuelve el texto ("" si nada) y cuántas subastas lleva.
function Scanner.EncodeLevels(levels)
  local parts, auctions = {}, 0
  for i, level in ipairs(type(levels) == "table" and levels or {}) do
    if i > Scanner.BASE_LEVELS then break end
    local list = level[2]
    if auctions + #list > Scanner.BASE_AUCTIONS then break end
    local cells = {}
    for k, a in ipairs(list) do cells[k] = a[1] .. a[2] end
    parts[#parts + 1] = level[1] .. ":" .. table.concat(cells, ",")
    auctions = auctions + #list
  end
  return table.concat(parts, ";"), auctions
end

-- Texto -> levels, o nil si está mal.
function Scanner.DecodeLevels(text)
  if type(text) ~= "string" or text == "" then return nil end
  local levels = {}
  for entry in text:gmatch("[^;]+") do
    local price, rest = entry:match("^(%d+):([%d,]+)$")
    price = tonumber(price)
    if not isInt(price, 1, Spec.PRICE_MAX) then return nil end
    if #levels > 0 and price <= levels[#levels][1] then return nil end
    local list = {}
    for cell in rest:gmatch("[^,]+") do
      local band, count = tonumber(cell:sub(1, 1)), tonumber(cell:sub(2))
      if not (isInt(band, 0, 3) and isInt(count, 1, Spec.QTY_MAX)) then return nil end
      list[#list + 1] = {band, count}
    end
    if #list == 0 then return nil end
    levels[#levels + 1] = {price, list}
  end
  if #levels == 0 then return nil end
  return levels
end

---------------------------------------------------------------------------
-- Compras propias (para descontarlas de la estimación) y ventas propias (solo en este PC)
---------------------------------------------------------------------------
local function decodeRecords(text, fields)
  local out = {}
  for entry in (text or ""):gmatch("[^;]+") do
    local rec, ok = {}, true
    local i = 0
    for f in (entry .. ","):gmatch("([^,]*),") do
      i = i + 1
      rec[i] = tonumber(f)
      if not rec[i] then ok = false end
    end
    if ok and i >= fields then out[#out + 1] = rec end
  end
  return out
end

local function encodeRecords(list)
  local parts = {}
  for i, rec in ipairs(list) do parts[i] = table.concat(rec, ",") end
  return table.concat(parts, ";")
end

local function pruneBuys(t)
  local kept = {}
  for _, rec in ipairs(decodeRecords(S.buys, 3)) do
    if rec[1] > t - Scanner.BUYS_SECONDS and rec[1] <= t + 600 then kept[#kept + 1] = rec end
  end
  while #kept > Scanner.BUYS_MAX do table.remove(kept, 1) end
  S.buys = encodeRecords(kept)
end

-- Unidades compradas por esta cuenta en (from, to]: {[id] = unidades}.
local function boughtIn(from, to)
  local out = {}
  for _, rec in ipairs(decodeRecords(S.buys, 3)) do
    if rec[1] > from and rec[1] <= to then out[rec[2]] = (out[rec[2]] or 0) + rec[3] end
  end
  return out
end

function Scanner.BoughtBetween(id, from, to) return boughtIn(from, to)[id] or 0 end

-- COMMODITY_PURCHASED (itemID, cantidad) e ITEM_PURCHASED (itemID: 1). En toda la cuenta y cualquier mercado.
function Scanner.OnPurchase(itemID, quantity)
  if not S then return end
  protect("compra", function()
    local t = now()
    lastUserAction = t
    local id, qty = readable(itemID), readable(quantity) or 1
    if not (t and isInt(id, 1, ID_MAX) and isInt(qty, 1, Spec.QTY_MAX)) then return end
    S.buys = (S.buys == "" and "" or (S.buys .. ";")) .. t .. "," .. id .. "," .. qty
    pruneBuys(t)
  end)
end

-- COMMODITY_PURCHASE_SUCCEEDED / _FAILED: el jugador está comprando (las peticiones solas esperan 15 s).
function Scanner.OnUserAction()
  lastUserAction = now()
end

-- Subastas tuyas seguidas: cdb.auctions[auctionID] = "id,unit,qty,dur,postedAt,market,k" (k: c mercancía, i objeto).
local function decodeAuction(text)
  local id, unit, qty, dur, at, key, kind, sold = text:match("^(%d+),(%d+),(%d+),(%d),(%d+),([^,]+),([ci])(,?s?)$")
  if not id or (sold ~= "" and sold ~= ",s") then return nil end
  return {id = tonumber(id), unit = tonumber(unit), qty = tonumber(qty), dur = tonumber(dur), at = tonumber(at),
          market = key, kind = kind, sold = sold == ",s"}
end

local function auctionEnd(a) return a.at + (DURATION_HOURS[a.dur] or 24) * 3600 + 3600 end

local function pruneAuctions(t)
  for auctionID, text in pairs(cdb.auctions) do
    local a = decodeAuction(text)
    if not a or auctionEnd(a) < t then cdb.auctions[auctionID] = nil end
  end
end

local function prunePending(t)
  local kept = {}
  for _, p in ipairs(pending) do
    local fresh = t - p.at <= Scanner.POST_SECONDS and (not p.used or t - p.used <= Scanner.POST_REPEAT)
    if fresh then kept[#kept + 1] = p end
  end
  pending = kept
end

-- Gancho de PostCommodity / ConfirmPostCommodity (kind "c": location, duration, quantity, unitPrice) y de
-- PostItem / ConfirmPostItem (kind "i": location, duration, quantity, bid, buyout). Solo mira.
local function onPost(kind, location, duration, quantity, a, b)
  local t = now()
  lastUserAction = t
  if not (ahOpen and house == "faction" and t) then return end
  local id
  if type(C_Item) == "table" and type(C_Item.GetItemID) == "function" then
    local ok, got = pcall(C_Item.GetItemID, location)
    id = ok and readable(got) or nil
  end
  duration, quantity = readable(duration), readable(quantity)
  -- PostItem: el precio de compra ya es por pieza (con varias, la subasta crea una subasta de 1 por pieza a ese precio).
  local unit = readable(kind == "c" and a or b)
  if not (isInt(id, 1, ID_MAX) and isInt(duration, 1, 3) and isInt(quantity, 1, Spec.QTY_MAX)) then return end
  unit = (type(unit) == "number" and unit == unit and unit >= 0) and floor(unit + 0.5) or 0
  prunePending(t)
  for _, p in ipairs(pending) do
    if p.id == id and p.unit == unit and p.qty == quantity and p.dur == duration and p.kind == kind then
      p.at = t -- ConfirmPost* tras Post*: la misma publicación
      return
    end
  end
  -- Una publicación nueva. La subasta las atiende de una en una (el botón espera a que responda a la anterior), así
  -- que una pendiente de hace más de 2 s ya no se va a crear (un aviso de confirmación que se canceló, una que la
  -- subasta no aceptó sin decirlo): si se quedara, la siguiente subasta creada se apuntaría con su objeto.
  local kept = {}
  for _, p in ipairs(pending) do
    if t - max(p.at, p.used or 0) <= Scanner.POST_FLIGHT then kept[#kept + 1] = p end
  end
  pending = kept
  pending[#pending + 1] = {id = id, unit = unit, qty = quantity, dur = duration, at = t, market = market(), kind = kind,
                           left = quantity}
end

-- AUCTION_HOUSE_SHOW_ERROR y AUCTION_HOUSE_POST_ERROR (Core) y el gancho de C_AuctionHouse.CancelSell: lo que se estaba
-- publicando no se hizo (la subasta lo rechazó, no deja publicar ahora o se paró una venta de varias piezas). Se olvidan
-- las publicaciones pendientes: la siguiente subasta creada no se apunta con el objeto de una que no existe.
function Scanner.OnPostFailed()
  pending = {}
end

-- Subastas creadas en la neutral (o en una que no se sabe): solo el número y la hora, el tiempo que puede durar una.
local OTHER_SECONDS = (DURATION_HOURS[#DURATION_HOURS] + 1) * 3600
local function pruneOther(t)
  local ids = {}
  for id, at in pairs(cdb.otherAuctions) do
    if at < t - OTHER_SECONDS then cdb.otherAuctions[id] = nil else ids[#ids + 1] = id end
  end
  if #ids <= Scanner.OTHER_MAX then return end
  table.sort(ids, function(x, y)
    if cdb.otherAuctions[x] ~= cdb.otherAuctions[y] then return cdb.otherAuctions[x] < cdb.otherAuctions[y] end
    return x < y
  end)
  for i = 1, #ids - Scanner.OTHER_MAX do cdb.otherAuctions[ids[i]] = nil end
end

-- AUCTION_HOUSE_AUCTION_CREATED: la publicación más vieja pendiente pasa a ser una subasta seguida. Un PostItem de
-- varias unidades crea varias subastas de una (las que lleguen en 5 s).
function Scanner.OnAuctionCreated(auctionID)
  if not cdb then return end
  protect("subasta creada", function()
    local t = now()
    lastUserAction = t
    auctionID = readable(auctionID)
    if not (t and isInt(auctionID, 1, 2 ^ 53)) then return end
    if otherHouse() then
      -- En la neutral (otro mercado) no se sigue nada: solo se recuerda el número, para que su aviso de venta no se
      -- tome por una venta de tu facción.
      cdb.otherAuctions[auctionID] = t
      pruneOther(t)
      return
    end
    prunePending(t)
    local p = pending[1]
    if not p or not validMarket(p.market) then return end
    local qty = p.qty
    if p.kind == "i" then
      qty = 1
      p.left = p.left - 1
      p.used = t
      if p.left <= 0 then table.remove(pending, 1) end
    else
      table.remove(pending, 1)
    end
    cdb.auctions[auctionID] = table.concat({p.id, p.unit, qty, p.dur, t, p.market, p.kind}, ",")
    sessionAuctions[auctionID] = true
  end)
end

-- AUCTION_CANCELED: esa subasta ya no está. Se apunta cuándo y en qué mercado (el de la seguida; si no se sigue, el de
-- tu facción salvo que sea una de la neutral): la pareja cuya foto es de antes no mide ventas ahí (cancelledSince).
-- Aquí no se limpia cancelAt (pruneCancels): sin referencia de ese mercado, el escaneo en marcha guardará una de antes.
function Scanner.OnAuctionGone(auctionID)
  local t = now()
  lastUserAction = t
  if not (cdb and cs and cdb.auctions) then return end
  local id = readable(auctionID)
  local text = id ~= nil and cdb.auctions[id] or nil
  if id ~= nil then cdb.auctions[id] = nil end
  local a = text and decodeAuction(text)
  local where = a and a.market
  if not where and visitHouse ~= "neutral" and not (id ~= nil and cdb.otherAuctions[id]) then where = market() end
  if not (t and validMarket(where)) then return end
  cs.cancelAt[where] = max(cs.cancelAt[where] or 0, t)
end

local function salesList(key) return decodeRecords(db.sales[key], 6) end

local function appendSale(key, rec, t)
  local kept = {}
  for _, r in ipairs(salesList(key)) do
    if r[1] > t - Scanner.SALES_DAYS * 86400 then kept[#kept + 1] = r end
  end
  kept[#kept + 1] = rec
  while #kept > Scanner.SALES_MAX do table.remove(kept, 1) end
  db.sales[key] = encodeRecords(kept)
  capByVisit(db.sales, key, Scanner.SALES_MARKETS)
end

-- AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION (notification, text, auctionID). Una venta (AuctionSold) se apunta como
-- "t,id,unit,qty,dur,age": qty 0 en mercancías (el aviso no dice cuántas unidades, y una subasta de mercancía avisa una
-- vez por compra parcial: se cuentan veces, no unidades) y 1 en lo demás; lo que no se sabe, 0. El texto se usa solo
-- para reconocer el objeto y nunca se guarda. «Apuntar mis ventas» apagado (S.sales = false) solo quita el apunte de
-- la venta: la subasta vendida deja de contar como tuya en el escaneo igual (si no, ese personaje dejaría de medir
-- ventas).
function Scanner.OnNotification(notification, text, auctionID)
  if not cdb or not S then return end
  protect("aviso", function()
    notification, auctionID = readable(notification), readable(auctionID)
    if notification ~= SOLD and notification ~= EXPIRED then return end
    -- Una subasta de la neutral (o de una que no se sabe): otro mercado, ni se apunta ni toca las tuyas de aquí.
    if auctionID ~= nil and cdb.otherAuctions[auctionID] then
      if notification == EXPIRED then cdb.otherAuctions[auctionID] = nil end
      return
    end
    if notification == EXPIRED then
      if auctionID ~= nil then cdb.auctions[auctionID] = nil end
      return
    end
    local t = now()
    if not t then return end
    pruneAuctions(t)
    text = readable(text)
    local named = type(text) == "string" and text ~= ""
    local key, a = nil, nil
    if auctionID ~= nil then
      -- Con número: la seguida con ese número o ninguna. Los números no se repiten, así que una que no está seguida
      -- (de antes de instalar, de otro PC) nunca es otra tuya del mismo objeto.
      if cdb.auctions[auctionID] then key, a = auctionID, decodeAuction(cdb.auctions[auctionID]) end
    elseif named then
      for k, v in pairs(cdb.auctions) do
        local cand = decodeAuction(v)
        if cand and Items.Name(cand.id) == text and (not a or cand.at < a.at or (cand.at == a.at and k < key)) then
          key, a = k, cand
        end
      end
    end
    -- Una subasta de objeto se vende entera; la de mercancía sigue (avisa una vez por compra parcial), marcada como
    -- vendida: puede que ya no esté en la subasta y no debe contar como tuya en el escaneo (ownSeen).
    if a then
      if a.kind ~= "c" then cdb.auctions[key] = nil elseif not a.sold then cdb.auctions[key] = cdb.auctions[key] .. ",s" end
    end
    if S.sales == false then return end
    local rec
    if a then
      rec = {t, a.id, a.unit, a.kind == "c" and 0 or 1, a.dur, max(0, t - a.at)}
    else
      local id = 0
      if named then
        for _, w in ipairs(History.WatchList()) do
          if Items.Name(w.id) == text then id = w.id; break end
        end
      end
      rec = {t, id, 0, 0, 0, 0}
    end
    local where = a and a.market or market()
    if validMarket(where) then appendSale(where, rec, t) end
  end)
end

-- Ventas apuntadas de un mercado (el actual si no se dice): {{t, id, unit, qty, dur, age}, ...} de 28 días.
function Scanner.Sales(key)
  if not db then return {} end
  key = key or market()
  if not key then return {} end
  local t = now() or 0
  local out = {}
  for _, r in ipairs(salesList(key)) do
    if r[1] > t - Scanner.SALES_DAYS * 86400 then out[#out + 1] = r end
  end
  return out
end

---------------------------------------------------------------------------
-- Peticiones: gancho, ventana de respuesta y huella
---------------------------------------------------------------------------
local startRead, checkHeld, finishSweep

local function numReplicate()
  local ok, n = ah("GetNumReplicateItems")
  n = ok and readable(n) or nil
  if isInt(n, 0, 10000000) then return n end
  return 0
end

local function decimal(x)
  if type(x) ~= "number" or x ~= x then return "" end
  return string.format("%.0f", x)
end

-- Huella de lo que hay ahora en la lista: FNV-1a del texto "n,itemID,count,buyout,..." de 32 filas repartidas
-- (floor(k * n / 32), k = 0..31). Basta para saber si es la misma respuesta que la última leída.
function Scanner.Fingerprint(n)
  local parts = {decimal(n)}
  local a = api()
  for k = 0, 31 do
    local row = floor(k * n / 32)
    local _, ok, count, buyout, itemID = nil, false, nil, nil, nil
    if a and type(a.GetReplicateItemInfo) == "function" then
      ok, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = pcall(a.GetReplicateItemInfo, row)
    end
    if not ok then count, buyout, itemID = nil, nil, nil end
    parts[#parts + 1] = decimal(itemID)
    parts[#parts + 1] = decimal(count)
    parts[#parts + 1] = decimal(buyout)
  end
  return fnv(table.concat(parts, ","))
end

local function nextAllowedAt()
  return max(S.lastOwnRequest or 0, S.lastSuccess or 0) + Scanner.THROTTLE
end

local function openWindow()
  windowToken = windowToken + 1
  local token = windowToken
  windowOpen, events, firstAt, firstT = true, 0, nil, nil
  phase = req.ours and "requested" or "other"
  listen(true)
  after(Scanner.WINDOW, function() protect("respuesta", Scanner.WindowEnd, token) end)
  notify()
end

local function closeWindow()
  windowOpen = false
  windowToken = windowToken + 1
  firstAt, firstT = nil, nil
  if listening then listen(false) end
end

-- Corre después de cada llamada a C_AuctionHouse.ReplicateItems hecha a través de la tabla (la nuestra, la de
-- Auctionator o la de otro addon). Solo en la subasta de tu facción abre la ventana de la respuesta.
local function onRequest()
  local t = now()
  if not (S and t) then return end
  local ours = sending
  S.lastAnyRequest = t
  if ours then S.lastOwnRequest = t else stats.otherRequests = stats.otherRequests + 1 end
  if not ahOpen then
    -- La subasta se está abriendo: Auctionator pide su escaneo completo al mostrar su marco, que puede ir antes de
    -- nuestro AUCTION_HOUSE_SHOW. Se apunta y OnShow abre la ventana de la respuesta (la respuesta tarda más).
    early = {t = t, ours = ours, at = clock()}
    return
  end
  if house ~= "faction" then return end
  if reading then stats.requestsWhileReading = stats.requestsWhileReading + 1; return end
  if windowOpen then closeWindow() end
  queued = nil
  req = {t = t, ours = ours, resent = ours and resendNext or false}
  resendNext = false
  if ours then visitScanned = true end
  openWindow()
end

function Scanner.InstallHooks()
  if hooksInstalled then return Scanner.hooked end
  hooksInstalled = true
  local a = api()
  if type(hooksecurefunc) ~= "function" or not a or type(a.ReplicateItems) ~= "function" then
    Scanner.hooked = false
    return false
  end
  Scanner.hooked = pcall(hooksecurefunc, a, "ReplicateItems", function() protect("petición", onRequest) end) and true or false
  for name, kind in pairs({PostCommodity = "c", ConfirmPostCommodity = "c", PostItem = "i", ConfirmPostItem = "i"}) do
    if type(a[name]) == "function" then
      pcall(hooksecurefunc, a, name, function(...) protect("publicar", onPost, kind, ...) end)
    end
  end
  if type(a.CancelSell) == "function" then
    pcall(hooksecurefunc, a, "CancelSell", function() protect("publicar", Scanner.OnPostFailed) end)
  end
  return Scanner.hooked
end

-- REPLICATE_ITEM_LIST_UPDATE (solo registrado dentro de una ventana de respuesta). O(1) y sin crear nada: cuenta y, la
-- primera vez, programa la única espera de esa respuesta.
local settle
function Scanner.OnReplicate()
  if not windowOpen then return end
  events = events + 1
  if firstAt then return end
  firstAt, firstT = clock(), now()
  settleFor = windowToken
  after(Scanner.SETTLE, settle)
end

settle = function()
  if settleFor ~= windowToken or not windowOpen then return end
  protect("respuesta", function()
    listen(false)
    stats.settleEvents = events
    local n = numReplicate()
    local fp = n > 0 and Scanner.Fingerprint(n) or nil
    if n == 0 or fp == S.fp then
      -- Un aviso suelto de la caché de objetos o la misma respuesta de antes: se sigue esperando en esta ventana.
      if n > 0 then stats.strayRejected = stats.strayRejected + 1 end
      firstAt, firstT, events = nil, nil, 0
      listen(true)
      return
    end
    S.lastSuccess = req.t -- la hora de la PETICIÓN: la subasta vuelve a dejar escanear 15 min después de pedir
    S.fp = fp
    local t = firstT or now()
    stats.answerSeconds = t - req.t
    local answered = req
    closeWindow()
    if answered.ours then sessionTimeouts, S.timeouts = 0, 0 end
    startRead(n, t, answered)
  end)
end

-- Fin de la ventana (60 s) sin respuesta aceptada.
function Scanner.WindowEnd(token)
  if token ~= windowToken or not windowOpen then return end
  closeWindow()
  phase = nil
  if req and req.ours then
    sessionTimeouts = sessionTimeouts + 1
    S.timeouts = (S.timeouts or 0) + 1
    stats.timeouts = stats.timeouts + 1
    if sessionTimeouts >= Scanner.TIMEOUTS then noresponse = true end
    result = {state = noresponse and "noresponse" or "timeout", at = now(), nextAt = nextAllowedAt()}
  else
    stats.otherUnanswered = stats.otherUnanswered + 1
  end
  checkHeld()
  notify()
end

local function throttledReady()
  local ok, ready = ah("IsThrottledMessageSystemReady")
  if not ok then return true end
  return readable(ready) ~= false
end

local function scanRunning()
  local P = ns.Prices
  return P and type(P.ScanRunning) == "function" and P.ScanRunning() == true or false
end

local function send()
  phase = "requested"
  sending = true
  local ok, err = pcall(function() C_AuctionHouse.ReplicateItems() end)
  sending = false
  if not ok then
    Scanner.lastError = "pedir: " .. tostring(err)
    phase = nil
    return
  end
  -- Sin gancho, solo nuestras peticiones abren la ventana de la respuesta.
  if not Scanner.hooked then
    sending = true
    protect("petición", onRequest)
    sending = false
  end
end

-- Por qué no se puede pedir ahora mismo (nil = se puede): "closed", "neutral", "unknown", "other" (otro addon acaba de
-- pedir), "running" (ya se está pidiendo, leyendo o escaneando la lista) o "throttle".
local function blockReason()
  if not ahOpen then return "closed" end
  if house == "neutral" or house == "unknown" then return house end
  if windowOpen then return (req and not req.ours) and "other" or "running" end
  if reading or queued or sweep then return "running" end
  if (now() or 0) < nextAllowedAt() then return "throttle" end
  return nil
end

local function tryQueued(token)
  local q = queued
  if not q or (token and q.token ~= token) then return end
  if not ahOpen or house ~= "faction" or windowOpen or reading then queued = nil; phase = nil; notify(); return end
  local c = clock()
  local wait
  if c - showAt < Scanner.OPEN_DELAY then
    wait = Scanner.OPEN_DELAY - (c - showAt)
  elseif scanRunning() then
    if c - q.at > Scanner.SUMMARY_WAIT then queued = nil; phase = nil; notify(); return end
    wait = Scanner.READY_POLL
  elseif not throttledReady() then
    if c - q.at > Scanner.READY_WAIT then queued = nil; phase = nil; notify(); return end
    wait = Scanner.READY_POLL
  end
  if wait then
    after(wait, function() protect("petición", tryQueued, q.token) end)
    return
  end
  queued = nil
  if q.resend then resendNext = true end
  send()
  notify()
end

local queueSeq = 0
local function enqueue(resend)
  queueSeq = queueSeq + 1
  queued = {at = clock(), token = queueSeq, resend = resend}
  phase = "queued"
  tryQueued(queueSeq)
end

-- Pide la subasta entera si las reglas lo dejan. manual: lo pidió el jugador (botón o /oro escanear). Devuelve true y
-- "queued"/"requested", o false y el motivo de blockReason.
function Scanner.Request(manual)
  if not S then return false, "closed" end
  local why = blockReason()
  if why then return false, why end
  result = nil
  enqueue(false)
  return true, phase or "requested"
end

-- AUCTION_HOUSE_THROTTLED_SYSTEM_READY / AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED.
function Scanner.OnThrottle(event)
  if not S then return end
  protect("subasta ocupada", function()
    if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
      if queued then tryQueued(queued.token) end
    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
      -- Nuestra petición se perdió por el camino: una vez, se vuelve a pedir en cuanto se pueda.
      if windowOpen and req and req.ours and not req.resent and (now() or 0) - req.t <= Scanner.DROP_RESEND then
        closeWindow()
        enqueue(true)
      end
    end
  end)
end

---------------------------------------------------------------------------
-- Lectura de la respuesta, por tandas de 1,5 ms (una por fotograma)
---------------------------------------------------------------------------
local readStep

local function watchedIDs()
  local set = {}
  for _, w in ipairs(History.WatchList()) do set[w.id] = true end
  return set
end

startRead = function(n, t, answered)
  local me
  if type(UnitName) == "function" then
    local ok, name = pcall(UnitName, "player")
    me = ok and type(readable(name)) == "string" and name or nil
  end
  reading = {n = n, n0 = n, i = 0, t = t, req = answered, me = me, watched = watchedIDs(), lo = {}, P = {}, B = {}, C = {},
             rows = 0, valid = 0, watchedRows = 0, ownRows = 0, foreign = 0, frames = 0, maxMs = 0, totalMs = 0,
             statuses = {}, startedAt = clock(), lastNotify = 0}
  phase = "reading"
  notify()
  after(0, readStep)
end

-- Lee filas hasta gastar el presupuesto. Sin tablas por fila: los vigilados van a tres listas de números por objeto.
local function noBand() return nil end

local function readRows(job)
  local a = api()
  local get, left = a.GetReplicateItemInfo, a.GetReplicateItemTimeLeft or noBand
  local profile = type(debugprofilestop) == "function" and debugprofilestop or nil
  local start = profile and profile()
  local budget, every = Scanner.BUDGET_MS, Scanner.CHECK_ROWS
  local limit = profile and math.huge or Scanner.ROWS_PER_STEP
  local i, n, k = job.i, job.n, 0
  local me, watched, lo, P, B, C, statuses = job.me, job.watched, job.lo, job.P, job.B, job.C, job.statuses
  local priceMax = Spec.PRICE_MAX
  while true do
    if i >= n then
      local more = numReplicate() -- la lista creció mientras se leía: se sigue hasta el nuevo final
      if more > n then n = more; job.n = more else job.finished = true; break end
    end
    if k >= limit then break end
    if profile and k > 0 and k % every == 0 then
      local spent = profile() - start
      -- Sin pasarse: si otras 64 filas al mismo ritmo pasarían de 1,5 ms, se para aquí.
      if spent > budget or spent * (k + every) > budget * k then break end
    end
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, saleStatus, itemID = get(i)
    job.rows = job.rows + 1
    if saleStatus ~= nil and not statuses[saleStatus] then statuses[saleStatus] = true end
    if owner ~= nil and owner == me then
      -- Tus subastas (también las de solo puja) no son el precio del mercado; el nombre no se guarda.
      job.ownRows = job.ownRows + 1
    elseif type(itemID) == "number" and itemID >= 1 and itemID <= ID_MAX and itemID % 1 == 0 and itemID ~= PET_CAGE
       and type(count) == "number" and count >= 1 and type(buyout) == "number" and buyout > 0 and saleStatus ~= 1 then
      if type(owner) == "string" and owner ~= "" then job.foreign = job.foreign + 1 end
      local unit = floor(buyout / count + 0.5)
      if unit >= 1 and unit <= priceMax then
        job.valid = job.valid + 1
        local old = lo[itemID]
        if not old or unit < old then lo[itemID] = unit end
        if watched[itemID] then
          local raw = left(i)
          if type(raw) == "number" then
            if not job.rawMin or raw < job.rawMin then job.rawMin = raw end
            if not job.rawMax or raw > job.rawMax then job.rawMax = raw end
          end
          local prices = P[itemID]
          if not prices then
            prices = {}
            P[itemID], B[itemID], C[itemID] = prices, {}, {}
          end
          local m = #prices + 1
          prices[m], B[itemID][m], C[itemID][m] = unit, type(raw) == "number" and raw or -1, count
          job.watchedRows = job.watchedRows + 1
        end
      end
    end
    i, k = i + 1, k + 1
  end
  job.i = i
  local spent = profile and (profile() - start) or 0
  job.frames = job.frames + 1
  job.totalMs = job.totalMs + spent
  if spent > job.maxMs then job.maxMs = spent end
end

local finishStep

-- Una tanda por fotograma: primero se leen las filas y, en los fotogramas siguientes, se cierra el escaneo (precios,
-- ventas y referencia) con el mismo presupuesto.
readStep = function()
  local job = reading
  if not job then return end
  local ok, err
  if job.finished then ok, err = pcall(finishStep, job) else ok, err = pcall(readRows, job) end
  if not ok then
    Scanner.lastError = (job.finished and "escaneo: " or "lectura: ") .. tostring(err)
    reading, phase = nil, nil
    notify()
    return
  end
  if job.closed then
    if reading == job then reading, phase = nil, nil end
    notify()
    return
  end
  local progress = floor(job.i * 10 / max(1, job.n))
  if progress ~= job.lastNotify then job.lastNotify = progress; notify() end
  after(0, readStep)
end

local function bandMinimums()
  local out, values = {}, {}
  for b = 0, 3 do
    local ok, lo = ah("GetTimeLeftBandInfo", b)
    lo = ok and readable(lo) or nil
    out[b + 1] = (type(lo) == "number" and lo >= 0) and lo or BAND_FALLBACK[b + 1]
    values[#values + 1] = (type(lo) == "number") and tostring(lo) or "-"
  end
  stats.bandInfo = table.concat(values, "/")
  return out
end

-- Tus subastas según la pestaña Subastas (GetOwnedAuctionInfo, 200 como mucho): cuántas están activas con precio de
-- compra (las vendidas que esperan en el correo no), cuántas hay, si la lista está entera (HasFullOwnedAuctionResults
-- y no más de 200; también con ninguna: el cliente la llena solo al abrir la pestaña Subastas y, hasta entonces, da 0
-- sin estar entera, y ese 0 no dice nada), entera y con alguna, el estado de cada auctionID, y los auctionID de las
-- activas con precio de compra.
local function ownedAuctions()
  local ok, n = ah("GetNumOwnedAuctions")
  n = ok and readable(n) or nil
  if not isInt(n, 0, 100000) then return 0, n, nil, false, {} end
  local okFull, full = ah("HasFullOwnedAuctionResults")
  full = (okFull and readable(full) == true and n <= Scanner.OWNED_MAX) and true or false
  local statusOf = (full and n > 0) and {} or nil
  local active, activeIDs = 0, {}
  for i = 1, min(n, Scanner.OWNED_MAX) do
    local okInfo, info = ah("GetOwnedAuctionInfo", i)
    if okInfo and type(info) == "table" then
      local status, buyout, id = readable(info.status), readable(info.buyoutAmount), readable(info.auctionID)
      if status == ACTIVE and type(buyout) == "number" and buyout > 0 then
        active = active + 1
        if id ~= nil then activeIDs[id] = true end
      end
      if statusOf and id ~= nil then statusOf[id] = status end
    end
  end
  return active, n, statusOf, full, activeIDs
end

-- Subastas de este personaje que deberían salir en el escaneo (las que suman un escaneo sin las tuyas): las seguidas de
-- este mercado aún vigentes, sin aviso de venta y creadas en esta sesión (el aviso de venta solo llega con el personaje
-- conectado: lo vendido mientras no estabas seguiría contando), y las que la pestaña Subastas da como activas con
-- precio de compra. Con esa lista entera, una seguida que sale vendida o que no sale ya no cuenta. Tampoco las creadas
-- después de snap (el segundo de la petición del escaneo: publicadas mientras llegaba o se leía la respuesta, no pueden
-- salir en su foto), ni en esa lista. Contar de menos solo hace la comprobación más blanda.
-- Devuelve también si consta que no tienes ninguna en este mercado, lo único que quita el «no»: la lista de la pestaña
-- Subastas entera y sin ninguna activa, y ninguna seguida de este mercado vigente, sea de esta sesión o de antes (tras un
-- /reload o al entrar, las de antes siguen a la venta) y aunque haya avisado de una venta (una mercancía avisa con la
-- primera compra parcial y el resto sigue a la venta), salvo que esa lista la dé vendida: puede ser de antes de
-- publicarla (el cliente no la vuelve a pedir al publicar). Y, como tercer valor, el texto de /oro sondeo.
expectedOwn = function(key, t, snap)
  local listed, owned, statusOf, full, activeIDs = ownedAuctions()
  local active, n, open = listed, 0, 0
  for auctionID, text in pairs(cdb.auctions) do
    local a = decodeAuction(text)
    if a then
      local late = snap ~= nil and a.at > snap
      if late and activeIDs[auctionID] then active = active - 1 end
      if a.market == key and auctionEnd(a) >= t then
        local status = statusOf and statusOf[auctionID]
        if not (a.sold or late) and sessionAuctions[auctionID] and (not statusOf or status == ACTIVE) then n = n + 1 end
        if status == nil or status == ACTIVE then open = open + 1 end
      end
    end
  end
  return n + active, full and listed == 0 and open == 0,
    type(owned) == "number" and (listed .. " a la venta de " .. owned) or nil
end

-- Referencia de ventas de este personaje: los niveles más baratos de un objeto vigilado (sin tus subastas).
local function baselineItem(job, id)
  local idx, P, B, C = job.sorted[id], job.P[id], job.B[id], job.C[id]
  local levels, current = {}, nil
  for _, m in ipairs(idx) do
    if not current or current[1] ~= P[m] then
      if #levels >= Scanner.BASE_LEVELS then break end
      current = {P[m], {}}
      levels[#levels + 1] = current
    end
    local band = B[m] - job.offset
    if band < 0 then band = 0 elseif band > 3 then band = 3 end
    current[2][#current[2] + 1] = {band, C[m]}
  end
  local text, auctions = Scanner.EncodeLevels(levels)
  if text ~= "" then
    job.baseItems[id], job.baseCounts[id] = text, auctions
    job.baseTotal = job.baseTotal + #text + 12
  end
end

local function storeBaseline(job, key)
  local items, counts = job.baseItems, job.baseCounts
  -- Todo el texto en 400 KB como mucho: fuera primero los objetos con más subastas.
  if job.baseTotal > Scanner.BASE_BYTES then
    local ids, total = {}, job.baseTotal
    for id in pairs(items) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
      if counts[a] ~= counts[b] then return counts[a] > counts[b] end
      return a < b
    end)
    for _, id in ipairs(ids) do
      if total <= Scanner.BASE_BYTES then break end
      total = total - #items[id] - 12
      items[id] = nil
    end
  end
  local q = job.req and isTime(job.req.t) and min(job.req.t, job.t) or nil
  cdb.scanBase[key] = {t = job.t, q = q, off = (job.known and job.bandsOK) and job.offset or nil, items = items}
  -- 2 mercados por personaje como mucho: fuera el escaneado hace más tiempo.
  local keys = {}
  for k in pairs(cdb.scanBase) do keys[#keys + 1] = k end
  if #keys > Scanner.BASE_MARKETS then
    table.sort(keys, function(a, b) return cdb.scanBase[a].t < cdb.scanBase[b].t end)
    for i = 1, #keys - Scanner.BASE_MARKETS do if keys[i] ~= key then cdb.scanBase[keys[i]] = nil end end
  end
  pruneCancels()
  stats.baseItems, stats.baseBytes = 0, 0
  for _, text in pairs(items) do stats.baseItems = stats.baseItems + 1; stats.baseBytes = stats.baseBytes + #text end
end

-- Cierre del escaneo, paso a paso (cada uno se puede cortar entre objetos para no pasar de 1,5 ms por fotograma):
-- begin (tramos, tus subastas, ¿se graba?), items (lo, qty y qty5 de cada vigilado), prices (caché de precios),
-- samples (ventas desde la referencia), baseline (la nueva referencia) y, al final, finishEnd.
local function finishBegin(job)
  local t, key = job.t, market()
  visitScanned = true
  -- La lista creció durante la lectura: la huella pasa a ser la de la lista entera, o la misma foto se tomaría
  -- después por una respuesta nueva (otra petición rechazada en silencio y un aviso suelto de la caché de objetos).
  if job.n ~= job.n0 then S.fp = Scanner.Fingerprint(job.n) end
  stats.lastRead = {rows = job.rows, n = job.n, watchedRows = job.watchedRows, ownRows = job.ownRows,
                    foreign = job.foreign, frames = job.frames, maxMs = job.maxMs, totalMs = job.totalMs,
                    rawMin = job.rawMin, rawMax = job.rawMax, statuses = job.statuses, t = t,
                    ours = job.req and job.req.ours or false}
  job.key = key
  if not key or house ~= "faction" then job.closed = true; return end
  -- Tramo de tiempo: 0..3 o 1..4 según el cliente. Un 0 o un 4 lo demuestran; si no, el que ya se sabía (o 1).
  local offset, proven
  if job.rawMin == 0 then offset, proven = 0, true
  elseif job.rawMax == 4 then offset, proven = 1, true
  elseif S.bandOffset then offset = S.bandOffset
  else offset = 1 end
  if proven then S.bandOffset = offset end
  job.offset, job.known = offset, proven or S.bandOffset ~= nil
  job.bandsOK = job.rawMin == nil or (job.rawMin - offset >= 0 and job.rawMax - offset <= 3)
  stats.bandOffset = job.known and offset or nil
  job.bandMin = bandMinimums()
  job.agg, job.sorted, job.present = {}, {}, 0
  job.baseItems, job.baseCounts, job.baseTotal = {}, {}, 0
  job.day = Spec.DayIndex(t)
  -- ¿Salen tus subastas en el escaneo? Si dos escaneos seguidos no ven ninguna cuando debería haberlas, en este
  -- personaje no se miden ventas, hasta que un escaneo vea alguna o conste que ya no tienes ninguna aquí (sin subastas
  -- tuyas, el escaneo no puede tomarlas por las del mercado). Si no se sabe (no se esperaba ninguna, pero la pestaña
  -- Subastas no se ha abierto o queda alguna seguida a la venta), todo sigue igual: tras un /reload, las de antes no
  -- suman, y la cuenta no debe perderse. Salvo si ya consta que el escaneo reconoce las tuyas (ownSeen «yes»): ahí un
  -- escaneo sin ver ninguna (vendida justo antes, una lista de la pestaña Subastas sin refrescar) no dice que el
  -- cliente no las reconozca, y solo cuentan los seguidos (un escaneo que no esperaba ninguna quita la cuenta). Lo
  -- mismo si algún escaneo ya vio alguna tuya en este personaje (ownEver): el cliente sí las reconoce, y un «no» de
  -- una lista sin refrescar se quita en el siguiente escaneo que no espera ninguna (y ese mide).
  local cleared = false
  if job.ownRows > 0 then cs.ownSeen, cs.ownMiss, cs.ownEver = "yes", nil, true
  else
    local expected, none, listed = expectedOwn(key, t, job.req and job.req.t)
    stats.ownedAuctions = listed
    if expected > 0 then
      cs.ownMiss = (cs.ownMiss or 0) + 1
      if cs.ownMiss >= Scanner.OWN_MISSES then cs.ownSeen = "no" end
    elseif cs.ownSeen == "yes" or cs.ownEver then
      cs.ownMiss = nil
      if cs.ownSeen == "no" then cs.ownSeen = "yes" end
    elseif none then
      cleared = cs.ownSeen == "no" or cs.ownMiss ~= nil
      cs.ownMiss = nil
      if cs.ownSeen == "no" then cs.ownSeen = nil end
    end
  end
  -- Ventas solo si se va a grabar y hay referencia de este personaje de 15 min a 2 h antes, con los mismos tramos, y
  -- no anterior al último escaneo de la cuenta que ya midió ventas aquí (con un alter, las dos medidas se pisarían).
  -- Tampoco el escaneo que quita el «no» (o la cuenta de escaneos sin las tuyas) sin constar que se reconocen: su
  -- referencia es de un escaneo que no reconoció tus subastas y puede tenerlas como si fueran del mercado (una que
  -- cancelaste contaría como vendida); la siguiente pareja ya parte de este. Ni, sin constar que se reconocen, si
  -- cancelaste alguna aquí desde la foto de la referencia. PairDue sigue las mismas reglas.
  local base = cdb.scanBase[key]
  local dt = base and t - base.t
  job.base, job.dt = base, dt
  job.sampling = Scanner.AllowRecord(key, t) and base ~= nil and dt >= Scanner.SAMPLE_MIN and dt <= Scanner.SAMPLE_MAX
    and job.known and job.bandsOK and base.off == offset and cs.ownSeen ~= "no" and not cleared
    and base.t >= (S.sampledUntil[key] or 0) and not cancelledSince(key, base)
  if job.sampling then
    job.sold, job.bought = {}, boughtIn(base.t, t)
    job.sampleStats = {items = 0, sold = 0, partial = 0, own = 0, dt = dt, from = base.t}
  end
  loadPrices(key)
  job.stage, job.cursor = "items", nil
end

-- Por objeto vigilado: subastas por precio (estable) -> lo, qty y qty5 (la misma regla que History).
local function sortItem(job, id)
  local P, C = job.P[id], job.C[id]
  local idx = {}
  for m = 1, #P do idx[m] = m end
  table.sort(idx, function(a, b)
    if P[a] ~= P[b] then return P[a] < P[b] end
    return a < b
  end)
  local lo, qty, qty5 = P[idx[1]], 0, 0
  for _, m in ipairs(idx) do
    qty = qty + C[m]
    if P[m] * 100 <= lo * 105 then qty5 = qty5 + C[m] end
  end
  job.agg[id] = {lo = lo, qty = min(qty, Spec.QTY_MAX), qty5 = min(qty5, Spec.QTY_MAX)}
  job.sorted[id] = idx
  job.present = job.present + 1
end

local function sampleItem(job, id)
  local levels = Scanner.DecodeLevels(job.base.items[id])
  if not levels then return end
  local idx, P, B, C = job.sorted[id], job.P[id], job.B[id], job.C[id]
  local maxPrice = levels[#levels][1]
  local current = {}
  for _, m in ipairs(idx) do
    if P[m] > maxPrice then break end
    local list = current[P[m]]
    if not list then list = {}; current[P[m]] = list end
    list[#list + 1] = {B[m] - job.offset, C[m]}
  end
  local own = job.bought[id] or 0
  local s, partial = Spec.InferSold(levels, current, job.dt, job.bandMin, own)
  job.sold[id] = min(s, Spec.SOLD_MAX)
  local st = job.sampleStats
  st.items, st.sold, st.partial, st.own = st.items + 1, st.sold + s, st.partial + partial, st.own + own
end

local function finishEnd(job)
  local t, key = job.t, job.key
  -- Filtro de grabado (otra vez: un resumen retenido pudo grabarse mientras se cerraba este).
  local record = Scanner.AllowRecord(key, t)
  local previous = S.recorded[key]
  local opts = {t = t}
  if record and job.sampling then
    opts.dt, opts.sold = job.dt, job.sold
    stats.lastSamples = job.sampleStats
  end
  if record then
    if History.RecordAggregate("full", job.agg, true, opts) then
      markRecorded(key, t)
      if opts.dt then
        S.sampledUntil[key] = max(S.sampledUntil[key] or 0, t)
        capByVisit(S.sampledUntil, key, Scanner.VISITED_MAX)
      end
    else
      record = false
    end
  end
  -- Este escaneo es la nueva referencia del personaje (grabado o no).
  storeBaseline(job, key)
  -- Un resumen de Auctionator retenido de este mercado ya no hace falta.
  held[key] = nil
  result = {state = record and "done" or "done-refresh", at = t, items = job.present,
            samplesFrom = opts.dt and job.base.t or nil, recordedAt = record and t or previous}
  job.closed = true
  -- Core: fechas, avisos y ventana.
  if cb.onScanDone then protect("escaneo terminado", cb.onScanDone, "full", true, t) end
end

local PRICES_PER_UNIT = 64

finishStep = function(job)
  local profile = type(debugprofilestop) == "function" and debugprofilestop or nil
  local start = profile and profile()
  if not job.stage then
    finishBegin(job)
    if job.closed then return end
  end
  local units = 0
  while not job.closed do
    local stage = job.stage
    if stage == "items" then
      local id = next(job.P, job.cursor)
      if id == nil then job.stage, job.cursor = "prices", nil else job.cursor = id; sortItem(job, id) end
    elseif stage == "prices" then
      -- Caché de precios: todo lo visto, grabado o no.
      if priceKey ~= job.key then loadPrices(job.key) end
      local id, lo = job.cursor, nil
      for _ = 1, PRICES_PER_UNIT do
        id, lo = next(job.lo, id)
        if id == nil then break end
        priceLo[id], priceDay[id] = lo, job.day
      end
      priceDirty = true
      if id == nil then
        db.scanPrices[job.key] = db.scanPrices[job.key] or {text = ""}
        db.scanPrices[job.key].t = max(db.scanPrices[job.key].t or 0, job.t)
        job.stage, job.cursor = "samples", nil
      else
        job.cursor = id
      end
    elseif stage == "samples" then
      local id = job.sampling and next(job.sorted, job.cursor) or nil
      if id == nil then job.stage, job.cursor = "baseline", nil else job.cursor = id; sampleItem(job, id) end
    elseif stage == "baseline" then
      local id = next(job.sorted, job.cursor)
      if id == nil then finishEnd(job) else job.cursor = id; baselineItem(job, id) end
    end
    units = units + 1
    if profile then
      if profile() - start > Scanner.BUDGET_MS then break end
    elseif units >= Scanner.FINISH_UNITS then
      break
    end
  end
  local spent = profile and (profile() - start) or 0
  job.finishFrames = (job.finishFrames or 0) + 1
  stats.finishFrames = job.finishFrames
  if spent > (stats.finishMaxMs or 0) or job.finishFrames == 1 then stats.finishMaxMs = spent end
end

---------------------------------------------------------------------------
-- Resúmenes de Auctionator retenidos (un escaneo completo de la misma visita los sustituye)
---------------------------------------------------------------------------
local function release(key)
  local h = held[key]
  held[key] = nil
  if not h then return end
  -- De la subasta neutral o de una que no se sabe: no se guarda (otro mercado).
  if otherHouse() then return end
  local record = Scanner.AllowRecord(key, h.t)
  if record then markRecorded(key, h.t) end
  stats.lastHeld = {t = h.t, recorded = record}
  if cb.onSummaryRelease then protect("resumen", cb.onSummaryRelease, h, record) end
end

-- ¿Puede llegar todavía un escaneo completo en esta visita? Si no, se suelta ya.
local function fullScanPossible()
  if not ahOpen or house ~= "faction" or noresponse then return false end
  if windowOpen or reading or queued then return true end
  if S.auto == "off" then return false end
  if nextAllowedAt() - (now() or 0) > Scanner.HOLD then return false end
  return true
end

checkHeld = function()
  for key, h in pairs(held) do
    if not fullScanPossible() or clock() - h.at >= Scanner.HOLD then release(key) end
  end
end

-- Core, al terminar un escaneo de resumen entero de Auctionator con este archivo cargado: {t, rows, data, market}.
-- Devuelve true si queda retenido (se suelta al cerrar la subasta, a los 10 min o en cuanto no pueda llegar el
-- completo) o false si se soltó en el acto.
function Scanner.HoldSummary(summary)
  if type(summary) ~= "table" or not S then return false end
  local key = summary.market or market()
  if not validMarket(key) then return false end
  if otherHouse() then return "drop" end -- subasta neutral o que no se sabe: ni se retiene ni se graba
  -- Hora del servidor: una hora futura (la del reloj del PC adelantado) llevaría el filtro de grabado de toda la cuenta
  -- al futuro, y el resumen acaba de terminar.
  local t = now()
  summary.market, summary.t = key, (isTime(summary.t) and not (t and summary.t > t)) and summary.t or t
  summary.at = clock()
  if held[key] then release(key) end
  held[key] = summary
  if not fullScanPossible() then release(key); return false end
  after(Scanner.HOLD, function() protect("resumen", checkHeld) end)
  return true
end

function Scanner.Held(key) return held[key or market() or ""] end

-- PLAYER_LOGOUT (al salir o con cualquier /reload, también «Guardar y subir»), antes de History.Flush: los resúmenes
-- retenidos solo están en memoria, así que se sueltan ya (con su filtro de grabado) para que se escriban.
function Scanner.ReleaseHeld()
  if not S then return end
  for key in pairs(held) do release(key) end
end

---------------------------------------------------------------------------
-- Modos, propuesta y revisión de cada minuto con la subasta abierta
---------------------------------------------------------------------------
local function deferToAuctionator()
  local P = ns.Prices
  if not P or type(P.AutoscanEnabled) ~= "function" or type(P.AutoscanReplicate) ~= "function" then return false end
  return P.AutoscanEnabled() == true and P.AutoscanReplicate() == true
end
Scanner.DeferToAuctionator = deferToAuctionator

local function userBusy()
  local t = now() or 0
  if lastUserAction and t - lastUserAction < Scanner.BUSY then return true end
  local frame = _G.AuctionHouseFrame
  if type(frame) ~= "table" then return false end
  for _, name in ipairs({"CommoditiesSellFrame", "ItemSellFrame"}) do
    local sell = frame[name]
    if type(sell) == "table" and type(sell.GetItem) == "function" then
      local ok, item = pcall(sell.GetItem, sell)
      if ok and item ~= nil then return true end
    end
  end
  return false
end
Scanner.UserBusy = userBusy

local function newestMate(key)
  local m = History.Market(key)
  local newest = 0
  for _, entry in pairs(m and type(m.obs) == "table" and m.obs or {}) do
    if isTime(entry.seen) and entry.seen > newest then newest = entry.seen end
  end
  return newest
end

local function blockLabel(block) return (block * 4) .. "-" .. (block * 4 + 4) .. " h" end

-- La razón para proponer un escaneo ahora (la primera que vale) y su texto, o nil.
function Scanner.Proposal()
  if not (S and ahOpen and house == "faction") or deferToAuctionator() then return nil end
  local key, t = market(), now()
  if not (key and t) or not Scanner.RecordDue(key, t) then return nil end
  if Scanner.PairDue(key, t) then
    local minutes = floor((t - cdb.scanBase[key].t) / 60)
    return {reason = "pareja", text = "Escaneaste hace " .. minutes .. " min: si escaneas ahora, el addon mide lo que se "
      .. "ha vendido entre los dos escaneos."}
  end
  local newest = max(S.recorded[key] or 0, newestMate(key))
  if newest == 0 then
    return {reason = "stale", text = "Nadie de la hermandad ha escaneado aún esta subasta."}
  elseif t - newest >= Scanner.STALE then
    return {reason = "stale", text = "Hace " .. minutesOrHours(t - newest) .. " que nadie de la hermandad escanea esta subasta."}
  end
  local Timing = ns.Timing
  if type(Timing) == "table" and type(Timing.Coverage) == "function" then
    local _, _, block = Spec.MadridSlot(t)
    local ok, coverage = pcall(Timing.Coverage, key, block)
    if ok and type(coverage) == "number" and coverage < 2 then
      return {reason = "thin", text = "La franja " .. blockLabel(block) .. " tiene pocos datos para «Cuándo vender».", block = block}
    end
  end
  return nil
end

-- Modo «proponer» con la ventana cerrada: una línea en el chat por visita y como mucho cada 30 min.
local function proposeInChat()
  if S.auto ~= "propose" or chattedVisit or blockReason() then return end
  if lastChat and clock() - lastChat < Scanner.CHAT_SPACING then return end
  local shown = false
  if cb.windowShown then
    local ok, value = pcall(cb.windowShown)
    shown = ok and value == true
  end
  if shown then return end
  local p = Scanner.Proposal()
  if not p or not cb.say then return end
  chattedVisit, lastChat = true, clock()
  protect("propuesta", cb.say, p.text .. " Escribe /oro escanear (unos segundos).")
end

-- Modo automático: al abrir la subasta, en cuanto se pueda (lo grabe o no el filtro); después, solo si toca grabar o
-- medir ventas. Nunca con el escaneo completo de Auctionator activado ni mientras publicas o compras.
local function autoRequest()
  if S.auto ~= "auto" or noresponse or not ahOpen or house ~= "faction" then return end
  if deferToAuctionator() or userBusy() or blockReason() then return end
  if visitScanned then
    local key, t = market(), now()
    if not (Scanner.RecordDue(key, t) or Scanner.PairDue(key, t)) then return end
  end
  Scanner.Request(false)
end

local function review(token)
  if token ~= visitToken or not ahOpen then return end
  protect("revisión", autoRequest)
  protect("propuesta", proposeInChat)
  protect("resumen", checkHeld)
  notify()
end

local function tick(token)
  if token ~= visitToken or not ahOpen then return end
  review(token)
  after(Scanner.TICK, function() tick(token) end)
end

-- AUCTION_HOUSE_SHOW: Core lo llama antes que lo demás (para saber qué subasta es).
function Scanner.OnShow()
  if not S then return end
  protect("subasta abierta", function()
    ahOpen, showAt, visitScanned, chattedVisit = true, clock(), false, false
    visitToken = visitToken + 1
    result = nil
    detectHouse()
    touchVisited(market())
    -- Una petición de la subasta entera hecha mientras se abría (la de Auctionator al mostrar su marco): su respuesta
    -- aún no ha llegado, así que se escucha desde aquí.
    local e = early
    early = nil
    if e and house == "faction" and clock() - e.at <= Scanner.EARLY and not windowOpen and not reading then
      req = {t = e.t, ours = e.ours, resent = false}
      openWindow()
    end
    local token = visitToken
    if house == "faction" then
      after(Scanner.OPEN_DELAY, function() review(token) end)
      after(Scanner.TICK, function() tick(token) end)
    end
    notify()
  end)
end

local stopSweep

-- AUCTION_HOUSE_CLOSED: lo que se estaba pidiendo o leyendo se descarta; «Escanear la lista» se graba como parcial.
function Scanner.OnClose()
  if not S then return end
  protect("subasta cerrada", function()
    local interrupted = windowOpen or reading ~= nil or queued ~= nil
    if windowOpen then closeWindow() end
    if listening then listen(false) end
    reading, queued, phase = nil, nil, nil
    if sweep then stopSweep() end
    ahOpen = false
    early = nil
    visitToken = visitToken + 1
    for key in pairs(held) do release(key) end
    if interrupted then result = {state = "interrupted", at = now()} end
    house = nil
    notify()
  end)
end

function Scanner.SetMode(mode)
  if not S or (mode ~= "auto" and mode ~= "propose" and mode ~= "off") then return nil end
  S.auto = mode
  if ahOpen then protect("modo", checkHeld); protect("modo", autoRequest) end
  notify()
  return mode
end

function Scanner.SetSales(on)
  if not S then return nil end
  S.sales = on and true or false
  return S.sales
end

---------------------------------------------------------------------------
-- «Escanear la lista»: una búsqueda por objeto vigilado (solo si lo pides)
---------------------------------------------------------------------------
local sweepStep
local sweepSeq = 0

local function sweepPaused()
  local frame = _G.AuctionHouseFrame
  if type(frame) ~= "table" then return false end
  if type(frame.IsListingAuctions) == "function" then
    local ok, listing = pcall(frame.IsListingAuctions, frame)
    if ok and listing then return true end
  end
  local modes = _G.AuctionHouseFrameDisplayMode
  if type(frame.GetDisplayMode) == "function" and type(modes) == "table" and modes.Auctions ~= nil then
    local ok, mode = pcall(frame.GetDisplayMode, frame)
    if ok and mode == modes.Auctions then return true end
  end
  return false
end

local function itemKeyOf(id)
  local ok, key = ah("MakeItemKey", id)
  if ok and type(key) == "table" then return key end
  return nil
end

local function keyReady(key)
  local ok, info = ah("GetItemKeyInfo", key)
  return ok and info ~= nil
end

local function nextItem(answered, lo, qty, qty5)
  local cur = sweep.cur
  if answered then
    sweep.answered = sweep.answered + 1
    if lo then sweep.agg[cur.id] = {lo = lo, qty = qty, qty5 = qty5}; sweep.lo[cur.id] = lo end
  else
    sweep.unanswered = sweep.unanswered + 1
  end
  sweep.cur = nil
  sweep.index = sweep.index + 1
  notify()
end

-- Un solo paso programado a la vez: cada uno lleva su número y uno que se adelanta (stepNow, con un evento de la
-- subasta) deja sin valor al que estaba esperando, que ya no corre ni se vuelve a programar.
local function scheduleSweep(wait)
  sweep.step = sweep.step + 1
  local token, step = sweep.token, sweep.step
  after(wait, function()
    if sweep and sweep.token == token and sweep.step == step then protect("lista", sweepStep, token) end
  end)
end

local function stepNow()
  sweep.step = sweep.step + 1
  sweepStep(sweep.token)
end

sweepStep = function(token)
  if not sweep or sweep.token ~= token then return end
  if not ahOpen then stopSweep(); return end
  if sweepPaused() then
    if not sweep.paused then sweep.paused = true; notify() end
    return scheduleSweep(Scanner.SWEEP_POLL)
  end
  if sweep.paused then sweep.paused = false; notify() end
  local c = clock()
  local cur = sweep.cur
  if not cur then
    local w = sweep.items[sweep.index]
    if not w then return finishSweep(sweep.unanswered == 0) end
    cur = {id = w.id, key = itemKeyOf(w.id), phase = "key", since = c, tries = 0}
    sweep.cur = cur
    if not cur.key then nextItem(false); return scheduleSweep(0) end
  end
  if cur.phase == "key" then
    if keyReady(cur.key) then
      cur.phase = "query"
    elseif c - cur.since >= Scanner.SWEEP_KEY_WAIT then
      nextItem(false) -- sin datos del objeto: una búsqueda así se ignora a menudo
      return scheduleSweep(0)
    else
      return scheduleSweep(Scanner.SWEEP_POLL)
    end
  end
  if cur.phase == "query" then
    local wait = sweep.lastQuery + Scanner.SWEEP_SPACING - c
    if wait > 0 then return scheduleSweep(wait) end
    if not throttledReady() or scanRunning() then return scheduleSweep(Scanner.SWEEP_POLL) end
    local sorts = {{sortOrder = type(Enum) == "table" and type(Enum.AuctionHouseSortOrder) == "table"
                    and Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false}}
    local ok = ah("SendSearchQuery", cur.key, sorts, false)
    sweep.lastQuery, cur.sentAt, cur.tries, cur.phase = c, c, cur.tries + 1, "wait"
    stats.queries = stats.queries + 1
    if not ok then cur.sentAt = c - Scanner.SWEEP_ANSWER end
    return scheduleSweep(ok and Scanner.SWEEP_ANSWER or 0)
  end
  if cur.phase == "wait" then
    if c - cur.sentAt < Scanner.SWEEP_ANSWER then return scheduleSweep(cur.sentAt + Scanner.SWEEP_ANSWER - c) end
    if cur.tries < 2 then cur.phase = "query"; return scheduleSweep(0) end -- un reintento
    nextItem(false)
    return scheduleSweep(0)
  end
end

-- Lo que la subasta acaba de cargar de una mercancía: el precio más bajo sin tus unidades, las unidades (sin las
-- tuyas) y las que hay hasta un 5 % por encima del mínimo.
local function readCommodity(id)
  local okCount, count = ah("GetNumCommoditySearchResults", id)
  count = okCount and readable(count) or 0
  if not isInt(count, 0, 100000) then count = 0 end
  local prices, units, own, rows = {}, {}, 0, 0
  local lo
  for i = 1, count do
    local ok, info = ah("GetCommoditySearchResultInfo", id, i)
    if ok and type(info) == "table" then
      local price, qty, mine = readable(info.unitPrice), readable(info.quantity), readable(info.numOwnerItems) or 0
      if isInt(qty, 0, Spec.QTY_MAX) and type(price) == "number" and price > 0 then
        own = own + (isInt(mine, 0, qty) and mine or 0)
        local q = qty - (isInt(mine, 0, qty) and mine or 0)
        if q > 0 then
          price = floor(price + 0.5)
          prices[#prices + 1], units[#units + 1] = price, q
          rows = rows + q
          if not lo or price < lo then lo = price end
        end
      end
    end
  end
  if not lo then return nil end
  local okTotal, total = ah("GetCommoditySearchResultsQuantity", id)
  total = okTotal and readable(total) or nil
  local qty = isInt(total, 0, Spec.QTY_MAX) and max(0, total - own) or rows
  local qty5 = 0
  for k = 1, #prices do if prices[k] * 100 <= lo * 105 then qty5 = qty5 + units[k] end end
  return lo, min(max(qty, rows), Spec.QTY_MAX), min(qty5, Spec.QTY_MAX)
end

-- ITEM_KEY_ITEM_INFO_RECEIVED (itemID): ya se puede buscar ese objeto.
function Scanner.OnItemKeyInfo(itemID)
  if not sweep or not sweep.cur or sweep.cur.phase ~= "key" or sweep.cur.id ~= readable(itemID) then return end
  sweep.cur.phase = "query"
  protect("lista", stepNow)
end

-- COMMODITY_SEARCH_RESULTS_UPDATED (itemID): la respuesta de la búsqueda (Core además guarda el libro, CaptureBook).
function Scanner.OnCommodityResults(itemID)
  if not sweep or not sweep.cur or sweep.cur.phase ~= "wait" or sweep.cur.id ~= readable(itemID) then return end
  protect("lista", function()
    nextItem(true, readCommodity(sweep.cur.id))
    stepNow()
  end)
end

-- ITEM_SEARCH_RESULTS_UPDATED (itemKey): un objeto que no es mercancía respondió; no da precio por unidad.
function Scanner.OnItemResults(itemKey)
  if not sweep or not sweep.cur or sweep.cur.phase ~= "wait" then return end
  local id = type(itemKey) == "table" and readable(itemKey.itemID) or nil
  if id ~= sweep.cur.id then return end
  protect("lista", function()
    nextItem(true)
    stepNow()
  end)
end

finishSweep = function(whole)
  local s = sweep
  sweep = nil
  if not s then return end
  local key = market()
  local t = s.t
  local any = next(s.agg) ~= nil
  local record = false
  if key and any then
    mergePrices(key, s.lo, t)
    if Scanner.AllowRecord(key, t) and History.RecordAggregate("lista", s.agg, whole, {t = t}) then
      markRecorded(key, t)
      record = true
    end
  end
  stats.lastSweep = {answered = s.answered, total = #s.items, whole = whole, t = t, recorded = record}
  result = {state = record and "done" or "done-refresh", at = t, items = 0, recordedAt = record and t or (key and S.recorded[key]),
            sweep = true}
  for id in pairs(s.agg) do result.items = result.items + 1 end
  if cb.onScanDone then protect("escaneo terminado", cb.onScanDone, "lista", whole, t) end
  notify()
end

stopSweep = function()
  if sweep then finishSweep(false) end
end

-- /oro escanear lista o el botón «Escanear la lista». Devuelve true o false y el motivo.
function Scanner.StartSweep()
  if not S then return false, "closed" end
  if not ahOpen then return false, "closed" end
  if house == "neutral" or house == "unknown" then return false, house end
  if sweep or reading or windowOpen or queued then return false, "running" end
  local items = {}
  for _, w in ipairs(History.WatchList()) do items[#items + 1] = {id = w.id} end
  sweepSeq = sweepSeq + 1
  sweep = {items = items, index = 1, answered = 0, unanswered = 0, agg = {}, lo = {}, lastQuery = -math.huge,
           t = now(), token = sweepSeq, step = 0, paused = false}
  result = nil
  notify()
  protect("lista", sweepStep, sweep.token)
  return true
end

-- «Parar» o /oro escanear parar: para la lista (se graba lo leído, como parcial) o la lectura (se descarta).
function Scanner.Stop()
  if sweep then stopSweep(); return "sweep" end
  if reading or windowOpen or queued then
    if windowOpen then closeWindow() end
    reading, queued, phase = nil, nil, nil
    notify()
    return "read"
  end
  return nil
end

---------------------------------------------------------------------------
-- Estado y textos (la ventana, /oro escanear y /oro sondeo)
---------------------------------------------------------------------------
-- {state, progress, at, reason, nextAt, canScan, done, total, paused, items, samplesFrom, recordedAt}. state: closed,
-- neutral, unknown, ready, wait, auctionator, queued, requested, other, reading, done, done-refresh, timeout,
-- noresponse, sweep o interrupted.
function Scanner.State()
  local st = {}
  if not S then st.state = "closed"; return st end
  local t = now() or 0
  local canScan = blockReason() == nil
  st.canScan = canScan
  if not ahOpen then
    if result and result.state == "interrupted" and t - (result.at or 0) < 60 then st.state, st.at = "interrupted", result.at
    else st.state = "closed" end
    return st
  end
  if house == "neutral" or house == "unknown" then st.state = house; return st end
  if sweep then
    st.state, st.done, st.total, st.paused = "sweep", sweep.index - 1, #sweep.items, sweep.paused
    st.progress = st.total > 0 and st.done / st.total or 0
    return st
  end
  if reading then
    st.state, st.progress = "reading", reading.n > 0 and min(1, reading.i / reading.n) or 0
    return st
  end
  if windowOpen then st.state = (req and req.ours) and "requested" or "other"; return st end
  if queued then st.state = "queued"; return st end
  st.nextAt = nextAllowedAt()
  if noresponse then st.state = "noresponse"; return st end
  if result and (result.state == "done" or result.state == "done-refresh" or result.state == "timeout") and not canScan then
    st.state, st.at, st.items, st.samplesFrom, st.recordedAt = result.state, result.at, result.items, result.samplesFrom,
      result.recordedAt
    return st
  end
  if not canScan and t < st.nextAt then st.state = "wait"; return st end
  if deferToAuctionator() then st.state = "auctionator"; return st end
  st.state = "ready"
  return st
end

local TEXTS = {
  neutral = "Subasta neutral (goblin): es otro mercado y sus precios no se guardan.",
  unknown = "No sé si esta es la subasta de tu facción o la neutral (goblin): aquí no se guardan precios. /oro sondeo da los detalles.",
  ready = "Escaneo de la subasta: listo (unos segundos).",
  auctionator = "Auctionator escanea la subasta entera al abrirla: Oro de Hermandad usa ese escaneo.",
  queued = "Esperando a la subasta…",
  requested = "Pidiendo la subasta entera…",
  other = "Otro addon ha pedido la subasta entera: se usa su respuesta.",
  noresponse = "La subasta no responde al escaneo completo. Prueba «Escanear la lista» (2-3 min).",
  interrupted = "Escaneo interrumpido al cerrar la subasta.",
  paused = "Escaneo de la lista en pausa mientras vendes o miras tus subastas.",
}
Scanner.TEXTS = TEXTS

-- Texto de la ventana para un estado de Scanner.State() ("" con la subasta cerrada).
function Scanner.StateText(st)
  st = st or Scanner.State()
  local s = st.state
  if TEXTS[s] and s ~= "paused" then return TEXTS[s] end
  if s == "wait" then
    return "Siguiente escaneo completo posible a las " .. hhmm(st.nextAt) .. " (la subasta deja uno cada 15 min por cuenta)."
  elseif s == "reading" then
    return "Escaneando: " .. floor((st.progress or 0) * 100) .. " %"
  elseif s == "done" then
    local text = "Escaneo de las " .. hhmm(st.at) .. " guardado: " .. (st.items or 0) .. " objetos vigilados a la venta."
    if st.samplesFrom then text = text .. " Ventas medidas desde las " .. hhmm(st.samplesFrom) .. "." end
    return text
  elseif s == "done-refresh" then
    return "Escaneo de las " .. hhmm(st.at) .. ": precios al día (el de las " .. hhmm(st.recordedAt or st.at)
      .. " ya cuenta para «Cuándo vender»)."
  elseif s == "timeout" then
    return "La subasta no ha respondido (quizá otro addon escaneó hace menos de 15 min). Se puede volver a intentar a las "
      .. hhmm(st.nextAt) .. "."
  elseif s == "sweep" then
    if st.paused then return TEXTS.paused end
    local left = max(0, (st.total or 0) - (st.done or 0))
    local minutes = max(1, math.ceil(left * Scanner.SWEEP_SPACING / 60))
    return "Escaneando la lista vigilada: " .. (st.done or 0) .. "/" .. (st.total or 0) .. " (unos " .. minutes
      .. " min). No vendas ni compres mientras dura; «Parar» lo detiene."
  end
  return ""
end

-- «Escanear la lista» se ofrece cuando el escaneo completo no se puede pedir en más de 5 min o la subasta no responde.
function Scanner.OfferSweep()
  if not (S and ahOpen and house == "faction") or sweep then return false end
  return noresponse or nextAllowedAt() - (now() or 0) > 300
end

local MODE_TEXTS = {
  auto = "escanear la subasta: automático cada vez que la abres.",
  propose = "escanear la subasta: te lo propone el addon.",
  off = "escanear la subasta: solo con el botón o /oro escanear.",
}

local function refusal(why)
  if why == "closed" then return "abre la subasta y vuelve a escribirlo." end
  if why == "neutral" then return "subasta neutral: aquí no se guardan precios." end
  if why == "unknown" then return "no sé si esta es la subasta de tu facción: aquí no se guardan precios." end
  if why == "throttle" then
    return "la subasta deja un escaneo completo cada 15 min por cuenta: el siguiente, a las " .. hhmm(nextAllowedAt()) .. "."
  end
  if why == "other" then return "otro addon acaba de pedir la subasta entera: se usará su respuesta." end
  if reading then return "ya se está escaneando (" .. floor(min(1, reading.i / max(1, reading.n)) * 100) .. " %)." end
  if sweep then return "ya se está escaneando la lista (" .. (sweep.index - 1) .. "/" .. #sweep.items .. ")." end
  return "ya se está escaneando (0 %)."
end

-- /oro escanear [lista|parar|auto|proponer|off]: hace lo pedido y devuelve la línea para el chat.
function Scanner.Command(arg)
  arg = type(arg) == "string" and arg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
  if arg == "auto" or arg == "proponer" or arg == "off" then
    local mode = arg == "proponer" and "propose" or arg
    Scanner.SetMode(mode)
    return MODE_TEXTS[mode]
  end
  if arg == "parar" then
    local stopped = Scanner.Stop()
    if stopped == "sweep" then return "escaneo de la lista parado: se guarda lo leído." end
    if stopped == "read" then return "escaneo parado: no se ha guardado nada." end
    return "no hay ningún escaneo en marcha."
  end
  if arg == "lista" then
    local ok, why = Scanner.StartSweep()
    if ok then return Scanner.StateText() end
    return refusal(why)
  end
  local ok, why = Scanner.Request(true)
  if ok then return Scanner.StateText() end
  return refusal(why)
end

---------------------------------------------------------------------------
-- Al salir: caché de precios (solo si cambió), ventas, compras, subastas seguidas
---------------------------------------------------------------------------
function Scanner.BeforeSave()
  if not db or not S then return end
  protect("al salir", function()
    local t = now()
    flushPrices()
    if t then
      pruneBuys(t)
      pruneAuctions(t)
      pruneOther(t)
      for key in pairs(db.sales) do
        local kept = {}
        for _, r in ipairs(salesList(key)) do if r[1] > t - Scanner.SALES_DAYS * 86400 then kept[#kept + 1] = r end end
        while #kept > Scanner.SALES_MAX do table.remove(kept, 1) end
        db.sales[key] = #kept > 0 and encodeRecords(kept) or nil
      end
      capByVisit(db.sales, market(), Scanner.SALES_MARKETS)
    end
  end)
end

---------------------------------------------------------------------------
-- /oro sondeo: solo cifras, nunca nombres
---------------------------------------------------------------------------
local HOUSE_NAMES = {faction = "facción", neutral = "neutral", unknown = "desconocida"}
local MODE_NAMES = {auto = "automático", propose = "proponer", off = "solo con el botón"}

local function timeText(t) return t and (hhmm(t) .. " (" .. t .. ")") or "nunca" end

function Scanner.ProbeLines()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  if not S then add("Escáner de la subasta: no iniciado."); return lines end
  local st = Scanner.State()
  local key = market()
  add("Escáner: modo " .. (MODE_NAMES[S.auto] or "?") .. ", estado " .. st.state .. ", gancho "
    .. (Scanner.hooked and "sí" or "no") .. ", escucha " .. (listening and "sí" or "no") .. ", no responde "
    .. (noresponse and "sí" or "no") .. ", sin respuesta seguidas " .. (S.timeouts or 0)
    .. ", usa el de Auctionator " .. (deferToAuctionator() and "sí" or "no"))
  if ahOpen then
    local i = houseInfo
    add("Casa: " .. (HOUSE_NAMES[house] or "?") .. " (regla " .. tostring(i.rule) .. "; npc: " .. tostring(i.npc)
      .. ", id " .. tostring(i.npcID or "-") .. ", mapa " .. tostring(i.map or "-") .. ", zona " .. tostring(i.zone or "-")
      .. ", depósito ×" .. (i.ratio and string.format("%.2f", i.ratio):gsub("%.", ",") or "-") .. ")")
  end
  add("Peticiones: tuya " .. timeText(S.lastOwnRequest) .. " · respondida " .. timeText(S.lastSuccess)
    .. " · de cualquier addon " .. timeText(S.lastAnyRequest) .. " · de otros addons " .. stats.otherRequests
    .. " (sin respuesta " .. stats.otherUnanswered .. ") · respuesta en " .. tostring(stats.answerSeconds or "-")
    .. " s · avisos en el segundo de espera " .. tostring(stats.settleEvents or "-") .. " · rechazadas por huella "
    .. stats.strayRejected)
  local r = stats.lastRead
  if r then
    local statuses = {}
    for v in pairs(r.statuses or {}) do statuses[#statuses + 1] = tostring(v) end
    table.sort(statuses)
    add("Última lectura: " .. r.rows .. " filas de " .. r.n .. ", vigiladas " .. r.watchedRows .. ", tuyas " .. r.ownRows
      .. " (la subasta dice " .. tostring(stats.ownedAuctions or "-") .. "), con dueño ajeno " .. r.foreign
      .. ", fotogramas " .. r.frames .. ", máx. " .. string.format("%.2f", r.maxMs) .. " ms, total "
      .. string.format("%.1f", r.totalMs) .. " ms, cierre en " .. tostring(stats.finishFrames or "-") .. " tandas (máx. "
      .. (stats.finishMaxMs and string.format("%.2f", stats.finishMaxMs) or "-") .. " ms) · tramo bruto " .. tostring(r.rawMin or "-") .. "-" .. tostring(r.rawMax or "-")
      .. ", desfase " .. tostring(S.bandOffset or "-") .. ", GetTimeLeftBandInfo " .. tostring(stats.bandInfo or "-")
      .. " · saleStatus " .. (#statuses > 0 and table.concat(statuses, ",") or "-"))
  end
  add("Tus subastas en el escaneo: " .. (cs.ownSeen == "yes" and "se reconocen" or cs.ownSeen == "no" and "no" or "sin comprobar")
    .. (cs.ownSeen == "no" and " (Tus subastas no se reconocen en el escaneo: no se miden ventas en este personaje.)" or ""))
  if key then
    add("Grabados hoy: " .. Scanner.RecordedToday(key) .. " de " .. Scanner.RECORD_PER_DAY .. ", último "
      .. timeText(S.recorded[key]))
    local base = cdb.scanBase[key]
    if base then
      local n, bytes, auctions = 0, 0, 0
      for _, text in pairs(base.items) do
        n, bytes = n + 1, bytes + #text
        local _, c = text:gsub("[,;]", "")
        auctions = auctions + c + 1
      end
      add("Referencia de ventas: " .. n .. " objetos, unas " .. auctions .. " subastas, " .. bytes .. " bytes, de hace "
        .. minutesOrHours((now() or base.t) - base.t))
    end
  end
  local s = stats.lastSamples
  if s then
    add("Últimas ventas medidas: " .. s.items .. " objetos, " .. s.sold .. " unidades (parciales " .. s.partial
      .. ", compras tuyas descontadas " .. s.own .. ") en " .. s.dt .. " s")
  end
  if stats.lastHeld then add("Resumen de Auctionator retenido a las " .. hhmm(stats.lastHeld.t) .. ": " .. (stats.lastHeld.recorded and "grabado" or "solo precios")) end
  local sw = stats.lastSweep
  if sw then add("Última lista: " .. sw.answered .. "/" .. sw.total .. " respondidos" .. (sw.whole and "" or " (parcial)")) end
  local info = Scanner.CacheInfo()
  add("Caché de precios: " .. info.entries .. " entradas, " .. info.bytes .. " bytes, " .. plural(info.markets, "mercado", "mercados"))
  local salesN, last = 0, nil
  for _, rec in ipairs(Scanner.Sales(key)) do salesN = salesN + 1; last = rec[1] end
  local tracked = 0
  for _ in pairs(cdb.auctions) do tracked = tracked + 1 end
  add("Ventas: " .. salesN .. " apuntadas" .. (last and (", la última a las " .. hhmm(last)) or "") .. " · publicaciones pendientes "
    .. #pending .. " · subastas seguidas " .. tracked .. " · compras apuntadas " .. #decodeRecords(S.buys, 3)
    .. " · apuntar ventas " .. (S.sales and "sí" or "no"))
  if Scanner.lastError then add("Último fallo del escáner: " .. tostring(Scanner.lastError)) end
  return lines
end

-- Para las pruebas: estado interno.
function Scanner.Internals()
  return {windowOpen = windowOpen, listening = listening, reading = reading, queued = queued, phase = phase, req = req,
          held = held, pending = pending, sweep = sweep, stats = stats, noresponse = noresponse, result = result,
          visitScanned = visitScanned, house = house, early = early}
end

return Scanner

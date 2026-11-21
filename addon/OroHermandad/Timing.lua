-- Oro de Hermandad: «Cuándo vender» en el juego (0.6.0, /oro cuando). Por objeto vigilado y franja de 4 horas (hora de
-- España, contrato C5): si el precio más bajo suele estar por encima o por debajo de lo normal y, con las ventas
-- estimadas entre dos escaneos de la misma persona, si se vende más o menos que de media. Funciona sin conexión, con
-- tus escaneos y los de la hermandad (los puntos de OroHermandadHist), y aconseja con la misma regla que el panel
-- (contrato C11, timing-advice.json: 3 mediciones en 2 días distintos por franja, sin la mayor de cada franja).
-- Lo guardado (OroHermandadDB.timing[mercado]) son sumas que se van olvidando (media vida de 14 días) y, para no contar
-- dos veces un escaneo, las horas de los escaneos ya sumados de cada observador (tú = "self"; cada compañero, su
-- código de 8 cifras: nunca un nombre).
-- Al entrar, una primera pasada lee por tandas lo que aún no se ha sumado y lo suma de una vez al final (si se sale
-- antes, no cambia nada); después, cada punto que escriben History.lua (lo tuyo) y Relay.lua (lo de los compañeros) se
-- suma al llegar, por tandas de 1,5 ms, solo con el historial quieto y nunca en combate. Dos personas que miden las
-- mismas compras cuentan una vez: una venta que se solapa más de la mitad con la de otra persona ya sumada no cuenta.
-- Invisible: nada en el chat, ningún sonido. Los fallos van a Timing.lastError (/oro sondeo).
local _, ns = ...
local Data, Items, Spec, History = ns.Data, ns.Items, ns.Spec, ns.History
local Timing = {}
ns.Timing = Timing

Timing.HALF_LIFE = 14 * 86400        -- lo de hace dos semanas pesa la mitad
Timing.MAX_BYTES = 64 * 1024         -- por mercado
Timing.MARKETS = 4
Timing.OWN_SECONDS = 14 * 86400      -- escaneos tuyos sumados que se recuerdan (y puntos tuyos de la primera pasada)
Timing.MATE_SECONDS = 4 * 86400      -- los de compañeros
Timing.MATE_POINTS = 3 * 86400       -- puntos de compañeros que lee la primera pasada (los que guarda History)
Timing.INDEX_SECONDS = 74 * 3600     -- ventas recientes con las que se mira si una nueva se solapa
Timing.FIRST_DELAY, Timing.RETRY = 30, 10
Timing.BUDGET_MS = 1.5
Timing.UNITS = 16                    -- sin debugprofilestop: puntos por tanda en directo
Timing.PASS_UNITS = 8                -- y lo de un observador en un objeto, en la primera pasada
Timing.WAIT = 1                      -- con el historial escribiendo o en combate se mira cada segundo
Timing.QUEUE_MAX = 6000              -- puntos esperando (unos 30 escaneos); más no debería pasar y se pierden
Timing.MIN_W = 2.5                   -- escaneos (ya olvidados en parte) para fiarse del precio de una franja
Timing.REF_DAYS, Timing.REF_MIN, Timing.CLIP_BP = 7, 3, 5000
Timing.SALES_DAYS = 28
Timing.LAYER_SECONDS = 600
-- Regla C11 (la misma que public/hermandad.js timingAdvice).
Timing.SALES = {minN = 2.5, minDays = 2, minSec = 3600, minBlocks = 3, minUnits = 10, faster = 1.2}
Timing.PRICE = {minBlocks = 3, spreadBp = 300}
Timing.REASONS = {ventas = "más ventas", precio = "mejor precio", ["precio-alto"] = "precio más alto"}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local isInt = Spec.IsInt
local BLOCKS = 6
local TIME_MAX = Spec.TIME_MAX

Timing.lastError = nil

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------
local function protect(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then Timing.lastError = label .. ": " .. tostring(err) end
  return ok, err
end

local function after(seconds, fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then C_Timer.After(seconds, fn) end
end

local function now() return History.Now() end

local function inCombat()
  if type(InCombatLockdown) ~= "function" then return false end
  local ok, value = pcall(InCombatLockdown)
  return ok and value == true
end

local function historyBusy()
  return type(History.Pending) == "function" and History.Pending() > 0
end

local function relayIdle()
  local relay = ns.Relay
  if type(relay) ~= "table" or type(relay.Idle) ~= "function" then return true end
  local ok, idle = pcall(relay.Idle)
  return not ok or idle == true
end

-- ¿Tiene Relay ya decodificados los días de los compañeros de este mercado? (Las referencias de precio salen de ahí.)
local function relayDecoded(key)
  local relay = ns.Relay
  if type(relay) ~= "table" or type(relay.GuildItemsReady) ~= "function" then return true end
  local ok, ready = pcall(relay.GuildItemsReady, key)
  return not ok or ready == true
end

local function decay(seconds) return 2 ^ (-seconds / Timing.HALF_LIFE) end

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

-- Cifra corta para guardar: entera si lo es; si no, 3 decimales (1 a partir de 100), sin ceros de más.
local function num(x)
  if x == floor(x) and abs(x) < 1e15 then return string.format("%d", x) end
  local s = string.format(abs(x) >= 100 and "%.1f" or "%.3f", x)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  if s == "-0" then s = "0" end
  return s
end

-- Letras (no bytes) de un texto UTF-8, para alinear columnas con «—», «−» y «×».
local function width(s) return #(s:gsub("[\128-\191]", "")) end
local function padLeft(s, n) return string.rep(" ", max(0, n - width(s))) .. s end
local function padRight(s, n) return s .. string.rep(" ", max(0, n - width(s))) end

local function blockLabel(b) return (4 * b) .. "-" .. (4 * b + 4) .. " h" end
local function columnLabel(b) return string.format("%02d-%02d", 4 * b, 4 * b + 4) end

-- +4 %, 0 %, −2 % (signo menos de verdad) de un índice en puntos básicos.
local function pct(bp)
  local p = floor(bp / 100 + 0.5)
  if p > 0 then return "+" .. p .. " %" end
  if p < 0 then return "−" .. (-p) .. " %" end
  return "0 %"
end
Timing.Pct = pct

local function comma(x, decimals) return (string.format("%." .. decimals .. "f", x):gsub("%.", ",")) end
local function rateText(x) return "×" .. comma(floor(x * 10 + 0.5) / 10, 1) end
local function hoursText(seconds)
  local half = floor(max(0, seconds) / 1800 + 0.5) / 2
  if half == floor(half) then return string.format("%d h", half) end
  return comma(half, 1) .. " h"
end

---------------------------------------------------------------------------
-- Regla C11 (pura): blocks[1..6] = {priceOK, p, n, days, sec, u, mu, msec} de las franjas 0..5
---------------------------------------------------------------------------
-- Devuelve {salesOK = {6}, rateIdx = {6, nil donde no hay}, best = franja 0..5 o nil, reason = "ventas" | "precio" |
-- "precio-alto" | "pocos", hint = {h1, h2} o nil}. Las mismas cuentas, en el mismo orden, que advice.py y el panel.
function Timing.Advice(blocks)
  local S = Timing.SALES
  local salesOK, tu, ts = {}, {}, {}
  local ok = {}
  for i = 1, BLOCKS do
    local b = blocks[i] or {}
    local u, sec = max(0, (b.u or 0) - (b.mu or 0)), (b.sec or 0) - (b.msec or 0)
    salesOK[i] = (b.n or 0) >= S.minN and (b.days or 0) >= S.minDays and sec >= S.minSec
    tu[i], ts[i] = u, sec
    if salesOK[i] then ok[#ok + 1] = i end
  end
  local su, ss = 0, 0
  for _, i in ipairs(ok) do su = su + tu[i] end
  for _, i in ipairs(ok) do ss = ss + ts[i] end
  local rateIdx = {}
  local best, reason = nil, "pocos"
  if #ok >= S.minBlocks and su >= S.minUnits then
    local overall = su / ss
    for _, i in ipairs(ok) do rateIdx[i] = (tu[i] / ts[i]) / overall end
    local function score(i)
      local b = blocks[i]
      return (10000 + ((b.priceOK and b.p) and b.p or 0)) * rateIdx[i]
    end
    local top = ok[1]
    for k = 2, #ok do if score(ok[k]) > score(top) then top = ok[k] end end
    best = top - 1
    reason = rateIdx[top] >= S.faster and "ventas" or "precio"
  else
    local priced = {}
    for i = 1, BLOCKS do
      local b = blocks[i]
      if b and b.priceOK and type(b.p) == "number" then priced[#priced + 1] = i end
    end
    if #priced >= Timing.PRICE.minBlocks then
      local lo, hi, top = math.huge, -math.huge, priced[1]
      for _, i in ipairs(priced) do
        local p = blocks[i].p
        lo, hi = min(lo, p), max(hi, p)
        if p > blocks[top].p then top = i end
      end
      if hi - lo >= Timing.PRICE.spreadBp then best, reason = top - 1, "precio-alto" end
    end
  end
  local hint = best and {(4 * best + 23) % 24, 4 * best} or nil
  return {salesOK = salesOK, rateIdx = rateIdx, best = best, reason = reason, hint = hint}
end

---------------------------------------------------------------------------
-- Sumas por objeto: tRef y 6 franjas {w, sbp, n, sec, u, mu, msec, mt, d1, d2}
---------------------------------------------------------------------------
-- w y sbp: escaneos con precio de referencia y la suma de cuánto se apartan (puntos básicos); n, sec y u: ventas
-- medidas, sus segundos y sus unidades; mu, msec y mt: la mayor venta de la franja (unidades, segundos, hora); d1 > d2:
-- las dos fechas de España más nuevas con una venta (la del panel: cada día de la semana es otra fecha). Todo lo que se suma está olvidado hasta tRef: antes de sumar algo de una hora
-- t posterior se multiplica por 2^(-(t - tRef)/media vida) y tRef pasa a t; algo anterior a tRef entra ya olvidado.
local function newBlock() return {w = 0, sbp = 0, n = 0, sec = 0, u = 0} end
local function newItem()
  local item = {b = {}}
  for i = 1, BLOCKS do item.b[i] = newBlock() end
  return item
end

local function weightAt(item, t)
  if not item.tRef then item.tRef = t; return 1 end
  if t >= item.tRef then
    local f = decay(t - item.tRef)
    if f < 1 then
      for i = 1, BLOCKS do
        local b = item.b[i]
        b.w, b.sbp, b.n, b.sec, b.u = b.w * f, b.sbp * f, b.n * f, b.sec * f, b.u * f
      end
    end
    item.tRef = t
    return 1
  end
  return decay(item.tRef - t)
end

local function addPrice(item, block, t, ratio)
  local wgt = weightAt(item, t)
  local b = item.b[block + 1]
  b.w, b.sbp = b.w + wgt, b.sbp + ratio * wgt
end

local function addDay(b, d)
  if not d or d == b.d1 or d == b.d2 then return end
  if not b.d1 or d > b.d1 then b.d1, b.d2 = d, b.d1
  elseif not b.d2 or d > b.d2 then b.d2 = d end
end

-- Una venta medida: mid = mitad del intervalo (decide la franja y la fecha de España, day), dt segundos, sold unidades.
-- La mayor de la franja es la que más pesa ahora (unidades por lo que queda de ella tras olvidar); a igualdad, la de
-- más segundos.
local function addSale(item, block, mid, dt, sold, day)
  local wgt = weightAt(item, mid)
  local b = item.b[block + 1]
  b.n, b.sec, b.u = b.n + wgt, b.sec + dt * wgt, b.u + sold * wgt
  local current = b.mu and b.mu * decay(item.tRef - b.mt) or -1
  local new = sold * wgt
  if new > current or (new == current and dt > (b.msec or 0)) then b.mu, b.msec, b.mt = sold, dt, mid end
  if day == nil then day = select(5, Spec.MadridSlot(mid)) end
  addDay(b, day)
end

-- Junta dos objetos (las sumas de la primera pasada en las guardadas).
local function mergeItems(a, c)
  if not a then return c end
  if not c or not c.tRef then return a end
  if not a.tRef then return c end
  local T = max(a.tRef, c.tRef)
  local fa, fc = decay(T - a.tRef), decay(T - c.tRef)
  for i = 1, BLOCKS do
    local x, y = a.b[i], c.b[i]
    x.w, x.sbp = x.w * fa + y.w * fc, x.sbp * fa + y.sbp * fc
    x.n, x.sec, x.u = x.n * fa + y.n * fc, x.sec * fa + y.sec * fc, x.u * fa + y.u * fc
    if y.mu then
      local cx = x.mu and x.mu * decay(T - x.mt) or -1
      local cy = y.mu * decay(T - y.mt)
      if cy > cx or (cy == cx and y.msec > (x.msec or 0)) then x.mu, x.msec, x.mt = y.mu, y.msec, y.mt end
    end
    addDay(x, y.d1); addDay(x, y.d2)
  end
  a.tRef = T
  return a
end

-- Las 6 franjas de un objeto olvidadas hasta t, como las pide Timing.Advice (y w, para la cobertura).
local function blocksAt(item, t)
  local out = {}
  local f = decay(max(0, t - item.tRef))
  for i = 1, BLOCKS do
    local b = item.b[i]
    local w = b.w * f
    local mw = b.mu and decay(max(0, t - b.mt)) or 0
    out[i] = {w = w, priceOK = w >= Timing.MIN_W, p = w > 0 and (b.sbp * f) / w or nil, n = b.n * f,
              days = (b.d1 and 1 or 0) + (b.d2 and 1 or 0), sec = b.sec * f, u = b.u * f,
              mu = (b.mu or 0) * mw, msec = (b.msec or 0) * mw}
  end
  return out
end

---------------------------------------------------------------------------
-- Guardado: OroHermandadDB.timing[mercado] = {t, items = {[id] = texto}, seen = {[observador] = "t,t,..."}}
---------------------------------------------------------------------------
-- Texto de un objeto: "tRef|franja 0|...|franja 5"; franja vacía = "", solo precio = "w,sbp", con ventas =
-- "w,sbp,n,sec,u,mu,msec,tRef-mt,d1,d1-d2".
local db
local markets = {}     -- mercado -> {items = {[id] = item}, seen = {[obs] = {[t] = true}}, dirty}
local index = {}       -- mercado -> id -> números empaquetados de las ventas sumadas de las últimas 74 h
local obsIds = {}      -- mercado -> {n, byName = {}, names = {}} (observador -> número para empaquetar)

local function encodeBlock(b, tRef)
  local empty = b.w == 0 and b.n == 0
  if empty then return "" end
  local parts = {num(b.w), num(b.sbp)}
  if b.n > 0 and b.mu then
    parts[3], parts[4], parts[5] = num(b.n), num(b.sec), num(b.u)
    parts[6], parts[7], parts[8] = num(b.mu), num(b.msec), num(tRef - b.mt)
    parts[9], parts[10] = b.d1 and tostring(b.d1) or "", (b.d1 and b.d2) and tostring(b.d1 - b.d2) or ""
  end
  return table.concat(parts, ",")
end

local function encodeItem(item)
  local parts = {num(item.tRef)}
  for i = 1, BLOCKS do parts[i + 1] = encodeBlock(item.b[i], item.tRef) end
  return table.concat(parts, "|")
end

local function decodeItem(text)
  if type(text) ~= "string" then return nil end
  local fields = {}
  for f in (text .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = f end
  if #fields ~= BLOCKS + 1 then return nil end
  local tRef = tonumber(fields[1])
  if not isInt(tRef, 1, TIME_MAX) then return nil end
  local item = newItem()
  item.tRef = tRef
  for i = 1, BLOCKS do
    local f = fields[i + 1]
    if f ~= "" then
      local v = {}
      for x in (f .. ","):gmatch("([^,]*),") do v[#v + 1] = x end
      local b = item.b[i]
      b.w, b.sbp = tonumber(v[1]), tonumber(v[2])
      if not (b.w and b.sbp and b.w >= 0) then return nil end
      if #v >= 10 then
        b.n, b.sec, b.u = tonumber(v[3]), tonumber(v[4]), tonumber(v[5])
        b.mu, b.msec = tonumber(v[6]), tonumber(v[7])
        local dmt, d1, dd = tonumber(v[8]), tonumber(v[9]), tonumber(v[10])
        if not (b.n and b.sec and b.u and b.mu and b.msec and dmt and b.n >= 0) then return nil end
        b.mt = tRef - dmt
        b.d1 = isInt(d1, 0, Spec.DAY_MAX) and d1 or nil
        b.d2 = (b.d1 and isInt(dd, 1, Spec.DAY_MAX)) and b.d1 - dd or nil
      elseif #v ~= 2 then
        return nil
      end
    end
  end
  return item
end

local function decodeSet(text)
  local set = {}
  if type(text) ~= "string" then return set end
  for x in text:gmatch("[^,]+") do
    local t = tonumber(x)
    if isInt(t, 1, TIME_MAX) then set[t] = true end
  end
  return set
end

local function isObserver(k) return k == "self" or History.IsHash(k) end

-- El mercado decodificado (lo crea si no hay nada guardado).
local function marketData(key)
  local m = markets[key]
  if m then return m end
  m = {items = {}, seen = {}, dirty = false}
  local saved = db and db.timing and db.timing[key]
  if type(saved) == "table" then
    for id, text in pairs(type(saved.items) == "table" and saved.items or {}) do
      local item = isInt(id, 1, 2147483647) and decodeItem(text) or nil
      if item then m.items[id] = item end
    end
    for obs, text in pairs(type(saved.seen) == "table" and saved.seen or {}) do
      if isObserver(obs) then m.seen[obs] = decodeSet(text) end
    end
  end
  markets[key] = m
  return m
end

local function isSeen(m, obs, t) return m.seen[obs] ~= nil and m.seen[obs][t] == true end
local function markSeen(m, obs, t)
  m.seen[obs] = m.seen[obs] or {}
  m.seen[obs][t] = true
  m.dirty = true
end

-- Escribe un mercado en db.timing: horas de escaneos de 14 días (lo tuyo) y 4 (compañeros), objetos que ya casi no
-- pesan fuera y 64 KB como mucho (fuera primero los que llevan más tiempo sin nada nuevo).
local function encodeMarket(key, t)
  local m = markets[key]
  if not m then return end
  local items, list, total = {}, {}, 0
  for id, item in pairs(m.items) do
    if item.tRef then
      local alive = false
      local f = decay(max(0, t - item.tRef))
      for i = 1, BLOCKS do if (item.b[i].w + item.b[i].n) * f >= 0.01 then alive = true end end
      if alive then
        local text = encodeItem(item)
        items[id] = text
        list[#list + 1] = {id = id, tRef = item.tRef, size = #text + 12}
        total = total + #text + 12
      else
        m.items[id] = nil
      end
    end
  end
  local seen = {}
  for obs, set in pairs(m.seen) do
    local keep = obs == "self" and Timing.OWN_SECONDS or Timing.MATE_SECONDS
    local times = {}
    for x in pairs(set) do
      if x > t - keep then times[#times + 1] = x else set[x] = nil end
    end
    if #times > 0 then
      table.sort(times)
      while #times > 200 do table.remove(times, 1) end
      local text = table.concat(times, ",")
      seen[obs] = text
      total = total + #text + 12
    else
      m.seen[obs] = nil
    end
  end
  if total > Timing.MAX_BYTES then
    table.sort(list, function(a, b)
      if a.tRef ~= b.tRef then return a.tRef < b.tRef end
      return a.id < b.id
    end)
    for _, e in ipairs(list) do
      if total <= Timing.MAX_BYTES then break end
      items[e.id], m.items[e.id] = nil, nil
      total = total - e.size
    end
  end
  local previous = db.timing[key]
  db.timing[key] = {t = type(previous) == "table" and isInt(previous.t, 1, TIME_MAX) and previous.t or t, items = items,
                    seen = seen}
  m.dirty = false
end

-- Como mucho 4 mercados: fuera el que lleva más tiempo sin visitarse.
local function capMarkets(keep)
  local keys = {}
  for k in pairs(db.timing) do keys[#keys + 1] = k end
  if #keys <= Timing.MARKETS then return end
  table.sort(keys, function(a, b)
    local ta, tb = db.timing[a].t or 0, db.timing[b].t or 0
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  local extra = #keys - Timing.MARKETS
  for _, k in ipairs(keys) do
    if extra <= 0 then break end
    if k ~= keep then db.timing[k], markets[k], index[k] = nil, nil, nil; extra = extra - 1 end
  end
end

local function touch(key)
  local t = now()
  if not (db and key and t) then return end
  local saved = db.timing[key]
  if type(saved) ~= "table" then
    marketData(key).dirty = true
    db.timing[key] = {t = t, items = {}, seen = {}}
  else
    saved.t = t
  end
  capMarkets(key)
end

---------------------------------------------------------------------------
-- Precio de referencia: mediana de los días d-7 .. d-1 (3 como mínimo) del valor del día del objeto (lo tuyo y lo de
-- los compañeros juntos, Spec.BuildDays). Se guarda en memoria por mercado, objeto y día.
---------------------------------------------------------------------------
local refCache = {}    -- mercado -> id -> {T = día en que se calculó, values = {[d] = valor del día}}

-- Días de los compañeros de un objeto: los que Relay ya tiene decodificados (Relay.GuildItems, por tandas y en caché);
-- sin Relay, se decodifican aquí.
local function mateRecords(key, id)
  local relay = ns.Relay
  if type(relay) == "table" and type(relay.GuildItems) == "function" then
    local ok, items = pcall(relay.GuildItems, key)
    local g = ok and type(items) == "table" and items[id] or nil
    return g and g.list or {}
  end
  local out = {}
  local market = History.Market(key)
  for h, entry in pairs(market and type(market.obs) == "table" and market.obs or {}) do
    local it = entry.items and entry.items[id]
    if it then out[#out + 1] = {id = h, records = History.RecentRecords(it.d)} end
  end
  return out
end

-- Lo de un objeto para sus referencias, una vez por objeto y día T: tus registros de días, los de los compañeros y el
-- valor de cada día ya calculado (Spec.DayValue de un registro por observador: lo mismo que Spec.BuildDays con
-- registros ya normalizados). Cada valor se calcula al pedirlo (unas décimas de ms con 40 compañeros).
local function itemDays(key, id, T)
  refCache[key] = refCache[key] or {}
  local c = refCache[key][id]
  if c and c.T == T then return c end
  local market = History.Market(key)
  local own = market and market.items and market.items[id]
  c = {T = T, own = own and History.RecentRecords(own.d, 30) or {}, mates = mateRecords(key, id), values = {}}
  refCache[key][id] = c
  return c
end

-- El registro del día d de una lista de días en orden (se busca desde el final: lo que se pide es reciente).
local function recordOf(records, d)
  for k = #records, 1, -1 do
    local r = records[k]
    if r.d == d then return r end
    if r.d < d then return nil end
  end
  return nil
end

local function dayValueOf(c, d)
  local v = c.values[d]
  if v ~= nil then return v or nil end
  local observers = {}
  local r = recordOf(c.own, d)
  if r then observers[1] = {lo = r.lo, hi = r.hi, qty = r.qty, id = "self"} end
  for _, e in ipairs(c.mates) do
    local m = recordOf(e.records or {}, d)
    if m then observers[#observers + 1] = {lo = m.lo, hi = m.hi, qty = m.qty, id = e.id} end
  end
  local value = #observers > 0 and Spec.DayValue(observers) or nil
  c.values[d] = value and value.v or false
  return value and value.v or nil
end

-- ¿Aún no se ha preparado este objeto hoy? (Decodificar tus días es lo más caro de un punto: se deja para el
-- principio de una tanda.)
local function needsValues(key, id)
  local T = Spec.DayIndex(now() or 0)
  local cached = refCache[key] and refCache[key][id]
  return not (cached and cached.T == T)
end

-- Referencia del día d: mediana de los valores de d-7 .. d-1 (3 días como mínimo) o nil.
local function refFor(key, id, d)
  local T = Spec.DayIndex(now() or 0)
  if not d or not T or d > T then return nil end
  local c = itemDays(key, id, T)
  local list = {}
  for x = d - Timing.REF_DAYS, d - 1 do
    local v = dayValueOf(c, x)
    if v then list[#list + 1] = v end
  end
  if #list < Timing.REF_MIN then return nil end
  return Spec.Median(list)
end

local function ratioOf(lo, ref)
  return max(-Timing.CLIP_BP, min(Timing.CLIP_BP, floor(lo * 10000 / ref) - 10000))
end

---------------------------------------------------------------------------
-- Índice de ventas sumadas (solo en memoria): por mercado y objeto, cubos por hora de t con números empaquetados
-- ((t - DAY0) * 8192 + dt) * 128 + número del observador. Dos ventas solo se pueden solapar si sus t están a menos de
-- 2 h (dt ≤ 7200 s): basta mirar los cubos de 2 horas antes y después (como el panel).
---------------------------------------------------------------------------
local PACK_DT, PACK_OBS = 8192, 128
local REACH = math.ceil((Spec.SAMPLE_DT_MAX or 7200) / 3600)

local function obsNumber(key, obs)
  local o = obsIds[key]
  if not o then o = {n = 0, byName = {}, names = {}}; obsIds[key] = o end
  local n = o.byName[obs]
  if n then return n end
  if o.n >= PACK_OBS - 1 then return nil end
  o.n = o.n + 1
  o.byName[obs], o.names[o.n] = o.n, obs
  return o.n
end

local function pack(t, dt, n) return ((t - Spec.DAY0) * PACK_DT + dt) * PACK_OBS + n end
local function unpack(x)
  local n = x % PACK_OBS
  x = (x - n) / PACK_OBS
  local dt = x % PACK_DT
  return (x - dt) / PACK_DT + Spec.DAY0, dt, n
end

-- ¿Se solapa (t - dt, t] más de la mitad del más corto con una venta sumada de otro observador?
local function overlaps(buckets, t, dt, n)
  if not buckets then return false end
  local h = floor(t / 3600)
  for x = h - REACH, h + REACH do
    local list = buckets[x]
    if list then
      for k = 1, #list do
        local t2, dt2, n2 = unpack(list[k])
        if n2 ~= n and (min(t, t2) - max(t - dt, t2 - dt2)) * 2 > min(dt, dt2) then return true end
      end
    end
  end
  return false
end

local function bucketAdd(buckets, t, dt, n)
  local h = floor(t / 3600)
  local list = buckets[h]
  if not list then list = {}; buckets[h] = list end
  list[#list + 1] = pack(t, dt, n)
end

local indexAdds = 0
local function indexAdd(key, id, t, dt, n, at)
  index[key] = index[key] or {}
  local buckets = index[key][id]
  if not buckets then buckets = {}; index[key][id] = buckets end
  bucketAdd(buckets, t, dt, n)
  -- Lo de más de 74 h ya no se puede solapar con nada nuevo: se quita de vez en cuando.
  indexAdds = indexAdds + 1
  if indexAdds % 256 == 0 and at then
    local oldest = floor((at - Timing.INDEX_SECONDS) / 3600)
    for _, byItem in pairs(index) do
      for _, b in pairs(byItem) do
        for h in pairs(b) do if h < oldest then b[h] = nil end end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Sumar un punto
---------------------------------------------------------------------------
local stats = {overlaps = 0, absorbed = 0, skippedSeen = 0, dropped = 0, passes = 0, restarts = 0}

-- target: objeto donde se suma; check: lista del índice (o nil). Devuelve si la venta se sumó.
local function absorbPoint(key, target, id, t, lo, dt, sold, n, list)
  local ref = refFor(key, id, Spec.DayIndex(t))
  if ref and isInt(lo, 1, Spec.PRICE_MAX) then
    local _, _, block = Spec.MadridSlot(t)
    if block then addPrice(target, block, t, ratioOf(lo, ref)) end
  end
  if not (dt and sold and Spec.ValidSample(dt, sold)) then return false end
  if overlaps(list, t, dt, n) then stats.overlaps = stats.overlaps + 1; return false end
  local mid = t - floor(dt / 2)
  local _, _, block, _, day = Spec.MadridSlot(mid)
  if not block then return false end
  addSale(target, block, mid, dt, sold, day)
  return true
end

---------------------------------------------------------------------------
-- Primera pasada (al entrar): todo lo guardado que aún no se ha sumado, de una vez al final
---------------------------------------------------------------------------
local passDone = {}    -- mercado -> true: ya se sumó en esta sesión
local pass = nil       -- {key, ids, i, acc, times, index, t, restart}
local passStep, livePump

local function passIDs(key)
  local market = History.Market(key)
  local set, ids = {}, {}
  for id in pairs(market and market.items or {}) do set[id] = true end
  for _, entry in pairs(market and type(market.obs) == "table" and market.obs or {}) do
    for id in pairs(entry.items or {}) do set[id] = true end
  end
  for id in pairs(set) do if type(id) == "number" then ids[#ids + 1] = id end end
  table.sort(ids)
  return ids
end

-- Un objeto de la pasada se lee observador a observador (cada uno es una unidad de las tandas: con 40 compañeros
-- ninguna tanda se alarga): beginItem prepara la lista, readSource lee los puntos de uno (precios al momento; ventas a
-- una lista) y finishItem suma las ventas en el orden del panel, saltando las que se solapan.
local function beginItem(p, id)
  local market = History.Market(p.key)
  local cur = {id = id, sources = {}, k = 1, samples = {}, kept = {}, s = 0, acc = nil,
               day = p.T - Timing.OWN_SECONDS / 86400 - Timing.REF_DAYS}
  if not market then return cur end
  local own = market.items and market.items[id]
  if own and type(own.p) == "string" and own.p ~= "" then
    cur.sources[#cur.sources + 1] = {obs = "self", text = own.p, oldest = p.t - Timing.OWN_SECONDS}
  end
  local hashes = {}
  for h, entry in pairs(type(market.obs) == "table" and market.obs or {}) do
    local it = entry.items and entry.items[id]
    if it and type(it.p) == "string" and it.p ~= "" then hashes[#hashes + 1] = h end
  end
  table.sort(hashes)
  for _, h in ipairs(hashes) do
    cur.sources[#cur.sources + 1] = {obs = h, text = market.obs[h].items[id].p, oldest = p.t - Timing.MATE_POINTS}
  end
  return cur
end

local function readSource(p, cur, src)
  local m = marketData(p.key)
  local n = obsNumber(p.key, src.obs)
  for _, pt in ipairs(Spec.DecodePoints(src.text)) do
    if pt.t > src.oldest then
      if isSeen(m, src.obs, pt.t) then
        if pt.dt and n and pt.t > p.t - Timing.INDEX_SECONDS then bucketAdd(cur.kept, pt.t, pt.dt, n) end
      else
        p.times[src.obs] = p.times[src.obs] or {}
        p.times[src.obs][pt.t] = true
        cur.acc = cur.acc or newItem()
        absorbPoint(p.key, cur.acc, cur.id, pt.t, pt.lo, nil, nil, n, nil) -- el precio; las ventas, al final y en orden
        if pt.dt and n then
          cur.samples[#cur.samples + 1] = {t = pt.t, dt = pt.dt, sold = pt.sold, obs = src.obs, n = n}
        end
      end
    end
  end
end

-- Ventas de un objeto, en el orden del panel: primero la de más segundos (a igualdad, más unidades, la más vieja, el
-- observador menor). Se ordenan en una unidad y se suman de 64 en 64.
local function sortSamples(cur)
  table.sort(cur.samples, function(a, b)
    if a.dt ~= b.dt then return a.dt > b.dt end
    if a.sold ~= b.sold then return a.sold > b.sold end
    if a.t ~= b.t then return a.t < b.t end
    return a.obs < b.obs
  end)
  cur.sorted = true
end

local function applySamples(p, cur)
  local last = min(#cur.samples, cur.s + 64)
  for k = cur.s + 1, last do
    local s = cur.samples[k]
    if overlaps(cur.kept, s.t, s.dt, s.n) then
      p.overlaps = p.overlaps + 1
    else
      local mid = s.t - floor(s.dt / 2)
      local _, _, block, _, day = Spec.MadridSlot(mid)
      if block then addSale(cur.acc, block, mid, s.dt, s.sold, day) end
      if s.t > p.t - Timing.INDEX_SECONDS then bucketAdd(cur.kept, s.t, s.dt, s.n) end
    end
  end
  cur.s = last
end

local function finishItem(p, cur)
  if cur.acc and cur.acc.tRef then p.acc[cur.id] = cur.acc end
  if next(cur.kept) then p.index[cur.id] = cur.kept end
end

local function commitPass(p)
  local m = marketData(p.key)
  for id, acc in pairs(p.acc) do m.items[id] = mergeItems(m.items[id], acc) end
  for obs, times in pairs(p.times) do
    for t in pairs(times) do markSeen(m, obs, t) end
  end
  index[p.key] = p.index
  m.dirty = true
  passDone[p.key] = true
  stats.overlaps = stats.overlaps + p.overlaps
  stats.passes = stats.passes + 1
  stats.passAt = p.t
end

local tryPass

passStep = function(token)
  local p = pass
  if not p or p.token ~= token then return end
  if p.restart then
    -- Llegó algo nuevo mientras se leía: se empieza otra vez más tarde (lo leído a medias no se suma).
    pass = nil
    stats.restarts = stats.restarts + 1
    after(Timing.RETRY, function() protect("primera pasada", tryPass) end)
    return
  end
  if historyBusy() or inCombat() then after(Timing.WAIT, function() protect("primera pasada", passStep, token) end); return end
  local profile = type(debugprofilestop) == "function" and debugprofilestop or nil
  local start = profile and profile()
  local done = 0
  while p.i <= #p.ids do
    local cur = p.cur
    local unitStart = profile and profile()
    if not cur then
      cur = beginItem(p, p.ids[p.i])
      p.cur = cur
    elseif cur.day < p.T then
      -- Los valores de los días que piden sus puntos (14 días y los 7 anteriores), uno por unidad.
      if not cur.days then cur.days = itemDays(p.key, cur.id, p.T) end
      dayValueOf(cur.days, cur.day)
      cur.day = cur.day + 1
    elseif cur.k <= #cur.sources then
      readSource(p, cur, cur.sources[cur.k])
      cur.k = cur.k + 1
    elseif not cur.sorted then
      -- Ordenar muchas ventas (40 compañeros: casi 1000) cuesta casi 1 ms: va al principio de una tanda.
      if profile and done > 0 and #cur.samples > 128 then break end
      sortSamples(cur)
    elseif cur.s < #cur.samples then
      applySamples(p, cur)
    else
      finishItem(p, cur)
      p.cur, p.i = nil, p.i + 1
    end
    done = done + 1
    if profile then
      -- Sin pasarse: si otra unidad como esta no cabe en lo que queda de 1,5 ms, se sigue en el próximo fotograma.
      local spent = profile()
      if (spent - start) + (spent - unitStart) > Timing.BUDGET_MS then break end
    elseif done >= Timing.PASS_UNITS then
      break
    end
  end
  if p.i > #p.ids then
    pass = nil
    commitPass(p)
    livePump()
    return
  end
  after(0, function() protect("primera pasada", passStep, token) end)
end

local passSeq, noKeyTries = 0, 0
tryPass = function()
  if pass or not db then return end
  if not History.Hist() then return end
  local key = History.CurrentMarket()
  if not key then
    -- Aún no se sabe el reino o la facción: se mira otra vez más tarde (5 min como mucho).
    noKeyTries = noKeyTries + 1
    if noKeyTries <= 30 then after(Timing.RETRY, function() protect("primera pasada", tryPass) end) end
    return
  end
  if passDone[key] then return end
  if historyBusy() or not relayIdle() or not relayDecoded(key) or inCombat() then
    after(Timing.RETRY, function() protect("primera pasada", tryPass) end)
    return
  end
  marketData(key)
  touch(key)
  passSeq = passSeq + 1
  local t = now() or 0
  pass = {key = key, ids = passIDs(key), i = 1, acc = {}, times = {}, index = {}, t = t, T = Spec.DayIndex(t) or 0,
          overlaps = 0, token = passSeq}
  refCache[key] = nil
  local token = passSeq
  after(0, function() protect("primera pasada", passStep, token) end)
end

---------------------------------------------------------------------------
-- En directo: cada punto que escriben History (lo tuyo) y Relay (lo de compañeros)
---------------------------------------------------------------------------
local queue, head = {}, 1
local started = {}     -- escaneos con algún punto ya sumado y sin su «done»: mercado|observador|t -> true
local pumping = false

local function scanKey(key, obs, t) return key .. "|" .. obs .. "|" .. t end

local function onPoint(event, key, obs, ...)
  if not db or type(key) ~= "string" or not isObserver(obs) then return end
  if not passDone[key] then
    -- Antes de la primera pasada no se suma nada en directo: la pasada lo lee de lo guardado (si estaba leyendo,
    -- vuelve a empezar para no dejar medio escaneo).
    if pass and pass.key == key then pass.restart = true end
    stats.dropped = stats.dropped + 1
    return
  end
  -- Con la cola llena se pierden puntos, nunca el final de un escaneo: así nunca se suma dos veces.
  if event == "point" and #queue - head + 1 >= Timing.QUEUE_MAX then stats.dropped = stats.dropped + 1; return end
  if event == "point" then
    local id, t, lo, qty, dt, sold = ...
    queue[#queue + 1] = {key = key, obs = obs, id = id, t = t, lo = lo, dt = dt, sold = sold}
  elseif event == "done" then
    local t = ...
    queue[#queue + 1] = {key = key, obs = obs, t = t, done = true}
  end
  livePump()
end

-- Un elemento de la cola.
local function liveEntry(e)
  if not isInt(e.t, 1, TIME_MAX) then return end
  local m = marketData(e.key)
  if e.done then
    started[scanKey(e.key, e.obs, e.t)] = nil
    markSeen(m, e.obs, e.t)
    return
  end
  if isSeen(m, e.obs, e.t) then stats.skippedSeen = stats.skippedSeen + 1; return end
  if not isInt(e.id, 1, 2147483647) then return end
  started[scanKey(e.key, e.obs, e.t)] = true
  local item = m.items[e.id]
  if not item then item = newItem(); m.items[e.id] = item end
  local n = obsNumber(e.key, e.obs)
  local list = index[e.key] and index[e.key][e.id]
  if absorbPoint(e.key, item, e.id, e.t, e.lo, e.dt, e.sold, n, list) and n then
    indexAdd(e.key, e.id, e.t, e.dt, n, now())
  end
  if not item.tRef then m.items[e.id] = nil end
  m.dirty = true
  stats.absorbed = stats.absorbed + 1
end

local function compact()
  if head > 512 and head > #queue / 2 then
    local rest = {}
    for i = head, #queue do rest[#rest + 1] = queue[i] end
    queue, head = rest, 1
  end
end

local function liveStep()
  pumping = false
  if head > #queue then queue, head = {}, 1; return end
  if historyBusy() or inCombat() then
    pumping = true
    after(Timing.WAIT, function() protect("en directo", liveStep) end)
    return
  end
  local profile = type(debugprofilestop) == "function" and debugprofilestop or nil
  local start = profile and profile()
  local done = 0
  while head <= #queue do
    local e = queue[head]
    if profile and done > 0 and not e.done and e.id and needsValues(e.key, e.id)
       and profile() - start > Timing.BUDGET_MS / 3 then
      break
    end
    queue[head] = false
    head = head + 1
    local unitStart = profile and profile()
    protect("en directo", liveEntry, e)
    done = done + 1
    if profile then
      local spent = profile()
      if (spent - start) + (spent - unitStart) > Timing.BUDGET_MS then break end
    elseif done >= Timing.UNITS then
      break
    end
  end
  compact()
  if head <= #queue then
    pumping = true
    after(0, function() protect("en directo", liveStep) end)
  else
    queue, head = {}, 1
  end
end

livePump = function()
  if pumping or head > #queue then return end
  pumping = true
  after(0, function() protect("en directo", liveStep) end)
end

---------------------------------------------------------------------------
-- API del addon
---------------------------------------------------------------------------
local function sanitize(saved)
  local out = {}
  for key, entry in pairs(type(saved) == "table" and saved or {}) do
    if History.ValidMarketKey(key) and type(entry) == "table" and type(entry.items) == "table"
       and (entry.seen == nil or type(entry.seen) == "table") then
      out[key] = {t = isInt(entry.t, 1, TIME_MAX) and entry.t or nil, items = entry.items, seen = entry.seen or {}}
    end
  end
  return out
end

-- En ADDON_LOADED, después de History.Load y Relay.Init: los datos guardados y el aviso de cada punto escrito.
function Timing.Init(accountDB)
  db = type(accountDB) == "table" and accountDB or {}
  db.timing = sanitize(db.timing)
  History.OnPoint(function(...) protect("aviso", onPoint, ...) end)
end

-- En PLAYER_LOGIN: la primera pasada, 30 s después (y cada 10 s hasta que el historial y la hermandad estén quietos).
function Timing.Login()
  after(Timing.FIRST_DELAY, function() protect("primera pasada", tryPass) end)
end

-- PLAYER_LOGOUT: termina en el acto los escaneos que ya se estaban sumando (como mucho uno o dos de 201 objetos) para
-- no dejar medio escaneo; los que aún no habían empezado se quedan para la primera pasada de la próxima vez. Después
-- escribe lo que cambió.
function Timing.BeforeSave()
  if not db then return end
  protect("al salir", function()
    if next(started) then
      for i = head, #queue do
        local e = queue[i]
        if e and started[scanKey(e.key, e.obs, e.t)] then protect("al salir", liveEntry, e) end
      end
      -- Uno que no llegó a su «done»: se da por sumado (mejor perder lo que faltaba que contarlo dos veces).
      for k in pairs(started) do
        local key, obs, t = k:match("^(.+)|([^|]+)|(%d+)$")
        if key and markets[key] then markSeen(markets[key], obs, tonumber(t)) end
      end
      started = {}
    end
    queue, head = {}, 1
    local t = now()
    if not t then return end
    for key, m in pairs(markets) do
      if m.dirty then encodeMarket(key, t) end
    end
    capMarkets(History.CurrentMarket())
  end)
end

-- Cobertura de una franja (0..5) en un mercado: media de w (escaneos con precio, ya olvidados) de los objetos de la
-- lista fija que tienen datos; 0 si ninguno. La usa la propuesta de escanear (Scanner.Proposal).
function Timing.Coverage(key, block)
  if not db or not key or not isInt(block, 0, BLOCKS - 1) then return 0 end
  local m = marketData(key)
  local t = now() or 0
  local sum, n = 0, 0
  for id, item in pairs(m.items) do
    if History.IsFixed(id) and item.tRef then
      sum = sum + item.b[block + 1].w * decay(max(0, t - item.tRef))
      n = n + 1
    end
  end
  return n > 0 and sum / n or 0
end

-- Franjas de un objeto del mercado actual olvidadas hasta ahora (nil si no hay datos).
function Timing.ItemBlocks(id, key, t)
  key = key or History.CurrentMarket()
  if not db or not key then return nil end
  local item = marketData(key).items[id]
  if not item or not item.tRef then return nil end
  return blocksAt(item, t or now() or item.tRef)
end

-- Perfil de todos los objetos vigilados (la cabecera de la vista): por franja, precio medio ponderado por w (vale con
-- Σw ≥ 2,5), ventas = media de rateIdx de los objetos con patrón de ventas que valen en esa franja, ponderada por sus
-- segundos medidos (vale con 2 objetos), «Medido» y «Escaneos» del objeto que más tiene; mejor franja con la regla C11.
function Timing.Profile(key, t)
  key = key or History.CurrentMarket()
  t = t or now() or 0
  local sumW, sumSbp, sumR, sumRW, count, maxSec, maxW = {}, {}, {}, {}, {}, {}, {}
  for i = 1, BLOCKS do sumW[i], sumSbp[i], sumR[i], sumRW[i], count[i], maxSec[i], maxW[i] = 0, 0, 0, 0, 0, 0, 0 end
  local items = 0
  if db and key then
    local watched = {}
    for _, w in ipairs(History.WatchList()) do watched[w.id] = true end
    for id, item in pairs(marketData(key).items) do
      if watched[id] and item.tRef then
        items = items + 1
        local blocks = blocksAt(item, t)
        local advice = Timing.Advice(blocks)
        local pattern = advice.reason == "ventas" or advice.reason == "precio"
        for i = 1, BLOCKS do
          local b = blocks[i]
          sumW[i] = sumW[i] + b.w
          if b.w > 0 then sumSbp[i] = sumSbp[i] + b.p * b.w end
          maxSec[i], maxW[i] = max(maxSec[i], b.sec), max(maxW[i], b.w)
          if pattern and advice.salesOK[i] and advice.rateIdx[i] then
            local weight = b.sec - b.msec
            sumR[i], sumRW[i], count[i] = sumR[i] + advice.rateIdx[i] * weight, sumRW[i] + weight, count[i] + 1
          end
        end
      end
    end
  end
  local blocks = {}
  for i = 1, BLOCKS do
    local priceOK = sumW[i] >= Timing.MIN_W
    blocks[i] = {priceOK = priceOK, p = sumW[i] > 0 and sumSbp[i] / sumW[i] or nil, items = count[i],
                 rateIdx = (count[i] >= 2 and sumRW[i] > 0) and sumR[i] / sumRW[i] or nil, sec = maxSec[i], w = maxW[i]}
  end
  -- La regla C11 con esos valores: franjas con ventas = las de 2 objetos o más; patrón con 3 franjas.
  local ok = {}
  for i = 1, BLOCKS do if blocks[i].rateIdx then ok[#ok + 1] = i end end
  local best, reason = nil, "pocos"
  if #ok >= Timing.SALES.minBlocks then
    local function score(i) return (10000 + (blocks[i].priceOK and blocks[i].p or 0)) * blocks[i].rateIdx end
    local top = ok[1]
    for k = 2, #ok do if score(ok[k]) > score(top) then top = ok[k] end end
    best, reason = top - 1, blocks[top].rateIdx >= Timing.SALES.faster and "ventas" or "precio"
  else
    local priced = {}
    for i = 1, BLOCKS do if blocks[i].priceOK then priced[#priced + 1] = i end end
    if #priced >= Timing.PRICE.minBlocks then
      local lo, hi, top = math.huge, -math.huge, priced[1]
      for _, i in ipairs(priced) do
        lo, hi = min(lo, blocks[i].p), max(hi, blocks[i].p)
        if blocks[i].p > blocks[top].p then top = i end
      end
      if hi - lo >= Timing.PRICE.spreadBp then best, reason = top - 1, "precio-alto" end
    end
  end
  return {blocks = blocks, best = best, reason = reason, hint = best and {(4 * best + 23) % 24, 4 * best} or nil,
          items = items}
end

---------------------------------------------------------------------------
-- La vista (/oro cuando, botón «Cuándo vender») y la línea de la descripción de los objetos
---------------------------------------------------------------------------
local function itemName(id)
  local name = Items.Name(id)
  if type(name) == "string" and name ~= "" then return name end
  local key = History.CurrentMarket()
  local market = key and History.Market(key)
  local item = market and market.items and market.items[id]
  if item and type(item.n) == "string" and item.n ~= "" then return item.n end
  return Data.FALLBACK_NAMES[id] or ("Objeto " .. id)
end

local function bestLine(advice, blocks)
  if advice.best == nil then
    return "Mejor franja para vender: aún pocos datos (hacen falta 3 mediciones en 2 días distintos en cada franja)."
  end
  local b = blocks[advice.best + 1]
  local priceText = (b and b.priceOK and b.p) and ("; precio " .. pct(b.p)) or ""
  return "Mejor franja para vender: " .. blockLabel(advice.best) .. " (" .. Timing.REASONS[advice.reason] .. priceText
    .. "). Pon o iguala el precio hacia las " .. advice.hint[1] .. "-" .. advice.hint[2]
    .. " h, con 2 h (u 8 h si no vas a volver)."
end
Timing.BestLine = bestLine

-- Tus ventas de 28 días por franja (veces, no unidades): «20-24 h 9 · 16-20 h 4 · resto 2».
local function salesLine(key, id)
  local scanner = ns.Scanner
  if type(scanner) ~= "table" or type(scanner.Sales) ~= "function" then return nil end
  if type(scanner.Mode) == "function" and db.scanner and db.scanner.sales == false then
    return "Tus ventas: no se apuntan (se activa en las opciones)."
  end
  local ok, records = pcall(scanner.Sales, key)
  if not ok or type(records) ~= "table" then return nil end
  local counts, total = {}, 0
  for i = 0, BLOCKS - 1 do counts[i] = 0 end
  for _, r in ipairs(records) do
    if not id or r[2] == id then
      local _, _, block = Spec.MadridSlot(r[1])
      if block then counts[block] = counts[block] + 1; total = total + 1 end
    end
  end
  if total == 0 then return "Tus ventas (28 días): ninguna apuntada todavía." end
  local order = {}
  for i = 0, BLOCKS - 1 do if counts[i] > 0 then order[#order + 1] = i end end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a > b
  end)
  local parts, shown = {}, 0
  for k = 1, min(2, #order) do
    parts[#parts + 1] = blockLabel(order[k]) .. " " .. counts[order[k]]
    shown = shown + counts[order[k]]
  end
  if total > shown then parts[#parts + 1] = "resto " .. (total - shown) end
  return "Tus ventas (28 días): " .. table.concat(parts, " · ") .. " (veces que se vendió algo tuyo)."
end

local FOOTNOTE = {
  "(«—» = pocos datos: hacen falta 3 mediciones en 2 días distintos. «Ventas» es una estimación de lo que desaparece "
    .. "entre dos escaneos de la misma persona. El depósito de 8 h es 4 veces el de 2 h; el de 24 h, 12 veces.)",
}

-- Las 5 filas de la tabla. rows[i] = {price, rate, sec, w} por franja (textos ya hechos o números).
local function tableLines(rows)
  local lines = {}
  local function row(label, cells)
    local out = padRight(label, 11)
    for i = 1, BLOCKS do out = out .. padLeft(cells[i], 8) end
    lines[#lines + 1] = out
  end
  local franja, precio, ventas, medido, escaneos = {}, {}, {}, {}, {}
  for i = 1, BLOCKS do
    local r = rows[i]
    franja[i] = columnLabel(i - 1)
    precio[i] = (r.priceOK and r.p) and pct(r.p) or "—"
    ventas[i] = r.rateIdx and rateText(r.rateIdx) or "—"
    medido[i] = hoursText(r.sec or 0)
    escaneos[i] = tostring(floor((r.w or 0) + 0.5))
  end
  row("Franja", franja); row("Precio", precio); row("Ventas", ventas); row("Medido", medido); row("Escaneos", escaneos)
  return lines
end

local function itemAdviceText(advice)
  if advice.best == nil then return nil end
  local text = blockLabel(advice.best) .. ", " .. Timing.REASONS[advice.reason]
  if advice.reason ~= "precio-alto" and advice.rateIdx[advice.best + 1] then
    text = text .. " " .. rateText(advice.rateIdx[advice.best + 1])
  end
  return text
end

-- Busca un objeto vigilado por nombre (sin tildes ni mayúsculas), número o enlace. Devuelve su id o nil.
function Timing.FindItem(arg)
  if type(arg) ~= "string" then return nil end
  arg = arg:gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "" then return nil end
  local id = tonumber(arg:match("item:(%d+)") or arg:match("^(%d+)$"))
  if id then return Items.ID(id) end
  local wanted = Data.Normalize(arg)
  local partial, partialCount = nil, 0
  for _, w in ipairs(History.WatchList()) do
    local names = {Items.Name(w.id), Data.FALLBACK_NAMES[w.id]}
    for _, name in ipairs(names) do
      local n = Data.Normalize(name)
      if n ~= "" then
        if n == wanted then return w.id end
        if n:find(wanted, 1, true) and partial ~= w.id then partial, partialCount = w.id, partialCount + 1 end
      end
    end
  end
  if partialCount == 1 then return partial end
  return nil
end

-- /oro cuando [objeto]: título, texto para copiar y la línea para el chat. Sin objeto, la tabla de todos y una línea
-- por objeto con consejo (por categorías); con objeto, solo la suya.
function Timing.View(arg)
  local key = History.CurrentMarket()
  local t = now() or 0
  local title = "Oro de Hermandad · cuándo vender"
  if not db or not key then return title, "Aún no se sabe en qué mercado estás.", "aún no se sabe en qué mercado estás." end
  local lines = {}
  local pending = not passDone[key] and " (aún se están leyendo los escaneos guardados: vuelve a mirarlo en unos segundos)" or ""
  local id
  if type(arg) == "string" and arg:match("%S") then
    id = Timing.FindItem(arg)
    if not id then
      local msg = "no encuentro «" .. arg:gsub("|", "") .. "» entre los objetos vigilados (nombre, número o enlace)."
      return nil, nil, msg
    end
  end
  if id then
    local blocks = Timing.ItemBlocks(id, key, t)
    lines[#lines + 1] = "Cuándo vender · " .. itemName(id) .. " · últimas semanas (hora de España)" .. pending
    if not blocks then
      lines[#lines + 1] = "Aún no hay datos de este objeto: escanea la subasta (o espera a los escaneos de la hermandad)."
      return title, table.concat(lines, "\n"), itemName(id) .. ": aún no hay datos."
    end
    local advice = Timing.Advice(blocks)
    local rows = {}
    for i = 1, BLOCKS do
      rows[i] = {priceOK = blocks[i].priceOK, p = blocks[i].p, rateIdx = advice.rateIdx[i], sec = blocks[i].sec,
                 w = blocks[i].w}
    end
    for _, line in ipairs(tableLines(rows)) do lines[#lines + 1] = line end
    local best = bestLine(advice, blocks)
    lines[#lines + 1] = best
    local sales = salesLine(key, id)
    if sales then lines[#lines + 1] = sales end
    for _, line in ipairs(FOOTNOTE) do lines[#lines + 1] = line end
    return title, table.concat(lines, "\n"), itemName(id) .. ": " .. best:gsub("^Mejor franja para vender: ", "")
  end
  local profile = Timing.Profile(key, t)
  lines[#lines + 1] = "Cuándo vender · tu hermandad · últimas semanas (hora de España)" .. pending
  if profile.items == 0 then
    lines[#lines + 1] = "Aún no hay datos en este mercado: escanea la subasta (o espera a los escaneos de la hermandad)."
    return title, table.concat(lines, "\n"), "cuándo vender: aún no hay datos en este mercado."
  end
  for _, line in ipairs(tableLines(profile.blocks)) do lines[#lines + 1] = line end
  local best = bestLine(profile, profile.blocks)
  lines[#lines + 1] = best
  local sales = salesLine(key)
  if sales then lines[#lines + 1] = sales end
  for _, line in ipairs(FOOTNOTE) do lines[#lines + 1] = line end
  -- Una línea por objeto con consejo, por categorías.
  local byCat = {}
  for _, w in ipairs(History.WatchList()) do
    local blocks = Timing.ItemBlocks(w.id, key, t)
    local text = blocks and itemAdviceText(Timing.Advice(blocks))
    if text then
      byCat[w.cat] = byCat[w.cat] or {}
      local list = byCat[w.cat]
      list[#list + 1] = {name = itemName(w.id), text = text}
    end
  end
  for _, cat in ipairs(Data.CATEGORY_ORDER or Spec.CATEGORIES) do
    local list = byCat[cat]
    if list then
      table.sort(list, function(a, b) return a.name < b.name end)
      lines[#lines + 1] = ""
      lines[#lines + 1] = (Data.CATEGORY_LABELS and Data.CATEGORY_LABELS[cat] or cat) .. ":"
      for _, e in ipairs(list) do lines[#lines + 1] = "  " .. e.name .. ": " .. e.text end
    end
  end
  return title, table.concat(lines, "\n"), "cuándo vender: " .. best:gsub("^Mejor franja para vender: ", "")
end

-- Línea de la descripción de un objeto vigilado: «Cuándo vender: 20-24 h (más ventas)» o «aún pocos datos».
function Timing.TooltipLine(id)
  local key = History.CurrentMarket()
  if not db or not key or not isInt(id, 1, 2147483647) then return nil end
  local watched = History.IsFixed(id)
  if not watched then
    for _, extra in ipairs(History.ExtraIDs()) do if extra == id then watched = true; break end end
  end
  if not watched then return nil end
  local blocks = Timing.ItemBlocks(id, key)
  local advice = blocks and Timing.Advice(blocks)
  if not advice or advice.best == nil then return "Cuándo vender: aún pocos datos" end
  return "Cuándo vender: " .. blockLabel(advice.best) .. " (" .. Timing.REASONS[advice.reason] .. ")"
end

---------------------------------------------------------------------------
-- /oro sondeo
---------------------------------------------------------------------------
-- «Capas»: escaneos tuyos y de compañeros del mismo objeto a menos de 10 min (de lo guardado en este mercado) y en
-- cuántos coincide el precio más bajo. Solo cifras.
function Timing.LayerLine(key)
  key = key or History.CurrentMarket()
  local market = key and History.Market(key)
  local pairsSeen, pairsN, same, total = {}, 0, 0, 0
  if market and type(market.obs) == "table" then
    for id, own in pairs(market.items or {}) do
      local mine = Spec.DecodePoints(own.p) -- en orden de hora
      if #mine > 0 then
        for h, entry in pairs(market.obs) do
          local it = entry.items and entry.items[id]
          if it then
            for _, q in ipairs(Spec.DecodePoints(it.p)) do
              -- El tuyo más cercano: búsqueda binaria del primero con t >= q.t y su anterior.
              local lo, hi = 1, #mine + 1
              while lo < hi do
                local mid = floor((lo + hi) / 2)
                if mine[mid].t < q.t then lo = mid + 1 else hi = mid end
              end
              local closest, gap = nil, nil
              for _, k in ipairs({lo - 1, lo}) do
                local p = mine[k]
                if p then
                  local d = abs(p.t - q.t)
                  if d <= Timing.LAYER_SECONDS and (not gap or d < gap) then closest, gap = p, d end
                end
              end
              if closest then
                total = total + 1
                if closest.lo == q.lo then same = same + 1 end
                local k = closest.t .. "|" .. h .. "|" .. q.t
                if not pairsSeen[k] then pairsSeen[k] = true; pairsN = pairsN + 1 end
              end
            end
          end
        end
      end
    end
  end
  return "Capas: " .. plural(pairsN, "par", "pares") .. " de escaneos tuyos y de compañeros a menos de 10 min; mismo precio "
    .. "más bajo en " .. same .. " de " .. plural(total, "objeto", "objetos") .. "."
end

function Timing.ProbeLines()
  local lines = {}
  local key = History.CurrentMarket()
  local m = key and db and marketData(key)
  local items, own, mates, mateScans = 0, 0, 0, 0
  if m then
    for _, item in pairs(m.items) do if item.tRef then items = items + 1 end end
    for obs, set in pairs(m.seen) do
      local n = 0
      for _ in pairs(set) do n = n + 1 end
      if obs == "self" then own = own + n else mates, mateScans = mates + 1, mateScans + n end
    end
  end
  local passText = (key and passDone[key]) and "hecha" or (pass and ("en marcha " .. (pass.i - 1) .. "/" .. #pass.ids) or "pendiente")
  lines[1] = "Cuándo vender: " .. plural(items, "objeto", "objetos") .. " con datos en este mercado · primera pasada "
    .. passText .. " (" .. stats.restarts .. " reinicios) · en cola " .. max(0, #queue - head + 1) .. " · escaneos sumados: "
    .. own .. " tuyos, " .. mateScans .. " de " .. plural(mates, "compañero", "compañeros") .. " · ventas solapadas sin contar "
    .. stats.overlaps .. " · puntos ya sumados saltados " .. stats.skippedSeen .. " · descartados antes de la pasada "
    .. stats.dropped
  local ok, layer = pcall(Timing.LayerLine, key)
  lines[2] = ok and layer or ("Capas: no se pudo calcular (" .. tostring(layer) .. ")")
  if Timing.lastError then lines[3] = "Último fallo de «Cuándo vender»: " .. tostring(Timing.lastError) end
  return lines
end

-- Para las pruebas: estado interno.
function Timing.Internals()
  return {markets = markets, index = index, queue = queue, head = head, pass = pass, passDone = passDone,
          started = started, stats = stats, refCache = refCache, newItem = newItem, addPrice = addPrice,
          addSale = addSale, mergeItems = mergeItems, blocksAt = blocksAt, encodeItem = encodeItem,
          decodeItem = decodeItem, refFor = refFor, overlaps = overlaps, bucketAdd = bucketAdd}
end

return Timing

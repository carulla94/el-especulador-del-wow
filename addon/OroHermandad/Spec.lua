-- Oro de Hermandad: Especular v1 (chollos, picos, reventa, balances).
-- Lógica pura: no llama a la API de WoW. La misma regla vive en JS (src/especular.mjs del panel de la
-- hermandad) y las dos deben dar exactamente los mismos enteros: el contrato es test-vectors/especular-v1.json.
-- Todo el dinero es cobre entero; los porcentajes, puntos básicos (bp: 10000 = 100 %).
local _, ns = ...
ns = ns or {}
local Spec = {}
ns.Spec = Spec

Spec.VERSION = "especular-v1"
Spec.DAY0 = 1577833200        -- 2020-01-01 00:00 CET: día 0 (Auctionator usa la medianoche local del PC)
Spec.LAUNCH = 2499            -- 2026-11-04, miércoles
Spec.GUARD_DAYS = 14          -- sin chollos hasta el día 2513 (18-nov)
Spec.WINDOW = 14              -- días de la ventana del precio normal (sin contar hoy)
Spec.MIN_DAYS = 7             -- días con precio para fiarse
Spec.KEEP_DAYS = 120          -- días guardados por objeto
Spec.KEEP_POINT_SECONDS = 14 * 86400
Spec.MAX_POINTS = 120         -- puntos por objeto
Spec.POINT_MERGE_SECONDS = 1800
Spec.MAX_BYTES = 768 * 1024   -- techo de OroHermandadHist en el archivo de SavedVariables

Spec.PRICE_MAX = 1000000000
Spec.QTY_MAX = 1000000
Spec.UNITS_MAX = 10000
Spec.DAY_MAX = 99999
Spec.TIME_MAX = 9999999999

Spec.SBP_FLOOR = 300          -- sigma mínima: 3 %
Spec.CUT_BP = 500             -- comisión de la subasta por defecto (5 %)
Spec.UNDERCUT = 1             -- rebaja de 1 c (100 c si la subasta no admite cobre)
Spec.FAILED_LISTINGS = 1      -- publicaciones que se esperan perder (el depósito no se devuelve)
Spec.BUDGET = 1000000         -- presupuesto por defecto: 100 oros (la parte por objeto es el 25 %)
Spec.MIN_PROFIT = 10000       -- 1 oro por tanda
Spec.MIN_MARGIN_PCT = 15      -- ganancia mínima sobre lo invertido (coste + depósitos)
Spec.CAP_LIQ_DEFAULT = 20     -- unidades máximas si no se sabe la oferta típica

-- Claves de categoría de OroHermandadHist (contrato con el subidor del PC y el panel).
Spec.CATEGORIES = {"metal", "piedra", "gema", "hierba", "piel", "tela", "pocion", "elixir", "frasco", "comida",
                   "venda", "encantar", "elemental", "otro"}
local CATEGORY = {}
for _, key in ipairs(Spec.CATEGORIES) do CATEGORY[key] = true end
function Spec.IsCategory(key) return CATEGORY[key] == true end

local floor, max, min = math.floor, math.max, math.min

---------------------------------------------------------------------------
-- Aritmética entera (idéntica en Lua y JS: con los rangos de arriba todo queda por debajo de 2^53)
---------------------------------------------------------------------------
local function isInt(x, lo, hi)
  return type(x) == "number" and x == x and x >= lo and x <= hi and x == floor(x)
end
local function isPrice(x) return isInt(x, 1, Spec.PRICE_MAX) end

local function idiv(a, b) return floor(a / b) end
local function ceilDiv(a, b) return idiv(a + b - 1, b) end

local function sortedCopy(xs)
  local s = {}
  for i = 1, #xs do s[i] = xs[i] end
  table.sort(s)
  return s
end

-- Mediana; con un número par de valores, idiv(a+b, 2) (hacia abajo, como engine.mjs).
local function median(xs)
  local n = #xs
  if n == 0 then return nil end
  local s = sortedCopy(xs)
  local m = floor(n / 2)
  if n % 2 == 1 then return s[m + 1] end
  return idiv(s[m] + s[m + 1], 2)
end

-- Cuantil sin interpolar: sorted[idiv((n-1)*num, den)] contando desde 0.
local function quantile(xs, num, den)
  local n = #xs
  if n == 0 then return nil end
  return sortedCopy(xs)[idiv((n - 1) * num, den) + 1]
end

Spec.IsInt, Spec.Idiv, Spec.CeilDiv, Spec.Median, Spec.Quantile = isInt, idiv, ceilDiv, median, quantile

---------------------------------------------------------------------------
-- Días
---------------------------------------------------------------------------
-- Índice de día de una hora unix (segundos). nil si t no es un número entero.
function Spec.DayIndex(t)
  if not isInt(t, -Spec.TIME_MAX, Spec.TIME_MAX) then return nil end
  return idiv(t - Spec.DAY0, 86400)
end

-- Día de la semana de un índice de día: lunes 0 ... domingo 6 (el día 2499 es miércoles, 2).
function Spec.WeekdayOf(d) return (d + 2) % 7 end

---------------------------------------------------------------------------
-- Formato de OroHermandadHist (contrato 2)
--   días:   "d,lo,hi,last,qty,scans,src;..." (src o = propio, a = importado de Auctionator; qty 0 = desconocida)
--   puntos: "t,lo,qty,qty5;..." (t en segundos unix; qty5 = unidades hasta un 5 % sobre el mínimo, 0 si no se sabe)
-- Los lectores se saltan los registros mal formados y no fallan nunca. Solo cifras decimales; los campos de más
-- al final de un registro se ignoran (por si una versión futura añade alguno).
---------------------------------------------------------------------------
local function parseInt(text, lo, hi)
  if type(text) ~= "string" or text == "" or #text > 12 or text:find("[^0-9]") then return nil end
  local n = tonumber(text)
  if n and n >= lo and n <= hi then return n end
  return nil
end

local function fields(record)
  local out = {}
  for f in (record .. ","):gmatch("([^,]*),") do out[#out + 1] = f end
  return out
end

local function validDay(r)
  return type(r) == "table" and isInt(r.d, 0, Spec.DAY_MAX) and isPrice(r.lo) and isPrice(r.hi) and r.lo <= r.hi
    and isPrice(r.last) and isInt(r.qty, 0, Spec.QTY_MAX) and isInt(r.scans, 0, Spec.QTY_MAX)
    and (r.src == "o" or r.src == "a")
end

local function copyDay(r)
  return {d = r.d, lo = r.lo, hi = r.hi, last = r.last, qty = r.qty, scans = r.scans, src = r.src}
end

-- Junta dos registros del mismo observador y el mismo día. Idempotente, conmutativa y asociativa:
-- un registro propio ("o") gana entero a uno importado ("a"); entre dos del mismo tipo, lo = mín, hi = máx,
-- qty = máx, scans = máx y last es el del registro con más escaneos (a igualdad, el last mayor).
-- Devuelve nil si los dos registros son de días distintos.
function Spec.MergeDay(a, b)
  if not a then return b and copyDay(b) or nil end
  if not b then return copyDay(a) end
  if a.d ~= b.d then return nil end
  if a.src ~= b.src then return copyDay(a.src == "o" and a or b) end
  local newer = (b.scans > a.scans or (b.scans == a.scans and b.last > a.last)) and b or a
  return {d = a.d, lo = min(a.lo, b.lo), hi = max(a.hi, b.hi), last = newer.last, qty = max(a.qty, b.qty),
          scans = max(a.scans, b.scans), src = a.src}
end

-- Lista válida, un registro por día (juntados con MergeDay), en orden y con los KEEP_DAYS más nuevos.
function Spec.NormalizeDays(records)
  local byDay, days = {}, {}
  for _, r in ipairs(type(records) == "table" and records or {}) do
    if validDay(r) then
      if not byDay[r.d] then days[#days + 1] = r.d end
      byDay[r.d] = Spec.MergeDay(byDay[r.d], r)
    end
  end
  table.sort(days)
  local out, first = {}, max(1, #days - Spec.KEEP_DAYS + 1)
  for i = first, #days do out[#out + 1] = byDay[days[i]] end
  return out
end

function Spec.DecodeDays(text)
  local list = {}
  if type(text) ~= "string" then return list end
  for entry in text:gmatch("[^;]+") do
    local f = fields(entry)
    local r = {d = parseInt(f[1], 0, Spec.DAY_MAX), lo = parseInt(f[2], 1, Spec.PRICE_MAX),
               hi = parseInt(f[3], 1, Spec.PRICE_MAX), last = parseInt(f[4], 1, Spec.PRICE_MAX),
               qty = parseInt(f[5], 0, Spec.QTY_MAX), scans = parseInt(f[6], 0, Spec.QTY_MAX), src = f[7]}
    if validDay(r) then list[#list + 1] = r end
  end
  return Spec.NormalizeDays(list)
end

function Spec.EncodeDays(records)
  local parts = {}
  for i, r in ipairs(Spec.NormalizeDays(records)) do
    parts[i] = table.concat({r.d, r.lo, r.hi, r.last, r.qty, r.scans, r.src}, ",")
  end
  return table.concat(parts, ";")
end

local function validPoint(p)
  return type(p) == "table" and isInt(p.t, 1, Spec.TIME_MAX) and isPrice(p.lo) and isInt(p.qty, 0, Spec.QTY_MAX)
    and isInt(p.qty5, 0, Spec.QTY_MAX)
end

-- Dos puntos a menos de 30 min se juntan en el primero: lo = mín, qty = máx, y qty5 del punto más barato
-- (a igual precio, la mayor). Así juntar es conmutativo y la lista normalizada no cambia al normalizarla otra vez.
local function mergePoint(a, b)
  local qty5 = a.qty5
  if b.lo < a.lo then qty5 = b.qty5 elseif b.lo == a.lo then qty5 = max(a.qty5, b.qty5) end
  a.lo, a.qty, a.qty5 = min(a.lo, b.lo), max(a.qty, b.qty), qty5
end

function Spec.NormalizePoints(points)
  local list = {}
  for _, p in ipairs(type(points) == "table" and points or {}) do
    if validPoint(p) then list[#list + 1] = {t = p.t, lo = p.lo, qty = p.qty, qty5 = p.qty5} end
  end
  table.sort(list, function(a, b) return a.t < b.t end)
  local merged = {}
  for _, p in ipairs(list) do
    local last = merged[#merged]
    if last and p.t - last.t < Spec.POINT_MERGE_SECONDS then mergePoint(last, p) else merged[#merged + 1] = p end
  end
  local out, first = {}, max(1, #merged - Spec.MAX_POINTS + 1)
  for i = first, #merged do out[#out + 1] = merged[i] end
  return out
end

function Spec.DecodePoints(text)
  local list = {}
  if type(text) ~= "string" then return list end
  for entry in text:gmatch("[^;]+") do
    local f = fields(entry)
    local p = {t = parseInt(f[1], 1, Spec.TIME_MAX), lo = parseInt(f[2], 1, Spec.PRICE_MAX),
               qty = parseInt(f[3], 0, Spec.QTY_MAX), qty5 = parseInt(f[4], 0, Spec.QTY_MAX)}
    if validPoint(p) then list[#list + 1] = p end
  end
  return Spec.NormalizePoints(list)
end

function Spec.EncodePoints(points)
  local parts = {}
  for i, p in ipairs(Spec.NormalizePoints(points)) do parts[i] = table.concat({p.t, p.lo, p.qty, p.qty5}, ",") end
  return table.concat(parts, ";")
end

-- Depósitos aprendidos: "dur:cobre,dur:cobre" (dur = duración de la subasta, 1..9).
function Spec.DecodeDeposits(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for entry in text:gmatch("[^,]+") do
    local dur, copper = entry:match("^([^:]*):([^:]*)$")
    dur, copper = parseInt(dur, 1, 9), parseInt(copper, 0, Spec.PRICE_MAX)
    if dur and copper then out[dur] = copper end
  end
  return out
end

function Spec.EncodeDeposits(deposits)
  local parts = {}
  for dur = 1, 9 do
    local copper = type(deposits) == "table" and deposits[dur]
    if isInt(copper, 0, Spec.PRICE_MAX) then parts[#parts + 1] = dur .. ":" .. copper end
  end
  return table.concat(parts, ",")
end

---------------------------------------------------------------------------
-- Registro (lo usa el lado WoW tras un escaneo completo; aquí solo la regla)
---------------------------------------------------------------------------
-- Suma un escaneo propio al día d: lo = mín, hi = máx, last = p, qty = máx, scans + 1. Un día importado de
-- Auctionator se sustituye por el propio. Quien llama no debe registrar dos veces el mismo escaneo.
-- Devuelve la lista normalizada y true si se escribió.
function Spec.RecordScan(records, d, p, qty)
  local list = Spec.NormalizeDays(records)
  if not (isInt(d, 0, Spec.DAY_MAX) and isPrice(p)) then return list, false end
  qty = isInt(qty, 0, Spec.QTY_MAX) and qty or 0
  for _, r in ipairs(list) do
    if r.d == d and r.src == "o" then
      r.lo, r.hi, r.last, r.qty, r.scans = min(r.lo, p), max(r.hi, p), p, max(r.qty, qty), r.scans + 1
      return list, true
    end
  end
  local kept = {}
  for _, r in ipairs(list) do if r.d ~= d then kept[#kept + 1] = r end end
  kept[#kept + 1] = {d = d, lo = p, hi = p, last = p, qty = qty, scans = 1, src = "o"}
  return Spec.NormalizeDays(kept), true
end

function Spec.AddPoint(points, t, lo, qty, qty5)
  local list = Spec.NormalizePoints(points)
  list[#list + 1] = {t = t, lo = lo, qty = isInt(qty, 0, Spec.QTY_MAX) and qty or 0,
                     qty5 = isInt(qty5, 0, Spec.QTY_MAX) and qty5 or 0}
  return Spec.NormalizePoints(list)
end

-- Quita los días de hace KEEP_DAYS o más y los del futuro (más de un día: relojes desajustados).
function Spec.PruneDays(records, today, keep)
  keep = keep or Spec.KEEP_DAYS
  local kept = {}
  for _, r in ipairs(type(records) == "table" and records or {}) do
    if type(r) == "table" and isInt(r.d, 0, Spec.DAY_MAX) and r.d > today - keep and r.d <= today + 1 then kept[#kept + 1] = r end
  end
  return Spec.NormalizeDays(kept)
end

function Spec.PrunePoints(points, now, keepSeconds)
  keepSeconds = keepSeconds or Spec.KEEP_POINT_SECONDS
  local kept = {}
  for _, p in ipairs(type(points) == "table" and points or {}) do
    if type(p) == "table" and isInt(p.t, 1, Spec.TIME_MAX) and p.t > now - keepSeconds and p.t <= now + 86400 then kept[#kept + 1] = p end
  end
  return Spec.NormalizePoints(kept)
end

-- Historial de Auctionator (Auctionator.Database:GetPriceHistory): filas {rawDay, minSeen, maxSeen, available},
-- rawDay a veces como texto. Solo rellena días que no tenemos (src a, scans 0, last = lo); nunca pisa un día
-- propio ni uno ya importado. Devuelve la lista normalizada y cuántos días se añadieron.
function Spec.ImportAuctionator(records, rows, today, keep)
  keep = keep or Spec.KEEP_DAYS
  local list, have, added = Spec.NormalizeDays(records), {}, 0
  for _, r in ipairs(list) do have[r.d] = true end
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if type(row) == "table" then
      local d = tonumber(row.rawDay)
      local lo, hi = row.minSeen, row.maxSeen
      if not isPrice(lo) then lo = hi end
      if not isPrice(hi) then hi = lo end
      if isPrice(lo) and isPrice(hi) and isInt(d, 0, Spec.DAY_MAX) and not have[d] and d <= today and d > today - keep then
        if lo > hi then lo, hi = hi, lo end
        local qty = isInt(row.available, 0, Spec.QTY_MAX) and row.available or 0
        list[#list + 1] = {d = d, lo = lo, hi = hi, last = lo, qty = qty, scans = 0, src = "a"}
        have[d] = true
        added = added + 1
      end
    end
  end
  return Spec.NormalizeDays(list), added
end

---------------------------------------------------------------------------
-- Valor del día entre observadores
---------------------------------------------------------------------------
-- observers: lista de {lo, hi, qty, id}. v = mediana del multiconjunto {lo, hi}; con 3 o más observadores se
-- descarta a quien tenga idiv(lo+hi, 2) fuera de [idiv(v,2), 2v] y se recalcula v una vez (si se descartaran todos,
-- se quedan todos). qty = mediana de las qty > 0 de los que quedan. Devuelve {v, qty, obs, ids} o nil.
function Spec.DayValue(observers)
  local valid = {}
  for _, o in ipairs(type(observers) == "table" and observers or {}) do
    if type(o) == "table" and isPrice(o.lo) and isPrice(o.hi) and o.lo <= o.hi then valid[#valid + 1] = o end
  end
  if #valid == 0 then return nil end
  local function values(list)
    local out = {}
    for _, o in ipairs(list) do out[#out + 1] = o.lo; out[#out + 1] = o.hi end
    return out
  end
  local v, kept = median(values(valid)), valid
  if #valid >= 3 then
    local low, high, inside = idiv(v, 2), 2 * v, {}
    for _, o in ipairs(valid) do
      local mid = idiv(o.lo + o.hi, 2)
      if mid >= low and mid <= high then inside[#inside + 1] = o end
    end
    if #inside > 0 and #inside < #valid then kept = inside; v = median(values(kept)) end
  end
  local qtys, ids = {}, {}
  for _, o in ipairs(kept) do
    if isInt(o.qty, 1, Spec.QTY_MAX) then qtys[#qtys + 1] = o.qty end
    ids[#ids + 1] = o.id ~= nil and tostring(o.id) or ""
  end
  return {v = v, qty = median(qtys), obs = #kept, ids = ids}
end

-- byDay: {[d] = {{lo, hi, qty, id, src}, ...}} con registros de varios observadores. Junta los de cada observador
-- (MergeDay: lo propio gana a lo importado) y calcula DayValue. Devuelve {[d] = DayValue}.
function Spec.BuildDays(byDay)
  local out = {}
  for d, records in pairs(type(byDay) == "table" and byDay or {}) do
    if isInt(d, 0, Spec.DAY_MAX) and type(records) == "table" then
      local perId, order = {}, {}
      for _, r in ipairs(records) do
        if type(r) == "table" then
          local rec = {d = d, lo = r.lo, hi = r.hi, last = isPrice(r.last) and r.last or r.lo,
                       qty = r.qty == nil and 0 or r.qty, scans = isInt(r.scans, 0, Spec.QTY_MAX) and r.scans or 0,
                       src = r.src == nil and "o" or r.src}
          if validDay(rec) then
            local id = r.id ~= nil and tostring(r.id) or ""
            if not perId[id] then order[#order + 1] = id end
            perId[id] = Spec.MergeDay(perId[id], rec)
          end
        end
      end
      local observers = {}
      for _, id in ipairs(order) do
        local m = perId[id]
        observers[#observers + 1] = {lo = m.lo, hi = m.hi, qty = m.qty, id = id}
      end
      out[d] = Spec.DayValue(observers)
    end
  end
  return out
end

-- Días de un solo observador (los registros de DecodeDays): {[d] = DayValue}.
function Spec.DaysFromRecords(records, id)
  local out = {}
  for _, r in ipairs(Spec.NormalizeDays(records)) do
    out[r.d] = Spec.DayValue({{lo = r.lo, hi = r.hi, qty = r.qty, id = id}})
  end
  return out
end

---------------------------------------------------------------------------
-- Precio normal en el día T (T no cuenta)
---------------------------------------------------------------------------
local function valueOf(days, d)
  local x = days[d]
  local v = type(x) == "table" and x.v or x
  if isPrice(v) then return v end
  return nil
end

local function valuesIn(days, from, to)
  local out = {}
  for d = from, to do
    local v = valueOf(days, d)
    if v then out[#out + 1] = v end
  end
  return out
end

-- days: {[d] = DayValue} (o {[d] = v}). opts.cloud: en la nube ALTA exige 2 miembros distintos.
-- Devuelve {T, n, k, maxDay, fresh, prev1, prev2, status, N, MAD, sBp, R3, O7, trend, trendBp, conf, Rs, Q}.
-- status: SIN_DATOS (n < 7; entonces N y lo demás son nil), INESTABLE (tendencia no estable) u OK.
-- trend: "bajando", "subiendo", "estable" o "desconocida". conf: "ALTA", "MEDIA" o "BAJA".
function Spec.Baseline(days, T, opts)
  opts = opts or {}
  days = type(days) == "table" and days or {}
  local b = {T = T, n = 0, k = 0, fresh = false, status = "SIN_DATOS"}
  if not isInt(T, 0, Spec.DAY_MAX) then return b end
  local vals, qtys, ids, k = {}, {}, {}, 0
  for d = T - Spec.WINDOW, T - 1 do
    local v = valueOf(days, d)
    if v then
      vals[#vals + 1] = v
      b.maxDay = d
      local x = days[d]
      local list = type(x) == "table" and type(x.ids) == "table" and x.ids or {""}
      for _, id in ipairs(list) do
        id = tostring(id)
        if not ids[id] then ids[id] = true; k = k + 1 end
      end
      if type(x) == "table" and isInt(x.qty, 0, Spec.QTY_MAX) then qtys[#qtys + 1] = x.qty end
    end
  end
  b.n, b.k = #vals, k
  b.fresh = b.maxDay ~= nil and b.maxDay >= T - 2
  b.prev1, b.prev2 = valueOf(days, T - 1), valueOf(days, T - 2)
  if b.n < Spec.MIN_DAYS then return b end

  local N = median(vals)
  local devs = {}
  for i, v in ipairs(vals) do devs[i] = math.abs(v - N) end
  b.N, b.MAD = N, median(devs)
  b.sBp = max(Spec.SBP_FLOOR, idiv(b.MAD * 14826, N))
  local r3, o7 = valuesIn(days, T - 3, T - 1), valuesIn(days, T - 10, T - 4)
  b.R3 = #r3 >= 2 and median(r3) or nil
  b.O7 = #o7 >= 2 and median(o7) or nil
  b.trend = "desconocida"
  if b.R3 and b.O7 then
    b.trendBp = idiv(b.R3 * 10000, b.O7) - 10000
    if b.R3 * 10 < b.O7 * 9 then b.trend = "bajando"
    elseif b.R3 * 100 > b.O7 * 115 then b.trend = "subiendo"
    else b.trend = "estable" end
  end
  if b.n >= 12 and b.sBp <= 1500 and b.maxDay >= T - 1 and (not opts.cloud or k >= 2) then b.conf = "ALTA"
  elseif b.n >= 10 and b.sBp <= 2500 and b.fresh then b.conf = "MEDIA"
  else b.conf = "BAJA" end
  b.Rs = quantile(vals, 2, 5)
  if b.R3 then b.Rs = min(b.Rs, b.R3) end
  b.Q = median(qtys)
  b.status = b.trend == "estable" and "OK" or "INESTABLE"
  return b
end

---------------------------------------------------------------------------
-- Veredicto del precio actual p
---------------------------------------------------------------------------
-- Devuelve {verdict, guard, wait, dBp, band, dumpLine, spikeLine, shiftLine, trend}. Veredictos, en orden:
-- SIN_DATOS, INESTABLE, SIN_PRECIO (p nil), FUERA_DE_RANGO, BAJADA, CHOLLO (PROTECCION antes del día 2513),
-- CARO, ESPERA, NORMAL. guard: protección de lanzamiento activa. wait: nota "si no tienes prisa, espera" en
-- las filas de venta. opts.launch cambia el día de lanzamiento (pruebas).
function Spec.Assess(baseline, p, T, opts)
  opts = opts or {}
  T = T or (baseline and baseline.T)
  local launch = opts.launch or Spec.LAUNCH
  local a = {verdict = "SIN_DATOS", guard = isInt(T, 0, Spec.DAY_MAX) and T < launch + Spec.GUARD_DAYS or false,
             wait = false, trend = baseline and baseline.trend}
  if type(baseline) ~= "table" or (baseline.n or 0) < Spec.MIN_DAYS or not isPrice(baseline.N)
    or not isInt(baseline.sBp, 0, Spec.PRICE_MAX) then return a end
  local N = baseline.N
  a.band = ceilDiv(N * 25 * min(baseline.sBp, 10000), 100000)
  a.dumpLine = min(idiv(N * 4, 5), N - a.band)
  a.spikeLine = max(ceilDiv(N * 5, 4), N + a.band)
  a.shiftLine = idiv(N * 85, 100)
  local low = idiv(N * 4, 5)
  if isPrice(p) then a.dBp = idiv(p * 10000, N) - 10000 end
  if baseline.trend ~= "estable" then a.verdict = "INESTABLE"; return a end
  if p == nil then a.verdict = "SIN_PRECIO"; return a end
  if not isPrice(p) then a.verdict = "FUERA_DE_RANGO"; return a end
  a.wait = p <= low
  local prev1, prev2 = baseline.prev1, baseline.prev2
  if prev1 and prev2 and prev1 < a.shiftLine and prev2 < a.shiftLine then a.verdict = "BAJADA"; return a end
  local trusted = baseline.conf == "ALTA" or baseline.conf == "MEDIA"
  if p <= a.dumpLine and trusted and baseline.fresh then
    a.verdict = a.guard and "PROTECCION" or "CHOLLO"
  elseif p >= a.spikeLine and trusted then
    a.verdict = "CARO"
  elseif p <= low then
    a.verdict = "ESPERA"
  else
    a.verdict = "NORMAL"
  end
  return a
end

---------------------------------------------------------------------------
-- Compra para revender (flip)
---------------------------------------------------------------------------
-- book: lotes {{precio, cantidad}, ...} (o {price=, qty=}); se ordenan por precio. Si book es nil, se usa el libro
-- estimado {{opts.p, opts.q5 o 1}}. opts: cutBp, u, D (nil = estimado con opts.vendor), vendor, F, budget, Q
-- (nil = baseline.Q), p, q5. Devuelve {units, cost, profit, maxBuy, breakEven, netUnit, risk, D, F, Rs,
-- depositEstimated, bookEstimated, avgIn, capLiq, capBudget, accept, reason}; reason nil si se acepta, si no
-- FUERA_DE_RANGO, SIN_BASE, SIN_MARGEN, SIN_UNIDADES, POCA_GANANCIA o MARGEN_BAJO.
function Spec.Flip(baseline, book, opts)
  opts = opts or {}
  local r = {units = 0, cost = 0, profit = 0, accept = false, depositEstimated = false, bookEstimated = false}
  local ok = true
  local function option(value, lo, hi, default)
    if value == nil then return default end
    if not isInt(value, lo, hi) then ok = false end
    return value
  end
  local cutBp = option(opts.cutBp, 0, 9999, Spec.CUT_BP)
  local u = option(opts.u, 1, 10000, Spec.UNDERCUT)
  local D = option(opts.D, 0, Spec.PRICE_MAX, nil)
  local vendor = option(opts.vendor, 0, Spec.PRICE_MAX, 0)
  local F = option(opts.F, 0, 100, Spec.FAILED_LISTINGS)
  local budget = option(opts.budget, 0, 100000000000, Spec.BUDGET)
  local Q = option(opts.Q, 0, Spec.QTY_MAX, nil)
  local p = option(opts.p, 1, Spec.PRICE_MAX, nil)
  local q5 = option(opts.q5, 0, Spec.QTY_MAX, nil)
  local lots = {}
  if book ~= nil then
    if type(book) ~= "table" then ok = false else
      for _, lot in ipairs(book) do
        local price = type(lot) == "table" and (lot[1] or lot.price)
        local qty = type(lot) == "table" and (lot[2] or lot.qty)
        if isPrice(price) and isInt(qty, 0, Spec.QTY_MAX) then lots[#lots + 1] = {price, qty} else ok = false end
      end
    end
  end
  if not ok then r.reason = "FUERA_DE_RANGO"; return r end
  if type(baseline) ~= "table" or not isPrice(baseline.Rs) then r.reason = "SIN_BASE"; return r end

  if D == nil then D = ceilDiv(vendor * 6000, 10000); r.depositEstimated = true end
  r.D, r.F, r.Rs = D, F, baseline.Rs
  r.netUnit = idiv((baseline.Rs - u) * (10000 - cutBp), 10000)
  r.risk = D * F
  r.maxBuy = idiv((r.netUnit - r.risk) * 100, 115)
  if Q == nil and isInt(baseline.Q, 0, Spec.QTY_MAX) then Q = baseline.Q end
  r.capLiq = Q and max(1, idiv(Q * 25, 100)) or Spec.CAP_LIQ_DEFAULT
  r.capBudget = idiv(budget * 25, 100)
  if r.maxBuy <= 0 then r.reason = "SIN_MARGEN"; return r end

  if book == nil and p then
    lots = {{p, (q5 and q5 >= 1) and q5 or 1}}
    r.bookEstimated = true
  end
  table.sort(lots, function(x, y) return x[1] < y[1] end)
  local cap, n, cost = min(r.capLiq, Spec.UNITS_MAX), 0, 0
  for _, lot in ipairs(lots) do
    local price = lot[1]
    if price > r.maxBuy or n >= cap then break end
    local take = min(lot[2], cap - n, max(0, idiv(r.capBudget - cost, price)))
    n, cost = n + take, cost + take * price
  end
  if n == 0 then r.reason = "SIN_UNIDADES"; return r end
  r.units, r.cost = n, cost
  r.profit = n * r.netUnit - cost - n * r.risk
  r.avgIn = ceilDiv(cost + n * r.risk, n)
  r.breakEven = ceilDiv(r.avgIn * 10000, 10000 - cutBp) + u
  r.accept = r.profit >= Spec.MIN_PROFIT and r.profit * 100 >= Spec.MIN_MARGIN_PCT * (cost + n * r.risk)
  if not r.accept then r.reason = r.profit < Spec.MIN_PROFIT and "POCA_GANANCIA" or "MARGEN_BAJO" end
  return r
end

---------------------------------------------------------------------------
-- Balances: Δ1d y Δ7d en bp (nil si faltan datos)
---------------------------------------------------------------------------
function Spec.Deltas(days, T)
  days = type(days) == "table" and days or {}
  local out = {}
  if not isInt(T, 0, Spec.DAY_MAX) then return out end
  local today, yesterday = valueOf(days, T), valueOf(days, T - 1)
  if today and yesterday then out.d1 = idiv(today * 10000, yesterday) - 10000 end
  local recent, before = valuesIn(days, T - 6, T), valuesIn(days, T - 13, T - 7)
  if #recent >= 4 and #before >= 4 then out.d7 = idiv(median(recent) * 10000, median(before)) - 10000 end
  return out
end

---------------------------------------------------------------------------
-- Textos (los mismos que el panel web; los de confianza y veredicto están en el contrato)
---------------------------------------------------------------------------
function Spec.Money(copper)
  copper = floor((copper or 0) + 0.5)
  local sign = copper < 0 and "-" or ""
  copper = math.abs(copper)
  local g, s, c = floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
  if g > 0 then
    return sign .. g .. "o" .. (s > 0 and (" " .. s .. "p") or "")
  elseif s > 0 then
    return sign .. s .. "p" .. (c > 0 and (" " .. c .. "c") or "")
  end
  return sign .. c .. "c"
end

local Texts = {
  CAVEAT = "el precio mínimo publicado no es una venta confirmada",
  GUARD = "Protección de lanzamiento: sin compras especulativas hasta el 18-nov",
}
Spec.Texts = Texts

-- Porcentaje desde bp, sin signo, con una cifra decimal como mucho y coma decimal: 300 -> "3", 1234 -> "12,3".
function Texts.Pct(bp)
  local tenths = idiv(math.abs(bp) + 5, 10)
  local whole, decimal = idiv(tenths, 10), tenths % 10
  if decimal == 0 then return tostring(whole) end
  return whole .. "," .. decimal
end

function Texts.SignedPct(bp)
  local text = Texts.Pct(bp)
  if text == "0" then return text end
  return (bp < 0 and "-" or "+") .. text
end

function Texts.Days(n) return n == 1 and "1 día" or (n .. " días") end

function Texts.Learning(n) return "Aprendiendo precios: " .. (n or 0) .. " de 7 días" end

function Texts.Conf(baseline)
  if type(baseline) ~= "table" or (baseline.n or 0) < Spec.MIN_DAYS or not baseline.conf then
    return Texts.Learning(type(baseline) == "table" and baseline.n or 0)
  end
  local spread = " · variación ±" .. Texts.Pct(baseline.sBp) .. " %"
  if baseline.conf == "ALTA" then
    return "Fiable · " .. Texts.Days(baseline.n) .. spread .. ((baseline.k or 0) >= 2 and (" · " .. baseline.k .. " miembros") or "")
  elseif baseline.conf == "MEDIA" then
    return "Orientativo · " .. Texts.Days(baseline.n) .. spread
  end
  return "Poco fiable: pocos datos o precio muy variable"
end

function Texts.Status(assessment, baseline)
  local verdict = type(assessment) == "table" and assessment.verdict or "SIN_DATOS"
  local dBp = type(assessment) == "table" and assessment.dBp or 0
  if verdict == "SIN_DATOS" then return Texts.Learning(type(baseline) == "table" and baseline.n or 0) end
  if verdict == "INESTABLE" then
    local trend = type(baseline) == "table" and baseline.trend
    if trend == "bajando" then
      return "Mercado bajando (" .. Texts.SignedPct(baseline.trendBp) .. " % en una semana): vende pronto, no compres para revender"
    elseif trend == "subiendo" then
      return "Mercado subiendo: aún no hay precio normal"
    end
    return "Tendencia desconocida: faltan precios de algunos días"
  end
  if verdict == "SIN_PRECIO" then return "Sin precio actual: escanea la subasta" end
  if verdict == "FUERA_DE_RANGO" then return "Precio fuera de rango" end
  if verdict == "BAJADA" then return "Bajada de nivel: dos días por debajo de lo normal; no es un chollo" end
  if verdict == "PROTECCION" then return Texts.GUARD end
  if verdict == "CHOLLO" then return "Chollo: " .. Texts.Pct(dBp) .. " % por debajo de lo normal" end
  if verdict == "CARO" then return "Precio alto: " .. Texts.Pct(dBp) .. " % por encima de lo normal" end
  if verdict == "ESPERA" then
    return "Precio bajo (" .. Texts.Pct(dBp) .. " % por debajo de lo normal): si no tienes prisa, espera"
  end
  return "Precio normal"
end

-- Frase de la compra (o por qué no compensa). money: formateador de cobre (por defecto el del addon: 1o 23p).
function Texts.Flip(flip, money)
  money = money or Spec.Money
  if type(flip) ~= "table" then return "Sin precio normal: no se calcula la compra" end
  if flip.accept then
    local losses = ""
    if (flip.F or 0) == 1 then losses = " y un depósito perdido"
    elseif (flip.F or 0) >= 2 then losses = " y " .. flip.F .. " depósitos perdidos" end
    local text = string.format("Compra %d× a %s como máximo; no revendas por debajo de %s; objetivo %s; ganancia ≈ %s tras la comisión%s",
      flip.units, money(flip.maxBuy), money(flip.breakEven), money(flip.Rs), money(flip.profit), losses)
    if flip.depositEstimated and (flip.F or 0) > 0 then text = text .. " (depósito estimado)" end
    if flip.bookEstimated then text = text .. " · estimado: confirma en la subasta" end
    return text
  end
  local reason = flip.reason
  if reason == "FUERA_DE_RANGO" then return "Datos fuera de rango: no se calcula la compra" end
  if reason == "SIN_MARGEN" then return "No compensa: la comisión y el depósito se comen el margen" end
  if reason == "SIN_UNIDADES" then return "No compensa: no hay nada a la venta por debajo de " .. money(flip.maxBuy) end
  -- Con lotes a maxBuy o menos la ganancia siempre es positiva (cada unidad deja al menos un 15 % del precio).
  if reason == "POCA_GANANCIA" then return "No compensa: ganarías solo " .. money(flip.profit) .. " (menos de 1 oro)" end
  if reason == "MARGEN_BAJO" then
    return "No compensa: ganarías " .. money(flip.profit) .. ", menos del " .. Spec.MIN_MARGIN_PCT .. " % de lo invertido"
  end
  return "Sin precio normal: no se calcula la compra"
end

---------------------------------------------------------------------------
-- Tamaño en el archivo de SavedVariables
---------------------------------------------------------------------------
-- Bytes que ocupa un valor escrito al estilo de WoW (tabuladores, ["clave"] = valor, y "-- [n]" en los arrays).
-- Es exacto para ese formato salvo el orden de las claves, que no cambia el tamaño.
local function stringSize(s)
  local extra = 0
  for _ in s:gmatch('["\\\n\r]') do extra = extra + 1 end
  for _ in s:gmatch("%z") do extra = extra + 3 end
  return #s + 2 + extra
end

local function valueSize(value, depth)
  local kind = type(value)
  if kind == "string" then return stringSize(value) end
  if kind == "number" or kind == "boolean" then return #tostring(value) end
  if kind ~= "table" or depth > 32 then return 3 end -- "nil"
  local inner = depth + 1
  local size = 1 + 1 + depth + 1                        -- "{", "\n", tabuladores, "}"
  local n = #value
  for i = 1, n do
    size = size + inner + valueSize(value[i], inner) + #(", -- [" .. i .. "]") + 1
  end
  for k, v in pairs(value) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == floor(k)) then
      local key = type(k) == "string" and (2 + stringSize(k)) or (2 + #tostring(k))
      size = size + inner + key + 3 + valueSize(v, inner) + 2 -- " = ", ",\n"
    end
  end
  return size
end

function Spec.EstimateSize(value, name)
  return #(name or "OroHermandadHist") + 3 + valueSize(value, 0) + 1
end

-- Poda al cargar: días de más de KEEP_DAYS y puntos de más de 14 días; borra los objetos que quedan vacíos.
-- Devuelve cuántos objetos se borraron.
function Spec.PruneHist(hist, now)
  local today, removed = Spec.DayIndex(now), 0
  if type(hist) ~= "table" or type(hist.markets) ~= "table" or not today then return 0 end
  for _, market in pairs(hist.markets) do
    if type(market) == "table" and type(market.items) == "table" then
      for id, item in pairs(market.items) do
        if type(item) ~= "table" then
          market.items[id] = nil; removed = removed + 1
        else
          item.d = Spec.EncodeDays(Spec.PruneDays(Spec.DecodeDays(item.d), today))
          item.p = Spec.EncodePoints(Spec.PrunePoints(Spec.DecodePoints(item.p), now))
          if item.d == "" and item.p == "" then market.items[id] = nil; removed = removed + 1 end
        end
      end
    end
  end
  return removed
end

-- Si OroHermandadHist pasa de maxBytes: primero los puntos de más de 7 días, luego todos los puntos, y después se
-- acortan los días a 90, 60 y 30. Devuelve el paso al que hubo que llegar (0 = cabía) y el tamaño final.
function Spec.Shrink(hist, maxBytes, now)
  maxBytes = maxBytes or Spec.MAX_BYTES
  local size = Spec.EstimateSize(hist)
  local today = Spec.DayIndex(now)
  if size <= maxBytes or type(hist) ~= "table" or type(hist.markets) ~= "table" or not today then return 0, size end
  local steps = {
    function(item) item.p = Spec.EncodePoints(Spec.PrunePoints(Spec.DecodePoints(item.p), now, 7 * 86400)) end,
    function(item) item.p = "" end,
    function(item) item.d = Spec.EncodeDays(Spec.PruneDays(Spec.DecodeDays(item.d), today, 90)) end,
    function(item) item.d = Spec.EncodeDays(Spec.PruneDays(Spec.DecodeDays(item.d), today, 60)) end,
    function(item) item.d = Spec.EncodeDays(Spec.PruneDays(Spec.DecodeDays(item.d), today, 30)) end,
  }
  for step, apply in ipairs(steps) do
    for _, market in pairs(hist.markets) do
      if type(market) == "table" and type(market.items) == "table" then
        for _, item in pairs(market.items) do if type(item) == "table" then apply(item) end end
      end
    end
    size = Spec.EstimateSize(hist)
    if size <= maxBytes then return step, size end
  end
  return #steps, size
end

return Spec

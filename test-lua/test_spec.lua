-- Pruebas de Especular v1 (Spec.lua, lógica pura). Desde la raíz del repositorio:
--   lua5.1 test-lua/test_spec.lua
-- Recorre test-vectors/especular-v1.json (el contrato compartido con src/especular.mjs del panel web) con igualdad
-- exacta de enteros y textos, y añade pruebas propias del formato de OroHermandadHist.
package.path = "test-lua/?.lua;" .. package.path
local json = require("json")
local DIR = "addon/OroHermandad/"
local ns = {}
local Spec = assert(loadfile(DIR .. "Spec.lua"))("OroHermandad", ns)
local Texts = Spec.Texts

local passed, failed, skipped = 0, 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; print("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

---------------------------------------------------------------------------
-- Vectores compartidos
---------------------------------------------------------------------------
local file = assert(io.open("test-vectors/especular-v1.json", "rb"))
local vectors = json.decode(file:read("*a"))
file:close()

local function nn(x) if x == json.null then return nil end return x end

-- input.days del vector -> {[d] = {{lo, hi, qty, id, src}, ...}} (solo claves enteras canónicas, como en JS).
local function vectorDays(obj)
  local byDay = {}
  for key, records in pairs(obj) do
    if key:match("^%d+$") and (key == "0" or key:sub(1, 1) ~= "0") then
      local list = {}
      for _, r in ipairs(records) do
        list[#list + 1] = {lo = nn(r[1]), hi = nn(r[2]), qty = nn(r[3]), id = nn(r[4]), src = nn(r[5])}
      end
      byDay[tonumber(key)] = list
    end
  end
  return byDay
end

local function evaluate(input)
  local days = Spec.BuildDays(vectorDays(input.days))
  local b = Spec.Baseline(days, input.T, {cloud = nn(input.cloud) == true})
  local a = Spec.Assess(b, nn(input.p), input.T)
  local flip
  if a.verdict == "CHOLLO" or nn(input.calc) == true then
    flip = Spec.Flip(b, nn(input.book), {cutBp = nn(input.cutBp), u = nn(input.u), D = nn(input.D), vendor = nn(input.vendor),
      F = nn(input.F), budget = nn(input.budget), Q = nn(input.Q), p = nn(input.p), q5 = nn(input.q5)})
  end
  local deltas = Spec.Deltas(days, input.T)
  local out = {flip = flip, d1 = deltas.d1, d7 = deltas.d7, values = days,
               texts = {conf = Texts.Conf(b), status = Texts.Status(a, b)}}
  for _, k in ipairs({"status", "n", "k", "N", "MAD", "sBp", "R3", "O7", "trend", "trendBp", "fresh", "conf", "Rs", "Q"}) do out[k] = b[k] end
  for _, k in ipairs({"verdict", "guard", "wait", "dBp", "band", "dumpLine", "spikeLine", "shiftLine"}) do out[k] = a[k] end
  return out
end

-- Compara todas las claves de expected (null = nil) con igualdad exacta; devuelve la lista de diferencias.
local function compare(expected, actual, path, diffs)
  if expected == json.null then
    if actual ~= nil then diffs[#diffs + 1] = path .. ": esperado null, obtenido " .. tostring(actual) end
  elseif type(expected) == "table" then
    if type(actual) ~= "table" then diffs[#diffs + 1] = path .. ": esperado una tabla, obtenido " .. tostring(actual); return diffs end
    for key, value in pairs(expected) do
      local actualValue = actual[key]
      if actualValue == nil and tonumber(key) then actualValue = actual[tonumber(key)] end
      compare(value, actualValue, path .. "." .. key, diffs)
    end
  elseif expected ~= actual then
    diffs[#diffs + 1] = path .. ": esperado " .. tostring(expected) .. ", obtenido " .. tostring(actual)
  end
  return diffs
end

eq(vectors.contract, Spec.VERSION, "versión del contrato")
eq(vectors.constants.DAY0, Spec.DAY0); eq(vectors.constants.LAUNCH, Spec.LAUNCH); eq(vectors.constants.GUARD_DAYS, Spec.GUARD_DAYS)
eq(vectors.constants.PRICE_MAX, Spec.PRICE_MAX); eq(vectors.constants.QTY_MAX, Spec.QTY_MAX); eq(vectors.constants.UNITS_MAX, Spec.UNITS_MAX)
eq(vectors.constants.SBP_FLOOR, Spec.SBP_FLOOR); eq(vectors.constants.CUT_BP_DEFAULT, Spec.CUT_BP)
eq(vectors.constants.BUDGET_DEFAULT, Spec.BUDGET); eq(vectors.constants.MIN_PROFIT, Spec.MIN_PROFIT)
eq(vectors.constants.MIN_MARGIN_PCT, Spec.MIN_MARGIN_PCT); eq(vectors.constants.CAP_LIQ_DEFAULT, Spec.CAP_LIQ_DEFAULT)
eq(vectors.texts.caveat, Texts.CAVEAT); eq(vectors.texts["status.PROTECCION"], Texts.GUARD)

local vectorCount = 0
for _, case in ipairs(vectors.cases) do
  if nn(case.js_only) == true then
    skipped = skipped + 1
  else
    vectorCount = vectorCount + 1
    test("vector " .. case.name, function()
      local diffs = compare(case.expect, evaluate(case.input), case.name, {})
      if #diffs > 0 then error(table.concat(diffs, "\n  "), 0) end
    end)
  end
end
assert(vectorCount >= 25, "faltan vectores: " .. vectorCount)

test("Vectores: índice de día", function()
  for _, pair in ipairs(vectors.dayIndex) do eq(Spec.DayIndex(pair[1]), pair[2], "t = " .. pair[1]) end
end)

test("Vectores: el ejemplo trabajado da los números del método", function()
  local worked
  for _, case in ipairs(vectors.cases) do if case.name == "ejemplo-trabajado" then worked = case end end
  local r = evaluate(worked.input)
  eq(r.N, 10000); eq(r.MAD, 100); eq(r.sBp, 300); eq(r.dumpLine, 8000); eq(r.spikeLine, 12500); eq(r.Rs, 10000)
  eq(r.flip.netUnit, 9499); eq(r.flip.maxBuy, 8216); eq(r.flip.units, 82); eq(r.flip.cost, 500000)
  eq(r.flip.profit, 274818); eq(r.flip.breakEven, 6473); eq(r.flip.accept, true)
  worked.input.cutBp = 1500
  eq(evaluate(worked.input).flip.maxBuy, 7346)
end)

---------------------------------------------------------------------------
-- Pureza: sin API de WoW ni globales
---------------------------------------------------------------------------
test("Spec.lua carga sin WoW: solo la biblioteca estándar y sin escribir globales", function()
  local allowed = {math = math, string = string, table = table, ipairs = ipairs, pairs = pairs, type = type,
                   tonumber = tonumber, tostring = tostring, setmetatable = setmetatable, error = error}
  local env = setmetatable({}, {
    __index = function(_, k) if allowed[k] == nil then error("usa el global " .. tostring(k), 2) end return allowed[k] end,
    __newindex = function(_, k) error("escribe el global " .. tostring(k), 2) end,
  })
  local chunk = assert(loadfile(DIR .. "Spec.lua"))
  setfenv(chunk, env)
  local box = {}
  local S = chunk("OroHermandad", box)
  assert(box.Spec == S and S.Baseline and S.Flip)
  -- Todo funciona dentro de la caja: una vuelta completa.
  local recs = {}
  for d = 2506, 2519 do recs = S.RecordScan(recs, d, 10000, 400) end
  local b = S.Baseline(S.DaysFromRecords(S.DecodeDays(S.EncodeDays(recs))), 2520)
  local f = S.Flip(b, {{6000, 100}}, {D = 50})
  assert(f.accept and S.Texts.Flip(f) and S.EstimateSize({markets = {}}) > 0)
end)

---------------------------------------------------------------------------
-- Días y formato del historial
---------------------------------------------------------------------------
test("DayIndex: día 0, lanzamiento, fin de la protección; nil si no es un número", function()
  eq(Spec.DayIndex(Spec.DAY0), 0); eq(Spec.DayIndex(1793746800), 2499); eq(Spec.DayIndex(1793746800 - 1), 2498)
  eq(Spec.DayIndex(1793746800 + 14 * 86400), 2513)
  eq(Spec.DayIndex(nil), nil); eq(Spec.DayIndex("1793746800"), nil); eq(Spec.DayIndex(0 / 0), nil); eq(Spec.DayIndex(1.5), nil)
  eq(Spec.WeekdayOf(2499), 2, "miércoles"); eq(Spec.WeekdayOf(2504), 0, "lunes 9-nov"); eq(Spec.WeekdayOf(2510), 6, "domingo 15-nov")
end)

test("Días: codificar y decodificar es estable y ordena", function()
  local text = "2501,900,1100,1000,50,3,o;2499,1000,1200,1100,40,2,o;2500,800,800,800,0,0,a"
  local days = Spec.DecodeDays(text)
  eq(#days, 3); eq(days[1].d, 2499); eq(days[3].d, 2501); eq(days[2].src, "a"); eq(days[2].qty, 0)
  local encoded = Spec.EncodeDays(days)
  eq(encoded, "2499,1000,1200,1100,40,2,o;2500,800,800,800,0,0,a;2501,900,1100,1000,50,3,o")
  eq(Spec.EncodeDays(Spec.DecodeDays(encoded)), encoded)
  eq(Spec.EncodeDays({}), ""); eq(#Spec.DecodeDays(""), 0)
end)

test("Días: texto corrupto se salta registro a registro, sin errores", function()
  local corrupt = table.concat({
    "abc", "2499,1000,1200,1100,40,2,o", ";;", "2500,-5,1200,1100,40,2,o", "2501,1000,900,950,40,2,o",
    "2502,1000,1200,1100,40,2,x", "2503,1e3,1200,1100,40,2,o", "2504,1000.5,1200,1100,40,2,o", "2505,1000,1200,1100,,2,o",
    "2506,1000,1200,1100,40,2", "2507,1000,1200,1100,40,2,o,futuro", " 2508,1000,1200,1100,40,2,o",
    "2509,0,1200,1100,40,2,o", "2510,1000,1000000001,1100,40,2,o", "2511,1000,1200,1100,1000001,2,o",
    "99999999999999,1,1,1,0,0,o", "2512,1000,1200,1100,40,2,o",
  }, ";")
  local days = Spec.DecodeDays(corrupt)
  local got = {}
  for i, d in ipairs(days) do got[i] = d.d end
  eq(table.concat(got, " "), "2499 2507 2512", "solo los registros bien formados (2507 con un campo de más)")
  for _, bad in ipairs({nil, 42, {}, true, "", ";", ",,,,,,", string.rep("9", 5000)}) do
    eq(#Spec.DecodeDays(bad), 0); eq(#Spec.DecodePoints(bad), 0)
  end
  eq(next(Spec.DecodeDeposits(nil)), nil)
end)

test("Días: un día repetido en el texto se junta con MergeDay; como mucho 120 días", function()
  local days = Spec.DecodeDays("2500,1000,1100,1050,30,2,o;2500,900,1000,950,50,5,o;2500,1,1,1,1,0,a")
  eq(#days, 1); eq(days[1].lo, 900); eq(days[1].hi, 1100); eq(days[1].last, 950); eq(days[1].qty, 50); eq(days[1].scans, 5)
  local many = {}
  for d = 1, 130 do many[d] = {d = 2400 + d, lo = 100, hi = 100, last = 100, qty = 1, scans = 1, src = "o"} end
  local kept = Spec.DecodeDays(Spec.EncodeDays(many))
  eq(#kept, 120); eq(kept[1].d, 2411); eq(kept[120].d, 2530)
end)

-- Generador determinista para las pruebas de propiedades.
local seed = 12345
local function rand(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
local function randomDay(d)
  local lo = 1 + rand(5000)
  return {d = d or 2500, lo = lo, hi = lo + rand(3000), last = lo + rand(3000), qty = rand(50), scans = rand(4),
          src = rand(3) == 0 and "a" or "o"}
end
local function same(a, b)
  return a.d == b.d and a.lo == b.lo and a.hi == b.hi and a.last == b.last and a.qty == b.qty and a.scans == b.scans and a.src == b.src
end

test("MergeDay: idempotente, conmutativa y asociativa; lo propio gana a lo importado", function()
  for _ = 1, 500 do
    local a, b, c = randomDay(), randomDay(), randomDay()
    assert(same(Spec.MergeDay(a, a), a), "idempotente")
    assert(same(Spec.MergeDay(a, b), Spec.MergeDay(b, a)), "conmutativa")
    assert(same(Spec.MergeDay(Spec.MergeDay(a, b), c), Spec.MergeDay(a, Spec.MergeDay(b, c))), "asociativa")
  end
  local own = {d = 2500, lo = 9000, hi = 9000, last = 9000, qty = 10, scans = 1, src = "o"}
  local imported = {d = 2500, lo = 1, hi = 50000, last = 1, qty = 999, scans = 0, src = "a"}
  assert(same(Spec.MergeDay(own, imported), own) and same(Spec.MergeDay(imported, own), own))
  eq(Spec.MergeDay(own, {d = 2501, lo = 1, hi = 1, last = 1, qty = 0, scans = 0, src = "o"}), nil, "días distintos")
  assert(same(Spec.MergeDay(nil, own), own) and Spec.MergeDay(own, nil) ~= own, "devuelve copias")
end)

test("RecordScan: escaneos del día se acumulan; un escaneo propio sustituye al día importado", function()
  local recs = Spec.RecordScan({}, 2500, 3000, 500)
  recs = Spec.RecordScan(recs, 2500, 2500, 800)
  recs = Spec.RecordScan(recs, 2500, 2800, 600)
  recs = Spec.RecordScan(recs, 2501, 2900)
  eq(#recs, 2)
  eq(Spec.EncodeDays(recs), "2500,2500,3000,2800,800,3,o;2501,2900,2900,2900,0,1,o")
  local imported = Spec.ImportAuctionator({}, {{rawDay = "2502", minSeen = 1000, maxSeen = 1200, available = 7}}, 2502)
  recs = Spec.RecordScan(imported, 2502, 1500, 3)
  eq(Spec.EncodeDays(recs), "2502,1500,1500,1500,3,1,o")
  local same, written = Spec.RecordScan(recs, 2502, 0, 3)
  eq(written, false); eq(Spec.EncodeDays(same), "2502,1500,1500,1500,3,1,o")
end)

test("ImportAuctionator: día como texto, solo huecos, nunca pisa lo propio; filas malas fuera", function()
  local recs = Spec.RecordScan({}, 2510, 1000, 50)
  local rows = {
    {rawDay = "2510", minSeen = 1, maxSeen = 1, available = 1},          -- ya es propio
    {rawDay = "2509", minSeen = 900, maxSeen = 1100, available = 70},
    {rawDay = 2508, minSeen = 950},                                      -- sin máximo
    {rawDay = 2507, maxSeen = 990},                                      -- solo h (Auctionator no guarda l)
    {rawDay = 2506, minSeen = 1200, maxSeen = 1000},                     -- al revés: se ordena
    {rawDay = "x", minSeen = 5}, {rawDay = 2505, minSeen = -3}, {rawDay = 2504, minSeen = 10.5},
    {rawDay = 2511, minSeen = 1000},                                     -- futuro
    {rawDay = 2510 - 120, minSeen = 1000},                               -- demasiado viejo
    "basura", {rawDay = 2503, minSeen = 1000, available = -1},
  }
  local out, added = Spec.ImportAuctionator(recs, rows, 2510)
  eq(added, 5)
  eq(Spec.EncodeDays(out), "2503,1000,1000,1000,0,0,a;2506,1000,1200,1000,0,0,a;2507,990,990,990,0,0,a;" ..
    "2508,950,950,950,0,0,a;2509,900,1100,900,70,0,a;2510,1000,1000,1000,50,1,o")
  local again, none = Spec.ImportAuctionator(out, rows, 2510)
  eq(none, 0, "importar dos veces no añade nada"); eq(Spec.EncodeDays(again), Spec.EncodeDays(out))
  eq(select(2, Spec.ImportAuctionator(nil, nil, 2510)), 0)
end)

test("Poda de días: 120 días hacia atrás y nada del futuro", function()
  local recs = {}
  for d = 2380, 2502 do recs[#recs + 1] = {d = d, lo = 5, hi = 5, last = 5, qty = 0, scans = 1, src = "o"} end
  -- Hoy 2500: entran 2381..2501 (ayer de más por relojes desajustados), y el tope de 120 deja fuera el 2381.
  local kept = Spec.PruneDays(recs, 2500)
  eq(kept[1].d, 2382); eq(kept[#kept].d, 2501); eq(#kept, 120)
  eq(#Spec.PruneDays(recs, 2500, 30), 31)
  local future = {}
  for d = 2400, 2600 do future[#future + 1] = {d = d, lo = 5, hi = 5, last = 5, qty = 0, scans = 1, src = "o"} end
  local trimmed = Spec.PruneDays(future, 2500)
  eq(trimmed[#trimmed].d, 2501, "los días futuros no ocupan sitio"); eq(trimmed[1].d, 2400); eq(#trimmed, 102)
end)

test("Puntos: a menos de 30 min se juntan, como mucho 120, 14 días; idempotente", function()
  local t0 = 1793746800
  local points = {}
  points = Spec.AddPoint(points, t0, 1000, 50, 10)
  points = Spec.AddPoint(points, t0 + 600, 900, 40, 4)     -- se junta: mínimo 900 con su qty5
  points = Spec.AddPoint(points, t0 + 1799, 900, 70, 8)    -- se junta: mismo mínimo, qty5 mayor
  points = Spec.AddPoint(points, t0 + 1800, 1100, 20, 2)   -- 30 min justos: punto nuevo
  eq(Spec.EncodePoints(points), t0 .. ",900,70,8;" .. (t0 + 1800) .. ",1100,20,2")
  eq(Spec.EncodePoints(Spec.AddPoint(points, t0 + 600, 900, 40, 4)), Spec.EncodePoints(points), "repetir un punto no cambia nada")
  local text = Spec.EncodePoints(points)
  eq(Spec.EncodePoints(Spec.DecodePoints(text)), text)
  -- Orden indiferente: los mismos puntos en otro orden dan lo mismo.
  local shuffled = {{t = t0 + 1799, lo = 900, qty = 70, qty5 = 8}, {t = t0 + 1800, lo = 1100, qty = 20, qty5 = 2},
                    {t = t0, lo = 1000, qty = 50, qty5 = 10}, {t = t0 + 600, lo = 900, qty = 40, qty5 = 4}}
  eq(Spec.EncodePoints(shuffled), text)
  local many = {}
  for i = 1, 300 do many[i] = {t = t0 + i * 3600, lo = 100 + i, qty = 1, qty5 = 1} end
  local capped = Spec.NormalizePoints(many)
  eq(#capped, 120); eq(capped[1].lo, 281); eq(capped[120].lo, 400)
  local ahead = {}
  for i = 1, 300 do ahead[i] = {t = t0 + i * 3600, lo = 100 + i, qty = 1, qty5 = 1} end
  eq(Spec.PrunePoints(ahead, t0 + 100 * 3600)[120].t, t0 + 124 * 3600, "los puntos futuros (más de un día) no ocupan sitio")
  local recent = Spec.PrunePoints(many, t0 + 300 * 3600)
  eq(#recent, 120); eq(recent[1].t > t0 + 300 * 3600 - 14 * 86400, true)
  eq(#Spec.PrunePoints(many, t0 + 300 * 3600, 3600 * 10), 10)
  eq(#Spec.DecodePoints("1793746800,900,1,1;x;1793746800,0,1,1;-1,5,5,5;1793750000,5,5"), 1)
end)

test("Depósitos: 'dur:cobre' por duración", function()
  local dep = Spec.DecodeDeposits("1:60,2:120,3:240,4:x,0:5,9:1,2:130,bad")
  eq(dep[1], 60); eq(dep[2], 130); eq(dep[3], 240); eq(dep[4], nil); eq(dep[0], nil); eq(dep[9], 1)
  eq(Spec.EncodeDeposits(dep), "1:60,2:130,3:240,9:1")
  eq(Spec.EncodeDeposits({[2] = -1, [3] = 1.5}), "")
end)

test("Categorías del contrato", function()
  eq(#Spec.CATEGORIES, 14); eq(Spec.IsCategory("hierba"), true); eq(Spec.IsCategory("pocion"), true); eq(Spec.IsCategory("poción"), false)
end)

---------------------------------------------------------------------------
-- Valor del día, línea base, veredicto
---------------------------------------------------------------------------
test("DayValue: un observador, pares, atípicos con 3 o más, qty desconocida", function()
  local one = Spec.DayValue({{lo = 101, hi = 104, qty = 0}})
  eq(one.v, 102); eq(one.qty, nil); eq(one.obs, 1); eq(one.ids[1], "")
  local two = Spec.DayValue({{lo = 1000, hi = 1000, qty = 5, id = "A"}, {lo = 9000, hi = 9000, qty = 8, id = "B"}})
  eq(two.v, 5000, "con 2 no se descarta a nadie"); eq(two.qty, 6); eq(two.obs, 2)
  local three = Spec.DayValue({{lo = 1000, hi = 1000, id = 1}, {lo = 1100, hi = 1100, id = 2}, {lo = 9000, hi = 9000, id = 3}})
  eq(three.v, 1050); eq(three.obs, 2); eq(three.ids[2], "2")
  eq(Spec.DayValue({}), nil); eq(Spec.DayValue({{lo = 5, hi = 4}, {lo = 0, hi = 3}, "x"}), nil); eq(Spec.DayValue(nil), nil)
end)

test("Baseline y Assess no fallan con entradas vacías o raras", function()
  local b = Spec.Baseline(nil, 2520)
  eq(b.status, "SIN_DATOS"); eq(b.n, 0)
  eq(Spec.Baseline({}, "x").status, "SIN_DATOS")
  eq(Spec.Assess(nil, 5000, 2520).verdict, "SIN_DATOS")
  eq(Spec.Assess({n = 14, N = 10000}, 5000, 2520).verdict, "SIN_DATOS", "línea base incompleta")
  eq(Spec.Assess(b, 5000, 2500).guard, true); eq(Spec.Assess(b, 5000, 2513).guard, false)
  local days = {}
  for d = 2506, 2519 do days[d] = 10000 end
  local plain = Spec.Baseline(days, 2520)
  eq(plain.N, 10000); eq(plain.k, 1, "valores sueltos cuentan como un observador")
  eq(Spec.Assess(plain, 6000).verdict, "CHOLLO", "T sale de la línea base")
  eq(Spec.Assess(plain, 6000, 2520, {launch = 2510}).verdict, "PROTECCION")
end)

test("Flip: rangos, orden del libro, lotes enormes y presupuesto cero", function()
  local days = {}
  for d = 2506, 2519 do days[d] = {v = 10000, qty = 400, ids = {""}} end
  local b = Spec.Baseline(days, 2520)
  local ok = Spec.Flip(b, {{6200, 60}, {5800, 1}, {6000, 40}}, {D = 50, budget = 2000000})
  eq(ok.units, 82); eq(ok.cost, 500000); eq(ok.accept, true); eq(ok.Rs, 10000); eq(ok.F, 1)
  eq(Spec.Flip(b, {{price = 6000, qty = 40}}, {D = 50}).units, 40, "lotes con nombre")
  local t0 = os.clock()
  local big = Spec.Flip(b, {{6000, 1000000}}, {D = 50, budget = 100000000000, Q = 1000000})
  eq(big.units, 10000, "como mucho 10000 unidades"); assert(os.clock() - t0 < 0.05, "sin bucle por unidad")
  eq(Spec.Flip(b, {{6000, 40}}, {budget = 0, D = 0}).reason, "SIN_UNIDADES")
  for _, bad in ipairs({{cutBp = 10000}, {cutBp = -1}, {u = 0}, {D = -1}, {D = 1.5}, {F = 101}, {budget = -1},
                        {Q = 1000001}, {p = 0}, {q5 = -1}, {vendor = 1e10}}) do
    eq(Spec.Flip(b, {{6000, 40}}, bad).reason, "FUERA_DE_RANGO")
  end
  eq(Spec.Flip(b, {{0, 40}}).reason, "FUERA_DE_RANGO"); eq(Spec.Flip(b, {{6000, 1.5}}).reason, "FUERA_DE_RANGO")
  eq(Spec.Flip(b, "libro").reason, "FUERA_DE_RANGO"); eq(Spec.Flip(b, {"x"}).reason, "FUERA_DE_RANGO")
  eq(Spec.Flip(nil, {{6000, 40}}).reason, "SIN_BASE"); eq(Spec.Flip(Spec.Baseline({}, 2520), nil, {p = 6000}).reason, "SIN_BASE")
  local none = Spec.Flip(b, nil, {})
  eq(none.reason, "SIN_UNIDADES"); eq(none.bookEstimated, false)
  eq(Spec.Flip(b, {}, {p = 6000}).bookEstimated, false, "un libro vacío no se sustituye por el estimado")
end)

test("Deltas: Δ1d y Δ7d con mínimo de valores", function()
  local days = {}
  for d = 2507, 2513 do days[d] = 10000 end
  for d = 2514, 2520 do days[d] = 11000 end
  local dl = Spec.Deltas(days, 2520)
  eq(dl.d1, 0); eq(dl.d7, 1000)
  days[2507], days[2508], days[2509], days[2510] = nil, nil, nil, nil
  eq(Spec.Deltas(days, 2520).d7, nil, "3 valores antes: no basta")
  eq(Spec.Deltas(days, 2530).d1, nil); eq(Spec.Deltas(nil, 2520).d1, nil); eq(Spec.Deltas(days, nil).d7, nil)
end)

---------------------------------------------------------------------------
-- Textos
---------------------------------------------------------------------------
test("Textos: porcentajes con coma, plurales y miembros", function()
  eq(Texts.Pct(300), "3"); eq(Texts.Pct(1234), "12,3"); eq(Texts.Pct(1295), "13"); eq(Texts.Pct(-4000), "40"); eq(Texts.Pct(4), "0")
  eq(Texts.Pct(5), "0,1"); eq(Texts.SignedPct(-1417), "-14,2"); eq(Texts.SignedPct(95), "+1"); eq(Texts.SignedPct(-4), "0")
  eq(Texts.Days(1), "1 día"); eq(Texts.Days(2), "2 días"); eq(Texts.Learning(1), "Aprendiendo precios: 1 de 7 días")
  eq(Texts.Conf({n = 1, k = 1}), "Aprendiendo precios: 1 de 7 días")
  eq(Texts.Conf({n = 14, k = 1, conf = "ALTA", sBp = 300}), "Fiable · 14 días · variación ±3 %")
  eq(Texts.Conf({n = 14, k = 2, conf = "ALTA", sBp = 1234}), "Fiable · 14 días · variación ±12,3 % · 2 miembros")
  eq(Texts.Conf({n = 10, k = 1, conf = "MEDIA", sBp = 2500}), "Orientativo · 10 días · variación ±25 %")
  eq(Texts.Conf({n = 9, k = 1, conf = "BAJA", sBp = 300}), "Poco fiable: pocos datos o precio muy variable")
  eq(Texts.Status(nil, nil), "Aprendiendo precios: 0 de 7 días")
  assert(has(Texts.CAVEAT, "no es una venta confirmada"))
end)

test("Textos de la compra: dinero del addon, depósitos en plural, estimados y rechazos", function()
  local days = {}
  for d = 2506, 2519 do days[d] = {v = 10000, qty = 400, ids = {""}} end
  local b = Spec.Baseline(days, 2520)
  local text = Texts.Flip(Spec.Flip(b, {{5800, 1}, {6000, 40}, {6200, 60}}, {D = 50, budget = 2000000}))
  eq(text, "Compra 82× a 82p 16c como máximo; no revendas por debajo de 64p 73c; objetivo 1o; ganancia ≈ 27o 48p tras la comisión y un depósito perdido")
  assert(has(Texts.Flip(Spec.Flip(b, {{6000, 40}}, {D = 50, F = 2, budget = 2000000})), "y 2 depósitos perdidos"))
  local zero = Texts.Flip(Spec.Flip(b, {{6000, 40}}, {D = 50, F = 0, budget = 2000000}))
  assert(has(zero, "tras la comisión") and not has(zero, "depósito"), zero)
  local guessed = Texts.Flip(Spec.Flip(b, nil, {p = 6000, q5 = 40, vendor = 100, budget = 2000000}))
  assert(has(guessed, "(depósito estimado) · estimado: confirma en la subasta"), guessed)
  eq(Texts.Flip(Spec.Flip(b, {{6000, 1}}, {D = 50})), "No compensa: ganarías solo 34p 49c (menos de 1 oro)")
  eq(Texts.Flip(Spec.Flip(b, {{6000, 40}}, {D = 2500})), "No compensa: ganarías 3o 99p, menos del 15 % de lo invertido")
  eq(Texts.Flip(Spec.Flip(b, {{9000, 40}}, {D = 50})), "No compensa: no hay nada a la venta por debajo de 82p 16c")
  eq(Texts.Flip(Spec.Flip(b, {{6000, 40}}, {D = 9500})), "No compensa: la comisión y el depósito se comen el margen")
  eq(Texts.Flip(Spec.Flip(b, {{0, 1}})), "Datos fuera de rango: no se calcula la compra")
  eq(Texts.Flip(nil), "Sin precio normal: no se calcula la compra")
  assert(has(Texts.Flip(Spec.Flip(b, {{6000, 40}}, {D = 50}), function(c) return c .. "c" end), "Compra 40× a 8216c como máximo"))
end)

---------------------------------------------------------------------------
-- Tamaño de OroHermandadHist
---------------------------------------------------------------------------
-- Serializador al estilo de los SavedVariables de WoW (tabuladores, ["clave"] = , y "-- [n]" en los arrays).
local function wowSerialize(value, indent)
  indent = indent or ""
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  local inner, out = indent .. "\t", {"{"}
  local n = #value
  for i = 1, n do out[#out + 1] = inner .. wowSerialize(value[i], inner) .. ", -- [" .. i .. "]" end
  local keys = {}
  for k in pairs(value) do if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local key = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
    out[#out + 1] = inner .. key .. " = " .. wowSerialize(value[k], inner) .. ","
  end
  out[#out + 1] = indent .. "}"
  return table.concat(out, "\n")
end

-- Historial de 80 objetos con 120 días y `pointsPerDay` escaneos al día durante 14 días, con precios realistas.
local function fullHist(pointsPerDay)
  local now = 1793746800 + 130 * 86400
  local today = Spec.DayIndex(now)
  local items = {}
  for i = 1, 80 do
    local id = 2770 + i * 97
    local recs, points = {}, {}
    for d = today - 119, today do
      local p = 25000 + (id * 37 + d * 101) % 125000
      recs[#recs + 1] = {d = d, lo = p, hi = p + (d * 13) % 9000, last = p + 400, qty = 100 + (id + d) % 4000, scans = 1 + d % 5, src = d % 9 == 0 and "a" or "o"}
    end
    for k = 0, 14 * pointsPerDay - 1 do
      local t = now - k * math.floor(86400 / pointsPerDay)
      points[#points + 1] = {t = t, lo = 25000 + (id + k * 7) % 125000, qty = 100 + k % 3000, qty5 = 10 + k % 300}
    end
    items[id] = {n = "Objeto \"" .. i .. "\" de prueba", c = Spec.CATEGORIES[1 + i % 14], v = 125 + i,
                 d = Spec.EncodeDays(recs), p = Spec.EncodePoints(points)}
  end
  return {schema = 1, addon = "0.3.0", markets = {["Mirage Raceway-Alliance"] = {updated = now, cut = 500, items = items,
          dep = {[2771] = "1:60,2:120,3:240"}}}}, now
end

test("Tamaño: el estimador da exactamente el tamaño del formato de WoW", function()
  local hist = fullHist(4)
  eq(Spec.EstimateSize(hist), #("OroHermandadHist = " .. wowSerialize(hist) .. "\n"))
  local odd = {"a\nb", 'c"d', "e\\f", "g\rh", "\0", true, false, 12.5, {}, {{}}, [10] = "x", [-1] = 3, ["k\n"] = "v"}
  eq(Spec.EstimateSize(odd, "X"), #("X = " .. wowSerialize(odd) .. "\n"))
end)

test("Tamaño: 80 objetos x 120 días + 14 días de 4 escaneos caben en 512 KB; con 120 puntos, Shrink quita puntos primero", function()
  local hist, now = fullHist(4)
  local size = Spec.EstimateSize(hist)
  local step, after = Spec.Shrink(hist, Spec.MAX_BYTES, now)
  eq(step, 0); eq(after, size)
  local heavy = fullHist(10)
  local heavySize = Spec.EstimateSize(heavy)
  local heavyStep, heavyAfter = Spec.Shrink(heavy, Spec.MAX_BYTES, now)
  print(string.format("  tamaño: 4 escaneos/día %.0f KB · 120 puntos/objeto %.0f KB -> Shrink paso %d, %.0f KB",
    size / 1024, heavySize / 1024, heavyStep, heavyAfter / 1024))
  assert(size <= Spec.MAX_BYTES, size)
  assert(heavySize > Spec.MAX_BYTES and heavyStep >= 1 and heavyStep <= 2 and heavyAfter <= Spec.MAX_BYTES)
  local item = select(2, next(heavy.markets["Mirage Raceway-Alliance"].items))
  eq(#Spec.DecodeDays(item.d), 120, "los días no se tocan mientras basta con quitar puntos")
  -- Si ni sin puntos cabe, se acortan los días.
  local tiny = fullHist(1)
  local s, final = Spec.Shrink(tiny, 150 * 1024, now)
  assert(s >= 3 and final <= 150 * 1024, s .. " " .. final)
  eq(select(1, Spec.Shrink(nil, 10, now)), 0)
end)

test("PruneHist: poda días y puntos viejos y borra objetos vacíos", function()
  local now = 1793746800 + 200 * 86400
  local today = Spec.DayIndex(now)
  local hist = {schema = 1, markets = {M = {items = {
    [1] = {d = (today - 200) .. ",5,5,5,0,1,o;" .. today .. ",6,6,6,0,1,o", p = (now - 20 * 86400) .. ",5,1,1;" .. now .. ",6,1,1"},
    [2] = {d = (today - 300) .. ",5,5,5,0,1,o", p = ""},
    [3] = "basura",
  }}}}
  eq(Spec.PruneHist(hist, now), 2)
  local item = hist.markets.M.items[1]
  eq(item.d, today .. ",6,6,6,0,1,o"); eq(item.p, now .. ",6,1,1")
  eq(Spec.PruneHist(nil, now), 0); eq(Spec.PruneHist({markets = 5}, now), 0)
end)

print(string.format("especular: %d pruebas correctas, %d fallidas, %d vectores solo de JS saltados", passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)

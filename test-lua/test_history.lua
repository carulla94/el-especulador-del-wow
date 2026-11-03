-- Pruebas del historial de precios (History.lua y OroHermandadHist) en el cliente simulado de Forever.
-- Desde la raíz del repositorio: lua5.1 test-lua/test_history.lua
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
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
local function printed(sub) for _, line in ipairs(Stub.printed) do if has(line, sub) then return true end end return false end
local function slash(text) SlashCmdList.OROHERMANDAD(text); Stub.runTimers(10) end
local function link(id, name) return "|cffffffff|Hitem:" .. id .. "::::::::32:::::|h[" .. (name or "Cosa") .. "]|h|r" end

-- Serializa una tabla con las claves ordenadas: dos historiales iguales dan el mismo texto.
local function dump(value)
  if type(value) ~= "table" then return type(value) == "string" and string.format("%q", value) or tostring(value) end
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = "[" .. dump(k) .. "]=" .. dump(value[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end

-- Serializador al estilo de los SavedVariables de WoW (para medir el tamaño real).
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

-- Otra instancia de History.lua, con su propio estado (para probar la carga sin tocar la de la sesión).
local function freshHistory(ns)
  local H = {Data = ns.Data, Items = ns.Items, Spec = ns.Spec, Prices = ns.Prices, Scan = ns.Scan}
  assert(loadfile(DIR .. "History.lua"))("OroHermandad", H)
  return H.History
end

local ns = Stub.loadAddon(DIR)
local History, Spec, Data = ns.History, ns.Spec, ns.Data
local TODAY = Spec.DayIndex(Stub.now)
local function market() return OroHermandadHist.markets[KEY] end
local function days(id) local item = market().items[id]; return item and Spec.DecodeDays(item.d) or {} end
local function points(id) local item = market().items[id]; return item and Spec.DecodePoints(item.p) or {} end
local function dayOf(id, d) for _, r in ipairs(days(id)) do if r.d == d then return r end end end

-- Lo que el juego habría cargado del archivo: un jugador que ya usaba la 0.3.0, con datos viejos y basura.
Stub.items[19019] = {'Cosa; "rara"', 1, "", 7, 0, 1}  -- consumible, subclase poción
OroHermandadDB = {histSince = Stub.now - 86400, watchExtra = {[19019] = true, x = true}}
OroHermandadHist = {schema = 1, addon = "0.3.0", markets = {
  [KEY] = {updated = Stub.now - 3600, cut = 500, items = {
    [2772] = {n = "Hierro", c = "metal", v = 5,
              d = (TODAY - 200) .. ",5,5,5,0,1,o;basura;" .. (TODAY - 1) .. ",100,110,105,40,2,o;" .. (TODAY + 5) .. ",1,1,1,1,1,o;1,2",
              p = (Stub.now - 20 * 86400) .. ",5,1,1;" .. (Stub.now - 7200) .. ",100,40,10;x,y,z,w"},
    [2770] = {n = 5, c = "nada", v = -3, d = 42, p = {}},
    ["2771"] = {d = TODAY .. ",1,1,1,1,1,o"},
    [3858] = "basura",
  }, dep = {[2772] = "1:5,2:20,3:60,9:x", a = "1:1", [2770] = 7}},
  ["SinFaccion-"] = {items = {}},
  [5] = {},
  ["Otro-Horde"] = "basura",
}}
-- Historial de Auctionator que la importación de la entrada (a los 20 s) debe encontrar.
Stub.history["2770"] = {{date = "x", rawDay = tostring(TODAY - 2), minSeen = 30.4, maxSeen = 35, available = 100}}

Stub.fire("ADDON_LOADED", "OroHermandad")
Stub.fire("PLAYER_LOGIN")
Stub.fire("PLAYER_ENTERING_WORLD", true, false)
Stub.runTimers(30)

test("TOC: versión 0.3.0, OroHermandadHist guardado y Spec/History en su sitio", function()
  local files, sv, versionLine = {}, nil, nil
  for line in io.lines(DIR .. "OroHermandad.toc") do
    if line:match("%.lua$") then files[#files + 1] = line end
    sv = sv or line:match("^## SavedVariables: (.+)$")
    versionLine = versionLine or line:match("^## Version: (.+)$")
  end
  local pos = {}
  for i, f in ipairs(files) do pos[f] = i end
  eq(versionLine, "0.3.0", "versión"); eq(ns.Core.VERSION, "0.3.0", "Core.VERSION")
  eq(sv, "OroHermandadDB, OroHermandadHist", "SavedVariables de la cuenta")
  eq(pos["Spec.lua"], pos["Items.lua"] + 1, "Spec después de Items")
  eq(pos["History.lua"], pos["Prices.lua"] + 1, "History después de Prices")
  assert(pos["Core.lua"] == #files, "Core al final")
end)

test("Al cargar: poda, salta lo corrupto y deja solo mercados y objetos válidos", function()
  local h = OroHermandadHist
  eq(h.schema, 1); eq(h.addon, "0.3.0")
  local keys = {}
  for k in pairs(h.markets) do keys[#keys + 1] = tostring(k) end
  eq(table.concat(keys, ","), KEY, "solo el mercado válido")
  local m = market()
  eq(m.cut, 500); assert(m.updated, "updated")
  -- 2772: el día de hace 200 días, la basura y el del futuro fuera; el punto de hace 20 días, también.
  local own = dayOf(2772, TODAY - 1)
  assert(own and own.lo == 100 and own.hi == 110 and own.scans == 2 and own.src == "o", "día propio intacto")
  eq(#days(2772), 1 + (dayOf(2772, TODAY - 2) and 1 or 0), "sin días viejos ni futuros")
  eq(#points(2772), 1, "solo el punto reciente"); eq(points(2772)[1].qty5, 10)
  eq(m.items[2771], nil, "clave de texto fuera"); eq(m.items[3858], nil, "objeto que no es una tabla fuera")
  eq(m.dep[2772], "1:5,2:20,3:60", "depósitos limpios"); eq(m.dep.a, nil); eq(m.dep[2770], nil)
  assert(History.SurvivalText():find("^sí:"), "se cargó del archivo: " .. History.SurvivalText())
end)

test("Entrada: importa una vez al día del historial de Auctionator (texto, decimales, sin l)", function()
  local r = dayOf(2770, TODAY - 2)
  assert(r, "día importado")
  eq(r.src, "a"); eq(r.scans, 0); eq(r.lo, 30, "30,4 redondeado"); eq(r.hi, 35); eq(r.last, 30); eq(r.qty, 100)
  local item = market().items[2770]
  eq(item.c, "metal"); eq(item.n, "Mineral de cobre"); eq(item.v, 1, "precio de mercader")
  eq(OroHermandadDB.histImport[KEY], TODAY, "hecho hoy")
  eq(History.Import(), "done", "no se repite el mismo día")
end)

test("Lista vigilada: 80 fijos con categorías del contrato, la cesta dentro, extras válidos", function()
  local seenIDs, n = {}, 0
  for cat, ids in pairs(Data.WATCH) do
    assert(Spec.IsCategory(cat), "categoría " .. tostring(cat))
    assert(Data.CATEGORY_LABELS[cat], "etiqueta de " .. cat)
    for _, id in ipairs(ids) do
      assert(Spec.IsInt(id, 1, 300000), "ID " .. tostring(id))
      assert(not seenIDs[id], "repetido " .. id)
      seenIDs[id], n = true, n + 1
    end
  end
  eq(n, 80, "objetos fijos")
  for _, id in ipairs(Data.BASKET) do assert(seenIDs[id], "falta de la cesta " .. id) end
  eq(#Data.CATEGORY_ORDER, #Spec.CATEGORIES)
  for i, cat in ipairs(Spec.CATEGORIES) do eq(Data.CATEGORY_ORDER[i], cat, "orden") end
  local list = History.WatchList()
  eq(#list, 81, "80 fijos y un extra")
  eq(list[1].cat, "metal"); eq(list[81].id, 19019); eq(list[81].cat, "pocion", "categoría del extra por su clase")
  -- Un ID que el cliente no conoce no se vigila y el sondeo lo lista.
  Stub.unknownItems[15417] = true
  local H = freshHistory(ns)
  H.Load(nil, {db = {}, market = function() return KEY end})
  local ids = {}
  for _, w in ipairs(H.WatchList()) do ids[w.id] = true end
  Stub.unknownItems[15417] = nil
  assert(not ids[15417] and ids[2772], "sin el desconocido")
  eq(table.concat(H.Unknown(), ","), "15417")
end)

test("Escaneo completo (replicate): vela de hoy y punto; sin pujas ni subastas tuyas; qty5", function()
  local data = Stub.scanRows("full", nil, {
    {id = 2772, lots = {{20, 100}, {5, 104}, {10, 106}, {3, 90, "Javi"}, {7, 0}}},
    {id = 14047, lots = {{3, 1000 / 3}}},
    {id = 99999, lots = {{1, 5}}}, -- no vigilado
  })
  Stub.scanComplete("full", nil, data)
  Stub.runTimers(5)
  local r = dayOf(2772, TODAY)
  assert(r, "vela de hoy")
  eq(r.lo, 100, "las tuyas (90) no cuentan"); eq(r.hi, 100); eq(r.last, 100); eq(r.qty, 35); eq(r.scans, 1); eq(r.src, "o")
  local p = points(2772)
  eq(p[#p].t, Stub.now); eq(p[#p].lo, 100); eq(p[#p].qty, 35); eq(p[#p].qty5, 25, "20 + 5 hasta un 5 % por encima")
  local cloth = dayOf(14047, TODAY)
  assert(cloth and cloth.lo == 333 and cloth.qty == 3, "precio por unidad redondeado")
  eq(market().items[14047].c, "tela"); eq(market().items[14047].n, "Paño rúnico", "nombre de reserva mientras el cliente lo carga")
  eq(market().items[14047].v, 0, "precio de mercader aún desconocido")
  eq(market().items[99999], nil, "lo no vigilado no se guarda")
  eq(dayOf(2772, TODAY - 1).scans, 2, "el día de ayer no cambia")
end)

test("Escritura rápida: el mismo texto que decodificar, normalizar y codificar todo (4000 casos)", function()
  local seed = 12345
  local function rand(n) seed = (seed * 1103515245 + 12345) % 2147483648; return math.floor(seed / 65536) % n end
  local function pick(list) return list[1 + rand(#list)] end
  local fastDays, fastPoints = 0, 0
  for case = 1, 2000 do
    -- Días: texto canónico de 1 a 120 registros, y un escaneo de un día cercano al último (a veces anterior).
    local n, d0, recs = 1 + rand(120), 2400 + rand(50), {}
    for i = 1, n do
      local lo = 1 + rand(5000)
      recs[#recs + 1] = {d = d0 + i * (1 + rand(2)), lo = lo, hi = lo + rand(300), last = lo + rand(300), qty = rand(3) == 0 and 0 or rand(999),
                         scans = rand(4), src = rand(3) == 0 and "a" or "o"}
      recs[#recs].last = math.min(recs[#recs].last, recs[#recs].hi)
    end
    local text = Spec.EncodeDays(recs)
    local last = Spec.DecodeDays(text)
    last = last[#last]
    local d = last.d + pick({-2, -1, 0, 0, 1, 1, 2, 5})
    local p, qty = pick({1 + rand(6000), 1 + rand(6000), 0, 2.5}), pick({rand(2000), 0, nil, -1})
    History.FAST_WRITES = false
    local slow = History.RecordDayText(text, d, p, qty)
    History.FAST_WRITES = true
    local fast = History.RecordDayText(text, d, p, qty)
    eq(fast, slow, "días, caso " .. case)
    if d >= last.d then fastDays = fastDays + 1 end
    -- Puntos: texto canónico de 1 a 120 puntos y uno nuevo cerca del último (a veces antes, a veces en la misma media hora).
    local m, t0, pts = 1 + rand(120), 1790000000 + rand(100000), {}
    for i = 1, m do pts[#pts + 1] = {t = t0 + i * (1800 + rand(5000)), lo = 1 + rand(9000), qty = rand(500), qty5 = rand(50)} end
    local ptext = Spec.EncodePoints(pts)
    local lastPoint = Spec.DecodePoints(ptext)
    lastPoint = lastPoint[#lastPoint]
    local t = lastPoint.t + pick({-4000, -1, 0, 1, 900, 1799, 1800, 1801, 7200})
    local lo, pq, q5 = pick({1 + rand(9000), lastPoint.lo, 0}), pick({rand(500), nil}), pick({rand(50), nil, 3.5})
    History.FAST_WRITES = false
    local slowP = History.AddPointText(ptext, t, lo, pq, q5)
    History.FAST_WRITES = true
    eq(History.AddPointText(ptext, t, lo, pq, q5), slowP, "puntos, caso " .. case)
    if t >= lastPoint.t then fastPoints = fastPoints + 1 end
  end
  assert(fastDays > 1000 and fastPoints > 1000, "la mayoría por el camino rápido: " .. fastDays .. " " .. fastPoints)
  -- El camino rápido se basa en que, tras cargar, todos los textos son canónicos. Si la carga no los normalizó
  -- (sin hora, o la poda falló), todo va por el camino largo, que ordena y junta aunque el texto venga desordenado.
  local H = freshHistory(ns)
  eq(H.RecordDayText("2500,5,5,5,0,1,o;2499,7,7,7,0,1,o", 2500, 6, 1), "2499,7,7,7,0,1,o;2500,5,6,6,1,2,o")
  eq(H.AddPointText("100,5,1,0;50,7,1,0", 3000, 6, 1, 0), "50,5,1,0;3000,6,1,0", "a menos de 30 min: se juntan en el primero")
end)

test("Mismo escaneo otra vez: no cambia nada (misma tabla o copia idéntica)", function()
  local before = dump(OroHermandadHist)
  local data = Stub.scanRows("full", nil, {{id = 2772, lots = {{20, 100}, {5, 104}, {10, 106}}}, {id = 14047, lots = {{3, 1000 / 3}}}})
  -- La tabla del escaneo anterior no se puede volver a mandar (ya se vio); una copia idéntica sí.
  Stub.scanComplete("full", nil, data); Stub.runTimers(5)
  local afterCopy = dump(OroHermandadHist)
  Stub.scanComplete("full", nil, data); Stub.runTimers(5)
  eq(dump(OroHermandadHist), afterCopy, "la misma tabla dos veces")
  eq(afterCopy, before, "copia idéntica en menos de 30 min")
  assert(History.lastResult.duplicate, "marcado como repetido")
  -- 40 minutos después, con otro precio, sí cuenta.
  Stub.now = Stub.now + 2400
  Stub.scanComplete("full", nil, Stub.scanRows("full", nil, {{id = 2772, lots = {{4, 120}}}}))
  Stub.runTimers(5)
  local r = dayOf(2772, TODAY)
  eq(r.scans, 2); eq(r.lo, 100); eq(r.hi, 120); eq(r.last, 120); eq(r.qty, 35, "qty = máximo del día")
  eq(#points(2772), 3, "un punto más")
end)

test("Escaneo de resumen entero: vela y punto (qty5 desconocida); mascotas y cantidad 0 fuera", function()
  Stub.now = Stub.now + 2400
  local data = Stub.scanRows("summary", 1000, {
    {id = 2772, price = 95, qty = 80}, {id = 12365, price = 300, qty = 12},
    {id = 4306, price = 70, qty = 0}, {id = 3858, price = 400, qty = 9, pet = 39},
  })
  Stub.scanComplete("summary", nil, data)
  Stub.runTimers(5)
  local r = dayOf(2772, TODAY)
  eq(r.scans, 3); eq(r.lo, 95); eq(r.last, 95); eq(r.qty, 80)
  local p = points(12365)
  eq(p[#p].lo, 300); eq(p[#p].qty, 12); eq(p[#p].qty5, 0, "el resumen no da la cantidad cerca del mínimo")
  local silk = dayOf(4306, TODAY)
  assert(not silk or silk.lo ~= 70, "cantidad 0: no está a la venta")
  local mithril = dayOf(3858, TODAY)
  assert(not mithril or mithril.lo ~= 400, "fila de mascota fuera")
end)

test("Resumen parcial (una búsqueda que cortó el escaneo): puntos sí, la vela del día no", function()
  Stub.now = Stub.now + 2400
  local before = dump(dayOf(2772, TODAY))
  Stub.scanComplete("summary", nil, Stub.scanRows("summary", nil, {{id = 2772, price = 50, qty = 3}, {id = 13468, price = 90000, qty = 2}}))
  Stub.runTimers(5)
  eq(dump(dayOf(2772, TODAY)), before, "el día no cambia")
  local p = points(2772)
  eq(p[#p].lo, 50, "punto de la búsqueda"); eq(p[#p].t, Stub.now)
  eq(#days(13468), 0, "un objeto nuevo solo con puntos"); eq(#points(13468), 1)
  eq(History.lastResult.whole, false)
end)

test("Escaneo enorme (100 000 filas): por tandas con C_Timer, sin trabar el juego", function()
  Stub.now = Stub.now + 2400
  local listings = {}
  for i, id in ipairs(History.FixedIDs()) do listings[#listings + 1] = {id = id, lots = {{10, 1000 + i}, {5, 1020 + i}}} end
  local data = Stub.scanRows("full", 100000, listings)
  eq(#data, 100000)
  local after, maxTick, ticks = C_Timer.After, 0, 0
  C_Timer.After = function(delay, fn)
    after(delay, function() local t0 = os.clock(); fn(); ticks = ticks + 1; maxTick = math.max(maxTick, os.clock() - t0) end)
  end
  local t0 = os.clock()
  Stub.scanComplete("full", nil, data)
  eq(History.Pending(), 1, "en marcha, nada hecho todavía")
  Stub.runTimers(5)
  C_Timer.After = after
  local total = os.clock() - t0
  eq(History.Pending(), 0, "terminado")
  local r = History.lastResult
  eq(r.rows, 100000); eq(r.read, 100000); eq(r.items, 80)
  assert(r.ticks >= math.ceil(100000 / History.ROWS_PER_TICK), "lectura en tandas: " .. r.ticks)
  assert(ticks >= r.ticks + math.ceil(80 / History.ITEMS_PER_TICK), "escritura en tandas: " .. ticks)
  assert(maxTick < 0.1, "tanda más larga " .. maxTick)
  realPrint(string.format("  100 000 filas: %d tandas, la más larga %.1f ms, total %.0f ms", ticks, maxTick * 1000, total * 1000))
  eq(dayOf(13468, TODAY).lo, 1000 + 38, "loto negro (posición 38)")
  eq(points(2770)[#points(2770)].qty5, 15)
end)

test("Filas que no se entienden: sin error; si ninguna se entiende, el precio de Auctionator de hoy", function()
  Stub.now = Stub.now + 86400 -- otro día
  local today = Spec.DayIndex(Stub.now)
  local exploding = setmetatable({}, {__index = function() error("fila rota") end})
  local nan = 0 / 0
  local mixed = {
    5, "texto", exploding,
    {replicateInfo = {"x", 1, "3", 1, true, 1, "", 0, 0, 300, 0, nil, nil, "V", nil, 0, 2589, true}}, -- cantidad de texto
    {replicateInfo = {"x", 1, 3, 1, true, 1, "", 0, 0, nan, 0, nil, nil, "V", nil, 0, 2589, true}},  -- compra ya NaN
    {replicateInfo = {"x", 1, 3, 1, true, 1, "", 0, 0, 3e12, 0, nil, nil, "V", nil, 0, 2589, true}}, -- precio absurdo
    {itemKey = {itemID = 2589}, minPrice = -5, totalQuantity = 4},
    {itemKey = {itemID = 2589}, minPrice = 12, totalQuantity = 4},                                 -- la buena
  }
  Stub.scanComplete("full", nil, mixed)
  Stub.runTimers(5)
  eq(dayOf(2589, today).lo, 12, "la fila buena cuenta")
  -- Se entienden (forma conocida) la de NaN, la del precio absurdo y la buena; solo la buena tiene precio válido.
  assert(History.lastResult.errors == 1 and History.lastResult.read == 3, "la fila que lanza error se salta")
  -- Ninguna fila reconocible en un escaneo entero: lo que Auctionator vio hoy, con cantidad desconocida y sin punto.
  local pointsBefore = #points(2592)
  Stub.scanComplete("full", nil, {{foo = 1}, {bar = 2}})
  Stub.runTimers(5)
  local wool = dayOf(2592, today)
  assert(wool and wool.lo == Stub.prices[2592] and wool.qty == 0 and wool.scans == 1, "respaldo con el precio de Auctionator")
  eq(#points(2592), pointsBefore, "sin punto")
  assert(History.lastResult.fallback, "marcado")
  -- Un resumen sin filas legibles no es entero: no se usa el respaldo.
  Stub.ages[2592] = 0
  Stub.busFire("full_incremental_scan_complete")
  Stub.runTimers(5)
  eq(dayOf(2592, today).scans, 1, "nada más")
end)

test("Importación de Auctionator: solo rellena huecos, por tandas de 5, y sobrevive a errores", function()
  local today = Spec.DayIndex(Stub.now)
  local ownBefore = dump(dayOf(2772, today - 2))
  Stub.history["2772"] = {
    {rawDay = tostring(today), minSeen = 1, maxSeen = 1},                    -- hoy ya es propio
    {rawDay = tostring(today - 2), minSeen = 1, maxSeen = 1},                -- ayer de la carga: propio
    {rawDay = tostring(today - 3), minSeen = 80.6, maxSeen = 90, available = 30},
    {rawDay = tostring(today - 4), maxSeen = 85},                            -- sin l: minSeen = h
    {rawDay = "basura", minSeen = 5, maxSeen = 5}, {rawDay = tostring(today - 5), minSeen = "x"}, "basura",
  }
  local after, tick, perTick = C_Timer.After, 0, {}
  C_Timer.After = function(delay, fn) after(delay, function() tick = tick + 1; fn() end) end
  Stub.onHistory = function() perTick[tick] = (perTick[tick] or 0) + 1 end
  eq(History.Import(true), "started")
  Stub.runTimers(10)
  C_Timer.After, Stub.onHistory = after, nil
  local most = 0
  for _, n in pairs(perTick) do most = math.max(most, n) end
  eq(most, History.IMPORT_PER_TICK, "como mucho 5 objetos por tanda")
  eq(dump(dayOf(2772, today - 2)), ownBefore, "lo propio no se pisa")
  eq(dayOf(2772, today).src, "o")
  local a3, a4 = dayOf(2772, today - 3), dayOf(2772, today - 4)
  assert(a3 and a3.src == "a" and a3.lo == 81 and a3.hi == 90 and a3.qty == 30 and a3.scans == 0, "día importado")
  assert(a4 and a4.lo == 85 and a4.hi == 85 and a4.qty == 0, "sin l ni available")
  eq(dayOf(2772, today - 5), nil, "fila mala fuera")
  local again = dump(OroHermandadHist)
  History.Import(true); Stub.runTimers(10)
  eq(dump(OroHermandadHist), again, "importar otra vez no cambia nada")
  Stub.historyError = true
  History.Import(true); Stub.runTimers(10)
  Stub.historyError = nil
  eq(dump(OroHermandadHist), again, "GetPriceHistory falla: nada roto")
end)

test("Depósitos: con la subasta abierta, 1 unidad por duración; lo que no es mercancía, otra visita", function()
  _G.AuctionHouseFrame = Stub.newObject("Frame", "AuctionHouseFrame")
  _G.AuctionHouseFrame:Hide()
  eq(History.LearnDeposits(), "closed")
  local calls = {}
  local calc = C_AuctionHouse.CalculateCommodityDeposit
  C_AuctionHouse.CalculateCommodityDeposit = function(id, dur, qty) calls[#calls + 1] = qty; return calc(id, dur, qty) end
  Stub.notCommodity[2840] = true
  _G.AuctionHouseFrame:Show()
  Stub.fire("AUCTION_HOUSE_SHOW")
  Stub.runTimers(10)
  local m = market()
  eq(m.dep[12365], "1:2,2:5,3:15", "piedra densa (se vende por 25c)")
  eq(m.dep[2770], "1:1,2:1,3:1")
  eq(m.dep[2840], nil, "no es mercancía")
  for _, qty in ipairs(calls) do eq(qty, 1, "cantidad 1") end
  eq(#calls, 81 * 3, "todos los vigilados, tres duraciones")
  calls = {}
  Stub.notCommodity[2840] = nil
  Stub.fire("AUCTION_HOUSE_CLOSED"); _G.AuctionHouseFrame:Show(); Stub.fire("AUCTION_HOUSE_SHOW")
  Stub.runTimers(10)
  eq(#calls, 3, "solo se vuelve a preguntar lo que faltaba"); eq(m.dep[2840], "1:1,2:1,3:2")
  C_AuctionHouse.CalculateCommodityDeposit = calc
end)

test("History.OnChange: avisa cuando termina de escribir (escaneo, importación, depósitos), no si no cambió nada", function()
  local H = freshHistory(ns)
  H.Load({schema = 1, markets = {}}, {db = {}, market = function() return KEY end})
  local calls, pendingAtCall = 0, {}
  H.OnChange(function() calls = calls + 1; pendingAtCall[calls] = H.Pending() end)
  -- Escaneo: el aviso llega al acabar de escribir (con varias tandas de lectura y escritura), no al empezar.
  local listings = {}
  for i, id in ipairs(H.FixedIDs()) do if i <= 12 then listings[#listings + 1] = {id = id, lots = {{10, 500 + i}}} end end
  local data = Stub.scanRows("full", 5000, listings)
  eq(H.Record("full", data, true), true)
  eq(calls, 0, "aún no se ha escrito nada")
  Stub.runTimers(5)
  eq(calls, 1, "un aviso al terminar"); eq(pendingAtCall[1], 0, "ya no queda nada pendiente")
  eq(H.lastResult.items, 12); assert(H.lastResult.ticks >= 3, "por tandas: " .. H.lastResult.ticks)
  -- La misma subasta otra vez (copia idéntica) no escribe nada: sin aviso. Un escaneo sin nada vigilado, tampoco.
  H.Record("full", Stub.scanRows("full", 5000, listings), true); Stub.runTimers(5)
  assert(H.lastResult.duplicate, "repetido"); eq(calls, 1, "repetido: sin aviso")
  H.Record("full", Stub.scanRows("full", 10, {{id = 99999, lots = {{1, 5}}}}), false); Stub.runTimers(5)
  eq(calls, 1, "nada vigilado: sin aviso")
  -- Importación del historial de Auctionator: aviso si trajo algún día; otra vez (ya los tiene), no.
  eq(H.Import(true), "started"); Stub.runTimers(10)
  assert(H.lastImport.days > 0, "días importados"); eq(calls, 2, "importación")
  H.Import(true); Stub.runTimers(10)
  eq(H.lastImport.days, 0); eq(calls, 2, "nada nuevo: sin aviso")
  -- Depósitos con la subasta abierta: aviso si aprendió alguno; la segunda vez ya no pregunta nada.
  _G.AuctionHouseFrame = _G.AuctionHouseFrame or Stub.newObject("Frame", "AuctionHouseFrame")
  _G.AuctionHouseFrame:Show()
  eq(H.LearnDeposits(), "started"); Stub.runTimers(10)
  assert(H.lastDeposits.learned > 0, "depósitos aprendidos"); eq(calls, 3, "depósitos")
  H.LearnDeposits(); Stub.runTimers(10)
  eq(H.lastDeposits.learned, 0); eq(calls, 3, "nada nuevo: sin aviso")
  -- Si quien escucha falla, el trabajo termina igual y el error queda en lastError.
  H.OnChange(function() error("ventana rota") end)
  H.Record("full", Stub.scanRows("full", 10, {{id = listings[1].id, lots = {{3, 900}}}}), true); Stub.runTimers(5)
  eq(H.Pending(), 0); assert(has(H.lastError, "ventana rota"), tostring(H.lastError))
  H.OnChange(nil)
  H.Record("full", Stub.scanRows("full", 10, {{id = listings[2].id, lots = {{3, 950}}}}), true); Stub.runTimers(5)
  eq(H.Pending(), 0, "sin nadie escuchando")
end)

test("/oro tabla: CSV con «;», coma decimal y los números de Especular", function()
  local T = Spec.DayIndex(Stub.now)
  local recs = {}
  for d = T - 14, T - 1 do recs[#recs + 1] = {d = d, lo = 10000, hi = 10000, last = 10000, qty = 200, scans = 1, src = "o"} end
  recs[#recs + 1] = {d = T, lo = 8000, hi = 8000, last = 8000, qty = 300, scans = 1, src = "o"}
  market().items[3860].d = Spec.EncodeDays(recs)
  market().items[19019] = {n = "", c = "pocion", v = 7, d = (T - 1) .. ",500,700,600,0,1,a", p = ""}
  Stub.printed = {}
  slash("tabla")
  local text = _G.OroHermandadTextFrame.edit:GetText()
  assert(_G.OroHermandadTextFrame:IsShown(), "ventana abierta")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  eq(lines[1], "item;categoría;hoy;normal 14 d;Δ1d;Δ7d;mín 14 d;máx 14 d;oferta;días;confianza", "cabecera")
  local row, extra
  for _, line in ipairs(lines) do
    if line:sub(1, 18) == "Lingote de mitril;" then row = line end
    if line:sub(1, 1) == '"' then extra = line end
  end
  eq(row, "Lingote de mitril;Metal;0,8000;1,0000;-20;0;1,0000;1,0000;300;14;Fiable · 14 días · variación ±3 %")
  eq(extra, '"Cosa; ""rara""";Poción;;;;;0,0500;0,0700;;1;Aprendiendo precios: 1 de 7 días', "comillas y punto y coma")
  for i = 2, #lines do
    local _, semicolons = lines[i]:gsub(";", "")
    if lines[i] ~= extra then eq(semicolons, 10, "11 columnas en " .. lines[i]) end
  end
  -- Con 120 días guardados, la tabla solo mira los últimos: el resultado es el mismo que con todo el texto.
  local long = {}
  for d = T - 119, T do long[#long + 1] = {d = d, lo = 500 + d % 7, hi = 520 + d % 5, last = 510, qty = d % 3, scans = 1, src = "o"} end
  local longText = Spec.EncodeDays(long)
  local recent = History.RecentRecords(longText)
  eq(#recent, 16); eq(recent[1].d, T - 15); eq(recent[16].d, T)
  local full, cut = Spec.DaysFromRecords(Spec.DecodeDays(longText)), Spec.DaysFromRecords(recent)
  eq(dump(Spec.Baseline(cut, T)), dump(Spec.Baseline(full, T)), "mismo precio normal")
  eq(dump(Spec.Deltas(cut, T)), dump(Spec.Deltas(full, T)), "mismos cambios")
  eq(#History.RecentRecords("2500,5,5,5,0,1,o"), 1); eq(#History.RecentRecords(nil), 0)
  local metal, piedra = text:find("Metal;", 1, true), text:find("Piedra;", 1, true)
  assert(metal and piedra and metal < piedra, "por categorías")
  assert(printed("tabla de ") and printed("objetos: cópiala"), "mensaje")
  -- Mercado sin datos (otra facción): lo dice y no abre la ventana.
  _G.OroHermandadTextFrame:Hide()
  local faction = _G.UnitFactionGroup
  _G.UnitFactionGroup = function() return "Horde" end
  Stub.printed = {}
  slash("tabla")
  _G.UnitFactionGroup = faction
  assert(printed("aún no hay precios guardados en este mercado"), "sin datos")
  assert(not _G.OroHermandadTextFrame:IsShown())
end)

test("/oro sondeo: todo lo que hay que comprobar en el juego, sin nombres de personajes ni oro", function()
  -- Un escaneo completo y uno de resumen normales en esta sesión: el sondeo enseña la forma de su primera fila.
  Stub.now = Stub.now + 2400
  Stub.scanComplete("full"); Stub.scanComplete("summary"); Stub.runTimers(5)
  Stub.printed = {}
  _G.AuctionHouseFrame:Show()
  Stub.history["2770"] = {{rawDay = tostring(Spec.DayIndex(Stub.now)), minSeen = 30.5, maxSeen = 31, available = 9}}
  slash("sondeo")
  local text = _G.OroHermandadTextFrame.edit:GetText()
  assert(_G.OroHermandadTextFrame.edit.__highlighted, "seleccionado para copiar")
  local chat = table.concat(Stub.printed, "\n")
  for _, want in ipairs({
    "Oro de Hermandad 0.3.0 · sondeo ", "cliente 1.60.1.70707 (interfaz 16001)",
    "Auctionator 11.0.9-forever · __dbversion 8", "escaneos oídos sí", "SCAN_DAY_0 de Auctionator: 1577833200 (igual",
    "Escaneo completo (", "replicateInfo: 1 texto, 2 número, 3 número", "[3] cantidad ", "[17] itemID ",
    "Escaneo de resumen (", "itemKey {battlePetSpeciesID=número, itemID=número",
    "GetPriceHistory(\"2770\") Mineral de cobre: 1 fila, la primera: rawDay = ", "(texto)", "hay precios con decimales",
    "Depósito de 1 unidad de Mineral de cobre (2770): duración 1: 1c · duración 2: 1c · duración 3: 1c",
    "Depósito de 1 unidad de Paño rúnico (14047)", "(13446)",
    "Duraciones: 1 = 12 horas · 2 = 24 horas · 3 = 48 horas", "SupportsCopperValues: sí",
    "Mercancía o pieza: Hierro mercancía", "Mercado: Forever-Alliance", "Lista vigilada: 80 de 80 fijos reconocidos, 1 extra",
    "KB de 512 KB como máximo", "¿OroHermandadHist sobrevivió al último /reload? sí:",
  }) do
    assert(has(text, want), "falta en la ventana: " .. want .. "\n" .. text)
    assert(has(chat, want), "falta en el chat: " .. want)
  end
  for _, banned in ipairs({"Javi", "Vendedor", "Luis", "Los Mineros", ns.Engine.Money(GetMoney())}) do
    assert(not has(text, banned), "no debe salir: " .. banned)
  end
  -- Con la subasta cerrada, lo dice en vez de calcular depósitos.
  _G.AuctionHouseFrame:Hide()
  slash("sondeo")
  assert(has(_G.OroHermandadTextFrame.edit:GetText(), "Depósitos: abre la subasta y repite /oro sondeo"), "subasta cerrada")
end)

test("/oro vigilar y /oro olvidar: enlaces, lista fija, máximo 40, desconocidos", function()
  Stub.printed = {}
  slash("vigilar")
  assert(printed("vigilas 1 objeto (máximo 40): Cosa"), "lista de extras")
  slash("vigilar " .. link(2772, "Hierro"))
  assert(printed("Hierro ya está en la lista fija"), "fijo")
  Stub.history["19020"] = {{rawDay = tostring(Spec.DayIndex(Stub.now) - 1), minSeen = 400, maxSeen = 450}}
  slash("vigilar " .. link(19020, "Espada"))
  assert(printed("vigilo también el objeto 19020: llevas 2 de 40 extras. Sus precios se guardan desde el próximo escaneo."), "añadido")
  eq(History.ExtraIDs()[2], 19020)
  local imported = Spec.DecodeDays(market().items[19020] and market().items[19020].d)
  assert(#imported == 1 and imported[1].src == "a", "sus días de Auctionator se importan al añadirlo")
  slash("vigilar 19020"); assert(printed("ya está entre tus objetos vigilados"), "repetido")
  Stub.unknownItems[250001] = true
  slash("vigilar 250001"); assert(printed("el juego no reconoce ese objeto"), "desconocido")
  slash("vigilar abc"); assert(printed("uso: /oro vigilar"), "uso")
  for id = 30001, 30038 do eq(History.Watch(id), "added") end
  eq(#History.ExtraIDs(), 40)
  Stub.printed = {}
  slash("vigilar 30039"); assert(printed("ya vigilas 40 objetos extra, el máximo"), "tope")
  -- olvidar
  Stub.printed = {}
  slash("olvidar " .. link(2772)); assert(printed("es de la lista fija: no se puede quitar"), "fijo")
  slash("olvidar 12345"); assert(printed("no está entre tus objetos extra"), "no vigilado")
  slash("olvidar " .. link(19020))
  assert(printed("he dejado de vigilar") and printed("borrado sus precios guardados"), "quitado")
  eq(market().items[19020], nil, "historial borrado")
  for id = 30001, 30038 do History.Unwatch(id) end
  eq(#History.ExtraIDs(), 1)
  slash("olvidar"); assert(printed("uso: /oro olvidar"), "uso")
  slash("ayuda")
  assert(printed("/oro tabla —") and printed("/oro vigilar [enlace]") and printed("/oro sondeo —"), "ayuda")
end)

test("Mercado sin facción válida: no se graba nada y el sondeo lo explica", function()
  local faction = _G.UnitFactionGroup
  _G.UnitFactionGroup = function() return "Neutral" end
  local before = dump(OroHermandadHist)
  Stub.scanComplete("full", nil, Stub.scanRows("full", nil, {{id = 2772, lots = {{1, 7}}}}))
  Stub.runTimers(5)
  slash("sondeo")
  _G.UnitFactionGroup = faction
  eq(dump(OroHermandadHist), before, "nada nuevo")
  assert(has(_G.OroHermandadTextFrame.edit:GetText(), "Mercado: Forever-Neutral (no válido"), "explicado")
  assert(History.ValidMarketKey("Mirage Raceway-Horde") and not History.ValidMarketKey("-Alliance")
    and not History.ValidMarketKey("A|B-Alliance") and not History.ValidMarketKey(("x"):rep(65) .. "-Horde"), "formato")
end)

test("Sin EventBus, el evento del cliente fecha el escaneo pero no graba precios (Auctionator aún no los procesó)", function()
  local before = dump(OroHermandadHist)
  local watching = ns.Prices.WatchingScans
  ns.Prices.WatchingScans = function() return false end
  Stub.fire("REPLICATE_ITEM_LIST_UPDATE")
  Stub.runTimers(5)
  ns.Prices.WatchingScans = watching
  eq(OroHermandadDB.fullScan[KEY], Stub.now, "fechado como antes")
  eq(dump(OroHermandadHist), before, "sin grabar")
end)

test("¿Sobrevivió al /reload?: los cuatro casos y un esquema más nuevo que no se toca", function()
  local H = freshHistory(ns)
  local function survival(saved, db, dbLoaded)
    H.Load(saved, {db = db, market = function() return KEY end, dbLoaded = dbLoaded})
    return H.SurvivalText()
  end
  assert(has(survival({schema = 1, markets = {}}, {histSince = 1}, true), "sí: OroHermandadHist se cargó"), "cargado")
  assert(has(survival(nil, {histSince = 1}, true), "NO: OroHermandadDB se cargó, pero OroHermandadHist no"), "solo falla Hist")
  assert(has(survival(nil, {}, true), "primera sesión con historial"), "primera vez con la 0.3.0")
  assert(has(survival(nil, {}, false), "no se cargó nada guardado (ni OroHermandadDB)"), "nada cargado")
  local future = {schema = 2, markets = {x = 1}}
  local db = {}
  eq(H.Load(future, {db = db, market = function() return KEY end}), future, "la misma tabla")
  eq(future.schema, 2); eq(future.markets.x, 1, "intacta")
  assert(has(H.SurvivalText(), "versión más nueva"), "lo explica")
  eq(H.Record("full", {}, true), false, "no graba")
  eq(H.Import(true), "off")
end)

test("Tamaño: 80 objetos x 120 días caben en 512 KB; con 40 extras y 120 puntos, se recorta al cargar y al salir", function()
  local now = Stub.now
  local today = Spec.DayIndex(now)
  local function build(ids, pointsPerDay, keepPoints)
    local items, dep = {}, {}
    for i, id in ipairs(ids) do
      local recs, pts = {}, {}
      for d = today - 119, today do
        local p = 25000 + (id * 37 + d * 101) % 125000
        recs[#recs + 1] = {d = d, lo = p, hi = p + (d * 13) % 9000, last = p + 400, qty = 100 + (id + d) % 4000,
                           scans = 1 + d % 5, src = d % 9 == 0 and "a" or "o"}
      end
      for k = 0, keepPoints - 1 do
        pts[#pts + 1] = {t = now - k * math.floor(86400 / pointsPerDay), lo = 25000 + (id + k * 7) % 125000,
                         qty = 100 + k % 3000, qty5 = 10 + k % 300}
      end
      items[id] = {n = "Objeto de la lista número " .. i, c = Spec.CATEGORIES[1 + i % 14], v = 125 + i,
                   d = Spec.EncodeDays(recs), p = Spec.EncodePoints(pts)}
      dep[id] = "1:" .. (60 + i) .. ",2:" .. (240 + i) .. ",3:" .. (720 + i)
    end
    return {schema = 1, addon = "0.3.0", markets = {[KEY] = {updated = now, cut = 500, items = items, dep = dep}}}
  end
  local fixed = History.FixedIDs()
  local hist = build(fixed, 4, 14 * 4)
  local raw = Spec.EstimateSize(hist)
  eq(raw, #("OroHermandadHist = " .. wowSerialize(hist) .. "\n"), "el estimador mide el formato de WoW")
  local H = freshHistory(ns)
  local loaded = H.Load(hist, {db = {}, market = function() return KEY end})
  local size = #("OroHermandadHist = " .. wowSerialize(loaded) .. "\n")
  eq(H.LoadInfo().shrinkStep, 0, "cabe sin recortar")
  assert(size <= Spec.MAX_BYTES, "80 x 120 días: " .. size)
  local item = loaded.markets[KEY].items[fixed[1]]
  eq(#Spec.DecodeDays(item.d), 120); eq(#Spec.DecodePoints(item.p), 56)
  -- 120 objetos con 120 puntos cada uno: se quitan puntos, no días.
  local all = {}
  for _, id in ipairs(fixed) do all[#all + 1] = id end
  for id = 40001, 40040 do all[#all + 1] = id end
  local heavy = build(all, 10, 120)
  local heavyRaw = Spec.EstimateSize(heavy)
  local loadedHeavy = H.Load(heavy, {db = {}, market = function() return KEY end})
  local heavySize = #("OroHermandadHist = " .. wowSerialize(loadedHeavy) .. "\n")
  local step = H.LoadInfo().shrinkStep
  assert(heavyRaw > Spec.MAX_BYTES and step >= 1 and step <= 2 and heavySize <= Spec.MAX_BYTES, heavyRaw .. " " .. step .. " " .. heavySize)
  eq(#Spec.DecodeDays(loadedHeavy.markets[KEY].items[40040].d), 120, "los días se quedan")
  realPrint(string.format("  tamaño: 80 x 120 días %.0f KB · 120 objetos y 120 puntos %.0f KB -> paso %d, %.0f KB",
    size / 1024, heavyRaw / 1024, step, heavySize / 1024))
  -- Al salir: si la sesión lo hizo crecer, se recorta antes de guardar.
  local session = build(all, 10, 120)
  H.Load({schema = 1, markets = {}}, {db = {}, market = function() return KEY end})
  local live = H.Hist()
  live.markets = session.markets
  local stepOut, sizeOut = H.BeforeSave()
  assert(stepOut >= 1 and sizeOut <= Spec.MAX_BYTES, "al salir " .. tostring(stepOut) .. " " .. tostring(sizeOut))
end)

test("PLAYER_LOGOUT deja el historial listo para guardar", function()
  OroHermandadHist.addon = "otra"
  Stub.fire("PLAYER_LOGOUT")
  eq(OroHermandadHist.addon, "0.3.0")
  assert(Spec.EstimateSize(OroHermandadHist) <= Spec.MAX_BYTES)
end)

test("Prices.WatchScans pasa las filas del escaneo como tercer argumento", function()
  local P = {Data = ns.Data, Items = ns.Items}
  assert(loadfile(DIR .. "Prices.lua"))("OroHermandad", P)
  local got = {}
  assert(P.Prices.WatchScans(function(kind, rows, data) got[#got + 1] = {kind, rows, data} end))
  local data = {{}, {}}
  Stub.busFire("replicate_scan_complete", data)
  Stub.busFire("full_incremental_scan_complete", "no es una tabla")
  eq(got[1][1], "full"); eq(got[1][2], 2); eq(got[1][3], data)
  eq(got[2][1], "summary"); eq(got[2][2], nil); eq(got[2][3], nil)
end)

test("Privacidad: OroHermandadHist no lleva personajes, hermandad, profesiones ni oro", function()
  local text = wowSerialize(OroHermandadHist)
  for _, banned in ipairs({"Javi", "Luis", "Vendedor", "Los Mineros", "mining", "blacksmithing", "profs", "recipes", "bank"}) do
    assert(not has(text, banned), "no debe salir: " .. banned)
  end
  for key in pairs(OroHermandadHist) do assert(key == "schema" or key == "addon" or key == "markets", "clave " .. key) end
  for _, m in pairs(OroHermandadHist.markets) do
    for key in pairs(m) do assert(({updated = 1, cut = 1, items = 1, dep = 1})[key], "clave de mercado " .. key) end
    for _, item in pairs(m.items) do
      for key in pairs(item) do assert(({n = 1, c = 1, v = 1, d = 1, p = 1})[key], "clave de objeto " .. key) end
    end
  end
end)

test("Ningún error durante toda la sesión", function()
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

realPrint(string.format("historial: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

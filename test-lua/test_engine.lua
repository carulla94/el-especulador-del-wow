-- Pruebas del motor de sugerencias (lógica pura). Desde la raíz del repositorio:
--   lua5.1 test-lua/test_engine.lua
local DIR = "addon/OroHermandad/"
local ns = {}
assert(loadfile(DIR .. "Data.lua"))("OroHermandad", ns)
assert(loadfile(DIR .. "Engine.lua"))("OroHermandad", ns)
local Engine, Data = ns.Engine, ns.Data

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; print("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end
local function find(list, pred) for _, x in ipairs(list or {}) do if pred(x) then return x end end end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
local function all(r) local out = {} for _, k in ipairs({"now", "farm", "group"}) do for _, x in ipairs(r.sections[k]) do out[#out + 1] = x end end return out end
local function kinds(r, kind) local n = 0 for _, x in ipairs(all(r)) do if x.kind == kind then n = n + 1 end end return n end

local NOW = 1800000000
local PRICES = {
  [2770] = 30, [2840] = 45,                  -- cobre: el lingote vale más
  [2772] = 120, [3575] = 100,                -- hierro: el mineral vale más
  [3858] = 400, [3860] = 600, [7912] = 150,  -- mitril
  [10620] = 900, [12359] = 1000, [12365] = 300,
  [2589] = 10, [2592] = 25, [4306] = 60, [4338] = 120, [14047] = 300,
  [2835] = 8, [2836] = 15, [2838] = 40, [2447] = 20, [785] = 40, [2453] = 60, [3356] = 90,
  [12404] = 2500, -- Piedra de afilar densa (producto de herrería de ejemplo)
}
local NAMES = {[2770] = "Mineral de cobre", [2840] = "Lingote de cobre", [2772] = "Hierro", [3575] = "Lingote de hierro",
  [3858] = "Mineral de mitril", [3860] = "Lingote de mitril", [12404] = "Piedra de afilar densa", [12365] = "Piedra densa",
  [2901] = "Pico de minero", [858] = "Poción", [4306] = "Paño de seda", [10620] = "Torio"}

local function ctx(over)
  local base = {
    mode = "lazy", now = NOW, hasPriceSource = true, ageKnown = true, dbUpdatedAt = NOW - 3600,
    price = function(id) return PRICES[id] end,
    age = function(id) if PRICES[id] then return 0, false end end,
    vendor = function() return 1 end,
    vendorBuy = function() return nil end,
    name = function(id) return NAMES[id] end,
    me = {name = "Javi", level = 30, profs = {mining = 180, blacksmithing = 150}},
    bags = {}, bank = {}, recipes = {}, guild = {},
  }
  for k, v in pairs(over or {}) do base[k] = v end
  return base
end

test("Money formatea oro, plata y cobre", function()
  eq(Engine.Money(12345), "1o 23p"); eq(Engine.Money(250), "2p 50c"); eq(Engine.Money(7), "7c"); eq(Engine.Money(-10000), "-1o")
end)

test("Profesiones por ID y por nombre (también los nombres esES de Classic)", function()
  eq(Data.ProfessionKeyByID(186), "mining"); eq(Data.ProfessionKeyByID(197), "tailoring")
  eq(Data.ProfessionKey("Botánica"), "herbalism"); eq(Data.ProfessionKey("Marroquinería"), "leatherworking")
  eq(Data.ProfessionKey("Costura"), "tailoring"); eq(Data.ProfessionKey("HERRERIA"), "blacksmithing")
  eq(Data.ProfessionKey("encantadora"), "enchanting"); eq(Data.ProfessionKey("nada"), nil)
end)

test("Nombres de reserva: esES por defecto y esMX si el cliente es mexicano", function()
  eq(Data.FALLBACK_NAMES[2840], "Lingote de cobre")
  Data.ApplyLocale("esMX"); eq(Data.FALLBACK_NAMES[2840], "Barra de cobre")
  Data.ApplyLocale("esES")
end)

test("Sin Auctionator: aviso rojo, nada con precio, pero sí la chatarra gris", function()
  local r = Engine.Suggest(ctx({hasPriceSource = false, bags = {[2770] = {count = 20, quality = 1}, [1000] = {count = 2, quality = 0, vendor = 50}}}))
  eq(r.db.level, "error"); eq(kinds(r, "sell"), 0); eq(kinds(r, "gray"), 1)
end)

test("Base vacía: error aunque haya una actualización reciente", function()
  local r = Engine.Suggest(ctx({price = function() return nil end, dbUpdatedAt = NOW - 60}))
  eq(r.db.level, "error"); assert(has(r.db.text, "escaneo completo"), r.db.text)
end)

test("Pocos precios de referencia: aviso de cobertura", function()
  local r = Engine.Suggest(ctx({price = function(id) if id == 2770 or id == 2589 then return 10 end end}))
  eq(r.db.level, "warn"); assert(has(r.db.text, "Solo hay precio de 2"), r.db.text)
end)

test("Antigüedad por modo; más de 48 h se muestra en días", function()
  eq(Engine.Suggest(ctx({dbUpdatedAt = NOW - 10 * 3600})).db.level, "ok")
  local farm = Engine.Suggest(ctx({mode = "farm", dbUpdatedAt = NOW - 10 * 3600}))
  eq(farm.db.level, "warn"); assert(has(farm.db.text, "10 h"), farm.db.text)
  local old = Engine.Suggest(ctx({dbUpdatedAt = NOW - 72 * 3600}))
  assert(has(old.db.text, "3 días"), old.db.text)
end)

test("Si el autoescaneo de Auctionator está apagado, lo dice", function()
  local r = Engine.Suggest(ctx({mode = "farm", autoscan = false, dbUpdatedAt = NOW - 10 * 3600}))
  assert(has(r.db.text, "escanear al abrir la subasta"), r.db.text)
end)

test("Escaneo parcial: avisa si casi toda la cesta es antigua", function()
  local r = Engine.Suggest(ctx({mode = "farm", age = function(id) if id == 2770 then return 0 end if PRICES[id] then return 4 end end}))
  eq(r.db.level, "warn"); assert(has(r.db.text, "%"), r.db.text)
end)

-- Cesta con precio solo para los primeros n materiales: los "hoy" se vieron hoy y el resto hace "old" días.
local function basket(n, todayCount, old)
  local priced, ages = {}, {}
  for i, id in ipairs(Data.BASKET) do
    if i <= n then priced[id] = 100; ages[id] = i <= todayCount and 0 or old end
  end
  return function(id) return priced[id] end, function(id) return ages[id] end
end

test("Servidor nuevo: tras un escaneo completo, la poca oferta no pide escanear otra vez", function()
  local price, age = basket(5, 5, 0)
  for _, mode in ipairs({"farm", "lazy"}) do
    local r = Engine.Suggest(ctx({mode = mode, price = price, age = age, dbUpdatedAt = NOW - 120, fullScanAt = NOW - 120}))
    eq(r.db.level, "ok", mode); assert(not has(r.db.text, "escaneo") and has(r.db.text, "poca oferta"), r.db.text)
    eq(#r.warnings, 0)
  end
  -- Semana 1: 12 vistos hoy y 10 de hace días (no están a la venta). Basta el escaneo reciente aunque no conste el completo.
  local price2, age2 = basket(22, 12, 4)
  local r = Engine.Suggest(ctx({mode = "farm", price = price2, age = age2, dbUpdatedAt = NOW - 120}))
  eq(r.db.level, "ok"); assert(not has(r.db.text, "escaneo"), r.db.text)
  -- Solo con el completo (sin dbUpdatedAt) también vale, y la antigüedad sale de él.
  local r2 = Engine.Suggest(ctx({mode = "farm", price = price2, age = age2, dbUpdatedAt = false, fullScanAt = NOW - 2 * 3600}))
  eq(r2.db.level, "ok"); assert(has(r2.db.text, "hace 2 h"), r2.db.text)
  -- Nada a la venta tras un escaneo completo: aviso, pero sin pedir otro escaneo.
  local r3 = Engine.Suggest(ctx({price = function() return nil end, fullScanAt = NOW - 60}))
  assert(r3.db.level ~= "ok" and not has(r3.db.text, "escaneo"), r3.db.text)
end)

test("Una o dos búsquedas sobre una base vieja siguen avisando", function()
  local price, age = basket(28, 2, 4)
  local r = Engine.Suggest(ctx({mode = "farm", price = price, age = age, dbUpdatedAt = NOW - 60, fullScanAt = NOW - 6 * 86400}))
  eq(r.db.level, "warn"); assert(has(r.db.text, "%") and has(r.db.text, "escaneo completo"), r.db.text)
  -- Base nueva con solo 3 búsquedas: avisa de la cobertura.
  local price2, age2 = basket(3, 3, 0)
  local r2 = Engine.Suggest(ctx({mode = "farm", price = price2, age = age2, dbUpdatedAt = NOW - 60}))
  eq(r2.db.level, "warn"); assert(has(r2.db.text, "Solo hay precio de 3"), r2.db.text)
  -- Escaneo completo viejo: avisa de la antigüedad.
  local r3 = Engine.Suggest(ctx({mode = "farm", dbUpdatedAt = false, fullScanAt = NOW - 10 * 3600}))
  eq(r3.db.level, "warn"); assert(has(r3.db.text, "10 h"), r3.db.text)
end)

test("DbStatus sin fechas de escaneo", function()
  local r = Engine.DbStatus(ctx({dbUpdatedAt = false, now = false}), "farm")
  eq(r.level, "ok"); eq(r.hours, nil)
  local r2 = Engine.DbStatus(ctx({dbUpdatedAt = false, ageKnown = false, age = function() return nil end}), "lazy")
  eq(r2.level, "warn"); assert(has(r2.text, "No sé cuándo"), r2.text)
end)

test("Precio sin edad (más de 21 días) cuenta como viejo y no se usa para rutas a tope", function()
  local r = Engine.Suggest(ctx({mode = "farm", age = function(id) if id == 3858 then return nil end if PRICES[id] then return 0 end end}))
  eq(find(r.sections.farm, function(s) return has(s.title, "mitril") end), nil)
end)

test("Tranquilo: funde el cobre porque el lingote vale más y no sugiere vender ese mineral", function()
  local r = Engine.Suggest(ctx({bags = {[2770] = {count = 40, quality = 1}}}))
  local smelt = find(r.sections.now, function(s) return s.kind == "craft" end)
  assert(smelt and has(smelt.title, "Funde 40× Lingote de cobre"), smelt and smelt.title)
  eq(kinds(r, "sell"), 0)
end)

test("Hierro: el mineral vale más, se vende sin fundir", function()
  local r = Engine.Suggest(ctx({bags = {[2772] = {count = 20, quality = 1}}}))
  eq(kinds(r, "craft"), 0)
  local sell = find(r.sections.now, function(s) return s.kind == "sell" end)
  assert(sell and has(sell.detail, "20× Hierro"), sell and sell.detail)
end)

test("Tranquilo agrupa ventas en una línea; A tope las separa", function()
  local bags = {[2772] = {count = 20, quality = 1}, [2838] = {count = 10, quality = 1}, [4306] = {count = 15, quality = 1}}
  eq(kinds(Engine.Suggest(ctx({bags = bags})), "sell"), 1)
  eq(kinds(Engine.Suggest(ctx({mode = "farm", bags = bags})), "sell"), 3)
end)

test("No se sugiere vender: ligados, herramientas ni consumibles (salvo los que fabricas)", function()
  local bags = {[2772] = {count = 20, quality = 1, bound = true}, [2901] = {count = 1, quality = 1, classID = 2},
                [858] = {count = 5, quality = 1, classID = 0}}
  PRICES[2901], PRICES[858] = 900, 80
  local r = Engine.Suggest(ctx({mode = "farm", bags = bags}))
  eq(kinds(r, "sell"), 0)
  local r2 = Engine.Suggest(ctx({mode = "farm", bags = bags, recipes = {{product = 858, qty = 1, reagents = {{2447, 1}}, prof = "alchemy"}}}))
  assert(find(r2.sections.now, function(s) return s.kind == "sell" and has(s.title, "Poción") end), "la poción que fabricas sí")
  PRICES[2901], PRICES[858] = nil, nil
end)

test("Al vendedor y chatarra gris", function()
  local r = Engine.Suggest(ctx({mode = "farm", vendor = function(id) return id == 2589 and 50 or 1 end,
    bags = {[2589] = {count = 10, quality = 1}, [999] = {count = 3, quality = 0, vendor = 200}}}))
  assert(find(r.sections.now, function(s) return s.kind == "vendor" end), "esperaba vendedor")
  local gray = find(r.sections.now, function(s) return s.kind == "gray" end)
  assert(gray and has(gray.title, "6p") and not has(gray.detail, "Leatrix"), gray and gray.title)
end)

test("Receta: tranquilo solo con materiales; a tope dice qué falta, quién lo consigue y reserva lo que llevas", function()
  local recipe = {product = 12404, qty = 1, reagents = {{12365, 2}, {2772, 1}}, prof = "blacksmithing"}
  eq(find(Engine.Suggest(ctx({recipes = {recipe}})).sections.now, function(s) return s.icon == 12404 end), nil)
  local r = Engine.Suggest(ctx({mode = "farm", recipes = {recipe}, bags = {[2772] = {count = 1, quality = 1}},
    guild = {Luis = {profs = {mining = 290}}}}))
  local craft = find(r.sections.now, function(s) return s.icon == 12404 end)
  assert(craft, "esperaba la receta")
  assert(has(craft.detail, "2× Piedra densa: pídeselo a Luis, que tiene Minería"), craft.detail)
  assert(craft.shopping and craft.shopping[1].id == 12365 and craft.shopping[1].count == 2, "lista de la compra")
  eq(find(r.sections.now, function(s) return s.kind == "sell" and has(s.detail .. s.title, "Hierro") end), nil, "el hierro reservado no se vende")
end)

test("Lo que falta y tienes en el banco: se saca para fabricar, sin comprarlo ni sugerir venderlo", function()
  local recipe = {product = 12404, qty = 1, reagents = {{12365, 2}}, prof = "blacksmithing"}
  -- A tope siempre; en tranquilo, solo si el viaje al banco da al menos 1 oro (con 7 piedras no: ni se fabrica ni se vende).
  for _, case in ipairs({{"farm", 7, "fabrica 3×", "6× Piedra densa."}, {"lazy", 7}, {"lazy", 20, "fabrica 10×", "20× Piedra densa."}}) do
    local r = Engine.Suggest(ctx({mode = case[1], recipes = {recipe}, bank = {[12365] = {count = case[2], quality = 1}}}))
    local row = find(r.sections.now, function(s) return s.icon == 12404 end)
    if case[3] then
      assert(row and row.kind == "bank" and has(row.title, "Saca del banco y " .. case[3] .. " Piedra de afilar densa"), row and row.title)
      assert(has(row.detail, "Del banco: " .. case[4]), row.detail)
      eq(row.shopping, nil, "nada que comprar")
    else
      eq(row, nil, "en tranquilo no compensa")
    end
    eq(find(all(r), function(s) return has(s.title, "y vende") and has(s.detail, "Piedra densa") end), nil, case[1] .. ": no vende la piedra")
  end
end)

test("Lo que falta y solo está en parte en el banco: lo indica y la compra solo lleva lo que no tienes", function()
  local recipe = {product = 12404, qty = 1, reagents = {{12365, 2}, {2772, 1}}, prof = "blacksmithing"}
  local r = Engine.Suggest(ctx({mode = "farm", recipes = {recipe}, bank = {[12365] = {count = 1, quality = 1}}}))
  local craft = find(r.sections.now, function(s) return s.icon == 12404 end)
  assert(craft and craft.kind == "craft" and has(craft.detail, "Te faltan 2× Piedra densa (tienes 1 en el banco); 1× Hierro"), craft and craft.detail)
  eq(#craft.shopping, 2); eq(craft.shopping[1].id, 12365); eq(craft.shopping[1].count, 1); eq(craft.shopping[2].id, 2772)
  -- Con piedra de sobra en el banco pero sin hierro: se guarda la piedra y solo se compra el hierro.
  local r2 = Engine.Suggest(ctx({mode = "farm", recipes = {recipe}, bank = {[12365] = {count = 7, quality = 1}}}))
  local craft2 = find(r2.sections.now, function(s) return s.icon == 12404 end)
  assert(craft2 and has(craft2.detail, "(tienes 7 en el banco)"), craft2 and craft2.detail)
  eq(#craft2.shopping, 1); eq(craft2.shopping[1].id, 2772)
  eq(find(all(r2), function(s) return s.kind == "bank" and has(s.detail, "Piedra densa") end), nil, "no se vende la piedra")
end)

test("Minero con mineral en el banco: sacarlo y fundirlo, no venderlo (también en tranquilo)", function()
  for _, mode in ipairs({"lazy", "farm"}) do
    local r = Engine.Suggest(ctx({mode = mode, bank = {[3858] = {count = 40, quality = 1}}, bankAt = NOW - 2 * 86400}))
    local row = find(r.sections.now, function(s) return s.kind == "bank" end)
    assert(row and has(row.title, "Saca del banco y funde 40× Lingote de mitril"), row and row.title)
    assert(has(row.detail, "Del banco: 40× Mineral de mitril.") and has(row.detail, "hace 2 días"), row.detail)
    eq(find(all(r), function(s) return has(s.title, "y vende") end), nil, mode .. ": no se vende el mineral")
  end
  -- Un herrero sin Minería sí lo vende.
  local r = Engine.Suggest(ctx({mode = "farm", me = {name = "Javi", level = 30, profs = {blacksmithing = 150}},
    bank = {[3858] = {count = 40, quality = 1}}}))
  local sell = find(r.sections.now, function(s) return s.kind == "bank" end)
  assert(sell and has(sell.title, "y vende") and has(sell.detail, "40× Mineral de mitril"), sell and sell.title)
end)

test("Banco: lo que fabricas tú (lingotes, piedras de afilar) también se sugiere vender", function()
  local r = Engine.Suggest(ctx({mode = "farm", bank = {[3860] = {count = 40, quality = 1}, [3858] = {count = 40, quality = 1}}}))
  local sell = find(r.sections.now, function(s) return s.kind == "bank" and has(s.title, "y vende") end)
  assert(sell and has(sell.detail, "40× Lingote de mitril") and not has(sell.detail, "Mineral"), sell and sell.detail)
  assert(find(r.sections.now, function(s) return s.kind == "bank" and has(s.title, "funde 40×") end), "y el mineral se funde")
  local recipe = {product = 12404, qty = 1, reagents = {{12365, 1}}, prof = "blacksmithing"}
  local r2 = Engine.Suggest(ctx({mode = "farm", recipes = {recipe}, bank = {[12404] = {count = 20, quality = 1, classID = 0}}}))
  local sell2 = find(r2.sections.now, function(s) return s.kind == "bank" and has(s.title, "y vende") end)
  assert(sell2 and has(sell2.detail, "20× Piedra de afilar densa"), sell2 and sell2.detail)
end)

test("Material propio que el vendedor paga mejor que la subasta: no se fabrica con pérdidas", function()
  PRICES[2996] = 60
  local bolt = {product = 2996, qty = 1, reagents = {{2589, 2}}, prof = "tailoring"}
  local function run(recipes)
    return Engine.Suggest(ctx({me = {name = "Javi", level = 30, profs = {tailoring = 100}}, recipes = recipes,
      vendor = function(id) return id == 2589 and 50 or 1 end, bags = {[2589] = {count = 40, quality = 1}}}))
  end
  local r = run({bolt})
  eq(kinds(r, "craft"), 0, "fabricar rinde menos que vender al mercader")
  local vendor = find(r.sections.now, function(s) return s.kind == "vendor" end)
  assert(vendor and has(vendor.title, "20p"), vendor and vendor.title)
  PRICES[2996] = nil
end)

test("Material de mercader (a tope): no limita cuántas haces ni va a la lista de la subasta", function()
  PRICES[3859], PRICES[3857] = 2500, 3000
  local vendorBuy = function(id) return id == 3857 and 500 or nil end
  local bags = {[3575] = {count = 20, quality = 1}}
  local r = Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, bags = bags}))
  local steel = find(r.sections.now, function(s) return s.icon == 3859 end)
  assert(steel and has(steel.title, "Funde 20× Lingote de acero"), steel and steel.title)
  assert(has(steel.detail, "Compra a un mercader 20× Carbón"), steel.detail)
  eq(steel.shopping, nil, "el carbón no se busca en la subasta")
  eq(find(r.sections.now, function(s) return s.kind == "sell" and has(s.title, "Lingote de hierro") end), nil, "el hierro no se vende")
  -- Con 5 de carbón en las bolsas solo compras 15.
  bags[3857] = {count = 5, quality = 1}
  local r2 = Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, bags = bags}))
  assert(has(find(r2.sections.now, function(s) return s.icon == 3859 end).detail, "15× Carbón"))
  bags[3857] = nil
  -- Si falta otra cosa: se dice que el carbón es de mercader y solo se compra lo demás en la subasta.
  local r3 = Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, bags = {}}))
  local steel3 = find(r3.sections.now, function(s) return s.icon == 3859 end)
  assert(steel3 and has(steel3.detail, "1× Carbón (cómpralo a un mercader)"), steel3 and steel3.detail)
  eq(#steel3.shopping, 1); eq(steel3.shopping[1].id, 3575)
  -- Si la subasta es más barata que el mercader, el carbón sí va a la lista.
  PRICES[3857] = 300
  local r4 = Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, bags = {}}))
  local steel4 = find(r4.sections.now, function(s) return s.icon == 3859 end)
  assert(steel4 and #steel4.shopping == 2 and steel4.shopping[2].id == 3857, steel4 and steel4.detail)
  -- En tranquilo solo cuenta lo que llevas.
  PRICES[3857] = 3000
  eq(find(Engine.Suggest(ctx({vendorBuy = vendorBuy, bags = {[3575] = {count = 20, quality = 1}}})).sections.now,
    function(s) return s.icon == 3859 end), nil)
  PRICES[3859], PRICES[3857] = nil, nil
end)

test("Material de mercader: se usa el más barato entre mercader y subasta", function()
  local recipe = {product = 12404, qty = 1, reagents = {{12365, 2}}, prof = "blacksmithing"}
  local cheap = Engine.TopCrafts(ctx({recipes = {recipe}, vendorBuy = function(id) return id == 12365 and 100 or nil end}), 8)
  eq(cheap[1].profit, 2375 - 200)
  local dear = Engine.TopCrafts(ctx({recipes = {recipe}, vendorBuy = function(id) return id == 12365 and 5000 or nil end}), 8)
  eq(dear[1].profit, 2375 - 600)
end)

test("Material propio sin valor conocido: la receta no se sugiere", function()
  local recipe = {product = 12404, qty = 1, reagents = {{99999, 1}}, prof = "blacksmithing"}
  local r = Engine.Suggest(ctx({recipes = {recipe}, vendor = function() return nil end, bags = {[99999] = {count = 5, quality = 1}}}))
  eq(kinds(r, "craft"), 0)
end)

test("Recetas que hacen varias unidades: «por tanda» y título con unidades", function()
  PRICES[2841] = 100
  local r = Engine.Suggest(ctx({mode = "farm", me = {name = "Javi", level = 30, profs = {mining = 100}},
    bags = {[2840] = {count = 5, quality = 1}, [3576] = {count = 5, quality = 1}}}))
  local bronze = find(r.sections.now, function(s) return s.icon == 2841 end)
  assert(bronze and has(bronze.title, "Funde 10×"), bronze and bronze.title)
  PRICES[2841] = nil
end)

test("No reutiliza los mismos materiales para dos recetas", function()
  local a = {product = 12404, qty = 1, reagents = {{12365, 2}}, prof = "blacksmithing"}
  local b = {product = 12405, qty = 1, reagents = {{12365, 2}}, prof = "blacksmithing"}
  PRICES[12405] = 2400
  local r = Engine.Suggest(ctx({recipes = {a, b}, bags = {[12365] = {count = 2, quality = 1}}}))
  eq(kinds(r, "craft"), 1)
  PRICES[12405] = nil
end)

test("Las recetas aceptadas no se recortan por el límite del modo", function()
  local bags = {[2770] = {count = 40, quality = 1}, [12365] = {count = 4, quality = 1}}
  for _, id in ipairs({2772, 2838, 4306, 4338, 14047}) do bags[id] = {count = 10, quality = 1} end
  local r = Engine.Suggest(ctx({bags = bags, recipes = {{product = 12404, qty = 1, reagents = {{12365, 1}}, prof = "blacksmithing"}}}))
  eq(kinds(r, "craft"), 2); assert(#r.sections.now <= 4)
end)

test("Ruta tranquila según tu nivel; a tope: zonas por profesión y tela al final", function()
  local lazy = Engine.Suggest(ctx({me = {name = "Javi", level = 20, profs = {mining = 290}}}))
  eq(#lazy.sections.farm, 1)
  assert(has(lazy.sections.farm[1].title, "Hierro") and has(lazy.sections.farm[1].title, "Por tus zonas"), lazy.sections.farm[1].title)
  local farm = Engine.Suggest(ctx({mode = "farm", me = {name = "Javi", level = 55, profs = {mining = 290}}}))
  local first = farm.sections.farm[1]
  assert(first.kind == "route" and has(first.title, "Torio"), first.title)
  eq(farm.sections.farm[#farm.sections.farm].kind, "cloth")
end)

test("Tela según el nivel (no la de nivel 60 para un nivel 20)", function()
  local r = Engine.Suggest(ctx({mode = "farm", me = {name = "Javi", level = 20, profs = {}}}))
  local cloth = find(r.sections.farm, function(s) return s.kind == "cloth" end)
  assert(cloth and cloth.icon == 2592, cloth and tostring(cloth.icon))
end)

test("Hermandad: una fila por amigo, minerales solo para mineros, nivel de habilidad", function()
  local bags = {[3575] = {count = 10, quality = 1}, [2772] = {count = 10, quality = 1}, [12359] = {count = 10, quality = 1}}
  PRICES[12359] = 1000
  local r = Engine.Suggest(ctx({mode = "farm", bags = bags,
    guild = {Ana = {profs = {engineering = 180, blacksmithing = 170}}, Luis = {profs = {mining = 150}}, Javi = {profs = {engineering = 1}}}}))
  local ana = find(r.sections.group, function(s) return has(s.title, "Ana") end)
  assert(ana and has(ana.detail, "Lingote de hierro") and not has(ana.detail, "Hierro,") and not has(ana.detail, "torio"), ana and ana.detail)
  local count = 0
  for _, s in ipairs(r.sections.group) do if has(s.title, "Ana") then count = count + 1 end end
  eq(count, 1, "una fila por amigo")
  local luis = find(r.sections.group, function(s) return has(s.title, "Luis") end)
  assert(luis and has(luis.detail, "Hierro"), luis and luis.detail)
  eq(find(r.sections.group, function(s) return has(s.title, "Javi") end), nil, "no se sugiere a sí mismo")
  PRICES[12359] = nil
end)

test("Encantador: solo el de más nivel, y solo con precios", function()
  local bags = {[5000] = {count = 2, quality = 2, equip = true}, [5001] = {count = 1, quality = 3, equip = true}}
  local guild = {Bea = {profs = {enchanting = 120}}, Eva = {profs = {enchanting = 200}}}
  local r = Engine.Suggest(ctx({mode = "farm", bags = bags, guild = guild}))
  eq(kinds(r, "disenchant"), 1)
  assert(has(find(r.sections.group, function(s) return s.kind == "disenchant" end).title, "Eva 3 piezas"))
  eq(kinds(Engine.Suggest(ctx({mode = "farm", bags = bags, guild = guild, hasPriceSource = false})), "disenchant"), 0)
end)

test("Encantador tú mismo: desencantas tú si nadie de la hermandad tiene más nivel", function()
  local bags = {[5000] = {count = 2, quality = 2, equip = true}, [5001] = {count = 1, quality = 3, equip = true}}
  local me = {name = "Javi", level = 60, profs = {enchanting = 300}}
  local r = Engine.Suggest(ctx({mode = "farm", me = me, bags = bags, guild = {Bea = {profs = {enchanting = 40}}}}))
  local de = find(r.sections.now, function(s) return s.kind == "disenchant" end)
  assert(de and de.title == "Desencanta 3 piezas verdes o azules", de and de.title)
  eq(kinds(r, "disenchant"), 1, "no se sugiere dárselas a Bea")
  local solo = Engine.Suggest(ctx({me = me, bags = bags}))
  assert(find(solo.sections.now, function(s) return s.kind == "disenchant" end), "sin encantadores en la hermandad")
  local better = Engine.Suggest(ctx({mode = "farm", me = {name = "Javi", level = 30, profs = {enchanting = 100}}, bags = bags,
    guild = {Eva = {profs = {enchanting = 200}}}}))
  assert(has(find(better.sections.group, function(s) return s.kind == "disenchant" end).title, "Dale a Eva 3 piezas"))
end)

test("Hermandad: receta rentable de un amigo con tus materiales", function()
  local r = Engine.Suggest(ctx({bags = {[3860] = {count = 6, quality = 1}},
    guild = {Pedro = {profs = {engineering = 220}, crafts = {{product = 10546, qty = 1, profit = 5000, reagents = {{3860, 3}}}}}}}))
  local item = find(r.sections.group, function(s) return s.kind == "friendcraft" end)
  assert(item and item.value == 10000, item and tostring(item.value))
end)

test("A tope: profesiones que le faltan a la hermandad", function()
  local r = Engine.Suggest(ctx({mode = "farm", guild = {Ana = {profs = {engineering = 100}}, Luis = {profs = {mining = 100}}}}))
  local gap = find(r.sections.group, function(s) return s.kind == "coverage" end)
  assert(gap and has(gap.title, "Alquimia"), gap and gap.title)
end)

test("TopCrafts solo comparte recetas con beneficio y margen suficientes", function()
  local good = {product = 12404, qty = 1, reagents = {{12365, 2}}, prof = "blacksmithing"}
  local tiny = {product = 3575, qty = 1, reagents = {{2770, 1}}, prof = "mining"}
  local top = Engine.TopCrafts(ctx({recipes = {good, tiny}}), 8)
  eq(#top, 1); eq(top[1].product, 12404)
end)

test("Aviso de instructor cuando una profesión está a punto de topar", function()
  local r = Engine.Suggest(ctx({me = {name = "Javi", level = 30, profs = {mining = 145, blacksmithing = 100}, profMax = {mining = 150, blacksmithing = 225}}}))
  eq(#r.notes, 1); assert(has(r.notes[1].title, "Minería") and has(r.notes[1].title, "Experto"), r.notes[1].title)
end)

test("Aviso de rango: nivel de personaje que pide y profesiones secundarias (libro o misión)", function()
  local function notes(level, profs, profMax)
    return Engine.Suggest(ctx({me = {name = "Javi", level = level, profs = profs, profMax = profMax}})).notes
  end
  local low = notes(14, {mining = 145}, {mining = 150})
  eq(#low, 1); assert(not has(low[1].title, "Entrena") and has(low[1].title, "a partir del nivel 20"), low[1].title)
  local ok = notes(40, {mining = 215}, {mining = 225})
  assert(has(ok[1].title, "Entrena Minería: rango Artesano"), ok[1].title)
  assert(has(notes(30, {mining = 215}, {mining = 225})[1].title, "a partir del nivel 35"))
  local fish = notes(40, {fishing = 220}, {fishing = 225})
  assert(not has(fish[1].title, "Entrena") and has(fish[1].title, "misión de rango Artesano"), fish[1].title)
  local cook = notes(40, {cooking = 145}, {cooking = 150})
  assert(has(cook[1].title, "Cocina: compra el libro de rango Experto") and has(cook[1].detail, "«Libro de cocina para expertos»"), cook[1].detail)
  -- Oficial de Primeros auxilios: instructor y sin nivel mínimo; Experto: libro sin nivel mínimo.
  assert(has(notes(5, {firstaid = 70}, {firstaid = 75})[1].title, "Entrena Primeros auxilios: rango Oficial"))
  assert(has(notes(12, {firstaid = 150}, {firstaid = 150})[1].title, "compra el libro"))
  assert(has(notes(5, {cooking = 70}, {cooking = 75})[1].title, "a partir del nivel 10"))
  -- Sin nivel conocido no se bloquea.
  assert(has(notes(nil, {mining = 145}, {mining = 150})[1].title, "Entrena"))
end)

test("Banco: sugiere sacar y vender lo que vale (a tope)", function()
  local r = Engine.Suggest(ctx({mode = "farm", bank = {[4338] = {count = 40, quality = 1}}, bankAt = NOW - 2 * 86400}))
  local bank = find(r.sections.now, function(s) return s.kind == "bank" end)
  assert(bank and has(bank.title, "y vende") and has(bank.detail, "40× Tela de paño mágico") and has(bank.detail, "hace 2 días"),
    bank and bank.detail)
end)

test("Comisión configurable", function()
  local r5 = Engine.Suggest(ctx({mode = "farm", bags = {[2772] = {count = 100, quality = 1}}}))
  local r15 = Engine.Suggest(ctx({mode = "farm", cut = 0.15, bags = {[2772] = {count = 100, quality = 1}}}))
  eq(find(r5.sections.now, function(s) return s.kind == "sell" end).value, 11400)
  eq(find(r15.sections.now, function(s) return s.kind == "sell" end).value, 10200)
end)

test("FriendsWhoUse para la descripción de objetos", function()
  local users = Engine.FriendsWhoUse({Ana = {profs = {engineering = 180}}, Javi = {profs = {engineering = 180}}}, 3575, "Javi")
  eq(#users, 1); eq(users[1], "Ana (Ingeniería)")
end)

test("Las gemas no heredan el nivel de la veta rara donde salen", function()
  eq(Engine.TIER[1206], nil); eq(Engine.TIER[1529], nil); eq(Engine.TIER[7909], nil)
  eq(Engine.TIER[2835], 1); eq(Engine.TIER[12365], 245); eq(Engine.TIER[2934], 1) -- piedras y pellejos siguen
  local guild = {Ana = {profs = {blacksmithing = 300}}, Eva = {profs = {engineering = 300}}}
  for _, gem in ipairs({1206, 1529, 7909, 7910}) do eq(#Engine.FriendsWhoUse(guild, gem, "Javi"), 2, "gema " .. gem) end
  eq(#Engine.FriendsWhoUse({Ana = {profs = {blacksmithing = 180}}}, 7909, "Javi"), 1)
end)

test("Hermandad grande: las bolsas no se reordenan por cada amigo", function()
  local bags = {}
  for i = 1, 60 do bags[60000 + i] = {count = 10, quality = 1} end
  bags[3575], bags[2772] = {count = 10, quality = 1}, {count = 10, quality = 1}
  local guild = {}
  for i = 1, 300 do guild["Amigo" .. i] = {profs = {engineering = 180, mining = 150}} end
  local sort, sorted = table.sort, 0
  table.sort = function(t, f) sorted = sorted + #t; return sort(t, f) end
  local ok, r = pcall(Engine.Suggest, ctx({mode = "farm", bags = bags, guild = guild}))
  table.sort = sort
  assert(ok, r)
  local friend = find(r.sections.group, function(s) return s.kind == "friend" end)
  assert(friend and has(friend.detail, "Lingote de hierro"), friend and friend.detail)
  assert(sorted < 3000, "elementos ordenados: " .. sorted) -- antes: unas 300 × 62 × 2
end)

test("Singular y plural en los textos", function()
  local r = Engine.Suggest(ctx({mode = "farm", me = {name = "Javi", level = 30, profs = {}},
    bags = {[999] = {count = 1, quality = 0, vendor = 5}, [5000] = {count = 1, quality = 2, equip = true}},
    bank = {[4338] = {count = 40, quality = 1}}, bankAt = NOW - 30 * 3600,
    guild = {Eva = {profs = {enchanting = 200, alchemy = 1, engineering = 1, blacksmithing = 1, tailoring = 1, leatherworking = 1,
      herbalism = 1, skinning = 1}}, Luis = {profs = {skinning = 1}}}}))
  local bank = find(r.sections.now, function(s) return s.kind == "bank" end)
  assert(has(bank.detail, "hace 1 día.") and not has(bank.detail, "1 días"), bank.detail)
  eq(find(r.sections.now, function(s) return s.kind == "gray" end).detail, "1 objeto gris: cualquier vendedor te lo compra.")
  local de = find(r.sections.group, function(s) return s.kind == "disenchant" end)
  eq(de.title, "Dale a Eva 1 pieza verde o azul"); assert(has(de.detail, "No tiene precio"), de.detail)
  local gap = find(r.sections.group, function(s) return s.kind == "coverage" end)
  assert(has(gap.title, "le falta: Minería") and has(gap.detail, "Quien la aprenda"), gap.title)
  local gaps = Engine.Suggest(ctx({mode = "farm", me = {name = "Javi", level = 30, profs = {}},
    guild = {Ana = {profs = {engineering = 100}}, Luis = {profs = {mining = 100}}}}))
  local many = find(gaps.sections.group, function(s) return s.kind == "coverage" end)
  assert(has(many.title, "le faltan: ") and has(many.detail, "Quien aprenda alguna"), many.title)
  local gray = Engine.Suggest(ctx({bags = {[999] = {count = 3, quality = 0, vendor = 5}}}))
  eq(find(gray.sections.now, function(s) return s.kind == "gray" end).detail, "3 objetos grises: cualquier vendedor te los compra.")
  -- "Te falta" con una unidad, "Te faltan" con más.
  local one = Engine.Suggest(ctx({mode = "farm", recipes = {{product = 12404, qty = 1, reagents = {{12365, 1}}, prof = "blacksmithing"}}}))
  assert(has(find(one.sections.now, function(s) return s.icon == 12404 end).detail, "Te falta 1× Piedra densa"))
  -- Receta de un amigo con uno o varios de tus materiales.
  local function friendCraft(bags)
    local fr = Engine.Suggest(ctx({bags = bags, guild = {Pedro = {profs = {engineering = 220},
      crafts = {{product = 10546, qty = 1, profit = 5000, reagents = {{3860, 3}, {2772, 1}}}}}}}))
    return find(fr.sections.group, function(s) return s.kind == "friendcraft" end).detail
  end
  assert(has(friendCraft({[3860] = {count = 6, quality = 1}}), "con tu Lingote de mitril."))
  assert(has(friendCraft({[3860] = {count = 6, quality = 1}, [2772] = {count = 2, quality = 1}}), "con tus materiales: Lingote de mitril, Hierro."))
  -- Precio viejo: "hace N días".
  local stale = Engine.Suggest(ctx({mode = "farm", bags = {[2772] = {count = 20, quality = 1}}, age = function(id) if id == 2772 then return 4 end if PRICES[id] then return 0 end end}))
  assert(has(find(stale.sections.now, function(s) return s.kind == "sell" end).detail, "hace 4 días"))
end)

test("Límites por modo", function()
  local bags = {}
  for _, id in ipairs({2772, 2838, 4306, 4338, 14047, 2592, 2589, 2836}) do bags[id] = {count = 10, quality = 1} end
  local lazy = Engine.Suggest(ctx({bags = bags}))
  assert(#lazy.sections.now <= 4 and #lazy.sections.farm <= 1 and #lazy.sections.group <= 1)
  assert(#Engine.Suggest(ctx({mode = "farm", bags = bags})).sections.now <= 8)
end)

print(string.format("motor: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

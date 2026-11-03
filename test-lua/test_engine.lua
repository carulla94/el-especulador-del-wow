-- Pruebas del motor de sugerencias (lógica pura). Desde la raíz del repositorio:
--   lua5.1 test-lua/test_engine.lua
local DIR = "addon/OroHermandad/"
local ns = {}
assert(loadfile(DIR .. "Data.lua"))("OroHermandad", ns)
assert(loadfile(DIR .. "Spec.lua"))("OroHermandad", ns)
assert(loadfile(DIR .. "Engine.lua"))("OroHermandad", ns)
local Engine, Data, Spec = ns.Engine, ns.Data, ns.Spec

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
  assert(steel.vendorBuys and steel.vendorBuys[1].id == 3857 and steel.vendorBuys[1].count == 20, "lo que se compra al mercader (para /oro comprar)")
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
  assert(steel3.vendorBuys and steel3.vendorBuys[1].id == 3857 and steel3.vendorBuys[1].count == 1, "carbón al mercader")
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

test("Material de mercader guardado en el banco (a tope): se saca, no se compra ni se sugiere venderlo", function()
  PRICES[3859] = 2500 -- el carbón no está en la subasta (lo normal): solo lo vende un mercader
  local vendorBuy = function(id) return id == 3857 and 500 or nil end
  local vendor = function(id) return id == 3857 and 125 or 1 end
  local function steelRow(r) return find(r.sections.now, function(s) return s.icon == 3859 end) end
  local function sellsCoal(r)
    return find(r.sections.now, function(s) return s.kind == "bank" and has(s.title, "vende") and has(s.detail, "Carbón") end)
  end
  local bags = {[3575] = {count = 20, quality = 1}}
  -- Todo el carbón en el banco: igual que en tranquilo.
  local r = Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, vendor = vendor, bags = bags,
    bank = {[3857] = {count = 20, quality = 1}}}))
  local steel = steelRow(r)
  assert(steel and steel.title == "Saca del banco y funde 20× Lingote de acero", steel and steel.title)
  assert(has(steel.detail, "Del banco: 20× Carbón.") and not has(steel.detail, "mercader"), steel.detail)
  eq(steel.vendorBuys, nil, "nada que comprar")
  local lazy = steelRow(Engine.Suggest(ctx({vendorBuy = vendorBuy, vendor = vendor, bags = bags, bank = {[3857] = {count = 20, quality = 1}}})))
  eq(lazy and lazy.title, steel.title, "mismo consejo en los dos modos")
  -- Parte en el banco: se saca y el resto se compra.
  steel = steelRow(Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, vendor = vendor, bags = bags,
    bank = {[3857] = {count = 8, quality = 1}}})))
  assert(has(steel.detail, "Del banco: 8× Carbón. Compra a un mercader 12× Carbón."), steel.detail)
  assert(steel.vendorBuys and steel.vendorBuys[1].count == 12, "12 al mercader")
  -- Con el carbón en la subasta justo por encima del mercader: el del banco no se sugiere vender.
  PRICES[3857] = 510
  r = Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, vendor = vendor, bags = bags, bank = {[3857] = {count = 20, quality = 1}}}))
  assert(has(steelRow(r).detail, "Del banco: 20× Carbón."), steelRow(r).detail)
  eq(sellsCoal(r), nil, "no se vende lo que la receta saca del banco")
  -- Sin hierro: la fila «para vender» dice que el carbón está en el banco, no que lo compres, y tampoco se vende.
  r = Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, vendor = vendor, bags = {}, bank = {[3857] = {count = 20, quality = 1}}}))
  steel = steelRow(r)
  assert(steel and has(steel.detail, "1× Carbón (tienes 20 en el banco)") and not has(steel.detail, "mercader"), steel and steel.detail)
  eq(#steel.shopping, 1); eq(steel.shopping[1].id, 3575); eq(steel.vendorBuys, nil)
  eq(sellsCoal(r), nil, "el carbón reservado no se vende")
  PRICES[3857] = nil
  -- Hierro y carbón en el banco: se saca todo, nada al mercader.
  steel = steelRow(Engine.Suggest(ctx({mode = "farm", vendorBuy = vendorBuy, vendor = vendor, bags = {},
    bank = {[3575] = {count = 20, quality = 1}, [3857] = {count = 20, quality = 1}}})))
  assert(steel and has(steel.detail, "Del banco: 20× Lingote de hierro, 20× Carbón.") and not has(steel.detail, "mercader"),
    steel and steel.detail)
  PRICES[3859] = nil
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

---------------------------------------------------------------------------
-- Modos con banderas y modo Especular
---------------------------------------------------------------------------
local function serialize(value)
  if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. serialize(value[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

test("Cada modo define todas sus banderas y un límite para cada sección (también spec)", function()
  local listed = {}
  for _, key in ipairs(Engine.MODE_ORDER) do listed[key] = true end
  for key, mode in pairs(Engine.MODES) do
    assert(listed[key], key .. " no está en MODE_ORDER")
    for _, flag in ipairs(Engine.MODE_KEYS) do assert(mode[flag] ~= nil, key .. " no define " .. flag) end
    for _, section in ipairs(Engine.SECTIONS) do
      assert(type(mode.limits[section]) == "number", key .. ": falta limits." .. section)
    end
    assert(mode.routes == "level" or mode.routes == "all", key .. ": routes")
    assert(mode.specMinConf == "ALTA" or mode.specMinConf == "MEDIA", key .. ": specMinConf")
    for _, section in ipairs(mode.order) do
      assert(section == "notes" or section == "balance" or mode.limits[section], key .. ": sección desconocida " .. section)
    end
  end
  eq(#Engine.MODE_ORDER, 3); eq(Engine.MODES.spec.label, "Especular")
  eq(Engine.MODES.lazy.limits.spec, 1); eq(Engine.MODES.farm.limits.spec, 2); eq(Engine.MODES.spec.limits.spec, 8)
end)

test("Especular no se comporta como A tope: sin recetas, ventas, rutas ni hermandad", function()
  local over = {bags = {[2770] = {count = 40, quality = 1}, [2772] = {count = 20, quality = 1}, [1000] = {count = 2, quality = 0, vendor = 50}},
                guild = {Ana = {profs = {engineering = 100}}, Luis = {profs = {mining = 100}}},
                recipes = {{product = 12404, qty = 1, reagents = {{12365, 1}}, prof = "blacksmithing"}}}
  over.mode = "farm"
  local farm = Engine.Suggest(ctx(over))
  assert(#farm.sections.now > 0 and #farm.sections.farm > 0 and #farm.sections.group > 0, "A tope sí tiene de todo")
  over.mode = "spec"
  local spec = Engine.Suggest(ctx(over))
  eq(spec.mode, "spec")
  for _, key in ipairs({"now", "farm", "group", "spec"}) do eq(#spec.sections[key], 0, key) end
  eq(table.concat(spec.order, ","), "notes,spec,balance"); eq(spec.tableButton, true)
  assert(spec.showEmpty.spec and spec.showEmpty.balance and not spec.showEmpty.now, "secciones visibles")
  -- Sin historial (la sesión no lo cargó) lo dice en vez de quedarse en blanco.
  assert(has(spec.spec.text, "historial de precios no está disponible"), spec.spec and spec.spec.text)
  -- Los precios se dan por viejos como en A tope (6 h), no como en Tranquilo.
  eq(Engine.DbStatus(ctx({dbUpdatedAt = NOW - 10 * 3600}), "spec").level, "warn")
  eq(Engine.DbStatus(ctx({dbUpdatedAt = NOW - 10 * 3600}), "lazy").level, "ok")
  -- En Tranquilo y A tope las mismas listas de siempre, más la sección Especular (vacía sin historial).
  eq(table.concat(farm.order, ","), "notes,now,spec,farm,group"); eq(#farm.sections.spec, 0); eq(farm.spec, nil)
end)

local T = Spec.DayIndex(NOW)
local WORKED = {9600, 9800, 10000, 10200, 10400, 9900, 10100, 9700, 10300, 10000, 9900, 10100, 10000, 10000}
local BOOK = {{5800, 1}, {6000, 40}, {6200, 60}, {7900, 100}, {9500, 200}}
-- Días T-n .. T-1 (false = día sin precio) con lo = hi = el valor, y hoy si se pide.
local function dayRecords(values, opts)
  local out, T0 = {}, opts.T0 or T
  for i, v in ipairs(values) do
    if v then out[#out + 1] = {d = T0 - #values + i - 1, lo = v, hi = v, last = v, qty = opts.qty or 400, scans = 1, src = "o"} end
  end
  if opts.today then out[#out + 1] = {d = T0, lo = opts.today, hi = opts.today, last = opts.today, qty = opts.qty or 400, scans = 1, src = "o"} end
  return out
end
local function watched(values, opts)
  opts = opts or {}
  return {records = dayRecords(values, opts), vendor = opts.vendor or 100, dep = opts.dep == nil and 50 or opts.dep or nil,
          cat = opts.cat or "tela", name = opts.name,
          point = opts.p and {t = NOW - (opts.ago or 600), lo = opts.p, qty = 300, qty5 = opts.q5 or 40} or nil}
end
local function specCtx(over, items, extra)
  local c = ctx(over)
  c.spec = {T = T, now = NOW, hints = true, budget = 2000000, items = items, books = {}}
  for k, v in pairs(extra or {}) do c.spec[k] = v end
  return c
end
local function rowsOf(r, kind)
  local out = {}
  for _, x in ipairs(r.sections.spec) do if not kind or x.kind == kind then out[#out + 1] = x end end
  return out
end

test("Chollo con lo que mostró la subasta: el ejemplo trabajado de Especular, con su lista de la compra", function()
  local items = {[14047] = watched(WORKED)}
  for _, mode in ipairs({"lazy", "farm", "spec"}) do
    local r = Engine.Suggest(specCtx({mode = mode}, items, {books = {[14047] = {at = NOW - 60, lots = BOOK}}}))
    local rows = rowsOf(r, "flip")
    eq(#rows, 1, mode)
    local row = rows[1]
    eq(row.title, "Chollo: Paño rúnico a 58p (42 % por debajo de lo normal)")
    eq(row.detail, "Compra 82× a 82p 16c como máximo; no revendas por debajo de 64p 73c; objetivo 1o; ganancia ≈ 27o 48p "
      .. "tras la comisión y un depósito perdido. Precio confirmado en la subasta hace 1 min. Fiable · 14 días · variación ±3 %.")
    eq(row.icon, 14047); eq(row.value, 274818); eq(row.flip.cost, 500000); eq(row.flip.maxBuy, 8216); eq(row.flip.breakEven, 6473)
    eq(#row.shopping, 1); eq(row.shopping[1].id, 14047); eq(row.shopping[1].count, 82)
    assert(has(r.spec.text, "Recuerda: el precio mínimo publicado no es una venta confirmada."), r.spec.text)
  end
  -- Comisión del 15 % (/oro comision 15): compra como mucho a 73p 46c.
  local r = Engine.Suggest(specCtx({mode = "farm", cut = 0.15}, items, {books = {[14047] = {at = NOW - 60, lots = BOOK}}}))
  eq(rowsOf(r, "flip")[1].flip.maxBuy, 7346)
end)

test("Chollo estimado con el último escaneo propio; sin hora, viejo o sin nada a la venta no hay chollo", function()
  local r = Engine.Suggest(specCtx({mode = "farm"}, {[14047] = watched(WORKED, {p = 6000, q5 = 40})}))
  local row = rowsOf(r, "flip")[1]
  assert(row and has(row.detail, "Compra 40× a 82p 16c como máximo") and has(row.detail, "· estimado: confirma en la subasta. Precio de hace 10 min."),
    row and row.detail)
  eq(row.shopping[1].count, 40)
  -- Escaneo de hace más de 2 h y Auctionator con el mismo precio de hoy: se sabe el precio, no su hora.
  local cheap = function(id) if id == 14047 then return 6000 end return PRICES[id] end
  local old = Engine.Suggest(specCtx({mode = "spec", price = cheap}, {[14047] = watched(WORKED, {p = 6000, ago = 3 * 3600})}))
  eq(#rowsOf(old, "flip"), 0)
  local lines = Engine.SpecLines(specCtx({mode = "spec", price = cheap}, {[14047] = watched(WORKED, {p = 6000, ago = 3 * 3600})}), 14047)
  -- La ventana no lo enseña, así que la descripción tampoco lo llama «Chollo» (R3).
  eq(lines[1].right, "1o · hoy -40 %"); eq(lines[2].left, "Precio bajo (40 % por debajo de lo normal): escanea la subasta para confirmarlo")
  -- Al buscarlo en la subasta no había nada a la venta: el escaneo de hace 10 min ya no vale.
  local gone = Engine.Suggest(specCtx({mode = "spec"}, {[14047] = watched(WORKED, {p = 6000})}, {books = {[14047] = {at = NOW - 30, lots = {}}}}))
  eq(#rowsOf(gone, "flip"), 0)
  -- Lo de la subasta de hace más de 5 min ya no cuenta: vuelve el escaneo propio.
  local stale = Engine.Suggest(specCtx({mode = "spec"}, {[14047] = watched(WORKED, {p = 6000})}, {books = {[14047] = {at = NOW - 400, lots = {}}}}))
  eq(#rowsOf(stale, "flip"), 1)
end)

test("Sin chollo: bajada del 4 %, confianza baja, bajada de nivel, tendencia desconocida o un solo lote barato", function()
  local function flips(items, extra) return #rowsOf(Engine.Suggest(specCtx({mode = "spec"}, items, extra)), "flip") end
  eq(flips({[14047] = watched(WORKED, {p = 9600})}), 0, "4 % por debajo")
  local shaky = {false, 6000, 14000, 6000, 14000, false, false, false, 6000, 14000, 6000, 14000, 10000, 6000}
  eq(flips({[14047] = watched(shaky, {p = 3000})}), 0, "poco fiable")
  local shifted = {10000, 10000, 10000, 10000, 8000, 10000, 8000, 8000, 10000, 7000, false, 10000, 8000, 8000}
  eq(flips({[14047] = watched(shifted, {p = 6000})}), 0, "bajada de nivel")
  local gaps = {10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, 10000, false, false, 10000}
  eq(flips({[14047] = watched(gaps, {p = 6000})}), 0, "tendencia desconocida")
  -- Un lote de 1 a 60p: ganaría menos de 1 oro.
  eq(flips({[14047] = watched(WORKED)}, {books = {[14047] = {at = NOW - 60, lots = {{6000, 1}}}}}), 0, "un solo lote")
  -- Y el mismo objeto con el ejemplo trabajado sí (las pruebas de arriba no fallan por los datos).
  eq(flips({[14047] = watched(WORKED, {p = 6000})}), 1, "control")
end)

test("Límites de Especular en cada modo: Tranquilo 1, A tope 2, Especular 8", function()
  local items = {}
  for i = 1, 12 do items[20000 + i] = watched(WORKED, {p = 6000 + i * 10}) end
  local function count(mode, extra) return #rowsOf(Engine.Suggest(specCtx({mode = mode}, items, extra or {budget = 100000000})), "flip") end
  eq(count("lazy"), 1); eq(count("farm"), 2); eq(count("spec"), 8)
  -- El de Tranquilo es el que más gana; vacío, ningún modo se rompe.
  local lazy = Engine.Suggest(specCtx({mode = "lazy"}, items, {budget = 100000000}))
  eq(lazy.sections.spec[1].icon, 20001)
  for _, mode in ipairs(Engine.MODE_ORDER) do
    local ok, r = pcall(Engine.Suggest, specCtx({mode = mode}, {}))
    assert(ok and #r.sections.spec == 0, mode .. ": " .. tostring(r))
  end
end)

test("Tranquilo solo enseña chollos de confianza alta; A tope y Especular, también orientativos", function()
  local items = {[14047] = watched({false, false, false, 10200, 10400, 9900, 10100, 9700, 10300, 10000, 9900, 10100, 10000, 10000}, {p = 6000})}
  local r = Engine.Suggest(specCtx({mode = "farm"}, items))
  local row = rowsOf(r, "flip")[1]
  assert(row and has(row.detail, "Orientativo · 11 días"), row and row.detail)
  eq(#rowsOf(Engine.Suggest(specCtx({mode = "lazy"}, items)), "flip"), 0)
  eq(#rowsOf(Engine.Suggest(specCtx({mode = "spec"}, items)), "flip"), 1)
end)

test("Protección de lanzamiento, aprendiendo precios y mercado bajando en la línea de estado", function()
  -- 2510 (13-nov): antes del 18-nov no hay chollos; se dice cuántos habría.
  local guard = Engine.Suggest(specCtx({mode = "spec"}, {[14047] = watched(WORKED, {p = 6000, T0 = 2510})}, {T = 2510}))
  eq(#rowsOf(guard, "flip"), 0)
  eq(guard.spec.level, "warn")
  assert(has(guard.spec.text, "Protección de lanzamiento hasta el 18-nov: aún no sugiere compras para revender. Hoy habría 1 chollo."), guard.spec.text)
  -- 2513 (18-nov): ya sí.
  local open = Engine.Suggest(specCtx({mode = "spec"}, {[14047] = watched(WORKED, {p = 6000, T0 = 2513})}, {T = 2513}))
  eq(#rowsOf(open, "flip"), 1); assert(not has(open.spec.text, "Protección"), open.spec.text)
  -- 3 días de precios: hoy es el cuarto de los 7 que hacen falta.
  local learning = Engine.Suggest(specCtx({mode = "spec"}, {[14047] = watched({10000, 10000, 10000}, {p = 6000})}))
  eq(learning.spec.text, "Aprendiendo precios: día 4 de 7. Haz un escaneo completo cada día: el precio normal necesita 7 días y los chollos, 10.")
  local lazyLearning = Engine.Suggest(specCtx({mode = "lazy"}, {[14047] = watched({10000, 10000, 10000}, {p = 6000})}))
  eq(lazyLearning.spec.text, "Aprendiendo precios: día 4 de 7. Haz un escaneo completo cada día: el precio normal necesita 7 días y los chollos, 12.")
  -- Nada guardado todavía en este mercado.
  assert(has(Engine.Suggest(specCtx({mode = "spec"}, {})).spec.text, "Aún no hay precios guardados"))
  -- Un 3 % menos cada día en 4 objetos: mercado bajando, sin chollos.
  local items, falling = {}, {}
  for i = 1, 14 do falling[i] = math.floor(20000 * 0.97 ^ i) end
  for i = 1, 4 do items[30000 + i] = watched(falling, {p = 6000}) end
  local down = Engine.Suggest(specCtx({mode = "spec"}, items))
  eq(#rowsOf(down, "flip"), 0)
  assert(has(down.spec.text, "Mercado bajando: 4 de 4 objetos han caído más de un 10 % en unos días. Vende pronto lo que farmees y no compres para revender."),
    down.spec.text)
  assert(has(down.spec.text, "Con precio normal: 4 de 4 objetos vigilados (0 fiables)."), down.spec.text)
end)

test("Vende ahora: solo con existencias en las bolsas o el banco, y no lo que te guardas", function()
  local items = {[2772] = watched(WORKED, {p = 14000, cat = "metal"}), [13510] = watched(WORKED, {p = 14000, cat = "frasco"})}
  local function spikes(over) over.mode = over.mode or "spec"; return rowsOf(Engine.Suggest(specCtx(over, items)), "spike") end
  local rows = spikes({bags = {[2772] = {count = 20, quality = 1}, [13510] = {count = 5, quality = 1, classID = 0}}})
  eq(#rows, 1, "el frasco no: es un consumible que no fabricas")
  eq(rows[1].title, "Vende ahora 20× Hierro (40 % por encima de lo normal)")
  eq(rows[1].detail, "≈ 26o 60p en la subasta, ya descontada la comisión (hoy 1o 40p; lo normal, 1o). Precio de hace 10 min.")
  eq(#spikes({}), 0, "sin existencias")
  eq(#spikes({bags = {[2772] = {count = 20, quality = 1, bound = true}}}), 0, "ligado")
  local bank = spikes({bank = {[2772] = {count = 12, quality = 1}}})
  assert(bank[1] and bank[1].title == "Vende ahora 12× Hierro (40 % por encima de lo normal)" and has(bank[1].detail, "Está todo en el banco: sácalo primero."),
    bank[1] and bank[1].detail)
  local both = spikes({bags = {[2772] = {count = 3, quality = 1}}, bank = {[2772] = {count = 12, quality = 1}}})
  assert(has(both[1].detail, "Llevas 3 y tienes 12 en el banco."), both[1].detail)
  -- En A tope no hay filas aparte: la de venta lo dice con el precio de Auctionator, el mismo que usa la fila.
  local high = function(id) if id == 2772 then return 14000 end return PRICES[id] end
  assert(#spikes({mode = "farm", bags = {[2772] = {count = 20, quality = 1}}}) == 0, "A tope: sin filas Vende ahora")
  local farm = Engine.Suggest(specCtx({mode = "farm", price = high, bags = {[2772] = {count = 20, quality = 1}}}, items))
  local sell = find(farm.sections.now, function(x) return x.kind == "sell" end)
  assert(has(sell.detail, "Hoy está un 40 % por encima de lo normal: buen momento para vender."), sell.detail)
end)

test("Si no tienes prisa, espera: nota en las filas de venta (no en una bajada de nivel)", function()
  local low = function(id) if id == 2772 or id == 4306 then return 7500 end return PRICES[id] end
  local items = {[2772] = watched(WORKED, {cat = "metal"}), [4306] = watched(WORKED)}
  local bags = {[2772] = {count = 20, quality = 1}, [4306] = {count = 15, quality = 1}}
  local farm = Engine.Suggest(specCtx({mode = "farm", price = low, bags = bags}, items))
  local iron = find(farm.sections.now, function(x) return x.kind == "sell" and x.icon == 2772 end)
  eq(iron.detail, "≈ 14o 25p en la subasta, ya descontada la comisión. Hoy está un 25 % por debajo de lo normal: si no tienes prisa, espera.")
  local lazy = Engine.Suggest(specCtx({mode = "lazy", price = low, bags = bags}, items))
  local grouped = find(lazy.sections.now, function(x) return x.kind == "sell" end)
  assert(has(grouped.detail, "Acepta el precio que proponga Auctionator. Hoy Hierro y Paño de seda están por debajo de lo normal: si no tienes prisa, espera."),
    grouped.detail)
  -- Bajada de nivel (dos días seguidos muy por debajo): no es un mal día, esperar no lo arregla.
  local shifted = {[2772] = watched({10000, 10000, 10000, 10000, 8000, 10000, 8000, 8000, 10000, 7000, false, 10000, 8000, 8000})}
  local r = Engine.Suggest(specCtx({mode = "farm", price = low, bags = {[2772] = {count = 20, quality = 1}}}, shifted))
  local sell = find(r.sections.now, function(x) return x.kind == "sell" end)
  assert(not has(sell.detail, "espera"), sell.detail)
  -- Con el precio de hace días no se dice nada de hoy.
  local stale = Engine.Suggest(specCtx({mode = "farm", price = low, age = function(id) if PRICES[id] or id == 4306 then return 4 end end,
    bags = {[2772] = {count = 20, quality = 1}}}, items))
  assert(not has(find(stale.sections.now, function(x) return x.kind == "sell" end).detail, "Hoy"), "precio viejo")
end)

test("Balance de la semana: solo en Especular y solo con confianza orientativa o fiable", function()
  local up = {10000, 10000, 10000, 10000, 10000, 10000, 10000, 11200, 11200, 11200, 11200, 11200, 11200, 11200}
  local down = {10000, 10000, 10000, 10000, 10000, 10000, 10000, 9000, 9000, 9000, 9000, 9000, 9000, 9000}
  local shaky = {false, 6000, 14000, 6000, 14000, false, false, false, 6000, 14000, 6000, 14000, 10000, 6000} -- variación ±37 %: poco fiable
  local items = {[14047] = watched(up), [4306] = watched(down), [2589] = watched(shaky)}
  local r = Engine.Suggest(specCtx({mode = "spec"}, items))
  eq(#r.balance, 2)
  eq(r.balance[1].kind, "rise"); eq(r.balance[1].title, "Paño rúnico sube un 12 % en 7 días")
  eq(r.balance[1].detail, "Normal (14 d): 1o 6p. Fiable · 14 días · variación ±8,4 %.")
  eq(r.balance[2].kind, "fall"); eq(r.balance[2].title, "Paño de seda baja un 10 % en 7 días")
  eq(r.balanceText, "Por categoría, en 7 días: Tela +1 %.")
  -- Con el precio de hoy guardado, también sale.
  items[14047] = watched(up, {today = 11500})
  assert(has(Engine.Suggest(specCtx({mode = "spec"}, items)).balance[1].detail, "; hoy: 1o 15p."), "hoy")
  -- Tranquilo y A tope no tienen balance.
  eq(Engine.Suggest(specCtx({mode = "farm"}, items)).balance, nil)
end)

test("Presupuesto: entre todos los chollos no pasan de lo que tienes y, si no caben, se dice", function()
  local items = {}
  for i = 1, 12 do items[20000 + i] = watched(WORKED, {p = 6000}) end
  local r = Engine.Suggest(specCtx({mode = "spec"}, items, {budget = 2000000}))
  local total = 0
  for _, row in ipairs(rowsOf(r, "flip")) do total = total + row.flip.cost end
  assert(total <= 2000000, "gasto total " .. total)
  eq(#rowsOf(r, "flip"), 8)
  -- 8 enteros, el noveno recortado a lo que queda (se queda fuera por el límite) y 3 que ya no caben.
  assert(has(r.spec.text, "3 chollos no caben en tu presupuesto (200o): súbelo con /oro especular presupuesto <oro>."), r.spec.text)
  -- Con poco oro (25 % de 5 oros = 1o 25p) ninguno cabe: el estado lo explica.
  local poor = Engine.Suggest(specCtx({mode = "spec"}, {[14047] = watched(WORKED, {p = 6000})}, {budget = 12500}))
  eq(#rowsOf(poor, "flip"), 0)
  assert(has(poor.spec.text, "1 chollo no cabe en tu presupuesto (1o 25p): súbelo con /oro especular presupuesto <oro>."), poor.spec.text)
end)

test("Especular apagado: Tranquilo y A tope quedan como sin historial; el modo Especular sigue", function()
  local items = {[14047] = watched(WORKED, {p = 6000}), [2772] = watched(WORKED, {p = 7500})}
  local bags = {[2772] = {count = 20, quality = 1}}
  local low = function(id) if id == 2772 then return 7500 end return PRICES[id] end
  for _, mode in ipairs({"lazy", "farm"}) do
    local plain = Engine.Suggest(ctx({mode = mode, bags = bags, price = low}))
    local off = Engine.Suggest(specCtx({mode = mode, bags = bags, price = low}, items, {hints = false}))
    eq(serialize(off), serialize(plain), mode)
    local on = Engine.Suggest(specCtx({mode = mode, bags = bags, price = low}, items))
    assert(#on.sections.spec >= 1 and on.spec, mode .. ": encendido sí")
  end
  eq(#rowsOf(Engine.Suggest(specCtx({mode = "spec"}, items, {hints = false})), "flip"), 2)
end)

test("Descripción de los objetos: precio normal, el de hoy y el chollo", function()
  local items = {[14047] = watched(WORKED), [2772] = watched(WORKED, {p = 14000}), [4306] = watched({10000, 10000, 10000})}
  local c = specCtx({mode = "lazy"}, items, {books = {[14047] = {at = NOW - 60, lots = BOOK}}})
  local lines = Engine.SpecLines(c, 14047)
  eq(lines[1].left, "Normal (14 d)"); eq(lines[1].right, "1o · hoy -42 %")
  eq(lines[2].left, "Chollo: compra hasta 82 a 82p 16c como máximo; no revendas por debajo de 64p 73c")
  local high = Engine.SpecLines(c, 2772)
  eq(high[2].left, "Precio alto: 40 % por encima de lo normal")
  -- Un chollo solo orientativo: en Tranquilo la descripción no propone comprarlo (la ventana tampoco); en A tope, sí.
  c.spec.items[4338] = watched({false, false, false, 10200, 10400, 9900, 10100, 9700, 10300, 10000, 9900, 10100, 10000, 10000}, {p = 6000})
  eq(Engine.SpecLines(c, 4338)[2].left, "Precio bajo (40 % por debajo de lo normal): en Tranquilo solo se avisa de los chollos fiables")
  c.mode = "farm"
  assert(has(Engine.SpecLines(c, 4338)[2].left, "Chollo: compra hasta"), "A tope")
  c.mode = "lazy"
  eq(Engine.SpecLines(c, 4306), nil, "aprendiendo: fuera de Especular no se dice nada")
  c.mode = "spec"
  eq(Engine.SpecLines(c, 4306)[1].left, "Especular · Aprendiendo precios: 3 de 7 días")
  eq(Engine.SpecLines(c, 99999), nil, "no vigilado")
  c.mode, c.spec.hints = "farm", false
  eq(Engine.SpecLines(c, 14047), nil, "apagado")
end)

test("Subasta sin cobre: se rebaja 1 plata y el depósito se estima si no se conoce", function()
  local items = {[14047] = watched(WORKED, {p = 6000, dep = false, vendor = 1000})}
  local r = Engine.Suggest(specCtx({mode = "spec"}, items, {copperValues = false}))
  local row = rowsOf(r, "flip")[1]
  eq(row.flip.D, 600); eq(row.flip.netUnit, math.floor((10000 - 100) * 9500 / 10000))
  assert(has(row.detail, "(depósito estimado)"), row.detail)
end)

test("Escaneo de resumen (no dice cuántas hay cerca del mínimo): posible chollo, no «No compensa» por suponer 1", function()
  -- qty5 = 0: el punto viene del escaneo de resumen de Auctionator (el de su botón por defecto).
  local items = {[14047] = watched(WORKED, {p = 6000, q5 = 0})}
  for _, mode in ipairs(Engine.MODE_ORDER) do
    local c = specCtx({mode = mode}, items)
    local r = Engine.Suggest(c)
    eq(#rowsOf(r, "flip"), 0, mode .. ": sin chollo calculado")
    local checks = rowsOf(r, "check")
    eq(#checks, 1, mode)
    eq(checks[1].title, "Posible chollo: Paño rúnico a 60p (40 % por debajo de lo normal)")
    eq(checks[1].detail, "Tu escaneo no dice cuántas hay a ese precio: ábrelo en la pestaña Comprar de la subasta y el addon "
      .. "calculará la compra con lo que hay a la venta. Precio de hace 10 min. Fiable · 14 días · variación ±3 %.")
    eq(checks[1].icon, 14047); eq(checks[1].value, 0)
    eq(#checks[1].shopping, 1); eq(checks[1].shopping[1].id, 14047); eq(checks[1].shopping[1].count, 1, "1: solo para buscarlo")
    local lines = Engine.SpecLines(c, 14047)
    eq(lines[2].left, "Posible chollo: tu escaneo no dice cuántas hay a ese precio; ábrelo en la pestaña Comprar para calcular la compra")
    for _, line in ipairs(lines) do assert(not has(line.left, "No compensa"), mode .. ": " .. line.left) end
  end
  -- Al abrirlo en la subasta (300 a 60p) sale el chollo de verdad y la fila de posible chollo desaparece.
  local opened = Engine.Suggest(specCtx({mode = "spec"}, items, {books = {[14047] = {at = NOW - 60, lots = {{6000, 300}}}}}))
  eq(#rowsOf(opened, "check"), 0); eq(#rowsOf(opened, "flip"), 1)
  -- Con un chollo calculado al lado: va primero, y en Tranquilo (1 fila) es el que queda.
  local both = {[14047] = watched(WORKED, {p = 6000, q5 = 0}), [4306] = watched(WORKED, {p = 6000, q5 = 40})}
  local spec = Engine.Suggest(specCtx({mode = "spec"}, both))
  eq(#spec.sections.spec, 2); eq(spec.sections.spec[1].kind, "flip"); eq(spec.sections.spec[2].kind, "check")
  local lazy = Engine.Suggest(specCtx({mode = "lazy"}, both))
  eq(#lazy.sections.spec, 1); eq(lazy.sections.spec[1].kind, "flip"); eq(lazy.sections.spec[1].icon, 4306)
  -- Posible chollo, pero no gasta presupuesto: el chollo de al lado cabe igual.
  eq(lazy.sections.spec[1].flip.units, 40)
  -- Si el escaneo completo dice que solo hay 1 cerca del mínimo, sí es «No compensa».
  local one = {[14047] = watched(WORKED, {p = 6000, q5 = 1})}
  eq(#rowsOf(Engine.Suggest(specCtx({mode = "spec"}, one)), "check"), 0)
  eq(Engine.SpecLines(specCtx({mode = "spec"}, one), 14047)[2].left, "No compensa: ganarías solo 34p 49c (menos de 1 oro)")
  -- Material muy barato: ni con todas las unidades que admitiría (100) llega a 1 oro. Ni posible chollo ni la cuenta de
  -- 1 unidad: la descripción da la mejor posible.
  local penny = {}
  for i = 1, 14 do penny[i] = 300 end
  local tiny = {[2589] = watched(penny, {p = 180, q5 = 0})}
  local r = Engine.Suggest(specCtx({mode = "spec"}, tiny))
  eq(#r.sections.spec, 0)
  eq(Engine.SpecLines(specCtx({mode = "spec"}, tiny), 2589)[2].left, "No compensa: ganarías solo 54p (menos de 1 oro)")
end)

test("La descripción no llama «Chollo» a lo que la ventana no enseña (Tranquilo con un orientativo, precio sin hora)", function()
  local medium = {false, false, false, 10200, 10400, 9900, 10100, 9700, 10300, 10000, 9900, 10100, 10000, 10000}
  local cheap = function(id) if id == 14047 then return 6000 end return PRICES[id] end
  local cases = {
    {mode = "lazy", item = watched(medium, {p = 6000}),
     text = "Precio bajo (40 % por debajo de lo normal): en Tranquilo solo se avisa de los chollos fiables"},
    -- Escaneo propio de hace 3 h y el precio de hoy de Auctionator: se sabe el precio, no su hora (en todos los modos).
    {mode = "lazy", item = watched(WORKED, {p = 6000, ago = 3 * 3600}), price = cheap,
     text = "Precio bajo (40 % por debajo de lo normal): escanea la subasta para confirmarlo"},
    {mode = "farm", item = watched(WORKED, {p = 6000, ago = 3 * 3600}), price = cheap,
     text = "Precio bajo (40 % por debajo de lo normal): escanea la subasta para confirmarlo"},
    {mode = "spec", item = watched(WORKED, {p = 6000, ago = 3 * 3600}), price = cheap,
     text = "Precio bajo (40 % por debajo de lo normal): escanea la subasta para confirmarlo"},
  }
  for i, case in ipairs(cases) do
    local c = specCtx({mode = case.mode, price = case.price}, {[14047] = case.item})
    eq(#Engine.Suggest(c).sections.spec, 0, i .. ": la ventana no enseña nada")
    local lines = Engine.SpecLines(c, 14047)
    eq(lines[1].right, "1o · hoy -40 %", i)
    eq(lines[2].left, case.text, i)
    for _, line in ipairs(lines) do assert(not has(line.left, "Chollo"), i .. ": " .. line.left) end
  end
  -- Cuando la ventana sí lo enseña (A tope, el mismo orientativo), la descripción también.
  local farm = specCtx({mode = "farm"}, {[14047] = watched(medium, {p = 6000})})
  eq(#rowsOf(Engine.Suggest(farm), "flip"), 1)
  assert(has(Engine.SpecLines(farm, 14047)[2].left, "Chollo: compra hasta"), "A tope")
end)

test("Días para los chollos: 7 para el precio normal, 10 para un chollo (12 en Tranquilo), y se dice mientras tanto", function()
  local function flat(n) local out = {} for i = 1, n do out[i] = 10000 end return out end
  local function status(mode, n) return Engine.Suggest(specCtx({mode = mode}, {[14047] = watched(flat(n), {p = 6000})})) end
  for _, n in ipairs({7, 8, 9}) do
    local r = status("spec", n)
    eq(#rowsOf(r, "flip"), 0, n .. " días")
    assert(has(r.spec.text, "Con precio normal: 1 de 1 objeto vigilado (0 fiables). Los chollos necesitan 10 días con precio (ahora hay "
      .. n .. ")."), r.spec.text)
  end
  local ten = status("spec", 10)
  eq(#rowsOf(ten, "flip"), 1, "10 días: orientativo")
  assert(not has(ten.spec.text, "Los chollos necesitan"), ten.spec.text)
  -- Tranquilo pide confianza alta: 12 días.
  local lazy11 = status("lazy", 11)
  eq(#rowsOf(lazy11, "flip"), 0)
  assert(has(lazy11.spec.text, "Los chollos necesitan 12 días con precio (ahora hay 11)."), lazy11.spec.text)
  local lazy12 = status("lazy", 12)
  eq(#rowsOf(lazy12, "flip"), 1, "12 días en Tranquilo")
  assert(not has(lazy12.spec.text, "Los chollos necesitan"), lazy12.spec.text)
  assert(has(status("farm", 9).spec.text, "Los chollos necesitan 10 días con precio (ahora hay 9)."), "A tope")
  -- Antes de los 7 días solo sale la línea de aprendizaje (con los dos números).
  local six = status("spec", 6)
  eq(six.spec.text, "Aprendiendo precios: día 7 de 7. Haz un escaneo completo cada día: el precio normal necesita 7 días y los chollos, 10.")
end)

print(string.format("motor: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

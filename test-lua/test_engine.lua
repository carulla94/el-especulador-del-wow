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

test("Lo que falta y tienes en el banco se indica", function()
  local recipe = {product = 12404, qty = 1, reagents = {{12365, 2}}, prof = "blacksmithing"}
  local r = Engine.Suggest(ctx({mode = "farm", recipes = {recipe}, bank = {[12365] = {count = 7, quality = 1}}}))
  local craft = find(r.sections.now, function(s) return s.icon == 12404 end)
  assert(craft and has(craft.detail, "tienes 7 en el banco"), craft and craft.detail)
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

test("Banco: sugiere sacar y vender lo que vale (a tope)", function()
  local r = Engine.Suggest(ctx({mode = "farm", bank = {[3858] = {count = 40, quality = 1}}, bankAt = NOW - 2 * 86400}))
  local bank = find(r.sections.now, function(s) return s.kind == "bank" end)
  assert(bank and has(bank.detail, "40× Mineral de mitril") and has(bank.detail, "hace 2 días"), bank and bank.detail)
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

test("Límites por modo", function()
  local bags = {}
  for _, id in ipairs({2772, 2838, 4306, 4338, 14047, 2592, 2589, 2836}) do bags[id] = {count = 10, quality = 1} end
  local lazy = Engine.Suggest(ctx({bags = bags}))
  assert(#lazy.sections.now <= 4 and #lazy.sections.farm <= 1 and #lazy.sections.group <= 1)
  assert(#Engine.Suggest(ctx({mode = "farm", bags = bags})).sections.now <= 8)
end)

print(string.format("motor: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

-- Oro de Hermandad: datos estáticos.
-- IDs de objetos de WoW Classic (Forever los mantiene). Rendimientos por nodo según los datos de botín de
-- Classic (vmangos/pfQuest) y zonas por número de nodos. Sirven para ordenar sugerencias, no son exactos.
local _, ns = ...
ns = ns or {}
local Data = {}
ns.Data = Data

Data.VERSION = 2

---------------------------------------------------------------------------
-- Profesiones
---------------------------------------------------------------------------
-- skillLineID -> clave interna. Es la forma fiable: no depende del idioma del cliente.
Data.SKILLLINE = {
  [186] = "mining",        [182] = "herbalism",      [393] = "skinning",
  [164] = "blacksmithing", [202] = "engineering",    [171] = "alchemy",
  [333] = "enchanting",    [165] = "leatherworking", [197] = "tailoring",
  [185] = "cooking",       [129] = "firstaid",       [356] = "fishing",
}

-- Nombres que puede mostrar el cliente (enUS, esES de Classic y moderno, esMX) para reconocerlos por texto.
Data.PROFESSIONS = {
  mining         = {label = "Minería",           primary = true, names = {"Mining", "Minería", "Smelting", "Fundición"}},
  herbalism      = {label = "Herboristería",     primary = true, names = {"Herbalism", "Herboristería", "Botánica"}},
  skinning       = {label = "Desuello",          primary = true, names = {"Skinning", "Desuello"}},
  blacksmithing  = {label = "Herrería",          primary = true, names = {"Blacksmithing", "Herrería"}},
  engineering    = {label = "Ingeniería",        primary = true, names = {"Engineering", "Ingeniería"}},
  alchemy        = {label = "Alquimia",          primary = true, names = {"Alchemy", "Alquimia"}},
  enchanting     = {label = "Encantamiento",     primary = true, names = {"Enchanting", "Encantamiento"}},
  leatherworking = {label = "Peletería",         primary = true, names = {"Leatherworking", "Peletería", "Marroquinería"}},
  tailoring      = {label = "Sastrería",         primary = true, names = {"Tailoring", "Sastrería", "Costura"}},
  cooking        = {label = "Cocina",            names = {"Cooking", "Cocina"}},
  firstaid       = {label = "Primeros auxilios", names = {"First Aid", "Primeros auxilios"}},
  fishing        = {label = "Pesca",             names = {"Fishing", "Pesca"}},
}

-- Rango según el tope de habilidad. level = nivel de personaje que pide el instructor de una profesión principal
-- (reglas de Classic, las mismas en Forever).
Data.TIERS = {
  {max = 75,  name = "Aprendiz"},
  {max = 150, name = "Oficial",  level = 10},
  {max = 225, name = "Experto",  level = 20},
  {max = 300, name = "Artesano", level = 35},
}

-- Las secundarias no siempre se aprenden con un instructor: Experto es un libro que vende un mercader y Artesano,
-- una misión. Por tope del rango: how = "trainer", "book" o "quest"; level = nivel de personaje (nil: no pide);
-- book = el libro.
Data.SECONDARY_RANKS = {
  cooking  = {[150] = {how = "trainer", level = 10}, [225] = {how = "book", book = 16072, level = 20}, [300] = {how = "quest", level = 35}},
  firstaid = {[150] = {how = "trainer"},             [225] = {how = "book", book = 16084},             [300] = {how = "quest", level = 35}},
  fishing  = {[150] = {how = "trainer"},             [225] = {how = "book", book = 16083, level = 20}, [300] = {how = "quest", level = 35}},
}

-- Quita tildes y pasa a minúsculas para comparar nombres.
local ACCENTS = {["á"] = "a", ["é"] = "e", ["í"] = "i", ["ó"] = "o", ["ú"] = "u", ["ü"] = "u", ["ñ"] = "n",
                 ["Á"] = "a", ["É"] = "e", ["Í"] = "i", ["Ó"] = "o", ["Ú"] = "u", ["Ü"] = "u", ["Ñ"] = "n"}
function Data.Normalize(text)
  if type(text) ~= "string" then return "" end
  local out = text
  for accented, plain in pairs(ACCENTS) do out = out:gsub(accented, plain) end
  return (out:lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

local byName = {}
for key, prof in pairs(Data.PROFESSIONS) do
  byName[Data.Normalize(key)] = key
  byName[Data.Normalize(prof.label)] = key
  for _, name in ipairs(prof.names) do byName[Data.Normalize(name)] = key end
end
-- Atajos para el comando /oro amigo
for alias, key in pairs({mineria = "mining", minero = "mining", minera = "mining", herreria = "blacksmithing",
    herrero = "blacksmithing", herrera = "blacksmithing", ingenieria = "engineering", ingeniero = "engineering",
    ingeniera = "engineering", herbo = "herbalism", herborista = "herbalism", encantador = "enchanting",
    encantadora = "enchanting", encantamientos = "enchanting", sastre = "tailoring", peletero = "leatherworking",
    peletera = "leatherworking", alquimista = "alchemy", desollador = "skinning", desolladora = "skinning",
    cocinero = "cooking", cocinera = "cooking", pescador = "fishing", pescadora = "fishing"}) do
  byName[alias] = key
end

function Data.ProfessionKey(name)
  return byName[Data.Normalize(name)]
end

function Data.ProfessionKeyByID(skillLine)
  return type(skillLine) == "number" and Data.SKILLLINE[skillLine] or nil
end

Data.GATHERING = {mining = true, herbalism = true, skinning = true}

---------------------------------------------------------------------------
-- Recolección
---------------------------------------------------------------------------
-- skill = habilidad mínima; items = {itemID, unidades medias por nodo o bicho};
-- level = nivel de personaje típico de esas zonas (para no mandarte lejos en modo tranquilo);
-- rare = aparece poco y no se busca a propósito.
-- El nombre mostrado es el del primer objeto, tal como lo da el cliente en tu idioma.
Data.GATHER = {
  mining = {
    {key = "copper", skill = 1, level = {1, 20}, items = {{2770, 2}, {2835, 0.45}, {774, 0.01}, {818, 0.01}, {1210, 0.01}},
     zones = "Los Baldíos, Durotar, Dun Morogh, Bosque de Elwynn, Claros de Tirisfal, Costa Oscura"},
    {key = "tin", skill = 65, level = {15, 30}, items = {{2771, 2}, {2836, 0.4}, {1210, 0.01}, {1206, 0.01}, {1705, 0.01}, {1529, 0.01}},
     zones = "Vallefresno, Laderas de Trabalomas, Montañas Crestagrana, Los Humedales, Sierra Espolón"},
    {key = "silver", skill = 75, level = {15, 35}, rare = true, items = {{2775, 1.5}, {1206, 0.015}},
     zones = "Vallefresno, Las Mil Agujas, Laderas de Trabalomas, Tierras Altas de Arathi"},
    {key = "iron", skill = 125, level = {25, 40}, items = {{2772, 2}, {2838, 0.4}, {1529, 0.013}, {1705, 0.01}, {3864, 0.007}},
     zones = "Tierras Altas de Arathi, Montañas de Alterac, Vega de Tuercespina, Las Mil Agujas, Desolace"},
    {key = "gold", skill = 155, level = {30, 45}, rare = true, items = {{2776, 1.5}, {1529, 0.01}, {3864, 0.01}},
     zones = "Desolace, Tierras Altas de Arathi, Vega de Tuercespina, Tierras Inhóspitas"},
    {key = "mithril", skill = 175, level = {35, 50}, items = {{3858, 2}, {7912, 0.4}, {3864, 0.008}, {7909, 0.007}, {7910, 0.007}},
     zones = "Tierras del Interior, Desolace, Tanaris, Tierras Inhóspitas, Feralas"},
    {key = "truesilver", skill = 230, level = {40, 55}, rare = true, items = {{7911, 1.5}, {7909, 0.01}, {7910, 0.01}},
     zones = "Silithus, Tierras del Interior, Las Estepas Ardientes, Cráter de Un'Goro"},
    {key = "thorium", skill = 245, note = "vetas pequeñas", level = {45, 60}, items = {{10620, 2}, {12365, 0.4}, {7910, 0.008}, {12361, 0.007}, {12364, 0.007}, {12799, 0.007}, {12800, 0.007}},
     zones = "Cráter de Un'Goro, Silithus, Las Estepas Ardientes, Frondavil, Cuna del Invierno"},
    {key = "richthorium", skill = 275, note = "vetas enriquecidas", level = {50, 60}, items = {{10620, 3}, {12365, 0.4}, {12363, 0.03}, {12361, 0.008}, {12364, 0.008}, {12799, 0.008}, {7910, 0.008}, {12800, 0.007}},
     zones = "Silithus, Cuna del Invierno, Tierras de la Peste del Este, Azshara, Las Estepas Ardientes"},
  },
  herbalism = {
    {key = "peacebloom",  skill = 1,   level = {1, 15},  items = {{2447, 2}},  zones = "zonas iniciales, Los Baldíos"},
    {key = "silverleaf",  skill = 1,   level = {1, 15},  items = {{765, 2}},   zones = "zonas iniciales"},
    {key = "earthroot",   skill = 15,  level = {5, 20},  items = {{2449, 2}},  zones = "Los Baldíos, Claros de Tirisfal, Teldrassil, Dun Morogh"},
    {key = "mageroyal",   skill = 50,  level = {10, 25}, items = {{785, 2}},   zones = "Los Baldíos, Páramos de Poniente, Costa Oscura, Loch Modan"},
    {key = "briarthorn",  skill = 70,  level = {15, 30}, items = {{2450, 2}},  zones = "Los Baldíos, Páramos de Poniente, Los Humedales, Bosque del Ocaso"},
    {key = "stranglekelp", skill = 85, level = {15, 40}, items = {{3820, 2}},  zones = "bajo el agua: Vega de Tuercespina, Los Humedales, Costa Oscura"},
    {key = "bruiseweed",  skill = 100, level = {20, 35}, items = {{2453, 2}},  zones = "Los Baldíos, Sierra Espolón, Vallefresno, Laderas de Trabalomas"},
    {key = "steelbloom",  skill = 115, level = {25, 40}, items = {{3355, 2}},  zones = "Vega de Tuercespina, Sierra Espolón, Tierras Altas de Arathi"},
    {key = "kingsblood",  skill = 125, level = {25, 40}, items = {{3356, 2}},  zones = "Vega de Tuercespina, Laderas de Trabalomas, Los Humedales, Vallefresno"},
    {key = "gravemoss",   skill = 120, level = {25, 40}, rare = true, items = {{3369, 1}}, zones = "cementerios de Desolace y Bosque del Ocaso"},
    {key = "liferoot",    skill = 150, level = {30, 45}, items = {{3357, 2}},  zones = "Vega de Tuercespina, Marjal Revolcafango, Los Humedales"},
    {key = "fadeleaf",    skill = 160, level = {30, 45}, items = {{3818, 2}},  zones = "Marjal Revolcafango, Vega de Tuercespina, Tierras Altas de Arathi"},
    {key = "goldthorn",   skill = 170, level = {35, 50}, items = {{3821, 2}},  zones = "Vega de Tuercespina, Feralas, Tierras Altas de Arathi"},
    {key = "khadgar",     skill = 185, level = {35, 50}, items = {{3358, 2}},  zones = "Vega de Tuercespina, Feralas, Marjal Revolcafango"},
    {key = "wintersbite", skill = 195, level = {35, 45}, items = {{3819, 2}},  zones = "Montañas de Alterac"},
    {key = "firebloom",   skill = 205, level = {40, 55}, items = {{4625, 2}},  zones = "Tanaris, La Garganta de Fuego, Las Tierras Devastadas"},
    {key = "purplelotus", skill = 210, level = {40, 55}, items = {{8831, 2}},  zones = "Tierras del Interior, Feralas, Azshara, Tanaris"},
    {key = "arthastears", skill = 220, level = {45, 60}, items = {{8836, 2}},  zones = "Tierras de la Peste del Oeste y del Este, Frondavil"},
    {key = "sungrass",    skill = 230, level = {45, 60}, items = {{8838, 2}},  zones = "Feralas, Tierras del Interior, Azshara, Cráter de Un'Goro"},
    {key = "blindweed",   skill = 235, level = {40, 55}, items = {{8839, 2}},  zones = "Pantano de las Penas, Cráter de Un'Goro"},
    {key = "ghostmushroom", skill = 245, level = {40, 55}, rare = true, items = {{8845, 1}}, zones = "cuevas de Tierras del Interior y Desolace"},
    {key = "gromsblood",  skill = 250, level = {45, 60}, items = {{8846, 2}},  zones = "Las Tierras Devastadas, Frondavil, Desolace"},
    {key = "sansam",      skill = 260, level = {48, 60}, items = {{13464, 2}}, zones = "Azshara, Cráter de Un'Goro, Tierras de la Peste del Este"},
    {key = "dreamfoil",   skill = 270, level = {50, 60}, items = {{13463, 2}}, zones = "Cráter de Un'Goro, Azshara, Tierras de la Peste del Este, Frondavil"},
    {key = "silversage",  skill = 280, level = {50, 60}, items = {{13465, 2}}, zones = "Cuna del Invierno, Cráter de Un'Goro, Tierras de la Peste del Este"},
    {key = "plaguebloom", skill = 285, level = {52, 60}, items = {{13466, 2}}, zones = "Tierras de la Peste del Este y del Oeste, Frondavil"},
    {key = "icecap",      skill = 290, level = {53, 60}, items = {{13467, 2}}, zones = "Cuna del Invierno"},
    {key = "blacklotus",  skill = 300, level = {55, 60}, rare = true, items = {{13468, 1}}, zones = "Las Estepas Ardientes, Tierras de la Peste del Este, Silithus"},
  },
  skinning = {
    {key = "light",  skill = 1,   note = "bichos de nivel 5–20",  level = {5, 20},  items = {{2318, 1.5}, {2934, 1}, {783, 0.1}},
     zones = "Los Baldíos, Páramos de Poniente, Costa Oscura, Loch Modan"},
    {key = "medium", skill = 100, note = "bichos de nivel 20–30", level = {20, 30}, items = {{2319, 1.5}, {4232, 0.1}},
     zones = "Los Humedales, Vallefresno, Sierra Espolón, Laderas de Trabalomas"},
    {key = "heavy",  skill = 150, note = "bichos de nivel 30–40", level = {30, 40}, items = {{4234, 1.5}, {4235, 0.1}},
     zones = "Tierras Altas de Arathi, Desolace, Vega de Tuercespina"},
    {key = "thick",  skill = 200, note = "bichos de nivel 40–50", level = {40, 50}, items = {{4304, 1.5}, {8169, 0.1}},
     zones = "Feralas, Tanaris, Tierras del Interior"},
    {key = "rugged", skill = 250, note = "bichos de nivel 50–60", level = {50, 60}, items = {{8170, 1.5}, {8171, 0.1}},
     zones = "Cráter de Un'Goro, Cuna del Invierno, Silithus, Tierras de la Peste del Este"},
  },
}

-- Tela según el nivel del personaje (cualquiera puede farmearla matando humanoides).
Data.CLOTH = {
  {item = 2589,  minLevel = 5,  maxLevel = 20, mobs = "humanoides de nivel 5–20"},
  {item = 2592,  minLevel = 15, maxLevel = 30, mobs = "humanoides de nivel 15–30"},
  {item = 4306,  minLevel = 25, maxLevel = 40, mobs = "humanoides de nivel 25–40"},
  {item = 4338,  minLevel = 35, maxLevel = 50, mobs = "humanoides de nivel 35–50"},
  {item = 14047, minLevel = 48, maxLevel = 60, mobs = "humanoides de nivel 48–60"},
}

---------------------------------------------------------------------------
-- Fundición (si aún no has abierto la ventana de Minería y no tenemos tus recetas)
---------------------------------------------------------------------------
Data.SMELT = {
  {product = 2840,  qty = 1, skill = 1,   reagents = {{2770, 1}}},
  {product = 3576,  qty = 1, skill = 65,  reagents = {{2771, 1}}},
  {product = 2841,  qty = 2, skill = 65,  reagents = {{2840, 1}, {3576, 1}}},
  {product = 2842,  qty = 1, skill = 75,  reagents = {{2775, 1}}},
  {product = 3575,  qty = 1, skill = 125, reagents = {{2772, 1}}},
  {product = 3577,  qty = 1, skill = 155, reagents = {{2776, 1}}},
  {product = 3859,  qty = 1, skill = 165, reagents = {{3575, 1}, {3857, 1}}},
  {product = 3860,  qty = 1, skill = 175, reagents = {{3858, 1}}},
  {product = 6037,  qty = 1, skill = 230, reagents = {{7911, 1}}},
  {product = 12359, qty = 1, skill = 250, reagents = {{10620, 1}}},
}

-- Barra -> mineral del que sale (para saber quién de la hermandad puede conseguirla).
Data.BAR_FROM_ORE = {}
for _, smelt in ipairs(Data.SMELT) do
  if #smelt.reagents == 1 then Data.BAR_FROM_ORE[smelt.product] = smelt.reagents[1][1] end
end

-- Precio de compra a mercaderes de materiales con existencias ilimitadas (cobre por unidad).
-- Se usa si este personaje no ha comprado aún a un mercader que lo venda; lo que aprendió Auctionator (de toda la
-- cuenta) solo cuenta si no es más barato que esto.
Data.VENDOR_BUY = {
  [3857] = 500,   -- Carbón
  [2880] = 100,   -- Fundente débil
  [3466] = 2000,  -- Fundente fuerte
  [18567] = 30000, -- Fundente elemental
  [2324] = 25,    -- Tinte blanqueador
  [2604] = 50,    -- Tinte rojo
  [2320] = 10,    -- Hilo basto
  [2321] = 100,   -- Hilo fino
  [4291] = 500,   -- Hilo de seda
  [8343] = 2000,  -- Hilo pesado de seda
  [14341] = 5000, -- Hilo rúnico
  [3371] = 4,     -- Vial vacío
  [3372] = 40,    -- Vial con plomo
  [8925] = 500,   -- Vial de cristal
  [18256] = 30000, -- Vial imbuido
  [4289] = 50,    -- Sal
  [2678] = 10,    -- Especias suaves
}

---------------------------------------------------------------------------
-- Qué usa cada profesión (para cruzar tus bolsas con tu hermandad)
---------------------------------------------------------------------------
local BARS    = {2840, 3576, 2841, 2842, 3575, 3577, 3859, 3860, 6037, 12359}
local ORES    = {2770, 2771, 2775, 2772, 2776, 3858, 7911, 10620}
local STONES  = {2835, 2836, 2838, 7912, 12365}
local GEMS    = {774, 818, 1210, 1206, 1705, 1529, 3864, 7909, 7910, 12361, 12363, 12364, 12799, 12800}
local LEATHER = {2934, 2318, 783, 2319, 4232, 4234, 4235, 4304, 8169, 8170, 8171}
local CLOTH   = {2589, 2592, 4306, 4338, 14047, 14256}
local HERBS = {}
for _, node in ipairs(Data.GATHER.herbalism) do HERBS[#HERBS + 1] = node.items[1][1] end

local function set(...)
  local out = {}
  for _, list in ipairs({...}) do for _, id in ipairs(list) do out[id] = true end end
  return out
end

Data.ORES = set(ORES)
Data.DEMAND = {
  mining         = set(ORES),             -- un minero puede fundir el mineral de otros
  blacksmithing  = set(BARS, STONES, GEMS),
  engineering    = set(BARS, STONES, GEMS, CLOTH),
  alchemy        = set(HERBS),
  leatherworking = set(LEATHER),
  tailoring      = set(CLOTH),
}

-- Herramientas de profesión y objetos que nunca hay que sugerir vender.
Data.KEEP = set({2901, 7005, 5956, 6219, 10498, 6256, 6365, 6367, 12225, 19022, 9149, 6218, 6339, 11130, 11145, 16207,
                 6948, 5060, 20815})

-- Clases de objeto (Enum.ItemClass): consumibles, proyectiles y carcajes no se sugieren para la subasta
-- salvo que los fabriques tú.
Data.ITEM_CLASS = {Consumable = 0, Container = 1, Weapon = 2, Armor = 4, Reagent = 5, Projectile = 6, Tradegoods = 7,
                   Recipe = 9, Quiver = 11, Questitem = 12, Key = 13, Miscellaneous = 15}
Data.SKIP_CLASS = {[0] = true, [6] = true, [11] = true, [12] = true, [13] = true}

-- Cesta para medir si la base de datos de la subasta está al día.
Data.BASKET = {2770, 2771, 2772, 3858, 10620, 2589, 2592, 4306, 4338, 14047, 2318, 2319, 4234, 4304, 8170,
               2447, 785, 2453, 3356, 3818, 8831, 8838, 13464, 2835, 2836, 2838, 7912, 12365}

---------------------------------------------------------------------------
-- Lista vigilada del historial de precios (History.lua): 80 materiales y consumibles comunes
---------------------------------------------------------------------------
-- Las claves son las categorías de OroHermandadHist (el contrato con el subidor de la hermandad); el orden es el
-- de Data.CATEGORY_ORDER. Incluye toda la cesta de arriba. Son IDs de Classic que Forever debería mantener: el addon
-- solo vigila los que el cliente reconoce (C_Item.GetItemInfoInstant), y /oro sondeo lista los que no.
-- Sin confirmar todavía en Forever (marcados con «?»): 15417, 13931, 18254.
Data.WATCH = {
  metal     = {2770, 2771, 2772, 3858, 10620,                                -- minerales: cobre, estaño, hierro, mitril, torio
               2840, 2841, 3575, 3859, 3860, 6037, 12359, 12360},          -- lingotes: cobre, bronce, hierro, acero, mitril, veraplata, torio, arcanita
  piedra    = {2835, 2836, 2838, 7912, 12365},                             -- basta, burda, pesada, sólida, densa
  gema      = {7910, 12361, 12363, 12364, 12800},                          -- rubí estrella, zafiro azul, cristal arcano, esmeralda enorme, diamante de Azeroth
  hierba    = {2447, 785, 2453, 3356, 3357, 3818, 8831, 8838, 8846,         -- flor de paz … gromsanguina
               13463, 13464, 13465, 13466, 13467, 13468},                  -- hojasueño, sansam, salviargenta, flor de peste, setelo, loto negro
  piel      = {2318, 2319, 4234, 4304, 8170, 15417},                       -- cuero ligero, medio, pesado, grueso, basto; demosaurio (?)
  tela      = {2589, 2592, 4306, 4338, 14047, 14256, 14342},               -- lino, lana, seda, paño mágico, rúnico, tela de inferi, tela lunar
  pocion    = {3928, 13446, 13444, 13442, 5634},                           -- sanación superior y mayor, maná mayor, ira poderosa, acción libre
  elixir    = {13452, 9187, 9206, 13454},                                  -- mangosta, agilidad superior, gigantes, arcano superior
  frasco    = {13510, 13511, 13512, 13513},                                -- titanes, sabiduría destilada, poder supremo, resistencia cromática
  comida    = {13928, 13931, 18254},                                       -- calamar a la parrilla, sopa de aleta nocturna (?), tubérculo Runn Tum (?)
  venda     = {14529, 14530},                                              -- de paño rúnico y de paño rúnico gruesa
  encantar  = {11137, 11176, 16204, 16203, 14344, 20725},                  -- polvo de visión, sueño, ilusión; esencia eterna mayor; fragmento brillante grande; cristal de nexo
  elemental = {7076, 7078, 7080, 12808},                                   -- esencias de tierra, fuego, agua y no-muerte
  otro      = {12811},                                                     -- orbe de rectitud
}
Data.CATEGORY_ORDER = {"metal", "piedra", "gema", "hierba", "piel", "tela", "pocion", "elixir", "frasco", "comida",
                       "venda", "encantar", "elemental", "otro"}
Data.CATEGORY_LABELS = {
  metal = "Metal", piedra = "Piedra", gema = "Gema", hierba = "Hierba", piel = "Piel", tela = "Tela",
  pocion = "Poción", elixir = "Elixir", frasco = "Frasco", comida = "Comida", venda = "Venda",
  encantar = "Encantamiento", elemental = "Elemental", otro = "Otro",
}
Data.WATCH_EXTRA_MAX = 40 -- objetos que cada jugador puede añadir con /oro vigilar

---------------------------------------------------------------------------
-- Material exclusivo de WoW Forever (IDs vistos en guías de la beta; sin confirmar)
---------------------------------------------------------------------------
-- Solo se usan si el cliente confirma que el objeto existe (C_Item.DoesItemExistByID).
Data.FOREVER_SMELT = {
  {product = 249726, qty = 1, skill = 275, reagents = {{249426, 2}, {3857, 1}}},                 -- Azerotio: 2 pecblenda + 1 carbón
  {product = 251291, qty = 1, skill = 300, reagents = {{248815, 1}}, station = "Fundición fundida"}, -- Torio pesado
}

---------------------------------------------------------------------------
-- Nombres de reserva por si el cliente aún no ha cargado el objeto
---------------------------------------------------------------------------
local NAMES_esES = {
  [2770] = "Mineral de cobre", [2771] = "Mineral de estaño", [2775] = "Mineral de plata", [2772] = "Hierro",
  [2776] = "Mineral de oro", [3858] = "Mineral de mitril", [7911] = "Veraplata", [10620] = "Torio",
  [2840] = "Lingote de cobre", [3576] = "Lingote de estaño", [2841] = "Lingote de bronce", [2842] = "Lingote de plata",
  [3575] = "Lingote de hierro", [3577] = "Lingote de oro", [3859] = "Lingote de acero", [3860] = "Lingote de mitril",
  [6037] = "Lingote de veraplata", [12359] = "Lingote de torio", [3857] = "Carbón",
  [2835] = "Piedra basta", [2836] = "Piedra burda", [2838] = "Piedra pesada", [7912] = "Piedra sólida", [12365] = "Piedra densa",
  [774] = "Malaquita", [818] = "Ojo de tigre", [1210] = "Gema de las Sombras", [1206] = "Ágata musgosa",
  [1705] = "Piedra lunar inferior", [1529] = "Jade", [3864] = "Citrino", [7909] = "Aguamarina", [7910] = "Rubí estrella",
  [12361] = "Zafiro azul", [12363] = "Cristal Arcano", [12364] = "Esmeralda enorme", [12799] = "Ópalo grande",
  [12800] = "Diamante de Azeroth",
  [2447] = "Flor de paz", [765] = "Hojaplata", [2449] = "Raíz terrenal", [785] = "Marregal", [2450] = "Brezospina",
  [3820] = "Alga estranguladora", [2453] = "Hierba cardenal", [3355] = "Acérita salvaje", [3356] = "Sangrerregia",
  [3369] = "Musgo de tumba", [3357] = "Vidarraíz", [3818] = "Pálida", [3821] = "Espina de oro",
  [3358] = "Mostacho de Khadgar", [3819] = "Ivernalia", [4625] = "Flor de Fuego", [8831] = "Loto morado",
  [8836] = "Lágrimas de Arthas", [8838] = "Solea", [8839] = "Ciegamala", [8845] = "Champiñón fantasma",
  [8846] = "Gromsanguina", [13464] = "Sansam dorado", [13463] = "Hojasueño", [13465] = "Salviargenta de montaña",
  [13466] = "Flor de peste", [13467] = "Setelo", [13468] = "Loto negro",
  [2934] = "Restos de cuero estropeado", [2318] = "Cuero ligero", [783] = "Pellejo ligero", [2319] = "Cuero medio",
  [4232] = "Pellejo fino", [4234] = "Cuero pesado", [4235] = "Pellejo pesado", [4304] = "Cuero grueso",
  [8169] = "Pellejo grueso", [8170] = "Cuero basto", [8171] = "Pellejo basto",
  [2589] = "Paño de lino", [2592] = "Paño de lana", [4306] = "Paño de seda", [4338] = "Tela de paño mágico",
  [14047] = "Paño rúnico", [14256] = "Tela de inferi",
  [16072] = "Libro de cocina para expertos", [16083] = "Pesca para expertos: La lubina y tú",
  [16084] = "Primeros auxilios para expertos: Entre vendas",
  -- Lista vigilada (solo los nombres seguros; el resto lo da el cliente al cargar el objeto)
  [12360] = "Lingote de arcanita", [14342] = "Tela lunar",
  [13510] = "Frasco de los titanes", [13511] = "Frasco de sabiduría destilada", [13512] = "Frasco de poder supremo",
  [13513] = "Frasco de resistencia cromática", [13452] = "Elixir de la mangosta", [9206] = "Elixir de gigantes",
  [5634] = "Poción de acción libre", [11137] = "Polvo de visión", [11176] = "Polvo de sueño", [16204] = "Polvo de ilusión",
  [20725] = "Cristal de nexo", [7076] = "Esencia de tierra", [7078] = "Esencia de fuego", [7080] = "Esencia de agua",
}
local NAMES_esMX = {
  [2770] = "Mena de cobre", [2771] = "Mena de estaño", [2775] = "Mena de plata", [2772] = "Mena de hierro",
  [2776] = "Mena de oro", [3858] = "Mena de mitril", [7911] = "Mena de veraplata", [10620] = "Mena de torio",
  [2840] = "Barra de cobre", [3576] = "Barra de estaño", [2841] = "Barra de bronce", [2842] = "Barra de plata",
  [3575] = "Barra de hierro", [3577] = "Barra de oro", [3859] = "Barra de acero", [3860] = "Barra de mitril",
  [6037] = "Barra de veraplata", [12359] = "Barra de torio", [2835] = "Piedra férrea", [2449] = "Raíz de tierra",
  [4232] = "Pellejo medio", [4338] = "Paño de tejido mágico", [4625] = "Flor de fuego", [8831] = "Loto cárdeno",
  [13466] = "Flor de plaga", [14256] = "Tela vil",
}
Data.FALLBACK_NAMES = {}
function Data.ApplyLocale(locale)
  for id, name in pairs(NAMES_esES) do Data.FALLBACK_NAMES[id] = name end
  if locale == "esMX" then
    for id, name in pairs(NAMES_esMX) do Data.FALLBACK_NAMES[id] = name end
  end
end
Data.ApplyLocale(type(GetLocale) == "function" and GetLocale() or "esES")

return Data

-- Prueba la ruta moderna (Forever 1.60) con una simulación de C_TradeSkillUI / C_SkillInfo.
-- Desde la raíz del repositorio: lua5.1 test-lua/test_scan.lua
local DIR = "addon/OroHermandad/"
local ns = {}
assert(loadfile(DIR .. "Data.lua"))("OroHermandad", ns)
assert(loadfile(DIR .. "Items.lua"))("OroHermandad", ns)
_G.Enum = {
  Profession = {FirstAid = 0, Blacksmithing = 1, Leatherworking = 2, Alchemy = 3, Herbalism = 4, Cooking = 5,
                Mining = 6, Tailoring = 7, Engineering = 8, Enchanting = 9, Fishing = 10, Skinning = 11},
  TradeskillRecipeType = {Item = 1, Salvage = 2, Enchant = 3, Gathering = 4},
  CraftingReagentType = {Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3},
  TradeskillSlotDataType = {Reagent = 1, ModifiedReagent = 2, Currency = 3},
}
assert(loadfile(DIR .. "Scan.lua"))("OroHermandad", ns)
local Scan = ns.Scan
local passed, failed = 0, 0
local function test(name, fn) local ok, err = pcall(fn); if ok then passed = passed + 1 else failed = failed + 1; print("FALLO: " .. name .. "\n  " .. tostring(err)) end end

-- GetProfessions en Forever: prof1, prof2, faid, fish, cook (con huecos nil).
_G.GetProfessions = function() return 1, nil, 5, nil, 9 end
local PI = {
  [1] = {"Minería", 1, 180, 225, 2, 10, 186, 0, 0, 0, "Minería"},
  [5] = {"Primeros auxilios", 2, 120, 150, 1, 20, 129, 0, 0, 0, "Primeros auxilios"},
  [9] = {"Cooking", 3, 75, 75, 1, 30, 185, 5, 0, 0, "Cooking"},
}
_G.GetProfessionInfo = function(i) local t = PI[i]; return unpack(t, 1, 11) end

test("Profesiones por GetProfessions (skillLine, sin depender del idioma)", function()
  local profs, detail = Scan.Professions()
  assert(profs.mining == 180 and profs.firstaid == 120 and profs.cooking == 75, "profs")
  assert(detail.mining.max == 225 and detail.mining.skillLine == 186)
  assert(detail.cooking.mod == 5)
end)

test("C_SkillInfo rellena lo que falta y aguanta errores", function()
  _G.C_SkillInfo = {GetSkillLineInfoByID = function(id)
    if id == 164 then return {skillID = 164, name = "Herrería", isHeader = false, rank = 160, maxRank = 225, modifier = 0} end
    if id == 202 then error("boom") end
    return nil
  end}
  local profs = Scan.Professions()
  assert(profs.blacksmithing == 160 and profs.mining == 180)
  _G.C_SkillInfo = nil
end)

test("Sin GetProfessions: lista C_SkillInfo con tablas y padres", function()
  local saveA, saveB = _G.GetProfessions, _G.GetProfessionInfo
  _G.GetProfessions, _G.GetProfessionInfo = nil, nil
  local lines = {
    {skillID = 11, name = "Professions", isHeader = true, rank = 0, maxRank = 0, parentSkillLineID = 0},
    {skillID = 999, name = "Classic Mining", isHeader = false, rank = 50, maxRank = 300, parentSkillLineID = 186, modifier = 0},
    {skillID = 197, name = "Sastrería", isHeader = false, rank = 10, maxRank = 75, parentSkillLineID = 0, modifier = 0},
  }
  _G.C_SkillInfo = {GetNumSkillLines = function() return #lines end, GetSkillLineInfo = function(i) return lines[i] end}
  local profs = Scan.Professions()
  assert(profs.mining == 50 and profs.tailoring == 10, "fallback")
  _G.C_SkillInfo = nil
  _G.GetProfessions, _G.GetProfessionInfo = saveA, saveB
end)

-- Ventana de Minería abierta: GetChildProfessionInfo devuelve professionID 0 (sin expansiones).
local state = {ready = true, linked = false, npc = false, open = true}
local recipes = {
  [2657] = {info = {recipeID = 2657, learned = true, name = "Fundir cobre"},
            schematic = {recipeID = 2657, recipeType = 1, outputItemID = 2840, quantityMin = 1, quantityMax = 1,
              reagentSlotSchematics = {{reagentType = 1, required = true, quantityRequired = 1, dataSlotType = 1,
                                        reagents = {{itemID = 2770}}, variableQuantities = {}}}}},
  [2000] = {info = {recipeID = 2000, learned = true, isGatheringRecipe = true, name = "Filón de cobre"},
            schematic = {recipeID = 2000, recipeType = 4, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {}}},
  [3000] = {info = {recipeID = 3000, learned = false, name = "Fundir torio"},
            schematic = {recipeID = 3000, recipeType = 1, outputItemID = 12359, quantityMin = 1, quantityMax = 1,
              reagentSlotSchematics = {{reagentType = 1, required = true, quantityRequired = 1, reagents = {{itemID = 10620}}, variableQuantities = {}}}}},
  [4000] = {info = {recipeID = 4000, learned = true, name = "Encantar"},
            schematic = {recipeID = 4000, recipeType = 3, quantityMin = 1, quantityMax = 1,
              reagentSlotSchematics = {{reagentType = 1, required = true, quantityRequired = 1, reagents = {{itemID = 10940}}, variableQuantities = {}}}}},
  [5000] = {info = {recipeID = 5000, learned = true, name = "Con opcional y calidades"},
            schematic = {recipeID = 5000, recipeType = 1, outputItemID = 7777, quantityMin = 2, quantityMax = 4,
              reagentSlotSchematics = {
                {reagentType = 1, required = true, quantityRequired = 2, reagents = {{itemID = 1}, {itemID = 2}, {itemID = 3}}, variableQuantities = {}},
                {reagentType = 1, required = true, quantityRequired = 3, reagents = {{itemID = 1}}, variableQuantities = {}},
                {reagentType = 0, required = false, quantityRequired = 1, reagents = {{itemID = 50}}, variableQuantities = {}},
                {reagentType = 2, required = false, quantityRequired = 1, reagents = {{itemID = 60}}, variableQuantities = {}},
              }}},
  [6000] = {info = {recipeID = 6000, learned = true, name = "Modificador obligatorio"},
            schematic = {recipeID = 6000, recipeType = 1, outputItemID = 8888, quantityMin = 1, quantityMax = 1,
              reagentSlotSchematics = {
                {reagentType = 1, required = true, quantityRequired = 1, reagents = {{itemID = 1}}, variableQuantities = {}},
                {reagentType = 0, required = true, hiddenInCraftingForm = false, quantityRequired = 1, reagents = {{itemID = 70}}, variableQuantities = {}},
              }}},
  [7000] = {info = {recipeID = 7000, learned = true, name = "Moneda"},
            schematic = {recipeID = 7000, recipeType = 1, outputItemID = 9999, quantityMin = 1, quantityMax = 1,
              reagentSlotSchematics = {{reagentType = 1, required = true, quantityRequired = 1, dataSlotType = 3, reagents = {{currencyID = 5}}, variableQuantities = {}}}}},
  [8000] = {info = {recipeID = 8000, learned = true, name = "Sin outputItemID", hyperlink = "|cff|Hitem:4444::|h[x]|h|r"},
            schematic = {recipeID = 8000, recipeType = 1, quantityMin = 1, quantityMax = 1,
              reagentSlotSchematics = {{reagentType = 1, required = true, quantityRequired = 2, reagents = {{itemID = 2770}}, variableQuantities = {{reagent = {itemID = 2770}, quantity = 5}}}}}},
  [9000] = {info = nil}, -- GetRecipeInfo devuelve nil
}
local ids = {2657, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, "x"}
_G.C_TradeSkillUI = {
  IsTradeSkillReady = function() return state.ready end,
  IsDataSourceChanging = function() return false end,
  IsTradeSkillLinked = function() return state.linked, state.linked and "Otro" or nil end,
  IsTradeSkillGuild = function() return false end,
  IsTradeSkillGuildMember = function() return false end,
  IsNPCCrafting = function() return state.npc end,
  IsRuneforging = function() return false end,
  GetChildProfessionInfo = function() return {professionID = 0, skillLevel = 0, maxSkillLevel = 0, professionName = "", expansionName = "", sourceCounter = 0, skillModifier = 0, isPrimaryProfession = false} end,
  GetBaseProfessionInfo = function()
    if not state.open then return {professionID = 0, skillLevel = 0, maxSkillLevel = 0, professionName = "", sourceCounter = 0} end
    return {profession = 6, professionID = 186, professionName = "Minería", skillLevel = 185, maxSkillLevel = 225, skillModifier = 0, sourceCounter = 1}
  end,
  GetFilteredRecipeIDs = function() return ids end,
  GetRecipeInfo = function(id) return recipes[id] and recipes[id].info end,
  GetRecipeSchematic = function(id, isRecraft) assert(isRecraft == false); return recipes[id].schematic end,
  GetRecipeOutputItemData = function(id) return {icon = 1} end,
}

test("Ventana moderna: solo recetas de objeto aprendidas y valorables", function()
  local key, rank, list, maxRank = Scan.TradeSkill()
  assert(key == "mining" and rank == 185 and maxRank == 225, tostring(key) .. " " .. tostring(rank))
  local byProduct = {}
  for _, r in ipairs(list) do byProduct[r.product] = r end
  assert(byProduct[2840] and byProduct[2840].reagents[1][1] == 2770 and byProduct[2840].reagents[1][2] == 1 and byProduct[2840].recipeID == 2657)
  assert(not byProduct[12359], "no aprendida")
  local r = byProduct[7777]
  assert(r and r.qty == 3, "qty media")
  assert(#r.reagents == 1 and r.reagents[1][1] == 1 and r.reagents[1][2] == 5, "suma de huecos con el mismo objeto")
  assert(not byProduct[8888], "modificador obligatorio")
  assert(not byProduct[9999], "moneda")
  assert(byProduct[4444] and byProduct[4444].reagents[1][2] == 5, "hyperlink de receta + cantidad variable")
  assert(#list == 3, "total " .. #list)
end)

test("Ventana enlazada / PNJ / no lista / cerrada", function()
  state.linked = true; local k, why = Scan.TradeSkill(); assert(k == nil and why == "external"); state.linked = false
  state.npc = true; k, why = Scan.TradeSkill(); assert(k == nil and why == "external"); state.npc = false
  state.ready = false; k, why = Scan.TradeSkill(); assert(k == nil and why == "notready"); state.ready = true
  state.open = false; k, why = Scan.TradeSkill(); assert(k == nil and why == "closed"); state.open = true
end)

test("Errores del cliente no rompen", function()
  local save = C_TradeSkillUI.GetFilteredRecipeIDs
  C_TradeSkillUI.GetFilteredRecipeIDs = function() error("x") end
  local k, rank, list = Scan.TradeSkill()
  assert(k == "mining" and #list == 0)
  C_TradeSkillUI.GetFilteredRecipeIDs = save
  C_TradeSkillUI.GetRecipeSchematic = function() error("y") end
  k, rank, list = Scan.TradeSkill()
  assert(k == "mining" and #list == 0)
end)

print(string.format("%d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

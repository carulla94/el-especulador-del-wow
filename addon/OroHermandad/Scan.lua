-- Oro de Hermandad: lectura de profesiones, bolsas y recetas del personaje.
-- Usa la API moderna de Forever (C_TradeSkillUI, C_SkillInfo, C_Container, C_Bank) y, si falta, la antigua de Classic.
local _, ns = ...
local Data = ns.Data
local Scan = {}
ns.Scan = Scan

local function itemIDFromLink(link)
  return link and tonumber(link:match("item:(%d+)")) or nil
end

---------------------------------------------------------------------------
-- Profesiones
---------------------------------------------------------------------------
-- skillLineID -> clave interna. Independiente del idioma del cliente.
local SKILL_LINE_KEY = Data.SKILLLINE
Scan.SKILL_LINE_KEY = SKILL_LINE_KEY

-- Enum.Profession (ProfessionInfo.profession) -> clave interna.
local PROFESSION_ENUM_KEY = {}
do
  local names = {FirstAid = "firstaid", Blacksmithing = "blacksmithing", Leatherworking = "leatherworking",
                 Alchemy = "alchemy", Herbalism = "herbalism", Cooking = "cooking", Mining = "mining",
                 Tailoring = "tailoring", Engineering = "engineering", Enchanting = "enchanting",
                 Fishing = "fishing", Skinning = "skinning"}
  local enum = type(Enum) == "table" and type(Enum.Profession) == "table" and Enum.Profession or nil
  for enumName, key in pairs(names) do
    local value = enum and enum[enumName]
    if type(value) == "number" then PROFESSION_ENUM_KEY[value] = key end
  end
end


-- Llama a una función del cliente sin dejar que un error rompa el addon.
local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

local function pack(...) return {n = select("#", ...), ...} end

local function num(value) return type(value) == "number" and value or nil end

local function keyFor(skillLine, ...)
  local key = num(skillLine) and SKILL_LINE_KEY[skillLine]
  if key then return key end
  for i = 1, select("#", ...) do
    local name = select(i, ...)
    if type(name) == "string" and name ~= "" then
      key = Data.ProfessionKey(name)
      if key then return key end
    end
  end
  return nil
end

-- Devuelve profs[clave] = nivel (lo que usa el resto del addon) y
-- detail[clave] = {rank, max, mod, skillLine, name}.
function Scan.Professions()
  local profs, detail = {}, {}
  local function add(key, rank, maxRank, modifier, skillLine, name)
    rank = num(rank)
    if not key or not rank or rank <= 0 then return end
    if profs[key] and profs[key] >= rank then return end
    profs[key] = rank
    detail[key] = {rank = rank, max = num(maxRank), mod = num(modifier) or 0,
                   skillLine = num(skillLine), name = type(name) == "string" and name or nil}
  end

  -- 1) GetProfessions + GetProfessionInfo (los usa la propia UI de Forever).
  --    El orden de los índices cambia entre clientes: se identifica por skillLine.
  if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
    local res = pack(pcall(GetProfessions))
    if res[1] then
      for i = 2, res.n do
        local index = res[i]
        if num(index) then
          local info = pack(pcall(GetProfessionInfo, index))
          if info[1] then
            -- name, texture, rank, maxRank, numSpells, spellOffset, skillLine, rankModifier,
            -- specializationIndex, specializationOffset, skillLineName
            local name, rank, maxRank, skillLine, modifier, skillLineName =
              info[2], info[4], info[5], info[8], info[9], info[12]
            add(keyFor(skillLine, name, skillLineName), rank, maxRank, modifier, skillLine, name)
          end
        end
      end
    end
  end

  -- 2) C_SkillInfo por ID: rellena lo que falte (nil si no tienes la habilidad).
  local skillInfo = type(C_SkillInfo) == "table" and C_SkillInfo or nil
  if skillInfo and type(skillInfo.GetSkillLineInfoByID) == "function" then
    for skillLine, key in pairs(SKILL_LINE_KEY) do
      if not profs[key] then
        local line = safe(skillInfo.GetSkillLineInfoByID, skillLine)
        if type(line) == "table" and not line.isHeader then
          add(key, line.rank, line.maxRank, line.modifier, skillLine, line.name)
        end
      end
    end
  end

  -- 3) Lista de habilidades moderna (C_SkillInfo devuelve tablas).
  if next(profs) == nil and skillInfo and type(skillInfo.GetNumSkillLines) == "function"
     and type(skillInfo.GetSkillLineInfo) == "function" then
    for i = 1, num(safe(skillInfo.GetNumSkillLines)) or 0 do
      local line = safe(skillInfo.GetSkillLineInfo, i)
      if type(line) == "table" and not line.isHeader then
        local parent = num(line.parentSkillLineID)
        local skillLine = (parent and parent > 0) and parent or line.skillID
        add(keyFor(skillLine, line.name), line.rank, line.maxRank, line.modifier, skillLine, line.name)
      end
    end
  end

  -- 4) API antigua de Classic (varios valores de retorno).
  if next(profs) == nil and type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
    for i = 1, num(safe(GetNumSkillLines)) or 0 do
      local line = pack(pcall(GetSkillLineInfo, i))
      -- skillName, isHeader, isExpanded, skillRank, numTempPoints, skillModifier, skillMaxRank
      if line[1] and type(line[2]) == "string" and not line[3] then
        add(keyFor(nil, line[2]), line[5], line[8], line[7], nil, line[2])
      end
    end
  end

  return profs, detail
end


---------------------------------------------------------------------------
-- Bolsas y banco
---------------------------------------------------------------------------
local Items = ns.Items

local function numSlots(bag)
  local f = (C_Container and C_Container.GetContainerNumSlots) or _G.GetContainerNumSlots
  if type(f) ~= "function" then return 0 end
  local ok, n = pcall(f, bag)
  return ok and tonumber(n) or 0
end

-- itemID, cantidad, calidad, ligado, sin valor, enlace
local function slotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or type(info) ~= "table" then return nil end
    return info.itemID or Items.IDFromLink(info.hyperlink), info.stackCount, info.quality, info.isBound, info.hasNoValue, info.hyperlink
  end
  if type(_G.GetContainerItemInfo) == "function" then
    local _, count, _, quality, _, _, link, _, noValue, itemID = _G.GetContainerItemInfo(bag, slot)
    itemID = itemID or Items.IDFromLink(link)
    if itemID then return itemID, count, quality, nil, noValue, link end
  end
  return nil
end

local function boundFallback(bag, slot)
  if C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot then
    local ok, bound = pcall(function() return C_Item.IsBound(ItemLocation:CreateFromBagAndSlot(bag, slot)) end)
    if ok then return bound and true or false end
  end
  return nil
end

local function addContainer(into, bag)
  for slot = 1, numSlots(bag) do
    local itemID, count, quality, bound, noValue, link = slotInfo(bag, slot)
    itemID = Items.ID(itemID)
    if itemID then
      if bound == nil then bound = boundFallback(bag, slot) end
      local equipLoc, classID, subclassID = Items.Instant(itemID)
      local equip = type(equipLoc) == "string" and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG"
                    and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" and equipLoc ~= "INVTYPE_NON_EQUIP"
      local _, infoQuality, _, sellPrice = Items.Info(itemID)
      local entry = into[itemID]
      if not entry then
        entry = {count = 0, quality = quality or infoQuality, equip = equip, classID = classID, subclassID = subclassID, link = link}
        into[itemID] = entry
      end
      if entry.quality == nil then entry.quality = infoQuality end
      if noValue then entry.noValue = true; entry.vendor = 0
      elseif entry.vendor == nil and type(sellPrice) == "number" then entry.vendor = sellPrice end
      entry.count = entry.count + (tonumber(count) or 1)
      if bound then entry.bound = true end
    end
  end
end

-- Mochila, 4 bolsas y la bolsa de componentes (Forever la tiene), como hace la propia interfaz.
function Scan.BagIDs()
  local first = (Enum and Enum.BagIndex and Enum.BagIndex.Backpack) or 0
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0))
  local ids = {}
  for bag = first, last do ids[#ids + 1] = bag end
  return ids
end

function Scan.Bags()
  local bags = {}
  for _, bag in ipairs(Scan.BagIDs()) do addContainer(bags, bag) end
  return bags
end

-- Pestañas del banco compradas (Forever: Enum.BagIndex.CharacterBankTab_1..). Solo es fiable con el banco abierto.
function Scan.BankIDs(bankType)
  local ids = {}
  if type(C_Bank) == "table" and type(Enum) == "table" and type(Enum.BankType) == "table" then
    bankType = bankType or Enum.BankType.Character
    if type(C_Bank.FetchPurchasedBankTabIDs) == "function" then
      local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabIDs, bankType)
      if ok and type(tabs) == "table" then for _, id in ipairs(tabs) do ids[#ids + 1] = id end end
    end
    if #ids == 0 and type(C_Bank.FetchPurchasedBankTabData) == "function" then
      local ok, data = pcall(C_Bank.FetchPurchasedBankTabData, bankType)
      if ok and type(data) == "table" then
        for _, tab in ipairs(data) do if type(tab) == "table" and tab.ID then ids[#ids + 1] = tab.ID end end
      end
    end
    return ids
  end
  -- Clientes Classic antiguos (en Forever el -1 es el llavero, por eso solo aquí).
  if BANK_CONTAINER then ids[#ids + 1] = BANK_CONTAINER end
  if NUM_BANKBAGSLOTS then
    local base = NUM_BAG_SLOTS or 4
    for i = base + 1, base + NUM_BANKBAGSLOTS do ids[#ids + 1] = i end
  end
  return ids
end

function Scan.Bank(bankType)
  local bank = {}
  for _, bag in ipairs(Scan.BankIDs(bankType)) do addContainer(bank, bag) end
  return bank
end

---------------------------------------------------------------------------
-- Recetas de la ventana de profesión abierta
---------------------------------------------------------------------------
local function enumValue(enumName, field, default)
  local enum = type(Enum) == "table" and Enum[enumName]
  local value = type(enum) == "table" and enum[field]
  return type(value) == "number" and value or default
end

local function itemFromRecipeOutput(T, recipeID, recipeInfo)
  local out = safe(T.GetRecipeOutputItemData, recipeID)
  if type(out) == "table" then
    local id = num(out.itemID) or itemIDFromLink(type(out.hyperlink) == "string" and out.hyperlink or nil)
    if id then return id end
  end
  local link = type(recipeInfo) == "table" and recipeInfo.hyperlink
  if type(link) == "string" and link:find("|Hitem:", 1, true) then return itemIDFromLink(link) end
  return nil
end

-- Lee una receta con C_TradeSkillUI.GetRecipeSchematic. Devuelve la entrada o nil.
local function readRecipe(T, recipeID, key)
  local info = safe(T.GetRecipeInfo, recipeID)
  if type(info) ~= "table" or not info.learned then return nil end
  if info.isDummyRecipe or info.isGatheringRecipe or info.isSalvageRecipe or info.isRecraft then return nil end

  local schematic = safe(T.GetRecipeSchematic, recipeID, false)
  if type(schematic) ~= "table" then return nil end
  local ITEM = enumValue("TradeskillRecipeType", "Item", 1)
  if schematic.recipeType ~= nil and schematic.recipeType ~= ITEM then return nil end -- encantamientos, etc.

  local product = num(schematic.outputItemID) or itemFromRecipeOutput(T, recipeID, info)
  if not product or product <= 0 then return nil end

  local BASIC = enumValue("CraftingReagentType", "Basic", 1)
  local CURRENCY = enumValue("TradeskillSlotDataType", "Currency", 3)
  local reagents, index = {}, {}
  for _, slot in ipairs(type(schematic.reagentSlotSchematics) == "table" and schematic.reagentSlotSchematics or {}) do
    if type(slot) == "table" then
      if slot.reagentType == BASIC and slot.required ~= false then
        local first = type(slot.reagents) == "table" and slot.reagents[1] or nil
        local itemID = type(first) == "table" and num(first.itemID) or nil
        local qty = num(slot.quantityRequired)
        if itemID and type(slot.variableQuantities) == "table" then
          for _, vq in ipairs(slot.variableQuantities) do
            if type(vq) == "table" and type(vq.reagent) == "table" and vq.reagent.itemID == itemID and num(vq.quantity) then
              qty = vq.quantity
            end
          end
        end
        if slot.dataSlotType == CURRENCY or not itemID or itemID <= 0 or not qty or qty <= 0 then
          return nil -- material que no se puede valorar (moneda, dato roto)
        end
        if index[itemID] then
          reagents[index[itemID]][2] = reagents[index[itemID]][2] + qty
        else
          reagents[#reagents + 1] = {itemID, qty}
          index[itemID] = #reagents
        end
      elseif slot.required and not slot.hiddenInCraftingForm then
        return nil -- requiere un material a elegir: no se puede calcular el coste
      end
    end
  end
  if #reagents == 0 then return nil end

  local minMade = num(schematic.quantityMin) or 1
  local maxMade = num(schematic.quantityMax) or minMade
  return {product = product, qty = math.max(1, math.floor((minMade + maxMade) / 2)),
          reagents = reagents, prof = key, recipeID = recipeID}
end

-- API moderna (Forever 1.60 y Retail): C_TradeSkillUI.
local function modernTradeSkill(T)
  if safe(T.IsTradeSkillReady) == false then return nil, "notready" end
  if safe(T.IsDataSourceChanging) then return nil, "notready" end
  -- No guardar recetas de otro jugador, de la hermandad ni de un PNJ.
  if safe(T.IsTradeSkillLinked) or safe(T.IsTradeSkillGuild) or safe(T.IsTradeSkillGuildMember)
     or safe(T.IsNPCCrafting) or safe(T.IsRuneforging) then
    return nil, "external"
  end

  local child = safe(T.GetChildProfessionInfo)
  local base = safe(T.GetBaseProfessionInfo)
  if type(child) ~= "table" then child = nil end
  if type(base) ~= "table" then base = nil end
  local info = (child and num(child.professionID) and child.professionID ~= 0) and child or base
  if not info or not num(info.professionID) or info.professionID == 0 then return nil, "closed" end

  local skillLine = num(info.parentProfessionID) or info.professionID
  local key = SKILL_LINE_KEY[skillLine]
           or (base and SKILL_LINE_KEY[base.professionID])
           or PROFESSION_ENUM_KEY[info.profession]
           or Data.ProfessionKey(info.parentProfessionName)
           or Data.ProfessionKey(info.professionName)
           or (base and Data.ProfessionKey(base.professionName))
  if not key then return nil, "unknown" end

  local rank, maxRank = 0, nil
  for _, p in ipairs({base or {}, child or {}}) do
    if num(p.skillLevel) and p.skillLevel > rank then rank, maxRank = p.skillLevel, num(p.maxSkillLevel) end
  end
  if rank == 0 then
    local profs, detail = Scan.Professions()
    rank = profs[key] or 0
    maxRank = detail[key] and detail[key].max
  end

  local ids = safe(T.GetAllRecipeIDs)
  if type(ids) ~= "table" or #ids == 0 then ids = safe(T.GetFilteredRecipeIDs) end
  local recipes = {}
  for _, recipeID in ipairs(type(ids) == "table" and ids or {}) do
    if num(recipeID) then
      local recipe = readRecipe(T, recipeID, key)
      if recipe then recipes[#recipes + 1] = recipe end
    end
  end
  return key, rank, recipes, maxRank
end

-- API antigua de Classic (GetTradeSkillLine...). No existe en Forever; se mantiene
-- para clientes Classic Era y para las pruebas.
local function legacyTradeSkill()
  if type(GetTradeSkillLine) ~= "function" or type(GetNumTradeSkills) ~= "function" then return nil, "noapi" end
  local profName, rank, maxRank = GetTradeSkillLine()
  local key = Data.ProfessionKey(profName)
  if not key then return nil, "unknown" end
  local recipes = {}
  for i = 1, num(GetNumTradeSkills()) or 0 do
    local name, kind = GetTradeSkillInfo(i)
    if name and kind ~= "header" and kind ~= "subheader" then
      local product = type(GetTradeSkillItemLink) == "function" and itemIDFromLink(GetTradeSkillItemLink(i))
      if product then
        local minMade, maxMade = GetTradeSkillNumMade(i)
        local reagents, complete = {}, true
        for r = 1, num(GetTradeSkillNumReagents(i)) or 0 do
          local _, _, needed = GetTradeSkillReagentInfo(i, r)
          local reagentID = itemIDFromLink(GetTradeSkillReagentItemLink(i, r))
          if reagentID and needed then reagents[#reagents + 1] = {reagentID, needed} else complete = false end
        end
        if complete and #reagents > 0 then
          recipes[#recipes + 1] = {product = product, qty = math.max(1, math.floor(((minMade or 1) + (maxMade or minMade or 1)) / 2)),
                                   reagents = reagents, prof = key}
        end
      end
    end
  end
  return key, rank, recipes, maxRank
end

-- Devuelve clave de profesión, nivel, recetas aprendidas con producto y materiales, y nivel máximo.
-- Si no hay nada que leer devuelve nil y un motivo: "notready" (reintentar), "closed",
-- "external" (ventana enlazada/hermandad/PNJ), "unknown", "noapi".
function Scan.TradeSkill()
  local T = type(C_TradeSkillUI) == "table" and C_TradeSkillUI or nil
  if T and type(T.GetBaseProfessionInfo) == "function" then
    local ok, key, rank, recipes, maxRank = pcall(modernTradeSkill, T)
    if ok then return key, rank, recipes, maxRank end
    return nil, "error"
  end
  local ok, key, rank, recipes, maxRank = pcall(legacyTradeSkill)
  if ok then return key, rank, recipes, maxRank end
  return nil, "error"
end


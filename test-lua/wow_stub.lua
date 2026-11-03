-- Simulación del cliente de WoW Forever (1.60, base moderna) para cargar el addon fuera del juego.
-- Igual que el cliente real: no hay GetItemInfo/GetItemIcon globales ni API antigua de profesiones.
local Stub = {timers = {}, sent = {}, printed = {}, frames = {}, now = 1800000000, gameTime = 1000, money = 50000}

local function newObject(kind, name)
  local obj = {__kind = kind, __name = name, __scripts = {}, __events = {}, __shown = true, __text = nil, __points = {}}
  local methods = {}
  function methods:SetScript(event, fn) self.__scripts[event] = fn end
  function methods:GetScript(event) return self.__scripts[event] end
  function methods:HookScript(event, fn) self.__scripts[event] = fn end
  function methods:HasScript() return false end
  function methods:RegisterEvent(event) self.__events[event] = true end
  function methods:CreateFontString() return newObject("FontString") end
  function methods:CreateTexture() return newObject("Texture") end
  function methods:Show() self.__shown = true end
  function methods:Hide() self.__shown = false end
  function methods:SetShown(shown) self.__shown = shown and true or false end
  function methods:IsShown() return self.__shown end
  function methods:SetText(text) self.__text = text end
  function methods:GetText() return self.__text end
  function methods:GetStringHeight() return 12 end
  function methods:GetWidth() return 140 end
  function methods:SetHeight(h) self.__height = h end
  function methods:GetHeight() return self.__height or 140 end
  function methods:SetMaxLines(n) self.__maxLines = n end
  function methods:GetCenter() return 700, 500 end
  function methods:GetEffectiveScale() return 1 end
  function methods:SetPoint(...) self.__points[#self.__points + 1] = {...} end
  function methods:ClearAllPoints() self.__points = {} end
  function methods:GetPoint() local p = self.__points[1] or {"CENTER", nil, "CENTER", 0, 0}; return p[1], p[2], p[3], p[4], p[5] end
  function methods:AddLine(text) self.__lines = self.__lines or {}; table.insert(self.__lines, text) end
  function methods:AddDoubleLine(l, r) self.__lines = self.__lines or {}; table.insert(self.__lines, l .. " = " .. r) end
  return setmetatable(obj, {__index = function(t, key)
    if methods[key] then return methods[key] end
    if type(key) == "string" and key:match("^[A-Z]") and not key:match("Text$") then return function() end end
    return nil
  end})
end
Stub.newObject = newObject

-- Datos de objetos: nombre, calidad, equipLoc, precio de venta, classID
Stub.items = {
  [2772] = {"Hierro", 1, "", 5, 7}, [3575] = {"Lingote de hierro", 1, "", 10, 7},
  [2770] = {"Mineral de cobre", 1, "", 1, 7}, [2840] = {"Lingote de cobre", 1, "", 2, 7},
  [12365] = {"Piedra densa", 1, "", 25, 7}, [12404] = {"Piedra de afilar densa", 1, "", 50, 0},
  [5000] = {"Espada verde", 2, "INVTYPE_WEAPON", 300, 2}, [1000] = {"Hueso roto", 0, "", 40, 15},
  [2901] = {"Pico de minero", 1, "INVTYPE_WEAPONMAINHAND", 10, 2}, [4306] = {"Paño de seda", 1, "", 15, 7},
  [858] = {"Poción de sanación inferior", 1, "", 5, 0}, [3858] = {"Mineral de mitril", 1, "", 25, 7},
}
Stub.prices = {[2772] = 120, [3575] = 100, [2770] = 30, [2840] = 45, [12365] = 300, [12404] = 2500, [3858] = 400,
               [3860] = 600, [4306] = 60, [858] = 80, [2901] = 900,
               -- resto de la cesta de referencia, para que la cobertura de precios sea buena
               [2771] = 40, [2589] = 10, [2592] = 25, [2318] = 20, [2319] = 40, [2447] = 20, [785] = 40, [2453] = 60,
               [2835] = 8, [2836] = 15, [2838] = 40}
Stub.ages = {}

-- Contenido de bolsas: 0 mochila, 5 bolsa de componentes, 6 primera pestaña del banco.
Stub.slots = {
  [0] = {{itemID = 2772, stackCount = 20, quality = 1, isBound = false},
         {itemID = 5000, stackCount = 1, quality = 2, isBound = false},
         {itemID = 1000, stackCount = 3, quality = 0, isBound = false},
         {itemID = 2901, stackCount = 1, quality = 1, isBound = false},
         {itemID = 858, stackCount = 5, quality = 1, isBound = false}},
  [5] = {{itemID = 2770, stackCount = 40, quality = 1, isBound = false}},
  [6] = {{itemID = 3858, stackCount = 40, quality = 1, isBound = false}},
}

function Stub.install()
  _G.CreateFrame = function(kind, name, parent, template)
    local f = newObject(kind, name)
    if kind == "Frame" and template == "BasicFrameTemplateWithInset" then f.__shown = true end
    table.insert(Stub.frames, f)
    if name then _G[name] = f end
    return f
  end
  _G.UIParent = newObject("Frame")
  _G.Minimap = newObject("Frame")
  _G.GameTooltip = newObject("GameTooltip")
  _G.ItemRefTooltip = newObject("GameTooltip")
  _G.UISpecialFrames = {}
  _G.SlashCmdList = {}
  _G.print = function(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end table.insert(Stub.printed, table.concat(parts, " ")) end
  _G.time = function() return Stub.now end
  _G.GetTime = function() return Stub.gameTime end
  _G.C_Timer = {After = function(delay, fn) table.insert(Stub.timers, {at = Stub.gameTime + (delay or 0), fn = fn}) end}
  _G.UnitName = function() return "Javi" end
  _G.UnitLevel = function() return 32 end
  _G.UnitFactionGroup = function() return "Alliance" end
  _G.GetNormalizedRealmName = function() return "Forever" end
  _G.GetLocale = function() return "esES" end
  _G.IsInGuild = function() return true end
  _G.GetGuildInfo = function() return "Los Mineros" end
  _G.Ambiguate = function(name) return (name:match("^([^%-]+)")) end
  _G.GetMoney = function() return Stub.money end
  _G.C_EventUtils = {IsEventValid = function(e) return e ~= "TRADE_SKILL_UPDATE" end}
  _G.Enum = {
    BagIndex = {Backpack = 0, ReagentBag = 5, CharacterBankTab_1 = 6},
    BankType = {Character = 0, Guild = 1, Account = 2},
    TooltipDataType = {Item = 0},
    PlayerInteractionType = {Banker = 8},
    SendAddonMessageResult = {Success = 0, AddonMessageThrottle = 3, ChannelThrottle = 8, AddOnMessageLockdown = 11},
    Profession = {FirstAid = 0, Blacksmithing = 1, Leatherworking = 2, Alchemy = 3, Herbalism = 4, Cooking = 5,
                  Mining = 6, Tailoring = 7, Engineering = 8, Enchanting = 9, Fishing = 10, Skinning = 11},
    TradeskillRecipeType = {Item = 1, Salvage = 2, Enchant = 3, Gathering = 4},
    CraftingReagentType = {Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3},
    TradeskillSlotDataType = {Reagent = 1, ModifiedReagent = 2, Currency = 3},
  }
  _G.NUM_BAG_SLOTS, _G.NUM_REAGENTBAG_SLOTS, _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 4, 1, 5
  Stub.chatResults = {}
  _G.C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return 0 end,
    SendAddonMessage = function(prefix, msg, channel, target)
      local forced = table.remove(Stub.chatResults, 1)
      if forced and forced ~= 0 then return forced end
      table.insert(Stub.sent, {prefix = prefix, msg = msg, channel = channel, target = target})
      return 0
    end,
    InChatMessagingLockdown = function() return false end,
  }
  _G.TooltipDataProcessor = {AddTooltipPostCall = function(kind, fn) Stub.tooltipPost = fn end}
  _G.SOUNDKIT = {MAP_PING = 1, LOOT_WINDOW_COIN_SOUND = 2}
  Stub.sounds = {}
  _G.PlaySound = function(id) table.insert(Stub.sounds, id) end

  local items = Stub.items
  _G.C_Item = {
    GetItemInfo = function(id)
      local it = items[id]
      if not it then return nil end
      return it[1], "|Hitem:" .. id .. "|h", it[2], 10, 1, "", "", 20, it[3], 134400, it[4], it[5], 0, 0
    end,
    GetItemInfoInstant = function(id)
      local it = items[id]
      if not it then return nil end
      return id, "", "", it[3], 134400, it[5], 0
    end,
    GetItemNameByID = function(id) return items[id] and items[id][1] or nil end,
    GetItemIconByID = function() return 134400 end,
    RequestLoadItemDataByID = function(id) Stub.requested = (Stub.requested or 0) + 1 end,
    DoesItemExistByID = function(id) return items[id] ~= nil end,
  }
  _G.C_Container = {
    GetContainerNumSlots = function(bag) return Stub.slots[bag] and #Stub.slots[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot) return Stub.slots[bag] and Stub.slots[bag][slot] end,
  }
  _G.C_Bank = {FetchPurchasedBankTabIDs = function(kind) return kind == 0 and {6} or {} end}

  local prices = Stub.prices
  Stub.autoscan = false
  Stub.vendorPrices = {} -- caché de precios de mercader de Auctionator (de toda la cuenta)
  -- EventBus interno de Auctionator (como Source/Utilities/EventBusMixin.lua): listener:ReceiveEvent(nombre, ...).
  Stub.bus = {}
  local bus = {Register = function(self, listener, names)
    assert(type(listener.ReceiveEvent) == "function", "ReceiveEvent")
    for _, name in ipairs(names) do Stub.bus[name] = Stub.bus[name] or {}; table.insert(Stub.bus[name], listener) end
    return self
  end}
  local EVENTS = {full = "replicate_scan_complete", summary = "full_incremental_scan_complete",
                  prices = "incremental_prices_processed"}
  function Stub.busFire(name, ...)
    for _, listener in ipairs(Stub.bus[name] or {}) do listener:ReceiveEvent(name, ...) end
  end
  -- Una tanda de resultados de búsqueda (favoritos, pestaña Comprar, lista de la compra): no es un escaneo.
  function Stub.dbCallback() Stub.busFire(EVENTS.prices) end
  -- Fin de un escaneo: "full" (replicate) o "summary" (el de resumen, que después procesa los precios).
  function Stub.scanComplete(kind)
    if kind == "full" then Stub.busFire(EVENTS.full, {}) else Stub.busFire(EVENTS.summary, {}); Stub.busFire(EVENTS.prices) end
  end
  _G.Auctionator = {
    API = {v1 = {
      GetAuctionPriceByItemID = function(caller, id) assert(type(caller) == "string"); return prices[id] end,
      GetAuctionAgeByItemID = function(caller, id) if prices[id] then return Stub.ages[id] or 0 end end,
      GetVendorPriceByItemID = function(caller, id) return Stub.vendorPrices[id] end,
      -- Como el real: avisa con cada tanda de búsqueda (PricesProcessed) y al terminar un escaneo completo.
      RegisterForDBUpdate = function(caller, cb)
        bus:Register({ReceiveEvent = function() cb() end}, {EVENTS.prices, EVENTS.full})
      end,
      ConvertToSearchString = function(caller, term) return "\"" .. term.searchString .. "\";;;;;;;;;;;" .. (term.quantity or "") end,
      CreateShoppingList = function(caller, name, strings) Stub.shoppingList = {name = name, strings = strings} end,
      MultiSearchAdvanced = function(caller, terms) Stub.multiSearch = terms end,
    }},
    Config = {Options = {AUTOSCAN = "autoscan"}, Get = function() return Stub.autoscan end},
    EventBus = bus,
    FullScan = {Events = {ScanStart = "replicate_scan_start", ScanComplete = EVENTS.full}},
    IncrementalScan = {Events = {ScanStart = "full_incremental_scan_start", ScanComplete = EVENTS.summary,
                                 PricesProcessed = EVENTS.prices}},
    SavedState = {},
  }

  -- Mercader abierto: cada fila {id, price, stack, available, purchasable, extended}.
  Stub.merchant = {}
  _G.GetMerchantNumItems = function() return #Stub.merchant end
  _G.GetMerchantItemID = function(i) return Stub.merchant[i] and Stub.merchant[i].id end
  _G.C_MerchantFrame = {GetItemInfo = function(i)
    local m = Stub.merchant[i]
    return {price = m.price, stackCount = m.stack or 1, numAvailable = m.available or -1,
            isPurchasable = m.purchasable ~= false, isUsable = true, hasExtendedCost = m.extended or false}
  end}

  -- Profesiones (Forever: GetProfessions devuelve prof1, prof2, primeros auxilios, pesca, cocina).
  _G.GetProfessions = function() return 1, 2, nil, nil, nil end
  local PI = {[1] = {"Minería", 1, 180, 225, 2, 10, 186, 0, 0, 0, "Minería"},
              [2] = {"Herrería", 2, 160, 225, 2, 20, 164, 0, 0, 0, "Herrería"}}
  _G.GetProfessionInfo = function(i) return unpack(PI[i], 1, 11) end

  -- Ventana de herrería moderna con una receta: Piedra de afilar densa = 1 Piedra densa.
  Stub.tradeOpen = false
  _G.C_TradeSkillUI = {
    IsTradeSkillReady = function() return Stub.tradeOpen end,
    IsDataSourceChanging = function() return false end,
    IsTradeSkillLinked = function() return false end, IsTradeSkillGuild = function() return false end,
    IsTradeSkillGuildMember = function() return false end, IsNPCCrafting = function() return false end,
    GetBaseProfessionInfo = function()
      if not Stub.tradeOpen then return {professionID = 0} end
      return {professionID = 164, professionName = "Herrería", skillLevel = 160, maxSkillLevel = 225, profession = 1}
    end,
    GetChildProfessionInfo = function() return {professionID = 0} end,
    GetFilteredRecipeIDs = function() return Stub.tradeOpen and {501, 502} or {} end,
    GetRecipeInfo = function(id) return {recipeID = id, learned = id == 501} end,
    GetRecipeSchematic = function(id)
      return {recipeID = id, recipeType = 1, outputItemID = 12404, quantityMin = 1, quantityMax = 1,
              reagentSlotSchematics = {{reagentType = 1, required = true, quantityRequired = 1, reagents = {{itemID = 12365}}, dataSlotType = 1}}}
    end,
    IsGuildTradeSkillsEnabled = function() return true end,
  }

  -- Roster de la hermandad: Luis no tiene el addon, pero el roster dice que es minero.
  _G.C_GuildInfo = {GuildRoster = function() end}
  _G.C_Club = {
    GetGuildClubId = function() return 77 end,
    GetClubMembers = function() return {1, 2} end,
    GetMemberInfo = function(club, memberId)
      if memberId == 1 then return {name = "Javi", isSelf = true, profession1ID = 186, profession1Rank = 180} end
      return {name = "Luis-Forever", level = 40, profession1ID = 186, profession1Rank = 210, profession1Name = "Minería"}
    end,
  }
end

-- Ejecuta los temporizadores pendientes avanzando el reloj de juego.
function Stub.runTimers(maxSeconds)
  local limit = Stub.gameTime + (maxSeconds or 120)
  local guard = 0
  while guard < 500 do
    table.sort(Stub.timers, function(a, b) return a.at < b.at end)
    local nextTimer = Stub.timers[1]
    if not nextTimer or nextTimer.at > limit then break end
    table.remove(Stub.timers, 1)
    if nextTimer.at > Stub.gameTime then Stub.gameTime = nextTimer.at end
    nextTimer.fn()
    guard = guard + 1
  end
end

function Stub.fire(event, ...)
  for _, f in ipairs(Stub.frames) do
    if f.__events[event] and f.__scripts.OnEvent then f.__scripts.OnEvent(f, event, ...) end
  end
end

function Stub.loadAddon(dir)
  local ns = {}
  for line in io.lines(dir .. "/OroHermandad.toc") do
    if line:match("%.lua$") then assert(loadfile(dir .. "/" .. line))("OroHermandad", ns) end
  end
  return ns
end

return Stub

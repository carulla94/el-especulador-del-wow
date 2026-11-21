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
  function methods:UnregisterEvent(event) self.__events[event] = nil end
  function methods:CreateFontString() return newObject("FontString") end
  function methods:CreateTexture() return newObject("Texture") end
  function methods:Show() self.__shown = true end
  function methods:Hide() self.__shown = false end
  function methods:SetShown(shown) self.__shown = shown and true or false end
  function methods:IsShown() return self.__shown end
  function methods:SetText(text) self.__text = text end
  function methods:GetText() return self.__text end
  function methods:HighlightText() self.__highlighted = true end -- EditBox: selecciona el texto
  function methods:LockHighlight() self.__locked = true end      -- botón resaltado (el modo activo)
  function methods:UnlockHighlight() self.__locked = false end
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
-- IDs que el cliente no conoce (C_Item.GetItemInfoInstant no devuelve nada). Los demás existen, como en el juego.
Stub.unknownItems = {}

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

-- opts (0.6.0): auctionator = false (sin Auctionator) o {autoscan = bool, replicate = bool} (sus opciones de escanear al
-- abrir la subasta y de que ese escaneo sea el completo). Sin opts, como siempre (Auctionator sin escaneo al abrir).
function Stub.install(opts)
  opts = opts or {}
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
  -- Segundos enteros, como el juego (Stub.runUntil avanza Stub.now con el reloj de juego, que tiene decimales).
  _G.time = function() return math.floor(Stub.now) end
  _G.GetServerTime = function() return math.floor(Stub.now) end
  _G.date = function(format, t) return os.date(format, t or Stub.now) end
  _G.GetBuildInfo = function() return "1.60.1", "70707", "Oct 30 2026", 16001 end
  _G.C_AddOns = {GetAddOnMetadata = function(name, field)
    if name == "Auctionator" and field == "Version" then return Stub.auctionatorVersion end
  end}
  Stub.auctionatorVersion = "11.0.9-forever"
  _G.GetTime = function() return Stub.gameTime end
  Stub.timerSeq, Stub.timerCalls = 0, 0
  _G.C_Timer = {After = function(delay, fn)
    Stub.timerSeq, Stub.timerCalls = Stub.timerSeq + 1, Stub.timerCalls + 1
    table.insert(Stub.timers, {at = Stub.gameTime + (delay or 0), fn = fn, seq = Stub.timerSeq})
  end}
  _G.UnitName = function() return "Javi" end
  _G.UnitLevel = function() return 32 end
  -- "npc" es el subastador (con la subasta abierta, Stub.openAH): su facción, nil o "Neutral".
  Stub.playerFaction = "Alliance"
  _G.UnitFactionGroup = function(unit)
    if unit == "npc" then return Stub.npcFaction end
    return Stub.playerFaction
  end
  _G.UnitGUID = function(unit)
    if unit == "npc" and Stub.npcGUID then return Stub.npcGUID end
    return nil
  end
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
    -- Como el cliente: conoce cualquier objeto que exista (sin preguntar al servidor), aunque no tenga su nombre.
    GetItemInfoInstant = function(id)
      local it = items[id]
      if not it then
        if type(id) ~= "number" or id <= 0 or id >= 300000 or Stub.unknownItems[id] then return nil end
        return id, "", "", "", 134400, 7, 0
      end
      return id, "", "", it[3], 134400, it[5], it[6] or 0
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
  -- Fin de un escaneo: "full" (replicate) o "summary" (el de resumen, que después procesa los precios). Como el real,
  -- el evento lleva los resultados del escaneo (fixedScanData / rawScan): rows filas, 1000 si no se dice, hechas con
  -- Stub.scanRows. data: filas a medida en lugar de esas.
  function Stub.scanComplete(kind, rows, data)
    data = data or Stub.scanRows(kind, rows or 1000)
    if kind == "full" then Stub.busFire(EVENTS.full, data) else Stub.busFire(EVENTS.summary, data); Stub.busFire(EVENTS.prices) end
    return data
  end
  -- Marco del escaneo de resumen de Auctionator (Auctionator.State.IncrementalScanFrameRef): doingFullScan mientras dura.
  Stub.scanFrame = {doingFullScan = false}
  -- Historial interno de Auctionator (Database:GetPriceHistory): dbKey (texto) -> filas, de la más nueva a la más
  -- vieja, como en Source/Database/Mixin.lua: {date, rawDay = "2499", minSeen, maxSeen, available}.
  Stub.history, Stub.historyCalls = {}, 0
  _G.AUCTIONATOR_PRICE_DATABASE = {__dbversion = 8}
  _G.Auctionator = {
    Database = {GetPriceHistory = function(self, dbKey)
      assert(type(self) == "table" and type(dbKey) == "string", "GetPriceHistory(self, dbKey de texto)")
      Stub.historyCalls = Stub.historyCalls + 1
      if Stub.onHistory then Stub.onHistory(dbKey) end
      if Stub.historyError then error("CBOR roto") end
      return Stub.history[dbKey] or {}
    end},
    Constants = {SCAN_DAY_0 = 1577833200},
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
    Config = {Options = {AUTOSCAN = "autoscan", REPLICATE_SCAN = "replicate_scan"}, Get = function(key)
      if key == "replicate_scan" then return Stub.replicateScan end
      return Stub.autoscan
    end},
    EventBus = bus,
    FullScan = {Events = {ScanStart = "replicate_scan_start", ScanComplete = EVENTS.full}},
    IncrementalScan = {Events = {ScanStart = "full_incremental_scan_start", ScanComplete = EVENTS.summary,
                                 PricesProcessed = EVENTS.prices}},
    SavedState = {},
    State = {IncrementalScanFrameRef = Stub.scanFrame},
  }

  -- Subasta moderna (C_AuctionHouse). El depósito sale del precio de venta a un mercader; 1:4:12 entre las tres
  -- duraciones, como se midió en la beta de Forever. nil para lo que no es mercancía (Stub.notCommodity).
  -- Stub.depositFactor: 5 en la subasta neutral (Stub.openAH).
  Stub.notCommodity, Stub.depositCalls, Stub.copperValues, Stub.commodity, Stub.depositFactor = {}, 0, true, {}, 1
  _G.C_AuctionHouse = {
    CalculateCommodityDeposit = function(id, duration, quantity)
      assert(type(id) == "number" and type(duration) == "number" and type(quantity) == "number", "argumentos")
      Stub.depositCalls = Stub.depositCalls + 1
      local it = items[id]
      if Stub.notCommodity[id] or duration < 1 or duration > 3 then return nil end
      return math.ceil((it and it[4] or 10) * quantity * ({5, 20, 60})[duration] / 100) * (Stub.depositFactor or 1)
    end,
    SupportsCopperValues = function() return Stub.copperValues end,
    -- Resultados de buscar una mercancía (pestaña Comprar): Stub.commodity[id] = {{unitPrice, quantity, numOwnerItems}, ...}.
    GetNumCommoditySearchResults = function(id)
      assert(type(id) == "number", "itemID")
      return #(Stub.commodity[id] or {})
    end,
    GetCommoditySearchResultInfo = function(id, index)
      local row = (Stub.commodity[id] or {})[index]
      if not row then return nil end
      return {itemID = id, quantity = row[2], unitPrice = row[1], auctionID = index, owners = {}, totalNumberOfOwners = 1,
              numOwnerItems = row[3] or 0, containsOwnerItem = (row[3] or 0) > 0, containsAccountItem = false}
    end,
    GetItemCommodityStatus = function(location)
      assert(type(location) == "table" and location.bag and location.slot, "ItemLocation")
      local info = Stub.slots[location.bag] and Stub.slots[location.bag][location.slot]
      return info and (Stub.notCommodity[info.itemID] and 1 or 2) or 0
    end,
  }
  _G.ItemLocation = {CreateFromBagAndSlot = function(self, bag, slot) return {bag = bag, slot = slot} end}
  if opts.auctionator == false then
    _G.Auctionator, _G.AUCTIONATOR_PRICE_DATABASE = nil, nil
  elseif type(opts.auctionator) == "table" then
    Stub.autoscan, Stub.replicateScan = opts.auctionator.autoscan == true, opts.auctionator.replicate == true
  end
  Stub.installAuctionHouse()
  _G.AUCTION_DURATION_ONE, _G.AUCTION_DURATION_TWO, _G.AUCTION_DURATION_THREE = "12 horas", "24 horas", "48 horas"

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

-- Filas de un escaneo como las que Auctionator pasa con ScanComplete.
-- listings: {{id, price (por unidad), qty, lots = {{count, unitPrice, owner}, ...}}, ...}; por defecto, todo lo de
-- Stub.prices con 50 unidades (completo: lotes de 10 al precio, 5 un 4 % más caros y 35 un 20 % más caros).
-- Completo (replicate, Source_Mainline/FullScan/Mixins/Frame.lua): {replicateInfo = {GetReplicateItemInfo(i)},
-- itemLink, timeLeft}; [3] cantidad, [10] compra ya del lote, [14] vendedor, [17] itemID.
-- Resumen (IncrementalScan): BrowseResultInfo {itemKey, totalQuantity, minPrice (por unidad), containsOwnerItem}.
-- Se rellena con objetos no vigilados (IDs 200000+) hasta rows filas; con menos filas, se corta.
function Stub.defaultListings()
  local ids = {}
  for id in pairs(Stub.prices) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = {}
  for _, id in ipairs(ids) do
    local p = Stub.prices[id]
    out[#out + 1] = {id = id, price = p, qty = 50,
                     lots = {{10, p}, {5, math.floor(p * 104 / 100)}, {35, math.floor(p * 120 / 100)}}}
  end
  return out
end

function Stub.scanRows(kind, rows, listings)
  listings = listings or Stub.defaultListings()
  local data = {}
  local function replicate(id, count, unit, owner)
    local name = Stub.items[id] and Stub.items[id][1] or ("Objeto " .. id)
    return {replicateInfo = {name, 134400, count, 1, true, 1, "", 0, 0, math.floor(unit * count + 0.5), 0, nil, nil,
                             owner or "Vendedor", nil, 0, id, true},
            itemLink = "|cffffffff|Hitem:" .. id .. "::::::::32:::::|h[" .. name .. "]|h|r", timeLeft = 3}
  end
  for _, l in ipairs(listings) do
    if kind == "full" then
      for _, lot in ipairs(l.lots or {{l.qty, l.price}}) do data[#data + 1] = replicate(l.id, lot[1], lot[2], lot[3]) end
    else
      data[#data + 1] = {itemKey = {itemID = l.id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = l.pet or 0},
                         totalQuantity = l.qty, minPrice = l.price, containsOwnerItem = false}
    end
  end
  local filler = 200000
  while #data < (rows or #data) do
    filler = filler + 1
    if kind == "full" then data[#data + 1] = replicate(filler, 1, 100)
    else data[#data + 1] = {itemKey = {itemID = filler, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0},
                            totalQuantity = 1, minPrice = 100, containsOwnerItem = false} end
  end
  while rows and #data > rows do table.remove(data) end
  return data
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

---------------------------------------------------------------------------
-- 0.6.0: escáner propio (Scanner.lua). Subasta entera (replicate), búsquedas, publicar y comprar, mapas.
---------------------------------------------------------------------------
-- hooksecurefunc(tbl, name, fn) o hooksecurefunc(name, fn): la función pasa a ser una envoltura que llama a la original
-- y después a fn con los mismos argumentos. Quien la busca al llamar (el addon, el Auctionator de pruebas) pasa por ella.
function Stub.hooksecurefunc(tbl, name, fn)
  if type(tbl) == "string" then tbl, name, fn = _G, tbl, name end
  local original = tbl[name]
  assert(type(original) == "function", "hooksecurefunc: " .. tostring(name) .. " no es una función")
  tbl[name] = function(...)
    local a, b, c, d, e = original(...)
    fn(...)
    return a, b, c, d, e
  end
end

-- Una fila de la subasta entera: id, count, unit (precio por unidad) o buyout (del lote), owner (el personaje dueño:
-- el cliente solo da el nombre si es el tuyo, UnitName("player"); de los demás da shown, nil si no se dice), band
-- (0..3: el valor que devuelve el cliente es band + Stub.ah.bandBase), saleStatus, bid (solo puja), bidder (pujador),
-- uncached (al leerla, el cliente avisa otra vez cuando llegan los datos del objeto).
function Stub.row(id, count, unit, extra)
  extra = extra or {}
  return {id = id, count = count, buyout = extra.buyout or (extra.bid and 0 or math.floor(unit * count + 0.5)),
          owner = extra.owner, shown = extra.shown, band = extra.band or 3, saleStatus = extra.saleStatus or 0,
          uncached = extra.uncached, bidder = extra.bidder, name = "Objeto " .. id}
end

local function frameTimer(fn)
  Stub.timerSeq = Stub.timerSeq + 1
  table.insert(Stub.timers, {at = Stub.gameTime, fn = fn, seq = Stub.timerSeq, internal = true})
end

-- Avisos de la caché de objetos: cada fila sin datos que se lee avisa una vez (REPLICATE_ITEM_LIST_UPDATE), hasta 2000
-- por fotograma, durante la lectura y después.
local function pumpRefires()
  local ah = Stub.ah
  ah.pumping = false
  local n = math.min(ah.refirePending, 2000)
  ah.refirePending = ah.refirePending - n
  for _ = 1, n do ah.refired = ah.refired + 1; Stub.fire("REPLICATE_ITEM_LIST_UPDATE") end
  if ah.refirePending > 0 then ah.pumping = true; frameTimer(pumpRefires) end
end

function Stub.strayReplicateEvents(k)
  for _ = 1, k do Stub.fire("REPLICATE_ITEM_LIST_UPDATE") end
end

local PROTECTED = {"PostCommodity", "PostItem", "ConfirmPostCommodity", "ConfirmPostItem", "PlaceBid", "CancelAuction",
                   "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase"}

function Stub.installAuctionHouse()
  local api = _G.C_AuctionHouse
  local ah = {rows = {}, list = {}, calls = {}, answerDelay = 2, answerEvents = 3, cooldown = 900, lastSuccess = nil,
              bandBase = 1, refirePending = 0, refired = 0, ownedList = {}, ready = true, keyCached = {}, keyDelay = 0.3,
              keyPending = {}, ignore = {}, queries = {}, searchDelay = 0.3, protectedCalls = {}, asUser = false,
              usPerRow = 0, fakeMs = 0, bandInfo = {0, 1800, 7200, 43200}, refuseAll = false, nextAuctionID = 1000}
  Stub.ah = ah
  -- Pide la subasta entera. El servidor solo responde una vez cada cooldown segundos (desde la última petición que
  -- aceptó); antes, ni error ni respuesta. La respuesta llega answerDelay s después: una foto de Stub.ah.rows.
  function api.ReplicateItems()
    local t = Stub.now
    local accepted = not ah.refuseAll and not (ah.lastSuccess and t - ah.lastSuccess < ah.cooldown)
    ah.calls[#ah.calls + 1] = {at = t, game = Stub.gameTime, accepted = accepted}
    if not accepted then return end
    ah.lastSuccess = t
    -- autoBump = un itemID: si es la primera fila, cambia con cada respuesta (una subasta de verdad nunca responde dos
    -- veces lo mismo; la huella del escáner descarta una respuesta igual a la última leída).
    local first = ah.rows[1]
    if ah.autoBump and first and first.id == ah.autoBump then first.count, first.buyout = first.count + 1, first.buyout + 100 end
    local snapshot = {}
    for i, r in ipairs(ah.rows) do
      local copy = {}
      for k, v in pairs(r) do copy[k] = v end
      snapshot[i] = copy
    end
    Stub.timerSeq = Stub.timerSeq + 1
    table.insert(Stub.timers, {at = Stub.gameTime + ah.answerDelay, seq = Stub.timerSeq, internal = true, fn = function()
      ah.list = snapshot
      ah.answers = (ah.answers or 0) + 1
      for _ = 1, ah.answerEvents do Stub.fire("REPLICATE_ITEM_LIST_UPDATE") end
    end})
  end
  function api.GetNumReplicateItems() return #ah.list end
  function api.GetReplicateItemInfo(i)
    assert(type(i) == "number" and i == math.floor(i), "índice")
    ah.fakeMs = ah.fakeMs + ah.usPerRow / 1000
    if ah.onRowRead then ah.onRowRead(i) end
    local r = ah.list[i + 1]
    if not r then return nil end
    if r.uncached then
      r.uncached = false
      ah.refirePending = ah.refirePending + 1
      if not ah.pumping then ah.pumping = true; frameTimer(pumpRefires) end
    end
    local owner = r.shown
    if r.owner ~= nil and r.owner == _G.UnitName("player") then owner = r.owner end
    return r.name, 134400, r.count, 1, true, 1, "", r.bid or 0, 0, r.buyout, 0, r.bidder, r.bidder,
           owner, owner, r.saleStatus, r.id, not r.uncached
  end
  function api.GetReplicateItemTimeLeft(i)
    local r = ah.list[i + 1]
    return r and (r.band + ah.bandBase) or nil
  end
  function api.GetTimeLeftBandInfo(b)
    local lo = ah.bandInfo[b + 1]
    return lo, ({1800, 7200, 43200, 172800})[b + 1]
  end
  -- Tus subastas (pestaña Subastas): ownedList = {{status = 0 activa o 1 vendida (espera en el correo), buyoutAmount,
  -- bidder}, ...}. El pujador está ahí, como en el cliente; el addon nunca lo lee.
  function api.GetNumOwnedAuctions() return #ah.ownedList end
  function api.GetOwnedAuctionInfo(i)
    local o = ah.ownedList[i]
    if not o then return nil end
    return {auctionID = 9000 + i, itemKey = {itemID = o.id or 2772}, status = o.status or 0, quantity = o.qty or 1,
            buyoutAmount = o.buyoutAmount, bidAmount = o.bidAmount, bidder = o.bidder}
  end
  function api.IsThrottledMessageSystemReady() return ah.ready end
  -- Búsquedas: MakeItemKey, GetItemKeyInfo (nil hasta keyDelay s; entonces ITEM_KEY_ITEM_INFO_RECEIVED) y
  -- SendSearchQuery (100 por minuto; se ignora sin aviso si la clave no tiene datos o el objeto está en ignore).
  function api.MakeItemKey(id, level, suffix, pet)
    return {itemID = id, itemLevel = level or 0, itemSuffix = suffix or 0, battlePetSpeciesID = pet or 0}
  end
  function api.GetItemKeyInfo(key)
    local id = key and key.itemID
    if ah.keyCached[id] then return {itemID = id, itemName = "Objeto " .. id, isCommodity = not Stub.notCommodity[id]} end
    if not ah.keyPending[id] then
      ah.keyPending[id] = true
      Stub.timerSeq = Stub.timerSeq + 1
      table.insert(Stub.timers, {at = Stub.gameTime + ah.keyDelay, seq = Stub.timerSeq, internal = true, fn = function()
        ah.keyCached[id], ah.keyPending[id] = true, nil
        Stub.fire("ITEM_KEY_ITEM_INFO_RECEIVED", id)
      end})
    end
    return nil
  end
  function api.SendSearchQuery(key, sorts, separate)
    assert(type(key) == "table" and type(sorts) == "table" and type(separate) == "boolean", "SendSearchQuery(clave, orden, bool)")
    local id = key.itemID
    local recent = 0
    for _, q in ipairs(ah.queries) do if Stub.gameTime - q.at < 60 then recent = recent + 1 end end
    ah.queries[#ah.queries + 1] = {at = Stub.gameTime, id = id}
    if recent >= 100 or not ah.keyCached[id] or ah.ignore[id] then return end
    Stub.timerSeq = Stub.timerSeq + 1
    table.insert(Stub.timers, {at = Stub.gameTime + ah.searchDelay, seq = Stub.timerSeq, internal = true, fn = function()
      if Stub.notCommodity[id] then Stub.fire("ITEM_SEARCH_RESULTS_UPDATED", key)
      else Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", id) end
    end})
  end
  function api.GetCommoditySearchResultsQuantity(id)
    local total = 0
    for _, row in ipairs(Stub.commodity[id] or {}) do total = total + row[2] end
    return total
  end
  -- Publicar, pujar, cancelar y comprar están protegidos: solo «el jugador» (Stub.asUser) puede llamarlos.
  for _, name in ipairs(PROTECTED) do
    api[name] = function()
      if not ah.asUser then ah.protectedCalls[#ah.protectedCalls + 1] = name end
      return false
    end
  end
  Stub.ahOriginals = {}
  for k, v in pairs(api) do Stub.ahOriginals[k] = v end
  _G.hooksecurefunc = Stub.hooksecurefunc
  _G.C_Item.GetItemID = function(location)
    if type(location) ~= "table" then return nil end
    if location.itemID then return location.itemID end
    local info = Stub.slots[location.bag] and Stub.slots[location.bag][location.slot]
    return info and info.itemID
  end
  -- Mapas: Stub.mapID es el mapa del jugador; Stub.maps[id] = {parent, kind} (kind: Enum.UIMapType).
  Stub.maps = {[1453] = {1415, 3}, [1415] = {947, 2}, [1446] = {1414, 3}, [1414] = {947, 2}, [947] = {nil, 1},
               [9001] = {1446, 5}, [1519] = {1453, 5}, [2001] = {1415, 3}}
  Stub.mapID = 1453
  _G.Enum.UIMapType = {Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6}
  _G.Enum.AuctionHouseNotification = {BidPlaced = 0, AuctionRemoved = 1, AuctionWon = 2, AuctionOutbid = 3,
                                      AuctionSold = 4, AuctionExpired = 5}
  _G.Enum.AuctionHouseSortOrder = {Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4, TimeRemaining = 5}
  _G.Enum.AuctionHouseTimeLeftBand = {Short = 0, Medium = 1, Long = 2, VeryLong = 3}
  _G.C_Map = {
    GetBestMapForUnit = function(unit) if unit == "player" then return Stub.mapID end end,
    GetMapInfo = function(id)
      local m = Stub.maps[id]
      if not m then return nil end
      return {mapID = id, name = "Mapa " .. id, mapType = m[2], parentMapID = m[1] or 0}
    end,
  }
  _G.AuctionHouseFrameDisplayMode = {Buy = {"Buy"}, ItemBuy = {"ItemBuy"}, CommoditiesBuy = {"CommoditiesBuy"},
                                     ItemSell = {"ItemSell"}, CommoditiesSell = {"CommoditiesSell"},
                                     Auctions = {"Auctions"}, WoWTokenSell = {"WoWTokenSell"}}
  _G.ReloadUI = function() Stub.reloads = (Stub.reloads or 0) + 1 end
  _G.InCombatLockdown = function() return Stub.combat == true end
end

-- El jugador hace algo (publicar, comprar): las funciones protegidas solo se pueden llamar así.
function Stub.asUser(fn)
  Stub.ah.asUser = true
  local ok, err = pcall(fn)
  Stub.ah.asUser = false
  assert(ok, err)
end

-- debugprofilestop falso: avanza usPerRow microsegundos con cada GetReplicateItemInfo. nil lo quita.
function Stub.fakeProfile(usPerRow)
  if usPerRow == nil then _G.debugprofilestop = nil; Stub.ah.usPerRow = 0; return end
  Stub.ah.usPerRow = usPerRow
  _G.debugprofilestop = function() return Stub.ah.fakeMs end
end

-- Abre la subasta: o.npcFaction ("Alliance", "Horde", "Neutral"; false = el cliente no da facción; por defecto la tuya),
-- o.npcGUID, o.mapID, o.depositFactor (5 en la neutral). Muestra AuctionHouseFrame (pestaña Comprar) y lanza
-- AUCTION_HOUSE_SHOW. o.onShow(): lo que otro addon hace al mostrarse su marco, antes de que el nuestro oiga
-- AUCTION_HOUSE_SHOW (Auctionator pide ahí su escaneo completo si lo tiene activado al abrir).
function Stub.openAH(o)
  o = o or {}
  if o.npcFaction == false then Stub.npcFaction = nil else Stub.npcFaction = o.npcFaction or Stub.playerFaction end
  Stub.npcGUID = o.npcGUID or "Creature-0-4170-0-12-8719-00002A1B2C"
  if o.mapID then Stub.mapID = o.mapID end
  Stub.depositFactor = o.depositFactor or 1
  local frame = _G.AuctionHouseFrame
  if type(frame) ~= "table" or not frame.__ahStub then
    frame = Stub.newObject("Frame", "AuctionHouseFrame")
    frame.__ahStub = true
    frame.displayMode = _G.AuctionHouseFrameDisplayMode.Buy
    function frame:GetDisplayMode() return self.displayMode end
    function frame:IsListingAuctions()
      local m = _G.AuctionHouseFrameDisplayMode
      return self.displayMode == m.ItemSell or self.displayMode == m.CommoditiesSell or self.displayMode == m.WoWTokenSell
    end
    function frame:SetDisplayMode(mode) self.displayMode = mode end
    frame.CommoditiesSellFrame = {GetItem = function() return Stub.sellItem end}
    frame.ItemSellFrame = {GetItem = function() return nil end}
    _G.AuctionHouseFrame = frame
  end
  frame.displayMode = _G.AuctionHouseFrameDisplayMode.Buy
  frame:Show()
  if o.onShow then o.onShow() end
  Stub.fire("AUCTION_HOUSE_SHOW")
end

function Stub.closeAH()
  if _G.AuctionHouseFrame then _G.AuctionHouseFrame:Hide() end
  Stub.npcFaction, Stub.npcGUID = nil, nil
  Stub.fire("AUCTION_HOUSE_CLOSED")
end

-- Ejecuta los temporizadores en orden (a igual hora, el primero que se programó) avanzando el reloj de juego y la hora
-- del servidor a la vez, hasta que predicate() sea verdad o pasen maxSeconds. Devuelve si se cumplió. Sin el tope de
-- 500 temporizadores de runTimers (los escaneos grandes llevan cientos de tandas).
function Stub.runUntil(predicate, maxSeconds)
  local limit = Stub.gameTime + (maxSeconds or 120)
  for _ = 1, 5000000 do
    if predicate and predicate() then return true end
    local best, index
    for i, t in ipairs(Stub.timers) do
      if not best or t.at < best.at or (t.at == best.at and (t.seq or 0) < (best.seq or 0)) then best, index = t, i end
    end
    if not best or best.at > limit then break end
    table.remove(Stub.timers, index)
    if best.at > Stub.gameTime then
      Stub.now = Stub.now + (best.at - Stub.gameTime)
      Stub.gameTime = best.at
    end
    best.fn()
  end
  if predicate and predicate() then return true end
  if Stub.gameTime < limit then Stub.now = Stub.now + (limit - Stub.gameTime); Stub.gameTime = limit end
  return predicate == nil
end

-- Avanza seconds segundos (reloj de juego y hora del servidor) ejecutando lo que toque.
function Stub.advance(seconds) Stub.runUntil(nil, seconds) end

local function deepCopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do out[deepCopy(k, seen)] = deepCopy(v, seen) end
  return out
end
Stub.deepCopy = deepCopy

-- /reload en el mismo proceso: PLAYER_LOGOUT, copia de los SavedVariables (como si se escribieran y se volvieran a
-- leer), fuera marcos, temporizadores y ganchos, y el addon cargado otra vez con ADDON_LOADED. Devuelve su ns.
-- onLoaded(ns): entre cargar los archivos y ADDON_LOADED (para envolver funciones antes de que Core las llame).
-- skip: archivos que no se cargan esta vez (Stub.loadAddon).
function Stub.reload(dir, beforeLoad, onLoaded, skip)
  Stub.fire("PLAYER_LOGOUT")
  local db, cdb, hist = deepCopy(_G.OroHermandadDB), deepCopy(_G.OroHermandadCharDB), deepCopy(_G.OroHermandadHist)
  Stub.frames, Stub.timers = {}, {}
  for k, v in pairs(Stub.ahOriginals or {}) do _G.C_AuctionHouse[k] = v end
  if Stub.ah then Stub.ah.refirePending, Stub.ah.pumping = 0, false end
  _G.OroHermandadDB, _G.OroHermandadCharDB, _G.OroHermandadHist = db, cdb, hist
  if beforeLoad then beforeLoad() end
  local ns = Stub.loadAddon(dir, skip)
  if onLoaded then onLoaded(ns) end
  Stub.fire("ADDON_LOADED", "OroHermandad")
  return ns
end

-- SHA-256 de un archivo (las copias de los datos compartidos van fijadas así; Lua 5.1 no la trae: sha256sum o shasum).
function Stub.sha256File(path)
  for _, cmd in ipairs({"sha256sum", "shasum -a 256"}) do
    local pipe = io.popen(cmd .. " '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
    if pipe then
      local out = pipe:read("*a") or ""
      pipe:close()
      local hash = out:match("^(%x+)")
      if hash and #hash == 64 then return hash:lower() end
    end
  end
  error("no se pudo calcular el SHA-256 de " .. path .. " (hace falta sha256sum o shasum)")
end

-- Copias de test-lua/fixtures/v06 (los datos compartidos de la 0.6.0, SPEC.md §6): byte a byte las del diseño.
Stub.V06_SHA256 = {
  ["madrid-slots.json"] = "6cb2edb2be99aff756484a928084dc151191488fffc8b45d2cbe27dcf18f0a5b",
  ["points-v2.json"] = "0014ae349a489d0353aaf65e8763e1df104897dbaef61067e7fd83b2ee6ac937",
  ["p3-samples.json"] = "99c6977d26b7daed70324122c15b866516593206bfffb17375ed1a5679b7a071",
  ["sold-inference.json"] = "f09273176a21ee43c125227c149e42ce682ad36b859a6cc7cf29706e8696f83e",
  ["hist-v060.lua"] = "3d20bd7406e13f6221a20df82ecfb046862205f73dd633af36633239c6705d32",
  ["marker-v2.json"] = "a694e8f457aad01829b0a728f001ec911b246d48fa8ec097dd844dc37d244f49",
  ["timing-advice.json"] = "62b1870351a68d3552e6687ec98147ffab42590762471f49f1908e3d2f5191fc",
  ["marker-v2/first-run.lua"] = "f9fd2d0cb4a6b188f21f5e0a193cb29c0fbdd524b0dee2c9977f1e29f672a201",
  ["marker-v2/full.lua"] = "ee02a9f95c35ad03e415e8695d4442967e8a33c4023a55b34100ef1ce93f76fc",
  ["marker-v2/key-refused.lua"] = "0296f99f53d599aa684cdc0061b3948d5cd58dd245171e510cd283caf0d73d0f",
  ["marker-v2/never-accepted.lua"] = "8ff69012b1d25c4310d04e92b1b5020d4a66524700e2aec3539563417e07490e",
}
-- Las de relay-v1 (0.4.0) siguen sin cambiar.
Stub.RELAY_SHA256 = {
  ["constants.json"] = "293b0f52e6f382510ea900181b1fcfe6234148ba64c65f70912dee0dfbc296b9",
  ["obs-hash.json"] = "c83a2641974175fe4f15cb6833e887e714a6f409fd4a7e28fc13a409cb6d425f",
  ["wire.json"] = "b9c618b8abdcd83d2d916aeecdc86276f961b2aa82e084d88674b0fbf9add6e9",
  ["hist-schema1.lua"] = "32f9afd9a148487d2109af45b1faf94091c5a4c4c2a41eb736daf1037c164604",
  ["hist-schema2.lua"] = "15e09a13e526afd6e037934a7e4b30e1a01b957dbd3dc36b1f95082362922851",
}
-- Relay.lua de la 0.5.1 (git show f645d15:addon/OroHermandad/Relay.lua), para probar que los de antes siguen entendiendo.
Stub.LEGACY_RELAY_SHA256 = "f1d30bd42b0f6cdb0fc8057b082833913524588c95b931148c39689015c8d71e"

-- skip: {["Archivo.lua"] = true} que no se cargan (tras actualizar con solo un /reload, el juego carga la lista de
-- archivos de la versión anterior: sin los nuevos de la 0.6.0, Scanner.lua y Timing.lua).
Stub.NEW_IN_060 = {["Scanner.lua"] = true, ["Timing.lua"] = true}
function Stub.loadAddon(dir, skip)
  local ns = {}
  for line in io.lines(dir .. "/OroHermandad.toc") do
    if line:match("%.lua$") and not (skip and skip[line]) then assert(loadfile(dir .. "/" .. line))("OroHermandad", ns) end
  end
  return ns
end

return Stub

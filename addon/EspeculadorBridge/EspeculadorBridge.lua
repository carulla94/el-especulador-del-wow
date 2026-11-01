-- Original observer for NoobyGains/Auctioneer-Forever 12.x.
-- Experimental: source-verified, not yet validated in the Forever game client.
-- No purchases, listings, mail, chat broadcasts, or automatic game input.
local addonName = ...
local MARKET = "forever.pvp.alliance.eu"
local MAX_ITEMS = 20000
local sessionReady = false
local attached = false
local frame = CreateFrame("Frame")

local function say(message)
    print("|cffd6b56eEl Especulador del WoW:|r " .. message)
end

local function validInteger(value, low, high)
    return type(value) == "number" and value == value and
        value >= low and value <= high and value == math.floor(value)
end

local function now()
    local timestamp = GetServerTime()
    if validInteger(timestamp, 1, 10000000000) then
        return timestamp
    end
    return nil
end

local function context()
    local version, buildNumber, _, interface = GetBuildInfo()
    local faction = UnitFactionGroup("player")
    local region = GetCurrentRegion()
    local realm = GetRealmName()
    if interface ~= 16001 or type(version) ~= "string" or not version:match("^1%.60%.") then
        return nil, "Esta version del puente solo admite el cliente Forever 1.60.x / interfaz 16001."
    end
    if region ~= 3 then
        return nil, "El puente esta limitado a la region Europa."
    end
    if faction ~= "Alliance" then
        return nil, "El puente esta limitado a personajes de la Alianza."
    end
    if type(realm) ~= "string" or realm == "" then
        return nil, "El cliente no ha identificado el reino."
    end
    return {
        region = "EU", faction = "Alliance", ruleset = "pvp",
        rulesetVerification = "user-confirmed", realm = realm,
        interface = interface, buildNumber = tostring(buildNumber or ""),
    }
end

local function database()
    if EspeculadorBridgeDB == nil then
        EspeculadorBridgeDB = {
            schemaVersion = 1, source = "Auctioneer12.x", enabled = false,
            confirmedMarket = false, items = {}, lastBatchScope = "partial",
            complete = false,
        }
    end
    local db = EspeculadorBridgeDB
    if type(db) ~= "table" or db.schemaVersion ~= 1 or type(db.items) ~= "table" then
        return nil
    end
    return db
end

local function invalidate(db, reason)
    db.market = nil
    db.enabled = false
    db.confirmedMarket = false
    db.lastError = reason
    -- Preserve the observations themselves; they cannot be imported without a
    -- valid market binding and will be cleared before rebinding to a new realm.
end

local function confirmedContext()
    local db = database()
    if not db or not sessionReady then
        return nil
    end
    local metadata, reason = context()
    if not metadata then
        invalidate(db, reason)
        return nil
    end
    local prior = db.metadata
    if not db.enabled or not db.confirmedMarket or db.market ~= MARKET or
        type(prior) ~= "table" or prior.realm ~= metadata.realm or
        prior.region ~= metadata.region or prior.faction ~= metadata.faction or
        prior.interface ~= metadata.interface or prior.ruleset ~= "pvp" or
        prior.rulesetVerification ~= "user-confirmed" then
        invalidate(db, "Confirma tu mercado con /especulador confirmar EU PVP ALIANZA.")
        return nil
    end
    return db, metadata
end

local function prune(db)
    local ordered = {}
    for key, row in pairs(db.items) do
        local timestamp = type(row) == "table" and row.observedAt or 0
        ordered[#ordered + 1] = {key = key, timestamp = tonumber(timestamp) or 0}
    end
    if #ordered <= MAX_ITEMS then return end
    table.sort(ordered, function(a, b)
        if a.timestamp == b.timestamp then return tostring(a.key) < tostring(b.key) end
        return a.timestamp < b.timestamp
    end)
    for index = 1, #ordered - MAX_ITEMS do
        db.items[ordered[index].key] = nil
    end
end

local function capture(items)
    local db, metadata = confirmedContext()
    local timestamp = now()
    if not db or not timestamp or type(items) ~= "table" then return end
    if not Auctioneer or type(Auctioneer.ItemKeyKey) ~= "function" then return end
    local captured = 0
    for _, item in ipairs(items) do
        local key = type(item) == "table" and item.itemKey
        local data = type(item) == "table" and item.itemData
        local info = type(item) == "table" and item.itemInfo
        if type(key) == "table" and type(data) == "table" and
            validInteger(key.itemID, 1, 9007199254740991) and
            validInteger(key.itemLevel or 0, 0, 1000000) and
            validInteger(key.itemSuffix or 0, -1000000, 1000000) and
            validInteger(key.battlePetSpeciesID or 0, 0, 1000000) and
            validInteger(data.minPrice, 1, 1000000000000000) and
            validInteger(data.totalQuantity, 0, 10000000000) then
            -- Copy the key: never mutate an Auctioneer-owned table.
            local fullKey = {
                itemID = key.itemID, itemLevel = key.itemLevel or 0,
                itemSuffix = key.itemSuffix or 0,
                battlePetSpeciesID = key.battlePetSpeciesID or 0,
            }
            local ok, itemKey = pcall(Auctioneer.ItemKeyKey, Auctioneer, fullKey)
            if ok and type(itemKey) == "string" and #itemKey > 0 and #itemKey < 100 then
                local name = type(info) == "table" and info.itemName
                if type(name) ~= "string" or name == "" then
                    name = "Objeto " .. tostring(key.itemID)
                end
                db.items[itemKey] = {
                    itemId = key.itemID, name = name,
                    buyCopper = data.minPrice,
                    quantityObserved = data.totalQuantity,
                    observedAt = timestamp,
                    itemLevel = fullKey.itemLevel,
                    itemSuffix = fullKey.itemSuffix,
                    battlePetSpeciesID = fullKey.battlePetSpeciesID,
                }
                captured = captured + 1
            end
        end
    end
    if captured > 0 then
        db.metadata = metadata
        db.capturedAt = timestamp
        db.lastBatchCount = captured
        db.lastBatchScope = "partial"
        db.complete = false
        db.lastError = nil
        prune(db)
    end
end

local function attach()
    if attached then return end
    if not Auctioneer or type(Auctioneer.Module) ~= "function" or
        type(Auctioneer.Const) ~= "function" then
        return
    end
    local constants = Auctioneer.Const()
    if type(constants) ~= "table" or not constants.ScannerItemsCompleted then
        return
    end
    local module = Auctioneer:Module("Especulador:Bridge", "Scanner")
    function module:Boot(hook)
        hook(constants.ScannerItemsCompleted, function(_, items)
            capture(items)
        end)
    end
    attached = true
end

local function confirm()
    if not sessionReady then
        say("Espera a que tu personaje termine de entrar al mundo.")
        return
    end
    local db = database()
    if not db then
        say("El formato guardado no es compatible. Conserva una copia antes de reparar el archivo.")
        return
    end
    local metadata, reason = context()
    if not metadata then
        invalidate(db, reason)
        say(reason)
        return
    end
    local prior = db.metadata
    if type(prior) ~= "table" or prior.realm ~= metadata.realm or
        prior.region ~= metadata.region or prior.faction ~= metadata.faction or
        prior.interface ~= metadata.interface or prior.ruleset ~= "pvp" then
        db.items = {}
        db.capturedAt = nil
        db.lastBatchCount = 0
    end
    db.market = MARKET
    db.metadata = metadata
    db.enabled = true
    db.confirmedMarket = true
    db.confirmedAt = now()
    db.lastError = nil
    say("Mercado confirmado: Europa / PvP / Alianza. Esta confirmacion declara que juegas en PvP; el cliente no lo verifica por el nombre del reino.")
    say("Escanea con Auctioneer. Al terminar, usa /reload para guardar el archivo. El puente no guarda archivos continuamente.")
end

local function status()
    local db = database()
    if not db then
        say("Formato de datos desconocido; no se ha modificado.")
        return
    end
    local count = 0
    for _ in pairs(db.items) do count = count + 1 end
    say("Experimental, pendiente de validar en el cliente. Observaciones guardadas en memoria: " .. tostring(count) .. ".")
    say("Conexion con Auctioneer: " .. (attached and "modulo registrado" or "no disponible / version no compatible") .. ".")
    say(db.market == MARKET and db.enabled and "Mercado: Europa / PvP / Alianza." or "Mercado sin confirmar.")
    if db.lastError then say(db.lastError) end
    say("Cada fila conserva su propia fecha. Los resultados son parciales; cantidad total no significa unidades al precio minimo. /reload guarda los datos en disco.")
end

SLASH_ESPECULADORBRIDGE1 = "/especulador"
SlashCmdList.ESPECULADORBRIDGE = function(message)
    local command = (message or ""):match("^%s*(.-)%s*$"):upper():gsub("%s+", " ")
    if command == "CONFIRMAR EU PVP ALIANZA" then
        confirm()
    elseif command == "PAUSAR" then
        local db = database()
        if db then
            db.enabled = false
            say("Captura pausada. Se conservan las observaciones.")
        end
    else
        status()
        say("Comandos: /especulador confirmar EU PVP ALIANZA | /especulador estado | /especulador pausar")
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon == addonName then
        database()
        attach()
    elseif event == "PLAYER_LOGIN" then
        sessionReady = true
        attach()
        local db = database()
        if db and db.enabled then confirmedContext() end
    elseif event == "PLAYER_LOGOUT" then
        local db = database()
        if db then db.savedAt = now() end
    end
end)

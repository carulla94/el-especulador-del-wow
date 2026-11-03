-- Oro de Hermandad: eventos, datos guardados y comandos.
local ADDON, ns = ...
local Data, Items, Engine, Prices, Scan, Money = ns.Data, ns.Items, ns.Engine, ns.Prices, ns.Scan, ns.Money
local Guild, UI, Tooltip, Extras = ns.Guild, ns.UI, ns.Tooltip, ns.Extras
local Core = {}
ns.Core = Core

Core.VERSION = "0.2.0"

local DEFAULTS = {mode = "lazy", autoOpen = true, sound = true, tooltip = true}
local db, cdb
local lastResult
local openedByAH = false
local openNow = {}

local function say(text)
  print("|cffe6c35aOro de Hermandad:|r " .. text)
end

local function after(seconds, fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then C_Timer.After(seconds, fn) end
end

local function throttle(seconds, fn)
  local pending = false
  return function()
    if pending then return end
    pending = true
    after(seconds, function() pending = false; fn() end)
  end
end

local function safely(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then say("error en " .. label .. ": " .. tostring(err)) end
  return ok, err
end

-- Precios de Auctionator: uno por reino y facción.
local function marketKey()
  local realm = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or ""
  local faction = type(UnitFactionGroup) == "function" and UnitFactionGroup("player") or ""
  return (realm or "") .. "-" .. (faction or "")
end

local function recipeList()
  local list = {}
  for _, byProduct in pairs(cdb.recipes or {}) do
    for _, recipe in pairs(byProduct) do list[#list + 1] = recipe end
  end
  return list
end

local function cut()
  if type(db.cut) == "number" then return db.cut end
  return Prices.Cut()
end

local membersCache, membersAt = nil, -math.huge
local function members()
  local t = type(GetTime) == "function" and GetTime() or 0
  if not membersCache or t - membersAt > 5 then membersCache, membersAt = Guild.Members(), t end
  return membersCache
end
local function invalidateMembers() membersCache = nil end

function Core.Context()
  local caps = Prices.Capabilities()
  return {
    mode = db.mode,
    now = time(),
    cut = cut(),
    hasPriceSource = caps.prices,
    ageKnown = caps.age,
    autoscan = caps.autoscan,
    dbUpdatedAt = db.dbUpdated[marketKey()],
    price = Prices.Price, age = Prices.Age, vendor = Prices.Vendor, vendorBuy = Prices.VendorBuy,
    name = Items.Name, exists = Items.Exists,
    me = {name = UnitName("player"), level = UnitLevel("player"), profs = cdb.profs, profMax = cdb.profMax},
    bags = Scan.Bags(),
    bank = cdb.bank and cdb.bank.items or {}, bankAt = cdb.bank and cdb.bank.at,
    recipes = recipeList(),
    guild = members(),
  }
end

local function footer()
  local profs = {}
  for key, rank in pairs(cdb.profs or {}) do
    if Data.PROFESSIONS[key] and Data.PROFESSIONS[key].primary then profs[#profs + 1] = Data.PROFESSIONS[key].label .. " " .. rank end
  end
  table.sort(profs)
  local withAddon, manual, roster = Guild.Count()
  local text = "Tú: " .. (#profs > 0 and table.concat(profs, ", ") or "sin profesiones detectadas")
  text = text .. "  ·  Hermandad: " .. withAddon .. " con addon"
  if roster > 0 then text = text .. ", " .. roster .. " del roster" end
  if manual > 0 then text = text .. ", " .. manual .. " a mano" end
  local stats = Money.Stats()
  if stats and stats.seconds >= 300 then
    text = text .. "\nSesión: " .. Engine.Money(stats.net) .. " (" .. Engine.Money(stats.perHour) .. " por hora)"
  end
  return text
end

function Core.Refresh()
  if not UI.IsShown() then return end
  local ok, result = pcall(function() return Engine.Suggest(Core.Context()) end)
  if not ok then
    say("error al calcular sugerencias: " .. tostring(result))
    return
  end
  lastResult = result
  safely("la ventana", UI.Render, result, {footer = footer(), canShop = Prices.CanShop() or Prices.AuctionHouseOpen()})
end

local refreshSoon = function() end
local scanTradeSkillSoon = function() end
local announceSoon = function() end
local importRosterSoon = function() end
local scanBankSoon = function() end

function Core.SetMode(mode, quiet)
  if not Engine.MODES[mode] then return end
  db.mode = mode
  if not quiet then
    say("modo " .. Engine.MODES[mode].label .. ".")
    UI.Show()
  end
  Core.Refresh()
end

local function selfInfo()
  local ok, crafts = pcall(function() return Engine.TopCrafts(Core.Context(), 8) end)
  return {level = UnitLevel("player"), profs = cdb.profs, crafts = ok and crafts or {}}
end

local function updateProfessions()
  local ok, profs, detail = pcall(Scan.Professions)
  if not ok or type(profs) ~= "table" or next(profs) == nil then return end
  local changed = false
  for key, rank in pairs(profs) do if cdb.profs[key] ~= rank then changed = true end end
  for key in pairs(cdb.profs) do if not profs[key] then changed = true end end
  cdb.profs = profs
  cdb.profMax = cdb.profMax or {}
  for key, info in pairs(detail or {}) do
    if type(info) == "table" and type(info.max) == "number" and info.max > 0 then cdb.profMax[key] = info.max end
  end
  if changed then announceSoon(); refreshSoon() end
end

local tradeSkillRetries = 0
local function scanTradeSkill()
  local key, rank, recipes, maxRank = Scan.TradeSkill()
  if not key then
    -- rank trae el motivo: "notready" = la ventana aún carga datos; se reintenta unas veces.
    if rank == "notready" and tradeSkillRetries < 5 then
      tradeSkillRetries = tradeSkillRetries + 1
      scanTradeSkillSoon()
    end
    return
  end
  tradeSkillRetries = 0
  cdb.recipes[key] = cdb.recipes[key] or {}
  for _, recipe in ipairs(recipes or {}) do cdb.recipes[key][recipe.product] = recipe end
  if type(rank) == "number" and rank > 0 then cdb.profs[key] = rank end
  if type(maxRank) == "number" and maxRank > 0 then cdb.profMax[key] = maxRank end
  announceSoon()
  refreshSoon()
end

local bankOpen = false
local function scanBank()
  if not bankOpen then return end
  cdb.bank = {items = Scan.Bank(), at = time()}
  refreshSoon()
end
local function setBankOpen(open)
  if bankOpen == open then return end
  bankOpen = open
  if open then scanBankSoon() end
end

local function printStatus()
  local status = Engine.DbStatus(Core.Context(), db.mode)
  say("versión " .. Core.VERSION .. ", modo " .. Engine.MODES[db.mode].label .. ". " .. (status.text or ""))
  say(footer():gsub("\n", "  ·  "))
  if not Prices.Available() then say("Auctionator no está activo: sin él no hay precios.") end
end

local function shop()
  local wanted, order = {}, {}
  for _, item in ipairs(lastResult and lastResult.sections.now or {}) do
    for _, miss in ipairs(item.shopping or {}) do
      if not wanted[miss.id] then order[#order + 1] = miss.id end
      wanted[miss.id] = (wanted[miss.id] or 0) + miss.count
    end
  end
  local list = {}
  for _, id in ipairs(order) do list[#list + 1] = {itemID = id, count = wanted[id]} end
  local result, item = Prices.ShopFor(list)
  local messages = {
    auctionator = "lista «Oro de Hermandad» creada en Auctionator y buscando en la subasta.",
    list = "lista «Oro de Hermandad» creada en Auctionator (pestaña Compras). Ábrela en la subasta.",
    loading = "preparando la lista: el juego está cargando los nombres. Se crea sola en un momento.",
    closed = "abre la subasta y vuelve a pulsar.",
    notbuytab = "ve a la pestaña Comprar de la subasta y vuelve a pulsar.",
    none = "no falta nada.",
  }
  if result == "searchbox" and item then
    say("buscando " .. (Items.Name(item.id) or "el material") .. ": pulsa Buscar. Vuelve a pulsar para el siguiente.")
  else
    say(messages[result] or "no se pudo crear la lista.")
  end
end

local function openOptions()
  if not (Extras.OpenSettings and Extras.OpenSettings()) then
    say("opciones: /oro auto on|off, /oro minimapa on|off, /oro sonido on|off, /oro info on|off")
  end
end

local function toggleWindow()
  UI.Toggle()
  Core.Refresh()
end

---------------------------------------------------------------------------
-- Línea extra en la descripción de los objetos
---------------------------------------------------------------------------
local function tooltipLines(itemID)
  if not db or db.tooltip == false then return nil end
  local lines = {}
  local price, age, atLeast = Prices.Quote(itemID)
  if price then
    local when = ""
    if atLeast then when = " (hace más de 3 semanas)"
    elseif age == 0 then when = " (hoy)"
    elseif age then when = " (hace " .. age .. " d)" end
    lines[#lines + 1] = {left = "Subasta" .. when, right = Engine.Money(price)}
  end
  local users = Engine.FriendsWhoUse(members(), itemID, UnitName("player"))
  if #users > 0 then
    local shown = {}
    for i = 1, math.min(3, #users) do shown[i] = users[i] end
    lines[#lines + 1] = {left = "Lo usa: " .. table.concat(shown, ", ") .. (#users > 3 and "…" or "")}
  end
  local inBank = cdb and cdb.bank and cdb.bank.items and cdb.bank.items[itemID]
  if inBank and not bankOpen then lines[#lines + 1] = {left = "En tu banco", right = tostring(inBank.count)} end
  if #lines > 0 then lines[1].left = "Oro de Hermandad · " .. lines[1].left end
  return lines
end

---------------------------------------------------------------------------
-- Comandos
---------------------------------------------------------------------------
local HELP = {
  "/oro — abre o cierra la ventana (también con el botón del minimapa)",
  "/oro tranquilo — sugerencias sin desviarte de lo que estés haciendo",
  "/oro atope — sesión solo para hacer oro: rutas, recetas y hermandad",
  "/oro estado — precios, profesiones y hermandad",
  "/oro comprar — crea en Auctionator la lista de lo que falta para tus recetas",
  "/oro sesion — oro ganado en esta sesión  ·  /oro sesion reset",
  "/oro amigo Ana ingenieria 150 — añade a alguien a mano  ·  /oro amigo borrar Ana",
  "/oro sync — pide a la hermandad que comparta sus datos",
  "/oro comision 5 — porcentaje que se queda la subasta (por defecto 5)",
  "/oro opciones — panel de opciones (también: auto, minimapa, sonido, info on|off)",
}

local ON = {on = true, si = true, activar = true, encender = true, ["1"] = true}
local OFF = {off = true, no = true, desactivar = true, apagar = true, ["0"] = true}
local function onOff(word, current)
  word = Data.Normalize(word or "")
  if word == "" then return not current end
  if ON[word] then return true end
  if OFF[word] then return false end
  return nil
end

local function setFlag(label, word, get, set)
  local value = onOff(word, get())
  if value == nil then say("uso: /oro " .. label .. " on|off"); return end
  set(value)
  say(label .. ": " .. (value and "activado" or "desactivado") .. ".")
end

local function handleSlash(input)
  local args = {}
  for word in (input or ""):gmatch("%S+") do args[#args + 1] = word end
  local cmd = Data.Normalize(args[1] or "")
  if cmd == "" then
    toggleWindow()
  elseif cmd == "tranquilo" or cmd == "lazy" then
    Core.SetMode("lazy")
  elseif cmd == "atope" or cmd == "tope" or cmd == "farm" or (cmd == "a" and Data.Normalize(args[2] or "") == "tope") then
    Core.SetMode("farm")
  elseif cmd == "estado" or cmd == "status" then
    printStatus()
  elseif cmd == "comprar" then
    if not lastResult then lastResult = Engine.Suggest(Core.Context()) end
    shop()
  elseif cmd == "sync" then
    Guild.Announce(); Guild.Request(); importRosterSoon()
    say("pedido enviado a la hermandad.")
  elseif cmd == "auto" then
    setFlag("auto", args[2], function() return db.autoOpen end, function(v) db.autoOpen = v end)
  elseif cmd == "sonido" then
    setFlag("sonido", args[2], function() return db.sound end, function(v) db.sound = v end)
  elseif cmd == "info" or cmd == "tooltip" then
    setFlag("info", args[2], function() return db.tooltip ~= false end, function(v) db.tooltip = v end)
  elseif cmd == "minimapa" then
    setFlag("minimapa", args[2], function() return db.minimap.show ~= false end, function(v) Extras.SetMinimapShown(v) end)
  elseif cmd == "opciones" or cmd == "config" then
    openOptions()
  elseif cmd == "sesion" then
    if Data.Normalize(args[2] or "") == "reset" then Money.Start(cdb, true); say("sesión reiniciada."); return end
    local s = Money.Stats()
    if not s then say("sin datos de sesión todavía."); return end
    say(string.format("sesión de %d min: %s netos (%s por hora). Ganado %s, gastado %s.", math.floor(s.seconds / 60),
      Engine.Money(s.net), Engine.Money(s.perHour), Engine.Money(s.earned), Engine.Money(s.spent)))
  elseif cmd == "comision" then
    local pct = tonumber(args[2] or "")
    if pct and pct >= 0 and pct < 50 then
      db.cut = pct / 100
      say("comisión de la subasta: " .. pct .. " %.")
      refreshSoon()
    else
      say("uso: /oro comision 5 (porcentaje). Ahora: " .. math.floor(cut() * 1000 + 0.5) / 10 .. " %.")
    end
  elseif cmd == "amigo" then
    if Data.Normalize(args[2] or "") == "borrar" and args[3] then
      local removed = Guild.Remove(args[3])
      say(removed and (removed .. " eliminado.") or ("no encuentro a " .. args[3] .. "."))
      invalidateMembers(); refreshSoon()
    else
      local name, profKey, rank = args[2], Data.ProfessionKey(args[3] or ""), tonumber(args[4] or "")
      local saved = name and profKey and rank and Guild.SetManual(name, profKey, rank)
      if not saved then
        say("uso: /oro amigo Nombre profesión nivel (ej.: /oro amigo Ana ingenieria 150)")
      else
        say(saved .. ": " .. Data.PROFESSIONS[profKey].label .. " " .. math.floor(rank) .. ".")
        invalidateMembers(); refreshSoon()
      end
    end
  else
    for _, line in ipairs(HELP) do say(line) end
  end
end

---------------------------------------------------------------------------
-- Eventos
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
  if name ~= ADDON then return end
  OroHermandadDB = type(OroHermandadDB) == "table" and OroHermandadDB or {}
  OroHermandadCharDB = type(OroHermandadCharDB) == "table" and OroHermandadCharDB or {}
  db, cdb = OroHermandadDB, OroHermandadCharDB
  for key, value in pairs(DEFAULTS) do if db[key] == nil then db[key] = value end end
  if not Engine.MODES[db.mode] then db.mode = "lazy" end
  db.window = type(db.window) == "table" and db.window or {}
  db.prices = type(db.prices) == "table" and db.prices or {}
  db.dbUpdated = type(db.dbUpdated) == "table" and db.dbUpdated or {}
  db.lastDBUpdate = nil -- formato de la versión 0.1
  cdb.profs = type(cdb.profs) == "table" and cdb.profs or {}
  cdb.profMax = type(cdb.profMax) == "table" and cdb.profMax or {}
  cdb.recipes = type(cdb.recipes) == "table" and cdb.recipes or {}

  refreshSoon = throttle(0.5, Core.Refresh)
  scanTradeSkillSoon = throttle(1, scanTradeSkill)
  announceSoon = throttle(30, function() Guild.Announce() end)
  importRosterSoon = throttle(5, function()
    Guild.UpdateKey()
    if Guild.ImportRoster() > 0 then invalidateMembers(); refreshSoon() end
  end)
  scanBankSoon = throttle(0.5, scanBank)

  SLASH_OROHERMANDAD1, SLASH_OROHERMANDAD2 = "/oro", "/orohermandad"
  SlashCmdList.OROHERMANDAD = handleSlash

  Prices.Init(db.prices)
  Guild.Init(db, selfInfo)
  safely("la ventana", UI.Create, {position = db.window, onMode = Core.SetMode, onRefresh = Core.Refresh,
    onShop = shop, onOptions = openOptions})
  Extras.Init(db, toggleWindow, openOptions)
  Extras.RegisterSettings(Core)
  Tooltip.Install(tooltipLines)
end

function handlers.PLAYER_LOGIN()
  Prices.Watch(function()
    db.dbUpdated[marketKey()] = time()
    refreshSoon()
  end)
  Prices.HookInvoices()
  updateProfessions()
  safely("el botón del minimapa", Extras.CreateMinimapButton)
  if type(C_GuildInfo) == "table" and type(C_GuildInfo.GuildRoster) == "function" then pcall(C_GuildInfo.GuildRoster) end
  after(15, function() Guild.UpdateKey(); Guild.Announce(); Guild.Request(); importRosterSoon() end)
  after(8, function()
    local ok, status = pcall(function() return Engine.DbStatus(Core.Context(), db.mode) end)
    local text = "modo " .. Engine.MODES[db.mode].label .. ". Escribe /oro o pulsa el botón del minimapa."
    if ok and status.level ~= "ok" then text = text .. " |cffffc733" .. status.text .. "|r" end
    say(text)
  end)
end

function handlers.PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)
  Money.Start(cdb, isInitialLogin and not isReloadingUi)
end

local function currentSource()
  for _, key in ipairs({"correo", "subasta", "vendedor", "botín"}) do if openNow[key] then return key end end
  return "otros"
end
function handlers.PLAYER_MONEY()
  Money.OnPlayerMoney(currentSource())
  if UI.IsShown() then refreshSoon() end
end
for event, source in pairs({MERCHANT_SHOW = "vendedor", MAIL_SHOW = "correo", LOOT_OPENED = "botín"}) do
  handlers[event] = function() openNow[source] = true end
end
for event, source in pairs({MERCHANT_CLOSED = "vendedor", MAIL_CLOSED = "correo", LOOT_CLOSED = "botín"}) do
  handlers[event] = function() openNow[source] = nil end
end
local merchantShow = handlers.MERCHANT_SHOW
function handlers.MERCHANT_SHOW()
  merchantShow()
  after(0.3, function() if Prices.RecordMerchant() > 0 then refreshSoon() end end)
end

function handlers.SKILL_LINES_CHANGED() updateProfessions() end
function handlers.LEARNED_SPELL_IN_SKILL_LINE() updateProfessions() end
-- En Forever TRADE_SKILL_SHOW llega antes que los datos; la lista está lista en TRADE_SKILL_LIST_UPDATE.
function handlers.TRADE_SKILL_SHOW() tradeSkillRetries = 0; scanTradeSkillSoon() end
function handlers.TRADE_SKILL_LIST_UPDATE() scanTradeSkillSoon() end
function handlers.TRADE_SKILL_DATA_SOURCE_CHANGED() scanTradeSkillSoon() end
function handlers.NEW_RECIPE_LEARNED() scanTradeSkillSoon() end
function handlers.TRADE_SKILL_UPDATE() scanTradeSkillSoon() end -- solo clientes Classic antiguos

function handlers.BAG_UPDATE_DELAYED()
  if bankOpen then scanBankSoon() end
  if UI.IsShown() then refreshSoon() end
end
local function itemLoaded(itemID, success)
  if Items.OnLoaded(itemID, success) and UI.IsShown() then refreshSoon() end
end
handlers.ITEM_DATA_LOAD_RESULT = itemLoaded
handlers.GET_ITEM_INFO_RECEIVED = itemLoaded

-- Banco: el cliente moderno lo abre con el gestor de interacciones; se escuchan ambos caminos.
local BANKER = {}
do
  local kinds = type(Enum) == "table" and Enum.PlayerInteractionType or nil
  if type(kinds) == "table" then
    for _, k in ipairs({"Banker", "CharacterBanker", "AccountBanker"}) do if kinds[k] then BANKER[kinds[k]] = true end end
  end
end
function handlers.BANKFRAME_OPENED() setBankOpen(true) end
function handlers.BANKFRAME_CLOSED() setBankOpen(false) end
function handlers.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind) if BANKER[kind] then setBankOpen(true) end end
function handlers.PLAYER_INTERACTION_MANAGER_FRAME_HIDE(kind) if BANKER[kind] then setBankOpen(false) end end
function handlers.PLAYERBANKSLOTS_CHANGED() if bankOpen then scanBankSoon() end end
function handlers.BANK_TABS_CHANGED() if bankOpen then scanBankSoon() end end

function handlers.AUCTION_HOUSE_SHOW()
  openNow.subasta = true
  Prices.Invalidate()
  if db.autoOpen and not UI.IsShown() then
    UI.Show()
    openedByAH = true
    after(0, function() UI.AttachTo(_G.AuctionHouseFrame) end)
  end
  refreshSoon()
  after(2, function()
    local ok, status = pcall(function() return Engine.DbStatus(Core.Context(), db.mode) end)
    if ok and status.level ~= "ok" then
      say("|cffffc733" .. status.text .. "|r")
      Extras.Alert("warn")
    end
  end)
end
function handlers.AUCTION_HOUSE_CLOSED()
  openNow.subasta = nil
  if openedByAH then
    UI.Hide()
    UI.RestorePosition()
  end
  openedByAH = false
end

function handlers.PLAYER_GUILD_UPDATE() Guild.UpdateKey(); invalidateMembers(); importRosterSoon() end
function handlers.GUILD_ROSTER_UPDATE() importRosterSoon() end

function handlers.CHAT_MSG_ADDON(prefix, text, channel, sender)
  if prefix ~= Guild.PREFIX then return end
  local ok, changed, isNew = pcall(Guild.OnAddonMessage, prefix, text, channel, sender)
  if ok and changed then
    invalidateMembers()
    refreshSoon()
    if isNew then Extras.Alert("good") end
  end
end

events:SetScript("OnEvent", function(_, event, ...)
  local handler = handlers[event]
  if handler then safely(event, handler, ...) end
end)
local function validEvent(event)
  if type(C_EventUtils) == "table" and type(C_EventUtils.IsEventValid) == "function" then
    local ok, valid = pcall(C_EventUtils.IsEventValid, event)
    return ok and valid
  end
  return true
end
for event in pairs(handlers) do
  if validEvent(event) then pcall(events.RegisterEvent, events, event) end
end

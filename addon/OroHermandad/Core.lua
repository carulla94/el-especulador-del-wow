-- Oro de Hermandad: eventos, datos guardados y comandos.
local ADDON, ns = ...
local Data, Items, Engine, Prices, Scan, Money = ns.Data, ns.Items, ns.Engine, ns.Prices, ns.Scan, ns.Money
local Guild, UI, Tooltip, Extras = ns.Guild, ns.UI, ns.Tooltip, ns.Extras
local Core = {}
ns.Core = Core

Core.VERSION = "0.2.1"

local DEFAULTS = {mode = "lazy", autoOpen = true, sound = true, tooltip = true}
-- Un escaneo de resumen cuenta como completo si trae al menos esta parte de los resultados del último que contó
-- (y no menos de SCAN_MIN_ROWS). Ver scanFinished.
local SCAN_MIN_ROWS, SCAN_MIN_SHARE, SCAN_DECAY = 50, 0.5, 0.75
local db, cdb
local openedByAH = false
local openNow = {}
local lastAhWarning -- último aviso de precios dado al abrir la subasta (no se repite igual en cada visita)

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

-- Solo recetas de profesiones que el personaje tiene ahora. Las de una profesión abandonada no se borran (por si una
-- lectura de profesiones falla un momento o la vuelve a aprender), pero no se sugieren ni se anuncian.
local function recipeList()
  local list = {}
  local profs = cdb.profs or {}
  for key, byProduct in pairs(cdb.recipes or {}) do
    if profs[key] and type(byProduct) == "table" then
      for _, recipe in pairs(byProduct) do list[#list + 1] = recipe end
    end
  end
  return list
end

local function cut()
  if type(db.cut) == "number" then return db.cut end
  return Prices.Cut()
end

local function clock() return type(GetTime) == "function" and GetTime() or 0 end

-- Hermandad combinada: se rehace como mucho cada 5 s o al cambiar algo (invalidateMembers).
-- usersLine: línea «Lo usa» ya hecha por objeto. La descripción de un objeto se repinta 5 veces por segundo mientras
-- el ratón está encima; así no se recorre ni se ordena toda la hermandad cada vez.
local membersCache, membersAt = nil, -math.huge
local usersLine, usersAt = {}, -math.huge
local function members()
  local t = clock()
  if not membersCache or t - membersAt > 5 or t < membersAt then membersCache, membersAt = Guild.Members(), t end
  return membersCache
end
local function invalidateMembers() membersCache = nil; usersLine = {} end

-- Último escaneo terminado de Auctionator en este reino y facción. Si sus escaneos no se pueden oír, se usa la hora a
-- la que Auctionator empezó el último (aproximada: no es por reino).
local function lastScan(key)
  local at = db.dbUpdated[key]
  if not at and not Prices.WatchingScans() then at = Prices.LastScanTime() end
  return at
end

function Core.Context()
  local caps = Prices.Capabilities()
  local key = marketKey()
  return {
    mode = db.mode,
    now = time(),
    cut = cut(),
    hasPriceSource = caps.prices,
    ageKnown = caps.age,
    autoscan = caps.autoscan,
    dbUpdatedAt = lastScan(key),  -- último escaneo terminado (completo o el de resumen)
    fullScanAt = db.fullScan[key], -- último escaneo de toda la subasta terminado (ver scanFinished)
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
  -- Una línea por dato: así ninguna se parte en dos y el pie cabe en su hueco de la ventana.
  local text = "Tú: " .. (#profs > 0 and table.concat(profs, ", ") or "sin profesiones detectadas")
  text = text .. "\nHermandad: " .. withAddon .. " con addon"
  if roster > 0 then text = text .. ", " .. roster .. " del roster" end
  if manual > 0 then text = text .. ", " .. manual .. " a mano" end
  local stats = Money.Stats()
  if stats and stats.seconds >= 300 then
    text = text .. "\nSesión: " .. Engine.Money(stats.net) .. " (" .. Engine.Money(stats.perHour) .. " por hora)"
  end
  return text
end

-- Sugerencias calculadas ahora mismo, o nil (y lo dice) si el motor falla.
local function suggest()
  local ok, result = pcall(function() return Engine.Suggest(Core.Context()) end)
  if not ok then
    say("error al calcular sugerencias: " .. tostring(result))
    return nil
  end
  return result
end

local function render(result)
  -- guildKnown: hay alguien de la hermandad con datos (el pie lo cuenta); si su sección sale vacía, no es por eso.
  safely("la ventana", UI.Render, result, {footer = footer(), canShop = Prices.CanShop() or Prices.AuctionHouseOpen(),
    guildKnown = next(members()) ~= nil})
end

function Core.Refresh()
  if not UI.IsShown() then return end
  local result = suggest()
  if result then render(result) end
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

-- Lo que se anuncia a la hermandad. Se piden algunas recetas de más: Guild no envía las que una versión antigua
-- rechazaría (más de 100 unidades por tanda, como la munición) y se queda con las 8 primeras.
local function selfInfo()
  local ok, crafts = pcall(function() return Engine.TopCrafts(Core.Context(), 12) end)
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

-- /oro comprar y el botón «Comprar lo que falta»: siempre con sugerencias calculadas ahora (la ventana puede llevar
-- rato cerrada, o el modo haber cambiado desde las opciones), nunca con las últimas que se pintaron.
local function shop()
  local fresh = suggest()
  if not fresh then return end
  if UI.IsShown() then render(fresh) end
  -- Lo que falta en la subasta (shopping) y lo que vende un mercader (vendorBuys), sumado por objeto.
  local wanted, order, atVendor, vendorOrder, vendorNames = {}, {}, {}, {}, {}
  for _, item in ipairs(fresh.sections and fresh.sections.now or {}) do
    for _, miss in ipairs(item.shopping or {}) do
      if not wanted[miss.id] then order[#order + 1] = miss.id end
      wanted[miss.id] = (wanted[miss.id] or 0) + miss.count
    end
    for _, buy in ipairs(item.vendorBuys or {}) do
      if not atVendor[buy.id] then vendorOrder[#vendorOrder + 1] = buy.id; vendorNames[buy.id] = buy.name end
      atVendor[buy.id] = (atVendor[buy.id] or 0) + buy.count
    end
  end
  local list = {}
  for _, id in ipairs(order) do list[#list + 1] = {itemID = id, count = wanted[id]} end
  -- Con la lista vacía no se llama a Auctionator: borraría la lista «Oro de Hermandad» que ya tuvieras.
  if #list == 0 then
    if fresh.mode == "lazy" then
      say("en modo Tranquilo solo se sugieren recetas que ya puedes hacer con lo que llevas; lo que falta para las demás solo se lista en A tope (/oro atope).")
    elseif #vendorOrder > 0 then
      local names = {}
      for i, id in ipairs(vendorOrder) do names[i] = atVendor[id] .. "× " .. (vendorNames[id] or Items.Name(id) or ("Objeto " .. id)) end
      say("no hay nada que comprar en la subasta para las recetas sugeridas. Lo que falta lo vende un mercader: " .. table.concat(names, ", ") .. ".")
    else
      say("no hay nada que comprar en la subasta para las recetas sugeridas.")
    end
    return
  end
  local result, item = Prices.ShopFor(list)
  local messages = {
    auctionator = "lista «Oro de Hermandad» creada en Auctionator y buscando en la subasta.",
    list = "lista «Oro de Hermandad» creada en Auctionator (pestaña Compras). Ábrela en la subasta.",
    loading = "preparando la lista: el juego está cargando los nombres. Se crea sola en un momento.",
    scanning = "lista «Oro de Hermandad» creada en Auctionator, pero no la busco: Auctionator está escaneando la subasta y una búsqueda cortaría el escaneo. Cuando termine, vuelve a pulsar o ábrela en la pestaña Compras.",
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
  local t = clock()
  if t - usersAt > 30 or t < usersAt then usersLine, usersAt = {}, t end
  local used = usersLine[itemID]
  if used == nil then
    local users = Engine.FriendsWhoUse(members(), itemID, UnitName("player"))
    used = #users > 0 and ((#users == 1 and "Lo usa: " or "Lo usan: ") .. table.concat(users, ", ", 1, math.min(3, #users))
      .. (#users > 3 and "…" or "")) or false
    usersLine[itemID] = used
  end
  if used then lines[#lines + 1] = {left = used} end
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
  "/oro comprar — (modo A tope) crea en Auctionator la lista de lo que falta para tus recetas",
  "/oro sesion — oro ganado en esta sesión  ·  /oro sesion reset",
  "/oro amigo Ana ingenieria 150 — añade a alguien a mano  ·  /oro amigo borrar Ana",
  "/oro sync — envía tus datos a la hermandad y le pide los suyos",
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
    shop()
  elseif cmd == "sync" then
    if not (type(IsInGuild) == "function" and IsInGuild()) then say("no estás en ninguna hermandad."); return end
    Guild.Announce(true); Guild.Request(); importRosterSoon() -- true: tus datos salen aunque no hayan cambiado
    say("he enviado tus datos a la hermandad y le he pedido los suyos.")
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
      say(removed and ("he quitado a " .. removed .. " de tu lista.") or ("no encuentro a " .. args[3] .. "."))
      invalidateMembers(); refreshSoon()
    else
      local name, profKey, rank = args[2], Data.ProfessionKey(args[3] or ""), tonumber(args[4] or "")
      local valid = name and profKey and rank and rank == rank and Guild.NormalizeName(name)
      local saved = valid and Guild.SetManual(name, profKey, rank)
      if not valid then
        say("uso: /oro amigo Nombre profesión nivel (ej.: /oro amigo Ana ingenieria 150)")
      elseif not saved then
        say("la hermandad aún no ha cargado: prueba otra vez en unos segundos.")
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
  db.dbUpdated = type(db.dbUpdated) == "table" and db.dbUpdated or {} -- último escaneo terminado, por reino y facción
  db.fullScan = type(db.fullScan) == "table" and db.fullScan or {}    -- último escaneo completo terminado
  db.scanRows = type(db.scanRows) == "table" and db.scanRows or {}    -- resultados del último resumen que contó
  db.lastDBUpdate = nil -- formato de la versión 0.1
  cdb.profs = type(cdb.profs) == "table" and cdb.profs or {}
  cdb.profMax = type(cdb.profMax) == "table" and cdb.profMax or {}
  cdb.recipes = type(cdb.recipes) == "table" and cdb.recipes or {}
  cdb.merchant = type(cdb.merchant) == "table" and cdb.merchant or {} -- precios de mercader de este personaje

  refreshSoon = throttle(0.5, Core.Refresh)
  scanTradeSkillSoon = throttle(1, scanTradeSkill)
  announceSoon = throttle(30, function() Guild.Announce() end)
  local rosterKey
  importRosterSoon = throttle(5, function()
    safely("el roster", function()
      local key = Guild.UpdateKey()
      -- Solo si cambió algo: el cliente manda GUILD_ROSTER_UPDATE cada vez que alguien entra o sale del juego.
      local _, changed = Guild.ImportRoster()
      if changed or key ~= rosterKey then rosterKey = key; invalidateMembers(); refreshSoon() end
    end)
  end)
  scanBankSoon = throttle(0.5, scanBank)

  SLASH_OROHERMANDAD1, SLASH_OROHERMANDAD2 = "/oro", "/orohermandad"
  SlashCmdList.OROHERMANDAD = handleSlash

  Prices.Init(db.prices, cdb.merchant)
  Guild.Init(db, selfInfo)
  safely("la ventana", UI.Create, {position = db.window, onMode = Core.SetMode, onRefresh = Core.Refresh,
    onShop = shop, onOptions = openOptions})
  Extras.Init(db, toggleWindow, openOptions)
  Extras.RegisterSettings(Core)
  Tooltip.Install(tooltipLines)
end

-- Un escaneo de Auctionator ha terminado: kind "full" (completo, el de replicate) o "summary" (el de resumen, el que
-- Auctionator hace por defecto); rows = cuántos resultados trae (nil si no se sabe).
-- El completo recorre la subasta entera: lo que no salió en él no está a la venta (ctx.fullScanAt).
-- El de resumen también, salvo si durante él se busca algo (barra de búsqueda, pestaña Compras, «Comprar lo que
-- falta»): Auctionator lo da por terminado solo con los resultados de esa búsqueda. Por eso solo cuenta si trae al
-- menos la mitad de resultados que el último que contó (y un mínimo); uno más corto es una búsqueda: refresca, pero
-- no fecha los precios, y rebaja un poco la referencia (si la subasta encoge de verdad, el siguiente ya cuenta).
-- Sin rows (versión de Auctionator que no los pasa) se fecha el escaneo, pero no cuenta como completo.
local function scanFinished(kind, rows)
  local key, now = marketKey(), time()
  local whole = kind == "full"
  if kind == "summary" and type(rows) == "number" then
    local last = tonumber(db.scanRows[key]) or 0
    whole = rows >= math.max(SCAN_MIN_ROWS, SCAN_MIN_SHARE * last)
    db.scanRows[key] = whole and rows or math.max(rows, math.floor(last * SCAN_DECAY))
    if not whole then refreshSoon(); return end
  end
  db.dbUpdated[key] = now
  if whole then db.fullScan[key] = now end
  lastAhWarning = nil
  refreshSoon()
end

function handlers.PLAYER_LOGIN()
  -- Cualquier búsqueda en la subasta actualiza la base de Auctionator: se refresca, pero solo un escaneo terminado
  -- cuenta como «precios al día».
  Prices.Watch(function() refreshSoon() end)
  Prices.WatchScans(scanFinished)
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

local guildSettling = false
function handlers.PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)
  Money.Start(cdb, isInitialLogin and not isReloadingUi)
  if guildSettling then return end
  guildSettling = true
  -- Unos segundos después de entrar, IsInGuild() ya es fiable: la hermandad queda identificada (y migrada).
  after(5, function()
    if Guild.Settle then safely("la hermandad", Guild.Settle) end
    invalidateMembers()
    refreshSoon()
  end)
end

-- Respaldo si no se oyen los escaneos de Auctionator: los datos de un escaneo completo acaban de llegar.
function handlers.REPLICATE_ITEM_LIST_UPDATE()
  if not Prices.WatchingScans() and Prices.Available() then scanFinished("full") end
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
    if not ok then return end
    if status.level == "ok" then lastAhWarning = nil; return end
    -- El mismo aviso no se repite (ni suena) en cada visita: solo si cambia o tras un escaneo.
    if status.text == lastAhWarning then return end
    lastAhWarning = status.text
    say("|cffffc733" .. status.text .. "|r")
    Extras.Alert("warn")
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

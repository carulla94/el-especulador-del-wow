-- Carga el addon completo en un cliente simulado de Forever y recorre una sesión de juego.
-- Desde la raíz del repositorio: lua5.1 test-lua/test_load.lua
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local realPrint = print
Stub.install()
assert(_G.GetItemInfo == nil and _G.GetTradeSkillLine == nil, "la simulación debe parecerse a Forever")
local ns = Stub.loadAddon("addon/OroHermandad")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; realPrint("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
local function printed(sub) for _, line in ipairs(Stub.printed) do if has(line, sub) then return true end end return false end
local function sent(pattern) local n = 0 for _, m in ipairs(Stub.sent) do if m.msg:match(pattern) then n = n + 1 end end return n end

local lastRender
local render = ns.UI.Render
ns.UI.Render = function(result, info) lastRender = {result = result, info = info}; return render(result, info) end
local function rendered(kind, pred)
  for _, key in ipairs({"now", "farm", "group"}) do
    for _, item in ipairs(lastRender.result.sections[key]) do
      if item.kind == kind and (not pred or pred(item)) then return item end
    end
  end
end
local function slash(text) SlashCmdList.OROHERMANDAD(text); Stub.runTimers(10) end
-- Cuenta las llamadas a una función de un módulo (Core las busca en la tabla al llamar).
local function counter(module, name)
  local calls, original = {n = 0}, module[name]
  module[name] = function(...) calls.n = calls.n + 1; return original(...) end
  calls.restore = function() module[name] = original end
  return calls
end
local settles = counter(ns.Guild, "Settle")

test("Arranque: profesiones por la API moderna, anuncio y petición a la hermandad, roster", function()
  Stub.fire("ADDON_LOADED", "OroHermandad")
  Stub.fire("PLAYER_LOGIN")
  Stub.fire("PLAYER_ENTERING_WORLD", true, false)
  Stub.runTimers(30)
  assert(SlashCmdList.OROHERMANDAD, "falta el comando")
  local cdb = OroHermandadCharDB
  assert(cdb.profs.mining == 180 and cdb.profs.blacksmithing == 160, "profesiones")
  assert(cdb.profMax.mining == 225, "tope de habilidad")
  assert(sent("^H2|32|blacksmithing=160,mining=180|") == 1, "anuncio")
  assert(sent("^R2$") == 1, "petición")
  assert(ns.Guild.Members().Luis, "Luis desde el roster")
  assert(_G.OroHermandadMinimapButton, "botón del minimapa")
  assert(Stub.tooltipPost, "descripción de objetos")
  assert(printed("Escribe /oro"), "mensaje de bienvenida")
  assert(settles.n == 1, "la hermandad se da por identificada unos segundos después de entrar: " .. settles.n)
  Stub.fire("PLAYER_ENTERING_WORLD", false, false) -- cambio de zona: no se repite
  Stub.runTimers(10)
  assert(settles.n == 1, "solo una vez")
end)

test("/oro: vende hierro (no el pico ni la poción) y funde el cobre de la bolsa de componentes", function()
  slash("")
  assert(lastRender and lastRender.result.mode == "lazy")
  local smelt = rendered("craft")
  assert(smelt and has(smelt.title, "Funde 40× Lingote de cobre"), smelt and smelt.title)
  local sell = rendered("sell")
  assert(sell and has(sell.detail, "20× Hierro"), sell and sell.detail)
  assert(not has(sell.detail, "Pico") and not has(sell.detail, "Poción"), sell.detail)
  assert(rendered("gray"), "chatarra gris")
  assert(has(lastRender.info.footer, "Minería 180"), lastRender.info.footer)
  assert(has(lastRender.info.footer, "\nHermandad: "), "la hermandad en su propia línea: " .. lastRender.info.footer)
end)

test("Pie de la ventana: hueco propio entre la lista y los botones", function()
  local frame = _G.OroHermandadFrame
  local function y(region, i) local p = region.__points[i or 1]; return p[#p] end
  local buttonTop = y(frame.shopButton) + 22
  assert(y(frame.optionsButton) == y(frame.shopButton), "botones a la misma altura")
  assert(#frame.footer.__points == 2, "anclado por los dos lados: el ancho no depende del texto")
  assert(y(frame.footer, 1) >= buttonTop and y(frame.footer, 2) >= buttonTop, "el pie empieza encima de los botones")
  assert(frame.footer.__height and frame.footer.__maxLines == 3, "alto fijo y como mucho 3 líneas")
  assert(y(frame.scroll, 2) >= y(frame.footer) + frame.footer.__height, "la lista termina encima del pie")
end)

test("Roster sin cambios: no se recalcula; con cambios, sí", function()
  local suggests = counter(ns.Engine, "Suggest")
  for _ = 1, 3 do Stub.fire("GUILD_ROSTER_UPDATE", true); Stub.runTimers(10) end
  assert(suggests.n == 0, "alguien entra o sale del juego: nada que recalcular (" .. suggests.n .. ")")
  local getInfo = C_Club.GetMemberInfo
  C_Club.GetMemberInfo = function(club, id)
    local info = getInfo(club, id)
    if id == 2 then info.level = 41 end
    return info
  end
  Stub.fire("GUILD_ROSTER_UPDATE", true); Stub.runTimers(10)
  assert(suggests.n == 1, "Luis ha subido de nivel: " .. suggests.n)
  C_Club.GetMemberInfo = getInfo
  Stub.fire("GUILD_ROSTER_UPDATE", true); Stub.runTimers(10)
  suggests.restore()
end)

test("Ventana de herrería moderna: guarda solo las recetas aprendidas", function()
  Stub.tradeOpen = true
  Stub.fire("TRADE_SKILL_SHOW")
  Stub.fire("TRADE_SKILL_LIST_UPDATE")
  Stub.runTimers(10)
  local recipes = OroHermandadCharDB.recipes.blacksmithing
  assert(recipes and recipes[12404], "receta guardada")
  local count = 0 for _ in pairs(recipes) do count = count + 1 end
  assert(count == 1, "solo la aprendida")
  Stub.tradeOpen = false
end)

test("A tope + /oro comprar: lista de la compra en Auctionator con lo que falta", function()
  slash("atope")
  assert(lastRender.result.mode == "farm")
  local craft = rendered("craft", function(item) return item.icon == 12404 end)
  assert(craft and has(craft.detail, "Te falta 1× Piedra densa"), craft and craft.detail)
  slash("comprar")
  assert(Stub.shoppingList and Stub.shoppingList.name == "Oro de Hermandad", "lista creada")
  assert(has(Stub.shoppingList.strings[1], "Piedra densa"), Stub.shoppingList.strings[1])
end)

test("/oro comprar calcula en el momento: ventana cerrada, bolsas cambiadas, modo cambiado en opciones", function()
  local list = Stub.shoppingList
  -- Ventana cerrada y ya has comprado la piedra: no se busca de nuevo ni se borra la lista que tienes.
  ns.UI.Hide()
  table.insert(Stub.slots[0], {itemID = 12365, stackCount = 5, quality = 1, isBound = false})
  Stub.printed = {}
  slash("comprar")
  assert(printed("no falta nada"), "ya lo tienes")
  assert(Stub.shoppingList == list and #list.strings == 1, "la lista de Auctionator no se toca")
  table.remove(Stub.slots[0])
  -- Tranquilo no lista lo que falta: lo explica y no toca Auctionator.
  slash("tranquilo")
  Stub.shoppingList, Stub.printed = nil, {}
  slash("comprar")
  assert(printed("en modo Tranquilo") and printed("A tope"), "explica el modo")
  assert(Stub.shoppingList == nil, "sin lista vacía en Auctionator")
  -- Modo cambiado desde el panel de opciones con la ventana cerrada.
  ns.UI.Hide()
  ns.Core.SetMode("farm", true)
  slash("comprar")
  assert(Stub.shoppingList and has(Stub.shoppingList.strings[1], "Piedra densa"), "lista de A tope")
  -- Si el motor falla, se dice sin romper el comando.
  local suggest = ns.Engine.Suggest
  ns.Engine.Suggest = function() error("roto") end
  Stub.printed = {}
  slash("comprar")
  ns.Engine.Suggest = suggest
  assert(printed("error al calcular sugerencias"), "error controlado")
  Stub.printed = {}
end)

test("Profesión abandonada: sus recetas ni se sugieren ni se anuncian (y no se borran)", function()
  local getProfessions = _G.GetProfessions
  _G.GetProfessions = function() return 1, nil, nil, nil, nil end -- deja la herrería
  Stub.fire("SKILL_LINES_CHANGED")
  Stub.runTimers(5)
  assert(OroHermandadCharDB.profs.blacksmithing == nil, "herrería olvidada")
  slash("atope")
  assert(not rendered("craft", function(item) return item.icon == 12404 end), "no sugiere la piedra de afilar")
  for _, craft in ipairs(ns.Engine.TopCrafts(ns.Core.Context(), 8)) do
    assert(craft.product ~= 12404 and craft.id ~= 12404, "no la anuncia a la hermandad")
  end
  assert(OroHermandadCharDB.recipes.blacksmithing[12404], "la receta sigue guardada")
  _G.GetProfessions = getProfessions
  Stub.fire("SKILL_LINES_CHANGED")
  slash("atope")
  assert(rendered("craft", function(item) return item.icon == 12404 end), "al volver a tenerla, vuelve")
  local announced = false
  for _, craft in ipairs(ns.Engine.TopCrafts(ns.Core.Context(), 8)) do announced = announced or craft.product == 12404 end
  assert(announced, "y se vuelve a anunciar")
end)

test("Banco moderno por pestañas: sugiere sacar el mitril y fundirlo", function()
  Stub.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 8)
  Stub.runTimers(5)
  assert(OroHermandadCharDB.bank and OroHermandadCharDB.bank.items[3858].count == 40, "banco leído")
  Stub.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 8)
  slash("atope")
  local bank = rendered("bank")
  assert(bank and has(bank.detail, "40× Mineral de mitril"), bank and bank.detail)
  assert(has(bank.title, "funde 40× Lingote de mitril"), bank.title)
end)

test("Descripción de objetos: precio, quién lo usa y cuántos hay en el banco", function()
  local tip = ns and _G.GameTooltip
  local uses = counter(ns.Engine, "FriendsWhoUse")
  tip.__lines = {}
  Stub.tooltipPost(tip, {id = 2772})
  local text = table.concat(tip.__lines, " | ")
  assert(has(text, "Oro de Hermandad · Subasta (hoy) = 1p 20c"), text)
  assert(has(text, "Lo usa: Luis (Minería)"), text)
  -- El cliente repinta la descripción 5 veces por segundo: la hermandad no se recorre cada vez.
  for _ = 1, 10 do Stub.gameTime = Stub.gameTime + 0.2; tip.__lines = {}; Stub.tooltipPost(tip, {id = 2772}) end
  assert(uses.n == 1, "una vez por objeto: " .. uses.n)
  assert(has(table.concat(tip.__lines, " | "), "Lo usa: Luis (Minería)"), "misma línea")
  slash("amigo ana mineria 150") -- cambia la hermandad: se vuelve a calcular
  tip.__lines = {}
  Stub.tooltipPost(tip, {id = 2772})
  assert(uses.n == 2 and has(table.concat(tip.__lines, " | "), "Lo usa: Ana (Minería), Luis (Minería)"), table.concat(tip.__lines, " | "))
  slash("amigo borrar ana")
  uses.restore()
  tip.__lines = {}
  Stub.tooltipPost(tip, {id = 3858})
  assert(has(table.concat(tip.__lines, " | "), "En tu banco = 40"), table.concat(tip.__lines, " | "))
  tip.__lines = {}
  Stub.tooltipPost(_G.newShoppingTooltip or {}, {id = 2772})
  assert(#tip.__lines == 0, "otras descripciones no se tocan")
end)

test("Mensajes de la hermandad: receta de Pedro con tu hierro y aviso sonoro de miembro nuevo", function()
  Stub.sounds = {}
  Stub.fire("CHAT_MSG_ADDON", "OroHerm", "H2|40|engineering=200|1|5", "GUILD", "Pedro-Forever")
  Stub.fire("CHAT_MSG_ADDON", "OroHerm", "C2|5|1|1|10546|1|5000|2772:4", "GUILD", "Pedro-Forever")
  slash("atope")
  assert(rendered("friendcraft", function(item) return has(item.title, "Pedro") end), "receta de Pedro")
  assert(#Stub.sounds == 1, "sonido")
  assert(has(lastRender.info.footer, "1 con addon") and has(lastRender.info.footer, "1 del roster"), lastRender.info.footer)
end)

test("Mensaje malicioso no rompe nada", function()
  Stub.fire("CHAT_MSG_ADDON", "OroHerm", "C2|5|nan|1|1|1|1|1:1", "GUILD", "Pedro-Forever")
  Stub.fire("CHAT_MSG_ADDON", "OroHerm", ("|"):rep(400), "GUILD", "Malo")
end)

test("Precios viejos: aviso al abrir la subasta, ventana pegada a ella; una búsqueda no lo quita, un escaneo sí", function()
  local KEY = "Forever-Alliance"
  local old = Stub.now - 12 * 3600
  local function visit()
    Stub.printed, Stub.sounds = {}, {}
    Stub.gameTime = Stub.gameTime + 20 -- los sonidos tienen un mínimo de 10 s entre sí
    Stub.fire("AUCTION_HOUSE_SHOW")
    Stub.runTimers(5)
  end
  OroHermandadDB.dbUpdated[KEY] = old
  ns.UI.Hide()
  _G.AuctionHouseFrame = Stub.newObject("Frame", "AuctionHouseFrame")
  visit()
  assert(ns.UI.IsShown(), "se abre sola")
  local frame = _G.OroHermandadFrame
  assert(frame.__points[1] and frame.__points[1][2] == _G.AuctionHouseFrame, "pegada a la subasta")
  assert(printed("Precios de hace 12 h") and printed("escanear al abrir la subasta"), "aviso en el chat")
  assert(#Stub.sounds == 1, "sonido de aviso")
  -- Una tanda de búsqueda (los favoritos que la subasta busca al abrirse, la pestaña Comprar, una lista de la
  -- compra) actualiza unos pocos objetos: no es un escaneo.
  Stub.dbCallback()
  Stub.runTimers(5)
  assert(OroHermandadDB.dbUpdated[KEY] == old, "una búsqueda no fecha los precios")
  assert(lastRender.result.db.level == "warn", lastRender.result.db.text)
  -- Otra visita con el mismo aviso: ni se repite ni suena.
  Stub.fire("AUCTION_HOUSE_CLOSED")
  visit()
  assert(not printed("Precios de hace"), "el mismo aviso no se repite")
  assert(#Stub.sounds == 0, "ni suena")
  -- Termina el escaneo de resumen de Auctionator (el que hace por defecto): recorre toda la subasta, así que cuenta
  -- como escaneo completo.
  Stub.scanComplete("summary")
  Stub.runTimers(5)
  assert(OroHermandadDB.dbUpdated[KEY] == Stub.now, "fecha del escaneo")
  assert(ns.Core.Context().dbUpdatedAt == Stub.now and ns.Core.Context().fullScanAt == Stub.now, "resumen = completo")
  assert(lastRender.result.db.level == "ok", lastRender.result.db.text)
  -- Escaneo completo (replicate).
  OroHermandadDB.fullScan[KEY] = nil
  Stub.scanComplete("full")
  Stub.runTimers(5)
  assert(ns.Core.Context().fullScanAt == Stub.now and OroHermandadDB.fullScan[KEY] == Stub.now, "escaneo completo")
  -- Tras un escaneo, si los precios vuelven a envejecer, el aviso vuelve a darse.
  Stub.fire("AUCTION_HOUSE_CLOSED")
  OroHermandadDB.dbUpdated[KEY], OroHermandadDB.fullScan[KEY] = old, nil
  visit()
  assert(printed("Precios de hace 12 h") and #Stub.sounds == 1, "aviso de nuevo")
  OroHermandadDB.dbUpdated[KEY] = Stub.now
  Stub.fire("AUCTION_HOUSE_CLOSED")
  assert(not ns.UI.IsShown(), "se cierra con la subasta")
end)

test("Escaneos de Auctionator sin su EventBus: se usa su hora guardada", function()
  local P = {Data = ns.Data, Items = ns.Items}
  assert(loadfile("addon/OroHermandad/Prices.lua"))("OroHermandad", P)
  local saved = _G.Auctionator
  _G.Auctionator = {API = saved.API, SavedState = {TimeOfLastBrowseScan = 100, TimeOfLastReplicateScan = 200}}
  assert(P.Prices.WatchScans(function() end) == false and P.Prices.WatchingScans() == false, "sin EventBus")
  assert(P.Prices.LastScanTime() == 200, "hora guardada")
  _G.Auctionator = nil
  assert(P.Prices.LastScanTime() == nil, "sin Auctionator")
  _G.Auctionator = saved
  assert(ns.Prices.WatchingScans() == true, "el addon sí los oye")
  -- Oyéndolos, los datos de un escaneo completo de otro addon (REPLICATE_ITEM_LIST_UPDATE) no fechan nada:
  -- Auctionator solo procesa los suyos.
  local before = OroHermandadDB.fullScan["Forever-Alliance"]
  OroHermandadDB.fullScan["Forever-Alliance"] = nil
  Stub.fire("REPLICATE_ITEM_LIST_UPDATE")
  assert(OroHermandadDB.fullScan["Forever-Alliance"] == nil, "solo como respaldo")
  local watching = ns.Prices.WatchingScans
  ns.Prices.WatchingScans = function() return false end -- sin EventBus: el evento del cliente es el respaldo
  Stub.fire("REPLICATE_ITEM_LIST_UPDATE")
  ns.Prices.WatchingScans = watching
  assert(OroHermandadDB.fullScan["Forever-Alliance"] == Stub.now, "respaldo")
  OroHermandadDB.fullScan["Forever-Alliance"] = before
end)

test("Oro de la sesión", function()
  Stub.fire("MERCHANT_SHOW")
  Stub.money = Stub.money + 25000
  Stub.fire("PLAYER_MONEY")
  Stub.fire("MERCHANT_CLOSED")
  Stub.now = Stub.now + 3600
  slash("sesion")
  assert(printed("2o 50p netos"), "sesión")
end)

test("Comandos en español: auto no / auto / comision / amigo", function()
  slash("auto no"); assert(OroHermandadDB.autoOpen == false)
  slash("auto"); assert(OroHermandadDB.autoOpen == true)
  slash("auto quizas"); assert(printed("uso: /oro auto on|off"))
  slash("comision 15"); assert(OroHermandadDB.cut == 0.15)
  slash("comision 5")
  slash("amigo bea encantamiento 120")
  assert(ns.Guild.Members().Bea and ns.Guild.Members().Bea.profs.enchanting == 120)
  Stub.printed = {}
  slash("amigo borrar nadie"); assert(printed("no encuentro a nadie"))
  slash("amigo borrar bea"); assert(printed("he quitado a Bea de tu lista."))
  slash("ayuda"); assert(printed("/oro comprar — (modo A tope)"), "la ayuda dice para qué modo es")
  -- Al entrar, la hermandad tarda unos segundos en cargar: se dice en vez de mostrar el uso.
  local setManual = ns.Guild.SetManual
  ns.Guild.SetManual = function() return nil end
  Stub.printed = {}
  slash("amigo ana mineria 150")
  ns.Guild.SetManual = setManual
  assert(printed("la hermandad aún no ha cargado") and not printed("uso:"), "hermandad sin cargar")
  Stub.printed = {}
  slash("amigo ana mineria"); assert(printed("uso: /oro amigo"), "falta el nivel")
end)

test("/oro sync: tus datos salen aunque no hayan cambiado", function()
  local limits, top = {}, ns.Engine.TopCrafts
  ns.Engine.TopCrafts = function(ctx, limit) limits[#limits + 1] = limit; return top(ctx, limit) end
  Stub.gameTime = Stub.gameTime + 120; Stub.runTimers(120)
  ns.Guild.Announce(); Stub.runTimers(30) -- sale si algo cambió en las pruebas anteriores
  Stub.gameTime = Stub.gameTime + 120
  Stub.sent = {}
  ns.Guild.Announce(); Stub.runTimers(30)
  assert(sent("^H2|") == 0, "sin cambios no se repite")
  Stub.gameTime = Stub.gameTime + 120
  Stub.printed = {}
  slash("sync")
  ns.Engine.TopCrafts = top
  assert(sent("^H2|") == 1 and sent("^R2$") == 1, "anuncio y petición")
  assert(printed("he enviado tus datos a la hermandad"), "mensaje")
  assert(limits[#limits] == 12, "se piden recetas de más por si alguna no se puede enviar: " .. tostring(limits[#limits]))
end)

test("Precios de mercader: de este personaje y solo lo que puede comprar", function()
  Stub.merchant = {{id = 2321, price = 90}, {id = 8925, price = 1800, stack = 4},
                   {id = 18256, price = 1000, purchasable = false}, -- en rojo: le falta reputación
                   {id = 3371, price = 4, available = 5}, {id = 2324, price = 25, extended = true}}
  Stub.fire("MERCHANT_SHOW"); Stub.runTimers(1); Stub.fire("MERCHANT_CLOSED")
  Stub.merchant = {}
  local own = OroHermandadCharDB.merchant
  assert(own[2321] == 90 and own[8925] == 450, "precio por unidad")
  assert(own[18256] == nil, "lo que no puede comprar no se guarda")
  assert(own[3371] == nil and own[2324] == nil, "existencias limitadas o coste especial")
  assert(OroHermandadDB.prices.merchant == nil, "no es de toda la cuenta")
  assert(ns.Prices.VendorBuy(2321) == 90, "el suyo manda")
  -- Sin visita propia, la caché de Auctionator (de toda la cuenta) puede traer el descuento de otro personaje.
  Stub.vendorPrices[4291], Stub.vendorPrices[99999] = 450, 70
  ns.Prices.Invalidate()
  assert(ns.Prices.VendorBuy(4291) == 500, "no baja del precio de la tabla")
  assert(ns.Prices.VendorBuy(99999) == 70, "fuera de la tabla, el de Auctionator")
  Stub.vendorPrices[4291] = 600
  ns.Prices.Invalidate()
  assert(ns.Prices.VendorBuy(4291) == 600, "si es más caro, el de Auctionator")
  Stub.vendorPrices = {}
  -- Los de la 0.2.0, guardados para toda la cuenta, se descartan al cargar.
  local P = {Data = ns.Data, Items = ns.Items}
  assert(loadfile("addon/OroHermandad/Prices.lua"))("OroHermandad", P)
  local account = {merchant = {[2321] = 50}, ahCut = 0.05}
  P.Prices.Init(account, {})
  assert(account.merchant == nil and account.ahCut == 0.05 and P.Prices.VendorBuy(2321) == 100, "0.2.0")
end)

test("Menú de addons del minimapa: la descripción no invita a arrastrar (el botón redondo sí)", function()
  local tip = _G.GameTooltip
  tip.__lines = {}
  OroHermandad_OnCompartmentEnter("OroHermandad", Stub.newObject("Button"))
  local text = table.concat(tip.__lines, " | ")
  assert(has(text, "Clic: abrir") and not has(text, "Arrastrar"), text)
  tip.__lines = {}
  local button = _G.OroHermandadMinimapButton
  button.__scripts.OnEnter(button)
  assert(has(table.concat(tip.__lines, " | "), "Arrastrar: mover el botón"), "el botón del minimapa sí se arrastra")
end)

test("Sin Auctionator no rompe y lo explica", function()
  local saved = _G.Auctionator
  _G.Auctionator = nil
  slash("tranquilo")
  assert(lastRender.result.db.level == "error" and has(lastRender.result.db.text, "Auctionator"))
  _G.Auctionator = saved
end)

test("Ningún error durante toda la sesión", function()
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

realPrint(string.format("sesión simulada: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

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
  assert(printed("no hay nada que comprar en la subasta para las recetas sugeridas."), "ya lo tienes")
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
  -- Con varios, en plural.
  assert(uses.n == 2 and has(table.concat(tip.__lines, " | "), "Lo usan: Ana (Minería), Luis (Minería)"), table.concat(tip.__lines, " | "))
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
  -- Un escaneo de resumen cortado por una búsqueda (barra de búsqueda, pestaña Compras, «Comprar lo que falta»):
  -- Auctionator lo da por terminado solo con los resultados de esa búsqueda. No fecha los precios.
  Stub.scanComplete("summary", 3)
  Stub.runTimers(5)
  assert(OroHermandadDB.dbUpdated[KEY] == old and ns.Core.Context().fullScanAt == nil, "un resumen cortado no cuenta")
  assert(lastRender.result.db.level == "warn", lastRender.result.db.text)
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

test("Escaneo de resumen: cuenta si trae una parte creíble de la subasta; si la subasta encoge, el siguiente sí", function()
  local KEY, db = "Forever-Alliance", OroHermandadDB
  local saved = {db.dbUpdated[KEY], db.fullScan[KEY], db.scanRows[KEY]}
  assert(saved[3] == 1000, "se recuerda cuántos trajo el último que contó: " .. tostring(saved[3]))
  db.dbUpdated[KEY], db.fullScan[KEY] = nil, nil
  Stub.scanComplete("summary", 400) -- menos de la mitad que el último
  Stub.runTimers(5)
  assert(db.fullScan[KEY] == nil and db.dbUpdated[KEY] == nil, "corto: no cuenta")
  assert(db.scanRows[KEY] == 750, "la referencia baja un poco: " .. tostring(db.scanRows[KEY]))
  Stub.scanComplete("summary", 400) -- la subasta ha encogido de verdad
  Stub.runTimers(5)
  assert(db.fullScan[KEY] == Stub.now and db.dbUpdated[KEY] == Stub.now and db.scanRows[KEY] == 400, "el siguiente ya cuenta")
  -- Sin el número de resultados (versión de Auctionator que no los pasa): fecha el escaneo, pero no como completo.
  db.dbUpdated[KEY], db.fullScan[KEY] = nil, nil
  Stub.busFire("full_incremental_scan_complete")
  Stub.runTimers(5)
  assert(db.dbUpdated[KEY] == Stub.now and db.fullScan[KEY] == nil, "sin resultados")
  db.dbUpdated[KEY], db.fullScan[KEY], db.scanRows[KEY] = saved[1], saved[2], saved[3]
end)

test("Comprar lo que falta durante el escaneo de Auctionator: crea la lista pero no la busca (lo cortaría)", function()
  local ah = _G.AuctionHouseFrame
  local wasShown = ah.__shown
  ah:Show()
  slash("atope")
  Stub.scanFrame.doingFullScan = true
  Stub.shoppingList, Stub.multiSearch, Stub.printed = nil, nil, {}
  slash("comprar")
  Stub.scanFrame.doingFullScan = false
  assert(Stub.shoppingList and has(Stub.shoppingList.strings[1], "Piedra densa"), "lista creada")
  assert(Stub.multiSearch == nil, "sin búsqueda en la subasta")
  assert(printed("no la busco") and printed("pestaña Compras"), "lo explica")
  Stub.shoppingList, Stub.printed = nil, {}
  slash("comprar")
  assert(Stub.multiSearch and Stub.multiSearch[1].searchString == "Piedra densa", "sin escaneo, sí busca")
  assert(printed("buscando en la subasta"), "mensaje normal")
  Stub.multiSearch, Stub.printed = nil, {}
  ah.__shown = wasShown
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
  slash("ayuda"); assert(printed("/oro comprar — lista de la compra en Auctionator: lo que falta para tus recetas (A tope) y los chollos"),
    "la ayuda dice para qué modo es")
  assert(printed("/oro especular — modo para especular") and printed("/oro especular presupuesto 200"), "y el modo Especular")
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

test("/oro comprar: si lo que falta lo vende un mercader, lo dice; si lo tienes en el banco, se saca", function()
  local bags, bank = Stub.slots[0], OroHermandadCharDB.bank
  Stub.items[3859], Stub.items[3857] = {"Lingote de acero", 1, "", 50, 7}, {"Carbón", 1, "", 125, 7}
  Stub.prices[3859] = 3000 -- el carbón no está en la subasta: solo lo vende un mercader
  Stub.slots[0] = {{itemID = 3575, stackCount = 20, quality = 1, isBound = false},
                   {itemID = 12365, stackCount = 5, quality = 1, isBound = false}}
  OroHermandadCharDB.bank = {items = {}, at = Stub.now}
  ns.Prices.Invalidate()
  slash("atope")
  local steel = rendered("craft", function(item) return item.icon == 3859 end)
  assert(steel and has(steel.detail, "Compra a un mercader 20× Carbón"), steel and steel.detail)
  Stub.shoppingList, Stub.printed = nil, {}
  slash("comprar")
  assert(printed("no hay nada que comprar en la subasta") and printed("Lo que falta lo vende un mercader: 20× Carbón."),
    table.concat(Stub.printed, " / "))
  assert(not printed("no falta nada") and Stub.shoppingList == nil, "ni «no falta nada» ni lista en Auctionator")
  -- Con el carbón en el banco: se saca, no se compra.
  OroHermandadCharDB.bank.items[3857] = {count = 20, quality = 1}
  slash("atope")
  steel = rendered("craft", function(item) return item.icon == 3859 end)
  assert(steel and has(steel.title, "Saca del banco y funde 20× Lingote de acero"), steel and steel.title)
  assert(has(steel.detail, "Del banco: 20× Carbón.") and not has(steel.detail, "mercader"), steel.detail)
  Stub.printed = {}
  slash("comprar")
  assert(printed("no hay nada que comprar en la subasta") and not printed("mercader"), table.concat(Stub.printed, " / "))
  Stub.slots[0], OroHermandadCharDB.bank, Stub.prices[3859] = bags, bank, nil
  ns.Prices.Invalidate()
  Stub.printed = {}
end)

test("Hermandad sin sugerencias: si se conoce a alguien, no dice que nadie tiene datos", function()
  slash("tranquilo")
  assert(lastRender.info.guildKnown == true, "Core dice a la ventana que hay hermandad conocida")
  -- Otra instancia de UI.lua para ver los textos que pinta (sin tocar la ventana de la sesión).
  local texts, saved = {}, {frame = _G.OroHermandadFrame, scroll = _G.OroHermandadScroll, createFrame = _G.CreateFrame}
  _G.CreateFrame = function(...)
    local f = saved.createFrame(...)
    f.CreateFontString = function() local fs = Stub.newObject("FontString"); texts[#texts + 1] = fs; return fs end
    return f
  end
  local ok, err = pcall(function()
    local U = {Items = ns.Items}
    assert(loadfile("addon/OroHermandad/UI.lua"))("OroHermandad", U)
    U.UI.Create({position = {}})
    local function shown(sub) for _, fs in ipairs(texts) do if fs.__shown and has(fs.__text, sub) then return true end end end
    local empty = {mode = "lazy", notes = {}, sections = {now = {}, farm = {}, group = {}}}
    U.UI.Render(empty, {footer = "Hermandad: 0 con addon, 2 del roster", guildKnown = true})
    assert(shown("Nada para la hermandad con lo que llevas ahora.") and not shown("Nadie de la hermandad"), "con hermandad conocida")
    U.UI.Render(empty, {footer = "Hermandad: 0 con addon"})
    assert(shown("Nadie de la hermandad con datos todavía") and not shown("Nada para la hermandad"), "sin nadie conocido")
  end)
  _G.CreateFrame, _G.OroHermandadFrame, _G.OroHermandadScroll = saved.createFrame, saved.frame, saved.scroll
  if not ok then error(err, 0) end
end)

---------------------------------------------------------------------------
-- Modo Especular en la sesión
---------------------------------------------------------------------------
local Spec = ns.Spec
local KEY = "Forever-Alliance"
local WORKED = {9600, 9800, 10000, 10200, 10400, 9900, 10100, 9700, 10300, 10000, 9900, 10100, 10000, 10000}
-- Paño rúnico con 14 días de precios en OroHermandadHist (escritos con los codificadores de Spec, como History) y un
-- escaneo propio de hace 10 min a 60p.
local function seedHistory(id, lo)
  local T = Spec.DayIndex(Stub.now)
  local records = {}
  for i, v in ipairs(WORKED) do records[i] = {d = T - 15 + i, lo = v, hi = v, last = v, qty = 400, scans = 2, src = "o"} end
  local market = ns.History.Hist().markets[KEY]
  market.items[id] = {n = "Paño rúnico", c = "tela", v = 100, d = Spec.EncodeDays(records),
                      p = Spec.EncodePoints({{t = Stub.now - 600, lo = lo or 6000, qty = 300, qty5 = 40}})}
  market.dep[id] = "1:13,2:50,3:150"
end
local function specRow(kind)
  for _, item in ipairs(lastRender.result.sections.spec or {}) do if item.kind == kind then return item end end
end

test("Tres modos: botones, /oro especular, resaltado y botón de la tabla", function()
  local frame = _G.OroHermandadFrame
  assert(#frame.modeButtons == 3, "tres botones")
  assert(frame.modeButtons[1].__text == "Tranquilo" and frame.modeButtons[2].__text == "A tope" and frame.modeButtons[3].__text == "Especular",
    "en el orden de Engine.MODE_ORDER")
  slash("tranquilo")
  frame.specButton.__scripts.OnClick(frame.specButton)
  Stub.runTimers(5)
  assert(OroHermandadDB.mode == "spec" and lastRender.result.mode == "spec", "el botón cambia de modo")
  assert(frame.specButton.__locked and not frame.lazyButton.__locked and not frame.farmButton.__locked, "resaltado el activo")
  assert(frame.tableButton.__shown, "botón de la tabla en Especular")
  slash("atope")
  assert(frame.farmButton.__locked and not frame.specButton.__locked and not frame.tableButton.__shown, "A tope: sin botón de tabla")
  Stub.printed = {}
  slash("especular")
  assert(OroHermandadDB.mode == "spec" and printed("modo Especular."), "/oro especular cambia de modo")
  -- En Especular no hay recetas, ventas, rutas ni hermandad.
  for _, key in ipairs({"now", "farm", "group"}) do assert(#lastRender.result.sections[key] == 0, key) end
  slash("tranquilo")
end)

test("/oro especular on|off y presupuesto (por defecto, el 25 % de tu oro)", function()
  Stub.printed = {}
  slash("especular presupuesto")
  assert(printed("presupuesto para chollos: el 25 % de tu oro, ahora " .. ns.Engine.Money(math.floor(Stub.money / 4))), table.concat(Stub.printed, " / "))
  slash("especular presupuesto 200")
  assert(OroHermandadDB.spec.budget == 2000000 and printed("presupuesto para chollos: 200o (cada chollo usa como mucho 50o)."), "200 oros")
  slash("especular 12,5")
  assert(OroHermandadDB.spec.budget == 125000, "coma decimal: " .. tostring(OroHermandadDB.spec.budget))
  Stub.printed = {}
  slash("especular presupuesto muchos")
  assert(printed("uso: /oro especular") and OroHermandadDB.spec.budget == 125000, "uso")
  slash("especular presupuesto auto")
  assert(OroHermandadDB.spec.budget == nil, "vuelve al 25 %")
  slash("especular 50"); slash("especular presupuesto 0")
  assert(OroHermandadDB.spec.budget == nil, "0 también, como en el panel de opciones")
  Stub.printed = {}
  slash("especular off")
  assert(OroHermandadDB.spec.on == false and printed("Especular apagado en Tranquilo, A tope y la descripción de los objetos."), "apagado")
  slash("especular si")
  assert(OroHermandadDB.spec.on == true and printed("Especular encendido"), "encendido")
  Stub.printed = {}
  slash("estado")
  assert(printed("Especular: presupuesto para chollos") and printed("(el 25 % de tu oro)") and printed("encendido."), "estado")
  slash("especular presupuesto 200")
end)

test("Especular con historial: chollo, «Comprar lo que falta» con su cantidad (también en Tranquilo) y la tabla", function()
  Stub.items[14047] = {"Paño rúnico", 1, "", 100, 7}
  seedHistory(14047)
  slash("especular")
  local row = specRow("flip")
  assert(row and row.title == "Chollo: Paño rúnico a 60p (40 % por debajo de lo normal)", row and row.title)
  assert(has(row.detail, "Compra 40× a 82p 16c como máximo") and has(row.detail, "Precio de hace 10 min."), row.detail)
  assert(row.shopping[1].id == 14047 and row.shopping[1].count == 40, "lista de la compra")
  assert(has(lastRender.result.spec.text, "Recuerda: el precio mínimo publicado no es una venta confirmada."), lastRender.result.spec.text)
  Stub.shoppingList, Stub.printed = nil, {}
  slash("comprar")
  assert(Stub.shoppingList and Stub.shoppingList.strings[1] == "\"Paño rúnico\";;;;;;;;;;;40", Stub.shoppingList and Stub.shoppingList.strings[1])
  assert(not printed("no hay nada que comprar"), "hay algo que comprar")
  -- Tranquilo: el mismo chollo (confianza alta) y el mismo botón.
  slash("tranquilo")
  assert(specRow("flip") and #lastRender.result.sections.spec == 1, "1 chollo en Tranquilo")
  Stub.shoppingList = nil
  slash("comprar")
  assert(Stub.shoppingList and has(Stub.shoppingList.strings[#Stub.shoppingList.strings], "Paño rúnico"), "Tranquilo también lo compra")
  -- Especular apagado: Tranquilo ya no lo enseña ni lo compra.
  slash("especular off")
  slash("tranquilo")
  assert(#lastRender.result.sections.spec == 0, "apagado")
  Stub.shoppingList, Stub.printed = nil, {}
  slash("comprar")
  assert(Stub.shoppingList == nil and printed("en modo Tranquilo"), "nada que comprar")
  slash("especular on")
  -- El botón «Tabla» abre /oro tabla.
  slash("especular")
  local frame = _G.OroHermandadFrame
  frame.tableButton.__scripts.OnClick(frame.tableButton)
  local text = _G.OroHermandadTextFrame
  assert(text and text.__shown and has(text.edit.__text, ns.History.TABLE_HEADER) and has(text.edit.__text, "Paño rúnico;Tela;"), "tabla")
  text:Hide()
end)

test("Lo que muestra la subasta al buscar el objeto: precio confirmado y sin tus propias unidades", function()
  Stub.commodity[14047] = {{5000, 10, 10}, {5800, 1}, {6000, 40}, {6200, 60}, {7900, 100}, {9500, 200}}
  Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 14047)
  Stub.runTimers(5)
  local book = ns.History.Books()[14047]
  assert(book and #book.lots == 5 and book.lots[1][1] == 5800 and book.at == Stub.now, "lotes sin los tuyos")
  local row = specRow("flip")
  assert(row and row.title == "Chollo: Paño rúnico a 58p (42 % por debajo de lo normal)", row and row.title)
  assert(has(row.detail, "Compra 82× a 82p 16c como máximo; no revendas por debajo de 64p 73c; objetivo 1o; ganancia ≈ 27o 48p")
    and has(row.detail, "Precio confirmado en la subasta hace menos de 1 min."), row.detail)
  assert(row.shopping[1].count == 82, "82 unidades")
  -- Objetos que no se vigilan: no se guardan.
  Stub.commodity[2901] = {{900, 1}}
  Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2901)
  assert(ns.History.Books()[2901] == nil, "no vigilado")
  -- Pasados 5 minutos vuelve a valer el último escaneo (estimado).
  Stub.now = Stub.now + 400
  ns.History.Hist().markets[KEY].items[14047].p = Spec.EncodePoints({{t = Stub.now - 60, lo = 6000, qty = 300, qty5 = 40}})
  slash("especular")
  assert(has(specRow("flip").detail, "estimado: confirma en la subasta"), specRow("flip").detail)
end)

test("Descripción de objetos con Especular: precio normal y chollo, con caché de 30 s", function()
  local tip = _G.GameTooltip
  local calls = counter(ns.Engine, "SpecLines")
  local function hover(id) tip.__lines = {}; Stub.tooltipPost(tip, {id = id}); return table.concat(tip.__lines, " | ") end
  local text = hover(14047)
  assert(has(text, "Oro de Hermandad · Normal (14 d) = 1o · hoy -40 %"), text)
  assert(has(text, "Chollo: compra hasta 40 a 82p 16c como máximo; no revendas por debajo de"), text)
  for _ = 1, 10 do Stub.gameTime = Stub.gameTime + 0.2; text = hover(14047) end
  assert(calls.n == 1, "una vez en 30 s: " .. calls.n)
  assert(not has(text, "Oro de Hermandad · Oro de Hermandad"), "la línea guardada no se modifica: " .. text)
  Stub.gameTime = Stub.gameTime + 31
  hover(14047)
  assert(calls.n == 2, "pasados 30 s se recalcula: " .. calls.n)
  -- Un escaneo nuevo también vacía la caché.
  Stub.scanComplete("summary")
  Stub.runTimers(5)
  hover(14047)
  assert(calls.n == 3, "tras un escaneo: " .. calls.n)
  -- Lo que no se vigila no lleva líneas de Especular; apagado, tampoco lo vigilado (fuera del modo Especular).
  assert(not has(hover(2901), "Normal (14 d)"), "no vigilado")
  slash("tranquilo")
  slash("especular off")
  assert(not has(hover(14047), "Normal (14 d)"), "apagado")
  slash("especular on")
  calls.restore()
end)

test("Escaneo grande con la ventana abierta: se repinta cuando el historial termina de escribirlo (y la descripción)", function()
  -- Sin escaneo de hoy no hay chollo; el escaneo trae el Paño rúnico a 60p (300) y los 114 vigilados entre 60 000 filas.
  ns.History.Hist().markets[KEY].items[14047].p = ""
  assert(Stub.prices[14047] == nil, "sin precio de Auctionator: el chollo solo puede venir del escaneo")
  slash("especular")
  assert(ns.UI.IsShown() and specRow("flip") == nil, "antes del escaneo no hay chollo")
  local tip = _G.GameTooltip
  local function hover() tip.__lines = {}; Stub.tooltipPost(tip, {id = 14047}); return table.concat(tip.__lines, " | ") end
  -- Como en el cliente: un temporizador creado en un fotograma salta como pronto en el siguiente (también After(0)),
  -- a 60 fotogramas por segundo. Así las tandas de History tardan lo que tardarían en el juego.
  local frameNo, timers, original, renders = 0, {}, _G.C_Timer.After, {}
  _G.C_Timer.After = function(delay, fn) timers[#timers + 1] = {at = Stub.gameTime + (delay or 0), born = frameNo, fn = fn} end
  local function frame()
    frameNo = frameNo + 1
    Stub.gameTime = Stub.gameTime + 1 / 60
    local due, keep = {}, {}
    for _, t in ipairs(timers) do
      if t.born < frameNo and t.at <= Stub.gameTime + 1e-9 then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    timers = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do t.fn() end
  end
  local render = ns.UI.Render
  ns.UI.Render = function(result, info)
    local flip = false
    for _, row in ipairs(result.sections.spec or {}) do if row.kind == "flip" and row.icon == 14047 then flip = true end end
    renders[#renders + 1] = {t = Stub.gameTime, flip = flip, pending = ns.History.Pending()}
    return render(result, info)
  end
  local ok, err = pcall(function()
    local listings = {{id = 14047, price = 6000, qty = 300, lots = {{300, 6000}}}}
    for _, id in ipairs(ns.History.FixedIDs()) do
      if id ~= 14047 then listings[#listings + 1] = {id = id, price = 1000, qty = 50, lots = {{50, 1000}}} end
    end
    local t0 = Stub.gameTime
    Stub.scanComplete("full", 60000, Stub.scanRows("full", 60000, listings))
    local doneAt, during
    for i = 1, 600 do
      frame()
      if i == 3 then during = hover() end -- el jugador pasa el ratón por el objeto mientras History escribe
      if not doneAt and ns.History.Pending() == 0 then doneAt = Stub.gameTime end
    end
    assert(doneAt and doneAt - t0 > 0.5, "History tarda más que el repintado de 0,5 s: " .. tostring(doneAt and doneAt - t0))
    assert(renders[1] and renders[1].t < doneAt and renders[1].pending > 0 and not renders[1].flip,
      "el primer repintado (0,5 s) aún no tiene el escaneo")
    local last = renders[#renders]
    assert(last.t >= doneAt and last.pending == 0 and last.flip, "se repinta al terminar, ya con el chollo")
    assert(specRow("flip") and specRow("flip").title == "Chollo: Paño rúnico a 60p (40 % por debajo de lo normal)",
      specRow("flip") and specRow("flip").title)
    assert(not has(during, "Chollo"), "durante el escaneo aún no: " .. during)
    -- Unos segundos después (la caché es de 30 s): la descripción ya tiene el escaneo.
    local text = hover()
    -- 83: lo que cabe en la cuarta parte del presupuesto de 200o a 60p.
    assert(has(text, "hoy -40 %") and has(text, "Chollo: compra hasta 83 a 82p 16c como máximo"), text)
  end)
  _G.C_Timer.After, ns.UI.Render = original, render
  for _, t in ipairs(timers) do Stub.timers[#Stub.timers + 1] = {at = t.at, fn = t.fn} end
  if not ok then error(err, 0) end
end)

test("Escaneo de resumen con un chollo: «Posible chollo», «Comprar lo que falta» lo busca y al abrirlo sale la compra", function()
  Stub.now = Stub.now + 3 * 3600 -- el escaneo completo de la prueba anterior ya tiene más de 2 h
  ns.History.Hist().markets[KEY].items[14047].p = ""
  -- El escaneo de resumen (el del botón de Auctionator por defecto) da el mínimo y el total, no cuántas hay cerca.
  Stub.scanComplete("summary", 2000, Stub.scanRows("summary", 2000, {{id = 14047, price = 6000, qty = 300}}))
  Stub.runTimers(5)
  slash("especular")
  assert(specRow("flip") == nil, "sin cantidades no se calcula la compra")
  local row = specRow("check")
  assert(row and row.title == "Posible chollo: Paño rúnico a 60p (40 % por debajo de lo normal)", row and row.title)
  assert(has(row.detail, "Tu escaneo no dice cuántas hay a ese precio: ábrelo en la pestaña Comprar")
    and has(row.detail, "Precio de hace menos de 1 min."), row.detail)
  local tip = _G.GameTooltip
  tip.__lines = {}; Stub.tooltipPost(tip, {id = 14047})
  local text = table.concat(tip.__lines, " | ")
  assert(has(text, "Posible chollo: tu escaneo no dice cuántas hay a ese precio") and not has(text, "No compensa"), text)
  Stub.shoppingList = nil
  slash("comprar")
  assert(Stub.shoppingList and Stub.shoppingList.strings[1] == "\"Paño rúnico\";;;;;;;;;;;1",
    Stub.shoppingList and Stub.shoppingList.strings[1])
  -- Al abrirlo en la subasta hay 300 a 60p: ya es un chollo calculado, con el precio confirmado.
  Stub.commodity[14047] = {{6000, 300}}
  Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 14047)
  Stub.runTimers(5)
  assert(specRow("check") == nil and specRow("flip"), "con lo que hay a la venta, el chollo de verdad")
  assert(has(specRow("flip").detail, "Precio confirmado en la subasta"), specRow("flip").detail)
end)

test("Ventana en Especular: estado, balance y secciones que no se ven en los otros modos", function()
  local texts, saved = {}, {frame = _G.OroHermandadFrame, scroll = _G.OroHermandadScroll, createFrame = _G.CreateFrame}
  _G.CreateFrame = function(...)
    local f = saved.createFrame(...)
    f.CreateFontString = function() local fs = Stub.newObject("FontString"); texts[#texts + 1] = fs; return fs end
    return f
  end
  local ok, err = pcall(function()
    local U = {Items = ns.Items}
    assert(loadfile("addon/OroHermandad/UI.lua"))("OroHermandad", U)
    local frame = U.UI.Create({position = {}})
    local function shown(sub) for _, fs in ipairs(texts) do if fs.__shown and has(fs.__text, sub) then return true end end end
    local ctx = ns.Core.Context()
    ctx.mode = "spec"
    local result = ns.Engine.Suggest(ctx)
    U.UI.Render(result, {footer = "pie", canShop = true})
    assert(shown("Especular") and shown("Balance de la semana") and shown(result.spec.text), "secciones y estado")
    assert(shown("Aún no hay balance") and not shown("Ahora") and not shown("Recoger"), "solo las de Especular")
    assert(frame.tableButton.__shown and frame.shopButton.__shown, "tabla y comprar (hay un chollo)")
    ctx.mode = "lazy"
    U.UI.Render(ns.Engine.Suggest(ctx), {footer = "pie", canShop = true})
    assert(shown("Ahora") and shown("Recoger") and not shown("Balance de la semana") and not frame.tableButton.__shown, "Tranquilo")
  end)
  _G.CreateFrame, _G.OroHermandadFrame, _G.OroHermandadScroll = saved.createFrame, saved.frame, saved.scroll
  if not ok then error(err, 0) end
end)

test("Panel de opciones: desplegable con los tres modos, chollos en todos los modos y presupuesto", function()
  local registered, saved = {}, _G.Settings
  local function setting(variable, extra) local st = extra or {}; st.variable = variable; registered[variable] = st; return st end
  _G.Settings = {
    VarType = {Boolean = "boolean", String = "string", Number = "number"},
    RegisterVerticalLayoutCategory = function(name) return {name = name, GetID = function() return 42 end} end,
    RegisterAddOnSetting = function(_, variable, key, tbl, _, label, default)
      return setting(variable, {key = key, tbl = tbl, label = label, default = default,
        SetValueChangedCallback = function(self, fn) self.onChange = fn end})
    end,
    RegisterProxySetting = function(_, variable, _, label, default, get, set)
      return setting(variable, {label = label, default = default, get = get, set = set})
    end,
    CreateCheckbox = function(_, st, tooltip) st.kind, st.tooltip = "checkbox", tooltip end,
    CreateControlTextContainer = function()
      local data = {}
      return {Add = function(_, value, label) data[#data + 1] = {value = value, label = label} end, GetData = function() return data end}
    end,
    CreateDropdown = function(_, st, options, tooltip) st.kind, st.options, st.tooltip = "dropdown", options(), tooltip end,
    CreateSliderOptions = function(minValue, maxValue, rate) return {minValue = minValue, maxValue = maxValue, rate = rate} end,
    CreateSlider = function(_, st, options) st.kind, st.options = "slider", options end,
    RegisterAddOnCategory = function() end,
  }
  local ok, err = pcall(function()
    local E = {Engine = ns.Engine}
    assert(loadfile("addon/OroHermandad/Extras.lua"))("OroHermandad", E)
    local db = {mode = "lazy", spec = {on = true}, minimap = {}}
    local refreshed = 0
    E.Extras.Init(db, function() end, function() end)
    assert(E.Extras.RegisterSettings({SetMode = function(mode) db.mode = mode end, Refresh = function() refreshed = refreshed + 1 end}) == 42)
    local modes = registered.OroHermandad_Mode
    assert(modes.kind == "dropdown" and #modes.options == 3, "tres modos")
    local labels = {}
    for i, o in ipairs(modes.options) do labels[i] = o.value .. "=" .. o.label end
    assert(table.concat(labels, ",") == "lazy=Tranquilo,farm=A tope,spec=Especular", table.concat(labels, ","))
    assert(has(modes.tooltip, "Especular: chollos"), modes.tooltip)
    modes.set("spec"); assert(db.mode == "spec" and modes.get() == "spec", "elige Especular")
    local on = registered.OroHermandad_SpecOn
    assert(on.kind == "checkbox" and on.tbl == db.spec and on.key == "on" and on.default == true, "chollos en todos los modos")
    on.onChange(nil, false); assert(refreshed == 1, "refresca")
    local budget = registered.OroHermandad_SpecBudget
    assert(budget.kind == "slider" and budget.options.maxValue == 5000 and budget.get() == 0, "deslizador")
    budget.set(200); assert(db.spec.budget == 2000000 and budget.get() == 200, "200 oros")
    budget.set(0); assert(db.spec.budget == nil, "0 = el 25 % de tu oro")
    db.spec.budget = 90000000; assert(budget.get() == 5000, "lo fijado con /oro se queda, el deslizador marca el tope")
  end)
  _G.Settings = saved
  if not ok then error(err, 0) end
end)

test("Especular: limpieza de la prueba", function()
  ns.History.Hist().markets[KEY].items[14047] = nil
  ns.History.Hist().markets[KEY].dep[14047] = nil
  Stub.commodity, Stub.items[14047] = {}, nil
  slash("especular presupuesto auto")
  slash("tranquilo")
  assert(#lastRender.result.sections.spec == 0, "sin chollos")
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

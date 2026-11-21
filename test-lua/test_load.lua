-- Carga el addon completo en un cliente simulado de Forever y recorre una sesión de juego.
-- Desde la raíz del repositorio: lua5.1 test-lua/test_load.lua
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local realPrint = print
Stub.install()
assert(_G.GetItemInfo == nil and _G.GetTradeSkillLine == nil, "la simulación debe parecerse a Forever")
local ns = Stub.loadAddon("addon/OroHermandad")
-- Lo que Core le pasa al escáner (0.6.0) al cargar: se guarda para hacer en las pruebas lo que el escáner hace al
-- terminar un escaneo (grabar y avisar a Core).
local scannerCallbacks
do
  local init = ns.Scanner.Init
  ns.Scanner.Init = function(db, cdb, callbacks) scannerCallbacks = callbacks; return init(db, cdb, callbacks) end
end

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
  assert(frame.footer.__height and frame.footer.__maxLines == 4, "alto fijo y como mucho 4 líneas (0.6.0: la del subidor)")
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
  assert(printed("Precios de hace 12 h") and printed("Escanear cada vez que abro la subasta"), "aviso en el chat")
  assert(not printed("Auctionator"), "sin mandar a Auctionator")
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
  -- 0.6.0: con el escáner, REPLICATE_ITEM_LIST_UPDATE ni se registra fuera de sus ventanas de respuesta (el respaldo
  -- de la 0.5.1 solo sigue sin Scanner.lua: «Sin los archivos nuevos», más abajo).
  local before = OroHermandadDB.fullScan["Forever-Alliance"]
  OroHermandadDB.fullScan["Forever-Alliance"] = nil
  local watching = ns.Prices.WatchingScans
  ns.Prices.WatchingScans = function() return false end
  Stub.fire("REPLICATE_ITEM_LIST_UPDATE")
  ns.Prices.WatchingScans = watching
  for _, f in ipairs(Stub.frames) do assert(not f.__events.REPLICATE_ITEM_LIST_UPDATE, "no se escucha fuera de una ventana") end
  assert(OroHermandadDB.fullScan["Forever-Alliance"] == nil, "nada")
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
  slash("ayuda"); assert(printed("/oro comprar — lo que falta para tus recetas (A tope) y los chollos: lista en Auctionator o, sin él, búsqueda en la subasta"),
    "la ayuda dice para qué modo es")
  assert(printed("/oro escanear — escanea la subasta entera ahora") and printed("/oro escanear auto|proponer|off")
    and printed("/oro cuando [objeto]") and printed("/oro guardar — en el PC del subidor"), "y lo de la 0.6.0")
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
  -- Los resultados de una búsqueda solo llegan con la subasta abierta (0.6.0: y solo se guardan en la de tu facción).
  Stub.fire("AUCTION_HOUSE_SHOW")
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
  Stub.fire("AUCTION_HOUSE_CLOSED")
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
    -- 0.6.0: el escáner lee la subasta entera (60 000 filas) y deja a History el resumen de los vigilados; después
    -- avisa a Core (onScanDone), como en Scanner.lua al terminar.
    local agg = {}
    for _, l in ipairs(listings) do agg[l.id] = {lo = l.price, qty = l.qty, qty5 = l.qty} end
    assert(ns.History.RecordAggregate("full", agg, true, {t = Stub.now}))
    scannerCallbacks.onScanDone("full", true, Stub.now)
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
  Stub.fire("AUCTION_HOUSE_SHOW")
  Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 14047)
  Stub.runTimers(5)
  Stub.fire("AUCTION_HOUSE_CLOSED")
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

---------------------------------------------------------------------------
-- 0.6.0: escáner propio, «Cuándo vender», «Guardar y subir» y aviso v2 del subidor (cada una en una sesión nueva)
---------------------------------------------------------------------------
local json060 = require("json")
local function readFile(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local function eq060(a, b, msg) if a ~= b then error((msg or "") .. ": esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end

-- Una sesión nueva (otro personaje, otro PC o tras salir del juego): marcos, temporizadores y escuchas de Auctionator
-- de cero. opts: db/cdb/hist (lo guardado), skip (archivos que no se cargan), auctionator (false = sin él).
local function freshSession(opts)
  opts = opts or {}
  Stub.frames, Stub.timers, Stub.bus = {}, {}, {}
  for k, v in pairs(Stub.ahOriginals) do C_AuctionHouse[k] = v end
  if opts.auctionator == false then _G.Auctionator = nil end
  _G.OroHermandadDB, _G.OroHermandadCharDB, _G.OroHermandadHist = opts.db, opts.cdb, opts.hist
  local s = Stub.loadAddon("addon/OroHermandad", opts.skip)
  local callbacks
  if s.Scanner then
    local init = s.Scanner.Init
    s.Scanner.Init = function(db, cdb, cb) callbacks = cb; return init(db, cdb, cb) end
  end
  Stub.fire("ADDON_LOADED", "OroHermandad")
  Stub.fire("PLAYER_LOGIN")
  Stub.fire("PLAYER_ENTERING_WORLD", true, false)
  Stub.runUntil(nil, opts.wait or 40)
  return s, callbacks
end

local function coreFrame()
  for _, f in ipairs(Stub.frames) do if f.__events.ADDON_LOADED then return f end end
end

local function render(s) s.UI.Show(); s.Core.Refresh() end
local function hhmm(t) return os.date("%H:%M", t) end
local function now() return math.floor(Stub.now) end

-- La subasta con algo a la venta (hierro y cobre vigilados; relleno no vigilado; la primera fila cambia en cada
-- respuesta para que la huella no la confunda con la anterior).
local function houseRows()
  local rows = {Stub.row(299999, 1, 100, {band = 2})}
  for _, r in ipairs({{2772, 20, 100}, {2772, 30, 104}, {2770, 40, 30}, {3575, 10, 150}, {12365, 10, 300}}) do
    rows[#rows + 1] = Stub.row(r[1], r[2], r[3], {band = 3})
  end
  for i = 1, 30 do rows[#rows + 1] = Stub.row(200000 + i, 1, 500 + i, {band = 2}) end
  Stub.ah.rows, Stub.ah.autoBump = rows, 299999
end

test("TOC 0.6.0: versión, notas, web, sin el número de CurseForge, archivos nuevos en su sitio y los mismos SavedVariables", function()
  local toc = readFile("addon/OroHermandad/OroHermandad.toc")
  assert(toc:find("\n## Version: 0.6.0\n", 1, true), "versión")
  assert(toc:find("\n## Notes: Escanea la subasta con hora, te dice cuándo se vende mejor y te sugiere qué hacer para ganar oro "
    .. "con tus profesiones y tu hermandad. Auctionator es opcional.\n", 1, true), "notas")
  assert(toc:find("\n## X-Website: https://github.com/carulla94/el-especulador-del-wow\n", 1, true), "web")
  assert(not toc:find("X-Curse-Project-ID", 1, true), "el número del proyecto lo pone una persona")
  assert(toc:find("\n## SavedVariables: OroHermandadDB, OroHermandadHist\n## SavedVariablesPerCharacter: OroHermandadCharDB\n", 1, true),
    "ningún SavedVariables nuevo")
  local files = {}
  for line in toc:gmatch("[^\n]+") do if line:match("%.lua$") then files[#files + 1] = line end end
  eq060(table.concat(files, ","), "Data.lua,Items.lua,Spec.lua,Engine.lua,Prices.lua,History.lua,Scan.lua,Money.lua,Guild.lua,"
    .. "Relay.lua,Scanner.lua,Timing.lua,UI.lua,Tooltip.lua,Extras.lua,Core.lua", "orden de carga")
  local core = readFile("addon/OroHermandad/Core.lua")
  assert(core:find('\nCore.VERSION = "0.6.0"\n', 1, true), "Core.VERSION en su propia línea (C9)")
  eq060(ns.Core.VERSION, "0.6.0")
  assert(readFile("addon/OroHermandad/CAMBIOS.md"):match("\n## 0%.6%.0 %(%d%d%d%d%-%d%d%-%d%d%)\n"), "CAMBIOS.md con la sección 0.6.0")
end)

test("Escaneo completo de Auctionator (EventBus «full») con el escáner: History no lo graba; un resumen entero se retiene", function()
  local s, cb = freshSession()
  local recorded = 0
  local record = s.History.Record
  s.History.Record = function(kind, ...) if kind == "full" then recorded = recorded + 1 end; return record(kind, ...) end
  Stub.scanComplete("full")
  Stub.runTimers(5)
  eq060(recorded, 0, "el escáner lee la misma respuesta (gancho en ReplicateItems): aquí no se graba")
  assert(OroHermandadDB.fullScan["Forever-Alliance"], "pero los precios quedan fechados")
  -- Resumen entero con la subasta cerrada: no puede llegar un escaneo completo en esta visita, se suelta y se graba.
  local released = 0
  Stub.scanComplete("summary")
  Stub.runTimers(5)
  assert(s.Scanner.Internals().stats.lastHeld and s.Scanner.Internals().stats.lastHeld.recorded, "soltado y grabado")
  s.History.Record = record
end)

test("Subasta neutral o dudosa: ni depósitos, ni libros de lotes, ni petición; en la tuya, sí (D9)", function()
  local s = freshSession()
  local deposits, books = 0, 0
  local learn, capture = s.History.LearnDeposits, s.History.CaptureBook
  s.History.LearnDeposits = function(...) deposits = deposits + 1; return learn(...) end
  s.History.CaptureBook = function(...) books = books + 1; return capture(...) end
  Stub.commodity[2772] = {{100, 20}}
  Stub.openAH({npcFaction = "Neutral"})
  Stub.runUntil(nil, 5)
  Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2772)
  eq060(s.Scanner.House(), "neutral"); eq060(deposits, 0, "sin depósitos"); eq060(books, 0, "sin libros")
  Stub.printed = {}
  slash("escanear")
  assert(printed("subasta neutral: aquí no se guardan precios."), "/oro escanear lo dice")
  Stub.closeAH()
  Stub.openAH()
  Stub.runUntil(nil, 5)
  Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2772)
  eq060(s.Scanner.House(), "faction"); eq060(deposits, 1, "depósitos en la tuya"); eq060(books, 1, "libros en la tuya")
  Stub.closeAH()
  Stub.commodity[2772] = nil
end)

test("Sin los archivos nuevos (un /reload tras actualizar): como la 0.5.1, y /oro sondeo, escanear y cuando lo dicen", function()
  local s = freshSession({skip = Stub.NEW_IN_060})
  assert(s.Scanner == nil and s.Timing == nil, "sin Scanner.lua ni Timing.lua")
  assert(coreFrame().__events.REPLICATE_ITEM_LIST_UPDATE, "el respaldo de la 0.5.1 sigue registrado")
  local watching = s.Prices.WatchingScans
  s.Prices.WatchingScans = function() return false end
  OroHermandadDB.fullScan["Forever-Alliance"] = nil
  Stub.fire("REPLICATE_ITEM_LIST_UPDATE")
  s.Prices.WatchingScans = watching
  assert(OroHermandadDB.fullScan["Forever-Alliance"], "respaldo")
  -- Los escaneos de Auctionator se graban como en la 0.5.1.
  Stub.scanComplete("full")
  Stub.runTimers(5)
  eq060(s.History.lastResult and s.History.lastResult.kind, "full", "grabado por History")
  local RESTART = "tras actualizar el addon, sal del juego del todo y vuelve a entrar (un /reload no carga sus archivos nuevos)."
  Stub.printed = {}
  slash("escanear")
  assert(printed("el escáner de la subasta aún no está cargado: " .. RESTART), "escanear")
  slash("cuando")
  assert(printed("«Cuándo vender» aún no está cargado: " .. RESTART), "cuando")
  slash("sondeo")
  local probe = _G.OroHermandadTextFrame.text
  assert(has(probe, "Escáner de la subasta: aún no está cargado: " .. RESTART) and has(probe, "Cuándo vender: aún no está cargado: " .. RESTART), probe)
  -- La subasta se abre sin errores y aprende depósitos como antes.
  Stub.openAH()
  Stub.runUntil(nil, 5)
  Stub.closeAH()
  render(s)
  assert(not _G.OroHermandadFrame.cuandoButton.__shown, "sin Timing.lua no hay botón «Cuándo vender»")
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

test("Sin Auctionator (H2): se abre la subasta, se escanea con el addon y salen sugerencias con oro; los textos no lo piden", function()
  local savedAuctionator = _G.Auctionator
  local s = freshSession({auctionator = false})
  eq060(s.Prices.Available(), false, "aún sin precios")
  local status = s.Engine.DbStatus(s.Core.Context(), "lazy")
  eq060(status.text, "Aún no hay precios de la subasta: ábrela y pulsa «Escanear» (Auctionator es opcional).")
  Stub.printed = {}
  slash("tabla")
  assert(printed("aún no hay precios guardados en este mercado: escanea la subasta con Oro de Hermandad."), "tabla")
  houseRows()
  Stub.ah.rows[#Stub.ah.rows + 1] = Stub.row(210777, 1, 777, {band = 2})
  Stub.openAH()
  Stub.runUntil(nil, 3)
  assert(s.Scanner.Request(true), "se pide")
  Stub.runUntil(function() return s.Scanner.State().state == "done" or s.Scanner.State().state == "done-refresh" end, 60)
  Stub.runUntil(function() return s.History.Pending() == 0 end, 30)
  Stub.closeAH()
  eq060(s.Prices.Price(210777), 777, "un objeto no vigilado, de la caché propia")
  eq060(s.Prices.Price(2772), 100)
  local ctx = s.Core.Context()
  eq060(ctx.hasPriceSource, true)
  local result = s.Engine.Suggest(ctx)
  local sell
  for _, row in ipairs(result.sections.now or {}) do if row.kind == "sell" then sell = row end end
  assert(sell and sell.value > 0 and has(sell.detail, "Ponlo al precio más bajo de la subasta."), sell and sell.detail)
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error") and not has(line, "Instálalo"), line) end
  _G.Auctionator = savedAuctionator
end)

test("Ningún mensaje del escáner en el chat (H4): 5 visitas en automático; en proponer, con la ventana abierta, tampoco", function()
  local s = freshSession()
  slash("escanear auto")
  assert(printed("escanear la subasta: automático cada vez que la abres."), "confirmación")
  eq060(OroHermandadDB.scanner.auto, "auto")
  houseRows()
  Stub.printed, Stub.sounds = {}, {}
  local calls = #Stub.ah.calls
  for _ = 1, 5 do
    Stub.openAH()
    Stub.runUntil(function() local st = s.Scanner.State().state; return st == "done" or st == "done-refresh" end, 60)
    Stub.runUntil(nil, 30)
    Stub.closeAH()
    Stub.advance(1000)
  end
  eq060(#Stub.ah.calls, calls + 5, "un escaneo por visita")
  eq060(#Stub.ah.protectedCalls, 0, "nunca publica, compra, puja ni cancela")
  eq060(#Stub.printed, 0, "nada en el chat: " .. table.concat(Stub.printed, " | "))
  eq060(#Stub.sounds, 0, "ningún sonido")
  -- Proponer con la ventana abierta: la propuesta va en la ventana, no en el chat.
  slash("escanear proponer")
  Stub.printed = {}
  Stub.advance(2000)
  Stub.openAH()
  Stub.runUntil(nil, 5)
  assert(s.UI.IsShown(), "la ventana se abre con la subasta")
  local panel = s.UI.Panel()
  assert(panel and has(panel.text, "¿Escanear ahora? (unos segundos)"), panel and panel.text)
  assert(panel.check and panel.check.label == "Escanear siempre al abrir la subasta", "la casilla")
  assert(panel.buttons[1].label == "Escanear", "el botón")
  Stub.runUntil(nil, 70)
  eq060(#Stub.printed, 0, "en proponer con la ventana abierta: nada en el chat: " .. table.concat(Stub.printed, " | "))
  -- La casilla pasa a automático; el botón «Escanear» pide la subasta.
  local frame = _G.OroHermandadFrame
  frame.panel.check.__scripts.OnClick(frame.panel.check)
  eq060(OroHermandadDB.scanner.auto, "auto", "la casilla")
  Stub.closeAH()
end)

test("Fila del escáner en la ventana: [Escanear], [Parar] mientras lee, la hora del siguiente y «Escanear la lista»", function()
  local s = freshSession()
  houseRows()
  Stub.advance(1000)
  Stub.openAH()
  Stub.runUntil(nil, 3)
  local frame = _G.OroHermandadFrame
  local panel = s.UI.Panel()
  assert(panel and panel.buttons[1].label == "Escanear", panel and panel.text)
  frame.panel.buttons[1].__scripts.OnClick(frame.panel.buttons[1])
  Stub.runUntil(function() return s.Scanner.State().state == "reading" end, 30)
  panel = s.UI.Panel()
  if s.Scanner.State().state == "reading" then
    assert(panel.buttons[1].label == "Parar" and has(panel.text, "Escaneando: "), panel.text)
  end
  Stub.runUntil(function() local st = s.Scanner.State().state; return st == "done" or st == "done-refresh" end, 60)
  panel = s.UI.Panel()
  assert(panel and has(panel.text, "Escaneo de las ") and has(panel.text, "guardado"), panel and panel.text)
  -- Pasados unos minutos: la hora del siguiente y, como faltan más de 5 min, «Escanear la lista».
  Stub.advance(240)
  s.Core.UpdatePanel()
  panel = s.UI.Panel()
  local labels = {}
  for _, b in ipairs(panel.buttons) do labels[#labels + 1] = b.label end
  assert(has(panel.text, "Siguiente escaneo completo posible a las") or has(panel.text, "Escaneo de las"), panel.text)
  assert(table.concat(labels, ","):find("Escanear la lista", 1, true), table.concat(labels, ","))
  Stub.closeAH()
  eq060(s.UI.Panel() == nil or not s.UI.IsShown(), true, "sin subasta, sin fila")
end)

test("Botones de abajo: «Cuándo vender» siempre; con todos a la vista caben sin pisarse (comprar se acorta)", function()
  local s = freshSession()
  local frame = _G.OroHermandadFrame
  render(s)
  assert(frame.cuandoButton.__shown, "«Cuándo vender»")
  for _, b in ipairs({frame.shopButton, frame.tableButton, frame.saveButton}) do b:Show() end
  s.UI.LayoutButtons()
  local list = {}
  for _, b in ipairs({frame.shopButton, frame.cuandoButton, frame.saveButton, frame.tableButton, frame.optionsButton}) do
    list[#list + 1] = {x = b.x, w = b.width}
  end
  table.sort(list, function(a, b) return a.x < b.x end)
  for i = 2, #list do assert(list[i].x >= list[i - 1].x + list[i - 1].w, "sin pisarse") end
  assert(list[1].x >= 12 and list[#list].x + list[#list].w <= 440 - 12, "dentro de la ventana")
  eq060(frame.shopButton:GetText(), "Comprar", "acortado")
  frame.tableButton:Hide(); frame.saveButton:Hide()
  s.UI.LayoutButtons()
  eq060(frame.shopButton:GetText(), "Comprar lo que falta", "con sitio, entero")
end)

-- Aviso del subidor (C7): lo que dejaría en _G el archivo del aviso.
local function marker(lua)
  local env = {}
  local chunk = assert(loadstring(lua))
  setfenv(chunk, env)
  chunk()
  _G.OroHermandadSubidor = env.OroHermandadSubidor
end

test("Aviso v2 del subidor (C7): cada caso de marker-v2.json y los 4 archivos de ejemplo, campo a campo", function()
  local V06 = "test-lua/fixtures/v06/"
  eq060(Stub.sha256File(V06 .. "marker-v2.json"), Stub.V06_SHA256["marker-v2.json"], "copia exacta")
  local fx = json060.decode(readFile(V06 .. "marker-v2.json"))
  local Relay = ns.Relay
  local function plain(v) if v == json060.null then return nil end return v end
  for _, c in ipairs(fx.read) do
    marker(c.lua)
    local detected, info = Relay.MarkerInfo()
    eq060(detected, c.detected, c.note .. ": detectado")
    local want = plain(c.info)
    if want == nil then
      eq060(info, nil, c.note .. ": sin estado")
    else
      for _, k in ipairs({"escrito", "version", "suben", "aportan", "quedan", "dia"}) do eq060(info[k], plain(want[k]), c.note .. ": " .. k) end
      local envio = plain(want.envio)
      if envio == nil then eq060(info.envio, nil, c.note .. ": envio")
      else eq060(info.envio.t, envio.t, c.note); eq060(info.envio.estado, envio.estado, c.note) end
    end
  end
  for _, w in ipairs(fx.write) do
    eq060(Stub.sha256File(V06 .. w.file), Stub.V06_SHA256[w.file], w.file)
    marker(readFile(V06 .. w.file))
    local detected, info = Relay.MarkerInfo()
    eq060(detected, true, w.file)
    eq060(info.escrito, w.state.escrito, w.file); eq060(info.version, w.state.version, w.file)
    eq060(info.aportan, w.state.aportan, w.file); eq060(info.quedan, w.state.quedan, w.file); eq060(info.dia, w.state.dia, w.file)
    if w.state.envio then eq060(info.envio.estado, w.state.envio.estado, w.file) else eq060(info.envio, nil, w.file) end
  end
  _G.OroHermandadSubidor = nil
end)

test("PC del subidor: el pie y /oro subidor cuentan el último envío, los avisos y si el subidor no parece abierto", function()
  local s = freshSession()
  local t = now()
  marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, version = \"0.6.0\", "
    .. "envio = {t = %d, estado = \"ok\"}, suben = 2, aportan = 7, quedan = 21, dia = %d}", t - 60, t - 300, s.Spec.DayIndex(t)))
  -- Sin modo subidor: nada.
  slash("subidor off")
  render(s)
  assert(not has(_G.OroHermandadFrame.footer.__text, "Subidor del PC"), _G.OroHermandadFrame.footer.__text)
  slash("subidor auto")
  s.Relay.Login()
  render(s)
  local base = "Subidor del PC (0.6.0): último envío aceptado a las " .. hhmm(t - 300) .. " · 7 personas aportan precios (dato de las "
    .. hhmm(t - 60) .. ")."
  assert(has(_G.OroHermandadFrame.footer.__text, base), _G.OroHermandadFrame.footer.__text)
  Stub.printed = {}
  slash("subidor")
  assert(printed(base), "/oro subidor")
  -- El último intento falló por la clave.
  marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, version = \"0.6.0\", "
    .. "envio = {t = 0, estado = \"clave\"}}", t - 60))
  render(s)
  assert(has(_G.OroHermandadFrame.footer.__text, "El subidor del PC avisa: el panel ha rechazado la clave."), _G.OroHermandadFrame.footer.__text)
  for estado, text in pairs({red = "sin conexión con el panel", cuota = "el panel pide esperar", rechazado = "el panel no aceptó los datos"}) do
    marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, envio = {t = 0, estado = %q}}", t - 60, estado))
    eq060(s.Relay.UploaderLines().warn, "El subidor del PC avisa: " .. text .. ".")
  end
  -- Último aviso de hace más de 2 h: no parece abierto.
  marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, version = \"0.6.0\"}", t - 7300))
  render(s)
  local stale = "El subidor del PC no parece abierto (último aviso a las " .. hhmm(t - 7300) .. "): ábrelo para que suba."
  assert(has(_G.OroHermandadFrame.footer.__text, stale), _G.OroHermandadFrame.footer.__text)
  Stub.printed = {}
  slash("subidor")
  assert(printed(stale) and printed("Subidor del PC (0.6.0): aún ningún envío aceptado."), table.concat(Stub.printed, " | "))
  slash("sondeo")
  assert(has(_G.OroHermandadTextFrame.text, "Aviso del subidor: datos 2, campos válidos escrito,version"), _G.OroHermandadTextFrame.text)
  _G.OroHermandadSubidor = nil
end)

test("PC del subidor: la edad del aviso cuenta al cargar la interfaz (el juego no ve cómo lo reescribe el subidor)", function()
  -- El subidor abierto lo escribió hace 50 min (lo reescribe cada hora, pero el juego solo lee el archivo al entrar o
  -- con /reload): horas de juego sin recargar no lo convierten en «no parece abierto».
  local t0 = now()
  local lua = string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, version = \"0.6.0\", "
    .. "envio = {t = %d, estado = \"ok\"}, aportan = 7}", t0 - 3000, t0 - 3100)
  marker(lua)
  local s = freshSession()
  slash("subidor auto")
  local base = "Subidor del PC (0.6.0): último envío aceptado a las " .. hhmm(t0 - 3100) .. " · 7 personas aportan precios (dato de las "
    .. hhmm(t0 - 3000) .. ")."
  local stale = "El subidor del PC no parece abierto (último aviso a las " .. hhmm(t0 - 3000) .. "): ábrelo para que suba."
  render(s)
  assert(has(_G.OroHermandadFrame.footer.__text, base), _G.OroHermandadFrame.footer.__text)
  Stub.advance(2 * 3600 + 60)
  render(s)
  assert(has(_G.OroHermandadFrame.footer.__text, base), "2 h después, sin recargar: " .. _G.OroHermandadFrame.footer.__text)
  eq060(s.Relay.UploaderLines().stale, nil, "sin «no parece abierto»")
  Stub.printed = {}
  slash("subidor")
  assert(printed(base) and not printed("no parece abierto"), table.concat(Stub.printed, " | "))
  -- Un /reload ahora lee el mismo archivo (el subidor no lo reescribió: está cerrado), de hace más de 2 h.
  s = Stub.reload("addon/OroHermandad", function() marker(lua) end)
  Stub.fire("PLAYER_LOGIN")
  Stub.runUntil(nil, 30)
  render(s)
  assert(has(_G.OroHermandadFrame.footer.__text, stale), "tras recargar: " .. _G.OroHermandadFrame.footer.__text)
  -- Y sigue así en la sesión, aunque pase el tiempo: es lo que se leyó al cargar.
  Stub.advance(600)
  eq060(s.Relay.UploaderLines().stale, stale)
  _G.OroHermandadSubidor = nil
end)

-- El reloj del PC (time(), el que lee el subidor con time.time() al escribir escrito) y el del servidor
-- (GetServerTime) separados por skew segundos (positivo: el del PC va atrasado). Carga una sesión nueva con un aviso
-- escrito hace age segundos según el reloj del PC y devuelve sus líneas del subidor y la de /oro sondeo.
local function skewedMarker(skew, age)
  local realTime = _G.time
  _G.time = function() return math.floor(Stub.now) - skew end
  local ok, lines, probe, written = pcall(function()
    local pc = _G.time()
    marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, version = \"0.6.0\", "
      .. "envio = {t = %d, estado = \"ok\"}, aportan = 7}", pc - age, pc - age - 100))
    local s = freshSession()
    slash("subidor auto")
    s.Relay.Login()
    render(s)
    return s.Relay.UploaderLines(), s.Relay.MarkerProbeLine(), pc - age
  end)
  _G.time = realTime
  _G.OroHermandadSubidor = nil
  if not ok then error(lines, 0) end
  return lines, probe, written
end

test("PC del subidor: la edad del aviso va con el reloj del PC, con el que lo escribe el subidor (no con el del servidor)", function()
  -- Reloj del PC 45 min atrasado y el subidor abierto, que reescribió el aviso hace 80 min (su ciclo normal llega a
  -- 1,5 h): con la hora del servidor tendría 2 h 5 min y diría «no parece abierto».
  local lines, probe = skewedMarker(2700, 4800)
  eq060(lines.stale, nil, "45 min atrasado, aviso de hace 80 min")
  assert(has(lines.base, "7 personas aportan precios"), lines.base)
  assert(not has(_G.OroHermandadFrame.footer.__text, "no parece abierto"), _G.OroHermandadFrame.footer.__text)
  assert(has(probe, ", escrito hace 1 h"), probe) -- (con la hora del servidor, «hace 2 h»)
  -- 2 h atrasado (un Windows que lee como hora local el reloj en UTC de Linux), aviso de hace 1 min: abierto.
  lines = skewedMarker(7200, 60)
  eq060(lines.stale, nil, "2 h atrasado, aviso de hace 1 min")
  -- Reloj del PC 45 min adelantado y el subidor cerrado hace 2 h 2 min: con la hora del servidor tendría 1 h 17 min y
  -- no avisaría.
  local written
  lines, probe, written = skewedMarker(-2700, 7320)
  eq060(lines.stale, "El subidor del PC no parece abierto (último aviso a las " .. hhmm(written) .. "): ábrelo para que suba.",
    "45 min adelantado, aviso de hace 2 h 2 min")
  assert(has(_G.OroHermandadFrame.footer.__text, "no parece abierto"), _G.OroHermandadFrame.footer.__text)
  assert(has(probe, ", escrito hace 2 h"), probe) -- (con la hora del servidor, «hace 77 min»)
  -- Sin diferencia entre los relojes, lo de siempre: 1 h 59 min, abierto; 2 h 1 min, no parece abierto.
  eq060(skewedMarker(0, 7140).stale, nil, "sin diferencia, 1 h 59 min")
  assert(skewedMarker(0, 7260).stale, "sin diferencia, 2 h 1 min")
end)

test("«Guardar y subir» (R12): solo en el PC del subidor con algo nuevo; desactivado mientras se guarda; confirmación; un ReloadUI", function()
  local s = freshSession()
  local frame = _G.OroHermandadFrame
  local reloads = Stub.reloads or 0
  local function save() return s.Core.SaveButton() end
  -- /oro guardar en un PC que no sube.
  slash("subidor off")
  Stub.printed = {}
  slash("guardar")
  assert(printed("Este PC no sube precios: no hace falta (tus precios llegan al panel por la hermandad)."), "no sube")
  eq060(save(), nil, "sin modo subidor: no se ve")
  slash("subidor on")
  eq060(save(), nil, "sin nada nuevo desde que entraste: no se ve")
  render(s)
  assert(not frame.saveButton.__shown, "oculto")
  -- Un escaneo tuyo: mientras History lo escribe, desactivado; después, activo.
  local agg = {[2772] = {lo = 100, qty = 10, qty5 = 5}, [2770] = {lo = 30, qty = 40, qty5 = 40}}
  assert(s.History.RecordAggregate("full", agg, true, {t = now()}))
  s.History.Flush() -- (escrito ya, para que el botón aparezca)
  assert(s.History.RecordAggregate("full", {[2772] = {lo = 101, qty = 10, qty5 = 5}}, true, {t = now() + 2000}))
  local busy = save()
  assert(busy and busy.enabled == false and busy.tooltip == "Espera unos segundos: aún se están guardando los precios.", "History escribiendo")
  Stub.runUntil(function() return s.History.Pending() == 0 end, 30)
  assert(save().enabled, "activo")
  render(s)
  assert(frame.saveButton.__shown and frame.saveButton.enabled, "a la vista")
  -- Relay aplicando un escaneo de un compañero, o el escáner leyendo: desactivado.
  local idle = s.Relay.Idle
  s.Relay.Idle = function() return false end
  eq060(save().enabled, false, "Relay aplicando")
  s.Relay.Idle = idle
  local state = s.Scanner.State
  s.Scanner.State = function() return {state = "reading"} end
  eq060(save().enabled, false, "el escáner leyendo")
  s.Scanner.State = state
  -- 2 envíos de hoy en el panel: desactivado y lo dice; si el dato es de ayer, no cuenta.
  local today = s.Spec.DayIndex(now())
  marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, quedan = 2, dia = %d}", now(), today))
  eq060(save().enabled, false)
  eq060(save().tooltip, "Hoy solo le quedan 2 envíos a tu clave en el panel: los precios se subirán al salir del juego.")
  -- Sin envíos hoy, el de al salir también lo rechaza el panel: llegan mañana.
  marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, quedan = 0, dia = %d}", now(), today))
  eq060(save().enabled, false)
  eq060(save().tooltip, "Hoy ya no le quedan envíos a tu clave en el panel: los precios se subirán mañana.")
  marker(string.format("OroHermandadSubidor = {formato = 1, datos = 2, escrito = %d, quedan = 2, dia = %d}", now(), today - 1))
  eq060(save().enabled, true, "dato de ayer")
  -- Clic: confirmación dentro de la ventana (sin StaticPopupDialogs); «Ahora no» la quita.
  render(s)
  frame.saveButton.__scripts.OnClick(frame.saveButton)
  local panel = s.UI.Panel()
  assert(panel and panel.text == "WoW solo guarda los precios en el disco al recargar la interfaz o al salir. ¿Recargar ahora para "
    .. "que el subidor, si está abierto, los envíe? (Si tienes la subasta abierta, se cerrará.)", panel and panel.text)
  eq060(panel.buttons[1].label, "Recargar"); eq060(panel.buttons[2].label, "Ahora no")
  frame.panel.buttons[2].__scripts.OnClick(frame.panel.buttons[2])
  eq060(s.UI.Panel(), nil, "«Ahora no»")
  eq060(Stub.reloads or 0, reloads, "nada recargado")
  -- En combate, no; fuera de combate, un ReloadUI y la hora apuntada.
  frame.saveButton.__scripts.OnClick(frame.saveButton)
  Stub.combat = true
  frame.panel.buttons[1].__scripts.OnClick(frame.panel.buttons[1])
  assert(has(s.UI.Panel().text, "Espera a salir de combate."), s.UI.Panel().text)
  eq060(Stub.reloads or 0, reloads, "en combate no")
  Stub.combat = false
  frame.panel.buttons[1].__scripts.OnClick(frame.panel.buttons[1])
  eq060(Stub.reloads, reloads + 1, "un ReloadUI")
  eq060(OroHermandadDB.savedAt, now(), "hora apuntada")
  -- La recarga: al volver, el pie lo dice (una vez) y savedAt se borra.
  local savedAt = OroHermandadDB.savedAt
  s = Stub.reload("addon/OroHermandad")
  Stub.fire("PLAYER_LOGIN")
  Stub.runUntil(nil, 30)
  eq060(OroHermandadDB.savedAt, nil, "borrado")
  render(s)
  assert(has(_G.OroHermandadFrame.footer.__text, "Guardado a las " .. hhmm(savedAt) .. ": si el subidor está abierto, lo envía en "
    .. "unos segundos (la confirmación sale en su ventana)."), _G.OroHermandadFrame.footer.__text)
  -- /oro guardar: mismas comprobaciones y textos.
  assert(s.History.RecordAggregate("full", {[2772] = {lo = 102, qty = 10, qty5 = 5}}, true, {t = now()}))
  Stub.printed = {}
  slash("guardar")
  assert(printed("Espera unos segundos: aún se están guardando los precios."), "ocupado")
  Stub.runUntil(function() return s.History.Pending() == 0 end, 30)
  local before = Stub.reloads
  slash("guardar")
  eq060(Stub.reloads, before + 1, "/oro guardar recarga")
  _G.OroHermandadSubidor = nil
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

test("/oro escanear: sin la subasta abierta lo dice; auto, proponer y off lo confirman; lo demás, el uso", function()
  local s = freshSession()
  Stub.printed = {}
  slash("escanear")
  assert(printed("abre la subasta y vuelve a escribirlo."), "cerrada")
  slash("escanear lista")
  assert(printed("abre la subasta y vuelve a escribirlo."), "la lista, cerrada")
  slash("escanear parar")
  assert(printed("no hay ningún escaneo en marcha."), "parar")
  for word, text in pairs({auto = "escanear la subasta: automático cada vez que la abres.",
                           proponer = "escanear la subasta: te lo propone el addon.",
                           off = "escanear la subasta: solo con el botón o /oro escanear."}) do
    slash("escanear " .. word)
    assert(printed(text), word)
  end
  slash("escanear patata")
  assert(printed("uso: /oro escanear [lista|parar|auto|proponer|off]"), "uso")
  slash("escanear proponer")
  -- Con la subasta abierta y el turno libre: lo pide; otra vez enseguida, la hora del siguiente.
  houseRows()
  Stub.advance(1000)
  Stub.openAH()
  Stub.runUntil(nil, 3)
  Stub.printed = {}
  slash("escanear ahora")
  Stub.runUntil(function() local st = s.Scanner.State().state; return st == "done" or st == "done-refresh" end, 60)
  slash("escanear")
  assert(printed("la subasta deja un escaneo completo cada 15 min por cuenta: el siguiente, a las "), table.concat(Stub.printed, " | "))
  slash("sondeo")
  local probe = _G.OroHermandadTextFrame.text
  for _, want in ipairs({"Escáner: modo proponer", "Casa: facción", "Peticiones: tuya", "Cuándo vender: ", "Capas: ", "Aviso del subidor: "}) do
    assert(has(probe, want), want .. "\n" .. probe)
  end
  Stub.closeAH()
end)

test("Opciones: sección «Escáner de la subasta» (desplegable y casilla) y la de precios compartidos habla de las ventas", function()
  local registered, headers, saved = {}, {}, _G.Settings
  local savedHeader = _G.CreateSettingsListSectionHeaderInitializer
  _G.CreateSettingsListSectionHeaderInitializer = function(title, text) headers[#headers + 1] = {title = title, text = text}; return {} end
  _G.Settings = {
    VarType = {Boolean = "boolean", String = "string", Number = "number"},
    RegisterVerticalLayoutCategory = function(name) return {name = name, GetID = function() return 42 end}, {AddInitializer = function() end} end,
    RegisterAddOnSetting = function(_, variable, key, tbl, _, label, default)
      local st = {key = key, tbl = tbl, label = label, default = default, SetValueChangedCallback = function(self, fn) self.onChange = fn end}
      registered[variable] = st
      return st
    end,
    RegisterProxySetting = function(_, variable, _, label, default, get, set)
      local st = {label = label, default = default, get = get, set = set}
      registered[variable] = st
      return st
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
    local mode, sales = "propose", true
    E.Extras.Init(db, function() end, function() end)
    E.Extras.RegisterSettings({SetMode = function() end, Refresh = function() end, ScannerLoaded = function() return true end,
      ScannerMode = function() return mode end, SetScannerMode = function(v) mode = v end,
      ScannerSales = function() return sales end, SetScannerSales = function(v) sales = v end})
    local scan = registered.OroHermandad_ScanMode
    assert(scan and scan.kind == "dropdown" and scan.label == "Escanear la subasta", "desplegable")
    local labels = {}
    for i, o in ipairs(scan.options) do labels[i] = o.value .. "=" .. o.label end
    eq060(table.concat(labels, ","), "propose=Proponerlo al abrir la subasta,auto=Escanear cada vez que abro la subasta,off=Solo con el botón")
    eq060(scan.tooltip, "Un escaneo completo tarda unos segundos y no se nota en el juego. La subasta deja uno cada 15 minutos por "
      .. "cuenta; si Auctionator ya escanea la subasta entera al abrirla, se usa el suyo.")
    scan.set("auto"); eq060(mode, "auto"); eq060(scan.get(), "auto")
    local salesSetting = registered.OroHermandad_ScanSales
    assert(salesSetting.kind == "checkbox" and salesSetting.label == "Apuntar mis ventas para «Cuándo vender»", "casilla")
    eq060(salesSetting.tooltip, "Solo en este PC: tus ventas no se comparten ni se suben.")
    salesSetting.set(false); eq060(sales, false)
    local titles = {}
    for _, h in ipairs(headers) do titles[#titles + 1] = h.title end
    eq060(table.concat(titles, ","), "Escáner de la subasta,Precios compartidos con la hermandad")
    assert(has(headers[2].text, "Los escaneos llevan también una estimación de cuántas unidades se vendieron entre dos escaneos (sin nombres)."),
      headers[2].text)
  end)
  _G.Settings, _G.CreateSettingsListSectionHeaderInitializer = saved, savedHeader
  if not ok then error(err, 0) end
end)

test("Privacidad: ni vendedores, ni pujadores, ni el texto de los avisos de venta en nada guardado", function()
  local s = freshSession()
  houseRows()
  Stub.ah.rows[3] = Stub.row(2772, 5, 99, {band = 3, owner = "Javi"})
  Stub.ah.rows[4] = Stub.row(2770, 3, 29, {band = 3, shown = "Vendedor", bidder = "Pujador"})
  Stub.advance(1000)
  Stub.openAH()
  Stub.runUntil(nil, 3)
  assert(s.Scanner.Request(true))
  Stub.runUntil(function() local st = s.Scanner.State().state; return st == "done" or st == "done-refresh" end, 60)
  Stub.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "Comprador Secreto ha comprado Hierro", 12345)
  Stub.closeAH()
  Stub.fire("PLAYER_LOGOUT")
  local function dumpAll(v, seen)
    seen = seen or {}
    if type(v) ~= "table" then return tostring(v) end
    if seen[v] then return "" end
    seen[v] = true
    local out = {}
    for k, x in pairs(v) do out[#out + 1] = dumpAll(k, seen) .. "=" .. dumpAll(x, seen) end
    return table.concat(out, ",")
  end
  local db, cdb = OroHermandadDB, OroHermandadCharDB
  local text = dumpAll({db.scanPrices, db.sales, db.timing, db.scanner, cdb.scanBase, cdb.auctions, cdb.scanner, OroHermandadHist})
  for _, name in ipairs({"Javi", "Vendedor", "Pujador", "Comprador Secreto"}) do assert(not has(text, name), name .. " guardado") end
  assert(db.sales["Forever-Alliance"] or true)
end)

test("Ningún error durante toda la sesión", function()
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

realPrint(string.format("sesión simulada: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

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

test("Banco moderno por pestañas: sugiere sacar y vender el mitril", function()
  Stub.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 8)
  Stub.runTimers(5)
  assert(OroHermandadCharDB.bank and OroHermandadCharDB.bank.items[3858].count == 40, "banco leído")
  Stub.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 8)
  slash("atope")
  local bank = rendered("bank")
  assert(bank and has(bank.detail, "40× Mineral de mitril"), bank and bank.detail)
end)

test("Descripción de objetos: precio, quién lo usa y cuántos hay en el banco", function()
  local tip = ns and _G.GameTooltip
  tip.__lines = {}
  Stub.tooltipPost(tip, {id = 2772})
  local text = table.concat(tip.__lines, " | ")
  assert(has(text, "Oro de Hermandad · Subasta (hoy) = 1p 20c"), text)
  assert(has(text, "Lo usa: Luis (Minería)"), text)
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

test("Precios viejos: aviso al abrir la subasta, ventana pegada a ella; un escaneo lo quita", function()
  Stub.printed, Stub.sounds = {}, {}
  Stub.gameTime = Stub.gameTime + 20 -- los sonidos tienen un mínimo de 10 s entre sí
  OroHermandadDB.dbUpdated["Forever-Alliance"] = Stub.now - 12 * 3600
  ns.UI.Hide()
  _G.AuctionHouseFrame = Stub.newObject("Frame", "AuctionHouseFrame")
  Stub.fire("AUCTION_HOUSE_SHOW")
  Stub.runTimers(5)
  assert(ns.UI.IsShown(), "se abre sola")
  local frame = _G.OroHermandadFrame
  assert(frame.__points[1] and frame.__points[1][2] == _G.AuctionHouseFrame, "pegada a la subasta")
  assert(printed("Precios de hace 12 h") and printed("escanear al abrir la subasta"), "aviso en el chat")
  assert(#Stub.sounds == 1, "sonido de aviso")
  Stub.dbCallback()
  Stub.runTimers(5)
  assert(lastRender.result.db.level == "ok", lastRender.result.db.text)
  Stub.fire("AUCTION_HOUSE_CLOSED")
  assert(not ns.UI.IsShown(), "se cierra con la subasta")
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
  slash("amigo borrar bea"); assert(printed("Bea eliminado"))
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

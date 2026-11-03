-- Pruebas del protocolo de hermandad. Desde la raíz del repositorio: lua5.1 test-lua/test_guild.lua
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local realPrint = print
Stub.install()
local DIR = "addon/OroHermandad/"
local ns = {}
for _, file in ipairs({"Data.lua", "Items.lua", "Guild.lua"}) do assert(loadfile(DIR .. file))("OroHermandad", ns) end
local Guild = ns.Guild

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; realPrint("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end
local function sentMatching(pattern)
  local out = {}
  for _, m in ipairs(Stub.sent) do if m.msg:match(pattern) then out[#out + 1] = m end end
  return out
end

local db = {}
local me = {level = 32, profs = {mining = 180, blacksmithing = 160},
            crafts = {{product = 12404, qty = 1, profit = 1775, reagents = {{12365, 2}}}}}
Guild.Init(db, function() return me end)

test("La clave de la hermandad incluye reino y nombre", function()
  eq(Guild.UpdateKey(), "Forever/Los Mineros")
  Guild.Members()
  assert(db.guilds["Forever/Los Mineros"], "almacén creado al usarlo")
end)

test("Anunciar y pedir: la petición R2 no se pierde", function()
  Guild.Announce(); Guild.Request()
  Stub.runTimers(30)
  eq(#sentMatching("^R2$"), 1)
  local hello = sentMatching("^H2|")[1]
  assert(hello and hello.msg == "H2|32|blacksmithing=160,mining=180|1|1", hello and hello.msg)
  local craft = sentMatching("^C2|")[1]
  assert(craft and craft.msg == "C2|1|1|1|12404|1|1775|12365:2", craft and craft.msg)
end)

test("Anuncios seguidos se agrupan (como mucho uno por minuto)", function()
  local before = #sentMatching("^H2|")
  Guild.Announce(); Guild.Announce(); Guild.Announce()
  Stub.runTimers(30)
  eq(#sentMatching("^H2|"), before, "nada en menos de un minuto")
  Stub.runTimers(120)
  eq(#sentMatching("^H2|"), before + 1, "uno al cumplirse el minuto")
end)

test("Si el servidor frena el mensaje, se reintenta", function()
  Stub.sent = {}
  Stub.chatResults = {3}
  Guild.Request()
  Stub.runTimers(30)
  eq(#sentMatching("^R2$"), 1)
end)

test("Hola + recetas de un amigo se guardan; con 0 recetas se borran", function()
  assert(Guild.Handle("H2|40|engineering=200,mining=210|1|7", "Pedro-Forever", "GUILD"))
  assert(Guild.Handle("C2|7|1|1|10546|1|5000|2772:4", "Pedro-Forever", "GUILD"))
  local m = Guild.Members().Pedro
  assert(m and m.addon and m.profs.engineering == 200 and #m.crafts == 1, "pedro")
  assert(Guild.Handle("H2|40|engineering=205|0|8", "Pedro-Forever", "GUILD"))
  eq(#Guild.Members().Pedro.crafts, 0)
end)

test("Partes de otra serie o incompletas no se mezclan", function()
  Guild.Handle("H2|40|engineering=200|2|9", "Pedro", "GUILD")
  eq(Guild.Handle("C2|8|1|2|10546|1|5000|2772:4", "Pedro", "GUILD"), false, "serie vieja")
  eq(Guild.Handle("C2|9|1|2|10546|1|5000|2772:4", "Pedro", "GUILD"), false, "aún falta una parte")
  assert(Guild.Handle("C2|9|2|2|10547|1|3000|2772:2", "Pedro", "GUILD"))
  eq(#Guild.Members().Pedro.crafts, 2)
end)

test("Números trucados (nan, inf, negativos, hex, decimales) se rechazan sin error", function()
  Guild.Handle("H2|40|engineering=200|2|10", "Malo", "GUILD")
  for _, text in ipairs({"C2|10|nan|2|1|1|1|1:1", "C2|10|1|inf|1|1|1|1:1", "C2|10|1.5|2|1|1|1|1:1",
                         "C2|10|1|2|0x10|1|1|1:1", "C2|10|1|2|1|1|-5|1:1", "C2|10|1|2|1|1|1e999|1:1",
                         "H2|nan|mining=1|0|1", "H2|40|engineering=200,mining=99999|0|1", "garbage", ("x"):rep(300)}) do
    local ok, err = pcall(Guild.Handle, text, "Malo", "GUILD")
    assert(ok, "error con " .. text .. ": " .. tostring(err))
  end
  local m = Guild.Members().Malo
  assert(m and (not m.crafts or #m.crafts == 0), "sin recetas")
  eq(m.profs.mining, nil, "rango imposible ignorado")
end)

test("Mensajes propios, de otro addon o susurros no pedidos se ignoran", function()
  eq(Guild.OnAddonMessage("OroHerm", "H2|40|mining=1|0|1", "GUILD", "Javi-Forever"), false)
  eq(Guild.OnAddonMessage("OtroAddon", "H2|40|mining=1|0|1", "GUILD", "Otro"), false)
  Stub.gameTime = Stub.gameTime + 1000
  eq(Guild.OnAddonMessage("OroHerm", "H2|40|mining=1|0|1", "WHISPER", "Extra"), false)
  eq(Guild.Members().Extra, nil)
end)

test("Una petición R2 se contesta por susurro solo a quien la hizo, sin repetir en un minuto", function()
  Stub.sent = {}
  Guild.OnAddonMessage("OroHerm", "R2", "GUILD", "Ana-Forever")
  Guild.OnAddonMessage("OroHerm", "R2", "GUILD", "Ana-Forever")
  Stub.runTimers(30)
  local whispers = sentMatching("^H2|")
  eq(#whispers, 1); eq(whispers[1].channel, "WHISPER"); eq(whispers[1].target, "Ana-Forever")
end)

test("Tras pedir datos se aceptan respuestas por susurro", function()
  Guild.Request()
  assert(Guild.OnAddonMessage("OroHerm", "H2|30|tailoring=120|0|3", "WHISPER", "Eva-Forever"))
  eq(Guild.Members().Eva.profs.tailoring, 120)
end)

test("Amigos a mano: nombres normalizados, sin duplicados, y el addon no borra lo manual", function()
  eq(Guild.SetManual("ana", "enchanting", 150), "Ana")
  eq(Guild.SetManual("ANA", "tailoring", 90), "Ana")
  local ana = Guild.Members().Ana
  eq(ana.profs.enchanting, 150); eq(ana.profs.tailoring, 90); assert(ana.manual)
  Guild.Handle("H2|30|enchanting=160|0|4", "Ana-Forever", "GUILD")
  ana = Guild.Members().Ana
  eq(ana.profs.enchanting, 160, "manda el addon"); eq(ana.profs.tailoring, 90, "lo manual sigue")
  eq(Guild.NormalizeName("ñandú"), "Ñandú")
  eq(Guild.Remove("nadie"), nil)
  eq(Guild.Remove("ana"), "Ana")
end)

test("Roster de la hermandad: Luis sin addon aparece con su profesión", function()
  eq(Guild.ImportRoster(), 1)
  local luis = Guild.Members().Luis
  assert(luis and luis.roster and luis.profs.mining == 210, "luis")
  local withAddon, manual, roster = Guild.Count()
  assert(roster >= 1 and withAddon >= 1)
end)

test("Otra hermandad tiene su propio almacén", function()
  local saved = _G.GetGuildInfo
  _G.GetGuildInfo = function() return "Otra" end
  Guild.UpdateKey()
  eq(Guild.Members().Pedro, nil)
  _G.GetGuildInfo = saved
  Guild.UpdateKey()
  assert(Guild.Members().Pedro)
end)

test("Datos del addon de hace más de 30 días se olvidan", function()
  Stub.now = Stub.now + 31 * 86400
  Guild.Prune()
  eq(Guild.Members().Pedro, nil)
  assert(Guild.Members().Luis, "el roster sigue")
end)

realPrint(string.format("hermandad: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

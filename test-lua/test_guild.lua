-- Pruebas del protocolo de hermandad. Desde la raíz del repositorio: lua5.1 test-lua/test_guild.lua
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local realPrint = print
Stub.install()
local DIR = "addon/OroHermandad/"
local ns = {}
for _, file in ipairs({"Data.lua", "Items.lua", "Guild.lua"}) do assert(loadfile(DIR .. file))("OroHermandad", ns) end
local Guild = ns.Guild

-- Miembros de la hermandad según el cliente (C_GuildInfo.MemberExistsByName); el resto son de fuera.
local GUILDMATES = {Javi = true, Ana = true, Eva = true, Pedro = true, Luis = true, Bea = true}
C_GuildInfo.MemberExistsByName = function(name) return GUILDMATES[(name:match("^([^%-]+)"))] == true end

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
  me.level = 33 -- con los mismos datos no se repetiría
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

---------------------------------------------------------------------------
-- Instancias nuevas de Guild.lua (estado propio) y cambios temporales del cliente simulado
---------------------------------------------------------------------------
local function freshGuild(store, getSelf)
  local inst = {Data = ns.Data, Items = ns.Items}
  assert(loadfile(DIR .. "Guild.lua"))("OroHermandad", inst)
  inst.Guild.Init(store, getSelf or function() return me end)
  return inst.Guild
end
-- Cambia campos de una tabla (o globales) mientras dura fn y los deja como estaban.
local function withFields(target, fields, fn)
  local saved = {}
  for k, v in pairs(fields) do saved[k] = {target[k]}; target[k] = v end
  local ok, err = pcall(fn)
  for k, s in pairs(saved) do target[k] = s[1] end
  if not ok then error(err, 0) end
end
local function with(globals, fn) return withFields(_G, globals, fn) end
local function drain() Stub.runTimers(600); Stub.sent, Stub.chatResults = {}, {} end
local function selfWith(level, profs, crafts) return {level = level, profs = profs, crafts = crafts or {}} end
local function craftList(n)
  local list = {}
  for i = 1, n do list[i] = {product = 12400 + i, qty = 1, profit = 1000 + i, reagents = {{12365, 2}}} end
  return list
end
-- Valor secreto simulado: el cliente lo marca con issecretvalue y no deja operar con él.
local SECRETO = setmetatable({}, {__index = function() error("secreto") end, __lt = function() error("secreto") end,
                                  __le = function() error("secreto") end, __concat = function() error("secreto") end})
local function issecret(v) return v == SECRETO end

---------------------------------------------------------------------------
-- 0.1.0 → 0.2.1: amigos a mano (hallazgo 01) y Guild.Settle
---------------------------------------------------------------------------
test("0.1.0: los amigos a mano pasan a la hermandad actual", function()
  drain()
  local old = {guild = {ana = {manual = true, profs = {engineering = 150}},
                        Bea = {manual = true, profs = {enchanting = "120", inventada = 5, mining = 9999}},
                        Pedro = {addon = true, profs = {mining = 100}}, Nadie = {manual = true, profs = {inventada = 1}}}}
  local G = freshGuild(old)
  eq(old.guild, nil, "db.guild se vacía tras migrar")
  local m = G.Members()
  eq(m.Ana.profs.engineering, 150); assert(m.Ana.manual, "Ana a mano")
  eq(m.Bea.profs.enchanting, 120); eq(m.Bea.profs.mining, 450); eq(m.Bea.profs.inventada, nil)
  eq(m.Pedro, nil, "lo del addon vuelve solo, no se migra")
  eq(old.guilds["Forever/Los Mineros"].members.Nadie, nil, "sin profesiones válidas no se crea")
  local _, manual = G.Count(); eq(manual, 2)
end)

test("0.1.0: si la hermandad aún no ha cargado, db.guild espera intacto en el archivo", function()
  local old = {guild = {Ana = {manual = true, profs = {engineering = 150}}}}
  local G
  with({GetGuildInfo = function() return nil end}, function()
    G = freshGuild(old)
    assert(old.guild and old.guild.Ana, "sigue en el archivo")
    eq(next(G.Members()), nil)
    G.Settle()
    assert(old.guild, "sin nombre de hermandad no se migra")
  end)
  eq(G.UpdateKey(), "Forever/Los Mineros")
  eq(old.guild, nil)
  eq(G.Members().Ana.profs.engineering, 150)
  eq(old.guilds._sinhermandad, nil, "nada en el almacén sin hermandad")
end)

test("0.1.0: IsInGuild() tardío no manda los amigos al almacén sin hermandad", function()
  local old = {guild = {Ana = {manual = true, profs = {engineering = 150}}}}
  local inGuild = false
  with({IsInGuild = function() return inGuild end}, function()
    local G = freshGuild(old)
    assert(old.guild, "sin asentar no se sabe si de verdad no hay hermandad")
    inGuild = true
    eq(G.Members().Ana.profs.engineering, 150, "se ve en cuanto la hermandad es legible")
    eq(old.guild, nil)
    eq(old.guilds["Forever/Los Mineros"].members.Ana.manual.profs.engineering, 150)
    eq(old.guilds._sinhermandad, nil)
  end)
end)

test("0.1.0: sin hermandad se migra al asentarse (Settle), que se puede llamar varias veces", function()
  local old = {guild = {Ana = {manual = true, profs = {engineering = 150}}}}
  with({IsInGuild = function() return false end}, function()
    local G = freshGuild(old)
    assert(old.guild, "aún no")
    eq(G.Settle(), "_sinhermandad"); G.Settle()
    eq(old.guild, nil)
    eq(G.Members().Ana.profs.engineering, 150)
    eq(old.guilds._sinhermandad.members.Ana.manual.profs.engineering, 150)
  end)
end)

---------------------------------------------------------------------------
-- Roster: si cambió algo (02 / contrato C1) y roster ilegible (17)
---------------------------------------------------------------------------
test("Roster: ImportRoster dice si cambió algo (primera vez, rango, nivel, bajas)", function()
  local db2 = {}
  local G = freshGuild(db2)
  local n, changed = G.ImportRoster()
  eq(n, 1); eq(changed, true, "primera importación de esta hermandad")
  n, changed = G.ImportRoster()
  eq(n, 1); eq(changed, false, "nada nuevo")
  local base = C_Club.GetMemberInfo
  local rank, level = 215, 40
  withFields(C_Club, {GetMemberInfo = function(club, id)
    local info = base(club, id)
    if id == 2 then info.profession1Rank, info.level = rank, level end
    return info
  end}, function()
    n, changed = G.ImportRoster(); eq(changed, true, "sube de rango")
    eq(G.Members().Luis.profs.mining, 215)
    level = 41
    n, changed = G.ImportRoster(); eq(changed, true, "sube de nivel")
    n, changed = G.ImportRoster(); eq(changed, false)
  end)
  withFields(C_Club, {GetClubMembers = function() return {1} end}, function()
    n, changed = G.ImportRoster()
    eq(n, 0); eq(changed, true, "Luis se fue"); eq(G.Members().Luis, nil)
    n, changed = G.ImportRoster(); eq(changed, false)
  end)
end)

test("Roster en secreto o ilegible (mazmorra, banda, encuentro): no se borra nada ni da error", function()
  local G = freshGuild({})
  G.ImportRoster()
  local function luisIntact(label)
    local luis = G.Members().Luis
    assert(luis and luis.roster and luis.profs.mining == 210 and luis.level == 40, label)
  end
  local function imports(label)
    local ok, n, changed = pcall(G.ImportRoster)
    assert(ok, label .. ": " .. tostring(n))
    eq(n, 0, label); eq(changed, false, label)
    luisIntact(label)
  end
  withFields(C_ChatInfo, {InChatMessagingLockdown = function() return true end}, function() imports("chat bloqueado") end)
  with({issecretvalue = issecret}, function()
    withFields(C_Club, {GetMemberInfo = function(club, id)
      if id == 1 then return {name = "Javi", isSelf = true} end
      return {name = SECRETO, level = SECRETO, profession1ID = SECRETO, profession1Rank = SECRETO, profession1Name = SECRETO}
    end}, function() imports("campos secretos") end)
    withFields(C_Club, {GetMemberInfo = function(club, id)
      local info = {name = "Luis-Forever", level = 40, profession1ID = 186, profession1Rank = SECRETO}
      return id == 1 and {name = "Javi", isSelf = true} or info
    end}, function() imports("solo el rango es secreto") end)
    withFields(C_Club, {GetClubMembers = function() return {SECRETO, SECRETO} end,
                        GetMemberInfo = function(club, id) if issecret(id) then error("argumento secreto") end end},
      function() imports("identificadores secretos") end)
    withFields(C_Club, {GetGuildClubId = function() return SECRETO end}, function() imports("club secreto") end)
  end)
  withFields(C_Club, {GetMemberInfo = function() error("bloqueado") end}, function() imports("lecturas que fallan") end)
  withFields(C_Club, {GetClubMembers = function() return {} end}, function() imports("lista vacía") end)
  withFields(C_Club, {GetMemberInfo = function(club, id) if id == 1 then return {name = "Javi", isSelf = true} end end},
    function() imports("roster a medio cargar") end)
end)

---------------------------------------------------------------------------
-- Clave de hermandad desconocida y almacén sin hermandad (18)
---------------------------------------------------------------------------
test("Mientras no se sabe la hermandad no se guarda nada suyo (ni en el almacén sin hermandad)", function()
  local db2 = {}
  with({GetGuildInfo = function() return nil end}, function()
    local G = freshGuild(db2)
    eq(G.UpdateKey(), nil)
    eq(G.Handle("H2|40|engineering=200|1|1", "Pedro-Forever", "GUILD"), false)
    eq(G.Handle("C2|1|1|1|10546|1|5000|2772:4", "Pedro-Forever", "GUILD"), false)
    eq(G.ImportRoster(), 0)
    eq(next(G.Members()), nil)
    eq(G.SetManual("Ana", "mining", 10), nil, "a mano tampoco, hasta saber dónde")
    eq(db2.guilds._sinhermandad, nil)
  end)
end)

test("Datos de la hermandad en el almacén sin hermandad (0.2.0) se borran; lo manual se queda", function()
  local db2 = {guilds = {_sinhermandad = {members = {
    Pedro = {addon = {profs = {mining = 1}, level = 10, seen = Stub.now, crafts = {}}},
    Luis = {roster = {profs = {mining = 210}, seen = Stub.now}},
    Ana = {manual = {profs = {tailoring = 50}}, roster = {profs = {mining = 5}, seen = Stub.now}}}}}}
  with({IsInGuild = function() return false end}, function()
    local G = freshGuild(db2)
    local m = G.Members()
    eq(m.Pedro, nil); eq(m.Luis, nil)
    eq(m.Ana.profs.tailoring, 50); eq(m.Ana.profs.mining, nil)
    eq(G.Handle("H2|40|engineering=200|0|1", "Pedro-Forever", "GUILD"), false, "sin hermandad no se guarda")
    eq(G.Members().Pedro, nil)
  end)
end)

---------------------------------------------------------------------------
-- Recetas de más de 100 unidades (19)
---------------------------------------------------------------------------
test("Recetas de 200 unidades (munición) se aceptan y una parte ilegible no tumba la serie", function()
  local G = freshGuild({})
  assert(G.Handle("H2|40|engineering=230|3|20", "Pedro-Forever", "GUILD"))
  eq(G.Handle("C2|20|1|3|15997|200|900|12359:2", "Pedro-Forever", "GUILD"), false, "faltan partes")
  eq(G.Handle("C2|20|2|3|1|1|1|basura", "Pedro-Forever", "GUILD"), false, "faltan partes")
  assert(G.Handle("C2|20|3|3|10546|1|5000|2772:4", "Pedro-Forever", "GUILD"), "serie completa")
  local crafts = G.Members().Pedro.crafts
  eq(#crafts, 2); eq(crafts[1].product, 15997); eq(crafts[1].qty, 200); eq(crafts[2].product, 10546)
end)

test("Al enviar se omiten recetas que la 0.2.0 rechazaría (más de 100 unidades)", function()
  drain()
  local crafts = {{product = 15997, qty = 200, profit = 900, reagents = {{12359, 2}}},
                  {product = 12404, qty = 1, profit = 1775, reagents = {{12365, 2}}},
                  {product = 12405, qty = 1, profit = 0.4, reagents = {{12365, 2}}},
                  {product = 12406, qty = 1, profit = 800, reagents = {}}}
  for i = 1, 8 do crafts[#crafts + 1] = {product = 13000 + i, qty = 5, profit = 700, reagents = {{2772, 1}}} end
  local G = freshGuild({}, function() return selfWith(34, {engineering = 230}, crafts) end)
  G.Announce()
  Stub.runTimers(60)
  local hello = sentMatching("^H2|34|")
  eq(#hello, 1); eq(hello[1].msg, "H2|34|engineering=230|8|1")
  local parts = sentMatching("^C2|")
  eq(#parts, 8, "1 válida + 7 de relleno hasta 8")
  assert(parts[1].msg:match("^C2|1|1|8|12404|"), parts[1].msg)
  for _, m in ipairs(parts) do assert(not m.msg:match("|15997|"), "la munición no se envía") end
  -- Un receptor 0.2.0 (tope 100) completaría la serie: todas las partes pasan el tope antiguo.
  for _, m in ipairs(parts) do assert(tonumber(m.msg:match("^C2|%d+|%d+|%d+|%d+|(%d+)|")) <= 100) end
end)

---------------------------------------------------------------------------
-- Chat bloqueado (20)
---------------------------------------------------------------------------
test("Con el chat bloqueado se espera sin gastar intentos y luego sale todo", function()
  drain()
  local locked = true
  withFields(C_ChatInfo, {InChatMessagingLockdown = function() return locked end}, function()
    local G = freshGuild({}, function() return selfWith(20, {mining = 100}, craftList(2)) end)
    G.Announce(); G.Request()
    Stub.runTimers(600) -- diez minutos en una mazmorra
    eq(#Stub.sent, 0, "nada sale con el chat bloqueado")
    locked = false
    Stub.runTimers(60)
    eq(#sentMatching("^H2|20|mining=100|2|"), 1, "el anuncio sale al terminar")
    eq(#sentMatching("^C2|"), 2)
    eq(#sentMatching("^R2$"), 1, "y la petición también")
  end)
  drain()
end)

test("Si el servidor contesta «bloqueado» (11) tampoco se gastan intentos", function()
  drain()
  Stub.chatResults = {11, 11, 11, 11, 11, 11, 11, 11}
  local G = freshGuild({}, function() return selfWith(21, {mining = 100}) end)
  G.Announce()
  Stub.runTimers(120)
  eq(#sentMatching("^H2|21|"), 1)
  drain()
end)

test("Si el servidor frena seis veces el anuncio, se quita entero y se repite más tarde", function()
  drain()
  Stub.chatResults = {3, 3, 3, 3, 3, 3}
  local G = freshGuild({}, function() return selfWith(22, {mining = 100}, craftList(1)) end)
  G.Announce()
  Stub.runTimers(40)
  eq(#Stub.sent, 0, "sin el H2 las recetas no sirven de nada")
  Stub.runTimers(60)
  eq(#sentMatching("^H2|22|"), 1, "se repite al cumplirse el minuto")
  eq(#sentMatching("^C2|"), 1)
  drain()
end)

test("Respuestas por susurro retenidas demasiado tiempo se cambian por un anuncio a la hermandad", function()
  drain()
  local locked = true
  withFields(C_ChatInfo, {InChatMessagingLockdown = function() return locked end}, function()
    local G = freshGuild({}, function() return selfWith(23, {mining = 100}) end)
    G.OnAddonMessage("OroHerm", "R2", "GUILD", "Eva-Forever")
    Stub.runTimers(300)
    locked = false
    Stub.runTimers(60)
    eq(#sentMatching("^H2|23|"), 1)
    eq(sentMatching("^H2|23|")[1].channel, "GUILD", "quien pidió ya no aceptaría el susurro")
  end)
  drain()
end)

---------------------------------------------------------------------------
-- Ventana de respuestas y oleadas de peticiones (16)
---------------------------------------------------------------------------
test("La ventana de respuestas cuenta desde que sale la petición, no desde que entra en cola", function()
  drain()
  Stub.chatResults = {3, 3, 3, 3, 3}
  local G = freshGuild({})
  G.Request()
  Stub.runTimers(30)
  eq(#sentMatching("^R2$"), 1, "sale al quinto reintento")
  Stub.gameTime = Stub.gameTime + 110 -- 135 s tras pedir, 110 s tras salir
  assert(G.OnAddonMessage("OroHerm", "H2|30|tailoring=120|1|4", "WHISPER", "Eva-Forever"), "aún en plazo")
  Stub.gameTime = Stub.gameTime + 200
  assert(G.OnAddonMessage("OroHerm", "C2|4|1|1|10546|1|5000|2772:4", "WHISPER", "Eva-Forever"), "la serie empezada se completa")
  eq(#G.Members().Eva.crafts, 1)
  eq(G.OnAddonMessage("OroHerm", "H2|30|tailoring=125|0|5", "WHISPER", "Eva-Forever"), false, "un anuncio nuevo, fuera de plazo")
  drain()
end)

test("Una oleada de peticiones se responde con un anuncio a la hermandad, no con decenas de susurros", function()
  drain()
  local G = freshGuild({}, function() return selfWith(24, {mining = 100}, craftList(8)) end)
  for i = 1, 12 do G.OnAddonMessage("OroHerm", "R2", "GUILD", "Pj" .. string.char(64 + i) .. "-Forever") end
  Stub.runTimers(120)
  local whispers = 0
  for _, m in ipairs(Stub.sent) do if m.channel == "WHISPER" then whispers = whispers + 1 end end
  eq(whispers, 18, "dos respuestas por susurro como mucho")
  eq(#sentMatching("^H2|24|"), 3, "dos susurros y un anuncio a la hermandad")
  local guild = 0
  for _, m in ipairs(Stub.sent) do if m.channel == "GUILD" then guild = guild + 1 end end
  eq(guild, 9, "el anuncio a la hermandad llega a todos")
  drain()
end)

---------------------------------------------------------------------------
-- Susurros solo de la hermandad (21)
---------------------------------------------------------------------------
test("Susurros de alguien de fuera de la hermandad se ignoran aunque estemos esperando respuestas", function()
  drain()
  local G = freshGuild({})
  G.ImportRoster()
  G.Request()
  eq(G.OnAddonMessage("OroHerm", "H2|60|mining=300|1|1", "WHISPER", "Intruso-OtroReino"), false)
  eq(G.OnAddonMessage("OroHerm", "C2|1|1|1|12404|1|999999|2772:1", "WHISPER", "Intruso-OtroReino"), false)
  eq(G.Members().Intruso, nil)
  assert(G.OnAddonMessage("OroHerm", "H2|30|tailoring=120|0|3", "WHISPER", "Eva-Forever"), "Eva es de la hermandad")
  -- Sin la consulta del cliente (o con el roster sin cargar) vale quien ya vimos en el roster.
  withFields(C_GuildInfo, {MemberExistsByName = function() error("no disponible") end}, function()
    assert(G.OnAddonMessage("OroHerm", "H2|40|mining=211|0|2", "WHISPER", "Luis-Forever"), "Luis sale en el roster")
    eq(G.OnAddonMessage("OroHerm", "H2|40|mining=1|0|2", "WHISPER", "Otro-Forever"), false)
  end)
  drain()
end)

test("Sin hermandad no se pide nada ni se aceptan susurros", function()
  drain()
  with({IsInGuild = function() return false end}, function()
    local G = freshGuild({})
    G.Settle()
    G.Request()
    Stub.runTimers(10)
    eq(#sentMatching("^R2$"), 0)
    eq(G.OnAddonMessage("OroHerm", "H2|30|tailoring=120|0|3", "WHISPER", "Eva-Forever"), false)
    eq(next(G.Members()), nil)
  end)
  drain()
end)

---------------------------------------------------------------------------
-- Nombres (22)
---------------------------------------------------------------------------
test("Nombres: sin tu reino y con mayúsculas y minúsculas en todas las letras (UTF-8)", function()
  eq(Guild.NormalizeName("Ana-Forever"), "Ana")
  eq(Guild.NormalizeName("ana-forever"), "Ana")
  eq(Guild.NormalizeName("Ana-"), "Ana")
  eq(Guild.NormalizeName("bob-Otro-Reino"), "Bob-OtroReino")
  eq(Guild.NormalizeName("çaro"), "Çaro")
  eq(Guild.NormalizeName("ZÖE"), "Zöe")
  eq(Guild.NormalizeName("ÉLODIE"), "Élodie")
  eq(Guild.NormalizeName("æsa"), "Æsa")
  eq(Guild.NormalizeName("łukasz"), "Łukasz")
  eq(Guild.NormalizeName("ÿves"), "Ÿves")
  eq(Guild.NormalizeName("œDIPE"), "Œdipe")
  eq(Guild.NormalizeName("АНЯ"), "Аня")
  eq(Guild.NormalizeName("ёлка"), "Ёлка")
  eq(Guild.NormalizeName("ñandú"), "Ñandú")
  eq(Guild.NormalizeName("  ÁLVARO  "), "Álvaro")
end)

test("Un amigo a mano con tu reino o en minúsculas se une a los datos del addon", function()
  -- Como el cliente real: Ambiguate(nombre, "none") solo quita tu propio reino.
  with({Ambiguate = function(name)
    local base, realm = name:match("^([^%-]+)%-(.+)$")
    if realm == GetNormalizedRealmName() then return base end
    return name
  end}, function()
    local G = freshGuild({})
    G.Handle("H2|30|enchanting=160|0|1", "Ana-Forever", "GUILD")
    G.Handle("H2|30|mining=100|0|1", "Çaro-Forever", "GUILD")
    G.Handle("H2|30|mining=50|0|1", "Bob-OtroReino", "GUILD")
    eq(G.SetManual("Ana-Forever", "tailoring", 90), "Ana")
    eq(G.SetManual("çaro", "tailoring", 50), "Çaro")
    eq(G.SetManual("bob-otroreino", "skinning", 40), "Bob-OtroReino")
    local m = G.Members()
    eq(m["Ana-Forever"], nil); eq(m.Ana.profs.tailoring, 90); eq(m.Ana.profs.enchanting, 160)
    eq(m["çaro"], nil); eq(m["Çaro"].profs.tailoring, 50); eq(m["Çaro"].profs.mining, 100)
    eq(m["Bob-OtroReino"].profs.skinning, 40); eq(m["Bob-OtroReino"].profs.mining, 50)
    eq(G.Remove("ANA-forever"), "Ana"); eq(G.Members().Ana, nil)
  end)
  -- Una clave antigua mal escrita (0.2.0) toma la grafía del servidor al llegar sus datos.
  local db3 = {guilds = {["Forever/Los Mineros"] = {members = {["ZÖe"] = {manual = {profs = {tailoring = 10}}}}}}}
  local G = freshGuild(db3)
  assert(G.Handle("H2|30|mining=100|0|1", "Zöe-Forever", "GUILD"))
  local m = G.Members()
  eq(m["ZÖe"], nil); eq(m["Zöe"].profs.tailoring, 10); eq(m["Zöe"].profs.mining, 100)
end)

test("0.2.0: amigos a mano guardados con tu reino («Ana-Forever») se unen a Ana; borrar quita lo que se nombra", function()
  local db = {guilds = {
    ["Forever/Los Mineros"] = {members = {
      ["Ana-Forever"] = {manual = {profs = {engineering = 150, tailoring = 50}}},
      Ana = {addon = {profs = {mining = 200}, level = 40, seen = time()}, manual = {profs = {tailoring = 75}}},
      ["bea-forever"] = {manual = {profs = {enchanting = 120}}},
      ["Eva-OtroReino"] = {manual = {profs = {alchemy = 100}}},
      ["Vacio-Forever"] = {manual = {profs = {}}},
    }},
    -- Otra hermandad de otro reino: ahí «Ana-Forever» es alguien de fuera y no se toca.
    ["OtroReino/Gremio"] = {members = {["Ana-Forever"] = {manual = {profs = {mining = 10}}}}},
  }}
  local G = freshGuild(db)
  local m = G.Members()
  eq(m["Ana-Forever"], nil, "sin duplicado")
  eq(m.Ana.profs.mining, 200); eq(m.Ana.profs.engineering, 150, "lo manual se junta"); eq(m.Ana.profs.tailoring, 75, "sin pisar")
  assert(m.Ana.addon and m.Ana.manual, "Ana conserva los datos del addon")
  eq(m["bea-forever"], nil); eq(m.Bea.profs.enchanting, 120)
  eq(m["Eva-OtroReino"].profs.alchemy, 100, "otro reino: se queda")
  local stored = db.guilds["Forever/Los Mineros"].members
  eq(stored["Vacio-Forever"], nil); eq(stored.Vacio, nil, "sin profesiones no se crea nada")
  eq(db.guilds["OtroReino/Gremio"].members["Ana-Forever"].manual.profs.mining, 10)
  local withAddon, manual = G.Count(); eq(withAddon, 1); eq(manual, 2)
  eq(G.SetManual("Bea-Forever", "tailoring", 60), "Bea", "no crea otra Bea")
  eq(G.Remove("Bea-Forever"), "Bea"); eq(G.Members().Bea, nil)
  -- Donde no se renombra (almacén sin hermandad, que no es de ningún reino), la clave antigua se puede quitar tal cual
  -- sin llevarse a la Ana de verdad.
  local loose = {guilds = {_sinhermandad = {members = {["Ana-Forever"] = {manual = {profs = {engineering = 150}}},
                                                       Ana = {manual = {profs = {mining = 100}}}}}}}
  with({IsInGuild = function() return false end}, function()
    local L = freshGuild(loose)
    L.Settle()
    eq(L.Remove("Ana-Forever"), "Ana-Forever")
    eq(L.Members().Ana.profs.mining, 100, "la otra Ana se queda")
    eq(L.Remove("Ana-Forever"), "Ana", "después, normalizado")
    eq(next(L.Members()), nil)
  end)
end)

---------------------------------------------------------------------------
-- Anuncios repetidos (23)
---------------------------------------------------------------------------
test("Anunciar los mismos datos no se repite; con cambios, forzado o pasada media hora, sí", function()
  drain()
  local self = selfWith(25, {mining = 100}, craftList(1))
  local G = freshGuild({}, function() return self end)
  local function hellos() return #sentMatching("^H2|") end
  G.Announce(); Stub.runTimers(10); eq(hellos(), 1)
  Stub.gameTime = Stub.gameTime + 120
  G.Announce(); Stub.runTimers(10); eq(hellos(), 1, "igual que antes: no se repite (abrir la ventana de profesión)")
  G.Announce(true); Stub.runTimers(10); eq(hellos(), 2, "forzado (/oro sync)")
  self.profs = {mining = 101}
  G.Announce(); Stub.runTimers(10); eq(hellos(), 2, "dentro del minuto se espera")
  Stub.runTimers(70); eq(hellos(), 3, "el cambio sale al cumplirse el minuto")
  eq(#sentMatching("^H2|25|mining=101|"), 1)
  Stub.gameTime = Stub.gameTime + 1900
  G.Announce(); Stub.runTimers(10); eq(hellos(), 4, "pasada media hora se repite")
  drain()
end)

test("Recibir otra vez el mismo anuncio no cuenta como cambio", function()
  local G = freshGuild({})
  local changed, isNew = G.Handle("H2|40|engineering=200|1|1", "Pedro-Forever", "GUILD")
  assert(changed and isNew)
  assert(G.Handle("C2|1|1|1|10546|1|5000|2772:4", "Pedro-Forever", "GUILD"))
  eq(G.Handle("H2|40|engineering=200|1|2", "Pedro-Forever", "GUILD"), false)
  eq(G.Handle("C2|2|1|1|10546|1|5000|2772:4", "Pedro-Forever", "GUILD"), false)
  eq(#G.Members().Pedro.crafts, 1)
  assert(G.Handle("H2|41|engineering=200|1|3", "Pedro-Forever", "GUILD"), "sube de nivel")
  assert(G.Handle("C2|3|1|1|10546|1|6000|2772:4", "Pedro-Forever", "GUILD"), "receta con otro beneficio")
  assert(G.Handle("H2|41|engineering=200|0|4", "Pedro-Forever", "GUILD"), "ya no tiene recetas")
end)

---------------------------------------------------------------------------
-- 0.6.0: WoW Forever ya no da el reino (Data.Realm)
---------------------------------------------------------------------------
test("Reino vacío: el almacén de la hermandad sigue en el del reino de antes y lo guardado en «/Hermandad» pasa a él", function()
  local OLD = "CAMWOWEU4Realm4PvP"
  local store = {guilds = {
    [OLD .. "/Los Mineros"] = {members = {Ana = {manual = {profs = {engineering = 150}}},
                                          ["Bea-" .. OLD] = {manual = {profs = {tailoring = 60}}}}},
    -- Lo que se guardó mientras el juego daba el reino vacío y el addon no lo resolvía.
    ["/Los Mineros"] = {members = {Eva = {manual = {profs = {alchemy = 90}}},
                                   ana = {manual = {profs = {mining = 5, engineering = 120}}}}},
  }}
  Stub.setRealm("")
  with({OroHermandadHist = {schema = 2, markets = {[OLD .. "-Alliance"] = {items = {}, dep = {}, updated = time()}}}}, function()
    local G = freshGuild(store)
    eq(G.UpdateKey(), OLD .. "/Los Mineros", "la clave de antes")
    local m = G.Members()
    eq(m.Ana.profs.engineering, 150, "lo de antes, en su sitio (la de más nivel)")
    eq(m.Ana.profs.mining, 5, "lo de Ana en «/Los Mineros» se junta con lo suyo")
    eq(m.ana, nil, "con el nombre de antes")
    eq(m.Eva.profs.alchemy, 90, "lo guardado sin reino se une")
    eq(store.guilds["/Los Mineros"], nil, "y ya no queda aparte")
    eq(m.Bea.profs.tailoring, 60, "los nombres de la 0.2.0 con tu reino de antes se unen")
    eq(G.NormalizeName("Ana-" .. OLD), "Ana", "tu reino de antes se quita del nombre")
  end)
  -- Sin reino ni datos: «Forever» (fijo). Lo de «/Hermandad» también pasa; los nombres de la 0.2.0 no se tocan (no es
  -- seguro que «Forever» sea tu reino de antes).
  local loose = {guilds = {["/Los Mineros"] = {members = {Eva = {manual = {profs = {alchemy = 90}}}}},
                           ["Forever/Los Mineros"] = {members = {["Ana-Forever"] = {manual = {profs = {engineering = 150}}}}}}}
  local G = freshGuild(loose)
  eq(G.UpdateKey(), "Forever/Los Mineros")
  G.Members()
  assert(loose.guilds["Forever/Los Mineros"].members["Ana-Forever"], "con el reino de reserva no se renombra")
  assert(loose.guilds["Forever/Los Mineros"].members.Eva, "lo de «/Los Mineros» pasa")
  eq(loose.guilds["/Los Mineros"], nil)
  Stub.setRealm("Forever")
end)

test("El reino cambia a media sesión (/oro reino, o el juego lo da tarde): lo de la hermandad pasa al reino nuevo", function()
  local store = {guilds = {}}
  local G = freshGuild(store)
  Stub.setRealm("")
  local ok, err = pcall(function()
    eq(G.UpdateKey(), "Forever/Los Mineros")
    assert(G.SetManual("Ana", "engineering", 150))
    assert(G.Handle("H2|40|mining=210|0|1", "Luis", "GUILD"))
    Stub.setRealm("Nuevo")
    eq(G.UpdateKey(), "Nuevo/Los Mineros")
    local m = G.Members()
    eq(m.Ana and m.Ana.profs.engineering, 150, "el amigo a mano sigue")
    eq(m.Luis and m.Luis.profs.mining, 210, "y lo que anunció un compañero")
    eq(store.guilds["Forever/Los Mineros"], nil, "sin dejar el de antes aparte")
    -- Otra vez, a un reino donde ya había alguien: lo de los dos se junta.
    store.guilds["Otro/Los Mineros"] = {members = {Ana = {manual = {profs = {tailoring = 60}}}}}
    Stub.setRealm("Otro")
    eq(G.UpdateKey(), "Otro/Los Mineros")
    m = G.Members()
    eq(m.Ana.profs.tailoring, 60, "lo que ya había"); eq(m.Ana.profs.engineering, 150, "y lo que llega")
    eq(m.Luis.profs.mining, 210)
    eq(store.guilds["Nuevo/Los Mineros"], nil)
    -- Otra hermandad no se toca.
    store.guilds["Otro/Los Otros"] = {members = {Eva = {manual = {profs = {alchemy = 90}}}}}
    G.UpdateKey()
    assert(store.guilds["Otro/Los Otros"].members.Eva)
  end)
  Stub.setRealm("Forever")
  assert(ok, err)
end)

test("Al juntar dos almacenes de la hermandad no se pierde nada: a mano, todo (la de más nivel); addon y roster, lo más reciente", function()
  local OLD = "CAMWOWEU4Realm4PvP"
  local t = time()
  local function addon(level, mining, ago) return {level = level, profs = {mining = mining}, crafts = {}, seen = t - ago} end
  local function roster(level, mining, ago) return {level = level, profs = {mining = mining}, seen = t - ago} end
  local store = {guilds = {
    [OLD .. "/Los Mineros"] = {members = {
      Ana = {manual = {profs = {engineering = 150, alchemy = 200}}},
      Luis = {roster = roster(40, 210, 10 * 86400)},
      Bea = {addon = addon(32, 180, 25 * 86400), manual = {profs = {tailoring = 60}}},
      Pedro = {addon = addon(50, 300, 60), roster = roster(50, 290, 60)},
      Eva = "basura", -- lo de «/Los Mineros» la sustituye
    }},
    -- La 0.5.x con el reino vacío: lo más nuevo.
    ["/Los Mineros"] = {members = {
      ana = {manual = {profs = {engineering = 225, alchemy = 90, mining = 30}}},
      Luis = {manual = {profs = {tailoring = 75}}, roster = roster(41, 225, 3600)},
      Bea = {addon = addon(35, 220, 3600)},
      Pedro = {addon = addon(49, 280, 86400), roster = roster(49, 270, 86400)},
      Eva = {manual = {profs = {alchemy = 90}}},
      Raro = "basura",
    }},
  }}
  Stub.setRealm("")
  with({OroHermandadHist = {schema = 2, markets = {[OLD .. "-Alliance"] = {items = {}, dep = {}, updated = t}}}}, function()
    local G = freshGuild(store)
    eq(G.UpdateKey(), OLD .. "/Los Mineros")
    local m = G.Members()
    eq(m.Ana.profs.engineering, 225, "en los dos: la de más nivel (la nueva)")
    eq(m.Ana.profs.alchemy, 200, "en los dos: la de más nivel (la de antes)")
    eq(m.Ana.profs.mining, 30, "solo en uno: se queda"); assert(m.Ana.manual)
    eq(m.Luis.profs.tailoring, 75, "a mano sin nada a mano en el otro"); eq(m.Luis.profs.mining, 225, "roster más reciente")
    eq(m.Luis.level, 41)
    eq(m.Bea.profs.mining, 220, "addon más reciente"); eq(m.Bea.level, 35); eq(m.Bea.profs.tailoring, 60)
    eq(m.Pedro.profs.mining, 300, "lo de antes era más reciente: se queda"); eq(m.Pedro.level, 50)
    eq(store.guilds[OLD .. "/Los Mineros"].members.Pedro.roster.profs.mining, 290)
    eq(m.Eva.profs.alchemy, 90)
    eq(store.guilds[OLD .. "/Los Mineros"].members.Raro, nil, "lo que no es un amigo no pasa")
    eq(store.guilds["/Los Mineros"], nil, "y el de antes ya no queda aparte")
    -- Seis días después, la poda: lo del addon de Bea es el de hace una hora, no el de hace 25 días.
    withFields(_G, {time = function() return t + 6 * 86400 end}, function()
      G.Prune()
      eq(G.Members().Bea.profs.mining, 220, "sigue")
    end)
  end)
  Stub.setRealm("Forever")
end)

test("«Forever/Hermandad» pasa al reino de verdad solo con el personaje que lo usó con el reino de reserva", function()
  local OLD = "CAMWOWEU4Realm4PvP"
  local hist = {schema = 2, markets = {[OLD .. "-Alliance"] = {items = {}, dep = {}, updated = time()}}}
  local store = {guilds = {}}
  Stub.setRealm("")
  local ok, err = pcall(function()
    local G
    local function login(cdb, globals)
      local fields = {OroHermandadCharDB = cdb}
      for k, v in pairs(globals or {}) do fields[k] = v end
      local key, members
      with(fields, function() G = freshGuild(store); key = G.UpdateKey(); members = G.Members() end)
      return key, members
    end
    -- Un alt sin reino ni datos: «Forever» de reserva. El personaje apunta la hermandad.
    local alt = {}
    eq(login(alt), "Forever/Los Mineros")
    assert(G.SetManual("Pedro", "alchemy", 50))
    eq(alt.fallbackGuild, "Los Mineros", "apuntado en el personaje")
    eq(store.guilds["Forever/Los Mineros"].chosen, nil)
    -- El principal, con un reino de verdad (/oro reino): no se lo lleva, ni al entrar ni la vez siguiente; el alt lo
    -- sigue viendo.
    local main = {realm = OLD, realmFrom = "manual"}
    for round = 1, 2 do
      local key, members = login(main)
      eq(key, OLD .. "/Los Mineros"); eq(members.Pedro, nil, "no es suyo (" .. round .. ")")
      key, members = login(alt)
      eq(key, "Forever/Los Mineros")
      eq(members.Pedro and members.Pedro.profs.alchemy, 50, "el alt lo sigue viendo (" .. round .. ")")
    end
    eq(main.fallbackGuild, nil)
    -- El mismo alt, al entrar con un reino de verdad (tus datos): lo suyo pasa a él, una vez.
    local key, members = login(alt, {OroHermandadHist = hist})
    eq(key, OLD .. "/Los Mineros"); eq(members.Pedro.profs.alchemy, 50)
    eq(store.guilds["Forever/Los Mineros"], nil)
    eq(alt.fallbackGuild, nil, "ya sabe su reino")
    -- «Forever» elegido con /oro reino: queda marcado y ni un personaje que lo usó con el de reserva se lo lleva.
    local bank = {}
    login(bank)
    eq(bank.fallbackGuild, "Los Mineros")
    local chooser = {realm = "Forever", realmFrom = "manual", fallbackGuild = "Los Mineros"}
    eq(login(chooser), "Forever/Los Mineros")
    assert(G.SetManual("Eva", "alchemy", 90))
    eq(store.guilds["Forever/Los Mineros"].chosen, true, "elegido a propósito")
    eq(chooser.fallbackGuild, nil, "quien lo elige no es de reserva")
    key, members = login(bank, {OroHermandadHist = hist})
    eq(key, OLD .. "/Los Mineros"); eq(members.Eva, nil, "no se lo lleva")
    eq(bank.fallbackGuild, nil)
    assert(store.guilds["Forever/Los Mineros"].members.Eva, "sigue en su sitio")
    -- Aunque luego lo use alguien con el de reserva, sigue elegido.
    login({})
    eq(store.guilds["Forever/Los Mineros"].chosen, true)
    -- Uno de antes (nadie lo apuntó): no se sabe de quién es y se queda. Lo apuntado de otra hermandad tampoco cuenta.
    store.guilds["Forever/Los Otros"] = {members = {Bea = {manual = {profs = {tailoring = 60}}}}}
    local other = {fallbackGuild = "Los Mineros"}
    key, members = login(other, {OroHermandadHist = hist, GetGuildInfo = function() return "Los Otros" end})
    eq(key, OLD .. "/Los Otros"); eq(members.Bea, nil)
    assert(store.guilds["Forever/Los Otros"].members.Bea)
    eq(other.fallbackGuild, nil, "ya sabe su reino")
    -- Lo que no es un nombre de hermandad, fuera al cargar.
    local bad = {fallbackGuild = 5}
    login(bad)
    eq(bad.fallbackGuild, "Los Mineros")
    bad.fallbackGuild = ""
    with({OroHermandadCharDB = bad, IsInGuild = function() return false end}, function() freshGuild(store) end)
    eq(bad.fallbackGuild, nil)
    -- El cambio a media sesión sí lo mueve (es el de este personaje): /oro reino borrar desde «Forever» elegido. Con la
    -- clave nueva deja de estar marcado.
    store.guilds["Forever/Los Terceros"] = {members = {Luis = {manual = {profs = {mining = 40}}}}, chosen = true}
    local cdb = {realm = "Forever", realmFrom = "manual"}
    with({OroHermandadCharDB = cdb, OroHermandadHist = hist, GetGuildInfo = function() return "Los Terceros" end}, function()
      G = freshGuild(store)
      eq(G.UpdateKey(), "Forever/Los Terceros")
      cdb.realm, cdb.realmFrom = nil, nil
      eq(G.UpdateKey(), OLD .. "/Los Terceros")
      eq(G.Members().Luis.profs.mining, 40)
      eq(store.guilds["Forever/Los Terceros"], nil)
      eq(store.guilds[OLD .. "/Los Terceros"].chosen, nil, "la marca no sigue al reino de verdad")
    end)
  end)
  Stub.setRealm("Forever")
  assert(ok, err)
end)

realPrint(string.format("hermandad: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

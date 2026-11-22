-- Pruebas del reino (Data.Realm, 0.6.0) en el cliente simulado de Forever. WoW Forever no tiene reinos y, tras un cambio
-- del cliente, GetRealmName, GetNormalizedRealmName y GetPlayerInfoByGUID dan "": el addon usa el último reino conocido,
-- el de tus datos guardados o «Forever», y /oro reino lo cambia. Desde la raíz del repositorio:
--   lua5.1 test-lua/test_realm.lua
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local realPrint = print
Stub.install()

local DIR = "addon/OroHermandad/"
local OLD = "CAMWOWEU4Realm4PvP"  -- el reino que daba el juego antes (el del jugador que lo reportó, con la 0.5.x)
local OLD_KEY = OLD .. "-Alliance"
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; realPrint("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
local function printed(sub) for _, line in ipairs(Stub.printed) do if has(line, sub) then return true end end return false end
local function chat() return table.concat(Stub.printed, "\n") end

-- Sesión nueva con sv = {db, cdb, hist}: lo que el juego cargaría del archivo (nil: nada).
-- Antes de empezar otra, la sesión anterior no puede haber escrito ningún error interno en el chat.
local ns
local function noErrors() for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end end
local function boot(sv)
  sv = sv or {}
  noErrors()
  Stub.frames, Stub.timers, Stub.printed, Stub.sent = {}, {}, {}, {}
  for k, v in pairs(Stub.ahOriginals) do C_AuctionHouse[k] = v end
  Stub.ah.refirePending, Stub.ah.pumping = 0, false
  _G.OroHermandadDB, _G.OroHermandadCharDB, _G.OroHermandadHist = sv.db, sv.cdb, sv.hist
  ns = Stub.loadAddon(DIR)
  Stub.fire("ADDON_LOADED", "OroHermandad")
  return ns
end
local function saved()
  return {db = Stub.deepCopy(OroHermandadDB), cdb = Stub.deepCopy(OroHermandadCharDB), hist = Stub.deepCopy(OroHermandadHist)}
end
local function slash(text) SlashCmdList.OROHERMANDAD(text); Stub.runTimers(10) end
local function realm() return ns.Data.Realm() end
local function source() return select(2, ns.Data.Realm()) end
local function market() return ns.History.CurrentMarket() end
-- La línea «Mercado:» de /oro sondeo.
local function marketLine()
  slash("sondeo")
  local line = _G.OroHermandadTextFrame.edit:GetText():match("\nMercado: [^\n]*")
  return line and line:sub(2)
end

boot()
local Spec = ns.Spec
-- OroHermandadHist de la 0.5.x: markets = {[clave] = hace cuántos segundos se escribió (updated)}, con el hierro de ayer.
local function oldHist(markets)
  local h = {schema = 2, addon = "0.5.1", markets = {}}
  local t = math.floor(Stub.now)
  local day = Spec.EncodeDays({{d = Spec.DayIndex(t) - 1, lo = 100, hi = 110, last = 105, qty = 50, scans = 2, src = "o"}})
  for key, ago in pairs(markets) do
    h.markets[key] = {items = {[2772] = {n = "Hierro", c = "metal", v = 5, d = day, p = ""}}, dep = {}, updated = t - ago}
  end
  return h
end

-- Entrar al mundo (PLAYER_LOGIN y PLAYER_ENTERING_WORLD) y esperar a que todo se asiente.
local function enterWorld()
  Stub.fire("PLAYER_LOGIN")
  Stub.fire("PLAYER_ENTERING_WORLD", true, false)
  Stub.runTimers(30)
end
-- Un escaneo completo con el escáner del addon (hierro, cobre y 50 objetos más), hasta que queda grabado.
local function scanAH()
  local rows = {Stub.row(2772, 20, 100, {band = 3}), Stub.row(2772, 5, 120, {band = 2}), Stub.row(2770, 40, 30, {band = 3})}
  for i = 1, 50 do rows[#rows + 1] = Stub.row(200000 + i, 1, 100 + i, {band = 2}) end
  Stub.ah.rows, Stub.ah.lastSuccess = rows, nil -- otra sesión: el servidor ya no recuerda la petición anterior
  Stub.openAH()
  local ok, why = ns.Scanner.Request(true)
  assert(ok, "no se pudo pedir: " .. tostring(why))
  Stub.runUntil(function()
    local s = ns.Scanner.State().state
    return not (s == "queued" or s == "requested" or s == "reading" or s == "other")
  end, 120)
  Stub.runUntil(function() return ns.History.Pending() == 0 end, 30)
  eq(ns.Scanner.State().state, "done")
  Stub.closeAH()
  Stub.runTimers(60)
end
local function members() return ns.Guild.Members() end
local function manual(profs) return {manual = {profs = profs}} end
-- La primera línea de /oro cuando (dice si aún se están leyendo los escaneos guardados).
local function cuandoHead() local _, text = ns.Timing.View(""); return (text or ""):match("[^\n]*") end
local PENDING = "aún se están leyendo los escaneos guardados"

---------------------------------------------------------------------------
-- 1. De dónde sale el reino
---------------------------------------------------------------------------
test("Reino del juego: se usa y se recuerda para el personaje y para la cuenta (por facción), venga de la función que venga", function()
  Stub.setRealm("MirageRaceway", "Mirage Raceway", "")
  boot()
  eq(realm(), "MirageRaceway"); eq(source(), "juego")
  eq(market(), "MirageRaceway-Alliance")
  eq(OroHermandadCharDB.realm, "MirageRaceway", "del personaje"); eq(OroHermandadCharDB.realmFrom, "juego")
  eq(OroHermandadDB.realms.Alliance, "MirageRaceway", "de la cuenta"); eq(OroHermandadDB.realms.Horde, nil)
  Stub.setRealm("", "Mirage Raceway", "")
  eq(realm(), "MirageRaceway", "solo GetRealmName: sin espacios"); eq(source(), "juego")
  Stub.setRealm("", "", "Mirage-Raceway")
  eq(realm(), "MirageRaceway", "solo GetPlayerInfoByGUID: sin guiones"); eq(source(), "juego")
  -- Lo que no vale como reino no cuenta como dado por el juego.
  for _, bad in ipairs({"A|B", ("x"):rep(65), " - ", "Con\1control"}) do
    Stub.setRealm(bad)
    eq(source(), "guardado", "no vale: " .. bad)
  end
  local secret = "Secreto"
  _G.issecretvalue = function(v) return v == secret end
  Stub.setRealm(secret)
  local secretSource = source()
  _G.issecretvalue = nil
  eq(secretSource, "guardado", "un valor secreto no se lee")
  -- Un personaje de la Horda en la misma cuenta: la cuenta lo recuerda aparte.
  Stub.playerFaction = "Horde"
  Stub.setRealm("Otro")
  eq(realm(), "Otro"); eq(OroHermandadDB.realms.Horde, "Otro"); eq(OroHermandadDB.realms.Alliance, "MirageRaceway")
  Stub.playerFaction = "Alliance"
  Stub.setRealm("Forever")
end)

test("El juego da el reino vacío: el que dio antes a este personaje; en otro personaje, el de la cuenta de su facción", function()
  Stub.setRealm("MirageRaceway")
  boot()
  local sv = saved()
  Stub.setRealm("")
  boot(Stub.deepCopy(sv))
  eq(realm(), "MirageRaceway"); eq(source(), "guardado"); eq(market(), "MirageRaceway-Alliance")
  -- Otro personaje de la cuenta (sin OroHermandadCharDB): el de la cuenta, sin copiarlo al personaje.
  boot({db = Stub.deepCopy(sv.db)})
  eq(realm(), "MirageRaceway"); eq(source(), "cuenta"); eq(OroHermandadCharDB.realm, nil)
  -- De la Horda: la cuenta no tiene reino de la Horda ni hay datos → «Forever».
  Stub.playerFaction = "Horde"
  boot({db = Stub.deepCopy(sv.db)})
  local r, s = realm()
  Stub.playerFaction = "Alliance"
  eq(r, "Forever"); eq(s, "fijo")
  Stub.setRealm("Forever")
end)

test("El caso del jugador: sin reino del juego ni guardado, el de su OroHermandadHist (un mercado), recordado", function()
  Stub.setRealm("")
  boot({hist = oldHist({[OLD_KEY] = 3600, ["Otro-Horde"] = 60})})
  eq(realm(), OLD); eq(source(), "datos"); eq(market(), OLD_KEY)
  eq(OroHermandadCharDB.realm, OLD, "recordado para el personaje"); eq(OroHermandadCharDB.realmFrom, "datos")
  eq(OroHermandadDB.realms, nil, "la cuenta solo recuerda lo que da el juego")
  eq(ns.Guild.UpdateKey(), OLD .. "/Los Mineros", "el almacén de la hermandad, también")
  ns = Stub.reload(DIR)
  eq(realm(), OLD, "tras recargar"); eq(source(), "datos"); eq(market(), OLD_KEY)
  Stub.setRealm("Forever")
end)

test("Varios reinos en tus datos: el del mercado escrito más recientemente, de tu facción y con clave válida", function()
  Stub.setRealm("")
  boot({hist = oldHist({["Viejo-Alliance"] = 3 * 86400, [OLD_KEY] = 3600, ["Nuevo-Horde"] = 10})})
  eq(realm(), OLD); eq(source(), "datos")
  boot({hist = oldHist({["Viejo-Alliance"] = 60, [OLD_KEY] = 3600})})
  eq(realm(), "Viejo", "el más reciente")
  boot({hist = oldHist({["Con espacio-Alliance"] = 1, ["Con-guion-Alliance"] = 1, ["A|B-Alliance"] = 1, [OLD_KEY] = 7200})})
  eq(realm(), OLD, "claves que no vienen del juego no cuentan")
  Stub.setRealm("Forever")
end)

test("Sin nada: «Forever» (fijo), sin recordarlo; el del juego gana en cuanto aparece", function()
  Stub.setRealm("")
  boot()
  eq(realm(), "Forever"); eq(source(), "fijo"); eq(market(), "Forever-Alliance")
  eq(OroHermandadCharDB.realm, nil, "no se recuerda"); eq(OroHermandadDB.realms, nil)
  eq(ns.Guild.UpdateKey(), "Forever/Los Mineros")
  Stub.setRealm("Nuevo")
  eq(realm(), "Nuevo"); eq(source(), "juego")
  Stub.setRealm("")
  eq(realm(), "Nuevo"); eq(source(), "guardado")
  Stub.setRealm("Forever")
end)

test("Al cargar se quita lo guardado que no vale (del personaje y de la cuenta)", function()
  Stub.setRealm("")
  boot({db = {realms = {Alliance = "Bueno", Horde = "Con-Guion", Neutral = "X"}}, cdb = {realm = "A|B", realmFrom = "manual"}})
  eq(OroHermandadCharDB.realm, nil); eq(OroHermandadCharDB.realmFrom, nil)
  eq(OroHermandadDB.realms.Alliance, "Bueno"); eq(OroHermandadDB.realms.Horde, nil); eq(OroHermandadDB.realms.Neutral, nil)
  eq(realm(), "Bueno"); eq(source(), "cuenta")
  boot({db = {realms = "basura"}, cdb = {realm = ("x"):rep(65), realmFrom = "juego"}})
  eq(OroHermandadDB.realms, nil); eq(OroHermandadCharDB.realm, nil); eq(OroHermandadCharDB.realmFrom, nil)
  eq(source(), "fijo")
  boot({db = {realms = {Horde = 7}}, cdb = {realm = "Bueno", realmFrom = "raro"}})
  eq(OroHermandadDB.realms, nil, "sin ninguno válido"); eq(OroHermandadCharDB.realmFrom, nil)
  eq(realm(), "Bueno"); eq(source(), "guardado")
  Stub.setRealm("Forever")
end)

---------------------------------------------------------------------------
-- 2. /oro reino y /oro sondeo
---------------------------------------------------------------------------
test("/oro reino: lo enseña, lo pone a mano, rechaza uno que no vale y lo borra; con el reino del juego, manda el juego", function()
  Stub.setRealm("")
  boot({hist = oldHist({[OLD_KEY] = 3600})})
  slash("reino")
  assert(printed("reino: " .. OLD .. " (el juego no da el reino: el de tus datos guardados). Mercado: " .. OLD_KEY .. "."), chat())
  assert(printed("si usan otro, /oro reino <nombre>"), chat())
  Stub.printed = {}
  slash("reino Grito de Guerra")
  assert(printed("reino de este personaje: GritodeGuerra. Mercado: GritodeGuerra-Alliance."), chat())
  eq(OroHermandadCharDB.realm, "GritodeGuerra"); eq(OroHermandadCharDB.realmFrom, "manual")
  eq(source(), "manual"); eq(market(), "GritodeGuerra-Alliance")
  ns.Guild.Members()
  assert(OroHermandadDB.guilds["GritodeGuerra/Los Mineros"], "el almacén de la hermandad sigue al reino")
  -- Que no vale: no cambia nada.
  for _, bad in ipairs({"A|B", ("x"):rep(65), "- -"}) do
    Stub.printed = {}
    slash("reino " .. bad)
    assert(printed("uso: /oro reino (lo enseña), /oro reino <nombre>"), chat())
    eq(OroHermandadCharDB.realm, "GritodeGuerra", bad)
  end
  -- Borrar: vuelve a lo automático (aquí, el de tus datos).
  Stub.printed = {}
  slash("reino BORRAR")
  assert(printed("he borrado el reino guardado de este personaje. Ahora, reino: " .. OLD
    .. " (el juego no da el reino: el de tus datos guardados). Mercado: " .. OLD_KEY .. "."), chat())
  eq(market(), OLD_KEY); eq(source(), "datos")
  -- Con el reino del juego, ponerlo a mano no hace falta (y no se guarda).
  Stub.setRealm("Forever")
  Stub.printed = {}
  slash("reino Otro")
  assert(printed("el juego da el reino (Forever) y es el que se usa: no hace falta ponerlo a mano."), chat())
  eq(OroHermandadCharDB.realm, "Forever"); eq(OroHermandadCharDB.realmFrom, "juego")
  Stub.printed = {}
  slash("reino")
  assert(printed("reino: Forever (el reino lo da el juego). Mercado: Forever-Alliance."), chat())
  assert(not printed("/oro reino <nombre>"), "sin consejo si lo da el juego")
  Stub.printed = {}
  slash("ayuda")
  assert(printed("/oro reino — el reino de tus precios (WoW Forever ya no lo da)"), "en la ayuda")
end)

test("/oro sondeo: la línea «Mercado:» dice de dónde sale el reino; sin facción válida, sigue diciendo «no válido»", function()
  Stub.setRealm("")
  boot({hist = oldHist({[OLD_KEY] = 3600})})
  eq(marketLine(), "Mercado: " .. OLD_KEY .. " (el juego no da el reino: el de tus datos guardados)")
  slash("reino Grito de Guerra")
  eq(marketLine(), "Mercado: GritodeGuerra-Alliance (el juego no da el reino: el que pusiste con /oro reino)")
  boot()
  eq(marketLine(), "Mercado: Forever-Alliance (el juego no da el reino y no hay ninguno guardado: «Forever»; si tu "
    .. "hermandad usa otro, /oro reino <nombre>)")
  Stub.setRealm("MirageRaceway")
  boot()
  eq(marketLine(), "Mercado: MirageRaceway-Alliance (el reino lo da el juego)")
  local sv = saved()
  Stub.setRealm("")
  boot(Stub.deepCopy(sv))
  eq(marketLine(), "Mercado: MirageRaceway-Alliance (el juego no da el reino: el que dio antes a este personaje)")
  boot({db = Stub.deepCopy(sv.db)})
  eq(marketLine(), "Mercado: MirageRaceway-Alliance (el juego no da el reino: el que dio antes a otro personaje de tu cuenta)")
  Stub.playerFaction = "Neutral"
  local line = marketLine()
  Stub.playerFaction = "Alliance"
  eq(line, "Mercado: Forever-Neutral (no válido: falta el reino o la facción; no se graba nada)",
    "sin facción tampoco hay reino de la cuenta")
  Stub.setRealm("Forever")
end)

---------------------------------------------------------------------------
-- 3. El caso del jugador: escanear con el reino vacío
---------------------------------------------------------------------------
test("Reino vacío y su OroHermandadHist de la 0.5.x: el escáner graba en su mercado de siempre, guarda y comparte", function()
  Stub.setRealm("")
  boot({hist = oldHist({[OLD_KEY] = 86400})})
  enterWorld()
  scanAH()
  local markets = {}
  for key in pairs(OroHermandadHist.markets) do markets[#markets + 1] = key end
  eq(table.concat(markets, ","), OLD_KEY, "un solo mercado, el de siempre")
  local item = OroHermandadHist.markets[OLD_KEY].items[2772]
  local points = Spec.DecodePoints(item.p)
  eq(#points, 1, "el escaneo, grabado"); eq(points[1].lo, 100); eq(points[1].qty, 25)
  eq(#Spec.DecodeDays(item.d), 2, "su vela de ayer y la de hoy")
  assert(OroHermandadDB.scanPrices and OroHermandadDB.scanPrices[OLD_KEY], "precios del escáner en su mercado")
  assert(OroHermandadCharDB.scanBase and OroHermandadCharDB.scanBase[OLD_KEY], "referencia de ventas en su mercado")
  -- Compartido con la hermandad con la etiqueta de su mercado (antes, sin reino, el relay estaba apagado).
  local out = OroHermandadCharDB.relay and OroHermandadCharDB.relay.out
  assert(out and out[1], "en el buzón")
  eq(out[1].mk, ns.Relay.MarketTag(OLD_KEY))
  local p3 = 0
  for _, m in ipairs(Stub.sent) do
    if m.msg:match("^P3|") and m.channel == "GUILD" then p3 = p3 + 1; assert(has(m.msg, ns.Relay.MarketTag(OLD_KEY)), m.msg) end
  end
  assert(p3 >= 1, "el P3 sale a la hermandad")
  eq(ns.Scanner.lastError, nil); eq(ns.History.lastError, nil); eq(ns.Relay.lastError, nil)
  Stub.setRealm("Forever")
end)

test("Del reino solo se guarda el reino, nunca el nombre del personaje (GetPlayerInfoByGUID lo da justo al lado)", function()
  Stub.setRealm("", "", "Reino")
  boot()
  eq(OroHermandadCharDB.realm, "Reino"); eq(OroHermandadCharDB.realmFrom, "juego"); eq(OroHermandadDB.realms.Alliance, "Reino")
  for _, v in ipairs({OroHermandadCharDB.realm, OroHermandadCharDB.realmFrom, OroHermandadDB.realms.Alliance}) do
    assert(not has(v, UnitName("player")), "sin el nombre del personaje: " .. v)
  end
  Stub.setRealm("Forever")
  noErrors()
end)

---------------------------------------------------------------------------
-- 4. Revisión: lo que se escribe a mano, el reino de reserva y lo que sigue al reino
---------------------------------------------------------------------------
test("/oro reino con otras mayúsculas o con «-Alliance» pegado: la grafía del reino que ya conoces", function()
  Stub.setRealm("")
  boot({hist = oldHist({[OLD_KEY] = 3600})})
  -- El mercado y su etiqueta distinguen mayúsculas: en minúsculas serían otro mercado y no se compartiría nada.
  for _, typed in ipairs({OLD:lower(), OLD_KEY, OLD:upper() .. "-alliance", " " .. OLD .. " - Alliance "}) do
    Stub.printed = {}
    slash("reino " .. typed)
    eq(OroHermandadCharDB.realm, OLD, typed); eq(OroHermandadCharDB.realmFrom, "manual")
    eq(market(), OLD_KEY, typed)
    assert(printed("reino de este personaje: " .. OLD .. ". Mercado: " .. OLD_KEY .. "."), chat())
    assert(not printed("las mayúsculas cuentan"), "conocido: sin aviso")
  end
  -- Uno que no conoces: tal cual, con el aviso de que las mayúsculas cuentan.
  Stub.printed = {}
  slash("reino grito de guerra")
  eq(OroHermandadCharDB.realm, "gritodeguerra"); eq(market(), "gritodeguerra-Alliance")
  assert(printed("ojo: las mayúsculas cuentan. Escríbelo exactamente igual que sale en el /oro reino de tus compañeros."),
    chat())
  -- Un reino llamado como una facción no se queda vacío.
  slash("reino Horde")
  eq(OroHermandadCharDB.realm, "Horde")
  -- Instalación nueva (sin datos): «forever» es el de reserva, el de los demás sin datos.
  boot()
  Stub.printed = {}
  slash("reino forever")
  eq(OroHermandadCharDB.realm, "Forever"); eq(market(), "Forever-Alliance")
  assert(not printed("las mayúsculas cuentan"), chat())
  -- También los que dio el juego a la cuenta y los del almacén de la hermandad.
  boot({db = {realms = {Horde = "MirageRaceway"}, guilds = {[OLD .. "/Otra Hermandad"] = {members = {}}}}})
  slash("reino mirage-raceway")
  eq(OroHermandadCharDB.realm, "MirageRaceway")
  slash("reino " .. OLD:lower() .. "-Alliance")
  eq(OroHermandadCharDB.realm, OLD)
  Stub.setRealm("Forever")
end)

test("Reino de reserva: tras escanear sigue siendo «Forever» sin recordar (su «Forever-Alliance» no es un dato)", function()
  Stub.setRealm("")
  boot()
  enterWorld()
  scanAH()
  assert(OroHermandadHist.markets["Forever-Alliance"], "grabado en el de reserva")
  eq(realm(), "Forever"); eq(source(), "fijo")
  eq(OroHermandadCharDB.realm, nil, "no se recuerda"); eq(OroHermandadCharDB.realmFrom, nil)
  eq(marketLine(), "Mercado: Forever-Alliance (el juego no da el reino y no hay ninguno guardado: «Forever»; si tu "
    .. "hermandad usa otro, /oro reino <nombre>)")
  -- Al volver a entrar, igual; con otro reino en los datos, ese (aunque «Forever-Alliance» sea más reciente).
  ns = Stub.reload(DIR)
  eq(source(), "fijo"); eq(OroHermandadCharDB.realm, nil)
  boot({hist = oldHist({["Forever-Alliance"] = 60, [OLD_KEY] = 86400})})
  eq(realm(), OLD); eq(source(), "datos")
  -- Lo que recordó una versión de pruebas («Forever» sacado de los datos) se quita al cargar.
  boot({cdb = {realm = "Forever", realmFrom = "datos"}})
  eq(OroHermandadCharDB.realm, nil); eq(source(), "fijo")
  Stub.setRealm("Forever")
end)

test("Sin precios guardados: el reino del almacén de tu hermandad (la 0.5.x lo guardó con el reino del juego)", function()
  Stub.setRealm("")
  local function guilds()
    return {[OLD .. "/Los Mineros"] = {members = {Ana = manual({engineering = 150})}},
            ["Otro/Otra Hermandad"] = {members = {}}, ["/Los Mineros"] = {members = {}},
            ["Forever/Los Mineros"] = {members = {}}}
  end
  boot({db = {guilds = guilds()}})
  eq(realm(), OLD); eq(source(), "datos"); eq(market(), OLD_KEY)
  eq(OroHermandadCharDB.realm, OLD, "recordado"); eq(OroHermandadCharDB.realmFrom, "datos")
  eq(ns.Guild.UpdateKey(), OLD .. "/Los Mineros")
  eq(members().Ana.profs.engineering, 150, "sus amigos a mano siguen ahí")
  eq(marketLine(), "Mercado: " .. OLD_KEY .. " (el juego no da el reino: el de tus datos guardados)")
  eq(OroHermandadDB.guildRealms["Los Mineros"], OLD, "anotado una vez, solo reino y hermandad")
  -- /oro reino mueve lo de la hermandad al reino nuevo; /oro reino borrar vuelve al de antes (también tras recargar).
  slash("reino Otro Reino")
  eq(ns.Guild.UpdateKey(), "OtroReino/Los Mineros")
  ns = Stub.reload(DIR)
  slash("reino borrar")
  eq(realm(), OLD); eq(source(), "datos"); eq(ns.Guild.UpdateKey(), OLD .. "/Los Mineros")
  eq(members().Ana.profs.engineering, 150)
  -- Solo los de tu hermandad, con reino y que no sean el de reserva.
  boot({db = {guilds = {["Otro/Otra Hermandad"] = {members = {}}, ["/Los Mineros"] = {members = {}},
                        ["Forever/Los Mineros"] = {members = {}}}}})
  eq(source(), "fijo")
  -- La hermandad aún no ha cargado al entrar: «Forever» hasta que se sabe cuál es; entonces, su reino, y «Cuándo
  -- vender» lee el mercado nuevo sin volver a entrar.
  local getGuildInfo = _G.GetGuildInfo
  _G.GetGuildInfo = function() return nil end
  local ok, err = pcall(function()
    boot({db = {guilds = guilds()}})
    enterWorld()
    Stub.runTimers(120)
    eq(market(), "Forever-Alliance", "aún sin hermandad")
    eq(cuandoHead():find(PENDING, 1, true), nil, "la del de reserva, hecha")
  end)
  _G.GetGuildInfo = getGuildInfo
  assert(ok, err)
  eq(market(), OLD_KEY, "con la hermandad cargada")
  Stub.fire("GUILD_ROSTER_UPDATE")
  Stub.runTimers(10)
  eq(members().Ana.profs.engineering, 150)
  cuandoHead()
  Stub.runTimers(30)
  eq(cuandoHead():find(PENDING, 1, true), nil, "la del mercado nuevo, también")
  Stub.setRealm("Forever")
end)

test("Lo de la hermandad sigue al reino: /oro reino, /oro reino borrar y al volver a entrar con uno de verdad", function()
  Stub.setRealm("")
  boot()
  slash("amigo Ana ingenieria 150")
  ns.Guild.Handle("H2|40|mining=210|0|1", "Luis", "GUILD")
  eq(ns.Guild.UpdateKey(), "Forever/Los Mineros")
  assert(members().Ana and members().Luis, "antes")
  slash("reino " .. OLD)
  eq(ns.Guild.UpdateKey(), OLD .. "/Los Mineros")
  eq(members().Ana and members().Ana.profs.engineering, 150, "el amigo a mano sigue")
  eq(members().Luis and members().Luis.profs.mining, 210, "y lo que anunció un compañero")
  eq(OroHermandadDB.guilds["Forever/Los Mineros"], nil, "sin dejar el de antes aparte")
  Stub.runTimers(600)
  assert(members().Ana, "diez minutos después, también")
  slash("reino borrar")
  eq(ns.Guild.UpdateKey(), "Forever/Los Mineros")
  assert(members().Ana and members().Luis, "de vuelta a lo automático")
  -- La 0.5.x guardó amigos en «/Los Mineros»; con «Forever» se ven, y siguen tras /oro reino.
  boot({db = {guilds = {["/Los Mineros"] = {members = {Eva = manual({alchemy = 90})}}}}})
  eq(members().Eva.profs.alchemy, 90, "con «Forever»")
  slash("reino " .. OLD)
  eq(members().Eva and members().Eva.profs.alchemy, 90, "tras /oro reino")
  eq(OroHermandadDB.guilds["/Los Mineros"], nil); eq(OroHermandadDB.guilds["Forever/Los Mineros"], nil)
  -- Lo guardado con «Forever» pasa al reino de verdad al volver a entrar (sin pisar lo que ya hay).
  boot({db = {guilds = {["Forever/Los Mineros"] = {members = {Eva = manual({alchemy = 90}), Ana = manual({mining = 5})}},
                        [OLD .. "/Los Mineros"] = {members = {Ana = manual({engineering = 150})}}}},
        hist = oldHist({[OLD_KEY] = 3600})})
  eq(ns.Guild.UpdateKey(), OLD .. "/Los Mineros")
  eq(members().Eva.profs.alchemy, 90); eq(members().Ana.profs.engineering, 150); eq(members().Ana.profs.mining, nil)
  eq(OroHermandadDB.guilds["Forever/Los Mineros"], nil)
  -- Un amigo quitado no vuelve.
  slash("amigo borrar Eva")
  boot(saved())
  eq(members().Eva, nil, "quitado sigue quitado")
  Stub.setRealm("Forever")
end)

test("/oro cuando tras /oro reino: el mercado nuevo se lee sin volver a entrar", function()
  Stub.setRealm("")
  boot({hist = oldHist({["Otro-Alliance"] = 60})})
  enterWorld()
  Stub.runTimers(120)
  eq(market(), "Otro-Alliance")
  eq(cuandoHead():find(PENDING, 1, true), nil, "el de antes, leído")
  slash("reino " .. OLD)
  eq(market(), OLD_KEY)
  Stub.runTimers(60)
  eq(cuandoHead():find(PENDING, 1, true), nil, "el nuevo, también")
  eq(ns.Timing.lastError, nil)
  Stub.setRealm("Forever")
end)

realPrint(string.format("reino: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

-- Pruebas de los precios compartidos por la hermandad (Relay.lua, relay-v1) con varios clientes simulados que se
-- envían mensajes de addon a través del cliente de pruebas (wow_stub). Desde la raíz del repositorio:
--   lua5.1 test-lua/test_relay.lua
-- Los datos compartidos con el subidor y el panel están en test-lua/fixtures/relay/ (copias exactas de los del diseño)
-- y las versiones antiguas de Guild.lua, en test-lua/fixtures/legacy/.
package.path = "test-lua/?.lua;" .. package.path
local Stub = require("wow_stub")
local json = require("json")
local realPrint = print
-- Límite de cada tanda: 2 ms aquí; en CI (máquinas compartidas y más lentas) se deja margen para que la prueba
-- no falle por ruido, y aun así detecta una tanda sin trocear (cientos de ms).
local TICK_LIMIT_MS = (os.getenv("CI") and os.getenv("CI") ~= "") and 8 or 2
Stub.install()

local DIR, FIX, LEGACY = "addon/OroHermandad/", "test-lua/fixtures/relay/", "test-lua/fixtures/legacy/"
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local C = json.decode(read(FIX .. "constants.json"))
local WIRE = json.decode(read(FIX .. "wire.json"))
local HASHES = json.decode(read(FIX .. "obs-hash.json"))
local NOW, MARKET, TAG = C.now, C.market, C.marketTag
local HA, HJ, HB = C.hashes["Ána"], C.hashes.Jusep, C.hashes.Borja
local GUILDKEY = C.guildRealm .. "/" .. C.guildName

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; realPrint("FALLO: " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": esperado " .. tostring(b) .. ", obtenido " .. tostring(a), 2) end end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

local function dump(value)
  if type(value) ~= "table" then return type(value) == "string" and string.format("%q", value) or tostring(value) end
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = "[" .. dump(k) .. "]=" .. dump(value[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end
-- Un archivo de SavedVariables de las pruebas (OroHermandadDB y OroHermandadHist).
local function saved(name)
  local env = {}
  local chunk = assert(loadstring(read(FIX .. name)))
  setfenv(chunk, env)
  chunk()
  return env
end

---------------------------------------------------------------------------
-- Red simulada: varios clientes del addon en el mismo Lua
---------------------------------------------------------------------------
-- Cada cliente carga su propia copia del addon. Las funciones del juego miran `current` (el cliente cuyo código está
-- corriendo); cada temporizador recuerda de quién es. Los mensajes de addon llegan a los demás un momento después.
-- Reloj: la hora unix avanza con el tiempo de juego (GetServerTime = GetTime + offset).
local current
local offset = NOW - Stub.gameTime
local function unix() return math.floor(Stub.gameTime + offset) end
local function setUnix(t) offset = t - Stub.gameTime end
_G.time, _G.GetServerTime = unix, unix

local net = {clients = {}, byName = {}, roster = {}, log = {}, drop = nil, violations = {}, visible = {}}
local timers, timerSeq = {}, 0
_G.C_Timer.After = function(delay, fn)
  timerSeq = timerSeq + 1
  timers[#timers + 1] = {at = Stub.gameTime + (tonumber(delay) or 0), n = timerSeq, owner = current, fn = fn}
end
local tickLog = nil -- {owner = cliente, max = ms, clean = bool}: mide cuánto dura cada temporizador de ese cliente
local function run(seconds)
  local limit = Stub.gameTime + seconds
  for _ = 1, 1000000 do
    local best, index
    for i, t in ipairs(timers) do
      if not best or t.at < best.at or (t.at == best.at and t.n < best.n) then best, index = t, i end
    end
    if not best or best.at > limit then break end
    table.remove(timers, index)
    if best.at > Stub.gameTime then Stub.gameTime = best.at end
    if not (best.owner and best.owner.dead) then
      local prev = current
      current = best.owner
      -- clean: cada tanda se mide con la basura ya recogida (fuera de la medida) y el recolector parado.
      if tickLog and tickLog.clean and best.owner == tickLog.owner then collectgarbage("collect"); collectgarbage("stop") end
      local started = os.clock()
      best.fn()
      if tickLog and best.owner == tickLog.owner then
        tickLog.max = math.max(tickLog.max, (os.clock() - started) * 1000)
        tickLog.n = tickLog.n + 1
      end
      current = prev
    end
  end
  if Stub.gameTime < limit then Stub.gameTime = limit end
end
local function jumpTo(t) run(t - unix()) end

-- El juego visto desde el cliente actual.
_G.UnitName = function() return current and current.name end
_G.GetNormalizedRealmName = function() return current and current.realm end
_G.UnitFactionGroup = function() return current and current.faction end
_G.IsInGuild = function() return current ~= nil and current.guild ~= nil end
_G.GetGuildInfo = function() if current and current.guild then return current.guild, "Miembro", 3, current.guildRealm end end
_G.InCombatLockdown = function() return current ~= nil and current.combat == true end
_G.IsInInstance = function() if current and current.instance then return true, current.instance end return false, "none" end
_G.C_RestrictedActions = {IsAddOnRestrictionActive = function(kind) return current ~= nil and current.restricted[kind] == true end}
_G.Enum.AddOnRestrictionType = {Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5}
_G.Enum.SendAddonMessageResult.NotInGuild, _G.Enum.SendAddonMessageResult.TargetOffline = 10, 12
_G.C_ChatInfo.InChatMessagingLockdown = function() return current ~= nil and current.chatLock == true end
_G.C_AddOns.IsAddOnLoaded = function(name)
  if name == "OroHermandad_Subidor" and current and current.marker then return true, true end
  return false, false
end
_G.C_GuildInfo.MemberExistsByName = function(name) return net.roster[(name:match("^([^%-]+)"))] == true end
local realRandom = math.random
math.random = function(a, b)
  if current and current.random then return current.random(a, b) end
  return realRandom(a, b)
end
-- Lo que se vería en pantalla (además de print, PlaySound y CreateFrame del cliente de pruebas).
local function visible(kind) return function(...) net.visible[#net.visible + 1] = {kind = kind, args = {...}} end end
_G.SendChatMessage = visible("SendChatMessage")
_G.StaticPopup_Show = visible("StaticPopup_Show")
_G.RaidNotice_AddMessage = visible("RaidNotice_AddMessage")
_G.DEFAULT_CHAT_FRAME = {AddMessage = visible("DEFAULT_CHAT_FRAME")}
_G.UIErrorsFrame = {AddMessage = visible("UIErrorsFrame")}
-- EventBus de Auctionator compartido: cada escucha recuerda a qué cliente pertenece.
_G.Auctionator.EventBus.Register = function(self, listener, names)
  listener.__owner = current
  for _, name in ipairs(names) do Stub.bus[name] = Stub.bus[name] or {}; table.insert(Stub.bus[name], listener) end
  return self
end

local function isRelay(msg) return msg:match("^[PQ]3|") ~= nil end
local function blocked(c)
  if c.combat or c.instance or c.chatLock then return true end
  for _, on in pairs(c.restricted) do if on then return true end end
  return false
end

local function fire(c, event, ...)
  local prev = current
  current = c
  for _, f in ipairs(c.frames) do
    if f.__events[event] and f.__scripts.OnEvent then f.__scripts.OnEvent(f, event, ...) end
  end
  current = prev
end

local function deliver(dest, prefix, msg, channel, from, entry)
  timerSeq = timerSeq + 1
  timers[#timers + 1] = {at = Stub.gameTime + 0.05, n = timerSeq, owner = dest, fn = function()
    if not dest.online or (net.drop and net.drop(entry, dest)) then return end
    if dest.legacy then dest.received[#dest.received + 1] = dest.receive(prefix, msg, channel, from) return end
    fire(dest, "CHAT_MSG_ADDON", prefix, msg, channel, from)
  end}
end

_G.C_ChatInfo.SendAddonMessage = function(prefix, msg, channel, target)
  local c = assert(current, "envío sin cliente")
  if isRelay(msg) and blocked(c) then net.violations[#net.violations + 1] = msg end
  local forced = table.remove(c.results, 1)
  if forced and forced ~= 0 then c.refused[#c.refused + 1] = {msg = msg, result = forced, channel = channel, target = target}; return forced end
  if not c.online then return 9 end
  local dest = channel == "WHISPER" and net.byName[(target:match("^([^%-]+)"))] or nil
  if channel == "WHISPER" and not (dest and dest.online) then
    c.refused[#c.refused + 1] = {msg = msg, result = 12, channel = channel, target = target}
    return 12 -- TargetOffline
  end
  local entry = {from = c, msg = msg, channel = channel, target = target, at = Stub.gameTime}
  net.log[#net.log + 1] = entry
  c.sent[#c.sent + 1] = entry
  local from = c.name .. "-" .. c.realm
  if channel == "WHISPER" then
    deliver(dest, prefix, msg, channel, from, entry)
  elseif channel == "GUILD" then
    for _, other in ipairs(net.clients) do
      if other.online and other.guild == c.guild then deliver(other, prefix, msg, channel, from, entry) end
    end
  end
  return 0
end

-- Los archivos del addon según su TOC, sin los de skip (tras actualizar con solo un /reload, el juego carga la lista
-- de archivos de la versión anterior: sin Relay.lua).
local function loadWithout(dir, skip)
  local ns = {}
  for line in io.lines(dir .. "/OroHermandad.toc") do
    if line:match("%.lua$") and not skip[line] then assert(loadfile(dir .. "/" .. line))("OroHermandad", ns) end
  end
  return ns
end

-- Nuevo cliente (un personaje con el addon 0.4.0). o: name, realm, guild (false = sin hermandad), marker (aviso del
-- subidor), random, db/cdb/hist (lo que el juego cargaría del archivo), members (compañeros ya conocidos: sin sonido),
-- skip (archivos del TOC que no se cargan).
local function newClient(o)
  local c = {name = o.name, realm = o.realm or C.guildRealm, faction = o.faction or "Alliance", online = true,
             guild = o.guild == false and nil or (o.guild or C.guildName), guildRealm = o.guildRealm,
             marker = o.marker, random = o.random, restricted = {}, results = {}, sent = {}, refused = {}, frames = {}}
  local db = o.db or {}
  if o.members ~= false then
    db.guilds = db.guilds or {}
    local key = c.realm .. "/" .. (c.guild or "")
    db.guilds[key] = db.guilds[key] or {members = {}}
    for _, other in ipairs({"Jusep", "Ána", "Borja", "Eva", "Luis", "Viejo", "Rx", "Zoë"}) do
      if other ~= c.name then db.guilds[key].members[other] = {addon = {level = 60, seen = unix(), profs = {}, crafts = {}}} end
    end
  end
  net.clients[#net.clients + 1] = c
  net.byName[c.name] = c
  net.roster[c.name] = true
  current = c
  _G.OroHermandadDB, _G.OroHermandadCharDB, _G.OroHermandadHist = db, o.cdb, o.hist
  local before = #Stub.frames
  c.ns = o.skip and loadWithout(DIR, o.skip) or Stub.loadAddon(DIR)
  for i = before + 1, #Stub.frames do c.frames[#c.frames + 1] = Stub.frames[i] end
  current = c
  fire(c, "ADDON_LOADED", "OroHermandad")
  c.DB, c.CharDB = _G.OroHermandadDB, _G.OroHermandadCharDB
  c.slash = SlashCmdList.OROHERMANDAD
  c.Relay, c.Guild, c.History, c.Engine = c.ns.Relay, c.ns.Guild, c.ns.History, c.ns.Engine
  local ui, extras = c.ns.UI, c.ns.Extras
  local show, alert = ui.Show, extras.Alert
  ui.Show = function(...) net.visible[#net.visible + 1] = {kind = "UI.Show"}; return show(...) end
  extras.Alert = function(...) net.visible[#net.visible + 1] = {kind = "Extras.Alert"}; return alert(...) end
  current = nil
  return c
end

local function hist(c) return c.History.Hist() end
local function obsOf(c, h, market) local m = hist(c).markets[market or MARKET]; return m and m.obs and m.obs[h] end
local function slash(c, text) local prev = current; current = c; c.slash(text); current = prev; run(1) end
local function login(c, seconds)
  fire(c, "PLAYER_LOGIN")
  fire(c, "PLAYER_ENTERING_WORLD", true, false)
  run(seconds or 30)
end
local function logout(c)
  fire(c, "PLAYER_LOGOUT")
  c.online, c.dead = false, true
  for i, other in ipairs(net.clients) do if other == c then table.remove(net.clients, i) break end end
  if net.byName[c.name] == c then net.byName[c.name] = nil end
  return {db = copy(c.DB), cdb = copy(c.CharDB), hist = copy(hist(c))}
end
-- Un compañero con la versión 0.3.1 (o la 0.2.0) del addon: solo su Guild.lua, con su propio almacén.
local function legacyClient(file, name)
  local c = {name = name, realm = C.guildRealm, faction = "Alliance", online = true, guild = C.guildName, restricted = {},
             results = {}, sent = {}, refused = {}, frames = {}, legacy = true, received = {}}
  local inst = {}
  current = c
  for _, f in ipairs({"Data.lua", "Items.lua"}) do assert(loadfile(DIR .. f))("OroHermandad", inst) end
  assert(loadfile(LEGACY .. file))("OroHermandad", inst)
  c.db = {}
  inst.Guild.Init(c.db, function() return {level = 40, profs = {}, crafts = {}} end)
  c.Guild = inst.Guild
  c.receive = function(prefix, msg, channel, from) return inst.Guild.OnAddonMessage(prefix, msg, channel, from) end
  net.clients[#net.clients + 1] = c
  net.byName[name] = c
  net.roster[name] = true
  current = nil
  return c
end

-- Lo de un escaneo completo de Auctionator: items = {[id] = {lo, qty, qty5}} (lotes: qty5 al mínimo y el resto al
-- doble de precio).
local function listings(items)
  local out = {}
  for id, it in pairs(items) do
    local lo, qty, qty5 = it[1], it[2], it[3]
    local lots = {{qty5, lo}}
    if qty > qty5 then lots[2] = {qty - qty5, lo * 2} end
    out[#out + 1] = {id = id, lots = lots}
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end
local function scan(c, items)
  local data = Stub.scanRows("full", nil, listings(items))
  for _, l in ipairs(Stub.bus["replicate_scan_complete"] or {}) do
    if l.__owner == c then current = c; l:ReceiveEvent("replicate_scan_complete", data); current = nil end
  end
  run(5)
end
local function fromList(list) local out = {} for _, it in ipairs(list) do out[it[1]] = {it[2], it[3], it[4]} end return out end
local function sentBy(c, pattern, channel)
  local out = {}
  for _, e in ipairs(c.sent) do if e.msg:match(pattern) and (not channel or e.channel == channel) then out[#out + 1] = e end end
  return out
end
local function inject(c, msg, channel, from) fire(c, "CHAT_MSG_ADDON", "OroHerm", msg, channel or "GUILD", from) end

-- Invisible: mientras corre fn nada sale en el chat, suena, crea marcos ni se ve; y nada de precios sale con el
-- chat bloqueado, en combate o en instancias.
local function quiet(label, fn)
  local printed, sounds, frames, shown = #Stub.printed, #Stub.sounds, #Stub.frames, #net.visible
  fn()
  local extra = {}
  for i = printed + 1, #Stub.printed do extra[#extra + 1] = Stub.printed[i] end
  eq(#Stub.printed, printed, label .. ": líneas de chat (" .. table.concat(extra, " | ") .. ")")
  eq(#Stub.sounds, sounds, label .. ": sonidos")
  eq(#Stub.frames, frames, label .. ": marcos nuevos")
  eq(#net.visible, shown, label .. ": " .. (net.visible[shown + 1] and net.visible[shown + 1].kind or "visible"))
  eq(#net.violations, 0, label .. ": precios enviados con los mensajes restringidos")
end

---------------------------------------------------------------------------
-- 1. Formato: código de cada personaje, base 36, mensajes exactos y rechazos
---------------------------------------------------------------------------
local unit = newClient({name = "Rx", members = false})
current = unit
local R = unit.Relay

test("Código de cada personaje: el mismo texto canónico y el mismo FNV-1a que Python y JS (25 vectores)", function()
  local n = 0
  for _, v in ipairs(HASHES.vectors) do
    local canonical = R.Canonical(v.guildRealm, v.guildName, v.sender, v.ownRealm)
    eq(canonical, v.canonical, v.note); eq(R.Fnv1a32(canonical), v.hash, v.note)
    n = n + 1
  end
  for _, v in ipairs(HASHES.fnv1a32_plain) do eq(R.Fnv1a32(v.input), v.hash, "fnv " .. v.input); n = n + 1 end
  for _, v in ipairs(HASHES.market_tags) do eq(R.MarketTag(v.market), v.tag, v.market); n = n + 1 end
  eq(n, 25, "vectores")
  -- El que recibe lo calcula con el nombre que da el servidor y el reino de la hermandad (no el suyo).
  current = unit
  eq(R.Hash("Ána-GritodeGuerra"), HA); eq(R.Hash("ÁNA-gritodeguerra"), HA); eq(R.Hash("Ána"), HA, "sin reino: el tuyo")
  eq(R.Hash("Jusep-GritodeGuerra"), HJ)
  unit.realm, unit.guildRealm = "Sanguinarios", "Grito de Guerra"
  eq(R.Hash("Ána-GritodeGuerra"), HA, "reino conectado: la hermandad manda")
  unit.realm, unit.guildRealm = C.guildRealm, nil
  unit.guild = nil
  eq(R.Hash("Ána-GritodeGuerra"), nil, "sin hermandad no hay código")
  unit.guild = C.guildName
  current = nil
end)

test("Base 36: minúsculas, sin ceros a la izquierda y con su rango", function()
  for _, v in ipairs(WIRE.base36) do eq(R.B36(v.n), v.s); eq(R.D36(v.s, 0, 99999999999), v.n, v.s) end
  for _, bad in ipairs({"", "00", "01", "A", "+1", " 1", "1 ", "0x1", "zzzzzzzz", "-1", "1.5"}) do
    eq(R.D36(bad, 0, 99999999999), nil, "rechaza «" .. bad .. "»")
  end
  eq(R.D36("zz", 0, 1295), 1295); eq(R.D36("100", 0, 1295), nil, "fuera de rango")
end)

test("P3 y Q3: exactamente los mensajes esperados, de 250 bytes como mucho (114 objetos en 9 partes)", function()
  for _, p in ipairs(WIRE.p3) do
    local msgs = R.PackP3(p.seq, WIRE.marketTag, p.t, p.items)
    eq(#msgs, #p.messages, p.name)
    for i, m in ipairs(msgs) do eq(m, p.messages[i], p.name .. " parte " .. i); assert(#m <= 250, "largo " .. #m) end
  end
  eq(#WIRE.p3[4].items, 114); eq(#WIRE.p3[4].messages, 9)
  for _, q in ipairs(WIRE.q3) do
    local msgs = R.PackQ3(q.seq, WIRE.marketTag, q.floor, q.entries)
    eq(#msgs, #q.messages, q.name)
    for i, m in ipairs(msgs) do eq(m, q.messages[i], q.name .. " parte " .. i); assert(#m <= 250) end
  end
  -- Con más de 16 partes se quedan las 16 primeras (los ID más altos fuera).
  local many = {}
  for id = 1, 400 do many[#many + 1] = {100000 + id, 1000000000, 1000000, 1000000} end
  local msgs = R.PackP3(1295, TAG, NOW, many)
  eq(#msgs, 16)
  for i, m in ipairs(msgs) do assert(#m <= 250 and m:match("^P3|zz|" .. i .. "|16|"), m) end
end)

test("Mensajes rechazados y partes ignoradas (los casos de wire.json)", function()
  for _, r in ipairs(WIRE.rejected) do
    eq(R.Parse(r.message, WIRE.now, "GUILD", WIRE.marketTag), nil, r.why)
  end
  for _, r in ipairs(WIRE.accepted_with_ignored_parts) do
    local msg = R.Parse(r.message, WIRE.now, "GUILD", WIRE.marketTag)
    assert(msg, r.why)
    eq(dump(msg.items), dump(r.items), r.why)
  end
  -- La puesta al día (susurro) acepta hasta 72 h y 15 min; en directo, 6 h.
  local old = "P3|5|1|1|" .. TAG .. "|" .. R.B36(NOW - 72 * 3600 - 900) .. "|250:46:b4:1o"
  assert(R.Parse(old, NOW, "WHISPER", TAG), "72 h en la puesta al día")
  eq(R.Parse(old, NOW, "GUILD", TAG), nil, "en directo no")
  eq(R.Parse("P3|5|1|1|" .. TAG .. "|" .. R.B36(NOW - 72 * 3600 - 901) .. "|250:46:b4:1o", NOW, "WHISPER", TAG), nil, "ni un segundo más")
  -- Otras formas rotas: campos de más con símbolos, mayúsculas en la etiqueta, Q3 sin hora.
  eq(R.Parse("P3|5|1|1|" .. TAG .. "|tpks80|250:46:b4:1o|x;y", NOW, "GUILD", TAG), nil)
  eq(R.Parse("P3|5|1|1|06642D3B|tpks80|250:46:b4:1o", NOW, "GUILD", TAG), nil)
  eq(R.Parse("Q3|5|1|1|" .. TAG .. "||", NOW, "GUILD", TAG), nil)
  local q = R.Parse("Q3|5|1|1|" .. TAG .. "|tpf880|47da174e:tpkoio:zz|extra", NOW, "GUILD", TAG)
  assert(q and q.entries[HA] == 1796474400, "subcampos y campos de más ignorados en Q3")
end)

test("Con 40 compañeros en memoria, un escaneo nuevo y rehacer la caché van por tandas de menos de 2 ms", function()
  -- Con el recolector parado toda la sesión, la basura de decodificar 40 compañeros hace que el propio Lua de las
  -- pruebas agrande una y otra vez su tabla de textos (milisegundos que no son del addon; en el juego el recolector
  -- va recogiendo): por eso cada tanda se mide tras recoger la basura (clean).
  _G.debugprofilestop = function() return os.clock() * 1000 end
  local c = newClient({name = "Rx5"})
  login(c, 30)
  current = c
  local Spec = c.ns.Spec
  local T = Spec.DayIndex(unix())
  local obs = {}
  for o = 1, c.History.OBS_PER_MARKET do
    local items = {}
    for i, id in ipairs(c.History.FixedIDs()) do
      local ds, pts = {}, {}
      for d = T - 14, T do
        local p = 100 + (i * 977 + d * 13 + o * 31) % 4900
        ds[#ds + 1] = {d = d, lo = p, hi = p + 40, last = p + 10, qty = 10 + i, scans = 3, src = "o"}
      end
      for k = 1, 9 do pts[#pts + 1] = {t = unix() - 72 * 3600 + k * 28000 - o, lo = 100 + k, qty = 10, qty5 = 5} end
      items[id] = {d = Spec.EncodeDays(ds), p = Spec.EncodePoints(pts)}
    end
    obs[string.format("%08x", 0x10000000 + o * 7919)] = {seen = unix() - 600 - o, s = tostring(unix() - 600 - o), items = items}
  end
  c.History.Market(MARKET, true).obs = obs
  c.Relay.GuildItems("Otro-Horde"); c.Relay.GuildItems(MARKET) -- caché nueva: los 40 compañeros, por tandas
  current = nil
  tickLog = {owner = c, max = 0, n = 0, clean = true}
  run(120)
  local rebuild = tickLog
  -- Un compañero nuevo comparte un escaneo de 114 objetos: solo se decodifica lo suyo.
  tickLog = {owner = c, max = 0, n = 0, clean = true}
  for _, m in ipairs(R.PackP3(7, TAG, unix() - 30, WIRE.p3[4].items)) do inject(c, m, "GUILD", "Nuevo-GritodeGuerra") end
  run(120)
  local live = tickLog
  tickLog = nil
  collectgarbage("restart")
  _G.debugprofilestop = nil
  current = c
  local items = c.Relay.GuildItems(MARKET)
  eq(#items[WIRE.p3[4].items[1][1]].list, c.History.OBS_PER_MARKET, "40 compañeros en el objeto (el nuevo echó al más viejo)")
  assert(rebuild.max < TICK_LIMIT_MS, string.format("caché nueva: tanda más larga %.2f ms", rebuild.max))
  assert(live.max < TICK_LIMIT_MS, string.format("escaneo nuevo: tanda más larga %.2f ms", live.max))
  assert(live.n < rebuild.n, "tras un escaneo se reutiliza lo de los demás: " .. live.n .. " < " .. rebuild.n)
  realPrint(string.format("  40 compañeros en memoria: caché nueva %d tandas (la más larga %.2f ms), escaneo nuevo %d tandas (%.2f ms)",
    rebuild.n, rebuild.max, live.n, live.max))
  current = nil
  logout(c)
end)

---------------------------------------------------------------------------
-- 2. Cola de Guild.lua: prioridad, bloqueos, resultados del servidor y caducidad
---------------------------------------------------------------------------
local solo = newClient({name = "Solo", guild = "Los Solitarios", members = false})
login(solo, 150) -- pasa también el minuto entre anuncios de profesiones
local function relayMsgs(n, tag) local out = {} for i = 1, n do out[i] = "P3|" .. tag .. "|" .. i .. "|" .. n .. "|" .. TAG .. "|tpks80|" end return out end
local function soloEnqueue(msgs, channel, target, ttl, onSent)
  current = solo
  local ok = solo.Guild.EnqueueRelay(msgs, channel, target, ttl, onSent)
  current = nil
  return ok
end

test("Lo de profesiones (H2/R2) nunca espera detrás de los precios", function()
  solo.sent = {}
  assert(soloEnqueue(relayMsgs(8, "a"), "GUILD", nil, 600))
  run(2.5) -- sale la primera parte o dos
  current = solo; solo.Guild.Announce(true); solo.Guild.Request(); current = nil
  run(60)
  local order = {}
  for _, e in ipairs(solo.sent) do order[#order + 1] = e.msg:sub(1, 2) end
  local text = table.concat(order, ",")
  local firstH = text:find("H2")
  assert(firstH and text:sub(firstH):match("^H2,R2,P3"), "H2 y R2 adelantan a los precios: " .. text)
  eq(#sentBy(solo, "^P3|a|"), 8, "y los precios salen todos después")
  -- Con los precios esperando el fin del combate, un R2 no espera a la siguiente comprobación (10 s).
  solo.sent, solo.combat = {}, true
  assert(soloEnqueue(relayMsgs(2, "w"), "GUILD", nil, 3600))
  run(3)
  current = solo; solo.Guild.Request(); current = nil
  run(1)
  eq(#sentBy(solo, "^R2$"), 1, "R2 en menos de 1 s")
  solo.combat = false
  run(30)
  eq(#sentBy(solo, "^P3|w|"), 2, "y luego los precios")
end)

test("Sin enviar precios en combate, instancias, restricciones (0-5) ni con el chat bloqueado; sin gastar intentos", function()
  for _, block in ipairs({"combat", "instance", "chatLock", 0, 1, 2, 3, 4, 5}) do
    solo.sent = {}
    if type(block) == "number" then solo.restricted[block] = true elseif block == "instance" then solo.instance = "party" else solo[block] = true end
    assert(soloEnqueue(relayMsgs(2, "b"), "GUILD", nil, 3600))
    run(120)
    eq(#sentBy(solo, "^P3"), 0, "bloqueado: " .. tostring(block))
    if type(block) == "number" then solo.restricted[block] = nil elseif block == "instance" then solo.instance = nil else solo[block] = nil end
    run(30)
    eq(#sentBy(solo, "^P3|b|"), 2, "sale al acabar: " .. tostring(block))
  end
  -- Las profesiones siguen como antes (solo esperan con el chat bloqueado).
  solo.sent, solo.combat = {}, true
  current = solo; solo.Guild.Request(); current = nil
  run(5)
  eq(#sentBy(solo, "^R2$"), 1, "R2 en combate")
  solo.combat = false
  eq(#net.violations, 0, "nada de precios con los mensajes restringidos")
end)

test("Resultados del servidor: 3 y 8 se reintentan, 11 espera sin gastar intentos, 12 corta lo de ese susurro", function()
  solo.sent = {}
  solo.results = {3, 8}
  assert(soloEnqueue(relayMsgs(1, "c"), "GUILD", nil, 600))
  run(30)
  eq(#sentBy(solo, "^P3|c|"), 1, "reintentado")
  solo.results = {11, 11, 11, 11, 11, 11, 11, 11, 11}
  assert(soloEnqueue(relayMsgs(1, "d"), "GUILD", nil, 600))
  run(200)
  eq(#sentBy(solo, "^P3|d|"), 1, "11 no gasta los 6 intentos")
  -- 6 frenazos seguidos: se pierde esa serie entera y NO se repite el anuncio de profesiones (sin state.owed).
  solo.sent = {}
  solo.results = {8, 8, 8, 8, 8, 8}
  assert(soloEnqueue(relayMsgs(3, "e"), "GUILD", nil, 600))
  run(120)
  eq(#sentBy(solo, "^P3|e|"), 0, "serie perdida"); eq(#sentBy(solo, "^H2"), 0, "sin anuncio repetido")
  -- Susurro a alguien que se fue (12): fuera el resto de la serie y todo lo que iba a esa persona; lo demás sigue.
  net.roster.Nadie = true
  assert(soloEnqueue(relayMsgs(3, "f"), "WHISPER", "Nadie-GritodeGuerra", 600))
  assert(soloEnqueue(relayMsgs(2, "g"), "WHISPER", "Nadie-GritodeGuerra", 600))
  assert(soloEnqueue(relayMsgs(1, "h"), "GUILD", nil, 600))
  run(60)
  eq(#sentBy(solo, "^P3|[fg]|"), 0, "nada más a Nadie"); eq(#sentBy(solo, "^P3|h|"), 1, "lo de la hermandad sale")
  local tried = 0
  for _, r in ipairs(solo.refused) do if r.msg:match("^P3|[fg]|") then tried = tried + 1 end end
  eq(tried, 1, "solo se intentó la primera parte")
  eq(#sentBy(solo, "^H2"), 0, "ni anuncio repetido")
end)

test("Caducidad, tope de 64 y onSent al salir de verdad", function()
  solo.sent = {}
  solo.combat = true
  local sentAt
  assert(soloEnqueue(relayMsgs(2, "i"), "GUILD", nil, 30))
  assert(soloEnqueue(relayMsgs(1, "j"), "GUILD", nil, 600, function() sentAt = Stub.gameTime end))
  run(60)
  solo.combat = false
  run(30)
  eq(#sentBy(solo, "^P3|i|"), 0, "caducada sin avisar"); eq(#sentBy(solo, "^P3|j|"), 1)
  assert(sentAt and sentAt >= solo.sent[#solo.sent].at, "onSent cuando sale")
  current = solo
  eq(solo.Guild.EnqueueRelay(relayMsgs(65, "k"), "GUILD", nil, 600), false, "más de 64")
  eq(solo.Guild.EnqueueRelay({("x"):rep(251)}, "GUILD", nil, 600), false, "más de 250 bytes")
  eq(solo.Guild.RelayQueued(), 0, "no se puso nada")
  current = nil
end)

---------------------------------------------------------------------------
-- 3. Versiones antiguas: la 0.3.1 y la 0.2.0 ignoran P3 y Q3
---------------------------------------------------------------------------
test("0.3.1 y 0.2.0 ignoran P3 y Q3 (hermandad, susurro dentro y fuera de la ventana de R2) sin tocar nada", function()
  for _, file in ipairs({"Guild-0.3.1.lua", "Guild-0.2.0.lua"}) do
    local old = legacyClient(file, "Viejo")
    current = old
    local messages = {}
    for _, group in ipairs({WIRE.p3, WIRE.q3}) do
      for _, item in ipairs(group) do for _, m in ipairs(item.messages) do messages[#messages + 1] = m end end
    end
    for _, r in ipairs(WIRE.rejected) do messages[#messages + 1] = r.message end
    for _, r in ipairs(WIRE.accepted_with_ignored_parts) do messages[#messages + 1] = r.message end
    old.Guild.Members() -- su almacén de la hermandad ya existe (lo crea al abrir la ventana)
    local before = dump(old.db)
    for _, m in ipairs(messages) do eq(old.Guild.OnAddonMessage("OroHerm", m, "GUILD", "Ána-GritodeGuerra"), false, file .. " " .. m) end
    for _, m in ipairs(messages) do eq(old.Guild.OnAddonMessage("OroHerm", m, "WHISPER", "Ána-GritodeGuerra"), false, file) end
    old.Guild.Request() -- abre su ventana de respuestas por susurro
    for _, m in ipairs(messages) do eq(old.Guild.OnAddonMessage("OroHerm", m, "WHISPER", "Ána-GritodeGuerra"), false, file) end
    eq(dump(old.db), before, file .. ": su almacén no cambia")
    current = nil
    old.online, old.dead = false, true
    for i, other in ipairs(net.clients) do if other == old then table.remove(net.clients, i) break end end
    net.byName.Viejo = nil
  end
end)

---------------------------------------------------------------------------
-- 4. Historial: esquema 1 -> 2 sin pérdidas, esquema 2 intacto, topes
---------------------------------------------------------------------------
local function freshHistory(c)
  local H = {Data = c.ns.Data, Items = c.ns.Items, Spec = c.ns.Spec, Prices = c.ns.Prices, Scan = c.ns.Scan}
  assert(loadfile(DIR .. "History.lua"))("OroHermandad", H)
  return H.History
end
local Spec = unit.ns.Spec

test("Una OroHermandadHist de la 0.3.1 (esquema 1) pasa al 2 sin perder nada", function()
  setUnix(C.nowLegacy)
  local file = saved("hist-schema1.lua")
  local before = copy(file.OroHermandadHist)
  current = unit
  local H = freshHistory(unit)
  local loaded = H.Load(copy(file.OroHermandadHist), {db = copy(file.OroHermandadDB), market = function() return MARKET end})
  current = nil
  eq(loaded.schema, 2); eq(loaded.addon, "0.4.0")
  local n = 0
  for key, market in pairs(before.markets) do
    local now = loaded.markets[key]
    assert(now, "mercado " .. key)
    eq(dump(now.items), dump(market.items), key .. " objetos"); eq(dump(now.dep), dump(market.dep), key .. " depósitos")
    eq(now.updated, market.updated, key .. " updated"); eq(now.cut, market.cut, key .. " cut")
    eq(now.obs, nil); eq(now.self, nil)
    n = n + 1
  end
  eq(n, 2, "los dos mercados")
  -- Y la 0.4.0 entera (Core) con ese archivo: lo mismo, y su personaje queda apuntado al entrar.
  local jusep = newClient({name = "Jusep", db = copy(file.OroHermandadDB), hist = copy(file.OroHermandadHist), members = false})
  for key, market in pairs(before.markets) do eq(dump(hist(jusep).markets[key].items), dump(market.items), key) end
  login(jusep, 30)
  eq(hist(jusep).markets[MARKET].self, HJ, "self con el código del personaje")
  logout(jusep)
  setUnix(NOW)
end)

test("Una OroHermandadHist del esquema 2 se carga y se guarda sin cambiar nada; la 0.3.1 no la toca", function()
  setUnix(NOW)
  local file = saved("hist-schema2.lua")
  current = unit
  local H = freshHistory(unit)
  local loaded = H.Load(copy(file.OroHermandadHist), {db = copy(file.OroHermandadDB), market = function() return MARKET end})
  eq(dump(loaded), dump(file.OroHermandadHist), "idéntica al cargar")
  H.BeforeSave()
  eq(dump(loaded), dump(file.OroHermandadHist), "idéntica al guardar")
  -- La 0.3.1 la ve más nueva: la deja tal cual y apaga su historial (volver a la 0.4.0 la recupera).
  local L = {Data = unit.ns.Data, Items = unit.ns.Items, Spec = unit.ns.Spec, Prices = unit.ns.Prices}
  assert(loadfile(LEGACY .. "History-0.3.1.lua"))("OroHermandad", L)
  local original = copy(file.OroHermandadHist)
  eq(L.History.Load(original, {db = {}, market = function() return MARKET end}), original, "la misma tabla")
  eq(L.History.Hist(), nil, "historial apagado en la 0.3.1"); eq(dump(original), dump(file.OroHermandadHist), "intacta")
  current = nil
end)

test("Carga: códigos raros, compañeros viejos, objetos fuera de la lista fija y 40 compañeros como mucho", function()
  current = unit
  local H = freshHistory(unit)
  local today = Spec.DayIndex(NOW)
  local obs = {}
  local function entry(seen) return {seen = seen, s = tostring(seen), items = {[2772] = {d = today .. ",100,100,100,5,1,o", p = seen .. ",100,5,1"}}} end
  for i = 1, 45 do obs[string.format("%08x", i)] = entry(NOW - 3600 - i * 60) end
  obs.ZZZZZZZZ = entry(NOW); obs["1234"] = entry(NOW); obs[HJ] = entry(NOW) -- inválidos y uno propio
  obs.aaaaaaaa = {seen = NOW - 16 * 86400, s = "", items = {[2772] = {d = (today - 16) .. ",1,1,1,1,1,o", p = ""}}}
  obs.bbbbbbbb = {seen = NOW, s = "x,7," .. NOW, items = {[5000] = {d = today .. ",1,1,1,1,1,o", p = ""}}} -- 5000 no es fijo
  obs.cccccccc = {seen = NOW, s = "", items = {[2772] = {d = today .. ",1,1,1,1,1,a", p = ""}}} -- src a: no es suyo
  local loaded = H.Load({schema = 2, markets = {[MARKET] = {items = {}, dep = {}, self = HJ .. ",XYZ,ffff", obs = obs}}},
    {db = {}, market = function() return MARKET end})
  current = nil
  local m = loaded.markets[MARKET]
  eq(m.self, HJ, "self sin códigos raros")
  local n = 0
  for h in pairs(m.obs) do n = n + 1; assert(h:match("^%x+$") and #h == 8 and h ~= HJ, h) end
  eq(n, 40, "40 como mucho")
  for i = 1, 40 do assert(m.obs[string.format("%08x", i)], "se quedan los más nuevos " .. i) end
  eq(m.obs.aaaaaaaa, nil, "15 días sin escaneos"); eq(m.obs.bbbbbbbb, nil, "solo lista fija"); eq(m.obs.cccccccc, nil, "solo días propios")
end)

-- Historial grande como el de test_history.lua: ids x días con puntos.
local function bigItems(ids, days, pointsPerDay, keepPoints, now)
  local today = Spec.DayIndex(now)
  local items = {}
  for i, id in ipairs(ids) do
    local recs, pts = {}, {}
    for d = today - days + 1, today do
      local p = 25000 + (id * 37 + d * 101) % 125000
      recs[#recs + 1] = {d = d, lo = p, hi = p + (d * 13) % 9000, last = p + 400, qty = 100 + (id + d) % 4000, scans = 1 + d % 5, src = "o"}
    end
    for k = 0, keepPoints - 1 do
      pts[#pts + 1] = {t = now - k * math.floor(86400 / pointsPerDay), lo = 25000 + (id + k * 7) % 125000, qty = 100 + k % 3000, qty5 = 10 + k % 300}
    end
    items[id] = {n = "Objeto de la lista número " .. i, c = Spec.CATEGORIES[1 + i % 14], v = 125 + i,
                 d = Spec.EncodeDays(recs), p = Spec.EncodePoints(pts)}
  end
  return items
end
local function obsFrom(items, seen)
  local out = {}
  for id, item in pairs(items) do out[id] = {d = item.d, p = item.p} end
  return {seen = seen, s = tostring(seen), items = out}
end

test("Topes: lo tuyo (768 KB) se mide sin lo de los compañeros, que tiene sus 2 MB y sus pasos", function()
  current = unit
  local H = freshHistory(unit)
  local fixed = H.FixedIDs()
  local today = Spec.DayIndex(NOW)
  -- Lo tuyo cabe (114 objetos x 120 días, ~610 KB) y lo de los compañeros también, pero juntos pasan de 768 KB:
  -- lo tuyo no se recorta.
  local own = bigItems(fixed, 120, 4, 14 * 4, NOW)
  local mateItems = bigItems(fixed, 15, 4, 12, NOW)
  local hist = {schema = 2, markets = {[MARKET] = {updated = NOW, items = copy(own), dep = {}, obs = {
    ["0000000a"] = obsFrom(mateItems, NOW - 60), ["0000000b"] = obsFrom(mateItems, NOW - 120), ["0000000c"] = obsFrom(mateItems, NOW - 180)}}}}
  local loaded = H.Load(hist, {db = {}, market = function() return MARKET end})
  local info = H.LoadInfo()
  assert(Spec.EstimateSize(loaded) > Spec.MAX_BYTES, "juntos pasan de 768 KB: " .. Spec.EstimateSize(loaded))
  eq(info.shrinkStep, 0, "lo tuyo no se recorta"); eq(info.obsStep, 0, "lo de los compañeros cabe")
  eq(dump(loaded.markets[MARKET].items), dump(own), "lo tuyo intacto")
  -- Los pasos, con un tope a medida (ShrinkObs lo admite): 6 compañeros de 15 días con 3 días de puntos.
  local function build(n, seenStep)
    local obs = {}
    for i = 1, n do obs[string.format("%08x", 0x100 + i)] = obsFrom(bigItems(fixed, 15, 4, 12, NOW), NOW - i * (seenStep or 60)) end
    return {schema = 2, markets = {[MARKET] = {items = {}, dep = {}, obs = obs}}}
  end
  local function each(h, fn)
    for _, entry in pairs(h.markets[MARKET].obs or {}) do for _, item in pairs(entry.items) do fn(item) end end
  end
  -- Tamaño tras cada paso, calculado aparte: (1) puntos de 24 h, (2) días de 7 días, (3) de 3 días, (4) sin puntos.
  local probe = build(6)
  local sizes = {H.ObsSize(probe)}
  each(probe, function(item) item.p = Spec.EncodePoints(Spec.PrunePoints(Spec.DecodePoints(item.p), NOW, 86400)) end)
  sizes[2] = H.ObsSize(probe)
  each(probe, function(item) item.d = Spec.EncodeDays(Spec.PruneDays(Spec.DecodeDays(item.d), today, 7)) end)
  sizes[3] = H.ObsSize(probe)
  each(probe, function(item) item.d = Spec.EncodeDays(Spec.PruneDays(Spec.DecodeDays(item.d), today, 3)) end)
  sizes[4] = H.ObsSize(probe)
  each(probe, function(item) item.p = "" end)
  sizes[5] = H.ObsSize(probe)
  for k = 1, 4 do assert(sizes[k + 1] < sizes[k], "cada paso ahorra: " .. k) end
  for step = 1, 4 do
    local h = build(6)
    local got, size = H.ShrinkObs(h, NOW, sizes[step + 1])
    eq(got, step, "paso " .. step); assert(size <= sizes[step + 1], "cabe: " .. size)
    local n = 0
    for _ in pairs(h.markets[MARKET].obs) do n = n + 1 end
    eq(n, 6, "paso " .. step .. ": siguen todos los compañeros")
    each(h, function(item)
      local days = Spec.DecodeDays(item.d)
      eq(days[#days].d, today, "paso " .. step .. ": el día de hoy sigue")
      assert(days[1].d > today - (step >= 3 and 3 or step >= 2 and 7 or 15), "paso " .. step .. ": días " .. days[1].d)
      for _, p in ipairs(Spec.DecodePoints(item.p)) do assert(step < 4 and p.t > NOW - 86400, "paso " .. step .. ": puntos") end
    end)
  end
  -- Paso 5, solo si ni así cabe: se van compañeros, el de escaneo más viejo primero.
  local h5 = build(12)
  local step5, size5 = H.ShrinkObs(h5, NOW, sizes[5])
  eq(step5, 5, "paso 5"); assert(size5 <= sizes[5], size5)
  local kept = {}
  for h in pairs(h5.markets[MARKET].obs) do kept[#kept + 1] = h end
  table.sort(kept)
  assert(#kept >= 5 and #kept < 12, "algunos fuera: " .. #kept)
  for i = 1, #kept do eq(kept[i], string.format("%08x", 0x100 + i), "se quedan los más nuevos") end
  -- Con el tope de verdad: 25 compañeros con 15 días y 3 días de puntos solo pierden los puntos de más de 24 h.
  local h25 = build(25)
  local out = H.Load(h25, {db = {}, market = function() return MARKET end})
  local i1 = H.LoadInfo()
  eq(i1.obsStep, 1, "25 compañeros: paso 1"); assert(i1.obsSize <= H.OBS_MAX_BYTES, i1.obsSize)
  local n25 = 0
  for _, entry in pairs(out.markets[MARKET].obs) do
    n25 = n25 + 1
    for _, item in pairs(entry.items) do eq(#Spec.DecodeDays(item.d), 15, "sus 15 días") end
  end
  eq(n25, 25, "los 25")
  -- Al salir (BeforeSave), con lo que llegó en la sesión: los 40 compañeros que admite un mercado, activos (114
  -- objetos, 15 días, 3 escaneos al día), siguen todos con el día de hoy y los 2 anteriores, que el subidor envía.
  H.Load({schema = 2, markets = {}}, {db = {}, market = function() return MARKET end})
  local live = H.Hist()
  live.markets[MARKET] = {items = {}, dep = {}, obs = {}}
  for i = 1, H.OBS_PER_MARKET do live.markets[MARKET].obs[string.format("%08x", 0x200 + i)] = obsFrom(bigItems(fixed, 15, 3, 9, NOW), NOW - i * 60) end
  local before = H.ObsSize(live)
  local expected = copy(live.markets[MARKET].obs)
  local started = os.clock()
  local _, _, stepOut, sizeOut = H.BeforeSave()
  local ms = (os.clock() - started) * 1000
  assert(stepOut <= 2 and sizeOut <= H.OBS_MAX_BYTES, "al salir " .. tostring(stepOut) .. " " .. tostring(sizeOut))
  -- Tras la carga los textos se recortan cortándolos (sin decodificar): da lo mismo que el camino largo.
  for _, entry in pairs(expected) do
    for _, item in pairs(entry.items) do
      if stepOut >= 1 then item.p = Spec.EncodePoints(Spec.PrunePoints(Spec.DecodePoints(item.p), NOW, 86400)) end
      if stepOut >= 2 then item.d = Spec.EncodeDays(Spec.PruneDays(Spec.DecodeDays(item.d), today, 7)) end
    end
  end
  eq(dump(live.markets[MARKET].obs), dump(expected), "recortar cortando = decodificar y volver a codificar")
  assert(ms < 1000, string.format("al salir, %.0f ms", ms))
  local survivors = 0
  for _, entry in pairs(live.markets[MARKET].obs) do
    survivors = survivors + 1
    local items = 0
    for _, item in pairs(entry.items) do
      items = items + 1
      local days = Spec.DecodeDays(item.d)
      eq(days[#days].d, today, "hoy"); assert(#days >= 3, "y los 2 anteriores")
    end
    eq(items, #fixed, "todos sus objetos")
  end
  eq(survivors, H.OBS_PER_MARKET, "los 40 compañeros siguen")
  realPrint(string.format("  tamaño: lo tuyo %.0f KB + compañeros %.0f KB sin recortar lo tuyo · 40 compañeros activos %.0f KB -> paso %d, %.0f KB (%.0f ms al salir)",
    Spec.EstimateSize(loaded.markets[MARKET].items) / 1024, info.obsSize / 1024, before / 1024, stepOut, sizeOut / 1024, ms))
  current = nil
end)

---------------------------------------------------------------------------
-- 5. Varios clientes: en directo, puesta al día con el subidor, petición por susurro
---------------------------------------------------------------------------
local ANA_SCANS = {}
for _, p in ipairs(WIRE.p3) do if p.obs == HA then ANA_SCANS[#ANA_SCANS + 1] = {t = p.t, items = fromList(p.items)} end end
local fixture2 = saved("hist-schema2.lua").OroHermandadHist
local ANA_FIXTURE = fixture2.markets[MARKET].obs[HA]

-- Ána (solo el addon) escanea la subasta mientras Jusep (que sube los precios al panel) no está.
setUnix(ANA_SCANS[1].t - 120)
local ana = newClient({name = "Ána", random = function(a, b) assert(a == 2 and b == 90, "retraso de 2 a 90 s"); return 7 end})
login(ana, 60)

test("Un escaneo completo se comparte en directo, invisible, y cada addon lo guarda (sin nombres)", function()
  local borja = newClient({name = "Borja"})
  login(borja, 30)
  local old = legacyClient("Guild-0.3.1.lua", "Viejo") -- un compañero que sigue con la 0.3.1
  local oldDB = dump(old.db)
  quiet("en directo", function()
    jumpTo(ANA_SCANS[1].t)
    scan(ana, ANA_SCANS[1].items)
    run(30)
  end)
  assert(#old.received >= 1, "la 0.3.1 también lo recibe")
  for _, changed in ipairs(old.received) do eq(changed, false, "y lo ignora") end
  eq(dump(old.db), oldDB, "sin tocar su almacén")
  old.online, old.dead = false, true
  for i, other in ipairs(net.clients) do if other == old then table.remove(net.clients, i) break end end
  net.byName.Viejo = nil
  local live = sentBy(ana, "^P3|", "GUILD")
  eq(#live, 1, "un P3 a la hermandad")
  local seq = live[1].msg:match("^P3|(%w+)|")
  eq(live[1].msg, (R.PackP3(R.D36(seq, 0, 1295), TAG, ANA_SCANS[1].t, WIRE.p3[1].items))[1], "el mensaje del contrato")
  local got = obsOf(borja, HA)
  assert(got, "Borja guarda lo de Ána con su código")
  eq(got.seen, ANA_SCANS[1].t); eq(got.s, tostring(ANA_SCANS[1].t))
  eq(got.items[2770].d, (ANA_FIXTURE.items[2770].d:match("^[^;]+")), "su vela del día")
  -- Lo que se guarda no lleva su nombre.
  local text = dump(hist(borja))
  assert(not has(text, "Ána") and not has(text, "Borja"), "sin nombres en OroHermandadHist")
  eq(ana.CharDB.relay.out[1].t, ANA_SCANS[1].t, "en el buzón de Ána (72 h)")
  logout(borja)
end)

test("Puesta al día: el PC con el subidor pide al entrar y recibe por susurro lo que se perdió (= hist-schema2.lua)", function()
  -- Ána escanea dos veces más; nadie con el subidor está conectado.
  for i = 2, 3 do jumpTo(ANA_SCANS[i].t); scan(ana, ANA_SCANS[i].items); run(30) end
  eq(#sentBy(ana, "^P3|", "GUILD"), 3, "tres escaneos, tres anuncios")
  jumpTo(NOW - 60)
  local file = saved("hist-schema1.lua")
  local jusep = newClient({name = "Jusep", marker = true, db = copy(file.OroHermandadDB), hist = copy(file.OroHermandadHist)})
  jusep.DB.relay.lastAsk = nil
  login(jusep, 23)
  quiet("puesta al día", function() run(150) end)
  local asks = sentBy(jusep, "^Q3|", "GUILD")
  eq(#asks, 1, "una petición a la hermandad")
  assert(asks[1].msg:match("^Q3|%w+|1|1|" .. TAG .. "|%w+|$"), "sin compañeros conocidos aún: " .. asks[1].msg)
  local replies = sentBy(ana, "^P3|", "WHISPER")
  eq(#replies, 3, "Ána responde con sus 3 escaneos de 72 h, por susurro")
  for _, r in ipairs(replies) do eq(r.target, "Jusep-GritodeGuerra") end
  assert(replies[1].at - asks[1].at >= 7, "después del retraso al azar")
  eq(dump(obsOf(jusep, HA)), dump(ANA_FIXTURE), "lo de Ána en Jusep, exacto")
  local lastAsk = jusep.DB.relay.lastAsk
  assert(lastAsk and lastAsk <= unix() and lastAsk >= unix() - 150, "lastAsk guardado en la cuenta: " .. tostring(lastAsk))
  -- Un /reload no vuelve a pedir antes de 10 min; /oro sync sí, pasados.
  local saved1 = logout(jusep)
  jusep = newClient({name = "Jusep", marker = true, db = saved1.db, cdb = saved1.cdb, hist = saved1.hist})
  login(jusep, 60)
  eq(#sentBy(jusep, "^Q3|"), 0, "tras /reload no repite")
  run(600)
  Stub.printed = {}
  slash(jusep, "sync")
  assert(has(Stub.printed[#Stub.printed], "y también los precios que este PC se perdió"), Stub.printed[#Stub.printed])
  run(5)
  local again = sentBy(jusep, "^Q3|", "GUILD")
  eq(#again, 1, "pasados 10 min, /oro sync pide otra vez")
  assert(has(again[1].msg, HA .. ":" .. R.B36(ANA_SCANS[3].t)), "con lo que ya tiene de Ána: " .. again[1].msg)
  run(60)
  eq(#sentBy(ana, "^P3|", "WHISPER"), 3, "y Ána no repite lo que ya tiene")
  -- /oro estado y /oro sondeo cuentan compañeros (solo al pedirlo, sin nombres ni códigos).
  Stub.printed = {}
  slash(jusep, "estado")
  local text = table.concat(Stub.printed, "\n")
  assert(has(text, "precios compartidos: 1 compañero en este mercado (el último escaneo, hace "), text)
  assert(not has(text, HA), "sin códigos")
  slash(jusep, "sondeo")
  text = table.concat(Stub.printed, "\n")
  assert(has(text, "Precios compartidos: 1 compañero en este mercado, último escaneo recibido hace "), text)
  assert(has(text, "subidor: automático (aviso del PC: sí) · compartir: sí · ") and has(text, " KB de 2048 KB"), text)
  assert(not has(text, HA) and not has(text, "Ána"), "sin nombres ni códigos en el sondeo")
  net.jusep = jusep
end)

test("Mensaje perdido: la serie incompleta se descarta y la siguiente petición la recupera", function()
  local jusep = net.jusep
  -- Ána escanea otra vez mientras Jusep no está (se desconecta un momento).
  local savedJ = logout(jusep)
  run(900)
  local t4 = unix()
  scan(ana, {[2772] = {151, 300, 40}, [13446] = {2350, 55, 20}})
  run(60)
  jusep = newClient({name = "Jusep", marker = true, db = savedJ.db, cdb = savedJ.cdb, hist = savedJ.hist})
  local lost = false
  net.drop = function(entry, dest)
    if dest == jusep and entry.channel == "WHISPER" and entry.msg:match("^P3|") and not lost then lost = true; return true end
  end
  login(jusep, 200)
  assert(lost, "se perdió una parte")
  eq(obsOf(jusep, HA).seen, ANA_SCANS[3].t, "el escaneo perdido no se aplica")
  net.drop = nil
  run(700)
  slash(jusep, "sync")
  run(120)
  eq(obsOf(jusep, HA).seen, t4, "llega con la siguiente petición")
  local d = Spec.DecodeDays(obsOf(jusep, HA).items[2772].d)
  eq(d[#d].scans, 2, "una vez cada escaneo (el de hoy a las 13:40 y este)")
  net.jusep = jusep
end)

test("Petición por susurro: un compañero que entra después recibe una petición solo para él", function()
  local jusep = net.jusep
  -- Borja comparte en directo (Jusep lo conoce), se va, escanea a solas y vuelve cuando Jusep está conectado.
  local borja = newClient({name = "Borja"})
  login(borja, 30)
  scan(borja, {[2772] = {147, 430, 66}, [12365] = {298, 125, 33}})
  run(30)
  local seen1 = obsOf(jusep, HB) and obsOf(jusep, HB).seen
  assert(seen1, "Jusep tiene lo de Borja en directo")
  jusep.online = false
  run(1000)
  scan(borja, {[2772] = {148, 425, 64}, [12365] = {300, 118, 30}})
  local t2 = unix() - 5
  run(30)
  local savedB = logout(borja)
  jusep.online = true
  run(1900) -- más de 30 min desde que se le pidió nada
  borja = newClient({name = "Borja", db = savedB.db, cdb = savedB.cdb, hist = savedB.hist})
  login(borja, 10) -- su mensaje de bienvenida (no es de los precios) sale a los 8 s
  quiet("petición por susurro", function() run(120) end)
  local targeted = sentBy(jusep, "^Q3|", "WHISPER")
  eq(#targeted, 1, "un Q3 por susurro a Borja")
  eq(targeted[1].target, "Borja-GritodeGuerra")
  assert(targeted[1].msg:match("|$"), "sin entradas: " .. targeted[1].msg)
  eq(obsOf(jusep, HB).seen, t2, "y llega lo que Borja escaneó a solas")
  -- No se repite en 30 min aunque vuelva a anunciarse.
  current = borja; borja.Guild.Announce(true); current = nil
  run(120)
  eq(#sentBy(jusep, "^Q3|", "WHISPER"), 1, "una vez cada 30 min")
  net.borja = borja
end)

---------------------------------------------------------------------------
-- 6. Reglas de quien recibe: reconstrucción, duplicados, límites, basura
---------------------------------------------------------------------------
local rx = newClient({name = "Rx2", marker = false})
login(rx, 30)
local LUCJA = WIRE.p3[4]
local function lucjaFrom(seq)
  local t = unix() - 60
  return R.PackP3(seq, TAG, t, LUCJA.items), t
end

test("Reconstrucción: partes desordenadas, repetidas, otra serie del mismo, 48 abiertas y 120 s", function()
  local before = R.Stats and rx.Relay.Stats().dropped
  -- Desordenadas y con repetidas: se aplica una vez.
  local msgs, tL = lucjaFrom(3)
  quiet("reconstrucción", function()
    for i = #msgs, 1, -1 do inject(rx, msgs[i], "GUILD", "Łucja-GritodeGuerra"); inject(rx, msgs[i], "GUILD", "Łucja-GritodeGuerra") end
    run(30)
  end)
  local h = rx.Relay.Hash and (function() current = rx; local x = rx.Relay.Hash("Łucja-GritodeGuerra"); current = nil; return x end)()
  eq(h, LUCJA.obs)
  local got = obsOf(rx, h)
  local n = 0
  for _ in pairs(got.items) do n = n + 1 end
  eq(n, 114, "los 114 objetos"); eq(got.s, tostring(tL)); eq(got.seen, tL)
  eq(#Spec.DecodeDays(got.items[765].d), 1)
  -- Falta una parte 120 s: se descarta; la parte que llega tarde no la completa.
  run(700)
  local late = lucjaFrom(4)
  for i = 1, #late - 1 do inject(rx, late[i], "GUILD", "Zoë-Sanguinarios") end
  run(121)
  inject(rx, late[#late], "GUILD", "Zoë-Sanguinarios")
  run(10)
  current = rx
  eq(obsOf(rx, rx.Relay.Hash("Zoë-Sanguinarios")), nil, "incompleta 120 s")
  -- Otra serie del mismo compañero tira la anterior sin completar.
  local tA = unix() - 30
  local a = R.PackP3(5, TAG, tA, {{2772, 100, 10, 5}, {2770, 40, 10, 5}, {12365, 300, 10, 5}})
  local split, two = {}, nil
  for _, it in ipairs(LUCJA.items) do
    split[#split + 1] = it
    two = R.PackP3(6, TAG, unix() - 20, split)
    if #two == 2 then break end
  end
  eq(#two, 2, "una serie de dos partes")
  inject(rx, two[1], "GUILD", "Eva-GritodeGuerra")
  inject(rx, a[1], "GUILD", "Eva-GritodeGuerra")
  inject(rx, two[2], "GUILD", "Eva-GritodeGuerra")
  run(30)
  local eva = obsOf(rx, rx.Relay.Hash("Eva-GritodeGuerra"))
  assert(eva and eva.s == tostring(tA), "solo la serie nueva: " .. tostring(eva and eva.s))
  -- Partes que no casan (otro total): fuera.
  local mismatch = R.PackP3(7, TAG, unix() - 10, split)
  inject(rx, mismatch[1], "GUILD", "Luis-GritodeGuerra")
  inject(rx, (mismatch[2]:gsub("^P3|7|2|" .. #mismatch .. "|", "P3|7|2|9|")), "GUILD", "Luis-GritodeGuerra")
  for i = 3, #mismatch do inject(rx, mismatch[i], "GUILD", "Luis-GritodeGuerra") end
  run(30)
  eq(obsOf(rx, rx.Relay.Hash("Luis-GritodeGuerra")), nil, "otro total")
  -- 48 series abiertas como mucho (una por cada uno de los 40 compañeros y margen). Con la tabla llena se va la que
  -- menos partes tiene (a igualdad, la más vieja), nunca la más vieja sin más, que es la que está por completarse.
  local three
  split = {}
  for _, it in ipairs(LUCJA.items) do
    split[#split + 1] = it
    three = R.PackP3(8, TAG, unix() - 20, split)
    if #three == 3 then break end
  end
  eq(#three, 3, "una serie de tres partes")
  inject(rx, three[1], "GUILD", "Primera-GritodeGuerra")
  inject(rx, three[2], "GUILD", "Primera-GritodeGuerra")
  run(0.5)
  current = rx
  local maxOpen = rx.Relay.Internals().maxOpen
  eq(maxOpen, rx.History.OBS_PER_MARKET + 8, "48")
  for i = 1, maxOpen - 1 do
    inject(rx, (two[1]:gsub("^P3|6|", "P3|" .. i .. "|")), "GUILD", "Alt" .. i .. "-GritodeGuerra")
    run(0.5)
  end
  current = rx
  eq(rx.Relay.Internals().openCount, maxOpen, "llena")
  inject(rx, (two[1]:gsub("^P3|6|", "P3|" .. maxOpen .. "|")), "GUILD", "Alt" .. maxOpen .. "-GritodeGuerra")
  current = rx
  eq(rx.Relay.Internals().openCount, maxOpen, "sigue llena")
  inject(rx, three[3], "GUILD", "Primera-GritodeGuerra")
  inject(rx, (two[2]:gsub("^P3|6|", "P3|1|")), "GUILD", "Alt1-GritodeGuerra")
  inject(rx, (two[2]:gsub("^P3|6|", "P3|2|")), "GUILD", "Alt2-GritodeGuerra")
  inject(rx, (two[2]:gsub("^P3|6|", "P3|" .. maxOpen .. "|")), "GUILD", "Alt" .. maxOpen .. "-GritodeGuerra")
  run(30)
  current = rx
  assert(obsOf(rx, rx.Relay.Hash("Primera-GritodeGuerra")), "la más vieja, con 2 de 3 partes, se completa")
  eq(obsOf(rx, rx.Relay.Hash("Alt1-GritodeGuerra")), nil, "se descartó la más vieja de las que tenían 1 parte")
  assert(obsOf(rx, rx.Relay.Hash("Alt2-GritodeGuerra")), "las demás siguen")
  assert(obsOf(rx, rx.Relay.Hash("Alt" .. maxOpen .. "-GritodeGuerra")), "y la nueva también")
  assert(rx.Relay.Stats().dropped > before, "descartes contados para /oro sondeo")
  current = nil
end)

test("40 compañeros por mercado: uno nuevo entra solo si su escaneo es más nuevo que el más viejo", function()
  local c = newClient({name = "Rx4"})
  login(c, 30)
  current = c
  local market = c.History.Market(MARKET, true)
  market.obs = {}
  local today = Spec.DayIndex(unix())
  for i = 1, 40 do
    market.obs[string.format("%08x", 0x1000 + i)] = {seen = unix() - 3600 + i, s = tostring(unix() - 3600 + i),
      items = {[2772] = {d = today .. ",100,100,100,5,1,o", p = (unix() - 3600 + i) .. ",100,5,1"}}}
  end
  inject(c, R.PackP3(1, TAG, unix() - 7200, {{2772, 120, 10, 5}})[1], "GUILD", "Eva-GritodeGuerra")
  run(20)
  current = c
  eq(obsOf(c, c.Relay.Hash("Eva-GritodeGuerra")), nil, "más viejo que todos: fuera")
  inject(c, R.PackP3(2, TAG, unix() - 60, {{2772, 121, 10, 5}})[1], "GUILD", "Luis-GritodeGuerra")
  run(20)
  current = c
  assert(obsOf(c, c.Relay.Hash("Luis-GritodeGuerra")), "más nuevo: entra")
  eq(market.obs[string.format("%08x", 0x1001)], nil, "sale el de escaneo más viejo")
  local n = 0
  for _ in pairs(market.obs) do n = n + 1 end
  eq(n, 40)
  -- Tus propios personajes (self) nunca entran en obs: un alt de esta cuenta que comparte se ignora.
  market.self = c.Relay.OwnHash() .. "," .. C.hashes["Jusepín"]
  inject(c, R.PackP3(3, TAG, unix() - 30, {{2772, 122, 10, 5}})[1], "GUILD", "Jusepín-GritodeGuerra")
  run(20)
  current = c
  eq(market.obs[C.hashes["Jusepín"]], nil, "alt propio ignorado")
  -- self: 10 códigos como mucho, el personaje que entra va primero.
  local ten = {}
  for i = 1, 10 do ten[i] = string.format("%08x", 0x2000 + i) end
  market.self = table.concat(ten, ",")
  c.Relay.Login()
  local list = c.History.SelfList(market.self)
  eq(#list, 10); eq(list[1], c.Relay.OwnHash(), "primero"); eq(list[10], ten[9], "se va el más viejo")
  current = nil
  logout(c)
end)

test("Sin duplicados: el mismo escaneo en directo y por susurro, o repetido, se cuenta una vez", function()
  current = rx
  local h = rx.Relay.Hash("Ána-GritodeGuerra")
  local t = unix() - 100
  local items = {{2772, 160, 50, 10}}
  inject(rx, R.PackP3(10, TAG, t, items)[1], "GUILD", "Ána-GritodeGuerra")
  run(20)
  local entry = obsOf(rx, h)
  eq(entry.seen, t)
  local d = entry.items[2772].d
  inject(rx, R.PackP3(11, TAG, t, items)[1], "GUILD", "Ána-GritodeGuerra")
  run(700)
  inject(rx, R.PackP3(12, TAG, t, items)[1], "GUILD", "Ána-GritodeGuerra")
  run(20)
  eq(obsOf(rx, h).items[2772].d, d, "misma vela"); eq(obsOf(rx, h).s, tostring(t), "una hora")
  current = nil
end)

test("Límites de quien recibe: 1 en directo cada 10 min, susurros solo pedidos y de la hermandad, 8 por ventana", function()
  current = rx
  local h = rx.Relay.Hash("Eva-GritodeGuerra")
  run(700)
  local t1 = unix() - 50
  inject(rx, R.PackP3(20, TAG, t1, {{2772, 150, 10, 5}})[1], "GUILD", "Eva-GritodeGuerra")
  inject(rx, R.PackP3(21, TAG, t1 + 10, {{2772, 151, 10, 5}})[1], "GUILD", "Eva-GritodeGuerra")
  run(20)
  eq(obsOf(rx, h).seen, t1, "el segundo en menos de 10 min no")
  -- Susurros sin haberlos pedido: nada.
  inject(rx, R.PackP3(22, TAG, unix() - 20, {{2772, 152, 10, 5}})[1], "WHISPER", "Eva-GritodeGuerra")
  run(20)
  eq(obsOf(rx, h).seen, t1, "susurro no pedido")
  -- Con la ventana abierta (subidor activado a mano): de la hermandad sí, de fuera no; 8 escaneos por ventana.
  rx.DB.relay.lastAsk = nil
  Stub.printed = {}
  slash(rx, "subidor on")
  assert(has(Stub.printed[1], "subidor activado: este PC pedirá a la hermandad los precios que se perdió."), Stub.printed[1])
  run(10)
  eq(#sentBy(rx, "^Q3|", "GUILD"), 1, "pide al activarlo")
  current = rx
  inject(rx, R.PackP3(23, TAG, unix() - 3000, {{2772, 153, 10, 5}})[1], "WHISPER", "Extraño-OtroReino")
  current = rx
  run(10)
  eq(obsOf(rx, rx.Relay.Hash("Extraño-OtroReino")), nil, "de fuera de la hermandad no")
  local known = #rx.History.DecodeTimes(obsOf(rx, h).s)
  for i = 1, 9 do inject(rx, R.PackP3(30 + i, TAG, unix() - 7200 - i * 600, {{2772, 150 + i, 10, 5}})[1], "WHISPER", "Eva-GritodeGuerra") end
  run(60)
  local times = rx.History.DecodeTimes(obsOf(rx, h).s)
  eq(#times, known + 8, "8 por ventana")
  current = rx
  slash(rx, "subidor auto")
  current = nil
end)

test("Basura, mensajes propios y de otro mercado: sin errores ni efectos", function()
  run(120)
  current = rx
  local before = dump(hist(rx))
  local junk = {"P3", "Q3", "P3|", "Q3|||||||", ("P3|"):rep(100), "P3|zz|1|1|" .. TAG .. "|" .. ("z"):rep(300), "P3|\0|1|1|x|y|z",
                "Q3|1|1|1|" .. TAG .. "|tpf880|" .. ("47da174e:tpkoio,"):rep(14), "P3|1|1|1|" .. TAG .. "|tpks80|a:b:c:d:e:f:g:h",
                "P3|1|1|1|" .. TAG .. "|tpks80|,", "P3|1|1|1|" .. TAG .. "|tpks80|250:46:b4:1o,,", "Q3|1|1|1|" .. TAG .. "|tpf880|,"}
  for i = 1, 200 do
    local parts = {}
    for k = 1, realRandom(1, 12) do parts[k] = string.char(realRandom(32, 126)):rep(realRandom(0, 6)) end
    junk[#junk + 1] = (realRandom(1, 2) == 1 and "P3|" or "Q3|") .. table.concat(parts, realRandom(1, 2) == 1 and "|" or ":")
  end
  quiet("basura", function()
    for _, m in ipairs(junk) do
      inject(rx, m, "GUILD", "Malo-GritodeGuerra")
      inject(rx, m, "WHISPER", "Malo-GritodeGuerra")
    end
    inject(rx, R.PackP3(1, TAG, unix() - 10, {{2772, 1, 1, 1}})[1], "GUILD", "Rx2-GritodeGuerra") -- el propio eco
    inject(rx, R.PackP3(1, "7dd6b140", unix() - 10, {{2772, 1, 1, 1}})[1], "GUILD", "Eva-GritodeGuerra") -- Horda
    inject(rx, "P3|1|1|1|" .. TAG .. "|tpks80|250:46:b4:1o", "PARTY", "Eva-GritodeGuerra") -- otro canal
    run(30)
  end)
  eq(dump(hist(rx)), before, "nada cambia")
  eq(rx.Relay.lastError, nil, "sin errores internos"); eq(rx.Guild.relayError, nil)
  -- Nadie habla por otro: el mismo P3 de Ána reenviado por Malo cuenta como de Malo (el código sale del remitente
  -- que da el servidor), nunca como de Ána.
  current = rx
  local anaBefore = dump(obsOf(rx, rx.Relay.Hash("Ána-GritodeGuerra")))
  inject(rx, R.PackP3(77, TAG, unix() - 15, WIRE.p3[1].items)[1], "GUILD", "Malo-GritodeGuerra")
  run(20)
  current = rx
  assert(obsOf(rx, rx.Relay.Hash("Malo-GritodeGuerra")), "queda a nombre de quien lo envió")
  eq(dump(obsOf(rx, rx.Relay.Hash("Ána-GritodeGuerra"))), anaBefore, "lo de Ána no cambia")
  current = nil
end)

---------------------------------------------------------------------------
-- 7. Quien comparte: 15 min, buzón, respuestas (retraso, 10 min, 4 escaneos y 24 mensajes), compartir off
---------------------------------------------------------------------------
test("Como mucho un anuncio cada 15 min por personaje; el más nuevo sale al cumplirse", function()
  ana.sent = {}
  run(1000)
  local t1 = unix()
  scan(ana, {[2772] = {140, 100, 10}})
  run(60)
  local t2 = unix()
  scan(ana, {[2772] = {141, 100, 10}})
  run(60)
  local t3 = unix()
  scan(ana, {[2772] = {142, 100, 10}})
  run(60)
  local live = sentBy(ana, "^P3|", "GUILD")
  eq(#live, 1, "uno en 15 min")
  run(900)
  live = sentBy(ana, "^P3|", "GUILD")
  eq(#live, 2, "el temporizador manda uno")
  assert(live[2].msg:match("|" .. R.B36(t3) .. "|"), "el más nuevo")
  assert(live[2].at - live[1].at >= 899, "15 min después")
  assert(t1 and t2, "tiempos")
end)

test("Respuestas: una por persona cada 10 min, con retraso al azar, del más viejo, 4 escaneos y 24 mensajes", function()
  -- Un compañero nuevo, con 6 escaneos de 114 objetos en su buzón (9 partes cada uno).
  local big = newClient({name = "Luis", random = function() return 2 end})
  login(big, 30)
  local all = fromList(LUCJA.items)
  for i = 1, 6 do
    run(1000)
    local items = {}
    for id, it in pairs(all) do items[id] = {it[1] + i, it[2], math.min(it[3], it[2])} end
    scan(big, items)
  end
  run(1000)
  eq(#big.CharDB.relay.out, 6, "6 en el buzón")
  big.sent = {}
  current = big
  inject(big, R.PackQ3(1, TAG, unix() - 72 * 3600, {})[1], "GUILD", "Rx2-GritodeGuerra")
  current = big
  inject(big, R.PackQ3(2, TAG, unix() - 72 * 3600, {})[1], "GUILD", "Rx2-GritodeGuerra")
  run(1.9)
  eq(#sentBy(big, "^P3|"), 0, "espera el retraso")
  run(120)
  local out = sentBy(big, "^P3|", "WHISPER")
  local series, order = {}, {}
  for _, e in ipairs(out) do
    local seq, total, t = e.msg:match("^P3|(%w+)|%d+|(%d+)|%x+|(%w+)|")
    if not series[seq] then series[seq] = {total = tonumber(total), t = R.D36(t, 0, 1e10), n = 0}; order[#order + 1] = seq end
    series[seq].n = series[seq].n + 1
  end
  local parts = series[order[1]].total
  assert(parts >= 7 and parts <= 12, "114 objetos en unas 9 partes: " .. parts)
  eq(#order, math.min(4, math.floor(24 / parts)), "escaneos enteros que caben en 24 mensajes")
  assert(#out <= 24 and #out + parts > 24, "24 mensajes como mucho: " .. #out)
  for _, seq in ipairs(order) do eq(series[seq].n, series[seq].total, "solo escaneos enteros") end
  assert(series[order[1]].t < series[order[#order]].t, "del más viejo al más nuevo")
  for i, seq in ipairs(order) do
    eq(series[seq].t, big.CharDB.relay.out[i].t, "empieza por el más viejo y no se salta ninguno: " .. i)
  end
  -- Otra petición de la misma persona en menos de 10 min: no se responde.
  inject(big, R.PackQ3(3, TAG, unix() - 72 * 3600, {})[1], "GUILD", "Rx2-GritodeGuerra")
  run(60)
  eq(#sentBy(big, "^P3|", "WHISPER"), #out, "10 min")
  -- Escaneos pequeños: 4 como mucho, y solo los posteriores a lo que ya tiene quien pide.
  local small = newClient({name = "Eva", random = function() return 30 end})
  login(small, 30)
  for i = 1, 6 do run(1000); scan(small, {[2772] = {150 + i, 100, 10}}) end
  local since = small.CharDB.relay.out[2].t
  current = small
  local me = small.Relay.OwnHash()
  inject(small, R.PackQ3(4, TAG, unix() - 72 * 3600, {[me] = since})[1], "WHISPER", "Rx2-GritodeGuerra")
  run(29)
  eq(#sentBy(small, "^P3|", "WHISPER"), 0, "30 s de retraso")
  run(60)
  local replies = sentBy(small, "^P3|", "WHISPER")
  eq(#replies, 4, "4 escaneos")
  for _, r in ipairs(replies) do assert(R.D36(r.msg:match("^P3|%w+|1|1|%x+|(%w+)|"), 0, 1e10) > since, "posteriores") end
  -- Con la cola de precios llena (48 o más), no responde.
  current = small
  for i = 1, 3 do small.Guild.EnqueueRelay(relayMsgs(16, "z" .. i), "GUILD", nil, 3600) end
  small.combat = true
  inject(small, R.PackQ3(5, TAG, unix() - 72 * 3600, {})[1], "WHISPER", "Borja-GritodeGuerra")
  run(60)
  eq(#sentBy(small, "^P3|", "WHISPER"), 4, "cola llena")
  small.combat = false
  run(200)
  current = nil
  logout(big); logout(small)
end)

test("/oro compartir off: no anuncia ni responde, pero sigue recibiendo", function()
  Stub.printed = {}
  slash(ana, "compartir off")
  eq(Stub.printed[1], "|cffe6c35aOro de Hermandad:|r compartir precios con la hermandad: desactivado: tus escaneos ya no se comparten (sigues viendo los de la hermandad).")
  eq(#ana.CharDB.relay.out, 0, "buzón vacío")
  ana.sent = {}
  run(1000)
  scan(ana, {[2772] = {150, 100, 10}})
  run(1000)
  eq(#sentBy(ana, "^P3|"), 0, "no anuncia")
  current = ana
  inject(ana, R.PackQ3(9, TAG, unix() - 72 * 3600, {})[1], "GUILD", "Rx2-GritodeGuerra")
  run(60)
  eq(#sentBy(ana, "^P3|"), 0, "no responde")
  local h = ana.Relay.Hash("Eva-GritodeGuerra")
  inject(ana, R.PackP3(50, TAG, unix() - 10, {{2772, 155, 10, 5}})[1], "GUILD", "Eva-GritodeGuerra")
  run(20)
  assert(obsOf(ana, h), "sigue recibiendo")
  Stub.printed = {}
  slash(ana, "compartir on")
  eq(Stub.printed[1], "|cffe6c35aOro de Hermandad:|r compartir precios con la hermandad: activado.")
  slash(ana, "compartir")
  eq(Stub.printed[2], "|cffe6c35aOro de Hermandad:|r compartir precios con la hermandad: activado.", "sin palabra: consulta")
  current = nil
end)

---------------------------------------------------------------------------
-- 8. Aviso del subidor y /oro subidor
---------------------------------------------------------------------------
test("Aviso del subidor: OroHermandad_Subidor cargado o su tabla; on, off y auto", function()
  local c = newClient({name = "Zoë", realm = "Sanguinarios"})
  login(c, 40)
  eq(#sentBy(c, "^Q3|"), 0, "sin aviso no pide")
  current = c
  eq(c.Relay.UploaderMode(), false)
  -- La tabla del aviso (el archivo que crea hermandad.py, tal cual).
  assert(loadfile(FIX .. "companion/OroHermandad_Subidor/OroHermandad_Subidor.lua"))()
  assert(_G.OroHermandadSubidor and _G.OroHermandadSubidor.formato == 1, "el aviso define su tabla")
  Stub.printed = {}
  slash(c, "subidor")
  eq(Stub.printed[1], "|cffe6c35aOro de Hermandad:|r subidor: automático (este PC sube precios: sí). Pide a la hermandad los precios que se perdió mientras no estabas.")
  current = c
  eq(c.Relay.UploaderMode(), true, "con la tabla del aviso")
  _G.OroHermandadSubidor = nil
  slash(c, "subidor")
  eq(Stub.printed[2], "|cffe6c35aOro de Hermandad:|r subidor: automático (este PC sube precios: no).")
  slash(c, "subidor off")
  eq(Stub.printed[3], "|cffe6c35aOro de Hermandad:|r subidor desactivado: este PC solo recoge lo que la hermandad comparte mientras juegas.")
  slash(c, "subidor")
  eq(Stub.printed[4], "|cffe6c35aOro de Hermandad:|r subidor: desactivado.")
  c.marker = true
  current = c
  eq(c.Relay.UploaderMode(), false, "off manda sobre el aviso")
  slash(c, "subidor auto")
  eq(Stub.printed[5], "|cffe6c35aOro de Hermandad:|r subidor en automático: se activa si el subidor del PC ha creado su aviso (sal del juego del todo una vez tras instalarlo).")
  slash(c, "subidor on"); slash(c, "subidor")
  eq(Stub.printed[7], "|cffe6c35aOro de Hermandad:|r subidor: siempre activado.")
  slash(c, "subidor quizá")
  eq(Stub.printed[8], "|cffe6c35aOro de Hermandad:|r uso: /oro subidor on|off|auto")
  slash(c, "ayuda")
  local help = table.concat(Stub.printed, "\n")
  assert(has(help, "/oro compartir on|off —") and has(help, "/oro subidor on|off|auto —"), "en la ayuda")
  current = nil
  logout(c)
  -- C_AddOns.IsAddOnLoaded("OroHermandad_Subidor"): al entrar (a los 25 s) pide.
  local up = newClient({name = "Zoë", realm = "Sanguinarios", marker = true})
  login(up, 40)
  eq(#sentBy(up, "^Q3|", "GUILD"), 1, "con el aviso cargado pide al entrar")
  logout(up)
end)

---------------------------------------------------------------------------
-- 9. Especular con los precios de la hermandad (Engine, puro)
---------------------------------------------------------------------------
local Engine = unit.Engine
local ET = 2600
local ENOW = Spec.DAY0 + ET * 86400 + 15 * 3600
local WORKED = {9600, 9800, 10000, 10200, 10400, 9900, 10100, 9700, 10300, 10000, 9900, 10100, 10000, 10000}
local function records(values, first)
  local out = {}
  for i, v in ipairs(values) do
    if v then out[#out + 1] = {d = (first or ET - #values) + i - 1, lo = v, hi = v, last = v, qty = 400, scans = 1, src = "o"} end
  end
  return out
end
local function ectx(mode, items, over)
  local c = {mode = mode or "spec", now = ENOW, hasPriceSource = true, ageKnown = true, dbUpdatedAt = ENOW - 600,
             price = function() return nil end, age = function() return nil end, vendor = function() return 1 end,
             vendorBuy = function() return nil end, name = function(id) return id == 14047 and "Paño rúnico" or nil end,
             me = {name = "Javi", level = 60, profs = {}}, bags = {}, bank = {}, recipes = {}, guild = {}}
  for k, v in pairs(over or {}) do c[k] = v end
  c.spec = {T = ET, now = ENOW, hints = true, budget = 2000000, items = items, books = {}}
  return c
end
local function specRows(r, kind)
  local out = {}
  for _, x in ipairs(r.sections.spec) do if not kind or x.kind == kind then out[#out + 1] = x end end
  return out
end
local function mate(id, values, point, first) return {id = id, records = records(values, first), point = point} end

test("Sin compañeros aceptados el motor da exactamente lo de antes (nil, lista vacía o todos fuera de rango)", function()
  local base = {records = records(WORKED), vendor = 100, dep = 50, cat = "tela",
                point = {t = ENOW - 600, lo = 6000, qty = 300, qty5 = 40}}
  local function result(entry) return dump(Engine.Suggest(ectx("spec", {[14047] = entry}))) end
  local function with(extra) local e = copy(base); for k, v in pairs(extra) do e[k] = v end; return e end
  local plain = result(base)
  eq(result(with({guild = {}, guildKey = {}})), plain, "lista vacía")
  local far = {}
  for i, v in ipairs(WORKED) do far[i] = v * 3 end
  eq(result(with({guild = {mate("aaaaaaaa", far, {t = ENOW - 60, lo = 100, qty = 9, qty5 = 9})}, guildKey = {}})), plain,
    "un compañero con precios del triple se descarta (y su punto también)")
  eq(dump(Engine.SpecLines(ectx("spec", {[14047] = with({guild = {mate("aaaaaaaa", far)}, guildKey = {}})}), 14047)),
    dump(Engine.SpecLines(ectx("spec", {[14047] = base}), 14047)), "descripción igual")
end)

test("Con compañeros: más días antes, regla de la nube (Fiable pide 2 personas) y el filtro de cordura", function()
  -- Tú solo tienes 7 días: aún aprendiendo. Con los 7 de un compañero, 14 días y fiable (2 personas).
  local mine = {false, false, false, false, false, false, false, 10000, 10100, 9900, 10000, 10200, 9800, 10000}
  local theirs = {9600, 9800, 10000, 10200, 10400, 9900, 10100}
  local alone = Engine.Suggest(ectx("spec", {[14047] = {records = records(mine), cat = "tela"}}))
  assert(has(alone.spec.text, "Con precio normal: 1 de 1 objeto vigilado (0 fiables)"), alone.spec.text)
  assert(not has(alone.spec.text, "Precios compartidos"), alone.spec.text)
  local merged = Engine.SpecLines(ectx("spec", {[14047] = {records = records(mine), cat = "tela",
    guild = {mate("47da174e", theirs, nil, ET - 14)}, guildKey = {}}}), 14047)
  local r = Engine.Suggest(ectx("spec", {[14047] = {records = records(mine), cat = "tela", guild = {mate("47da174e", theirs, nil, ET - 14)}, guildKey = {}}}))
  assert(has(r.spec.text, "Precios compartidos por la hermandad: 1 compañero en 14 días."), r.spec.text)
  assert(has(r.spec.text, "Con precio normal: 1 de 1 objeto vigilado (1 fiable)"), r.spec.text)
  assert(merged and merged[1].left == "Normal (14 d)", "precio normal con lo del compañero")
  -- Solo con lo de un compañero nunca es «Fiable»: la nube pide 2 personas.
  local onlyMate = Engine.Suggest(ectx("spec", {[14047] = {records = {}, cat = "tela", guild = {mate("47da174e", WORKED)}, guildKey = {}}}))
  assert(has(onlyMate.spec.text, "(0 fiables)"), onlyMate.spec.text)
  -- Lo mismo con tus 14 días propios sí es fiable (y sin compañeros, como siempre).
  local own = Engine.Suggest(ectx("spec", {[14047] = {records = records(WORKED), cat = "tela"}}))
  assert(has(own.spec.text, "(1 fiable)"), own.spec.text)
  -- Filtro de cordura: un compañero con la mitad de tus precios justo vale; con menos, no.
  local half, low = {}, {}
  for i, v in ipairs(WORKED) do half[i] = math.ceil(v / 2); low[i] = math.floor(v * 4 / 10) end
  local function mates(values)
    local res = Engine.Suggest(ectx("spec", {[14047] = {records = records(WORKED), cat = "tela", guild = {mate("bbbbbbbb", values)}, guildKey = {}}}))
    return has(res.spec.text, "Precios compartidos por la hermandad")
  end
  eq(mates(half), true, "mitad: dentro"); eq(mates(low), false, "40 %: fuera")
end)

test("Precio de un compañero: «Un compañero lo vio hace 10 min.» y su chollo es un «Posible chollo» que hay que mirar", function()
  local entry = {records = records(WORKED), vendor = 100, dep = 50, cat = "tela",
                 guild = {mate("47da174e", WORKED, {t = ENOW - 600, lo = 6000, qty = 300, qty5 = 40})}, guildKey = {}}
  local r = Engine.Suggest(ectx("spec", {[14047] = entry}))
  eq(#specRows(r, "flip"), 0, "nunca una compra directa con el precio de otro")
  local check = specRows(r, "check")[1]
  assert(check, "posible chollo")
  eq(check.title, "Posible chollo: Paño rúnico a 60p (40 % por debajo de lo normal)")
  eq(check.detail, "Un compañero lo vio a 60p hace 10 min: ábrelo en la pestaña Comprar de la subasta y el addon calculará "
    .. "la compra con lo que hay a la venta. Fiable · 14 días · variación ±3 % · 2 miembros.")
  eq(check.value, 0); eq(check.shopping[1].id, 14047); eq(check.shopping[1].count, 1)
  assert(not has(check.detail, "47da174e"), "sin código")
  local lines = Engine.SpecLines(ectx("spec", {[14047] = entry}), 14047)
  eq(lines[2].left, "Posible chollo: un compañero lo vio a 60p hace 10 min; ábrelo en la pestaña Comprar para confirmarlo")
  -- Tu escaneo (más nuevo o a la misma hora) manda: entonces sí es un chollo normal.
  entry.point = {t = ENOW - 600, lo = 6000, qty = 300, qty5 = 40}
  entry.guildKey = {}
  local mine = Engine.Suggest(ectx("spec", {[14047] = entry}))
  eq(#specRows(mine, "flip"), 1, "a la misma hora, el tuyo")
  assert(has(specRows(mine, "flip")[1].detail, "Precio de hace 10 min."), specRows(mine, "flip")[1].detail)
  -- Vende ahora con el precio de un compañero: «Un compañero lo vio hace 5 min.».
  local high = {records = records(WORKED), vendor = 100, cat = "tela",
                guild = {mate("47da174e", WORKED, {t = ENOW - 300, lo = 14000, qty = 300, qty5 = 40})}, guildKey = {}}
  local sell = Engine.Suggest(ectx("spec", {[14047] = high}, {bags = {[14047] = {count = 10, quality = 1}}}))
  local spike = specRows(sell, "spike")[1]
  assert(spike and has(spike.detail, "Un compañero lo vio hace 5 min."), spike and spike.detail)
  -- Un punto de un compañero de hace más de 2 h ya no es precio actual.
  local stale = {records = records(WORKED), vendor = 100, cat = "tela",
                 guild = {mate("47da174e", WORKED, {t = ENOW - 3 * 3600, lo = 6000, qty = 300, qty5 = 40})}, guildKey = {}}
  eq(#specRows(Engine.Suggest(ectx("spec", {[14047] = stale})), "check"), 0, "viejo")
end)

test("Core: los objetos que solo tienen los compañeros también llegan al motor, por tandas y sin bloquear", function()
  local jusep = net.jusep
  current = jusep
  local items = jusep.Relay.GuildItems(MARKET)
  run(30)
  current = jusep
  items = jusep.Relay.GuildItems(MARKET)
  assert(items[13446] and #items[13446].list >= 1, "13446 (solo de Ána) decodificado")
  local ctx = jusep.ns.Core.Context()
  local entry = ctx.spec and ctx.spec.items[13446]
  assert(entry and #entry.records == 0 and entry.guild and entry.guildKey, "con tus días vacíos")
  eq(entry.cat, "pocion")
  local again = jusep.ns.Core.Context().spec.items[13446]
  eq(again.guildKey, entry.guildKey, "la misma clave mientras no cambie nada")
  current = nil
end)

---------------------------------------------------------------------------
-- 10. Sin tirones: cada tanda de 2 ms como mucho
---------------------------------------------------------------------------
test("Recibir 3 escaneos de 114 objetos va por tandas de menos de 2 ms", function()
  _G.debugprofilestop = function() return os.clock() * 1000 end
  local fresh = newClient({name = "Rx3"})
  login(fresh, 30)
  -- Se mide el trabajo del addon: el recolector de basura de este proceso (con una docena de copias del addon
  -- cargadas) se para mientras tanto; en el juego ese trabajo es de todos los addons a la vez.
  collectgarbage("collect"); collectgarbage("stop")
  tickLog = {owner = fresh, max = 0, n = 0}
  for i, who in ipairs({"Uno", "Dos", "Tres"}) do
    for _, m in ipairs(R.PackP3(i, TAG, unix() - 30, LUCJA.items)) do inject(fresh, m, "GUILD", who .. "-GritodeGuerra") end
  end
  current = fresh
  fresh.Relay.GuildItems(MARKET)
  current = nil
  run(60)
  local log = tickLog
  tickLog = nil
  collectgarbage("restart")
  _G.debugprofilestop = nil
  current = fresh
  local n = 0
  for _ in pairs(hist(fresh).markets[MARKET].obs) do n = n + 1 end
  eq(n, 3, "los tres aplicados")
  assert(log.max < TICK_LIMIT_MS, string.format("tanda más larga %.2f ms", log.max))
  realPrint(string.format("  3 escaneos de 114 objetos: %d tandas, la más larga %.2f ms", log.n, log.max))
  current = nil
  logout(fresh)
end)

---------------------------------------------------------------------------
-- 11. Hermandades grandes, instancias, actualizar con solo un /reload y compartir off a medias
---------------------------------------------------------------------------
-- Otra hermandad del mismo reino: lo de aquí no llega a los clientes de las pruebas anteriores.
local OTHER = "Los de Siempre"
local FIXED_IDS = unit.History.FixedIDs()
-- Un escaneo de los 114 objetos de la lista fija con precios de 6 cifras: 9 partes por escaneo.
local function wholeScan(seed)
  local items = {}
  for i, id in ipairs(FIXED_IDS) do items[id] = {60000 + ((i * 7919 + seed * 104729) % 900000), 1000 + (i * 37) % 4000, 100 + i % 50} end
  return items
end
-- OroHermandadDB con estos compañeros ya conocidos (sin el aviso de compañero nuevo).
local function knownDB(names)
  local db = {guilds = {}}
  local members = {}
  for _, n in ipairs(names) do members[n] = {addon = {level = 60, seen = unix(), profs = {}, crafts = {}}} end
  db.guilds[C.guildRealm .. "/" .. OTHER] = {members = members}
  return db
end
local function member(name, names, o)
  o = o or {}
  o.name, o.guild, o.members, o.db = name, OTHER, false, o.db or knownDB(names)
  return newClient(o)
end
local function hashOf(c, of) local prev = current; current = c; local h = c.Relay.Hash(of .. "-" .. C.guildRealm); current = prev; return h end
local function scansAt(c, h)
  local entry = obsOf(c, h)
  return entry and #c.History.DecodeTimes(entry.s) or 0
end

test("Puesta al día con 12 compañeros a la vez: llegan los 24 escaneos (48 series abiertas, se va la de menos partes)", function()
  local names = {"Subidora"}
  for i = 1, 12 do names[#names + 1] = "Socio" .. string.char(96 + i) end
  local mates = {}
  for i = 2, #names do mates[#mates + 1] = member(names[i], names); login(mates[#mates], 2) end
  run(60)
  for round = 1, 2 do
    for i, m in ipairs(mates) do scan(m, wholeScan(i * 10 + round)); run(40) end
    run(1000)
  end
  local outs = 0
  for _, m in ipairs(mates) do outs = outs + #m.CharDB.relay.out end
  eq(outs, 24, "2 escaneos en cada buzón")
  run(3600)
  local up = member("Subidora", names, {marker = true})
  login(up, 25)
  quiet("12 respuestas a la vez", function() run(400) end)
  local got, parts = 0, 0
  for _, m in ipairs(mates) do
    got = got + scansAt(up, hashOf(up, m.name))
    parts = parts + #sentBy(m, "^P3|", "WHISPER")
  end
  eq(got, 24, "los 24 escaneos")
  assert(parts >= 24 * 7 and parts <= 24 * 12, "un susurro por parte: " .. parts)
  current = up
  assert(up.Relay.Stats().lastReason ~= "demasiadas series", "sin series descartadas por llenas")
  current = nil
  logout(up)
  for _, m in ipairs(mates) do logout(m) end
end)

test("Respuesta llena: el resto llega solo, sin huecos y sin /oro sync (4 escaneos de 9 partes en dos días)", function()
  local names = {"Pidiente", "Nadia"}
  local nadia = member("Nadia", names)
  login(nadia, 30)
  -- Dos escaneos un día y dos al siguiente, sin nadie con el subidor conectado.
  local day1 = Spec.DayIndex(unix())
  scan(nadia, wholeScan(1)); run(1200); scan(nadia, wholeScan(2)); run(1200)
  while Spec.DayIndex(unix()) == day1 do run(1800) end
  local day2 = Spec.DayIndex(unix())
  run(600)
  scan(nadia, wholeScan(3)); run(1200); scan(nadia, wholeScan(4)); run(1200)
  eq(#nadia.CharDB.relay.out, 4, "4 en el buzón")
  for _, scanOut in ipairs(nadia.CharDB.relay.out) do
    local items = {}
    for tok in scanOut.items:gmatch("[^,]+") do items[#items + 1] = tok end
    eq(#R.PackP3(1, TAG, scanOut.t, (function()
      local list = {}
      for _, tok in ipairs(items) do
        local a, b, c2, d = tok:match("^(%w+):(%w+):(%w+):(%w+)$")
        list[#list + 1] = {R.D36(a, 0, 2147483647), R.D36(b, 0, 2147483647), R.D36(c2, 0, 2147483647), R.D36(d, 0, 2147483647)}
      end
      return list
    end)()), 9, "9 partes por escaneo")
  end
  run(3600)
  local up = member("Pidiente", names, {marker = true})
  login(up, 25)
  quiet("respuesta llena", function() run(300) end)
  local h = hashOf(up, "Nadia")
  eq(scansAt(up, h), 2, "la primera respuesta: los 2 más viejos (24 mensajes como mucho)")
  local first = Spec.DecodeDays(obsOf(up, h).items[FIXED_IDS[1]].d)
  eq(#first, 1, "un día"); eq(first[1].d, day1, "el más viejo")
  quiet("lo que faltaba", function() run(900) end)
  eq(scansAt(up, h), 4, "pasados 11 min, el resto, sin /oro sync")
  local days = Spec.DecodeDays(obsOf(up, h).items[FIXED_IDS[1]].d)
  eq(#days, 2, "los dos días"); eq(days[1].d, day1); eq(days[1].scans, 2); eq(days[2].d, day2); eq(days[2].scans, 2)
  -- La cadena se acaba sola: una petición más, sin nada nuevo que responder, y ya no se pide más.
  run(3600)
  local asks = #sentBy(up, "^Q3|", "GUILD")
  assert(asks >= 2 and asks <= 3, "peticiones: " .. asks)
  eq(#sentBy(nadia, "^P3|", "WHISPER"), 4 * 9, "cada escaneo, una vez")
  run(3600)
  eq(#sentBy(up, "^Q3|", "GUILD"), asks, "y no pide más")
  -- Por susurro (un compañero que vuelve a entrar): la petición solo a él también sigue hasta tenerlo todo.
  up.online = false
  for i = 5, 7 do scan(nadia, wholeScan(i)); run(1000) end
  local savedN = logout(nadia)
  up.online = true
  run(1900)
  nadia = member("Nadia", names, {db = savedN.db, cdb = savedN.cdb, hist = savedN.hist})
  login(nadia, 10)
  quiet("por susurro, lo que faltaba", function() run(1200) end)
  eq(scansAt(up, h), 7, "los 3 nuevos, en dos peticiones por susurro")
  local targeted = sentBy(up, "^Q3|", "WHISPER")
  assert(#targeted >= 2, "dos peticiones por susurro: " .. #targeted)
  for _, e in ipairs(targeted) do eq(e.target, "Nadia-" .. C.guildRealm) end
  logout(up); logout(nadia)
end)

test("El subidor entra en una mazmorra: la petición espera a salir (más de 5 min) y lastAsk cuenta desde que sale", function()
  local names = {"Ulises", "Olga"}
  local olga = member("Olga", names)
  login(olga, 30)
  scan(olga, {[2772] = {150, 300, 40}, [13446] = {2350, 55, 20}})
  run(60)
  local up = member("Ulises", names, {marker = true})
  up.instance = "party"
  login(up, 30)
  quiet("en la mazmorra", function() run(8 * 60) end)
  eq(#sentBy(up, "^Q3|"), 0, "nada en la mazmorra")
  eq(up.DB.relay.lastAsk, nil, "sin lastAsk mientras no sale")
  current = up
  eq(up.Relay.Ask(), "sent", "ya está en camino (no se duplica)")
  current = nil
  up.instance = nil
  local left = unix()
  quiet("al salir", function() run(120) end)
  local asks = sentBy(up, "^Q3|", "GUILD")
  eq(#asks, 1, "sale al dejar la mazmorra, una vez")
  assert(up.DB.relay.lastAsk >= left and up.DB.relay.lastAsk <= left + 60, "lastAsk al salir: " .. tostring(up.DB.relay.lastAsk))
  eq(scansAt(up, hashOf(up, "Olga")), 1, "y llega lo de Olga")
  -- Si vuelve a quedarse bloqueada en la cola más de 5 min (combate largo justo al salir), se prepara otra vez.
  up.DB.relay.lastAsk = nil
  current = up
  up.combat = true
  eq(up.Relay.Ask(), "sent")
  current = nil
  run(400)
  eq(#sentBy(up, "^Q3|", "GUILD"), 1, "en combate no sale")
  up.combat = false
  run(60)
  eq(#sentBy(up, "^Q3|", "GUILD"), 2, "sale después")
  logout(up); logout(olga)
end)

test("/oro compartir off quita de la cola los escaneos tuyos que aún no habían salido", function()
  local names = {"Fabio", "Gema"}
  local gema = member("Gema", names)
  login(gema, 30)
  local fabio = member("Fabio", names)
  login(fabio, 30)
  fabio.instance = "party" -- termina el escaneo y entra directo en una mazmorra
  scan(fabio, {[2772] = {150, 300, 40}, [13446] = {2350, 55, 20}})
  current = fabio
  eq(fabio.Guild.RelayQueued(), 1, "su P3 espera en la cola")
  current = nil
  slash(fabio, "compartir off")
  current = fabio
  eq(fabio.Guild.RelayQueued(), 0, "fuera de la cola")
  current = nil
  run(600)
  fabio.instance = nil
  run(300)
  eq(#sentBy(fabio, "^P3|"), 0, "no sale nada tras desactivarlo")
  eq(obsOf(gema, hashOf(gema, "Fabio")), nil, "Gema no lo guarda")
  -- Una serie a medias: lo que ya salió caduca en quien recibe como serie incompleta.
  slash(fabio, "compartir on")
  run(1000)
  scan(fabio, wholeScan(9))
  run(2.5) -- salen las primeras partes
  local sent = #sentBy(fabio, "^P3|", "GUILD")
  assert(sent >= 1 and sent < 9, "a medias: " .. sent)
  slash(fabio, "compartir off")
  run(300)
  eq(#sentBy(fabio, "^P3|", "GUILD"), sent, "el resto no sale")
  eq(obsOf(gema, hashOf(gema, "Fabio")), nil, "y nadie lo aplica")
  logout(fabio); logout(gema)
end)

test("Actualizado con solo un /reload (sin Relay.lua): todo lo demás funciona, sin errores ni nada en el chat", function()
  local names = {"Recarga", "Gema2"}
  local before = #Stub.printed
  local c = member("Recarga", names, {skip = {["Relay.lua"] = true}})
  eq(c.ns.Relay, nil, "sin Relay.lua")
  login(c, 40)
  for i = before + 1, #Stub.printed do assert(not has(Stub.printed[i], "error"), Stub.printed[i]) end
  scan(c, {[2772] = {150, 300, 40}})
  run(30)
  Stub.printed = {}
  slash(c, "") -- abre la ventana: las sugerencias se calculan
  run(5)
  slash(c, "estado")
  slash(c, "sondeo")
  slash(c, "sync")
  slash(c, "compartir off")
  slash(c, "subidor on")
  local text = table.concat(Stub.printed, "\n")
  assert(not has(text, "error"), text)
  assert(has(text, "Precios compartidos: aún no están cargados: tras actualizar el addon, sal del juego del todo"), text)
  assert(has(text, "los precios compartidos aún no están cargados: tras actualizar el addon"), text)
  assert(has(text, "versión " .. c.ns.Core.VERSION), "/oro estado funciona")
  current = c
  assert(c.ns.Core.Context(), "el contexto del motor se arma")
  current = nil
  logout(c)
end)

test("Ningún error interno ni nada de precios enviado con los mensajes restringidos en toda la sesión", function()
  eq(#net.violations, 0, "violaciones")
  for _, c in ipairs(net.clients) do
    if c.Relay then eq(c.Relay.lastError, nil, c.name); eq(c.Guild.relayError, nil, c.name) end
  end
  for _, line in ipairs(Stub.printed) do assert(not has(line, "error"), line) end
end)

realPrint(string.format("precios compartidos: %d pruebas correctas, %d fallidas", passed, failed))
os.exit(failed == 0 and 0 or 1)

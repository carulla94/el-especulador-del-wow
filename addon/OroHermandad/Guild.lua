-- Oro de Hermandad: comparte profesiones y recetas rentables con la hermandad (mensajes de addon)
-- y lee las profesiones del roster de la hermandad para quien no tenga el addon.
-- Solo se comparte: nivel, profesiones con su nivel y hasta 8 recetas con beneficio. Nada de bolsas ni oro.
local _, ns = ...
local Data = ns.Data
local Guild = {}
ns.Guild = Guild

Guild.PREFIX = "OroHerm"
local PROTOCOL = "2"
local MAX_CRAFTS = 8
local STALE_DAYS = 30
local ANNOUNCE_COOLDOWN = 60   -- segundos entre anuncios completos a la hermandad
local RESEND_UNCHANGED = 1800  -- los mismos datos no se vuelven a anunciar antes de esto (salvo si se fuerza)
local REPLY_COOLDOWN = 60      -- segundos entre respuestas a la misma persona
local REQUEST_WINDOW = 120     -- aceptamos susurros de respuesta durante este tiempo tras salir la petición
local REPLY_TTL = REQUEST_WINDOW - 20 -- una respuesta que no ha salido en este tiempo ya no se aceptaría
local MAX_WHISPER_QUEUE = 2 * (MAX_CRAFTS + 1) -- con más susurros en cola se responde con un anuncio a la hermandad
local LOCKDOWN_POLL = 10       -- con el chat bloqueado (mazmorra, banda, encuentro) se espera sin gastar intentos
local MAX_QTY = 1000           -- unidades por receta que aceptamos (munición: 200 por tanda)
local MAX_QTY_V020 = 100       -- la versión 0.2.0 rechaza más y perdería la serie entera: no se envían
local NOGUILD = "_sinhermandad"

local state = {
  db = nil, getSelf = nil, key = nil, settled = false, legacy = nil, importedKey = nil, adopted = {},
  queue = {}, sending = false, owed = false,
  pending = {}, lastAnnounce = -math.huge, announceScheduled = false, forceNext = false, lastSig = nil,
  repliedTo = {}, requestedAt = -math.huge, seq = 0,
}

local SEND = type(Enum) == "table" and Enum.SendAddonMessageResult or nil
local SUCCESS = (SEND and SEND.Success) or 0
local LOCKDOWN = (SEND and SEND.AddOnMessageLockdown) or 11
local RETRY = {[(SEND and SEND.AddonMessageThrottle) or 3] = true, [(SEND and SEND.ChannelThrottle) or 8] = true}

local function split(text, sep)
  local out = {}
  for piece in (text .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
  return out
end

local function clock()
  if type(GetTime) == "function" then return GetTime() end
  return time and time() or 0
end
local function now() return time and time() or 0 end

local function after(seconds, fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then C_Timer.After(seconds, fn) end
end

-- Entero estricto dentro de un rango (rechaza nan, inf, hex, decimales y negativos).
local function int(text, low, high)
  if type(text) ~= "string" or not text:match("^%d+$") or #text > 10 then return nil end
  local n = tonumber(text)
  if not n or n < low or n > high then return nil end
  return n
end

local function myName()
  return type(UnitName) == "function" and UnitName("player") or nil
end

-- En mazmorras, bandas y encuentros el cliente devuelve "valores secretos": no se puede operar con ellos.
local function secret(value)
  if type(value) == "nil" or type(issecretvalue) ~= "function" then return false end
  local ok, isSecret = pcall(issecretvalue, value)
  return not ok or isSecret == true
end
local function secretTable(t)
  if secret(t) then return true end
  if type(issecrettable) ~= "function" then return false end
  local ok, isSecret = pcall(issecrettable, t)
  return not ok or isSecret == true
end

local function chatLocked()
  if not (type(C_ChatInfo) == "table" and type(C_ChatInfo.InChatMessagingLockdown) == "function") then return false end
  local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
  return ok and locked == true
end

---------------------------------------------------------------------------
-- Nombres
---------------------------------------------------------------------------
-- Mayúsculas y minúsculas en UTF-8: ASCII, Latin-1 (À-Þ), Latin extendido A (Ā-ž) y cirílico.
local function shiftCase(cp, up)
  local d = 0
  if (cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7) or (cp >= 0x410 and cp <= 0x42F) then d = up and 0 or 32
  elseif (cp >= 0xE0 and cp <= 0xFE and cp ~= 0xF7) or (cp >= 0x430 and cp <= 0x44F) then d = up and -32 or 0
  elseif cp >= 0x400 and cp <= 0x40F then d = up and 0 or 80
  elseif cp >= 0x450 and cp <= 0x45F then d = up and -80 or 0
  elseif cp == 0xFF then d = up and 0x79 or 0      -- ÿ / Ÿ
  elseif cp == 0x178 then d = up and 0 or -0x79
  elseif (cp >= 0x100 and cp <= 0x12F) or (cp >= 0x132 and cp <= 0x137) or (cp >= 0x14A and cp <= 0x177) then
    d = cp % 2 == 0 and (up and 0 or 1) or (up and -1 or 0)
  elseif (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
    d = cp % 2 == 1 and (up and 0 or 1) or (up and -1 or 0)
  end
  return cp + d
end

local function changeCase(text, up)
  text = text:gsub("[\194-\223][\128-\191]", function(ch)
    local a, b = ch:byte(1, 2)
    local cp = shiftCase((a - 192) * 64 + (b - 128), up)
    return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
  end)
  return (text:gsub("[A-Za-z]", up and string.upper or string.lower))
end

-- Clave sin mayúsculas para comparar nombres (con caché: el roster compara muchos).
local folded = {}
local function fold(text)
  local out = folded[text]
  if not out then out = changeCase(text, false); folded[text] = out end
  return out
end

-- Nombres al estilo del servidor: primera letra en mayúscula, el resto en minúscula y sin tu propio reino.
function Guild.NormalizeName(name)
  if type(name) ~= "string" then return nil end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or #name > 64 then return nil end
  local base, realm = name:match("^([^%-]+)%-(.*)$")
  base = base or name
  if realm then
    realm = realm:gsub("[%s%-]", "")
    local mine = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or nil
    if realm == "" or (type(mine) == "string" and fold((realm:gsub("'", ""))) == fold((mine:gsub("[%s%-']", "")))) then
      realm = nil
    end
  end
  local first, rest = base:match("^([%z\1-\127\194-\244][\128-\191]*)(.*)$")
  if not first then return nil end
  local out = changeCase(first, true) .. changeCase(rest, false)
  if realm then out = out .. "-" .. realm end
  return out
end

local function shortName(sender)
  if type(sender) ~= "string" then return nil end
  if type(Ambiguate) == "function" then return Ambiguate(sender, "none") end
  return (sender:match("^([^%-]+)")) or sender
end

---------------------------------------------------------------------------
-- Almacén por hermandad
---------------------------------------------------------------------------
local function findName(members, name)
  if members[name] then return name end
  local target = fold(name)
  for existing in pairs(members) do
    if fold(existing) == target then return existing end
  end
  return nil
end

-- La 0.2.0 guardaba los amigos a mano tal como se escribían, también con tu reino («Ana-Forever»): salían duplicados
-- junto a «Ana» y no se podían quitar. Esas claves pasan a la forma normal y lo manual se junta con lo que ya hubiera,
-- sin pisarlo. Solo las que no traen datos del addon ni del roster (esas ya llegan con el nombre del servidor).
local function adoptLegacyNames(members)
  local moves = {}
  for name, friend in pairs(members) do
    local clean = Guild.NormalizeName(name)
    if clean and clean ~= name and type(friend) == "table" and type(friend.manual) == "table"
       and not friend.addon and not friend.roster then
      moves[#moves + 1] = {from = name, to = clean}
    end
  end
  for _, move in ipairs(moves) do
    local old = members[move.from]
    members[move.from] = nil
    local profs = type(old.manual.profs) == "table" and old.manual.profs or {}
    if next(profs) then
      local key = findName(members, move.to) or move.to
      local target = type(members[key]) == "table" and members[key] or {}
      members[key] = target
      target.manual = type(target.manual) == "table" and target.manual or {}
      target.manual.profs = type(target.manual.profs) == "table" and target.manual.profs or {}
      for prof, rank in pairs(profs) do
        if target.manual.profs[prof] == nil then target.manual.profs[prof] = rank end
      end
    end
  end
end

-- Miembros de la hermandad actual; nil mientras no se sabe cuál es (nada se guarda en un sitio equivocado).
local function store()
  local db = state.db
  if not db then return nil end
  local key = state.key
  if not key or (key == NOGUILD and not state.settled) then key = Guild.UpdateKey() end -- al entrar puede tardar
  if not key then return nil end
  local bucket = type(db.guilds[key]) == "table" and db.guilds[key] or {}
  bucket.members = type(bucket.members) == "table" and bucket.members or {}
  db.guilds[key] = bucket
  -- Nombres de la 0.2.0, una vez por sesión y hermandad, con tu reino ya legible (el almacén sin hermandad no es de
  -- ningún reino: ahí no se toca nada).
  local realm = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or nil
  if key ~= NOGUILD and not state.adopted[key] and type(realm) == "string" and realm ~= "" then
    state.adopted[key] = true
    adoptLegacyNames(bucket.members)
  end
  return bucket.members
end

-- canonical: el nombre viene del servidor (addon o roster) y manda su grafía si había otra guardada.
local function member(name, create, canonical)
  local members = store()
  if not members or not name then return nil end
  local key = findName(members, name)
  if key and canonical and key ~= name then
    members[name], members[key] = members[key], nil
    state.pending[name], state.pending[key] = state.pending[key], nil
    key = name
  end
  if not key then
    if not create then return nil end
    key = name
    members[key] = {}
  end
  return members[key], key
end

local function sameProfs(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- La 0.1 guardaba todo en db.guild, sin separar por hermandad. Sus amigos a mano pasan a la hermandad actual
-- cuando se conoce de verdad; hasta entonces db.guild se queda en el archivo.
local function migrateLegacy()
  local legacy, key = state.legacy, state.key
  if not legacy or not key or (key == NOGUILD and not state.settled) then return end
  state.legacy = nil
  for name, old in pairs(legacy) do
    local clean = Guild.NormalizeName(name)
    if clean and type(old) == "table" and old.manual and type(old.profs) == "table" then
      local profs = {}
      for prof, value in pairs(old.profs) do
        local rank = tonumber(value)
        if Data.PROFESSIONS[prof] and rank and rank == rank then profs[prof] = math.max(1, math.min(450, math.floor(rank))) end
      end
      local friend = next(profs) and member(clean, true)
      if friend then
        friend.manual = type(friend.manual) == "table" and friend.manual or {}
        friend.manual.profs = type(friend.manual.profs) == "table" and friend.manual.profs or {}
        for prof, rank in pairs(profs) do friend.manual.profs[prof] = friend.manual.profs[prof] or rank end
      end
    end
  end
  if state.db then state.db.guild = nil end
end

-- Clave de la hermandad actual (reino normalizado + nombre). nil si estás en una pero aún no ha cargado.
function Guild.UpdateKey()
  local key = NOGUILD
  if type(IsInGuild) == "function" and IsInGuild() and type(GetGuildInfo) == "function" then
    local ok, guildName = pcall(GetGuildInfo, "player")
    if not ok or secret(guildName) or type(guildName) ~= "string" or guildName == "" then
      if state.key == NOGUILD then state.key = nil end -- aún no ha cargado: se conserva solo una hermandad ya conocida
      return state.key
    end
    local realm = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or ""
    key = (realm or "") .. "/" .. guildName
    state.settled = true -- con el nombre de la hermandad legible, la identidad es fiable
  end
  state.key = key
  migrateLegacy()
  return key
end

-- Core la llama unos segundos después de entrar al mundo: IsInGuild() ya es fiable aunque dé false.
function Guild.Settle()
  state.settled = true
  return Guild.UpdateKey()
end

-- Clave de una hermandad real ya identificada, o nil. Lo que llega de la hermandad solo se guarda con ella.
local function guildKey()
  local key = state.key
  if not key or key == NOGUILD then key = Guild.UpdateKey() end
  if key == NOGUILD then return nil end
  return key
end

---------------------------------------------------------------------------
-- Envío con cola, reintento y límite de ritmo
---------------------------------------------------------------------------
-- "sent", "retry" (el servidor frena), "lockdown" (chat bloqueado: se espera) o "fail".
local function rawSend(entry)
  if not (type(C_ChatInfo) == "table" and type(C_ChatInfo.SendAddonMessage) == "function") then return "fail" end
  if entry.channel == "GUILD" and not (type(IsInGuild) == "function" and IsInGuild()) then return "fail" end
  if chatLocked() then return "lockdown" end
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, Guild.PREFIX, entry.msg, entry.channel, entry.target)
  if not ok then return "fail" end
  if result == LOCKDOWN then return "lockdown" end
  if RETRY[result] then return "retry" end
  return (result == nil or result == true or result == SUCCESS) and "sent" or "fail"
end

local function pump()
  local entry = state.queue[1]
  -- Respuestas por susurro que llegarían cuando quien pidió ya no las acepta: fuera, y luego va un anuncio general.
  while entry and entry.channel == "WHISPER" and not (entry.series and entry.series.started)
        and clock() - entry.queuedAt > REPLY_TTL do
    table.remove(state.queue, 1)
    state.owed = true
    entry = state.queue[1]
  end
  if not entry then
    state.sending = false
    if state.owed then state.owed = false; Guild.Announce(true) end
    return
  end
  local status = rawSend(entry)
  if status == "lockdown" then after(LOCKDOWN_POLL, pump); return end -- no gasta intentos
  entry.tries = (entry.tries or 0) + 1
  if status == "retry" and entry.tries < 6 then after(5, pump); return end
  table.remove(state.queue, 1)
  if status == "sent" then
    if entry.series then entry.series.started = true end
    if entry.kind == "request" then state.requestedAt = clock() end -- la ventana de respuestas cuenta desde aquí
  elseif entry.series then
    -- Sin esta parte la serie no se completa: se quita el resto y, si fue por el ritmo del servidor, se repite luego.
    local keep = {}
    for _, other in ipairs(state.queue) do if other.series ~= entry.series then keep[#keep + 1] = other end end
    state.queue = keep
    if status == "retry" then state.owed = true end
  end
  after(1.2, pump) -- el servidor admite ráfagas de 10 y luego 1 por segundo
end

local function enqueue(msg, channel, target, kind, series)
  if type(msg) ~= "string" or #msg > 250 then return end
  state.queue[#state.queue + 1] = {msg = msg, channel = channel or "GUILD", target = target, kind = kind,
                                   series = series, queuedAt = clock()}
  if not state.sending then
    state.sending = true
    after(0.2, pump)
  end
end

---------------------------------------------------------------------------
-- Codificación
---------------------------------------------------------------------------
function Guild.EncodeHello(level, profs, craftCount, seq)
  local parts, keys = {}, {}
  for key in pairs(profs or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local rank = tonumber(profs[key])
    if rank and Data.PROFESSIONS[key] then parts[#parts + 1] = key .. "=" .. math.floor(rank) end
  end
  return string.format("H%s|%d|%s|%d|%d", PROTOCOL, math.floor(tonumber(level) or 0), table.concat(parts, ","),
    craftCount or 0, seq or 0)
end

function Guild.EncodeCraft(seq, index, total, craft)
  local reagents = {}
  for _, r in ipairs(craft.reagents or {}) do reagents[#reagents + 1] = r[1] .. ":" .. r[2] end
  return string.format("C%s|%d|%d|%d|%d|%d|%d|%s", PROTOCOL, seq, index, total, craft.product, craft.qty or 1,
    math.floor(craft.profit or 0), table.concat(reagents, ";"))
end

local function parseProfs(text)
  local profs = {}
  if not text or text == "" then return profs end
  local count = 0
  for _, pair in ipairs(split(text, ",")) do
    local key, value = pair:match("^(%a+)=(%d+)$")
    local rank = value and int(value, 1, 450)
    if key and rank and Data.PROFESSIONS[key] then
      profs[key] = rank
      count = count + 1
      if count >= 12 then break end
    end
  end
  return profs
end

local function parseCraft(fields, maxQty)
  local product, qty, profit = int(fields[5], 1, 2 ^ 31), int(fields[6], 1, maxQty or MAX_QTY), int(fields[7], 1, 1e9)
  if not (product and qty and profit) then return nil end
  local reagents = {}
  for _, pair in ipairs(split(fields[8] or "", ";")) do
    local id, count = pair:match("^(%d+):(%d+)$")
    id, count = id and int(id, 1, 2 ^ 31), count and int(count, 1, 1000)
    if not (id and count) then return nil end
    reagents[#reagents + 1] = {id, count}
  end
  if #reagents == 0 or #reagents > 8 then return nil end
  return {product = product, qty = qty, profit = profit, reagents = reagents}
end

-- Solo se envían recetas que cualquier versión acepta (una parte rechazada deja la serie sin completar).
local function sendable(craft)
  local ok, msg = pcall(Guild.EncodeCraft, 1, 1, 1, craft)
  return ok and #msg <= 250 and parseCraft(split(msg, "|"), MAX_QTY_V020) ~= nil
end

local function craftsText(list)
  local parts = {}
  for i, craft in ipairs(type(list) == "table" and list or {}) do
    local ok, msg = pcall(Guild.EncodeCraft, 0, i, 0, craft)
    parts[i] = ok and msg or "?"
  end
  return table.concat(parts, "\n")
end

-- Procesa un mensaje ya validado de canal. Devuelve true si cambió algo de la hermandad (y si es alguien nuevo).
function Guild.Handle(text, sender, channel)
  if not state.db or type(text) ~= "string" or #text > 255 then return false end
  local name = shortName(sender)
  if not name or name == myName() then return false end
  local fields = split(text, "|")
  local kind = fields[1]
  if kind == "R" .. PROTOCOL then
    if channel == "GUILD" then Guild.Reply(sender) end
    return false
  elseif kind == "H" .. PROTOCOL then
    local level = int(fields[2], 0, 100)
    local craftCount = int(fields[4], 0, MAX_CRAFTS)
    local seq = int(fields[5], 0, 999)
    if not (level and craftCount and seq) or not guildKey() then return false end
    local friend, key = member(name, true, true)
    if not friend then return false end
    local old, profs = friend.addon, parseProfs(fields[3])
    local fresh = type(old) == "table" and (old.seen or 0) >= now() - STALE_DAYS * 86400
    local changed = not fresh or old.level ~= level or not sameProfs(old.profs, profs)
    friend.addon = {profs = profs, level = level, seen = now(), crafts = fresh and type(old.crafts) == "table" and old.crafts or {}}
    if craftCount == 0 then
      if #friend.addon.crafts > 0 then changed = true end
      friend.addon.crafts = {}
      state.pending[key] = nil
    else
      state.pending[key] = {seq = seq, total = craftCount, parts = {}}
    end
    return changed, old == nil
  elseif kind == "C" .. PROTOCOL then
    local seq, index, total = int(fields[2], 0, 999), int(fields[3], 1, MAX_CRAFTS), int(fields[4], 1, MAX_CRAFTS)
    if not (seq and index and total) or index > total or not guildKey() then return false end
    local friend, key = member(name, false)
    local pending = key and state.pending[key]
    if not (friend and friend.addon and pending and pending.seq == seq and pending.total == total) then return false end
    -- Una receta que no entendemos ocupa su hueco y se descarta: no impide guardar las demás.
    pending.parts[index] = parseCraft(fields) or false
    for i = 1, total do if pending.parts[i] == nil then return false end end
    local crafts = {}
    for i = 1, total do if pending.parts[i] then crafts[#crafts + 1] = pending.parts[i] end end
    local changed = craftsText(friend.addon.crafts) ~= craftsText(crafts)
    friend.addon.crafts = crafts
    friend.addon.seen = now()
    state.pending[key] = nil
    return changed
  end
  return false
end

---------------------------------------------------------------------------
-- API del addon
---------------------------------------------------------------------------
function Guild.Init(db, getSelf)
  state.db, state.getSelf = db, getSelf
  db.guilds = type(db.guilds) == "table" and db.guilds or {}
  -- Formato de la versión 0.1 (sin separar por hermandad): se migra al conocer la hermandad (ver migrateLegacy).
  if type(db.guild) == "table" then state.legacy = db.guild else db.guild = nil end
  if type(C_ChatInfo) == "table" and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, Guild.PREFIX)
  end
  Guild.UpdateKey()
  Guild.Prune()
end

-- Recetas que se comparten: como mucho 8 y solo las que cualquier versión entiende.
local function shareable(me)
  local crafts = {}
  for _, craft in ipairs(type(me.crafts) == "table" and me.crafts or {}) do
    if #crafts < MAX_CRAFTS and sendable(craft) then crafts[#crafts + 1] = craft end
  end
  return crafts
end

local function buildAnnounce(channel, target, me, crafts)
  me = me or (state.getSelf and state.getSelf())
  if not me then return end
  crafts = crafts or shareable(me)
  state.seq = (state.seq + 1) % 1000
  local series = {}
  enqueue(Guild.EncodeHello(me.level, me.profs, #crafts, state.seq), channel, target, "announce", series)
  for i, craft in ipairs(crafts) do
    enqueue(Guild.EncodeCraft(state.seq, i, #crafts, craft), channel, target, "announce", series)
  end
end

local function signature(me, crafts)
  local parts = {tostring(state.key), Guild.EncodeHello(me.level, me.profs, #crafts, 0)}
  for i, craft in ipairs(crafts) do parts[#parts + 1] = Guild.EncodeCraft(0, i, #crafts, craft) end
  return table.concat(parts, "\n")
end

-- Anuncia tus datos a la hermandad. Como mucho una vez por minuto (si se pide antes, se agrupa) y, si nada ha
-- cambiado, no se repite en media hora salvo con force (/oro sync o un anuncio que no llegó a salir).
function Guild.Announce(force)
  if not state.getSelf then return end
  if force then state.forceNext = true end
  local wait = state.lastAnnounce + ANNOUNCE_COOLDOWN - clock()
  if wait > 0 then
    if not state.announceScheduled then
      state.announceScheduled = true
      after(wait, function() state.announceScheduled = false; Guild.Announce() end)
    end
    return
  end
  local me = state.getSelf()
  if not me then return end
  local crafts = shareable(me)
  local sig = signature(me, crafts)
  if not state.forceNext and sig == state.lastSig and clock() - state.lastAnnounce < RESEND_UNCHANGED then return end
  state.forceNext, state.lastSig, state.lastAnnounce = false, sig, clock()
  -- Quita anuncios pendientes a la hermandad (quedarían viejos); conserva peticiones y respuestas.
  local keep = {}
  for _, entry in ipairs(state.queue) do
    if not (entry.kind == "announce" and entry.channel == "GUILD") then keep[#keep + 1] = entry end
  end
  state.queue = keep
  buildAnnounce("GUILD", nil, me, crafts)
end

-- Pide a la hermandad que te envíe sus datos (te responden por susurro).
function Guild.Request()
  if not (type(IsInGuild) == "function" and IsInGuild()) then return end
  state.requestedAt = clock()
  enqueue("R" .. PROTOCOL, "GUILD", nil, "request")
end

-- Responde a una petición solo a quien la hizo, con un mínimo de tiempo entre respuestas.
function Guild.Reply(sender)
  if type(sender) ~= "string" then return end
  local last = state.repliedTo[sender]
  if last and clock() - last < REPLY_COOLDOWN then return end
  state.repliedTo[sender] = clock()
  after(1 + (#sender % 5), function()
    -- La cola se mira al responder, no al recibir la petición: así una oleada de peticiones no se acumula.
    local whispers = 0
    for _, entry in ipairs(state.queue) do
      if entry.kind == "announce" and not (entry.series and entry.series.started)
         and (entry.channel == "GUILD" or entry.target == sender) then
        return -- ya hay en cola un anuncio que también le llega
      end
      if entry.channel == "WHISPER" then whispers = whispers + 1 end
    end
    -- Muchas peticiones a la vez: un anuncio a la hermandad sirve a todos y siempre se acepta.
    if whispers >= MAX_WHISPER_QUEUE then Guild.Announce(true) else buildAnnounce("WHISPER", sender) end
  end)
end

-- Susurros: solo de miembros de tu hermandad (a quienes pedimos los datos).
local function isGuildmate(sender)
  if not (type(IsInGuild) == "function" and IsInGuild()) or not guildKey() then return false end
  local short = shortName(sender)
  if type(C_GuildInfo) == "table" and type(C_GuildInfo.MemberExistsByName) == "function" then
    for _, name in ipairs({short, sender}) do
      local ok, exists = pcall(C_GuildInfo.MemberExistsByName, name)
      if ok and exists == true then return true end
    end
  end
  -- El roster puede no haber cargado aún: vale si ya lo vimos en el roster o anunciándose a la hermandad.
  local friend = member(short, false)
  return friend ~= nil and (friend.roster ~= nil or friend.addon ~= nil)
end

-- Respuesta a una petición nuestra reciente, o las recetas que faltan de una serie ya empezada.
local function expecting(text, sender)
  if clock() - state.requestedAt < REQUEST_WINDOW then return true end
  if text:sub(1, 2) ~= "C" .. PROTOCOL then return false end
  local _, key = member(shortName(sender), false)
  return key ~= nil and state.pending[key] ~= nil
end

function Guild.OnAddonMessage(prefix, text, channel, sender)
  if secret(prefix) or secret(text) or secret(channel) or secret(sender) then return false end
  if prefix ~= Guild.PREFIX or type(text) ~= "string" then return false end
  if channel == "GUILD" then return Guild.Handle(text, sender, channel) end
  if channel == "WHISPER" and expecting(text, sender) and isGuildmate(sender) then
    return Guild.Handle(text, sender, channel)
  end
  return false
end

-- Lee un miembro del roster; error(SECRET) si algún dato llega en secreto.
local SECRET = {}
local function readMember(clubId, memberId)
  if secret(memberId) then error(SECRET) end
  local info = C_Club.GetMemberInfo(clubId, memberId)
  if type(info) ~= "table" then error("sin datos") end
  if secretTable(info) then error(SECRET) end
  if info.isSelf then return nil end
  local name, level = info.name, info.level
  if secret(name) or secret(level) then error(SECRET) end
  if type(name) ~= "string" or name == "" then error("sin nombre") end
  local profs = {}
  for i = 1, 2 do
    local id, rank, profName = info["profession" .. i .. "ID"], info["profession" .. i .. "Rank"], info["profession" .. i .. "Name"]
    if secret(id) or secret(rank) or secret(profName) then error(SECRET) end
    local key = Data.ProfessionKeyByID(id) or Data.ProfessionKey(profName)
    if key and type(rank) == "number" and rank > 0 then profs[key] = math.min(math.floor(rank), 450) end
  end
  if not next(profs) then return nil end
  return {name = shortName(name), profs = profs, level = type(level) == "number" and level or nil}
end

-- Lee el roster entero sin tocar nada guardado: filas y si la lectura fue completa, o nil si no se puede leer.
local function readRoster()
  local clubId = C_Club.GetGuildClubId()
  if type(clubId) == "nil" or secret(clubId) then return nil end
  local ids = C_Club.GetClubMembers(clubId)
  if type(ids) ~= "table" or secretTable(ids) then return nil end
  local rows, total, read = {}, 0, 0
  for _, memberId in ipairs(ids) do
    total = total + 1
    local ok, row = pcall(readMember, clubId, memberId)
    if ok then
      read = read + 1
      if row then rows[#rows + 1] = row end
    elseif row == SECRET then
      return nil
    end
  end
  return rows, total > 0 and read == total
end

-- Importa las profesiones del roster de la hermandad (quien no tenga el addon también aparece).
-- Devuelve cuántos miembros con profesiones se leyeron y si cambió algo de lo guardado.
function Guild.ImportRoster()
  if not state.db or not (type(IsInGuild) == "function" and IsInGuild()) then return 0, false end
  if not (type(C_Club) == "table" and type(C_Club.GetGuildClubId) == "function" and type(C_Club.GetClubMembers) == "function"
          and type(C_Club.GetMemberInfo) == "function") then return 0, false end
  if type(C_TradeSkillUI) == "table" and type(C_TradeSkillUI.IsGuildTradeSkillsEnabled) == "function" then
    local ok, enabled = pcall(C_TradeSkillUI.IsGuildTradeSkillsEnabled)
    if ok and enabled == false then return 0, false end
  end
  -- En mazmorras, bandas y encuentros el roster llega en secreto: no se lee ni se borra nada.
  if chatLocked() then return 0, false end
  local key = guildKey()
  if not key then return 0, false end
  local ok, rows, complete = pcall(readRoster)
  if not ok or not rows then return 0, false end
  local members = store()
  if not members then return 0, false end
  local changed = state.importedKey ~= key
  state.importedKey = key
  local seenNow, imported = {}, 0
  for _, row in ipairs(rows) do
    local friend, name = member(row.name, true, true)
    local old = friend.roster
    if type(old) ~= "table" or old.level ~= row.level or not sameProfs(old.profs, row.profs) then changed = true end
    friend.roster = {profs = row.profs, level = row.level, seen = now()}
    seenNow[name] = true
    imported = imported + 1
  end
  -- Solo con una lectura completa: quien ya no sale en el roster con profesiones pierde esos datos
  -- (no los del addon ni los manuales).
  if complete then
    for name, friend in pairs(members) do
      if friend.roster and not seenNow[name] then friend.roster = nil; changed = true end
      if not friend.roster and not friend.addon and not friend.manual then members[name] = nil end
    end
  end
  return imported, changed
end

function Guild.Prune()
  local db = state.db
  if not db then return end
  local limit = now() - STALE_DAYS * 86400
  for bucket, data in pairs(db.guilds) do
    local members = type(data) == "table" and type(data.members) == "table" and data.members or {}
    for name, friend in pairs(members) do
      -- Sin hermandad solo valen los amigos a mano (la 0.2.0 guardaba aquí datos llegados antes de saber la hermandad).
      if bucket == NOGUILD then friend.addon, friend.roster = nil, nil end
      if friend.addon and (friend.addon.seen or 0) < limit then friend.addon = nil end
      if not friend.addon and not friend.manual and not friend.roster then members[name] = nil end
    end
  end
end

-- Añade o cambia a mano una profesión de alguien. Devuelve el nombre normalizado o nil.
function Guild.SetManual(name, profKey, rank)
  name, rank = Guild.NormalizeName(name), tonumber(rank)
  if not name or not Data.PROFESSIONS[profKey] or not rank or rank ~= rank then return nil end
  local friend, key = member(name, true)
  if not friend then return nil end -- la hermandad aún no ha cargado
  friend.manual = friend.manual or {profs = {}}
  friend.manual.profs[profKey] = math.max(1, math.min(450, math.floor(rank)))
  return key
end

-- Quita a alguien. Devuelve el nombre si existía. Primero se busca tal cual (así se puede quitar una clave antigua
-- como «Ana-Forever») y si no, normalizado.
function Guild.Remove(name)
  local members = store()
  if not members or type(name) ~= "string" then return nil end
  local raw = name:gsub("^%s+", ""):gsub("%s+$", "")
  local key = raw ~= "" and findName(members, raw)
  if not key then
    local clean = Guild.NormalizeName(name)
    key = clean and findName(members, clean)
  end
  if not key then return nil end
  members[key] = nil
  return key
end

-- Vista combinada para el motor: por profesión manda lo que envía el addon, luego lo manual, luego el roster.
function Guild.Members()
  local out = {}
  local limit = now() - STALE_DAYS * 86400
  for name, friend in pairs(store() or {}) do
    local profs, level = {}, nil
    if friend.roster then
      for k, v in pairs(friend.roster.profs or {}) do profs[k] = v end
      level = friend.roster.level
    end
    if friend.manual then for k, v in pairs(friend.manual.profs or {}) do profs[k] = v end end
    local fresh = friend.addon and (friend.addon.seen or 0) >= limit
    if fresh then
      for k, v in pairs(friend.addon.profs or {}) do profs[k] = v end
      level = friend.addon.level or level
    end
    if next(profs) then
      out[name] = {profs = profs, level = level, crafts = fresh and friend.addon.crafts or nil,
                   addon = fresh and true or false, manual = friend.manual ~= nil, roster = friend.roster ~= nil}
    end
  end
  return out
end

function Guild.Count()
  local withAddon, manual, roster = 0, 0, 0
  for _, friend in pairs(Guild.Members()) do
    if friend.addon then withAddon = withAddon + 1
    elseif friend.manual then manual = manual + 1
    elseif friend.roster then roster = roster + 1 end
  end
  return withAddon, manual, roster
end

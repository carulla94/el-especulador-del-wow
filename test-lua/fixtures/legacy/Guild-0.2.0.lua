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
local REPLY_COOLDOWN = 60      -- segundos entre respuestas a la misma persona
local REQUEST_WINDOW = 120     -- aceptamos susurros de respuesta durante este tiempo tras pedir datos

local state = {
  db = nil, getSelf = nil, key = nil,
  queue = {}, sending = false,
  pending = {}, lastAnnounce = -math.huge, announceScheduled = false,
  repliedTo = {}, requestedAt = -math.huge, seq = 0,
}

local RETRY = {}
do
  local R = type(Enum) == "table" and Enum.SendAddonMessageResult or nil
  RETRY[(R and R.AddonMessageThrottle) or 3] = true
  RETRY[(R and R.ChannelThrottle) or 8] = true
  RETRY[(R and R.AddOnMessageLockdown) or 11] = true
end

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

-- Nombres al estilo del servidor: primera letra en mayúscula y el resto en minúscula (UTF-8).
local UPPER = {["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ", ["ü"] = "Ü"}
local LOWER = {}
for lower, upper in pairs(UPPER) do LOWER[upper] = lower end
function Guild.NormalizeName(name)
  if type(name) ~= "string" then return nil end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or #name > 64 then return nil end
  local base, realm = name:match("^([^%-]+)%-(.+)$")
  base = base or name
  local first, rest = base:match("^([%z\1-\127\194-\244][\128-\191]*)(.*)$")
  if not first then return nil end
  first = UPPER[first] or first:upper()
  rest = rest:lower():gsub("[\195][\128-\191]", function(ch) return LOWER[ch] or ch end)
  local out = first .. rest
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
local function store()
  local db = state.db
  if not db then return nil end
  local key = state.key or "_sinhermandad"
  db.guilds[key] = db.guilds[key] or {members = {}}
  return db.guilds[key].members
end

local function findName(members, name)
  if members[name] then return name end
  local lower = name:lower()
  for existing in pairs(members) do
    if existing:lower() == lower then return existing end
  end
  return nil
end

local function member(name, create)
  local members = store()
  if not members or not name then return nil end
  local key = findName(members, name)
  if not key then
    if not create then return nil end
    key = name
    members[key] = {}
  end
  return members[key], key
end

-- Clave de la hermandad actual (reino normalizado + nombre de la hermandad).
function Guild.UpdateKey()
  local key = "_sinhermandad"
  if type(IsInGuild) == "function" and IsInGuild() and type(GetGuildInfo) == "function" then
    local guildName = GetGuildInfo("player")
    if type(guildName) ~= "string" or guildName == "" then return state.key end -- aún no ha cargado
    local realm = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or ""
    key = (realm or "") .. "/" .. guildName
  end
  state.key = key
  return key
end

---------------------------------------------------------------------------
-- Envío con cola, reintento y límite de ritmo
---------------------------------------------------------------------------
local function rawSend(entry)
  if not (type(C_ChatInfo) == "table" and type(C_ChatInfo.SendAddonMessage) == "function") then return false end
  if entry.channel == "GUILD" and not (type(IsInGuild) == "function" and IsInGuild()) then return false end
  if type(C_ChatInfo.InChatMessagingLockdown) == "function" and C_ChatInfo.InChatMessagingLockdown() then return true end
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, Guild.PREFIX, entry.msg, entry.channel, entry.target)
  return ok and RETRY[result] == true -- true = reintentar más tarde
end

local function pump()
  local entry = state.queue[1]
  if not entry then state.sending = false; return end
  entry.tries = (entry.tries or 0) + 1
  if rawSend(entry) and entry.tries < 6 then after(5, pump); return end
  table.remove(state.queue, 1)
  after(1.2, pump) -- el servidor admite ráfagas de 10 y luego 1 por segundo
end

local function enqueue(msg, channel, target, kind)
  if type(msg) ~= "string" or #msg > 250 then return end
  state.queue[#state.queue + 1] = {msg = msg, channel = channel or "GUILD", target = target, kind = kind}
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

local function parseCraft(fields)
  local product, qty, profit = int(fields[5], 1, 2 ^ 31), int(fields[6], 1, 100), int(fields[7], 1, 1e9)
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

-- Procesa un mensaje ya validado de canal. Devuelve true si cambió algo de la hermandad.
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
    if not (level and craftCount and seq) then return false end
    local friend, key = member(name, true)
    local isNew = friend.addon == nil
    friend.addon = {profs = parseProfs(fields[3]), level = level, seen = now(), crafts = friend.addon and friend.addon.crafts or {}}
    if craftCount == 0 then
      friend.addon.crafts = {}
      state.pending[key] = nil
    else
      state.pending[key] = {seq = seq, total = craftCount, parts = {}}
    end
    return true, isNew
  elseif kind == "C" .. PROTOCOL then
    local seq, index, total = int(fields[2], 0, 999), int(fields[3], 1, MAX_CRAFTS), int(fields[4], 1, MAX_CRAFTS)
    if not (seq and index and total) or index > total then return false end
    local friend, key = member(name, false)
    local pending = key and state.pending[key]
    if not (friend and friend.addon and pending and pending.seq == seq and pending.total == total) then return false end
    local craft = parseCraft(fields)
    if not craft then return false end
    pending.parts[index] = craft
    for i = 1, total do if not pending.parts[i] then return false end end
    friend.addon.crafts = pending.parts
    friend.addon.seen = now()
    state.pending[key] = nil
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- API del addon
---------------------------------------------------------------------------
function Guild.Init(db, getSelf)
  state.db, state.getSelf = db, getSelf
  db.guilds = type(db.guilds) == "table" and db.guilds or {}
  db.guild = nil -- formato de la versión 0.1 (sin separar por hermandad)
  if type(C_ChatInfo) == "table" and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, Guild.PREFIX)
  end
  Guild.UpdateKey()
  Guild.Prune()
end

local function buildAnnounce(channel, target)
  local me = state.getSelf and state.getSelf()
  if not me then return end
  state.seq = (state.seq + 1) % 1000
  local crafts = me.crafts or {}
  local total = math.min(#crafts, MAX_CRAFTS)
  enqueue(Guild.EncodeHello(me.level, me.profs, total, state.seq), channel, target, "announce")
  for i = 1, total do enqueue(Guild.EncodeCraft(state.seq, i, total, crafts[i]), channel, target, "announce") end
end

-- Anuncia tus datos a la hermandad. Como mucho una vez por minuto; si se pide antes, se agrupa.
function Guild.Announce()
  if not state.getSelf then return end
  local wait = state.lastAnnounce + ANNOUNCE_COOLDOWN - clock()
  if wait > 0 then
    if not state.announceScheduled then
      state.announceScheduled = true
      after(wait, function() state.announceScheduled = false; Guild.Announce() end)
    end
    return
  end
  state.lastAnnounce = clock()
  -- Quita anuncios pendientes a la hermandad (quedarían viejos); conserva peticiones y respuestas.
  local keep = {}
  for _, entry in ipairs(state.queue) do
    if not (entry.kind == "announce" and entry.channel == "GUILD") then keep[#keep + 1] = entry end
  end
  state.queue = keep
  buildAnnounce("GUILD")
end

-- Pide a la hermandad que te envíe sus datos (te responden por susurro).
function Guild.Request()
  state.requestedAt = clock()
  enqueue("R" .. PROTOCOL, "GUILD", nil, "request")
end

-- Responde a una petición solo a quien la hizo, con un mínimo de tiempo entre respuestas.
function Guild.Reply(sender)
  if type(sender) ~= "string" then return end
  local last = state.repliedTo[sender]
  if last and clock() - last < REPLY_COOLDOWN then return end
  state.repliedTo[sender] = clock()
  after(1 + (#sender % 5), function() buildAnnounce("WHISPER", sender) end)
end

function Guild.OnAddonMessage(prefix, text, channel, sender)
  if prefix ~= Guild.PREFIX then return false end
  if channel == "GUILD" then return Guild.Handle(text, sender, channel) end
  if channel == "WHISPER" and clock() - state.requestedAt < REQUEST_WINDOW then
    return Guild.Handle(text, sender, channel)
  end
  return false
end

-- Importa las profesiones del roster de la hermandad (quien no tenga el addon también aparece).
function Guild.ImportRoster()
  if not state.db or not (type(IsInGuild) == "function" and IsInGuild()) then return 0 end
  if not (type(C_Club) == "table" and type(C_Club.GetGuildClubId) == "function" and type(C_Club.GetClubMembers) == "function"
          and type(C_Club.GetMemberInfo) == "function") then return 0 end
  if type(C_TradeSkillUI) == "table" and type(C_TradeSkillUI.IsGuildTradeSkillsEnabled) == "function" then
    local ok, enabled = pcall(C_TradeSkillUI.IsGuildTradeSkillsEnabled)
    if ok and enabled == false then return 0 end
  end
  local okClub, clubId = pcall(C_Club.GetGuildClubId)
  if not okClub or not clubId then return 0 end
  local okMembers, ids = pcall(C_Club.GetClubMembers, clubId)
  if not okMembers or type(ids) ~= "table" then return 0 end
  local members = store()
  local seenNow, imported = {}, 0
  for _, memberId in ipairs(ids) do
    local ok, info = pcall(C_Club.GetMemberInfo, clubId, memberId)
    if ok and type(info) == "table" and not info.isSelf and type(info.name) == "string" then
      local profs = {}
      for i = 1, 2 do
        local id, rank, profName = info["profession" .. i .. "ID"], info["profession" .. i .. "Rank"], info["profession" .. i .. "Name"]
        local key = Data.ProfessionKeyByID(id) or Data.ProfessionKey(profName)
        if key and type(rank) == "number" and rank > 0 then profs[key] = math.min(rank, 450) end
      end
      if next(profs) then
        local name = shortName(info.name)
        local friend, key = member(name, true)
        friend.roster = {profs = profs, level = type(info.level) == "number" and info.level or nil, seen = now()}
        seenNow[key] = true
        imported = imported + 1
      end
    end
  end
  -- Quien ya no sale en el roster con profesiones pierde esos datos (no los del addon ni los manuales).
  for name, friend in pairs(members) do
    if friend.roster and not seenNow[name] then friend.roster = nil end
    if not friend.roster and not friend.addon and not friend.manual then members[name] = nil end
  end
  return imported
end

function Guild.Prune()
  local db = state.db
  if not db then return end
  local limit = now() - STALE_DAYS * 86400
  for _, data in pairs(db.guilds) do
    for name, friend in pairs(data.members or {}) do
      if friend.addon and (friend.addon.seen or 0) < limit then friend.addon = nil end
      if not friend.addon and not friend.manual and not friend.roster then data.members[name] = nil end
    end
  end
end

-- Añade o cambia a mano una profesión de alguien. Devuelve el nombre normalizado o nil.
function Guild.SetManual(name, profKey, rank)
  name = Guild.NormalizeName(name)
  if not name or not Data.PROFESSIONS[profKey] then return nil end
  local friend, key = member(name, true)
  friend.manual = friend.manual or {profs = {}}
  friend.manual.profs[profKey] = math.max(1, math.min(450, math.floor(rank)))
  return key
end

-- Quita a alguien. Devuelve el nombre si existía.
function Guild.Remove(name)
  name = Guild.NormalizeName(name)
  local members = store()
  local key = members and name and findName(members, name)
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

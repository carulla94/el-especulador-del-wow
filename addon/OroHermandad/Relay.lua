-- Oro de Hermandad: precios compartidos con la hermandad (relay-v1), invisibles en el juego.
-- Al terminar un escaneo completo de la subasta, el addon comparte con tu hermandad, por el canal oculto de los addons
-- (no se ve en el chat), el precio más bajo y las unidades de los objetos de la lista fija, la hora del escaneo y el
-- reino y la facción (mensaje P3). Nada más: ni tu oro, ni tus bolsas, ni tus subastas, ni tus objetos extra. Cada
-- addon guarda lo que oye en OroHermandadHist (market.obs) y lo usa en Especular; los PC con el subidor, además, piden
-- a la hermandad los escaneos que se perdieron (mensaje Q3; las respuestas van por susurro de addon) y el subidor los
-- envía al panel. Quien recibe identifica a quien envía solo con un código de 8 cifras (un hash del nombre del
-- personaje, que da el servidor del juego, y de la hermandad): los nombres de los personajes nunca salen del juego.
-- Ese código es seudónimo, no anónimo: quien conozca la lista de la hermandad podría calcularlo. /oro compartir off
-- deja de compartir tus escaneos.
-- Invisible: aquí nada escribe en el chat, suena, abre ventanas ni toca Auctionator o la subasta. Los fallos van a
-- Relay.lastError (solo los enseña /oro sondeo). Se envía por la cola de Guild.lua (después de lo de profesiones y
-- nunca en combate, instancias ni con los mensajes de addon restringidos) y lo pesado va por tandas de C_Timer.
-- Los 0.2.x/0.3.x ignoran P3 y Q3 (para ellos son mensajes de un tipo desconocido).
local _, ns = ...
local Spec, History, Guild = ns.Spec, ns.History, ns.Guild
local Relay = {}
ns.Relay = Relay

Relay.VERSION = "relay-v1"
local MAX_MSG = 250
local P3_PARTS, Q3_PARTS = 16, 4
local LIVE_OLDEST = 6 * 3600            -- un escaneo en directo (GUILD) de hace más de 6 h no se acepta
local CATCHUP_OLDEST = 72 * 3600 + 900  -- uno de la puesta al día (WHISPER), de hace 72 h y 15 min como mucho
local FUTURE = 600                      -- ni uno con la hora más de 10 min por delante
local BROADCAST_COOLDOWN = 900          -- cada personaje comparte en directo como mucho un escaneo cada 15 min
local LIVE_PER_SENDER = 600             -- y se acepta como mucho uno nuevo de cada compañero cada 10 min
local REPLY_COOLDOWN = 600              -- una respuesta a la misma persona cada 10 min como mucho
local REPLY_DELAY_MIN, REPLY_DELAY_MAX = 2, 90 -- al azar: con muchos compañeros, las respuestas llegan repartidas
local REPLY_MAX_SCANS, REPLY_MAX_MSGS = 4, 24
local REPLY_QUEUE_LIMIT = 48            -- con tantos mensajes de precios en cola no se responde
local OUTBOX_MAX, OUTBOX_SECONDS = 32, 72 * 3600
local ASK_COOLDOWN = 600                -- el PC con el subidor pide como mucho cada 10 min (por cuenta)
local ASK_SECONDS = 72 * 3600
local ASK_POLL = 30                     -- con los mensajes de precios bloqueados, la petición espera y se mira cada 30 s
local FOLLOW_UP = REPLY_COOLDOWN + 60   -- una respuesta llena: lo que falta se pide solo, pasados 11 min
local WINDOW = 900                      -- respuestas por susurro aceptadas durante 15 min tras salir la petición
local WINDOW_MAX_SCANS = 8
local TARGET_RECENT = 14 * 86400
local TARGET_COOLDOWN = 1800
local TARGET_SPACING = 30
local TARGET_PER_HOUR = 20
local SERIES_TIMEOUT = 120
local MAX_OPEN = History.OBS_PER_MARKET + 8 -- series a medio llegar: una por compañero (40) y margen
local INBOX_MAX = 64                    -- escaneos completos esperando a aplicarse (en combate no se aplican)
local Q3_ENTRIES = 52
local TTL = {live = 1200, ask = 300, target = 300, reply = 600}
local TICK_MS, TICK_UNITS = 1.5, 6      -- por tanda: 1,5 ms (con debugprofilestop) o 6 objetos
local COMBAT_POLL = 5
local CHANGE_SPACING = 10               -- la ventana y las descripciones se rehacen como mucho cada 10 s
local TIME_MAX = Spec.TIME_MAX

local floor, max, min = math.floor, math.max, math.min
local isInt = Spec.IsInt

Relay.lastError = nil

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------
local function secret(value)
  if value == nil or type(issecretvalue) ~= "function" then return false end
  local ok, isSecret = pcall(issecretvalue, value)
  return not ok or isSecret == true
end

local function clock()
  if type(GetTime) == "function" then
    local ok, t = pcall(GetTime)
    if ok and type(t) == "number" then return t end
  end
  return 0
end

local function unixNow() return History.Now() end

local function after(seconds, fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then C_Timer.After(seconds, fn) end
end

-- Los fallos nunca salen en el chat: quedan en Relay.lastError para /oro sondeo.
local function protect(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then Relay.lastError = label .. ": " .. tostring(err) end
  return ok, err
end

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

local function agoText(seconds)
  local minutes = floor(max(0, seconds) / 60)
  if minutes < 1 then return "hace menos de 1 min" end
  if minutes < 60 then return "hace " .. minutes .. " min" end
  local hours = floor(minutes / 60)
  if hours < 48 then return "hace " .. hours .. " h" end
  return "hace " .. floor(hours / 24) .. " días"
end

---------------------------------------------------------------------------
-- Código de cada personaje (relay-v1): FNV-1a de 32 bits, 8 cifras hexadecimales en minúsculas
---------------------------------------------------------------------------
-- Sin la librería bit: xor de bytes con una tabla de 16 x 16 y la multiplicación por 16777619 (2^24 + 403) partida,
-- exacta en los números de Lua 5.1. El texto en hexadecimal se arma en dos mitades (%x no admite 32 bits en todos los
-- sistemas).
local XOR4 = {}
for a = 0, 15 do
  for b = 0, 15 do
    local out, bit, x, y = 0, 1, a, b
    for _ = 1, 4 do
      if x % 2 ~= y % 2 then out = out + bit end
      x, y, bit = floor(x / 2), floor(y / 2), bit * 2
    end
    XOR4[a * 16 + b] = out
  end
end

local function xor8(a, b)
  return XOR4[floor(a / 16) * 16 + floor(b / 16)] * 16 + XOR4[(a % 16) * 16 + b % 16]
end

function Relay.Fnv1a32(text)
  local h = 2166136261
  for i = 1, #text do
    local low = h % 256
    h = h - low + xor8(low, text:byte(i))
    h = (h * 403 + (h % 256) * 16777216) % 4294967296
  end
  return string.format("%04x%04x", floor(h / 65536), h % 65536)
end
local fnv = Relay.Fnv1a32

local function fold(text) return Guild.Fold(text) end
local function canonRealm(realm) return fold((realm:gsub("[%s%-']", ""))) end

-- Texto del que sale el código: reino de la hermandad / hermandad | personaje-reino, todo en minúsculas. El nombre se
-- parte en el primer guion; sin guion, el reino es el tuyo.
function Relay.Canonical(guildRealm, guildName, sender, ownRealm)
  local name, realm = sender:match("^([^%-]+)%-(.*)$")
  if not name then name, realm = sender, ownRealm end
  return canonRealm(guildRealm) .. "/" .. fold(guildName) .. "|" .. fold(name) .. "-" .. canonRealm(realm or "")
end

local function realmName()
  if type(GetNormalizedRealmName) ~= "function" then return nil end
  local ok, realm = pcall(GetNormalizedRealmName)
  if ok and not secret(realm) and type(realm) == "string" and realm ~= "" then return realm end
  return nil
end

-- Reino de la hermandad (el suyo, no el tuyo: así todos, también en reinos conectados, dan el mismo código) y su
-- nombre. nil si no estás en una o aún no se puede leer: entonces no se comparte ni se recibe nada.
local function salt()
  if type(IsInGuild) ~= "function" or type(GetGuildInfo) ~= "function" then return nil end
  local okGuild, inGuild = pcall(IsInGuild)
  if not okGuild or secret(inGuild) or not inGuild then return nil end
  local ok, name, _, _, realm = pcall(GetGuildInfo, "player")
  if not ok or secret(name) or secret(realm) or type(name) ~= "string" or name == "" then return nil end
  if type(realm) ~= "string" or realm == "" then realm = realmName() end
  if not realm then return nil end
  return canonRealm(realm) .. "/" .. fold(name)
end
Relay.Salt = salt

-- Caché nombre -> código solo en memoria (Relay nunca guarda nombres).
local hashCache, hashCount = {}, 0
local function senderHash(sender, s)
  s = s or salt()
  if not s or type(sender) ~= "string" or sender == "" or #sender > 100 then return nil end
  local key = s .. "|" .. sender
  local h = hashCache[key]
  if h then return h end
  local name, realm = sender:match("^([^%-]+)%-(.*)$")
  if not name then name, realm = sender, realmName() end
  if not realm then return nil end
  h = fnv(s .. "|" .. fold(name) .. "-" .. canonRealm(realm))
  if hashCount >= 2000 then hashCache, hashCount = {}, 0 end
  hashCache[key], hashCount = h, hashCount + 1
  return h
end
Relay.Hash = senderHash

local function ownHash(s)
  local okName, name = pcall(UnitName, "player")
  local realm = realmName()
  if not okName or secret(name) or type(name) ~= "string" or name == "" or not realm then return nil end
  return senderHash(name .. "-" .. realm, s)
end
Relay.OwnHash = ownHash

-- Etiqueta del mercado: el código FNV de "Reino-Facción" tal cual (otra subasta, otra etiqueta).
local tagCache = {}
local function tagOf(key)
  local tag = tagCache[key]
  if not tag then tag = fnv(key); tagCache[key] = tag end
  return tag
end
Relay.MarketTag = tagOf

local function marketNow()
  local key = History.CurrentMarket()
  if key then return key, tagOf(key) end
  return nil
end

local function isHash(h) return type(h) == "string" and #h == 8 and not h:find("[^0-9a-f]") end

---------------------------------------------------------------------------
-- Formato de los mensajes (base 36 en minúsculas, sin ceros a la izquierda)
---------------------------------------------------------------------------
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local DIGIT = {}
for i = 1, #DIGITS do DIGIT[DIGITS:byte(i)] = i - 1 end

function Relay.B36(n)
  if n == 0 then return "0" end
  local out = {}
  while n > 0 do
    local r = n % 36
    out[#out + 1] = DIGITS:sub(r + 1, r + 1)
    n = (n - r) / 36
  end
  return string.reverse(table.concat(out))
end
local b36 = Relay.B36

-- Texto en base 36 -> número en [lo, hi], o nil. Se rechazan mayúsculas, signos, espacios y ceros a la izquierda; se
-- calcula a mano (tonumber con base no llega a 2^32 en todos los sistemas).
function Relay.D36(text, lo, hi)
  if type(text) ~= "string" or text == "" or #text > 7 then return nil end
  if #text > 1 and text:byte(1) == 48 then return nil end
  local n = 0
  for i = 1, #text do
    local d = DIGIT[text:byte(i)]
    if not d then return nil end
    n = n * 36 + d
  end
  if n < lo or n > hi then return nil end
  return n
end
local d36 = Relay.D36

local function small(text, hi)
  if type(text) ~= "string" or not text:match("^[1-9][0-9]?$") then return nil end
  local n = tonumber(text)
  return n <= hi and n or nil
end

local function split(text, sep)
  local out = {}
  for piece in (text .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do out[#out + 1] = piece end
  return out
end

local function token(id, lo, qty, qty5) return b36(id) .. ":" .. b36(lo) .. ":" .. b36(qty) .. ":" .. b36(qty5) end

-- Reparte los tokens en mensajes de 250 bytes como mucho, siempre en el mismo orden y como si parte y total tuvieran
-- 2 cifras: "<kind>|<seq>|<parte>|<total>|<mk>|<t>|tok,tok,...". Si salen más de maxParts, se quedan las primeras.
local function pack(kind, seq, mk, t, tokens, maxParts)
  local head, tail = kind .. "|" .. b36(seq) .. "|", "|" .. mk .. "|" .. b36(t) .. "|"
  local budget = MAX_MSG - #(head .. "16|16" .. tail)
  local parts, cur = {}, nil
  for _, tok in ipairs(tokens) do
    if not cur then
      cur = tok
    elseif #cur + 1 + #tok <= budget then
      cur = cur .. "," .. tok
    else
      parts[#parts + 1] = cur
      cur = tok
    end
  end
  if cur then parts[#parts + 1] = cur elseif #parts == 0 then parts[1] = "" end
  while #parts > maxParts do table.remove(parts) end
  local msgs = {}
  for i, p in ipairs(parts) do msgs[i] = head .. i .. "|" .. #parts .. tail .. p end
  return msgs
end

local function sortTokens(items)
  table.sort(items, function(a, b) return a[1] < b[1] end)
  local tokens = {}
  for i, it in ipairs(items) do tokens[i] = token(it[1], it[2], it[3], it[4]) end
  return tokens
end

-- P3 de un escaneo: items = {{id, lo, qty, qty5}, ...} (se ordenan por ID).
function Relay.PackP3(seq, mk, t, items)
  local copy = {}
  for i, it in ipairs(items) do copy[i] = it end
  return pack("P3", seq, mk, t, sortTokens(copy), P3_PARTS)
end

-- Q3: entries = {[código] = hora} o {{código, hora}, ...}; van ordenadas por código.
function Relay.PackQ3(seq, mk, floorTime, entries)
  local tokens = {}
  for k, v in pairs(entries or {}) do
    if type(k) == "string" then tokens[#tokens + 1] = k .. ":" .. b36(v)
    elseif type(v) == "table" then tokens[#tokens + 1] = v[1] .. ":" .. b36(v[2]) end
  end
  table.sort(tokens)
  return pack("Q3", seq, mk, floorTime, tokens, Q3_PARTS)
end

local function splitTokens(text)
  local out = {}
  for tok in text:gmatch("[^,]+") do out[#out + 1] = tok end
  return out
end

-- "id:lo:qty:qty5(:más)*" -> id, lo, qty, qty5 (o nil si está mal). Los subcampos de más se ignoran.
local function parseToken(tok)
  local f = split(tok, ":")
  if #f < 4 then return nil end
  for i = 5, #f do if not f[i]:match("^[0-9a-z]*$") then return nil end end
  local id, lo = d36(f[1], 1, 2147483647), d36(f[2], 1, Spec.PRICE_MAX)
  local qty, qty5 = d36(f[3], 0, Spec.QTY_MAX), d36(f[4], 0, Spec.QTY_MAX)
  if not (id and lo and qty and qty5) or qty5 > qty then return nil end
  return id, lo, qty, qty5
end

-- Mensaje recibido -> tabla, o nil y el motivo. now: hora unix; channel: "GUILD" (en directo) o "WHISPER" (puesta al
-- día); mk: etiqueta del mercado actual. Solo comprueba el texto; las reglas de quién y cuándo van aparte.
function Relay.Parse(text, now, channel, mk)
  if type(text) ~= "string" or #text > 255 then return nil, "tamaño" end
  local f = split(text, "|")
  if #f < 7 then return nil, "campos" end
  local kind = f[1]
  if kind ~= "P3" and kind ~= "Q3" then return nil, "tipo" end
  for i = 8, #f do if not f[i]:match("^[0-9a-z]*$") then return nil, "campo de más" end end
  local maxParts = kind == "P3" and P3_PARTS or Q3_PARTS
  local seq, part, total = d36(f[2], 0, 1295), small(f[3], maxParts), small(f[4], maxParts)
  if not (seq and part and total) or part > total then return nil, "cabecera" end
  if not isHash(f[5]) then return nil, "etiqueta" end
  if f[5] ~= mk then return nil, "otro mercado" end
  if kind == "P3" then
    local t = d36(f[6], 1, TIME_MAX)
    local oldest = channel == "WHISPER" and now - CATCHUP_OLDEST or now - LIVE_OLDEST
    if not t or t < oldest or t > now + FUTURE then return nil, "hora" end
    local items, ids = {}, {}
    if f[7] ~= "" then
      for _, tok in ipairs(split(f[7], ",")) do
        local id, lo, qty, qty5 = parseToken(tok)
        if not id then return nil, "objeto mal escrito" end
        if ids[id] then return nil, "objeto repetido" end
        ids[id] = true
        if History.IsFixed(id) then items[#items + 1] = {id, lo, qty, qty5} end
      end
    end
    return {kind = kind, seq = seq, part = part, total = total, mk = f[5], t = t, items = items, ids = ids}
  end
  local floorTime = d36(f[6], 0, TIME_MAX)
  if not floorTime then return nil, "hora" end
  local entries = {}
  if f[7] ~= "" then
    for _, tok in ipairs(split(f[7], ",")) do
      local sub = split(tok, ":")
      if #sub < 2 or not isHash(sub[1]) then return nil, "entrada" end
      for i = 3, #sub do if not sub[i]:match("^[0-9a-z]*$") then return nil, "entrada" end end
      local t = d36(sub[2], 0, TIME_MAX)
      if not t then return nil, "entrada" end
      entries[sub[1]] = max(entries[sub[1]] or 0, t)
    end
  end
  return {kind = kind, seq = seq, part = part, total = total, mk = f[5], floor = floorTime, entries = entries}
end

---------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------
local db, cdb                 -- OroHermandadDB.relay (cuenta) y OroHermandadCharDB.relay (personaje)
local markerSeen = false      -- el subidor del PC dejó su aviso (OroHermandad_Subidor)
local loggedIn = false        -- ya pasó Relay.Login (25 s después de entrar)
local stats = {received = 0, dropped = 0, lastReason = nil}
local open, openCount, bySender, dead = {}, 0, {}, {}
local liveAt = {}             -- código -> último escaneo en directo aceptado (GetTime)
local inbox, applying = {}, nil
local broadcastWin = nil      -- {id, untilAt}: tras la petición a toda la hermandad
local targets = {}            -- código -> {id, untilAt}: tras una petición por susurro
local windowCount, windowParts, windowSeq = {}, {}, 0
local replies, repliedAt = {}, {}
local askedAt, targetLog, pendingTargets, lastTarget, targetTimer = {}, {}, {}, -math.huge, false
local broadcastTimer = false
local askPending = false      -- hay que pedir a toda la hermandad (hasta que la petición sale de verdad)
local askQueued, askPolling = false, false -- esa petición ya está en la cola / hay un temporizador mirando si se puede
local followAsk, followTarget = false, {} -- peticiones de lo que faltaba, ya programadas (toda la hermandad / código)
local cache = {key = nil, items = {}, dirty = {}, queue = {}}
local working = false
local onChange, lastChange, changeTimer, changePending = nil, -math.huge, false, false

local function reject(reason)
  stats.dropped = stats.dropped + 1
  stats.lastReason = reason
  return false, reason
end

local function nextSeq()
  cdb.seq = ((cdb.seq or 0) + 1) % 1296
  return cdb.seq
end

local function nextWindowId(kind)
  windowSeq = windowSeq + 1
  return kind .. windowSeq
end

local function shareOn() return db ~= nil and db.share ~= false end

-- Códigos de tus personajes en un mercado (market.self), como conjunto; se recalcula solo si cambia el texto.
local selfCache = {}
local function selfSet(market)
  local text = type(market) == "table" and market.self or nil
  if type(text) ~= "string" then return {} end
  local set = selfCache[text]
  if not set then
    set = {}
    for _, h in ipairs(History.SelfList(text)) do set[h] = true end
    selfCache = {[text] = set}
  end
  return set
end

local function hasTime(text, t)
  if type(text) ~= "string" or text == "" then return false end
  local s = tostring(t)
  return text == s or text:sub(1, #s + 1) == s .. "," or text:sub(-(#s + 1)) == "," .. s
    or text:find("," .. s .. ",", 1, true) ~= nil
end

---------------------------------------------------------------------------
-- Datos de los compañeros para Especular (decodificados por tandas; Core los pide con Relay.GuildItems)
---------------------------------------------------------------------------
local startWork

local function markDirty(key, id)
  if cache.key ~= key then return end
  if not cache.dirty[id] then
    cache.dirty[id] = true
    cache.queue[#cache.queue + 1] = id
  end
  startWork()
end

local function resetCache(key)
  cache = {key = key, items = {}, dirty = {}, queue = {}, job = nil}
  local market = History.Market(key)
  local ids = {}
  for _, entry in pairs(market and type(market.obs) == "table" and market.obs or {}) do
    for id in pairs(entry.items) do ids[id] = true end
  end
  local list = {}
  for id in pairs(ids) do list[#list + 1] = id end
  table.sort(list)
  for _, id in ipairs(list) do markDirty(key, id) end
end

-- Un objeto se decodifica compañero a compañero (cada uno es una unidad de las tandas: con 40 compañeros ninguna
-- tanda se alarga). Lo de un compañero cuyo texto no cambió se reutiliza tal cual: tras un escaneo nuevo solo se
-- decodifica lo de quien lo hizo.
local function startDecode(id)
  local market = History.Market(cache.key)
  local hashes = {}
  for h, entry in pairs(market and type(market.obs) == "table" and market.obs or {}) do
    if entry.items[id] then hashes[#hashes + 1] = h end
  end
  table.sort(hashes)
  local prev = {}
  for _, e in ipairs(cache.items[id] and cache.items[id].list or {}) do prev[e.id] = e end
  cache.job = {id = id, hashes = hashes, i = 1, list = {}, prev = prev}
end

local function decodeStep(job)
  local h = job.hashes[job.i]
  job.i = job.i + 1
  if h then
    local market = History.Market(cache.key)
    local entry = market and type(market.obs) == "table" and market.obs[h] or nil
    local item = entry and entry.items[job.id]
    if item then
      local old = job.prev[h]
      if old and old.dText == item.d and old.pText == item.p then
        job.list[#job.list + 1] = old
      else
        local records, point = History.RecentRecords(item.d), History.LastPoint(item.p)
        if #records > 0 or point then
          job.list[#job.list + 1] = {id = h, records = records, point = point, dText = item.d, pText = item.p}
        end
      end
    end
    return
  end
  cache.items[job.id] = #job.list > 0 and {list = job.list, key = {}} or nil
  cache.job = nil
  changePending = true
end

-- {[id] = {list = {{id = código, records, point}, ...}, key = tabla nueva cada vez que cambia}} del mercado key, con
-- lo que ya esté decodificado (lo demás llega en unas tandas y entonces avisa con Relay.OnChange).
function Relay.GuildItems(key)
  if not key or not History.Hist() then return {} end
  if cache.key ~= key then resetCache(key) end
  return cache.items
end

function Relay.OnChange(fn) onChange = type(fn) == "function" and fn or nil end

local function notifyChange()
  if not changePending or not onChange then return end
  local wait = lastChange + CHANGE_SPACING - clock()
  if wait > 0 then
    if not changeTimer then
      changeTimer = true
      after(wait, function() changeTimer = false; notifyChange() end)
    end
    return
  end
  changePending, lastChange = false, clock()
  protect("aviso", onChange)
end

---------------------------------------------------------------------------
-- Aplicar escaneos de compañeros (por tandas, nunca en combate)
---------------------------------------------------------------------------
-- Tu código en este mercado (market.self, el más nuevo primero, 10 como mucho); si alguna vez llegó algo con él a
-- obs (no debería), se quita.
local function recordSelf(key, market)
  market = market or History.Market(key)
  local me = ownHash()
  if not market or not me then return end
  local list = History.SelfList(market.self)
  local present = false
  for _, h in ipairs(list) do if h == me then present = true end end
  if not present then
    table.insert(list, 1, me)
    while #list > History.SELF_MAX do table.remove(list) end
    market.self = table.concat(list, ",")
  end
  if type(market.obs) == "table" then
    for h in pairs(selfSet(market)) do
      local entry = market.obs[h]
      if entry then
        market.obs[h] = nil
        for id in pairs(entry.items) do markDirty(key, id) end
      end
    end
    if next(market.obs) == nil then market.obs = nil end
  end
end

local function evict(key, market, h)
  local entry = market.obs[h]
  if not entry then return end
  market.obs[h] = nil
  for id in pairs(entry.items) do markDirty(key, id) end
end

-- Primer paso de un escaneo: la hora va a s ANTES que los precios (así nunca se cuenta dos veces, aunque la sesión
-- acabe a medias). Con 40 compañeros en el mercado, uno nuevo solo entra si su escaneo es más nuevo que el más viejo.
local function applyBegin(scan)
  if not History.Hist() then return nil end
  local market = History.Market(scan.market, true)
  if not market then return nil end
  recordSelf(scan.market, market)
  if selfSet(market)[scan.hash] then return nil end
  local obs = type(market.obs) == "table" and market.obs[scan.hash] or nil
  if obs then
    if hasTime(obs.s, scan.t) then return nil end
  else
    local count, oldest = 0, nil
    for h, entry in pairs(type(market.obs) == "table" and market.obs or {}) do
      count = count + 1
      local candidate = {hash = h, seen = entry.seen}
      if not oldest or History.EvictionOrder(candidate, oldest) then oldest = candidate end
    end
    if count >= History.OBS_PER_MARKET then
      if not (scan.t > oldest.seen) then stats.dropped = stats.dropped + 1; return nil end
      evict(scan.market, market, oldest.hash)
    end
    market.obs = type(market.obs) == "table" and market.obs or {}
    obs = {seen = scan.t, s = "", items = {}}
    market.obs[scan.hash] = obs
  end
  local times = History.DecodeTimes(obs.s)
  times[#times + 1] = scan.t
  table.sort(times)
  obs.s = History.EncodeTimes(times, unixNow())
  obs.seen = max(obs.seen or 0, scan.t)
  return {scan = scan, obs = obs, index = 1, d = Spec.DayIndex(scan.t)}
end

-- Un objeto del escaneo, igual que History escribe los tuyos: la vela del día y el punto.
local function applyItem(job)
  local it = job.scan.items[job.index]
  job.index = job.index + 1
  local id, lo, qty, qty5 = it[1], it[2], it[3], it[4]
  local item = job.obs.items[id]
  if not item then item = {d = "", p = ""}; job.obs.items[id] = item end
  item.d = History.RecordDayText(item.d, job.d, lo, qty)
  item.p = History.AddPointText(item.p, job.scan.t, lo, qty, qty5)
  markDirty(job.scan.market, id)
end

-- Una unidad de trabajo: un objeto de un escaneo, o lo de un compañero en un objeto. Un objeto a medio decodificar
-- se termina antes de aplicar otro escaneo (así ve los datos de una vez).
local function workUnit()
  if applying then
    if applying.index > #applying.scan.items then
      applying = nil
      changePending = true
    else
      applyItem(applying)
    end
    return true
  end
  if cache.job then
    decodeStep(cache.job)
    return true
  end
  local scan = table.remove(inbox, 1)
  if scan then
    applying = applyBegin(scan)
    return true
  end
  local id = table.remove(cache.queue, 1)
  if id then
    cache.dirty[id] = nil
    startDecode(id)
    return true
  end
  return false
end

local function inCombat()
  if type(InCombatLockdown) ~= "function" then return false end
  local ok, value = pcall(function() return InCombatLockdown() == true end)
  return not ok or value
end

local expire

local function work()
  working = false
  protect("series", expire)
  if inCombat() then
    working = true
    after(COMBAT_POLL, work)
    return
  end
  local ok, err = pcall(function()
    local profile = type(debugprofilestop) == "function" and debugprofilestop or nil
    local start = profile and profile()
    local n = 0
    while true do
      if profile then
        if profile() - start >= TICK_MS then break end
      elseif n >= TICK_UNITS then
        break
      end
      if not workUnit() then break end
      n = n + 1
    end
  end)
  if not ok then Relay.lastError = "tanda: " .. tostring(err); applying = nil; cache.job = nil end
  if applying or cache.job or #inbox > 0 or #cache.queue > 0 then
    working = true
    after(0, work)
  else
    notifyChange()
  end
end

startWork = function()
  if working then return end
  working = true
  after(0, work)
end

---------------------------------------------------------------------------
-- Recibir
---------------------------------------------------------------------------
local function windowFor(h)
  local c = clock()
  local target = targets[h]
  if target and c <= target.untilAt then return target.id end
  if broadcastWin and c <= broadcastWin.untilAt then return broadcastWin.id end
  return nil
end

local function dropSeries(key, reason)
  local s = open[key]
  if not s then return end
  open[key], openCount = nil, openCount - 1
  if bySender[s.hash] == key then bySender[s.hash] = nil end
  dead[key] = clock()
  if reason then reject(reason) end
end

expire = function()
  local c = clock()
  for key, s in pairs(open) do
    if c - s.at > SERIES_TIMEOUT then dropSeries(key, "incompleto") end
  end
  for key, at in pairs(dead) do
    if c - at > SERIES_TIMEOUT then dead[key] = nil end
  end
end
Relay.Expire = expire

local scheduleFollowUp

-- Un escaneo completo de un compañero: a la bandeja de entrada (64 como mucho), si no se tenía ya y no pasa de los
-- límites (uno en directo cada 10 min por compañero; 8 por ventana de puesta al día). Si su respuesta llega llena
-- (4 escaneos, o no cabría otro como el último en los 24 mensajes), lo que le quede se pide solo más tarde.
local function deliver(scan)
  local market = History.Market(scan.market)
  local obs = market and type(market.obs) == "table" and market.obs[scan.hash] or nil
  if obs and hasTime(obs.s, scan.t) then return false, "ya estaba" end
  if applying and applying.scan.hash == scan.hash and applying.scan.t == scan.t then return false, "ya estaba" end
  for _, other in ipairs(inbox) do
    if other.hash == scan.hash and other.t == scan.t then return false, "ya estaba" end
  end
  if #scan.items == 0 then return false, "vacío" end
  if scan.channel == "GUILD" then
    local last = liveAt[scan.hash]
    if last and clock() - last < LIVE_PER_SENDER then return reject("demasiado seguido") end
    liveAt[scan.hash] = clock()
  else
    local win = windowFor(scan.hash)
    if not win then return reject("fuera de ventana") end
    local k = win .. "\0" .. scan.hash
    if (windowCount[k] or 0) >= WINDOW_MAX_SCANS then return reject("demasiados") end
    windowCount[k] = (windowCount[k] or 0) + 1
    local parts = scan.parts or 1
    windowParts[k] = (windowParts[k] or 0) + parts
    if windowCount[k] >= REPLY_MAX_SCANS or windowParts[k] + parts > REPLY_MAX_MSGS then
      scheduleFollowUp(win, scan.hash, scan.sender)
    end
  end
  inbox[#inbox + 1] = scan
  if #inbox > INBOX_MAX then table.remove(inbox, 1); stats.dropped = stats.dropped + 1 end
  stats.received = stats.received + 1
  startWork()
  return true, "escaneo"
end

local function onP3(msg, sender, h, channel, key)
  if channel == "WHISPER" then
    if not windowFor(h) then return reject("susurro no pedido") end
    if not Guild.IsGuildmate(sender) then return reject("no es de la hermandad") end
  end
  expire()
  local skey = h .. "\0" .. msg.seq .. "\0" .. msg.t
  if dead[skey] then return false, "serie descartada" end
  local s = open[skey]
  if not s then
    local older = bySender[h]
    if older then dropSeries(older, "otra serie") end
    if openCount >= MAX_OPEN then
      -- Lleno: se va la serie con menos partes recibidas (a igualdad, la más vieja), nunca la que está por acabar.
      local worstKey, worst
      for k, other in pairs(open) do
        if not worst or other.got < worst.got or (other.got == worst.got and (other.at < worst.at
           or (other.at == worst.at and k < worstKey))) then
          worstKey, worst = k, other
        end
      end
      dropSeries(worstKey, "demasiadas series")
    end
    s = {hash = h, sender = sender, t = msg.t, total = msg.total, channel = channel, market = key, parts = {}, got = 0,
         ids = {}, at = clock()}
    open[skey], openCount, bySender[h] = s, openCount + 1, skey
  end
  if s.total ~= msg.total or s.channel ~= channel or s.market ~= key then
    dropSeries(skey)
    return reject("partes que no casan")
  end
  if s.parts[msg.part] then return false, "parte repetida" end
  for id in pairs(msg.ids) do
    if s.ids[id] then dropSeries(skey); return reject("objeto repetido") end
  end
  for id in pairs(msg.ids) do s.ids[id] = true end
  s.parts[msg.part], s.got = msg.items, s.got + 1
  if s.got < s.total then return true, "parte" end
  dropSeries(skey) -- completa: las copias que lleguen tarde de esta serie se ignoran
  local items = {}
  for i = 1, s.total do
    for _, it in ipairs(s.parts[i]) do items[#items + 1] = it end
  end
  return deliver({hash = h, sender = sender, t = s.t, channel = channel, market = key, items = items, parts = s.total})
end

local fireReply

local function onQ3(msg, sender, h, channel)
  if channel == "WHISPER" and not Guild.IsGuildmate(sender) then return reject("no es de la hermandad") end
  if not shareOn() then return false, "no compartes" end
  local me = ownHash()
  if not me then return false, "sin código" end
  local since = max(msg.floor, msg.entries[me] or 0)
  local last = repliedAt[h]
  if last and clock() - last < REPLY_COOLDOWN then return false, "ya respondido" end
  local pending = replies[h]
  if pending then
    pending.since = max(pending.since, since)
    return true, "petición"
  end
  replies[h] = {since = since, sender = sender, mk = msg.mk}
  after(math.random(REPLY_DELAY_MIN, REPLY_DELAY_MAX), function() protect("respuesta", fireReply, h) end)
  return true, "petición"
end

local function handleMessage(text, sender, channel)
  if not db or not cdb or not History.Hist() then return false, "apagado" end
  if type(text) ~= "string" or #text > 255 then return reject("tamaño") end
  local s = salt()
  if not s then return reject("hermandad sin leer") end
  local key, mk = marketNow()
  if not key then return reject("mercado") end
  local t = unixNow()
  if not t then return reject("hora") end
  local h = senderHash(sender, s)
  if not h then return reject("remitente") end
  if h == ownHash(s) or selfSet(History.Market(key))[h] then return false, "propio" end
  local msg, why = Relay.Parse(text, t, channel, mk)
  if not msg then return reject(why) end
  if msg.kind == "P3" then return onP3(msg, sender, h, channel, key) end
  return onQ3(msg, sender, h, channel)
end

-- Guild.OnAddonMessage pasa aquí cada P3 y Q3 (de la hermandad o por susurro). Devuelve si se aceptó y el motivo
-- (solo para las pruebas: Guild no lo usa).
function Relay.OnMessage(text, sender, channel)
  local ok, accepted, why = pcall(handleMessage, text, sender, channel)
  if not ok then Relay.lastError = "mensaje: " .. tostring(accepted); return false, "error" end
  return accepted, why
end

---------------------------------------------------------------------------
-- Compartir (buzón del personaje, anuncio en directo y respuestas a Q3)
---------------------------------------------------------------------------
local function pruneOutbox(list, t)
  table.sort(list, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return a.mk < b.mk
  end)
  local out, last = {}, nil
  for _, scan in ipairs(list) do
    local fresh = not t or scan.t > t - OUTBOX_SECONDS
    if fresh and not (last and last.t == scan.t and last.mk == scan.mk) then out[#out + 1] = scan; last = scan end
  end
  while #out > OUTBOX_MAX do table.remove(out, 1) end
  return out
end

local function validTokens(text)
  if type(text) ~= "string" or text == "" or #text > 4096 then return false end
  for _, tok in ipairs(splitTokens(text)) do
    if not parseToken(tok) then return false end
  end
  return true
end

-- Anuncia a la hermandad el escaneo más nuevo del buzón que aún no salió en directo, como mucho uno cada 15 min por
-- personaje (si toca esperar, un solo temporizador lo hace a su hora).
local function maybeBroadcast()
  if not shareOn() or not cdb or not salt() then return end
  local key, mk = marketNow()
  local t = unixNow()
  if not (key and t) then return end
  local newest
  for _, scan in ipairs(cdb.out) do
    if scan.mk == mk and scan.t > (cdb.sent or 0) and scan.t >= t - LIVE_OLDEST + TTL.live and scan.t <= t + FUTURE
       and (not newest or scan.t > newest.t) then
      newest = scan
    end
  end
  if not newest then return end
  local wait = min(BROADCAST_COOLDOWN, (cdb.lastSent or 0) + BROADCAST_COOLDOWN - t)
  if wait > 0 then
    if not broadcastTimer then
      broadcastTimer = true
      after(wait, function() broadcastTimer = false; protect("anuncio", maybeBroadcast) end)
    end
    return
  end
  local msgs = pack("P3", nextSeq(), mk, newest.t, splitTokens(newest.items), P3_PARTS)
  if Guild.EnqueueRelay(msgs, "GUILD", nil, TTL.live) then cdb.lastSent, cdb.sent = t, newest.t end
end

-- History acaba de grabar un escaneo. Solo uno entero, propio (no el precio de reserva de Auctionator) y nuevo va
-- al buzón y se comparte; solo los objetos de la lista fija.
local function onScan(info)
  if not db or not cdb or type(info) ~= "table" then return end
  if not (info.whole and not info.fallback and not info.duplicate and (info.written or 0) > 0) then return end
  if not History.ValidMarketKey(info.market) or not isInt(info.t, 1, TIME_MAX) then return end
  if History.CurrentMarket() == info.market then recordSelf(info.market) end
  if not shareOn() then return end
  local items = {}
  for _, it in ipairs(type(info.items) == "table" and info.items or {}) do
    local id, lo, qty, qty5 = it[1], it[2], it[3], it[4]
    if History.IsFixed(id) and isInt(lo, 1, Spec.PRICE_MAX) and isInt(qty, 0, Spec.QTY_MAX) and isInt(qty5, 0, Spec.QTY_MAX) then
      items[#items + 1] = {id, lo, qty, min(qty5, qty)}
    end
  end
  if #items == 0 then return end
  cdb.out[#cdb.out + 1] = {t = info.t, mk = tagOf(info.market), items = table.concat(sortTokens(items), ",")}
  cdb.out = pruneOutbox(cdb.out, unixNow())
  maybeBroadcast()
end

-- Se llama al terminar de grabar (dentro de una tanda de History): el trabajo va en la siguiente.
function Relay.OnScan(info)
  after(0, function() protect("escaneo", onScan, info) end)
end

-- Respuesta a una petición: tus escaneos de ese mercado posteriores a lo que ya tiene (since) y de las últimas 72 h,
-- solo escaneos enteros, del más viejo al más nuevo y como mucho 4 y 24 mensajes. Así lo que tiene quien pide avanza
-- sin huecos: lo que no cabe va en la siguiente petición (que quien pide hace sola si la respuesta llega llena).
fireReply = function(h)
  local p = replies[h]
  replies[h] = nil
  if not p then return end
  repliedAt[h] = clock()
  if not shareOn() or not cdb or Guild.RelayQueued() >= REPLY_QUEUE_LIMIT then return end
  local key, mk = marketNow()
  local t = unixNow()
  if not key or mk ~= p.mk or not t then return end
  local list = {}
  for _, scan in ipairs(cdb.out) do
    if scan.mk == mk and scan.t > p.since and scan.t >= t - OUTBOX_SECONDS and scan.t <= t + FUTURE then
      list[#list + 1] = scan
    end
  end
  table.sort(list, function(a, b) return a.t < b.t end)
  local chosen, count = {}, 0
  for _, scan in ipairs(list) do
    if #chosen >= REPLY_MAX_SCANS then break end
    local n = #pack("P3", 1295, mk, scan.t, splitTokens(scan.items), P3_PARTS)
    if count + n > REPLY_MAX_MSGS then break end -- sin saltarse ninguno: el siguiente va en la próxima respuesta
    chosen[#chosen + 1] = scan
    count = count + n
  end
  for _, scan in ipairs(chosen) do
    local msgs = pack("P3", nextSeq(), mk, scan.t, splitTokens(scan.items), P3_PARTS)
    if not Guild.EnqueueRelay(msgs, "WHISPER", p.sender, TTL.reply) then break end
  end
end

---------------------------------------------------------------------------
-- Pedir lo que se perdió (solo en el PC con el subidor)
---------------------------------------------------------------------------
-- ¿Está el aviso del subidor? Lo crea hermandad.py en Interface\AddOns\OroHermandad_Subidor (una carpeta nueva solo
-- se ve tras salir del juego del todo). Solo se lee.
function Relay.MarkerDetected()
  if type(C_AddOns) == "table" and type(C_AddOns.IsAddOnLoaded) == "function" then
    local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, "OroHermandad_Subidor")
    if ok and not secret(loaded) and loaded then return true end
  end
  local marker = _G["OroHermandadSubidor"]
  return type(marker) == "table" and marker.formato == 1
end

function Relay.UploaderMode()
  if not db then return false end
  if db.subidor == "on" then return true end
  if db.subidor == "off" then return false end
  return markerSeen
end

-- La petición a toda la hermandad se arma justo al ponerla en cola (con lo que ya se tiene de cada compañero) y solo
-- cuando se pueden enviar mensajes de precios: en combate, instancias o con los mensajes restringidos espera y se
-- mira cada 30 s. lastAsk (los 10 min de espera) cuenta desde que sale de verdad; si caduca en la cola sin salir,
-- se vuelve a preparar.
local askToken = 0
local armAsk

local function sendAsk()
  local key, mk = marketNow()
  local t = unixNow()
  if not (db and cdb and History.Hist() and Relay.UploaderMode() and salt() and key and t) then
    askPending = false
    return false
  end
  local floorTime = t - ASK_SECONDS
  local market = History.Market(key)
  local list = {}
  for h, entry in pairs(market and type(market.obs) == "table" and market.obs or {}) do
    if entry.seen > floorTime then list[#list + 1] = {hash = h, seen = entry.seen} end
  end
  table.sort(list, function(a, b)
    if a.seen ~= b.seen then return a.seen > b.seen end
    return a.hash < b.hash
  end)
  local entries = {}
  for i = 1, min(#list, Q3_ENTRIES) do entries[list[i].hash] = list[i].seen end
  local id = nextWindowId("b")
  askToken = askToken + 1
  local token = askToken
  local msgs = Relay.PackQ3(nextSeq(), mk, floorTime, entries)
  local queued = Guild.EnqueueRelay(msgs, "GUILD", nil, TTL.ask, function()
    broadcastWin = {id = id, untilAt = clock() + WINDOW}
    if token == askToken and askQueued then
      askQueued, askPending = false, false
      db.lastAsk = unixNow() or t
    end
  end)
  if not queued then
    askPending = false
    return false
  end
  askQueued = true
  after(TTL.ask + 5, function()
    if token == askToken and askQueued then
      askQueued = false -- caducó en la cola sin salir
      protect("petición", armAsk)
    end
  end)
  return true
end

armAsk = function()
  if not askPending or askQueued then return end
  if Guild.RelayBlocked() then
    if not askPolling then
      askPolling = true
      after(ASK_POLL, function() askPolling = false; protect("petición", armAsk) end)
    end
    return
  end
  sendAsk()
end

-- Petición a toda la hermandad: devuelve "sent" (en cola o esperando a poder salir), "recent" (salió hace menos de
-- 10 min, en esta cuenta), "off" (este PC no sube precios o el historial está apagado), "notready" (sin hermandad o
-- mercado) o "busy" (cola llena).
function Relay.Ask()
  if not db or not cdb or not History.Hist() or not Relay.UploaderMode() then return "off" end
  local key = marketNow()
  local t = unixNow()
  if not (salt() and key and t) then return "notready" end
  if askPending then return "sent" end
  if db.lastAsk and t >= db.lastAsk and t - db.lastAsk < ASK_COOLDOWN then return "recent" end
  askPending = true
  armAsk()
  return askPending and "sent" or "busy"
end

local function sendTarget(sender, h)
  local key, mk = marketNow()
  local t = unixNow()
  local market = key and History.Market(key)
  local entry = market and type(market.obs) == "table" and market.obs[h] or nil
  if not (entry and t) then return end
  local id = nextWindowId("t")
  local msgs = Relay.PackQ3(nextSeq(), mk, max(t - ASK_SECONDS, entry.seen), {})
  local queued = Guild.EnqueueRelay(msgs, "WHISPER", sender, TTL.target, function()
    targets[h] = {id = id, untilAt = clock() + WINDOW}
  end)
  if queued then
    askedAt[h], lastTarget = clock(), clock()
    targetLog[#targetLog + 1] = clock()
  end
end

-- Peticiones por susurro pendientes: una cada 30 s y 20 por hora como mucho.
local function pumpTargets()
  targetTimer = false
  local c = clock()
  local recent = {}
  for _, at in ipairs(targetLog) do if c - at < 3600 then recent[#recent + 1] = at end end
  targetLog = recent
  while #pendingTargets > 0 do
    local wait = lastTarget + TARGET_SPACING - c
    if #targetLog >= TARGET_PER_HOUR then wait = max(wait, targetLog[1] + 3600 - c) end
    if wait > 0 then
      targetTimer = true
      after(wait, function() protect("petición", pumpTargets) end)
      return
    end
    local p = table.remove(pendingTargets, 1)
    if p.follow or not (askedAt[p.hash] and c - askedAt[p.hash] < TARGET_COOLDOWN) then
      sendTarget(p.sender, p.hash)
      c = clock()
    end
  end
end

-- follow: lo que faltaba de una respuesta llena (no espera los 30 min de cada compañero).
local function queueTarget(sender, h, follow)
  for _, p in ipairs(pendingTargets) do if p.hash == h then return end end
  if #pendingTargets >= TARGET_PER_HOUR then return end
  pendingTargets[#pendingTargets + 1] = {sender = sender, hash = h, follow = follow}
  if not targetTimer then pumpTargets() end
end

-- Un compañero acaba de anunciarse a la hermandad (H2 o R2: suele ser que acaba de entrar). Si este PC sube precios y
-- ese compañero compartió algo en los últimos 14 días, se le piden por susurro los escaneos que nos perdimos.
local function onPeer(sender, kind, channel)
  if channel ~= "GUILD" or not loggedIn or not db or not History.Hist() or not Relay.UploaderMode() then return end
  local s = salt()
  local key = History.CurrentMarket()
  local t = unixNow()
  local h = s and senderHash(sender, s)
  if not (h and key and t) or h == ownHash(s) then return end
  local market = History.Market(key)
  local entry = market and type(market.obs) == "table" and market.obs[h] or nil
  if not entry or entry.seen < t - TARGET_RECENT then return end
  if askedAt[h] and clock() - askedAt[h] < TARGET_COOLDOWN then return end
  queueTarget(sender, h, false)
end

function Relay.OnPeer(sender, kind, channel) protect("compañero", onPeer, sender, kind, channel) end

-- Una respuesta llegó llena: pasados los 11 min en los que quien respondió no vuelve a responder, se pide lo que le
-- queda (a toda la hermandad si fue la petición general, que solo contestan quienes tienen algo nuevo; solo a él si
-- fue por susurro). Cada vez avanza lo que ya se tiene y cada buzón guarda 32 escaneos como mucho: se acaba sola.
local function followUpAsk(tries)
  if not loggedIn or not Relay.UploaderMode() then return end
  local result = Relay.Ask()
  local t = unixNow()
  if (result == "recent" or result == "busy") and tries < 3 and t then
    -- Otra petición salió entretanto (/oro sync) o la cola está llena: se repite al acabar su espera.
    local wait = result == "recent" and (db.lastAsk + ASK_COOLDOWN - t + 60) or FOLLOW_UP
    after(max(5, wait), function() protect("petición", followUpAsk, tries + 1) end)
  end
end

scheduleFollowUp = function(win, h, sender)
  if win:sub(1, 1) == "b" then
    if followAsk then return end
    followAsk = true
    after(FOLLOW_UP, function()
      followAsk = false
      protect("petición", followUpAsk, 0)
    end)
  elseif not followTarget[h] then
    followTarget[h] = true
    after(FOLLOW_UP, function()
      followTarget[h] = nil
      protect("petición", function()
        if loggedIn and Relay.UploaderMode() then queueTarget(sender, h, true) end
      end)
    end)
  end
end

---------------------------------------------------------------------------
-- API del addon
---------------------------------------------------------------------------
local function sanitizeDB(saved)
  local r = type(saved) == "table" and saved or {}
  if r.subidor ~= "on" and r.subidor ~= "off" and r.subidor ~= "auto" then r.subidor = "auto" end
  if type(r.share) ~= "boolean" then r.share = true end
  if not isInt(r.lastAsk, 1, TIME_MAX) then r.lastAsk = nil end
  return r
end

local function sanitizeCDB(saved, t)
  local r = type(saved) == "table" and saved or {}
  r.v = 1
  if not isInt(r.seq, 0, 1295) then r.seq = 0 end
  if not isInt(r.lastSent, 1, TIME_MAX) then r.lastSent = nil end
  if not isInt(r.sent, 1, TIME_MAX) then r.sent = nil end
  local out = {}
  for _, scan in ipairs(type(r.out) == "table" and r.out or {}) do
    if type(scan) == "table" and isInt(scan.t, 1, TIME_MAX) and isHash(scan.mk) and validTokens(scan.items) then
      out[#out + 1] = {t = scan.t, mk = scan.mk, items = scan.items}
    end
  end
  r.out = pruneOutbox(out, t)
  return r
end

-- En ADDON_LOADED, después de History.Load: ajustes de la cuenta (OroHermandadDB.relay: subidor, share, lastAsk) y
-- del personaje (OroHermandadCharDB.relay: seq, lastSent, sent y el buzón out de 72 h).
function Relay.Init(accountDB, charDB)
  accountDB.relay = sanitizeDB(accountDB.relay)
  charDB.relay = sanitizeCDB(charDB.relay, unixNow())
  db, cdb = accountDB.relay, charDB.relay
  Guild.SetRelayHandler(Relay.OnMessage)
  Guild.OnPeerSeen(Relay.OnPeer)
  History.OnScanRecorded(Relay.OnScan)
end

-- 25 s después de entrar (la hermandad ya está identificada y su anuncio H2/R2 ya salió): se mira el aviso del
-- subidor, se apunta tu código y, en el PC que sube precios, se pide a la hermandad lo que se perdió. También sale un
-- escaneo de antes del /reload que aún no se compartió.
function Relay.Login()
  protect("entrada", function()
    if not db then return end
    loggedIn = true
    markerSeen = Relay.MarkerDetected()
    local key = History.CurrentMarket()
    if key and History.Hist() then recordSelf(key) end
    if Relay.UploaderMode() then Relay.Ask() end
    maybeBroadcast()
  end)
end

-- /oro subidor on|off|auto (nil = solo consultar). Devuelve el modo y si se ve el aviso del PC.
function Relay.SetSubidor(mode)
  if not db then return nil end
  markerSeen = Relay.MarkerDetected()
  if mode == "on" or mode == "off" or mode == "auto" then
    db.subidor = mode
    if loggedIn and Relay.UploaderMode() then Relay.Ask() end
  end
  return db.subidor, markerSeen
end

-- /oro compartir on|off. Al apagarlo se vacía el buzón de este personaje, se quitan de la cola tus escaneos que aún
-- no habían salido (en directo o en respuestas) y no sale nada más de lo tuyo.
function Relay.SetShare(on)
  if not db then return nil end
  db.share = on and true or false
  if not db.share then
    if cdb then cdb.out = {} end
    replies = {}
    if type(Guild.DropRelay) == "function" then
      Guild.DropRelay(function(msg) return type(msg) == "string" and msg:sub(1, 3) == "P3|" end)
    end
  end
  return db.share
end

function Relay.Share() return shareOn() end

-- Compañeros con precios en el mercado actual y la hora de su escaneo más nuevo.
local function mates()
  local key = History.CurrentMarket()
  local market = key and History.Market(key)
  local n, newest = 0, nil
  for _, entry in pairs(market and type(market.obs) == "table" and market.obs or {}) do
    n = n + 1
    newest = max(newest or 0, entry.seen)
  end
  return n, newest
end
Relay.Mates = mates

local function subidorText()
  local mode = db and db.subidor or "auto"
  if mode == "on" then return "siempre activado" end
  if mode == "off" then return "desactivado" end
  return "automático (aviso del PC: " .. (Relay.MarkerDetected() and "sí" or "no") .. ")"
end

-- /oro sondeo: una línea, sin nombres ni códigos.
function Relay.ProbeLine()
  local n, newest = mates()
  local t = unixNow()
  local h = History.Hist()
  local size = h and History.ObsSize(h) or 0
  return "Precios compartidos: " .. plural(n, "compañero", "compañeros") .. " en este mercado"
    .. ((newest and t) and (", último escaneo recibido " .. agoText(t - newest)) or "")
    .. " · esta sesión: " .. plural(stats.received, "recibido", "recibidos") .. ", "
    .. plural(stats.dropped, "descartado", "descartados")
    .. " · en cola: " .. plural(Guild.RelayQueued(), "mensaje", "mensajes")
    .. " · subidor: " .. subidorText() .. " · compartir: " .. (shareOn() and "sí" or "no")
    .. " · " .. string.format("%.0f", size / 1024) .. " KB de " .. floor(History.OBS_MAX_BYTES / 1024) .. " KB"
end

-- /oro estado: cuántos compañeros comparten precios contigo en este mercado.
function Relay.StatusLine()
  if not History.Hist() then return "precios compartidos: el historial de precios está apagado en esta sesión." end
  local n, newest = mates()
  local t = unixNow()
  local text
  if n == 0 then
    text = "precios compartidos: aún no ha llegado ninguno de la hermandad en este mercado."
  else
    text = "precios compartidos: " .. plural(n, "compañero", "compañeros") .. " en este mercado"
      .. ((newest and t) and (" (el último escaneo, " .. agoText(t - newest) .. ")") or "") .. "."
  end
  return text .. " Compartir tus escaneos: " .. (shareOn() and "sí" or "no") .. " · subidor: " .. subidorText() .. "."
end

-- Para las pruebas: contadores y estado interno.
function Relay.Stats() return stats end
function Relay.Internals()
  return {open = open, openCount = openCount, inbox = inbox, applying = applying, replies = replies,
          pendingTargets = pendingTargets, broadcastWin = broadcastWin, targets = targets, cache = cache,
          askPending = askPending, followAsk = followAsk, maxOpen = MAX_OPEN}
end

return Relay

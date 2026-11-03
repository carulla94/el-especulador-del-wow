-- Oro de Hermandad: historial de precios de la lista vigilada (OroHermandadHist, contrato 2 de Especular).
-- Graba una vela por día y puntos de escaneo con los escaneos terminados de Auctionator, rellena una vez al día los
-- días que faltan con el historial de Auctionator, aprende los depósitos con la subasta abierta y prepara
-- /oro tabla y /oro sondeo. El formato y las reglas están en Spec.lua; aquí solo está el lado de WoW.
-- Lo que pasa Auctionator con sus eventos y su base de precios no es API pública: cada campo se comprueba y todo
-- va en pcall. Los escaneos grandes se procesan por tandas con C_Timer para que el juego no se trabe.
-- OroHermandadHist es lo único que el subidor de la hermandad saca del PC: solo lleva objetos vigilados (precios,
-- nombre del objeto, precio de mercader, categoría y depósitos) por mercado. Nunca nombres de personajes, oro,
-- profesiones ni nada de OroHermandadDB u OroHermandadCharDB.
local _, ns = ...
local Data, Items, Spec, Prices = ns.Data, ns.Items, ns.Spec, ns.Prices
local History = {}
ns.History = History

History.SCHEMA = 1
History.ROWS_PER_TICK = 2000   -- filas de un escaneo por tanda: 100 000 filas de un escaneo completo, unas 50 tandas
History.ITEMS_PER_TICK = 4     -- objetos que se escriben por tanda al acabar de leer un escaneo (lo normal es tocar
                               -- solo el último registro; por el camino largo, con 120 días, unos 3 ms cada uno)
History.IMPORT_PER_TICK = 5    -- objetos por tanda al leer el historial de Auctionator (deserializa CBOR en cada uno)
History.DEPOSITS_PER_TICK = 5  -- objetos por tanda al preguntar depósitos a la subasta
History.TICK = 0               -- espera entre tandas, en segundos (0 = el siguiente fotograma)
History.DURATIONS = 3          -- duraciones de subasta (luaIndex 1..3)
History.EXTRA_MAX = Data.WATCH_EXTRA_MAX or 40
History.MAX_QUEUE = 8          -- escaneos esperando turno; más (no debería pasar) se descartan
local SAME_SCAN_SECONDS = 1800 -- el mismo resultado otra vez en menos de 30 min es el mismo escaneo
local MAX_ERRORS = 20          -- errores sueltos que se toleran por trabajo antes de dejarlo
local NAME_MAX = 100

local floor, max, min = math.floor, math.max, math.min
local isInt = Spec.IsInt

local hist                     -- OroHermandadHist (la tabla viva que el juego guarda al salir)
local db = {}                  -- OroHermandadDB: estado privado (extras vigilados, día de la última importación)
local marketKeyFn              -- función de Core que da "Reino-Facción"
local version = "0.3.0"
local loadInfo = {}            -- cómo se cargó OroHermandadHist (para /oro sondeo)
local shapes = {}              -- tipo de escaneo -> forma de su primera fila (para /oro sondeo)
local queue, running = {}, nil
local lastScan = {}            -- mercado -> {sig, t, d} del último escaneo grabado
local seen = setmetatable({}, {__mode = "k"}) -- tablas de escaneo ya recibidas
local knownCache = {}
local depositsDone = {}
local importing, depositing = false, false
local normalized = false       -- los textos se normalizaron al cargar (si no, las escrituras van por el camino largo)

History.lastResult, History.lastImport, History.lastDeposits, History.lastError = nil, nil, nil, nil

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------
local isSecret = type(issecretvalue) == "function" and issecretvalue or nil
local function readable(value)
  if isSecret and isSecret(value) then return nil end
  return value
end

local function now()
  if type(GetServerTime) == "function" then
    local ok, t = pcall(GetServerTime)
    if ok and isInt(t, 1, Spec.TIME_MAX) then return t end
  end
  if type(time) == "function" then
    local ok, t = pcall(time)
    if ok and isInt(t, 1, Spec.TIME_MAX) then return t end
  end
  return nil
end
History.Now = now

-- Siguiente tanda. Sin C_Timer (no pasa en el juego) se sigue en el acto.
local function schedule(fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    C_Timer.After(History.TICK, fn)
  else
    fn()
  end
end

-- Aviso a Core cuando el historial ya tiene algo nuevo escrito: un escaneo grabado, días traídos de Auctionator o
-- depósitos aprendidos. Todo eso termina varias tandas después del evento que lo empezó, así que la ventana y las
-- descripciones se repintan aquí, con lo escrito, y no con lo de antes. Un fallo de quien escucha no para el trabajo.
local onChange
function History.OnChange(fn) onChange = type(fn) == "function" and fn or nil end
local function changed()
  if not onChange then return end
  local ok, err = pcall(onChange)
  if not ok then History.lastError = tostring(err) end
end

-- Precio positivo -> cobre entero (al más cercano; los del escaneo completo son compra ya / cantidad y pueden
-- tener decimales), o nil si no es un precio válido.
local function copper(value)
  value = readable(value)
  if type(value) ~= "number" or value ~= value or value <= 0 or value > Spec.PRICE_MAX then return nil end
  return max(1, floor(value + 0.5))
end

local function quantity(value)
  value = readable(value)
  if type(value) ~= "number" or value ~= value or value < 0 or value > Spec.QTY_MAX then return nil end
  return floor(value)
end

local function itemID(value)
  value = readable(value)
  if type(value) ~= "number" then return nil end
  return Items.ID(value)
end

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

-- Nombre de objeto de NAME_MAX bytes como mucho, sin cortar una letra de UTF-8 por la mitad (el subidor del PC lee
-- este archivo como UTF-8).
local function clip(name)
  if #name <= NAME_MAX then return name end
  return (name:sub(1, NAME_MAX):gsub("[\192-\255][\128-\191]*$", ""))
end

-- "Reino-Facción", como lo valida el servidor de la hermandad: reino sin «|» de 1 a 64 letras y Alliance u Horde.
local function validMarketKey(key)
  if type(key) ~= "string" then return false end
  local realm, faction = key:match("^(.+)%-(%a+)$")
  return realm ~= nil and #realm <= 64 and not realm:find("|", 1, true) and (faction == "Alliance" or faction == "Horde")
end
History.ValidMarketKey = validMarketKey

local function rawMarketKey()
  if type(marketKeyFn) ~= "function" then return nil end
  local ok, key = pcall(marketKeyFn)
  return ok and key or nil
end

local function currentKey()
  local key = rawMarketKey()
  if validMarketKey(key) then return key end
  return nil
end

---------------------------------------------------------------------------
-- Lista vigilada
---------------------------------------------------------------------------
local FIXED, FIXED_ORDER = {}, {}
for _, cat in ipairs(Data.CATEGORY_ORDER or Spec.CATEGORIES) do
  for _, id in ipairs(Data.WATCH and Data.WATCH[cat] or {}) do
    if not FIXED[id] and Spec.IsCategory(cat) then FIXED[id] = cat; FIXED_ORDER[#FIXED_ORDER + 1] = id end
  end
end
local CATEGORY_RANK = {}
for i, cat in ipairs(Spec.CATEGORIES) do CATEGORY_RANK[cat] = i end

-- ¿Lo conoce el cliente? C_Item.GetItemInfoInstant responde sin preguntar al servidor y no devuelve nada si el ID
-- no existe (C_Item.DoesItemExistByID no sirve para eso en Forever). Sin esa función se da por bueno.
local function instantKnown(id)
  local known = knownCache[id]
  if known ~= nil then return known end
  local get = (type(C_Item) == "table" and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
  known = true
  if type(get) == "function" then
    local ok, got = pcall(get, id)
    known = ok and readable(got) ~= nil
  end
  knownCache[id] = known
  return known
end

-- Categoría de un extra según su clase y subclase de objeto (las de Classic).
local TRADE_CATEGORY = {[4] = "gema", [5] = "tela", [6] = "piel", [7] = "metal", [8] = "comida", [9] = "hierba",
                        [10] = "elemental", [12] = "encantar"}
local CONSUMABLE_CATEGORY = {[1] = "pocion", [2] = "elixir", [3] = "frasco", [5] = "comida", [7] = "venda"}
local function guessCategory(id)
  local ok, _, classID, subclassID = pcall(Items.Instant, id)
  if not ok then return "otro" end
  if classID == 7 then return TRADE_CATEGORY[subclassID] or "otro" end
  if classID == 0 then return CONSUMABLE_CATEGORY[subclassID] or "otro" end
  if classID == 3 then return "gema" end
  return "otro"
end
History.GuessCategory = guessCategory

local function extras()
  if type(db.watchExtra) ~= "table" then db.watchExtra = {} end
  return db.watchExtra
end

local function extraIDs()
  local ids = {}
  for id, on in pairs(extras()) do
    if on and Items.ID(id) == id and not FIXED[id] then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

function History.IsFixed(id) return FIXED[id] ~= nil end
function History.FixedIDs() return FIXED_ORDER end
function History.ExtraIDs() return extraIDs() end

-- Objetos vigilados que el cliente reconoce: {{id, cat, fixed}, ...}, los fijos en orden de categoría y los extras
-- al final.
function History.WatchList()
  local list = {}
  for _, id in ipairs(FIXED_ORDER) do
    if instantKnown(id) then list[#list + 1] = {id = id, cat = FIXED[id], fixed = true} end
  end
  for _, id in ipairs(extraIDs()) do
    if instantKnown(id) then list[#list + 1] = {id = id, cat = guessCategory(id), fixed = false} end
  end
  return list
end

-- IDs de la lista fija que el cliente no reconoce (para corregir la lista).
function History.Unknown()
  local out = {}
  for _, id in ipairs(FIXED_ORDER) do if not instantKnown(id) then out[#out + 1] = id end end
  return out
end

-- updated: última vez que el addon escribió algo en ese mercado (escaneo, importación o depósitos).
local function marketFor(key, create)
  if not hist or not key then return nil end
  local market = hist.markets[key]
  if not market and create then
    market = {items = {}, dep = {}, updated = now()}
    hist.markets[key] = market
  end
  return market
end

local function touch(market, t)
  market.updated = t or market.updated
  local cut = Prices.LearnedCut and Prices.LearnedCut()
  if type(cut) == "number" and cut >= 0 and cut < 1 then market.cut = floor(cut * 10000 + 0.5) end
end

-- Entrada del objeto en el mercado, con su nombre, categoría y precio de mercader al día.
local function itemFor(market, id, cat)
  local item = market.items[id]
  if not item then
    item = {d = "", p = ""}
    market.items[id] = item
  end
  local name = Items.Name(id)
  if type(name) == "string" and name ~= "" then
    item.n = clip(name)
  elseif type(item.n) ~= "string" or item.n == "" then
    item.n = Data.FALLBACK_NAMES[id] or ""
  end
  item.c = Spec.IsCategory(cat) and cat or (Spec.IsCategory(item.c) and item.c or "otro")
  local sell = Items.SellPrice(id)
  if isInt(sell, 0, Spec.PRICE_MAX) then item.v = sell elseif not isInt(item.v, 0, Spec.PRICE_MAX) then item.v = 0 end
  return item
end

-- /oro vigilar: devuelve "added", "already", "fixed", "full", "unknown", "invalid" o "off" (historial apagado).
function History.Watch(id)
  id = Items.ID(id)
  if not id then return "invalid" end
  if FIXED[id] then return "fixed" end
  if not hist then return "off" end
  local extra = extras()
  if extra[id] then return "already" end
  if not instantKnown(id) then return "unknown" end
  if #extraIDs() >= History.EXTRA_MAX then return "full" end
  extra[id] = true
  History.Import(true, {id})
  return "added"
end

-- /oro olvidar: deja de vigilar un extra y borra su historial en todos los mercados.
-- Devuelve "removed", "fixed", "notwatched" o "invalid".
function History.Unwatch(id)
  id = Items.ID(id)
  if not id then return "invalid" end
  if FIXED[id] then return "fixed" end
  local extra = extras()
  if not extra[id] then return "notwatched" end
  extra[id] = nil
  if hist then
    for _, market in pairs(hist.markets) do
      market.items[id] = nil
      market.dep[id] = nil
    end
  end
  return "removed"
end

---------------------------------------------------------------------------
-- Carga y guardado
---------------------------------------------------------------------------
-- Copia limpia de lo que se cargó del archivo: mercados válidos, objetos con ID numérico, campos del tipo correcto.
-- Los textos de días y puntos se dejan tal cual: Spec.PruneHist los decodifica y se salta lo que esté mal.
local function sanitize(saved)
  local out = {schema = History.SCHEMA, addon = version, markets = {}}
  local markets = type(saved) == "table" and saved.schema == History.SCHEMA and type(saved.markets) == "table"
    and saved.markets or {}
  for key, market in pairs(markets) do
    if validMarketKey(key) and type(market) == "table" then
      local clean = {items = {}, dep = {}}
      if isInt(market.updated, 1, Spec.TIME_MAX) then clean.updated = market.updated end
      if isInt(market.cut, 0, 9999) then clean.cut = market.cut end
      for id, item in pairs(type(market.items) == "table" and market.items or {}) do
        if type(id) == "number" and Items.ID(id) == id and type(item) == "table" then
          clean.items[id] = {
            n = type(item.n) == "string" and clip(item.n) or "",
            c = Spec.IsCategory(item.c) and item.c or "otro",
            v = isInt(item.v, 0, Spec.PRICE_MAX) and item.v or 0,
            d = type(item.d) == "string" and item.d or "",
            p = type(item.p) == "string" and item.p or "",
          }
        end
      end
      for id, text in pairs(type(market.dep) == "table" and market.dep or {}) do
        if type(id) == "number" and Items.ID(id) == id then
          local encoded = Spec.EncodeDeposits(Spec.DecodeDeposits(text))
          if encoded ~= "" then clean.dep[id] = encoded end
        end
      end
      out.markets[key] = clean
    end
  end
  return out
end

local function countItems(market)
  local n = 0
  for _ in pairs(market and market.items or {}) do n = n + 1 end
  return n
end

-- En ADDON_LOADED. saved: lo que el juego cargó en OroHermandadHist (nil si nada). opts: db (OroHermandadDB ya
-- preparado), market (función "Reino-Facción"), version, dbLoaded (OroHermandadDB venía del archivo).
-- Limpia, poda (120 días, 14 días de puntos) y deja el total en 512 KB o menos. Devuelve la tabla que debe quedar en
-- OroHermandadHist.
function History.Load(saved, opts)
  opts = opts or {}
  db = type(opts.db) == "table" and opts.db or {}
  marketKeyFn = opts.market
  version = type(opts.version) == "string" and opts.version or version
  local t = now()
  loadInfo = {loaded = type(saved) == "table", dbLoaded = opts.dbLoaded and true or false,
              hadHist = db.histSince ~= nil, at = t}
  db.watchExtra = type(db.watchExtra) == "table" and db.watchExtra or {}
  db.histImport = type(db.histImport) == "table" and db.histImport or {}
  if type(saved) == "table" and type(saved.schema) == "number" and saved.schema > History.SCHEMA then
    -- De una versión más nueva del addon: no se toca, por si se vuelve a ella.
    loadInfo.newer = saved.schema
    hist = nil
    return saved
  end
  loadInfo.badSchema = type(saved) == "table" and saved.schema ~= History.SCHEMA
  hist = sanitize(saved)
  normalized = false
  if t then
    local ok, removed = pcall(Spec.PruneHist, hist, t)
    loadInfo.pruned = ok and removed or nil
    normalized = ok
    local okShrink, step, size = pcall(Spec.Shrink, hist, Spec.MAX_BYTES, t)
    if okShrink then loadInfo.shrinkStep, loadInfo.size = step, size end
    db.histSince = db.histSince or t
  end
  local items = 0
  for _, market in pairs(hist.markets) do items = items + countItems(market) end
  loadInfo.items = items
  return hist
end

function History.Hist() return hist end
function History.LoadInfo() return loadInfo end

-- En PLAYER_LOGOUT, antes de que el juego escriba el archivo: el tope de 512 KB también para lo de esta sesión.
function History.BeforeSave()
  if not hist then return nil end
  hist.schema, hist.addon = History.SCHEMA, version
  local t = now()
  if not t then return nil end
  local step, size = Spec.Shrink(hist, Spec.MAX_BYTES, t)
  return step, size
end

-- ¿Sobrevivió OroHermandadHist al último /reload? Detecta el fallo de Forever que guarda los SavedVariables pero no
-- los carga.
function History.SurvivalText()
  if loadInfo.newer then
    return "OroHermandadHist es de una versión más nueva del addon (esquema " .. loadInfo.newer .. "): no se toca."
  end
  if loadInfo.loaded and not loadInfo.badSchema then
    return "sí: OroHermandadHist se cargó del archivo guardado (" .. plural(loadInfo.items or 0, "objeto", "objetos") .. ")."
  end
  if loadInfo.dbLoaded and loadInfo.hadHist then
    return "NO: OroHermandadDB se cargó, pero OroHermandadHist no. Si acabas de actualizar el addon, sal del juego del todo "
      .. "y vuelve a entrar; si vuelve a pasar, es el fallo de Forever que no carga los SavedVariables."
  end
  if loadInfo.dbLoaded then
    return "primera sesión con historial: haz /reload y vuelve a escribir /oro sondeo para comprobar que se guarda."
  end
  return "no se cargó nada guardado (ni OroHermandadDB): es la primera vez con el addon o el juego no carga los "
    .. "SavedVariables. Haz /reload y repite /oro sondeo: si vuelve a salir esto, es el fallo de Forever."
end

---------------------------------------------------------------------------
-- Escaneos
---------------------------------------------------------------------------
local TYPE_NAMES = {string = "texto", number = "número", boolean = "sí/no", table = "tabla", ["nil"] = "nada",
                    ["function"] = "función"}
local function typeName(value) return TYPE_NAMES[type(value)] or type(value) end

local function numberText(value)
  value = readable(value)
  if type(value) ~= "number" then return typeName(value) end
  return tostring(value)
end

-- Forma de la primera fila de un escaneo: tipos de cada campo y solo los números que hacen falta para comprobar el
-- significado (cantidad, compra ya, itemID, precio mínimo). Ni nombres de vendedores ni de objetos.
local function describeShape(kind, data)
  local ok, text = pcall(function()
    local row = data[1]
    if type(row) ~= "table" then return "primera fila: " .. typeName(row) end
    local keys, n = {}, 0
    for k, v in pairs(row) do
      n = n + 1
      if n <= 12 then keys[#keys + 1] = tostring(k) .. "=" .. typeName(v) end
    end
    table.sort(keys)
    local out = "{" .. table.concat(keys, ", ") .. (n > 12 and ", …" or "") .. "}"
    local info, key = row.replicateInfo, row.itemKey
    if type(info) == "table" then
      local fields = {}
      for i = 1, 18 do fields[i] = i .. " " .. typeName(info[i]) end
      out = out .. " · replicateInfo: " .. table.concat(fields, ", ") .. " · [3] cantidad " .. numberText(info[3])
        .. ", [10] compra ya " .. numberText(info[10]) .. ", [17] itemID " .. numberText(info[17])
    elseif type(key) == "table" then
      local fields = {}
      for k, v in pairs(key) do fields[#fields + 1] = tostring(k) .. "=" .. typeName(v) end
      table.sort(fields)
      out = out .. " · itemKey {" .. table.concat(fields, ", ") .. "} · itemID " .. numberText(key.itemID)
        .. ", minPrice " .. numberText(row.minPrice) .. ", totalQuantity " .. numberText(row.totalQuantity)
    end
    return out
  end)
  shapes[kind or "?"] = {text = ok and text or "no se pudo leer la primera fila", rows = #data, at = now()}
end

local function add(job, id, unit, n, withLots)
  local a = job.agg[id]
  if not a then
    a = {lo = unit, qty = 0, qty5 = 0, lots = withLots and {} or nil}
    job.agg[id] = a
  end
  if unit < a.lo then a.lo = unit end
  a.qty = min(Spec.QTY_MAX, a.qty + n)
  if withLots then
    local lots, k = a.lots, #a.lots
    lots[k + 1], lots[k + 2] = unit, n
  end
end

-- Una fila del escaneo. Completo (replicate): {replicateInfo = {[3] cantidad, [10] compra ya del lote, [14] vendedor,
-- [17] itemID, ...}, itemLink, timeLeft}. Resumen: BrowseResultInfo {itemKey = {itemID, battlePetSpeciesID, ...},
-- minPrice, totalQuantity, containsOwnerItem}. job.read cuenta las filas con forma reconocible, se vigilen o no.
local function consume(job, row)
  if type(row) ~= "table" then return end
  local info, key = row.replicateInfo, row.itemKey
  if type(info) == "table" then
    local n, id = quantity(info[3]), itemID(info[17])
    if not (n and id) then return end
    job.read = job.read + 1
    if not job.watched[id] or n < 1 then return end
    local buyout = readable(info[10])
    if type(buyout) ~= "number" or not (buyout > 0) then return end -- solo puja: no hay precio de compra
    if job.me and readable(info[14]) == job.me then return end      -- tus subastas no son el precio del mercado
    local unit = copper(buyout / n)
    if unit then add(job, id, unit, n, true) end
  elseif type(key) == "table" then
    local id, price, n = itemID(key.itemID), copper(row.minPrice), quantity(row.totalQuantity)
    if not (id and price and n) then return end
    job.read = job.read + 1
    local pet = readable(key.battlePetSpeciesID)
    if not job.watched[id] or n < 1 or (type(pet) == "number" and pet > 0) then return end
    add(job, id, price, n, false)
  end
end

-- Escaneo entero sin filas que entender (Auctionator no las pasa o cambió su forma): el precio que Auctionator
-- acaba de guardar, solo de lo visto hoy. Va a la vela del día con la cantidad desconocida y sin punto.
local function fallback(job)
  job.fallback = true
  for id in pairs(job.watched) do
    local price = copper(Prices.Price(id))
    if price and Prices.Age(id) == 0 then job.agg[id] = {lo = price, qty = 0, qty5 = 0, noPoint = true} end
  end
end

local function prepare(job)
  if job.whole and job.read == 0 then fallback(job) end
  local ids = {}
  for id, a in pairs(job.agg) do
    ids[#ids + 1] = id
    if a.lots then
      local qty5 = 0
      for i = 1, #a.lots, 2 do
        if a.lots[i] * 100 <= a.lo * 105 then qty5 = qty5 + a.lots[i + 1] end
      end
      a.qty5, a.lots = min(Spec.QTY_MAX, qty5), nil
    end
  end
  table.sort(ids)
  job.ids, job.writeIndex = ids, 1
  -- El mismo resultado otra vez (Auctionator avisa dos veces, o se repite el escaneo sin cambios en la subasta)
  -- no se cuenta dos veces: RecordScan suma un escaneo al día cada vez.
  local parts = {job.kind or "?", job.whole and "1" or "0"}
  for _, id in ipairs(ids) do
    local a = job.agg[id]
    parts[#parts + 1] = id .. ":" .. a.lo .. ":" .. a.qty .. ":" .. a.qty5
  end
  local sig = table.concat(parts, ",")
  local last = lastScan[job.market]
  if #ids == 0 or (last and last.sig == sig and last.d == job.d and job.t - last.t < SAME_SCAN_SECONDS) then
    job.duplicate = #ids > 0
    job.ids = {}
  else
    lastScan[job.market] = {sig = sig, t = job.t, d = job.d}
  end
end

-- Escritura de un escaneo en los textos de días y puntos. Los textos guardados ya están normalizados (los escribe
-- Spec.EncodeDays/EncodePoints, y la carga los vuelve a normalizar con Spec.PruneHist) y lo nuevo cae siempre al final,
-- así que basta con tocar el último registro: da exactamente el mismo texto que decodificar, normalizar y volver a
-- codificar todo (test_history.lua lo compara con miles de casos), sin crear unos 400 KB de basura por objeto. Si el
-- último registro no encaja (no es canónico, o el reloj fue hacia atrás), se hace por el camino largo.
History.FAST_WRITES = true

local function splitLast(text)
  local pos = text:match("^.*();")
  if pos then return text:sub(1, pos - 1), text:sub(pos + 1) end
  return "", text
end

local function countRecords(text)
  local _, separators = text:gsub(";", ";")
  return separators + 1
end

local function dropFirst(text)
  local pos = text:find(";", 1, true)
  return pos and text:sub(pos + 1) or ""
end

local function join(prefix, tail)
  if prefix == "" then return tail end
  if tail == "" then return prefix end
  return prefix .. ";" .. tail
end

function History.RecordDayText(text, d, p, qty)
  if History.FAST_WRITES and normalized and type(text) == "string" and text ~= "" then
    local prefix, lastText = splitLast(text)
    local decoded = Spec.DecodeDays(lastText)
    local last = decoded[1]
    if #decoded == 1 and Spec.EncodeDays(decoded) == lastText and last.d <= d then
      local tail = Spec.EncodeDays((Spec.RecordScan(decoded, d, p, qty)))
      local out = join(prefix, tail)
      if countRecords(out) > Spec.KEEP_DAYS then out = dropFirst(out) end
      return out
    end
  end
  return Spec.EncodeDays((Spec.RecordScan(Spec.DecodeDays(text), d, p, qty)))
end

function History.AddPointText(text, t, lo, qty, qty5)
  if History.FAST_WRITES and normalized and type(text) == "string" and text ~= "" then
    local prefix, lastText = splitLast(text)
    local decoded = Spec.DecodePoints(lastText)
    local last = decoded[1]
    if #decoded == 1 and Spec.EncodePoints(decoded) == lastText and isInt(t, 1, Spec.TIME_MAX) and t >= last.t then
      local tail = Spec.EncodePoints(Spec.AddPoint(decoded, t, lo, qty, qty5))
      local out = join(prefix, tail)
      if countRecords(out) > Spec.MAX_POINTS then out = dropFirst(out) end
      return out
    end
  end
  return Spec.EncodePoints(Spec.AddPoint(Spec.DecodePoints(text), t, lo, qty, qty5))
end

local function writeItem(job, market, id)
  local a = job.agg[id]
  local item = itemFor(market, id, job.watched[id])
  if job.whole then item.d = History.RecordDayText(item.d, job.d, a.lo, a.qty) end
  if not a.noPoint then item.p = History.AddPointText(item.p, job.t, a.lo, a.qty, a.qty5) end
end

-- Una tanda del trabajo en curso.
local function advance(job)
  if job.phase == "read" then
    local stop = min(job.index + History.ROWS_PER_TICK - 1, job.n)
    while job.index <= stop do
      local i = job.index
      job.index = i + 1 -- antes de leer: una fila que falla se salta y la siguiente tanda sigue después
      consume(job, job.data[i])
    end
    job.ticks = job.ticks + 1
    if job.index > job.n then job.phase = "prepare" end
  elseif job.phase == "prepare" then
    job.phase = "write" -- si prepare falla, no se repite: se escribe lo que haya
    prepare(job)
  elseif job.phase == "write" then
    if not hist then job.phase = "done"; return end
    local market = marketFor(job.market, true)
    local stop = min(job.writeIndex + History.ITEMS_PER_TICK - 1, #job.ids)
    while job.writeIndex <= stop do
      local id = job.ids[job.writeIndex]
      job.writeIndex = job.writeIndex + 1
      writeItem(job, market, id)
      job.written = job.written + 1
    end
    if job.writeIndex > #job.ids then
      if job.written > 0 then touch(market, job.t) end
      job.phase = "done"
    end
  end
end

local step
local function startNext()
  running = table.remove(queue, 1)
  if running then schedule(step) end
end

step = function()
  local job = running
  if not job then return end
  local ok, err = pcall(advance, job)
  if not ok then
    job.errors = job.errors + 1
    History.lastError = tostring(err)
    if job.errors > MAX_ERRORS then job.phase = "done" end
  end
  if job.phase == "done" then
    History.lastResult = {kind = job.kind, whole = job.whole, rows = job.n, read = job.read, items = job.written,
                          fallback = job.fallback, duplicate = job.duplicate, t = job.t, ticks = job.ticks,
                          errors = job.errors}
    running = nil
    if job.written > 0 then changed() end
    startNext()
  else
    schedule(step)
  end
end

-- Un escaneo de Auctionator ha terminado (Core.scanFinished). kind: "full" o "summary"; data: sus filas; whole: el
-- escaneo recorrió toda la subasta. Solo un escaneo entero escribe la vela del día; uno parcial (una búsqueda que
-- cortó el escaneo de resumen) solo añade puntos. Se procesa por tandas; devuelve true si queda algo que hacer.
function History.Record(kind, data, whole)
  if not hist then return false end
  if type(data) == "table" then
    if seen[data] then return false end
    seen[data] = true
    describeShape(kind, data)
  else
    data = nil
  end
  if not data and not whole then return false end
  local key, t = currentKey(), now()
  local d = t and Spec.DayIndex(t)
  if not (key and d) then return false end
  if #queue >= History.MAX_QUEUE then History.lastError = "demasiados escaneos en cola"; return false end
  local watched = {}
  for _, w in ipairs(History.WatchList()) do watched[w.id] = w.cat end
  local me = type(UnitName) == "function" and UnitName("player") or nil
  local job = {kind = kind, data = data, n = data and #data or 0, whole = whole and true or false, t = t, d = d,
               market = key, watched = watched, me = type(me) == "string" and me or nil, agg = {}, ids = {},
               index = 1, writeIndex = 1, read = 0, written = 0, errors = 0, ticks = 0, phase = "read"}
  queue[#queue + 1] = job
  if not running then startNext() end
  return true
end

-- Escaneos en marcha o esperando turno (0 = nada pendiente).
function History.Pending()
  local n = #queue
  if running then n = n + 1 end
  return n
end

---------------------------------------------------------------------------
-- Historial de Auctionator (una vez al día)
---------------------------------------------------------------------------
-- Filas de Auctionator.Database:GetPriceHistory (interno): {date, rawDay = "2499", minSeen, maxSeen, available}, de
-- la más nueva a la más vieja. Se pasan a enteros para Spec.ImportAuctionator. nil si no se puede leer.
local function auctionatorRows(id)
  local ok, rows = pcall(function()
    local database = _G.Auctionator.Database
    return database:GetPriceHistory(tostring(id))
  end)
  if not ok or type(rows) ~= "table" then return nil end
  local out = {}
  for i = 1, min(#rows, 200) do
    local row = rows[i]
    if type(row) == "table" then
      local day = tonumber(readable(row.rawDay))
      out[#out + 1] = {rawDay = isInt(day, 0, Spec.DAY_MAX) and day or nil, minSeen = copper(row.minSeen),
                       maxSeen = copper(row.maxSeen), available = quantity(row.available)}
    end
  end
  return out, rows
end
History.AuctionatorRows = auctionatorRows

-- ¿Tiene ya el texto de días el día d? Búsqueda rápida sin decodificar: los registros empiezan por "d,".
local function hasDay(text, d)
  local prefix = d .. ","
  return text:sub(1, #prefix) == prefix or text:find(";" .. prefix, 1, true) ~= nil
end

-- ¿Trae Auctionator algún día con precio que no tengamos? Si no, ni se decodifica (lo normal tras la primera vez).
local function needsImport(text, rows, today)
  if type(text) ~= "string" or text == "" then return true end
  for _, row in ipairs(rows) do
    local d = row.rawDay
    if d and d <= today and d > today - Spec.KEEP_DAYS and (row.minSeen or row.maxSeen) and not hasDay(text, d) then
      return true
    end
  end
  return false
end

local function databaseReady()
  local ok, ready = pcall(function()
    local database = _G.Auctionator.Database
    return type(database) == "table" and type(database.GetPriceHistory) == "function"
  end)
  return ok and ready == true
end

-- Rellena con el historial de Auctionator los días que no tenemos (src a, nunca pisa un día propio), unos pocos
-- objetos por tanda. Una vez al día por mercado salvo force; ids: solo esos objetos (un extra recién añadido).
-- Devuelve "started", "done" (ya se hizo hoy), "busy", "unavailable" (sin la base de Auctionator) o "off".
function History.Import(force, ids)
  if not hist then return "off" end
  local key, t = currentKey(), now()
  local today = t and Spec.DayIndex(t)
  if not (key and today) then return "off" end
  if not force and db.histImport[key] == today then return "done" end
  if importing then return "busy" end
  if not databaseReady() then return "unavailable" end
  local todo = {}
  if ids then
    for _, id in ipairs(ids) do todo[#todo + 1] = {id = id, cat = FIXED[id] or guessCategory(id)} end
  else
    todo = History.WatchList()
  end
  importing = true
  local index, added, touched = 1, 0, 0
  local function tick()
    local ok, err = pcall(function()
      local stop = min(index + History.IMPORT_PER_TICK - 1, #todo)
      while index <= stop do
        local w = todo[index]
        index = index + 1
        local rows = auctionatorRows(w.id)
        local market = marketFor(key)
        local current = market and market.items[w.id]
        if rows and #rows > 0 and needsImport(current and current.d, rows, today) then
          local list, n = Spec.ImportAuctionator(Spec.DecodeDays(current and current.d), rows, today)
          if n > 0 then
            market = market or marketFor(key, true)
            local item = itemFor(market, w.id, w.cat)
            item.d = Spec.EncodeDays(list)
            touch(market, t)
            added, touched = added + n, touched + 1
          end
        end
      end
    end)
    if not ok then History.lastError = tostring(err) end
    if index <= #todo and hist then
      schedule(tick)
    else
      importing = false
      if not ids then db.histImport[key] = today end
      History.lastImport = {t = t, days = added, items = touched, checked = #todo}
      if added > 0 then changed() end
    end
  end
  schedule(tick)
  return "started"
end

---------------------------------------------------------------------------
-- Lo que la subasta muestra al buscar un objeto vigilado (para el modo Especular)
---------------------------------------------------------------------------
-- COMMODITY_SEARCH_RESULTS_UPDATED / _ADDED (itemID): el jugador ha abierto ese objeto en la pestaña Comprar (o una
-- lista de la compra). Se guardan, solo durante la sesión, sus lotes {precio por unidad, cantidad} sin tus propias
-- unidades (numOwnerItems): con ellos el motor calcula el chollo con el libro de verdad («precio confirmado»).
-- Una lista vacía también vale: no hay nada a la venta. Devuelve true si se guardó algo.
History.BOOK_LOTS = 200
local books = {}
function History.CaptureBook(id)
  id = itemID(id)
  if not id or not hist or not (FIXED[id] or extras()[id]) then return false end
  local api = type(C_AuctionHouse) == "table" and C_AuctionHouse or nil
  if not api or type(api.GetNumCommoditySearchResults) ~= "function" or type(api.GetCommoditySearchResultInfo) ~= "function" then
    return false
  end
  local okCount, count = pcall(api.GetNumCommoditySearchResults, id)
  count = okCount and quantity(count) or nil
  if not count then return false end
  local lots = {}
  for i = 1, min(count, History.BOOK_LOTS) do
    local ok, info = pcall(api.GetCommoditySearchResultInfo, id, i)
    if ok and type(info) == "table" then
      local price, qty, own = copper(info.unitPrice), quantity(info.quantity), quantity(info.numOwnerItems) or 0
      if price and qty and qty - own > 0 then lots[#lots + 1] = {price, qty - own} end
    end
  end
  table.sort(lots, function(x, y) return x[1] < y[1] end)
  books[id] = {at = now(), lots = lots}
  return true
end

-- {[id] = {at, lots}} de esta sesión (el motor solo usa los de los últimos 5 minutos).
function History.Books() return books end

---------------------------------------------------------------------------
-- Depósitos (con la subasta abierta)
---------------------------------------------------------------------------
-- C_AuctionHouse.CalculateCommodityDeposit(itemID, duración luaIndex 1..3, cantidad) -> cobre (o nil). Se guarda el
-- de 1 unidad por duración: market.dep[id] = "1:60,2:120,3:240". Una vez por sesión y objeto; lo que no responde (una
-- pieza que no es mercancía, o la subasta aún sin datos) se vuelve a preguntar en la siguiente visita.
local function depositsOf(id)
  local calc = type(C_AuctionHouse) == "table" and C_AuctionHouse.CalculateCommodityDeposit
  if type(calc) ~= "function" then return nil end
  local out, any = {}, false
  for dur = 1, History.DURATIONS do
    local ok, cost = pcall(calc, id, dur, 1)
    cost = ok and readable(cost) or nil
    if type(cost) == "number" and cost == cost and cost >= 0 and cost <= Spec.PRICE_MAX then
      out[dur], any = floor(cost + 0.5), true
    end
  end
  return any and out or nil
end
History.DepositsOf = depositsOf

-- Devuelve "started", "closed" (subasta cerrada), "busy", "unavailable" u "off".
function History.LearnDeposits()
  if not hist then return "off" end
  if type(C_AuctionHouse) ~= "table" or type(C_AuctionHouse.CalculateCommodityDeposit) ~= "function" then return "unavailable" end
  if not Prices.AuctionHouseOpen() then return "closed" end
  if depositing then return "busy" end
  local key = currentKey()
  if not key then return "off" end
  local todo = {}
  for _, w in ipairs(History.WatchList()) do
    if not depositsDone[key .. ":" .. w.id] then todo[#todo + 1] = w.id end
  end
  depositing = true
  local index, learned = 1, 0
  local function tick()
    local ok, err = pcall(function()
      local stop = min(index + History.DEPOSITS_PER_TICK - 1, #todo)
      while index <= stop and Prices.AuctionHouseOpen() do
        local id = todo[index]
        index = index + 1
        local deposits = depositsOf(id)
        if deposits then
          local market = marketFor(key, true)
          market.dep[id] = Spec.EncodeDeposits(deposits)
          touch(market, now())
          depositsDone[key .. ":" .. id] = true
          learned = learned + 1
        end
      end
    end)
    if not ok then History.lastError = tostring(err) end
    if index <= #todo and hist and Prices.AuctionHouseOpen() then
      schedule(tick)
    else
      depositing = false
      History.lastDeposits = {learned = learned, checked = index - 1}
      if learned > 0 then changed() end
    end
  end
  schedule(tick)
  return "started"
end

---------------------------------------------------------------------------
-- /oro tabla: CSV para Excel en español (separador «;», coma decimal)
---------------------------------------------------------------------------
History.TABLE_HEADER = "item;categoría;hoy;normal 14 d;Δ1d;Δ7d;mín 14 d;máx 14 d;oferta;días;confianza"

-- Cobre -> oro con coma decimal y 4 decimales (1o 23p 45c = "1,2345"), "" si no hay valor.
local function gold(copperValue)
  if not isInt(copperValue, 0, Spec.PRICE_MAX) then return "" end
  return Spec.Idiv(copperValue, 10000) .. "," .. string.format("%04d", copperValue % 10000)
end
History.Gold = gold

local function cell(value)
  local text = value == nil and "" or tostring(value)
  if text:find('[;"\r\n]') then text = '"' .. text:gsub('"', '""') .. '"' end
  return text
end

-- Registros de los últimos `keep` días guardados (por defecto 16: la ventana de 14 días, hoy y mañana por si el reloj
-- va adelantado). Los textos están en orden de día, así que basta con decodificar el final: /oro tabla no recorre los
-- 120 días de cada objeto. Si los textos no se normalizaron al cargar, se decodifica todo.
-- Los últimos `keep` registros de un texto «r;r;r»: busca los «;» solo en el final (unos 64 bytes por registro, y el
-- doble si no bastan), no en los 120 días. Devuelve el texto tal cual si tiene keep registros o menos.
local function tailRecords(text, keep)
  local window = keep * 64
  while true do
    local start = #text - window
    local cuts, pos = {}, text:find(";", start > 1 and start or 1, true)
    while pos do cuts[#cuts + 1] = pos; pos = text:find(";", pos + 1, true) end
    if #cuts >= keep then return text:sub(cuts[#cuts - keep + 1] + 1) end
    if start <= 1 then return text end
    window = window * 2
  end
end

function History.RecentRecords(text, keep)
  keep = keep or (Spec.WINDOW + 2)
  if type(text) ~= "string" then return {} end
  if normalized then text = tailRecords(text, keep) end
  return Spec.DecodeDays(text)
end

-- Último escaneo propio de un objeto {t, lo, qty, qty5} (o nil): el final del texto de puntos, sin decodificarlo
-- entero si los textos se normalizaron al cargar.
function History.LastPoint(text)
  if type(text) ~= "string" or text == "" then return nil end
  if normalized then text = text:match("^.*;(.*)$") or text end -- «.*» llega al final y retrocede hasta el último «;»
  local points = Spec.DecodePoints(text)
  return points[#points]
end

local function displayName(id, item)
  local name = Items.Name(id)
  if type(name) == "string" and name ~= "" then return name end
  if item and type(item.n) == "string" and item.n ~= "" then return item.n end
  return Data.FALLBACK_NAMES[id] or ("Objeto " .. id)
end

-- Devuelve el texto CSV, cuántos objetos tiene y una línea de ayuda. Una fila por objeto vigilado con días guardados
-- en este mercado. hoy = valor del día de hoy (escaneos enteros), normal 14 d = precio normal de Especular (sin hoy),
-- Δ en %, mín y máx de los 14 días anteriores, oferta = unidades a la venta hoy, días = días con precio de esos 14.
function History.Table()
  local key, t = currentKey(), now()
  local T = t and Spec.DayIndex(t)
  local market = marketFor(key)
  local rows = {}
  if market and T then
    for _, w in ipairs(History.WatchList()) do
      local item = market.items[w.id]
      local records = item and History.RecentRecords(item.d) or {}
      if #records > 0 then
        local days = Spec.DaysFromRecords(records)
        local b = Spec.Baseline(days, T)
        local deltas = Spec.Deltas(days, T)
        local today, lo, hi
        for _, r in ipairs(records) do
          if r.d == T then today = r end
          if r.d >= T - Spec.WINDOW and r.d <= T - 1 then
            lo, hi = min(lo or r.lo, r.lo), max(hi or r.hi, r.hi)
          end
        end
        local name = displayName(w.id, item)
        rows[#rows + 1] = {rank = CATEGORY_RANK[w.cat] or 99, name = name, cells = {
          cell(name), cell(Data.CATEGORY_LABELS[w.cat] or w.cat), gold(days[T] and days[T].v), gold(b.N),
          deltas.d1 and Spec.Texts.SignedPct(deltas.d1) or "", deltas.d7 and Spec.Texts.SignedPct(deltas.d7) or "",
          gold(lo), gold(hi), (today and today.qty > 0) and tostring(today.qty) or "", tostring(b.n or 0),
          cell(Spec.Texts.Conf(b)),
        }}
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.name < b.name
  end)
  local lines = {History.TABLE_HEADER}
  for _, row in ipairs(rows) do lines[#lines + 1] = table.concat(row.cells, ";") end
  local hint = "Ya está todo seleccionado: Ctrl+C y pégalo en Excel. Precios en oro con coma decimal; Δ en %. "
    .. "Mercado " .. (key or "desconocido") .. "."
  return table.concat(lines, "\n"), #rows, hint
end

---------------------------------------------------------------------------
-- /oro sondeo: diagnóstico para pegar en una incidencia (sin nombres de personajes ni oro)
---------------------------------------------------------------------------
local function addonVersion(name)
  local get = (type(C_AddOns) == "table" and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
  if type(get) ~= "function" then return nil end
  local ok, value = pcall(get, name, "Version")
  return ok and type(value) == "string" and value ~= "" and value or nil
end

local function moneyText(value)
  if isInt(value, 0, Spec.PRICE_MAX) then return Spec.Money(value) end
  if type(value) == "number" then return tostring(value) .. "c" end
  return typeName(value)
end

local PROBE_DEPOSIT_ITEMS = {2770, 14047, 13446}
local COMMODITY_STATUS = {[0] = "desconocido", [1] = "objeto", [2] = "mercancía (se compra por unidades)"}

local function probeLines()
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  local function section(fn)
    local ok, err = pcall(fn)
    if not ok then add("  (no se pudo leer: " .. tostring(err) .. ")") end
  end
  local t = now()
  local today = t and Spec.DayIndex(t)

  section(function()
    local when = (type(date) == "function" and t) and date("%Y-%m-%d %H:%M", t) or "?"
    local build = "?"
    if type(GetBuildInfo) == "function" then
      local ok, v, b, _, toc = pcall(GetBuildInfo)
      if ok then build = tostring(v) .. "." .. tostring(b) .. " (interfaz " .. tostring(toc) .. ")" end
    end
    local locale = type(GetLocale) == "function" and GetLocale() or "?"
    add("Oro de Hermandad " .. version .. " · sondeo " .. when .. " · cliente " .. build .. " · " .. tostring(locale))
    add("Día de Especular: " .. tostring(today) .. " (día 0 = " .. Spec.DAY0 .. ", lanzamiento " .. Spec.LAUNCH .. ")")
  end)

  section(function()
    local A = _G.Auctionator
    if type(A) ~= "table" then add("Auctionator: no está cargado."); return end
    local saved = _G.AUCTIONATOR_PRICE_DATABASE
    local dbVersion = type(saved) == "table" and saved.__dbversion or nil
    local v1 = type(A.API) == "table" and A.API.v1
    add("Auctionator " .. (addonVersion("Auctionator") or "versión desconocida") .. " · __dbversion " .. tostring(dbVersion)
      .. " · API v1 " .. (type(v1) == "table" and "sí" or "no") .. " · EventBus " .. (type(A.EventBus) == "table" and "sí" or "no")
      .. " · escaneos oídos " .. (Prices.WatchingScans() and "sí" or "no") .. " · Database:GetPriceHistory "
      .. (databaseReady() and "sí" or "no"))
    local day0 = type(A.Constants) == "table" and readable(A.Constants.SCAN_DAY_0) or nil
    if type(day0) == "number" then
      local diff = day0 - Spec.DAY0
      add("SCAN_DAY_0 de Auctionator: " .. day0 .. (diff == 0 and " (igual que el de Especular)"
        or (" (" .. (diff > 0 and "+" or "") .. string.format("%.1f", diff / 3600):gsub("%.", ",") .. " h respecto al de Especular)")))
    else
      add("SCAN_DAY_0 de Auctionator: " .. typeName(day0))
    end
    local autoscan = Prices.AutoscanEnabled()
    add("Escanear al abrir la subasta: " .. (autoscan == true and "sí" or autoscan == false and "no" or "desconocido"))
  end)

  section(function()
    for _, kind in ipairs({"full", "summary"}) do
      local shape = shapes[kind]
      local label = kind == "full" and "Escaneo completo" or "Escaneo de resumen"
      if shape then
        add(label .. " (" .. plural(shape.rows, "fila", "filas") .. "): " .. shape.text)
      else
        add(label .. ": no visto en esta sesión (haz uno con Auctionator y repite /oro sondeo).")
      end
    end
    local r = History.lastResult
    if r then
      add("Último escaneo grabado: " .. (r.whole and "entero" or "parcial") .. ", filas entendidas: " .. r.read .. " de " .. r.rows
        .. ", " .. plural(r.items, "objeto escrito", "objetos escritos") .. ", " .. plural(r.ticks, "tanda", "tandas") .. " de lectura"
        .. (r.fallback and " (con el precio de Auctionator: no se entendieron las filas)" or "")
        .. (r.duplicate and " (repetido: no se contó otra vez)" or ""))
    end
  end)

  section(function()
    if not databaseReady() then add("GetPriceHistory: no disponible."); return end
    for _, w in ipairs(History.WatchList()) do
      local readableRows, raw = auctionatorRows(w.id)
      if raw and #raw > 0 then
        local first, fractional = raw[1], false
        for _, row in ipairs(raw) do
          if type(row) == "table" and type(row.minSeen) == "number" and row.minSeen ~= floor(row.minSeen) then fractional = true end
        end
        local fields = {}
        for _, k in ipairs({"rawDay", "minSeen", "maxSeen", "available", "date"}) do
          local v = type(first) == "table" and first[k] or nil
          fields[#fields + 1] = k .. " = " .. (k == "date" and typeName(v) or (tostring(v) .. " (" .. typeName(v) .. ")"))
        end
        add("GetPriceHistory(\"" .. w.id .. "\") " .. displayName(w.id) .. ": " .. plural(#raw, "fila", "filas")
          .. ", la primera: " .. table.concat(fields, ", ") .. (fractional and " · hay precios con decimales" or "")
          .. " · " .. plural(#readableRows, "día legible", "días legibles"))
        return
      end
    end
    add("GetPriceHistory: Auctionator aún no tiene historial de ningún objeto vigilado.")
  end)

  section(function()
    local calc = type(C_AuctionHouse) == "table" and C_AuctionHouse.CalculateCommodityDeposit
    if type(calc) ~= "function" then add("Depósitos: C_AuctionHouse.CalculateCommodityDeposit no existe."); return end
    if not Prices.AuctionHouseOpen() then add("Depósitos: abre la subasta y repite /oro sondeo para verlos."); return end
    for _, id in ipairs(PROBE_DEPOSIT_ITEMS) do
      local parts = {}
      for dur = 1, History.DURATIONS do
        local ok, cost = pcall(calc, id, dur, 1)
        parts[#parts + 1] = "duración " .. dur .. ": " .. (ok and moneyText(readable(cost)) or "falla")
      end
      local sell = Items.SellPrice(id)
      add("Depósito de 1 unidad de " .. displayName(id) .. " (" .. id .. "): " .. table.concat(parts, " · ")
        .. " · precio de mercader " .. (sell and moneyText(sell) or "desconocido"))
    end
  end)

  section(function()
    local labels = {}
    for i, name in ipairs({"AUCTION_DURATION_ONE", "AUCTION_DURATION_TWO", "AUCTION_DURATION_THREE"}) do
      local label = _G[name]
      labels[#labels + 1] = i .. " = " .. (type(label) == "string" and label or "no definido")
    end
    add("Duraciones: " .. table.concat(labels, " · "))
    local copperText = "no disponible"
    if type(C_AuctionHouse) == "table" and type(C_AuctionHouse.SupportsCopperValues) == "function" then
      local ok, value = pcall(C_AuctionHouse.SupportsCopperValues)
      copperText = ok and (value and "sí (se puede rebajar 1c)" or "no (se redondea a platas)") or "error"
    end
    add("SupportsCopperValues: " .. copperText)
  end)

  section(function()
    local get = type(C_AuctionHouse) == "table" and C_AuctionHouse.GetItemCommodityStatus
    local container = type(C_Container) == "table" and C_Container
    if type(get) ~= "function" or not container or type(ItemLocation) ~= "table" then
      add("Mercancía o pieza: no se puede comprobar en este cliente."); return
    end
    local watched, found, done = {}, {}, {}
    for _, w in ipairs(History.WatchList()) do watched[w.id] = true end
    local bags = ns.Scan and ns.Scan.BagIDs and ns.Scan.BagIDs() or {0, 1, 2, 3, 4}
    for _, bag in ipairs(bags) do
      local okSlots, slots = pcall(container.GetContainerNumSlots, bag)
      for slot = 1, okSlots and tonumber(slots) or 0 do
        local okInfo, info = pcall(container.GetContainerItemInfo, bag, slot)
        local id = okInfo and type(info) == "table" and itemID(info.itemID) or nil
        if id and watched[id] and not done[id] and #found < 5 then
          done[id] = true
          local okStatus, status = pcall(function() return get(ItemLocation:CreateFromBagAndSlot(bag, slot)) end)
          found[#found + 1] = displayName(id) .. " " .. (okStatus and (COMMODITY_STATUS[status] or tostring(status)) or "error")
        end
      end
    end
    if #found == 0 then
      add("Mercancía o pieza: lleva en las bolsas algún objeto de la lista vigilada y repite /oro sondeo.")
    else
      add("Mercancía o pieza: " .. table.concat(found, " · "))
    end
  end)

  section(function()
    local raw = rawMarketKey()
    add("Mercado: " .. tostring(raw) .. (validMarketKey(raw) and "" or " (no válido: falta el reino o la facción; no se graba nada)"))
    local list = History.WatchList()
    local fixed = 0
    for _, w in ipairs(list) do if w.fixed then fixed = fixed + 1 end end
    local unknown = History.Unknown()
    add("Lista vigilada: " .. fixed .. " de " .. #FIXED_ORDER .. " fijos reconocidos, " .. plural(#list - fixed, "extra", "extras")
      .. (#unknown > 0 and (" · el cliente no conoce: " .. table.concat(unknown, ", ")) or ""))
    if not hist then add("OroHermandadHist: apagado en esta sesión."); return end
    local market = marketFor(currentKey())
    local deposits = 0
    for _ in pairs(market and market.dep or {}) do deposits = deposits + 1 end
    local markets = 0
    for _ in pairs(hist.markets) do markets = markets + 1 end
    add("OroHermandadHist: " .. plural(countItems(market), "objeto", "objetos") .. " en este mercado, "
      .. plural(markets, "mercado", "mercados") .. ", " .. string.format("%.0f", Spec.EstimateSize(hist) / 1024)
      .. " KB de " .. (Spec.MAX_BYTES / 1024) .. " KB como máximo · depósitos de " .. plural(deposits, "objeto", "objetos")
      .. (loadInfo.shrinkStep and loadInfo.shrinkStep > 0 and (" · al cargar se recortó (paso " .. loadInfo.shrinkStep .. ")") or ""))
    local import = History.lastImport
    if import then
      add("Historial de Auctionator: " .. plural(import.days, "día añadido", "días añadidos") .. " en "
        .. plural(import.items, "objeto", "objetos") .. " de " .. import.checked .. " revisados.")
    elseif db.histImport[currentKey() or ""] == today then
      add("Historial de Auctionator: ya importado hoy.")
    else
      add("Historial de Auctionator: aún no importado en esta sesión.")
    end
    if History.lastError then add("Último fallo interno: " .. History.lastError) end
  end)

  add("¿OroHermandadHist sobrevivió al último /reload? " .. History.SurvivalText())
  return lines
end

function History.Probe() return probeLines() end

return History

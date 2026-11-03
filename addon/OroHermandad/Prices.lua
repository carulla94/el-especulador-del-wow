-- Oro de Hermandad: precios a través de la API pública de Auctionator (Auctionator.API.v1).
-- Cada llamada se detecta antes (type == "function") y va dentro de pcall: si Auctionator falta, aún no ha
-- cargado su base (antes de PLAYER_LOGIN) o cambia, el addon sigue funcionando sin precios.
local ADDON, ns = ...
local Prices = {}
ns.Prices = Prices

local CALLER = (type(ADDON) == "string" and ADDON ~= "") and ADDON or "OroHermandad"

Prices.AH_CUT = 0.05             -- comisión por defecto; Auctionator usa la misma (Constants.AfterAHCut = 0.95)
Prices.HISTORY_DAYS = 21         -- historial por defecto de Auctionator (opción price_history_days)
Prices.LIST_NAME = "Oro de Hermandad"
local CACHE_SECONDS = 30

local store                      -- tabla guardada opcional: precios de mercader vistos y comisión aprendida
local cache, cacheOwner, cacheStamp = {}, nil, 0
local watchers, watching = {}, false
local round = {key = nil, index = 1}

local floor = math.floor

local function now()
  if type(GetTime) == "function" then return GetTime() end
  if type(time) == "function" then return time() end
  return 0
end

-- El cliente moderno puede devolver "valores secretos"; no se pueden sumar ni comparar.
local function readable(value)
  if type(issecretvalue) == "function" and issecretvalue(value) then return nil end
  return value
end

local function toID(itemID)
  local id = tonumber(itemID)
  if id and id > 0 and id == floor(id) then return id end
  return nil
end

local function api()
  local auctionator = _G.Auctionator
  if type(auctionator) ~= "table" or type(auctionator.API) ~= "table" then return nil end
  local v1 = auctionator.API.v1
  return type(v1) == "table" and v1 or nil
end

local function has(method)
  local v1 = api()
  return v1 ~= nil and type(v1[method]) == "function"
end

-- Devuelve ok, resultado. La API lanza error() si callerID no es texto o el id no es número.
local function call(method, ...)
  local v1 = api()
  if not v1 or type(v1[method]) ~= "function" then return false end
  local ok, a, b = pcall(v1[method], CALLER, ...)
  if ok then return true, a, b end
  return false
end

local function positive(value)
  value = readable(value)
  if type(value) == "number" and value > 0 then return value end
  return nil
end

-- Memoria corta: en Auctionator moderno cada lectura deserializa CBOR. Se vacía al actualizarse su base.
local function cached(kind, id, compute)
  local v1 = api()
  if not v1 then return nil end
  local t = now()
  if v1 ~= cacheOwner or t < cacheStamp or t - cacheStamp > CACHE_SECONDS then
    cache, cacheOwner, cacheStamp = {}, v1, t
  end
  local key = kind .. id
  local hit = cache[key]
  if hit == nil then
    local value = compute(id)
    cache[key] = value == nil and false or value
    return value
  end
  if hit == false then return nil end
  return hit
end

function Prices.Invalidate()
  cache, cacheStamp = {}, now()
end

-- Tabla guardada (p. ej. OroHermandadDB.prices). Opcional.
function Prices.Init(saved)
  if type(saved) == "table" then
    store = saved
    store.merchant = type(store.merchant) == "table" and store.merchant or {}
  end
end

function Prices.Available()
  return has("GetAuctionPriceByItemID")
end

function Prices.Capabilities()
  return {
    prices = has("GetAuctionPriceByItemID"),
    byLink = has("GetAuctionPriceByItemLink"),
    age = has("GetAuctionAgeByItemID"),
    vendor = has("GetVendorPriceByItemID"),
    watch = has("RegisterForDBUpdate"),
    shopping = Prices.CanShop(),
    advancedSearch = has("MultiSearchAdvanced"),
    autoscan = Prices.AutoscanEnabled(),
  }
end

------------------------------------------------------------------------------------------------
-- Subasta
------------------------------------------------------------------------------------------------

local function auctionPrice(id)
  local ok, price = call("GetAuctionPriceByItemID", id)
  return ok and positive(price) or nil
end

-- Último precio mínimo que Auctionator vio en la subasta, en cobre (por unidad).
function Prices.Price(itemID)
  local id = toID(itemID)
  if not id then return nil end
  return cached("p", id, auctionPrice)
end

-- Con enlace: separa equipo con sufijo aleatorio ("de la Ballena") o por nivel de objeto.
function Prices.PriceByLink(link, itemID)
  if type(link) == "string" then
    local ok, price = call("GetAuctionPriceByItemLink", link)
    price = ok and positive(price) or nil
    if price then return price end
    itemID = itemID or link:match("item:(%d+)")
  end
  return Prices.Price(itemID)
end

local function auctionAge(id)
  local ok, age = call("GetAuctionAgeByItemID", id)
  age = ok and readable(age) or nil
  if type(age) == "number" and age >= 0 then return floor(age) end
  return nil
end

-- Días desde que Auctionator vio el objeto (0 = hoy, por día de calendario).
-- Si hay precio pero no edad, el dato es más viejo que el historial de Auctionator:
-- devuelve HISTORY_DAYS + 1 y true ("al menos").
function Prices.Age(itemID)
  local id = toID(itemID)
  if not id then return nil end
  local age = cached("a", id, auctionAge)
  if age then return age, false end
  if Prices.Price(id) then return Prices.HISTORY_DAYS + 1, true end
  return nil
end

function Prices.Quote(itemID)
  local price = Prices.Price(itemID)
  if not price then return nil end
  local age, atLeast = Prices.Age(itemID)
  return price, age, atLeast
end

------------------------------------------------------------------------------------------------
-- Mercaderes
------------------------------------------------------------------------------------------------

local function auctionatorVendor(id)
  local ok, price = call("GetVendorPriceByItemID", id)
  return ok and positive(price) or nil
end

-- Lo que cuesta COMPRARLO a un mercader de existencias ilimitadas (precio / pila; puede tener decimales).
-- Primero lo que te cobró a ti un mercader (incluye descuentos de reputación), luego lo que aprendió Auctionator.
function Prices.VendorBuy(itemID)
  local id = toID(itemID)
  if not id then return nil end
  local own = store and store.merchant and positive(store.merchant[id])
  if own then return own end
  local learned = cached("v", id, auctionatorVendor)
  if learned then return learned end
  local static = ns.Data and ns.Data.VENDOR_BUY and ns.Data.VENDOR_BUY[id]
  return positive(static)
end

-- Lo que te paga un mercader por una unidad (precio de venta del objeto).
function Prices.Vendor(itemID)
  return ns.Items.SellPrice(itemID)
end

-- Nombre del objeto, o nil (y pide cargarlo) si el cliente aún no lo conoce.
function Prices.ItemName(itemID)
  return ns.Items.Name(itemID)
end

-- Llamar en MERCHANT_SHOW (con C_Timer.After(0.3, ...)): guarda el precio de compra por unidad de lo que el
-- mercader vende sin límite. En Forever la ficha moderna es C_MerchantFrame.GetItemInfo(i).
function Prices.RecordMerchant()
  if not store or type(GetMerchantNumItems) ~= "function" or type(GetMerchantItemID) ~= "function" then return 0 end
  local okCount, count = pcall(GetMerchantNumItems)
  count = okCount and tonumber(readable(count)) or 0
  local getInfo = type(C_MerchantFrame) == "table" and C_MerchantFrame.GetItemInfo or nil
  local learned = 0
  for i = 1, count do
    local okID, rawID = pcall(GetMerchantItemID, i)
    local id = okID and toID(readable(rawID)) or nil
    local price, stack, available, extended
    if id and type(getInfo) == "function" then
      local ok, info = pcall(getInfo, i)
      if ok and type(info) == "table" then
        price, stack, available, extended = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
      end
    elseif id and type(GetMerchantItemInfo) == "function" then
      local ok, _, _, p, s, a, _, _, e = pcall(GetMerchantItemInfo, i)
      if ok then price, stack, available, extended = p, s, a, e end
    end
    price, stack, available = readable(price), readable(stack), readable(available)
    if id and type(price) == "number" and price > 0 and type(stack) == "number" and stack > 0
        and available == -1 and not extended then
      store.merchant[id] = price / stack
      learned = learned + 1
    end
  end
  if learned > 0 then Prices.Invalidate() end
  return learned
end

------------------------------------------------------------------------------------------------
-- Comisión
------------------------------------------------------------------------------------------------

function Prices.Cut()
  local learned = store and tonumber(store.ahCut)
  if learned and learned >= 0 and learned < 0.5 then return learned end
  return Prices.AH_CUT
end

-- Lo que te queda al vender `count` unidades a `price` cada una, tras la comisión.
function Prices.Net(price, count)
  if type(price) ~= "number" then return nil end
  return floor(price * (count or 1) * (1 - Prices.Cut()))
end

-- Opcional: aprende la comisión real de las facturas de venta que abre el jugador (MailFrame llama a
-- GetInboxInvoiceInfo al abrir una factura; la volvemos a leer con el mismo índice, sin efectos).
local reading = false
local function learnFromInvoice(index)
  if reading or not store or type(GetInboxInvoiceInfo) ~= "function" then return end
  reading = true
  local ok, kind, _, _, bid, _, _, consignment = pcall(GetInboxInvoiceInfo, index)
  reading = false
  bid, consignment = ok and readable(bid), ok and readable(consignment)
  if kind == "seller" and type(bid) == "number" and bid >= 2000 and type(consignment) == "number" and consignment >= 0 then
    local ratio = consignment / bid
    if ratio < 0.5 then store.ahCut = floor(ratio * 1000 + 0.5) / 1000 end
  end
end

function Prices.HookInvoices()
  if Prices.invoiceHooked or type(hooksecurefunc) ~= "function" or type(GetInboxInvoiceInfo) ~= "function" then
    return false
  end
  Prices.invoiceHooked = pcall(hooksecurefunc, "GetInboxInvoiceInfo", learnFromInvoice)
  return Prices.invoiceHooked
end

------------------------------------------------------------------------------------------------
-- Avisos de Auctionator
------------------------------------------------------------------------------------------------

local function fire()
  Prices.Invalidate()
  for i = 1, #watchers do pcall(watchers[i]) end
end

-- Auctionator llama tras cada tanda de resultados de búsqueda y tras un escaneo completo (sin argumentos).
-- No hay forma de darse de baja: se registra una sola vez y se reparte a todos los interesados.
function Prices.Watch(callback)
  if type(callback) == "function" then watchers[#watchers + 1] = callback end
  if watching then return true end
  local v1 = api()
  if v1 and type(v1.RegisterForDBUpdate) == "function" then
    watching = pcall(v1.RegisterForDBUpdate, CALLER, fire) and true or false
  end
  return watching
end

-- Opción interna de Auctionator (no es API pública): escanear al abrir la subasta. nil si no se puede leer.
function Prices.AutoscanEnabled()
  local ok, value = pcall(function()
    local config = _G.Auctionator and _G.Auctionator.Config
    if type(config) ~= "table" or type(config.Options) ~= "table" or type(config.Get) ~= "function" then return nil end
    local key = config.Options.AUTOSCAN
    if key == nil then return nil end
    return config.Get(key)
  end)
  if ok and type(value) == "boolean" then return value end
  return nil
end

------------------------------------------------------------------------------------------------
-- Comprar lo que falta
------------------------------------------------------------------------------------------------

function Prices.AuctionHouseOpen()
  local frame = _G.AuctionHouseFrame
  if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
  local ok, shown = pcall(frame.IsShown, frame)
  return ok and shown and true or false
end

function Prices.CanShop()
  return has("CreateShoppingList") and has("ConvertToSearchString")
end

-- Llama a done cuando el cliente conoce todos los nombres. Devuelve true si tiene que esperar.
local function withNames(ids, done)
  local missing = {}
  for _, id in ipairs(ids) do
    if not Prices.ItemName(id) then missing[#missing + 1] = id end
  end
  if #missing == 0 then
    done()
    return false
  end
  if type(ContinuableContainer) == "table" and type(Item) == "table" and type(Item.CreateFromItemID) == "function" then
    local ok = pcall(function()
      local container = ContinuableContainer:Create()
      for _, id in ipairs(missing) do container:AddContinuable(Item:CreateFromItemID(id)) end
      container:ContinueOnLoad(done)
    end)
    if ok then return true end
  end
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then C_Timer.After(1, done) end
  return true
end

local function normalize(items)
  local list = {}
  for _, item in ipairs(items or {}) do
    local id = toID(item.itemID or item.id)
    local count = tonumber(item.count or item.need or 1)
    if id and count and count > 0 then list[#list + 1] = {id = id, count = math.ceil(count)} end
  end
  return list
end

local function shopWithAuctionator(list)
  local v1 = api()
  local strings, terms, names = {}, {}, {}
  for _, item in ipairs(list) do
    local name = Prices.ItemName(item.id)
    if name and not name:find("[;%^\"]") then
      local term = {searchString = name, isExact = true, quantity = item.count}
      local ok, text = pcall(v1.ConvertToSearchString, CALLER, term)
      if ok and type(text) == "string" then
        strings[#strings + 1], terms[#terms + 1], names[#names + 1] = text, term, name
      end
    end
  end
  if #strings == 0 then return end
  -- Reemplaza la lista del mismo nombre; Auctionator la despliega en su pestaña Compras.
  pcall(v1.CreateShoppingList, CALLER, Prices.LIST_NAME, strings)
  if not Prices.AuctionHouseOpen() then return end
  -- MultiSearchAdvanced recibe TABLAS de búsqueda (no cadenas) y conserva las cantidades.
  if type(v1.MultiSearchAdvanced) == "function" and pcall(v1.MultiSearchAdvanced, CALLER, terms) then return end
  if type(v1.MultiSearchExact) == "function" then pcall(v1.MultiSearchExact, CALLER, names) end
end

-- items: { {itemID = n, count = n}, ... } lo que falta comprar.
-- Devuelve:
--   "auctionator"  lista "Oro de Hermandad" creada y buscada (subasta abierta)
--   "list"         lista creada; la subasta está cerrada (se busca al abrir Compras en Auctionator)
--   "loading"      el cliente carga nombres; se completa solo en un momento
--   "searchbox", item  sin Auctionator: el nombre del siguiente objeto está en la caja de búsqueda; pulsa Buscar
--   "notbuytab", item  sin Auctionator: la subasta no está en la pestaña Comprar
--   "closed"       sin Auctionator y la subasta cerrada
--   "none"         no falta nada
function Prices.ShopFor(items)
  local list = normalize(items)
  if #list == 0 then
    if Prices.CanShop() then pcall(api().CreateShoppingList, CALLER, Prices.LIST_NAME, {}) end
    return "none"
  end
  if Prices.CanShop() then
    local ids = {}
    for i, item in ipairs(list) do ids[i] = item.id end
    local waiting = withNames(ids, function() shopWithAuctionator(list) end)
    if waiting then return "loading" end
    return Prices.AuctionHouseOpen() and "auctionator" or "list"
  end
  if not Prices.AuctionHouseOpen() then return "closed" end
  local parts = {}
  for i, item in ipairs(list) do parts[i] = item.id .. ":" .. item.count end
  local key = table.concat(parts, ",")
  if key ~= round.key or round.index > #list then round.key, round.index = key, 1 end
  local item = list[round.index]
  local name = Prices.ItemName(item.id)
  if not name then return "loading", item end
  local frame = _G.AuctionHouseFrame
  if type(frame.SetSearchText) ~= "function" then return "notbuytab", item end
  local ok, filled = pcall(frame.SetSearchText, frame, name)
  if not (ok and filled) then return "notbuytab", item end
  round.index = round.index + 1
  return "searchbox", item
end

function Prices.ResetRound()
  round.key, round.index = nil, 1
end

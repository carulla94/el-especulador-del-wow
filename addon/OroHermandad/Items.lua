-- Oro de Hermandad: información de objetos con la API moderna (C_Item).
-- En Forever no existen los globales GetItemInfo ni GetItemIcon; se usan solo si C_Item falta (clientes viejos).
local _, ns = ...
local Items = {}
ns.Items = Items

local nameCache, sellCache, failed = {}, {}, {}
local pending = {}

-- El cliente moderno puede devolver "valores secretos" con los que no se puede operar.
local function readable(value)
  if type(issecretvalue) == "function" and issecretvalue(value) then return nil end
  return value
end
Items.Readable = readable

local function getInfo()
  if type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then return C_Item.GetItemInfo end
  if type(_G.GetItemInfo) == "function" then return _G.GetItemInfo end
  return nil
end

local function getInstant()
  if type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function" then return C_Item.GetItemInfoInstant end
  if type(_G.GetItemInfoInstant) == "function" then return _G.GetItemInfoInstant end
  return nil
end

function Items.ID(value)
  local id = tonumber(value)
  if id and id > 0 and id == math.floor(id) and id < 2 ^ 31 then return id end
  return nil
end

function Items.IDFromLink(link)
  return type(link) == "string" and Items.ID(link:match("item:(%d+)")) or nil
end

-- Pide al servidor los datos de un objeto. La respuesta llega con ITEM_DATA_LOAD_RESULT / GET_ITEM_INFO_RECEIVED.
function Items.Request(itemID)
  local id = Items.ID(itemID)
  if not id or failed[id] or pending[id] then return end
  if type(C_Item) == "table" and type(C_Item.RequestLoadItemDataByID) == "function" then
    pending[id] = true
    pcall(C_Item.RequestLoadItemDataByID, id)
  end
end

-- Llamar desde el evento de carga. Devuelve true si el objeto lo habíamos pedido nosotros.
function Items.OnLoaded(itemID, success)
  local id = Items.ID(itemID)
  if not id or not pending[id] then return false end
  pending[id] = nil
  if success == false then failed[id] = true end
  return true
end

-- name, quality, equipLoc, sellPrice, classID, subclassID, bindType (nil si el cliente aún no lo conoce)
function Items.Info(itemID)
  local id, get = Items.ID(itemID), getInfo()
  if not id or not get then return nil end
  local ok, name, _, quality, _, _, _, _, _, equipLoc, _, sellPrice, classID, subclassID, bindType = pcall(get, id)
  name = ok and readable(name) or nil
  if type(name) ~= "string" or name == "" then
    Items.Request(id)
    return nil
  end
  sellPrice = readable(sellPrice)
  nameCache[id] = name
  sellCache[id] = type(sellPrice) == "number" and sellPrice or 0
  return name, readable(quality), readable(equipLoc), sellCache[id], readable(classID), readable(subclassID), readable(bindType)
end

function Items.Name(itemID)
  local id = Items.ID(itemID)
  if not id then return nil end
  if nameCache[id] then return nameCache[id] end
  if type(C_Item) == "table" and type(C_Item.GetItemNameByID) == "function" then
    local ok, name = pcall(C_Item.GetItemNameByID, id)
    name = ok and readable(name) or nil
    if type(name) == "string" and name ~= "" then nameCache[id] = name; return name end
  end
  return (Items.Info(id))
end

-- Lo que paga un vendedor por una unidad.
function Items.SellPrice(itemID)
  local id = Items.ID(itemID)
  if not id then return nil end
  if sellCache[id] then return sellCache[id] end
  local _, _, _, sellPrice = Items.Info(id)
  return sellPrice
end

-- Datos que el cliente conoce sin preguntar al servidor: equipLoc, classID, subclassID.
function Items.Instant(itemID)
  local id, instant = Items.ID(itemID), getInstant()
  if id and instant then
    local ok, _, _, _, equipLoc, _, classID, subclassID = pcall(instant, id)
    if ok and (equipLoc ~= nil or classID ~= nil) then return readable(equipLoc), readable(classID), readable(subclassID) end
  end
  local _, _, equipLoc, _, classID, subclassID = Items.Info(id)
  return equipLoc, classID, subclassID
end

function Items.Icon(itemID)
  local id = Items.ID(itemID)
  if not id then return nil end
  if type(C_Item) == "table" and type(C_Item.GetItemIconByID) == "function" then
    local ok, icon = pcall(C_Item.GetItemIconByID, id)
    if ok and icon then return icon end
  end
  if type(_G.GetItemIcon) == "function" then return _G.GetItemIcon(id) end
  return nil
end

-- true si el cliente confirma que el objeto existe (para los IDs de Forever sin confirmar).
function Items.Exists(itemID)
  local id = Items.ID(itemID)
  if not id then return false end
  if type(C_Item) == "table" and type(C_Item.DoesItemExistByID) == "function" then
    local ok, exists = pcall(C_Item.DoesItemExistByID, id)
    return ok and exists and true or false
  end
  return false
end

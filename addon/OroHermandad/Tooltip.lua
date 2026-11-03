-- Oro de Hermandad: líneas extra en la descripción de los objetos.
-- Usa TooltipDataProcessor (cliente moderno de Forever). No escanea nada: solo lee datos ya guardados.
local _, ns = ...
local Items = ns.Items
local Tooltip = {}
ns.Tooltip = Tooltip

local installed

local function itemIDFromData(data)
  if type(data) ~= "table" then return nil end
  local id = Items.Readable(data.id)
  if type(id) == "number" and id > 0 then return id end
  local link = Items.Readable(data.hyperlink)
  if not link and data.guid and C_Item and C_Item.GetItemLinkByGUID then
    local ok, value = pcall(C_Item.GetItemLinkByGUID, data.guid)
    link = ok and value or nil
  end
  return Items.IDFromLink(link)
end

-- linesFor(itemID) -> { {left = texto, right = texto opcional, color = {r, g, b} opcional para left}, ... }
local GOLD = {0.9, 0.76, 0.35}
function Tooltip.Install(linesFor)
  if installed then return installed end
  local function add(tooltip, itemID)
    local ok, lines = pcall(linesFor, itemID)
    if not ok or type(lines) ~= "table" then return end
    for _, line in ipairs(lines) do
      local c = type(line.color) == "table" and line.color or GOLD
      if line.right then
        tooltip:AddDoubleLine(line.left, line.right, c[1], c[2], c[3], 1, 1, 1)
      else
        tooltip:AddLine(line.left, c[1], c[2], c[3], true)
      end
    end
  end
  if type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
     and type(Enum) == "table" and type(Enum.TooltipDataType) == "table" then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
      local itemID = itemIDFromData(data)
      if itemID then add(tooltip, itemID) end
    end)
    installed = "TooltipDataProcessor"
  elseif GameTooltip and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem") then
    local function legacy(tooltip)
      local _, link = tooltip:GetItem()
      local id = Items.IDFromLink(link)
      if id then add(tooltip, id) end
    end
    GameTooltip:HookScript("OnTooltipSetItem", legacy)
    if ItemRefTooltip then ItemRefTooltip:HookScript("OnTooltipSetItem", legacy) end
    installed = "OnTooltipSetItem"
  end
  return installed
end

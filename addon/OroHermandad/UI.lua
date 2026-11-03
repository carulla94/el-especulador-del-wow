-- Oro de Hermandad: ventana de sugerencias.
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 440, 560
local ROW_TEXT_WIDTH = 340
local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local NOTE_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local LEVEL_COLORS = {ok = {0.45, 0.85, 0.45}, warn = {1, 0.78, 0.2}, error = {1, 0.35, 0.3}}
local SECTION_TITLES = {notes = "Avisos", now = "Ahora", farm = "Recoger", group = "Hermandad"}
local SECTION_ORDER = {"notes", "now", "farm", "group"}
local EMPTY_TEXT = {
  now = "Nada que vender ni fabricar con lo que llevas.",
  farm = "Sin datos de recolección: necesitas una profesión de recolección y precios.",
  group = "Nadie de la hermandad con datos todavía. Pídeles que instalen el addon o usa /oro amigo.",
}

local frame, content
local rows, headers, empties = {}, {}, {}
local callbacks = {}
local savedPosition -- tabla del archivo guardado: {point, relPoint, x, y}

local function itemIcon(item)
  if item.icon then return ns.Items.Icon(item.icon) or COIN_ICON end
  if item.kind == "train" then return NOTE_ICON end
  return COIN_ICON
end

local function makeRow(index)
  local row = CreateFrame("Button", nil, content)
  row:SetWidth(WIDTH - 60)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(28, 28)
  row.icon:SetPoint("TOPLEFT", 0, -2)
  row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 0)
  row.title:SetWidth(ROW_TEXT_WIDTH)
  row.title:SetJustifyH("LEFT")
  row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
  row.detail:SetWidth(ROW_TEXT_WIDTH)
  row.detail:SetJustifyH("LEFT")
  row.detail:SetTextColor(0.75, 0.75, 0.75)
  row:SetScript("OnEnter", function(self)
    if self.itemID and GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.itemID)
    end
  end)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  rows[index] = row
  return row
end

local function button(label, width, onClick)
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function applySavedPosition()
  if not frame then return end
  frame:ClearAllPoints()
  local pos = savedPosition
  if type(pos) == "table" and pos.point then
    frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
  end
end

-- position: tabla guardada donde recordar la posición de la ventana.
function UI.Create(opts)
  if frame then return frame end
  opts = opts or {}
  callbacks = opts
  savedPosition = opts.position
  frame = CreateFrame("Frame", "OroHermandadFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("MEDIUM")
  if frame.SetToplevel then frame:SetToplevel(true) end
  if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if type(savedPosition) == "table" then
      local point, _, relPoint, x, y = self:GetPoint(1)
      savedPosition.point, savedPosition.relPoint, savedPosition.x, savedPosition.y = point, relPoint, x, y
    end
  end)
  applySavedPosition()
  frame:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "OroHermandadFrame") end -- se cierra con Escape

  local title = type(frame.TitleText) == "table" and frame.TitleText or nil
  if not title then
    title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
  end
  title:SetText("Oro de Hermandad")

  frame.lazyButton = button("Tranquilo", 100, function() if callbacks.onMode then callbacks.onMode("lazy") end end)
  frame.lazyButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -30)
  frame.farmButton = button("A tope", 100, function() if callbacks.onMode then callbacks.onMode("farm") end end)
  frame.farmButton:SetPoint("LEFT", frame.lazyButton, "RIGHT", 4, 0)
  frame.refreshButton = button("Actualizar", 90, function() if callbacks.onRefresh then callbacks.onRefresh() end end)
  frame.refreshButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -30)

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.status:SetPoint("TOPLEFT", 14, -58)
  frame.status:SetWidth(WIDTH - 28)
  frame.status:SetJustifyH("LEFT")

  local ok, scroll = pcall(CreateFrame, "ScrollFrame", "OroHermandadScroll", frame, "ScrollFrameTemplate")
  if not ok or not scroll then scroll = CreateFrame("ScrollFrame", "OroHermandadScroll2", frame, "UIPanelScrollFrameTemplate") end
  scroll:SetPoint("TOPLEFT", 12, -92)
  scroll:SetPoint("BOTTOMRIGHT", -32, 58)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH - 60, 10)
  scroll:SetScrollChild(content)
  frame.scroll = scroll

  frame.shopButton = button("Comprar lo que falta", 160, function() if callbacks.onShop then callbacks.onShop() end end)
  frame.shopButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 30)
  frame.shopButton:Hide()
  frame.optionsButton = button("Opciones", 90, function() if callbacks.onOptions then callbacks.onOptions() end end)
  frame.optionsButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 30)

  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.footer:SetPoint("BOTTOMLEFT", 14, 12)
  frame.footer:SetWidth(WIDTH - 28)
  frame.footer:SetJustifyH("LEFT")
  return frame
end

local function header(key)
  if not headers[key] then
    headers[key] = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headers[key]:SetJustifyH("LEFT")
  end
  return headers[key]
end

local function emptyLine(key)
  if not empties[key] then
    empties[key] = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empties[key]:SetWidth(ROW_TEXT_WIDTH + 36)
    empties[key]:SetJustifyH("LEFT")
  end
  return empties[key]
end

-- result: lo que devuelve Engine.Suggest. info: {footer = texto, canShop = bool}.
function UI.Render(result, info)
  if not frame then return end
  frame.lazyButton:UnlockHighlight(); frame.farmButton:UnlockHighlight()
  if result.mode == "farm" then frame.farmButton:LockHighlight() else frame.lazyButton:LockHighlight() end

  local db = result.db or {}
  local color = LEVEL_COLORS[db.level or "warn"] or LEVEL_COLORS.warn
  frame.status:SetTextColor(color[1], color[2], color[3])
  frame.status:SetText(db.text or "")

  for _, row in ipairs(rows) do row:Hide() end
  local sections = {notes = result.notes or {}, now = result.sections.now, farm = result.sections.farm, group = result.sections.group}
  local y, used, shopping = 0, 0, false
  for _, key in ipairs(SECTION_ORDER) do
    local list = sections[key] or {}
    local h, empty = header(key), emptyLine(key)
    if key == "notes" and #list == 0 then
      h:Hide(); empty:Hide()
    else
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
      h:SetText(SECTION_TITLES[key])
      h:Show()
      y = y + 20
      if #list == 0 then
        empty:ClearAllPoints()
        empty:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
        empty:SetText(EMPTY_TEXT[key] or "")
        empty:Show()
        y = y + math.max(16, empty:GetStringHeight() or 16) + 8
      else
        empty:Hide()
        for _, item in ipairs(list) do
          used = used + 1
          if item.shopping then shopping = true end
          local row = rows[used] or makeRow(used)
          row.itemID = item.icon
          row.icon:SetTexture(itemIcon(item))
          row.title:SetText(item.title or "")
          row.detail:SetText(item.detail or "")
          local height = math.max(32, (row.title:GetStringHeight() or 14) + (row.detail:GetStringHeight() or 12) + 6)
          row:SetHeight(height)
          row:ClearAllPoints()
          row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
          row:Show()
          y = y + height + 6
        end
      end
      y = y + 6
    end
  end
  content:SetHeight(math.max(y, 10))
  frame.shopButton:SetShown(shopping and info and info.canShop and true or false)
  frame.footer:SetText(info and info.footer or "")
end

function UI.Show() if frame then frame:Show() end end
function UI.Hide() if frame then frame:Hide() end end
function UI.IsShown() return frame ~= nil and frame:IsShown() and true or false end
function UI.Toggle() if frame then if frame:IsShown() then frame:Hide() else frame:Show() end end end

-- Coloca la ventana a la derecha de otra (la subasta) sin tocar la posición guardada.
function UI.AttachTo(other)
  if not frame or type(other) ~= "table" or type(other.IsShown) ~= "function" or not other:IsShown() then return false end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", other, "TOPRIGHT", 4, 0)
  return true
end

function UI.RestorePosition() applySavedPosition() end

-- Oro de Hermandad: ventana de sugerencias.
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 440, 560
local ROW_TEXT_WIDTH = 340
local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local NOTE_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local LEVEL_COLORS = {ok = {0.45, 0.85, 0.45}, warn = {1, 0.78, 0.2}, error = {1, 0.35, 0.3}, info = {0.75, 0.75, 0.75}}
-- Parte de abajo, de abajo arriba: botones (y 8-30), pie de hasta 3 líneas (y 34-70), lista (desde y 74).
local BUTTON_Y, FOOTER_Y, FOOTER_HEIGHT, FOOTER_LINES = 8, 34, 36, 3
local LIST_BOTTOM = FOOTER_Y + FOOTER_HEIGHT + 4
local SECTION_TITLES = {notes = "Avisos", now = "Ahora", farm = "Recoger", group = "Hermandad", spec = "Especular",
                        balance = "Balance de la semana"}
-- Orden y secciones que se muestran aunque estén vacías, si el resultado no los trae (Engine.MODES los da por modo).
local SECTION_ORDER = {"notes", "now", "spec", "farm", "group"}
local SHOW_EMPTY = {now = true, farm = true, group = true}
local EMPTY_TEXT = {
  now = "Nada que vender ni fabricar con lo que llevas.",
  farm = "Sin datos de recolección: necesitas una profesión de recolección y precios.",
  group = "Nadie de la hermandad con datos todavía. Pídeles que instalen el addon o usa /oro amigo.",
  spec = "Ningún chollo ni precio alto para vender ahora.",
  balance = "Aún no hay balance: hacen falta precios de unos 11 días (4 de cada semana) con confianza orientativa o fiable.",
}
-- Botones de modo si Core no los pasa (los mismos de Engine.MODE_ORDER).
local DEFAULT_MODES = {{key = "lazy", label = "Tranquilo"}, {key = "farm", label = "A tope"}, {key = "spec", label = "Especular"}}
-- Sección Hermandad vacía cuando sí se conoce a alguien (info.guildKnown): no hay nada que les sirva ahora.
local EMPTY_GROUP_KNOWN = "Nada para la hermandad con lo que llevas ahora."

local frame, content
local rows, headers, empties, statusLines = {}, {}, {}, {}
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

  -- Un botón por modo, en el orden de Engine.MODE_ORDER (opts.modes = {{key, label}, ...}).
  frame.modeButtons = {}
  local previous
  for _, mode in ipairs(type(opts.modes) == "table" and #opts.modes > 0 and opts.modes or DEFAULT_MODES) do
    local key = mode.key
    local b = button(mode.label, 100, function() if callbacks.onMode then callbacks.onMode(key) end end)
    if previous then b:SetPoint("LEFT", previous, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -30) end
    frame.modeButtons[#frame.modeButtons + 1] = b
    frame.modeButtons[key] = b
    previous = b
  end
  frame.lazyButton, frame.farmButton, frame.specButton = frame.modeButtons.lazy, frame.modeButtons.farm, frame.modeButtons.spec
  frame.refreshButton = button("Actualizar", 90, function() if callbacks.onRefresh then callbacks.onRefresh() end end)
  frame.refreshButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -30)

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.status:SetPoint("TOPLEFT", 14, -58)
  frame.status:SetWidth(WIDTH - 28)
  frame.status:SetJustifyH("LEFT")

  local ok, scroll = pcall(CreateFrame, "ScrollFrame", "OroHermandadScroll", frame, "ScrollFrameTemplate")
  if not ok or not scroll then scroll = CreateFrame("ScrollFrame", "OroHermandadScroll2", frame, "UIPanelScrollFrameTemplate") end
  scroll:SetPoint("TOPLEFT", 12, -92)
  scroll:SetPoint("BOTTOMRIGHT", -32, LIST_BOTTOM)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH - 60, 10)
  scroll:SetScrollChild(content)
  frame.scroll = scroll

  frame.shopButton = button("Comprar lo que falta", 160, function() if callbacks.onShop then callbacks.onShop() end end)
  frame.shopButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, BUTTON_Y)
  frame.shopButton:Hide()
  frame.optionsButton = button("Opciones", 90, function() if callbacks.onOptions then callbacks.onOptions() end end)
  frame.optionsButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, BUTTON_Y)
  -- Modo Especular: la tabla de precios (/oro tabla) a un clic.
  frame.tableButton = button("Tabla", 80, function() if callbacks.onTable then callbacks.onTable() end end)
  frame.tableButton:SetPoint("RIGHT", frame.optionsButton, "LEFT", -4, 0)
  frame.tableButton:Hide()

  -- El pie tiene su propio hueco entre los botones y la lista: alto fijo y como mucho 3 líneas, para que un texto
  -- largo no crezca hacia arriba y se meta debajo de los botones.
  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, FOOTER_Y)
  frame.footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, FOOTER_Y)
  frame.footer:SetHeight(FOOTER_HEIGHT)
  frame.footer:SetJustifyH("LEFT")
  frame.footer:SetJustifyV("BOTTOM")
  if frame.footer.SetMaxLines then frame.footer:SetMaxLines(FOOTER_LINES) end
  return frame
end

local function header(key)
  if not headers[key] then
    headers[key] = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headers[key]:SetJustifyH("LEFT")
  end
  return headers[key]
end

-- Línea de estado bajo el título de una sección (Especular: aprendiendo, protección, mercado bajando...).
local function statusLine(key)
  if not statusLines[key] then
    statusLines[key] = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusLines[key]:SetWidth(ROW_TEXT_WIDTH + 36)
    statusLines[key]:SetJustifyH("LEFT")
  end
  return statusLines[key]
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
  local active = frame.modeButtons[result.mode] or frame.modeButtons[1]
  for _, b in ipairs(frame.modeButtons) do if b == active then b:LockHighlight() else b:UnlockHighlight() end end

  local db = result.db or {}
  local color = LEVEL_COLORS[db.level or "warn"] or LEVEL_COLORS.warn
  frame.status:SetTextColor(color[1], color[2], color[3])
  frame.status:SetText(db.text or "")

  for _, row in ipairs(rows) do row:Hide() end
  local sections = {notes = result.notes or {}, balance = result.balance}
  for key, list in pairs(result.sections) do sections[key] = list end
  -- Estado de una sección: {level, text} (Especular) o un texto (el índice por categoría del balance).
  local states = {spec = result.spec, balance = result.balanceText and {level = "info", text = result.balanceText} or nil}
  local order = type(result.order) == "table" and result.order or SECTION_ORDER
  local showEmpty = type(result.showEmpty) == "table" and result.showEmpty or SHOW_EMPTY
  local y, used, shopping = 0, 0, false
  for _, line in pairs(statusLines) do line:Hide() end
  for _, h in pairs(headers) do h:Hide() end
  for _, empty in pairs(empties) do empty:Hide() end
  for _, key in ipairs(order) do
    local list = sections[key] or {}
    local h, empty = header(key), emptyLine(key)
    if #list == 0 and not showEmpty[key] then
      h:Hide(); empty:Hide()
    else
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
      h:SetText(SECTION_TITLES[key] or key)
      h:Show()
      y = y + 20
      local state = states[key]
      if type(state) == "table" and type(state.text) == "string" and state.text ~= "" then
        local line = statusLine(key)
        local color = LEVEL_COLORS[state.level or "info"] or LEVEL_COLORS.info
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
        line:SetTextColor(color[1], color[2], color[3])
        line:SetText(state.text)
        line:Show()
        y = y + math.max(14, line:GetStringHeight() or 14) + 6
      end
      if #list == 0 then
        empty:ClearAllPoints()
        empty:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
        empty:SetText((key == "group" and info and info.guildKnown) and EMPTY_GROUP_KNOWN or EMPTY_TEXT[key] or "")
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
  frame.tableButton:SetShown(result.tableButton and true or false)
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

---------------------------------------------------------------------------
-- Ventana de texto para copiar (/oro tabla, /oro sondeo)
---------------------------------------------------------------------------
local TEXT_WIDTH, TEXT_HEIGHT = 640, 440
local textFrame

local function createTextFrame()
  local f = CreateFrame("Frame", "OroHermandadTextFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(TEXT_WIDTH, TEXT_HEIGHT)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  f:SetFrameStrata("DIALOG")
  if f.SetToplevel then f:SetToplevel(true) end
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "OroHermandadTextFrame") end -- se cierra con Escape

  f.title = type(f.TitleText) == "table" and f.TitleText or nil
  if not f.title then
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -5)
  end
  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -30)
  f.hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -30)
  f.hint:SetJustifyH("LEFT")

  local ok, scroll = pcall(CreateFrame, "ScrollFrame", "OroHermandadTextScroll", f, "ScrollFrameTemplate")
  if not ok or not scroll then scroll = CreateFrame("ScrollFrame", "OroHermandadTextScroll2", f, "UIPanelScrollFrameTemplate") end
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -50)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 12)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  local font = _G.ChatFontNormal or _G.GameFontHighlightSmall
  if font then edit:SetFontObject(font) end -- sin fuente, el cliente no deja poner texto
  edit:SetWidth(TEXT_WIDTH - 50)
  edit:SetHeight(TEXT_HEIGHT - 70)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  -- Solo para copiar: si se escribe algo, vuelve el texto original, seleccionado.
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput then self:SetText(f.text or ""); self:HighlightText() end
  end)
  scroll:SetScrollChild(edit)
  f.scroll, f.edit = scroll, edit
  return f
end

-- Muestra un texto seleccionado para copiarlo con Ctrl+C. hint: una línea de ayuda encima.
function UI.ShowText(title, text, hint)
  if not textFrame then textFrame = createTextFrame() end
  textFrame.text = text or ""
  textFrame.title:SetText(title or "Oro de Hermandad")
  textFrame.hint:SetText(hint or "Ya está todo seleccionado: Ctrl+C para copiarlo.")
  textFrame:Show()
  textFrame.edit:SetText(textFrame.text)
  textFrame.edit:SetFocus()
  textFrame.edit:HighlightText()
  return textFrame
end

-- Oro de Hermandad: ventana de sugerencias.
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 440, 560
local ROW_TEXT_WIDTH = 340
local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local NOTE_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local LEVEL_COLORS = {ok = {0.45, 0.85, 0.45}, warn = {1, 0.78, 0.2}, error = {1, 0.35, 0.3}, info = {0.75, 0.75, 0.75}}
-- Parte de abajo, de abajo arriba: botones (y 8-30), pie de hasta 4 líneas (y 34-82), la fila de acciones del escáner
-- o de «Guardar y subir» cuando la hay (UI.SetPanel) y la lista encima.
local BUTTON_Y, FOOTER_Y, FOOTER_HEIGHT, FOOTER_LINES = 8, 34, 48, 4
local LIST_BOTTOM = FOOTER_Y + FOOTER_HEIGHT + 4
local PANEL_GAP = 4
-- Botones de abajo: a la izquierda «Comprar lo que falta» y «Cuándo vender»; a la derecha «Opciones», «Tabla» y
-- «Guardar y subir». Si no caben todos (Especular con lista de la compra en el PC del subidor), el de comprar se acorta.
local BUTTON_WIDTHS = {shop = 136, shopShort = 70, cuando = 96, save = 104, table = 52, options = 72}
local ROW_SPACE = WIDTH - 24
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

local function button(label, width, onClick, parent)
  local b = CreateFrame("Button", nil, parent or frame, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  b.width, b.enabled = width, true
  return b
end

-- Activa o desactiva un botón; con tooltip, al pasar el ratón por encima (también desactivado) dice por qué.
local function setEnabled(b, enabled, tooltip)
  b.enabled, b.tooltipText = enabled and true or false, tooltip
  if b.SetEnabled then b:SetEnabled(b.enabled) end
end

local function withTooltip(b)
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  b:SetScript("OnEnter", function(self)
    if self.tooltipText and GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(self.tooltipText, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
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

  frame.shopButton = button("Comprar lo que falta", BUTTON_WIDTHS.shop, function() if callbacks.onShop then callbacks.onShop() end end)
  frame.shopButton:Hide()
  -- «Cuándo vender» (/oro cuando) a un clic; solo si Timing.lua está cargado.
  frame.cuandoButton = button("Cuándo vender", BUTTON_WIDTHS.cuando, function() if callbacks.onCuando then callbacks.onCuando() end end)
  frame.cuandoButton:Hide()
  frame.optionsButton = button("Opciones", BUTTON_WIDTHS.options, function() if callbacks.onOptions then callbacks.onOptions() end end)
  -- Modo Especular: la tabla de precios (/oro tabla) a un clic.
  frame.tableButton = button("Tabla", BUTTON_WIDTHS.table, function() if callbacks.onTable then callbacks.onTable() end end)
  frame.tableButton:Hide()
  -- PC del subidor: guardar ya (recargar la interfaz) para que suba los precios, con confirmación en la fila de acciones.
  frame.saveButton = withTooltip(button("Guardar y subir", BUTTON_WIDTHS.save, function(self)
    if self.enabled and callbacks.onSave then callbacks.onSave() end
  end))
  frame.saveButton:Hide()

  -- Fila de acciones (escáner de la subasta o confirmación de «Guardar y subir»): texto, hasta 3 botones y una casilla.
  -- Nada de StaticPopupDialogs: todo va dentro de esta ventana.
  local panel = CreateFrame("Frame", nil, frame)
  panel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, LIST_BOTTOM)
  panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, LIST_BOTTOM)
  panel.text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  panel.text:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, 0)
  panel.text:SetJustifyH("LEFT")
  panel.buttons = {}
  for i = 1, 3 do
    local b = withTooltip(button("", 96, function(self)
      if self.enabled and self.onClick then self.onClick() end
    end, panel))
    b:Hide()
    panel.buttons[i] = b
  end
  local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  check:SetSize(22, 22)
  check:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
  check.label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
  check:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
  check:Hide(); check.label:Hide()
  panel.check = check
  panel:Hide()
  frame.panel = panel

  -- El pie tiene su propio hueco entre los botones y la lista: alto fijo y como mucho 3 líneas, para que un texto
  -- largo no crezca hacia arriba y se meta debajo de los botones.
  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, FOOTER_Y)
  frame.footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, FOOTER_Y)
  frame.footer:SetHeight(FOOTER_HEIGHT)
  frame.footer:SetJustifyH("LEFT")
  frame.footer:SetJustifyV("BOTTOM")
  if frame.footer.SetMaxLines then frame.footer:SetMaxLines(FOOTER_LINES) end
  UI.LayoutButtons()
  return frame
end

-- Coloca los botones de abajo que se ven: de izquierda a derecha comprar y «Cuándo vender»; de derecha a izquierda
-- «Opciones», «Tabla» y «Guardar y subir». Sin pisarse: si no caben, «Comprar lo que falta» pasa a «Comprar».
local function layoutButtons()
  local left = {frame.shopButton, frame.cuandoButton}
  local right = {frame.optionsButton, frame.tableButton, frame.saveButton}
  local function total(shopWidth)
    local sum, n = 0, 0
    for _, b in ipairs(left) do if b:IsShown() then sum, n = sum + (b == frame.shopButton and shopWidth or b.width), n + 1 end end
    for _, b in ipairs(right) do if b:IsShown() then sum, n = sum + b.width, n + 1 end end
    return sum + math.max(0, n - 1) * 4
  end
  local shop = frame.shopButton
  if total(BUTTON_WIDTHS.shop) > ROW_SPACE then
    shop.width = BUTTON_WIDTHS.shopShort
    shop:SetText("Comprar")
  else
    shop.width = BUTTON_WIDTHS.shop
    shop:SetText("Comprar lo que falta")
  end
  shop:SetSize(shop.width, 22)
  -- Los ocultos también quedan colocados (en el sitio que tendrían), sin mover a los demás.
  local x = 12
  for _, b in ipairs(left) do
    b:ClearAllPoints()
    b:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, BUTTON_Y)
    b.x = x
    if b:IsShown() then x = x + b.width + 4 end
  end
  x = WIDTH - 12
  for _, b in ipairs(right) do
    b:ClearAllPoints()
    b:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", x - WIDTH, BUTTON_Y)
    b.x = x - b.width
    if b:IsShown() then x = x - b.width - 4 end
  end
end
UI.LayoutButtons = function() if frame then layoutButtons() end end

-- Fila de acciones encima del pie. panel = nil (se quita) o {text, level, buttons = {{label, onClick, disabled,
-- tooltip}, ...} (hasta 3), check = {label, onClick}}. La lista se acorta lo que ocupe.
local LINE_HEIGHT = 12
function UI.SetPanel(panel)
  if not frame then return end
  local p = frame.panel
  for _, b in ipairs(p.buttons) do b:Hide(); b.onClick = nil end
  p.check:Hide(); p.check.label:Hide()
  if type(panel) ~= "table" or type(panel.text) ~= "string" or panel.text == "" then
    p:Hide()
    p.info = nil
    frame.scroll:SetPoint("BOTTOMRIGHT", -32, LIST_BOTTOM)
    return
  end
  p.info = panel
  local right = WIDTH - 24
  for i, spec in ipairs(panel.buttons or {}) do
    local b = p.buttons[i]
    if not b then break end
    b:SetText(spec.label)
    b.width = spec.width or 96
    b:SetSize(b.width, 22)
    b.onClick = spec.onClick
    setEnabled(b, not spec.disabled, spec.tooltip)
    b:ClearAllPoints()
    b:SetPoint("TOPRIGHT", p, "TOPRIGHT", right - (WIDTH - 24), 0)
    right = right - b.width - 4
    b:Show()
  end
  local color = LEVEL_COLORS[panel.level or "info"] or LEVEL_COLORS.info
  p.text:SetWidth(math.max(120, right - 4))
  p.text:SetTextColor(color[1], color[2], color[3])
  p.text:SetText(panel.text)
  local height = math.max(22, (p.text:GetStringHeight() or LINE_HEIGHT) + 4)
  if type(panel.check) == "table" then
    p.check.label:SetText(panel.check.label or "")
    p.check.onClick = panel.check.onClick
    if p.check.SetChecked then p.check:SetChecked(panel.check.checked and true or false) end
    p.check:Show(); p.check.label:Show()
    height = height + 24
  end
  p:SetHeight(height)
  p:Show()
  frame.scroll:SetPoint("BOTTOMRIGHT", -32, LIST_BOTTOM + height + PANEL_GAP)
end

function UI.Panel() return frame and frame.panel.info or nil end

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
  frame.cuandoButton:SetShown(info and info.cuando and true or false)
  UI.SetSave(info and info.save)
  frame.footer:SetText(info and info.footer or "")
end

-- «Guardar y subir»: save = nil (no se ve) o {enabled, tooltip} (solo en el PC del subidor con algo nuevo guardado).
function UI.SetSave(save)
  if not frame then return end
  frame.saveButton:SetShown(save and true or false)
  if save then setEnabled(frame.saveButton, save.enabled, save.tooltip) end
  layoutButtons()
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
-- Ventana de texto para copiar (/oro tabla, /oro sondeo, /oro cuando)
---------------------------------------------------------------------------
local TEXT_WIDTH, TEXT_HEIGHT = 640, 440
local TEXT_TOP = 50 -- donde empieza el texto (debajo de la línea de ayuda), o la tabla si la hay
-- Tabla en celdas encima del texto (la de «Cuándo vender»): la letra del juego no es de ancho fijo y una tabla hecha
-- con espacios se tuerce. Una celda por FontString, de ancho fijo: la primera columna a la izquierda y las demás a la
-- derecha. Se crean la primera vez y luego solo se cambia su texto.
local GRID_LABEL_WIDTH, GRID_CELL_WIDTH, GRID_ROW_HEIGHT, GRID_CAPTION_HEIGHT = 80, 60, 16, 18
local GRID_MAX_ROWS, GRID_MAX_COLUMNS = 8, 8
local GRID_HINT = "Arriba, la tabla; debajo, todo el texto (también la tabla) ya seleccionado: Ctrl+C para copiarlo."
local textFrame
local pendingTable -- {text, tbl}: la tabla del próximo texto (UI.SetTextTable)

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

  f.caption = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.caption:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -TEXT_TOP)
  f.caption:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -TEXT_TOP)
  f.caption:SetJustifyH("LEFT")
  if f.caption.SetWordWrap then f.caption:SetWordWrap(false) end
  f.caption:Hide()
  f.cells = {} -- f.cells[fila][columna]

  local ok, scroll = pcall(CreateFrame, "ScrollFrame", "OroHermandadTextScroll", f, "ScrollFrameTemplate")
  if not ok or not scroll then scroll = CreateFrame("ScrollFrame", "OroHermandadTextScroll2", f, "UIPanelScrollFrameTemplate") end
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -TEXT_TOP)
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

-- La celda (fila r, columna c) de la tabla, creada una sola vez: rótulos (fila 1 y columna 1) en dorado y cifras en
-- blanco, todas del mismo ancho en su columna.
local function gridCell(f, r, c)
  f.cells[r] = f.cells[r] or {}
  local cell = f.cells[r][c]
  if cell then return cell end
  cell = f:CreateFontString(nil, "OVERLAY", (r == 1 or c == 1) and "GameFontNormal" or "GameFontHighlight")
  local x = c == 1 and 14 or 14 + GRID_LABEL_WIDTH + (c - 2) * GRID_CELL_WIDTH
  cell:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(TEXT_TOP + GRID_CAPTION_HEIGHT + (r - 1) * GRID_ROW_HEIGHT))
  cell:SetWidth(c == 1 and GRID_LABEL_WIDTH or GRID_CELL_WIDTH)
  cell:SetJustifyH(c == 1 and "LEFT" or "RIGHT")
  if cell.SetWordWrap then cell:SetWordWrap(false) end
  f.cells[r][c] = cell
  return cell
end

-- Pone la tabla (o la quita con tbl = nil) y coloca el texto debajo. tbl = {caption = texto, rows = {{celdas}, ...}}.
local function setGrid(f, tbl)
  local rows = type(tbl) == "table" and type(tbl.rows) == "table" and tbl.rows or {}
  local used = math.min(#rows, GRID_MAX_ROWS)
  for r = 1, math.max(used, #f.cells) do
    local row = r <= used and type(rows[r]) == "table" and rows[r] or {}
    for c = 1, GRID_MAX_COLUMNS do
      local value = row[c]
      if value ~= nil then
        local cell = gridCell(f, r, c)
        cell:SetText(tostring(value))
        cell:Show()
      elseif f.cells[r] and f.cells[r][c] then
        f.cells[r][c]:SetText("")
        f.cells[r][c]:Hide()
      end
    end
  end
  local top = TEXT_TOP
  if used > 0 then
    f.caption:SetText(type(tbl.caption) == "string" and tbl.caption or "")
    f.caption:Show()
    top = TEXT_TOP + GRID_CAPTION_HEIGHT + used * GRID_ROW_HEIGHT + 8
  else
    f.caption:SetText("")
    f.caption:Hide()
  end
  f.scroll:ClearAllPoints()
  f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -top)
  f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 12)
  f.edit:SetHeight(TEXT_HEIGHT - top - 20)
  f.grid = used > 0 and tbl or nil
end

-- Tabla para el próximo UI.ShowText de este mismo texto (Timing.View la deja; Core solo pasa título y texto).
-- tbl = {caption = texto, rows = {{"Franja", "00-04", ...}, ...}} o nil para quitarla.
function UI.SetTextTable(text, tbl)
  pendingTable = (type(text) == "string" and type(tbl) == "table") and {text = text, tbl = tbl} or nil
end

-- Muestra un texto seleccionado para copiarlo con Ctrl+C. hint: una línea de ayuda encima. Si a este texto le dejaron
-- una tabla (UI.SetTextTable), va dibujada en celdas encima y el texto, debajo, sigue entero para copiarlo.
function UI.ShowText(title, text, hint)
  if not textFrame then textFrame = createTextFrame() end
  local tbl = pendingTable and pendingTable.text == text and pendingTable.tbl or nil
  pendingTable = nil
  textFrame.text = text or ""
  textFrame.title:SetText(title or "Oro de Hermandad")
  setGrid(textFrame, tbl)
  textFrame.hint:SetText(hint or (textFrame.grid and GRID_HINT) or "Ya está todo seleccionado: Ctrl+C para copiarlo.")
  textFrame:Show()
  textFrame.edit:SetText(textFrame.text)
  textFrame.edit:SetFocus()
  textFrame.edit:HighlightText()
  return textFrame
end

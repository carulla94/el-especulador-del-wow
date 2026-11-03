-- Oro de Hermandad: botón del minimapa, entrada del compartimento de addons, ajustes y sonidos. Sin librerías.
local ADDON, ns = ...
local Extras = {}
ns.Extras = Extras

local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local RADIUS_OFFSET = 5
local state = {db = nil, onToggle = nil, onOptions = nil, button = nil, categoryID = nil, lastSound = 0}

---------------------------------------------------------------------------
-- Botón del minimapa (misma geometría que WorldMapTrackingPinButtonTemplate)
---------------------------------------------------------------------------
local function minimapShape()
  return (type(GetMinimapShape) == "function" and GetMinimapShape()) or "ROUND"
end

local function placeButton(button, angle)
  local rad = math.rad(angle or 200)
  local x, y = math.cos(rad), math.sin(rad)
  local w = (Minimap:GetWidth() / 2) + RADIUS_OFFSET
  local h = (Minimap:GetHeight() / 2) + RADIUS_OFFSET
  if minimapShape() == "ROUND" then
    x, y = x * w, y * h
  else -- minimapas cuadrados (SexyMap, ElvUI...): proyecta sobre el borde
    local dw, dh = math.sqrt(2 * w * w) - 10, math.sqrt(2 * h * h) - 10
    x = math.max(-w, math.min(x * dw, w))
    y = math.max(-h, math.min(y * dh, h))
  end
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onDragUpdate(self)
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  local angle = math.deg(math.atan2(py - my, px - mx)) % 360
  state.db.minimap.angle = angle
  placeButton(self, angle)
end

-- fromCompartment: la entrada del menú de addons del minimapa no se puede arrastrar (solo el botón redondo).
local function showTooltip(owner, anchor, fromCompartment)
  if not GameTooltip then return end
  GameTooltip:SetOwner(owner, anchor or "ANCHOR_LEFT")
  GameTooltip:SetText("Oro de Hermandad")
  GameTooltip:AddLine("Clic: abrir / cerrar", 1, 1, 1)
  GameTooltip:AddLine("Clic derecho: opciones", 1, 1, 1)
  if not fromCompartment then GameTooltip:AddLine("Arrastrar: mover el botón", 0.7, 0.7, 0.7) end
  GameTooltip:Show()
end

function Extras.CreateMinimapButton()
  if state.button or not Minimap or not CreateFrame then return state.button end
  local b = CreateFrame("Button", "OroHermandadMinimapButton", Minimap)
  b:SetSize(32, 32)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("AnyUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(25, 25); bg:SetPoint("TOPLEFT", 3, -4)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(COIN_ICON)
  icon:SetSize(20, 20); icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b.icon = icon
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(54, 54); border:SetPoint("TOPLEFT")
  b:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then
      if state.onOptions then state.onOptions() end
    elseif state.onToggle then
      state.onToggle()
    end
  end)
  b:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    self:SetScript("OnUpdate", onDragUpdate)
    if GameTooltip then GameTooltip:Hide() end
  end)
  b:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:UnlockHighlight()
  end)
  b:SetScript("OnMouseDown", function() icon:SetPoint("TOPLEFT", 8, -7) end)
  b:SetScript("OnMouseUp", function() icon:SetPoint("TOPLEFT", 7, -6) end)
  b:SetScript("OnEnter", function(self) showTooltip(self, "ANCHOR_LEFT") end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  state.button = b
  placeButton(b, state.db.minimap.angle)
  b:SetShown(state.db.minimap.show ~= false)
  return b
end

function Extras.SetMinimapShown(shown)
  state.db.minimap.show = shown and true or false
  local b = Extras.CreateMinimapButton()
  if b then b:SetShown(shown) end
end

---------------------------------------------------------------------------
-- Compartimento de addons (TOC: ## AddonCompartmentFunc...)
-- Blizzard llama a _G[func](addonName, buttonName) al pulsar, y (addonName, menuButton) al entrar/salir.
---------------------------------------------------------------------------
function OroHermandad_OnCompartmentClick(_, buttonName)
  if buttonName == "RightButton" then
    if state.onOptions then state.onOptions() end
  elseif state.onToggle then
    state.onToggle()
  end
end
function OroHermandad_OnCompartmentEnter(_, menuButton) showTooltip(menuButton, "ANCHOR_LEFT", true) end
function OroHermandad_OnCompartmentLeave() if GameTooltip then GameTooltip:Hide() end end

---------------------------------------------------------------------------
-- Panel de opciones (Esc > Opciones > Accesorios > Oro de Hermandad)
---------------------------------------------------------------------------
function Extras.RegisterSettings(core)
  if state.categoryID or not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnCategory) then
    return state.categoryID
  end
  local db = state.db
  local ok, err = pcall(function()
    local category = Settings.RegisterVerticalLayoutCategory("Oro de Hermandad")
    local function checkbox(tbl, key, variable, label, tooltip, default, onChange)
      local setting = Settings.RegisterAddOnSetting(category, variable, key, tbl, Settings.VarType.Boolean, label, default)
      if onChange then setting:SetValueChangedCallback(function(_, value) onChange(value) end) end
      Settings.CreateCheckbox(category, setting, tooltip)
    end
    checkbox(db, "autoOpen", "OroHermandad_AutoOpen", "Abrir al entrar en la subasta",
      "Muestra la ventana cada vez que hablas con un subastador.", true)
    checkbox(db, "sound", "OroHermandad_Sound", "Avisos sonoros",
      "Un sonido suave cuando los precios están viejos o llega algo de la hermandad.", true)
    checkbox(db.minimap, "show", "OroHermandad_MinimapShow", "Botón en el minimapa",
      "Muestra u oculta el botón redondo junto al minimapa.", true,
      function(value) Extras.SetMinimapShown(value) end)
    checkbox(db, "tooltip", "OroHermandad_Tooltip", "Información en los objetos",
      "Añade a la descripción de cada objeto su precio, quién de tu hermandad lo usa y cuántos tienes en el banco.", true)
    -- Un modo por entrada, en el orden de los botones de la ventana (Engine.MODE_ORDER).
    local Engine = ns.Engine
    local modeSetting = Settings.RegisterProxySetting(category, "OroHermandad_Mode", Settings.VarType.String,
      "Modo", "lazy", function() return db.mode end, function(value) core.SetMode(value, true) end)
    Settings.CreateDropdown(category, modeSetting, function()
      local container = Settings.CreateControlTextContainer()
      for _, key in ipairs(Engine.MODE_ORDER) do container:Add(key, Engine.MODES[key].label) end
      return container:GetData()
    end, "Tranquilo: sugerencias sin desviarte. A tope: sesión solo para hacer oro. Especular: chollos para comprar y "
      .. "revender, qué vender caro ahora y el balance de la semana.")
    checkbox(db.spec, "on", "OroHermandad_SpecOn", "Chollos en todos los modos",
      "Tranquilo enseña como mucho 1 chollo muy fiable y A tope, 2; la descripción de los objetos dice su precio normal. "
        .. "El modo Especular funciona igual aunque lo apagues.", true, function() if core.Refresh then core.Refresh() end end)
    -- Presupuesto para chollos, en oro (0 = el 25 % del oro que llevas). Con /oro especular presupuesto se puede fijar
    -- cualquier cantidad; aquí, hasta 5000 de 50 en 50. Si falla (cliente sin deslizadores), el resto del panel sigue.
    pcall(function()
      local MAX = 5000
      local budgetSetting = Settings.RegisterProxySetting(category, "OroHermandad_SpecBudget", Settings.VarType.Number,
        "Presupuesto para chollos", 0,
        function() return math.min(MAX, math.floor((db.spec.budget or 0) / 10000)) end,
        function(value)
          value = math.floor((tonumber(value) or 0) + 0.5)
          db.spec.budget = value > 0 and value * 10000 or nil
          if core.Refresh then core.Refresh() end
        end)
      local options = Settings.CreateSliderOptions(0, MAX, 50)
      if options.SetLabelFormatter and MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
          return value <= 0 and "25 % de tu oro" or (math.floor(value) .. "o")
        end)
      end
      Settings.CreateSlider(category, budgetSetting, options,
        "Oro máximo para comprar chollos (cada uno usa como mucho la cuarta parte). En 0, el 25 % del oro que llevas.")
    end)
    Settings.RegisterAddOnCategory(category)
    state.categoryID = category:GetID()
  end)
  if not ok and print then print("|cffe6c35aOro de Hermandad:|r no se pudo crear el panel de opciones: " .. tostring(err)) end
  return state.categoryID
end

function Extras.OpenSettings()
  if state.categoryID and Settings and Settings.OpenToCategory then
    local ok = pcall(Settings.OpenToCategory, state.categoryID)
    if ok then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Sonido suave (como mucho uno cada 10 s)
---------------------------------------------------------------------------
function Extras.Alert(kind)
  if not (state.db and state.db.sound) or type(PlaySound) ~= "function" or type(SOUNDKIT) ~= "table" then return end
  local now = (GetTime and GetTime()) or 0
  if now - state.lastSound < 10 then return end
  state.lastSound = now
  local id = (kind == "warn") and SOUNDKIT.MAP_PING or SOUNDKIT.LOOT_WINDOW_COIN_SOUND
  if id then pcall(PlaySound, id, "SFX") end
end

function Extras.Init(db, onToggle, onOptions)
  state.db, state.onToggle, state.onOptions = db, onToggle, onOptions
  db.minimap = db.minimap or {}
  if db.minimap.angle == nil then db.minimap.angle = 200 end
  if db.minimap.show == nil then db.minimap.show = true end
  if db.sound == nil then db.sound = true end
end

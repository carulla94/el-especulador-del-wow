-- Oro de Hermandad: motor de sugerencias.
-- Lógica pura: no llama a la API de WoW. Recibe un "contexto" con precios, bolsas, banco,
-- profesiones y hermandad, y devuelve avisos y sugerencias ordenadas por secciones.
local _, ns = ...
ns = ns or {}
local Data, Spec = ns.Data, ns.Spec
local Engine = {}
ns.Engine = Engine

Engine.AH_CUT = 0.05          -- comisión por defecto de la subasta (se puede cambiar con /oro comision)
Engine.STALE_ITEM_DAYS = 3    -- un precio con más días se considera viejo

-- Cada modo dice con banderas qué hace: el motor nunca pregunta «¿es tal modo?», así que un modo nuevo no puede
-- comportarse sin querer como otro. Todos definen todas las banderas de Engine.MODE_KEYS (lo comprueban las pruebas).
--   staleHours, freshDays, minFreshShare, minCoverage: cuándo los precios están viejos o cubren poco (DbStatus).
--   limits: filas como mucho por sección (las recetas aceptadas y la tela no cuentan). maxCrafts: recetas sugeridas.
--   craftNeedsBags: solo recetas que puedes hacer con lo que llevas. minCraftProfit, minCraftMargin: lo que pide una
--   receta. minBankTrip: lo que tiene que valer lo que sacas del banco.
--   strictPrices: una receta con algún precio viejo no se sugiere. vendorUnlimited: lo que vende un mercader más
--   barato que la subasta no limita cuántas haces ni se va a buscar al banco (se compra allí).
--   sellsInOneRow: las ventas van en una sola fila. routes: "level" (la mejor ruta de tu nivel) o "all" (2 por
--   profesión y la tela de tu nivel). guildGaps: profesiones que le faltan a la hermandad.
--   sections: secciones que se calculan; order: orden en la ventana; showEmpty: se muestran aunque estén vacías.
--   specAlways: Especular aunque esté apagado en las opciones. specMinConf: confianza mínima de un chollo.
--   specSpikes: filas «Vende ahora». specNotes: notas de precio bajo o alto en las filas de venta. balance: objetos
--   que suben y que bajan en el balance de la semana (0 = sin balance). tableButton: botón de /oro tabla.
Engine.MODE_ORDER = {"lazy", "farm", "spec"}
Engine.MODES = {
  lazy = {
    label = "Tranquilo", staleHours = 24, freshDays = 1, minFreshShare = 0.3, minCoverage = 0.2,
    limits = {now = 4, farm = 1, group = 1, spec = 1}, maxCrafts = 2,
    craftNeedsBags = true, minCraftProfit = 500, minCraftMargin = 0.10,
    minBankTrip = 10000, -- ir al banco compensa desde 1 oro
    strictPrices = false, vendorUnlimited = false, sellsInOneRow = true, routes = "level", guildGaps = false,
    sections = {now = true, farm = true, group = true},
    order = {"notes", "now", "spec", "farm", "group"}, showEmpty = {now = true, farm = true, group = true},
    specAlways = false, specMinConf = "ALTA", specSpikes = false, specNotes = true, balance = 0, tableButton = false,
  },
  farm = {
    label = "A tope", staleHours = 6, freshDays = 1, minFreshShare = 0.6, minCoverage = 0.25,
    limits = {now = 8, farm = 5, group = 4, spec = 2}, maxCrafts = 4,
    craftNeedsBags = false, minCraftProfit = 500, minCraftMargin = 0.15,
    minBankTrip = 0,
    strictPrices = true, vendorUnlimited = true, sellsInOneRow = false, routes = "all", guildGaps = true,
    sections = {now = true, farm = true, group = true},
    order = {"notes", "now", "spec", "farm", "group"}, showEmpty = {now = true, farm = true, group = true},
    specAlways = false, specMinConf = "MEDIA", specSpikes = false, specNotes = true, balance = 0, tableButton = false,
  },
  -- Especular: solo chollos, «Vende ahora», el balance de la semana y la tabla. No calcula recetas, ventas normales,
  -- rutas ni hermandad (para eso están los otros modos).
  spec = {
    label = "Especular", staleHours = 6, freshDays = 1, minFreshShare = 0.6, minCoverage = 0.25,
    limits = {now = 0, farm = 0, group = 0, spec = 8}, maxCrafts = 0,
    craftNeedsBags = true, minCraftProfit = 500, minCraftMargin = 0.15,
    minBankTrip = 0,
    strictPrices = true, vendorUnlimited = false, sellsInOneRow = false, routes = "level", guildGaps = false,
    sections = {now = false, farm = false, group = false},
    order = {"notes", "spec", "balance"}, showEmpty = {spec = true, balance = true},
    specAlways = true, specMinConf = "MEDIA", specSpikes = true, specNotes = false, balance = 3, tableButton = true,
  },
}
Engine.MODE_KEYS = {"label", "staleHours", "freshDays", "minFreshShare", "minCoverage", "limits", "maxCrafts",
  "craftNeedsBags", "minCraftProfit", "minCraftMargin", "minBankTrip", "strictPrices", "vendorUnlimited",
  "sellsInOneRow", "routes", "guildGaps", "sections", "order", "showEmpty", "specAlways", "specMinConf", "specSpikes",
  "specNotes", "balance", "tableButton"}
Engine.SECTIONS = {"now", "farm", "group", "spec"} -- las de result.sections (todas con límite en cada modo)

local floor, max, min = math.floor, math.max, math.min

function Engine.Money(copper)
  copper = floor((copper or 0) + 0.5)
  local sign = copper < 0 and "-" or ""
  copper = math.abs(copper)
  local g, s, c = floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
  if g > 0 then
    return sign .. g .. "o" .. (s > 0 and (" " .. s .. "p") or "")
  elseif s > 0 then
    return sign .. s .. "p" .. (c > 0 and (" " .. c .. "c") or "")
  end
  return sign .. c .. "c"
end
local Money = Engine.Money

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

---------------------------------------------------------------------------
-- Ayudas
---------------------------------------------------------------------------
local function cutOf(ctx)
  local cut = ctx.cut
  if finite(cut) and cut >= 0 and cut < 0.5 then return cut end
  return Engine.AH_CUT
end

-- Precio de subasta con su antigüedad en días (nil si no hay dato).
-- Si hay precio pero no edad (o la edad llega marcada como "al menos"), el dato es de hace más de 3 semanas.
local function quote(ctx, id)
  local price = ctx.price and ctx.price(id)
  if not finite(price) or price <= 0 then return nil end
  local age, atLeast
  if ctx.age then age, atLeast = ctx.age(id) end
  if not finite(age) then
    age = ctx.ageKnown and 99 or nil
    atLeast = age ~= nil
  end
  return price, age, atLeast
end

local function isStale(age) return age ~= nil and age >= Engine.STALE_ITEM_DAYS end

local function itemName(ctx, id)
  local name = ctx.name and ctx.name(id)
  if type(name) == "string" and name ~= "" then return name end
  return Data.FALLBACK_NAMES[id] or ("Objeto " .. tostring(id))
end

-- "1 día", "3 días": el número con el sustantivo en singular o en plural.
local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

local function ageNote(age, atLeast)
  if age and atLeast and age >= 21 then return " · precio de hace más de 3 semanas" end
  if isStale(age) then return " · precio de hace " .. plural(age, "día", "días") end
  return ""
end

-- Claves en orden de texto (los números también, como texto). Si todas son texto, sin convertir: más rápido.
local function byText(a, b) return tostring(a) < tostring(b) end
local function sortedKeys(map)
  local keys, allText = {}, true
  for k in pairs(map) do
    keys[#keys + 1] = k
    if type(k) ~= "string" then allText = false end
  end
  if allText then table.sort(keys) else table.sort(keys, byText) end
  return keys
end

local function byValue(a, b)
  local va, vb = a.value or 0, b.value or 0
  if va ~= vb then return va > vb end
  return (a.title or "") < (b.title or "")
end

local function listNames(names, limit)
  limit = limit or 4
  local shown = {}
  for i = 1, min(#names, limit) do shown[i] = names[i] end
  local text = table.concat(shown, ", ")
  if #names > limit then text = text .. " y " .. (#names - limit) .. " más" end
  return text
end

local function hoursText(hours)
  if hours < 1 then return "menos de 1 h" end
  if hours >= 48 then return plural(floor(hours / 24), "día", "días") end
  return floor(hours) .. " h"
end

-- Nivel de habilidad aproximado de cada material (para saber si a un amigo le sirve).
-- Cuenta el material principal de cada nodo y el segundo si es habitual (piedra o pellejo, al menos 0,1 por nodo);
-- las gemas raras de las vetas de plata, oro o veraplata no heredan la habilidad de esa veta.
local TIER = {}
for _, nodes in pairs(Data.GATHER) do
  for _, node in ipairs(nodes) do
    for i, item in ipairs(node.items) do
      if i <= 2 and item[2] >= 0.1 and (TIER[item[1]] == nil or node.skill < TIER[item[1]]) then TIER[item[1]] = node.skill end
    end
  end
end
for bar, ore in pairs(Data.BAR_FROM_ORE) do TIER[bar] = TIER[bar] or TIER[ore] end
TIER[2841] = 65; TIER[3859] = 165
for _, cloth in ipairs({{2589, 1}, {2592, 75}, {4306, 125}, {4338, 175}, {14047, 250}, {14256, 275}}) do TIER[cloth[1]] = cloth[2] end
Engine.TIER = TIER

local function usefulFor(skill, id)
  local tier = TIER[id]
  if not tier or not skill then return true end
  return skill >= tier - 25 and skill <= tier + 100
end

-- Quién de la hermandad usa este material: { "Ana (Ingeniería)", ... }
function Engine.FriendsWhoUse(guild, id, myName)
  local out = {}
  for _, name in ipairs(sortedKeys(guild or {})) do
    local friend = guild[name]
    if name ~= myName and type(friend.profs) == "table" then
      for _, prof in ipairs(sortedKeys(friend.profs)) do
        local demand = Data.DEMAND[prof]
        if demand and demand[id] and usefulFor(friend.profs[prof], id) then
          out[#out + 1] = name .. " (" .. Data.PROFESSIONS[prof].label .. ")"
          break
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Estado de la base de datos de precios
---------------------------------------------------------------------------
function Engine.DbStatus(ctx, modeKey)
  local mode = Engine.MODES[modeKey] or Engine.MODES.lazy
  local status = {source = ctx.hasPriceSource and true or false}
  if not status.source then
    status.level, status.text = "error", "Sin Auctionator no hay precios. Instálalo para recibir sugerencias con oro."
    return status
  end
  -- ctx.dbUpdatedAt: último escaneo terminado (completo o el resumen de Auctionator); ctx.fullScanAt: último
  -- escaneo completo terminado. Cualquiera de los dos puede faltar.
  local now = finite(ctx.now) and ctx.now or nil
  if now and finite(ctx.dbUpdatedAt) then status.hours = max(0, (now - ctx.dbUpdatedAt) / 3600) end
  if now and finite(ctx.fullScanAt) then
    status.fullHours = max(0, (now - ctx.fullScanAt) / 3600)
    if not status.hours or status.fullHours < status.hours then status.hours = status.fullHours end
  end
  local known, fresh, withAge, today = 0, 0, 0, 0
  for _, id in ipairs(Data.BASKET) do
    local price, age = quote(ctx, id)
    if price then
      known = known + 1
      if age then
        withAge = withAge + 1
        if age <= mode.freshDays then fresh = fresh + 1 end
        if age <= 0 then today = today + 1 end
      end
    end
  end
  status.known, status.total, status.today = known, #Data.BASKET, today
  status.coverage = known / #Data.BASKET
  if withAge > 0 then status.freshShare = fresh / withAge end
  -- Tras un escaneo completo reciente, lo que no tiene precio o lo tiene de días anteriores es que no está a la
  -- venta: escanear otra vez no lo arregla. Sin escaneo completo registrado, vale un escaneo reciente que se note
  -- en la cesta (bastantes materiales vistos hoy); una o dos búsquedas sobre una base vieja siguen avisando.
  local recentFull = status.fullHours ~= nil and status.fullHours <= mode.staleHours
  local recentScan = recentFull or (status.hours ~= nil and status.hours <= mode.staleHours and today >= 5 and today >= 0.4 * known)
  status.recentScan = recentScan
  local scanHint = ctx.autoscan == false
    and " Activa «escanear al abrir la subasta» en las opciones de Auctionator o pulsa su escaneo completo."
    or " Haz un escaneo completo con Auctionator en la subasta."

  if known == 0 then
    if recentFull then
      status.level, status.text = "warn", "La subasta no tiene a la venta ninguno de los materiales de referencia: aún no hay precios con los que sugerir."
    else
      status.level, status.text = "error", "Aún no hay precios." .. scanHint
    end
  elseif status.coverage < mode.minCoverage and not recentScan then
    status.level = "warn"
    status.text = string.format("Solo hay precio de %d de %d materiales de referencia.%s", known, #Data.BASKET, scanHint)
  elseif status.hours and status.hours > mode.staleHours then
    status.level = "warn"
    status.text = "Precios de hace " .. hoursText(status.hours) .. "." .. scanHint
  elseif status.freshShare and status.freshShare < mode.minFreshShare and not recentScan then
    status.level = "warn"
    status.text = string.format("Solo el %d%% de los precios es de hoy o ayer.%s", floor(status.freshShare * 100 + 0.5), scanHint)
  elseif not status.hours and not status.freshShare then
    status.level = "warn"
    status.text = "No sé cuándo se escaneó la subasta." .. scanHint
  else
    status.level = "ok"
    status.text = status.hours and ("Precios al día (hace " .. hoursText(status.hours) .. ").") or "Precios al día."
    -- Mercado con poca oferta (servidor nuevo): se dice, pero sin pedir otro escaneo.
    if status.coverage < mode.minCoverage then
      status.thin = true
      status.text = status.text .. string.format(" La subasta tiene poca oferta: solo hay precio de %d de %d materiales de referencia.",
        known, #Data.BASKET)
    elseif status.freshShare and status.freshShare < mode.minFreshShare then
      status.thin = true
      status.text = status.text .. " Muchos materiales de referencia no están a la venta ahora: sus precios son de días anteriores."
    end
  end
  return status
end

---------------------------------------------------------------------------
-- Recetas
---------------------------------------------------------------------------
-- Coste de reponer un material que te falta: el más barato entre mercader y subasta.
local function buyCost(ctx, id)
  local buy = ctx.vendorBuy and ctx.vendorBuy(id)
  if not finite(buy) or buy <= 0 then buy = nil end
  local price, age, atLeast = quote(ctx, id)
  if buy and price then return min(buy, price), nil end
  if buy then return buy, nil end
  if price then return price, age, atLeast end
  return nil
end

-- Lo que vale un material que ya llevas: lo mejor que te darían por él (subasta tras la comisión, o el mercader si
-- paga más), sin pasar de lo que cuesta reponerlo si lo vende un mercader.
local function ownedValue(ctx, id, cut)
  local price = quote(ctx, id)
  local net = price and floor(price * (1 - cut)) or nil
  local buy = ctx.vendorBuy and ctx.vendorBuy(id)
  if not finite(buy) or buy <= 0 then buy = nil end
  local sell = ctx.vendor and ctx.vendor(id)
  if not finite(sell) or sell <= 0 then sell = nil end
  local best = (net or sell) and max(net or 0, sell or 0) or nil
  if buy then best = best and min(best, buy) or buy end
  return best
end

-- ¿Lo vende un mercader sin límite y no más caro que la subasta? Entonces se compra allí, no en la subasta.
local function vendorCheaper(ctx, id)
  local buy = ctx.vendorBuy and ctx.vendorBuy(id)
  if not finite(buy) or buy <= 0 then return false end
  local price = quote(ctx, id)
  return not price or buy <= price
end

-- available: unidades que tienes de cada material. A tope, lo que vende un mercader más barato que la subasta no
-- limita cuántas puedes hacer (se compra allí); missing marca esos materiales con vendor = true.
local function recipeEconomics(ctx, recipe, available, mode)
  local cut = cutOf(ctx)
  local productPrice, productAge, productAtLeast = quote(ctx, recipe.product)
  if not productPrice then return nil end
  if mode.strictPrices and isStale(productAge) then return nil end
  local qty = recipe.qty or 1
  local revenue = floor(productPrice * (1 - cut)) * qty
  local cost, canMake, withWhatYouHave, missing = 0, math.huge, math.huge, {}
  for _, reagent in ipairs(recipe.reagents or {}) do
    local id, need = reagent[1], reagent[2]
    local have = max(0, available[id] or 0)
    local fromVendor = vendorCheaper(ctx, id)
    local unlimited = fromVendor and mode.vendorUnlimited
    withWhatYouHave = min(withWhatYouHave, floor(have / need))
    if not unlimited then canMake = min(canMake, floor(have / need)) end
    local unit
    if have >= need and not unlimited then
      unit = ownedValue(ctx, id, cut)
    else
      -- Lo que se compra (o se repone al mercader) cuesta lo que cueste comprarlo.
      local age
      unit, age = buyCost(ctx, id)
      if unit and mode.strictPrices and isStale(age) then return nil end
      if have < need then missing[#missing + 1] = {id = id, count = need - have, vendor = fromVendor or nil} end
    end
    if not unit then return nil end -- no sabemos cuánto vale este material
    cost = cost + unit * need
  end
  -- Si todo se compra al mercader, se cuentan las que salen con lo que ya llevas.
  if canMake == math.huge then canMake = withWhatYouHave == math.huge and 0 or withWhatYouHave end
  if cost <= 0 then return nil end
  return {revenue = revenue, cost = cost, profit = revenue - cost, canMake = canMake, missing = missing, qty = qty,
          margin = (revenue - cost) / cost, productAge = productAge, productAtLeast = productAtLeast}
end

-- Tus recetas más rentables comprando todos los materiales (lo que se comparte con la hermandad).
function Engine.TopCrafts(ctx, limit)
  local farm = Engine.MODES.farm
  local list = {}
  for _, recipe in ipairs(ctx.recipes or {}) do
    local econ = recipeEconomics(ctx, recipe, {}, farm)
    if econ and econ.profit >= farm.minCraftProfit and econ.margin >= farm.minCraftMargin then
      list[#list + 1] = {product = recipe.product, qty = recipe.qty or 1, profit = econ.profit, reagents = recipe.reagents}
    end
  end
  table.sort(list, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.product < b.product
  end)
  for i = #list, (limit or 8) + 1, -1 do table.remove(list, i) end
  return list
end

-- ¿Quién de la hermandad puede conseguir este material? (names: nombres ya ordenados, opcional)
local function gathererFor(ctx, id, names)
  local source = Data.BAR_FROM_ORE[id] or id
  local me = ctx.me and ctx.me.name
  for _, name in ipairs(names or sortedKeys(ctx.guild or {})) do
    local friend = ctx.guild[name]
    if name ~= me and type(friend.profs) == "table" then
      for prof, nodes in pairs(Data.GATHER) do
        local skill = friend.profs[prof]
        if skill then
          for _, node in ipairs(nodes) do
            for _, item in ipairs(node.items) do
              if item[1] == source and skill >= node.skill then
                return name .. ", que tiene " .. Data.PROFESSIONS[prof].label
              end
            end
          end
        end
      end
    end
  end
end

local function recipeList(ctx)
  local recipes, haveSmelt = {}, false
  for _, r in ipairs(ctx.recipes or {}) do
    recipes[#recipes + 1] = r
    if r.prof == "mining" then haveSmelt = true end
  end
  local mining = ctx.me and ctx.me.profs and ctx.me.profs.mining
  if mining and not haveSmelt then
    local function add(smelt)
      recipes[#recipes + 1] = {product = smelt.product, qty = smelt.qty, reagents = smelt.reagents, prof = "mining", station = smelt.station}
    end
    for _, smelt in ipairs(Data.SMELT) do if mining >= smelt.skill then add(smelt) end end
    for _, smelt in ipairs(Data.FOREVER_SMELT or {}) do
      if mining >= smelt.skill and ctx.exists and ctx.exists(smelt.product) then add(smelt) end
    end
  end
  return recipes
end

---------------------------------------------------------------------------
-- Especular: chollos, «Vende ahora», notas en las ventas y balance (las reglas están en Spec.lua)
---------------------------------------------------------------------------
-- ctx.spec (opcional; lo prepara Core con OroHermandadHist del mercado actual):
--   T = día de hoy (Spec.DayIndex), now = hora unix, hints = Especular encendido también en Tranquilo y A tope,
--   budget = presupuesto para chollos en cobre (cada compra usa como mucho el 25 %), copperValues = false si la
--   subasta no admite cobre (se rebaja 1 plata en vez de 1 cobre), launch = día de lanzamiento (solo pruebas),
--   items = {[id] = {records = días (History.RecentRecords), point = último escaneo propio {t, lo, qty, qty5},
--            vendor = precio de mercader, dep = depósito de 24 h por unidad (nil = se estima), cat, name}},
--   books = {[id] = {at = hora, lots = {{precio, cantidad}, ...}}}: lo que la subasta mostró al buscar el objeto.
Engine.SPEC_STALE_SECONDS = 2 * 3600 -- precio actual: un escaneo propio de hace 2 h como mucho
Engine.BOOK_SECONDS = 300            -- lo visto al buscar un objeto en la subasta vale 5 min
Engine.SPEC_DEPOSIT_DURATION = 2     -- depósito de la duración 2 (24 h), la de reventa que supone Especular

local CONF_RANK = {BAJA = 1, MEDIA = 2, ALTA = 3}
local function isInt(x, lo, hi) return finite(x) and x >= lo and x <= hi and x == floor(x) end

-- Días, precio normal y balances de un objeto: se recalculan solo si cambian sus días (Core reutiliza la misma
-- tabla de registros mientras no llegue otro escaneo) o el día de hoy.
local baseMemo = setmetatable({}, {__mode = "k"})
local function specBase(entry, T)
  if type(entry) ~= "table" or type(entry.records) ~= "table" then return nil end
  local memo = baseMemo[entry.records]
  if memo and memo.T == T then return memo end
  local days = Spec.DaysFromRecords(entry.records)
  memo = {T = T, days = days, b = Spec.Baseline(days, T), deltas = Spec.Deltas(days, T)}
  baseMemo[entry.records] = memo
  return memo
end

-- Precio actual para Especular y desde cuándo se sabe (nil si no se sabe la hora: así no hay chollo).
-- 1. Lo que mostró la subasta al buscar el objeto hace 5 min o menos (precio confirmado, con sus lotes).
-- 2. El último escaneo propio de hace 2 h o menos (no cuenta tus subastas; trae las unidades cerca del mínimo).
-- 3. El precio de hoy de Auctionator, sin hora.
local function specPrice(ctx, spec, id, entry)
  local t = spec.now
  local book = type(spec.books) == "table" and spec.books[id] or nil
  if type(book) == "table" and finite(t) and finite(book.at) and t - book.at <= Engine.BOOK_SECONDS and book.at <= t + 60
     and type(book.lots) == "table" then
    local first = book.lots[1]
    if first == nil then return nil end -- la subasta no tiene nada a la venta
    if type(first) == "table" and isInt(first[1], 1, Spec.PRICE_MAX) then return first[1], book.at, nil, book.lots end
  end
  local point = entry.point
  if type(point) == "table" and finite(t) and isInt(point.t, 1, Spec.TIME_MAX) and t - point.t <= Engine.SPEC_STALE_SECONDS
     and point.t <= t + 300 and isInt(point.lo, 1, Spec.PRICE_MAX) then
    return point.lo, point.t, isInt(point.qty5, 0, Spec.QTY_MAX) and point.qty5 or nil
  end
  local price, age = quote(ctx, id)
  if price and age == 0 then
    price = floor(price + 0.5)
    if isInt(price, 1, Spec.PRICE_MAX) then return price end
  end
  return nil
end

local function cutBp(ctx) return floor(cutOf(ctx) * 10000 + 0.5) end

-- Nombre del cliente; si aún no lo tiene, el que se guardó en el historial (también del cliente) o el de reserva.
local function specName(ctx, id, entry)
  local name = ctx.name and ctx.name(id)
  if type(name) == "string" and name ~= "" then return name end
  if entry and type(entry.name) == "string" and entry.name ~= "" then return entry.name end
  return Data.FALLBACK_NAMES[id] or ("Objeto " .. tostring(id))
end

local function agoText(seconds)
  local minutes = floor(max(0, seconds) / 60)
  if minutes < 1 then return "hace menos de 1 min" end
  if minutes < 60 then return "hace " .. minutes .. " min" end
  local hours, rest = floor(minutes / 60), minutes % 60
  return "hace " .. hours .. " h" .. (rest > 0 and (" " .. rest .. " min") or "")
end

-- «A», «A y B», «A, B y C», «A, B, C y 2 más».
local function joinNames(names, limit)
  limit = limit or 3
  local n = #names
  if n <= 1 then return names[1] or "" end
  if n > limit then return table.concat(names, ", ", 1, limit) .. " y " .. (n - limit) .. " más" end
  return table.concat(names, ", ", 1, n - 1) .. " y " .. names[n]
end

-- Compra para revender de un objeto con veredicto CHOLLO. budget: presupuesto que queda (cobre). q5: unidades que
-- se suponen a la venta cerca del mínimo, en lugar de las del escaneo (solo para unknownDepth).
local function specFlip(ctx, spec, id, info, budget, q5)
  local entry = info.entry
  local vendor = isInt(entry.vendor, 1, Spec.PRICE_MAX) and entry.vendor or nil
  if not vendor and ctx.vendor then
    local v = ctx.vendor(id)
    if isInt(v, 0, Spec.PRICE_MAX) then vendor = v end
  end
  return Spec.Flip(info.b, info.lots, {
    cutBp = cutBp(ctx), u = spec.copperValues == false and 100 or Spec.UNDERCUT,
    D = isInt(entry.dep, 0, Spec.PRICE_MAX) and entry.dep or nil, vendor = vendor or 0, F = Spec.FAILED_LISTINGS,
    budget = budget, p = info.p, q5 = q5 or info.q5,
  })
end

-- El escaneo de resumen de Auctionator (el de su botón por defecto) no dice cuántas unidades hay cerca del mínimo
-- (qty5 = 0), y entonces Spec.Flip supone 1. Con 1 unidad casi ningún material barato deja 1 oro: «No compensa»
-- sería decir algo que no se sabe. En ese caso se repite la cuenta con todas las unidades que admitiría el chollo y
-- se devuelve esa (la mejor posible): si compensa, es un posible chollo que hay que mirar en la subasta (al abrir el
-- objeto, History.CaptureBook trae lo que hay a la venta); si no, no compensa ni con todas. nil: no es el caso.
local function unknownDepth(ctx, spec, id, info, flip, budget)
  if flip.accept or not flip.bookEstimated or (info.q5 and info.q5 >= 1) then return nil end
  if flip.reason ~= "POCA_GANANCIA" and flip.reason ~= "MARGEN_BAJO" then return nil end
  return specFlip(ctx, spec, id, info, budget, Spec.UNITS_MAX)
end

local function specBudget(spec)
  return isInt(spec.budget, 0, 100000000000) and spec.budget or Spec.BUDGET
end

-- Análisis de un objeto vigilado: {entry, b (precio normal), a (veredicto), p, at, q5, lots, deltas, days}, o nil.
local function specItem(ctx, spec, id)
  local entry = type(spec.items) == "table" and spec.items[id] or nil
  local base = specBase(entry, spec.T)
  if not base then return nil end
  local p, at, q5, lots = specPrice(ctx, spec, id, entry)
  local a = Spec.Assess(base.b, p, spec.T, {launch = spec.launch})
  return {id = id, entry = entry, b = base.b, a = a, p = p, at = at, q5 = q5, lots = lots, deltas = base.deltas,
          days = base.days}
end

local function useSpec(ctx, mode)
  return Spec ~= nil and type(ctx.spec) == "table" and isInt(ctx.spec.T, 0, Spec.DAY_MAX)
    and (mode.specAlways or ctx.spec.hints == true)
end

-- Todos los objetos vigilados con días guardados, en orden de ID (para que el resultado no dependa de pairs).
local function specAnalyze(ctx, mode)
  if not useSpec(ctx, mode) then return nil end
  local spec = ctx.spec
  local ids = {}
  for id in pairs(type(spec.items) == "table" and spec.items or {}) do
    if type(id) == "number" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local out = {spec = spec, list = {}, byID = {}}
  for _, id in ipairs(ids) do
    local info = specItem(ctx, spec, id)
    if info then out.list[#out.list + 1] = info; out.byID[id] = info end
  end
  return out
end

-- Nota de las filas de venta: precio bajo (si no tienes prisa, espera) o alto (buen momento para vender), con el
-- mismo precio de hoy que usa la fila (el de Auctionator). Devuelve "low", "high" o nil, y el veredicto.
local function sellNoteFor(analysis, sell)
  local info = analysis and analysis.byID[sell.id]
  if not info or sell.age ~= 0 or not finite(sell.price) then return nil end
  local p = floor(sell.price + 0.5)
  if not isInt(p, 1, Spec.PRICE_MAX) then return nil end
  local a = Spec.Assess(info.b, p, analysis.spec.T, {launch = analysis.spec.launch})
  if a.wait and a.verdict ~= "BAJADA" then return "low", a end -- una bajada de nivel no es un mal día: no se espera
  if a.verdict == "CARO" then return "high", a end
  return nil
end

local function specSellNote(analysis, sell)
  local kind, a = sellNoteFor(analysis, sell)
  if kind == "low" then
    return " Hoy está un " .. Spec.Texts.Pct(a.dBp) .. " % por debajo de lo normal: si no tienes prisa, espera."
  elseif kind == "high" then
    return " Hoy está un " .. Spec.Texts.Pct(a.dBp) .. " % por encima de lo normal: buen momento para vender."
  end
  return ""
end

local function specGroupNote(analysis, sells)
  if not analysis then return "" end
  local low, high = {}, {}
  for _, sell in ipairs(sells) do
    local kind = sellNoteFor(analysis, sell)
    if kind == "low" then low[#low + 1] = sell.name elseif kind == "high" then high[#high + 1] = sell.name end
  end
  local text = ""
  if #low > 0 then
    text = text .. " Hoy " .. joinNames(low) .. (#low == 1 and " está" or " están")
      .. " por debajo de lo normal: si no tienes prisa, espera."
  end
  if #high > 0 then
    text = text .. " Hoy " .. joinNames(high) .. (#high == 1 and " está" or " están")
      .. " por encima de lo normal: buen momento para vender."
  end
  return text
end

local function guardDayText() return "18-nov" end

-- Días con precio (de los 14 de la ventana) que pide cada confianza en Spec.Baseline: con 7 ya hay precio normal,
-- pero un chollo pide confianza orientativa (10 días) o fiable (12, la que pide Tranquilo).
local CONF_DAYS = {BAJA = Spec.MIN_DAYS, MEDIA = 10, ALTA = 12}
local function cholloDays(mode) return CONF_DAYS[mode.specMinConf] or CONF_DAYS.ALTA end

-- Línea de estado de la sección Especular: {level, text}.
local function specStatus(stats, mode)
  local parts, level = {}, "ok"
  if stats.tracked == 0 then
    return {level = "warn", text = "Aún no hay precios guardados en este mercado: haz un escaneo completo con Auctionator en la subasta."}
  end
  local needed = cholloDays(mode)
  if stats.ready == 0 then
    level = "warn"
    parts[#parts + 1] = string.format("Aprendiendo precios: día %d de %d. Haz un escaneo completo cada día: el precio normal necesita %d días y los chollos, %d.",
      min(Spec.MIN_DAYS, stats.maxN + 1), Spec.MIN_DAYS, Spec.MIN_DAYS, needed)
  else
    parts[#parts + 1] = string.format("Con precio normal: %d de %s (%s).", stats.ready,
      plural(stats.tracked, "objeto vigilado", "objetos vigilados"), plural(stats.reliable, "fiable", "fiables"))
    -- De 7 a 9 días (11 en Tranquilo) ya hay precio normal, pero aún ningún objeto puede dar un chollo.
    if stats.maxN < needed then
      parts[#parts + 1] = string.format("Los chollos necesitan %d días con precio (ahora hay %d).", needed, stats.maxN)
    end
  end
  if stats.guard then
    level = "warn"
    local text = "Protección de lanzamiento hasta el " .. guardDayText() .. ": aún no sugiere compras para revender."
    if stats.guarded > 0 then
      text = text .. (stats.guarded == 1 and " Hoy habría 1 chollo." or (" Hoy habría " .. stats.guarded .. " chollos."))
    end
    parts[#parts + 1] = text
  end
  if stats.falling then
    level = "warn"
    parts[#parts + 1] = string.format("Mercado bajando: %d de %d %s más de un 10 %% en unos días. Vende pronto lo que farmees y no compres para revender.",
      stats.down, stats.trendKnown, stats.down == 1 and "objetos ha caído" or "objetos han caído")
  end
  if mode.specAlways and stats.budgetShort > 0 then
    parts[#parts + 1] = (stats.budgetShort == 1 and "1 chollo no cabe" or (stats.budgetShort .. " chollos no caben"))
      .. " en tu presupuesto (" .. Money(stats.budget) .. "): súbelo con /oro especular presupuesto <oro>."
  end
  if stats.ready > 0 then parts[#parts + 1] = "Recuerda: " .. Spec.Texts.CAVEAT .. "." end
  return {level = level, text = table.concat(parts, " ")}
end

-- Filas de la sección Especular (chollos y «Vende ahora»), estado y balance. available y bankLeft: lo que llevas y
-- lo que queda en el banco (sin lo ligado).
local function specRows(ctx, mode, analysis, available, bankLeft, sellable, cut)
  local spec = analysis.spec
  local rows, stats = {}, {tracked = 0, ready = 0, reliable = 0, maxN = 0, trendKnown = 0, down = 0, guarded = 0,
                           budgetShort = 0, budget = specBudget(spec)}
  stats.guard = isInt(spec.T, 0, Spec.DAY_MAX) and spec.T < (spec.launch or Spec.LAUNCH) + Spec.GUARD_DAYS
  local candidates, checks = {}, {}
  for _, info in ipairs(analysis.list) do
    local b, a = info.b, info.a
    stats.tracked = stats.tracked + 1
    stats.maxN = max(stats.maxN, b.n or 0)
    if (b.n or 0) >= Spec.MIN_DAYS then
      stats.ready = stats.ready + 1
      if b.conf == "ALTA" then stats.reliable = stats.reliable + 1 end
      if b.trend ~= "desconocida" then
        stats.trendKnown = stats.trendKnown + 1
        if b.trend == "bajando" then stats.down = stats.down + 1 end
      end
    end
    if a.verdict == "PROTECCION" then stats.guarded = stats.guarded + 1 end
    if a.verdict == "CHOLLO" and info.at and (CONF_RANK[b.conf] or 0) >= (CONF_RANK[mode.specMinConf] or 3) then
      info.flip = specFlip(ctx, spec, info.id, info, stats.budget)
      local best = unknownDepth(ctx, spec, info.id, info, info.flip, stats.budget)
      if info.flip.accept then
        candidates[#candidates + 1] = info
      elseif best and best.accept then
        checks[#checks + 1] = info
      elseif info.flip.reason == "SIN_UNIDADES" and info.flip.capBudget < (info.lots and info.lots[1][1] or info.p) then
        stats.budgetShort = stats.budgetShort + 1
      end
    end
  end
  stats.falling = stats.trendKnown >= 3 and stats.down * 2 >= stats.trendKnown

  -- Chollos: de más a menos ganancia, sin pasar entre todos del presupuesto.
  table.sort(candidates, function(x, y)
    if x.flip.profit ~= y.flip.profit then return x.flip.profit > y.flip.profit end
    return x.id < y.id
  end)
  local left = stats.budget
  for _, info in ipairs(candidates) do
    local flip, trimmed = info.flip, false
    if flip.cost > left then flip, trimmed = specFlip(ctx, spec, info.id, info, min(stats.budget, left * 4)), true end
    if flip.accept and flip.cost <= left then
      left = left - flip.cost
      local name = specName(ctx, info.id, info.entry)
      local when = info.lots and (" Precio confirmado en la subasta " .. agoText(spec.now - info.at) .. ".")
        or (" Precio de " .. agoText(spec.now - info.at) .. ".")
      rows[#rows + 1] = {kind = "flip", icon = info.id, value = flip.profit,
        title = string.format("Chollo: %s a %s (%s %% por debajo de lo normal)", name, Money(info.p), Spec.Texts.Pct(info.a.dBp)),
        detail = Spec.Texts.Flip(flip, Money) .. "." .. when .. " " .. Spec.Texts.Conf(info.b) .. ".",
        shopping = {{id = info.id, count = flip.units}}, flip = flip}
    elseif trimmed then
      stats.budgetShort = stats.budgetShort + 1 -- con lo que queda del presupuesto ya no compensa
    end
  end

  -- Posibles chollos: el precio es de chollo, pero el escaneo no dice cuántas hay (ver unknownDepth). Van después de
  -- los chollos de verdad (valor 0) y no gastan presupuesto: falta abrir el objeto en la subasta para saberlo. La
  -- lista de la compra lleva 1 para que «Comprar lo que falta» lo busque.
  for _, info in ipairs(checks) do
    local name = specName(ctx, info.id, info.entry)
    rows[#rows + 1] = {kind = "check", icon = info.id, value = 0,
      title = string.format("Posible chollo: %s a %s (%s %% por debajo de lo normal)", name, Money(info.p), Spec.Texts.Pct(info.a.dBp)),
      detail = "Tu escaneo no dice cuántas hay a ese precio: ábrelo en la pestaña Comprar de la subasta y el addon calculará "
        .. "la compra con lo que hay a la venta. Precio de " .. agoText(spec.now - info.at) .. ". " .. Spec.Texts.Conf(info.b) .. ".",
      shopping = {{id = info.id, count = 1}}}
  end

  -- Vende ahora: precio alto y lo tienes (bolsas o banco, sin lo ligado ni lo que no se vende).
  if mode.specSpikes then
    for _, info in ipairs(analysis.list) do
      local id = info.id
      local inBags, inBank = max(0, available[id] or 0), max(0, bankLeft[id] or 0)
      if info.a.verdict == "CARO" and inBags + inBank > 0 and sellable(id) then
        local count = inBags + inBank
        local unitNet = floor(info.p * (1 - cut))
        local vendor = ctx.vendor and ctx.vendor(id) or 0
        if not finite(vendor) then vendor = 0 end
        if unitNet > vendor * 1.05 then
          local name = specName(ctx, id, info.entry)
          local where
          if inBank == 0 then where = ""
          elseif inBags == 0 then where = " Está todo en el banco: sácalo primero."
          else where = string.format(" Llevas %d y tienes %d en el banco.", inBags, inBank) end
          local when = info.at and (" Precio de " .. agoText(spec.now - info.at) .. ".") or " Precio de hoy."
          rows[#rows + 1] = {kind = "spike", icon = id, value = unitNet * count,
            title = string.format("Vende ahora %d× %s (%s %% por encima de lo normal)", count, name, Spec.Texts.Pct(info.a.dBp)),
            detail = string.format("≈ %s en la subasta, ya descontada la comisión (hoy %s; lo normal, %s).", Money(unitNet * count),
              Money(info.p), Money(info.b.N)) .. where .. when}
        end
      end
    end
  end

  -- Balance de la semana: lo que más sube y más baja en 7 días, solo con confianza orientativa o fiable.
  local balance, balanceText = {}, nil
  if mode.balance > 0 then
    local up, down, byCat = {}, {}, {}
    for _, info in ipairs(analysis.list) do
      local d7 = info.deltas and info.deltas.d7
      if d7 and (CONF_RANK[info.b.conf] or 0) >= CONF_RANK.MEDIA then
        if d7 > 0 then up[#up + 1] = info elseif d7 < 0 then down[#down + 1] = info end
        local cat = info.entry.cat
        if type(cat) == "string" then byCat[cat] = byCat[cat] or {}; table.insert(byCat[cat], d7) end
      end
    end
    table.sort(up, function(x, y)
      if x.deltas.d7 ~= y.deltas.d7 then return x.deltas.d7 > y.deltas.d7 end
      return x.id < y.id
    end)
    table.sort(down, function(x, y)
      if x.deltas.d7 ~= y.deltas.d7 then return x.deltas.d7 < y.deltas.d7 end
      return x.id < y.id
    end)
    local function add(info, verb)
      local today = info.days[spec.T] and info.days[spec.T].v
      balance[#balance + 1] = {kind = verb == "sube" and "rise" or "fall", icon = info.id,
        title = string.format("%s %s un %s %% en 7 días", specName(ctx, info.id, info.entry), verb, Spec.Texts.Pct(info.deltas.d7)),
        detail = "Normal (14 d): " .. Money(info.b.N) .. (today and ("; hoy: " .. Money(today)) or "") .. ". "
          .. Spec.Texts.Conf(info.b) .. "."}
    end
    for i = 1, min(mode.balance, #up) do add(up[i], "sube") end
    for i = 1, min(mode.balance, #down) do add(down[i], "baja") end
    local cats = {}
    for _, cat in ipairs(Data.CATEGORY_ORDER or Spec.CATEGORIES) do
      local list = byCat[cat]
      if list and #list >= 2 then
        cats[#cats + 1] = ((Data.CATEGORY_LABELS and Data.CATEGORY_LABELS[cat]) or cat) .. " " .. Spec.Texts.SignedPct(Spec.Median(list)) .. " %"
      end
    end
    if #cats > 0 then balanceText = "Por categoría, en 7 días: " .. table.concat(cats, ", ") .. "." end
  end
  return rows, specStatus(stats, mode), balance, balanceText
end

-- Líneas de Especular para la descripción de un objeto vigilado (o nil): precio normal y cuánto se aparta el de
-- hoy, y el chollo, la protección o el aviso que toque. ctx: como el de Suggest (mode, price, age, cut, vendor,
-- name, spec). Cada línea: {left, right, color = {r, g, b}}.
local GREEN, ORANGE, GREY = {0.45, 0.9, 0.45}, {1, 0.6, 0.25}, {0.8, 0.8, 0.8}
function Engine.SpecLines(ctx, id)
  local modeKey = Engine.MODES[ctx.mode] and ctx.mode or "lazy"
  local mode = Engine.MODES[modeKey]
  if not useSpec(ctx, mode) then return nil end
  local info = specItem(ctx, ctx.spec, id)
  if not info then return nil end
  local b, a = info.b, info.a
  if (b.n or 0) < Spec.MIN_DAYS or not b.N then
    if mode.specAlways then return {{left = "Especular · " .. Spec.Texts.Learning(b.n), color = GREY}} end
    return nil
  end
  local lines = {{left = "Normal (14 d)", right = Money(b.N) .. (a.dBp and (" · hoy " .. Spec.Texts.SignedPct(a.dBp) .. " %") or "")}}
  local verdict = a.verdict
  if verdict == "CHOLLO" and info.at and (CONF_RANK[b.conf] or 0) >= (CONF_RANK[mode.specMinConf] or 3) then
    local budget = specBudget(ctx.spec)
    local flip = specFlip(ctx, ctx.spec, id, info, budget)
    local best = unknownDepth(ctx, ctx.spec, id, info, flip, budget)
    if flip.accept then
      lines[#lines + 1] = {left = string.format("Chollo: compra hasta %d a %s como máximo; no revendas por debajo de %s",
        flip.units, Money(flip.maxBuy), Money(flip.breakEven)), color = GREEN}
    elseif best and best.accept then
      lines[#lines + 1] = {left = "Posible chollo: tu escaneo no dice cuántas hay a ese precio; ábrelo en la pestaña Comprar para calcular la compra",
        color = GREEN}
    else
      -- Sin saber cuántas hay, la cuenta que se enseña es la mejor posible (best): si ni así compensa, no compensa.
      lines[#lines + 1] = {left = Spec.Texts.Flip(best or flip, Money), color = GREY}
    end
  elseif verdict == "CHOLLO" then
    -- Precio de chollo que la ventana no enseña: confianza por debajo de la que pide el modo (un orientativo en
    -- Tranquilo) o precio sin hora (el de hoy de Auctionator, que puede ser de hace horas). No se llama «Chollo».
    local low = "Precio bajo (" .. Spec.Texts.Pct(a.dBp) .. " % por debajo de lo normal): "
    lines[#lines + 1] = {left = low .. (info.at and ("en " .. mode.label .. " solo se avisa de los chollos fiables")
      or "escanea la subasta para confirmarlo"), color = GREY}
  elseif verdict == "CARO" or verdict == "ESPERA" or verdict == "BAJADA" or verdict == "PROTECCION" or verdict == "INESTABLE" then
    lines[#lines + 1] = {left = Spec.Texts.Status(a, b), color = (verdict == "CARO" or verdict == "PROTECCION") and ORANGE or GREY}
  end
  return lines
end

---------------------------------------------------------------------------
-- Sugerencias
---------------------------------------------------------------------------
function Engine.Suggest(ctx)
  local modeKey = Engine.MODES[ctx.mode] and ctx.mode or "lazy"
  local mode = Engine.MODES[modeKey]
  local cut = cutOf(ctx)
  local result = {mode = modeKey, warnings = {}, notes = {}, sections = {now = {}, farm = {}, group = {}, spec = {}},
                  order = mode.order, showEmpty = mode.showEmpty, tableButton = mode.tableButton}
  local status = Engine.DbStatus(ctx, modeKey)
  result.db = status
  if status.level ~= "ok" then result.warnings[#result.warnings + 1] = {level = status.level, text = status.text} end
  local me = ctx.me or {}
  local myProfs = me.profs or {}
  local bags = ctx.bags or {}
  local bank = ctx.bank or {}
  local hasPrices = status.source and (status.known or 0) > 0
  local now, farm, group, notes = result.sections.now, result.sections.farm, result.sections.group, result.notes
  local guildNames = sortedKeys(ctx.guild or {})

  -- 0. Avisos de rango: estás a punto de topar una profesión. Las principales se entrenan con un instructor;
  -- las secundarias pueden pedir un libro o una misión. Cada rango pide un nivel de personaje.
  local myLevel = finite(me.level) and me.level or nil
  for _, key in ipairs(sortedKeys(myProfs)) do
    local rank, cap = myProfs[key], me.profMax and me.profMax[key]
    local prof = Data.PROFESSIONS[key]
    if finite(rank) and finite(cap) and cap < 300 and rank >= cap - 10 and prof then
      local nextTier
      for _, tier in ipairs(Data.TIERS) do if tier.max > cap then nextTier = tier; break end end
      local rankInfo = nextTier and (prof.primary and {how = "trainer", level = nextTier.level}
        or (Data.SECONDARY_RANKS[key] and Data.SECONDARY_RANKS[key][nextTier.max]))
      if rankInfo then
        local label, tierName, title, detail = prof.label, nextTier.name
        local progress = string.format("Vas por %d de %d.", rank, cap)
        local book = rankInfo.book and ("«" .. itemName(ctx, rankInfo.book) .. "»")
        if rankInfo.level and myLevel and myLevel < rankInfo.level then
          title = string.format("%s: rango %s a partir del nivel %d", label, tierName, rankInfo.level)
          detail = progress .. string.format(" Hasta el nivel %d no podrás aprenderlo y sin él no pasarás de %d.", rankInfo.level, cap)
          if book then detail = detail .. " Se aprende con el libro " .. book .. ", que vende un mercader."
          elseif rankInfo.how == "quest" then detail = detail .. " Se consigue con una misión." end
        elseif rankInfo.how == "book" then
          title = string.format("%s: compra el libro de rango %s", label, tierName)
          detail = progress .. " Se aprende con el libro " .. book .. ", que vende un mercader. Sin él dejarás de subir."
        elseif rankInfo.how == "quest" then
          title = string.format("%s: misión de rango %s", label, tierName)
          detail = progress .. string.format(" El rango %s se consigue con una misión. Sin ella dejarás de subir.", tierName)
        else
          title = string.format("Entrena %s: rango %s", label, tierName)
          detail = progress .. " Sin entrenar dejarás de subir."
        end
        notes[#notes + 1] = {kind = "train", title = title, detail = detail}
      end
    end
  end

  -- Unidades disponibles en las bolsas (se reservan cuando sugerimos usarlas en una receta).
  local available = {}
  for id, bag in pairs(bags) do
    if not bag.bound then available[id] = bag.count end
  end
  -- Lo que queda en el banco sin reservar para tus recetas (lo ligado no cuenta, igual que en las bolsas).
  local bankLeft = {}
  for id, entry in pairs(bank) do
    if not entry.bound and finite(entry.count) and entry.count > 0 then bankLeft[id] = entry.count end
  end
  local bankDays = (finite(ctx.bankAt) and finite(ctx.now)) and floor((ctx.now - ctx.bankAt) / 86400) or nil
  local bankSeen = (bankDays and bankDays > 0) and (" Banco visto hace " .. plural(bankDays, "día", "días") .. ".") or ""

  local recipes = recipeList(ctx)
  local myProducts = {}
  for _, r in ipairs(recipes) do myProducts[r.product] = true end
  -- Especular: análisis de la lista vigilada (antes de las ventas, que llevan sus notas de precio bajo o alto).
  local analysis = specAnalyze(ctx, mode)
  local sellNotes = mode.specNotes and analysis or nil

  if hasPrices and mode.sections.now then
    -- 1. Recetas propias (fundición incluida).
    local function profitable(econ)
      return econ and econ.profit > 0 and econ.profit * max(1, econ.canMake) >= mode.minCraftProfit
        and econ.margin >= mode.minCraftMargin
    end
    local function evaluate(recipe)
      local econ = recipeEconomics(ctx, recipe, available, mode)
      if profitable(econ) and (econ.canMake > 0 or not mode.craftNeedsBags) then return econ end
    end
    -- Lo del banco que justifica ir a por él para una receta. A tope no cuenta lo que vende un mercader: por eso solo
    -- no se va al banco (se compra allí); pero si ya lo tienes en el banco, se saca en vez de comprarlo (ver draw).
    local function bankStock(id)
      if mode.vendorUnlimited and vendorCheaper(ctx, id) then return 0 end
      return bankLeft[id] or 0
    end
    -- La receta con lo de las bolsas más lo del banco, solo si de verdad hay que sacar algo del banco.
    local function evaluateBank(recipe)
      local pool, inBank = {}, false
      for _, reagent in ipairs(recipe.reagents or {}) do
        local id = reagent[1]
        pool[id] = max(0, available[id] or 0) + bankStock(id)
        if bankStock(id) > 0 then inBank = true end
      end
      if not inBank then return nil end
      local econ = recipeEconomics(ctx, recipe, pool, mode)
      if not (profitable(econ) and econ.canMake > 0) then return nil end
      for _, reagent in ipairs(recipe.reagents) do
        if reagent[2] * econ.canMake > max(0, available[reagent[1]] or 0) and bankStock(reagent[1]) > 0 then return econ end
      end
    end
    local function byCandidate(a, b)
      if a.value ~= b.value then return a.value > b.value end
      return a.name < b.name
    end
    local accepted = 0
    -- Reparte lo que usa una receta: primero las bolsas, luego el banco (también lo que vende un mercader: si ya lo
    -- tienes, no se compra) y lo que falte, al mercader. Reserva lo del banco; lo de las bolsas, solo si keepBags.
    -- Devuelve los textos de lo que se saca y de lo que se compra, y lo que se compra ({id, count, name}).
    local function draw(recipe, econ, keepBags)
      local takes, buys, vendorBuys = {}, {}, {}
      for _, reagent in ipairs(recipe.reagents) do
        local id, used = reagent[1], reagent[2] * econ.canMake
        local inBags = max(0, available[id] or 0)
        local fromBags = min(inBags, used)
        local fromBank = min(bankLeft[id] or 0, used - fromBags)
        local short = used - fromBags - fromBank
        if fromBank > 0 then
          takes[#takes + 1] = fromBank .. "× " .. itemName(ctx, id)
          bankLeft[id] = bankLeft[id] - fromBank
        end
        if short > 0 then
          buys[#buys + 1] = short .. "× " .. itemName(ctx, id)
          vendorBuys[#vendorBuys + 1] = {id = id, count = short, name = itemName(ctx, id)}
        end
        if keepBags then available[id] = inBags - fromBags end
      end
      return takes, buys, vendorBuys
    end
    -- Fila «Saca del banco y fabrica»: lo del banco, lo que se compra al mercader y lo que se gana.
    local function bankRow(recipe, econ, takes, buys, vendorBuys, kind)
      local value = econ.profit * econ.canMake
      local detail = "Del banco: " .. listNames(takes, 6) .. "."
      if #buys > 0 then detail = detail .. " Compra a un mercader " .. listNames(buys, 6) .. "." end
      detail = detail .. string.format(" Ganas ≈ %s más que vendiendo los materiales.", Money(value))
      if recipe.station then detail = detail .. " Necesitas: " .. recipe.station .. "." end
      now[#now + 1] = {kind = kind, icon = recipe.product, value = value, keep = true,
        title = string.format("Saca del banco y %s %d× %s", recipe.prof == "mining" and "funde" or "fabrica",
          econ.canMake * econ.qty, itemName(ctx, recipe.product)),
        detail = detail .. bankSeen .. ageNote(econ.productAge, econ.productAtLeast),
        vendorBuys = #vendorBuys > 0 and vendorBuys or nil}
    end
    -- Reserva lo del banco que usa la receta y, si se muestra, también lo de las bolsas y la sugiere.
    local function takeFromBank(recipe, econ, show)
      local takes, buys, vendorBuys = draw(recipe, econ, show)
      if not show then return end
      accepted = accepted + 1
      bankRow(recipe, econ, takes, buys, vendorBuys, "bank")
    end

    local candidates = {}
    for _, recipe in ipairs(recipes) do
      local econ = evaluate(recipe)
      if econ then
        candidates[#candidates + 1] = {recipe = recipe, value = econ.profit * max(1, econ.canMake), name = itemName(ctx, recipe.product)}
      end
    end
    table.sort(candidates, byCandidate)
    for _, candidate in ipairs(candidates) do
      if accepted >= mode.maxCrafts then break end
      -- Se recalcula con lo que quede tras reservar las recetas anteriores.
      local recipe, econ = candidate.recipe, evaluate(candidate.recipe)
      -- Si lo que falta está en el banco, se sugiere sacarlo en vez de comprarlo.
      local withBank = econ and econ.canMake == 0 and evaluateBank(recipe)
      if withBank then
        takeFromBank(recipe, withBank, true)
      elseif econ then
        accepted = accepted + 1
        local value = econ.profit * max(1, econ.canMake)
        local verb = recipe.prof == "mining" and "Funde" or "Fabrica"
        local per = econ.qty > 1 and ("por tanda de " .. econ.qty) or "por unidad"
        local margin = econ.margin > 2 and "más del 200 %" or (floor(econ.margin * 100 + 0.5) .. " %")
        local title, detail, shop, vendorBuys, placed
        if econ.canMake > 0 then
          -- A tope, lo que vende un mercader no limita: si lo tienes en el banco se saca y si no, se dice cuánto comprar.
          local takes, buys
          takes, buys, vendorBuys = draw(recipe, econ, true)
          if #takes > 0 then
            bankRow(recipe, econ, takes, buys, vendorBuys, "craft")
            placed = true
          else
            title = string.format("%s %d× %s", verb, econ.canMake * econ.qty, candidate.name)
            detail = (#buys > 0 and ("Compra a un mercader " .. listNames(buys, 6) .. "; lo demás ya lo llevas.") or "Con lo que llevas.")
              .. string.format(" Ganas ≈ %s más que vendiendo los materiales.", Money(econ.profit * econ.canMake))
          end
        else
          -- Lista de la compra para la subasta: sin lo que tienes en el banco ni lo que un mercader vende más barato.
          local parts, units = {}, 0
          shop, vendorBuys = {}, {}
          for _, miss in ipairs(econ.missing) do
            local text = miss.count .. "× " .. itemName(ctx, miss.id)
            local inBank = bankLeft[miss.id] or 0
            if inBank > 0 then
              text = text .. " (tienes " .. inBank .. " en el banco" .. ((miss.vendor and miss.count > inBank) and "; el resto, a un mercader" or "") .. ")"
            elseif miss.vendor then
              text = text .. " (cómpralo a un mercader)"
            else
              local who = gathererFor(ctx, miss.id, guildNames)
              if who then text = text .. ": pídeselo a " .. who end
            end
            if miss.count > inBank then
              if miss.vendor then
                vendorBuys[#vendorBuys + 1] = {id = miss.id, count = miss.count - inBank, name = itemName(ctx, miss.id)}
              else
                shop[#shop + 1] = {id = miss.id, count = miss.count - inBank}
              end
            end
            units = units + miss.count
            parts[#parts + 1] = text
          end
          title = string.format("%s %s para vender", verb, candidate.name)
          detail = string.format("≈ %s de beneficio %s (%s sobre el coste). %s %s.", Money(econ.profit), per, margin,
            units == 1 and "Te falta" or "Te faltan", table.concat(parts, "; "))
          -- Lo que ya llevas o guardas en el banco para esta receta no se sugiere vender.
          for _, reagent in ipairs(recipe.reagents) do
            local have = available[reagent[1]] or 0
            if have > 0 then available[reagent[1]] = have - min(have, reagent[2]) end
            if bankLeft[reagent[1]] then bankLeft[reagent[1]] = 0 end
          end
        end
        if not placed then
          if recipe.station then detail = detail .. " Necesitas: " .. recipe.station .. "." end
          now[#now + 1] = {kind = "craft", icon = recipe.product, title = title, detail = detail .. ageNote(econ.productAge, econ.productAtLeast),
            value = value, keep = true, shopping = shop and #shop > 0 and shop or nil,
            vendorBuys = vendorBuys and #vendorBuys > 0 and vendorBuys or nil}
        end
      end
    end

    -- 1b. Lo que guardas en el banco y usan tus recetas: se saca para fabricar, no para vender. Si no cabe en la lista
    -- (o en tranquilo no compensa el viaje al banco) no se muestra, pero tampoco se sugiere venderlo.
    local bankCandidates = {}
    for _, recipe in ipairs(recipes) do
      local econ = evaluateBank(recipe)
      if econ then
        bankCandidates[#bankCandidates + 1] = {recipe = recipe, value = econ.profit * econ.canMake, name = itemName(ctx, recipe.product)}
      end
    end
    table.sort(bankCandidates, byCandidate)
    for _, candidate in ipairs(bankCandidates) do
      local econ = evaluateBank(candidate.recipe)
      if econ then
        takeFromBank(candidate.recipe, econ, accepted < mode.maxCrafts and econ.revenue * econ.canMake >= mode.minBankTrip)
      end
    end

    -- 2. Qué vender y dónde.
    local function sellable(id, entry)
      if Data.KEEP[id] then return false end
      if entry.classID and Data.SKIP_CLASS[entry.classID] and not myProducts[id] then return false end
      return true
    end
    local sells, vendorBetter, staleSells = {}, {}, 0
    for _, id in ipairs(sortedKeys(bags)) do
      local entry = bags[id]
      local count = available[id] or 0
      local vendor = entry.vendor or (ctx.vendor and ctx.vendor(id)) or 0
      if not finite(vendor) then vendor = 0 end
      if entry.quality ~= 0 and count > 0 and sellable(id, entry) then
        local price, age, atLeast = quote(ctx, id)
        if price then
          local unitNet = floor(price * (1 - cut))
          if unitNet > vendor * 1.05 then
            sells[#sells + 1] = {id = id, count = count, value = unitNet * count, age = age, atLeast = atLeast, name = itemName(ctx, id),
                                 price = price}
            if isStale(age) then staleSells = staleSells + 1 end
          elseif vendor > 0 then
            vendorBetter[#vendorBetter + 1] = {id = id, count = count, value = vendor * count, name = itemName(ctx, id)}
          end
        end
      end
    end
    table.sort(sells, byValue)
    if #sells > 0 then
      if mode.sellsInOneRow then
        local names, total = {}, 0
        for i, sell in ipairs(sells) do
          total = total + sell.value
          names[i] = sell.count .. "× " .. sell.name
        end
        local note = staleSells > 0 and (" Algunos precios son viejos: Auctionator los actualizará al publicar.") or ""
        now[#now + 1] = {kind = "sell", icon = sells[1].id, title = "Vende en la subasta (≈ " .. Money(total) .. ")",
          detail = listNames(names) .. ". Acepta el precio que proponga Auctionator." .. note .. specGroupNote(sellNotes, sells),
          value = total}
      else
        for i, sell in ipairs(sells) do
          if i > 6 then break end
          now[#now + 1] = {kind = "sell", icon = sell.id, title = string.format("Vende %d× %s", sell.count, sell.name),
            detail = "≈ " .. Money(sell.value) .. " en la subasta, ya descontada la comisión" .. ageNote(sell.age, sell.atLeast) .. "."
              .. specSellNote(sellNotes, sell),
            value = sell.value}
        end
      end
    end
    if #vendorBetter > 0 then
      table.sort(vendorBetter, byValue)
      local names, total = {}, 0
      for i, item in ipairs(vendorBetter) do total = total + item.value; names[i] = item.name end
      now[#now + 1] = {kind = "vendor", icon = vendorBetter[1].id, title = "Al vendedor, no a la subasta (≈ " .. Money(total) .. ")",
        detail = listNames(names) .. ": el vendedor paga más de lo que sacarías tras la comisión.", value = total}
    end

    -- 2b. Lo que tienes guardado en el banco y vale dinero, también lo que fabricas tú (los lingotes de un minero),
    -- salvo lo reservado arriba para tus recetas.
    local bankSells, bankTotal = {}, 0
    for _, id in ipairs(sortedKeys(bank)) do
      local entry = bank[id]
      local count = bankLeft[id] or 0
      if count > 0 and entry.quality ~= 0 and sellable(id, entry) then
        local price, age = quote(ctx, id)
        local vendor = entry.vendor or (ctx.vendor and ctx.vendor(id)) or 0
        if not finite(vendor) then vendor = 0 end
        if price and not isStale(age) then
          local unitNet = floor(price * (1 - cut))
          if unitNet > vendor * 1.05 and unitNet * count >= 1000 then
            bankSells[#bankSells + 1] = {id = id, value = unitNet * count, name = count .. "× " .. itemName(ctx, id)}
            bankTotal = bankTotal + unitNet * count
          end
        end
      end
    end
    if #bankSells > 0 and bankTotal >= mode.minBankTrip then
      table.sort(bankSells, byValue)
      local names = {}
      for i, item in ipairs(bankSells) do names[i] = item.name end
      now[#now + 1] = {kind = "bank", icon = bankSells[1].id, title = "Saca del banco y vende (≈ " .. Money(bankTotal) .. ")",
        detail = listNames(names) .. "." .. bankSeen, value = bankTotal}
    end
  end

  -- Chatarra gris: no necesita precios de subasta.
  local grayValue, grayItems = 0, 0
  for _, entry in pairs(bags) do
    if entry.quality == 0 then
      local vendor = entry.vendor or 0
      if vendor > 0 then grayValue = grayValue + vendor * entry.count; grayItems = grayItems + entry.count end
    end
  end
  if grayValue > 0 and mode.sections.now then
    now[#now + 1] = {kind = "gray", title = "Vende la chatarra gris (≈ " .. Money(grayValue) .. ")",
      detail = grayItems == 1 and "1 objeto gris: cualquier vendedor te lo compra."
        or (grayItems .. " objetos grises: cualquier vendedor te los compra."), value = grayValue}
  end

  -- 3. Qué recoger y dónde.
  if hasPrices and mode.sections.farm then
    local routes = {}
    for _, prof in ipairs({"mining", "herbalism", "skinning"}) do
      local skill = myProfs[prof]
      if skill then
        for _, node in ipairs(Data.GATHER[prof]) do
          if skill >= node.skill and not node.rare then
            local primary, primaryAge = quote(ctx, node.items[1][1])
            if primary and not isStale(primaryAge) then
              local value = 0
              for _, item in ipairs(node.items) do
                local price, age = quote(ctx, item[1])
                if price and not isStale(age) then value = value + floor(price * (1 - cut)) * item[2] end
              end
              routes[#routes + 1] = {prof = prof, node = node, value = floor(value), name = itemName(ctx, node.items[1][1])}
            end
          end
        end
      end
    end
    table.sort(routes, function(a, b)
      if a.value ~= b.value then return a.value > b.value end
      return a.name < b.name
    end)
    local per = {mining = "veta", herbalism = "planta", skinning = "bicho"}
    local function routeTitle(route) return route.name .. (route.node.note and (" (" .. route.node.note .. ")") or "") end
    if mode.routes == "level" then
      local level, best, fits = me.level or 0, nil, false
      for _, route in ipairs(routes) do
        local band = route.node.level
        if band and level >= band[1] - 5 and level <= band[2] + 5 then best, fits = route, true; break end
      end
      best = best or routes[1]
      if best then
        farm[#farm + 1] = {kind = "route", icon = best.node.items[1][1],
          title = (fits and "Por tus zonas, no te saltes: " or "Si pasas por sus zonas, recoge: ") .. routeTitle(best),
          detail = "≈ " .. Money(best.value) .. " por " .. per[best.prof] .. ". " .. best.node.zones .. ".",
          value = best.value}
      end
    else
      local shown = {}
      for _, route in ipairs(routes) do
        shown[route.prof] = (shown[route.prof] or 0) + 1
        if shown[route.prof] <= 2 then
          farm[#farm + 1] = {kind = "route", icon = route.node.items[1][1], title = "Farmea " .. routeTitle(route),
            detail = "≈ " .. Money(route.value) .. " por " .. per[route.prof] .. " · " .. route.node.zones, value = route.value}
        end
      end
      table.sort(farm, byValue)
      -- Tela para tu nivel (va al final: no se compara con el valor por nodo).
      local level, bestCloth = me.level or 0, nil
      for _, cloth in ipairs(Data.CLOTH) do
        if level >= cloth.minLevel and level <= cloth.maxLevel + 5 then
          local price, age = quote(ctx, cloth.item)
          if price and not isStale(age) and (not bestCloth or price > bestCloth.price) then
            bestCloth = {cloth = cloth, price = price}
          end
        end
      end
      if bestCloth then
        farm[#farm + 1] = {kind = "cloth", icon = bestCloth.cloth.item, title = "Tela: " .. itemName(ctx, bestCloth.cloth.item),
          detail = "≈ " .. Money(floor(bestCloth.price * (1 - cut))) .. " por unidad. Mata " .. bestCloth.cloth.mobs .. ".",
          value = 0, keep = true}
      end
    end
  end

  -- 4. Hermandad.
  local guild = ctx.guild or {}
  local enchanter, enchanterSkill
  local covered = {}
  local members = 0
  -- Lo que cada profesión puede usar de tus bolsas: se calcula una vez, no por cada amigo (hermandades grandes).
  local usableByProf = {}
  if next(guild) then
    local availableIDs = sortedKeys(available)
    for prof, demand in pairs(Data.DEMAND) do
      local list = {}
      for _, id in ipairs(availableIDs) do
        if demand[id] and available[id] >= 5 then list[#list + 1] = id end
      end
      usableByProf[prof] = list
    end
  end
  for _, name in ipairs(mode.sections.group and guildNames or {}) do
    local friend = guild[name]
    if name ~= me.name and type(friend.profs) == "table" then
      members = members + 1
      for prof in pairs(friend.profs) do covered[prof] = true end
      -- 4a. Lo que llevas y tu amigo usa (una fila por amigo).
      local names, value, labels = {}, 0, {}
      local seenItem = {}
      for _, prof in ipairs(sortedKeys(friend.profs)) do
        local demand, skill = Data.DEMAND[prof], friend.profs[prof]
        if demand then
          local used = false
          for _, id in ipairs(usableByProf[prof] or {}) do
            if not seenItem[id] and usefulFor(skill, id) then
              seenItem[id], used = true, true
              names[#names + 1] = itemName(ctx, id)
              local price = hasPrices and quote(ctx, id)
              if price then value = value + floor(price * cut) * available[id] end
            end
          end
          if used then labels[#labels + 1] = Data.PROFESSIONS[prof].label .. " " .. skill end
        end
      end
      if #names > 0 then
        group[#group + 1] = {kind = "friend", title = string.format("%s (%s) usa lo que llevas", name, table.concat(labels, ", ")),
          detail = listNames(names) .. ". Antes de venderlo, pregúntale: a precio de subasta os ahorráis la comisión" ..
            (value > 0 and (" (≈ " .. Money(value) .. ")") or "") .. ".", value = value}
      end
      -- 4b. Recetas rentables de tu amigo que usan tus materiales.
      for _, craft in ipairs(friend.crafts or {}) do
        local uses, units = {}, math.huge
        for _, reagent in ipairs(craft.reagents or {}) do
          local have = available[reagent[1]] or 0
          if have > 0 then uses[#uses + 1] = itemName(ctx, reagent[1]); units = min(units, floor(have / reagent[2])) end
        end
        if #uses > 0 and finite(craft.profit) and craft.profit > 0 then
          if units == math.huge or units < 1 then units = 1 end
          local per = (craft.qty or 1) > 1 and ("por tanda de " .. craft.qty) or "por unidad"
          group[#group + 1] = {kind = "friendcraft", icon = craft.product,
            title = string.format("%s puede fabricar %s", name, itemName(ctx, craft.product)),
            detail = string.format("≈ %s de beneficio %s con %s.", Money(craft.profit), per,
              #uses == 1 and ("tu " .. uses[1]) or ("tus materiales: " .. listNames(uses, 3))),
            value = craft.profit * units}
        end
      end
      local skill = friend.profs.enchanting
      if skill and (not enchanterSkill or skill > enchanterSkill) then enchanter, enchanterSkill = name, skill end
    end
  end
  -- 4c. Verdes y azules que la subasta no valora: los desencantas tú si eres el mejor encantador; si no, se los das
  -- al mejor de la hermandad.
  local mySkill = finite(myProfs.enchanting) and myProfs.enchanting > 0 and myProfs.enchanting or nil
  local enchantMyself = mySkill ~= nil and (not enchanterSkill or mySkill >= enchanterSkill)
  if (enchantMyself or enchanter) and hasPrices and mode.sections.group then
    local pieces = 0
    for id, entry in pairs(bags) do
      if entry.equip and not entry.bound and (entry.quality == 2 or entry.quality == 3) and not quote(ctx, id) then
        pieces = pieces + entry.count
      end
    end
    if pieces > 0 then
      local what = plural(pieces, "pieza verde o azul", "piezas verdes o azules")
      local detail = pieces == 1 and "No tiene precio en la subasta. Desencantada suele valer más."
        or "No tienen precio en la subasta. Desencantadas suelen valer más."
      if enchantMyself then
        now[#now + 1] = {kind = "disenchant", title = "Desencanta " .. what, detail = detail, value = 0}
      else
        group[#group + 1] = {kind = "disenchant", title = string.format("Dale a %s %s", enchanter, what), detail = detail, value = 0}
      end
    end
  end
  -- 4d. Profesiones que le faltan a la hermandad (solo a tope y con varios amigos conocidos).
  if mode.guildGaps and members >= 2 then
    for prof in pairs(myProfs) do covered[prof] = true end
    local missingProfs = {}
    for _, key in ipairs({"alchemy", "enchanting", "engineering", "blacksmithing", "tailoring", "leatherworking", "mining", "herbalism", "skinning"}) do
      if not covered[key] then missingProfs[#missingProfs + 1] = Data.PROFESSIONS[key].label end
    end
    if #missingProfs > 0 then
      local one = #missingProfs == 1
      group[#group + 1] = {kind = "coverage", title = (one and "A la hermandad le falta: " or "A la hermandad le faltan: ") ..
        listNames(missingProfs, 3),
        detail = (one and "Quien la aprenda" or "Quien aprenda alguna") .. " tendrá clientes y materiales del resto del grupo.", value = -1}
    end
  end

  -- 5. Especular: chollos, «Vende ahora» y el balance de la semana.
  if analysis then
    local function specSellable(id)
      local entry = bags[id] or bank[id]
      if type(entry) ~= "table" or entry.quality == 0 or Data.KEEP[id] then return false end
      return not (entry.classID and Data.SKIP_CLASS[entry.classID] and not myProducts[id])
    end
    local bankFree = {}
    for id, count in pairs(bankLeft) do bankFree[id] = count end
    local rows, specState, balance, balanceText = specRows(ctx, mode, analysis, available, bankFree, specSellable, cut)
    for _, row in ipairs(rows) do result.sections.spec[#result.sections.spec + 1] = row end
    result.spec = specState
    result.balance, result.balanceText = mode.balance > 0 and balance or nil, balanceText
  elseif mode.specAlways then
    result.spec = {level = "warn", text = "El historial de precios no está disponible en esta sesión: mira /oro sondeo."}
    result.balance = {}
  end

  -- Ordenar y recortar según el modo. Las recetas aceptadas y la tela nunca se recortan.
  for key, list in pairs(result.sections) do
    local kept, others = {}, {}
    for _, item in ipairs(list) do
      if item.keep then kept[#kept + 1] = item else others[#others + 1] = item end
    end
    table.sort(others, byValue)
    local limit = mode.limits[key]
    local out = {}
    for _, item in ipairs(kept) do if item.kind ~= "cloth" then out[#out + 1] = item end end
    for _, item in ipairs(others) do
      if #out >= limit then break end
      out[#out + 1] = item
    end
    for _, item in ipairs(kept) do if item.kind == "cloth" then out[#out + 1] = item end end
    table.sort(out, function(a, b)
      if a.kind == "cloth" or b.kind == "cloth" then return b.kind == "cloth" and a.kind ~= "cloth" end
      return byValue(a, b)
    end)
    result.sections[key] = out
  end
  return result
end

return Engine

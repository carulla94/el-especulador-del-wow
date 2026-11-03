-- Oro de Hermandad: motor de sugerencias.
-- Lógica pura: no llama a la API de WoW. Recibe un "contexto" con precios, bolsas, banco,
-- profesiones y hermandad, y devuelve avisos y sugerencias ordenadas por secciones.
local _, ns = ...
ns = ns or {}
local Data = ns.Data
local Engine = {}
ns.Engine = Engine

Engine.AH_CUT = 0.05          -- comisión por defecto de la subasta (se puede cambiar con /oro comision)
Engine.STALE_ITEM_DAYS = 3    -- un precio con más días se considera viejo

Engine.MODES = {
  lazy = {
    label = "Tranquilo", staleHours = 24, freshDays = 1, minFreshShare = 0.3, minCoverage = 0.2,
    limits = {now = 4, farm = 1, group = 1}, maxCrafts = 2,
    craftNeedsBags = true, minCraftProfit = 500, minCraftMargin = 0.10,
  },
  farm = {
    label = "A tope", staleHours = 6, freshDays = 1, minFreshShare = 0.6, minCoverage = 0.25,
    limits = {now = 8, farm = 5, group = 4}, maxCrafts = 4,
    craftNeedsBags = false, minCraftProfit = 500, minCraftMargin = 0.15,
  },
}

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

local function ageNote(age, atLeast)
  if age and atLeast and age >= 21 then return " · precio de hace más de 3 semanas" end
  if isStale(age) then return " · precio de hace " .. age .. " días" end
  return ""
end

local function sortedKeys(map)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
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
  if hours >= 48 then return floor(hours / 24) .. " días" end
  return floor(hours) .. " h"
end

-- Nivel de habilidad aproximado de cada material (para saber si a un amigo le sirve).
local TIER = {}
for _, nodes in pairs(Data.GATHER) do
  for _, node in ipairs(nodes) do
    for i, item in ipairs(node.items) do
      if i <= 2 and (TIER[item[1]] == nil or node.skill < TIER[item[1]]) then TIER[item[1]] = node.skill end
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
  if finite(ctx.dbUpdatedAt) and finite(ctx.now) then status.hours = max(0, (ctx.now - ctx.dbUpdatedAt) / 3600) end
  local known, fresh, withAge = 0, 0, 0
  for _, id in ipairs(Data.BASKET) do
    local price, age = quote(ctx, id)
    if price then
      known = known + 1
      if age then
        withAge = withAge + 1
        if age <= mode.freshDays then fresh = fresh + 1 end
      end
    end
  end
  status.known, status.total = known, #Data.BASKET
  status.coverage = known / #Data.BASKET
  if withAge > 0 then status.freshShare = fresh / withAge end
  local scanHint = ctx.autoscan == false
    and " Activa «escanear al abrir la subasta» en las opciones de Auctionator o pulsa su escaneo completo."
    or " Haz un escaneo completo con Auctionator en la subasta."

  if known == 0 then
    status.level, status.text = "error", "Aún no hay precios." .. scanHint
  elseif status.coverage < mode.minCoverage then
    status.level = "warn"
    status.text = string.format("Solo hay precio de %d de %d materiales de referencia.%s", known, #Data.BASKET, scanHint)
  elseif status.hours and status.hours > mode.staleHours then
    status.level = "warn"
    status.text = "Precios de hace " .. hoursText(status.hours) .. "." .. scanHint
  elseif status.freshShare and status.freshShare < mode.minFreshShare then
    status.level = "warn"
    status.text = string.format("Solo el %d%% de los precios es de hoy o ayer.%s", floor(status.freshShare * 100 + 0.5), scanHint)
  elseif not status.hours and not status.freshShare then
    status.level = "warn"
    status.text = "No sé cuándo se escaneó la subasta." .. scanHint
  else
    status.level = "ok"
    status.text = status.hours and ("Precios al día (hace " .. hoursText(status.hours) .. ").") or "Precios al día."
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

-- Lo que vale un material que ya llevas (lo que te darían por él, o lo que cuesta reponerlo si es de mercader).
local function ownedValue(ctx, id, cut)
  local price = quote(ctx, id)
  local buy = ctx.vendorBuy and ctx.vendorBuy(id)
  local net = price and floor(price * (1 - cut)) or nil
  if not finite(buy) or buy <= 0 then buy = nil end
  if net and buy then return min(net, buy) end
  if net or buy then return net or buy end
  local sell = ctx.vendor and ctx.vendor(id)
  if finite(sell) and sell > 0 then return sell end
  return nil
end

local function recipeEconomics(ctx, recipe, available, modeKey)
  local cut = cutOf(ctx)
  local productPrice, productAge, productAtLeast = quote(ctx, recipe.product)
  if not productPrice then return nil end
  if modeKey ~= "lazy" and isStale(productAge) then return nil end
  local qty = recipe.qty or 1
  local revenue = floor(productPrice * (1 - cut)) * qty
  local cost, canMake, missing = 0, math.huge, {}
  for _, reagent in ipairs(recipe.reagents or {}) do
    local id, need = reagent[1], reagent[2]
    local have = available[id] or 0
    canMake = min(canMake, floor(have / need))
    local unit
    if have >= need then
      unit = ownedValue(ctx, id, cut)
    else
      local age
      unit, age = buyCost(ctx, id)
      if unit and modeKey ~= "lazy" and isStale(age) then return nil end
      missing[#missing + 1] = {id = id, count = need - have}
    end
    if not unit then return nil end -- no sabemos cuánto vale este material
    cost = cost + unit * need
  end
  if canMake == math.huge then canMake = 0 end
  if cost <= 0 then return nil end
  return {revenue = revenue, cost = cost, profit = revenue - cost, canMake = canMake, missing = missing, qty = qty,
          margin = (revenue - cost) / cost, productAge = productAge, productAtLeast = productAtLeast}
end

-- Tus recetas más rentables comprando todos los materiales (lo que se comparte con la hermandad).
function Engine.TopCrafts(ctx, limit)
  local farm = Engine.MODES.farm
  local list = {}
  for _, recipe in ipairs(ctx.recipes or {}) do
    local econ = recipeEconomics(ctx, recipe, {}, "farm")
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

-- ¿Quién de la hermandad puede conseguir este material?
local function gathererFor(ctx, id)
  local source = Data.BAR_FROM_ORE[id] or id
  local me = ctx.me and ctx.me.name
  for _, name in ipairs(sortedKeys(ctx.guild or {})) do
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
-- Sugerencias
---------------------------------------------------------------------------
function Engine.Suggest(ctx)
  local modeKey = Engine.MODES[ctx.mode] and ctx.mode or "lazy"
  local mode = Engine.MODES[modeKey]
  local cut = cutOf(ctx)
  local result = {mode = modeKey, warnings = {}, notes = {}, sections = {now = {}, farm = {}, group = {}}}
  local status = Engine.DbStatus(ctx, modeKey)
  result.db = status
  if status.level ~= "ok" then result.warnings[#result.warnings + 1] = {level = status.level, text = status.text} end
  local me = ctx.me or {}
  local myProfs = me.profs or {}
  local bags = ctx.bags or {}
  local bank = ctx.bank or {}
  local hasPrices = status.source and (status.known or 0) > 0
  local now, farm, group, notes = result.sections.now, result.sections.farm, result.sections.group, result.notes

  -- 0. Avisos de instructor: estás a punto de topar una profesión.
  for _, key in ipairs(sortedKeys(myProfs)) do
    local rank, cap = myProfs[key], me.profMax and me.profMax[key]
    if finite(rank) and finite(cap) and cap < 300 and rank >= cap - 10 and Data.PROFESSIONS[key] then
      local nextTier
      for _, tier in ipairs(Data.TIERS) do if tier.max > cap then nextTier = tier; break end end
      if nextTier then
        notes[#notes + 1] = {kind = "train", title = string.format("Entrena %s: rango %s", Data.PROFESSIONS[key].label, nextTier.name),
          detail = string.format("Vas por %d de %d. Sin entrenar dejarás de subir.", rank, cap)}
      end
    end
  end

  -- Unidades disponibles (se reservan cuando sugerimos usarlas en una receta).
  local available, reserved = {}, {}
  for id, bag in pairs(bags) do
    if not bag.bound then available[id] = bag.count end
  end

  local recipes = recipeList(ctx)
  local myProducts = {}
  for _, r in ipairs(recipes) do myProducts[r.product] = true end

  if hasPrices then
    -- 1. Recetas propias (fundición incluida).
    local function evaluate(recipe)
      local econ = recipeEconomics(ctx, recipe, available, modeKey)
      if econ and econ.profit > 0 and econ.profit * max(1, econ.canMake) >= mode.minCraftProfit
        and econ.margin >= mode.minCraftMargin and (econ.canMake > 0 or not mode.craftNeedsBags) then
        return econ
      end
    end
    local candidates = {}
    for _, recipe in ipairs(recipes) do
      local econ = evaluate(recipe)
      if econ then
        candidates[#candidates + 1] = {recipe = recipe, value = econ.profit * max(1, econ.canMake), name = itemName(ctx, recipe.product)}
      end
    end
    table.sort(candidates, function(a, b)
      if a.value ~= b.value then return a.value > b.value end
      return a.name < b.name
    end)
    local accepted = 0
    for _, candidate in ipairs(candidates) do
      if accepted >= mode.maxCrafts then break end
      -- Se recalcula con lo que quede tras reservar las recetas anteriores.
      local recipe, econ = candidate.recipe, evaluate(candidate.recipe)
      if econ then
        accepted = accepted + 1
        local value = econ.profit * max(1, econ.canMake)
        local verb = recipe.prof == "mining" and "Funde" or "Fabrica"
        local per = econ.qty > 1 and ("por tanda de " .. econ.qty) or "por unidad"
        local margin = econ.margin > 2 and "más del 200 %" or (floor(econ.margin * 100 + 0.5) .. " %")
        local title, detail
        if econ.canMake > 0 then
          title = string.format("%s %d× %s", verb, econ.canMake * econ.qty, candidate.name)
          detail = string.format("Con lo que llevas. Ganas ≈ %s más que vendiendo los materiales.", Money(econ.profit * econ.canMake))
          for _, reagent in ipairs(recipe.reagents) do
            available[reagent[1]] = (available[reagent[1]] or 0) - reagent[2] * econ.canMake
          end
        else
          local parts = {}
          for _, miss in ipairs(econ.missing) do
            local text = miss.count .. "× " .. itemName(ctx, miss.id)
            local inBank = bank[miss.id] and bank[miss.id].count or 0
            local who = gathererFor(ctx, miss.id)
            if inBank > 0 then text = text .. " (tienes " .. inBank .. " en el banco)"
            elseif who then text = text .. ": pídeselo a " .. who end
            parts[#parts + 1] = text
          end
          title = string.format("%s %s para vender", verb, candidate.name)
          detail = string.format("≈ %s de beneficio %s (%s sobre el coste). Te falta %s.", Money(econ.profit), per, margin,
            table.concat(parts, "; "))
          -- Lo que ya llevas para esta receta no se sugiere vender.
          for _, reagent in ipairs(recipe.reagents) do
            local have = available[reagent[1]] or 0
            if have > 0 then
              reserved[reagent[1]] = (reserved[reagent[1]] or 0) + min(have, reagent[2])
              available[reagent[1]] = have - min(have, reagent[2])
            end
          end
        end
        if recipe.station then detail = detail .. " Necesitas: " .. recipe.station .. "." end
        now[#now + 1] = {kind = "craft", icon = recipe.product, title = title, detail = detail .. ageNote(econ.productAge, econ.productAtLeast),
          value = value, keep = true,
          shopping = econ.canMake == 0 and econ.missing or nil}
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
      if entry.quality ~= 0 and count > 0 and sellable(id, entry) then
        local price, age, atLeast = quote(ctx, id)
        if price then
          local unitNet = floor(price * (1 - cut))
          if unitNet > vendor * 1.05 then
            sells[#sells + 1] = {id = id, count = count, value = unitNet * count, age = age, atLeast = atLeast, name = itemName(ctx, id)}
            if isStale(age) then staleSells = staleSells + 1 end
          elseif vendor > 0 then
            vendorBetter[#vendorBetter + 1] = {id = id, count = count, value = vendor * count, name = itemName(ctx, id)}
          end
        end
      end
    end
    table.sort(sells, byValue)
    if #sells > 0 then
      if modeKey == "lazy" then
        local names, total = {}, 0
        for i, sell in ipairs(sells) do
          total = total + sell.value
          names[i] = sell.count .. "× " .. sell.name
        end
        local note = staleSells > 0 and (" Algunos precios son viejos: Auctionator los actualizará al publicar.") or ""
        now[#now + 1] = {kind = "sell", icon = sells[1].id, title = "Vende en la subasta (≈ " .. Money(total) .. ")",
          detail = listNames(names) .. ". Acepta el precio que proponga Auctionator." .. note, value = total}
      else
        for i, sell in ipairs(sells) do
          if i > 6 then break end
          now[#now + 1] = {kind = "sell", icon = sell.id, title = string.format("Vende %d× %s", sell.count, sell.name),
            detail = "≈ " .. Money(sell.value) .. " en la subasta, ya descontada la comisión" .. ageNote(sell.age, sell.atLeast) .. ".",
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

    -- 2b. Lo que tienes guardado en el banco y vale dinero.
    local bankSells, bankTotal = {}, 0
    for _, id in ipairs(sortedKeys(bank)) do
      local entry = bank[id]
      if not entry.bound and entry.quality ~= 0 and sellable(id, entry) and not myProducts[id] then
        local price, age = quote(ctx, id)
        local vendor = entry.vendor or 0
        if price and not isStale(age) then
          local unitNet = floor(price * (1 - cut))
          if unitNet > vendor * 1.05 and unitNet * entry.count >= 1000 then
            bankSells[#bankSells + 1] = {id = id, value = unitNet * entry.count, name = entry.count .. "× " .. itemName(ctx, id)}
            bankTotal = bankTotal + unitNet * entry.count
          end
        end
      end
    end
    if #bankSells > 0 and (modeKey == "farm" or bankTotal >= 10000) then
      table.sort(bankSells, byValue)
      local names = {}
      for i, item in ipairs(bankSells) do names[i] = item.name end
      local seen = (finite(ctx.bankAt) and finite(ctx.now)) and floor((ctx.now - ctx.bankAt) / 86400) or nil
      now[#now + 1] = {kind = "bank", icon = bankSells[1].id, title = "Saca del banco y vende (≈ " .. Money(bankTotal) .. ")",
        detail = listNames(names) .. (seen and seen > 0 and (". Banco visto hace " .. seen .. " días.") or "."), value = bankTotal}
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
  if grayValue > 0 then
    now[#now + 1] = {kind = "gray", title = "Vende la chatarra gris (≈ " .. Money(grayValue) .. ")",
      detail = grayItems .. " objetos grises: cualquier vendedor te los compra.", value = grayValue}
  end

  -- 3. Qué recoger y dónde.
  if hasPrices then
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
    if modeKey == "lazy" then
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
  for _, name in ipairs(sortedKeys(guild)) do
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
          for _, id in ipairs(sortedKeys(available)) do
            if demand[id] and available[id] >= 5 and not seenItem[id] and usefulFor(skill, id) then
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
            detail = string.format("≈ %s de beneficio %s con tu %s.", Money(craft.profit), per, listNames(uses, 3)),
            value = craft.profit * units}
        end
      end
      local skill = friend.profs.enchanting
      if skill and (not enchanterSkill or skill > enchanterSkill) then enchanter, enchanterSkill = name, skill end
    end
  end
  -- 4c. Verdes y azules que la subasta no valora: para el mejor encantador.
  if enchanter and hasPrices then
    local pieces = 0
    for id, entry in pairs(bags) do
      if entry.equip and not entry.bound and (entry.quality == 2 or entry.quality == 3) and not quote(ctx, id) then
        pieces = pieces + entry.count
      end
    end
    if pieces > 0 then
      group[#group + 1] = {kind = "disenchant", title = string.format("Dale a %s %d piezas verdes o azules", enchanter, pieces),
        detail = "No tienen precio en la subasta. Desencantadas suelen valer más.", value = 0}
    end
  end
  -- 4d. Profesiones que le faltan a la hermandad (solo a tope y con varios amigos conocidos).
  if modeKey == "farm" and members >= 2 then
    for prof in pairs(myProfs) do covered[prof] = true end
    local missingProfs = {}
    for _, key in ipairs({"alchemy", "enchanting", "engineering", "blacksmithing", "tailoring", "leatherworking", "mining", "herbalism", "skinning"}) do
      if not covered[key] then missingProfs[#missingProfs + 1] = Data.PROFESSIONS[key].label end
    end
    if #missingProfs > 0 then
      group[#group + 1] = {kind = "coverage", title = "A la hermandad le falta: " .. listNames(missingProfs, 3),
        detail = "Quien la aprenda tendrá clientes y materiales del resto del grupo.", value = -1}
    end
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

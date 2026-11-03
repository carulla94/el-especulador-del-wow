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
    minBankTrip = 10000, -- ir al banco compensa desde 1 oro
  },
  farm = {
    label = "A tope", staleHours = 6, freshDays = 1, minFreshShare = 0.6, minCoverage = 0.25,
    limits = {now = 8, farm = 5, group = 4}, maxCrafts = 4,
    craftNeedsBags = false, minCraftProfit = 500, minCraftMargin = 0.15,
    minBankTrip = 0,
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
local function recipeEconomics(ctx, recipe, available, modeKey)
  local cut = cutOf(ctx)
  local productPrice, productAge, productAtLeast = quote(ctx, recipe.product)
  if not productPrice then return nil end
  if modeKey ~= "lazy" and isStale(productAge) then return nil end
  local qty = recipe.qty or 1
  local revenue = floor(productPrice * (1 - cut)) * qty
  local cost, canMake, withWhatYouHave, missing = 0, math.huge, math.huge, {}
  for _, reagent in ipairs(recipe.reagents or {}) do
    local id, need = reagent[1], reagent[2]
    local have = max(0, available[id] or 0)
    local fromVendor = vendorCheaper(ctx, id)
    local unlimited = fromVendor and modeKey ~= "lazy"
    withWhatYouHave = min(withWhatYouHave, floor(have / need))
    if not unlimited then canMake = min(canMake, floor(have / need)) end
    local unit
    if have >= need and not unlimited then
      unit = ownedValue(ctx, id, cut)
    else
      -- Lo que se compra (o se repone al mercader) cuesta lo que cueste comprarlo.
      local age
      unit, age = buyCost(ctx, id)
      if unit and modeKey ~= "lazy" and isStale(age) then return nil end
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

  if hasPrices then
    -- 1. Recetas propias (fundición incluida).
    local function profitable(econ)
      return econ and econ.profit > 0 and econ.profit * max(1, econ.canMake) >= mode.minCraftProfit
        and econ.margin >= mode.minCraftMargin
    end
    local function evaluate(recipe)
      local econ = recipeEconomics(ctx, recipe, available, modeKey)
      if profitable(econ) and (econ.canMake > 0 or not mode.craftNeedsBags) then return econ end
    end
    -- Lo del banco que justifica ir a por él para una receta. A tope no cuenta lo que vende un mercader: por eso solo
    -- no se va al banco (se compra allí); pero si ya lo tienes en el banco, se saca en vez de comprarlo (ver draw).
    local function bankStock(id)
      if modeKey ~= "lazy" and vendorCheaper(ctx, id) then return 0 end
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
      local econ = recipeEconomics(ctx, recipe, pool, modeKey)
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
  if grayValue > 0 then
    now[#now + 1] = {kind = "gray", title = "Vende la chatarra gris (≈ " .. Money(grayValue) .. ")",
      detail = grayItems == 1 and "1 objeto gris: cualquier vendedor te lo compra."
        or (grayItems .. " objetos grises: cualquier vendedor te los compra."), value = grayValue}
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
  for _, name in ipairs(guildNames) do
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
  if (enchantMyself or enchanter) and hasPrices then
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
  if modeKey == "farm" and members >= 2 then
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

-- Oro de Hermandad: oro ganado en la sesión y oro por hora.
local _, ns = ...
local Money = {}
ns.Money = Money

local session

local function money()
  if type(GetMoney) ~= "function" then return 0 end
  local ok, value = pcall(GetMoney)
  value = ok and ns.Items.Readable(value) or nil
  return type(value) == "number" and value or 0
end

local function now() return time and time() or 0 end

-- Empieza una sesión nueva (al entrar al juego) o continúa la guardada (tras /reload).
function Money.Start(store, reset)
  local current = money()
  if reset or type(store.session) ~= "table" or not store.session.startedAt then
    store.session = {start = current, last = current, startedAt = now(), earned = 0, spent = 0, sources = {}}
  else
    store.session.last = current
  end
  session = store.session
end

-- Llamar en PLAYER_MONEY. source: dónde estabas ("subasta", "correo", "vendedor", "botín"...).
function Money.OnPlayerMoney(source)
  if not session then return nil end
  local current = money()
  local delta = current - (session.last or current)
  session.last = current
  if delta > 0 then
    session.earned = session.earned + delta
    source = source or "otros"
    session.sources[source] = (session.sources[source] or 0) + delta
  elseif delta < 0 then
    session.spent = session.spent - delta
  end
  return delta
end

function Money.Stats()
  if not session then return nil end
  local elapsed = math.max(60, now() - (session.startedAt or now()))
  local net = (session.last or 0) - (session.start or 0)
  return {net = net, earned = session.earned, spent = session.spent, seconds = elapsed,
          perHour = math.floor(net * 3600 / elapsed), sources = session.sources}
end

/** Pure, integer-copper auction ledger shared by the Cloudflare worker and tests. */
export const MARKET = "forever.pvp.alliance.eu";
export const MAX_COPPER = 1e15;
export const DEFAULTS = Object.freeze({capitalCopper: 0, maxItemPercent: 10, minMarginPercent: 20,
  feePercent: 5, resaleDiscountPercent: 10, maxDataAgeHours: 6, maxUnits: 20});
const DAY = 86400000;
const FUTURE_TOLERANCE = 300000;
const MAX_SAFE_BIG = BigInt(Number.MAX_SAFE_INTEGER);

function object(value, label = "Datos") {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label}: se requiere un objeto.`);
  return value;
}
export function integer(value, label = "Valor", minimum = 0, maximum = MAX_COPPER) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${label}: se requiere un entero entre ${minimum} y ${maximum}.`);
  return value;
}
function text(value, limit = 160) {
  if (typeof value !== "string") throw new Error("El texto no es válido.");
  return value.trim().slice(0, limit);
}
function safeMoney(value, label = "Importe acumulado") {
  if (value > MAX_SAFE_BIG || value < -MAX_SAFE_BIG) throw new Error(`${label}: supera la precisión admitida.`);
  return Number(value);
}
function nowValue(value = Date.now()) {
  if (typeof value !== "number" || !Number.isFinite(value) || Number.isNaN(new Date(value).getTime())) throw new Error("Reloj de validación no válido.");
  return value;
}
export function instant(value) {
  if (typeof value !== "string") throw new Error("Falta la fecha ISO con zona horaria.");
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) throw new Error("Se requiere una fecha ISO válida con zona horaria.");
  const [, year, month, day, hour, minute, second, zone] = match;
  const y = Number(year), mo = Number(month), d = Number(day);
  const calendar = new Date(Date.UTC(y, mo - 1, d));
  if (mo < 1 || mo > 12 || d < 1 || calendar.getUTCFullYear() !== y || calendar.getUTCMonth() !== mo - 1 || calendar.getUTCDate() !== d || Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59 || (zone !== "Z" && (Number(zone.slice(1, 3)) > 23 || Number(zone.slice(4, 6)) > 59))) throw new Error("Fecha ISO no válida.");
  const result = Date.parse(value);
  if (!Number.isFinite(result)) throw new Error("Fecha ISO no válida.");
  return result;
}
export function stamp(value = Date.now()) { return new Date(nowValue(value)).toISOString(); }
export function itemKey(value, itemId) {
  const key = value == null ? String(itemId) : value;
  if (itemId === 0 && key === "0") return key;
  if (typeof key !== "string" || key.length > 100) throw new Error("Clave de variante no válida.");
  const parts = key.split(":");
  if (parts.length > 4) throw new Error("Clave de variante no válida.");
  const [base = "", level = "", suffix = "", species = ""] = parts;
  if ([base, level, species].some(part => part && !/^\d+$/.test(part)) || (suffix && !/^-?\d+$/.test(suffix)) || parts.some(part => part.length > 18)) throw new Error("Clave de variante no válida.");
  if (!base && (parts.length !== 4 || level || suffix || !species || BigInt(species) <= 0n || itemId !== 82800)) throw new Error("Clave de mascota no válida.");
  if (base && Number(base) !== itemId) throw new Error("La clave de variante no corresponde al ID del objeto.");
  integer(itemId, "ID de objeto", 1, Number.MAX_SAFE_INTEGER);
  return key;
}
export function emptyState() {
  return {settings: {...DEFAULTS}, status: {state: "empty", message: "Importa tus escaneos de Auctioneer para empezar.", source: "Auctioneer", checkedAt: null}, snapshots: [], transactions: [], history: [], sourceMeta: {}};
}
export function validateSettings(current = DEFAULTS, changes = {}) {
  object(current, "Ajustes"); object(changes, "Ajustes");
  if ([...Object.keys(current), ...Object.keys(changes)].some(key => !Object.hasOwn(DEFAULTS, key))) throw new Error("Ajustes desconocidos.");
  const result = {...DEFAULTS, ...current, ...changes};
  integer(result.capitalCopper, "Capital inicial"); integer(result.maxUnits, "Unidades máximas", 1, 10000);
  const ranges = {maxItemPercent: [0, 100], minMarginPercent: [0, 500], feePercent: [0, 50], resaleDiscountPercent: [0, 50], maxDataAgeHours: [.25, 168]};
  for (const [key, [low, high]] of Object.entries(ranges)) {
    if (typeof result[key] !== "number" || !Number.isFinite(result[key]) || result[key] < low || result[key] > high) throw new Error(`${key}: valor fuera de rango (${low}–${high}).`);
  }
  return result;
}
export function normalizeSnapshot(data, nowMs = Date.now()) {
  nowValue(nowMs); object(data, "Escaneo");
  if (data.market !== MARKET) throw new Error("El escaneo debe pertenecer a Europa · PvP · Alianza.");
  const observed = instant(data.observedAt);
  if (observed > nowMs + FUTURE_TOLERANCE || new Date(observed).getUTCFullYear() < 2026) throw new Error("La fecha de observación es futura o anterior a Forever.");
  if (!Array.isArray(data.items) || data.items.length > 50000) throw new Error("items debe ser una lista de hasta 50.000 objetos.");
  const seen = new Set();
  const items = data.items.map(row => {
    object(row, "Objeto");
    const itemId = integer(row.itemId, "ID de objeto", 1, Number.MAX_SAFE_INTEGER);
    const key = itemKey(row.itemKey, itemId);
    if (seen.has(key)) throw new Error("El escaneo contiene variantes duplicadas.");
    seen.add(key);
    const reference = row.referenceCopper == null ? null : integer(row.referenceCopper, "Precio histórico", 1);
    const itemObserved = instant(row.observedAt ?? data.observedAt);
    if (itemObserved > observed + 1000 || new Date(itemObserved).getUTCFullYear() < 2026) throw new Error("Fecha de observación individual no válida.");
    return {itemId, itemKey: key, name: text(row.name ?? `Objeto ${itemId}`), buyCopper: integer(row.buyCopper, "Precio de compra", 1), referenceCopper: reference,
      quantityAvailable: integer(row.quantityAvailable, "Unidades observadas", 0, 1e10), observedAt: stamp(itemObserved)};
  });
  const coverage = data.coverage ?? "unspecified";
  if (!["partial", "full", "unspecified"].includes(coverage)) throw new Error("Alcance de captura no válido.");
  const realm = data.realm == null ? null : text(data.realm);
  if (data.realm != null && (!realm || data.realm.length > 160)) throw new Error("Reino de captura no válido.");
  return {market: MARKET, realm, observedAt: stamp(observed), coverage, source: text(data.source ?? "Archivo importado"), items};
}
export function importSnapshot(state, data, nowMs = Date.now()) {
  const snapshot = normalizeSnapshot(data, nowMs);
  const current = latestSnapshot(state);
  if (current && instant(current.observedAt) > instant(snapshot.observedAt)) return {...snapshot, ignored: true};
  const unchanged = current && JSON.stringify(current) === JSON.stringify(snapshot);
  state.snapshots = [snapshot];
  if (unchanged) return {...snapshot, unchanged: true};
  state.status = {state: snapshot.items.length ? "ready" : "empty", message: snapshot.coverage === "partial" ? "Observaciones parciales importadas; no representan todo el mercado." : "Escaneo importado. Comprueba precio y unidades dentro del juego.", source: snapshot.source, checkedAt: stamp(nowMs)};
  return snapshot;
}
function latestSnapshot(state) {
  return state.snapshots.reduce((latest, snapshot) => !latest || instant(snapshot.observedAt) >= instant(latest.observedAt) ? snapshot : latest, null);
}
export function latestSnapshotRealm(state) { return latestSnapshot(state)?.realm ?? null; }

function appendLot(lots, lot) {
  lots.available = (lots.available ?? 0) + lot.quantity;
  lots.push(lot);
}
function consume(lots, quantity) {
  lots.available ??= lots.reduce((sum, lot) => sum + lot.quantity, 0);
  lots.head ??= 0;
  if (lots.available < quantity) throw new Error("La venta supera las unidades registradas.");
  let remaining = quantity, cost = 0n;
  while (remaining) {
    const lot = lots[lots.head], used = Math.min(lot.quantity, remaining);
    const allocated = lot.cost * BigInt(used) / BigInt(lot.quantity);
    cost += allocated; lot.cost -= allocated; lot.quantity -= used; remaining -= used; lots.available -= used;
    if (lot.quantity === 0) lots.head++;
  }
  return cost;
}
function positions(transactions) {
  const positions = new Map();
  for (const tx of transactions) {
    if (tx.kind === "expense") continue;
    const key = tx.itemKey ?? String(tx.itemId);
    if (!positions.has(key)) positions.set(key, {itemId: tx.itemId, itemKey: key, name: tx.name, lots: []});
    const position = positions.get(key);
    position.name = tx.name;
    if (tx.kind === "buy") appendLot(position.lots, {quantity: tx.quantity, cost: BigInt(tx.quantity) * BigInt(tx.unitCopper) + BigInt(tx.feeCopper) + BigInt(tx.depositLossCopper), createdAt: tx.createdAt});
    else if (tx.kind === "sell") consume(position.lots, tx.quantity);
  }
  return positions;
}
function grossAmount(tx) { return BigInt(tx.quantity) * BigInt(tx.unitCopper); }
function summaryOf(transactions, inventory, settings) {
  let invested = 0n, profit = 0n, cash = BigInt(settings.capitalCopper);
  for (const tx of transactions) {
    const gross = grossAmount(tx), costs = BigInt(tx.feeCopper) + BigInt(tx.depositLossCopper);
    if (tx.kind === "buy") { invested += gross + costs; cash -= gross + costs; }
    else if (tx.kind === "sell") cash += gross - costs;
    else cash -= gross + costs;
    profit += BigInt(tx.realizedProfitCopper);
  }
  return {investedCopper: safeMoney(invested), realizedProfitCopper: safeMoney(profit), inventoryCostCopper: safeMoney(inventory.reduce((sum, item) => sum + BigInt(item.totalCostCopper), 0n)), availableCapitalCopper: safeMoney(cash)};
}
export function addTransaction(state, data, nowMs = Date.now()) {
  return addTransactionCore(state, data, nowMs);
}
function addTransactionCore(state, data, nowMs, preparedPositions = null) {
  nowValue(nowMs); object(data, "Movimiento");
  if (state.transactions.length >= 100000) throw new Error("El registro supera 100.000 movimientos. Exporta una copia antes de continuar.");
  const kind = data.kind;
  if (!["buy", "sell", "expense"].includes(kind)) throw new Error("Tipo de movimiento no válido.");
  const itemId = integer(data.itemId ?? 0, "ID de objeto", kind === "expense" ? 0 : 1, Number.MAX_SAFE_INTEGER);
  const quantity = integer(data.quantity ?? 1, "Unidades", 1, 1e10);
  const unitCopper = integer(data.unitCopper, "Precio unitario");
  const feeCopper = integer(data.feeCopper ?? 0, "Comisión");
  const depositLossCopper = integer(data.depositLossCopper ?? 0, "Depósitos perdidos");
  const gross = BigInt(quantity) * BigInt(unitCopper), costs = BigInt(feeCopper) + BigInt(depositLossCopper);
  if (gross + costs > BigInt(MAX_COPPER)) throw new Error("Importe demasiado grande.");
  if (kind === "sell" && costs > gross) throw new Error("Los costes de venta superan el importe recibido.");
  const key = itemKey(data.itemKey, itemId);
  const tx = {id: (state.transactions.at(-1)?.id ?? 0) + 1, kind, itemId, itemKey: key,
    name: text(data.name ?? (kind === "expense" ? "Gasto" : `Objeto ${itemId}`)), quantity, unitCopper, feeCopper, depositLossCopper,
    createdAt: stamp(nowMs), note: text(data.note ?? "", 500), realizedProfitCopper: 0};
  const currentPositions = preparedPositions ?? positions(state.transactions);
  if (kind === "sell") {
    const lots = currentPositions.get(key)?.lots ?? [];
    tx.realizedProfitCopper = safeMoney(gross - costs - consume(lots, quantity));
  } else if (kind === "expense") tx.realizedProfitCopper = -safeMoney(gross + costs);
  if (kind === "buy") {
    if (!currentPositions.has(key)) currentPositions.set(key, {itemId, itemKey: key, name: tx.name, lots: []});
    appendLot(currentPositions.get(key).lots, {quantity, cost: gross + costs, createdAt: tx.createdAt});
  }
  if (kind !== "expense" && currentPositions.has(key)) currentPositions.get(key).name = tx.name;
  // Reject unsafe accumulated totals before changing the state.
  if (!preparedPositions) summaryOf(state.transactions.concat(tx), inventoryOf(currentPositions), validateSettings(state.settings));
  state.transactions.push(tx);
  return tx;
}
function inventoryOf(positionMap) {
  return [...positionMap.values()].filter(position => (position.lots.available ?? 0) > 0).map(position => {
    const quantity = position.lots.reduce((sum, lot) => sum + lot.quantity, 0);
    const totalCostCopper = safeMoney(position.lots.reduce((sum, lot) => sum + lot.cost, 0n));
    return {itemId: position.itemId, itemKey: position.itemKey, name: position.name, quantity, totalCostCopper, averageCostCopper: Math.round(totalCostCopper / quantity)};
  });
}
function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b), index = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[index] : Number((BigInt(sorted[index - 1]) + BigInt(sorted[index])) / 2n);
}
function decimalFraction(value) {
  const [coefficient, exponentText = "0"] = String(value).toLowerCase().split("e");
  const [whole, fractional = ""] = coefficient.split(".");
  let numerator = BigInt(whole + fractional), denominator = 10n ** BigInt(fractional.length);
  const exponent = Number(exponentText);
  if (exponent > 0) numerator *= 10n ** BigInt(exponent);
  else if (exponent < 0) denominator *= 10n ** BigInt(-exponent);
  return [numerator, denominator];
}
function afterPercent(copper, percent) {
  const [numerator, denominator] = decimalFraction(percent);
  return Number(BigInt(copper) * (100n * denominator - numerator) / (100n * denominator));
}
function percentageFloor(copper, percent) {
  const [numerator, denominator] = decimalFraction(percent);
  return Number(BigInt(copper) * numerator / (100n * denominator));
}
function maxPurchase(copper, minimumRoi) {
  const [numerator, denominator] = decimalFraction(minimumRoi);
  return Number(BigInt(copper) * 100n * denominator / (100n * denominator + numerator));
}
function breakEven(copper, feePercent) {
  const [numerator, denominator] = decimalFraction(feePercent);
  const dividend = BigInt(copper) * 100n * denominator, divisor = 100n * denominator - numerator;
  return safeMoney((dividend + divisor - 1n) / divisor);
}
function reachesRoi(profit, purchase, minimumRoi) {
  const [numerator, denominator] = decimalFraction(minimumRoi);
  return BigInt(profit) * 100n * denominator >= BigInt(purchase) * numerator;
}
function normalizeHistoryRow(realm, row, nowMs) {
  object(row, "Fila histórica");
  const itemId = integer(row.itemId, "ID histórico", 1, Number.MAX_SAFE_INTEGER), key = itemKey(row.itemKey, itemId);
  const observed = instant(row.observedAt);
  if (observed > nowMs + FUTURE_TOLERANCE || new Date(observed).getUTCFullYear() < 2026) throw new Error("El histórico contiene fechas futuras o anteriores a Forever.");
  return {realm, itemKey: key, itemId, observedAt: stamp(observed), priceCopper: integer(row.priceCopper, "Precio histórico", 1), quantityObserved: integer(row.quantityObserved, "Cantidad histórica", 0, 1e10)};
}
export function addHistory(state, realm, rows, nowMs = Date.now()) {
  nowValue(nowMs);
  if (typeof realm !== "string" || !realm.trim() || realm.length > 160 || !Array.isArray(rows) || rows.length > 500000) throw new Error("Histórico no válido.");
  realm = realm.trim();
  const clean = rows.map(row => normalizeHistoryRow(realm, row, nowMs));
  const keyOf = row => JSON.stringify([row.realm, row.itemKey, row.observedAt]);
  const merged = new Map(state.history.map(row => [keyOf(row), row]));
  for (const row of clean) merged.set(keyOf(row), row);
  if (merged.size > 500000) throw new Error("El histórico supera 500.000 observaciones. Exporta una copia para conservar los datos antes de continuar.");
  state.history = [...merged.values()].sort((a, b) => instant(a.observedAt) - instant(b.observedAt));
  state.sourceMeta ??= {};
  state.sourceMeta.historyRealm = realm;
  return clean.length;
}
export function historyState(state, realm = null, nowMs = Date.now()) {
  nowValue(nowMs);
  const rows = state.history.filter(row => !realm || row.realm === realm);
  const groups = new Map(), realms = new Set();
  for (const row of rows) {
    const key = JSON.stringify([row.realm, row.itemKey]);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row); realms.add(row.realm);
  }
  const items = [...groups.values()].map(points => {
    points.sort((a, b) => instant(a.observedAt) - instant(b.observedAt));
    const last = points.at(-1), daily = new Map();
    for (const point of points) {
      const age = nowMs - instant(point.observedAt);
      if (age >= 0 && age <= 7 * DAY) {
        const date = point.observedAt.slice(0, 10);
        daily.set(date, Math.min(daily.get(date) ?? Infinity, point.priceCopper));
      }
    }
    return {realm: last.realm, itemKey: last.itemKey, itemId: last.itemId, name: `Objeto ${last.itemId}`, lastObservedAt: last.observedAt,
      minCopper: points.reduce((min, point) => Math.min(min, point.priceCopper), Infinity), maxCopper: points.reduce((max, point) => Math.max(max, point.priceCopper), 0),
      referenceCopper: median([...daily.values()]), samples: points.length, days: daily.size, quantityObserved: last.quantityObserved};
  }).sort((a, b) => instant(b.lastObservedAt) - instant(a.lastObservedAt));
  return {count: rows.length, realms: [...realms].sort(), items};
}
function tradingMetrics(transactions, summary, nowMs) {
  const queues = new Map();
  let heldHours = 0, soldUnits = 0, soldCost = 0n, saleProfit = 0n, expenses = 0n, closedSales = 0;
  for (const tx of transactions) {
    const key = tx.itemKey ?? String(tx.itemId);
    if (!queues.has(key)) queues.set(key, {lots: [], head: 0});
    const queue = queues.get(key);
    if (tx.kind === "buy") queue.lots.push({quantity: tx.quantity, when: instant(tx.createdAt)});
    else if (tx.kind === "sell") {
      let remaining = tx.quantity;
      while (remaining) {
        if (!queue.lots[queue.head]) throw new Error("Inventario de métricas incoherente.");
        const lot = queue.lots[queue.head], used = Math.min(lot.quantity, remaining);
        heldHours += Math.max(0, (instant(tx.createdAt) - lot.when) / 3600000) * used;
        soldUnits += used; lot.quantity -= used; remaining -= used;
        if (!lot.quantity) queue.head++;
      }
      const receipt = grossAmount(tx) - BigInt(tx.feeCopper) - BigInt(tx.depositLossCopper);
      soldCost += receipt - BigInt(tx.realizedProfitCopper); saleProfit += BigInt(tx.realizedProfitCopper); closedSales++;
    } else expenses -= BigInt(tx.realizedProfitCopper);
  }
  let oldest = null;
  for (const queue of queues.values()) for (const lot of queue.lots) if (lot.quantity) oldest = Math.max(oldest ?? 0, Math.max(0, (nowMs - lot.when) / 3600000));
  const equity = summary.availableCapitalCopper + summary.inventoryCostCopper;
  const rounded = value => Math.round(value * 100) / 100;
  return {cashSharePercent: equity > 0 ? rounded(summary.availableCapitalCopper / equity * 100) : null,
    realizedRoiPercent: soldCost > 0n ? rounded(Number(saleProfit - expenses) / Number(soldCost) * 100) : null,
    averageHoldHours: soldUnits ? rounded(heldHours / soldUnits) : null, oldestInventoryHours: oldest == null ? null : rounded(oldest),
    soldCostCopper: safeMoney(soldCost), expensesCopper: safeMoney(expenses), closedSales};
}
export function computeState(state, nowMs = Date.now()) {
  nowValue(nowMs);
  const settings = validateSettings(state.settings), transactions = state.transactions;
  const inventory = inventoryOf(positions(transactions)), summary = summaryOf(transactions, inventory, settings);
  const stock = new Map(inventory.map(item => [item.itemKey, item]));
  const snapshot = latestSnapshot(state), status = {...state.status, observedAt: null}, items = [];
  const allRealms = [...new Set(state.history.map(row => row.realm))];
  const activeRealm = snapshot?.realm || state.sourceMeta?.activeRealm || state.sourceMeta?.historyRealm || (allRealms.length === 1 ? allRealms[0] : null);
  const history = historyState(state, activeRealm, nowMs);
  const references = activeRealm ? new Map(history.items.map(row => [row.itemKey, row])) : new Map();
  const ownSales = new Map();
  for (const tx of transactions) if (tx.kind === "sell" && nowMs - instant(tx.createdAt) >= 0 && nowMs - instant(tx.createdAt) <= 7 * DAY) {
    const key = tx.itemKey ?? String(tx.itemId);
    if (!ownSales.has(key)) ownSales.set(key, []);
    ownSales.get(key).push(tx.unitCopper);
  }
  if (snapshot) {
    const age = (nowMs - instant(snapshot.observedAt)) / 3600000;
    const fresh = age >= -FUTURE_TOLERANCE / 3600000 && age <= settings.maxDataAgeHours;
    Object.assign(status, {observedAt: snapshot.observedAt, coverage: snapshot.coverage ?? "unspecified", realm: snapshot.realm ?? null, source: snapshot.source,
      state: snapshot.items.length ? (fresh ? "ready" : "stale") : "empty"});
    if (!fresh) status.message = "Precios antiguos: actualiza el escaneo para habilitar recomendaciones.";
    for (const observed of snapshot.items) {
      const key = observed.itemKey ?? String(observed.itemId), observedAt = observed.observedAt ?? snapshot.observedAt;
      const itemAge = (nowMs - instant(observedAt)) / 3600000;
      const freshItem = itemAge >= -FUTURE_TOLERANCE / 3600000 && itemAge <= settings.maxDataAgeHours;
      const referenceData = references.get(key) ?? {};
      let reference = observed.referenceCopper;
      if (reference == null && referenceData.days >= 4) reference = referenceData.referenceCopper;
      if (reference && ownSales.get(key)?.length) reference = Math.min(reference, median(ownSales.get(key)));
      const target = reference ? afterPercent(reference, settings.resaleDiscountPercent) : 0;
      const netSale = afterPercent(target, settings.feePercent), margin = netSale - observed.buyCopper;
      const roi = margin / observed.buyCopper * 100;
      const cap = Math.max(0, percentageFloor(settings.capitalCopper, settings.maxItemPercent) - (stock.get(key)?.totalCostCopper ?? 0));
      const units = Math.min(1, settings.maxUnits, observed.quantityAvailable, Math.floor(Math.max(0, summary.availableCapitalCopper) / observed.buyCopper), Math.floor(cap / observed.buyCopper));
      const reachesThreshold = reachesRoi(margin, observed.buyCopper, settings.minMarginPercent);
      const eligible = Boolean(fresh && freshItem && reference && reachesThreshold && margin > 0 && units > 0);
      let reason = "Prueba de una unidad; verifica oferta y reventa en el juego. No hay ventas confirmadas.";
      if (!fresh || !freshItem) reason = "El escaneo es antiguo.";
      else if (!reference) reason = "Falta una referencia histórica; la oferta actual no demuestra valor de reventa.";
      else if (margin <= 0 || !reachesThreshold) reason = "ROI estimado insuficiente tras comisión y descuento de reventa.";
      else if (units <= 0) reason = "Sin capital disponible, sin oferta o límite de inversión alcanzado.";
      items.push({...observed, itemKey: key, referenceCopper: reference ?? null, targetCopper: target, netUnitCopper: margin, roiPercent: Math.round(roi * 100) / 100,
        maximumBuyCopper: maxPurchase(netSale, settings.minMarginPercent), breakEvenCopper: breakEven(observed.buyCopper, settings.feePercent),
        recommendedUnits: eligible ? units : 0, estimatedProfitCopper: eligible ? margin * units : 0, reason, eligible, confidence: "Baja", observedAt,
        referenceDays: referenceData.days ?? 0});
    }
  }
  items.sort((a, b) => Number(b.eligible) - Number(a.eligible) || b.estimatedProfitCopper - a.estimatedProfitCopper);
  return {market: MARKET, settings, status, items, inventory, transactions: [...transactions].reverse(), summary, trading: tradingMetrics(transactions, summary, nowMs)};
}
export function exportBackup(state, nowMs = Date.now()) {
  return structuredClone({format: "forever-mercado-backup", version: 1, market: MARKET, exportedAt: stamp(nowMs), settings: state.settings,
    transactions: state.transactions, snapshots: state.snapshots, auctioneerHistory: state.history});
}
export function restoreBackup(backup, nowMs = Date.now()) {
  nowValue(nowMs); object(backup, "Copia de seguridad");
  if (backup.format !== "forever-mercado-backup" || backup.version !== 1 || backup.market !== MARKET) throw new Error("Copia de seguridad incompatible.");
  if (!Array.isArray(backup.snapshots) || backup.snapshots.length > 10000 || !Array.isArray(backup.transactions) || backup.transactions.length > 100000 || !Array.isArray(backup.auctioneerHistory ?? []) || (backup.auctioneerHistory?.length ?? 0) > 500000) throw new Error("Copia de seguridad no válida.");
  const restored = emptyState();
  restored.settings = validateSettings(DEFAULTS, backup.settings ?? {});
  for (const snapshot of backup.snapshots) importSnapshot(restored, snapshot, nowMs);
  const restoredPositions = new Map();
  for (const original of backup.transactions) {
    object(original, "Movimiento de copia");
    const when = instant(original.createdAt);
    if (when > nowMs + FUTURE_TOLERANCE) throw new Error("La copia contiene movimientos futuros.");
    addTransactionCore(restored, original, when, restoredPositions);
  }
  summaryOf(restored.transactions, inventoryOf(restoredPositions), restored.settings);
  const byRealm = new Map();
  for (const row of backup.auctioneerHistory ?? []) {
    object(row, "Fila histórica de copia");
    if (!byRealm.has(row.realm)) byRealm.set(row.realm, []);
    byRealm.get(row.realm).push(row);
  }
  for (const [realm, rows] of byRealm) addHistory(restored, realm, rows, nowMs);
  restored.status = {state: "empty", message: "Copia restaurada y movimientos recalculados.", source: "Archivo importado", checkedAt: stamp(nowMs)};
  restored.sourceMeta = {};
  return restored;
}

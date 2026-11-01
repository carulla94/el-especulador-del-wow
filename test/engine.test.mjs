import test from "node:test";
import assert from "node:assert/strict";
import {MARKET, DEFAULTS, emptyState, validateSettings, instant, itemKey, normalizeSnapshot, importSnapshot,
  addTransaction, computeState, addHistory, historyState, exportBackup, restoreBackup, latestSnapshotRealm} from "../src/engine.mjs";

const NOW = Date.parse("2026-11-01T18:30:00Z"), DAY = 86400000, HOUR = 3600000;
const iso = time => new Date(time).toISOString();
const stateWithCapital = () => { const state = emptyState(); state.settings = validateSettings(state.settings, {capitalCopper: 1e6}); return state; };
function trade(state, kind, quantity = 1, unitCopper = 10000, options = {}, when = NOW) {
  return addTransaction(state, {kind, itemId: 2589, name: "Paño", quantity, unitCopper, ...options}, when);
}
function snapshot(options = {}) {
  return {market: MARKET, realm: "PvP EU", observedAt: iso(NOW), source: "Prueba", coverage: "partial", items: [
    {itemId: 2589, name: "Paño", buyCopper: 10000, referenceCopper: 20000, quantityAvailable: 20}], ...options};
}
function historyRow(day = 0, priceCopper = 20000, options = {}) {
  return {itemId: 2589, itemKey: "2589", observedAt: iso(NOW - day * DAY - HOUR), priceCopper, quantityObserved: 50, ...options};
}

test("defaults start empty, zero capital and no invented market signals", () => {
  const state = emptyState(), computed = computeState(state, NOW);
  assert.equal(computed.summary.availableCapitalCopper, 0);
  assert.equal(computed.status.state, "empty");
  assert.deepEqual(computed.items, []);
  assert.equal(computed.trading.realizedRoiPercent, null);
});

test("settings validate partial changes without losing old values", () => {
  const first = validateSettings(DEFAULTS, {capitalCopper: 12000});
  assert.equal(validateSettings(first, {minMarginPercent: 30}).capitalCopper, 12000);
  for (const changes of [{feePercent: Infinity}, {capitalCopper: true}, {maxUnits: 1.5}, {maxItemPercent: -1}, {unknown: 1}, {maxDataAgeHours: 0}]) assert.throws(() => validateSettings(first, changes));
});

test("ISO timestamps require timezone, valid calendar and normalize offsets", () => {
  assert.equal(instant("2026-11-01T19:30:00+01:00"), NOW);
  for (const invalid of [null, "2026-11-01T18:30:00", "2026-02-30T12:00:00Z", "2026-11-01T24:00:00Z", "2026-11-01", "2026-11-01T18:30:00+25:00"]) assert.throws(() => instant(invalid));
});

test("variant identity retains levels, signed suffixes and pet species", () => {
  for (const key of ["2589", "2589:12", "2589::-5", "2589:12:-5"]) assert.equal(itemKey(key, 2589), key);
  assert.equal(itemKey(":::39", 82800), ":::39");
  for (const [key, id] of [["2592",2589], ["2589:1:foo",2589], [":::0",82800], [":::39",2589], ["2589:1:2:3:4",2589]]) assert.throws(() => itemKey(key, id));
});

test("partial sale realizes only sold FIFO costs, leaving the rest at cost", () => {
  const state = stateWithCapital();
  trade(state, "buy", 10, 100, {}, NOW - DAY);
  const sale = trade(state, "sell", 4, 200, {feeCopper: 40});
  assert.equal(sale.realizedProfitCopper, 360);
  const computed = computeState(state, NOW);
  assert.equal(computed.inventory[0].quantity, 6);
  assert.equal(computed.inventory[0].totalCostCopper, 600);
  assert.equal(computed.summary.availableCapitalCopper, 999760);
  assert.equal(computed.summary.realizedProfitCopper, 360);
});

test("FIFO crosses purchase lots in insertion order", () => {
  const state = stateWithCapital();
  trade(state, "buy", 2, 100);
  trade(state, "buy", 2, 500);
  assert.equal(trade(state, "sell", 3, 600).realizedProfitCopper, 1100);
  assert.equal(computeState(state, NOW).inventory[0].totalCostCopper, 500);
});

test("fee allocation preserves every copper after partial sales", () => {
  const state = stateWithCapital();
  trade(state, "buy", 3, 100, {feeCopper: 2});
  const a = trade(state, "sell", 1, 150), b = trade(state, "sell", 1, 150), c = trade(state, "sell", 1, 150);
  assert.equal(a.realizedProfitCopper + b.realizedProfitCopper + c.realizedProfitCopper, 148);
  assert.deepEqual(computeState(state, NOW).inventory, []);
});

test("BigInt allocation stays exact when intermediate cost times units exceeds Number precision", () => {
  const state = stateWithCapital();
  const qty = 100000000, unit = 1234567, fee = 7;
  trade(state, "buy", qty, unit, {feeCopper: fee});
  const sold = qty - 1, sale = trade(state, "sell", sold, unit + 1);
  const expectedCost = (BigInt(qty) * BigInt(unit) + 7n) * BigInt(sold) / BigInt(qty);
  assert.equal(sale.realizedProfitCopper, Number(BigInt(sold) * BigInt(unit + 1) - expectedCost));
  assert.equal(computeState(state, NOW).inventory[0].totalCostCopper, Number(BigInt(qty) * BigInt(unit) + 7n - expectedCost));
});

test("oversale cannot mutate the saved ledger", () => {
  const state = stateWithCapital();
  trade(state, "buy", 2, 100);
  const before = structuredClone(state);
  assert.throws(() => trade(state, "sell", 3, 200));
  assert.deepEqual(state, before);
});

test("negative or non-integer quantities and oversized products fail atomically", () => {
  const state = stateWithCapital();
  for (const quantity of [0, -1, true, 1.5, "2"]) assert.throws(() => trade(state, "buy", quantity));
  assert.throws(() => trade(state, "buy", 1e10, 1e15));
  assert.equal(state.transactions.length, 0);
});

test("different variants never share inventory or purchase costs", () => {
  const state = stateWithCapital();
  trade(state, "buy", 1, 100, {itemKey: "2589::1"});
  trade(state, "buy", 1, 900, {itemKey: "2589::-2"});
  assert.throws(() => trade(state, "sell", 1, 200, {itemKey: "2589"}));
  assert.equal(trade(state, "sell", 1, 200, {itemKey: "2589::1"}).realizedProfitCopper, 100);
  assert.equal(computeState(state, NOW).inventory[0].itemKey, "2589::-2");
});

test("expenses reduce cash and realized profit without removing stock", () => {
  const state = stateWithCapital();
  trade(state, "buy", 2, 100);
  addTransaction(state, {kind: "expense", itemId: 0, unitCopper: 50, quantity: 1}, NOW);
  const result = computeState(state, NOW);
  assert.equal(result.summary.availableCapitalCopper, 999750);
  assert.equal(result.summary.realizedProfitCopper, -50);
  assert.equal(result.inventory[0].quantity, 2);
});

test("sale costs cannot exceed the receipt", () => {
  const state = stateWithCapital(); trade(state, "buy", 1, 100);
  assert.throws(() => trade(state, "sell", 1, 200, {feeCopper: 201}));
  assert.equal(state.transactions.length, 1);
});

test("invalid last snapshot row prevents every row being imported", () => {
  const state = emptyState(), before = structuredClone(state);
  const data = snapshot(); data.items.push({itemId: 2592, name: "Otro", buyCopper: "1", quantityAvailable: 1});
  assert.throws(() => importSnapshot(state, data, NOW)); assert.deepEqual(state, before);
});

test("wrong market, future date and duplicate variants are rejected", () => {
  const data = snapshot();
  assert.throws(() => normalizeSnapshot({...data, market: "forever.pvp.horde.eu"}, NOW));
  assert.throws(() => normalizeSnapshot({...data, observedAt: iso(NOW + HOUR)}, NOW));
  assert.throws(() => normalizeSnapshot({...data, items: [data.items[0], data.items[0]]}, NOW));
  assert.equal(normalizeSnapshot({...data, items: [data.items[0], {...data.items[0], itemKey: "2589:12"}]}, NOW).items.length, 2);
});

test("stale and zero-capital observations never recommend a purchase", () => {
  const zero = emptyState(); importSnapshot(zero, snapshot(), NOW);
  assert.equal(computeState(zero, NOW).items[0].recommendedUnits, 0);
  const state = stateWithCapital(); importSnapshot(state, snapshot({observedAt: iso(NOW - DAY)}), NOW);
  assert.equal(computeState(state, NOW).status.state, "stale");
  assert.equal(computeState(state, NOW).items[0].eligible, false);
});

test("a stale row remains stale in a fresh partial capture", () => {
  const state = stateWithCapital(), data = snapshot();
  data.items[0].observedAt = iso(NOW - DAY);
  importSnapshot(state, data, NOW);
  const result = computeState(state, NOW);
  assert.equal(result.status.state, "ready"); assert.equal(result.status.coverage, "partial");
  assert.equal(result.items[0].eligible, false);
});

test("latest scan wins by observation time regardless of import order", () => {
  const state = stateWithCapital();
  const newer = snapshot({observedAt: iso(NOW + 500)}); newer.items[0].buyCopper = 12000;
  importSnapshot(state, newer, NOW);
  importSnapshot(state, snapshot(), NOW);
  assert.equal(computeState(state, NOW).items[0].buyCopper, 12000);
});

test("a newer empty scan never resurrects older offers", () => {
  const state = stateWithCapital(); importSnapshot(state, snapshot(), NOW);
  importSnapshot(state, snapshot({observedAt: iso(NOW + 1000), items: []}), NOW);
  assert.deepEqual(computeState(state, NOW).items, []);
});

test("ROI deducts prudence and commission and proposes only one trial unit", () => {
  const state = stateWithCapital(); importSnapshot(state, snapshot(), NOW);
  const item = computeState(state, NOW).items[0];
  assert.equal(item.targetCopper, 18000); assert.equal(item.netUnitCopper, 7100);
  assert.equal(item.roiPercent, 71); assert.equal(item.maximumBuyCopper, 14250);
  assert.equal(item.breakEvenCopper, 10527); assert.equal(item.recommendedUnits, 1);
  assert.equal(item.confidence, "Baja");
});

test("inventory consumes the item capital ceiling", () => {
  const state = stateWithCapital(); state.settings.maxItemPercent = 1;
  trade(state, "buy", 1, 10000); importSnapshot(state, snapshot(), NOW);
  assert.equal(computeState(state, NOW).items[0].eligible, false);
});

test("insufficient historical margin and missing reference do not recommend", () => {
  const state = stateWithCapital(), data = snapshot(); data.items[0].referenceCopper = 10000;
  importSnapshot(state, data, NOW); assert.equal(computeState(state, NOW).items[0].eligible, false);
  data.items[0].referenceCopper = null; importSnapshot(state, data, NOW);
  assert.equal(computeState(state, NOW).items[0].referenceCopper, null);
});

test("history imports remain history and deduplicate canonical timestamps", () => {
  const state = stateWithCapital();
  const row = historyRow(); addHistory(state, "PvP EU", [row], NOW);
  addHistory(state, "PvP EU", [{...row, observedAt: iso(NOW - HOUR).replace("17:30", "18:30").replace("Z", "+01:00")}], NOW);
  assert.equal(state.history.length, 1);
  assert.deepEqual(computeState(state, NOW).items, []);
});

test("one invalid history row prevents partial history writes", () => {
  const state = emptyState();
  assert.throws(() => addHistory(state, "PvP EU", [historyRow(), historyRow(1, -1)], NOW));
  assert.deepEqual(state.history, []);
});

test("reference uses median daily lows, not the most frequently scanned hour", () => {
  const state = stateWithCapital();
  const rows = [historyRow(0, 100), historyRow(1, 200), historyRow(2, 300), historyRow(3, 400)];
  for (let hour = 2; hour < 10; hour++) rows.push(historyRow(0, 90, {observedAt: iso(NOW - hour * HOUR)}));
  addHistory(state, "PvP EU", rows, NOW);
  const result = historyState(state, "PvP EU", NOW).items[0];
  assert.equal(result.days, 4); assert.equal(result.referenceCopper, 250);
});

test("four distinct recent days can support a fresh bridge observation", () => {
  const state = stateWithCapital();
  addHistory(state, "PvP EU", [0,1,2].map(day => historyRow(day)), NOW);
  const data = snapshot(); data.items[0].referenceCopper = null; importSnapshot(state, data, NOW);
  assert.equal(computeState(state, NOW).items[0].eligible, false);
  addHistory(state, "PvP EU", [historyRow(3)], NOW);
  assert.equal(computeState(state, NOW).items[0].eligible, true);
});

test("history outside seven days is archived but cannot be a current reference", () => {
  const state = stateWithCapital(); addHistory(state, "PvP EU", [8,9,10,11].map(day => historyRow(day)), NOW);
  const data = snapshot(); data.items[0].referenceCopper = null; importSnapshot(state, data, NOW);
  assert.equal(historyState(state, "PvP EU", NOW).count, 4);
  assert.equal(historyState(state, "PvP EU", NOW).items[0].days, 0);
  assert.equal(computeState(state, NOW).items[0].eligible, false);
});

test("different realms cannot manufacture coverage or prices for the active snapshot", () => {
  const state = stateWithCapital();
  addHistory(state, "PvP EU", [historyRow(0, 20000)], NOW);
  addHistory(state, "Other realm", [1,2,3].map(day => historyRow(day, 900000)), NOW);
  const data = snapshot(); data.items[0].referenceCopper = null; importSnapshot(state, data, NOW);
  assert.equal(historyState(state, null, NOW).items.length, 2);
  assert.equal(computeState(state, NOW).items[0].referenceDays, 1);
  assert.equal(computeState(state, NOW).items[0].eligible, false);
});

test("own confirmed sales cap an inflated historical reference", () => {
  const state = stateWithCapital();
  trade(state, "buy", 1, 1000, {}, NOW - DAY); trade(state, "sell", 1, 12000);
  importSnapshot(state, snapshot(), NOW);
  assert.equal(computeState(state, NOW).items[0].referenceCopper, 12000);
});

test("observed trading metrics reflect FIFO time, closed-sale costs and expenses", () => {
  const state = stateWithCapital();
  trade(state, "buy", 2, 100, {}, NOW - 2 * DAY); trade(state, "sell", 1, 200, {feeCopper: 10}, NOW - DAY);
  addTransaction(state, {kind: "expense", unitCopper: 10}, NOW);
  const result = computeState(state, NOW);
  assert.equal(result.trading.averageHoldHours, 24);
  assert.equal(result.trading.oldestInventoryHours, 48);
  assert.equal(result.trading.realizedRoiPercent, 80);
  assert.equal(result.trading.soldCostCopper, 100);
  assert.equal(result.trading.closedSales, 1);
  assert.equal(result.summary.realizedProfitCopper, 80);
});

test("backup export is a deep copy compatible with the Python format", () => {
  const state = stateWithCapital(); trade(state, "buy");
  const backup = exportBackup(state, NOW);
  assert.equal(backup.format, "forever-mercado-backup"); assert.equal(backup.version, 1);
  backup.transactions[0].unitCopper = 1;
  assert.equal(state.transactions[0].unitCopper, 10000);
});

test("backup restore recalculates profits and retains history, variants and snapshot realm", () => {
  const state = stateWithCapital();
  trade(state, "buy", 2, 100, {itemKey: "2589::-2"}, NOW - DAY);
  trade(state, "sell", 1, 200, {itemKey: "2589::-2", feeCopper: 10});
  addHistory(state, "PvP EU", [historyRow()], NOW); importSnapshot(state, snapshot(), NOW);
  const backup = exportBackup(state, NOW); backup.transactions[1].realizedProfitCopper = 99999999;
  const restored = restoreBackup(backup, NOW), result = computeState(restored, NOW);
  assert.equal(result.summary.realizedProfitCopper, 90);
  assert.equal(result.inventory[0].itemKey, "2589::-2");
  assert.equal(restored.history.length, 1); assert.equal(latestSnapshotRealm(restored), "PvP EU");
  assert.deepEqual(restored.sourceMeta, {});
});

test("old Python backups without item keys or history remain importable", () => {
  const state = stateWithCapital(); trade(state, "buy", 1, 100);
  const backup = exportBackup(state, NOW); delete backup.auctioneerHistory; delete backup.transactions[0].itemKey;
  backup.transactions[0].createdAt = "2026-11-01T19:30:00+01:00";
  assert.equal(restoreBackup(backup, NOW).transactions[0].itemKey, "2589");
});

test("invalid backup and over-selling cannot alter the original state", () => {
  const state = stateWithCapital(); trade(state, "buy", 1, 100);
  const before = structuredClone(state), backup = exportBackup(state, NOW);
  backup.transactions.push({...backup.transactions[0], kind: "sell", quantity: 2});
  assert.throws(() => restoreBackup(backup, NOW)); assert.deepEqual(state, before);
  for (const bad of [{...backup, market: "other"}, {...backup, version: 2}, {...backup, auctioneerHistory: [null]}]) assert.throws(() => restoreBackup(bad, NOW));
});

test("cloud snapshots retain one latest capture and ignore older incoming data", () => {
  const state = stateWithCapital();
  importSnapshot(state, snapshot(), NOW);
  const second = snapshot({observedAt: iso(NOW + 1000)}); second.items[0].buyCopper = 9000;
  importSnapshot(state, second, NOW);
  assert.equal(state.snapshots.length, 1);
  const unchanged = importSnapshot(state, second, NOW);
  assert.equal(unchanged.unchanged, true);
  const ignored = importSnapshot(state, snapshot(), NOW);
  assert.equal(ignored.ignored, true);
  assert.equal(state.snapshots.length, 1);
  assert.equal(computeState(state, NOW).items[0].buyCopper, 9000);
});

test("restoring old many-snapshot backups keeps latest observations and independent history", () => {
  const state = stateWithCapital(), old = snapshot({observedAt: iso(NOW - DAY)});
  const newest = snapshot(); newest.items[0].buyCopper = 9000;
  const backup = exportBackup(state, NOW); backup.snapshots = [old, newest, old];
  backup.auctioneerHistory = [historyRow(1)].map(row => ({realm: "PvP EU", ...row}));
  const restored = restoreBackup(backup, NOW);
  assert.equal(restored.snapshots.length, 1);
  assert.equal(restored.history.length, 1);
  assert.equal(computeState(restored, NOW).items[0].buyCopper, 9000);
});

test("percentage floors use exact decimal arithmetic instead of losing a copper to binary floats", () => {
  const state = stateWithCapital();
  state.settings.feePercent = 34; state.settings.resaleDiscountPercent = 0;
  const data = snapshot(); data.items[0].referenceCopper = 100; data.items[0].buyCopper = 50;
  importSnapshot(state, data, NOW);
  const item = computeState(state, NOW).items[0];
  assert.equal(item.targetCopper, 100);
  assert.equal(item.netUnitCopper, 16);
  assert.equal(item.maximumBuyCopper, 55);
  assert.equal(item.breakEvenCopper, 76);
});

test("fractional percentage inputs remain exact for large copper amounts", () => {
  const state = stateWithCapital();
  state.settings.feePercent = .1; state.settings.resaleDiscountPercent = .1;
  const data = snapshot(); data.items[0].referenceCopper = 1e15; data.items[0].buyCopper = 100;
  importSnapshot(state, data, NOW);
  assert.equal(computeState(state, NOW).items[0].targetCopper, 999000000000000);
  assert.equal(computeState(state, NOW).items[0].netUnitCopper, 998000999999900);
});

test("restoring many FIFO lots remains a linear bulk operation with exact closing profit", () => {
  const total = 10000, backup = exportBackup(emptyState(), NOW);
  for (let i = 0; i < total; i++) backup.transactions.push({kind: "buy", itemId: 2589, name: "Paño", quantity: 1, unitCopper: 100, createdAt: iso(NOW - DAY)});
  for (let i = 0; i < total; i++) backup.transactions.push({kind: "sell", itemId: 2589, name: "Paño", quantity: 1, unitCopper: 200, feeCopper: 10, createdAt: iso(NOW)});
  const restored = restoreBackup(backup, NOW), result = computeState(restored, NOW);
  assert.equal(restored.transactions.length, 2 * total);
  assert.equal(result.summary.realizedProfitCopper, 90 * total);
  assert.deepEqual(result.inventory, []);
  assert.equal(result.trading.averageHoldHours, 24);
});

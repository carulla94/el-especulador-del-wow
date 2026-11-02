import test from "node:test";
import assert from "node:assert/strict";
import {createLocalApi} from "../pages/local-api.mjs";
import {emptyState, MARKET} from "../src/engine.mjs";

const NOW = Date.parse("2026-11-03T12:30:00Z");
const REALM = "Reino PvP EU";
const clone = value => structuredClone(value);

/** An isolated transactional storage adapter, including a failed-commit path. */
class MemoryRepository {
  #record = {state: emptyState(), previousBackup: null};
  #tail = Promise.resolve();
  failNextCommit = false;
  commits = 0;
  async read() { await this.#tail; return clone(this.#record); }
  update(mutator) {
    const operation = this.#tail.then(async () => {
      const draft = clone(this.#record);
      const result = mutator(draft);
      assert.ok(!(result instanceof Promise), "storage mutations must stay synchronous");
      await Promise.resolve();
      if (this.failNextCommit) {
        this.failNextCommit = false;
        throw Object.assign(new Error("No queda espacio para guardar los datos locales."), {status: 507});
      }
      this.#record = clone(draft);
      this.commits++;
      return clone(result);
    });
    this.#tail = operation.catch(() => {});
    return operation;
  }
}

function fixture(repository = new MemoryRepository()) {
  return {repository, api: createLocalApi({repository, now: () => NOW})};
}

function snapshot(changes = {}) {
  return {market: MARKET, realm: REALM, source: "Archivo de prueba", coverage: "partial",
    observedAt: new Date(NOW).toISOString(), items: [
      {itemId: 2589, itemKey: "2589", name: "Paño de lino", buyCopper: 100, referenceCopper: 200, quantityAvailable: 10}
    ], ...changes};
}
function buy(changes = {}) {
  return {kind: "buy", itemId: 2589, itemKey: "2589", name: "Paño de lino", quantity: 3,
    unitCopper: 100, feeCopper: 10, depositLossCopper: 0, note: "", ...changes};
}
function literal(value) {
  if (value === null) return "nil";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return "{" + Object.entries(value).map(([key, row]) => `[${literal(key)}]=${literal(row)}`).join(",") + "}";
}
function historyText() {
  const hour = Math.floor(NOW / 3600000);
  return `AuctioneerStatsOverTimeData={[${JSON.stringify(REALM)}]={[${hour}]={price={["2589"]=200},count={["2589"]=10}}}}`;
}
function bridgeData(changes = {}) {
  const captured = NOW / 1000;
  return {schemaVersion: 1, source: "Auctioneer12.x", market: MARKET, enabled: true, confirmedMarket: true,
    capturedAt: captured, savedAt: captured, lastBatchScope: "partial", complete: false,
    metadata: {region: "EU", faction: "Alliance", ruleset: "pvp", rulesetVerification: "user-confirmed", interface: 16001, realm: REALM},
    items: {"2589": {itemId: 2589, name: "Paño de lino", buyCopper: 100, quantityObserved: 10, observedAt: captured}}, ...changes};
}
const bridgeText = (data = bridgeData()) => "EspeculadorBridgeDB=" + literal(data);

test("Pages opens an independent local account without a cloud token or devices", async () => {
  const {api} = fixture();
  const state = await api.request("/api/state");
  assert.equal(state.market, MARKET);
  assert.equal(state.localMode, true);
  assert.equal(state.token, "");
  assert.deepEqual(state.transactions, []);
  assert.deepEqual(state.auctioneer.devices, []);
  assert.equal(state.auctioneer.connection.configured, false);
  assert.equal(state.auctioneer.connection.enabled, false);
});

test("settings and FIFO ledger survive adapter recreation using the same repository", async () => {
  const {api, repository} = fixture();
  await api.request("/api/settings", {capitalCopper: 10000, minMarginPercent: 25});
  await api.request("/api/transactions", buy());
  await api.request("/api/transactions", buy({kind: "sell", quantity: 2, unitCopper: 250, feeCopper: 25}));
  const second = createLocalApi({repository, now: NOW});
  const state = await second.request("/api/state");
  assert.equal(state.settings.capitalCopper, 10000);
  assert.equal(state.settings.minMarginPercent, 25);
  assert.equal(state.transactions.length, 2);
  assert.equal(state.inventory[0].quantity, 1);
  assert.equal(state.inventory[0].totalCostCopper, 104);
  assert.equal(state.summary.realizedProfitCopper, 269);
  assert.equal(state.summary.availableCapitalCopper, 10165);
});

test("manual JSON and AHL1 imports preserve observations and exact copper prices", async () => {
  const {api} = fixture();
  await api.request("/api/import", snapshot({items: [
    {itemId: 2589, itemKey: "2589", name: "Lino", buyCopper: 100, referenceCopper: 200, quantityAvailable: 10},
    {itemId: 2589, itemKey: "2589:60:-12", name: "Lino variante", buyCopper: 140, referenceCopper: 300, quantityAvailable: 3}
  ]}));
  let state = await api.request("/api/state");
  assert.deepEqual(new Set(state.items.map(item => item.itemKey)), new Set(["2589", "2589:60:-12"]));
  assert.equal(state.status.coverage, "partial");
  const row = ["2589", "", "101", "4", "205", "240", "", "", ""].join(":");
  const ahlTable = `AHL1|${MARKET.replaceAll(".", "/")}|${NOW / 1000}|1\n${row}`;
  await api.request("/api/import", {ahlTable});
  state = await api.request("/api/state");
  assert.equal(state.items.length, 1);
  assert.equal(state.items[0].buyCopper, 101);
  assert.equal(state.items[0].referenceCopper, 205);
  assert.equal(state.items[0].quantityAvailable, 4);
});

test("invalid imports, settings and sales leave the stored ledger unchanged", async () => {
  const {api, repository} = fixture();
  await api.request("/api/transactions", buy());
  const before = await repository.read();
  await assert.rejects(api.request("/api/transactions", buy({kind: "sell", quantity: 4, unitCopper: 200})), /venta supera/i);
  await assert.rejects(api.request("/api/settings", {feePercent: 99}), /fuera de rango/i);
  await assert.rejects(api.request("/api/import", snapshot({market: "retail.eu"})), /Europa/i);
  await assert.rejects(api.request("/api/import", {ahlTable: `AHL1|${MARKET.replaceAll(".", "/")}|${NOW / 1000}|2\n2589::100:4:200:220:::`}), /incompleta|válida/i);
  assert.deepEqual(await repository.read(), before);
});

test("historical realm discovery does not write and confirmed Lua imports remain historical", async () => {
  const {api, repository} = fixture();
  const text = historyText();
  const discovered = await api.request("/api/auctioneer/import", {text, realm: "", confirmedMarket: false});
  assert.equal(discovered.requiresRealm, true);
  assert.deepEqual(discovered.realms, [REALM]);
  assert.equal(repository.commits, 0);
  await assert.rejects(api.request("/api/auctioneer/import", {text, realm: REALM, confirmedMarket: false}), /confirma/i);
  const result = await api.request("/api/auctioneer/import", {text, realm: REALM, confirmedMarket: true});
  assert.equal(result.imported, 1);
  const state = await api.request("/api/state");
  assert.equal(state.auctioneer.history.count, 1);
  assert.equal(state.auctioneer.history.items[0].referenceCopper, 200);
  assert.equal(state.items.length, 0, "history is not fabricated as a current offer");
  assert.equal((await api.request("/api/history?realm=" + encodeURIComponent(REALM))).count, 1);
  assert.equal((await api.request("/api/history?realm=Otro%20reino")).count, 0);
});

test("manual bridge import records partial captures and rejects another market atomically", async () => {
  const {api, repository} = fixture();
  await api.request("/api/auctioneer/bridge", {text: bridgeText()});
  const state = await api.request("/api/state");
  assert.equal(state.status.state, "ready");
  assert.equal(state.status.coverage, "partial");
  assert.equal(state.items[0].name, "Paño de lino");
  assert.equal(state.items[0].quantityAvailable, 10);
  assert.equal(state.auctioneer.bridge.realm, REALM);
  const before = await repository.read();
  const other = bridgeData();
  other.metadata.region = "US";
  await assert.rejects(api.request("/api/auctioneer/bridge", {text: bridgeText(other)}));
  assert.deepEqual(await repository.read(), before);
});

test("portable backup restore preserves the previous account and rejects bad replacements", async () => {
  const {api, repository} = fixture();
  await assert.rejects(api.request("/api/backups/previous"), error => error.status === 404);
  await api.request("/api/settings", {capitalCopper: 50000});
  await api.request("/api/transactions", buy());
  await api.request("/api/import", snapshot());
  const backup = await api.request("/api/export");
  assert.equal(backup.format, "forever-mercado-backup");
  assert.equal(backup.version, 1);
  assert.equal(backup.market, MARKET);
  assert.ok(!JSON.stringify(backup).includes("token"));
  await api.request("/api/transactions", buy({quantity: 1, unitCopper: 300}));
  const beforeRestore = await api.request("/api/export");
  await api.request("/api/restore", backup);
  const state = await api.request("/api/state");
  assert.equal(state.transactions.length, 1);
  assert.equal(state.inventory[0].quantity, 3);
  assert.deepEqual(await api.request("/api/backups/previous"), beforeRestore);
  const restoredRecord = await repository.read();
  await assert.rejects(api.request("/api/restore", {...backup, market: "retail.eu"}), /incompatible/i);
  assert.deepEqual(await repository.read(), restoredRecord);
});

test("failed commits do not dirty state and a later mutation can still succeed", async () => {
  const {api, repository} = fixture();
  await api.request("/api/transactions", buy());
  const before = await repository.read();
  repository.failNextCommit = true;
  await assert.rejects(api.request("/api/settings", {capitalCopper: 10000}), error => error.status === 507);
  assert.deepEqual(await repository.read(), before);
  assert.equal((await api.request("/api/state")).settings.capitalCopper, 0);
  const replacement = await fixture().api.request("/api/export");
  repository.failNextCommit = true;
  await assert.rejects(api.request("/api/restore", replacement), error => error.status === 507);
  assert.deepEqual(await repository.read(), before, "a failed restore cannot replace state or create a previous backup");
  await api.request("/api/settings", {capitalCopper: 20000});
  assert.equal((await api.request("/api/state")).settings.capitalCopper, 20000);
});

test("concurrent writes serialize without losing movements or reusing IDs", async () => {
  const {api, repository} = fixture();
  await Promise.all(Array.from({length: 20}, (_, index) => api.request("/api/transactions", buy({quantity: 1, unitCopper: index + 1, feeCopper: 0}))));
  const state = await api.request("/api/state");
  assert.equal(state.transactions.length, 20);
  assert.equal(new Set(state.transactions.map(row => row.id)).size, 20);
  assert.equal(state.inventory[0].quantity, 20);
  assert.equal(state.inventory[0].totalCostCopper, 210);
  assert.equal(repository.commits, 20);
});

test("a state above the local limit is rejected before committing", async () => {
  const {api, repository} = fixture();
  const before = await repository.read();
  const data = snapshot({items: Array.from({length: 50000}, (_, index) => ({
    itemId: 2589, itemKey: `2589:123456789012345678:123456789012345678:${index}`,
    name: "x".repeat(160), buyCopper: 1000000000000000, referenceCopper: 1000000000000000,
    quantityAvailable: 10000000000
  }))});
  await assert.rejects(api.request("/api/import", data), error => error.status === 507);
  assert.deepEqual(await repository.read(), before);
});

test("cloud-only routes cannot create fake authentication or PC synchronization", async () => {
  const {api, repository} = fixture();
  for (const path of ["/api/login", "/api/logout", "/api/devices", "/api/devices/revoke", "/api/device/sync", "/api/sync", "/api/auctioneer/config", "/api/auctioneer/sync"]) {
    await assert.rejects(api.request(path, {}), error => error.status === 400 && /local|navegador|GitHub Pages|rutas de tu PC/i.test(error.message), path);
  }
  await assert.rejects(api.request("/api/not-a-real-route"), error => error.status === 404);
  assert.equal(repository.commits, 0);
});

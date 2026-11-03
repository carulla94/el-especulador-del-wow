/** Full Worker -> Durable Object -> real SQLite checks, without HTTP sockets. */
import test from "node:test";
import assert from "node:assert/strict";
import {DatabaseSync} from "node:sqlite";
import worker, {Portfolio, GuildMarket, issueSession} from "../src/worker.mjs";
import {MARKET} from "../src/engine.mjs";

const BASE = "https://especulador.test";
const PASSWORD = "test-only-owner-password-47-strong";
const REALM = "EU PvP Test";
const COOKIE_NAME = "__Host-especulador_session";

function sqliteContext() {
  const db = new DatabaseSync(":memory:");
  const sql = {exec(query, ...bindings) {
    const statement = db.prepare(query);
    const rows = statement.columns().length ? statement.all(...bindings) : (statement.run(...bindings), []);
    return {toArray: () => rows, [Symbol.iterator]: () => rows[Symbol.iterator]()};
  }};
  return {db, ctx: {storage: {sql, transactionSync(callback) {
    db.exec("BEGIN IMMEDIATE");
    try { const result = callback(); assert.ok(!(result instanceof Promise)); db.exec("COMMIT"); return result; }
    catch (error) { db.exec("ROLLBACK"); throw error; }
  }}}};
}

// guild: also bind the GuildMarket namespace (its own SQLite), as production will; false leaves GUILD unset.
function fixture(t, configured = true, {guild = true} = {}) {
  const {db, ctx} = sqliteContext();
  t.after(() => db.close());
  const assets = [];
  const env = {
    OWNER_PASSWORD: configured ? PASSWORD : undefined,
    SESSION_SECRET: "test-only-independent-session-secret-99",
    ASSETS: {async fetch(request) {
      const path = new URL(request.url).pathname;
      assets.push({path, method: request.method});
      return new Response("asset:" + path, {status: 200, headers: {"Content-Type": "text/html"}});
    }}
  };
  let portfolio = new Portfolio(ctx, env);
  env.PORTFOLIO = {idFromName(name) { return name; }, get(id) {
    assert.equal(id, "owner-eu-pvp-alliance-v1");
    return {fetch(request) { return portfolio.fetch(request); }};
  }};
  if (guild) {
    const separate = sqliteContext();
    t.after(() => separate.db.close());
    const market = new GuildMarket(separate.ctx, env);
    env.GUILD = {idFromName(name) { return name; }, get(id) {
      assert.equal(id, "guild-forever-eu-v1");
      return {fetch(request) { return market.fetch(request); }};
    }};
  }
  const f = {
    env, db, ctx, assets,
    restart() { portfolio = new Portfolio(ctx, env); },
    state() { return portfolio.store.loadState(); },
    async call(path, {method = "GET", data, raw, headers = {}, cookie, csrf, token, origin, ip} = {}) {
      const h = new Headers(headers);
      if (cookie) h.set("Cookie", cookie);
      if (csrf) h.set("X-CSRF-Token", csrf);
      if (token) h.set("Authorization", "Bearer " + token);
      if (origin) h.set("Origin", origin);
      if (ip) h.set("CF-Connecting-IP", ip);
      const body = raw !== undefined ? raw : data !== undefined ? JSON.stringify(data) : undefined;
      if (body !== undefined && !h.has("Content-Type")) h.set("Content-Type", "application/json");
      return worker.fetch(new Request(BASE + path, {method, headers: h, ...(body !== undefined ? {body} : {})}), env);
    },
    async login(password = PASSWORD, options = {}) {
      const response = await this.call("/api/login", {method: "POST", data: {password}, origin: BASE, ...options});
      const cookie = response.headers.get("Set-Cookie")?.split(";")[0];
      return {response, cookie};
    },
    async owner() {
      const {response, cookie} = await this.login();
      assert.equal(response.status, 200);
      const result = await this.call("/api/state", {cookie});
      assert.equal(result.status, 200);
      const state = await result.json();
      return {cookie, csrf: state.token};
    },
    async mutation(path, data, owner) {
      return this.call(path, {method: "POST", data, ...owner, origin: BASE});
    },
    async device(owner) {
      const response = await this.mutation("/api/devices", {label: "PC de prueba"}, owner);
      assert.equal(response.status, 200);
      return response.json();
    }
  };
  return f;
}

function lua(value) {
  if (value === null) return "nil";
  if (value === true) return "true";
  if (value === false) return "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") return String(value);
  const entries = value instanceof Map ? Array.from(value) : Object.entries(value);
  return "{" + entries.map(([key, v]) => "[" + lua(key) + "]=" + lua(v)).join(",") + "}";
}

function historyText(realm = REALM) {
  const hour = Math.floor(Date.now() / 3600000);
  return "AuctioneerStatsOverTimeData=" + lua({[realm]: new Map([[hour, {price: {"2589": 200}, count: {"2589": 10}}]])});
}

function bridgeData() {
  const captured = Math.floor(Date.now() / 1000);
  return {schemaVersion: 1, source: "Auctioneer12.x", market: MARKET, enabled: true, confirmedMarket: true,
    capturedAt: captured, savedAt: captured, lastBatchScope: "partial", complete: false,
    metadata: {region: "EU", faction: "Alliance", ruleset: "pvp", rulesetVerification: "user-confirmed", interface: 16001, realm: REALM},
    items: {"2589": {itemId: 2589, name: "Paño de prueba", buyCopper: 100, quantityObserved: 10, observedAt: captured}}};
}
function bridgeText(data = bridgeData()) { return "EspeculadorBridgeDB=" + lua(data); }
function syncPayload(changes = {}) { return {historyText: historyText(), bridgeText: bridgeText(), realm: REALM, confirmedMarket: true, ...changes}; }

test("an unconfigured deployment fails closed while login assets remain public", async t => {
  const f = fixture(t, false);
  assert.equal((await f.call("/api/state")).status, 503);
  assert.equal((await f.call("/", {})).status, 302);
  assert.equal((await f.call("/api/device/sync", {method: "POST", data: {}})).status, 503);
  const login = await f.call("/login");
  assert.equal(login.status, 200);
  assert.equal(await login.text(), "asset:/login.html");
  assert.equal(f.state().transactions.length, 0);
});

test("anonymous requests see login but cannot read account or downloads", async t => {
  const f = fixture(t);
  const root = await f.call("/");
  assert.equal(root.status, 302);
  assert.equal(root.headers.get("Location"), BASE + "/login");
  assert.equal((await f.call("/api/state")).status, 401);
  assert.equal((await f.call("/api/export")).status, 401);
  assert.equal((await f.call("/api/connector")).status, 401);
  assert.equal((await f.call("/downloads/Sincronizador_PC.zip")).status, 302);
  assert.equal((await f.call("/app.js")).status, 302);
  assert.equal((await f.call("/login.js")).status, 200);
  assert.equal((await f.call("/login.css")).status, 200);
  assert.ok(!f.assets.some(asset => asset.path.includes("downloads")));
});

test("health exposes configuration status without password, tokens or account data", async t => {
  const f = fixture(t);
  const response = await f.call("/api/health");
  assert.equal(response.status, 200);
  const text = await response.text();
  const body = JSON.parse(text);
  assert.deepEqual(Object.keys(body).sort(), ["configurationIssue", "configured", "ok", "version"]);
  assert.equal(body.configured, true);
  assert.equal(body.configurationIssue, null);
  assert.ok(!text.includes(PASSWORD));
  assert.ok(!text.includes(f.env.SESSION_SECRET));
  assert.ok(response.headers.get("Content-Security-Policy").includes("frame-ancestors 'none'"));
  assert.equal(response.headers.get("X-Robots-Tag"), "noindex, nofollow, noarchive");
});

test("configuration diagnostics distinguish missing, wrong type and short passwords without leaking them", async t => {
  const cases = [
    {value:undefined, issue:"missing_password", message:/Configura el secreto OWNER_PASSWORD/},
    {value:null, issue:"missing_password", message:/Configura el secreto OWNER_PASSWORD/},
    {value:"", issue:"missing_password", message:/Configura el secreto OWNER_PASSWORD/},
    {value:{marker:"private-wrong-type-value"}, issue:"invalid_password_type", message:/no está configurado como texto/, marker:"private-wrong-type-value"},
    {value:1234567890123456, issue:"invalid_password_type", message:/no está configurado como texto/, marker:"1234567890123456"},
    {value:"short-secret-15", issue:"password_too_short", message:/contraseña guardada.*menos de 16 caracteres/, marker:"short-secret-15"},
    {value:"valid-secret-016", issue:null, marker:"valid-secret-016"}
  ];
  for (const entry of cases) {
    const f = fixture(t);
    f.env.OWNER_PASSWORD = entry.value;
    const health = await f.call("/api/health");
    assert.equal(health.status, 200);
    const healthText = await health.text(), body = JSON.parse(healthText);
    assert.deepEqual(Object.keys(body).sort(), ["configurationIssue", "configured", "ok", "version"]);
    assert.equal(body.configurationIssue, entry.issue);
    assert.equal(body.configured, entry.issue === null);
    assert.equal(health.headers.get("Cache-Control"), "private, no-store");
    const state = await f.call("/api/state");
    assert.equal(state.status, entry.issue === null ? 401 : 503);
    const stateText = await state.text();
    if (entry.issue) assert.match(JSON.parse(stateText).error, entry.message);
    if (entry.marker) {
      assert.ok(!healthText.includes(entry.marker));
      assert.ok(!stateText.includes(entry.marker));
    }
    if (entry.issue === null) assert.equal((await f.login(entry.value)).response.status, 200);
    else assert.equal((await f.login()).response.status, 503);
  }
});

test("bad login is rejected; good login issues a secure private cookie", async t => {
  const f = fixture(t);
  assert.equal((await f.login("incorrect-password")).response.status, 401);
  const {response, cookie} = await f.login();
  assert.equal(response.status, 200);
  const header = response.headers.get("Set-Cookie");
  assert.ok(header.startsWith(COOKIE_NAME + "="));
  for (const flag of ["HttpOnly", "Secure", "SameSite=Strict", "Path=/", "Max-Age=28800"]) assert.ok(header.includes(flag));
  assert.ok(!header.includes(PASSWORD));
  const state = await f.call("/api/state", {cookie});
  assert.equal(state.status, 200);
  const body = await state.json();
  assert.equal(body.market, MARKET);
  assert.ok(body.token.length > 20);
});

test("login rejects cross-origin and cross-site requests before authentication", async t => {
  const f = fixture(t);
  assert.equal((await f.login(PASSWORD, {origin: "https://attacker.test"})).response.status, 403);
  assert.equal((await f.login(PASSWORD, {headers: {"Sec-Fetch-Site": "cross-site"}})).response.status, 403);
  assert.equal((await f.call("/api/state")).status, 401);
});

test("login rate limit persists across Durable Object instances", async t => {
  const f = fixture(t);
  for (let count = 0; count < 8; count += 1) assert.equal((await f.login("wrong", {ip: "192.0.2.1"})).response.status, 401);
  f.restart();
  assert.equal((await f.login(PASSWORD, {ip: "192.0.2.1"})).response.status, 429);
  assert.equal((await f.login(PASSWORD, {ip: "192.0.2.2"})).response.status, 200);
});

test("forged, expired and future-issued sessions do not grant account access", async t => {
  const f = fixture(t);
  const owner = await f.owner();
  assert.equal((await f.call("/api/state", {cookie: owner.cookie + "tampered"})).status, 401);
  const old = await issueSession(f.env, Date.now() - 9 * 3600000);
  assert.equal((await f.call("/api/state", {cookie: COOKIE_NAME + "=" + old.value})).status, 401);
  const future = await issueSession(f.env, Date.now() + 3600000);
  assert.equal((await f.call("/api/state", {cookie: COOKIE_NAME + "=" + future.value})).status, 401);
  assert.equal((await f.call("/api/state", {headers: {"X-Owner-CSRF": "forged", "X-Device-Hash": "a".repeat(64)}})).status, 401);
});

test("owner mutations require the matching session CSRF token and origin", async t => {
  const f = fixture(t);
  const owner = await f.owner();
  assert.equal((await f.call("/api/settings", {method: "POST", data: {capitalCopper: 999}, cookie: owner.cookie})).status, 403);
  assert.equal((await f.call("/api/settings", {method: "POST", data: {capitalCopper: 999}, cookie: owner.cookie, csrf: "forged"})).status, 403);
  assert.equal((await f.call("/api/settings", {method: "POST", data: {capitalCopper: 999}, ...owner, origin: "https://attacker.test"})).status, 403);
  assert.equal(f.state().settings.capitalCopper, 0);
  assert.equal((await f.mutation("/api/settings", {capitalCopper: 10000}, owner)).status, 200);
  assert.equal(f.state().settings.capitalCopper, 10000);
});

test("a CSRF token from another valid owner session cannot authorise a mutation", async t => {
  const f = fixture(t);
  const first = await f.owner(), second = await f.owner();
  assert.notEqual(first.csrf, second.csrf);
  assert.equal((await f.call("/api/settings", {method: "POST", data: {capitalCopper: 100}, cookie: first.cookie, csrf: second.csrf})).status, 403);
  assert.equal(f.state().settings.capitalCopper, 0);
});

test("owner ledger routes preserve FIFO cost, profit and rejected oversales", async t => {
  const f = fixture(t), owner = await f.owner();
  await f.mutation("/api/settings", {capitalCopper: 10000}, owner);
  assert.equal((await f.mutation("/api/transactions", {kind: "buy", itemId: 2589, name: "Test", quantity: 10, unitCopper: 100}, owner)).status, 200);
  const sale = await f.mutation("/api/transactions", {kind: "sell", itemId: 2589, name: "Test", quantity: 4, unitCopper: 200, feeCopper: 40}, owner);
  assert.equal(sale.status, 200);
  assert.equal((await sale.json()).realizedProfitCopper, 360);
  const before = structuredClone(f.state());
  assert.equal((await f.mutation("/api/transactions", {kind: "sell", itemId: 2589, name: "Test", quantity: 7, unitCopper: 200}, owner)).status, 400);
  assert.deepEqual(f.state(), before);
  f.restart();
  const state = await (await f.call("/api/state", owner)).json();
  assert.equal(state.summary.realizedProfitCopper, 360);
  assert.equal(state.summary.availableCapitalCopper, 9760);
  assert.equal(state.inventory[0].quantity, 6);
});

test("export and restore routes preserve a recoverable prior account", async t => {
  const f = fixture(t), owner = await f.owner();
  await f.mutation("/api/settings", {capitalCopper: 10000}, owner);
  const initial = await (await f.call("/api/export", owner)).json();
  await f.mutation("/api/transactions", {kind: "buy", itemId: 2589, name: "Test", quantity: 2, unitCopper: 100}, owner);
  const current = await (await f.call("/api/export", owner)).json();
  const restored = await f.mutation("/api/restore", initial, owner);
  assert.equal(restored.status, 200);
  assert.equal(f.state().transactions.length, 0);
  const previous = await f.call("/api/backups/previous", owner);
  assert.equal(previous.status, 200);
  const backup = await previous.json();
  assert.deepEqual(backup.transactions, current.transactions);
  assert.equal(backup.market, MARKET);
});

test("invalid restore neither changes current data nor creates a misleading backup", async t => {
  const f = fixture(t), owner = await f.owner();
  await f.mutation("/api/settings", {capitalCopper: 10000}, owner);
  const state = structuredClone(f.state());
  assert.equal((await f.mutation("/api/restore", {format: "forever-mercado-backup", version: 1, market: "other"}, owner)).status, 400);
  assert.deepEqual(f.state(), state);
  assert.equal((await f.call("/api/backups/previous", owner)).status, 404);
});

test("a device secret is returned once and absent from state, list and exports", async t => {
  const f = fixture(t), owner = await f.owner();
  const device = await f.device(owner);
  assert.match(device.token, /^esp_[A-Za-z0-9_-]{43}$/);
  const state = await (await f.call("/api/state", owner)).json();
  assert.equal(state.auctioneer.devices.length, 1);
  assert.equal(state.auctioneer.devices[0].id, device.id);
  const exported = await (await f.call("/api/export", owner)).json();
  for (const result of [state, exported]) {
    const text = JSON.stringify(result);
    assert.ok(!text.includes(device.token));
    assert.ok(!text.includes("tokenHash"));
    assert.ok(!text.includes(PASSWORD));
  }
  const persisted = f.db.prepare("SELECT token_hash FROM especulador_devices WHERE id=?").get(device.id);
  assert.match(persisted.token_hash, /^[a-f0-9]{64}$/);
  assert.notEqual(persisted.token_hash, device.token);
});

test("device credentials can upload sources but cannot read or edit owner records", async t => {
  const f = fixture(t), owner = await f.owner(), device = await f.device(owner);
  assert.equal((await f.call("/api/state", {token: device.token})).status, 401);
  assert.equal((await f.call("/api/export", {token: device.token})).status, 401);
  assert.equal((await f.call("/api/settings", {method: "POST", data: {capitalCopper: 9999}, token: device.token})).status, 401);
  const sync = await f.call("/api/device/sync", {method: "POST", data: syncPayload(), token: device.token});
  assert.equal(sync.status, 200);
  assert.equal((await sync.json()).accepted, true);
  assert.equal(f.state().history.length, 1);
  assert.equal(f.state().snapshots.length, 1);
  assert.equal(f.state().transactions.length, 0);
  assert.equal(f.state().settings.capitalCopper, 0);
  const state = await (await f.call("/api/state", owner)).json();
  assert.ok(state.auctioneer.devices[0].lastSeenAt);
});

test("revocation blocks the next device upload and cannot be requested by the device", async t => {
  const f = fixture(t), owner = await f.owner(), device = await f.device(owner);
  assert.equal((await f.call("/api/devices/revoke", {method: "POST", data: {id: device.id}, token: device.token})).status, 401);
  assert.equal((await f.mutation("/api/devices/revoke", {id: device.id}, owner)).status, 200);
  const before = structuredClone(f.state());
  const response = await f.call("/api/device/sync", {method: "POST", data: syncPayload(), token: device.token});
  assert.equal(response.status, 401);
  assert.deepEqual(f.state(), before);
});

test("unknown and malformed device secrets are rejected without accepting forged internal headers", async t => {
  const f = fixture(t);
  for (const token of ["bad", "esp_" + "x".repeat(43)]) {
    assert.equal((await f.call("/api/device/sync", {method: "POST", data: syncPayload(), token, headers: {"X-Device-Hash": "a".repeat(64), "X-Owner-CSRF": "forged"}})).status, 401);
  }
  assert.equal(f.state().history.length, 0);
});

test("malicious Lua is rejected without changing any stored market or owner data", async t => {
  const f = fixture(t), owner = await f.owner();
  const before = structuredClone(f.state());
  const response = await f.mutation("/api/auctioneer/import", {text: "AuctioneerStatsOverTimeData = {}; os.execute('ignored')", realm: REALM, confirmedMarket: true}, owner);
  assert.equal(response.status, 400);
  assert.deepEqual(f.state(), before);
});

test("combined upload validates bridge and history before importing either", async t => {
  const f = fixture(t), owner = await f.owner(), device = await f.device(owner);
  const invalid = bridgeData();
  invalid.items["2589"].name = true;
  const before = structuredClone(f.state());
  const response = await f.call("/api/device/sync", {method: "POST", data: syncPayload({bridgeText: bridgeText(invalid)}), token: device.token});
  assert.equal(response.status, 400);
  assert.deepEqual(f.state(), before);
  assert.equal(f.db.prepare("SELECT last_seen_at FROM especulador_devices WHERE id=?").get(device.id).last_seen_at, null);
});

test("mismatched realm or missing market confirmation rejects device sources atomically", async t => {
  const f = fixture(t), owner = await f.owner(), device = await f.device(owner);
  for (const changes of [{realm: "another realm"}, {confirmedMarket: false}]) {
    const response = await f.call("/api/device/sync", {method: "POST", data: syncPayload(changes), token: device.token});
    assert.equal(response.status, 400);
  }
  assert.equal(f.state().history.length, 0);
  assert.equal(f.state().snapshots.length, 0);
});

test("manual historical discovery does not write records or fabricate current offers", async t => {
  const f = fixture(t), owner = await f.owner();
  const discovery = await f.mutation("/api/auctioneer/import", {text: historyText()}, owner);
  assert.equal(discovery.status, 200);
  assert.equal((await discovery.json()).requiresRealm, true);
  assert.equal(f.state().history.length, 0);
  const imported = await f.mutation("/api/auctioneer/import", {text: historyText(), realm: REALM, confirmedMarket: true}, owner);
  assert.equal(imported.status, 200);
  const state = await (await f.call("/api/state", owner)).json();
  assert.equal(state.auctioneer.history.count, 1);
  assert.equal(state.items.length, 0);
});

test("manual bridge import preserves partial coverage and per-item observation time", async t => {
  const f = fixture(t), owner = await f.owner();
  const data = bridgeData();
  data.items["2589"].observedAt -= 8 * 3600;
  const response = await f.mutation("/api/auctioneer/bridge", {text: bridgeText(data)}, owner);
  assert.equal(response.status, 200);
  const state = await (await f.call("/api/state", owner)).json();
  assert.equal(state.status.coverage, "partial");
  assert.equal(state.items[0].eligible, false);
  assert.equal(state.items[0].observedAt, new Date(data.items["2589"].observedAt * 1000).toISOString());
});

test("the cloud refuses local PC paths and polling never invents new scans", async t => {
  const f = fixture(t), owner = await f.owner();
  assert.equal((await f.mutation("/api/auctioneer/config", {path: "C:\\private\\file.lua", enabled: true}, owner)).status, 400);
  const response = await f.mutation("/api/sync", {}, owner);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).connected, false);
  assert.equal(f.state().snapshots.length, 0);
});

test("private downloads work only for authenticated owners and receive safe headers", async t => {
  const f = fixture(t), owner = await f.owner();
  for (const [route, name] of [["/api/addon", "EspeculadorBridge.zip"], ["/api/connector", "Sincronizador_PC.zip"]]) {
    const response = await f.call(route, owner);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Disposition"), `attachment; filename="${name}"`);
    assert.equal(response.headers.get("Cache-Control"), "private, no-store");
    assert.ok((await response.text()).includes("/downloads/"));
  }
});

test("logout requires CSRF and expires the browser cookie", async t => {
  const f = fixture(t), owner = await f.owner();
  assert.equal((await f.call("/api/logout", {method: "POST", data: {}, cookie: owner.cookie})).status, 403);
  const response = await f.mutation("/api/logout", {}, owner);
  assert.equal(response.status, 200);
  assert.ok(response.headers.get("Set-Cookie").includes("Max-Age=0"));
  assert.equal((await f.call("/api/state")).status, 401);
});

test("malformed and oversized JSON cannot modify an owner account", async t => {
  const f = fixture(t), owner = await f.owner();
  const before = structuredClone(f.state());
  for (const raw of ["[1,2,3]", "{broken", "null"]) {
    assert.equal((await f.call("/api/settings", {method: "POST", raw, ...owner, origin: BASE})).status, 400);
  }
  const oversized = await f.call("/api/import", {method: "POST", raw: "{}", ...owner, origin: BASE, headers: {"Content-Length": String(16 * 1024 * 1024 + 1)}});
  assert.equal(oversized.status, 413);
  assert.deepEqual(f.state(), before);
});

test("a forged internal device hash cannot substitute for the paired secret", async t => {
  const f = fixture(t), owner = await f.owner(), device = await f.device(owner);
  const hash = f.db.prepare("SELECT token_hash FROM especulador_devices WHERE id=?").get(device.id).token_hash;
  const response = await f.call("/api/device/sync", {method: "POST", data: syncPayload(), token: "esp_" + "z".repeat(43), headers: {"X-Device-Hash": hash}});
  assert.equal(response.status, 401);
  assert.equal(f.state().history.length, 0);
  assert.equal(f.state().snapshots.length, 0);
});

test("retrying the same paired upload does not duplicate history or rejuvenate prices", async t => {
  const f = fixture(t), owner = await f.owner(), device = await f.device(owner);
  const bridge = bridgeData(), data = syncPayload({bridgeText: bridgeText(bridge)});
  for (let retry = 0; retry < 2; retry += 1) {
    const response = await f.call("/api/device/sync", {method: "POST", data, token: device.token});
    assert.equal(response.status, 200);
    assert.equal((await response.json()).accepted, true);
  }
  const state = f.state();
  assert.equal(state.history.length, 1);
  assert.equal(state.snapshots.length, 1);
  assert.equal(state.snapshots[0].items[0].observedAt, new Date(bridge.items["2589"].observedAt * 1000).toISOString());
});

test("corrupted stored chunks never become an empty account through an API write", async t => {
  const f = fixture(t), owner = await f.owner();
  await f.mutation("/api/settings", {capitalCopper: 15000}, owner);
  f.db.exec("DELETE FROM especulador_chunks WHERE kind='state'");
  const before = f.db.prepare("SELECT * FROM especulador_meta WHERE kind='state'").get();
  assert.notEqual((await f.call("/api/state", owner)).status, 200);
  assert.notEqual((await f.mutation("/api/settings", {capitalCopper: 0}, owner)).status, 200);
  assert.deepEqual(f.db.prepare("SELECT * FROM especulador_meta WHERE kind='state'").get(), before);
  assert.equal(f.db.prepare("SELECT count(*) AS n FROM especulador_chunks WHERE kind='state'").get().n, 0);
});

test("rotating the session secret invalidates old cookies and permits a fresh owner login", async t => {
  const f = fixture(t), previous = await f.owner();
  f.env.SESSION_SECRET = "new-test-session-secret-for-rotation";
  assert.equal((await f.call("/api/state", previous)).status, 401);
  const fresh = await f.owner();
  assert.equal((await f.call("/api/state", fresh)).status, 200);
});

test("revoked device secrets cannot access protected downloads or create new device keys", async t => {
  const f = fixture(t), owner = await f.owner(), device = await f.device(owner);
  await f.mutation("/api/devices/revoke", {id: device.id}, owner);
  assert.equal((await f.call("/api/addon", {token: device.token})).status, 401);
  assert.equal((await f.call("/api/connector", {token: device.token})).status, 401);
  assert.equal((await f.call("/api/devices", {method: "POST", data: {label: "unauthorised"}, token: device.token})).status, 401);
  assert.equal(f.db.prepare("SELECT count(*) AS n FROM especulador_devices").get().n, 1);
});

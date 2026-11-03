/** Guild market: Worker -> GuildMarket Durable Object -> real SQLite (node:sqlite), without HTTP sockets.
 * Portfolio and GuildMarket each get their own database, as two Durable Objects do in production. */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {DatabaseSync} from "node:sqlite";
import worker, {Portfolio, GuildMarket as WorkerGuildMarket} from "../src/worker.mjs";
import {GuildMarket, GuildStore, validateUpload, issueGuildSession, goldCell, pctCell, textCell, dateOfDay, LIMITS, WATCHLIST,
  GUILD_COOKIE} from "../src/guild.mjs";
import {DAY0, BUDGET, buildDays, baseline, assess, flip, deltas, weekday, texts, mergeDay, dayValue, median} from "../src/especular.mjs";

const BASE = "https://especulador.test";
const PASSWORD = "test-only-owner-password-47-strong";
const MARKET = "Grito de Guerra-Alliance";
const DAY = 86400;
const T0 = 2530;                                   // 2026-12-05, after the launch guard
const at = (d, hour = 12, minute = 0) => DAY0 + d * DAY + hour * 3600 + minute * 60;
const WATCH_IDS = Object.values(WATCHLIST).flat();
const DATA_TABLES = ["guild_obs_day", "guild_obs_point", "guild_deposits", "guild_day_agg", "guild_items"];

/** Cloudflare's SqlStorage on node:sqlite. rowsWritten counts table rows only (Cloudflare also counts index entries);
 * reads records how many rows each statement returned. */
function sqliteContext() {
  const db = new DatabaseSync(":memory:"), queries = [], reads = [];
  const sql = {exec(query, ...bindings) {
    queries.push(query);
    const statement = db.prepare(query), write = /^\s*(?:INSERT|UPDATE|DELETE|REPLACE)\b/i.test(query);
    let rows = [], rowsWritten = 0;
    if (statement.columns().length) { rows = statement.all(...bindings); if (write) rowsWritten = rows.length; else reads.push([query, rows.length]); }
    else { const result = statement.run(...bindings); if (write) rowsWritten = Number(result.changes); }
    return {rowsWritten, toArray: () => rows, [Symbol.iterator]: () => rows[Symbol.iterator]()};
  }};
  return {db, queries, reads, ctx: {storage: {sql, transactionSync(callback) {
    db.exec("BEGIN IMMEDIATE");
    try { const result = callback(); assert.ok(!(result instanceof Promise)); db.exec("COMMIT"); return result; }
    catch (error) { db.exec("ROLLBACK"); throw error; }
  }}}};
}
/** Every row of every table (optionally only some), for before/after comparisons. Rate limits and the write counter
 * are bookkeeping that every request may touch. */
function dump(db, {only = null, skip = ["guild_rate_limits", "guild_write_budget"]} = {}) {
  const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(r => r.name)
    .filter(name => (only ? only.includes(name) : true) && !skip.includes(name));
  return Object.fromEntries(names.map(name => {
    const columns = db.prepare(`PRAGMA table_info("${name}")`).all().map((_, i) => i + 1).join(",");
    return [name, db.prepare(`SELECT * FROM "${name}" ORDER BY ${columns}`).all().map(r => ({...r}))];
  }));
}

function fixture(t, {guild = true, configured = true} = {}) {
  const P = sqliteContext(), G = sqliteContext();
  t.after(() => { P.db.close(); G.db.close(); });
  const assets = [], calls = {portfolio: 0, guild: 0};
  const env = {
    OWNER_PASSWORD: configured ? PASSWORD : undefined,
    SESSION_SECRET: "test-only-independent-session-secret-99",
    ASSETS: {async fetch(request) {
      const path = new URL(request.url).pathname;
      assets.push(path);
      return new Response("asset:" + path, {status: 200, headers: {"Content-Type": "application/zip"}});
    }}
  };
  let portfolio = new Portfolio(P.ctx, env);
  env.PORTFOLIO = {idFromName(name) { return name; }, get(id) {
    assert.equal(id, "owner-eu-pvp-alliance-v1");
    return {fetch(request) { calls.portfolio++; return portfolio.fetch(request); }};
  }};
  let clock = at(T0, 18) * 1000;
  let market = new GuildMarket(G.ctx, env);
  market.now = () => clock;
  if (guild) env.GUILD = {idFromName(name) { return name; }, get(id) {
    assert.equal(id, "guild-forever-eu-v1");
    return {fetch(request) { calls.guild++; return market.fetch(request); }};
  }};
  return {
    env, calls, assets, gdb: G.db, pdb: P.db, queries: G.queries, reads: G.reads, gctx: G.ctx,
    get T() { return Math.floor((clock / 1000 - DAY0) / DAY); },
    get nowSec() { return Math.floor(clock / 1000); },
    setTime(d, hour = 18, minute = 0) { clock = at(d, hour, minute) * 1000; },
    advance(ms) { clock += ms; },
    restart() { market = new GuildMarket(G.ctx, env); market.now = () => clock; },
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
    async owner() {
      const login = await this.call("/api/login", {method: "POST", data: {password: PASSWORD}, origin: BASE});
      assert.equal(login.status, 200);
      const cookie = login.headers.get("Set-Cookie").split(";")[0];
      const state = await (await this.call("/api/state", {cookie})).json();
      const me = await this.call("/api/guild/me", {cookie});
      assert.equal(me.status, 200);
      return {cookie, csrf: (await me.json()).csrf, portfolioCsrf: state.token};
    },
    post(path, data, who) { return this.call(path, {method: "POST", data, cookie: who.cookie, csrf: who.csrf, origin: BASE}); },
    async member(who, label, role = "member") {
      const created = await this.post("/api/guild/members", {label, role}, who);
      assert.equal(created.status, 200, await created.clone().text());
      const {member} = await created.json();
      return {...member, ...await this.key(who, member.id)};
    },
    async key(who, memberId) {
      const response = await this.post("/api/guild/keys", {memberId}, who);
      assert.equal(response.status, 200, await response.clone().text());
      const body = await response.json();
      return {key: body.key, keyId: body.keyId};
    },
    async login(key, {ip = "198.51.100.7", origin = BASE} = {}) {
      const response = await this.call("/api/guild/login", {method: "POST", data: {key}, origin, ip});
      const body = await response.clone().json();
      return {response, body, cookie: response.headers.get("Set-Cookie")?.split(";")[0], csrf: body.csrf};
    },
    sync(key, body, headers = {}) {
      return this.call("/api/guild/sync", {method: "POST", raw: typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body), token: key, headers});
    },
    async market(who, name = MARKET) { return this.call("/api/guild/market?market=" + encodeURIComponent(name), {cookie: who.cookie}); }
  };
}

function item(id, {name = "Objeto " + id, cat = "tela", vendor = 100, days = [], points = []} = {}) { return {id, name, cat, vendor, days, points}; }
function upload(items, {market = MARKET, cut = 500, deposits = [], addon = "0.3.0", markets} = {}) {
  return {schema: 1, addon, markets: markets ?? [{market, cut, items, deposits}]};
}
function flat(lo, from, to, {spread = 200, qty = 400, scans = 2, src = "o"} = {}) {
  const out = [];
  for (let d = from; d <= to; d++) out.push([d, lo, lo + spread, lo + spread / 2, qty, scans, src]);
  return out;
}
function rng(seed) {
  return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let x = Math.imul(seed ^ seed >>> 15, 1 | seed); x = x + Math.imul(x ^ x >>> 7, 61 | x) ^ x; return ((x ^ x >>> 14) >>> 0) / 4294967296; };
}

// ---------------------------------------------------------------------------------------------------------------
test("without the GUILD binding every guild route answers 503 and nothing reaches Portfolio", async t => {
  const f = fixture(t, {guild: false});
  const routes = [["GET", "/api/guild/me"], ["GET", "/api/guild/market?market=a-Alliance"], ["GET", "/api/guild/item?market=a-Alliance&id=1"],
    ["GET", "/api/guild/export.csv?market=a-Alliance"], ["GET", "/api/guild/members"], ["GET", "/api/guild/download/sincronizador"],
    ["POST", "/api/guild/sync"], ["POST", "/api/guild/login"], ["POST", "/api/guild/logout"], ["POST", "/api/guild/members"],
    ["POST", "/api/guild/members/role"], ["POST", "/api/guild/members/revoke"], ["POST", "/api/guild/keys"], ["POST", "/api/guild/keys/revoke"],
    ["GET", "/api/guild/unknown"], ["GET", "/api/guild"]];
  for (const [method, path] of routes) {
    const response = await f.call(path, {method, ...(method === "POST" ? {data: {}} : {}), token: "gld_" + "a".repeat(43), origin: BASE});
    assert.equal(response.status, 503, path);
    assert.match((await response.json()).error, /^Hermandad no configurada/);
  }
  assert.equal(f.calls.portfolio, 0);
  const owner = await f.call("/api/login", {method: "POST", data: {password: PASSWORD}, origin: BASE});
  const cookie = owner.headers.get("Set-Cookie").split(";")[0], before = f.calls.portfolio;
  assert.equal((await f.call("/api/guild/members", {cookie})).status, 503);
  assert.equal(f.calls.portfolio, before, "an owner guild request is never forwarded to Portfolio");
  assert.equal((await f.call("/api/state", {cookie})).status, 200);
});

test("an unconfigured owner password keeps the guild closed too", async t => {
  const f = fixture(t, {configured: false});
  for (const [method, path] of [["GET", "/api/guild/me"], ["POST", "/api/guild/sync"], ["POST", "/api/guild/login"]]) {
    const response = await f.call(path, {method, ...(method === "POST" ? {data: {}} : {}), token: "gld_" + "a".repeat(43), origin: BASE});
    assert.equal(response.status, 503);
    assert.match((await response.json()).error, /OWNER_PASSWORD/);
  }
  assert.equal(f.calls.guild, 0);
});

test("wrangler and the worker entry add GuildMarket without touching Portfolio or migration v1", () => {
  const config = JSON.parse(fs.readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8"));
  assert.deepEqual(config.durable_objects.bindings, [{name: "PORTFOLIO", class_name: "Portfolio"}, {name: "GUILD", class_name: "GuildMarket"}]);
  assert.deepEqual(config.migrations, [{tag: "v1", new_sqlite_classes: ["Portfolio"]}, {tag: "v2", new_sqlite_classes: ["GuildMarket"]}]);
  assert.equal(config.main, "src/worker.mjs");
  assert.equal(WorkerGuildMarket, GuildMarket);
  assert.equal(WATCH_IDS.length, 80);
  assert.equal(new Set(WATCH_IDS).size, 80);
});

test("unknown guild paths and wrong methods are rejected before any authentication", async t => {
  const f = fixture(t);
  assert.equal((await f.call("/api/guild/nada")).status, 404);
  assert.equal((await f.call("/api/guild/me", {method: "POST", data: {}})).status, 405);
  assert.equal((await f.call("/api/guild/sync")).status, 405);
  assert.equal((await f.call("/api/guild/me", {method: "HEAD"})).status, 405);
  assert.equal(f.calls.guild, 0);
});

// ---------------------------------------------------------------------------------------------------------------
test("the owner creates members and keys; a key is shown once and stored only as its SHA-256", async t => {
  const f = fixture(t), owner = await f.owner();
  const ana = await f.member(owner, "Ana");
  assert.match(ana.key, /^gld_[A-Za-z0-9_-]{43}$/);
  const list = await f.call("/api/guild/members", {cookie: owner.cookie});
  assert.equal(list.status, 200);
  const text = await list.text(), body = JSON.parse(text);
  assert.ok(!text.includes(ana.key) && !text.includes(ana.key.slice(4)));
  assert.equal(body.members.length, 1);
  assert.deepEqual([body.members[0].label, body.members[0].role, body.members[0].activeKeys, body.activeKeys, body.maxKeys], ["Ana", "member", 1, 1, 50]);
  const stored = f.gdb.prepare("SELECT token_hash FROM guild_keys").get().token_hash;
  assert.match(stored, /^[a-f0-9]{64}$/);
  const everything = JSON.stringify(dump(f.gdb, {skip: []}));
  assert.ok(!everything.includes(ana.key.slice(4)), "the plain key is nowhere in the guild database");
  assert.ok(!JSON.stringify(dump(f.pdb, {skip: []})).includes(ana.key.slice(4)));
  // Labels are unique regardless of case; roles are checked.
  assert.equal((await f.post("/api/guild/members", {label: "ANA"}, owner)).status, 400);
  assert.equal((await f.post("/api/guild/members", {label: ""}, owner)).status, 400);
  assert.equal((await f.post("/api/guild/members", {label: "x".repeat(41)}, owner)).status, 400);
  assert.equal((await f.post("/api/guild/members", {label: "Bruno", role: "owner"}, owner)).status, 400);
  assert.equal((await f.post("/api/guild/keys", {memberId: 999}, owner)).status, 404);
});

test("the guild CSRF and the Portfolio CSRF are different tokens and neither works for the other", async t => {
  const f = fixture(t), owner = await f.owner();
  assert.notEqual(owner.csrf, owner.portfolioCsrf);
  assert.equal((await f.post("/api/guild/members", {label: "Ana"}, {cookie: owner.cookie, csrf: owner.portfolioCsrf})).status, 403);
  assert.equal((await f.post("/api/guild/members", {label: "Ana"}, {cookie: owner.cookie})).status, 403);
  assert.equal((await f.call("/api/guild/members", {method: "POST", data: {label: "Ana"}, cookie: owner.cookie, csrf: owner.csrf, origin: "https://attacker.test"})).status, 403);
  assert.equal((await f.call("/api/settings", {method: "POST", data: {capitalCopper: 5}, cookie: owner.cookie, csrf: owner.csrf, origin: BASE})).status, 403);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_members").get().n, 0);
});

test("a member login sets the guild cookie with its own CSRF and grants nothing in Portfolio", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const {response, body, cookie, csrf} = await f.login("  " + ana.key + "\n");
  assert.equal(response.status, 200);
  const header = response.headers.get("Set-Cookie");
  assert.ok(header.startsWith(GUILD_COOKIE + "="));
  for (const flag of ["HttpOnly", "Secure", "SameSite=Strict", "Path=/", "Max-Age=604800"]) assert.ok(header.includes(flag), flag);
  assert.ok(!header.includes(ana.key));
  assert.deepEqual(body.member, {id: ana.id, label: "Ana", role: "member"});
  const me = await (await f.call("/api/guild/me", {cookie})).json();
  assert.deepEqual([me.role, me.isOwner, me.canAdmin, me.member.label, me.csrf, me.uploadsToday, me.T, me.date], ["member", false, false, "Ana", csrf, 0, T0, "2026-12-05"]);
  assert.equal((await f.call("/api/state", {cookie})).status, 401);
  assert.equal((await f.call("/api/export", {cookie})).status, 401);
  assert.equal((await f.call("/api/guild/logout", {method: "POST", data: {}, cookie, origin: BASE})).status, 403);
  const out = await f.call("/api/guild/logout", {method: "POST", data: {}, cookie, csrf, origin: BASE});
  assert.equal(out.status, 200);
  assert.ok(out.headers.get("Set-Cookie").includes("Max-Age=0"));
  assert.ok(f.gdb.prepare("SELECT last_login_at FROM guild_keys WHERE id=?").get(ana.keyId).last_login_at > 0);
});

test("wrong, malformed, cross-origin, forged, expired and future guild sessions are rejected", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  assert.equal((await f.login("gld_" + "z".repeat(43))).response.status, 401);
  assert.equal((await f.login("not-a-key")).response.status, 401);
  assert.equal((await f.login(ana.key, {origin: "https://attacker.test"})).response.status, 403);
  assert.equal((await f.call("/api/guild/login", {method: "POST", raw: "{broken", origin: BASE})).status, 400);
  const {cookie} = await f.login(ana.key);
  assert.equal((await f.call("/api/guild/me", {cookie: cookie + "x"})).status, 401);
  const expired = await issueGuildSession(f.env, {memberId: ana.id, keyId: ana.keyId}, Date.now() - 8 * DAY * 1000);
  const future = await issueGuildSession(f.env, {memberId: ana.id, keyId: ana.keyId}, Date.now() + 3600000);
  for (const value of [expired.value, future.value]) {
    const response = await f.call("/api/guild/me", {cookie: GUILD_COOKIE + "=" + value});
    assert.equal(response.status, 401);
    assert.ok(response.headers.get("Set-Cookie").includes("Max-Age=0"));
  }
  // A cookie for another member id with a valid signature but a key that is not theirs.
  const bruno = await f.member(owner, "Bruno");
  const crossed = await issueGuildSession(f.env, {memberId: bruno.id, keyId: ana.keyId});
  assert.equal((await f.call("/api/guild/me", {cookie: GUILD_COOKIE + "=" + crossed.value})).status, 401);
  // Rotating the session secret invalidates guild cookies as well.
  assert.equal((await f.call("/api/guild/me", {cookie})).status, 200);
  f.env.SESSION_SECRET = "rotated-test-session-secret-000";
  assert.equal((await f.call("/api/guild/me", {cookie})).status, 401);
});

test("member keys, device keys and forged internal headers cannot cross between Portfolio and the guild", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const device = await (await f.call("/api/devices", {method: "POST", data: {label: "PC"}, cookie: owner.cookie, csrf: owner.portfolioCsrf, origin: BASE})).json();
  assert.equal((await f.call("/api/device/sync", {method: "POST", data: {}, token: ana.key})).status, 401);
  assert.equal((await f.sync(device.token, upload([]))).status, 401);
  assert.equal((await f.call("/api/guild/me", {token: ana.key})).status, 401);
  const hash = f.gdb.prepare("SELECT token_hash FROM guild_keys").get().token_hash;
  const forged = {"X-Member-Hash": hash, "X-Guild-Actor": JSON.stringify({kind: "owner"})};
  assert.equal((await f.sync("gld_" + "q".repeat(43), upload([]), forged)).status, 401);
  assert.equal((await f.call("/api/guild/members", {headers: forged})).status, 401);
  assert.equal((await f.call("/api/guild/members", {method: "POST", data: {label: "X"}, headers: forged, origin: BASE})).status, 401);
  const {cookie} = await f.login(ana.key);
  assert.equal((await f.call("/api/guild/members", {cookie, headers: {"X-Guild-Actor": JSON.stringify({kind: "owner"})}})).status, 403);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_uploads").get().n, 0);
});

// ---------------------------------------------------------------------------------------------------------------
test("two members with overlapping days merge per member first and then across members", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana"), bruno = await f.member(owner, "Bruno");
  const first = [[2520, 1000, 1100, 1050, 300, 2, "o"], [2521, 1010, 1090, 1020, 310, 1, "o"], [2522, 990, 1080, 1000, 320, 3, "a"], [2523, 1000, 1200, 1100, 200, 2, "o"]];
  const second = [[2521, 980, 1080, 1030, 250, 4, "o"], [2522, 1005, 1060, 1010, 280, 1, "o"], [2523, 1100, 1150, 1120, 500, 1, "a"], [2524, 1000, 1000, 1000, 0, 1, "o"]];
  const brunos = [[2522, 1200, 1300, 1250, 100, 1, "o"], [2523, 900, 1000, 950, 150, 2, "o"], [2525, 1100, 1100, 1100, 90, 5, "o"]];
  for (const [key, days] of [[ana.key, first], [ana.key, second], [bruno.key, brunos]]) {
    const response = await f.sync(key, upload([item(2589, {name: "Paño de lino", days})]));
    assert.equal(response.status, 200, await response.clone().text());
  }
  const row = (member, d) => ({...f.gdb.prepare("SELECT day AS d,lo,hi,last,qty,scans,src FROM guild_obs_day WHERE member_id=? AND item_id=2589 AND day=?").get(member, d)});
  const asRecord = ([d, lo, hi, last, qty, scans, src]) => ({d, lo, hi, last, qty, scans, src});
  for (const d of [2520, 2521, 2522, 2523, 2524]) {
    const fold = [...first, ...second].filter(r => r[0] === d).map(asRecord).reduce((acc, r) => mergeDay(acc, r), null);
    assert.deepEqual(row(ana.id, d), fold, `Ana day ${d}`);
  }
  assert.deepEqual(row(ana.id, 2521), {d: 2521, lo: 980, hi: 1090, last: 1030, qty: 310, scans: 4, src: "o"}, "lo min, hi max, qty max, scans max, last of more scans");
  assert.equal(row(ana.id, 2522).src, "o", "an own record replaces an earlier Auctionator import");
  assert.deepEqual(row(ana.id, 2523), {d: 2523, lo: 1000, hi: 1200, last: 1100, qty: 200, scans: 2, src: "o"}, "an import never overwrites an own day");
  const agg = d => f.gdb.prepare("SELECT v,lo,hi,qty,observers,members FROM guild_day_agg WHERE item_id=2589 AND day=?").get(d);
  for (const d of [2522, 2523]) {
    const value = dayValue([row(ana.id, d), row(bruno.id, d)].map((r, i) => ({lo: r.lo, hi: r.hi, qty: r.qty, id: String([ana.id, bruno.id][i])})));
    const a = agg(d);
    assert.deepEqual([a.v, a.qty, a.observers, a.members], [value.v, value.qty, 2, `${ana.id},${bruno.id}`], `day ${d}`);
    assert.equal(a.lo, Math.min(row(ana.id, d).lo, row(bruno.id, d).lo));
    assert.equal(a.hi, Math.max(row(ana.id, d).hi, row(bruno.id, d).hi));
  }
  assert.equal(agg(2524).qty, null, "qty 0 is unknown");
  assert.equal(agg(2525).observers, 1);
});

test("an identical body is a duplicate with no writes; the same data in a new file changes no rows", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const body = upload([item(2589, {days: flat(1000, T0 - 10, T0), points: [[at(T0, 9), 900, 40, 10]]})], {deposits: [[2589, 3, 50]]});
  const first = await f.sync(ana.key, body);
  assert.equal(first.status, 200);
  assert.ok((await first.json()).rowsChanged > 0);
  const before = dump(f.gdb);
  const again = await f.sync(ana.key, JSON.stringify(body));
  assert.equal(again.status, 200);
  assert.deepEqual(await again.json(), {accepted: true, duplicate: true, rowsChanged: 0, day: T0, message: "Este envío ya se había recibido: sin cambios."});
  assert.deepEqual(dump(f.gdb), before, "a duplicate writes nothing");
  const reworded = await f.sync(ana.key, JSON.stringify({...body, addon: "0.3.0-b"}, null, 2));
  const report = await reworded.json();
  assert.deepEqual([reworded.status, report.duplicate, report.rowsChanged, report.markets[0].days, report.markets[0].points], [200, false, 0, 0, 0]);
  assert.deepEqual(dump(f.gdb, {only: DATA_TABLES}), Object.fromEntries(DATA_TABLES.map(n => [n, before[n]])), "no data row changed");
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_uploads").get().n, 2);
  assert.equal(report.message, "Envío aceptado: sin cambios.");
});

test("revoking a key or a member stops uploads and sessions on the very next request", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const second = await f.key(owner, ana.id);
  const session = await f.login(ana.key), other = await f.login(second.key);
  assert.equal((await f.post("/api/guild/keys/revoke", {keyId: ana.keyId}, owner)).status, 200);
  const before = dump(f.gdb);
  const rejected = await f.sync(ana.key, upload([item(2589, {days: flat(1000, T0 - 3, T0)})]));
  assert.equal(rejected.status, 401);
  assert.deepEqual(dump(f.gdb), before);
  const me = await f.call("/api/guild/me", {cookie: session.cookie});
  assert.equal(me.status, 401);
  assert.ok(me.headers.get("Set-Cookie").includes("Max-Age=0"));
  assert.equal((await f.login(ana.key)).response.status, 401);
  assert.equal((await f.call("/api/guild/me", {cookie: other.cookie})).status, 200, "the member's other key still works");
  assert.equal((await f.sync(second.key, upload([item(2589, {days: flat(1000, T0 - 3, T0)})]))).status, 200);
  assert.equal((await f.post("/api/guild/members/revoke", {memberId: ana.id}, owner)).status, 200);
  assert.equal((await f.sync(second.key, upload([item(2589, {days: flat(900, T0 - 3, T0)})]))).status, 401);
  assert.equal((await f.call("/api/guild/market?market=" + encodeURIComponent(MARKET), {cookie: other.cookie})).status, 401);
  assert.equal((await f.login(second.key)).response.status, 401);
  assert.equal((await f.post("/api/guild/keys", {memberId: ana.id}, owner)).status, 400, "a revoked member gets no new keys");
  const list = await (await f.call("/api/guild/members", {cookie: owner.cookie})).json();
  assert.deepEqual([list.members[0].revoked, list.members[0].activeKeys, list.activeKeys, list.activeMembers], [true, 0, 0, 0]);
});

test("plain members cannot administer, admins manage plain members, and only the owner manages admins", async t => {
  const f = fixture(t), owner = await f.owner();
  const ana = await f.member(owner, "Ana"), carla = await f.member(owner, "Carla", "admin"), eva = await f.member(owner, "Eva", "admin");
  const member = await f.login(ana.key), admin = await f.login(carla.key);
  const asMember = {cookie: member.cookie, csrf: member.csrf}, asAdmin = {cookie: admin.cookie, csrf: admin.csrf};
  assert.equal((await f.call("/api/guild/members", {cookie: member.cookie})).status, 403);
  for (const [path, data] of [["/api/guild/members", {label: "Zoe"}], ["/api/guild/keys", {memberId: ana.id}], ["/api/guild/keys/revoke", {keyId: ana.keyId}],
    ["/api/guild/members/revoke", {memberId: ana.id}], ["/api/guild/members/role", {memberId: ana.id, role: "admin"}]]) {
    assert.equal((await f.post(path, data, asMember)).status, 403, path);
  }
  assert.equal((await f.call("/api/guild/members", {cookie: admin.cookie})).status, 200);
  const dani = await f.member(asAdmin, "Dani");
  assert.equal((await f.post("/api/guild/members", {label: "Fede", role: "admin"}, asAdmin)).status, 403);
  await f.key(asAdmin, carla.id);
  assert.equal((await f.post("/api/guild/keys", {memberId: eva.id}, asAdmin)).status, 403);
  assert.equal((await f.post("/api/guild/keys/revoke", {keyId: eva.keyId}, asAdmin)).status, 403);
  assert.equal((await f.post("/api/guild/members/revoke", {memberId: eva.id}, asAdmin)).status, 403);
  assert.equal((await f.post("/api/guild/members/role", {memberId: dani.id, role: "admin"}, asAdmin)).status, 403);
  assert.equal((await f.post("/api/guild/members/revoke", {memberId: carla.id}, asAdmin)).status, 400, "no self-revocation");
  assert.equal((await f.post("/api/guild/keys/revoke", {keyId: dani.keyId}, asAdmin)).status, 200);
  assert.equal((await f.post("/api/guild/members/revoke", {memberId: dani.id}, asAdmin)).status, 200);
  assert.equal((await f.post("/api/guild/members/role", {memberId: ana.id, role: "admin"}, owner)).status, 200);
  assert.equal((await (await f.call("/api/guild/me", {cookie: member.cookie})).json()).canAdmin, true, "the role applies on the next request");
  assert.equal((await f.post("/api/guild/members/revoke", {memberId: eva.id, purge: true}, owner)).status, 200);
  assert.equal((await f.post("/api/guild/members/revoke", {memberId: ana.id, purge: "yes"}, owner)).status, 400);
  const roles = (await (await f.call("/api/guild/members", {cookie: owner.cookie})).json()).members.map(m => [m.label, m.role, m.revoked]);
  assert.deepEqual(roles, [["Ana", "admin", false], ["Carla", "admin", false], ["Eva", "admin", true], ["Dani", "member", true]]);
});

test("guild login allows 8 attempts per 15 minutes per IP, also across Durable Object restarts", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  for (let attempt = 0; attempt < 8; attempt++) assert.equal((await f.login("gld_" + String(attempt).repeat(43), {ip: "192.0.2.1"})).response.status, 401);
  f.restart();
  const blocked = await f.login(ana.key, {ip: "192.0.2.1"});
  assert.equal(blocked.response.status, 429);
  assert.equal(blocked.response.headers.get("Set-Cookie"), null);
  assert.equal((await f.login(ana.key, {ip: "192.0.2.2"})).response.status, 200);
  f.advance(LIMITS.loginWindowMs);
  assert.equal((await f.login(ana.key, {ip: "192.0.2.1"})).response.status, 200);
  // A successful login clears the counter.
  for (let attempt = 0; attempt < 7; attempt++) await f.login("bad", {ip: "192.0.2.3"});
  assert.equal((await f.login(ana.key, {ip: "192.0.2.3"})).response.status, 200);
  assert.equal((await f.login("bad", {ip: "192.0.2.3"})).response.status, 401);
  assert.equal(f.pdb.prepare("SELECT count(*) AS n FROM especulador_rate_limits").get().n, 0, "guild logins never use Portfolio's limiter");
});

// ---------------------------------------------------------------------------------------------------------------
test("malformed uploads are rejected with 400 before anything is written", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const good = () => upload([item(2589, {days: flat(1000, T0 - 2, T0), points: [[at(T0, 8), 900, 10, 5]]})], {deposits: [[2589, 3, 50]]});
  const withMarket = change => { const body = good(); Object.assign(body.markets[0], change); return body; };
  const withItem = change => { const body = good(); Object.assign(body.markets[0].items[0], change); return body; };
  const day = (index, value) => { const days = flat(1000, T0 - 2, T0); days[0][index] = value; return withItem({days}); };
  const point = (index, value) => { const points = [[at(T0, 8), 900, 10, 5]]; points[0][index] = value; return withItem({points}); };
  const cases = [
    ["{broken", null], ["[1,2]", null], ["null", null], ['"texto"', null], [new Uint8Array([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d]), null],
    [{...good(), schema: 2}, /schema/], [{...good(), addon: undefined}, /addon/], [{...good(), addon: "0.3 beta"}, /addon/], [{...good(), markets: {}}, /markets/],
    [{...good(), markets: Array.from({length: 9}, (_, i) => ({market: `R${i}-Alliance`, items: []}))}, /markets/],
    [withMarket({market: "Sin facción"}), /market/], [withMarket({market: "Reino-Neutral"}), /market/], [withMarket({market: "Re|ino-Alliance"}), /market/],
    [withMarket({market: "x".repeat(65) + "-Horde"}), /market/], [withMarket({market: "Reino\n-Horde"}), /market/],
    [upload([], {markets: [{market: MARKET, items: []}, {market: MARKET, items: []}]}), /repetido/],
    [withMarket({cut: 10000}), /cut/], [withMarket({cut: 4.5}), /cut/], [withMarket({items: {}}), /items/],
    [withMarket({items: Array.from({length: 301}, (_, i) => item(100000 + i))}), /items/],
    [withItem({id: 0}), /id/], [withItem({id: 1.5}), /id/], [withItem({id: "2589"}), /id/], [withItem({id: 2 ** 31}), /id/],
    [withMarket({items: [item(2589), item(2589)]}), /repetido/],
    [withItem({name: "x".repeat(101)}), /name/], [withItem({name: "Lino\nmalo"}), /name/], [withItem({name: 5}), /name/],
    [withItem({cat: "arma"}), /cat/], [withItem({vendor: -1}), /vendor/], [withItem({vendor: 1e9 + 1}), /vendor/],
    [withItem({days: "x"}), /days/], [withItem({days: flat(1000, T0 - 130, T0)}), /days/], [withItem({points: undefined}), /points/],
    [withItem({days: [[T0, 1, 2, 1, 0, 0]]}), /cada día/], [day(0, T0 + 2), /d debe/], [day(0, -1), /d debe/], [day(0, 2600.5), /d debe/],
    [withItem({days: [[T0, 1000, 1000, 1000, 1, 1, "o"], [T0, 1000, 1000, 1000, 1, 1, "o"]]}), /ascendente/],
    [withItem({days: [[T0, 1000, 1000, 1000, 1, 1, "o"], [T0 - 1, 1000, 1000, 1000, 1, 1, "o"]]}), /ascendente/],
    [day(1, 0), /lo, hi y last/], [day(2, 1e9 + 1), /lo, hi y last/], [day(3, 0), /lo, hi y last/], [day(1, 5000), /mayor que hi/],
    [day(4, -1), /qty y scans/], [day(4, 1e6 + 1), /qty y scans/], [day(5, 1.5), /qty y scans/], [day(6, "x"), /src/],
    [withItem({points: Array.from({length: 131}, (_, i) => [at(T0, 0) + i * 60, 900, 1, 1])}), /points/], [point(0, at(T0 + 2)), /t debe/],
    [withItem({points: [[at(T0, 8), 900, 1, 1], [at(T0, 7), 900, 1, 1]]}), /ascendente/], [point(1, 0), /lo debe/], [point(3, -1), /qty5/],
    [withItem({points: [[at(T0, 8), 900, 1]]}), /cada punto/],
    [withMarket({deposits: {}}), /deposits/], [withMarket({deposits: [[2589, 0, 5]]}), /dur/], [withMarket({deposits: [[2589, 10, 5]]}), /dur/],
    [withMarket({deposits: [[2589, 3, -1]]}), /copper/], [withMarket({deposits: [[2589, 3, 5], [2589, 3, 6]]}), /repetido/]
  ];
  const before = dump(f.gdb);
  for (const [body, message] of cases) {
    const response = await f.sync(ana.key, body);
    const error = (await response.json()).error;
    assert.equal(response.status, 400, `${JSON.stringify(body).slice(0, 120)} -> ${error}`);
    if (message) { assert.match(error, /^Envío no válido/); assert.match(error, message); }
    assert.deepEqual(dump(f.gdb), before);
    f.advance(61000);                               // stay under the 60 attempts per hour
  }
  assert.equal(cases.length, 59);
  assert.equal((await f.sync(ana.key, good())).status, 200, "the same body without the defect is accepted");
});

test("oversized and compressed uploads are refused before reading or writing", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const before = dump(f.gdb);
  const padding = JSON.stringify(upload([])).replace("}", `,"pad":"${"x".repeat(LIMITS.body)}"}`);
  assert.ok(new TextEncoder().encode(padding).byteLength > LIMITS.body);
  const big = await f.sync(ana.key, padding);
  assert.equal(big.status, 413);
  assert.match((await big.json()).error, /2 MiB/);
  assert.equal((await f.sync(ana.key, "{}", {"Content-Length": String(LIMITS.body + 1)})).status, 413);
  assert.equal((await f.sync(ana.key, upload([]), {"Content-Encoding": "gzip"})).status, 415);
  assert.deepEqual(dump(f.gdb), before);
  const shell = JSON.stringify(upload([])).replace("}", ',"pad":""}');
  const exact = shell.replace('"pad":""', `"pad":"${"x".repeat(LIMITS.body - shell.length)}"`);
  assert.equal(new TextEncoder().encode(exact).byteLength, LIMITS.body);
  assert.equal((await f.sync(ana.key, exact)).status, 200, "a body of exactly 2 MiB is accepted");
});

test("pre-launch days, days past retention, points older than 14 days and unknown deposits are valid but not stored", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  // Ana joined at launch, so her backfill limit (30 days before her first upload) lies before the launch window.
  f.setTime(2495);
  assert.equal((await f.sync(ana.key, upload([item(2592, {days: flat(5, 2495, 2495)})]))).status, 200);
  f.setTime(T0);
  // The first upload of the day runs the daily retention, so the second one relies on the ingest filters alone.
  assert.equal((await f.sync(ana.key, upload([item(2592, {days: flat(5, T0, T0)})]))).status, 200);
  const now = f.nowSec;
  const response = await f.sync(ana.key, upload([item(2589, {days: [[2400, 5, 5, 5, 1, 1, "a"], [2489, 5, 5, 5, 1, 1, "a"], [2490, 7, 7, 7, 1, 1, "o"]],
    points: [[now - 14 * DAY - 1, 5, 1, 1], [now - 14 * DAY, 6, 1, 1], [at(T0 - 13), 7, 1, 1]]})], {deposits: [[999999, 3, 5], [2592, 3, 7], [2589, 1, 2]]}));
  assert.equal(response.status, 200);
  assert.deepEqual(f.gdb.prepare("SELECT day FROM guild_obs_day WHERE item_id=2589").all().map(r => r.day), [2490]);
  assert.deepEqual(f.gdb.prepare("SELECT t FROM guild_obs_point ORDER BY t").all().map(r => r.t), [now - 14 * DAY, at(T0 - 13)], "exactly 14 days old is kept");
  assert.deepEqual(f.gdb.prepare("SELECT item_id,duration,copper FROM guild_deposits ORDER BY item_id").all().map(r => [r.item_id, r.duration, r.copper]),
    [[2589, 1, 2], [2592, 3, 7]], "a deposit counts only for an item the market has");
});

test("each member keeps at most 200 points per item, the newest ones", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const points = (from, count) => Array.from({length: count}, (_, i) => [at(T0 - 5, 0) + (from + i) * 1800, 900 + i, 5, 1]);
  await f.sync(ana.key, upload([item(2589, {days: flat(900, T0, T0), points: points(0, 130)})]));
  await f.sync(ana.key, upload([item(2589, {points: points(130, 130)})]));
  const kept = f.gdb.prepare("SELECT count(*) AS n, min(t) AS first, max(t) AS last FROM guild_obs_point").get();
  assert.deepEqual({...kept}, {n: 200, first: at(T0 - 5, 0) + 60 * 1800, last: at(T0 - 5, 0) + 259 * 1800});
});

test("the cloud needs two members for ALTA, and the lowest point today breaks ties by the newest", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana"), bruno = await f.member(owner, "Bruno");
  assert.equal((await f.sync(ana.key, upload([item(2589, {days: flat(10000, T0 - 14, T0), points: [[at(T0, 8), 9000, 9, 2]]})]))).status, 200);
  assert.equal((await f.sync(bruno.key, upload([item(2589, {points: [[at(T0 - 1, 23), 100, 1, 1], [at(T0, 7), 9000, 8, 1], [at(T0, 10), 9000, 7, 3]]})]))).status, 200);
  const entry = (await (await f.market(owner)).json()).items[0];
  const days = buildDays(Object.fromEntries(flat(10000, T0 - 14, T0).map(([d, lo, hi, last, qty, scans, src]) => [d, [{lo, hi, qty, id: String(ana.id), last, scans, src}]])));
  assert.equal(baseline(days, T0).conf, "ALTA", "one member alone would be ALTA in the game");
  assert.deepEqual([entry.conf, entry.members, entry.confText], ["MEDIA", 1, texts.conf(baseline(days, T0, {cloud: true}))]);
  assert.deepEqual([entry.price.lo, entry.price.t, entry.price.member, entry.price.qty5], [9000, at(T0, 10), "Bruno", 3], "yesterday's 100 c does not count");
});

test("caps: 50 active members and keys, 24 uploads a day, 60 attempts an hour, 300 items and 20 markets", async t => {
  const f = fixture(t), owner = await f.owner();
  const members = [];
  for (let i = 0; i < 50; i++) members.push(await f.member(owner, `Miembro ${i + 1}`));
  const extra = await f.post("/api/guild/members", {label: "Sobrante"}, owner);
  assert.equal(extra.status, 400);
  assert.match((await extra.json()).error, /50 miembros activos/);
  const tooMany = await f.post("/api/guild/keys", {memberId: members[0].id}, owner);
  assert.equal(tooMany.status, 400);
  assert.match((await tooMany.json()).error, /50 claves activas/);
  assert.equal((await f.post("/api/guild/keys/revoke", {keyId: members[1].keyId}, owner)).status, 200);
  const replacement = await f.key(owner, members[1].id);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_keys WHERE revoked_at IS NULL").get().n, 50);

  // 24 accepted uploads a day; a retry of an accepted body is still answered as a duplicate.
  const a = members[0];
  for (let i = 0; i < 24; i++) {
    const response = await f.sync(a.key, upload([item(2589, {days: flat(1000 + i, T0, T0)})], {addon: `0.3.${i}`}));
    assert.equal(response.status, 200);
    assert.equal((await response.json()).uploadsLeft, 23 - i);
  }
  const capped = await f.sync(a.key, upload([item(2589, {days: flat(500, T0, T0)})], {addon: "0.3.99"}));
  assert.equal(capped.status, 429);
  assert.match((await capped.json()).error, /24 envíos hoy/);
  assert.equal((await (await f.sync(a.key, upload([item(2589, {days: flat(1000, T0, T0)})], {addon: "0.3.0"}))).json()).duplicate, true);
  f.setTime(T0 + 1, 9);
  assert.equal((await f.sync(a.key, upload([item(2589, {days: flat(500, T0 + 1, T0 + 1)})], {addon: "0.3.99"}))).status, 200);

  // 60 attempts per hour and member, whatever the outcome.
  const b = members[2];
  for (let i = 0; i < 60; i++) assert.equal((await f.sync(b.key, "{broken")).status, 400);
  assert.equal((await f.sync(b.key, upload([]))).status, 429);
  f.advance(3600000);
  assert.equal((await f.sync(b.key, upload([]))).status, 200);

  // 300 items per market: the 80 watchlist items always fit, the rest share 220 slots.
  const c = members[3];
  const extras = Array.from({length: 300}, (_, i) => item(200000 + i, {cat: "otro", days: flat(5, f.T, f.T)}));
  const first = await (await f.sync(c.key, upload(extras))).json();
  assert.deepEqual([first.markets[0].items, first.markets[0].skippedItems.length, first.markets[0].skippedItems[0]], [220, 80, 200220]);
  const watched = await (await f.sync(c.key, upload(WATCH_IDS.map(id => item(id, {days: flat(5, f.T, f.T)}))))).json();
  assert.deepEqual([watched.markets[0].items, watched.markets[0].skippedItems], [80, []]);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_items WHERE market=?").get(MARKET).n, LIMITS.itemsPerMarket);
  const late = await (await f.sync(replacement.key, upload([item(300001, {days: flat(5, T0 + 1, T0 + 1)})]))).json();
  assert.deepEqual(late.markets[0].skippedItems, [300001]);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_obs_day WHERE item_id=300001").get().n, 0);
  const categories = new Map(f.gdb.prepare("SELECT item_id,category,watch FROM guild_items WHERE watch=1").all().map(r => [r.item_id, r.category]));
  for (const [cat, ids] of Object.entries(WATCHLIST)) for (const id of ids) assert.equal(categories.get(id), cat, "watchlist items keep their fixed category");

  // 20 markets in all; a 21st is skipped and reported.
  const d = members[4];
  for (let batch = 0; batch < 3; batch++) {
    const markets = Array.from({length: batch < 2 ? 8 : 5}, (_, i) => ({market: `Reino ${batch * 8 + i}-Horde`, items: []}));
    await f.sync(d.key, upload([], {markets, addon: `0.3.${batch}`}));
  }
  const report = await (await f.sync(d.key, upload([], {markets: [{market: "Reino 99-Horde", items: [item(2589)]}, {market: MARKET, items: []}], addon: "1.0"}))).json();
  assert.deepEqual(report.markets.map(m => m.skipped), ["LIMITE_DE_MERCADOS", null]);
  assert.equal(f.gdb.prepare("SELECT count(DISTINCT market) AS n FROM guild_member_markets").get().n, 20);
});

test("retention keeps 180 days of days and receipts and 14 days of points", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  await f.sync(ana.key, upload([item(2589, {days: flat(1000, T0 - 20, T0), points: [[at(T0 - 13), 900, 1, 1], [at(T0, 8), 950, 1, 1]]})]));
  f.setTime(T0 + 10);
  await f.sync(ana.key, upload([item(2589, {days: flat(1100, T0 + 10, T0 + 10)})]));
  assert.deepEqual(f.gdb.prepare("SELECT t FROM guild_obs_point ORDER BY t").all().map(r => r.t), [at(T0, 8)], "points older than 14 days are gone");
  f.setTime(T0 + 175);
  await f.sync(ana.key, upload([item(2589, {days: flat(1200, T0 + 175, T0 + 175)})]));
  const daysLeft = () => f.gdb.prepare("SELECT min(day) AS lo, count(*) AS n FROM guild_obs_day").get();
  assert.deepEqual({...daysLeft()}, {lo: T0 + 175 - 180, n: 6 + 1 + 1}, "days before T-180 are deleted");
  assert.equal(f.gdb.prepare("SELECT min(day) AS lo FROM guild_day_agg").get().lo, T0 - 5);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_uploads").get().n, 3);
  f.setTime(T0 + 200);
  await f.sync(ana.key, upload([item(2589, {days: flat(1300, T0 + 200, T0 + 200)})]));
  assert.deepEqual(f.gdb.prepare("SELECT day FROM guild_obs_day ORDER BY day").all().map(r => r.day), [T0 + 175, T0 + 200]);
  assert.deepEqual(f.gdb.prepare("SELECT day FROM guild_uploads ORDER BY day").all().map(r => r.day), [T0 + 175, T0 + 200]);
  assert.equal(f.gdb.prepare("SELECT value FROM guild_meta WHERE key='retention_day'").get().value, String(T0 + 200));
});

// ---------------------------------------------------------------------------------------------------------------
/** A three-member month of a small market with a dump, a spike, a falling item, an outlier member and thin items. */
async function guildMonth(f, owner) {
  const random = rng(20261104);
  const ana = await f.member(owner, "Ana"), bruno = await f.member(owner, "Bruno"), carla = await f.member(owner, "Carla");
  const members = [ana, bruno, carla];
  const specs = [
    {id: 2589, name: "Paño de lino", cat: "tela", vendor: 10, base: d => 10000, always: [0], today: [[1, 6000, 40], [0, 9800, 300]]},
    {id: 2592, name: "Paño de lana", cat: "tela", vendor: 33, base: d => 5000, today: [[2, 8000, 12], [0, 8100, 20]]},
    {id: 2772, name: "Mena de hierro", cat: "metal", vendor: 150, base: d => Math.round(3000 * 0.97 ** (d - (T0 - 27))), today: [[0, 1800, 50]]},
    {id: 13446, name: "Poción de sanación mayor", cat: "pocion", vendor: 1000, base: d => 20000, outlier: [T0 - 20, T0 - 15], today: [[1, 19800, 30]]},
    {id: 200500, name: 'Pez "raro"; grande', cat: "otro", vendor: 0, base: d => 777, today: []},
    {id: 14047, name: "=Paño rúnico", cat: "tela", vendor: 400, base: d => 1500, from: T0 - 5, today: [[2, 1400, 5]]}
  ];
  const uploads = [[], [], []];                     // per member: list of upload bodies
  for (let m = 0; m < 3; m++) {
    for (const [from, to, imports] of [[T0 - 27, T0 - 10, true], [T0 - 14, T0, false]]) {
      const items = specs.map(spec => {
        const days = [];
        for (let d = Math.max(from, spec.from ?? 0); d <= to; d++) {
          const forced = spec.always?.includes(m) || (spec.outlier && d >= spec.outlier[0] && d <= spec.outlier[1]);
          if (!forced && random() < 0.3) continue;
          const factor = spec.outlier && m === 2 && d >= spec.outlier[0] && d <= spec.outlier[1] ? 3 : 1;
          const lo = Math.round(spec.base(d) * factor * (0.97 + random() * 0.06)), hi = lo + Math.round(random() * lo * 0.05);
          const src = imports && random() < 0.2 ? "a" : "o";
          days.push([d, lo, hi, lo + Math.round((hi - lo) * random()), Math.round(50 + random() * 400), src === "a" ? 0 : 1 + Math.floor(random() * 4), src]);
        }
        const points = imports ? [] : [[at(T0 - 1, 20), Math.round(spec.base(T0 - 1) * 0.5), 10, 5],
          ...spec.today.filter(([who]) => who === m).map(([, lo, q5], i) => [at(T0, 9 + i), lo, q5 * 3, q5])];
        return item(spec.id, {name: spec.name, cat: spec.cat, vendor: spec.vendor, days, points});
      });
      uploads[m].push(upload(items, {cut: [500, 600, null][m], deposits: [[2589, 3, [50, 70, 90][m]], [2589, 1, 10 + m], [2592, 3, 40]], addon: from < T0 - 20 ? "0.3.0" : "0.3.1"}));
    }
  }
  for (let m = 0; m < 3; m++) for (const body of uploads[m]) {
    const response = await f.sync(members[m].key, body);
    assert.equal(response.status, 200, await response.clone().text());
  }
  return {members, specs, uploads};
}

/** What especular.mjs says about the raw uploads, computed in memory without the database. */
function expectedMarket({members, specs, uploads}, T) {
  const out = new Map(), labels = new Map(members.map(m => [String(m.id), m.label]));
  for (const spec of specs) {
    const byDay = {}, merged = new Map(), points = [];
    uploads.forEach((list, m) => list.forEach(body => {
      const it = body.markets[0].items.find(x => x.id === spec.id);
      for (const [d, lo, hi, last, qty, scans, src] of it.days) {
        if (d < 2490) continue;
        (byDay[d] ??= []).push({lo, hi, qty, id: String(members[m].id), src, last, scans});
        const key = d + ":" + members[m].id;
        merged.set(key, mergeDay(merged.get(key), {d, lo, hi, last, qty, scans, src}));
      }
      for (const [t, lo, qty, qty5] of it.points) points.push({t, lo, qty, qty5, member: members[m].label});
    }));
    const days = buildDays(byDay);
    const today = points.filter(p => p.t >= DAY0 + T * DAY && p.t < DAY0 + (T + 1) * DAY).sort((x, y) => x.lo - y.lo || y.t - x.t)[0] ?? null;
    const b = baseline(days, T, {cloud: true}), a = assess(b, today ? today.lo : null, T), d = deltas(days, T);
    const range = (from, to) => {
      let lo = null, hi = null;
      for (let day = from; day <= to; day++) {
        if (!days[day]) continue;
        const kept = members.filter(m => days[day].ids.includes(String(m.id))).map(m => merged.get(day + ":" + m.id));
        lo = Math.min(lo ?? Infinity, ...kept.map(r => r.lo));
        hi = Math.max(hi ?? -Infinity, ...kept.map(r => r.hi));
      }
      return [lo, hi];
    };
    const cuts = [500, 600];
    const dep = spec.id === 2589 ? median([50, 70, 90]) : spec.id === 2592 ? 40 : null;
    const f = a.verdict === "CHOLLO" ? flip(b, null, {cutBp: median(cuts), D: dep, vendor: spec.vendor, budget: BUDGET, p: today.lo, q5: today.qty5}) : null;
    const spark = [];
    for (let day = T - 27; day <= T; day++) spark.push(days[day]?.v ?? null);
    out.set(spec.id, {days, b, a, d, today, f, spark, range: range(T - 13, T), labels});
  }
  return out;
}

test("the market summary equals especular.mjs applied to the raw uploads of three members", async t => {
  const f = fixture(t), owner = await f.owner(), month = await guildMonth(f, owner);
  const response = await f.market(owner);
  assert.equal(response.status, 200);
  const summary = await response.json(), expected = expectedMarket(month, T0);
  assert.deepEqual([summary.market, summary.T, summary.date, summary.dayOfLaunch, summary.phase, summary.banner, summary.cutBp, summary.cutMembers, summary.rules],
    [MARKET, T0, "2026-12-05", 32, "normal", null, 550, 2, "especular-v1"]);
  assert.deepEqual(summary.freshness, {lastUploadAt: new Date(f.nowSec * 1000).toISOString(), lastUploadBy: "Ana", contributors: 3, contributorsToday: 3});
  assert.deepEqual(summary.items.map(e => e.id), [2772, 2589, 2592, 14047, 13446, 200500], "category order, then id");
  for (const entry of summary.items) {
    const x = expected.get(entry.id), {b, a, d} = x;
    const fields = {n: b.n, members: b.k, N: b.N, MAD: b.MAD, sBp: b.sBp, R3: b.R3, O7: b.O7, trend: b.trend, trendBp: b.trendBp, fresh: b.fresh,
      conf: b.conf, Rs: b.Rs, Q: b.Q, status: b.status, verdict: a.verdict, guard: a.guard, wait: a.wait, dBp: a.dBp, band: a.band,
      dumpLine: a.dumpLine, spikeLine: a.spikeLine, shiftLine: a.shiftLine, d1: d.d1, d7: d.d7, confText: texts.conf(b), statusText: texts.status(a, b),
      spark: x.spark, min14: x.range[0], max14: x.range[1], today: x.days[T0] ? x.days[T0].v : null, price: x.today ? [x.today.lo, x.today.t, x.today.member] : null};
    const actual = {...Object.fromEntries(Object.keys(fields).map(k => [k, entry[k]])), today: entry.today ? entry.today.v : null,
      price: entry.price ? [entry.price.lo, entry.price.t, entry.price.member] : null};
    assert.deepEqual(actual, fields, `item ${entry.id}`);
    if (x.f) {
      const {text, cutBp, budget, who, at: when, t: time, ...rest} = entry.flip;
      assert.deepEqual(rest, x.f);
      assert.deepEqual([text, cutBp, budget, who, time], [texts.flip(x.f), 550, BUDGET, x.today.member, x.today.t]);
      assert.equal(when, new Date(x.today.t * 1000).toISOString());
    } else assert.equal(entry.flip, null);
  }
  const byId = new Map(summary.items.map(e => [e.id, e]));
  // The scenario covers what it claims to cover.
  assert.deepEqual([2589, 2592, 2772, 13446, 200500, 14047].map(id => byId.get(id).verdict), ["CHOLLO", "CARO", "INESTABLE", "NORMAL", "SIN_PRECIO", "SIN_DATOS"]);
  assert.equal(byId.get(2589).flip.accept, true);
  assert.equal(byId.get(2589).flip.D, 70, "median learned deposit for the 24 h listing");
  assert.equal(byId.get(2589).flip.who, "Bruno");
  assert.equal(byId.get(200500).flip, null);
  assert.equal(byId.get(2772).trend, "bajando");
  assert.equal(byId.get(2589).conf, "ALTA");
  assert.equal(byId.get(2589).deposit.members, 3);
  assert.deepEqual(byId.get(2592).deposit, {D: 40, duration: 3, members: 3, estimated: false});
  assert.equal(byId.get(14047).deposit.estimated, true);
  assert.deepEqual(summary.chollos, [2589]);
  const guarded = f.gdb.prepare("SELECT count(*) AS n FROM guild_day_agg a WHERE item_id=13446 AND observers=2 AND (SELECT count(*) FROM guild_obs_day o WHERE o.item_id=13446 AND o.day=a.day)=3").get().n;
  assert.equal(guarded, 6, "the outlier member was dropped on all six of its inflated days");
  const carla = month.members[2];
  for (let day = T0 - 20; day <= T0 - 15; day++) {
    const agg = f.gdb.prepare("SELECT lo,hi,members FROM guild_day_agg WHERE item_id=13446 AND day=?").get(day);
    const others = f.gdb.prepare("SELECT min(lo) AS lo, max(hi) AS hi FROM guild_obs_day WHERE item_id=13446 AND day=? AND member_id<>?").get(day, carla.id);
    assert.deepEqual([agg.lo, agg.hi, agg.members.split(",").includes(String(carla.id))], [others.lo, others.hi, false], `lo and hi of the kept members on day ${day}`);
  }
  // Balance: category index is the median Δ7d; risers and fallers need confidence ALTA or MEDIA.
  for (const category of summary.balance.categories) {
    assert.equal(category.index, median(summary.items.filter(e => e.cat === category.cat && e.d7 !== null).map(e => e.d7)));
  }
  assert.deepEqual(summary.balance.categories.map(c => c.cat), ["metal", "tela", "pocion", "otro"]);
  for (const entry of [...summary.balance.risers, ...summary.balance.fallers]) assert.ok(["ALTA", "MEDIA"].includes(entry.conf));
  assert.ok(summary.balance.fallers.some(e => e.id === 2772) || byId.get(2772).conf === "BAJA");
  // Before the guard ends the same data never yields a chollo.
  f.setTime(2512);
  const early = await (await f.market(owner)).json();
  assert.deepEqual([early.phase, early.banner, early.chollos], ["proteccion", texts.GUARD, []]);
});

test("the summary is cached for the day and rebuilt only when data or the day change", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const body = upload([item(2589, {days: flat(1000, T0 - 14, T0), points: [[at(T0, 8), 950, 10, 5]]})]);
  await f.sync(ana.key, body);
  assert.equal((await f.market(owner)).headers.get("X-Guild-Cache"), "miss");
  f.queries.length = 0;
  const hit = await f.market(owner);
  assert.equal(hit.headers.get("X-Guild-Cache"), "hit");
  assert.ok(f.queries.length <= 5, f.queries.join("\n"));
  assert.ok(!f.queries.some(q => /guild_day_agg|guild_obs_day|guild_obs_point/.test(q)), "a cached read touches no observation table");
  f.advance(3600000);
  await f.sync(ana.key, {...body, addon: "0.3.1"});
  const fresh = await f.market(owner);
  assert.equal(fresh.headers.get("X-Guild-Cache"), "hit", "an upload without new data keeps the cache");
  assert.equal((await fresh.json()).freshness.lastUploadAt, new Date(f.nowSec * 1000).toISOString(), "but freshness is live");
  await f.sync(ana.key, upload([item(2589, {days: flat(1000, T0 - 14, T0), points: [[at(T0, 8), 900, 10, 5]]})]));
  assert.equal((await f.market(owner)).headers.get("X-Guild-Cache"), "miss", "new data rebuilds it");
  f.setTime(T0 + 1, 1);
  const tomorrow = await f.market(owner);
  assert.equal(tomorrow.headers.get("X-Guild-Cache"), "miss", "a new day rebuilds it");
  assert.equal((await tomorrow.json()).T, T0 + 1);
  assert.equal((await f.call("/api/guild/market?market=" + encodeURIComponent("Otro reino-Horde"), {cookie: owner.cookie})).status, 404);
  assert.equal((await f.call("/api/guild/market", {cookie: owner.cookie})).status, 400);
  assert.equal((await f.call("/api/guild/market?market=sinfaccion", {cookie: owner.cookie})).status, 400);
});

test("before launch and during the first week the panel says honestly that there is no data", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  f.setTime(2498, 20);
  await f.sync(ana.key, upload([item(2589, {days: flat(1000, 2498, 2498)})]));
  const before = await (await f.market(owner)).json();
  assert.deepEqual([before.phase, before.dayOfLaunch], ["antes", 0]);
  assert.match(before.banner, /todavía no hay precios/);
  f.setTime(2505, 20);
  await f.sync(ana.key, upload([item(2589, {days: flat(1000, 2500, 2505), points: [[at(2505, 9), 990, 10, 5]]})]));
  const week = await (await f.market(owner)).json();
  assert.equal(week.phase, "proteccion");
  assert.deepEqual([week.items[0].n, week.items[0].verdict, week.items[0].confText, week.items[0].statusText, week.items[0].N, week.items[0].flip],
    [6, "SIN_DATOS", "Aprendiendo precios: 6 de 7 días", "Aprendiendo precios: 6 de 7 días", null, null]);
});

test("item detail: 60 days, 14 days of points, weekday pattern and the calculator defaults", async t => {
  const f = fixture(t), owner = await f.owner();
  const members = [await f.member(owner, "Ana"), await f.member(owner, "Bruno"), await f.member(owner, "Carla")];
  const T = 2580;
  f.setTime(T, 20);
  // Ten weeks: Tuesdays 20 % cheaper; three members agree. They joined ten weeks ago and uploaded as the days came
  // (a first upload only stores 30 days back).
  const daysOf = (id, d0, d1 = T) => { const out = []; for (let d = d0; d <= d1; d++) out.push([d, (d + 2) % 7 === 1 ? 8000 : 10000, (d + 2) % 7 === 1 ? 8100 : 10100, 10000, 100 + id % 7, 1, "o"]); return out; };
  f.setTime(T - 45, 20);
  for (const m of members) {
    const response = await f.sync(m.key, upload([item(2589, {days: daysOf(m.id, T - 69, T - 45)}), item(200001, {cat: "otro", days: daysOf(m.id, T - 69, T - 45)})]));
    assert.equal(response.status, 200);
  }
  f.setTime(T, 20);
  for (const m of members) {
    const response = await f.sync(m.key, upload([item(2589, {days: daysOf(m.id, T - 44), points: [[at(T - 15), 9000, 9, 9], [at(T - 2), 9500, 9, 9], [at(T, 7), 7000 + m.id, 30, 12]]}),
      item(200001, {cat: "otro", days: daysOf(m.id, T - 44)})], {deposits: [[2589, 1, 5], [2589, 2, 10], [2589, 3, 20 + m.id]]}));
    assert.equal(response.status, 200);
  }
  const get = id => f.call(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=${id}`, {cookie: owner.cookie});
  const detail = await (await get(2589)).json();
  assert.equal(detail.days.length, 60);
  assert.deepEqual([detail.days[0].d, detail.days.at(-1).d, detail.days[0].date, detail.days.at(-1).members], [T - 59, T, dateOfDay(T - 59), ["Ana", "Bruno", "Carla"]]);
  assert.deepEqual(detail.points.map(p => [p.t, p.member]), [[at(T - 2), "Ana"], [at(T - 2), "Bruno"], [at(T - 2), "Carla"], [at(T, 7), "Ana"], [at(T, 7), "Bruno"], [at(T, 7), "Carla"]]);
  assert.deepEqual([detail.price.lo, detail.price.member], [7001, "Ana"]);
  const byDay = {};
  for (const m of members) for (const [d, lo, hi, last, qty, scans, src] of daysOf(m.id, T - 69)) (byDay[d] ??= []).push({lo, hi, qty, id: String(m.id), last, scans, src});
  const days = buildDays(byDay), b = baseline(days, T, {cloud: true});
  const w = weekday(days, T, {watch: true});
  assert.equal(w.shown, true);
  assert.deepEqual(Object.fromEntries(Object.entries(detail.weekday).filter(([k]) => k in w)), w);
  // Day values are medians of {lo, hi}: 8050 on Tuesdays against 10050, so the dip is 19,9 %.
  assert.deepEqual([w.cheapest, w.e[w.cheapest]], [1, -1991]);
  assert.equal(detail.weekday.text, "Patrón probable: el martes suele estar un 19,9 % más barato que el resto de su semana.");
  assert.deepEqual(detail.baseline, b);
  assert.deepEqual(detail.assess, assess(b, 7001, T));
  assert.deepEqual(detail.deltas, deltas(days, T));
  assert.deepEqual(detail.deposits, [{duration: 1, D: 5, members: 3}, {duration: 2, D: 10, members: 3}, {duration: 3, D: 22, members: 3}]);
  const calc = flip(b, null, {cutBp: 500, D: 22, vendor: 100, budget: BUDGET, p: 7001, q5: 12});
  const {text, cutBp, budget, duration, ...rest} = detail.flip;
  assert.deepEqual(rest, calc);
  assert.deepEqual([text, cutBp, budget, duration], [texts.flip(calc), 500, BUDGET, 3]);
  const extra = await (await get(200001)).json();
  assert.equal(extra.item.watch, false);
  assert.equal(extra.weekday.shown, false, "personal extras never show weekday patterns");
  assert.match(extra.weekday.text, /lista fija/);
  assert.equal(extra.flip.reason, "SIN_UNIDADES", "no price today: the calculator has nothing to buy");
  assert.equal((await get(999)).status, 404);
  assert.equal((await get("abc")).status, 400);
  assert.equal((await get("1e3")).status, 400);
  f.setTime(T - 50, 20);
  const young = await (await get(2589)).json();
  assert.equal(young.weekday.shown, false);
  assert.match(young.weekday.text, /^Faltan \d semanas de datos|^Falta 1 semana de datos/);
});

test("CSV exports open in Spanish Excel: BOM, semicolons, decimal commas, CRLF and safe text", async t => {
  const f = fixture(t), owner = await f.owner(), month = await guildMonth(f, owner);
  const get = (query) => f.call(`/api/guild/export.csv?market=${encodeURIComponent(MARKET)}${query}`, {cookie: owner.cookie});
  const response = await get("&kind=summary");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "text/csv; charset=utf-8");
  assert.equal(response.headers.get("Content-Disposition"), 'attachment; filename="Hermandad_Grito_de_Guerra-Alliance_resumen_2026-12-05.csv"');
  assert.equal(response.headers.get("Cache-Control"), "private, no-store");
  const bytes = new Uint8Array(await response.arrayBuffer());
  assert.deepEqual([...bytes.slice(0, 3)], [0xef, 0xbb, 0xbf]);
  const text = new TextDecoder("utf-8", {ignoreBOM: true}).decode(bytes);
  assert.equal(text[0], "\uFEFF");
  assert.ok(text.endsWith("\r\n") && !text.replace(/\r\n/g, "").includes("\n"));
  const lines = text.slice(1).split("\r\n").slice(0, -1);
  assert.equal(lines[0], "Objeto;ID;Categoría;Hoy (oro);Más bajo hoy (oro);Visto por;Normal 14 d (oro);Δ1d (%);Δ7d (%);Mín 14 d (oro);Máx 14 d (oro);Oferta típica;Miembros;Días con datos;Confianza;Veredicto");
  assert.equal(lines.length, 1 + month.specs.length);
  const summary = await (await f.market(owner)).json(), lino = summary.items.find(e => e.id === 2589);
  const row = lines.find(line => line.startsWith("Paño de lino;")).split(";");
  assert.deepEqual(row, ["Paño de lino", "2589", "Tela", goldCell(lino.today.v), "0,6", "Bruno", goldCell(lino.N), pctCell(lino.d1), pctCell(lino.d7),
    goldCell(lino.min14), goldCell(lino.max14), String(lino.Q), "3", String(lino.n), "Fiable", "Chollo"]);
  assert.ok(lines.includes('"Pez ""raro""; grande";200500;Otro;;;;;;;;;;;;Aprendiendo;Sin precio hoy') ||
    lines.some(line => line.startsWith('"Pez ""raro""; grande";200500;Otro;')), "quotes and semicolons are escaped");
  assert.ok(lines.some(line => line.startsWith("'=Paño rúnico;14047;")), "a name that looks like a formula is neutralised");
  const daily = await get("&kind=daily&days=14");
  const dailyText = new TextDecoder("utf-8", {ignoreBOM: true}).decode(await daily.arrayBuffer());
  assert.equal(dailyText[0], "\uFEFF");
  const dailyLines = dailyText.slice(1).split("\r\n").slice(0, -1);
  assert.equal(dailyLines[0], "Fecha;Día;Objeto;ID;Categoría;Valor (oro);Mín (oro);Máx (oro);Cantidad;Miembros");
  const rows = f.gdb.prepare("SELECT count(*) AS n FROM guild_day_agg WHERE day>=?").get(T0 - 13).n;
  assert.equal(dailyLines.length, 1 + rows);
  const firstRow = dailyLines[1].split(";"), agg = f.gdb.prepare("SELECT * FROM guild_day_agg WHERE day=? AND item_id=2772").get(T0 - 13);
  assert.deepEqual(firstRow, [dateOfDay(T0 - 13), String(T0 - 13 - 2499 + 1), "Mena de hierro", "2772", "Metal", goldCell(agg.v), goldCell(agg.lo), goldCell(agg.hi),
    agg.qty === null ? "" : String(agg.qty), String(agg.observers)]);
  assert.match(daily.headers.get("Content-Disposition"), /_diario_2026-12-05\.csv"$/);
  for (const bad of ["&kind=xml", "&kind=daily&days=0", "&kind=daily&days=181", "&kind=daily&days=2.5"]) assert.equal((await get(bad)).status, 400, bad);
  assert.equal((await f.call("/api/guild/export.csv?market=" + encodeURIComponent("Nadie-Horde"), {cookie: owner.cookie})).status, 404);
});

test("CSV number and text cells", () => {
  assert.deepEqual([12345, 10000, 50, 0, -2500, 1000000000, null, 1.5].map(goldCell), ["1,2345", "1", "0,005", "0", "-0,25", "100000", "", ""]);
  assert.deepEqual([-1234, 50, 0, 10000, -5, null].map(pctCell), ["-12,34", "0,5", "0", "100", "-0,05", ""]);
  assert.deepEqual(["Lino", "a;b", 'di "hola"', "=SUMA(A1)", "+1", "-1", "@x", "línea\nnueva", null].map(textCell),
    ["Lino", '"a;b"', '"di ""hola"""', "'=SUMA(A1)", "'+1", "'-1", "'@x", '"línea\nnueva"', ""]);
});

test("purging a revoked member removes their observations and recomputes the market", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana"), bruno = await f.member(owner, "Bruno");
  await f.sync(ana.key, upload([item(2589, {days: flat(1000, T0 - 14, T0), points: [[at(T0, 8), 990, 1, 1]]})], {deposits: [[2589, 3, 50]]}));
  await f.sync(bruno.key, upload([item(2589, {days: flat(100000, T0 - 14, T0), points: [[at(T0, 9), 10, 1, 1]]})], {deposits: [[2589, 3, 99999]]}));
  const poisoned = await (await f.market(owner)).json();
  assert.equal(poisoned.items[0].price.member, "Bruno");
  assert.equal(f.gdb.prepare("SELECT observers FROM guild_day_agg WHERE day=?").get(T0).observers, 2, "with two members a liar is not detectable");
  const response = await f.post("/api/guild/members/revoke", {memberId: bruno.id, purge: true}, owner);
  assert.deepEqual(await response.json(), {revoked: true, memberId: bruno.id, purged: 15 + 1 + 1});
  for (const table of ["guild_obs_day", "guild_obs_point", "guild_deposits", "guild_member_markets"]) {
    assert.equal(f.gdb.prepare(`SELECT count(*) AS n FROM ${table} WHERE member_id=?`).get(bruno.id).n, 0, table);
  }
  const clean = await f.market(owner);
  assert.equal(clean.headers.get("X-Guild-Cache"), "miss");
  const entry = (await clean.json()).items[0];
  assert.deepEqual([entry.price.member, entry.N, entry.members, entry.deposit.D], ["Ana", 1100, 1, 50]);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_day_agg WHERE observers<>1 OR members<>?").get(String(ana.id)).n, 0);
});

test("the download route serves the PC uploader only to a signed-in guild member or the owner", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  assert.equal((await f.call("/api/guild/download/sincronizador")).status, 401);
  const {cookie} = await f.login(ana.key);
  for (const who of [cookie, owner.cookie]) {
    const response = await f.call("/api/guild/download/sincronizador", {cookie: who});
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Disposition"), 'attachment; filename="Sincronizador_PC.zip"');
    assert.equal(await response.text(), "asset:/downloads/Sincronizador_PC.zip");
  }
  await f.post("/api/guild/members/revoke", {memberId: ana.id}, owner);
  assert.equal((await f.call("/api/guild/download/sincronizador", {cookie})).status, 401);
});

test("Portfolio data, tables and routes are byte-for-byte unaffected by every guild operation", async t => {
  const f = fixture(t), owner = await f.owner();
  const portfolioWrite = (path, data) => f.call(path, {method: "POST", data, cookie: owner.cookie, csrf: owner.portfolioCsrf, origin: BASE});
  assert.equal((await portfolioWrite("/api/settings", {capitalCopper: 123456})).status, 200);
  assert.equal((await portfolioWrite("/api/transactions", {kind: "buy", itemId: 2589, name: "Lino", quantity: 3, unitCopper: 100})).status, 200);
  const exportText = async () => JSON.stringify({...await (await f.call("/api/export", {cookie: owner.cookie})).json(), exportedAt: null});
  const exported = await exportText();
  const tables = dump(f.pdb, {skip: []}), calls = f.calls.portfolio;
  // A full guild life cycle with the owner session.
  const month = await guildMonth(f, owner);
  const [ana, bruno] = month.members;
  const session = await f.login(ana.key);
  for (const path of ["/api/guild/me", "/api/guild/members", "/api/guild/market?market=" + encodeURIComponent(MARKET),
    `/api/guild/item?market=${encodeURIComponent(MARKET)}&id=2589`, `/api/guild/export.csv?market=${encodeURIComponent(MARKET)}&kind=daily`]) {
    assert.equal((await f.call(path, {cookie: owner.cookie})).status, 200, path);
    assert.ok([200, 403].includes((await f.call(path, {cookie: session.cookie})).status));
  }
  await f.post("/api/guild/keys/revoke", {keyId: ana.keyId}, owner);
  await f.post("/api/guild/members/revoke", {memberId: bruno.id, purge: true}, owner);
  await f.call("/api/guild/logout", {method: "POST", data: {}, cookie: owner.cookie, csrf: owner.csrf, origin: BASE});
  assert.equal(f.calls.portfolio, calls, "no guild request reached the Portfolio Durable Object");
  assert.deepEqual(dump(f.pdb, {skip: []}), tables, "every Portfolio table and row is unchanged");
  assert.equal(await exportText(), exported, "the owner export is identical apart from its own export time");
  const names = db => db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);
  assert.ok(names(f.pdb).every(name => name.startsWith("especulador_")));
  assert.ok(names(f.gdb).every(name => name.startsWith("guild_")));
  assert.equal((await f.call("/api/state", {cookie: owner.cookie})).status, 200, "the owner session still works after a guild logout");
});

// ---------------------------------------------------------------------------------------------------------------
test("validateUpload normalises a valid body and ignores unknown keys", () => {
  const body = upload([item(2589, {name: "Paño de lino", days: [[2520, 10, 20, 15, 3, 1, "a"]], points: [[at(2520), 10, 3, 1]]})], {cut: null, deposits: [[2589, 3, 7]]});
  body.extra = {future: true};
  body.markets[0].items[0].extra = 1;
  const clean = validateUpload(body, {today: 2520, nowSec: at(2520, 20)});
  assert.deepEqual(clean, {schema: 1, addon: "0.3.0", markets: [{market: MARKET, cut: null, items: [{id: 2589, name: "Paño de lino", cat: "tela", vendor: 100,
    days: [{d: 2520, lo: 10, hi: 20, last: 15, qty: 3, scans: 1, src: "a"}], points: [{t: at(2520), lo: 10, qty: 3, qty5: 1}]}], deposits: [{id: 2589, dur: 3, copper: 7}]}]});
  const noDeposits = upload([]);
  delete noDeposits.markets[0].deposits;
  delete noDeposits.markets[0].cut;
  assert.deepEqual(validateUpload(noDeposits, {today: 2520, nowSec: at(2520)}).markets[0], {market: MARKET, cut: null, items: [], deposits: []});
  assert.deepEqual(validateUpload({schema: 1, addon: "0.3.0", markets: []}, {today: 2520, nowSec: at(2520)}).markets, []);
  assert.doesNotThrow(() => validateUpload(upload([item(2589, {days: flat(1, 2521, 2521)})]), {today: 2520, nowSec: at(2520)}), "tomorrow is allowed");
  assert.throws(() => validateUpload(upload([item(2589, {days: flat(1, 2522, 2522)})]), {today: 2520, nowSec: at(2520)}), /d debe/);
});

test("ingest merges a member's days exactly like folding especular.mergeDay, and points like the addon", t => {
  const {db, ctx} = sqliteContext();
  t.after(() => db.close());
  const store = new GuildStore(ctx), random = rng(7);
  store.run("INSERT INTO guild_members(id,label,label_key,role,created_at,created_by) VALUES (1,'A','a','member',0,'owner')");
  store.run("INSERT INTO guild_keys(id,member_id,token_hash,created_at) VALUES (1,1,?,0)", "f".repeat(64));
  const T = 2600, nowSec = at(T, 23), fold = new Map(), pointFold = new Map();
  const pick = list => list[Math.floor(random() * list.length)];
  for (let round = 0; round < 300; round++) {
    const days = [...new Set(Array.from({length: 1 + Math.floor(random() * 4)}, () => T - Math.floor(random() * 6)))].sort((a, b) => a - b).map(d => {
      const lo = 100 + Math.floor(random() * 50), hi = lo + Math.floor(random() * 20);
      return {d, lo, hi, last: pick([lo, hi, lo + 1]), qty: Math.floor(random() * 5), scans: Math.floor(random() * 3), src: pick(["o", "a"])};
    });
    const points = [...new Set(Array.from({length: Math.floor(random() * 3)}, () => at(T, Math.floor(random() * 3))))].sort((a, b) => a - b)
      .map(t => ({t, lo: 50 + Math.floor(random() * 5), qty: Math.floor(random() * 4), qty5: Math.floor(random() * 4)}));
    store.transaction(() => store.ingest({schema: 1, addon: "x", markets: [{market: MARKET, cut: null, items: [{id: 2589, name: "", cat: "tela", vendor: 0, days, points}], deposits: []}]},
      {member: {memberId: 1, keyId: 1}, digest: String(round), bytes: 1, nowSec, T}));
    for (const r of days) fold.set(r.d, mergeDay(fold.get(r.d), r));
    for (const p of points) {
      const a = pointFold.get(p.t);
      pointFold.set(p.t, !a ? p : {t: p.t, lo: Math.min(a.lo, p.lo), qty: Math.max(a.qty, p.qty), qty5: p.lo < a.lo ? p.qty5 : p.lo === a.lo ? Math.max(a.qty5, p.qty5) : a.qty5});
    }
    for (const [d, expected] of fold) {
      const row = db.prepare("SELECT day AS d,lo,hi,last,qty,scans,src FROM guild_obs_day WHERE day=?").get(d);
      assert.deepEqual({...row}, expected, `round ${round}, day ${d}`);
      const agg = db.prepare("SELECT v,lo,hi FROM guild_day_agg WHERE day=?").get(d);
      assert.deepEqual([agg.v, agg.lo, agg.hi], [dayValue([expected]).v, expected.lo, expected.hi]);
    }
    for (const [time, expected] of pointFold) assert.deepEqual({...db.prepare("SELECT t,lo,qty,qty5 FROM guild_obs_point WHERE t=?").get(time)}, expected);
  }
  assert.equal(db.prepare("SELECT count(*) AS n FROM guild_obs_day").get().n, fold.size);
});

// ---------------------------------------------------------------------------------------------------------------
// Free-plan write budget, item slots and shared metadata (review CLOUD-R1, R2 and R4)
test("the guild's daily write budget refuses an upload before writing anything and resets at 00:00 UTC", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  f.env.GUILD_WRITE_ROWS_PER_DAY = "2000";
  const items = (count, from) => Array.from({length: count}, (_, i) => item(from + i, {cat: "otro", days: flat(1000 + i, f.T - 9, f.T)}));
  assert.equal((await f.sync(ana.key, upload(items(20, 300000)))).status, 200);
  const counter = () => { const rows = f.gdb.prepare("SELECT day,written FROM guild_write_budget").all(); assert.equal(rows.length, 1); return [rows[0].day, rows[0].written]; };
  const me = await (await f.call("/api/guild/me", {cookie: owner.cookie})).json();
  assert.equal(me.limits.writeRowsPerDay, 2000);
  assert.deepEqual(counter(), [Math.floor(f.nowSec / DAY), me.writesToday], "the owner sees the counter of the UTC day");
  assert.ok(me.writesToday > 440, "20 items, 20 vendor prices, 200 days and 200 aggregates, plus keys and receipts");
  const session = await f.login(ana.key);
  assert.equal("writesToday" in await (await f.call("/api/guild/me", {cookie: session.cookie})).json(), false, "only for whoever administers");

  // 40 more items of 10 days could write 1765 rows: over the budget, so nothing at all is written.
  const watched = [...DATA_TABLES, "guild_uploads", "guild_member_markets", "guild_item_vendor"];
  const before = dump(f.gdb, {only: watched});
  const refused = await f.sync(ana.key, upload(items(40, 400000)));
  assert.equal(refused.status, 429);
  assert.equal(refused.headers.get("Retry-After"), String((Math.floor(f.nowSec / DAY) + 1) * DAY - f.nowSec + 60));
  assert.equal((await refused.json()).error, "La hermandad ha agotado por hoy su cuota de escritura en el panel (2000 filas al día). " +
    "Los precios se guardarán a partir de la 01:00 (hora de España): el subidor lo volverá a intentar solo.");
  assert.deepEqual(dump(f.gdb, {only: watched}), before, "a refused upload writes nothing and does not count as an upload");
  assert.equal((await f.sync(ana.key, upload([item(2589, {days: flat(500, f.T, f.T)})]))).status, 200, "a small upload still fits");

  // The guild's day changes at 00:00 in Spain (23:00 UTC), Cloudflare's at 00:00 UTC: the budget follows Cloudflare.
  f.setTime(T0 + 1, 0, 30);
  assert.equal((await f.sync(ana.key, upload(items(40, 400000)))).status, 429);
  f.setTime(T0 + 1, 1, 30);
  const accepted = await f.sync(ana.key, upload(items(40, 400000)));
  assert.equal(accepted.status, 200, await accepted.clone().text());
  assert.equal(counter()[0], Math.floor(f.nowSec / DAY));
  assert.ok(counter()[1] < 2000);
  f.env.GUILD_WRITE_ROWS_PER_DAY = "12";
  assert.equal((await f.market(owner)).status, 200);
  assert.equal((await (await f.call("/api/guild/me", {cookie: owner.cookie})).json()).limits.writeRowsPerDay, LIMITS.writeRowsPerDay, "values below 1000 are ignored");
});

test("a rescan that only adds scans rewrites no aggregate and keeps the cached summary", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const body = scans => upload([item(2589, {days: flat(1000, T0 - 9, T0, {scans})})]);
  await f.sync(ana.key, body(2));
  assert.equal((await f.market(owner)).headers.get("X-Guild-Cache"), "miss");
  const agg = dump(f.gdb, {only: ["guild_day_agg"]});
  f.queries.length = 0;
  const report = await (await f.sync(ana.key, body(3))).json();
  assert.equal(report.markets[0].days, 10, "every member day took the higher scan count");
  assert.ok(!f.queries.some(q => /^\s*(?:INSERT|UPDATE|DELETE|REPLACE)\b[^;]*guild_day_agg/i.test(q)), "no aggregate row is written");
  assert.deepEqual(dump(f.gdb, {only: ["guild_day_agg"]}), agg);
  assert.equal((await f.market(owner)).headers.get("X-Guild-Cache"), "hit", "the summary did not change, so it stays cached");
  f.queries.length = 0;
  await f.sync(ana.key, upload([item(2589, {days: [[T0, 900, 1200, 1000, 400, 4, "o"]]})]));
  const writes = f.queries.filter(q => /guild_day_agg/.test(q) && /^\s*(?:INSERT|UPDATE|DELETE|REPLACE)\b/i.test(q));
  assert.equal(writes.length, 1, "a real change rewrites exactly the aggregate that changed");
  assert.match(writes[0], /^INSERT INTO guild_day_agg[\s\S]*ON CONFLICT\(market,item_id,day\) DO UPDATE/);
  assert.ok(!f.queries.some(q => /INSERT OR REPLACE INTO guild_(?:day_agg|obs_day|obs_point|deposits|items)/.test(q)));
  assert.equal((await f.market(owner)).headers.get("X-Guild-Cache"), "miss");
});

test("a steady upload reads only the days and points it brings, not the member's history", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana"), bruno = await f.member(owner, "Bruno");
  const ids = Array.from({length: 10}, (_, i) => 300000 + i);
  for (const who of [ana, bruno]) {
    await f.sync(who.key, upload(ids.map(id => item(id, {cat: "otro", days: flat(1000, T0 - 29, T0), points: [[at(T0, 9), 900, 5, 2]]}))));
  }
  f.reads.length = 0;
  const steady = upload(ids.map(id => item(id, {cat: "otro", days: [[T0, 990, 1250, 1000, 400, 3, "o"]], points: [[at(T0, 10), 950, 5, 2]]})));
  assert.equal((await f.sync(ana.key, steady)).status, 200);
  const rowsFrom = table => f.reads.filter(([query]) => new RegExp(`FROM ${table}\\b`).test(query)).reduce((n, [, rows]) => n + rows, 0);
  // Before: every one of Ana's 300 stored days and 10 points was read on each upload.
  assert.equal(rowsFrom("guild_obs_day"), 10 + 2 * 10, "Ana's stored day of each item, then both members' day for the aggregate");
  assert.equal(rowsFrom("guild_day_agg"), 10);
  assert.equal(rowsFrom("guild_obs_point"), 0, "the new points have no stored twin");
});

test("a late joiner stores 30 days of history, and members who were there keep theirs", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  await f.sync(ana.key, upload([item(2589, {days: flat(1000, T0, T0)})]));
  f.setTime(T0 + 40);
  const bruno = await f.member(owner, "Bruno");
  for (const who of [ana, bruno]) assert.equal((await f.sync(who.key, upload([item(2589, {days: flat(1000, T0 - 19, T0 + 40)})]))).status, 200);
  const stored = who => ({...f.gdb.prepare("SELECT min(day) AS first, count(*) AS n FROM guild_obs_day WHERE member_id=?").get(who.id)});
  assert.deepEqual(stored(bruno), {first: T0 + 11, n: 30});
  assert.deepEqual(stored(ana), {first: T0 - 19, n: 60}, "Ana's limit comes from her first upload, 40 days ago");
  f.setTime(T0 + 41);
  await f.sync(bruno.key, upload([item(2589, {days: flat(1000, T0 - 19, T0 + 41)})]));
  assert.deepEqual(stored(bruno), {first: T0 + 11, n: 31}, "the limit stays where Bruno started");
  assert.equal(f.gdb.prepare("SELECT since FROM guild_member_markets WHERE member_id=?").get(bruno.id).since, T0 + 11);
});

test("a purge or the retention frees the slots and names of items left without data", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana"), bruno = await f.member(owner, "Bruno");
  const listed = () => f.gdb.prepare("SELECT item_id,name FROM guild_items ORDER BY item_id").all().map(r => [r.item_id, r.name]);
  // An item that brings nothing storable gets no row, so it cannot hold a slot.
  const nothing = await (await f.sync(ana.key, upload(Array.from({length: 300}, (_, i) => item(500000 + i, {cat: "otro", days: [[2400, 5, 5, 5, 1, 1, "a"]]}))))).json();
  assert.deepEqual([nothing.markets[0].items, nothing.markets[0].skippedItems, listed()], [0, [], []]);
  const junk = Array.from({length: 220}, (_, i) => item(900000 + i, {name: "BASURA " + i, cat: "otro", days: flat(1000, T0, T0)}));
  assert.equal((await f.sync(ana.key, upload([item(2770, {name: "Mena de cobre", cat: "metal", days: flat(500, T0, T0)}), ...junk], {deposits: [[900001, 3, 40]]}))).status, 200);
  await f.sync(bruno.key, upload([item(900005, {name: "Compartido", cat: "otro", days: flat(900, T0, T0)})]));
  const full = await (await f.sync(bruno.key, upload([item(12345, {name: "Mi extra", cat: "otro", days: flat(700, T0, T0)})]))).json();
  assert.deepEqual(full.markets[0].skippedItems, [12345], "Ana's 220 extras fill every free slot");

  const purge = await f.post("/api/guild/members/revoke", {memberId: ana.id, purge: true}, owner);
  assert.deepEqual(await purge.json(), {revoked: true, memberId: ana.id, purged: 221 + 1});
  assert.deepEqual(listed(), [[900005, ""]], "only the item Bruno also has stays, without the name Ana gave it");
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_deposits").get().n, 0);
  assert.deepEqual(f.gdb.prepare("SELECT DISTINCT member_id FROM guild_item_vendor").all().map(r => r.member_id), [bruno.id]);
  const again = await (await f.sync(bruno.key, upload([item(12345, {name: "Mi extra", cat: "otro", days: flat(700, T0, T0)}),
    item(900005, {name: "Compartido", cat: "otro", days: flat(900, T0, T0)})]))).json();
  assert.deepEqual(again.markets[0].skippedItems, [], "the slots are free again");
  assert.deepEqual(listed(), [[12345, "Mi extra"], [900005, "Compartido"]], "the next upload names the item again");
  assert.deepEqual((await (await f.market(owner)).json()).items.map(e => e.name), ["Mi extra", "Compartido"]);
  for (const kind of ["summary", "daily"]) {
    assert.doesNotMatch(await (await f.call(`/api/guild/export.csv?market=${encodeURIComponent(MARKET)}&kind=${kind}`, {cookie: owner.cookie})).text(), /BASURA/);
  }
  // 200 days later the retention removed every day of both items, and the items go with them.
  f.setTime(T0 + 200);
  await f.sync(bruno.key, upload([item(12346, {name: "Nuevo", cat: "otro", days: flat(700, T0 + 200, T0 + 200)})]));
  assert.deepEqual(listed(), [[12346, "Nuevo"]]);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_item_vendor WHERE item_id<>12346").get().n, 0);
});

test("one member cannot rename an item, inflate its vendor price or set the cut for everyone", async t => {
  const f = fixture(t), owner = await f.owner();
  const [ana, bruno, carla, dani] = [await f.member(owner, "Ana"), await f.member(owner, "Bruno"), await f.member(owner, "Carla"), await f.member(owner, "Dani")];
  const copper = (who, extra = {}) => f.sync(who.key, upload([item(2770, {name: "Mena de cobre", cat: "metal", vendor: 5, days: flat(10000, T0 - 14, T0),
    points: [[at(T0, 9), 5000, 400, 300]], ...extra})], {cut: null}));
  for (const who of [ana, bruno, carla]) assert.equal((await copper(who)).status, 200);
  const row = () => ({...f.gdb.prepare("SELECT name,category,vendor,name_by FROM guild_items WHERE item_id=2770").get()});
  const entry = async () => (await (await f.market(owner)).json()).items.find(e => e.id === 2770);
  assert.deepEqual(row(), {name: "Mena de cobre", category: "metal", vendor: 5, name_by: ana.id});
  const honest = await entry();
  assert.deepEqual([honest.verdict, honest.flip.accept, honest.flip.D, honest.deposit.estimated], ["CHOLLO", true, 3, true]);

  // Dani renames the item and claims a vendor price that would make the estimated deposit eat every margin.
  assert.equal((await copper(dani, {name: "¡COMPRA YA! cobre a 1c", cat: "tela", vendor: 1e9})).status, 200);
  assert.deepEqual(row(), {name: "Mena de cobre", category: "metal", vendor: 5, name_by: ana.id});
  assert.equal(f.gdb.prepare("SELECT vendor FROM guild_item_vendor WHERE member_id=? AND item_id=2770").get(dani.id).vendor, 1e9, "kept, but outvoted");
  const attacked = await entry();
  assert.deepEqual([attacked.name, attacked.vendor, attacked.flip.accept, attacked.flip.D], ["Mena de cobre", 5, true, 3], "the chollo is still shown");
  // A client in English sends another name: nothing changes, so the cached summary survives.
  const english = await (await copper(bruno, {name: "Copper Ore"})).json();
  assert.equal(english.rowsChanged, 0);
  assert.equal((await f.market(owner)).headers.get("X-Guild-Cache"), "hit");
  // With two members the lower vendor price wins.
  for (const [who, vendor] of [[ana, 25], [dani, 1e9]]) await f.sync(who.key, upload([item(2771, {cat: "metal", vendor, days: flat(500, T0, T0)})], {cut: null}));
  assert.equal(f.gdb.prepare("SELECT vendor FROM guild_items WHERE item_id=2771").get().vendor, 25);
  // An extra leaves "otro" for the first real category, and keeps it.
  for (const [who, cat] of [[ana, "otro"], [bruno, "tela"], [dani, "metal"]]) await f.sync(who.key, upload([item(300100, {cat, days: flat(500, T0, T0)})], {cut: null}));
  assert.equal(f.gdb.prepare("SELECT category FROM guild_items WHERE item_id=300100").get().category, "tela");

  // The cut: an implausible value or a single member does not move it; two plausible ones do.
  const cut = async () => { const s = await (await f.market(owner)).json(); return [s.cutBp, s.cutMembers]; };
  await f.sync(dani.key, upload([], {cut: 9999}));
  assert.deepEqual(await cut(), [500, 0]);
  await f.sync(carla.key, upload([], {cut: 1500}));
  assert.deepEqual(await cut(), [500, 0], "one member alone");
  await f.sync(bruno.key, upload([], {cut: 500}));
  assert.deepEqual(await cut(), [1000, 2], "the median of Bruno's and Carla's cuts; Dani's 99,99 % is ignored");

  // Purging the member who named an item clears the name, and the next upload names it again.
  await f.post("/api/guild/members/revoke", {memberId: ana.id, purge: true}, owner);
  assert.equal(row().name, "");
  await copper(bruno, {name: "Copper Ore", points: [[at(T0, 11), 5100, 400, 300]]});
  assert.deepEqual([row().name, row().name_by], ["Copper Ore", bruno.id]);
});

test("the daily retention commits on its own, so a refused upload neither undoes nor repeats it", async t => {
  const f = fixture(t), owner = await f.owner(), ana = await f.member(owner, "Ana");
  const ids = Array.from({length: 30}, (_, i) => 300000 + i);
  const points = Array.from({length: 40}, (_, i) => [at(T0 - 1, 0) + i * 1800, 900, 5, 2]);
  assert.equal((await f.sync(ana.key, upload(ids.map(id => item(id, {cat: "otro", days: flat(1000, T0, T0), points}))))).status, 200);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_obs_point").get().n, 1200);
  // Twenty days later those points are past the 14 days: the retention deletes 1200 rows, which leaves too little
  // of a 2000-row budget for 20 new items with 10 days each (885 rows at most).
  f.env.GUILD_WRITE_ROWS_PER_DAY = "2000";
  f.setTime(T0 + 20);
  const fresh = upload(Array.from({length: 20}, (_, i) => item(400000 + i, {cat: "otro", days: flat(1000, T0 + 11, T0 + 20)})));
  const used = () => f.gdb.prepare("SELECT written FROM guild_write_budget WHERE day=?").get(Math.floor(f.nowSec / DAY)).written;
  assert.equal((await f.sync(ana.key, fresh)).status, 429);
  assert.equal(f.gdb.prepare("SELECT count(*) AS n FROM guild_obs_point").get().n, 0, "the retention stayed done");
  assert.equal(f.gdb.prepare("SELECT value FROM guild_meta WHERE key='retention_day'").get().value, String(T0 + 20));
  const afterFirst = used();
  assert.ok(afterFirst > 1200, "the refused attempt counted its retention");
  f.queries.length = 0;
  f.advance(60000);
  assert.equal((await f.sync(ana.key, fresh)).status, 429);
  assert.ok(!f.queries.some(q => /^DELETE FROM guild_obs_point WHERE t</.test(q)), "a retry does not run the retention again");
  assert.ok(used() - afterFirst <= 3, "a refused retry costs its rate limit and the counter, nothing more");
  f.setTime(T0 + 21, 1, 30);
  const next = await f.sync(ana.key, fresh);
  assert.equal(next.status, 200, await next.clone().text());
  assert.ok(used() < 1200);
});

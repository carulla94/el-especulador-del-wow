/** Relay (upload schema 2, relay-v1): observer slots, the binding of an uploader's own characters, per-person
 * aggregates, validation, caps, the write budget share, purge and retention, the panel strings, and the proof that a
 * GuildMarket database written by the previous code (f007cb8, test/fixtures/relay/guild-v1.mjs) keeps every row when
 * this code opens it. test/fixtures/relay holds byte copies of the shared relay fixtures (checked below). */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import crypto from "node:crypto";
import {DatabaseSync} from "node:sqlite";
import worker, {Portfolio} from "../src/worker.mjs";
import {GuildMarket, GuildStore, validateUpload, LIMITS, RELAYED_SLOT_BASE, WATCHLIST} from "../src/guild.mjs";
import * as V1 from "./fixtures/relay/guild-v1.mjs";
import {DAY0, dayIndex, mergeDay, dayValue} from "../src/especular.mjs";
import * as E from "../src/especular.mjs";
import * as H from "../public/hermandad.js";

H.setEspecular(E);
const DAY = 86400;
const raw = name => fs.readFileSync(new URL("./fixtures/relay/" + name, import.meta.url));
const fixture = name => JSON.parse(raw(name).toString("utf8"));
const C = fixture("constants.json"), X = fixture("server-expected.json");
const U0 = fixture("upload-schema1.json"), U1 = fixture("upload-schema2.json"), U2 = fixture("upload-schema2-second.json");
const U1H = fixture("upload-schema2-from-hist1.json");
const MARKET = C.market, HORDE = C.marketHorde;
const NAMES = ["Jusep", "Borja", "Ána", "Борис", "Los Errantes"];
const copy = value => JSON.parse(JSON.stringify(value));
const DATA = ["guild_obs_day", "guild_obs_point", "guild_deposits", "guild_day_agg", "guild_items", "guild_item_vendor", "guild_observers", "guild_observer_markets"];

/** Cloudflare's SqlStorage on node:sqlite (as in guild.test.mjs): rowsWritten counts table rows only. */
function sqliteContext() {
  const db = new DatabaseSync(":memory:"), queries = [];
  const sql = {exec(query, ...bindings) {
    queries.push(query);
    const statement = db.prepare(query), write = /^\s*(?:INSERT|UPDATE|DELETE|REPLACE)\b/i.test(query);
    let rows = [], rowsWritten = 0;
    if (statement.columns().length) { rows = statement.all(...bindings); if (write) rowsWritten = rows.length; }
    else { const result = statement.run(...bindings); if (write) rowsWritten = Number(result.changes); }
    return {rowsWritten, toArray: () => rows, [Symbol.iterator]: () => rows[Symbol.iterator]()};
  }};
  return {db, queries, ctx: {storage: {sql, transactionSync(callback) {
    db.exec("BEGIN IMMEDIATE");
    try { const result = callback(); db.exec("COMMIT"); return result; } catch (error) { db.exec("ROLLBACK"); throw error; }
  }}}};
}
function dump(db, {only = null, skip = ["guild_rate_limits", "guild_write_budget"]} = {}) {
  const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(r => r.name)
    .filter(name => (only ? only.includes(name) : true) && !skip.includes(name));
  return Object.fromEntries(names.map(name => {
    const columns = db.prepare(`PRAGMA table_info("${name}")`).all().map((_, i) => i + 1).join(",");
    return [name, db.prepare(`SELECT * FROM "${name}" ORDER BY ${columns}`).all().map(r => ({...r}))];
  }));
}
const tokenHash = id => crypto.createHash("sha256").update("relay-test-key-" + id).digest("hex");
/** Members 1..n with one key each, written as the admin routes write them. */
function seed(db, n) {
  for (let id = 1; id <= n; id++) {
    db.prepare("INSERT INTO guild_members(id,label,label_key,role,created_at,created_by) VALUES (?,?,?,'member',0,'owner')").run(id, `Cuenta ${id}`, `cuenta ${id}`);
    db.prepare("INSERT INTO guild_keys(id,member_id,token_hash,created_at) VALUES (?,?,?,0)").run(id, id, tokenHash(id));
  }
}
/** A GuildMarket (of this code or of f007cb8) on a database, driven with internal requests like the worker sends. */
function room(base = sqliteContext(), {Market = GuildMarket, env = {}} = {}) {
  const market = new Market(base.ctx, env);
  let clock = C.now * 1000;
  market.now = () => clock;
  const send = (path, init) => market.fetch(new Request("https://guild.internal" + path, init));
  return {...base, market, env,
    at(seconds) { clock = seconds * 1000; return this; },
    get nowSec() { return Math.floor(clock / 1000); },
    async sync(member, body) {
      const response = await send("/api/guild/sync", {method: "POST", headers: {"Content-Type": "application/json", "X-Member-Hash": tokenHash(member)},
        body: typeof body === "string" ? body : JSON.stringify(body)});
      return {status: response.status, body: await response.json()};
    },
    async get(path) {
      const response = await send(path, {headers: {"X-Guild-Actor": JSON.stringify({kind: "owner"})}});
      const bytes = new Uint8Array(await response.arrayBuffer());
      const text = new TextDecoder("utf-8", {ignoreBOM: true}).decode(bytes);
      return {status: response.status, cache: response.headers.get("X-Guild-Cache"), body: response.headers.get("Content-Type")?.includes("json") ? JSON.parse(text) : text};
    },
    async post(path, data) {
      const response = await send(path, {method: "POST", headers: {"Content-Type": "application/json", "X-Guild-Actor": JSON.stringify({kind: "owner"})}, body: JSON.stringify(data)});
      return {status: response.status, body: await response.json()};
    },
    summary(name = MARKET) { return this.get("/api/guild/market?market=" + encodeURIComponent(name)); }
  };
}
/** guild_day_agg as server-expected.json writes it. */
function aggregates(db) {
  const out = {};
  for (const r of db.prepare("SELECT market,item_id,day,v,lo,hi,qty,observers,members FROM guild_day_agg ORDER BY market,item_id,day").all()) {
    ((out[r.market] ??= {})[r.item_id] ??= {})[r.day] = {v: r.v, obs: r.observers, lo: r.lo, hi: r.hi, qty: r.qty, persons: r.members.split(",").map(Number)};
  }
  return out;
}
const bindings = db => Object.fromEntries(db.prepare("SELECT hash,slot,member_id FROM guild_observers ORDER BY hash").all().map(r => [r.hash, {slot: r.slot, member: r.member_id}]));
/** Every aggregate recomputed from the stored rows with especular alone: slots grouped by person (a relayed slot bound
 * to a member is that member), merged with mergeDay, persons in numeric order. */
function expectedAggregates(db) {
  const bound = new Map(db.prepare("SELECT slot,member_id FROM guild_observers WHERE slot>=? AND member_id IS NOT NULL").all(RELAYED_SLOT_BASE).map(r => [r.slot, r.member_id]));
  const groups = new Map();
  for (const r of db.prepare("SELECT * FROM guild_obs_day").all()) {
    const person = r.member_id < RELAYED_SLOT_BASE ? r.member_id : bound.get(r.member_id) ?? r.member_id, key = `${r.market}|${r.item_id}|${r.day}`;
    if (!groups.has(key)) groups.set(key, new Map());
    const people = groups.get(key);
    people.set(person, mergeDay(people.get(person), {d: r.day, lo: r.lo, hi: r.hi, last: r.last, qty: r.qty, scans: r.scans, src: r.src}));
  }
  const out = {};
  for (const [key, people] of groups) {
    const [market, item, d] = key.split("|"), list = [...people].sort((a, b) => a[0] - b[0]);
    const value = dayValue(list.map(([p, r]) => ({lo: r.lo, hi: r.hi, qty: r.qty, id: String(p)})));
    const kept = list.filter(([p]) => value.ids.includes(String(p))).map(([, r]) => r);
    ((out[market] ??= {})[item] ??= {})[d] = {v: value.v, obs: value.obs, lo: Math.min(...kept.map(r => r.lo)), hi: Math.max(...kept.map(r => r.hi)),
      qty: value.qty ?? null, persons: value.ids.map(Number)};
  }
  return out;
}
async function checkStep(r, step, now) {
  assert.deepEqual(bindings(r.db), step.bindings, "observer codes and their slots");
  assert.deepEqual(aggregates(r.db), step.aggregates, "day aggregates per person");
  assert.deepEqual(aggregates(r.db), expectedAggregates(r.db), "the aggregates follow from the stored rows");
  for (const name of [MARKET, HORDE]) {
    const summary = await r.summary(name);
    assert.equal(summary.status, 200);
    const {observers, contributors} = summary.body.freshness;
    assert.deepEqual({observers, contributors}, step.freshness[name], name);
    if (name === MARKET) assert.deepEqual(Object.fromEntries(summary.body.items.map(e => [e.id, e.members])), step.membersToday, "members = persons in the baseline");
  }
  return (await r.summary()).body;
}

// ---------------------------------------------------------------------------------------------------------------
test("the relay fixtures are byte copies of the shared ones and the v1 module is f007cb8's guild.mjs", () => {
  const sha = bytes => crypto.createHash("sha256").update(bytes).digest("hex");
  const expected = {
    "obs-hash.json": "c83a2641974175fe4f15cb6833e887e714a6f409fd4a7e28fc13a409cb6d425f",
    "upload-schema1.json": "206274131bd28925c74fff90edabbe0ae5dfaf1a3e48f7361a29dba26802c131",
    "upload-schema2.json": "b006c419d3e5fe9790bf8cd1c878d18d78e2fb5f74fe50e503c69e9e58eb1b8c",
    "upload-schema2-from-hist1.json": "4bf06a62b459fdafc9f6c223ae6f166f0cbe5f07a03c300f49b35d69e9a26515",
    "upload-schema2-second.json": "179b31d29de299d8ded833accc7e774a2a1f45398cb89ee5c0c5979fafb38026",
    "server-expected.json": "7cf2484d7f20a0942dcfe42824db723d89ed470b83305d21554bd43a7312f149",
    "constants.json": "293b0f52e6f382510ea900181b1fcfe6234148ba64c65f70912dee0dfbc296b9"};
  for (const [name, hash] of Object.entries(expected)) assert.equal(sha(raw(name)), hash, name);
  // Only the import path differs from `git show f007cb8:src/guild.mjs`.
  const v1 = raw("guild-v1.mjs").toString("utf8").replace('from "../../../src/especular.mjs";', 'from "./especular.mjs";');
  assert.equal(sha(Buffer.from(v1, "utf8")), "4e2af33753800a7a2dfb0d7a23cfde62376e8df5c7b0095a0df10f172d3aa703");
  assert.equal(X.firstOnlyEqualsAfterFirst, true);
});

test("observer codes: FNV-1a 32 of the canonical text, as the addon computes them (the server never does)", () => {
  const fnv = text => {
    let h = 0x811c9dc5;
    for (const byte of new TextEncoder().encode(text)) { h ^= byte; h = Math.imul(h, 0x01000193) >>> 0; }
    return h.toString(16).padStart(8, "0");
  };
  const vectors = fixture("obs-hash.json");
  assert.ok(vectors.vectors.length >= 18);
  for (const v of vectors.vectors) assert.equal(fnv(v.canonical), v.hash, v.note ?? v.canonical);
  for (const v of vectors.fnv1a32_plain) assert.equal(fnv(v.input), v.hash, v.input);
  for (const v of vectors.market_tags) assert.equal(fnv(v.market), v.tag, v.market);
  assert.equal(fnv(C.market), C.marketTag);
  for (const [name, hash] of Object.entries(C.hashes)) assert.ok(vectors.vectors.some(v => v.hash === hash && v.sender.startsWith(name + "-")), name);
});

// ---------------------------------------------------------------------------------------------------------------
test("a database written by f007cb8 keeps every row when this code opens it, and then follows server-expected.json", async t => {
  const base = sqliteContext();
  t.after(() => base.db.close());
  // 1. The 0.3 code: its tables, the schema-1 upload of account A (member 1) and its summary, cached as resumen-1.
  const old = room(base, {Market: V1.GuildMarket}).at(C.nowLegacy);
  seed(base.db, 2);
  const legacy = await old.sync(1, U0);
  assert.equal(legacy.status, 200, JSON.stringify(legacy.body));
  const oldSummaries = {};
  for (const name of [MARKET, HORDE]) oldSummaries[name] = (await old.summary(name)).body;
  const oldItem = (await old.get(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=2772`)).body;
  const before = dump(base.db, {skip: []});
  assert.equal(before.guild_meta.find(r => r.key === "schema").value, "1");
  assert.equal(before.guild_summary_cache.length, 2);

  // 2. This code opens it: two NULL columns and the schema marker, nothing else; a second opening changes nothing.
  new GuildStore(base.ctx);
  const after = dump(base.db, {skip: []});
  for (const [name, rows] of Object.entries(before)) {
    if (name === "guild_obs_day" || name === "guild_obs_point") assert.deepEqual(after[name], rows.map(r => ({...r, uploaded_by: null})), name);
    else if (name === "guild_meta") assert.deepEqual(after[name], rows.map(r => r.key === "schema" ? {...r, value: "2"} : r), name);
    else assert.deepEqual(after[name], rows, name);
  }
  assert.deepEqual(Object.keys(after).filter(name => !(name in before)).sort(), ["guild_observer_markets", "guild_observers"]);
  assert.deepEqual([after.guild_observers, after.guild_observer_markets], [[], []]);
  new GuildStore(base.ctx);
  assert.deepEqual(dump(base.db, {skip: []}), after, "opening the database again changes nothing");

  // 3. The same day with this code: the cached resumen-1 is ignored, and everything but the documented new fields
  // (freshness.observers/observersToday, price.mate) is what the 0.3 code served.
  const r = room(base).at(C.nowLegacy);
  for (const name of [MARKET, HORDE]) {
    const summary = await r.summary(name);
    assert.equal(summary.cache, "miss", "a new summary version is computed once");
    const {observers, observersToday, ...freshness} = summary.body.freshness;
    assert.deepEqual(freshness, oldSummaries[name].freshness);
    assert.deepEqual([observers, observersToday], [1, 1], "the uploader, who uploaded today");
    const items = summary.body.items.map(e => e.price ? {...e, price: (({mate, ...rest}) => { assert.equal(mate, false); return rest; })(e.price)} : e);
    assert.deepEqual({...summary.body, freshness: oldSummaries[name].freshness, items}, oldSummaries[name], name);
  }
  const item = (await r.get(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=2772`)).body;
  assert.deepEqual({...item, points: item.points.map(({mate, ...rest}) => rest)}, oldItem, "item detail: same, points gain mate: false");
  await checkStep(r, X.afterLegacy, C.nowLegacy);
  assert.equal(H.freshnessLine((await r.summary()).body.freshness, 1, C.nowLegacy * 1000).split(" · ")[0], X.freshnessText.afterLegacy);

  // 4. Account A's first schema-2 upload binds its codes to member 1, where its legacy rows already are: nothing moves.
  const legacyRows = base.db.prepare("SELECT * FROM guild_obs_day WHERE member_id=1").all().map(row => ({...row}));
  const first = await r.at(C.now).sync(1, U1);
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.deepEqual(first.body.markets.map(m => [m.market, m.observers, m.skippedObservers, m.selfConflicts]),
    [[MARKET, 3, [], []], [HORDE, 0, [], []]]);
  for (const row of legacyRows) {
    const now = base.db.prepare("SELECT * FROM guild_obs_day WHERE market=? AND member_id=1 AND item_id=? AND day=?").get(row.market, row.item_id, row.day);
    assert.deepEqual({...now}, row, `legacy row ${row.market} ${row.item_id} ${row.day} untouched`);
  }
  let summary = await checkStep(r, X.afterFirst, C.now);
  assert.equal(H.freshnessLine(summary.freshness, summary.dayOfLaunch, C.now * 1000).split(" · ")[0], X.freshnessText.afterFirst);

  // 5. Account B (member 2): Borja's code, relayed by A, is B's own character; B relays A's characters and two mates.
  const second = await r.at(C.nowSecond).sync(2, U2);
  assert.equal(second.status, 200, JSON.stringify(second.body));
  assert.deepEqual(second.body.markets.map(m => [m.observers, m.skippedObservers, m.selfConflicts]), [[4, [], []]]);
  summary = await checkStep(r, X.afterSecond, C.nowSecond);
  assert.equal(H.freshnessLine(summary.freshness, summary.dayOfLaunch, C.nowSecond * 1000).split(" · ")[0], X.freshnessText.afterSecond);
  assert.equal(base.db.prepare("SELECT count(*) AS n FROM guild_obs_day WHERE member_id=? AND uploaded_by=2").get(RELAYED_SLOT_BASE + 1).n, 0,
    "B's copy of Ána's scans was identical to A's: nothing written");
  assert.equal(base.db.prepare("SELECT count(*) AS n FROM guild_obs_day WHERE member_id=1 AND uploaded_by=2").get().n, 0,
    "B's copies of A's own characters merge into A's slot and change nothing");

  // 6. Both uploads again (new files, same data): no data row changes.
  const data = dump(base.db, {only: DATA});
  r.at(C.nowSecond + 60);
  for (const [member, body] of [[1, U1], [2, U2]]) {
    const again = await r.sync(member, JSON.stringify(body, null, 1));
    assert.deepEqual([again.status, again.body.duplicate, again.body.rowsChanged], [200, false, 0]);
  }
  assert.deepEqual(dump(base.db, {only: DATA}), data, "the same observations twice write nothing");
  assert.deepEqual(aggregates(base.db), X.afterSecond.aggregates);
});

test("a fresh database that only receives the first schema-2 upload ends exactly as afterFirst", async t => {
  const r = room().at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 1);
  assert.equal((await r.sync(1, U1)).status, 200);
  assert.deepEqual(bindings(r.db), X.afterFirst.bindings);
  assert.deepEqual(aggregates(r.db), X.afterFirst.aggregates);
});

test("schema 1 is still accepted: the same rows and the same answer as the 0.3 code; schema 2 without codes stores the same", async t => {
  const oldRoom = room(sqliteContext(), {Market: V1.GuildMarket}).at(C.nowLegacy), newRoom = room().at(C.nowLegacy), relayRoom = room().at(C.nowLegacy);
  t.after(() => { oldRoom.db.close(); newRoom.db.close(); relayRoom.db.close(); });
  for (const x of [oldRoom, newRoom, relayRoom]) seed(x.db, 1);
  const a = await oldRoom.sync(1, U0), b = await newRoom.sync(1, U0), c = await relayRoom.sync(1, U1H);
  assert.deepEqual(b, a, "a schema-1 upload gets the 0.3 answer, without the relay fields");
  assert.equal(c.status, 200);
  assert.deepEqual(c.body.markets.map(({observers, skippedObservers, selfConflicts, ...rest}) => rest), a.body.markets);
  assert.equal(c.body.rowsChanged, a.body.rowsChanged);
  const tables = ["guild_obs_day", "guild_obs_point", "guild_deposits", "guild_day_agg", "guild_items", "guild_item_vendor", "guild_member_markets"];
  const oldData = dump(oldRoom.db, {only: tables});
  oldData.guild_obs_day = oldData.guild_obs_day.map(r => ({...r, uploaded_by: 1}));
  oldData.guild_obs_point = oldData.guild_obs_point.map(r => ({...r, uploaded_by: 1}));
  assert.deepEqual(dump(newRoom.db, {only: tables}), oldData, "same rows; this code also records who uploaded them");
  assert.deepEqual(dump(relayRoom.db, {only: tables}), oldData, "the 0.4 uploader on a schema-1 history sends the same observations");
  assert.deepEqual(dump(relayRoom.db, {only: ["guild_observers", "guild_observer_markets"]}), {guild_observers: [], guild_observer_markets: []});
});

// ---------------------------------------------------------------------------------------------------------------
test("validateUpload: schema 2 is normalised with the self observer first and the mates by code", () => {
  const options = {today: C.T, nowSec: C.now};
  const clean = validateUpload(U1, options);
  assert.equal(clean.schema, 2);
  assert.deepEqual(clean.markets[0].observers.map(o => [o.obs, o.self, o.aliases]),
    [["65c8ae44", true, ["27e0ee58"]], ["47da174e", false, []], ["556e986d", false, []], ["631b8919", false, []]]);
  assert.deepEqual(clean.markets[0].items[0], {id: 2770, name: "Mineral de cobre", cat: "metal", vendor: 5});
  assert.deepEqual(clean.markets[0].observers[1].items[0].days[0], {d: 2527, lo: 41, hi: 41, last: 41, qty: 800, scans: 1, src: "o"});
  assert.deepEqual(clean.markets[0].observers[1].items[0].points[0], {t: 1796241600, lo: 41, qty: 800, qty5: 150});
  assert.deepEqual(clean.markets[1].observers, [{obs: null, self: true, aliases: [], items: [{id: 2589,
    days: [{d: 2528, lo: 30, hi: 30, last: 30, qty: 2000, scans: 1, src: "o"}, {d: 2530, lo: 28, hi: 28, last: 28, qty: 2100, scans: 1, src: "o"}],
    points: [{t: 1796284800, lo: 30, qty: 2000, qty5: 400}, {t: 1796457600, lo: 28, qty: 2100, qty5: 450}]}]}]);
  const shuffled = copy(U1);
  shuffled.markets[0].observers.reverse();
  shuffled.markets[0].observers[0].future = {x: 1};
  shuffled.markets[0].extra = true;
  delete shuffled.markets[1].observers[0].aliases;
  assert.deepEqual(validateUpload(shuffled, options), clean, "order does not matter, unknown keys are ignored, aliases may be left out");
  assert.deepEqual(validateUpload({schema: 2, addon: "0.4.0", markets: [{market: MARKET, cut: null, items: [], observers: []}]}, options).markets,
    [{market: MARKET, cut: null, items: [], deposits: [], observers: []}]);
});

test("validateUpload: every malformed schema-2 body is refused with a Spanish message naming the place", async t => {
  const options = {today: C.T, nowSec: C.now};
  const change = edit => { const body = copy(U1); edit(body.markets[0], body); return body; };
  const self = m => m.observers[0], mate = m => m.observers[1];
  const many = (n, make) => Array.from({length: n}, (_, i) => make(i));
  const code = i => (0x10000000 + i).toString(16);
  const cases = [
    [change((m, b) => { b.schema = 3; }), /schema debe ser 1 o 2/],
    [change(m => { delete m.observers; }), /observers debe ser una lista de 61 observadores como máximo \(schema 2\)/],
    [change(m => { m.observers = [...m.observers, ...many(58, i => ({obs: code(i), self: false, items: []}))]; }), /observers debe ser una lista de 61/],
    [change(m => { m.observers[1] = "x"; }), /observador n\.º 2\): se esperaba un objeto/],
    [change(m => { mate(m).self = "no"; }), /self debe ser true o false/],
    [change(m => { mate(m).self = true; }), /solo puede haber un observador con self: true/],
    [change(m => { mate(m).obs = "47DA174E"; }), /^Envío no válido \(mercado GritodeGuerra-Alliance, observador n\.º 2\): obs debe ser un código de 8 cifras hexadecimales en minúsculas\.$/],
    [change(m => { mate(m).obs = null; }), /obs debe ser un código de 8 cifras/],
    [change(m => { mate(m).obs = "47da174"; }), /obs debe ser un código de 8 cifras/],
    [change(m => { self(m).obs = 5; }), /obs debe ser un código de 8 cifras hexadecimales en minúsculas o null/],
    [change(m => { mate(m).aliases = []; }), /aliases solo puede ir en el observador con self: true/],
    [change(m => { self(m).aliases = many(10, code); }), /aliases debe ser una lista de 9 códigos/],
    [change(m => { self(m).aliases = ["XYZ"]; }), /cada alias debe ser un código/],
    [change(m => { self(m).aliases = ["27e0ee58", "27e0ee58"]; }), /no pueden repetirse/],
    [change(m => { self(m).aliases = ["65c8ae44"]; }), /no pueden repetirse/],
    [change(m => { self(m).obs = null; }), /aliases necesita un obs/],
    [change(m => { m.observers[3].obs = "47da174e"; }), /observador n\.º 4\): observador repetido/],
    [change(m => { mate(m).obs = "65c8ae44"; }), /un compañero no puede ser uno de los personajes de self/],
    [change(m => { mate(m).obs = "27e0ee58"; }), /un compañero no puede ser uno de los personajes de self/],
    [change(m => { mate(m).items[0].id = 2589; }), /^Envío no válido \(mercado GritodeGuerra-Alliance, observador n\.º 2\): el objeto 2589 no está en items del mercado\.$/],
    [change(m => { mate(m).items[1].id = 2770; }), /objeto 2770\): objeto repetido/],
    [change(m => { mate(m).items[0].days[0][6] = "a"; }), /los días de un compañero deben ser propios \(src "o"\)/],
    [change(m => { mate(m).items[0].days = many(21, i => [2510 + i, 40, 40, 40, 1, 1, "o"]); }), /days debe ser una lista de 20 días/],
    [change(m => { mate(m).items[0].points = many(151, i => [C.now - 100000 + i, 40, 1, 1]); }), /points debe ser una lista de 150 puntos/],
    [change(m => { self(m).items[0].days = many(131, i => [2390 + i, 40, 40, 40, 1, 1, "o"]); }), /days debe ser una lista de 130 días/],
    [change(m => { self(m).items[0].points = many(131, i => [C.now - 100000 + i, 40, 1, 1]); }), /points debe ser una lista de 130 puntos/],
    [change(m => { mate(m).items[0].days.reverse(); }), /ascendente/],
    [change(m => { mate(m).items[0].days[0][0] = C.T + 2; }), /d debe/],
    [change(m => { mate(m).items[0].points[0][0] = C.now + 2 * DAY; }), /t debe/],
    [change(m => { mate(m).items = "x"; }), /items debe ser una lista de 300 series/],
    [change(m => { mate(m).items[0] = 7; }), /serie n\.º 1\): se esperaba un objeto/],
    [change(m => { m.items.push({...m.items[0]}); }), /objeto 2770\): objeto repetido/],
    [change(m => { m.items[0].cat = "arma"; }), /cat/],
    [change(m => { m.items[0].name = "a\nb"; }), /name/]
  ];
  for (const [body, message] of cases) {
    assert.throws(() => validateUpload(body, options), error => { assert.equal(error.status, 400); assert.match(error.message, /^Envío no válido/); assert.match(error.message, message); return true; },
      String(message));
  }
  // 8000 series per body at most, across markets and observers.
  const wide = {schema: 2, addon: "0.4.0", markets: Array.from({length: 8}, (_, mi) => ({market: `Reino${mi}-Alliance`, cut: null,
    items: WATCHLIST.metal.slice(0, 17).map(id => ({id, name: "", cat: "otro", vendor: 0})),
    observers: Array.from({length: 61}, (_, oi) => ({obs: oi === 0 ? null : code(oi), self: oi === 0, items: WATCHLIST.metal.slice(0, 17).map(id => ({id, days: [], points: []}))}))}))};
  assert.throws(() => validateUpload(wide, options), /el envío no puede llevar más de 8000 series/);
  wide.markets[7].observers = wide.markets[7].observers.slice(0, 30);
  assert.doesNotThrow(() => validateUpload(wide, options), "7 x 61 x 17 + 30 x 17 = 7769 series fit");

  // Over HTTP a refused body writes nothing.
  const r = room().at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 1);
  const before = dump(r.db);
  for (const [body] of cases.slice(0, 8)) assert.equal((await r.sync(1, body)).status, 400);
  assert.deepEqual(dump(r.db), before);
});

// ---------------------------------------------------------------------------------------------------------------
/** A schema-2 body of one market: own characters (codes) with a series, and mates with the given series. */
function body({own = "aaaa0001", aliases = [], ownItems = [], mates = [], market = MARKET, cut = null} = {}) {
  const ids = new Set([...ownItems.map(s => s.id), ...mates.flatMap(m => m.items.map(s => s.id))]);
  return {schema: 2, addon: "0.4.0", markets: [{market, cut, items: [...ids].sort((a, b) => a - b).map(id => ({id, name: "", cat: "otro", vendor: 0})), deposits: [],
    observers: [{obs: own, self: true, aliases, items: ownItems}, ...mates.map(m => ({obs: m.obs, self: false, items: m.items}))]}]};
}
const mateCode = i => (0xb0000000 + i).toString(16);
/** One series of a watchlist item: days from..to and one point a day at 12:00 (days within T-14 are kept). */
function series(id, from, to, lo = 1000) {
  const days = [], points = [];
  for (let d = from; d <= to; d++) { days.push([d, lo, lo, lo, 100, 1, "o"]); points.push([DAY0 + d * DAY + 12 * 3600, lo, 100, 10]); }
  return {id, days, points};
}

test("caps: 60 relayed persons per market active in 30 days, 2000 codes in the guild; known mates always fit", async t => {
  const r = room().at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 2);
  const T = C.T, sixty = Array.from({length: 60}, (_, i) => ({obs: mateCode(i), items: [series(2770, T, T)]}));
  const full = await r.sync(1, body({mates: sixty}));
  assert.equal(full.status, 200);
  assert.deepEqual([full.body.markets[0].observers, full.body.markets[0].skippedObservers], [60, []]);
  const slots = r.db.prepare("SELECT slot FROM guild_observers WHERE member_id IS NULL ORDER BY slot").all().map(x => x.slot);
  assert.deepEqual([slots.length, slots[0], slots.at(-1)], [60, RELAYED_SLOT_BASE + 1, RELAYED_SLOT_BASE + 60]);
  const more = await r.at(C.now + 600).sync(1, body({mates: [{obs: mateCode(0), items: [series(2770, T, T, 990)]}, {obs: mateCode(99), items: [series(2770, T, T)]}]}));
  assert.deepEqual([more.status, more.body.markets[0].observers, more.body.markets[0].skippedObservers],
    [200, 1, [{obs: mateCode(99), reason: "LIMITE_DE_OBSERVADORES"}]], "a known mate is still written, a new one has no room");
  assert.equal(r.db.prepare("SELECT lo FROM guild_obs_day WHERE member_id=? AND item_id=2770").get(RELAYED_SLOT_BASE + 1).lo, 990);
  assert.equal(r.db.prepare("SELECT count(*) AS n FROM guild_observers WHERE hash=?").get(mateCode(99)).n, 0);
  // A mate that turns out to be a member's character no longer counts as a relayed person.
  const bound = await r.at(C.now + 1200).sync(2, body({own: mateCode(5), ownItems: [series(2770, T, T)], mates: [{obs: mateCode(99), items: [series(2770, T, T)]}]}));
  assert.deepEqual([bound.body.markets[0].observers, bound.body.markets[0].skippedObservers], [1, []]);
  assert.deepEqual(bindings(r.db)[mateCode(5)], {slot: RELAYED_SLOT_BASE + 6, member: 2});
  assert.equal(bindings(r.db)[mateCode(99)].slot, RELAYED_SLOT_BASE + 61);
  // 31 days later nobody is active: there is room again (days and points of the new day).
  r.at(C.now + 31 * DAY);
  const later = await r.sync(1, body({mates: [{obs: mateCode(200), items: [series(2770, T + 31, T + 31)]}]}));
  assert.deepEqual([later.body.markets[0].observers, later.body.markets[0].skippedObservers], [1, []]);
  // 2000 codes in the guild at most (filler rows of another market).
  const count = () => r.db.prepare("SELECT count(*) AS n FROM guild_observers").get().n;
  const insert = r.db.prepare("INSERT INTO guild_observers(hash,slot,member_id,first_seen,first_by,bound_at) VALUES (?,?,NULL,0,1,NULL)");
  const om = r.db.prepare("INSERT INTO guild_observer_markets(market,slot,first_day,last_seen,last_by) VALUES ('Otro-Horde',?,0,?,1)");
  for (let i = count(); i < LIMITS.observersMax - 1; i++) { insert.run((0xc0000000 + i).toString(16), 2 * RELAYED_SLOT_BASE + i); om.run(2 * RELAYED_SLOT_BASE + i, r.nowSec); }
  const last = await r.at(C.now + 31 * DAY + 600).sync(1, body({mates: [{obs: mateCode(300), items: [series(2770, T + 31, T + 31)]}, {obs: mateCode(301), items: [series(2770, T + 31, T + 31)]}]}));
  assert.deepEqual(last.body.markets[0].skippedObservers, [{obs: mateCode(301), reason: "LIMITE_DE_OBSERVADORES"}]);
  assert.equal(count(), LIMITS.observersMax);
  assert.equal(bindings(r.db)[mateCode(300)].slot, 2 * RELAYED_SLOT_BASE + LIMITS.observersMax - 2 + 1, "slot numbers keep growing, never reused");
});

test("the write budget: own rows first (429 as before), mates up to 75 % of the day (CUOTA) and 12000 rows per upload (ENVIO)", async t => {
  const r = room(sqliteContext(), {env: {GUILD_WRITE_ROWS_PER_DAY: "2000"}}).at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 1);
  const T = C.T, ids = WATCHLIST.hierba.slice(0, 3);
  const mates = Array.from({length: 20}, (_, i) => ({obs: mateCode(i), items: ids.map(id => series(id, T - 4, T, 1000 + i))}));
  const first = await r.sync(1, body({ownItems: [series(2770, T, T)], mates}));
  assert.equal(first.status, 200, JSON.stringify(first.body));
  const report = first.body.markets[0], skipped = report.skippedObservers.map(x => x.obs);
  assert.ok(report.observers >= 1 && skipped.length >= 1, JSON.stringify(report));
  assert.ok(report.skippedObservers.every(x => x.reason === "CUOTA"));
  assert.deepEqual(skipped, mates.slice(report.observers).map(m => m.obs), "the mates that did not fit are the last ones");
  const written = r.db.prepare("SELECT written FROM guild_write_budget").get().written;
  assert.ok(written <= 1500 + 60, `a 2000-row day keeps the mates to 1500 rows (${written})`);
  for (const obs of skipped) assert.equal(bindings(r.db)[obs], undefined, "a skipped mate gets no slot");
  assert.ok(r.db.prepare("SELECT count(*) AS n FROM guild_obs_day WHERE member_id=1").get().n === 1, "the uploader's own rows are written");
  // Over the whole budget the uploader's own rows are refused exactly as before.
  r.env.GUILD_WRITE_ROWS_PER_DAY = "1000";
  const refused = await r.at(C.now + 60).sync(1, body({ownItems: WATCHLIST.metal.slice(0, 15).map(id => series(id, T - 9, T))}));
  assert.equal(refused.status, 429);
  // The next UTC day the rest fits.
  r.env.GUILD_WRITE_ROWS_PER_DAY = "40000";
  const next = await r.at((Math.floor(C.now / DAY) + 1) * DAY + 3600).sync(1, body({ownItems: [series(2770, T, T)], mates: mates.slice(report.observers)}));
  assert.deepEqual([next.status, next.body.markets[0].observers, next.body.markets[0].skippedObservers], [200, skipped.length, []]);
  // 12000 relayed rows per upload whatever the budget.
  const big = room(sqliteContext(), {env: {GUILD_WRITE_ROWS_PER_DAY: "1000000"}}).at(C.now);
  t.after(() => big.db.close());
  seed(big.db, 1);
  const crowd = Array.from({length: 60}, (_, i) => ({obs: mateCode(i), items: WATCHLIST.hierba.slice(0, 8).map(id => series(id, T - 13, T, 900 + i))}));
  const capped = await big.sync(1, body({mates: crowd}));
  assert.equal(capped.status, 200);
  const accepted = capped.body.markets[0].observers;
  assert.ok(accepted > 0 && accepted < 60 && capped.body.markets[0].skippedObservers.length === 60 - accepted, JSON.stringify(capped.body.markets[0]).slice(0, 200));
  assert.ok(capped.body.markets[0].skippedObservers.every(x => x.reason === "ENVIO"), "the per-upload cap is ENVIO, not the daily quota");
  assert.ok(big.db.prepare("SELECT count(*) AS n FROM guild_obs_day").get().n * 4 <= LIMITS.relayRowsPerUpload);
  // The same body again: the mates already stored cost nothing and the waiting ones go first.
  let uploads = 1, waiting = capped.body.markets[0].skippedObservers.length;
  while (waiting > 0 && uploads < 10) {
    const again = await big.at(C.now + 60 * uploads).sync(1, body({ownItems: [series(2770, T, T, 1000 + uploads)], mates: crowd}));
    assert.equal(again.status, 200);
    waiting = again.body.markets[0].skippedObservers.length;
    uploads++;
  }
  assert.equal(waiting, 0, "every mate stored");
  assert.ok(uploads <= Math.ceil(60 / accepted) + 1, `in ${uploads} uploads`);
  assert.equal(big.db.prepare("SELECT count(DISTINCT member_id) AS n FROM guild_obs_day WHERE member_id>=?").get(RELAYED_SLOT_BASE).n, 60);
});

test("relayed mates take turns: least recently stored first, a big backlog with a low code never blocks the others", async t => {
  const r = room(sqliteContext(), {env: {GUILD_WRITE_ROWS_PER_DAY: "10000000"}}).at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 1);
  const T = C.T, ids = Object.values(WATCHLIST).flat();
  // A heavy mate (all 114 items, 15 days, 12 points a day) with the lowest code costs more than 12000 rows alone.
  const heavy = {obs: mateCode(0), items: ids.map(id => {
    const one = series(id, T - 14, T, 5000);
    for (let d = T - 2; d <= T; d++) for (let k = 1; k < 12; k++) one.points.push([DAY0 + d * DAY + k * 7200 + 600, 5000 + k, 100, 10]);
    one.points.sort((a, b) => a[0] - b[0]);
    return one;
  })};
  const light = Array.from({length: 4}, (_, i) => ({obs: mateCode(100 + i), items: ids.slice(0, 10).map(id => series(id, T - 3, T, 900 + i))}));
  const stored = () => new Set(r.db.prepare("SELECT DISTINCT o.hash FROM guild_obs_day d JOIN guild_observers o ON o.slot=d.member_id WHERE d.member_id>=?")
    .all(RELAYED_SLOT_BASE).map(x => x.hash));
  const first = await r.sync(1, body({mates: [heavy, ...light]}));
  assert.equal(first.status, 200, JSON.stringify(first.body).slice(0, 300));
  assert.equal(first.body.markets[0].observers, 1, "the heavy mate goes alone, over the per-upload cap");
  assert.deepEqual(first.body.markets[0].skippedObservers, light.map(m => ({obs: m.obs, reason: "ENVIO"})));
  assert.ok(stored().has(heavy.obs));
  const second = await r.at(C.now + 900).sync(1, body({ownItems: [series(2770, T, T)], mates: [heavy, ...light]}));
  assert.deepEqual([second.body.markets[0].observers, second.body.markets[0].skippedObservers], [5, []], "the rest the next time");
  assert.equal(stored().size, 5);
  // Steady state: 20 mates scanning the 114 items 3 times a day and 2 WoW saves a day. Each save the uploader sends
  // every mate's last 3 days and today's points, and posts again at once while mates come back as ENVIO (as
  // pc_sync/hermandad.py does): every mate is stored every day, whatever its code, within the 24 uploads a day.
  const crowd = Array.from({length: 20}, (_, i) => ({obs: mateCode(200 + i), base: 700 + i * 13}));
  const recent = (m, day, scans) => ({obs: m.obs, items: ids.map(id => {
    const one = series(id, day - 2, day, m.base);
    one.points = [];
    for (let k = 0; k < scans; k++) one.points.push([DAY0 + day * DAY + 8 * 3600 + k * 3 * 3600, m.base + k, 100, 10]);
    one.days[one.days.length - 1] = [day, m.base, m.base + scans - 1, m.base + scans - 1, 100, scans, "o"];
    return one;
  })});
  for (let day = 1; day <= 3; day++) {
    const D = T + day;
    let uploads = 0;
    for (const [save, scans] of [[0, 1], [1, 3]]) {
      let waiting = crowd.length, tries = 0;
      while (waiting > 0 && tries < 10) {
        const at = DAY0 + D * DAY + (10 + save * 10) * 3600 + tries * 15;
        const result = await r.at(at).sync(1, body({ownItems: [series(2770, D, D, 1000 + tries + save * 100)], mates: crowd.map(m => recent(m, D, scans))}));
        assert.equal(result.status, 200, JSON.stringify(result.body).slice(0, 200));
        const skipped = result.body.markets[0].skippedObservers;
        assert.ok(skipped.every(x => x.reason === "ENVIO"), JSON.stringify(skipped).slice(0, 200));
        waiting = skipped.length;
        tries++;
        uploads++;
      }
      assert.equal(waiting, 0, `day ${day}, save ${save}: every mate fits after ${tries} uploads`);
    }
    assert.ok(uploads <= LIMITS.uploadsPerDay, `${uploads} uploads`);
    const today = new Set(r.db.prepare("SELECT DISTINCT o.hash FROM guild_obs_day d JOIN guild_observers o ON o.slot=d.member_id WHERE d.day=? AND d.scans=3")
      .all(D).map(x => x.hash));
    assert.deepEqual(crowd.filter(m => !today.has(m.obs)).map(m => m.obs), [], `day ${day}: every mate with its 3 scans`);
  }
});

test("an uploader cannot take another member's character; a mate's day that only adds scans is not rewritten", async t => {
  const r = room().at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 2);
  assert.equal((await r.sync(1, U1)).status, 200);
  const stolen = await r.at(C.now + 60).sync(2, body({own: "65c8ae44", aliases: ["27e0ee58", "aaaa0002"], ownItems: [series(2770, C.T, C.T, 41)]}));
  assert.deepEqual(stolen.body.markets[0].selfConflicts, ["65c8ae44", "27e0ee58"]);
  assert.deepEqual([bindings(r.db)["65c8ae44"], bindings(r.db).aaaa0002], [{slot: 1, member: 1}, {slot: 2, member: 2}]);
  assert.equal(r.db.prepare("SELECT lo FROM guild_obs_day WHERE member_id=2 AND item_id=2770").get().lo, 41, "member 2's own scan stays in member 2's slot");
  // Ána's day 2530 seen again with more scans: same prices, so no write and no aggregate change.
  const again = copy(U1);
  for (const o of again.markets[0].observers) if (o.obs === "47da174e") for (const s of o.items) for (const d of s.days) d[5] = 9;
  again.markets[0].observers = again.markets[0].observers.filter(o => o.obs === "47da174e" || o.self);
  r.queries.length = 0;
  const report = await r.at(C.now + 120).sync(1, again);
  assert.equal(report.body.rowsChanged, 0);
  assert.ok(!r.queries.some(q => /^\s*INSERT INTO guild_obs_day/.test(q)), "no day row is written");
  assert.equal(r.db.prepare("SELECT max(scans) AS n FROM guild_obs_day WHERE member_id=?").get(RELAYED_SLOT_BASE + 1).n, 1);
});

test("a relayed mate's days count from T-14, only watchlist items are relayed, and a new item needs a stored day", async t => {
  const r = room().at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 1);
  const T = C.T;
  const report = await r.sync(1, body({mates: [{obs: mateCode(1), items: [series(2770, T - 16, T), series(500001, T, T), {id: 2771, days: [], points: [[C.now - 3600, 50, 1, 1]]}]}]}));
  assert.equal(report.status, 200);
  assert.deepEqual(r.db.prepare("SELECT DISTINCT item_id FROM guild_obs_day ORDER BY item_id").all().map(x => x.item_id), [2770]);
  assert.equal(r.db.prepare("SELECT min(day) AS d FROM guild_obs_day").get().d, T - LIMITS.relayDays);
  assert.deepEqual(r.db.prepare("SELECT item_id FROM guild_items ORDER BY item_id").all().map(x => x.item_id), [2770],
    "an extra (not in the watchlist) is ignored, and 2771 brought only a point");
  assert.equal(r.db.prepare("SELECT count(*) AS n FROM guild_obs_point WHERE item_id<>2770").get().n, 0);
  const om = r.db.prepare("SELECT * FROM guild_observer_markets").all().map(x => ({...x}));
  assert.deepEqual(om, [{market: MARKET, slot: RELAYED_SLOT_BASE + 1, first_day: T, last_seen: DAY0 + T * DAY + 12 * 3600, last_by: 1}]);
});

test("a market with only mates counts its uploader, and one mate seen in two markets keeps one slot", async t => {
  const r = room().at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 1);
  const T = C.T, alliance = body({mates: [{obs: mateCode(7), items: [series(2770, T, T)]}]}), horde = body({market: HORDE, mates: [{obs: mateCode(7), items: [series(2589, T, T)]}]});
  alliance.markets[0].observers.shift();
  const upload = {...alliance, markets: [alliance.markets[0], horde.markets[0]]};
  const report = await r.sync(1, upload);
  assert.equal(report.status, 200, JSON.stringify(report.body));
  assert.deepEqual(report.body.markets.map(m => [m.market, m.observers, m.items]), [[MARKET, 1, 1], [HORDE, 1, 1]]);
  assert.deepEqual(bindings(r.db), {[mateCode(7)]: {slot: RELAYED_SLOT_BASE + 1, member: null}, aaaa0001: {slot: 1, member: 1}});
  assert.deepEqual(r.db.prepare("SELECT market,slot FROM guild_observer_markets ORDER BY market").all().map(x => [x.market, x.slot]),
    [[MARKET, RELAYED_SLOT_BASE + 1], [HORDE, RELAYED_SLOT_BASE + 1]]);
  const fresh = (await r.summary()).body.freshness;
  assert.deepEqual([fresh.contributors, fresh.observers], [1, 2], "the uploader and the mate");
  assert.equal(H.freshnessLine(fresh, 32, C.now * 1000).split(" · ")[0], "2 personas aportan (1 sube)");
});

// ---------------------------------------------------------------------------------------------------------------
async function relayed(t) {
  const r = room().at(C.now);
  t.after(() => r.db.close());
  seed(r.db, 2);
  assert.equal((await r.sync(1, U1)).status, 200);
  assert.equal((await r.at(C.nowSecond).sync(2, U2)).status, 200);
  return r;
}

test("purging the second uploader: its own slot, its characters (also what A relayed of them) and the mates' rows it wrote go", async t => {
  const r = await relayed(t);
  const rows = (where, ...args) => r.db.prepare(`SELECT count(*) AS n FROM guild_obs_day WHERE ${where}`).get(...args).n;
  const points = (where, ...args) => r.db.prepare(`SELECT count(*) AS n FROM guild_obs_point WHERE ${where}`).get(...args).n;
  // Borja was first relayed by account A (slot BASE + 2) and then bound to member 2 by its own upload.
  assert.deepEqual(bindings(r.db)["556e986d"], {slot: RELAYED_SLOT_BASE + 2, member: 2});
  const borja = RELAYED_SLOT_BASE + 2;
  const expected = rows("member_id=2") + points("member_id=2") + rows("member_id>=? AND uploaded_by=2", RELAYED_SLOT_BASE) +
    points("member_id>=? AND uploaded_by=2", RELAYED_SLOT_BASE) + rows("member_id=? AND uploaded_by<>2", borja) +
    points("member_id=? AND uploaded_by<>2", borja) + r.db.prepare("SELECT count(*) AS n FROM guild_deposits WHERE member_id=2").get().n;
  assert.ok(rows("member_id=? AND uploaded_by=2", RELAYED_SLOT_BASE + 3) > 0, "Борис's day of today came from account B");
  assert.ok(rows("member_id=? AND uploaded_by=1", borja) > 0, "account A relayed Borja");
  const purge = await r.post("/api/guild/members/revoke", {memberId: 2, purge: true});
  assert.deepEqual(purge.body, {revoked: true, memberId: 2, purged: expected});
  assert.deepEqual([rows("member_id=2"), rows("uploaded_by=2"), points("uploaded_by=2")], [0, 0, 0]);
  assert.deepEqual([rows("member_id=?", borja), points("member_id=?", borja)], [0, 0], "what account A relayed of Borja goes too");
  assert.equal(bindings(r.db)["556e986d"], undefined, "Borja's code is forgotten");
  assert.equal(r.db.prepare("SELECT count(*) AS n FROM guild_observer_markets WHERE slot=?").get(borja).n, 0);
  assert.deepEqual(aggregates(r.db), expectedAggregates(r.db));
  const after = await r.summary();
  assert.equal(after.cache, "miss", "the summaries are rebuilt");
  assert.deepEqual([after.body.freshness.contributors, after.body.freshness.observers], [1, 3]);
});

test("purge does not depend on the upload order: a character first relayed or first uploaded as its own ends the same", async t => {
  const T = C.T, ends = [];
  for (const order of ["relayed first", "own first"]) {
    const r = room().at(C.now);
    t.after(() => r.db.close());
    seed(r.db, 2);
    const a = () => r.sync(1, body({own: "aaaa0001", ownItems: [series(2770, T - 1, T, 40)], mates: [{obs: "bbbb0002", items: [series(2770, T - 1, T, 42), series(2772, T - 1, T, 142)]}]}));
    const b = () => r.sync(2, body({own: "bbbb0002", ownItems: [series(2770, T - 1, T, 41)]}));
    if (order === "relayed first") { assert.equal((await a()).status, 200); r.at(C.now + 60); assert.equal((await b()).status, 200); }
    else { assert.equal((await b()).status, 200); r.at(C.now + 60); assert.equal((await a()).status, 200); }
    assert.equal((await r.summary()).body.freshness.observers, 2, `${order}: 2 personas`);
    const purge = await r.at(C.now + 120).post("/api/guild/members/revoke", {memberId: 2, purge: true});
    assert.equal(purge.status, 200);
    const left = r.db.prepare("SELECT member_id,item_id,day,lo,uploaded_by FROM guild_obs_day ORDER BY member_id,item_id,day").all().map(x => ({...x}));
    const leftPoints = r.db.prepare("SELECT member_id,item_id,t,lo FROM guild_obs_point ORDER BY member_id,item_id,t").all().map(x => ({...x}));
    const codes = Object.keys(bindings(r.db)).sort();
    const summary = (await r.summary()).body;
    ends.push({left, leftPoints, codes, observers: summary.freshness.observers, aggregates: aggregates(r.db)});
    assert.deepEqual(aggregates(r.db), expectedAggregates(r.db), order);
  }
  assert.deepEqual(ends[0], ends[1], "the same rows, codes, persons and aggregates");
  assert.deepEqual([ends[0].codes, ends[0].observers], [["aaaa0001"], 1], "only the first uploader is left");
  assert.ok(ends[0].left.every(x => x.member_id === 1), JSON.stringify(ends[0].left));
});

test("purging the first uploader: its slot (also what others relayed of it) and its relayed rows go; mates left empty disappear", async t => {
  const r = await relayed(t);
  const purge = await r.post("/api/guild/members/revoke", {memberId: 1, purge: true});
  assert.equal(purge.status, 200);
  assert.equal(r.db.prepare("SELECT count(*) AS n FROM guild_obs_day WHERE member_id=1 OR uploaded_by=1").get().n, 0);
  assert.equal(r.db.prepare("SELECT count(*) AS n FROM guild_obs_point WHERE member_id=1 OR uploaded_by=1").get().n, 0);
  const codes = bindings(r.db);
  assert.equal(codes["65c8ae44"], undefined, "the purged member's own codes are forgotten");
  assert.deepEqual(codes["556e986d"], {slot: RELAYED_SLOT_BASE + 2, member: 2}, "a code bound to another member stays bound");
  assert.deepEqual(r.db.prepare("SELECT slot FROM guild_observer_markets ORDER BY slot").all().map(x => x.slot), [RELAYED_SLOT_BASE + 3],
    "only Борис still has rows (account B's scan of today); Ána's rows were all A's");
  assert.deepEqual(aggregates(r.db), expectedAggregates(r.db));
  assert.deepEqual(r.db.prepare("SELECT item_id FROM guild_items WHERE market=? ORDER BY item_id").all(MARKET).map(x => x.item_id), [2770, 2772, 12365],
    "13446 had only Ána's days and leaves the market");
  // The next day's retention drops Ána's code: unbound and without any market.
  r.at(C.now + DAY);
  assert.equal((await r.sync(2, body({own: "556e986d", ownItems: [series(2770, C.T + 1, C.T + 1)]}))).status, 200);
  assert.equal(bindings(r.db)["47da174e"], undefined);
});

test("retention: relayed mates not seen in 180 days and their codes go; members' codes stay", async t => {
  const r = await relayed(t);
  r.at(C.now + 181 * DAY);
  assert.equal((await r.sync(2, body({own: "556e986d", ownItems: [series(2770, C.T + 181, C.T + 181)]}))).status, 200);
  assert.deepEqual(Object.keys(bindings(r.db)).sort(), ["27e0ee58", "556e986d", "65c8ae44"]);
  assert.deepEqual(r.db.prepare("SELECT market,slot FROM guild_observer_markets").all().map(x => ({...x})), []);
  assert.equal(r.db.prepare("SELECT count(*) AS n FROM guild_obs_day WHERE member_id>=?").get(RELAYED_SLOT_BASE).n, 0);
});

// ---------------------------------------------------------------------------------------------------------------
test("reads: a mate's lowest price is «un compañero» (never a name or code), counts are persons, CSVs match the panel", async t => {
  const r = await relayed(t);
  const summary = (await r.summary()).body;
  const potion = summary.items.find(e => e.id === 13446);
  assert.deepEqual([potion.price.lo, potion.price.member, potion.price.mate, potion.members], [2400, null, true, 1]);
  const copper = summary.items.find(e => e.id === 2770);
  assert.deepEqual([copper.price.member, copper.price.mate, copper.today.obs], [null, true, 4], "Борис's 36c is today's lowest");
  assert.deepEqual(summary.freshness.observersToday, 4);
  const csv = (await r.get(`/api/guild/export.csv?market=${encodeURIComponent(MARKET)}&kind=summary`)).body;
  assert.equal(H.csvRows(H.SUMMARY_COLUMNS, summary.items), csv, "the panel's 'esta vista' is the server CSV");
  assert.equal(csv[0], "\uFEFF");
  const lines = csv.slice(1).split("\r\n");
  assert.match(lines[0], /;Visto por;.*;Personas;/);
  assert.ok(lines.find(line => line.includes(";13446;")).includes(";un compañero;"));
  const daily = (await r.get(`/api/guild/export.csv?market=${encodeURIComponent(MARKET)}&kind=daily&days=14`)).body;
  assert.match(daily, /;Cantidad;Personas\r\n/);
  const detail = (await r.get(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=12365`)).body;
  assert.deepEqual(detail.points.map(p => [p.t, p.member, p.mate]),
    [[1796409000, "Cuenta 1", false], [1796410800, "Cuenta 2", false], [1796461200, "Cuenta 1", false], [1796468400, "Cuenta 2", false], [1796475600, "Cuenta 1", false]],
    "Borja's points sent by both accounts are one person's points, labelled with the member they are bound to");
  const potionDetail = (await r.get(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=13446`)).body;
  assert.deepEqual(potionDetail.days.map(x => x.members), [[null], [null], [null]]);
  assert.deepEqual(potionDetail.points.map(p => [p.member, p.mate]), [[null, true], [null, true], [null, true]]);
  assert.equal(H.peopleText(potionDetail.days[0].members, potionDetail.days[0].obs), "1 compañero");
  const day = (await r.get(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=2770`)).body.days.find(x => x.d === C.T);
  assert.deepEqual(day.members, ["Cuenta 1", "Cuenta 2", null, null]);
  assert.equal(H.peopleText(day.members, day.obs), "Cuenta 1, Cuenta 2 y 2 compañeros");
  const me = (await r.get("/api/guild/me")).body;
  assert.deepEqual(me.markets.map(m => [m.market, m.contributors, m.observers]), [[MARKET, 2, 4], [HORDE, 1, 1]]);
  const members = (await r.get("/api/guild/members")).body.members;
  assert.deepEqual(members.map(m => [m.id, m.characters]), [[1, 2], [2, 1]], "how many characters each member bound, never the codes");
});

test("privacy: no character or guild name reaches the server or the uploads, only codes", async t => {
  const r = await relayed(t);
  const everything = JSON.stringify(dump(r.db, {skip: []}));
  for (const name of NAMES) {
    assert.ok(!everything.includes(name), name);
    for (const file of ["upload-schema1.json", "upload-schema2.json", "upload-schema2-second.json", "upload-schema2-from-hist1.json"]) assert.ok(!raw(file).toString("utf8").includes(name), `${name} in ${file}`);
  }
  for (const hash of Object.values(C.hashes)) assert.ok(everything.includes(hash), "codes are stored");
  const summary = JSON.stringify((await r.summary()).body);
  for (const hash of Object.values(C.hashes)) assert.ok(!summary.includes(hash), "the panel never shows a code");
});

test("the panel strip: 'N personas aportan (M suben)', singular forms, no uploads, and older servers", () => {
  const now = Date.parse("2026-12-05T14:00:00Z"), two = "2026-12-05T12:00:00Z";
  assert.equal(H.freshnessLine({contributors: 2, observers: 4, lastUploadAt: two}, 12, now), "4 personas aportan (2 suben) · último envío hace 2 h · día 12 desde el lanzamiento");
  assert.equal(H.freshnessLine({contributors: 1, observers: 1, lastUploadAt: two}, 1, now), "1 persona aporta (1 sube) · último envío hace 2 h · día 1 desde el lanzamiento");
  assert.equal(H.freshnessLine({contributors: 1, observers: 15, lastUploadAt: two}, 30, now), "15 personas aportan (1 sube) · último envío hace 2 h · día 30 desde el lanzamiento");
  assert.equal(H.freshnessLine({contributors: 0, observers: 0, lastUploadAt: null}, 3, now), "ningún envío en 14 días · día 3 desde el lanzamiento");
  assert.equal(H.freshnessLine({contributors: 3, lastUploadAt: two}, 3, now), "3 miembros · último envío hace 2 h · día 3 desde el lanzamiento", "without observers (older server)");
  assert.equal(H.peopleText(["Ana", "Luis", null, null], 4), "Ana, Luis y 2 compañeros");
  assert.equal(H.peopleText(["Ana", null], 2), "Ana y 1 compañero");
  assert.equal(H.peopleText(["Ana", "Luis"], 2), "Ana, Luis");
  assert.equal(H.peopleText([null, null, null], 3), "3 compañeros");
  assert.equal(H.peopleText([], 2), "2");
  assert.equal(H.SUMMARY_COLUMNS.find(c => c.label === "Visto por").value({price: {lo: 5, member: null, mate: true}}), "un compañero");
  assert.equal(H.SUMMARY_COLUMNS.find(c => c.label === "Visto por").value({price: null}), null);
  assert.deepEqual(H.dailyColumns({id: 1}, 2499).map(c => c.label).at(-1), "Personas");
  const js = fs.readFileSync(new URL("../public/hermandad.js", import.meta.url), "utf8"), html = fs.readFileSync(new URL("../public/hermandad.html", import.meta.url), "utf8");
  assert.doesNotMatch(js, /"un miembro"/);
  assert.match(html, /data-sort="members" class="num"><button type="button" title="Personas[^"]*">Personas /);
  assert.match(html, /seudónimo, no anónimo/);
  assert.match(html, /\/oro compartir off/);
  assert.match(html, /basta con 1 o 2 personas/);
});

test("README and CONTRIBUTING explain the relay, the 1-2 uploaders and that the code is pseudonymous", () => {
  const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8"), contributing = fs.readFileSync(new URL("../CONTRIBUTING.md", import.meta.url), "utf8");
  for (const text of [readme, contributing]) {
    assert.match(text, /seudónimo, no anónimo/);
    assert.match(text, /nunca salen del juego/);
  }
  assert.match(readme, /1 o 2/);
  assert.match(readme, /\/oro compartir off/);
  assert.match(readme, /personas aportan/);
  assert.doesNotMatch(readme, /Nunca se envían `OroHermandadDB` ni `OroHermandadCharDB` \(personajes,/, "the old promise is corrected");
  assert.match(contributing, /test\/fixtures\/relay/);
});

// ---------------------------------------------------------------------------------------------------------------
test("through the worker: schema-2 uploads, the panel strip and a purge never touch Portfolio", async t => {
  const P = sqliteContext(), G = sqliteContext();
  t.after(() => { P.db.close(); G.db.close(); });
  const PASSWORD = "test-only-owner-password-47-strong", BASE = "https://especulador.test";
  const env = {OWNER_PASSWORD: PASSWORD, SESSION_SECRET: "test-only-independent-session-secret-99",
    ASSETS: {async fetch() { return new Response("asset", {status: 200}); }}};
  const portfolio = new Portfolio(P.ctx, env), market = new GuildMarket(G.ctx, env);
  let clock = C.now * 1000;
  market.now = () => clock;
  env.PORTFOLIO = {idFromName: n => n, get: () => ({fetch: request => portfolio.fetch(request)})};
  env.GUILD = {idFromName: n => n, get: () => ({fetch: request => market.fetch(request)})};
  const call = (path, {method = "GET", data, cookie, csrf, token} = {}) => {
    const h = new Headers();
    if (cookie) h.set("Cookie", cookie);
    if (csrf) h.set("X-CSRF-Token", csrf);
    if (token) h.set("Authorization", "Bearer " + token);
    if (data !== undefined) { h.set("Content-Type", "application/json"); h.set("Origin", BASE); }
    return worker.fetch(new Request(BASE + path, {method, headers: h, ...(data !== undefined ? {body: JSON.stringify(data)} : {})}), env);
  };
  const login = await call("/api/login", {method: "POST", data: {password: PASSWORD}});
  const cookie = login.headers.get("Set-Cookie").split(";")[0];
  const state = await (await call("/api/state", {cookie})).json();
  assert.equal((await call("/api/settings", {method: "POST", data: {capitalCopper: 4242}, cookie, csrf: state.token})).status, 200);
  const portfolioBefore = dump(P.db, {skip: []});
  const csrf = (await (await call("/api/guild/me", {cookie})).json()).csrf;
  const keys = [];
  for (const label of ["Cuenta A", "Cuenta B"]) {
    const {member} = await (await call("/api/guild/members", {method: "POST", data: {label}, cookie, csrf})).json();
    keys.push((await (await call("/api/guild/keys", {method: "POST", data: {memberId: member.id}, cookie, csrf})).json()).key);
  }
  const sync = (key, body) => worker.fetch(new Request(BASE + "/api/guild/sync", {method: "POST", headers: {"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    body: JSON.stringify(body)}), env);
  assert.equal((await sync(keys[0], U1)).status, 200);
  clock = C.nowSecond * 1000;
  const second = await sync(keys[1], U2);
  assert.equal(second.status, 200);
  assert.equal((await second.json()).markets[0].observers, 4);
  const summary = await (await call("/api/guild/market?market=" + encodeURIComponent(MARKET), {cookie})).json();
  assert.equal(H.freshnessLine(summary.freshness, summary.dayOfLaunch, clock), `${X.freshnessText.afterSecond} · último envío hace un momento · día 32 desde el lanzamiento`);
  assert.equal((await call("/api/guild/members/revoke", {method: "POST", data: {memberId: 1, purge: true}, cookie, csrf})).status, 200);
  assert.deepEqual(dump(P.db, {skip: []}), portfolioBefore, "every Portfolio table and row is unchanged");
  const names = db => db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(x => x.name);
  assert.ok(names(G.db).every(name => name.startsWith("guild_")));
  assert.ok(names(P.db).every(name => name.startsWith("especulador_")));
});

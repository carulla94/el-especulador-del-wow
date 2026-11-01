import test from "node:test";
import assert from "node:assert/strict";
import {DatabaseSync} from "node:sqlite";
import {Store, CHUNK_BYTES, MAX_STATE_BYTES} from "../src/storage.mjs";
import {emptyState} from "../src/engine.mjs";

const encoder = new TextEncoder();

function context() {
  const db = new DatabaseSync(":memory:");
  let failInsertPart = null;
  let largestBinding = 0;
  const sql = {
    exec(query, ...bindings) {
      for (const value of bindings) {
        if (typeof value === "string") {
          const bytes = encoder.encode(value).byteLength;
          largestBinding = Math.max(largestBinding, bytes);
          assert.ok(bytes <= 2 * 1024 * 1024, "Cloudflare SQL per-value limit");
        }
      }
      if (query.startsWith("INSERT INTO especulador_chunks") && bindings[1] === failInsertPart) throw new Error("simulated SQLite write failure");
      const statement = db.prepare(query);
      const rows = statement.columns().length ? statement.all(...bindings) : (statement.run(...bindings), []);
      return {toArray: () => rows, [Symbol.iterator]: () => rows[Symbol.iterator]()};
    }
  };
  const ctx = {storage: {sql, transactionSync(callback) {
    db.exec("BEGIN IMMEDIATE");
    try {
      const result = callback();
      assert.ok(!(result instanceof Promise), "transactionSync must remain synchronous");
      db.exec("COMMIT");
      return result;
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }}};
  return {ctx, db, failOnPart(value) { failInsertPart = value; }, largestBinding: () => largestBinding};
}

function store(t) {
  const fixture = context();
  t.after(() => fixture.db.close());
  return {store: new Store(fixture.ctx), ...fixture};
}

test("a new account returns independent empty states", t => {
  const {store: persistence} = store(t);
  const first = persistence.loadState();
  assert.deepEqual(first, emptyState());
  first.transactions.push({test: "unsaved"});
  assert.deepEqual(persistence.loadState().transactions, []);
  assert.equal(persistence.loadPreviousBackup(), null);
});

test("state persists across Store instances using the same SQLite database", t => {
  const {store: persistence, ctx} = store(t);
  const state = emptyState();
  state.settings.capitalCopper = 123456;
  state.transactions.push({id: 1, name: "Poción de prueba", itemKey: "2589::-5"});
  persistence.saveState(state);
  assert.deepEqual(new Store(ctx).loadState(), state);
});

test("state larger than SQLite's 2 MiB row limit uses bounded UTF-8 chunks", t => {
  const {store: persistence, largestBinding, db} = store(t);
  const state = emptyState();
  state.sourceMeta.note = "€🐉á".repeat(300000);
  const result = persistence.saveState(state);
  assert.ok(result.bytes > 2 * 1024 * 1024);
  assert.ok(result.chunks > 4);
  assert.ok(largestBinding() <= CHUNK_BYTES);
  const rows = db.prepare("SELECT payload FROM especulador_chunks WHERE kind='state'").all();
  for (const row of rows) assert.ok(encoder.encode(row.payload).length <= CHUNK_BYTES);
  assert.deepEqual(persistence.loadState(), state);
});

test("failure midway through replacement rolls back to the entire prior account", t => {
  const fixture = store(t);
  const previous = emptyState();
  previous.settings.capitalCopper = 10000;
  fixture.store.saveState(previous);
  const replacement = emptyState();
  replacement.sourceMeta.note = "x".repeat(CHUNK_BYTES * 3);
  fixture.failOnPart(1);
  assert.throws(() => fixture.store.saveState(replacement), /simulated SQLite/);
  fixture.failOnPart(null);
  assert.deepEqual(fixture.store.loadState(), previous);
});

test("oversized state is rejected before the existing account changes", t => {
  const {store: persistence} = store(t);
  const previous = emptyState();
  persistence.saveState(previous);
  const state = emptyState();
  state.sourceMeta.large = "x".repeat(MAX_STATE_BYTES);
  assert.throws(() => persistence.saveState(state), /16 MiB/);
  assert.deepEqual(persistence.loadState(), previous);
});

test("unserialisable state does not change saved records", t => {
  const {store: persistence} = store(t);
  persistence.saveState(emptyState());
  const cycle = {};
  cycle.cycle = cycle;
  assert.throws(() => persistence.saveState(cycle), /serializar/);
  assert.deepEqual(persistence.loadState(), emptyState());
});

test("an incomplete persisted state fails closed instead of becoming empty", t => {
  const {store: persistence, db} = store(t);
  persistence.saveState(emptyState());
  db.exec("DELETE FROM especulador_chunks WHERE kind='state'");
  assert.throws(() => persistence.loadState(), /reconstruir/);
});

test("orphaned chunks cannot silently overwrite a damaged account", t => {
  const {store: persistence, db} = store(t);
  persistence.saveState(emptyState());
  db.exec("DELETE FROM especulador_meta WHERE kind='state'");
  assert.throws(() => persistence.loadState(), /incompletos/);
});

test("UTF-8 size metadata detects a changed saved payload", t => {
  const {store: persistence, db} = store(t);
  persistence.saveState(emptyState());
  db.exec("UPDATE especulador_chunks SET payload='{}' WHERE kind='state'");
  assert.throws(() => persistence.loadState(), /incompleta/);
});

test("a persisted null cannot be mistaken for a new empty account", t => {
  const {store: persistence, db} = store(t);
  persistence.saveState(emptyState());
  db.exec("UPDATE especulador_chunks SET payload='null' WHERE kind='state'");
  db.exec("UPDATE especulador_meta SET bytes=4 WHERE kind='state'");
  assert.throws(() => persistence.loadState(), /JSON no válido/);
});

test("the pre-restore backup is independent of the current account", t => {
  const {store: persistence} = store(t);
  const old = emptyState();
  old.settings.capitalCopper = 20000;
  persistence.snapshotBackup(old);
  persistence.saveState(emptyState());
  assert.deepEqual(persistence.loadPreviousBackup(), old);
  assert.deepEqual(persistence.loadState(), emptyState());
});

test("a failed backup replacement preserves the previous backup", t => {
  const fixture = store(t);
  const old = {version: 1, note: "Backup previo"};
  fixture.store.snapshotBackup(old);
  fixture.failOnPart(1);
  assert.throws(() => fixture.store.snapshotBackup({note: "x".repeat(CHUNK_BYTES * 2)}), /simulated SQLite/);
  fixture.failOnPart(null);
  assert.deepEqual(fixture.store.loadPreviousBackup(), old);
});

test("device listing and lookup never return stored token hashes or raw credentials", t => {
  const {store: persistence} = store(t);
  const hash = "a".repeat(64);
  const created = persistence.createDevice({id: "pc1", label: "PC principal", tokenHash: hash, createdAt: "2026-11-01T12:00:00Z"});
  assert.equal(created.id, "pc1");
  assert.equal(created.revoked, false);
  assert.equal(persistence.findDevice("b".repeat(64)), null);
  assert.equal(persistence.findDevice(hash).id, "pc1");
  for (const value of [created, persistence.listDevices(), persistence.findDevice(hash), persistence.loadState()]) {
    assert.ok(!JSON.stringify(value).includes(hash));
    assert.ok(!JSON.stringify(value).includes("tokenHash"));
  }
});

test("device revocation is persistent and prevents later last-seen updates", t => {
  const {store: persistence, ctx} = store(t);
  persistence.createDevice({id: "pc1", label: "PC", tokenHash: "a".repeat(64), createdAt: "2026-11-01T12:00:00Z"});
  assert.equal(persistence.markDeviceSeen("pc1", "2026-11-01T12:05:00Z"), true);
  assert.equal(persistence.listDevices()[0].lastSeenAt, "2026-11-01T12:05:00.000Z");
  assert.equal(persistence.revokeDevice("pc1"), true);
  assert.equal(persistence.revokeDevice("absent"), false);
  assert.equal(new Store(ctx).findDevice("a".repeat(64)).revoked, true);
  assert.equal(persistence.markDeviceSeen("pc1", "2026-11-01T12:10:00Z"), false);
});

test("raw-looking tokens, invalid labels and duplicated hashes cannot create devices", t => {
  const {store: persistence} = store(t);
  const value = {id: "pc", label: "PC", tokenHash: "a".repeat(64), createdAt: "2026-11-01T12:00:00Z"};
  assert.throws(() => persistence.createDevice({...value, tokenHash: "device-secret-raw-token"}), /SHA-256/);
  assert.throws(() => persistence.createDevice({...value, label: " "}), /Nombre/);
  persistence.createDevice(value);
  assert.throws(() => persistence.createDevice({...value, id: "pc2"}));
  assert.equal(persistence.listDevices().length, 1);
});

test("rate limits permit the configured number and reset only after the window", t => {
  const {store: persistence, ctx} = store(t);
  for (let attempt = 0; attempt < 8; attempt += 1) assert.equal(persistence.rateLimit("hashed-ip", 1000), true);
  assert.equal(new Store(ctx).rateLimit("hashed-ip", 1001), false);
  assert.equal(persistence.rateLimit("hashed-ip", 0), false);
  assert.equal(persistence.rateLimit("hashed-ip", 901000), true);
  persistence.resetRateLimit("hashed-ip");
  assert.equal(persistence.rateLimit("hashed-ip", 901001), true);
});

test("rate counters are isolated from devices and application exports", t => {
  const {store: persistence, db} = store(t);
  persistence.rateLimit("old-hashed-ip", 1000);
  persistence.rateLimit("other-hashed-ip", 4000000);
  assert.equal(db.prepare("SELECT count(*) AS n FROM especulador_rate_limits WHERE bucket_key='old-hashed-ip'").get().n, 0);
  assert.ok(!JSON.stringify(persistence.loadState()).includes("hashed-ip"));
  assert.deepEqual(persistence.listDevices(), []);
});

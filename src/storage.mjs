/** Durable Object SQLite persistence. Every public method is synchronous.
 *
 * Cloudflare limits one SQLite row/string to 2 MiB. Application state and the
 * pre-restore backup are therefore split at UTF-8 boundaries into <=512 KiB
 * rows and replaced in one transactionSync. No secrets are mixed into exports.
 */
import {emptyState} from "./engine.mjs";

export const CHUNK_BYTES = 512 * 1024;
export const MAX_STATE_BYTES = 16 * 1024 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", {fatal: true});

function requireText(value, label, maximum = 160) {
  if (typeof value !== "string" || !value.trim() || value.length > maximum || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new Error(`${label}: texto no válido.`);
  }
  return value.trim();
}

function requireTimestamp(value, label) {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) throw new Error(`${label}: fecha no válida.`);
  return new Date(value).toISOString();
}

function requireNumber(value, label, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${label}: entero no válido.`);
  return value;
}

function publicDevice(row) {
  if (!row) return null;
  return {id: row.id, label: row.label, createdAt: row.created_at,
    lastSeenAt: row.last_seen_at ?? null, revoked: Boolean(row.revoked)};
}

function serialise(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Los datos que se guardan deben ser un objeto.");
  let text;
  try { text = JSON.stringify(value); }
  catch { throw new Error("No se pueden serializar los datos para guardarlos."); }
  const bytes = encoder.encode(text);
  if (bytes.byteLength > MAX_STATE_BYTES) {
    const error = new Error("La cuenta supera el límite de 16 MiB de esta versión. Exporta una copia antes de ampliar el almacenamiento.");
    error.status = 507;
    throw error;
  }
  const chunks = [];
  let start = 0;
  while (start < bytes.byteLength) {
    let end = Math.min(start + CHUNK_BYTES, bytes.byteLength);
    // Do not split a multi-byte UTF-8 code point between two SQLite rows.
    while (end < bytes.byteLength && end > start && (bytes[end] & 0xc0) === 0x80) end -= 1;
    if (end === start) throw new Error("No se puede dividir el texto UTF-8 para guardarlo.");
    chunks.push(decoder.decode(bytes.subarray(start, end)));
    start = end;
  }
  return {chunks, bytes: bytes.byteLength};
}

export class Store {
  constructor(ctx) {
    if (!ctx?.storage?.sql?.exec || typeof ctx.storage.transactionSync !== "function") throw new Error("Se requiere almacenamiento SQLite de Durable Objects.");
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS especulador_chunks (
      kind TEXT NOT NULL, part INTEGER NOT NULL, payload TEXT NOT NULL,
      PRIMARY KEY(kind,part))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS especulador_meta (
      kind TEXT PRIMARY KEY, parts INTEGER NOT NULL, bytes INTEGER NOT NULL, schema_version INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS especulador_devices (
      id TEXT PRIMARY KEY, label TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL, last_seen_at TEXT, revoked INTEGER NOT NULL DEFAULT 0)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS especulador_rate_limits (
      bucket_key TEXT PRIMARY KEY, window_start INTEGER NOT NULL, attempts INTEGER NOT NULL)`);
    this.sql.exec("CREATE INDEX IF NOT EXISTS especulador_rate_window ON especulador_rate_limits(window_start)");
  }

  rows(query, ...bindings) {
    const cursor = this.sql.exec(query, ...bindings);
    return typeof cursor.toArray === "function" ? cursor.toArray() : Array.from(cursor);
  }

  load(kind) {
    const metadata = this.rows("SELECT parts,bytes,schema_version FROM especulador_meta WHERE kind=?", kind)[0];
    const rows = this.rows("SELECT part,payload FROM especulador_chunks WHERE kind=? ORDER BY part", kind);
    if (!metadata) {
      if (rows.length) throw new Error("Los datos guardados están incompletos. No se han sustituido por una cuenta vacía.");
      return null;
    }
    if (metadata.schema_version !== 1 || metadata.parts !== rows.length || metadata.bytes > MAX_STATE_BYTES ||
        rows.some((row, index) => row.part !== index || typeof row.payload !== "string")) {
      throw new Error("No se puede reconstruir la cuenta guardada. Conserva una copia antes de reparar el almacenamiento.");
    }
    const text = rows.map(row => row.payload).join("");
    if (encoder.encode(text).byteLength !== metadata.bytes) throw new Error("La copia guardada está incompleta.");
    try {
      const parsed = JSON.parse(text);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Invalid stored object");
      return parsed;
    } catch { throw new Error("El almacenamiento contiene JSON no válido. Los datos se conservan para su recuperación."); }
  }

  save(kind, value) {
    // All expensive serialisation and bounds checks happen before touching SQLite.
    const prepared = serialise(value);
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM especulador_chunks WHERE kind=?", kind);
      for (let part = 0; part < prepared.chunks.length; part += 1) {
        this.sql.exec("INSERT INTO especulador_chunks(kind,part,payload) VALUES (?,?,?)", kind, part, prepared.chunks[part]);
      }
      this.sql.exec("INSERT OR REPLACE INTO especulador_meta(kind,parts,bytes,schema_version) VALUES (?,?,?,1)", kind, prepared.chunks.length, prepared.bytes);
    });
    return {bytes: prepared.bytes, chunks: prepared.chunks.length};
  }

  loadState() { return this.load("state") ?? emptyState(); }
  saveState(state) { return this.save("state", state); }
  snapshotBackup(stateOrBackup) { return this.save("before_restore", stateOrBackup); }
  loadPreviousBackup() { return this.load("before_restore"); }

  createDevice({id, label, tokenHash, createdAt}) {
    id = requireText(id, "Identificador de dispositivo", 128);
    label = requireText(label, "Nombre de dispositivo", 80);
    if (typeof tokenHash !== "string" || !/^(?:[a-f\d]{64}|[A-Za-z\d_-]{43})$/i.test(tokenHash)) throw new Error("La clave del dispositivo debe guardarse como hash SHA-256.");
    createdAt = requireTimestamp(createdAt, "Creación de dispositivo");
    this.sql.exec("INSERT INTO especulador_devices(id,label,token_hash,created_at,last_seen_at,revoked) VALUES (?,?,?,?,NULL,0)", id, label, tokenHash, createdAt);
    return publicDevice(this.rows("SELECT * FROM especulador_devices WHERE id=?", id)[0]);
  }

  listDevices() {
    return this.rows("SELECT id,label,created_at,last_seen_at,revoked FROM especulador_devices ORDER BY created_at DESC,id").map(publicDevice);
  }

  findDevice(tokenHash) {
    if (typeof tokenHash !== "string") return null;
    return publicDevice(this.rows("SELECT id,label,created_at,last_seen_at,revoked FROM especulador_devices WHERE token_hash=?", tokenHash)[0]);
  }

  markDeviceSeen(id, timestamp) {
    id = requireText(id, "Identificador de dispositivo", 128);
    timestamp = requireTimestamp(timestamp, "Última sincronización");
    const device = this.rows("SELECT revoked FROM especulador_devices WHERE id=?", id)[0];
    if (!device || device.revoked) return false;
    this.sql.exec("UPDATE especulador_devices SET last_seen_at=? WHERE id=? AND revoked=0", timestamp, id);
    return true;
  }

  revokeDevice(id) {
    id = requireText(id, "Identificador de dispositivo", 128);
    if (!this.rows("SELECT id FROM especulador_devices WHERE id=?", id)[0]) return false;
    this.sql.exec("UPDATE especulador_devices SET revoked=1 WHERE id=?", id);
    return true;
  }

  rateLimit(key, nowMs, limit = 8, windowMs = 900000) {
    key = requireText(key, "Identificador de límite", 256);
    requireNumber(nowMs, "Fecha del límite");
    requireNumber(limit, "Intentos admitidos", 1, 1000000);
    requireNumber(windowMs, "Ventana de intentos", 1, 86400000);
    return this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM especulador_rate_limits WHERE window_start<?", nowMs - windowMs * 4);
      const prior = this.rows("SELECT window_start,attempts FROM especulador_rate_limits WHERE bucket_key=?", key)[0];
      const expired = prior && nowMs - prior.window_start >= windowMs;
      const start = !prior || expired ? nowMs : prior.window_start;
      const attempts = !prior || expired ? 0 : prior.attempts;
      if (attempts >= limit) return false;
      this.sql.exec("INSERT OR REPLACE INTO especulador_rate_limits(bucket_key,window_start,attempts) VALUES (?,?,?)", key, start, attempts + 1);
      return true;
    });
  }

  resetRateLimit(key) {
    key = requireText(key, "Identificador de límite", 256);
    this.sql.exec("DELETE FROM especulador_rate_limits WHERE bucket_key=?", key);
  }
}

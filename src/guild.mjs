/** Guild market ("Hermandad") for the Oro de Hermandad addon. The PCs that run the uploader send their
 * OroHermandadHist prices and the panel shows the merged market of the whole guild.
 *
 * Isolation: GuildMarket is its own Durable Object with its own SQLite, its own credential (personal gld_ member
 * keys, stored only as SHA-256), its own cookie and its own CSRF. It never reads or writes Portfolio data, and the
 * owner session only counts here as the guild owner. Money is integer copper and every market rule comes from
 * src/especular.mjs, the JS twin of the addon's Spec.lua (contract: test-vectors/especular-v1.json).
 *
 * Upload contract (pc_sync/hermandad.py -> POST /api/guild/sync, Authorization: Bearer gld_...), two schemas:
 *   schema 1 (uploader 0.3): {schema: 1, addon, markets: [{market: "<Reino>-Alliance|Horde", cut: bp|null, items: [{id,
 *    name, cat, vendor, days: [[d, lo, hi, last, qty, scans, "o"|"a"]], points: [[t, lo, qty, qty5]]}],
 *    deposits: [[id, dur, copper]]}]}
 *   schema 2 (uploader 0.4, relay-v1): {schema: 2, addon, markets: [{market, cut, items: [{id, name, cat, vendor}],
 *    deposits, observers: [{obs: "<8 hex>"|null, self: true|false, aliases?: ["<8 hex>"], items: [{id, days, points}]}]}]}
 * In schema 2 the self observer is the uploader's own characters (obs and aliases are their codes) and every other
 * observer is a guild mate whose whole Auctionator scans the uploader's addon received over the hidden addon channel.
 * An observer code is a pseudonymous FNV-1a hash of guild and character computed in the game: names never reach
 * the server, but the code is not anonymous (whoever knows the roster can recompute it).
 *
 * Observations are stored per observer slot (the member_id column of guild_obs_day/guild_obs_point): a member's id
 * for that member's own characters (legacy rows included), RELAYED_SLOT_BASE + n for a relayed mate. A mate's code
 * that later turns up as a member's own character is bound to that member. Day aggregates, counts and labels are per
 * person (personOf), so the same character sent by two uploaders counts once and lands in the same rows.
 * The whole body is validated before anything is written, and an identical body is recognised by its SHA-256. */
import {DAY0, LAUNCH, GUARD_DAYS, BUDGET, CUT_BP, PRICE_MAX, CATEGORIES, VERSION, median, quantile, dayIndex, mergeDay, dayValue,
  baseline, assess, flip, deltas, weekday, texts, idiv} from "./especular.mjs";

export const GUILD_ID = "guild-forever-eu-v1";
export const GUILD_COOKIE = "__Host-especulador_hermandad";
export const SESSION_SECONDS = 7 * 86400;
export const KEY_PATTERN = /^gld_[A-Za-z0-9_-]{43}$/;
export const LIMITS = Object.freeze({
  body: 2 * 1024 * 1024, adminBody: 4096, loginBody: 2048,
  keys: 50, members: 50, markets: 20, itemsPerMarket: 300,
  marketsPerUpload: 8, itemsPerUpload: 300, daysPerItem: 130, pointsPerItem: 130,
  uploadsPerDay: 24, syncPerHour: 60, loginAttempts: 8, loginWindowMs: 15 * 60000,
  retentionDays: 180, pointSeconds: 14 * 86400, pointsKept: 200,
  minDay: 2490, itemIdMax: 2147483647, qtyMax: 1000000, nameMax: 100, labelMax: 40, cacheBytes: 1536 * 1024,
  // A member's history reaches at most 30 days before their first upload to a market (a late joiner's 120 days
  // would cost as much as a week of everyone's uploads).
  backfillDays: 30,
  // Rows the guild may write per UTC day, index entries included, as Cloudflare counts them. The free plan allows
  // 100.000 per account and day, shared with Portfolio, so the guild keeps well below; GUILD_WRITE_ROWS_PER_DAY
  // raises it (Workers Paid).
  writeRowsPerDay: 40000,
  // The auction house cut a member reports counts only between 1 % and 20 %, and only once two members report one.
  cutMin: 100, cutMax: 2000, cutMembers: 2,
  // Relay (upload schema 2): per market one self observer and up to 60 guild mates, each with at most 9 alias codes
  // (alts on the uploader's account); a mate's series holds 20 days and 150 points; 8000 series per body.
  observersPerMarket: 61, aliases: 9, relayDaysPerItem: 20, relayPointsPerItem: 150, seriesPerUpload: 8000,
  // A mate's days count from T-14 (the whole baseline window); a market keeps at most 60 relayed persons seen in the
  // last 30 days, and the guild 2000 observer codes in all.
  relayDays: 14, relayedPerMarket: 60, relayActiveDays: 30, observersMax: 2000,
  // Relayed mates may use 75 % of the daily write budget (the rest waits for the next UTC day: CUOTA) and 12000 rows
  // per upload (the rest goes with the next upload: ENVIO).
  relayBudgetShare: 0.75, relayRowsPerUpload: 12000,
  // Freshness: who uploaded or was seen in the last 14 days.
  freshDays: 14
});
/** Slots at or above this number are relayed guild mates; member ids never reach it. */
export const RELAYED_SLOT_BASE = 1000000000;
const OBSERVER_PATTERN = /^[0-9a-f]{8}$/;
/** Duration (luaIndex 1..3) whose learned deposit the summary flips use: the longest, which is the 24 h listing that
 * the vendor estimate assumes and never understates the cost. The item route returns all three. */
export const RESALE_DURATION = 3;
const SUMMARY_VERSION = VERSION + ":resumen-2";

/** The fixed guild watchlist, the same 114 IDs as Data.WATCH in the addon (addon/OroHermandad/Data.lua). Its items
 * always have room in a market and are the only ones where weekday patterns are looked for. */
export const WATCHLIST = Object.freeze({
  metal: [2770, 2771, 2775, 2772, 2776, 3858, 7911, 10620, 2840, 3576, 2841, 2842, 3575, 3577, 3859, 3860, 6037, 12359, 12360],
  piedra: [2835, 2836, 2838, 7912, 12365],
  gema: [774, 818, 1210, 1206, 1705, 1529, 3864, 7909, 7910, 12361, 12363, 12364, 12799, 12800],
  hierba: [2447, 765, 2449, 785, 2450, 3820, 2453, 3355, 3356, 3369, 3357, 3818, 3821, 3358, 3819, 4625, 8831, 8836, 8838, 8839, 8845, 8846,
    13463, 13464, 13465, 13466, 13467, 13468],
  piel: [2934, 2318, 783, 2319, 4232, 4234, 4235, 4304, 8169, 8170, 8171, 15417],
  tela: [2589, 2592, 4306, 4338, 14047, 14256, 14342],
  pocion: [3928, 13446, 13444, 13442, 5634],
  elixir: [13452, 9187, 9206, 13454],
  frasco: [13510, 13511, 13512, 13513],
  comida: [13928, 13931, 18254],
  venda: [14529, 14530],
  encantar: [11137, 11176, 16204, 16203, 14344, 20725],
  elemental: [7076, 7078, 7080, 12808],
  otro: [12811]
});
const WATCH = new Map(Object.entries(WATCHLIST).flatMap(([cat, ids]) => ids.map(id => [id, cat])));
export const CATEGORY_LABELS = Object.freeze({metal: "Metal", piedra: "Piedra", gema: "Gema", hierba: "Hierba", piel: "Piel",
  tela: "Tela", pocion: "Poción", elixir: "Elixir", frasco: "Frasco", comida: "Comida", venda: "Venda",
  encantar: "Encantamiento", elemental: "Elemental", otro: "Otro"});
export const VERDICT_LABELS = Object.freeze({SIN_DATOS: "Aprendiendo", INESTABLE: "Inestable", SIN_PRECIO: "Sin precio hoy",
  FUERA_DE_RANGO: "Fuera de rango", BAJADA: "Bajada de nivel", PROTECCION: "Protección de lanzamiento", CHOLLO: "Chollo",
  CARO: "Caro", ESPERA: "Bajo: espera", NORMAL: "Normal"});
export const CONFIDENCE_LABELS = Object.freeze({ALTA: "Fiable", MEDIA: "Orientativo", BAJA: "Poco fiable"});
const WEEKDAYS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"];
const MARKET_PATTERN = /^[^|\u0000-\u001f\u007f]{1,64}-(?:Alliance|Horde)$/;
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;
const encoder = new TextEncoder();

// ---- Small shared helpers (kept local so this module stays independent of worker.mjs)
function json(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), {status, headers: {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store", ...extra}});
}
function fail(message, status = 400, headers = null) { const error = new Error(message); error.status = status; if (headers) error.headers = headers; throw error; }
const isInt = (x, lo, hi) => Number.isSafeInteger(x) && x >= lo && x <= hi;
const plainObject = value => !!value && typeof value === "object" && !Array.isArray(value);
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const iso = seconds => isInt(seconds, 0, 99999999999) ? new Date(seconds * 1000).toISOString() : null;
/** Calendar date (Spain, CET without DST, like the day index) of a day index. */
export function dateOfDay(d) { return new Date((DAY0 + d * 86400 + 3600) * 1000).toISOString().slice(0, 10); }
const dayStart = d => DAY0 + d * 86400;
/** Cloudflare's daily limits reset at 00:00 UTC, not at the guild's day change (00:00 CET). */
const utcDay = seconds => Math.floor(seconds / 86400);
/** The person an observer slot belongs to: a member slot is its member; a relayed slot its bound member, else itself.
 * persons: Map relayed slot -> member (GuildStore.persons()). */
const personOf = (persons, slot) => slot < RELAYED_SLOT_BASE ? slot : persons.get(slot) ?? slot;
const isMate = person => person >= RELAYED_SLOT_BASE;
const sameDay = (a, b) => a.lo === b.lo && a.hi === b.hi && a.last === b.last && a.qty === b.qty && a.scans === b.scans && a.src === b.src;
/** What a day aggregate depends on: a relayed day is only rewritten when one of these changes. */
const samePrice = (a, b) => a.lo === b.lo && a.hi === b.hi && a.qty === b.qty && a.src === b.src;
/** The addon's merge of two points of one observer at the same time: lo = min, qty = max, qty5 of the cheaper one. */
function mergePoint(a, b) {
  if (!a) return {t: b.t, lo: b.lo, qty: b.qty, qty5: b.qty5};
  const qty5 = b.lo < a.lo ? b.qty5 : b.lo === a.lo ? Math.max(a.qty5, b.qty5) : a.qty5;
  return {t: a.t, lo: Math.min(a.lo, b.lo), qty: Math.max(a.qty, b.qty), qty5};
}
const samePoint = (a, b) => a.lo === b.lo && a.qty === b.qty && a.qty5 === b.qty5;
/** A validated market of either schema as the store ingests it: item metadata, deposits and observers. Schema 1 has
 * one observer, the uploader's own characters, without codes. */
function observersOf(m) {
  if (Array.isArray(m.observers)) return m;
  return {market: m.market, cut: m.cut, deposits: m.deposits, items: m.items.map(({id, name, cat, vendor}) => ({id, name, cat, vendor})),
    observers: [{obs: null, self: true, aliases: [], items: m.items.map(({id, days, points}) => ({id, days, points}))}]};
}

async function readBody(request, limit, tooLarge = "Los datos superan el límite permitido.") {
  if (!request.body) fail("Faltan los datos de la petición.");
  const declared = Number(request.headers.get("Content-Length") || 0);
  if (declared > limit) fail(tooLarge, 413);
  const reader = request.body.getReader(), parts = [];
  let total = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) { await reader.cancel(); fail(tooLarge, 413); }
    parts.push(value);
  }
  const raw = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) { raw.set(part, offset); offset += part.byteLength; }
  return raw;
}
function parseObject(raw) {
  let value;
  try { value = JSON.parse(new TextDecoder("utf-8", {fatal: true}).decode(raw)); }
  catch { fail("Los datos no son un JSON válido."); }
  if (!plainObject(value)) fail("Se requiere un objeto JSON.");
  return value;
}
function base64url(bytes) { let text = ""; for (const byte of bytes) text += String.fromCharCode(byte); return btoa(text).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_"); }
function unbase64(text) { if (!/^[A-Za-z0-9_-]+$/.test(text)) throw new Error("base64"); const value = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - text.length % 4) % 4)); return Uint8Array.from(value, c => c.charCodeAt(0)); }
function randomToken() { return base64url(crypto.getRandomValues(new Uint8Array(32))); }
async function sha256(data) {
  const bytes = typeof data === "string" ? encoder.encode(data) : data;
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), byte => byte.toString(16).padStart(2, "0")).join("");
}
function equal(a, b) { if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false; let diff = 0; for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i); return diff === 0; }

// ---- Guild cookie: HMAC like the owner session, but with its own prefix, name, lifetime and CSRF.
async function guildSign(text, env) {
  const secret = (env.SESSION_SECRET || "") + ":" + env.OWNER_PASSWORD;
  const key = await crypto.subtle.importKey("raw", encoder.encode("especulador-guild-v1:" + secret), {name: "HMAC", hash: "SHA-256"}, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(text))));
}
export async function issueGuildSession(env, {memberId, keyId}, nowMs = Date.now()) {
  const payload = base64url(encoder.encode(JSON.stringify({v: 1, exp: Math.floor(nowMs / 1000) + SESSION_SECONDS, nonce: randomToken(), m: memberId, k: keyId})));
  const value = payload + "." + await guildSign(payload, env);
  return {value, csrf: await guildSign("csrf:" + value, env)};
}
/** The signed guild cookie of a request, or null. Revocation is checked afterwards by the Durable Object. */
export async function readGuildSession(request, env, nowMs = Date.now()) {
  const cookie = request.headers.get("Cookie") || "";
  const value = cookie.split(";").map(v => v.trim()).find(v => v.startsWith(GUILD_COOKIE + "="))?.slice(GUILD_COOKIE.length + 1);
  if (!value || value.length > 1200) return null;
  try {
    const [payload, signature, extra] = value.split(".");
    if (extra !== undefined || !signature || !equal(signature, await guildSign(payload, env))) return null;
    const parsed = JSON.parse(new TextDecoder().decode(unbase64(payload)));
    const now = Math.floor(nowMs / 1000);
    if (parsed.v !== 1 || !Number.isSafeInteger(parsed.exp) || parsed.exp <= now || parsed.exp > now + SESSION_SECONDS ||
        typeof parsed.nonce !== "string" || parsed.nonce.length !== 43 || !isInt(parsed.m, 1, Number.MAX_SAFE_INTEGER) ||
        !isInt(parsed.k, 1, Number.MAX_SAFE_INTEGER)) return null;
    return {memberId: parsed.m, keyId: parsed.k, value, csrf: await guildSign("csrf:" + value, env)};
  } catch { return null; }
}
const setCookie = value => `${GUILD_COOKIE}=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_SECONDS}`;
const clearCookie = `${GUILD_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`;
function originCheck(request) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) fail("Origen de petición no válido.", 403);
  if (request.headers.get("Sec-Fetch-Site") === "cross-site") fail("Origen de petición no válido.", 403);
}

// ---- Worker side: authentication and forwarding. Called by worker.mjs for every /api/guild/* path.
const ROUTES = new Map([
  ["POST /api/guild/sync", "key"], ["POST /api/guild/login", "public"], ["POST /api/guild/logout", "session"],
  ["GET /api/guild/me", "session"], ["GET /api/guild/market", "session"], ["GET /api/guild/item", "session"],
  ["GET /api/guild/export.csv", "session"], ["GET /api/guild/download/sincronizador", "session"],
  ["GET /api/guild/members", "session"], ["POST /api/guild/members", "session"], ["POST /api/guild/members/role", "session"],
  ["POST /api/guild/members/revoke", "session"], ["POST /api/guild/keys", "session"], ["POST /api/guild/keys/revoke", "session"]
]);
const PATHS = new Set([...ROUTES.keys()].map(route => route.slice(route.indexOf(" ") + 1)));
const stub = env => env.GUILD.get(env.GUILD.idFromName(GUILD_ID));
// A fresh request to the Durable Object: no client header (Cookie, Authorization, X-Guild-*) ever reaches it.
function internal(env, path, {method = "GET", search = "", actor, headers = {}, body} = {}) {
  const h = new Headers(headers);
  if (actor) h.set("X-Guild-Actor", JSON.stringify(actor));
  return stub(env).fetch(new Request("https://guild.internal" + path + search, {method, headers: h, ...(body !== undefined && body !== null ? {body, duplex: "half"} : {})}));
}
function passBody(request) {
  const headers = {"Content-Type": "application/json"};
  for (const name of ["Content-Length", "Content-Encoding"]) { const value = request.headers.get(name); if (value) headers[name] = value; }
  return headers;
}

/** Handles /api/guild/*. ownerSession() resolves the existing owner cookie (worker.mjs readSession), which counts as
 * the guild owner. The owner wins when both cookies are present. */
export async function guildFetch(request, env, {ownerSession} = {}) {
  const url = new URL(request.url), path = url.pathname;
  if (!env.GUILD) return json({error: "Hermandad no configurada."}, 503);
  const access = ROUTES.get(request.method + " " + path);
  if (!access) return PATHS.has(path) ? json({error: "Método no admitido."}, 405) : json({error: "Ruta no encontrada."}, 404);
  if (access === "key") {
    const token = request.headers.get("Authorization")?.match(/^Bearer (gld_[A-Za-z0-9_-]{43})$/)?.[1];
    if (!token) return json({error: "Clave de la hermandad no válida."}, 401);
    return internal(env, "/api/guild/sync", {method: "POST", headers: {...passBody(request), "X-Member-Hash": await sha256(token)}, body: request.body});
  }
  if (access === "public") {
    originCheck(request);
    const ip = await sha256("guild-login:" + (request.headers.get("CF-Connecting-IP") || "unknown"));
    const data = parseObject(await readBody(request, LIMITS.loginBody));
    const key = typeof data.key === "string" ? data.key.trim() : "";
    const keyHash = KEY_PATTERN.test(key) ? await sha256(key) : null;
    const answer = await internal(env, "/internal/login", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({ip, keyHash})});
    if (!answer.ok) return answer;
    const member = await answer.json();
    const session = await issueGuildSession(env, {memberId: member.id, keyId: member.keyId});
    return json({ok: true, member: {id: member.id, label: member.label, role: member.role}, csrf: session.csrf}, 200, {"Set-Cookie": setCookie(session.value)});
  }
  const owner = ownerSession ? await ownerSession() : null;
  const guest = owner ? null : await readGuildSession(request, env);
  const who = owner ? {actor: {kind: "owner"}, csrf: await guildSign("owner-csrf:" + owner.value, env)}
    : guest ? {actor: {kind: "member", memberId: guest.memberId, keyId: guest.keyId}, csrf: guest.csrf} : null;
  if (!who) return json({error: "Inicia sesión con tu clave de la hermandad."}, 401, request.headers.get("Cookie")?.includes(GUILD_COOKIE + "=") ? {"Set-Cookie": clearCookie} : {});
  if (request.method !== "GET") {
    originCheck(request);
    if (!equal(request.headers.get("X-CSRF-Token"), who.csrf)) return json({error: "La sesión ha cambiado. Recarga la página."}, 403);
  }
  if (path === "/api/guild/logout") return json({ok: true}, 200, {"Set-Cookie": clearCookie});
  const response = await internal(env, path, {method: request.method, search: url.search, actor: who.actor,
    ...(request.method === "POST" ? {headers: passBody(request), body: request.body} : {})});
  if (response.status === 401 && who.actor.kind === "member") {
    const headers = new Headers(response.headers);
    headers.set("Set-Cookie", clearCookie);
    return new Response(response.body, {status: 401, headers});
  }
  if (!response.ok) return response;
  if (path === "/api/guild/me") return json({...await response.json(), csrf: who.csrf});
  if (path === "/api/guild/download/sincronizador") {
    const asset = await env.ASSETS.fetch(new Request(url.origin + "/downloads/Sincronizador_PC.zip", {method: "GET"}));
    const headers = new Headers(asset.headers);
    headers.set("Content-Disposition", 'attachment; filename="Sincronizador_PC.zip"');
    return new Response(asset.body, {status: asset.status, headers});
  }
  return response;
}

// ---- Upload validation (schemas 1 and 2). Throws a 400 naming the first problem; returns a normalised copy.
/** data: the parsed body. today: day index of now; nowSec: unix seconds. Unknown keys are ignored. Schema 1 comes back
 * exactly as it was sent; schema 2 with the self observer first and the mates ordered by code. */
export function validateUpload(data, {today, nowSec}) {
  const bad = (where, what) => fail(`Envío no válido${where ? ` (${where})` : ""}: ${what}.`);
  if (!plainObject(data)) bad("", "se esperaba un objeto JSON");
  if (data.schema !== 1 && data.schema !== 2) bad("", "schema debe ser 1 o 2");
  const relay = data.schema === 2;
  if (typeof data.addon !== "string" || !/^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$/.test(data.addon)) bad("", "addon debe ser la versión del addon, como \"0.3.0\"");
  if (!Array.isArray(data.markets) || data.markets.length > LIMITS.marketsPerUpload) bad("", `markets debe ser una lista de ${LIMITS.marketsPerUpload} mercados como máximo`);
  const maxDay = today + 1, maxTime = nowSec + 86400, seen = new Set();
  const price = `un entero entre 1 y ${PRICE_MAX} cobre`, qty = `un entero entre 0 y ${LIMITS.qtyMax}`;
  let series = 0;
  // The days and points of one series: an item of schema 1, or an item of one observer of schema 2. own: the
  // uploader's characters (a mate's days are always own scans, never Auctionator imports).
  const daysOf = (list, at, max, own) => {
    if (!Array.isArray(list) || list.length > max) bad(at, `days debe ser una lista de ${max} días como máximo`);
    let previous = -Infinity;
    return list.map((r, ri) => {
      const here = `${at}, día n.º ${ri + 1}`;
      if (!Array.isArray(r) || r.length !== 7) bad(here, "cada día es [d, lo, hi, last, qty, scans, src]");
      const [d, lo, hi, last, quantity, scans, src] = r;
      if (!isInt(d, 0, maxDay)) bad(here, `d debe ser un índice de día entre 0 y ${maxDay} (mañana)`);
      if (d <= previous) bad(here, "los días deben ir en orden ascendente y sin repetirse");
      previous = d;
      if (!isInt(lo, 1, PRICE_MAX) || !isInt(hi, 1, PRICE_MAX) || !isInt(last, 1, PRICE_MAX)) bad(here, `lo, hi y last deben ser ${price}`);
      if (lo > hi) bad(here, "lo no puede ser mayor que hi");
      if (!isInt(quantity, 0, LIMITS.qtyMax) || !isInt(scans, 0, LIMITS.qtyMax)) bad(here, `qty y scans deben ser ${qty}`);
      if (src !== "o" && src !== "a") bad(here, "src debe ser \"o\" o \"a\"");
      if (!own && src !== "o") bad(here, "los días de un compañero deben ser propios (src \"o\")");
      return {d, lo, hi, last, qty: quantity, scans, src};
    });
  };
  const pointsOf = (list, at, max) => {
    if (!Array.isArray(list) || list.length > max) bad(at, `points debe ser una lista de ${max} puntos como máximo`);
    let previous = -Infinity;
    return list.map((r, ri) => {
      const here = `${at}, punto n.º ${ri + 1}`;
      if (!Array.isArray(r) || r.length !== 4) bad(here, "cada punto es [t, lo, qty, qty5]");
      const [t, lo, quantity, qty5] = r;
      if (!isInt(t, DAY0, maxTime)) bad(here, `t debe ser una hora unix entre ${DAY0} y ${maxTime} (mañana)`);
      if (t <= previous) bad(here, "los puntos deben ir en orden ascendente y sin repetirse");
      previous = t;
      if (!isInt(lo, 1, PRICE_MAX)) bad(here, `lo debe ser ${price}`);
      if (!isInt(quantity, 0, LIMITS.qtyMax) || !isInt(qty5, 0, LIMITS.qtyMax)) bad(here, `qty y qty5 deben ser ${qty}`);
      return {t, lo, qty: quantity, qty5};
    });
  };
  const code = value => typeof value === "string" && OBSERVER_PATTERN.test(value);
  const markets = data.markets.map((m, mi) => {
    let where = `mercado n.º ${mi + 1}`;
    if (!plainObject(m)) bad(where, "se esperaba un objeto");
    if (typeof m.market !== "string" || !MARKET_PATTERN.test(m.market)) bad(where, "market debe ser \"Reino-Alliance\" o \"Reino-Horde\" (reino de 64 caracteres como máximo, sin «|»)");
    where = `mercado ${m.market}`;
    if (seen.has(m.market)) bad(where, "mercado repetido");
    seen.add(m.market);
    if (m.cut !== undefined && m.cut !== null && !isInt(m.cut, 0, 9999)) bad(where, "cut debe ser null o un entero entre 0 y 9999");
    if (!Array.isArray(m.items) || m.items.length > LIMITS.itemsPerUpload) bad(where, `items debe ser una lista de ${LIMITS.itemsPerUpload} objetos como máximo`);
    const ids = new Set();
    const items = m.items.map((item, ii) => {
      let at = `${where}, objeto n.º ${ii + 1}`;
      if (!plainObject(item)) bad(at, "se esperaba un objeto");
      if (!isInt(item.id, 1, LIMITS.itemIdMax)) bad(at, "id debe ser un entero positivo");
      at = `${where}, objeto ${item.id}`;
      if (ids.has(item.id)) bad(at, "objeto repetido");
      ids.add(item.id);
      if (typeof item.name !== "string" || [...item.name].length > LIMITS.nameMax || CONTROL.test(item.name)) bad(at, `name debe ser un texto de ${LIMITS.nameMax} caracteres como máximo, sin caracteres de control`);
      if (!CATEGORIES.includes(item.cat)) bad(at, `cat debe ser una de estas categorías: ${CATEGORIES.join(", ")}`);
      if (!isInt(item.vendor, 0, PRICE_MAX)) bad(at, `vendor debe ser un entero entre 0 y ${PRICE_MAX} cobre`);
      // Schema 2 keeps the metadata here and the series in observers.
      if (relay) return {id: item.id, name: item.name, cat: item.cat, vendor: item.vendor};
      return {id: item.id, name: item.name, cat: item.cat, vendor: item.vendor,
        days: daysOf(item.days, at, LIMITS.daysPerItem, true), points: pointsOf(item.points, at, LIMITS.pointsPerItem)};
    });
    const deposits = m.deposits === undefined ? [] : m.deposits;
    if (!Array.isArray(deposits) || deposits.length > LIMITS.itemsPerUpload * 9) bad(where, `deposits debe ser una lista de ${LIMITS.itemsPerUpload * 9} depósitos como máximo`);
    const pairs = new Set();
    const out = {market: m.market, cut: isInt(m.cut, 0, 9999) ? m.cut : null, items, deposits: deposits.map((r, ri) => {
      const here = `${where}, depósito n.º ${ri + 1}`;
      if (!Array.isArray(r) || r.length !== 3) bad(here, "cada depósito es [id, dur, copper]");
      const [id, dur, copper] = r;
      if (!isInt(id, 1, LIMITS.itemIdMax) || !isInt(dur, 1, 9) || !isInt(copper, 0, PRICE_MAX)) bad(here, `id positivo, dur entre 1 y 9 y copper entre 0 y ${PRICE_MAX}`);
      if (pairs.has(id + ":" + dur)) bad(here, "depósito repetido");
      pairs.add(id + ":" + dur);
      return {id, dur, copper};
    })};
    if (!relay) return out;
    if (!Array.isArray(m.observers) || m.observers.length > LIMITS.observersPerMarket) bad(where, `observers debe ser una lista de ${LIMITS.observersPerMarket} observadores como máximo (schema 2)`);
    let own = null;
    const mates = [];
    m.observers.forEach((o, oi) => {
      const here = `${where}, observador n.º ${oi + 1}`;
      if (!plainObject(o)) bad(here, "se esperaba un objeto");
      if (typeof o.self !== "boolean") bad(here, "self debe ser true o false");
      if (o.self && own) bad(here, "solo puede haber un observador con self: true");
      if (!(code(o.obs) || (o.self && o.obs === null))) bad(here, "obs debe ser un código de 8 cifras hexadecimales en minúsculas" + (o.self ? " o null" : ""));
      let aliases = [];
      if (!o.self && o.aliases !== undefined) bad(here, "aliases solo puede ir en el observador con self: true");
      if (o.self && o.aliases !== undefined) {
        if (!Array.isArray(o.aliases) || o.aliases.length > LIMITS.aliases) bad(here, `aliases debe ser una lista de ${LIMITS.aliases} códigos como máximo`);
        if (!o.aliases.every(code)) bad(here, "cada alias debe ser un código de 8 cifras hexadecimales en minúsculas");
        if (o.aliases.length && o.obs === null) bad(here, "aliases necesita un obs");
        if (new Set([o.obs, ...o.aliases]).size !== o.aliases.length + 1) bad(here, "los códigos de obs y aliases no pueden repetirse");
        aliases = [...o.aliases];
      }
      if (!Array.isArray(o.items) || o.items.length > LIMITS.itemsPerUpload) bad(here, `items debe ser una lista de ${LIMITS.itemsPerUpload} series como máximo`);
      const isOwn = o.self, inSeries = new Set();
      const list = o.items.map((s, si) => {
        let at = `${here}, serie n.º ${si + 1}`;
        if (!plainObject(s)) bad(at, "se esperaba un objeto");
        if (!isInt(s.id, 1, LIMITS.itemIdMax)) bad(at, "id debe ser un entero positivo");
        if (!ids.has(s.id)) bad(here, `el objeto ${s.id} no está en items del mercado`);
        at = `${here}, objeto ${s.id}`;
        if (inSeries.has(s.id)) bad(at, "objeto repetido");
        inSeries.add(s.id);
        if (++series > LIMITS.seriesPerUpload) bad("", `el envío no puede llevar más de ${LIMITS.seriesPerUpload} series`);
        return {id: s.id, days: daysOf(s.days, at, isOwn ? LIMITS.daysPerItem : LIMITS.relayDaysPerItem, isOwn),
          points: pointsOf(s.points, at, isOwn ? LIMITS.pointsPerItem : LIMITS.relayPointsPerItem)};
      });
      const observer = {obs: o.obs, self: o.self, aliases, items: list};
      if (o.self) own = observer; else mates.push([oi, observer]);
    });
    // A mate is listed once and is never one of the uploader's own characters.
    const mine = new Set(own ? [own.obs, ...own.aliases].filter(Boolean) : []), codes = new Set();
    for (const [oi, observer] of mates) {
      const here = `${where}, observador n.º ${oi + 1}`;
      if (codes.has(observer.obs)) bad(here, "observador repetido");
      if (mine.has(observer.obs)) bad(here, "un compañero no puede ser uno de los personajes de self");
      codes.add(observer.obs);
    }
    mates.sort((x, y) => x[1].obs < y[1].obs ? -1 : 1);
    return {...out, observers: [...(own ? [own] : []), ...mates.map(([, observer]) => observer)]};
  });
  return {schema: data.schema, addon: data.addon, markets};
}

// ---- CSV for Spanish Excel: UTF-8 BOM, ";" separator, decimal comma, CRLF.
/** Copper as gold with a decimal comma: 12345 -> "1,2345", 10000 -> "1", 50 -> "0,005"; "" for no value. */
export function goldCell(copper) {
  if (!Number.isSafeInteger(copper)) return "";
  const sign = copper < 0 ? "-" : "", abs = Math.abs(copper), fraction = String(abs % 10000).padStart(4, "0").replace(/0+$/, "");
  return sign + Math.floor(abs / 10000) + (fraction ? "," + fraction : "");
}
/** Basis points as a percentage with a decimal comma: -1234 -> "-12,34", 50 -> "0,5"; "" for no value. */
export function pctCell(bp) {
  if (!Number.isSafeInteger(bp)) return "";
  const sign = bp < 0 ? "-" : "", abs = Math.abs(bp), fraction = String(abs % 100).padStart(2, "0").replace(/0+$/, "");
  return sign + Math.floor(abs / 100) + (fraction ? "," + fraction : "");
}
/** A text cell: quoted when needed, and prefixed with ' when Excel would read it as a formula. */
export function textCell(value) {
  let text = value === null || value === undefined ? "" : String(value);
  if (/^[=+\-@\t\r]/.test(text)) text = "'" + text;
  return /[;"\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}
const intCell = value => Number.isSafeInteger(value) ? String(value) : "";
const csvText = rows => "\uFEFF" + rows.map(row => row.join(";")).join("\r\n") + "\r\n";

// ---- SQLite persistence. Every method is synchronous; writes that belong together run in one transactionSync.
export class GuildStore {
  constructor(ctx) {
    if (!ctx?.storage?.sql?.exec || typeof ctx.storage.transactionSync !== "function") throw new Error("Se requiere almacenamiento SQLite de Durable Objects.");
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    this.unsaved = 0;
    for (const statement of [
      `CREATE TABLE IF NOT EXISTS guild_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
      `CREATE TABLE IF NOT EXISTS guild_members (id INTEGER PRIMARY KEY, label TEXT NOT NULL, label_key TEXT NOT NULL UNIQUE,
        role TEXT NOT NULL CHECK (role IN ('admin','member')), created_at INTEGER NOT NULL, created_by TEXT NOT NULL, revoked_at INTEGER)`,
      `CREATE TABLE IF NOT EXISTS guild_keys (id INTEGER PRIMARY KEY, member_id INTEGER NOT NULL, token_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL, last_upload_at INTEGER, last_login_at INTEGER, revoked_at INTEGER)`,
      `CREATE TABLE IF NOT EXISTS guild_uploads (member_id INTEGER NOT NULL, sha256 TEXT NOT NULL, key_id INTEGER NOT NULL,
        received_at INTEGER NOT NULL, day INTEGER NOT NULL, bytes INTEGER NOT NULL, rows_changed INTEGER NOT NULL, PRIMARY KEY (member_id, sha256))`,
      `CREATE INDEX IF NOT EXISTS guild_uploads_day ON guild_uploads(member_id, day)`,
      // since: the oldest day this member may store in the market (LIMITS.backfillDays before their first upload).
      `CREATE TABLE IF NOT EXISTS guild_member_markets (market TEXT NOT NULL, member_id INTEGER NOT NULL, cut INTEGER, addon TEXT NOT NULL,
        last_upload_at INTEGER NOT NULL, since INTEGER NOT NULL, PRIMARY KEY (market, member_id))`,
      // name_by: the member whose upload gave the shared name (the first non-empty one); a purge of that member clears it.
      // vendor: the lower median of guild_item_vendor, kept here so every read stays one row per item.
      `CREATE TABLE IF NOT EXISTS guild_items (market TEXT NOT NULL, item_id INTEGER NOT NULL, name TEXT NOT NULL, category TEXT NOT NULL,
        vendor INTEGER NOT NULL, watch INTEGER NOT NULL, first_seen INTEGER NOT NULL, name_by INTEGER, PRIMARY KEY (market, item_id))`,
      `CREATE TABLE IF NOT EXISTS guild_item_vendor (market TEXT NOT NULL, member_id INTEGER NOT NULL, item_id INTEGER NOT NULL,
        vendor INTEGER NOT NULL, PRIMARY KEY (market, member_id, item_id))`,
      `CREATE INDEX IF NOT EXISTS guild_item_vendor_item ON guild_item_vendor(market, item_id)`,
      `CREATE TABLE IF NOT EXISTS guild_obs_day (market TEXT NOT NULL, member_id INTEGER NOT NULL, item_id INTEGER NOT NULL, day INTEGER NOT NULL,
        lo INTEGER NOT NULL, hi INTEGER NOT NULL, last INTEGER NOT NULL, qty INTEGER NOT NULL, scans INTEGER NOT NULL,
        src TEXT NOT NULL CHECK (src IN ('o','a')), updated_at INTEGER NOT NULL, PRIMARY KEY (market, member_id, item_id, day))`,
      `CREATE INDEX IF NOT EXISTS guild_obs_day_item ON guild_obs_day(market, item_id, day)`,
      `CREATE TABLE IF NOT EXISTS guild_obs_point (market TEXT NOT NULL, member_id INTEGER NOT NULL, item_id INTEGER NOT NULL, t INTEGER NOT NULL,
        lo INTEGER NOT NULL, qty INTEGER NOT NULL, qty5 INTEGER NOT NULL, PRIMARY KEY (market, member_id, item_id, t))`,
      // Points are the most written rows (every scan), so they get one secondary index only; each index costs writes.
      `CREATE INDEX IF NOT EXISTS guild_obs_point_time ON guild_obs_point(market, t)`,
      `CREATE TABLE IF NOT EXISTS guild_deposits (market TEXT NOT NULL, member_id INTEGER NOT NULL, item_id INTEGER NOT NULL, duration INTEGER NOT NULL,
        copper INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (market, member_id, item_id, duration))`,
      `CREATE TABLE IF NOT EXISTS guild_day_agg (market TEXT NOT NULL, item_id INTEGER NOT NULL, day INTEGER NOT NULL, v INTEGER NOT NULL,
        lo INTEGER NOT NULL, hi INTEGER NOT NULL, qty INTEGER, observers INTEGER NOT NULL, members TEXT NOT NULL, PRIMARY KEY (market, item_id, day))`,
      `CREATE INDEX IF NOT EXISTS guild_day_agg_day ON guild_day_agg(market, day)`,
      `CREATE TABLE IF NOT EXISTS guild_summary_cache (market TEXT PRIMARY KEY, day INTEGER NOT NULL, version TEXT NOT NULL,
        computed_at INTEGER NOT NULL, payload TEXT NOT NULL)`,
      `CREATE TABLE IF NOT EXISTS guild_rate_limits (bucket_key TEXT PRIMARY KEY, window_start INTEGER NOT NULL, attempts INTEGER NOT NULL)`,
      // One row: the UTC day and the rows the guild wrote on it (see LIMITS.writeRowsPerDay).
      `CREATE TABLE IF NOT EXISTS guild_write_budget (day INTEGER PRIMARY KEY, written INTEGER NOT NULL)`,
      `CREATE INDEX IF NOT EXISTS guild_rate_window ON guild_rate_limits(window_start)`,
      `INSERT OR IGNORE INTO guild_meta(key, value) VALUES ('schema', '1')`,
      // Relay (schema 2 of the database). Observer codes (pseudonymous hashes computed in the game, never names) and
      // their slot; member_id is the member a code belongs to (its own characters), NULL for a guild mate not bound.
      `CREATE TABLE IF NOT EXISTS guild_observers (hash TEXT PRIMARY KEY, slot INTEGER NOT NULL, member_id INTEGER,
        first_seen INTEGER NOT NULL, first_by INTEGER NOT NULL, bound_at INTEGER)`,
      `CREATE INDEX IF NOT EXISTS guild_observers_slot ON guild_observers(slot)`,
      // Where and when a relayed observer was last seen (its newest stored point or day), for the freshness counts.
      `CREATE TABLE IF NOT EXISTS guild_observer_markets (market TEXT NOT NULL, slot INTEGER NOT NULL, first_day INTEGER NOT NULL,
        last_seen INTEGER NOT NULL, last_by INTEGER NOT NULL, PRIMARY KEY (market, slot))`
    ]) this.sql.exec(statement);
    this.migrate();
  }
  /** Database schema 1 -> 2, once and atomically: every row an upload writes records its uploader (uploaded_by; NULL
   * on older rows means the slot's own member). Additive only: no row or column is changed or removed, so data
   * written by the previous code stays where it is, and the wrangler migrations are untouched. */
  migrate() {
    const schema = () => this.rows("SELECT value FROM guild_meta WHERE key='schema'")[0]?.value;
    if (schema() !== "1") return;
    this.transaction(() => {
      if (schema() !== "1") return;
      this.run("ALTER TABLE guild_obs_day ADD COLUMN uploaded_by INTEGER");
      this.run("ALTER TABLE guild_obs_point ADD COLUMN uploaded_by INTEGER");
      this.run("UPDATE guild_meta SET value='2' WHERE key='schema'");
    });
  }

  /** Every statement runs to the end and its cursor.rowsWritten (Cloudflare's billed rows, index entries included) is
   * added to `unsaved` until saveWrites() adds it to the day's counter. A cursor without rowsWritten counts nothing. */
  rows(query, ...bindings) {
    const cursor = this.sql.exec(query, ...bindings);
    const out = typeof cursor.toArray === "function" ? cursor.toArray() : Array.from(cursor);
    if (Number.isSafeInteger(cursor.rowsWritten) && cursor.rowsWritten > 0) this.unsaved += cursor.rowsWritten;
    return out;
  }
  run(query, ...bindings) { this.rows(query, ...bindings); }
  transaction(callback) { return this.ctx.storage.transactionSync(callback); }

  rateLimit(key, nowMs, limit, windowMs) {
    return this.transaction(() => {
      this.run("DELETE FROM guild_rate_limits WHERE window_start<?", nowMs - 4 * 86400000);
      const prior = this.rows("SELECT window_start,attempts FROM guild_rate_limits WHERE bucket_key=?", key)[0];
      const expired = prior && nowMs - prior.window_start >= windowMs;
      const start = !prior || expired ? nowMs : prior.window_start, attempts = !prior || expired ? 0 : prior.attempts;
      if (attempts >= limit) return false;
      this.run("INSERT OR REPLACE INTO guild_rate_limits(bucket_key,window_start,attempts) VALUES (?,?,?)", key, start, attempts + 1);
      return true;
    });
  }
  resetRateLimit(key) { this.run("DELETE FROM guild_rate_limits WHERE bucket_key=?", key); }

  // ---- Members and keys
  keyByHash(hash) {
    if (typeof hash !== "string" || !/^[a-f0-9]{64}$/.test(hash)) return null;
    const row = this.rows(`SELECT k.id AS key_id, k.revoked_at AS key_revoked, m.id, m.label, m.role, m.revoked_at AS member_revoked
      FROM guild_keys k JOIN guild_members m ON m.id=k.member_id WHERE k.token_hash=?`, hash)[0];
    return row ? {keyId: row.key_id, memberId: row.id, label: row.label, role: row.role, revoked: row.key_revoked !== null || row.member_revoked !== null} : null;
  }
  /** The caller identity forwarded by the worker, re-checked against revocation on every request. */
  actor(header) {
    let data = null;
    try { data = JSON.parse(header || "null"); } catch { data = null; }
    if (data?.kind === "owner") return {kind: "owner", role: "owner", memberId: null, keyId: null, label: "Propietario"};
    if (data?.kind === "member" && isInt(data.memberId, 1, Number.MAX_SAFE_INTEGER) && isInt(data.keyId, 1, Number.MAX_SAFE_INTEGER)) {
      const row = this.rows(`SELECT m.label, m.role, m.revoked_at AS member_revoked, k.revoked_at AS key_revoked
        FROM guild_keys k JOIN guild_members m ON m.id=k.member_id WHERE k.id=? AND m.id=?`, data.keyId, data.memberId)[0];
      if (row && row.member_revoked === null && row.key_revoked === null) return {kind: "member", role: row.role, memberId: data.memberId, keyId: data.keyId, label: row.label};
      fail("Tu acceso a la hermandad se ha revocado. Pide una clave nueva a quien administra la hermandad.", 401);
    }
    fail("Inicia sesión con tu clave de la hermandad.", 401);
  }
  member(id) { return this.rows("SELECT id,label,role,revoked_at FROM guild_members WHERE id=?", id)[0] || null; }
  activeKeys() { return this.rows("SELECT count(*) AS n FROM guild_keys k JOIN guild_members m ON m.id=k.member_id WHERE k.revoked_at IS NULL AND m.revoked_at IS NULL")[0].n; }
  listMembers() {
    const members = this.rows(`SELECT id,label,role,created_at,revoked_at FROM guild_members ORDER BY created_at,id`);
    const keys = this.rows(`SELECT id,member_id,created_at,last_upload_at,last_login_at,revoked_at FROM guild_keys ORDER BY created_at,id`);
    // How many character codes each member's uploads bound to them (the codes themselves are never shown).
    const characters = new Map(this.rows("SELECT member_id,count(*) AS n FROM guild_observers WHERE member_id IS NOT NULL GROUP BY member_id").map(r => [r.member_id, r.n]));
    const out = members.map(m => {
      const own = keys.filter(k => k.member_id === m.id).map(k => ({id: k.id, createdAt: iso(k.created_at), lastUploadAt: iso(k.last_upload_at),
        lastLoginAt: iso(k.last_login_at), revoked: k.revoked_at !== null || m.revoked_at !== null, revokedAt: iso(k.revoked_at ?? m.revoked_at)}));
      const last = Math.max(0, ...keys.filter(k => k.member_id === m.id).map(k => k.last_upload_at ?? 0));
      return {id: m.id, label: m.label, role: m.role, createdAt: iso(m.created_at), revoked: m.revoked_at !== null, revokedAt: iso(m.revoked_at),
        lastUploadAt: last ? iso(last) : null, activeKeys: own.filter(k => !k.revoked).length, characters: characters.get(m.id) ?? 0, keys: own};
    });
    return {members: out, activeMembers: out.filter(m => !m.revoked).length, maxMembers: LIMITS.members, activeKeys: this.activeKeys(), maxKeys: LIMITS.keys};
  }
  createMember({label, role, by, nowSec}) {
    return this.transaction(() => {
      if (this.rows("SELECT count(*) AS n FROM guild_members WHERE revoked_at IS NULL")[0].n >= LIMITS.members) fail(`Ya hay ${LIMITS.members} miembros activos, el máximo. Revoca a alguien antes de añadir más.`);
      const key = label.normalize("NFC").toLowerCase();
      if (this.rows("SELECT id FROM guild_members WHERE label_key=?", key)[0]) fail("Ya existe un miembro con ese nombre. Elige otro.");
      const id = this.rows("INSERT INTO guild_members(label,label_key,role,created_at,created_by,revoked_at) VALUES (?,?,?,?,?,NULL) RETURNING id",
        label, key, role, nowSec, by)[0].id;
      return {id, label, role, createdAt: iso(nowSec), revoked: false};
    });
  }
  setRole(memberId, role) { this.run("UPDATE guild_members SET role=? WHERE id=?", role, memberId); }
  createKey(memberId, tokenHash, nowSec) {
    return this.transaction(() => {
      if (this.activeKeys() >= LIMITS.keys) fail(`Ya hay ${LIMITS.keys} claves activas, el máximo. Revoca una antes de crear otra.`);
      return this.rows("INSERT INTO guild_keys(member_id,token_hash,created_at) VALUES (?,?,?) RETURNING id", memberId, tokenHash, nowSec)[0].id;
    });
  }
  key(id) { return this.rows("SELECT id,member_id,revoked_at FROM guild_keys WHERE id=?", id)[0] || null; }
  revokeKey(id, nowSec) { this.run("UPDATE guild_keys SET revoked_at=? WHERE id=? AND revoked_at IS NULL", nowSec, id); }
  /** Revokes a member and every key. purge also deletes their observations (their own slot, also what other uploaders
   * relayed of their characters, whether a character was first seen as their own or as a relayed mate later bound to
   * them, and every relayed row they uploaded), vendor prices and the item names they gave, forgets every character
   * code bound to them, recomputes the affected days and drops the items left without data. The end state does not
   * depend on the order of the uploads. A relayed row this member was the last to change goes even if another
   * uploader had sent it too. */
  revokeMember(id, nowSec, purge) {
    return this.transaction(() => {
      this.run("UPDATE guild_members SET revoked_at=? WHERE id=? AND revoked_at IS NULL", nowSec, id);
      this.run("UPDATE guild_keys SET revoked_at=? WHERE member_id=? AND revoked_at IS NULL", nowSec, id);
      if (!purge) return {purged: 0};
      let purged = 0;
      const touched = new Map();      // market -> item -> days whose aggregate changes
      const touch = (market, rows) => {
        if (!touched.has(market)) touched.set(market, new Map());
        const items = touched.get(market);
        for (const r of rows) { if (!items.has(r.item_id)) items.set(r.item_id, new Set()); items.get(r.item_id).add(r.day); }
      };
      const uploaded = this.rows("SELECT market FROM guild_member_markets WHERE member_id=?", id).map(r => r.market);
      const relayedInto = this.rows("SELECT market FROM guild_observer_markets WHERE slot=?", id).map(r => r.market);
      for (const market of new Set([...uploaded, ...relayedInto])) {
        touch(market, this.rows("SELECT item_id,day FROM guild_obs_day WHERE market=? AND member_id=?", market, id));
        purged += this.rows("DELETE FROM guild_obs_day WHERE market=? AND member_id=? RETURNING day", market, id).length;
        purged += this.rows("DELETE FROM guild_obs_point WHERE market=? AND member_id=? RETURNING t", market, id).length;
        purged += this.rows("DELETE FROM guild_deposits WHERE market=? AND member_id=? RETURNING copper", market, id).length;
      }
      // What this member relayed of guild mates (rows in another member's slot stay: they are that member's own).
      for (const {market, slot} of this.rows("SELECT market,slot FROM guild_observer_markets WHERE slot>=? ORDER BY market,slot", RELAYED_SLOT_BASE)) {
        const days = this.rows("DELETE FROM guild_obs_day WHERE market=? AND member_id=? AND uploaded_by=? RETURNING item_id,day", market, slot, id);
        touch(market, days);
        purged += days.length + this.rows("DELETE FROM guild_obs_point WHERE market=? AND member_id=? AND uploaded_by=? RETURNING t", market, slot, id).length;
      }
      // A relayed code bound to this member is one of their characters: what anyone relayed of it goes too (as when the
      // character was first seen as their own), and all the member's codes are forgotten.
      for (const {slot} of this.rows("SELECT slot FROM guild_observers WHERE member_id=? AND slot>=?", id, RELAYED_SLOT_BASE)) {
        for (const {market} of this.rows("SELECT market FROM guild_observer_markets WHERE slot=?", slot)) {
          const days = this.rows("DELETE FROM guild_obs_day WHERE market=? AND member_id=? RETURNING item_id,day", market, slot);
          touch(market, days);
          purged += days.length + this.rows("DELETE FROM guild_obs_point WHERE market=? AND member_id=? RETURNING t", market, slot).length;
        }
      }
      this.run("DELETE FROM guild_observers WHERE member_id=?", id);
      this.run("DELETE FROM guild_observers WHERE slot=?", id);
      this.run(`DELETE FROM guild_observer_markets WHERE NOT EXISTS (SELECT 1 FROM guild_obs_day o WHERE o.market=guild_observer_markets.market
        AND o.member_id=guild_observer_markets.slot) AND NOT EXISTS (SELECT 1 FROM guild_obs_point p WHERE p.market=guild_observer_markets.market
        AND p.member_id=guild_observer_markets.slot)`);
      for (const market of uploaded) {
        // A name this member gave is cleared; the next upload of the item names it again.
        this.run("UPDATE guild_items SET name='',name_by=NULL WHERE market=? AND name_by=?", market, id);
        const vendors = this.rows("DELETE FROM guild_item_vendor WHERE market=? AND member_id=? RETURNING item_id", market, id);
        for (const {item_id} of vendors) this.shareVendor(market, item_id);
      }
      const persons = this.persons();
      for (const [market, items] of touched) for (const [item, days] of items) this.aggregate(market, item, days, persons);
      this.run("DELETE FROM guild_member_markets WHERE member_id=?", id);
      this.pruneItems();
      this.run("DELETE FROM guild_summary_cache");
      return {purged};
    });
  }

  // ---- Daily write budget
  /** Rows written today (UTC): the saved counter plus what this instance wrote since it last saved it. */
  writesToday(nowSec) {
    return (this.rows("SELECT written FROM guild_write_budget WHERE day=?", utcDay(nowSec))[0]?.written ?? 0) + this.unsaved;
  }
  /** Adds the unsaved rows to the day's counter (in the caller's transaction, if any); the counter row is one more. */
  saveWrites(nowSec) {
    const day = utcDay(nowSec), used = this.writesToday(nowSec) + 1;
    this.run("DELETE FROM guild_write_budget WHERE day<>?", day);
    this.run("INSERT INTO guild_write_budget(day,written) VALUES (?,?) ON CONFLICT(day) DO UPDATE SET written=excluded.written", day, used);
    this.unsaved = 0;
    return used;
  }

  // ---- Uploads
  uploadExists(memberId, digest) { return this.rows("SELECT 1 AS x FROM guild_uploads WHERE member_id=? AND sha256=?", memberId, digest).length > 0; }
  uploadsOn(memberId, day) { return this.rows("SELECT count(*) AS n FROM guild_uploads WHERE member_id=? AND day=?", memberId, day)[0].n; }

  /** Writes a validated upload (schema 1 or 2) in two steps. First every market is planned with reads only: the
   * codes of the uploader's own characters and of the relayed guild mates (observers), and the rows whose merge
   * changes something (mergeDay for days, the addon's point merge for points, deposits, vendor prices and item
   * metadata). If the uploader's own rows could take the guild past its daily write budget, nothing is written and a
   * 429 says when to come back. The mates are admitted least recently stored first (new and starved mates before the
   * rest, then by code), each on its own: one that would take the mates past their share of the day
   * (LIMITS.relayBudgetShare) is reported as CUOTA, one that would take this upload past LIMITS.relayRowsPerUpload as
   * ENVIO (the first mate of an upload always fits that cap), and the next ones are still tried. Both come again with
   * a later upload. Then the plan is written, the
   * touched day aggregates are recomputed and the summaries of changed markets are dropped. Returns the report. */
  ingest(upload, {member, digest, bytes, nowSec, T, budget = Infinity}) {
    // The daily retention runs first, so the first upload of the day already sees the slots of pruned items.
    this.retain(T, nowSec);
    // Days before the launch window, past retention or before the member's backfill limit, and points older than
    // 14 days, are valid but not stored. observers: code -> {hash, slot, member, stored, insert, bind, fresh}.
    const scope = {member, T, nowSec, oldestDay: Math.max(LIMITS.minDay, T - LIMITS.retentionDays), oldestPoint: nowSec - LIMITS.pointSeconds,
      added: new Set(), observers: new Map(), codes: null, fresh: 0, bindRows: 0, rebind: new Map()};
    const relay = upload.schema === 2, report = {rowsChanged: 0, markets: []}, plans = [];
    for (const m of upload.markets) {
      const entry = {market: m.market, items: 0, days: 0, points: 0, deposits: 0, skippedItems: [], skipped: null,
        ...(relay ? {observers: 0, skippedObservers: [], selfConflicts: []} : {})};
      report.markets.push(entry);
      const plan = this.openMarket(observersOf(m), entry, scope);
      if (plan) plans.push(plan);
    }
    // Own characters first, everywhere, so a code that is both somebody's own and relayed is the member's.
    for (const plan of plans) this.planOwn(plan, scope);
    for (const plan of plans) this.planMates(plan, scope);
    // Upper bound of the rows Cloudflare will count: the receipt (and its index entry) and the key, the codes bound,
    // then per market its rows; a new day row and its aggregate each write the table and one index entry, a new point
    // its row and its time index and perhaps the removal of an old point, a vendor price its row, its index entry and
    // the shared one.
    let estimate = 3 + scope.bindRows;
    for (const plan of plans) estimate += this.planRows(plan, scope);
    const used = this.writesToday(nowSec);
    if (used + estimate > budget) {
      const reset = (utcDay(nowSec) + 1) * 86400;
      const clock = new Intl.DateTimeFormat("es-ES", {timeZone: "Europe/Madrid", hour: "2-digit", minute: "2-digit", hourCycle: "h23"}).format(new Date(reset * 1000));
      fail(`La hermandad ha agotado por hoy su cuota de escritura en el panel (${new Intl.NumberFormat("es-ES").format(budget)} filas al día). ` +
        `Los precios se guardarán a partir de ${clock.startsWith("01:") ? "la" : "las"} ${clock} (hora de España): el subidor lo volverá a intentar solo.`,
        429, {"Retry-After": String(reset - nowSec + 60)});
    }
    // Guild mates least recently stored first (a new or skipped mate has the oldest last_seen), so every mate gets
    // its turn whatever its code; one that does not fit is skipped alone and the smaller ones after it still go.
    const share = Math.floor(budget * LIMITS.relayBudgetShare);
    const queue = plans.flatMap(plan => plan.mates.filter(part => !part.skipped).map(part => ({plan, part})))
      .sort((a, b) => (a.part.seen ?? 0) - (b.part.seen ?? 0) || (a.part.o.obs < b.part.o.obs ? -1 : a.part.o.obs > b.part.o.obs ? 1 : 0));
    let relayed = 0;
    for (const {plan, part} of queue) {
      const overDay = used + estimate + part.cost > share, overUpload = relayed > 0 && relayed + part.cost > LIMITS.relayRowsPerUpload;
      if (part.cost > 0 && (overDay || overUpload)) {
        part.skipped = overDay ? "CUOTA" : "ENVIO";
        plan.entry.skippedObservers.push({obs: part.o.obs, reason: part.skipped});
        continue;
      }
      estimate += part.cost;
      relayed += part.cost;
      plan.entry.observers++;
    }
    for (const plan of plans) plan.entry.skippedObservers?.sort((a, b) => (a.obs < b.obs ? -1 : a.obs > b.obs ? 1 : 0));
    for (const plan of plans) this.finishPlan(plan, scope);
    this.applyObservers(plans, scope);
    const persons = this.persons();
    for (const plan of plans) report.rowsChanged += this.applyMarket(plan, {member, addon: upload.addon, nowSec, T, persons});
    // A relayed code that turned out to be this member's character: its stored days now count for the member, and
    // its prices are now labelled with the member (so the cached summary goes even if no aggregate changed).
    for (const [market, items] of scope.rebind) {
      for (const [item, days] of items) this.aggregate(market, item, days, persons);
      this.run("DELETE FROM guild_summary_cache WHERE market=?", market);
    }
    this.run("INSERT INTO guild_uploads(member_id,sha256,key_id,received_at,day,bytes,rows_changed) VALUES (?,?,?,?,?,?,?)",
      member.memberId, digest, member.keyId, nowSec, T, bytes, report.rowsChanged);
    this.run("UPDATE guild_keys SET last_upload_at=? WHERE id=?", nowSec, member.keyId);
    return report;
  }

  /** The plan of one market of an upload, before any row is read; null when the market is skipped. */
  openMarket(m, entry, {member, T, added}) {
    const known = this.rows("SELECT cut,since FROM guild_member_markets WHERE market=? AND member_id=?", m.market, member.memberId)[0];
    if (!known && !this.marketKnown(m.market)) {
      if (this.rows("SELECT count(DISTINCT market) AS n FROM guild_member_markets")[0].n + added.size >= LIMITS.markets) {
        entry.skipped = "LIMITE_DE_MERCADOS";
        return null;
      }
      added.add(m.market);
    }
    const since = known ? known.since : T - LIMITS.backfillDays + 1;
    return {m, entry, known, since, cut: m.cut ?? known?.cut ?? null, own: m.observers.find(o => o.self) ?? null, mates: [],
      items: null, accepted: new Set(), inserts: [], updates: [], vendors: [], days: [], points: [], deposits: [],
      stored: new Map(), storedPoints: new Map(), finalDays: [], finalPoints: []};
  }

  /** The stored row of an observer code (read once per upload) and what this upload does to it. */
  observer(hash, scope) {
    let st = scope.observers.get(hash);
    if (!st) {
      const row = this.rows("SELECT slot,member_id FROM guild_observers WHERE hash=?", hash)[0];
      st = row ? {hash, slot: row.slot, member: row.member_id, stored: true} : {hash, slot: null, member: null, stored: false};
      scope.observers.set(hash, st);
    }
    return st;
  }

  /** Binds the codes of the uploader's own characters to the member: a new code gets the member's slot (where the
   * member's rows already are, also the legacy ones), a relayed mate's code becomes the member's (its stored days are
   * recomputed as the member's), and a code bound to another member is left alone and reported (selfConflicts). */
  planOwn(plan, scope) {
    const own = plan.own, memberId = scope.member.memberId;
    if (!own) return;
    for (const hash of [own.obs, ...own.aliases]) {
      if (hash === null) continue;
      const st = this.observer(hash, scope);
      if (!st.stored && !st.insert) {
        Object.assign(st, {slot: memberId, member: memberId, insert: true});
        scope.bindRows += 2;
      } else if (st.member === null && st.slot >= RELAYED_SLOT_BASE) {
        st.member = memberId;
        st.bind = true;
        scope.bindRows += 2;
        for (const {market} of this.rows("SELECT market FROM guild_observer_markets WHERE slot=?", st.slot)) {
          if (!scope.rebind.has(market)) scope.rebind.set(market, new Map());
          const items = scope.rebind.get(market);
          for (const r of this.rows("SELECT item_id,day FROM guild_obs_day WHERE market=? AND member_id=?", market, st.slot)) {
            if (!items.has(r.item_id)) items.set(r.item_id, new Set());
            if (!items.get(r.item_id).has(r.day)) scope.bindRows += 2;
            items.get(r.item_id).add(r.day);
          }
        }
      } else if (st.member !== memberId) plan.entry.selfConflicts?.push(hash);
    }
  }

  /** Finds the slot of every relayed mate: the slot of a known code (a member's own slot when the mate is that
   * member), or a new relayed slot while the market has fewer than 60 relayed persons active in 30 days and the guild
   * fewer than 2000 codes; otherwise the mate is skipped (LIMITE_DE_OBSERVADORES). */
  planMates(plan, scope) {
    const mates = plan.m.observers.filter(o => !o.self);
    if (!mates.length) return;
    const active = new Set(this.rows(`SELECT om.slot FROM guild_observer_markets om JOIN guild_observers o ON o.slot=om.slot
      WHERE om.market=? AND om.slot>=? AND om.last_seen>=? AND o.member_id IS NULL`, plan.m.market, RELAYED_SLOT_BASE,
    scope.nowSec - LIMITS.relayActiveDays * 86400).map(r => r.slot));
    // A relayed code this upload binds to its member is a member's character from now on: it leaves the count.
    for (const st of scope.observers.values()) if (st.bind) active.delete(st.slot);
    scope.codes ??= this.rows("SELECT count(*) AS n FROM guild_observers")[0].n;
    for (const o of mates) {
      const st = this.observer(o.obs, scope), part = {o, st, skipped: null, cost: 0, series: new Map(), days: [], points: [], last: 0, seen: null};
      plan.mates.push(part);
      const known = st.stored || st.insert || st.fresh, key = st.slot ?? "h:" + st.hash, unbound = st.member === null;
      const room = !known ? scope.codes + scope.fresh < LIMITS.observersMax && active.size < LIMITS.relayedPerMarket
        : !unbound || active.has(key) || active.size < LIMITS.relayedPerMarket;
      if (!room) {
        part.skipped = "LIMITE_DE_OBSERVADORES";
        plan.entry.skippedObservers.push({obs: o.obs, reason: part.skipped});
        continue;
      }
      if (!known) { st.fresh = true; scope.fresh++; }
      if (unbound) active.add(key);
    }
  }

  /** Reads (and keeps for the plan) the stored days of one slot and item between two days. */
  storedDays(plan, slot, id, from, to) {
    const out = new Map(this.rows("SELECT day,lo,hi,last,qty,scans,src FROM guild_obs_day WHERE market=? AND member_id=? AND item_id=? AND day>=? AND day<=?",
      plan.m.market, slot, id, from, to).map(r => [r.day, {d: r.day, lo: r.lo, hi: r.hi, last: r.last, qty: r.qty, scans: r.scans, src: r.src}]));
    for (const [d, r] of out) plan.stored.set(`${slot}|${id}|${d}`, r);
    return out;
  }
  storedPoints(plan, slot, id, from, to) {
    const out = new Map(this.rows("SELECT t,lo,qty,qty5 FROM guild_obs_point WHERE market=? AND member_id=? AND item_id=? AND t>=? AND t<=?",
      plan.m.market, slot, id, from, to).map(r => [r.t, r]));
    for (const [t, r] of out) plan.storedPoints.set(`${slot}|${id}|${t}`, r);
    return out;
  }

  /** Plans one market with reads only: item metadata, the uploader's own rows (as in schema 1) and each mate's rows.
   * Returns the write estimate of everything but the mates; each mate gets its own (part.cost). */
  planRows(plan, {member, T, oldestDay, oldestPoint}) {
    const {m, entry} = plan, memberId = member.memberId;
    const firstDay = Math.max(oldestDay, plan.since), mateDay = Math.max(oldestDay, T - LIMITS.relayDays);
    // Item metadata. Watchlist items always fit; the rest share what is left of the 300 slots.
    const items = plan.items = new Map(this.rows("SELECT item_id,name,category,vendor,watch,name_by FROM guild_items WHERE market=?", m.market).map(r => [r.item_id, r]));
    const vendors = new Map(this.rows("SELECT item_id,vendor FROM guild_item_vendor WHERE market=? AND member_id=?", m.market, memberId).map(r => [r.item_id, r.vendor]));
    let extras = [...items.values()].filter(r => !r.watch).length;
    const none = {days: [], points: []};
    const own = new Map((plan.own?.items ?? []).map(s => [s.id, {days: s.days.filter(r => r.d >= firstDay), points: s.points.filter(p => p.t >= oldestPoint)}]));
    // A mate's series: watchlist items only (the addon never shares anything else), days from T-14, points of 14 days.
    const mates = plan.mates.filter(part => !part.skipped);
    for (const part of mates) {
      part.series = new Map(part.o.items.filter(s => WATCH.has(s.id))
        .map(s => [s.id, {days: s.days.filter(r => r.d >= mateDay), points: s.points.filter(p => p.t >= oldestPoint)}]));
    }
    for (const item of m.items) {
      const watchCat = WATCH.get(item.id), prior = items.get(item.id), mine = own.get(item.id) ?? none;
      if (!prior) {
        // A new item needs a day to store: without one it would hold a slot (and a name) with nothing to show.
        const sources = mates.filter(part => part.series.get(item.id)?.days.length > 0);
        if (!mine.days.length && !sources.length) continue;
        if (!watchCat && extras >= LIMITS.itemsPerMarket - WATCH.size) { entry.skippedItems.push(item.id); continue; }
        if (!watchCat) extras++;
        plan.inserts.push({id: item.id, name: item.name, cat: watchCat ?? item.cat, vendor: item.vendor, watch: watchCat ? 1 : 0, own: mine.days.length > 0, sources});
      } else {
        // The first non-empty name wins, watchlist categories are fixed and an extra only leaves "otro" for a real
        // category: one member cannot rename an item for everyone, and clients in other languages do not flip it.
        // An extra that has since joined the watchlist becomes a watchlist item here.
        const name = prior.name || item.name, cat = watchCat ?? (prior.category === "otro" ? item.cat : prior.category), watch = watchCat ? 1 : 0;
        if (name !== prior.name || cat !== prior.category || watch !== prior.watch) plan.updates.push({id: item.id, name, cat, watch, nameBy: name !== prior.name ? memberId : prior.name_by});
      }
      // Each member's vendor price is kept (0 is unknown); the shared one is their lower median (shareVendor).
      if (item.vendor > 0 && vendors.get(item.id) !== item.vendor) plan.vendors.push({id: item.id, vendor: item.vendor});
      plan.accepted.add(item.id);
      entry.items++;
      // Days: one row per slot, item and day, merged with especular.mergeDay (an own record beats an import). Only
      // this slot's rows for the days in the body are read (a primary key range), never its whole history.
      if (mine.days.length) {
        const stored = this.storedDays(plan, memberId, item.id, mine.days[0].d, mine.days.at(-1).d);
        for (const record of mine.days) {
          const prior = stored.get(record.d), merged = mergeDay(prior, record);
          if (prior && sameDay(merged, prior)) continue;
          plan.days.push({slot: memberId, id: item.id, ...merged});
        }
      }
      // Points: the addon's merge for the same time (lo = min, qty = max, qty5 of the cheaper point).
      if (mine.points.length) {
        const stored = this.storedPoints(plan, memberId, item.id, mine.points[0].t, mine.points.at(-1).t);
        for (const point of mine.points) {
          const prior = stored.get(point.t), next = mergePoint(prior, point);
          if (prior && samePoint(next, prior)) continue;
          plan.points.push({slot: memberId, id: item.id, ...next});
        }
      }
    }
    // Mates: the same merges in their slot, for the items the market keeps. A mate's day that only adds scans is not
    // rewritten (aggregates never depend on scans or last), which saves most rewrites of a scan seen twice.
    for (const part of mates) {
      const slot = part.st.fresh ? null : part.st.slot;
      for (const [id, s] of part.series) {
        if (!plan.accepted.has(id)) continue;
        if (s.days.length) {
          const stored = slot === null ? new Map() : this.storedDays(plan, slot, id, s.days[0].d, s.days.at(-1).d);
          for (const record of s.days) {
            const prior = stored.get(record.d), merged = mergeDay(prior, record);
            if (prior && samePrice(merged, prior)) continue;
            part.days.push({slot: slot ?? part.st, id, ...merged});
          }
        }
        if (s.points.length) {
          const stored = slot === null ? new Map() : this.storedPoints(plan, slot, id, s.points[0].t, s.points.at(-1).t);
          for (const point of s.points) {
            const prior = stored.get(point.t), next = mergePoint(prior, point);
            if (prior && samePoint(next, prior)) continue;
            part.points.push({slot: slot ?? part.st, id, ...next});
          }
        }
      }
      part.last = this.lastSeen(part, plan.accepted);
      if (slot !== null && part.last > 0) part.seen = this.rows("SELECT last_seen FROM guild_observer_markets WHERE market=? AND slot=?", m.market, slot)[0]?.last_seen ?? null;
      part.cost = 4 * part.days.length + 4 * part.points.length + (part.last > (part.seen ?? 0) ? 2 : 0) + (part.st.fresh && part.last > 0 ? 3 : 0);
    }
    // Deposits learned with the auction house open, only for items stored in this market.
    const deposits = new Map(this.rows("SELECT item_id,duration,copper FROM guild_deposits WHERE market=? AND member_id=?", m.market, memberId)
      .map(r => [r.item_id + ":" + r.duration, r.copper]));
    for (const deposit of m.deposits) {
      if (!plan.accepted.has(deposit.id) && !items.has(deposit.id)) continue;
      if (deposits.get(deposit.id + ":" + deposit.dur) === deposit.copper) continue;
      plan.deposits.push(deposit);
    }
    return plan.inserts.length + plan.updates.length + 3 * plan.vendors.length + 4 * plan.days.length + 4 * plan.points.length + plan.deposits.length + 2;
  }
  /** When a mate was last seen in what this upload stores of it: its newest point, or the start of its newest day. */
  lastSeen(part, accepted) {
    let last = 0;
    for (const [id, s] of part.series) {
      if (!accepted.has(id)) continue;
      if (s.days.length) last = Math.max(last, dayStart(s.days.at(-1).d));
      if (s.points.length) last = Math.max(last, s.points.at(-1).t);
    }
    return last;
  }

  /** After the budget decided which mates are written: drops a new item that only a skipped mate had a day for, and
   * merges the rows of the uploader and of every written mate per slot (two codes can share one: a member's alts). */
  finishPlan(plan) {
    const dropped = new Set(plan.inserts.filter(x => !x.own && !x.sources.some(part => !part.skipped)).map(x => x.id));
    if (dropped.size) {
      plan.inserts = plan.inserts.filter(x => !dropped.has(x.id));
      plan.vendors = plan.vendors.filter(x => !dropped.has(x.id));
      plan.points = plan.points.filter(x => !dropped.has(x.id));
      plan.deposits = plan.deposits.filter(x => !dropped.has(x.id));
      for (const id of dropped) plan.accepted.delete(id);
      plan.entry.items -= dropped.size;
    }
    const days = new Map(), points = new Map();
    const keyOf = x => `${typeof x.slot === "number" ? x.slot : "h:" + x.slot.hash}|${x.id}|`;
    const add = (map, x, at, stored, merge) => {
      const key = keyOf(x) + at, prior = map.get(key) ?? stored.get(key);
      map.set(key, {...x, ...merge(prior, x)});
    };
    const written = plan.mates.filter(part => !part.skipped);
    for (const x of [plan.days, ...written.map(part => part.days)].flat()) {
      if (plan.accepted.has(x.id)) add(days, x, x.d, plan.stored, (a, b) => mergeDay(a, b));
    }
    for (const x of [plan.points, ...written.map(part => part.points)].flat()) {
      if (plan.accepted.has(x.id)) add(points, x, x.t, plan.storedPoints, (a, b) => mergePoint(a, b));
    }
    plan.finalDays = [...days.values()];
    plan.finalPoints = [...points.values()];
    for (const part of written) part.last = this.lastSeen(part, plan.accepted);
  }

  /** Writes the codes: the uploader's own (new or bound now), then a slot for each new mate that has rows to store,
   * numbered in the order the mates appear (markets in body order, mates by code), never reusing a number. */
  applyObservers(plans, {member, nowSec, observers}) {
    for (const st of observers.values()) {
      if (st.insert) {
        this.run("INSERT INTO guild_observers(hash,slot,member_id,first_seen,first_by,bound_at) VALUES (?,?,?,?,?,?)",
          st.hash, st.slot, st.member, nowSec, member.memberId, nowSec);
      } else if (st.bind) this.run("UPDATE guild_observers SET member_id=?,bound_at=? WHERE hash=? AND member_id IS NULL", st.member, nowSec, st.hash);
    }
    let next = null;
    for (const plan of plans) for (const part of plan.mates) {
      const st = part.st;
      if (part.skipped || !st.fresh || st.slot !== null || part.last <= 0) continue;
      next ??= Math.max(RELAYED_SLOT_BASE, Number(this.rows("SELECT value FROM guild_meta WHERE key='relay_slot'")[0]?.value ?? 0),
        this.rows("SELECT max(slot) AS n FROM guild_observers")[0].n ?? 0) + 1;
      st.slot = next++;
      this.run("INSERT INTO guild_observers(hash,slot,member_id,first_seen,first_by,bound_at) VALUES (?,?,NULL,?,?,NULL)", st.hash, st.slot, nowSec, member.memberId);
    }
    if (next !== null) this.run("INSERT OR REPLACE INTO guild_meta(key,value) VALUES ('relay_slot',?)", String(next - 1));
  }

  /** Writes one planned market. Returns the rows the upload changed in it (the report's rowsChanged). */
  applyMarket(plan, {member, addon, nowSec, T, persons}) {
    const {m, entry, known} = plan, market = m.market, slotOf = x => typeof x.slot === "number" ? x.slot : x.slot.slot;
    let shown = 0;      // changes that the cached summary of the market shows
    for (const x of plan.inserts) {
      this.run("INSERT INTO guild_items(market,item_id,name,category,vendor,watch,first_seen,name_by) VALUES (?,?,?,?,?,?,?,?)",
        market, x.id, x.name, x.cat, x.vendor, x.watch, nowSec, x.name ? member.memberId : null);
    }
    for (const x of plan.updates) this.run("UPDATE guild_items SET name=?,category=?,watch=?,name_by=? WHERE market=? AND item_id=?", x.name, x.cat, x.watch, x.nameBy, market, x.id);
    for (const x of plan.vendors) {
      this.run(`INSERT INTO guild_item_vendor(market,member_id,item_id,vendor) VALUES (?,?,?,?)
        ON CONFLICT(market,member_id,item_id) DO UPDATE SET vendor=excluded.vendor`, market, member.memberId, x.id, x.vendor);
      shown += this.shareVendor(market, x.id);
    }
    const touched = new Map();
    for (const x of plan.finalDays) {
      this.run(`INSERT INTO guild_obs_day(market,member_id,item_id,day,lo,hi,last,qty,scans,src,updated_at,uploaded_by) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(market,member_id,item_id,day) DO UPDATE SET lo=excluded.lo,hi=excluded.hi,last=excluded.last,qty=excluded.qty,
        scans=excluded.scans,src=excluded.src,updated_at=excluded.updated_at,uploaded_by=excluded.uploaded_by`,
        market, slotOf(x), x.id, x.d, x.lo, x.hi, x.last, x.qty, x.scans, x.src, nowSec, member.memberId);
      if (!touched.has(x.id)) touched.set(x.id, new Set());
      touched.get(x.id).add(x.d);
    }
    // 14 days and 200 points per slot and item; only points of today change today's summary.
    const pointItems = new Map();
    for (const x of plan.finalPoints) {
      this.run(`INSERT INTO guild_obs_point(market,member_id,item_id,t,lo,qty,qty5,uploaded_by) VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(market,member_id,item_id,t) DO UPDATE SET lo=excluded.lo,qty=excluded.qty,qty5=excluded.qty5,uploaded_by=excluded.uploaded_by`,
        market, slotOf(x), x.id, x.t, x.lo, x.qty, x.qty5, member.memberId);
      pointItems.set(slotOf(x) + ":" + x.id, [slotOf(x), x.id]);
      if (x.t >= dayStart(T)) shown++;
    }
    for (const [slot, id] of pointItems.values()) {
      this.run(`DELETE FROM guild_obs_point WHERE market=? AND member_id=? AND item_id=? AND t<(SELECT t FROM guild_obs_point
        WHERE market=? AND member_id=? AND item_id=? ORDER BY t DESC LIMIT 1 OFFSET ?)`, market, slot, id, market, slot, id, LIMITS.pointsKept - 1);
    }
    for (const x of plan.deposits) {
      this.run(`INSERT INTO guild_deposits(market,member_id,item_id,duration,copper,updated_at) VALUES (?,?,?,?,?,?)
        ON CONFLICT(market,member_id,item_id,duration) DO UPDATE SET copper=excluded.copper,updated_at=excluded.updated_at`,
        market, member.memberId, x.id, x.dur, x.copper, nowSec);
    }
    // Where each written mate was last seen (only forward), for the count of persons who feed the market.
    for (const part of plan.mates) {
      if (part.skipped || part.last <= (part.seen ?? 0) || part.st.slot === null) continue;
      this.run(`INSERT INTO guild_observer_markets(market,slot,first_day,last_seen,last_by) VALUES (?,?,?,?,?)
        ON CONFLICT(market,slot) DO UPDATE SET last_seen=excluded.last_seen,last_by=excluded.last_by WHERE excluded.last_seen>guild_observer_markets.last_seen`,
        market, part.st.slot, T, part.last, member.memberId);
    }
    for (const [item, days] of touched) shown += this.aggregate(market, item, days, persons);
    this.run(`INSERT INTO guild_member_markets(market,member_id,cut,addon,last_upload_at,since) VALUES (?,?,?,?,?,?)
      ON CONFLICT(market,member_id) DO UPDATE SET cut=excluded.cut,addon=excluded.addon,last_upload_at=excluded.last_upload_at`,
      market, member.memberId, plan.cut, addon, nowSec, plan.since);
    Object.assign(entry, {days: plan.finalDays.length, points: plan.finalPoints.length, deposits: plan.deposits.length});
    shown += plan.inserts.length + plan.updates.length + plan.deposits.length;
    if (shown > 0 || (known?.cut ?? null) !== plan.cut) this.run("DELETE FROM guild_summary_cache WHERE market=?", market);
    return plan.inserts.length + plan.updates.length + plan.vendors.length + plan.finalDays.length + plan.finalPoints.length + plan.deposits.length;
  }

  /** The shared vendor price of an item: the lower median of what members sent, so that one member alone cannot
   * inflate it (and with it the estimated deposit, which would hide every chollo of the item). Returns 1 if it changed. */
  shareVendor(market, id) {
    const values = this.rows("SELECT vendor FROM guild_item_vendor WHERE market=? AND item_id=?", market, id).map(r => r.vendor);
    const vendor = values.length ? quantile(values, 1, 2) : 0;
    return this.rows("UPDATE guild_items SET vendor=? WHERE market=? AND item_id=? AND vendor<>? RETURNING item_id", vendor, market, id, vendor).length;
  }

  /** Recomputes guild_day_agg for some days of one item from every person's merged day (especular.dayValue, with its
   * outlier guard from 3 persons). A person is a member (their own slot plus the relayed codes bound to them) or a
   * relayed mate; the slots of one person are merged with especular.mergeDay first, and persons go in numeric order.
   * lo and hi are those of the persons that were kept; members lists their ids. Rows that come out the same are not
   * written again. persons: GuildStore.persons(). Returns how many aggregate rows changed. */
  aggregate(market, item, days, persons = this.persons()) {
    const list = [...days], from = Math.min(...list), to = Math.max(...list);
    const rows = this.rows("SELECT day,member_id,lo,hi,last,qty,scans,src FROM guild_obs_day WHERE market=? AND item_id=? AND day>=? AND day<=? ORDER BY day,member_id",
      market, item, from, to);
    const current = new Map(this.rows("SELECT day,v,lo,hi,qty,observers,members FROM guild_day_agg WHERE market=? AND item_id=? AND day>=? AND day<=?",
      market, item, from, to).map(r => [r.day, r]));
    const byDay = new Map();
    for (const r of rows) {
      if (!byDay.has(r.day)) byDay.set(r.day, new Map());
      const people = byDay.get(r.day), person = personOf(persons, r.member_id);
      people.set(person, mergeDay(people.get(person), {d: r.day, lo: r.lo, hi: r.hi, last: r.last, qty: r.qty, scans: r.scans, src: r.src}));
    }
    let changed = 0;
    for (const d of list) {
      const observers = [...(byDay.get(d) ?? [])].sort((x, y) => x[0] - y[0]), prior = current.get(d);
      const value = dayValue(observers.map(([person, r]) => ({lo: r.lo, hi: r.hi, qty: r.qty, id: String(person)})));
      if (!value) {
        if (prior) { this.run("DELETE FROM guild_day_agg WHERE market=? AND item_id=? AND day=?", market, item, d); changed++; }
        continue;
      }
      const kept = observers.filter(([person]) => value.ids.includes(String(person))).map(([, r]) => r);
      const next = {v: value.v, lo: Math.min(...kept.map(r => r.lo)), hi: Math.max(...kept.map(r => r.hi)), qty: value.qty ?? null,
        observers: value.obs, members: value.ids.join(",")};
      if (prior && prior.v === next.v && prior.lo === next.lo && prior.hi === next.hi && prior.qty === next.qty &&
          prior.observers === next.observers && prior.members === next.members) continue;
      this.run(`INSERT INTO guild_day_agg(market,item_id,day,v,lo,hi,qty,observers,members) VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(market,item_id,day) DO UPDATE SET v=excluded.v,lo=excluded.lo,hi=excluded.hi,qty=excluded.qty,
        observers=excluded.observers,members=excluded.members`, market, item, d, next.v, next.lo, next.hi, next.qty, next.observers, next.members);
      changed++;
    }
    return changed;
  }
  /** Relayed slots bound to a member: Map slot -> member id (personOf). */
  persons() {
    return new Map(this.rows("SELECT slot,member_id FROM guild_observers WHERE slot>=? AND member_id IS NOT NULL", RELAYED_SLOT_BASE).map(r => [r.slot, r.member_id]));
  }

  /** Retention, at most once per day: days older than T-180, points older than 14 days, upload receipts of 180 days,
   * relayed mates not seen in 180 days (and their codes, when no member owns them), and then the items left without
   * days. */
  retain(T, nowSec) {
    if (this.rows("SELECT value FROM guild_meta WHERE key='retention_day'")[0]?.value === String(T)) return;
    this.run("DELETE FROM guild_obs_day WHERE day<?", T - LIMITS.retentionDays);
    this.run("DELETE FROM guild_day_agg WHERE day<?", T - LIMITS.retentionDays);
    this.run("DELETE FROM guild_obs_point WHERE t<?", nowSec - LIMITS.pointSeconds);
    this.run("DELETE FROM guild_uploads WHERE day<?", T - LIMITS.retentionDays);
    this.run("DELETE FROM guild_observer_markets WHERE last_seen<?", nowSec - LIMITS.retentionDays * 86400);
    this.run(`DELETE FROM guild_observers WHERE member_id IS NULL AND NOT EXISTS (SELECT 1 FROM guild_observer_markets om
      WHERE om.slot=guild_observers.slot)`);
    this.pruneItems();
    this.run("INSERT OR REPLACE INTO guild_meta(key,value) VALUES ('retention_day',?)", String(T));
  }
  /** Items without any stored day (after the retention or a purge) give back their slot and their name, with their
   * deposits and vendor prices. A point of such an item, if any is left, is shown nowhere and ages out in 14 days. */
  pruneItems() {
    const gone = this.rows(`DELETE FROM guild_items WHERE NOT EXISTS (SELECT 1 FROM guild_obs_day o
      WHERE o.market=guild_items.market AND o.item_id=guild_items.item_id) RETURNING market`);
    if (!gone.length) return 0;
    this.run(`DELETE FROM guild_deposits WHERE NOT EXISTS (SELECT 1 FROM guild_items i WHERE i.market=guild_deposits.market AND i.item_id=guild_deposits.item_id)`);
    this.run(`DELETE FROM guild_item_vendor WHERE NOT EXISTS (SELECT 1 FROM guild_items i WHERE i.market=guild_item_vendor.market AND i.item_id=guild_item_vendor.item_id)`);
    for (const market of new Set(gone.map(r => r.market))) this.run("DELETE FROM guild_summary_cache WHERE market=?", market);
    return gone.length;
  }

  // ---- Reads
  labels() { return new Map(this.rows("SELECT id,label FROM guild_members").map(r => [String(r.id), r.label])); }
  markets(nowSec) {
    const items = new Map(this.rows("SELECT market,count(*) AS n FROM guild_items GROUP BY market").map(r => [r.market, r.n]));
    const since = nowSec - LIMITS.freshDays * 86400, people = new Map();
    const add = (market, person) => { if (!people.has(market)) people.set(market, new Set()); people.get(market).add(person); };
    for (const r of this.rows("SELECT market,member_id FROM guild_member_markets WHERE last_upload_at>=?", since)) add(r.market, r.member_id);
    for (const r of this.relayedSeen(null, since)) add(r.market, r.person);
    return this.rows(`SELECT market,max(last_upload_at) AS last,sum(CASE WHEN last_upload_at>=? THEN 1 ELSE 0 END) AS contributors
      FROM guild_member_markets GROUP BY market ORDER BY last DESC,market`, since)
      .map(r => ({market: r.market, items: items.get(r.market) ?? 0, contributors: r.contributors, observers: people.get(r.market)?.size ?? 0, lastUploadAt: iso(r.last)}));
  }
  /** Relayed observers seen since a time, in one market or all (market null), with the person each one is. */
  relayedSeen(market, since) {
    return this.rows(`SELECT om.market,om.slot,om.last_seen,o.member_id FROM guild_observer_markets om
      LEFT JOIN guild_observers o ON o.slot=om.slot AND o.slot>=? WHERE ${market === null ? "" : "om.market=? AND "}om.last_seen>=?`,
    RELAYED_SLOT_BASE, ...(market === null ? [] : [market]), since)
      .map(r => ({market: r.market, seen: r.last_seen, person: r.slot < RELAYED_SLOT_BASE ? r.slot : r.member_id ?? r.slot}));
  }
  marketKnown(market) { return this.rows("SELECT 1 AS x FROM guild_member_markets WHERE market=? LIMIT 1", market).length > 0; }
  /** The auction house cut for flips: the median of what members learned from their invoices, once at least two
   * members report a plausible one (1 % to 20 %); else 5 %. members: how many cuts were used (0 for the default). */
  cut(market) {
    const cuts = this.rows("SELECT cut FROM guild_member_markets WHERE market=? AND cut>=? AND cut<=?", market, LIMITS.cutMin, LIMITS.cutMax).map(r => r.cut);
    return cuts.length >= LIMITS.cutMembers ? {cutBp: median(cuts), members: cuts.length} : {cutBp: CUT_BP, members: 0};
  }
  dayMap(rows) {
    const out = new Map();
    for (const r of rows) {
      if (!out.has(r.item_id)) out.set(r.item_id, {});
      out.get(r.item_id)[r.day] = {v: r.v, qty: r.qty, obs: r.observers, ids: r.members ? r.members.split(",") : [], lo: r.lo, hi: r.hi};
    }
    return out;
  }
  /** Lowest scan point of each item on day T across every observer (ties: the newest), with who and when: member is
   * the member's label, or null with mate: true for a relayed guild mate (never a name or a code). */
  lowestPoints(market, T, labels, item = null, persons = this.persons()) {
    const rows = this.rows(`SELECT item_id,member_id,t,lo,qty,qty5 FROM guild_obs_point WHERE market=? AND t>=? AND t<?${item === null ? "" : " AND item_id=?"}
      ORDER BY item_id,lo,t DESC,member_id`, market, dayStart(T), dayStart(T + 1), ...(item === null ? [] : [item]));
    const out = new Map();
    for (const r of rows) {
      if (out.has(r.item_id)) continue;
      const person = personOf(persons, r.member_id);
      out.set(r.item_id, {lo: r.lo, qty: r.qty, qty5: r.qty5, t: r.t, at: iso(r.t), member: isMate(person) ? null : labels.get(String(person)) ?? null, mate: isMate(person)});
    }
    return out;
  }
  depositsFor(market, duration, item = null) {
    const rows = this.rows(`SELECT item_id,duration,copper FROM guild_deposits WHERE market=? AND duration=?${item === null ? "" : " AND item_id=?"}`,
      market, duration, ...(item === null ? [] : [item]));
    const grouped = new Map();
    for (const r of rows) { if (!grouped.has(r.item_id)) grouped.set(r.item_id, []); grouped.get(r.item_id).push(r.copper); }
    return new Map([...grouped].map(([id, values]) => [id, {D: median(values), members: values.length}]));
  }

  /** Who uploaded to a market and when, and how many people feed it. Not cached: an upload without new data still
   * counts as fresh. contributors: members who uploaded in 14 days (M, "suben"); observers: distinct persons among
   * them and the relayed mates seen in 14 days (N, "aportan"); the ...Today counts the same since today began. */
  freshness(market, T, nowSec) {
    const rows = this.rows(`SELECT mm.member_id,mm.last_upload_at,m.label FROM guild_member_markets mm LEFT JOIN guild_members m ON m.id=mm.member_id
      WHERE mm.market=? ORDER BY mm.last_upload_at DESC,mm.member_id`, market);
    const since = nowSec - LIMITS.freshDays * 86400, today = dayStart(T), last = rows[0];
    const recent = rows.filter(r => r.last_upload_at >= since), mates = this.relayedSeen(market, since);
    const people = new Set([...recent.map(r => r.member_id), ...mates.map(r => r.person)]);
    const peopleToday = new Set([...recent.filter(r => r.last_upload_at >= today).map(r => r.member_id), ...mates.filter(r => r.seen >= today).map(r => r.person)]);
    return {lastUploadAt: iso(last?.last_upload_at), lastUploadBy: last?.label ?? null, contributors: recent.length,
      contributorsToday: rows.filter(r => r.last_upload_at >= today).length, observers: people.size, observersToday: peopleToday.size};
  }
  /** The market summary for day T without freshness, served from guild_summary_cache while the day and data hold. */
  summary(market, T, nowSec) {
    const cached = this.rows("SELECT day,version,payload FROM guild_summary_cache WHERE market=?", market)[0];
    if (cached && cached.day === T && cached.version === SUMMARY_VERSION) return {payload: cached.payload, cache: "hit"};
    if (!this.marketKnown(market)) return null;
    const payload = JSON.stringify(this.buildSummary(market, T, nowSec));
    if (encoder.encode(payload).byteLength <= LIMITS.cacheBytes) {
      this.run("INSERT OR REPLACE INTO guild_summary_cache(market,day,version,computed_at,payload) VALUES (?,?,?,?,?)", market, T, SUMMARY_VERSION, nowSec, payload);
    }
    return {payload, cache: "miss"};
  }
  buildSummary(market, T, nowSec) {
    const labels = this.labels(), {cutBp, members: cutMembers} = this.cut(market);
    const items = this.rows("SELECT item_id,name,category,vendor,watch FROM guild_items WHERE market=?", market);
    const days = this.dayMap(this.rows("SELECT item_id,day,v,lo,hi,qty,observers,members FROM guild_day_agg WHERE market=? AND day>=? AND day<=?", market, T - 27, T));
    const prices = this.lowestPoints(market, T, labels), deposits = this.depositsFor(market, RESALE_DURATION);
    const order = new Map(CATEGORIES.map((cat, i) => [cat, i]));
    items.sort((a, b) => order.get(a.category) - order.get(b.category) || a.item_id - b.item_id);
    const entries = items.map(item => {
      const series = days.get(item.item_id) ?? {}, price = prices.get(item.item_id) ?? null;
      const b = baseline(series, T, {cloud: true}), a = assess(b, price ? price.lo : null, T), d = deltas(series, T);
      let min14 = null, max14 = null;
      for (let day = T - 13; day <= T; day++) {
        const x = series[day];
        if (!x) continue;
        min14 = min14 === null ? x.lo : Math.min(min14, x.lo);
        max14 = max14 === null ? x.hi : Math.max(max14, x.hi);
      }
      const spark = [];
      for (let day = T - 27; day <= T; day++) spark.push(series[day]?.v ?? null);
      const today = series[T] ? {v: series[T].v, lo: series[T].lo, hi: series[T].hi, qty: series[T].qty, obs: series[T].obs} : null;
      const deposit = deposits.get(item.item_id);
      let result = null;
      if (a.verdict === "CHOLLO") {
        const f = flip(b, null, {cutBp, D: deposit ? deposit.D : null, vendor: item.vendor, budget: BUDGET, p: price.lo, q5: price.qty5});
        result = {...f, text: texts.flip(f), cutBp, budget: BUDGET, who: price.member, at: price.at, t: price.t};
      }
      return {id: item.item_id, name: item.name, cat: item.category, catLabel: CATEGORY_LABELS[item.category], vendor: item.vendor, watch: item.watch === 1,
        today, price, n: b.n, members: b.k, N: b.N, MAD: b.MAD, sBp: b.sBp, R3: b.R3, O7: b.O7, trend: b.trend, trendBp: b.trendBp, fresh: b.fresh,
        conf: b.conf, confLabel: b.conf ? CONFIDENCE_LABELS[b.conf] : "Aprendiendo", confText: texts.conf(b), Rs: b.Rs, Q: b.Q, status: b.status,
        verdict: a.verdict, verdictLabel: VERDICT_LABELS[a.verdict], statusText: texts.status(a, b), guard: a.guard, wait: a.wait, dBp: a.dBp,
        band: a.band, dumpLine: a.dumpLine, spikeLine: a.spikeLine, shiftLine: a.shiftLine, d1: d.d1, d7: d.d7, min14, max14, spark,
        deposit: {D: deposit ? deposit.D : null, duration: RESALE_DURATION, members: deposit ? deposit.members : 0, estimated: !deposit}, flip: result};
    });
    const trusted = entries.filter(e => (e.conf === "ALTA" || e.conf === "MEDIA") && e.d7 !== null);
    const brief = e => ({id: e.id, name: e.name, cat: e.cat, d7: e.d7, conf: e.conf});
    const categories = CATEGORIES.filter(cat => entries.some(e => e.cat === cat)).map(cat => {
      const values = entries.filter(e => e.cat === cat && e.d7 !== null).map(e => e.d7);
      return {cat, label: CATEGORY_LABELS[cat], index: median(values), items: values.length};
    });
    const chollos = entries.filter(e => e.verdict === "CHOLLO")
      .sort((x, y) => Number(y.flip.accept) - Number(x.flip.accept) || x.dBp - y.dBp || x.id - y.id).map(e => e.id);
    const phase = T < LAUNCH ? "antes" : T < LAUNCH + GUARD_DAYS ? "proteccion" : "normal";
    return {market, rules: VERSION, T, date: dateOfDay(T), dayOfLaunch: T - LAUNCH + 1, launchDay: LAUNCH, guardUntil: LAUNCH + GUARD_DAYS, phase,
      banner: phase === "antes" ? "WoW Forever abre el 4 de noviembre: todavía no hay precios de la hermandad." : phase === "proteccion" ? texts.GUARD : null,
      caveat: texts.CAVEAT, computedAt: iso(nowSec), cutBp, cutMembers, budget: BUDGET, resaleDuration: RESALE_DURATION,
      items: entries, chollos,
      balance: {categories, risers: trusted.filter(e => e.d7 > 0).sort((x, y) => y.d7 - x.d7 || x.id - y.id).slice(0, 5).map(brief),
        fallers: trusted.filter(e => e.d7 < 0).sort((x, y) => x.d7 - y.d7 || x.id - y.id).slice(0, 5).map(brief)}};
  }

  /** Item detail: 60 days of the merged market, 14 days of every person's points, the weekday pattern and the
   * calculator defaults (flip with the lowest point today, whatever the verdict). null for an unknown item. */
  item(market, id, T, nowSec) {
    const item = this.rows("SELECT item_id,name,category,vendor,watch FROM guild_items WHERE market=? AND item_id=?", market, id)[0];
    if (!item) return null;
    const labels = this.labels(), persons = this.persons(), {cutBp} = this.cut(market);
    const series = this.dayMap(this.rows("SELECT item_id,day,v,lo,hi,qty,observers,members FROM guild_day_agg WHERE market=? AND item_id=? AND day<=? ORDER BY day",
      market, id, T)).get(id) ?? {};
    const price = this.lowestPoints(market, T, labels, id, persons).get(id) ?? null;
    const b = baseline(series, T, {cloud: true}), a = assess(b, price ? price.lo : null, T), d = deltas(series, T);
    const w = weekday(series, T, {watch: item.watch === 1});
    const deposits = [1, 2, 3].map(duration => {
      const found = this.depositsFor(market, duration, id).get(id);
      return {duration, D: found ? found.D : null, members: found ? found.members : 0};
    });
    const resale = deposits.find(x => x.duration === RESALE_DURATION);
    const f = flip(b, null, {cutBp, D: resale.D, vendor: item.vendor, budget: BUDGET, p: price ? price.lo : null, q5: price ? price.qty5 : null});
    // Every slot with data in the market (members who uploaded, relayed mates), each read by its primary key range; the
    // slots of one person are merged like the addon merges two points at the same time.
    const slots = new Set([...this.rows("SELECT member_id AS slot FROM guild_member_markets WHERE market=?", market),
      ...this.rows("SELECT slot FROM guild_observer_markets WHERE market=?", market)].map(r => r.slot));
    const merged = new Map();
    for (const slot of slots) {
      const person = personOf(persons, slot);
      for (const r of this.rows("SELECT t,lo,qty,qty5 FROM guild_obs_point WHERE market=? AND member_id=? AND item_id=? AND t>=?", market, slot, id, nowSec - LIMITS.pointSeconds)) {
        const key = person + ":" + r.t;
        merged.set(key, {person, ...mergePoint(merged.get(key), r)});
      }
    }
    const points = [...merged.values()].sort((x, y) => x.t - y.t || x.person - y.person)
      .map(r => ({t: r.t, at: iso(r.t), lo: r.lo, qty: r.qty, qty5: r.qty5, member: isMate(r.person) ? null : labels.get(String(r.person)) ?? null, mate: isMate(r.person)}));
    const days = Object.keys(series).map(Number).filter(day => day >= T - 59).sort((x, y) => x - y).map(day => {
      const x = series[day];
      return {d: day, date: dateOfDay(day), v: x.v, lo: x.lo, hi: x.hi, qty: x.qty, obs: x.obs, members: x.ids.map(m => labels.get(m) ?? null)};
    });
    let weekdayText;
    if (item.watch !== 1) weekdayText = "Los patrones por día de la semana solo se buscan en la lista fija de la hermandad.";
    else if (w.shown) weekdayText = `Patrón probable: el ${WEEKDAYS[w.cheapest]} suele estar un ${texts.pct(w.e[w.cheapest])} % más barato que el resto de su semana.`;
    else if (w.missingWeeks > 0) weekdayText = `${w.missingWeeks === 1 ? "Falta" : "Faltan"} ${plural(w.missingWeeks, "semana", "semanas")} de datos para buscar patrones por día de la semana.`;
    else weekdayText = "Sin patrón claro por día de la semana.";
    return {market, rules: VERSION, T, date: dateOfDay(T),
      item: {id: item.item_id, name: item.name, cat: item.category, catLabel: CATEGORY_LABELS[item.category], vendor: item.vendor, watch: item.watch === 1},
      days, points, price, baseline: b, assess: a, deltas: d, confText: texts.conf(b), statusText: texts.status(a, b),
      verdictLabel: VERDICT_LABELS[a.verdict], weekday: {...w, names: WEEKDAYS, text: weekdayText}, deposits, cutBp, budget: BUDGET,
      flip: {...f, text: texts.flip(f), cutBp, budget: BUDGET, duration: RESALE_DURATION}, caveat: texts.CAVEAT};
  }

  /** The summary as CSV. "Visto por" is the member's label, or «un compañero» for a relayed mate; "Personas" counts
   * the people behind the normal price. Pure: the panel builds the same file from the same summary. */
  csvSummary(summary) {
    const rows = [["Objeto", "ID", "Categoría", "Hoy (oro)", "Más bajo hoy (oro)", "Visto por", "Normal 14 d (oro)", "Δ1d (%)", "Δ7d (%)",
      "Mín 14 d (oro)", "Máx 14 d (oro)", "Oferta típica", "Personas", "Días con datos", "Confianza", "Veredicto"]];
    for (const e of summary.items) {
      rows.push([textCell(e.name || `Objeto ${e.id}`), intCell(e.id), textCell(e.catLabel), goldCell(e.today?.v), goldCell(e.price?.lo),
        textCell(e.price ? e.price.member ?? "un compañero" : null),
        goldCell(e.N), pctCell(e.d1), pctCell(e.d7), goldCell(e.min14), goldCell(e.max14), intCell(e.Q), intCell(e.members), intCell(e.n),
        textCell(e.confLabel), textCell(e.verdictLabel)]);
    }
    return csvText(rows);
  }
  csvDaily(market, T, span) {
    const items = new Map(this.rows("SELECT item_id,name,category FROM guild_items WHERE market=?", market).map(r => [r.item_id, r]));
    const order = new Map(CATEGORIES.map((cat, i) => [cat, i]));
    const rows = this.rows("SELECT item_id,day,v,lo,hi,qty,observers FROM guild_day_agg WHERE market=? AND day>=? AND day<=?", market, T - span + 1, T)
      .filter(r => items.has(r.item_id))
      .sort((x, y) => x.day - y.day || order.get(items.get(x.item_id).category) - order.get(items.get(y.item_id).category) || x.item_id - y.item_id);
    const out = [["Fecha", "Día", "Objeto", "ID", "Categoría", "Valor (oro)", "Mín (oro)", "Máx (oro)", "Cantidad", "Personas"]];
    for (const r of rows) {
      const item = items.get(r.item_id);
      out.push([dateOfDay(r.day), intCell(r.day - LAUNCH + 1), textCell(item.name || `Objeto ${r.item_id}`), intCell(r.item_id),
        textCell(CATEGORY_LABELS[item.category]), goldCell(r.v), goldCell(r.lo), goldCell(r.hi), intCell(r.qty), intCell(r.observers)]);
    }
    return csvText(out);
  }
}

// ---- Durable Object
const canAdmin = actor => actor.role === "owner" || actor.role === "admin";
function requireId(value, label) { if (!isInt(value, 1, Number.MAX_SAFE_INTEGER)) fail(`${label} no válido.`); return value; }
function requireLabel(value) {
  const label = typeof value === "string" ? value.normalize("NFC").trim().replace(/\s+/g, " ") : "";
  if (!label || [...label].length > LIMITS.labelMax || CONTROL.test(label)) fail(`El nombre del miembro debe tener entre 1 y ${LIMITS.labelMax} caracteres.`);
  return label;
}
function requireRole(value) { if (value !== "admin" && value !== "member") fail("El rol debe ser «member» o «admin»."); return value; }
function requireMarket(value) { if (typeof value !== "string" || !MARKET_PATTERN.test(value)) fail("Indica el mercado como Reino-Alliance o Reino-Horde."); return value; }

export class GuildMarket {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; this.store = new GuildStore(ctx); this.now = () => Date.now(); }
  /** Rows the guild may write per UTC day: GUILD_WRITE_ROWS_PER_DAY when set (1000 or more), else LIMITS.writeRowsPerDay. */
  writeBudget() {
    const value = Number(this.env?.GUILD_WRITE_ROWS_PER_DAY);
    return Number.isSafeInteger(value) && value >= 1000 ? value : LIMITS.writeRowsPerDay;
  }

  async fetch(request) {
    try {
      const url = new URL(request.url), path = url.pathname, method = request.method;
      const nowMs = this.now(), nowSec = Math.floor(nowMs / 1000), T = dayIndex(nowSec), store = this.store;
      if (path === "/internal/login" && method === "POST") {
        const data = parseObject(await readBody(request, LIMITS.loginBody));
        if (typeof data.ip !== "string" || !/^[a-f0-9]{64}$/.test(data.ip)) fail("Petición interna no válida.");
        if (!store.rateLimit("login:" + data.ip, nowMs, LIMITS.loginAttempts, LIMITS.loginWindowMs)) return json({error: "Demasiados intentos. Vuelve a intentarlo dentro de 15 minutos."}, 429);
        const key = store.keyByHash(data.keyHash);
        if (!key || key.revoked) return json({error: "Clave de la hermandad incorrecta o revocada."}, 401);
        store.resetRateLimit("login:" + data.ip);
        store.run("UPDATE guild_keys SET last_login_at=? WHERE id=?", nowSec, key.keyId);
        return json({id: key.memberId, keyId: key.keyId, label: key.label, role: key.role});
      }
      if (path === "/api/guild/sync" && method === "POST") return await this.sync(request, nowMs, nowSec, T);
      if (method === "POST") {
        store.actor(request.headers.get("X-Guild-Actor"));
        const data = parseObject(await readBody(request, LIMITS.adminBody));
        return await this.admin(path, data, store.actor(request.headers.get("X-Guild-Actor")), nowSec);
      }
      if (method !== "GET") return json({error: "Método no admitido."}, 405);
      const actor = store.actor(request.headers.get("X-Guild-Actor"));
      const params = url.searchParams;
      if (path === "/api/guild/me") {
        const me = {role: actor.role, isOwner: actor.role === "owner", canAdmin: canAdmin(actor),
          member: actor.kind === "member" ? {id: actor.memberId, label: actor.label} : null, rules: VERSION, T, date: dateOfDay(T),
          dayOfLaunch: T - LAUNCH + 1, launchDay: LAUNCH, guardUntil: LAUNCH + GUARD_DAYS, markets: store.markets(nowSec),
          limits: {uploadsPerDay: LIMITS.uploadsPerDay, maxKeys: LIMITS.keys, maxMembers: LIMITS.members, itemsPerMarket: LIMITS.itemsPerMarket,
            retentionDays: LIMITS.retentionDays, bodyBytes: LIMITS.body, writeRowsPerDay: this.writeBudget()}};
        if (canAdmin(actor)) me.writesToday = store.writesToday(nowSec);
        if (actor.kind === "member") {
          me.uploadsToday = store.uploadsOn(actor.memberId, T);
          me.lastUploadAt = iso(store.rows("SELECT max(received_at) AS t FROM guild_uploads WHERE member_id=?", actor.memberId)[0].t);
        }
        return json(me);
      }
      if (path === "/api/guild/download/sincronizador") return new Response(null, {status: 204});
      if (path === "/api/guild/members") {
        if (!canAdmin(actor)) return json({error: "Solo quien administra la hermandad puede ver los miembros."}, 403);
        return json(store.listMembers());
      }
      const market = requireMarket(params.get("market"));
      if (path === "/api/guild/market") {
        const summary = store.summary(market, T, nowSec);
        if (!summary) return json({error: "Todavía no hay datos de ese mercado."}, 404);
        // The cached object plus the live freshness, spliced in without parsing the cached JSON again.
        const body = '{"freshness":' + JSON.stringify(store.freshness(market, T, nowSec)) + "," + summary.payload.slice(1);
        return new Response(body, {headers: {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store", "X-Guild-Cache": summary.cache}});
      }
      if (path === "/api/guild/item") {
        const id = Number(params.get("id"));
        if (!/^[1-9][0-9]{0,9}$/.test(params.get("id") || "") || !isInt(id, 1, LIMITS.itemIdMax)) fail("Indica el objeto con su ID numérico.");
        const detail = store.item(market, id, T, nowSec);
        return detail ? json(detail) : json({error: "Ese objeto no está en este mercado."}, 404);
      }
      if (path === "/api/guild/export.csv") {
        const kind = params.get("kind") || "summary";
        if (kind !== "summary" && kind !== "daily") fail("El tipo de exportación debe ser «summary» o «daily».");
        const span = params.has("days") ? Number(params.get("days")) : 60;
        if (!isInt(span, 1, LIMITS.retentionDays)) fail(`Los días deben ser un entero entre 1 y ${LIMITS.retentionDays}.`);
        let text;
        if (kind === "summary") {
          const summary = store.summary(market, T, nowSec);
          if (!summary) return json({error: "Todavía no hay datos de ese mercado."}, 404);
          text = store.csvSummary(JSON.parse(summary.payload));
        } else {
          if (!store.marketKnown(market)) return json({error: "Todavía no hay datos de ese mercado."}, 404);
          text = store.csvDaily(market, T, span);
        }
        const name = `Hermandad_${market.replace(/[^A-Za-z0-9_-]+/g, "_")}_${kind === "summary" ? "resumen" : "diario"}_${dateOfDay(T)}.csv`;
        return new Response(text, {headers: {"Content-Type": "text/csv; charset=utf-8", "Cache-Control": "private, no-store",
          "Content-Disposition": `attachment; filename="${name}"`}});
      }
      return json({error: "Ruta no encontrada."}, 404);
    } catch (error) {
      return json({error: error.status ? error.message : "No se ha podido completar la operación."}, error.status || 500, error.status && error.headers || {});
    } finally {
      // Rows written outside an accepted upload (logins, rate limits, summaries, refused attempts) count for today too.
      if (this.store.unsaved > 0) { try { this.store.saveWrites(Math.floor(this.now() / 1000)); } catch { /* counted next time */ } }
    }
  }

  async sync(request, nowMs, nowSec, T) {
    const store = this.store, hash = request.headers.get("X-Member-Hash");
    let key = store.keyByHash(hash);
    if (!key || key.revoked) return json({error: "La clave de la hermandad se ha rechazado o revocado."}, 401);
    if (!store.rateLimit("sync:" + key.memberId, nowMs, LIMITS.syncPerHour, 3600000)) return json({error: "Demasiados envíos en una hora. Espera un poco y vuelve a intentarlo."}, 429);
    const encoding = request.headers.get("Content-Encoding");
    if (encoding && encoding.toLowerCase() !== "identity") return json({error: "Envía el JSON sin comprimir."}, 415);
    const raw = await readBody(request, LIMITS.body, `El envío supera el límite de ${LIMITS.body / 1048576} MiB.`);
    const digest = await sha256(raw);
    // From here on everything is synchronous, so a concurrent revocation or retry of the same body cannot interleave.
    key = store.keyByHash(hash);
    if (!key || key.revoked) return json({error: "La clave de la hermandad se ha revocado durante el envío."}, 401);
    if (store.uploadExists(key.memberId, digest)) return json({accepted: true, duplicate: true, rowsChanged: 0, day: T, message: "Este envío ya se había recibido: sin cambios."});
    const upload = validateUpload(parseObject(raw), {today: T, nowSec});
    const used = store.uploadsOn(key.memberId, T);
    if (used >= LIMITS.uploadsPerDay) return json({error: `Ya has hecho ${LIMITS.uploadsPerDay} envíos hoy, el máximo diario. Vuelve a intentarlo mañana.`}, 429);
    // The daily retention commits on its own first: a refused upload never undoes it, so a retry never repeats it.
    store.transaction(() => store.retain(T, nowSec));
    // Over the guild's daily write budget, ingest throws a 429 with Retry-After before writing anything.
    const report = store.transaction(() => {
      const result = store.ingest(upload, {member: key, digest, bytes: raw.byteLength, nowSec, T, budget: this.writeBudget()});
      store.saveWrites(nowSec);
      return result;
    });
    const changes = report.rowsChanged;
    return json({accepted: true, duplicate: false, day: T, rowsChanged: changes, markets: report.markets,
      uploadsToday: used + 1, uploadsLeft: LIMITS.uploadsPerDay - used - 1,
      message: changes ? `Envío aceptado: ${plural(changes, "cambio", "cambios")}.` : "Envío aceptado: sin cambios."});
  }

  admin(path, data, actor, nowSec) {
    const store = this.store, by = actor.kind === "owner" ? "owner" : "member:" + actor.memberId;
    if (!["/api/guild/members", "/api/guild/members/role", "/api/guild/members/revoke", "/api/guild/keys", "/api/guild/keys/revoke"].includes(path)) return json({error: "Ruta no encontrada."}, 404);
    if (!canAdmin(actor)) return json({error: "Solo quien administra la hermandad puede gestionar miembros y claves."}, 403);
    const ownerOnly = message => { if (actor.role !== "owner") fail(message, 403); };
    // An admin manages plain members and their own keys; other admins are the owner's.
    const target = id => {
      const member = store.member(requireId(id, "Miembro"));
      if (!member) fail("Ese miembro no existe.", 404);
      if (member.role === "admin" && member.id !== actor.memberId) ownerOnly("Solo el propietario puede gestionar a otro administrador.");
      return member;
    };
    if (path === "/api/guild/members") {
      const label = requireLabel(data.label), role = requireRole(data.role ?? "member");
      if (role === "admin") ownerOnly("Solo el propietario puede nombrar administradores.");
      return json({member: store.createMember({label, role, by, nowSec})});
    }
    if (path === "/api/guild/members/role") {
      ownerOnly("Solo el propietario puede cambiar roles.");
      const member = target(data.memberId), role = requireRole(data.role);
      if (member.revoked_at !== null) fail("Ese miembro está revocado.");
      store.setRole(member.id, role);
      return json({member: {id: member.id, label: member.label, role}});
    }
    if (path === "/api/guild/members/revoke") {
      const member = target(data.memberId);
      if (member.id === actor.memberId) fail("No puedes revocarte a ti mismo: pídeselo al propietario.");
      if (data.purge !== undefined && typeof data.purge !== "boolean") fail("purge debe ser true o false.");
      const result = store.revokeMember(member.id, nowSec, data.purge === true);
      return json({revoked: true, memberId: member.id, purged: result.purged});
    }
    if (path === "/api/guild/keys") {
      const member = target(data.memberId);
      if (member.revoked_at !== null) fail("Ese miembro está revocado: crea un miembro nuevo.");
      return this.newKey(member, nowSec);
    }
    const key = store.key(requireId(data.keyId, "Clave"));
    if (!key) fail("Esa clave no existe.", 404);
    target(key.member_id);
    store.revokeKey(key.id, nowSec);
    return json({revoked: true, keyId: key.id});
  }

  async newKey(member, nowSec) {
    const token = "gld_" + randomToken();
    const keyId = this.store.createKey(member.id, await sha256(token), nowSec);
    return json({key: token, keyId, memberId: member.id, label: member.label, createdAt: iso(nowSec),
      warning: "Copia la clave ahora: no se volverá a mostrar. Sirve para el sincronizador y para entrar en el panel."});
  }
}

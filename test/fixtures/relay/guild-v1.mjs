/** Guild market ("Hermandad") for the Oro de Hermandad addon. Every guild mate's PC uploads its OroHermandadHist
 * prices and the panel shows the merged market of the whole guild.
 *
 * Isolation: GuildMarket is its own Durable Object with its own SQLite, its own credential (personal gld_ member
 * keys, stored only as SHA-256), its own cookie and its own CSRF. It never reads or writes Portfolio data, and the
 * owner session only counts here as the guild owner. Money is integer copper and every market rule comes from
 * src/especular.mjs, the JS twin of the addon's Spec.lua (contract: test-vectors/especular-v1.json).
 *
 * Upload contract 3 (pc_sync/hermandad.py -> POST /api/guild/sync, Authorization: Bearer gld_...):
 *   {schema: 1, addon, markets: [{market: "<Reino>-Alliance|Horde", cut: bp|null, items: [{id, name, cat, vendor,
 *    days: [[d, lo, hi, last, qty, scans, "o"|"a"]], points: [[t, lo, qty, qty5]]}], deposits: [[id, dur, copper]]}]}
 * The whole body is validated before anything is written, and an identical body is recognised by its SHA-256. */
import {DAY0, LAUNCH, GUARD_DAYS, BUDGET, CUT_BP, PRICE_MAX, CATEGORIES, VERSION, median, quantile, dayIndex, mergeDay, dayValue,
  baseline, assess, flip, deltas, weekday, texts, idiv} from "../../../src/especular.mjs";

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
  cutMin: 100, cutMax: 2000, cutMembers: 2
});
/** Duration (luaIndex 1..3) whose learned deposit the summary flips use: the longest, which is the 24 h listing that
 * the vendor estimate assumes and never understates the cost. The item route returns all three. */
export const RESALE_DURATION = 3;
const SUMMARY_VERSION = VERSION + ":resumen-1";

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

// ---- Upload validation (contract 3). Throws a 400 naming the first problem; returns a normalised copy.
/** data: the parsed body. today: day index of now; nowSec: unix seconds. Unknown keys are ignored. */
export function validateUpload(data, {today, nowSec}) {
  const bad = (where, what) => fail(`Envío no válido${where ? ` (${where})` : ""}: ${what}.`);
  if (!plainObject(data)) bad("", "se esperaba un objeto JSON");
  if (data.schema !== 1) bad("", "schema debe ser 1");
  if (typeof data.addon !== "string" || !/^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$/.test(data.addon)) bad("", "addon debe ser la versión del addon, como \"0.3.0\"");
  if (!Array.isArray(data.markets) || data.markets.length > LIMITS.marketsPerUpload) bad("", `markets debe ser una lista de ${LIMITS.marketsPerUpload} mercados como máximo`);
  const maxDay = today + 1, maxTime = nowSec + 86400, seen = new Set();
  const price = `un entero entre 1 y ${PRICE_MAX} cobre`, qty = `un entero entre 0 y ${LIMITS.qtyMax}`;
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
      if (!Array.isArray(item.days) || item.days.length > LIMITS.daysPerItem) bad(at, `days debe ser una lista de ${LIMITS.daysPerItem} días como máximo`);
      if (!Array.isArray(item.points) || item.points.length > LIMITS.pointsPerItem) bad(at, `points debe ser una lista de ${LIMITS.pointsPerItem} puntos como máximo`);
      let previous = -Infinity;
      const days = item.days.map((r, ri) => {
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
        return {d, lo, hi, last, qty: quantity, scans, src};
      });
      previous = -Infinity;
      const points = item.points.map((r, ri) => {
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
      return {id: item.id, name: item.name, cat: item.cat, vendor: item.vendor, days, points};
    });
    const deposits = m.deposits === undefined ? [] : m.deposits;
    if (!Array.isArray(deposits) || deposits.length > LIMITS.itemsPerUpload * 9) bad(where, `deposits debe ser una lista de ${LIMITS.itemsPerUpload * 9} depósitos como máximo`);
    const pairs = new Set();
    return {market: m.market, cut: isInt(m.cut, 0, 9999) ? m.cut : null, items, deposits: deposits.map((r, ri) => {
      const here = `${where}, depósito n.º ${ri + 1}`;
      if (!Array.isArray(r) || r.length !== 3) bad(here, "cada depósito es [id, dur, copper]");
      const [id, dur, copper] = r;
      if (!isInt(id, 1, LIMITS.itemIdMax) || !isInt(dur, 1, 9) || !isInt(copper, 0, PRICE_MAX)) bad(here, `id positivo, dur entre 1 y 9 y copper entre 0 y ${PRICE_MAX}`);
      if (pairs.has(id + ":" + dur)) bad(here, "depósito repetido");
      pairs.add(id + ":" + dur);
      return {id, dur, copper};
    })};
  });
  return {schema: 1, addon: data.addon, markets};
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
      `INSERT OR IGNORE INTO guild_meta(key, value) VALUES ('schema', '1')`
    ]) this.sql.exec(statement);
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
    const out = members.map(m => {
      const own = keys.filter(k => k.member_id === m.id).map(k => ({id: k.id, createdAt: iso(k.created_at), lastUploadAt: iso(k.last_upload_at),
        lastLoginAt: iso(k.last_login_at), revoked: k.revoked_at !== null || m.revoked_at !== null, revokedAt: iso(k.revoked_at ?? m.revoked_at)}));
      const last = Math.max(0, ...keys.filter(k => k.member_id === m.id).map(k => k.last_upload_at ?? 0));
      return {id: m.id, label: m.label, role: m.role, createdAt: iso(m.created_at), revoked: m.revoked_at !== null, revokedAt: iso(m.revoked_at),
        lastUploadAt: last ? iso(last) : null, activeKeys: own.filter(k => !k.revoked).length, keys: own};
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
  /** Revokes a member and every key. purge also deletes their observations, vendor prices and the item names they
   * gave, recomputes the affected days and drops the items that are left without data. */
  revokeMember(id, nowSec, purge) {
    return this.transaction(() => {
      this.run("UPDATE guild_members SET revoked_at=? WHERE id=? AND revoked_at IS NULL", nowSec, id);
      this.run("UPDATE guild_keys SET revoked_at=? WHERE member_id=? AND revoked_at IS NULL", nowSec, id);
      if (!purge) return {purged: 0};
      let purged = 0;
      for (const {market} of this.rows("SELECT market FROM guild_member_markets WHERE member_id=?", id)) {
        const touched = new Map();
        for (const row of this.rows("SELECT item_id,day FROM guild_obs_day WHERE market=? AND member_id=?", market, id)) {
          if (!touched.has(row.item_id)) touched.set(row.item_id, new Set());
          touched.get(row.item_id).add(row.day);
        }
        purged += this.rows("DELETE FROM guild_obs_day WHERE market=? AND member_id=? RETURNING day", market, id).length;
        purged += this.rows("DELETE FROM guild_obs_point WHERE market=? AND member_id=? RETURNING t", market, id).length;
        purged += this.rows("DELETE FROM guild_deposits WHERE market=? AND member_id=? RETURNING copper", market, id).length;
        // A name this member gave is cleared; the next upload of the item names it again.
        this.run("UPDATE guild_items SET name='',name_by=NULL WHERE market=? AND name_by=?", market, id);
        const vendors = this.rows("DELETE FROM guild_item_vendor WHERE market=? AND member_id=? RETURNING item_id", market, id);
        for (const [item, days] of touched) this.aggregate(market, item, days);
        for (const {item_id} of vendors) this.shareVendor(market, item_id);
      }
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

  /** Writes a validated upload in two steps. First every market is planned with reads only: the rows whose merge
   * changes something (mergeDay for days, the addon's point merge for points, deposits, vendor prices and item
   * metadata). If those rows could take the guild past its daily write budget, nothing is written and a 429 says when
   * to come back. Otherwise the plan is written, the touched day aggregates are recomputed and the summaries of
   * changed markets are dropped. Returns the per-market report. */
  ingest(upload, {member, digest, bytes, nowSec, T, budget = Infinity}) {
    // The daily retention runs first, so the first upload of the day already sees the slots of pruned items.
    this.retain(T, nowSec);
    // Days before the launch window, past retention or before the member's backfill limit, and points older than
    // 14 days, are valid but not stored.
    const scope = {member, T, oldestDay: Math.max(LIMITS.minDay, T - LIMITS.retentionDays), oldestPoint: nowSec - LIMITS.pointSeconds, added: new Set()};
    const report = {rowsChanged: 0, markets: []}, plans = [];
    // Upper bound of the rows Cloudflare will count: the receipt (and its index entry) and the key, then per market
    // its rows; a new day row and its aggregate each write the table and one index entry, a new point its row and its
    // time index and perhaps the removal of an old point, a vendor price its row, its index entry and the shared one.
    let estimate = 3;
    for (const m of upload.markets) {
      const entry = {market: m.market, items: 0, days: 0, points: 0, deposits: 0, skippedItems: [], skipped: null};
      report.markets.push(entry);
      const plan = this.planMarket(m, entry, scope);
      if (!plan) continue;
      plans.push(plan);
      estimate += plan.inserts.length + plan.updates.length + 3 * plan.vendors.length + 4 * plan.days.length + 4 * plan.points.length + plan.deposits.length + 2;
    }
    if (this.writesToday(nowSec) + estimate > budget) {
      const reset = (utcDay(nowSec) + 1) * 86400;
      const clock = new Intl.DateTimeFormat("es-ES", {timeZone: "Europe/Madrid", hour: "2-digit", minute: "2-digit", hourCycle: "h23"}).format(new Date(reset * 1000));
      fail(`La hermandad ha agotado por hoy su cuota de escritura en el panel (${new Intl.NumberFormat("es-ES").format(budget)} filas al día). ` +
        `Los precios se guardarán a partir de ${clock.startsWith("01:") ? "la" : "las"} ${clock} (hora de España): el subidor lo volverá a intentar solo.`,
        429, {"Retry-After": String(reset - nowSec + 60)});
    }
    for (const plan of plans) report.rowsChanged += this.applyMarket(plan, {member, addon: upload.addon, nowSec, T});
    this.run("INSERT INTO guild_uploads(member_id,sha256,key_id,received_at,day,bytes,rows_changed) VALUES (?,?,?,?,?,?,?)",
      member.memberId, digest, member.keyId, nowSec, T, bytes, report.rowsChanged);
    this.run("UPDATE guild_keys SET last_upload_at=? WHERE id=?", nowSec, member.keyId);
    return report;
  }

  /** The rows one market of an upload would change, read but not written; null when the market is skipped. */
  planMarket(m, entry, {member, T, oldestDay, oldestPoint, added}) {
    const known = this.rows("SELECT cut,since FROM guild_member_markets WHERE market=? AND member_id=?", m.market, member.memberId)[0];
    if (!known && !this.marketKnown(m.market)) {
      if (this.rows("SELECT count(DISTINCT market) AS n FROM guild_member_markets")[0].n + added.size >= LIMITS.markets) {
        entry.skipped = "LIMITE_DE_MERCADOS";
        return null;
      }
      added.add(m.market);
    }
    const since = known ? known.since : T - LIMITS.backfillDays + 1, firstDay = Math.max(oldestDay, since);
    const plan = {m, entry, known, since, cut: m.cut ?? known?.cut ?? null, accepted: new Set(),
      inserts: [], updates: [], vendors: [], days: [], points: [], deposits: []};
    // Item metadata. Watchlist items always fit; the rest share what is left of the 300 slots.
    const items = new Map(this.rows("SELECT item_id,name,category,vendor,watch,name_by FROM guild_items WHERE market=?", m.market).map(r => [r.item_id, r]));
    const vendors = new Map(this.rows("SELECT item_id,vendor FROM guild_item_vendor WHERE market=? AND member_id=?", m.market, member.memberId).map(r => [r.item_id, r.vendor]));
    let extras = [...items.values()].filter(r => !r.watch).length;
    for (const item of m.items) {
      const watchCat = WATCH.get(item.id), prior = items.get(item.id);
      const days = item.days.filter(r => r.d >= firstDay), points = item.points.filter(p => p.t >= oldestPoint);
      if (!prior) {
        // A new item needs a day to store: without one it would hold a slot (and a name) with nothing to show.
        if (!days.length) continue;
        if (!watchCat && extras >= LIMITS.itemsPerMarket - WATCH.size) { entry.skippedItems.push(item.id); continue; }
        if (!watchCat) extras++;
        plan.inserts.push({id: item.id, name: item.name, cat: watchCat ?? item.cat, vendor: item.vendor, watch: watchCat ? 1 : 0});
      } else {
        // The first non-empty name wins, watchlist categories are fixed and an extra only leaves "otro" for a real
        // category: one member cannot rename an item for everyone, and clients in other languages do not flip it.
        // An extra that has since joined the watchlist becomes a watchlist item here.
        const name = prior.name || item.name, cat = watchCat ?? (prior.category === "otro" ? item.cat : prior.category), watch = watchCat ? 1 : 0;
        if (name !== prior.name || cat !== prior.category || watch !== prior.watch) plan.updates.push({id: item.id, name, cat, watch, nameBy: name !== prior.name ? member.memberId : prior.name_by});
      }
      // Each member's vendor price is kept (0 is unknown); the shared one is their lower median (shareVendor).
      if (item.vendor > 0 && vendors.get(item.id) !== item.vendor) plan.vendors.push({id: item.id, vendor: item.vendor});
      plan.accepted.add(item.id);
      entry.items++;
      // Days: one row per member, item and day, merged with especular.mergeDay (an own record beats an import). Only
      // this member's rows for the days in the body are read (a primary key range), never their whole history.
      if (days.length) {
        const stored = new Map(this.rows("SELECT day,lo,hi,last,qty,scans,src FROM guild_obs_day WHERE market=? AND member_id=? AND item_id=? AND day>=? AND day<=?",
          m.market, member.memberId, item.id, days[0].d, days[days.length - 1].d)
          .map(r => [r.day, {d: r.day, lo: r.lo, hi: r.hi, last: r.last, qty: r.qty, scans: r.scans, src: r.src}]));
        for (const record of days) {
          const prior = stored.get(record.d), merged = mergeDay(prior, record);
          if (prior && merged.lo === prior.lo && merged.hi === prior.hi && merged.last === prior.last && merged.qty === prior.qty &&
              merged.scans === prior.scans && merged.src === prior.src) continue;
          plan.days.push({id: item.id, d: record.d, lo: merged.lo, hi: merged.hi, last: merged.last, qty: merged.qty, scans: merged.scans, src: merged.src});
        }
      }
      // Points: the addon's merge for the same time (lo = min, qty = max, qty5 of the cheaper point).
      if (points.length) {
        const stored = new Map(this.rows("SELECT t,lo,qty,qty5 FROM guild_obs_point WHERE market=? AND member_id=? AND item_id=? AND t>=? AND t<=?",
          m.market, member.memberId, item.id, points[0].t, points[points.length - 1].t).map(r => [r.t, r]));
        for (const point of points) {
          const prior = stored.get(point.t);
          let next = point;
          if (prior) {
            const qty5 = point.lo < prior.lo ? point.qty5 : point.lo === prior.lo ? Math.max(prior.qty5, point.qty5) : prior.qty5;
            next = {t: point.t, lo: Math.min(prior.lo, point.lo), qty: Math.max(prior.qty, point.qty), qty5};
            if (next.lo === prior.lo && next.qty === prior.qty && next.qty5 === prior.qty5) continue;
          }
          plan.points.push({id: item.id, t: next.t, lo: next.lo, qty: next.qty, qty5: next.qty5});
        }
      }
    }
    // Deposits learned with the auction house open, only for items stored in this market.
    const deposits = new Map(this.rows("SELECT item_id,duration,copper FROM guild_deposits WHERE market=? AND member_id=?", m.market, member.memberId)
      .map(r => [r.item_id + ":" + r.duration, r.copper]));
    for (const deposit of m.deposits) {
      if (!plan.accepted.has(deposit.id) && !items.has(deposit.id)) continue;
      if (deposits.get(deposit.id + ":" + deposit.dur) === deposit.copper) continue;
      plan.deposits.push(deposit);
    }
    return plan;
  }

  /** Writes one planned market. Returns the rows the member changed (the report's rowsChanged). */
  applyMarket(plan, {member, addon, nowSec, T}) {
    const {m, entry, known} = plan, market = m.market;
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
    for (const x of plan.days) {
      this.run(`INSERT INTO guild_obs_day(market,member_id,item_id,day,lo,hi,last,qty,scans,src,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(market,member_id,item_id,day) DO UPDATE SET lo=excluded.lo,hi=excluded.hi,last=excluded.last,qty=excluded.qty,
        scans=excluded.scans,src=excluded.src,updated_at=excluded.updated_at`,
        market, member.memberId, x.id, x.d, x.lo, x.hi, x.last, x.qty, x.scans, x.src, nowSec);
      if (!touched.has(x.id)) touched.set(x.id, new Set());
      touched.get(x.id).add(x.d);
    }
    // 14 days and 200 points per member and item; only points of today change today's summary.
    const pointItems = new Set();
    for (const x of plan.points) {
      this.run(`INSERT INTO guild_obs_point(market,member_id,item_id,t,lo,qty,qty5) VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(market,member_id,item_id,t) DO UPDATE SET lo=excluded.lo,qty=excluded.qty,qty5=excluded.qty5`,
        market, member.memberId, x.id, x.t, x.lo, x.qty, x.qty5);
      pointItems.add(x.id);
      if (x.t >= dayStart(T)) shown++;
    }
    for (const id of pointItems) {
      this.run(`DELETE FROM guild_obs_point WHERE market=? AND member_id=? AND item_id=? AND t<(SELECT t FROM guild_obs_point
        WHERE market=? AND member_id=? AND item_id=? ORDER BY t DESC LIMIT 1 OFFSET ?)`, market, member.memberId, id, market, member.memberId, id, LIMITS.pointsKept - 1);
    }
    for (const x of plan.deposits) {
      this.run(`INSERT INTO guild_deposits(market,member_id,item_id,duration,copper,updated_at) VALUES (?,?,?,?,?,?)
        ON CONFLICT(market,member_id,item_id,duration) DO UPDATE SET copper=excluded.copper,updated_at=excluded.updated_at`,
        market, member.memberId, x.id, x.dur, x.copper, nowSec);
    }
    for (const [item, days] of touched) shown += this.aggregate(market, item, days);
    this.run(`INSERT INTO guild_member_markets(market,member_id,cut,addon,last_upload_at,since) VALUES (?,?,?,?,?,?)
      ON CONFLICT(market,member_id) DO UPDATE SET cut=excluded.cut,addon=excluded.addon,last_upload_at=excluded.last_upload_at`,
      market, member.memberId, plan.cut, addon, nowSec, plan.since);
    Object.assign(entry, {days: plan.days.length, points: plan.points.length, deposits: plan.deposits.length});
    shown += plan.inserts.length + plan.updates.length + plan.deposits.length;
    if (shown > 0 || (known?.cut ?? null) !== plan.cut) this.run("DELETE FROM guild_summary_cache WHERE market=?", market);
    return plan.inserts.length + plan.updates.length + plan.vendors.length + plan.days.length + plan.points.length + plan.deposits.length;
  }

  /** The shared vendor price of an item: the lower median of what members sent, so that one member alone cannot
   * inflate it (and with it the estimated deposit, which would hide every chollo of the item). Returns 1 if it changed. */
  shareVendor(market, id) {
    const values = this.rows("SELECT vendor FROM guild_item_vendor WHERE market=? AND item_id=?", market, id).map(r => r.vendor);
    const vendor = values.length ? quantile(values, 1, 2) : 0;
    return this.rows("UPDATE guild_items SET vendor=? WHERE market=? AND item_id=? AND vendor<>? RETURNING item_id", vendor, market, id, vendor).length;
  }

  /** Recomputes guild_day_agg for some days of one item from every member's merged day (especular.dayValue, with its
   * outlier guard from 3 members). lo and hi are those of the members that were kept. Rows that come out the same are
   * not written again. Returns how many aggregate rows changed. */
  aggregate(market, item, days) {
    const list = [...days], from = Math.min(...list), to = Math.max(...list);
    const rows = this.rows("SELECT day,member_id,lo,hi,qty FROM guild_obs_day WHERE market=? AND item_id=? AND day>=? AND day<=? ORDER BY day,member_id",
      market, item, from, to);
    const current = new Map(this.rows("SELECT day,v,lo,hi,qty,observers,members FROM guild_day_agg WHERE market=? AND item_id=? AND day>=? AND day<=?",
      market, item, from, to).map(r => [r.day, r]));
    const byDay = new Map();
    for (const r of rows) { if (!byDay.has(r.day)) byDay.set(r.day, []); byDay.get(r.day).push(r); }
    let changed = 0;
    for (const d of list) {
      const observers = byDay.get(d) ?? [], prior = current.get(d);
      const value = dayValue(observers.map(r => ({lo: r.lo, hi: r.hi, qty: r.qty, id: String(r.member_id)})));
      if (!value) {
        if (prior) { this.run("DELETE FROM guild_day_agg WHERE market=? AND item_id=? AND day=?", market, item, d); changed++; }
        continue;
      }
      const kept = observers.filter(r => value.ids.includes(String(r.member_id)));
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

  /** Retention, at most once per day: days older than T-180, points older than 14 days, upload receipts of 180 days,
   * and then the items left without days. */
  retain(T, nowSec) {
    if (this.rows("SELECT value FROM guild_meta WHERE key='retention_day'")[0]?.value === String(T)) return;
    this.run("DELETE FROM guild_obs_day WHERE day<?", T - LIMITS.retentionDays);
    this.run("DELETE FROM guild_day_agg WHERE day<?", T - LIMITS.retentionDays);
    this.run("DELETE FROM guild_obs_point WHERE t<?", nowSec - LIMITS.pointSeconds);
    this.run("DELETE FROM guild_uploads WHERE day<?", T - LIMITS.retentionDays);
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
    return this.rows(`SELECT market,max(last_upload_at) AS last,sum(CASE WHEN last_upload_at>=? THEN 1 ELSE 0 END) AS contributors
      FROM guild_member_markets GROUP BY market ORDER BY last DESC,market`, nowSec - 14 * 86400)
      .map(r => ({market: r.market, items: items.get(r.market) ?? 0, contributors: r.contributors, lastUploadAt: iso(r.last)}));
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
  /** Lowest scan point of each item on day T across members (ties: the newest), with who and when. */
  lowestPoints(market, T, labels, item = null) {
    const rows = this.rows(`SELECT item_id,member_id,t,lo,qty,qty5 FROM guild_obs_point WHERE market=? AND t>=? AND t<?${item === null ? "" : " AND item_id=?"}
      ORDER BY item_id,lo,t DESC,member_id`, market, dayStart(T), dayStart(T + 1), ...(item === null ? [] : [item]));
    const out = new Map();
    for (const r of rows) {
      if (!out.has(r.item_id)) out.set(r.item_id, {lo: r.lo, qty: r.qty, qty5: r.qty5, t: r.t, at: iso(r.t), member: labels.get(String(r.member_id)) ?? null});
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

  /** Who uploaded to a market and when. Not cached: an upload without new data still counts as fresh. */
  freshness(market, T, nowSec) {
    const rows = this.rows("SELECT member_id,last_upload_at FROM guild_member_markets WHERE market=? ORDER BY last_upload_at DESC,member_id", market);
    const last = rows[0], label = last ? this.member(last.member_id)?.label ?? null : null;
    return {lastUploadAt: iso(last?.last_upload_at), lastUploadBy: label, contributors: rows.filter(r => r.last_upload_at >= nowSec - 14 * 86400).length,
      contributorsToday: rows.filter(r => r.last_upload_at >= dayStart(T)).length};
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

  /** Item detail: 60 days of the merged market, 14 days of every member's points, the weekday pattern and the
   * calculator defaults (flip with the lowest point today, whatever the verdict). null for an unknown item. */
  item(market, id, T, nowSec) {
    const item = this.rows("SELECT item_id,name,category,vendor,watch FROM guild_items WHERE market=? AND item_id=?", market, id)[0];
    if (!item) return null;
    const labels = this.labels(), {cutBp} = this.cut(market);
    const series = this.dayMap(this.rows("SELECT item_id,day,v,lo,hi,qty,observers,members FROM guild_day_agg WHERE market=? AND item_id=? AND day<=? ORDER BY day",
      market, id, T)).get(id) ?? {};
    const price = this.lowestPoints(market, T, labels, id).get(id) ?? null;
    const b = baseline(series, T, {cloud: true}), a = assess(b, price ? price.lo : null, T), d = deltas(series, T);
    const w = weekday(series, T, {watch: item.watch === 1});
    const deposits = [1, 2, 3].map(duration => {
      const found = this.depositsFor(market, duration, id).get(id);
      return {duration, D: found ? found.D : null, members: found ? found.members : 0};
    });
    const resale = deposits.find(x => x.duration === RESALE_DURATION);
    const f = flip(b, null, {cutBp, D: resale.D, vendor: item.vendor, budget: BUDGET, p: price ? price.lo : null, q5: price ? price.qty5 : null});
    const points = this.rows("SELECT member_id FROM guild_member_markets WHERE market=?", market).flatMap(({member_id}) =>
      this.rows("SELECT member_id,t,lo,qty,qty5 FROM guild_obs_point WHERE market=? AND member_id=? AND item_id=? AND t>=?", market, member_id, id, nowSec - LIMITS.pointSeconds))
      .sort((x, y) => x.t - y.t || x.member_id - y.member_id)
      .map(r => ({t: r.t, at: iso(r.t), lo: r.lo, qty: r.qty, qty5: r.qty5, member: labels.get(String(r.member_id)) ?? null}));
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

  csvSummary(summary) {
    const rows = [["Objeto", "ID", "Categoría", "Hoy (oro)", "Más bajo hoy (oro)", "Visto por", "Normal 14 d (oro)", "Δ1d (%)", "Δ7d (%)",
      "Mín 14 d (oro)", "Máx 14 d (oro)", "Oferta típica", "Miembros", "Días con datos", "Confianza", "Veredicto"]];
    for (const e of summary.items) {
      rows.push([textCell(e.name || `Objeto ${e.id}`), intCell(e.id), textCell(e.catLabel), goldCell(e.today?.v), goldCell(e.price?.lo), textCell(e.price?.member),
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
    const out = [["Fecha", "Día", "Objeto", "ID", "Categoría", "Valor (oro)", "Mín (oro)", "Máx (oro)", "Cantidad", "Miembros"]];
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

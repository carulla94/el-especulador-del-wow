/**
 * Fishing sessions recorded by the Forever Fishing addon, sent by the PC uploader (pc_sync/hermandad.py ->
 * POST /api/guild/fishing, Authorization: Bearer gld_...) and shown in the Pesca tab (GET /api/guild/fishing).
 *
 * Upload contract (schema 1), only numbers and place names, never a character name or code:
 *   {schema: 1, source: "ForeverFishing", sessions: [{start, end, seconds, casts, catches,
 *    zones: {"Zona: Subzona": {"<item id>": count}}}]}
 * start/end: unix seconds of the session; seconds: the time with the rod in hand (Forever Fishing's activeSeconds);
 * zones: what was caught where ("?" for catches without a place). A session is identified by its start: sending it again
 * replaces it (a session still open grows), and unchanged sessions are not written again.
 *
 * The panel values every session with the day's prices (public/hermandad.js fishingSessionRows), so nothing here
 * depends on a market.
 */
import {DAY0} from "./especular.mjs";

export const FISHING = Object.freeze({
  body: 256 * 1024,
  sessionsPerUpload: 200,
  zonesPerSession: 40,
  itemsPerZone: 80,
  zoneMax: 80,
  countMax: 100000,
  sessionSeconds: 7 * 86400,
  postsPerHour: 30,
  // The newest sessions GET returns (per member, or of the whole guild for the owner), and how far back they reach.
  sessionsShown: 100,
  shownDays: 90,
  // Oldest session start accepted: a week before the expansion's launch day (2026-11-04).
  minStart: DAY0 + 2492 * 86400
});

const isInt = (x, lo, hi) => Number.isSafeInteger(x) && x >= lo && x <= hi;
const plainObject = value => !!value && typeof value === "object" && !Array.isArray(value);
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;

function fail(message, status = 400) { const error = new Error(message); error.status = status; throw error; }

/** The upload, checked and normalised: {source, sessions: [{start, end, seconds, casts, catches, zones}]} with the zones
 * and their items in a stable order (so an unchanged session gives the same JSON). Throws a 400 naming the first problem.
 * Unknown keys are ignored. */
export function validateFishing(data, {nowSec}) {
  const bad = (where, what) => fail(`Envío de pesca no válido${where ? ` (${where})` : ""}: ${what}.`);
  if (!plainObject(data)) bad("", "se esperaba un objeto JSON");
  if (data.schema !== 1) bad("", "schema debe ser 1");
  if (typeof data.source !== "string" || !/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}$/.test(data.source)) bad("", "source debe ser el nombre del addon, como \"ForeverFishing\"");
  if (!Array.isArray(data.sessions) || data.sessions.length > FISHING.sessionsPerUpload) bad("", `sessions debe ser una lista de ${FISHING.sessionsPerUpload} sesiones como máximo`);
  const latest = nowSec + 86400, starts = new Set(), count = `un entero entre 0 y ${FISHING.countMax}`;
  const sessions = data.sessions.map((s, index) => {
    const at = `sesión ${index + 1}`;
    if (!plainObject(s)) bad(at, "cada sesión es un objeto");
    if (!isInt(s.start, FISHING.minStart, latest)) bad(at, "start debe ser la hora de inicio (segundos unix) desde finales de octubre de 2026");
    if (!isInt(s.end, s.start, latest) || s.end - s.start > FISHING.sessionSeconds) bad(at, "end debe ser la hora de fin, como mucho una semana después del inicio");
    if (starts.has(s.start)) bad(at, "hay dos sesiones con el mismo inicio");
    starts.add(s.start);
    if (!isInt(s.seconds, 0, FISHING.sessionSeconds)) bad(at, "seconds debe ser el tiempo pescando, en segundos");
    for (const key of ["casts", "catches"]) if (!isInt(s[key], 0, FISHING.countMax)) bad(at, `${key} debe ser ${count}`);
    if (!plainObject(s.zones) || Object.keys(s.zones).length > FISHING.zonesPerSession) bad(at, `zones debe ser un objeto con ${FISHING.zonesPerSession} lugares como máximo`);
    const zones = {};
    for (const place of Object.keys(s.zones).sort()) {
      const name = place.normalize("NFC");
      if (!name.trim() || name.length > FISHING.zoneMax || CONTROL.test(name)) bad(at, `cada lugar es un texto de 1 a ${FISHING.zoneMax} caracteres`);
      const items = s.zones[place];
      if (!plainObject(items) || Object.keys(items).length > FISHING.itemsPerZone) bad(`${at}, ${name}`, `cada lugar lleva ${FISHING.itemsPerZone} objetos como máximo`);
      // Two spellings of one place (NFC) add up.
      const clean = zones[name] ?? {};
      for (const id of Object.keys(items)) {
        if (!/^[1-9][0-9]{0,9}$/.test(id) || Number(id) > 2147483647) bad(`${at}, ${name}`, "cada objeto va por su ID numérico");
        if (!isInt(items[id], 1, FISHING.countMax)) bad(`${at}, ${name}`, `cada cantidad debe ser un entero entre 1 y ${FISHING.countMax}`);
        clean[id] = Math.min(FISHING.countMax, (clean[id] ?? 0) + items[id]);
      }
      if (Object.keys(clean).length) zones[name] = Object.fromEntries(Object.entries(clean).sort(([a], [b]) => Number(a) - Number(b)));
    }
    return {start: s.start, end: s.end, seconds: s.seconds, casts: s.casts, catches: s.catches, zones};
  });
  return {source: data.source, sessions};
}

/** What GET /api/guild/fishing answers from the stored rows ({member_id, label, start, end_at, seconds, casts, catches,
 * zones (JSON)}), newest first. scope "mine": a member sees their own sessions; "guild": the owner sees everyone's, with
 * the member's label. guild: every stored session added up (what bites where, for everybody). */
export function fishingReport(rows, {scope, memberId = null, nowSec}) {
  const parsed = rows.map(r => ({...r, zones: JSON.parse(r.zones)})).sort((a, b) => b.start - a.start || a.member_id - b.member_id);
  const since = nowSec - FISHING.shownDays * 86400;
  const shown = parsed.filter(r => r.end_at >= since && (scope === "guild" || r.member_id === memberId)).slice(0, FISHING.sessionsShown);
  const zones = {}, members = new Set();
  let catches = 0, seconds = 0;
  for (const r of parsed) {
    members.add(r.member_id); catches += r.catches; seconds += r.seconds;
    for (const [place, items] of Object.entries(r.zones)) {
      const z = zones[place] ??= {};
      for (const [id, n] of Object.entries(items)) z[id] = (z[id] ?? 0) + n;
    }
  }
  return {
    scope,
    sessions: shown.map(r => ({start: r.start, end: r.end_at, seconds: r.seconds, casts: r.casts, catches: r.catches, zones: r.zones,
      ...(scope === "guild" ? {member: r.label} : {})})),
    guild: {sessions: parsed.length, members: members.size, catches, seconds, zones}
  };
}

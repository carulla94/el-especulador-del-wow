// Forever Fishing sessions on the server: what an upload may carry (validateFishing) and what the panel reads back
// (fishingReport). The HTTP side, the table and the purge are in guild.test.mjs.
import test from "node:test";
import assert from "node:assert/strict";
import {FISHING, validateFishing, fishingReport} from "../src/fishing.mjs";
import {DAY0} from "../src/especular.mjs";

const DAY = 86400;
const NOW = DAY0 + 2513 * DAY + 18 * 3600;          // 2026-11-18 18:00 UTC
const session = (start, extra = {}) => ({start, end: start + 1900, seconds: 1800, casts: 100, catches: 90, zones: {"Feralas: Costa": {"13422": 90}}, ...extra});
const body = sessions => ({schema: 1, source: "ForeverFishing", sessions});
const check = data => validateFishing(data, {nowSec: NOW});
const refused = (data, pattern) => assert.throws(() => check(data), error => error.status === 400 && pattern.test(error.message));

test("validateFishing keeps numbers and places only, in a stable order, and adds up two spellings of one place", () => {
  const nfd = "Bahía", nfc = "Bahía";
  const result = check({...body([session(NOW - 7200, {
    character: "Nombre", realm: "Reino", owner: "x",
    zones: {[`Azshara: ${nfd}`]: {"13422": 5, "6359": 1}, [`Azshara: ${nfc}`]: {"13422": 2}, "?": {"6358": 3}, "Vacío": {}}
  })]), extra: true});
  assert.deepEqual(result, {source: "ForeverFishing", sessions: [{start: NOW - 7200, end: NOW - 7200 + 1900, seconds: 1800, casts: 100, catches: 90,
    zones: {"?": {"6358": 3}, [`Azshara: ${nfc}`]: {"6359": 1, "13422": 7}}}]});
  assert.deepEqual(Object.keys(result.sessions[0]), ["start", "end", "seconds", "casts", "catches", "zones"], "no name travels on");
  // Same data in another order gives the same JSON (so an unchanged session is not written again).
  const again = check(body([session(NOW - 7200, {zones: {"?": {"6358": 3}, [`Azshara: ${nfc}`]: {"13422": 7, "6359": 1}}})]));
  assert.equal(JSON.stringify(again.sessions[0].zones), JSON.stringify(result.sessions[0].zones));
  assert.deepEqual(check(body([])), {source: "ForeverFishing", sessions: []});
});

test("validateFishing refuses what is not a session of the addon, naming the first problem", () => {
  refused(null, /se esperaba un objeto JSON/);
  refused([], /se esperaba un objeto JSON/);
  refused({...body([]), schema: "1"}, /schema debe ser 1/);
  refused({...body([]), source: "<script>"}, /source/);
  refused({schema: 1, source: "ForeverFishing"}, /sessions debe ser una lista/);
  refused(body(Array.from({length: FISHING.sessionsPerUpload + 1}, (_, i) => session(NOW - 86400 + i * 60))), /200 sesiones/);
  refused(body([session(FISHING.minStart - 1)]), /\(sesión 1\): start/);
  refused(body([session(NOW + 2 * DAY)]), /start/);
  refused(body([session(NOW - 3600, {end: NOW - 7200})]), /end debe ser/);
  refused(body([session(NOW - 8 * DAY, {end: NOW})]), /una semana/);
  refused(body([session(NOW - 7200), session(NOW - 7200)]), /\(sesión 2\): hay dos sesiones con el mismo inicio/);
  refused(body([session(NOW - 7200, {seconds: 1.5})]), /seconds/);
  refused(body([session(NOW - 7200, {casts: -1})]), /casts debe ser un entero/);
  refused(body([session(NOW - 7200, {catches: FISHING.countMax + 1})]), /catches/);
  refused(body([session(NOW - 7200, {zones: []})]), /zones debe ser un objeto/);
  refused(body([session(NOW - 7200, {zones: Object.fromEntries(Array.from({length: 41}, (_, i) => ["Z" + i, {"1": 1}]))})]), /40 lugares/);
  refused(body([session(NOW - 7200, {zones: {"  ": {"1": 1}}})]), /cada lugar es un texto/);
  refused(body([session(NOW - 7200, {zones: {["x".repeat(81)]: {"1": 1}}})]), /cada lugar es un texto/);
  refused(body([session(NOW - 7200, {zones: {"Feralas\n": {"1": 1}}})]), /cada lugar es un texto/);
  refused(body([session(NOW - 7200, {zones: {"Feralas": Object.fromEntries(Array.from({length: 81}, (_, i) => [String(i + 1), 1]))}})]), /\(sesión 1, Feralas\): cada lugar lleva 80/);
  for (const id of ["0", "01", "abc", "2147483648", "1.5"]) refused(body([session(NOW - 7200, {zones: {"Feralas": {[id]: 1}}})]), /ID numérico/);
  for (const n of [0, -1, 1.5, "3", FISHING.countMax + 1]) refused(body([session(NOW - 7200, {zones: {"Feralas": {"13422": n}}})]), /cada cantidad/);
});

test("fishingReport: a member sees their own sessions of the last 90 days, the owner everyone's, and both the guild's totals", () => {
  const row = (member_id, label, start, catches, zones) => ({member_id, label, start, end_at: start + 1900, seconds: 1800, casts: catches + 10, catches, zones: JSON.stringify(zones)});
  const rows = [
    row(1, "Ana", NOW - DAY, 90, {"Feralas: Costa": {"13422": 80, "6358": 10}}),
    row(2, "Bruno", NOW - 2 * DAY, 50, {"Feralas: Costa": {"13422": 50}}),
    row(1, "Ana", NOW - 100 * DAY, 40, {"Azshara": {"13422": 40}})
  ];
  const mine = fishingReport(rows, {scope: "mine", memberId: 1, nowSec: NOW});
  assert.equal(mine.scope, "mine");
  assert.deepEqual(mine.sessions, [{start: NOW - DAY, end: NOW - DAY + 1900, seconds: 1800, casts: 100, catches: 90, zones: {"Feralas: Costa": {"13422": 80, "6358": 10}}}],
    "their own only, without labels, and not the one of 100 days ago");
  assert.deepEqual(mine.guild, {sessions: 3, members: 2, catches: 180, seconds: 5400,
    zones: {"Feralas: Costa": {"13422": 130, "6358": 10}, "Azshara": {"13422": 40}}}, "what bites where counts every stored session");
  const guild = fishingReport(rows, {scope: "guild", nowSec: NOW});
  assert.deepEqual(guild.sessions.map(s => [s.member, s.start]), [["Ana", NOW - DAY], ["Bruno", NOW - 2 * DAY]]);
  assert.deepEqual(fishingReport([], {scope: "mine", memberId: 1, nowSec: NOW}), {scope: "mine", sessions: [], guild: {sessions: 0, members: 0, catches: 0, seconds: 0, zones: {}}});
  const many = Array.from({length: FISHING.sessionsShown + 5}, (_, i) => row(1, "Ana", NOW - (i + 1) * 3600, 10, {}));
  const newest = fishingReport(many, {scope: "mine", memberId: 1, nowSec: NOW}).sessions;
  assert.equal(newest.length, FISHING.sessionsShown);
  assert.equal(newest[0].start, NOW - 3600);
});

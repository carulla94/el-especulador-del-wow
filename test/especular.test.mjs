import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import crypto from "node:crypto";
import * as E from "../src/especular.mjs";
import {dayIndex, weekdayOf, mergeDay, dayValue, buildDays, baseline, assess, flip, deltas, weekday, texts, money, idiv, ceilDiv} from "../src/especular.mjs";

// The shared contract with the addon (addon/OroHermandad/Spec.lua): copied byte for byte, never edited here.
// The hash ignores CRLF line endings, which a Windows checkout may add.
const VECTORS_URL = new URL("../test-vectors/especular-v1.json", import.meta.url);
const VECTORS_SHA256 = "632f59ed4da86eff6fda3cad4d4f72e77b736dc569235b6942912cddac9793d4";
const raw = fs.readFileSync(VECTORS_URL, "utf8").replace(/\r\n/g, "\n");
const vectors = JSON.parse(raw);

// Vector days {"<d>": [[lo, hi, qty, obs, src?], ...]} -> buildDays input (the key check is buildDays' own job).
function vectorDays(obj) {
  return Object.fromEntries(Object.entries(obj).map(([key, records]) => [key,
    records.map(([lo, hi, qty, id, src]) => ({lo, hi, qty, id, src}))]));
}
// The vector pipeline of the contract's "format" section, exactly as test-lua/test_spec.lua runs it.
function evaluate(input) {
  const days = buildDays(vectorDays(input.days));
  const b = baseline(days, input.T, {cloud: input.cloud === true});
  const a = assess(b, input.p ?? null, input.T);
  const f = a.verdict === "CHOLLO" || input.calc === true ? flip(b, input.book ?? null, {cutBp: input.cutBp, u: input.u,
    D: input.D, vendor: input.vendor, F: input.F, budget: input.budget, Q: input.Q, p: input.p, q5: input.q5}) : null;
  const {d1, d7} = deltas(days, input.T);
  const out = {flip: f, d1, d7, values: days, texts: {conf: texts.conf(b), status: texts.status(a, b)}};
  for (const key of ["status", "n", "k", "N", "MAD", "sBp", "R3", "O7", "trend", "trendBp", "fresh", "conf", "Rs", "Q"]) out[key] = b[key];
  for (const key of ["verdict", "guard", "wait", "dBp", "band", "dumpLine", "spikeLine", "shiftLine"]) out[key] = a[key];
  return out;
}
// Every expected key with exact equality; null means "no value" (null or undefined).
function compare(expected, actual, path, diffs = []) {
  if (expected === null) { if (actual !== null && actual !== undefined) diffs.push(`${path}: esperado null, obtenido ${JSON.stringify(actual)}`); }
  else if (typeof expected === "object") {
    if (actual === null || typeof actual !== "object") diffs.push(`${path}: esperado un objeto, obtenido ${JSON.stringify(actual)}`);
    else for (const [key, value] of Object.entries(expected)) compare(value, actual[key], `${path}.${key}`, diffs);
  } else if (expected !== actual) diffs.push(`${path}: esperado ${JSON.stringify(expected)}, obtenido ${JSON.stringify(actual)}`);
  return diffs;
}
const caseNamed = name => structuredClone(vectors.cases.find(item => item.name === name));

test("vector file is the byte-identical especular-v1 contract with enough cases", () => {
  assert.equal(crypto.createHash("sha256").update(raw).digest("hex"), VECTORS_SHA256, "rule changes go to especular-v2.json");
  assert.equal(vectors.contract, E.VERSION);
  const names = vectors.cases.map(item => item.name);
  assert.equal(new Set(names).size, names.length, "unique case names");
  assert.ok(vectors.cases.filter(item => !item.js_only).length >= 25);
  assert.ok(vectors.cases.filter(item => item.kind === "weekday").length >= 2);
  const c = vectors.constants;
  assert.deepEqual([c.DAY0, c.LAUNCH, c.GUARD_DAYS, c.GUARD_UNTIL_DAY, c.WINDOW_DAYS, c.MIN_DAYS, c.PRICE_MAX, c.QTY_MAX, c.UNITS_MAX,
    c.SBP_FLOOR, c.CUT_BP_DEFAULT, c.UNDERCUT_DEFAULT, c.FAILED_LISTINGS_DEFAULT, c.BUDGET_DEFAULT, c.MIN_PROFIT, c.MIN_MARGIN_PCT,
    c.CAP_LIQ_DEFAULT], [E.DAY0, E.LAUNCH, E.GUARD_DAYS, E.LAUNCH + E.GUARD_DAYS, E.WINDOW, E.MIN_DAYS, E.PRICE_MAX, E.QTY_MAX,
    E.UNITS_MAX, E.SBP_FLOOR, E.CUT_BP, E.UNDERCUT, E.FAILED_LISTINGS, E.BUDGET, E.MIN_PROFIT, E.MIN_MARGIN_PCT, E.CAP_LIQ_DEFAULT]);
  assert.equal(vectors.texts.caveat, texts.CAVEAT);
  assert.equal(vectors.texts["status.PROTECCION"], texts.GUARD);
});

for (const item of vectors.cases) {
  test(`vector ${item.name}`, () => {
    let actual;
    if (item.kind === "weekday") {
      assert.equal(item.js_only, true);
      actual = {weekday: weekday(buildDays(vectorDays(item.input.days)), item.input.T, {watch: item.input.watch})};
    } else actual = evaluate(item.input);
    const diffs = compare(item.expect, actual, item.name);
    assert.deepEqual(diffs, [], diffs.join("\n"));
  });
}

test("vector day index table, plus null for anything that is not an integer time", () => {
  for (const [t, d] of vectors.dayIndex) assert.equal(dayIndex(t), d, `t = ${t}`);
  assert.equal(dayIndex(1793746800 + 14 * 86400), 2513);
  for (const bad of [null, undefined, "1793746800", 1.5, NaN, Infinity, 1e11, true]) assert.equal(dayIndex(bad), null);
  assert.deepEqual([weekdayOf(2499), weekdayOf(2504), weekdayOf(2510), weekdayOf(-1), weekdayOf(-3)], [2, 0, 6, 1, 6]);
});

test("worked example gives the method's numbers, and maxBuy 7346 with a 15 % cut", () => {
  const worked = caseNamed("ejemplo-trabajado"), r = evaluate(worked.input);
  assert.deepEqual([r.N, r.MAD, r.sBp, r.dumpLine, r.spikeLine, r.Rs], [10000, 100, 300, 8000, 12500, 10000]);
  assert.deepEqual([r.flip.netUnit, r.flip.maxBuy, r.flip.units, r.flip.cost, r.flip.profit, r.flip.breakEven, r.flip.accept],
    [9499, 8216, 82, 500000, 274818, 6473, true]);
  assert.equal(texts.flip(r.flip), "Compra 82× a 82p 16c como máximo; no revendas por debajo de 64p 73c; objetivo 1o; "
    + "ganancia ≈ 27o 48p tras la comisión y un depósito perdido");
  worked.input.cutBp = 1500;
  assert.equal(evaluate(worked.input).flip.maxBuy, 7346);
});

test("module is pure: no imports, clock, randomness, I/O or globals; contract 4 exports exist", async () => {
  const source = fs.readFileSync(new URL("../src/especular.mjs", import.meta.url), "utf8");
  for (const banned of [/^\s*import\b/m, /\bimport\(/, /\bDate\b/, /Math\.random/, /\bfetch\b/, /globalThis/, /\bprocess\b/, /\brequire\(/, /\bconsole\b/])
    assert.doesNotMatch(source, banned);
  const before = Object.keys(globalThis).sort();
  const fresh = await import(`../src/especular.mjs?fresh=${Date.now()}`);
  assert.deepEqual(Object.keys(globalThis).sort(), before);
  for (const name of ["dayIndex", "dayValue", "baseline", "assess", "flip", "deltas", "weekday", "mergeDay", "buildDays", "money"])
    assert.equal(typeof fresh[name], "function", name);
  for (const name of ["pct", "signedPct", "days", "learning", "conf", "status", "flip"]) assert.equal(typeof texts[name], "function", name);
  assert.ok(Object.isFrozen(texts) && Object.isFrozen(E.CATEGORIES));
  assert.deepEqual(E.CATEGORIES, ["metal", "piedra", "gema", "hierba", "piel", "tela", "pocion", "elixir", "frasco", "comida", "venda",
    "encantar", "elemental", "otro"]);
  assert.equal(E.isCategory("hierba"), true); assert.equal(E.isCategory("Hierba"), false);
});

test("integer helpers refuse anything that is not an exact integer", () => {
  assert.deepEqual([idiv(7, 2), idiv(-7, 2), ceilDiv(7, 2), ceilDiv(8, 2), E.median([3, 1, 2]), E.median([1, 2]), E.median([]),
    E.quantile([50, 10, 40, 20, 30], 2, 5)], [3, -4, 4, 4, 2, 1, null, 20]);
  for (const [a, b] of [[2 ** 53, 1], [1.5, 1], [1, 0], [NaN, 1], ["4", 2], [4, null]]) assert.throws(() => idiv(a, b), RangeError);
  assert.equal(E.isInt(1e9, 1, 1e9), true); assert.equal(E.isInt(1e9 + 1, 1, 1e9), false); assert.equal(E.isInt("5", 0, 9), false);
});

test("buildDays keeps only canonical day keys 0..99999; a Map with number keys gives the same days", () => {
  const rec = [{lo: 100, hi: 100, qty: 5, id: "A"}];
  const odd = [{lo: 999, hi: 999, id: "Z"}];
  const days = buildDays({"2506": rec, "02506": odd, "00": odd, "-1": odd, "1e3": odd, "100000": odd, "2506.0": odd, " 2507": odd, "0": rec,
    "99999": rec});
  assert.deepEqual(Object.keys(days), ["0", "2506", "99999"]);
  assert.equal(days[2506].v, 100);
  assert.deepEqual(buildDays(new Map([[2506, rec], [0, rec], [99999, rec], [100000, rec], [-1, rec], [2.5, rec]])), days);
  for (const bad of [null, undefined, 42, "x", [], {"2506": "x"}, {"2506": [null, 5, "x"]}]) assert.deepEqual(buildDays(bad), {});
});

test("buildDays merges each observer first: own beats imported, then the day value over observers", () => {
  const days = buildDays({"2510": [{lo: 900, hi: 1000, qty: 20, id: "A", src: "a"}, {lo: 1200, hi: 1300, qty: 10, id: "A"},
    {lo: 1100, hi: 1150, qty: 0, id: "A"}, {lo: 1000, hi: 1100, id: "B"}, {lo: 0, hi: 5, id: "C"}, {lo: 50, hi: 40, id: "C"},
    {lo: 100, hi: 100, qty: -1, id: "D"}, {lo: 100, hi: 100, id: "E", src: "x"}]});
  // A: own records merge to lo 1100, hi 1300, qty 10; B: 1000..1100; the rest are invalid. Median of {1100,1300,1000,1100}.
  assert.deepEqual(days[2510], {v: 1100, qty: 10, obs: 2, ids: ["A", "B"]});
  assert.deepEqual(buildDays({"1": [{lo: 7, hi: 9}]})[1], {v: 8, qty: null, obs: 1, ids: [""]});
});

// Deterministic generator for property and simulation tests (mulberry32).
function rng(seed) {
  let state = seed >>> 0;
  const next = () => { state = (state + 0x6D2B79F5) >>> 0; let t = state; t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const int = n => Math.floor(next() * n);
  const gauss = () => Math.sqrt(-2 * Math.log(1 - next())) * Math.cos(2 * Math.PI * next());
  return {next, int, gauss};
}

test("mergeDay is idempotent, commutative and associative; own beats imported; other days give null", () => {
  const r = rng(12345);
  const day = () => { const lo = 1 + r.int(5000); return {d: 2500, lo, hi: lo + r.int(3000), last: lo + r.int(3000), qty: r.int(50),
    scans: r.int(4), src: r.int(3) === 0 ? "a" : "o"}; };
  for (let i = 0; i < 500; i++) {
    const a = day(), b = day(), c = day();
    assert.deepEqual(mergeDay(a, a), a);
    assert.deepEqual(mergeDay(a, b), mergeDay(b, a));
    assert.deepEqual(mergeDay(mergeDay(a, b), c), mergeDay(a, mergeDay(b, c)));
    if (a.src !== b.src) assert.deepEqual(mergeDay(a, b), a.src === "o" ? a : b);
  }
  assert.equal(mergeDay({...day(), d: 1}, {...day(), d: 2}), null);
  assert.equal(mergeDay(null, null), null);
  const only = day();
  assert.deepEqual(mergeDay(null, only), only); assert.notEqual(mergeDay(null, only), only);
});

test("dayValue: outlier guard only from 3 observers, inclusive bounds, all-dropped keeps all, qty ignores 0", () => {
  assert.deepEqual(dayValue([{lo: 100, hi: 100, qty: 3, id: "A"}, {lo: 10000, hi: 10000, qty: 0, id: "B"}]),
    {v: 5050, qty: 3, obs: 2, ids: ["A", "B"]});
  assert.deepEqual(dayValue([{lo: 1000, hi: 1000, id: "A"}, {lo: 1000, hi: 1000, id: "B"}, {lo: 9000, hi: 9000, id: "C"}]),
    {v: 1000, qty: null, obs: 2, ids: ["A", "B"]});
  // v = 1000: 500 and 2000 are exactly on the bounds and stay.
  assert.equal(dayValue([{lo: 1000, hi: 1000}, {lo: 500, hi: 500}, {lo: 2000, hi: 2000}, {lo: 1000, hi: 1000}]).obs, 4);
  assert.deepEqual(dayValue([{lo: 5, hi: 5, id: 7}, null, {lo: 0, hi: 1}]), {v: 5, qty: null, obs: 1, ids: ["7"]});
  for (const bad of [null, undefined, [], [null], [{lo: 2, hi: 1}], "x", {lo: 1, hi: 1}]) assert.equal(dayValue(bad), null);
});

test("baseline accepts plain prices, Maps and garbage without throwing", () => {
  const plain = {}, map = new Map();
  for (let d = 2506; d <= 2519; d++) { plain[d] = 10000; map.set(d, 10000); }
  const b = baseline(plain, 2520);
  assert.deepEqual([b.status, b.n, b.k, b.N, b.sBp, b.conf, b.Rs, b.Q, b.trend], ["OK", 14, 1, 10000, 300, "ALTA", 10000, null, "estable"]);
  assert.deepEqual(baseline(map, 2520), b);
  assert.equal(baseline(plain, 2520, {cloud: true}).conf, "MEDIA", "the cloud asks for two members for ALTA");
  for (const T of [null, -1, 100000, 2520.5, "2520"]) {
    const empty = baseline(plain, T);
    assert.deepEqual([empty.status, empty.n, empty.N, empty.prev1, empty.fresh], ["SIN_DATOS", 0, null, null, false]);
  }
  assert.equal(baseline(null, 2520).n, 0);
  // MEDIA on its sigma border: N 14826 and MAD 2500 give sBp exactly 2500; R3 = O7 = N keeps the trend stable.
  const border = {2509: 17326, 2510: 14826, 2511: 12326, 2512: 17326, 2513: 12326, 2514: 17326, 2515: 12326, 2516: 17326, 2517: 14826,
    2518: 14826, 2519: 12326};
  const m = baseline(border, 2520);
  assert.deepEqual([m.n, m.N, m.MAD, m.sBp, m.trend, m.conf], [11, 14826, 2500, 2500, "estable", "MEDIA"]);
  const wider = Object.fromEntries(Object.entries(border).map(([d, v]) => [d, v === 14826 ? v : v > 14826 ? v + 1 : v - 1]));
  assert.deepEqual([baseline(wider, 2520).sBp, baseline(wider, 2520).conf], [2501, "BAJA"]);
  assert.equal(baseline({2519: 0, 2518: 1e9 + 1, 2517: "5", 2516: {v: 1.5}}, 2520).n, 0);
});

test("assess: guard ends on day 2513, T falls back to baseline.T, launch is configurable", () => {
  const days = {};
  for (let d = 2490; d <= 2530; d++) days[d] = 10000;
  assert.equal(assess(baseline(days, 2512), 6000, 2512).verdict, "PROTECCION");
  assert.equal(assess(baseline(days, 2513), 6000, 2513).verdict, "CHOLLO");
  assert.equal(assess(baseline(days, 2512), 6000).guard, true);
  assert.equal(assess(baseline(days, 2512), 6000, 2512, {launch: 2400}).verdict, "CHOLLO");
  assert.equal(assess(baseline(days, 2512), 13000, 2512).verdict, "CARO", "sell-side verdicts still apply during the guard");
  assert.deepEqual([assess(null, 6000, 2520).verdict, assess(null, 6000, 2520).guard, assess(undefined).guard], ["SIN_DATOS", false, false]);
  for (const p of [0, -5, 1.5, "6000", 1e9 + 1, false]) assert.equal(assess(baseline(days, 2520), p, 2520).verdict, "FUERA_DE_RANGO");
});

test("flip walks lots, not units: a 1e6-unit lot is instant and stays under the caps", () => {
  const b = baseline(Object.fromEntries(Array.from({length: 14}, (_, i) => [2506 + i, {v: 10000, qty: 1000000, ids: ["A"]}])), 2520);
  const start = performance.now();
  const r = flip(b, [[6000, 1000000], [5000, 1000000]], {D: 0, budget: 1e11});
  assert.ok(performance.now() - start < 250);
  assert.deepEqual([r.capLiq, r.units, r.cost, r.accept], [250000, 10000, 50000000, true]);
  assert.deepEqual([flip(b, [{price: 6000, qty: 5}], {D: 0}).units, flip(b, [[6000, 0], [7000, 3]], {D: 0}).units], [5, 3]);
  assert.equal(flip(b, null, {D: 0}).reason, "SIN_UNIDADES", "no book and no price");
  for (const q5 of [0, undefined]) {
    const estimated = flip(b, null, {D: 0, p: 6000, q5});
    assert.deepEqual([estimated.units, estimated.bookEstimated], [1, true], "an unknown q5 means a single unit");
  }
  assert.equal(flip(b, null, {D: 0, p: 6000, q5: 7}).units, 7);
  assert.equal(flip(null, [[6000, 1]]).reason, "SIN_BASE");
  for (const opts of [{cutBp: 10000}, {u: 0}, {D: -1}, {F: 101}, {budget: 1e11 + 1}, {Q: 1.5}, {p: 0}, {q5: -1}, {vendor: "5"}])
    assert.equal(flip(b, [[6000, 1]], opts).reason, "FUERA_DE_RANGO", JSON.stringify(opts));
  for (const book of [5, "x", false, [[0, 1]], [[6000, -1]], [[6000]], [[6000, 1], "x"], [{price: 6000}]])
    assert.equal(flip(b, book, {D: 0}).reason, "FUERA_DE_RANGO", JSON.stringify(book));
  // Like Lua's ipairs, a missing entry ends the book.
  assert.deepEqual([flip(b, [[6000, 5], null, "x"], {D: 0}).units, flip(b, [null, [6000, 5]], {D: 0}).reason], [5, "SIN_UNIDADES"]);
});

test("deltas need today and yesterday for Δ1d, and 4 values a side for Δ7d", () => {
  const days = {};
  for (let d = 2507; d <= 2513; d++) days[d] = 10000;
  for (let d = 2514; d <= 2520; d++) days[d] = 11000;
  assert.deepEqual(deltas(days, 2520), {d1: 0, d7: 1000});
  days[2519] = 10000;
  assert.deepEqual(deltas(days, 2520), {d1: 1000, d7: 1000});
  assert.deepEqual(deltas(days, 2521), {d1: null, d7: 1000});
  assert.deepEqual(deltas({2520: 1}, 2520), {d1: null, d7: null});
  const sparse = {2507: 10000, 2508: 10000, 2509: 10000, 2510: 10000, 2514: 11000, 2516: 11000, 2518: 11000};
  assert.equal(deltas(sparse, 2520).d7, null, "3 recent values");
  assert.equal(deltas({...sparse, 2520: 11000}, 2520).d7, 1000, "4 recent values");
  assert.deepEqual(deltas(days, "2520"), {d1: null, d7: null});
});

test("texts: Spanish plurals, signs, decimal comma and flip sentences", () => {
  assert.deepEqual([texts.days(1), texts.days(2), texts.learning(0), texts.learning(), texts.pct(300), texts.pct(1234), texts.pct(-140),
    texts.pct(4), texts.pct(-14), texts.signedPct(-1420), texts.signedPct(4), texts.signedPct(50)],
  ["1 día", "2 días", "Aprendiendo precios: 0 de 7 días", "Aprendiendo precios: 0 de 7 días", "3", "12,3", "1,4", "0", "0,1", "-14,2", "0", "+0,5"]);
  const conf = {n: 14, conf: "ALTA", sBp: 300, k: 1};
  assert.equal(texts.conf(conf), "Fiable · 14 días · variación ±3 %");
  assert.equal(texts.conf({...conf, k: 2}), "Fiable · 14 días · variación ±3 % · 2 miembros");
  assert.equal(texts.conf({...conf, conf: "MEDIA", k: 5}), "Orientativo · 14 días · variación ±3 %");
  assert.equal(texts.conf({...conf, conf: "BAJA"}), "Poco fiable: pocos datos o precio muy variable");
  assert.equal(texts.conf(null), "Aprendiendo precios: 0 de 7 días");
  assert.equal(texts.status(null, null), "Aprendiendo precios: 0 de 7 días");
  assert.equal(texts.status({verdict: "INESTABLE"}, {trend: "bajando", trendBp: -1420}),
    "Mercado bajando (-14,2 % en una semana): vende pronto, no compres para revender");
  const ok = {accept: true, units: 1, maxBuy: 8216, breakEven: 6473, Rs: 10000, profit: 274818, F: 2, depositEstimated: true, bookEstimated: true};
  assert.equal(texts.flip(ok), "Compra 1× a 82p 16c como máximo; no revendas por debajo de 64p 73c; objetivo 1o; ganancia ≈ 27o 48p "
    + "tras la comisión y 2 depósitos perdidos (depósito estimado) · estimado: confirma en la subasta");
  assert.equal(texts.flip({...ok, F: 0, bookEstimated: false}), "Compra 1× a 82p 16c como máximo; no revendas por debajo de 64p 73c; "
    + "objetivo 1o; ganancia ≈ 27o 48p tras la comisión");
  assert.equal(texts.flip({...ok, F: 1, depositEstimated: false, bookEstimated: false}, c => `${c}c`),
    "Compra 1× a 8216c como máximo; no revendas por debajo de 6473c; objetivo 10000c; ganancia ≈ 274818c tras la comisión y un depósito perdido");
  assert.deepEqual(["FUERA_DE_RANGO", "SIN_MARGEN", "SIN_UNIDADES", "POCA_GANANCIA", "MARGEN_BAJO", "SIN_BASE"].map(reason =>
    texts.flip({accept: false, reason, maxBuy: 8216, profit: 9999})), ["Datos fuera de rango: no se calcula la compra",
    "No compensa: la comisión y el depósito se comen el margen", "No compensa: no hay nada a la venta por debajo de 82p 16c",
    "No compensa: ganarías solo 99p 99c (menos de 1 oro)", "No compensa: ganarías 99p 99c, menos del 15 % de lo invertido",
    "Sin precio normal: no se calcula la compra"]);
  assert.equal(texts.flip(null), "Sin precio normal: no se calcula la compra");
  assert.equal(texts.flip(ok, null), texts.flip(ok), "a missing formatter means money()");
  assert.deepEqual([money(0), money(7), money(100), money(4506), money(10000), money(10099), money(274818), money(-4506), money(null), money(12.5)],
    ["0c", "7c", "1p", "45p 6c", "1o", "1o", "27o 48p", "-45p 6c", "0c", "13c"]);
});

// ---- Weekday patterns on synthetic data (cloud only)
const MONDAY = 2504; // 2026-11-09
function series(weeks, dip = 1000) {          // one observer, every day, exact prices: Tuesdays dip by dip bp
  const days = {};
  for (let d = MONDAY; d < MONDAY + 7 + 7 * weeks; d++) days[d] = weekdayOf(d) === 1 ? 10000 - dip : 10000;
  return days;
}
// Members scan on random days with their own noise around a drifting market; buildDays merges them.
function market(seed, {members = 3, weeks = 10, dip = 1000, sigma = 0.06, scanChance = 0.5} = {}) {
  const r = rng(seed), byDay = {}, last = MONDAY + 7 + 7 * weeks;
  let drift = 0;
  for (let d = MONDAY; d < last; d++) {
    drift = 0.9 * drift + 0.02 * r.gauss();
    const level = 10000 * Math.exp(drift) * (weekdayOf(d) === 1 ? (10000 - dip) / 10000 : 1);
    for (let m = 0; m < members; m++) {
      if (r.next() >= scanChance) continue;
      const lo = Math.max(1, Math.round(level * Math.exp(sigma * r.gauss())));
      (byDay[d] ??= []).push({lo, hi: lo + r.int(Math.max(1, Math.floor(lo / 50))), qty: 50 + r.int(200), id: `m${m}`});
    }
  }
  return {days: buildDays(byDay), T: last};
}

test("weekday: an exact 10 % Tuesday dip shows from the 4th week after the gate, not before", () => {
  const hidden = weekday(series(3), MONDAY + 7 + 21);
  assert.deepEqual([hidden.gate, hidden.weeks, hidden.counts, hidden.missingWeeks, hidden.shown], [MONDAY + 7, 3, [3, 3, 3, 3, 3, 3, 3], 1, false]);
  assert.deepEqual(hidden.e, [0, -1000, 0, 0, 0, 0, 0]);
  const shown = weekday(series(4), MONDAY + 7 + 28);
  assert.deepEqual([shown.weeks, shown.missingWeeks, shown.cheapest, shown.dearest, shown.spread, shown.cheapHits, shown.shown],
    [4, 0, 1, 0, 1000, 4, true]);
  assert.equal(weekday(series(4), MONDAY + 7 + 28, {watch: false}).shown, false, "only watchlist items");
  assert.equal(weekday(series(4, 799), MONDAY + 7 + 28).shown, false, "spread under 800 bp");
  assert.equal(weekday(series(4, 800), MONDAY + 7 + 28).shown, true, "spread of exactly 800 bp");
});

test("weekday: hidden while any weekday has fewer than 4 weeks, even with a strong pattern", () => {
  for (let seed = 1; seed <= 40; seed++) {
    const {days, T} = market(seed, {weeks: 3, dip: 2000});
    const w = weekday(days, T, {watch: true});
    assert.equal(w.shown, false, `seed ${seed}`);
    assert.ok(Math.min(...w.counts) < 4 && w.missingWeeks >= 1, `seed ${seed}`);
  }
});

// 3 members scanning half of the days, 6 % noise each, a drifting market (the design simulation's setup).
// Measured over 400 seeds: detected in 94 %, a false pattern on pure noise in 3 % (0 % at 3 % noise).
test("weekday: 3 members over 10 weeks detect a planted 10 % Tuesday dip", () => {
  let detected = 0;
  for (let seed = 1; seed <= 40; seed++) {
    const {days, T} = market(seed);
    const w = weekday(days, T, {watch: true});
    if (w.shown) { detected++; assert.equal(w.cheapest, 1, `seed ${seed}: el martes`); }
  }
  assert.ok(detected >= 34, `detectado en ${detected} de 40`);
  let single = 0;                                              // one member alone rarely has 5 days in a week
  for (let seed = 1; seed <= 40; seed++) { const {days, T} = market(seed, {members: 1}); if (weekday(days, T).shown) single++; }
  assert.ok(single <= 2, `un solo miembro: ${single} de 40`);
});

test("weekday: no false pattern on noise", () => {
  const shownIn = (options, from) => {
    let shown = 0;
    for (let seed = 1; seed <= 40; seed++) { const {days, T} = market(from + seed, {dip: 0, ...options}); if (weekday(days, T).shown) shown++; }
    return shown;
  };
  assert.equal(shownIn({sigma: 0.03}, 1000), 0, "3 % noise");
  assert.equal(shownIn({members: 1, sigma: 0.02, scanChance: 1}, 2000), 0, "one member every day, 2 % noise");
  assert.ok(shownIn({}, 1000) <= 3, "6 % noise: rare");
});

test("weekday: today and days before the gate do not count; no data gives the empty answer", () => {
  const days = series(4), T = MONDAY + 7 + 28;
  const base = weekday(days, T);
  const saturday = T + 5, upToFriday = {...days};                      // today mid-week: its week already counts
  for (let d = T; d < saturday; d++) upToFriday[d] = weekdayOf(d) === 1 ? 9000 : 10000;
  assert.deepEqual(weekday({...upToFriday, [saturday]: 1}, saturday), weekday(upToFriday, saturday), "today is ignored");
  assert.equal(weekday(upToFriday, saturday).weeks, 5);
  const short = {...days};                                               // a week with 4 values is left out
  for (const d of [T - 7, T - 6, T - 5]) delete short[d];
  assert.deepEqual([weekday(short, T).weeks, weekday(short, T).shown, weekday(short, T).missingWeeks], [3, false, 1]);
  const threeOfFour = {...days, [MONDAY + 15]: 10000}, twoOfFour = {...threeOfFour, [MONDAY + 22]: 10000};  // Tuesdays without the dip
  assert.deepEqual([weekday(threeOfFour, T).cheapHits, weekday(threeOfFour, T).shown], [3, true], "75 % of the weeks is enough");
  assert.deepEqual([weekday(twoOfFour, T).cheapest, weekday(twoOfFour, T).shown], [1, false]);
  const early = {...days};
  for (let d = MONDAY - 20; d < MONDAY; d++) early[d] = 30000 - 1000 * (d - MONDAY + 20);  // falling market: no gate yet
  assert.deepEqual(weekday(early, T).e, base.e);
  assert.ok(weekday(early, T).gate > MONDAY - 20 + 7);
  assert.deepEqual(weekday(new Map(Object.entries(days).map(([d, v]) => [Number(d), v])), T), base);
  const empty = {shown: false, gate: null, weeks: 0, counts: [0, 0, 0, 0, 0, 0, 0], e: [null, null, null, null, null, null, null],
    cheapest: null, dearest: null, spread: null, cheapHits: 0, missingWeeks: 4};
  for (const [d, t] of [[{}, T], [null, T], [days, null], [days, MONDAY + 3]]) assert.deepEqual(weekday(d, t), empty);
});

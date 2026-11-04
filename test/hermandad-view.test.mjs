/** The guild panel (public/hermandad.*): its pure builders (money as g/s/c, charts, CSV, filters, banners, the flip
 * calculator), the static page contract (CSP-safe, ids, 12 px minimum, theme tokens), how the worker serves it, and
 * the builders against the real GuildMarket answers (worker -> Durable Object -> node:sqlite). */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {execFileSync} from "node:child_process";
import {DatabaseSync} from "node:sqlite";
import * as E from "../src/especular.mjs";
import worker, {Portfolio} from "../src/worker.mjs";
import {GuildMarket, GuildStore, goldCell, pctCell, textCell, WATCHLIST} from "../src/guild.mjs";
import * as H from "../public/hermandad.js";

H.setEspecular(E);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = name => fs.readFileSync(path.join(root, name), "utf8");
const BASE = "https://especulador.test";
const PASSWORD = "test-only-owner-password-47-strong";
const MARKET = "Grito de Guerra-Alliance";
// Response.text() drops a leading BOM; the CSV exports must keep it.
const bytesText = async response => new TextDecoder("utf-8", {ignoreBOM: true}).decode(await response.arrayBuffer());
const at = (d, hour = 12, minute = 0) => E.DAY0 + d * 86400 + hour * 3600 + minute * 60;
function rng(seed) {
  return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let x = Math.imul(seed ^ seed >>> 15, 1 | seed); x = x + Math.imul(x ^ x >>> 7, 61 | x) ^ x; return ((x ^ x >>> 14) >>> 0) / 4294967296; };
}
const svgText = node => H.toSVGString(node);
const fontSizes = markup => [...markup.matchAll(/font-size="([\d.]+)"/g)].map(m => Number(m[1]));

// ---- money --------------------------------------------------------------------------------------------------
test("formatGSC writes integer copper as WoW gold, silver and copper", () => {
  const cases = [[0, "0c"], [7, "7c"], [100, "1s"], [105, "1s 5c"], [8216, "82s 16c"], [10000, "1g"], [10001, "1g 1c"],
    [123456, "12g 34s 56c"], [99990000, "9999g"], [100000000, "10.000g"], [1234567890, "123.456g 78s 90c"], [-56, "−56c"], [-123456, "−12g 34s 56c"]];
  for (const [copper, text] of cases) assert.equal(H.formatGSC(copper), text, String(copper));
  for (const bad of [null, undefined, NaN, 1.5, "12", Infinity, 2 ** 60]) assert.equal(H.formatGSC(bad), "—");
  assert.equal(H.formatGSC(null, ""), "");
  assert.deepEqual(H.gscParts(8216), {negative: false, parts: [{value: "82", unit: "s"}, {value: "16", unit: "c"}]});
  assert.equal(H.gscParts(0.5), null);
});

test("parseGSC reads what players type and round-trips every formatted amount", () => {
  const cases = [["12g 34s 56c", 123456], ["12G 34S 56C", 123456], ["1o 20p", 12000], ["12 g 3 s", 120300], ["75s", 7500], ["3c", 3],
    ["150s", 15000], ["1,25", 12500], ["1.5", 15000], ["100", 1000000], ["0", 0], ["0,0001", 1], ["  2g  ", 20000],
    // Spanish thousands, as the panel itself writes gold: a point before exactly three digits groups thousands.
    ["1.000", 10000000], ["1.000g", 10000000], ["10.000g", 100000000], ["12.345g 67s 89c", 123456789], ["2.500g 30s", 25003000],
    ["1.000,5", 10005000], ["1.000.000", 10000000000], ["0.500", 5000], ["1.2500", 12500], ["1.25", 12500]];
  for (const [text, copper] of cases) assert.equal(H.parseGSC(text), copper, text);
  for (const bad of ["", "   ", null, undefined, "12x", "1g 2g", "g", "-5", "1,23456", "1g 20", "1.234.5", "12.34.567", "1,000.5", "5 %", "1g20s"]) {
    assert.equal(H.parseGSC(bad), null, String(bad));
  }
  const random = rng(42);
  for (const copper of [0, 1, 99, 9999, 10000, 99999999, 100000000, 999999999, 1000000000, 123456789012]) {
    assert.equal(H.parseGSC(H.formatGSC(copper)), copper, H.formatGSC(copper));
  }
  for (let i = 0; i < 5000; i++) {
    const copper = Math.floor(random() * 1e9);
    assert.equal(H.parseGSC(H.formatGSC(copper)), copper, H.formatGSC(copper));
  }
});

test("the calculator reads a Spanish budget of 1.000 as a thousand gold, like 1000g", () => {
  const detail = {item: {vendor: 0}, baseline: {Rs: 20000, Q: 400}, budget: 0};
  const inputs = budget => ({units: "40", buy: "1g", resale: "2g", cut: "5", deposit: "", budget});
  const reference = H.calculatorFlip(detail, inputs("1000g"));
  assert.equal(reference.result.capBudget, 2500000, "25 % of 1000 gold");
  for (const budget of ["1.000", "1.000g", "1000"]) assert.deepEqual(H.calculatorFlip(detail, inputs(budget)), reference, budget);
  assert.deepEqual(H.calculatorFlip(detail, inputs(H.formatGSC(100000000))).opts.budget, 100000000, "the panel's own 10.000g");
  // Units take the same thousands point as the limit in their own message ("entre 1 y 10.000").
  const many = units => H.calculatorFlip(detail, {...inputs("1000g"), units});
  assert.deepEqual(many("1.000"), many("1000"));
  assert.deepEqual(many("10.000"), many("10000"));
  for (const bad of ["10.001", "1.00", "0.500", "100.000", "1,000"]) assert.match(many(bad).error ?? "", /^Unidades/, bad);
});

test("percentages, units, days and times use the shared rounding and Spanish forms", () => {
  for (const bp of [-12345, -1234, -55, -5, -4, 0, 4, 5, 55, 300, 1234, 99999]) assert.equal(H.formatPct(bp), E.texts.signedPct(bp) + " %");
  assert.equal(H.formatPct(-1234), "-12,3 %");
  assert.equal(H.formatPct(null), "—");
  assert.equal(H.formatUnits(1234), "1234 ud.");
  assert.equal(H.formatUnits(12345), "12.345 ud.");
  assert.equal(H.formatUnits(null), "—");
  assert.equal(H.dayLabel(E.LAUNCH), "mié 4 nov");
  assert.equal(H.dayLabel(E.LAUNCH + E.GUARD_DAYS), "mié 18 nov");
  assert.equal(H.dayLabel(2556, {weekday: false, year: true}), "31 dic 2026");
  assert.equal(H.dayLabel(2557), "vie 1 ene");
  for (let d = 2490; d < 2600; d++) assert.equal(H.dayLabel(d).split(" ")[0], ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"][E.weekdayOf(d)]);
  const now = Date.parse("2026-12-01T19:30:00Z");
  const ago = s => new Date(now - s * 1000).toISOString();
  assert.deepEqual([0, 59, 60, 3599, 3600, 7200, 86399, 86400, 172800].map(s => H.relativeTime(ago(s), now)),
    ["hace un momento", "hace un momento", "hace 1 min", "hace 59 min", "hace 1 h", "hace 2 h", "hace 23 h", "hace 1 día", "hace 2 días"]);
  assert.equal(H.relativeTime(new Date(now + 60000).toISOString(), now), "hace un momento");
  assert.equal(H.relativeTime(null, now), null);
  assert.equal(H.formatWhen("2026-12-01T18:05:00Z", now, "Europe/Madrid"), "hoy 19:05");
  assert.equal(H.formatWhen("2026-11-30T21:40:00Z", now, "Europe/Madrid"), "ayer 22:40");
  assert.equal(H.formatWhen("2026-11-03T20:40:00Z", now, "Europe/Madrid"), "3 nov 21:40");
  assert.equal(H.formatWhen(null, now), "—");
});

test("the freshness strip reads like '4 miembros · último envío hace 2 h · día 12 desde el lanzamiento'", () => {
  const now = Date.parse("2026-11-15T20:00:00Z");
  const two = new Date(now - 2 * 3600 * 1000).toISOString();
  assert.equal(H.freshnessLine({contributors: 4, lastUploadAt: two}, 12, now), "4 miembros · último envío hace 2 h · día 12 desde el lanzamiento");
  assert.equal(H.freshnessLine({contributors: 1, lastUploadAt: two}, 1, now), "1 miembro · último envío hace 2 h · día 1 desde el lanzamiento");
  assert.equal(H.freshnessLine({contributors: 0, lastUploadAt: null}, 0, now), "ningún envío en 14 días · el lanzamiento es mañana");
  assert.equal(H.freshnessLine(null, -2, now), "ningún envío en 14 días · faltan 3 días para el lanzamiento");
});

// ---- charts -------------------------------------------------------------------------------------------------
test("sparklinePath: empty, one point, gaps, flat and 60 points", () => {
  assert.deepEqual(H.sparklinePath([]), {d: "", points: [], last: null, min: null, max: null});
  assert.equal(H.sparklinePath([null, null]).d, "");
  assert.equal(H.sparklinePath(undefined).d, "");
  const one = H.sparklinePath([500], {width: 96, height: 24});
  assert.equal(one.d, "M48 12l0 0", "a lone value is a dot in the middle");
  const flat = H.sparklinePath([7, 7, 7], {width: 96, height: 24});
  assert.ok(flat.points.every(p => p.y === 12));
  const gaps = H.sparklinePath([1, 2, null, 4, 5, null, null, 8]);
  assert.equal((gaps.d.match(/M/g) || []).length, 3, "each run of values starts a new segment");
  assert.ok(gaps.d.endsWith("l0 0"), "the isolated last value is drawn as a dot");
  const random = rng(7), values = Array.from({length: 60}, () => 1000 + Math.floor(random() * 9000));
  const geo = H.sparklinePath(values, {width: 300, height: 40, pad: 3});
  assert.equal(geo.points.length, 60);
  assert.equal(geo.points[0].x, 3);
  assert.equal(geo.points[59].x, 297);
  for (let i = 1; i < 60; i++) assert.ok(geo.points[i].x > geo.points[i - 1].x);
  assert.ok(geo.points.every(p => p.y >= 3 && p.y <= 37));
  const lowest = geo.points.find(p => p.v === geo.min), highest = geo.points.find(p => p.v === geo.max);
  assert.equal(lowest.y, 37);
  assert.equal(highest.y, 3);
  assert.doesNotMatch(geo.d, /NaN|Infinity/);
  const markup = svgText(H.sparklineSVG([100, 200, null, 300]));
  assert.match(markup, /^<svg class="spark"/);
  assert.match(markup, /aria-label="28 días: entre 1s y 3s"/);
  assert.match(svgText(H.sparklineSVG([null])), /sin datos/);
});

function days60(T, {gapAt = null, dumpAt = null} = {}) {
  const out = [], random = rng(3);
  for (let d = T - 59; d <= T; d++) {
    if (d === gapAt) continue;
    const v = 10000 + Math.floor((random() - 0.5) * 600);
    const lo = d === dumpAt ? 6000 : v - 150, hi = v + 250;
    out.push({d, v, lo, hi, qty: 300, obs: 3, members: ["Ana", "Bruno", "Carla"]});
  }
  return out;
}

test("bandChartSVG draws the low-high band, the day value, normal and chollo lines and dump dots", () => {
  assert.equal(H.bandChartSVG({days: [], from: 1, to: 60}), null);
  const T = 2530, days = days60(T, {gapAt: T - 20, dumpAt: T - 5});
  const chart = H.bandChartSVG({days, from: T - 59, to: T, N: 10000, dumpLine: 8000, markers: [T - 5, T - 20], price: 6100, width: 640, height: 260});
  const markup = svgText(chart.node);
  assert.doesNotMatch(markup, /NaN|Infinity|undefined/);
  assert.equal((markup.match(/<path d="M[^"]*Z" fill="#c98500" fill-opacity="0.18">/g) || []).length, 2, "the gap splits the band in two");
  const line = /class="value-line" d="([^"]+)"/.exec(markup)[1];
  assert.equal((line.match(/M/g) || []).length, 2, "and the value line too");
  assert.match(markup, /class="normal-line"/);
  assert.match(markup, /class="dump-line"[^>]*stroke-dasharray="6 4"/);
  assert.equal((markup.match(/<circle cx="[\d.]+" cy="[\d.]+" r="4.5"/g) || []).length, 1, "a marker only on a day with data");
  assert.match(markup, /class="today-price"/);
  assert.ok(fontSizes(markup).length > 0 && fontSizes(markup).every(size => size >= 12));
  for (const [, label] of markup.matchAll(/<text[^>]*>([^<]+)<\/text>/g)) assert.match(label, /^(?:−?(?:[\d.]+g)?(?: ?\d+s)?(?: ?\d+c)?|\d{1,2} [a-z]{3})$/, label);
  const {x0, x1, y0, y1, x, y} = chart.layout;
  assert.equal(x(T - 59), x0);
  assert.equal(x(T), x1);
  assert.ok(y(6000) > y(10000) && y(10000) > y0 && y(6000) < y1);
  assert.match(markup, /aria-label="Precio diario de 7 oct a 5 dic: 59 días con datos, normal 1g\."/);
  const narrow = svgText(H.bandChartSVG({days, from: T - 59, to: T, width: 340, height: 220}).node);
  assert.ok((narrow.match(/class="x-labels"/g) || []).length === 1);
  assert.ok([...narrow.matchAll(/<text x="[\d.]+" y="214">/g)].length <= 5, "fewer date labels on a phone");
  const single = H.bandChartSVG({days: [{d: T, v: 100, lo: 90, hi: 110}], from: T - 59, to: T});
  assert.match(svgText(single.node), /<rect x="[\d.]+" y="[\d.]+" width="4"/);
  assert.equal(H.niceTicks(0, 10000, 4).join(), "0,2000,4000,6000,8000,10000");
  assert.equal(H.niceTicks(1000, 1900, 4).join(), "1000,1200,1400,1600,1800");
  assert.deepEqual(H.niceTicks(NaN, 1), []);
});

test("dumpDays marks the days at or below the chollo line of their own 14-day baseline", () => {
  const T = 2540, series = {};
  for (let d = T - 40; d <= T; d++) series[d] = {v: 10000, lo: 9900, hi: 10100};
  series[T - 3] = {v: 9800, lo: 7000, hi: 10100};
  series[T - 1] = {v: 9900, lo: 8400, hi: 10100};
  const marks = H.dumpDays(series, T - 30, T);
  assert.deepEqual(marks, [T - 3]);
  const line = E.assess(E.baseline(series, T - 1, {cloud: true}), 1, T - 1).dumpLine;
  assert.deepEqual(H.dumpDays({...series, [T - 1]: {v: 9900, lo: line, hi: 10100}}, T - 1, T - 1), [T - 1], "exactly on the line counts");
  assert.deepEqual(H.dumpDays({...series, [T - 1]: {v: 9900, lo: line + 1, hi: 10100}}, T - 1, T - 1), []);
  const a = E.assess(E.baseline(series, T - 3, {cloud: true}), 7000, T - 3);
  assert.ok(7000 <= a.dumpLine && 8400 > E.assess(E.baseline(series, T - 1, {cloud: true}), 8400, T - 1).dumpLine);
  assert.deepEqual(H.dumpDays({}, 1, 10), []);
});

test("weekdayBars stays hidden until the pattern qualifies and then draws seven bars", () => {
  const hidden = H.weekdayBars({shown: false, e: [0, 0, 0, 0, 0, 0, 0], missingWeeks: 2, text: "Faltan 2 semanas de datos para buscar patrones por día de la semana."});
  assert.deepEqual([hidden.shown, hidden.node, hidden.bars], [false, null, []]);
  assert.match(hidden.text, /^Faltan 2 semanas/);
  assert.equal(H.weekdayBars(null).shown, false);
  const w = {shown: true, e: [-70, -1470, 10, 0, 60, -60, 80], counts: [8, 8, 8, 7, 8, 8, 8], cheapest: 1, dearest: 6, text: "Patrón probable: el martes…"};
  const shown = H.weekdayBars(w, {width: 420, height: 160});
  assert.equal(shown.shown, true);
  assert.equal(shown.bars.length, 7);
  assert.deepEqual(shown.bars.map(b => b.short), ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"]);
  const markup = svgText(shown.node);
  assert.match(markup, /width="420" height="160"/, "drawn at its real size, so text stays 12 px");
  assert.ok(fontSizes(markup).every(size => size >= 12));
  assert.equal((markup.match(/<path /g) || []).length, 6, "a zero bar is a flat mark, not a path");
  assert.equal((markup.match(/fill="#3987e5"/g) || []).length, 3, "cheaper days below the line in blue");
  assert.equal((markup.match(/fill="#e66767"/g) || []).length, 3);
  const labels = [...markup.matchAll(/<text x="[\d.]+" y="([\d.]+)">([^<]+)<\/text>/g)].map(m => [Number(m[1]), m[2]]);
  const values = labels.filter(([, t]) => /%$/.test(t));
  assert.deepEqual(values.map(([, t]) => t), ["-14,7 %", "+0,8 %"], "only the cheapest and dearest are labelled");
  for (const [yy] of values) assert.ok(yy < 160 - 20, "value labels never reach the weekday names");
  assert.match(markup, /<path d="[^"]+" fill="#3987e5"><title>martes: -14,7 % frente a su semana · 8 semanas<\/title>/, "the cheap day is blue");
  assert.match(markup, /<path d="[^"]+" fill="#e66767"><title>domingo: \+0,8 %/, "a dearer day is red");
});

// ---- CSV ----------------------------------------------------------------------------------------------------
test("csvRows writes Spanish Excel CSV with the same cells as the server", () => {
  const text = H.csvRows([{label: "Objeto", kind: "text", value: r => r.name}, {label: "Valor (oro)", kind: "gold", value: r => r.v},
    {label: "Δ7d (%)", kind: "pct", value: r => r.d}, {label: "ID", kind: "int", value: r => r.id}],
  [{name: "Paño rúnico", v: 12345, d: -1234, id: 14047}, {name: '=HYPERLINK("x");b', v: null, d: null, id: null}, {name: "-5", v: 10000, d: 50, id: 1}]);
  assert.ok(text.startsWith("\uFEFFObjeto;Valor (oro);Δ7d (%);ID\r\n"));
  assert.ok(text.endsWith("\r\n"));
  assert.deepEqual(text.slice(1).split("\r\n"), ["Objeto;Valor (oro);Δ7d (%);ID", "Paño rúnico;1,2345;-12,34;14047", `"'=HYPERLINK(""x"");b";;;`, "'-5;1;0,5;1", ""]);
  const random = rng(11);
  for (let i = 0; i < 3000; i++) {
    const n = Math.floor((random() - 0.5) * 2e9);
    assert.equal(H.csvGold(n), goldCell(n));
    assert.equal(H.csvPct(n % 100000), pctCell(n % 100000));
  }
  for (const value of [null, undefined, "", "a;b", 'a"b', "a\nb", "=1+1", "+1", "-1", "@SUM", "\tx", "\rx", "normal", 12, "Ñandú"]) {
    assert.equal(H.csvText(value), textCell(value), String(value));
  }
  assert.equal(H.csvGold(1.5), "");
});

// ---- table filters, banners and empty states --------------------------------------------------------------------
const ITEMS = [
  {id: 3, name: "Paño rúnico", cat: "tela", N: 12000, d7: -500, price: {lo: 9000}, conf: "ALTA", verdict: "CHOLLO", members: 3, n: 14},
  {id: 1, name: "Mineral de cobre", cat: "metal", N: 2500, d7: null, price: null, conf: "MEDIA", verdict: "SIN_PRECIO", members: 2, n: 12},
  {id: 2, name: "Ópalo grande", cat: "gema", N: null, d7: 300, price: {lo: 70000}, conf: null, verdict: "SIN_DATOS", members: 1, n: 3},
  {id: 4, name: "Frasco de los titanes", cat: "frasco", N: 900000, d7: 900, price: {lo: 1300000}, conf: "BAJA", verdict: "CARO", members: 3, n: 9}];
test("filterItems, sortItems and groupByCategory", () => {
  assert.deepEqual(H.filterItems(ITEMS, {q: "paño"}).map(e => e.id), [3]);
  assert.deepEqual(H.filterItems(ITEMS, {q: "ÓPALO"}).map(e => e.id), [2]);
  assert.deepEqual(H.filterItems(ITEMS, {q: "4"}).map(e => e.id), [4], "an exact ID matches");
  assert.deepEqual(H.filterItems(ITEMS, {cat: "metal"}).map(e => e.id), [1]);
  assert.deepEqual(H.filterItems(ITEMS, {show: "chollos"}).map(e => e.id), [3]);
  assert.deepEqual(H.filterItems(ITEMS, {show: "caros"}).map(e => e.id), [4]);
  assert.deepEqual(H.filterItems(ITEMS, {show: "precio"}).map(e => e.id), [3, 2, 4]);
  assert.deepEqual(H.filterItems(ITEMS, {conf: "media"}).map(e => e.id), [3, 1]);
  assert.deepEqual(H.filterItems(ITEMS, {conf: "alta"}).map(e => e.id), [3]);
  assert.deepEqual(H.sortItems(ITEMS, {key: "d7", dir: "asc"}).map(e => e.id), [3, 2, 4, 1], "unknown values go last");
  assert.deepEqual(H.sortItems(ITEMS, {key: "d7", dir: "desc"}).map(e => e.id), [4, 2, 3, 1], "in both directions");
  assert.deepEqual(H.sortItems(ITEMS, {key: "hoy", dir: "desc"}).map(e => e.id), [4, 2, 3, 1]);
  assert.deepEqual(H.sortItems(ITEMS, {key: "name"}).map(e => e.id), [4, 1, 2, 3], "Spanish collation puts Ó with O");
  assert.deepEqual(H.sortItems(ITEMS, {key: "conf", dir: "desc"}).map(e => e.id), [3, 1, 4, 2]);
  assert.deepEqual(H.sortItems(ITEMS, {key: "verdict"}).map(e => e.id), [3, 4, 1, 2]);
  assert.deepEqual(H.sortItems(ITEMS, {key: ""}).map(e => e.id), [3, 1, 2, 4], "no key keeps the server order");
  assert.deepEqual(H.sortItems(ITEMS, {key: "members", dir: "desc"}).map(e => e.id), [3, 4, 1, 2], "ties keep the ID order in both directions");
  assert.deepEqual(H.sortItems(ITEMS, {key: "members", dir: "asc"}).map(e => e.id), [2, 1, 3, 4]);
  assert.deepEqual(H.sortItems([...ITEMS].reverse(), {key: "members", dir: "desc"}).map(e => e.id), [3, 4, 1, 2], "whatever the input order");
  assert.deepEqual(H.groupByCategory(ITEMS).map(g => g.cat), ["metal", "gema", "tela", "frasco"]);
  assert.deepEqual(H.CATEGORY_ORDER, E.CATEGORIES);
});

const item = (over = {}) => ({id: 1, n: 14, N: 10000, status: "OK", trend: "estable", trendBp: 0, price: {lo: 9000}, ...over});
test("marketBanners and cholloEmptyText explain the launch, learning and a falling market", () => {
  assert.deepEqual(H.marketBanners({phase: "antes", banner: "WoW Forever abre el 4 de noviembre: todavía no hay precios de la hermandad.", items: []}).map(b => b.kind), ["before"]);
  const launch = H.marketBanners({phase: "proteccion", banner: E.texts.GUARD, items: [item({n: 6, N: null, status: "SIN_DATOS", trend: null}), item({n: 4, N: null, status: "SIN_DATOS", trend: null})]});
  assert.deepEqual(launch.map(b => [b.kind, b.title, b.text]), [
    ["guard", "Protección de lanzamiento", "Sin compras especulativas hasta el 18-nov."],
    ["learning", "Aprendiendo precios", "6 de 7 días con datos. Hasta tener 7 no hay precio normal, chollos ni balances."]]);
  const falling = [item({trend: "bajando", trendBp: -1500}), item({trend: "bajando", trendBp: -1200}), item({trend: "bajando", trendBp: -1100}),
    ...Array.from({length: 6}, () => item())];
  const banners = H.marketBanners({phase: "normal", banner: null, items: falling});
  assert.deepEqual(banners.map(b => b.kind), ["falling"]);
  assert.equal(banners[0].text, "3 de 9 objetos con precio normal han caído más de un 10 % en una semana (mediana -12 %). Vende pronto lo que farmees; no compres para revender.");
  assert.deepEqual(H.marketBanners({phase: "normal", items: [...falling, item()]}), [], "under a third does not call the whole market falling");
  assert.deepEqual(H.marketBanners({phase: "normal", items: falling.slice(0, 2)}), [], "nor do two items");
  assert.deepEqual(H.marketBanners({phase: "normal", items: [item({trend: "subiendo"}), item({trend: "subiendo"}), item({trend: "subiendo"}), item()]}).map(b => b.kind), ["rising"]);
  assert.deepEqual(H.marketBanners({phase: "normal", items: [item({n: 5, N: null, status: "SIN_DATOS", trend: null}), item()]}), [], "learning only while no item has a normal price");
  assert.match(H.cholloEmptyText({phase: "proteccion", items: []}), /^Protección de lanzamiento: hasta el 18 de noviembre/);
  assert.match(H.cholloEmptyText({phase: "normal", items: [item({n: 5, N: null, status: "SIN_DATOS"})]}), /^Aprendiendo precios: hacen falta 7 días con datos \(de momento 5 días\)\.$/);
  assert.match(H.cholloEmptyText({phase: "normal", items: [item({price: null})]}), /^Hoy todavía nadie ha escaneado/);
  assert.match(H.cholloEmptyText({phase: "normal", items: falling}), /^El mercado está bajando/);
  assert.match(H.cholloEmptyText({phase: "normal", items: [item()]}), /^Hoy nadie de la hermandad ha visto/);
  assert.match(H.cholloEmptyText({phase: "normal", items: []}), /^Todavía no hay objetos/);
});

// ---- flip calculator ------------------------------------------------------------------------------------------
test("calculatorFlip runs especular.flip on typed amounts (worked example of the vectors)", () => {
  const detail = {item: {vendor: 0}, baseline: {Rs: 10000, Q: 400}};
  const inputs = {units: "100", buy: "60s", resale: "1g", cut: "5", deposit: "50c", budget: "200g"};
  const {result, opts} = H.calculatorFlip(detail, inputs);
  assert.deepEqual(opts, {cutBp: 500, D: 50, vendor: 0, budget: 2000000});
  assert.deepEqual(result, E.flip({Rs: 10000, Q: 400}, [[6000, 100]], opts));
  // 83 units: the per-item budget (25 % of 200g = 50g) buys 83 at 60s; cost 498000 + 83 lost deposits of 50c.
  assert.deepEqual([result.netUnit, result.maxBuy, result.capLiq, result.capBudget, result.units, result.cost, result.profit, result.avgIn, result.breakEven],
    [9499, 8216, 100, 500000, 83, 498000, 286267, 6050, 6370]);
  assert.equal(H.calculatorFlip(detail, {...inputs, cut: "15"}).result.maxBuy, 7346);
  assert.equal(H.calculatorFlip(detail, {...inputs, cut: "5,5"}).opts.cutBp, 550);
  const resale = H.calculatorFlip(detail, {...inputs, resale: "1g 50s"}).result;
  assert.deepEqual([resale.Rs, resale.netUnit, resale.maxBuy], [15000, 14249, 12346], "the typed resale replaces the guild's");
  assert.equal(H.calculatorFlip(detail, {...inputs, units: "5000", budget: "100000g"}).result.units, 100, "up to 10.000 units, then the liquidity cap");
  const estimated = H.calculatorFlip({item: {vendor: 2000}, baseline: {Rs: 10000}}, {...inputs, deposit: ""}).result;
  assert.deepEqual([estimated.D, estimated.depositEstimated], [1200, true]);
  assert.equal(E.texts.flip(result, H.formatGSC), "Compra 83× a 82s 16c como máximo; no revendas por debajo de 63s 70c; objetivo 1g; ganancia ≈ 28g 62s 67c tras la comisión y un depósito perdido");
  const errors = [[{units: "0"}, /^Unidades/], [{units: "1,5"}, /^Unidades/], [{units: "10001"}, /^Unidades/], [{buy: ""}, /^Precio de compra/],
    [{buy: "1x"}, /^Precio de compra/], [{resale: "0"}, /^Precio de reventa/], [{cut: "100"}, /^Comisión/], [{cut: "-1"}, /^Comisión/],
    [{deposit: "abc"}, /^Depósito/], [{budget: "0"}, /^Presupuesto/]];
  for (const [change, message] of errors) assert.match(H.calculatorFlip(detail, {...inputs, ...change}).error, message, JSON.stringify(change));
});

// ---- static page contract ---------------------------------------------------------------------------------------
// ---- Qué compensa -----------------------------------------------------------------------------------------------
const marketOf = (items, extra = {}) => ({phase: "normal", cutBp: 500, budget: E.BUDGET, items, ...extra});
const stock = (id, fields = {}) => ({id, name: `Objeto ${id}`, cat: "metal", vendor: 0, deposit: {D: 0}, verdict: "NORMAL", trend: "estable", ...fields});
const today = (lo, qty5 = 50) => ({lo, qty5});

test("the gathering and smelting tables are the addon's, and the watchlist prices all of them", () => {
  const lua = read("addon/OroHermandad/Data.lua");
  const pairs = text => [...text.matchAll(/\{(\d+),\s*([\d.]+)\}/g)].map(m => [Number(m[1]), Number(m[2])]);
  const between = (from, to) => { const start = lua.indexOf(from); return lua.slice(start, lua.indexOf(to, start)); };
  const nodes = (prof, next) => [...between(`  ${prof} = {`, next).matchAll(/\{key = "(\w+)",\s*skill = (\d+),(?:\s*note = "([^"]*)",)?\s*level = \{(\d+), (\d+)\},(\s*rare = true,)?\s*items = \{(.*?)\},\s*zones = "([^"]*)"\}/gs)]
    .map(m => ({prof, key: m[1], skill: Number(m[2]), ...(m[3] ? {note: m[3]} : {}), level: [Number(m[4]), Number(m[5])], ...(m[6] ? {rare: true} : {}), items: pairs(m[7]), zones: m[8]}));
  const cloth = [...between("Data.CLOTH = {", "Fundición").matchAll(/\{item = (\d+),\s*minLevel = (\d+),\s*maxLevel = (\d+),\s*mobs = "([^"]*)"\}/g)]
    .map(m => ({prof: "cloth", key: m[1], skill: 1, level: [Number(m[2]), Number(m[3])], items: [[Number(m[1]), 1]], zones: m[4]}));
  const parsed = [...nodes("mining", "  herbalism = {"), ...nodes("herbalism", "  skinning = {"), ...nodes("skinning", "Data.CLOTH = {"), ...cloth];
  assert.equal(parsed.length, 47);
  assert.deepEqual(parsed, [...H.GATHER]);
  const smelt = [...between("Data.SMELT = {", "-- Barra").matchAll(/\{product = (\d+),\s*qty = (\d+),\s*skill = (\d+),\s*reagents = \{((?:\{\d+, \d+\}(?:, )?)+)\}\}/g)]
    .map(m => ({product: Number(m[1]), qty: Number(m[2]), skill: Number(m[3]), reagents: pairs(m[4])}));
  assert.equal(smelt.length, 10);
  assert.deepEqual(smelt, [...H.SMELT]);
  for (const [id, {buy}] of Object.entries(H.VENDOR_ITEMS)) assert.match(lua, new RegExp(`\\[${id}\\] = ${buy},`));
  const watched = new Set(Object.values(WATCHLIST).flat());
  for (const node of H.GATHER) for (const [id] of node.items) assert.ok(watched.has(id), `${node.key}: ${id}`);
  for (const recipe of H.SMELT) for (const id of [recipe.product, ...recipe.reagents.map(r => r[0])]) assert.ok(watched.has(id) || H.VENDOR_ITEMS[id], `${recipe.product}: ${id}`);
});

test("salePrice is the prudent resale, then today's lowest, then the last three days", () => {
  assert.deepEqual(H.salePrice(stock(1, {Rs: 900, price: today(700)})), {price: 900, source: "prudente"});
  assert.deepEqual(H.salePrice(stock(1, {price: today(700), spark: [1, 2]})), {price: 700, source: "hoy"});
  assert.deepEqual(H.salePrice(stock(1, {spark: [500, 400, null, null]})), {price: 400, source: "reciente"});
  assert.equal(H.salePrice(stock(1, {spark: [500, null, null, null]})), null, "four days ago is too old");
  assert.equal(H.salePrice(undefined), null);
});

test("farmRows values every material of a node after the cut, like the addon's routes", () => {
  const items = [stock(3858, {name: "Mineral de mitril", Rs: 10000, conf: "ALTA", confLabel: "Fiable", d7: -120, Q: 300}), stock(7912, {name: "Piedra sólida", Rs: 1000}),
    stock(2770, {name: "Mineral de cobre", price: today(100)}), stock(2835, {name: "Piedra basta", price: today(1000)}),
    stock(13468, {name: "Loto negro", Rs: 3000000}), stock(14047, {name: "Paño rúnico", Rs: 5000}), stock(13463, {name: "Hojasueño", Rs: 20000})];
  const {rows, unpriced} = H.farmRows(marketOf(items));
  assert.deepEqual(rows.map(r => r.key), ["dreamfoil", "mithril", "copper"], "best first; rare nodes and cloth stay out");
  const mithril = rows[1];
  assert.equal(mithril.value, 2 * 9500 + 380, "2 × 95 % of 1g and 0,4 × 95 % of 10s");
  assert.deepEqual(mithril.parts.map(p => [p.id, p.net, p.value]), [[3858, 9500, 19000], [7912, 950, 380]]);
  assert.equal(mithril.unpricedParts, 3);
  assert.equal(mithril.source, "prudente");
  assert.equal(mithril.per, "veta");
  assert.equal(mithril.label, "Minería");
  assert.equal(rows[2].value, 2 * 95 + 427, "0,45 × 950 keeps its exact thousandths and rounds down at the end");
  assert.equal(rows[2].source, "hoy");
  assert.equal(unpriced, H.GATHER.filter(n => n.prof !== "cloth" && !n.rare).length - 3);
  assert.equal(H.partsText(mithril), "2 × Mineral de mitril");
  assert.equal(H.partsText(mithril, {all: true}), "2 × Mineral de mitril · 0,4 × Piedra sólida");
  assert.deepEqual(H.farmRows(marketOf(items), {skill: 174}).rows.map(r => r.key), ["copper"]);
  assert.deepEqual(H.farmRows(marketOf(items), {prof: "herbalism", rare: true}).rows.map(r => r.key), ["blacklotus", "dreamfoil"]);
  assert.deepEqual(H.farmRows(marketOf(items), {prof: "cloth"}).rows.map(r => [r.key, r.value, r.per]), [["14047", 4750, "unidad"]]);
  assert.equal(H.farmRows(marketOf(items, {cutBp: 0}), {prof: "cloth"}).rows[0].value, 5000, "the learned cut counts");
});

test("resaleRows only says buy for a chollo that pays, and the budget limits it", () => {
  const chollo = stock(1, {name: "Chollo", verdict: "CHOLLO", Rs: 10000, Q: 400, price: today(5000, 100)});
  const cheap = stock(2, {name: "Barato, bajada", verdict: "BAJADA", Rs: 10000, Q: 400, price: today(5000, 100)});
  const near = stock(3, {name: "Cerca", Rs: 10000, Q: 400, price: today(8700, 100)}), far = stock(4, {name: "Lejos", Rs: 10000, Q: 400, price: today(12000, 100)});
  const silent = stock(5, {name: "Sin precio hoy", Rs: 10000}), learning = stock(6, {name: "Aprendiendo", price: today(100)});
  const rows = H.resaleRows(marketOf([far, silent, near, cheap, chollo, learning]));
  assert.deepEqual(rows.map(r => r.id), [1, 2, 3, 4, 5], "to buy first, then the nearest to paying, and no resale means no row");
  assert.deepEqual(rows.map(r => r.buy), [true, false, false, false, false]);
  const expected = E.flip({Rs: 10000, Q: 400}, null, {cutBp: 500, D: 0, vendor: 0, budget: E.BUDGET, p: 5000, q5: 100});
  assert.deepEqual(rows[0].flip, expected);
  assert.equal(rows[0].flip.units, 50, "25 % of a 100g budget at 50s");
  assert.equal(H.resaleRows(marketOf([chollo]), {budget: 10000000})[0].flip.units, 100, "1.000g: then what is on sale limits it");
  assert.equal(rows[0].gapBp, E.idiv(5000 * 10000, expected.maxBuy) - 10000);
  assert.ok(rows[2].gapBp > 0 && rows[3].gapBp > rows[2].gapBp);
  assert.equal(rows[4].gapBp, null);
  assert.equal(H.resaleRows(marketOf([stock(1, {verdict: "PROTECCION", Rs: 10000, Q: 400, price: today(5000, 100)})], {phase: "proteccion"}))[0].buy, false);
});

test("smeltRows buys the reagents today and sells the bar under the rules of a purchase to resell", () => {
  const mithril = () => [stock(3858, {name: "Mineral de mitril", price: today(1000)}), stock(3860, {name: "Lingote de mitril", Rs: 2000, Q: 400, deposit: {D: 100}})];
  const [row] = H.smeltRows(marketOf(mithril())).rows;
  assert.equal(row.unitCost, 1000);
  const f = E.flip({Rs: 2000, Q: 400}, [[1000, 50]], {cutBp: 500, D: 100, vendor: 0, budget: E.BUDGET});
  assert.deepEqual(row.flip, f);
  assert.deepEqual([f.netUnit, f.risk, f.units, f.profit, f.accept], [1899, 100, 50, 39950, true]);
  assert.deepEqual([row.unitProfit, row.marginBp, row.pays, row.label], [799, 7263, true, "Compensa"]);
  const lose = H.smeltRows(marketOf([stock(3858, {price: today(3000)}), stock(3860, {Rs: 2000, Q: 400, deposit: {D: 100}})])).rows[0];
  assert.deepEqual([lose.unitProfit, lose.pays, lose.label], [-1201, false, "No compensa"]);
  assert.equal(H.smeltRows(marketOf(mithril(), {phase: "proteccion"})).rows[0].label, "Orientativo", "no buying advice during the launch guard");
  const falling = [stock(3858, {price: today(1000)}), stock(3860, {Rs: 2000, Q: 400, deposit: {D: 100}, trend: "bajando"})];
  assert.deepEqual([H.smeltRows(marketOf(falling)).rows[0].pays, H.smeltRows(marketOf(falling)).rows[0].label], [false, "Mercado bajando"]);
  const early = [stock(3858, {price: today(1000)}), stock(3860, {price: today(2000)})];
  assert.deepEqual([H.smeltRows(marketOf(early)).rows[0].source, H.smeltRows(marketOf(early)).rows[0].label], ["hoy", "Orientativo"], "without a normal price it never pays");
  // Coal comes from the merchant, unless the auction house is cheaper; two bars per craft share the cost, rounded up.
  const steel = H.smeltRows(marketOf([stock(3575, {name: "Lingote de hierro", price: today(1500, 8)}), stock(3859, {name: "Lingote de acero", Rs: 4000, Q: 800})])).rows[0];
  assert.deepEqual(steel.parts.map(p => [p.name, p.unit, p.fromVendor]), [["Lingote de hierro", 1500, false], ["Carbón", 500, true]]);
  assert.equal(steel.unitCost, 2000);
  assert.equal(steel.flip.units, 8, "what is on sale near the lowest limits the batch; the merchant does not");
  const cheapCoal = H.smeltRows(marketOf([stock(3575, {price: today(1500)}), stock(3857, {price: today(300)}), stock(3859, {Rs: 4000})])).rows[0];
  assert.deepEqual(cheapCoal.parts[1].unit, 300);
  const bronze = H.smeltRows(marketOf([stock(2840, {price: today(101)}), stock(3576, {price: today(200)}), stock(2841, {Rs: 1000})])).rows[0];
  assert.deepEqual([bronze.qty, bronze.unitCost], [2, 151]);
  const missing = H.smeltRows(marketOf([stock(3860, {Rs: 2000})]));
  assert.deepEqual([missing.rows.length, missing.unpriced], [0, H.SMELT.length], "a reagent without a price today hides the recipe");
});

test("bestCards answers the three questions and never calls a launch price good news", () => {
  const items = [stock(13463, {name: "Hojasueño", Rs: 20000}), stock(14047, {name: "Paño rúnico", verdict: "CHOLLO", Rs: 10000, Q: 400, price: today(5000, 100)}),
    stock(3858, {name: "Mineral de mitril", price: today(1000)}), stock(3860, {name: "Lingote de mitril", Rs: 2000, Q: 400, deposit: {D: 100}})];
  const answer = (summary, filters) => H.bestCards(summary, H.farmRows(summary, filters), H.resaleRows(summary), H.smeltRows(summary));
  const [farm, resale, smelt] = answer(marketOf(items));
  assert.deepEqual([farm.key, farm.name, farm.id, farm.amount, farm.per, farm.good], ["farm", "Hojasueño", 13463, 38000, "por planta", false]);
  assert.match(farm.note, /^Herboristería · con reventa prudente/);
  assert.deepEqual([resale.name, resale.good], ["Paño rúnico", true]);
  assert.match(resale.note, /^Compra 50× a /);
  assert.deepEqual([smelt.name, smelt.amount, smelt.good], ["Lingote de mitril", 799, true]);
  assert.match(smelt.note, /^Lote de 50: ganas ≈ 3g 99s 50c$/);
  const guard = answer(marketOf([items[0], stock(14047, {name: "Paño rúnico", verdict: "PROTECCION", Rs: 10000, Q: 400, price: today(5000, 100)}), items[2], items[3]], {phase: "proteccion"}));
  assert.deepEqual([guard[1].name, guard[1].good, guard[1].amount], ["Hoy, nada", false, null]);
  assert.match(guard[1].note, /^Protección de lanzamiento/);
  assert.deepEqual([guard[2].name, guard[2].good, guard[2].amount], ["Lingote de mitril", false, 799]);
  assert.match(guard[2].note, /^Orientativo/);
  const weak = answer(marketOf([stock(1, {name: "Flojo", verdict: "CHOLLO", Rs: 10000, Q: 400, price: today(8000, 1)})]));
  assert.match(weak[1].note, /^Hay chollos, pero ninguno compensa/);
  const empty = answer(marketOf([]));
  assert.deepEqual(empty.map(c => [c.name, c.id, c.amount]), [["Sin datos", null, null], ["Hoy, nada", null, null], ["Hoy, nada", null, null]]);
  const html = read("public/hermandad.html");
  for (const card of empty) assert.match(html, new RegExp(`id="${card.target.slice(1)}"`));
});

test("marketMapSVG places each item by price and variation over the rule's own areas", () => {
  // The areas are the real lines of especular.assess: 20 % below (25 % above) or 2,5 times the variation.
  for (const sBp of [300, 800, 1200, 2000, 2500]) {
    const a = E.assess({n: 14, N: 100000, sBp, trend: "estable", conf: "ALTA", fresh: true}, 100000, 2600);
    assert.ok(Math.abs((a.dumpLine - 100000) / 10 + Math.max(2000, 2.5 * sBp)) <= 1, `chollo line at ${sBp}`);
    assert.ok(Math.abs((a.spikeLine - 100000) / 10 - Math.max(2500, 2.5 * sBp)) <= 1, `caro line at ${sBp}`);
  }
  const point = (id, dBp, sBp, verdict = "NORMAL", name = `Objeto ${id}`) => ({id, name, dBp, sBp, verdict});
  const chart = H.marketMapSVG({items: [point(1, -3000, 500, "CHOLLO", "Paño <rúnico>"), point(2, 4000, 900, "CARO"), point(3, 200, 700), point(4, -500, 1500), point(5, 20000, 90000), {id: 6, name: "Sin precio", dBp: null, sBp: 400, verdict: "SIN_PRECIO"}], width: 720, height: 380});
  const markup = svgText(chart.node);
  assert.doesNotMatch(markup, /NaN|undefined|Infinity/);
  assert.match(markup, /Paño &lt;rúnico&gt;/, "names are escaped");
  assert.ok(fontSizes(markup).every(size => size >= 12));
  assert.equal(chart.layout.points.length, 5, "without a price today there is nothing to place");
  assert.deepEqual(chart.layout.points.map(p => p.e.id), [1, 4, 3, 2, 5], "keyboard order is left to right");
  assert.equal((markup.match(/<g class="good">.*?<\/g>/)[0].match(/<circle/g) ?? []).length, 1);
  assert.equal((markup.match(/<g class="up">.*?<\/g>/)[0].match(/<rect/g) ?? []).length, 1, "caro has its own shape, not only its own colour");
  assert.equal((markup.match(/<g class="rest">.*?<\/g>/)[0].match(/<circle/g) ?? []).length, 3);
  const off = chart.layout.points.find(p => p.e.id === 5);
  assert.deepEqual([off.x, off.y], [chart.layout.x1, chart.layout.y0], "values beyond the axes stay on the chart");
  const zones = markup.match(/class="zone-good" points="([^"]+)"/)[1].split(" ");
  assert.equal(zones.length, 5);
  assert.equal(H.marketMapSVG({items: [point(1, null, 500)]}), null);
  const narrow = svgText(H.marketMapSVG({items: Array.from({length: 40}, (_, i) => point(i + 1, -2500 - i * 50, 400 + i * 10, "CHOLLO")), width: 320, height: 300}).node);
  assert.ok((narrow.match(/<g class="labels"[^>]*>.*?<\/g>/)[0].match(/<text/g) ?? []).length <= 3, "few labels on a phone");
  assert.doesNotMatch(narrow, /NaN/);
});

test("the page is CSP-safe: one module script, no inline code, no external requests, no HTML injection", () => {
  const html = read("public/hermandad.html"), js = read("public/hermandad.js"), css = read("public/hermandad.css");
  assert.deepEqual([...html.matchAll(/<script\b[^>]*>/g)].map(m => m[0]), ['<script type="module" src="/hermandad.js">']);
  assert.doesNotMatch(html, /<script[^>]*>[^<]+<\/script>/, "no inline script");
  assert.doesNotMatch(html, /\son[a-z]+=/i, "no inline event handler");
  assert.doesNotMatch(html, /style="/);
  const external = [...html.matchAll(/(?:href|src)="(https?:[^"]+)"/g)].map(m => m[1]);
  assert.deepEqual(external, [H.RELEASES_URL], "the only external URL is the addon release link (a link, not a request)");
  assert.match(html, /href="https:\/\/github\.com\/carulla94\/el-especulador-del-wow\/releases" target="_blank" rel="noopener noreferrer"/);
  assert.match(html, /href="\/api\/guild\/download\/sincronizador" download/);
  assert.doesNotMatch(css, /@import|url\((?!["']?data:)/);
  const code = js.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
  assert.doesNotMatch(code, /innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function/);
  assert.deepEqual([...js.matchAll(/import\(\s*["']([^"']+)["']\s*\)/g)].map(m => m[1]), ["./especular.js"]);
  assert.doesNotMatch(js, /^\s*import\s/m, "no static import: the builders load in Node without the generated copy");
  for (const [, url] of js.matchAll(/request\(\s*[`"']([^`"'$]+)/g)) assert.match(url, /^\/api\/guild\//);
  assert.doesNotMatch(js, /fetch\(\s*["'`]https?:/);
});

test("every element the page script looks up exists in the HTML", () => {
  const html = read("public/hermandad.html"), js = read("public/hermandad.js");
  const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map(m => m[1]));
  const wanted = new Set([...js.matchAll(/\$\("#([A-Za-z0-9_-]+)/g), ...js.matchAll(/getElementById\("([^"]+)"\)/g)].map(m => m[1]));
  wanted.delete("calc"); wanted.delete("calc-result");         // built by the script inside the item detail
  assert.ok(wanted.size > 40);
  for (const id of wanted) assert.ok(ids.has(id), `#${id} is missing from hermandad.html`);
  assert.equal(new Set([...html.matchAll(/\sid="([^"]+)"/g)].map(m => m[1])).size, [...html.matchAll(/\sid="([^"]+)"/g)].length, "ids are unique");
  for (const screen of ["loading", "login", "fatal", "mercado", "compensa", "balance", "miembros", "unirse"]) assert.match(html, new RegExp(`id="screen-${screen}" data-screen`));
  assert.match(html, /<a href="#compensa" data-tab="compensa">/);
  const headers = [...html.matchAll(/<th scope="col"(?: data-sort="(\w+)")?/g)].filter((m, i) => i < 11).map(m => m[1] ?? null);
  assert.deepEqual(headers, ["name", "hoy", "N", "d1", "d7", "range", null, "Q", "members", "conf", "verdict"]);
  for (const key of headers.filter(Boolean)) assert.ok(H.SORTS[key], key);
  assert.match(js, /colspan: "11"/, "category rows span every column");
});

test("no text is smaller than 12 px and the theme tokens are those of styles.css", () => {
  const css = read("public/hermandad.css");
  const sizes = [...css.matchAll(/font-size:\s*([\d.]+)(px|em|rem)/g)];
  assert.ok(sizes.length > 20);
  for (const [, value, unit] of sizes) assert.ok(unit === "px" && Number(value) >= 12, `font-size ${value}${unit}`);
  assert.doesNotMatch(css, /font:\s*[^;]*\b(?:[0-9]|1[01])px/);
  const tokens = text => Object.fromEntries([...text.matchAll(/--([a-z0-9-]+):([^;}]+)/g)].map(m => [m[1], m[2].trim()]));
  const app = read("public/styles.css").split("\n").map(line => line.match(/^:root\{([^}]*)\}/)?.[1]).filter(Boolean).at(-1);
  const theirs = tokens(app), ours = tokens(css.match(/:root\{([^}]*)\}/)[1]);
  for (const name of ["bg", "surface", "surface-2", "border", "text", "muted", "gold", "gold-bright", "blue", "green", "red", "radius"]) assert.equal(ours[name], theirs[name], name);
  for (const [name, value] of Object.entries({"chart-price": H.CHART.price, "chart-good": H.CHART.good, "chart-down": H.CHART.down, "chart-up": H.CHART.up})) assert.equal(ours[name], value, name);
  assert.equal(H.CHART.surface, ours.surface);
});

test("the owner app links the panel, and the Pages edition never does", () => {
  const index = read("public/index.html");
  assert.match(index, /<a class="nav-button" href="\/hermandad"><span aria-hidden="true">⚑<\/span> Hermandad<\/a>/);
  assert.match(read("scripts/build-pages.mjs"), /\.replace\('href="\/hermandad"', 'href="#hermandad-en-la-nube" data-pages-guild hidden'\)/);
});

// ---- how the worker and the build serve it ----------------------------------------------------------------------
function sqliteContext() {
  const db = new DatabaseSync(":memory:");
  const sql = {exec(query, ...bindings) {
    const statement = db.prepare(query);
    const rows = statement.columns().length ? statement.all(...bindings) : (statement.run(...bindings), []);
    return {toArray: () => rows, [Symbol.iterator]: () => rows[Symbol.iterator]()};
  }};
  return {db, ctx: {storage: {sql, transactionSync(callback) {
    db.exec("BEGIN IMMEDIATE");
    try { const result = callback(); db.exec("COMMIT"); return result; } catch (error) { db.exec("ROLLBACK"); throw error; }
  }}}};
}
function fixture(t, {configured = true, T = 2526} = {}) {
  const P = sqliteContext(), G = sqliteContext(), assets = [];
  t.after(() => { P.db.close(); G.db.close(); });
  const env = {OWNER_PASSWORD: configured ? PASSWORD : undefined, SESSION_SECRET: "test-only-independent-session-secret-99",
    ASSETS: {async fetch(request) { const p = new URL(request.url).pathname; assets.push(p); return new Response("asset:" + p, {headers: {"Content-Type": "text/plain"}}); }}};
  const portfolio = new Portfolio(P.ctx, env), market = new GuildMarket(G.ctx, env);
  let clock = at(T, 20, 30) * 1000;
  market.now = () => clock;
  env.PORTFOLIO = {idFromName: n => n, get: () => ({fetch: r => portfolio.fetch(r)})};
  env.GUILD = {idFromName: n => n, get: () => ({fetch: r => market.fetch(r)})};
  return {env, assets, gdb: G.db, get nowSec() { return Math.floor(clock / 1000); },
    call(p, {method = "GET", data, cookie, csrf, token} = {}) {
      const h = new Headers();
      if (cookie) h.set("Cookie", cookie);
      if (csrf) h.set("X-CSRF-Token", csrf);
      if (token) h.set("Authorization", "Bearer " + token);
      if (data !== undefined) { h.set("Content-Type", "application/json"); h.set("Origin", BASE); }
      return worker.fetch(new Request(BASE + p, {method, headers: h, ...(data !== undefined ? {body: typeof data === "string" ? data : JSON.stringify(data)} : {})}), env);
    },
    async owner() {
      const login = await this.call("/api/login", {method: "POST", data: {password: PASSWORD}});
      const cookie = login.headers.get("Set-Cookie").split(";")[0];
      return {cookie, csrf: (await (await this.call("/api/guild/me", {cookie})).json()).csrf};
    },
    async key(owner, label) {
      const {member} = await (await this.call("/api/guild/members", {method: "POST", data: {label}, ...owner})).json();
      return (await (await this.call("/api/guild/keys", {method: "POST", data: {memberId: member.id}, ...owner})).json()).key;
    }};
}

test("the worker serves the panel, its module and the rules without a session, and nothing else", async t => {
  for (const configured of [true, false]) {
    const f = fixture(t, {configured});
    for (const [p, asset] of [["/hermandad", "/hermandad.html"], ["/hermandad.html", "/hermandad.html"], ["/hermandad.js", "/hermandad.js"],
      ["/hermandad.css", "/hermandad.css"], ["/especular.js", "/especular.js"]]) {
      const response = await f.call(p);
      assert.equal(response.status, 200, p);
      assert.equal(await response.text(), "asset:" + asset);
      assert.match(response.headers.get("Content-Security-Policy"), /script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'/);
      assert.equal(response.headers.get("X-Frame-Options"), "DENY");
    }
    for (const p of ["/hermandad/", "/especular.mjs", "/guild.mjs", "/src/especular.mjs", "/hermandad.json"]) {
      const response = await f.call(p);
      assert.equal(response.status, 302, p);
      assert.ok(!f.assets.includes(p), p);
    }
    const post = await f.call("/hermandad", {method: "POST", data: {}});
    assert.equal(post.status, 302, "only GET is public: anything else goes to the owner login");
    assert.equal(post.headers.get("Location"), BASE + "/login");
  }
});

test("the build copies src/especular.mjs byte for byte to public/especular.js, a standalone module", t => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "hermandad-build-"));
  t.after(() => fs.rmSync(work, {recursive: true, force: true}));
  for (const file of ["scripts/prepare-downloads.mjs", "src/especular.mjs", ...["sincronizar.py", "SINCRONIZAR.cmd", "LEEME.md", "hermandad.py", "HERMANDAD.cmd"].map(n => "pc_sync/" + n),
    ...fs.readdirSync(path.join(root, "addon/EspeculadorBridge")).map(n => "addon/EspeculadorBridge/" + n)]) {
    fs.mkdirSync(path.dirname(path.join(work, file)), {recursive: true});
    fs.copyFileSync(path.join(root, file), path.join(work, file));
  }
  fs.mkdirSync(path.join(work, "public"));
  execFileSync(process.execPath, ["scripts/prepare-downloads.mjs"], {cwd: work, stdio: "pipe"});
  const copy = fs.readFileSync(path.join(work, "public/especular.js"));
  assert.ok(copy.equals(fs.readFileSync(path.join(root, "src/especular.mjs"))));
  assert.doesNotMatch(copy.toString("utf8"), /^\s*import\s|\bimport\(|\brequire\(/m, "the rules import nothing, so the copy runs alone in the browser");
  assert.match(read(".gitignore"), /^public\/especular\.js$/m, "the generated copy is never committed");
});

// ---- against the real GuildMarket ------------------------------------------------------------------------------------
const WATCH = [[14047, "tela", "Paño rúnico", 12000], [2589, "tela", "Paño de lino", 600], [10620, "metal", "Mineral de torio", 28000],
  [13463, "hierba", "Hojasueño", 18000], [13510, "frasco", "Frasco de los titanes", 900000], [7076, "elemental", "Esencia de tierra", 30000]];
/** 3 members x 28 days (2499..T) of the items above; today one member sees Paño rúnico at 62 % of normal. falling:
 * the last 10 days lose 3 % a day. */
function body(member, T, {falling = false, start = E.LAUNCH} = {}) {
  const random = rng(member * 97 + 1);
  const items = WATCH.map(([id, cat, name, base]) => {
    const days = [], points = [];
    for (let d = start; d <= T; d++) {
      if (d !== T && random() > 0.85) continue;
      let v = base * (1 + (random() - 0.5) * 0.04);
      if (falling && d >= T - 9) v *= Math.pow(0.97, d - (T - 10));
      let lo = Math.round(v * 0.98), hi = Math.round(v * 1.05);
      if (!falling && d === T && id === 14047 && member === 0) lo = Math.round(base * 0.62);
      days.push([d, lo, Math.max(lo, hi), lo, 300 + member, 2, "o"]);
      if (d >= T - 13) points.push([at(d, 19, 10 + member), lo, 300 + member, 40]);
    }
    return {id, name, cat, vendor: Math.round(base / 40), days, points};
  });
  return {schema: 1, addon: "0.3.0", markets: [{market: MARKET, cut: member === 0 ? 500 : null, items, deposits: member === 0 ? [[14047, 3, 180]] : []}]};
}
async function seeded(t, T, options) {
  const f = fixture(t, {T}), owner = await f.owner();
  for (const [i, label] of ["Ana", "Bruno", "Carla"].entries()) {
    const response = await f.call("/api/guild/sync", {method: "POST", token: await f.key(owner, label), data: body(i, T, options)});
    assert.equal(response.status, 200, await response.clone().text());
  }
  const summary = await (await f.call("/api/guild/market?market=" + encodeURIComponent(MARKET), {cookie: owner.cookie})).json();
  return {f, owner, summary};
}

test("against the real market: CSV of the view and of one item equal the server exports; the calculator defaults equal its flip", async t => {
  const T = 2526, {f, owner, summary} = await seeded(t, T);
  assert.deepEqual(summary.chollos, [14047]);
  const csv = await bytesText(await f.call(`/api/guild/export.csv?market=${encodeURIComponent(MARKET)}&kind=summary`, {cookie: owner.cookie}));
  assert.ok(csv.startsWith("\uFEFFObjeto;ID;"));
  assert.equal(H.csvRows(H.SUMMARY_COLUMNS, summary.items), csv, "'Esta vista' with no filter is the server's summary CSV");
  assert.equal(H.csvRows(H.SUMMARY_COLUMNS, summary.items), GuildStore.prototype.csvSummary.call(null, summary));
  const detail = await (await f.call(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=14047`, {cookie: owner.cookie})).json();
  const daily = await bytesText(await f.call(`/api/guild/export.csv?market=${encodeURIComponent(MARKET)}&kind=daily&days=60`, {cookie: owner.cookie}));
  const serverRows = daily.slice(1).split("\r\n").filter((line, i) => i === 0 || line.split(";")[3] === "14047");
  assert.equal(H.csvRows(H.dailyColumns(detail.item, summary.launchDay), detail.days), "\uFEFF" + serverRows.join("\r\n") + "\r\n");
  // The calculator starts from today's lowest price, its qty within 5 %, the prudent resale, the learned cut and deposit.
  const deposit = detail.deposits.find(x => x.duration === detail.flip.duration).D;
  const defaults = {units: String(detail.price.qty5 >= 1 ? detail.price.qty5 : 1), buy: H.formatGSC(detail.price.lo), resale: H.formatGSC(detail.baseline.Rs),
    cut: String(detail.cutBp / 100), deposit: deposit === null ? "" : H.formatGSC(deposit), budget: H.formatGSC(detail.budget)};
  const {result} = H.calculatorFlip(detail, defaults);
  for (const key of ["units", "cost", "profit", "maxBuy", "breakEven", "netUnit", "risk", "D", "capLiq", "capBudget", "accept", "reason", "depositEstimated"]) {
    assert.deepEqual(result[key], detail.flip[key], key);
  }
  assert.equal(result.accept, true);
  const series = Object.fromEntries(detail.days.map(x => [x.d, x]));
  assert.ok(H.dumpDays(series, T - 59, T).includes(T), "today's dump is marked on the chart");
  const chart = H.bandChartSVG({days: detail.days, from: T - 59, to: T, N: detail.baseline.N, dumpLine: detail.assess.dumpLine, markers: [T], price: detail.price.lo});
  assert.doesNotMatch(svgText(chart.node), /NaN|undefined/);
  assert.equal(H.weekdayBars(detail.weekday).shown, false);
  assert.match(H.weekdayBars(detail.weekday).text, /^Faltan \d semanas? de datos/);
  for (const e of summary.items) assert.doesNotMatch(svgText(H.sparklineSVG(e.spark)), /NaN/);
  assert.equal(H.freshnessLine(summary.freshness, summary.dayOfLaunch, f.nowSec * 1000), "3 personas aportan (3 suben) · último envío hace un momento · día 28 desde el lanzamiento");
});

test("against the real market: 'Qué compensa' works from the summary alone and agrees with its chollo and its item", async t => {
  const T = 2526, {f, owner, summary} = await seeded(t, T);
  const chollo = summary.items.find(e => e.id === 14047);
  const rows = H.resaleRows(summary);
  assert.equal(rows[0].id, 14047);
  assert.equal(rows[0].buy, true);
  assert.equal(rows.filter(r => r.buy).length, 1);
  for (const key of ["units", "cost", "profit", "maxBuy", "breakEven", "netUnit", "risk", "D", "capLiq", "capBudget", "accept", "reason", "depositEstimated"]) {
    assert.deepEqual(rows[0].flip[key], chollo.flip[key], key);
  }
  // The detail's flip uses the same inputs for any verdict, so every row matches its item.
  const other = rows.find(r => r.id === 13463);
  const detail = await (await f.call(`/api/guild/item?market=${encodeURIComponent(MARKET)}&id=13463`, {cookie: owner.cookie})).json();
  for (const key of ["units", "cost", "profit", "maxBuy", "breakEven", "accept", "reason"]) assert.deepEqual(other.flip[key], detail.flip[key], key);
  const farm = H.farmRows(summary);
  assert.deepEqual(farm.rows.map(r => r.key).sort(), ["dreamfoil", "richthorium", "thorium"]);
  const dreamfoil = farm.rows.find(r => r.key === "dreamfoil"), item = summary.items.find(e => e.id === 13463);
  assert.equal(dreamfoil.value, 2 * E.idiv(item.Rs * (10000 - summary.cutBp), 10000));
  assert.deepEqual(H.farmRows(summary, {prof: "cloth"}).rows.map(r => r.key).sort(), ["14047", "2589"]);
  assert.deepEqual(H.smeltRows(summary).rows, [], "this market has no bars");
  const map = H.marketMapSVG({items: summary.items});
  assert.equal(map.layout.points.length, summary.items.length);
  assert.doesNotMatch(svgText(map.node), /NaN|undefined/);
  const [cardFarm, cardResale, cardSmelt] = H.bestCards(summary, farm, rows, H.smeltRows(summary));
  assert.equal(cardFarm.amount, farm.rows[0].value);
  assert.equal(cardResale.id, 14047);
  assert.equal(cardSmelt.id, null);
  const launch = (await seeded(t, 2505)).summary;
  assert.deepEqual(H.resaleRows(launch), [], "no normal price, no resale");
  assert.equal(H.marketMapSVG({items: launch.items}), null);
  assert.equal(H.farmRows(launch).rows.find(r => r.key === "dreamfoil").source, "hoy");
});

test("against the real market: launch week says 'Aprendiendo precios'; a falling market shows its banner and no chollos", async t => {
  const launch = (await seeded(t, 2505)).summary;
  assert.equal(launch.phase, "proteccion");
  assert.ok(launch.items.every(e => e.verdict === "SIN_DATOS"));
  assert.deepEqual(H.marketBanners(launch).map(b => b.kind), ["guard", "learning"]);
  assert.match(H.marketBanners(launch)[1].text, /^6 de 7 días con datos/);
  assert.match(H.cholloEmptyText(launch), /^Protección de lanzamiento/);
  const falling = (await seeded(t, 2526, {falling: true})).summary;
  assert.deepEqual(falling.chollos, []);
  assert.ok(falling.items.every(e => e.verdict === "INESTABLE"));
  const banners = H.marketBanners(falling);
  assert.deepEqual(banners.map(b => b.kind), ["falling"]);
  assert.match(banners[0].text, /^6 de 6 objetos con precio normal han caído más de un 10 % en una semana/);
  assert.match(H.cholloEmptyText(falling), /^El mercado está bajando/);
});

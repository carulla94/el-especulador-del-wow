/** «Cuándo vender» (src/timing.mjs): weekday × time-of-day cells in Spanish time, against the item's own level. */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import crypto from "node:crypto";
import {buildTiming, localSlot, TIMING, TIMING_VERSION, SALES} from "../src/timing.mjs";
import {DAY0, weekdayOf, dayIndex} from "../src/especular.mjs";

/** Byte copies of the shared 0.6.0 fixtures (contracts C5 and C8), pinned: never edited here. */
const v06 = name => fs.readFileSync(new URL("./fixtures/v06/" + name, import.meta.url));
const V06_SHA = {"madrid-slots.json": "6cb2edb2be99aff756484a928084dc151191488fffc8b45d2cbe27dcf18f0a5b",
  "timing-v2.json": "4b312978359deeffde566386da38f3e8eae34d1e3f6c51519fb66c88b6a62023"};

const DAY = 86400;
const T = 2530;                                            // 2026-12-05, a Saturday
// Day d starts at 00:00 CET (DAY0); in winter Spanish time is CET, so hour h of day d is local hour h.
const at = (d, hour, minute = 0) => DAY0 + d * DAY + hour * 3600 + minute * 60;

test("localSlot gives the weekday and the time of day in Spanish time, summer time included", () => {
  // Wednesday 18 November 2026, 20:30 in Madrid (19:30 UTC).
  assert.deepEqual(localSlot(Date.UTC(2026, 10, 18, 19, 30) / 1000), {wd: 2, hour: 20, block: 5, cell: 17});
  // Sunday 5 July 2026, 14:00 in Madrid (12:00 UTC, summer time).
  assert.deepEqual(localSlot(Date.UTC(2026, 6, 5, 12, 0) / 1000), {wd: 6, hour: 14, block: 3, cell: 39});
  // Monday 00:10 in Madrid is still Sunday 23:10 UTC.
  assert.deepEqual(localSlot(Date.UTC(2026, 10, 22, 23, 10) / 1000), {wd: 0, hour: 0, block: 0, cell: 0});
  assert.equal(weekdayOf(T), 5, "the fixture's today is a Saturday");
  assert.equal(localSlot(at(T, 12)).wd, 5);
});

test("evening scans above the week's level and morning scans below it land in their cells", () => {
  const points = [];
  for (let d = T - 13; d <= T; d++) {
    points.push({item_id: 7, person: 1, t: at(d, 9), lo: 900, qty: 200});      // morning: 10 % below 1000
    points.push({item_id: 7, person: 1, t: at(d, 14), lo: 1000, qty: 100});    // afternoon: the level
    points.push({item_id: 7, person: 2, t: at(d, 21), lo: 1100, qty: 50});     // evening: 10 % above
  }
  const out = buildTiming({points, T});
  assert.deepEqual([out.T, out.timeZone, out.hours, out.blocks, out.days], [T, "Europe/Madrid", 4, 6, TIMING.days]);
  const [item] = out.items;
  assert.equal(item.id, 7);
  assert.equal(item.n, 42);
  const cells = new Map(item.cells.map(c => [c[0], c]));
  // Every weekday appears twice in 14 days; the reference is the median of the points around (1000).
  for (let wd = 0; wd < 7; wd++) {
    // No sell-through samples: the six sales columns of cuando-vender-2 are zero.
    assert.deepEqual(cells.get(wd * 6 + 2), [wd * 6 + 2, 2, 2, -2000, 2, 2 * 10000, 0, 0, 0, 0, 0, 0], "morning, 2 points of 2 days, −10 % each, twice the usual quantity");
    assert.deepEqual(cells.get(wd * 6 + 3), [wd * 6 + 3, 2, 2, 0, 2, 0, 0, 0, 0, 0, 0, 0]);
    assert.deepEqual(cells.get(wd * 6 + 5), [wd * 6 + 5, 2, 2, 2000, 2, -2 * 5000, 0, 0, 0, 0, 0, 0]);
  }
  assert.equal(item.cells.length, 21);
  assert.deepEqual(item.wd, [], "no day values, no weekday profile");
});

test("one person counts once per moment, a lone point has no reference and an absurd price is clipped", () => {
  const points = [];
  for (let d = T - 6; d <= T; d++) points.push({item_id: 3, person: 1, t: at(d, 12), lo: 1000, qty: 10});
  // The same person by two slots at the same moment: one point, the lowest price and the largest quantity.
  points.push({item_id: 3, person: 1, t: at(T, 21), lo: 1500, qty: 4}, {item_id: 3, person: 1, t: at(T, 21), lo: 1200, qty: 9});
  // A listing at ten times the price.
  points.push({item_id: 3, person: 2, t: at(T - 1, 1), lo: 10000, qty: 1});
  // An item with only two points: nothing to compare with.
  points.push({item_id: 4, person: 1, t: at(T, 12), lo: 50, qty: 1}, {item_id: 4, person: 1, t: at(T - 1, 12), lo: 55, qty: 1});
  const out = buildTiming({points, T});
  assert.deepEqual(out.items.map(i => i.id), [3]);
  const cells = new Map(out.items[0].cells.map(c => [c[0], c]));
  const evening = localSlot(at(T, 21)).cell, night = localSlot(at(T - 1, 1)).cell;
  assert.deepEqual(cells.get(evening).slice(0, 4), [evening, 1, 1, 2000], "1200 against 1000");
  assert.deepEqual(cells.get(night).slice(0, 4), [night, 1, 1, TIMING.clipBp], "ten times the price counts as +50 %");
  assert.equal(out.items[0].n, 9);
});

test("the weekday profile compares each finished day with the days around it", () => {
  const days = [];
  for (let d = T - 30; d <= T; d++) days.push({item_id: 9, day: d, v: weekdayOf(d) === 6 ? 1200 : 1000});
  days.push({item_id: 9, day: T, v: 5000});                     // today, not over: left out
  const out = buildTiming({days: days.filter((r, i, all) => all.findLastIndex(x => x.day === r.day) === i), T});
  const [item] = out.items;
  assert.equal(item.n, 0);
  assert.deepEqual(item.cells, []);
  const wd = new Map(item.wd.map(x => [x[0], x]));
  // Sundays at 1200 against a median of 1000 around them: +20 %; the other days at the median.
  assert.deepEqual(wd.get(6), [6, 4, 4 * 2000]);
  for (const w of [0, 1, 2, 3, 4]) assert.deepEqual(wd.get(w).slice(2), [0], `weekday ${w}`);
  assert.equal([...wd.values()].reduce((s, x) => s + x[1], 0), 30, "thirty finished days");
});

// ---- cuando-vender-2: sell-through samples (contract C8) and the Spanish slot (contract C5) --------------------------
test("the 0.6.0 fixtures are byte copies of the shared ones", () => {
  for (const [name, hash] of Object.entries(V06_SHA)) assert.equal(crypto.createHash("sha256").update(v06(name)).digest("hex"), hash, name);
});

test("localSlot gives exactly the weekday, hour, block and cell of every vector of madrid-slots.json (the addon's Spec.MadridSlot)", () => {
  const {vectors} = JSON.parse(v06("madrid-slots.json"));
  assert.ok(vectors.length > 1000);
  for (const [t, wd, hour, block, cell, text] of vectors) assert.deepEqual(localSlot(t), {wd, hour, block, cell}, text);
});

test("buildTiming equals timing-v2.json: twelve-column cells, one sample per person and moment, overlapping persons merged", () => {
  const {input, expected} = JSON.parse(v06("timing-v2.json"));
  assert.equal(TIMING_VERSION, "cuando-vender-2");
  assert.deepEqual(buildTiming(input), expected);
  // Without the samples the first six columns are cuando-vender-1's, and items with only samples are gone.
  const plain = buildTiming({...input, points: input.points.map(({dt, sold, ...p}) => p)});
  const withSales = new Map(expected.items.map(it => [it.id, it]));
  for (const item of plain.items) {
    const priced = withSales.get(item.id).cells.filter(c => c[1] > 0);
    assert.deepEqual(item.cells.map(c => c.slice(0, 6)), priced.map(c => c.slice(0, 6)), `item ${item.id}`);
    assert.ok(item.cells.every(c => c.slice(6).every(x => x === 0)));
  }
  assert.ok(!plain.items.some(it => it.id === 13446), "13446 has samples but no price reference");
  assert.deepEqual(withSales.get(13446).wd, []);
  assert.equal(withSales.get(13446).n, 0);
});

test("samples: midpoint cell, invalid dt or sold ignored, one per person and moment, the whale is the cell's largest", () => {
  const T = 2530, t = at(T, 21);                       // 21:00 in winter: the middle of a 2 h sample is 20:00
  // lo 0: no price point anywhere, so every cell below comes from the samples alone (a sample needs no price).
  const points = [
    {item_id: 7, person: 1, t, lo: 0, qty: 5, dt: 7200, sold: 30},
    {item_id: 7, person: 1, t, lo: 0, qty: 5, dt: 3600, sold: 90},            // same person and moment: the longer one stays
    {item_id: 7, person: 2, t: at(T, 9), lo: 0, qty: 5, dt: 1800, sold: 400},
    {item_id: 7, person: 3, t: at(T - 1, 9), lo: 0, qty: 5, dt: 1800, sold: 5},
    {item_id: 7, person: 4, t: at(T, 3), lo: 0, qty: 5, dt: 599, sold: 5},     // too short
    {item_id: 7, person: 4, t: at(T, 4), lo: 0, qty: 5, dt: 7201, sold: 5},    // too long
    {item_id: 7, person: 4, t: at(T, 5), lo: 0, qty: 5, dt: 1800, sold: -1},
    {item_id: 7, person: 4, t: at(T, 6), lo: 0, qty: 5, dt: 1800, sold: 1.5},
    {item_id: 7, person: 4, t: at(T, 7), lo: 0, qty: 5, dt: null, sold: null}
  ];
  const [item] = buildTiming({points, T}).items;
  assert.deepEqual([item.n, item.wd], [0, []], "only sales");
  const cells = new Map(item.cells.map(c => [c[0], c]));
  const evening = localSlot(at(T, 20)).cell, morning = localSlot(at(T, 9)).cell, yesterday = localSlot(at(T - 1, 9)).cell;
  assert.equal(localSlot(t - 3600).cell, evening);
  assert.deepEqual(cells.get(evening), [evening, 0, 0, 0, 0, 0, 30, 7200, 1, 1, 30, 7200]);
  assert.deepEqual(cells.get(morning), [morning, 0, 0, 0, 0, 0, 400, 1800, 1, 1, 400, 1800]);
  assert.deepEqual(cells.get(yesterday), [yesterday, 0, 0, 0, 0, 0, 5, 1800, 1, 1, 5, 1800]);
  assert.equal(item.cells.length, 3, "the invalid samples are not samples");
  assert.deepEqual([SALES.dtMin, SALES.dtMax, SALES.soldMax], [600, 7200, 1000000]);
  // Two days of one weekday in the same block: soldDays counts the days of the middles, the largest sample is kept apart.
  const twice = buildTiming({points: [
    {item_id: 8, person: 1, t: at(T, 22), lo: 0, qty: 1, dt: 3600, sold: 4},
    {item_id: 8, person: 1, t: at(T - 7, 22), lo: 0, qty: 1, dt: 3600, sold: 12},
    {item_id: 8, person: 2, t: at(T - 7, 23, 30), lo: 0, qty: 1, dt: 1800, sold: 12}], T}).items[0];
  assert.deepEqual(twice.cells.map(c => c.slice(6)), [[28, 9000, 3, 2, 12, 3600]], "ties on units: the longer sample is the largest");
  assert.equal(dayIndex(at(T, 22) - 1800), T);
});

test("two persons who measured the same purchases count once; half or less of the shorter interval is not the same", () => {
  const T = 2530, base = at(T, 20);
  const sample = (person, t, dt, sold) => ({item_id: 9, person, t, lo: 100, qty: 5, dt, sold});
  const sales = points => buildTiming({points, T}).items[0].cells.reduce((sum, c) => [sum[0] + c[6], sum[1] + c[8]], [0, 0]);
  assert.deepEqual(sales([sample(1, base, 3600, 10), sample(2, base + 60, 3600, 11)]), [11, 1], "same dt: the larger sold");
  assert.deepEqual(sales([sample(1, base, 1800, 30), sample(2, base + 300, 3600, 10)]), [10, 1], "the longer measurement wins");
  assert.deepEqual(sales([sample(1, base, 3600, 10), sample(2, base + 1800, 3600, 5)]), [15, 2], "exactly half: both stay");
  assert.deepEqual(sales([sample(1, base, 3600, 10), sample(2, base + 1799, 3600, 5)]), [10, 1], "a second more than half: one");
  assert.deepEqual(sales([sample(1, base, 3600, 10), sample(1, base + 600, 3600, 5)]), [15, 2], "the same person's samples never merge");
  assert.deepEqual(sales([sample(1, base, 7200, 10), sample(2, base + 7199, 7200, 5)]), [15, 2], "barely touching: both stay");
});

test("3000 samples of one item are merged without comparing every pair", () => {
  const T = 2530, points = [];
  for (let i = 0; i < 3000; i++) points.push({item_id: 1, person: 1 + (i % 9), t: at(T - 27, 0) + i * 800, lo: 100 + (i % 7), qty: 40, dt: 900 * (1 + (i % 8)), sold: i % 50});
  const start = performance.now(), out = buildTiming({points, T});
  const elapsed = performance.now() - start;
  assert.ok(elapsed < 200, `${elapsed.toFixed(1)} ms`);
  assert.ok(out.items[0].cells.reduce((sum, c) => sum + c[8], 0) > 0);
});

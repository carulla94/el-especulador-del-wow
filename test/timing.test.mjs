/** «Cuándo vender» (src/timing.mjs): weekday × time-of-day cells in Spanish time, against the item's own level. */
import test from "node:test";
import assert from "node:assert/strict";
import {buildTiming, localSlot, TIMING} from "../src/timing.mjs";
import {DAY0, weekdayOf} from "../src/especular.mjs";

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
    assert.deepEqual(cells.get(wd * 6 + 2), [wd * 6 + 2, 2, 2, -2000, 2, 2 * 10000], "morning, 2 points of 2 days, −10 % each, twice the usual quantity");
    assert.deepEqual(cells.get(wd * 6 + 3), [wd * 6 + 3, 2, 2, 0, 2, 0]);
    assert.deepEqual(cells.get(wd * 6 + 5), [wd * 6 + 5, 2, 2, 2000, 2, -2 * 5000]);
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

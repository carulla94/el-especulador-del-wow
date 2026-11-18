/** «Cuándo vender»: on which weekdays and at which times of day (Spanish time, the realm's) an item's lowest listing
 * usually sits above or below its own level that week. Pure and integer: no I/O, no clock, percentages in basis points
 * (10000 = 100 %).
 *
 * - Scan points: each person's scans (lowest price and quantity on sale at that moment) of the last TIMING.days days.
 *   A point is compared with the median of the item's points from three days before to three days after it (at least
 *   TIMING.minRef points), so a week that rises or falls does not paint one weekday. Same for the quantity on sale.
 * - Day values: the merged value of each day (guild_day_agg, which also holds the days imported from Auctionator),
 *   compared the same way with the days around it, for the weekday profile. Today is left out: it is not over.
 * - Each price ratio is clipped to ±TIMING.clipBp (quantities to ±TIMING.clipQtyBp), so one absurd listing cannot carry a
 *   cell.
 * Cells are weekday × block of TIMING.hours hours: cell = weekday * TIMING.blocks + block, Monday 0, block 0 = 0-4 h.
 * The output keeps sums and counts, which add up: the panel averages the items of a group, and the weekday or time of
 * day profiles, from them. */
import {dayIndex, weekdayOf, median, idiv} from "./especular.mjs";

export const TIMING = Object.freeze({days: 28, dayValues: 56, halfWindow: 3, minRef: 4, clipBp: 5000, clipQtyBp: 10000, hours: 4, blocks: 6,
  ttlSeconds: 2 * 3600, timeZone: "Europe/Madrid"});
export const TIMING_VERSION = "cuando-vender-1";
const WEEKDAY_CODES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

let clock = null;
const slots = new Map();
/** Weekday (Monday 0), hour and cell of a unix time in Spanish time. Cached per UTC hour (the offset only changes on the
 * hour), so a month of scans asks Intl a few hundred times. */
export function localSlot(t) {
  const key = Math.floor(t / 3600);
  let slot = slots.get(key);
  if (!slot) {
    clock ??= new Intl.DateTimeFormat("en-GB", {timeZone: TIMING.timeZone, weekday: "short", hour: "2-digit", hourCycle: "h23"});
    const parts = Object.fromEntries(clock.formatToParts(new Date(key * 3600 * 1000)).map(p => [p.type, p.value]));
    const wd = WEEKDAY_CODES.indexOf(parts.weekday), hour = Number(parts.hour) % 24, block = Math.floor(hour / TIMING.hours);
    slot = {wd, hour, block, cell: wd * TIMING.blocks + block};
    if (slots.size > 20000) slots.clear();
    slots.set(key, slot);
  }
  return slot;
}

const ratio = (value, ref, limit = TIMING.clipBp) => Math.max(-limit, Math.min(limit, idiv(value * 10000, ref) - 10000));
/** The values of the days from d - halfWindow to d + halfWindow of a Map day -> [values]. */
function around(byDay, d) {
  const out = [];
  for (let x = d - TIMING.halfWindow; x <= d + TIMING.halfWindow; x++) { const list = byDay.get(x); if (list) out.push(...list); }
  return out;
}

/** points: [{item_id, person, t, lo, qty}] (one row per observer slot; slots of one person at the same moment count once,
 * with the lowest price and the largest quantity). days: [{item_id, day, v}] of guild_day_agg. T: today's day index.
 * Returns {T, timeZone, hours, blocks, days, items: [{id, n, cells: [[cell, n, days, sumBp, nQty, sumQtyBp]], wd: [[weekday,
 * n, sumBp]]}]} with only the cells and weekdays that have data, items by id. nQty counts the points whose quantity could
 * be compared (the days around them had enough quantities). */
export function buildTiming({points = [], days = [], T}) {
  const items = new Map();
  const itemOf = id => { if (!items.has(id)) items.set(id, {points: new Map(), days: new Map()}); return items.get(id); };
  for (const p of points) {
    if (!Number.isInteger(p.lo) || p.lo < 1 || !Number.isInteger(p.qty) || p.qty < 0 || !Number.isInteger(p.t)) continue;
    const key = p.person + ":" + p.t, item = itemOf(p.item_id), prior = item.points.get(key);
    item.points.set(key, prior ? {t: p.t, lo: Math.min(prior.lo, p.lo), qty: Math.max(prior.qty, p.qty)} : {t: p.t, lo: p.lo, qty: p.qty});
  }
  for (const r of days) if (Number.isInteger(r.v) && r.v > 0 && Number.isInteger(r.day)) itemOf(r.item_id).days.set(r.day, r.v);
  const out = [];
  for (const [id, item] of [...items].sort((a, b) => a[0] - b[0])) {
    // Scan points against the points of the days around them.
    const lows = new Map(), qtys = new Map();
    for (const p of item.points.values()) {
      const d = dayIndex(p.t);
      if (!lows.has(d)) { lows.set(d, []); qtys.set(d, []); }
      lows.get(d).push(p.lo);
      if (p.qty > 0) qtys.get(d).push(p.qty);
    }
    const refs = new Map();
    for (const d of lows.keys()) {
      const lo = around(lows, d), qty = around(qtys, d);
      refs.set(d, {lo: lo.length >= TIMING.minRef ? median(lo) : null, qty: qty.length >= TIMING.minRef ? median(qty) : null});
    }
    const cells = new Map();
    let n = 0;
    for (const p of item.points.values()) {
      const d = dayIndex(p.t), ref = refs.get(d);
      if (!ref.lo) continue;
      const {cell} = localSlot(p.t);
      if (!cells.has(cell)) cells.set(cell, {n: 0, days: new Set(), sum: 0, sumQty: 0, nQty: 0});
      const c = cells.get(cell);
      c.n++; c.days.add(d); c.sum += ratio(p.lo, ref.lo); n++;
      if (ref.qty && p.qty > 0) { c.sumQty += ratio(p.qty, ref.qty, TIMING.clipQtyBp); c.nQty++; }
    }
    // Day values against the days around them (today is not over, so it is left out).
    const values = new Map([...item.days].filter(([d]) => d < T).map(([d, v]) => [d, [v]]));
    const wd = new Map();
    for (const [d, [v]] of values) {
      const near = around(values, d);
      if (near.length < TIMING.minRef) continue;
      const w = weekdayOf(d);
      if (!wd.has(w)) wd.set(w, {n: 0, sum: 0});
      wd.get(w).n++; wd.get(w).sum += ratio(v, median(near));
    }
    if (!n && !wd.size) continue;
    out.push({id, n,
      cells: [...cells].sort((a, b) => a[0] - b[0]).map(([cell, c]) => [cell, c.n, c.days.size, c.sum, c.nQty, c.sumQty]),
      wd: [...wd].sort((a, b) => a[0] - b[0]).map(([w, x]) => [w, x.n, x.sum])});
  }
  return {T, timeZone: TIMING.timeZone, hours: TIMING.hours, blocks: TIMING.blocks, days: TIMING.days, items: out};
}

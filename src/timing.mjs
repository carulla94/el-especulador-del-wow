/** «Cuándo vender»: on which weekdays and at which times of day (Spanish time, the realm's) an item's lowest listing
 * usually sits above or below its own level that week, and (since cuando-vender-2) how much of it sells then. Pure and
 * integer: no I/O, no clock, percentages in basis points (10000 = 100 %).
 *
 * - Scan points: each person's scans (lowest price and quantity on sale at that moment) of the last TIMING.days days.
 *   A point is compared with the median of the item's points from three days before to three days after it (at least
 *   TIMING.minRef points), so a week that rises or falls does not paint one weekday. Same for the quantity on sale.
 * - Day values: the merged value of each day (guild_day_agg, which also holds the days imported from Auctionator),
 *   compared the same way with the days around it, for the weekday profile. Today is left out: it is not over.
 * - Each price ratio is clipped to ±TIMING.clipBp (quantities to ±TIMING.clipQtyBp), so one absurd listing cannot carry a
 *   cell.
 * - Sales (addon 0.6.0): a point may carry a sell-through sample, the units that disappeared between two full scans of
 *   the same person in the interval (t - dt, t] (an estimate). One sample per person and moment; two persons measuring
 *   the same purchases count once (SALES.overlap); each kept sample goes to the cell of the middle of its interval.
 * Cells are weekday × block of TIMING.hours hours: cell = weekday * TIMING.blocks + block, Monday 0, block 0 = 0-4 h.
 * The output keeps sums and counts, which add up: the panel averages the items of a group, and the weekday or time of
 * day profiles, from them. */
import {dayIndex, weekdayOf, median, idiv} from "./especular.mjs";

export const TIMING = Object.freeze({days: 28, dayValues: 56, halfWindow: 3, minRef: 4, clipBp: 5000, clipQtyBp: 10000, hours: 4, blocks: 6,
  ttlSeconds: 2 * 3600, timeZone: "Europe/Madrid"});
export const TIMING_VERSION = "cuando-vender-2";
/** A sell-through sample counts when dt (seconds between the two scans) and sold (units) are integers in these ranges
 * (contract points-v2). Two samples of different persons are the same measurement when they overlap by more than
 * half of the shorter interval. */
export const SALES = Object.freeze({dtMin: 600, dtMax: 7200, soldMax: 1000000});
const WEEKDAY_CODES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

let clock = null;
const slots = new Map();
/** Weekday (Monday 0), hour and cell of a unix time in Spanish time, and shift: the seconds to add before dayIndex to get
 * the Spanish date (0 in winter; 3600 in summer, when 00:00-01:00 is already the next day). Cached per UTC hour (the
 * offset only changes on the hour), so a month of scans asks Intl a few hundred times. */
export function localSlot(t) {
  const key = Math.floor(t / 3600);
  let slot = slots.get(key);
  if (!slot) {
    clock ??= new Intl.DateTimeFormat("en-GB", {timeZone: TIMING.timeZone, weekday: "short", hour: "2-digit", hourCycle: "h23"});
    const parts = Object.fromEntries(clock.formatToParts(new Date(key * 3600 * 1000)).map(p => [p.type, p.value]));
    const wd = WEEKDAY_CODES.indexOf(parts.weekday), hour = Number(parts.hour) % 24, block = Math.floor(hour / TIMING.hours);
    const offset = (((hour - key % 24) % 24) + 24) % 24; // hours ahead of UTC: 1 (CET) or 2 (CEST)
    slot = {wd, hour, block, cell: wd * TIMING.blocks + block, shift: (offset - 1) * 3600};
    if (slots.size > 20000) slots.clear();
    slots.set(key, slot);
  }
  return slot;
}
/** The Spanish date of a unix time, numbered like dayIndex (the same day in winter). The seven weekday cells of a block
 * then split the days exactly, as the addon counts them (Spec.MadridSlot). */
export const localDay = t => dayIndex(t + localSlot(t).shift);

const ratio = (value, ref, limit = TIMING.clipBp) => Math.max(-limit, Math.min(limit, idiv(value * 10000, ref) - 10000));
/** The values of the days from d - halfWindow to d + halfWindow of a Map day -> [values]. */
function around(byDay, d) {
  const out = [];
  for (let x = d - TIMING.halfWindow; x <= d + TIMING.halfWindow; x++) { const list = byDay.get(x); if (list) out.push(...list); }
  return out;
}

const isSample = p => Number.isInteger(p.dt) && p.dt >= SALES.dtMin && p.dt <= SALES.dtMax
  && Number.isInteger(p.sold) && p.sold >= 0 && p.sold <= SALES.soldMax && Number.isInteger(p.t);
const overlap = (a, b) => Math.min(a.t, b.t) - Math.max(a.t - a.dt, b.t - b.dt);
/** The samples of one item that count: sorted by dt descending, sold descending, t ascending, person ascending, a
 * sample is left out when it overlaps a sample already kept from another person by more than half of the shorter
 * interval (the larger dt wins). Kept samples are bucketed per hour of t: two samples can only overlap when their t
 * are less than SALES.dtMax apart, so each sample looks at five buckets, never at every other sample. */
function keptSamples(list) {
  list.sort((a, b) => b.dt - a.dt || b.sold - a.sold || a.t - b.t || a.person - b.person);
  const buckets = new Map(), kept = [], reach = Math.ceil(SALES.dtMax / 3600);
  for (const s of list) {
    const hour = Math.floor(s.t / 3600);
    let duplicate = false;
    for (let h = hour - reach; h <= hour + reach && !duplicate; h++) {
      for (const k of buckets.get(h) ?? []) {
        if (k.person !== s.person && overlap(k, s) * 2 > Math.min(k.dt, s.dt)) { duplicate = true; break; }
      }
    }
    if (duplicate) continue;
    kept.push(s);
    if (!buckets.has(hour)) buckets.set(hour, []);
    buckets.get(hour).push(s);
  }
  return kept;
}

/** points: [{item_id, person, t, lo, qty, dt?, sold?}] (one row per observer slot; slots of one person at the same
 * moment count once, with the lowest price and the largest quantity, and the sample with the larger dt, then the larger
 * sold). days: [{item_id, day, v}] of guild_day_agg. T: today's day index.
 * Returns {T, timeZone, hours, blocks, days, items: [{id, n, cells: [[cell, n, days, sumBp, nQty, sumQtyBp, soldUnits,
 * soldSeconds, soldN, soldDays, maxUnits, maxSeconds]], wd: [[weekday, n, sumBp]]}]} with only the cells and weekdays
 * that have data, items by id. nQty counts the points whose quantity could be compared (the days around them had
 * enough quantities). The sales columns: units and seconds measured by the kept samples whose middle falls in the
 * cell, how many samples, on how many distinct Spanish dates (localDay of their middle), and the sample with the most
 * units (ties: the longer one), so the advice can leave it out. A cell can have sales and no price point (n = 0), and an
 * item with only samples is listed with n = 0 and wd = []. */
export function buildTiming({points = [], days = [], T}) {
  const items = new Map();
  const itemOf = id => {
    if (!items.has(id)) items.set(id, {points: new Map(), days: new Map(), samples: new Map()});
    return items.get(id);
  };
  for (const p of points) {
    if (isSample(p)) {
      const key = p.person + ":" + p.t, samples = itemOf(p.item_id).samples, prior = samples.get(key);
      if (!prior || p.dt > prior.dt || (p.dt === prior.dt && p.sold > prior.sold)) samples.set(key, {person: p.person, t: p.t, dt: p.dt, sold: p.sold});
    }
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
    const cellOf = cell => {
      if (!cells.has(cell)) cells.set(cell, {n: 0, days: new Set(), sum: 0, sumQty: 0, nQty: 0, units: 0, seconds: 0, sold: 0, soldDays: new Set(), maxUnits: 0, maxSeconds: 0});
      return cells.get(cell);
    };
    let n = 0;
    for (const p of item.points.values()) {
      const d = dayIndex(p.t), ref = refs.get(d);
      if (!ref.lo) continue;
      const c = cellOf(localSlot(p.t).cell);
      c.n++; c.days.add(d); c.sum += ratio(p.lo, ref.lo); n++;
      if (ref.qty && p.qty > 0) { c.sumQty += ratio(p.qty, ref.qty, TIMING.clipQtyBp); c.nQty++; }
    }
    // Sales: each kept sample in the cell of the middle of its interval, with or without a price reference.
    for (const s of keptSamples([...item.samples.values()])) {
      const mid = s.t - Math.floor(s.dt / 2), slot = localSlot(mid), c = cellOf(slot.cell);
      c.units += s.sold; c.seconds += s.dt; c.sold++; c.soldDays.add(dayIndex(mid + slot.shift));
      if (c.sold === 1 || s.sold > c.maxUnits || (s.sold === c.maxUnits && s.dt > c.maxSeconds)) { c.maxUnits = s.sold; c.maxSeconds = s.dt; }
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
    if (!n && !wd.size && !item.samples.size) continue;
    out.push({id, n,
      cells: [...cells].sort((a, b) => a[0] - b[0]).map(([cell, c]) => [cell, c.n, c.days.size, c.sum, c.nQty, c.sumQty,
        c.units, c.seconds, c.sold, c.soldDays.size, c.maxUnits, c.maxSeconds]),
      wd: [...wd].sort((a, b) => a[0] - b[0]).map(([w, x]) => [w, x.n, x.sum])});
  }
  return {T, timeZone: TIMING.timeZone, hours: TIMING.hours, blocks: TIMING.blocks, days: TIMING.days, items: out};
}

/** Especular v1: pure, integer-copper rules for the guild market panel (dumps, spikes, resale, balances).
 * Twin of addon/OroHermandad/Spec.lua in the Oro de Hermandad addon: both must return exactly the same integers
 * and texts, and the contract is test-vectors/especular-v1.json (never edited; a rule change becomes v2).
 * Money is integer copper; percentages are basis points (bp, 10000 = 100 %). No I/O, clock or randomness.
 * weekday() is cloud-only and has no Lua twin. */
export const VERSION = "especular-v1";
export const DAY0 = 1577833200;        // 2020-01-01 00:00 CET, day 0 (Auctionator counts days from local midnight)
export const LAUNCH = 2499;            // 2026-11-04, a Wednesday
export const GUARD_DAYS = 14;          // no dumps flagged before day 2513 (2026-11-18)
export const WINDOW = 14;              // days of the normal-price window (today excluded)
export const MIN_DAYS = 7;
export const PRICE_MAX = 1000000000, QTY_MAX = 1000000, UNITS_MAX = 10000, DAY_MAX = 99999, TIME_MAX = 9999999999;
export const SBP_FLOOR = 300;          // robust sigma floor: 3 %
export const CUT_BP = 500;             // default auction house cut: 5 %
export const UNDERCUT = 1;             // 1 c, or 100 c where the auction house has no copper
export const FAILED_LISTINGS = 1;      // listings expected to expire (their deposit is lost)
export const BUDGET = 1000000;         // 100 g; a single item may use 25 % of it
export const MIN_PROFIT = 10000;       // 1 g per batch
export const MIN_MARGIN_PCT = 15;      // profit over what was put in (cost + deposits)
export const CAP_LIQ_DEFAULT = 20;     // unit cap when the usual supply is unknown
export const CATEGORIES = Object.freeze(["metal", "piedra", "gema", "hierba", "piel", "tela", "pocion", "elixir", "frasco",
  "comida", "venda", "encantar", "elemental", "otro"]);
export function isCategory(key) { return CATEGORIES.includes(key); }

// ---- Lua semantics the twin relies on: nil is undefined or null, false and nil are the only falsy values.
const isNil = value => value === undefined || value === null;
const truthy = value => !isNil(value) && value !== false;
const or = (value, fallback) => truthy(value) ? value : fallback;
const isTable = value => value !== null && typeof value === "object";
// ipairs(): the array prefix before the first nil; anything that is not an array yields nothing.
function seq(value) {
  const out = [];
  if (Array.isArray(value)) for (const item of value) { if (isNil(item)) break; out.push(item); }
  return out;
}
// tostring() of an id. Equal to Lua for strings and for integers below 1e14; member ids are strings.
const idText = value => String(value);

// ---- Integer arithmetic. With the ranges above every value stays below 2^53, and these asserts prove it.
function safe(value) {
  if (!Number.isSafeInteger(value)) throw new RangeError(`Especular: ${value} no es un entero exacto.`);
  return value;
}
export function isInt(x, lo, hi) { return typeof x === "number" && Number.isInteger(x) && x >= lo && x <= hi; }
const isPrice = x => isInt(x, 1, PRICE_MAX);
export function idiv(a, b) { return safe(Math.floor(safe(a) / safe(b))); }
export function ceilDiv(a, b) { return idiv(a + b - 1, b); }
const sorted = xs => [...xs].sort((a, b) => a - b);
/** Median; with an even count idiv(a+b, 2), rounded down like engine.mjs. null for no values. */
export function median(xs) {
  const n = xs.length;
  if (!n) return null;
  const s = sorted(xs), m = Math.floor(n / 2);
  return n % 2 ? s[m] : idiv(s[m - 1] + s[m], 2);
}
/** Quantile without interpolation: sorted[idiv((n-1)*num, den)], counted from 0. */
export function quantile(xs, num, den) {
  if (!xs.length) return null;
  return sorted(xs)[idiv((xs.length - 1) * num, den)];
}

// ---- Days
/** Day index of a unix time in seconds, or null when t is not an integer. */
export function dayIndex(t) {
  if (!isInt(t, -TIME_MAX, TIME_MAX)) return null;
  return idiv(t - DAY0, 86400);
}
/** Weekday of a day index: Monday 0 ... Sunday 6 (day 2499 is a Wednesday, 2). */
export function weekdayOf(d) { return ((d + 2) % 7 + 7) % 7; }

const validDay = r => isTable(r) && isInt(r.d, 0, DAY_MAX) && isPrice(r.lo) && isPrice(r.hi) && r.lo <= r.hi
  && isPrice(r.last) && isInt(r.qty, 0, QTY_MAX) && isInt(r.scans, 0, QTY_MAX) && (r.src === "o" || r.src === "a");
const copyDay = r => ({d: r.d, lo: r.lo, hi: r.hi, last: r.last, qty: r.qty, scans: r.scans, src: r.src});

/** Merges two records {d, lo, hi, last, qty, scans, src} of one observer and one day. Idempotent, commutative and
 * associative: an own record ("o") beats an Auctionator import ("a") outright; between records of the same source
 * lo = min, hi = max, qty = max, scans = max, and last comes from the record with more scans (ties: larger last).
 * null when the days differ. */
export function mergeDay(a, b) {
  if (!truthy(a)) return truthy(b) ? copyDay(b) : null;
  if (!truthy(b)) return copyDay(a);
  if (a.d !== b.d) return null;
  if (a.src !== b.src) return copyDay(a.src === "o" ? a : b);
  const newer = b.scans > a.scans || (b.scans === a.scans && b.last > a.last) ? b : a;
  return {d: a.d, lo: Math.min(a.lo, b.lo), hi: Math.max(a.hi, b.hi), last: newer.last, qty: Math.max(a.qty, b.qty),
    scans: Math.max(a.scans, b.scans), src: a.src};
}

// ---- Day value across observers
const bounds = list => list.flatMap(o => [o.lo, o.hi]);
/** observers: [{lo, hi, qty, id}]. v = median of the {lo, hi} multiset. With 3 or more observers, those whose
 * idiv(lo+hi, 2) falls outside [idiv(v, 2), 2v] are dropped and v is computed again once (if all would go, all
 * stay). qty = median of the remaining qty > 0. Returns {v, qty, obs, ids} or null. */
export function dayValue(observers) {
  const valid = seq(observers).filter(o => isTable(o) && isPrice(o.lo) && isPrice(o.hi) && o.lo <= o.hi);
  if (!valid.length) return null;
  let v = median(bounds(valid)), kept = valid;
  if (valid.length >= 3) {
    const low = idiv(v, 2), high = 2 * v;
    const inside = valid.filter(o => { const mid = idiv(o.lo + o.hi, 2); return mid >= low && mid <= high; });
    if (inside.length > 0 && inside.length < valid.length) { kept = inside; v = median(bounds(kept)); }
  }
  const qtys = kept.filter(o => isInt(o.qty, 1, QTY_MAX)).map(o => o.qty);
  return {v, qty: median(qtys), obs: kept.length, ids: kept.map(o => isNil(o.id) ? "" : idText(o.id))};
}

// A day key: a number from a Map, or a canonical decimal string (no sign, no leading zeros) from an object.
function dayKey(key) {
  if (typeof key === "number") return key;
  return typeof key === "string" && /^(0|[1-9][0-9]{0,4})$/.test(key) ? Number(key) : null;
}
const entries = byDay => byDay instanceof Map ? [...byDay.entries()] : isTable(byDay) ? Object.entries(byDay) : [];

/** byDay: {day: [{lo, hi, qty, id, src, last?, scans?}, ...]} (an object or a Map) with the records of several
 * observers. Records of one observer are merged with mergeDay (own beats imported), then dayValue runs over the
 * observers. Keys that are not days 0..99999 and invalid records are ignored. Returns {day: dayValue}. */
export function buildDays(byDay) {
  const out = {};
  for (const [key, records] of entries(byDay)) {
    const d = dayKey(key);
    if (!isInt(d, 0, DAY_MAX) || !isTable(records)) continue;
    const perId = new Map();
    for (const r of seq(records)) {
      if (!isTable(r)) continue;
      const rec = {d, lo: r.lo, hi: r.hi, last: isPrice(r.last) ? r.last : r.lo, qty: isNil(r.qty) ? 0 : r.qty,
        scans: isInt(r.scans, 0, QTY_MAX) ? r.scans : 0, src: isNil(r.src) ? "o" : r.src};
      if (!validDay(rec)) continue;
      const id = isNil(r.id) ? "" : idText(r.id);
      perId.set(id, mergeDay(perId.get(id), rec));
    }
    const value = dayValue([...perId].map(([id, m]) => ({lo: m.lo, hi: m.hi, qty: m.qty, id})));
    if (value) out[d] = value;
  }
  return out;
}

// ---- Normal price on day T (T itself excluded)
const at = (days, d) => days instanceof Map ? days.get(d) : isTable(days) ? days[d] : undefined;
function valueOf(days, d) {
  const x = at(days, d), v = isTable(x) ? x.v : x;
  return isPrice(v) ? v : null;
}
function valuesIn(days, from, to) {
  const out = [];
  for (let d = from; d <= to; d++) { const v = valueOf(days, d); if (v !== null) out.push(v); }
  return out;
}

/** days: {day: dayValue} or {day: price} (an object or a Map with number keys). opts.cloud: ALTA also needs two
 * distinct members in the window. Returns {T, n, k, maxDay, fresh, prev1, prev2, status, N, MAD, sBp, R3, O7, trend,
 * trendBp, conf, Rs, Q}; with n < 7 status is SIN_DATOS and N and everything after it is null. */
export function baseline(days, T, opts) {
  opts = isTable(opts) ? opts : {};
  const b = {T: T ?? null, n: 0, k: 0, maxDay: null, fresh: false, prev1: null, prev2: null, status: "SIN_DATOS", N: null,
    MAD: null, sBp: null, R3: null, O7: null, trend: null, trendBp: null, conf: null, Rs: null, Q: null};
  if (!isInt(T, 0, DAY_MAX)) return b;
  const vals = [], qtys = [], ids = new Set();
  for (let d = T - WINDOW; d <= T - 1; d++) {
    const v = valueOf(days, d);
    if (v === null) continue;
    vals.push(v);
    b.maxDay = d;
    const x = at(days, d);
    for (const id of seq(isTable(x) && isTable(x.ids) ? x.ids : [""])) ids.add(idText(id));
    if (isTable(x) && isInt(x.qty, 0, QTY_MAX)) qtys.push(x.qty);
  }
  b.n = vals.length; b.k = ids.size;
  b.fresh = b.maxDay !== null && b.maxDay >= T - 2;
  b.prev1 = valueOf(days, T - 1); b.prev2 = valueOf(days, T - 2);
  if (b.n < MIN_DAYS) return b;

  const N = median(vals);
  b.N = N; b.MAD = median(vals.map(v => Math.abs(v - N)));
  b.sBp = Math.max(SBP_FLOOR, idiv(b.MAD * 14826, N));
  const r3 = valuesIn(days, T - 3, T - 1), o7 = valuesIn(days, T - 10, T - 4);
  b.R3 = r3.length >= 2 ? median(r3) : null;
  b.O7 = o7.length >= 2 ? median(o7) : null;
  b.trend = "desconocida";
  if (b.R3 !== null && b.O7 !== null) {
    b.trendBp = idiv(b.R3 * 10000, b.O7) - 10000;
    b.trend = b.R3 * 10 < b.O7 * 9 ? "bajando" : b.R3 * 100 > b.O7 * 115 ? "subiendo" : "estable";
  }
  if (b.n >= 12 && b.sBp <= 1500 && b.maxDay >= T - 1 && (!truthy(opts.cloud) || b.k >= 2)) b.conf = "ALTA";
  else if (b.n >= 10 && b.sBp <= 2500 && b.fresh) b.conf = "MEDIA";
  else b.conf = "BAJA";
  b.Rs = quantile(vals, 2, 5);
  if (b.R3 !== null) b.Rs = Math.min(b.Rs, b.R3);
  b.Q = median(qtys);
  b.status = b.trend === "estable" ? "OK" : "INESTABLE";
  return b;
}

// ---- Verdict for the current price p
/** Returns {verdict, guard, wait, dBp, band, dumpLine, spikeLine, shiftLine, trend}. Verdicts, in order: SIN_DATOS,
 * INESTABLE, SIN_PRECIO (p null), FUERA_DE_RANGO, BAJADA, CHOLLO (PROTECCION before day 2513), CARO, ESPERA,
 * NORMAL. guard: launch protection is on. wait: the "si no tienes prisa, espera" note for sell rows.
 * T defaults to baseline.T; opts.launch moves the launch day (tests). */
export function assess(base, p, T, opts) {
  opts = isTable(opts) ? opts : {};
  if (!truthy(T)) T = isTable(base) ? base.T ?? null : null;
  const launch = or(opts.launch, LAUNCH);
  const a = {verdict: "SIN_DATOS", guard: isInt(T, 0, DAY_MAX) && T < safe(launch + GUARD_DAYS), wait: false, dBp: null,
    band: null, dumpLine: null, spikeLine: null, shiftLine: null, trend: isTable(base) ? base.trend ?? null : null};
  if (!isTable(base) || or(base.n, 0) < MIN_DAYS || !isPrice(base.N) || !isInt(base.sBp, 0, PRICE_MAX)) return a;
  const N = base.N;
  a.band = ceilDiv(N * 25 * Math.min(base.sBp, 10000), 100000);
  a.dumpLine = Math.min(idiv(N * 4, 5), N - a.band);
  a.spikeLine = Math.max(ceilDiv(N * 5, 4), N + a.band);
  a.shiftLine = idiv(N * 85, 100);
  const low = idiv(N * 4, 5);
  if (isPrice(p)) a.dBp = idiv(p * 10000, N) - 10000;
  if (base.trend !== "estable") return {...a, verdict: "INESTABLE"};
  if (isNil(p)) return {...a, verdict: "SIN_PRECIO"};
  if (!isPrice(p)) return {...a, verdict: "FUERA_DE_RANGO"};
  a.wait = p <= low;
  const {prev1, prev2} = base;
  if (truthy(prev1) && truthy(prev2) && prev1 < a.shiftLine && prev2 < a.shiftLine) return {...a, verdict: "BAJADA"};
  const trusted = base.conf === "ALTA" || base.conf === "MEDIA";
  if (p <= a.dumpLine && trusted && truthy(base.fresh)) a.verdict = a.guard ? "PROTECCION" : "CHOLLO";
  else if (p >= a.spikeLine && trusted) a.verdict = "CARO";
  else if (p <= low) a.verdict = "ESPERA";
  else a.verdict = "NORMAL";
  return a;
}

// ---- Buy to resell
/** book: lots [[price, qty], ...] (or [{price, qty}]), sorted by price here. A null book becomes the estimated
 * [[opts.p, opts.q5 or 1]]. opts: cutBp, u, D (null = estimated from opts.vendor), vendor, F, budget, Q
 * (null = baseline Q), p, q5. Returns {units, cost, profit, maxBuy, breakEven, netUnit, risk, D, F, Rs,
 * depositEstimated, bookEstimated, avgIn, capLiq, capBudget, accept, reason}; reason is null when accepted,
 * otherwise FUERA_DE_RANGO, SIN_BASE, SIN_MARGEN, SIN_UNIDADES, POCA_GANANCIA or MARGEN_BAJO. */
export function flip(base, book, opts) {
  opts = isTable(opts) ? opts : {};
  const r = {units: 0, cost: 0, profit: 0, maxBuy: null, breakEven: null, netUnit: null, risk: null, D: null, F: null,
    Rs: null, depositEstimated: false, bookEstimated: false, avgIn: null, capLiq: null, capBudget: null, accept: false,
    reason: null};
  let ok = true;
  const option = (value, lo, hi, fallback) => {
    if (isNil(value)) return fallback;
    if (!isInt(value, lo, hi)) ok = false;
    return value;
  };
  const cutBp = option(opts.cutBp, 0, 9999, CUT_BP);
  const u = option(opts.u, 1, 10000, UNDERCUT);
  let D = option(opts.D, 0, PRICE_MAX, null);
  const vendor = option(opts.vendor, 0, PRICE_MAX, 0);
  const F = option(opts.F, 0, 100, FAILED_LISTINGS);
  const budget = option(opts.budget, 0, 100000000000, BUDGET);
  let Q = option(opts.Q, 0, QTY_MAX, null);
  const p = option(opts.p, 1, PRICE_MAX, null);
  const q5 = option(opts.q5, 0, QTY_MAX, null);
  let lots = [];
  if (!isNil(book)) {
    if (!isTable(book)) ok = false;
    else for (const lot of seq(book)) {
      const price = isTable(lot) && or(lot[0], lot.price), qty = isTable(lot) && or(lot[1], lot.qty);
      if (isPrice(price) && isInt(qty, 0, QTY_MAX)) lots.push([price, qty]); else ok = false;
    }
  }
  if (!ok) return {...r, reason: "FUERA_DE_RANGO"};
  if (!isTable(base) || !isPrice(base.Rs)) return {...r, reason: "SIN_BASE"};

  if (D === null) { D = ceilDiv(vendor * 6000, 10000); r.depositEstimated = true; }
  r.D = D; r.F = F; r.Rs = base.Rs;
  r.netUnit = idiv((base.Rs - u) * (10000 - cutBp), 10000);
  r.risk = safe(D * F);
  r.maxBuy = idiv((r.netUnit - r.risk) * 100, 115);
  if (Q === null && isInt(base.Q, 0, QTY_MAX)) Q = base.Q;
  r.capLiq = Q !== null ? Math.max(1, idiv(Q * 25, 100)) : CAP_LIQ_DEFAULT;
  r.capBudget = idiv(budget * 25, 100);
  if (r.maxBuy <= 0) return {...r, reason: "SIN_MARGEN"};

  if (isNil(book) && p !== null) { lots = [[p, q5 !== null && q5 >= 1 ? q5 : 1]]; r.bookEstimated = true; }
  lots.sort((x, y) => x[0] - y[0]);
  const cap = Math.min(r.capLiq, UNITS_MAX);
  let n = 0, cost = 0;
  for (const [price, qty] of lots) {                // per lot, not per unit: a lot of 1e6 units is instant
    if (price > r.maxBuy || n >= cap) break;
    const take = Math.min(qty, cap - n, Math.max(0, idiv(r.capBudget - cost, price)));
    n += take; cost = safe(cost + take * price);
  }
  if (n === 0) return {...r, reason: "SIN_UNIDADES"};
  r.units = n; r.cost = cost;
  const spent = safe(cost + n * r.risk);
  r.profit = safe(n * r.netUnit - spent);
  r.avgIn = ceilDiv(spent, n);
  r.breakEven = ceilDiv(r.avgIn * 10000, 10000 - cutBp) + u;
  r.accept = r.profit >= MIN_PROFIT && safe(r.profit * 100) >= safe(MIN_MARGIN_PCT * spent);
  if (!r.accept) r.reason = r.profit < MIN_PROFIT ? "POCA_GANANCIA" : "MARGEN_BAJO";
  return r;
}

// ---- Balances
/** Δ1d and Δ7d in bp; each is null without enough data (Δ7d needs 4 values on each side). */
export function deltas(days, T) {
  const out = {d1: null, d7: null};
  if (!isInt(T, 0, DAY_MAX)) return out;
  const today = valueOf(days, T), yesterday = valueOf(days, T - 1);
  if (today !== null && yesterday !== null) out.d1 = idiv(today * 10000, yesterday) - 10000;
  const recent = valuesIn(days, T - 6, T), before = valuesIn(days, T - 13, T - 7);
  if (recent.length >= 4 && before.length >= 4) out.d7 = idiv(median(recent) * 10000, median(before)) - 10000;
  return out;
}

// ---- Weekday pattern (cloud only, never in game)
function dayList(days) {
  const out = [];
  for (const [key] of entries(days)) { const d = dayKey(key); if (isInt(d, 0, DAY_MAX) && valueOf(days, d) !== null) out.push(d); }
  return out;
}
/** Day-of-week effect over the days after the trend gate first passed (the first day G after the first value where
 * baseline(days, G) has n >= 7 and a stable trend); uses days G..T-1. Weeks w = idiv(d+2, 7) with at least 5 values;
 * r = idiv(v*10000, week median); e[wd] = median of r - 10000 (wd: Monday 0). shown ("patrón probable") needs every
 * weekday in at least 4 weeks, spread >= 800 bp, the cheapest weekday below its week in 75 % of its weeks, and
 * opts.watch (default true: the caller passes false for items outside the fixed watchlist). */
export function weekday(days, T, opts) {
  opts = isTable(opts) ? opts : {};
  const out = {shown: false, gate: null, weeks: 0, counts: [0, 0, 0, 0, 0, 0, 0], e: [null, null, null, null, null, null, null],
    cheapest: null, dearest: null, spread: null, cheapHits: 0, missingWeeks: 4};
  const list = dayList(days);
  if (!isInt(T, 0, DAY_MAX) || !list.length) return out;
  const first = Math.min(...list);
  for (let G = first + 1; G <= T; G++) {
    const b = baseline(days, G);
    if (b.n >= MIN_DAYS && b.trend === "estable") { out.gate = G; break; }
  }
  if (out.gate === null) return out;
  const weeks = new Map();
  for (let d = out.gate; d <= T - 1; d++) {
    const v = valueOf(days, d);
    if (v === null) continue;
    const w = idiv(d + 2, 7);
    if (!weeks.has(w)) weeks.set(w, []);
    weeks.get(w).push([d, v]);
  }
  const ratios = [[], [], [], [], [], [], []];
  for (const w of sorted([...weeks.keys()])) {
    const week = weeks.get(w);
    if (week.length < 5) continue;
    out.weeks++;
    const m = median(week.map(([, v]) => v));
    for (const [d, v] of week) ratios[weekdayOf(d)].push(idiv(v * 10000, m));
  }
  for (let wd = 0; wd < 7; wd++) {
    out.counts[wd] = ratios[wd].length;
    if (ratios[wd].length) out.e[wd] = median(ratios[wd]) - 10000;
  }
  for (let wd = 0; wd < 7; wd++) {
    if (out.e[wd] === null) continue;
    if (out.cheapest === null || out.e[wd] < out.e[out.cheapest]) out.cheapest = wd;
    if (out.dearest === null || out.e[wd] > out.e[out.dearest]) out.dearest = wd;
  }
  if (out.cheapest !== null) {
    out.spread = out.e[out.dearest] - out.e[out.cheapest];
    out.cheapHits = ratios[out.cheapest].filter(r => r < 10000).length;
  }
  out.missingWeeks = Math.max(0, 4 - Math.min(...out.counts));
  const watch = isNil(opts.watch) ? true : opts.watch === true;
  out.shown = watch && out.counts.every(c => c >= 4) && out.spread !== null && out.spread >= 800
    && out.cheapHits * 100 >= 75 * out.counts[out.cheapest];
  return out;
}

// ---- Texts (the same strings as the addon; confidence and verdict texts are part of the contract)
/** Copper as "1o 23p", "45p 6c" or "7c", like the addon's Engine.Money. */
export function money(copper) {
  copper = Math.floor(or(copper, 0) + 0.5);
  const sign = copper < 0 ? "-" : "";
  copper = Math.abs(copper);
  const g = Math.floor(copper / 10000), s = Math.floor((copper % 10000) / 100), c = copper % 100;
  if (g > 0) return `${sign}${g}o${s > 0 ? ` ${s}p` : ""}`;
  if (s > 0) return `${sign}${s}p${c > 0 ? ` ${c}c` : ""}`;
  return `${sign}${c}c`;
}

const CAVEAT = "el precio mínimo publicado no es una venta confirmada";
const GUARD = "Protección de lanzamiento: sin compras especulativas hasta el 18-nov";
/** Percentage from bp, unsigned, at most one decimal with a decimal comma: 300 -> "3", 1234 -> "12,3". */
function pct(bp) {
  const tenths = idiv(Math.abs(bp) + 5, 10), whole = idiv(tenths, 10), decimal = tenths % 10;
  return decimal === 0 ? String(whole) : `${whole},${decimal}`;
}
function signedPct(bp) {
  const text = pct(bp);
  return text === "0" ? text : (bp < 0 ? "-" : "+") + text;
}
const dayCount = n => n === 1 ? "1 día" : `${n} días`;
const learning = n => `Aprendiendo precios: ${or(n, 0)} de 7 días`;
function conf(base) {
  if (!isTable(base) || or(base.n, 0) < MIN_DAYS || !truthy(base.conf)) return learning(isTable(base) ? base.n : 0);
  const spread = ` · variación ±${pct(base.sBp)} %`;
  if (base.conf === "ALTA") return `Fiable · ${dayCount(base.n)}${spread}${or(base.k, 0) >= 2 ? ` · ${base.k} miembros` : ""}`;
  if (base.conf === "MEDIA") return `Orientativo · ${dayCount(base.n)}${spread}`;
  return "Poco fiable: pocos datos o precio muy variable";
}
function status(assessment, base) {
  const verdict = isTable(assessment) ? or(assessment.verdict, "SIN_DATOS") : "SIN_DATOS";
  const dBp = isTable(assessment) ? or(assessment.dBp, 0) : 0;
  switch (verdict) {
    case "SIN_DATOS": return learning(isTable(base) ? base.n : 0);
    case "INESTABLE": {
      const trend = isTable(base) ? base.trend : null;
      if (trend === "bajando") return `Mercado bajando (${signedPct(base.trendBp)} % en una semana): vende pronto, no compres para revender`;
      if (trend === "subiendo") return "Mercado subiendo: aún no hay precio normal";
      return "Tendencia desconocida: faltan precios de algunos días";
    }
    case "SIN_PRECIO": return "Sin precio actual: escanea la subasta";
    case "FUERA_DE_RANGO": return "Precio fuera de rango";
    case "BAJADA": return "Bajada de nivel: dos días por debajo de lo normal; no es un chollo";
    case "PROTECCION": return GUARD;
    case "CHOLLO": return `Chollo: ${pct(dBp)} % por debajo de lo normal`;
    case "CARO": return `Precio alto: ${pct(dBp)} % por encima de lo normal`;
    case "ESPERA": return `Precio bajo (${pct(dBp)} % por debajo de lo normal): si no tienes prisa, espera`;
    default: return "Precio normal";
  }
}
/** The buy sentence, or why it does not pay. format: copper formatter (default money()). */
function flipText(result, format) {
  if (isNil(format)) format = money;
  if (!isTable(result)) return "Sin precio normal: no se calcula la compra";
  const F = or(result.F, 0);
  if (truthy(result.accept)) {
    const losses = F === 1 ? " y un depósito perdido" : F >= 2 ? ` y ${F} depósitos perdidos` : "";
    let text = `Compra ${result.units}× a ${format(result.maxBuy)} como máximo; no revendas por debajo de ${format(result.breakEven)}; `
      + `objetivo ${format(result.Rs)}; ganancia ≈ ${format(result.profit)} tras la comisión${losses}`;
    if (truthy(result.depositEstimated) && F > 0) text += " (depósito estimado)";
    if (truthy(result.bookEstimated)) text += " · estimado: confirma en la subasta";
    return text;
  }
  switch (result.reason) {
    case "FUERA_DE_RANGO": return "Datos fuera de rango: no se calcula la compra";
    case "SIN_MARGEN": return "No compensa: la comisión y el depósito se comen el margen";
    case "SIN_UNIDADES": return `No compensa: no hay nada a la venta por debajo de ${format(result.maxBuy)}`;
    // With lots at maxBuy or less the profit is always positive (each unit keeps at least 15 % of its price).
    case "POCA_GANANCIA": return `No compensa: ganarías solo ${format(result.profit)} (menos de 1 oro)`;
    case "MARGEN_BAJO": return `No compensa: ganarías ${format(result.profit)}, menos del ${MIN_MARGIN_PCT} % de lo invertido`;
    default: return "Sin precio normal: no se calcula la compra";
  }
}
/** Spanish texts, named like Spec.Texts in the addon (Pct -> pct, SignedPct -> signedPct, Days -> days, ...). */
export const texts = Object.freeze({CAVEAT, GUARD, pct, signedPct, days: dayCount, learning, conf, status, flip: flipText});

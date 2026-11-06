/** Panel de la hermandad (/hermandad): the merged market of every guild mate's uploads, outside the game.
 *
 * Plain ES module with no dependencies and no external requests (CSP script-src and connect-src 'self'). The market
 * rules are not re-implemented here: they come from /especular.js, a byte-for-byte copy of src/especular.mjs (the JS
 * twin of the addon's Spec.lua) made by scripts/prepare-downloads.mjs, injected with setEspecular().
 *
 * The pure builders at the top (money as g/s/c, percentages, dates, filters, SVG charts as node trees, CSV) are
 * exported for test/hermandad-view.test.mjs. The page code at the bottom only runs in a browser. Item names and member
 * labels are untrusted input: they only reach the DOM through textContent, and charts are built with createElementNS,
 * never innerHTML. Money is integer copper everywhere. */

const SVG_NS = "http://www.w3.org/2000/svg";
const MONTHS = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
const WEEKDAYS_SHORT = ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"];
const WEEKDAYS_LONG = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"];
export const RELEASES_URL = "https://github.com/carulla94/el-especulador-del-wow/releases/latest/download/OroHermandad.zip";
export const CATEGORY_ORDER = ["metal", "piedra", "gema", "hierba", "piel", "tela", "pocion", "elixir", "frasco", "comida",
  "venda", "encantar", "elemental", "otro"];
export const DURATIONS = [{value: 1, label: "Corta"}, {value: 2, label: "Media"}, {value: 3, label: "Larga"}];
/** Chart colours, validated for the dark surface with the dataviz palette checks (see hermandad.css for the same
 * values as tokens). Text never wears them. */
export const CHART = Object.freeze({price: "#c98500", normal: "#a9a18d", good: "#0ca30c", down: "#3987e5", up: "#e66767",
  grid: "#3a3a32", surface: "#22231f", text: "#e9e0cd", muted: "#a9a18d"});

let E = null;
/** The market rules module (src/especular.mjs, served as /especular.js). Must be set before most builders run. */
export function setEspecular(module) { E = module; return E; }
function rules() {
  if (!E) throw new Error("Las reglas del mercado (especular.js) no están cargadas.");
  return E;
}

const isInt = value => Number.isSafeInteger(value);
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const round1 = x => Math.round(x * 10) / 10;

// ---- Money: integer copper shown as WoW gold, silver and copper ------------------------------------------------
function groupThousands(n) {
  const text = String(n);
  return text.length < 5 ? text : text.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
}
/** Copper as parts [{value, unit}] with unit g, s or c; zero parts are left out (0 is [{0, c}]); null when the
 * amount is not an integer. */
export function gscParts(copper) {
  if (!isInt(copper)) return null;
  const abs = Math.abs(copper), g = Math.floor(abs / 10000), s = Math.floor((abs % 10000) / 100), c = abs % 100;
  const parts = [];
  if (g > 0) parts.push({value: groupThousands(g), unit: "g"});
  if (s > 0) parts.push({value: String(s), unit: "s"});
  if (c > 0 || parts.length === 0) parts.push({value: String(c), unit: "c"});
  return {negative: copper < 0, parts};
}
/** Copper as "12g 34s 56c", "82s 16c", "7c" or "0c"; negative amounts start with "−"; "—" (or empty) when unknown. */
export function formatGSC(copper, empty = "—") {
  const money = gscParts(copper);
  if (!money) return empty;
  return (money.negative ? "−" : "") + money.parts.map(p => p.value + p.unit).join(" ");
}
/** "1.000", "12.345g" and "1.000,5": a point between a leading group of 1 to 3 digits (not starting with 0) and groups of
 * exactly three digits groups thousands, as Spanish and formatGSC write them. Any other point is a decimal point. */
const THOUSANDS = /(^|[^\d.,])([1-9]\d{0,2}(?:\.\d{3})+)(?![\d.])/g;
/** Parses what a player types for an amount: "12g 34s 56c", "1o 20p" (Spanish), "75s", "3c", "10.000g", or a bare gold
 * amount with a decimal comma or point ("1,25" = 1g 25s, "1.5" = 1g 50s, "1.000" = 1000g). Returns copper, or null
 * when empty or not understood. Every formatGSC output of a non-negative amount reads back as the same copper. */
export function parseGSC(text) {
  const raw = String(text ?? "").trim().toLowerCase().replace(/\s+/g, " ")
    .replace(THOUSANDS, (_, before, number) => before + number.replace(/\./g, ""));
  if (!raw) return null;
  if (/^\d{1,9}(?:[.,]\d{1,4})?$/.test(raw)) {
    const [whole, fraction = ""] = raw.split(/[.,]/);
    const value = Number(whole) * 10000 + Number(fraction.padEnd(4, "0"));
    return isInt(value) ? value : null;
  }
  const tokens = raw.replace(/(\d)\s+([a-z])/g, "$1$2").split(" ");
  const factor = {g: 10000, o: 10000, s: 100, p: 100, c: 1};
  const seen = new Set();
  let total = 0;
  for (const token of tokens) {
    const match = /^(\d{1,9})([gospc])$/.exec(token);
    if (!match) return null;
    const unit = factor[match[2]];
    if (seen.has(unit)) return null;
    seen.add(unit);
    total += Number(match[1]) * unit;
  }
  return isInt(total) ? total : null;
}

// ---- Percentages, counts, dates and times ----------------------------------------------------------------------
/** Basis points as "+3,2 %" / "-4,1 %" / "0 %" with the shared rounding of especular texts; "—" when unknown. */
export function formatPct(bp) { return isInt(bp) ? `${rules().texts.signedPct(bp)} %` : "—"; }
export function formatUnits(n) { return isInt(n) ? `${groupThousands(n)} ud.` : "—"; }
/** Day index (especular.dayIndex) as its Spanish calendar date, e.g. "mié 4 nov". */
export function dayLabel(d, {weekday = true, year = false} = {}) {
  const date = new Date((rules().DAY0 + d * 86400 + 3600) * 1000);
  const text = `${date.getUTCDate()} ${MONTHS[date.getUTCMonth()]}${year ? ` ${date.getUTCFullYear()}` : ""}`;
  return weekday ? `${WEEKDAYS_SHORT[rules().weekdayOf(d)]} ${text}` : text;
}
/** "hace un momento", "hace 5 min", "hace 2 h", "hace 1 día", "hace 3 días"; null for no date. */
export function relativeTime(iso, nowMs) {
  const t = Date.parse(iso ?? "");
  if (!Number.isFinite(t)) return null;
  const seconds = Math.max(0, Math.floor((nowMs - t) / 1000));
  if (seconds < 60) return "hace un momento";
  if (seconds < 3600) return `hace ${Math.floor(seconds / 60)} min`;
  if (seconds < 86400) return `hace ${Math.floor(seconds / 3600)} h`;
  return `hace ${plural(Math.floor(seconds / 86400), "día", "días")}`;
}
/** A moment as "hoy 18:05", "ayer 21:40" or "3 nov 21:40" in the given time zone (the viewer's by default). */
export function formatWhen(iso, nowMs, timeZone) {
  const t = Date.parse(iso ?? "");
  if (!Number.isFinite(t)) return "—";
  const parts = ms => Object.fromEntries(new Intl.DateTimeFormat("es-ES", {timeZone, year: "numeric", month: "numeric", day: "numeric",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23"}).formatToParts(new Date(ms)).map(p => [p.type, p.value]));
  const at = parts(t), today = parts(nowMs), yesterday = parts(nowMs - 86400000);
  const same = (a, b) => a.year === b.year && a.month === b.month && a.day === b.day;
  const clock = `${at.hour}:${at.minute}`;
  if (same(at, today)) return `hoy ${clock}`;
  if (same(at, yesterday)) return `ayer ${clock}`;
  return `${Number(at.day)} ${MONTHS[Number(at.month) - 1]} ${clock}`;
}
/** The freshness strip: "4 personas aportan (2 suben) · último envío hace 2 h · día 12 desde el lanzamiento". Persons
 * (freshness.observers) are the members who upload plus the guild mates whose addon shared their scans in 14 days;
 * "suben" (contributors) are the members who uploaded. Without the persons count it reads "4 miembros". */
export function freshnessLine(freshness, dayOfLaunch, nowMs) {
  const parts = [];
  const contributors = freshness?.contributors ?? 0, observers = freshness?.observers;
  if (contributors <= 0) parts.push("ningún envío en 14 días");
  else if (isInt(observers)) parts.push(`${plural(observers, "persona aporta", "personas aportan")} (${plural(contributors, "sube", "suben")})`);
  else parts.push(plural(contributors, "miembro", "miembros"));
  const ago = relativeTime(freshness?.lastUploadAt, nowMs);
  if (ago) parts.push(`último envío ${ago}`);
  if (isInt(dayOfLaunch)) {
    if (dayOfLaunch >= 1) parts.push(`día ${dayOfLaunch} desde el lanzamiento`);
    else if (dayOfLaunch === 0) parts.push("el lanzamiento es mañana");
    else parts.push(`faltan ${1 - dayOfLaunch} días para el lanzamiento`);
  }
  return parts.join(" · ");
}

/** Who is behind one day of the market: the labels of the members kept (null for a guild mate who only shares from
 * the game), e.g. "Ana, Luis y 2 compañeros", "Ana, Luis" or "1 compañero"; the count alone when nobody is known. */
export function peopleText(labels, count) {
  const list = Array.isArray(labels) ? labels : [], names = list.filter(Boolean), mates = list.length - names.length;
  if (!list.length) return isInt(count) ? String(count) : "—";
  const others = mates > 0 ? plural(mates, "compañero", "compañeros") : null;
  if (!names.length) return others;
  return others ? `${names.join(", ")} y ${others}` : names.join(", ");
}

// ---- What the market says as a whole -------------------------------------------------------------------------
/** Counts the trend of the items that already have a normal price (n >= 7). */
export function marketMood(items) {
  const out = {items: 0, known: 0, falling: 0, rising: 0, learning: 0, maxN: 0, fallingBp: []};
  for (const e of items ?? []) {
    out.items++;
    out.maxN = Math.max(out.maxN, e.n ?? 0);
    if (e.status === "SIN_DATOS" || !isInt(e.N)) { out.learning++; continue; }
    if (e.trend !== "bajando" && e.trend !== "subiendo" && e.trend !== "estable") continue;
    out.known++;
    if (e.trend === "bajando") { out.falling++; if (isInt(e.trendBp)) out.fallingBp.push(e.trendBp); }
    if (e.trend === "subiendo") out.rising++;
  }
  return out;
}
/** The banners above the market, most important first: the launch phase (from the server), "aprendiendo precios"
 * while no item has 7 days, and "mercado bajando/subiendo" when at least 3 items and a third of the items with a
 * normal price share that trend. Each is {kind, title, text}. */
export function marketBanners(summary) {
  const out = [];
  // A shared text that already starts with the title ("Protección de lanzamiento: …") keeps only what follows it.
  const after = (title, text) => text.startsWith(title + ": ") ? text.charAt(title.length + 2).toUpperCase() + text.slice(title.length + 3) : text;
  if (summary?.banner) {
    const title = summary.phase === "antes" ? "Antes del lanzamiento" : "Protección de lanzamiento";
    out.push({kind: summary.phase === "antes" ? "before" : "guard", title, text: after(title, summary.banner) + "."});
  }
  const mood = marketMood(summary?.items);
  if (mood.items > 0 && mood.learning === mood.items) {
    const title = "Aprendiendo precios";
    out.push({kind: "learning", title, text: `${after(title, rules().texts.learning(mood.maxN))} con datos. Hasta tener 7 no hay precio normal, chollos ni balances.`});
  }
  const median = rules().median;
  if (mood.falling >= 3 && mood.falling * 3 >= mood.known) {
    const typical = mood.fallingBp.length ? ` (mediana ${formatPct(median(mood.fallingBp))})` : "";
    out.push({kind: "falling", title: "Mercado bajando", text: `${mood.falling} de ${plural(mood.known, "objeto", "objetos")} con precio normal han caído más de un 10 % en una semana${typical}. Vende pronto lo que farmees; no compres para revender.`});
  } else if (mood.rising >= 3 && mood.rising * 3 >= mood.known) {
    out.push({kind: "rising", title: "Mercado subiendo", text: `${mood.rising} de ${plural(mood.known, "objeto", "objetos")} con precio normal suben más de un 15 %: aún no hay precio normal fiable; no compres para revender.`});
  }
  return out;
}
/** Why "Chollos de hoy" is empty: the one cause that applies, and what fixes it. */
export function cholloEmptyText(summary) {
  const items = summary?.items ?? [];
  if (summary?.phase === "antes") return "Aún no ha empezado el servidor: los chollos llegarán cuando haya precios de varios días.";
  if (summary?.phase === "proteccion") return "Protección de lanzamiento: hasta el 18 de noviembre no se marcan chollos, porque los precios del lanzamiento todavía no son normales.";
  const mood = marketMood(items);
  if (mood.items === 0) return "Todavía no hay objetos en este mercado.";
  if (mood.learning === mood.items) return `Aprendiendo precios: hacen falta 7 días con datos (de momento ${plural(mood.maxN, "día", "días")}).`;
  if (!items.some(e => e.price)) return "Hoy todavía nadie ha escaneado la subasta: los chollos se buscan con el precio más bajo visto hoy por la hermandad.";
  if (mood.falling >= 3 && mood.falling * 3 >= mood.known) return "El mercado está bajando: no se proponen compras para revender mientras dure la caída.";
  return "Hoy nadie de la hermandad ha visto ningún objeto por debajo de su línea de chollo. Cuantos más compañeros escaneen la subasta entera con el addon, antes se detectan.";
}

// ---- The market table: filters and sorting -------------------------------------------------------------------
const CONF_RANK = {ALTA: 3, MEDIA: 2, BAJA: 1};
const VERDICT_RANK = {CHOLLO: 0, CARO: 1, ESPERA: 2, BAJADA: 3, INESTABLE: 4, NORMAL: 5, PROTECCION: 6, SIN_PRECIO: 7, FUERA_DE_RANGO: 8, SIN_DATOS: 9};
/** The sortable columns of the market table: key -> value used to sort (null sorts last either way). */
export const SORTS = Object.freeze({
  name: e => (e.name || `Objeto ${e.id}`).toLocaleLowerCase("es"),
  hoy: e => e.price?.lo ?? null,
  N: e => e.N ?? null,
  d1: e => e.d1 ?? null,
  d7: e => e.d7 ?? null,
  range: e => e.min14 ?? null,
  Q: e => e.Q ?? null,
  members: e => e.members ?? null,
  conf: e => CONF_RANK[e.conf] ?? null,
  verdict: e => VERDICT_RANK[e.verdict] ?? null
});
/** Filters: q (name or ID), cat (category key or ""), show ("" | "favoritos" | "chollos" | "caros" | "precio"), conf
 * ("" | "media" | "alta"). favorites: the Set of IDs of the player's list, for show "favoritos". */
export function filterItems(items, {q = "", cat = "", show = "", conf = "", favorites = null} = {}) {
  const needle = String(q).trim().toLocaleLowerCase("es");
  return (items ?? []).filter(e => {
    if (cat && e.cat !== cat) return false;
    if (needle && !(e.name || "").toLocaleLowerCase("es").includes(needle) && String(e.id) !== needle) return false;
    if (show === "favoritos" && !favorites?.has(e.id)) return false;
    if (show === "chollos" && e.verdict !== "CHOLLO") return false;
    if (show === "caros" && e.verdict !== "CARO") return false;
    if (show === "precio" && !e.price) return false;
    if (conf === "media" && !(CONF_RANK[e.conf] >= 2)) return false;
    if (conf === "alta" && e.conf !== "ALTA") return false;
    return true;
  });
}
/** The player's list as stored in the browser: a JSON array of item IDs. Anything else reads as an empty list. */
export function parseFavorites(text) {
  try {
    const list = JSON.parse(text ?? "[]");
    return Array.isArray(list) ? [...new Set(list.filter(id => isInt(id) && id > 0))].slice(0, 200) : [];
  } catch { return []; }
}
/** The items of the player's list that this market has, in market order. */
export function favoriteRows(summary, favorites) {
  return (summary?.items ?? []).filter(e => favorites?.has(e.id));
}
/** What moved most today against yesterday, with a price today: {fallers, risers}, the biggest change first. */
export function dayMovers(summary, count = 5) {
  const moved = (summary?.items ?? []).filter(e => isInt(e.d1) && e.d1 !== 0 && isInt(e.price?.lo) && e.verdict !== "FUERA_DE_RANGO");
  const by = (a, b) => a.d1 - b.d1 || a.id - b.id;
  return {fallers: moved.filter(e => e.d1 < 0).sort(by).slice(0, count), risers: moved.filter(e => e.d1 > 0).sort((a, b) => by(b, a)).slice(0, count)};
}
/** Sorts a copy. key "" keeps the server order (category order, then ID). Unknown values always go last. */
export function sortItems(items, {key = "", dir = "asc"} = {}) {
  const list = [...(items ?? [])];
  const get = SORTS[key];
  if (!get) return list;
  const sign = dir === "desc" ? -1 : 1;
  return list.sort((x, y) => {
    const a = get(x), b = get(y);
    if (a === null && b === null) return x.id - y.id;
    if (a === null) return 1;
    if (b === null) return -1;
    const order = typeof a === "string" ? a.localeCompare(b, "es") : a - b;
    return order !== 0 ? sign * order : x.id - y.id;
  });
}
/** Groups items by category in the fixed category order: [{cat, items}]. */
export function groupByCategory(items) {
  const groups = new Map();
  for (const e of items) { if (!groups.has(e.cat)) groups.set(e.cat, []); groups.get(e.cat).push(e); }
  return CATEGORY_ORDER.filter(cat => groups.has(cat)).map(cat => ({cat, items: groups.get(cat)}));
}

// ---- SVG node trees (rendered with createElementNS in the page, as strings in the tests) -----------------------
/** A node {tag, attrs, children}; children are nodes or strings (text). null/false children are dropped. */
export function h(tag, attrs = {}, ...children) {
  return {tag, attrs: attrs || {}, children: children.flat(Infinity).filter(c => c !== null && c !== undefined && c !== false)};
}
const escapeXML = text => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
export function toSVGString(node) {
  if (typeof node === "string" || typeof node === "number") return escapeXML(node);
  const attrs = Object.entries(node.attrs).filter(([, v]) => v !== null && v !== undefined && v !== false)
    .map(([k, v]) => ` ${k}="${escapeXML(v)}"`).join("");
  return `<${node.tag}${attrs}>${node.children.map(toSVGString).join("")}</${node.tag}>`;
}
function toDOM(node, doc) {
  if (typeof node === "string" || typeof node === "number") return doc.createTextNode(String(node));
  const el = doc.createElementNS(SVG_NS, node.tag);
  for (const [k, v] of Object.entries(node.attrs)) if (v !== null && v !== undefined && v !== false) el.setAttribute(k, String(v));
  for (const child of node.children) el.append(toDOM(child, doc));
  return el;
}

/** Sparkline geometry for values (nulls are gaps). A gap breaks the line, and a lone value draws as a dot (a
 * zero-length segment with round caps). Returns {d, points, last, min, max}; d is "" without values. */
export function sparklinePath(values, {width = 96, height = 24, pad = 3} = {}) {
  const list = Array.isArray(values) ? values : [];
  const known = list.filter(isInt);
  if (known.length === 0) return {d: "", points: [], last: null, min: null, max: null};
  const min = Math.min(...known), max = Math.max(...known);
  const span = list.length > 1 ? (width - 2 * pad) / (list.length - 1) : 0;
  const y = v => max === min ? height / 2 : pad + (height - 2 * pad) * (max - v) / (max - min);
  const points = [];
  let d = "", open = false;
  list.forEach((v, i) => {
    if (!isInt(v)) { open = false; return; }
    const x = round1(list.length > 1 ? pad + i * span : width / 2), yy = round1(y(v));
    const next = list[i + 1];
    if (!open) { d += `M${x} ${yy}`; open = true; if (!isInt(next)) d += "l0 0"; }
    else d += `L${x} ${yy}`;
    points.push({i, x, y: yy, v});
  });
  return {d, points, last: points[points.length - 1], min, max};
}
/** The 28-day sparkline of the table (one series, so no legend: the column header names it). */
export function sparklineSVG(values, {width = 96, height = 24} = {}) {
  const geo = sparklinePath(values, {width, height});
  const label = geo.d ? `28 días: entre ${formatGSC(geo.min)} y ${formatGSC(geo.max)}` : "28 días: sin datos";
  return h("svg", {class: "spark", viewBox: `0 0 ${width} ${height}`, width, height, role: "img", "aria-label": label},
    h("title", {}, label),
    geo.d ? h("path", {d: geo.d, fill: "none", stroke: CHART.price, "stroke-width": 1.5, "stroke-linecap": "round", "stroke-linejoin": "round"}) : h("path", {d: `M3 ${height / 2}H${width - 3}`, stroke: CHART.grid, "stroke-width": 1}),
    geo.last ? h("circle", {cx: geo.last.x, cy: geo.last.y, r: 2.5, fill: CHART.price, stroke: CHART.surface, "stroke-width": 1}) : null);
}

/** "Nice" axis ticks for a copper range: 3 to 6 round values (1, 2 or 5 times a power of ten). */
export function niceTicks(lo, hi, wanted = 4) {
  if (!Number.isFinite(lo) || !Number.isFinite(hi)) return [];
  if (hi <= lo) { const pad = Math.max(1, Math.abs(lo) * 0.1); lo -= pad; hi += pad; }
  const raw = (hi - lo) / wanted, power = Math.pow(10, Math.floor(Math.log10(raw))), unit = raw / power;
  const step = Math.max(1, (unit < 1.5 ? 1 : unit < 3 ? 2 : unit < 7 ? 5 : 10) * power);
  const out = [];
  for (let t = Math.ceil(lo / step) * step; t <= hi + 1e-9; t += step) out.push(Math.round(t));
  return out;
}

/** The item detail chart over days from..to: the daily low-high band (wash), the day value v (line), the normal
 * price N and the chollo line (dumpLine) as horizontal references, dump days as dots and today's lowest price.
 * input: {days: [{d, lo, hi, v}], from, to, N, dumpLine, markers: [d], price, width, height}. Returns null without
 * days, else {node, layout: {x0, x1, y0, y1, from, to, x(d), y(copper)}} for the hover layer. */
export function bandChartSVG({days = [], from, to, N = null, dumpLine = null, markers = [], price = null, width = 640, height = 260} = {}) {
  const list = days.filter(x => isInt(x.d) && x.d >= from && x.d <= to && isInt(x.lo) && isInt(x.hi) && isInt(x.v)).sort((a, b) => a.d - b.d);
  if (list.length === 0 || !isInt(from) || !isInt(to) || to < from) return null;
  const values = list.flatMap(x => [x.lo, x.hi]);
  for (const extra of [N, dumpLine, price]) if (isInt(extra)) values.push(extra);
  let lo = Math.min(...values), hi = Math.max(...values);
  const pad = Math.max(1, Math.round((hi - lo) * 0.08));
  lo = Math.max(0, lo - pad); hi += pad;
  const ticks = niceTicks(lo, hi, height < 200 ? 3 : 4).filter(t => t >= lo && t <= hi);
  const labelWidth = Math.max(44, ...ticks.map(t => formatGSC(t).length * 7 + 8));
  const x0 = labelWidth, x1 = width - 10, y0 = 10, y1 = height - 26;
  const x = d => to === from ? (x0 + x1) / 2 : x0 + (x1 - x0) * (d - from) / (to - from);
  const y = c => y1 - (y1 - y0) * (c - lo) / (hi - lo || 1);
  const runs = [];
  for (const p of list) {
    const run = runs[runs.length - 1];
    if (run && p.d === run[run.length - 1].d + 1) run.push(p); else runs.push([p]);
  }
  const band = runs.map(run => {
    if (run.length === 1) {
      const p = run[0];
      return h("rect", {x: round1(x(p.d) - 2), y: round1(y(p.hi)), width: 4, height: round1(Math.max(1, y(p.lo) - y(p.hi))), fill: CHART.price, "fill-opacity": 0.22});
    }
    const top = run.map(p => `${round1(x(p.d))} ${round1(y(p.hi))}`), bottom = [...run].reverse().map(p => `${round1(x(p.d))} ${round1(y(p.lo))}`);
    return h("path", {d: `M${top.join("L")}L${bottom.join("L")}Z`, fill: CHART.price, "fill-opacity": 0.18});
  });
  const line = runs.map(run => run.length === 1
    ? `M${round1(x(run[0].d))} ${round1(y(run[0].v))}l0 0`
    : "M" + run.map(p => `${round1(x(p.d))} ${round1(y(p.v))}`).join("L")).join("");
  const step = width < 480 ? 14 : 7;
  const xTicks = [];
  for (let d = to; d >= from; d -= step) xTicks.push(d);
  const byDay = new Map(list.map(p => [p.d, p]));
  const node = h("svg", {class: "band-chart", viewBox: `0 0 ${width} ${height}`, width, height, role: "img",
    "aria-label": `Precio diario de ${dayLabel(from, {weekday: false})} a ${dayLabel(to, {weekday: false})}: ${plural(list.length, "día", "días")} con datos${isInt(N) ? `, normal ${formatGSC(N)}` : ""}.`},
    h("g", {class: "grid"}, ticks.map(t => h("line", {x1: x0, x2: x1, y1: round1(y(t)), y2: round1(y(t)), stroke: CHART.grid, "stroke-width": 1}))),
    h("g", {class: "y-labels", "font-size": 12, fill: CHART.muted, "text-anchor": "end"}, ticks.map(t => h("text", {x: x0 - 6, y: round1(y(t) + 4)}, formatGSC(t)))),
    h("g", {class: "x-labels", "font-size": 12, fill: CHART.muted, "text-anchor": "middle"}, xTicks.map(d => h("text", {x: round1(Math.min(x1 - 18, Math.max(x0 + 18, x(d)))), y: height - 6}, dayLabel(d, {weekday: false})))),
    h("line", {x1: x0, x2: x1, y1: y1, y2: y1, stroke: CHART.grid, "stroke-width": 1}),
    h("g", {class: "band"}, band),
    isInt(N) ? h("line", {class: "normal-line", x1: x0, x2: x1, y1: round1(y(N)), y2: round1(y(N)), stroke: CHART.normal, "stroke-width": 1.5}) : null,
    isInt(dumpLine) ? h("line", {class: "dump-line", x1: x0, x2: x1, y1: round1(y(dumpLine)), y2: round1(y(dumpLine)), stroke: CHART.good, "stroke-width": 1.5, "stroke-dasharray": "6 4"}) : null,
    h("path", {class: "value-line", d: line, fill: "none", stroke: CHART.price, "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round"}),
    h("g", {class: "markers"}, markers.filter(d => byDay.has(d)).map(d => h("circle", {cx: round1(x(d)), cy: round1(y(byDay.get(d).lo)), r: 4.5, fill: CHART.good, stroke: CHART.surface, "stroke-width": 2}))),
    isInt(price) ? h("circle", {class: "today-price", cx: round1(x(to)), cy: round1(y(price)), r: 5, fill: CHART.text, stroke: CHART.surface, "stroke-width": 2}) : null,
    h("line", {class: "crosshair", x1: x0, x2: x0, y1: y0, y2: y1, stroke: CHART.text, "stroke-width": 1, visibility: "hidden"}),
    h("rect", {class: "hit", x: x0, y: y0, width: x1 - x0, height: y1 - y0, fill: "transparent"}));
  return {node, layout: {x0, x1, y0, y1, from, to, x, y}};
}

/** Days d in from..to whose lowest price was at or below the chollo line of that day's own baseline (the 14 days
 * before it): the dump markers of the detail chart. series: {[d]: {v, lo, hi, qty, obs, ids}} as the server keeps it. */
export function dumpDays(series, from, to) {
  const {baseline, assess} = rules();
  const out = [];
  for (let d = from; d <= to; d++) {
    const x = series[d];
    if (!x || !isInt(x.lo)) continue;
    const a = assess(baseline(series, d, {cloud: true}), x.lo, d);
    if (isInt(a.dumpLine) && x.lo <= a.dumpLine) out.push(d);
  }
  return out;
}

/** Weekday bars from especular.weekday (cloud only). Hidden unless the pattern qualifies (w.shown): then the text
 * says why ("Faltan N semanas…"). Shown: one bar per weekday of e (bp against its week), cheaper below the line. */
export function weekdayBars(w, {width = 420, height = 160} = {}) {
  if (!w || !w.shown || !Array.isArray(w.e) || w.e.length !== 7) return {shown: false, text: w?.text ?? "Sin datos por día de la semana.", node: null, bars: []};
  const bars = w.e.map((e, wd) => ({wd, name: WEEKDAYS_LONG[wd], short: WEEKDAYS_SHORT[wd], e, weeks: w.counts?.[wd] ?? null}));
  // Room above for the dearest label, below for the cheapest label and then the weekday names.
  const top = 18, bottom = height - 38;
  const up = Math.max(50, ...w.e.map(v => Math.max(0, v))), down = Math.max(50, ...w.e.map(v => Math.max(0, -v)));
  const zero = top + (bottom - top) * up / (up + down);
  const scale = v => (bottom - top) * v / (up + down);
  const slot = (width - 16) / 7, barWidth = Math.min(24, slot * 0.6);
  const xs = wd => 8 + slot * wd + slot / 2;
  const bar = b => {
    const len = Math.abs(scale(b.e)), r = Math.min(4, len), left = round1(xs(b.wd) - barWidth / 2), right = round1(xs(b.wd) + barWidth / 2);
    if (len < 0.5) return h("line", {x1: left, x2: right, y1: zero, y2: zero, stroke: CHART.muted, "stroke-width": 2});
    const end = b.e < 0 ? zero + len : zero - len, dir = b.e < 0 ? -1 : 1;
    // Square at the zero line, 4px rounded at the data end.
    const d = `M${left} ${zero}V${round1(end + dir * r)}Q${left} ${round1(end)} ${round1(left + r)} ${round1(end)}H${round1(right - r)}Q${right} ${round1(end)} ${right} ${round1(end + dir * r)}V${zero}Z`;
    return h("path", {d, fill: b.e < 0 ? CHART.down : CHART.up}, h("title", {}, `${b.name}: ${formatPct(b.e)} frente a su semana${isInt(b.weeks) ? ` · ${plural(b.weeks, "semana", "semanas")}` : ""}`));
  };
  const labelled = new Set([w.cheapest, w.dearest].filter(isInt));
  const node = h("svg", {class: "weekday-chart", viewBox: `0 0 ${width} ${height}`, width, height, role: "img",
    "aria-label": `Precio por día de la semana frente a la mediana de su semana. Más barato: ${WEEKDAYS_LONG[w.cheapest]} (${formatPct(w.e[w.cheapest])}).`},
    h("line", {x1: 4, x2: width - 4, y1: zero, y2: zero, stroke: CHART.grid, "stroke-width": 1}),
    bars.map(bar),
    h("g", {"font-size": 12, fill: CHART.muted, "text-anchor": "middle"}, bars.map(b => h("text", {x: round1(xs(b.wd)), y: height - 6}, b.short))),
    h("g", {"font-size": 12, fill: CHART.text, "text-anchor": "middle"}, bars.filter(b => labelled.has(b.wd)).map(b =>
      h("text", {x: round1(xs(b.wd)), y: round1(b.e < 0 ? zero + Math.abs(scale(b.e)) + 14 : zero - Math.abs(scale(b.e)) - 5)}, formatPct(b.e)))));
  return {shown: true, text: w.text, node, bars};
}

// ---- CSV for Spanish Excel: the same cells as the server's export (src/guild.mjs) -------------------------------
/** Copper as gold with a decimal comma: 12345 -> "1,2345"; "" for no value. */
export function csvGold(copper) {
  if (!isInt(copper)) return "";
  const abs = Math.abs(copper), fraction = String(abs % 10000).padStart(4, "0").replace(/0+$/, "");
  return (copper < 0 ? "-" : "") + Math.floor(abs / 10000) + (fraction ? "," + fraction : "");
}
/** Basis points as a percentage with a decimal comma: -1234 -> "-12,34"; "" for no value. */
export function csvPct(bp) {
  if (!isInt(bp)) return "";
  const abs = Math.abs(bp), fraction = String(abs % 100).padStart(2, "0").replace(/0+$/, "");
  return (bp < 0 ? "-" : "") + Math.floor(abs / 100) + (fraction ? "," + fraction : "");
}
/** A text cell, quoted when needed and with a leading ' when Excel would read it as a formula. */
export function csvText(value) {
  let text = value === null || value === undefined ? "" : String(value);
  if (/^[=+\-@\t\r]/.test(text)) text = "'" + text;
  return /[;"\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}
const CELL = {gold: csvGold, pct: csvPct, int: v => isInt(v) ? String(v) : "", text: csvText};
/** CSV text: UTF-8 BOM, ';' separator, CRLF. columns: [{label, kind: gold|pct|int|text, value(record)}]. */
export function csvRows(columns, records) {
  const lines = [columns.map(c => csvText(c.label)).join(";")];
  for (const record of records ?? []) lines.push(columns.map(c => (CELL[c.kind] ?? csvText)(c.value(record))).join(";"));
  return "\uFEFF" + lines.join("\r\n") + "\r\n";
}
/** The summary columns of the server CSV (GET /api/guild/export.csv?kind=summary), for "exportar esta vista". */
export const SUMMARY_COLUMNS = Object.freeze([
  {label: "Objeto", kind: "text", value: e => e.name || `Objeto ${e.id}`}, {label: "ID", kind: "int", value: e => e.id},
  {label: "Categoría", kind: "text", value: e => e.catLabel}, {label: "Hoy (oro)", kind: "gold", value: e => e.today?.v},
  {label: "Más bajo hoy (oro)", kind: "gold", value: e => e.price?.lo}, {label: "Visto por", kind: "text", value: e => e.price ? e.price.member ?? "un compañero" : null},
  {label: "Normal 14 d (oro)", kind: "gold", value: e => e.N}, {label: "Δ1d (%)", kind: "pct", value: e => e.d1},
  {label: "Δ7d (%)", kind: "pct", value: e => e.d7}, {label: "Mín 14 d (oro)", kind: "gold", value: e => e.min14},
  {label: "Máx 14 d (oro)", kind: "gold", value: e => e.max14}, {label: "Oferta típica", kind: "int", value: e => e.Q},
  {label: "Personas", kind: "int", value: e => e.members}, {label: "Días con datos", kind: "int", value: e => e.n},
  {label: "Confianza", kind: "text", value: e => e.confLabel}, {label: "Veredicto", kind: "text", value: e => e.verdictLabel}]);
/** The daily columns of the server CSV (kind=daily) for one item of the detail view. */
export function dailyColumns(item, launchDay) {
  return [{label: "Fecha", kind: "text", value: x => x.date}, {label: "Día", kind: "int", value: x => x.d - launchDay + 1},
    {label: "Objeto", kind: "text", value: () => item.name || `Objeto ${item.id}`}, {label: "ID", kind: "int", value: () => item.id},
    {label: "Categoría", kind: "text", value: () => item.catLabel}, {label: "Valor (oro)", kind: "gold", value: x => x.v},
    {label: "Mín (oro)", kind: "gold", value: x => x.lo}, {label: "Máx (oro)", kind: "gold", value: x => x.hi},
    {label: "Cantidad", kind: "int", value: x => x.qty}, {label: "Personas", kind: "int", value: x => x.obs}];
}

// ---- The editable flip calculator of the item detail --------------------------------------------------------
/** Runs especular.flip with what the player typed. detail: GET /api/guild/item. inputs (strings as typed): units,
 * buy, resale, cut (percent), deposit, budget. Returns {error} or {result, D, depositEstimated, opts}. */
export function calculatorFlip(detail, inputs) {
  const {flip} = rules();
  const unitsText = String(inputs.units ?? "").trim().replace(/^([1-9]\d?)\.(\d{3})$/, "$1$2");   // "1.000" as in "10.000"
  const units = /^\d{1,5}$/.test(unitsText) ? Number(unitsText) : null;
  if (units === null || units < 1 || units > 10000) return {error: "Unidades: escribe un número entero entre 1 y 10.000."};
  const buy = parseGSC(inputs.buy);
  if (buy === null || buy < 1) return {error: "Precio de compra: escribe un importe como 1g 20s 5c."};
  const resale = parseGSC(inputs.resale);
  if (resale === null || resale < 1) return {error: "Precio de reventa: escribe un importe como 1g 20s 5c."};
  const cutText = String(inputs.cut ?? "").trim().replace(",", ".");
  if (!/^\d{1,2}(?:\.\d{1,2})?$/.test(cutText)) return {error: "Comisión: escribe un porcentaje entre 0 y 99,99."};
  const cutBp = Math.round(Number(cutText) * 100);
  const depositText = String(inputs.deposit ?? "").trim();
  const D = depositText === "" ? null : parseGSC(depositText);
  if (depositText !== "" && D === null) return {error: "Depósito: escribe un importe como 30s, o déjalo vacío para estimarlo."};
  const budget = parseGSC(inputs.budget);
  if (budget === null || budget < 1) return {error: "Presupuesto: escribe un importe como 100g."};
  const opts = {cutBp, D, vendor: detail?.item?.vendor ?? 0, budget};
  const base = {...(detail?.baseline ?? {}), Rs: resale};
  const result = flip(base, [[buy, units]], opts);
  return {result, opts};
}

// ---- Qué compensa: farming, buying to resell and smelting, worked out from the market summary --------------------
export const PROFESSIONS = Object.freeze({mining: {label: "Minería", per: "veta"}, herbalism: {label: "Herboristería", per: "planta"},
  skinning: {label: "Desuello", per: "bicho"}, cloth: {label: "Tela", per: "unidad"}});
/** Copies of Data.GATHER and Data.CLOTH in the addon's Data.lua (test/hermandad-view.test.mjs compares them). items:
 * [itemID, average units per node or mob]. A cloth row counts one unit, because no drop rate is known: it is only
 * listed on its own, never against the nodes. */
export const GATHER = Object.freeze([
  {prof: "mining", key: "copper", skill: 1, level: [1, 20], items: [[2770, 2], [2835, 0.45], [774, 0.01], [818, 0.01], [1210, 0.01]], zones: "Los Baldíos, Durotar, Dun Morogh, Bosque de Elwynn, Claros de Tirisfal, Costa Oscura"},
  {prof: "mining", key: "tin", skill: 65, level: [15, 30], items: [[2771, 2], [2836, 0.4], [1210, 0.01], [1206, 0.01], [1705, 0.01], [1529, 0.01]], zones: "Vallefresno, Laderas de Trabalomas, Montañas Crestagrana, Los Humedales, Sierra Espolón"},
  {prof: "mining", key: "silver", skill: 75, level: [15, 35], rare: true, items: [[2775, 1.5], [1206, 0.015]], zones: "Vallefresno, Las Mil Agujas, Laderas de Trabalomas, Tierras Altas de Arathi"},
  {prof: "mining", key: "iron", skill: 125, level: [25, 40], items: [[2772, 2], [2838, 0.4], [1529, 0.013], [1705, 0.01], [3864, 0.007]], zones: "Tierras Altas de Arathi, Montañas de Alterac, Vega de Tuercespina, Las Mil Agujas, Desolace"},
  {prof: "mining", key: "gold", skill: 155, level: [30, 45], rare: true, items: [[2776, 1.5], [1529, 0.01], [3864, 0.01]], zones: "Desolace, Tierras Altas de Arathi, Vega de Tuercespina, Tierras Inhóspitas"},
  {prof: "mining", key: "mithril", skill: 175, level: [35, 50], items: [[3858, 2], [7912, 0.4], [3864, 0.008], [7909, 0.007], [7910, 0.007]], zones: "Tierras del Interior, Desolace, Tanaris, Tierras Inhóspitas, Feralas"},
  {prof: "mining", key: "truesilver", skill: 230, level: [40, 55], rare: true, items: [[7911, 1.5], [7909, 0.01], [7910, 0.01]], zones: "Silithus, Tierras del Interior, Las Estepas Ardientes, Cráter de Un'Goro"},
  {prof: "mining", key: "thorium", skill: 245, note: "vetas pequeñas", level: [45, 60], items: [[10620, 2], [12365, 0.4], [7910, 0.008], [12361, 0.007], [12364, 0.007], [12799, 0.007], [12800, 0.007]], zones: "Cráter de Un'Goro, Silithus, Las Estepas Ardientes, Frondavil, Cuna del Invierno"},
  {prof: "mining", key: "richthorium", skill: 275, note: "vetas enriquecidas", level: [50, 60], items: [[10620, 3], [12365, 0.4], [12363, 0.03], [12361, 0.008], [12364, 0.008], [12799, 0.008], [7910, 0.008], [12800, 0.007]], zones: "Silithus, Cuna del Invierno, Tierras de la Peste del Este, Azshara, Las Estepas Ardientes"},
  {prof: "herbalism", key: "peacebloom", skill: 1, level: [1, 15], items: [[2447, 2]], zones: "zonas iniciales, Los Baldíos"},
  {prof: "herbalism", key: "silverleaf", skill: 1, level: [1, 15], items: [[765, 2]], zones: "zonas iniciales"},
  {prof: "herbalism", key: "earthroot", skill: 15, level: [5, 20], items: [[2449, 2]], zones: "Los Baldíos, Claros de Tirisfal, Teldrassil, Dun Morogh"},
  {prof: "herbalism", key: "mageroyal", skill: 50, level: [10, 25], items: [[785, 2]], zones: "Los Baldíos, Páramos de Poniente, Costa Oscura, Loch Modan"},
  {prof: "herbalism", key: "briarthorn", skill: 70, level: [15, 30], items: [[2450, 2]], zones: "Los Baldíos, Páramos de Poniente, Los Humedales, Bosque del Ocaso"},
  {prof: "herbalism", key: "stranglekelp", skill: 85, level: [15, 40], items: [[3820, 2]], zones: "bajo el agua: Vega de Tuercespina, Los Humedales, Costa Oscura"},
  {prof: "herbalism", key: "bruiseweed", skill: 100, level: [20, 35], items: [[2453, 2]], zones: "Los Baldíos, Sierra Espolón, Vallefresno, Laderas de Trabalomas"},
  {prof: "herbalism", key: "steelbloom", skill: 115, level: [25, 40], items: [[3355, 2]], zones: "Vega de Tuercespina, Sierra Espolón, Tierras Altas de Arathi"},
  {prof: "herbalism", key: "kingsblood", skill: 125, level: [25, 40], items: [[3356, 2]], zones: "Vega de Tuercespina, Laderas de Trabalomas, Los Humedales, Vallefresno"},
  {prof: "herbalism", key: "gravemoss", skill: 120, level: [25, 40], rare: true, items: [[3369, 1]], zones: "cementerios de Desolace y Bosque del Ocaso"},
  {prof: "herbalism", key: "liferoot", skill: 150, level: [30, 45], items: [[3357, 2]], zones: "Vega de Tuercespina, Marjal Revolcafango, Los Humedales"},
  {prof: "herbalism", key: "fadeleaf", skill: 160, level: [30, 45], items: [[3818, 2]], zones: "Marjal Revolcafango, Vega de Tuercespina, Tierras Altas de Arathi"},
  {prof: "herbalism", key: "goldthorn", skill: 170, level: [35, 50], items: [[3821, 2]], zones: "Vega de Tuercespina, Feralas, Tierras Altas de Arathi"},
  {prof: "herbalism", key: "khadgar", skill: 185, level: [35, 50], items: [[3358, 2]], zones: "Vega de Tuercespina, Feralas, Marjal Revolcafango"},
  {prof: "herbalism", key: "wintersbite", skill: 195, level: [35, 45], items: [[3819, 2]], zones: "Montañas de Alterac"},
  {prof: "herbalism", key: "firebloom", skill: 205, level: [40, 55], items: [[4625, 2]], zones: "Tanaris, La Garganta de Fuego, Las Tierras Devastadas"},
  {prof: "herbalism", key: "purplelotus", skill: 210, level: [40, 55], items: [[8831, 2]], zones: "Tierras del Interior, Feralas, Azshara, Tanaris"},
  {prof: "herbalism", key: "arthastears", skill: 220, level: [45, 60], items: [[8836, 2]], zones: "Tierras de la Peste del Oeste y del Este, Frondavil"},
  {prof: "herbalism", key: "sungrass", skill: 230, level: [45, 60], items: [[8838, 2]], zones: "Feralas, Tierras del Interior, Azshara, Cráter de Un'Goro"},
  {prof: "herbalism", key: "blindweed", skill: 235, level: [40, 55], items: [[8839, 2]], zones: "Pantano de las Penas, Cráter de Un'Goro"},
  {prof: "herbalism", key: "ghostmushroom", skill: 245, level: [40, 55], rare: true, items: [[8845, 1]], zones: "cuevas de Tierras del Interior y Desolace"},
  {prof: "herbalism", key: "gromsblood", skill: 250, level: [45, 60], items: [[8846, 2]], zones: "Las Tierras Devastadas, Frondavil, Desolace"},
  {prof: "herbalism", key: "sansam", skill: 260, level: [48, 60], items: [[13464, 2]], zones: "Azshara, Cráter de Un'Goro, Tierras de la Peste del Este"},
  {prof: "herbalism", key: "dreamfoil", skill: 270, level: [50, 60], items: [[13463, 2]], zones: "Cráter de Un'Goro, Azshara, Tierras de la Peste del Este, Frondavil"},
  {prof: "herbalism", key: "silversage", skill: 280, level: [50, 60], items: [[13465, 2]], zones: "Cuna del Invierno, Cráter de Un'Goro, Tierras de la Peste del Este"},
  {prof: "herbalism", key: "plaguebloom", skill: 285, level: [52, 60], items: [[13466, 2]], zones: "Tierras de la Peste del Este y del Oeste, Frondavil"},
  {prof: "herbalism", key: "icecap", skill: 290, level: [53, 60], items: [[13467, 2]], zones: "Cuna del Invierno"},
  {prof: "herbalism", key: "blacklotus", skill: 300, level: [55, 60], rare: true, items: [[13468, 1]], zones: "Las Estepas Ardientes, Tierras de la Peste del Este, Silithus"},
  {prof: "skinning", key: "light", skill: 1, note: "bichos de nivel 5–20", level: [5, 20], items: [[2318, 1.5], [2934, 1], [783, 0.1]], zones: "Los Baldíos, Páramos de Poniente, Costa Oscura, Loch Modan"},
  {prof: "skinning", key: "medium", skill: 100, note: "bichos de nivel 20–30", level: [20, 30], items: [[2319, 1.5], [4232, 0.1]], zones: "Los Humedales, Vallefresno, Sierra Espolón, Laderas de Trabalomas"},
  {prof: "skinning", key: "heavy", skill: 150, note: "bichos de nivel 30–40", level: [30, 40], items: [[4234, 1.5], [4235, 0.1]], zones: "Tierras Altas de Arathi, Desolace, Vega de Tuercespina"},
  {prof: "skinning", key: "thick", skill: 200, note: "bichos de nivel 40–50", level: [40, 50], items: [[4304, 1.5], [8169, 0.1]], zones: "Feralas, Tanaris, Tierras del Interior"},
  {prof: "skinning", key: "rugged", skill: 250, note: "bichos de nivel 50–60", level: [50, 60], items: [[8170, 1.5], [8171, 0.1]], zones: "Cráter de Un'Goro, Cuna del Invierno, Silithus, Tierras de la Peste del Este"},
  {prof: "cloth", key: "2589", skill: 1, level: [5, 20], items: [[2589, 1]], zones: "humanoides de nivel 5–20"},
  {prof: "cloth", key: "2592", skill: 1, level: [15, 30], items: [[2592, 1]], zones: "humanoides de nivel 15–30"},
  {prof: "cloth", key: "4306", skill: 1, level: [25, 40], items: [[4306, 1]], zones: "humanoides de nivel 25–40"},
  {prof: "cloth", key: "4338", skill: 1, level: [35, 50], items: [[4338, 1]], zones: "humanoides de nivel 35–50"},
  {prof: "cloth", key: "14047", skill: 1, level: [48, 60], items: [[14047, 1]], zones: "humanoides de nivel 48–60"}]);
/** Copy of Data.SMELT in the addon's Data.lua. Data.FOREVER_SMELT stays out: its IDs are unconfirmed and not watched. */
export const SMELT = Object.freeze([
  {product: 2840, qty: 1, skill: 1, reagents: [[2770, 1]]}, {product: 3576, qty: 1, skill: 65, reagents: [[2771, 1]]},
  {product: 2841, qty: 2, skill: 65, reagents: [[2840, 1], [3576, 1]]}, {product: 2842, qty: 1, skill: 75, reagents: [[2775, 1]]},
  {product: 3575, qty: 1, skill: 125, reagents: [[2772, 1]]}, {product: 3577, qty: 1, skill: 155, reagents: [[2776, 1]]},
  {product: 3859, qty: 1, skill: 165, reagents: [[3575, 1], [3857, 1]]}, {product: 3860, qty: 1, skill: 175, reagents: [[3858, 1]]},
  {product: 6037, qty: 1, skill: 230, reagents: [[7911, 1]]}, {product: 12359, qty: 1, skill: 250, reagents: [[10620, 1]]}]);
/** What SMELT needs from a merchant, from Data.VENDOR_BUY (copper per unit); it is not watched, so it has no market price. */
export const VENDOR_ITEMS = Object.freeze({3857: {name: "Carbón", buy: 500}});

const itemsById = summary => new Map((summary?.items ?? []).map(e => [e.id, e]));
const nameOf = e => e.name || `Objeto ${e.id}`;
const afterCut = (copper, cutBp) => rules().idiv(copper * (10000 - cutBp), 10000);
/** The price to value what you would sell: the prudent resale once there is a normal price, else today's lowest, else
 * the day value of the last three days. {price, source: "prudente" | "hoy" | "reciente"}, or null. */
export function salePrice(e) {
  if (isInt(e?.Rs)) return {price: e.Rs, source: "prudente"};
  if (isInt(e?.price?.lo)) return {price: e.price.lo, source: "hoy"};
  for (const v of (e?.spark ?? []).slice(-3).reverse()) if (isInt(v)) return {price: v, source: "reciente"};
  return null;
}
/** The price to value what you would buy: today's lowest, else the day value of the last three days, so the morning before
 * anyone scans still has an estimate. {price, source: "hoy" | "reciente", qty5}, or null; qty5 is only known today. */
export function buyPrice(e) {
  if (isInt(e?.price?.lo)) return {price: e.price.lo, source: "hoy", qty5: e.price.qty5 ?? null};
  for (const v of (e?.spark ?? []).slice(-3).reverse()) if (isInt(v)) return {price: v, source: "reciente", qty5: null};
  return null;
}
const SOURCE_TEXT = {prudente: "reventa prudente", hoy: "precio de hoy, aún sin precio normal", reciente: "precio de los últimos días, aún sin precio normal"};
export const sourceText = source => SOURCE_TEXT[source] ?? "";
/** Each node or mob valued like the addon's routes: every material it gives, after the cut. A node whose main material has
 * no price is counted in unpriced, not shown; rare nodes are left out unless asked for. Filters: prof ("" is every
 * node and no cloth), skill (hides what needs more), rare. Returns {rows (best first), unpriced}. */
export function farmRows(summary, {prof = "", skill = null, rare = false} = {}) {
  const items = itemsById(summary), cutBp = summary?.cutBp ?? rules().CUT_BP;
  const rows = [];
  let unpriced = 0;
  for (const node of GATHER) {
    if (prof ? node.prof !== prof : node.prof === "cloth") continue;
    if ((node.rare && !rare) || (isInt(skill) && node.skill > skill)) continue;
    const main = items.get(node.items[0][0]), sale = salePrice(main);
    if (!sale) { unpriced++; continue; }
    let milli = 0;
    const parts = [];
    for (const [id, units] of node.items) {
      const e = items.get(id), found = salePrice(e);
      if (!found) continue;
      const net = afterCut(found.price, cutBp), thousandths = Math.round(units * 1000);   // 0,45 units stay exact
      milli += net * thousandths;
      parts.push({id, name: nameOf(e), units, net, value: Math.floor(net * thousandths / 1000)});
    }
    rows.push({...node, ...PROFESSIONS[node.prof], id: main.id, name: nameOf(main), value: Math.floor(milli / 1000), parts,
      unpricedParts: node.items.length - parts.length, source: sale.source, conf: main.conf, confLabel: main.confLabel, d7: main.d7, Q: main.Q});
  }
  rows.sort((a, b) => b.value - a.value || a.skill - b.skill || a.key.localeCompare(b.key));
  return {rows, unpriced};
}
/** "2 × Mineral de mitril · 0,4 × Piedra sólida": what a node gives, the materials worth at least 5 % of it unless all. */
export function partsText(row, {all = false} = {}) {
  const parts = all ? row.parts : row.parts.filter(p => p.value * 20 >= row.value);
  return parts.map(p => `${String(p.units).replace(".", ",")} × ${p.name}`).join(" · ");
}
/** especular.flip on today's lowest price of every item with a prudent resale, whatever its verdict, as the item detail
 * does. buy: chollo and it pays (with the same budget it is the chollo's own flip). gapBp: today against the most that
 * pays. Those to buy come first by profit, then the nearest to paying. */
export function resaleRows(summary, {budget = null} = {}) {
  const {flip, idiv} = rules();
  const rows = [];
  for (const e of summary?.items ?? []) {
    if (!isInt(e.Rs)) continue;
    const p = e.price?.lo ?? null;
    const f = flip({Rs: e.Rs, Q: e.Q}, null, {cutBp: summary.cutBp, D: e.deposit?.D ?? null, vendor: e.vendor, budget: budget ?? summary.budget, p, q5: e.price?.qty5 ?? null});
    if (f.reason === "FUERA_DE_RANGO") continue;
    rows.push({id: e.id, name: nameOf(e), e, p, flip: f, buy: e.verdict === "CHOLLO" && f.accept, gapBp: isInt(p) && f.maxBuy > 0 ? idiv(p * 10000, f.maxBuy) - 10000 : null});
  }
  const gap = r => r.gapBp ?? Infinity;
  return rows.sort((a, b) => Number(b.buy) - Number(a.buy) || (a.buy ? b.flip.profit - a.flip.profit : 0) || gap(a) - gap(b) || a.id - b.id);
}
/** Each smelting recipe, buying every reagent today (at the merchant when that is not dearer) and selling the bar with the
 * rules of a purchase to resell: especular.flip with the cost per bar as the price, so the same cut, lost deposit, margin,
 * liquidity and budget limits apply. A reagent nobody has scanned today costs its price of the last days (stale). During
 * the launch guard, without a normal price, with a stale reagent or with the bar falling it never says that it pays.
 * Returns {rows (those that pay first, then by profit per bar), unpriced}. */
export function smeltRows(summary, {budget = null} = {}) {
  const {flip, idiv, ceilDiv, UNITS_MAX} = rules();
  const items = itemsById(summary), rows = [];
  let unpriced = 0;
  for (const recipe of SMELT) {
    const product = items.get(recipe.product), sale = salePrice(product);
    let cost = 0, crafts = UNITS_MAX;
    const parts = [];
    for (const [id, need] of recipe.reagents) {
      const e = items.get(id), auction = buyPrice(e), vendor = VENDOR_ITEMS[id] ?? null;
      const fromVendor = vendor !== null && (!auction || vendor.buy <= auction.price);
      const unit = fromVendor ? vendor.buy : auction?.price ?? null;
      if (!isInt(unit)) { cost = null; break; }
      cost += unit * need;
      if (!fromVendor) crafts = Math.min(crafts, Math.max(1, Math.floor((auction.qty5 ?? 1) / need)));
      parts.push({id, name: e?.name || vendor?.name || `Objeto ${id}`, need, unit, fromVendor, source: fromVendor ? "mercader" : auction.source});
    }
    if (!sale || cost === null) { unpriced++; continue; }
    const stale = parts.some(p => p.source === "reciente");
    const unitCost = ceilDiv(cost, recipe.qty);
    const f = flip({Rs: sale.price, Q: product.Q}, [[unitCost, Math.min(crafts * recipe.qty, UNITS_MAX)]],
      {cutBp: summary.cutBp, D: product.deposit?.D ?? null, vendor: product.vendor, budget: budget ?? summary.budget});
    if (f.reason === "FUERA_DE_RANGO") { unpriced++; continue; }
    const unitProfit = f.netUnit - f.risk - unitCost;
    const guarded = summary.phase !== "normal" || sale.source !== "prudente" || stale, falling = product.trend === "bajando";
    const pays = f.accept && !guarded && !falling;
    rows.push({id: product.id, name: nameOf(product), skill: recipe.skill, qty: recipe.qty, parts, stale, sale: sale.price, source: sale.source, unitCost, unitProfit, marginBp: idiv(unitProfit * 10000, unitCost + f.risk),
      flip: f, pays, label: pays ? "Compensa" : guarded ? "Orientativo" : falling ? "Mercado bajando" : "No compensa", trend: product.trend, d7: product.d7});
  }
  rows.sort((a, b) => Number(b.pays) - Number(a.pays) || b.unitProfit - a.unitProfit || a.id - b.id);
  return {rows, unpriced};
}
/** The three answers at the top of the view: {key, label, target, good, name, id, amount, per, note}; amount and id are null
 * when there is nothing to point at. Only a real purchase or a recipe that pays counts as good news. */
export function bestCards(summary, farm, resale, smelt) {
  const topFarm = farm.rows[0], buy = resale.find(r => r.buy), nearest = resale.find(r => isInt(r.gapBp));
  const pays = smelt.rows.find(r => r.pays), topSmelt = smelt.rows[0];
  const noBuy = resale.some(r => r.e.verdict === "CHOLLO") ? "Hay chollos, pero ninguno compensa tras la comisión y el depósito." : cholloEmptyText(summary);
  return [
    topFarm ? {key: "farm", label: "Qué farmear", target: "#farm-section", good: false, name: topFarm.name + (topFarm.note ? ` (${topFarm.note})` : ""), id: topFarm.id, amount: topFarm.value, per: `por ${topFarm.per}`,
      note: `${topFarm.label} · con ${sourceText(topFarm.source)}`}
      : {key: "farm", label: "Qué farmear", target: "#farm-section", good: false, name: "Sin datos", id: null, amount: null, per: "", note: "Todavía no hay precios de lo que se recolecta."},
    buy ? {key: "resale", label: "Qué comprar para revender", target: "#resale-section", good: true, name: buy.name, id: buy.id, amount: buy.flip.profit, per: "de ganancia",
      note: `Compra ${buy.flip.units}× a ${formatGSC(buy.flip.maxBuy)} como máximo`}
      : {key: "resale", label: "Qué comprar para revender", target: "#resale-section", good: false, name: "Hoy, nada", id: null, amount: null, per: "",
        note: noBuy + (nearest && summary.phase === "normal" ? ` Lo más cerca: ${nearest.name}, a ${formatPct(nearest.gapBp)} de lo máximo que compensa pagar.` : "")},
    pays ? {key: "smelt", label: "Qué fundir", target: "#smelt-section", good: true, name: pays.name, id: pays.id, amount: pays.unitProfit, per: "por lingote",
      note: `Lote de ${pays.flip.units}: ganas ≈ ${formatGSC(pays.flip.profit)}`}
      : {key: "smelt", label: "Qué fundir", target: "#smelt-section", good: false, name: topSmelt?.label === "Orientativo" ? topSmelt.name : "Hoy, nada", id: topSmelt?.label === "Orientativo" ? topSmelt.id : null,
        amount: topSmelt?.label === "Orientativo" ? topSmelt.unitProfit : null, per: topSmelt?.label === "Orientativo" ? "por lingote" : "",
        note: !topSmelt ? "Faltan precios recientes de los materiales." : topSmelt.label !== "Orientativo" ? `Lo mejor: ${topSmelt.name}, ${formatGSC(topSmelt.unitProfit)} por lingote.`
          : topSmelt.stale ? "Orientativo: hoy aún no se han escaneado los materiales y se usa su precio de los últimos días." : "Orientativo: con precios de lanzamiento no es una recomendación de compra."}];
}

/** The balance map: one mark per item with a normal price and a price today, x its price against normal (dBp) and y how
 * much it varies (sBp), over the areas where especular.assess calls a trusted price chollo or caro: at least 20 % below or
 * 25 % above, and 2,5 times the variation when that is more, up to the 25 % variation that stops being trusted.
 * Values beyond the axes stay at their edge. Returns null without such items, else {node, layout: {points: [{e, x, y}]
 * (by x), x0, x1, y0, y1}} for the hover layer. */
export function marketMapSVG({items = [], width = 720, height = 360} = {}) {
  const list = items.filter(e => isInt(e.dBp) && isInt(e.sBp));
  if (list.length === 0) return null;
  const loX = Math.max(-9000, Math.min(-3000, ...list.map(e => e.dBp - 300))), hiX = Math.min(10000, Math.max(3500, ...list.map(e => e.dBp + 300)));
  const hiY = Math.min(6000, Math.max(2000, ...list.map(e => e.sBp))) * 1.08;
  const x0 = 46, x1 = width - 12, y0 = 26, y1 = height - 46;
  const x = v => round1(x0 + (x1 - x0) * (Math.max(loX, Math.min(hiX, v)) - loX) / (hiX - loX));
  const y = v => round1(y1 - (y1 - y0) * Math.min(hiY, v) / hiY);
  const trusted = Math.min(2500, hiY), edgeLo = Math.min(trusted, -loX / 2.5), edgeHi = Math.min(trusted, hiX / 2.5);
  const polygon = points => points.map(([a, b]) => `${x(a)},${y(b)}`).join(" ");
  const narrow = width < 480;
  const xTicks = niceTicks(loX, hiX, narrow ? 4 : 7).filter(t => t >= loX && t <= hiX), yTicks = niceTicks(0, hiY, 4).filter(t => t >= 0 && t <= hiY);
  const points = list.map(e => ({e, x: x(e.dBp), y: y(e.sBp)})).sort((a, b) => a.x - b.x || a.y - b.y || a.e.id - b.e.id);
  const groups = {rest: [], up: [], good: []};
  for (const p of points) groups[p.e.verdict === "CHOLLO" ? "good" : p.e.verdict === "CARO" ? "up" : "rest"].push(p);
  // Labels only for what stands out: chollos, then caros, then the cheapest; none on top of another.
  const placed = [];
  const labelled = [...groups.good, ...groups.up, ...groups.rest].slice(0, narrow ? 3 : 6).flatMap(p => {
    const name = nameOf(p.e), text = name.length > 22 ? name.slice(0, 21) + "…" : name;
    const room = text.length * 7, right = p.x + 9 + room <= x1;
    const box = {left: right ? p.x + 9 : p.x - 9 - room, right: right ? p.x + 9 + room : p.x - 9, y: p.y};
    if (placed.some(o => Math.abs(o.y - box.y) < 16 && box.left < o.right && o.left < box.right)) return [];
    placed.push(box);
    return [h("text", {x: right ? p.x + 9 : p.x - 9, y: round1(p.y + 4), "text-anchor": right ? "start" : "end", fill: CHART.text, stroke: CHART.surface, "stroke-width": 3, "paint-order": "stroke"}, text)];
  });
  const node = h("svg", {class: "market-map", viewBox: `0 0 ${width} ${height}`, width, height, role: "img",
    "aria-label": `Balance de ${plural(list.length, "objeto", "objetos")}: ${plural(groups.good.length, "chollo", "chollos")} y ${plural(groups.up.length, "caro", "caros")}. Los valores están también en la tabla de debajo.`},
    h("polygon", {class: "zone-good", points: polygon([[loX, 0], [-2000, 0], [-2000, 800], [-2.5 * edgeLo, edgeLo], [loX, edgeLo]]), fill: CHART.good, "fill-opacity": 0.12}),
    h("polygon", {class: "zone-up", points: polygon([[hiX, 0], [2500, 0], [2500, 1000], [2.5 * edgeHi, edgeHi], [hiX, edgeHi]]), fill: CHART.up, "fill-opacity": 0.12}),
    h("g", {class: "grid"}, yTicks.map(t => h("line", {x1: x0, x2: x1, y1: y(t), y2: y(t), stroke: CHART.grid, "stroke-width": 1}))),
    h("line", {class: "normal-line", x1: x(0), x2: x(0), y1: y0, y2: y1, stroke: CHART.normal, "stroke-width": 1}),
    h("g", {class: "y-labels", "font-size": 12, fill: CHART.muted, "text-anchor": "end"}, yTicks.map(t => h("text", {x: x0 - 6, y: round1(y(t) + 4)}, `${rules().texts.pct(t)} %`))),
    h("g", {class: "x-labels", "font-size": 12, fill: CHART.muted, "text-anchor": "middle"}, xTicks.map(t => h("text", {x: x(t), y: y1 + 18}, formatPct(t)))),
    h("g", {class: "axis-titles", "font-size": 12, fill: CHART.muted},
      h("text", {x: 4, y: 14}, "Cuánto varía su precio"), h("text", {x: x1, y: height - 8, "text-anchor": "end"}, "Hoy frente a su precio normal")),
    h("g", {class: "rest"}, groups.rest.map(p => h("circle", {cx: p.x, cy: p.y, r: 4, fill: CHART.normal, stroke: CHART.surface, "stroke-width": 2}))),
    h("g", {class: "up"}, groups.up.map(p => h("rect", {x: round1(p.x - 5), y: round1(p.y - 5), width: 10, height: 10, transform: `rotate(45 ${p.x} ${p.y})`, fill: CHART.up, stroke: CHART.surface, "stroke-width": 2}))),
    h("g", {class: "good"}, groups.good.map(p => h("circle", {cx: p.x, cy: p.y, r: 6, fill: CHART.good, stroke: CHART.surface, "stroke-width": 2}))),
    h("g", {class: "labels", "font-size": 12}, labelled),
    h("circle", {class: "focus-ring", cx: x0, cy: y1, r: 9, fill: "none", stroke: CHART.text, "stroke-width": 2, visibility: "hidden"}),
    h("rect", {class: "hit", x: 0, y: 0, width, height, fill: "transparent"}));
  return {node, layout: {points, x0, x1, y0, y1}};
}

// =================================================================================================================
// Page (browser only)
// =================================================================================================================
function boot(doc, win) {
  const $ = selector => doc.querySelector(selector);
  const state = {me: null, csrf: "", market: null, summary: null, detail: null, filters: {q: "", cat: "", show: "", conf: ""},
    sort: {key: "", dir: "asc"}, view: "hoy", lastUpload: null, pollTimer: null, members: null, busy: false,
    compensa: {prof: "", skill: "", budget: "", rare: false, cat: ""}, favorites: new Set()};
  let toastTimer;
  let cartera = null;
  /** The portfolio tab, while the owner is the one signed in: this page may stay open after they log out. */
  const owned = () => state.me?.isOwner ? cartera : null;
  try { state.favorites = new Set(parseFavorites(win.localStorage.getItem("hermandad.lista"))); } catch { /* private mode */ }

  // ---- tiny DOM helpers
  function el(tag, props = {}, ...children) {
    const node = doc.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else if (k in node && typeof v !== "string") node[k] = v;
      else node.setAttribute(k, v === true ? "" : v);
    }
    for (const child of children.flat()) if (child !== null && child !== undefined && child !== false) node.append(typeof child === "string" ? doc.createTextNode(child) : child);
    return node;
  }
  function money(copper, className = "money") {
    const parts = gscParts(copper);
    if (!parts) return el("span", {class: className + " none", text: "—"});
    const node = el("span", {class: className});
    if (parts.negative) node.append("−");
    parts.parts.forEach((p, i) => { if (i) node.append(" "); node.append(p.value, el("span", {class: "coin coin-" + p.unit, text: p.unit})); });
    return node;
  }
  function pctNode(bp) {
    return el("span", {class: "pct" + (isInt(bp) ? bp > 0 ? " up" : bp < 0 ? " down" : "" : " none"), text: formatPct(bp)});
  }
  const svg = node => toDOM(node, doc);
  function toast(message, isError = false) {
    const node = $("#toast");
    node.textContent = message;
    node.classList.toggle("error", isError);
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.hidden = true; }, isError ? 9000 : 5000);
  }

  class PanelError extends Error { constructor(message, status) { super(message); this.status = status; } }
  async function request(path, data) {
    const options = {headers: {Accept: "application/json"}, cache: "no-store", credentials: "same-origin"};
    if (data !== undefined) {
      options.method = "POST";
      options.headers["Content-Type"] = "application/json";
      options.headers["X-CSRF-Token"] = state.csrf || "";
      options.body = JSON.stringify(data);
    }
    let response;
    try { response = await win.fetch(path, options); }
    catch { throw new PanelError("No se puede conectar con el panel. Comprueba tu conexión y vuelve a intentarlo.", 0); }
    let body = null;
    try { body = await response.json(); } catch { /* handled below */ }
    if (!response.ok || !body || body.error) throw new PanelError(body?.error || `No se ha podido completar la petición (${response.status}).`, response.status);
    return body;
  }
  function handle(error) {
    if (error?.status === 401) return showLogin("Tu sesión ha terminado o tu clave ya no es válida. Vuelve a entrar con tu clave o contraseña.");
    if (error?.status === 503) return showFatal(error.message);
    toast(error?.message || "No se ha podido completar la operación.", true);
  }

  // ---- views
  const VIEWS = ["hoy", "mercado", "compensa", "balance", "cartera", "hermandad"];
  const VIEW_ALIASES = {miembros: "hermandad", unirse: "hermandad"};
  const VIEWS_WITH_MARKET = ["hoy", "mercado", "compensa", "balance", "cartera"];
  function showOnly(id) {
    const ids = [].concat(id);
    for (const section of doc.querySelectorAll("[data-screen]")) section.hidden = !ids.includes(section.id);
  }
  function showLogin(message = "") {
    stopPolling();
    state.me = null; state.csrf = "";
    cartera?.unmount();
    $("#tab-cartera").hidden = true; $("#hoy-cartera").hidden = true;
    if ($("#movement").open) $("#movement").close();
    $("#account").hidden = true; $("#tabs").hidden = true; $("#market-bar").hidden = true;
    showOnly("screen-login");
    $("#key-value").value = ""; $("#key-panel").hidden = true;
    $("#login-feedback").textContent = message;
    if ($("#detail").open) $("#detail").close();
    $("#login-key").focus();
  }
  function showFatal(message) {
    stopPolling();
    $("#account").hidden = true; $("#tabs").hidden = true; $("#market-bar").hidden = true;
    showOnly("screen-fatal");
    $("#fatal-message").textContent = message;
  }
  function route() {
    const hash = win.location.hash.replace(/^#/, "");
    const item = /^objeto-(\d{1,10})$/.exec(hash);
    // An item opens over the current view; any other hash picks a view.
    const wanted = VIEW_ALIASES[hash] ?? hash;
    let view = item ? state.view : VIEWS.includes(wanted) ? wanted : "hoy";
    if (view === "cartera" && !state.me?.isOwner) view = "hoy";
    state.view = view;
    for (const tab of doc.querySelectorAll("#tabs a")) {
      const active = tab.dataset.tab === view;
      tab.classList.toggle("active", active);
      if (active) tab.setAttribute("aria-current", "page"); else tab.removeAttribute("aria-current");
    }
    showOnly(view === "hermandad" ? (state.me?.canAdmin ? ["screen-miembros", "screen-unirse"] : ["screen-unirse"]) : "screen-" + view);
    $("#market-bar").hidden = !VIEWS_WITH_MARKET.includes(view);
    if (view === "hermandad" && state.me?.canAdmin) loadMembers();
    if (view === "compensa") renderCompensa();
    if (view === "cartera") owned()?.load();
    if (item && state.summary) openDetail(Number(item[1]));
    else if (!item && $("#detail").open) $("#detail").close();
  }

  // ---- login and account
  $("#login-form").addEventListener("submit", async event => {
    event.preventDefault();
    const input = $("#login-key"), button = $("#login-submit");
    const key = input.value.trim();
    // One field for everybody: a guild key never reaches the owner's login, and a password never reaches the guild's.
    const isKey = key.startsWith("gld_");
    if (!key) { $("#login-feedback").textContent = "Escribe tu clave de la hermandad o tu contraseña."; input.focus(); return; }
    if (isKey && !/^gld_[A-Za-z0-9_-]{43}$/.test(key)) { $("#login-feedback").textContent = "La clave empieza por gld_ y tiene 47 caracteres. Cópiala entera, sin espacios."; input.focus(); return; }
    button.disabled = true; $("#login-feedback").textContent = "";
    try {
      if (isKey) state.csrf = (await request("/api/guild/login", {key})).csrf;
      else await ownerLogin(input.value);
      input.value = "";
      await start();
    } catch (error) {
      $("#login-feedback").textContent = error.status === 503 ? error.message : error.message || "No se ha podido entrar.";
      input.focus();
    } finally { button.disabled = false; }
  });
  async function ownerLogin(password) {
    let response;
    try {
      response = await win.fetch("/api/login", {method: "POST", credentials: "same-origin", cache: "no-store",
        headers: {"Content-Type": "application/json", Accept: "application/json"}, body: JSON.stringify({password})});
    } catch { throw new PanelError("No se puede conectar con el panel. Comprueba tu conexión y vuelve a intentarlo.", 0); }
    let body = null;
    try { body = await response.json(); } catch { /* handled below */ }
    if (!response.ok || !body || body.error) throw new PanelError(body?.error || `No se ha podido entrar (${response.status}).`, response.status);
  }
  /** The owner's session has its own CSRF token, which only the owner's state gives. */
  async function ownerLogout() {
    const options = {credentials: "same-origin", cache: "no-store", headers: {Accept: "application/json"}};
    const owner = await (await win.fetch("/api/state", options)).json();
    await win.fetch("/api/logout", {...options, method: "POST", headers: {"Content-Type": "application/json", "X-CSRF-Token": owner.token ?? ""}, body: "{}"});
  }
  $("#login-show").addEventListener("change", event => { $("#login-key").type = event.target.checked ? "text" : "password"; });
  $("#logout").addEventListener("click", async () => {
    const owner = state.me?.isOwner;
    try { await request("/api/guild/logout", {}); } catch { /* the cookie may already be gone */ }
    if (owner) { try { await ownerLogout(); } catch { /* the session may already be gone */ } }
    showLogin("Has cerrado la sesión.");
  });

  async function start() {
    let me;
    try { me = await request("/api/guild/me"); }
    catch (error) { return error.status === 401 ? showLogin("") : showFatal(error.message); }
    applyMe(me);
    if (me.isOwner) await mountCartera();
    let saved = null;
    try { saved = win.localStorage.getItem("hermandad.market"); } catch { /* private mode */ }
    const names = me.markets.map(m => m.market);
    state.market = names.includes(saved) ? saved : names[0] ?? null;
    renderMarketSelect();
    await loadMarket();
    route();
    startPolling();
  }
  /** The portfolio tab loads only for the owner: the Worker refuses this file without the owner's session. */
  async function mountCartera() {
    try {
      if (!cartera) {
        const module = await import("./cartera.js");
        cartera = module.mountCartera({doc, win, $, el, money, toast, handle, formatGSC, parseGSC, formatWhen, plural, itemButton, summary: () => state.summary});
      }
      await cartera.load();
    } catch { toast("No se ha podido cargar tu cartera. Recarga la página.", true); }
  }
  function applyMe(me) {
    state.me = me; state.csrf = me.csrf || state.csrf;
    $("#account").hidden = false; $("#tabs").hidden = false;
    $("#tab-cartera").hidden = !me.isOwner;
    const who = me.isOwner ? "Propietario" : `${me.member?.label ?? "Miembro"} · ${me.role === "admin" ? "administra" : "miembro"}`;
    $("#who").textContent = who;
    $("#panel-url").value = win.location.origin + "/hermandad";
  }

  // ---- polling: /me every minute (revocation logs out); the market again when someone uploaded
  function startPolling() {
    stopPolling();
    state.pollTimer = win.setInterval(poll, 60000);
  }
  function stopPolling() { if (state.pollTimer) win.clearInterval(state.pollTimer); state.pollTimer = null; }
  async function poll() {
    if (doc.hidden || !state.me) return;
    try {
      const me = await request("/api/guild/me");
      applyMe(me);
      const known = state.me.markets.map(m => m.market);
      if (!state.market && known.length) { state.market = known[0]; renderMarketSelect(); await loadMarket(); return; }
      renderMarketSelect();
      const current = me.markets.find(m => m.market === state.market);
      if (current && current.lastUploadAt !== state.lastUpload) await loadMarket();
      else renderFreshness();
    } catch (error) { if (error.status === 401 || error.status === 503) handle(error); }
  }
  doc.addEventListener("visibilitychange", () => { if (!doc.hidden && state.me) poll(); });

  // ---- market selection and summary
  function renderMarketSelect() {
    const select = $("#market");
    const markets = state.me?.markets ?? [];
    const signature = JSON.stringify([markets.map(m => [m.market, m.items]), state.market]);
    if (select.dataset.signature === signature) return;
    select.dataset.signature = signature;
    select.replaceChildren(...markets.map(m => el("option", {value: m.market, text: `${m.market.replace(/-(Alliance|Horde)$/, (_, f) => f === "Alliance" ? " · Alianza" : " · Horda")} (${plural(m.items, "objeto", "objetos")})`})));
    select.value = state.market ?? "";
    select.disabled = markets.length < 2;
    $("#market-wrap").hidden = markets.length === 0;
  }
  $("#market").addEventListener("change", async event => {
    state.market = event.target.value;
    try { win.localStorage.setItem("hermandad.market", state.market); } catch { /* private mode */ }
    await loadMarket();
  });
  // The previous render stays (dimmed) while it reloads, so nothing jumps.
  async function loadMarket() {
    if (!state.market) { state.summary = null; renderMarket(); return; }
    const frames = [$("#screen-hoy"), $("#screen-mercado"), $("#screen-compensa")];
    for (const frame of frames) { frame.setAttribute("aria-busy", "true"); frame.classList.add("refreshing"); }
    try {
      const summary = await request(`/api/guild/market?market=${encodeURIComponent(state.market)}`);
      state.summary = summary;
      state.lastUpload = summary.freshness?.lastUploadAt ?? null;
      renderMarket();
    } catch (error) {
      if (error.status === 404) { state.summary = null; renderMarket(); }
      else handle(error);
    } finally { for (const frame of frames) { frame.removeAttribute("aria-busy"); frame.classList.remove("refreshing"); } }
  }
  function renderFreshness() {
    const s = state.summary, me = state.me;
    const strip = $("#freshness");
    if (!s) { strip.textContent = me ? freshnessLine(null, me.dayOfLaunch, Date.now()) : ""; return; }
    strip.textContent = freshnessLine(s.freshness, s.dayOfLaunch, Date.now());
    const f = s.freshness ?? {};
    strip.title = f.lastUploadAt ? `Último envío: ${f.lastUploadBy ?? "un compañero"}, ${formatWhen(f.lastUploadAt, Date.now())} · hoy ${plural(f.contributorsToday ?? 0, "miembro ha enviado", "miembros han enviado")} precios` +
      (isInt(f.observersToday) ? ` · hoy aportan ${plural(f.observersToday, "persona", "personas")} (también quienes solo comparten sus escaneos desde el juego)` : "") : "";
  }
  function renderExports() {
    const base = `/api/guild/export.csv?market=${encodeURIComponent(state.market ?? "")}`;
    $("#csv-summary").href = base + "&kind=summary";
    $("#csv-daily").href = base + "&kind=daily&days=60";
  }
  function renderMarket() {
    renderFreshness();
    const s = state.summary;
    $("#market-empty").hidden = !!s;
    $("#market-content").hidden = !s;
    $("#balance-empty").hidden = !!s;
    $("#balance-content").hidden = !s;
    $("#compensa-empty").hidden = !!s;
    $("#compensa-content").hidden = !s;
    if (!s) {
      $("#market-empty-text").textContent = state.me?.markets?.length
        ? "Todavía no hay datos de ese mercado."
        : "Todavía nadie de la hermandad ha subido precios. Cuando alguien escanee la subasta y el sincronizador de su PC envíe los datos, aparecerán aquí.";
      $("#market-empty-admin").hidden = !state.me?.canAdmin;
      $("#banners").replaceChildren();
      $("#compensa-banners").replaceChildren();
      $("#tab-balance").hidden = true;
      renderHoy();
      return;
    }
    renderExports();
    const banners = () => marketBanners(s).map(b => el("div", {class: "banner banner-" + b.kind, role: "status"},
      el("span", {class: "banner-icon", "aria-hidden": "true", text: b.kind === "falling" ? "↘" : b.kind === "rising" ? "↗" : b.kind === "learning" ? "◷" : "⚑"}),
      el("p", {}, el("strong", {text: b.title + ". "}), b.text)));
    $("#banners").replaceChildren(...banners());
    $("#compensa-banners").replaceChildren(...banners());
    $("#hoy-banners").replaceChildren(...banners());
    $("#caveat").textContent = `Recuerda: ${s.caveat}. Los cálculos son estimaciones con los precios que la hermandad ha visto; confírmalos siempre en la subasta.`;
    $("#compensa-caveat").textContent = $("#caveat").textContent;
    renderChollos();
    renderCategoryFilter();
    renderTable();
    renderBalance();
    renderHoy();
    if (state.view === "compensa") renderCompensa();
  }

  // ---- "Chollos de hoy"
  function renderChollos() {
    const s = state.summary, byId = new Map(s.items.map(e => [e.id, e]));
    const list = s.chollos.map(id => byId.get(id)).filter(Boolean);
    $("#chollos-count").textContent = String(list.length);
    $("#chollos-empty").hidden = list.length > 0;
    $("#chollos-empty").textContent = list.length ? "" : cholloEmptyText(s);
    $("#chollos-list").hidden = list.length === 0;
    $("#chollos-list").replaceChildren(...list.map(e => {
      const f = e.flip;
      const figures = f && f.units > 0 ? el("dl", {class: "figures"},
        el("div", {}, el("dt", {text: "Unidades"}), el("dd", {text: String(f.units)})),
        el("div", {}, el("dt", {text: "Compra máx."}), el("dd", {}, money(f.maxBuy))),
        el("div", {}, el("dt", {text: "Equilibrio"}), el("dd", {}, money(f.breakEven))),
        el("div", {}, el("dt", {text: "Ganancia"}), el("dd", {}, money(f.profit)))) : null;
      return el("li", {class: "chollo" + (f?.accept ? "" : " weak")},
        el("div", {class: "chollo-head"},
          el("button", {type: "button", class: "item-link", text: e.name || `Objeto ${e.id}`, onclick: () => navigateItem(e.id)}),
          el("span", {class: "badge verdict-CHOLLO", text: f?.accept ? "Chollo" : "Chollo · no compensa"})),
        el("p", {class: "chollo-price"}, money(e.price?.lo), el("span", {class: "muted", text: ` · ${(e.statusText || "").replace(/^Chollo: /, "")}`})),
        el("p", {class: "seen muted", text: `Visto por ${f?.who ?? e.price?.member ?? "un compañero"}, ${formatWhen(f?.at ?? e.price?.at, Date.now())} · normal ${formatGSC(e.N)}`}),
        figures,
        owned() ? el("p", {class: "row"}, el("button", {type: "button", class: "button subtle small", text: "Registrar compra", onclick: () => owned()?.openMovement("buy", {itemId: e.id, name: e.name, unit: e.price?.lo})})) : null,
        el("p", {class: "flip-text", text: f?.accept
          ? `Objetivo de reventa ${formatGSC(f.Rs)} · tras la comisión del ${rules().texts.pct(f.cutBp ?? s.cutBp)} % y un depósito perdido${f.depositEstimated ? " (estimado)" : ""}`
          : rules().texts.flip(f, formatGSC)}),
        el("p", {class: "estimate", text: "estimado: confírmalo en la subasta"}));
    }));
  }

  // ---- the market table
  function renderCategoryFilter() {
    const select = $("#filter-cat");
    const cats = groupByCategory(state.summary.items).map(g => ({cat: g.cat, label: g.items[0].catLabel ?? g.cat, n: g.items.length}));
    select.replaceChildren(el("option", {value: "", text: "Todas las categorías"}), ...cats.map(c => el("option", {value: c.cat, text: `${c.label} (${c.n})`})));
    select.value = cats.some(c => c.cat === state.filters.cat) ? state.filters.cat : "";
    state.filters.cat = select.value;
  }
  for (const [id, key] of [["#filter-q", "q"], ["#filter-cat", "cat"], ["#filter-show", "show"], ["#filter-conf", "conf"]]) {
    $(id).addEventListener(id === "#filter-q" ? "input" : "change", event => { state.filters[key] = event.target.value; if (state.summary) renderTable(); });
  }
  // Each header cycles: its natural order (names A-Z, biggest drops first, the rest highest first), the reverse, and
  // back to the grouped category order.
  const firstDir = key => key === "name" || key === "d1" || key === "d7" ? "asc" : "desc";
  for (const th of doc.querySelectorAll("#market-table th[data-sort]")) {
    th.querySelector("button").addEventListener("click", () => {
      const key = th.dataset.sort;
      if (state.sort.key !== key) state.sort = {key, dir: firstDir(key)};
      else if (state.sort.dir === firstDir(key)) state.sort.dir = state.sort.dir === "asc" ? "desc" : "asc";
      else state.sort = {key: "", dir: "asc"};
      renderTable();
    });
  }
  $("#csv-view").addEventListener("click", () => {
    const rows = sortItems(filterItems(state.summary?.items, {...state.filters, favorites: state.favorites}), state.sort);
    download(csvRows(SUMMARY_COLUMNS, rows), `Hermandad_${(state.market ?? "").replace(/[^A-Za-z0-9_-]+/g, "_")}_vista_${state.summary?.date ?? ""}.csv`);
  });
  function download(text, name) {
    const url = URL.createObjectURL(new Blob([text], {type: "text/csv;charset=utf-8"}));
    const link = el("a", {href: url, download: name});
    doc.body.append(link); link.click(); link.remove();
    win.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function renderTable() {
    const s = state.summary;
    const rows = sortItems(filterItems(s.items, {...state.filters, favorites: state.favorites}), state.sort);
    for (const th of doc.querySelectorAll("#market-table th[data-sort]")) {
      const active = th.dataset.sort === state.sort.key;
      th.setAttribute("aria-sort", active ? (state.sort.dir === "asc" ? "ascending" : "descending") : "none");
      th.querySelector(".sort-mark").textContent = active ? (state.sort.dir === "asc" ? "▲" : "▼") : "";
    }
    $("#table-count").textContent = rows.length === s.items.length ? plural(s.items.length, "objeto", "objetos") : `${rows.length} de ${plural(s.items.length, "objeto", "objetos")}`;
    $("#table-empty").hidden = rows.length > 0;
    const body = $("#market-body");
    const grouped = state.sort.key === "";
    const groups = grouped ? groupByCategory(rows) : [{cat: null, items: rows}];
    body.replaceChildren(...groups.flatMap(g => [
      g.cat ? el("tr", {class: "group"}, el("th", {colspan: "11", scope: "colgroup", text: `${g.items[0].catLabel ?? g.cat} · ${g.items.length}`})) : null,
      ...g.items.map(row)]).filter(Boolean));
  }
  // ---- the player's list: the stars, kept in this browser
  function paintStar(node, id) {
    const on = state.favorites.has(id), name = node.dataset.name;
    node.classList.toggle("on", on);
    node.textContent = on ? "★" : "☆";
    node.setAttribute("aria-pressed", on ? "true" : "false");
    node.setAttribute("aria-label", on ? `Quitar ${name} de mi lista` : `Añadir ${name} a mi lista`);
    node.title = on ? "Quitar de mi lista" : "Añadir a mi lista";
  }
  function starButton(id, name) {
    const node = el("button", {type: "button", class: "star", "data-star": String(id), "data-name": name || `Objeto ${id}`, onclick: () => toggleFavorite(id)});
    paintStar(node, id);
    return node;
  }
  function toggleFavorite(id) {
    if (state.favorites.has(id)) state.favorites.delete(id); else state.favorites.add(id);
    try { win.localStorage.setItem("hermandad.lista", JSON.stringify([...state.favorites])); } catch { /* private mode */ }
    for (const node of doc.querySelectorAll(`[data-star="${id}"]`)) paintStar(node, id);
    if (state.summary) { if (state.filters.show === "favoritos") renderTable(); renderHoy(); }
  }

  function row(e) {
    const range = isInt(e.min14) ? el("span", {class: "range"}, money(e.min14), el("span", {class: "muted", text: " – "}), money(e.max14)) : el("span", {class: "none", text: "—"});
    const nameCell = el("th", {scope: "row", class: "name-cell"},
      starButton(e.id, e.name),
      el("button", {type: "button", class: "item-link", text: e.name || `Objeto ${e.id}`, onclick: () => navigateItem(e.id)}),
      state.sort.key ? el("span", {class: "cat-tag", text: e.catLabel ?? e.cat}) : null);
    const today = e.price ? el("td", {class: "num", title: `Más bajo visto hoy por ${e.price.member ?? "un compañero"}, ${formatWhen(e.price.at, Date.now())}`}, money(e.price.lo)) : el("td", {class: "num"}, el("span", {class: "none", text: "—"}));
    return el("tr", {class: e.verdict === "CHOLLO" ? "is-chollo" : e.verdict === "CARO" ? "is-caro" : null},
      nameCell, today,
      el("td", {class: "num"}, money(e.N)),
      el("td", {class: "num"}, pctNode(e.d1)),
      el("td", {class: "num"}, pctNode(e.d7)),
      el("td", {class: "num"}, range),
      el("td", {class: "spark-cell"}, svg(sparklineSVG(e.spark))),
      el("td", {class: "num", text: formatUnits(e.Q)}),
      el("td", {class: "num", text: isInt(e.members) && e.n > 0 ? String(e.members) : "—"}),
      el("td", {}, el("span", {class: "conf conf-" + (e.conf ?? "NONE"), title: e.confText, text: e.conf ? e.confLabel : `Aprendiendo ${e.n ?? 0}/7`})),
      el("td", {}, el("span", {class: "badge verdict-" + e.verdict, title: e.statusText, text: e.verdictLabel})));
  }

  // ---- weekly balance
  function renderBalance() {
    const b = state.summary.balance;
    const known = b.categories.filter(c => isInt(c.index));
    $("#tab-balance").hidden = known.length === 0;
    $("#balance-none").hidden = known.length > 0;
    $("#balance-grid").hidden = known.length === 0;
    if (!known.length) return;
    const maxAbs = Math.max(100, ...known.map(c => Math.abs(c.index)));
    $("#balance-cats").replaceChildren(...b.categories.map(c => {
      const width = isInt(c.index) && c.index !== 0 ? Math.max(2, Math.round(50 * Math.abs(c.index) / maxAbs)) : 0;
      const bar = el("span", {class: "bar " + (isInt(c.index) ? c.index < 0 ? "down" : "up" : "")});
      bar.style.width = width + "%";
      if (isInt(c.index) && c.index < 0) bar.style.right = "50%"; else bar.style.left = "50%";
      return el("li", {},
        el("span", {class: "cat-label", text: c.label}),
        el("span", {class: "track", "aria-hidden": "true"}, el("span", {class: "zero"}), width ? bar : null),
        el("span", {class: "cat-value"}, pctNode(c.index), el("span", {class: "muted", text: ` · ${plural(c.items, "objeto", "objetos")}`})));
    }));
    const list = (items, empty) => items.length ? items.map(i => el("li", {},
      el("button", {type: "button", class: "item-link", text: i.name || `Objeto ${i.id}`, onclick: () => navigateItem(i.id)}),
      pctNode(i.d7), el("span", {class: "conf conf-" + i.conf, text: i.conf === "ALTA" ? "Fiable" : "Orientativo"}))) : [el("li", {class: "muted", text: empty})];
    $("#risers").replaceChildren(...list(b.risers, "Ningún objeto fiable ha subido esta semana."));
    $("#fallers").replaceChildren(...list(b.fallers, "Ningún objeto fiable ha bajado esta semana."));
  }

  // ---- "Qué compensa": everything is worked out here from the summary, so the filters answer at once
  const COMPENSA_SAVED = [["#farm-prof", "prof"], ["#farm-skill", "skill"], ["#resale-budget", "budget"]];
  try {
    const saved = JSON.parse(win.localStorage.getItem("hermandad.compensa") ?? "{}");
    for (const [id, key] of COMPENSA_SAVED) if (typeof saved?.[key] === "string") { $(id).value = saved[key]; state.compensa[key] = $(id).value; }
  } catch { /* private mode or an old value */ }
  for (const [id, key] of COMPENSA_SAVED) {
    $(id).addEventListener(id === "#farm-prof" ? "change" : "input", event => {
      state.compensa[key] = event.target.value;
      try { win.localStorage.setItem("hermandad.compensa", JSON.stringify({prof: state.compensa.prof, skill: state.compensa.skill, budget: state.compensa.budget})); } catch { /* private mode */ }
      renderCompensa();
    });
  }
  $("#farm-rare").addEventListener("change", event => { state.compensa.rare = event.target.checked; renderCompensa(); });
  $("#map-cat").addEventListener("change", event => { state.compensa.cat = event.target.value; if (state.summary) renderMap(); });
  // The map is drawn at its real width, so its text stays at 12 px: it is redrawn when that width changes.
  let mapWidth = 0, resizeTimer;
  win.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { if (state.view === "compensa" && state.summary && $("#map-holder").clientWidth !== mapWidth) renderMap(); }, 150);
  });

  /** The rows of "Qué compensa" with the player's filters; the home tab shows the same three best cards. */
  function compensaRows() {
    const s = state.summary, filters = state.compensa;
    const skillText = filters.skill.trim(), budgetText = filters.budget.trim();
    const skill = /^\d{1,3}$/.test(skillText) ? Number(skillText) : null;
    const typed = budgetText ? parseGSC(budgetText) : null, typedOk = typed !== null && typed >= 1 && typed <= 100000000000;
    const budget = typedOk ? typed : s.budget;
    return {budgetBad: !!budgetText && !typedOk, farm: farmRows(s, {prof: filters.prof, skill, rare: filters.rare}), resale: resaleRows(s, {budget}), smelt: smeltRows(s, {budget})};
  }
  function bestCardNode(c, onJump) {
    return el("li", {class: "best-card" + (c.good ? " is-good" : "")},
      el("span", {class: "eyebrow", text: c.label}),
      c.id !== null ? itemButton(c.id, c.name, "item-link best-name") : el("span", {class: "best-name", text: c.name}),
      isInt(c.amount) ? el("span", {class: "best-amount"}, money(c.amount), " ", el("small", {text: c.per})) : null,
      el("span", {class: "best-note", text: c.note}),
      el("button", {type: "button", class: "jump", text: "Ver el detalle", onclick: onJump}));
  }
  function renderCompensa() {
    const s = state.summary, filters = state.compensa;
    if (!s) return;
    $("#resale-budget").placeholder = formatGSC(s.budget);
    const {budgetBad, farm, resale, smelt} = compensaRows();
    $("#resale-feedback").textContent = budgetBad ? "Presupuesto: escribe un importe como 100g." : "";
    $("#best-cards").replaceChildren(...bestCards(s, farm, resale, smelt).map(c => bestCardNode(c, () => $(c.target).scrollIntoView())));
    renderFarm(farm);
    renderResale(resale);
    renderSmelt(smelt);
    const select = $("#map-cat");
    const cats = groupByCategory(s.items).map(g => ({cat: g.cat, label: g.items[0].catLabel ?? g.cat, n: g.items.length}));
    select.replaceChildren(el("option", {value: "", text: "Todas las categorías"}), ...cats.map(c => el("option", {value: c.cat, text: `${c.label} (${c.n})`})));
    select.value = cats.some(c => c.cat === filters.cat) ? filters.cat : "";
    filters.cat = select.value;
    renderMap();
  }
  const itemButton = (id, name, className = "item-link") => el("button", {type: "button", class: className, text: name, onclick: () => navigateItem(id)});
  const num = (...children) => el("td", {class: "num"}, ...children);
  const cell = (...children) => el("td", {}, ...children);
  /** A chart's table twin: headers [[text, numeric]], rows of cells whose first one is the row header. */
  function twinTable(headers, rows) {
    return el("div", {class: "table-scroll"}, el("table", {},
      el("thead", {}, el("tr", {}, ...headers.map(([text, numeric]) => el("th", {scope: "col", class: numeric ? "num" : null, text})))),
      el("tbody", {}, ...rows.map(([first, ...cells]) => el("tr", {}, el("th", {scope: "row"}, first), ...cells)))));
  }
  function rankRow({id, name, tag, track, value, detail}) {
    return el("li", {class: "rank-row"},
      el("div", {class: "rank-name"}, itemButton(id, name), tag ? el("span", {class: "rank-tag", text: tag}) : null),
      el("div", {"aria-hidden": "true"}, track),
      el("div", {class: "rank-value"}, ...value),
      detail ? el("p", {class: "rank-detail", text: detail}) : null);
  }
  /** A bar from the middle line: to the right when value > 0; maxAbs fills half of the track. */
  function divergingTrack(value, maxAbs, tone) {
    const track = el("span", {class: "track"}, el("span", {class: "zero"}));
    if (!isInt(value) || value === 0) return track;
    const bar = el("span", {class: `bar tone-${tone} ${value < 0 ? "to-left" : "to-right"}`});
    bar.style.width = Math.max(2, Math.round(50 * Math.min(1, Math.abs(value) / maxAbs))) + "%";
    if (value < 0) bar.style.right = "50%"; else bar.style.left = "50%";
    track.append(bar);
    return track;
  }
  function renderFarm(farm) {
    const top = farm.rows.slice(0, 12), max = top[0]?.value || 1;
    $("#farm-empty").hidden = top.length > 0;
    $("#farm-empty").textContent = farm.unpriced ? "Todavía no hay precios de estos materiales: aparecerán cuando alguien de la hermandad escanee la subasta." : "Nada cumple estos filtros.";
    $("#farm-twin").hidden = top.length === 0;
    const title = r => r.name + (r.note ? ` (${r.note})` : "");
    const tag = r => `${r.label}${r.prof === "cloth" ? "" : ` · habilidad ${r.skill}`} · niveles ${r.level[0]}–${r.level[1]}${r.rare ? " · raro" : ""}`;
    $("#farm-list").replaceChildren(...top.map(r => {
      const fill = el("span", {class: "rank-fill"});
      fill.style.width = Math.max(1, Math.round(100 * r.value / max)) + "%";
      return rankRow({id: r.id, name: title(r), tag: tag(r), track: el("span", {class: "rank-base"}, fill), value: [money(r.value), el("small", {text: `por ${r.per}`})],
        detail: `${partsText(r)}. Dónde: ${r.zones}.`});
    }));
    $("#farm-table").replaceChildren(twinTable([["Objeto"], ["Profesión"], ["Habilidad", true], ["Niveles"], ["Vale", true], ["Por"], ["Δ7d", true], ["Oferta típica", true], ["Confianza"], ["Precio usado"], ["Da"], ["Zonas"]],
      farm.rows.map(r => [itemButton(r.id, title(r)), cell(r.label), num(r.prof === "cloth" ? "—" : String(r.skill)), cell(`${r.level[0]}–${r.level[1]}`), num(money(r.value)), cell(r.per), num(pctNode(r.d7)), num(formatUnits(r.Q)),
        cell(r.conf ? r.confLabel : "Aprendiendo"), cell(sourceText(r.source)), el("td", {class: "twin-wrap", text: partsText(r, {all: true})}), el("td", {class: "twin-wrap", text: r.zones})])));
  }
  function renderResale(rows) {
    const s = state.summary, {texts} = rules(), guarded = s.phase !== "normal";
    const top = rows.slice(0, 10), maxAbs = Math.max(1000, ...top.map(r => Math.min(10000, Math.abs(r.gapBp ?? 0))));
    $("#resale-empty").hidden = !(guarded || rows.length === 0);
    $("#resale-empty").textContent = guarded ? "Protección de lanzamiento: hasta el 18-nov no se propone ninguna compra." + (rows.length ? " Aquí ves cuánto tendría que bajar cada objeto." : " Aún no hay objetos con 7 días de precios.")
      : rows.length ? "" : "Hacen falta 7 días de precios para saber a cuánto se revende cada objeto.";
    $("#resale-legend").hidden = rows.length === 0;
    $("#resale-twin").hidden = rows.length === 0;
    $("#resale-list").replaceChildren(...top.map(r => rankRow({id: r.id, name: r.name, tag: r.e.catLabel ?? r.e.cat, track: divergingTrack(r.gapBp, maxAbs, isInt(r.gapBp) && r.gapBp <= 0 ? "gain" : "rest"),
      value: r.buy ? [el("span", {class: "badge verdict-CHOLLO", text: "Compra"}), money(r.flip.profit), el("small", {text: "de ganancia"})] : [pctNode(r.gapBp), el("small", {text: "frente a lo máximo"})],
      detail: r.buy ? `Compra ${r.flip.units}× a ${formatGSC(r.flip.maxBuy)} como máximo · no revendas por debajo de ${formatGSC(r.flip.breakEven)} · objetivo ${formatGSC(r.flip.Rs)}${r.flip.depositEstimated ? " · depósito estimado" : ""}` : r.flip.maxBuy > 0 ? `${isInt(r.p) ? `Hoy ${formatGSC(r.p)}` : "Sin precio hoy"} · compensa pagar hasta ${formatGSC(r.flip.maxBuy)} · ${r.e.statusText}` : texts.flip(r.flip, formatGSC)})));
    $("#resale-table").replaceChildren(twinTable([["Objeto"], ["Hoy", true], ["Compensa hasta", true], ["Frente a lo máximo", true], ["Reventa prudente", true], ["Unidades", true], ["Coste", true], ["Ganancia", true], ["Estado"]],
      rows.map(r => [itemButton(r.id, r.name), num(money(r.p)), num(money(r.flip.maxBuy)), num(pctNode(r.gapBp)), num(money(r.flip.Rs)), num(r.flip.units ? String(r.flip.units) : "—"), num(r.flip.units ? money(r.flip.cost) : "—"), num(r.flip.units ? money(r.flip.profit) : "—"),
        cell(el("span", {class: "badge verdict-" + (r.buy ? "CHOLLO" : r.e.verdict), title: r.e.statusText, text: r.buy ? "Compra" : r.e.verdictLabel}))])));
  }
  function renderSmelt(smelt) {
    const s = state.summary, rows = smelt.rows, maxAbs = Math.max(100, ...rows.map(r => Math.abs(r.unitProfit)));
    const badge = r => el("span", {class: "badge " + (r.pays ? "verdict-CHOLLO" : r.label === "Mercado bajando" ? "verdict-BAJADA" : "off"), text: r.label});
    const signed = copper => el("span", {}, copper > 0 ? "+" : "", money(copper));
    const uses = r => r.parts.map(p => `${p.need} × ${p.name} a ${formatGSC(p.unit)}${p.fromVendor ? " (mercader)" : p.source === "reciente" ? " (últimos días)" : ""}`).join(" + ");
    const stale = rows.some(r => r.stale), notes = [];
    if (s.phase !== "normal") notes.push("Precios de lanzamiento: el cálculo es orientativo y no es una recomendación de compra hasta el 18-nov.");
    if (stale) notes.push("Hoy aún nadie ha escaneado algunos materiales: se usa su precio de los últimos días y esas recetas salen como orientativas.");
    $("#smelt-note").hidden = notes.length === 0 || rows.length === 0;
    $("#smelt-note").textContent = notes.join(" ");
    $("#smelt-empty").hidden = rows.length > 0;
    $("#smelt-empty").textContent = "Faltan precios de los últimos días de los materiales o de los lingotes: aparecerán cuando alguien de la hermandad escanee la subasta.";
    $("#smelt-legend").hidden = rows.length === 0;
    $("#smelt-twin").hidden = rows.length === 0;
    $("#smelt-list").replaceChildren(...rows.map(r => rankRow({id: r.id, name: r.name, tag: `Minería · habilidad ${r.skill}`, track: divergingTrack(r.unitProfit, maxAbs, r.unitProfit > 0 ? "gain" : "loss"),
      value: [badge(r), signed(r.unitProfit), el("small", {text: "por lingote"})],
      detail: `${uses(r)} → ${r.qty > 1 ? `${r.qty} lingotes` : "lingote"} a ${formatGSC(r.sale)} (${sourceText(r.source)})${r.pays ? ` · lote de ${r.flip.units}: ganas ≈ ${formatGSC(r.flip.profit)}` : ""}`})));
    $("#smelt-table").replaceChildren(twinTable([["Lingote"], ["Habilidad", true], ["Materiales"], ["Coste por lingote", true], ["Venta", true], ["Ganancia por lingote", true], ["Margen", true], ["Lote", true], ["Ganancia del lote", true], ["Estado"]],
      rows.map(r => [itemButton(r.id, r.name), num(String(r.skill)), el("td", {class: "twin-wrap", text: uses(r)}), num(money(r.unitCost)), num(money(r.sale)), num(money(r.unitProfit)), num(formatPct(r.marginBp)), num(r.flip.units && !r.stale ? String(r.flip.units) : "—"), num(r.flip.units && !r.stale ? money(r.flip.profit) : "—"), cell(badge(r))])));
  }
  function renderMap() {
    const s = state.summary, holder = $("#map-holder");
    const items = filterItems(s.items, {cat: state.compensa.cat}), known = items.filter(e => isInt(e.N));
    mapWidth = holder.clientWidth;
    const width = Math.max(300, mapWidth || 720);
    const chart = marketMapSVG({items, width, height: width < 480 ? 300 : 380});
    $("#map-empty").hidden = !!chart;
    $("#map-empty").textContent = known.length ? "Hoy todavía nadie ha escaneado estos objetos: el balance compara el precio de hoy con el normal."
      : `Aprendiendo precios: hacen falta 7 días con datos para saber qué es normal (de momento ${plural(marketMood(s.items).maxN, "día", "días")}).`;
    $("#map-legend").hidden = !chart;
    holder.replaceChildren(...(chart ? [mapFrame(chart)] : []));
    $("#map-twin").hidden = known.length === 0;
    const rows = [...known].sort((a, b) => (a.dBp ?? Infinity) - (b.dBp ?? Infinity) || a.id - b.id);
    $("#map-table").replaceChildren(twinTable([["Objeto"], ["Hoy", true], ["Normal 14 d", true], ["Frente a lo normal", true], ["Variación", true], ["Δ7d", true], ["Mín – máx 14 d", true], ["Oferta típica", true], ["Estado"]],
      rows.map(e => [itemButton(e.id, nameOf(e)), num(money(e.price?.lo)), num(money(e.N)), num(pctNode(e.dBp)), num(isInt(e.sBp) ? `±${rules().texts.pct(e.sBp)} %` : "—"), num(pctNode(e.d7)),
        num(isInt(e.min14) ? el("span", {class: "range"}, money(e.min14), el("span", {class: "muted", text: " – "}), money(e.max14)) : "—"), num(formatUnits(e.Q)),
        cell(el("span", {class: "badge verdict-" + e.verdict, title: e.statusText, text: e.verdictLabel}))])));
  }
  function mapFrame(chart) {
    const frame = el("div", {class: "chart-frame", tabindex: "0", "aria-label": "Balance de objetos: usa las flechas para recorrerlos e Intro para abrir uno"});
    const node = svg(chart.node), tip = el("div", {class: "chart-tip", hidden: true}), ring = node.querySelector(".focus-ring");
    frame.append(node, tip);
    const {points} = chart.layout;
    let current = -1;
    const show = i => {
      current = i;
      const p = points[i], e = p.e, scale = node.getBoundingClientRect().width / node.viewBox.baseVal.width;
      ring.setAttribute("cx", String(p.x)); ring.setAttribute("cy", String(p.y)); ring.setAttribute("visibility", "visible");
      tip.replaceChildren(el("strong", {text: nameOf(e)}), el("span", {}, "Hoy ", money(e.price?.lo), " · normal ", money(e.N)),
        el("span", {text: `${formatPct(e.dBp)} frente a lo normal · varía ±${rules().texts.pct(e.sBp)} %`}), el("span", {class: "muted", text: e.verdictLabel}));
      tip.hidden = false;
      tip.style.left = Math.max(0, Math.min(p.x * scale + 14, frame.clientWidth - tip.offsetWidth - 4)) + "px";
      tip.style.top = Math.max(0, Math.min(p.y * scale + 14, frame.clientHeight - tip.offsetHeight - 4)) + "px";
    };
    const hide = () => { current = -1; tip.hidden = true; ring.setAttribute("visibility", "hidden"); };
    // The nearest item within 28 px answers, because a dot is too small a target.
    const nearest = event => {
      const rect = node.getBoundingClientRect(), k = node.viewBox.baseVal.width / rect.width;
      const px = (event.clientX - rect.left) * k, py = (event.clientY - rect.top) * k;
      let best = -1, distance = 28 * 28;
      points.forEach((p, i) => { const d = (p.x - px) ** 2 + (p.y - py) ** 2; if (d <= distance) { distance = d; best = i; } });
      return best;
    };
    node.addEventListener("pointermove", event => {
      const i = nearest(event);
      if (i < 0) hide(); else if (i !== current) show(i);
    });
    node.addEventListener("pointerleave", event => { if (event.pointerType === "mouse") hide(); });
    // A click opens the item under a mouse; on a touch screen the first tap shows it and the second opens it.
    node.addEventListener("click", event => {
      const i = nearest(event);
      if (i >= 0 && i === current) navigateItem(points[i].e.id);
      else if (i >= 0) show(i);
    });
    frame.addEventListener("keydown", event => {
      if (event.key === "Enter" && current >= 0) { event.preventDefault(); navigateItem(points[current].e.id); return; }
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      show(current < 0 ? 0 : Math.max(0, Math.min(points.length - 1, current + (event.key === "ArrowLeft" ? -1 : 1))));
    });
    frame.addEventListener("blur", hide);
    return frame;
  }

  // ---- item detail
  function navigateItem(id) { win.location.hash = "objeto-" + id; }
  $("#detail").addEventListener("close", () => {
    if (/^#objeto-/.test(win.location.hash)) win.history.replaceState(null, "", "#" + (state.view || "mercado"));
  });
  $("#detail-close").addEventListener("click", () => $("#detail").close());
  // ---- "Hoy": the home tab, what to look at first
  function renderHoy() {
    const s = state.summary;
    $("#hoy-empty").hidden = !!s;
    $("#hoy-content").hidden = !s;
    if (!s) {
      $("#hoy-empty-text").textContent = $("#market-empty-text").textContent;
      $("#hoy-banners").replaceChildren();
      return;
    }
    const {farm, resale, smelt} = compensaRows();
    $("#hoy-best").replaceChildren(...bestCards(s, farm, resale, smelt).map(c => bestCardNode(c, () => {
      win.location.hash = "compensa";
      route();
      $(c.target).scrollIntoView();
    })));
    const line = e => el("li", {}, itemButton(e.id, nameOf(e)), money(e.price?.lo ?? null), pctNode(e.d1));
    const lines = (rows, empty) => rows.length ? rows.map(line) : [el("li", {class: "muted", text: empty})];
    const {fallers, risers} = dayMovers(s);
    const noYesterday = "Hace falta un día más de precios para comparar con ayer.";
    const anyYesterday = s.items.some(e => isInt(e.d1));
    $("#hoy-fallers").replaceChildren(...lines(fallers, anyYesterday ? "Nada ha bajado frente a ayer." : noYesterday));
    $("#hoy-risers").replaceChildren(...lines(risers, anyYesterday ? "Nada ha subido frente a ayer." : noYesterday));
    const mine = favoriteRows(s, state.favorites);
    $("#hoy-list-empty").hidden = mine.length > 0;
    $("#hoy-list").replaceChildren(...mine.map(e => el("li", {}, starButton(e.id, e.name), itemButton(e.id, nameOf(e)), money(e.price?.lo ?? null), pctNode(e.d1))));
    $("#hoy-caveat").textContent = `Recuerda: ${s.caveat}. Los cálculos son estimaciones con los precios que la hermandad ha visto; confírmalos siempre en la subasta.`;
    owned()?.render();
  }

  async function openDetail(id) {
    const dialog = $("#detail");
    const fromSummary = state.summary?.items.find(e => e.id === id);
    $("#detail-title").textContent = fromSummary?.name || `Objeto ${id}`;
    $("#detail-body").replaceChildren(el("p", {class: "muted", text: "Cargando el objeto…"}));
    if (!dialog.open) dialog.showModal();
    try {
      const detail = await request(`/api/guild/item?market=${encodeURIComponent(state.market)}&id=${id}`);
      state.detail = detail;
      renderDetail(detail);
    } catch (error) {
      if (error.status === 401 || error.status === 503) { dialog.close(); return handle(error); }
      $("#detail-body").replaceChildren(el("p", {class: "feedback", text: error.message}));
    }
  }
  function renderDetail(detail) {
    const item = detail.item, b = detail.baseline, a = detail.assess, price = detail.price;
    $("#detail-title").textContent = item.name || `Objeto ${item.id}`;
    const series = Object.fromEntries(detail.days.map(x => [x.d, x]));
    const from = detail.T - 59, to = detail.T;
    const markers = dumpDays(series, from, to);
    const chartWidth = Math.min(880, Math.max(300, ($("#detail-body").clientWidth || 760) - 32));
    const chart = bandChartSVG({days: detail.days, from, to, N: b.N, dumpLine: a.dumpLine, markers, price: price?.lo ?? null, width: chartWidth, height: chartWidth < 480 ? 220 : 260});
    const stat = (label, value, note) => el("div", {class: "stat"}, el("span", {class: "stat-label", text: label}), el("strong", {}, value), note ? el("span", {class: "muted stat-note", text: note}) : null);
    const children = [
      el("p", {class: "detail-meta muted", text: `${item.catLabel} · ID ${item.id}${item.watch ? " · lista fija de la hermandad" : " · objeto vigilado por algún miembro"}${item.vendor ? ` · se vende al vendedor por ${formatGSC(item.vendor)}` : ""}`}),
      el("div", {class: "detail-status"}, el("span", {class: "badge verdict-" + a.verdict, text: detail.verdictLabel}), el("span", {text: detail.statusText}), el("span", {class: "muted", text: " · " + detail.confText})),
      el("div", {class: "row detail-actions"}, starButton(item.id, item.name),
        owned() ? el("button", {type: "button", class: "button primary small", text: "Registrar compra", onclick: () => owned()?.openMovement("buy", {itemId: item.id, name: item.name, unit: price?.lo})}) : null,
        owned() ? el("button", {type: "button", class: "button secondary small", text: "Registrar venta", onclick: () => owned()?.openMovement("sell", {itemId: item.id, name: item.name, unit: price?.lo})}) : null),
      el("div", {class: "stats"},
        stat("Más bajo hoy", money(price?.lo), price ? `${price.member ?? "un compañero"}, ${formatWhen(price.at, Date.now())}` : "nadie lo ha visto hoy"),
        stat("Normal 14 d", money(b.N), b.n ? plural(b.n, "día", "días") + " con datos" : null),
        stat("Línea de chollo", money(a.dumpLine), isInt(a.dumpLine) ? "por debajo, chollo" : null),
        stat("Precio alto", money(a.spikeLine), isInt(a.spikeLine) ? "por encima, caro" : null),
        stat("Reventa prudente", money(b.Rs), isInt(b.Rs) ? "objetivo de reventa" : null),
        stat("Oferta típica", el("span", {text: formatUnits(b.Q)}), isInt(b.Q) ? "a la venta en un día" : null)),
      el("section", {class: "detail-section", "aria-labelledby": "chart-title"},
        el("h3", {id: "chart-title", text: "Últimos 60 días"}),
        chart ? el("ul", {class: "legend"},
          el("li", {}, el("span", {class: "key key-band"}), "Mín – máx del día"),
          el("li", {}, el("span", {class: "key key-line"}), "Valor del día"),
          isInt(b.N) ? el("li", {}, el("span", {class: "key key-normal"}), "Normal 14 d") : null,
          isInt(a.dumpLine) ? el("li", {}, el("span", {class: "key key-dump"}), "Línea de chollo") : null,
          markers.length ? el("li", {}, el("span", {class: "key key-marker"}), "Día de chollo") : null,
          isInt(price?.lo) ? el("li", {}, el("span", {class: "key key-today"}), "Más bajo hoy") : null) : null,
        chart ? chartFrame(chart, series) : el("p", {class: "empty-line", text: "Todavía no hay días con precio para este objeto."}),
        detail.days.length ? daysTable(detail) : null),
      weekdaySection(detail),
      calculator(detail),
      pointsSection(detail),
      el("p", {class: "caveat muted", text: `Recuerda: ${detail.caveat}.`})];
    $("#detail-body").replaceChildren(...children);
    updateCalculator();
  }
  function chartFrame(chart, series) {
    const frame = el("div", {class: "chart-frame", tabindex: "0", "aria-label": "Gráfico de precios: usa las flechas para recorrer los días"});
    const node = svg(chart.node), tip = el("div", {class: "chart-tip", hidden: true});
    frame.append(node, tip);
    const {x0, x1, from, to, x} = chart.layout;
    let current = null;
    const show = d => {
      current = Math.max(from, Math.min(to, d));
      const point = series[current];
      const cross = node.querySelector(".crosshair");
      const vb = node.viewBox.baseVal, scale = node.getBoundingClientRect().width / vb.width;
      cross.setAttribute("x1", String(x(current))); cross.setAttribute("x2", String(x(current)));
      cross.setAttribute("visibility", "visible");
      tip.replaceChildren(el("strong", {text: dayLabel(current)}),
        point ? el("span", {}, "Valor ", money(point.v)) : el("span", {class: "muted", text: "Sin datos ese día"}),
        point ? el("span", {}, "Mín – máx ", money(point.lo), " – ", money(point.hi)) : null,
        point ? el("span", {class: "muted", text: `${plural(point.obs ?? 0, "persona", "personas")}${isInt(point.qty) ? ` · ${formatUnits(point.qty)}` : ""}`}) : null);
      tip.hidden = false;
      const left = x(current) * scale;
      tip.style.left = Math.max(0, Math.min(left + 12, frame.clientWidth - tip.offsetWidth - 4)) + "px";
    };
    const hide = () => { tip.hidden = true; node.querySelector(".crosshair").setAttribute("visibility", "hidden"); };
    node.addEventListener("pointermove", event => {
      const rect = node.getBoundingClientRect(), vb = node.viewBox.baseVal;
      const px = (event.clientX - rect.left) * vb.width / rect.width;
      if (px < x0 - 8 || px > x1 + 8) return hide();
      show(Math.round(from + (px - x0) / (x1 - x0) * (to - from)));
    });
    node.addEventListener("pointerleave", hide);
    frame.addEventListener("keydown", event => {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      show((current ?? to) + (event.key === "ArrowLeft" ? -1 : 1));
    });
    frame.addEventListener("blur", hide);
    return frame;
  }
  function daysTable(detail) {
    const rows = [...detail.days].reverse();
    return el("details", {class: "days-table"},
      el("summary", {text: `Ver los ${plural(detail.days.length, "día", "días")} en una tabla`}),
      el("div", {class: "table-scroll"}, el("table", {},
        el("thead", {}, el("tr", {}, ...["Día", "Valor", "Mín", "Máx", "Cantidad", "Personas"].map((t, i) => el("th", {scope: "col", class: i >= 1 && i <= 4 ? "num" : null, text: t})))),
        el("tbody", {}, ...rows.map(x => el("tr", {},
          el("th", {scope: "row", text: dayLabel(x.d)}), el("td", {class: "num"}, money(x.v)), el("td", {class: "num"}, money(x.lo)),
          el("td", {class: "num"}, money(x.hi)), el("td", {class: "num", text: formatUnits(x.qty)}),
          el("td", {text: peopleText(x.members, x.obs)})))))),
      el("button", {type: "button", class: "button subtle small", text: "Descargar estos días (CSV)", onclick: () =>
        download(csvRows(dailyColumns(detail.item, state.summary?.launchDay ?? rules().LAUNCH), detail.days), `Hermandad_${detail.item.id}_diario_${detail.date}.csv`)}));
  }
  function weekdaySection(detail) {
    const result = weekdayBars(detail.weekday, {width: Math.min(560, Math.max(280, ($("#detail-body").clientWidth || 560) - 32))});
    return el("section", {class: "detail-section", "aria-labelledby": "weekday-title"},
      el("h3", {id: "weekday-title", text: "Por día de la semana"}),
      el("p", {class: result.shown ? "" : "empty-line", text: result.text}),
      result.shown ? el("div", {class: "chart-frame"}, svg(result.node)) : null,
      result.shown ? el("table", {class: "weekday-table"},
        el("thead", {}, el("tr", {}, el("th", {scope: "col", text: "Día"}), el("th", {scope: "col", text: "Frente a su semana"}), el("th", {scope: "col", text: "Semanas"}))),
        el("tbody", {}, ...result.bars.map(bar => el("tr", {}, el("th", {scope: "row", text: bar.name}), el("td", {class: "num"}, pctNode(bar.e)), el("td", {class: "num", text: String(bar.weeks ?? "—")}))))) : null);
  }
  function pointsSection(detail) {
    const points = [...detail.points].reverse().slice(0, 12);
    return el("section", {class: "detail-section", "aria-labelledby": "points-title"},
      el("h3", {id: "points-title", text: "Escaneos recientes"}),
      points.length ? el("div", {class: "table-scroll"}, el("table", {},
        el("thead", {}, el("tr", {}, ...["Cuándo", "Más bajo", "A la venta", "Cerca del mínimo", "Quién"].map((t, i) => el("th", {scope: "col", class: i >= 1 && i <= 3 ? "num" : null, text: t})))),
        el("tbody", {}, ...points.map(p => el("tr", {},
          el("td", {text: formatWhen(p.at, Date.now())}), el("td", {class: "num"}, money(p.lo)), el("td", {class: "num", text: formatUnits(p.qty)}),
          el("td", {class: "num", text: p.qty5 ? formatUnits(p.qty5) : "—"}), el("td", {text: p.member ?? (p.mate ? "un compañero" : "—")})))))) : el("p", {class: "empty-line", text: "Nadie ha escaneado este objeto en los últimos 14 días."}));
  }

  // ---- flip calculator (especular.flip on what the player types)
  function calculator(detail) {
    const price = detail.price, b = detail.baseline;
    const deposit = duration => detail.deposits.find(x => x.duration === duration)?.D ?? null;
    const resaleDuration = detail.flip?.duration ?? 3;
    const field = (label, name, value, hint, attrs = {}) => el("label", {}, el("span", {text: label}),
      el("input", {name, value: value ?? "", autocomplete: "off", spellcheck: "false", inputmode: attrs.inputmode ?? "text", ...attrs}),
      hint ? el("small", {class: "muted", text: hint}) : null);
    const form = el("form", {class: "calc", id: "calc", novalidate: true},
      el("div", {class: "calc-fields"},
        field("Unidades", "units", String(price?.qty5 >= 1 ? price.qty5 : 1), price?.qty5 >= 1 ? "Hoy, cerca del mínimo" : "Las que ves a ese precio", {inputmode: "numeric"}),
        field("Compra por unidad", "buy", price ? formatGSC(price.lo) : "", price ? "El más bajo visto hoy" : "Escribe el precio que ves"),
        field("Reventa por unidad", "resale", isInt(b.Rs) ? formatGSC(b.Rs) : "", isInt(b.Rs) ? "Reventa prudente de la hermandad" : "Sin precio normal: escribe el tuyo"),
        field("Comisión (%)", "cut", String(detail.cutBp / 100).replace(".", ","), "5 % en la subasta de tu facción", {inputmode: "decimal"}),
        el("label", {}, el("span", {text: "Duración"}),
          el("select", {name: "duration"}, ...DURATIONS.map(d => el("option", {value: String(d.value), text: d.label + (deposit(d.value) !== null ? "" : " (sin depósito aprendido)")}))),
          el("small", {class: "muted", text: "Cambia el depósito aprendido"})),
        field("Depósito por unidad", "deposit", deposit(resaleDuration) !== null ? formatGSC(deposit(resaleDuration)) : "",
          deposit(resaleDuration) !== null ? "Aprendido en la subasta" : "Vacío: se estima con el precio de vendedor"),
        field("Presupuesto total", "budget", formatGSC(detail.budget), "Se usa como máximo el 25 % en un objeto")),
      el("div", {class: "calc-result", id: "calc-result", "aria-live": "polite"}));
    form.elements.duration.value = String(resaleDuration);
    form.addEventListener("input", event => {
      if (event.target.name === "deposit") event.target.dataset.edited = "1";
      updateCalculator();
    });
    form.elements.duration.addEventListener("change", event => {
      const input = form.elements.deposit;
      if (!input.dataset.edited) input.value = deposit(Number(event.target.value)) !== null ? formatGSC(deposit(Number(event.target.value))) : "";
      updateCalculator();
    });
    form.addEventListener("submit", event => event.preventDefault());
    return el("section", {class: "detail-section", "aria-labelledby": "calc-title"},
      el("h3", {id: "calc-title", text: "Calculadora de compra y reventa"}),
      el("p", {class: "muted", text: "Cambia cualquier dato: el cálculo usa las mismas reglas que el addon (comisión, un depósito perdido y un margen mínimo del 15 %)."}),
      form);
  }
  function updateCalculator() {
    const form = $("#calc"), out = $("#calc-result");
    if (!form || !out || !state.detail) return;
    const values = Object.fromEntries(["units", "buy", "resale", "cut", "deposit", "budget"].map(k => [k, form.elements[k].value]));
    const answer = calculatorFlip(state.detail, values);
    if (answer.error) { out.replaceChildren(el("p", {class: "feedback", text: answer.error})); return; }
    const f = answer.result;
    const line = (label, value) => el("div", {}, el("dt", {text: label}), el("dd", {}, value));
    out.replaceChildren(
      el("p", {class: "calc-verdict " + (f.accept ? "ok" : "no"), text: f.accept ? "Compensa" : "No compensa"}),
      el("dl", {class: "figures"},
        line("Compra recomendada", el("span", {text: plural(f.units, "unidad", "unidades")})),
        line("Coste", money(f.cost)),
        line("Ganancia estimada", money(f.profit)),
        line("Compra máxima por unidad", money(f.maxBuy)),
        line("No revendas por debajo de", money(f.breakEven)),
        line("Neto por unidad vendida", money(f.netUnit)),
        line("Depósito por unidad", el("span", {}, money(f.D), f.depositEstimated ? " (estimado)" : "")),
        line("Límites", el("span", {text: f.capLiq !== null ? `${plural(f.capLiq, "unidad", "unidades")} por liquidez · ${formatGSC(f.capBudget)} de presupuesto` : "—"}))),
      el("p", {class: "flip-text", text: rules().texts.flip(f, formatGSC)}));
  }

  // ---- members (owner and admins)
  async function loadMembers() {
    if (!state.me?.canAdmin) return;
    try { state.members = await request("/api/guild/members"); renderMembers(); }
    catch (error) { handle(error); }
  }
  function renderMembers() {
    const data = state.members;
    $("#members-count").textContent = `${data.activeMembers} de ${data.maxMembers} miembros activos · ${data.activeKeys} de ${data.maxKeys} claves activas`;
    $("#member-role-wrap").hidden = !state.me.isOwner;
    $("#members-empty").hidden = data.members.length > 0;
    const owner = state.me.isOwner, me = state.me.member?.id ?? null;
    $("#members-body").replaceChildren(...data.members.map(m => {
      const manageable = owner || (m.role !== "admin" || m.id === me);
      const actions = [];
      if (!m.revoked && manageable) actions.push(el("button", {type: "button", class: "button small", text: "Nueva clave", onclick: () => createKey(m)}));
      if (!m.revoked && owner) actions.push(el("button", {type: "button", class: "button subtle small", text: m.role === "admin" ? "Quitar admin" : "Hacer admin", onclick: () => setRole(m, m.role === "admin" ? "member" : "admin")}));
      if (!m.revoked && manageable && m.id !== me) actions.push(el("button", {type: "button", class: "button danger small", text: "Revocar", onclick: () => revokeMember(m)}));
      const keys = m.keys.length ? el("details", {class: "keys"}, el("summary", {text: plural(m.keys.length, "clave", "claves")}),
        el("ul", {}, ...m.keys.map(k => el("li", {},
          el("span", {text: `Clave ${k.id} · creada ${formatWhen(k.createdAt, Date.now())} · último envío ${k.lastUploadAt ? formatWhen(k.lastUploadAt, Date.now()) : "nunca"} · última entrada ${k.lastLoginAt ? formatWhen(k.lastLoginAt, Date.now()) : "nunca"}`}),
          k.revoked ? el("span", {class: "badge off", text: "Revocada"}) : manageable ? el("button", {type: "button", class: "button subtle small", text: "Revocar clave", onclick: () => revokeKey(m, k)}) : null)))) : el("span", {class: "muted", text: "sin claves"});
      return el("tr", {class: m.revoked ? "revoked" : null},
        el("th", {scope: "row", text: m.label}),
        el("td", {text: m.role === "admin" ? "Administra" : "Miembro"}),
        el("td", {text: (m.revoked ? `Revocado ${formatWhen(m.revokedAt, Date.now())}` : "Activo") +
          (m.characters > 0 ? ` · ${plural(m.characters, "personaje vinculado", "personajes vinculados")}` : "")}),
        el("td", {text: m.lastUploadAt ? `${relativeTime(m.lastUploadAt, Date.now())}` : "Nunca"}),
        el("td", {}, keys),
        el("td", {}, el("div", {class: "actions"}, ...actions)));
    }));
  }
  $("#member-form").addEventListener("submit", async event => {
    event.preventDefault();
    const form = event.target, label = form.elements.label.value.trim(), role = state.me.isOwner ? form.elements.role.value : "member";
    if (!label) { $("#member-feedback").textContent = "Escribe un nombre para el miembro (no hace falta que sea su personaje)."; return; }
    const button = form.querySelector("button[type=submit]");
    button.disabled = true; $("#member-feedback").textContent = "";
    try {
      const {member} = await request("/api/guild/members", {label, role});
      form.reset();
      await createKey(member);
    } catch (error) { if (error.status === 401) handle(error); else $("#member-feedback").textContent = error.message; }
    finally { button.disabled = false; }
  });
  async function createKey(member) {
    try {
      const answer = await request("/api/guild/keys", {memberId: member.id});
      $("#key-label").textContent = answer.label;
      $("#key-value").value = answer.key;
      $("#key-warning").textContent = answer.warning;
      $("#key-panel").hidden = false;
      $("#key-value").select();
      await loadMembers();
    } catch (error) { handle(error); }
  }
  $("#key-copy").addEventListener("click", async () => {
    const input = $("#key-value");
    try { await win.navigator.clipboard.writeText(input.value); toast("Clave copiada. Envíasela por privado."); }
    catch { input.select(); toast("Selecciona la clave y cópiala con Ctrl+C.", true); }
  });
  $("#key-done").addEventListener("click", () => { $("#key-value").value = ""; $("#key-panel").hidden = true; });
  $("#url-copy").addEventListener("click", async () => {
    try { await win.navigator.clipboard.writeText($("#panel-url").value); toast("Dirección copiada."); }
    catch { $("#panel-url").select(); }
  });
  async function setRole(member, role) {
    try { await request("/api/guild/members/role", {memberId: member.id, role}); toast(role === "admin" ? `${member.label} ahora puede administrar.` : `${member.label} ya no administra.`); await loadMembers(); }
    catch (error) { handle(error); }
  }
  function confirmAction(title, text, {purge = false} = {}) {
    const dialog = $("#confirm");
    $("#confirm-title").textContent = title;
    $("#confirm-text").textContent = text;
    $("#confirm-purge-wrap").hidden = !purge;
    $("#confirm-purge").checked = false;
    dialog.returnValue = "";
    dialog.showModal();
    return new Promise(resolve => {
      dialog.addEventListener("close", () => resolve(dialog.returnValue === "ok" ? {purge: $("#confirm-purge").checked} : null), {once: true});
    });
  }
  async function revokeMember(member) {
    const answer = await confirmAction(`¿Revocar a ${member.label}?`, "Sus claves dejarán de funcionar al momento: no podrá subir precios ni entrar en el panel. Sus precios ya subidos se quedan, salvo que marques la casilla.", {purge: true});
    if (!answer) return;
    try { await request("/api/guild/members/revoke", {memberId: member.id, purge: answer.purge}); toast(answer.purge ? `${member.label} revocado y sus precios borrados.` : `${member.label} revocado.`); await loadMembers(); if (answer.purge) await loadMarket(); }
    catch (error) { handle(error); }
  }
  async function revokeKey(member, key) {
    const answer = await confirmAction(`¿Revocar la clave ${key.id} de ${member.label}?`, "El sincronizador o el panel que la use dejarán de funcionar. Puedes crearle otra clave después.");
    if (!answer) return;
    try { await request("/api/guild/keys/revoke", {keyId: key.id}); toast("Clave revocada."); await loadMembers(); }
    catch (error) { handle(error); }
  }

  win.addEventListener("hashchange", () => { if (state.me) route(); });
  for (const tab of doc.querySelectorAll("#tabs a")) tab.addEventListener("click", () => { if ($("#detail").open) $("#detail").close(); });
  return start;
}

if (typeof document !== "undefined" && typeof window !== "undefined" && document.getElementById("hermandad")) {
  (async () => {
    try { setEspecular(await import("./especular.js")); }
    catch {
      document.getElementById("fatal-message").textContent = "No se han podido cargar las reglas del mercado (especular.js). Recarga la página; si sigue igual, avisa a quien mantiene el panel.";
      for (const section of document.querySelectorAll("[data-screen]")) section.hidden = section.id !== "screen-fatal";
      return;
    }
    await boot(document, window)();
  })();
}

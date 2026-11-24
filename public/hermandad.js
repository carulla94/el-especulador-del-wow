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
/** The Windows uploader of the latest GitHub release (contract C10: attached to every release by the publish workflow). */
export const UPLOADER_URL = "https://github.com/carulla94/el-especulador-del-wow/releases/latest/download/Subidor_Windows.zip";
export const CATEGORY_ORDER = ["metal", "piedra", "gema", "hierba", "piel", "tela", "pocion", "elixir", "frasco", "comida",
  "venda", "encantar", "elemental", "otro"];
export const DURATIONS = [{value: 1, label: "Corta"}, {value: 2, label: "Media"}, {value: 3, label: "Larga"}];
/** Chart colours, validated for the dark surface with the dataviz palette checks (see hermandad.css for the same
 * values as tokens). Text never wears them. */
export const CHART = Object.freeze({price: "#c98500", normal: "#a99b80", good: "#0ca30c", down: "#3987e5", up: "#e66767",
  grid: "#33291c", surface: "#1d1811", text: "#ece1c9", muted: "#a99b80"});

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

// ---- Cuándo vender: weekday × time of day from /api/guild/timing (src/timing.mjs) -----------------------------
export const BLOCK_LABELS = ["0–4 h", "4–8 h", "8–12 h", "12–16 h", "16–20 h", "20–24 h"];
const BLOCK_TEXT = ["de 0 a 4 h", "de 4 a 8 h", "de 8 a 12 h", "de 12 a 16 h", "de 16 a 20 h", "de 20 a 24 h"];
/** When a cell, a time of day or a weekday is worth reading: at least this many scans from this many days, and a
 * difference of at least spreadBp between the best and the worst before anything is called a pattern. */
export const TIMING_MIN = Object.freeze({cellPoints: 3, cellDays: 2, blockPoints: 6, blockDays: 3, dayValues: 2, spreadBp: 300});
const meanOf = list => list.length ? Math.round(list.reduce((s, x) => s + x, 0) / list.length) : null;
/** The pattern of a group of items, every item weighing the same (an item's cell is the mean of its points).
 * timing: the /api/guild/timing answer; ids: the items to take (null: every item with data).
 * Returns {items, points, cells: [42] {cell, wd, block, value, n, days, items, qty, usable}, blocks: [6] {block, value, n,
 * days, items, usable}, weekdays: [7] {wd, value, n, items, usable}}; value is null where nobody scanned. */
export function timingPattern(timing, ids = null) {
  const wanted = ids ? new Set(ids) : null, blocks = BLOCK_LABELS.length;
  const list = (timing?.items ?? []).filter(i => !wanted || wanted.has(i.id));
  const cells = Array.from({length: 7 * blocks}, (_, cell) => ({cell, wd: Math.floor(cell / blocks), block: cell % blocks, means: [], qtys: [], n: 0, days: 0}));
  const byBlock = Array.from({length: blocks}, (_, block) => ({block, means: [], n: 0, days: 0}));
  const byDay = Array.from({length: 7}, (_, wd) => ({wd, means: [], n: 0}));
  let points = 0, items = 0;
  for (const item of list) {
    const blockSum = Array(blocks).fill(0), blockN = Array(blocks).fill(0), blockDays = Array(blocks).fill(0);
    for (const [cell, n, days, sum, nQty, sumQty] of item.cells ?? []) {
      const c = cells[cell];
      if (!c || !isInt(n) || n < 1) continue;
      c.means.push(sum / n); c.n += n; c.days = Math.max(c.days, days);
      if (isInt(nQty) && nQty > 0) c.qtys.push(sumQty / nQty);
      blockSum[c.block] += sum; blockN[c.block] += n; blockDays[c.block] += days;
      points += n;
    }
    for (let b = 0; b < blocks; b++) if (blockN[b]) {
      byBlock[b].means.push(blockSum[b] / blockN[b]); byBlock[b].n += blockN[b]; byBlock[b].days = Math.max(byBlock[b].days, blockDays[b]);
    }
    for (const [wd, n, sum] of item.wd ?? []) if (byDay[wd] && isInt(n) && n > 0) { byDay[wd].means.push(sum / n); byDay[wd].n += n; }
    if ((item.cells ?? []).length || (item.wd ?? []).length) items++;
  }
  return {items, points,
    cells: cells.map(c => ({cell: c.cell, wd: c.wd, block: c.block, value: meanOf(c.means), n: c.n, days: c.days, items: c.means.length,
      qty: meanOf(c.qtys), usable: c.n >= TIMING_MIN.cellPoints && c.days >= TIMING_MIN.cellDays})),
    blocks: byBlock.map(b => ({block: b.block, value: meanOf(b.means), n: b.n, days: b.days, items: b.means.length,
      usable: b.n >= TIMING_MIN.blockPoints && b.days >= TIMING_MIN.blockDays})),
    weekdays: byDay.map(d => ({wd: d.wd, value: meanOf(d.means), n: d.n, items: d.means.length,
      usable: d.means.length > 0 && d.n >= TIMING_MIN.dayValues * d.means.length}))};
}
const extremes = list => {
  const usable = list.filter(x => x.usable && isInt(x.value));
  if (usable.length < 2) return null;
  const best = usable.reduce((a, b) => b.value > a.value ? b : a), worst = usable.reduce((a, b) => b.value < a.value ? b : a);
  return {best, worst, spread: best.value - worst.value, count: usable.length};
};
function pctWords(bp) {
  if (!isInt(bp)) return "—";
  const text = `${rules().texts.pct(Math.abs(bp))} %`;
  return bp > 0 ? `un ${text} por encima` : bp < 0 ? `un ${text} por debajo` : "igual";
}
/** What to do with the price pattern, in words: {level: "sin-datos" | "pocos" | "plano" | "claro", title, lines: [text],
 * best, worst (the best and worst usable cells when they differ enough, else null)}. The weekday × time cells, the time
 * of day and the weekday are read apart, each when it has enough data. The sales («Ventas») are read by timingAdvice. */
export const SCAN_MORE = "Escanea la subasta con Oro de Hermandad (botón «Escanear», addon 0.6.0 o posterior) a distintas horas y días: con cada escaneo que se sube, aquí aparece cuándo se paga más y cuándo se vende más.";
export function timingSummary(pattern) {
  if (!pattern || (pattern.points === 0 && !pattern.weekdays.some(d => d.n > 0))) {
    return {level: "sin-datos", title: "Aún no hay escaneos de estos objetos", best: null, worst: null, lines: [SCAN_MORE]};
  }
  const cells = extremes(pattern.cells), blocks = extremes(pattern.blocks), days = extremes(pattern.weekdays);
  const lines = [], cellsClear = !!cells && cells.spread >= TIMING_MIN.spreadBp;
  let level = "pocos";
  if (cellsClear) {
    level = "claro";
    const b = cells.best, w = cells.worst;
    lines.push(`Mejor momento para poner a la venta: el ${WEEKDAYS_LONG[b.wd]} ${BLOCK_TEXT[b.block]}. Su precio más bajo suele estar ${pctWords(b.value)} de su nivel de esa semana (${plural(b.n, "escaneo", "escaneos")} de ${plural(b.days, "día", "días")}).`);
    lines.push(`El peor: el ${WEEKDAYS_LONG[w.wd]} ${BLOCK_TEXT[w.block]} (${formatPct(w.value)}).`);
  }
  if (blocks) {
    if (blocks.spread >= TIMING_MIN.spreadBp) {
      level = "claro";
      lines.push(`Por horas, sea el día que sea: mejor ${BLOCK_TEXT[blocks.best.block]} (${formatPct(blocks.best.value)}), peor ${BLOCK_TEXT[blocks.worst.block]} (${formatPct(blocks.worst.value)}).`);
    } else {
      if (level === "pocos") level = "plano";
      lines.push(`Por horas apenas cambia (de ${formatPct(blocks.worst.value)} a ${formatPct(blocks.best.value)}).`);
    }
  }
  if (days) {
    if (days.spread >= TIMING_MIN.spreadBp) {
      level = "claro";
      lines.push(`Por días, con el precio de cada día: mejor el ${WEEKDAYS_LONG[days.best.wd]} (${formatPct(days.best.value)}), peor el ${WEEKDAYS_LONG[days.worst.wd]} (${formatPct(days.worst.value)}).`);
    } else {
      if (level === "pocos") level = "plano";
      lines.push(`Por días de la semana apenas cambia (de ${formatPct(days.worst.value)} a ${formatPct(days.best.value)}).`);
    }
  }
  if (level === "plano") lines.push("Vende cuando te venga bien: lo que cuenta es no malvender por debajo del precio normal.");
  if (level === "pocos") lines.unshift("Aún hay pocos escaneos para ver un patrón. Escanea a distintas horas (mañana, tarde y noche) y distintos días.");
  const title = {pocos: "Faltan escaneos para ver un patrón", plano: "No se nota un momento mejor", claro: "Cuándo se paga más"}[level];
  return {level, title, lines, best: cellsClear ? cells.best : null, worst: cellsClear ? cells.worst : null};
}
/** The heatmap: one row per weekday, one column per block of four hours; amber above the items' level that week, blue
 * below, stronger the further (full at ±10 %). Cells without enough scans stay empty with a dashed edge and their count
 * in the tooltip; the best cell of the advice gets a ring. With sales (timingSales, mode "ventas") a cell shows how much
 * more or less sells there than usual: green above, blue below, full at ×1,5 and ×0,5; an eighth row («todos») shows
 * the blocks of any day, which the advice reads, and its best block gets the ring. Returns {node, cells}. */
export function timingHeatmapSVG(pattern, {best = null, width = 440, sales = null, cellH = 30} = {}) {
  const left = 40, top = 22, cols = BLOCK_LABELS.length, cellW = (width - left - 4) / cols, gap = 8, textY = Math.round(cellH / 2) + 4;
  const height = top + 7 * cellH + 4 + (sales ? cellH + gap : 0);
  const cells = sales ? sales.cells : pattern?.cells ?? [];
  const salesCell = c => {
    const any = c.wd === 7;
    const x = round1(left + c.block * cellW + 1), y = round1(top + c.wd * cellH + (any ? gap : 0) + 1), w = round1(cellW - 2), hgt = cellH - 2;
    const name = any ? `Cualquier día ${BLOCK_TEXT[c.block]}` : `${WEEKDAYS_LONG[c.wd]} ${BLOCK_TEXT[c.block]}`;
    const tip = c.n === 0 ? `${name}: nadie ha medido ventas a esa hora`
      : `${name}: ${c.usable ? `se vende ${formatRate(c.value)} de lo normal` : "pocos datos"} · ${plural(c.n, "medición", "mediciones")}${any ? "" : ` de ${plural(c.days, "día", "días")}`} · ${formatHours(c.sec)} medidas`;
    const strength = c.usable ? Math.min(1, Math.abs(c.value - 1) / 0.5) : 0;
    const ring = any && sales.advice.best === c.block && c.usable;
    return h("g", {class: "heat-cell"},
      h("rect", {x, y, width: w, height: hgt, rx: 3, fill: c.usable ? (c.value >= 1 ? CHART.good : CHART.down) : "none",
        "fill-opacity": c.usable ? round1(0.12 + 0.68 * strength) : 0, stroke: ring ? CHART.text : c.usable ? "none" : CHART.grid,
        "stroke-width": ring ? 2 : 1, ...(c.usable || ring ? {} : {"stroke-dasharray": "3 3"})}),
      h("text", {x: round1(x + w / 2), y: y + textY, "text-anchor": "middle", "font-size": 12, fill: c.usable ? CHART.text : CHART.muted},
        c.usable ? formatRate(c.value) : c.n > 0 ? "·" : ""),
      h("title", {}, tip));
  };
  const cell = c => {
    const x = round1(left + c.block * cellW + 1), y = round1(top + c.wd * cellH + 1), w = round1(cellW - 2), hgt = cellH - 2;
    const name = `${WEEKDAYS_LONG[c.wd]} ${BLOCK_TEXT[c.block]}`;
    const tip = c.n === 0 ? `${name}: nadie ha escaneado a esa hora`
      : `${name}: ${c.usable ? formatPct(c.value) : "pocos datos"} frente a su semana · ${plural(c.n, "escaneo", "escaneos")} de ${plural(c.days, "día", "días")}`
        + (isInt(c.qty) && c.usable ? ` · ${c.qty < 0 ? "menos" : "más"} unidades a la venta que de costumbre (${formatPct(c.qty)})` : "");
    const strength = c.usable && isInt(c.value) ? Math.min(1, Math.abs(c.value) / 1000) : 0;
    const ring = !!best && best.cell === c.cell;
    return h("g", {class: "heat-cell"},
      h("rect", {x, y, width: w, height: hgt, rx: 3, fill: c.usable ? (c.value >= 0 ? CHART.price : CHART.down) : "none",
        "fill-opacity": c.usable ? round1(0.12 + 0.68 * strength) : 0, stroke: ring ? CHART.text : c.usable ? "none" : CHART.grid,
        "stroke-width": ring ? 2 : 1, ...(c.usable || ring ? {} : {"stroke-dasharray": "3 3"})}),
      h("text", {x: round1(x + w / 2), y: y + textY, "text-anchor": "middle", "font-size": 12, fill: c.usable ? CHART.text : CHART.muted},
        c.usable ? formatPct(c.value) : c.n > 0 ? "·" : ""),
      h("title", {}, tip));
  };
  const node = h("svg", {class: "heatmap", viewBox: `0 0 ${width} ${height}`, width, height, role: "img",
    "aria-label": sales ? "Ventas estimadas por día de la semana y franja horaria frente a lo normal de esos objetos. Las mismas conclusiones están en las frases de arriba."
      : "Precio más bajo por día de la semana y franja horaria frente a su nivel de esa semana. Las mismas conclusiones están en las frases de arriba."},
    h("g", {"font-size": 12, fill: CHART.muted, "text-anchor": "middle"}, BLOCK_LABELS.map((label, b) => h("text", {x: round1(left + b * cellW + cellW / 2), y: 14}, width < 420 ? label.replace(" h", "") : label))),
    h("g", {"font-size": 12, fill: CHART.muted}, WEEKDAYS_SHORT.map((label, wd) => h("text", {x: 2, y: top + wd * cellH + 1 + textY}, label)),
      sales ? h("text", {x: 2, y: top + 7 * cellH + gap + 1 + textY}, "todos") : null),
    cells.map(sales ? salesCell : cell),
    sales ? sales.blocks.map(b => salesCell({wd: 7, block: b.block, value: b.rateIdx, usable: b.rateIdx !== null, n: b.n, days: 0, sec: b.sec})) : null);
  return {node, cells};
}

// ---- Ventas: the sell-through estimates of addon 0.6.0 (cuando-vender-2 cells) and the advice rule C11 ------------
/** Contract C11 (test/fixtures/v06/timing-advice.json), the same rule as the addon's Timing.Advice: a block counts for
 * sales with at least minN samples on minDays days and minSec seconds measured once its largest sample is left out; a
 * sales pattern needs minBlocks such blocks and minUnits units; a block «sells more» from faster times the usual rate.
 * Without a sales pattern, a price pattern needs minBlocks blocks with a usable price and a spread of spreadBp. */
export const SALES_RULE = Object.freeze({minN: 2.5, minDays: 2, minSec: 3600, minBlocks: 3, minUnits: 10, faster: 1.2});
export const PRICE_RULE = Object.freeze({minBlocks: 3, spreadBp: 300});
/** blocks: the six Spanish 4-hour blocks (0 = 0-4 h) of one item, [{priceOK, p, n, days, sec, u, mu, msec}]. Returns
 * {salesOK: [6] booleans, rateIdx: [6] numbers or null (units per second of the block against the item's), best: block
 * or null, reason: "ventas" | "precio" | "precio-alto" | "pocos", hint: [h1, h2] (put or match the price around h1-h2 h)
 * or null}. best = the salesOK block with the highest (10000 + price index) × rateIdx (ties: the earlier block). */
export function timingAdvice(blocks) {
  const trimmed = blocks.map(b => ({u: Math.max(0, b.u - b.mu), sec: b.sec - b.msec}));
  const salesOK = blocks.map((b, i) => b.n >= SALES_RULE.minN && b.days >= SALES_RULE.minDays && trimmed[i].sec >= SALES_RULE.minSec);
  const ok = salesOK.flatMap((x, i) => x ? [i] : []);
  const units = ok.reduce((sum, i) => sum + trimmed[i].u, 0), seconds = ok.reduce((sum, i) => sum + trimmed[i].sec, 0);
  const rateIdx = Array(blocks.length).fill(null);
  let best = null, reason = "pocos";
  if (ok.length >= SALES_RULE.minBlocks && units >= SALES_RULE.minUnits) {
    const overall = units / seconds;
    for (const i of ok) rateIdx[i] = trimmed[i].u / trimmed[i].sec / overall;
    const score = i => (10000 + (blocks[i].priceOK ? blocks[i].p : 0)) * rateIdx[i];
    best = ok.reduce((a, i) => score(i) > score(a) ? i : a);
    reason = rateIdx[best] >= SALES_RULE.faster ? "ventas" : "precio";
  } else {
    best = pricePattern(blocks);
    if (best !== null) reason = "precio-alto";
  }
  return {salesOK, rateIdx, best, reason, hint: best === null ? null : [(4 * best + 23) % 24, 4 * best]};
}
/** The block with the highest usable price when at least PRICE_RULE.minBlocks blocks have one and they spread by
 * PRICE_RULE.spreadBp (ties: the earlier block); else null. blocks: [{priceOK, p}]. */
function pricePattern(blocks) {
  const priced = blocks.flatMap((b, i) => b.priceOK ? [i] : []);
  if (priced.length < PRICE_RULE.minBlocks) return null;
  const values = priced.map(i => blocks[i].p);
  if (Math.max(...values) - Math.min(...values) < PRICE_RULE.spreadBp) return null;
  return priced.reduce((a, i) => blocks[i].p > blocks[a].p ? i : a);
}
/** «×1,6»: how many times the usual rate. */
export function formatRate(x) { return Number.isFinite(x) ? `×${(Math.round(x * 10) / 10).toFixed(1).replace(".", ",")}` : "—"; }
/** Seconds measured as hours, rounded to half an hour: «0 h», «0,5 h», «14 h». */
export function formatHours(seconds) {
  const half = Math.round((Number.isFinite(seconds) ? seconds : 0) / 1800) / 2;
  return `${String(half).replace(".", ",")} h`;
}
const REASON_TEXT = {ventas: "más ventas", precio: "mejor precio", "precio-alto": "precio más alto"};
/** «Mejor franja: 20-24 h (más ventas). Pon o iguala el precio hacia las 19-20 h, con 2 h (u 8 h si no vas a volver).»;
 * null without a best block. advice: timingAdvice (or a group's advice of the same shape). */
export function adviceText(advice) {
  if (!advice || advice.best === null || !advice.hint) return null;
  const [from, to] = advice.hint;
  return `Mejor franja: ${4 * advice.best}-${4 * advice.best + 4} h (${REASON_TEXT[advice.reason]}). Pon o iguala el precio hacia las ${from}-${to} h, con 2 h (u 8 h si no vas a volver).`;
}
export const NO_SALES_YET = "Ningún envío trae ventas todavía: quien tiene el subidor tiene que actualizar el addon y el subidor a la 0.6.0.";
export const FEW_SALES = "Aún pocas ventas medidas: el addon las calcula entre dos escaneos completos de la misma persona separados de 30 min a 2 h.";
const count = x => Number.isSafeInteger(x) && x >= 0 ? x : 0;
/** The six sales columns of a cuando-vender-2 cell; zeros for a cuando-vender-1 cell (an older cached answer). */
const salesOf = c => ({u: count(c[6]), sec: count(c[7]), n: count(c[8]), days: count(c[9]), mu: count(c[10]), msec: count(c[11])});
const cellSalesOK = s => s.n >= SALES_RULE.minN && s.days >= SALES_RULE.minDays && s.sec - s.msec >= SALES_RULE.minSec;
/** The six blocks of one item as timingAdvice takes them: per block the sums of its weekday cells (soldDays add up:
 * different weekdays are different days) and the largest of their largest samples; priceOK and p from the price
 * rule of the blocks (TIMING_MIN blockPoints and blockDays). */
export function itemBlocks(item) {
  const blocks = BLOCK_LABELS.map(() => ({n: 0, days: 0, sec: 0, u: 0, mu: 0, msec: 0, pn: 0, pdays: 0, psum: 0}));
  for (const c of item?.cells ?? []) {
    const b = blocks[c[0] % BLOCK_LABELS.length];
    if (!b || !isInt(c[0])) continue;
    if (isInt(c[1]) && c[1] > 0 && isInt(c[3])) { b.pn += c[1]; b.pdays += count(c[2]); b.psum += c[3]; }
    const s = salesOf(c);
    b.n += s.n; b.days += s.days; b.sec += s.sec; b.u += s.u;
    if (s.n > 0 && (s.mu > b.mu || (s.mu === b.mu && s.msec > b.msec))) { b.mu = s.mu; b.msec = s.msec; }
  }
  return blocks.map(({pn, pdays, psum, ...b}) => {
    const priceOK = pn >= TIMING_MIN.blockPoints && pdays >= TIMING_MIN.blockDays;
    return {priceOK, p: priceOK ? Math.round(psum / pn) : null, ...b};
  });
}
/** «Ventas» of a group of items (ids null: every item) from /api/guild/timing: {any (some item of the market has a
 * measured second: the uploaders send sales), items: [{id, blocks, advice}], advice (timingAdvice of the only item; for
 * a group, its blocks' rateIdx is the mean of the items' rateIdx weighted by their trimmed seconds over the items with a
 * sales pattern that count there, shown from 2 items, and the price is the group's equal-weight pattern), blocks: [6]
 * {block, rateIdx, items, n, sec}, cells: [42] {cell, wd, block, value, usable, n, days, sec, items}}. A cell's value is
 * its trimmed rate against the item's trimmed rate over its usable cells (a group: weighted like the blocks). */
export function timingSales(timing, ids = null, pattern = null) {
  const wanted = ids ? new Set(ids) : null, all = timing?.items ?? [];
  const list = all.filter(i => !wanted || wanted.has(i.id));
  const any = all.some(i => (i.cells ?? []).some(c => salesOf(c).sec > 0));
  const single = list.length === 1, minItems = single ? 1 : 2;
  const items = list.map(item => {
    const blocks = itemBlocks(item), advice = timingAdvice(blocks);
    // The item's usual rate for its cells: trimmed units over trimmed seconds of its usable cells.
    let units = 0, seconds = 0;
    const cells = new Map();
    for (const c of item.cells ?? []) {
      const s = salesOf(c);
      if (!cellSalesOK(s)) continue;
      const u = Math.max(0, s.u - s.mu), sec = s.sec - s.msec;
      cells.set(c[0], {u, sec}); units += u; seconds += sec;
    }
    return {id: item.id, blocks, advice, cells, rate: units > 0 ? units / seconds : null};
  });
  const cells = Array.from({length: 7 * BLOCK_LABELS.length}, (_, cell) => ({cell, wd: Math.floor(cell / BLOCK_LABELS.length), block: cell % BLOCK_LABELS.length,
    value: null, usable: false, n: 0, days: 0, sec: 0, items: 0, weight: 0, sum: 0}));
  for (const item of list) for (const c of item.cells ?? []) {
    const x = cells[c[0]], s = salesOf(c);
    if (!x || s.n === 0) continue;
    x.n += s.n; x.days = Math.max(x.days, s.days); x.sec += s.sec;
  }
  for (const item of items) {
    if (item.rate === null) continue;
    for (const [cell, t] of item.cells) {
      const x = cells[cell];
      if (!x || t.sec <= 0) continue;
      x.items++; x.weight += t.sec; x.sum += t.sec * (t.u / t.sec / item.rate);
    }
  }
  for (const x of cells) if (x.items >= minItems && x.weight > 0) { x.value = x.sum / x.weight; x.usable = true; }
  // Blocks: the item's own advice, or the group's weighted mean of the items that have a sales pattern.
  const blocks = BLOCK_LABELS.map((_, block) => {
    let weight = 0, sum = 0, used = 0, n = 0, sec = 0;
    for (const item of items) {
      const b = item.blocks[block];
      n += b.n; sec += b.sec;
      const idx = item.advice.rateIdx[block];
      if (idx === null) continue;
      const w = b.sec - b.msec;
      used++; weight += w; sum += w * idx;
    }
    return {block, rateIdx: used >= minItems && weight > 0 ? sum / weight : null, items: used, n, sec};
  });
  let advice;
  if (single) advice = items[0].advice;
  else {
    const price = (pattern ?? timingPattern(timing, ids)).blocks;
    const shaped = blocks.map((b, i) => ({priceOK: price[i].usable && isInt(price[i].value), p: price[i].usable ? price[i].value : null, rateIdx: b.rateIdx}));
    const ok = shaped.flatMap((b, i) => b.rateIdx !== null ? [i] : []);
    let best = null, reason = "pocos";
    if (ok.length >= SALES_RULE.minBlocks) {
      const score = i => (10000 + (shaped[i].priceOK ? shaped[i].p : 0)) * shaped[i].rateIdx;
      best = ok.reduce((a, i) => score(i) > score(a) ? i : a);
      reason = shaped[best].rateIdx >= SALES_RULE.faster ? "ventas" : "precio";
    } else {
      best = pricePattern(shaped);
      if (best !== null) reason = "precio-alto";
    }
    advice = {salesOK: blocks.map(b => b.rateIdx !== null), rateIdx: blocks.map(b => b.rateIdx), best, reason, hint: best === null ? null : [(4 * best + 23) % 24, 4 * best]};
  }
  return {any, items: items.map(({id, blocks: b, advice: a}) => ({id, blocks: b, advice: a})), advice, blocks,
    cells: cells.map(({weight, sum, ...x}) => x)};
}
/** What «Cuándo vender» says about sales: the advice line when there is a best block, and why there is no sales
 * pattern when there is none. */
export function salesLines(sales) {
  const lines = [], text = adviceText(sales?.advice);
  if (text) lines.push(text);
  const pattern = sales?.advice && (sales.advice.reason === "ventas" || sales.advice.reason === "precio");
  if (!pattern) lines.push(sales?.any ? FEW_SALES : NO_SALES_YET);
  return lines;
}

/** The bars beside the heatmap, each list with its best and worst marked when they differ. Price (no sales): the six
 * blocks and the seven weekdays in basis points against the week. Sales (timingSales): the six blocks as times the
 * usual rate, and no weekdays. Returns {unit: "bp" | "rate", hours: [6], days: [7] | null} of {label, value, text,
 * usable, n, best, worst}. */
export function timingSlots(pattern, sales = null) {
  const mark = rows => {
    const usable = rows.filter(r => r.usable);
    if (usable.length >= 2) {
      const best = usable.reduce((a, b) => b.value > a.value ? b : a), worst = usable.reduce((a, b) => b.value < a.value ? b : a);
      if (best.value !== worst.value) { best.best = true; worst.worst = true; }
    }
    return rows;
  };
  const row = (label, value, usable, n, text) => ({label, value: usable ? value : null, usable, n, text: usable ? text : n ? "pocos" : "—", best: false, worst: false});
  if (sales) return {unit: "rate", days: null,
    hours: mark(sales.blocks.map(b => row(BLOCK_LABELS[b.block], b.rateIdx, b.rateIdx !== null, b.n, formatRate(b.rateIdx))))};
  return {unit: "bp",
    hours: mark((pattern?.blocks ?? []).map(b => row(BLOCK_LABELS[b.block], b.value, b.usable && isInt(b.value), b.n, formatPct(b.value)))),
    days: mark((pattern?.weekdays ?? []).map(d => row(WEEKDAYS_LONG[d.wd], d.value, d.usable && isInt(d.value), d.n, formatPct(d.value))))};
}
/** The answers at the top of «Cuándo vender», most useful first: the best moment (and the worst) of the price pattern,
 * and when to post from the sales advice. advice: timingSummary with .sales (timingSales) when known.
 * [{key, label, name, note, tone: "good" | "bad" | null}]. */
export function sellAnswers(advice) {
  const out = [], cap = text => text.charAt(0).toUpperCase() + text.slice(1);
  const moment = c => `${cap(WEEKDAYS_LONG[c.wd])}, ${BLOCK_LABELS[c.block]}`;
  if (advice?.best) out.push({key: "best", label: "El mejor momento", name: moment(advice.best), tone: "good",
    note: `Se paga ${pctWords(advice.best.value)} de lo normal de esa semana.`});
  const s = advice?.sales?.advice;
  if (s && s.best !== null && s.hint) out.push({key: "post", label: s.reason === "ventas" ? "Cuándo se vende más" : s.reason === "precio" ? "Cuándo se vende mejor" : "La franja con mejor precio",
    name: `De ${4 * s.best} a ${4 * s.best + 4} h`, tone: advice?.best ? null : "good",
    note: `Pon o iguala el precio hacia las ${s.hint[0]}-${s.hint[1]} h, con 2 h (u 8 h si no vas a volver).`});
  if (advice?.worst) out.push({key: "worst", label: "El peor momento", name: moment(advice.worst), tone: "bad",
    note: `Se paga ${pctWords(advice.worst.value)} de lo normal de esa semana.`});
  return out;
}
/** What «Cuándo vender» can look at: the whole market, each category of the summary and the fishing groups.
 * {market: {key: "todo", label, ids: null}, cats: [{key: "cat:<cat>", label, ids}], fish: [{key, label, ids}]}. */
export function sellGroups(summary) {
  const fish = fishGroups();
  return {market: fish.find(g => g.key === "todo"),
    cats: groupByCategory(summary?.items ?? []).map(g => ({key: "cat:" + g.cat, label: g.items[0].catLabel ?? g.cat, ids: g.items.map(e => e.id)})),
    fish: fish.filter(g => g.key !== "todo")};
}

// ---- Pesca: qué pescar, dónde, qué hacer con cada pez (y cuándo venderlo, en su pestaña) -------------------------
/** Raw fish the addon watches (Data.WATCH «comida» since 0.5.0) with the lowest fishing skill that catches it in
 * open water (3 % or more) or in a pool. */
export const FISH = Object.freeze([
  {id: 6291, skill: 1}, {id: 6303, skill: 1}, {id: 6289, skill: 1}, {id: 6317, skill: 1}, {id: 6361, skill: 1}, {id: 6308, skill: 1},
  {id: 21071, skill: 1}, {id: 6522, skill: 1}, {id: 6358, skill: 1}, {id: 6359, skill: 55}, {id: 6362, skill: 130}, {id: 8365, skill: 130},
  {id: 21153, skill: 130}, {id: 4603, skill: 130}, {id: 13754, skill: 205}, {id: 13758, skill: 205}, {id: 13756, skill: 330}, {id: 13755, skill: 205},
  {id: 13759, skill: 205}, {id: 13760, skill: 205}, {id: 13889, skill: 55}, {id: 13893, skill: 205}, {id: 13888, skill: 205}, {id: 13422, skill: 130},
  {id: 13757, skill: 330},
]);
/** Cooking and alchemy with fish: Wowhead Classic (checked 2026-11), plus the elixirs that use the oils. qty: units made. */
export const FISH_RECIPES = Object.freeze([
  {prof: "cooking", product: 4592, qty: 1, skill: 50, reagents: [[6289, 1]]},
  {prof: "cooking", product: 5095, qty: 1, skill: 50, reagents: [[6361, 1]]},
  {prof: "cooking", product: 21072, qty: 1, skill: 80, reagents: [[21071, 1], [2678, 1]]},
  {prof: "cooking", product: 6657, qty: 1, skill: 85, reagents: [[6522, 1], [2678, 1]]},
  {prof: "cooking", product: 4593, qty: 1, skill: 100, reagents: [[6308, 1]]},
  {prof: "cooking", product: 4594, qty: 1, skill: 175, reagents: [[6362, 1]]},
  {prof: "cooking", product: 8364, qty: 1, skill: 175, reagents: [[8365, 1]]},
  {prof: "cooking", product: 21217, qty: 1, skill: 175, reagents: [[21153, 1], [2692, 1]]},
  {prof: "cooking", product: 6887, qty: 1, skill: 225, reagents: [[4603, 1]]},
  {prof: "cooking", product: 13927, qty: 1, skill: 225, reagents: [[13754, 1], [3713, 1]]},
  {prof: "cooking", product: 13930, qty: 1, skill: 225, reagents: [[13758, 1]]},
  {prof: "cooking", product: 13928, qty: 1, skill: 240, reagents: [[13755, 1], [3713, 1]]},
  {prof: "cooking", product: 13929, qty: 1, skill: 240, reagents: [[13756, 1], [2692, 2]]},
  {prof: "cooking", product: 13931, qty: 1, skill: 250, reagents: [[13759, 1], [159, 1]]},
  {prof: "cooking", product: 13932, qty: 1, skill: 250, reagents: [[13760, 1]]},
  {prof: "cooking", product: 13933, qty: 1, skill: 275, reagents: [[13888, 1], [159, 1]]},
  {prof: "cooking", product: 13934, qty: 1, skill: 275, reagents: [[13893, 1], [2692, 1], [3713, 1]]},
  {prof: "cooking", product: 13935, qty: 1, skill: 275, reagents: [[13889, 1], [3713, 1]]},
  {prof: "alchemy", product: 6370, qty: 1, skill: 80, reagents: [[6358, 2], [3371, 1]]},
  {prof: "alchemy", product: 6371, qty: 1, skill: 130, reagents: [[6359, 2], [3371, 1]]},
  {prof: "alchemy", product: 13423, qty: 1, skill: 250, reagents: [[13422, 1], [3372, 1]]},
  {prof: "alchemy", product: 5634, qty: 1, skill: 150, reagents: [[6370, 2], [3820, 1], [3372, 1]]},
  {prof: "alchemy", product: 6373, qty: 1, skill: 140, reagents: [[6371, 2], [3356, 1], [3372, 1]]},
  {prof: "alchemy", product: 21546, qty: 1, skill: 250, reagents: [[6371, 3], [4625, 3], [8925, 1]]},
  {prof: "alchemy", product: 13445, qty: 1, skill: 265, reagents: [[13423, 2], [8838, 1], [8925, 1]]},
]);
/** What a merchant pays for fish the panel may have no price of (sell) and what spices and vials cost there (buy), copper. */
export const FISH_VENDOR = Object.freeze({
  6291: {name: "Pececito luminoso crudo", sell: 1},
  6289: {name: "Pargo de loco boquilargo crudo", sell: 1},
  6308: {name: "Siluro mostacherizo crudo", sell: 2},
  6362: {name: "Bacalao Piedrescama crudo", sell: 4},
  4603: {name: "Serviola moteada cruda", sell: 4},
  8365: {name: "Trucha cabeza de mitril cruda", sell: 4},
  13754: {name: "Vigorpez lustroso crudo", sell: 6},
  13893: {name: "Vigorpez crudo grande", sell: 15},
  13758: {name: "Branquirrojo crudo", sell: 4},
  13759: {name: "Pargo nocturno crudo", sell: 10},
  13760: {name: "Salmón escama de sol crudo", sell: 10},
  13889: {name: "Salmón escama blanca crudo", sell: 5},
  13756: {name: "Lubina cruda", sell: 9},
  13755: {name: "Calamar de invierno", sell: 7},
  21071: {name: "Sabiola cruda", sell: 25},
  21153: {name: "Sabiola cruda superior", sell: 125},
  6361: {name: "Atún blanco arco iris crudo", sell: 2},
  6317: {name: "Frenesí del lago crudo", sell: 2},
  6303: {name: "Caballa suave cruda", sell: 1},
  6358: {name: "Bocanegra graso", sell: 4},
  6359: {name: "Pargo de Fuego", sell: 5},
  13422: {name: "Anguila Escama Tormentosa", sell: 10},
  6522: {name: "Pez descarriado", sell: 4},
  13888: {name: "Langosta pinza oscura", sell: 12},
  13757: {name: "Anguila relámpago", sell: 10},
  5523: {name: "Percebe pequeño", sell: 15},
  5524: {name: "Almeja de concha espesa", sell: 21},
  7973: {name: "Almeja de boca grande", sell: 46},
  7070: {name: "Elemental de agua", sell: 400},
  3820: {name: "Alga estranguladora", sell: 100},
  2678: {name: "Especias suaves", buy: 10},
  2692: {name: "Especias picantes", buy: 40},
  3713: {name: "Especias calmantes", buy: 160},
  159: {name: "Agua de manantial refrescante", buy: 25},
  3371: {name: "Vial vacío", buy: 20},
  3372: {name: "Vial con plomo", buy: 200},
  8925: {name: "Vial de cristal", buy: 2500},
});
/** Open water by zone: catches [[itemID, % of casts]] from Wowhead Classic (zones with 1 000+ casts; Eastern Plaguelands
 * comes as two samples, its lakes and its coast; the rest of 100 % is junk), clean: the skill without fish getting away,
 * skill: the least to fish there (clean − 95). */
export const FISH_ZONES = Object.freeze([
  {key: "elwynn-forest", name: "Bosque de Elwynn", skill: 1, clean: 25, catches: [[6291, 59], [6289, 37.1]]},
  {key: "tirisfal-glades", name: "Claros de Tirisfal", skill: 1, clean: 25, catches: [[6291, 45.4], [6289, 29], [6303, 1.2], [8365, 1.1], [6308, 0.8]]},
  {key: "dun-morogh", name: "Dun Morogh", skill: 1, clean: 25, catches: [[6291, 60], [6289, 38.1]]},
  {key: "durotar", name: "Durotar", skill: 1, clean: 25, catches: [[6303, 59.7], [6291, 22.2], [6289, 15.4], [6308, 0.6]]},
  {key: "mulgore", name: "Mulgore", skill: 1, clean: 25, catches: [[6291, 59.8], [6289, 38.2]]},
  {key: "teldrassil", name: "Teldrassil", skill: 1, clean: 25, catches: [[6303, 56.2], [6291, 25.5], [6289, 16.2]]},
  {key: "silverpine-forest", name: "Bosque de Argénteos", skill: 1, clean: 75, catches: [[6358, 36.4], [6361, 18.7], [6303, 12.3], [21071, 5.4], [6289, 5.2], [6308, 1.9], [6291, 1.3]]},
  {key: "thunder-bluff", name: "Cima del Trueno", skill: 1, clean: 75, catches: [[6289, 60], [6308, 21.9], [6291, 17]]},
  {key: "stormwind-city", name: "Ciudad de Ventormenta", skill: 1, clean: 75, catches: [[6289, 60], [6308, 21.9], [6291, 17.1]]},
  {key: "darkshore", name: "Costa Oscura", skill: 1, clean: 75, catches: [[6361, 19.1], [6358, 16.3], [6303, 13.1], [6289, 9.8], [6308, 3.5], [6291, 2.9]]},
  {key: "darnassus", name: "Darnassus", skill: 1, clean: 75, catches: [[6289, 59.9], [6308, 22], [6291, 17]]},
  {key: "undercity", name: "Entrañas", skill: 1, clean: 75, catches: [[6289, 41.7], [6308, 15], [6291, 11.7]]},
  {key: "loch-modan", name: "Loch Modan", skill: 1, clean: 75, catches: [[6289, 30], [6317, 21.7], [21071, 21.4], [6308, 11.6], [6291, 8.7]]},
  {key: "the-barrens", name: "Los Baldíos", skill: 1, clean: 75, catches: [[6522, 26.6], [6358, 18.3], [6289, 17.9], [6361, 8], [6308, 6.5], [6303, 5.5], [6291, 5.1], [6359, 0.6]]},
  {key: "orgrimmar", name: "Orgrimmar", skill: 1, clean: 75, catches: [[6289, 59.8], [6308, 22.3], [6291, 16.9]]},
  {key: "westfall", name: "Páramos de Poniente", skill: 1, clean: 75, catches: [[6358, 41.1], [6361, 20.3], [6303, 13.9], [6289, 4.3], [6308, 1.7], [6291, 1.1]]},
  {key: "duskwood", name: "Bosque del Ocaso", skill: 55, clean: 150, catches: [[6308, 47.2], [6289, 30.4], [13889, 5.2], [13759, 2.2], [13760, 2.1], [13757, 1.2], [13758, 0.7]]},
  {key: "hillsbrad-foothills", name: "Laderas de Trabalomas", skill: 55, clean: 150, catches: [[21071, 25.1], [6358, 16.1], [6308, 13.4], [6361, 12.3], [6359, 11.9], [6289, 7.4]]},
  {key: "wetlands", name: "Los Humedales", skill: 55, clean: 150, catches: [[6361, 48.8], [6358, 24.4], [6359, 17], [6308, 1.8], [6289, 1]]},
  {key: "redridge-mountains", name: "Montañas Crestagrana", skill: 55, clean: 150, catches: [[6308, 63.9], [6289, 35.2]]},
  {key: "stonetalon-mountains", name: "Sierra Espolón", skill: 55, clean: 150, catches: [[6308, 48.9], [6289, 27.3], [6359, 8.7], [21071, 6.8]]},
  {key: "ashenvale", name: "Vallefresno", skill: 55, clean: 150, catches: [[6308, 39.2], [6289, 21.3], [6361, 19.3], [6358, 7.8], [21071, 5.6], [6359, 3.1], [13758, 0.8]]},
  {key: "desolace", name: "Desolace", skill: 130, clean: 225, catches: [[8365, 26.5], [6362, 17.5], [6359, 14.8], [6308, 14.4], [6358, 11], [4603, 6.4], [13758, 1]]},
  {key: "thousand-needles", name: "Las Mil Agujas", skill: 130, clean: 225, catches: [[8365, 62.8], [6308, 35], [6522, 0.4]]},
  {key: "dustwallow-marsh", name: "Marjal Revolcafango", skill: 130, clean: 225, catches: [[6362, 27.1], [8365, 23.6], [6308, 12.9], [6359, 10.9], [4603, 10], [6358, 9.9]]},
  {key: "alterac-mountains", name: "Montañas de Alterac", skill: 130, clean: 225, catches: [[21153, 50], [8365, 23.4], [6308, 12.4]]},
  {key: "swamp-of-sorrows", name: "Pantano de las Penas", skill: 130, clean: 225, catches: [[6362, 49], [4603, 17.6], [6359, 10.4], [6358, 10.3], [8365, 7.5], [6308, 4]]},
  {key: "arathi-highlands", name: "Tierras Altas de Arathi", skill: 130, clean: 225, catches: [[8365, 46.2], [6308, 25.6], [6362, 8.8], [6359, 6.4], [6358, 5.3], [4603, 3.2]]},
  {key: "stranglethorn-vale", name: "Vega de Tuercespina", skill: 130, clean: 225, catches: [[6362, 18.4], [6359, 17.8], [6358, 15.7], [4603, 7.3], [21153, 5.2], [13422, 4.9], [8365, 2.8], [6308, 1.5], [13889, 0.4]], note: "la isla Jaguero pide 300"},
  {key: "azshara", name: "Azshara", skill: 205, clean: 300, catches: [[13888, 26.1], [13755, 13.7], [13422, 11.8], [4603, 11.1], [7973, 7.9], [13893, 5.4], [13758, 4.1], [6359, 3.3], [13754, 2.4], [6362, 2.3], [6358, 1.7], [13759, 1.4], [13756, 1.1], [8365, 0.8], [13760, 0.8], [7070, 0.7]], note: "la bahía de las Tormentas pide 425"},
  {key: "moonglade", name: "Claro de la Luna", skill: 205, clean: 300, catches: [[13758, 50.2], [13759, 21.8], [8365, 10], [6358, 10], [13760, 6.2], [13757, 0.7]]},
  {key: "un-goro-crater", name: "Cráter de Un'Goro", skill: 205, clean: 300, catches: [[13758, 49.5], [13759, 21.6], [8365, 10.2], [6358, 10], [13760, 6.3], [13757, 0.9]]},
  {key: "feralas", name: "Feralas", skill: 205, clean: 300, catches: [[13758, 31.8], [13759, 12.1], [6358, 9.3], [4603, 9], [8365, 6.3], [13760, 5.7], [6359, 5.3], [13422, 5], [13754, 2.2], [6362, 2.2], [7973, 1.9], [13755, 1.7], [13757, 0.9], [13889, 0.7], [13756, 0.5]], note: "el lago Jademir puede pedir más"},
  {key: "felwood", name: "Frondavil", skill: 205, clean: 300, catches: [[13758, 50.6], [13759, 18.7], [8365, 9.9], [6358, 9.6], [13760, 8.8], [13757, 1.4]]},
  {key: "tanaris", name: "Tanaris", skill: 205, clean: 300, catches: [[4603, 27.4], [6359, 14.3], [13422, 13.6], [6358, 7.7], [6362, 7], [13754, 6.5], [7973, 5.9], [13755, 5.3], [13756, 1.6]]},
  {key: "western-plaguelands", name: "Tierras de la Peste del Oeste", skill: 205, clean: 300, catches: [[13758, 50.3], [13759, 20], [8365, 10.1], [6358, 10], [13760, 7.7], [13757, 0.9]]},
  {key: "the-hinterlands", name: "Tierras del Interior", skill: 205, clean: 300, catches: [[13758, 24.2], [4603, 21.5], [13759, 10], [13754, 5.6], [6359, 5.3], [6362, 5.3], [13422, 5.1], [6358, 4.8], [8365, 4.7], [7973, 4.1], [13760, 3.2], [13755, 2.9], [13756, 2], [13757, 0.3]]},
  {key: "winterspring", name: "Cuna del Invierno", skill: 330, clean: 425, catches: [[13889, 39.4], [13759, 19.8], [13760, 10.6], [13757, 6.8], [13758, 5]], note: "habilidad orientativa: las guías dan 300 o 425"},
  {key: "deadwind-pass", name: "Paso de la Muerte", skill: 330, clean: 425, catches: [[13889, 40.1], [13759, 19], [13760, 10.7], [13757, 7.8], [13758, 4.8]], note: "habilidad orientativa: las guías dan 300 o 425"},
  {key: "eastern-plaguelands", name: "Tierras de la Peste del Este (lagos)", skill: 330, clean: 425, catches: [[13889, 37.4], [13759, 19.1], [13760, 10.9], [13757, 7.6], [13758, 6.9], [8365, 0.5], [6358, 0.5]], note: "habilidad orientativa: las guías dan 300 o 425"},
  {key: "eastern-plaguelands-coast", name: "Tierras de la Peste del Este (costa)", skill: 330, clean: 425, catches: [[13888, 45.2], [13756, 20.3], [13422, 11.3], [7973, 9.6], [13893, 8.2], [4603, 3.1]], note: "pocos datos: unas 2 000 capturas en Wowhead; habilidad orientativa"},
]);
/** Fishing pools: Wowhead has no loot table for them; the guides say most catches are the pool's fish, so 4 out of 5 count. */
export const FISH_POOLS = Object.freeze([
  {key: "bocanegra", name: "Banco de bocanegra graso", skill: 1, clean: 75, catches: [[6358, 80]], where: "costas de Costa Oscura, Bosque de Argénteos, Los Baldíos, Páramos de Poniente y el lago de Loch Modan"},
  {key: "sabiola", name: "Banco de sabiolas", skill: 1, clean: 75, catches: [[21071, 80]], where: "lagos y ríos de Loch Modan, Bosque de Argénteos, Vallefresno, Laderas de Trabalomas y Sierra Espolón"},
  {key: "descarriado", name: "Banco de peces descarriados", skill: 1, clean: 75, catches: [[6522, 80]], where: "oasis de Los Baldíos y las Cuevas de los Lamentos"},
  {key: "pargo-fuego", name: "Banco de pargos de fuego", skill: 55, clean: 150, catches: [[6359, 80]], where: "costas de nivel 20-30: Los Humedales, Laderas de Trabalomas, Sierra Espolón"},
  {key: "petroleo", name: "Vertido de petróleo", skill: 55, clean: 150, catches: [[6359, 60]], where: "lago de Sierra Espolón (da menos pargos que un banco)"},
  {key: "sabiola-superior", name: "Banco superior de sabiolas", skill: 130, clean: 225, catches: [[21153, 80]], where: "ríos y lagos de interior de las Montañas de Alterac y la Vega de Tuercespina"},
  {key: "anguila", name: "Banco de anguilas Escama Tormentosa", skill: 205, clean: 300, catches: [[13422, 80]], where: "costas de Azshara, Feralas y Tanaris"},
]);
/** Winter Squid only bites in winter and Summer Bass only in summer; Nightfin Snapper at night and Sunscale Salmon by day. */
export const FISH_WHEN = Object.freeze({13755: {season: "invierno"}, 13756: {season: "verano"}, 13759: {night: true}, 13760: {day: true}});
/** Catches an hour fishing on your own, without pools (the cast, the bite and looting); the player can change it. */
export const CATCHES_PER_HOUR = 200;
/** Catches a pool gives before it disappears, roughly. */
export const POOL_CATCHES = 4;

const fishLabel = (items, id) => { const e = items.get(id); return e ? nameOf(e) : FISH_VENDOR[id]?.name ?? `Objeto ${id}`; };
/** What one unit of each item is worth to you, doing the best you can with it: selling it at the market (after the cut),
 * to a merchant, or turning it into something worth more with the recipes your skills allow (an oil is worth what its
 * elixir pays, if that is more). skills: {cooking, alchemy}, null for any. Returns worth(id) -> {id, name, options:
 * [{kind, label, value, ok, ...}] best first, best (the best option you can do, or null)}. A recipe counts only when its
 * product and every other reagent have a price: spices and vials at the merchant, the rest at the market (today's or the
 * last days'). */
export function fishWorth(summary, {cooking = null, alchemy = null} = {}) {
  const items = itemsById(summary), cutBp = summary?.cutBp ?? rules().CUT_BP, memo = new Map(), using = new Map();
  for (const r of FISH_RECIPES) for (const [id] of r.reagents) { if (!using.has(id)) using.set(id, []); using.get(id).push(r); }
  const skillOf = prof => prof === "cooking" ? cooking : alchemy;
  function worth(id, depth = 0) {
    if (memo.has(id)) return memo.get(id);
    const e = items.get(id), options = [], sale = salePrice(e);
    if (sale) options.push({kind: "subasta", label: "Venderlo en la subasta", value: afterCut(sale.price, cutBp), source: sale.source, ok: true});
    const vendor = isInt(e?.vendor) && e.vendor > 0 ? e.vendor : FISH_VENDOR[id]?.sell ?? null;
    if (isInt(vendor) && vendor > 0) options.push({kind: "mercader", label: "Vendérselo al mercader", value: vendor, ok: true});
    if (depth < 3) for (const r of using.get(id) ?? []) {
      const product = worth(r.product, depth + 1);
      if (!product.best) continue;
      let cost = 0, missing = false;
      const others = [];
      for (const [rid, n] of r.reagents) {
        if (rid === id) continue;
        const merchant = FISH_VENDOR[rid]?.buy ?? VENDOR_ITEMS[rid]?.buy ?? null, bought = isInt(merchant) ? null : buyPrice(items.get(rid));
        const unit = isInt(merchant) ? merchant : bought?.price ?? null;
        if (!isInt(unit)) { missing = true; break; }
        cost += unit * n;
        others.push(`${n} × ${fishLabel(items, rid)}${isInt(merchant) ? " del mercader" : ""}`);
      }
      if (missing) continue;
      const mine = r.reagents.find(([rid]) => rid === id)[1], skill = skillOf(r.prof);
      const chain = product.best.kind === "cooking" || product.best.kind === "alchemy" ? product.best : null;
      options.push({kind: r.prof, label: `${r.prof === "cooking" ? "Cocinarlo" : "Destilarlo"}: ${fishLabel(items, r.product)}${chain ? ` y después ${fishLabel(items, chain.product)}` : ""}`,
        value: Math.floor((product.best.value * r.qty - cost) / mine), product: r.product, need: mine, skill: r.skill, prof: r.prof,
        chainSkill: chain ? chain.skill : null, ok: !isInt(skill) || skill >= r.skill, cost, others,
        sellAs: product.best.kind === "mercader" ? "al mercader" : chain ? null : "en la subasta"});
    }
    options.sort((a, b) => b.value - a.value || a.kind.localeCompare(b.kind));
    const result = {id, name: fishLabel(items, id), options, best: options.find(o => o.ok) ?? null};
    memo.set(id, result);
    return result;
  }
  return worth;
}

/** The season of a day index: "verano" from April to September, "invierno" the rest (orientative: the guides do not agree on
 * the exact day). */
export function fishSeason(T) {
  const month = new Date((rules().DAY0 + T * 86400 + 43200) * 1000).getUTCMonth() + 1;
  return month >= 4 && month <= 9 ? "verano" : "invierno";
}
const inSeason = (id, season) => !FISH_WHEN[id]?.season || FISH_WHEN[id].season === season;
/** Expected value of one catch from [[id, % of casts]]: out-of-season fish are left out and the others take their share
 * (the junk keeps its own). {value, pct (the share of the fish with a price), parts: [{id, name, pct, value, best, bring}]
 * by what they bring}. */
export function catchValue(catches, worth, season) {
  const all = catches.reduce((s, [, pct]) => s + pct, 0), live = catches.filter(([id]) => inSeason(id, season));
  const liveTotal = live.reduce((s, [, pct]) => s + pct, 0);
  if (liveTotal <= 0) return {value: 0, pct: 0, parts: []};
  const scale = all / liveTotal;
  let milli = 0, priced = 0;
  const parts = live.map(([id, pct]) => {
    const w = worth(id), share = pct * scale / 100, value = w.best ? w.best.value : null;
    if (value !== null) { milli += value * share * 1000; priced += pct; }
    return {id, name: w.name, pct: Math.round(pct * scale * 10) / 10, value, best: w.best, bring: value === null ? 0 : value * share};
  }).sort((a, b) => b.bring - a.bring || b.pct - a.pct);
  return {value: Math.floor(milli / 1000), pct: Math.round(priced / liveTotal * 1000) / 10, parts};
}
const okSkill = (need, have) => !isInt(have) || have >= need;
/** Open water by what a catch is worth there, the zones you can fish (skill) only. rate: catches per hour. A zone where
 * less than half of what bites has a price goes to unpriced. Returns {rows (best first), unpriced, season}. */
export function fishZones(summary, {fishing = null, cooking = null, alchemy = null, rate = CATCHES_PER_HOUR} = {}) {
  const worth = fishWorth(summary, {cooking, alchemy}), season = fishSeason(summary?.T ?? 0), rows = [];
  let unpriced = 0;
  for (const zone of FISH_ZONES) {
    if (!okSkill(zone.skill, fishing)) continue;
    const c = catchValue(zone.catches, worth, season);
    if (c.pct < 50) { unpriced++; continue; }
    rows.push({...zone, ...c, perHour: c.value * rate, escapes: isInt(fishing) && fishing < zone.clean});
  }
  rows.sort((a, b) => b.value - a.value || a.skill - b.skill || a.key.localeCompare(b.key));
  return {rows, unpriced, season};
}
/** Fishing pools you can fish, by what a catch and a whole pool (POOL_CATCHES catches) are worth. */
export function fishPools(summary, {fishing = null, cooking = null, alchemy = null} = {}) {
  const worth = fishWorth(summary, {cooking, alchemy}), season = fishSeason(summary?.T ?? 0), rows = [];
  let unpriced = 0;
  for (const pool of FISH_POOLS) {
    if (!okSkill(pool.skill, fishing)) continue;
    const c = catchValue(pool.catches, worth, season);
    if (c.pct < 50) { unpriced++; continue; }
    rows.push({...pool, ...c, perPool: c.value * POOL_CATCHES, escapes: isInt(fishing) && fishing < pool.clean});
  }
  rows.sort((a, b) => b.value - a.value || a.skill - b.skill || a.key.localeCompare(b.key));
  return {rows, unpriced, season};
}
/** Every fish with a price: selling it raw against the best you can do with it. gainBp: the best against the market (null
 * without a market price); locked: what pays more but needs more skill. Returns {rows (by best value), unpriced}. */
export function fishUses(summary, {fishing = null, cooking = null, alchemy = null} = {}) {
  const worth = fishWorth(summary, {cooking, alchemy}), items = itemsById(summary), season = fishSeason(summary?.T ?? 0), rows = [];
  let unpriced = 0;
  for (const fish of FISH) {
    if (!okSkill(fish.skill, fishing)) continue;
    const w = worth(fish.id);
    if (!w.best) { unpriced++; continue; }
    const market = w.options.find(o => o.kind === "subasta") ?? null, vendor = w.options.find(o => o.kind === "mercader") ?? null;
    const gainBp = market && market.value > 0 ? rules().idiv((w.best.value - market.value) * 10000, market.value) : null;
    rows.push({...fish, name: w.name, e: items.get(fish.id) ?? null, options: w.options, best: w.best, market, vendor, gainBp,
      locked: w.options.filter(o => !o.ok && o.value > w.best.value), when: FISH_WHEN[fish.id] ?? null, outOfSeason: !inSeason(fish.id, season)});
  }
  rows.sort((a, b) => b.best.value - a.best.value || a.id - b.id);
  return {rows, unpriced};
}
/** The groups "Cuándo vender" can show: every fish and what is made with it, each part, and the whole market. */
export function fishGroups() {
  const cooked = FISH_RECIPES.filter(r => r.prof === "cooking").map(r => r.product);
  const alchemy = FISH_RECIPES.filter(r => r.prof === "alchemy").map(r => r.product);
  const fish = FISH.map(f => f.id);
  return [{key: "pesca", label: "Todo lo de pesca", ids: [...new Set([...fish, ...cooked, ...alchemy])]},
    {key: "crudo", label: "Pescado crudo", ids: fish},
    {key: "cocinado", label: "Comida de pescado", ids: [...new Set(cooked)]},
    {key: "aceites", label: "Aceites y elixires", ids: [...new Set(alchemy)]},
    {key: "todo", label: "Todo el mercado", ids: null}];
}
/** The four answers at the top of the Pesca view, shaped like bestCards: where to fish without pools, the best pool, what
 * to do with the catch and when to sell. */
export function fishCards(zones, pools, uses, advice, {rate = CATCHES_PER_HOUR} = {}) {
  const zone = zones.rows[0], pool = pools.rows[0], topUse = uses.rows[0];
  const gain = uses.rows.filter(r => r.market && (r.best.kind === "cooking" || r.best.kind === "alchemy") && isInt(r.gainBp) && r.gainBp >= 1000)
    .sort((a, b) => (b.best.value - b.market.value) - (a.best.value - a.market.value) || a.id - b.id)[0];
  const main = row => row.parts.filter(p => p.bring > 0).slice(0, 2).map(p => p.name).join(" y ");
  return [
    zone ? {key: "zone", label: "Dónde pescar sin bancos", target: "#zones-section", good: false, name: zone.name, id: null, amount: zone.perHour, per: "por hora",
      note: `≈ ${formatGSC(zone.value)} por captura a ${rate} capturas por hora · sobre todo ${main(zone)}${zone.escapes ? ` · con menos de ${zone.clean} de pesca se te escapan peces` : ""}`}
      : {key: "zone", label: "Dónde pescar sin bancos", target: "#zones-section", good: false, name: "Sin datos", id: null, amount: null, per: "", note: "Faltan precios de lo que se pesca."},
    pool ? {key: "pool", label: "El mejor banco", target: "#pools-section", good: false, name: pool.name, id: null, amount: pool.perPool, per: "por banco",
      note: `≈ ${formatGSC(pool.value)} por captura · ${pool.where}`}
      : {key: "pool", label: "El mejor banco", target: "#pools-section", good: false, name: "Sin datos", id: null, amount: null, per: "", note: "Faltan precios de lo que dan los bancos."},
    gain ? {key: "use", label: "Qué hacer con lo pescado", target: "#uses-section", good: true, name: gain.name, id: gain.id, amount: gain.best.value - gain.market.value, per: "más por pez",
      note: `${gain.best.label}: ${formatPct(gain.gainBp)} que venderlo crudo`}
      : {key: "use", label: "Qué hacer con lo pescado", target: "#uses-section", good: false, name: topUse ? "Véndelo crudo" : "Sin datos", id: null, amount: null, per: "",
        note: topUse ? "Hoy ninguna receta paga al menos un 10 % más que vender el pescado crudo." : "Faltan precios del pescado."},
    sellCard(advice)];
}
/** The «Cuándo vender» card: the best block of the sales advice when there is a sales pattern, else the price summary's
 * best moment. advice: timingSummary, with the sales (timingSales) in advice.sales when known. */
function sellCard(advice) {
  const sales = advice.sales?.advice, base = {key: "sell", label: "Cuándo vender", target: "#sell-section", id: null, amount: null, per: ""};
  if (sales && (sales.reason === "ventas" || sales.reason === "precio")) {
    const idx = sales.rateIdx[sales.best];
    return {...base, good: sales.reason === "ventas", name: `De ${4 * sales.best} a ${4 * sales.best + 4} h`,
      note: `${sales.reason === "ventas" ? `Se vende más (${formatRate(idx)})` : "Mejor precio y ventas normales"}: pon o iguala el precio hacia las ${sales.hint[0]}-${sales.hint[1]} h.`};
  }
  return {...base, good: advice.level === "claro" && !!advice.best,
    name: advice.best ? `El ${WEEKDAYS_LONG[advice.best.wd]} ${BLOCK_TEXT[advice.best.block]}` : advice.title,
    note: advice.best ? `Su precio más bajo suele estar ${pctWords(advice.best.value)} de su nivel de esa semana.` : advice.lines[0] ?? ""};
}

// ---- Tus sesiones de pesca: Forever Fishing (GET /api/guild/fishing, src/fishing.mjs), valued with the day's prices --
/** The zone of a Forever Fishing place: "Feralas: Bastión Plumaluna" -> "Feralas"; "?" (catches without a place) ->
 * "Sin lugar". */
export function fishingZoneOf(place) {
  const zone = place === "?" ? "" : String(place ?? "").split(":")[0].trim();
  return zone || "Sin lugar";
}
/** Seconds as "2 h 17 min", "49 min" or "menos de 1 min". */
export function formatSpan(seconds) {
  if (!isInt(seconds) || seconds < 60) return "menos de 1 min";
  const h = Math.floor(seconds / 3600), m = Math.floor(seconds % 3600 / 60);
  return h ? `${h} h${m ? ` ${m} min` : ""}` : `${m} min`;
}
/** A unix time on Spain's clock, with its weekday: "mar 17 nov, 20:20". */
export function sessionWhen(t) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("es-ES", {timeZone: "Europe/Madrid", year: "numeric", month: "numeric", day: "numeric",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23"}).formatToParts(new Date(t * 1000)).map(x => [x.type, x.value]));
  const wd = (new Date(Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day))).getUTCDay() + 6) % 7;
  return `${WEEKDAYS_SHORT[wd]} ${Number(p.day)} ${MONTHS[Number(p.month) - 1]}, ${p.hour}:${p.minute}`;
}
/** A view link's token (?ver=): what the server's HMAC gives, base64url without padding. */
export const VIEW_TOKEN = /^[A-Za-z0-9_-]{43}$/;
/** Time with the rod a session needs for its pace and gold per hour to be shown (shorter ones show only their total). */
export const FISHING_MIN_SECONDS = 600;
/** Fewer catches than this in a zone: what bites there is only orientative. */
export const FISHING_FEW = 100;
/** Your pace: catches per hour with the rod in hand over every session, or null with less than half an hour in all.
 * {rate, catches, seconds, sessions}. */
export function fishingRate(sessions) {
  let catches = 0, seconds = 0, n = 0;
  for (const s of sessions ?? []) if (isInt(s.seconds) && s.seconds > 0 && isInt(s.catches)) { catches += s.catches; seconds += s.seconds; n++; }
  return seconds >= 1800 ? {rate: Math.round(catches * 3600 / seconds), catches, seconds, sessions: n} : null;
}
/** Every session valued with the day's prices: what you caught times what each catch is worth to you (worth: fishWorth
 * with your skills) and selling everything as it comes (raw: fishWorth without recipes). Newest first: {start, end,
 * seconds, catches, perHourCatches, value, raw, perHour, rawPerHour, unpriced (catches without any price), zones:
 * [{zone, catches}], member (the owner's view only)}. Per hour only with FISHING_MIN_SECONDS with the rod. */
export function fishingSessionRows(fishing, worth, raw) {
  return (fishing?.sessions ?? []).map(s => {
    let value = 0, plain = 0, unpriced = 0;
    const zones = new Map();
    for (const [place, items] of Object.entries(s.zones ?? {})) {
      const zone = fishingZoneOf(place);
      for (const [key, n] of Object.entries(items ?? {})) {
        if (!isInt(n)) continue;
        const id = Number(key), best = worth(id).best, sold = raw(id).best;
        zones.set(zone, (zones.get(zone) ?? 0) + n);
        if (best) value += best.value * n; else unpriced += n;
        if (sold) plain += sold.value * n;
      }
    }
    const timed = isInt(s.seconds) && s.seconds >= FISHING_MIN_SECONDS;
    const perHour = x => timed ? Math.round(x * 3600 / s.seconds) : null;
    return {start: s.start, end: s.end, seconds: s.seconds, catches: s.catches, perHourCatches: perHour(s.catches),
      value, raw: plain, perHour: perHour(value), rawPerHour: perHour(plain), unpriced, member: s.member ?? null,
      zones: [...zones].map(([zone, catches]) => ({zone, catches})).sort((a, b) => b.catches - a.catches || a.zone.localeCompare(b.zone, "es"))};
  }).sort((a, b) => b.start - a.start);
}
/** What really bites in each zone, from every session the guild sent (fishing.guild.zones), valued like fishZones: the
 * average catch (a catch without a price counts as nothing) and per hour at rate. Zones with enough catches first, then
 * by value: {zone, catches, value, perHour, pct (share with a price), few, parts: [{id, name, pct, value, best}],
 * places: [{place, catches}] (the subzones, most fished first)}. */
export function fishingPlaces(fishing, worth, rate = CATCHES_PER_HOUR) {
  const zones = new Map();
  for (const [place, items] of Object.entries(fishing?.guild?.zones ?? {})) {
    const zone = fishingZoneOf(place);
    if (!zones.has(zone)) zones.set(zone, {items: new Map(), places: new Map(), catches: 0});
    const z = zones.get(zone);
    for (const [key, n] of Object.entries(items ?? {})) {
      if (!isInt(n) || n <= 0) continue;
      z.items.set(Number(key), (z.items.get(Number(key)) ?? 0) + n);
      z.places.set(place, (z.places.get(place) ?? 0) + n);
      z.catches += n;
    }
  }
  const rows = [];
  for (const [zone, z] of zones) {
    if (!z.catches) continue;
    let total = 0, priced = 0;
    const parts = [...z.items].map(([id, n]) => {
      const w = worth(id), value = w.best ? w.best.value : null;
      if (value !== null) { total += value * n; priced += n; }
      return {id, name: w.name, n, pct: Math.round(n * 1000 / z.catches) / 10, value, best: w.best, bring: value === null ? 0 : value * n};
    }).sort((a, b) => b.bring - a.bring || b.n - a.n || a.id - b.id);
    const value = Math.floor(total / z.catches);
    rows.push({zone, catches: z.catches, value, perHour: value * rate, pct: Math.round(priced * 1000 / z.catches) / 10, few: z.catches < FISHING_FEW, parts,
      places: [...z.places].map(([place, catches]) => ({place: place === "?" ? "sin lugar" : place.slice(place.indexOf(":") + 1).trim() || place, catches}))
        .sort((a, b) => b.catches - a.catches || a.place.localeCompare(b.place, "es"))});
  }
  rows.sort((a, b) => Number(a.few) - Number(b.few) || b.value - a.value || a.zone.localeCompare(b.zone, "es"));
  return rows;
}

// =================================================================================================================
// Page (browser only)
// =================================================================================================================
function boot(doc, win) {
  const $ = selector => doc.querySelector(selector);
  const state = {me: null, csrf: "", market: null, summary: null, detail: null, filters: {q: "", cat: "", show: "", conf: ""},
    sort: {key: "", dir: "asc"}, view: "hoy", lastUpload: null, pollTimer: null, members: null, busy: false,
    compensa: {skills: {mining: "", herbalism: "", skinning: ""}, open: {}, budget: "", rare: false, cat: ""}, favorites: new Set(), chollosAll: false,
    pesca: {skill: "", cook: "", alch: "", rate: ""}, vender: {group: "todo", mode: "precio"}, timing: null, timingKey: null, timingLoading: false, timingError: "",
    fishing: null, fishingKey: null, fishingLoading: false};
  let toastTimer;
  let cartera = null;
  /** The portfolio tab, while the owner is the one signed in: this page may stay open after they log out. */
  const owned = () => state.me?.isOwner ? cartera : null;
  try { state.favorites = new Set(parseFavorites(win.localStorage.getItem("hermandad.lista"))); } catch { /* private mode */ }
  // The secret view link (/hermandad?ver=…): read-only without signing in. Kept for this tab only, so the brand link
  // (/hermandad) keeps it; a session always wins over it.
  // pinView: the panel has a 4-digit access code (GUILD_VIEW_PIN), so the login screen asks for it; pinSession: this
  // device is looking with that code (the server keeps it 30 days in an HttpOnly cookie).
  let viewToken = null, viewDead = false, pinView = false, pinSession = false;
  try {
    const given = new URLSearchParams(win.location.search).get("ver");
    if (given && VIEW_TOKEN.test(given)) { viewToken = given; win.sessionStorage.setItem("hermandad.ver", given); }
    else { const kept = win.sessionStorage.getItem("hermandad.ver"); viewToken = kept && VIEW_TOKEN.test(kept) ? kept : null; }
  } catch { /* private mode */ }

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

  class PanelError extends Error { constructor(message, status, body = null) { super(message); this.status = status; this.body = body; } }
  async function request(path, data) {
    const options = {headers: {Accept: "application/json"}, cache: "no-store", credentials: "same-origin"};
    if (viewToken) options.headers["X-Guild-View"] = viewToken;
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
    if (!response.ok || !body || body.error) throw new PanelError(body?.error || `No se ha podido completar la petición (${response.status}).`, response.status, body);
    return body;
  }
  function handle(error) {
    if (error?.status === 401 && state.me?.viewer && pinSession) {
      // The code was changed (or removed): the cookie no longer opens the panel.
      pinSession = false; pinView = !!error.body?.pin;
      return pinView ? showLogin("El código de la hermandad ha cambiado. Escribe el nuevo.", "#pin-feedback") : showLogin(error.message);
    }
    if (error?.status === 401 && state.me?.viewer) { viewDead = true; return showLogin(error.message); }
    if (error?.status === 401) return showLogin("Tu sesión ha terminado o tu clave ya no es válida. Vuelve a entrar con tu clave o contraseña.");
    if (error?.status === 503) return showFatal(error.message);
    toast(error?.message || "No se ha podido completar la operación.", true);
  }

  // ---- views
  const VIEWS = ["hoy", "mercado", "compensa", "vender", "pesca", "balance", "cartera", "hermandad"];
  const VIEW_ALIASES = {miembros: "hermandad", unirse: "hermandad"};
  const VIEWS_WITH_MARKET = ["hoy", "mercado", "compensa", "vender", "pesca", "balance", "cartera"];
  function showOnly(id) {
    const ids = [].concat(id);
    for (const section of doc.querySelectorAll("[data-screen]")) section.hidden = !ids.includes(section.id);
  }
  /** feedback: where the message goes, under the key (#login-feedback) or under the code (#pin-feedback). */
  function showLogin(message = "", feedback = "#login-feedback") {
    stopPolling();
    state.me = null; state.csrf = "";
    cartera?.unmount();
    $("#tab-cartera").hidden = true; $("#hoy-cartera").hidden = true;
    if ($("#movement").open) $("#movement").close();
    $("#account").hidden = true; $("#tabs").hidden = true; $("#market-bar").hidden = true;
    showOnly("screen-login");
    $("#key-value").value = ""; $("#key-panel").hidden = true;
    $("#login-feedback").textContent = ""; $("#pin-feedback").textContent = ""; $("#pin-code").value = "";
    $(feedback).textContent = message;
    // The code is asked only to who is not already looking with it.
    const askPin = pinView && !pinSession;
    $("#pin-form").hidden = !askPin;
    $("#login-view").hidden = !((viewToken && !viewDead) || pinSession);
    if ($("#detail").open) $("#detail").close();
    $(askPin ? "#pin-code" : "#login-key").focus();
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
    if (view === "hermandad" && state.me?.viewer) view = "hoy";
    state.view = view;
    for (const tab of doc.querySelectorAll("#tabs a")) {
      const active = tab.dataset.tab === view;
      tab.classList.toggle("active", active);
      if (active) tab.setAttribute("aria-current", "page"); else tab.removeAttribute("aria-current");
      // On a phone the sections scroll sideways: the one in use stays in sight.
      if (active && !tab.hidden && $("#tabs").scrollWidth > $("#tabs").clientWidth) tab.scrollIntoView({block: "nearest", inline: "center"});
    }
    showOnly(view === "hermandad" ? (state.me?.canAdmin ? ["screen-miembros", "screen-unirse"] : ["screen-unirse"]) : "screen-" + view);
    $("#market-bar").hidden = !VIEWS_WITH_MARKET.includes(view);
    if (view === "hermandad" && state.me?.canAdmin) loadMembers();
    if (view === "compensa") renderCompensa();
    if (view === "vender") renderVender();
    if (view === "pesca") renderPesca();
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
  $("#pin-form").addEventListener("submit", async event => {
    event.preventDefault();
    const input = $("#pin-code"), button = $("#pin-submit");
    const code = input.value.trim();
    if (!/^[0-9]{4}$/.test(code)) { $("#pin-feedback").textContent = "El código son 4 cifras, sin letras ni espacios."; input.focus(); return; }
    button.disabled = true; $("#pin-feedback").textContent = "";
    try {
      await request("/api/guild/pin", {code});
      input.value = "";
      await start();
    } catch (error) {
      $("#pin-feedback").textContent = error.message || "No se ha podido comprobar el código.";
      input.value = ""; input.focus();
    } finally { button.disabled = false; }
  });
  $("#login-show").addEventListener("change", event => { $("#login-key").type = event.target.checked ? "text" : "password"; });
  $("#login-view").addEventListener("click", () => { $("#login-feedback").textContent = ""; start(); });
  $("#logout").addEventListener("click", async () => {
    if (state.me?.viewer) return showLogin("Entra con tu clave de la hermandad o, si eres el propietario, con tu contraseña. Sin entrar, el panel se ve en solo lectura.");
    const owner = state.me?.isOwner;
    try { await request("/api/guild/logout", {}); } catch { /* the cookie may already be gone */ }
    if (owner) { try { await ownerLogout(); } catch { /* the session may already be gone */ } }
    showLogin("Has cerrado la sesión.");
  });

  async function start() {
    let me;
    try { me = await request("/api/guild/me"); }
    catch (error) {
      if (error.status !== 401) return showFatal(error.message);
      // The 401 says whether the panel has an access code to offer.
      pinView = !!error.body?.pin; pinSession = false;
      // With a view link and no session, a 401 means the link was changed or turned off.
      if (viewToken) viewDead = true;
      return showLogin(viewToken ? error.message : "");
    }
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
    state.me = me; state.csrf = me.csrf || state.csrf; pinView = !!me.pinView; pinSession = !!me.viaPin;
    $("#account").hidden = false; $("#tabs").hidden = false;
    $("#tab-cartera").hidden = !me.isOwner;
    $("#tab-hermandad").hidden = !!me.viewer;
    const who = me.viewer ? "Solo lectura" : me.isOwner ? "Propietario" : `${me.member?.label ?? "Miembro"} · ${me.role === "admin" ? "administra" : "miembro"}`;
    $("#who").textContent = who;
    $("#logout").textContent = me.viewer ? "Entrar" : "Salir";
    $("#panel-url").value = win.location.origin + "/hermandad";
    renderViewLink();
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
    const frames = [$("#screen-hoy"), $("#screen-mercado"), $("#screen-compensa"), $("#screen-pesca")];
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
    $("#pesca-empty").hidden = !!s;
    $("#pesca-content").hidden = !s;
    $("#vender-empty").hidden = !!s;
    $("#vender-content").hidden = !s;
    if (!s) {
      $("#market-empty-text").textContent = state.me?.markets?.length
        ? "Todavía no hay datos de ese mercado."
        : "Todavía nadie de la hermandad ha subido precios. Cuando alguien escanee la subasta y el sincronizador de su PC envíe los datos, aparecerán aquí.";
      $("#market-empty-admin").hidden = !state.me?.canAdmin;
      $("#banners").replaceChildren();
      $("#compensa-banners").replaceChildren();
      $("#pesca-banners").replaceChildren();
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
    $("#pesca-banners").replaceChildren(...banners());
    $("#hoy-banners").replaceChildren(...banners());
    $("#caveat").textContent = `Recuerda: ${s.caveat}. Los cálculos son estimaciones con los precios que la hermandad ha visto; confírmalos siempre en la subasta.`;
    $("#compensa-caveat").textContent = $("#caveat").textContent;
    renderChollos();
    renderCategoryFilter();
    renderTable();
    renderBalance();
    renderHoy();
    if (state.view === "compensa") renderCompensa();
    if (state.view === "vender") renderVender();
    if (state.view === "pesca") renderPesca();
  }

  // ---- "Chollos de hoy"
  const CHOLLOS_SHOWN = 6;
  $("#chollos-more").addEventListener("click", () => { state.chollosAll = !state.chollosAll; if (state.summary) renderChollos(); });
  function renderChollos() {
    const s = state.summary, byId = new Map(s.items.map(e => [e.id, e]));
    const list = s.chollos.map(id => byId.get(id)).filter(Boolean);
    const shown = state.chollosAll ? list : list.slice(0, CHOLLOS_SHOWN);
    $("#chollos-count").textContent = String(list.length);
    $("#chollos-empty").hidden = list.length > 0;
    $("#chollos-empty").textContent = list.length ? "" : cholloEmptyText(s);
    $("#chollos-list").hidden = list.length === 0;
    $("#chollos-more").hidden = list.length <= CHOLLOS_SHOWN;
    $("#chollos-more").textContent = state.chollosAll ? "Ver solo los primeros" : `Ver los ${list.length} chollos`;
    $("#chollos-list").replaceChildren(...shown.map(e => {
      const f = e.flip, pays = !!f?.accept && f.units > 0;
      return el("li", {class: "chollo" + (f?.accept ? "" : " weak")},
        el("div", {class: "chollo-head"},
          el("button", {type: "button", class: "item-link", text: e.name || `Objeto ${e.id}`, onclick: () => navigateItem(e.id)}),
          el("span", {class: "badge verdict-CHOLLO", text: f?.accept ? "Chollo" : "Chollo · no compensa"})),
        el("p", {class: "chollo-price"}, money(e.price?.lo), el("span", {class: "muted", text: ` · ${(e.statusText || "").replace(/^Chollo: /, "")}`})),
        pays ? el("p", {class: "chollo-gain"}, "Compra hasta ", el("strong", {text: String(f.units)}), " a ", money(f.maxBuy), " como máximo: ganas ", el("strong", {}, money(f.profit)))
          : el("p", {class: "flip-text", text: rules().texts.flip(f, formatGSC)}),
        el("p", {class: "seen muted", text: `Visto por ${f?.who ?? e.price?.member ?? "un compañero"}, ${formatWhen(f?.at ?? e.price?.at, Date.now())} · normal ${formatGSC(e.N)}${pays ? ` · revende a ${formatGSC(f.Rs)}` : ""}`}),
        owned() ? el("p", {class: "row"}, el("button", {type: "button", class: "button subtle small", text: "Registrar compra", onclick: () => owned()?.openMovement("buy", {itemId: e.id, name: e.name, unit: e.price?.lo})})) : null);
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
  const FARM_PROFS = ["mining", "herbalism", "skinning", "cloth"], FARM_SHOWN = 5;
  const skillInputs = [...doc.querySelectorAll("#farm-profs [data-skill]")];
  const saveCompensa = () => { try { win.localStorage.setItem("hermandad.compensa", JSON.stringify({skills: state.compensa.skills, budget: state.compensa.budget})); } catch { /* private mode */ } };
  try {
    const saved = JSON.parse(win.localStorage.getItem("hermandad.compensa") ?? "{}");
    // Before there was one skill per profession there was one skill and one profession: it goes where it was meant.
    const old = typeof saved?.skill === "string" ? saved.skill : "";
    for (const input of skillInputs) {
      const prof = input.dataset.skill, kept = saved?.skills?.[prof];
      const value = typeof kept === "string" ? kept : old && (!saved.prof || saved.prof === prof) ? old : "";
      input.value = value.slice(0, 3); state.compensa.skills[prof] = input.value;
    }
    if (typeof saved?.budget === "string") { $("#resale-budget").value = saved.budget; state.compensa.budget = $("#resale-budget").value; }
  } catch { /* private mode or an old value */ }
  for (const input of skillInputs) {
    input.addEventListener("input", event => { state.compensa.skills[input.dataset.skill] = event.target.value; saveCompensa(); renderCompensa(); });
  }
  $("#resale-budget").addEventListener("input", event => { state.compensa.budget = event.target.value; saveCompensa(); renderCompensa(); });
  for (const box of doc.querySelectorAll("#farm-profs .prof")) {
    box.querySelector("[data-more]").addEventListener("click", () => { state.compensa.open[box.dataset.prof] = !state.compensa.open[box.dataset.prof]; renderCompensa(); });
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
    const budgetText = filters.budget.trim();
    const skillOf = prof => { const text = String(filters.skills[prof] ?? "").trim(); return /^\d{1,3}$/.test(text) ? Number(text) : null; };
    const typed = budgetText ? parseGSC(budgetText) : null, typedOk = typed !== null && typed >= 1 && typed <= 100000000000;
    const budget = typedOk ? typed : s.budget;
    // Every profession with its own skill. The best card compares what is gathered (cloth has no drop rate: apart).
    const profs = FARM_PROFS.map(prof => ({prof, ...farmRows(s, {prof, skill: skillOf(prof), rare: filters.rare})}));
    const gathered = profs.filter(p => p.prof !== "cloth");
    const farm = {profs, unpriced: gathered.reduce((n, p) => n + p.unpriced, 0),
      rows: gathered.flatMap(p => p.rows).sort((a, b) => b.value - a.value || a.skill - b.skill || a.key.localeCompare(b.key))};
    return {budgetBad: !!budgetText && !typedOk, farm, resale: resaleRows(s, {budget}), smelt: smeltRows(s, {budget})};
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
      el("div", {class: "rank-name"}, id === null ? el("span", {class: "rank-place", text: name}) : itemButton(id, name), tag ? el("span", {class: "rank-tag", text: tag}) : null),
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
  /** One column per profession: its best node in large, then the next ones on the same scale. */
  function renderFarm(farm) {
    const title = r => r.name + (r.note ? ` (${r.note})` : "");
    const any = farm.profs.some(p => p.rows.length > 0);
    $("#farm-empty").hidden = any || farm.profs.every(p => p.unpriced === 0);
    $("#farm-empty").textContent = "Todavía no hay precios de estos materiales: aparecerán cuando alguien de la hermandad escanee la subasta.";
    $("#farm-twin").hidden = !any;
    for (const p of farm.profs) {
      const box = doc.querySelector(`#farm-profs .prof[data-prof="${p.prof}"]`), part = name => box.querySelector(`[data-${name}]`);
      const cloth = p.prof === "cloth", open = !!state.compensa.open[p.prof], [best, ...rest] = p.rows;
      const needs = r => `${cloth ? "" : `habilidad ${r.skill} · `}niveles ${r.level[0]}–${r.level[1]}${r.rare ? " · raro" : ""}`;
      part("empty").hidden = p.rows.length > 0;
      part("empty").textContent = p.unpriced ? "Aún no hay precios de esto." : "Con esa habilidad no hay nada de la lista que puedas recoger.";
      part("best").replaceChildren(...(best ? [
        itemButton(best.id, title(best), "item-link best-name"),
        el("span", {class: "best-amount"}, money(best.value), " ", el("small", {text: `por ${best.per}`})),
        el("span", {class: "prof-where", text: needs(best).replace(/^h/, "H").replace(/^n/, "N")}),
        el("span", {class: "prof-where", text: `${cloth ? "Lo sueltan los " : `Da ${partsText(best)}. Dónde: `}${best.zones}.`})] : []));
      const shown = open ? rest : rest.slice(0, FARM_SHOWN - 1), max = best?.value || 1;
      part("list").replaceChildren(...shown.map(r => {
        const fill = el("span", {class: "rank-fill"});
        fill.style.width = Math.max(1, Math.round(100 * r.value / max)) + "%";
        const row = rankRow({id: r.id, name: title(r), tag: needs(r), track: el("span", {class: "rank-base"}, fill), value: [money(r.value)]});
        row.title = `${cloth ? "" : `Da ${partsText(r)}. `}Dónde: ${r.zones}.`;
        return row;
      }));
      part("more").hidden = rest.length <= FARM_SHOWN - 1;
      part("more").textContent = open ? "Ver menos" : `Ver los ${p.rows.length}`;
    }
    $("#farm-table").replaceChildren(twinTable([["Objeto"], ["Profesión"], ["Habilidad", true], ["Niveles"], ["Vale", true], ["Por"], ["Δ7d", true], ["Oferta típica", true], ["Confianza"], ["Precio usado"], ["Da"], ["Zonas"]],
      farm.profs.flatMap(p => p.rows).map(r => [itemButton(r.id, title(r)), cell(r.label), num(r.prof === "cloth" ? "—" : String(r.skill)), cell(`${r.level[0]}–${r.level[1]}`), num(money(r.value)), cell(r.per), num(pctNode(r.d7)), num(formatUnits(r.Q)),
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

  // ---- "Pesca": what to fish, where, what to do with it and when to sell, from the summary and /api/guild/timing
  const PESCA_SAVED = [["#fish-skill", "skill"], ["#fish-cook", "cook"], ["#fish-alch", "alch"], ["#fish-rate", "rate"]];
  const savePesca = () => { try { win.localStorage.setItem("hermandad.pesca", JSON.stringify(state.pesca)); } catch { /* private mode */ } };
  try {
    const saved = JSON.parse(win.localStorage.getItem("hermandad.pesca") ?? "{}");
    for (const [id, key] of PESCA_SAVED) if (typeof saved?.[key] === "string") { $(id).value = saved[key].slice(0, 3); state.pesca[key] = $(id).value; }
  } catch { /* private mode or an old value */ }
  for (const [id, key] of PESCA_SAVED) {
    $(id).addEventListener("input", event => { state.pesca[key] = event.target.value; savePesca(); renderPesca(); });
  }
  // ---- "Cuándo vender": its own tab; what it looks at and «Precio / Ventas» are kept in this browser
  const saveVender = () => { try { win.localStorage.setItem("hermandad.vender", JSON.stringify(state.vender)); } catch { /* private mode */ } };
  try {
    const saved = JSON.parse(win.localStorage.getItem("hermandad.vender") ?? "{}");
    if (typeof saved?.group === "string") state.vender.group = saved.group;
    if (saved?.mode === "ventas") state.vender.mode = "ventas";
  } catch { /* private mode or an old value */ }
  $("#sell-group").addEventListener("change", event => { state.vender.group = event.target.value; saveVender(); renderVender(); });
  for (const mode of ["precio", "ventas"]) {
    $(`#sell-mode-${mode}`).addEventListener("click", () => { state.vender.mode = mode; saveVender(); renderVender(); });
  }
  // The heatmap is drawn at its real width, so its text stays readable: it is redrawn when that width changes.
  let heatWidth = 0, heatTimer;
  win.addEventListener("resize", () => {
    clearTimeout(heatTimer);
    heatTimer = setTimeout(() => { if (state.view === "vender" && state.summary && $("#sell-holder").clientWidth !== heatWidth) renderVender(); }, 150);
  });
  /** The player's skills and pace: a number in range, or null (show everything). */
  function pescaInputs() {
    const read = (text, low, high) => {
      const t = String(text ?? "").trim();
      return /^\d{1,3}$/.test(t) && Number(t) >= low && Number(t) <= high ? Number(t) : null;
    };
    const p = state.pesca, mine = fishingRate(state.fishing?.sessions);
    // The pace: what you typed, else your sessions of Forever Fishing, else a usual one.
    const typed = read(p.rate, 10, 999), real = mine && mine.rate >= 10 && mine.rate <= 999 ? mine.rate : null;
    const out = {fishing: read(p.skill, 1, 450), cooking: read(p.cook, 1, 300), alchemy: read(p.alch, 1, 300), rate: typed ?? real ?? CATCHES_PER_HOUR,
      rateFrom: typed !== null ? "typed" : real !== null ? "fishing" : "usual", realRate: real};
    out.bad = [["skill", "Pesca", out.fishing, 450], ["cook", "Cocina", out.cooking, 300], ["alch", "Alquimia", out.alchemy, 300], ["rate", "Capturas por hora", read(p.rate, 10, 999), 999]]
      .filter(([key, , value]) => String(p[key] ?? "").trim() && value === null).map(([, label, , high]) => `${label}: escribe un número hasta ${high}.`);
    return out;
  }
  /** /api/guild/timing once per market and upload (the server keeps it two hours); the view redraws when it arrives. */
  async function loadTiming() {
    const market = state.market, key = `${market}|${state.lastUpload ?? ""}`;
    if (!market || state.timingKey === key) return;
    state.timingKey = key; state.timingError = ""; state.timingLoading = true;
    try {
      const data = await request(`/api/guild/timing?market=${encodeURIComponent(market)}`);
      if (state.market === market) state.timing = {market, data};
    } catch (error) {
      if (error.status === 401) { handle(error); return; }
      if (state.market === market) { state.timing = {market, data: null}; state.timingError = error.status === 404 ? "" : error.message; }
    } finally {
      state.timingLoading = false;
      if (state.view === "pesca") renderPesca();
      if (state.view === "vender") renderVender();
    }
  }
  /** /api/guild/fishing once per upload (Forever Fishing sessions are not tied to a market); the view redraws when it arrives. */
  async function loadFishing() {
    const key = String(state.lastUpload ?? "");
    if (state.fishingKey === key) return;
    state.fishingKey = key; state.fishingLoading = true;
    try {
      state.fishing = await request("/api/guild/fishing");
    } catch (error) {
      if (error.status === 401) { handle(error); return; }
      state.fishing = null;
    } finally {
      state.fishingLoading = false;
      if (state.view === "pesca") renderPesca();
    }
  }
  const verb = best => !best ? "sin precio" : best.kind === "subasta" ? "véndelo" : best.kind === "mercader" ? "al mercader" : best.kind === "cooking" ? "cocínalo" : "destílalo";
  const catchText = (row, n = 4) => row.parts.filter(p => p.pct >= 1).slice(0, n).map(p => `${p.name} ${String(p.pct).replace(".", ",")} % (${verb(p.best)}${isInt(p.value) ? `, ${formatGSC(p.value)}` : ""})`).join(" · ");
  function renderPesca() {
    const s = state.summary;
    if (!s) return;
    loadTiming();
    loadFishing();
    const inputs = pescaInputs();
    $("#fish-feedback").hidden = inputs.bad.length === 0;
    $("#fish-feedback").textContent = inputs.bad.join(" ");
    $("#fish-rate").placeholder = String(inputs.realRate ?? CATCHES_PER_HOUR);
    const byId = new Map(s.items.map(e => [e.id, e]));
    const pricedFish = FISH.filter(f => byId.has(f.id)).length;
    $("#fish-missing").hidden = pricedFish > 0;
    $("#fish-missing").textContent = "Aún no hay precios de pescado en este mercado: con el addon Oro de Hermandad 0.5.0 o posterior se apunta el pescado en cada escaneo de la subasta. Mientras tanto, abajo solo cuenta lo que paga el mercader.";
    const zones = fishZones(s, inputs), pools = fishPools(s, inputs), uses = fishUses(s, inputs);
    $("#fish-season").textContent = zones.season === "invierno"
      ? "Ahora es invierno en el juego: pica el calamar de invierno y no la lubina (de abril a septiembre, al revés). El pargo nocturno sale de noche y el salmón escama de sol de día: las cuentas usan la media del día."
      : "Ahora es verano en el juego: pica la lubina y no el calamar de invierno (de octubre a marzo, al revés). El pargo nocturno sale de noche y el salmón escama de sol de día: las cuentas usan la media del día.";
    const advice = sellData("pesca").advice;
    $("#fish-cards").replaceChildren(...fishCards(zones, pools, uses, advice, {rate: inputs.rate}).map(c => bestCardNode(c, c.key === "sell"
      ? () => { state.vender.group = "pesca"; saveVender(); win.location.hash = "vender"; }
      : () => $(c.target).scrollIntoView())));
    renderMine(s, zones, inputs);
    renderZones(zones, inputs);
    renderPools(pools);
    renderUses(uses);
    $("#pesca-caveat").textContent = "De dónde sale: lo que pica en cada zona y las recetas son de Wowhead Classic (pueden cambiar en Forever); los bancos no tienen datos allí y se cuentan con 4 de cada 5 capturas de su pez. "
      + "Los precios son los que ha visto la hermandad, tras la comisión de la subasta; las especias y los viales, a precio de mercader. " + $("#caveat").textContent;
  }
  /** What «Cuándo vender» knows about one choice ("todo", "cat:metal", a fishing group or "id:123"): the price pattern,
   * the sales and the advice (timingSummary with the sales in .sales, as the cards take it). */
  function sellData(chosen) {
    const timing = state.timing?.market === state.market ? state.timing.data : null;
    const groups = sellGroups(state.summary), group = [groups.market, ...groups.cats, ...groups.fish].find(g => g.key === chosen);
    const ids = chosen.startsWith("id:") ? [Number(chosen.slice(3))] : group?.ids ?? null;
    const pattern = timing ? timingPattern(timing, ids) : null;
    const sales = timing ? timingSales(timing, ids, pattern) : null;
    const summary = pattern ? timingSummary(pattern) : {level: "sin-datos", title: state.timingLoading ? "Cargando los escaneos…" : "Aún no hay escaneos", best: null, worst: null,
      lines: [state.timingError || (state.timingLoading ? "" : SCAN_MORE)].filter(Boolean)};
    return {timing, groups, pattern, sales, advice: {...summary, sales}};
  }
  function renderVender() {
    if (!state.summary) return;
    loadTiming();
    renderSell();
  }
  /** The tab: what to look at, the answers in large, the heatmap by weekday and time with the bars by time and by weekday
   * beside it, and the table twin. */
  function renderSell() {
    const whole = sellData("todo"), {timing, groups} = whole, select = $("#sell-group");
    const withData = (timing?.items ?? []).filter(i => (i.cells ?? []).length || (i.wd ?? []).length).map(i => i.id);
    const byId = new Map((state.summary?.items ?? []).map(e => [e.id, e]));
    const singles = withData.map(id => ({id, name: byId.get(id) ? nameOf(byId.get(id)) : FISH_VENDOR[id]?.name ?? `Objeto ${id}`}))
      .sort((a, b) => a.name.localeCompare(b.name, "es"));
    const option = g => el("option", {value: g.key, text: g.label});
    const signature = JSON.stringify([groups.cats.map(g => g.key), singles.map(x => x.id)]);
    if (select.dataset.signature !== signature || !select.options.length) {
      select.dataset.signature = signature;
      select.replaceChildren(option(groups.market),
        groups.cats.length ? el("optgroup", {label: "Por categoría"}, ...groups.cats.map(option)) : null,
        el("optgroup", {label: "Pesca"}, ...groups.fish.map(option)),
        singles.length ? el("optgroup", {label: "Un objeto"}, ...singles.map(x => el("option", {value: "id:" + x.id, text: x.name}))) : null);
    }
    const wanted = state.vender.group || "todo";
    select.value = [...select.options].some(o => o.value === wanted) ? wanted : "todo";
    const chosen = select.value;
    const {pattern, sales, advice} = chosen === "todo" ? whole : sellData(chosen);
    const fallback = chosen !== "todo" && pattern && pattern.points === 0 && whole.pattern.points > 0;
    $("#sell-feedback").hidden = !fallback;
    $("#sell-feedback").textContent = fallback
      ? "De esto aún no hay escaneos con hora. Mientras tanto, «Todo el mercado» ya tiene escaneos y suele seguir el mismo ritmo." : "";
    // The answers in large; the sentences stay for what the answers do not say: why there is no pattern yet, or no sales.
    const answers = sellAnswers(advice);
    $("#sell-answer").replaceChildren(...answers.map(a => el("li", {class: "best-card" + (a.tone === "good" ? " is-good" : a.tone === "bad" ? " is-bad" : "")},
      el("span", {class: "eyebrow", text: a.label}), el("span", {class: "best-name", text: a.name}), el("span", {class: "best-note", text: a.note}))));
    const measured = !!sales && sales.cells.some(c => c.n > 0);
    const lead = timing ? adviceText(sales.advice) : null, why = timing ? salesLines(sales).filter(line => line !== lead) : [];
    const lines = answers.length ? why : [...advice.lines.filter(line => line !== SCAN_MORE || !measured), ...why];
    const title = answers.length ? null : measured && advice.level === "sin-datos" ? "Aún hay pocas ventas medidas" : advice.title;
    $("#sell-advice").replaceChildren(...(title ? [el("h3", {text: title})] : []), ...lines.map(line => el("p", {text: line})));
    const mode = state.vender.mode === "ventas" ? "ventas" : "precio";
    for (const m of ["precio", "ventas"]) $(`#sell-mode-${m}`).setAttribute("aria-pressed", m === mode ? "true" : "false");
    const show = mode === "ventas" ? measured : !!pattern && pattern.points > 0;
    $("#sell-modes").hidden = !(measured || (pattern && pattern.points > 0));
    $("#sell-legend").hidden = !show || mode !== "precio";
    $("#sell-legend-sales").hidden = !show || mode !== "ventas";
    $("#sell-twin").hidden = !show;
    $("#sell-charts").hidden = !show;
    const holder = $("#sell-holder");
    if (!show) {
      holder.replaceChildren();
      $("#sell-hours").replaceChildren(); $("#sell-days").replaceChildren();
      $("#sell-table").replaceChildren();
      if (mode === "ventas" && pattern?.points > 0) $("#sell-advice").append(el("p", {class: "empty-line", text: sales?.any ? FEW_SALES : NO_SALES_YET}));
      return advice;
    }
    heatWidth = holder.clientWidth;
    const width = Math.max(300, Math.min(720, heatWidth || 440)), cellH = width < 420 ? 34 : 40;
    // The bars beside the map: the same numbers read by time of day and by weekday, the best one in gold.
    const slots = timingSlots(pattern, mode === "ventas" ? sales : null);
    const amount = r => slots.unit === "rate" ? Math.round((r.value - 1) * 1000) : r.value;
    const bars = rows => {
      const maxAbs = Math.max(slots.unit === "rate" ? 200 : 300, ...rows.filter(r => r.usable).map(r => Math.abs(amount(r))));
      return rows.map(r => el("li", {class: r.best ? "is-best" : r.usable ? null : "is-few", title: r.usable ? null : r.n ? "Pocos datos todavía" : "Nadie ha escaneado entonces"},
        el("span", {class: "slot-name", text: r.label}),
        el("span", {"aria-hidden": "true"}, divergingTrack(r.usable ? amount(r) : null, maxAbs, !r.usable ? "rest" : amount(r) < 0 ? "cheap" : slots.unit === "rate" ? "gain" : "dear")),
        el("span", {class: "slot-value", text: r.text})));
    };
    $("#sell-hours").replaceChildren(...bars(slots.hours));
    $("#sell-days-block").hidden = !slots.days;
    $("#sell-days").replaceChildren(...(slots.days ? bars(slots.days) : []));
    if (mode === "ventas") {
      holder.replaceChildren(svg(timingHeatmapSVG(pattern, {width, sales, cellH}).node));
      const cellText = c => c.n === 0 ? "—" : c.usable ? formatRate(c.value) : `pocos (${c.n})`;
      $("#sell-table").replaceChildren(twinTable([["Día"], ...BLOCK_LABELS.map(label => [label, true])],
        [...WEEKDAYS_LONG.map((day, wd) => [day, ...sales.cells.filter(c => c.wd === wd).map(c => num(cellText(c)))]),
          ["Cualquier día", ...sales.blocks.map(b => num(b.rateIdx === null ? b.n ? `pocos (${b.n})` : "—" : formatRate(b.rateIdx)))],
          ["Medido", ...sales.blocks.map(b => num(formatHours(b.sec)))],
          ["Mediciones", ...sales.blocks.map(b => num(String(b.n)))]]));
      return advice;
    }
    holder.replaceChildren(svg(timingHeatmapSVG(pattern, {best: advice.best, width, cellH}).node));
    const cellText = c => c.n === 0 ? "—" : c.usable ? formatPct(c.value) : `pocos (${c.n})`;
    $("#sell-table").replaceChildren(twinTable([["Día"], ...BLOCK_LABELS.map(label => [label, true]), ["Con el precio del día", true]],
      [...WEEKDAYS_LONG.map((day, wd) => [day, ...pattern.cells.filter(c => c.wd === wd).map(c => num(cellText(c))),
        num(pattern.weekdays[wd].usable ? formatPct(pattern.weekdays[wd].value) : pattern.weekdays[wd].n ? `pocos (${pattern.weekdays[wd].n})` : "—")]),
      ["Cualquier día", ...pattern.blocks.map(b => num(b.n === 0 ? "—" : b.usable ? formatPct(b.value) : `pocos (${b.n})`)), num("")]]));
    return advice;
  }
  function renderZones(zones, inputs) {
    const top = zones.rows.slice(0, 10), max = top[0]?.perHour || 1;
    $("#zones-empty").hidden = top.length > 0;
    $("#zones-empty").textContent = zones.unpriced ? "Faltan precios de lo que se pesca: aparecerán cuando alguien escanee la subasta con el addon 0.5.0." : "Con esa habilidad de pesca aún no hay ninguna zona: déjala vacía para verlas todas.";
    $("#zones-twin").hidden = top.length === 0;
    const tag = z => `habilidad ${z.skill}${z.clean > z.skill ? ` · sin que se escapen, ${z.clean}` : ""}${z.escapes ? " · se te escapará alguno" : ""}${z.note ? ` · ${z.note}` : ""}`;
    $("#zones-list").replaceChildren(...top.map(z => {
      const fill = el("span", {class: "rank-fill"});
      fill.style.width = Math.max(1, Math.round(100 * z.perHour / max)) + "%";
      return rankRow({id: null, name: z.name, tag: tag(z), track: el("span", {class: "rank-base"}, fill), value: [money(z.perHour), el("small", {text: "por hora"})],
        detail: `≈ ${formatGSC(z.value)} por captura a ${inputs.rate} capturas por hora${inputs.rateFrom === "fishing" ? " (tu ritmo según Forever Fishing)" : ""}. Pica: ${catchText(z)}.`});
    }));
    $("#zones-table").replaceChildren(twinTable([["Zona"], ["Habilidad", true], ["Sin escapes", true], ["Por captura", true], ["Por hora", true], ["Lo que pica"]],
      zones.rows.map(z => [z.name, num(String(z.skill)), num(String(z.clean)), num(money(z.value)), num(money(z.perHour)), el("td", {class: "twin-wrap", text: catchText(z, 8)})])));
  }
  /** "Tus sesiones de pesca": Forever Fishing sessions valued with today's prices, your pace and what really bites. */
  function renderMine(s, zones, inputs) {
    const worth = fishWorth(s, inputs), raw = fishWorth(s, {cooking: 0, alchemy: 0});
    const fishing = state.fishing, guildView = fishing?.scope === "guild", linkView = fishing?.scope === "viewer";
    const rows = fishingSessionRows(fishing, worth, raw), timed = rows.filter(r => r.perHour !== null);
    $("#mine-title").textContent = guildView ? "Sesiones de pesca de la hermandad" : linkView ? "Lo que pesca la hermandad" : "Tus sesiones de pesca";
    $("#mine-empty").hidden = rows.length > 0;
    $("#mine-empty").textContent = state.fishingLoading && !fishing ? "Cargando las sesiones…"
      : linkView ? "Las sesiones de cada uno solo se ven entrando con su clave. Aquí, lo que de verdad pica en cada zona según lo que ha pescado la hermandad (sin nombres)."
      : "Aún no hay sesiones. Si usas el addon Forever Fishing, el subidor del PC (0.5.0 o posterior) envía tus sesiones al salir del juego o al usar /reload: solo números y lugares, sin nombres de personaje.";
    const seconds = timed.reduce((sum, r) => sum + r.seconds, 0), value = timed.reduce((sum, r) => sum + r.value, 0), plain = timed.reduce((sum, r) => sum + r.raw, 0);
    const pace = fishingRate(fishing?.sessions), best = zones.rows[0];
    const lines = [];
    if (pace) lines.push(`${guildView ? "Ritmo de la hermandad" : "Tu ritmo"}: ${pace.rate} capturas por hora con la caña en la mano (${plural(pace.sessions, "sesión", "sesiones")}, ${formatSpan(pace.seconds)}).${inputs.rateFrom === "fishing" ? " Las cuentas de abajo lo usan; escribe otro en «Capturas por hora» si quieres." : ""}`);
    if (seconds) lines.push(`Vendiéndolo todo tal cual sale, ${formatGSC(Math.round(plain * 3600 / seconds))} por hora.`);
    if (best && seconds) lines.push(`La mejor zona de la lista de abajo, ${best.name}, daría unos ${formatGSC(best.perHour)} por hora a ${inputs.rate} capturas por hora (con lo que pica allí según Wowhead).`);
    $("#mine-advice").replaceChildren(...(rows.length ? [el("h3", {text: seconds ? `${guildView ? "La hermandad ha sacado" : "Has sacado"} ${formatGSC(Math.round(value * 3600 / seconds))} por hora` : "Sesiones demasiado cortas para calcular el oro por hora"}),
      ...lines.map(line => el("p", {text: line}))] : []));
    const where = r => r.zones.slice(0, 2).map(z => `${z.zone} (${groupThousands(z.catches)})`).join(" y ");
    const top = rows.slice(0, 10), max = Math.max(1, ...top.map(r => r.perHour ?? 0));
    $("#mine-list").replaceChildren(...top.map(r => {
      const fill = el("span", {class: "rank-fill"});
      fill.style.width = Math.max(1, Math.round(100 * (r.perHour ?? 0) / max)) + "%";
      const tag = `${formatSpan(r.seconds)} · ${plural(r.catches, "captura", "capturas")}${r.perHourCatches !== null ? ` · ${r.perHourCatches} por hora` : ""}${r.member ? ` · ${r.member}` : ""}`;
      return rankRow({id: null, name: sessionWhen(r.start), tag, track: el("span", {class: "rank-base"}, fill),
        value: r.perHour !== null ? [money(r.perHour), el("small", {text: "por hora"})] : [money(r.value), el("small", {text: "en total"})],
        detail: `${r.zones.length ? `Sobre todo en ${where(r)}. ` : ""}Vale ${formatGSC(r.value)} haciendo lo mejor con cada pez; vendiéndolo tal cual, ${formatGSC(r.raw)}.`
          + (r.unpriced ? ` ${plural(r.unpriced, "captura", "capturas")} sin precio (cofres, cajas o lo que nadie ha escaneado).` : "")});
    }));
    $("#mine-twin").hidden = rows.length === 0;
    $("#mine-table").replaceChildren(twinTable([["Inicio"], ...(guildView ? [["Quién"]] : []), ["Con la caña", true], ["Capturas", true], ["Por hora", true], ["Vale", true], ["Oro por hora", true], ["Tal cual, por hora", true], ["Dónde"]],
      rows.map(r => [sessionWhen(r.start), ...(guildView ? [r.member ?? ""] : []), num(formatSpan(r.seconds)), num(groupThousands(r.catches)), num(r.perHourCatches === null ? "—" : String(r.perHourCatches)),
        num(money(r.value)), num(money(r.perHour)), num(money(r.rawPerHour)), el("td", {class: "twin-wrap", text: r.zones.map(z => `${z.zone} (${groupThousands(z.catches)})`).join(", ")})])));
    const places = fishingPlaces(fishing, worth, inputs.rate).slice(0, 8), maxPlace = Math.max(1, ...places.map(p => p.perHour));
    $("#places-title").hidden = places.length === 0;
    $("#places-list").replaceChildren(...places.map(p => {
      const fill = el("span", {class: "rank-fill"});
      fill.style.width = Math.max(1, Math.round(100 * p.perHour / maxPlace)) + "%";
      const parts = p.parts.filter(x => x.pct >= 1).slice(0, 4).map(x => `${x.name} ${String(x.pct).replace(".", ",")} % (${verb(x.best)}${isInt(x.value) ? `, ${formatGSC(x.value)}` : ""})`).join(" · ");
      return rankRow({id: null, name: p.zone, tag: `${plural(p.catches, "captura", "capturas")}${p.few ? " · pocas, orientativo" : ""}${p.places[0] ? ` · sobre todo en ${p.places[0].place}` : ""}`,
        track: el("span", {class: "rank-base"}, fill), value: [money(p.perHour), el("small", {text: "por hora"})],
        detail: `≈ ${formatGSC(p.value)} por captura a ${inputs.rate} capturas por hora. Ha picado: ${parts || "nada con precio"}.`});
    }));
  }
  function renderPools(pools) {
    const top = pools.rows, max = top[0]?.perPool || 1;
    $("#pools-empty").hidden = top.length > 0;
    $("#pools-empty").textContent = pools.unpriced ? "Faltan precios del pescado de los bancos." : "Con esa habilidad de pesca aún no hay bancos: déjala vacía para verlos todos.";
    $("#pools-twin").hidden = top.length === 0;
    $("#pools-list").replaceChildren(...top.map(p => {
      const fill = el("span", {class: "rank-fill"});
      fill.style.width = Math.max(1, Math.round(100 * p.perPool / max)) + "%";
      const fish = p.parts[0];
      return rankRow({id: null, name: p.name, tag: `habilidad ${p.skill} · sin que se escapen, ${p.clean}${p.escapes ? " · se te escapará alguno" : ""}`, track: el("span", {class: "rank-base"}, fill),
        value: [money(p.perPool), el("small", {text: "por banco"})],
        detail: `${p.where[0].toUpperCase()}${p.where.slice(1)}. ≈ ${formatGSC(p.value)} por captura${fish ? `: ${fish.name} (${verb(fish.best)}${isInt(fish.value) ? `, ${formatGSC(fish.value)}` : ""})` : ""}.`});
    }));
    $("#pools-table").replaceChildren(twinTable([["Banco"], ["Habilidad", true], ["Por captura", true], ["Por banco", true], ["Dónde"]],
      pools.rows.map(p => [p.name, num(String(p.skill)), num(money(p.value)), num(money(p.perPool)), el("td", {class: "twin-wrap", text: p.where})])));
  }
  function renderUses(uses) {
    const top = uses.rows.slice(0, 15), max = top[0]?.best.value || 1;
    $("#uses-empty").hidden = top.length > 0;
    $("#uses-empty").textContent = uses.unpriced ? "Faltan precios del pescado: aparecerán cuando alguien escanee la subasta con el addon 0.5.0." : "Con esa habilidad de pesca aún no hay peces: déjala vacía para verlos todos.";
    $("#uses-twin").hidden = top.length === 0;
    const how = o => `${o.label}${o.others?.length ? ` (con ${o.others.join(", ")})` : ""}`;
    const tag = r => `pesca ${r.skill}${r.when?.season ? ` · solo en ${r.when.season}${r.outOfSeason ? ", ahora no pica" : ""}` : ""}${r.when?.night ? " · de noche" : ""}${r.when?.day ? " · de día" : ""}`;
    const detail = r => {
      const parts = [how(r.best)];
      if (r.best.kind !== "subasta") parts.push(!r.market ? "crudo aún sin precio en la subasta" : isInt(r.gainBp) && r.gainBp > 0
        ? `${formatPct(r.gainBp)} que venderlo crudo en la subasta (${formatGSC(r.market.value)})` : `crudo en la subasta, ${formatGSC(r.market.value)}`);
      if (r.best.kind !== "mercader" && r.vendor) parts.push(`al mercader, ${formatGSC(r.vendor.value)}`);
      if (r.locked.length) parts.push(`con ${r.locked[0].prof === "cooking" ? "cocina" : "alquimia"} ${r.locked[0].chainSkill ?? r.locked[0].skill}: ${r.locked[0].label.toLowerCase()}, ${formatGSC(r.locked[0].value)}`);
      return parts.join(" · ");
    };
    $("#uses-list").replaceChildren(...top.map(r => {
      const fill = el("span", {class: "rank-fill"});
      fill.style.width = Math.max(1, Math.round(100 * r.best.value / max)) + "%";
      return rankRow({id: r.id, name: r.name, tag: tag(r), track: el("span", {class: "rank-base"}, fill),
        value: [money(r.best.value), el("small", {text: `por pez · ${verb(r.best)}`})], detail: detail(r)});
    }));
    $("#uses-table").replaceChildren(twinTable([["Pez"], ["Pesca", true], ["Crudo en la subasta", true], ["Al mercader", true], ["Lo mejor"], ["Vale", true], ["Frente a crudo", true]],
      uses.rows.map(r => [itemButton(r.id, r.name), num(String(r.skill)), num(money(r.market?.value)), num(money(r.vendor?.value)), el("td", {class: "twin-wrap", text: how(r.best)}), num(money(r.best.value)), num(pctNode(r.gainBp))])));
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
    // The chart starts where the prices start (never less than two weeks wide), not sixty days back with half of it empty.
    const to = detail.T, first = detail.days.reduce((d, x) => isInt(x.d) && x.d < d ? x.d : d, to);
    const from = Math.min(Math.max(to - 59, first), to - 13);
    const markers = dumpDays(series, from, to);
    const chartWidth = Math.min(880, Math.max(300, ($("#detail-body").clientWidth || 760) - 32));
    const chart = bandChartSVG({days: detail.days, from, to, N: b.N, dumpLine: a.dumpLine, markers, price: price?.lo ?? null, width: chartWidth, height: chartWidth < 480 ? 220 : 260});
    const stat = (label, value, note) => el("div", {class: "stat"}, el("span", {class: "stat-label", text: label}), el("strong", {}, value), note ? el("span", {class: "muted stat-note", text: note}) : null);
    const children = [
      el("p", {class: "detail-meta muted", text: `${item.catLabel} · ID ${item.id}${item.watch ? " · lista fija de la hermandad" : " · objeto vigilado por algún miembro"}${item.vendor ? ` · se vende al vendedor por ${formatGSC(item.vendor)}` : ""}`}),
      el("div", {class: "detail-status"}, el("span", {class: "badge verdict-" + a.verdict, text: detail.verdictLabel}), el("span", {text: detail.statusText}), el("span", {class: "muted", text: " · " + detail.confText})),
      el("div", {class: "row detail-actions"}, starButton(item.id, item.name),
        el("button", {type: "button", class: "button subtle small", text: "Cuándo venderlo", onclick: () => { state.vender.group = "id:" + item.id; saveVender(); win.location.hash = "vender"; }}),
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
        el("h3", {id: "chart-title", text: `Últimos ${to - from + 1} días`}),
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
  // ---- the secret view link (whoever administers)
  const viewLinkUrl = token => `${win.location.origin}/hermandad?ver=${token}`;
  function renderViewLink() {
    const link = state.me?.viewLink ?? null;
    $("#view-link-card").hidden = !link;
    if (!link) return;
    $("#view-link-open").hidden = !state.me.pinView;
    $("#view-link-off").hidden = link.on;
    $("#view-link-create").hidden = link.on;
    $("#view-link-on").hidden = !link.on;
    $("#view-link-value").value = link.on ? viewLinkUrl(link.token) : "";
  }
  async function changeViewLink(action, done) {
    $("#view-link-feedback").textContent = "";
    try {
      const {viewLink} = await request("/api/guild/view-link", {action});
      state.me.viewLink = viewLink;
      renderViewLink();
      toast(done);
    } catch (error) { if (error.status === 401) handle(error); else $("#view-link-feedback").textContent = error.message; }
  }
  $("#view-link-create").addEventListener("click", () => changeViewLink("on", "Enlace creado. Cópialo y pásalo a quien quieras."));
  $("#view-link-rotate").addEventListener("click", async () => {
    if (!await confirmAction("¿Cambiar el enlace para ver?", "El enlace de ahora dejará de funcionar para todos los que lo tengan. Tendrás que pasar el nuevo.")) return;
    await changeViewLink("rotate", "Enlace cambiado: el anterior ya no vale.");
  });
  $("#view-link-remove").addEventListener("click", async () => {
    if (!await confirmAction("¿Quitar el enlace para ver?", "Nadie podrá ver el panel sin entrar con su clave. Puedes crear otro enlace cuando quieras.")) return;
    await changeViewLink("off", "Enlace quitado: ya solo se entra con clave.");
  });
  $("#view-link-copy").addEventListener("click", async () => {
    const input = $("#view-link-value");
    try { await win.navigator.clipboard.writeText(input.value); toast("Enlace copiado."); }
    catch { input.select(); toast("Selecciona el enlace y cópialo con Ctrl+C.", true); }
  });
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

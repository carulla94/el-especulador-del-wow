/** Auctioneer 12.x SavedVariables importer. Reads bounded data; never runs Lua. */
export const MARKET = "forever.pvp.alliance.eu";
export const SOURCE_VERSION = "Auctioneer12.xOverTime";
export const HISTORY_WARNING = "Histórico por horas: precio mínimo y cantidad máxima pueden proceder de momentos distintos. No representa ofertas actuales ni ventas confirmadas.";
export const LIMITS = Object.freeze({bytes: 16 * 1024 * 1024, depth: 30, nodes: 500000, stringBytes: 1024 * 1024, rows: 500000});

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", {fatal: true});
const identifierPattern = /[A-Za-z_][A-Za-z_0-9]*/y;
const numberPattern = /-?(?:0[xX][0-9a-fA-F]+|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)/y;
const longPattern = /\[(=*)\[/y;
const reserved = new Set(["__proto__", "prototype", "constructor"]);
const keywords = new Set(["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"]);
const tableKeyTypes = new WeakMap();
const owns = (object, key) => Object.hasOwn(object, key);
const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const iso = (milliseconds) => new Date(milliseconds).toISOString().replace(/\.(\d{3})Z$/, ".$1000Z");

export class SavedVariablesError extends Error {
  constructor(message) { super(message); this.name = "SavedVariablesError"; }
}

function safeKey(value) {
  const key = String(value);
  if (reserved.has(key)) throw new SavedVariablesError("Clave reservada no admitida en SavedVariables.");
  return key;
}

function matchAt(pattern, text, position) {
  pattern.lastIndex = position;
  return pattern.exec(text);
}

function exactNumber(token) {
  if (token.length > 64) throw new SavedVariablesError("Número Lua demasiado largo.");
  let result;
  if (/^-?0x/i.test(token)) {
    const negative = token[0] === "-";
    const integer = BigInt(negative ? token.slice(1) : token) * (negative ? -1n : 1n);
    if (integer > BigInt(Number.MAX_SAFE_INTEGER) || integer < -BigInt(Number.MAX_SAFE_INTEGER)) throw new SavedVariablesError("Número Lua fuera de precisión segura.");
    return Number(integer);
  }
  const parts = /^(-?)(\d*?)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(token);
  if (!parts || !(parts[2] || parts[3])) throw new SavedVariablesError("Número Lua no válido.");
  const exponent = Number(parts[4] || 0);
  if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 400) throw new SavedVariablesError("Exponente Lua fuera de rango.");
  const digits = (parts[2] + (parts[3] || "")).replace(/^0+/, "") || "0";
  const sign = parts[1] ? -1n : 1n;
  const scale = exponent - (parts[3] || "").length;
  let integer = BigInt(digits) * sign;
  let mathematicallyInteger = true;
  if (scale >= 0) integer *= 10n ** BigInt(scale);
  else {
    const divisor = 10n ** BigInt(-scale);
    mathematicallyInteger = integer % divisor === 0n;
    if (mathematicallyInteger) integer /= divisor;
  }
  if (mathematicallyInteger) {
    if (integer > BigInt(Number.MAX_SAFE_INTEGER) || integer < -BigInt(Number.MAX_SAFE_INTEGER)) throw new SavedVariablesError("Número Lua fuera de precisión segura.");
    return Number(integer);
  }
  result = Number(token);
  if (!Number.isFinite(result) || Math.abs(result) > Number.MAX_SAFE_INTEGER || Number.isInteger(result)) throw new SavedVariablesError("Número Lua no finito o sin precisión suficiente.");
  return result;
}

class Parser {
  constructor(text, limits = LIMITS) {
    if (typeof text !== "string") throw new SavedVariablesError("El archivo Lua debe ser texto UTF-8.");
    if (text.length > limits.bytes || encoder.encode(text).length > limits.bytes) throw new SavedVariablesError("El archivo supera los 16 MB permitidos.");
    this.text = text.replace(/^\uFEFF/, "");
    this.position = 0;
    this.nodes = 0;
    this.limits = limits;
  }

  fail(message) { throw new SavedVariablesError(`${message} (posición ${this.position}).`); }
  node() { if (++this.nodes > this.limits.nodes) this.fail("Demasiados elementos en el archivo"); }

  skip() {
    while (this.position < this.text.length) {
      if (/\s/.test(this.text[this.position])) this.position++;
      else if (this.text.startsWith("--", this.position)) {
        this.position += 2;
        const opening = matchAt(longPattern, this.text, this.position);
        if (opening) {
          const closer = `]${opening[1]}]`;
          const end = this.text.indexOf(closer, this.position + opening[0].length);
          if (end < 0) this.fail("Comentario Lua sin cerrar");
          this.position = end + closer.length;
        } else {
          const end = this.text.indexOf("\n", this.position);
          this.position = end < 0 ? this.text.length : end + 1;
        }
      } else break;
    }
  }

  accept(value) {
    this.skip();
    if (!this.text.startsWith(value, this.position)) return false;
    this.position += value.length;
    return true;
  }
  expect(value) { if (!this.accept(value)) this.fail(`Se esperaba ${JSON.stringify(value)}`); }
  identifier() {
    this.skip();
    const match = matchAt(identifierPattern, this.text, this.position);
    if (!match) this.fail("Se esperaba un identificador literal");
    this.position += match[0].length;
    return match[0];
  }

  quoted() {
    const quote = this.text[this.position++];
    const chunks = [];
    let size = 0;
    const add = (bytes) => {
      size += bytes.length;
      if (size > this.limits.stringBytes) this.fail("Cadena Lua demasiado larga");
      if (bytes.length) chunks.push(bytes);
    };
    const escapes = {a:7, b:8, f:12, n:10, r:13, t:9, v:11, "\\":92, '"':34, "'":39};
    let start = this.position;
    while (this.position < this.text.length) {
      const char = this.text[this.position++];
      if (char === quote) {
        add(encoder.encode(this.text.slice(start, this.position - 1)));
        const bytes = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        try { return decoder.decode(bytes); }
        catch { this.fail("Cadena Lua con bytes que no son UTF-8"); }
      }
      if (char === "\r" || char === "\n") this.fail("Salto de línea sin escapar dentro de una cadena");
      if (char !== "\\") continue;
      add(encoder.encode(this.text.slice(start, this.position - 1)));
      if (this.position === this.text.length) this.fail("Cadena Lua truncada");
      const escaped = this.text[this.position++];
      if (owns(escapes, escaped)) add(Uint8Array.of(escapes[escaped]));
      else if (/\d/.test(escaped)) {
        let digits = escaped;
        while (digits.length < 3 && this.position < this.text.length && /\d/.test(this.text[this.position])) digits += this.text[this.position++];
        const value = Number(digits);
        if (value > 255) this.fail("Escape decimal Lua fuera de rango");
        add(Uint8Array.of(value));
      } else if (escaped === "\r" || escaped === "\n") {
        if (escaped === "\r" && this.text[this.position] === "\n") this.position++;
        add(Uint8Array.of(10));
      } else this.fail("Escape Lua no admitido");
      start = this.position;
    }
    this.fail("Cadena Lua sin cerrar");
  }

  longString() {
    const opening = matchAt(longPattern, this.text, this.position);
    if (!opening) this.fail("Cadena larga Lua no válida");
    const closer = `]${opening[1]}]`;
    const start = this.position + opening[0].length;
    const end = this.text.indexOf(closer, start);
    if (end < 0) this.fail("Cadena larga Lua sin cerrar");
    let value = this.text.slice(start, end).replace(/^(?:\r\n|\r|\n)/, "");
    if (encoder.encode(value).length > this.limits.stringBytes) this.fail("Cadena Lua demasiado larga");
    this.position = end + closer.length;
    return value;
  }

  value(depth = 0) {
    this.skip(); this.node();
    if (depth > this.limits.depth) this.fail("La estructura Lua es demasiado profunda");
    if (this.position >= this.text.length) this.fail("Falta un valor literal");
    const char = this.text[this.position];
    if (char === "{") return this.table(depth + 1);
    if (char === '"' || char === "'") return this.quoted();
    if (char === "[" && matchAt(longPattern, this.text, this.position)) return this.longString();
    if ("-0123456789.".includes(char)) {
      const match = matchAt(numberPattern, this.text, this.position);
      if (!match) this.fail("Número Lua no válido");
      this.position += match[0].length;
      return exactNumber(match[0]);
    }
    const name = this.identifier();
    if (name === "true") return true;
    if (name === "false") return false;
    if (name === "nil") return null;
    this.fail("Solo se admiten literales; no se ejecuta código Lua");
  }

  table(depth) {
    this.expect("{");
    const result = Object.create(null);
    const types = new Map();
    tableKeyTypes.set(result, types);
    let index = 1;
    while (true) {
      this.skip();
      if (this.accept("}")) return result;
      let key, value;
      if (this.text[this.position] === "[" && !matchAt(longPattern, this.text, this.position)) {
        this.position++;
        key = this.value(depth);
        if ((typeof key !== "string" && typeof key !== "number") || (typeof key === "number" && !Number.isFinite(key))) this.fail("Clave de tabla Lua no admitida");
        this.expect("]"); this.expect("=");
        value = this.value(depth);
      } else {
        const mark = this.position;
        const match = matchAt(identifierPattern, this.text, this.position);
        if (match) {
          const name = this.identifier();
          if (this.accept("=")) {
            if (keywords.has(name)) this.fail("Palabra reservada usada como campo Lua");
            key = name; value = this.value(depth);
          } else { this.position = mark; key = index++; value = this.value(depth); }
        } else { key = index++; value = this.value(depth); }
      }
      const property = safeKey(key);
      if (owns(result, property)) this.fail("Clave duplicada en una tabla Lua");
      result[property] = value;
      types.set(property, typeof key);
      if (this.accept("}")) return result;
      if (!this.accept(",") && !this.accept(";")) this.fail("Falta separador de elementos Lua");
    }
  }

  parse() {
    const result = Object.create(null);
    while (true) {
      this.skip();
      if (this.position === this.text.length) return result;
      const name = this.identifier();
      if (keywords.has(name)) this.fail("No se admite código ejecutable Lua");
      safeKey(name);
      if (owns(result, name)) this.fail("Variable global duplicada");
      this.expect("=");
      result[name] = this.value();
      this.accept(";");
    }
  }
}

export function parseSavedVariables(text, options = {}) {
  return new Parser(text, {...LIMITS, ...options}).parse();
}

function integer(value, label, minimum = 0, maximum = 1e15) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new SavedVariablesError(`${label}: entero fuera de rango.`);
  return value;
}
function validNow(nowMs) {
  if (typeof nowMs !== "number" || !Number.isFinite(nowMs) || !Number.isFinite(new Date(nowMs).getTime())) throw new SavedVariablesError("Fecha de validación no válida.");
}
function validDate(milliseconds, nowMs) {
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).getUTCFullYear() < 2026 || milliseconds > nowMs + 300000) throw new SavedVariablesError("El archivo contiene una fecha anterior a Forever o futura.");
}
function realmName(realm) {
  if (typeof realm !== "string" || !realm || realm.trim() !== realm || realm.length > 160 || /[\u0000-\u001f]/.test(realm)) throw new SavedVariablesError("Nombre de reino Auctioneer no válido.");
  return realm;
}

export function itemIdentity(itemKey) {
  if (typeof itemKey !== "string" || !itemKey || itemKey.length > 100) throw new SavedVariablesError("Clave de objeto Auctioneer no válida.");
  const parts = itemKey.split(":");
  if (parts.length > 4 || parts.some(part => part.length > 18)) throw new SavedVariablesError("Formato de variante Auctioneer desconocido.");
  const [base = "", level = "", suffix = "", species = ""] = parts;
  if ([base, level, species].some(value => value && !/^\d+$/.test(value)) || (suffix && !/^-?\d+$/.test(suffix))) throw new SavedVariablesError("Clave de variante Auctioneer no válida.");
  if ([base, level, species, suffix].some(value => value && !Number.isSafeInteger(Number(value)))) throw new SavedVariablesError("Componente de variante fuera de precisión segura.");
  if (!base) {
    if (parts.length !== 4 || level || suffix || !species || Number(species) <= 0) throw new SavedVariablesError("Clave de mascota Auctioneer no válida.");
    return 82800;
  }
  return integer(Number(base), "ID de objeto Auctioneer", 1, Number.MAX_SAFE_INTEGER);
}

export function normalizeOverTime(text, realm = null, confirmedMarket = false, nowMs = Date.now()) {
  validNow(nowMs);
  const variables = parseSavedVariables(text);
  if (Object.keys(variables).length !== 1 || !record(variables.AuctioneerStatsOverTimeData)) throw new SavedVariablesError("No es un histórico Auctioneer 12.x compatible (AuctioneerStatsOverTimeData).");
  const data = variables.AuctioneerStatsOverTimeData;
  const realms = Object.keys(data).map(realmName).sort();
  if (realms.length > 500) throw new SavedVariablesError("Demasiados reinos en el archivo Auctioneer.");
  if (realm === null || realm === "") return {requiresRealm:true, realms, sourceVersion:SOURCE_VERSION, warning:HISTORY_WARNING};
  if (typeof realm !== "string" || !owns(data, realm)) throw new SavedVariablesError("Selecciona un reino que exista en este archivo.");
  if (confirmedMarket !== true) throw new SavedVariablesError("Confirma que el reino elegido corresponde a Europa · PvP · Alianza.");
  const slices = data[realm];
  if (!record(slices) || Object.keys(slices).length > 10000) throw new SavedVariablesError("Estructura de histórico Auctioneer no válida.");
  const rows = [];
  for (const [hourKey, observations] of Object.entries(slices)) {
    if (tableKeyTypes.get(slices)?.get(hourKey) !== "number") throw new SavedVariablesError("El intervalo horario debe ser una clave numérica.");
    const hour = integer(Number(hourKey), "Intervalo horario", 0, 100000000);
    const observed = hour * 3600000;
    validDate(observed, nowMs);
    if (!record(observations) || Object.keys(observations).sort().join(",") !== "count,price") throw new SavedVariablesError("Cada intervalo debe contener únicamente price y count.");
    const prices = observations.price, counts = observations.count;
    if (!record(prices) || !record(counts)) throw new SavedVariablesError("Precios y cantidades del intervalo no válidos.");
    const keys = Object.keys(prices);
    if (keys.length !== Object.keys(counts).length || keys.some(key => !owns(counts, key))) throw new SavedVariablesError("Precios y cantidades del intervalo no coinciden.");
    for (const key of keys) {
      if (tableKeyTypes.get(prices)?.get(key) !== "string" || tableKeyTypes.get(counts)?.get(key) !== "string") throw new SavedVariablesError("La clave de objeto debe ser una cadena Auctioneer.");
      rows.push({itemKey:key, itemId:itemIdentity(key), observedAt:iso(observed),
        priceCopper:integer(prices[key], "Precio histórico", 1),
        quantityObserved:integer(counts[key], "Cantidad histórica", 0, 1e10)});
      if (rows.length > LIMITS.rows) throw new SavedVariablesError("Demasiadas observaciones históricas.");
    }
  }
  rows.sort((a,b) => a.observedAt.localeCompare(b.observedAt) || a.itemKey.localeCompare(b.itemKey));
  return {requiresRealm:false, realms, realm, rows, sourceVersion:SOURCE_VERSION, warning:HISTORY_WARNING};
}

export function normalizeBridge(text, nowMs = Date.now()) {
  validNow(nowMs);
  const parsed = parseSavedVariables(text);
  if (Object.keys(parsed).length !== 1 || !record(parsed.EspeculadorBridgeDB)) throw new SavedVariablesError("Selecciona EspeculadorBridge.lua generado por nuestro puente.");
  const data = parsed.EspeculadorBridgeDB;
  if (data.schemaVersion !== 1 || data.source !== "Auctioneer12.x") throw new SavedVariablesError("Versión del puente no compatible.");
  if (data.market !== MARKET || data.enabled !== true || data.confirmedMarket !== true) throw new SavedVariablesError("Confirma el mercado en el juego: /especulador confirmar EU PVP ALIANZA.");
  const metadata = data.metadata;
  const expected = {region:"EU", faction:"Alliance", ruleset:"pvp", rulesetVerification:"user-confirmed", interface:16001};
  if (!record(metadata) || Object.entries(expected).some(([key,value]) => metadata[key] !== value)) throw new SavedVariablesError("La captura no acredita el contexto Europa · PvP · Alianza de Forever.");
  const realm = realmName(metadata.realm);
  if (data.lastBatchScope !== "partial" || data.complete !== false) throw new SavedVariablesError("Solo se admiten observaciones parciales declaradas explícitamente.");
  const captured = integer(data.capturedAt, "Hora de captura", 1, 1e10);
  validDate(captured * 1000, nowMs);
  if (!record(data.items) || Object.keys(data.items).length > 20000) throw new SavedVariablesError("Lista del puente no válida o demasiado grande.");
  const items = [];
  for (const [key, row] of Object.entries(data.items)) {
    if (tableKeyTypes.get(data.items)?.get(key) !== "string" || !record(row)) throw new SavedVariablesError("Observación del puente no válida.");
    const id = integer(row.itemId, "ID del puente", 1, Number.MAX_SAFE_INTEGER);
    if (itemIdentity(key) !== id) throw new SavedVariablesError("La variante no corresponde al ID del objeto.");
    const observed = integer(row.observedAt, "Hora de observación", 1, captured);
    validDate(observed * 1000, nowMs);
    const rawName = row.name ?? `Objeto ${id}`;
    if (typeof rawName !== "string") throw new SavedVariablesError("Nombre de objeto del puente no válido.");
    items.push({itemId:id, itemKey:key, name:rawName.trim().slice(0,160),
      buyCopper:integer(row.buyCopper, "Precio de compra", 1), referenceCopper:null,
      quantityAvailable:integer(row.quantityObserved, "Unidades observadas", 0, 1e10), observedAt:iso(observed * 1000)});
  }
  const observedAt = iso(captured * 1000);
  return {
    snapshot:{market:MARKET, realm, source:"Auctioneer · puente parcial", coverage:"partial", observedAt, items},
    realm,
    bridgeMeta:{lastImportedAt:iso(nowMs), observedAt, itemCount:items.length, scope:"partial", status:"experimental", realm},
  };
}

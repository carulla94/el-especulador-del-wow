/** "Mi cartera" (public/cartera.js) and what the home tab adds to the panel: the portfolio valued with guild prices, the
 * movement form, today's movers and the player's list. The page contract for the portfolio file is checked here too. */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {quoteOf, valuation, saleFee, readMovement} from "../public/cartera.js";
import {dayMovers, favoriteRows, parseFavorites, filterItems, parseGSC, setEspecular} from "../public/hermandad.js";
import * as E from "../src/especular.mjs";

setEspecular(E);
const read = name => fs.readFileSync(new URL("../" + name, import.meta.url), "utf8");
const market = (id, lo, extra = {}) => ({id, name: "Objeto " + id, cat: "tela", price: lo === null ? null : {lo, at: 0, member: 1}, spark: [], verdict: "NORMAL", d1: null, ...extra});
const held = (itemId, quantity, totalCostCopper, extra = {}) => ({itemId, itemKey: String(itemId), name: "Objeto " + itemId, quantity, averageCostCopper: Math.round(totalCostCopper / quantity), totalCostCopper, ...extra});

test("an item is quoted at today's lowest price, else at the last price of the last three days", () => {
  assert.deepEqual(quoteOf(market(1, 500)), {price: 500, source: "hoy"});
  assert.deepEqual(quoteOf(market(1, null, {spark: [100, 200, null, null]})), {price: 200, source: "reciente"});
  assert.equal(quoteOf(market(1, null, {spark: [100, null, null, null]})), null, "a price older than three days says nothing about today");
  assert.equal(quoteOf(null), null);
  assert.equal(quoteOf(market(1, null)), null);
});

test("the portfolio is valued after the commission, and items without a price stay out of the totals", () => {
  const summary = {items: [market(10, 1000), market(20, 500, {verdict: "CARO"})]};
  const v = valuation([held(10, 10, 8000), held(20, 2, 1500), held(30, 1, 700)], summary, 5);
  assert.equal(v.cost, 10200, "the cost counts everything");
  assert.equal(v.rows[0].value, 9500, "10 × 1000 less 5 %");
  assert.equal(v.rows[0].gain, 1500);
  assert.equal(v.rows[1].value, 950);
  assert.equal(v.rows[1].gain, -550);
  assert.equal(v.rows[2].value, null, "not in the guild's list");
  assert.equal(v.rows[2].gain, null);
  assert.equal(v.value, 10450);
  assert.equal(v.gain, 950);
  assert.equal(v.unpriced, 1);
  assert.equal(v.priced, 2);
  assert.deepEqual(v.sellNow.map(r => r.itemId), [20], "only what the market calls expensive");
});

test("a variant has its own price, so the base item's price never values it", () => {
  const v = valuation([held(10, 1, 100, {itemKey: "10:1:0:1234"})], {items: [market(10, 99999)]}, 5);
  assert.equal(v.rows[0].value, null);
  assert.equal(v.value, 0);
  assert.equal(v.unpriced, 1);
});

test("an empty portfolio or a market without data values nothing and does not break", () => {
  assert.deepEqual(valuation([], {items: []}, 5).rows, []);
  assert.deepEqual(valuation(undefined, null, 5).rows, []);
  const v = valuation([held(10, 1, 100)], null, 5);
  assert.equal(v.rows[0].value, null);
  assert.equal(v.gain, 0);
});

test("the movement form sends exactly what the owner's API expects", () => {
  assert.deepEqual(readMovement({kind: "buy", name: " Paño de lino ", itemId: "2589", itemKey: "", quantity: "20", unit: "1s 50c", fee: "", deposit: "", note: " x "}, parseGSC),
    {kind: "buy", itemId: 2589, itemKey: "2589", name: "Paño de lino", quantity: 20, unitCopper: 150, feeCopper: 0, depositLossCopper: 0, note: "x"});
  assert.deepEqual(readMovement({kind: "sell", name: "Espada", itemId: "10", itemKey: "10:1:0:5", quantity: "1", unit: "2g", fee: "10s", deposit: "5s", note: ""}, parseGSC),
    {kind: "sell", itemId: 10, itemKey: "10:1:0:5", name: "Espada", quantity: 1, unitCopper: 20000, feeCopper: 1000, depositLossCopper: 500, note: ""});
  assert.deepEqual(readMovement({kind: "expense", name: "", itemId: "", itemKey: "", quantity: "1", unit: "5g", fee: "", deposit: "", note: "Reparar"}, parseGSC),
    {kind: "expense", itemId: 0, itemKey: "0", name: "Gasto", quantity: 1, unitCopper: 50000, feeCopper: 0, depositLossCopper: 0, note: "Reparar"});
});

test("the movement form explains what is wrong instead of sending it", () => {
  const good = {kind: "buy", name: "Lino", itemId: "2589", itemKey: "", quantity: "1", unit: "1s", fee: "", deposit: "", note: ""};
  assert.throws(() => readMovement({...good, kind: "regalo"}, parseGSC), /tipo de movimiento/);
  assert.throws(() => readMovement({...good, itemId: ""}, parseGSC), /objeto de la lista/);
  assert.throws(() => readMovement({...good, itemId: "-3"}, parseGSC), /objeto de la lista/);
  assert.throws(() => readMovement({...good, name: "  "}, parseGSC), /nombre/);
  assert.throws(() => readMovement({...good, quantity: "0"}, parseGSC), /Unidades/);
  assert.throws(() => readMovement({...good, quantity: "1.5"}, parseGSC), /Unidades/);
  assert.throws(() => readMovement({...good, unit: "mucho"}, parseGSC), /Precio/);
  assert.throws(() => readMovement({...good, fee: "mucho"}, parseGSC), /Comisión/);
});

test("a sale's commission is estimated from the owner's percentage", () => {
  assert.equal(saleFee(1000, 10, 5), 500);
  assert.equal(saleFee(333, 1, 5), 17);
  assert.equal(saleFee(1000, 10, 0), 0);
});

test("today's movers: the biggest change first, only with a price today, never out-of-range items", () => {
  const items = [market(1, 100, {d1: -500}), market(2, 100, {d1: -2000}), market(3, 100, {d1: 900}), market(4, 100, {d1: 3000}), market(5, 100, {d1: 0}),
    market(6, null, {d1: -9000}), market(7, 100, {d1: -9000, verdict: "FUERA_DE_RANGO"}), market(8, 100, {d1: null})];
  const {fallers, risers} = dayMovers({items});
  assert.deepEqual(fallers.map(e => e.id), [2, 1]);
  assert.deepEqual(risers.map(e => e.id), [4, 3]);
  assert.equal(dayMovers({items}, 1).fallers.length, 1);
  assert.deepEqual(dayMovers(null), {fallers: [], risers: []});
});

test("the player's list survives anything the browser has stored", () => {
  assert.deepEqual(parseFavorites("[1,2,2,3]"), [1, 2, 3]);
  assert.deepEqual(parseFavorites('[1,"2",-3,4.5,null]'), [1]);
  for (const bad of ["", "no json", "{}", "null", "7", null, undefined]) assert.deepEqual(parseFavorites(bad), [], String(bad));
  assert.equal(parseFavorites(JSON.stringify(Array.from({length: 500}, (_, i) => i + 1))).length, 200);
});

test("the list filters the market table and shows on the home tab, in market order", () => {
  const items = [market(1, 100), market(2, 100), market(3, 100)];
  const favorites = new Set([3, 1, 99]);
  assert.deepEqual(filterItems(items, {show: "favoritos", favorites}).map(e => e.id), [1, 3]);
  assert.deepEqual(filterItems(items, {show: "favoritos"}), [], "no list, nothing to show");
  assert.deepEqual(filterItems(items, {}).map(e => e.id), [1, 2, 3], "without the filter the list changes nothing");
  assert.deepEqual(favoriteRows({items}, favorites).map(e => e.id), [1, 3]);
  assert.deepEqual(favoriteRows(null, favorites), []);
});

test("the portfolio file only uses elements of the page and only talks to the owner's API", () => {
  const source = read("public/cartera.js"), html = read("public/hermandad.html");
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
  const used = [...source.matchAll(/\$\("#([\w-]+)"\)/g)].map(m => m[1]);
  assert.ok(used.length > 10);
  for (const id of used) assert.ok(ids.has(id), "#" + id);
  const paths = [...source.matchAll(/api\("([^"]+)"/g)].map(m => m[1]);
  assert.deepEqual([...new Set(paths)].sort(), ["/api/settings", "/api/state", "/api/transactions"]);
  assert.ok(!source.includes("/api/guild"), "nothing of the portfolio goes to the guild");
  assert.ok(!/^import\b/m.test(source), "it has no dependencies of its own");
  assert.ok(!source.includes("localStorage"), "the portfolio is never kept in the browser");
  assert.ok(!/innerHTML/.test(source));
});

test("the panel has one way in and the portfolio tab starts hidden", () => {
  const html = read("public/hermandad.html"), js = read("public/hermandad.js");
  assert.match(html, /<a href="#cartera" data-tab="cartera" id="tab-cartera" hidden>/);
  assert.ok(!html.includes('href="/login"'), "there is no second login page to choose");
  assert.ok(!html.includes('id="owner-back"'));
  // A guild key must never be sent to the owner's login, nor a password to the guild's.
  assert.match(js, /if \(isKey\) state\.csrf = \(await request\("\/api\/guild\/login", \{key\}\)\)\.csrf;\s*else await ownerLogin\(input\.value\);/);
  assert.match(read("public/login.js"), /location\.replace\("\/hermandad"\)/);
});

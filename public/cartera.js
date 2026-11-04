/** "Mi cartera", the owner's tab of the panel. The Worker serves this file only with the owner's session, so members never
 * download it, and it talks only to the owner's API (/api/state, /api/transactions, /api/settings). Guild data comes from
 * the summary the panel already loaded: it is only read here, and nothing of the portfolio is ever sent to the guild. */
const isInt = Number.isSafeInteger;

/** What an item is worth in the market right now: today's lowest price, else the last price of the last three days. */
export function quoteOf(e) {
  if (isInt(e?.price?.lo)) return {price: e.price.lo, source: "hoy"};
  for (const value of (e?.spark ?? []).slice(-3).reverse()) if (isInt(value)) return {price: value, source: "reciente"};
  return null;
}

/** The portfolio valued with the guild's prices, after the commission. Only exact items are valued: a variant (a gear
 * piece with a suffix, say) has its own price, which the guild's list of materials does not give. */
export function valuation(inventory, summary, feePercent = 5) {
  const byId = new Map((summary?.items ?? []).map(e => [e.id, e]));
  const keep = Math.max(0, 10000 - Math.round(Number(feePercent) * 100));
  let cost = 0, value = 0, gain = 0, unpriced = 0;
  const rows = (inventory ?? []).map(item => {
    const exact = String(item.itemKey ?? item.itemId) === String(item.itemId);
    const e = exact ? byId.get(Number(item.itemId)) ?? null : null;
    const quote = quoteOf(e);
    const worth = quote ? Math.floor(quote.price * item.quantity * keep / 10000) : null;
    const rowValue = isInt(worth) ? worth : null;
    const rowGain = rowValue === null ? null : rowValue - item.totalCostCopper;
    cost += item.totalCostCopper;
    if (rowValue === null) unpriced++;
    else { value += rowValue; gain += rowGain; }
    return {...item, e, quote: rowValue === null ? null : quote, value: rowValue, gain: rowGain, sellNow: e?.verdict === "CARO" && item.quantity > 0};
  });
  return {rows, cost, value, gain, unpriced, priced: rows.length - unpriced, sellNow: rows.filter(r => r.sellNow)};
}

/** The commission of a sale, the way the old form estimated it; the player corrects it to the real amount. */
export function saleFee(unitCopper, quantity, feePercent) {
  const fee = Math.round(unitCopper * quantity * Number(feePercent) / 100);
  return isInt(fee) && fee >= 0 ? fee : 0;
}

/** Form values -> the body of POST /api/transactions. Throws an Error with the sentence to show. */
export function readMovement(values, parseGSC) {
  const kind = values.kind, expense = kind === "expense";
  if (!["buy", "sell", "expense"].includes(kind)) throw new Error("Elige el tipo de movimiento.");
  const itemId = expense ? 0 : Number(String(values.itemId ?? "").trim());
  if (!expense && (!isInt(itemId) || itemId < 1)) throw new Error("Elige un objeto de la lista o escribe su ID.");
  const name = String(values.name ?? "").trim() || (expense ? "Gasto" : "");
  if (!name) throw new Error("Escribe el nombre del objeto.");
  const quantity = Number(String(values.quantity ?? "").trim());
  if (!isInt(quantity) || quantity < 1) throw new Error("Unidades: escribe un número entero, 1 o más.");
  const amount = (text, label, optional) => {
    const raw = String(text ?? "").trim();
    if (!raw && optional) return 0;
    const copper = parseGSC(raw);
    if (copper === null) throw new Error(`${label}: escribe un importe como 1g 50s.`);
    return copper;
  };
  return {kind, itemId, itemKey: expense ? "0" : String(values.itemKey ?? "").trim() || String(itemId), name, quantity,
    unitCopper: amount(values.unit, expense ? "Importe" : "Precio", false),
    feeCopper: amount(values.fee, "Comisión", true), depositLossCopper: amount(values.deposit, "Depósitos perdidos", true),
    note: String(values.note ?? "").trim()};
}

const KIND_LABEL = {buy: "Compra", sell: "Venta", expense: "Gasto"};
const MOVEMENT_TITLE = {buy: "Registrar compra", sell: "Registrar venta", expense: "Añadir gasto"};
const MAX_ROWS = 100;

export function mountCartera({doc, win, $, el, money, toast, handle, formatGSC, parseGSC, formatWhen, plural, itemButton, summary}) {
  let data = null, token = "", feeEdited = false;

  async function api(path, body) {
    const options = {headers: {Accept: "application/json"}, cache: "no-store", credentials: "same-origin"};
    if (body !== undefined) {
      options.method = "POST";
      options.headers["Content-Type"] = "application/json";
      options.headers["X-CSRF-Token"] = token;
      options.body = JSON.stringify(body);
    }
    let response;
    try { response = await win.fetch(path, options); }
    catch { throw Object.assign(new Error("No se puede conectar con tu cuenta. Comprueba tu conexión y vuelve a intentarlo."), {status: 0}); }
    let answer = null;
    try { answer = await response.json(); } catch { /* handled below */ }
    if (!response.ok || !answer || answer.error) throw Object.assign(new Error(answer?.error || `No se ha podido completar la operación (${response.status}).`), {status: response.status});
    return answer;
  }
  async function load() {
    try {
      const state = await api("/api/state");
      data = state; token = state.token || "";
      $("#cartera-feedback").textContent = "";
      fillSettings();
      render();
    } catch (error) {
      if (error.status === 401) return handle(error);
      $("#cartera-feedback").textContent = error.message;
    }
  }
  const feePercent = () => Number(data?.settings?.feePercent ?? 5);
  const worth = () => valuation(data?.inventory, summary(), feePercent());

  function metric(label, value, note, tone = "") {
    return el("li", {class: "metric-card" + tone}, el("span", {class: "stat-label", text: label}), el("strong", {}, value), note ? el("span", {class: "muted stat-note", text: note}) : null);
  }
  const toneOf = copper => copper > 0 ? " is-up" : copper < 0 ? " is-down" : "";
  function percentText(value) {
    return typeof value === "number" && Number.isFinite(value) ? `${new Intl.NumberFormat("es-ES", {maximumFractionDigits: 1}).format(value)} %` : "Sin ventas";
  }

  function render() {
    if (!data) return;
    const v = worth(), totals = data.summary ?? {};
    const pricedNote = !v.rows.length ? "Sin objetos en la cartera" : v.unpriced ? `Sin precio: ${plural(v.unpriced, "objeto", "objetos")}` : "Precio de hoy, tras la comisión";
    $("#cartera-metrics").replaceChildren(
      metric("Oro disponible", money(totals.availableCapitalCopper ?? 0), "Capital inicial más tus movimientos"),
      metric("Inventario a coste", money(v.cost), plural(v.rows.length, "objeto registrado", "objetos registrados")),
      metric("Valor a precio de hoy", v.priced ? money(v.value) : money(null), pricedNote),
      metric("Ganancia latente", v.priced ? money(v.gain) : money(null), "Si vendieras todo a ese precio", v.priced ? toneOf(v.gain) : ""),
      metric("Beneficio realizado", money(totals.realizedProfitCopper ?? 0), "Ventas cobradas menos sus costes", toneOf(totals.realizedProfitCopper ?? 0)),
      metric("ROI realizado", el("span", {text: percentText(data.trading?.realizedRoiPercent)}), "Sobre el coste de lo vendido"));
    renderInventory(v);
    renderMovements();
    renderHoy(v);
  }

  function renderInventory(v) {
    $("#inv-empty").hidden = v.rows.length > 0;
    $("#inv-wrap").hidden = v.rows.length === 0;
    $("#inv-body").replaceChildren(...v.rows.map(row => el("tr", {class: row.sellNow ? "is-caro" : null},
      el("th", {scope: "row", class: "name-cell"}, row.e ? itemButton(row.itemId, row.name || `Objeto ${row.itemId}`) : el("span", {text: row.name || `Objeto ${row.itemId}`})),
      el("td", {class: "num", text: String(row.quantity)}),
      el("td", {class: "num"}, money(row.averageCostCopper)),
      el("td", {class: "num", title: row.quote?.source === "reciente" ? "Hoy nadie lo ha visto: es el último precio de estos días" : null}, money(row.quote?.price ?? null)),
      el("td", {class: "num"}, money(row.value)),
      el("td", {class: "num" + (row.gain > 0 ? " gain" : row.gain < 0 ? " loss" : "")}, money(row.gain)),
      el("td", {}, row.e ? el("span", {class: "badge verdict-" + row.e.verdict, title: row.e.statusText, text: row.sellNow ? "Vende ahora" : row.e.verdictLabel}) : el("span", {class: "none", text: "—"})),
      el("td", {}, el("button", {type: "button", class: "button subtle small", text: "Registrar venta", onclick: () => openMovement("sell", {itemId: row.itemId, itemKey: row.itemKey, name: row.name, unit: row.quote?.price, have: row})})))));
  }

  function renderMovements() {
    const all = [...(data.transactions ?? [])].sort((a, b) => Number(b.id) - Number(a.id));
    $("#tx-empty").hidden = all.length > 0;
    $("#tx-wrap").hidden = all.length === 0;
    $("#tx-more").hidden = all.length <= MAX_ROWS;
    $("#tx-more").textContent = `Se muestran los ${MAX_ROWS} últimos de ${all.length}. Descarga la copia para verlos todos.`;
    $("#tx-body").replaceChildren(...all.slice(0, MAX_ROWS).map(tx => el("tr", {},
      el("td", {text: formatWhen(tx.createdAt, Date.now())}),
      el("td", {}, el("span", {class: "badge " + (tx.kind === "sell" ? "verdict-CHOLLO" : "verdict-NORMAL"), text: KIND_LABEL[tx.kind] ?? tx.kind})),
      el("th", {scope: "row", class: "name-cell"}, el("span", {text: tx.name || `Objeto ${tx.itemId}`}), tx.note ? el("span", {class: "cat-tag", text: tx.note}) : null),
      el("td", {class: "num", text: String(tx.quantity)}),
      el("td", {class: "num"}, money(tx.unitCopper)),
      el("td", {class: "num" + (tx.realizedProfitCopper > 0 ? " gain" : tx.realizedProfitCopper < 0 ? " loss" : "")}, tx.kind === "buy" ? el("span", {class: "none", text: "—"}) : money(tx.realizedProfitCopper)))));
  }

  /** The owner's line on the home tab: what the portfolio is worth today and what to sell now. */
  function renderHoy(v) {
    const box = $("#hoy-cartera");
    box.hidden = !v.rows.length;
    if (!v.rows.length) return;
    $("#hoy-cartera-line").replaceChildren("Vale ", money(v.priced ? v.value : null), " a precio de hoy, tras la comisión · ", el("span", {class: v.gain > 0 ? "gain" : v.gain < 0 ? "loss" : ""}, "ganancia latente ", money(v.priced ? v.gain : null)));
    $("#hoy-sell").hidden = !v.sellNow.length;
    $("#hoy-sell").replaceChildren(...v.sellNow.map(row => el("li", {},
      itemButton(row.itemId, row.name), el("span", {class: "badge verdict-CARO", text: "Vende ahora"}), money(row.quote?.price ?? null),
      el("button", {type: "button", class: "button subtle small", text: "Registrar venta", onclick: () => openMovement("sell", {itemId: row.itemId, itemKey: row.itemKey, name: row.name, unit: row.quote?.price, have: row})}))));
  }

  // ---- the movement form
  function suggestions() {
    const items = summary()?.items ?? [];
    $("#movement-names").replaceChildren(...items.filter(e => e.name).map(e => el("option", {value: e.name})));
    return items;
  }
  function adjustForm() {
    const form = $("#movement-form"), kind = form.elements.kind.value, expense = kind === "expense";
    $("#movement-title").textContent = MOVEMENT_TITLE[kind];
    form.elements.name.required = !expense;
    form.elements.itemId.required = !expense;
    $("#movement-item").hidden = expense;
    $("#movement-unit-label").textContent = expense ? "Importe del gasto" : "Precio por unidad";
    $("#movement-sale").hidden = kind !== "sell";
    updateFee();
  }
  function updateFee() {
    const form = $("#movement-form");
    if (form.elements.kind.value !== "sell" || feeEdited) return;
    const unit = parseGSC(form.elements.unit.value), quantity = Number(form.elements.quantity.value);
    form.elements.fee.value = unit !== null && isInt(quantity) && quantity > 0 ? formatGSC(saleFee(unit, quantity, feePercent())) : "";
  }
  function openMovement(kind = "buy", {itemId = null, itemKey = "", name = "", unit = null, have = null} = {}) {
    const form = $("#movement-form");
    form.reset();
    feeEdited = false;
    suggestions();
    form.elements.kind.value = kind;
    form.elements.name.value = name ?? "";
    form.elements.itemId.value = itemId ? String(itemId) : "";
    form.elements.itemKey.value = itemKey ?? "";
    form.elements.unit.value = isInt(unit) ? formatGSC(unit) : "";
    const held = have ?? (data?.inventory ?? []).find(i => Number(i.itemId) === Number(itemId) && (!itemKey || String(i.itemKey) === String(itemKey)));
    $("#movement-note").textContent = held ? `Tienes ${held.quantity}, con un coste medio de ${formatGSC(held.averageCostCopper)}.` : "";
    $("#movement-feedback").textContent = "";
    adjustForm();
    $("#movement").showModal();
    (name ? form.elements.quantity : form.elements.name).focus();
  }
  const form = $("#movement-form");
  form.elements.kind.addEventListener("change", () => { feeEdited = false; form.elements.fee.value = ""; adjustForm(); });
  form.elements.fee.addEventListener("input", () => { feeEdited = true; });
  form.elements.unit.addEventListener("input", updateFee);
  form.elements.quantity.addEventListener("input", updateFee);
  // Picking a name fills its ID and today's price; typing an ID fills the name.
  form.elements.name.addEventListener("input", () => {
    const wanted = form.elements.name.value.trim().toLocaleLowerCase("es");
    const match = (summary()?.items ?? []).find(e => (e.name || "").toLocaleLowerCase("es") === wanted);
    if (!match) return;
    form.elements.itemId.value = String(match.id);
    form.elements.itemKey.value = "";
    if (!form.elements.unit.value && isInt(quoteOf(match)?.price)) { form.elements.unit.value = formatGSC(quoteOf(match).price); updateFee(); }
  });
  form.elements.itemId.addEventListener("input", () => {
    const match = (summary()?.items ?? []).find(e => String(e.id) === form.elements.itemId.value.trim());
    if (match?.name && !form.elements.name.value.trim()) form.elements.name.value = match.name;
    form.elements.itemKey.value = "";
  });
  $("#movement-cancel").addEventListener("click", () => $("#movement").close());
  form.addEventListener("submit", async event => {
    event.preventDefault();
    const button = form.querySelector("button[type=submit]");
    if (button.disabled) return;
    $("#movement-feedback").textContent = "";
    button.disabled = true;
    try {
      const values = Object.fromEntries(["kind", "name", "itemId", "itemKey", "quantity", "unit", "fee", "deposit", "note"].map(key => [key, form.elements[key].value]));
      await api("/api/transactions", readMovement(values, parseGSC));
      await load();
      $("#movement").close();
      toast("Movimiento guardado en tu cartera.");
    } catch (error) {
      if (error.status === 401) { $("#movement").close(); return handle(error); }
      $("#movement-feedback").textContent = error.message;
    } finally { button.disabled = false; }
  });

  // ---- settings
  function fillSettings() {
    const settings = $("#cartera-settings");
    if (settings.contains(doc.activeElement)) return;
    settings.elements.capital.value = formatGSC(data?.settings?.capitalCopper ?? 0);
    settings.elements.fee.value = String(feePercent());
  }
  $("#cartera-settings").addEventListener("submit", async event => {
    event.preventDefault();
    const settings = event.target, feedback = $("#cartera-settings-feedback");
    feedback.textContent = "";
    feedback.classList.remove("success");
    try {
      const capital = parseGSC(settings.elements.capital.value), fee = Number(String(settings.elements.fee.value).replace(",", "."));
      if (capital === null) throw new Error("Capital inicial: escribe un importe como 500g.");
      if (!Number.isFinite(fee) || fee < 0 || fee > 50) throw new Error("Comisión: escribe un porcentaje entre 0 y 50.");
      await api("/api/settings", {capitalCopper: capital, feePercent: fee});
      if (doc.activeElement && settings.contains(doc.activeElement)) doc.activeElement.blur();
      await load();
      feedback.textContent = "Ajustes guardados.";
      feedback.classList.add("success");
    } catch (error) {
      if (error.status === 401) return handle(error);
      feedback.textContent = error.message;
    }
  });
  for (const [id, kind] of [["#cartera-buy", "buy"], ["#cartera-sell", "sell"], ["#cartera-expense", "expense"]]) $(id).addEventListener("click", () => openMovement(kind));

  /** Logging out leaves nothing of the portfolio in the page: the next person may use this same browser. */
  function unmount() {
    data = null; token = "";
    for (const id of ["#cartera-metrics", "#inv-body", "#tx-body", "#hoy-sell", "#hoy-cartera-line", "#movement-names"]) $(id).replaceChildren();
    $("#cartera-settings").reset();
    $("#cartera-feedback").textContent = ""; $("#cartera-settings-feedback").textContent = "";
    $("#movement-form").reset();
  }
  return {load, render, openMovement, unmount};
}

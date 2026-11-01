"use strict";

(() => {
  const $ = (selector) => document.querySelector(selector);
  const defaults = {capitalCopper: 0, maxItemPercent: 10, minMarginPercent: 20, feePercent: 5, resaleDiscountPercent: 10, maxDataAgeHours: 6, maxUnits: 20};
  let state = {settings: {...defaults}, status: {state: "unavailable", message: "Conectando con tu cuenta."}, items: [], inventory: [], transactions: [], summary: {}};
  let activeView = "opportunities";
  let toastTimer;
  let loading = false;
  let feeDirty = false;
  let opportunityPage = 0;
  let historyPage = 0;
  const PAGE_SIZE = 100;
  const viewCopy = {
    opportunities: ["Oportunidades", "CASA DE SUBASTAS · EUROPA", "Tu libro de subastas.", "Sigue el mercado, decide tus compras y lleva la cuenta de cada moneda."],
    inventory: ["Mi inventario", "TUS EXISTENCIAS", "Tu almacén de objetos.", "Consulta tus existencias y el coste real de cada posición."],
    transactions: ["Movimientos", "EL LIBRO DE CUENTAS", "Cada moneda cuenta.", "Registra compras, ventas cobradas y los costes de tus operaciones."],
    auctioneer: ["Auctioneer", "ARCHIVO DEL MERCADER", "Conecta tus escaneos.", "Conserva tus referencias y distingue el histórico de las observaciones recientes."],
    strategy: ["Estrategia", "DECISIONES CON DATOS", "Antes de comprar, calcula.", "Revisa tu oro disponible, tus resultados y el tiempo que tardas en vender."],
    settings: ["Ajustes", "TUS REGLAS DE COMPRA", "Decide tus límites.", "Configura el capital, los costes y las condiciones de cada operación."]
  };

  function showToast(message, isError = false) {
    const toast = $("#toast");
    toast.textContent = message;
    toast.classList.toggle("error", isError);
    toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.hidden = true; }, isError ? 10000 : 6000);
  }

  function toGold(copper) {
    const number = Number(copper);
    if (!Number.isFinite(number)) return "—";
    return new Intl.NumberFormat("es-ES", {minimumFractionDigits: 0, maximumFractionDigits: 4}).format(number / 10000);
  }

  function goldToCopper(value, label = "Importe") {
    const raw = String(value).trim().replace(",", ".");
    if (!/^\d+(?:\.\d{1,4})?$/.test(raw)) throw new Error(`${label}: escribe un importe positivo con un máximo de 4 decimales, sin separadores de miles.`);
    const [whole, fraction = ""] = raw.split(".");
    const amount = BigInt(whole) * 10000n + BigInt(fraction.padEnd(4, "0"));
    if (amount > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`${label}: el importe es demasiado grande.`);
    return Number(amount);
  }

  function goldInput(copper) {
    if (!Number.isSafeInteger(Number(copper))) return "0";
    return String(Number(copper) / 10000);
  }

  function dateLabel(value) {
    if (!value) return "Sin escaneos";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "Fecha desconocida";
    return new Intl.DateTimeFormat("es-ES", {day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit"}).format(date);
  }

  async function request(path, data) {
    const options = {headers: {Accept: "application/json"}, cache: "no-store"};
    if (data !== undefined) {
      options.method = "POST";
      options.headers["Content-Type"] = "application/json";
      options.headers["X-CSRF-Token"] = state.token || "";
      options.body = JSON.stringify(data);
    }
    let response;
    try { response = await fetch(path, options); }
    catch { throw new Error("No se puede conectar con la app. Comprueba tu conexión y vuelve a intentarlo."); }
    if (response.status === 401) { window.location.assign("/login"); throw new Error("Tu sesión ha caducado. Vuelve a entrar."); }
    let body;
    try { body = await response.json(); }
    catch { throw new Error("La app no ha devuelto una respuesta válida. Actualiza la página y vuelve a intentarlo."); }
    if (!response.ok || body.error) throw new Error(body.error || `No se pudo completar la operación (${response.status}).`);
    return body;
  }

  function switchView(view, updateHash = true) {
    if (!viewCopy[view]) view = "opportunities";
    activeView = view;
    if (view !== "auctioneer") hideDeviceToken();
    document.querySelectorAll(".view-panel").forEach((panel) => { panel.hidden = panel.id !== `view-${view}`; });
    document.querySelectorAll(".nav-button").forEach((button) => {
      const active = button.dataset.view === view;
      button.classList.toggle("active", active);
      if (active) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
    });
    const [breadcrumb, eyebrow, title, description] = viewCopy[view];
    $("#breadcrumb-view").textContent = breadcrumb;
    $("#page-eyebrow").textContent = eyebrow;
    $("#page-title").textContent = title;
    $("#page-description").textContent = description;
    if (updateHash) history.replaceState(null, "", `#${view}`);
  }

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined && text !== null) node.textContent = text;
    if (className) node.className = className;
    return node;
  }

  function cell(text, className) { return element("td", text, className); }
  function moneyCell(copper, className = "gold-amount") { return cell(`${toGold(copper)} g`, className); }

  function metric(selector, copper) {
    const node = $(selector);
    node.replaceChildren(document.createTextNode(`${toGold(copper ?? 0)} `), element("span", "g"));
    node.classList.toggle("negative", Number(copper) < 0);
  }

  function renderStatus() {
    const status = state.status || {};
    const mode = status.state || "unavailable";
    const titles = {ready: "Escaneo disponible para evaluar", empty: "Esperando los primeros datos de tu mercado", stale: "El último escaneo ha perdido actualidad", unavailable: "La fuente de precios no está disponible"};
    $("#status-banner").className = `status-banner ${mode}`;
    $("#status-title").textContent = titles[mode] || "Estado del mercado";
    $("#status-message").textContent = status.message || "Actualiza el mercado o importa un escaneo compatible para empezar.";
    if (status.coverage === "partial") $("#status-message").textContent += " Captura parcial; no representa todo el mercado.";
    $("#last-observed").textContent = status.observedAt ? `Escaneo: ${dateLabel(status.observedAt)}` : "Sin precios verificados";
  }

  function renderOpportunities() {
    const search = $("#item-search").value.trim().toLocaleLowerCase("es");
    const onlyEligible = $("#eligible-only").checked;
    const ready = state.status?.state === "ready";
    const allItems = Array.isArray(state.items) ? state.items : [];
    const opportunities = allItems.filter((item) => item.eligible && ready);
    $("#nav-count").textContent = String(opportunities.length);
    $("#opportunities-count").textContent = String(opportunities.length);
    const items = allItems.filter((item) => (!search || `${item.name} ${item.itemId}`.toLocaleLowerCase("es").includes(search)) && (!onlyEligible || (ready && item.eligible)));
    $("#opportunities-empty").hidden = items.length > 0;
    $("#opportunities-table-wrap").hidden = items.length === 0;
    const emptyHeading = $("#opportunities-empty h3");
    if (allItems.length && !items.length) {
      emptyHeading.textContent = "No hay objetos con esos filtros.";
      $("#opportunities-empty-text").textContent = "Prueba otro nombre o desactiva «Solo con margen» para ver todas las observaciones.";
    } else {
      emptyHeading.textContent = "Aún no hay oportunidades que evaluar.";
      $("#opportunities-empty-text").textContent = "Actualiza el mercado o importa un escaneo de Europa PvP Alianza. Aquí aparecerán los precios y el margen estimado.";
    }
    const fragment = document.createDocumentFragment();
    opportunityPage = Math.min(opportunityPage, Math.max(0, Math.ceil(items.length / PAGE_SIZE) - 1));
    renderPagination("opportunities", opportunityPage, items.length);
    for (const item of items.slice(opportunityPage * PAGE_SIZE, (opportunityPage + 1) * PAGE_SIZE)) {
      const row = element("tr");
      const name = cell(null, "item-cell");
      name.append(element("strong", item.name || `Objeto ${item.itemId}`), element("small", `ID ${item.itemId} · ${dateLabel(item.observedAt || state.status?.observedAt)}`));
      if (item.itemKey && String(item.itemKey) !== String(item.itemId)) name.append(element("small", "Variante " + item.itemKey));
      const margin = cell(null);
      margin.append(element("span", Number.isFinite(Number(item.roiPercent)) ? `${new Intl.NumberFormat("es-ES", {maximumFractionDigits: 1}).format(item.roiPercent)} %` : "—", Number(item.netUnitCopper) > 0 ? "positive" : "negative"), element("small", `${toGold(item.netUnitCopper)} g / ud.`, "cell-detail"));
      const recommended = ready && item.eligible ? Number(item.recommendedUnits || 0) : 0;
      const units = cell(String(recommended));
      units.append(element("small", `${item.quantityAvailable ?? "?"} observadas`, "cell-detail"));
      const assessment = cell(null);
      const available = ready && item.eligible;
      const tag = element("span", available ? "Dentro de tus límites" : ready ? "Sin compra propuesta" : "Observación histórica", `tag ${available ? "good" : "neutral"}`);
      const note = ready ? item.reason || "Revisa el precio dentro del juego antes de comprar." : "Actualiza el escaneo antes de decidir una compra.";
      assessment.append(tag, element("small", note, "cell-detail"));
      if (available) assessment.append(element("small", `Confianza: ${item.confidence || "Baja"}`, "cell-detail"));
      if (available && recommended > 0) assessment.append(element("small", `Margen total estimado: ${toGold(item.estimatedProfitCopper)} g`, "cell-detail"));
      const purchase = moneyCell(item.buyCopper);
      if (Number.isSafeInteger(item.maximumBuyCopper)) purchase.append(element("small", "Compra máxima: " + toGold(item.maximumBuyCopper) + " g", "cell-detail"));
      const resale = item.referenceCopper ? moneyCell(item.targetCopper) : cell("Sin referencia");
      if (item.referenceCopper && Number.isSafeInteger(item.breakEvenCopper)) resale.append(element("small", "Equilibrio: " + toGold(item.breakEvenCopper) + " g", "cell-detail"));
      row.append(name, purchase, resale, item.referenceCopper ? margin : cell("-"), units, assessment);
      fragment.append(row);
    }
    $("#opportunities-body").replaceChildren(fragment);
  }

  function renderInventory() {
    const inventory = Array.isArray(state.inventory) ? state.inventory : [];
    $("#inventory-empty").hidden = inventory.length > 0;
    $("#inventory-table-wrap").hidden = inventory.length === 0;
    const fragment = document.createDocumentFragment();
    for (const item of inventory) {
      const row = element("tr");
      const name = cell(null, "item-cell");
      name.append(element("strong", item.name || `Objeto ${item.itemId}`), element("small", `ID ${item.itemId}`));
      if (item.itemKey && String(item.itemKey) !== String(item.itemId)) name.append(element("small", "Variante " + item.itemKey));
      const action = cell(null);
      const sell = element("button", "Registrar venta", "table-action");
      sell.type = "button";
      sell.addEventListener("click", () => openTransaction("sell", item));
      action.append(sell);
      row.append(name, cell(item.quantity), moneyCell(item.averageCostCopper), moneyCell(item.totalCostCopper), action);
      fragment.append(row);
    }
    $("#inventory-body").replaceChildren(fragment);
    $("#metric-stock-note").textContent = inventory.length ? `${inventory.length} ${inventory.length === 1 ? "objeto registrado" : "objetos registrados"} · valor de compra` : "Sin oro invertido en objetos";
  }

  function renderTransactions() {
    const transactions = Array.isArray(state.transactions) ? state.transactions : [];
    $("#transactions-empty").hidden = transactions.length > 0;
    $("#transactions-table-wrap").hidden = transactions.length === 0;
    const fragment = document.createDocumentFragment();
    const labels = {buy: "Compra", sell: "Venta cobrada", expense: "Gasto"};
    for (const tx of [...transactions].sort((a, b) => Number(b.id) - Number(a.id))) {
      const row = element("tr");
      const kind = cell(null);
      kind.append(element("span", labels[tx.kind] || tx.kind, `tag ${tx.kind === "sell" ? "good" : "neutral"}`));
      const name = cell(null, "item-cell");
      name.append(element("strong", tx.name || `Objeto ${tx.itemId}`));
      if (tx.note) name.append(element("small", tx.note));
      const profit = tx.kind === "buy" ? cell("—") : moneyCell(tx.realizedProfitCopper, Number(tx.realizedProfitCopper) < 0 ? "negative" : "positive");
      row.append(cell(dateLabel(tx.createdAt)), kind, name, cell(tx.quantity), moneyCell(tx.unitCopper), profit);
      fragment.append(row);
    }
    $("#transactions-body").replaceChildren(fragment);
  }

  function renderSettings() {
    const form = $("#settings-form");
    const settings = {...defaults, ...state.settings};
    form.elements.capitalGold.value = goldInput(settings.capitalCopper);
    for (const name of ["maxItemPercent", "minMarginPercent", "feePercent", "resaleDiscountPercent", "maxDataAgeHours", "maxUnits"]) form.elements[name].value = String(settings[name]);
  }

  function render() {
    renderStatus();
    metric("#metric-capital", state.summary?.availableCapitalCopper);
    metric("#metric-stock", state.summary?.inventoryCostCopper);
    metric("#metric-profit", state.summary?.realizedProfitCopper);
    renderOpportunities();
    renderInventory();
    renderTransactions();
    renderSettings();
    renderAuctioneer();
    renderStrategy();
  }

  async function refresh() {
    const body = await request("/api/state");
    state = {...state, ...body};
    render();
  }

  function openTransaction(kind = "buy", item) {
    const form = $("#transaction-form");
    form.reset();
    feeDirty = false;
    form.elements.kind.value = kind;
    $("#transaction-feedback").textContent = "";
    if (item) {
      form.elements.itemId.value = String(item.itemId);
      form.elements.itemKey.value = item.itemKey || String(item.itemId);
      form.elements.name.value = item.name || "";
      form.elements.quantity.value = "1";
    }
    adjustTransactionForm();
    $("#transaction-dialog").showModal();
  }

  function adjustTransactionForm() {
    const form = $("#transaction-form");
    const expense = form.elements.kind.value === "expense";
    form.elements.itemId.required = !expense;
    form.elements.name.required = !expense;
    $("#unit-price-label > span").textContent = expense ? "Importe del gasto por unidad (g)" : "Precio por unidad (g)";
    form.elements.feeGold.parentElement.querySelector("small").textContent = "Al vender se estima según tus ajustes; corrige al importe real.";
    updateSaleFee();
  }

  function updateSaleFee() {
    const form = $("#transaction-form");
    if (form.elements.kind.value !== "sell" || feeDirty) return;
    try {
      const total = goldToCopper(form.elements.unitGold.value) * Number(form.elements.quantity.value);
      if (Number.isSafeInteger(total)) form.elements.feeGold.value = goldInput(Math.round(total * Number(state.settings.feePercent) / 100));
    } catch { /* Do not overwrite a fee while the user is entering a price. */ }
  }

  async function readJson(file) {
    if (!file) return null;
    if (file.size > 10 * 1024 * 1024) throw new Error("El archivo supera los 10 MB. Importa un archivo JSON más pequeño.");
    try { return JSON.parse(await file.text()); }
    catch { throw new Error("El archivo no contiene un JSON válido."); }
  }

  document.querySelectorAll("[data-view]").forEach((button) => button.addEventListener("click", () => switchView(button.dataset.view)));
  $(".brand").addEventListener("click", (event) => { event.preventDefault(); switchView("opportunities"); });
  $("#empty-settings-button").addEventListener("click", () => { switchView("settings"); $("#settings-form input").focus(); });
  $("#item-search").addEventListener("input", () => { opportunityPage = 0; renderOpportunities(); });
  $("#eligible-only").addEventListener("change", () => { opportunityPage = 0; renderOpportunities(); });
  $("#opportunities-prev").addEventListener("click", () => { opportunityPage = Math.max(0, opportunityPage - 1); renderOpportunities(); });
  $("#opportunities-next").addEventListener("click", () => { opportunityPage += 1; renderOpportunities(); });
  document.querySelectorAll("[data-add-transaction]").forEach((button) => button.addEventListener("click", () => openTransaction(button.dataset.addTransaction)));
  $("#close-dialog").addEventListener("click", () => $("#transaction-dialog").close());
  $("#cancel-dialog").addEventListener("click", () => $("#transaction-dialog").close());
  $("#transaction-form").elements.kind.addEventListener("change", () => {
    feeDirty = false;
    $("#transaction-form").elements.feeGold.value = "0";
    adjustTransactionForm();
  });
  $("#transaction-form").elements.feeGold.addEventListener("input", () => { feeDirty = true; });
  $("#transaction-form").elements.unitGold.addEventListener("input", updateSaleFee);
  $("#transaction-form").elements.quantity.addEventListener("input", updateSaleFee);

  $("#sync-button").addEventListener("click", async () => {
    if (loading) return;
    loading = true;
    const button = $("#sync-button");
    button.disabled = true;
    button.textContent = "Consultando mercado…";
    try {
      const devices = state.auctioneer?.devices || [];
      if (devices.some(device => !device.revoked) || state.auctioneer?.connection?.configured) {
        await refresh();
        showToast("Estado actualizado. Los nuevos escaneos llegan cuando el PC sincroniza y WoW guarda el archivo.");
      } else {
        const result = await request("/api/sync", {});
        await refresh();
        showToast(result.message || "Consulta terminada. Revisa la fecha del último escaneo.", result.connected === false);
      }
    } catch (error) { showToast(error.message, true); }
    finally { button.disabled = false; button.replaceChildren(element("span", "↻"), document.createTextNode(" Actualizar mercado")); loading = false; }
  });

  $("#logout-button").addEventListener("click", async () => {
    const button = $("#logout-button");
    button.disabled = true;
    try { await request("/api/logout", {}); window.location.assign("/login"); }
    catch (error) { showToast(error.message, true); button.disabled = false; }
  });

  $("#settings-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const button = form.querySelector("button[type=submit]");
    if (button.disabled) return;
    const feedback = $("#settings-feedback");
    feedback.textContent = "";
    feedback.classList.remove("success");
    button.disabled = true;
    try {
      const settings = {capitalCopper: goldToCopper(form.elements.capitalGold.value, "Capital inicial")};
      for (const name of ["maxItemPercent", "minMarginPercent", "feePercent", "resaleDiscountPercent", "maxDataAgeHours", "maxUnits"]) settings[name] = Number(form.elements[name].value);
      await request("/api/settings", settings);
      await refresh();
      feedback.textContent = "Ajustes guardados. Las cantidades propuestas ya usan tus límites.";
      feedback.classList.add("success");
    } catch (error) { feedback.textContent = error.message; }
    finally { button.disabled = false; }
  });

  $("#transaction-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const button = form.querySelector("button[type=submit]");
    if (button.disabled) return;
    const feedback = $("#transaction-feedback");
    feedback.textContent = "";
    button.disabled = true;
    try {
      const payload = {
        kind: form.elements.kind.value,
        itemId: form.elements.kind.value === "expense" ? 0 : Number(form.elements.itemId.value),
        itemKey: form.elements.kind.value === "expense" ? "0" : form.elements.itemKey.value.trim() || String(form.elements.itemId.value),
        name: form.elements.name.value.trim() || (form.elements.kind.value === "expense" ? "Gasto" : ""),
        quantity: Number(form.elements.quantity.value),
        unitCopper: goldToCopper(form.elements.unitGold.value, "Precio"),
        feeCopper: goldToCopper(form.elements.feeGold.value, "Comisión"),
        depositLossCopper: goldToCopper(form.elements.depositGold.value, "Depósitos perdidos"),
        note: form.elements.note.value.trim()
      };
      await request("/api/transactions", payload);
      await refresh();
      $("#transaction-dialog").close();
      showToast("Movimiento guardado en tu cuenta.");
    } catch (error) { feedback.textContent = error.message; }
    finally { button.disabled = false; }
  });

  function beginImport() { $("#import-file").click(); }
  $("#import-button").addEventListener("click", beginImport);
  $("#settings-import-button").addEventListener("click", beginImport);
  $("#import-file").addEventListener("change", async (event) => {
    try {
      const file = event.target.files[0];
      if (!file) return;
      if (file.size > 10 * 1024 * 1024) throw new Error("El archivo supera los 10 MB.");
      const text = (await file.text()).trim();
      let data;
      if (text.startsWith("AHL1|")) data = {ahlTable: text};
      else {
        try { data = JSON.parse(text); }
        catch { throw new Error("El archivo no contiene un JSON ni una tabla AHL1 válidos."); }
      }
      await request("/api/import", data);
      await refresh();
      showToast("Escaneo importado. Comprueba su fecha antes de decidir una compra.");
    } catch (error) { showToast(error.message, true); }
    finally { event.target.value = ""; }
  });
  $("#restore-button").addEventListener("click", () => $("#restore-file").click());
  $("#restore-file").addEventListener("change", async (event) => {
    try {
      const data = await readJson(event.target.files[0]);
      if (!data) return;
      if (!window.confirm("Restaurar esta copia reemplazará tus ajustes, movimientos y escaneo actuales. Descarga primero una copia si quieres conservarlos. ¿Restaurar los datos del archivo?")) return;
      const result = await request("/api/restore", data);
      await refresh();
      showToast(result.connectionPaused ? "Copia restaurada. Revisa tus dispositivos y la fecha de los escaneos." : "Copia restaurada correctamente.");
    } catch (error) { showToast(error.message, true); }
    finally { event.target.value = ""; }
  });
  let pendingAuctioneerText = "";
  let auctioneerBusy = false;

  function renderPagination(prefix, page, count) {
    const format = value => new Intl.NumberFormat("es-ES").format(value);
    const start = page * PAGE_SIZE;
    $("#" + prefix + "-pagination").hidden = count === 0;
    $("#" + prefix + "-page-label").textContent = count ? format(start + 1) + "–" + format(Math.min(start + PAGE_SIZE, count)) + " de " + format(count) : "Sin resultados";
    $("#" + prefix + "-prev").disabled = page === 0;
    $("#" + prefix + "-next").disabled = start + PAGE_SIZE >= count;
  }

  function hideDeviceToken() {
    const panel = $("#device-token-panel");
    if (!panel) return;
    $("#device-token").value = "";
    panel.hidden = true;
  }

  function renderDevices(devices) {
    $("#devices-empty").hidden = devices.length > 0;
    const fragment = document.createDocumentFragment();
    for (const device of devices) {
      const row = element("article", null, "device-row");
      const content = element("div");
      content.append(element("strong", device.label || "Equipo sin nombre"), element("small", device.revoked ? "Clave revocada" : device.lastSeenAt ? "Último contacto: " + dateLabel(device.lastSeenAt) : "Pendiente del primer envío"));
      row.append(content);
      if (!device.revoked) {
        const revoke = element("button", "Revocar", "button subtle small");
        revoke.type = "button";
        revoke.addEventListener("click", () => auctioneerAction(revoke, async () => {
          if (!window.confirm("¿Revocar la clave de " + (device.label || "este equipo") + "? Sus escaneos guardados se conservarán.")) return;
          await request("/api/devices/revoke", {id: device.id});
          hideDeviceToken();
          await refresh();
          showToast("Clave revocada. El equipo ya no puede enviar escaneos.");
        }));
        row.append(revoke);
      } else row.append(element("span", "Revocado", "tag neutral"));
      fragment.append(row);
    }
    $("#device-list").replaceChildren(fragment);
  }

  function renderAuctioneer() {
    const source = state.auctioneer || {};
    const connection = source.connection || {};
    const history = source.history || {};
    const devices = Array.isArray(source.devices) ? source.devices : [];
    const activeDevices = devices.filter(device => !device.revoked);
    const latestDevice = activeDevices.filter(device => device.lastSeenAt).sort((a, b) => new Date(b.lastSeenAt) - new Date(a.lastSeenAt))[0];
    $("#auctioneer-sync-button").disabled = auctioneerBusy;
    $("#auctioneer-connection-label").textContent = connection.lastError ? "El último envío no se ha podido incorporar" : latestDevice ? "Escaneos recibidos de tu PC" : activeDevices.length ? "Equipo autorizado; esperando su primer envío" : connection.lastImportedAt ? "Datos importados en tu cuenta" : "Sin sincronizador conectado";
    $("#auctioneer-connection-dot").classList.toggle("muted-dot", !latestDevice || Boolean(connection.lastError));
    let detail = connection.lastError || "Los datos llegan cuando el sincronizador del PC está abierto y WoW guarda el archivo.";
    if (latestDevice) detail = "Último contacto: " + dateLabel(latestDevice.lastSeenAt) + " · " + (latestDevice.label || "Tu PC");
    else if (connection.lastImportedAt) detail = "Última incorporación: " + dateLabel(connection.lastImportedAt);
    if (connection.realm) detail += " · " + connection.realm;
    $("#auctioneer-connection-detail").textContent = detail;
    renderDevices(devices);
    const bridge = source.bridge || {};
    $("#auctioneer-bridge-status").textContent = bridge.lastImportedAt ? "Última captura: " + dateLabel(bridge.lastImportedAt) + " · " + (bridge.itemCount || 0) + " objetos · " + (bridge.scope === "full" ? "alcance completo declarado" : "alcance parcial") + "." : "Sin captura del puente importada.";
    const rows = Array.isArray(history.items) ? history.items : [];
    const search = $("#auctioneer-history-search").value.trim().toLocaleLowerCase("es");
    const filtered = rows.filter(item => !search || [item.name, item.itemKey, item.itemId].join(" ").toLocaleLowerCase("es").includes(search));
    $("#auctioneer-history-count").textContent = String(history.count ?? rows.length);
    $("#auctioneer-history-empty").hidden = filtered.length > 0;
    $("#auctioneer-history-wrap").hidden = filtered.length === 0;
    $("#auctioneer-history-empty h3").textContent = rows.length && !filtered.length ? "No hay registros con ese filtro." : "Tu histórico empieza con el primer archivo.";
    const fragment = document.createDocumentFragment();
    historyPage = Math.min(historyPage, Math.max(0, Math.ceil(filtered.length / PAGE_SIZE) - 1));
    renderPagination("auctioneer-history", historyPage, filtered.length);
    for (const item of filtered.slice(historyPage * PAGE_SIZE, (historyPage + 1) * PAGE_SIZE)) {
      const row = element("tr");
      const name = cell(null, "item-cell");
      name.append(element("strong", item.name || "Objeto " + (item.itemId || item.itemKey)), element("small", "Variante " + (item.itemKey || item.itemId)));
      if (item.realm || history.activeRealm) name.append(element("small", "Reino: " + (item.realm || history.activeRealm)));
      const observations = cell(null);
      observations.append(element("span", (item.samples ?? 0) + " observaciones"), element("small", (item.days ?? 0) + " días distintos", "cell-detail"));
      row.append(name, item.referenceCopper == null ? cell("Sin referencia") : moneyCell(item.referenceCopper),
        item.minCopper == null ? cell("—") : moneyCell(item.minCopper), item.maxCopper == null ? cell("—") : moneyCell(item.maxCopper),
        observations, cell(dateLabel(item.lastObservedAt)));
      fragment.append(row);
    }
    $("#auctioneer-history-body").replaceChildren(fragment);
  }

  function renderStrategy() {
    const trading = state.trading || {};
    const percent = value => typeof value === "number" && Number.isFinite(value) ? new Intl.NumberFormat("es-ES", {maximumFractionDigits: 1}).format(value) + " %" : null;
    const duration = value => {
      if (typeof value !== "number" || !Number.isFinite(value)) return null;
      return new Intl.NumberFormat("es-ES", {maximumFractionDigits: 1}).format(value >= 48 ? value / 24 : value) + (value >= 48 ? " días" : " h");
    };
    $("#strategy-cash").textContent = percent(trading.cashSharePercent) || "Sin capital";
    $("#strategy-roi").textContent = percent(trading.realizedRoiPercent) || "Sin ventas";
    $("#strategy-hold").textContent = duration(trading.averageHoldHours) || "Sin ventas";
    $("#strategy-oldest").textContent = duration(trading.oldestInventoryHours) || "Sin inventario";
    const calculator = $("#strategy-calculator");
    if (!calculator.dataset.edited) {
      calculator.elements.feePercent.value = String(state.settings?.feePercent ?? 5);
      calculator.elements.minRoiPercent.value = String(state.settings?.minMarginPercent ?? 20);
    }
  }

  async function readLua(file) {
    if (!file) return null;
    if (file.size > 8 * 1024 * 1024) throw new Error("El archivo supera los 8 MB permitidos por importación.");
    const text = await file.text();
    if (!text.trim()) throw new Error("El archivo está vacío.");
    return text;
  }

  async function auctioneerAction(button, action) {
    if (auctioneerBusy) return;
    auctioneerBusy = true;
    if (button) button.disabled = true;
    try { await action(); }
    catch (error) { showToast(error.message, true); }
    finally {
      auctioneerBusy = false;
      if (button) button.disabled = false;
      renderAuctioneer();
    }
  }

  $("#hero-auctioneer-button").addEventListener("click", () => switchView("auctioneer"));
  document.querySelectorAll("[data-open-auctioneer]").forEach(button => button.addEventListener("click", () => switchView("auctioneer")));
  document.querySelectorAll("[data-open-opportunities]").forEach(button => button.addEventListener("click", () => switchView("opportunities")));
  $("#auctioneer-history-search").addEventListener("input", () => { historyPage = 0; renderAuctioneer(); });
  $("#auctioneer-history-prev").addEventListener("click", () => { historyPage = Math.max(0, historyPage - 1); renderAuctioneer(); });
  $("#auctioneer-history-next").addEventListener("click", () => { historyPage += 1; renderAuctioneer(); });
  $("#auctioneer-sync-button").addEventListener("click", event => auctioneerAction(event.currentTarget, async () => {
    await refresh();
    showToast("Estado actualizado. Los nuevos escaneos llegan desde tu PC cuando WoW guarda los archivos.");
  }));
  $("#device-form").addEventListener("submit", event => {
    event.preventDefault();
    const form = event.currentTarget;
    auctioneerAction(form.querySelector("button"), async () => {
      const label = form.elements.deviceLabel.value.trim();
      if (!label) throw new Error("Escribe un nombre para este equipo.");
      const result = await request("/api/devices", {label});
      if (typeof result.token !== "string" || !result.token) throw new Error("La app no ha devuelto una clave válida.");
      $("#device-token").value = result.token;
      $("#device-token-panel").hidden = false;
      await refresh();
      $("#device-token").focus();
      $("#device-token").select();
      showToast("Equipo autorizado. Guarda la clave: se muestra una sola vez.");
    });
  });
  $("#copy-device-token").addEventListener("click", async () => {
    const field = $("#device-token");
    if (!field.value) return;
    try { await navigator.clipboard.writeText(field.value); showToast("Clave copiada. Pégala en el sincronizador de tu PC."); }
    catch { field.focus(); field.select(); showToast("Selecciona la clave y cópiala con Ctrl+C."); }
  });
  $("#close-device-token").addEventListener("click", hideDeviceToken);
  $("#auctioneer-import-button").addEventListener("click", () => $("#auctioneer-history-file").click());
  $("#auctioneer-history-file").addEventListener("change", event => {
    const file = event.target.files[0];
    auctioneerAction($("#auctioneer-import-button"), async () => {
      const text = await readLua(file);
      if (!text) return;
      const result = await request("/api/auctioneer/import", {text, realm: "", confirmedMarket: false});
      if (!result.requiresRealm || !Array.isArray(result.realms) || !result.realms.length) throw new Error("El archivo no contiene reinos compatibles. Comprueba la versión de Auctioneer.");
      pendingAuctioneerText = text;
      const form = $("#auctioneer-realm-form");
      form.elements.realm.replaceChildren(...result.realms.map(realm => {
        const value = typeof realm === "string" ? realm : realm.realm || realm.name || "";
        const option = element("option", value);
        option.value = value;
        return option;
      }));
      form.elements.confirmedMarket.checked = false;
      form.hidden = false;
      $("#auctioneer-import-feedback").textContent = "Archivo leído: " + file.name + ". Elige el reino y confirma el mercado.";
    }).finally(() => { event.target.value = ""; });
  });
  $("#auctioneer-realm-form").addEventListener("submit", event => {
    event.preventDefault();
    const form = event.currentTarget;
    auctioneerAction(form.querySelector("button"), async () => {
      if (!pendingAuctioneerText) throw new Error("Selecciona de nuevo el archivo del histórico.");
      await request("/api/auctioneer/import", {text: pendingAuctioneerText, realm: form.elements.realm.value, confirmedMarket: form.elements.confirmedMarket.checked});
      pendingAuctioneerText = "";
      form.hidden = true;
      await refresh();
      $("#auctioneer-import-feedback").textContent = "Histórico incorporado. Se mantiene separado de las ofertas recientes.";
      $("#auctioneer-import-feedback").classList.add("success");
      showToast("Histórico de Auctioneer incorporado.");
    });
  });
  $("#auctioneer-bridge-button").addEventListener("click", () => $("#auctioneer-bridge-file").click());
  $("#auctioneer-bridge-file").addEventListener("change", event => {
    const file = event.target.files[0];
    auctioneerAction($("#auctioneer-bridge-button"), async () => {
      const text = await readLua(file);
      if (!text) return;
      await request("/api/auctioneer/bridge", {text});
      await refresh();
      showToast("Captura incorporada. Revisa su fecha y alcance antes de operar.");
    }).finally(() => { event.target.value = ""; });
  });
  $("#strategy-calculator").addEventListener("input", event => { event.currentTarget.dataset.edited = "true"; });
  $("#strategy-calculator").elements.method.addEventListener("change", () => {
    const form = $("#strategy-calculator");
    const vendor = form.elements.method.value === "vendor";
    form.elements.feePercent.disabled = vendor;
    form.elements.feePercent.value = vendor ? "0" : String(state.settings?.feePercent ?? 5);
    $("#calculator-results").hidden = true;
  });
  $("#strategy-calculator").addEventListener("submit", event => {
    event.preventDefault();
    const form = event.currentTarget;
    const feedback = $("#calculator-feedback");
    feedback.textContent = "";
    try {
      const cost = goldToCopper(form.elements.costGold.value, "Compra");
      const sale = goldToCopper(form.elements.saleGold.value, "Venta esperada");
      const extra = goldToCopper(form.elements.extraGold.value, "Otros costes");
      const feePercent = form.elements.method.value === "vendor" ? 0 : Number(form.elements.feePercent.value);
      const roiPercent = Number(form.elements.minRoiPercent.value);
      if (!Number.isFinite(feePercent) || feePercent < 0 || feePercent > 50 || !Number.isFinite(roiPercent) || roiPercent < 0 || roiPercent > 500) throw new Error("Comprueba comisión y ROI: los valores están fuera de rango.");
      if (cost <= 0 || sale <= 0) throw new Error("Introduce un coste de compra y una venta esperada mayores que cero.");
      const fee = Math.round(sale * feePercent / 100);
      const profit = sale - fee - cost - extra;
      const roi = profit / cost * 100;
      const maxBuy = Math.max(0, Math.floor((sale * (1 - feePercent / 100) - extra) / (1 + roiPercent / 100)));
      const breakEven = Math.ceil((cost + extra) / (1 - feePercent / 100));
      $("#calc-profit").textContent = toGold(profit) + " g";
      $("#calc-profit").classList.toggle("negative", profit < 0);
      $("#calc-roi").textContent = new Intl.NumberFormat("es-ES", {maximumFractionDigits: 1}).format(roi) + " %";
      $("#calc-max-buy").textContent = toGold(maxBuy) + " g";
      $("#calc-break-even").textContent = toGold(breakEven) + " g";
      $("#calculator-results").hidden = false;
      feedback.textContent = profit > 0 && roi >= roiPercent ? "La estimación cumple tu umbral. Verifica precios, cantidades y demanda antes de operar." : "La estimación no cumple tu umbral de beneficio. Revisa el coste o la venta prevista.";
      feedback.classList.toggle("success", profit > 0 && roi >= roiPercent);
    } catch (error) {
      feedback.textContent = error.message;
      feedback.classList.remove("success");
      $("#calculator-results").hidden = true;
    }
  });
  window.addEventListener("hashchange", () => switchView(location.hash.slice(1), false));
  switchView(location.hash.slice(1), false);
  refresh().catch((error) => {
    state.status = {state: "unavailable", message: error.message};
    render();
  });
  // Re-evaluate scan age locally; this never polls the external price provider.
  setInterval(() => {
    if (document.hidden || activeView === "settings" || $("#transaction-dialog").open || loading || auctioneerBusy) return;
    refresh().catch((error) => {
      state.status = {...state.status, state: "unavailable", message: error.message};
      renderStatus();
      renderOpportunities();
    });
  }, 15000);
})();

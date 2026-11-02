/** Browser-only Pages runtime. Market files never leave the browser. */
import {MARKET, emptyState, validateSettings, importSnapshot, addTransaction,
  computeState, historyState, addHistory, exportBackup, restoreBackup, latestSnapshotRealm, stamp} from "../src/engine.mjs";
import {normalizeOverTime, normalizeBridge} from "../src/auctioneer.mjs";

export const MAX_LOCAL_STATE_BYTES = 16 * 1024 * 1024;
const encoder = new TextEncoder();
const clone = value => structuredClone(value);

function fail(message, status = 400) { const error = new Error(message); error.status = status; throw error; }
function record(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function body(value) { if (!record(value)) fail("Se requiere un objeto JSON."); return value; }
function blankEnvelope() { return {state:emptyState(), previousBackup:null}; }
function envelope(value) {
  if (value === undefined) return blankEnvelope();
  if (!record(value) || !record(value.state) || !(value.previousBackup === null || record(value.previousBackup))) {
    fail("Los datos locales no tienen un formato compatible. Conserva una copia antes de restablecer el navegador.", 500);
  }
  return clone(value);
}
function bounded(value) {
  if (encoder.encode(JSON.stringify(value)).byteLength > MAX_LOCAL_STATE_BYTES) {
    fail("Los datos superan los 16 MiB admitidos en esta versión. No se ha guardado ningún cambio; exporta una copia antes de continuar.", 507);
  }
}
function storageError(error) {
  if (error?.status) return error;
  const result = new Error("El navegador no ha podido guardar los datos. Comprueba el espacio disponible y los permisos de almacenamiento; tus datos anteriores se conservan.");
  result.status = 507;
  result.cause = error;
  return result;
}

/**
 * The complete envelope uses one IndexedDB record and one read/write transaction.
 * Cross-tab mutations therefore read the newest state while holding a write lock.
 * update callbacks must be synchronous; only committed transactions resolve.
 */
export function createIndexedDbRepository({indexedDB = globalThis.indexedDB,
  databaseName = "el-especulador-pages-v1:" + new URL(".", import.meta.url).pathname} = {}) {
  if (!indexedDB || typeof indexedDB.open !== "function") fail("Este navegador no permite guardar los datos localmente. Habilita IndexedDB o utiliza otro navegador.", 507);
  if (typeof databaseName !== "string" || !databaseName.trim() || databaseName.length > 500) fail("Nombre de almacenamiento local no válido.");
  let opened, closed = false;
  const open = () => {
    if (closed) return Promise.reject(storageError(new Error("Almacenamiento cerrado.")));
    opened ??= new Promise((resolve, reject) => {
      let request;
      try { request = indexedDB.open(databaseName, 1); }
      catch (error) { reject(storageError(error)); return; }
      let settled = false;
      const rejectOnce = error => { if (!settled) { settled = true; reject(storageError(error)); } };
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains("portfolio")) db.createObjectStore("portfolio");
      };
      request.onerror = () => rejectOnce(request.error);
      request.onblocked = () => rejectOnce(new Error("Cierra las otras pestañas de esta app y vuelve a abrirla."));
      request.onsuccess = () => {
        const db = request.result;
        if (closed || settled) { db.close(); rejectOnce(new Error("Almacenamiento cerrado.")); return; }
        db.onversionchange = () => { closed = true; db.close(); };
        settled = true;
        resolve(db);
      };
    });
    return opened;
  };

  async function transact(write, operation) {
    const db = await open();
    if (closed) throw storageError(new Error("Almacenamiento cerrado."));
    return new Promise((resolve, reject) => {
      let transaction, result, failure;
      try { transaction = db.transaction("portfolio", write ? "readwrite" : "readonly"); }
      catch (error) { reject(storageError(error)); return; }
      transaction.oncomplete = () => resolve(clone(result));
      transaction.onabort = () => reject(failure || storageError(transaction.error));
      transaction.onerror = () => { failure ??= storageError(transaction.error); };
      const store = transaction.objectStore("portfolio"), request = store.get("active");
      request.onsuccess = () => {
        try {
          const draft = envelope(request.result);
          result = operation(draft);
          if (result && typeof result.then === "function") fail("La operación local debe ser síncrona.", 500);
          if (write) {
            bounded(draft.state);
            if (draft.previousBackup !== null) bounded(draft.previousBackup);
            store.put(draft, "active");
          }
        } catch (error) {
          failure = error?.status ? error : storageError(error);
          transaction.abort();
        }
      };
    });
  }

  return {
    read: () => transact(false, draft => draft),
    update: operation => {
      if (typeof operation !== "function") return Promise.reject(storageError(new Error("Falta la operación local.")));
      return transact(true, operation);
    },
    async close() {
      closed = true;
      if (opened) { try { (await opened).close(); } catch { /* Already failed/closed. */ } }
    }
  };
}

function sourceView(state, nowMs) {
  const bridge = state.sourceMeta?.bridge || {lastImportedAt:null,itemCount:0,scope:"partial",status:"experimental"};
  const latest = state.sourceMeta?.lastImport || {};
  const realm = latestSnapshotRealm(state) || state.sourceMeta?.historyRealm || bridge.realm || null;
  return {activeRealm:realm,devices:[],bridge,history:historyState(state,realm,nowMs),
    connection:{configured:false,enabled:false,realm,lastCheckedAt:latest.checkedAt || null,
      lastImportedAt:latest.importedAt || null,lastError:latest.error || null}};
}

function snapshotFromAHL(text) {
  if (typeof text !== "string" || text.length > MAX_LOCAL_STATE_BYTES) fail("Tabla AHL1 no válida.");
  const lines = text.trim().split(/\r?\n/), header = lines.shift()?.split("|");
  if (header?.length !== 4 || header[0] !== "AHL1" || header[1] !== MARKET.replaceAll(".","/")) fail("Se necesita una tabla AHL1 de Europa · PvP · Alianza.");
  if (!/^\d+$/.test(header[2]) || !/^\d+$/.test(header[3]) || Number(header[3]) !== lines.length || lines.length > 50000) fail("Tabla AHL1 incompleta o no válida.");
  const timestamp = Number(header[2]) * 1000;
  if (!Number.isSafeInteger(timestamp) || !Number.isFinite(new Date(timestamp).getTime())) fail("Fecha AHL1 no válida.");
  const items = [];
  for (const line of lines) {
    const fields = line.split(":");
    if (fields.length !== 9 || fields.some(field => field && !/^\d+$/.test(field))) fail("Fila AHL1 no válida.");
    const [id,,buy,quantity,ref7,ref30] = fields;
    if (buy && Number(buy) > 0 && quantity !== "") {
      const refs = [ref7,ref30].filter(value => value && Number(value) > 0).map(Number);
      const itemId = Number(id);
      items.push({itemId,name:`Objeto ${itemId}`,buyCopper:Number(buy),quantityAvailable:Number(quantity),referenceCopper:refs.length ? Math.min(...refs) : null});
    }
  }
  return {market:MARKET,source:"AHledger",observedAt:new Date(timestamp).toISOString(),items};
}

const unsupported = new Map([
  ["/api/login", "GitHub Pages guarda los datos en este navegador y no utiliza cuentas ni contraseñas. Para tu cuenta privada, abre la app de Cloudflare."],
  ["/api/logout", "Esta versión local no tiene una sesión de usuario que cerrar. Tus datos permanecen en este navegador."],
  ["/api/sync", "GitHub Pages no recibe envíos del PC. Importa manualmente un archivo del addon; actualizar la página no genera precios nuevos."],
  ["/api/auctioneer/sync", "GitHub Pages no recibe envíos del PC. Importa manualmente los archivos de Auctioneer."],
  ["/api/auctioneer/config", "Esta versión no puede leer rutas de tu PC. Selecciona los archivos que quieras importar."],
  ["/api/devices", "Las claves y el sincronizador del PC pertenecen a la app privada de Cloudflare. En GitHub Pages se utiliza importación manual."],
  ["/api/devices/revoke", "GitHub Pages no gestiona claves ni equipos autorizados."],
  ["/api/device/sync", "GitHub Pages no admite sincronización remota. Usa la URL de la app privada de Cloudflare en el sincronizador."],
  ["/api/connector", "El sincronizador requiere la app privada de Cloudflare; no puede enviar datos a GitHub Pages."]
]);

/**
 * Compatible JSON-body transport for public/app.js. No fetch, tokens or cookies.
 * A custom repository must isolate drafts and commit update(callback) atomically.
 */
export function createLocalApi({repository, now = Date.now} = {}) {
  if (!repository || typeof repository.read !== "function" || typeof repository.update !== "function") fail("Falta el almacenamiento local de la app.", 500);
  const clock = () => {
    const value = typeof now === "function" ? now() : now;
    if (!Number.isFinite(value) || !Number.isFinite(new Date(value).getTime())) fail("Reloj local no válido.");
    return value;
  };
  const read = async () => {
    try { return envelope(await repository.read()); }
    catch (error) { throw storageError(error); }
  };
  const update = async operation => {
    try {
      return await repository.update(draft => {
        try {
          const result = operation(draft);
          bounded(draft.state);
          if (draft.previousBackup !== null) bounded(draft.previousBackup);
          return result;
        } catch (error) { if (!error.status) error.status = 400; throw error; }
      });
    } catch (error) { throw storageError(error); }
  };

  return {
    async request(path, data) {
      try {
        if (typeof path !== "string" || !path.startsWith("/api/")) fail("Ruta local no encontrada.", 404);
        const url = new URL(path,"https://especulador-local.invalid"), route = url.pathname;
        const nowMs = clock();
        if (unsupported.has(route)) fail(unsupported.get(route));
        if (data === undefined) {
          const stored = await read(), state = stored.state;
          if (route === "/api/state") return {...computeState(state,nowMs),token:"",localMode:true,auctioneer:sourceView(state,nowMs)};
          if (route === "/api/history") return historyState(state,url.searchParams.get("realm") || latestSnapshotRealm(state) || state.sourceMeta?.historyRealm || null,nowMs);
          if (route === "/api/export") return exportBackup(state,nowMs);
          if (route === "/api/backups/previous") {
            if (!stored.previousBackup) fail("Todavía no hay copia anterior a una restauración.",404);
            return clone(stored.previousBackup);
          }
          fail("Ruta local no encontrada.",404);
        }
        body(data);
        if (route === "/api/auctioneer/import") {
          const normalized = normalizeOverTime(data.text,data.realm ?? null,data.confirmedMarket,nowMs);
          if (normalized.requiresRealm) return normalized;
          return update(draft => {
            addHistory(draft.state,normalized.realm,normalized.rows,nowMs);
            draft.state.sourceMeta.lastImport = {checkedAt:stamp(nowMs),importedAt:stamp(nowMs),error:null};
            return {imported:normalized.rows.length,realm:normalized.realm,warning:normalized.warning};
          });
        }
        if (route === "/api/auctioneer/bridge") {
          const bridge = normalizeBridge(data.text,nowMs);
          return update(draft => {
            importSnapshot(draft.state,bridge.snapshot,nowMs);
            draft.state.sourceMeta.bridge = bridge.bridgeMeta;
            draft.state.sourceMeta.lastImport = {checkedAt:stamp(nowMs),importedAt:stamp(nowMs),error:null};
            return clone(bridge.bridgeMeta);
          });
        }
        if (route === "/api/settings") return update(draft => (draft.state.settings = validateSettings(draft.state.settings,data)));
        if (route === "/api/transactions") return update(draft => addTransaction(draft.state,data,nowMs));
        if (route === "/api/import") return update(draft => {
          const imported = importSnapshot(draft.state,data.ahlTable ? snapshotFromAHL(data.ahlTable) : data,nowMs);
          return {imported:imported.items.length,ignored:!!imported.ignored};
        });
        if (route === "/api/restore") {
          const replacement = restoreBackup(data,nowMs);
          return update(draft => {
            draft.previousBackup = exportBackup(draft.state,nowMs);
            draft.state = clone(replacement);
            return {restored:true,connectionPaused:false};
          });
        }
        fail("Ruta local no encontrada.",404);
      } catch (error) {
        if (error?.status) throw error;
        const result = new Error(error?.message || "No se ha podido completar la operación local.");
        result.status = 400;
        throw result;
      }
    }
  };
}

import {Store} from "./storage.mjs";
import {MARKET, emptyState, validateSettings, normalizeSnapshot, importSnapshot, addTransaction,
  computeState, historyState, addHistory, exportBackup, restoreBackup, latestSnapshotRealm} from "./engine.mjs";
import {normalizeOverTime, normalizeBridge} from "./auctioneer.mjs";

const VERSION = "0.3.0";
const COOKIE = "__Host-especulador_session";
const SESSION_SECONDS = 8 * 3600;
const MAX_BODY = 16 * 1024 * 1024;
const encoder = new TextEncoder();
const stamp = () => new Date().toISOString();

export function json(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), {status, headers: {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store", ...extra}});
}
function fail(message, status = 400) { const error = new Error(message); error.status = status; throw error; }
function plain(value) { if (!value || typeof value !== "object" || Array.isArray(value)) fail("Se requiere un objeto JSON."); return value; }
async function bodyJSON(request, limit = MAX_BODY) {
  if (!request.body) fail("Faltan los datos de la petición.");
  const declared = Number(request.headers.get("Content-Length") || 0);
  if (declared > limit) fail("El archivo supera el límite permitido.", 413);
  const reader = request.body.getReader(), parts = [];
  let total = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) { await reader.cancel(); fail("El archivo supera el límite permitido.", 413); }
    parts.push(value);
  }
  const raw = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) { raw.set(part, offset); offset += part.length; }
  try { return plain(JSON.parse(new TextDecoder("utf-8", {fatal:true}).decode(raw))); }
  catch (error) { if (error.status) throw error; fail("El archivo no contiene un objeto JSON válido."); }
}
function base64url(bytes) { let text = ""; for (const byte of bytes) text += String.fromCharCode(byte); return btoa(text).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_"); }
function unbase64(text) { if (!/^[A-Za-z0-9_-]+$/.test(text)) throw new Error("base64"); const value = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4-text.length%4)%4)); return Uint8Array.from(value, c=>c.charCodeAt(0)); }
function randomToken() { return base64url(crypto.getRandomValues(new Uint8Array(32))); }
async function digest(text) { return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text))), byte=>byte.toString(16).padStart(2,"0")).join(""); }
async function sign(text, env) {
  const secret = (env.SESSION_SECRET || "")+":"+env.OWNER_PASSWORD;
  const key = await crypto.subtle.importKey("raw", encoder.encode("especulador-session-v1:"+secret), {name:"HMAC",hash:"SHA-256"}, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC",key,encoder.encode(text))));
}
function equal(a, b) { if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false; let diff = 0; for (let i=0;i<a.length;i++) diff |= a.charCodeAt(i)^b.charCodeAt(i); return diff === 0; }
export async function issueSession(env, nowMs = Date.now()) {
  const payload = base64url(encoder.encode(JSON.stringify({v:1, exp: Math.floor(nowMs/1000)+SESSION_SECONDS, nonce:randomToken()})));
  const value = payload+"."+await sign(payload,env);
  return {value, csrf:await sign("csrf:"+value,env)};
}
export async function readSession(request, env, nowMs = Date.now()) {
  const cookie = request.headers.get("Cookie") || "";
  const value = cookie.split(";").map(v=>v.trim()).find(v=>v.startsWith(COOKIE+"="))?.slice(COOKIE.length+1);
  if (!value || value.length > 1200) return null;
  try {
    const [payload, signature, extra] = value.split(".");
    if (extra || !signature || !equal(signature, await sign(payload,env))) return null;
    const parsed = JSON.parse(new TextDecoder().decode(unbase64(payload)));
    const now = Math.floor(nowMs/1000);
    if (parsed.v !== 1 || !Number.isSafeInteger(parsed.exp) || parsed.exp <= now || parsed.exp > now+SESSION_SECONDS || typeof parsed.nonce !== "string" || parsed.nonce.length !== 43) return null;
    return {value, csrf:await sign("csrf:"+value,env)};
  } catch { return null; }
}
function secure(response) {
  const headers = new Headers(response.headers);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Frame-Options", "DENY");
  headers.set("Referrer-Policy", "same-origin");
  headers.set("X-Robots-Tag", "noindex, nofollow, noarchive");
  headers.set("Cache-Control", "private, no-store");
  headers.set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
  headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  return new Response(response.body, {status:response.status, statusText:response.statusText, headers});
}
function configurationIssue(env) {
  const password = env.OWNER_PASSWORD;
  if (password === undefined || password === null || password === "") return "missing_password";
  if (typeof password !== "string") return "invalid_password_type";
  return password.length < 16 ? "password_too_short" : null;
}
function configurationError(issue) {
  if (issue === "password_too_short") return "La contraseña guardada en Cloudflare tiene menos de 16 caracteres. Sustitúyela por una de al menos 16 caracteres y despliega el cambio para habilitar el acceso privado.";
  if (issue === "invalid_password_type") return "El secreto OWNER_PASSWORD no está configurado como texto. Configúralo como un secreto de texto en Cloudflare y despliega el cambio para habilitar el acceso privado.";
  return "La app está preparada. Configura el secreto OWNER_PASSWORD (mínimo 16 caracteres) en Cloudflare para habilitar el acceso privado.";
}
function portfolio(env) { return env.PORTFOLIO.get(env.PORTFOLIO.idFromName("owner-eu-pvp-alliance-v1")); }
async function internal(env, path, data, headers = {}) {
  return portfolio(env).fetch(new Request("https://portfolio.internal"+path, {method:"POST", headers:{"Content-Type":"application/json",...headers}, body:JSON.stringify(data)}));
}
function originCheck(request) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) fail("Origen de petición no válido.",403);
  if (request.headers.get("Sec-Fetch-Site") === "cross-site") fail("Origen de petición no válido.",403);
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url), path = url.pathname, setupIssue = configurationIssue(env);
      if (path === "/api/health" && request.method === "GET") return secure(json({ok:true,version:VERSION,configured:setupIssue === null,configurationIssue:setupIssue}));
      const publicAssets = new Set(["/login", "/login.html", "/login.js", "/login.css", "/styles.css", "/auction-hall.svg"]);
      if (request.method === "GET" && publicAssets.has(path)) {
        if (path === "/login") url.pathname = "/login.html";
        return secure(await env.ASSETS.fetch(new Request(url,request)));
      }
      if (setupIssue) return secure(path.startsWith("/api/") ? json({error:configurationError(setupIssue)},503) : Response.redirect(url.origin+"/login",302));
      if (path === "/api/login" && request.method === "POST") {
        originCheck(request);
        const ip = await digest("login:"+(request.headers.get("CF-Connecting-IP") || "unknown"));
        const allowed = await internal(env,"/internal/auth-limit",{key:ip});
        if (!(await allowed.json()).allowed) return secure(json({error:"Demasiados intentos. Vuelve a intentarlo dentro de 15 minutos."},429));
        const data = await bodyJSON(request,2048);
        const password = typeof data.password === "string" && data.password.length <= 1024 ? data.password : "";
        if (!equal(await digest(password),await digest(env.OWNER_PASSWORD))) return secure(json({error:"Contraseña incorrecta."},401));
        await internal(env,"/internal/auth-clear",{key:ip});
        const session = await issueSession(env);
        return secure(json({ok:true},200,{"Set-Cookie":`${COOKIE}=${session.value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_SECONDS}`}));
      }
      if (path === "/api/device/sync" && request.method === "POST") {
        const token = request.headers.get("Authorization")?.match(/^Bearer (esp_[A-Za-z0-9_-]{43})$/)?.[1];
        if (!token) return secure(json({error:"Clave de dispositivo no válida."},401));
        const headers = new Headers(request.headers);
        headers.delete("Cookie"); headers.delete("Authorization");
        headers.delete("X-Owner-CSRF"); headers.delete("X-Device-Hash");
        headers.set("X-Device-Hash",await digest(token));
        const forwarded = new Request("https://portfolio.internal/api/device/sync",{method:"POST",headers,body:request.body,duplex:"half"});
        return secure(await portfolio(env).fetch(forwarded));
      }
      const session = await readSession(request,env);
      if (!session) return secure(path.startsWith("/api/") ? json({error:"Inicia sesión para acceder a tu cuenta."},401) : Response.redirect(url.origin+"/login",302));
      if (!["GET","HEAD"].includes(request.method)) {
        originCheck(request);
        if (!equal(request.headers.get("X-CSRF-Token"),session.csrf)) return secure(json({error:"La sesión ha cambiado. Recarga la app."},403));
      }
      if (path === "/api/logout" && request.method === "POST") return secure(json({ok:true},200,{"Set-Cookie":`${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`}));
      if (path === "/api/addon" || path === "/api/connector") {
        if (request.method !== "GET") return secure(json({error:"Método no admitido."},405));
        url.pathname = path === "/api/addon" ? "/downloads/EspeculadorBridge.zip" : "/downloads/Sincronizador_PC.zip";
        const response = await env.ASSETS.fetch(new Request(url,request));
        const headers = new Headers(response.headers);
        headers.set("Content-Disposition",`attachment; filename="${url.pathname.split("/").at(-1)}"`);
        return secure(new Response(response.body,{status:response.status,headers}));
      }
      // Never serve private downloads via an unauthenticated asset shortcut.
      if (path.startsWith("/api/")) {
        const headers = new Headers(request.headers);
        headers.delete("X-Device-Hash"); headers.delete("X-Owner-CSRF"); headers.delete("Cookie"); headers.delete("Authorization");
        headers.set("X-Owner-CSRF",session.csrf);
        const forwarded = new Request("https://portfolio.internal"+path+url.search,{method:request.method,headers,
          ...(!["GET","HEAD"].includes(request.method) ? {body:request.body,duplex:"half"} : {})});
        return secure(await portfolio(env).fetch(forwarded));
      }
      if (path === "/") url.pathname = "/index.html";
      return secure(await env.ASSETS.fetch(new Request(url,request)));
    } catch (error) {
      return secure(json({error:error.status ? error.message : "No se ha podido completar la petición."},error.status || 500));
    }
  }
};

function sourceView(state, devices) {
  const bridge = state.sourceMeta?.bridge || {lastImportedAt:null,itemCount:0,scope:"partial",status:"experimental"};
  const latest = state.sourceMeta?.lastImport || {};
  const realm = latestSnapshotRealm(state) || state.sourceMeta?.historyRealm || bridge.realm || null;
  return {activeRealm:realm,devices,bridge,history:historyState(state,realm),
    connection:{configured:devices.some(d=>!d.revoked),enabled:devices.some(d=>!d.revoked),realm,
      lastCheckedAt:latest.checkedAt || null,lastImportedAt:latest.importedAt || null,lastError:latest.error || null}};
}
function prepareSources(data) {
  if (data.confirmedMarket !== true) fail("Confirma Europa · PvP · Alianza antes de sincronizar.");
  if (typeof data.historyText !== "string" && typeof data.bridgeText !== "string") fail("El envío no contiene archivos compatibles.");
  let history, bridge;
  if (data.historyText != null) {
    history = normalizeOverTime(data.historyText,data.realm,true);
    if (history.requiresRealm) fail("Selecciona el reino del histórico.");
  }
  if (data.bridgeText != null) {
    bridge = normalizeBridge(data.bridgeText);
    normalizeSnapshot(bridge.snapshot);
    if (typeof data.realm !== "string" || bridge.realm !== data.realm) fail("El reino del puente no coincide con el seleccionado.");
  }
  if (history && bridge && history.realm !== bridge.realm) fail("Los archivos pertenecen a reinos distintos.");
  return {history,bridge};
}
function snapshotFromAHL(text) {
  if (typeof text !== "string" || text.length > MAX_BODY) fail("Tabla AHL1 no válida.");
  const lines=text.trim().split(/\r?\n/), header=lines.shift()?.split("|");
  if (header?.length !== 4 || header[0] !== "AHL1" || header[1] !== MARKET.replaceAll(".","/")) fail("Se necesita una tabla AHL1 de Europa · PvP · Alianza.");
  if (!/^\d+$/.test(header[2]) || !/^\d+$/.test(header[3]) || Number(header[3]) !== lines.length || lines.length > 50000) fail("Tabla AHL1 incompleta o no válida.");
  const timestamp=Number(header[2])*1000;
  if (!Number.isSafeInteger(timestamp) || !Number.isFinite(new Date(timestamp).getTime())) fail("Fecha AHL1 no válida.");
  const items=[];
  for (const line of lines) {
    const fields=line.split(":");
    if (fields.length !== 9 || fields.some(field=>field && !/^\d+$/.test(field))) fail("Fila AHL1 no válida.");
    const [id,,buy,quantity,ref7,ref30]=fields;
    if (buy && Number(buy)>0 && quantity !== "") {
      const refs=[ref7,ref30].filter(v=>v && Number(v)>0).map(Number);
      const itemId=Number(id);
      items.push({itemId,name:`Objeto ${itemId}`,buyCopper:Number(buy),quantityAvailable:Number(quantity),referenceCopper:refs.length?Math.min(...refs):null});
    }
  }
  return {market:MARKET,source:"AHledger",observedAt:new Date(timestamp).toISOString(),items};
}
function applySources(state, prepared) {
  if (prepared.history) addHistory(state,prepared.history.realm,prepared.history.rows);
  if (prepared.bridge) {
    importSnapshot(state,prepared.bridge.snapshot);
    state.sourceMeta.bridge = prepared.bridge.bridgeMeta;
  }
  state.sourceMeta.lastImport = {checkedAt:stamp(),importedAt:stamp(),error:null};
}

export class Portfolio {
  constructor(ctx, env) { this.ctx=ctx; this.env=env; this.store=new Store(ctx); }
  async fetch(request) {
    try {
      const path = new URL(request.url).pathname;
      if (path === "/internal/auth-limit" && request.method === "POST") {
        const data = await bodyJSON(request,2048);
        return json({allowed:this.store.rateLimit(data.key,Date.now())});
      }
      if (path === "/internal/auth-clear" && request.method === "POST") {
        const data=await bodyJSON(request,2048); this.store.resetRateLimit(data.key); return json({ok:true});
      }
      if (path === "/api/device/sync" && request.method === "POST") {
        let device = this.store.findDevice(request.headers.get("X-Device-Hash"));
        if (!device || device.revoked) return json({error:"La clave del dispositivo ha sido rechazada o revocada."},401);
        const prepared = prepareSources(await bodyJSON(request));
        device = this.store.findDevice(request.headers.get("X-Device-Hash"));
        if (!device || device.revoked) return json({error:"La clave del dispositivo ha sido revocada durante el envío."},401);
        const state = this.store.loadState();
        applySources(state,prepared);
        this.store.saveState(state);
        this.store.markDeviceSeen(device.id,stamp());
        return json({accepted:true,observedAt:state.snapshots[0]?.observedAt || null});
      }
      const csrf = request.headers.get("X-Owner-CSRF");
      if (!csrf) return json({error:"Acceso privado requerido."},401);
      if (request.method === "GET") {
        const state=this.store.loadState();
        if (path === "/api/state") return json({...computeState(state),token:csrf,auctioneer:sourceView(state,this.store.listDevices())});
        if (path === "/api/export") return json(exportBackup(state),200,{"Content-Disposition":'attachment; filename="El_Especulador_copia.json"'});
        if (path === "/api/backups/previous") {
          const backup=this.store.loadPreviousBackup();
          return backup ? json(backup,200,{"Content-Disposition":'attachment; filename="Especulador_antes_de_restaurar.json"'}) : json({error:"Todavía no hay copia anterior a una restauración."},404);
        }
        return json({error:"Ruta no encontrada."},404);
      }
      if (request.method !== "POST") return json({error:"Método no admitido."},405);
      const data = await bodyJSON(request);
      if (path === "/api/devices") {
        const token="esp_"+randomToken(), tokenHash=await digest(token);
        if (this.store.listDevices().filter(d=>!d.revoked).length >= 16) fail("Revoca una clave anterior antes de autorizar más equipos.");
        const device={id:crypto.randomUUID(),label:data.label,tokenHash,createdAt:stamp()};
        this.store.createDevice(device);
        return json({id:device.id,token});
      }
      if (path === "/api/devices/revoke") { this.store.revokeDevice(data.id); return json({revoked:true}); }
      if (path === "/api/auctioneer/config") return json({error:"La nube no lee rutas de tu PC. Empareja el sincronizador o importa los archivos."},400);
      if (path === "/api/auctioneer/sync" || path === "/api/sync") return json({connected:false,message:"Los escaneos llegan desde tu PC emparejado o mediante importación. Actualizar la página no genera precios nuevos."});
      const state=this.store.loadState();
      let result;
      if (path === "/api/settings") { state.settings=validateSettings(state.settings,data); result=state.settings; }
      else if (path === "/api/transactions") result=addTransaction(state,data);
      else if (path === "/api/import") {
        const snapshot=importSnapshot(state,data.ahlTable ? snapshotFromAHL(data.ahlTable) : data); result={imported:snapshot.items.length,ignored:!!snapshot.ignored};
      }
      else if (path === "/api/auctioneer/import") {
        const normalized=normalizeOverTime(data.text,data.realm,data.confirmedMarket);
        if (normalized.requiresRealm) return json(normalized);
        addHistory(state,normalized.realm,normalized.rows);
        state.sourceMeta.lastImport={checkedAt:stamp(),importedAt:stamp(),error:null};
        result={imported:normalized.rows.length,realm:normalized.realm,warning:normalized.warning};
      }
      else if (path === "/api/auctioneer/bridge") {
        const bridge=normalizeBridge(data.text);
        importSnapshot(state,bridge.snapshot);
        state.sourceMeta.bridge=bridge.bridgeMeta;
        state.sourceMeta.lastImport={checkedAt:stamp(),importedAt:stamp(),error:null};
        result=bridge.bridgeMeta;
      }
      else if (path === "/api/restore") {
        const replacement=restoreBackup(data);
        this.store.snapshotBackup(exportBackup(state));
        this.store.saveState(replacement);
        return json({restored:true,connectionPaused:false});
      }
      else return json({error:"Ruta no encontrada."},404);
      this.store.saveState(state);
      return json(result);
    } catch (error) {
      return json({error:error.message || "No se ha podido completar la operación."},error.status || 400);
    }
  }
}

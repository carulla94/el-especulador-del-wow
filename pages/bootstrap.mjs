import {createLocalApi, createIndexedDbRepository} from "./local-api.mjs";

const CLOUD_URL = "https://el-especulador-del-wow.arqcon-cat.workers.dev/";
let api;
try {
  const repository = createIndexedDbRepository({databaseName: `el-especulador-pages-v1:${location.pathname.replace(/index\.html$/, "")}`});
  api = createLocalApi({repository});
} catch (storageError) {
  // Fail locally even when browser storage is unavailable. Never fall back to
  // the Cloudflare transport or silently discard writes in an in-memory store.
  api = {async request() { throw storageError; }};
}
window.especuladorLocal = api;

const $ = selector => document.querySelector(selector);
const note = $(".local-note");
note.replaceChildren(document.createTextNode("Datos en este navegador"));
$("#logout-button").hidden = true;
$("#hero-auctioneer-button").textContent = "Importar Auctioneer →";
const cloudLink = document.createElement("a");
cloudLink.href = CLOUD_URL;
cloudLink.className = "button subtle small";
cloudLink.textContent = "Cuenta en la nube";
cloudLink.target = "_blank";
cloudLink.rel = "noopener noreferrer";
$(".account-actions").append(cloudLink);

const notice = document.createElement("div");
notice.className = "guidance-card";
const copy = document.createElement("div");
const title = document.createElement("strong");
title.textContent = "Edición GitHub Pages · Datos locales";
const description = document.createElement("p");
description.textContent = "Tus escaneos y movimientos se guardan solo en este navegador. Exporta una copia JSON para conservarlos o llevarlos a otro equipo. Esta edición no comparte los datos con tu cuenta de Cloudflare.";
copy.append(title, description);
notice.append(copy);
$("#status-banner").before(notice);

const cloudCards = $(".connector-layout > .settings-side:first-child");
cloudCards.hidden = true;
$(".connector-layout").style.gridTemplateColumns = "minmax(0, 1fr)";
$("#view-auctioneer .count-badge").textContent = "DATOS LOCALES";
const overview = document.querySelectorAll(".auctioneer-overview article");
overview[2].querySelector("strong").textContent = "Importa los archivos aquí";
overview[2].querySelector("p").textContent = "Elige los archivos guardados por WoW. El análisis se hace en tu navegador.";

// Retain required controls in the DOM for the shared UI, but hide cloud-only
// features. No client-side password is presented as protection for local data.
document.querySelectorAll('a[data-pages-connector], a[href="/api/connector"]').forEach(link => { link.hidden = true; });
document.querySelectorAll('a[href="/api/addon"]').forEach(link => { link.href = "./downloads/EspeculadorBridge.zip"; });

function localFeedback(message, isError = false) {
  const toast = $("#toast");
  toast.textContent = message;
  toast.classList.toggle("error", isError);
  toast.hidden = false;
}

document.querySelectorAll('a[data-pages-export], a[href="/api/export"]').forEach(link => {
  link.href = "#copia-json";
  link.addEventListener("click", async event => {
    event.preventDefault();
    try {
      const data = await api.request("/api/export");
      const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], {type: "application/json"}));
      const download = document.createElement("a");
      download.href = url;
      download.download = "El_Especulador_del_WoW_copia_local.json";
      document.body.append(download);
      download.click();
      download.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
    } catch (error) { localFeedback(error.message, true); }
  });
});

// All app API requests use the local adapter. Cloudflare's request code and
// authentication remain untouched when this Pages entry point is not loaded.
await import("../app.js");

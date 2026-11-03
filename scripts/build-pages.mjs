/** Build the isolated, browser-local GitHub Pages edition. No account data is read. */
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = path.resolve(root, "dist-pages");
const expectedOutput = path.join(root, "dist-pages");
if (output !== expectedOutput || path.relative(root, output) !== "dist-pages") {
  throw new Error("El destino de Pages debe ser dist-pages dentro del proyecto.");
}
for (const file of ["pages/bootstrap.mjs", "pages/local-api.mjs", "src/engine.mjs", "src/auctioneer.mjs"]) {
  if (!fs.statSync(path.join(root, file)).isFile()) throw new Error(`Falta el archivo de Pages: ${file}`);
}

// The owned absolute target has been verified above before removing an older build.
fs.rmSync(output, {recursive:true, force:true});
fs.mkdirSync(output, {recursive:true});
const copy = (source, destination = source) => {
  const target = path.join(output, destination);
  fs.mkdirSync(path.dirname(target), {recursive:true});
  fs.copyFileSync(path.join(root, source), target);
};

await import("./prepare-downloads.mjs");
for (const file of ["app.js", "styles.css", "auction-hall.svg"]) copy(`public/${file}`, file);
for (const file of fs.readdirSync(path.join(root, "pages")).filter(file => file.endsWith(".mjs"))) {
  copy(`pages/${file}`);
}
for (const file of ["engine.mjs", "auctioneer.mjs"]) copy(`src/${file}`);
copy("public/downloads/EspeculadorBridge.zip", "downloads/EspeculadorBridge.zip");

let html = fs.readFileSync(path.join(root, "public/index.html"), "utf8");
const entry = '<script src="app.js" defer></script>';
if (!html.includes(entry)) throw new Error("No se ha encontrado la entrada de la interfaz para Pages.");
html = html.replace(entry, '<script type="module" src="./pages/bootstrap.mjs"></script>')
  .replace('href="styles.css"', 'href="./styles.css"')
  .replace('href="/api/addon"', 'href="./downloads/EspeculadorBridge.zip"')
  .replace('href="/api/export"', 'href="#copia-json" data-pages-export')
  .replace('href="/api/connector"', 'href="#cuenta-en-la-nube" data-pages-connector hidden')
  // The guild panel lives only in the Cloudflare edition: Pages is public and never holds guild data.
  .replace('href="/hermandad"', 'href="#hermandad-en-la-nube" data-pages-guild hidden')
  .replace('<html lang="es">', '<html lang="es" data-storage-mode="pages-local">')
  .replace('<meta name="viewport"', '<meta name="robots" content="noindex, nofollow">\n  <meta name="especulador-mode" content="pages-local">\n  <meta name="viewport"')
  .replace(/<title>([^<]+)<\/title>/, '<title>El Especulador del WoW · Datos en este navegador</title>');
fs.writeFileSync(path.join(output, "index.html"), html, "utf8");
fs.writeFileSync(path.join(output, ".nojekyll"), "");
console.log("Pages preparado en dist-pages: datos locales, importación manual y copias JSON.");

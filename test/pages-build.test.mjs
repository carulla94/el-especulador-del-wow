import test, {before} from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {execFileSync} from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = path.join(root, "dist-pages");
const read = name => fs.readFileSync(path.join(output, name), "utf8");
function filesIn(directory, prefix = "") {
  return fs.readdirSync(directory, {withFileTypes:true}).flatMap(entry => {
    const relative = prefix + entry.name;
    return entry.isDirectory() ? filesIn(path.join(directory, entry.name), relative + "/") : [relative];
  }).sort();
}

before(() => {
  execFileSync(process.execPath, ["scripts/build-pages.mjs"], {cwd:root, stdio:"pipe"});
});

test("Pages artifact contains only reviewed static files, with no server or private downloads", () => {
  assert.deepEqual(filesIn(output), [
    ".nojekyll", "app.js", "auction-hall.svg", "downloads/EspeculadorBridge.zip",
    "index.html", "pages/bootstrap.mjs", "pages/local-api.mjs",
    "src/auctioneer.mjs", "src/engine.mjs", "styles.css"
  ]);
  for (const name of filesIn(output).filter(name => !name.endsWith(".zip"))) {
    assert.doesNotMatch(read(name), /CLOUDFLARE_API_TOKEN|OWNER_PASSWORD|__Host-especulador_session/);
  }
});

test("Pages entry and local assets resolve beneath a project subpath", () => {
  const html = read("index.html");
  const project = new URL("https://example.github.io/el-especulador-del-wow/");
  assert.match(html, /data-storage-mode="pages-local"/);
  assert.match(html, /<script type="module" src="\.\/pages\/bootstrap\.mjs"><\/script>/);
  assert.match(html, /href="#copia-json" data-pages-export/);
  assert.match(html, /href="#cuenta-en-la-nube" data-pages-connector hidden/);
  assert.match(html, /href="#hermandad-en-la-nube" data-pages-guild hidden/);
  assert.doesNotMatch(html, /hermandad\.(?:html|js|css)|\/api\/guild/);
  assert.doesNotMatch(html, /(?:href|src)=["']\//);
  for (const [, reference] of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
    if (reference.startsWith("#") || /^https?:/.test(reference)) continue;
    const resolved = new URL(reference, project);
    assert.ok(resolved.pathname.startsWith(project.pathname));
    assert.ok(fs.existsSync(path.join(output, resolved.pathname.slice(project.pathname.length))));
  }
  for (const module of ["pages/bootstrap.mjs", "pages/local-api.mjs", "src/engine.mjs", "src/auctioneer.mjs"]) {
    for (const [, reference] of read(module).matchAll(/(?:from\s*|import\s*\(\s*)["']([^"']+)["']/g)) {
      assert.ok(reference.startsWith("."), `${module}: module reference ${reference} must be relative`);
      assert.ok(fs.existsSync(path.resolve(output, path.dirname(module), reference)));
    }
  }
});

test("Pages initializes local transport before shared UI and does not use network APIs", () => {
  const bootstrap = read("pages/bootstrap.mjs"), sharedUi = read("app.js"), localApi = read("pages/local-api.mjs");
  assert.ok(bootstrap.indexOf("window.especuladorLocal = api") >= 0);
  assert.ok(bootstrap.indexOf("window.especuladorLocal = api") < bootstrap.indexOf('import("../app.js")'));
  assert.match(bootstrap, /data-pages-export/);
  assert.doesNotMatch(bootstrap + localApi, /\bfetch\s*\(|XMLHttpRequest|WebSocket|sendBeacon/);
  assert.ok(sharedUi.indexOf("if (window.especuladorLocal) return window.especuladorLocal.request(path, data)") < sharedUi.indexOf("await fetch(path, options)"));
});

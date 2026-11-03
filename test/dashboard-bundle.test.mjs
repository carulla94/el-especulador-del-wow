/** The documented dashboard bundle (README "Comprobar el proyecto", npm run build:dashboard) is built in a temporary
 * copy of the project, so a new import that the bundler does not know fails here instead of at publication time. */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {execFileSync} from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("the dashboard bundle builds from every module the worker imports and keeps the guild optional", async t => {
  const copy = fs.mkdtempSync(path.join(os.tmpdir(), "especulador-bundle-"));
  t.after(() => fs.rmSync(copy, {recursive: true, force: true}));
  for (const part of ["scripts", "src", "public", "pc_sync", "addon/EspeculadorBridge", "wrangler.jsonc"]) {
    fs.cpSync(path.join(root, part), path.join(copy, part), {recursive: true, filter: source => !/__pycache__|[\\/]downloads$/.test(source)});
  }
  for (const script of ["scripts/prepare-downloads.mjs", "scripts/bundle-dashboard.mjs"]) {
    execFileSync(process.execPath, [script], {cwd: copy, stdio: "pipe"});
  }
  const file = path.join(copy, "dashboard-deploy", "worker.mjs"), bundle = fs.readFileSync(file, "utf8");
  assert.doesNotMatch(bundle, /^import\s/m, "every import is inlined");
  assert.ok(bundle.indexOf("const Especular=(()=>{") < bundle.indexOf("const Guild=(()=>{"), "especular is defined before guild uses it");
  const bundled = await import(pathToFileURL(file).href);
  assert.equal(typeof bundled.GuildMarket, "function");
  assert.equal(typeof bundled.Portfolio, "function");
  const env = {OWNER_PASSWORD: "test-only-owner-password-47-strong", SESSION_SECRET: "test-only-independent-session-secret-99"};
  const guild = await bundled.default.fetch(new Request("https://especulador.test/api/guild/me"), env);
  assert.deepEqual([guild.status, await guild.json()], [503, {error: "Hermandad no configurada."}]);
  const rules = await bundled.default.fetch(new Request("https://especulador.test/especular.js"), env);
  assert.equal(rules.status, 200);
  assert.match(rules.headers.get("Content-Type"), /^text\/javascript/);
  assert.equal(await rules.text(), fs.readFileSync(path.join(root, "src", "especular.mjs"), "utf8"), "the panel's rules are the server's rules");
});

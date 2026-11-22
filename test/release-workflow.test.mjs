/** Releases of Oro de Hermandad (.github/workflows/publicar-oro-hermandad.yml, .github/workflows/oro-hermandad.yml,
 * .pkgmeta, scripts/build-oro-hermandad.mjs): the version lines the workflow reads (contract C9), the uploader line of
 * the release notes and its fallback to the previous Subidor_Windows.zip (D15), «solo_subidor», the reusable uploader
 * workflow (C10), what may reach the packager and the CurseForge zip, and which pull requests run these tests (the
 * check workflow, before the merge: npm test in deploy-cloudflare.yml runs them too). The shell steps are taken from
 * the workflow file itself and run with bash against a fake `gh` that keeps releases and artifacts in a temporary
 * folder (or answers the Actions API from a JSON file): nothing here talks to GitHub, CurseForge or Wago. */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import {fileURLToPath} from "node:url";
import {execFileSync, spawnSync} from "node:child_process";
import {inflateRawSync} from "node:zlib";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = name => fs.readFileSync(path.join(root, name), "utf8");
const PUBLISH = read(".github/workflows/publicar-oro-hermandad.yml"), CHECK = read(".github/workflows/oro-hermandad.yml");
const PACKAGER = "BigWigsMods/packager@01e8631a69c69d7654c788d152630d5fed9e3812 # v2.7.0";
/** Contract between the jobs (SPEC §4.3): the uploader line of the release notes. */
const NOTES_LINE = "^Subidor para Windows ([0-9]+(\\.[0-9]+){1,3})( \\(sin cambios\\))?: Subidor_Windows\\.zip \\(SHA-256 ([0-9a-f]{64})\\)$";
const bash = spawnSync("bash", ["-c", "command -v sha256sum && command -v awk && command -v sort"], {encoding: "utf8"}).status === 0;
const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");

// ---- Reading the workflow file (its own layout: two-space indents, `run: |` blocks) --------------------------------
/** The text of one job, from its `  name:` line to the next job. */
function jobText(yaml, job) {
  const lines = yaml.split("\n"), start = lines.indexOf(`  ${job}:`);
  assert.ok(start > 0, `job ${job}`);
  let end = start + 1;
  while (end < lines.length && !/^  [a-z][a-z0-9-]*:\s*$/.test(lines[end]) && !/^\S/.test(lines[end])) end++;
  return lines.slice(start, end).join("\n");
}
/** The script of the step called `name` in a job, dedented. */
function stepRun(yaml, job, name) {
  const lines = jobText(yaml, job).split("\n");
  const at = lines.findIndex(line => line.trim() === `- name: ${name}`);
  assert.ok(at >= 0, `step «${name}» in ${job}`);
  let i = at + 1;
  while (!/^\s*run: \|\s*$/.test(lines[i])) { assert.ok(i < lines.length && !lines[i].trim().startsWith("- name:"), `run of «${name}»`); i++; }
  const indent = lines[i].indexOf("run:") + 2, out = [];
  for (i++; i < lines.length; i++) {
    if (lines[i].trim() && lines[i].search(/\S/) < indent) break;
    out.push(lines[i].slice(indent));
  }
  return out.join("\n").trimEnd() + "\n";
}
/** A workflow-level env value written as a single-quoted YAML scalar. */
function envValue(yaml, key) {
  const match = new RegExp(`^  ${key}: '((?:[^']|'')*)'$`, "m").exec(yaml);
  assert.ok(match, key);
  return match[1].replace(/''/g, "'");
}
const ifOf = (yaml, job) => /^    if: (.+)$/m.exec(jobText(yaml, job))?.[1] ?? null;

// ---- A fake gh: releases in $FAKE/releases/<tag>/{body,assets/}, the latest tag in $FAKE/latest, run artifacts in
// $FAKE/artifacts/<name>/, every call appended to $FAKE/log.
const FAKE_GH = String.raw`#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE/log"
cmd="$1 $2"; shift 2
tag=""; json=""; dir=""; pattern=""; notes=""; files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json="$2"; shift 2 ;;
    --jq) shift 2 ;;
    --dir|-D) dir="$2"; shift 2 ;;
    --pattern|-p) pattern="$2"; shift 2 ;;
    --name|-n) pattern="$2"; shift 2 ;;
    --notes-file) notes="$2"; shift 2 ;;
    --target|--title) shift 2 ;;
    --clobber|--prerelease) shift ;;
    *) if [ -z "$tag" ]; then tag="$1"; else files+=("$1"); fi; shift ;;
  esac
done
case "$cmd" in
  "run download")
    [ -d "$FAKE/artifacts/$pattern" ] || { echo "no artifact $pattern" >&2; exit 1; }
    mkdir -p "$dir"; cp -R "$FAKE/artifacts/$pattern/." "$dir/" ;;
  "release view")
    if [ -z "$tag" ]; then [ -s "$FAKE/latest" ] || exit 1; tag=$(cat "$FAKE/latest"); fi
    [ -d "$FAKE/releases/$tag" ] || { echo "release not found" >&2; exit 1; }
    case "$json" in tagName) echo "$tag" ;; body) cat "$FAKE/releases/$tag/body" ;; esac ;;
  "release download")
    [ -f "$FAKE/releases/$tag/assets/$pattern" ] || { echo "no assets match" >&2; exit 1; }
    mkdir -p "$dir"; cp "$FAKE/releases/$tag/assets/$pattern" "$dir/" ;;
  "release upload")
    for f in "\${files[@]}"; do cp "$f" "$FAKE/releases/$tag/assets/"; done ;;
  "release edit")
    cp "$notes" "$FAKE/releases/$tag/body" ;;
  "release create")
    mkdir -p "$FAKE/releases/$tag/assets"; cp "$notes" "$FAKE/releases/$tag/body"
    for f in "\${files[@]}"; do cp "$f" "$FAKE/releases/$tag/assets/"; done
    echo "$tag" > "$FAKE/latest" ;;
  *) echo "fake gh: $cmd" >&2; exit 2 ;;
esac
`.replace(/\\\$\{files\[@\]\}/g, "${files[@]}");

/** A temporary world: a fake gh on PATH, RUNNER_TEMP, and helpers to add releases and artifacts. */
function world(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "publicar-"));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const fake = path.join(dir, "fake"), bin = path.join(dir, "bin"), temp = path.join(dir, "runner");
  for (const d of [fake, bin, temp, path.join(fake, "releases"), path.join(fake, "artifacts")]) fs.mkdirSync(d, {recursive: true});
  fs.writeFileSync(path.join(bin, "gh"), FAKE_GH, {mode: 0o755});
  fs.writeFileSync(path.join(fake, "log"), "");
  const env = {PATH: `${bin}:${process.env.PATH}`, FAKE: fake, RUNNER_TEMP: temp, GITHUB_RUN_ID: "4242", GITHUB_SHA: "c0ffee",
    GITHUB_REF: "refs/heads/main", GH_TOKEN: "fake", GH_REPO: "carulla94/el-especulador-del-wow", LINEA_SUBIDOR: envValue(PUBLISH, "LINEA_SUBIDOR"),
    AVISO_DESBLOQUEAR: envValue(PUBLISH, "AVISO_DESBLOQUEAR")};
  return {dir, fake, temp, env,
    release(tag, body, assets = {}, {latest = true} = {}) {
      fs.mkdirSync(path.join(fake, "releases", tag, "assets"), {recursive: true});
      fs.writeFileSync(path.join(fake, "releases", tag, "body"), body);
      for (const [name, bytes] of Object.entries(assets)) fs.writeFileSync(path.join(fake, "releases", tag, "assets", name), bytes);
      if (latest) fs.writeFileSync(path.join(fake, "latest"), tag + "\n");
    },
    artifact(name, files) {
      fs.mkdirSync(path.join(fake, "artifacts", name), {recursive: true});
      for (const [file, bytes] of Object.entries(files)) fs.writeFileSync(path.join(fake, "artifacts", name, file), bytes);
    },
    body: tag => fs.readFileSync(path.join(fake, "releases", tag, "body"), "utf8"),
    asset: (tag, name) => fs.readFileSync(path.join(fake, "releases", tag, "assets", name)),
    log: () => fs.readFileSync(path.join(fake, "log"), "utf8").trim().split("\n").filter(Boolean),
    run(script, extra = {}, cwd = dir) {
      const result = spawnSync("bash", ["-c", script], {cwd, env: {...env, ...extra}, encoding: "utf8"});
      return {status: result.status, stdout: result.stdout, stderr: result.stderr};
    }
  };
}
const ZIP_A = Buffer.from("PK subidor 0.6.0"), ZIP_B = Buffer.from("PK subidor 0.6.1");
const notesWith = line => `- Escáner propio de la subasta.\n- Ventas estimadas.\n\n${line}\n\nAntes de extraer el subidor: clic derecho en el zip → Propiedades → «Desbloquear».\n`;

// ---- Contract C9: the version lines --------------------------------------------------------------------------------
/** A copy of the four files the version step reads, with the given versions. */
function addonFiles(dir, {toc = "0.6.0", core = "0.6.0", hist = "0.6.0", cambios, crlf = false}) {
  const folder = path.join(dir, "addon/OroHermandad");
  fs.mkdirSync(folder, {recursive: true});
  const eol = text => crlf ? text.replace(/\n/g, "\r\n") : text;
  fs.writeFileSync(path.join(folder, "OroHermandad.toc"), eol(`## Interface: 16001\n## Title: Oro de Hermandad\n## Version: ${toc}\n\nCore.lua\n`));
  fs.writeFileSync(path.join(folder, "Core.lua"), eol(`local _, Core = ...\nCore.VERSION = "${core}"\nreturn Core\n`));
  fs.writeFileSync(path.join(folder, "History.lua"), eol(`local History = {}\nlocal version = "${hist}"\nreturn History\n`));
  fs.writeFileSync(path.join(folder, "CAMBIOS.md"), eol(cambios ?? "# Cambios de Oro de Hermandad\n\n## 0.6.0 (2026-11-20)\n\n- Escáner propio.\n- Ventas estimadas.\n\n## 0.5.1 (2026-11-18)\n\n- Pescado.\n"));
}

test("C9: the publish workflow reads the addon's real version lines, and CAMBIOS.md has the section of that version", t => {
  if (!bash) return t.skip("needs bash, sha256sum, awk and sort");
  const toc = read("addon/OroHermandad/OroHermandad.toc"), core = read("addon/OroHermandad/Core.lua"), hist = read("addon/OroHermandad/History.lua");
  const version = /^## Version: *(.*)$/m.exec(toc)?.[1].trim();
  assert.equal(version, "0.6.0", "the TOC of this release");
  assert.equal(/^Core\.VERSION = "(.*)"$/m.exec(core.replace(/\r/g, ""))?.[1], version, "Core.VERSION alone on its line");
  assert.equal(/^local version = "(.*)"$/m.exec(hist.replace(/\r/g, ""))?.[1], version, "History.lua alone on its line");
  assert.match(read("addon/OroHermandad/CAMBIOS.md"), /^## 0\.6\.0 \(\d{4}-\d{2}-\d{2}\)$/m);
  // The step itself, on a copy of the real files.
  const w = world(t), folder = path.join(w.dir, "addon/OroHermandad");
  fs.mkdirSync(folder, {recursive: true});
  for (const name of ["OroHermandad.toc", "Core.lua", "History.lua", "CAMBIOS.md"]) fs.copyFileSync(path.join(root, "addon/OroHermandad", name), path.join(folder, name));
  const result = w.run(stepRun(PUBLISH, "comprobar", "Comprobar la versión y sacar sus notas de CAMBIOS.md"), {ETIQUETA: "oro-hermandad-v" + version});
  assert.equal(result.status, 0, result.stderr);
  const notes = fs.readFileSync(path.join(w.dir, ".notas-version.md"), "utf8");
  assert.match(notes, /\S/);
  assert.doesNotMatch(notes, /^## /m, "only the section's own text");
});

test("C9: the version step stops before anything slow when the tag, the TOC, Core, History or CAMBIOS.md disagree", t => {
  if (!bash) return t.skip("needs bash");
  const script = stepRun(PUBLISH, "comprobar", "Comprobar la versión y sacar sus notas de CAMBIOS.md");
  const cases = [
    [{}, "oro-hermandad-v0.6.0", 0, null],
    [{crlf: true}, "oro-hermandad-v0.6.0", 0, null],
    [{}, "oro-hermandad-v0.6.1", 1, "La etiqueta dice 0.6.1 pero el TOC dice «0.6.0»"],
    [{core: "0.5.1"}, "oro-hermandad-v0.6.0", 1, "La etiqueta dice 0.6.0 pero Core.VERSION dice «0.5.1»"],
    [{hist: "0.5.9"}, "oro-hermandad-v0.6.0", 1, "La etiqueta dice 0.6.0 pero History.lua dice «0.5.9»"],
    [{toc: "0.6.1", core: "0.6.1", hist: "0.6.1"}, "oro-hermandad-v0.6.1", 1, "CAMBIOS.md no tiene la sección «## 0.6.1»"],
    [{cambios: "## 0.6.0 (2026-11-20)\n\n   \n## 0.5.1 (2026-11-18)\n\n- Pescado.\n"}, "oro-hermandad-v0.6.0", 1, "La sección «## 0.6.0» de CAMBIOS.md está vacía"],
    [{}, "oro-hermandad-v", 1, "«oro-hermandad-v» no es oro-hermandad-vX.Y.Z"],
    [{}, "oro-hermandad-v0.6.0;ls", 1, "no es oro-hermandad-vX.Y.Z"],
    [{}, "oro-hermandad-v0.6.0 x", 1, "no es oro-hermandad-vX.Y.Z"],
    [{}, "oro-hermandad-v0.6.0\n0.6.0", 1, "no es oro-hermandad-vX.Y.Z"],
    // A test version: the same checks, with its own CAMBIOS.md section.
    [{toc: "0.6.1-beta1", core: "0.6.1-beta1", hist: "0.6.1-beta1", cambios: "## 0.6.1-beta1 (2026-11-21)\n\n- Escáner propio.\n- Ventas estimadas.\n\n## 0.6.0 (2026-11-20)\n\n- Otra.\n"},
      "oro-hermandad-v0.6.1-beta1", 0, null]
  ];
  for (const [files, tag, status, message] of cases) {
    const w = world(t);
    addonFiles(w.dir, files);
    const result = w.run(script, {ETIQUETA: tag});
    assert.equal(result.status === 0 ? 0 : 1, status, `${tag} ${JSON.stringify(files)}: ${result.stderr}`);
    if (message) assert.ok(result.stderr.includes(message), result.stderr);
    else assert.equal(fs.readFileSync(path.join(w.dir, ".notas-version.md"), "utf8").replace(/\r/g, ""), "\n- Escáner propio.\n- Ventas estimadas.\n\n");
  }
});

test("a test version is a prerelease on GitHub and alpha or beta on CurseForge and Wago, never only on one side", t => {
  if (!bash) return t.skip("needs bash");
  const check = stepRun(PUBLISH, "comprobar", "Comprobar la versión y sacar sus notas de CAMBIOS.md");
  const create = stepRun(PUBLISH, "github", "Crear la versión de GitHub con los dos zips");
  // The pinned packager (v2.7.0, release.sh file_type) uploads to CurseForge, and to Wago, as alpha when the tag has
  // «alpha», as beta when it has «beta», and as a normal release otherwise. GitHub: the github job's --prerelease.
  const storeTest = tag => /alpha|beta/.test(tag.toLowerCase());
  const versions = ["0.6.1", "0.6.1.2", "0.6.1-beta1", "0.6.1-alpha2", "0.6.1-beta", "0.6.1-rc1", "0.6.1-prueba1", "0.6.1beta1",
    "0.6.1-Beta1", "0.6.1alpha", "0.6.1-beta1-x", "0.6.1-", "0.6.1.2.3"];
  const accepted = [];
  for (const version of versions) {
    // Every version line agrees (C9), so only the form of the version can stop it.
    const w = world(t), tag = "oro-hermandad-v" + version;
    addonFiles(w.dir, {toc: version, core: version, hist: version, cambios: `## ${version} (2026-11-21)\n\n- Prueba.\n`});
    const checked = w.run(check, {ETIQUETA: tag});
    if (checked.status !== 0) {
      assert.ok(checked.stderr.includes(`«${tag}» no es oro-hermandad-vX.Y.Z (ni X.Y.Z-alphaN o X.Y.Z-betaN, de prueba)`), `${version}: ${checked.stderr}`);
      continue;
    }
    accepted.push(version);
    for (const [dir, file, bytes] of [["addon", "OroHermandad.zip", "PK"], ["addon", "notas-version.md", "\n- Prueba.\n"], ["subidor", "Subidor_Windows.zip", ZIP_A]]) {
      fs.mkdirSync(path.join(w.temp, dir), {recursive: true}); fs.writeFileSync(path.join(w.temp, dir, file), bytes);
    }
    fs.writeFileSync(path.join(w.temp, "linea-subidor.txt"), `Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_A)})\n`);
    const created = w.run(create, {ETIQUETA: tag});
    assert.equal(created.status, 0, created.stderr);
    const calls = w.log().filter(line => line.startsWith("release create"));
    assert.equal(calls.length, 1, version);
    assert.equal(calls[0].endsWith(" --prerelease"), storeTest(tag), `${version}: GitHub and the stores agree on a test version`);
  }
  assert.deepEqual(accepted, ["0.6.1", "0.6.1.2", "0.6.1-beta1", "0.6.1-alpha2", "0.6.1-beta"]);
});

// ---- D15: the uploader line and the fallback to the previous Subidor_Windows.zip -----------------------------------
test("the uploader line of the release notes: both forms are accepted, anything else is not", t => {
  assert.equal(envValue(PUBLISH, "LINEA_SUBIDOR"), NOTES_LINE, "the workflow's grep -E pattern is the spec's");
  const hex = "0123456789abcdef".repeat(4), re = new RegExp(NOTES_LINE);
  const good = [`Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${hex})`, `Subidor para Windows 0.6.1 (sin cambios): Subidor_Windows.zip (SHA-256 ${hex})`,
    `Subidor para Windows 1.0: Subidor_Windows.zip (SHA-256 ${hex})`, `Subidor para Windows 0.6.0.2: Subidor_Windows.zip (SHA-256 ${hex})`];
  const bad = [`Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${hex.toUpperCase()})`, `Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${hex.slice(1)})`,
    `Subidor para Windows 6: Subidor_Windows.zip (SHA-256 ${hex})`, `Subidor para Windows 0.6.0.1.2: Subidor_Windows.zip (SHA-256 ${hex})`,
    `Subidor para Windows 0.6.0 (sin cambio): Subidor_Windows.zip (SHA-256 ${hex})`, `Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${hex}) `,
    `- Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${hex})`, `Subidor para Windows 0.6.0: OroHermandad.zip (SHA-256 ${hex})`,
    `Subidor para Windows v0.6.0: Subidor_Windows.zip (SHA-256 ${hex})`];
  for (const line of good) assert.match(line, re);
  for (const line of bad) assert.doesNotMatch(line, re);
  if (!bash) return;
  // grep -E reads the same pattern the same way.
  const w = world(t);
  const counted = spawnSync("bash", ["-c", 'printf "%s\\n" "${@:1}" | grep -cE "$LINEA_SUBIDOR"', "x", ...good, ...bad], {env: w.env, encoding: "utf8"});
  assert.equal(counted.stdout.trim(), String(good.length));
});

test("the github job runs whenever the addon checks passed, and takes the new uploader only when its build succeeded", () => {
  // !cancelled(), never always(): always() is true even when a person cancels the run, so a cancelled Windows build
  // would still create the release and upload it to CurseForge. A failed or skipped job still lets the next one run.
  assert.doesNotMatch(PUBLISH, /always\(\) &&/);
  assert.equal(ifOf(PUBLISH, "comprobar"), "${{ !inputs.solo_subidor }}");
  assert.equal(ifOf(PUBLISH, "subidor"), "${{ !cancelled() && !inputs.reusar_subidor && (inputs.solo_subidor || needs.comprobar.result == 'success') }}");
  assert.equal(ifOf(PUBLISH, "github"), "${{ !cancelled() && !inputs.solo_subidor && needs.comprobar.result == 'success' }}");
  assert.equal(ifOf(PUBLISH, "subidor-suelto"), "${{ !cancelled() && inputs.solo_subidor && needs.subidor.result == 'success' }}");
  for (const job of ["curseforge", "wago"]) assert.equal(ifOf(PUBLISH, job), "${{ !cancelled() && needs.github.result == 'success' }}", job);
  assert.match(jobText(PUBLISH, "github"), /^    needs: \[comprobar, subidor\]$/m);
  assert.match(jobText(PUBLISH, "subidor-suelto"), /^    needs: subidor$/m);
  assert.match(jobText(PUBLISH, "subidor"), /^    uses: \.\/\.github\/workflows\/subidor-windows\.yml$/m);
  const github = jobText(PUBLISH, "github");
  assert.match(github, /- name: Traer el subidor nuevo\n\s+if: \$\{\{ needs\.subidor\.result == 'success' \}\}/);
  assert.match(github, /- name: Reutilizar el subidor de la última versión\n\s+if: \$\{\{ needs\.subidor\.result != 'success' \}\}/);
  assert.match(stepRun(PUBLISH, "github", "Reutilizar el subidor de la última versión"), /gh release download "\$anterior" --pattern Subidor_Windows\.zip/);
});

test("a failed (or skipped) uploader build attaches the previous Subidor_Windows.zip unchanged, checked against its notes", t => {
  if (!bash) return t.skip("needs bash");
  const script = stepRun(PUBLISH, "github", "Reutilizar el subidor de la última versión");
  const ok = world(t);
  ok.release("oro-hermandad-v0.6.0", notesWith(`Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_A)})`), {"OroHermandad.zip": "a", "Subidor_Windows.zip": ZIP_A});
  let result = ok.run(script, {SUBIDOR_RESULTADO: "failure"});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(ok.temp, "linea-subidor.txt"), "utf8"), `Subidor para Windows 0.6.0 (sin cambios): Subidor_Windows.zip (SHA-256 ${sha256(ZIP_A)})\n`);
  assert.ok(fs.readFileSync(path.join(ok.temp, "subidor/Subidor_Windows.zip")).equals(ZIP_A));
  // A previous «(sin cambios)» line is read the same way.
  const again = world(t);
  again.release("oro-hermandad-v0.6.1", notesWith(`Subidor para Windows 0.6.0 (sin cambios): Subidor_Windows.zip (SHA-256 ${sha256(ZIP_A)})`), {"Subidor_Windows.zip": ZIP_A});
  assert.equal(again.run(script, {SUBIDOR_RESULTADO: "skipped"}).status, 0);
  assert.match(fs.readFileSync(path.join(again.temp, "linea-subidor.txt"), "utf8"), /^Subidor para Windows 0\.6\.0 \(sin cambios\): /);
  // Refusals: the asset changed since its notes, no asset, no line (the first 0.6.0 release needs the build), no release.
  const cases = [
    [w => w.release("oro-hermandad-v0.6.0", notesWith(`Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_B)})`), {"Subidor_Windows.zip": ZIP_A}), "no es el de sus notas"],
    [w => w.release("oro-hermandad-v0.6.0", notesWith(`Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_A)})`), {}), "no tiene Subidor_Windows.zip"],
    [w => w.release("oro-hermandad-v0.5.1", "- Pescado.\n", {"OroHermandad.zip": "a"}), "la primera versión necesita compilarlo"],
    [() => {}, "No hay ninguna versión anterior"]
  ];
  for (const [setup, message] of cases) {
    const w = world(t);
    setup(w);
    result = w.run(script, {SUBIDOR_RESULTADO: "failure"});
    assert.notEqual(result.status, 0, message);
    assert.ok(result.stderr.includes(message), result.stderr);
    assert.ok(!fs.existsSync(path.join(w.temp, "linea-subidor.txt")));
  }
});

test("a successful uploader build: its artifact must hold only Subidor_Windows.zip and its version names the line", t => {
  if (!bash) return t.skip("needs bash");
  const script = stepRun(PUBLISH, "github", "Traer el subidor nuevo");
  const w = world(t);
  w.artifact("Subidor_Windows", {"Subidor_Windows.zip": ZIP_B});
  const result = w.run(script, {SUBIDOR_VERSION: "0.6.1"});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(w.temp, "linea-subidor.txt"), "utf8"), `Subidor para Windows 0.6.1: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_B)})\n`);
  for (const [files, version, message] of [[{"Subidor_Windows.zip": ZIP_B, "otro.txt": "x"}, "0.6.1", "solo Subidor_Windows.zip"],
    [{"Subidor_Windows.zip": ZIP_B}, "", "no dio una versión válida"], [{"Subidor_Windows.zip": ZIP_B}, "0.6.1;x", "no dio una versión válida"],
    [{"Subidor_Windows.zip": ZIP_B}, "7", "Línea del subidor no válida"]]) {
    const bad = world(t);
    bad.artifact("Subidor_Windows", files);
    const refused = bad.run(script, {SUBIDOR_VERSION: version});
    assert.notEqual(refused.status, 0, message);
    assert.ok(refused.stderr.includes(message), refused.stderr);
  }
});

test("the release is created once with both zips and the notes: CAMBIOS.md, the uploader line and «Desbloquear»", t => {
  if (!bash) return t.skip("needs bash");
  const fetch = stepRun(PUBLISH, "github", "Traer el zip del addon y sus notas"), create = stepRun(PUBLISH, "github", "Crear la versión de GitHub con los dos zips");
  const w = world(t), addon = Buffer.from("PK addon 0.6.0"), section = "\n- Escáner propio.\n- Ventas estimadas.\n\n";
  w.artifact("OroHermandad", {"OroHermandad.zip": addon, "notas-version.md": section});
  fs.mkdirSync(path.join(w.temp, "subidor"));
  fs.writeFileSync(path.join(w.temp, "subidor/Subidor_Windows.zip"), ZIP_A);
  const line = `Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_A)})`;
  fs.writeFileSync(path.join(w.temp, "linea-subidor.txt"), line + "\n");
  assert.equal(w.run(fetch).status, 0);
  const result = w.run(create, {ETIQUETA: "oro-hermandad-v0.6.0"});
  assert.equal(result.status, 0, result.stderr);
  const creates = w.log().filter(l => l.startsWith("release create"));
  assert.equal(creates.length, 1, "one gh release create, with both assets");
  assert.match(creates[0], /^release create oro-hermandad-v0\.6\.0 \S+\/addon\/OroHermandad\.zip \S+\/subidor\/Subidor_Windows\.zip --target c0ffee --title Oro de Hermandad 0\.6\.0 --notes-file \S+$/);
  assert.equal(w.body("oro-hermandad-v0.6.0"), `${section}\n${line}\n\nAntes de extraer el subidor: clic derecho en el zip → Propiedades → «Desbloquear».\n`);
  assert.ok(w.asset("oro-hermandad-v0.6.0", "OroHermandad.zip").equals(addon));
  assert.ok(w.asset("oro-hermandad-v0.6.0", "Subidor_Windows.zip").equals(ZIP_A));
  // Run again (re-run, or a release made by hand): both zips replaced with --clobber and only the uploader line changes.
  fs.writeFileSync(path.join(w.temp, "subidor/Subidor_Windows.zip"), ZIP_B);
  const newer = `Subidor para Windows 0.6.0: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_B)})`;
  fs.writeFileSync(path.join(w.temp, "linea-subidor.txt"), newer + "\n");
  assert.equal(w.run(create, {ETIQUETA: "oro-hermandad-v0.6.0"}).status, 0);
  assert.match(w.log().at(-3), /^release upload oro-hermandad-v0\.6\.0 \S+OroHermandad\.zip \S+Subidor_Windows\.zip --clobber$/);
  assert.equal(w.body("oro-hermandad-v0.6.0"), `${section}\n${newer}\n\nAntes de extraer el subidor: clic derecho en el zip → Propiedades → «Desbloquear».\n`);
  // A hand-made release without the line gets it appended.
  const hand = world(t);
  hand.release("oro-hermandad-v0.6.0", "Hecha a mano.\n");
  fs.mkdirSync(path.join(hand.temp, "addon")); fs.mkdirSync(path.join(hand.temp, "subidor"));
  fs.writeFileSync(path.join(hand.temp, "addon/OroHermandad.zip"), addon); fs.writeFileSync(path.join(hand.temp, "addon/notas-version.md"), section);
  fs.writeFileSync(path.join(hand.temp, "subidor/Subidor_Windows.zip"), ZIP_A); fs.writeFileSync(path.join(hand.temp, "linea-subidor.txt"), line + "\n");
  assert.equal(hand.run(create, {ETIQUETA: "oro-hermandad-v0.6.0"}).status, 0);
  assert.equal(hand.body("oro-hermandad-v0.6.0"), `Hecha a mano.\n\n${line}\n`);
  // A version with a suffix is a prerelease (it never becomes «latest»).
  const beta = world(t);
  for (const [dir, file, bytes] of [["addon", "OroHermandad.zip", addon], ["addon", "notas-version.md", section], ["subidor", "Subidor_Windows.zip", ZIP_A]]) {
    fs.mkdirSync(path.join(beta.temp, dir), {recursive: true}); fs.writeFileSync(path.join(beta.temp, dir, file), bytes);
  }
  fs.writeFileSync(path.join(beta.temp, "linea-subidor.txt"), line + "\n");
  assert.equal(beta.run(create, {ETIQUETA: "oro-hermandad-v0.6.1-beta1"}).status, 0);
  assert.match(beta.log().at(-1), / --prerelease$/);
});

test("solo_subidor: only a newer uploader replaces Subidor_Windows.zip of the latest release, and only its notes line changes", t => {
  if (!bash) return t.skip("needs bash");
  const script = stepRun(PUBLISH, "subidor-suelto", "Subir el subidor nuevo a la última versión");
  const old = `Subidor para Windows 0.6.9: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_A)})`;
  const w = world(t);
  w.release("oro-hermandad-v0.6.0", notesWith(old), {"OroHermandad.zip": "a", "Subidor_Windows.zip": ZIP_A});
  w.artifact("Subidor_Windows", {"Subidor_Windows.zip": ZIP_B});
  const result = w.run(script, {SUBIDOR_VERSION: "0.6.10"});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(w.body("oro-hermandad-v0.6.0"), notesWith(`Subidor para Windows 0.6.10: Subidor_Windows.zip (SHA-256 ${sha256(ZIP_B)})`), "0.6.10 is newer than 0.6.9");
  assert.ok(w.asset("oro-hermandad-v0.6.0", "Subidor_Windows.zip").equals(ZIP_B));
  assert.ok(w.log().some(l => /^release upload oro-hermandad-v0\.6\.0 \S+Subidor_Windows\.zip --clobber$/.test(l)));
  assert.ok(!w.log().some(l => l.startsWith("release create")));
  for (const [version, message] of [["0.6.9", "no es más nuevo"], ["0.6.2", "no es más nuevo"], ["", "no dio una versión válida"]]) {
    const refused = world(t);
    refused.release("oro-hermandad-v0.6.0", notesWith(old), {"Subidor_Windows.zip": ZIP_A});
    refused.artifact("Subidor_Windows", {"Subidor_Windows.zip": ZIP_B});
    const r = refused.run(script, {SUBIDOR_VERSION: version});
    assert.notEqual(r.status, 0, version);
    assert.ok(r.stderr.includes(message), r.stderr);
    assert.equal(refused.body("oro-hermandad-v0.6.0"), notesWith(old), "nothing changed");
    assert.ok(!refused.log().some(l => l.startsWith("release upload") || l.startsWith("release edit")));
  }
  const branch = world(t);
  branch.release("oro-hermandad-v0.6.0", notesWith(old), {"Subidor_Windows.zip": ZIP_A});
  branch.artifact("Subidor_Windows", {"Subidor_Windows.zip": ZIP_B});
  const fromBranch = branch.run(script, {SUBIDOR_VERSION: "0.6.10", GITHUB_REF: "refs/heads/mejora/subidor"});
  assert.notEqual(fromBranch.status, 0);
  assert.ok(fromBranch.stderr.includes("Lanza «solo_subidor» desde main"), fromBranch.stderr);
  assert.equal(branch.log().length, 0, "nothing asked of GitHub");
  const noLine = world(t);
  noLine.release("oro-hermandad-v0.5.1", "- Pescado.\n");
  noLine.artifact("Subidor_Windows", {"Subidor_Windows.zip": ZIP_B});
  assert.ok(noLine.run(script, {SUBIDOR_VERSION: "0.6.1"}).stderr.includes("no tienen la línea del subidor"));
});

// ---- Triggers, inputs, permissions, tokens and the packager -------------------------------------------------------
test("the publish workflow only runs when a person asks: a pushed oro-hermandad-v* tag or Run workflow, with its three inputs", () => {
  const on = PUBLISH.slice(PUBLISH.indexOf("\non:\n"), PUBLISH.indexOf("\npermissions:"));
  assert.deepEqual([...on.matchAll(/^  ([a-z_]+):/gm)].map(m => m[1]), ["push", "workflow_dispatch"]);
  assert.match(on, /^  push:\n    tags:\n      - 'oro-hermandad-v\*'\n  workflow_dispatch:/m);
  assert.doesNotMatch(on, /branches|schedule|pull_request|release:|workflow_run|repository_dispatch/);
  assert.deepEqual([...on.matchAll(/^      ([a-z_]+):$/gm)].map(m => m[1]), ["version", "reusar_subidor", "solo_subidor"]);
  for (const input of ["reusar_subidor", "solo_subidor"]) {
    assert.match(on, new RegExp(`      ${input}:\\n        description: '[^']+'\\n        required: false\\n        type: boolean\\n        default: false`));
  }
  assert.match(PUBLISH, /^permissions: \{\}$/m, "no token permission by default");
  assert.match(PUBLISH, /^concurrency:\n  group: publicar-oro-hermandad\n  cancel-in-progress: false$/m);
});

test("no GitHub token ever reaches the packager; gh gets one only in the jobs that publish", () => {
  for (const yaml of [PUBLISH, CHECK]) {
    const uses = [...yaml.matchAll(/uses: (BigWigsMods\/packager\S*.*)$/gm)].map(m => m[1]);
    assert.ok(uses.length > 0);
    for (const use of uses) assert.equal(use, PACKAGER, "pinned to the v2.7.0 commit");
    assert.doesNotMatch(yaml, /GITHUB_OAUTH|GH_API_TOKEN|GITHUB_API_TOKEN|secrets\.GITHUB_TOKEN/);
  }
  assert.equal([...PUBLISH.matchAll(/uses: BigWigsMods\/packager/g)].length, 3);
  // Each packager step: only the store key of its job, if any.
  const steps = PUBLISH.split(/\n      - name: /).filter(step => step.includes("BigWigsMods/packager"));
  const keys = steps.map(step => [...step.matchAll(/^          ([A-Z_]+): \$\{\{/gm)].map(m => m[1]));
  assert.deepEqual(keys, [[], ["CF_API_TOKEN"], ["WAGO_API_TOKEN"]]);
  assert.match(steps[0], /args: -d \$\{\{ env\.EMPAQUETADOR_OPCIONES \}\}/, "the check run uploads nothing");
  assert.doesNotMatch(jobText(PUBLISH, "comprobar"), /GH_TOKEN|github\.token/);
  // The stores: a read-only token only in the step that looks at earlier runs and attempts, never in another step.
  for (const job of ["curseforge", "wago"]) {
    const steps = jobText(PUBLISH, job).split(/\n      - name: /);
    assert.deepEqual(steps.filter(step => /GH_TOKEN|github\.token/.test(step)).map(step => step.split("\n")[0]), ["¿Ya se subió esta versión?"], job);
    assert.match(jobText(PUBLISH, job), /^    permissions:\n      contents: read\n      actions: read\n    steps:$/m, job);
  }
  for (const job of ["github", "subidor-suelto"]) {
    assert.match(jobText(PUBLISH, job), /^      GH_TOKEN: \$\{\{ github\.token \}\}$/m, job);
    assert.match(jobText(PUBLISH, job), /^    permissions:\n      contents: write\n      actions: read$/m, job);
  }
  for (const job of ["comprobar", "subidor"]) assert.match(jobText(PUBLISH, job), /^    permissions:\n      contents: read$/m, job);
  for (const job of ["curseforge", "wago"]) assert.match(jobText(PUBLISH, job), /^    environment: publicar-addon$/m, job);
  assert.equal(envValue(PUBLISH, "AVISO_DESBLOQUEAR"), "Antes de extraer el subidor: clic derecho en el zip → Propiedades → «Desbloquear».");
});

// A fake `gh api` for the stores' «¿Ya se subió esta versión?» step, in Node (URL and query parsing) with the step's own
// --jq run by jq. $FAKE/api.json holds the runs: {id, head_sha, attempts: [[job, …], …], listed?, broken?}. It only reads:
// any flag but --paginate and --jq (a --method, -f, -F or --input) fails, as does an unknown URL.
const FAKE_API = String.raw`"use strict";
const fs = require("fs"), path = require("path"), {spawnSync} = require("child_process");
const args = process.argv.slice(2), fake = process.env.FAKE;
fs.appendFileSync(path.join(fake, "log"), args.join(" ") + "\n");
const fail = message => { process.stderr.write(message + "\n"); process.exit(1); };
if (args[0] !== "api" || !args[1]) fail("fake gh: only gh api <url>");
let jq = ".";
for (let i = 2; i < args.length; i++) {
  if (args[i] === "--jq") jq = args[++i];
  else if (args[i] !== "--paginate") fail("fake gh: " + args[i]);
}
const url = new URL(args[1], "https://api.github.com/"), base = "/repos/carulla94/el-especulador-del-wow/actions/";
const rest = url.pathname.startsWith(base) ? url.pathname.slice(base.length) : "";
const runs = JSON.parse(fs.readFileSync(path.join(fake, "api.json"), "utf8")).runs;
const find = id => runs.find(run => String(run.id) === id && !run.broken) || fail("HTTP 502: Bad Gateway");
let body, m;
if (rest === "workflows/publicar-oro-hermandad.yml/runs") {
  // The latest attempt of each run of this workflow (on one commit with head_sha).
  const sha = url.searchParams.get("head_sha");
  const list = runs.filter(run => run.listed !== false && (sha === null || run.head_sha === sha));
  body = {total_count: list.length, workflow_runs: list.map(run => ({id: run.id, head_sha: run.head_sha, run_attempt: run.attempts.length}))};
} else if ((m = /^runs\/(\d+)\/jobs$/.exec(rest))) {
  // filter=all: the jobs of every attempt; otherwise (latest) only those of the last one.
  const run = find(m[1]), attempts = url.searchParams.get("filter") === "all" ? run.attempts : run.attempts.slice(-1);
  const jobs = attempts.flatMap((list, n) => list.map(job => ({...job, run_id: run.id, run_attempt: n + 1})));
  body = {total_count: jobs.length, jobs};
} else if ((m = /^runs\/(\d+)\/attempts\/(\d+)\/jobs$/.exec(rest))) {
  const jobs = find(m[1]).attempts[Number(m[2]) - 1] || fail("HTTP 404: Not Found");
  body = {total_count: jobs.length, jobs};
} else fail("HTTP 404: Not Found (" + url.pathname + ")");
const out = spawnSync("jq", ["-r", jq], {input: JSON.stringify(body), encoding: "utf8"});
process.stdout.write(out.stdout || ""); process.stderr.write(out.stderr || "");
process.exit(out.status === null ? 1 : out.status);
`;

test("CurseForge and Wago never get the same version twice: not on «Re-run failed jobs», not on a new run on the same commit", t => {
  const step = "¿Ya se subió esta versión?";
  const stores = ["curseforge", "wago"].map(job => {
    const text = jobText(PUBLISH, job), steps = text.split(/\n      - name: /).slice(1);
    return {job, text, name: /^    name: (.+)$/m.exec(text)[1], steps: steps.map(s => s.split("\n")[0]),
      upload: steps.find(s => s.includes("uses: BigWigsMods/packager@")).split("\n")[0]};
  });
  for (const {job, text, steps} of stores) {
    assert.equal(steps[0], step, `${job}: the first step`);
    assert.ok(text.includes(`- name: ${step}\n        id: antes\n`), job);
    // Every later step, the packager's included, only runs when no earlier run or attempt uploaded.
    const later = text.slice(text.indexOf("- name: Descargar el código")).split(/\n      - name: /);
    assert.equal(later.length, 3, job);
    for (const s of later) assert.match(s, /^        if: steps\.antes\.outputs\.ya != '1'$/m, `${job}: ${s.split("\n")[0]}`);
  }
  if (!bash || spawnSync("bash", ["-c", "command -v jq"]).status !== 0) return t.skip("needs bash and jq");
  const [cf, wago] = stores;
  // The jobs as the API lists them: a finished store job whose upload step ended as `upload`; one that never ran
  // («solo_subidor»); the job running right now (this attempt), with its upload step still to come.
  const done = (store, upload, conclusion = upload === "failure" ? "failure" : "success") => ({name: store.name, status: "completed", conclusion,
    steps: store.steps.map((name, i) => ({name, number: i + 1, status: "completed", conclusion: name === store.upload ? upload : "success"}))});
  const skipped = store => ({name: store.name, status: "completed", conclusion: "skipped", steps: []});
  const running = store => ({name: store.name, status: "in_progress", conclusion: null,
    steps: store.steps.map((name, i) => ({name, number: i + 1, status: i ? "pending" : "in_progress", conclusion: null}))});
  const others = [{name: "Comprobar y empaquetar el addon", status: "completed", conclusion: "success", steps: []},
    {name: "Publicar en GitHub", status: "completed", conclusion: "success", steps: []}];
  // This run (4242 on c0ffee, as world() sets): its earlier attempts, then the one running now.
  const thisRun = (...earlier) => ({id: 4242, head_sha: "c0ffee", attempts: [...earlier, [...others, running(cf), running(wago)]]});
  const both = (a, b) => [...others, a, b];
  const cases = [
    ["the first run of a version", [thisRun()], null, null],
    ["«Re-run failed jobs» after Wago failed", [thisRun(both(done(cf, "success"), done(wago, "failure")))], 4242, null],
    ["a later attempt after one that skipped the upload", [thisRun(both(done(cf, "success"), done(wago, "success")), both(done(cf, "skipped"), done(wago, "skipped")))], 4242, 4242],
    ["a new Run workflow after a run that uploaded both and was re-run", [{id: 100, head_sha: "c0ffee",
      attempts: [both(done(cf, "success"), done(wago, "success")), both(done(cf, "skipped"), done(wago, "skipped"))]}, thisRun()], 100, 100],
    ["the pushed tag after Run workflow (or the other way round)", [{id: 100, head_sha: "c0ffee", attempts: [both(done(cf, "success"), done(wago, "failure"))]},
      {id: 101, head_sha: "c0ffee", attempts: [both(done(cf, "skipped"), done(wago, "success"))]}, thisRun()], 100, 101],
    ["an earlier run on another commit", [{id: 100, head_sha: "beef", attempts: [both(done(cf, "success"), done(wago, "success"))]}, thisRun()], null, null],
    ["an earlier run that stopped before uploading", [{id: 100, head_sha: "c0ffee", attempts: [both(done(cf, "skipped", "failure"), done(wago, "failure"))]}, thisRun()], null, null],
    ["an earlier «solo_subidor» run on the same commit", [{id: 100, head_sha: "c0ffee", attempts: [[skipped(cf), skipped(wago)]]}, thisRun()], null, null],
    ["an earlier attempt of this run that the list of runs does not show yet", [{...thisRun(both(done(cf, "success"), done(wago, "success"))), listed: false}], 4242, 4242]
  ];
  const fakeWorld = runs => {
    const w = world(t);
    fs.writeFileSync(path.join(w.dir, "bin", "gh-api.cjs"), FAKE_API);
    fs.writeFileSync(path.join(w.dir, "bin", "gh"), `#!/usr/bin/env bash\nexec '${process.execPath.replace(/'/g, "'\\''")}' "$(dirname "$0")/gh-api.cjs" "$@"\n`, {mode: 0o755});
    if (runs) fs.writeFileSync(path.join(w.fake, "api.json"), JSON.stringify({runs}));
    fs.writeFileSync(path.join(w.temp, "output"), "");
    return w;
  };
  for (const [what, runs, ...expected] of cases) {
    for (const [i, store] of stores.entries()) {
      const w = fakeWorld(runs), attempt = runs.find(run => run.id === 4242).attempts.length;
      const result = w.run(stepRun(PUBLISH, store.job, step), {GITHUB_RUN_ATTEMPT: String(attempt), GITHUB_OUTPUT: path.join(w.temp, "output")});
      assert.equal(result.status, 0, `${what}, ${store.job}: ${result.stderr}`);
      assert.equal(fs.readFileSync(path.join(w.temp, "output"), "utf8"), expected[i] ? "ya=1\n" : "", `${what}, ${store.job}`);
      const shop = store.job === "curseforge" ? "CurseForge" : "Wago";
      if (expected[i]) assert.match(result.stdout, new RegExp(`^::notice::Esta versión ya se subió a ${shop} en la ejecución ${expected[i]} de este flujo: no se sube otra vez\\.$`, "m"));
      else assert.doesNotMatch(result.stdout, /::notice::/);
      for (const call of w.log()) assert.match(call, /^api repos\/carulla94\/el-especulador-del-wow\/actions\/\S+ --paginate --jq .+$/, "only reads");
    }
  }
  // If GitHub does not answer (the list of runs, or the jobs of one run), the step fails: better no upload than two.
  for (const runs of [null, [{id: 100, head_sha: "c0ffee", attempts: [both(done(cf, "failure"), done(wago, "failure"))], broken: true}, thisRun()]]) {
    for (const store of stores) {
      const w = fakeWorld(runs);
      const result = w.run(stepRun(PUBLISH, store.job, step), {GITHUB_RUN_ATTEMPT: "1", GITHUB_OUTPUT: path.join(w.temp, "output")});
      assert.notEqual(result.status, 0, `${store.job}: ${runs ? "jobs" : "runs"}`);
      assert.equal(fs.readFileSync(path.join(w.temp, "output"), "utf8"), "");
    }
  }
});

test("C10: the reusable uploader workflow has no required input, outputs version and an artifact with Subidor_Windows.zip", () => {
  const app = read(".github/workflows/subidor-windows.yml");
  const call = app.slice(app.indexOf("  workflow_call:"), app.indexOf("\npermissions:"));
  assert.match(call, /^  workflow_call:\n    outputs:\n      version:\n/m);
  assert.doesNotMatch(call, /inputs:|required: true/);
  assert.match(app, /name: Subidor_Windows\n\s+path: \$\{\{ runner\.temp \}\}\/Subidor_Windows\.zip/);
  assert.doesNotMatch(app, /gh release|softprops|action-gh-release/, "it never publishes");
});

/** The `paths` filter of one event of a workflow, in order. */
function pathFilters(yaml, event) {
  const lines = yaml.split("\n"), start = lines.indexOf(`  ${event}:`);
  assert.ok(start > 0, event);
  let end = start + 1;
  while (end < lines.length && !/^  [a-z_]+:/.test(lines[end]) && !/^\S/.test(lines[end])) end++;
  const block = lines.slice(start + 1, end).filter(line => line.trim() && !/^\s*#/.test(line));
  assert.equal(block[0], "    paths:", `${event}: paths`);
  return block.slice(1).map(line => /^      - '([^']+)'$/.exec(line)?.[1] ?? assert.fail(`${event}: ${line}`));
}
/** Whether a change to these files runs the workflow. GitHub: the last pattern that matches a file decides (a «!»
 * pattern leaves it out), and the workflow runs when at least one file is in; `*` stops at «/», `**` does not. */
function runsOn(filters, files) {
  const regex = glob => new RegExp("^" + glob.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*\*|\*/g, star => star === "**" ? ".*" : "[^/]*") + "$");
  return files.some(file => filters.reduce((inside, filter) => {
    const out = filter.startsWith("!");
    return regex(out ? filter.slice(1) : filter).test(file) ? !out : inside;
  }, false));
}

test("every addon change, and every pull request that could break a release, runs the release tests and the packager", () => {
  const push = pathFilters(CHECK, "push"), pr = pathFilters(CHECK, "pull_request");
  for (const filter of [...push, ...pr]) assert.match(filter, /^!?[A-Za-z0-9._/*-]+$/, `${filter}: only * and ** (what runsOn reads)`);
  // A pull request: every file the release tests read, and anything new at the root or in a new folder, so that a
  // missing .pkgmeta entry fails there and not in deploy-cloudflare.yml (npm test) after the merge.
  const release = ["LICENSE", "LICENSE.md", "tsconfig.json", "docs/guia.md", "addon/Otro/Otro.toc", "addon/OroHermandad/Core.lua",
    "addon/OroHermandad/CAMBIOS.md", ".pkgmeta", ".gitignore", "README.md", "CONTRIBUTING.md", "package.json", ".github/workflows/publicar-oro-hermandad.yml",
    ".github/workflows/oro-hermandad.yml", ".github/workflows/subidor-windows.yml", "test/release-workflow.test.mjs", "scripts/build-oro-hermandad.mjs",
    "test-lua/test_scanner.lua", "test-vectors/especular-v1.json"];
  for (const file of release) assert.ok(runsOn(pr, [file]), `pull_request: ${file}`);
  // Not one that only touches the web, the uploader or their tests...
  const web = ["src/worker.mjs", "public/hermandad.js", "pages/app.mjs", "test/guild.test.mjs", "test/fixtures/v06/points-v2.json",
    "pc_sync/hermandad.py", "test-browser/pages.spec.mjs", "scripts/build-pages.mjs"];
  for (const file of web) assert.ok(!runsOn(pr, [file]), `pull_request: ${file}`);
  assert.ok(!runsOn(pr, web));
  assert.ok(runsOn(pr, [...web, "tsconfig.json"]));
  // ...whose folders are all in the ignore list of .pkgmeta, so a change inside them cannot reach the CurseForge zip.
  const ignore = read(".pkgmeta").slice(read(".pkgmeta").indexOf("\nignore:"));
  for (const filter of pr.filter(f => f.startsWith("!"))) assert.match(ignore, new RegExp(`^  - ${filter.slice(1, -3)}$`, "m"), filter);
  // A push: every addon change, as before.
  for (const file of ["addon/OroHermandad/Core.lua", "test-lua/test_scanner.lua", "test-vectors/especular-v1.json", "scripts/build-oro-hermandad.mjs",
    ".pkgmeta", ".github/workflows/oro-hermandad.yml"]) assert.ok(runsOn(push, [file]), `push: ${file}`);
  assert.ok(!runsOn(push, ["src/worker.mjs"]));
  assert.match(jobText(CHECK, "lua"), /\n      - name: Pruebas de la publicación\n        run: node --test test\/release-workflow\.test\.mjs\n/);
  const order = ["Pruebas del addon", "Preparar Node.js", "Pruebas de la publicación", "Construir el zip del addon", "Notas de prueba para el empaquetador",
    "Empaquetar como en CurseForge, sin subir", "Comprobar que el zip de CurseForge es el mismo"];
  let at = -1;
  for (const name of order) { const next = CHECK.indexOf(`- name: ${name}`); assert.ok(next > at, name); at = next; }
  assert.match(CHECK, /args: -d -u -n "\{package-name\}-\{project-version\}:\{project-version\}"\n\s+pandoc: false/);
  assert.match(stepRun(CHECK, "lua", "Comprobar que el zip de CurseForge es el mismo"), /diff -r "\$RUNNER_TEMP\/esperado" "\$RUNNER_TEMP\/curseforge"/);
  assert.match(stepRun(PUBLISH, "comprobar", "Comprobar que el zip es el addon y nada más"), /node scripts\/build-oro-hermandad\.mjs[\s\S]*diff -r/);
});

// ---- .pkgmeta, the build script and the license ---------------------------------------------------------------------
test(".pkgmeta keeps everything but addon/OroHermandad out of the CurseForge zip, root license files included", () => {
  const pkgmeta = read(".pkgmeta");
  assert.doesNotMatch(pkgmeta, /\t/, "spaces only");
  assert.match(pkgmeta, /^package-as: OroHermandad$/m);
  assert.match(pkgmeta, /^manual-changelog:\n  filename: \.notas-version\.md\n  markup-type: markdown$/m);
  assert.match(pkgmeta, /^move-folders:\n  OroHermandad\/addon\/OroHermandad: OroHermandad$/m);
  assert.match(pkgmeta, /^optional-dependencies:\n  - auctionator$/m);
  const ignore = new Set([...pkgmeta.slice(pkgmeta.indexOf("\nignore:")).matchAll(/^  - (\S+)$/gm)].map(m => m[1]));
  for (const name of ["LICENSE", "LICENSE.md", "LICENSE.txt"]) assert.ok(ignore.has(name), name);
  // What Git would give the packager at the root (tracked or new and not ignored), dot-files aside (it skips them).
  let entries;
  try {
    entries = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard"], {cwd: root, encoding: "utf8"}).split("\n").filter(Boolean);
  } catch {
    entries = fs.readdirSync(root).filter(name => !["node_modules", "dist-pages", "dist-addon"].includes(name));
  }
  const top = new Set(entries.map(file => file.split("/")[0]).filter(name => !name.startsWith(".")));
  for (const name of top) if (name !== "addon") assert.ok(ignore.has(name), `${name} is missing from the ignore list of .pkgmeta`);
  const addons = new Set(entries.filter(file => file.startsWith("addon/")).map(file => file.split("/")[1]));
  for (const name of addons) if (name !== "OroHermandad") assert.ok(ignore.has(`addon/${name}`), `addon/${name}`);
  assert.match(read(".gitignore"), /^\.release\/$/m);
  assert.match(read(".gitignore"), /^\.notas-version\.md$/m);
});

/** Entry names of a zip (central directory), and the text of one entry. */
function zipEntries(bytes) {
  const end = bytes.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  const count = bytes.readUInt16LE(end + 10);
  let at = bytes.readUInt32LE(end + 16);
  const out = new Map();
  for (let i = 0; i < count; i++) {
    const nameLength = bytes.readUInt16LE(at + 28), extra = bytes.readUInt16LE(at + 30), comment = bytes.readUInt16LE(at + 32);
    const local = bytes.readUInt32LE(at + 42), name = bytes.toString("utf8", at + 46, at + 46 + nameLength);
    const size = bytes.readUInt32LE(at + 20), start = local + 30 + bytes.readUInt16LE(local + 26) + bytes.readUInt16LE(local + 28);
    out.set(name, () => inflateRawSync(bytes.subarray(start, start + size)).toString("utf8"));
    at += 46 + nameLength + extra + comment;
  }
  return out;
}

test("the build script zips the TOC, the Lua files it lists, LEEME.md and CAMBIOS.md, and nothing else", t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zip-addon-"));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const out = path.join(dir, "OroHermandad.zip");
  execFileSync(process.execPath, [path.join(root, "scripts/build-oro-hermandad.mjs"), out], {cwd: root, stdio: "pipe"});
  const listed = read("addon/OroHermandad/OroHermandad.toc").split(/\r?\n/).map(line => line.trim()).filter(line => line.endsWith(".lua"));
  assert.ok(listed.length >= 16 && listed.includes("Scanner.lua") && listed.includes("Timing.lua"), "0.6.0 lists Scanner.lua and Timing.lua");
  const entries = zipEntries(fs.readFileSync(out));
  assert.deepEqual([...entries.keys()], ["OroHermandad/OroHermandad.toc", ...listed.map(file => "OroHermandad/" + file), "OroHermandad/LEEME.md", "OroHermandad/CAMBIOS.md"]);
  assert.match(entries.get("OroHermandad/CAMBIOS.md")(), /^## 0\.6\.0 \(/m);
  assert.doesNotMatch(entries.get("OroHermandad/OroHermandad.toc")(), /\r/, "LF line endings, like the packager with -u");
});

// A root LICENSE (CONTRIBUTING «Licencia», MIT) is the owners' choice: the tests only check that .pkgmeta keeps it out of
// the zip (above), never that there is none, so following that procedure does not fail npm test or the deploy.
test("CONTRIBUTING documents the license chosen, how to change it and the release steps; README starts with CurseForge", () => {
  const contributing = read("CONTRIBUTING.md"), readme = read("README.md");
  assert.ok(contributing.includes("\n## Licencia\n"));
  const license = contributing.slice(contributing.indexOf("\n## Licencia\n"));
  assert.match(license, /Todos los derechos reservados/);
  assert.match(license, /All Rights Reserved/);
  assert.match(license, /MIT/);
  assert.match(license, /## X-License: MIT/);
  assert.match(license, /\.pkgmeta/);
  for (const text of ["publicar-addon", "CF_API_TOKEN", "X-Curse-Project-ID", "solo_subidor", "reusar_subidor", "LATEST_UPLOADER", "git init"]) assert.ok(contributing.includes(text), text);
  for (const id of ["C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "C10", "C11"]) assert.match(contributing, new RegExp(`\\| ${id} \\|`), id);
  assert.match(contributing, /28 mensajes/);
  const install = readme.slice(readme.indexOf("**Cómo se une un miembro**"));
  assert.ok(install.indexOf("CurseForge") >= 0 && install.indexOf("CurseForge") < install.indexOf("releases"), "CurseForge first, GitHub zip as the fallback");
  assert.doesNotMatch(install.slice(0, install.indexOf("**Qué se comparte**")), /junto a Auctionator|escaneo completo de Auctionator/);
  assert.match(install, /Auctionator es opcional/);
  for (const text of ["Desbloquear", "Subidor_Windows.zip", "Abrir subidor.cmd", "56.000", "14.000"]) assert.ok(readme.includes(text), text);
});

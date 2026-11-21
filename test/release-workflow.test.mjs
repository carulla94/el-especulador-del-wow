/** Releases of Oro de Hermandad (.github/workflows/publicar-oro-hermandad.yml, .github/workflows/oro-hermandad.yml,
 * .pkgmeta, scripts/build-oro-hermandad.mjs): the version lines the workflow reads (contract C9), the uploader line of
 * the release notes and its fallback to the previous Subidor_Windows.zip (D15), «solo_subidor», the reusable uploader
 * workflow (C10), what may reach the packager and the CurseForge zip. The shell steps are taken from the workflow file
 * itself and run with bash against a fake `gh` that keeps releases and artifacts in a temporary folder: nothing here
 * talks to GitHub, CurseForge or Wago. */
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
    [{}, "oro-hermandad-v0.6.0 x", 1, "no es oro-hermandad-vX.Y.Z"]
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
  // The stores: a read-only token only in the step that looks at earlier attempts of the run, never in another step.
  for (const job of ["curseforge", "wago"]) {
    const steps = jobText(PUBLISH, job).split(/\n      - name: /);
    assert.deepEqual(steps.filter(step => /GH_TOKEN|github\.token/.test(step)).map(step => step.split("\n")[0]), ["¿Ya se subió en un intento anterior?"], job);
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

test("«Re-run failed jobs» after a failed Windows build never uploads the same version to CurseForge or Wago twice", t => {
  for (const [job, name] of [["curseforge", "Subir a CurseForge"], ["wago", "Subir a Wago"]]) {
    const text = jobText(PUBLISH, job), step = "¿Ya se subió en un intento anterior?";
    assert.match(text, new RegExp(`^    name: ${name}$`, "m"));
    assert.ok(text.indexOf(`- name: ${step}\n        id: antes`) > 0 && text.indexOf(`- name: ${step}`) < text.indexOf("- name: Descargar el código"), job);
    // Every later step, the packager's included, only runs when no earlier attempt uploaded.
    const later = text.slice(text.indexOf("- name: Descargar el código")).split(/\n      - name: /);
    assert.equal(later.length, 3, job);
    for (const s of later) assert.match(s, /^        if: steps\.antes\.outputs\.ya != '1'$/m, `${job}: ${s.split("\n")[0]}`);
    assert.match(stepRun(PUBLISH, job, step), new RegExp(`select\\(\\.name == "${name}" and \\.conclusion == "success"\\)`));
  }
  if (!bash || spawnSync("bash", ["-c", "command -v jq"]).status !== 0) return t.skip("needs bash and jq");
  // A fake gh api: the jobs of attempt n of run 4242 in $FAKE/attempts/<n>.json, filtered with the step's --jq.
  const fakeApi = String.raw`#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE/log"
[ "$1" = api ] || exit 2
url="$2"; shift 2; expr=""
while [ $# -gt 0 ]; do case "$1" in --jq) expr="$2"; shift 2 ;; *) shift ;; esac; done
n=$(printf '%s\n' "$url" | sed -nE 's#^repos/carulla94/el-especulador-del-wow/actions/runs/4242/attempts/([0-9]+)/jobs$#\1#p')
[ -n "$n" ] && [ -f "$FAKE/attempts/$n.json" ] || { echo "HTTP 404" >&2; exit 1; }
jq -r "$expr" "$FAKE/attempts/$n.json"
`;
  const jobs = list => JSON.stringify({total_count: list.length, jobs: list.map(([name, conclusion], i) => ({id: 100 + i, name, conclusion}))});
  const attempt1 = [["Comprobar y empaquetar el addon", "success"], ["Subidor para Windows / Compilar y probar en Windows", "failure"],
    ["Publicar en GitHub", "success"], ["Subir a CurseForge", "success"], ["Subir a Wago", "failure"]];
  // Per job: what the step writes to GITHUB_OUTPUT and how many attempts it had to ask about.
  const cases = [
    {attempt: 1, attempts: {}, curseforge: ["", 0], wago: ["", 0]},
    {attempt: 2, attempts: {1: attempt1}, curseforge: ["ya=1", 1], wago: ["", 1]},
    {attempt: 3, attempts: {1: attempt1, 2: [["Subir a CurseForge", "skipped"], ["Subir a Wago", "success"]]}, curseforge: ["ya=1", 1], wago: ["ya=1", 2]},
    {attempt: 2, attempts: {1: [["Subir a CurseForge", "cancelled"], ["Subir a Wago", null]]}, curseforge: ["", 1], wago: ["", 1]},
  ];
  for (const c of cases) {
    for (const job of ["curseforge", "wago"]) {
      const w = world(t);
      fs.writeFileSync(path.join(w.dir, "bin", "gh"), fakeApi, {mode: 0o755});
      fs.mkdirSync(path.join(w.fake, "attempts"));
      for (const [n, list] of Object.entries(c.attempts)) fs.writeFileSync(path.join(w.fake, "attempts", n + ".json"), jobs(list));
      const output = path.join(w.temp, "output");
      fs.writeFileSync(output, "");
      const result = w.run(stepRun(PUBLISH, job, "¿Ya se subió en un intento anterior?"), {GITHUB_RUN_ATTEMPT: String(c.attempt), GITHUB_OUTPUT: output});
      const [out, calls] = c[job];
      assert.equal(result.status, 0, `attempt ${c.attempt}, ${job}: ${result.stderr}`);
      assert.equal(fs.readFileSync(output, "utf8").trim(), out, `attempt ${c.attempt}, ${job}`);
      assert.equal(w.log().length, calls, `attempt ${c.attempt}, ${job}: calls`);
      if (out) assert.match(result.stdout, /^::notice::Esta versión ya se subió a (CurseForge|Wago) en el intento \d de esta ejecución/m);
    }
  }
  // If GitHub does not answer, the step fails: better no upload than a second one.
  const w = world(t);
  fs.writeFileSync(path.join(w.dir, "bin", "gh"), fakeApi, {mode: 0o755});
  fs.writeFileSync(path.join(w.temp, "output"), "");
  assert.notEqual(w.run(stepRun(PUBLISH, "curseforge", "¿Ya se subió en un intento anterior?"), {GITHUB_RUN_ATTEMPT: "2", GITHUB_OUTPUT: path.join(w.temp, "output")}).status, 0);
});

test("C10: the reusable uploader workflow has no required input, outputs version and an artifact with Subidor_Windows.zip", () => {
  const app = read(".github/workflows/subidor-windows.yml");
  const call = app.slice(app.indexOf("  workflow_call:"), app.indexOf("\npermissions:"));
  assert.match(call, /^  workflow_call:\n    outputs:\n      version:\n/m);
  assert.doesNotMatch(call, /inputs:|required: true/);
  assert.match(app, /name: Subidor_Windows\n\s+path: \$\{\{ runner\.temp \}\}\/Subidor_Windows\.zip/);
  assert.doesNotMatch(app, /gh release|softprops|action-gh-release/, "it never publishes");
});

test("every addon change runs the packager without uploading and compares its zip with the build script's", () => {
  for (const event of ["push", "pull_request"]) {
    const block = CHECK.slice(CHECK.indexOf(`  ${event}:`), CHECK.indexOf(event === "push" ? "  pull_request:" : "  workflow_dispatch:"));
    for (const filter of ["addon/OroHermandad/**", "scripts/build-oro-hermandad.mjs", ".pkgmeta", ".github/workflows/oro-hermandad.yml"]) assert.ok(block.includes(`- '${filter}'`), `${event}: ${filter}`);
  }
  const order = ["Construir el zip del addon", "Notas de prueba para el empaquetador", "Empaquetar como en CurseForge, sin subir", "Comprobar que el zip de CurseForge es el mismo"];
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

test("no license file is added; CONTRIBUTING documents the license chosen, how to change it and the release steps; README starts with CurseForge", () => {
  for (const name of ["LICENSE", "LICENSE.md", "LICENSE.txt"]) assert.ok(!fs.existsSync(path.join(root, name)), name);
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

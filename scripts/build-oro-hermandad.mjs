/** Empaqueta el addon Oro de Hermandad en un zip (solo biblioteca estándar de Node).
 * Uso: node scripts/build-oro-hermandad.mjs [ruta-de-salida.zip]  (por defecto dist-addon/OroHermandad.zip, que Git
 * ignora: los ZIP generados no se suben al repositorio). No va en public/: esa carpeta es la de la web y lo que hay
 * en ella se publica al desplegar. El zip sale igual en Windows y en Linux. */
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {deflateRawSync} from "node:zlib";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = path.join(root, "addon/OroHermandad");
const output = process.argv[2] ? path.resolve(process.argv[2]) : path.join(root, "dist-addon/OroHermandad.zip");

const table = Uint32Array.from({length: 256}, (_, value) => {
  for (let i = 0; i < 8; i++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = table[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
function zip(entries) {
  const local = [], central = [];
  let offset = 0;
  for (const [filename, body] of entries) {
    const name = Buffer.from(filename), compressed = deflateRawSync(body, {level: 9}), crc = crc32(body);
    const head = Buffer.alloc(30);
    head.writeUInt32LE(0x04034b50, 0); head.writeUInt16LE(20, 4); head.writeUInt16LE(0x800, 6); head.writeUInt16LE(8, 8);
    head.writeUInt16LE(33, 12); head.writeUInt32LE(crc, 14); head.writeUInt32LE(compressed.length, 18);
    head.writeUInt32LE(body.length, 22); head.writeUInt16LE(name.length, 26);
    local.push(head, name, compressed);
    const dir = Buffer.alloc(46);
    dir.writeUInt32LE(0x02014b50, 0); dir.writeUInt16LE(20, 4); dir.writeUInt16LE(20, 6); dir.writeUInt16LE(0x800, 8);
    dir.writeUInt16LE(8, 10); dir.writeUInt16LE(33, 14); dir.writeUInt32LE(crc, 16); dir.writeUInt32LE(compressed.length, 20);
    dir.writeUInt32LE(body.length, 24); dir.writeUInt16LE(name.length, 28); dir.writeUInt32LE(offset, 42);
    central.push(dir, name);
    offset += head.length + name.length + compressed.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}

const toc = fs.readFileSync(path.join(source, "OroHermandad.toc"), "utf8");
const listed = toc.split(/\r?\n/).map(line => line.trim()).filter(line => line.endsWith(".lua"));
for (const file of listed) {
  if (!fs.existsSync(path.join(source, file))) throw new Error(`El TOC lista ${file}, que no existe.`);
}
const files = ["OroHermandad.toc", ...listed, "LEEME.md"];
// Texto con saltos LF y sin BOM: un checkout de Windows (core.autocrlf) o un editor no cambian el zip.
const text = body => Buffer.from(body.toString("utf8").replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n"), "utf8");
const entries = files.map(file => {
  const body = fs.readFileSync(path.join(source, file));
  return [`OroHermandad/${file}`, /\.(lua|toc|md)$/i.test(file) ? text(body) : body];
});
fs.mkdirSync(path.dirname(output), {recursive: true});
fs.writeFileSync(output, zip(entries));
console.log(`${path.relative(root, output)}: ${entries.length} archivos.`);

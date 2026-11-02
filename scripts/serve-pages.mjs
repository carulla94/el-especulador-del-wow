/** Loopback-only static server for the GitHub Pages browser checks. */
import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../dist-pages");
const base = "/el-especulador-del-wow/";
const port = 4173;
const types = {".html":"text/html; charset=utf-8", ".js":"text/javascript; charset=utf-8",
  ".mjs":"text/javascript; charset=utf-8", ".css":"text/css; charset=utf-8",
  ".svg":"image/svg+xml", ".zip":"application/zip"};
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://127.0.0.1:${port}`);
    if (request.method !== "GET" && request.method !== "HEAD") { response.writeHead(405).end(); return; }
    if (url.pathname === "/") { response.writeHead(302, {Location:base}).end(); return; }
    if (!url.pathname.startsWith(base)) { response.writeHead(404).end(); return; }
    const relative = decodeURIComponent(url.pathname.slice(base.length)) || "index.html";
    const filename = path.resolve(root, relative);
    const within = path.relative(root, filename);
    if (within.startsWith("..") || path.isAbsolute(within)) { response.writeHead(403).end(); return; }
    const data = await fs.readFile(filename);
    response.writeHead(200, {"Content-Type":types[path.extname(filename)] || "application/octet-stream", "Cache-Control":"no-store"});
    response.end(request.method === "HEAD" ? undefined : data);
  } catch { response.writeHead(404).end(); }
});
server.listen(port, "127.0.0.1", () => console.log(`Pages test server: http://127.0.0.1:${port}${base}`));
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => server.close(() => process.exit(0)));

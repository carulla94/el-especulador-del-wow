/** Local QA adapter. This is not the deployment runtime and contains no production credentials. */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {Readable} from "node:stream";
import {DatabaseSync} from "node:sqlite";
import worker,{Portfolio} from "../src/worker.mjs";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const db=new DatabaseSync(":memory:");
const ctx={storage:{sql:{exec(sql,...args){const statement=db.prepare(sql);const rows=statement.columns().length?statement.all(...args):(statement.run(...args),[]);return {toArray:()=>rows,[Symbol.iterator]:()=>rows[Symbol.iterator]()};}},transactionSync(callback){db.exec("BEGIN IMMEDIATE");try{const result=callback();if(result instanceof Promise)throw new Error("async transaction");db.exec("COMMIT");return result;}catch(error){db.exec("ROLLBACK");throw error;}}}};
const types={".html":"text/html; charset=utf-8",".css":"text/css; charset=utf-8",".js":"text/javascript; charset=utf-8",".svg":"image/svg+xml",".zip":"application/zip"};
const env={OWNER_PASSWORD:process.env.ESPECULADOR_PREVIEW_PASSWORD||"vista-previa-privada-sin-datos",ASSETS:{async fetch(request){const relative=new URL(request.url).pathname;const filename=path.resolve(root,"public","."+relative);if(!filename.startsWith(path.join(root,"public")+path.sep)||!fs.existsSync(filename)||!fs.statSync(filename).isFile())return new Response("No encontrado",{status:404});return new Response(fs.readFileSync(filename),{headers:{"Content-Type":types[path.extname(filename)]||"application/octet-stream"}});}}};
const object=new Portfolio(ctx,env);env.PORTFOLIO={idFromName:name=>name,get:()=>({fetch:request=>object.fetch(request)})};
const server=http.createServer(async(incoming,outgoing)=>{try{
  const request=new Request("http://localhost:8787"+incoming.url,{method:incoming.method,headers:incoming.headers,...(!["GET","HEAD"].includes(incoming.method)?{body:Readable.toWeb(incoming),duplex:"half"}:{})});
  const response=await worker.fetch(request,env);
  outgoing.writeHead(response.status,Object.fromEntries(response.headers));
  if(response.body)Readable.fromWeb(response.body).pipe(outgoing);else outgoing.end();
}catch{outgoing.writeHead(500);outgoing.end("Error de la vista previa");}});
server.listen(8787,"127.0.0.1",()=>console.log("Vista local de pruebas: http://localhost:8787 · datos temporales"));
process.on("SIGINT",()=>server.close(()=>{db.close();process.exit(0);}));

/** Deterministic bundle for Cloudflare dashboard/Git deploy without build dependencies. */
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const destination=path.join(root,"dashboard-deploy");
fs.mkdirSync(destination,{recursive:true});
const namespaces=new Map([["./engine.mjs","Engine"],["./auctioneer.mjs","Auctioneer"],["./storage.mjs","Storage"]]);
function imports(source) {
  return source.replace(/^import\s+\{([\s\S]*?)\}\s+from\s+["']([^"']+)["'];\s*/gm,(_,names,file)=>{
    if(!namespaces.has(file))throw new Error(`Unexpected import ${file}`);
    return `const {${names}} = ${namespaces.get(file)};\n`;
  });
}
let bundle="// El Especulador del WoW. Generated from reviewed source; no secrets.\n";
for(const [file,namespace] of namespaces){
  let source=fs.readFileSync(path.join(root,"src",file.slice(2)),"utf8");
  const names=[...source.matchAll(/^export\s+(?:async\s+)?(?:function|class|const|let)\s+(\w+)/gm)].map(m=>m[1]);
  source=imports(source).replace(/^export\s+/gm,"");
  bundle+=`const ${namespace}=(()=>{\n${source}\nreturn {${names.join(",")}};\n})();\n`;
}
const types={".html":"text/html; charset=utf-8",".css":"text/css; charset=utf-8",".js":"text/javascript; charset=utf-8",".svg":"image/svg+xml",".zip":"application/zip"};
const assets={};
function include(directory,relative=""){
  for(const entry of fs.readdirSync(directory,{withFileTypes:true})){
    const next=path.join(directory,entry.name), key=relative+"/"+entry.name;
    if(entry.isDirectory())include(next,key);
    else assets[key]={type:types[path.extname(entry.name)]||"application/octet-stream",body:fs.readFileSync(next).toString("base64")};
  }
}
include(path.join(root,"public"));
bundle+=`const EmbeddedAssetMap=${JSON.stringify(assets)};\nconst EmbeddedAssets={async fetch(request){const value=EmbeddedAssetMap[new URL(request.url).pathname];if(!value)return new Response('No encontrado',{status:404});const bytes=Uint8Array.from(atob(value.body),c=>c.charCodeAt(0));return new Response(bytes,{headers:{'Content-Type':value.type}})}};\n`;
let worker=imports(fs.readFileSync(path.join(root,"src/worker.mjs"),"utf8"));
worker=worker.replace("async fetch(request, env) {", "async fetch(request, env) { env={...env,ASSETS:env.ASSETS||EmbeddedAssets};");
worker=worker.replace(/^export (async function|function) /gm,"$1 ");
bundle+=worker;
const config=JSON.parse(fs.readFileSync(path.join(root,"wrangler.jsonc"),"utf8"));
delete config.assets; delete config.$schema;
config.main="worker.mjs";
fs.writeFileSync(path.join(destination,"worker.mjs"),bundle);
fs.writeFileSync(path.join(destination,"wrangler.jsonc"),JSON.stringify(config,null,2)+"\n");
fs.writeFileSync(path.join(destination,"package.json"),JSON.stringify({name:"el-especulador-del-wow",version:"0.3.0",private:true,type:"module",scripts:{deploy:"wrangler deploy"},devDependencies:{wrangler:"^4.102.0"}},null,2)+"\n");
console.log(JSON.stringify({file:path.join(destination,"worker.mjs"),bytes:Buffer.byteLength(bundle),assets:Object.keys(assets).length}));

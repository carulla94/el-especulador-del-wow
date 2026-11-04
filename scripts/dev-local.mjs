/** Local QA adapter. This is not the deployment runtime and contains no production credentials.
 *   node scripts/dev-local.mjs                    empty, like a new install
 *   node scripts/dev-local.mjs --demo             thirty days of invented prices with deals, clock past the launch guard
 *   node scripts/dev-local.mjs --demo=lanzamiento the launch day: one day of invented prices, nothing to compare yet
 * All the data is invented and lives in memory; it disappears when the server stops. */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {Readable} from "node:stream";
import {DatabaseSync} from "node:sqlite";
import worker,{Portfolio,GuildMarket} from "../src/worker.mjs";
import {WATCHLIST} from "../src/guild.mjs";
import {DAY0,LAUNCH} from "../src/especular.mjs";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const ORIGIN="http://localhost:8787";
const demoArg=process.argv.find(a=>a==="--demo"||a.startsWith("--demo="));
const launchDay=demoArg==="--demo=lanzamiento";
const databases=[];
function context(){
  const db=new DatabaseSync(":memory:");databases.push(db);
  return {storage:{sql:{exec(sql,...args){
    const statement=db.prepare(sql),write=/^\s*(?:INSERT|UPDATE|DELETE|REPLACE)\b/i.test(sql);
    let rows=[],rowsWritten=0;
    if(statement.columns().length){rows=statement.all(...args);if(write)rowsWritten=rows.length;}
    else{const result=statement.run(...args);if(write)rowsWritten=Number(result.changes);}
    return {rowsWritten,toArray:()=>rows,[Symbol.iterator]:()=>rows[Symbol.iterator]()};
  }},transactionSync(callback){db.exec("BEGIN IMMEDIATE");try{const result=callback();if(result instanceof Promise)throw new Error("async transaction");db.exec("COMMIT");return result;}catch(error){db.exec("ROLLBACK");throw error;}}}};
}
const types={".html":"text/html; charset=utf-8",".css":"text/css; charset=utf-8",".js":"text/javascript; charset=utf-8",".svg":"image/svg+xml",".zip":"application/zip"};
const env={OWNER_PASSWORD:process.env.ESPECULADOR_PREVIEW_PASSWORD||"vista-previa-privada-sin-datos",GUILD_WRITE_ROWS_PER_DAY:"1000000",ASSETS:{async fetch(request){const relative=new URL(request.url).pathname;const filename=path.resolve(root,"public","."+relative);if(!filename.startsWith(path.join(root,"public")+path.sep)||!fs.existsSync(filename)||!fs.statSync(filename).isFile())return new Response("No encontrado",{status:404});return new Response(fs.readFileSync(filename),{headers:{"Content-Type":types[path.extname(filename)]||"application/octet-stream"}});}}};
const object=new Portfolio(context(),env);env.PORTFOLIO={idFromName:name=>name,get:()=>({fetch:request=>object.fetch(request)})};
const market=new GuildMarket(context(),env);env.GUILD={idFromName:name=>name,get:()=>({fetch:request=>market.fetch(request)})};

/** The demo's clock: the market lives on its own day, and only the market sees it. */
const DEMO_DAY=launchDay?LAUNCH:2530; // 2530 = 2026-12-05, after the launch guard
if(demoArg){const started=Date.now(),shift=(DAY0+DEMO_DAY*86400+18*3600)*1000-started;market.now=()=>Date.now()+shift;}

const NAMES={2770:"Mena de cobre",2771:"Mena de estaño",2775:"Mena de plata",2772:"Mena de hierro",2776:"Mena de oro",3858:"Mena de mitril",7911:"Mena de veraplata",10620:"Mena de torio",2840:"Barra de cobre",3576:"Barra de estaño",2841:"Barra de bronce",2842:"Barra de plata",3575:"Barra de hierro",3577:"Barra de oro",3859:"Barra de acero",3860:"Barra de mitril",6037:"Barra de veraplata",12359:"Barra de torio",12360:"Barra de arcanita",2589:"Paño de lino",2592:"Paño de lana",4306:"Paño de seda",4338:"Paño de tejido de mago",14047:"Paño rúnico",14256:"Tela vil",14342:"Tela lunar",13463:"Salvia oscura",13464:"Sangre de dragón",13465:"Salvia de montaña",13466:"Lágrima de Sorrow",13467:"Loto negro",2318:"Cuero ligero",2319:"Cuero medio",4234:"Cuero pesado",4304:"Cuero grueso",8170:"Cuero basto",12811:"Orbe justo",13510:"Frasco de titanes",13446:"Poción de sanación superior",13444:"Poción de maná superior",14344:"Fragmento brillante grande",16204:"Esencia ilusoria"};
function rng(seed){return ()=>{seed|=0;seed=seed+0x6D2B79F5|0;let x=Math.imul(seed^seed>>>15,1|seed);x=x+Math.imul(x^x>>>7,61|x)^x;return ((x^x>>>14)>>>0)/4294967296;};}
/** What one invented member saw: a wobbling price per item, with a dip or a spike today on a few items. */
function demoUpload(seed,today,firstDay){
  const items=[];
  for(const [cat,ids] of Object.entries(WATCHLIST))ids.forEach((id,index)=>{
    const base=rng(id*7919),market=500+Math.floor(base()*base()*40000),own=rng(id*31+seed);
    const trend=index%5===0?0.92:index%5===1?1.05:1,days=[];
    for(let d=firstDay;d<=today;d++){
      const shock=d===today&&firstDay<today?(index%7===2?0.5:index%7===4?1.7:index%7===5?trend:1):1;
      const lo=Math.max(1,Math.round(market*shock*(0.94+own()*0.12)));
      days.push([d,lo,lo+Math.round(lo*0.3),lo+Math.round(lo*0.1),60+Math.floor(own()*900),2+Math.floor(own()*3),"o"]);
    }
    // The price of today comes from the scans of today, as it does with the addon.
    const last=days.at(-1),points=[[DAY0+today*86400+17*3600+seed*60,last[1],last[4],Math.floor(last[4]/4)]];
    items.push({id,name:NAMES[id]??`Demo ${cat} ${id}`,cat,vendor:Math.floor(market/6),days,points});
  });
  return {schema:1,addon:"0.4.0",markets:[{market:"Grito de Guerra-Alliance",cut:500,items,deposits:[]}]};
}
/** The Worker with the session of a member of the demo; nothing here leaves this process. */
async function call(pathname,{method="GET",data,cookie,csrf,token}={}){
  const headers=new Headers({Origin:ORIGIN});
  if(data!==undefined)headers.set("Content-Type","application/json");
  if(cookie)headers.set("Cookie",cookie);if(csrf)headers.set("X-CSRF-Token",csrf);if(token)headers.set("Authorization","Bearer "+token);
  const response=await worker.fetch(new Request(ORIGIN+pathname,{method,headers,...(data!==undefined?{body:JSON.stringify(data)}:{})}),env);
  if(!response.ok)throw new Error(`${method} ${pathname}: ${response.status} ${await response.text()}`);
  return response;
}
async function seed(){
  const login=await call("/api/login",{method:"POST",data:{password:env.OWNER_PASSWORD}});
  const cookie=login.headers.get("Set-Cookie").split(";")[0];
  const guildCsrf=(await (await call("/api/guild/me",{cookie})).json()).csrf,keys=[];
  for(const label of ["Ana","Bruno"]){
    const {member}=await (await call("/api/guild/members",{method:"POST",data:{label,role:"member"},cookie,csrf:guildCsrf})).json();
    const {key}=await (await call("/api/guild/keys",{method:"POST",data:{memberId:member.id},cookie,csrf:guildCsrf})).json();
    keys.push(key);
  }
  const first=launchDay?DEMO_DAY:DEMO_DAY-29;
  for(const [index,key] of keys.entries())await call("/api/guild/sync",{method:"POST",data:demoUpload(index+1,DEMO_DAY,first),token:key});
  if(!launchDay){
    const state=await (await call("/api/state",{cookie})).json();
    await call("/api/settings",{method:"POST",data:{capitalCopper:50000000},cookie,csrf:state.token});
    const buy=(itemId,name,quantity,unitCopper)=>call("/api/transactions",{method:"POST",cookie,csrf:state.token,data:{kind:"buy",itemId,itemKey:String(itemId),name,quantity,unitCopper,feeCopper:0,depositLossCopper:0,note:""}});
    await buy(2589,NAMES[2589],40,300);await buy(2772,NAMES[2772],20,900);await buy(13467,NAMES[13467],5,8000);
    // Whatever the invented prices came out as, one item is held at a loss and one at a price today calls expensive.
    const summary=await (await call("/api/guild/market?market="+encodeURIComponent("Grito de Guerra-Alliance"),{cookie})).json();
    const caro=summary.items.find(e=>e.verdict==="CARO"&&Number.isInteger(e.price?.lo));
    if(caro)await buy(caro.id,caro.name,10,Math.round(caro.price.lo*0.7));
  }
  console.log(`Datos de ejemplo ${launchDay?"del día de lanzamiento":"con 30 días de precios"}. Clave de miembro de pruebas: ${keys[0]}`);
}

const server=http.createServer(async(incoming,outgoing)=>{try{
  const request=new Request(ORIGIN+incoming.url,{method:incoming.method,headers:incoming.headers,...(!["GET","HEAD"].includes(incoming.method)?{body:Readable.toWeb(incoming),duplex:"half"}:{})});
  const response=await worker.fetch(request,env);
  outgoing.writeHead(response.status,Object.fromEntries(response.headers));
  if(response.body)Readable.fromWeb(response.body).pipe(outgoing);else outgoing.end();
}catch{outgoing.writeHead(500);outgoing.end("Error de la vista previa");}});
if(demoArg)await seed();
server.listen(8787,"127.0.0.1",()=>console.log(`Vista local de pruebas: ${ORIGIN} · datos temporales`));
process.on("SIGINT",()=>server.close(()=>{for(const db of databases)db.close();process.exit(0);}));

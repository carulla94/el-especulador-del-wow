/** Local QA adapter. This is not the deployment runtime and contains no production credentials.
 *   node scripts/dev-local.mjs                    empty, like a new install
 *   node scripts/dev-local.mjs --demo             thirty days of invented prices with deals, clock past the launch guard;
 *                                                 the last 14 days with six scans a day and an invented weekday × hour
 *                                                 pattern (dearer on Sunday evenings, cheaper on Tuesday mornings) for
 *                                                 «Cuándo vender», and fish priced so the Pesca tab has something to say
 *   node scripts/dev-local.mjs --demo=lanzamiento the launch day: one day of invented prices, nothing to compare yet
 *   add --codigo=1234                             the panel's 4-digit access code (GUILD_VIEW_PIN), for the code screen
 * All the data is invented and lives in memory; it disappears when the server stops. */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {Readable} from "node:stream";
import {DatabaseSync} from "node:sqlite";
import worker,{Portfolio,GuildMarket} from "../src/worker.mjs";
import {WATCHLIST} from "../src/guild.mjs";
import {DAY0,LAUNCH,weekdayOf} from "../src/especular.mjs";
import {FISH_VENDOR} from "../public/hermandad.js";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const ORIGIN="http://localhost:8787";
const demoArg=process.argv.find(a=>a==="--demo"||a.startsWith("--demo="));
const launchDay=demoArg==="--demo=lanzamiento";
const codeArg=process.argv.find(a=>a.startsWith("--codigo="))?.slice("--codigo=".length);
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
const env={OWNER_PASSWORD:process.env.ESPECULADOR_PREVIEW_PASSWORD||"vista-previa-privada-sin-datos",GUILD_WRITE_ROWS_PER_DAY:"1000000",...(codeArg?{GUILD_VIEW_PIN:codeArg}:{}),ASSETS:{async fetch(request){const relative=new URL(request.url).pathname;const filename=path.resolve(root,"public","."+relative);if(!filename.startsWith(path.join(root,"public")+path.sep)||!fs.existsSync(filename)||!fs.statSync(filename).isFile())return new Response("No encontrado",{status:404});return new Response(fs.readFileSync(filename),{headers:{"Content-Type":types[path.extname(filename)]||"application/octet-stream"}});}}};
const object=new Portfolio(context(),env);env.PORTFOLIO={idFromName:name=>name,get:()=>({fetch:request=>object.fetch(request)})};
const market=new GuildMarket(context(),env);env.GUILD={idFromName:name=>name,get:()=>({fetch:request=>market.fetch(request)})};

/** The demo's clock: the market lives on its own day, and only the market sees it. */
const DEMO_DAY=launchDay?LAUNCH:2530; // 2530 = 2026-12-05, after the launch guard
if(demoArg){const started=Date.now(),shift=(DAY0+DEMO_DAY*86400+18*3600)*1000-started;market.now=()=>Date.now()+shift;}

const NAMES={2770:"Mena de cobre",2771:"Mena de estaño",2775:"Mena de plata",2772:"Mena de hierro",2776:"Mena de oro",3858:"Mena de mitril",7911:"Mena de veraplata",10620:"Mena de torio",2840:"Barra de cobre",3576:"Barra de estaño",2841:"Barra de bronce",2842:"Barra de plata",3575:"Barra de hierro",3577:"Barra de oro",3859:"Barra de acero",3860:"Barra de mitril",6037:"Barra de veraplata",12359:"Barra de torio",12360:"Barra de arcanita",2589:"Paño de lino",2592:"Paño de lana",4306:"Paño de seda",4338:"Paño de tejido de mago",14047:"Paño rúnico",14256:"Tela vil",14342:"Tela lunar",13463:"Salvia oscura",13464:"Sangre de dragón",13465:"Salvia de montaña",13466:"Lágrima de Sorrow",13467:"Loto negro",2318:"Cuero ligero",2319:"Cuero medio",4234:"Cuero pesado",4304:"Cuero grueso",8170:"Cuero basto",12811:"Orbe justo",13510:"Frasco de titanes",13446:"Poción de sanación superior",13444:"Poción de maná superior",14344:"Fragmento brillante grande",16204:"Esencia ilusoria"};
/** Fishing (addon 0.5.0): Spanish names and invented prices in copper, raw fish cheap and what is made from them dearer. */
const FISH_NAMES={6291:"Pececito luminoso crudo",6303:"Caballa suave cruda",6289:"Pargo de loco boquilargo crudo",6317:"Frenesí del lago crudo",6361:"Atún blanco arco iris crudo",6308:"Siluro mostacherizo crudo",21071:"Sabiola cruda",6522:"Pez descarriado",6358:"Bocanegra graso",6359:"Pargo de Fuego",6362:"Bacalao Piedrescama crudo",8365:"Trucha cabeza de mitril cruda",21153:"Sabiola cruda superior",4603:"Serviola moteada cruda",13754:"Vigorpez lustroso crudo",13758:"Branquirrojo crudo",13756:"Lubina cruda",13755:"Calamar de invierno",13759:"Pargo nocturno crudo",13760:"Salmón escama de sol crudo",13889:"Salmón escama blanca crudo",13893:"Vigorpez crudo grande",13888:"Langosta pinza oscura",13422:"Anguila Escama Tormentosa",13757:"Anguila relámpago",4592:"Pargo de lodo boquilargo",5095:"Atún blanco arco iris",4593:"Siluro mostacherizo",21072:"Sabiola ahumada",6657:"Delicia desviada sabrosa",4594:"Bacalao Piedrescama",8364:"Trucha de cabeza de mitril",21217:"Delicia de sabiolas",6887:"Serviola moteada",13927:"Vigorpez lustroso cocido",13930:"Filete de branquirrojo",13929:"Lubina ahumada caliente",13932:"Salmón escama de sol pochado",13933:"Estofado de langosta",13934:"Filete de vigorpez",13935:"Salmón al horno",13928:"Calamar a la parrilla",13931:"Sopa de aleta nocturna",6370:"Aceite bocanegra",6371:"Aceite de fuego",13423:"Aceite de Escama Tormentosa",5634:"Poción de acción libre",6373:"Elixir de poder de fuego",21546:"Elixir de gran poder de fuego",13445:"Elixir de defensa superior",3820:"Alga estranguladora",3356:"Sangrerregia",4625:"Flor de fuego",8838:"Solea",2449:"Raíz terrenal"};
const FISH_BASE={6291:4,6303:5,6289:8,6317:12,6361:15,6308:20,21071:250,6522:60,6358:40,6359:80,6362:35,8365:30,21153:900,4603:45,13754:120,13758:60,13756:400,13755:900,13759:350,13760:150,13889:200,13893:300,13888:500,13422:1800,13757:250,4592:30,5095:45,4593:50,21072:600,6657:350,4594:90,8364:60,21217:2200,6887:120,13927:900,13930:150,13929:1400,13932:500,13933:2400,13934:1600,13935:700,13928:2600,13931:1500,6370:180,6371:450,13423:3200,5634:4500,6373:1800,21546:5500,13445:9000,3820:150,3356:250,4625:400,8838:500,2449:30};
/** The invented pattern of «Cuándo vender»: how a scan's lowest price moves with the weekday (Monday 0) and the hour. */
function hourFactor(wd,hour){
  if(wd===6&&hour>=18)return 1.1;
  if(wd===5&&hour>=20)return 1.06;
  if(wd===1&&hour>=6&&hour<12)return 0.93;
  if(hour<4)return 0.97;
  return 1;
}
function rng(seed){return ()=>{seed|=0;seed=seed+0x6D2B79F5|0;let x=Math.imul(seed^seed>>>15,1|seed);x=x+Math.imul(x^x>>>7,61|x)^x;return ((x^x>>>14)>>>0)/4294967296;};}
/** What one invented member saw: a wobbling price per item, with a dip or a spike today on a few items. The last 14 days
 * also have six scans a day (one every four hours, at a random minute), following hourFactor. */
function demoUpload(seed,today,firstDay){
  const items=[];
  for(const [cat,ids] of Object.entries(WATCHLIST))ids.forEach((id,index)=>{
    const base=rng(id*7919),market=FISH_BASE[id]??500+Math.floor(base()*base()*40000),own=rng(id*31+seed);
    const trend=index%5===0?0.92:index%5===1?1.05:1,days=[],points=[];
    for(let d=firstDay;d<=today;d++){
      const shock=d===today&&firstDay<today?(index%7===2?0.5:index%7===4?1.7:index%7===5?trend:1):1;
      const level=market*shock*(0.96+own()*0.08),qty=60+Math.floor(own()*900);
      let lo=Math.max(1,Math.round(level*hourFactor(weekdayOf(d),12)));
      if(!launchDay&&d>today-14){
        // Scans of that day: today only until 17 h, the demo's clock is at 18 h.
        const scans=[];
        for(let block=0;block<6;block++){
          const hour=block*4+Math.floor(own()*4);
          if(d===today&&hour>=17)continue;
          const p=Math.max(1,Math.round(level*hourFactor(weekdayOf(d),hour)*(0.98+own()*0.04))),q=Math.max(1,Math.round(qty*(0.8+own()*0.4)));
          scans.push([DAY0+d*86400+hour*3600+Math.floor(own()*3600),p,q,Math.floor(q/4)]);
        }
        points.push(...scans);
        if(scans.length)lo=Math.min(...scans.map(p=>p[1]));
      }
      days.push([d,lo,lo+Math.round(lo*0.3),lo+Math.round(lo*0.1),qty,2+Math.floor(own()*3),"o"]);
    }
    if(!points.length){const last=days.at(-1);points.push([DAY0+today*86400+17*3600+seed*60,last[1],last[4],Math.floor(last[4]/4)]);}
    const vendor=FISH_VENDOR[id]?.sell??Math.floor(market/6);
    items.push({id,name:FISH_NAMES[id]??NAMES[id]??`Demo ${cat} ${id}`,cat,vendor,days,points});
  });
  return {schema:1,addon:"0.5.0",markets:[{market:"Grito de Guerra-Alliance",cut:500,items,deposits:[]}]};
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
  console.log(`Datos de ejemplo ${launchDay?"del día de lanzamiento":"con 30 días de precios y 14 de escaneos a distintas horas"}. Clave de miembro de pruebas: ${keys[0]}`);
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

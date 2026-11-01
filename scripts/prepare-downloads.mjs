/** Build the two private downloads with Node's standard library only. */
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {deflateRawSync} from "node:zlib";

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const destination=path.join(root,"public/downloads");
fs.mkdirSync(destination,{recursive:true});
const table=Uint32Array.from({length:256},(_,value)=>{for(let i=0;i<8;i++)value=value&1?0xedb88320^(value>>>1):value>>>1;return value>>>0;});
function crc32(buffer){let crc=0xffffffff;for(const byte of buffer)crc=table[(crc^byte)&255]^(crc>>>8);return (crc^0xffffffff)>>>0;}
function zip(entries){
  const local=[],central=[];let offset=0;
  for(const [filename,body] of entries){
    const name=Buffer.from(filename), compressed=deflateRawSync(body), crc=crc32(body);
    const head=Buffer.alloc(30);head.writeUInt32LE(0x04034b50,0);head.writeUInt16LE(20,4);head.writeUInt16LE(0x800,6);head.writeUInt16LE(8,8);head.writeUInt16LE(33,12);head.writeUInt32LE(crc,14);head.writeUInt32LE(compressed.length,18);head.writeUInt32LE(body.length,22);head.writeUInt16LE(name.length,26);
    local.push(head,name,compressed);
    const dir=Buffer.alloc(46);dir.writeUInt32LE(0x02014b50,0);dir.writeUInt16LE(20,4);dir.writeUInt16LE(20,6);dir.writeUInt16LE(0x800,8);dir.writeUInt16LE(8,10);dir.writeUInt16LE(33,14);dir.writeUInt32LE(crc,16);dir.writeUInt32LE(compressed.length,20);dir.writeUInt32LE(body.length,24);dir.writeUInt16LE(name.length,28);dir.writeUInt32LE(offset,42);
    central.push(dir,name);offset+=head.length+name.length+compressed.length;
  }
  const directory=Buffer.concat(central),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50,0);end.writeUInt16LE(entries.length,8);end.writeUInt16LE(entries.length,10);end.writeUInt32LE(directory.length,12);end.writeUInt32LE(offset,16);
  return Buffer.concat([...local,directory,end]);
}
function entry(folder,name,prefix=""){return [prefix+name,fs.readFileSync(path.join(root,folder,name))];}
fs.writeFileSync(path.join(destination,"Sincronizador_PC.zip"),zip(["sincronizar.py","SINCRONIZAR.cmd","LEEME.md"].map(name=>entry("pc_sync",name))));
const addonFiles=fs.readdirSync(path.join(root,"addon/EspeculadorBridge")).filter(name=>/\.(lua|toc|md)$/.test(name));
fs.writeFileSync(path.join(destination,"EspeculadorBridge.zip"),zip(addonFiles.map(name=>entry("addon/EspeculadorBridge",name,"EspeculadorBridge/"))));
console.log("Descargas preparadas: sincronizador del PC y puente de Auctioneer.");

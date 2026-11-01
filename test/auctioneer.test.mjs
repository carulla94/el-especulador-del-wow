import test from "node:test";
import assert from "node:assert/strict";
import {MARKET, LIMITS, SavedVariablesError, parseSavedVariables, itemIdentity, normalizeOverTime, normalizeBridge} from "../src/auctioneer.mjs";

const NOW = Date.parse("2026-11-01T18:30:00Z");
const HOUR = Math.floor(NOW / 3600000);
const REALM = "Reino PvP EU";
const plain = value => JSON.parse(JSON.stringify(value));
function literal(value) {
  if (value === null) return "nil";
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  return `{${Object.entries(value).map(([key,row]) => `[${literal(key)}]=${literal(row)}`).join(",")}}`;
}
function history({hour=HOUR, realm=REALM, key="2589", price="100", quantity="20", numericItem=false, quotedHour=false} = {}) {
  const itemKey = numericItem ? "2589" : JSON.stringify(key);
  return `AuctioneerStatsOverTimeData = {[${JSON.stringify(realm)}] = {[${quotedHour ? JSON.stringify(String(hour)) : hour}] = {price = {[${itemKey}] = ${price}}, count = {[${itemKey}] = ${quantity}}}}}`;
}
function bridgeData() {
  return {schemaVersion:1, source:"Auctioneer12.x", market:MARKET, enabled:true, confirmedMarket:true,
    capturedAt:NOW/1000, savedAt:NOW/1000, lastBatchScope:"partial", complete:false,
    metadata:{region:"EU", faction:"Alliance", ruleset:"pvp", rulesetVerification:"user-confirmed", interface:16001, realm:REALM},
    items:{"2589":{itemId:2589,name:"Paño de prueba",buyCopper:100,quantityObserved:20,observedAt:NOW/1000}}};
}
const bridge = (data=bridgeData()) => `EspeculadorBridgeDB = ${literal(data)}`;

test("literal parser reads comments, named/numeric fields, lists and primitive values", () => {
  const parsed = parseSavedVariables(`-- header
    A = {name="abc", [3]=true, false, nil, ["text"]=1.25e2;};
    --[=[ comment ]=]
    B=-12; C=0x10; D=-0x1f
  `);
  assert.deepEqual(plain(parsed), {A:{1:false,2:null,3:true,name:"abc",text:125},B:-12,C:16,D:-31});
  assert.equal(Object.getPrototypeOf(parsed), null);
  assert.equal(Object.getPrototypeOf(parsed.A), null);
});

test("UTF-8 source and decimal byte escapes are decoded together without corruption", () => {
  const parsed = parseSavedVariables(String.raw`A="Vall\195\168s"; B="Sant Cugat · Alianza"; C="ñ\195\177"`);
  assert.equal(parsed.A,"Vallès");
  assert.equal(parsed.B,"Sant Cugat · Alianza");
  assert.equal(parsed.C,"ññ");
});

test("quoted text resembling code remains inert text", () => {
  assert.equal(parseSavedVariables(String.raw`A="quoted\"; os.execute('bad')"`).A, `quoted"; os.execute('bad')`);
});

test("long strings, optional initial linebreak and escaped linebreaks work", () => {
  assert.equal(parseSavedVariables("A=[=[\nhello\nworld]=]").A,"hello\nworld");
  assert.equal(parseSavedVariables("A={[[value]],}").A[1],"value");
  assert.equal(parseSavedVariables('A="hello\\\nworld"').A,"hello\nworld");
});

test("executable and trailing Lua is rejected", () => {
  for (const text of ['A={};os.execute("bad")','A=dofile("a")','A=function() return 1 end','A=_G','A=foo.bar','A={};A[1]=7','return {1}','local A={}','A=1+2','A=(1)','A="a".."b"','A={};while true do end']) {
    assert.throws(() => parseSavedVariables(text), SavedVariablesError, text);
  }
});

test("prototype keys and duplicate assignments cannot mutate JS prototypes", () => {
  for (const text of ['__proto__={polluted=true}','A={__proto__={polluted=true}}','A={["constructor"]={}}','A=1;A=2','A={x=1,x=2}','A={[1]=1,2}','A={[1]=1,[1.0]=2}','A={[1]=1,["1"]=2}']) {
    assert.throws(() => parseSavedVariables(text), SavedVariablesError);
  }
  assert.equal({}.polluted, undefined);
});

test("non-primitive table keys are rejected", () => {
  for (const text of ['A={[true]=1}','A={[false]=1}','A={[nil]=1}','A={[{}]=1}']) assert.throws(() => parseSavedVariables(text), SavedVariablesError);
});

test("unsafe, nonfinite, underflowed and rounded numerical values are rejected", () => {
  for (const token of ['1e9999','-1e9999','9007199254740993','0x20000000000000','1e-400','9007199254740990.5','9'.repeat(70)]) assert.throws(() => parseSavedVariables(`A=${token}`), SavedVariablesError, token);
  assert.equal(parseSavedVariables('A=9007199254740991').A,Number.MAX_SAFE_INTEGER);
  assert.equal(parseSavedVariables('A=0.125').A,0.125);
});

test("bad escaping and truncated structures are rejected", () => {
  for (const raw of [String.raw`A="\999"`,String.raw`A="\q"`,'A="unfinished','A={x=1','--[[ comment','A=[=[missing',String.raw`A="\195"`]) assert.throws(() => parseSavedVariables(raw), SavedVariablesError);
});

test("byte, nesting, node and individual-string limits are enforced", () => {
  assert.throws(() => parseSavedVariables('A='+"{".repeat(40)+"1"+"}".repeat(40)), SavedVariablesError);
  assert.throws(() => parseSavedVariables('A={1,2,3,4}',{nodes:3}), SavedVariablesError);
  assert.throws(() => parseSavedVariables('A="hello"',{stringBytes:3}), SavedVariablesError);
  assert.throws(() => parseSavedVariables('A={1}',{bytes:3}), SavedVariablesError);
  assert.equal(LIMITS.bytes,16*1024*1024);
});

test("BOM and empty literal files work", () => {
  assert.deepEqual(plain(parseSavedVariables('\uFEFFA={}')),{A:{}});
  assert.deepEqual(plain(parseSavedVariables(' -- nothing\n')),{});
});

test("historical discovery never assumes region, faction or ruleset", () => {
  const result = normalizeOverTime(history(),null,false,NOW);
  assert.equal(result.requiresRealm,true);
  assert.deepEqual(result.realms,[REALM]);
  assert.equal(result.rows,undefined);
  assert.equal(result.market,undefined);
});

test("historical imports require an explicit real realm and boolean market confirmation", () => {
  for (const confirmation of [false,null,1,"true"]) assert.throws(() => normalizeOverTime(history(),REALM,confirmation,NOW),SavedVariablesError);
  assert.throws(() => normalizeOverTime(history(),"Other",true,NOW),SavedVariablesError);
});

test("hour buckets retain their original UTC timestamp and are never current offers", () => {
  const result = normalizeOverTime(history(),REALM,true,NOW);
  assert.deepEqual(result.rows,[{itemKey:"2589",itemId:2589,observedAt:"2026-11-01T18:00:00.000000Z",priceCopper:100,quantityObserved:20}]);
  assert.equal(result.rows[0].buyCopper,undefined);
  assert.equal(result.rows[0].eligible,undefined);
  assert.match(result.warning,/no representa/i);
});

test("importing old data never substitutes the current import time", () => {
  const result = normalizeOverTime(history({hour:HOUR-48}),REALM,true,NOW);
  assert.equal(result.rows[0].observedAt,"2026-10-30T18:00:00.000000Z");
});

test("full item variants and pets retain separate identities", () => {
  for (const [key,itemId] of Object.entries({"2589":2589,"2589:60":2589,"2589::-12":2589,"2589:60:-12":2589,"123:60:-12:2":123,":::42":82800,"82800:::42":82800})) {
    assert.equal(itemIdentity(key),itemId);
    const row = normalizeOverTime(history({key}),REALM,true,NOW).rows[0];
    assert.equal(row.itemKey,key);
    assert.equal(row.itemId,itemId);
  }
});

test("unknown item-key formats and unsafe variant components are rejected", () => {
  for (const key of ["item:2589","0",":::0","",":12","1:2:3:4:5","2589::foo","1:-2","1::9007199254740993"]) assert.throws(() => itemIdentity(key),SavedVariablesError,key);
});

test("numeric item keys and string hour keys cannot masquerade as source format", () => {
  assert.throws(() => normalizeOverTime(history({numericItem:true}),REALM,true,NOW),SavedVariablesError);
  assert.throws(() => normalizeOverTime(history({quotedHour:true}),REALM,true,NOW),SavedVariablesError);
});

test("future and pre-Forever historical timestamps are rejected", () => {
  for (const hour of [HOUR+1,Math.floor(Date.parse("2025-01-01")/3600000),-1]) assert.throws(() => normalizeOverTime(history({hour}),REALM,true,NOW),SavedVariablesError);
});

test("invalid historical price or quantity cannot become a normalized row", () => {
  for (const price of ["true","false",'"100"',"0","-1","1.5","1e16"]) assert.throws(() => normalizeOverTime(history({price}),REALM,true,NOW),SavedVariablesError);
  for (const quantity of ["true",'"20"',"-1","1.5","10000000001"]) assert.throws(() => normalizeOverTime(history({quantity}),REALM,true,NOW),SavedVariablesError);
});

test("mismatched rows, unknown globals and invalid late rows reject the whole normalization", () => {
  const invalids = [history().replace('count = {["2589"]','count = {["2592"]'),history()+" Other={}",history().replace('price = {["2589"] = 100}','price = {["2589"] = 100,["9999"]=false}').replace('count = {["2589"] = 20}','count = {["2589"] = 20,["9999"]=1}')];
  for (const raw of invalids) assert.throws(() => normalizeOverTime(raw,REALM,true,NOW),SavedVariablesError);
});

test("bridge normalizer exports only partial observations with their own timestamps", () => {
  const result = normalizeBridge(bridge(),NOW);
  assert.equal(result.realm,REALM);
  assert.equal(result.snapshot.market,MARKET);
  assert.equal(result.snapshot.coverage,"partial");
  assert.equal(result.snapshot.items[0].referenceCopper,null);
  assert.equal(result.snapshot.items[0].observedAt,"2026-11-01T18:30:00.000000Z");
  assert.equal(result.bridgeMeta.itemCount,1);
  assert.equal(result.bridgeMeta.status,"experimental");
});

test("bridge savedAt and refreshed batch timestamp never rejuvenate old item observations", () => {
  const data = bridgeData();
  data.items["2589"].observedAt -= 48*3600;
  data.savedAt += 1000000;
  assert.equal(normalizeBridge(bridge(data),NOW).snapshot.items[0].observedAt,"2026-10-30T18:30:00.000000Z");
});

test("bridge refuses missing confirmation, wrong market and incompatible context", () => {
  for (const [key,value] of [["market","forever.pvp.horde.eu"],["enabled",false],["confirmedMarket",false],["source","Other"],["schemaVersion",2]]) {
    const data = bridgeData(); data[key]=value;
    assert.throws(() => normalizeBridge(bridge(data),NOW),SavedVariablesError);
  }
  for (const [key,value] of [["region","US"],["faction","Horde"],["ruleset","normal"],["interface",120001],["rulesetVerification","guessed"],["realm",""]]) {
    const data = bridgeData(); data.metadata[key]=value;
    assert.throws(() => normalizeBridge(bridge(data),NOW),SavedVariablesError);
  }
});

test("bridge rejects complete-market claims, future captures and per-item timestamps beyond capture", () => {
  for (const changes of [{complete:true},{lastBatchScope:"full"},{capturedAt:NOW/1000+3600}]) {
    assert.throws(() => normalizeBridge(bridge({...bridgeData(),...changes}),NOW),SavedVariablesError);
  }
  const data=bridgeData(); data.items["2589"].observedAt++;
  assert.throws(() => normalizeBridge(bridge(data),NOW),SavedVariablesError);
});

test("bridge validates every row before return including names and key consistency", () => {
  for (const changes of [{name:true},{buyCopper:0},{quantityObserved:-1},{itemId:2592},{observedAt:1}]) {
    const data=bridgeData(); data.items["2589"]={...data.items["2589"],...changes};
    assert.throws(() => normalizeBridge(bridge(data),NOW),SavedVariablesError);
  }
  const data=bridgeData(); data.items["2589:60"]={...data.items["2589"],name:"Variant"};
  const normalized=normalizeBridge(bridge(data),NOW);
  assert.equal(normalized.snapshot.items.length,2);
  assert.deepEqual(normalized.snapshot.items.map(row=>row.itemKey).sort(),["2589","2589:60"]);
});

test("bridge unknown root or executable tail is rejected", () => {
  assert.throws(() => normalizeBridge('Other={}',NOW),SavedVariablesError);
  assert.throws(() => normalizeBridge(bridge()+" os.execute('bad')",NOW),SavedVariablesError);
});

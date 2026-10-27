import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';

const id = '1e932c61-9ddc-4cfa-bf5d-2fb07511c443';
const report = {id, kind:'feedback', note:'Fixture report', contact:'fixture@example.com'};
const diagnostics = {agentCount:6,attachmentCount:0,buildNumber:'14',bundleIdentifier:'com.msgblast.feedback-demo',comparisonCount:0,fixtureMode:true,hasDraft:true,lastErrorCategory:'none',messagesStatus:'simulated',operatingSystem:'Version 27.2 (Build 26B5091g)',permissionStage:'idle',personalAgent:'none',stateFileBytes:1175,stateFilePresent:true,supportFolder:'msgblast-Demo',updatesEnabled:false,updatesReason:'Updates are disabled in previews and test runs.',variant:'other',version:'0.6.2',webProviderCounts:{chatgpt:1,dots:1,grokbot:1},windowStyle:'connected'};
function environment() {
  const objects = new Map();
  return {objects, FEEDBACK_RATE_LIMIT:{limit:async()=>({success:true})}, FEEDBACK_BUCKET:{
    head:async key=>objects.get(key) ?? null,
    put:async(key,value,options)=>{
      assert.deepEqual(options.onlyIf,{etagDoesNotMatch:'*'});
      if(objects.has(key))return null;
      const object={value,customMetadata:options.customMetadata};
      objects.set(key,object); return object;
    }
  }};
}
function request(body=report, headers={}) { return new Request('https://msgblast.app/api/feedback',{method:'POST', headers:{'content-type':'application/json',...headers},body:JSON.stringify(body)}); }
const send=(body,env=environment())=>worker.fetch(request(body),env);

test('stores private JSON and returns receipt without content or URL',async()=>{
  const env=environment(), response=await send({...report,diagnostics:JSON.stringify(diagnostics)},env);
  assert.equal(response.status,201);assert.deepEqual(await response.json(),{id});
  const saved=JSON.parse(env.objects.get(`reports/${id}.json`).value);
  assert.deepEqual(saved.diagnostics,diagnostics);assert.equal(saved.note,report.note);assert.equal(saved.contact,report.contact);
  assert.match(saved.receivedAt,/^\d{4}-\d{2}-\d{2}T/);assert.equal(response.headers.get('cache-control'),'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'),null);
});
test('diagnostics omitted unless explicitly provided; blank contact allowed',async()=>{
 const env=environment(); assert.equal((await send({...report,contact:''},env)).status,201);
 assert.equal('diagnostics' in JSON.parse(env.objects.get(`reports/${id}.json`).value),false);
});
test('rejects malformed fields and unknown input',async()=>{
 for(const value of [{...report,id:'../file'},{...report,kind:'other'},{...report,note:' '},{...report,note:'x'.repeat(16001)},{...report,contact:'bad'},{...report,contact:'a'.repeat(121)+'@x.com'},{...report,files:[]},[],null])assert.equal((await send(value)).status,400);
 assert.equal((await send({id,kind:'bug',note:'🐈'.repeat(8000)})).status,201);
});
test('accepts bounded native-app provider counts while retaining the private diagnostics allowlist',async()=>{
 const env=environment();
 const counts={museApp:1,grokBotApp:1,wabi:1,geminiApp:1,chatgptApp:2,dotsApp:1,claudeApp:1,os3:1,hark:1};
 const input={...report,diagnostics:JSON.stringify({...diagnostics,webProviderCounts:counts})};
 assert.equal((await send(input,env)).status,201);
 assert.deepEqual(JSON.parse(env.objects.get(`reports/${id}.json`).value).diagnostics.webProviderCounts,counts);
 for(const bad of [{unknownApp:1},{chatgptApp:-1},{wabi:'private text'},{dotsApp:1000001}])
  assert.equal((await send({...report,diagnostics:JSON.stringify({...diagnostics,webProviderCounts:bad})})).status,400);
});
test('diagnostics allowlist rejects arbitrary fields, types and categories',async()=>{
 for(const value of [{...diagnostics,transcript:'secret'},{...diagnostics,agentCount:-1},{...diagnostics,agentCount:1000001},{...diagnostics,fixtureMode:'true'},{...diagnostics,messagesStatus:'private text'},{...diagnostics,webProviderCounts:{unknown:1}},{...diagnostics,supportFolder:'/Users/private'},{...diagnostics,updatesReason:'a token'},{...diagnostics,version:'secret with spaces'},{}])assert.equal((await send({...report,diagnostics:JSON.stringify(value)})).status,400);
 assert.equal((await send({...report,diagnostics})).status,400);
});
test('caps streamed bytes even without Content-Length and cancels oversized input',async()=>{
 let cancelled=false;
 const stream=new ReadableStream({pull(controller){controller.enqueue(new Uint8Array(32769));},cancel(){cancelled=true;}});
 const response=await worker.fetch(new Request('https://msgblast.app/api/feedback',{method:'POST',headers:{'content-type':'application/json'},body:stream,duplex:'half'}),environment());
 assert.equal(response.status,413);assert.equal(cancelled,true);
 assert.equal((await worker.fetch(request(report,{'content-length':'65537'}),environment())).status,413);
});
test('rate limit rejects with retry hint; limiter errors fail closed',async()=>{
 const env=environment();let key;
 env.FEEDBACK_RATE_LIMIT.limit=async input=>{key=input.key;return {success:false};};
 const response=await worker.fetch(request(report,{'CF-Connecting-IP':'192.0.2.1'}),env);
 assert.equal(response.status,429);assert.equal(response.headers.get('retry-after'),'60');assert.equal(key,'192.0.2.1');assert.equal(env.objects.size,0);
 env.FEEDBACK_RATE_LIMIT.limit=async()=>{throw Error('unavailable');};assert.equal((await send(report,env)).status,503);
 delete env.FEEDBACK_RATE_LIMIT;assert.equal((await send(report,env)).status,503);
});
test('storage errors fail without success',async()=>{
 const env=environment();env.FEEDBACK_BUCKET.put=async()=>{throw Error('offline');};assert.equal((await send(report,env)).status,503);
});
test('idempotent retries return same receipt; changed content conflicts',async()=>{
 const env=environment();assert.equal((await send(report,env)).status,201);assert.equal((await send({...report},env)).status,200);
 assert.equal((await send({...report,note:'changed'},env)).status,409);assert.equal(env.objects.size,1);
});
test('conditional put handles concurrent equal reports and collisions',async()=>{
 for(const second of [report,{...report,note:'different'}]){
 const env=environment(); const responses=await Promise.all([send(report,env),send(second,env)]);
 assert.deepEqual(responses.map(x=>x.status).sort(),second===report?[200,201]:[201,409]);assert.equal(env.objects.size,1);
 }
});
test('malformed JSON/content types and invalid UTF8 fail; methods have no listing',async()=>{
 assert.equal((await worker.fetch(new Request('https://msgblast.app/api/feedback',{method:'POST',body:'{' ,headers:{'content-type':'application/json'}}),environment())).status,400);
 assert.equal((await worker.fetch(request(report,{'content-type':'text/plain'}),environment())).status,415);
 assert.equal((await worker.fetch(new Request('https://msgblast.app/api/feedback'),environment())).status,405);
});
test('canonical diagnostics ordering permits identical retry and rejects invalid UTF8',async()=>{
 const env=environment();
 assert.equal((await send({...report,diagnostics:JSON.stringify(diagnostics)},env)).status,201);
 const reordered=Object.fromEntries(Object.entries(diagnostics).reverse());
 assert.equal((await send({...report,diagnostics:JSON.stringify(reordered)},env)).status,200);
 assert.equal((await worker.fetch(new Request('https://msgblast.app/api/feedback',{method:'POST',headers:{'content-type':'application/json'},body:new Uint8Array([0xff])}),environment())).status,400);
});
test('other routes delegate only to assets',async()=>{
 const env=environment();env.ASSETS={fetch:async()=>new Response('asset')};assert.equal(await (await worker.fetch(new Request('https://msgblast.app/'),env)).text(),'asset');
});

const crash = {schema:1, incident:'12345678-1234-1234-1234-123456789abc', process:'app', bundleIdentifier:'com.msgblast.mac', version:'0.9.0', build:'40', exception:'EXC_CRASH', signal:'SIGABRT', day:'2026-09-21', frames:[{uuid:'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',arch:'arm64',offset:1234}], fingerprint:'a'.repeat(64)};
test('crash summaries are strictly validated and private with idempotent receipt',async()=>{
 const env=environment(); const body={...report,kind:'crash',crash};
 assert.equal((await send(body,env)).status,201);
 assert.equal((await send(body,env)).status,200);
 assert.deepEqual(JSON.parse(env.objects.get(`reports/${id}.json`).value).crash,crash);
 for(const bad of [{...crash,path:'/Users/private'},{...crash,frames:[{...crash.frames[0],symbol:'chat text'}]},{...crash,frames:[]},{...crash,frames:Array(65).fill(crash.frames[0])},{...crash,signal:'SIGTERM'},{...crash,bundleIdentifier:'com.other.app'},{...crash,frames:[{...crash.frames[0],offset:-1}]}]) {
  assert.equal((await send({...body,crash:bad})).status,400);
 }
 assert.equal((await send({...report,kind:'crash'})).status,400);
 assert.equal((await send({...report,crash})).status,400);
});
test('crash retries normalize frame-object key order inside arrays',async()=>{
 const env=environment();
 const body={...report,kind:'crash',crash};
 assert.equal((await send(body,env)).status,201);
 const reordered={...crash,frames:crash.frames.map(f=>({offset:f.offset,arch:f.arch,uuid:f.uuid}))};
 assert.equal((await send({...body,crash:reordered},env)).status,200);
 assert.equal(env.objects.size,1);
});

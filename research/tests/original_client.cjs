'use strict';
// Tests isolated, inspected client functions. This does NOT launch the Medal GUI.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert/strict');
const {EventEmitter,once}=require('events');const crypto=require('crypto');const {execFileSync}=require('child_process');const {DatabaseSync}=require('node:sqlite');
const ROOT=path.resolve(__dirname,'..'),APP=path.resolve(process.argv[2]||'./extracted/app');const src=fs.readFileSync(path.join(APP,'main.min.js'),'utf8');
assert.equal(crypto.createHash('sha256').update(src).digest('hex'),'5a2a6dd5d1370a15577b0c09bc2d021059e2f9e7dba6a2e40cc41b4685e0c8ff');
const syms=JSON.parse(fs.readFileSync(path.join(ROOT,'evidence/test_symbols.json')));const oldSyms=JSON.parse(fs.readFileSync(path.join(ROOT,'evidence/client_symbols.json')));for(const x of oldSyms)syms[x.name]??={...x,type:'FunctionDeclaration'};
const WS=require(path.join(APP,'node_modules/ws'));const events=new EventEmitter();const logs=[],tests=[],inserted=[];
const log=new Proxy({},{get:(_,k)=>(...args)=>logs.push({level:k,text:String(args[0])})});
const db=new DatabaseSync(':memory:');db.exec('CREATE TABLE contents(created_at INTEGER NOT NULL,category_id TEXT,video_path TEXT,image_path TEXT,thumbnail_path TEXT,metadata BLOB NOT NULL,remote_content_id TEXT UNIQUE,local_content_id TEXT UNIQUE NOT NULL,parent_id TEXT)');
const cols=['created_at','category_id','video_path','image_path','thumbnail_path','metadata','remote_content_id','local_content_id','parent_id'];
const dbAdapter={columnNameSet:new Set(cols),prepare(sql){const st=db.prepare(sql);return{run(...args){return st.run(...args.map(v=>v===undefined?null:v))}}}};
const recorder={stateMachine:{status:'running',meta:{didReset:false},sessionState:{}}};
const ctx=vm.createContext({console,setTimeout,clearTimeout,crypto,process,Buffer,LP:WS,Ct:events,
 oe:{logger:log,authObject:null,GlobalEvents:events},Gt:{default:new Proxy({},{get:()=>s=>s})},n$:{SUCCESS:'success',FAIL:'fail'},r$:['ping','settings','customGameSettings','steamGamesInLibrary'],t$:1000,
 Ta:async(fn,ms,err)=>{let t;try{return await Promise.race([Promise.resolve().then(fn),new Promise((_,rej)=>{t=setTimeout(()=>rej(err),ms)})])}finally{clearTimeout(t)}},
 VS:false,Vi:()=>false,ase:false,mT:false,Qk:false,Bk:null,Ua:()=>{},
 // Isolated media-registration dependencies: real SQLite and FFmpeg; no cloud calls.
 bb:{FIVEM:'fivem-test-not-in-use'},Mr:()=>({}),Wt:async()=>false,mc:async()=>{const p=path.join(__dirname,'media/thumbs');fs.mkdirSync(p,{recursive:true});return p},
 tt:{FileRename:'fileRename',AutoUploadOption:'autoUpload',OverlayEnabled:'overlayEnabled'},De:{ShowOverlay:'showOverlay'},
 fd:async p=>{const j=JSON.parse(execFileSync('ffprobe',['-v','error','-show_format','-show_streams','-of','json',p],{encoding:'utf8'}));const v=j.streams.find(s=>s.codec_type==='video');return{clipDuration:Number(j.format.duration),width:v.width,height:v.height,contentSize:fs.statSync(p).size}},
 At:{default:path},Ht:{default:fs.promises},c1:fn=>fn(),WN:async(p,t)=>{execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-y','-i',p,'-frames:v','1',t])},Th:async()=>({}),ur:async()=>dbAdapter,KN:cols.map(c=>c==='metadata'?'json(metadata) as metadata':c),_5:()=>cols,Che:async()=>{},hd:{ON:{KEY:'on'},ON_GAME_EXIT:{KEY:'on_game_exit'}},L4:[]
});
function load(n){const x=syms[n];assert(x,`missing ${n}`);vm.runInContext((x.type==='VariableDeclarator'?'var ':'')+src.slice(x.start,x.end)+';',ctx,{filename:n+'.js',timeout:1000})}
for(const n of ['x','nse','BQ','SZe','_Ze','BZe','QZe','wZe'])load(n);vm.runInContext('var fT=wZe();',ctx);
// Unused handlers are inert test doubles; the paths exercised below are original functions.
const classText=src.slice(syms.K7e.start,syms.K7e.end);const pairs=[...classText.matchAll(/\["([^"]+)",([\w$]+)\]/g)];
for(const [,method,name]of pairs)ctx[name]=()=>({testDouble:method});
for(const n of ['Ov','w7e','l7e','A7e','p7e','w5','gfe','m7e','K7e'])load(n);
const clean=x=>JSON.parse(JSON.stringify(x));
function ok(name,detail){tests.push({name,status:'passed',detail});console.log('PASS',name)}
async function main(){
 const handler=new ctx.K7e(recorder);ctx.oe.WSHandler=handler;const srv=handler.start(0);await once(srv,'listening');const port=srv.address().port;
 const probeResult=await new Promise((resolve,reject)=>require('child_process').execFile(process.execPath,[path.join(ROOT,'tools/recorder_probe.mjs'),'--port',String(port)],{timeout:20000},(err,stdout,stderr)=>err?reject(new Error(String(err)+' '+stderr+' '+stdout)):resolve(stdout)));
 assert.match(probeResult,/handshake-ok/);assert.match(probeResult,/heartbeat-ok/);ok('standalone diagnostic probe connects to original client WS',{nativeCapture:false});
 const sock=new WS(`ws://127.0.0.1:${port}`);let id=0;const pending=new Map();
 sock.on('message',raw=>{const msg=JSON.parse(raw.toString());if(msg.method){if(msg.id!==undefined){const result=msg.method==='availableMicDevices'?['Test microphone']:null;sock.send(JSON.stringify({jsonrpc:'2.0',id:msg.id,result}))}}else{const p=pending.get(msg.id);if(p){pending.delete(msg.id);p.resolve(msg)}}});await once(sock,'open');
 const req=(method,params={})=>new Promise((resolve,reject)=>{const rid=++id;const t=setTimeout(()=>{pending.delete(rid);reject(new Error('timeout '+method))},2000);pending.set(rid,{resolve:x=>{clearTimeout(t);resolve(x)}});sock.send(JSON.stringify({jsonrpc:'2.0',id:rid,method,params}))});
 let r=await req('handshake',{supportedVersions:[1],preferredVersion:1});assert.deepEqual(r.result,{result:'success',errorMessage:null,data:{version:1,capabilities:[]}});ok('actual client WS + JSON-RPC handshake',r.result);
 r=await req('handshake',{supportedVersions:[2,1],preferredVersion:2});assert.equal(r.result.data.version,1);ok('handshake negotiates common version',r.result.data);
 r=await req('handshake',{supportedVersions:[99],preferredVersion:99});assert.deepEqual(r.result.data,{});ok('no common version produces empty data (client quirk)',r.result);
 r=await req('ping');assert.equal(r.result.data,'pong');ok('recorder-to-client heartbeat uses Medal envelope',r.result);
 r=await req('notARealMethod');assert.equal(r.error.code,-32601);ok('unknown RPC rejected; no fabricated success',r.error);
 r=await req('setKV',{key:'micDevices',value:['Test microphone']});assert.deepEqual(clean(recorder.stateMachine.sessionState.micDevices),['Test microphone']);ok('setKV updates original client session state',{});
 r=await req('recordingReady');assert.equal(recorder.stateMachine.status,'ready');assert.match(recorder.stateMachine.sessionState.currentSessionId,/^[0-9a-f-]{36}$/);ok('recordingReady transitions original state machine',clean(recorder.stateMachine));
 const mics=await handler.sendRequest('availableMicDevices',{});assert.deepEqual(clean(mics),['Test microphone']);ok('client-to-helper response is a raw array, not Medal envelope',mics);
 const evt={uuid:crypto.randomUUID(),createdAt:Date.now(),clipLocation:path.join(__dirname,'media/replay.mp4'),gameCategoryId:'test-game',clipType:'clip',captureType:'screen',processName:'SyntheticTest',metadata:{triggerType:'Manual',exportStatsDuration:4.015365}};
 r=await req('contentCreate',evt);assert.equal(r.result.result,'success');assert.deepEqual(r.result.data,{uuid:evt.uuid,contentId:null});
 const row=db.prepare("SELECT local_content_id,video_path,thumbnail_path,json_extract(metadata,'$.clipDuration') AS duration,json_extract(metadata,'$.recorder.currentSessionId') AS sessionId FROM contents").get();assert.equal(row.local_content_id,evt.uuid);assert(fs.existsSync(row.thumbnail_path));assert(row.duration>3.9&&row.duration<4.1);assert.equal(row.sessionId,recorder.stateMachine.sessionState.currentSessionId);ok('actual m7e -> gfe -> w5 registers real MP4 + thumbnail in SQLite (adapted dependencies)',row);
 await new Promise((resolve,reject)=>{const hostile=new WS(`ws://127.0.0.1:${port}`,{origin:'https://example.invalid'});hostile.on('unexpected-response',(_q,res)=>{try{assert.equal(res.statusCode,401);res.resume();hostile.terminate();resolve()}catch(e){reject(e)}});hostile.on('error',()=>{});hostile.on('open',()=>{hostile.close();reject(new Error('origin accepted'))})});ok('actual server rejects browser Origin header',{});
 const closing=once(events,'recorder.selfExit');sock.close(1000,'shutdown');await closing;ok('shutdown close reason emits recorder.selfExit',{});
 handler.destroy();db.close();fs.writeFileSync(path.join(__dirname,'protocol_results.json'),JSON.stringify({scope:'Isolated original JS functions, original bundled ws + JSON-RPC; runtime/DB/media dependencies adapted. No full Electron GUI or cloud calls.',tests},null,2));
}
main().catch(err=>{console.error(err);fs.writeFileSync(path.join(__dirname,'protocol_results.json'),JSON.stringify({tests,error:err.stack},null,2));process.exit(1)});

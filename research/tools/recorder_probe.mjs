#!/usr/bin/env node
/** Diagnostic transport probe, NOT a recorder or a capability emulator.
 * Node 22+ with global WebSocket. Never records, sends recordingReady, registers
 * clips, requests account details, persists settings or logs message values.
 * Stop the official recorder before using against an isolated Medal test profile.
 */
import {parseArgs} from 'node:util';
const {values} = parseArgs({options:{port:{type:'string'},hold:{type:'boolean',default:false}},strict:true});
const port = Number(values.port);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('--port must be the actual client-selected loopback port');
if (typeof WebSocket !== 'function') throw new Error('Node 22+ with global WebSocket is required');
let nextId=0, closed=false, heartbeat=null, shuttingDown=false;
const pending=new Map();
const socket=new WebSocket(`ws://127.0.0.1:${port}`);
const log=(event,detail={})=>console.log(JSON.stringify({event,...detail}));
const send=obj=>socket.send(JSON.stringify(obj));
function request(method,params={}) {
  return new Promise((resolve,reject)=>{
    const id=++nextId;
    const timeout=setTimeout(()=>{pending.delete(id);reject(new Error(`Request timed out: ${method}`))},15000);
    pending.set(id,{resolve,reject,timeout}); send({jsonrpc:'2.0',id,method,params});
  });
}
async function medalRequest(method,params={}) {
  const envelope=await request(method,params);
  if (!envelope || envelope.result!=='success') throw new Error(`Medal rejected ${method}; response contents omitted to protect credentials`);
  return envelope.data;
}
function close(reason='probe-complete') {
  shuttingDown=true;clearInterval(heartbeat);
  if (socket.readyState===WebSocket.OPEN) socket.close(1000,reason);
  else if (socket.readyState===WebSocket.CONNECTING) socket.close();
}
socket.addEventListener('message',event=>{
  try {
    if (typeof event.data!=='string') throw new Error('Unexpected binary frame');
    const msg=JSON.parse(event.data);
    if (msg.jsonrpc!=='2.0' || Array.isArray(msg)) throw new Error('Unexpected JSON-RPC frame');
    if (typeof msg.method==='string') {
      log('client-request',{method:msg.method,parameterKeys:msg.params&&typeof msg.params==='object'?Object.keys(msg.params):[]});
      const hasId=Object.prototype.hasOwnProperty.call(msg,'id');
      if (msg.method==='ping' || msg.method==='shutdown') {
        if (hasId) send({jsonrpc:'2.0',id:msg.id,result:null}); // Original recorder's Task<void> shape.
        if (msg.method==='shutdown') close('shutdown');
      } else if (hasId) {
        send({jsonrpc:'2.0',id:msg.id,error:{code:-32601,message:'Not implemented by diagnostic probe'}});
      }
    } else {
      const p=pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id); clearTimeout(p.timeout);
      if (msg.error) p.reject(new Error(`JSON-RPC error ${msg.error.code}`)); else p.resolve(msg.result);
    }
  } catch(e) { log('protocol-error',{message:e.message}); process.exitCode=1;close('protocol-error'); }
});
socket.addEventListener('open',async()=>{
  try {
    const h=await medalRequest('handshake',{supportedVersions:[1],preferredVersion:1});
    if (h?.version!==1 || !Array.isArray(h.capabilities)) throw new Error('No compatible handshake; empty success data is not success');
    log('handshake-ok',{version:h.version,capabilityCount:h.capabilities.length});
    const pong=await medalRequest('ping');
    if (pong!=='pong') throw new Error('Unexpected heartbeat result');
    log('heartbeat-ok');
    if (!values.hold) {close();return;}
    log('diagnostic-hold',{recording:false,readyReported:false});
    heartbeat=setInterval(()=>medalRequest('ping').catch(e=>{log('heartbeat-failed',{message:e.message});process.exitCode=1;close('heartbeat-failed')}),20000);
  } catch(e) {log('failed',{message:e.message});process.exitCode=1;close('probe-failed');}
});
socket.addEventListener('close',event=>{
  closed=true;clearInterval(heartbeat);
  for (const p of pending.values()){clearTimeout(p.timeout);p.reject(new Error('Socket closed'));}pending.clear();
  log('closed',{code:event.code});
  if(!shuttingDown) process.exitCode=1;
});
socket.addEventListener('error',()=>{log('connection-error');process.exitCode=1;close('connection-error')});
process.on('SIGINT',()=>close('shutdown'));
// A finite watchdog prevents hanging during connection/close failures in a short probe.
const watchdog=setTimeout(()=>{if(!closed&&!values.hold){log('watchdog-expired');process.exit(1)}},20000);
watchdog.unref();

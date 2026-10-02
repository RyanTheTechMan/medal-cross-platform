'use strict'
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm')
let state, cleanup, response = {schemaVersion: 1, state: 'capturing', applicationName: 'Synthetic App'}, call = 0
const timers = new Map()
const window = {MedalEnv: {platform: 'darwin'}, MedalIPC: {async sendRecorderWSRequest(method) {
  assert.equal(method, 'nativePort.captureActivity'); ++call; return response
}}}
vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname, 'native-capture-status.js'), 'utf8'), {
  window, setTimeout(fn) {timers.set(fn, fn); return fn}, clearTimeout(fn) {timers.delete(fn)},
})
const api = window.NativeMedalCaptureStatus
const React = {useState: () => [state, value => {state = value}], useEffect: fn => {cleanup = fn()}}
const turn = () => new Promise(resolve => setImmediate(resolve))
;(async () => {
  assert.equal(api.label({schemaVersion: 1, state: 'stopped', applicationName: 'Stale'}), null)
  assert.equal(api.label({schemaVersion: 2, state: 'capturing', applicationName: 'Unknown'}), null)
  assert.equal(api.label(null), null)
  api.useApplicationName(React); await turn()
  assert.equal(state, 'Synthetic App'); assert.equal(call, 1)
  const refresh = [...timers.keys()][0]; timers.delete(refresh)
  response = {schemaVersion: 1, state: 'failed', applicationName: 'Synthetic App'}
  await refresh(); assert.equal(state, null, 'failure clears stale recording label')
  cleanup(); assert.equal(timers.size, 0)
  window.MedalEnv.platform = 'win32'; api.useApplicationName(React); await turn()
  assert.equal(call, 2, 'original Windows header has no native polling')
  console.log('PASS capture label active/stopped/failed/schema/disposal and original Windows isolation')
})().catch(error => {console.error(error); process.exitCode = 1})

'use strict'
const assert = require('node:assert/strict'), vm = require('node:vm'), fs = require('node:fs')
const source = fs.readFileSync(require('node:path').join(__dirname, 'native-audio-preview-controller.js'), 'utf8')
const elements = [], nodes = [], timers = new Set(), released = []
let prepares = 0, failure = false, pending, hiddenMaster = false
class Media extends EventTarget {
  constructor() { super(); this.paused = true; this.ended = false; this.currentTime = 0; this.playbackRate = 1;
    this.muted = false; this.volume = .75; this.readyState = 4; this.duration = 30; this.seeking = false; elements.push(this) }
  async play() { this.paused = false }
  pause() { this.paused = true }
  load() {}
  removeAttribute() {}
}
class Node { connect(to) { this.to = to; return to } disconnect() { this.to = null } }
class Gain extends Node { constructor() { super(); this.gain = { value: 1, cancelScheduledValues() {}, setTargetAtTime(v) { this.value = v } }; nodes.push(this) } }
class Context {
  constructor() { this.currentTime = 0; this.destination = new Node() }
  createMediaElementSource() { return new Node() }
  createGain() { return new Gain() }
  createAnalyser() { return Object.assign(new Node(), { fftSize: 2048, getFloatTimeDomainData() {} }) }
  async resume() {}
}
const window = new EventTarget()
window.MedalIPC = { nativeAudioPreview: {
  async prepare() {
    ++prepares
    if (pending) await pending
    if (failure) throw new Error('fixture unavailable')
    if (hiddenMaster) return {lease: `lease-${prepares}`, streams: [
      {index: 1, title: 'All Audio', logicalId: 'all-audio'}, {index: 2, title: 'PC Audio'}]}
    return { lease: `lease-${prepares}`, streams: [{ index: 2, offset: 0, isMuted: false, url: 'fixture-pc' },
      { index: 5, offset: .2, isMuted: false, url: 'fixture-mic' }] }
  },
  async release(p) { released.push(p.lease) },
} }
const document = { createElement: () => ({ dataset: {}, style: {}, setAttribute() {}, remove() {} }) }
vm.runInNewContext(source, { window, document, AudioContext: Context, Audio: Media, CustomEvent,
  setTimeout, clearTimeout, setInterval(fn) { timers.add(fn); return fn }, clearInterval(id) { timers.delete(id) } })
const controller = window.NativeMedalAudioPreviewController
const video = new Media()
const attach = streams => controller.attach({ uuid: 'fixture-uuid', path: '/fixture.mp4', video, streams })
const turn = () => new Promise(resolve => setImmediate(resolve))
;(async () => {
  await attach([{ index: 2, isMuted: false }, { index: 5, isMuted: false }])
  assert.equal(controller.snapshot().state, 'ready')
  assert.equal(prepares, 1)
  assert.equal(nodes[0].gain.value, 0, 'baseline disconnected independently of user mute')
  assert.equal(video.muted, false, 'do not corrupt user master mute')
  assert.equal(nodes[1].gain.value, .75)
  assert.equal(nodes[2].gain.value, 0, 'delayed source not started before offset')
  video.currentTime = 1; await video.play(); video.dispatchEvent(new Event('play')); await turn()
  assert.equal(elements[1].currentTime, 1)
  assert.equal(elements[2].currentTime, .8)
  assert.equal(nodes[2].gain.value, .75)
  await attach([{index: 2, isMuted: true}])
  assert(nodes.every(n => n.gain.value === 0), 'bus absent from original controls cannot leak audio')
  await attach([{ index: 2, isMuted: true }, { index: 5, isMuted: true }])
  assert.equal(prepares, 1, 'toggles never rebuild sidecars')
  assert(nodes.every(n => n.gain.value === 0), 'all-muted includes original baseline')
  await attach([{ index: 2, isMuted: false }, { index: 5, isMuted: false }])
  assert.equal(nodes[1].gain.value, .75, 'cancel state restores gains')
  video.muted = true; video.dispatchEvent(new Event('volumechange'))
  assert(nodes.every(n => n.gain.value === 0), 'user master mute applies to every stem')
  video.muted = false; video.volume = .25; video.dispatchEvent(new Event('volumechange'))
  assert.equal(nodes[1].gain.value, .25)
  assert.equal(nodes[0].gain.value, 0, 'original player volume handler cannot leak master')
  video.pause(); video.dispatchEvent(new Event('pause')); assert(elements.every(e => e.paused))
  video.seeking = true; video.dispatchEvent(new Event('seeking')); assert(nodes.every(n => n.gain.value === 0))
  video.currentTime = 2; video.seeking = false; video.dispatchEvent(new Event('seeked')); await turn()
  assert.equal(elements[1].currentTime, 2)
  controller.detach(); assert.equal(timers.size, 0); assert.equal(released.length, 1)
  failure = true; await attach([])
  assert.equal(controller.snapshot().state, 'error')
  assert.equal(nodes[0].gain.value, 0, 'failure must remain fail-closed')
  assert(video.paused)
  controller.detach(); failure = false
  let resume; pending = new Promise(resolve => { resume = resolve })
  const late = attach([]); controller.detach(); resume(); await late
  assert.equal(controller.snapshot().state, 'disposed')
  assert.equal(released.length, 2, 'late prepare lease released')
  pending = undefined; hiddenMaster = true
  await attach([{index: 2, isMuted: true}])
  assert.equal(controller.snapshot().state, 'error', 'master plus stem manifest rejected')
  assert.equal(controller.snapshot().buses, 0)
  assert.equal(nodes[0].gain.value, 0, 'invalid prepared master cannot leak baseline')
  controller.detach()
  console.log('PASS preview ownership, in-place gain updates, cancel, master mute, offsets, seeking, pause, errors and async disposal (mock media, not GUI)')
})().catch(error => { console.error(error); process.exitCode = 1 })

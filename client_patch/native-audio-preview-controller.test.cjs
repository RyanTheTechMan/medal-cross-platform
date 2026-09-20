'use strict'

const assert = require('node:assert/strict')
const vm = require('node:vm')
const fs = require('node:fs')

const source = fs.readFileSync(require('node:path').join(__dirname, 'native-audio-preview-controller.js'), 'utf8')
const events = new Map()
const window = {
  MedalIPC: {
    nativeAudioPreview: {
      async prepare({ index }) { return { url: `native-audio-preview://${index}.m4a` } }
    }
  },
  addEventListener(name, callback) { events.set(name, callback) },
  removeEventListener() {},
  dispatchEvent() {}
}
class GainNode {
  constructor() { this.gain = { value: 1, setTargetAtTime(value) { this.value = value } } }
  connect() { return this }
  disconnect() {}
}
class AudioNode {
  connect(node) { return node }
  disconnect() {}
}
class FakeAudio {
  constructor() { this.paused = true; this.ended = false; this.currentTime = 0; this.playbackRate = 1 }
  addEventListener() {}
  removeEventListener() {}
  async play() { this.paused = false }
  pause() { this.paused = true }
  load() {}
  removeAttribute() {}
}
class AudioContext {
  constructor() { this.currentTime = 0; this.destination = new AudioNode() }
  createMediaElementSource() { return new AudioNode() }
  createGain() { return new GainNode() }
  async resume() {}
  async close() {}
}
const context = vm.createContext({ window, AudioContext, Audio: FakeAudio, CustomEvent: class CustomEvent {
  constructor(type, init) { this.type = type; this.detail = init?.detail }
}, console, setTimeout })
vm.runInContext(source, context)
assert.ok(window.NativeMedalAudioPreviewController)
const video = {
  muted: false, paused: true, ended: false, currentTime: 0, playbackRate: 1,
  addEventListener() {}, removeEventListener() {}
}
;(async () => {
  await window.NativeMedalAudioPreviewController.attach({
    uuid: 'fixture-uuid', path: '/profile/Media/fixture.mp4', video,
    streams: [{ index: 1, logicalId: 'all-audio', title: 'All Audio', isIncludeInMix: true },
      { index: 2, logicalId: 'pc-audio', title: 'PC Audio', isIncludeInMix: true, isMuted: false }]
  })
  assert.equal(video.muted, true, 'audition must suppress the original master')
  window.NativeMedalAudioPreviewController.toggle(2, true)
  window.NativeMedalAudioPreviewController.toggle(2, false)
  window.NativeMedalAudioPreviewController.reset()
  assert.equal(video.muted, false, 'cancel/reset must restore the saved baseline mute state')
  console.log('PASS native audio preview controller attach/toggle/reset')
})().catch(error => { console.error(error); process.exitCode = 1 })

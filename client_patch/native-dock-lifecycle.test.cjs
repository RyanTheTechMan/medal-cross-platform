'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const fs = require('node:fs')
const crypto = require('node:crypto')
const vm = require('node:vm')
const { createDockLifecycle } = require('./native-dock-lifecycle.cjs')

class Window extends EventEmitter {
  visible = true; minimized = false; destroyed = false
  isVisible() { return this.visible }
  isMinimized() { return this.minimized }
  isDestroyed() { return this.destroyed }
  hide() { this.visible = false; this.emit('hide') }
  show() { this.visible = true; this.emit('show') }
}
function fixture(platform = 'darwin') {
  const app = new EventEmitter(), main = new Window(), timers = new Map(), calls = [], errors = []
  let clock = 0, serial = 0, visible = true
  app.dock = {
    isVisible: () => visible,
    hide: () => { visible = false; calls.push('hide') },
    show: async () => { visible = true; calls.push('show') },
  }
  const lifecycle = createDockLifecycle({ app, platform, now: () => clock,
    schedule: (fn, ms) => { timers.set(++serial, { fn, at: clock + ms }); return serial },
    cancel: id => timers.delete(id), onError: (...args) => errors.push(args) })
  lifecycle.bind(main)
  return { app, main, lifecycle, calls, errors, timers, visible: () => visible,
    advance(ms) { clock += ms; for (const [id, timer] of timers) if (timer.at <= clock) {
      timers.delete(id); timer.fn()
    } },
  }
}
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve() }

test('pinned original X handler hides, not quits; adapter hides Dock and reopen restores', async () => {
  const source = fs.readFileSync('research/extracted-macos-m0/app/main.min.js', 'utf8')
  assert.equal(crypto.createHash('sha256').update(source).digest('hex'),
    '5a2a6dd5d1370a15577b0c09bc2d021059e2f9e7dba6a2e40cc41b4685e0c8ff')
  const start = source.indexOf('_onClose(t){'), end = source.indexOf('_onShow(){', start)
  assert(start >= 0 && end > start)
  const original = vm.runInNewContext(`new (class {${source.slice(start, end)}})()`)
  const f = fixture(); original.window = f.main; original._showIdleBackgroundToast = () => {}
  let prevented = false
  original._onClose({ preventDefault() { prevented = true } })
  assert(prevented); assert(!f.visible()); assert(!f.main.destroyed)
  f.main.show(); await flush()
  assert(f.visible()); assert.deepEqual(f.calls, ['hide', 'show'])
})
test('rapid close/reopen/close waits for Electron hide cooldown', async () => {
  const f = fixture(); f.main.hide(); f.advance(100); f.main.show(); await flush()
  f.main.hide(); assert(f.visible()); assert.equal(f.timers.size, 1)
  f.advance(1099); assert(f.visible()); f.advance(1); assert(!f.visible())
  assert.deepEqual(f.calls, ['hide', 'show', 'hide'])
})
test('reopen cancels stale delayed hide', async () => {
  const f = fixture(); f.main.hide(); f.main.show(); await flush(); f.main.hide()
  f.main.show(); f.advance(2000); await flush()
  assert(f.visible()); assert.equal(f.timers.size, 0)
})
test('close during asynchronous Dock show reconciles the eventual result', async () => {
  const f = fixture(); f.main.hide(); let resolve
  const show = f.app.dock.show
  f.app.dock.show = () => new Promise(r => { resolve = () => { show().then(r) } })
  f.main.show(); await flush(); f.main.hide(); resolve(); await flush()
  assert(f.visible()); f.advance(1100)
  assert(!f.visible())
})
test('close before pending show and quit before pending show do not resurrect Dock', async () => {
  const f = fixture(); f.main.hide(); f.main.show(); f.main.hide(); await flush()
  assert.deepEqual(f.calls, ['hide'])
  f.main.show(); f.app.emit('before-quit'); await flush()
  assert.deepEqual(f.calls, ['hide'])
})
test('minimize retains Dock; unrelated windows cannot change it', () => {
  const f = fixture(), unrelated = new Window()
  unrelated.hide(); assert(f.visible())
  f.main.minimized = true; f.main.visible = false; f.main.emit('minimize'); f.main.emit('hide')
  assert(f.visible()); assert.deepEqual(f.calls, [])
})
test('repeated binding is idempotent, replacement removes old listeners', () => {
  const f = fixture(); f.lifecycle.bind(f.main); assert.equal(f.main.listenerCount('hide'), 1)
  const replacement = new Window(); f.lifecycle.bind(replacement)
  f.main.hide(); assert(f.visible()); replacement.hide(); assert(!f.visible())
  f.lifecycle.dispose(); assert.equal(replacement.listenerCount('hide'), 0)
})
test('quit cancels delayed work and never prevents original shutdown', async () => {
  const f = fixture(); f.main.hide(); f.main.show(); await flush(); f.main.hide()
  f.app.emit('before-quit'); f.advance(2000); f.main.show(); await flush()
  assert.deepEqual(f.calls, ['hide', 'show']); assert.equal(f.timers.size, 0)
})
test('Windows/Linux unchanged and errors reported, not successful state', async () => {
  for (const platform of ['win32', 'linux']) {
    const f = fixture(platform); f.main.hide(); assert.deepEqual(f.calls, [])
    assert.equal(f.app.listenerCount('before-quit'), 0)
  }
  const f = fixture(); f.main.hide(); f.app.dock.show = async () => { throw new Error('rejected') }
  f.main.show(); await flush(); assert(!f.visible()); assert.equal(f.errors.length, 1)
})

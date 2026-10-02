'use strict'
const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const crypto = require('node:crypto')
const vm = require('node:vm')
const { EventEmitter } = require('node:events')
const original = fs.readFileSync('research/extracted-macos-m0/app/main.min.js', 'utf8')
assert.equal(crypto.createHash('sha256').update(original).digest('hex'),
  '5a2a6dd5d1370a15577b0c09bc2d021059e2f9e7dba6a2e40cc41b4685e0c8ff')
// Execute the actual exact-replacement strings, not a second implementation.
const importer = fs.readFileSync('tools/native_port_importer.py', 'utf8')
let source = original
for (const name of ['macos-menu-bar-left-click-reopens-right-click-menu',
  'macos-menu-bar-updates-do-not-reattach-left-click-menu']) {
  const pattern = /main_path,\n\s*'([^'\n]+)',\n\s*'([^'\n]+)',\n\s*1,\n\s*'([^'\n]+)'/g
  const match = [...importer.matchAll(pattern)].find(m => m[3] === name)
  assert(match, name); assert.equal(source.split(match[1]).length - 1, 1)
  source = source.replace(match[1], match[2])
}
function method(name) {
  const start = source.indexOf(`${name}(){`)
  assert(start >= 0)
  let depth = 0
  for (let i = start + name.length + 2; i < source.length; i++) {
    if (source[i] === '{') depth++
    if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1)
  }
  throw Error('unterminated method')
}
class Tray extends EventEmitter {
  destroyed = false; menus = []; popups = []
  destroy() { this.destroyed = true }
  isDestroyed() { return this.destroyed }
  setToolTip(value) { this.tooltip = value }
  setIgnoreDoubleClickEvents(value) { this.ignoreDouble = value }
  setContextMenu(value) { this.menus.push(value) }
  popUpContextMenu(value) { this.popups.push(value) }
}
function fixture(platform) {
  const obj = vm.runInNewContext(`new (class {${method('_setTrayMenuContext')}${method('_updateTrayMenu')}})()`, {
    process: { platform }, r3: true, _at: x => x, console,
    Ce: { Tray, app: { getAppPath: () => '/fixture' }, nativeImage: { createFromPath: x => x } },
  })
  obj.shows = 0; obj._show = () => obj.shows++; obj.state = 'hidden'
  obj._buildTrayMenu = () => ({ state: obj.state }); obj._setTrayMenuContext()
  return obj
}
test('macOS left-click reopens; only right-click builds the current original menu', () => {
  const obj = fixture('darwin'), tray = obj.tray
  assert.equal(tray.tooltip, 'Medal'); assert.equal(tray.ignoreDouble, true)
  tray.emit('click'); assert.equal(obj.shows, 1); assert.equal(tray.popups.length, 0)
  obj.state = 'visible'; obj._updateTrayMenu(); tray.emit('right-click')
  assert.deepEqual(tray.popups, [{ state: 'visible' }]); assert.equal(obj.shows, 1)
  assert(tray.menus.every(menu => menu === null))
  tray.emit('click'); assert.equal(obj.shows, 2)
})
test('tray recreation destroys old icon and restores single bindings', () => {
  const obj = fixture('darwin'), old = obj.tray; old.destroy(); obj._updateTrayMenu()
  assert.notEqual(obj.tray, old); assert.equal(obj.tray.listenerCount('click'), 1)
  assert.equal(obj.tray.listenerCount('right-click'), 1)
  obj._setTrayMenuContext(); assert(obj.tray !== old)
  obj.tray.emit('click'); assert.equal(obj.shows, 1)
})
test('Windows/Linux original click and attached menu behavior is preserved', () => {
  for (const platform of ['win32', 'linux']) {
    const obj = fixture(platform); obj.tray.emit('click'); obj.tray.emit('double-click')
    assert.equal(obj.shows, platform === 'win32' ? 2 : 0)
    obj.state = 'changed'; obj._updateTrayMenu()
    assert.deepEqual(obj.tray.menus.at(-1), { state: 'changed' })
    assert.equal(obj.tray.listenerCount('right-click'), 0)
  }
})

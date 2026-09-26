'use strict'
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path')
const { audioManifest } = require('./native-audio-media.cjs')
// The pinned original uses ABSOLUTE indexes. Only trusted legacy records with
// the recognized complete 0..N-1 bug may be migrated, never arbitrary UI ordinals.
const probe = { streams: [{ index: 0, codec_type: 'video' }, { index: 3, codec_type: 'audio' }, { index: 5, codec_type: 'audio' }] }
assert.deepEqual(audioManifest(probe).map(s => s.index), [3, 5])
assert.deepEqual(audioManifest(probe, [{ index: 0 }, { index: 1 }], { allowLegacyOrdinals: true }).map(s => [s.index, s.requestIndex]), [[3, 0], [5, 1]])
assert.throws(() => audioManifest(probe, [{ index: 0 }]), /Invalid/)
assert.throws(() => audioManifest(probe, [{ index: 3 }, { index: 3 }]), /Invalid/)
if (process.argv[2]) {
  const prepared = fs.readFileSync(process.argv[2], 'utf8')
  const original = fs.readFileSync(path.join(__dirname, '../research/extracted-macos-m0/app/main.min.js'), 'utf8')
  const start = original.indexOf('async function Ype('), end = original.indexOf('async function jpe(', start)
  const body = original.slice(start, end).split('namespacePath){')[1]
  assert(prepared.includes(body), 'entire original Windows trim body remains byte-for-byte unchanged')
  assert(prepared.includes('global.nativePortAudio.trim({uuid:nativeContentId'), 'native media capability called')
  assert(prepared.includes('global.nativePortAudio.assertSender(t)'), 'authorized caller required')
}
console.log('PASS actual manifest validator and native edit integration anchors')

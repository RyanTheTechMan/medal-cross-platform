'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')

const preparedMain = process.argv[2]
assert(preparedMain, 'pass the prepared main.min.js path')
const source = fs.readFileSync(preparedMain, 'utf8')

// The original renderer sends audio ordinals (0, 1, ...), while ffprobe and
// the native writer expose absolute container indexes (video is usually 0).
// Keep a source-level guard so a future importer patch cannot regress to
// feeding the renderer ordinals into FFmpeg's 0:<index> selectors.
assert.match(source, /const v=await fd\(e\),q=Array\.isArray\(v\.audioStreams\)/,
  'trim must probe the final file before resolving audio indexes')
assert.match(source, /index:Number\.isInteger\(q\[m\]\?\.index\)\?q\[m\]\.index:f\.index/,
  'trim must map each audio ordinal to the probed absolute stream index')
assert.match(source, /audioStreams:d\.map\(\(f,m\)=>\(\{\.\.\.f,index:Number\.isInteger\(q\[m\]\?\.index\)/,
  'trim must return the final audio manifest for persistence')

const resolveFinalManifest = (uiStreams, probedAudioStreams) => [...uiStreams]
  .sort((a, b) => a.index - b.index)
  .map((stream, ordinal) => ({
    ...stream,
    index: Number.isInteger(probedAudioStreams[ordinal]?.index)
      ? probedAudioStreams[ordinal].index
      : stream.index,
    audioOrdinal: ordinal,
  }))

assert.deepEqual(resolveFinalManifest([
  { index: 0, title: 'PC Audio', isMuted: false },
  { index: 1, title: 'Microphone', isMuted: true },
], [
  { index: 1, codecName: 'aac' },
  { index: 2, codecName: 'aac' },
]), [
  { index: 1, title: 'PC Audio', isMuted: false, audioOrdinal: 0 },
  { index: 2, title: 'Microphone', isMuted: true, audioOrdinal: 1 },
])

assert.deepEqual(resolveFinalManifest([
  { index: 1, title: 'PC Audio', isMuted: false },
  { index: 2, title: 'Microphone', isMuted: true },
], [
  { index: 1, codecName: 'aac' },
  { index: 2, codecName: 'aac' },
]), [
  { index: 1, title: 'PC Audio', isMuted: false, audioOrdinal: 0 },
  { index: 2, title: 'Microphone', isMuted: true, audioOrdinal: 1 },
])

console.log('PASS native audio edit absolute-index manifest mapping')

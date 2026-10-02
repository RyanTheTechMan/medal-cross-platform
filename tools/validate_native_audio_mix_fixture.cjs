'use strict'
// Offline validation of files made by the actual native PCM graph + AAC + MP4
// writer. This does not claim permissioned HAL/SCK or imported GUI coverage.
const fs = require('node:fs/promises'), path = require('node:path'), assert = require('node:assert/strict')
const {runTool} = require('../client_patch/native-audio-media.cjs')
async function main() {
  const [media, mode, directory] = process.argv.slice(2)
  assert(media && ['single', 'multiple'].includes(mode) && directory)
  await fs.mkdir(directory)
  const report = {status: 'failed', file: path.resolve(media), mode, commands: [], node: process.version}
  const run = async (tool, args, opts) => {report.commands.push({tool, args}); return runTool(tool, args, opts)}
  try {
    const probe = JSON.parse(await run('/opt/homebrew/bin/ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', report.file]))
    report.ffprobe = probe
    report.avfoundation = JSON.parse(await run(path.resolve('build-macos-20260925/native/backends/macos/native_port_macos_avfoundation_file_probe'), [report.file]))
    assert.equal(report.avfoundation.status, 'passed')
    const audio = probe.streams.filter(s => s.codec_type === 'audio')
    assert.equal(audio.length, mode === 'single' ? 1 : 3)
    assert.deepEqual(audio.map(s => s.disposition.default), mode === 'single' ? [1] : [1, 0, 0])
    assert(audio.every(s => s.codec_name === 'aac' && Number(s.sample_rate) === 48000 && s.channels === 2))
    report.signals = []
    for (const stream of audio) {
      const bytes = await run('/opt/homebrew/bin/ffmpeg', ['-v', 'error', '-i', report.file, '-map', `0:${stream.index}`, '-af', 'pan=mono|c0=c0', '-ar', '48000', '-f', 'f32le', '-'], {maxOutput: 16 * 1024 * 1024})
      assert(bytes.length >= 48000 * 4, 'Positive PCM sample count required')
      const segments = []
      for (const [start, end] of [[.06, .18], [.5, .9], [1.2, 1.8]]) {
        const first = Math.max(0, Math.ceil((start - Number(stream.start_time)) * 48000)), last = Math.floor((end - Number(stream.start_time)) * 48000)
        const bins = {440: [0,0], 660: [0,0], 880: [0,0]}; let sum = 0, peak = 0
        assert(first >= 0 && last * 4 <= bytes.length)
        for (let i = first; i < last; ++i) {
          const value = bytes.readFloatLE(i * 4); assert(Number.isFinite(value)); sum += value * value; peak = Math.max(peak, Math.abs(value))
          for (const [hz, bin] of Object.entries(bins)) {const phase = 2 * Math.PI * Number(hz) * i / 48000; bin[0] += value * Math.cos(phase); bin[1] += value * Math.sin(phase)}
        }
        segments.push({start, end, count: last-first, peak, rms: Math.sqrt(sum/(last-first)), tones: Object.fromEntries(Object.entries(bins).map(([hz,bin])=>[hz,2*Math.hypot(...bin)/(last-first)]))})
      }
      report.signals.push({index: stream.index, samples: bytes.length/4, segments})
    }
    const master = report.signals[0]
    assert(master.segments[0].tones[660] < .005, 'Delayed microphone must not appear early')
    for (const segment of master.segments.slice(1)) {
      assert(Math.abs(segment.tones[440] - .05) < .008, 'PC gain must be applied once')
      assert(Math.abs(segment.tones[660] - .1) < .008, 'Microphone joins actual master at its own gain')
      assert(segment.tones[880] < .003)
    }
    if (mode === 'multiple') {
      assert(report.signals[1].segments[1].tones[660] < .003 && report.signals[2].segments[1].tones[440] < .003)
      assert(Math.abs(report.signals[1].segments[1].tones[440] - .05) < .008)
      assert(Math.abs(report.signals[2].segments[1].tones[660] - .1) < .008)
    }
    report.status = 'passed'; console.log(`PASS ${mode}: native master tones/gains, delayed mic, isolated stems, default selection, ffprobe and AVFoundation`)
  } catch (error) {report.error = String(error); throw error}
  finally {await fs.writeFile(path.join(directory, 'results.json'), JSON.stringify(report, null, 2))}
}
main().catch(error => {console.error(error); process.exitCode = 1})

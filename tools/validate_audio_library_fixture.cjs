'use strict'
// Read-only postcondition check for an explicitly identified synthetic UI clip.
const fs = require('node:fs/promises'), path = require('node:path'), cp = require('node:child_process')
const assert = require('node:assert/strict'), crypto = require('node:crypto')
const { runTool } = require('../client_patch/native-audio-media.cjs')
async function main() {
  const [database, uuid, original, destination, expectSilent] = process.argv.slice(2)
  assert(database && /^[a-f0-9-]{36}$/.test(uuid) && original && destination)
  await fs.mkdir(destination) // New report per attempt, including failures.
  const report = { uuid, status: 'failed', commands: [], environment: { node: process.version, platform: process.platform } }
  const run = async (tool, args, options) => { report.commands.push({ tool, args }); return runTool(tool, args, options) }
  try {
    const row = JSON.parse(cp.execFileSync('/usr/bin/sqlite3', ['-readonly', database,
      `select json_object('uuid',local_content_id,'video_path',video_path,'thumbnail_path',thumbnail_path,'audioStreams',json_extract(metadata,'$.audioStreams')) from contents where local_content_id='${uuid}';`], { encoding: 'utf8' }))
    report.content = row
    assert(row.video_path && await fs.stat(row.thumbnail_path), 'Persisted video and thumbnail required')
    const file = row.video_path
    const probe = JSON.parse(await run('/opt/homebrew/bin/ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file]))
    report.ffprobe = probe
    report.avfoundation = JSON.parse(await run(path.resolve('build-macos-20260925/native/backends/macos/native_port_macos_avfoundation_file_probe'), [file]))
    assert.equal(report.avfoundation.status, 'passed')
    const audio = probe.streams.filter(s => s.codec_type === 'audio')
    assert.deepEqual(audio.map(s => s.index), row.audioStreams.map(s => s.index))
    assert.equal(audio[0].disposition.default, 1)
    assert(audio.slice(1).every(s => s.disposition.default === 0))
    report.signals = []
    for (const stream of audio) {
      const bytes = await run('/opt/homebrew/bin/ffmpeg', ['-v', 'error', '-i', file, '-map', `0:${stream.index}`, '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'], { maxOutput: 32 * 1024 * 1024 })
      let peak = 0, sum = 0; const tones = { 440: [0, 0], 660: [0, 0] }
      assert(bytes.length > 48000 * 4)
      for (let i = 0; i < bytes.length / 4; ++i) {
        const x = bytes.readFloatLE(i * 4); peak = Math.max(peak, Math.abs(x)); sum += x * x
        if (i >= 24000 && i < 72000) for (const [hz, bins] of Object.entries(tones)) {
          bins[0] += x * Math.cos(2 * Math.PI * Number(hz) * (i - 24000) / 48000)
          bins[1] += x * Math.sin(2 * Math.PI * Number(hz) * (i - 24000) / 48000)
        }
      }
      report.signals.push({ index: stream.index, samples: bytes.length / 4, peak,
        rms: Math.sqrt(sum / (bytes.length / 4)), tones: Object.fromEntries(Object.entries(tones).map(([hz, bins]) => [hz, 2 * Math.hypot(...bins) / 48000])) })
    }
    assert.equal(row.audioStreams[0].title, 'All Audio')
    if (expectSilent === 'silent') assert.equal(report.signals[0].peak, 0)
    if (expectSilent === 'audible') assert(report.signals[0].tones[440] > .05 && report.signals[0].tones[660] > .05)
    const hashes = async (media, stream) => JSON.parse(await run('/opt/homebrew/bin/ffprobe', ['-v', 'error', '-select_streams', stream,
      '-show_packets', '-show_data_hash', 'sha256', '-show_entries', 'packet=data_hash', '-of', 'json', media])).packets.map(p => p.data_hash)
    assert.deepEqual(await hashes(original, 'v:0'), await hashes(file, 'v:0'))
    assert.deepEqual(await hashes(original, 'a:0'), await hashes(file, 'a:1'))
    assert.deepEqual(await hashes(original, 'a:1'), await hashes(file, 'a:2'))
    report.sha256 = crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex')
    report.status = 'passed'
    console.log(`PASS ${uuid}: persisted media, thumbnail, AVFoundation, ffprobe, PCM ${expectSilent}, unchanged video/stems`)
  } catch (error) { report.error = String(error); throw error }
  finally { await fs.writeFile(path.join(destination, 'results.json'), JSON.stringify(report, null, 2)) }
}
main().catch(error => { console.error(error); process.exitCode = 1 })

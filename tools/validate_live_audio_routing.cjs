'use strict'
// Read-only validation of an explicitly named synthetic clip created by Medal's
// normal hotkey/contentCreate path. Never discovers or exports other user media.
const fs = require('node:fs/promises'), path = require('node:path'), cp = require('node:child_process')
const assert = require('node:assert/strict'), crypto = require('node:crypto')
const {runTool} = require('../client_patch/native-audio-media.cjs')

async function main() {
  const [database, uuid, expectation, destination, endpointGate] = process.argv.slice(2)
  assert(database && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(uuid) && destination)
  assert(endpointGate === undefined || endpointGate === '--require-endpoint-coverage')
  const expected = JSON.parse(expectation)
  assert(Array.isArray(expected) && expected.length > 0)
  await fs.mkdir(destination) // Refuse reuse: failed attempts remain evidence.
  const report = {uuid, expected, status: 'failed', commands: [],
    invocation: {tool: process.execPath, args: process.argv.slice(1)},
    environment: {node: process.version, platform: process.platform, architecture: process.arch}}
  const run = async (tool, args, options) => {report.commands.push({tool, args}); return runTool(tool, args, options)}
  try {
    const sql = `select json_object('uuid',local_content_id,'video_path',video_path,'thumbnail_path',thumbnail_path,'audioStreams',json_extract(metadata,'$.audioStreams')) from contents where local_content_id='${uuid}';`
    report.commands.push({tool: '/usr/bin/sqlite3', args: ['-readonly', database, sql]})
    const row = report.content = JSON.parse(cp.execFileSync('/usr/bin/sqlite3', ['-readonly', database, sql], {encoding: 'utf8'}))
    assert(row.video_path && path.isAbsolute(row.video_path) && row.thumbnail_path)
    assert((await fs.stat(row.thumbnail_path)).size > 0, 'Original Medal thumbnail required')
    report.fileSha256 = crypto.createHash('sha256').update(await fs.readFile(row.video_path)).digest('hex')
    report.thumbnailSha256 = crypto.createHash('sha256').update(await fs.readFile(row.thumbnail_path)).digest('hex')
    report.ffprobe = JSON.parse(await run('/opt/homebrew/bin/ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', row.video_path]))
    report.avfoundation = JSON.parse(await run(path.resolve('build-macos-20260925/native/backends/macos/native_port_macos_avfoundation_file_probe'), [row.video_path]))
    assert.equal(report.avfoundation.status, 'passed')
    const audio = report.ffprobe.streams.filter(s => s.codec_type === 'audio')
    assert.equal(report.ffprobe.streams.filter(s => s.codec_type === 'video').length, 1)
    assert.equal(audio.length, expected.length)
    assert.deepEqual(audio.map(s => s.index), row.audioStreams.map(s => s.index))
    assert.deepEqual(row.audioStreams.map(s => s.logicalId), expected.map(s => s.logicalId))
    assert.equal(row.audioStreams[0].title, 'All Audio')
    assert.deepEqual(audio.map(s => s.disposition.default), audio.map((_, i) => i === 0 ? 1 : 0))
    const video = report.ffprobe.streams.find(s => s.codec_type === 'video')
    assert.equal(video.codec_name, 'h264')
    report.containerAudioTailRelativeToVideoSeconds = audio.map(s => ({index: s.index,
      delta: Number(s.start_time) + Number(s.duration) - Number(video.start_time) - Number(video.duration)}))
    const packets = JSON.parse(await run('/opt/homebrew/bin/ffprobe', ['-v', 'error', '-show_packets',
      '-show_entries', 'packet=stream_index,pts_time,dts_time,duration_time,flags', '-of', 'json', row.video_path])).packets
    report.packetTimelines = report.ffprobe.streams.map(s => {
      const selected = packets.filter(p => p.stream_index === s.index)
      assert(selected.length > 0)
      for (let i = 0; i < selected.length; ++i) {
        assert.equal(selected[i].pts_time, selected[i].dts_time, 'PTS/DTS must preserve no-B-frame capture')
        if (i) assert(Number(selected[i].pts_time) >= Number(selected[i - 1].pts_time))
      }
      return {index: s.index, count: selected.length, first: selected[0], last: selected.at(-1),
        end: Math.max(...selected.map(p => Number(p.pts_time) + Number(p.duration_time)))}
    })
    const videoTimeline = report.packetTimelines.find(t => t.index === video.index)
    assert(videoTimeline.first.flags.includes('K'), 'Replay must start independently decodable')
    report.audioTailRelativeToVideoSeconds = audio.map(s => ({index: s.index,
      delta: report.packetTimelines.find(t => t.index === s.index).end - videoTimeline.end}))
    if (endpointGate) assert(report.audioTailRelativeToVideoSeconds.every(t =>
      t.delta >= -0.00001 && t.delta <= 1024 / 48000 + 0.00001),
      'Every required AAC track must cover the fixed video endpoint within one AAC packet')
    report.signals = []
    for (let ordinal = 0; ordinal < audio.length; ++ordinal) {
      const stream = audio[ordinal], required = expected[ordinal]
      assert.equal(stream.codec_name, 'aac'); assert.equal(Number(stream.sample_rate), 48000)
      // Inspect one channel, not ffmpeg's equal-power stereo downmix (which
      // boosts identical stereo tones and would give a false gain failure).
      const bytes = await run('/opt/homebrew/bin/ffmpeg', ['-v', 'error', '-i', row.video_path,
        '-map', `0:${stream.index}`, '-af', 'pan=mono|c0=c0', '-ar', '48000', '-f', 'f32le', '-'], {maxOutput: 64 * 1024 * 1024})
      const samples = bytes.length / 4
      assert(samples > 3 * 48000, 'Positive decoded PCM count required')
      if (required.digitalSilence) {
        for (let i = 0; i < samples; ++i) assert.equal(bytes.readFloatLE(i * 4), 0, 'Muted master must be digital zero')
      }
      const starts = [1, Math.floor(samples / 48000 / 2), Math.floor(samples / 48000) - 2]
      const segments = starts.map(start => {
        const first = start * 48000, count = 48000
        assert(first + count <= samples)
        let peak = 0, sum = 0
        const bins = {440: [0, 0], 660: [0, 0], 880: [0, 0]}
        for (let i = 0; i < count; ++i) {
          const x = bytes.readFloatLE((first + i) * 4)
          assert(Number.isFinite(x)); peak = Math.max(peak, Math.abs(x)); sum += x * x
          for (const [hz, bin] of Object.entries(bins)) {
            const angle = 2 * Math.PI * Number(hz) * i / 48000
            bin[0] += x * Math.cos(angle); bin[1] += x * Math.sin(angle)
          }
        }
        return {startSeconds: start, samples: count, peak, rms: Math.sqrt(sum / count),
          tones: Object.fromEntries(Object.entries(bins).map(([hz, bin]) => [hz, 2 * Math.hypot(...bin) / count]))}
      })
      report.signals.push({index: stream.index, logicalId: required.logicalId, samples, segments})
      for (const segment of segments) for (const [hz, amplitude] of Object.entries(required.tones)) {
        const measured = segment.tones[hz]
        assert(amplitude === 0 ? measured < .003 : Math.abs(measured - amplitude) < Math.max(.008, amplitude * .2),
          `${required.logicalId} ${hz} Hz @ ${segment.startSeconds}s: expected ${amplitude}, measured ${measured}`)
      }
    }
    report.status = 'passed'
    console.log(`PASS ${uuid}: original library path/thumbnail, native decode, independent probe, source tones/gains/defaults`)
    // GUI playback and restart are deliberately separate manual evidence.
  } catch (error) {report.error = String(error); throw error}
  finally {await fs.writeFile(path.join(destination, 'results.json'), JSON.stringify(report, null, 2))}
}
main().catch(error => {console.error(error); process.exitCode = 1})

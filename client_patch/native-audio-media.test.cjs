'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs/promises')
const path = require('node:path')
const crypto = require('node:crypto')
const { createAudioMedia, audioManifest, mergeClientProbeAudio, byteRange, runTool } = require('./native-audio-media.cjs')
const { createNativeAudioEditor } = require('./native-audio-editor.js')

async function main() {
  const root = path.resolve(process.argv[2] || '')
  assert(process.argv[2], 'Supply a NEW evidence directory')
  await fs.mkdir(root) // Refuse to overwrite prior evidence.
  const calls = [], checks = [], signals = {}
  const execute = async (tool, args, options) => { calls.push({ tool, args }); return runTool(tool, args, options) }
  const check = (name, test) => { assert(test, name); checks.push(name) }
  const tools = process.env.NATIVE_AUDIO_TEST_TOOLS || '/opt/homebrew/bin'
  const input = path.join(root, 'stems.mp4')
  const ffmpeg = path.join(tools, 'ffmpeg'), ffprobe = path.join(tools, 'ffprobe')
  const rows = new Map()
  let record = { local_content_id: 'audio-fixture-20260925', video_path: input, metadata: {
    audioStreams: [{ index: 1, title: 'PC Audio', logicalId: 'pc-audio' }, { index: 2, title: 'Microphone', logicalId: 'microphone' }] } }
  rows.set(record.local_content_id, record)
  const options = { tools, cacheDirectory: path.join(root, 'cache'), getContent: async id => rows.get(id),
    getEditDirectory: async () => path.join(root, 'Edits'), execute }
  const service = createAudioMedia(options)
  try {
    await execute(ffmpeg, ['-v', 'error', '-nostdin', '-n', '-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=15:d=3',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=3',
      '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000:duration=3',
      '-map', '0:v', '-map', '1:a', '-map', '2:a', '-c:v', 'libx264', '-bf', '0', '-threads', '1', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '128k', input])
    const originalHash = crypto.createHash('sha256').update(await fs.readFile(input)).digest('hex')
    const packets = async (file, selector) => JSON.parse((await execute(ffprobe, ['-v', 'error', '-select_streams', selector,
      '-show_packets', '-show_data_hash', 'sha256', '-show_entries', 'packet=data_hash', '-of', 'json', file])).toString()).packets.map(p => p.data_hash)
    const pcm = async (file, index) => {
      const bytes = await execute(ffmpeg, ['-v', 'error', '-i', file, '-map', `0:${index}`, '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'], { maxOutput: 16 * 1024 * 1024 })
      const count = bytes.length / 4; assert(count > 48000, 'Positive decoded sample count required')
      let peak = 0, sum = 0; const samples = []
      for (let i = 0; i < count; ++i) { const x = bytes.readFloatLE(i * 4); peak = Math.max(peak, Math.abs(x)); sum += x * x; if (i >= 24000 && i < 72000) samples.push(x) }
      const tones = {}
      for (const hz of [440, 660]) {
        let re = 0, im = 0
        samples.forEach((x, i) => { re += x * Math.cos(2 * Math.PI * hz * i / 48000); im += x * Math.sin(2 * Math.PI * hz * i / 48000) })
        tones[hz] = 2 * Math.hypot(re, im) / samples.length
      }
      return { count, peak, rms: Math.sqrt(sum / count), tones }
    }
    const edit = async (muted, label) => {
      const output = await service.trim({ uuid: record.local_content_id, expectedPath: record.video_path,
        audioStreams: record.metadata.audioStreams.map(s => ({ index: s.index, isMuted: muted.includes(s.title) })) })
      signals[label] = await pcm(output.outputPath, 1)
      check(`${label}: fresh output manifest`, output.audioStreams.map(s => s.index).join() === '1,2,3')
      check(`${label}: preserved video packets`, JSON.stringify(await packets(input, 'v:0')) === JSON.stringify(await packets(output.outputPath, 'v:0')))
      check(`${label}: preserved PC packets`, JSON.stringify(await packets(input, 'a:0')) === JSON.stringify(await packets(output.outputPath, 'a:1')))
      check(`${label}: preserved mic packets`, JSON.stringify(await packets(input, 'a:1')) === JSON.stringify(await packets(output.outputPath, 'a:2')))
      record = { ...record, video_path: output.outputPath, metadata: { ...record.metadata, audioStreams: output.audioStreams } }
      rows.set(record.local_content_id, record)
      return output
    }
    await edit(['PC Audio'], 'mute-pc-migration')
    check('migration excludes PC, retains mic in master', signals['mute-pc-migration'].tones[440] < .001 && signals['mute-pc-migration'].tones[660] > .05)
    await edit(['PC Audio', 'Microphone'], 'mute-both')
    check('all muted master is digital silence with samples', signals['mute-both'].peak === 0)
    await edit([], 'unmute-after-save')
    check('saved stems can both be unmuted', signals['unmute-after-save'].tones[440] > .05 && signals['unmute-after-save'].tones[660] > .05)
    await edit(['Microphone'], 'mute-mic')
    check('mic-only mute preserves PC', signals['mute-mic'].tones[660] < .001 && signals['mute-mic'].tones[440] > .05)
    check('original unchanged', originalHash === crypto.createHash('sha256').update(await fs.readFile(input)).digest('hex'))
    const preview = await service.prepare({ uuid: record.local_content_id, expectedPath: record.video_path })
    check('master excluded from audition', preview.streams.length === 2 && preview.streams.every(s => s.title !== 'All Audio'))
    for (const source of preview.streams) {
      const asset = service.asset(source.url)
      const ordinal = source.title === 'PC Audio' ? 'a:0' : 'a:1'
      check(`sidecar packets preserved: ${source.title}`, JSON.stringify(await packets(asset, 'a:0')) === JSON.stringify(await packets(input, ordinal)))
    }
    service.release(preview.lease)
    assert.throws(() => service.asset(preview.streams[0].url), /Expired/)
    const delayedPath = path.join(root, 'delayed.mp4')
    await execute(ffmpeg, ['-v', 'error', '-nostdin', '-n', '-i', input, '-itsoffset', '1.2', '-i', input,
      '-map', '0:v:0', '-map', '0:a:0', '-map', '1:a:1', '-c', 'copy', delayedPath])
    const delayedId = 'delayed-audio-fixture'
    rows.set(delayedId, { local_content_id: delayedId, video_path: delayedPath, metadata: {} })
    const delayedProbe = await service.probe(delayedPath)
    const delayed = await service.prepare({ uuid: delayedId })
    const delayedSource = delayed.streams[1], delayedFile = service.asset(delayedSource.url)
    check('delayed source retains measured timeline offset', delayedSource.offset > 1 &&
      Math.abs(delayedSource.offset - Number(delayedProbe.streams[2].start_time)) < .001)
    check('delayed sidecar starts at zero', Math.abs(Number((await service.probe(delayedFile)).streams[0].start_time)) < .001)
    check('delayed source AAC packets unchanged', JSON.stringify(await packets(delayedPath, 'a:1')) === JSON.stringify(await packets(delayedFile, 'a:0')))
    service.release(delayed.lease)
    await assert.rejects(service.prepare({ uuid: '../escape', expectedPath: input }), /Invalid/)
    await assert.rejects(service.trim({ uuid: record.local_content_id, expectedPath: input }), /changed/)
    await assert.rejects(service.trim({ uuid: record.local_content_id, audioStreams: [{ index: 0 }] }), /Invalid/)
    await assert.rejects(service.trim({ uuid: record.local_content_id, audioStreams: [{ index: 2 }, { index: 2 }] }), /Invalid/)
    checks.push('expired assets/path traversal/stale source/non-audio/duplicate selections rejected')
    const info = { streams: [{ index: 0, codec_type: 'video' }, { index: 4, codec_type: 'audio' }, { index: 7, codec_type: 'audio' }] }
    check('arbitrary absolute indexes preserved', audioManifest(info, [{ index: 7, title: 'Mic' }]).map(s => s.index).join() === '4,7')
    check('missing labels retained', audioManifest(info).length === 2)
    assert.throws(() => mergeClientProbeAudio([{ index: 1 }], [{ index: 0 }]), { code: 'NATIVE_INVALID_AUDIO_MANIFEST' })
    check('native master metadata survives actual original-client merge', mergeClientProbeAudio([{ index: 1, codecName: 'aac' }],
      [{ index: 1, title: 'All Audio', logicalId: 'all-audio', default: true }])[0].default)
    assert.throws(() => audioManifest(info, [{ index: 4 }, { index: 4 }]), /Invalid/)
    assert.throws(() => audioManifest(info, [{ index: 0 }]), /Invalid/)
    assert.deepEqual(byteRange('bytes=-20', 100), { start: 80, end: 99, statusCode: 206 })
    assert.deepEqual(byteRange('bytes=80-', 100), { start: 80, end: 99, statusCode: 206 })
    assert.throws(() => byteRange('bytes=100-', 100))
    assert.throws(() => byteRange('bytes=0-2,4-5', 100))
    checks.push('manifest and range validation')
    for (const failure of ['ffmpeg', 'ffprobe']) {
      const broken = createAudioMedia({ ...options, execute: async (tool, args) => {
        if (path.basename(tool) === failure && (failure !== 'ffprobe' || args.at(-1).endsWith('result.mp4'))) throw new Error(`Injected ${failure} failure`)
        return execute(tool, args)
      } })
      await assert.rejects(broken.trim({ uuid: record.local_content_id }), /Injected/)
      check(`${failure} failure preserves source`, (await fs.stat(record.video_path)).size > 0)
    }
    // Exercise the shipped renderer transaction with failure injection, not a formula clone.
    let rejectUpdate = false, corruptReadback = false, committed = 0, callbackError
    const ipc = {
      getContents: async ({ localContentId }) => ({ contents: [structuredClone(rows.get(localContentId))] }),
      trimVideo: p => service.trim({ uuid: p.nativeContentId, expectedPath: p.videoPath,
        startTime: p.startTime, duration: p.duration, audioStreams: p.audioStreams }),
      updateContent: async ({ local_content_id }, change) => {
        if (rejectUpdate) return { changes: 0 }
        rows.set(local_content_id, { ...rows.get(local_content_id), ...structuredClone(change), ...(corruptReadback ? { video_path: '/bad-readback' } : {}) })
        corruptReadback = false
        return { changes: 1 }
      },
      insertContentRaw: async row => { rows.set(row.local_content_id, structuredClone(row)); return {} },
    }
    const clip = { content: record, currentAudioStreams: record.metadata.audioStreams, getUUID: () => record.local_content_id, getDuration: () => 3 }
    const editor = createNativeAudioEditor({ ipc, onCommitted: () => ++committed, trimMetadata: () => ({}), rebaseBookmarks: () => [], gameName: () => 'Synthetic' })
    const originalContent = clip.content
    rejectUpdate = true
    await editor.edit(clip, {}, error => { callbackError = error })
    check('failed library update reported and UI state unchanged', callbackError && committed === 0 && clip.content === originalContent)
    rejectUpdate = false; corruptReadback = true; callbackError = undefined
    await editor.edit(clip, {}, error => { callbackError = error })
    check('failed readback rolled back, UI unchanged', callbackError && clip.content === originalContent && rows.get(record.local_content_id).video_path === originalContent.video_path)
    const copied = await editor.copy(clip, { startTime: 0, duration: 3,
      audioStreams: [{ index: 2, isMuted: true }, { index: 3, isMuted: true }] })
    check('Save Copy has separate UUID and retains original reference', copied.local_content_id !== record.local_content_id && rows.get(record.local_content_id).video_path === originalContent.video_path)
    check('Save Copy all muted master', (await pcm(copied.video_path, 1)).peak === 0)
    check('Save Copy zero/full range preserves AAC priming packets',
      JSON.stringify(await packets(input, 'a:0')) === JSON.stringify(await packets(copied.video_path, 'a:1')))
    await editor.edit(clip, { audioStreams: [{ index: 2, isMuted: false }, { index: 3, isMuted: false }] })
    check('overwrite commits fresh path and output manifest', clip.content.video_path !== originalContent.video_path && clip.currentAudioStreams === clip.content.metadata.audioStreams)
    console.log(`PASS ${checks.length} fixed-behavior checks (real FFmpeg; mocked client persistence, not GUI/native capture)`)
  } finally {
    await fs.writeFile(path.join(root, 'results.json'), JSON.stringify({ checks, signals, calls, environment: { node: process.version, platform: process.platform } }, null, 2))
  }
}
main().catch(error => { console.error(error); process.exitCode = 1 })

'use strict'

// Native client media adapter. Recording stays in C++; this module only probes,
// copies source AAC for audition and edits finalized library files.
const fs = require('node:fs/promises')
const path = require('node:path')
const crypto = require('node:crypto')
const { spawn } = require('node:child_process')

function runTool(executable, args, { timeout = 180000, maxOutput = 8 * 1024 * 1024 } = {}) {
  if (!path.isAbsolute(executable)) throw new Error('Media tool must have an absolute packaged path')
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { shell: false, stdio: ['ignore', 'pipe', 'pipe'] })
    const chunks = []; let bytes = 0; let stderr = ''; let failure
    const stop = message => { failure ||= new Error(message); child.kill('SIGKILL') }
    const timer = setTimeout(() => stop('Media tool timed out'), timeout)
    child.stdout.on('data', chunk => {
      bytes += chunk.length
      if (bytes > maxOutput) stop('Media tool output exceeded its limit')
      else chunks.push(chunk)
    })
    child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-4000) })
    child.once('error', error => { failure = error })
    child.once('close', code => {
      clearTimeout(timer)
      if (failure || code !== 0) reject(failure || new Error(`Media tool failed (${code}): ${stderr.trim()}`))
      else resolve(Buffer.concat(chunks))
    })
  })
}

function audioManifest(probe, metadata = [], { allowLegacyOrdinals = false } = {}) {
  const audio = probe.streams.filter(s => s.codec_type === 'audio')
  if (audio.length > 16 || audio.some(s => !Number.isInteger(s.index))) throw new Error('Invalid audio layout')
  const actual = new Set(audio.map(s => s.index)); const labels = new Map()
  // Repair only the recognized old recorder bug, using trusted library metadata:
  // a complete 0..N-1 audio array whose indexes cannot be absolute audio indexes.
  const legacyOrdinals = allowLegacyOrdinals && metadata.length === audio.length && metadata.every((s, i) => s.index === i) &&
    metadata.some(s => !actual.has(s.index))
  for (const [ordinal, row] of metadata.entries()) {
    const index = legacyOrdinals ? audio[ordinal].index : row.index
    if (!Number.isInteger(index) || !actual.has(index) || labels.has(index)) throw new Error('Invalid library audio manifest')
    labels.set(index, row)
  }
  return audio.map((stream, ordinal) => {
    const row = labels.get(stream.index)
    const title = row?.title || stream.tags?.title || stream.tags?.handler_name
    return {
      index: stream.index, audioOrdinal: ordinal, requestIndex: legacyOrdinals ? ordinal : stream.index,
      title: typeof title === 'string' && title.trim() && title !== 'SoundHandler' ? title.trim() : `Audio Stream #${ordinal + 1}`,
      logicalId: row?.logicalId, isMuted: row?.isMuted === true,
      codecName: stream.codec_name, sampleRate: Number(stream.sample_rate), channels: stream.channels,
      startTime: Number(stream.start_time || 0), default: stream.disposition?.default === undefined ? row?.default === true : stream.disposition.default === 1,
    }
  })
}

function libraryMetadata(value) {
  // Original main::wi returns JSON text; the original preload::y parses it for
  // renderer callers. Our privileged media service calls wi directly and must
  // perform that same boundary conversion before reading the trusted manifest.
  if (value === undefined) return {}
  if (typeof value === 'string') {
    if (Buffer.byteLength(value) > 4 * 1024 * 1024) throw new Error('Library metadata is too large')
    try { value = JSON.parse(value) } catch { throw new Error('Invalid library metadata JSON') }
  }
  if (!value || typeof value !== 'object' || Array.isArray(value) || Buffer.isBuffer(value) ||
      (value.audioStreams !== undefined && !Array.isArray(value.audioStreams))) {
    throw new Error('Invalid library metadata shape')
  }
  return value
}

function createAudioMedia({ tools, cacheDirectory, getContent, getEditDirectory, execute = runTool }) {
  const ffmpeg = path.join(tools, 'ffmpeg'); const ffprobe = path.join(tools, 'ffprobe')
  const assets = new Map(); const leases = new Map(); const jobs = new Map(); const edits = new Set()
  let preparing = 0; let preparationTail = Promise.resolve()
  const maxCacheBytes = 512 * 1024 * 1024
  const probe = async input => JSON.parse((await execute(ffprobe,
    ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', input])).toString())
  async function resolveContent(uuid, expectedPath) {
    if (typeof uuid !== 'string' || !/^[A-Za-z0-9_-]{6,128}$/.test(uuid)) throw new Error('Invalid local content ID')
    const rawContent = await getContent(uuid)
    const content = rawContent && {...rawContent, metadata: libraryMetadata(rawContent.metadata)}
    if (!content || content.local_content_id !== uuid || !path.isAbsolute(content.video_path || '')) {
      throw new Error('Local library video was not found')
    }
    const input = await fs.realpath(content.video_path)
    if (expectedPath && (typeof expectedPath !== 'string' || !path.isAbsolute(expectedPath) ||
        await fs.realpath(expectedPath) !== input)) throw new Error('The clip changed; reopen it before editing')
    const stat = await fs.stat(input, { bigint: true })
    if (!stat.isFile()) throw new Error('Library media is not a regular file')
    const identity = [input, stat.dev, stat.ino, stat.size, stat.mtimeNs].join('\0')
    const media = await probe(input)
    return { uuid, content, input, identity, media, audio: audioManifest(media, content.metadata?.audioStreams || [], { allowLegacyOrdinals: true }) }
  }
  async function unchanged(resolved) {
    const content = await getContent(resolved.uuid)
    if (content?.video_path !== resolved.content.video_path) throw new Error('Library clip changed during the operation')
    const stat = await fs.stat(resolved.input, { bigint: true })
    if ([resolved.input, stat.dev, stat.ino, stat.size, stat.mtimeNs].join('\0') !== resolved.identity) {
      throw new Error('Media changed during the operation')
    }
  }
  async function trim({ uuid, expectedPath, audioStreams = [], startTime, duration }) {
    if (edits.has(uuid) || edits.size >= 2) throw new Error('Another edit is already running; wait for it to finish')
    edits.add(uuid)
    let temporary
    try {
      const resolved = await resolveContent(uuid, expectedPath)
      const video = resolved.media.streams.find(s => s.codec_type === 'video')
      if (!video) throw new Error('The clip has no video')
      for (const [key, value] of Object.entries({ startTime, duration })) {
        if (value !== undefined && (!Number.isFinite(value) || value < 0 || (key === 'duration' && value === 0))) {
          throw new Error(`Invalid trim ${key}`)
        }
      }
      const masks = new Map()
      if (!Array.isArray(audioStreams)) throw new Error('Invalid audio selection')
      for (const row of audioStreams) {
        if (!Number.isInteger(row.index) || masks.has(row.index) ||
            !resolved.audio.some(s => s.requestIndex === row.index)) throw new Error('Invalid selected audio stream')
        masks.set(row.index, row.isMuted === true)
      }
      const sources = resolved.audio.filter(s => !(s.title === 'All Audio' && resolved.audio.length > 1))
        .map(s => ({ ...s, isMuted: masks.has(s.requestIndex) ? masks.get(s.requestIndex) : s.isMuted }))
      if (sources.some(s => s.codecName !== 'aac')) throw new Error('Native audio editing currently requires AAC sources')
      const directory = await getEditDirectory()
      if (!path.isAbsolute(directory)) throw new Error('Invalid edit directory')
      await fs.mkdir(directory, { recursive: true, mode: 0o700 })
      temporary = await fs.mkdtemp(path.join(directory, '.native-audio-'))
      const staged = path.join(temporary, 'result.mp4')
      const args = ['-v', 'error', '-nostdin', '-n']
      // The original Save Copy supplies start=0/duration=full even for audio-only
      // edits. Input seeking to zero discards negative AAC priming packets.
      const completeVideoDuration = Number(video.duration || resolved.media.format?.duration)
      const trimStart = startTime > 0
      const trimEnd = duration !== undefined && (trimStart || duration < completeVideoDuration - 0.0001)
      if (trimStart) args.push('-ss', String(startTime))
      else args.push('-copyts', '-start_at_zero')
      args.push('-i', resolved.input)
      if (trimEnd) args.push('-t', String(duration))
      if (sources.length) {
        const filters = sources.map((s, i) =>
          `[0:${s.index}]aresample=48000:async=0:first_pts=0,volume=${s.isMuted ? 0 : 1}[source${i}]`)
        filters.push(sources.map((_, i) => `[source${i}]`).join('') +
          `amix=inputs=${sources.length}:normalize=0:duration=longest:dropout_transition=0,alimiter=limit=0.97:level=false:latency=1[master]`)
        args.push('-filter_complex', filters.join(';'), '-map', '0:v:0', '-map', '[master]')
        for (const source of sources) args.push('-map', `0:${source.index}`)
        args.push('-c:v', 'copy', '-c:a', 'copy', '-c:a:0', 'aac', '-b:a:0', '192k', '-ar:a:0', '48000',
          '-disposition:a:0', 'default', '-metadata:s:a:0', 'handler_name=All Audio')
        sources.forEach((s, i) => args.push(`-disposition:a:${i + 1}`, '0', `-metadata:s:a:${i + 1}`, `handler_name=${s.title}`))
      } else args.push('-map', '0:v:0', '-c:v', 'copy')
      args.push('-movflags', '+faststart', '-use_editlist', '1', staged)
      await execute(ffmpeg, args)
      const outputProbe = await probe(staged)
      const outputAudio = outputProbe.streams.filter(s => s.codec_type === 'audio')
      const expectedCount = sources.length ? sources.length + 1 : 0
      const actualDuration = Number(outputProbe.format?.duration)
      if (!outputProbe.streams.some(s => s.codec_type === 'video') || !(actualDuration > 0) ||
          outputAudio.length !== expectedCount || outputAudio.some(s => s.codec_name !== 'aac') ||
          outputAudio.some((s, i) => s.disposition?.default !== (i === 0 ? 1 : 0))) {
        throw new Error('Edited output failed independent layout validation')
      }
      const descriptors = sources.length ? [{ title: 'All Audio', logicalId: 'all-audio', isMuted: false }, ...sources] : []
      const manifest = outputAudio.map((s, i) => ({
        index: s.index, audioOrdinal: i, title: descriptors[i].title,
        logicalId: descriptors[i].logicalId, isMuted: descriptors[i].isMuted,
        codecName: s.codec_name, sampleRate: Number(s.sample_rate), channels: s.channels, default: i === 0,
      }))
      await unchanged(resolved)
      const outputPath = path.join(directory, `${uuid}-audio-${crypto.randomUUID()}.mp4`)
      const file = await fs.open(staged, 'r'); try { await file.sync() } finally { await file.close() }
      await fs.rename(staged, outputPath)
      const stat = await fs.stat(outputPath, { bigint: true })
      return { outputPath, actualDuration, contentSize: Number(stat.size), contentInode: stat.ino.toString(), audioStreams: manifest, nativeAudioEdit: true,
        nativeSourcePath: resolved.content.video_path }
    } finally {
      edits.delete(uuid)
      if (temporary) await fs.rm(temporary, { recursive: true, force: true })
    }
  }
  async function pruneCache(additional = 0) {
    await fs.mkdir(cacheDirectory, { recursive: true, mode: 0o700 })
    const held = new Set([...assets.values()].map(a => a.file))
    const rows = []
    for (const name of await fs.readdir(cacheDirectory)) {
      if (!/^[a-f0-9]{64}\.m4a$/.test(name)) continue
      const file = path.join(cacheDirectory, name); const stat = await fs.lstat(file)
      if (stat.isFile()) rows.push({ file, size: stat.size, time: stat.mtimeMs })
    }
    let size = rows.reduce((n, r) => n + r.size, additional); let count = rows.length
    for (const row of rows.sort((a, b) => a.time - b.time)) {
      if (size <= maxCacheBytes && count < 128) break
      if (!held.has(row.file)) { await fs.unlink(row.file); size -= row.size; --count }
    }
    if (size > maxCacheBytes) throw new Error('Audio preview cache is full')
  }
  async function sidecar(resolved, source) {
    const key = crypto.createHash('sha256').update(`${resolved.identity}\0${source.index}\0${source.startTime}`).digest('hex')
    const output = path.join(cacheDirectory, `${key}.m4a`)
    if (!jobs.has(key)) jobs.set(key, (async () => {
      try { if ((await fs.lstat(output)).isFile()) return output } catch {}
      if (jobs.size >= 4) throw new Error('Audio preview preparation is busy')
      const temp = await fs.mkdtemp(path.join(cacheDirectory, '.extract-'))
      try {
        const file = path.join(temp, 'audio.m4a')
        // Normalize each single-track file to zero and return its measured offset
        // separately. Chromium may otherwise jump to a nonzero seekable start and
        // play a late microphone early relative to the video clock.
        await execute(ffmpeg, ['-v', 'error', '-nostdin', '-n', '-copyts', '-itsoffset', String(-source.startTime), '-i', resolved.input,
          '-map', `0:${source.index}`, '-vn', '-c:a', 'copy', '-use_editlist', '1', '-movflags', '+faststart', file])
        const size = (await fs.stat(file)).size
        if (size > maxCacheBytes / 2) throw new Error('Audio preview source is too large')
        await pruneCache(size)
        await fs.rename(file, output)
        return output
      } finally { await fs.rm(temp, { recursive: true, force: true }) }
    })().finally(() => jobs.delete(key)))
    return jobs.get(key)
  }
  async function prepareOne({ uuid, expectedPath }) {
    if (leases.size >= 4) throw new Error('Too many audio previews are open')
    const resolved = await resolveContent(uuid, expectedPath)
    await pruneCache()
    const lease = crypto.randomUUID(); const tokens = []
    leases.set(lease, tokens)
    try {
      const streams = []
      for (const source of resolved.audio.filter(s => !(s.title === 'All Audio' && resolved.audio.length > 1))) {
        if (source.codecName !== 'aac') throw new Error('Audio audition currently requires AAC')
        const file = await sidecar(resolved, source)
        const info = await probe(file); const stream = info.streams.find(s => s.codec_type === 'audio')
        if (!stream || info.streams.length !== 1) throw new Error('Invalid audition sidecar')
        const token = crypto.randomBytes(32).toString('hex')
        assets.set(token, { file, lease }); tokens.push(token)
        streams.push({ ...source, index: source.requestIndex,
          offset: source.startTime - Number(stream.start_time || 0),
          url: `native-audio-preview://asset/${token}.m4a` })
      }
      await unchanged(resolved)
      return { lease, streams, version: crypto.createHash('sha256').update(resolved.identity).digest('hex') }
    } catch (error) { release(lease); throw error }
  }
  function prepare(options) {
    if (preparing >= 4) return Promise.reject(new Error('Audio preview preparation is busy'))
    ++preparing
    const pending = preparationTail.then(() => prepareOne(options)).finally(() => --preparing)
    preparationTail = pending.catch(() => {})
    return pending
  }
  function release(lease) {
    for (const token of leases.get(lease) || []) assets.delete(token)
    leases.delete(lease)
  }
  function asset(url) {
    const parsed = new URL(url)
    if (parsed.protocol !== 'native-audio-preview:' || parsed.host !== 'asset' || parsed.search || parsed.hash ||
        !/^\/[a-f0-9]{64}\.m4a$/.test(parsed.pathname)) throw new Error('Invalid preview asset')
    const item = assets.get(parsed.pathname.slice(1, -4))
    if (!item) throw new Error('Expired preview asset')
    return item.file
  }
  return { trim, prepare, release, asset, probe, resolveContent }
}

function byteRange(header, size) {
  if (!header) return { start: 0, end: size - 1, statusCode: 200 }
  const match = /^bytes=(\d*)-(\d*)$/.exec(header)
  if (!match || !(match[1] || match[2])) throw new Error('Invalid range')
  const start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]))
  const end = match[1] && match[2] ? Math.min(size - 1, Number(match[2])) : size - 1
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= size || end < start) throw new Error('Unsatisfiable range')
  return { start, end, statusCode: 206 }
}

function mergeClientProbeAudio(probed, metadata) {
  try {
    return audioManifest({ streams: probed.map(s => ({ index: s.index, codec_type: 'audio', codec_name: s.codecName,
      sample_rate: s.sampleRate, channels: s.channels, tags: { title: s.title } })) }, metadata || [])
      .map(({ requestIndex, startTime, ...row }, i) => ({ ...probed[i], ...row }))
  } catch (error) { error.code = 'NATIVE_INVALID_AUDIO_MANIFEST'; throw error }
}
module.exports = { createAudioMedia, audioManifest, mergeClientProbeAudio, byteRange, runTool }

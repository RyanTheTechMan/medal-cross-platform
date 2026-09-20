'use strict'

const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const { app, BrowserWindow, ipcMain, protocol } = require('electron')
const { spawn } = require('node:child_process')
const { createReadStream } = require('node:fs')

protocol.registerSchemesAsPrivileged([{
  scheme: 'native-audio-preview',
  privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, corsEnabled: true }
}])

const fail = message => {
  const error = new Error(`Native port bootstrap: ${message}`)
  error.code = 'NATIVE_PORT_BOOTSTRAP_INVALID'
  throw error
}

if (process.platform !== 'darwin' || process.arch !== 'arm64') {
  fail(`this prepared client requires darwin-arm64, got ${process.platform}-${process.arch}`)
}
if (process.versions.electron !== '43.2.0' || process.versions.modules !== '148') {
  fail(`expected Electron 43.2.0 / ABI 148, got Electron ${process.versions.electron} / ABI ${process.versions.modules}`)
}

const configuredProfile = process.env.NATIVE_PORT_PROFILE_DIR
if (configuredProfile && !path.isAbsolute(configuredProfile)) fail('NATIVE_PORT_PROFILE_DIR must be an absolute path')
const profile = configuredProfile || path.join(app.getPath('appData'), 'Native Medal Development Profile')
fs.mkdirSync(profile, { recursive: true, mode: 0o700 })
process.env.NATIVE_PORT_PROFILE_DIR = profile
const isolatedMedia = path.join(profile, 'Media')
fs.mkdirSync(isolatedMedia, { recursive: true, mode: 0o700 })
app.setPath('userData', profile)
app.setPath('sessionData', path.join(profile, 'Session Data'))
app.setPath('logs', path.join(profile, 'Logs'))
app.setPath('videos', isolatedMedia)

const configuredTools = process.env.NATIVE_PORT_TOOLS_DIR
if (configuredTools && !path.isAbsolute(configuredTools)) fail('NATIVE_PORT_TOOLS_DIR must be an absolute path')
const tools = configuredTools || path.join(__dirname, 'tools')
process.env.NATIVE_PORT_TOOLS_DIR = tools
for (const tool of ['ffmpeg', 'ffprobe', 'sqlite3']) {
  const candidate = path.join(tools, tool)
  const stat = fs.statSync(candidate, { throwIfNoEntry: false })
  if (!stat || !stat.isFile() || (stat.mode & 0o111) === 0) fail(`missing executable ${candidate}`)
}

const audioPreviewCache = path.join(profile, 'Audio Preview')
fs.mkdirSync(audioPreviewCache, { recursive: true, mode: 0o700 })
const clipLibrary = path.join(profile, 'Clips')
fs.mkdirSync(clipLibrary, { recursive: true, mode: 0o700 })
const safePreviewUuid = value => typeof value === 'string' && /^[A-Za-z0-9_-]{6,128}$/.test(value)
const resolvePreviewInput = (value, uuid) => {
  if (typeof value !== 'string' || !path.isAbsolute(value)) fail('audio preview path must be absolute')
  const resolved = fs.realpathSync(value)
  const inRoot = root => {
    const relative = path.relative(root, resolved)
    return !relative.startsWith('..') && !path.isAbsolute(relative)
  }
  if (!inRoot(isolatedMedia) && !inRoot(clipLibrary)) fail('audio preview path is outside the isolated clip profile')
  if (!path.basename(resolved).startsWith(`${uuid}.`)) fail('audio preview path is not the requested library UUID')
  if (!fs.statSync(resolved).isFile()) fail('audio preview input is not a file')
  return resolved
}
const runAudioPreviewExtraction = ({ uuid, input, index }) => new Promise((resolve, reject) => {
  const stat = fs.statSync(input)
  const key = crypto.createHash('sha256').update(`${uuid}\0${input}\0${stat.size}\0${stat.mtimeMs}\0${index}`).digest('hex')
  const output = path.join(audioPreviewCache, `${key}.m4a`)
  if (fs.statSync(output, { throwIfNoEntry: false })?.isFile()) {
    resolve({ url: `native-audio-preview://${path.basename(output)}`, generation: key })
    return
  }
  const temporary = `${output}.${process.pid}.${crypto.randomUUID()}.tmp`
  const child = spawn(path.join(tools, 'ffmpeg'), [
    '-v', 'error', '-nostdin', '-y', '-i', input, '-map', `0:${index}`,
    '-vn', '-c:a', 'copy', '-movflags', '+faststart', temporary
  ], { stdio: ['ignore', 'ignore', 'pipe'] })
  let stderr = ''
  child.stderr.on('data', chunk => { stderr += String(chunk).slice(0, 2000) })
  child.once('error', error => { try { fs.unlinkSync(temporary) } catch {}; reject(error) })
  child.once('exit', (code, signal) => {
    if (code !== 0 || signal) {
      try { fs.unlinkSync(temporary) } catch {}
      reject(new Error(`native audio preview extraction failed (${code ?? signal}): ${stderr.trim()}`))
      return
    }
    fs.renameSync(temporary, output)
    resolve({ url: `native-audio-preview://${path.basename(output)}`, generation: key })
  })
})
ipcMain.handle('native-port:audio-preview', async (event, params = {}) => {
  if (!event.sender || event.sender.isDestroyed()) throw new Error('audio preview sender is unavailable')
  if (!safePreviewUuid(params.uuid)) throw new Error('audio preview UUID is invalid')
  if (params.action === 'release') return { released: true }
  if (params.action !== 'prepare') throw new Error('unsupported native audio preview action')
  const index = Number(params.index)
  if (!Number.isInteger(index) || index < 0 || index > 64) throw new Error('audio preview stream index is invalid')
  const input = resolvePreviewInput(params.path, params.uuid)
  return runAudioPreviewExtraction({ uuid: params.uuid, input, index })
})
app.whenReady().then(() => {
  protocol.registerStreamProtocol('native-audio-preview', (request, callback) => {
    try {
      const name = decodeURIComponent(new URL(request.url).pathname.replace(/^\/+/, ''))
      if (!/^[a-f0-9]{64}\.m4a$/.test(name)) throw new Error('invalid audio preview asset')
      const file = path.join(audioPreviewCache, name)
      const relative = path.relative(audioPreviewCache, file)
      const stat = fs.statSync(file)
      if (relative.startsWith('..') || path.isAbsolute(relative) || !stat.isFile()) throw new Error('missing audio preview asset')
      const range = /^bytes=(\d*)-(\d*)$/i.exec(request.headers.range || '')
      let start = 0
      let end = stat.size - 1
      const headers = { 'Content-Type': 'audio/mp4', 'Accept-Ranges': 'bytes' }
      let statusCode = 200
      if (range) {
        start = range[1] ? Number(range[1]) : Math.max(0, stat.size - Number(range[2] || 0))
        end = range[2] ? Number(range[2]) : end
        end = Math.min(end, stat.size - 1)
        if (!Number.isInteger(start) || start < 0 || start > end) throw new Error('invalid audio preview range')
        statusCode = 206
        headers['Content-Range'] = `bytes ${start}-${end}/${stat.size}`
      }
      headers['Content-Length'] = String(end - start + 1)
      callback({ statusCode, headers, data: createReadStream(file, { start, end }) })
    } catch (error) {
      callback({ statusCode: 404, headers: { 'Content-Type': 'text/plain' }, data: Buffer.from(String(error.message || error)) })
    }
  })
})

const recorder = path.join(
  __dirname,
  'bin',
  'NativeMedalRecorder.app',
  'Contents',
  'MacOS',
  'native_medal_recorder'
)
const recorderStat = fs.statSync(recorder, { throwIfNoEntry: false })
if (!recorderStat || !recorderStat.isFile() || (recorderStat.mode & 0o111) === 0) {
  fail(`missing native recorder ${recorder}`)
}
process.env.NATIVE_PORT_RECORDER_EXE = recorder
const defaultClipSound = path.join(__dirname, 'assets', 'ClipEffect.wav')
const medalIcon = path.join(path.dirname(__dirname), 'src', 'assets', 'icon', 'MedalApp.png')
for (const [label, candidate] of [['default clip sound', defaultClipSound], ['Medal icon', medalIcon]]) {
  if (!fs.statSync(candidate, { throwIfNoEntry: false })?.isFile()) fail(`missing ${label} ${candidate}`)
}
process.env.NATIVE_PORT_DEFAULT_CLIP_SOUND = defaultClipSound
process.env.NATIVE_PORT_MEDAL_ICON = medalIcon
process.env.NATIVE_PORT_SESSION_SECRET = crypto.randomBytes(32).toString('base64url')

if (process.env.NATIVE_PORT_DISABLE_RECORDER === 'true') process.env.NO_RECORDER = '1'
global.nativePort = Object.freeze({ profile, tools, recorder, updater: 'manual' })
console.log(`[native-port] Electron ${process.versions.electron}, ABI ${process.versions.modules}, ${process.arch}`)

const selfTestMode = process.env.NATIVE_PORT_CLIENT_DB_SELFTEST
if (selfTestMode) {
  if (!['write', 'verify'].includes(selfTestMode)) fail('invalid NATIVE_PORT_CLIENT_DB_SELFTEST mode')
  const report = process.env.NATIVE_PORT_SELFTEST_REPORT
  if (!report || !path.isAbsolute(report)) fail('NATIVE_PORT_SELFTEST_REPORT must be absolute')
  const relativeReport = path.relative(profile, report)
  if (relativeReport.startsWith('..') || path.isAbsolute(relativeReport)) {
    fail('NATIVE_PORT_SELFTEST_REPORT must stay inside the isolated profile')
  }
  ipcMain.once('native-port:db-selftest-result', (_event, result) => {
    fs.mkdirSync(path.dirname(report), { recursive: true, mode: 0o700 })
    const temporary = `${report}.${process.pid}.tmp`
    fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
    fs.renameSync(temporary, report)
    global.nativePortDbSelfTestWindow?.destroy()
    global.nativePortDbSelfTestWindow = null
  })
  app.whenReady().then(() => {
    setTimeout(() => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          partition: 'native-port-db-selftest',
          preload: path.join(__dirname, 'db-selftest-preload.cjs')
        }
      })
      global.nativePortDbSelfTestWindow = window
      window.loadURL('data:text/html,<meta charset="utf-8"><title>Native port DB self-test</title>')
    }, 1500)
  })
}

const protocolSelfTestReport = process.env.NATIVE_PORT_PROTOCOL_SELFTEST_REPORT
if (protocolSelfTestReport) {
  if (!path.isAbsolute(protocolSelfTestReport)) fail('NATIVE_PORT_PROTOCOL_SELFTEST_REPORT must be absolute')
  const relativeReport = path.relative(profile, protocolSelfTestReport)
  if (relativeReport.startsWith('..') || path.isAbsolute(relativeReport)) {
    fail('NATIVE_PORT_PROTOCOL_SELFTEST_REPORT must stay inside the isolated profile')
  }
  const contentSelfTestClip = process.env.NATIVE_PORT_PROTOCOL_SELFTEST_CLIP
  if (contentSelfTestClip) {
    if (!path.isAbsolute(contentSelfTestClip) || path.extname(contentSelfTestClip).toLowerCase() !== '.mp4') {
      fail('NATIVE_PORT_PROTOCOL_SELFTEST_CLIP must be an absolute MP4 path')
    }
    const relativeClip = path.relative(profile, contentSelfTestClip)
    if (relativeClip.startsWith('..') || path.isAbsolute(relativeClip) || !fs.statSync(contentSelfTestClip, { throwIfNoEntry: false })?.isFile()) {
      fail('NATIVE_PORT_PROTOCOL_SELFTEST_CLIP must be an existing file inside the isolated profile')
    }
    const duration = Number(process.env.NATIVE_PORT_PROTOCOL_SELFTEST_DURATION_SECONDS)
    if (!Number.isFinite(duration) || duration <= 0 || duration > 125) {
      fail('NATIVE_PORT_PROTOCOL_SELFTEST_DURATION_SECONDS must be in (0, 125]')
    }
    process.env.NATIVE_PORT_PROTOCOL_SELFTEST_UUID = crypto.randomUUID()
  }
  ipcMain.once('native-port:protocol-selftest-result', (_event, result) => {
    fs.mkdirSync(path.dirname(protocolSelfTestReport), { recursive: true, mode: 0o700 })
    const temporary = `${protocolSelfTestReport}.${process.pid}.tmp`
    fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
    fs.renameSync(temporary, protocolSelfTestReport)
    global.nativePortProtocolSelfTestWindow?.destroy()
    global.nativePortProtocolSelfTestWindow = null
    setTimeout(() => app.quit(), 250)
  })
  app.whenReady().then(() => {
    setTimeout(() => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          partition: 'native-port-protocol-selftest',
          preload: path.join(__dirname, 'protocol-selftest-preload.cjs')
        }
      })
      global.nativePortProtocolSelfTestWindow = window
      window.loadURL('data:text/html,<meta charset="utf-8"><title>Native port protocol self-test</title>')
    }, 1500)
  })
}

const captureSelfTestReport = process.env.NATIVE_PORT_CAPTURE_SELFTEST_REPORT
if (captureSelfTestReport) {
  if (!path.isAbsolute(captureSelfTestReport)) fail('NATIVE_PORT_CAPTURE_SELFTEST_REPORT must be absolute')
  const relativeReport = path.relative(profile, captureSelfTestReport)
  if (relativeReport.startsWith('..') || path.isAbsolute(relativeReport)) {
    fail('NATIVE_PORT_CAPTURE_SELFTEST_REPORT must stay inside the isolated profile')
  }
  if (!['display', 'window', 'application'].includes(process.env.NATIVE_PORT_CAPTURE_SELFTEST_KIND)) {
    fail('NATIVE_PORT_CAPTURE_SELFTEST_KIND must be display, window or application')
  }
  if (process.env.NATIVE_PORT_CAPTURE_SELFTEST_CODEC &&
      !['H264', 'H265', 'AV1'].includes(process.env.NATIVE_PORT_CAPTURE_SELFTEST_CODEC)) {
    fail('NATIVE_PORT_CAPTURE_SELFTEST_CODEC must be H264, H265 or AV1')
  }
  if (process.env.NATIVE_PORT_CAPTURE_SELFTEST_REGISTER === '1') {
    if (process.env.NATIVE_PORT_CAPTURE_SELFTEST_EXPORT_MP4 !== '1') {
      fail('NATIVE_PORT_CAPTURE_SELFTEST_REGISTER requires MP4 export')
    }
    process.env.NATIVE_PORT_CAPTURE_SELFTEST_UUID = crypto.randomUUID()
  }
  if (process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY === '1' &&
      (process.env.NATIVE_PORT_CAPTURE_SELFTEST_EXPORT_MP4 === '1' ||
       process.env.NATIVE_PORT_CAPTURE_SELFTEST_REGISTER === '1')) {
    fail('operational hotkey self-test cannot use private save/register test RPCs')
  }
  const hotkeyInputs = process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY_INPUTS || 'F8'
  if (!/^[A-Za-z0-9+ ]{1,64}$/.test(hotkeyInputs)) {
    fail('NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY_INPUTS contains unsupported characters')
  }
  process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY_INPUTS = hotkeyInputs
  ipcMain.once('native-port:capture-selftest-result', (_event, result) => {
    fs.mkdirSync(path.dirname(captureSelfTestReport), { recursive: true, mode: 0o700 })
    const temporary = `${captureSelfTestReport}.${process.pid}.tmp`
    fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
    fs.renameSync(temporary, captureSelfTestReport)
    global.nativePortCaptureSelfTestWindow?.destroy()
    global.nativePortCaptureSelfTestWindow = null
    setTimeout(() => app.quit(), 250)
  })
  app.whenReady().then(() => {
    setTimeout(() => {
      const window = new BrowserWindow({
        show: process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY === '1',
        width: 620,
        height: 240,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          partition: 'native-port-capture-selftest',
          preload: path.join(__dirname, 'capture-selftest-preload.cjs')
        }
      })
      global.nativePortCaptureSelfTestWindow = window
      const escapedHotkeyInputs = hotkeyInputs.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
      const title = process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY === '1'
        ? `<h2>Native Medal replay test</h2><p>Select the requested source in the macOS picker. After capture begins, wait eight seconds, then press <kbd>${escapedHotkeyInputs}</kbd> once.</p>`
        : '<title>Native capture self-test</title>'
      window.loadURL(`data:text/html,<meta charset="utf-8"><title>Native capture self-test</title><body style="font:16px system-ui;padding:24px">${title}</body>`)
    }, 1500)
  })
}

const mediaSelfTestReport = process.env.NATIVE_PORT_MEDIA_SELFTEST_REPORT
if (mediaSelfTestReport) {
  if (!path.isAbsolute(mediaSelfTestReport)) fail('NATIVE_PORT_MEDIA_SELFTEST_REPORT must be absolute')
  const relativeReport = path.relative(profile, mediaSelfTestReport)
  if (relativeReport.startsWith('..') || path.isAbsolute(relativeReport)) {
    fail('NATIVE_PORT_MEDIA_SELFTEST_REPORT must stay inside the isolated profile')
  }
  for (const variable of ['NATIVE_PORT_MEDIA_SELFTEST_VIDEO', 'NATIVE_PORT_MEDIA_SELFTEST_THUMBNAIL']) {
    const candidate = process.env[variable]
    if (!candidate || !path.isAbsolute(candidate)) fail(`${variable} must be an absolute path`)
    const relativeCandidate = path.relative(profile, candidate)
    if (relativeCandidate.startsWith('..') || path.isAbsolute(relativeCandidate)) {
      fail(`${variable} must stay inside the isolated profile`)
    }
  }
  ipcMain.once('native-port:media-selftest-result', (_event, result) => {
    fs.mkdirSync(path.dirname(mediaSelfTestReport), { recursive: true, mode: 0o700 })
    const temporary = `${mediaSelfTestReport}.${process.pid}.tmp`
    fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
    fs.renameSync(temporary, mediaSelfTestReport)
    global.nativePortMediaSelfTestWindow?.destroy()
    global.nativePortMediaSelfTestWindow = null
    setTimeout(() => app.quit(), 250)
  })
  app.whenReady().then(() => {
    setTimeout(() => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          partition: 'native-port-media-selftest',
          preload: path.join(__dirname, 'media-selftest-preload.cjs')
        }
      })
      global.nativePortMediaSelfTestWindow = window
      window.loadFile(path.join(__dirname, 'media-selftest.html'))
    }, 1500)
  })
}

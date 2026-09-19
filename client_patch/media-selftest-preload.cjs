'use strict'

const { ipcRenderer } = require('electron')

const waitForEvent = (target, eventName, timeoutMilliseconds) => new Promise((resolve, reject) => {
  const timeout = setTimeout(() => {
    cleanup()
    reject(new Error(`${eventName} timed out`))
  }, timeoutMilliseconds)
  const cleanup = () => {
    clearTimeout(timeout)
    target.removeEventListener(eventName, passed)
    target.removeEventListener('error', failed)
  }
  const passed = () => {
    cleanup()
    resolve()
  }
  const failed = () => {
    cleanup()
    reject(new Error(`${eventName} failed with media error ${target.error?.code || 'unknown'}`))
  }
  target.addEventListener(eventName, passed, { once: true })
  target.addEventListener('error', failed, { once: true })
})

const fileUrl = absolutePath => `file://${absolutePath.split('/').map(encodeURIComponent).join('/')}`
const basename = absolutePath => absolutePath.split('/').filter(Boolean).at(-1) || ''

window.addEventListener('DOMContentLoaded', async () => {
  const videoPath = process.env.NATIVE_PORT_MEDIA_SELFTEST_VIDEO
  const thumbnailPath = process.env.NATIVE_PORT_MEDIA_SELFTEST_THUMBNAIL
  const result = {
    schemaVersion: 1,
    status: 'failed',
    videoFileName: basename(videoPath || ''),
    thumbnailFileName: basename(thumbnailPath || ''),
    startedAt: new Date().toISOString()
  }
  try {
    if (!videoPath?.startsWith('/') || !thumbnailPath?.startsWith('/')) {
      throw new Error('media self-test paths must be absolute')
    }
    const video = document.createElement('video')
    video.muted = true
    video.preload = 'auto'
    video.src = fileUrl(videoPath)
    document.body.append(video)
    await waitForEvent(video, 'loadedmetadata', 20000)
    if (!Number.isFinite(video.duration) || video.duration <= 0 || video.videoWidth <= 0 || video.videoHeight <= 0) {
      throw new Error('Chromium did not expose usable video metadata')
    }
    await video.play()
    await waitForEvent(video, 'timeupdate', 10000)
    video.pause()
    const seekTarget = Math.min(Math.max(video.duration / 2, 0.01), Math.max(video.duration - 0.01, 0.01))
    const seeked = waitForEvent(video, 'seeked', 10000)
    video.currentTime = seekTarget
    await seeked

    const image = document.createElement('img')
    image.src = fileUrl(thumbnailPath)
    document.body.append(image)
    await waitForEvent(image, 'load', 20000)
    if (image.naturalWidth <= 0 || image.naturalHeight <= 0) {
      throw new Error('Chromium did not decode the generated thumbnail')
    }

    result.status = 'passed'
    result.video = {
      durationSeconds: video.duration,
      width: video.videoWidth,
      height: video.videoHeight,
      seekedSeconds: video.currentTime,
      h264AacCanPlayType: video.canPlayType('video/mp4; codecs="avc1.640028, mp4a.40.2"')
    }
    result.thumbnail = {
      width: image.naturalWidth,
      height: image.naturalHeight
    }
  } catch (error) {
    result.error = String(error?.stack || error).replace(/[\r\n]+/g, ' ').slice(0, 1200)
  }
  result.completedAt = new Date().toISOString()
  ipcRenderer.send('native-port:media-selftest-result', result)
})

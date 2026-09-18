'use strict'

const path = require('node:path')
const WebSocket = require(path.resolve(process.argv[2], 'node_modules/ws'))
const port = Number(process.argv[3])
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid port')

const attempt = headers => new Promise((resolve, reject) => {
  const socket = new WebSocket(`ws://127.0.0.1:${port}`, { headers })
  const timer = setTimeout(() => reject(new Error('authentication probe timed out')), 3000)
  socket.once('unexpected-response', (_request, response) => {
    clearTimeout(timer)
    response.resume()
    socket.terminate()
    resolve(response.statusCode)
  })
  socket.once('open', () => {
    clearTimeout(timer)
    socket.close()
    reject(new Error('unauthorized WebSocket unexpectedly opened'))
  })
  socket.once('error', error => {
    if (!String(error).includes('Unexpected server response')) {
      clearTimeout(timer)
      reject(error)
    }
  })
})

;(async () => {
  const missing = await attempt({})
  const incorrect = await attempt({ 'x-native-port-secret': 'incorrect-old-launch-secret-value' })
  if (missing !== 401 || incorrect !== 401) throw new Error(`expected 401/401, received ${missing}/${incorrect}`)
  console.log(JSON.stringify({ passed: true, missingSecretStatus: missing, incorrectSecretStatus: incorrect }, null, 2))
})().catch(error => {
  console.error(error)
  process.exitCode = 1
})

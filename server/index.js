import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import readline from 'node:readline'
import { fileURLToPath } from 'node:url'
import { spawn, exec } from 'node:child_process'
import { WebSocketServer, WebSocket } from 'ws'

/** Prefer LAN IPv4 (e.g. 192.168.x.x) for phone access on the same Wi‑Fi. */
function getLanIPv4() {
  const ifaces = os.networkInterfaces()
  const candidates = []
  for (const list of Object.values(ifaces)) {
    if (!list) continue
    for (const info of list) {
      const family = info.family === 4 || info.family === 'IPv4'
      if (!family || info.internal) continue
      candidates.push(info.address)
    }
  }
  const score = (ip) => {
    if (ip.startsWith('192.168.')) return 0
    if (ip.startsWith('10.')) return 1
    if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(ip)) return 2
    return 9
  }
  candidates.sort((a, b) => score(a) - score(b))
  return candidates[0] || '127.0.0.1'
}

function resolveRoot() {
  // pkg: public/ + bin/ are embedded in the snapshot next to the bundled script
  if (process.pkg) {
    return path.dirname(__filename)
  }
  // esbuild CJS bundle in build/: prefer sibling public/ (packaging layout) or repo root
  if (typeof __dirname !== 'undefined') {
    if (fs.existsSync(path.join(__dirname, 'public'))) return __dirname
    const candidate = path.resolve(__dirname, '..')
    if (fs.existsSync(path.join(candidate, 'public'))) return candidate
  }
  try {
    return path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
  } catch {
    return process.cwd()
  }
}

/**
 * Native .exe cannot be spawned from pkg's virtual FS — copy to a real temp path.
 */
function materializeCaptureExe(embeddedPath) {
  if (!process.pkg) return embeddedPath

  const destDir = path.join(os.tmpdir(), 'toneferry-runtime')
  const dest = path.join(destDir, 'audio-capture.exe')
  fs.mkdirSync(destDir, { recursive: true })

  const srcStat = fs.statSync(embeddedPath)
  let needCopy = true
  try {
    const destStat = fs.statSync(dest)
    needCopy = destStat.size !== srcStat.size || destStat.mtimeMs < srcStat.mtimeMs
  } catch {
    needCopy = true
  }
  if (needCopy) {
    fs.copyFileSync(embeddedPath, dest)
  }
  return dest
}

const ROOT = resolveRoot()
const PUBLIC_DIR = path.join(ROOT, 'public')
const CAPTURE_EXE = materializeCaptureExe(path.join(ROOT, 'bin', 'audio-capture.exe'))

const HTTP_PORT = Number(process.env.PORT || 3088)
const WS_PATH = '/audio'
const OPEN_BROWSER = process.env.TONEFERRY_NO_BROWSER !== '1'

/** @type {{ sampleRate: number, channels: number, format: string } | null} */
let audioConfig = null

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
}

function sendConfig(ws, force) {
  if (!audioConfig) return
  if (ws.readyState !== WebSocket.OPEN) return
  // 同一连接同采样率只下发一次，避免客户端重复初始化播放器（重复建图会双路出声）。
  // 但客户端被手机顶掉后本机静音、再恢复出声时会显式 get-config，那次必须重发。
  if (!force && ws.configSent && ws.configRate === audioConfig.sampleRate) return
  ws.configSent = true
  ws.configRate = audioConfig.sampleRate
  ws.send(
    JSON.stringify({
      type: 'audio-config',
      sampleRate: audioConfig.sampleRate,
      channels: audioConfig.channels,
      format: audioConfig.format,
    }),
  )
}

/** 从握手请求里判断是不是原生 App（Toneferry-iOS/...），浏览器则带 Mozilla/... */
function isNativeClient(req) {
  const ua = String(req?.headers?.['user-agent'] || '')
  return /Toneferry-iOS/i.test(ua)
}

function nativeClientCount() {
  let n = 0
  for (const c of wss.clients) {
    if (c.isNative && c.readyState === WebSocket.OPEN) n++
  }
  return n
}

/**
 * 手机 App 一连接就通知浏览器端停下来。
 * 原因：浏览器外放的声音会被 WASAPI loopback 重新采进去，再推回手机播一遍，
 * 手机听到的就是「原声 + 延迟副本」，听感即回声。这是物理闭环，只能在源头掐断。
 */
function broadcastPeerMode() {
  const count = nativeClientCount()
  const payload = JSON.stringify({ type: 'peer-mode', nativeCount: count })
  for (const c of wss.clients) {
    if (c.isNative) continue
    if (c.readyState !== WebSocket.OPEN) continue
    try {
      c.send(payload)
    } catch {
      /* ignore */
    }
  }
  if (count > 0) {
    console.log(`  ${c.yellow}[ws] 手机 App 在线（${count} 路），已通知浏览器端停止播放以避免回声${c.reset}`)
  }
}

/** 手机锁屏/后台时下行可能积压，超过阈值直接丢帧，避免内存膨胀与延迟累积。 */
const MAX_BUFFERED_BYTES = 512 * 1024

/**
 * 总开关：电脑网页端点了「开始收听」才真正推流。
 * 没点之前，采集照常在跑（要拿配置、要暖机），但一帧都不下发 ——
 * 手机端此时是安静的，符合「开始收听 = 开始发送到手机」的直觉。
 */
let streamEnabled = false
/** 谁点的开始（浏览器连接）。发起方全断开时自动关闸，避免采集空转。 */
const streamOwners = new Set()

function setStreamEnabled(on, owner) {
  if (on) {
    if (owner) streamOwners.add(owner)
  } else if (owner) {
    streamOwners.delete(owner)
  } else {
    streamOwners.clear()
  }
  const next = streamOwners.size > 0
  if (next === streamEnabled) return
  streamEnabled = next
  console.log(
    `  ${streamEnabled ? c.green : c.dim}[stream] 推流${streamEnabled ? '开启' : '停止'}` +
      `（订阅方 ${streamOwners.size} 路）${c.reset}`,
  )
  broadcastJson({ type: 'stream-state', enabled: streamEnabled })
}

function broadcastBinary(buf) {
  if (!streamEnabled) return
  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN) continue
    // 只做在线监测的连接（浏览器被手机顶掉后留下的监控 socket）不再收 PCM
    if (client.wantsAudio === false) continue
    if (client.bufferedAmount > MAX_BUFFERED_BYTES) continue
    try {
      client.send(buf, { binary: true })
    } catch {
      /* 客户端已断开 */
    }
  }
}

function broadcastJson(obj) {
  const text = JSON.stringify(obj)
  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN) continue
    try {
      client.send(text)
    } catch {
      /* ignore */
    }
  }
}

function openBrowser(url) {
  if (!OPEN_BROWSER) return
  const cmd =
    process.platform === 'win32'
      ? `start "" "${url}"`
      : process.platform === 'darwin'
        ? `open "${url}"`
        : `xdg-open "${url}"`
  exec(cmd, (err) => {
    if (err) console.warn('[browser] open failed:', err.message)
  })
}

/** ANSI colors for Windows Terminal / modern consoles */
const c = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  cyan: '\x1b[36m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  magenta: '\x1b[35m',
  blue: '\x1b[34m',
  white: '\x1b[37m',
  red: '\x1b[31m',
  bgBlue: '\x1b[44m',
}

function enableConsoleColor() {
  if (process.platform !== 'win32') return
  try {
    // Best-effort: Node 20+ usually already enables VT on Windows consoles
    if (process.stdout.isTTY) process.stdout.write('')
  } catch {
    /* ignore */
  }
}

function printStartupBanner(host, port) {
  const url = `http://${host}:${port}`
  const localUrl = `http://127.0.0.1:${port}`
  const wsUrl = `ws://${host}:${port}${WS_PATH}`
  const line = '═'.repeat(56)

  console.log('')
  console.log(`${c.cyan}${c.bold}  ${line}${c.reset}`)
  console.log(`${c.cyan}${c.bold}   Toneferry  ·  系统音频实时推流已启动${c.reset}`)
  console.log(`${c.cyan}${c.bold}  ${line}${c.reset}`)
  console.log('')
  console.log(`  ${c.green}${c.bold}访问地址${c.reset}\n`)
  console.log(`    局域网（手机请用这个）：  ${c.yellow}${c.bold}${url}${c.reset}`)
  console.log(`    本机浏览器：              ${c.dim}${localUrl}${c.reset}`)
  console.log(`    WebSocket：               ${c.dim}${wsUrl}${c.reset}`)
  console.log('')
  console.log(`  ${c.green}${c.bold}如何使用${c.reset}\n`)
  console.log(`    1. 电脑播放音乐 / 视频 / 浏览器声音`)
  console.log(`    2. 手机与电脑在 ${c.bold}同一局域网${c.reset}`)
  console.log(`    3. 手机浏览器打开上面的局域网地址`)
  console.log(`    4. 点击页面「开始收听」`)
  console.log('')
  console.log(`  ${c.magenta}${c.bold}注意事项${c.reset}\n`)
  console.log(`    · 请保持本窗口开着，${c.yellow}关闭窗口即停止服务${c.reset}`)
  console.log(`    · ${c.yellow}请将音频输出设备设为主机自带扬声器${c.reset}（系统声音 → 输出），勿选 USB 声卡 / 耳机等外置设备`)
  console.log(`    · 手机与电脑必须在同一局域网，访客网络可能不通`)
  console.log(`    · 若打不开页面，检查 Windows 防火墙是否放行端口 ${port}`)
  console.log(`    · ${c.yellow}支持锁屏 / 息屏继续播放${c.reset}，手机通知栏可直接暂停/继续`)
  console.log(`    · 若锁屏后无声：手机浏览器设置里允许该站点「后台播放 / 不受流量节省限制」`)
  console.log(`    · 本机也可打开：${localUrl}`)
  console.log('')
  console.log(`  ${c.dim}停止服务：关闭本窗口，或按 Ctrl+C${c.reset}`)
  console.log(`${c.cyan}${c.bold}  ${line}${c.reset}`)
  console.log('')
}

const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent((req.url || '/').split('?')[0])
  const relUrl = urlPath === '/' ? '/index.html' : urlPath
  const filePath = path.normalize(path.join(PUBLIC_DIR, relUrl))
  const rel = path.relative(PUBLIC_DIR, filePath)
  if (rel.startsWith('..') || path.isAbsolute(rel)) {
    res.writeHead(403).end('Forbidden')
    return
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404).end('Not Found')
      return
    }
    const ext = path.extname(filePath).toLowerCase()
    res.writeHead(200, { 'Content-Type': mime[ext] || 'application/octet-stream' })
    res.end(data)
  })
})

const wss = new WebSocketServer({ server, path: WS_PATH })

wss.on('connection', (ws, req) => {
  ws.isAlive = true
  ws.isNative = isNativeClient(req)
  // 默认收 PCM；浏览器被手机顶掉后会发 wants-audio:false，只保留在线监测
  ws.wantsAudio = true
  ws.on('pong', () => {
    ws.isAlive = true
  })

  sendConfig(ws)
  // 告诉新连接当前总闸状态：没点「开始收听」时手机端应当保持安静
  try {
    ws.send(JSON.stringify({ type: 'stream-state', enabled: streamEnabled }))
  } catch {
    /* ignore */
  }

  const who = ws.isNative ? '手机 App' : '浏览器'
  console.log(`  ${c.dim}[ws] ${who} 已连接（当前 ${wss.clients.size} 路）${c.reset}`)

  // 两路同时在播时，电脑扬声器 + 手机扬声器会形成「同一段音频的两个声源」，
  // 听感就是回声。这里明确提示，避免误判成播放器 bug。
  if (wss.clients.size > 1) {
    console.log(`  ${c.yellow}[ws] 提示：当前有 ${wss.clients.size} 个客户端在收听，` +
      `若电脑浏览器页面也在播放，请关掉它，否则会听到回声${c.reset}`)
  }

  // 手机 App 接入 → 让浏览器端自动停播（回声的源头就是浏览器外放）
  broadcastPeerMode();

  ws.on('message', (data, isBinary) => {
    if (isBinary) return
    const text = typeof data === 'string' ? data : data.toString('utf8')
    try {
      const msg = JSON.parse(text)
      if (msg.type === 'get-config') {
        if (audioConfig) {
          sendConfig(ws, true)
        } else {
          ws.send(JSON.stringify({ type: 'status', message: 'capture config pending' }))
        }
      } else if (msg.type === 'wants-audio') {
        // 浏览器被手机 App 接管后主动退订下行 PCM，避免电脑外放被 loopback 采回形成回声
        ws.wantsAudio = msg.value !== false
      } else if (msg.type === 'start-stream') {
        // 网页端点了「开始收听」：从这一刻起才向手机/其他端下发音频
        setStreamEnabled(true, ws)
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'stream-state', enabled: streamEnabled }))
        }
      } else if (msg.type === 'stop-stream') {
        setStreamEnabled(false, ws)
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'stream-state', enabled: streamEnabled }))
        }
      } else if (msg.type === 'ping') {
        // 客户端心跳：锁屏时用它维持连接并确认下行仍通畅
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'pong', t: Date.now() }))
        }
      }
    } catch {
      /* ignore non-json */
    }
  })

  ws.on('close', () => {
    const left = Math.max(wss.clients.size - 1, 0)
    console.log(`  ${c.dim}[ws] ${who} 断开（剩余 ${left} 路）${c.reset}`)
    // 发起推流的页面关掉后必须关闸，否则采集继续空转、手机继续收
    if (streamOwners.delete(ws)) setStreamEnabled(streamOwners.size > 0)
    // close 事件里 clients 集合可能还没更新完，挪到下一轮事件循环再算
    setTimeout(broadcastPeerMode, 50)
  })
})

/**
 * 保活：手机锁屏后页面可能被冻结。协议层 ping 由网络栈直接回 pong，
 * 连续收不到 pong 的连接直接断开，客户端 watchdog 会自己重连。
 */
const wsHeartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      try {
        ws.terminate()
      } catch {
        /* ignore */
      }
      continue
    }
    ws.isAlive = false
    try {
      ws.ping()
    } catch {
      /* ignore */
    }
  }
}, 30000)
wsHeartbeat.unref?.()

wss.on('close', () => clearInterval(wsHeartbeat))

function startCapture() {
  if (!fs.existsSync(CAPTURE_EXE)) {
    console.error(`[error] missing capture binary: ${CAPTURE_EXE}`)
    console.error('Dev: npm run build:capture   |   Packaged: rebuild with npm run build:exe')
    holdAndExit(1)
  }

  const child = spawn(CAPTURE_EXE, [], {
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  })

  let stderrBuf = ''
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk) => {
    stderrBuf += chunk
    let idx
    while ((idx = stderrBuf.indexOf('\n')) >= 0) {
      const line = stderrBuf.slice(0, idx).trim()
      stderrBuf = stderrBuf.slice(idx + 1)
      if (!line) continue
      try {
        const msg = JSON.parse(line)
        if (msg.type === 'audio-config') {
          audioConfig = {
            sampleRate: Number(msg.sampleRate),
            channels: Number(msg.channels) || 2,
            format: msg.format || 'f32',
          }
          // 逐连接下发（带采样率去重），避免已初始化的客户端被重复建图
          for (const client of wss.clients) sendConfig(client)
        } else if (msg.type === 'error') {
          console.error('[capture]', msg.message, msg.hr ?? '')
          broadcastJson({ type: 'error', message: msg.message })
        } else if (msg.type === 'status') {
        }
      } catch {
        console.log('[capture:stderr]', line)
      }
    }
  })

  let pending = Buffer.alloc(0)
  const defaultFrameBytes = 48000 * 2 * 4 * 0.01

  child.stdout.on('data', (chunk) => {
    pending = Buffer.concat([pending, chunk])
    const frameBytes = audioConfig
      ? Math.max(
          Math.floor(audioConfig.sampleRate * audioConfig.channels * 4 * 0.01),
          audioConfig.channels * 4,
        )
      : defaultFrameBytes

    while (pending.length >= frameBytes) {
      const frame = pending.subarray(0, frameBytes)
      pending = pending.subarray(frameBytes)
      broadcastBinary(Buffer.from(frame))
    }
  })

  child.on('exit', (code, signal) => {
    console.error(`[capture] exited code=${code} signal=${signal}`)
    broadcastJson({ type: 'status', message: 'capture stopped' })
    if (!shuttingDown) {
      setTimeout(() => {
        captureProc = startCapture()
      }, 1500)
    }
  })

  child.on('error', (err) => {
    console.error('[capture] spawn error', err)
  })

  return child
}

let shuttingDown = false
let captureProc = null

captureProc = startCapture()

server.listen(HTTP_PORT, '0.0.0.0', () => {
  const host = getLanIPv4()
  const url = `http://${host}:${HTTP_PORT}`
  enableConsoleColor()
  printStartupBanner(host, HTTP_PORT)
  openBrowser(url)
})

server.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE') {
    console.error(`[error] port ${HTTP_PORT} already in use. Kill the old process or set PORT=3089`)
  } else {
    console.error('[error] server', err)
  }
  holdAndExit(1)
})

function holdAndExit(code = 1) {
  if (process.pkg) {
    console.error('')
    console.error('按回车键退出…')
    try {
      const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
      rl.question('', () => {
        rl.close()
        process.exit(code)
      })
      return
    } catch {
      /* fall through */
    }
  }
  process.exit(code)
}

function shutdown() {
  if (shuttingDown) return
  shuttingDown = true
  console.log('shutting down...')
  if (captureProc && !captureProc.killed) {
    captureProc.kill()
  }
  wss.close()
  server.close(() => process.exit(0))
  setTimeout(() => process.exit(0), 2000).unref()
}

process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
process.on('uncaughtException', (err) => {
  console.error('[fatal]', err)
  holdAndExit(1)
})
process.on('unhandledRejection', (err) => {
  console.error('[fatal]', err)
  holdAndExit(1)
})

/**
 * Toneferry 前端播放器
 *
 * 锁屏 / 息屏继续出声的三个关键点：
 * 1. 页面不可见时不再断开 WebSocket、不再 suspend AudioContext（旧逻辑直接导致静音）。
 * 2. AudioWorklet 的输出必须经由 <audio> 媒体元素播放（MediaStreamAudioDestinationNode），
 *    只有走媒体元素，Android Chrome 才会把这段音频当成"正在播放的媒体"，
 *    锁屏后继续出声，并在锁屏界面保留媒体会话。
 * 3. watchdog 周期性自检 AudioContext / 媒体元素 / WebSocket，被打断后自动恢复。
 */

const btnStart = document.getElementById('btnStart')
const btnStop = document.getElementById('btnStop')
const statusDot = document.getElementById('statusDot')
const statusText = document.getElementById('statusText')
const sampleRateEl = document.getElementById('sampleRate')
const channelsEl = document.getElementById('channels')
const bufferedEl = document.getElementById('buffered')
const levelEl = document.getElementById('level')

/* 关闭网页 / 配对码 / 最近连接 */
/** 本页是否跑在电脑上（只有本机页面显示「关闭网页」和配对码） */
let isLocalPage = false
const btnClosePage = document.getElementById('btnClosePage')
const closePageHint = document.getElementById('closePageHint')
const peersList = document.getElementById('peersList')
const peersBadge = document.getElementById('peersBadge')

/* ---- 配对码 ---- */
const PIN_KEY = 'toneferry.pin'
const pairingLocalCard = document.getElementById('pairingLocalCard')
const pairingPhoneCard = document.getElementById('pairingPhoneCard')
const pairingCodeEl = document.getElementById('pairingCode')
const pairingInput = document.getElementById('pairingInput')
const btnPairing = document.getElementById('btnPairing')
const pairingBadge = document.getElementById('pairingBadge')
const pairingHint = document.getElementById('pairingHint')
/** 手机端已保存的配对码（本机页面不需要） */
let savedPin = ''
/** 本次 WS 握手是否被服务端拒绝（配对码错误），用于停止无效重连 */
let pairingRejected = false
try {
  savedPin = String(localStorage.getItem(PIN_KEY) || '').trim()
} catch {
  /* 隐私模式下 localStorage 可能不可用 */
}

/** true = 保持屏幕常亮（会阻止锁屏）。锁屏播放场景应为 false。 */
const KEEP_SCREEN_ON = false
const HEARTBEAT_MS = 20000
const WATCHDOG_MS = 4000

/** @type {AudioContext | null} */
let audioContext = null
/** @type {AudioWorkletNode | ScriptProcessorNode | null} */
let player = null
/** @type {'worklet' | 'script' | null} */
let playerMode = null
/** @type {WebSocket | null} */
let ws = null
/** @type {{ sampleRate: number, channels: number, format: string } | null} */
let config = null
/** 用户意图：持续收听（直到点停止）。 */
let listening = false
/**
 * 是否真的把下行 PCM 送进播放器。
 * 与 listening 分开的原因有两个：
 * 1. 「开始收听」是**总开关**——服务端只有收到 start-stream 才推流，
 *    所以没点按钮时手机端是安静的；listening 记录的就是这个意图。
 * 2. 手机 App 在线时必须让本机静音：网页外放会被 WASAPI loopback 重新采回去
 *    再推给手机，形成「原声 + 延迟副本」的物理回声闭环。
 *    此时 listening 仍为 true（总闸开着，手机在收），但 audioEnabled 为 false。
 */
let audioEnabled = false
/** 服务端是否已确认推流开启（用于区分「刚连上时的初始 false」和「别人真的点了停止」） */
let streamConfirmed = false
/** 在线的手机 App 路数。>0 时本机必须静音，否则电脑外放会被 loopback 采回去形成回声。 */
let nativePeerCount = 0
/** @type {ReturnType<typeof setTimeout> | null} */
let reconnectTimer = null
let reconnectAttempt = 0
/** @type {ReturnType<typeof setInterval> | null} */
let watchdogTimer = null
let heartbeatTick = 0
/** 播放器初始化串行化（防止重复 config 造成并发建上下文） */
/** @type {Promise<void> | null} */
let initPromise = null

/** 承载音频的媒体元素：锁屏媒体会话的宿主，也是音频真正出声的地方。 */
/** @type {HTMLAudioElement | null} */
let sinkAudio = null
/** @type {MediaStreamAudioDestinationNode | null} */
let sinkNode = null
/** 当前是否成功走媒体元素通道 */
let usingSink = false
/** 正在切换媒体源（切换期间不要自动续播） */
let sinkSwapping = false

const NoSleepCtor = typeof window !== 'undefined' ? window.NoSleep : undefined
const noSleep = typeof NoSleepCtor === 'function' ? new NoSleepCtor() : null

const scriptQueue = {
  samples: new Float32Array(0),
  clear() {
    this.samples = new Float32Array(0)
  },
  push(buf) {
    const next = new Float32Array(this.samples.length + buf.length)
    next.set(this.samples)
    next.set(buf, this.samples.length)
    const max = 48000 * 2
    this.samples = next.length > max ? next.subarray(next.length - max) : next
  },
  pull(frames) {
    const need = frames * 2
    const out = new Float32Array(need)
    const take = Math.min(need, this.samples.length)
    out.set(this.samples.subarray(0, take))
    this.samples = this.samples.subarray(take)
    return out
  },
  frames() {
    return this.samples.length >> 1
  },
}

function setStatus(text, ok = false) {
  statusText.textContent = text
  statusDot.classList.toggle('on', ok)
}

function playingLabel() {
  return playerMode === 'worklet' ? '播放中' : '播放中（兼容模式）'
}

function wsUrl() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:'
  let url = `${proto}//${location.host}/audio`
  // 本机连接服务端自动放行；局域网设备必须带正确配对码才能握手成功。
  const pin = isLocalPage ? '' : savedPin
  if (pin) url += `?pin=${encodeURIComponent(pin)}`
  return url
}

/** 手机端未填配对码就不发连接，避免无限重连刷屏。 */
function pairingReady() {
  return isLocalPage || /^\d{4,8}$/.test(savedPin)
}

function clearReconnect() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
}

/* ------------------------------------------------------------------ */
/* 媒体元素：锁屏播放的宿主                                            */
/* ------------------------------------------------------------------ */

/** 极短静音 WAV —— 手势内让 <audio> 进入真正的播放态。 */
function silentWavDataUri(seconds = 2, sampleRate = 8000) {
  const n = sampleRate * seconds
  const dataBytes = n * 2
  const buf = new ArrayBuffer(44 + dataBytes)
  const v = new DataView(buf)
  const w = (o, s) => {
    for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i))
  }
  w(0, 'RIFF')
  v.setUint32(4, 36 + dataBytes, true)
  w(8, 'WAVEfmt ')
  v.setUint32(16, 16, true)
  v.setUint16(20, 1, true)
  v.setUint16(22, 1, true)
  v.setUint32(24, sampleRate, true)
  v.setUint32(28, sampleRate * 2, true)
  v.setUint16(32, 2, true)
  v.setUint16(34, 16, true)
  w(36, 'data')
  v.setUint32(40, dataBytes, true)
  const bytes = new Uint8Array(buf)
  let bin = ''
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return `data:audio/wav;base64,${btoa(bin)}`
}

function getSinkAudio() {
  if (sinkAudio) return sinkAudio

  const el = document.createElement('audio')
  el.id = 'tfSink'
  el.setAttribute('playsinline', '')
  el.setAttribute('webkit-playsinline', '')
  el.setAttribute('aria-hidden', 'true')
  el.autoplay = true
  el.preload = 'auto'
  el.volume = 1
  el.muted = false
  el.style.position = 'fixed'
  el.style.width = '1px'
  el.style.height = '1px'
  el.style.opacity = '0'
  el.style.pointerEvents = 'none'
  el.style.left = '-9999px'
  el.style.top = '0'

  // 被系统打断（来电、音频焦点切换、耳机插拔）后自动续播
  el.addEventListener('pause', () => {
    if (!listening || sinkSwapping) return
    setTimeout(() => {
      if (listening && !sinkSwapping && el.paused) el.play().catch(() => {})
    }, 300)
  })

  document.body.appendChild(el)
  sinkAudio = el
  return el
}

function applyMediaSession() {
  if (!('mediaSession' in navigator)) return
  try {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: '系统音频推流',
      artist: 'Toneferry',
      album: 'Loopback',
    })
    navigator.mediaSession.playbackState = 'playing'
    navigator.mediaSession.setActionHandler('play', () => {
      if (!listening) start().catch(console.error)
      else if (sinkAudio && sinkAudio.paused) sinkAudio.play().catch(() => {})
    })
    navigator.mediaSession.setActionHandler('pause', () => {
      stop().catch(console.error)
    })
    navigator.mediaSession.setActionHandler('stop', () => {
      stop().catch(console.error)
    })
  } catch {
    /* 部分浏览器不支持某些 action，忽略 */
  }
}

/** 必须在用户手势内调用：先让媒体元素真正播放起来。 */
async function primeMediaElement() {
  const el = getSinkAudio()
  if (!el.srcObject && !el.getAttribute('src')) {
    el.src = silentWavDataUri(2, 8000)
    el.loop = true
  }
  if (el.paused) {
    try {
      await el.play()
    } catch (err) {
      console.warn('[media] prime play failed', err)
    }
  }
  applyMediaSession()
}

/** 把 AudioContext 的输出流接到媒体元素上；失败则回退到直接输出。 */
async function attachSinkStream(stream) {
  const el = getSinkAudio()
  sinkSwapping = true
  try {
    el.pause()
  } catch {
    /* ignore */
  }
  try {
    el.removeAttribute('src')
    el.loop = false
    el.srcObject = stream
  } catch (err) {
    console.warn('[media] srcObject unsupported', err)
    sinkSwapping = false
    return false
  }
  try {
    await el.play()
    usingSink = true
    sinkSwapping = false
    applyMediaSession()
    return true
  } catch (err) {
    console.warn('[media] stream play failed', err)
    sinkSwapping = false
    return false
  }
}

/** 媒体元素回退为静音 keep-alive（至少保住媒体会话，避免页面被冻结）。 */
function fallbackKeepAlive() {
  const el = getSinkAudio()
  sinkSwapping = true
  try {
    el.pause()
  } catch {
    /* ignore */
  }
  try {
    el.srcObject = null
  } catch {
    /* ignore */
  }
  el.src = silentWavDataUri(2, 8000)
  el.loop = true
  el.play()
    .catch(() => {})
    .finally(() => {
      sinkSwapping = false
    })
  applyMediaSession()
}

function stopMediaElement() {
  const el = sinkAudio
  if (!el) return
  try {
    el.pause()
  } catch {
    /* ignore */
  }
  try {
    el.srcObject = null
  } catch {
    /* ignore */
  }
  el.removeAttribute('src')
  try {
    el.load()
  } catch {
    /* ignore */
  }
  if ('mediaSession' in navigator) {
    try {
      navigator.mediaSession.playbackState = 'none'
    } catch {
      /* ignore */
    }
  }
}

/* ------------------------------------------------------------------ */
/* 屏幕常亮（可选，默认关闭：锁屏播放不需要常亮）                       */
/* ------------------------------------------------------------------ */

function enableNoSleep() {
  if (!noSleep || !KEEP_SCREEN_ON) return
  try {
    const result = noSleep.enable()
    if (result && typeof result.catch === 'function') {
      result.catch((err) => console.warn('NoSleep enable failed', err))
    }
  } catch (err) {
    console.warn('NoSleep enable failed', err)
  }
}

function disableNoSleep() {
  if (!noSleep) return
  try {
    noSleep.disable()
  } catch {
    /* ignore */
  }
}

/* ------------------------------------------------------------------ */
/* 播放器                                                              */
/* ------------------------------------------------------------------ */

function resetPlayerBuffer() {
  if (playerMode === 'worklet' && player) {
    try {
      player.port.postMessage({ type: 'reset' })
    } catch {
      /* ignore */
    }
  }
  scriptQueue.clear()
  bufferedEl.textContent = '0'
  levelEl.style.width = '0%'
}

function destroyPlayer() {
  if (player) {
    resetPlayerBuffer()
    try {
      player.disconnect()
    } catch {
      /* ignore */
    }
    player = null
  }
  playerMode = null
  scriptQueue.clear()
}

async function ensurePlayer(sampleRate) {
  if (audioContext && player && Math.abs(audioContext.sampleRate - sampleRate) < 1) {
    if (audioContext.state === 'suspended') await audioContext.resume()
    return
  }

  // 服务端可能连续下发 audio-config，初始化必须串行，否则两个 AudioContext 会互相覆盖
  if (initPromise) {
    try {
      await initPromise
    } catch {
      /* 上一轮失败，下面重试 */
    }
    if (audioContext && player && Math.abs(audioContext.sampleRate - sampleRate) < 1) {
      if (audioContext.state === 'suspended') await audioContext.resume()
      return
    }
  }

  initPromise = createPlayer(sampleRate).finally(() => {
    initPromise = null
  })
  return initPromise
}

async function createPlayer(sampleRate) {
  destroyPlayer()
  usingSink = false
  sinkNode = null
  const prev = audioContext
  audioContext = null
  if (prev) {
    try {
      await prev.close()
    } catch {
      /* ignore */
    }
  }

  // 全程使用局部 ctx：await 期间全局可能被替换
  const ctx = new AudioContext({ sampleRate })
  audioContext = ctx
  const actualRate = ctx.sampleRate
  if (Math.abs(actualRate - sampleRate) > 1) {
    console.warn(`AudioContext sampleRate=${actualRate}, stream=${sampleRate}`)
  }

  // 被系统挂起时自动拉起（锁屏/切换音频焦点后常见）
  ctx.addEventListener('statechange', () => {
    if (!listening) return
    if (ctx.state !== 'running') ctx.resume().catch(() => {})
  })

  // 优先走媒体元素通道，这是锁屏后仍能出声的前提
  let outTarget = ctx.destination
  let sink = null
  if (typeof ctx.createMediaStreamDestination === 'function') {
    try {
      const node = ctx.createMediaStreamDestination()
      if (await attachSinkStream(node.stream)) {
        sink = node
        outTarget = node
      } else {
        fallbackKeepAlive()
      }
    } catch (err) {
      console.warn('[media] createMediaStreamDestination failed', err)
      fallbackKeepAlive()
    }
  } else {
    fallbackKeepAlive()
  }

  const canWorklet =
    window.isSecureContext && typeof ctx.audioWorklet?.addModule === 'function'

  if (canWorklet) {
    try {
      await ctx.audioWorklet.addModule('./audio-player.js')
      if (audioContext !== ctx) return
      const node = new AudioWorkletNode(ctx, 'audio-player', {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
      })
      node.connect(outTarget)
      node.port.onmessage = (ev) => {
        const msg = ev.data
        if (msg?.type === 'stats') {
          bufferedEl.textContent = String(msg.bufferedFrames)
          levelEl.style.width = `${Math.min(100, Math.round((msg.level || 0) * 140))}%`
        }
      }
      sinkNode = sink
      player = node
      playerMode = 'worklet'
      if (ctx.state === 'suspended') await ctx.resume()
      return
    } catch (err) {
      console.warn('AudioWorklet failed, fallback to ScriptProcessor', err)
      destroyPlayer()
    }
  }

  if (audioContext !== ctx) return

  const bufferSize = 2048
  const sp = ctx.createScriptProcessor(bufferSize, 0, 2)
  sp.onaudioprocess = (ev) => {
    const outL = ev.outputBuffer.getChannelData(0)
    const outR = ev.outputBuffer.getChannelData(1)
    const interleaved = scriptQueue.pull(bufferSize)
    let peak = 0
    for (let i = 0; i < bufferSize; i++) {
      const l = interleaved[i * 2] || 0
      const r = interleaved[i * 2 + 1] || 0
      outL[i] = l
      outR[i] = r
      const a = Math.abs(l) > Math.abs(r) ? Math.abs(l) : Math.abs(r)
      if (a > peak) peak = a
    }
    bufferedEl.textContent = String(scriptQueue.frames())
    levelEl.style.width = `${Math.min(100, Math.round(peak * 140))}%`
  }
  if (!sink) {
    // 仅直连扬声器时需要这个 0 增益节点，避免 ScriptProcessor 被回收
    const silent = ctx.createGain()
    silent.gain.value = 0
    silent.connect(sp)
  }
  sp.connect(outTarget)
  sinkNode = sink
  player = sp
  playerMode = 'script'

  if (ctx.state === 'suspended') await ctx.resume()
}

function feedPcm(arrayBuffer) {
  // 手机 App 在播时网页端必须完全静音：一旦送进播放器就会外放，
  // 电脑的 WASAPI loopback 会把外放声再采一遍推回手机 → 手机上听到两份。
  if (!audioEnabled) return
  if (!player) return
  if (playerMode === 'worklet') {
    player.port.postMessage(arrayBuffer, [arrayBuffer])
    return
  }
  if (playerMode === 'script') {
    scriptQueue.push(new Float32Array(arrayBuffer))
  }
}

async function applyAudioConfig(msg) {
  // 被手机 App 接管期间只当「在线监测连接」用，不建播放图。
  // 一旦建了 AudioContext / 媒体元素，声音就会从电脑扬声器出来被 loopback 采回去。
  if (!audioEnabled) return
  config = {
    sampleRate: Number(msg.sampleRate) || 48000,
    channels: Number(msg.channels) || 2,
    format: msg.format || 'f32',
  }
  sampleRateEl.textContent = `${config.sampleRate} Hz`
  channelsEl.textContent = String(config.channels)
  setStatus('收到配置，初始化播放器…', true)
  try {
    await ensurePlayer(config.sampleRate)
    setStatus(playingLabel(), true)
  } catch (err) {
    console.error(err)
    setStatus(`播放器初始化失败：${err.message || err}`)
  }
}

/* ------------------------------------------------------------------ */
/* WebSocket                                                           */
/* ------------------------------------------------------------------ */

function scheduleReconnect() {
  // 锁屏/后台同样要重连：不再因为 document.hidden 而放弃。
  // 另外：手机 App 在线时即使本机没在收听也要保持一条监测连接，
  // 否则收不到「手机已断开」的通知，按钮会一直锁死。
  if ((!listening && nativePeerCount === 0) || reconnectTimer) return
  const delay = Math.min(8000, 500 * 2 ** reconnectAttempt)
  reconnectAttempt += 1
  setStatus(`连接断开，${Math.round(delay / 1000)}s 后重连…`)
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    if (!listening && nativePeerCount === 0) return
    connectWs()
  }, delay)
}

function connectWs() {
  clearReconnect()

  // 手机端没配对码时不要建立连接（服务端会握手拒绝），给出明确提示即可。
  if (!pairingReady()) {
    setStatus('请先输入配对码')
    pairingHint.textContent = '请先输入配对码，保存后才能连接收听。'
    return
  }
  pairingRejected = false

  if (ws) {
    ws.onclose = null
    ws.onerror = null
    ws.onmessage = null
    try {
      ws.close()
    } catch {
      /* ignore */
    }
    ws = null
  }

  ws = new WebSocket(wsUrl())
  ws.binaryType = 'arraybuffer'
  setStatus('连接中…')

  ws.onopen = () => {
    reconnectAttempt = 0
    // 重连后丢弃旧缓冲，避免回放上一段陈旧音频
    resetPlayerBuffer()
    setStatus(config ? playingLabel() : '已连接，等待音频配置…', true)
    try {
      // 先声明要不要收 PCM：被手机顶掉时这里为 false，
      // 服务端就不会再往下行灌数据，链路彻底干净。
      ws.send(JSON.stringify({ type: 'wants-audio', value: audioEnabled }))
      // 重连后必须重新开闸，否则手机端会一直安静
      if (listening) ws.send(JSON.stringify({ type: 'start-stream' }))
      ws.send(JSON.stringify({ type: 'get-config' }))
    } catch {
      /* ignore */
    }
  }

  ws.onmessage = (event) => {
    if (typeof event.data === 'string') {
      let msg
      try {
        msg = JSON.parse(event.data)
      } catch {
        return
      }
      if (msg.type === 'audio-config') {
        applyAudioConfig(msg)
      } else if (msg.type === 'peer-mode') {
        applyPeerMode(Number(msg.nativeCount) || 0)
      } else if (msg.type === 'stream-state') {
        // 只处理「确认开闸之后又被关掉」的情况（另一个标签页点了停止）。
        // 刚连上时服务端会先发一次 enabled:false，那是初始态，不能当成停止。
        if (msg.enabled) {
          streamConfirmed = true
        } else if (streamConfirmed && listening) {
          streamConfirmed = false
          softStop('推流已被停止')
        }
      } else if (msg.type === 'error') {
        setStatus(`错误：${msg.message}`)
      } else if (msg.type === 'status') {
        if (!config) setStatus(msg.message, String(msg.message).includes('start'))
      }
      return
    }

    if (event.data instanceof ArrayBuffer) {
      feedPcm(event.data)
    }
  }

  ws.onclose = () => {
    ws = null
    // 握手被拒（配对码错误）：停止重连，让用户改配对码后再点开始。
    if (pairingRejected) {
      pairingRejected = false
      listening = false
      btnStart.disabled = false
      btnStop.disabled = true
      pairingBadge.textContent = '配对码错误'
      pairingBadge.classList.remove('on')
      pairingHint.textContent = '配对码不正确，请向电脑端确认后重新输入。'
      setStatus('配对失败：配对码错误')
      return
    }
    if (listening || nativePeerCount > 0) {
      scheduleReconnect()
    } else {
      setStatus('连接已断开')
      btnStart.disabled = false
      btnStop.disabled = true
    }
  }

  ws.onerror = () => {
    // 浏览器不会把 403 的具体原因暴露给 JS；非本机连接失败一律先怀疑配对码。
    if (!isLocalPage) pairingRejected = true
    if (!listening) setStatus('WebSocket 错误')
  }
}

/* ------------------------------------------------------------------ */
/* 自愈 watchdog                                                       */
/* ------------------------------------------------------------------ */

function startWatchdog() {
  stopWatchdog()
  heartbeatTick = 0
  watchdogTimer = setInterval(() => {
    if (!listening) return

    // 心跳与重连跟「本机是否出声」无关：手机在线时本机静音，
    // 但 socket 必须活着，否则收不到「手机已断开」，总闸就没法恢复。
    if (!ws || ws.readyState === WebSocket.CLOSED || ws.readyState === WebSocket.CLOSING) {
      if (!reconnectTimer) connectWs()
      return
    }

    heartbeatTick += 1
    if (ws.readyState === WebSocket.OPEN && heartbeatTick * WATCHDOG_MS >= HEARTBEAT_MS) {
      heartbeatTick = 0
      try {
        ws.send(JSON.stringify({ type: 'ping' }))
      } catch {
        /* ignore */
      }
    }

    // 本机静音期间没有播放图，下面这些自愈动作没意义
    if (!audioEnabled) return

    if (audioContext && audioContext.state !== 'running') {
      audioContext.resume().catch(() => {})
    }
    if (sinkAudio && sinkAudio.paused) {
      sinkAudio.play().catch(() => {})
    }
  }, WATCHDOG_MS)
}

function stopWatchdog() {
  if (watchdogTimer) {
    clearInterval(watchdogTimer)
    watchdogTimer = null
  }
  heartbeatTick = 0
}

/** 回到前台时补齐状态；锁屏期间播放不会中断。 */
async function resumePlayback() {
  if (!listening) return

  if (audioContext && audioContext.state === 'suspended') {
    try {
      await audioContext.resume()
    } catch (err) {
      console.warn('AudioContext.resume failed', err)
    }
  }
  if (sinkAudio && sinkAudio.paused) {
    try {
      await sinkAudio.play()
    } catch (err) {
      console.warn('[media] resume failed', err)
    }
  }

  const needWs = !ws || ws.readyState !== WebSocket.OPEN
  if (needWs) {
    reconnectAttempt = 0
    if (!reconnectTimer) {
      setStatus('正在重连…', true)
      connectWs()
    }
    return
  }

  if (config && player) setStatus(playingLabel(), true)
}

/* ------------------------------------------------------------------ */
/* 启停                                                                */
/* ------------------------------------------------------------------ */

async function start() {
  listening = true
  // 手机 App 在线时本机不发声（否则外放被 loopback 采回去 → 手机听到回声）
  audioEnabled = nativePeerCount === 0
  streamConfirmed = false
  btnStart.disabled = true
  btnStop.disabled = false
  config = null
  reconnectAttempt = 0
  clearReconnect()

  // 用户手势内解锁音频 & 让媒体元素真正播放起来
  const unlock = new AudioContext()
  if (unlock.state === 'suspended') await unlock.resume()
  await unlock.close()

  if (audioEnabled) await primeMediaElement()
  if (KEEP_SCREEN_ON) enableNoSleep()

  startWatchdog()
  connectWs()
}

/** 只回到停止态、不动 socket（用于被服务端/其它标签页关闸的情况） */
function softStop(reason) {
  listening = false
  audioEnabled = false
  stopWatchdog()
  disableNoSleep()
  destroyPlayer()
  if (audioContext) {
    audioContext.close().catch(() => {})
    audioContext = null
  }
  stopMediaElement()
  config = null
  btnStart.disabled = false
  btnStop.disabled = true
  bufferedEl.textContent = '0'
  levelEl.style.width = '0%'
  setStatus(reason || '已停止')
}

async function stop() {
  listening = false
  audioEnabled = false
  clearReconnect()
  stopWatchdog()
  reconnectAttempt = 0
  btnStart.disabled = false
  btnStop.disabled = true

  disableNoSleep()

  if (ws) {
    // 先关闸再断开：服务端只有收到 stop-stream 才会停止下发，
    // 否则要等 close 事件里的 owner 清理，中间会多推几十毫秒
    try {
      ws.send(JSON.stringify({ type: 'stop-stream' }))
    } catch {
      /* ignore */
    }
    ws.onclose = null
    try {
      ws.close()
    } catch {
      /* ignore */
    }
    ws = null
  }
  streamConfirmed = false
  destroyPlayer()
  if (audioContext) {
    try {
      await audioContext.close()
    } catch {
      /* ignore */
    }
    audioContext = null
  }
  stopMediaElement()
  config = null
  setStatus('已停止')
  bufferedEl.textContent = '0'
  levelEl.style.width = '0%'
}

/* ------------------------------------------------------------------ */
/* 手机 App 接管                                                       */
/* ------------------------------------------------------------------ */

/**
 * 手机 App 在线时把**本机**静音，但不动总开关。
 * 网页外放的声音会被电脑的 WASAPI loopback 重新采进去，再推回手机播一遍，
 * 手机听到的就是「原声 + 延迟副本」——这是物理闭环，只能在源头掐断。
 *
 * 这里绝不能调用完整的 stop()：那会关掉总闸，手机也跟着没声了；
 * 也不能只关 socket：断了就收不到「手机已断开」的通知，「开始收听」会永久卡住。
 * 正确做法是只掐本机音频通道（audioEnabled=false + wants-audio:false），保留 socket。
 */
async function muteLocalAudio() {
  audioEnabled = false
  // 注意：不 stopWatchdog()。总闸还开着，socket 与心跳必须继续跑，
  // 否则手机断开时收不到通知，界面会一直停在「已接管」。
  disableNoSleep()
  try {
    ws?.send(JSON.stringify({ type: 'wants-audio', value: false }))
  } catch {
    /* ignore */
  }
  destroyPlayer()
  if (audioContext) {
    try {
      await audioContext.close()
    } catch {
      /* ignore */
    }
    audioContext = null
  }
  stopMediaElement()
  config = null
  bufferedEl.textContent = '0'
  levelEl.style.width = '0%'
}

/** 手机走了，本机恢复出声（前提是总闸还开着） */
function resumeLocalAudio() {
  audioEnabled = true
  try {
    ws?.send(JSON.stringify({ type: 'wants-audio', value: true }))
  } catch {
    /* ignore */
  }
  resetPlayerBuffer()
  startWatchdog()
  try {
    ws?.send(JSON.stringify({ type: 'get-config' }))
  } catch {
    /* ignore */
  }
}

function applyPeerMode(count) {
  const prev = nativePeerCount
  nativePeerCount = count

  if (count > 0) {
    if (prev === 0) {
      muteLocalAudio()
      setStatus(
        listening
          ? '手机 App 已接管，本机已静音（避免回声）'
          : '手机 App 在线，点「开始收听」后手机开始播放',
      )
    }
  } else if (prev > 0) {
    if (listening) {
      resumeLocalAudio()
      setStatus('手机 App 已断开，恢复本机播放')
    } else {
      setStatus('手机 App 已断开')
    }
  }

  // 总开关与停止按钮的可用性只取决于 listening，跟手机在不在线无关。
  // 旧逻辑在手机上线时把两个按钮一起 disable，导致「点了开始却停不下来」。
  btnStart.disabled = listening
  btnStop.disabled = !listening
}

btnStart.addEventListener('click', () => {
  start().catch((err) => {
    console.error(err)
    setStatus(String(err.message || err))
    listening = false
    stopWatchdog()
    disableNoSleep()
    btnStart.disabled = false
    btnStop.disabled = true
  })
})

btnStop.addEventListener('click', () => {
  stop().catch(console.error)
})

/* 页面不可见（含锁屏）不再暂停播放，只做状态提示。 */
document.addEventListener('visibilitychange', () => {
  if (!listening) return
  if (document.visibilityState === 'visible') {
    resumePlayback().catch(console.error)
  } else if (config && player) {
    setStatus(playingLabel(), true)
  }
})

window.addEventListener('pageshow', (ev) => {
  if (ev.persisted || document.visibilityState === 'visible') {
    resumePlayback().catch(console.error)
  }
})

window.addEventListener('focus', () => {
  if (!document.hidden) {
    resumePlayback().catch(console.error)
  }
})

// 部分移动端解锁屏幕时触发
document.addEventListener('resume', () => {
  resumePlayback().catch(console.error)
})

// 熄屏/后台后浏览器可能回收定时器，回到前台立即自检一次
window.addEventListener('online', () => {
  if (listening) resumePlayback().catch(console.error)
})

/**
 * 排障用状态快照。手机端可在地址栏执行（需在页面上下文）：
 *   __toneferry.state
 * 或在电脑 Chrome 远程调试里查看。锁屏无声时先看 sinkHasStream / audioContext。
 */
/* ------------------------------------------------------------------ */
/* 关闭网页（电脑本机）：关页面不停推流，程序留在托盘，手机继续收听      */
/* ------------------------------------------------------------------ */

/**
 * 关掉电脑上的网页，但不停止推流：
 * 1. 先把推流闸的所有权转给服务端持久哨兵（start 走 API_OWNER），
 *    这样本页 WebSocket 断开时不会触发关闸 —— 手机还能继续收听。
 * 2. 再尝试 window.close()。浏览器通常只允许脚本关闭自己打开的窗口，
 *    手动输入地址打开的标签关不掉，此时给出明确提示。
 */
async function closePage() {
  try {
    await control('start')
  } catch {
    /* 即便控制请求失败也继续尝试关闭，不能把用户卡在页面上 */
  }
  if (closePageHint) closePageHint.hidden = false
  setStatus('已请求关闭网页，程序在右下角托盘继续运行，手机可继续收听')
  try {
    window.close()
  } catch {
    /* ignore */
  }
  // window.close() 被浏览器忽略时（非脚本打开的标签），1.2s 后仍停留则提示手动关
  setTimeout(() => {
    setStatus('请手动关闭此标签页；程序在右下角托盘运行，手机可继续收听')
  }, 1200)
}

btnClosePage?.addEventListener('click', () => {
  closePage().catch(console.error)
})

/* ------------------------------------------------------------------ */
/* 本地控制 API / 最近连接                                             */
/* ------------------------------------------------------------------ */

async function control(action) {
  try {
    const r = await fetch('/api/control', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action }),
    })
    const j = await r.json()
    if (j && typeof j.streamEnabled === 'boolean') {
      // 托盘那边点了开始/停止，同步一下按钮状态
      if (j.streamEnabled && !listening) {
        setStatus('已由电脑端开启推流')
      }
    }
    refreshPeers()
    return j
  } catch (err) {
    setStatus(`操作失败：${err.message || err}`)
    return null
  }
}

function relTime(ts) {
  const diff = Math.max(0, Date.now() - ts)
  if (diff < 60_000) return '刚刚'
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`
  return `${Math.floor(diff / 86_400_000)} 天前`
}

function renderPeers(list) {
  if (!peersList) return
  peersBadge.textContent = String(list.length)
  if (!list.length) {
    peersList.innerHTML = '<li class="tf-peer-empty">暂无记录</li>'
    return
  }
  peersList.innerHTML = ''
  for (const p of list.slice(0, 8)) {
    const li = document.createElement('li')
    li.className = 'tf-peer'
    const kind = p.kind === 'app' ? 'App' : '网页'
    li.innerHTML =
      `<span class="tf-peer-ip">${p.ip}</span>` +
      `<span>${kind} · ${relTime(p.lastSeen)}</span>`
    peersList.appendChild(li)
  }
}

async function refreshPeers() {
  try {
    const r = await fetch('/api/peers', { cache: 'no-store' })
    const j = await r.json()
    renderPeers(Array.isArray(j.peers) ? j.peers : [])
  } catch {
    /* 服务端不在就静默 */
  }
}

async function refreshLocalFlag() {
  try {
    const r = await fetch('/api/status', { cache: 'no-store' })
    const j = await r.json()
    const wasLocal = isLocalPage
    isLocalPage = !!j.local
    // 「关闭网页」只对电脑本机页面有意义：手机页面关掉就没法收听了。
    if (btnClosePage) btnClosePage.hidden = !isLocalPage

    // 配对码只在 status 里对本机返回；本机显示大字供手机输入，手机显示输入框。
    if (pairingLocalCard) pairingLocalCard.hidden = !isLocalPage
    if (pairingPhoneCard) pairingPhoneCard.hidden = isLocalPage
    if (isLocalPage) {
      if (pairingCodeEl && j.pairingCode) pairingCodeEl.textContent = j.pairingCode
    } else if (pairingInput && document.activeElement !== pairingInput) {
      pairingInput.value = savedPin
    }

    // 本机/手机身份发生变化时，按新角色重建连接。
    if (wasLocal !== isLocalPage && listening) connectWs()
  } catch {
    // 保持上一次的判断：网络抖一下不该让按钮闪没
  }
}

function savePairing() {
  const val = String(pairingInput?.value || '').trim()
  if (!/^\d{4,8}$/.test(val)) {
    pairingBadge.textContent = '格式错误'
    pairingBadge.classList.remove('on')
    pairingHint.textContent = '请输入 4~8 位数字配对码。'
    return
  }
  savedPin = val
  try {
    localStorage.setItem(PIN_KEY, savedPin)
  } catch {
    /* ignore */
  }
  pairingBadge.textContent = '已保存'
  pairingBadge.classList.add('on')
  pairingHint.textContent = '配对码已保存，正在连接…'
  // 配对码变了，用新凭据重连；若之前因未配对被拦，这里就能接上。
  if (listening || nativePeerCount > 0) connectWs()
}

btnPairing?.addEventListener('click', savePairing)
pairingInput?.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') savePairing()
})

// 手机端：已保存过配对码就回填并标记，省得每次重输
if (!isLocalPage && savedPin) {
  if (pairingInput) pairingInput.value = savedPin
  if (pairingBadge) {
    pairingBadge.textContent = '已保存'
    pairingBadge.classList.add('on')
  }
}

refreshLocalFlag()
refreshPeers()
// 页面加载时服务端可能还没起来，本地标记要持续刷新，否则关闭网页按钮永远不出现
setInterval(refreshLocalFlag, 8000)
setInterval(refreshPeers, 8000)

window.__toneferry = {
  get state() {
    return {
      listening,
      wsState: ws ? ws.readyState : null,
      audioContext: audioContext ? audioContext.state : null,
      playerMode,
      usingSink,
      sinkPaused: sinkAudio ? sinkAudio.paused : null,
      sinkHasStream: !!(sinkAudio && sinkAudio.srcObject),
      buffered: bufferedEl.textContent,
      status: statusText.textContent,
    }
  },
  async probe() {
    if (sinkAudio && sinkAudio.paused) await sinkAudio.play().catch(() => {})
    if (audioContext && audioContext.state !== 'running') await audioContext.resume().catch(() => {})
    return this.state
  },
}

// 麦克风授权 + 上行链路 + 最近连接 的端到端验证。
// 用法：先起服务端（node server/index.js 或 release/Toneferry.exe），再跑：
//   TF_URL=ws://127.0.0.1:3099/audio TF_API=http://127.0.0.1:3099 node scripts/test-mic.cjs
const { WebSocket } = require('ws')

const WS_URL = process.env.TF_URL || 'ws://127.0.0.1:3099/audio'
const API = process.env.TF_API || 'http://127.0.0.1:3099'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const results = []
function check(name, ok, extra) {
  results.push({ name, ok })
  console.log(`${ok ? '[ok]  ' : '[FAIL]'} ${name}${extra ? '  ' + extra : ''}`)
}

async function api(path, body) {
  const opt = body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : {}
  const r = await fetch(API + path, opt)
  return r.json()
}

function connect(ua) {
  const ws = new WebSocket(WS_URL, { headers: { 'user-agent': ua } })
  ws.msgs = []
  ws.on('message', (d, isBinary) => {
    if (!isBinary) ws.msgs.push(JSON.parse(String(d)))
  })
  return new Promise((res, rej) => {
    ws.once('open', () => res(ws))
    ws.once('error', rej)
  })
}

function micFrame(samples, freq = 440) {
  const buf = Buffer.alloc(4 + samples * 4)
  buf.writeUInt32LE(1, 0)
  for (let i = 0; i < samples; i++) {
    buf.writeFloatLE(Math.sin((2 * Math.PI * freq * i) / 48000) * 0.2, 4 + i * 4)
  }
  return buf
}

;(async () => {
  const phone = await connect('Toneferry-iOS/1.6 (native)')
  const pc = await connect('Mozilla/5.0 Chrome/120')
  await sleep(500)

  // 1) 初始必须未授权
  let st = await api('/api/status')
  check('默认不允许麦克风', st.mic && st.mic.granted === false, `granted=${st.mic && st.mic.granted}`)

  // 2) 手机请求 → 进入 pending，且服务端通知电脑端
  phone.send(JSON.stringify({ type: 'mic-open' }))
  await sleep(400)
  st = await api('/api/status')
  check('未授权时请求被挂起', st.mic.pending === true, `pending=${st.mic.pending}`)
  check(
    '电脑端收到 mic-request',
    pc.msgs.some((m) => m.type === 'mic-request'),
  )

  // 3) 未授权时上行帧必须被丢弃
  const before = (await api('/api/status')).mic.frames
  for (let i = 0; i < 5; i++) phone.send(micFrame(960))
  await sleep(300)
  st = await api('/api/status')
  check('未授权时上行被丢弃', st.mic.frames === before, `frames=${st.mic.frames}`)

  // 4) 电脑端授权 → 手机开始推流
  st = await api('/api/control', { action: 'grant-mic' })
  check('授权后 granted=true', st.mic.granted === true)
  check('授权后 active=true', st.mic.active === true)
  await sleep(200)

  const f0 = (await api('/api/status')).mic.frames
  for (let i = 0; i < 10; i++) {
    phone.send(micFrame(960))
    await sleep(25)
  }
  await sleep(300)
  st = await api('/api/status')
  check('授权后上行帧被接收', st.mic.frames > f0, `${f0} → ${st.mic.frames}`)
  check('播放器已就绪', st.mic.playerReady === true)

  // 5) 撤销授权 → 立即停止
  st = await api('/api/control', { action: 'revoke-mic' })
  check('撤销后 granted=false', st.mic.granted === false)
  check('撤销后 active=false', st.mic.active === false)
  const f1 = (await api('/api/status')).mic.frames
  for (let i = 0; i < 5; i++) phone.send(micFrame(960))
  await sleep(300)
  check('撤销后上行再次被丢弃', (await api('/api/status')).mic.frames === f1)

  // 6) 最近连接记录
  const peers = await api('/api/peers')
  check('记录了连接过的 IP', Array.isArray(peers.peers) && peers.peers.length > 0, `count=${peers.peers.length}`)
  check(
    '记录区分 App / 网页',
    peers.peers.some((p) => p.kind === 'app') && peers.peers.some((p) => p.kind === 'browser'),
  )

  // 7) 非本机不能授权（用 Host 头伪造不了，这里只验证接口存在且 403 逻辑生效于非 loopback）
  const st2 = await api('/api/status')
  check('status 带 local 字段', typeof st2.local === 'boolean', `local=${st2.local}`)

  phone.close()
  pc.close()
  const bad = results.filter((r) => !r.ok)
  console.log(`\n通过 ${results.length - bad.length}/${results.length}`)
  process.exit(bad.length ? 1 : 0)
})().catch((e) => {
  console.error('test error:', e.message)
  process.exit(2)
})

// 推流总闸行为验证：不点开始收听 -> 一帧都不下发
const { WebSocket } = require('ws')

const URL = process.env.TF_URL || 'ws://127.0.0.1:3099/audio'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function connect(ua) {
  const ws = new WebSocket(URL, { headers: { 'user-agent': ua } })
  ws.frames = 0
  ws.msgs = []
  ws.on('message', (data, isBinary) => {
    if (isBinary) ws.frames++
    else ws.msgs.push(String(data))
  })
  return new Promise((res, rej) => {
    ws.once('open', () => res(ws))
    ws.once('error', rej)
  })
}

const results = []
function check(name, ok, extra) {
  results.push({ name, ok, extra })
  console.log(`${ok ? '[ok]  ' : '[FAIL]'} ${name}${extra ? '  ' + extra : ''}`)
}

;(async () => {
  const native = await connect('Toneferry-iOS/1.5 (native)')
  const browser = await connect('Mozilla/5.0 Chrome/120')
  await sleep(400)

  // 1) 初始态：未开闸，两端都不该收到任何二进制帧
  native.frames = 0
  browser.frames = 0
  await sleep(1200)
  check('未点开始时服务端不下发音频（手机端）', native.frames === 0, `frames=${native.frames}`)
  check('未点开始时服务端不下发音频（浏览器端）', browser.frames === 0, `frames=${browser.frames}`)
  check(
    '新连接收到 stream-state=false',
    native.msgs.some((m) => m.includes('stream-state') && m.includes('false')),
    native.msgs.filter((m) => m.includes('stream-state')).join(' | ') || 'none',
  )

  // 2) 浏览器点「开始收听」
  browser.send(JSON.stringify({ type: 'start-stream' }))
  native.frames = 0
  browser.frames = 0
  await sleep(1500)
  check('开闸后手机端收到音频', native.frames > 0, `frames=${native.frames}`)
  check('开闸后浏览器端也收到音频', browser.frames > 0, `frames=${browser.frames}`)

  // 3) 手机接管 -> 浏览器退订，本机静音但总闸不动
  browser.send(JSON.stringify({ type: 'wants-audio', value: false }))
  await sleep(300)
  native.frames = 0
  browser.frames = 0
  await sleep(1200)
  check('浏览器退订后不再收 PCM', browser.frames === 0, `frames=${browser.frames}`)
  check('总闸仍开，手机继续收', native.frames > 0, `frames=${native.frames}`)

  // 4) 点停止 -> 全停
  browser.send(JSON.stringify({ type: 'stop-stream' }))
  await sleep(400)
  native.frames = 0
  browser.frames = 0
  await sleep(1200)
  check('点停止后手机端静音', native.frames === 0, `frames=${native.frames}`)

  // 5) 重新开闸，验证恢复
  browser.send(JSON.stringify({ type: 'start-stream' }))
  native.frames = 0
  await sleep(1200)
  check('再次开始后手机端恢复', native.frames > 0, `frames=${native.frames}`)

  // 6) 发起方断开 -> 自动关闸
  browser.close()
  await sleep(500)
  native.frames = 0
  await sleep(1200)
  check('发起方断开后自动关闸', native.frames === 0, `frames=${native.frames}`)

  native.close()
  const bad = results.filter((r) => !r.ok)
  console.log(`\n通过 ${results.length - bad.length}/${results.length}`)
  process.exit(bad.length ? 1 : 0)
})().catch((e) => {
  console.error('test error:', e.message)
  process.exit(2)
})

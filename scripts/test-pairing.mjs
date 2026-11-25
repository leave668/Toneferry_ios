/**
 * 配对码鉴权专项测试（Node ESM）。
 * 直接引入 server/pairing.js —— 与服务端握手用的是同一份实现。
 */
import { allowHandshake, normalizePin } from '../server/pairing.js'

const local = new Set(['127.0.0.1', '::1', '192.168.0.80'])
const PIN = '123456'

const cases = [
  ['本机回环地址免配对码', { remoteIp: '127.0.0.1', queryPin: '' }, true],
  ['本机 IPv6 回环免配对码', { remoteIp: '::1', queryPin: '' }, true],
  ['本机网卡 IP 免配对码', { remoteIp: '192.168.0.80', queryPin: '' }, true],
  ['::ffff: 前缀的本机地址', { remoteIp: '::ffff:127.0.0.1', queryPin: '' }, true],
  ['外部设备+正确配对码放行', { remoteIp: '192.168.0.55', queryPin: PIN }, true],
  ['外部设备+错误配对码拒绝', { remoteIp: '192.168.0.55', queryPin: '000000' }, false],
  ['外部设备+无配对码拒绝', { remoteIp: '192.168.0.55', queryPin: '' }, false],
  ['外部设备+非数字配对码拒绝', { remoteIp: '192.168.0.55', queryPin: 'abcdef' }, false],
  ['::ffff: 前缀的外部 IP 仍拦截', { remoteIp: '::ffff:192.168.0.55', queryPin: '' }, false],
  ['外部设备带码但服务端未设码', { remoteIp: '192.168.0.55', queryPin: '1234', pinOverride: '' }, false],
]

let pass = 0
for (const [name, input, want] of cases) {
  const { pinOverride, ...rest } = input
  const got = allowHandshake({ localAddresses: local, pin: pinOverride ?? PIN, ...rest })
  const ok = got === want
  if (ok) pass++
  console.log(`${ok ? '[ok]  ' : '[FAIL]'} ${name} => ${got}`)
}

const norm = [
  ['123456', '123456'],
  [' 1234 ', '1234'],
  ['abc', ''],
  ['12345', '12345'],
  ['123456789', ''],
]
for (const [inV, want] of norm) {
  const got = normalizePin(inV)
  const ok = got === want
  if (ok) pass++
  console.log(`${ok ? '[ok]  ' : '[FAIL]'} normalize(${JSON.stringify(inV)}) => ${JSON.stringify(got)}`)
}

const total = cases.length + norm.length
console.log(`\n通过 ${pass}/${total}`)
process.exit(pass === total ? 0 : 1)

/**
 * 配对码鉴权：共享给服务端与测试脚本，保证测的就是线上跑的判断逻辑。
 *
 * 规则：
 *   - 本机地址（回环 / 本机网卡 IP）永远放行；
 *   - 局域网设备必须在 query 上带正确的配对码；
 *   - 配对码只认 4~8 位纯数字。
 */

/** 归一化配对码：合法返回字符串，非法返回空串。 */
function normalizePin(v) {
  const s = String(v == null ? '' : v).trim()
  return /^\d{4,8}$/.test(s) ? s : ''
}

/**
 * 判断一个 WS 握手是否允许通过。
 * @param {object} o
 * @param {string} o.remoteIp     socket.remoteAddress（可能带 ::ffff: 前缀）
 * @param {Set<string>} o.localAddresses  本机地址集合
 * @param {string} o.pin         服务端持有的配对码
 * @param {string} o.queryPin     握手 URL 上 ?pin= 的值
 * @returns {boolean}
 */
function allowHandshake({ remoteIp, localAddresses, pin, queryPin }) {
  let ip = String(remoteIp || '')
  if (ip.startsWith('::ffff:')) ip = ip.slice(7)
  if (ip === '::1') ip = '127.0.0.1'
  // 本机连接自动放行，不需要配对码
  if (localAddresses && localAddresses.has(ip)) return true
  // 外部设备必须带正确配对码
  const want = normalizePin(pin)
  const got = normalizePin(queryPin)
  return !!want && !!got && got === want
}

export { normalizePin, allowHandshake }

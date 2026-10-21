/**
 * 最近连接记录。
 *
 * 目的：手机 / 浏览器每次连上来都记一笔，方便在电脑端（托盘菜单）和网页端
 * 看到「最近有哪些设备连过」，也方便排查「是不是别人连了我的推流」。
 *
 * 存储：%LOCALAPPDATA%\Toneferry\peers.json（非 Windows 落到 ~/.toneferry/）
 * 上限：最近 30 条，按 lastSeen 倒序。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const MAX_PEERS = 30

export function dataDir() {
  if (process.platform === 'win32') {
    const base = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local')
    return path.join(base, 'Toneferry')
  }
  return path.join(os.homedir(), '.toneferry')
}

export function createPeerStore() {
  const dir = dataDir()
  const file = path.join(dir, 'peers.json')
  /** @type {Array<{ip:string, kind:string, ua:string, firstSeen:number, lastSeen:number, count:number}>} */
  let peers = []
  let saveTimer = null

  try {
    fs.mkdirSync(dir, { recursive: true })
    if (fs.existsSync(file)) {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
      if (Array.isArray(raw)) peers = raw.filter((p) => p && typeof p.ip === 'string')
    }
  } catch {
    peers = []
  }

  function persist() {
    if (saveTimer) return
    saveTimer = setTimeout(() => {
      saveTimer = null
      try {
        fs.mkdirSync(dir, { recursive: true })
        fs.writeFileSync(file, JSON.stringify(peers, null, 2), 'utf8')
      } catch {
        /* 磁盘不可写就只保留内存副本，不影响主流程 */
      }
    }, 400)
  }

  function normalizeIp(raw) {
    let ip = String(raw || '').trim()
    if (!ip) return ''
    // ws 的 req.socket.remoteAddress 在双栈下是 ::ffff:192.168.0.80
    if (ip.startsWith('::ffff:')) ip = ip.slice(7)
    if (ip === '::1') ip = '127.0.0.1'
    return ip
  }

  return {
    /** 记录一次连接；同一 IP 只累加次数与时间，不新增条目 */
    touch(rawIp, kind, ua) {
      const ip = normalizeIp(rawIp)
      if (!ip) return null
      const now = Date.now()
      const hit = peers.find((p) => p.ip === ip && p.kind === kind)
      if (hit) {
        hit.lastSeen = now
        hit.count += 1
        if (ua) hit.ua = ua
      } else {
        peers.push({ ip, kind, ua: ua || '', firstSeen: now, lastSeen: now, count: 1 })
      }
      peers.sort((a, b) => b.lastSeen - a.lastSeen)
      if (peers.length > MAX_PEERS) peers.length = MAX_PEERS
      persist()
      return ip
    },

    list() {
      return peers.map((p) => ({ ...p }))
    },

    clear() {
      peers = []
      persist()
    },

    file,
  }
}

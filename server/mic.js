/**
 * 手机麦克风上行通道。
 *
 * 链路：手机（浏览器 / iOS App）采集 → WebSocket 二进制帧 → 本机 audio-play.exe
 *       → waveOut 渲染到默认输出设备 → 电脑扬声器/耳机出声。
 *
 * 安全模型：默认**不允许**。手机发起后必须由电脑端显式授权（托盘菜单 / 网页按钮），
 * 授权状态只保存在内存里，进程退出即失效 —— 不会出现「上次授权过，这次偷偷开麦」。
 *
 * 帧格式：客户端上行二进制帧第 1 字节是通道标识，0x01 = 麦克风；
 *         其后是裸 PCM，固定 **48000 Hz / 单声道 / Float32 小端**（客户端负责重采样）。
 */

import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'

export const MIC_CHANNEL_ID = 0x01
export const MIC_SAMPLE_RATE = 48000
export const MIC_CHANNELS = 1

/** 上行积压超过这个量就整段丢弃：麦克风延迟比爆音更难受。 */
const MAX_PENDING_BYTES = MIC_SAMPLE_RATE * 4 * 2 // 约 2 秒

export function createMicChannel({ playerPath, log = () => {}, onState = () => {} }) {
  let granted = false
  /** @type {any} 当前真正在推麦克风的连接 */
  let owner = null
  /** @type {any} 发起了请求、还在等电脑授权的连接 */
  let pending = null
  /** @type {import('node:child_process').ChildProcessWithoutNullStreams | null} */
  let player = null
  let frames = 0
  let dropped = 0

  const state = () => ({
    granted,
    active: !!owner,
    pending: !!pending,
    pendingIp: pending && pending.peerIp ? pending.peerIp : '',
    frames,
    dropped,
    playerReady: !!player,
  })

  const emit = () => onState(state())

  function ensurePlayer() {
    if (player) return player
    if (!playerPath || !fs.existsSync(playerPath)) {
      log(`[mic] 缺少播放器：${playerPath || '(未配置)'}，手机麦克风将无声`)
      return null
    }
    try {
      player = spawn(playerPath, [], { stdio: ['pipe', 'ignore', 'pipe'], windowsHide: true })
    } catch (err) {
      log(`[mic] 播放器启动失败：${err.message}`)
      player = null
      return null
    }
    player.on('error', (err) => {
      log(`[mic] 播放器错误：${err.message}`)
      player = null
    })
    player.stderr.on('data', (b) => {
      const s = String(b).trim()
      if (s) log(`[mic:player] ${s}`)
    })
    player.on('exit', (code) => {
      if (code !== 0) log(`[mic] 播放器退出 code=${code}`)
      player = null
    })
    player.stdin.on('error', () => {
      player = null
    })
    log('[mic] 播放器已启动（48000 Hz / 单声道 / Float32）')
    return player
  }

  function stopPlayer() {
    if (!player) return
    const p = player
    player = null
    try {
      p.stdin.end()
    } catch {
      /* ignore */
    }
    setTimeout(() => {
      try {
        p.kill()
      } catch {
        /* ignore */
      }
    }, 300)
  }

  function startFor(ws) {
    pending = null
    if (owner && owner !== ws) {
      try {
        owner.send(JSON.stringify({ type: 'mic-state', granted: true, active: false, reason: 'replaced' }))
      } catch {
        /* ignore */
      }
    }
    owner = ws
    frames = 0
    dropped = 0
    ensurePlayer()
    emit()
    return { status: 'granted' }
  }

  const api = {
    state,

    /** 手机点了麦克风开关 */
    open(ws) {
      if (!granted) {
        pending = ws
        emit()
        return { status: 'pending' }
      }
      return startFor(ws)
    },

    /** 电脑端点了「授权」 */
    grant() {
      granted = true
      emit()
      if (!pending) return { status: 'granted' }
      const ws = pending
      return startFor(ws)
    },

    deny() {
      const ws = pending
      pending = null
      emit()
      if (ws) {
        try {
          ws.send(JSON.stringify({ type: 'mic-state', granted: false, active: false, reason: 'denied' }))
        } catch {
          /* ignore */
        }
      }
      return { status: 'denied' }
    },

    revoke() {
      granted = false
      const ws = owner
      owner = null
      pending = null
      stopPlayer()
      emit()
      if (ws) {
        try {
          ws.send(JSON.stringify({ type: 'mic-state', granted: false, active: false, reason: 'revoked' }))
        } catch {
          /* ignore */
        }
      }
      return { status: 'revoked' }
    },

    /** 手机主动关掉麦克风 / 连接断开 */
    close(ws) {
      let changed = false
      if (pending === ws) {
        pending = null
        changed = true
      }
      if (owner === ws) {
        owner = null
        stopPlayer()
        changed = true
      }
      if (changed) emit()
    },

    detach(ws) {
      api.close(ws)
    },

    /** 收到一帧上行 PCM（已剥掉通道标识字节） */
    write(ws, buf) {
      if (!granted || owner !== ws) return false
      const p = ensurePlayer()
      if (!p) return false
      if (p.stdin.writableLength > MAX_PENDING_BYTES) {
        dropped += 1
        return false
      }
      try {
        p.stdin.write(buf)
        frames += 1
        return true
      } catch {
        player = null
        return false
      }
    },

    shutdown() {
      granted = false
      owner = null
      pending = null
      stopPlayer()
    },
  }

  return api
}

export function resolvePlayerPath(rootDir) {
  return path.join(rootDir, 'bin', 'audio-play.exe')
}

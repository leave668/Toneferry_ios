/**
 * 手机麦克风采集 Worklet（独立文件，不要内联成 Blob URL）。
 *
 * 之前用 `URL.createObjectURL(new Blob([...]))` 传给 addModule，
 * 部分浏览器会拒绝从 blob: 加载 worklet 模块；而且一旦并发调用
 * startMicCapture，两个 AudioContext 抢同一个 URL，就会出现
 * "AudioWorklet does not have a valid AudioWorkletGlobalScope"。
 * 独立文件 + 单次加载最稳。
 */
class TFMicrophone extends AudioWorkletProcessor {
  constructor() {
    super()
    this.step = 48000 / sampleRate
    this.frac = 0
    this.buf = new Float32Array(960)
    this.n = 0
  }

  flush() {
    if (this.n > 0) {
      this.port.postMessage(this.buf.slice(0, this.n))
      this.n = 0
    }
  }

  process(inputs) {
    const ch = inputs[0] && inputs[0][0]
    if (!ch) return true
    // 最近邻重采样到 48k；设备本来就是 48k 时 step=1，等于直通
    for (let i = 0; i < ch.length; i++) {
      this.frac += this.step
      while (this.frac >= 1) {
        this.frac -= 1
        this.buf[this.n++] = ch[i]
        if (this.n >= 960) this.flush()
      }
    }
    return true
  }
}

registerProcessor('tf-mic', TFMicrophone)

// audio-play.exe —— 把 stdin 里的 Float32 单声道 PCM 播放到 Windows 默认输出设备。
//
// 为什么单独做一个进程：Node 没法直接调 waveOut/WASAPI，而手机麦克风的音频
// 必须真的从电脑扬声器出来。服务端 spawn 本程序，把上行 PCM 写进 stdin 即可。
//
// 输入格式固定：48000 Hz / 1 声道 / float32 小端（与 server/mic.js 约定一致）。
// 输出：waveOut（winmm），8 个 20ms 缓冲轮转，端到端延迟约 40~80ms。
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
	"syscall"
	"time"
	"unsafe"
)

const (
	sampleRate  = 48000
	channels    = 1
	bitsPerSamp = 32
	bufferMS    = 20
	bufferCount = 8

	waveFormatIEEEFloat = 0x0003
	whdrDone            = 0x00000001
	waveMapper          = 0xFFFFFFFF

	// 手机麦克风的电平普遍偏低（系统不做 AGC，离嘴又远），
	// 直接放出来几乎听不清。用 tanh 做软限幅：小信号线性放大，
	// 大信号平滑压到 ±1，不会像硬乘法那样削顶爆音。
	inputGain = 3.0
)

type waveFormatEx struct {
	FormatTag      uint16
	Channels       uint16
	SamplesPerSec  uint32
	AvgBytesPerSec uint32
	BlockAlign     uint16
	BitsPerSample  uint16
	CbSize         uint16
}

type waveHdr struct {
	Data          uintptr
	BufferLength  uint32
	BytesRecorded uint32
	User          uintptr
	Flags         uint32
	Loops         uint32
	Next          uintptr
	Reserved      uintptr
}

var (
	winmm                = syscall.NewLazyDLL("winmm.dll")
	procWaveOutOpen      = winmm.NewProc("waveOutOpen")
	procWaveOutPrepare   = winmm.NewProc("waveOutPrepareHeader")
	procWaveOutWrite     = winmm.NewProc("waveOutWrite")
	procWaveOutReset     = winmm.NewProc("waveOutReset")
	procWaveOutClose     = winmm.NewProc("waveOutClose")
	procWaveOutGetNumDev = winmm.NewProc("waveOutGetNumDevs")
)

type buffer struct {
	data []byte
	hdr  waveHdr
	busy bool
}

func main() {
	if n, _, _ := procWaveOutGetNumDev.Call(); n == 0 {
		fmt.Fprintln(os.Stderr, "没有可用的音频输出设备")
		os.Exit(2)
	}

	frameBytes := channels * bitsPerSamp / 8
	bufSize := sampleRate * bufferMS / 1000 * frameBytes

	var wf waveFormatEx
	wf.FormatTag = waveFormatIEEEFloat
	wf.Channels = channels
	wf.SamplesPerSec = sampleRate
	wf.AvgBytesPerSec = sampleRate * uint32(frameBytes)
	wf.BlockAlign = uint16(frameBytes)
	wf.BitsPerSample = bitsPerSamp

	var handle uintptr
	r, _, _ := procWaveOutOpen.Call(
		uintptr(unsafe.Pointer(&handle)),
		waveMapper,
		uintptr(unsafe.Pointer(&wf)),
		0, 0, 0,
	)
	if r != 0 || handle == 0 {
		fmt.Fprintf(os.Stderr, "waveOutOpen 失败 code=%d\n", r)
		os.Exit(3)
	}
	defer procWaveOutClose.Call(handle)

	hdrSize := unsafe.Sizeof(waveHdr{})
	bufs := make([]*buffer, bufferCount)
	for i := range bufs {
		b := &buffer{data: make([]byte, bufSize)}
		b.hdr.Data = uintptr(unsafe.Pointer(&b.data[0]))
		b.hdr.BufferLength = uint32(bufSize)
		if pr, _, _ := procWaveOutPrepare.Call(handle, uintptr(unsafe.Pointer(&b.hdr)), hdrSize); pr != 0 {
			fmt.Fprintf(os.Stderr, "waveOutPrepareHeader 失败 code=%d\n", pr)
			os.Exit(4)
		}
		bufs[i] = b
	}

	pending := make([]byte, 0, bufSize)
	readBuf := make([]byte, bufSize)

	for {
		b := freeBuffer(bufs)
		if b == nil {
			// 全部在播：等一个空出来（同时给上游施加背压）
			time.Sleep(2 * time.Millisecond)
			continue
		}

		eof := false
		for len(pending) < bufSize {
			n, rerr := os.Stdin.Read(readBuf)
			if n > 0 {
				pending = append(pending, readBuf[:n]...)
			}
			if rerr != nil {
				if rerr == io.EOF {
					eof = true
					break
				}
				fmt.Fprintf(os.Stderr, "读 stdin 失败: %v\n", rerr)
				eof = true
				break
			}
		}

		if len(pending) == 0 && eof {
			drain(bufs)
			procWaveOutReset.Call(handle)
			return
		}

		// 尾部不足一块时补零，保证 waveOutWrite 拿到整块，避免爆音
		for len(pending) < bufSize {
			pending = append(pending, 0)
		}

		copy(b.data, pending[:bufSize])
		applyGain(b.data)
		b.hdr.Flags &^= whdrDone // 上一轮的 DONE 必须清掉，否则 waveOutWrite 会拒绝
		pending = pending[bufSize:]
		b.busy = true
		if wr, _, _ := procWaveOutWrite.Call(handle, uintptr(unsafe.Pointer(&b.hdr)), hdrSize); wr != 0 {
			b.busy = false
			fmt.Fprintf(os.Stderr, "waveOutWrite 失败 code=%d\n", wr)
			time.Sleep(5 * time.Millisecond)
		}

		if eof && len(pending) == 0 {
			drain(bufs)
			return
		}
	}
}

// applyGain 就地放大一块 Float32 PCM。
// tanh 软限幅：|x| 小时 tanh(gx) ≈ gx（等于线性增益），
// |x| 大时平滑趋向 ±1，不会出现硬削顶的方波失真。
func applyGain(p []byte) {
	for i := 0; i+4 <= len(p); i += 4 {
		bits := binary.LittleEndian.Uint32(p[i:])
		f := math.Float32frombits(bits)
		if f == 0 {
			continue
		}
		g := float32(math.Tanh(float64(f) * inputGain))
		binary.LittleEndian.PutUint32(p[i:], math.Float32bits(g))
	}
}

func freeBuffer(bufs []*buffer) *buffer {	for _, b := range bufs {
		if !b.busy {
			return b
		}
		if b.hdr.Flags&whdrDone != 0 {
			b.busy = false
			return b
		}
	}
	return nil
}

func drain(bufs []*buffer) {
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		busy := false
		for _, b := range bufs {
			if b.busy && b.hdr.Flags&whdrDone == 0 {
				busy = true
			}
		}
		if !busy {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
}

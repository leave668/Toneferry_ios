// Toneferry.exe —— 托盘宿主。
//
// 职责：
//  1. 以 GUI 子系统启动（双击不弹 cmd 黑框）
//  2. 把内嵌的 ToneferryServer.exe 释放到 %LOCALAPPDATA%\Toneferry\ 并隐藏启动
//  3. 托盘图标 + 右键菜单（开始/停止推送、授权手机麦克风、最近连接、打开网页、退出）
//  4. 手机请求麦克风时弹气泡提醒，等用户点「授权」
//
// 与服务端之间只走本地 HTTP（/api/status、/api/control），不共享内存，互不影响。
package main

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

//go:embed assets
var assets embed.FS

const (
	appName     = "Toneferry"
	windowClass = "ToneferryTrayWnd"

	WM_APP         = 0x8000
	wmTrayIcon     = WM_APP + 1
	wmRefresh      = WM_APP + 2
	wmBalloon      = WM_APP + 3
	wmTrayCallback = WM_APP + 4

	wmLButtonDblClk = 0x0203
	wmRButtonUp     = 0x0205

	nimAdd    = 0x00000000
	nimModify = 0x00000001
	nimDelete = 0x00000002

	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004
	nifInfo    = 0x00000010

	niifInfo = 0x00000001
	niifWarn = 0x00000002

	mfString    = 0x00000000
	mfGrayed    = 0x00000001
	mfChecked   = 0x00000008
	mfPopup     = 0x00000010
	mfSeparator = 0x00000800

	tpmLeftAlign   = 0x0000
	tpmRightButton = 0x0002
	tpmReturnCmd   = 0x0100

	idiApplication = 32512

	// CreateWindowExW 的 dwStyle 不能是 0：没有 WS_POPUP / WS_OVERLAPPED / WS_CHILD
	// 的顶层窗口会被系统拒绝创建，返回 NULL。窗口拿不到句柄，Shell_NotifyIcon 就
	// 一定失败 —— 表现就是「程序在跑，但右下角没有图标」。
	wsPopup = 0x80000000

	imageIcon      = 1
	lrLoadFromFile = 0x00000010

	createNoWindow = 0x08000000
)

// 菜单项 ID
const (
	idStart = 1001 + iota
	idStop
	idGrantMic
	idDenyMic
	idRevokeMic
	idOpenPage
	idOpenLog
	idClearPeers
	idQuit
)

const idPeerBase = 2000

type micState struct {
	Granted     bool   `json:"granted"`
	Active      bool   `json:"active"`
	Pending     bool   `json:"pending"`
	PendingIP   string `json:"pendingIp"`
	PlayerReady bool   `json:"playerReady"`
}

type peerInfo struct {
	IP       string `json:"ip"`
	Kind     string `json:"kind"`
	LastSeen int64  `json:"lastSeen"`
	Count    int    `json:"count"`
}

type serverStatus struct {
	OK             bool       `json:"ok"`
	Version        string     `json:"version"`
	Host           string     `json:"host"`
	Port           int        `json:"port"`
	URL            string     `json:"url"`
	StreamEnabled  bool       `json:"streamEnabled"`
	CaptureRunning bool       `json:"captureRunning"`
	Mic            micState   `json:"mic"`
	NativeCount    int        `json:"nativeCount"`
	Clients        int        `json:"clients"`
	Peers          []peerInfo `json:"peers"`
}

type notifyIconData struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         [16]byte
	HBalloonIcon     uintptr
}

type msgStruct struct {
	HWnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      struct{ X, Y int32 }
	Private uint32
}

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	pRegisterClassExW = user32.NewProc("RegisterClassExW")
	pCreateWindowExW  = user32.NewProc("CreateWindowExW")
	pDefWindowProcW   = user32.NewProc("DefWindowProcW")
	pGetMessageW      = user32.NewProc("GetMessageW")
	pTranslateMessage = user32.NewProc("TranslateMessage")
	pDispatchMessageW = user32.NewProc("DispatchMessageW")
	pPostMessageW     = user32.NewProc("PostMessageW")
	pCreatePopupMenu  = user32.NewProc("CreatePopupMenu")
	pAppendMenuW      = user32.NewProc("AppendMenuW")
	pTrackPopupMenu   = user32.NewProc("TrackPopupMenu")
	pDestroyMenu      = user32.NewProc("DestroyMenu")
	pSetForegroundWnd = user32.NewProc("SetForegroundWindow")
	pGetCursorPos     = user32.NewProc("GetCursorPos")
	pDestroyIcon      = user32.NewProc("DestroyIcon")
	pLoadIconW        = user32.NewProc("LoadIconW")
	pShellNotifyIconW = shell32.NewProc("Shell_NotifyIconW")
	pExtractIconExW   = shell32.NewProc("ExtractIconExW")
	pLoadImageW       = user32.NewProc("LoadImageW")
	pShellExecuteW    = shell32.NewProc("ShellExecuteW")
	pCreateMutexW     = kernel32.NewProc("CreateMutexW")
)

var (
	mu          sync.Mutex
	status      *serverStatus
	lastErr     string
	serverExe   string
	childCmd    *exec.Cmd
	hIcon       uintptr
	hwndMain    uintptr
	port        = 3088
	dataRoot    string
	micPrompted bool
)

func main() {
	runtime.LockOSThread()

	if len(os.Args) > 1 && (os.Args[1] == "--diagnose" || os.Args[1] == "/diagnose") {
		runDiagnose()
		return
	}

	if !ensureSingleInstance() {
		return
	}

	dir, err := dataDir()
	if err != nil {
		messageBox("Toneferry 启动失败",
			"无法创建数据目录，程序没有可写的磁盘位置。\r\n\r\n"+
				"常见原因：\r\n"+
				"  1. 程序被放在只读目录（如光盘、受保护的系统盘根目录）\r\n"+
				"  2. 安全软件拦截了写入\r\n\r\n"+
				"请把 Toneferry.exe 移到桌面或 D 盘后重试。\r\n错误："+err.Error())
		return
	}

	preferred := 3088
	if p := os.Getenv("PORT"); p != "" {
		fmt.Sscanf(p, "%d", &preferred)
	}
	port = pickPort(preferred)
	if port != preferred {
		hostLog("端口 %d 被占用，改用 %d", preferred, port)
	}

	serverExe, err = extractServer(dir)
	if err != nil {
		messageBox("Toneferry 启动失败",
			"释放内置服务端失败：\r\n"+err.Error()+"\r\n\r\n"+
				"这通常是杀毒软件 / Windows Defender 拦截了程序写出文件造成的。\r\n"+
				"请把 Toneferry.exe 加入安全软件白名单，或点「更多信息 → 仍要运行」后重试。\r\n\r\n"+
				"日志："+filepath.Join(dir, "host.log"))
		return
	}

	icoPath := extractIcon(dir)
	hIcon = loadIcon(serverExe, icoPath)
	hostLog("启动：dir=%q ico=%q hIcon=%d port=%d", dir, icoPath, hIcon, port)

	if err := startServer(); err != nil {
		messageBox("Toneferry 启动失败",
			"内置服务端无法启动：\r\n"+err.Error()+"\r\n\r\n"+
				"请把 Toneferry.exe 加入杀毒软件白名单后重试。\r\n"+
				"日志："+filepath.Join(dir, "toneferry.log"))
		return
	}

	// 子进程「启动成功」不等于「能服务」：杀软可能在 CreateProcess 之后立刻
	// 把 exe 删掉，或者服务端因为别的原因秒退。这里必须真正探活一次，
	// 否则用户看到的就是「双击了，什么都没发生」。
	if !waitServerReady(15 * time.Second) {
		tail := logTail(filepath.Join(dir, "toneferry.log"), 1800)
		if tail == "" {
			tail = "（日志为空，服务端可能被杀毒软件直接拦截，未能执行）"
		}
		messageBox("Toneferry 服务未就绪",
			fmt.Sprintf("内置服务端在 15 秒内没有响应 http://127.0.0.1:%d/ 。\r\n\r\n"+
				"请依次尝试：\r\n"+
				"  1. 把 Toneferry.exe 与 %%LOCALAPPDATA%%\\Toneferry 加入杀毒软件白名单\r\n"+
				"  2. 右键 Toneferry.exe → 属性 → 勾选「解除锁定」\r\n"+
				"  3. 用管理员身份运行一次\r\n\r\n"+
				"最近日志：\r\n%s", port, tail))
	}

	createTrayWindow()
	go pollLoop()

	// 服务端就绪后自动打开一次网页（托盘里也有入口）
	go func() {
		time.Sleep(1200 * time.Millisecond)
		openPage()
	}()

	messageLoop()
}

/* ------------------------------ 环境探测 ------------------------------ */

// pickPort 从首选端口往后找一个真正能绑定的端口。
// 3088 被别的程序占住时，服务端会 EADDRINUSE 秒退，表现就是「双击没反应」。
func pickPort(preferred int) int {
	for p := preferred; p < preferred+20; p++ {
		ln, err := net.Listen("tcp", fmt.Sprintf(":%d", p))
		if err == nil {
			ln.Close()
			return p
		}
	}
	return preferred
}

func waitServerReady(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := httpClient().Get(apiURL("/api/status"))
		if err == nil {
			io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return true
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

// logTail 读文件末尾若干字节，用于把失败原因直接摆在用户面前。
// 服务端日志带 ANSI 颜色码，落到报告里必须剥掉，否则是一堆乱码。
var ansiRe = regexp.MustCompile("\x1b\\[[0-9;]*[A-Za-z]")

func logTail(path string, max int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.Size() == 0 {
		return ""
	}
	off := st.Size() - max
	if off < 0 {
		off = 0
	}
	buf := make([]byte, st.Size()-off)
	if _, err := f.ReadAt(buf, off); err != nil && err != io.EOF {
		return ""
	}
	return strings.TrimSpace(ansiRe.ReplaceAllString(string(buf), ""))
}

// runDiagnose 供「打不开」时自救：把本机环境写成一个报告文件再打开。
func runDiagnose() {
	dir, dirErr := dataDir()
	if dirErr != nil {
		dir = os.TempDir()
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Toneferry 诊断报告\r\n")
	fmt.Fprintf(&b, "生成时间：%s\r\n", time.Now().Format("2006-01-02 15:04:05"))
	fmt.Fprintf(&b, "程序路径：%s\r\n", mustExecutable())
	fmt.Fprintf(&b, "系统架构：%s/%s\r\n", runtime.GOOS, runtime.GOARCH)
	fmt.Fprintf(&b, "Windows  ：%s\r\n", windowsVersion())
	fmt.Fprintf(&b, "数据目录：%s（错误：%v）\r\n", dir, dirErr)
	fmt.Fprintf(&b, "端口 3088：%s\r\n", portState(3088))
	fmt.Fprintf(&b, "端口选择：%d\r\n", pickPort(3088))
	fmt.Fprintf(&b, "\r\n--- 已释放的文件 ---\r\n")
	for _, n := range []string{"ToneferryServer.exe", "audio-capture.exe", "audio-play.exe", "icon.ico"} {
		p := filepath.Join(dir, n)
		if _, err := os.Stat(p); err != nil {
			// 采集器 / 播放器由服务端释放到 %TEMP%\toneferry-runtime
			if alt := filepath.Join(os.TempDir(), "toneferry-runtime", n); fileExists(alt) {
				p = alt
			}
		}
		if st, err := os.Stat(p); err == nil {
			fmt.Fprintf(&b, "%-22s %10d 字节  %s  %s\r\n", n, st.Size(), st.ModTime().Format("15:04:05"), p)
		} else {
			fmt.Fprintf(&b, "%-22s 缺失\r\n", n)
		}
	}
	fmt.Fprintf(&b, "\r\n--- host.log ---\r\n%s\r\n", logTail(filepath.Join(dir, "host.log"), 4000))
	fmt.Fprintf(&b, "\r\n--- toneferry.log ---\r\n%s\r\n", logTail(filepath.Join(dir, "toneferry.log"), 4000))

	out := filepath.Join(dir, "diagnose.txt")
	if err := os.WriteFile(out, []byte(b.String()), 0o644); err != nil {
		messageBox("Toneferry 诊断", b.String())
		return
	}
	hostLog("诊断报告已生成 %s", out)
	verb, _ := syscall.UTF16PtrFromString("open")
	target, _ := syscall.UTF16PtrFromString(out)
	pShellExecuteW.Call(0, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(target)), 0, 0, 1)
}

func mustExecutable() string {
	p, err := os.Executable()
	if err != nil {
		return "（未知）"
	}
	return p
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Size() > 0
}

func portState(p int) string {
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", p))
	if err != nil {
		return "被占用 / 不可用（" + err.Error() + "）"
	}
	ln.Close()
	return "空闲"
}

func windowsVersion() string {
	type osvi struct {
		Size       uint32
		Major      uint32
		Minor      uint32
		Build      uint32
		Platform   uint32
		CSDVersion *uint16
	}
	v := osvi{Size: uint32(unsafe.Sizeof(osvi{}))}
	ntdll := syscall.NewLazyDLL("ntdll.dll")
	proc := ntdll.NewProc("RtlGetVersion")
	if r, _, _ := proc.Call(uintptr(unsafe.Pointer(&v))); r == 0 {
		return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Build)
	}
	return "（未知）"
}

// dataDir 带多级降级：%LOCALAPPDATA% 不可写时退到 %APPDATA%、%TEMP%、exe 同级。
// 只读环境（U 盘只读、受控目录）下仍然要能跑起来。
func dataDir() (string, error) {
	if dataRoot != "" {
		return dataRoot, nil
	}
	var cands []string
	if base := os.Getenv("LOCALAPPDATA"); base != "" {
		cands = append(cands, filepath.Join(base, appName))
	}
	if base := os.Getenv("APPDATA"); base != "" {
		cands = append(cands, filepath.Join(base, appName))
	}
	cands = append(cands, filepath.Join(os.TempDir(), appName))
	if exe, err := os.Executable(); err == nil {
		cands = append(cands, filepath.Join(filepath.Dir(exe), appName+"-data"))
	}

	var lastErr error
	for _, d := range cands {
		if err := os.MkdirAll(d, 0o755); err != nil {
			lastErr = err
			continue
		}
		probe := filepath.Join(d, ".write-test")
		if err := os.WriteFile(probe, []byte("ok"), 0o644); err != nil {
			lastErr = err
			continue
		}
		os.Remove(probe)
		dataRoot = d
		return d, nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("没有可用的可写目录")
	}
	return "", lastErr
}

func ensureSingleInstance() bool {
	name, _ := syscall.UTF16PtrFromString(`Local\ToneferryTrayHost`)
	h, _, err := pCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(name)))
	if h == 0 {
		return true // 拿不到互斥体就不拦，总比打不开好
	}
	if errno, ok := err.(syscall.Errno); ok && errno == 183 { // ERROR_ALREADY_EXISTS
		messageBox("Toneferry", "已经在运行了，请到任务栏右下角查看图标。")
		return false
	}
	return true
}

// extractServer 把内嵌的服务端写到磁盘。pkg 的虚拟文件系统不能直接 CreateProcess。
// 写盘是最容易被安全软件掐住的一步，所以这里做「校验 + 重试 + 换目录」三层兜底。
func extractServer(dir string) (string, error) {
	raw, err := assets.ReadFile("assets/ToneferryServer.exe")
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	want := hex.EncodeToString(sum[:8])

	// 换目录兜底：某些机器上安全软件只允许往 %TEMP% 写可执行文件
	dirs := []string{dir}
	for _, alt := range []string{filepath.Join(os.TempDir(), appName), filepath.Join(os.TempDir(), appName+"-rt")} {
		if alt != dir {
			dirs = append(dirs, alt)
		}
	}

	var lastErr error
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			lastErr = err
			continue
		}
		dest := filepath.Join(d, "ToneferryServer.exe")
		stamp := filepath.Join(d, "server.sha")

		if b, err := os.ReadFile(stamp); err == nil && string(bytes.TrimSpace(b)) == want {
			if st, err := os.Stat(dest); err == nil && st.Size() == int64(len(raw)) {
				dataRoot = d
				return dest, nil
			}
		}

		// 覆盖前先杀掉旧进程，否则文件被占用
		killServerImage(dest)

		for attempt := 1; attempt <= 3; attempt++ {
			tmp := fmt.Sprintf("%s.%d.new", dest, attempt)
			if err := os.WriteFile(tmp, raw, 0o755); err != nil {
				lastErr = err
				time.Sleep(300 * time.Millisecond)
				continue
			}
			// 校验落盘完整性：杀软有时会「写入成功但内容被清空」
			if st, err := os.Stat(tmp); err != nil || st.Size() != int64(len(raw)) {
				os.Remove(tmp)
				lastErr = fmt.Errorf("写入不完整（期望 %d 字节）", len(raw))
				time.Sleep(300 * time.Millisecond)
				continue
			}
			os.Remove(dest)
			if err := os.Rename(tmp, dest); err != nil {
				os.Remove(tmp)
				lastErr = err
				time.Sleep(300 * time.Millisecond)
				continue
			}
			_ = os.WriteFile(stamp, []byte(want), 0o644)
			dataRoot = d
			if d != dir {
				hostLog("主目录写入被拒，已降级到 %s", d)
			}
			return dest, nil
		}
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("未知原因")
	}
	return "", lastErr
}

func killServerImage(path string) {
	name := filepath.Base(path)
	cmd := exec.Command("taskkill", "/F", "/IM", name)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	_ = cmd.Run()
	time.Sleep(150 * time.Millisecond)
}

func startServer() error {
	dir, _ := dataDir()
	logPath := filepath.Join(dir, "toneferry.log")
	if st, err := os.Stat(logPath); err == nil && st.Size() > 4*1024*1024 {
		os.Remove(logPath)
	}

	cmd := exec.Command(serverExe)
	cmd.Dir = filepath.Dir(serverExe)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	cmd.Env = append(os.Environ(),
		"TONEFERRY_NO_BROWSER=1",
		"TONEFERRY_LOG_FILE="+logPath,
		fmt.Sprintf("PORT=%d", port),
	)
	cmd.Stdin = nil
	if err := cmd.Start(); err != nil {
		return err
	}
	childCmd = cmd
	go func() {
		_ = cmd.Wait()
	}()
	return nil
}

// extractIcon 把内嵌的 icon.ico 释放到数据目录，供 LoadImageW 直接从文件加载。
func extractIcon(dir string) string {
	raw, err := assets.ReadFile("assets/icon.ico")
	if err != nil || len(raw) == 0 {
		return ""
	}
	dest := filepath.Join(dir, "icon.ico")
	if st, err := os.Stat(dest); err == nil && st.Size() == int64(len(raw)) {
		return dest
	}
	tmp := dest + ".new"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return ""
	}
	os.Remove(dest)
	if err := os.Rename(tmp, dest); err != nil {
		return ""
	}
	return dest
}

func loadIcon(exePath, icoPath string) uintptr {
	// 首选直接从 ico 文件加载：不依赖 exe 内部的图标资源索引。
	// pkg 打出来的 exe 是用 resedit 后盖图标的，ExtractIconEx 的索引未必对得上。
	if icoPath != "" {
		if p, err := syscall.UTF16PtrFromString(icoPath); err == nil {
			h, _, _ := pLoadImageW.Call(
				0,
				uintptr(unsafe.Pointer(p)),
				imageIcon,
				0, 0,
				lrLoadFromFile,
			)
			if h != 0 {
				return h
			}
		}
	}

	var large, small uintptr
	p, _ := syscall.UTF16PtrFromString(exePath)
	n, _, _ := pExtractIconExW.Call(uintptr(unsafe.Pointer(p)), 0, uintptr(unsafe.Pointer(&large)), uintptr(unsafe.Pointer(&small)), 1)
	if n > 0 && small != 0 {
		return small
	}
	if n > 0 && large != 0 {
		return large
	}
	icon, _, _ := pLoadIconW.Call(0, idiApplication)
	return icon
}

/* ------------------------------ 窗口 / 托盘 ------------------------------ */

func createTrayWindow() {
	hostLog("createTrayWindow 开始")
	hInst, _, _ := kernel32.NewProc("GetModuleHandleW").Call(0)
	clsName, _ := syscall.UTF16PtrFromString(windowClass)
	hostLog("hInst=%d", hInst)

	// 注意必须包含 HIconSm：WNDCLASSEXW 在 x64 下是 80 字节，
	// 少这个字段 cbSize 就只有 72，RegisterClassExW 会直接返回 0，
	// 窗口创建不出来，Shell_NotifyIcon 自然也不可能成功。
	wc := struct {
		CbSize        uint32
		Style         uint32
		LpfnWndProc   uintptr
		CbClsExtra    int32
		CbWndExtra    int32
		HInstance     uintptr
		HIcon         uintptr
		HCursor       uintptr
		HbrBackground uintptr
		LpszMenuName  uintptr
		LpszClassName uintptr
		HIconSm       uintptr
	}{}
	wc.CbSize = uint32(unsafe.Sizeof(wc))
	wc.LpfnWndProc = syscall.NewCallback(wndProc)
	wc.HInstance = hInst
	wc.HIcon = hIcon
	wc.HIconSm = hIcon
	wc.LpszClassName = uintptr(unsafe.Pointer(clsName))

	atom, _, regErr := pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	if atom == 0 {
		hostLog("RegisterClassExW 失败 err=%v（cbSize=%d）", regErr, wc.CbSize)
		messageBox("Toneferry 启动失败", "注册窗口类失败，无法显示托盘图标。")
		return
	}
	hostLog("窗口类已注册 atom=%d cbSize=%d", atom, wc.CbSize)

	title, _ := syscall.UTF16PtrFromString(appName)
	hwnd, _, _ := pCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(clsName)),
		uintptr(unsafe.Pointer(title)),
		wsPopup, // 必须是 WS_POPUP：dwStyle=0 的顶层窗口会被拒绝创建
		0, 0, 0, 0,
		0, 0, hInst, 0,
	)
	if hwnd == 0 {
		hostLog("CreateWindowExW 返回 0，无法创建托盘窗口")
		messageBox("Toneferry 启动失败", "创建托盘窗口失败，无法显示托盘图标。")
		return
	}
	hwndMain = hwnd
	hostLog("窗口已创建 hwnd=%d", hwnd)
	addTrayIcon()
}

// hostLog 把宿主的关键事件写进 %LOCALAPPDATA%\Toneferry\host.log。
// 托盘图标这种事在界面上看不出来，没有日志就没法排查。
func hostLog(format string, args ...any) {
	dir, err := dataDir()
	if err != nil {
		return
	}
	f, err := os.OpenFile(filepath.Join(dir, "host.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}

func addTrayIcon() {
	var nid notifyIconData
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	nid.HWnd = hwndMain
	nid.UID = 1
	nid.UFlags = nifMessage | nifIcon | nifTip
	nid.UCallbackMessage = wmTrayCallback
	nid.HIcon = hIcon
	tip := syscall.StringToUTF16(appName + " · 系统音频推流")
	copy(nid.SzTip[:], tip)

	ok, _, _ := pShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&nid)))
	if ok != 0 {
		hostLog("托盘图标已注册 hwnd=%d hIcon=%d", hwndMain, hIcon)
		return
	}

	// 第一次失败最常见的原因是 HICON 无效（图标资源取不到），
	// 换成系统默认图标再试一次，至少保证托盘里有东西可点。
	hostLog("托盘图标首次注册失败，改用系统默认图标重试")
	fallback, _, _ := pLoadIconW.Call(0, idiApplication)
	if fallback != 0 {
		hIcon = fallback
		nid.HIcon = fallback
		ok, _, _ = pShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&nid)))
		if ok != 0 {
			hostLog("托盘图标已用系统默认图标注册")
			return
		}
	}
	hostLog("托盘图标注册失败（Shell_NotifyIcon 返回 0）")
	messageBox("Toneferry", "托盘图标注册失败，程序仍在后台运行，可直接访问网页控制。")
}

func balloon(title, text string, flags uint32) {
	var nid notifyIconData
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	nid.HWnd = hwndMain
	nid.UID = 1
	nid.UFlags = nifInfo
	t := syscall.StringToUTF16(title)
	m := syscall.StringToUTF16(text)
	copy(nid.SzInfoTitle[:], t)
	copy(nid.SzInfo[:], m)
	nid.DwInfoFlags = flags
	pShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&nid)))
}

func messageLoop() {
	var msg msgStruct
	for {
		r, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(r) <= 0 {
			return
		}
		pTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		pDispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
	}
}

func wndProc(hwnd, msg, wParam, lParam uintptr) uintptr {
	switch uint32(msg) {
	case wmTrayCallback:
		switch uint32(lParam) {
		case wmRButtonUp:
			showMenu(hwnd)
			return 0
		case wmLButtonDblClk:
			openPage()
			return 0
		}
	case wmRefresh:
		// 状态由轮询 goroutine 更新，这里只需重绘（菜单是即时构建的）
		return 0
	case wmBalloon:
		return 0
	}
	r, _, _ := pDefWindowProcW.Call(hwnd, msg, wParam, lParam)
	return r
}

func menuString(s string) uintptr {
	p, _ := syscall.UTF16PtrFromString(s)
	return uintptr(unsafe.Pointer(p))
}

func showMenu(hwnd uintptr) {
	mu.Lock()
	st := status
	errText := lastErr
	mu.Unlock()

	menu, _, _ := pCreatePopupMenu.Call()
	defer pDestroyMenu.Call(menu)

	appendItem := func(flags uint32, id uintptr, label string) {
		pAppendMenuW.Call(menu, uintptr(flags), id, menuString(label))
	}

	// 标题行：版本 + 当前地址
	if st != nil {
		label := "Toneferry"
		if st.Version != "" {
			label += " v" + st.Version
		}
		appendItem(mfString|mfGrayed, 0, label+"  ·  "+st.URL)
	} else if errText != "" {
		appendItem(mfString|mfGrayed, 0, "服务未就绪："+errText)
	} else {
		appendItem(mfString|mfGrayed, 0, "服务启动中…")
	}
	appendItem(mfSeparator, 0, "")

	if st != nil {
		if st.StreamEnabled {
			appendItem(mfString|mfGrayed, 0, fmt.Sprintf("推流中  ·  在线 %d 路", st.Clients))
			appendItem(mfString, idStop, "停止推流")
		} else {
			appendItem(mfString|mfGrayed, 0, "已停止  ·  手机端静音")
			appendItem(mfString, idStart, "开始推流")
		}
	} else {
		appendItem(mfString|mfGrayed, idStart, "开始推流")
	}

	appendItem(mfSeparator, 0, "")

	// 麦克风授权
	if st != nil {
		if st.Mic.Granted {
			label := "允许手机使用麦克风（点击撤销）"
			if st.Mic.Active {
				label = "手机麦克风使用中（点击撤销）"
			} else if st.Mic.Pending {
				label = "允许手机使用麦克风（有待确认请求）"
			}
			appendItem(mfString|mfChecked, idRevokeMic, label)
		} else {
			label := "授权手机麦克风"
			if st.Mic.Pending {
				label = "★ 授权手机麦克风（" + orDefault(st.Mic.PendingIP, "手机") + " 正在请求）"
			}
			appendItem(mfString, idGrantMic, label)
			if st.Mic.Pending {
				appendItem(mfString, idDenyMic, "拒绝本次请求")
			}
		}
	} else {
		appendItem(mfString|mfGrayed, idGrantMic, "授权手机麦克风")
	}

	appendItem(mfSeparator, 0, "")

	// 最近连接
	peersMenu, _, _ := pCreatePopupMenu.Call()
	peerCount := 0
	if st != nil {
		for i, p := range st.Peers {
			if i >= 8 {
				break
			}
			kind := "网页"
			if p.Kind == "app" {
				kind = "App"
			}
			appendMenuRaw(peersMenu, mfString, uintptr(idPeerBase+i),
				fmt.Sprintf("%s  ·  %s  ·  %d 次", p.IP, kind, p.Count))
			peerCount++
		}
	}
	if peerCount == 0 {
		appendMenuRaw(peersMenu, mfString|mfGrayed, 0, "（暂无记录）")
	} else {
		appendMenuRaw(peersMenu, mfSeparator, 0, "")
		appendMenuRaw(peersMenu, mfString, idClearPeers, "清空记录")
	}
	pAppendMenuW.Call(menu, uintptr(mfPopup), uintptr(peersMenu), menuString("最近连接的 IP"))

	appendItem(mfSeparator, 0, "")
	appendItem(mfString, idOpenPage, "打开网页")
	appendItem(mfString, idOpenLog, "打开日志")
	appendItem(mfSeparator, 0, "")
	appendItem(mfString, idQuit, "退出")

	var pt struct{ X, Y int32 }
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	pSetForegroundWnd.Call(hwnd)

	cmd, _, _ := pTrackPopupMenu.Call(
		menu,
		tpmLeftAlign|tpmRightButton|tpmReturnCmd,
		uintptr(pt.X), uintptr(pt.Y), 0, hwnd, 0,
	)
	pDestroyMenu.Call(peersMenu)
	handleMenu(uint32(cmd), st)
}

func appendMenuRaw(menu uintptr, flags uint32, id uintptr, label string) {
	pAppendMenuW.Call(menu, uintptr(flags), id, menuString(label))
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func handleMenu(id uint32, st *serverStatus) {
	switch {
	case id == idStart:
		postControl("start")
	case id == idStop:
		postControl("stop")
	case id == idGrantMic:
		postControl("grant-mic")
		mu.Lock()
		micPrompted = true
		mu.Unlock()
	case id == idDenyMic:
		postControl("deny-mic")
	case id == idRevokeMic:
		postControl("revoke-mic")
	case id == idClearPeers:
		postControl("clear-peers")
	case id == idOpenPage:
		openPage()
	case id == idOpenLog:
		openLog()
	case id == idQuit:
		quitApp()
	case id >= idPeerBase:
		if st != nil {
			idx := int(id - idPeerBase)
			if idx < len(st.Peers) {
				copyText(st.Peers[idx].IP)
			}
		}
	}
}

/* ------------------------------ HTTP ------------------------------ */

func apiURL(path string) string {
	return fmt.Sprintf("http://127.0.0.1:%d%s", port, path)
}

func httpClient() *http.Client {
	return &http.Client{Timeout: 1500 * time.Millisecond}
}

func pollLoop() {
	for {
		resp, err := httpClient().Get(apiURL("/api/status"))
		if err != nil {
			mu.Lock()
			status = nil
			lastErr = "连接不上本地服务"
			mu.Unlock()
		} else {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			var st serverStatus
			if json.Unmarshal(body, &st) == nil {
				mu.Lock()
				prev := status
				status = &st
				lastErr = ""
				shouldPrompt := st.Mic.Pending && (prev == nil || !prev.Mic.Pending) && !micPrompted
				if shouldPrompt {
					micPrompted = true
				}
				mu.Unlock()
				if shouldPrompt {
					ip := orDefault(st.Mic.PendingIP, "手机")
					balloon("麦克风授权请求", ip+" 想使用电脑播放手机麦克风，右键托盘图标点「授权手机麦克风」。", niifWarn)
				}
				if prev != nil && prev.Mic.Pending && !st.Mic.Pending {
					mu.Lock()
					micPrompted = false
					mu.Unlock()
				}
			}
		}
		time.Sleep(1500 * time.Millisecond)
	}
}

func postControl(action string) {
	payload, _ := json.Marshal(map[string]string{"action": action})
	req, err := http.NewRequest("POST", apiURL("/api/control"), bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient().Do(req)
	if err != nil {
		balloon("Toneferry", "操作失败："+err.Error(), niifWarn)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var st serverStatus
	if json.Unmarshal(body, &st) == nil && st.OK {
		mu.Lock()
		status = &st
		mu.Unlock()
	}
}

func openPage() {
	url := fmt.Sprintf("http://127.0.0.1:%d/", port)
	verb, _ := syscall.UTF16PtrFromString("open")
	target, _ := syscall.UTF16PtrFromString(url)
	pShellExecuteW.Call(0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(target)),
		0, 0, 1)
}

func openLog() {
	dir, _ := dataDir()
	path := filepath.Join(dir, "toneferry.log")
	if _, err := os.Stat(path); err != nil {
		os.WriteFile(path, []byte(""), 0o644)
	}
	verb, _ := syscall.UTF16PtrFromString("open")
	target, _ := syscall.UTF16PtrFromString(path)
	pShellExecuteW.Call(0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(target)),
		0, 0, 1)
}

func copyText(text string) {
	user32.NewProc("OpenClipboard").Call(0)
	user32.NewProc("EmptyClipboard").Call()
	utf, _ := syscall.UTF16FromString(text)
	h, _, _ := kernel32.NewProc("GlobalAlloc").Call(0x0042, uintptr(len(utf)*2))
	if h != 0 {
		ptr, _, _ := kernel32.NewProc("GlobalLock").Call(h)
		if ptr != 0 {
			copy(unsafe.Slice((*uint16)(unsafe.Pointer(ptr)), len(utf)), utf)
			kernel32.NewProc("GlobalUnlock").Call(h)
			user32.NewProc("SetClipboardData").Call(13, h)
		}
	}
	user32.NewProc("CloseClipboard").Call()
}

func quitApp() {
	postControl("shutdown")
	if childCmd != nil && childCmd.Process != nil {
		time.Sleep(200 * time.Millisecond)
		_ = childCmd.Process.Kill()
	}
	var nid notifyIconData
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	nid.HWnd = hwndMain
	nid.UID = 1
	pShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
	os.Exit(0)
}

func messageBox(title, text string) {
	t, _ := syscall.UTF16PtrFromString(title)
	m, _ := syscall.UTF16PtrFromString(text)
	user32.NewProc("MessageBoxW").Call(0,
		uintptr(unsafe.Pointer(m)),
		uintptr(unsafe.Pointer(t)),
		0x00000040)
}

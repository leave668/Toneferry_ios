// Toneferry.exe —— 托盘宿主。
//
// 职责：
//   1. 以 GUI 子系统启动（双击不弹 cmd 黑框）
//   2. 把内嵌的 ToneferryServer.exe 释放到 %LOCALAPPDATA%\Toneferry\ 并隐藏启动
//   3. 托盘图标 + 右键菜单（开始/停止推送、授权手机麦克风、最近连接、打开网页、退出）
//   4. 手机请求麦克风时弹气泡提醒，等用户点「授权」
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
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

//go:embed assets/ToneferryServer.exe
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
	OK             bool      `json:"ok"`
	Host           string    `json:"host"`
	Port           int       `json:"port"`
	URL            string    `json:"url"`
	StreamEnabled  bool      `json:"streamEnabled"`
	CaptureRunning bool      `json:"captureRunning"`
	Mic            micState  `json:"mic"`
	NativeCount    int       `json:"nativeCount"`
	Clients        int       `json:"clients"`
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

	pRegisterClassExW  = user32.NewProc("RegisterClassExW")
	pCreateWindowExW   = user32.NewProc("CreateWindowExW")
	pDefWindowProcW    = user32.NewProc("DefWindowProcW")
	pGetMessageW       = user32.NewProc("GetMessageW")
	pTranslateMessage  = user32.NewProc("TranslateMessage")
	pDispatchMessageW  = user32.NewProc("DispatchMessageW")
	pPostMessageW      = user32.NewProc("PostMessageW")
	pCreatePopupMenu   = user32.NewProc("CreatePopupMenu")
	pAppendMenuW       = user32.NewProc("AppendMenuW")
	pTrackPopupMenu    = user32.NewProc("TrackPopupMenu")
	pDestroyMenu       = user32.NewProc("DestroyMenu")
	pSetForegroundWnd  = user32.NewProc("SetForegroundWindow")
	pGetCursorPos      = user32.NewProc("GetCursorPos")
	pDestroyIcon       = user32.NewProc("DestroyIcon")
	pLoadIconW         = user32.NewProc("LoadIconW")
	pShellNotifyIconW  = shell32.NewProc("Shell_NotifyIconW")
	pExtractIconExW    = shell32.NewProc("ExtractIconExW")
	pShellExecuteW     = shell32.NewProc("ShellExecuteW")
	pCreateMutexW      = kernel32.NewProc("CreateMutexW")
)

var (
	mu       sync.Mutex
	status   *serverStatus
	lastErr  string
	serverExe string
	childCmd  *exec.Cmd
	hIcon     uintptr
	hwndMain  uintptr
	port      = 3088
	micPrompted bool
)

func main() {
	runtime.LockOSThread()

	if !ensureSingleInstance() {
		return
	}

	dir, err := dataDir()
	if err != nil {
		messageBox("Toneferry 启动失败", "无法创建数据目录："+err.Error())
		return
	}

	if p := os.Getenv("PORT"); p != "" {
		fmt.Sscanf(p, "%d", &port)
	}

	serverExe, err = extractServer(dir)
	if err != nil {
		messageBox("Toneferry 启动失败", "释放服务端失败："+err.Error())
		return
	}

	hIcon = loadIcon(serverExe)

	if err := startServer(); err != nil {
		messageBox("Toneferry 启动失败", "服务端启动失败："+err.Error())
		return
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

func dataDir() (string, error) {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, "AppData", "Local")
	}
	dir := filepath.Join(base, appName)
	return dir, os.MkdirAll(dir, 0o755)
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
func extractServer(dir string) (string, error) {
	raw, err := assets.ReadFile("assets/ToneferryServer.exe")
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	want := hex.EncodeToString(sum[:8])
	dest := filepath.Join(dir, "ToneferryServer.exe")
	stamp := filepath.Join(dir, "server.sha")

	if b, err := os.ReadFile(stamp); err == nil && string(bytes.TrimSpace(b)) == want {
		if _, err := os.Stat(dest); err == nil {
			return dest, nil
		}
	}
	// 覆盖前先杀掉旧进程，否则文件被占用
	killServerImage(dest)
	tmp := dest + ".new"
	if err := os.WriteFile(tmp, raw, 0o755); err != nil {
		return "", err
	}
	os.Remove(dest)
	if err := os.Rename(tmp, dest); err != nil {
		return "", err
	}
	_ = os.WriteFile(stamp, []byte(want), 0o644)
	return dest, nil
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

func loadIcon(exePath string) uintptr {
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
	hInst, _, _ := kernel32.NewProc("GetModuleHandleW").Call(0)
	clsName, _ := syscall.UTF16PtrFromString(windowClass)

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
	}{}
	wc.CbSize = uint32(unsafe.Sizeof(wc))
	wc.LpfnWndProc = syscall.NewCallback(wndProc)
	wc.HInstance = hInst
	wc.HIcon = hIcon
	wc.LpszClassName = uintptr(unsafe.Pointer(clsName))

	pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	title, _ := syscall.UTF16PtrFromString(appName)
	hwnd, _, _ := pCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(clsName)),
		uintptr(unsafe.Pointer(title)),
		0, 0, 0, 0, 0, 0, 0, hInst, 0,
	)
	hwndMain = hwnd
	addTrayIcon()
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
	pShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&nid)))
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

	// 标题行：当前地址
	if st != nil {
		appendItem(mfString|mfGrayed, 0, "Toneferry  ·  "+st.URL)
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

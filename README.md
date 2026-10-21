# Toneferry

[English](./README_EN.md)

> Windows 系统音频 → 手机实时收听，两步搞定。

![Toneferry](./public/banner.png)

## 两步使用

1. **电脑**：运行 `Toneferry.exe`（或源码下执行 `npm start`）
2. **电脑浏览器**：打开 `http://<局域网IP>:3088/`，点 **开始收听** —— 这是总开关
3. **手机**：同一 Wi‑Fi 下打开页面（扫码或访问提示的地址）→ 即可收听

> **开始收听 = 开始发送到手机。** 没点之前服务端一帧都不下发，手机端保持安静，
> 只在界面上提示「等待电脑端点击开始收听」。点 **停止** 会立刻关闸，手机端同步静音。

电脑在播什么，手机就能听什么。无需立体声混音设备。

## iOS 原生客户端（TrollStore / 未签名 IPA）

`ios/` 下是一个纯原生 ObjC 客户端，不走浏览器，锁屏后台音频不受 Safari 限制。
产物：`release/Toneferry-ios.ipa`（TrollStore 可直接安装，无需签名）。

### 悬浮窗（画中画）

为避免长时间开启后台内存不足、退出后台的情况出现，新增悬浮窗备用功能。
主界面「悬浮窗」按钮会把 `延迟 / 缓冲 / 电平 / 连接状态` 渲染成 `CMSampleBuffer`，
喂进 `AVSampleBufferDisplayLayer`，再用 `AVPictureInPictureController` 浮在所有 App 之上。

```objc
AVPictureInPictureControllerContentSource *src =
  [[AVPictureInPictureControllerContentSource alloc]
      initWithSampleBufferDisplayLayer:layer playbackDelegate:self];
pip = [[AVPictureInPictureController alloc] initWithContentSource:src];
```

委托里 `pictureInPictureControllerTimeRangeForPlayback:` 返回
`CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity)` 声明成直播流，
系统就不会显示进度条和快进按钮。

**首次点击必须能弹**：`isPictureInPicturePossible` 是异步刷新的，如果等到用户点按钮才
`initWithContentSource:`，那一刻它必然是 `NO`，`startPictureInPicture` 会静默失败
（表现为「第一次点没反应，第二次就出来了」）。所以：

- `viewDidLoad` 里就调 `[_pipController prepare]`，把 layer / controller 建好并渲染一帧；
- 之后用 2 fps 的暖机帧维持 layer 有内容，避免系统认为「无画面」；
- KVO 监听 `pictureInPicturePossible`，用户点击时若还没就绪就挂起（`_pendingStart`），
  等 KVO 翻成 `YES` 立刻 `startPictureInPicture`；
- 4 s 仍未就绪才报错，且提示下一步（没在播放时会提示先点「开始收听」——
  系统不会给一条没有音频的会话标 PiP 就绪）。

### 锁屏界面

`MPNowPlayingInfoCenter` 的副标题每秒刷新一次实时延迟，锁屏/控制中心直接可见：

```
Toneferry 系统音频
延迟 88ms · 缓冲 72ms
192.168.0.80:3088
```

封面是代码生成的深色波形图（`+[TFPlayer sharedArtwork]`），不依赖图片资源。

### 关于回声

回声有两类来源，先看诊断行再判断：

1. **包速率约 200/s（正常 100/s）或「重复包」计数增长** → 服务端把同一帧发了两遍，
   客户端已自动丢弃重复包；若仍异常请贴服务端日志。
2. **包速率正常、欠载为 0，但听到延迟明显的重复声** → 是**物理闭环**：
   电脑浏览器外放 → 被 WASAPI loopback 重新采进去 → 再推给手机播一遍，
   手机上听到的就是「原声 + 延迟副本」。

第 2 类现在由软件自动掐断，不需要手动关页面：

- 手机 App 一连上，服务端就向所有浏览器连接广播 `{type:'peer-mode', nativeCount:N}`；
- 浏览器收到 `N>0` 立刻 `muteLocalAudio()`：只销毁**本机**的 AudioContext / 播放节点 / 媒体元素，
  并回 `{type:'wants-audio', value:false}` 让服务端停止给它下行 PCM；
- **总闸不动**：`listening` 仍为 true，手机继续收，状态栏显示「手机 App 已接管，本机已静音（避免回声）」；
- WebSocket 也**故意保留**，否则收不到「手机已断开」的通知，「开始收听」按钮会永久卡住；
- 手机断开后自动 `resumeLocalAudio()`，恢复电脑本机播放。

客户端侧还做了防叠加处理：音频图重建/断线时递增 generation 让旧回调失效，
断线时 `[_node stop]` 清空已排队的 buffer，建连加 `_connecting` 防重入。

## 推流总闸

`server/index.js` 里的 `streamEnabled` 是唯一总开关，默认 `false`：

- 浏览器点「开始收听」→ 发 `{type:'start-stream'}`，服务端把它记进 `streamOwners`；
- 点「停止」→ 发 `{type:'stop-stream'}`，从 `streamOwners` 移除；
- 发起方全部断开（关页面 / 断网）→ 自动关闸，采集不再空转；
- `broadcastBinary()` 首行 `if (!streamEnabled) return`，手机端与浏览器端都收不到任何帧。

新连接会收到一次 `{type:'stream-state', enabled}`；iOS 端据此把状态显示成
「等待电脑端点击开始收听…」而不是无意义的「缓冲中」。

## 锁屏 / 息屏播放

手机锁屏后继续出声，通知栏（媒体会话）可直接暂停、继续。实现要点：

- 页面不可见时**不再**断开 WebSocket、不再挂起 `AudioContext`；
- `AudioWorklet` 输出经 `MediaStreamAudioDestinationNode` 送入 `<audio>` 元素播放，
  只有走媒体元素，Android Chrome 才会把它当作"正在播放的媒体"在锁屏后继续出声；
- 前端 watchdog 每 4s 自检 `AudioContext` / 媒体元素 / WebSocket，被打断自动恢复；
- 服务端 30s 协议层心跳 + 下行背压保护（积压超过 512 KB 丢帧，避免延迟越拖越大）。

已知限制：

- iOS Safari 锁屏后仍可能被系统挂起（系统只允许原生媒体后台播放），属平台限制
  —— 用上面的 iOS 原生客户端可绕过；
- 安卓设备直接网页即可，省电策略会杀后台网络，需在浏览器/系统设置里给该站点或浏览器
  「允许后台活动 / 不受流量节省限制」。

## 源码运行

```bash
npm install
npm start
```

默认地址：`http://<局域网IP>:3088`

## 打包

```bash
npm run build        # → release/Toneferry.exe
bash ios/tools/build_win.sh   # → ios/out/Toneferry（arm64 Mach-O）
python ios/tools/pack.py      # → release/Toneferry-ios.ipa
```

iOS 交叉编译需要 `ios/sdk/iPhoneOS16.5.sdk` 与 `ios/tools/llvm`，两者体积过大，
不入库；按 `ios/tools/fetch_sdk.sh` 与 `ios/tools/sdklist.txt` 自行拉取。

## 版本

当前 iOS 客户端：**1.5.0（build 6）**

| 版本 | 变更 |
| --- | --- |
| 1.5.0 | 「开始收听」升级为推流总闸；修复点了开始后「停止」无法点击；手机端显示等待提示 |
| 1.4.0 | 修复回声闭环（手机接管时本机静音）；修复悬浮窗首次点击不弹出 |
| 1.3.0 | 新增画中画悬浮窗；锁屏媒体卡片显示实时延迟 |
| 1.2.0 | 播放核心重写为 `AVAudioSourceNode` 拉模式，消除沙哑与追帧振荡 |
| 1.1.0 | 修复回声与高延迟；锁屏后台持续出声 |

## License

MIT

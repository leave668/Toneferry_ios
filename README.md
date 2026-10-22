# Toneferry

[English](./README_EN.md)

> 把 Windows 系统音频实时传到手机收听，手机还能当麦克风用——两步搞定。

![Toneferry](./public/banner.png)

## 两步上手

1. **电脑端**：运行 `Toneferry.exe`（或从源码执行 `npm start`）
2. **手机端**：在同一个 Wi‑Fi 下打开页面（扫码或访问提示的地址）→ 开始收听

电脑在播什么，手机就能听什么，无需「立体声混音」设备。

## 只有一个文件

电脑端发布物就是 `release/Toneferry.exe` **一个文件**，双击即用：

- 不需要安装 Node.js，不需要 .NET，不需要 VC++ 运行库
- 不需要解压出一堆 dll，也不需要命令行窗口
- 内置 HTTP/WebSocket 服务、网页前端、WASAPI 采集器、音频播放器、托盘图标

程序运行时会在 `%LOCALAPPDATA%\Toneferry\` 下释放内部组件（`ToneferryServer.exe`、日志、最近连接记录），这是单文件自解压的正常行为，不影响「只发一个 exe 就能用」。

## 打不开怎么办

### Toneferry.exe

程序本身是自包含的，但在**别人的电脑**上最常见的拦路虎是 Windows 安全机制，不是程序坏了。按出现频率排：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 弹「Windows 已保护你的电脑」，只有「不运行」 | 文件从浏览器/微信下载，带了 Mark-of-the-Web，且没有代码签名证书 | 点「更多信息」→「仍要运行」；或执行 `Unblock-File .\Toneferry.exe` |
| 双击后毫无反应，右下角也没图标 | Defender / 360 / 火绒 把释放出来的 `ToneferryServer.exe` 删了或隔离 | 把 `Toneferry.exe` 和 `%LOCALAPPDATA%\Toneferry` 加入白名单，重新双击 |
| 提示缺少 `VCRUNTIME140.dll` 之类 | 系统过旧；Toneferry 需要 **64 位 Windows 10 1809+ / 11** | 换系统；32 位与 ARM64 不支持 |
| 浏览器打开是空白页 / 连不上 | 3088 端口被占用 | v1.7.2 起自动顺延找空闲端口，托盘菜单第一行显示实际地址 |
| 托盘有图标，手机连不上 | 防火墙拦了入站 | 首次运行允许「专用网络」访问 |

**打不开时自救**：命令行执行

```
Toneferry.exe --diagnose
```

会在 `%LOCALAPPDATA%\Toneferry\diagnose.txt` 生成报告（系统版本、端口占用、释放的文件、最近日志）并自动打开，把它发给对方就能定位。

### Toneferry-ios.ipa

**IPA 是未签名的**，iOS 不允许安装未签名应用——这不是文件损坏，是苹果的机制。

| 安装方式 | 条件 |
| --- | --- |
| TrollStore | 设备已装 TrollStore，点开 IPA 直接安装 |
| AltStore / Sideloadly 自签 | 用**自己的** Apple ID 重签；免费账号 7 天过期、最多 3 个 App |
| 开发者 / 企业证书 | 用自己的证书 `codesign` 重签后安装 |

另外：客户端要求 **iOS 15.0+、arm64（iPhone）**，`UIDeviceFamily` 只声明了 iPhone。

## iOS 原生客户端（TrollStore / 未签名 IPA）

`ios/` 目录下是一个纯原生 ObjC 客户端。它不经过浏览器，锁屏和后台音频播放不受 Safari 限制。

产物：`release/Toneferry-ios.ipa`（TrollStore 可直接安装，无需签名）。

### 悬浮窗（画中画）

主界面的「悬浮窗」按钮会把 `延迟 / 缓冲 / 电平 / 连接状态` 渲染成 `CMSampleBuffer`，以画中画形式常驻显示。

为避免长时间开启后台导致内存不足、被系统退到后台的情况，另新增了悬浮窗备用方案。

### 锁屏界面

`MPNowPlayingInfoCenter` 的副标题每秒刷新一次实时延迟，锁屏界面和控制中心都能直接看到。

封面是由代码生成的深色波形图（`+[TFPlayer sharedArtwork]`），不依赖任何图片资源。

## 从源码运行

```bash
npm install
npm start
```
默认地址：http://<局域网IP>:3088

## 打包

```bash
npm run build   # → release/Toneferry.exe（单文件，约 64 MB）
```

产物只有一个 exe：内嵌服务端（pkg）、网页前端、采集器、播放器与图标，运行时自解压到 `%LOCALAPPDATA%\Toneferry\`。


## 致谢与改动说明
原作者：magicflower2/Toneferry

改版原因：台式机学英语时没有耳机和麦克风，原版只能输出声音，因此做了改版，让台式机不插线也能同时输出和输入声音。

License
MIT

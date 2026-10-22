# Toneferry

[English](./README_EN.md)

> 把 Windows 系统音频实时传到手机收听，手机还能当麦克风用——两步搞定。

![Toneferry](./public/banner.png)

## 两步上手

1. **电脑端**：运行 `Toneferry.exe`（或从源码执行 `npm start`）
2. **手机端**：在同一个 Wi‑Fi 下打开页面（扫码或访问提示的地址）→ 开始收听

电脑在播什么，手机就能听什么，无需「立体声混音」设备。

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
bash
npm run build   # → release/Toneferry.exe

## 致谢与改动说明
原作者：magicflower2/Toneferry

改版原因：台式机学英语时没有耳机和麦克风，原版只能输出声音，因此做了改版，让台式机不插线也能同时输出和输入声音。

License
MIT

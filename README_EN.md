# Toneferry

[中文](./README.md)

> Stream Windows system audio to your phone in real time, and use your phone as a microphone — two steps.

![Toneferry](./public/banner.png)

## Two steps

1. **PC**: Double-click `Toneferry.exe` (or `npm start` from source)
2. **Phone**: On the same Wi-Fi, open the page (scan QR or visit the printed URL) → **Start Listening**

> **Start Listening = global stream switch.** Before you click it the server sends zero frames; the phone stays quiet.

Whatever the PC is playing, your phone hears it. No "Stereo Mix" device needed.

---

## One single file

The Windows release is exactly one file: `release/Toneferry.exe`. Double-click and go.

- No Node.js, no .NET, no VC++ redistributable required
- No DLL folder to keep beside it, no console window
- Bundles the HTTP/WebSocket server, the web UI, the WASAPI capture engine, the audio player and the tray icon

On launch it self-extracts its inner parts into `%LOCALAPPDATA%\Toneferry\` (`ToneferryServer.exe`, logs, recent-peer records). That is normal self-extraction behaviour and does not change the "ship one exe" story.

---

## Can't open it on someone else's machine?

### Toneferry.exe

The binary is self-contained. What blocks it on another PC is almost always Windows security, not a broken build:

| Symptom | Cause | Fix |
| --- | --- | --- |
| "Windows protected your PC", only a "Don't run" button | File was downloaded via a browser/IM, so it carries Mark-of-the-Web, and it is not code-signed | Click "More info" → "Run anyway", or run `Unblock-File .\Toneferry.exe` |
| Double-click does nothing, no tray icon | Defender / 360 / Huorong deleted or quarantined the extracted `ToneferryServer.exe` | Whitelist both `Toneferry.exe` and `%LOCALAPPDATA%\Toneferry`, then relaunch |
| Missing `VCRUNTIME140.dll` or similar | OS too old; Toneferry needs **64-bit Windows 10 1809+ / 11** | Upgrade the OS; 32-bit and ARM64 are not supported |
| Browser opens a blank page / cannot connect | Port 3088 already taken | Since v1.7.2 it auto-picks the next free port; the tray menu's first line shows the real address |
| Tray icon appears, phone cannot connect | Firewall blocks inbound | Allow "Private network" on first run |

**Self-diagnosis** when it won't open:

```
Toneferry.exe --diagnose
```

Writes `%LOCALAPPDATA%\Toneferry\diagnose.txt` (OS version, port state, extracted files, recent logs) and opens it. Send that file to whoever is debugging.

### Toneferry-ios.ipa

**The IPA is unsigned.** iOS refuses to install unsigned apps — this is Apple's policy, not a corrupt file.

| Install method | Requirement |
| --- | --- |
| TrollStore | TrollStore already installed on the device; just tap the IPA |
| AltStore / Sideloadly | Re-sign with **your own** Apple ID; free accounts expire in 7 days and allow max 3 apps |
| Developer / enterprise certificate | Re-sign with `codesign` using your own certificate |

Also: the client requires **iOS 15.0+, arm64 (iPhone)** — `UIDeviceFamily` declares iPhone only.

---

## System tray (no cmd window)

`Toneferry.exe` is a GUI-subsystem tray host. Double-clicking it **does not pop up a black console window**; it goes straight to the system tray.

Right-click the tray icon:
- Start / Stop streaming
- Grant / Revoke phone microphone
- Recent IPs (click to copy to clipboard)
- Open web page / Open log / Exit

Left double-click opens the web page directly. A balloon pops up when a phone requests microphone access.

**Can't see the icon?** Windows 11 hides new tray icons in the `^` overflow area by default. Click the small arrow and drag the icon to the main tray.

---

## Use your phone as a PC microphone

Speak into your phone → hear it from the PC speakers.

- **Phone side**: Web page / iOS App both have a "Microphone" toggle
- **PC side**: **Denied by default.** After the phone toggles it on, right-click the tray icon and choose "Grant phone microphone" (an "Authorize" button also appears on the local web page)
- The grant is memory-only; it expires when the process exits. You can revoke it anytime.
- **Clicking "Close Microphone" on the PC side revokes authorization across all devices.** The server broadcasts `mic-state granted:false` and every client stops capturing.

Pipeline: `getUserMedia` → AudioWorklet resample to 48 kHz mono f32 → WebSocket binary frame → `audio-play.exe` (waveOut) → default output device, end-to-end ~40–80 ms.

**Volume too low?** Phone microphones are far from the mouth and system AGC is conservative. The Go player applies tanh soft-limiting gain (×3): small signals are amplified, large signals smoothly saturate to ±1 without clipping distortion.

---

## iOS native client (TrollStore / unsigned IPA)

`ios/` contains a pure Objective-C native client. It bypasses the browser, so background audio and lock-screen playback are not restricted by Safari.

Output: `release/Toneferry-ios.ipa` (install directly with TrollStore, no signing needed).

### Picture-in-Picture floating window

The "Floating Window" button on the main screen renders `latency / buffer / level / connection state` into a `CMSampleBuffer` and keeps it visible as PiP.

### Lock screen

`MPNowPlayingInfoCenter` subtitle refreshes real-time latency every second. You can see it on the lock screen and in Control Center.

The cover art is a dark waveform generated by code (`+[TFPlayer sharedArtwork]`), no image assets required.

### Where to check the version

The bottom-right of the app shows `Toneferry for iOS vX.X.X (X)`. The subtitle under the title also includes the version string. Always verify this after installing a new build; if it hasn't changed the install didn't overwrite the old binary.

---

## Run from source

```bash
npm install
npm start
```

Default URL: http://<LAN-IP>:3088

## Build

```bash
npm run build   # → release/Toneferry.exe (single file, ~64 MB)
```

One artifact only: the server (pkg), web UI, capture engine, player and icon are all embedded and self-extract to `%LOCALAPPDATA%\Toneferry\` at runtime.

---

## Troubleshooting

### Phone can't hear PC audio after turning on microphone?

This was a bug before v1.7. Switching `AVAudioSession` from `.playback` to `.playAndRecord` stops `AVAudioEngine`, and the old code didn't listen to `AVAudioEngineConfigurationChangeNotification`, so the playback engine stayed dead. Fixed: the engine auto-restarts on config change, and the category no longer switches back after closing the mic.

### "Authorize" button doesn't appear on the PC page?

Control endpoints are localhost-only. The check now compares against **all local network interface addresses** (not just 127.0.0.1), so opening `http://192.168.0.80:3088/` from the same PC still counts as local.

### Tray icon not showing?

A bug in versions before v1.7: the Go `WNDCLASSEXW` struct was missing the `hIconSm` field, making `cbSize=72` instead of 80. `RegisterClassExW` failed silently, the window was never created, and `Shell_NotifyIcon` could never succeed. Fixed in v1.7.1.

### Why is the exe so large?

64 MB because it embeds the pkg-packaged server (Node runtime + bundled JS + static files + capture binary). On first run it extracts the server to `%LOCALAPPDATA%\Toneferry\` and skips re-extraction by SHA-256.

---

## Acknowledgements

Original author: magicflower2/Toneferry

Fork reason: learning English on a desktop PC without headphones or a microphone. The original only output audio, so this fork adds bidirectional audio so the desktop can both output and input wirelessly.

**License**
MIT

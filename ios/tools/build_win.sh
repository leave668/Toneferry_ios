#!/bin/bash
# Windows 本机交叉编译 iOS arm64 可执行文件（LLVM + theos iPhoneOS SDK）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LLVM="${LLVM:-$ROOT/tools/llvm}"
SDK="${SDK:-$ROOT/sdk/iPhoneOS16.5.sdk}"
OUT="${OUT:-$ROOT/out}"
CLANG="$LLVM/bin/clang.exe"

[ -x "$CLANG" ] || { echo "[error] 找不到 clang: $CLANG"; exit 1; }
[ -d "$SDK" ] || { echo "[error] 找不到 SDK: $SDK"; exit 1; }

mkdir -p "$OUT"

echo "[1/2] 编译 arm64 Mach-O（deployment target 15.0）…"
"$CLANG" -target arm64-apple-ios15.0 \
  -isysroot "$SDK" \
  -B "$LLVM/bin" \
  -fuse-ld=lld \
  -fobjc-arc -fblocks -O2 \
  -Wall -Wno-unused-parameter \
  -Wl,-adhoc_codesign \
  -framework Foundation -framework UIKit -framework AVFoundation -framework AVFAudio \
  -framework AVKit -framework MediaPlayer -framework CoreMedia -framework CoreVideo \
  -framework CoreText -framework CoreGraphics -framework QuartzCore \
  -o "$OUT/Toneferry" \
  "$ROOT/src/main.m" "$ROOT/src/TFViewController.m" "$ROOT/src/TFPlayer.m" \
  "$ROOT/src/TFPiPController.m"

echo "[2/2] 产物："
ls -l "$OUT/Toneferry"
head -c 8 "$OUT/Toneferry" | xxd

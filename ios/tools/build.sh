#!/bin/bash
# 在容器内交叉编译 iOS arm64 可执行文件
set -euo pipefail

SDK="${SDK:-/opt/sdk/iPhoneOS16.5.sdk}"
SRC="${SRC:-/work/src}"
OUT="${OUT:-/work/out}"

if [ ! -d "$SDK" ]; then
  echo "[error] SDK 不存在: $SDK" >&2
  exit 1
fi

mkdir -p "$OUT"

echo "[1/2] 编译 arm64 Mach-O（deployment target 15.0）…"
clang -target arm64-apple-ios15.0 \
      -isysroot "$SDK" \
      -fobjc-arc -fblocks -O2 \
      -Wall -Wno-unused-parameter \
      -fuse-ld=lld \
      -framework Foundation -framework UIKit -framework AVFoundation -framework MediaPlayer \
      -o "$OUT/Toneferry" \
      "$SRC/main.m" "$SRC/TFViewController.m" "$SRC/TFPlayer.m"

echo "[2/2] 产物："
file "$OUT/Toneferry"
ls -l "$OUT/Toneferry"

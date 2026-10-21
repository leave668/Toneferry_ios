#!/bin/bash
# 从 jsdelivr 拉 theos/sdks 里的 iPhoneOS SDK（逐文件，断点重下用 .part）
set -uo pipefail

LIST="${1:?用法: fetch_sdk.sh <sdklist.txt> <目标目录>}"
DEST="${2:?}"
JOBS="${JOBS:-24}"
BASE="https://cdn.jsdelivr.net/gh/theos/sdks@master"

# 先转成绝对路径：下面要 cd 到目标目录
LIST="$(cd "$(dirname "$LIST")" && pwd)/$(basename "$LIST")"
[ -f "$LIST" ] || { echo "[error] 清单不存在: $LIST"; exit 1; }
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
cd "$DEST" || exit 1

fetch_one() {
  local p="$1"
  [ -s "$p" ] && return 0
  mkdir -p "$(dirname "$p")" 2>/dev/null
  if curl -sfL --retry 2 --retry-delay 1 --max-time 90 -o "$p.part" "$BASE/$p"; then
    mv -f "$p.part" "$p"
  else
    rm -f "$p.part"
    echo "FAIL $p" >> "$DEST/../sdk_fail.log"
  fi
}
export -f fetch_one
export BASE DEST

total=$(wc -l < "$LIST")
echo "[sdk] 共 $total 个文件，并发 $JOBS"

tr -d '\r' < "$LIST" | xargs -r -P "$JOBS" -n 10 bash -c 'for p in "$@"; do fetch_one "$p"; done' _

done_count=$(find . -type f ! -name '*.part' | wc -l)
echo "[sdk] 完成 $done_count / $total"
du -sh . 2>/dev/null | tail -1

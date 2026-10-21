#!/usr/bin/env python3
"""修复 theos SDK 在 Windows 上丢失的符号链接。

git 在 Windows（core.symlinks=false）会把符号链接写成「一行目标路径」的小文本文件，
clang 找不到头文件/框架。这里把这类文本文件替换成真实副本（文件或目录）。

用法: python tools/fix_sdk_links.py <SDK 根目录>
"""
import os
import shutil
import sys


def is_link_stub(path: str) -> str | None:
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not os.path.isfile(path):
        return None
    if st.st_size == 0 or st.st_size > 512:
        return None
    with open(path, "rb") as f:
        raw = f.read()
    if b"\x00" in raw:
        return None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if text != text.strip() or "\n" in text or "\r" in text:
        return None
    target = os.path.normpath(os.path.join(os.path.dirname(path), text))
    if not os.path.exists(target):
        return None
    return target


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "sdk/iPhoneOS16.5.sdk"
    if not os.path.isdir(root):
        print(f"[error] 目录不存在: {root}")
        return 1

    files = dirs = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            target = is_link_stub(path)
            if not target:
                continue
            try:
                os.unlink(path)
                if os.path.isdir(target):
                    shutil.copytree(target, path, symlinks=False)
                    dirs += 1
                else:
                    shutil.copy2(target, path)
                    files += 1
            except Exception as exc:  # noqa: BLE001
                print(f"[warn] {path}: {exc}")

    print(f"[ok] 还原链接：文件 {files} 个，目录 {dirs} 个")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""把交叉编译产物打成 TrollStore 可安装的未签名 IPA。

用法: python tools/pack.py
产物: release/Toneferry-ios.ipa
"""
import os
import shutil
import zipfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
BUILD = ROOT / "build"
RELEASE = ROOT.parent / "release"
APP_NAME = "Toneferry"
BUNDLE = f"{APP_NAME}.app"

ICON_SRC = ROOT.parent / "public" / "icon.png"
ICON_SIZES = {
    "Icon.png": 57,
    "Icon@2x.png": 114,
    "Icon-60@2x.png": 120,
    "Icon-60@3x.png": 180,
}


def main() -> int:
    binary = OUT / "Toneferry"
    if not binary.exists():
        print(f"[error] 缺少编译产物: {binary}（先在容器里跑 tools/build.sh）")
        return 1

    if BUILD.exists():
        shutil.rmtree(BUILD)
    app = BUILD / "Payload" / BUNDLE
    app.mkdir(parents=True)

    shutil.copy2(binary, app / "Toneferry")
    os.chmod(app / "Toneferry", 0o755)
    shutil.copy2(ROOT / "Info.plist", app / "Info.plist")

    if ICON_SRC.exists():
        src = Image.open(ICON_SRC).convert("RGBA")
        for name, size in ICON_SIZES.items():
            src.resize((size, size), Image.LANCZOS).save(app / name, "PNG")

    RELEASE.mkdir(parents=True, exist_ok=True)
    ipa = RELEASE / "Toneferry-ios.ipa"
    if ipa.exists():
        ipa.unlink()

    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(app.rglob("*")):
            if path.is_file():
                z.write(path, path.relative_to(BUILD).as_posix())

    print(f"[ok] {ipa}  ({ipa.stat().st_size / 1024:.0f} KB)")
    for path in sorted(app.rglob("*")):
        if path.is_file():
            print(f"     {path.relative_to(BUILD).as_posix()}  {path.stat().st_size} B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

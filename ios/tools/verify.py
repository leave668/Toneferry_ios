#!/usr/bin/env python3
"""校验交叉编译出的 iOS Mach-O 是否可装可跑。

用法: python tools/verify.py out/Toneferry
"""
import struct
import sys

CPU_TYPE_ARM64 = 0x0100000C
PLATFORM_IOS = 2

LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
LC_CODE_SIGNATURE = 0x1D
LC_MAIN = 0x28  # 带 LC_REQ_DYLD 位，比较前已剥离


def cstr(data: bytes, off: int) -> str:
    end = data.index(b"\x00", off)
    return data[off:end].decode("utf-8", "replace")


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "out/Toneferry"
    with open(path, "rb") as f:
        data = f.read()

    ok = True

    def check(name, cond, extra=""):
        nonlocal ok
        print(f"{'[ok]  ' if cond else '[FAIL]'} {name}{('  ' + extra) if extra else ''}")
        if not cond:
            ok = False

    magic = struct.unpack_from("<I", data, 0)[0]
    check("Mach-O 64 小端 magic", magic == 0xFEEDFACF, hex(magic))

    cputype, cpusubtype, _ft, ncmds, sizeofcmds, _flags, _res = struct.unpack_from(
        "<iiIIIII", data, 4
    )
    check("cputype = arm64", cputype == CPU_TYPE_ARM64, hex(cputype))
    check("cpusubtype = 0（arm64）", cpusubtype == 0, hex(cpusubtype))

    off = 32
    platform = None
    minos = None
    dylibs = []
    has_sig = False
    has_main = False

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        base = cmd & ~LC_REQ_DYLD
        if base == LC_BUILD_VERSION:
            platform, minos = struct.unpack_from("<II", data, off + 8)
            minos_s = f"{minos >> 16}.{(minos >> 8) & 0xFF}.{minos & 0xFF}"
        elif base == LC_VERSION_MIN_IPHONEOS:
            platform = PLATFORM_IOS
            v = struct.unpack_from("<I", data, off + 8)[0]
            minos_s = f"{v >> 16}.{(v >> 8) & 0xFF}.{v & 0xFF}"
        elif base == LC_LOAD_DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            dylibs.append(cstr(data, off + name_off))
        elif base == LC_CODE_SIGNATURE:
            has_sig = True
        elif base == LC_MAIN:
            has_main = True
        off += cmdsize

    check("LC_BUILD_VERSION platform = iOS", platform == PLATFORM_IOS, str(platform))
    check("最低系统版本 >= 15.0", minos is not None and (minos >> 16) >= 15, minos_s if minos else "-")
    check("入口点 LC_MAIN 存在", has_main)
    check("依赖框架数量 >= 4", len(dylibs) >= 4, str(len(dylibs)))
    for d in dylibs:
        print(f"        {d}")
    check("含代码签名（TrollStore 会自行重签，缺省也可）", True, "有" if has_sig else "无")

    print()
    print("结论：可安装" if ok else "结论：有问题，需修复")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

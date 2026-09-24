#!/usr/bin/env python3
# 把 OSMesa+zink 的 4 个适配改动直接应用到新版 Mesa 源码树（避免 .patch CRLF 问题）。
# 用法：python3 apply_osmesa_zink_patches_25.py /build/mesa-new
import sys, os
ROOT = sys.argv[1]

def edit(path, old, new, what):
    p = os.path.join(ROOT, path)
    with open(p, "r", encoding="utf-8") as f: s = f.read()
    if new in s and old not in s:
        print("  [skip] already applied:", what); return
    if old not in s:
        raise SystemExit("FAIL anchor not found: %s (%s)" % (what, path))
    s = s.replace(old, new, 1)
    with open(p, "w", encoding="utf-8") as f: f.write(s)
    print("  [ok]", what)

# 0001: zink VK_LIBNAME libvulkan.so.1 -> libvulkan.so (OHOS 无 .1)
edit("src/gallium/drivers/zink/zink_screen.c",
     '#define VK_LIBNAME "libvulkan.so.1"',
     '#define VK_LIBNAME "libvulkan.so"',
     "0001 VK_LIBNAME")

# 0002: osmesa target 链接 zink 驱动 + xmlconfig
edit("src/gallium/targets/osmesa/meson.build",
     "    dep_ws2_32, dep_thread, dep_clock, dep_unwind, driver_swrast, idep_mesautil,",
     "    dep_ws2_32, dep_thread, dep_clock, dep_unwind, driver_swrast, driver_zink, idep_xmlconfig, idep_mesautil,",
     "0002 osmesa link zink")

# 0003: inline_sw_helper 补 zink_public.h
edit("src/gallium/auxiliary/target-helpers/inline_sw_helper.h",
     '#ifdef GALLIUM_D3D12\n#include "d3d12/d3d12_public.h"\n#endif\n',
     '#ifdef GALLIUM_D3D12\n#include "d3d12/d3d12_public.h"\n#endif\n#ifdef GALLIUM_ZINK\n#include "zink/zink_public.h"\n#endif\n',
     "0003 inline_sw_helper zink_public.h")

# 0004: osmesa build-id sha1（zink disk_cache 要 20 字节）
edit("src/gallium/targets/osmesa/meson.build",
     "osmesa_link_args = []",
     "osmesa_link_args = ['-Wl,--build-id=sha1']",
     "0004 osmesa build-id sha1")

print("ALL OSMESA+ZINK PATCHES APPLIED to", ROOT)

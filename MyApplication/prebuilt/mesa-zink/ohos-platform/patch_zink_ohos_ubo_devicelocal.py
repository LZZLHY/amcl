#!/usr/bin/env python3
# patch_zink_ohos_ubo_devicelocal.py
#
# 修复 MC 1.21.2+ 新管线世界几何体全黑（1.20.1 正常）。
#
# 根因（真机 + zink 源码 instrument 定位）：MC 1.21.2+ 用持久映射(ARB_buffer_storage
# COHERENT|PERSISTENT)的 UBO 环形缓冲。zink 在 update_alloc_info_flags 里只给 MAP_COHERENT
# 缓冲加 HOST_COHERENT（纯 host-visible，无 DEVICE_LOCAL）。Maleoon 的常量缓冲硬件无法寻址
# 纯 host-only 内存 → 驱动报 "UniformDescriptor csharp addr is 0" → 着色器读零 → 带光照的
# 世界几何体全黑（天空/UI/手持物走别的路径故正常）。
#
# 修法：Maleoon 是统一内存 GPU（device-local 同时 host-visible）。对【既 coherent 映射、又
# 作常量缓冲】的 buffer 额外加 DEVICE_LOCAL_BIT，让 zink 选到 device-local+host-visible 的
# 统一内存类型——既能持久映射、又能被常量缓冲硬件寻址。若无此内存类型，zink 既有的 heap 降级
# 逻辑会回退到原 HOST_VISIBLE_COHERENT（不劣于现状）。
#
# 用法：python3 patch_zink_ohos_ubo_devicelocal.py /build/mesa-ohos-src

import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
RES = os.path.join(ROOT, "src/gallium/drivers/zink/zink_resource.c")
MARK = "AMCL_OHOS_UBO_DEVLOCAL"

with open(RES, "r", encoding="utf-8") as f:
    c = f.read()
if MARK in c:
    print("already patched ubo devicelocal"); sys.exit(0)

anchor = ("   if (templ->flags & PIPE_RESOURCE_FLAG_MAP_COHERENT || templ->usage == PIPE_USAGE_DYNAMIC)\n"
          "      alloc_info->flags |= VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;\n")
if anchor not in c:
    raise SystemExit("FAIL: MAP_COHERENT flags anchor not found in update_alloc_info_flags")

new = ("   if (templ->flags & PIPE_RESOURCE_FLAG_MAP_COHERENT || templ->usage == PIPE_USAGE_DYNAMIC) {\n"
       "      alloc_info->flags |= VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;\n"
       "      /* " + MARK + ": Maleoon(统一内存) 常量缓冲硬件无法寻址纯 host-only 内存→addr 0→\n"
       "       * MC 1.21.2+ 持久映射 UBO 全黑。对 coherent 的常量缓冲额外要 DEVICE_LOCAL，\n"
       "       * 落到 device-local+host-visible 统一内存（既可映射又可作常量缓冲寻址）。 */\n"
       "      if (templ->bind & PIPE_BIND_CONSTANT_BUFFER)\n"
       "         alloc_info->flags |= VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;\n"
       "   }\n")
c = c.replace(anchor, new, 1)

with open(RES, "w", encoding="utf-8") as f:
    f.write(c)
print("patched zink_resource.c: coherent constant-buffers -> DEVICE_LOCAL (unified mem)")
print("ALL DONE")

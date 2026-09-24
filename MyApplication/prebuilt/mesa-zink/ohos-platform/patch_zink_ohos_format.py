#!/usr/bin/env python3
# patch_zink_ohos_format.py — 强制 OHOS kopper swapchain 用 VK_FORMAT_R8G8B8A8_UNORM(37)。
#
# 背景：Mesa EGL config 惯例是 BGRA，zink 直接拿其格式当 swapchain imageFormat=VkFormat 44
# (B8G8R8A8)。OHOS Vulkan WSI 报 "Swapchain format 44 unsupported"。X11/Wayland 上 BGRA 通用
# 故 zink 从不校验 surface 支持的格式；OHOS 不支持 BGRA → swapchain 创建异常 → 黑屏。
# 修：OHOS（KOPPER_OHOS）把 cdt->formats[0] 覆盖为 VK_FORMAT_R8G8B8A8_UNORM（OHOS 原生支持）。

import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_FORMAT"

with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()

if MARK in c:
    print("zink_kopper.c format already patched")
    sys.exit(0)

anchor = "   cdt->formats[0] = zink_get_format(screen, format);"
if anchor not in c:
    raise SystemExit("PATCH FAIL: formats[0] anchor not found")

repl = (anchor + "\n"
        "   /* " + MARK + ": OHOS Vulkan WSI 不支持 BGRA(VkFormat44)，强制 RGBA(VK_FORMAT_R8G8B8A8_UNORM=37)。 */\n"
        "   if (cdt->type == KOPPER_OHOS)\n"
        "      cdt->formats[0] = VK_FORMAT_R8G8B8A8_UNORM;")
c = c.replace(anchor, repl, 1)

with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched zink_kopper.c OHOS swapchain format -> VK_FORMAT_R8G8B8A8_UNORM")

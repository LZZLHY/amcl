#!/usr/bin/env python3
# patch_zink_ohos_no_mutable_format.py
#
# 根因修复（黑屏）：zink 给 OHOS swapchain 设了 VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR
# + VkImageFormatListCreateInfo(pNext)，且 view-format list 里的 formats[1] 是【强制 RGBA 之前】
# 原始格式的 sRGB 对应（通常是 BGRA-sRGB），与 imageFormat(R8G8B8A8_UNORM=37) 不匹配。
# HarmonyOS RenderService 的硬件/skia 合成器无法消费 mutable-format / 格式不匹配的 buffer：
# vkQueuePresentKHR 返回 VK_SUCCESS、zink readback 正确（紫），但 RS 拿不到可合成 buffer → 黑屏。
# （能上屏的纯 Vulkan 自检用的是 flags=0 / pNext=NULL 的干净单格式 swapchain。）
#
# 修法：在 zink_kopper_displaytarget_init 里，对 OHOS 强制 srgb=PIPE_FORMAT_NONE
#   → formats[1] 保持 VK_FORMAT_UNDEFINED
#   → zink_kopper_has_srgb()=false → scci.flags=0（无 MUTABLE_FORMAT）
#   → `if (cdt->formats[1])` 不成立 → scci.pNext 不挂 format_list
# 得到与自检一致的干净 swapchain。
#
# 另加一行 WSI 日志，落盘 flags / pNext-nonnull / colorSpace / formats[1] 以便真机核对。
#
# 用法：python3 patch_zink_ohos_no_mutable_format.py /build/mesa-ohos-src

import sys, os

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_NO_MUTABLE"

with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()

if MARK in c:
    print("already patched no-mutable-format")
    sys.exit(0)

# (1) displaytarget_init：OHOS 强制 srgb=NONE（紧接 formats[0] 的 OHOS 覆盖之后）。
anchor1 = (
    "   if (cdt->info.bos.sType == AMCL_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS)\n"
    "      cdt->formats[0] = VK_FORMAT_R8G8B8A8_UNORM;\n"
)
if anchor1 not in c:
    raise SystemExit("FAIL: formats[0] OHOS override anchor not found")
new1 = (
    "   if (cdt->info.bos.sType == AMCL_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS) {\n"
    "      cdt->formats[0] = VK_FORMAT_R8G8B8A8_UNORM;\n"
    "      /* " + MARK + ": 关掉 sRGB view 格式 → formats[1]=UNDEFINED → has_srgb=false →\n"
    "       * swapchain flags=0（无 MUTABLE_FORMAT）+ pNext=NULL（无 format_list）。OHOS RS\n"
    "       * 无法合成 mutable/格式不匹配 buffer（present 成功但黑屏）；干净单格式 swapchain\n"
    "       * 与能上屏的纯 Vulkan 自检一致。 */\n"
    "      srgb = PIPE_FORMAT_NONE;\n"
    "   }\n"
)
c = c.replace(anchor1, new1, 1)

# (2) 在 swapchain_created 日志之后，补一行 flags/pNext/colorSpace/fmt1 落盘（核对用）。
anchor2 = (
    "      amcl_wsi_logf(\"swapchain_created fmt/w/h/minImg/usage/compAlpha/presentMode\",\n"
    "                    cswap->scci.imageFormat, cswap->scci.imageExtent.width, cswap->scci.imageExtent.height,\n"
    "                    cswap->scci.minImageCount, cswap->scci.imageUsage, cswap->scci.compositeAlpha,\n"
    "                    cswap->scci.presentMode);\n"
)
if anchor2 in c:
    log2 = anchor2 + (
        "   if (cdt->type == KOPPER_OHOS)\n"
        "      amcl_wsi_logf(\"swapchain flags/pNextNonNull/colorSpace/fmt1\",\n"
        "                    (long)cswap->scci.flags, (long)(cswap->scci.pNext != NULL),\n"
        "                    (long)cswap->scci.imageColorSpace, (long)cdt->formats[1], 0, 0, 0);\n"
    )
    c = c.replace(anchor2, log2, 1)
    print("patched WSI flags/pNext log")
else:
    print("WARN: swapchain_created log anchor not found (skip extra log; WSI-log patch may differ)")

with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched zink_kopper.c: OHOS clean single-format swapchain (no MUTABLE_FORMAT / no format_list)")
print("ALL DONE")

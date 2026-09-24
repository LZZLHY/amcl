#!/usr/bin/env python3
# 给 OHOS swapchain 削减 imageUsage：去掉 SAMPLED/INPUT_ATTACHMENT/FEEDBACK_LOOP，
# 仅保留 COLOR_ATTACHMENT|TRANSFER_DST|TRANSFER_SRC（贴近能上屏的纯 Vulkan 自检 usage=18）。
# 依据：纯 Vulkan 自检(COLOR_ATTACHMENT|TRANSFER_DST)真机变蓝；zink 默认 usage=151 多出的
# SAMPLED/INPUT_ATTACHMENT 位可能让 OHOS buffer 以 RS 无法合成的方式分配 → 黑屏。
import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_USAGE"
with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()
if MARK in c:
    print("already patched usage"); sys.exit(0)
anchor = ("      if (cdt->caps.supportedUsageFlags & VK_IMAGE_USAGE_ATTACHMENT_FEEDBACK_LOOP_BIT_EXT)\n"
          "         cswap->scci.imageUsage |= VK_IMAGE_USAGE_ATTACHMENT_FEEDBACK_LOOP_BIT_EXT;\n")
if anchor not in c:
    raise SystemExit("FAIL: imageUsage anchor not found")
inject = (anchor +
    "      /* " + MARK + ": OHOS RS 仅合成 COLOR_ATTACHMENT|TRANSFER_DST 用法的 buffer（纯 Vulkan\n"
    "       * 自检该用法真机变蓝；zink 默认多加 SAMPLED/INPUT_ATTACHMENT 致 OHOS buffer 分配方式\n"
    "       * RS 无法硬件合成=黑屏）。仅保留 color/transfer。 */\n"
    "      if (cdt->info.bos.sType == ((VkStructureType)1000685000))\n"
    "         cswap->scci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |\n"
    "                                  VK_IMAGE_USAGE_TRANSFER_DST_BIT |\n"
    "                                  VK_IMAGE_USAGE_TRANSFER_SRC_BIT;\n")
c = c.replace(anchor, inject, 1)
with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched OHOS swapchain imageUsage -> COLOR_ATTACHMENT|TRANSFER_DST|TRANSFER_SRC")

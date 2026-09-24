#!/usr/bin/env python3
# patch_zink_ohos_match_selftest.py
#
# 让 zink 的 OHOS swapchain 与【能上屏的纯 Vulkan 自检 runVulkanSelfTest】逐字段一致，
# 排除 swapchain 参数的最后两处差异：
#   1) minImageCount：zink 用 caps.minImageCount(=3)，自检用 caps.minImageCount+1(=4)。
#      某些 WSI/合成器在恰好等于 minImageCount 时 producer 占满 buffer，consumer 饥饿
#      → present 成功但 RS 拿不到可合成 buffer（黑屏）。
#   2) imageUsage：zink=COLOR|TRANSFER_DST|TRANSFER_SRC(=19)，自检=COLOR|TRANSFER_DST(=18)。
#      去掉 TRANSFER_SRC，与自检完全一致（避免多余 usage 影响 OHOS buffer 分配）。
#
# 用法：python3 patch_zink_ohos_match_selftest.py /build/mesa-ohos-src

import sys, os

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_MATCH_SELFTEST"

with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()

if MARK in c:
    print("already patched match-selftest")
    sys.exit(0)

# (1) usage：把 OHOS 的 TRANSFER_SRC 去掉（19 -> 18），与自检一致。
anchor_usage = (
    "      if (cdt->info.bos.sType == ((VkStructureType)1000685000))\n"
    "         cswap->scci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |\n"
    "                                  VK_IMAGE_USAGE_TRANSFER_DST_BIT |\n"
    "                                  VK_IMAGE_USAGE_TRANSFER_SRC_BIT;\n"
)
new_usage = (
    "      if (cdt->info.bos.sType == ((VkStructureType)1000685000))\n"
    "         /* " + MARK + ": 与纯 Vulkan 自检一致 = COLOR_ATTACHMENT|TRANSFER_DST(=18)。 */\n"
    "         cswap->scci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |\n"
    "                                  VK_IMAGE_USAGE_TRANSFER_DST_BIT;\n"
)
if anchor_usage not in c:
    raise SystemExit("FAIL: OHOS usage anchor not found")
c = c.replace(anchor_usage, new_usage, 1)

# (2) minImageCount：OHOS 用 caps.minImageCount + 1（clamp 到 maxImageCount），与自检一致。
anchor_min = "   cswap->scci.minImageCount = cdt->caps.minImageCount;\n"
new_min = (
    "   cswap->scci.minImageCount = cdt->caps.minImageCount;\n"
    "   if (cdt->info.bos.sType == ((VkStructureType)1000685000)) {\n"
    "      /* " + MARK + ": OHOS 用 minImageCount+1（自检同款，避免 producer 占满致 consumer 饥饿黑屏）。 */\n"
    "      cswap->scci.minImageCount = cdt->caps.minImageCount + 1;\n"
    "      if (cdt->caps.maxImageCount > 0 && cswap->scci.minImageCount > cdt->caps.maxImageCount)\n"
    "         cswap->scci.minImageCount = cdt->caps.maxImageCount;\n"
    "   }\n"
)
if anchor_min not in c:
    raise SystemExit("FAIL: minImageCount anchor not found")
c = c.replace(anchor_min, new_min, 1)

with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched zink_kopper.c: OHOS swapchain minImageCount+1 + usage=18 (match self-test)")
print("ALL DONE")

#!/usr/bin/env python3
# patch_zink_wsi_log.py — 给 zink kopper OHOS 路径加地面真相日志（写 $AMCL_FILES_DIR/zink_wsi.log）。
# 记录 swapchain 创建参数 + CreateSwapchainKHR 结果 + QueuePresentKHR 结果，定位黑屏。
import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_WSI_LOG"
with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()
if MARK in c:
    print("already patched WSI log"); sys.exit(0)

# 1) 日志助手：插在 PFN_AmclCreateSurfaceOHOS typedef 之后。
helper = (
    "typedef VkResult (VKAPI_PTR *PFN_AmclCreateSurfaceOHOS)(VkInstance, const void *, const VkAllocationCallbacks *, VkSurfaceKHR *);\n"
    "#include <stdio.h>\n"
    "/* " + MARK + " */\n"
    "static void amcl_wsi_logf(const char *tag, long a, long b, long c, long d, long e, long f, long g) {\n"
    "   const char *dir = getenv(\"AMCL_FILES_DIR\");\n"
    "   if (!dir) return;\n"
    "   char path[512];\n"
    "   snprintf(path, sizeof(path), \"%s/zink_wsi.log\", dir);\n"
    "   FILE *fp = fopen(path, \"a\");\n"
    "   if (!fp) return;\n"
    "   fprintf(fp, \"%s: %ld %ld %ld %ld %ld %ld %ld\\n\", tag, a, b, c, d, e, f, g);\n"
    "   fclose(fp);\n"
    "}\n"
)
anchor1 = "typedef VkResult (VKAPI_PTR *PFN_AmclCreateSurfaceOHOS)(VkInstance, const void *, const VkAllocationCallbacks *, VkSurfaceKHR *);\n"
if anchor1 not in c:
    raise SystemExit("FAIL: PFN typedef anchor not found")
c = c.replace(anchor1, helper, 1)

# 2) swapchain 创建结果日志：插在 cswap->last_present = UINT32_MAX; 之前。
anchor2 = "   cswap->last_present = UINT32_MAX;\n"
if anchor2 not in c:
    raise SystemExit("FAIL: last_present anchor not found")
log2 = (
    "   if (cdt->type == KOPPER_OHOS)\n"
    "      amcl_wsi_logf(\"swapchain_created fmt/w/h/minImg/usage/compAlpha/presentMode\",\n"
    "                    cswap->scci.imageFormat, cswap->scci.imageExtent.width, cswap->scci.imageExtent.height,\n"
    "                    cswap->scci.minImageCount, cswap->scci.imageUsage, cswap->scci.compositeAlpha,\n"
    "                    cswap->scci.presentMode);\n"
    + anchor2
)
c = c.replace(anchor2, log2, 1)

# 3) present 结果日志：插在 QueuePresentKHR 之后。
anchor3 = "   VkResult error2 = VKSCR(QueuePresentKHR)(screen->queue, &cpi->info);\n"
if anchor3 not in c:
    raise SystemExit("FAIL: QueuePresentKHR anchor not found")
log3 = (
    anchor3 +
    "   if (cdt->type == KOPPER_OHOS) {\n"
    "      static unsigned long s_amcl_pc = 0;\n"
    "      if (s_amcl_pc < 3 || (s_amcl_pc % 300) == 0)\n"
    "         amcl_wsi_logf(\"present err2/image/preTransform\", error2, cpi->image,\n"
    "                       (long)s_amcl_pc, (long)cdt->caps.currentTransform,\n"
    "                       (long)cdt->caps.currentExtent.width, (long)cdt->caps.currentExtent.height, 0);\n"
    "      s_amcl_pc++;\n"
    "   }\n"
)
c = c.replace(anchor3, log3, 1)

with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched WSI log (helper + swapchain_created + present)")

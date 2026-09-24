#!/usr/bin/env python3
# patch_zink_ohos_present_drain.py
#
# 实验（根因已锁定在 present 提交方式）：真机已证明纯 Vulkan present 能给 mc_game_surface
# 上屏（蓝），zink 同 surface 同 swapchain 参数却不交付。两者唯一行为差异是【串行化】：
# 能上屏的自检每帧 present 后 CPU waitFence + 节流，完全跑完一帧才进下一帧；zink 是流水线、
# 多帧在飞。怀疑 OHOS WSI 的 present→consumer 交付需要 present 彻底排空才生效。
#
# 本补丁：OHOS 在 QueuePresentKHR 之后立即 vkQueueWaitIdle(screen->queue)，强制每帧 present
# 彻底完成再继续（与自检的串行语义一致）。若出图=根因为 present 未排空/时序（后续可换更轻的
# fence 等待优化帧率）；若仍黑=继续查 present 提交的其它差异。
#
# 用法：python3 patch_zink_ohos_present_drain.py /build/mesa-ohos-src

import sys, os

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_PRESENT_DRAIN"

with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()

if MARK in c:
    print("already patched present drain")
    sys.exit(0)

# 在 OHOS 的 present 日志块之后插入 QueueWaitIdle。该块紧跟 QueuePresentKHR，且仍持 queue_lock。
anchor = (
    "   VkResult error2 = VKSCR(QueuePresentKHR)(screen->queue, &cpi->info);\n"
    "   if (cdt->type == KOPPER_OHOS) {\n"
)
if anchor not in c:
    raise SystemExit("FAIL: QueuePresentKHR OHOS log anchor not found")

inject = (
    "   VkResult error2 = VKSCR(QueuePresentKHR)(screen->queue, &cpi->info);\n"
    "   if (cdt->type == KOPPER_OHOS) {\n"
    "      /* " + MARK + ": 强制每帧 present 彻底排空（与能上屏的纯 Vulkan 自检串行语义一致），\n"
    "       * 验证 OHOS WSI 是否需要 present drain 才把 buffer 交付 RS。 */\n"
    "      VKSCR(QueueWaitIdle)(screen->queue);\n"
)
c = c.replace(anchor, inject, 1)

with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched zink_kopper.c: OHOS QueueWaitIdle after present (drain experiment)")
print("ALL DONE")

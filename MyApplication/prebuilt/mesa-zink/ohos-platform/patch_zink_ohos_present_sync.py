#!/usr/bin/env python3
# 让 OHOS present 跳过 implicit_sync 路径（当成 WIN32）：直接 vkQueuePresentKHR 带 render
# 信号量，而非"CPU 等 fence 后 present 不带信号量"。
# 依据：纯 Vulkan 自检(直接带信号量 present)真机变蓝；zink 对非 WIN32 走 implicit_sync
# (present 不带 wait 信号量)，OHOS WSI 靠该信号量触发 buffer 交付，缺失→不交付→黑屏。
import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_PRESENT_SYNC"
with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()
if MARK in c:
    print("already patched present sync"); sys.exit(0)
anchor = "   if (screen->driver_workarounds.implicit_sync && cdt->type != KOPPER_WIN32) {"
if anchor not in c:
    raise SystemExit("FAIL: implicit_sync anchor not found")
new = ("   /* " + MARK + ": OHOS 当成 WIN32——跳过 implicit_sync，直接带 render 信号量 present\n"
       "    * （OHOS WSI 靠 present 的 wait 信号量触发 buffer 交付；implicit_sync 路径 present 不带\n"
       "    * 信号量 → buffer 不交付 RS = 黑屏。纯 Vulkan 自检直接带信号量 present 真机变蓝）。 */\n"
       "   if (screen->driver_workarounds.implicit_sync && cdt->type != KOPPER_WIN32 && cdt->type != KOPPER_OHOS) {")
c = c.replace(anchor, new, 1)
with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched OHOS present to skip implicit_sync (direct present with semaphore)")

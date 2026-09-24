#!/usr/bin/env python3
# 让 OHOS 走同步 present（直接调 kopper_present，不丢异步 util_queue）。
# 依据：能上屏的纯 Vulkan 自检是同步 present（present 后立即 waitFence，调用线程）；zink 默认
# 把 kopper_present 丢到 flush_queue 异步线程 + timeline 信号量 + 多帧在飞，可能与 OHOS WSI
# 的 acquire/release 语义不合（真机表现：present VK_SUCCESS 但 buffer 不交付 RS=黑）。
import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_SYNC_PRESENT"
with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()
if MARK in c:
    print("already patched sync present"); sys.exit(0)
anchor = ("   if (util_queue_is_initialized(&screen->flush_queue)) {\n"
          "      p_atomic_inc(&cpi->swapchain->async_presents);")
if anchor not in c:
    raise SystemExit("FAIL: present-queue anchor not found")
new = ("   /* " + MARK + ": OHOS 强制同步 present（贴近能上屏的纯 Vulkan 自检；异步 util_queue\n"
       "    * present 与 OHOS WSI 的 acquire/release 不合致黑屏）。 */\n"
       "   if (util_queue_is_initialized(&screen->flush_queue) && cdt->type != KOPPER_OHOS) {\n"
       "      p_atomic_inc(&cpi->swapchain->async_presents);")
c = c.replace(anchor, new, 1)
with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched OHOS synchronous present")

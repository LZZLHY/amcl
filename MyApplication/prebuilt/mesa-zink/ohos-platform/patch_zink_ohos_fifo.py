#!/usr/bin/env python3
# 强制 OHOS swapchain 用 FIFO present mode：MAILBOX(默认 interval=0)下 swapchain 可能握住
# XComponent buffer 队列的全部 buffer，RS 消费端拿不到→黑。FIFO 保证 buffer 按序交付。
import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_FIFO"
with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()
if MARK in c:
    print("already patched FIFO"); sys.exit(0)
anchor = "   assert(interval >= 0); /* TODO: VK_PRESENT_MODE_FIFO_RELAXED_KHR */\n"
if anchor not in c:
    raise SystemExit("FAIL: present-mode anchor not found")
inject = (anchor +
    "   /* " + MARK + ": OHOS XComponent 用 FIFO 保证 buffer 交付 RS 消费端（MAILBOX 会黑屏）。 */\n"
    "   if (cdt->info.bos.sType == ((VkStructureType)1000685000)) {\n"
    "      cdt->present_mode = VK_PRESENT_MODE_FIFO_KHR;\n"
    "      return;\n"
    "   }\n")
c = c.replace(anchor, inject, 1)
with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched OHOS FIFO present mode")

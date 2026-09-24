#!/usr/bin/env python3
# patch_zink_ohos_no_recreate.py
#
# 实验：zink 启动时建两次 swapchain（displaytarget_init 建 #1，首次 acquire 因 new_dt 用
# oldSwapchain 重建 #2）。能上屏的纯 Vulkan 自检只建一个 swapchain。怀疑 OHOS 上重建
# (oldSwapchain 退役)会破坏 native window BufferQueue 的 producer/consumer 绑定 → present
# 成功但 RS 不消费。
#
# 本补丁：OHOS 在 kopper_acquire 里，若已有同尺寸 swapchain（init 已建），跳过重建（清 new_dt
# 沿用唯一 swapchain），与自检的单 swapchain 一致。真正 resize 时尺寸不符仍会重建。
#
# 用法：python3 patch_zink_ohos_no_recreate.py /build/mesa-ohos-src

import sys, os

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
MARK = "AMCL_OHOS_NO_RECREATE"

with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()

if MARK in c:
    print("already patched no-recreate")
    sys.exit(0)

anchor = (
    "   while (true) {\n"
    "      if (res->obj->new_dt) {\n"
    "         VkResult error = update_swapchain(screen, cdt, res->base.b.width0, res->base.b.height0);\n"
)
if anchor not in c:
    raise SystemExit("FAIL: kopper_acquire new_dt anchor not found")

new = (
    "   while (true) {\n"
    "      if (res->obj->new_dt && cdt->type == KOPPER_OHOS && cdt->swapchain &&\n"
    "          cdt->swapchain->scci.imageExtent.width == res->base.b.width0 &&\n"
    "          cdt->swapchain->scci.imageExtent.height == res->base.b.height0) {\n"
    "         /* " + MARK + ": 同尺寸不重建——沿用 init 建的唯一 swapchain，避免 oldSwapchain\n"
    "          * 退役破坏 OHOS BufferQueue producer/consumer 绑定（与单 swapchain 的自检一致）。 */\n"
    "         res->obj->new_dt = false;\n"
    "      }\n"
    "      if (res->obj->new_dt) {\n"
    "         VkResult error = update_swapchain(screen, cdt, res->base.b.width0, res->base.b.height0);\n"
)
c = c.replace(anchor, new, 1)

with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("patched zink_kopper.c: OHOS skip same-size swapchain recreation")
print("ALL DONE")

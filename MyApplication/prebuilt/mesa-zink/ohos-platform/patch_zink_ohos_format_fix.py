#!/usr/bin/env python3
# 修正：格式覆盖处 cdt->type 尚未设置（init_dt_type 在之后的 kopper_CreateSurface 才调用），
# 改为直接判断 cdt->info.bos.sType。
import sys, os
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
with open(KOPPER_C, "r", encoding="utf-8") as f:
    c = f.read()
old = "   if (cdt->type == KOPPER_OHOS)\n      cdt->formats[0] = VK_FORMAT_R8G8B8A8_UNORM;"
new = ("   if (cdt->info.bos.sType == AMCL_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS)\n"
       "      cdt->formats[0] = VK_FORMAT_R8G8B8A8_UNORM;")
if new in c:
    print("already fixed")
    sys.exit(0)
if old not in c:
    raise SystemExit("PATCH FAIL: format override anchor not found")
c = c.replace(old, new, 1)
with open(KOPPER_C, "w", encoding="utf-8") as f:
    f.write(c)
print("fixed OHOS format override condition -> sType check")

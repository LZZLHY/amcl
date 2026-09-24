#!/usr/bin/env python3
# patch_zink_kopper_ohos.py — 给 Mesa zink 的 kopper WSI 加 OHOS（VK_OHOS_surface）支持。
#
# 背景：zink_kopper.c 的 init_dt_type / kopper_CreateSurface / find_dt_entry / 各 swapchain
# switch 只认 XCB/Wayland/Win32，OHOS 的 VkSurfaceCreateInfoOHOS(sType=1000685000) 命中
# default:unreachable() → abort 崩溃（真机 eglMakeCurrent→driBindContext→...→init_dt_type 崩）。
# 本脚本幂等地给 zink 加 KOPPER_OHOS：枚举 + sType 分派 + vkCreateSurfaceOHOS(经
# vk_GetInstanceProcAddr 动态取) + 窗口指针哈希 + 启用 VK_OHOS_surface 实例扩展。
#
# 对容器内 Mesa 源码树运行：python3 patch_zink_kopper_ohos.py /build/mesa-ohos-src

import sys, os, re

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"
KOPPER_C = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.c")
KOPPER_H = os.path.join(ROOT, "src/gallium/drivers/zink/zink_kopper.h")
INSTANCE_PY = os.path.join(ROOT, "src/gallium/drivers/zink/zink_instance.py")

MARK = "AMCL_OHOS_KOPPER"

def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def write(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(s, old, new, what):
    if old not in s:
        raise SystemExit("PATCH FAIL: anchor not found for: %s" % what)
    return s.replace(old, new, 1)

# ---------------- zink_kopper.h: enum ----------------
h = read(KOPPER_H)
if MARK not in h:
    h = must_replace(h,
        "   KOPPER_WIN32\n};",
        "   KOPPER_WIN32,\n   KOPPER_OHOS /* " + MARK + " */\n};",
        "enum kopper_type KOPPER_OHOS")
    write(KOPPER_H, h)
    print("patched zink_kopper.h enum")
else:
    print("zink_kopper.h already patched")

# ---------------- zink_kopper.c ----------------
c = read(KOPPER_C)
if MARK in c:
    print("zink_kopper.c already patched")
else:
    # (0) 顶部：OHOS sType 常量 + 最小 surface-create-info 结构（避免依赖 vulkan_ohos.h）。
    #     插在第一个 #include 之后第一个空行处——用 init_dt_type 之前的一个稳定锚点。
    defs = (
        "\n/* " + MARK + ": OHOS WSI（VK_OHOS_surface）——Mesa vk.xml 无此扩展，本地最小定义。 */\n"
        "#define AMCL_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS ((VkStructureType)1000685000)\n"
        "typedef struct AmclVkOhosSurfaceCreateInfo {\n"
        "   VkStructureType sType;\n"
        "   const void *pNext;\n"
        "   VkFlags flags;\n"
        "   void *window; /* OHNativeWindow* */\n"
        "} AmclVkOhosSurfaceCreateInfo;\n"
        "typedef VkResult (VKAPI_PTR *PFN_AmclCreateSurfaceOHOS)(VkInstance, const void *, const VkAllocationCallbacks *, VkSurfaceKHR *);\n"
    )
    c = must_replace(c,
        "static void\ninit_dt_type(struct kopper_displaytarget *cdt)\n{",
        defs + "\nstatic void\ninit_dt_type(struct kopper_displaytarget *cdt)\n{",
        "top defs before init_dt_type")

    # (1) init_dt_type: 加 OHOS sType → KOPPER_OHOS（插在该函数的 default: 前）。
    c = must_replace(c,
        "   case VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR:\n"
        "      cdt->type = KOPPER_WIN32;\n"
        "      break;\n"
        "#endif\n"
        "   default:\n"
        "      unreachable(\"unsupported!\");\n"
        "   }\n"
        "}",
        "   case VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR:\n"
        "      cdt->type = KOPPER_WIN32;\n"
        "      break;\n"
        "#endif\n"
        "   case AMCL_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS:\n"
        "      cdt->type = KOPPER_OHOS;\n"
        "      break;\n"
        "   default:\n"
        "      unreachable(\"unsupported!\");\n"
        "   }\n"
        "}",
        "init_dt_type OHOS case")

    # (2) kopper_CreateSurface: 加 OHOS sType → vkCreateSurfaceOHOS（动态取）。
    #     插在 kopper_CreateSurface 内 Win32 case 之后、其 default 之前。
    c = must_replace(c,
        "      error = VKSCR(CreateWin32SurfaceKHR)(screen->instance, win32, NULL, &surface);\n"
        "      break;\n"
        "   }\n"
        "#endif\n"
        "   default:\n"
        "      unreachable(\"unsupported!\");\n"
        "   }\n"
        "   if (error != VK_SUCCESS) {",
        "      error = VKSCR(CreateWin32SurfaceKHR)(screen->instance, win32, NULL, &surface);\n"
        "      break;\n"
        "   }\n"
        "#endif\n"
        "   case AMCL_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS: {\n"
        "      PFN_AmclCreateSurfaceOHOS create =\n"
        "         (PFN_AmclCreateSurfaceOHOS)screen->vk_GetInstanceProcAddr(screen->instance, \"vkCreateSurfaceOHOS\");\n"
        "      if (create)\n"
        "         error = create(screen->instance, &cdt->info.bos, NULL, &surface);\n"
        "      else\n"
        "         error = VK_ERROR_EXTENSION_NOT_PRESENT;\n"
        "      break;\n"
        "   }\n"
        "   default:\n"
        "      unreachable(\"unsupported!\");\n"
        "   }\n"
        "   if (error != VK_SUCCESS) {",
        "kopper_CreateSurface OHOS case")

    # (3) find_dt_entry: 加 OHOS → 按 window 指针查哈希（同 win32 风格）。
    c = must_replace(c,
        "      he = _mesa_hash_table_search(&screen->dts, win32->hwnd);\n"
        "      break;\n"
        "   }\n"
        "#endif\n"
        "   default:\n"
        "      unreachable(\"unsupported!\");\n"
        "   }\n"
        "   return he;",
        "      he = _mesa_hash_table_search(&screen->dts, win32->hwnd);\n"
        "      break;\n"
        "   }\n"
        "#endif\n"
        "   case KOPPER_OHOS: {\n"
        "      AmclVkOhosSurfaceCreateInfo *ohos = (AmclVkOhosSurfaceCreateInfo *)&cdt->info.bos;\n"
        "      he = _mesa_hash_table_search(&screen->dts, ohos->window);\n"
        "      break;\n"
        "   }\n"
        "   default:\n"
        "      unreachable(\"unsupported!\");\n"
        "   }\n"
        "   return he;",
        "find_dt_entry OHOS case")

    # (4) update_swapchain 尺寸 switch：OHOS 用 currentExtent（同 X11/WIN32）。
    c = must_replace(c,
        "   switch (cdt->type) {\n"
        "   case KOPPER_X11:\n"
        "   case KOPPER_WIN32:\n",
        "   switch (cdt->type) {\n"
        "   case KOPPER_X11:\n"
        "   case KOPPER_WIN32:\n"
        "   case KOPPER_OHOS:\n",
        "update_swapchain sizing OHOS")

    # (5) dts 哈希表初始化：OHOS 用指针哈希（同 wayland/win32）。
    c = must_replace(c,
        "         case KOPPER_WAYLAND:\n"
        "         case KOPPER_WIN32:\n"
        "            _mesa_hash_table_init(&screen->dts, screen, _mesa_hash_pointer, _mesa_key_pointer_equal);\n",
        "         case KOPPER_WAYLAND:\n"
        "         case KOPPER_WIN32:\n"
        "         case KOPPER_OHOS:\n"
        "            _mesa_hash_table_init(&screen->dts, screen, _mesa_hash_pointer, _mesa_key_pointer_equal);\n",
        "dts init OHOS")

    # (6) dts 插入：OHOS 按 window 指针插入。
    c = must_replace(c,
        "      _mesa_hash_table_insert(&screen->dts, win32->hwnd, cdt);\n"
        "      break;\n"
        "   }\n"
        "#endif\n"
        "   default:",
        "      _mesa_hash_table_insert(&screen->dts, win32->hwnd, cdt);\n"
        "      break;\n"
        "   }\n"
        "#endif\n"
        "   case KOPPER_OHOS: {\n"
        "      AmclVkOhosSurfaceCreateInfo *ohos = (AmclVkOhosSurfaceCreateInfo *)&cdt->info.bos;\n"
        "      _mesa_hash_table_insert(&screen->dts, ohos->window, cdt);\n"
        "      break;\n"
        "   }\n"
        "   default:",
        "dts insert OHOS")

    write(KOPPER_C, c)
    print("patched zink_kopper.c (6 sites)")

# ---------------- zink_instance.py: 启用 VK_OHOS_surface ----------------
inst = read(INSTANCE_PY)
if "VK_OHOS_surface" not in inst:
    inst = must_replace(inst,
        '    Extension("VK_KHR_win32_surface"),\n]',
        '    Extension("VK_KHR_win32_surface"),\n'
        '    Extension("VK_OHOS_surface", nonstandard=True),\n]',
        "zink_instance.py VK_OHOS_surface")
    write(INSTANCE_PY, inst)
    print("patched zink_instance.py VK_OHOS_surface")
else:
    print("zink_instance.py already patched")

print("ALL DONE")

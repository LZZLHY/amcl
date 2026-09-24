#!/usr/bin/env python3
# 在 Mesa 源码树注册 OHOS EGL 平台（Phase 2c-A）。幂等。
# 用法（容器）：python3 register_ohos_platform.py /build/mesa-ohos-src
import sys, os

root = sys.argv[1] if len(sys.argv) > 1 else "/build/mesa-ohos-src"

def patch(path, anchor, insert, tag):
    full = os.path.join(root, path)
    with open(full, "r", encoding="utf-8") as f:
        s = f.read()
    if tag in s:
        print(f"  [skip] {path} (already has {tag})")
        return
    if anchor not in s:
        print(f"  [FAIL] {path}: anchor not found: {anchor!r}")
        return
    s = s.replace(anchor, anchor + insert, 1)
    with open(full, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"  [ok]   {path}")

# 1) meson_options.txt: platforms choices 加 'ohos'
patch("meson_options.txt",
      "    'auto', 'x11', 'wayland', 'haiku', 'android', 'windows', 'macos',",
      "\n    'ohos',",
      "'ohos',")

# 2) meson.build: with_platform_ohos
patch("meson.build",
      "with_platform_windows = _platforms.contains('windows')",
      "\nwith_platform_ohos = _platforms.contains('ohos')",
      "with_platform_ohos")

# 3) egldisplay.h: 枚举
patch("src/egl/main/egldisplay.h",
      "   _EGL_PLATFORM_WINDOWS,\n",
      "   _EGL_PLATFORM_OHOS,\n",
      "_EGL_PLATFORM_OHOS")

# 4) egldisplay.c: 名表
patch("src/egl/main/egldisplay.c",
      '   {_EGL_PLATFORM_WINDOWS, "windows"},\n',
      '   {_EGL_PLATFORM_OHOS, "ohos"},\n',
      '_EGL_PLATFORM_OHOS, "ohos"')

# 5) egl_dri2.h: 初始化声明（仿 android 的 ifdef/inline-stub）
patch("src/egl/drivers/dri2/egl_dri2.h",
      "dri2_initialize_device(_EGLDisplay *disp);\n",
      ("\n#ifdef HAVE_OHOS_PLATFORM\n"
       "EGLBoolean\n"
       "dri2_initialize_ohos(_EGLDisplay *disp);\n"
       "#else\n"
       "static inline EGLBoolean\n"
       "dri2_initialize_ohos(_EGLDisplay *disp) { return _eglError(EGL_NOT_INITIALIZED, \"OHOS platform not built\"); }\n"
       "#endif\n"),
      "dri2_initialize_ohos")

# 6) egl_dri2.c: dri2_initialize switch case
patch("src/egl/drivers/dri2/egl_dri2.c",
      "   case _EGL_PLATFORM_ANDROID:\n      ret = dri2_initialize_android(disp);\n      break;\n",
      "   case _EGL_PLATFORM_OHOS:\n      ret = dri2_initialize_ohos(disp);\n      break;\n",
      "dri2_initialize_ohos(disp)")

# 7) src/egl/meson.build: 编入 platform_ohos.c
patch("src/egl/meson.build",
      "    'drivers/dri2/platform_surfaceless.c',\n  )\n",
      "\n  if with_platform_ohos\n    files_egl += files('drivers/dri2/platform_ohos.c')\n  endif\n",
      "platform_ohos.c")

print("done.")

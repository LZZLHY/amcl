# Mesa EGL OHOS 平台（Phase 2c-A，zink kopper 直呈现）

`platform_ohos.c` 是为 OpenHarmony 新增的 Mesa EGL DRI2 平台，让 zink 经 kopper WSI 直接
呈现到 XComponent 的 OHNativeWindow（VkSurface + swapchain，零回读），取代 OSMesa 离屏+readback。

## 注入方式

`platform_ohos.c` 复制到 Mesa 源码树 `src/egl/drivers/dri2/platform_ohos.c`，并按下方在 5 处注册
（最终固化为 `prebuilt/mesa-zink/patches/00NN-ohos-egl-platform.patch`）。

## 注册点（精确）

### 1. `src/egl/main/egldisplay.h` — 平台枚举
在 `_EGL_PLATFORM_WINDOWS,` 后加：
```c
   _EGL_PLATFORM_OHOS,
```

### 2. `src/egl/drivers/dri2/egl_dri2.h` — 初始化声明
仿 `dri2_initialize_android` 的 `#ifdef HAVE_ANDROID_PLATFORM` 块，加：
```c
#ifdef HAVE_OHOS_PLATFORM
EGLBoolean dri2_initialize_ohos(_EGLDisplay *disp);
#else
static inline EGLBoolean dri2_initialize_ohos(_EGLDisplay *disp) { return _eglError(EGL_NOT_INITIALIZED, "OHOS platform not built"); }
#endif
```

### 3. `src/egl/drivers/dri2/egl_dri2.c` — 初始化分派（~908 行 switch）
在 `case _EGL_PLATFORM_ANDROID:` 块后加：
```c
   case _EGL_PLATFORM_OHOS:
      ret = dri2_initialize_ohos(disp);
      break;
```
（若 ~999 行还有第二个按平台 switch 的 teardown，也加 `case _EGL_PLATFORM_OHOS:` 走默认。）

### 4. `src/egl/main/egldisplay.c` — 平台名映射
`_eglNativePlatformDetectNativeDisplay`/平台名表里把 `"ohos"` 映射到 `_EGL_PLATFORM_OHOS`
（仿 `"android"`）。EGL_PLATFORM_OHOS_KHR 数值另在 eglext 里定义或用 `eglGetPlatformDisplay`
的字符串平台 `EGL_PLATFORM_OHOS`。

### 5. `meson_options.txt` + `src/egl/meson.build` + 顶层 `meson.build`
- `meson_options.txt`：`platforms` 的 choices 数组加 `'ohos'`。
- 顶层 `meson.build`：`with_platform_ohos = _platforms.contains('ohos')`；
  `if with_platform_ohos: pre_args += '-DHAVE_OHOS_PLATFORM'`；EGL 要求里把 ohos 视作等价 android
  （`with_dri` 链、`_platforms += 'surfaceless'` 等已满足）。
- `src/egl/meson.build`：`if with_platform_ohos: files_egl += files('drivers/dri2/platform_ohos.c')`。
- 编译需 `-DVK_USE_PLATFORM_OHOS` + OHOS sysroot 的 `vulkan/vulkan_ohos.h`（已有 VkSurfaceCreateInfoOHOS）。

## 构建（容器）

```bash
docker exec ohos-debug bash -lc "cd /build/mesa-ohos-src/build-ohos && \
  meson configure -Dplatforms=ohos && ninja"
# 产物：libEGL.so（含 OHOS 平台）+ libgallium-*.so（zink+kopper）
```

## 设备侧集成（platform 编好后）

libglfw 的 zink 分支改用 **Mesa libEGL**（非系统 EGL）：
`eglGetPlatformDisplay(EGL_PLATFORM_OHOS, native_display, NULL)` →
`eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)OHNativeWindow, NULL)` →
`eglMakeCurrent` → 渲染 → `eglSwapBuffers`（→kopper→vkQueuePresentKHR，零回读）。
替换 glfw_osmesa.cpp 的 OSMesa 离屏 + readback-blit。

libglapi/libEGL/libgallium 经 System.loadLibrary（JVM 命名空间）或绝对路径 RTLD_GLOBAL 预载，
解决 OHOS ndk 命名空间找不到 HAP 私有 libs 的问题（同 libOSMesa 经验）。

## 状态

- ✅ `platform_ohos.c` 核心实现已写（kopper OHOS surface info + zink-sw 初始化 + window surface + swap）。
- ✅ **已通过 Mesa 头文件编译验证**（容器内单文件编译零错误，2026-06-24）。
- ✅ **7 处注册完成 + 全量编译链接成功**（`register_ohos_platform.py` 幂等注册：meson_options
  platforms 加 ohos、meson.build `with_platform_ohos`、egldisplay.{h,c} 枚举+名表、egl_dri2.{h,c}
  声明+分派、egl/meson.build 编入）。`meson configure -Dplatforms=ohos` + ninja → 产出
  **`libEGL.so.1.0.0`（含 `dri2_initialize_ohos`+`kopperSetSurfaceCreateInfo` 符号）**
  + `libgallium-24.3.4.so`(zink+kopper) + `libglapi.so.0.0.0`，均 ELF64 AArch64。
- ⏳ **设备侧集成**（下一步）：libglfw 的 zink 分支从 OSMesa 离屏改用 Mesa libEGL 的
  `eglGetPlatformDisplay(EGL_PLATFORM_OHOS)` + `eglCreateWindowSurface(OHNativeWindow)` +
  `eglSwapBuffers`（→kopper→vkQueuePresentKHR 零回读）；libEGL/libgallium/libglapi/libOSMesa
  部署到 entry/libs + 经 System.loadLibrary 解决命名空间；真机联调（swapchain/格式/present 模式）。

注：注册改动的可复现方式见 `register_ohos_platform.py`（幂等，对 Mesa 源码树运行）；最终连同
`platform_ohos.c` 固化为 `prebuilt/mesa-zink/patches/00NN-ohos-egl-platform.patch`。

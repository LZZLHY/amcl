/*
 * platform_ohos.c — Mesa EGL DRI2 平台：OpenHarmony / HarmonyOS NEXT（AMCL Phase 2c-A）
 *
 * 目标：让 zink 经 kopper WSI 直接呈现到 XComponent 的 OHNativeWindow（VkSurfaceKHR + swapchain，
 * 零 CPU 回读），取代 OSMesa 离屏 + readback-blit 的慢路径。
 *
 * 设计要点（见 docs/adaptation/ZINK_RENDERER_PLAN.md Phase 2c-A）：
 *   - OHOS 无 DRM render node，故走 zink-sw 初始化（fd=-1，driver="zink"，同 surfaceless 的 sw 路径）。
 *   - 窗口 surface 把 OHNativeWindow* 存进 dri2_surf->drawable（uintptr_t），由 kopper 经
 *     kopperSetSurfaceCreateInfo 填 VkSurfaceCreateInfoOHOS 建 VkSurface。
 *   - eglSwapBuffers → kopperSwapBuffers → zink vkQueuePresentKHR。
 *
 * 本文件经 prebuilt/mesa-zink/patches 注入 Mesa 源码树 src/egl/drivers/dri2/platform_ohos.c，
 * 并在 egl_dri2.c / egldisplay.{h,c} / meson.build 注册（见同目录 README + patch）。
 *
 * SPDX-License-Identifier: MIT
 */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "egl_dri2.h"
#include "eglglobals.h"
#include "kopper_interface.h"
#include "loader.h"
#include "loader_dri_helper.h"
#include "dri_util.h"

/* OHOS Vulkan WSI（VK_OHOS_surface）。仅取结构体/枚举，不引入函数原型。 */
#define VK_USE_PLATFORM_OHOS
#include <vulkan/vulkan_core.h>
#include <vulkan/vulkan_ohos.h>

/* Mesa 自带的 vulkan_core.h 可能旧、缺 OHOS 枚举值；缺失则手动定义（值见 OHOS NDK vulkan_core.h）。 */
#ifndef VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS
#define VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS ((VkStructureType)1000685000)
#endif

static_assert(sizeof(struct kopper_vk_surface_create_storage) >=
                 sizeof(VkSurfaceCreateInfoOHOS),
              "kopper bos storage too small for VkSurfaceCreateInfoOHOS");

/* MC 单窗口：存当前 OHNativeWindow（dri2_egl_surface 无通用 native-window 字段，
 * X11 的 drawable 是 32-bit、Android 的 window 在 ifdef 内，故用文件级单例最省侵入）。 */
static OHNativeWindow *g_ohos_window;

EGLBoolean dri2_initialize_ohos(_EGLDisplay *disp);

/* ---- kopper：把 OHNativeWindow 包成 VkSurfaceCreateInfoOHOS ---- */
static void
kopperSetSurfaceCreateInfo(void *_draw, struct kopper_loader_info *ci)
{
   struct dri2_egl_surface *dri2_surf = _draw;
   VkSurfaceCreateInfoOHOS *ohos = (VkSurfaceCreateInfoOHOS *)&ci->bos;

   if (dri2_surf->base.Type != EGL_WINDOW_BIT)
      return;

   ohos->sType = VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS;
   ohos->pNext = NULL;
   ohos->flags = 0;
   ohos->window = g_ohos_window;
   ci->has_alpha = false;            /* MC 主窗口不透明 */
   ci->present_opaque = true;
}

static const __DRIkopperLoaderExtension kopper_loader_extension = {
   .base = {__DRI_KOPPER_LOADER, 1},
   .SetSurfaceCreateInfo = kopperSetSurfaceCreateInfo,
};

/* sw/kopper loader 扩展集（zink 走 swrast loader 集 + kopper）。 */
static const __DRIextension *ohos_loader_extensions[] = {
   &image_lookup_extension.base,
   &use_invalidate.base,
   &kopper_loader_extension.base,
   NULL,
};

/* ---- surface ---- */
static _EGLSurface *
dri2_ohos_create_surface(_EGLDisplay *disp, EGLint type, _EGLConfig *conf,
                         void *native_window, const EGLint *attrib_list)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   struct dri2_egl_config *dri2_conf = dri2_egl_config(conf);
   struct dri2_egl_surface *dri2_surf;
   const struct dri_config *config;

   dri2_surf = calloc(1, sizeof *dri2_surf);
   if (!dri2_surf) {
      _eglError(EGL_BAD_ALLOC, "dri2_create_surface");
      return NULL;
   }

   if (!dri2_init_surface(&dri2_surf->base, disp, type, conf, attrib_list,
                          false, native_window))
      goto cleanup_surf;

   /* 存 OHNativeWindow*（kopperSetSurfaceCreateInfo 取用，MC 单窗口）。 */
   g_ohos_window = (OHNativeWindow *)native_window;

   /* 窗口尺寸：优先 EGL attrib（dri2_init_surface 已填），否则读 libglfw 设的 env。 */
   if (dri2_surf->base.Width <= 0 || dri2_surf->base.Height <= 0) {
      const char *ew = getenv("AMCL_WINDOW_WIDTH");
      const char *eh = getenv("AMCL_WINDOW_HEIGHT");
      dri2_surf->base.Width = ew ? atoi(ew) : 1280;
      dri2_surf->base.Height = eh ? atoi(eh) : 720;
   }

   config = dri2_get_dri_config(dri2_conf, type, dri2_surf->base.GLColorspace);
   if (!config) {
      _eglError(EGL_BAD_MATCH, "Unsupported surfacetype/colorspace configuration");
      goto cleanup_surf;
   }

   if (!dri2_create_drawable(dri2_dpy, config, dri2_surf, dri2_surf))
      goto cleanup_surf;

   return &dri2_surf->base;

cleanup_surf:
   free(dri2_surf);
   return NULL;
}

static _EGLSurface *
dri2_ohos_create_window_surface(_EGLDisplay *disp, _EGLConfig *conf,
                                void *native_window, const EGLint *attrib_list)
{
   return dri2_ohos_create_surface(disp, EGL_WINDOW_BIT, conf, native_window,
                                   attrib_list);
}

static _EGLSurface *
dri2_ohos_create_pbuffer_surface(_EGLDisplay *disp, _EGLConfig *conf,
                                 const EGLint *attrib_list)
{
   return dri2_ohos_create_surface(disp, EGL_PBUFFER_BIT, conf, NULL,
                                   attrib_list);
}

static EGLBoolean
dri2_ohos_destroy_surface(_EGLDisplay *disp, _EGLSurface *surf)
{
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(surf);

   driDestroyDrawable(dri2_surf->dri_drawable);
   dri2_fini_surface(surf);
   free(dri2_surf);
   return EGL_TRUE;
}

static EGLBoolean
dri2_ohos_swap_buffers(_EGLDisplay *disp, _EGLSurface *draw)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(draw);

   if (dri2_dpy->kopper) {
      kopperSwapBuffers(dri2_surf->dri_drawable,
                        __DRI2_FLUSH_INVALIDATE_ANCILLARY);
      return EGL_TRUE;
   }
   driSwapBuffers(dri2_surf->dri_drawable);
   return EGL_TRUE;
}

static const struct dri2_egl_display_vtbl dri2_ohos_display_vtbl = {
   .create_window_surface = dri2_ohos_create_window_surface,
   .create_pbuffer_surface = dri2_ohos_create_pbuffer_surface,
   .destroy_surface = dri2_ohos_destroy_surface,
   .create_image = dri2_create_image_khr,
   .swap_buffers = dri2_ohos_swap_buffers,
   .get_dri_drawable = dri2_surface_get_dri_drawable,
};

/* ---- configs ---- */
/* Mesa 自带的 dri2_add_pbuffer_configs_for_visuals 只给 config 标 EGL_PBUFFER_BIT，
 * 导致 eglChooseConfig(EGL_WINDOW_BIT) 返回 0 个匹配（真机实测 42 个 config 全是 st=0x1
 * pbuffer-only，eglCreateWindowSurface 报 EGL_BAD_MATCH）。OHOS 经 kopper 直呈现到
 * OHNativeWindow（窗口 surface），故所有 driver_config 都按【窗口 + pbuffer】登记。 */
static void
dri2_ohos_add_configs(_EGLDisplay *disp)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   const EGLint surface_type = EGL_WINDOW_BIT | EGL_PBUFFER_BIT;
   unsigned added = 0;

   for (unsigned i = 0; dri2_dpy->driver_configs[i] != NULL; i++) {
      if (dri2_add_config(disp, dri2_dpy->driver_configs[i], surface_type, NULL))
         added++;
   }

   if (!added)
      _eglLog(_EGL_WARNING, "OHOS: no EGL window configs added");
}

/* ---- 初始化：zink-sw（无 DRM node）---- */
EGLBoolean
dri2_initialize_ohos(_EGLDisplay *disp)
{
   const char *err;
   struct dri2_egl_display *dri2_dpy = dri2_display_create();
   if (!dri2_dpy)
      return EGL_FALSE;

   disp->DriverData = (void *)dri2_dpy;

   /* OHOS 无 DRM render node：用 zink（或 swrast）sw 路径，fd=-1。 */
   dri2_dpy->fd_render_gpu = -1;
   dri2_dpy->driver_name = strdup(disp->Options.Zink ? "zink" : "swrast");
   if (!dri2_dpy->driver_name) {
      err = "OHOS: strdup driver_name failed";
      goto cleanup;
   }

   if (!dri2_load_driver(disp)) {
      err = "OHOS: failed to load driver";
      goto cleanup;
   }

   dri2_dpy->loader_extensions = ohos_loader_extensions;
   dri2_dpy->fd_display_gpu = dri2_dpy->fd_render_gpu;

   if (!dri2_create_screen(disp)) {
      err = "OHOS: failed to create screen";
      goto cleanup;
   }

   dri2_setup_screen(disp);
   dri2_ohos_add_configs(disp);

   dri2_dpy->vtbl = &dri2_ohos_display_vtbl;
   return EGL_TRUE;

cleanup:
   dri2_display_destroy(disp);
   return _eglError(EGL_NOT_INITIALIZED, err);
}

/*
 * Copyright (c) 2022 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "egl_core.h"

#include <mutex>

#include "egl_defs.h"
#include "egl_pre_initializer.h"
#include "egl_wrapper_layer.h"
#include "egl_wrapper_loader.h"
#if USE_IGRAPHICS_EXTENDS_HOOKS
#include "egl_wrapper_hook.h"
#endif
#ifdef OPENGL_WRAPPER_ENABLE_GL4
#include "parameters.h"
#endif
#include "wrapper_log.h"

namespace {

#ifdef OPENGL_WRAPPER_ENABLE_GL4
bool CheckIfEnableOpengl()
{
    const char* needOpenglEnv = "NEED_OPENGL";
    const char* needOpenglEnvValue = getenv(needOpenglEnv);
    bool supportOpengl = OHOS::system::GetBoolParameter(OHOS::SUPPORT_GL_TO_VK, false);
    if (needOpenglEnvValue && std::string(needOpenglEnvValue) == "1" && supportOpengl) {
        return true;
    }
    WLOGI("Failed to get env NEED_OPENGL or the value of NEED_OPENGL is not 1");
    return false;
}
#endif
}

namespace OHOS {
EglWrapperDispatchTable gWrapperHook{};
GlHookTable gGlHookNoContext{};
#if USE_IGRAPHICS_EXTENDS_HOOKS
GlHookTable g_glHookCSDR;
GlHookTable g_glHookSingle;
#endif

#undef CALL_HOOK_API
#define CALL_HOOK_API(...)

#undef CALL_HOOK_API_RET
#define CALL_HOOK_API_RET CALL_HOOK_API

#undef HOOK_API_ENTRY
#define HOOK_API_ENTRY(r, api, ...) #api,

char const * const gWrapperApiNames[EGL_API_NUM] = {
#include "wrapper_hook_entries.in"
    nullptr
};

char const * const gEglApiNames[EGL_API_NUM] = {
#include "egl_hook_entries.in"
    nullptr
};

char const * const gGlApiNames1[GLES_API_NUM] = {
#include "gl1_hook_entries.in"
    nullptr
};

char const * const gGlApiNames2[GLES_API_NUM] = {
#include "gl2_hook_entries.in"
    nullptr
};

char const * const gGlApiNames3[GLES_API_NUM] = {
#include "gl3_hook_entries.in"
    nullptr
};
#ifdef OPENGL_WRAPPER_ENABLE_GL4
char const * const gGlApiNames4[OPENGL_API_NUM] = {
#include "gl4_hook_entries.in"
    nullptr
};
#endif
using namespace OHOS;

static std::mutex gInitMutex;
static EglPreInitializer preInitializer;

void WrapperHookTableInit() noexcept
{
    WLOGD("");
    char const * const *apiName = gWrapperApiNames;
    EglWrapperFuncPointer *curr = reinterpret_cast<EglWrapperFuncPointer*>(&gWrapperHook.wrapper);
    while (*apiName) {
        std::string name = *apiName;
        EglWrapperFuncPointer addr = FindEglWrapperApi(name);
        if (addr == nullptr) {
            WLOGW("No addr found in wrapper entries lookup table for %{public}s", *apiName);
        }
        *curr++ = addr;
        apiName++;
    }
}

bool EglCoreInit()
{
    std::lock_guard<std::mutex> lock(gInitMutex);

    if (gWrapperHook.isLoad) {
        return true;
    }

    if (!preInitializer.InitStat()) {
        WLOGE("preInit Error.");
        return false;
    }

#ifdef OPENGL_WRAPPER_ENABLE_GL4
    gWrapperHook.useMesa = CheckIfEnableOpengl();
    if (gWrapperHook.useMesa) {
        ThreadPrivateDataCtl::SetGlHookTable(&OHOS::gWrapperHook.gl);
        EglWrapperLoader& loader(EglWrapperLoader::GetInstance());
        if (!loader.Load(&gWrapperHook)) {
            WLOGE("EglWrapperLoader Load Failed.");
            return false;
        }
        return true;
    }
#endif

    WrapperHookTableInit();
    EglWrapperLoader& loader(EglWrapperLoader::GetInstance());
    if (!loader.Load(&gWrapperHook)) {
        WLOGE("EglWrapperLoader Load Failed.");
        return false;
    }

    EglWrapperLayer& layer(EglWrapperLayer::GetInstance());
    if (!layer.Init(&gWrapperHook)) {
        WLOGE("EglWrapperLayer Init Failed.");
    }

#if USE_IGRAPHICS_EXTENDS_HOOKS
    if (!layer.GetIGraphicsLogicStatus()) {
        return true;
    }

    EglWrapperHook& hookLayer(EglWrapperHook::GetInstance());
    if (!hookLayer.Hook(&gWrapperHook)) {
        WLOGE("EglWrapperHookLayer init Failed!");
    } else {
        WLOGI("EglWrapperHookLayer init Success!");
    }
#endif
    return true;
}
}; // namespace OHOS

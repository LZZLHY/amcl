/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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
#include <map>
#include <string>

#include "egl_defs.h"
#include "egl_wrapper_display.h"
#include "egl_wrapper_entry.h"
#include "egl_wrapper_loader.h"
#include "parameters.h"
#include "wrapper_log.h"
using namespace OHOS;
#ifdef OPENGL_WRAPPER_ENABLE_GL4
EGLBoolean OHGraphicsQueryGLImpl(void)
{
    bool supportOpengl = OHOS::system::GetBoolParameter(OHOS::SUPPORT_GL_TO_VK, false);
    return supportOpengl ? EGL_TRUE : EGL_FALSE;
}

__eglMustCastToProperFunctionPointerType EglGetProcAddressCustomImpl(const char* procname)
{
    void* func = nullptr;
    if (OHOS::gGetProcAddress && OHOS::gGetProcAddress != &EglGetProcAddressCustomImpl) {
        func = reinterpret_cast<void *>(OHOS::gGetProcAddress(procname));
    }

    if (func) {
        return __eglMustCastToProperFunctionPointerType(func);
    }

    if (auto it = OHOS::gCustomMap.find(procname); it != OHOS::gCustomMap.end()) {
        return __eglMustCastToProperFunctionPointerType(it->second);
    }
    WLOGD("EglGetProcAddressCustomImpl did not find an entry for %{public}s", procname);
    return nullptr;
}

PFNEGLGETPROCADDRESSPROC OHOS::gGetProcAddress = &EglGetProcAddressCustomImpl;
#endif

// LCOV_EXCL_START
EGLBoolean EglSetEngineNameImpl(EGLDisplay dpy, const char* name)
{
    ThreadPrivateDataCtl::ClearError();
    if (name == nullptr) {
        WLOGE("eglSetEngineName name is nullptr.");
        ThreadPrivateDataCtl::SetError(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    EglWrapperDisplay *display = EglWrapperDisplay::GetWrapperDisplay(dpy);
    if (!display) {
        WLOGE("display is bad");
        ThreadPrivateDataCtl::SetError(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }

    if (!display->IsReady()) {
        WLOGE("display is not initialized.");
        ThreadPrivateDataCtl::SetError(EGL_NOT_INITIALIZED);
        return EGL_FALSE;
    }
 
    typedef EGLBoolean (*FunPtr)(EGLDisplay dpy, const char* name);
    FunPtr func = nullptr;
    if (gWrapperHook.isLoad && gWrapperHook.egl.eglGetProcAddress) {
        func = reinterpret_cast<FunPtr>(
            gWrapperHook.egl.eglGetProcAddress("eglSetEngineName"));
    }

    if (!func) {
        WLOGE("eglSetEngineName not supported in current driver");
        return EGL_FALSE;
    }
    
    return func(display->GetEglDisplay(), name);
}
// LCOV_EXCL_STOP

const std::map<std::string, EglWrapperFuncPointer> OHOS::gCustomMap = {
#ifdef OPENGL_WRAPPER_ENABLE_GL4
     // OH_Graphics_QueryGL
     { "OH_Graphics_QueryGL", (EglWrapperFuncPointer)&OHGraphicsQueryGLImpl },
#endif
     // GPU DFX to add name tag for third party engine
     { "eglSetEngineName", (EglWrapperFuncPointer)&EglSetEngineNameImpl },
};
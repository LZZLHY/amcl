#include <imgui_ImGuiPlatformIO.h>

//@line:81

        #include "_common.h"

        #define IMGUI_PLATFORM_IO ((ImGuiPlatformIO*)STRUCT_PTR)

        jobject jTmpViewport = NULL;
        jobject jTmpImVec2 = NULL;
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_nInit(JNIEnv* env, jclass clazz, jobject tmpViewport, jobject tmpImVec2) {


//@line:94

        jTmpViewport = env->NewGlobalRef(tmpViewport);
        jTmpImVec2 = env->NewGlobalRef(tmpImVec2);
    

}


//@line:99

        #define IM_PLATFORM_FUNC_VIEWPORT_TMPL(name)\
            jobject platformCallback##name = NULL;\
            void PlatformStub##name(ImGuiViewport* vp) {\
                if (platformCallback##name != NULL) {\
                    JNIEnv* env = Jni::GetEnv();\
                    env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);\
                    Jni::CallImPlatformFuncViewport(env, platformCallback##name, jTmpViewport);\
                }\
            }\
            void PlatformStub##name(ImGuiViewport* vp, void*) {\
                PlatformStub##name(vp);\
            }

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(CreateWindow)

        #define IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(name)\
            if (platformCallback##name != NULL) {\
                env->DeleteGlobalRef(platformCallback##name);\
            }\
            platformCallback##name = env->NewGlobalRef(func);\
            IMGUI_PLATFORM_IO->Platform_##name = PlatformStub##name;
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformCreateWindow(JNIEnv* env, jobject object, jobject func) {


//@line:126

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(CreateWindow)
    

}


//@line:130

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(DestroyWindow)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformDestroyWindow(JNIEnv* env, jobject object, jobject func) {


//@line:137

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(DestroyWindow)
    

}


//@line:141

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(ShowWindow)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformShowWindow(JNIEnv* env, jobject object, jobject func) {


//@line:148

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(ShowWindow)
    

}


//@line:152

        #define IM_PLATFORM_FUNC_VIEWPORT_IM_VEC2_TMPL(name)\
            jobject platformCallback##name = NULL;\
            void PlatformStub##name(ImGuiViewport* vp, ImVec2 pos) {\
                if (platformCallback##name != NULL) {\
                    JNIEnv* env = Jni::GetEnv();\
                    env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);\
                    Jni::ImVec2Cpy(env, pos, jTmpImVec2);\
                    Jni::CallImPlatformFuncViewportImVec2(env, platformCallback##name, jTmpViewport, jTmpImVec2);\
                }\
            }

        IM_PLATFORM_FUNC_VIEWPORT_IM_VEC2_TMPL(SetWindowPos)

        #define IM_PLATFORM_FUNC_VIEWPORT_IM_VEC2_METHOD_TMPL(name)\
            if (platformCallback##name != NULL) {\
                env->DeleteGlobalRef(platformCallback##name);\
            }\
            platformCallback##name = env->NewGlobalRef(func);\
            IMGUI_PLATFORM_IO->Platform_##name = PlatformStub##name;
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformSetWindowPos(JNIEnv* env, jobject object, jobject func) {


//@line:177

        IM_PLATFORM_FUNC_VIEWPORT_IM_VEC2_METHOD_TMPL(SetWindowPos)
    

}


//@line:181

        #define IM_PLATFORM_FUNC_VIEWPORT_SUPP_IM_VEC2_TMPL(name)\
            jobject platformCallback##name = NULL;\
            ImVec2 PlatformStub##name(ImGuiViewport* vp) {\
                ImVec2 dst;\
                if (platformCallback##name != NULL) {\
                    JNIEnv* env = Jni::GetEnv();\
                    env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);\
                    Jni::CallImPlatformFuncViewportSuppImVec2(env, platformCallback##name, jTmpViewport, jTmpImVec2);\
                    Jni::ImVec2Cpy(env, jTmpImVec2, &dst);\
                }\
                return dst;\
            }

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_IM_VEC2_TMPL(GetWindowPos)

        #define IM_PLATFORM_FUNC_VIEWPORT_SUPP_IM_VEC2_METHOD_TMPL(name)\
            if (platformCallback##name != NULL) {\
                env->DeleteGlobalRef(platformCallback##name);\
            }\
            platformCallback##name = env->NewGlobalRef(func);\
            IMGUI_PLATFORM_IO->Platform_##name = PlatformStub##name;
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformGetWindowPos(JNIEnv* env, jobject object, jobject func) {


//@line:208

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_IM_VEC2_METHOD_TMPL(GetWindowPos)
    

}


//@line:212

        IM_PLATFORM_FUNC_VIEWPORT_IM_VEC2_TMPL(SetWindowSize)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformSetWindowSize(JNIEnv* env, jobject object, jobject func) {


//@line:219

        IM_PLATFORM_FUNC_VIEWPORT_IM_VEC2_METHOD_TMPL(SetWindowSize)
    

}


//@line:223

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_IM_VEC2_TMPL(GetWindowSize)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformGetWindowSize(JNIEnv* env, jobject object, jobject func) {


//@line:230

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_IM_VEC2_METHOD_TMPL(GetWindowSize)
    

}


//@line:234

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(SetWindowFocus)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformSetWindowFocus(JNIEnv* env, jobject object, jobject func) {


//@line:241

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(SetWindowFocus)
    

}


//@line:245

        #define IM_PLATFORM_FUNC_VIEWPORT_SUPP_BOOLEAN_TMPL(name)\
            jobject platformCallback##name = NULL;\
            bool PlatformStub##name(ImGuiViewport* vp) {\
                if (platformCallback##name != NULL) {\
                    JNIEnv* env = Jni::GetEnv();\
                    env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);\
                    return Jni::CallImPlatformFuncViewportSuppBoolean(env, platformCallback##name, jTmpViewport);\
                }\
                return false;\
            }

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_BOOLEAN_TMPL(GetWindowFocus)

        #define IM_PLATFORM_FUNC_VIEWPORT_SUPP_BOOLEAN_METHOD_TMPL(name)\
            if (platformCallback##name != NULL) {\
                env->DeleteGlobalRef(platformCallback##name);\
            }\
            platformCallback##name = env->NewGlobalRef(func);\
            IMGUI_PLATFORM_IO->Platform_##name = PlatformStub##name;
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformGetWindowFocus(JNIEnv* env, jobject object, jobject func) {


//@line:270

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_BOOLEAN_METHOD_TMPL(GetWindowFocus)
    

}


//@line:274

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_BOOLEAN_TMPL(GetWindowMinimized)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformGetWindowMinimized(JNIEnv* env, jobject object, jobject func) {


//@line:281

        IM_PLATFORM_FUNC_VIEWPORT_SUPP_BOOLEAN_METHOD_TMPL(GetWindowMinimized)
    

}


//@line:285

        jobject platformCallbackSetWindowTitle = NULL;
        void PlatformStubSetWindowTitle(ImGuiViewport* vp, const char* str) {
            if (platformCallbackSetWindowTitle != NULL) {
                JNIEnv* env = Jni::GetEnv();
                env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);
                Jni::CallImPlatformFuncViewportString(env, platformCallbackSetWindowTitle, jTmpViewport, str);
            }
        }
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformSetWindowTitle(JNIEnv* env, jobject object, jobject func) {


//@line:299

        if (platformCallbackSetWindowTitle != NULL) {
            env->DeleteGlobalRef(platformCallbackSetWindowTitle);
        }
        platformCallbackSetWindowTitle = env->NewGlobalRef(func);
        IMGUI_PLATFORM_IO->Platform_SetWindowTitle = PlatformStubSetWindowTitle;
    

}


//@line:307

        jobject platformCallbackSetWindowAlpha = NULL;
        void PlatformStubSetWindowAlpha(ImGuiViewport* vp, float alpha) {
            if (platformCallbackSetWindowAlpha != NULL) {
                JNIEnv* env = Jni::GetEnv();
                env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);
                Jni::CallImPlatformFuncViewportFloat(env, platformCallbackSetWindowAlpha, jTmpViewport, alpha);
            }
        }
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformSetWindowAlpha(JNIEnv* env, jobject object, jobject func) {


//@line:321

        if (platformCallbackSetWindowAlpha != NULL) {
            env->DeleteGlobalRef(platformCallbackSetWindowAlpha);
        }
        platformCallbackSetWindowAlpha = env->NewGlobalRef(func);
        IMGUI_PLATFORM_IO->Platform_SetWindowAlpha = PlatformStubSetWindowAlpha;
    

}


//@line:329

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(UpdateWindow)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformUpdateWindow(JNIEnv* env, jobject object, jobject func) {


//@line:336

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(UpdateWindow)
    

}


//@line:340

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(RenderWindow)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformRenderWindow(JNIEnv* env, jobject object, jobject func) {


//@line:347

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(RenderWindow)
    

}


//@line:351

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(SwapBuffers)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformSwapBuffers(JNIEnv* env, jobject object, jobject func) {


//@line:358

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(SwapBuffers)
    

}


//@line:362

        jobject platformCallbackGetWindowDpiScale = NULL;
        float PlatformStubGetWindowDpiScale(ImGuiViewport* vp) {
            if (platformCallbackGetWindowDpiScale != NULL) {
                JNIEnv* env = Jni::GetEnv();
                env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);
                return Jni::CallImPlatformFuncViewportSuppFloat(env, platformCallbackGetWindowDpiScale, jTmpViewport);
            }
            return false;
        }
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformGetWindowDpiScale(JNIEnv* env, jobject object, jobject func) {


//@line:377

         if (platformCallbackGetWindowDpiScale != NULL) {
            env->DeleteGlobalRef(platformCallbackGetWindowDpiScale);
        }
        platformCallbackGetWindowDpiScale = env->NewGlobalRef(func);
        IMGUI_PLATFORM_IO->Platform_GetWindowDpiScale = PlatformStubGetWindowDpiScale;
    

}


//@line:385

        IM_PLATFORM_FUNC_VIEWPORT_TMPL(OnChangedViewport)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setPlatformOnChangedViewport(JNIEnv* env, jobject object, jobject func) {


//@line:392

        IM_PLATFORM_FUNC_VIEWPORT_METHOD_TMPL(OnChangedViewport)
    

}


//@line:398

        #define IM_RENDERER_FUNC_VIEWPORT_TMPL(name)\
            jobject rendererCallback##name = NULL;\
            void RendererStub##name(ImGuiViewport* vp) {\
                if (rendererCallback##name != NULL) {\
                    JNIEnv* env = Jni::GetEnv();\
                    env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);\
                    Jni::CallImPlatformFuncViewport(env, rendererCallback##name, jTmpViewport);\
                }\
            }\
            void RendererStub##name(ImGuiViewport* vp, void*) {\
                RendererStub##name(vp);\
            }

        IM_RENDERER_FUNC_VIEWPORT_TMPL(CreateWindow)

        #define IM_RENDERER_FUNC_VIEWPORT_METHOD_TMPL(name)\
            if (rendererCallback##name != NULL) {\
                env->DeleteGlobalRef(rendererCallback##name);\
            }\
            rendererCallback##name = env->NewGlobalRef(func);\
            IMGUI_PLATFORM_IO->Renderer_##name = RendererStub##name;
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setRendererCreateWindow(JNIEnv* env, jobject object, jobject func) {


//@line:425

        IM_RENDERER_FUNC_VIEWPORT_METHOD_TMPL(CreateWindow)
    

}


//@line:429

        IM_RENDERER_FUNC_VIEWPORT_TMPL(DestroyWindow)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setRendererDestroyWindow(JNIEnv* env, jobject object, jobject func) {


//@line:436

        IM_RENDERER_FUNC_VIEWPORT_METHOD_TMPL(DestroyWindow)
    

}


//@line:440

        jobject rendererCallbackSetWindowSize = NULL;
        void RendererStubSetWindowSize(ImGuiViewport* vp, ImVec2 pos) {
            if (rendererCallbackSetWindowSize != NULL) {
                JNIEnv* env = Jni::GetEnv();
                env->SetLongField(jTmpViewport, Jni::GetBindingStructPtrID(), (intptr_t)vp);
                Jni::ImVec2Cpy(env, pos, jTmpImVec2);
                Jni::CallImPlatformFuncViewportImVec2(env, rendererCallbackSetWindowSize, jTmpViewport, jTmpImVec2);
            }
        }
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setRendererSetWindowPos(JNIEnv* env, jobject object, jobject func) {


//@line:455

        if (rendererCallbackSetWindowSize != NULL) {
            env->DeleteGlobalRef(rendererCallbackSetWindowSize);
        }
        rendererCallbackSetWindowSize = env->NewGlobalRef(func);
        IMGUI_PLATFORM_IO->Renderer_SetWindowSize = RendererStubSetWindowSize;
    

}


//@line:463

        IM_RENDERER_FUNC_VIEWPORT_TMPL(RenderWindow)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setRendererRenderWindow(JNIEnv* env, jobject object, jobject func) {


//@line:471

        IM_RENDERER_FUNC_VIEWPORT_METHOD_TMPL(RenderWindow)
    

}


//@line:475

        IM_RENDERER_FUNC_VIEWPORT_TMPL(SwapBuffers)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_setRendererSwapBuffers(JNIEnv* env, jobject object, jobject func) {


//@line:482

        IM_RENDERER_FUNC_VIEWPORT_METHOD_TMPL(SwapBuffers)
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_resizeMonitors(JNIEnv* env, jobject object, jint size) {


//@line:494

        IMGUI_PLATFORM_IO->Monitors.resize(0);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiPlatformIO_getMonitorsSize(JNIEnv* env, jobject object) {


//@line:498

        return IMGUI_PLATFORM_IO->Monitors.Size;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformIO_pushMonitors(JNIEnv* env, jobject object, jfloat mainPosX, jfloat mainPosY, jfloat mainSizeX, jfloat mainSizeY, jfloat workPosX, jfloat workPosY, jfloat workSizeX, jfloat workSizeY, jfloat dpiScale) {


//@line:502

        ImGuiPlatformMonitor monitor;

        monitor.MainPos = ImVec2(mainPosX, mainPosY);
        monitor.MainSize = ImVec2(mainSizeX, mainSizeY);

        monitor.WorkPos = ImVec2(workPosX, workPosY);
        monitor.WorkSize = ImVec2(workSizeX, workSizeY);

        monitor.DpiScale = dpiScale;

        IMGUI_PLATFORM_IO->Monitors.push_back(monitor);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGuiPlatformIO_nGetMonitors(JNIEnv* env, jobject object, jint idx) {


//@line:521

        return (intptr_t)&IMGUI_PLATFORM_IO->Monitors[idx];
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiPlatformIO_getViewportsSize(JNIEnv* env, jobject object) {


//@line:528

        return IMGUI_PLATFORM_IO->Viewports.Size;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGuiPlatformIO_nGetViewports(JNIEnv* env, jobject object, jint idx) {


//@line:537

        return (intptr_t)IMGUI_PLATFORM_IO->Viewports[idx];
    

}


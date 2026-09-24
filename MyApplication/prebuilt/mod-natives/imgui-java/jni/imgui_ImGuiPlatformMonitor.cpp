#include <imgui_ImGuiPlatformMonitor.h>

//@line:14

        #include "_common.h"

        #define IMGUI_PLATFORM_MONITOR ((ImGuiPlatformMonitor*)STRUCT_PTR)
     JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_getMainPos(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:23

        Jni::ImVec2Cpy(env, &IMGUI_PLATFORM_MONITOR->MainPos, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getMainPosX(JNIEnv* env, jobject object) {


//@line:30

        return IMGUI_PLATFORM_MONITOR->MainPos.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getMainPosY(JNIEnv* env, jobject object) {


//@line:37

        return IMGUI_PLATFORM_MONITOR->MainPos.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_setMainPos(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:41

        IMGUI_PLATFORM_MONITOR->MainPos = ImVec2(x, y);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_getMainSize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:48

        Jni::ImVec2Cpy(env, &IMGUI_PLATFORM_MONITOR->MainSize, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getMainSizeX(JNIEnv* env, jobject object) {


//@line:55

        return IMGUI_PLATFORM_MONITOR->MainSize.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getMainSizeY(JNIEnv* env, jobject object) {


//@line:62

        return IMGUI_PLATFORM_MONITOR->MainSize.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_setMainSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:69

        IMGUI_PLATFORM_MONITOR->MainSize = ImVec2(x, y);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_getWorkPos(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:77

        Jni::ImVec2Cpy(env, &IMGUI_PLATFORM_MONITOR->WorkPos, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getWorkPosX(JNIEnv* env, jobject object) {


//@line:85

        return IMGUI_PLATFORM_MONITOR->WorkPos.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getWorkPosY(JNIEnv* env, jobject object) {


//@line:93

        return IMGUI_PLATFORM_MONITOR->WorkPos.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_setWorkPos(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:101

        IMGUI_PLATFORM_MONITOR->WorkPos = ImVec2(x, y);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_getWorkSize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:109

        Jni::ImVec2Cpy(env, &IMGUI_PLATFORM_MONITOR->WorkSize, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getWorkSizeX(JNIEnv* env, jobject object) {


//@line:117

        return IMGUI_PLATFORM_MONITOR->WorkSize.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getWorkSizeY(JNIEnv* env, jobject object) {


//@line:125

        return IMGUI_PLATFORM_MONITOR->WorkSize.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_setWorkSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:133

        IMGUI_PLATFORM_MONITOR->WorkSize = ImVec2(x, y);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiPlatformMonitor_getDpiScale(JNIEnv* env, jobject object) {


//@line:140

        return IMGUI_PLATFORM_MONITOR->DpiScale;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiPlatformMonitor_setDpiScale(JNIEnv* env, jobject object, jfloat dpiScale) {


//@line:147

        IMGUI_PLATFORM_MONITOR->DpiScale = dpiScale;
    

}


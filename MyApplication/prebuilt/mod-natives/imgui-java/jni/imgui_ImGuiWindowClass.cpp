#include <imgui_ImGuiWindowClass.h>

//@line:22

        #include "_common.h"

        #define IMGUI_WINDOW_CLASS ((ImGuiWindowClass*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_ImGuiWindowClass_nCreate(JNIEnv* env, jobject object) {


//@line:33

        return (intptr_t)(new ImGuiWindowClass());
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiWindowClass_geClassId(JNIEnv* env, jobject object) {


//@line:40

        return IMGUI_WINDOW_CLASS->ClassId;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setClassId(JNIEnv* env, jobject object, jint classId) {


//@line:47

        IMGUI_WINDOW_CLASS->ClassId = classId;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiWindowClass_getParentViewportId(JNIEnv* env, jobject object) {


//@line:55

        return IMGUI_WINDOW_CLASS->ParentViewportId;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setParentViewportId(JNIEnv* env, jobject object, jint parentViewportId) {


//@line:63

        IMGUI_WINDOW_CLASS->ParentViewportId = parentViewportId;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiWindowClass_getViewportFlagsOverrideSet(JNIEnv* env, jobject object) {


//@line:71

        return IMGUI_WINDOW_CLASS->ViewportFlagsOverrideSet;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setViewportFlagsOverrideSet(JNIEnv* env, jobject object, jint viewportFlagsOverrideSet) {


//@line:79

        IMGUI_WINDOW_CLASS->ViewportFlagsOverrideSet = viewportFlagsOverrideSet;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiWindowClass_getViewportFlagsOverrideClear(JNIEnv* env, jobject object) {


//@line:87

        return IMGUI_WINDOW_CLASS->ViewportFlagsOverrideClear;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setViewportFlagsOverrideClear(JNIEnv* env, jobject object, jint viewportFlagsOverrideClear) {


//@line:95

        IMGUI_WINDOW_CLASS->ViewportFlagsOverrideClear = viewportFlagsOverrideClear;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiWindowClass_getTabItemFlagsOverrideSet(JNIEnv* env, jobject object) {


//@line:103

        return IMGUI_WINDOW_CLASS->TabItemFlagsOverrideSet;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setTabItemFlagsOverrideSet(JNIEnv* env, jobject object, jint tabItemFlagsOverrideSet) {


//@line:111

        IMGUI_WINDOW_CLASS->TabItemFlagsOverrideSet = tabItemFlagsOverrideSet;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiWindowClass_getDockNodeFlagsOverrideSet(JNIEnv* env, jobject object) {


//@line:118

        return IMGUI_WINDOW_CLASS->DockNodeFlagsOverrideSet;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setDockNodeFlagsOverrideSet(JNIEnv* env, jobject object, jint dockNodeFlagsOverrideSet) {


//@line:125

        IMGUI_WINDOW_CLASS->DockNodeFlagsOverrideSet = dockNodeFlagsOverrideSet;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiWindowClass_getDockingAlwaysTabBar(JNIEnv* env, jobject object) {


//@line:154

        return IMGUI_WINDOW_CLASS->DockingAlwaysTabBar;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setDockingAlwaysTabBar(JNIEnv* env, jobject object, jboolean dockingAlwaysTabBar) {


//@line:162

        IMGUI_WINDOW_CLASS->DockingAlwaysTabBar = dockingAlwaysTabBar;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiWindowClass_getDockingAllowUnclassed(JNIEnv* env, jobject object) {


//@line:169

        return IMGUI_WINDOW_CLASS->DockingAllowUnclassed;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiWindowClass_setDockingAllowUnclassed(JNIEnv* env, jobject object, jboolean dockingAllowUnclassed) {


//@line:176

        IMGUI_WINDOW_CLASS->DockingAllowUnclassed = dockingAllowUnclassed;
    

}


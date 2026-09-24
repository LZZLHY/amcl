#include <imgui_internal_ImGuiWindow.h>

//@line:10

        #include "_common.h"
        #include <imgui_internal.h>

        #define IMGUI_WINDOW ((ImGuiWindow*)STRUCT_PTR)
     JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiWindow_isScrollbarX(JNIEnv* env, jobject object) {


//@line:20

       return IMGUI_WINDOW->ScrollbarX;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGuiWindow_isScrollbarY(JNIEnv* env, jobject object) {


//@line:27

       return IMGUI_WINDOW->ScrollbarY;
    

}


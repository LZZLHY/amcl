#include <imgui_ImGuiListClipper.h>

//@line:40

        #include "_common.h"
     JNIEXPORT void JNICALL Java_imgui_ImGuiListClipper_forEach(JNIEnv* env, jclass clazz, jint itemsCount, jint itemsHeight, jobject callback) {


//@line:60

        ImGuiListClipper clipper;
        clipper.Begin(itemsCount, itemsHeight);
        while (clipper.Step()) {
            for (int i = clipper.DisplayStart; i < clipper.DisplayEnd; i++) {
                Jni::CallImListClipperCallback(env, callback, i);
            }
        }
    

}


#include <imgui_binding_ImGuiStructDestroyable.h>
JNIEXPORT void JNICALL Java_imgui_binding_ImGuiStructDestroyable_nDestroy(JNIEnv* env, jobject object, jlong ptr) {


//@line:28

        delete (void*)ptr;
    

}


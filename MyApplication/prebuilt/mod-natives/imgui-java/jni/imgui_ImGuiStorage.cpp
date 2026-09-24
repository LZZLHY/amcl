#include <imgui_ImGuiStorage.h>

//@line:23

        #include "_common.h"

        #define IMGUI_STORAGE ((ImGuiStorage*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_ImGuiStorage_nCreate(JNIEnv* env, jobject object) {


//@line:34

        return (intptr_t)(new ImGuiStorage());
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStorage_clear(JNIEnv* env, jobject object) {


//@line:42

        IMGUI_STORAGE->Clear();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiStorage_getInt__I(JNIEnv* env, jobject object, jint imGuiID) {


//@line:46

        return IMGUI_STORAGE->GetInt(imGuiID);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiStorage_getInt__II(JNIEnv* env, jobject object, jint imGuiID, jint defaultVal) {


//@line:50

        return IMGUI_STORAGE->GetInt(imGuiID, defaultVal);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStorage_setInt(JNIEnv* env, jobject object, jint imGuiID, jint val) {


//@line:54

        IMGUI_STORAGE->SetInt(imGuiID, val);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiStorage_getBool__I(JNIEnv* env, jobject object, jint imGuiID) {


//@line:58

        return IMGUI_STORAGE->GetBool(imGuiID);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiStorage_getBool__IZ(JNIEnv* env, jobject object, jint imGuiID, jboolean defaultVal) {


//@line:62

        return IMGUI_STORAGE->GetBool(imGuiID, defaultVal);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStorage_setBool(JNIEnv* env, jobject object, jint imGuiID, jboolean val) {


//@line:66

        IMGUI_STORAGE->SetBool(imGuiID, val);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStorage_getFloat__I(JNIEnv* env, jobject object, jint imGuiID) {


//@line:70

        return IMGUI_STORAGE->GetFloat(imGuiID);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiStorage_getFloat__IF(JNIEnv* env, jobject object, jint imGuiID, jfloat defaultVal) {


//@line:74

        return IMGUI_STORAGE->GetFloat(imGuiID, defaultVal);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStorage_setFloat(JNIEnv* env, jobject object, jint imGuiID, jfloat val) {


//@line:78

        IMGUI_STORAGE->SetFloat(imGuiID, val);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStorage_setAllInt(JNIEnv* env, jobject object, jint val) {


//@line:85

        IMGUI_STORAGE->SetAllInt(val);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiStorage_buildSortByKey(JNIEnv* env, jobject object) {


//@line:92

        IMGUI_STORAGE->BuildSortByKey();
    

}


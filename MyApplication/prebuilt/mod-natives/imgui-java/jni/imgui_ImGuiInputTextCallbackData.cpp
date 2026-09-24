#include <imgui_ImGuiInputTextCallbackData.h>

//@line:21

        #include "_common.h"

        #define IMGUI_CALLBACK_DATA ((ImGuiInputTextCallbackData*)STRUCT_PTR)
     JNIEXPORT jint JNICALL Java_imgui_ImGuiInputTextCallbackData_getEventFlag(JNIEnv* env, jobject object) {


//@line:32

        return IMGUI_CALLBACK_DATA->EventFlag;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiInputTextCallbackData_getFlags(JNIEnv* env, jobject object) {


//@line:41

        return IMGUI_CALLBACK_DATA->Flags;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiInputTextCallbackData_getEventChar(JNIEnv* env, jobject object) {


//@line:50

        return IMGUI_CALLBACK_DATA->EventChar;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiInputTextCallbackData_setEventChar(JNIEnv* env, jobject object, jint c) {


//@line:68

        IMGUI_CALLBACK_DATA->EventChar = c;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiInputTextCallbackData_getEventKey(JNIEnv* env, jobject object) {


//@line:77

        return IMGUI_CALLBACK_DATA->EventKey;
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGuiInputTextCallbackData_getBuf(JNIEnv* env, jobject object) {


//@line:87

        return env->NewStringUTF(IMGUI_CALLBACK_DATA->Buf);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiInputTextCallbackData_getBufDirty(JNIEnv* env, jobject object) {


//@line:96

        return IMGUI_CALLBACK_DATA->BufDirty;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiInputTextCallbackData_setBufDirty(JNIEnv* env, jobject object, jboolean dirty) {


//@line:105

        IMGUI_CALLBACK_DATA->BufDirty = dirty;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiInputTextCallbackData_getCursorPos(JNIEnv* env, jobject object) {


//@line:114

        return IMGUI_CALLBACK_DATA->CursorPos;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiInputTextCallbackData_setCursorPos(JNIEnv* env, jobject object, jint pos) {


//@line:123

        IMGUI_CALLBACK_DATA->CursorPos = pos;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiInputTextCallbackData_getSelectionStart(JNIEnv* env, jobject object) {


//@line:132

        return IMGUI_CALLBACK_DATA->SelectionStart;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiInputTextCallbackData_setSelectionStart(JNIEnv* env, jobject object, jint pos) {


//@line:141

        IMGUI_CALLBACK_DATA->SelectionStart = pos;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiInputTextCallbackData_getSelectionEnd(JNIEnv* env, jobject object) {


//@line:150

        return IMGUI_CALLBACK_DATA->SelectionEnd;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiInputTextCallbackData_setSelectionEnd(JNIEnv* env, jobject object, jint pos) {


//@line:159

        IMGUI_CALLBACK_DATA->SelectionEnd = pos;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiInputTextCallbackData_deleteChars(JNIEnv* env, jobject object, jint pos, jint bytesCount) {


//@line:169

        IMGUI_CALLBACK_DATA->DeleteChars(pos, bytesCount);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiInputTextCallbackData_insertChars(JNIEnv* env, jobject object, jint pos, jstring obj_str) {
	char* str = (char*)env->GetStringUTFChars(obj_str, 0);


//@line:179

        IMGUI_CALLBACK_DATA->InsertChars(pos, str);
    
	env->ReleaseStringUTFChars(obj_str, str);

}


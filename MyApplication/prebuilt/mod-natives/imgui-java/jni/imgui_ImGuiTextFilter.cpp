#include <imgui_ImGuiTextFilter.h>

//@line:21

        #include "_common.h"

        #define IMGUI_TEXT_FILTER ((ImGuiTextFilter*)STRUCT_PTR)
     static inline jlong wrapped_Java_imgui_ImGuiTextFilter_nCreate
(JNIEnv* env, jobject object, jstring obj_defaultFilter, char* defaultFilter) {

//@line:32

        return (intptr_t)(new ImGuiTextFilter(defaultFilter));
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImGuiTextFilter_nCreate(JNIEnv* env, jobject object, jstring obj_defaultFilter) {
	char* defaultFilter = (char*)env->GetStringUTFChars(obj_defaultFilter, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImGuiTextFilter_nCreate(env, object, obj_defaultFilter, defaultFilter);

	env->ReleaseStringUTFChars(obj_defaultFilter, defaultFilter);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGuiTextFilter_draw
(JNIEnv* env, jobject object, jstring obj_label, jfloat width, char* label) {

//@line:44

        return IMGUI_TEXT_FILTER->Draw(label, width);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiTextFilter_draw(JNIEnv* env, jobject object, jstring obj_label, jfloat width) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGuiTextFilter_draw(env, object, obj_label, width, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGuiTextFilter_passFilter
(JNIEnv* env, jobject object, jstring obj_text, char* text) {

//@line:48

        return IMGUI_TEXT_FILTER->PassFilter(text);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiTextFilter_passFilter(JNIEnv* env, jobject object, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGuiTextFilter_passFilter(env, object, obj_text, text);

	env->ReleaseStringUTFChars(obj_text, text);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGuiTextFilter_build(JNIEnv* env, jobject object) {


//@line:52

        IMGUI_TEXT_FILTER->Build();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiTextFilter_clear(JNIEnv* env, jobject object) {


//@line:56

        IMGUI_TEXT_FILTER->Clear();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiTextFilter_isActive(JNIEnv* env, jobject object) {


//@line:60

        return IMGUI_TEXT_FILTER->IsActive();
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGuiTextFilter_getInputBuffer(JNIEnv* env, jobject object) {


//@line:64

        return env->NewStringUTF(IMGUI_TEXT_FILTER->InputBuf);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiTextFilter_setInputBuffer(JNIEnv* env, jobject object, jstring obj_inputBuffer) {
	char* inputBuffer = (char*)env->GetStringUTFChars(obj_inputBuffer, 0);


//@line:68

        strncpy(IMGUI_TEXT_FILTER->InputBuf, inputBuffer, sizeof(IMGUI_TEXT_FILTER->InputBuf));
    
	env->ReleaseStringUTFChars(obj_inputBuffer, inputBuffer);

}


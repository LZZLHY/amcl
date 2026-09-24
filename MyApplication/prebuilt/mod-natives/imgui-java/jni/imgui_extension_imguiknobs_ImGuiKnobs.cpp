#include <imgui_extension_imguiknobs_ImGuiKnobs.h>

//@line:16

        #include "_imguiknobs.h"
    static inline jboolean wrapped_Java_imgui_extension_imguiknobs_ImGuiKnobs_nKnob
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_pValue, jfloat minValue, jfloat maxValue, jfloat speed, jstring obj_format, jint variant, jfloat size, jint flags, jint steps, char* label, char* format, float* pValue) {

//@line:39

    return ImGuiKnobs::Knob(label, pValue, minValue, maxValue, speed, format, (ImGuiKnobVariant)variant, size, (ImGuiKnobFlags)flags, steps);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguiknobs_ImGuiKnobs_nKnob(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_pValue, jfloat minValue, jfloat maxValue, jfloat speed, jstring obj_format, jint variant, jfloat size, jint flags, jint steps) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* pValue = (float*)env->GetPrimitiveArrayCritical(obj_pValue, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imguiknobs_ImGuiKnobs_nKnob(env, clazz, obj_label, obj_pValue, minValue, maxValue, speed, obj_format, variant, size, flags, steps, label, format, pValue);

	env->ReleasePrimitiveArrayCritical(obj_pValue, pValue, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_imguiknobs_ImGuiKnobs_nKnobInt
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_pValue, jint minValue, jint maxValue, jfloat speed, jstring obj_format, jint variant, jfloat size, jint flags, jint steps, char* label, char* format, int* pValue) {

//@line:62

     return ImGuiKnobs::KnobInt(label, pValue, minValue, maxValue, speed, format, (ImGuiKnobVariant)variant, size, (ImGuiKnobFlags)flags, steps);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguiknobs_ImGuiKnobs_nKnobInt(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_pValue, jint minValue, jint maxValue, jfloat speed, jstring obj_format, jint variant, jfloat size, jint flags, jint steps) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* pValue = (int*)env->GetPrimitiveArrayCritical(obj_pValue, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imguiknobs_ImGuiKnobs_nKnobInt(env, clazz, obj_label, obj_pValue, minValue, maxValue, speed, obj_format, variant, size, flags, steps, label, format, pValue);

	env->ReleasePrimitiveArrayCritical(obj_pValue, pValue, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}


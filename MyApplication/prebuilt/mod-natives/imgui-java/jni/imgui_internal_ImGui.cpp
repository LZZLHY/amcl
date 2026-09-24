#include <imgui_internal_ImGui.h>

//@line:12

        #include "_common.h"
        #include <imgui_internal.h>
     JNIEXPORT void JNICALL Java_imgui_internal_ImGui_calcItemSize(JNIEnv* env, jclass clazz, jfloat sizeX, jfloat sizeY, jfloat defaultW, jfloat defaultH, jobject dstImVec2) {


//@line:25

        Jni::ImVec2Cpy(env, ImGui::CalcItemSize(ImVec2(sizeX, sizeY), defaultW, defaultH), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGui_calcItemSizeX(JNIEnv* env, jclass clazz, jfloat sizeX, jfloat sizeY, jfloat defaultW, jfloat defaultH) {


//@line:29

        return ImGui::CalcItemSize(ImVec2(sizeX, sizeY), defaultW, defaultH).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_internal_ImGui_calcItemSizeY(JNIEnv* env, jclass clazz, jfloat sizeX, jfloat sizeY, jfloat defaultW, jfloat defaultH) {


//@line:33

        return ImGui::CalcItemSize(ImVec2(sizeX, sizeY), defaultW, defaultH).y;
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_pushItemFlag(JNIEnv* env, jclass clazz, jint imGuiItemFlags, jboolean enabled) {


//@line:37

        ImGui::PushItemFlag(imGuiItemFlags, enabled);
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_popItemFlag(JNIEnv* env, jclass clazz) {


//@line:41

        ImGui::PopItemFlag();
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderDockWindow(JNIEnv* env, jclass clazz, jstring obj_windowName, jint nodeId) {
	char* windowName = (char*)env->GetStringUTFChars(obj_windowName, 0);


//@line:55

        ImGui::DockBuilderDockWindow(windowName, nodeId);
    
	env->ReleaseStringUTFChars(obj_windowName, windowName);

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGui_nDockBuilderGetNode(JNIEnv* env, jclass clazz, jint nodeId) {


//@line:64

        return (intptr_t)ImGui::DockBuilderGetNode(nodeId);
    

}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGui_nDockBuilderGetCentralNode(JNIEnv* env, jclass clazz, jint nodeId) {


//@line:73

        return (intptr_t)ImGui::DockBuilderGetCentralNode(nodeId);
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGui_dockBuilderAddNode__(JNIEnv* env, jclass clazz) {


//@line:77

        return ImGui::DockBuilderAddNode();
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGui_dockBuilderAddNode__I(JNIEnv* env, jclass clazz, jint nodeId) {


//@line:81

        return ImGui::DockBuilderAddNode(nodeId);
    

}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGui_dockBuilderAddNode__II(JNIEnv* env, jclass clazz, jint nodeId, jint flags) {


//@line:85

        return ImGui::DockBuilderAddNode(nodeId, flags);
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderRemoveNode(JNIEnv* env, jclass clazz, jint nodeId) {


//@line:92

        ImGui::DockBuilderRemoveNode(nodeId);
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderRemoveNodeDockedWindows__I(JNIEnv* env, jclass clazz, jint nodeId) {


//@line:96

        ImGui::DockBuilderRemoveNodeDockedWindows(nodeId);
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderRemoveNodeDockedWindows__IZ(JNIEnv* env, jclass clazz, jint nodeId, jboolean clearSettingsRefs) {


//@line:100

        ImGui::DockBuilderRemoveNodeDockedWindows(nodeId, clearSettingsRefs);
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderRemoveNodeChildNodes(JNIEnv* env, jclass clazz, jint nodeId) {


//@line:107

        ImGui::DockBuilderRemoveNodeChildNodes(nodeId);
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderSetNodePos(JNIEnv* env, jclass clazz, jint nodeId, jfloat posX, jfloat posY) {


//@line:111

        ImGui::DockBuilderSetNodePos(nodeId, ImVec2(posX, posY));
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderSetNodeSize(JNIEnv* env, jclass clazz, jint nodeId, jfloat sizeX, jfloat sizeY) {


//@line:115

        ImGui::DockBuilderSetNodeSize(nodeId, ImVec2(sizeX, sizeY));
    

}

static inline jint wrapped_Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIF_3I_3I
(JNIEnv* env, jclass clazz, jint nodeId, jint splitDir, jfloat sizeRatioForNodeAtDir, jintArray obj_outIdAtDir, jintArray obj_outIdAtOppositeDir, int* outIdAtDir, int* outIdAtOppositeDir) {

//@line:134

        return ImGui::DockBuilderSplitNode(nodeId, splitDir, sizeRatioForNodeAtDir, (ImGuiID*)&outIdAtDir[0], (ImGuiID*)&outIdAtOppositeDir[0]);
    
}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIF_3I_3I(JNIEnv* env, jclass clazz, jint nodeId, jint splitDir, jfloat sizeRatioForNodeAtDir, jintArray obj_outIdAtDir, jintArray obj_outIdAtOppositeDir) {
	int* outIdAtDir = (int*)env->GetPrimitiveArrayCritical(obj_outIdAtDir, 0);
	int* outIdAtOppositeDir = (int*)env->GetPrimitiveArrayCritical(obj_outIdAtOppositeDir, 0);

	jint JNI_returnValue = wrapped_Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIF_3I_3I(env, clazz, nodeId, splitDir, sizeRatioForNodeAtDir, obj_outIdAtDir, obj_outIdAtOppositeDir, outIdAtDir, outIdAtOppositeDir);

	env->ReleasePrimitiveArrayCritical(obj_outIdAtDir, outIdAtDir, 0);
	env->ReleasePrimitiveArrayCritical(obj_outIdAtOppositeDir, outIdAtOppositeDir, 0);

	return JNI_returnValue;
}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIF(JNIEnv* env, jclass clazz, jint nodeId, jint splitDir, jfloat sizeRatioForNodeAtDir) {


//@line:138

        return ImGui::DockBuilderSplitNode(nodeId, splitDir, sizeRatioForNodeAtDir, NULL, NULL);
    

}

static inline jint wrapped_Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIF_3I
(JNIEnv* env, jclass clazz, jint nodeId, jint splitDir, jfloat sizeRatioForNodeAtDir, jintArray obj_outIdAtDir, int* outIdAtDir) {

//@line:142

        return ImGui::DockBuilderSplitNode(nodeId, splitDir, sizeRatioForNodeAtDir, (ImGuiID*)&outIdAtDir[0], NULL);
    
}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIF_3I(JNIEnv* env, jclass clazz, jint nodeId, jint splitDir, jfloat sizeRatioForNodeAtDir, jintArray obj_outIdAtDir) {
	int* outIdAtDir = (int*)env->GetPrimitiveArrayCritical(obj_outIdAtDir, 0);

	jint JNI_returnValue = wrapped_Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIF_3I(env, clazz, nodeId, splitDir, sizeRatioForNodeAtDir, obj_outIdAtDir, outIdAtDir);

	env->ReleasePrimitiveArrayCritical(obj_outIdAtDir, outIdAtDir, 0);

	return JNI_returnValue;
}

static inline jint wrapped_Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIFI_3I
(JNIEnv* env, jclass clazz, jint nodeId, jint splitDir, jfloat sizeRatioForNodeAtDir, jint o, jintArray obj_outIdAtOppositeDir, int* outIdAtOppositeDir) {

//@line:146

        return ImGui::DockBuilderSplitNode(nodeId, splitDir, sizeRatioForNodeAtDir, NULL, (ImGuiID*)&outIdAtOppositeDir[0]);
    
}

JNIEXPORT jint JNICALL Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIFI_3I(JNIEnv* env, jclass clazz, jint nodeId, jint splitDir, jfloat sizeRatioForNodeAtDir, jint o, jintArray obj_outIdAtOppositeDir) {
	int* outIdAtOppositeDir = (int*)env->GetPrimitiveArrayCritical(obj_outIdAtOppositeDir, 0);

	jint JNI_returnValue = wrapped_Java_imgui_internal_ImGui_nDockBuilderSplitNode__IIFI_3I(env, clazz, nodeId, splitDir, sizeRatioForNodeAtDir, o, obj_outIdAtOppositeDir, outIdAtOppositeDir);

	env->ReleasePrimitiveArrayCritical(obj_outIdAtOppositeDir, outIdAtOppositeDir, 0);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderCopyWindowSettings(JNIEnv* env, jclass clazz, jstring obj_srcName, jstring obj_dstName) {
	char* srcName = (char*)env->GetStringUTFChars(obj_srcName, 0);
	char* dstName = (char*)env->GetStringUTFChars(obj_dstName, 0);


//@line:152

        ImGui::DockBuilderCopyWindowSettings(srcName, dstName);
    
	env->ReleaseStringUTFChars(obj_srcName, srcName);
	env->ReleaseStringUTFChars(obj_dstName, dstName);

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_dockBuilderFinish(JNIEnv* env, jclass clazz, jint nodeId) {


//@line:156

        ImGui::DockBuilderFinish(nodeId);
    

}

static inline jboolean wrapped_Java_imgui_internal_ImGui_nSplitterBehaviour
(JNIEnv* env, jclass clazz, jfloat bbMinX, jfloat bbMinY, jfloat bbMaxX, jfloat bbMaxY, jint id, jint imGuiAxis, jfloatArray obj_size1, jfloatArray obj_size2, jfloat minSize1, jfloat minSize2, jfloat hoverExtend, jfloat hoverVisibilityDelay, jint bgCol, float* size1, float* size2) {

//@line:174

        return ImGui::SplitterBehavior(ImRect(bbMinX, bbMinY, bbMaxX, bbMaxY), id, (ImGuiAxis)imGuiAxis, &size1[0], &size2[0], minSize1, minSize2, hoverExtend, hoverVisibilityDelay, bgCol);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_internal_ImGui_nSplitterBehaviour(JNIEnv* env, jclass clazz, jfloat bbMinX, jfloat bbMinY, jfloat bbMaxX, jfloat bbMaxY, jint id, jint imGuiAxis, jfloatArray obj_size1, jfloatArray obj_size2, jfloat minSize1, jfloat minSize2, jfloat hoverExtend, jfloat hoverVisibilityDelay, jint bgCol) {
	float* size1 = (float*)env->GetPrimitiveArrayCritical(obj_size1, 0);
	float* size2 = (float*)env->GetPrimitiveArrayCritical(obj_size2, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_internal_ImGui_nSplitterBehaviour(env, clazz, bbMinX, bbMinY, bbMaxX, bbMaxY, id, imGuiAxis, obj_size1, obj_size2, minSize1, minSize2, hoverExtend, hoverVisibilityDelay, bgCol, size1, size2);

	env->ReleasePrimitiveArrayCritical(obj_size1, size1, 0);
	env->ReleasePrimitiveArrayCritical(obj_size2, size2, 0);

	return JNI_returnValue;
}

JNIEXPORT jlong JNICALL Java_imgui_internal_ImGui_nGetCurrentWindow(JNIEnv* env, jclass clazz) {


//@line:183

        return (intptr_t)ImGui::GetCurrentWindow();
    

}

JNIEXPORT void JNICALL Java_imgui_internal_ImGui_nGetWindowScrollbarRect(JNIEnv* env, jclass clazz, jlong windowPtr, jint axis, jobject minDstImVec2, jobject maxDstImVec2) {


//@line:193

        ImRect rect = ImGui::GetWindowScrollbarRect((ImGuiWindow*)windowPtr, static_cast<ImGuiAxis>(axis));
        Jni::ImVec2Cpy(env, &rect.Min, minDstImVec2);
        Jni::ImVec2Cpy(env, &rect.Max, maxDstImVec2);
    

}


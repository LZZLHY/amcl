#include <imgui_extension_imnodes_ImNodes.h>
#include <imgui_extension_imnodes_ImNodesContext.h>

//@line:20

        #include "_imnodes.h"
     JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_nEditorContextSet(JNIEnv* env, jclass clazz, jlong ptr) {


//@line:42

        ImNodes::EditorContextSet((ImNodesEditorContext*)ptr);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_createContext(JNIEnv* env, jclass clazz) {


//@line:49

        ImNodes::CreateContext();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_destroyContext(JNIEnv* env, jclass clazz) {


//@line:53

        ImNodes::DestroyContext();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_imnodes_ImNodes_nGetStyle(JNIEnv* env, jclass clazz) {


//@line:65

        return (intptr_t)&ImNodes::GetStyle();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_styleColorsDark(JNIEnv* env, jclass clazz) {


//@line:71

        ImNodes::StyleColorsDark();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_styleColorsClassic(JNIEnv* env, jclass clazz) {


//@line:75

        ImNodes::StyleColorsClassic();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_styleColorsLight(JNIEnv* env, jclass clazz) {


//@line:79

        ImNodes::StyleColorsLight();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_pushColorStyle(JNIEnv* env, jclass clazz, jint imNodesStyleColor, jint color) {


//@line:86

        ImNodes::PushColorStyle((ImNodesCol)imNodesStyleColor, color);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_popColorStyle(JNIEnv* env, jclass clazz) {


//@line:90

        ImNodes::PopColorStyle();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_pushStyleVar__IF(JNIEnv* env, jclass clazz, jint imNodesStyleVar, jfloat value) {


//@line:94

        ImNodes::PushStyleVar((ImNodesStyleVar)imNodesStyleVar, value);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_pushStyleVar__IFF(JNIEnv* env, jclass clazz, jint imNodesStyleVar, jfloat x, jfloat y) {


//@line:98

        ImNodes::PushStyleVar((ImNodesStyleVar)imNodesStyleVar, ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_popStyleVar(JNIEnv* env, jclass clazz) {


//@line:102

        ImNodes::PopStyleVar();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_beginNodeEditor(JNIEnv* env, jclass clazz) {


//@line:110

        ImNodes::BeginNodeEditor();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_endNodeEditor(JNIEnv* env, jclass clazz) {


//@line:114

        ImNodes::EndNodeEditor();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_beginNode(JNIEnv* env, jclass clazz, jint node) {


//@line:118

        ImNodes::BeginNode(node);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_endNode(JNIEnv* env, jclass clazz) {


//@line:122

        ImNodes::EndNode();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_link(JNIEnv* env, jclass clazz, jint id, jint source, jint target) {


//@line:131

        ImNodes::Link(id, source, target);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_beginNodeTitleBar(JNIEnv* env, jclass clazz) {


//@line:140

        ImNodes::BeginNodeTitleBar();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_endNodeTitleBar(JNIEnv* env, jclass clazz) {


//@line:144

        ImNodes::EndNodeTitleBar();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_beginStaticAttribute(JNIEnv* env, jclass clazz, jint id) {


//@line:162

        ImNodes::BeginStaticAttribute(id);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_endStaticAttribute(JNIEnv* env, jclass clazz) {


//@line:166

        ImNodes::EndStaticAttribute();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_beginInputAttribute(JNIEnv* env, jclass clazz, jint id, jint imNodesPinShape) {


//@line:177

        ImNodes::BeginInputAttribute(id, (ImNodesPinShape)imNodesPinShape);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_endInputAttribute(JNIEnv* env, jclass clazz) {


//@line:181

        ImNodes::EndInputAttribute();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_beginOutputAttribute(JNIEnv* env, jclass clazz, jint id, jint imNodesPinShape) {


//@line:192

        ImNodes::BeginOutputAttribute(id, (ImNodesPinShape)imNodesPinShape);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_pushAttributeFlag(JNIEnv* env, jclass clazz, jint imNodesAttributeFlags) {


//@line:199

        ImNodes::PushAttributeFlag((ImNodesAttributeFlags)imNodesAttributeFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_endOutputAttribute(JNIEnv* env, jclass clazz) {


//@line:203

        ImNodes::EndOutputAttribute();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_isEditorHovered(JNIEnv* env, jclass clazz) {


//@line:211

        return ImNodes::IsEditorHovered();
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_imnodes_ImNodes_getHoveredNode(JNIEnv* env, jclass clazz) {


//@line:225

        int i;
        return ImNodes::IsNodeHovered(&i) ? i : -1;
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_imnodes_ImNodes_getHoveredLink(JNIEnv* env, jclass clazz) {


//@line:233

        int i;
        return ImNodes::IsLinkHovered(&i) ? i : -1;
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_imnodes_ImNodes_getHoveredPin(JNIEnv* env, jclass clazz) {


//@line:241

        int i;
        return ImNodes::IsPinHovered(&i) ? i : -1;
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_imnodes_ImNodes_getActiveAttribute(JNIEnv* env, jclass clazz) {


//@line:251

        int i;
        return ImNodes::IsAnyAttributeActive(&i) ? i : -1;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_isAttributeActive(JNIEnv* env, jclass clazz) {


//@line:260

        return ImNodes::IsAttributeActive();
    

}

static inline jboolean wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkStarted
(JNIEnv* env, jclass clazz, jintArray obj_data, int* data) {

//@line:274

        return ImNodes::IsLinkStarted(&data[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_nIsLinkStarted(JNIEnv* env, jclass clazz, jintArray obj_data) {
	int* data = (int*)env->GetPrimitiveArrayCritical(obj_data, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkStarted(env, clazz, obj_data, data);

	env->ReleasePrimitiveArrayCritical(obj_data, data, 0);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkDropped
(JNIEnv* env, jclass clazz, jintArray obj_data, jboolean includingDetachedLinks, int* data) {

//@line:290

        return ImNodes::IsLinkDropped(&data[0], includingDetachedLinks);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_nIsLinkDropped(JNIEnv* env, jclass clazz, jintArray obj_data, jboolean includingDetachedLinks) {
	int* data = (int*)env->GetPrimitiveArrayCritical(obj_data, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkDropped(env, clazz, obj_data, includingDetachedLinks, data);

	env->ReleasePrimitiveArrayCritical(obj_data, data, 0);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkCreated___3I_3I
(JNIEnv* env, jclass clazz, jintArray obj_sourceAttribute, jintArray obj_targetAttribute, int* sourceAttribute, int* targetAttribute) {

//@line:301

        return ImNodes::IsLinkCreated(&sourceAttribute[0], &targetAttribute[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_nIsLinkCreated___3I_3I(JNIEnv* env, jclass clazz, jintArray obj_sourceAttribute, jintArray obj_targetAttribute) {
	int* sourceAttribute = (int*)env->GetPrimitiveArrayCritical(obj_sourceAttribute, 0);
	int* targetAttribute = (int*)env->GetPrimitiveArrayCritical(obj_targetAttribute, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkCreated___3I_3I(env, clazz, obj_sourceAttribute, obj_targetAttribute, sourceAttribute, targetAttribute);

	env->ReleasePrimitiveArrayCritical(obj_sourceAttribute, sourceAttribute, 0);
	env->ReleasePrimitiveArrayCritical(obj_targetAttribute, targetAttribute, 0);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkCreated___3I_3I_3I_3I_3Z
(JNIEnv* env, jclass clazz, jintArray obj_startedAtNodeId, jintArray obj_startedAtAttributeId, jintArray obj_endedAtNodeId, jintArray obj_endedAtAttributeId, jbooleanArray obj_createdFromSnap, int* startedAtNodeId, int* startedAtAttributeId, int* endedAtNodeId, int* endedAtAttributeId, bool* createdFromSnap) {

//@line:311

        return ImNodes::IsLinkCreated(&startedAtNodeId[0], &startedAtAttributeId[0], &endedAtNodeId[0], &endedAtAttributeId[0], &createdFromSnap[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_nIsLinkCreated___3I_3I_3I_3I_3Z(JNIEnv* env, jclass clazz, jintArray obj_startedAtNodeId, jintArray obj_startedAtAttributeId, jintArray obj_endedAtNodeId, jintArray obj_endedAtAttributeId, jbooleanArray obj_createdFromSnap) {
	int* startedAtNodeId = (int*)env->GetPrimitiveArrayCritical(obj_startedAtNodeId, 0);
	int* startedAtAttributeId = (int*)env->GetPrimitiveArrayCritical(obj_startedAtAttributeId, 0);
	int* endedAtNodeId = (int*)env->GetPrimitiveArrayCritical(obj_endedAtNodeId, 0);
	int* endedAtAttributeId = (int*)env->GetPrimitiveArrayCritical(obj_endedAtAttributeId, 0);
	bool* createdFromSnap = (bool*)env->GetPrimitiveArrayCritical(obj_createdFromSnap, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkCreated___3I_3I_3I_3I_3Z(env, clazz, obj_startedAtNodeId, obj_startedAtAttributeId, obj_endedAtNodeId, obj_endedAtAttributeId, obj_createdFromSnap, startedAtNodeId, startedAtAttributeId, endedAtNodeId, endedAtAttributeId, createdFromSnap);

	env->ReleasePrimitiveArrayCritical(obj_startedAtNodeId, startedAtNodeId, 0);
	env->ReleasePrimitiveArrayCritical(obj_startedAtAttributeId, startedAtAttributeId, 0);
	env->ReleasePrimitiveArrayCritical(obj_endedAtNodeId, endedAtNodeId, 0);
	env->ReleasePrimitiveArrayCritical(obj_endedAtAttributeId, endedAtAttributeId, 0);
	env->ReleasePrimitiveArrayCritical(obj_createdFromSnap, createdFromSnap, 0);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkDestroyed
(JNIEnv* env, jclass clazz, jintArray obj_linkId, int* linkId) {

//@line:323

        return ImNodes::IsLinkDestroyed(&linkId[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_nIsLinkDestroyed(JNIEnv* env, jclass clazz, jintArray obj_linkId) {
	int* linkId = (int*)env->GetPrimitiveArrayCritical(obj_linkId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imnodes_ImNodes_nIsLinkDestroyed(env, clazz, obj_linkId, linkId);

	env->ReleasePrimitiveArrayCritical(obj_linkId, linkId, 0);

	return JNI_returnValue;
}

JNIEXPORT jint JNICALL Java_imgui_extension_imnodes_ImNodes_numSelectedNodes(JNIEnv* env, jclass clazz) {


//@line:331

        return ImNodes::NumSelectedNodes();
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_imnodes_ImNodes_numSelectedLinks(JNIEnv* env, jclass clazz) {


//@line:335

        return ImNodes::NumSelectedLinks();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_getSelectedNodes(JNIEnv* env, jclass clazz, jintArray obj_nodeIds) {
	int* nodeIds = (int*)env->GetPrimitiveArrayCritical(obj_nodeIds, 0);


//@line:344

        ImNodes::GetSelectedNodes(&nodeIds[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_nodeIds, nodeIds, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_getSelectedLinks(JNIEnv* env, jclass clazz, jintArray obj_linkIds) {
	int* linkIds = (int*)env->GetPrimitiveArrayCritical(obj_linkIds, 0);


//@line:348

        ImNodes::GetSelectedLinks(&linkIds[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_linkIds, linkIds, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_clearNodeSelection__(JNIEnv* env, jclass clazz) {


//@line:355

        ImNodes::ClearNodeSelection();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_clearNodeSelection__I(JNIEnv* env, jclass clazz, jint node) {


//@line:359

        ImNodes::ClearNodeSelection(node);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_clearLinkSelection__(JNIEnv* env, jclass clazz) {


//@line:363

        ImNodes::ClearLinkSelection();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_clearLinkSelection__I(JNIEnv* env, jclass clazz, jint link) {


//@line:367

        ImNodes::ClearLinkSelection(link);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_selectNode(JNIEnv* env, jclass clazz, jint node) {


//@line:374

        ImNodes::SelectNode(node);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_selectLink(JNIEnv* env, jclass clazz, jint link) {


//@line:378

        ImNodes::SelectLink(link);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_isNodeSelected(JNIEnv* env, jclass clazz, jint node) {


//@line:385

        return ImNodes::IsNodeSelected(node);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imnodes_ImNodes_isLinkSelected(JNIEnv* env, jclass clazz, jint link) {


//@line:389

        return ImNodes::IsLinkSelected(link);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_setNodeDraggable(JNIEnv* env, jclass clazz, jint node, jboolean isDraggable) {


//@line:396

        ImNodes::SetNodeDraggable(node, isDraggable);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeDimensions(JNIEnv* env, jclass clazz, jint node, jobject result) {


//@line:400

        ImVec2 dst = ImNodes::GetNodeDimensions(node);
        Jni::ImVec2Cpy(env, &dst, result);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeDimensionsX(JNIEnv* env, jclass clazz, jint node) {


//@line:405

        return ImNodes::GetNodeDimensions(node).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeDimensionsY(JNIEnv* env, jclass clazz, jint node) {


//@line:409

        return ImNodes::GetNodeDimensions(node).y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_setNodeScreenSpacePos(JNIEnv* env, jclass clazz, jint node, jfloat x, jfloat y) {


//@line:422

        ImNodes::SetNodeScreenSpacePos(node, ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_setNodeEditorSpacePos(JNIEnv* env, jclass clazz, jint node, jfloat x, jfloat y) {


//@line:426

        ImNodes::SetNodeEditorSpacePos(node, ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_setNodeGridSpacePos(JNIEnv* env, jclass clazz, jint node, jfloat x, jfloat y) {


//@line:430

        ImNodes::SetNodeGridSpacePos(node, ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeScreenSpacePos(JNIEnv* env, jclass clazz, jint node, jobject result) {


//@line:434

        ImVec2 dst = ImNodes::GetNodeScreenSpacePos(node);
        Jni::ImVec2Cpy(env, &dst, result);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeScreenSpacePosX(JNIEnv* env, jclass clazz, jint node) {


//@line:439

        return ImNodes::GetNodeScreenSpacePos(node).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeScreenSpacePosY(JNIEnv* env, jclass clazz, jint node) {


//@line:443

        return ImNodes::GetNodeScreenSpacePos(node).y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeEditorSpacePos(JNIEnv* env, jclass clazz, jint node, jobject result) {


//@line:447

        ImVec2 dst = ImNodes::GetNodeEditorSpacePos(node);
        Jni::ImVec2Cpy(env, &dst, result);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeEditorSpacePosX(JNIEnv* env, jclass clazz, jint node) {


//@line:452

        return ImNodes::GetNodeEditorSpacePos(node).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeEditorSpacePosY(JNIEnv* env, jclass clazz, jint node) {


//@line:456

        return ImNodes::GetNodeEditorSpacePos(node).y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeGridSpacePos(JNIEnv* env, jclass clazz, jint node, jobject dst) {


//@line:460

        ImVec2 result = ImNodes::GetNodeGridSpacePos(node);
        Jni::ImVec2Cpy(env, &result, dst);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeGridSpacePosX(JNIEnv* env, jclass clazz, jint node) {


//@line:465

        return ImNodes::GetNodeGridSpacePos(node).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodes_getNodeGridSpacePosY(JNIEnv* env, jclass clazz, jint node) {


//@line:469

        return ImNodes::GetNodeGridSpacePos(node).y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_editorResetPanning(JNIEnv* env, jclass clazz, jfloat x, jfloat y) {


//@line:473

        ImNodes::EditorContextResetPanning(ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_editorContextGetPanning(JNIEnv* env, jclass clazz, jobject result) {


//@line:477

        ImVec2 dst = ImNodes::EditorContextGetPanning();
        Jni::ImVec2Cpy(env, &dst, result);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_editorMoveToNode(JNIEnv* env, jclass clazz, jint node) {


//@line:482

        ImNodes::EditorContextMoveToNode(node);
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_imnodes_ImNodes_saveCurrentEditorStateToIniString(JNIEnv* env, jclass clazz) {


//@line:489

        return env->NewStringUTF(ImNodes::SaveCurrentEditorStateToIniString(NULL));
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_imnodes_ImNodes_nSaveEditorStateToIniString(JNIEnv* env, jclass clazz, jlong context) {


//@line:497

        return env->NewStringUTF(ImNodes::SaveEditorStateToIniString((ImNodesEditorContext*)context, NULL));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_loadCurrentEditorStateFromIniString(JNIEnv* env, jclass clazz, jstring obj_data, jint dataSize) {
	char* data = (char*)env->GetStringUTFChars(obj_data, 0);


//@line:501

        ImNodes::LoadCurrentEditorStateFromIniString(data, dataSize);
    
	env->ReleaseStringUTFChars(obj_data, data);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_nLoadEditorStateFromIniString(JNIEnv* env, jclass clazz, jlong context, jstring obj_data, jint dataSize) {
	char* data = (char*)env->GetStringUTFChars(obj_data, 0);


//@line:509

        ImNodes::LoadEditorStateFromIniString((ImNodesEditorContext*)context, data, dataSize);
    
	env->ReleaseStringUTFChars(obj_data, data);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_saveCurrentEditorStateToIniFile(JNIEnv* env, jclass clazz, jstring obj_fileName) {
	char* fileName = (char*)env->GetStringUTFChars(obj_fileName, 0);


//@line:513

        ImNodes::SaveCurrentEditorStateToIniFile(fileName);
    
	env->ReleaseStringUTFChars(obj_fileName, fileName);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_nSaveEditorStateToIniFile(JNIEnv* env, jclass clazz, jlong context, jstring obj_fileName) {
	char* fileName = (char*)env->GetStringUTFChars(obj_fileName, 0);


//@line:521

        ImNodes::SaveEditorStateToIniFile((ImNodesEditorContext*)context, fileName);
    
	env->ReleaseStringUTFChars(obj_fileName, fileName);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_loadCurrentEditorStateFromIniFile(JNIEnv* env, jclass clazz, jstring obj_fileName) {
	char* fileName = (char*)env->GetStringUTFChars(obj_fileName, 0);


//@line:525

        ImNodes::LoadCurrentEditorStateFromIniFile(fileName);
    
	env->ReleaseStringUTFChars(obj_fileName, fileName);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_nLoadEditorStateFromIniFile(JNIEnv* env, jclass clazz, jlong context, jstring obj_fileName) {
	char* fileName = (char*)env->GetStringUTFChars(obj_fileName, 0);


//@line:533

        ImNodes::LoadEditorStateFromIniFile((ImNodesEditorContext*)context, fileName);
    
	env->ReleaseStringUTFChars(obj_fileName, fileName);

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodes_miniMap(JNIEnv* env, jclass clazz, jfloat miniMapSizeFraction, jint miniMapLocation) {


//@line:537

        ImNodes::MiniMap(miniMapSizeFraction, (ImNodesMiniMapLocation)miniMapLocation);
    

}


#include <imgui_extension_nodeditor_NodeEditor.h>

//@line:33

        #include "_nodeeditor.h"

        namespace ed = ax::NodeEditor;
     JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_nSetCurrentEditor(JNIEnv* env, jclass clazz, jlong editor) {


//@line:61

        ed::SetCurrentEditor((ed::EditorContext*)editor);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_begin(JNIEnv* env, jclass clazz, jstring obj_title) {
	char* title = (char*)env->GetStringUTFChars(obj_title, 0);


//@line:65

        ed::Begin(title);
    
	env->ReleaseStringUTFChars(obj_title, title);

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_beginNode(JNIEnv* env, jclass clazz, jlong id) {


//@line:69

        ed::BeginNode(id);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_group(JNIEnv* env, jclass clazz, jfloat w, jfloat h) {


//@line:73

        ed::Group(ImVec2(w, h));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_beginGroupHint(JNIEnv* env, jclass clazz, jlong id) {


//@line:77

        return ed::BeginGroupHint(id);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_beginPin(JNIEnv* env, jclass clazz, jlong pin, jint imNodeEditorPinKind) {


//@line:82

        ed::BeginPin(pin, (ed::PinKind)imNodeEditorPinKind);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_endGroupHint(JNIEnv* env, jclass clazz) {


//@line:86

        ed::EndGroupHint();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_endPin(JNIEnv* env, jclass clazz) {


//@line:90

        ed::EndPin();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_endNode(JNIEnv* env, jclass clazz) {


//@line:94

        ed::EndNode();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_end(JNIEnv* env, jclass clazz) {


//@line:98

        ed::End();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getScreenSizeX(JNIEnv* env, jclass clazz) {


//@line:102

        return ed::GetScreenSize().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getScreenSizeY(JNIEnv* env, jclass clazz) {


//@line:106

        return ed::GetScreenSize().y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_toCanvasX(JNIEnv* env, jclass clazz, jfloat screenSpacePosX) {


//@line:110

        return ed::ScreenToCanvas(ImVec2(screenSpacePosX, 0.0f)).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_toCanvasY(JNIEnv* env, jclass clazz, jfloat screenSpacePosY) {


//@line:114

        return ed::ScreenToCanvas(ImVec2(0.0f, screenSpacePosY)).y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_toScreenX(JNIEnv* env, jclass clazz, jfloat canvasSpacePosX) {


//@line:118

        return ed::CanvasToScreen(ImVec2(canvasSpacePosX, 0.0f)).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_toScreenY(JNIEnv* env, jclass clazz, jfloat canvasSpacePosY) {


//@line:122

        return ed::CanvasToScreen(ImVec2(0.0f, canvasSpacePosY)).y;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_nGetStyle(JNIEnv* env, jclass clazz) {


//@line:131

        return (intptr_t)&ed::GetStyle();
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_nodeditor_NodeEditor_getStyleColorName(JNIEnv* env, jclass clazz, jint imNodeEditorStyleColor) {


//@line:135

        return env->NewStringUTF(ed::GetStyleColorName((ed::StyleColor)imNodeEditorStyleColor));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pushStyleColor(JNIEnv* env, jclass clazz, jint imNodeEditorStyleColor, jfloat r, jfloat g, jfloat b, jfloat a) {


//@line:139

        ed::PushStyleColor((ed::StyleColor)imNodeEditorStyleColor, ImVec4(r, g, b, a));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_popStyleColor(JNIEnv* env, jclass clazz, jint count) {


//@line:143

        ed::PopStyleColor(count);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pushStyleVar__IF(JNIEnv* env, jclass clazz, jint imNodeEditorStyleVar, jfloat v) {


//@line:147

        ed::PushStyleVar((ed::StyleVar)imNodeEditorStyleVar, v);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pushStyleVar__IFF(JNIEnv* env, jclass clazz, jint imNodeEditorStyleVar, jfloat x, jfloat y) {


//@line:151

        ed::PushStyleVar((ed::StyleVar)imNodeEditorStyleVar, ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pushStyleVar__IFFFF(JNIEnv* env, jclass clazz, jint imNodeEditorStyleVar, jfloat r, jfloat g, jfloat b, jfloat a) {


//@line:155

        ed::PushStyleVar((ed::StyleVar)imNodeEditorStyleVar, ImVec4(r, g, b, a));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_popStyleVar(JNIEnv* env, jclass clazz, jint count) {


//@line:159

        ed::PopStyleVar(count);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getGroupMinX(JNIEnv* env, jclass clazz) {


//@line:163

        return ed::GetGroupMin().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getGroupMinY(JNIEnv* env, jclass clazz) {


//@line:167

        return ed::GetGroupMin().y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getGroupMaxX(JNIEnv* env, jclass clazz) {


//@line:171

        return ed::GetGroupMax().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getGroupMaxY(JNIEnv* env, jclass clazz) {


//@line:175

        return ed::GetGroupMax().y;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_nGetHintForegroundDrawList(JNIEnv* env, jclass clazz) {


//@line:199

        return (intptr_t)(uintptr_t)ed::GetHintForegroundDrawList();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_nGetHintBackgroundDrawList(JNIEnv* env, jclass clazz) {


//@line:203

        return (intptr_t)(uintptr_t)ed::GetHintBackgroundDrawList();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_nGetNodeBackgroundDrawList(JNIEnv* env, jclass clazz, jlong nodeId) {


//@line:207

        return (intptr_t)(uintptr_t)ed::GetNodeBackgroundDrawList(nodeId);
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_getDoubleClickedNode(JNIEnv* env, jclass clazz) {


//@line:211

        return (intptr_t)(uintptr_t)ed::GetDoubleClickedNode();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_getDoubleClickedPin(JNIEnv* env, jclass clazz) {


//@line:215

        return (intptr_t)(uintptr_t)ed::GetDoubleClickedPin();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_getDoubleClickedLink(JNIEnv* env, jclass clazz) {


//@line:219

        return (intptr_t)(uintptr_t)ed::GetDoubleClickedLink();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_isBackgroundClicked(JNIEnv* env, jclass clazz) {


//@line:223

        return ed::IsBackgroundClicked();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_isBackgroundDoubleClicked(JNIEnv* env, jclass clazz) {


//@line:227

        return ed::IsBackgroundDoubleClicked();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_pinHadAnyLinks(JNIEnv* env, jclass clazz, jlong pinId) {


//@line:231

        return ed::PinHadAnyLinks(pinId);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getCurrentZoom(JNIEnv* env, jclass clazz) {


//@line:235

        return ed::GetCurrentZoom();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pinRect(JNIEnv* env, jclass clazz, jfloat x, jfloat y, jfloat w, jfloat h) {


//@line:239

        ed::PinRect(ImVec2(x, y), ImVec2(w, h));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pinPivotRect(JNIEnv* env, jclass clazz, jfloat x, jfloat y, jfloat w, jfloat h) {


//@line:243

        ed::PinPivotRect(ImVec2(x, y), ImVec2(w, h));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pinPivotSize(JNIEnv* env, jclass clazz, jfloat w, jfloat h) {


//@line:247

        ed::PinPivotSize(ImVec2(w, h));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pinPivotScale(JNIEnv* env, jclass clazz, jfloat w, jfloat h) {


//@line:251

        ed::PinPivotScale(ImVec2(w, h));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_pinPivotAlignment(JNIEnv* env, jclass clazz, jfloat x, jfloat y) {


//@line:255

        ed::PinPivotAlignment(ImVec2(x, y));
    

}

static inline jboolean wrapped_Java_imgui_extension_nodeditor_NodeEditor_nShowNodeContextMenu
(JNIEnv* env, jclass clazz, jlongArray obj_nodeId, long long* nodeId) {

//@line:263

        return ed::ShowNodeContextMenu((ed::NodeId*)&nodeId[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_nShowNodeContextMenu(JNIEnv* env, jclass clazz, jlongArray obj_nodeId) {
	long long* nodeId = (long long*)env->GetPrimitiveArrayCritical(obj_nodeId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_nShowNodeContextMenu(env, clazz, obj_nodeId, nodeId);

	env->ReleasePrimitiveArrayCritical(obj_nodeId, nodeId, 0);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_nodeditor_NodeEditor_nShowPinContextMenu
(JNIEnv* env, jclass clazz, jlongArray obj_pinId, long long* pinId) {

//@line:271

        return ed::ShowPinContextMenu((ed::PinId*)&pinId[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_nShowPinContextMenu(JNIEnv* env, jclass clazz, jlongArray obj_pinId) {
	long long* pinId = (long long*)env->GetPrimitiveArrayCritical(obj_pinId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_nShowPinContextMenu(env, clazz, obj_pinId, pinId);

	env->ReleasePrimitiveArrayCritical(obj_pinId, pinId, 0);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_nodeditor_NodeEditor_nShowLinkContextMenu
(JNIEnv* env, jclass clazz, jlongArray obj_linkId, long long* linkId) {

//@line:279

        return ed::ShowLinkContextMenu((ed::LinkId*)&linkId[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_nShowLinkContextMenu(JNIEnv* env, jclass clazz, jlongArray obj_linkId) {
	long long* linkId = (long long*)env->GetPrimitiveArrayCritical(obj_linkId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_nShowLinkContextMenu(env, clazz, obj_linkId, linkId);

	env->ReleasePrimitiveArrayCritical(obj_linkId, linkId, 0);

	return JNI_returnValue;
}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_getNodeWithContextMenu(JNIEnv* env, jclass clazz) {


//@line:291

        ed::NodeId id;
        return ed::ShowNodeContextMenu(&id) ? (intptr_t)(uintptr_t)id : -1;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_getPinWithContextMenu(JNIEnv* env, jclass clazz) {


//@line:296

        ed::PinId id;
        return ed::ShowPinContextMenu(&id) ? (intptr_t)(uintptr_t)id : -1;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditor_getLinkWithContextMenu(JNIEnv* env, jclass clazz) {


//@line:301

        ed::LinkId id;
        return ed::ShowLinkContextMenu(&id) ? (intptr_t)(uintptr_t)id : -1;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_showBackgroundContextMenu(JNIEnv* env, jclass clazz) {


//@line:306

        return ed::ShowBackgroundContextMenu();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_restoreNodeState(JNIEnv* env, jclass clazz, jlong node) {


//@line:310

        ed::RestoreNodeState(node);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_suspend(JNIEnv* env, jclass clazz) {


//@line:314

        ed::Suspend();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_resume(JNIEnv* env, jclass clazz) {


//@line:318

        ed::Resume();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_isSuspended(JNIEnv* env, jclass clazz) {


//@line:322

        return ed::IsSuspended();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_isActive(JNIEnv* env, jclass clazz) {


//@line:326

        return ed::IsActive();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_setNodePosition(JNIEnv* env, jclass clazz, jlong node, jfloat x, jfloat y) {


//@line:330

        ed::SetNodePosition(node, ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_link(JNIEnv* env, jclass clazz, jlong id, jlong startPinId, jlong endPinId, jfloat r, jfloat g, jfloat b, jfloat a, jfloat thickness) {


//@line:339

        ed::Link(id, startPinId, endPinId, ImVec4(r, g, b, a), thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_flow(JNIEnv* env, jclass clazz, jlong linkId) {


//@line:343

        ed::Flow(linkId);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_beginCreate(JNIEnv* env, jclass clazz, jfloat r, jfloat g, jfloat b, jfloat a, jfloat thickness) {


//@line:351

        return ed::BeginCreate(ImVec4(r, g, b, a), thickness);
    

}

static inline jboolean wrapped_Java_imgui_extension_nodeditor_NodeEditor_nQueryNewLink
(JNIEnv* env, jclass clazz, jlongArray obj_startId, jlongArray obj_endId, jfloat r, jfloat g, jfloat b, jfloat a, jfloat thickness, long long* startId, long long* endId) {

//@line:363

        return ed::QueryNewLink((ed::PinId*)&startId[0], (ed::PinId*)&endId[0], ImVec4(r, g, b, a), thickness);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_nQueryNewLink(JNIEnv* env, jclass clazz, jlongArray obj_startId, jlongArray obj_endId, jfloat r, jfloat g, jfloat b, jfloat a, jfloat thickness) {
	long long* startId = (long long*)env->GetPrimitiveArrayCritical(obj_startId, 0);
	long long* endId = (long long*)env->GetPrimitiveArrayCritical(obj_endId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_nQueryNewLink(env, clazz, obj_startId, obj_endId, r, g, b, a, thickness, startId, endId);

	env->ReleasePrimitiveArrayCritical(obj_startId, startId, 0);
	env->ReleasePrimitiveArrayCritical(obj_endId, endId, 0);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_acceptNewItem(JNIEnv* env, jclass clazz, jfloat r, jfloat g, jfloat b, jfloat a, jfloat thickness) {


//@line:371

        return ed::AcceptNewItem(ImVec4(r, g, b, a), thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_rejectNewItem(JNIEnv* env, jclass clazz, jfloat r, jfloat g, jfloat b, jfloat a, jfloat thickness) {


//@line:379

        ed::RejectNewItem(ImVec4(r, g, b, a), thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_endCreate(JNIEnv* env, jclass clazz) {


//@line:383

        ed::EndCreate();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_beginDelete(JNIEnv* env, jclass clazz) {


//@line:387

        return ed::BeginDelete();
    

}

static inline jboolean wrapped_Java_imgui_extension_nodeditor_NodeEditor_nQueryDeletedLink
(JNIEnv* env, jclass clazz, jlongArray obj_linkId, jlongArray obj_startId, jlongArray obj_endId, long long* linkId, long long* startId, long long* endId) {

//@line:395

        return ed::QueryDeletedLink((ed::LinkId*)&linkId[0], (ed::PinId*)&startId[0], (ed::PinId*)&endId[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_nQueryDeletedLink(JNIEnv* env, jclass clazz, jlongArray obj_linkId, jlongArray obj_startId, jlongArray obj_endId) {
	long long* linkId = (long long*)env->GetPrimitiveArrayCritical(obj_linkId, 0);
	long long* startId = (long long*)env->GetPrimitiveArrayCritical(obj_startId, 0);
	long long* endId = (long long*)env->GetPrimitiveArrayCritical(obj_endId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_nQueryDeletedLink(env, clazz, obj_linkId, obj_startId, obj_endId, linkId, startId, endId);

	env->ReleasePrimitiveArrayCritical(obj_linkId, linkId, 0);
	env->ReleasePrimitiveArrayCritical(obj_startId, startId, 0);
	env->ReleasePrimitiveArrayCritical(obj_endId, endId, 0);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_nodeditor_NodeEditor_nQueryDeletedNode
(JNIEnv* env, jclass clazz, jlongArray obj_nodeId, long long* nodeId) {

//@line:403

        return ed::QueryDeletedNode((ed::NodeId*)&nodeId[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_nQueryDeletedNode(JNIEnv* env, jclass clazz, jlongArray obj_nodeId) {
	long long* nodeId = (long long*)env->GetPrimitiveArrayCritical(obj_nodeId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_nQueryDeletedNode(env, clazz, obj_nodeId, nodeId);

	env->ReleasePrimitiveArrayCritical(obj_nodeId, nodeId, 0);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_acceptDeletedItem(JNIEnv* env, jclass clazz) {


//@line:407

        return ed::AcceptDeletedItem();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_rejectDeletedItem(JNIEnv* env, jclass clazz) {


//@line:411

        ed::RejectDeletedItem();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_endDelete(JNIEnv* env, jclass clazz) {


//@line:415

        ed::EndDelete();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_navigateToContent(JNIEnv* env, jclass clazz, jfloat duration) {


//@line:419

        ed::NavigateToContent(duration);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_navigateToSelection(JNIEnv* env, jclass clazz, jboolean zoomIn, jfloat duration) {


//@line:423

        ed::NavigateToSelection(zoomIn, duration);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_getNodePosition(JNIEnv* env, jclass clazz, jlong node, jobject dst) {


//@line:427

        ImVec2 result = ed::GetNodePosition(node);
        Jni::ImVec2Cpy(env, &result, dst);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getNodePositionX(JNIEnv* env, jclass clazz, jlong node) {


//@line:432

        return ed::GetNodePosition(node).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getNodePositionY(JNIEnv* env, jclass clazz, jlong node) {


//@line:436

        return ed::GetNodePosition(node).y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getNodeSizeX(JNIEnv* env, jclass clazz, jlong node) {


//@line:440

        return ed::GetNodeSize(node).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditor_getNodeSizeY(JNIEnv* env, jclass clazz, jlong node) {


//@line:444

        return ed::GetNodeSize(node).y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_centerNodeOnScreen(JNIEnv* env, jclass clazz, jlong node) {


//@line:448

        ed::CenterNodeOnScreen(node);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_hasSelectionChanged(JNIEnv* env, jclass clazz) {


//@line:452

        return ed::HasSelectionChanged();
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_nodeditor_NodeEditor_getSelectedObjectCount(JNIEnv* env, jclass clazz) {


//@line:456

        return ed::GetSelectedObjectCount();
    

}

static inline jint wrapped_Java_imgui_extension_nodeditor_NodeEditor_getSelectedNodes
(JNIEnv* env, jclass clazz, jlongArray obj_nodes, jint size, long long* nodes) {

//@line:460

        return ed::GetSelectedNodes((ed::NodeId*)&nodes[0], size);
    
}

JNIEXPORT jint JNICALL Java_imgui_extension_nodeditor_NodeEditor_getSelectedNodes(JNIEnv* env, jclass clazz, jlongArray obj_nodes, jint size) {
	long long* nodes = (long long*)env->GetPrimitiveArrayCritical(obj_nodes, 0);

	jint JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_getSelectedNodes(env, clazz, obj_nodes, size, nodes);

	env->ReleasePrimitiveArrayCritical(obj_nodes, nodes, 0);

	return JNI_returnValue;
}

static inline jint wrapped_Java_imgui_extension_nodeditor_NodeEditor_getSelectedLinks
(JNIEnv* env, jclass clazz, jlongArray obj_links, jint size, long long* links) {

//@line:464

        return ed::GetSelectedLinks((ed::LinkId*)&links[0], size);
    
}

JNIEXPORT jint JNICALL Java_imgui_extension_nodeditor_NodeEditor_getSelectedLinks(JNIEnv* env, jclass clazz, jlongArray obj_links, jint size) {
	long long* links = (long long*)env->GetPrimitiveArrayCritical(obj_links, 0);

	jint JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_getSelectedLinks(env, clazz, obj_links, size, links);

	env->ReleasePrimitiveArrayCritical(obj_links, links, 0);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_clearSelection(JNIEnv* env, jclass clazz) {


//@line:468

        return ed::ClearSelection();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_selectNode(JNIEnv* env, jclass clazz, jlong id, jboolean append) {


//@line:472

        ed::SelectNode(id, append);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_selectLink(JNIEnv* env, jclass clazz, jlong id, jboolean append) {


//@line:476

        ed::SelectLink(id, append);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_deselectNode(JNIEnv* env, jclass clazz, jlong id) {


//@line:480

        ed::DeselectNode(id);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_deselectLink(JNIEnv* env, jclass clazz, jlong id) {


//@line:484

        ed::DeselectLink(id);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_deleteNode(JNIEnv* env, jclass clazz, jlong nodeId) {


//@line:488

        return ed::DeleteNode(nodeId);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_deleteLink(JNIEnv* env, jclass clazz, jlong linkId) {


//@line:492

        return ed::DeleteLink(linkId);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_enableShortcuts(JNIEnv* env, jclass clazz, jboolean enable) {


//@line:496

        ed::EnableShortcuts(enable);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_areShortcutsEnabled(JNIEnv* env, jclass clazz) {


//@line:500

        return ed::AreShortcutsEnabled();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_beginShortcut(JNIEnv* env, jclass clazz) {


//@line:504

        return ed::BeginShortcut();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_acceptCut(JNIEnv* env, jclass clazz) {


//@line:508

        return ed::AcceptCut();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_acceptCopy(JNIEnv* env, jclass clazz) {


//@line:512

        return ed::AcceptCopy();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_acceptPaste(JNIEnv* env, jclass clazz) {


//@line:516

        return ed::AcceptPaste();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_acceptDuplicate(JNIEnv* env, jclass clazz) {


//@line:520

        return ed::AcceptDuplicate();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_nodeditor_NodeEditor_acceptCreateNode(JNIEnv* env, jclass clazz) {


//@line:524

        return ed::AcceptCreateNode();
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_nodeditor_NodeEditor_getActionContextSize(JNIEnv* env, jclass clazz) {


//@line:528

        return ed::GetActionContextSize();
    

}

static inline jint wrapped_Java_imgui_extension_nodeditor_NodeEditor_getActionContextNodes
(JNIEnv* env, jclass clazz, jlongArray obj_nodes, jint size, long long* nodes) {

//@line:532

        return ed::GetActionContextNodes((ed::NodeId*)&nodes[0], size);
    
}

JNIEXPORT jint JNICALL Java_imgui_extension_nodeditor_NodeEditor_getActionContextNodes(JNIEnv* env, jclass clazz, jlongArray obj_nodes, jint size) {
	long long* nodes = (long long*)env->GetPrimitiveArrayCritical(obj_nodes, 0);

	jint JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_getActionContextNodes(env, clazz, obj_nodes, size, nodes);

	env->ReleasePrimitiveArrayCritical(obj_nodes, nodes, 0);

	return JNI_returnValue;
}

static inline jint wrapped_Java_imgui_extension_nodeditor_NodeEditor_getActionContextLinks
(JNIEnv* env, jclass clazz, jlongArray obj_links, jint size, long long* links) {

//@line:536

        return ed::GetActionContextLinks((ed::LinkId*)&links[0], size);
    
}

JNIEXPORT jint JNICALL Java_imgui_extension_nodeditor_NodeEditor_getActionContextLinks(JNIEnv* env, jclass clazz, jlongArray obj_links, jint size) {
	long long* links = (long long*)env->GetPrimitiveArrayCritical(obj_links, 0);

	jint JNI_returnValue = wrapped_Java_imgui_extension_nodeditor_NodeEditor_getActionContextLinks(env, clazz, obj_links, size, links);

	env->ReleasePrimitiveArrayCritical(obj_links, links, 0);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditor_endShortcut(JNIEnv* env, jclass clazz) {


//@line:540

        ed::EndShortcut();
    

}


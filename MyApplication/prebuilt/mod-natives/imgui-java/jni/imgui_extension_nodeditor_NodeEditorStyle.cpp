#include <imgui_extension_nodeditor_NodeEditorStyle.h>

//@line:13

        #include "_nodeeditor.h"

        namespace ed = ax::NodeEditor;

        #define IM_NODE_EDITOR_STYLE ((ed::Style*)STRUCT_PTR)
     JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getNodePadding(JNIEnv* env, jobject object, jobject dstImVec4) {


//@line:28

        Jni::ImVec4Cpy(env, IM_NODE_EDITOR_STYLE->NodePadding, dstImVec4);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setNodePadding(JNIEnv* env, jobject object, jfloat x, jfloat y, jfloat z, jfloat w) {


//@line:32

        IM_NODE_EDITOR_STYLE->NodePadding.x = x;
        IM_NODE_EDITOR_STYLE->NodePadding.y = y;
        IM_NODE_EDITOR_STYLE->NodePadding.z = z;
        IM_NODE_EDITOR_STYLE->NodePadding.w = w;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getNodeRounding(JNIEnv* env, jobject object) {


//@line:39

       return IM_NODE_EDITOR_STYLE->NodeRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setNodeRounding(JNIEnv* env, jobject object, jfloat nodeRounding) {


//@line:43

       IM_NODE_EDITOR_STYLE->NodeRounding = nodeRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getNodeBorderWidth(JNIEnv* env, jobject object) {


//@line:47

       return IM_NODE_EDITOR_STYLE->NodeBorderWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setNodeBorderWidth(JNIEnv* env, jobject object, jfloat nodeBorderWidth) {


//@line:51

       IM_NODE_EDITOR_STYLE->NodeBorderWidth = nodeBorderWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getHoveredNodeBorderWidth(JNIEnv* env, jobject object) {


//@line:55

       return IM_NODE_EDITOR_STYLE->HoveredNodeBorderWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setHoveredNodeBorderWidth(JNIEnv* env, jobject object, jfloat hoveredNodeBorderWidth) {


//@line:59

       IM_NODE_EDITOR_STYLE->HoveredNodeBorderWidth = hoveredNodeBorderWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getSelectedNodeBorderWidth(JNIEnv* env, jobject object) {


//@line:63

       return IM_NODE_EDITOR_STYLE->SelectedNodeBorderWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setSelectedNodeBorderWidth(JNIEnv* env, jobject object, jfloat selectedNodeBorderWidth) {


//@line:67

       IM_NODE_EDITOR_STYLE->SelectedNodeBorderWidth = selectedNodeBorderWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPinRounding(JNIEnv* env, jobject object) {


//@line:71

       return IM_NODE_EDITOR_STYLE->PinRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPinRounding(JNIEnv* env, jobject object, jfloat pinRounding) {


//@line:75

       IM_NODE_EDITOR_STYLE->PinRounding = pinRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPinBorderWidth(JNIEnv* env, jobject object) {


//@line:79

       return IM_NODE_EDITOR_STYLE->PinBorderWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPinBorderWidth(JNIEnv* env, jobject object, jfloat pinBorderWidth) {


//@line:83

       IM_NODE_EDITOR_STYLE->PinBorderWidth = pinBorderWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getLinkStrength(JNIEnv* env, jobject object) {


//@line:87

       return IM_NODE_EDITOR_STYLE->LinkStrength;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setLinkStrength(JNIEnv* env, jobject object, jfloat linkStrength) {


//@line:91

       IM_NODE_EDITOR_STYLE->LinkStrength = linkStrength;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getSourceDirection(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:101

       Jni::ImVec2Cpy(env, &IM_NODE_EDITOR_STYLE->SourceDirection, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getSourceDirectionX(JNIEnv* env, jobject object) {


//@line:105

       return IM_NODE_EDITOR_STYLE->SourceDirection.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getSourceDirectionY(JNIEnv* env, jobject object) {


//@line:109

       return IM_NODE_EDITOR_STYLE->SourceDirection.y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setSourceDirection(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:113

       IM_NODE_EDITOR_STYLE->SourceDirection.x = x;
       IM_NODE_EDITOR_STYLE->SourceDirection.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getTargetDirection(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:124

       Jni::ImVec2Cpy(env, &IM_NODE_EDITOR_STYLE->TargetDirection, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getTargetDirectionX(JNIEnv* env, jobject object) {


//@line:129

       return IM_NODE_EDITOR_STYLE->TargetDirection.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getTargetDirectionY(JNIEnv* env, jobject object) {


//@line:133

       return IM_NODE_EDITOR_STYLE->TargetDirection.y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setTargetDirection(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:137

       IM_NODE_EDITOR_STYLE->TargetDirection.x = x;
       IM_NODE_EDITOR_STYLE->TargetDirection.y = y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getScrollDuration(JNIEnv* env, jobject object) {


//@line:142

       return IM_NODE_EDITOR_STYLE->ScrollDuration;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setScrollDuration(JNIEnv* env, jobject object, jfloat scrollDuration) {


//@line:146

       IM_NODE_EDITOR_STYLE->ScrollDuration = scrollDuration;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getFlowMarkerDistance(JNIEnv* env, jobject object) {


//@line:150

       return IM_NODE_EDITOR_STYLE->FlowMarkerDistance;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setFlowMarkerDistance(JNIEnv* env, jobject object, jfloat flowMarkerDistance) {


//@line:154

       IM_NODE_EDITOR_STYLE->FlowMarkerDistance = flowMarkerDistance;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getFlowSpeed(JNIEnv* env, jobject object) {


//@line:158

       return IM_NODE_EDITOR_STYLE->FlowSpeed;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setFlowSpeed(JNIEnv* env, jobject object, jfloat flowSpeed) {


//@line:162

       IM_NODE_EDITOR_STYLE->FlowSpeed = flowSpeed;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getFlowDuration(JNIEnv* env, jobject object) {


//@line:166

       return IM_NODE_EDITOR_STYLE->FlowDuration;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setFlowDuration(JNIEnv* env, jobject object, jfloat flowDuration) {


//@line:170

       IM_NODE_EDITOR_STYLE->FlowDuration = flowDuration;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotAlignment(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:180

       Jni::ImVec2Cpy(env, &IM_NODE_EDITOR_STYLE->PivotAlignment, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotAlignmentX(JNIEnv* env, jobject object) {


//@line:184

       return IM_NODE_EDITOR_STYLE->PivotAlignment.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotAlignmentY(JNIEnv* env, jobject object) {


//@line:188

       return IM_NODE_EDITOR_STYLE->PivotAlignment.y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPivotAlignment(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:192

       IM_NODE_EDITOR_STYLE->PivotAlignment.x = x;
       IM_NODE_EDITOR_STYLE->PivotAlignment.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotSize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:203

       Jni::ImVec2Cpy(env, &IM_NODE_EDITOR_STYLE->PivotSize, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotSizeX(JNIEnv* env, jobject object) {


//@line:207

       return IM_NODE_EDITOR_STYLE->PivotSize.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotSizeY(JNIEnv* env, jobject object) {


//@line:211

       return IM_NODE_EDITOR_STYLE->PivotSize.y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPivotSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:215

       IM_NODE_EDITOR_STYLE->PivotSize.x = x;
       IM_NODE_EDITOR_STYLE->PivotSize.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotScale(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:226

       Jni::ImVec2Cpy(env, &IM_NODE_EDITOR_STYLE->PivotScale, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotScaleX(JNIEnv* env, jobject object) {


//@line:230

       return IM_NODE_EDITOR_STYLE->PivotScale.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPivotScaleY(JNIEnv* env, jobject object) {


//@line:234

       return IM_NODE_EDITOR_STYLE->PivotScale.y;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPivotScale(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:238

       IM_NODE_EDITOR_STYLE->PivotScale.x = x;
       IM_NODE_EDITOR_STYLE->PivotScale.y = y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPinCorners(JNIEnv* env, jobject object) {


//@line:243

       return IM_NODE_EDITOR_STYLE->PinCorners;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPinCorners(JNIEnv* env, jobject object, jfloat pinCorners) {


//@line:247

       IM_NODE_EDITOR_STYLE->PinCorners = pinCorners;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPinRadius(JNIEnv* env, jobject object) {


//@line:251

       return IM_NODE_EDITOR_STYLE->PinRadius;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPinRadius(JNIEnv* env, jobject object, jfloat pinRadius) {


//@line:255

       IM_NODE_EDITOR_STYLE->PinRadius = pinRadius;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPinArrowSize(JNIEnv* env, jobject object) {


//@line:259

       return IM_NODE_EDITOR_STYLE->PinArrowSize;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPinArrowSize(JNIEnv* env, jobject object, jfloat pinArrowSize) {


//@line:263

       IM_NODE_EDITOR_STYLE->PinArrowSize = pinArrowSize;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getPinArrowWidth(JNIEnv* env, jobject object) {


//@line:267

       return IM_NODE_EDITOR_STYLE->PinArrowWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setPinArrowWidth(JNIEnv* env, jobject object, jfloat pinArrowWidth) {


//@line:271

       IM_NODE_EDITOR_STYLE->PinArrowWidth = pinArrowWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getGroupRounding(JNIEnv* env, jobject object) {


//@line:275

       return IM_NODE_EDITOR_STYLE->GroupRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setGroupRounding(JNIEnv* env, jobject object, jfloat groupRounding) {


//@line:279

       IM_NODE_EDITOR_STYLE->GroupRounding = groupRounding;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getGroupBorderWidth(JNIEnv* env, jobject object) {


//@line:283

       return IM_NODE_EDITOR_STYLE->GroupBorderWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setGroupBorderWidth(JNIEnv* env, jobject object, jfloat groupBorderWidth) {


//@line:287

       IM_NODE_EDITOR_STYLE->GroupBorderWidth = groupBorderWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getColors(JNIEnv* env, jobject object, jobjectArray buff) {


//@line:297

        for (int i = 0; i < ed::StyleColor_Count; i++) {
            jfloatArray jColors = (jfloatArray)env->GetObjectArrayElement(buff, i);
            jfloat* jBuffColor = env->GetFloatArrayElements(jColors, 0);

            jBuffColor[0] = IM_NODE_EDITOR_STYLE->Colors[i].x;
            jBuffColor[1] = IM_NODE_EDITOR_STYLE->Colors[i].y;
            jBuffColor[2] = IM_NODE_EDITOR_STYLE->Colors[i].z;
            jBuffColor[3] = IM_NODE_EDITOR_STYLE->Colors[i].w;

            env->ReleaseFloatArrayElements(jColors, jBuffColor, 0);
            env->DeleteLocalRef(jColors);
        }
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setColors(JNIEnv* env, jobject object, jobjectArray colors) {


//@line:315

        for (int i = 0; i < ed::StyleColor_Count; i++) {
            jfloatArray jColors = (jfloatArray)env->GetObjectArrayElement(colors, i);
            jfloat* jColor = env->GetFloatArrayElements(jColors, 0);

            IM_NODE_EDITOR_STYLE->Colors[i].x = jColor[0];
            IM_NODE_EDITOR_STYLE->Colors[i].y = jColor[1];
            IM_NODE_EDITOR_STYLE->Colors[i].z = jColor[2];
            IM_NODE_EDITOR_STYLE->Colors[i].w = jColor[3];

            env->ReleaseFloatArrayElements(jColors, jColor, 0);
            env->DeleteLocalRef(jColors);
        }
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_getColor(JNIEnv* env, jobject object, jint styleColor, jobject dstImVec4) {


//@line:336

        Jni::ImVec4Cpy(env, IM_NODE_EDITOR_STYLE->Colors[styleColor], dstImVec4);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setColor__IFFFF(JNIEnv* env, jobject object, jint styleColor, jfloat r, jfloat g, jfloat b, jfloat a) {


//@line:340

        IM_NODE_EDITOR_STYLE->Colors[styleColor] = ImColor((float)r, (float)g, (float)b, (float)a);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setColor__IIIII(JNIEnv* env, jobject object, jint styleColor, jint r, jint g, jint b, jint a) {


//@line:344

        IM_NODE_EDITOR_STYLE->Colors[styleColor] = ImColor((int)r, (int)g, (int)b, (int)a);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorStyle_setColor__II(JNIEnv* env, jobject object, jint styleColor, jint col) {


//@line:348

        IM_NODE_EDITOR_STYLE->Colors[styleColor] = ImColor(col);
    

}


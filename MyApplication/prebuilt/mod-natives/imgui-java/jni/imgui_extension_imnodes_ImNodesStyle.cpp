#include <imgui_extension_imnodes_ImNodesStyle.h>

//@line:11

        #include "_imnodes.h"

        #define IMNODES_STYLE ((ImNodesStyle*)STRUCT_PTR)
     JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getGridSpacing(JNIEnv* env, jobject object) {


//@line:17

       return IMNODES_STYLE->GridSpacing;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setGridSpacing(JNIEnv* env, jobject object, jfloat gridSpacing) {


//@line:21

       IMNODES_STYLE->GridSpacing = gridSpacing;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getNodeCornerRounding(JNIEnv* env, jobject object) {


//@line:25

       return IMNODES_STYLE->NodeCornerRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setNodeCornerRounding(JNIEnv* env, jobject object, jfloat nodeCornerRounding) {


//@line:29

       IMNODES_STYLE->NodeCornerRounding = nodeCornerRounding;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getNodePadding(JNIEnv* env, jobject object, jobject result) {


//@line:33

       Jni::ImVec2Cpy(env, &IMNODES_STYLE->NodePadding, result);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setNodePadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:37

       IMNODES_STYLE->NodePadding = ImVec2(x, y);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getNodeBorderThickness(JNIEnv* env, jobject object) {


//@line:41

       return IMNODES_STYLE->NodeBorderThickness;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setNodeBorderThickness(JNIEnv* env, jobject object, jfloat nodeBorderThickness) {


//@line:45

       IMNODES_STYLE->NodeBorderThickness = nodeBorderThickness;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getLinkThickness(JNIEnv* env, jobject object) {


//@line:49

       return IMNODES_STYLE->LinkThickness;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setLinkThickness(JNIEnv* env, jobject object, jfloat linkThickness) {


//@line:53

       IMNODES_STYLE->LinkThickness = linkThickness;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getLinkLineSegmentsPerLength(JNIEnv* env, jobject object) {


//@line:57

       return IMNODES_STYLE->LinkLineSegmentsPerLength;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setLinkLineSegmentsPerLength(JNIEnv* env, jobject object, jfloat linkLineSegmentsPerLength) {


//@line:61

       IMNODES_STYLE->LinkLineSegmentsPerLength = linkLineSegmentsPerLength;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getLinkHoverDistance(JNIEnv* env, jobject object) {


//@line:65

       return IMNODES_STYLE->LinkHoverDistance;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setLinkHoverDistance(JNIEnv* env, jobject object, jfloat linkHoverDistance) {


//@line:69

       IMNODES_STYLE->LinkHoverDistance = linkHoverDistance;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getPinCircleRadius(JNIEnv* env, jobject object) {


//@line:76

       return IMNODES_STYLE->PinCircleRadius;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setPinCircleRadius(JNIEnv* env, jobject object, jfloat pinCircleRadius) {


//@line:83

       IMNODES_STYLE->PinCircleRadius = pinCircleRadius;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getPinQuadSideLength(JNIEnv* env, jobject object) {


//@line:90

       return IMNODES_STYLE->PinQuadSideLength;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setPinQuadSideLength(JNIEnv* env, jobject object, jfloat pinQuadSideLength) {


//@line:97

       IMNODES_STYLE->PinQuadSideLength = pinQuadSideLength;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getPinTriangleSideLength(JNIEnv* env, jobject object) {


//@line:104

       return IMNODES_STYLE->PinTriangleSideLength;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setPinTriangleSideLength(JNIEnv* env, jobject object, jfloat pinTriangleSideLength) {


//@line:111

       IMNODES_STYLE->PinTriangleSideLength = pinTriangleSideLength;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getPinLineThickness(JNIEnv* env, jobject object) {


//@line:118

       return IMNODES_STYLE->PinLineThickness;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setPinLineThickness(JNIEnv* env, jobject object, jfloat pinLineThickness) {


//@line:125

       IMNODES_STYLE->PinLineThickness = pinLineThickness;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getPinHoverRadius(JNIEnv* env, jobject object) {


//@line:132

       return IMNODES_STYLE->PinHoverRadius;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setPinHoverRadius(JNIEnv* env, jobject object, jfloat pinHoverRadius) {


//@line:139

       IMNODES_STYLE->PinHoverRadius = pinHoverRadius;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getPinOffset(JNIEnv* env, jobject object) {


//@line:146

       return IMNODES_STYLE->PinOffset;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setPinOffset(JNIEnv* env, jobject object, jfloat pinOffset) {


//@line:153

       IMNODES_STYLE->PinOffset = pinOffset;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getMiniMapPadding(JNIEnv* env, jobject object, jobject result) {


//@line:160

       Jni::ImVec2Cpy(env, &IMNODES_STYLE->MiniMapPadding, result);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setMiniMapPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:167

       IMNODES_STYLE->MiniMapPadding = ImVec2(x, y);
    

}

JNIEXPORT jobject JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getMiniMapOffset(JNIEnv* env, jobject object, jobject result) {


//@line:174

       Jni::ImVec2Cpy(env, &IMNODES_STYLE->MiniMapOffset, result);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setMiniMapOffset(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:181

       IMNODES_STYLE->MiniMapOffset = ImVec2(x, y);
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_imnodes_ImNodesStyle_getFlags(JNIEnv* env, jobject object) {


//@line:185

       return IMNODES_STYLE->Flags;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesStyle_setFlags(JNIEnv* env, jobject object, jint imNodesStyleFlags) {


//@line:189

       IMNODES_STYLE->Flags = (ImNodesStyleFlags)imNodesStyleFlags;
    

}


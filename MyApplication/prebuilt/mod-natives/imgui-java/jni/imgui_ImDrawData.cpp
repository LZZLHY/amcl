#include <imgui_ImDrawData.h>

//@line:30

        #include "_common.h"

        #define IM_DRAW_DATA ((ImDrawData*)STRUCT_PTR)
     JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListCmdBufferSize(JNIEnv* env, jobject object, jint cmdListIdx) {


//@line:41

        return IM_DRAW_DATA->CmdLists[cmdListIdx]->CmdBuffer.Size;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListCmdBufferElemCount(JNIEnv* env, jobject object, jint cmdListIdx, jint cmdBufferIdx) {


//@line:49

        return IM_DRAW_DATA->CmdLists[cmdListIdx]->CmdBuffer[cmdBufferIdx].ElemCount;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_getCmdListCmdBufferClipRect(JNIEnv* env, jobject object, jint cmdListIdx, jint cmdBufferIdx, jobject dstImVec4) {


//@line:65

        Jni::ImVec4Cpy(env, &IM_DRAW_DATA->CmdLists[cmdListIdx]->CmdBuffer[cmdBufferIdx].ClipRect, dstImVec4);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListCmdBufferTextureId(JNIEnv* env, jobject object, jint cmdListIdx, jint cmdBufferIdx) {


//@line:73

        return (intptr_t)IM_DRAW_DATA->CmdLists[cmdListIdx]->CmdBuffer[cmdBufferIdx].GetTexID();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListCmdBufferVtxOffset(JNIEnv* env, jobject object, jint cmdListIdx, jint cmdBufferIdx) {


//@line:81

        return IM_DRAW_DATA->CmdLists[cmdListIdx]->CmdBuffer[cmdBufferIdx].VtxOffset;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListCmdBufferIdxOffset(JNIEnv* env, jobject object, jint cmdListIdx, jint cmdBufferIdx) {


//@line:88

        return IM_DRAW_DATA->CmdLists[cmdListIdx]->CmdBuffer[cmdBufferIdx].IdxOffset;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListIdxBufferSize(JNIEnv* env, jobject object, jint cmdListIdx) {


//@line:95

        return IM_DRAW_DATA->CmdLists[cmdListIdx]->IdxBuffer.Size;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_nGetCmdListIdxBufferData(JNIEnv* env, jobject object, jint cmdListIdx, jobject obj_idxBuffer, jint idxBufferCapacity) {
	char* idxBuffer = (char*)(obj_idxBuffer?env->GetDirectBufferAddress(obj_idxBuffer):0);


//@line:114

        memcpy(idxBuffer, IM_DRAW_DATA->CmdLists[cmdListIdx]->IdxBuffer.Data, idxBufferCapacity);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListVtxBufferSize(JNIEnv* env, jobject object, jint cmdListIdx) {


//@line:121

        return IM_DRAW_DATA->CmdLists[cmdListIdx]->VtxBuffer.Size;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_nGetCmdListVtxBufferData(JNIEnv* env, jobject object, jint cmdListIdx, jobject obj_vtxBuffer, jint vtxBufferCapacity) {
	char* vtxBuffer = (char*)(obj_vtxBuffer?env->GetDirectBufferAddress(obj_vtxBuffer):0);


//@line:140

        memcpy(vtxBuffer, IM_DRAW_DATA->CmdLists[cmdListIdx]->VtxBuffer.Data, vtxBufferCapacity);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_sizeOfImDrawVert(JNIEnv* env, jclass clazz) {


//@line:144

        return (int)sizeof(ImDrawVert);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_sizeOfImDrawIdx(JNIEnv* env, jclass clazz) {


//@line:148

        return (int)sizeof(ImDrawIdx);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImDrawData_getValid(JNIEnv* env, jobject object) {


//@line:157

        return IM_DRAW_DATA->Valid;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getCmdListsCount(JNIEnv* env, jobject object) {


//@line:164

        return IM_DRAW_DATA->CmdListsCount;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getTotalIdxCount(JNIEnv* env, jobject object) {


//@line:171

        return IM_DRAW_DATA->TotalIdxCount;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImDrawData_getTotalVtxCount(JNIEnv* env, jobject object) {


//@line:178

        return IM_DRAW_DATA->TotalVtxCount;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_getDisplayPos(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:194

        Jni::ImVec2Cpy(env, &IM_DRAW_DATA->DisplayPos, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawData_getDisplayPosX(JNIEnv* env, jobject object) {


//@line:201

        return IM_DRAW_DATA->DisplayPos.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawData_getDisplayPosY(JNIEnv* env, jobject object) {


//@line:208

        return IM_DRAW_DATA->DisplayPos.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_getDisplaySize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:226

        Jni::ImVec2Cpy(env, &IM_DRAW_DATA->DisplaySize, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawData_getDisplaySizeX(JNIEnv* env, jobject object) {


//@line:234

        return IM_DRAW_DATA->DisplaySize.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawData_getDisplaySizeY(JNIEnv* env, jobject object) {


//@line:242

        return IM_DRAW_DATA->DisplaySize.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_getFramebufferScale(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:258

        Jni::ImVec2Cpy(env, &IM_DRAW_DATA->FramebufferScale, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawData_getFramebufferScaleX(JNIEnv* env, jobject object) {


//@line:265

        return IM_DRAW_DATA->FramebufferScale.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawData_getFramebufferScaleY(JNIEnv* env, jobject object) {


//@line:272

        return IM_DRAW_DATA->FramebufferScale.y;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImDrawData_nGetOwnerViewport(JNIEnv* env, jobject object) {


//@line:284

        return (intptr_t)IM_DRAW_DATA->OwnerViewport;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_deIndexAllBuffers(JNIEnv* env, jobject object) {


//@line:294

        IM_DRAW_DATA->DeIndexAllBuffers();
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawData_scaleClipRects(JNIEnv* env, jobject object, jfloat fbScaleX, jfloat fbScaleY) {


//@line:302

        const ImVec2 fbScale = ImVec2(fbScaleX, fbScaleY);
        IM_DRAW_DATA->ScaleClipRects(fbScale);
    

}


#include <imgui_ImGuiViewport.h>

//@line:17

        #include "_common.h"

        #define IMGUI_VIEWPORT ((ImGuiViewport*)STRUCT_PTR)
     JNIEXPORT jint JNICALL Java_imgui_ImGuiViewport_getID(JNIEnv* env, jobject object) {


//@line:26

        return IMGUI_VIEWPORT->ID;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setID(JNIEnv* env, jobject object, jint imGuiID) {


//@line:33

        IMGUI_VIEWPORT->ID = imGuiID;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiViewport_getFlags(JNIEnv* env, jobject object) {


//@line:40

        return IMGUI_VIEWPORT->Flags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setFlags(JNIEnv* env, jobject object, jint flags) {


//@line:47

        IMGUI_VIEWPORT->Flags = flags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_getPos(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:84

        Jni::ImVec2Cpy(env, &IMGUI_VIEWPORT->Pos, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getPosX(JNIEnv* env, jobject object) {


//@line:91

        return IMGUI_VIEWPORT->Pos.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getPosY(JNIEnv* env, jobject object) {


//@line:98

        return IMGUI_VIEWPORT->Pos.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setPos(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:105

        IMGUI_VIEWPORT->Pos = ImVec2(x, y);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_getSize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:121

        Jni::ImVec2Cpy(env, &IMGUI_VIEWPORT->Size, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getSizeX(JNIEnv* env, jobject object) {


//@line:128

        return IMGUI_VIEWPORT->Size.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getSizeY(JNIEnv* env, jobject object) {


//@line:135

        return IMGUI_VIEWPORT->Size.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_seSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:142

        IMGUI_VIEWPORT->Size = ImVec2(x, y);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_getWorkPos(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:158

        Jni::ImVec2Cpy(env, IMGUI_VIEWPORT->WorkPos, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getWorkPosX(JNIEnv* env, jobject object) {


//@line:165

        return IMGUI_VIEWPORT->WorkPos.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getWorkPosY(JNIEnv* env, jobject object) {


//@line:172

        return IMGUI_VIEWPORT->WorkPos.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setWorkPos(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:179

        IMGUI_VIEWPORT->WorkPos = ImVec2(x, y);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_getWorkSize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:195

        Jni::ImVec2Cpy(env, IMGUI_VIEWPORT->WorkSize, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getWorkSizeX(JNIEnv* env, jobject object) {


//@line:202

        return IMGUI_VIEWPORT->WorkSize.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getWorkSizeY(JNIEnv* env, jobject object) {


//@line:209

        return IMGUI_VIEWPORT->WorkSize.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setWorkSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:216

        IMGUI_VIEWPORT->WorkSize = ImVec2(x, y);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getDpiScale(JNIEnv* env, jobject object) {


//@line:223

        return IMGUI_VIEWPORT->DpiScale;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setDpiScale(JNIEnv* env, jobject object, jfloat dpiScale) {


//@line:230

        IMGUI_VIEWPORT->DpiScale = dpiScale;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiViewport_getParentViewportId(JNIEnv* env, jobject object) {


//@line:237

        return IMGUI_VIEWPORT->ParentViewportId;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setParentViewportId(JNIEnv* env, jobject object, jint parentViewportId) {


//@line:244

        IMGUI_VIEWPORT->ParentViewportId = parentViewportId;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGuiViewport_nGetDrawData(JNIEnv* env, jobject object) {


//@line:256

        return (intptr_t)IMGUI_VIEWPORT->DrawData;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setRendererUserData(JNIEnv* env, jobject object, jobject data) {


//@line:268

        if (IMGUI_VIEWPORT->RendererUserData != NULL) {
            env->DeleteGlobalRef((jobject)IMGUI_VIEWPORT->RendererUserData);
        }
        IMGUI_VIEWPORT->RendererUserData = (data == NULL ? NULL : (void*)env->NewGlobalRef(data));
    

}

JNIEXPORT jobject JNICALL Java_imgui_ImGuiViewport_getRendererUserData(JNIEnv* env, jobject object) {


//@line:278

        return (jobject)IMGUI_VIEWPORT->RendererUserData;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setPlatformUserData(JNIEnv* env, jobject object, jobject data) {


//@line:285

        if (IMGUI_VIEWPORT->PlatformUserData != NULL) {
            env->DeleteGlobalRef((jobject)IMGUI_VIEWPORT->PlatformUserData);
        }
        IMGUI_VIEWPORT->PlatformUserData = (data == NULL ? NULL : (void*)env->NewGlobalRef(data));
    

}

JNIEXPORT jobject JNICALL Java_imgui_ImGuiViewport_getPlatformUserData(JNIEnv* env, jobject object) {


//@line:295

        return (jobject)IMGUI_VIEWPORT->PlatformUserData;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setPlatformHandle(JNIEnv* env, jobject object, jlong data) {


//@line:302

        IMGUI_VIEWPORT->PlatformHandle = (void*)data;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGuiViewport_getPlatformHandle(JNIEnv* env, jobject object) {


//@line:309

        return (intptr_t)IMGUI_VIEWPORT->PlatformHandle;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setPlatformHandleRaw(JNIEnv* env, jobject object, jlong data) {


//@line:316

        IMGUI_VIEWPORT->PlatformHandleRaw = (void*)data;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGuiViewport_getPlatformHandleRaw(JNIEnv* env, jobject object) {


//@line:323

        return (intptr_t)IMGUI_VIEWPORT->PlatformHandleRaw;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiViewport_getPlatformRequestMove(JNIEnv* env, jobject object) {


//@line:330

        return IMGUI_VIEWPORT->PlatformRequestMove;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setPlatformRequestMove(JNIEnv* env, jobject object, jboolean platformRequestMove) {


//@line:337

        IMGUI_VIEWPORT->PlatformRequestMove = platformRequestMove;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiViewport_getPlatformRequestResize(JNIEnv* env, jobject object) {


//@line:344

        return IMGUI_VIEWPORT->PlatformRequestResize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setPlatformRequestResize(JNIEnv* env, jobject object, jboolean platformRequestResize) {


//@line:351

        IMGUI_VIEWPORT->PlatformRequestResize = platformRequestResize;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiViewport_getPlatformRequestClose(JNIEnv* env, jobject object) {


//@line:358

        return IMGUI_VIEWPORT->PlatformRequestClose;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_setPlatformRequestClose(JNIEnv* env, jobject object, jboolean platformRequestClose) {


//@line:365

        IMGUI_VIEWPORT->PlatformRequestClose = platformRequestClose;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_getCenter(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:377

        Jni::ImVec2Cpy(env, IMGUI_VIEWPORT->GetCenter(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getCenterX(JNIEnv* env, jobject object) {


//@line:381

        return IMGUI_VIEWPORT->GetCenter().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getCenterY(JNIEnv* env, jobject object) {


//@line:385

        return IMGUI_VIEWPORT->GetCenter().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiViewport_getWorkCenter(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:395

        Jni::ImVec2Cpy(env, IMGUI_VIEWPORT->GetWorkCenter(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getWorkCenterX(JNIEnv* env, jobject object) {


//@line:399

        return IMGUI_VIEWPORT->GetWorkCenter().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiViewport_getWorkCenterY(JNIEnv* env, jobject object) {


//@line:403

        return IMGUI_VIEWPORT->GetWorkCenter().y;
    

}


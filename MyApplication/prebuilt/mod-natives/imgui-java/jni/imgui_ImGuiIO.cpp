#include <imgui_ImGuiIO.h>

//@line:18

        #include "_common.h"

        #define IO ((ImGuiIO*)STRUCT_PTR)
     JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getConfigFlags(JNIEnv* env, jobject object) {


//@line:31

        return IO->ConfigFlags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigFlags(JNIEnv* env, jobject object, jint configFlags) {


//@line:38

        IO->ConfigFlags = configFlags;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getBackendFlags(JNIEnv* env, jobject object) {


//@line:66

        return IO->BackendFlags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setBackendFlags(JNIEnv* env, jobject object, jint backendFlags) {


//@line:73

        IO->BackendFlags = backendFlags;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getIniSavingRate(JNIEnv* env, jobject object) {


//@line:101

        return IO->IniSavingRate;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setIniSavingRate(JNIEnv* env, jobject object, jfloat iniSavingRate) {


//@line:108

        IO->IniSavingRate = iniSavingRate;
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGuiIO_getIniFilename(JNIEnv* env, jobject object) {


//@line:115

        return env->NewStringUTF(IO->IniFilename);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setIniFilename(JNIEnv* env, jobject object, jstring obj_iniFilename) {

//@line:122

        IO->IniFilename = obj_iniFilename == NULL ? NULL : (char*)env->GetStringUTFChars(obj_iniFilename, JNI_FALSE);
    
}

JNIEXPORT jstring JNICALL Java_imgui_ImGuiIO_getLogFilename(JNIEnv* env, jobject object) {


//@line:129

        return env->NewStringUTF(IO->LogFilename);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setLogFilename(JNIEnv* env, jobject object, jstring obj_logFilename) {

//@line:136

        IO->LogFilename = obj_logFilename == NULL ? NULL : (char*)env->GetStringUTFChars(obj_logFilename, JNI_FALSE);
    
}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseDoubleClickTime(JNIEnv* env, jobject object) {


//@line:143

        return IO->MouseDoubleClickTime;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseDoubleClickTime(JNIEnv* env, jobject object, jfloat mouseDoubleClickTime) {


//@line:150

        IO->MouseDoubleClickTime = mouseDoubleClickTime;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseDoubleClickMaxDist(JNIEnv* env, jobject object) {


//@line:157

        return IO->MouseDoubleClickTime;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseDoubleClickMaxDist(JNIEnv* env, jobject object, jfloat mouseDoubleClickMaxDist) {


//@line:164

        IO->MouseDoubleClickMaxDist = mouseDoubleClickMaxDist;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseDragThreshold(JNIEnv* env, jobject object) {


//@line:171

        return IO->MouseDoubleClickTime;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseDragThreshold(JNIEnv* env, jobject object, jfloat mouseDragThreshold) {


//@line:178

        IO->MouseDragThreshold = mouseDragThreshold;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getKeyMap___3I(JNIEnv* env, jobject object, jintArray obj_buff) {
	int* buff = (int*)env->GetPrimitiveArrayCritical(obj_buff, 0);


//@line:185

        for(int i = 0; i < ImGuiKey_COUNT; i++)
            buff[i] = IO->KeyMap[i];
    
	env->ReleasePrimitiveArrayCritical(obj_buff, buff, 0);

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getKeyMap__I(JNIEnv* env, jobject object, jint idx) {


//@line:193

        return IO->KeyMap[idx];
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeyMap__II(JNIEnv* env, jobject object, jint idx, jint code) {


//@line:200

        IO->KeyMap[idx] = code;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeyMap___3I(JNIEnv* env, jobject object, jintArray obj_keyMap) {
	int* keyMap = (int*)env->GetPrimitiveArrayCritical(obj_keyMap, 0);


//@line:207

        for (int i = 0; i < ImGuiKey_COUNT; i++)
            IO->KeyMap[i] = keyMap[i];
    
	env->ReleasePrimitiveArrayCritical(obj_keyMap, keyMap, 0);

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getKeyRepeatDelay(JNIEnv* env, jobject object) {


//@line:215

        return IO->KeyRepeatDelay;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeyRepeatDelay(JNIEnv* env, jobject object, jfloat keyRepeatDelay) {


//@line:222

        IO->KeyRepeatDelay = keyRepeatDelay;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getKeyRepeatRate(JNIEnv* env, jobject object) {


//@line:229

        return IO->KeyRepeatRate;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeyRepeatRate(JNIEnv* env, jobject object, jfloat keyRepeatRate) {


//@line:236

        IO->KeyRepeatRate = keyRepeatRate;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGuiIO_nGetFonts(JNIEnv* env, jobject object) {


//@line:248

        return (intptr_t)IO->Fonts;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_nSetFonts(JNIEnv* env, jobject object, jlong imFontAtlasPtr) {


//@line:262

        IO->Fonts = (ImFontAtlas*)imFontAtlasPtr;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getFontGlobalScale(JNIEnv* env, jobject object) {


//@line:269

        return IO->FontGlobalScale;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setFontGlobalScale(JNIEnv* env, jobject object, jfloat fontGlobalScale) {


//@line:276

        IO->FontGlobalScale = fontGlobalScale;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getFontAllowUserScaling(JNIEnv* env, jobject object) {


//@line:283

        return IO->FontAllowUserScaling;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setFontAllowUserScaling(JNIEnv* env, jobject object, jboolean fontAllowUserScaling) {


//@line:290

        IO->FontAllowUserScaling = fontAllowUserScaling;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_nSetFontDefault(JNIEnv* env, jobject object, jlong fontDefaultPtr) {


//@line:298

        IO->FontDefault = (ImFont*)fontDefaultPtr;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getMouseDrawCursor(JNIEnv* env, jobject object) {


//@line:308

        return IO->MouseDrawCursor;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseDrawCursor(JNIEnv* env, jobject object, jboolean mouseDrawCursor) {


//@line:316

        IO->MouseDrawCursor = mouseDrawCursor;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigMacOSXBehaviors(JNIEnv* env, jobject object) {


//@line:325

        return IO->ConfigMacOSXBehaviors;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigMacOSXBehaviors(JNIEnv* env, jobject object, jboolean configMacOSXBehaviors) {


//@line:334

        IO->ConfigMacOSXBehaviors = configMacOSXBehaviors;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigInputTextCursorBlink(JNIEnv* env, jobject object) {


//@line:341

        return IO->ConfigInputTextCursorBlink;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigInputTextCursorBlink(JNIEnv* env, jobject object, jboolean configInputTextCursorBlink) {


//@line:348

        IO->ConfigInputTextCursorBlink = configInputTextCursorBlink;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigDragClickToInputText(JNIEnv* env, jobject object) {


//@line:355

        return IO->ConfigDragClickToInputText;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigDragClickToInputText(JNIEnv* env, jobject object, jboolean configDragClickToInputText) {


//@line:362

        IO->ConfigDragClickToInputText = configDragClickToInputText;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigWindowsResizeFromEdges(JNIEnv* env, jobject object) {


//@line:371

        return IO->ConfigWindowsResizeFromEdges;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigWindowsResizeFromEdges(JNIEnv* env, jobject object, jboolean configWindowsResizeFromEdges) {


//@line:380

        IO->ConfigWindowsResizeFromEdges = configWindowsResizeFromEdges;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigWindowsMoveFromTitleBarOnly(JNIEnv* env, jobject object) {


//@line:387

        return IO->ConfigWindowsMoveFromTitleBarOnly;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigWindowsMoveFromTitleBarOnly(JNIEnv* env, jobject object, jboolean configWindowsMoveFromTitleBarOnly) {


//@line:394

        IO->ConfigWindowsMoveFromTitleBarOnly = configWindowsMoveFromTitleBarOnly;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getConfigMemoryCompactTimer(JNIEnv* env, jobject object) {


//@line:401

        return IO->ConfigMemoryCompactTimer;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigMemoryCompactTimer(JNIEnv* env, jobject object, jfloat configMemoryCompactTimer) {


//@line:408

        IO->ConfigMemoryCompactTimer = configMemoryCompactTimer;
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGuiIO_getBackendPlatformName(JNIEnv* env, jobject object) {


//@line:419

        return env->NewStringUTF(IO->BackendPlatformName);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setBackendPlatformName(JNIEnv* env, jobject object, jstring obj_backendPlatformName) {

//@line:426

        IO->BackendPlatformName = obj_backendPlatformName == NULL ? NULL : (char*)env->GetStringUTFChars(obj_backendPlatformName, JNI_FALSE);
    
}

JNIEXPORT jstring JNICALL Java_imgui_ImGuiIO_getBackendRendererName(JNIEnv* env, jobject object) {


//@line:433

        return env->NewStringUTF(IO->BackendRendererName);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setBackendRendererName(JNIEnv* env, jobject object, jstring obj_backendRendererName) {

//@line:440

        IO->BackendRendererName = obj_backendRendererName == NULL ? NULL : (char*)env->GetStringUTFChars(obj_backendRendererName, JNI_FALSE);
    
}


//@line:447

        jobject _setClipboardTextCallback = NULL;
        jobject _getClipboardTextCallback = NULL;

        void setClipboardTextStub(void* userData, const char* text) {
            Jni::CallImStrConsumer(Jni::GetEnv(), _setClipboardTextCallback, text);
        }

        const char* getClipboardTextStub(void* user_data) {
            JNIEnv* env = Jni::GetEnv();
            jstring jstr = Jni::CallImStrSupplier(env, _getClipboardTextCallback);
            return env->GetStringUTFChars(jstr, 0);
        }
     JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setSetClipboardTextFn(JNIEnv* env, jobject object, jobject setClipboardTextCallback) {


//@line:462

        if (_setClipboardTextCallback != NULL) {
            env->DeleteGlobalRef(_setClipboardTextCallback);
        }

        _setClipboardTextCallback = env->NewGlobalRef(setClipboardTextCallback);
        IO->SetClipboardTextFn = setClipboardTextStub;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setGetClipboardTextFn(JNIEnv* env, jobject object, jobject getClipboardTextCallback) {


//@line:471

        if (_getClipboardTextCallback != NULL) {
            env->DeleteGlobalRef(_getClipboardTextCallback);
        }

        _getClipboardTextCallback = env->NewGlobalRef(getClipboardTextCallback);
        IO->GetClipboardTextFn = getClipboardTextStub;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getDisplaySize(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:500

        Jni::ImVec2Cpy(env, &IO->DisplaySize, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getDisplaySizeX(JNIEnv* env, jobject object) {


//@line:509

        return IO->DisplaySize.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getDisplaySizeY(JNIEnv* env, jobject object) {


//@line:518

        return IO->DisplaySize.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setDisplaySize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:527

        IO->DisplaySize.x = x;
        IO->DisplaySize.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getDisplayFramebufferScale(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:548

        Jni::ImVec2Cpy(env, &IO->DisplayFramebufferScale, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getDisplayFramebufferScaleX(JNIEnv* env, jobject object) {


//@line:557

        return IO->DisplayFramebufferScale.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getDisplayFramebufferScaleY(JNIEnv* env, jobject object) {


//@line:566

        return IO->DisplayFramebufferScale.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setDisplayFramebufferScale(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:575

        IO->DisplayFramebufferScale.x = x;
        IO->DisplayFramebufferScale.y = y;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigDockingNoSplit(JNIEnv* env, jobject object) {


//@line:585

        return IO->ConfigDockingNoSplit;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigDockingNoSplit(JNIEnv* env, jobject object, jboolean value) {


//@line:592

        IO->ConfigDockingNoSplit = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigDockingWithShift(JNIEnv* env, jobject object) {


//@line:599

        return IO->ConfigDockingWithShift;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigDockingWithShift(JNIEnv* env, jobject object, jboolean value) {


//@line:606

        IO->ConfigDockingWithShift = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigDockingAlwaysTabBar(JNIEnv* env, jobject object) {


//@line:614

        return IO->ConfigDockingAlwaysTabBar;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigDockingAlwaysTabBar(JNIEnv* env, jobject object, jboolean value) {


//@line:622

        IO->ConfigDockingAlwaysTabBar = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigDockingTransparentPayload(JNIEnv* env, jobject object) {


//@line:630

        return IO->ConfigDockingTransparentPayload;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigDockingTransparentPayload(JNIEnv* env, jobject object, jboolean value) {


//@line:638

        IO->ConfigDockingTransparentPayload = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigViewportsNoAutoMerge(JNIEnv* env, jobject object) {


//@line:648

        return IO->ConfigViewportsNoAutoMerge;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigViewportsNoAutoMerge(JNIEnv* env, jobject object, jboolean value) {


//@line:656

        IO->ConfigViewportsNoAutoMerge = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigViewportsNoTaskBarIcon(JNIEnv* env, jobject object) {


//@line:663

        return IO->ConfigViewportsNoTaskBarIcon;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigViewportsNoTaskBarIcon(JNIEnv* env, jobject object, jboolean value) {


//@line:670

        IO->ConfigViewportsNoTaskBarIcon = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigViewportsNoDecoration(JNIEnv* env, jobject object) {


//@line:678

        return IO->ConfigViewportsNoDecoration;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigViewportsNoDecoration(JNIEnv* env, jobject object, jboolean value) {


//@line:686

        IO->ConfigViewportsNoDecoration = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getConfigViewportsNoDefaultParent(JNIEnv* env, jobject object) {


//@line:696

        return IO->ConfigViewportsNoDefaultParent;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setConfigViewportsNoDefaultParent(JNIEnv* env, jobject object, jboolean value) {


//@line:706

        IO->ConfigViewportsNoDefaultParent = value;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getDeltaTime(JNIEnv* env, jobject object) {


//@line:716

        return IO->DeltaTime;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setDeltaTime(JNIEnv* env, jobject object, jfloat deltaTime) {


//@line:725

        IO->DeltaTime = deltaTime;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getMousePos(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:741

        Jni::ImVec2Cpy(env, &IO->MousePos, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMousePosX(JNIEnv* env, jobject object) {


//@line:748

        return IO->MousePos.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMousePosY(JNIEnv* env, jobject object) {


//@line:755

        return IO->MousePos.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMousePos(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:762

        IO->MousePos.x = x;
        IO->MousePos.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getMouseDown___3Z(JNIEnv* env, jobject object, jbooleanArray obj_buff) {
	bool* buff = (bool*)env->GetPrimitiveArrayCritical(obj_buff, 0);


//@line:771

        for (int i = 0; i < 5; i++)
            buff[i] = IO->MouseDown[i];
    
	env->ReleasePrimitiveArrayCritical(obj_buff, buff, 0);

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getMouseDown__I(JNIEnv* env, jobject object, jint idx) {


//@line:780

        return IO->MouseDown[idx];
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseDown__IZ(JNIEnv* env, jobject object, jint idx, jboolean down) {


//@line:788

        IO->MouseDown[idx] = down;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseDown___3Z(JNIEnv* env, jobject object, jbooleanArray obj_mouseDown) {
	bool* mouseDown = (bool*)env->GetPrimitiveArrayCritical(obj_mouseDown, 0);


//@line:796

        for (int i = 0; i < 5; i++)
            IO->MouseDown[i] = mouseDown[i];
    
	env->ReleasePrimitiveArrayCritical(obj_mouseDown, mouseDown, 0);

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseWheel(JNIEnv* env, jobject object) {


//@line:804

        return IO->MouseWheel;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseWheel(JNIEnv* env, jobject object, jfloat mouseDeltaY) {


//@line:811

        IO->MouseWheel = mouseDeltaY;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseWheelH(JNIEnv* env, jobject object) {


//@line:818

        return IO->MouseWheelH;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseWheelH(JNIEnv* env, jobject object, jfloat mouseDeltaX) {


//@line:825

        IO->MouseWheelH = mouseDeltaX;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseHoveredViewport(JNIEnv* env, jobject object) {


//@line:834

        return IO->MouseHoveredViewport;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseHoveredViewport(JNIEnv* env, jobject object, jint imGuiId) {


//@line:843

        IO->MouseHoveredViewport = imGuiId;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getKeyCtrl(JNIEnv* env, jobject object) {


//@line:850

        return IO->KeyCtrl;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeyCtrl(JNIEnv* env, jobject object, jboolean value) {


//@line:857

        IO->KeyCtrl = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getKeyShift(JNIEnv* env, jobject object) {


//@line:864

        return IO->KeyShift;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeyShift(JNIEnv* env, jobject object, jboolean value) {


//@line:871

        IO->KeyShift = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getKeyAlt(JNIEnv* env, jobject object) {


//@line:878

        return IO->KeyAlt;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeyAlt(JNIEnv* env, jobject object, jboolean value) {


//@line:885

        IO->KeyAlt = value;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getKeySuper(JNIEnv* env, jobject object) {


//@line:892

        return IO->KeySuper;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeySuper(JNIEnv* env, jobject object, jboolean value) {


//@line:899

        IO->KeySuper = value;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getKeysDown___3Z(JNIEnv* env, jobject object, jbooleanArray obj_buff) {
	bool* buff = (bool*)env->GetPrimitiveArrayCritical(obj_buff, 0);


//@line:906

        for (int i = 0; i < 512; i++)
            buff[i] = IO->KeysDown[i];
    
	env->ReleasePrimitiveArrayCritical(obj_buff, buff, 0);

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getKeysDown__I(JNIEnv* env, jobject object, jint idx) {


//@line:914

        return IO->KeysDown[idx];
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeysDown__IZ(JNIEnv* env, jobject object, jint idx, jboolean pressed) {


//@line:921

        IO->KeysDown[idx] = pressed;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setKeysDown___3Z(JNIEnv* env, jobject object, jbooleanArray obj_keysDown) {
	bool* keysDown = (bool*)env->GetPrimitiveArrayCritical(obj_keysDown, 0);


//@line:928

        for (int i = 0; i < 512; i++)
            IO->KeysDown[i] = keysDown[i];
    
	env->ReleasePrimitiveArrayCritical(obj_keysDown, keysDown, 0);

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getNavInputs___3F(JNIEnv* env, jobject object, jfloatArray obj_buff) {
	float* buff = (float*)env->GetPrimitiveArrayCritical(obj_buff, 0);


//@line:936

        for (int i = 0; i < ImGuiNavInput_COUNT; i++)
            buff[i] = IO->NavInputs[i];
    
	env->ReleasePrimitiveArrayCritical(obj_buff, buff, 0);

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getNavInputs__I(JNIEnv* env, jobject object, jint idx) {


//@line:944

        return IO->NavInputs[idx];
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setNavInputs__IF(JNIEnv* env, jobject object, jint idx, jfloat input) {


//@line:951

        IO->NavInputs[idx] = input;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setNavInputs___3F(JNIEnv* env, jobject object, jfloatArray obj_navInputs) {
	float* navInputs = (float*)env->GetPrimitiveArrayCritical(obj_navInputs, 0);


//@line:958

        for (int i = 0; i < ImGuiNavInput_COUNT; i++)
            IO->NavInputs[i] = navInputs[i];
    
	env->ReleasePrimitiveArrayCritical(obj_navInputs, navInputs, 0);

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getWantCaptureMouse(JNIEnv* env, jobject object) {


//@line:974

        return IO->WantCaptureMouse;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setWantCaptureMouse(JNIEnv* env, jobject object, jboolean wantCaptureMouse) {


//@line:983

        IO->WantCaptureMouse = wantCaptureMouse;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getWantCaptureKeyboard(JNIEnv* env, jobject object) {


//@line:991

        return IO->WantCaptureKeyboard;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setWantCaptureKeyboard(JNIEnv* env, jobject object, jboolean wantCaptureKeyboard) {


//@line:999

        IO->WantCaptureKeyboard = wantCaptureKeyboard;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getWantTextInput(JNIEnv* env, jobject object) {


//@line:1007

        return IO->WantTextInput;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setWantTextInput(JNIEnv* env, jobject object, jboolean wantTextInput) {


//@line:1015

        IO->WantTextInput = wantTextInput;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getWantSetMousePos(JNIEnv* env, jobject object) {


//@line:1022

        return IO->WantSetMousePos;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setWantSetMousePos(JNIEnv* env, jobject object, jboolean wantSetMousePos) {


//@line:1029

        IO->WantSetMousePos = wantSetMousePos;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getWantSaveIniSettings(JNIEnv* env, jobject object) {


//@line:1038

        return IO->WantSaveIniSettings;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setWantSaveIniSettings(JNIEnv* env, jobject object, jboolean wantSaveIniSettings) {


//@line:1047

        IO->WantSaveIniSettings = wantSaveIniSettings;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getNavActive(JNIEnv* env, jobject object) {


//@line:1055

        return IO->NavActive;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setNavActive(JNIEnv* env, jobject object, jboolean navActive) {


//@line:1063

        IO->NavActive = navActive;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGuiIO_getNavVisible(JNIEnv* env, jobject object) {


//@line:1070

        return IO->NavVisible;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setNavVisible(JNIEnv* env, jobject object, jboolean navVisible) {


//@line:1077

        IO->NavVisible = navVisible;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getFramerate(JNIEnv* env, jobject object) {


//@line:1085

        return IO->Framerate;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setFramerate(JNIEnv* env, jobject object, jfloat framerate) {


//@line:1093

        IO->Framerate = framerate;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getMetricsRenderVertices(JNIEnv* env, jobject object) {


//@line:1100

        return IO->MetricsRenderVertices;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMetricsRenderVertices(JNIEnv* env, jobject object, jint metricsRenderVertices) {


//@line:1107

        IO->MetricsRenderVertices = metricsRenderVertices;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getMetricsRenderIndices(JNIEnv* env, jobject object) {


//@line:1114

        return IO->MetricsRenderIndices;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMetricsRenderIndices(JNIEnv* env, jobject object, jint metricsRenderIndices) {


//@line:1121

        IO->MetricsRenderIndices = metricsRenderIndices;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getMetricsRenderWindows(JNIEnv* env, jobject object) {


//@line:1128

        return IO->MetricsRenderWindows;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMetricsRenderWindows(JNIEnv* env, jobject object, jint metricsRenderWindows) {


//@line:1135

        IO->MetricsRenderWindows = metricsRenderWindows;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getMetricsActiveWindows(JNIEnv* env, jobject object) {


//@line:1142

        return IO->MetricsActiveWindows;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMetricsActiveWindows(JNIEnv* env, jobject object, jint metricsActiveWindows) {


//@line:1149

        IO->MetricsActiveWindows = metricsActiveWindows;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGuiIO_getMetricsActiveAllocations(JNIEnv* env, jobject object) {


//@line:1156

        return IO->MetricsActiveAllocations;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMetricsActiveAllocations(JNIEnv* env, jobject object, jint metricsActiveAllocations) {


//@line:1163

        IO->MetricsActiveAllocations = metricsActiveAllocations;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_getMouseDelta(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:1179

        Jni::ImVec2Cpy(env, &IO->MouseDelta, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseDeltaX(JNIEnv* env, jobject object) {


//@line:1186

        return IO->MouseDelta.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGuiIO_getMouseDeltaY(JNIEnv* env, jobject object) {


//@line:1193

        return IO->MouseDelta.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_setMouseDelta(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:1200

        IO->MouseDelta.x = x;
        IO->MouseDelta.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_addInputCharacter(JNIEnv* env, jobject object, jint c) {


//@line:1210

        IO->AddInputCharacter((unsigned int)c);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_addInputCharacterUTF16(JNIEnv* env, jobject object, jshort c) {


//@line:1217

        IO->AddInputCharacterUTF16((ImWchar16)c);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_addInputCharactersUTF8(JNIEnv* env, jobject object, jstring obj_str) {
	char* str = (char*)env->GetStringUTFChars(obj_str, 0);


//@line:1224

        IO->AddInputCharactersUTF8(str);
    
	env->ReleaseStringUTFChars(obj_str, str);

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_addFocusEvent(JNIEnv* env, jobject object, jboolean focused) {


//@line:1231

        IO->AddFocusEvent(focused);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_clearInputCharacters(JNIEnv* env, jobject object) {


//@line:1238

        IO->ClearInputCharacters();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGuiIO_clearInputKeys(JNIEnv* env, jobject object) {


//@line:1245

        IO->ClearInputKeys();
    

}


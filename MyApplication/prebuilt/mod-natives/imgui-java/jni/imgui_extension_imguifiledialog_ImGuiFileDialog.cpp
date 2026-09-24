#include <imgui_extension_imguifiledialog_ImGuiFileDialog.h>

//@line:17

        #include "_imguifiledialog.h"

        jobject imgfdPaneFunCallback = NULL;
        const void paneFunCallback(const char* filter, void* user_data, bool* can_we_continue) {
            if (imgfdPaneFunCallback != NULL) {
                JNIEnv* env = Jni::GetEnv();
                std::string vKey = ImGuiFileDialog::Instance()->GetOpenedKey();
                jlong ret_user_datas = reinterpret_cast<jlong>(user_data);
                Jni::CallImGuiFileDialogPaneFun(env, imgfdPaneFunCallback, filter, ret_user_datas, *can_we_continue);
            }
        }

        #define IMGFD_PANE_FUN_METHOD_TMPL()\
            if (imgfdPaneFunCallback != NULL) {\
                env->DeleteGlobalRef(imgfdPaneFunCallback);\
            }\
            imgfdPaneFunCallback = env->NewGlobalRef(vSidePane);
    JNIEXPORT void JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_openDialog(JNIEnv* env, jclass clazz, jstring obj_vKey, jstring obj_vTitle, jstring obj_vFilters, jstring obj_vPath, jstring obj_vFileName, jint vCountSelectionMax, jlong vUserDatas, jint vFlags) {

//@line:50


        char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);
        char* vTitle = (char*)env->GetStringUTFChars(obj_vTitle, 0);
        char* vPath = (char*)env->GetStringUTFChars(obj_vPath, 0);
        char* vFileName = (char*)env->GetStringUTFChars(obj_vFileName, 0);

        if (env->IsSameObject(obj_vFilters, NULL)) {
            ImGuiFileDialog::Instance()->OpenDialog(vKey, vTitle, nullptr, vPath, vFileName, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
        } else {
            char* vFilters = (char*)env->GetStringUTFChars(obj_vFilters, JNI_FALSE);
            ImGuiFileDialog::Instance()->OpenDialog(vKey, vTitle, vFilters, vPath, vFileName, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
            env->ReleaseStringUTFChars(obj_vFilters, vFilters);
        }

        env->ReleaseStringUTFChars(obj_vKey, vKey);
        env->ReleaseStringUTFChars(obj_vTitle, vTitle);
        env->ReleaseStringUTFChars(obj_vPath, vPath);
        env->ReleaseStringUTFChars(obj_vFileName, vFileName);
    
}

JNIEXPORT void JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_openModal__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2IJI(JNIEnv* env, jclass clazz, jstring obj_vKey, jstring obj_vTitle, jstring obj_vFilters, jstring obj_vPath, jstring obj_vFileName, jint vCountSelectionMax, jlong vUserDatas, jint vFlags) {

//@line:85

        char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);
        char* vTitle = (char*)env->GetStringUTFChars(obj_vTitle, 0);
        char* vPath = (char*)env->GetStringUTFChars(obj_vPath, 0);
        char* vFileName = (char*)env->GetStringUTFChars(obj_vFileName, 0);

        if (env->IsSameObject(obj_vFilters, NULL)) {
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, nullptr, vPath, vFileName, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
        } else {
            char* vFilters = (char*)env->GetStringUTFChars(obj_vFilters, JNI_FALSE);
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, vFilters, vPath, vFileName, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
            env->ReleaseStringUTFChars(obj_vFilters, vFilters);
        }

        env->ReleaseStringUTFChars(obj_vKey, vKey);
        env->ReleaseStringUTFChars(obj_vTitle, vTitle);
        env->ReleaseStringUTFChars(obj_vPath, vPath);
        env->ReleaseStringUTFChars(obj_vFileName, vFileName);
    
}

JNIEXPORT void JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_openModal__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2IJI(JNIEnv* env, jclass clazz, jstring obj_vKey, jstring obj_vTitle, jstring obj_vFilters, jstring obj_vFilePathName, jint vCountSelectionMax, jlong vUserDatas, jint vFlags) {

//@line:118

        char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);
        char* vTitle = (char*)env->GetStringUTFChars(obj_vTitle, 0);
        char* vFilePathName = (char*)env->GetStringUTFChars(obj_vFilePathName, 0);

        if (env->IsSameObject(obj_vFilters, NULL)) {
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, nullptr, vFilePathName, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
        } else {
            char* vFilters = (char*)env->GetStringUTFChars(obj_vFilters, JNI_FALSE);
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, vFilters, vFilePathName, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
            env->ReleaseStringUTFChars(obj_vFilters, vFilters);
        }

        env->ReleaseStringUTFChars(obj_vKey, vKey);
        env->ReleaseStringUTFChars(obj_vTitle, vTitle);
        env->ReleaseStringUTFChars(obj_vFilePathName, vFilePathName);
    
}

JNIEXPORT void JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_openModal__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Limgui_extension_imguifiledialog_callback_ImGuiFileDialogPaneFun_2FIJI(JNIEnv* env, jclass clazz, jstring obj_vKey, jstring obj_vTitle, jstring obj_vFilters, jstring obj_vPath, jstring obj_vFileName, jobject vSidePane, jfloat vSidePaneWidth, jint vCountSelectionMax, jlong vUserDatas, jint vFlags) {

//@line:152

        IMGFD_PANE_FUN_METHOD_TMPL()

        char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);
        char* vTitle = (char*)env->GetStringUTFChars(obj_vTitle, 0);
        char* vPath = (char*)env->GetStringUTFChars(obj_vPath, 0);
        char* vFileName = (char*)env->GetStringUTFChars(obj_vFileName, 0);

        if (env->IsSameObject(obj_vFilters, NULL)) {
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, nullptr, vPath, vFileName, paneFunCallback, vSidePaneWidth, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
        } else {
            char* vFilters = (char*)env->GetStringUTFChars(obj_vFilters, JNI_FALSE);
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, vFilters, vPath, vFileName, paneFunCallback, vSidePaneWidth, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
            env->ReleaseStringUTFChars(obj_vFilters, vFilters);
        }

        env->ReleaseStringUTFChars(obj_vKey, vKey);
        env->ReleaseStringUTFChars(obj_vTitle, vTitle);
        env->ReleaseStringUTFChars(obj_vPath, vPath);
        env->ReleaseStringUTFChars(obj_vFileName, vFileName);
     
}

JNIEXPORT void JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_openModal__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2Limgui_extension_imguifiledialog_callback_ImGuiFileDialogPaneFun_2FIJI(JNIEnv* env, jclass clazz, jstring obj_vKey, jstring obj_vTitle, jstring obj_vFilters, jstring obj_vFilePathName, jobject vSidePane, jfloat vSidePaneWidth, jint vCountSelectionMax, jlong vUserDatas, jint vFlags) {

//@line:189

        IMGFD_PANE_FUN_METHOD_TMPL()

        char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);
        char* vTitle = (char*)env->GetStringUTFChars(obj_vTitle, 0);
        char* vFilePathName = (char*)env->GetStringUTFChars(obj_vFilePathName, 0);

        if (env->IsSameObject(obj_vFilters, NULL)) {
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, nullptr, vFilePathName, paneFunCallback, vSidePaneWidth, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
        } else {
            char* vFilters = (char*)env->GetStringUTFChars(obj_vFilters, JNI_FALSE);
            ImGuiFileDialog::Instance()->OpenModal(vKey, vTitle, vFilters, vFilePathName, paneFunCallback, vSidePaneWidth, vCountSelectionMax, reinterpret_cast<void*>(vUserDatas), vFlags);
            env->ReleaseStringUTFChars(obj_vFilters, vFilters);
        }

        env->ReleaseStringUTFChars(obj_vKey, vKey);
        env->ReleaseStringUTFChars(obj_vTitle, vTitle);
        env->ReleaseStringUTFChars(obj_vFilePathName, vFilePathName);
     
}

static inline jboolean wrapped_Java_imgui_extension_imguifiledialog_ImGuiFileDialog_display
(JNIEnv* env, jclass clazz, jstring obj_vKey, jint vFlags, jfloat vMinSizeX, jfloat vMinSizeY, jfloat vMaxSizeX, jfloat vMaxSizeY, char* vKey) {

//@line:221

        return ImGuiFileDialog::Instance()->Display(vKey, vFlags, ImVec2(vMinSizeX, vMinSizeY), ImVec2(vMaxSizeX, vMaxSizeY));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_display(JNIEnv* env, jclass clazz, jstring obj_vKey, jint vFlags, jfloat vMinSizeX, jfloat vMinSizeY, jfloat vMaxSizeX, jfloat vMaxSizeY) {
	char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imguifiledialog_ImGuiFileDialog_display(env, clazz, obj_vKey, vFlags, vMinSizeX, vMinSizeY, vMaxSizeX, vMaxSizeY, vKey);

	env->ReleaseStringUTFChars(obj_vKey, vKey);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_close(JNIEnv* env, jclass clazz) {


//@line:229

         ImGuiFileDialog::Instance()->Close();
    

}

static inline jboolean wrapped_Java_imgui_extension_imguifiledialog_ImGuiFileDialog_wasOpenedThisFrame__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_vKey, char* vKey) {

//@line:240

        return ImGuiFileDialog::Instance()->WasOpenedThisFrame(vKey);
     
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_wasOpenedThisFrame__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_vKey) {
	char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imguifiledialog_ImGuiFileDialog_wasOpenedThisFrame__Ljava_lang_String_2(env, clazz, obj_vKey, vKey);

	env->ReleaseStringUTFChars(obj_vKey, vKey);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_wasOpenedThisFrame__(JNIEnv* env, jclass clazz) {


//@line:250

        return ImGuiFileDialog::Instance()->WasOpenedThisFrame();
    

}

static inline jboolean wrapped_Java_imgui_extension_imguifiledialog_ImGuiFileDialog_isOpened__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_vKey, char* vKey) {

//@line:261

        return ImGuiFileDialog::Instance()->IsOpened(vKey);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_isOpened__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_vKey) {
	char* vKey = (char*)env->GetStringUTFChars(obj_vKey, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_imguifiledialog_ImGuiFileDialog_isOpened__Ljava_lang_String_2(env, clazz, obj_vKey, vKey);

	env->ReleaseStringUTFChars(obj_vKey, vKey);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_isOpened__(JNIEnv* env, jclass clazz) {


//@line:271

        return ImGuiFileDialog::Instance()->IsOpened();
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_getOpenedKey(JNIEnv* env, jclass clazz) {


//@line:281

        return env->NewStringUTF(ImGuiFileDialog::Instance()->GetOpenedKey().c_str());
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_isOk(JNIEnv* env, jclass clazz) {


//@line:291

        return ImGuiFileDialog::Instance()->IsOk();
    

}

JNIEXPORT jobject JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_getSelection(JNIEnv* env, jclass clazz) {


//@line:304

        //Get the map from ImGuiFileDialog
        std::map<std::string, std::string> mMap = ImGuiFileDialog::Instance()->GetSelection();

        env->PushLocalFrame(mMap.size() * 2); // Expands stack size to not overflow

        //Get reference to java's HashMap
        jclass hashMapClass = env->FindClass("java/util/HashMap");
        jmethodID hashMapInit = env->GetMethodID(hashMapClass, "<init>", "(I)V");
        jobject hashMapObj = env->NewObject(hashMapClass, hashMapInit, mMap.size());
        jmethodID hashMapPut = env->GetMethodID(hashMapClass, "put",
                    "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");

        //Copy key,value pairs from map to hashmap
        for (auto it : mMap)
        {
            env->CallObjectMethod(hashMapObj, hashMapPut,
                 env->NewStringUTF(it.first.c_str()),
                 env->NewStringUTF(it.second.c_str())
             );
        }

        env->PopLocalFrame(hashMapObj); //Cleanup stack

        return hashMapObj;
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_getFilePathName(JNIEnv* env, jclass clazz) {


//@line:335

        return env->NewStringUTF(ImGuiFileDialog::Instance()->GetFilePathName().c_str());
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_getCurrentFileName(JNIEnv* env, jclass clazz) {


//@line:345

        return env->NewStringUTF(ImGuiFileDialog::Instance()->GetCurrentFileName().c_str());
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_getCurrentPath(JNIEnv* env, jclass clazz) {


//@line:355

        return env->NewStringUTF(ImGuiFileDialog::Instance()->GetCurrentPath().c_str());
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_getCurrentFilter(JNIEnv* env, jclass clazz) {


//@line:365

        return env->NewStringUTF(ImGuiFileDialog::Instance()->GetCurrentFilter().c_str());
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_imguifiledialog_ImGuiFileDialog_getUserDatas(JNIEnv* env, jclass clazz) {


//@line:378

        return reinterpret_cast<jlong>(ImGuiFileDialog::Instance()->GetUserDatas());
    

}


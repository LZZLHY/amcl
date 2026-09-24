#include <imgui_extension_nodeditor_NodeEditorConfig.h>

//@line:13

        #include "_nodeeditor.h"

        namespace ed = ax::NodeEditor;

        #define IM_NODE_EDITOR_CONFIG ((ed::Config*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditorConfig_nCreate(JNIEnv* env, jobject object) {


//@line:26

        return (intptr_t)(new ed::Config());
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_nodeditor_NodeEditorConfig_getSettingsFile(JNIEnv* env, jobject object) {


//@line:30

        return env->NewStringUTF(IM_NODE_EDITOR_CONFIG->SettingsFile);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorConfig_setSettingsFile(JNIEnv* env, jobject object, jstring obj_settingsFile) {

//@line:34

        IM_NODE_EDITOR_CONFIG->SettingsFile = obj_settingsFile == NULL ? NULL : (char*)env->GetStringUTFChars(obj_settingsFile, JNI_FALSE);
    
}


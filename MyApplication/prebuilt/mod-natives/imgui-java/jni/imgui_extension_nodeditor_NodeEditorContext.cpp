#include <imgui_extension_nodeditor_NodeEditorContext.h>

//@line:17

        #include "_nodeeditor.h"

        namespace ed = ax::NodeEditor;

        #define IM_NODE_EDITOR_CONTEXT ((ed::EditorContext*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditorContext_nCreate__(JNIEnv* env, jobject object) {


//@line:35

        return (intptr_t)ed::CreateEditor();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_nodeditor_NodeEditorContext_nCreate__J(JNIEnv* env, jclass clazz, jlong cfgPtr) {


//@line:39

        return (intptr_t)ed::CreateEditor((ed::Config*)cfgPtr);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_nodeditor_NodeEditorContext_nDestroyEditorContext(JNIEnv* env, jobject object) {


//@line:43

       ed::DestroyEditor(IM_NODE_EDITOR_CONTEXT);
    

}


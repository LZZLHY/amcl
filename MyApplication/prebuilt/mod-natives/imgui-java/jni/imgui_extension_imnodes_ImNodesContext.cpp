#include <imgui_extension_imnodes_ImNodesContext.h>

//@line:13

        #include "_imnodes.h"

        #define IMNODES_CONTEXT ((ImNodesEditorContext*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_imnodes_ImNodesContext_nCreate(JNIEnv* env, jobject object) {


//@line:29

        return (intptr_t)ImNodes::EditorContextCreate();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imnodes_ImNodesContext_nDestroy(JNIEnv* env, jobject object) {


//@line:33

        ImNodes::EditorContextFree(IMNODES_CONTEXT);
    

}


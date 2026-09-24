#include <imgui_extension_memedit_MemoryEditor.h>

//@line:11

        #include "_memedit.h"

        #define MEMORY_EDITOR ((MemoryEditor*)STRUCT_PTR)
      JNIEXPORT jlong JNICALL Java_imgui_extension_memedit_MemoryEditor_nCreate(JNIEnv* env, jobject object) {


//@line:30

        return (intptr_t)(new MemoryEditor());
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditor_gotoAddrAndHighlight(JNIEnv* env, jobject object, jlong addrMin, jlong addrMax) {


//@line:34

        MEMORY_EDITOR->GotoAddrAndHighlight(addrMin, addrMax);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditor_nCalcSizes(JNIEnv* env, jobject object, jlong ptr, jlong memSize, jlong baseDisplayAddr) {


//@line:42

        MEMORY_EDITOR->CalcSizes(*((MemoryEditor::Sizes*)ptr), static_cast<size_t>(memSize), static_cast<size_t>(baseDisplayAddr));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditor_drawWindow(JNIEnv* env, jobject object, jstring obj_title, jlong memData, jlong memSize, jlong baseDisplayAddr) {
	char* title = (char*)env->GetStringUTFChars(obj_title, 0);


//@line:50

        MEMORY_EDITOR->DrawWindow(title, reinterpret_cast<void*>(memData), static_cast<size_t>(memSize), static_cast<size_t>(baseDisplayAddr));
    
	env->ReleaseStringUTFChars(obj_title, title);

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditor_drawContents(JNIEnv* env, jobject object, jlong memData, jlong memSize, jlong baseDisplayAddr) {


//@line:58

        MEMORY_EDITOR->DrawContents(reinterpret_cast<void*>(memData), static_cast<size_t>(memSize), static_cast<size_t>(baseDisplayAddr));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditor_nDrawOptionsLine(JNIEnv* env, jobject object, jlong ptr, jlong memData, jlong memSize, jlong baseDisplayAddr) {


//@line:66

        MEMORY_EDITOR->DrawOptionsLine(*((MemoryEditor::Sizes*)ptr), reinterpret_cast<void*>(memData), static_cast<size_t>(memSize), static_cast<size_t>(baseDisplayAddr));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditor_nDrawPreviewLine(JNIEnv* env, jobject object, jlong ptr, jlong memDataVoid, jlong memSize, jlong baseDisplayAddr) {


//@line:74

        MEMORY_EDITOR->DrawPreviewLine(*((MemoryEditor::Sizes*)ptr), reinterpret_cast<void*>(memDataVoid), static_cast<size_t>(memSize), static_cast<size_t>(baseDisplayAddr));
    

}


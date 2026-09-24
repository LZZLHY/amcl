#include <imgui_extension_memedit_MemoryEditorSizes.h>

//@line:7

        #include "_memedit.h"

        #define MEMORY_EDITOR_SIZES ((MemoryEditor::Sizes*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_nCreate(JNIEnv* env, jobject object) {


//@line:26

        return (intptr_t)(new MemoryEditor::Sizes());
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setAddrDigitsCount(JNIEnv* env, jobject object, jint addrDigitsCount) {


//@line:30

        MEMORY_EDITOR_SIZES->AddrDigitsCount = addrDigitsCount;
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getAddrDigitsCount(JNIEnv* env, jobject object) {


//@line:34

        return MEMORY_EDITOR_SIZES->AddrDigitsCount;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setLineHeight(JNIEnv* env, jobject object, jfloat lineHeight) {


//@line:38

        MEMORY_EDITOR_SIZES->LineHeight = lineHeight;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getLineHeight(JNIEnv* env, jobject object) {


//@line:42

        return MEMORY_EDITOR_SIZES->LineHeight;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setGlyphWidth(JNIEnv* env, jobject object, jfloat glyphWidth) {


//@line:46

        MEMORY_EDITOR_SIZES->GlyphWidth = glyphWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getGlyphWidth(JNIEnv* env, jobject object) {


//@line:50

        return MEMORY_EDITOR_SIZES->GlyphWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setHexCellWidth(JNIEnv* env, jobject object, jfloat hexCellWidth) {


//@line:54

        MEMORY_EDITOR_SIZES->HexCellWidth = hexCellWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getHexCellWidth(JNIEnv* env, jobject object) {


//@line:58

        return MEMORY_EDITOR_SIZES->HexCellWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setSpacingBetweenMidCols(JNIEnv* env, jobject object, jfloat spacingBetweenMidCols) {


//@line:62

        MEMORY_EDITOR_SIZES->SpacingBetweenMidCols = spacingBetweenMidCols;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getSpacingBetweenMidCols(JNIEnv* env, jobject object) {


//@line:66

        return MEMORY_EDITOR_SIZES->SpacingBetweenMidCols;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setPosHexStart(JNIEnv* env, jobject object, jfloat posHexStart) {


//@line:70

        MEMORY_EDITOR_SIZES->PosHexStart = posHexStart;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getPosHexStart(JNIEnv* env, jobject object) {


//@line:74

        return MEMORY_EDITOR_SIZES->PosHexStart;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setPosHexEnd(JNIEnv* env, jobject object, jfloat posHexEnd) {


//@line:78

        MEMORY_EDITOR_SIZES->PosHexEnd = posHexEnd;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getPosHexEnd(JNIEnv* env, jobject object) {


//@line:82

        return MEMORY_EDITOR_SIZES->PosHexEnd;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setPosAsciiStart(JNIEnv* env, jobject object, jfloat posAsciiStart) {


//@line:86

        MEMORY_EDITOR_SIZES->PosAsciiStart = posAsciiStart;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getPosAsciiStart(JNIEnv* env, jobject object) {


//@line:90

        return MEMORY_EDITOR_SIZES->PosAsciiStart;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setPosAsciiEnd(JNIEnv* env, jobject object, jfloat posAsciiEnd) {


//@line:94

        MEMORY_EDITOR_SIZES->PosAsciiEnd = posAsciiEnd;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getPosAsciiEnd(JNIEnv* env, jobject object) {


//@line:98

        return MEMORY_EDITOR_SIZES->PosAsciiEnd;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_setWindowWidth(JNIEnv* env, jobject object, jfloat windowWidth) {


//@line:102

        MEMORY_EDITOR_SIZES->WindowWidth = windowWidth;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_memedit_MemoryEditorSizes_getWindowWidth(JNIEnv* env, jobject object) {


//@line:106

        return MEMORY_EDITOR_SIZES->WindowWidth;
    

}


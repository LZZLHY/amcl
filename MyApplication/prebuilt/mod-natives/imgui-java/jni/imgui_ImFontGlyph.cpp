#include <imgui_ImFontGlyph.h>

//@line:17

        #include "_common.h"

        #define IM_FONT_GLYPH ((ImFontGlyph*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_ImFontGlyph_nCreate(JNIEnv* env, jobject object) {


//@line:28

        return (intptr_t)(new ImFontGlyph());
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontGlyph_getColored(JNIEnv* env, jobject object) {


//@line:35

        return (unsigned int)IM_FONT_GLYPH->Colored;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setColored(JNIEnv* env, jobject object, jint colored) {


//@line:42

        IM_FONT_GLYPH->Colored = (unsigned int)colored;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontGlyph_getVisible(JNIEnv* env, jobject object) {


//@line:49

        return (unsigned int)IM_FONT_GLYPH->Visible;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setVisible(JNIEnv* env, jobject object, jint visible) {


//@line:56

        IM_FONT_GLYPH->Visible = (unsigned int)visible;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontGlyph_getCodepoint(JNIEnv* env, jobject object) {


//@line:63

        return (unsigned int)IM_FONT_GLYPH->Codepoint;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setCodepoint(JNIEnv* env, jobject object, jint codepoint) {


//@line:70

        IM_FONT_GLYPH->Codepoint = (unsigned int)codepoint;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getAdvanceX(JNIEnv* env, jobject object) {


//@line:77

        return IM_FONT_GLYPH->AdvanceX;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setAdvanceX(JNIEnv* env, jobject object, jfloat advanceX) {


//@line:84

        IM_FONT_GLYPH->AdvanceX = advanceX;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getX0(JNIEnv* env, jobject object) {


//@line:91

        return IM_FONT_GLYPH->X0;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setX0(JNIEnv* env, jobject object, jfloat x0) {


//@line:98

        IM_FONT_GLYPH->X0 = x0;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getY0(JNIEnv* env, jobject object) {


//@line:105

        return IM_FONT_GLYPH->Y0;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setY0(JNIEnv* env, jobject object, jfloat y0) {


//@line:112

        IM_FONT_GLYPH->Y0 = y0;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getX1(JNIEnv* env, jobject object) {


//@line:119

        return IM_FONT_GLYPH->X1;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setX1(JNIEnv* env, jobject object, jfloat x1) {


//@line:126

        IM_FONT_GLYPH->X1 = x1;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getY1(JNIEnv* env, jobject object) {


//@line:133

        return IM_FONT_GLYPH->Y1;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setY1(JNIEnv* env, jobject object, jfloat y1) {


//@line:140

        IM_FONT_GLYPH->Y1 = y1;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getU0(JNIEnv* env, jobject object) {


//@line:147

        return IM_FONT_GLYPH->U0;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setU0(JNIEnv* env, jobject object, jfloat u0) {


//@line:154

        IM_FONT_GLYPH->U0 = u0;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getV0(JNIEnv* env, jobject object) {


//@line:161

        return IM_FONT_GLYPH->V0;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setV0(JNIEnv* env, jobject object, jfloat v0) {


//@line:168

        IM_FONT_GLYPH->V0 = v0;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getU1(JNIEnv* env, jobject object) {


//@line:175

        return IM_FONT_GLYPH->U1;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setU1(JNIEnv* env, jobject object, jfloat u1) {


//@line:182

        IM_FONT_GLYPH->U1 = u1;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontGlyph_getV1(JNIEnv* env, jobject object) {


//@line:189

        return IM_FONT_GLYPH->V1;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontGlyph_setV1(JNIEnv* env, jobject object, jfloat v1) {


//@line:196

        IM_FONT_GLYPH->V1 = v1;
    

}


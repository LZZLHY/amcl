#include <imgui_ImFontConfig.h>

//@line:22

        #include "_common.h"

        #define IM_FONT_CONFIG ((ImFontConfig*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_ImFontConfig_nCreate(JNIEnv* env, jobject object) {


//@line:33

        return (intptr_t)(new ImFontConfig());
    

}

JNIEXPORT jbyteArray JNICALL Java_imgui_ImFontConfig_getFontData(JNIEnv* env, jobject object) {


//@line:40

        int size = IM_FONT_CONFIG->FontDataSize;
        jbyteArray jBytes = env->NewByteArray(size);
        env->SetByteArrayRegion(jBytes, 0, size, (jbyte*)IM_FONT_CONFIG->FontData);
        return jBytes;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setFontData(JNIEnv* env, jobject object, jbyteArray obj_fontData) {
	char* fontData = (char*)env->GetPrimitiveArrayCritical(obj_fontData, 0);


//@line:50

        IM_FONT_CONFIG->FontData = &fontData[0];
    
	env->ReleasePrimitiveArrayCritical(obj_fontData, fontData, 0);

}

JNIEXPORT jint JNICALL Java_imgui_ImFontConfig_getFontDataSize(JNIEnv* env, jobject object) {


//@line:57

        return IM_FONT_CONFIG->FontDataSize;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setFontDataSize(JNIEnv* env, jobject object, jint fontDataSize) {


//@line:64

        IM_FONT_CONFIG->FontDataSize = fontDataSize;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFontConfig_getFontDataOwnedByAtlas(JNIEnv* env, jobject object) {


//@line:71

        return IM_FONT_CONFIG->FontDataOwnedByAtlas;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setFontDataOwnedByAtlas(JNIEnv* env, jobject object, jboolean isFontDataOwnedByAtlas) {


//@line:82

        IM_FONT_CONFIG->FontDataOwnedByAtlas = isFontDataOwnedByAtlas;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontConfig_getFontNo(JNIEnv* env, jobject object) {


//@line:89

        return IM_FONT_CONFIG->FontNo;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setFontNo(JNIEnv* env, jobject object, jint fontNo) {


//@line:96

        IM_FONT_CONFIG->FontNo = fontNo;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getSizePixels(JNIEnv* env, jobject object) {


//@line:103

        return IM_FONT_CONFIG->SizePixels;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setSizePixels(JNIEnv* env, jobject object, jfloat sizePixels) {


//@line:110

        IM_FONT_CONFIG->SizePixels = sizePixels;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontConfig_getOversampleH(JNIEnv* env, jobject object) {


//@line:119

        return IM_FONT_CONFIG->OversampleH;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setOversampleH(JNIEnv* env, jobject object, jint oversampleH) {


//@line:128

        IM_FONT_CONFIG->OversampleH = oversampleH;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontConfig_getOversampleV(JNIEnv* env, jobject object) {


//@line:136

        return IM_FONT_CONFIG->OversampleV;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setOversampleV(JNIEnv* env, jobject object, jint oversampleV) {


//@line:144

        IM_FONT_CONFIG->OversampleV = oversampleV;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFontConfig_getPixelSnapH(JNIEnv* env, jobject object) {


//@line:152

        return IM_FONT_CONFIG->PixelSnapH;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setPixelSnapH(JNIEnv* env, jobject object, jboolean isPixelSnapH) {


//@line:160

        IM_FONT_CONFIG->PixelSnapH = isPixelSnapH;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_getGlyphExtraSpacing(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:176

        Jni::ImVec2Cpy(env, &IM_FONT_CONFIG->GlyphExtraSpacing, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getGlyphExtraSpacingX(JNIEnv* env, jobject object) {


//@line:183

        return IM_FONT_CONFIG->GlyphExtraSpacing.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getGlyphExtraSpacingY(JNIEnv* env, jobject object) {


//@line:190

        return IM_FONT_CONFIG->GlyphExtraSpacing.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setGlyphExtraSpacing(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:197

        IM_FONT_CONFIG->GlyphExtraSpacing.x = x;
        IM_FONT_CONFIG->GlyphExtraSpacing.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_getGlyphOffset(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:214

        Jni::ImVec2Cpy(env, &IM_FONT_CONFIG->GlyphOffset, dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getGlyphOffsetX(JNIEnv* env, jobject object) {


//@line:221

        return IM_FONT_CONFIG->GlyphOffset.x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getGlyphOffsetY(JNIEnv* env, jobject object) {


//@line:228

        return IM_FONT_CONFIG->GlyphOffset.y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setGlyphOffset(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:235

        IM_FONT_CONFIG->GlyphOffset.x = x;
        IM_FONT_CONFIG->GlyphOffset.y = y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_nSetGlyphRanges(JNIEnv* env, jobject object, jshortArray obj_glyphRanges) {
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);


//@line:257

        IM_FONT_CONFIG->GlyphRanges = glyphRanges != NULL ? (ImWchar*)&glyphRanges[0] : NULL;
    
	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getGlyphMinAdvanceX(JNIEnv* env, jobject object) {


//@line:264

        return IM_FONT_CONFIG->GlyphMinAdvanceX;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setGlyphMinAdvanceX(JNIEnv* env, jobject object, jfloat glyphMinAdvanceX) {


//@line:271

        IM_FONT_CONFIG->GlyphMinAdvanceX = glyphMinAdvanceX;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getGlyphMaxAdvanceX(JNIEnv* env, jobject object) {


//@line:278

        return IM_FONT_CONFIG->GlyphMaxAdvanceX;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setGlyphMaxAdvanceX(JNIEnv* env, jobject object, jfloat glyphMaxAdvanceX) {


//@line:285

        IM_FONT_CONFIG->GlyphMaxAdvanceX = glyphMaxAdvanceX;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFontConfig_getMergeMode(JNIEnv* env, jobject object) {


//@line:293

        return IM_FONT_CONFIG->MergeMode;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setMergeMode(JNIEnv* env, jobject object, jboolean mergeMode) {


//@line:301

        IM_FONT_CONFIG->MergeMode = mergeMode;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontConfig_getFontBuilderFlags(JNIEnv* env, jobject object) {


//@line:308

        return IM_FONT_CONFIG->FontBuilderFlags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setFontBuilderFlags(JNIEnv* env, jobject object, jint fontBuilderFlags) {


//@line:315

        IM_FONT_CONFIG->FontBuilderFlags = (unsigned int)fontBuilderFlags;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFontConfig_getRasterizerMultiply(JNIEnv* env, jobject object) {


//@line:322

        return IM_FONT_CONFIG->RasterizerMultiply;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setRasterizerMultiply(JNIEnv* env, jobject object, jfloat rasterizerMultiply) {


//@line:329

        IM_FONT_CONFIG->RasterizerMultiply = rasterizerMultiply;
    

}

JNIEXPORT jshort JNICALL Java_imgui_ImFontConfig_getEllipsisChar(JNIEnv* env, jobject object) {


//@line:336

        return (short)IM_FONT_CONFIG->EllipsisChar;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setEllipsisChar(JNIEnv* env, jobject object, jint ellipsisChar) {


//@line:343

        IM_FONT_CONFIG->EllipsisChar = (ImWchar)ellipsisChar;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontConfig_setName(JNIEnv* env, jobject object, jstring obj_name) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:352

        strcpy(IM_FONT_CONFIG->Name, name);
    
	env->ReleaseStringUTFChars(obj_name, name);

}


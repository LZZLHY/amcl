#include <imgui_ImFontAtlas.h>

//@line:39

        #include "_common.h"

        #define IM_FONT_ATLAS ((ImFontAtlas*)STRUCT_PTR)

        jmethodID jImFontAtlasCreateAlpha8PixelsMID;
        jmethodID jImFontAtlasCreateRgba32PixelsMID;
     JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_nInit(JNIEnv* env, jclass clazz) {


//@line:48

        jclass jImFontAtlasClass = env->FindClass("imgui/ImFontAtlas");

        jImFontAtlasCreateAlpha8PixelsMID = env->GetMethodID(jImFontAtlasClass, "createAlpha8Pixels", "(I)Ljava/nio/ByteBuffer;");
        jImFontAtlasCreateRgba32PixelsMID = env->GetMethodID(jImFontAtlasClass, "createRgba32Pixels", "(I)Ljava/nio/ByteBuffer;");
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nCreate(JNIEnv* env, jobject object) {


//@line:60

        return (intptr_t)(new ImFontConfig());
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFont(JNIEnv* env, jobject object, jlong imFontConfigPtr) {


//@line:68

        return (intptr_t)IM_FONT_ATLAS->AddFont((ImFontConfig*)imFontConfigPtr);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontDefault__(JNIEnv* env, jobject object) {


//@line:76

        return (intptr_t)IM_FONT_ATLAS->AddFontDefault();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontDefault__J(JNIEnv* env, jobject object, jlong imFontConfigPtr) {


//@line:84

        return (intptr_t)IM_FONT_ATLAS->AddFontDefault((ImFontConfig*)imFontConfigPtr);
    

}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2F
(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels, char* filename) {

//@line:92

        return (intptr_t)IM_FONT_ATLAS->AddFontFromFileTTF(filename, sizePixels);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2F(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels) {
	char* filename = (char*)env->GetStringUTFChars(obj_filename, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2F(env, object, obj_filename, sizePixels, filename);

	env->ReleaseStringUTFChars(obj_filename, filename);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2FJ
(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels, jlong imFontConfigPtr, char* filename) {

//@line:100

        return (intptr_t)IM_FONT_ATLAS->AddFontFromFileTTF(filename, sizePixels, (ImFontConfig*)imFontConfigPtr);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2FJ(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels, jlong imFontConfigPtr) {
	char* filename = (char*)env->GetStringUTFChars(obj_filename, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2FJ(env, object, obj_filename, sizePixels, imFontConfigPtr, filename);

	env->ReleaseStringUTFChars(obj_filename, filename);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2F_3S
(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels, jshortArray obj_glyphRanges, char* filename, short* glyphRanges) {

//@line:108

        return (intptr_t)IM_FONT_ATLAS->AddFontFromFileTTF(filename, sizePixels, NULL, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2F_3S(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels, jshortArray obj_glyphRanges) {
	char* filename = (char*)env->GetStringUTFChars(obj_filename, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2F_3S(env, object, obj_filename, sizePixels, obj_glyphRanges, filename, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);
	env->ReleaseStringUTFChars(obj_filename, filename);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2FJ_3S
(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges, char* filename, short* glyphRanges) {

//@line:116

        return (intptr_t)IM_FONT_ATLAS->AddFontFromFileTTF(filename, sizePixels, (ImFontConfig*)imFontConfigPtr, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2FJ_3S(JNIEnv* env, jobject object, jstring obj_filename, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges) {
	char* filename = (char*)env->GetStringUTFChars(obj_filename, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromFileTTF__Ljava_lang_String_2FJ_3S(env, object, obj_filename, sizePixels, imFontConfigPtr, obj_glyphRanges, filename, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);
	env->ReleaseStringUTFChars(obj_filename, filename);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIF
(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels, char* fontData) {

//@line:128

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryTTF(&fontData[0], fontSize, sizePixels);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIF(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels) {
	char* fontData = (char*)env->GetPrimitiveArrayCritical(obj_fontData, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIF(env, object, obj_fontData, fontSize, sizePixels, fontData);

	env->ReleasePrimitiveArrayCritical(obj_fontData, fontData, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIFJ
(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr, char* fontData) {

//@line:141

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryTTF(&fontData[0], fontSize, sizePixels, (ImFontConfig*)imFontConfigPtr);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIFJ(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr) {
	char* fontData = (char*)env->GetPrimitiveArrayCritical(obj_fontData, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIFJ(env, object, obj_fontData, fontSize, sizePixels, imFontConfigPtr, fontData);

	env->ReleasePrimitiveArrayCritical(obj_fontData, fontData, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIF_3S
(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels, jshortArray obj_glyphRanges, char* fontData, short* glyphRanges) {

//@line:153

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryTTF(&fontData[0], fontSize, sizePixels, NULL, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIF_3S(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels, jshortArray obj_glyphRanges) {
	char* fontData = (char*)env->GetPrimitiveArrayCritical(obj_fontData, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIF_3S(env, object, obj_fontData, fontSize, sizePixels, obj_glyphRanges, fontData, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_fontData, fontData, 0);
	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIFJ_3S
(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges, char* fontData, short* glyphRanges) {

//@line:165

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryTTF(&fontData[0], fontSize, sizePixels, (ImFontConfig*)imFontConfigPtr, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIFJ_3S(JNIEnv* env, jobject object, jbyteArray obj_fontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges) {
	char* fontData = (char*)env->GetPrimitiveArrayCritical(obj_fontData, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryTTF___3BIFJ_3S(env, object, obj_fontData, fontSize, sizePixels, imFontConfigPtr, obj_glyphRanges, fontData, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_fontData, fontData, 0);
	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIF
(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels, char* compressedFontData) {

//@line:176

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedTTF(&compressedFontData[0], fontSize, sizePixels);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIF(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels) {
	char* compressedFontData = (char*)env->GetPrimitiveArrayCritical(obj_compressedFontData, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIF(env, object, obj_compressedFontData, fontSize, sizePixels, compressedFontData);

	env->ReleasePrimitiveArrayCritical(obj_compressedFontData, compressedFontData, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIFJ
(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr, char* compressedFontData) {

//@line:187

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedTTF(&compressedFontData[0], fontSize, sizePixels, (ImFontConfig*)imFontConfigPtr);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIFJ(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr) {
	char* compressedFontData = (char*)env->GetPrimitiveArrayCritical(obj_compressedFontData, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIFJ(env, object, obj_compressedFontData, fontSize, sizePixels, imFontConfigPtr, compressedFontData);

	env->ReleasePrimitiveArrayCritical(obj_compressedFontData, compressedFontData, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIF_3S
(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels, jshortArray obj_glyphRanges, char* compressedFontData, short* glyphRanges) {

//@line:198

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedTTF(&compressedFontData[0], fontSize, sizePixels, NULL, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIF_3S(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels, jshortArray obj_glyphRanges) {
	char* compressedFontData = (char*)env->GetPrimitiveArrayCritical(obj_compressedFontData, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIF_3S(env, object, obj_compressedFontData, fontSize, sizePixels, obj_glyphRanges, compressedFontData, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_compressedFontData, compressedFontData, 0);
	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIFJ_3S
(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges, char* compressedFontData, short* glyphRanges) {

//@line:209

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedTTF(&compressedFontData[0], fontSize, sizePixels, (ImFontConfig*)imFontConfigPtr, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIFJ_3S(JNIEnv* env, jobject object, jbyteArray obj_compressedFontData, jint fontSize, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges) {
	char* compressedFontData = (char*)env->GetPrimitiveArrayCritical(obj_compressedFontData, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedTTF___3BIFJ_3S(env, object, obj_compressedFontData, fontSize, sizePixels, imFontConfigPtr, obj_glyphRanges, compressedFontData, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_compressedFontData, compressedFontData, 0);
	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2F
(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels, char* compressedFontDataBase85) {

//@line:220

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedBase85TTF(compressedFontDataBase85, sizePixels);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2F(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels) {
	char* compressedFontDataBase85 = (char*)env->GetStringUTFChars(obj_compressedFontDataBase85, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2F(env, object, obj_compressedFontDataBase85, sizePixels, compressedFontDataBase85);

	env->ReleaseStringUTFChars(obj_compressedFontDataBase85, compressedFontDataBase85);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2FJ
(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels, jlong imFontConfigPtr, char* compressedFontDataBase85) {

//@line:231

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedBase85TTF(compressedFontDataBase85, sizePixels, (ImFontConfig*)imFontConfigPtr);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2FJ(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels, jlong imFontConfigPtr) {
	char* compressedFontDataBase85 = (char*)env->GetStringUTFChars(obj_compressedFontDataBase85, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2FJ(env, object, obj_compressedFontDataBase85, sizePixels, imFontConfigPtr, compressedFontDataBase85);

	env->ReleaseStringUTFChars(obj_compressedFontDataBase85, compressedFontDataBase85);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2F_3S
(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels, jshortArray obj_glyphRanges, char* compressedFontDataBase85, short* glyphRanges) {

//@line:242

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedBase85TTF(compressedFontDataBase85, sizePixels, NULL, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2F_3S(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels, jshortArray obj_glyphRanges) {
	char* compressedFontDataBase85 = (char*)env->GetStringUTFChars(obj_compressedFontDataBase85, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2F_3S(env, object, obj_compressedFontDataBase85, sizePixels, obj_glyphRanges, compressedFontDataBase85, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);
	env->ReleaseStringUTFChars(obj_compressedFontDataBase85, compressedFontDataBase85);

	return JNI_returnValue;
}

static inline jlong wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2FJ_3S
(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges, char* compressedFontDataBase85, short* glyphRanges) {

//@line:253

        return (intptr_t)IM_FONT_ATLAS->AddFontFromMemoryCompressedBase85TTF(compressedFontDataBase85, sizePixels, (ImFontConfig*)imFontConfigPtr, (ImWchar*)&glyphRanges[0]);
    
}

JNIEXPORT jlong JNICALL Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2FJ_3S(JNIEnv* env, jobject object, jstring obj_compressedFontDataBase85, jfloat sizePixels, jlong imFontConfigPtr, jshortArray obj_glyphRanges) {
	char* compressedFontDataBase85 = (char*)env->GetStringUTFChars(obj_compressedFontDataBase85, 0);
	short* glyphRanges = (short*)env->GetPrimitiveArrayCritical(obj_glyphRanges, 0);

	jlong JNI_returnValue = wrapped_Java_imgui_ImFontAtlas_nAddFontFromMemoryCompressedBase85TTF__Ljava_lang_String_2FJ_3S(env, object, obj_compressedFontDataBase85, sizePixels, imFontConfigPtr, obj_glyphRanges, compressedFontDataBase85, glyphRanges);

	env->ReleasePrimitiveArrayCritical(obj_glyphRanges, glyphRanges, 0);
	env->ReleaseStringUTFChars(obj_compressedFontDataBase85, compressedFontDataBase85);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_clearInputData(JNIEnv* env, jobject object) {


//@line:260

        IM_FONT_ATLAS->ClearInputData();
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_clearTexData(JNIEnv* env, jobject object) {


//@line:267

        IM_FONT_ATLAS->ClearTexData();
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_clearFonts(JNIEnv* env, jobject object) {


//@line:274

        IM_FONT_ATLAS->ClearFonts();
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_clear(JNIEnv* env, jobject object) {


//@line:281

        IM_FONT_ATLAS->Clear();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFontAtlas_build(JNIEnv* env, jobject object) {


//@line:294

        return IM_FONT_ATLAS->Build();
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_getTexDataAsAlpha8(JNIEnv* env, jobject object, jintArray obj_outWidth, jintArray obj_outHeight, jintArray obj_outBytesPerPixel) {
	int* outWidth = (int*)env->GetPrimitiveArrayCritical(obj_outWidth, 0);
	int* outHeight = (int*)env->GetPrimitiveArrayCritical(obj_outHeight, 0);
	int* outBytesPerPixel = (int*)env->GetPrimitiveArrayCritical(obj_outBytesPerPixel, 0);


//@line:323

        unsigned char* pixels;
        IM_FONT_ATLAS->GetTexDataAsAlpha8(&pixels, &outWidth[0], &outHeight[0], &outBytesPerPixel[0]);

        int size = outWidth[0] * outHeight[0] * outBytesPerPixel[0];

        jobject jBuffer = env->CallObjectMethod(object, jImFontAtlasCreateAlpha8PixelsMID, size);
        char* buffer = (char*)env->GetDirectBufferAddress(jBuffer);

        memcpy(buffer, pixels, size);
    
	env->ReleasePrimitiveArrayCritical(obj_outWidth, outWidth, 0);
	env->ReleasePrimitiveArrayCritical(obj_outHeight, outHeight, 0);
	env->ReleasePrimitiveArrayCritical(obj_outBytesPerPixel, outBytesPerPixel, 0);

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_nGetTexDataAsRGBA32(JNIEnv* env, jobject object, jintArray obj_outWidth, jintArray obj_outHeight, jintArray obj_outBytesPerPixel) {
	int* outWidth = (int*)env->GetPrimitiveArrayCritical(obj_outWidth, 0);
	int* outHeight = (int*)env->GetPrimitiveArrayCritical(obj_outHeight, 0);
	int* outBytesPerPixel = (int*)env->GetPrimitiveArrayCritical(obj_outBytesPerPixel, 0);


//@line:360

        unsigned char* pixels;
        IM_FONT_ATLAS->GetTexDataAsRGBA32(&pixels, &outWidth[0], &outHeight[0], &outBytesPerPixel[0]);

        int size = outWidth[0] * outHeight[0] * outBytesPerPixel[0];

        jobject jBuffer = env->CallObjectMethod(object, jImFontAtlasCreateRgba32PixelsMID, size);
        char* buffer = (char*)env->GetDirectBufferAddress(jBuffer);

        memcpy(buffer, pixels, size);
    
	env->ReleasePrimitiveArrayCritical(obj_outWidth, outWidth, 0);
	env->ReleasePrimitiveArrayCritical(obj_outHeight, outHeight, 0);
	env->ReleasePrimitiveArrayCritical(obj_outBytesPerPixel, outBytesPerPixel, 0);

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFontAtlas_isBuilt(JNIEnv* env, jobject object) {


//@line:372

        return IM_FONT_ATLAS->IsBuilt();
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_setTexID(JNIEnv* env, jobject object, jint textureID) {


//@line:376

        IM_FONT_ATLAS->SetTexID((ImTextureID)(intptr_t)textureID);
    

}


//@line:388

        #define RETURN_GLYPH_2_SHORT(glyphs) \
            const ImWchar* ranges = glyphs; \
            int size = 0; \
            for (; ranges[0]; ranges += 2) \
                size += 2; \
            jshortArray jShorts = env->NewShortArray(size); \
            env->SetShortArrayRegion(jShorts, 0, size, (jshort*)glyphs); \
            return jShorts;
     JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesDefault(JNIEnv* env, jobject object) {


//@line:402

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesDefault());
    

}

JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesKorean(JNIEnv* env, jobject object) {


//@line:409

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesKorean());
    

}

JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesJapanese(JNIEnv* env, jobject object) {


//@line:416

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesJapanese());
    

}

JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesChineseFull(JNIEnv* env, jobject object) {


//@line:423

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesChineseFull());
    

}

JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesChineseSimplifiedCommon(JNIEnv* env, jobject object) {


//@line:430

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesChineseSimplifiedCommon());
    

}

JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesCyrillic(JNIEnv* env, jobject object) {


//@line:437

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesCyrillic());
    

}

JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesThai(JNIEnv* env, jobject object) {


//@line:444

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesThai());
    

}

JNIEXPORT jshortArray JNICALL Java_imgui_ImFontAtlas_getGlyphRangesVietnamese(JNIEnv* env, jobject object) {


//@line:451

        RETURN_GLYPH_2_SHORT(IM_FONT_ATLAS->GetGlyphRangesVietnamese());
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontAtlas_addCustomRectRegular(JNIEnv* env, jobject object, jint width, jint height) {


//@line:466

        return IM_FONT_ATLAS->AddCustomRectRegular(width, height);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontAtlas_nAddCustomRectFontGlyph__JSIIF(JNIEnv* env, jobject object, jlong imFontPtr, jshort id, jint width, jint height, jfloat advanceX) {


//@line:474

        return IM_FONT_ATLAS->AddCustomRectFontGlyph((ImFont*)imFontPtr, id, width, height, advanceX);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontAtlas_nAddCustomRectFontGlyph__JSIIFFF(JNIEnv* env, jobject object, jlong imFontPtr, jshort id, jint width, jint height, jfloat advanceX, jfloat offsetX, jfloat offsetY) {


//@line:485

        return IM_FONT_ATLAS->AddCustomRectFontGlyph((ImFont*)imFontPtr, id, width, height, advanceX, ImVec2(offsetX, offsetY));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFontAtlas_getLocked(JNIEnv* env, jobject object) {


//@line:498

        return IM_FONT_ATLAS->Locked;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_setLocked(JNIEnv* env, jobject object, jboolean locked) {


//@line:505

        IM_FONT_ATLAS->Locked = locked;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontAtlas_getFlags(JNIEnv* env, jobject object) {


//@line:512

        return IM_FONT_ATLAS->Flags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_setFlags(JNIEnv* env, jobject object, jint imFontAtlasFlags) {


//@line:519

        IM_FONT_ATLAS->Flags = imFontAtlasFlags;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontAtlas_getTexID(JNIEnv* env, jobject object) {


//@line:548

        return (int)(intptr_t)(void*)IM_FONT_ATLAS->TexID;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontAtlas_getTexDesiredWidth(JNIEnv* env, jobject object) {


//@line:556

        return IM_FONT_ATLAS->TexDesiredWidth;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_setTexDesiredWidth(JNIEnv* env, jobject object, jint texDesiredWidth) {


//@line:564

        IM_FONT_ATLAS->TexDesiredWidth = texDesiredWidth;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFontAtlas_getTexGlyphPadding(JNIEnv* env, jobject object) {


//@line:572

        return IM_FONT_ATLAS->TexGlyphPadding;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFontAtlas_setTexGlyphPadding(JNIEnv* env, jobject object, jint texGlyphPadding) {


//@line:580

        IM_FONT_ATLAS->TexGlyphPadding = texGlyphPadding;
    

}


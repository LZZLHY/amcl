#include <imgui_ImFont.h>

//@line:20

        #include "_common.h"

        #define IM_FONT ((ImFont*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_ImFont_nCreate(JNIEnv* env, jobject object) {


//@line:31

        return (intptr_t)(new ImFont());
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_getFallbackAdvanceX(JNIEnv* env, jobject object) {


//@line:40

        return IM_FONT->FallbackAdvanceX;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setFallbackAdvanceX(JNIEnv* env, jobject object, jfloat fallbackAdvanceX) {


//@line:47

        IM_FONT->FallbackAdvanceX = fallbackAdvanceX;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_getFontSize(JNIEnv* env, jobject object) {


//@line:54

        return IM_FONT->FontSize;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImFont_nGetFallbackGlyphPtr(JNIEnv* env, jobject object) {


//@line:68

        return (intptr_t)IM_FONT->FallbackGlyph;
    

}

JNIEXPORT jshort JNICALL Java_imgui_ImFont_getConfigDataCount(JNIEnv* env, jobject object) {


//@line:78

        return IM_FONT->ConfigDataCount;
    

}

JNIEXPORT jshort JNICALL Java_imgui_ImFont_getFallbackChar(JNIEnv* env, jobject object) {


//@line:85

        return IM_FONT->FallbackChar;
    

}

JNIEXPORT jshort JNICALL Java_imgui_ImFont_getEllipsisChar(JNIEnv* env, jobject object) {


//@line:92

        return IM_FONT->EllipsisChar;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setEllipsisChar(JNIEnv* env, jobject object, jint ellipsisChar) {


//@line:99

        IM_FONT->EllipsisChar = (ImWchar)ellipsisChar;
    

}

JNIEXPORT jshort JNICALL Java_imgui_ImFont_getDotChar(JNIEnv* env, jobject object) {


//@line:106

        return IM_FONT->DotChar;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setDotChar(JNIEnv* env, jobject object, jint dotChar) {


//@line:113

        IM_FONT->DotChar = (ImWchar)dotChar;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFont_getDirtyLookupTables(JNIEnv* env, jobject object) {


//@line:117

        return IM_FONT->DirtyLookupTables;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setDirtyLookupTables(JNIEnv* env, jobject object, jboolean dirtyLookupTables) {


//@line:121

        IM_FONT->DirtyLookupTables = dirtyLookupTables;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_getScale(JNIEnv* env, jobject object) {


//@line:128

        return IM_FONT->Scale;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setScale(JNIEnv* env, jobject object, jfloat scale) {


//@line:135

        IM_FONT->Scale = scale;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_getAscent(JNIEnv* env, jobject object) {


//@line:142

        return IM_FONT->Ascent;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setAscent(JNIEnv* env, jobject object, jfloat ascent) {


//@line:149

        IM_FONT->Ascent = ascent;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_getDescent(JNIEnv* env, jobject object) {


//@line:156

        return IM_FONT->Descent;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setDescent(JNIEnv* env, jobject object, jfloat descent) {


//@line:163

        IM_FONT->Descent = descent;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImFont_getMetricsTotalSurface(JNIEnv* env, jobject object) {


//@line:170

        return IM_FONT->MetricsTotalSurface;
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_setMetricsTotalSurface(JNIEnv* env, jobject object, jint metricsTotalSurface) {


//@line:177

        IM_FONT->MetricsTotalSurface = metricsTotalSurface;
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImFont_nFindGlyph(JNIEnv* env, jobject object, jint c) {


//@line:188

        return (intptr_t)IM_FONT->FindGlyph((ImWchar)c);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImFont_nFindGlyphNoFallback(JNIEnv* env, jobject object, jint c) {


//@line:197

        return (intptr_t)IM_FONT->FindGlyphNoFallback((ImWchar)c);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_getCharAdvance(JNIEnv* env, jobject object, jint c) {


//@line:201

        return IM_FONT->GetCharAdvance((ImWchar)c);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImFont_isLoaded(JNIEnv* env, jobject object) {


//@line:205

        return IM_FONT->IsLoaded();
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImFont_getDebugName(JNIEnv* env, jobject object) {


//@line:209

        return env->NewStringUTF(IM_FONT->GetDebugName());
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_calcTextSizeA(JNIEnv* env, jobject object, jobject dstImVec2, jfloat size, jfloat maxWidth, jfloat wrapWidth, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:223

        Jni::ImVec2Cpy(env, IM_FONT->CalcTextSizeA(size, maxWidth, wrapWidth, text), dstImVec2);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

static inline jfloat wrapped_Java_imgui_ImFont_calcTextSizeAX
(JNIEnv* env, jobject object, jfloat size, jfloat maxWidth, jfloat wrapWidth, jstring obj_text, char* text) {

//@line:231

        return IM_FONT->CalcTextSizeA(size, maxWidth, wrapWidth, text).x;
    
}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_calcTextSizeAX(JNIEnv* env, jobject object, jfloat size, jfloat maxWidth, jfloat wrapWidth, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);

	jfloat JNI_returnValue = wrapped_Java_imgui_ImFont_calcTextSizeAX(env, object, size, maxWidth, wrapWidth, obj_text, text);

	env->ReleaseStringUTFChars(obj_text, text);

	return JNI_returnValue;
}

static inline jfloat wrapped_Java_imgui_ImFont_calcTextSizeAY
(JNIEnv* env, jobject object, jfloat size, jfloat maxWidth, jfloat wrapWidth, jstring obj_text, char* text) {

//@line:239

        return IM_FONT->CalcTextSizeA(size, maxWidth, wrapWidth, text).y;
    
}

JNIEXPORT jfloat JNICALL Java_imgui_ImFont_calcTextSizeAY(JNIEnv* env, jobject object, jfloat size, jfloat maxWidth, jfloat wrapWidth, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);

	jfloat JNI_returnValue = wrapped_Java_imgui_ImFont_calcTextSizeAY(env, object, size, maxWidth, wrapWidth, obj_text, text);

	env->ReleaseStringUTFChars(obj_text, text);

	return JNI_returnValue;
}

static inline jstring wrapped_Java_imgui_ImFont_calcWordWrapPositionA
(JNIEnv* env, jobject object, jfloat scale, jstring obj_text, jstring obj_textEnd, jfloat wrapWidth, char* text, char* textEnd) {

//@line:243

        return env->NewStringUTF(IM_FONT->CalcWordWrapPositionA(scale, text, textEnd, wrapWidth));
    
}

JNIEXPORT jstring JNICALL Java_imgui_ImFont_calcWordWrapPositionA(JNIEnv* env, jobject object, jfloat scale, jstring obj_text, jstring obj_textEnd, jfloat wrapWidth) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);
	char* textEnd = (char*)env->GetStringUTFChars(obj_textEnd, 0);

	jstring JNI_returnValue = wrapped_Java_imgui_ImFont_calcWordWrapPositionA(env, object, scale, obj_text, obj_textEnd, wrapWidth, text, textEnd);

	env->ReleaseStringUTFChars(obj_text, text);
	env->ReleaseStringUTFChars(obj_textEnd, textEnd);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImFont_nRenderChar(JNIEnv* env, jobject object, jlong drawListPtr, jfloat size, jfloat posX, jfloat posY, jint col, jint c) {


//@line:251

        IM_FONT->RenderChar((ImDrawList*)drawListPtr, size, ImVec2(posX, posY), col, (ImWchar)c);
    

}

JNIEXPORT void JNICALL Java_imgui_ImFont_nRenderText(JNIEnv* env, jobject object, jlong drawListPtr, jfloat size, jfloat posX, jfloat posY, jint col, jfloat clipRectX, jfloat clipRectY, jfloat clipRectW, jfloat clipRectZ, jstring obj_text, jstring obj_textEnd, jfloat wrapWidth, jboolean cpuFineClip) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);
	char* textEnd = (char*)env->GetStringUTFChars(obj_textEnd, 0);


//@line:267

        IM_FONT->RenderText((ImDrawList*)drawListPtr, size, ImVec2(posX, posY), col, ImVec4(clipRectX, clipRectY, clipRectW, clipRectZ), text, textEnd, wrapWidth, cpuFineClip);
    
	env->ReleaseStringUTFChars(obj_text, text);
	env->ReleaseStringUTFChars(obj_textEnd, textEnd);

}


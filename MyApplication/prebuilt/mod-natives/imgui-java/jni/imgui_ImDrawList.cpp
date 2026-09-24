#include <imgui_ImDrawList.h>

//@line:21

        #include "_common.h"

        #define IM_DRAW_LIST ((ImDrawList*)STRUCT_PTR)
     JNIEXPORT jint JNICALL Java_imgui_ImDrawList_getImDrawListFlags(JNIEnv* env, jobject object) {


//@line:30

        return IM_DRAW_LIST->Flags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_setImDrawListFlags(JNIEnv* env, jobject object, jint imDrawListFlags) {


//@line:37

        IM_DRAW_LIST->Flags = imDrawListFlags;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pushClipRect__FFFF(JNIEnv* env, jobject object, jfloat clipRectMinX, jfloat clipRectMinY, jfloat clipRectMaxX, jfloat clipRectMaxY) {


//@line:67

        IM_DRAW_LIST->PushClipRect(ImVec2(clipRectMinX, clipRectMinY), ImVec2(clipRectMaxX, clipRectMaxY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pushClipRect__FFFFZ(JNIEnv* env, jobject object, jfloat clipRectMinX, jfloat clipRectMinY, jfloat clipRectMaxX, jfloat clipRectMaxY, jboolean intersectWithCurrentClipRect) {


//@line:76

        IM_DRAW_LIST->PushClipRect(ImVec2(clipRectMinX, clipRectMinY), ImVec2(clipRectMaxX, clipRectMaxY), intersectWithCurrentClipRect);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pushClipRectFullScreen(JNIEnv* env, jobject object) {


//@line:80

        IM_DRAW_LIST->PushClipRectFullScreen();
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_popClipRect(JNIEnv* env, jobject object) {


//@line:84

        IM_DRAW_LIST->PopClipRect();
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pushTextureId(JNIEnv* env, jobject object, jint textureId) {


//@line:88

        IM_DRAW_LIST->PushTextureID((ImTextureID)(intptr_t)textureId);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_popTextureId(JNIEnv* env, jobject object) {


//@line:92

        IM_DRAW_LIST->PopTextureID();
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_getClipRectMin(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:102

        Jni::ImVec2Cpy(env, IM_DRAW_LIST->GetClipRectMin(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawList_getClipRectMinX(JNIEnv* env, jobject object) {


//@line:106

        return IM_DRAW_LIST->GetClipRectMin().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawList_getClipRectMinY(JNIEnv* env, jobject object) {


//@line:110

        return IM_DRAW_LIST->GetClipRectMin().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_getClipRectMax(JNIEnv* env, jobject object, jobject dstImVec2) {


//@line:120

        Jni::ImVec2Cpy(env, IM_DRAW_LIST->GetClipRectMax(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawList_getClipRectMaxX(JNIEnv* env, jobject object) {


//@line:124

        return IM_DRAW_LIST->GetClipRectMax().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImDrawList_getClipRectMaxY(JNIEnv* env, jobject object) {


//@line:128

        return IM_DRAW_LIST->GetClipRectMax().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addLine__FFFFI(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jint col) {


//@line:139

        IM_DRAW_LIST->AddLine(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addLine__FFFFIF(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jint col, jfloat thickness) {


//@line:143

        IM_DRAW_LIST->AddLine(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), col, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRect__FFFFI(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jint col) {


//@line:147

        IM_DRAW_LIST->AddRect(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), col);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRect__FFFFIF(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jint col, jfloat rounding) {


//@line:151

        IM_DRAW_LIST->AddRect(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), col, rounding);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRect__FFFFIFI(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jint col, jfloat rounding, jint imDrawFlags) {


//@line:155

        IM_DRAW_LIST->AddRect(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), col, rounding, imDrawFlags);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRect__FFFFIFIF(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jint col, jfloat rounding, jint imDrawFlags, jfloat thickness) {


//@line:159

        IM_DRAW_LIST->AddRect(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), col, rounding, imDrawFlags, thickness);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRectFilled__FFFFI(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jint col) {


//@line:163

        IM_DRAW_LIST->AddRectFilled(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), col);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRectFilled__FFFFIF(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jint col, jfloat rounding) {


//@line:167

        IM_DRAW_LIST->AddRectFilled(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), col, rounding);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRectFilled__FFFFIFI(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jint col, jfloat rounding, jint imDrawFlags) {


//@line:171

        IM_DRAW_LIST->AddRectFilled(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), col, rounding, imDrawFlags);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addRectFilledMultiColor(JNIEnv* env, jobject object, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jlong colUprLeft, jlong colUprRight, jlong colBotRight, jlong colBotLeft) {


//@line:175

        IM_DRAW_LIST->AddRectFilledMultiColor(ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), colUprLeft, colUprRight, colBotRight, colBotLeft);
     

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addQuad__FFFFFFFFI(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jint col) {


//@line:179

        IM_DRAW_LIST->AddQuad(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addQuad__FFFFFFFFIF(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jint col, jfloat thickness) {


//@line:183

        IM_DRAW_LIST->AddQuad(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), col, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addQuadFilled(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jint col) {


//@line:187

        IM_DRAW_LIST->AddQuadFilled(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addTriangle__FFFFFFI(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jint col) {


//@line:191

        IM_DRAW_LIST->AddTriangle(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addTriangle__FFFFFFIF(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jint col, jfloat thickness) {


//@line:195

        IM_DRAW_LIST->AddTriangle(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), col, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addTriangleFilled(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jint col) {


//@line:199

        IM_DRAW_LIST->AddTriangleFilled(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addCircle__FFFI(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col) {


//@line:203

        IM_DRAW_LIST->AddCircle(ImVec2(centreX, centreY), radius, col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addCircle__FFFII(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col, jint numSegments) {


//@line:207

        IM_DRAW_LIST->AddCircle(ImVec2(centreX, centreY), radius, col, numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addCircle__FFFIIF(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col, jint numSegments, jfloat thickness) {


//@line:211

        IM_DRAW_LIST->AddCircle(ImVec2(centreX, centreY), radius, col, numSegments, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addCircleFilled__FFFI(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col) {


//@line:215

        IM_DRAW_LIST->AddCircleFilled(ImVec2(centreX, centreY), radius, col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addCircleFilled__FFFII(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col, jint numSegments) {


//@line:219

        IM_DRAW_LIST->AddCircleFilled(ImVec2(centreX, centreY), radius, col, numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addNgon__FFFII(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col, jint numSegments) {


//@line:223

        IM_DRAW_LIST->AddNgon(ImVec2(centreX, centreY), radius, col, numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addNgon__FFFIIF(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col, jint numSegments, jfloat thickness) {


//@line:227

        IM_DRAW_LIST->AddNgon(ImVec2(centreX, centreY), radius, col, numSegments, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addNgonFilled(JNIEnv* env, jobject object, jfloat centreX, jfloat centreY, jfloat radius, jint col, jint numSegments) {


//@line:231

        IM_DRAW_LIST->AddNgonFilled(ImVec2(centreX, centreY), radius, col, numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addText(JNIEnv* env, jobject object, jfloat posX, jfloat posY, jint col, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:235

        IM_DRAW_LIST->AddText(ImVec2(posX, posY), col, text);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_nAddText__JFFFILjava_lang_String_2(JNIEnv* env, jobject object, jlong imFontPtr, jfloat fontSize, jfloat posX, jfloat posY, jint col, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:243

        IM_DRAW_LIST->AddText((ImFont*)imFontPtr, fontSize, ImVec2(posX, posY), col, text);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_nAddText__JFFFILjava_lang_String_2F(JNIEnv* env, jobject object, jlong imFontPtr, jfloat fontSize, jfloat posX, jfloat posY, jint col, jstring obj_text, jfloat wrapWidth) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:251

        IM_DRAW_LIST->AddText((ImFont*)imFontPtr, fontSize, ImVec2(posX, posY), col, text, NULL, wrapWidth);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_nAddText__JFFFILjava_lang_String_2FFFFF(JNIEnv* env, jobject object, jlong imFontPtr, jfloat fontSize, jfloat posX, jfloat posY, jint col, jstring obj_text, jfloat wrapWidth, jfloat cpuFineClipRectX, jfloat cpuFineClipRectY, jfloat cpuFineClipRectZ, jfloat cpuFineClipRectV) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:259

        ImVec4 cpuFineClipRect = ImVec4(cpuFineClipRectX, cpuFineClipRectY, cpuFineClipRectZ, cpuFineClipRectV);
        IM_DRAW_LIST->AddText((ImFont*)imFontPtr, fontSize, ImVec2(posX, posY), col, text, NULL, wrapWidth, &cpuFineClipRect);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addPolyline(JNIEnv* env, jobject object, jobjectArray points, jint numPoints, jint col, jint imDrawFlags, jfloat thickness) {


//@line:264

        int points_num = env->GetArrayLength(points);
        ImVec2 _points[points_num];
        for (int i = 0; i < points_num; i++) {
            jobject jImVec2 = env->GetObjectArrayElement(points, i);
            ImVec2 dst;
            Jni::ImVec2Cpy(env, jImVec2, &dst);
            _points[i] = dst;
        }
        IM_DRAW_LIST->AddPolyline(_points, numPoints, col, imDrawFlags, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addConvexPolyFilled(JNIEnv* env, jobject object, jobjectArray points, jint numPoints, jint col) {


//@line:277

        int points_num = env->GetArrayLength(points);
        ImVec2 _points[points_num];
        for (int i = 0; i < points_num; i++) {
            jobject jImVec2 = env->GetObjectArrayElement(points, i);
            ImVec2 dst;
            Jni::ImVec2Cpy(env, jImVec2, &dst);
            _points[i] = dst;
        }
        IM_DRAW_LIST->AddConvexPolyFilled(_points, numPoints, col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addBezierCubic__FFFFFFFFIF(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jint col, jfloat thickness) {


//@line:292

        IM_DRAW_LIST->AddBezierCubic(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), col, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addBezierCubic__FFFFFFFFIFI(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jint col, jfloat thickness, jint numSegments) {


//@line:299

        IM_DRAW_LIST->AddBezierCubic(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), col, thickness, numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addBezierQuadratic__FFFFFFIF(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jint col, jfloat thickness) {


//@line:306

        IM_DRAW_LIST->AddBezierQuadratic(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), col, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addBezierQuadratic__FFFFFFIFI(JNIEnv* env, jobject object, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jint col, jfloat thickness, jint numSegments) {


//@line:313

        IM_DRAW_LIST->AddBezierQuadratic(ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), col, thickness, numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImage__IFFFF(JNIEnv* env, jobject object, jint textureID, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY) {


//@line:322

        IM_DRAW_LIST->AddImage((ImTextureID)(intptr_t)textureID, ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImage__IFFFFFF(JNIEnv* env, jobject object, jint textureID, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jfloat uvMinX, jfloat uvMinY) {


//@line:326

        IM_DRAW_LIST->AddImage((ImTextureID)(intptr_t)textureID, ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), ImVec2(uvMinX, uvMinY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImage__IFFFFFFFF(JNIEnv* env, jobject object, jint textureID, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jfloat uvMinX, jfloat uvMinY, jfloat uvMaxX, jfloat uvMaxY) {


//@line:330

        IM_DRAW_LIST->AddImage((ImTextureID)(intptr_t)textureID, ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), ImVec2(uvMinX, uvMinY), ImVec2(uvMaxX, uvMaxY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImage__IFFFFFFFFI(JNIEnv* env, jobject object, jint textureID, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jfloat uvMinX, jfloat uvMinY, jfloat uvMaxX, jfloat uvMaxY, jint col) {


//@line:334

        IM_DRAW_LIST->AddImage((ImTextureID)(intptr_t)textureID, ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), ImVec2(uvMinX, uvMinY), ImVec2(uvMaxX, uvMaxY), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageQuad__IFFFFFFFF(JNIEnv* env, jobject object, jint textureID, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y) {


//@line:338

        IM_DRAW_LIST->AddImageQuad((ImTextureID)(intptr_t)textureID, ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageQuad__IFFFFFFFFFF(JNIEnv* env, jobject object, jint textureID, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jfloat uv1X, jfloat uv1Y) {


//@line:342

        IM_DRAW_LIST->AddImageQuad((ImTextureID)(intptr_t)textureID, ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), ImVec2(uv1X, uv1Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageQuad__IFFFFFFFFFFFF(JNIEnv* env, jobject object, jint textureID, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jfloat uv1X, jfloat uv1Y, jfloat uv2X, jfloat uv2Y) {


//@line:346

        IM_DRAW_LIST->AddImageQuad((ImTextureID)(intptr_t)textureID, ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), ImVec2(uv1X, uv1Y), ImVec2(uv2X, uv2Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageQuad__IFFFFFFFFFFFFFF(JNIEnv* env, jobject object, jint textureID, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jfloat uv1X, jfloat uv1Y, jfloat uv2X, jfloat uv2Y, jfloat uv3X, jfloat uv3Y) {


//@line:350

        IM_DRAW_LIST->AddImageQuad((ImTextureID)(intptr_t)textureID, ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), ImVec2(uv1X, uv1Y), ImVec2(uv2X, uv2Y), ImVec2(uv3X, uv3Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageQuad__IFFFFFFFFFFFFFFFF(JNIEnv* env, jobject object, jint textureID, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jfloat uv1X, jfloat uv1Y, jfloat uv2X, jfloat uv2Y, jfloat uv3X, jfloat uv3Y, jfloat uv4X, jfloat uv4Y) {


//@line:354

        IM_DRAW_LIST->AddImageQuad((ImTextureID)(intptr_t)textureID, ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), ImVec2(uv1X, uv1Y), ImVec2(uv2X, uv2Y), ImVec2(uv3X, uv3Y), ImVec2(uv4X, uv4Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageQuad__IFFFFFFFFFFFFFFFFI(JNIEnv* env, jobject object, jint textureID, jfloat p1X, jfloat p1Y, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jfloat uv1X, jfloat uv1Y, jfloat uv2X, jfloat uv2Y, jfloat uv3X, jfloat uv3Y, jfloat uv4X, jfloat uv4Y, jint col) {


//@line:358

        IM_DRAW_LIST->AddImageQuad((ImTextureID)(intptr_t)textureID, ImVec2(p1X, p1Y), ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), ImVec2(uv1X, uv1Y), ImVec2(uv2X, uv2Y), ImVec2(uv3X, uv3Y), ImVec2(uv4X, uv4Y), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageRounded__IFFFFFFFFIF(JNIEnv* env, jobject object, jint textureID, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jfloat uvMinX, jfloat uvMinY, jfloat uvMaxX, jfloat uvMaxY, jint col, jfloat rounding) {


//@line:362

        IM_DRAW_LIST->AddImageRounded((ImTextureID)(intptr_t)textureID, ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), ImVec2(uvMinX, uvMinY), ImVec2(uvMaxX, uvMaxY), col, rounding);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_addImageRounded__IFFFFFFFFIFI(JNIEnv* env, jobject object, jint textureID, jfloat pMinX, jfloat pMinY, jfloat pMaxX, jfloat pMaxY, jfloat uvMinX, jfloat uvMinY, jfloat uvMaxX, jfloat uvMaxY, jint col, jfloat rounding, jint imDrawFlags) {


//@line:366

        IM_DRAW_LIST->AddImageRounded((ImTextureID)(intptr_t)textureID, ImVec2(pMinX, pMinY), ImVec2(pMaxX, pMaxY), ImVec2(uvMinX, uvMinY), ImVec2(uvMaxX, uvMaxY), col, rounding, imDrawFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathClear(JNIEnv* env, jobject object) {


//@line:372

        IM_DRAW_LIST->PathClear();
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathLineTo(JNIEnv* env, jobject object, jfloat posX, jfloat posY) {


//@line:376

        IM_DRAW_LIST->PathLineTo(ImVec2(posX, posY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathLineToMergeDuplicate(JNIEnv* env, jobject object, jfloat posX, jfloat posY) {


//@line:380

        IM_DRAW_LIST->PathLineToMergeDuplicate(ImVec2(posX, posY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathFillConvex(JNIEnv* env, jobject object, jint col) {


//@line:385

        IM_DRAW_LIST->PathFillConvex(col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathStroke__II(JNIEnv* env, jobject object, jint col, jint imDrawFlags) {


//@line:389

        IM_DRAW_LIST->PathStroke(col, imDrawFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathStroke__IIF(JNIEnv* env, jobject object, jint col, jint imDrawFlags, jfloat thickness) {


//@line:393

        IM_DRAW_LIST->PathStroke(col, imDrawFlags, thickness);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathArcTo__FFFFF(JNIEnv* env, jobject object, jfloat centerX, jfloat centerY, jfloat radius, jfloat aMin, jfloat aMax) {


//@line:397

        IM_DRAW_LIST->PathArcTo(ImVec2(centerX, centerY), radius, aMin, aMax);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathArcTo__FFFFFI(JNIEnv* env, jobject object, jfloat centerX, jfloat centerY, jfloat radius, jfloat aMin, jfloat aMax, jint numSegments) {


//@line:401

        IM_DRAW_LIST->PathArcTo(ImVec2(centerX, centerY), radius, aMin, aMax, numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathArcToFast(JNIEnv* env, jobject object, jfloat centerX, jfloat centerY, jfloat radius, jint aMinOf12, jint aMaxOf12) {


//@line:408

        IM_DRAW_LIST->PathArcToFast(ImVec2(centerX, centerY), radius, aMinOf12, aMaxOf12);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathBezierCubicCurveTo__FFFFFF(JNIEnv* env, jobject object, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y) {


//@line:415

        IM_DRAW_LIST->PathBezierCubicCurveTo(ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathBezierCubicCurveTo__FFFFFFI(JNIEnv* env, jobject object, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jfloat p4X, jfloat p4Y, jint numSegments) {


//@line:422

        IM_DRAW_LIST->PathBezierCubicCurveTo(ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), ImVec2(p4X, p4Y), numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathBezierQuadraticCurveTo__FFFF(JNIEnv* env, jobject object, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y) {


//@line:429

        IM_DRAW_LIST->PathBezierQuadraticCurveTo(ImVec2(p2X, p2Y), ImVec2(p3X, p3Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathBezierQuadraticCurveTo__FFFFI(JNIEnv* env, jobject object, jfloat p2X, jfloat p2Y, jfloat p3X, jfloat p3Y, jint numSegments) {


//@line:436

        IM_DRAW_LIST->PathBezierQuadraticCurveTo(ImVec2(p2X, p2Y), ImVec2(p3X, p3Y), numSegments);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathRect__FFFF(JNIEnv* env, jobject object, jfloat rectMinX, jfloat rectMinY, jfloat rectMaxX, jfloat rectMaxY) {


//@line:440

        IM_DRAW_LIST->PathRect(ImVec2(rectMinX, rectMinY), ImVec2(rectMaxX, rectMaxY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathRect__FFFFF(JNIEnv* env, jobject object, jfloat rectMinX, jfloat rectMinY, jfloat rectMaxX, jfloat rectMaxY, jfloat rounding) {


//@line:444

        IM_DRAW_LIST->PathRect(ImVec2(rectMinX, rectMinY), ImVec2(rectMaxX, rectMaxY), rounding);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_pathRect__FFFFFI(JNIEnv* env, jobject object, jfloat rectMinX, jfloat rectMinY, jfloat rectMaxX, jfloat rectMaxY, jfloat rounding, jint imDrawFlags) {


//@line:448

        IM_DRAW_LIST->PathRect(ImVec2(rectMinX, rectMinY), ImVec2(rectMaxX, rectMaxY), rounding, imDrawFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_channelsSplit(JNIEnv* env, jobject object, jint count) {


//@line:458

        IM_DRAW_LIST->ChannelsSplit(count);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_channelsMerge(JNIEnv* env, jobject object) {


//@line:462

        IM_DRAW_LIST->ChannelsMerge();
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_channelsSetCurrent(JNIEnv* env, jobject object, jint n) {


//@line:466

        IM_DRAW_LIST->ChannelsSetCurrent(n);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_primReserve(JNIEnv* env, jobject object, jint idxCount, jint vtxCount) {


//@line:474

        IM_DRAW_LIST->PrimReserve(idxCount, vtxCount);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_primUnreserve(JNIEnv* env, jobject object, jint idxCount, jint vtxCount) {


//@line:478

        IM_DRAW_LIST->PrimUnreserve(idxCount, vtxCount);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_primRect(JNIEnv* env, jobject object, jfloat ax, jfloat ay, jfloat bx, jfloat by, jint col) {


//@line:482

        IM_DRAW_LIST->PrimRect(ImVec2(ax, ay), ImVec2(bx, by), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_primRectUV(JNIEnv* env, jobject object, jfloat ax, jfloat ay, jfloat bx, jfloat by, jfloat uvAx, jfloat uvAy, jfloat uvBx, jfloat uvBy, jint col) {


//@line:486

        IM_DRAW_LIST->PrimRectUV(ImVec2(ax, ay), ImVec2(bx, by), ImVec2(uvAx, uvAy), ImVec2(uvBx, uvBy), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_primQuadUV(JNIEnv* env, jobject object, jfloat ax, jfloat ay, jfloat bx, jfloat by, jfloat cx, jfloat cy, jfloat dx, jfloat dy, jfloat uvAx, jfloat uvAy, jfloat uvBx, jfloat uvBy, jfloat uvCx, jfloat uvCy, jfloat uvDx, jfloat uvDy, jint col) {


//@line:490

        IM_DRAW_LIST->PrimQuadUV(ImVec2(ax, ay), ImVec2(bx, by), ImVec2(cx, cy), ImVec2(dx, dy), ImVec2(uvAx, uvAy), ImVec2(uvBx, uvBy), ImVec2(uvCx, uvCy), ImVec2(uvDx, uvDy), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_primWriteVtx(JNIEnv* env, jobject object, jfloat posX, jfloat posY, jfloat uvX, jfloat uvY, jint col) {


//@line:494

        IM_DRAW_LIST->PrimWriteVtx(ImVec2(posX, posY), ImVec2(uvX, uvY), col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImDrawList_primVtx(JNIEnv* env, jobject object, jfloat posX, jfloat posY, jfloat uvX, jfloat uvY, jint col) {


//@line:498

        IM_DRAW_LIST->PrimVtx(ImVec2(posX, posY), ImVec2(uvX, uvY), col);
    

}


#include <imgui_ImGuiPlatformMonitor.h>
#include <imgui_ImGuiIO.h>
#include <imgui_ImGuiPlatformIO.h>
#include <imgui_ImGui.h>
#include <imgui_ImGuiListClipper.h>

//@line:168

        #include "_common.h"
     JNIEXPORT void JNICALL Java_imgui_ImGui_nInitJni(JNIEnv* env, jclass clazz) {


//@line:172

        Jni::InitJvm(env);
        Jni::InitCommon(env);
        Jni::InitAssertion(env);
        Jni::InitCallbacks(env);
        Jni::InitBindingStruct(env);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nCreateContext__(JNIEnv* env, jclass clazz) {


//@line:192

        return (intptr_t)ImGui::CreateContext();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nCreateContext__J(JNIEnv* env, jclass clazz, jlong sharedFontAtlasPtr) {


//@line:201

        return (intptr_t)ImGui::CreateContext((ImFontAtlas*)sharedFontAtlasPtr);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_destroyContext(JNIEnv* env, jclass clazz) {


//@line:205

        ImGui::DestroyContext();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nDestroyContext(JNIEnv* env, jclass clazz, jlong ptr) {


//@line:213

        ImGui::DestroyContext((ImGuiContext*) ptr);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetCurrentContext(JNIEnv* env, jclass clazz) {


//@line:222

        return (intptr_t)ImGui::GetCurrentContext();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nSetCurrentContext(JNIEnv* env, jclass clazz, jlong ptr) {


//@line:230

        ImGui::SetCurrentContext((ImGuiContext*) ptr);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setAssertCallback(JNIEnv* env, jclass clazz, jobject callback) {


//@line:241

        Jni::SetAssertionCallback(callback);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetIO(JNIEnv* env, jclass clazz) {


//@line:255

        return (intptr_t)&ImGui::GetIO();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetStyle(JNIEnv* env, jclass clazz) {


//@line:267

        return (intptr_t)&ImGui::GetStyle();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_newFrame(JNIEnv* env, jclass clazz) {


//@line:274

        ImGui::NewFrame();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endFrame(JNIEnv* env, jclass clazz) {


//@line:282

        ImGui::EndFrame();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_render(JNIEnv* env, jclass clazz) {


//@line:289

        ImGui::Render();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetDrawData(JNIEnv* env, jclass clazz) {


//@line:301

        return (intptr_t)ImGui::GetDrawData();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_showDemoWindow(JNIEnv* env, jclass clazz) {


//@line:310

        ImGui::ShowDemoWindow();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nShowDemoWindow(JNIEnv* env, jclass clazz, jbooleanArray obj_pOpen) {
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);


//@line:318

        ImGui::ShowDemoWindow(&pOpen[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_showMetricsWindow(JNIEnv* env, jclass clazz) {


//@line:332

        ImGui::ShowMetricsWindow();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nShowMetricsWindow(JNIEnv* env, jclass clazz, jbooleanArray obj_pOpen) {
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);


//@line:336

        ImGui::ShowMetricsWindow(&pOpen[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_showStackToolWindow(JNIEnv* env, jclass clazz) {


//@line:350

        ImGui::ShowStackToolWindow();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nShowStackToolWindow(JNIEnv* env, jclass clazz, jbooleanArray obj_pOpen) {
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);


//@line:354

        ImGui::ShowStackToolWindow(&pOpen[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_showAboutWindow(JNIEnv* env, jclass clazz) {


//@line:361

        ImGui::ShowAboutWindow();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nShowAboutWindow(JNIEnv* env, jclass clazz, jbooleanArray obj_pOpen) {
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);


//@line:369

        ImGui::ShowAboutWindow(&pOpen[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_showStyleEditor(JNIEnv* env, jclass clazz) {


//@line:377

        ImGui::ShowStyleEditor();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nShowStyleEditor(JNIEnv* env, jclass clazz, jlong ref) {


//@line:385

        ImGui::ShowStyleEditor((ImGuiStyle*)ref);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_showStyleSelector
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:392

        return ImGui::ShowStyleSelector(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_showStyleSelector(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_showStyleSelector(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_showFontSelector(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);


//@line:399

        ImGui::ShowFontSelector(label);
    
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_showUserGuide(JNIEnv* env, jclass clazz) {


//@line:406

        ImGui::ShowUserGuide();
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGui_getVersion(JNIEnv* env, jclass clazz) {


//@line:413

        return env->NewStringUTF(ImGui::GetVersion());
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_styleColorsDark(JNIEnv* env, jclass clazz) {


//@line:422

        ImGui::StyleColorsDark();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nStyleColorsDark(JNIEnv* env, jclass clazz, jlong ptr) {


//@line:430

        ImGui::StyleColorsDark((ImGuiStyle*)ptr);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_styleColorsLight(JNIEnv* env, jclass clazz) {


//@line:437

        ImGui::StyleColorsLight();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nStyleColorsLight(JNIEnv* env, jclass clazz, jlong ptr) {


//@line:445

        ImGui::StyleColorsLight((ImGuiStyle*)ptr);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_styleColorsClassic(JNIEnv* env, jclass clazz) {


//@line:452

        ImGui::StyleColorsClassic();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nStyleColorsClassic(JNIEnv* env, jclass clazz, jlong ptr) {


//@line:460

        ImGui::StyleColorsClassic((ImGuiStyle*)ptr);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_begin
(JNIEnv* env, jclass clazz, jstring obj_title, char* title) {

//@line:478

        return ImGui::Begin(title);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_begin(JNIEnv* env, jclass clazz, jstring obj_title) {
	char* title = (char*)env->GetStringUTFChars(obj_title, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_begin(env, clazz, obj_title, title);

	env->ReleaseStringUTFChars(obj_title, title);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nBegin__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_title, jint imGuiWindowFlags, char* title) {

//@line:494

        return ImGui::Begin(title, NULL, imGuiWindowFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nBegin__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_title, jint imGuiWindowFlags) {
	char* title = (char*)env->GetStringUTFChars(obj_title, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nBegin__Ljava_lang_String_2I(env, clazz, obj_title, imGuiWindowFlags, title);

	env->ReleaseStringUTFChars(obj_title, title);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nBegin__Ljava_lang_String_2_3ZI
(JNIEnv* env, jclass clazz, jstring obj_title, jbooleanArray obj_pOpen, jint imGuiWindowFlags, char* title, bool* pOpen) {

//@line:498

        return ImGui::Begin(title, &pOpen[0], imGuiWindowFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nBegin__Ljava_lang_String_2_3ZI(JNIEnv* env, jclass clazz, jstring obj_title, jbooleanArray obj_pOpen, jint imGuiWindowFlags) {
	char* title = (char*)env->GetStringUTFChars(obj_title, 0);
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nBegin__Ljava_lang_String_2_3ZI(env, clazz, obj_title, obj_pOpen, imGuiWindowFlags, title, pOpen);

	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);
	env->ReleaseStringUTFChars(obj_title, title);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_end(JNIEnv* env, jclass clazz) {


//@line:502

        ImGui::End();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:515

        return ImGui::BeginChild(strId);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChild__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2FF
(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, char* strId) {

//@line:519

        return ImGui::BeginChild(strId, ImVec2(width, height));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChild__Ljava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2FF(env, clazz, obj_strId, width, height, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2FFZ
(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, jboolean border, char* strId) {

//@line:523

        return ImGui::BeginChild(strId, ImVec2(width, height), border);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChild__Ljava_lang_String_2FFZ(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, jboolean border) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2FFZ(env, clazz, obj_strId, width, height, border, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2FFZI
(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, jboolean border, jint imGuiWindowFlags, char* strId) {

//@line:527

        return ImGui::BeginChild(strId, ImVec2(width, height), border, imGuiWindowFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChild__Ljava_lang_String_2FFZI(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, jboolean border, jint imGuiWindowFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginChild__Ljava_lang_String_2FFZI(env, clazz, obj_strId, width, height, border, imGuiWindowFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChild__I(JNIEnv* env, jclass clazz, jint imGuiID) {


//@line:531

        return ImGui::BeginChild(imGuiID);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChild__IFFZ(JNIEnv* env, jclass clazz, jint imGuiID, jfloat width, jfloat height, jboolean border) {


//@line:535

        return ImGui::BeginChild(imGuiID, ImVec2(width, height), border);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChild__IFFZI(JNIEnv* env, jclass clazz, jint imGuiID, jfloat width, jfloat height, jboolean border, jint imGuiWindowFlags) {


//@line:539

        return ImGui::BeginChild(imGuiID, ImVec2(width, height), border, imGuiWindowFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endChild(JNIEnv* env, jclass clazz) {


//@line:543

        ImGui::EndChild();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isWindowAppearing(JNIEnv* env, jclass clazz) {


//@line:550

        return ImGui::IsWindowAppearing();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isWindowCollapsed(JNIEnv* env, jclass clazz) {


//@line:554

        return ImGui::IsWindowCollapsed();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isWindowFocused__(JNIEnv* env, jclass clazz) {


//@line:561

        return ImGui::IsWindowFocused();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isWindowFocused__I(JNIEnv* env, jclass clazz, jint imGuiFocusedFlags) {


//@line:568

        return ImGui::IsWindowFocused(imGuiFocusedFlags);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isWindowHovered__(JNIEnv* env, jclass clazz) {


//@line:577

        return ImGui::IsWindowHovered();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isWindowHovered__I(JNIEnv* env, jclass clazz, jint imGuiHoveredFlags) {


//@line:586

        return ImGui::IsWindowHovered(imGuiHoveredFlags);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetWindowDrawList(JNIEnv* env, jclass clazz) {


//@line:598

        return (intptr_t)ImGui::GetWindowDrawList();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowDpiScale(JNIEnv* env, jclass clazz) {


//@line:605

        return ImGui::GetWindowDpiScale();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getWindowPos(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:621

        Jni::ImVec2Cpy(env, ImGui::GetWindowPos(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowPosX(JNIEnv* env, jclass clazz) {


//@line:628

        return ImGui::GetWindowPos().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowPosY(JNIEnv* env, jclass clazz) {


//@line:635

        return ImGui::GetWindowPos().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getWindowSize(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:651

        Jni::ImVec2Cpy(env, ImGui::GetWindowSize(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowSizeX(JNIEnv* env, jclass clazz) {


//@line:658

        return ImGui::GetWindowSize().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowSizeY(JNIEnv* env, jclass clazz) {


//@line:665

        return ImGui::GetWindowSize().y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowWidth(JNIEnv* env, jclass clazz) {


//@line:672

        return ImGui::GetWindowWidth();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowHeight(JNIEnv* env, jclass clazz) {


//@line:679

        return ImGui::GetWindowHeight();
     

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetWindowViewport(JNIEnv* env, jclass clazz) {


//@line:691

        return (intptr_t)ImGui::GetWindowViewport();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowPos__FF(JNIEnv* env, jclass clazz, jfloat x, jfloat y) {


//@line:700

        ImGui::SetNextWindowPos(ImVec2(x, y));
     

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowPos__FFI(JNIEnv* env, jclass clazz, jfloat x, jfloat y, jint imGuiCond) {


//@line:707

        ImGui::SetNextWindowPos(ImVec2(x, y), imGuiCond);
     

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowPos__FFIFF(JNIEnv* env, jclass clazz, jfloat x, jfloat y, jint imGuiCond, jfloat pivotX, jfloat pivotY) {


//@line:714

        ImGui::SetNextWindowPos(ImVec2(x, y), imGuiCond, ImVec2(pivotX, pivotY));
     

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowSize__FF(JNIEnv* env, jclass clazz, jfloat width, jfloat height) {


//@line:721

        ImGui::SetNextWindowSize(ImVec2(width, height));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowSize__FFI(JNIEnv* env, jclass clazz, jfloat width, jfloat height, jint imGuiCond) {


//@line:728

        ImGui::SetNextWindowSize(ImVec2(width, height), imGuiCond);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowSizeConstraints(JNIEnv* env, jclass clazz, jfloat minWidth, jfloat minHeight, jfloat maxWidth, jfloat maxHeight) {


//@line:735

        ImGui::SetNextWindowSizeConstraints(ImVec2(minWidth, minHeight), ImVec2(maxWidth, maxHeight));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowContentSize(JNIEnv* env, jclass clazz, jfloat width, jfloat height) {


//@line:743

        ImGui::SetNextWindowContentSize(ImVec2(width, height));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowCollapsed__Z(JNIEnv* env, jclass clazz, jboolean collapsed) {


//@line:750

        ImGui::SetNextWindowCollapsed(collapsed);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowCollapsed__ZI(JNIEnv* env, jclass clazz, jboolean collapsed, jint imGuiCond) {


//@line:757

        ImGui::SetNextWindowCollapsed(collapsed, imGuiCond);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowFocus(JNIEnv* env, jclass clazz) {


//@line:764

        ImGui::SetNextWindowFocus();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowBgAlpha(JNIEnv* env, jclass clazz, jfloat alpha) {


//@line:772

        ImGui::SetNextWindowBgAlpha(alpha);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowViewport(JNIEnv* env, jclass clazz, jint viewportId) {


//@line:779

        ImGui::SetNextWindowViewport(viewportId);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowPos__FF(JNIEnv* env, jclass clazz, jfloat x, jfloat y) {


//@line:787

        ImGui::SetWindowPos(ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowPos__FFI(JNIEnv* env, jclass clazz, jfloat x, jfloat y, jint imGuiCond) {


//@line:795

        ImGui::SetWindowPos(ImVec2(x, y), imGuiCond);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowSize__FF(JNIEnv* env, jclass clazz, jfloat width, jfloat height) {


//@line:803

        ImGui::SetWindowSize(ImVec2(width, height));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowSize__FFI(JNIEnv* env, jclass clazz, jfloat width, jfloat height, jint imGuiCond) {


//@line:811

        ImGui::SetWindowSize(ImVec2(width, height), imGuiCond);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowCollapsed__Z(JNIEnv* env, jclass clazz, jboolean collapsed) {


//@line:818

        ImGui::SetWindowCollapsed(collapsed);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowCollapsed__ZI(JNIEnv* env, jclass clazz, jboolean collapsed, jint imGuiCond) {


//@line:825

        ImGui::SetWindowCollapsed(collapsed, imGuiCond);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowFocus__(JNIEnv* env, jclass clazz) {


//@line:832

        ImGui::SetWindowFocus();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowFontScale(JNIEnv* env, jobject object, jfloat scale) {


//@line:840

        ImGui::SetWindowFontScale(scale);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowPos__Ljava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_name, jfloat x, jfloat y) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:847

        ImGui::SetWindowPos(name, ImVec2(x, y));
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowPos__Ljava_lang_String_2FFI(JNIEnv* env, jclass clazz, jstring obj_name, jfloat x, jfloat y, jint imGuiCond) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:854

        ImGui::SetWindowPos(name, ImVec2(x, y), imGuiCond);
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowSize__Ljava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_name, jfloat x, jfloat y) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:861

        ImGui::SetWindowSize(name, ImVec2(x, y));
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowSize__Ljava_lang_String_2FFI(JNIEnv* env, jclass clazz, jstring obj_name, jfloat x, jfloat y, jint imGuiCond) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:868

        ImGui::SetWindowSize(name, ImVec2(x, y), imGuiCond);
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowCollapsed__Ljava_lang_String_2Z(JNIEnv* env, jclass clazz, jstring obj_name, jboolean collapsed) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:875

        ImGui::SetWindowCollapsed(name, collapsed, 0);
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowCollapsed__Ljava_lang_String_2ZI(JNIEnv* env, jclass clazz, jstring obj_name, jboolean collapsed, jint imGuiCond) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:882

        ImGui::SetWindowCollapsed(name, collapsed, imGuiCond);
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setWindowFocus__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_name) {

//@line:889

        if (obj_name == NULL)
            ImGui::SetWindowFocus(NULL);
        else {
            char* name = (char*)env->GetStringUTFChars(obj_name, JNI_FALSE);
            ImGui::SetWindowFocus(name);
            env->ReleaseStringUTFChars(obj_name, name);
        }
    
}

JNIEXPORT void JNICALL Java_imgui_ImGui_getContentRegionAvail(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:915

        Jni::ImVec2Cpy(env, ImGui::GetContentRegionAvail(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getContentRegionAvailX(JNIEnv* env, jclass clazz) {


//@line:922

        return ImGui::GetContentRegionAvail().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getContentRegionAvailY(JNIEnv* env, jclass clazz) {


//@line:929

        return ImGui::GetContentRegionAvail().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getContentRegionMax(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:945

        Jni::ImVec2Cpy(env, ImGui::GetContentRegionMax(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getContentRegionMaxX(JNIEnv* env, jclass clazz) {


//@line:952

        return ImGui::GetContentRegionMax().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getContentRegionMaxY(JNIEnv* env, jclass clazz) {


//@line:959

        return ImGui::GetContentRegionMax().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getWindowContentRegionMin(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:975

        Jni::ImVec2Cpy(env, ImGui::GetWindowContentRegionMin(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowContentRegionMinX(JNIEnv* env, jclass clazz) {


//@line:982

        return ImGui::GetWindowContentRegionMin().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowContentRegionMinY(JNIEnv* env, jclass clazz) {


//@line:989

        return ImGui::GetWindowContentRegionMin().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getWindowContentRegionMax(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:999

        Jni::ImVec2Cpy(env, ImGui::GetWindowContentRegionMax(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowContentRegionMaxX(JNIEnv* env, jclass clazz) {


//@line:1003

        return ImGui::GetWindowContentRegionMax().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getWindowContentRegionMaxY(JNIEnv* env, jclass clazz) {


//@line:1007

        return ImGui::GetWindowContentRegionMax().y;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getScrollX(JNIEnv* env, jclass clazz) {


//@line:1016

        return ImGui::GetScrollX();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getScrollY(JNIEnv* env, jclass clazz) {


//@line:1023

        return ImGui::GetScrollY();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollX(JNIEnv* env, jclass clazz, jfloat scrollX) {


//@line:1030

        ImGui::SetScrollX(scrollX);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollY(JNIEnv* env, jclass clazz, jfloat scrollY) {


//@line:1037

        ImGui::SetScrollY(scrollY);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getScrollMaxX(JNIEnv* env, jclass clazz) {


//@line:1044

        return ImGui::GetScrollMaxX();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getScrollMaxY(JNIEnv* env, jclass clazz) {


//@line:1051

        return ImGui::GetScrollMaxY();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollHereX__(JNIEnv* env, jclass clazz) {


//@line:1059

        ImGui::SetScrollHereX();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollHereX__F(JNIEnv* env, jclass clazz, jfloat centerXRatio) {


//@line:1067

        ImGui::SetScrollHereX(centerXRatio);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollHereY__(JNIEnv* env, jclass clazz) {


//@line:1075

        ImGui::SetScrollHereY();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollHereY__F(JNIEnv* env, jclass clazz, jfloat centerYRatio) {


//@line:1083

        ImGui::SetScrollHereY(centerYRatio);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollFromPosX__F(JNIEnv* env, jclass clazz, jfloat localX) {


//@line:1090

        ImGui::SetScrollFromPosX(localX);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollFromPosX__FF(JNIEnv* env, jclass clazz, jfloat localX, jfloat centerXRatio) {


//@line:1097

        ImGui::SetScrollFromPosX(localX, centerXRatio);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollFromPosY__F(JNIEnv* env, jclass clazz, jfloat localY) {


//@line:1104

        ImGui::SetScrollFromPosY(localY);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setScrollFromPosY__FF(JNIEnv* env, jclass clazz, jfloat localY, jfloat centerYRatio) {


//@line:1111

        ImGui::SetScrollFromPosY(localY, centerYRatio);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nPushFont(JNIEnv* env, jclass clazz, jlong fontPtr) {


//@line:1121

        ImGui::PushFont((ImFont*)fontPtr);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popFont(JNIEnv* env, jclass clazz) {


//@line:1125

        ImGui::PopFont();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushStyleColor__IFFFF(JNIEnv* env, jclass clazz, jint imGuiCol, jfloat r, jfloat g, jfloat b, jfloat a) {


//@line:1132

        ImGui::PushStyleColor(imGuiCol, (ImU32)ImColor((float)r, (float)g, (float)b, (float)a));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushStyleColor__IIIII(JNIEnv* env, jclass clazz, jint imGuiCol, jint r, jint g, jint b, jint a) {


//@line:1139

        ImGui::PushStyleColor(imGuiCol, (ImU32)ImColor((int)r, (int)g, (int)b, (int)a));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushStyleColor__II(JNIEnv* env, jclass clazz, jint imGuiCol, jint col) {


//@line:1146

        ImGui::PushStyleColor(imGuiCol, col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popStyleColor__(JNIEnv* env, jclass clazz) {


//@line:1150

        ImGui::PopStyleColor();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popStyleColor__I(JNIEnv* env, jclass clazz, jint count) {


//@line:1154

        ImGui::PopStyleColor(count);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushStyleVar__IF(JNIEnv* env, jclass clazz, jint imGuiStyleVar, jfloat val) {


//@line:1161

        ImGui::PushStyleVar(imGuiStyleVar, val);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushStyleVar__IFF(JNIEnv* env, jclass clazz, jint imGuiStyleVar, jfloat valX, jfloat valY) {


//@line:1168

        ImGui::PushStyleVar(imGuiStyleVar, ImVec2(valX, valY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popStyleVar__(JNIEnv* env, jclass clazz) {


//@line:1172

        ImGui::PopStyleVar();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popStyleVar__I(JNIEnv* env, jclass clazz, jint count) {


//@line:1176

        ImGui::PopStyleVar(count);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushAllowKeyboardFocus(JNIEnv* env, jclass clazz, jboolean allowKeyboardFocus) {


//@line:1183

        ImGui::PushAllowKeyboardFocus(allowKeyboardFocus);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popAllowKeyboardFocus(JNIEnv* env, jclass clazz) {


//@line:1187

        ImGui::PopAllowKeyboardFocus();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushButtonRepeat(JNIEnv* env, jclass clazz, jboolean repeat) {


//@line:1195

        ImGui::PushButtonRepeat(repeat);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popButtonRepeat(JNIEnv* env, jclass clazz) {


//@line:1199

        ImGui::PopButtonRepeat();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushItemWidth(JNIEnv* env, jclass clazz, jfloat itemWidth) {


//@line:1209

        ImGui::PushItemWidth(itemWidth);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popItemWidth(JNIEnv* env, jclass clazz) {


//@line:1213

        ImGui::PopItemWidth();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextItemWidth(JNIEnv* env, jclass clazz, jfloat itemWidth) {


//@line:1221

        ImGui::SetNextItemWidth(itemWidth);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_calcItemWidth(JNIEnv* env, jclass clazz) {


//@line:1228

        return ImGui::CalcItemWidth();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushTextWrapPos__(JNIEnv* env, jclass clazz) {


//@line:1236

        ImGui::PushTextWrapPos();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushTextWrapPos__F(JNIEnv* env, jclass clazz, jfloat wrapLocalPosX) {


//@line:1244

        ImGui::PushTextWrapPos(wrapLocalPosX);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popTextWrapPos(JNIEnv* env, jclass clazz) {


//@line:1248

        ImGui::PopTextWrapPos();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetFont(JNIEnv* env, jclass clazz) {


//@line:1262

        return (intptr_t)ImGui::GetFont();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getFontSize(JNIEnv* env, jclass clazz) {


//@line:1269

        return ImGui::GetFontSize();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getFontTexUvWhitePixel(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:1285

        Jni::ImVec2Cpy(env, ImGui::GetFontTexUvWhitePixel(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getFontTexUvWhitePixelX(JNIEnv* env, jclass clazz) {


//@line:1292

        return ImGui::GetFontTexUvWhitePixel().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getFontTexUvWhitePixelY(JNIEnv* env, jclass clazz) {


//@line:1299

        return ImGui::GetFontTexUvWhitePixel().y;
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getColorU32__I(JNIEnv* env, jclass clazz, jint imGuiCol) {


//@line:1306

        return ImGui::GetColorU32((ImGuiCol)imGuiCol);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getColorU32__IF(JNIEnv* env, jclass clazz, jint imGuiCol, jfloat alphaMul) {


//@line:1313

        return ImGui::GetColorU32(imGuiCol, alphaMul);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getColorU32__FFFF(JNIEnv* env, jclass clazz, jfloat r, jfloat g, jfloat b, jfloat a) {


//@line:1320

        return ImGui::GetColorU32(ImVec4(r, g, b, a));
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getColorU32i(JNIEnv* env, jclass clazz, jint col) {


//@line:1329

        return ImGui::GetColorU32((ImU32)col);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getStyleColorVec4(JNIEnv* env, jclass clazz, jint imGuiStyleVar, jobject dstImVec4) {


//@line:1347

        Jni::ImVec4Cpy(env, ImGui::GetStyleColorVec4(imGuiStyleVar), dstImVec4);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_separator(JNIEnv* env, jclass clazz) {


//@line:1362

        ImGui::Separator();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_sameLine__(JNIEnv* env, jclass clazz) {


//@line:1369

        ImGui::SameLine();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_sameLine__F(JNIEnv* env, jclass clazz, jfloat offsetFromStartX) {


//@line:1376

        ImGui::SameLine(offsetFromStartX);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_sameLine__FF(JNIEnv* env, jclass clazz, jfloat offsetFromStartX, jfloat spacing) {


//@line:1383

        ImGui::SameLine(offsetFromStartX, spacing);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_newLine(JNIEnv* env, jclass clazz) {


//@line:1390

        ImGui::NewLine();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_spacing(JNIEnv* env, jclass clazz) {


//@line:1397

        ImGui::Spacing();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_dummy(JNIEnv* env, jclass clazz, jfloat width, jfloat height) {


//@line:1404

        ImGui::Dummy(ImVec2(width, height));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_indent__(JNIEnv* env, jclass clazz) {


//@line:1411

        ImGui::Indent();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_indent__F(JNIEnv* env, jclass clazz, jfloat indentW) {


//@line:1418

        ImGui::Indent(indentW);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_unindent__(JNIEnv* env, jclass clazz) {


//@line:1425

        ImGui::Unindent();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_unindent__F(JNIEnv* env, jclass clazz, jfloat indentW) {


//@line:1432

        ImGui::Unindent(indentW);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_beginGroup(JNIEnv* env, jclass clazz) {


//@line:1439

        ImGui::BeginGroup();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endGroup(JNIEnv* env, jclass clazz) {


//@line:1446

        ImGui::EndGroup();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getCursorPos(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:1467

        Jni::ImVec2Cpy(env, ImGui::GetCursorPos(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getCursorPosX(JNIEnv* env, jclass clazz) {


//@line:1474

        return ImGui::GetCursorPosX();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getCursorPosY(JNIEnv* env, jclass clazz) {


//@line:1481

        return ImGui::GetCursorPosY();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setCursorPos(JNIEnv* env, jclass clazz, jfloat x, jfloat y) {


//@line:1488

        ImGui::SetCursorPos(ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setCursorPosX(JNIEnv* env, jclass clazz, jfloat x) {


//@line:1495

        ImGui::SetCursorPosX(x);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setCursorPosY(JNIEnv* env, jclass clazz, jfloat y) {


//@line:1502

        ImGui::SetCursorPosY(y);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getCursorStartPos(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:1518

        Jni::ImVec2Cpy(env, ImGui::GetCursorStartPos(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getCursorStartPosX(JNIEnv* env, jclass clazz) {


//@line:1525

        return ImGui::GetCursorStartPos().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getCursorStartPosY(JNIEnv* env, jclass clazz) {


//@line:1532

        return ImGui::GetCursorStartPos().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getCursorScreenPos(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:1552

        Jni::ImVec2Cpy(env, ImGui::GetCursorScreenPos(), dstImVec2);
     

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getCursorScreenPosX(JNIEnv* env, jclass clazz) {


//@line:1561

        return ImGui::GetCursorScreenPos().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getCursorScreenPosY(JNIEnv* env, jclass clazz) {


//@line:1570

        return ImGui::GetCursorScreenPos().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setCursorScreenPos(JNIEnv* env, jclass clazz, jfloat x, jfloat y) {


//@line:1576

        ImGui::SetCursorScreenPos(ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_alignTextToFramePadding(JNIEnv* env, jclass clazz) {


//@line:1583

        ImGui::AlignTextToFramePadding();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getTextLineHeight(JNIEnv* env, jclass clazz) {


//@line:1590

        return ImGui::GetTextLineHeight();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getTextLineHeightWithSpacing(JNIEnv* env, jclass clazz) {


//@line:1597

        return ImGui::GetTextLineHeightWithSpacing();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getFrameHeight(JNIEnv* env, jclass clazz) {


//@line:1604

        return ImGui::GetFrameHeight();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getFrameHeightWithSpacing(JNIEnv* env, jclass clazz) {


//@line:1611

        return ImGui::GetFrameHeightWithSpacing();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushID__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);


//@line:1626

        ImGui::PushID(strId);
    
	env->ReleaseStringUTFChars(obj_strId, strId);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushID__Ljava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strIdBegin, jstring obj_strIdEnd) {
	char* strIdBegin = (char*)env->GetStringUTFChars(obj_strIdBegin, 0);
	char* strIdEnd = (char*)env->GetStringUTFChars(obj_strIdEnd, 0);


//@line:1633

        ImGui::PushID(strIdBegin, strIdEnd);
    
	env->ReleaseStringUTFChars(obj_strIdBegin, strIdBegin);
	env->ReleaseStringUTFChars(obj_strIdEnd, strIdEnd);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushID__J(JNIEnv* env, jclass clazz, jlong ptrId) {


//@line:1640

        ImGui::PushID((void*)ptrId);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushID__I(JNIEnv* env, jclass clazz, jint intId) {


//@line:1647

        ImGui::PushID(intId);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popID(JNIEnv* env, jclass clazz) {


//@line:1654

        ImGui::PopID();
    

}

static inline jint wrapped_Java_imgui_ImGui_getID__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:1661

        return ImGui::GetID(strId);
    
}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getID__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jint JNI_returnValue = wrapped_Java_imgui_ImGui_getID__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jint wrapped_Java_imgui_ImGui_getID__Ljava_lang_String_2Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strIdBegin, jstring obj_strIdEnd, char* strIdBegin, char* strIdEnd) {

//@line:1668

        return ImGui::GetID(strIdBegin, strIdEnd);
    
}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getID__Ljava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strIdBegin, jstring obj_strIdEnd) {
	char* strIdBegin = (char*)env->GetStringUTFChars(obj_strIdBegin, 0);
	char* strIdEnd = (char*)env->GetStringUTFChars(obj_strIdEnd, 0);

	jint JNI_returnValue = wrapped_Java_imgui_ImGui_getID__Ljava_lang_String_2Ljava_lang_String_2(env, clazz, obj_strIdBegin, obj_strIdEnd, strIdBegin, strIdEnd);

	env->ReleaseStringUTFChars(obj_strIdBegin, strIdBegin);
	env->ReleaseStringUTFChars(obj_strIdEnd, strIdEnd);

	return JNI_returnValue;
}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getID__J(JNIEnv* env, jclass clazz, jlong ptrId) {


//@line:1675

        return ImGui::GetID((void*)ptrId);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_textUnformatted(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1686

        ImGui::TextUnformatted(text);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_text(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1695

        ImGui::TextUnformatted(text);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_textColored__FFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jfloat r, jfloat g, jfloat b, jfloat a, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1702

        ImGui::TextColored(ImColor((float)r, (float)g, (float)b, (float)a), text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_textColored__IIIILjava_lang_String_2(JNIEnv* env, jclass clazz, jint r, jint g, jint b, jint a, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1709

        ImGui::TextColored(ImColor((int)r, (int)g, (int)b, (int)a), text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_textColored__ILjava_lang_String_2(JNIEnv* env, jclass clazz, jint col, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1716

        ImGui::TextColored(ImColor(col), text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_textDisabled(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1723

        ImGui::TextDisabled(text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_textWrapped(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1732

        ImGui::TextWrapped(text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_labelText(JNIEnv* env, jclass clazz, jstring obj_label, jstring obj_text) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1739

        ImGui::LabelText(label, text, NULL);
    
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_bulletText(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:1746

        ImGui::BulletText(text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

static inline jboolean wrapped_Java_imgui_ImGui_button__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:1757

        return ImGui::Button(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_button__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_button__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_button__Ljava_lang_String_2FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat width, jfloat height, char* label) {

//@line:1764

        return ImGui::Button(label, ImVec2(width, height));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_button__Ljava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloat width, jfloat height) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_button__Ljava_lang_String_2FF(env, clazz, obj_label, width, height, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_smallButton
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:1771

        return ImGui::SmallButton(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_smallButton(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_smallButton(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_invisibleButton__Ljava_lang_String_2FF
(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, char* strId) {

//@line:1778

        return ImGui::InvisibleButton(strId, ImVec2(width, height));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_invisibleButton__Ljava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_invisibleButton__Ljava_lang_String_2FF(env, clazz, obj_strId, width, height, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_invisibleButton__Ljava_lang_String_2FFI
(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, jint imGuiButtonFlags, char* strId) {

//@line:1785

        return ImGui::InvisibleButton(strId, ImVec2(width, height), imGuiButtonFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_invisibleButton__Ljava_lang_String_2FFI(JNIEnv* env, jclass clazz, jstring obj_strId, jfloat width, jfloat height, jint imGuiButtonFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_invisibleButton__Ljava_lang_String_2FFI(env, clazz, obj_strId, width, height, imGuiButtonFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_arrowButton
(JNIEnv* env, jclass clazz, jstring obj_strId, jint dir, char* strId) {

//@line:1792

        return ImGui::ArrowButton(strId, dir);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_arrowButton(JNIEnv* env, jclass clazz, jstring obj_strId, jint dir) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_arrowButton(env, clazz, obj_strId, dir, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_image__IFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY) {


//@line:1796

        ImGui::Image((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_image__IFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y) {


//@line:1800

        ImGui::Image((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_image__IFFFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y, jfloat uv1X, jfloat uv1Y) {


//@line:1804

        ImGui::Image((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y), ImVec2(uv1X, uv1Y));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_image__IFFFFFFFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y, jfloat uv1X, jfloat uv1Y, jfloat tintColorR, jfloat tintColorG, jfloat tintColorB, jfloat tintColorA) {


//@line:1808

        ImGui::Image((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y), ImVec2(uv1X, uv1Y), ImVec4(tintColorR, tintColorG, tintColorB, tintColorA));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_image__IFFFFFFFFFFFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y, jfloat uv1X, jfloat uv1Y, jfloat tintColorR, jfloat tintColorG, jfloat tintColorB, jfloat tintColorA, jfloat borderR, jfloat borderG, jfloat borderB, jfloat borderA) {


//@line:1812

        ImGui::Image((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y), ImVec2(uv1X, uv1Y), ImVec4(tintColorR, tintColorG, tintColorB, tintColorA), ImVec4(borderR, borderG, borderB, borderA));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_imageButton__IFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY) {


//@line:1819

        return ImGui::ImageButton((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_imageButton__IFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y) {


//@line:1826

        return ImGui::ImageButton((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_imageButton__IFFFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y, jfloat uv1X, jfloat uv1Y) {


//@line:1833

        return ImGui::ImageButton((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y), ImVec2(uv1X, uv1Y));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_imageButton__IFFFFFFI(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y, jfloat uv1X, jfloat uv1Y, jint framePadding) {


//@line:1840

        return ImGui::ImageButton((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y), ImVec2(uv1X, uv1Y), framePadding);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_imageButton__IFFFFFFIFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y, jfloat uv1X, jfloat uv1Y, jint framePadding, jfloat bgColorR, jfloat bgColorG, jfloat bgColorB, jfloat bgColorA) {


//@line:1847

        return ImGui::ImageButton((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y), ImVec2(uv1X, uv1Y), framePadding, ImVec4(bgColorR, bgColorG, bgColorB, bgColorA));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_imageButton__IFFFFFFIFFFFFFFF(JNIEnv* env, jclass clazz, jint textureID, jfloat sizeX, jfloat sizeY, jfloat uv0X, jfloat uv0Y, jfloat uv1X, jfloat uv1Y, jint framePadding, jfloat bgColorR, jfloat bgColorG, jfloat bgColorB, jfloat bgColorA, jfloat tintR, jfloat tintG, jfloat tintB, jfloat tintA) {


//@line:1854

        return ImGui::ImageButton((ImTextureID)(intptr_t)textureID, ImVec2(sizeX, sizeY), ImVec2(uv0X, uv0Y), ImVec2(uv1X, uv1Y), framePadding, ImVec4(bgColorR, bgColorG, bgColorB, bgColorA), ImVec4(tintR, tintG, tintB, tintA));
    

}

static inline jboolean wrapped_Java_imgui_ImGui_checkbox
(JNIEnv* env, jclass clazz, jstring obj_label, jboolean active, char* label) {

//@line:1858

        bool flag = (bool)active;
        return ImGui::Checkbox(label, &flag);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_checkbox(JNIEnv* env, jclass clazz, jstring obj_label, jboolean active) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_checkbox(env, clazz, obj_label, active, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nCheckbox
(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_data, char* label, bool* data) {

//@line:1867

        return ImGui::Checkbox(label, &data[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nCheckbox(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_data) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	bool* data = (bool*)env->GetPrimitiveArrayCritical(obj_data, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nCheckbox(env, clazz, obj_label, obj_data, label, data);

	env->ReleasePrimitiveArrayCritical(obj_data, data, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nCheckboxFlags
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_data, jint flagsValue, char* label, int* data) {

//@line:1875

        return ImGui::CheckboxFlags(label, (unsigned int*)&data[0], flagsValue);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nCheckboxFlags(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_data, jint flagsValue) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* data = (int*)env->GetPrimitiveArrayCritical(obj_data, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nCheckboxFlags(env, clazz, obj_label, obj_data, flagsValue, label, data);

	env->ReleasePrimitiveArrayCritical(obj_data, data, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_radioButton
(JNIEnv* env, jclass clazz, jstring obj_label, jboolean active, char* label) {

//@line:1882

        return ImGui::RadioButton(label, active);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_radioButton(JNIEnv* env, jclass clazz, jstring obj_label, jboolean active) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_radioButton(env, clazz, obj_label, active, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nRadioButton
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_data, jint vButton, char* label, int* data) {

//@line:1893

        return ImGui::RadioButton(label, &data[0], vButton);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nRadioButton(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_data, jint vButton) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* data = (int*)env->GetPrimitiveArrayCritical(obj_data, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nRadioButton(env, clazz, obj_label, obj_data, vButton, label, data);

	env->ReleasePrimitiveArrayCritical(obj_data, data, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_progressBar__F(JNIEnv* env, jclass clazz, jfloat fraction) {


//@line:1897

        ImGui::ProgressBar(fraction);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_progressBar__FFF(JNIEnv* env, jclass clazz, jfloat fraction, jfloat sizeArgX, jfloat sizeArgY) {


//@line:1901

        ImGui::ProgressBar(fraction, ImVec2(sizeArgX, sizeArgY));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_progressBar__FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jfloat fraction, jfloat sizeArgX, jfloat sizeArgY, jstring obj_overlay) {
	char* overlay = (char*)env->GetStringUTFChars(obj_overlay, 0);


//@line:1905

        ImGui::ProgressBar(fraction, ImVec2(sizeArgX, sizeArgY), overlay);
    
	env->ReleaseStringUTFChars(obj_overlay, overlay);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_bullet(JNIEnv* env, jclass clazz) {


//@line:1912

        ImGui::Bullet();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginCombo__Ljava_lang_String_2Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jstring obj_previewValue, char* label, char* previewValue) {

//@line:1920

        return ImGui::BeginCombo(label, previewValue);
     
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginCombo__Ljava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jstring obj_previewValue) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* previewValue = (char*)env->GetStringUTFChars(obj_previewValue, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginCombo__Ljava_lang_String_2Ljava_lang_String_2(env, clazz, obj_label, obj_previewValue, label, previewValue);

	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_previewValue, previewValue);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginCombo__Ljava_lang_String_2Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jstring obj_previewValue, jint imGuiComboFlags, char* label, char* previewValue) {

//@line:1924

        return ImGui::BeginCombo(label, previewValue, imGuiComboFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginCombo__Ljava_lang_String_2Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jstring obj_previewValue, jint imGuiComboFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* previewValue = (char*)env->GetStringUTFChars(obj_previewValue, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginCombo__Ljava_lang_String_2Ljava_lang_String_2I(env, clazz, obj_label, obj_previewValue, imGuiComboFlags, label, previewValue);

	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_previewValue, previewValue);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endCombo(JNIEnv* env, jclass clazz) {


//@line:1931

        ImGui::EndCombo();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_nCombo__Ljava_lang_String_2_3I_3Ljava_lang_String_2II
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_currentItem, jobjectArray items, jint itemsCount, jint popupMaxHeightInItems, char* label, int* currentItem) {

//@line:1943

        const char* listboxItems[itemsCount];

        for (int i = 0; i < itemsCount; i++) {
            jstring string = (jstring)env->GetObjectArrayElement(items, i);
            const char* rawString = env->GetStringUTFChars(string, JNI_FALSE);
            listboxItems[i] = rawString;
        }

        bool flag = ImGui::Combo(label, &currentItem[0], listboxItems, itemsCount, popupMaxHeightInItems);

        for (int i = 0; i< itemsCount; i++) {
            jstring string = (jstring)env->GetObjectArrayElement(items, i);
            env->ReleaseStringUTFChars(string, listboxItems[i]);
        }

        return flag;
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nCombo__Ljava_lang_String_2_3I_3Ljava_lang_String_2II(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_currentItem, jobjectArray items, jint itemsCount, jint popupMaxHeightInItems) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* currentItem = (int*)env->GetPrimitiveArrayCritical(obj_currentItem, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nCombo__Ljava_lang_String_2_3I_3Ljava_lang_String_2II(env, clazz, obj_label, obj_currentItem, items, itemsCount, popupMaxHeightInItems, label, currentItem);

	env->ReleasePrimitiveArrayCritical(obj_currentItem, currentItem, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nCombo__Ljava_lang_String_2_3ILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_currentItem, jstring obj_itemsSeparatedByZeros, jint popupMaxHeightInItems, char* label, char* itemsSeparatedByZeros, int* currentItem) {

//@line:1973

        return ImGui::Combo(label, &currentItem[0], itemsSeparatedByZeros, popupMaxHeightInItems);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nCombo__Ljava_lang_String_2_3ILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_currentItem, jstring obj_itemsSeparatedByZeros, jint popupMaxHeightInItems) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* itemsSeparatedByZeros = (char*)env->GetStringUTFChars(obj_itemsSeparatedByZeros, 0);
	int* currentItem = (int*)env->GetPrimitiveArrayCritical(obj_currentItem, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nCombo__Ljava_lang_String_2_3ILjava_lang_String_2I(env, clazz, obj_label, obj_currentItem, obj_itemsSeparatedByZeros, popupMaxHeightInItems, label, itemsSeparatedByZeros, currentItem);

	env->ReleasePrimitiveArrayCritical(obj_currentItem, currentItem, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_itemsSeparatedByZeros, itemsSeparatedByZeros);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, char* label, float* v) {

//@line:1990

        return ImGui::DragFloat(label, &v[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, char* label, float* v) {

//@line:1994

        return ImGui::DragFloat(label, &v[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2001

        return ImGui::DragFloat(label, &v[0], vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2008

        return ImGui::DragFloat(label, &v[0], vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2015

        return ImGui::DragFloat(label, &v[0], vSpeed, vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, char* label, float* v) {

//@line:2019

        return ImGui::DragFloat2(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, char* label, float* v) {

//@line:2023

        return ImGui::DragFloat2(label, v, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, char* label, float* v) {

//@line:2027

        return ImGui::DragFloat2(label, v, vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_v, vSpeed, vMin, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2031

        return ImGui::DragFloat2(label, v, vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2035

        return ImGui::DragFloat2(label, v, vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2039

        return ImGui::DragFloat2(label, v, vSpeed, vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat2__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, char* label, float* v) {

//@line:2043

        return ImGui::DragFloat3(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, char* label, float* v) {

//@line:2047

        return ImGui::DragFloat3(label, v, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, char* label, float* v) {

//@line:2051

        return ImGui::DragFloat3(label, v, vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_v, vSpeed, vMin, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2055

        return ImGui::DragFloat3(label, v, vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2059

        return ImGui::DragFloat3(label, v, vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2063

        return ImGui::DragFloat3(label, v, vSpeed, vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat3__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, char* label, float* v) {

//@line:2067

        return ImGui::DragFloat4(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, char* label, float* v) {

//@line:2071

        return ImGui::DragFloat4(label, v, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, char* label, float* v) {

//@line:2075

        return ImGui::DragFloat4(label, v, vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_v, vSpeed, vMin, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2079

        return ImGui::DragFloat4(label, v, vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2083

        return ImGui::DragFloat4(label, v, vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2087

        return ImGui::DragFloat4(label, v, vSpeed, vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloat4__Ljava_lang_String_2_3FFFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, char* label, float* vCurrentMin, float* vCurrentMax) {

//@line:2091

        return ImGui::DragFloatRange2(label, &vCurrentMin[0], &vCurrentMax[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* vCurrentMin = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	float* vCurrentMax = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3F(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, char* label, float* vCurrentMin, float* vCurrentMax) {

//@line:2095

        return ImGui::DragFloatRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* vCurrentMin = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	float* vCurrentMax = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FF(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, char* label, float* vCurrentMin, float* vCurrentMax) {

//@line:2099

        return ImGui::DragFloatRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* vCurrentMin = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	float* vCurrentMax = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFF(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, float* vCurrentMin, float* vCurrentMax) {

//@line:2103

        return ImGui::DragFloatRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* vCurrentMin = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	float* vCurrentMax = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFF(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, vMax, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* vCurrentMin, float* vCurrentMax) {

//@line:2107

        return ImGui::DragFloatRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* vCurrentMin = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	float* vCurrentMax = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, vMax, obj_format, label, format, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jstring obj_formatMax, char* label, char* format, char* formatMax, float* vCurrentMin, float* vCurrentMax) {

//@line:2111

        return ImGui::DragFloatRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin, vMax, format, formatMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jstring obj_formatMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	char* formatMax = (char*)env->GetStringUTFChars(obj_formatMax, 0);
	float* vCurrentMin = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	float* vCurrentMax = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2Ljava_lang_String_2(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, vMax, obj_format, obj_formatMax, label, format, formatMax, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);
	env->ReleaseStringUTFChars(obj_formatMax, formatMax);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jstring obj_formatMax, jint imGuiSliderFlags, char* label, char* format, char* formatMax, float* vCurrentMin, float* vCurrentMax) {

//@line:2115

        return ImGui::DragFloatRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin, vMax, format, formatMax, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vCurrentMin, jfloatArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jstring obj_formatMax, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	char* formatMax = (char*)env->GetStringUTFChars(obj_formatMax, 0);
	float* vCurrentMin = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	float* vCurrentMax = (float*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragFloatRange2__Ljava_lang_String_2_3F_3FFFFLjava_lang_String_2Ljava_lang_String_2I(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, vMax, obj_format, obj_formatMax, imGuiSliderFlags, label, format, formatMax, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);
	env->ReleaseStringUTFChars(obj_formatMax, formatMax);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, char* label, int* v) {

//@line:2119

        return ImGui::DragInt(label, &v[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3I(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, char* label, int* v) {

//@line:2123

        return ImGui::DragInt(label, &v[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, char* label, int* v) {

//@line:2127

        return ImGui::DragInt(label, &v[0], vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFF(env, clazz, obj_label, obj_v, vSpeed, vMin, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, int* v) {

//@line:2134

        return ImGui::DragInt(label, &v[0], vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2141

        return ImGui::DragInt(label, &v[0], vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt__Ljava_lang_String_2_3IFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, char* label, int* v) {

//@line:2145

        return ImGui::DragInt2(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3I(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, char* label, int* v) {

//@line:2149

        return ImGui::DragInt2(label, v, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, char* label, int* v) {

//@line:2153

        return ImGui::DragInt2(label, v, vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFF(env, clazz, obj_label, obj_v, vSpeed, vMin, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, int* v) {

//@line:2157

        return ImGui::DragInt2(label, v, vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2161

        return ImGui::DragInt2(label, v, vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt2__Ljava_lang_String_2_3IFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, char* label, int* v) {

//@line:2165

        return ImGui::DragInt3(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3I(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, char* label, int* v) {

//@line:2169

        return ImGui::DragInt3(label, v, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, char* label, int* v) {

//@line:2173

        return ImGui::DragInt3(label, v, vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFF(env, clazz, obj_label, obj_v, vSpeed, vMin, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, int* v) {

//@line:2177

        return ImGui::DragInt3(label, v, vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2181

        return ImGui::DragInt3(label, v, vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt3__Ljava_lang_String_2_3IFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, char* label, int* v) {

//@line:2185

        return ImGui::DragInt4(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3I(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, char* label, int* v) {

//@line:2189

        return ImGui::DragInt4(label, v, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IF(env, clazz, obj_label, obj_v, vSpeed, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, char* label, int* v) {

//@line:2193

        return ImGui::DragInt4(label, v, vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFF(env, clazz, obj_label, obj_v, vSpeed, vMin, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, int* v) {

//@line:2197

        return ImGui::DragInt4(label, v, vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFFF(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2201

        return ImGui::DragInt4(label, v, vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragInt4__Ljava_lang_String_2_3IFFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vSpeed, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, char* label, int* vCurrentMin, int* vCurrentMax) {

//@line:2205

        return ImGui::DragIntRange2(label, &vCurrentMin[0], &vCurrentMax[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* vCurrentMin = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	int* vCurrentMax = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3I(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, char* label, int* vCurrentMin, int* vCurrentMax) {

//@line:2209

        return ImGui::DragIntRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* vCurrentMin = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	int* vCurrentMax = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IF(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, char* label, int* vCurrentMin, int* vCurrentMax) {

//@line:2213

        return ImGui::DragIntRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* vCurrentMin = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	int* vCurrentMax = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFF(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, char* label, int* vCurrentMin, int* vCurrentMax) {

//@line:2217

        return ImGui::DragIntRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFF(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* vCurrentMin = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	int* vCurrentMax = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFF(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, vMax, label, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, int* vCurrentMin, int* vCurrentMax) {

//@line:2221

        return ImGui::DragIntRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* vCurrentMin = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	int* vCurrentMax = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFFLjava_lang_String_2(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, vMax, obj_format, label, format, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFFLjava_lang_String_2Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jstring obj_formatMax, char* label, char* format, char* formatMax, int* vCurrentMin, int* vCurrentMax) {

//@line:2225

        return ImGui::DragIntRange2(label, &vCurrentMin[0], &vCurrentMax[0], vSpeed, vMin, vMax, format, formatMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFFLjava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_vCurrentMin, jintArray obj_vCurrentMax, jfloat vSpeed, jfloat vMin, jfloat vMax, jstring obj_format, jstring obj_formatMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	char* formatMax = (char*)env->GetStringUTFChars(obj_formatMax, 0);
	int* vCurrentMin = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMin, 0);
	int* vCurrentMax = (int*)env->GetPrimitiveArrayCritical(obj_vCurrentMax, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_dragIntRange2__Ljava_lang_String_2_3I_3IFFFLjava_lang_String_2Ljava_lang_String_2(env, clazz, obj_label, obj_vCurrentMin, obj_vCurrentMax, vSpeed, vMin, vMax, obj_format, obj_formatMax, label, format, formatMax, vCurrentMin, vCurrentMax);

	env->ReleasePrimitiveArrayCritical(obj_vCurrentMin, vCurrentMin, 0);
	env->ReleasePrimitiveArrayCritical(obj_vCurrentMax, vCurrentMax, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);
	env->ReleaseStringUTFChars(obj_formatMax, formatMax);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed, char* label, int* pData) {

//@line:2233

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IF(env, clazz, obj_label, dataType, obj_pData, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFI
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed, jint pMin, char* label, int* pData) {

//@line:2241

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFI(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed, jint pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFI(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFII
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed, jint pMin, jint pMax, char* label, int* pData) {

//@line:2249

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFII(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed, jint pMin, jint pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFII(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFIILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed, jint pMin, jint pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, int* pData) {

//@line:2261

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFIILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jfloat vSpeed, jint pMin, jint pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3IFIILjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed, char* label, float* pData) {

//@line:2269

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FF(env, clazz, obj_label, dataType, obj_pData, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed, jfloat pMin, char* label, float* pData) {

//@line:2277

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed, jfloat pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFF(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed, jfloat pMin, jfloat pMax, char* label, float* pData) {

//@line:2285

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed, jfloat pMin, jfloat pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFFF(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed, jfloat pMin, jfloat pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* pData) {

//@line:2297

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat vSpeed, jfloat pMin, jfloat pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3FFFFLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed, char* label, double* pData) {

//@line:2305

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DF(env, clazz, obj_label, dataType, obj_pData, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed, jdouble pMin, char* label, double* pData) {

//@line:2313

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed, jdouble pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFD(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFDD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed, jdouble pMin, jdouble pMax, char* label, double* pData) {

//@line:2321

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFDD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed, jdouble pMin, jdouble pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFDD(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFDDLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed, jdouble pMin, jdouble pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, double* pData) {

//@line:2333

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFDDLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jfloat vSpeed, jdouble pMin, jdouble pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3DFDDLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed, char* label, long long* pData) {

//@line:2341

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JF(env, clazz, obj_label, dataType, obj_pData, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed, jlong pMin, char* label, long long* pData) {

//@line:2349

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed, jlong pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJ(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed, jlong pMin, jlong pMax, char* label, long long* pData) {

//@line:2357

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed, jlong pMin, jlong pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJJ(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJJLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed, jlong pMin, jlong pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, long long* pData) {

//@line:2369

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJJLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jfloat vSpeed, jlong pMin, jlong pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3JFJJLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed, char* label, short* pData) {

//@line:2377

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SF(env, clazz, obj_label, dataType, obj_pData, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed, jshort pMin, char* label, short* pData) {

//@line:2385

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed, jshort pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFS(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFSS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed, jshort pMin, jshort pMax, char* label, short* pData) {

//@line:2393

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFSS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed, jshort pMin, jshort pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFSS(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFSSLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed, jshort pMin, jshort pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, short* pData) {

//@line:2405

        return ImGui::DragScalar(label, dataType, &pData[0], vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFSSLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jfloat vSpeed, jshort pMin, jshort pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalar__Ljava_lang_String_2I_3SFSSLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed, char* label, int* pData) {

//@line:2413

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIF(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFI
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed, jint pMin, char* label, int* pData) {

//@line:2421

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFI(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed, jint pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFI(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFII
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed, jint pMin, jint pMax, char* label, int* pData) {

//@line:2429

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFII(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed, jint pMin, jint pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFII(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFIILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed, jint pMin, jint pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, int* pData) {

//@line:2441

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFIILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jfloat vSpeed, jint pMin, jint pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3IIFIILjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed, char* label, float* pData) {

//@line:2449

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIF(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed, jfloat pMin, char* label, float* pData) {

//@line:2457

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed, jfloat pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFF(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed, jfloat pMin, jfloat pMax, char* label, float* pData) {

//@line:2465

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed, jfloat pMin, jfloat pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFFF(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed, jfloat pMin, jfloat pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* pData) {

//@line:2477

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat vSpeed, jfloat pMin, jfloat pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3FIFFFLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed, char* label, double* pData) {

//@line:2485

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIF(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed, jdouble pMin, char* label, double* pData) {

//@line:2493

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed, jdouble pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFD(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFDD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed, jdouble pMin, jdouble pMax, char* label, double* pData) {

//@line:2501

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFDD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed, jdouble pMin, jdouble pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFDD(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFDDLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed, jdouble pMin, jdouble pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, double* pData) {

//@line:2513

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFDDLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jfloat vSpeed, jdouble pMin, jdouble pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3DIFDDLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed, char* label, long long* pData) {

//@line:2521

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIF(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed, jlong pMin, char* label, long long* pData) {

//@line:2529

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed, jlong pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJ(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed, jlong pMin, jlong pMax, char* label, long long* pData) {

//@line:2537

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed, jlong pMin, jlong pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJJ(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJJLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed, jlong pMin, jlong pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, long long* pData) {

//@line:2549

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJJLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jfloat vSpeed, jlong pMin, jlong pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3JIFJJLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed, char* label, short* pData) {

//@line:2557

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIF(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed, jshort pMin, char* label, short* pData) {

//@line:2565

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed, jshort pMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFS(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFSS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed, jshort pMin, jshort pMax, char* label, short* pData) {

//@line:2573

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFSS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed, jshort pMin, jshort pMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFSS(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFSSLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed, jshort pMin, jshort pMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, short* pData) {

//@line:2585

        return ImGui::DragScalarN(label, dataType, &pData[0], components, vSpeed, &pMin, &pMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFSSLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jfloat vSpeed, jshort pMin, jshort pMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nDragScalarN__Ljava_lang_String_2I_3SIFSSLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, vSpeed, pMin, pMax, obj_format, imGuiSliderFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2599

        return ImGui::SliderFloat(label, &v[0],vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2603

        return ImGui::SliderFloat(label, &v[0], vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2607

        return ImGui::SliderFloat(label, &v[0], vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat__Ljava_lang_String_2_3FFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2611

        return ImGui::SliderFloat2(label, v, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2615

        return ImGui::SliderFloat2(label, v, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2619

        return ImGui::SliderFloat2(label, v, vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat2__Ljava_lang_String_2_3FFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2623

        return ImGui::SliderFloat3(label, v, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2627

        return ImGui::SliderFloat3(label, v, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2631

        return ImGui::SliderFloat3(label, v, vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat3__Ljava_lang_String_2_3FFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2635

        return ImGui::SliderFloat4(label, v, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2639

        return ImGui::SliderFloat4(label, v, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFFLjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2643

        return ImGui::SliderFloat4(label, v, vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderFloat4__Ljava_lang_String_2_3FFFLjava_lang_String_2I(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad, char* label, float* vRad) {

//@line:2647

        return ImGui::SliderAngle(label, &vRad[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* vRad = (float*)env->GetPrimitiveArrayCritical(obj_vRad, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_vRad, label, vRad);

	env->ReleasePrimitiveArrayCritical(obj_vRad, vRad, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad, jfloat vDegreesMin, char* label, float* vRad) {

//@line:2651

        return ImGui::SliderAngle(label, &vRad[0], vDegreesMin);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad, jfloat vDegreesMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* vRad = (float*)env->GetPrimitiveArrayCritical(obj_vRad, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FF(env, clazz, obj_label, obj_vRad, vDegreesMin, label, vRad);

	env->ReleasePrimitiveArrayCritical(obj_vRad, vRad, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad, jfloat vDegreesMin, jfloat vDegreesMax, char* label, float* vRad) {

//@line:2655

        return ImGui::SliderAngle(label, &vRad[0], vDegreesMin, vDegreesMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad, jfloat vDegreesMin, jfloat vDegreesMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* vRad = (float*)env->GetPrimitiveArrayCritical(obj_vRad, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FFF(env, clazz, obj_label, obj_vRad, vDegreesMin, vDegreesMax, label, vRad);

	env->ReleasePrimitiveArrayCritical(obj_vRad, vRad, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad, jfloat vDegreesMin, jfloat vDegreesMax, jstring obj_format, char* label, char* format, float* vRad) {

//@line:2659

        return ImGui::SliderAngle(label, &vRad[0], vDegreesMin, vDegreesMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_vRad, jfloat vDegreesMin, jfloat vDegreesMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* vRad = (float*)env->GetPrimitiveArrayCritical(obj_vRad, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderAngle__Ljava_lang_String_2_3FFFLjava_lang_String_2(env, clazz, obj_label, obj_vRad, vDegreesMin, vDegreesMax, obj_format, label, format, vRad);

	env->ReleasePrimitiveArrayCritical(obj_vRad, vRad, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt__Ljava_lang_String_2_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2663

        return ImGui::SliderInt(label, &v[0], vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt__Ljava_lang_String_2_3III(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt__Ljava_lang_String_2_3III(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt__Ljava_lang_String_2_3IIILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2667

        return ImGui::SliderInt(label, &v[0], vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt__Ljava_lang_String_2_3IIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt__Ljava_lang_String_2_3IIILjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt2__Ljava_lang_String_2_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2671

        return ImGui::SliderInt2(label, v, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt2__Ljava_lang_String_2_3III(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt2__Ljava_lang_String_2_3III(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt2__Ljava_lang_String_2_3IIILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2675

        return ImGui::SliderInt2(label, v, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt2__Ljava_lang_String_2_3IIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt2__Ljava_lang_String_2_3IIILjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt3__Ljava_lang_String_2_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2679

        return ImGui::SliderInt3(label, v, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt3__Ljava_lang_String_2_3III(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt3__Ljava_lang_String_2_3III(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt3__Ljava_lang_String_2_3IIILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2683

        return ImGui::SliderInt3(label, v, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt3__Ljava_lang_String_2_3IIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt3__Ljava_lang_String_2_3IIILjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt4__Ljava_lang_String_2_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2687

        return ImGui::SliderInt4(label, v, vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt4__Ljava_lang_String_2_3III(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt4__Ljava_lang_String_2_3III(env, clazz, obj_label, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_sliderInt4__Ljava_lang_String_2_3IIILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2691

        return ImGui::SliderInt4(label, v, vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_sliderInt4__Ljava_lang_String_2_3IIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint vMin, jint vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_sliderInt4__Ljava_lang_String_2_3IIILjava_lang_String_2(env, clazz, obj_label, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2699

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3III(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3III(env, clazz, obj_label, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, int* v) {

//@line:2711

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2I(env, clazz, obj_label, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2719

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3FFF(env, clazz, obj_label, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2731

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3JJJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax, char* label, long long* v) {

//@line:2739

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3JJJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* v = (long long*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3JJJ(env, clazz, obj_label, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, long long* v) {

//@line:2751

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* v = (long long*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3DDD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax, char* label, double* v) {

//@line:2759

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3DDD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* v = (double*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3DDD(env, clazz, obj_label, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, double* v) {

//@line:2771

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* v = (double*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3SSS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax, char* label, short* v) {

//@line:2779

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3SSS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* v = (short*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3SSS(env, clazz, obj_label, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, short* v) {

//@line:2791

        return ImGui::SliderScalar(label, dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* v = (short*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2799

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3III(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3III(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3IIILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, int* v) {

//@line:2811

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3IIILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3IIILjava_lang_String_2I(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2819

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3FFF(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2831

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3FFFLjava_lang_String_2I(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3JJJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jlongArray obj_v, jlong vMin, jlong vMax, char* label, long long* v) {

//@line:2839

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3JJJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jlongArray obj_v, jlong vMin, jlong vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* v = (long long*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3JJJ(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3JJJLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jlongArray obj_v, jlong vMin, jlong vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, long long* v) {

//@line:2851

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3JJJLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jlongArray obj_v, jlong vMin, jlong vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* v = (long long*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3JJJLjava_lang_String_2I(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3DDD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jdoubleArray obj_v, jdouble vMin, jdouble vMax, char* label, double* v) {

//@line:2859

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3DDD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jdoubleArray obj_v, jdouble vMin, jdouble vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* v = (double*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3DDD(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3DDDLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jdoubleArray obj_v, jdouble vMin, jdouble vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, double* v) {

//@line:2871

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3DDDLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jdoubleArray obj_v, jdouble vMin, jdouble vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* v = (double*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3DDDLjava_lang_String_2I(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3SSS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jshortArray obj_v, jshort vMin, jshort vMax, char* label, short* v) {

//@line:2879

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3SSS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jshortArray obj_v, jshort vMin, jshort vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* v = (short*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3SSS(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3SSSLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jshortArray obj_v, jshort vMin, jshort vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, short* v) {

//@line:2891

        return ImGui::SliderScalarN(label, dataType, &v[0], components, &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3SSSLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jint components, jshortArray obj_v, jshort vMin, jshort vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* v = (short*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSliderScalarN__Ljava_lang_String_2II_3SSSLjava_lang_String_2I(env, clazz, obj_label, dataType, components, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2895

        return ImGui::VSliderFloat(label, ImVec2(sizeX, sizeY), &v[0], vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFF(env, clazz, obj_label, sizeX, sizeY, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, char* label, char* format, float* v) {

//@line:2899

        return ImGui::VSliderFloat(label, ImVec2(sizeX, sizeY), &v[0], vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFFLjava_lang_String_2(env, clazz, obj_label, sizeX, sizeY, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2903

        return ImGui::VSliderFloat(label, ImVec2(sizeX, sizeY), &v[0], vMin, vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_vSliderFloat__Ljava_lang_String_2FF_3FFFLjava_lang_String_2I(env, clazz, obj_label, sizeX, sizeY, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_vSliderInt__Ljava_lang_String_2FF_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2907

        return ImGui::VSliderInt(label, ImVec2(sizeX, sizeY), &v[0], vMin, vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_vSliderInt__Ljava_lang_String_2FF_3III(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_vSliderInt__Ljava_lang_String_2FF_3III(env, clazz, obj_label, sizeX, sizeY, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_vSliderInt__Ljava_lang_String_2FF_3IIILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, char* label, char* format, int* v) {

//@line:2911

        return ImGui::VSliderInt(label, ImVec2(sizeX, sizeY), &v[0], vMin, vMax, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_vSliderInt__Ljava_lang_String_2FF_3IIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jintArray obj_v, jint vMin, jint vMax, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_vSliderInt__Ljava_lang_String_2FF_3IIILjava_lang_String_2(env, clazz, obj_label, sizeX, sizeY, obj_v, vMin, vMax, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jintArray obj_v, jint vMin, jint vMax, char* label, int* v) {

//@line:2919

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3III(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jintArray obj_v, jint vMin, jint vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3III(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3IIILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, int* v) {

//@line:2931

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3IIILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jintArray obj_v, jint vMin, jint vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3IIILjava_lang_String_2I(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax, char* label, float* v) {

//@line:2939

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3FFF(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, float* v) {

//@line:2951

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jfloatArray obj_v, jfloat vMin, jfloat vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3FFFLjava_lang_String_2I(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3JJJ
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax, char* label, long long* v) {

//@line:2959

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3JJJ(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* v = (long long*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3JJJ(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3JJJLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, long long* v) {

//@line:2971

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3JJJLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jlongArray obj_v, jlong vMin, jlong vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* v = (long long*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3JJJLjava_lang_String_2I(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3DDD
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax, char* label, double* v) {

//@line:2979

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3DDD(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* v = (double*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3DDD(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3DDDLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, double* v) {

//@line:2991

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3DDDLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jdoubleArray obj_v, jdouble vMin, jdouble vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* v = (double*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3DDDLjava_lang_String_2I(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3SSS
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax, char* label, short* v) {

//@line:2999

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3SSS(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* v = (short*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3SSS(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3SSSLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax, jstring obj_format, jint imGuiSliderFlags, char* label, char* format, short* v) {

//@line:3011

        return ImGui::VSliderScalar(label, ImVec2(sizeX, sizeY), dataType, &v[0], &vMin, &vMax, format, (ImGuiSliderFlags)imGuiSliderFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3SSSLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, jint dataType, jshortArray obj_v, jshort vMin, jshort vMax, jstring obj_format, jint imGuiSliderFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* v = (short*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nVSliderScalar__Ljava_lang_String_2FFI_3SSSLjava_lang_String_2I(env, clazz, obj_label, sizeX, sizeY, dataType, obj_v, vMin, vMax, obj_format, imGuiSliderFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}


//@line:3019

        jmethodID jImStringResizeInternalMID;
        jmethodID jInputTextCallbackMID;

        jfieldID inputDataSizeID;
        jfieldID inputDataIsDirtyID;
        jfieldID inputDataIsResizedID;


        struct InputTextCallbackUserData {
            JNIEnv* env;
            jobject* imString;
            int maxSize;
            jbyteArray jResizedBuf;
            char* resizedBuf;
            jobject* textInputData;
            char* allowedChars;
            jobject* handler;
        };

        static int TextEditCallbackStub(ImGuiInputTextCallbackData* data) {
            InputTextCallbackUserData* userData = (InputTextCallbackUserData*)data->UserData;

            if (data->EventFlag == ImGuiInputTextFlags_CallbackCharFilter) {
                int allowedCharLength = strlen(userData->allowedChars);
                if(allowedCharLength > 0) {
                    bool found = false;
                    for(int i = 0; i < allowedCharLength; i++) {
                        if(userData->allowedChars[i] == data->EventChar) {
                            found = true;
                            break;
                        }
                    }
                    return found ? 0 : 1;
                }
            } else if (data->EventFlag == ImGuiInputTextFlags_CallbackResize) {
                int newSize = data->BufTextLen;
                if (newSize >= userData->maxSize) {
                    JNIEnv* env = userData->env;

                    jbyteArray newBufArr = (jbyteArray)env->CallObjectMethod(*userData->imString, jImStringResizeInternalMID, newSize);
                    char* newBuf = (char*)env->GetPrimitiveArrayCritical(newBufArr, 0);

                    data->Buf = newBuf;

                    userData->jResizedBuf = newBufArr;
                    userData->resizedBuf = newBuf;
                }
            }

            if (userData->handler != NULL) {
                JNIEnv* env = userData->env;
                env->CallObjectMethod(*userData->handler, jInputTextCallbackMID, data);
            }

            return 0;
        }
    JNIEXPORT void JNICALL Java_imgui_ImGui_nInitInputTextData(JNIEnv* env, jclass clazz) {


//@line:3078

        jclass jInputDataClass = env->FindClass("imgui/type/ImString$InputData");
        inputDataSizeID = env->GetFieldID(jInputDataClass, "size", "I");
        inputDataIsDirtyID = env->GetFieldID(jInputDataClass, "isDirty", "Z");
        inputDataIsResizedID = env->GetFieldID(jInputDataClass, "isResized", "Z");

        jclass jImString = env->FindClass("imgui/type/ImString");
        jImStringResizeInternalMID = env->GetMethodID(jImString, "resizeInternal", "(I)[B");

        jclass jCallback = env->FindClass("imgui/callback/ImGuiInputTextCallback");
        jInputTextCallbackMID = env->GetMethodID(jCallback, "accept", "(J)V");
    

}

static inline jboolean wrapped_Java_imgui_ImGui_nInputText
(JNIEnv* env, jclass clazz, jboolean multiline, jboolean hint, jstring obj_label, jstring obj_hintLabel, jobject imString, jbyteArray obj_buf, jint maxSize, jfloat width, jfloat height, jint flags, jobject textInputData, jstring obj_allowedChars, jobject callback, char* label, char* hintLabel, char* allowedChars, char* buf) {

//@line:3170

        InputTextCallbackUserData userData;
        userData.imString = &imString;
        userData.maxSize = maxSize;
        userData.jResizedBuf = NULL;
        userData.resizedBuf = NULL;
        userData.textInputData = &textInputData;
        userData.env = env;
        userData.allowedChars = allowedChars;
        userData.handler = callback != NULL ? &callback : NULL;

        bool valueChanged;

        if (multiline) {
            valueChanged = ImGui::InputTextMultiline(label, buf, maxSize, ImVec2(width, height), flags, &TextEditCallbackStub, &userData);
        } else if (hint) {
            valueChanged = ImGui::InputTextWithHint(label, hintLabel, buf, maxSize, flags, &TextEditCallbackStub, &userData);
        } else {
            valueChanged = ImGui::InputText(label, buf, maxSize, flags, &TextEditCallbackStub, &userData);
        }

        if (valueChanged) {
            int size;

            if (userData.jResizedBuf != NULL) {
                size = strlen(userData.resizedBuf);
                env->ReleasePrimitiveArrayCritical(userData.jResizedBuf, userData.resizedBuf, 0);
            } else {
                size = strlen(buf);
            }

            env->SetIntField(textInputData, inputDataSizeID, size);
            env->SetBooleanField(textInputData, inputDataIsDirtyID, true);
        }

        return valueChanged;
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputText(JNIEnv* env, jclass clazz, jboolean multiline, jboolean hint, jstring obj_label, jstring obj_hintLabel, jobject imString, jbyteArray obj_buf, jint maxSize, jfloat width, jfloat height, jint flags, jobject textInputData, jstring obj_allowedChars, jobject callback) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* hintLabel = (char*)env->GetStringUTFChars(obj_hintLabel, 0);
	char* allowedChars = (char*)env->GetStringUTFChars(obj_allowedChars, 0);
	char* buf = (char*)env->GetPrimitiveArrayCritical(obj_buf, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputText(env, clazz, multiline, hint, obj_label, obj_hintLabel, imString, obj_buf, maxSize, width, height, flags, textInputData, obj_allowedChars, callback, label, hintLabel, allowedChars, buf);

	env->ReleasePrimitiveArrayCritical(obj_buf, buf, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_hintLabel, hintLabel);
	env->ReleaseStringUTFChars(obj_allowedChars, allowedChars);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputFloat
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat step, jfloat stepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, float* v) {

//@line:3228

        return ImGui::InputFloat(label, &v[0], step, stepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputFloat(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jfloat step, jfloat stepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputFloat(env, clazz, obj_label, obj_v, step, stepFast, obj_format, imGuiInputTextFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, char* label, float* v) {

//@line:3232

        return ImGui::InputFloat2(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3FLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, char* label, char* format, float* v) {

//@line:3236

        return ImGui::InputFloat2(label, v, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3FLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3FLjava_lang_String_2(env, clazz, obj_label, obj_v, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3FLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, float* v) {

//@line:3240

        return ImGui::InputFloat2(label, v, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3FLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat2__Ljava_lang_String_2_3FLjava_lang_String_2I(env, clazz, obj_label, obj_v, obj_format, imGuiInputTextFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, char* label, float* v) {

//@line:3244

        return ImGui::InputFloat3(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3FLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, char* label, char* format, float* v) {

//@line:3248

        return ImGui::InputFloat3(label, v, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3FLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3FLjava_lang_String_2(env, clazz, obj_label, obj_v, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3FLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, float* v) {

//@line:3252

        return ImGui::InputFloat3(label, v, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3FLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat3__Ljava_lang_String_2_3FLjava_lang_String_2I(env, clazz, obj_label, obj_v, obj_format, imGuiInputTextFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, char* label, float* v) {

//@line:3256

        return ImGui::InputFloat4(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3FLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, char* label, char* format, float* v) {

//@line:3260

        return ImGui::InputFloat4(label, v, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3FLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3FLjava_lang_String_2(env, clazz, obj_label, obj_v, obj_format, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3FLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, float* v) {

//@line:3264

        return ImGui::InputFloat4(label, v, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3FLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_v, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* v = (float*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputFloat4__Ljava_lang_String_2_3FLjava_lang_String_2I(env, clazz, obj_label, obj_v, obj_format, imGuiInputTextFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputInt
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint step, jint stepFast, jint imGuiInputTextFlags, char* label, int* v) {

//@line:3284

        return ImGui::InputInt(label, &v[0], step, stepFast, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputInt(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint step, jint stepFast, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputInt(env, clazz, obj_label, obj_v, step, stepFast, imGuiInputTextFlags, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputInt2__Ljava_lang_String_2_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, char* label, int* v) {

//@line:3288

        return ImGui::InputInt2(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputInt2__Ljava_lang_String_2_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputInt2__Ljava_lang_String_2_3I(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputInt2__Ljava_lang_String_2_3II
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint imGuiInputTextFlags, char* label, int* v) {

//@line:3292

        return ImGui::InputInt2(label, v, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputInt2__Ljava_lang_String_2_3II(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputInt2__Ljava_lang_String_2_3II(env, clazz, obj_label, obj_v, imGuiInputTextFlags, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputInt3__Ljava_lang_String_2_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, char* label, int* v) {

//@line:3296

        return ImGui::InputInt3(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputInt3__Ljava_lang_String_2_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputInt3__Ljava_lang_String_2_3I(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputInt3__Ljava_lang_String_2_3II
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint imGuiInputTextFlags, char* label, int* v) {

//@line:3300

        return ImGui::InputInt3(label, v, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputInt3__Ljava_lang_String_2_3II(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputInt3__Ljava_lang_String_2_3II(env, clazz, obj_label, obj_v, imGuiInputTextFlags, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputInt4__Ljava_lang_String_2_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, char* label, int* v) {

//@line:3304

        return ImGui::InputInt4(label, v);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputInt4__Ljava_lang_String_2_3I(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputInt4__Ljava_lang_String_2_3I(env, clazz, obj_label, obj_v, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_inputInt4__Ljava_lang_String_2_3II
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint imGuiInputTextFlags, char* label, int* v) {

//@line:3308

        return ImGui::InputInt4(label, v, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_inputInt4__Ljava_lang_String_2_3II(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_v, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* v = (int*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_inputInt4__Ljava_lang_String_2_3II(env, clazz, obj_label, obj_v, imGuiInputTextFlags, label, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputDouble
(JNIEnv* env, jclass clazz, jstring obj_label, jdoubleArray obj_v, jdouble step, jdouble stepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, double* v) {

//@line:3332

        return ImGui::InputDouble(label, &v[0], step, stepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputDouble(JNIEnv* env, jclass clazz, jstring obj_label, jdoubleArray obj_v, jdouble step, jdouble stepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* v = (double*)env->GetPrimitiveArrayCritical(obj_v, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputDouble(env, clazz, obj_label, obj_v, step, stepFast, obj_format, imGuiInputTextFlags, label, format, v);

	env->ReleasePrimitiveArrayCritical(obj_v, v, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, char* label, int* pData) {

//@line:3340

        return ImGui::InputScalar(label, dataType, &pData[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3I(env, clazz, obj_label, dataType, obj_pData, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3II
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep, char* label, int* pData) {

//@line:3348

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3II(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3II(env, clazz, obj_label, dataType, obj_pData, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep, jint pStepFast, char* label, int* pData) {

//@line:3356

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3III(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep, jint pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3III(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep, jint pStepFast, jstring obj_format, char* label, char* format, int* pData) {

//@line:3364

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep, jint pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep, jint pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, int* pData) {

//@line:3372

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint pStep, jint pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3IIILjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, char* label, float* pData) {

//@line:3380

        return ImGui::InputScalar(label, dataType, &pData[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3F(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3F(env, clazz, obj_label, dataType, obj_pData, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep, char* label, float* pData) {

//@line:3388

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FF(env, clazz, obj_label, dataType, obj_pData, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep, jfloat pStepFast, char* label, float* pData) {

//@line:3396

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep, jfloat pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFF(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep, jfloat pStepFast, jstring obj_format, char* label, char* format, float* pData) {

//@line:3404

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep, jfloat pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep, jfloat pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, float* pData) {

//@line:3412

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jfloat pStep, jfloat pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3FFFLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3J
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, char* label, long long* pData) {

//@line:3420

        return ImGui::InputScalar(label, dataType, &pData[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3J(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3J(env, clazz, obj_label, dataType, obj_pData, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep, char* label, long long* pData) {

//@line:3428

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJ(env, clazz, obj_label, dataType, obj_pData, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep, jlong pStepFast, char* label, long long* pData) {

//@line:3436

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep, jlong pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJ(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep, jlong pStepFast, jstring obj_format, char* label, char* format, long long* pData) {

//@line:3444

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep, jlong pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep, jlong pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, long long* pData) {

//@line:3452

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jlong pStep, jlong pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3JJJLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3D
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, char* label, double* pData) {

//@line:3460

        return ImGui::InputScalar(label, dataType, &pData[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3D(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3D(env, clazz, obj_label, dataType, obj_pData, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep, char* label, double* pData) {

//@line:3468

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DD(env, clazz, obj_label, dataType, obj_pData, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep, jdouble pStepFast, char* label, double* pData) {

//@line:3476

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep, jdouble pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDD(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep, jdouble pStepFast, jstring obj_format, char* label, char* format, double* pData) {

//@line:3484

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep, jdouble pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep, jdouble pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, double* pData) {

//@line:3492

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jdouble pStep, jdouble pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3DDDLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3S
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, char* label, short* pData) {

//@line:3500

        return ImGui::InputScalar(label, dataType, &pData[0]);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3S(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3S(env, clazz, obj_label, dataType, obj_pData, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep, char* label, short* pData) {

//@line:3508

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SS(env, clazz, obj_label, dataType, obj_pData, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep, jshort pStepFast, char* label, short* pData) {

//@line:3516

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep, jshort pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSS(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep, jshort pStepFast, jstring obj_format, char* label, char* format, short* pData) {

//@line:3524

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep, jshort pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep, jshort pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, short* pData) {

//@line:3532

        return ImGui::InputScalar(label, dataType, &pData[0], &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jshort pStep, jshort pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalar__Ljava_lang_String_2I_3SSSLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3II
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, char* label, int* pData) {

//@line:3540

        return ImGui::InputScalarN(label, dataType, &pData[0], components);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3II(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3II(env, clazz, obj_label, dataType, obj_pData, components, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3III
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep, char* label, int* pData) {

//@line:3548

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3III(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3III(env, clazz, obj_label, dataType, obj_pData, components, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIII
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep, jint pStepFast, char* label, int* pData) {

//@line:3556

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIII(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep, jint pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIII(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIIILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep, jint pStepFast, jstring obj_format, char* label, char* format, int* pData) {

//@line:3564

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep, jint pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIIILjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIIILjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep, jint pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, int* pData) {

//@line:3572

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIIILjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jintArray obj_pData, jint components, jint pStep, jint pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	int* pData = (int*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3IIIILjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FI
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, char* label, float* pData) {

//@line:3580

        return ImGui::InputScalarN(label, dataType, &pData[0], components);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FI(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FI(env, clazz, obj_label, dataType, obj_pData, components, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep, char* label, float* pData) {

//@line:3588

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIF(env, clazz, obj_label, dataType, obj_pData, components, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFF
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep, jfloat pStepFast, char* label, float* pData) {

//@line:3596

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFF(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep, jfloat pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFF(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFFLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep, jfloat pStepFast, jstring obj_format, char* label, char* format, float* pData) {

//@line:3604

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFFLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep, jfloat pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFFLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFFLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep, jfloat pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, float* pData) {

//@line:3612

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFFLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jfloatArray obj_pData, jint components, jfloat pStep, jfloat pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	float* pData = (float*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3FIFFLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JI
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, char* label, long long* pData) {

//@line:3620

        return ImGui::InputScalarN(label, dataType, &pData[0], components);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JI(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JI(env, clazz, obj_label, dataType, obj_pData, components, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep, char* label, long long* pData) {

//@line:3628

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJ(env, clazz, obj_label, dataType, obj_pData, components, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJ
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep, jlong pStepFast, char* label, long long* pData) {

//@line:3636

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJ(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep, jlong pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJ(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep, jlong pStepFast, jstring obj_format, char* label, char* format, long long* pData) {

//@line:3644

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep, jlong pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep, jlong pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, long long* pData) {

//@line:3652

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jlongArray obj_pData, jint components, jlong pStep, jlong pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	long long* pData = (long long*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3JIJJLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DI
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, char* label, double* pData) {

//@line:3660

        return ImGui::InputScalarN(label, dataType, &pData[0], components);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DI(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DI(env, clazz, obj_label, dataType, obj_pData, components, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DID
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep, char* label, double* pData) {

//@line:3668

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DID(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DID(env, clazz, obj_label, dataType, obj_pData, components, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDD
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep, jdouble pStepFast, char* label, double* pData) {

//@line:3676

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDD(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep, jdouble pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDD(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDDLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep, jdouble pStepFast, jstring obj_format, char* label, char* format, double* pData) {

//@line:3684

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDDLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep, jdouble pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDDLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDDLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep, jdouble pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, double* pData) {

//@line:3692

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDDLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jdoubleArray obj_pData, jint components, jdouble pStep, jdouble pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	double* pData = (double*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3DIDDLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SI
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, char* label, short* pData) {

//@line:3700

        return ImGui::InputScalarN(label, dataType, &pData[0], components);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SI(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SI(env, clazz, obj_label, dataType, obj_pData, components, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SIS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep, char* label, short* pData) {

//@line:3708

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SIS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SIS(env, clazz, obj_label, dataType, obj_pData, components, pStep, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISS
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep, jshort pStepFast, char* label, short* pData) {

//@line:3716

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISS(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep, jshort pStepFast) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISS(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, label, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISSLjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep, jshort pStepFast, jstring obj_format, char* label, char* format, short* pData) {

//@line:3724

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISSLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep, jshort pStepFast, jstring obj_format) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISSLjava_lang_String_2(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISSLjava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep, jshort pStepFast, jstring obj_format, jint imGuiInputTextFlags, char* label, char* format, short* pData) {

//@line:3732

        return ImGui::InputScalarN(label, dataType, &pData[0], components, &pStep, &pStepFast, format, imGuiInputTextFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISSLjava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint dataType, jshortArray obj_pData, jint components, jshort pStep, jshort pStepFast, jstring obj_format, jint imGuiInputTextFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* format = (char*)env->GetStringUTFChars(obj_format, 0);
	short* pData = (short*)env->GetPrimitiveArrayCritical(obj_pData, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nInputScalarN__Ljava_lang_String_2I_3SISSLjava_lang_String_2I(env, clazz, obj_label, dataType, obj_pData, components, pStep, pStepFast, obj_format, imGuiInputTextFlags, label, format, pData);

	env->ReleasePrimitiveArrayCritical(obj_pData, pData, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_format, format);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorEdit3__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, char* label, float* col) {

//@line:3740

        return ImGui::ColorEdit3(label, col);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorEdit3__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorEdit3__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_col, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorEdit3__Ljava_lang_String_2_3FI
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags, char* label, float* col) {

//@line:3744

        return ImGui::ColorEdit3(label, col, imGuiColorEditFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorEdit3__Ljava_lang_String_2_3FI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorEdit3__Ljava_lang_String_2_3FI(env, clazz, obj_label, obj_col, imGuiColorEditFlags, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorEdit4__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, char* label, float* col) {

//@line:3748

        return ImGui::ColorEdit4(label, col);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorEdit4__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorEdit4__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_col, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorEdit4__Ljava_lang_String_2_3FI
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags, char* label, float* col) {

//@line:3752

        return ImGui::ColorEdit4(label, col, imGuiColorEditFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorEdit4__Ljava_lang_String_2_3FI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorEdit4__Ljava_lang_String_2_3FI(env, clazz, obj_label, obj_col, imGuiColorEditFlags, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorPicker3__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, char* label, float* col) {

//@line:3756

        return ImGui::ColorPicker3(label, col);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorPicker3__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorPicker3__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_col, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorPicker3__Ljava_lang_String_2_3FI
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags, char* label, float* col) {

//@line:3760

        return ImGui::ColorPicker3(label, col, imGuiColorEditFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorPicker3__Ljava_lang_String_2_3FI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorPicker3__Ljava_lang_String_2_3FI(env, clazz, obj_label, obj_col, imGuiColorEditFlags, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, char* label, float* col) {

//@line:3764

        return ImGui::ColorPicker4(label, col);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3F(env, clazz, obj_label, obj_col, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3FI
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags, char* label, float* col) {

//@line:3768

        return ImGui::ColorPicker4(label, col, imGuiColorEditFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3FI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3FI(env, clazz, obj_label, obj_col, imGuiColorEditFlags, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3FIF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags, jfloat refCol, char* label, float* col) {

//@line:3772

        return ImGui::ColorPicker4(label, col, imGuiColorEditFlags, &refCol);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3FIF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_col, jint imGuiColorEditFlags, jfloat refCol) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorPicker4__Ljava_lang_String_2_3FIF(env, clazz, obj_label, obj_col, imGuiColorEditFlags, refCol, label, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3F
(JNIEnv* env, jclass clazz, jstring obj_descId, jfloatArray obj_col, char* descId, float* col) {

//@line:3779

        return ImGui::ColorButton(descId, ImVec4(col[0], col[1], col[2], col[3]));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3F(JNIEnv* env, jclass clazz, jstring obj_descId, jfloatArray obj_col) {
	char* descId = (char*)env->GetStringUTFChars(obj_descId, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3F(env, clazz, obj_descId, obj_col, descId, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_descId, descId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3FI
(JNIEnv* env, jclass clazz, jstring obj_descId, jfloatArray obj_col, jint imGuiColorEditFlags, char* descId, float* col) {

//@line:3786

        return ImGui::ColorButton(descId, ImVec4(col[0], col[1], col[2], col[3]), imGuiColorEditFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3FI(JNIEnv* env, jclass clazz, jstring obj_descId, jfloatArray obj_col, jint imGuiColorEditFlags) {
	char* descId = (char*)env->GetStringUTFChars(obj_descId, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3FI(env, clazz, obj_descId, obj_col, imGuiColorEditFlags, descId, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_descId, descId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3FIFF
(JNIEnv* env, jclass clazz, jstring obj_descId, jfloatArray obj_col, jint imGuiColorEditFlags, jfloat width, jfloat height, char* descId, float* col) {

//@line:3793

        return ImGui::ColorButton(descId, ImVec4(col[0], col[1], col[2], col[3]), imGuiColorEditFlags, ImVec2(width, height));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3FIFF(JNIEnv* env, jclass clazz, jstring obj_descId, jfloatArray obj_col, jint imGuiColorEditFlags, jfloat width, jfloat height) {
	char* descId = (char*)env->GetStringUTFChars(obj_descId, 0);
	float* col = (float*)env->GetPrimitiveArrayCritical(obj_col, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_colorButton__Ljava_lang_String_2_3FIFF(env, clazz, obj_descId, obj_col, imGuiColorEditFlags, width, height, descId, col);

	env->ReleasePrimitiveArrayCritical(obj_col, col, 0);
	env->ReleaseStringUTFChars(obj_descId, descId);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_setColorEditOptions(JNIEnv* env, jclass clazz, jint imGuiColorEditFlags) {


//@line:3801

        ImGui::SetColorEditOptions(imGuiColorEditFlags);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_treeNode__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:3808

        return ImGui::TreeNode(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_treeNode__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_treeNode__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_treeNode__Ljava_lang_String_2Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, jstring obj_label, char* strId, char* label) {

//@line:3816

        return ImGui::TreeNode(strId, label, NULL);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_treeNode__Ljava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId, jstring obj_label) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_treeNode__Ljava_lang_String_2Ljava_lang_String_2(env, clazz, obj_strId, obj_label, strId, label);

	env->ReleaseStringUTFChars(obj_strId, strId);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_treeNode__JLjava_lang_String_2
(JNIEnv* env, jclass clazz, jlong ptrId, jstring obj_label, char* label) {

//@line:3820

        return ImGui::TreeNode((void*)ptrId, label, NULL);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_treeNode__JLjava_lang_String_2(JNIEnv* env, jclass clazz, jlong ptrId, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_treeNode__JLjava_lang_String_2(env, clazz, ptrId, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:3824

        return ImGui::TreeNodeEx(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTreeNodeFlags, char* label) {

//@line:3828

        return ImGui::TreeNodeEx(label, imGuiTreeNodeFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTreeNodeFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2I(env, clazz, obj_label, imGuiTreeNodeFlags, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2ILjava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiTreeNodeFlags, jstring obj_label, char* strId, char* label) {

//@line:3832

        return ImGui::TreeNodeEx(strId, imGuiTreeNodeFlags, label, NULL);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2ILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiTreeNodeFlags, jstring obj_label) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_treeNodeEx__Ljava_lang_String_2ILjava_lang_String_2(env, clazz, obj_strId, imGuiTreeNodeFlags, obj_label, strId, label);

	env->ReleaseStringUTFChars(obj_strId, strId);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_treeNodeEx__JILjava_lang_String_2
(JNIEnv* env, jclass clazz, jlong ptrId, jint imGuiTreeNodeFlags, jstring obj_label, char* label) {

//@line:3836

        return ImGui::TreeNodeEx((void*)ptrId, imGuiTreeNodeFlags, label, NULL);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_treeNodeEx__JILjava_lang_String_2(JNIEnv* env, jclass clazz, jlong ptrId, jint imGuiTreeNodeFlags, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_treeNodeEx__JILjava_lang_String_2(env, clazz, ptrId, imGuiTreeNodeFlags, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_treePush__(JNIEnv* env, jclass clazz) {


//@line:3843

        ImGui::TreePush();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_treePush__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);


//@line:3847

        ImGui::TreePush(strId);
    
	env->ReleaseStringUTFChars(obj_strId, strId);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_treePush__J(JNIEnv* env, jclass clazz, jlong ptrId) {


//@line:3851

        ImGui::TreePush((void*)ptrId);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_treePop(JNIEnv* env, jclass clazz) {


//@line:3858

        ImGui::TreePop();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getTreeNodeToLabelSpacing(JNIEnv* env, jclass clazz) {


//@line:3865

        return ImGui::GetTreeNodeToLabelSpacing();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_collapsingHeader__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:3872

        return ImGui::CollapsingHeader(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_collapsingHeader__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_collapsingHeader__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_collapsingHeader__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTreeNodeFlags, char* label) {

//@line:3879

        return ImGui::CollapsingHeader(label, imGuiTreeNodeFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_collapsingHeader__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTreeNodeFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_collapsingHeader__Ljava_lang_String_2I(env, clazz, obj_label, imGuiTreeNodeFlags, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nCollapsingHeader
(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_pVisible, jint imGuiTreeNodeFlags, char* label, bool* pVisible) {

//@line:3899

        return ImGui::CollapsingHeader(label, &pVisible[0], imGuiTreeNodeFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nCollapsingHeader(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_pVisible, jint imGuiTreeNodeFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	bool* pVisible = (bool*)env->GetPrimitiveArrayCritical(obj_pVisible, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nCollapsingHeader(env, clazz, obj_label, obj_pVisible, imGuiTreeNodeFlags, label, pVisible);

	env->ReleasePrimitiveArrayCritical(obj_pVisible, pVisible, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextItemOpen__Z(JNIEnv* env, jclass clazz, jboolean isOpen) {


//@line:3906

        ImGui::SetNextItemOpen(isOpen);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextItemOpen__ZI(JNIEnv* env, jclass clazz, jboolean isOpen, jint cond) {


//@line:3913

        ImGui::SetNextItemOpen(isOpen, cond);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:3921

        return ImGui::Selectable(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_selectable__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2Z
(JNIEnv* env, jclass clazz, jstring obj_label, jboolean selected, char* label) {

//@line:3925

        return ImGui::Selectable(label, selected);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_selectable__Ljava_lang_String_2Z(JNIEnv* env, jclass clazz, jstring obj_label, jboolean selected) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2Z(env, clazz, obj_label, selected, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2ZI
(JNIEnv* env, jclass clazz, jstring obj_label, jboolean selected, jint imGuiSelectableFlags, char* label) {

//@line:3929

        return ImGui::Selectable(label, selected, imGuiSelectableFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_selectable__Ljava_lang_String_2ZI(JNIEnv* env, jclass clazz, jstring obj_label, jboolean selected, jint imGuiSelectableFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2ZI(env, clazz, obj_label, selected, imGuiSelectableFlags, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2ZIFF
(JNIEnv* env, jclass clazz, jstring obj_label, jboolean selected, jint imGuiSelectableFlags, jfloat sizeX, jfloat sizeY, char* label) {

//@line:3933

        return ImGui::Selectable(label, selected, imGuiSelectableFlags, ImVec2(sizeX, sizeY));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_selectable__Ljava_lang_String_2ZIFF(JNIEnv* env, jclass clazz, jstring obj_label, jboolean selected, jint imGuiSelectableFlags, jfloat sizeX, jfloat sizeY) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_selectable__Ljava_lang_String_2ZIFF(env, clazz, obj_label, selected, imGuiSelectableFlags, sizeX, sizeY, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nSelectable
(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_selected, jint imGuiSelectableFlags, jfloat sizeX, jfloat sizeY, char* label, bool* selected) {

//@line:3949

        return ImGui::Selectable(label,  &selected[0], imGuiSelectableFlags, ImVec2(sizeX, sizeY));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSelectable(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_selected, jint imGuiSelectableFlags, jfloat sizeX, jfloat sizeY) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	bool* selected = (bool*)env->GetPrimitiveArrayCritical(obj_selected, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSelectable(env, clazz, obj_label, obj_selected, imGuiSelectableFlags, sizeX, sizeY, label, selected);

	env->ReleasePrimitiveArrayCritical(obj_selected, selected, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginListBox__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:3963

        return ImGui::BeginListBox(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginListBox__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginListBox__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginListBox__Ljava_lang_String_2FF
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY, char* label) {

//@line:3970

        return ImGui::BeginListBox(label, ImVec2(sizeX, sizeY));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginListBox__Ljava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloat sizeX, jfloat sizeY) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginListBox__Ljava_lang_String_2FF(env, clazz, obj_label, sizeX, sizeY, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endListBox(JNIEnv* env, jclass clazz) {


//@line:3977

        ImGui::EndListBox();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_nListBox
(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_currentItem, jobjectArray items, jint itemsCount, jint heightInItems, char* label, int* currentItem) {

//@line:3989

        const char* listboxItems[itemsCount];

        for (int i = 0; i < itemsCount; i++) {
            jstring string = (jstring)env->GetObjectArrayElement(items, i);
            const char* rawString = env->GetStringUTFChars(string, JNI_FALSE);
            listboxItems[i] = rawString;
        }

        bool flag = ImGui::ListBox(label, &currentItem[0], listboxItems, itemsCount, heightInItems);

        for (int i = 0; i< itemsCount; i++) {
            jstring string = (jstring)env->GetObjectArrayElement(items, i);
            env->ReleaseStringUTFChars(string, listboxItems[i]);
        }

        return flag;
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nListBox(JNIEnv* env, jclass clazz, jstring obj_label, jintArray obj_currentItem, jobjectArray items, jint itemsCount, jint heightInItems) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	int* currentItem = (int*)env->GetPrimitiveArrayCritical(obj_currentItem, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nListBox(env, clazz, obj_label, obj_currentItem, items, itemsCount, heightInItems, label, currentItem);

	env->ReleasePrimitiveArrayCritical(obj_currentItem, currentItem, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotLines__Ljava_lang_String_2_3FI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4011

        ImGui::PlotLines(label, &values[0], valuesCount);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotLines__Ljava_lang_String_2_3FII(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4015

        ImGui::PlotLines(label, &values[0], valuesCount, valuesOffset);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotLines__Ljava_lang_String_2_3FIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4019

        ImGui::PlotLines(label, &values[0], valuesCount, valuesOffset, overlayText);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotLines__Ljava_lang_String_2_3FIILjava_lang_String_2F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4023

        ImGui::PlotLines(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotLines__Ljava_lang_String_2_3FIILjava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin, jfloat scaleMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4027

        ImGui::PlotLines(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin, scaleMax);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotLines__Ljava_lang_String_2_3FIILjava_lang_String_2FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin, jfloat scaleMax, jfloat graphWidth, jfloat graphHeight) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4031

        ImGui::PlotLines(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin, scaleMax, ImVec2(graphWidth, graphHeight));
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotLines__Ljava_lang_String_2_3FIILjava_lang_String_2FFFFI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin, jfloat scaleMax, jfloat graphWidth, jfloat graphHeight, jint stride) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4035

        ImGui::PlotLines(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin, scaleMax, ImVec2(graphWidth, graphHeight), stride);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotHistogram__Ljava_lang_String_2_3FI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4039

        ImGui::PlotHistogram(label, &values[0], valuesCount);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotHistogram__Ljava_lang_String_2_3FII(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4043

        ImGui::PlotHistogram(label, &values[0], valuesCount, valuesOffset);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotHistogram__Ljava_lang_String_2_3FIILjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4047

        ImGui::PlotHistogram(label, &values[0], valuesCount, valuesOffset, overlayText);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotHistogram__Ljava_lang_String_2_3FIILjava_lang_String_2F(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4051

        ImGui::PlotHistogram(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotHistogram__Ljava_lang_String_2_3FIILjava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin, jfloat scaleMax) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4055

        ImGui::PlotHistogram(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin, scaleMax);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotHistogram__Ljava_lang_String_2_3FIILjava_lang_String_2FFFF(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin, jfloat scaleMax, jfloat graphWidth, jfloat graphHeight) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4059

        ImGui::PlotHistogram(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin, scaleMax, ImVec2(graphWidth, graphHeight));
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_plotHistogram__Ljava_lang_String_2_3FIILjava_lang_String_2FFFFI(JNIEnv* env, jclass clazz, jstring obj_label, jfloatArray obj_values, jint valuesCount, jint valuesOffset, jstring obj_overlayText, jfloat scaleMin, jfloat scaleMax, jfloat graphWidth, jfloat graphHeight, jint stride) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	char* overlayText = (char*)env->GetStringUTFChars(obj_overlayText, 0);
	float* values = (float*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:4063

        ImGui::PlotHistogram(label, &values[0], valuesCount, valuesOffset, overlayText, scaleMin, scaleMax, ImVec2(graphWidth, graphHeight), stride);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_label, label);
	env->ReleaseStringUTFChars(obj_overlayText, overlayText);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_value__Ljava_lang_String_2Z(JNIEnv* env, jclass clazz, jstring obj_prefix, jboolean b) {
	char* prefix = (char*)env->GetStringUTFChars(obj_prefix, 0);


//@line:4070

        ImGui::Value(prefix, b);
    
	env->ReleaseStringUTFChars(obj_prefix, prefix);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_value__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_prefix, jint v) {
	char* prefix = (char*)env->GetStringUTFChars(obj_prefix, 0);


//@line:4074

        ImGui::Value(prefix, (int)v);
    
	env->ReleaseStringUTFChars(obj_prefix, prefix);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_value__Ljava_lang_String_2J(JNIEnv* env, jclass clazz, jstring obj_prefix, jlong v) {
	char* prefix = (char*)env->GetStringUTFChars(obj_prefix, 0);


//@line:4078

        ImGui::Value(prefix, (unsigned int)v);
    
	env->ReleaseStringUTFChars(obj_prefix, prefix);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_value__Ljava_lang_String_2F(JNIEnv* env, jclass clazz, jstring obj_prefix, jfloat f) {
	char* prefix = (char*)env->GetStringUTFChars(obj_prefix, 0);


//@line:4082

        ImGui::Value(prefix, f);
    
	env->ReleaseStringUTFChars(obj_prefix, prefix);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_value__Ljava_lang_String_2FLjava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_prefix, jfloat f, jstring obj_floatFormat) {
	char* prefix = (char*)env->GetStringUTFChars(obj_prefix, 0);
	char* floatFormat = (char*)env->GetStringUTFChars(obj_floatFormat, 0);


//@line:4086

        ImGui::Value(prefix, f, floatFormat);
    
	env->ReleaseStringUTFChars(obj_prefix, prefix);
	env->ReleaseStringUTFChars(obj_floatFormat, floatFormat);

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginMenuBar(JNIEnv* env, jclass clazz) {


//@line:4098

        return ImGui::BeginMenuBar();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endMenuBar(JNIEnv* env, jclass clazz) {


//@line:4105

        ImGui::EndMenuBar();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginMainMenuBar(JNIEnv* env, jclass clazz) {


//@line:4112

        return ImGui::BeginMainMenuBar();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endMainMenuBar(JNIEnv* env, jclass clazz) {


//@line:4119

        ImGui::EndMainMenuBar();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginMenu__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:4126

        return ImGui::BeginMenu(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginMenu__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginMenu__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginMenu__Ljava_lang_String_2Z
(JNIEnv* env, jclass clazz, jstring obj_label, jboolean enabled, char* label) {

//@line:4133

        return ImGui::BeginMenu(label, enabled);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginMenu__Ljava_lang_String_2Z(JNIEnv* env, jclass clazz, jstring obj_label, jboolean enabled) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginMenu__Ljava_lang_String_2Z(env, clazz, obj_label, enabled, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endMenu(JNIEnv* env, jclass clazz) {


//@line:4140

        ImGui::EndMenu();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_menuItem
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:4147

        return ImGui::MenuItem(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_menuItem(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_menuItem(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nMenuItem__Ljava_lang_String_2Ljava_lang_String_2ZZ(JNIEnv* env, jclass clazz, jstring labelObj, jstring shortcutObj, jboolean selected, jboolean enabled) {

//@line:4189

        char* label = (char*)env->GetStringUTFChars(labelObj, JNI_FALSE);
        char* shortcut = NULL;
        if (shortcutObj != NULL)
            shortcut = (char*)env->GetStringUTFChars(shortcutObj, JNI_FALSE);

        jboolean result = ImGui::MenuItem(label, shortcut, selected, enabled);

        if (shortcutObj != NULL)
            env->ReleaseStringUTFChars(shortcutObj, shortcut);
        env->ReleaseStringUTFChars(labelObj, label);

        return result;
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nMenuItem__Ljava_lang_String_2Ljava_lang_String_2_3ZZ(JNIEnv* env, jclass clazz, jstring labelObj, jstring shortcutObj, jbooleanArray pSelectedObj, jboolean enabled) {

//@line:4207

        char* label = (char*)env->GetStringUTFChars(labelObj, JNI_FALSE);
        char* shortcut = NULL;
        if (shortcutObj != NULL)
            shortcut = (char*)env->GetStringUTFChars(shortcutObj, JNI_FALSE);
        bool* pSelected = (bool*)env->GetPrimitiveArrayCritical(pSelectedObj, JNI_FALSE);

        jboolean result = ImGui::MenuItem(label, shortcut, &pSelected[0], enabled);

        env->ReleasePrimitiveArrayCritical(pSelectedObj, pSelected, 0);
        if (shortcutObj != NULL)
            env->ReleaseStringUTFChars(shortcutObj, shortcut);
        env->ReleaseStringUTFChars(labelObj, label);

        return result;
    
}

JNIEXPORT void JNICALL Java_imgui_ImGui_beginTooltip(JNIEnv* env, jclass clazz) {


//@line:4230

        ImGui::BeginTooltip();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endTooltip(JNIEnv* env, jclass clazz) {


//@line:4234

        ImGui::EndTooltip();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setTooltip(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:4241

        ImGui::SetTooltip(text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopup__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:4260

        return ImGui::BeginPopup(strId);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopup__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopup__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopup__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiWindowFlags, char* strId) {

//@line:4267

        return ImGui::BeginPopup(strId, imGuiWindowFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopup__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiWindowFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopup__Ljava_lang_String_2I(env, clazz, obj_strId, imGuiWindowFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopupModal
(JNIEnv* env, jclass clazz, jstring obj_name, char* name) {

//@line:4274

        return ImGui::BeginPopupModal(name);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupModal(JNIEnv* env, jclass clazz, jstring obj_name) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopupModal(env, clazz, obj_name, name);

	env->ReleaseStringUTFChars(obj_name, name);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nBeginPopupModal__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_name, jint imGuiWindowFlags, char* name) {

//@line:4299

        return ImGui::BeginPopupModal(name, NULL, imGuiWindowFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nBeginPopupModal__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_name, jint imGuiWindowFlags) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nBeginPopupModal__Ljava_lang_String_2I(env, clazz, obj_name, imGuiWindowFlags, name);

	env->ReleaseStringUTFChars(obj_name, name);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nBeginPopupModal__Ljava_lang_String_2_3ZI
(JNIEnv* env, jclass clazz, jstring obj_name, jbooleanArray obj_pOpen, jint imGuiWindowFlags, char* name, bool* pOpen) {

//@line:4303

        return ImGui::BeginPopupModal(name, &pOpen[0], imGuiWindowFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nBeginPopupModal__Ljava_lang_String_2_3ZI(JNIEnv* env, jclass clazz, jstring obj_name, jbooleanArray obj_pOpen, jint imGuiWindowFlags) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nBeginPopupModal__Ljava_lang_String_2_3ZI(env, clazz, obj_name, obj_pOpen, imGuiWindowFlags, name, pOpen);

	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);
	env->ReleaseStringUTFChars(obj_name, name);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endPopup(JNIEnv* env, jclass clazz) {


//@line:4310

        ImGui::EndPopup();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_openPopup__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);


//@line:4324

        ImGui::OpenPopup(strId);
    
	env->ReleaseStringUTFChars(obj_strId, strId);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_openPopup__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);


//@line:4331

        ImGui::OpenPopup(strId, imGuiPopupFlags);
    
	env->ReleaseStringUTFChars(obj_strId, strId);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_openPopupOnItemClick__(JNIEnv* env, jclass clazz) {


//@line:4338

        ImGui::OpenPopupOnItemClick();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_openPopupOnItemClick__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);


//@line:4345

        ImGui::OpenPopupOnItemClick(strId);
    
	env->ReleaseStringUTFChars(obj_strId, strId);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_openPopupOnItemClick__I(JNIEnv* env, jclass clazz, jint imGuiPopupFlags) {


//@line:4352

        ImGui::OpenPopupOnItemClick(NULL, imGuiPopupFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_openPopupOnItemClick__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);


//@line:4359

        ImGui::OpenPopupOnItemClick(strId, imGuiPopupFlags);
    
	env->ReleaseStringUTFChars(obj_strId, strId);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_closeCurrentPopup(JNIEnv* env, jclass clazz) {


//@line:4366

        ImGui::CloseCurrentPopup();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextItem__(JNIEnv* env, jclass clazz) {


//@line:4380

        return ImGui::BeginPopupContextItem();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopupContextItem__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:4388

        return ImGui::BeginPopupContextItem(strId);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextItem__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopupContextItem__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextItem__I(JNIEnv* env, jclass clazz, jint imGuiPopupFlags) {


//@line:4396

        return ImGui::BeginPopupContextItem(NULL, imGuiPopupFlags);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopupContextItem__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags, char* strId) {

//@line:4404

        return ImGui::BeginPopupContextItem(strId, imGuiPopupFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextItem__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopupContextItem__Ljava_lang_String_2I(env, clazz, obj_strId, imGuiPopupFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextWindow__(JNIEnv* env, jclass clazz) {


//@line:4411

        return ImGui::BeginPopupContextWindow();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopupContextWindow__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:4418

        return ImGui::BeginPopupContextWindow(strId);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextWindow__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopupContextWindow__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextWindow__I(JNIEnv* env, jclass clazz, jint imGuiPopupFlags) {


//@line:4425

        return ImGui::BeginPopupContextWindow(NULL, imGuiPopupFlags);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopupContextWindow__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags, char* strId) {

//@line:4432

        return ImGui::BeginPopupContextWindow(strId, imGuiPopupFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextWindow__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopupContextWindow__Ljava_lang_String_2I(env, clazz, obj_strId, imGuiPopupFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextVoid__(JNIEnv* env, jclass clazz) {


//@line:4439

        return ImGui::BeginPopupContextVoid();
     

}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopupContextVoid__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:4446

        return ImGui::BeginPopupContextVoid(strId);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextVoid__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopupContextVoid__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextVoid__I(JNIEnv* env, jclass clazz, jint imGuiPopupFlags) {


//@line:4453

        return ImGui::BeginPopupContextVoid(NULL, imGuiPopupFlags);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginPopupContextVoid__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags, char* strId) {

//@line:4460

        return ImGui::BeginPopupContextVoid(strId, imGuiPopupFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginPopupContextVoid__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginPopupContextVoid__Ljava_lang_String_2I(env, clazz, obj_strId, imGuiPopupFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_isPopupOpen__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:4472

        return ImGui::IsPopupOpen(strId);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isPopupOpen__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_isPopupOpen__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_isPopupOpen__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags, char* strId) {

//@line:4479

        return ImGui::IsPopupOpen(strId, imGuiPopupFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isPopupOpen__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiPopupFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_isPopupOpen__Ljava_lang_String_2I(env, clazz, obj_strId, imGuiPopupFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_id, jint column, char* id) {

//@line:4509

        return ImGui::BeginTable(id, column);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginTable__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_id, jint column) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2I(env, clazz, obj_id, column, id);

	env->ReleaseStringUTFChars(obj_id, id);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2II
(JNIEnv* env, jclass clazz, jstring obj_id, jint column, jint imGuiTableFlags, char* id) {

//@line:4513

        return ImGui::BeginTable(id, column, imGuiTableFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginTable__Ljava_lang_String_2II(JNIEnv* env, jclass clazz, jstring obj_id, jint column, jint imGuiTableFlags) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2II(env, clazz, obj_id, column, imGuiTableFlags, id);

	env->ReleaseStringUTFChars(obj_id, id);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2IIFF
(JNIEnv* env, jclass clazz, jstring obj_id, jint column, jint imGuiTableFlags, jfloat outerSizeX, jfloat outerSizeY, char* id) {

//@line:4517

        return ImGui::BeginTable(id, column, imGuiTableFlags, ImVec2(outerSizeX, outerSizeY));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginTable__Ljava_lang_String_2IIFF(JNIEnv* env, jclass clazz, jstring obj_id, jint column, jint imGuiTableFlags, jfloat outerSizeX, jfloat outerSizeY) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2IIFF(env, clazz, obj_id, column, imGuiTableFlags, outerSizeX, outerSizeY, id);

	env->ReleaseStringUTFChars(obj_id, id);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2IIFFF
(JNIEnv* env, jclass clazz, jstring obj_id, jint column, jint imGuiTableFlags, jfloat outerSizeX, jfloat outerSizeY, jfloat innerWidth, char* id) {

//@line:4521

        return ImGui::BeginTable(id, column, imGuiTableFlags, ImVec2(outerSizeX, outerSizeY), innerWidth);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginTable__Ljava_lang_String_2IIFFF(JNIEnv* env, jclass clazz, jstring obj_id, jint column, jint imGuiTableFlags, jfloat outerSizeX, jfloat outerSizeY, jfloat innerWidth) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginTable__Ljava_lang_String_2IIFFF(env, clazz, obj_id, column, imGuiTableFlags, outerSizeX, outerSizeY, innerWidth, id);

	env->ReleaseStringUTFChars(obj_id, id);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endTable(JNIEnv* env, jclass clazz) {


//@line:4528

        ImGui::EndTable();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableNextRow__(JNIEnv* env, jclass clazz) {


//@line:4535

        ImGui::TableNextRow();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableNextRow__I(JNIEnv* env, jclass clazz, jint imGuiTableRowFlags) {


//@line:4542

        ImGui::TableNextRow(imGuiTableRowFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableNextRow__IF(JNIEnv* env, jclass clazz, jint imGuiTableRowFlags, jfloat minRowHeight) {


//@line:4549

        ImGui::TableNextRow(imGuiTableRowFlags, minRowHeight);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_tableNextColumn(JNIEnv* env, jclass clazz) {


//@line:4556

        return ImGui::TableNextColumn();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_tableSetColumnIndex(JNIEnv* env, jclass clazz, jint columnN) {


//@line:4563

        return ImGui::TableSetColumnIndex(columnN);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableSetupColumn__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);


//@line:4576

        ImGui::TableSetupColumn(label);
    
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableSetupColumn__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTableColumnFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);


//@line:4580

        ImGui::TableSetupColumn(label, imGuiTableColumnFlags);
    
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableSetupColumn__Ljava_lang_String_2IF(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTableColumnFlags, jfloat initWidthOrWeight) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);


//@line:4584

        ImGui::TableSetupColumn(label, imGuiTableColumnFlags, initWidthOrWeight);
    
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableSetupColumn__Ljava_lang_String_2IFI(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTableColumnFlags, jfloat initWidthOrWeight, jint userId) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);


//@line:4588

        ImGui::TableSetupColumn(label, imGuiTableColumnFlags, initWidthOrWeight, userId);
    
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableSetupScrollFreeze(JNIEnv* env, jclass clazz, jint cols, jint rows) {


//@line:4595

        ImGui::TableSetupScrollFreeze(cols, rows);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableHeadersRow(JNIEnv* env, jclass clazz) {


//@line:4602

        ImGui::TableHeadersRow();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableHeader(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);


//@line:4609

        ImGui::TableHeader(label);
    
	env->ReleaseStringUTFChars(obj_label, label);

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_tableGetColumnCount(JNIEnv* env, jclass clazz) {


//@line:4628

        return ImGui::TableGetColumnCount();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_tableGetColumnIndex(JNIEnv* env, jclass clazz) {


//@line:4635

        return ImGui::TableGetColumnIndex();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_tableGetRowIndex(JNIEnv* env, jclass clazz) {


//@line:4642

        return ImGui::TableGetRowIndex();
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGui_tableGetColumnName__(JNIEnv* env, jclass clazz) {


//@line:4649

        return env->NewStringUTF(ImGui::TableGetColumnName());
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGui_tableGetColumnName__I(JNIEnv* env, jclass clazz, jint columnN) {


//@line:4656

        return env->NewStringUTF(ImGui::TableGetColumnName(columnN));
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_tableGetColumnFlags__(JNIEnv* env, jclass clazz) {


//@line:4663

        return ImGui::TableGetColumnFlags();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_tableGetColumnFlags__I(JNIEnv* env, jclass clazz, jint columnN) {


//@line:4670

        return ImGui::TableGetColumnFlags(columnN);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableSetBgColor__II(JNIEnv* env, jclass clazz, jint imGuiTableBgTarget, jint color) {


//@line:4677

        ImGui::TableSetBgColor(imGuiTableBgTarget, color);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_tableSetBgColor__III(JNIEnv* env, jclass clazz, jint imGuiTableBgTarget, jint color, jint columnN) {


//@line:4684

        ImGui::TableSetBgColor(imGuiTableBgTarget, color, columnN);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_columns__(JNIEnv* env, jclass clazz) {


//@line:4692

        ImGui::Columns();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_columns__I(JNIEnv* env, jclass clazz, jint count) {


//@line:4696

        ImGui::Columns(count);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_columns__ILjava_lang_String_2(JNIEnv* env, jclass clazz, jint count, jstring obj_id) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);


//@line:4700

        ImGui::Columns(count, id);
    
	env->ReleaseStringUTFChars(obj_id, id);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_columns__ILjava_lang_String_2Z(JNIEnv* env, jclass clazz, jint count, jstring obj_id, jboolean border) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);


//@line:4704

        ImGui::Columns(count, id, border);
    
	env->ReleaseStringUTFChars(obj_id, id);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nextColumn(JNIEnv* env, jclass clazz) {


//@line:4711

        ImGui::NextColumn();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getColumnIndex(JNIEnv* env, jclass clazz) {


//@line:4718

        return ImGui::GetColumnIndex();
     

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getColumnWidth__(JNIEnv* env, jclass clazz) {


//@line:4725

        return ImGui::GetColumnWidth();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getColumnWidth__I(JNIEnv* env, jclass clazz, jint columnIndex) {


//@line:4732

        return ImGui::GetColumnWidth(columnIndex);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setColumnWidth(JNIEnv* env, jclass clazz, jint columnIndex, jfloat width) {


//@line:4739

        ImGui::SetColumnWidth(columnIndex, width);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getColumnOffset__(JNIEnv* env, jclass clazz) {


//@line:4746

        return ImGui::GetColumnOffset();
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getColumnOffset__I(JNIEnv* env, jclass clazz, jint columnIndex) {


//@line:4753

        return ImGui::GetColumnOffset(columnIndex);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setColumnOffset(JNIEnv* env, jclass clazz, jint columnIndex, jfloat offsetX) {


//@line:4760

        ImGui::SetColumnOffset(columnIndex, offsetX);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getColumnsCount(JNIEnv* env, jclass clazz) {


//@line:4764

        return ImGui::GetColumnsCount();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginTabBar__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_strId, char* strId) {

//@line:4774

        return ImGui::BeginTabBar(strId);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginTabBar__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_strId) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginTabBar__Ljava_lang_String_2(env, clazz, obj_strId, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_beginTabBar__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiTabBarFlags, char* strId) {

//@line:4781

        return ImGui::BeginTabBar(strId, imGuiTabBarFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginTabBar__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_strId, jint imGuiTabBarFlags) {
	char* strId = (char*)env->GetStringUTFChars(obj_strId, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginTabBar__Ljava_lang_String_2I(env, clazz, obj_strId, imGuiTabBarFlags, strId);

	env->ReleaseStringUTFChars(obj_strId, strId);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endTabBar(JNIEnv* env, jclass clazz) {


//@line:4788

        ImGui::EndTabBar();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_beginTabItem
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:4795

        return ImGui::BeginTabItem(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginTabItem(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_beginTabItem(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nBeginTabItem__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTabItemFlags, char* label) {

//@line:4820

        return ImGui::BeginTabItem(label, NULL, imGuiTabItemFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nBeginTabItem__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTabItemFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nBeginTabItem__Ljava_lang_String_2I(env, clazz, obj_label, imGuiTabItemFlags, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_nBeginTabItem__Ljava_lang_String_2_3ZI
(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_pOpen, jint imGuiTabItemFlags, char* label, bool* pOpen) {

//@line:4824

        return ImGui::BeginTabItem(label, &pOpen[0], imGuiTabItemFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nBeginTabItem__Ljava_lang_String_2_3ZI(JNIEnv* env, jclass clazz, jstring obj_label, jbooleanArray obj_pOpen, jint imGuiTabItemFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nBeginTabItem__Ljava_lang_String_2_3ZI(env, clazz, obj_label, obj_pOpen, imGuiTabItemFlags, label, pOpen);

	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);
	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endTabItem(JNIEnv* env, jclass clazz) {


//@line:4831

        ImGui::EndTabItem();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_tabItemButton__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:4838

        return ImGui::TabItemButton(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_tabItemButton__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_tabItemButton__Ljava_lang_String_2(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_ImGui_tabItemButton__Ljava_lang_String_2I
(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTabItemFlags, char* label) {

//@line:4845

        return ImGui::TabItemButton(label, imGuiTabItemFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_tabItemButton__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_label, jint imGuiTabItemFlags) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_tabItemButton__Ljava_lang_String_2I(env, clazz, obj_label, imGuiTabItemFlags, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_setTabItemClosed(JNIEnv* env, jclass clazz, jstring obj_tabOrDockedWindowLabel) {
	char* tabOrDockedWindowLabel = (char*)env->GetStringUTFChars(obj_tabOrDockedWindowLabel, 0);


//@line:4853

        ImGui::SetTabItemClosed(tabOrDockedWindowLabel);
    
	env->ReleaseStringUTFChars(obj_tabOrDockedWindowLabel, tabOrDockedWindowLabel);

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_nDockSpace(JNIEnv* env, jclass clazz, jint imGuiID, jfloat sizeX, jfloat sizeY, jint imGuiDockNodeFlags, jlong windowClassPtr) {


//@line:4882

        return ImGui::DockSpace(imGuiID, ImVec2(sizeX, sizeY), imGuiDockNodeFlags, windowClassPtr != 0 ? (ImGuiWindowClass*)windowClassPtr : NULL);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_nDockSpaceOverViewport(JNIEnv* env, jclass clazz, jlong viewportPtr, jint imGuiDockNodeFlags, jlong windowClassPtr) {


//@line:4902

        return ImGui::DockSpaceOverViewport(viewportPtr != 0 ? (ImGuiViewport*)viewportPtr : NULL, imGuiDockNodeFlags, windowClassPtr != 0 ? (ImGuiWindowClass*)windowClassPtr : NULL);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowDockID__I(JNIEnv* env, jclass clazz, jint dockId) {


//@line:4909

        ImGui::SetNextWindowDockID(dockId);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setNextWindowDockID__II(JNIEnv* env, jclass clazz, jint dockId, jint imGuiCond) {


//@line:4916

        ImGui::SetNextWindowDockID(dockId, imGuiCond);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nSetNextWindowClass(JNIEnv* env, jclass clazz, jlong windowClassPtr) {


//@line:4927

        ImGui::SetNextWindowClass((ImGuiWindowClass*)windowClassPtr);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getWindowDockID(JNIEnv* env, jclass clazz) {


//@line:4931

        return ImGui::GetWindowDockID();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isWindowDocked(JNIEnv* env, jclass clazz) {


//@line:4938

        return ImGui::IsWindowDocked();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logToTTY__(JNIEnv* env, jclass clazz) {


//@line:4948

        ImGui::LogToTTY();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logToTTY__I(JNIEnv* env, jclass clazz, jint autoOpenDepth) {


//@line:4955

        ImGui::LogToTTY(autoOpenDepth);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logToFile__(JNIEnv* env, jclass clazz) {


//@line:4962

        ImGui::LogToFile();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logToFile__I(JNIEnv* env, jclass clazz, jint autoOpenDepth) {


//@line:4969

        ImGui::LogToFile(autoOpenDepth);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logToFile__ILjava_lang_String_2(JNIEnv* env, jclass clazz, jint autoOpenDepth, jstring obj_filename) {
	char* filename = (char*)env->GetStringUTFChars(obj_filename, 0);


//@line:4976

        ImGui::LogToFile(autoOpenDepth, filename);
    
	env->ReleaseStringUTFChars(obj_filename, filename);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logToClipboard__(JNIEnv* env, jclass clazz) {


//@line:4983

        ImGui::LogToClipboard();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logToClipboard__I(JNIEnv* env, jclass clazz, jint autoOpenDepth) {


//@line:4991

        ImGui::LogToClipboard(autoOpenDepth);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logFinish(JNIEnv* env, jclass clazz) {


//@line:4998

        ImGui::LogFinish();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logButtons(JNIEnv* env, jclass clazz) {


//@line:5005

        ImGui::LogButtons();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_logText(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:5012

        ImGui::LogText(text, NULL);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginDragDropSource__(JNIEnv* env, jclass clazz) {


//@line:5025

        return ImGui::BeginDragDropSource();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginDragDropSource__I(JNIEnv* env, jclass clazz, jint imGuiDragDropFlags) {


//@line:5032

        return ImGui::BeginDragDropSource(imGuiDragDropFlags);
    

}

static inline jboolean wrapped_Java_imgui_ImGui_nSetDragDropPayload
(JNIEnv* env, jclass clazz, jstring obj_dataType, jbyteArray obj_data, jint sz, jint imGuiCond, char* dataType, char* data) {

//@line:5075

        return ImGui::SetDragDropPayload(dataType, &data[0], sz, imGuiCond);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nSetDragDropPayload(JNIEnv* env, jclass clazz, jstring obj_dataType, jbyteArray obj_data, jint sz, jint imGuiCond) {
	char* dataType = (char*)env->GetStringUTFChars(obj_dataType, 0);
	char* data = (char*)env->GetPrimitiveArrayCritical(obj_data, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nSetDragDropPayload(env, clazz, obj_dataType, obj_data, sz, imGuiCond, dataType, data);

	env->ReleasePrimitiveArrayCritical(obj_data, data, 0);
	env->ReleaseStringUTFChars(obj_dataType, dataType);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endDragDropSource(JNIEnv* env, jclass clazz) {


//@line:5082

        ImGui::EndDragDropSource();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginDragDropTarget(JNIEnv* env, jclass clazz) {


//@line:5089

        return ImGui::BeginDragDropTarget();
    

}

static inline jboolean wrapped_Java_imgui_ImGui_nAcceptDragDropPayload
(JNIEnv* env, jclass clazz, jstring obj_dataType, jint imGuiDragDropFlags, char* dataType) {

//@line:5144

        return ImGui::AcceptDragDropPayload(dataType, imGuiDragDropFlags) != NULL;
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nAcceptDragDropPayload(JNIEnv* env, jclass clazz, jstring obj_dataType, jint imGuiDragDropFlags) {
	char* dataType = (char*)env->GetStringUTFChars(obj_dataType, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nAcceptDragDropPayload(env, clazz, obj_dataType, imGuiDragDropFlags, dataType);

	env->ReleaseStringUTFChars(obj_dataType, dataType);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_endDragDropTarget(JNIEnv* env, jclass clazz) {


//@line:5151

        ImGui::EndDragDropTarget();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nHasDragDropPayload__(JNIEnv* env, jclass clazz) {


//@line:5190

        const ImGuiPayload* payload = ImGui::GetDragDropPayload();
        return payload != NULL && payload->Data != NULL;
    

}

static inline jboolean wrapped_Java_imgui_ImGui_nHasDragDropPayload__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_dataType, char* dataType) {

//@line:5195

        const ImGuiPayload* payload = ImGui::GetDragDropPayload();
        return payload != NULL && payload->IsDataType(dataType);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_nHasDragDropPayload__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_dataType) {
	char* dataType = (char*)env->GetStringUTFChars(obj_dataType, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_ImGui_nHasDragDropPayload__Ljava_lang_String_2(env, clazz, obj_dataType, dataType);

	env->ReleaseStringUTFChars(obj_dataType, dataType);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_ImGui_beginDisabled(JNIEnv* env, jclass clazz, jboolean disabled) {


//@line:5214

        ImGui::BeginDisabled(disabled);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endDisabled(JNIEnv* env, jclass clazz) {


//@line:5218

        ImGui::EndDisabled();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_pushClipRect(JNIEnv* env, jclass clazz, jfloat clipRectMinX, jfloat clipRectMinY, jfloat clipRectMaxX, jfloat clipRectMaxY, jboolean intersectWithCurrentClipRect) {


//@line:5225

        ImGui::PushClipRect(ImVec2(clipRectMinX, clipRectMinY), ImVec2(clipRectMaxX, clipRectMaxY), intersectWithCurrentClipRect);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_popClipRect(JNIEnv* env, jclass clazz) {


//@line:5229

        ImGui::PopClipRect();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setItemDefaultFocus(JNIEnv* env, jclass clazz) {


//@line:5239

        ImGui::SetItemDefaultFocus();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setKeyboardFocusHere__(JNIEnv* env, jclass clazz) {


//@line:5246

        ImGui::SetKeyboardFocusHere();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setKeyboardFocusHere__I(JNIEnv* env, jclass clazz, jint offset) {


//@line:5253

        ImGui::SetKeyboardFocusHere(offset);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemHovered__(JNIEnv* env, jclass clazz) {


//@line:5264

        return ImGui::IsItemHovered();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemHovered__I(JNIEnv* env, jclass clazz, jint imGuiHoveredFlags) {


//@line:5271

        return ImGui::IsItemHovered(imGuiHoveredFlags);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemActive(JNIEnv* env, jclass clazz) {


//@line:5280

        return ImGui::IsItemActive();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemFocused(JNIEnv* env, jclass clazz) {


//@line:5287

        return ImGui::IsItemFocused();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemClicked__(JNIEnv* env, jclass clazz) {


//@line:5294

        return ImGui::IsItemClicked();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemClicked__I(JNIEnv* env, jclass clazz, jint mouseButton) {


//@line:5301

        return ImGui::IsItemClicked(mouseButton);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemVisible(JNIEnv* env, jclass clazz) {


//@line:5308

        return ImGui::IsItemVisible();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemEdited(JNIEnv* env, jclass clazz) {


//@line:5315

        return ImGui::IsItemEdited();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemActivated(JNIEnv* env, jclass clazz) {


//@line:5322

        return ImGui::IsItemActivated();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemDeactivated(JNIEnv* env, jclass clazz) {


//@line:5329

        return ImGui::IsItemDeactivated();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemDeactivatedAfterEdit(JNIEnv* env, jclass clazz) {


//@line:5338

        return ImGui::IsItemDeactivatedAfterEdit();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isItemToggledOpen(JNIEnv* env, jclass clazz) {


//@line:5345

        return ImGui::IsItemToggledOpen();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isAnyItemHovered(JNIEnv* env, jclass clazz) {


//@line:5352

        return ImGui::IsAnyItemHovered();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isAnyItemActive(JNIEnv* env, jclass clazz) {


//@line:5359

        return ImGui::IsAnyItemActive();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isAnyItemFocused(JNIEnv* env, jclass clazz) {


//@line:5366

        return ImGui::IsAnyItemFocused();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getItemRectMin(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:5382

        Jni::ImVec2Cpy(env, ImGui::GetItemRectMin(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getItemRectMinX(JNIEnv* env, jclass clazz) {


//@line:5389

        return ImGui::GetItemRectMin().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getItemRectMinY(JNIEnv* env, jclass clazz) {


//@line:5396

        return ImGui::GetItemRectMin().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getItemRectMax(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:5412

        Jni::ImVec2Cpy(env, ImGui::GetItemRectMax(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getItemRectMaxX(JNIEnv* env, jclass clazz) {


//@line:5419

        return ImGui::GetItemRectMax().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getItemRectMaxY(JNIEnv* env, jclass clazz) {


//@line:5426

        return ImGui::GetItemRectMax().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getItemRectSize(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:5442

        Jni::ImVec2Cpy(env, ImGui::GetItemRectSize(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getItemRectSizeX(JNIEnv* env, jclass clazz) {


//@line:5449

        return ImGui::GetItemRectSize().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getItemRectSizeY(JNIEnv* env, jclass clazz) {


//@line:5456

        return ImGui::GetItemRectSize().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setItemAllowOverlap(JNIEnv* env, jclass clazz) {


//@line:5463

        ImGui::SetItemAllowOverlap();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetMainViewport(JNIEnv* env, jclass clazz) {


//@line:5480

        return (intptr_t)ImGui::GetMainViewport();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isRectVisible__FF(JNIEnv* env, jclass clazz, jfloat width, jfloat height) {


//@line:5489

        return ImGui::IsRectVisible(ImVec2(width, height));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isRectVisible__FFFF(JNIEnv* env, jclass clazz, jfloat minX, jfloat minY, jfloat maxX, jfloat maxY) {


//@line:5496

        return ImGui::IsRectVisible(ImVec2(minX, minY), ImVec2(maxX, maxY));
    

}

JNIEXPORT jdouble JNICALL Java_imgui_ImGui_getTime(JNIEnv* env, jclass clazz) {


//@line:5503

        return ImGui::GetTime();
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getFrameCount(JNIEnv* env, jclass clazz) {


//@line:5510

        return ImGui::GetFrameCount();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetBackgroundDrawList__(JNIEnv* env, jclass clazz) {


//@line:5523

        return (intptr_t)ImGui::GetBackgroundDrawList();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetForegroundDrawList__(JNIEnv* env, jclass clazz) {


//@line:5536

        return (intptr_t)ImGui::GetForegroundDrawList();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetBackgroundDrawList__J(JNIEnv* env, jclass clazz, jlong viewportPtr) {


//@line:5549

        return (intptr_t)ImGui::GetBackgroundDrawList((ImGuiViewport*)viewportPtr);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetForegroundDrawList__J(JNIEnv* env, jclass clazz, jlong viewportPtr) {


//@line:5562

        return (intptr_t)ImGui::GetBackgroundDrawList((ImGuiViewport*)viewportPtr);
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGui_getStyleColorName(JNIEnv* env, jclass clazz, jint imGuiCol) {


//@line:5571

        return env->NewStringUTF(ImGui::GetStyleColorName(imGuiCol));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_nSetStateStorage(JNIEnv* env, jclass clazz, jlong imGuiStoragePtr) {


//@line:5582

        ImGui::SetStateStorage((ImGuiStorage*)imGuiStoragePtr);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetStateStorage(JNIEnv* env, jclass clazz) {


//@line:5591

        return (intptr_t)ImGui::GetStateStorage();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChildFrame__IFF(JNIEnv* env, jclass clazz, jint id, jfloat width, jfloat height) {


//@line:5598

        return ImGui::BeginChildFrame(id, ImVec2(width, height));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_beginChildFrame__IFFI(JNIEnv* env, jclass clazz, jint id, jfloat width, jfloat height, jint imGuiWindowFlags) {


//@line:5605

        return ImGui::BeginChildFrame(id, ImVec2(width, height), imGuiWindowFlags);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_endChildFrame(JNIEnv* env, jclass clazz) {


//@line:5612

        ImGui::EndChildFrame();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_calcTextSize__Limgui_ImVec2_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jobject dstImVec2, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:5636

        ImVec2 src = ImGui::CalcTextSize(text);
        Jni::ImVec2Cpy(env, src, dstImVec2);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_calcTextSize__Limgui_ImVec2_2Ljava_lang_String_2Z(JNIEnv* env, jclass clazz, jobject dstImVec2, jstring obj_text, jboolean hideTextAfterDoubleHash) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:5641

        ImVec2 src = ImGui::CalcTextSize(text, NULL, hideTextAfterDoubleHash);
        Jni::ImVec2Cpy(env, src, dstImVec2);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_calcTextSize__Limgui_ImVec2_2Ljava_lang_String_2F(JNIEnv* env, jclass clazz, jobject dstImVec2, jstring obj_text, jfloat wrapWidth) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:5646

        ImVec2 src = ImGui::CalcTextSize(text, NULL, false, wrapWidth);
        Jni::ImVec2Cpy(env, src, dstImVec2);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_calcTextSize__Limgui_ImVec2_2Ljava_lang_String_2ZF(JNIEnv* env, jclass clazz, jobject dstImVec2, jstring obj_text, jboolean hideTextAfterDoubleHash, jfloat wrapWidth) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:5651

        ImVec2 src = ImGui::CalcTextSize(text, NULL, hideTextAfterDoubleHash, wrapWidth);
        Jni::ImVec2Cpy(env, src, dstImVec2);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_colorConvertU32ToFloat4(JNIEnv* env, jclass clazz, jint in, jobject dstImVec4) {


//@line:5664

        Jni::ImVec4Cpy(env, ImGui::ColorConvertU32ToFloat4(in), dstImVec4);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_colorConvertFloat4ToU32(JNIEnv* env, jclass clazz, jfloat r, jfloat g, jfloat b, jfloat a) {


//@line:5668

        return ImGui::ColorConvertFloat4ToU32(ImVec4(r, g, b, a));
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_colorConvertRGBtoHSV(JNIEnv* env, jclass clazz, jfloatArray obj_rgb, jfloatArray obj_hsv) {
	float* rgb = (float*)env->GetPrimitiveArrayCritical(obj_rgb, 0);
	float* hsv = (float*)env->GetPrimitiveArrayCritical(obj_hsv, 0);


//@line:5672

        ImGui::ColorConvertRGBtoHSV(rgb[0], rgb[1], rgb[2], hsv[0], hsv[1], hsv[2]);
    
	env->ReleasePrimitiveArrayCritical(obj_rgb, rgb, 0);
	env->ReleasePrimitiveArrayCritical(obj_hsv, hsv, 0);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_colorConvertHSVtoRGB(JNIEnv* env, jclass clazz, jfloatArray obj_hsv, jfloatArray obj_rgb) {
	float* hsv = (float*)env->GetPrimitiveArrayCritical(obj_hsv, 0);
	float* rgb = (float*)env->GetPrimitiveArrayCritical(obj_rgb, 0);


//@line:5676

        ImGui::ColorConvertHSVtoRGB(hsv[0], hsv[1], hsv[2], rgb[0], rgb[1], rgb[2]);
    
	env->ReleasePrimitiveArrayCritical(obj_hsv, hsv, 0);
	env->ReleasePrimitiveArrayCritical(obj_rgb, rgb, 0);

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getKeyIndex(JNIEnv* env, jclass clazz, jint imguiKey) {


//@line:5687

        return ImGui::GetKeyIndex(imguiKey);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isKeyDown(JNIEnv* env, jclass clazz, jint userKeyIndex) {


//@line:5694

        return ImGui::IsKeyDown(userKeyIndex);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isKeyPressed__I(JNIEnv* env, jclass clazz, jint userKeyIndex) {


//@line:5701

        return ImGui::IsKeyPressed(userKeyIndex);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isKeyPressed__IZ(JNIEnv* env, jclass clazz, jint userKeyIndex, jboolean repeat) {


//@line:5708

        return ImGui::IsKeyPressed(userKeyIndex, repeat);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isKeyReleased(JNIEnv* env, jclass clazz, jint userKeyIndex) {


//@line:5715

        return ImGui::IsKeyReleased(userKeyIndex);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_getKeyPressedAmount(JNIEnv* env, jclass clazz, jint keyIndex, jfloat repeatDelay, jfloat rate) {


//@line:5723

        return ImGui::GetKeyPressedAmount(keyIndex, repeatDelay, rate);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_captureKeyboardFromApp__(JNIEnv* env, jclass clazz) {


//@line:5732

        ImGui::CaptureKeyboardFromApp();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_captureKeyboardFromApp__Z(JNIEnv* env, jclass clazz, jboolean wantCaptureKeyboardValue) {


//@line:5741

        ImGui::CaptureKeyboardFromApp(wantCaptureKeyboardValue);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseDown(JNIEnv* env, jclass clazz, jint button) {


//@line:5753

        return ImGui::IsMouseDown(button);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isAnyMouseDown(JNIEnv* env, jclass clazz) {


//@line:5760

        return ImGui::IsAnyMouseDown();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseClicked__I(JNIEnv* env, jclass clazz, jint button) {


//@line:5767

        return ImGui::IsMouseClicked(button);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseClicked__IZ(JNIEnv* env, jclass clazz, jint button, jboolean repeat) {


//@line:5771

        return ImGui::IsMouseClicked(button, repeat);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseDoubleClicked(JNIEnv* env, jclass clazz, jint button) {


//@line:5778

        return ImGui::IsMouseDoubleClicked(button);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getMouseClickedCount(JNIEnv* env, jclass clazz, jint button) {


//@line:5785

        return ImGui::GetMouseClickedCount(button);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseReleased(JNIEnv* env, jclass clazz, jint button) {


//@line:5792

        return ImGui::IsMouseReleased(button);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseDragging__I(JNIEnv* env, jclass clazz, jint button) {


//@line:5799

        return ImGui::IsMouseDragging(button);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseDragging__IF(JNIEnv* env, jclass clazz, jint button, jfloat lockThreshold) {


//@line:5806

        return ImGui::IsMouseDragging(button, lockThreshold);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseHoveringRect__FFFF(JNIEnv* env, jclass clazz, jfloat minX, jfloat minY, jfloat maxX, jfloat maxY) {


//@line:5813

        return ImGui::IsMouseHoveringRect(ImVec2(minX, minY), ImVec2(maxX, maxY));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMouseHoveringRect__FFFFZ(JNIEnv* env, jclass clazz, jfloat minX, jfloat minY, jfloat maxX, jfloat maxY, jboolean clip) {


//@line:5820

        return ImGui::IsMouseHoveringRect(ImVec2(minX, minY), ImVec2(maxX, maxY), clip);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMousePosValid__(JNIEnv* env, jclass clazz) {


//@line:5827

        return ImGui::IsMousePosValid();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_ImGui_isMousePosValid__FF(JNIEnv* env, jclass clazz, jfloat mousePosX, jfloat mousePosY) {


//@line:5834

        ImVec2 pos = ImVec2(mousePosX, mousePosY);
        return ImGui::IsMousePosValid(&pos);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getMousePos(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:5851

        Jni::ImVec2Cpy(env, ImGui::GetMousePos(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMousePosX(JNIEnv* env, jclass clazz) {


//@line:5858

        return ImGui::GetMousePos().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMousePosY(JNIEnv* env, jclass clazz) {


//@line:5865

        return ImGui::GetMousePos().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getMousePosOnOpeningCurrentPopup(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:5881

        Jni::ImVec2Cpy(env, ImGui::GetMousePosOnOpeningCurrentPopup(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMousePosOnOpeningCurrentPopupX(JNIEnv* env, jclass clazz) {


//@line:5888

        return ImGui::GetMousePosOnOpeningCurrentPopup().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMousePosOnOpeningCurrentPopupY(JNIEnv* env, jclass clazz) {


//@line:5895

        return ImGui::GetMousePosOnOpeningCurrentPopup().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getMouseDragDelta__Limgui_ImVec2_2(JNIEnv* env, jclass clazz, jobject dstImVec2) {


//@line:5913

        Jni::ImVec2Cpy(env, ImGui::GetMouseDragDelta(), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMouseDragDeltaX__(JNIEnv* env, jclass clazz) {


//@line:5921

        return ImGui::GetMouseDragDelta().x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMouseDragDeltaY__(JNIEnv* env, jclass clazz) {


//@line:5929

        return ImGui::GetMouseDragDelta().y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getMouseDragDelta__Limgui_ImVec2_2I(JNIEnv* env, jclass clazz, jobject dstImVec2, jint button) {


//@line:5947

        Jni::ImVec2Cpy(env, ImGui::GetMouseDragDelta(button), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMouseDragDeltaX__I(JNIEnv* env, jclass clazz, jint button) {


//@line:5955

        return ImGui::GetMouseDragDelta(button).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMouseDragDeltaY__I(JNIEnv* env, jclass clazz, jint button) {


//@line:5963

        return ImGui::GetMouseDragDelta(button).y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_getMouseDragDelta__Limgui_ImVec2_2IF(JNIEnv* env, jclass clazz, jobject dstImVec2, jint button, jfloat lockThreshold) {


//@line:5981

        Jni::ImVec2Cpy(env, ImGui::GetMouseDragDelta(button, lockThreshold), dstImVec2);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMouseDragDeltaX__IF(JNIEnv* env, jclass clazz, jint button, jfloat lockThreshold) {


//@line:5989

        return ImGui::GetMouseDragDelta(button, lockThreshold).x;
    

}

JNIEXPORT jfloat JNICALL Java_imgui_ImGui_getMouseDragDeltaY__IF(JNIEnv* env, jclass clazz, jint button, jfloat lockThreshold) {


//@line:5997

        return ImGui::GetMouseDragDelta(button, lockThreshold).y;
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_resetMouseDragDelta__(JNIEnv* env, jclass clazz) {


//@line:6001

        ImGui::ResetMouseDragDelta();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_resetMouseDragDelta__I(JNIEnv* env, jclass clazz, jint button) {


//@line:6005

        ImGui::ResetMouseDragDelta(button);
    

}

JNIEXPORT jint JNICALL Java_imgui_ImGui_getMouseCursor(JNIEnv* env, jclass clazz) {


//@line:6013

        return ImGui::GetMouseCursor();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setMouseCursor(JNIEnv* env, jclass clazz, jint type) {


//@line:6020

        ImGui::SetMouseCursor(type);
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_captureMouseFromApp__(JNIEnv* env, jclass clazz) {


//@line:6028

        ImGui::CaptureMouseFromApp();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_captureMouseFromApp__Z(JNIEnv* env, jclass clazz, jboolean wantCaptureMouseValue) {


//@line:6036

        ImGui::CaptureMouseFromApp(wantCaptureMouseValue);
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGui_getClipboardText(JNIEnv* env, jclass clazz) {


//@line:6043

        return env->NewStringUTF(ImGui::GetClipboardText());
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_setClipboardText(JNIEnv* env, jclass clazz, jstring obj_text) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:6047

        ImGui::SetClipboardText(text);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_loadIniSettingsFromDisk(JNIEnv* env, jclass clazz, jstring obj_iniFilename) {
	char* iniFilename = (char*)env->GetStringUTFChars(obj_iniFilename, 0);


//@line:6058

        ImGui::LoadIniSettingsFromDisk(iniFilename);
    
	env->ReleaseStringUTFChars(obj_iniFilename, iniFilename);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_loadIniSettingsFromMemory__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_iniData) {
	char* iniData = (char*)env->GetStringUTFChars(obj_iniData, 0);


//@line:6065

        ImGui::LoadIniSettingsFromMemory(iniData);
    
	env->ReleaseStringUTFChars(obj_iniData, iniData);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_loadIniSettingsFromMemory__Ljava_lang_String_2I(JNIEnv* env, jclass clazz, jstring obj_iniData, jint iniSize) {
	char* iniData = (char*)env->GetStringUTFChars(obj_iniData, 0);


//@line:6072

        ImGui::LoadIniSettingsFromMemory(iniData, iniSize);
    
	env->ReleaseStringUTFChars(obj_iniData, iniData);

}

JNIEXPORT void JNICALL Java_imgui_ImGui_saveIniSettingsToDisk(JNIEnv* env, jclass clazz, jstring obj_iniFilename) {
	char* iniFilename = (char*)env->GetStringUTFChars(obj_iniFilename, 0);


//@line:6079

        ImGui::SaveIniSettingsToDisk(iniFilename);
    
	env->ReleaseStringUTFChars(obj_iniFilename, iniFilename);

}

JNIEXPORT jstring JNICALL Java_imgui_ImGui_saveIniSettingsToMemory__(JNIEnv* env, jclass clazz) {


//@line:6087

        return env->NewStringUTF(ImGui::SaveIniSettingsToMemory());
    

}

JNIEXPORT jstring JNICALL Java_imgui_ImGui_saveIniSettingsToMemory__J(JNIEnv* env, jclass clazz, jlong outIniSize) {


//@line:6095

        return env->NewStringUTF(ImGui::SaveIniSettingsToMemory((size_t*)&outIniSize));
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nGetPlatformIO(JNIEnv* env, jclass clazz) {


//@line:6111

        return (intptr_t)&ImGui::GetPlatformIO();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_updatePlatformWindows(JNIEnv* env, jclass clazz) {


//@line:6118

        ImGui::UpdatePlatformWindows();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_renderPlatformWindowsDefault(JNIEnv* env, jclass clazz) {


//@line:6126

        ImGui::RenderPlatformWindowsDefault();
    

}

JNIEXPORT void JNICALL Java_imgui_ImGui_destroyPlatformWindows(JNIEnv* env, jclass clazz) {


//@line:6135

        ImGui::DestroyPlatformWindows();
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nFindViewportByID(JNIEnv* env, jclass clazz, jint imGuiID) {


//@line:6147

        return (intptr_t)ImGui::FindViewportByID(imGuiID);
    

}

JNIEXPORT jlong JNICALL Java_imgui_ImGui_nFindViewportByPlatformHandle(JNIEnv* env, jclass clazz, jlong platformHandle) {


//@line:6159

        return (intptr_t)ImGui::FindViewportByPlatformHandle((void*)platformHandle);
    

}


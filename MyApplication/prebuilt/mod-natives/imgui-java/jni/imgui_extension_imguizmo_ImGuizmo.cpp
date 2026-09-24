#include <imgui_extension_imguizmo_ImGuizmo.h>

//@line:12

        #include "_imguizmo.h"
    JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nEnabled(JNIEnv* env, jclass clazz, jboolean enabled) {


//@line:16

        ImGuizmo::Enable(enabled);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nIsUsing(JNIEnv* env, jclass clazz) {


//@line:27

        return ImGuizmo::IsUsing();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nIsOver__(JNIEnv* env, jclass clazz) {


//@line:38

        return ImGuizmo::IsOver();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nSetDrawList(JNIEnv* env, jclass clazz, jlong pointer) {


//@line:49

        ImGuizmo::SetDrawlist((ImDrawList*)pointer);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_beginFrame(JNIEnv* env, jclass clazz) {


//@line:73

        ImGuizmo::BeginFrame();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nDecomposeMatrixToComponents(JNIEnv* env, jclass clazz, jfloatArray obj_matrix, jfloatArray obj_translation, jfloatArray obj_rotation, jfloatArray obj_scale) {
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);
	float* translation = (float*)env->GetPrimitiveArrayCritical(obj_translation, 0);
	float* rotation = (float*)env->GetPrimitiveArrayCritical(obj_rotation, 0);
	float* scale = (float*)env->GetPrimitiveArrayCritical(obj_scale, 0);


//@line:77

        ImGuizmo::DecomposeMatrixToComponents(matrix, translation, rotation, scale);
    
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);
	env->ReleasePrimitiveArrayCritical(obj_translation, translation, 0);
	env->ReleasePrimitiveArrayCritical(obj_rotation, rotation, 0);
	env->ReleasePrimitiveArrayCritical(obj_scale, scale, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nRecomposeMatrixFromComponents(JNIEnv* env, jclass clazz, jfloatArray obj_matrix, jfloatArray obj_translation, jfloatArray obj_rotation, jfloatArray obj_scale) {
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);
	float* translation = (float*)env->GetPrimitiveArrayCritical(obj_translation, 0);
	float* rotation = (float*)env->GetPrimitiveArrayCritical(obj_rotation, 0);
	float* scale = (float*)env->GetPrimitiveArrayCritical(obj_scale, 0);


//@line:96

        ImGuizmo::RecomposeMatrixFromComponents(translation, rotation, scale, matrix);
    
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);
	env->ReleasePrimitiveArrayCritical(obj_translation, translation, 0);
	env->ReleasePrimitiveArrayCritical(obj_rotation, rotation, 0);
	env->ReleasePrimitiveArrayCritical(obj_scale, scale, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nSetRect(JNIEnv* env, jclass clazz, jfloat x, jfloat y, jfloat width, jfloat height) {


//@line:115

        ImGuizmo::SetRect(x, y, width, height);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nSetOrthographic(JNIEnv* env, jclass clazz, jboolean ortho) {


//@line:131

        ImGuizmo::SetOrthographic(ortho);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nDrawCubes(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloatArray obj_projection, jfloatArray obj_matrices, jint matrixCount) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* projection = (float*)env->GetPrimitiveArrayCritical(obj_projection, 0);
	float* matrices = (float*)env->GetPrimitiveArrayCritical(obj_matrices, 0);


//@line:142

        ImGuizmo::DrawCubes(view, projection, matrices, matrixCount);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_projection, projection, 0);
	env->ReleasePrimitiveArrayCritical(obj_matrices, matrices, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nDrawGrid(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloatArray obj_projection, jfloatArray obj_matrix, jint gridSize) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* projection = (float*)env->GetPrimitiveArrayCritical(obj_projection, 0);
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);


//@line:166

        ImGuizmo::DrawGrid(view, projection, matrix, gridSize);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_projection, projection, 0);
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nManipulate___3F_3FII_3F(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloatArray obj_projection, jint operation, jint mode, jfloatArray obj_matrix) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* projection = (float*)env->GetPrimitiveArrayCritical(obj_projection, 0);
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);


//@line:182

        ImGuizmo::Manipulate(view, projection, (ImGuizmo::OPERATION) operation, (ImGuizmo::MODE) mode, matrix);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_projection, projection, 0);
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nManipulate___3F_3FII_3F_3F(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloatArray obj_projection, jint operation, jint mode, jfloatArray obj_matrix, jfloatArray obj_snap) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* projection = (float*)env->GetPrimitiveArrayCritical(obj_projection, 0);
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);
	float* snap = (float*)env->GetPrimitiveArrayCritical(obj_snap, 0);


//@line:186

        ImGuizmo::Manipulate(view, projection, (ImGuizmo::OPERATION) operation, (ImGuizmo::MODE) mode, matrix, NULL, snap);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_projection, projection, 0);
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);
	env->ReleasePrimitiveArrayCritical(obj_snap, snap, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nManipulate___3F_3FII_3F_3F_3F(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloatArray obj_projection, jint operation, jint mode, jfloatArray obj_matrix, jfloatArray obj_snap, jfloatArray obj_bounds) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* projection = (float*)env->GetPrimitiveArrayCritical(obj_projection, 0);
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);
	float* snap = (float*)env->GetPrimitiveArrayCritical(obj_snap, 0);
	float* bounds = (float*)env->GetPrimitiveArrayCritical(obj_bounds, 0);


//@line:190

        ImGuizmo::Manipulate(view, projection, (ImGuizmo::OPERATION) operation, (ImGuizmo::MODE) mode, matrix, NULL, snap, bounds, NULL);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_projection, projection, 0);
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);
	env->ReleasePrimitiveArrayCritical(obj_snap, snap, 0);
	env->ReleasePrimitiveArrayCritical(obj_bounds, bounds, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nManipulate___3F_3FII_3F_3F_3F_3F(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloatArray obj_projection, jint operation, jint mode, jfloatArray obj_matrix, jfloatArray obj_snap, jfloatArray obj_bounds, jfloatArray obj_boundsSnap) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* projection = (float*)env->GetPrimitiveArrayCritical(obj_projection, 0);
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);
	float* snap = (float*)env->GetPrimitiveArrayCritical(obj_snap, 0);
	float* bounds = (float*)env->GetPrimitiveArrayCritical(obj_bounds, 0);
	float* boundsSnap = (float*)env->GetPrimitiveArrayCritical(obj_boundsSnap, 0);


//@line:194

        ImGuizmo::Manipulate(view, projection, (ImGuizmo::OPERATION) operation, (ImGuizmo::MODE) mode, matrix, NULL, snap, bounds, boundsSnap);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_projection, projection, 0);
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);
	env->ReleasePrimitiveArrayCritical(obj_snap, snap, 0);
	env->ReleasePrimitiveArrayCritical(obj_bounds, bounds, 0);
	env->ReleasePrimitiveArrayCritical(obj_boundsSnap, boundsSnap, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nManipulate___3F_3FII_3F_3F_3F_3F_3F(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloatArray obj_projection, jint operation, jint mode, jfloatArray obj_matrix, jfloatArray obj_deltaMatrix, jfloatArray obj_snap, jfloatArray obj_bounds, jfloatArray obj_boundsSnap) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* projection = (float*)env->GetPrimitiveArrayCritical(obj_projection, 0);
	float* matrix = (float*)env->GetPrimitiveArrayCritical(obj_matrix, 0);
	float* deltaMatrix = (float*)env->GetPrimitiveArrayCritical(obj_deltaMatrix, 0);
	float* snap = (float*)env->GetPrimitiveArrayCritical(obj_snap, 0);
	float* bounds = (float*)env->GetPrimitiveArrayCritical(obj_bounds, 0);
	float* boundsSnap = (float*)env->GetPrimitiveArrayCritical(obj_boundsSnap, 0);


//@line:198

        ImGuizmo::Manipulate(view, projection, (ImGuizmo::OPERATION) operation, (ImGuizmo::MODE) mode, matrix, deltaMatrix, snap, bounds, boundsSnap);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_projection, projection, 0);
	env->ReleasePrimitiveArrayCritical(obj_matrix, matrix, 0);
	env->ReleasePrimitiveArrayCritical(obj_deltaMatrix, deltaMatrix, 0);
	env->ReleasePrimitiveArrayCritical(obj_snap, snap, 0);
	env->ReleasePrimitiveArrayCritical(obj_bounds, bounds, 0);
	env->ReleasePrimitiveArrayCritical(obj_boundsSnap, boundsSnap, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nViewManipulate(JNIEnv* env, jclass clazz, jfloatArray obj_view, jfloat length, jfloatArray obj_position, jfloatArray obj_size, jint color) {
	float* view = (float*)env->GetPrimitiveArrayCritical(obj_view, 0);
	float* position = (float*)env->GetPrimitiveArrayCritical(obj_position, 0);
	float* size = (float*)env->GetPrimitiveArrayCritical(obj_size, 0);


//@line:277

        ImGuizmo::ViewManipulate(view, length, ImVec2(position[0], position[1]), ImVec2(size[0], size[1]), (ImU32) color);
    
	env->ReleasePrimitiveArrayCritical(obj_view, view, 0);
	env->ReleasePrimitiveArrayCritical(obj_position, position, 0);
	env->ReleasePrimitiveArrayCritical(obj_size, size, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nSetId(JNIEnv* env, jclass clazz, jint id) {


//@line:294

        ImGuizmo::SetID(id);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nIsOver__I(JNIEnv* env, jclass clazz, jint operation) {


//@line:305

        return ImGuizmo::IsOver((ImGuizmo::OPERATION) operation);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nSetGizmoSizeClipSpace(JNIEnv* env, jclass clazz, jfloat value) {


//@line:319

        ImGuizmo::SetGizmoSizeClipSpace(value);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_imguizmo_ImGuizmo_nAllowAxisFlip(JNIEnv* env, jclass clazz, jboolean value) {


//@line:323

        ImGuizmo::AllowAxisFlip(value);
     

}


#include <imgui_extension_implot_ImPlotLimits.h>
#include <imgui_extension_implot_ImPlot.h>

//@line:24

        #include "_common.h"
        #include "_implot.h"

     JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nCreateContext(JNIEnv* env, jclass clazz) {


//@line:42

        return (intptr_t)ImPlot::CreateContext();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nDestroyContext(JNIEnv* env, jclass clazz, jlong ctx) {


//@line:53

        ImPlot::DestroyContext((ImPlotContext*)ctx);
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nGetCurrentContext(JNIEnv* env, jclass clazz) {


//@line:65

        return (intptr_t)ImPlot::GetCurrentContext();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nSetCurrentContext(JNIEnv* env, jclass clazz, jlong ctx) {


//@line:76

        ImPlot::SetCurrentContext((ImPlotContext*)ctx);
    

}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_beginPlot__Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_titleID, char* titleID) {

//@line:100

        return ImPlot::BeginPlot(titleID);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginPlot__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_titleID) {
	char* titleID = (char*)env->GetStringUTFChars(obj_titleID, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_beginPlot__Ljava_lang_String_2(env, clazz, obj_titleID, titleID);

	env->ReleaseStringUTFChars(obj_titleID, titleID);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_beginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel, char* titleID, char* xLabel, char* yLabel) {

//@line:121

        return ImPlot::BeginPlot(titleID, xLabel, yLabel);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel) {
	char* titleID = (char*)env->GetStringUTFChars(obj_titleID, 0);
	char* xLabel = (char*)env->GetStringUTFChars(obj_xLabel, 0);
	char* yLabel = (char*)env->GetStringUTFChars(obj_yLabel, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_beginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2(env, clazz, obj_titleID, obj_xLabel, obj_yLabel, titleID, xLabel, yLabel);

	env->ReleaseStringUTFChars(obj_titleID, titleID);
	env->ReleaseStringUTFChars(obj_xLabel, xLabel);
	env->ReleaseStringUTFChars(obj_yLabel, yLabel);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FF
(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel, jfloat x, jfloat y, char* titleID, char* xLabel, char* yLabel) {

//@line:149

        return ImPlot::BeginPlot(titleID, xLabel, yLabel, ImVec2(x, y));
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FF(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel, jfloat x, jfloat y) {
	char* titleID = (char*)env->GetStringUTFChars(obj_titleID, 0);
	char* xLabel = (char*)env->GetStringUTFChars(obj_xLabel, 0);
	char* yLabel = (char*)env->GetStringUTFChars(obj_yLabel, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FF(env, clazz, obj_titleID, obj_xLabel, obj_yLabel, x, y, titleID, xLabel, yLabel);

	env->ReleaseStringUTFChars(obj_titleID, titleID);
	env->ReleaseStringUTFChars(obj_xLabel, xLabel);
	env->ReleaseStringUTFChars(obj_yLabel, yLabel);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FFIII
(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel, jfloat x, jfloat y, jint flags, jint xFlags, jint yFlags, char* titleID, char* xLabel, char* yLabel) {

//@line:178

        return ImPlot::BeginPlot(titleID, xLabel, yLabel, ImVec2(x, y), flags, xFlags, yFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FFIII(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel, jfloat x, jfloat y, jint flags, jint xFlags, jint yFlags) {
	char* titleID = (char*)env->GetStringUTFChars(obj_titleID, 0);
	char* xLabel = (char*)env->GetStringUTFChars(obj_xLabel, 0);
	char* yLabel = (char*)env->GetStringUTFChars(obj_yLabel, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FFIII(env, clazz, obj_titleID, obj_xLabel, obj_yLabel, x, y, flags, xFlags, yFlags, titleID, xLabel, yLabel);

	env->ReleaseStringUTFChars(obj_titleID, titleID);
	env->ReleaseStringUTFChars(obj_xLabel, xLabel);
	env->ReleaseStringUTFChars(obj_yLabel, yLabel);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FFIIIIILjava_lang_String_2Ljava_lang_String_2
(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel, jfloat x, jfloat y, jint flags, jint xFlags, jint yFlags, jint y2Flags, jint y3Flags, jstring obj_y2Label, jstring obj_y3Label, char* titleID, char* xLabel, char* yLabel, char* y2Label, char* y3Label) {

//@line:229

        return ImPlot::BeginPlot(titleID,
                                 xLabel,
                                 yLabel,
                                 ImVec2(x, y),
                                 flags,
                                 xFlags,
                                 yFlags,
                                 y2Flags,
                                 y3Flags,
                                 y2Label,
                                 y3Label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FFIIIIILjava_lang_String_2Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_titleID, jstring obj_xLabel, jstring obj_yLabel, jfloat x, jfloat y, jint flags, jint xFlags, jint yFlags, jint y2Flags, jint y3Flags, jstring obj_y2Label, jstring obj_y3Label) {
	char* titleID = (char*)env->GetStringUTFChars(obj_titleID, 0);
	char* xLabel = (char*)env->GetStringUTFChars(obj_xLabel, 0);
	char* yLabel = (char*)env->GetStringUTFChars(obj_yLabel, 0);
	char* y2Label = (char*)env->GetStringUTFChars(obj_y2Label, 0);
	char* y3Label = (char*)env->GetStringUTFChars(obj_y3Label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nBeginPlot__Ljava_lang_String_2Ljava_lang_String_2Ljava_lang_String_2FFIIIIILjava_lang_String_2Ljava_lang_String_2(env, clazz, obj_titleID, obj_xLabel, obj_yLabel, x, y, flags, xFlags, yFlags, y2Flags, y3Flags, obj_y2Label, obj_y3Label, titleID, xLabel, yLabel, y2Label, y3Label);

	env->ReleaseStringUTFChars(obj_titleID, titleID);
	env->ReleaseStringUTFChars(obj_xLabel, xLabel);
	env->ReleaseStringUTFChars(obj_yLabel, yLabel);
	env->ReleaseStringUTFChars(obj_y2Label, y2Label);
	env->ReleaseStringUTFChars(obj_y3Label, y3Label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_endPlot(JNIEnv* env, jclass clazz) {


//@line:247

        ImPlot::EndPlot();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotLine(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);


//@line:311

        ImPlot::PlotLine(labelID, xs, ys, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotScatter(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);


//@line:339

        ImPlot::PlotScatter(labelID, xs, ys, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotStairs(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);


//@line:370

        ImPlot::PlotStairs(labelID, xs, ys, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotShaded__Ljava_lang_String_2_3D_3DIII(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size, jint yRef, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);


//@line:422

        ImPlot::PlotShaded(labelID, xs, ys, size, yRef, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotShaded__Ljava_lang_String_2_3D_3D_3DII(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys1, jdoubleArray obj_ys2, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys1 = (double*)env->GetPrimitiveArrayCritical(obj_ys1, 0);
	double* ys2 = (double*)env->GetPrimitiveArrayCritical(obj_ys2, 0);


//@line:433

        ImPlot::PlotShaded(labelID, xs, ys1, ys2, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys1, ys1, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys2, ys2, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotBars(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size, jfloat width, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);


//@line:475

        ImPlot::PlotBars(labelID, xs, ys, size, width, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotBarsH(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size, jfloat height, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);


//@line:517

        ImPlot::PlotBarsH(labelID, xs, ys, size, height, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotErrorBars(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jdoubleArray obj_err, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);
	double* err = (double*)env->GetPrimitiveArrayCritical(obj_err, 0);


//@line:550

        ImPlot::PlotErrorBars(labelID, xs, ys, err, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleasePrimitiveArrayCritical(obj_err, err, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotErrorBarsH(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jdoubleArray obj_err, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);
	double* err = (double*)env->GetPrimitiveArrayCritical(obj_err, 0);


//@line:583

        ImPlot::PlotErrorBarsH(labelID, xs, ys, err, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleasePrimitiveArrayCritical(obj_err, err, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotStems(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_values, jint size, jint yRef, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* values = (double*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:615

        ImPlot::PlotStems(labelID, values, size, yRef, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotVLines(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_values, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* values = (double*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:647

        ImPlot::PlotVLines(labelID, values, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotHLines(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_values, jint size, jint offset) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* values = (double*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:679

        ImPlot::PlotHLines(labelID, values, size, offset);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotPieChart(JNIEnv* env, jclass clazz, jstring obj_labelIDsSs, jint strLen, jdoubleArray obj_values, jint size, jdouble x, jdouble y, jdouble radius) {
	char* labelIDsSs = (char*)env->GetStringUTFChars(obj_labelIDsSs, 0);
	double* values = (double*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:721

        char** labelIDs = new char*[size];

        for (int pos = 0; pos < size; pos++) {
            char* str = new char[strLen + 1];
            char* str_i = str;

            while (*labelIDsSs != '\n' && *labelIDsSs != '\0') {
                *str = *labelIDsSs;
                labelIDsSs++;
                str++;
            }
            labelIDsSs++; //move past \n

            labelIDs[pos] = str_i;
        }

        ImPlot::PlotPieChart(labelIDs, values, size, x, y, radius);

        for (int i = 0; i < size; i++) {
            delete labelIDs[i];
        }
        delete[] labelIDs;
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_labelIDsSs, labelIDsSs);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotHeatmap(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_values, jint rows, jint cols) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* values = (double*)env->GetPrimitiveArrayCritical(obj_values, 0);


//@line:771

        ImPlot::PlotHeatmap(labelID, values, rows, cols);
    
	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

static inline jdouble wrapped_Java_imgui_extension_implot_ImPlot_nPlotHistogram
(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_values, jint size, char* labelID, double* values) {

//@line:801

        return ImPlot::PlotHistogram(labelID, values, size);
    
}

JNIEXPORT jdouble JNICALL Java_imgui_extension_implot_ImPlot_nPlotHistogram(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_values, jint size) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* values = (double*)env->GetPrimitiveArrayCritical(obj_values, 0);

	jdouble JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nPlotHistogram(env, clazz, obj_labelID, obj_values, size, labelID, values);

	env->ReleasePrimitiveArrayCritical(obj_values, values, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

	return JNI_returnValue;
}

static inline jdouble wrapped_Java_imgui_extension_implot_ImPlot_nPlotHistogram2D
(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size, char* labelID, double* xs, double* ys) {

//@line:824

        return ImPlot::PlotHistogram2D(labelID, xs, ys, size);
    
}

JNIEXPORT jdouble JNICALL Java_imgui_extension_implot_ImPlot_nPlotHistogram2D(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);

	jdouble JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nPlotHistogram2D(env, clazz, obj_labelID, obj_xs, obj_ys, size, labelID, xs, ys);

	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotDigital(JNIEnv* env, jclass clazz, jstring obj_labelID, jdoubleArray obj_xs, jdoubleArray obj_ys, jint size) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);
	double* xs = (double*)env->GetPrimitiveArrayCritical(obj_xs, 0);
	double* ys = (double*)env->GetPrimitiveArrayCritical(obj_ys, 0);


//@line:852

        ImPlot::PlotDigital(labelID, xs, ys, size);
    
	env->ReleasePrimitiveArrayCritical(obj_xs, xs, 0);
	env->ReleasePrimitiveArrayCritical(obj_ys, ys, 0);
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_plotText(JNIEnv* env, jclass clazz, jstring obj_text, jdouble x, jdouble y, jboolean vertical) {
	char* text = (char*)env->GetStringUTFChars(obj_text, 0);


//@line:870

        ImPlot::PlotText(text, x, y, vertical);
    
	env->ReleaseStringUTFChars(obj_text, text);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_plotDummy(JNIEnv* env, jclass clazz, jstring obj_labelID) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);


//@line:877

        ImPlot::PlotDummy(labelID);
    
	env->ReleaseStringUTFChars(obj_labelID, labelID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setNextPlotLimits(JNIEnv* env, jclass clazz, jdouble xmin, jdouble xmax, jdouble ymin, jdouble ymax, jint imguicond) {


//@line:889

        ImPlot::SetNextPlotLimits(xmin, xmax, ymin, ymax, imguicond);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setNextPlotLimitsX(JNIEnv* env, jclass clazz, jdouble xmin, jdouble xmax, jint imguicond) {


//@line:897

        ImPlot::SetNextPlotLimitsX(xmin, xmax, imguicond);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setNextPlotLimitsY(JNIEnv* env, jclass clazz, jdouble ymin, jdouble ymax, jint imguicond) {


//@line:905

        ImPlot::SetNextPlotLimitsY(ymin, ymax, imguicond);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nLinkNextPlotLimits(JNIEnv* env, jclass clazz, jdoubleArray obj_xmin, jdoubleArray obj_xmax, jdoubleArray obj_ymin, jdoubleArray obj_ymax, jdoubleArray obj_ymin2, jdoubleArray obj_ymax2, jdoubleArray obj_ymin3, jdoubleArray obj_ymax3) {
	double* xmin = (double*)env->GetPrimitiveArrayCritical(obj_xmin, 0);
	double* xmax = (double*)env->GetPrimitiveArrayCritical(obj_xmax, 0);
	double* ymin = (double*)env->GetPrimitiveArrayCritical(obj_ymin, 0);
	double* ymax = (double*)env->GetPrimitiveArrayCritical(obj_ymax, 0);
	double* ymin2 = (double*)env->GetPrimitiveArrayCritical(obj_ymin2, 0);
	double* ymax2 = (double*)env->GetPrimitiveArrayCritical(obj_ymax2, 0);
	double* ymin3 = (double*)env->GetPrimitiveArrayCritical(obj_ymin3, 0);
	double* ymax3 = (double*)env->GetPrimitiveArrayCritical(obj_ymax3, 0);


//@line:933

        ImPlot::LinkNextPlotLimits(&xmin[0], &xmax[0], &ymin[0], &ymax[0], &ymin2[0], &ymax2[0], &ymin3[0], &ymax3[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_xmin, xmin, 0);
	env->ReleasePrimitiveArrayCritical(obj_xmax, xmax, 0);
	env->ReleasePrimitiveArrayCritical(obj_ymin, ymin, 0);
	env->ReleasePrimitiveArrayCritical(obj_ymax, ymax, 0);
	env->ReleasePrimitiveArrayCritical(obj_ymin2, ymin2, 0);
	env->ReleasePrimitiveArrayCritical(obj_ymax2, ymax2, 0);
	env->ReleasePrimitiveArrayCritical(obj_ymin3, ymin3, 0);
	env->ReleasePrimitiveArrayCritical(obj_ymax3, ymax3, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_fitNextPlotAxes(JNIEnv* env, jclass clazz, jboolean x, jboolean y, jboolean y2, jboolean y3) {


//@line:957

        ImPlot::FitNextPlotAxes(x, y, y2, y3);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nSetNextPlotTicksX(JNIEnv* env, jclass clazz, jdouble xMin, jdouble xMax, jint nTicks, jstring obj_s1, jstring obj_s2, jstring obj_s3, jstring obj_s4, jboolean keepDefault) {
	char* s1 = (char*)env->GetStringUTFChars(obj_s1, 0);
	char* s2 = (char*)env->GetStringUTFChars(obj_s2, 0);
	char* s3 = (char*)env->GetStringUTFChars(obj_s3, 0);
	char* s4 = (char*)env->GetStringUTFChars(obj_s4, 0);


//@line:995

        char* strings[] = {s1, s2, s3, s4};
        ImPlot::SetNextPlotTicksX(xMin, xMax, nTicks, strings, keepDefault);
    
	env->ReleaseStringUTFChars(obj_s1, s1);
	env->ReleaseStringUTFChars(obj_s2, s2);
	env->ReleaseStringUTFChars(obj_s3, s3);
	env->ReleaseStringUTFChars(obj_s4, s4);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nSetNextPlotTicksY(JNIEnv* env, jclass clazz, jdouble xMin, jdouble xMax, jint nTicks, jstring obj_s1, jstring obj_s2, jstring obj_s3, jstring obj_s4, jboolean keepDefault, jint yAxis) {
	char* s1 = (char*)env->GetStringUTFChars(obj_s1, 0);
	char* s2 = (char*)env->GetStringUTFChars(obj_s2, 0);
	char* s3 = (char*)env->GetStringUTFChars(obj_s3, 0);
	char* s4 = (char*)env->GetStringUTFChars(obj_s4, 0);


//@line:1041

        char* strings[] = {s1, s2, s3, s4};
        ImPlot::SetNextPlotTicksY(xMin, xMax, nTicks, strings, keepDefault, yAxis);
    
	env->ReleaseStringUTFChars(obj_s1, s1);
	env->ReleaseStringUTFChars(obj_s2, s2);
	env->ReleaseStringUTFChars(obj_s3, s3);
	env->ReleaseStringUTFChars(obj_s4, s4);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setNextPlotFormatX(JNIEnv* env, jclass clazz, jstring obj_fmt) {
	char* fmt = (char*)env->GetStringUTFChars(obj_fmt, 0);


//@line:1050

        ImPlot::SetNextPlotFormatX(fmt);
    
	env->ReleaseStringUTFChars(obj_fmt, fmt);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setNextPlotFormatY(JNIEnv* env, jclass clazz, jstring obj_fmt, jint yAxis) {
	char* fmt = (char*)env->GetStringUTFChars(obj_fmt, 0);


//@line:1066

        ImPlot::SetNextPlotFormatY(fmt, yAxis);
     
	env->ReleaseStringUTFChars(obj_fmt, fmt);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setPlotYAxis(JNIEnv* env, jclass clazz, jint yAxis) {


//@line:1074

        ImPlot::SetPlotYAxis(yAxis);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_hideNextItem(JNIEnv* env, jclass clazz, jboolean hidden, jint imguiCond) {


//@line:1090

        ImPlot::HideNextItem(hidden, imguiCond);
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nPixelsToPlot(JNIEnv* env, jclass clazz, jfloat x, jfloat y, jint yAxis) {


//@line:1113

        ImPlotPoint* p = new ImPlotPoint(ImPlot::PixelsToPlot(x, y, yAxis));
        return (intptr_t)p;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPlotToPixels(JNIEnv* env, jclass clazz, jdouble x, jdouble y, jint yAxis, jobject vec) {


//@line:1136

        Jni::ImVec2Cpy(env, ImPlot::PlotToPixels(x, y, yAxis), vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_getPlotPos(JNIEnv* env, jclass clazz, jobject vec) {


//@line:1152

        Jni::ImVec2Cpy(env, ImPlot::GetPlotPos(), vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_getPlotSize(JNIEnv* env, jclass clazz, jobject vec) {


//@line:1170

        Jni::ImVec2Cpy(env, ImPlot::GetPlotSize(), vec);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_isPlotHovered(JNIEnv* env, jclass clazz) {


//@line:1178

        return ImPlot::IsPlotHovered();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_isPlotXAxisHovered(JNIEnv* env, jclass clazz) {


//@line:1186

        return ImPlot::IsPlotXAxisHovered();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_isPlotYAxisHovered(JNIEnv* env, jclass clazz, jint yAxis) {


//@line:1194

        return ImPlot::IsPlotYAxisHovered(yAxis);
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nGetPlotMousePos(JNIEnv* env, jclass clazz, jint yAxis) {


//@line:1208

        ImPlotPoint* p = new ImPlotPoint(ImPlot::GetPlotMousePos(yAxis));
        return (intptr_t)p;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nGetPlotLimits(JNIEnv* env, jclass clazz, jint yAxis) {


//@line:1223

        ImPlotLimits* p = new ImPlotLimits(ImPlot::GetPlotLimits(yAxis));
        return (intptr_t)p;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_isPlotSelected(JNIEnv* env, jclass clazz) {


//@line:1232

        return ImPlot::IsPlotSelected();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nGetPlotSelection(JNIEnv* env, jclass clazz, jint yAxis) {


//@line:1246

        ImPlotLimits* p = new ImPlotLimits(ImPlot::GetPlotSelection(yAxis));
        return (intptr_t)p;
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_isPlotQueried(JNIEnv* env, jclass clazz) {


//@line:1255

        return ImPlot::IsPlotQueried();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nGetPlotQuery(JNIEnv* env, jclass clazz, jint yAxis) {


//@line:1269

        ImPlotLimits* p = new ImPlotLimits(ImPlot::GetPlotQuery(yAxis));
        return (intptr_t)p;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nSetPlotQuery(JNIEnv* env, jclass clazz, jlong ptr, jint yAxis) {


//@line:1282

        ImPlotLimits* query = (ImPlotLimits*)ptr;
        ImPlot::SetPlotQuery(*query, yAxis);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nAnnotate(JNIEnv* env, jclass clazz, jdouble x, jdouble y, jfloat pixX, jfloat pixY, jfloat colA, jfloat colB, jfloat colC, jfloat colD, jstring obj_a, jstring obj_b, jstring obj_c, jstring obj_d, jstring obj_e) {
	char* a = (char*)env->GetStringUTFChars(obj_a, 0);
	char* b = (char*)env->GetStringUTFChars(obj_b, 0);
	char* c = (char*)env->GetStringUTFChars(obj_c, 0);
	char* d = (char*)env->GetStringUTFChars(obj_d, 0);
	char* e = (char*)env->GetStringUTFChars(obj_e, 0);


//@line:1311

        ImVec2 pixOffset(pixX, pixY);
        ImVec4 col(colA, colB, colC, colD);

        if (b == nullptr)
            ImPlot::Annotate(x, y, pixOffset, col, a);
        else if (b == nullptr)
            ImPlot::Annotate(x, y, pixOffset, col, a, b);
        else if (b == nullptr)
            ImPlot::Annotate(x, y, pixOffset, col, a, b, c);
        else if (b == nullptr)
            ImPlot::Annotate(x, y, pixOffset, col, a, b, c, d);
        else
            ImPlot::Annotate(x, y, pixOffset, col, a, b, c, d, e);
    
	env->ReleaseStringUTFChars(obj_a, a);
	env->ReleaseStringUTFChars(obj_b, b);
	env->ReleaseStringUTFChars(obj_c, c);
	env->ReleaseStringUTFChars(obj_d, d);
	env->ReleaseStringUTFChars(obj_e, e);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nAnnotateClamped(JNIEnv* env, jclass clazz, jdouble x, jdouble y, jfloat pixX, jfloat pixY, jfloat colA, jfloat colB, jfloat colC, jfloat colD, jstring obj_a, jstring obj_b, jstring obj_c, jstring obj_d, jstring obj_e) {
	char* a = (char*)env->GetStringUTFChars(obj_a, 0);
	char* b = (char*)env->GetStringUTFChars(obj_b, 0);
	char* c = (char*)env->GetStringUTFChars(obj_c, 0);
	char* d = (char*)env->GetStringUTFChars(obj_d, 0);
	char* e = (char*)env->GetStringUTFChars(obj_e, 0);


//@line:1347

        ImVec2 pixOffset(pixX, pixY);
        ImVec4 col(colA, colB, colC, colD);

        if (b == nullptr)
            ImPlot::AnnotateClamped(x, y, pixOffset, col, a);
        else if (b == nullptr)
            ImPlot::AnnotateClamped(x, y, pixOffset, col, a, b);
        else if (b == nullptr)
            ImPlot::AnnotateClamped(x, y, pixOffset, col, a, b, c);
        else if (b == nullptr)
            ImPlot::AnnotateClamped(x, y, pixOffset, col, a, b, c, d);
        else
            ImPlot::AnnotateClamped(x, y, pixOffset, col, a, b, c, d, e);
    
	env->ReleaseStringUTFChars(obj_a, a);
	env->ReleaseStringUTFChars(obj_b, b);
	env->ReleaseStringUTFChars(obj_c, c);
	env->ReleaseStringUTFChars(obj_d, d);
	env->ReleaseStringUTFChars(obj_e, e);

}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_nDragLineX
(JNIEnv* env, jclass clazz, jstring obj_id, jdouble xValue, jboolean showLabel, jfloat w, jfloat x, jfloat y, jfloat z, jfloat thickness, char* id) {

//@line:1374

        return ImPlot::DragLineX(id, &xValue, showLabel, ImVec4(w, x, y, z), thickness);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_nDragLineX(JNIEnv* env, jclass clazz, jstring obj_id, jdouble xValue, jboolean showLabel, jfloat w, jfloat x, jfloat y, jfloat z, jfloat thickness) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nDragLineX(env, clazz, obj_id, xValue, showLabel, w, x, y, z, thickness, id);

	env->ReleaseStringUTFChars(obj_id, id);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_nDragLineY
(JNIEnv* env, jclass clazz, jstring obj_id, jdouble yValue, jboolean showLabel, jfloat w, jfloat x, jfloat y, jfloat z, jfloat thickness, char* id) {

//@line:1385

        return ImPlot::DragLineY(id, &yValue, showLabel, ImVec4(w, x, y, z), thickness);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_nDragLineY(JNIEnv* env, jclass clazz, jstring obj_id, jdouble yValue, jboolean showLabel, jfloat w, jfloat x, jfloat y, jfloat z, jfloat thickness) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nDragLineY(env, clazz, obj_id, yValue, showLabel, w, x, y, z, thickness, id);

	env->ReleaseStringUTFChars(obj_id, id);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_nDragPoint
(JNIEnv* env, jclass clazz, jstring obj_id, jdouble xValue, jdouble yValue, jboolean showLabel, jfloat w, jfloat x, jfloat y, jfloat z, jfloat radius, char* id) {

//@line:1396

        return ImPlot::DragPoint(id, &xValue, &yValue, showLabel, ImVec4(w, x, y, z), radius);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_nDragPoint(JNIEnv* env, jclass clazz, jstring obj_id, jdouble xValue, jdouble yValue, jboolean showLabel, jfloat w, jfloat x, jfloat y, jfloat z, jfloat radius) {
	char* id = (char*)env->GetStringUTFChars(obj_id, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nDragPoint(env, clazz, obj_id, xValue, yValue, showLabel, w, x, y, z, radius, id);

	env->ReleaseStringUTFChars(obj_id, id);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setLegendLocation(JNIEnv* env, jclass clazz, jint location, jint orientation, jboolean outside) {


//@line:1408

        ImPlot::SetLegendLocation(location, orientation, outside);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_setMousePosLocation(JNIEnv* env, jclass clazz, jint location) {


//@line:1415

        ImPlot::SetMousePosLocation(location);
    

}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_isLegendEntryHovered
(JNIEnv* env, jclass clazz, jstring obj_labelID, char* labelID) {

//@line:1422

        return ImPlot::IsLegendEntryHovered(labelID);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_isLegendEntryHovered(JNIEnv* env, jclass clazz, jstring obj_labelID) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_isLegendEntryHovered(env, clazz, obj_labelID, labelID);

	env->ReleaseStringUTFChars(obj_labelID, labelID);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_beginLegendPopup
(JNIEnv* env, jclass clazz, jstring obj_labelID, jint mouseButton, char* labelID) {

//@line:1436

        return ImPlot::BeginLegendPopup(labelID, mouseButton);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginLegendPopup(JNIEnv* env, jclass clazz, jstring obj_labelID, jint mouseButton) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_beginLegendPopup(env, clazz, obj_labelID, mouseButton, labelID);

	env->ReleaseStringUTFChars(obj_labelID, labelID);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_endLegendPopup(JNIEnv* env, jclass clazz) {


//@line:1443

        ImPlot::EndLegendPopup();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropTarget(JNIEnv* env, jclass clazz) {


//@line:1454

        return ImPlot::BeginDragDropTarget();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropTargetX(JNIEnv* env, jclass clazz) {


//@line:1461

        return ImPlot::BeginDragDropTarget();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropTargetY(JNIEnv* env, jclass clazz, jint yAxis) {


//@line:1468

        return ImPlot::BeginDragDropTargetY(yAxis);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropTargetLegend(JNIEnv* env, jclass clazz) {


//@line:1475

        return ImPlot::BeginDragDropTargetLegend();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_endDragDropTarget(JNIEnv* env, jclass clazz) {


//@line:1482

        ImPlot::EndDragDropTarget();
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropSource(JNIEnv* env, jclass clazz, jint keyMods, jint dragDropFlags) {


//@line:1489

        return ImPlot::BeginDragDropSource(keyMods, dragDropFlags);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropSourceX(JNIEnv* env, jclass clazz, jint keyMods, jint dragDropFlags) {


//@line:1496

        return ImPlot::BeginDragDropSourceX(keyMods, dragDropFlags);
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropSourceY(JNIEnv* env, jclass clazz, jint yAxis, jint keyMods, jint dragDropFlags) {


//@line:1503

        return ImPlot::BeginDragDropSourceY(yAxis, keyMods, dragDropFlags);
    

}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_beginDragDropSourceItem
(JNIEnv* env, jclass clazz, jstring obj_labelID, jint dragDropFlags, char* labelID) {

//@line:1510

        return ImPlot::BeginDragDropSourceItem(labelID, dragDropFlags);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_beginDragDropSourceItem(JNIEnv* env, jclass clazz, jstring obj_labelID, jint dragDropFlags) {
	char* labelID = (char*)env->GetStringUTFChars(obj_labelID, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_beginDragDropSourceItem(env, clazz, obj_labelID, dragDropFlags, labelID);

	env->ReleaseStringUTFChars(obj_labelID, labelID);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_endDragDropSource(JNIEnv* env, jclass clazz) {


//@line:1517

        ImPlot::EndDragDropSource();
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nGetStyle(JNIEnv* env, jclass clazz) {


//@line:1533

        return (intptr_t)&ImPlot::GetStyle();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_styleColorsAuto(JNIEnv* env, jclass clazz) {


//@line:1540

        ImPlot::StyleColorsAuto();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_styleColorsClassic(JNIEnv* env, jclass clazz) {


//@line:1547

        ImPlot::StyleColorsClassic();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_styleColorsDark(JNIEnv* env, jclass clazz) {


//@line:1554

        ImPlot::StyleColorsDark();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_styleColorsLight(JNIEnv* env, jclass clazz) {


//@line:1561

        ImPlot::StyleColorsLight();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_pushStyleColor(JNIEnv* env, jclass clazz, jint idx, jlong col) {


//@line:1568

        ImPlot::PushStyleColor(idx, col);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPushStyleColor(JNIEnv* env, jclass clazz, jint idx, jfloat w, jfloat x, jfloat y, jfloat z) {


//@line:1579

        ImPlot::PushStyleColor(idx, ImVec4(w, x, y, z));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_popStyleColor(JNIEnv* env, jclass clazz, jint count) {


//@line:1587

        ImPlot::PopStyleColor(count);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_pushStyleVar__IF(JNIEnv* env, jclass clazz, jint idx, jfloat val) {


//@line:1594

        ImPlot::PushStyleVar(idx, val);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_pushStyleVar__II(JNIEnv* env, jclass clazz, jint idx, jint val) {


//@line:1601

        ImPlot::PushStyleVar(idx, (int)val);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nPushStyleVar(JNIEnv* env, jclass clazz, jint idx, jfloat x, jfloat y) {


//@line:1612

        ImPlot::PushStyleVar(idx, ImVec2(x, y));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_popStyleVar(JNIEnv* env, jclass clazz, jint count) {


//@line:1626

        ImPlot::PopStyleVar(count);
    

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlot_nGetLastItemColorS(JNIEnv* env, jclass clazz, jint selection) {


//@line:1637

        if (selection == 0)
            return ImPlot::GetLastItemColor().w;
        else if (selection == 1)
            return ImPlot::GetLastItemColor().x;
        else if (selection == 2)
            return ImPlot::GetLastItemColor().y;
        else
            return ImPlot::GetLastItemColor().z;
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_implot_ImPlot_getStyleColorName(JNIEnv* env, jclass clazz, jint idx) {


//@line:1651

        return env->NewStringUTF(ImPlot::GetStyleColorName(idx));
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_implot_ImPlot_getMarkerName(JNIEnv* env, jclass clazz, jint idx) {


//@line:1658

        return env->NewStringUTF(ImPlot::GetMarkerName(idx));
    

}

static inline jint wrapped_Java_imgui_extension_implot_ImPlot_nAddColormap
(JNIEnv* env, jclass clazz, jstring obj_name, jfloatArray obj_w, jfloatArray obj_x, jfloatArray obj_y, jfloatArray obj_z, jint count, char* name, float* w, float* x, float* y, float* z) {

//@line:1687

        ImVec4* cols = new ImVec4[count];
        for (int i = 0; i < count; i++) {
            cols[i] = ImVec4(w[i], x[i], y[i], z[i]);
        }

        return ImPlot::AddColormap(name, cols, count);
    
}

JNIEXPORT jint JNICALL Java_imgui_extension_implot_ImPlot_nAddColormap(JNIEnv* env, jclass clazz, jstring obj_name, jfloatArray obj_w, jfloatArray obj_x, jfloatArray obj_y, jfloatArray obj_z, jint count) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);
	float* w = (float*)env->GetPrimitiveArrayCritical(obj_w, 0);
	float* x = (float*)env->GetPrimitiveArrayCritical(obj_x, 0);
	float* y = (float*)env->GetPrimitiveArrayCritical(obj_y, 0);
	float* z = (float*)env->GetPrimitiveArrayCritical(obj_z, 0);

	jint JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_nAddColormap(env, clazz, obj_name, obj_w, obj_x, obj_y, obj_z, count, name, w, x, y, z);

	env->ReleasePrimitiveArrayCritical(obj_w, w, 0);
	env->ReleasePrimitiveArrayCritical(obj_x, x, 0);
	env->ReleasePrimitiveArrayCritical(obj_y, y, 0);
	env->ReleasePrimitiveArrayCritical(obj_z, z, 0);
	env->ReleaseStringUTFChars(obj_name, name);

	return JNI_returnValue;
}

JNIEXPORT jint JNICALL Java_imgui_extension_implot_ImPlot_getColormapCount(JNIEnv* env, jclass clazz) {


//@line:1699

        return ImPlot::GetColormapCount();
    

}

JNIEXPORT jstring JNICALL Java_imgui_extension_implot_ImPlot_getColormapName(JNIEnv* env, jclass clazz, jint cmap) {


//@line:1706

        return env->NewStringUTF(ImPlot::GetColormapName(cmap));
    

}

static inline jint wrapped_Java_imgui_extension_implot_ImPlot_getColormapIndex
(JNIEnv* env, jclass clazz, jstring obj_name, char* name) {

//@line:1713

        return ImPlot::GetColormapIndex(name);
    
}

JNIEXPORT jint JNICALL Java_imgui_extension_implot_ImPlot_getColormapIndex(JNIEnv* env, jclass clazz, jstring obj_name) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);

	jint JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_getColormapIndex(env, clazz, obj_name, name);

	env->ReleaseStringUTFChars(obj_name, name);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_pushColormap__I(JNIEnv* env, jclass clazz, jint cmap) {


//@line:1720

        ImPlot::PushColormap(cmap);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_pushColormap__Ljava_lang_String_2(JNIEnv* env, jclass clazz, jstring obj_name) {
	char* name = (char*)env->GetStringUTFChars(obj_name, 0);


//@line:1727

        ImPlot::PushColormap(name);
    
	env->ReleaseStringUTFChars(obj_name, name);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_popColormap(JNIEnv* env, jclass clazz, jint count) {


//@line:1741

        ImPlot::PopColormap(count);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nNextColormapColor(JNIEnv* env, jclass clazz, jobject vec) {


//@line:1755

        Jni::ImVec4Cpy(env, ImPlot::NextColormapColor(), vec);
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_implot_ImPlot_getColormapSize(JNIEnv* env, jclass clazz, jint cmap) {


//@line:1762

        return ImPlot::GetColormapSize(cmap);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nGetColormapColor(JNIEnv* env, jclass clazz, jint idx, jint cmap, jobject vec) {


//@line:1775

        Jni::ImVec4Cpy(env, ImPlot::GetColormapColor(idx, cmap), vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nSampleColormap(JNIEnv* env, jclass clazz, jfloat t, jint cmap, jobject vec) {


//@line:1788

        Jni::ImVec4Cpy(env, ImPlot::SampleColormap(t, cmap), vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_colormapScale(JNIEnv* env, jclass clazz, jstring obj_label, jdouble scaleMin, jdouble scaleMax, jint cmap) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);


//@line:1795

        ImPlot::ColormapScale(label, scaleMin, scaleMax, ImVec2(0,0), cmap);
    
	env->ReleaseStringUTFChars(obj_label, label);

}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_colormapSlider
(JNIEnv* env, jclass clazz, jstring obj_label, jfloat t, jint cmap, char* label) {

//@line:1802

        return ImPlot::ColormapSlider(label, &t, NULL, "", cmap);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_colormapSlider(JNIEnv* env, jclass clazz, jstring obj_label, jfloat t, jint cmap) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_colormapSlider(env, clazz, obj_label, t, cmap, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_colormapButton
(JNIEnv* env, jclass clazz, jstring obj_label, jint cmap, char* label) {

//@line:1809

        return ImPlot::ColormapButton(label, ImVec2(0,0), cmap);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_colormapButton(JNIEnv* env, jclass clazz, jstring obj_label, jint cmap) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_colormapButton(env, clazz, obj_label, cmap, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_bustColorCache(JNIEnv* env, jclass clazz, jstring obj_plotTableID) {
	char* plotTableID = (char*)env->GetStringUTFChars(obj_plotTableID, 0);


//@line:1835

        ImPlot::BustColorCache(plotTableID);
    
	env->ReleaseStringUTFChars(obj_plotTableID, plotTableID);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nItemIcon(JNIEnv* env, jclass clazz, jdouble a, jdouble b, jdouble c, jdouble d) {


//@line:1850

        ImPlot::ItemIcon(ImVec4(a, b, c, d));
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_colormapIcon(JNIEnv* env, jclass clazz, jint colorMap) {


//@line:1857

        ImPlot::ColormapIcon(colorMap);
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlot_nGetPlotDrawList(JNIEnv* env, jclass clazz) {


//@line:1869

        return (intptr_t)ImPlot::GetPlotDrawList();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_pushPlotClipRect(JNIEnv* env, jclass clazz, jfloat expand) {


//@line:1876

        ImPlot::PushPlotClipRect(expand);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_popPlotClipRect(JNIEnv* env, jclass clazz) {


//@line:1883

        ImPlot::PopPlotClipRect();
    

}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_showStyleSelector
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:1890

        return ImPlot::ShowStyleSelector(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_showStyleSelector(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_showStyleSelector(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

static inline jboolean wrapped_Java_imgui_extension_implot_ImPlot_showColormapSelector
(JNIEnv* env, jclass clazz, jstring obj_label, char* label) {

//@line:1897

        return ImPlot::ShowColormapSelector(label);
    
}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlot_showColormapSelector(JNIEnv* env, jclass clazz, jstring obj_label) {
	char* label = (char*)env->GetStringUTFChars(obj_label, 0);

	jboolean JNI_returnValue = wrapped_Java_imgui_extension_implot_ImPlot_showColormapSelector(env, clazz, obj_label, label);

	env->ReleaseStringUTFChars(obj_label, label);

	return JNI_returnValue;
}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_showStyleEditor(JNIEnv* env, jclass clazz) {


//@line:1904

        ImPlot::ShowStyleEditor(NULL);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_showUserGuide(JNIEnv* env, jclass clazz) {


//@line:1911

        ImPlot::ShowUserGuide();
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_showMetricsWindow(JNIEnv* env, jclass clazz) {


//@line:1918

        ImPlot::ShowMetricsWindow(NULL);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlot_nShowDemoWindow(JNIEnv* env, jclass clazz, jbooleanArray obj_pOpen) {
	bool* pOpen = (bool*)env->GetPrimitiveArrayCritical(obj_pOpen, 0);


//@line:1933

        ImPlot::ShowDemoWindow(&pOpen[0]);
    
	env->ReleasePrimitiveArrayCritical(obj_pOpen, pOpen, 0);

}


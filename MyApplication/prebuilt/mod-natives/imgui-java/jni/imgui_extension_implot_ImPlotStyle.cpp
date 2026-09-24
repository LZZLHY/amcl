#include <imgui_extension_implot_ImPlotStyle.h>

//@line:13

        #include "_common.h"
        #include "_implot.h"

        #define IMPLOT_STYLE ((ImPlotStyle*)STRUCT_PTR)
     JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getLineWeight(JNIEnv* env, jobject object) {


//@line:21

        return IMPLOT_STYLE->LineWeight;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setLineWeight(JNIEnv* env, jobject object, jfloat lineWeight) {


//@line:25

        IMPLOT_STYLE->LineWeight = lineWeight;
    

}

JNIEXPORT jint JNICALL Java_imgui_extension_implot_ImPlotStyle_getMarker(JNIEnv* env, jobject object) {


//@line:30

        return IMPLOT_STYLE->Marker;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setMarker(JNIEnv* env, jobject object, jfloat input) {


//@line:34

        IMPLOT_STYLE->Marker = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getMarkerSize(JNIEnv* env, jobject object) {


//@line:39

        return IMPLOT_STYLE->MarkerSize;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setMarkerSize(JNIEnv* env, jobject object, jfloat input) {


//@line:43

        IMPLOT_STYLE->MarkerSize = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getMarkerWeight(JNIEnv* env, jobject object) {


//@line:48

        return IMPLOT_STYLE->MarkerWeight;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setMarkerWeight(JNIEnv* env, jobject object, jfloat input) {


//@line:52

        IMPLOT_STYLE->MarkerWeight = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getFillAlpha(JNIEnv* env, jobject object) {


//@line:57

        return IMPLOT_STYLE->FillAlpha;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setFillAlpha(JNIEnv* env, jobject object, jfloat input) {


//@line:61

        IMPLOT_STYLE->FillAlpha = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getErrorBarSize(JNIEnv* env, jobject object) {


//@line:66

        return IMPLOT_STYLE->ErrorBarSize;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setErrorBarSize(JNIEnv* env, jobject object, jfloat input) {


//@line:70

        IMPLOT_STYLE->ErrorBarSize = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getErrorBarWeight(JNIEnv* env, jobject object) {


//@line:75

        return IMPLOT_STYLE->ErrorBarWeight;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setErrorBarWeight(JNIEnv* env, jobject object, jfloat input) {


//@line:79

        IMPLOT_STYLE->ErrorBarWeight = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getDigitalBitHeight(JNIEnv* env, jobject object) {


//@line:84

        return IMPLOT_STYLE->DigitalBitHeight;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setDigitalBitHeight(JNIEnv* env, jobject object, jfloat input) {


//@line:88

        IMPLOT_STYLE->DigitalBitHeight = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getDigitalBitGap(JNIEnv* env, jobject object) {


//@line:93

        return IMPLOT_STYLE->DigitalBitGap;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setDigitalBitGap(JNIEnv* env, jobject object, jfloat input) {


//@line:97

        IMPLOT_STYLE->DigitalBitGap = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getPlotBorderSize(JNIEnv* env, jobject object) {


//@line:102

        return IMPLOT_STYLE->PlotBorderSize;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setPlotBorderSize(JNIEnv* env, jobject object, jfloat input) {


//@line:106

        IMPLOT_STYLE->PlotBorderSize = input;
     

}

JNIEXPORT jfloat JNICALL Java_imgui_extension_implot_ImPlotStyle_getMinorAlpha(JNIEnv* env, jobject object) {


//@line:111

        return IMPLOT_STYLE->MinorAlpha;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setMinorAlpha(JNIEnv* env, jobject object, jfloat input) {


//@line:115

        IMPLOT_STYLE->MinorAlpha = input;
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetMajorTickLen(JNIEnv* env, jobject object, jobject vec) {


//@line:126

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->MajorTickLen, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetMajorTickLen(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:134

        IMPLOT_STYLE->MajorTickLen = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetMinorTickLen(JNIEnv* env, jobject object, jobject vec) {


//@line:145

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->MinorTickLen, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetMinorTickLen(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:153

        IMPLOT_STYLE->MinorTickLen = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetMajorTickSize(JNIEnv* env, jobject object, jobject vec) {


//@line:164

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->MajorTickSize, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetMajorTickSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:172

        IMPLOT_STYLE->MajorTickSize = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetMinorTickSize(JNIEnv* env, jobject object, jobject vec) {


//@line:183

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->MinorTickSize, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetMinorTickSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:191

        IMPLOT_STYLE->MinorTickSize = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetMajorGridSize(JNIEnv* env, jobject object, jobject vec) {


//@line:202

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->MajorGridSize, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetMajorGridSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:210

        IMPLOT_STYLE->MajorGridSize = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetMinorGridSize(JNIEnv* env, jobject object, jobject vec) {


//@line:221

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->MinorGridSize, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetMinorGridSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:229

        IMPLOT_STYLE->MinorGridSize = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetPlotPadding(JNIEnv* env, jobject object, jobject vec) {


//@line:240

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->PlotPadding, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetPlotPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:248

        IMPLOT_STYLE->PlotPadding = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetLabelPadding(JNIEnv* env, jobject object, jobject vec) {


//@line:259

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->LabelPadding, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetLabelPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:267

        IMPLOT_STYLE->LabelPadding = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetLegendPadding(JNIEnv* env, jobject object, jobject vec) {


//@line:278

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->LegendPadding, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetLegendPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:286

        IMPLOT_STYLE->LegendPadding = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetLegendInnerPadding(JNIEnv* env, jobject object, jobject vec) {


//@line:297

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->LegendInnerPadding, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetLegendInnerPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:305

        IMPLOT_STYLE->LegendInnerPadding = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetLegendSpacing(JNIEnv* env, jobject object, jobject vec) {


//@line:316

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->LegendSpacing, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetLegendSpacing(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:324

        IMPLOT_STYLE->LegendSpacing = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetMousePosPadding(JNIEnv* env, jobject object, jobject vec) {


//@line:335

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->MousePosPadding, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetMousePosPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:343

        IMPLOT_STYLE->MousePosPadding = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetAnnotationPadding(JNIEnv* env, jobject object, jobject vec) {


//@line:354

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->AnnotationPadding, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetAnnotationPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:362

        IMPLOT_STYLE->AnnotationPadding = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetFitPadding(JNIEnv* env, jobject object, jobject vec) {


//@line:373

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->FitPadding, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetFitPadding(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:381

        IMPLOT_STYLE->FitPadding = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetPlotDefaultSize(JNIEnv* env, jobject object, jobject vec) {


//@line:392

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->PlotDefaultSize, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetPlotDefaultSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:400

        IMPLOT_STYLE->PlotDefaultSize = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetPlotMinSize(JNIEnv* env, jobject object, jobject vec) {


//@line:411

        Jni::ImVec2Cpy(env, IMPLOT_STYLE->PlotMinSize, vec);
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetPlotMinSize(JNIEnv* env, jobject object, jfloat x, jfloat y) {


//@line:419

        IMPLOT_STYLE->PlotMinSize = ImVec2(x, y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nGetColors(JNIEnv* env, jobject object, jfloatArray obj_w, jfloatArray obj_x, jfloatArray obj_y, jfloatArray obj_z, jint count) {
	float* w = (float*)env->GetPrimitiveArrayCritical(obj_w, 0);
	float* x = (float*)env->GetPrimitiveArrayCritical(obj_x, 0);
	float* y = (float*)env->GetPrimitiveArrayCritical(obj_y, 0);
	float* z = (float*)env->GetPrimitiveArrayCritical(obj_z, 0);


//@line:439

        ImVec4* colors = IMPLOT_STYLE->Colors;

        for (int i = 0; i < count; i++) {
            w[i] = colors->w;
            x[i] = colors->x;
            y[i] = colors->y;
            z[i] = colors->z;

            colors++;
        }
    
	env->ReleasePrimitiveArrayCritical(obj_w, w, 0);
	env->ReleasePrimitiveArrayCritical(obj_x, x, 0);
	env->ReleasePrimitiveArrayCritical(obj_y, y, 0);
	env->ReleasePrimitiveArrayCritical(obj_z, z, 0);

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_nSetColors(JNIEnv* env, jobject object, jfloatArray obj_w, jfloatArray obj_x, jfloatArray obj_y, jfloatArray obj_z, jint count) {
	float* w = (float*)env->GetPrimitiveArrayCritical(obj_w, 0);
	float* x = (float*)env->GetPrimitiveArrayCritical(obj_x, 0);
	float* y = (float*)env->GetPrimitiveArrayCritical(obj_y, 0);
	float* z = (float*)env->GetPrimitiveArrayCritical(obj_z, 0);


//@line:468

        ImVec4* colors = IMPLOT_STYLE->Colors;

        for (int i = 0; i < count; i++) {
            colors->w = w[i];
            colors->x = x[i];
            colors->y = y[i];
            colors->z = z[i];

            colors++;
        }
     
	env->ReleasePrimitiveArrayCritical(obj_w, w, 0);
	env->ReleasePrimitiveArrayCritical(obj_x, x, 0);
	env->ReleasePrimitiveArrayCritical(obj_y, y, 0);
	env->ReleasePrimitiveArrayCritical(obj_z, z, 0);

}

JNIEXPORT jint JNICALL Java_imgui_extension_implot_ImPlotStyle_getColormap(JNIEnv* env, jobject object) {


//@line:482

        return IMPLOT_STYLE->Colormap;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setColormap(JNIEnv* env, jobject object, jint input) {


//@line:486

        IMPLOT_STYLE->Colormap = input;
     

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlotStyle_isAntiAliasedLines(JNIEnv* env, jobject object) {


//@line:491

        return IMPLOT_STYLE->AntiAliasedLines;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setAntiAliasedLines(JNIEnv* env, jobject object, jboolean input) {


//@line:495

        IMPLOT_STYLE->AntiAliasedLines = input;
     

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlotStyle_isUseLocalTime(JNIEnv* env, jobject object) {


//@line:500

        return IMPLOT_STYLE->UseLocalTime;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setUseLocalTime(JNIEnv* env, jobject object, jboolean input) {


//@line:504

        IMPLOT_STYLE->UseLocalTime = input;
     

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlotStyle_isUseISO8601(JNIEnv* env, jobject object) {


//@line:509

        return IMPLOT_STYLE->UseISO8601;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setUseISO8601(JNIEnv* env, jobject object, jboolean input) {


//@line:513

        IMPLOT_STYLE->UseISO8601 = input;
     

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlotStyle_isUse24HourClock(JNIEnv* env, jobject object) {


//@line:518

        return IMPLOT_STYLE->Use24HourClock;
    

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotStyle_setUse24HourClock(JNIEnv* env, jobject object, jboolean input) {


//@line:522

        IMPLOT_STYLE->Use24HourClock = input;
     

}


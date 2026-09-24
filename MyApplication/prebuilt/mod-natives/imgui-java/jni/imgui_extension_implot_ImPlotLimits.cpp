#include <imgui_extension_implot_ImPlotLimits.h>

//@line:20

        #include "_common.h"
        #include "_implot.h"

        #define IMPLOT_LIMITS ((ImPlotLimits*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotLimits_create__(JNIEnv* env, jobject object) {


//@line:28

        return (intptr_t)(new ImPlotLimits(0, 0, 0, 0));
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotLimits_create__DDDD(JNIEnv* env, jobject object, jdouble xMin, jdouble xMax, jdouble yMin, jdouble yMax) {


//@line:32

        return (intptr_t)(new ImPlotLimits(xMin, xMax, yMin, yMax));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlotLimits_contains(JNIEnv* env, jobject object, jdouble x, jdouble y) {


//@line:40

        return IMPLOT_LIMITS->Contains(x, y);
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotLimits_nMin(JNIEnv* env, jobject object) {


//@line:61

        ImPlotPoint* p = new ImPlotPoint(IMPLOT_LIMITS->Min());
        return (intptr_t)p;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotLimits_nMax(JNIEnv* env, jobject object) {


//@line:83

        ImPlotPoint* p = new ImPlotPoint(IMPLOT_LIMITS->Max());
        return (intptr_t)p;
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotLimits_nGetX(JNIEnv* env, jobject object, jlong ptr) {


//@line:92

        return (intptr_t)&(IMPLOT_LIMITS->X);
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotLimits_nGetY(JNIEnv* env, jobject object, jlong ptr) {


//@line:100

        return (intptr_t)&(IMPLOT_LIMITS->Y);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotLimits_nSetX(JNIEnv* env, jobject object, jlong valueptr) {


//@line:108

        IMPLOT_LIMITS->X = *((ImPlotRange*)valueptr);
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotLimits_nSetY(JNIEnv* env, jobject object, jlong valueptr) {


//@line:116

        IMPLOT_LIMITS->Y = *((ImPlotRange*)valueptr);
     

}


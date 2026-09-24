#include <imgui_extension_implot_ImPlotRange.h>

//@line:19

        #include "_common.h"
        #include "_implot.h"

        #define IMPLOT_RANGE ((ImPlotRange*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotRange_create__(JNIEnv* env, jobject object) {


//@line:27

        return (intptr_t)(new ImPlotRange(0, 0));
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotRange_create__DD(JNIEnv* env, jobject object, jdouble min, jdouble max) {


//@line:31

        return (intptr_t)(new ImPlotRange(min, max));
    

}

JNIEXPORT jboolean JNICALL Java_imgui_extension_implot_ImPlotRange_contains(JNIEnv* env, jobject object, jdouble value) {


//@line:35

        return IMPLOT_RANGE->Contains(value);
    

}

JNIEXPORT jdouble JNICALL Java_imgui_extension_implot_ImPlotRange_size(JNIEnv* env, jobject object) {


//@line:39

        return IMPLOT_RANGE->Size();
     

}

JNIEXPORT jdouble JNICALL Java_imgui_extension_implot_ImPlotRange_getMin(JNIEnv* env, jobject object) {


//@line:43

        return IMPLOT_RANGE->Min;
    

}

JNIEXPORT jdouble JNICALL Java_imgui_extension_implot_ImPlotRange_getMax(JNIEnv* env, jobject object) {


//@line:47

        return IMPLOT_RANGE->Max;
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotRange_setMin(JNIEnv* env, jobject object, jdouble min) {


//@line:51

        IMPLOT_RANGE->Min = min;
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotRange_nSetMax(JNIEnv* env, jobject object, jdouble max) {


//@line:55

        IMPLOT_RANGE->Max = max;
     

}


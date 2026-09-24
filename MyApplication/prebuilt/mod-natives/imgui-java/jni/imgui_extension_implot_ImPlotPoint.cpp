#include <imgui_extension_implot_ImPlotPoint.h>

//@line:24

        #include "_common.h"
        #include "_implot.h"

        #define IMPLOT_POINT ((ImPlotPoint*)STRUCT_PTR)
     JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotPoint_create__(JNIEnv* env, jobject object) {


//@line:32

        return (intptr_t)(new ImPlotPoint(0, 0));
    

}

JNIEXPORT jlong JNICALL Java_imgui_extension_implot_ImPlotPoint_create__DD(JNIEnv* env, jobject object, jdouble x, jdouble y) {


//@line:36

        return (intptr_t)(new ImPlotPoint(x, y));
    

}

JNIEXPORT jdouble JNICALL Java_imgui_extension_implot_ImPlotPoint_getX(JNIEnv* env, jobject object) {


//@line:40

        return IMPLOT_POINT->x;
    

}

JNIEXPORT jdouble JNICALL Java_imgui_extension_implot_ImPlotPoint_getY(JNIEnv* env, jobject object) {


//@line:44

        return IMPLOT_POINT->y;
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotPoint_setX(JNIEnv* env, jobject object, jdouble value) {


//@line:48

        IMPLOT_POINT->x = value;
     

}

JNIEXPORT void JNICALL Java_imgui_extension_implot_ImPlotPoint_setY(JNIEnv* env, jobject object, jdouble value) {


//@line:52

        IMPLOT_POINT->y = value;
     

}


#include <imgui_lwjgl3_glfw_ImGuiImplGlfwNative.h>

//@line:7

        #if defined(_WIN32)
            #include <windows.h>
        #endif
     JNIEXPORT void JNICALL Java_imgui_lwjgl3_glfw_ImGuiImplGlfwNative_win32hideFromTaskBar(JNIEnv* env, jclass clazz, jlong hwndPtr) {


//@line:21

        #if defined(_WIN32)
            HWND hwnd = (HWND)hwndPtr;
            LONG ex_style = ::GetWindowLong(hwnd, GWL_EXSTYLE);
            ex_style &= ~WS_EX_APPWINDOW;
            ex_style |= WS_EX_TOOLWINDOW;
            ::SetWindowLong(hwnd, GWL_EXSTYLE, ex_style);
        #endif
    

}


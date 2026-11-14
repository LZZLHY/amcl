// 编译真实光标入口，以最小窗口容器替代OHOS/EGL环境；验证句柄和所有权，
// 不把宿主结果称为系统光标外观、NativeWindow或完整GLFW线程资格。
#include "../../glfw/glfw_compat.h"
#include <cassert>
#include <climits>
#include <cstdio>
#include <mutex>
#include <vector>
#include <new>
#include <thread>

static bool failObject = false, failPixels = false;
// 仅宿主替换nothrow分配，分别模拟对象和像素OOM；成功仍用配对的标准new/delete。
void* operator new(std::size_t bytes, const std::nothrow_t&) noexcept {
    if (failObject) { failObject = false; return nullptr; }
    try { return ::operator new(bytes); } catch (...) { return nullptr; }
}
void* operator new[](std::size_t bytes, const std::nothrow_t&) noexcept {
    if (failPixels) { failPixels = false; return nullptr; }
    try { return ::operator new[](bytes); } catch (...) { return nullptr; }
}
struct GLFWwindow { GLFWcursor* cursor = nullptr; int cursorMode = GLFW_CURSOR_NORMAL; };
static std::recursive_mutex g_contextLifecycleMutex;
static std::vector<GLFWwindow*> g_windows;
static int g_initialized = 0, lastError = 0;
static bool reenterOnError = false;
void glfwOHOS_ReportError(int code, const char*) {
    lastError = code;
    if (reenterOnError) {
        reenterOnError = false;
        bool unlocked = false;
        std::thread other([&] { unlocked = g_contextLifecycleMutex.try_lock();
            if (unlocked) g_contextLifecycleMutex.unlock(); });
        other.join(); assert(unlocked);
        auto* nested = glfwCreateStandardCursor(GLFW_ARROW_CURSOR);
        assert(nested); glfwDestroyCursor(nested);
    }
}
#include "../../glfw/glfw_cursor.inc"

// 只替代窗口/输入/驱动退役边界，实际terminate的早退与清理顺序从生产源码提取。
static GLFWwindow* g_currentWindow = nullptr;
static GLFWwindow* g_threadCurrentContext = nullptr;
static void* g_typedInputHost = nullptr;
static int g_typedInputAdapter = 0;
static bool g_nativeEglContextCreated = true, retainWindow = false;
static int typedInputAdapterClose(int*) { return 0; }
namespace amcl::ohos { static void LeaveInteractiveRenderQoS(const char*) {} }
#define AMCL_EXTERNAL_LOG_E(...) ((void)0)
#define OH_LOG_INFO(...) ((void)0)
void glfwDestroyWindow(GLFWwindow* window) {
    if (retainWindow) return;
    g_windows.erase(std::remove(g_windows.begin(),g_windows.end(),window),g_windows.end());
    if (g_currentWindow == window) g_currentWindow = nullptr;
}
// @AMCL_GLFW_TERMINATE@

int main() {
    assert(glfwCreateStandardCursor(GLFW_ARROW_CURSOR) == nullptr && lastError == GLFW_NOT_INITIALIZED);
    g_initialized = 1;
    std::vector<GLFWcursor*> objects;
    for (int shape = GLFW_ARROW_CURSOR; shape <= GLFW_NOT_ALLOWED_CURSOR; ++shape) {
        auto* cursor = glfwCreateStandardCursor(shape);
        assert(cursor && cursor->shape == shape); objects.push_back(cursor);
    }
    auto* duplicate = glfwCreateStandardCursor(GLFW_ARROW_CURSOR);
    assert(duplicate && duplicate != objects[0]);
    reenterOnError = true;
    assert(glfwCreateStandardCursor(GLFW_ARROW_CURSOR - 1) == nullptr && lastError == GLFW_INVALID_ENUM);
    assert(glfwCreateStandardCursor(GLFW_NOT_ALLOWED_CURSOR + 1) == nullptr && lastError == GLFW_INVALID_ENUM);
    failObject = true;
    assert(glfwCreateStandardCursor(GLFW_ARROW_CURSOR) == nullptr && lastError == GLFW_OUT_OF_MEMORY);

    unsigned char pixels[16] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
    GLFWimage image{2,2,pixels};
    auto* custom = glfwCreateCursor(&image,1,0);
    assert(custom && custom->width == 2 && custom->height == 2 && custom->xhot == 1 && custom->yhot == 0);
    pixels[0] = 99; assert(custom->pixels[0] == 1 && custom->pixels[15] == 16);
    assert(!glfwCreateCursor(nullptr,0,0) && lastError == GLFW_INVALID_VALUE);
    assert(!glfwCreateCursor(&image,-1,0) && lastError == GLFW_INVALID_VALUE);
    assert(!glfwCreateCursor(&image,2,0) && lastError == GLFW_INVALID_VALUE);
    GLFWimage empty{0,2,pixels}, noPixels{2,2,nullptr}, overflow{INT_MAX,INT_MAX,pixels};
    assert(!glfwCreateCursor(&empty,0,0) && lastError == GLFW_INVALID_VALUE);
    assert(!glfwCreateCursor(&noPixels,0,0) && lastError == GLFW_INVALID_VALUE);
    assert(!glfwCreateCursor(&overflow,0,0) && lastError == GLFW_INVALID_VALUE);
    failObject = true; assert(!glfwCreateCursor(&image,0,0) && lastError == GLFW_OUT_OF_MEMORY);
    failPixels = true; assert(!glfwCreateCursor(&image,0,0) && lastError == GLFW_OUT_OF_MEMORY);

    GLFWwindow first, second, foreign;
    first.cursorMode = GLFW_CURSOR_DISABLED;
    g_windows = {&first,&second};
    glfwSetCursor(&first,custom); glfwSetCursor(&second,custom);
    assert(first.cursor == custom && second.cursor == custom && first.cursorMode == GLFW_CURSOR_DISABLED);
    glfwSetCursor(&first,nullptr); assert(!first.cursor && second.cursor == custom);
    glfwSetCursor(&first,custom); glfwDestroyCursor(custom);
    assert(!first.cursor && !second.cursor && first.cursorMode == GLFW_CURSOR_DISABLED);
    auto* invalid = reinterpret_cast<GLFWcursor*>(0x1234);
    glfwSetCursor(&first,invalid); assert(lastError == GLFW_INVALID_VALUE && !first.cursor);
    glfwSetCursor(&foreign,objects[0]); assert(lastError == GLFW_INVALID_VALUE && !foreign.cursor);
    glfwDestroyCursor(invalid); assert(lastError == GLFW_INVALID_VALUE);
    lastError = 0; glfwDestroyCursor(nullptr); assert(lastError == 0);

    // 窗口退休只移除窗口本身；共享cursor仍可交给另一个活窗口。
    glfwSetCursor(&first,objects[0]); glfwSetCursor(&second,objects[0]);
    g_windows.erase(g_windows.begin());
    glfwDestroyCursor(objects[0]); assert(!second.cursor);
    // 真实terminate在窗口拒退时必须保留光标；成功后必须回收所有未显式destroy的对象。
    glfwSetCursor(&second,duplicate); retainWindow = true;
    glfwTerminate(); assert(g_initialized && g_cursors && second.cursor == duplicate);
    retainWindow = false; glfwTerminate(); assert(!g_initialized && !g_cursors && g_windows.empty());
    glfwTerminate(); assert(!g_cursors);
    glfwSetCursor(&second,nullptr); assert(lastError == GLFW_NOT_INITIALIZED);
    std::puts("glfw cursor lifecycle: shapes, owned RGBA, OOM, shared binding, destruction and cleanup passed");
}

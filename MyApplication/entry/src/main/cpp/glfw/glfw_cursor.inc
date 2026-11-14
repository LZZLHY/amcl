// GLFW NULL平台的逻辑光标对象实现。由glfw_compat.cpp直接包含，共用其
// g_windows和g_contextLifecycleMutex；宿主测试也编译本实现而非另写模型。
// 提供真实创建、独立身份、图像所有权、窗口关联与退休，不伪造系统光标外观。
// GLFW要求这些入口由应用主线程调用；核心锁额外保护与窗口退休的一致性，
// 不授予跨线程调用全部GLFW API的资格。错误回调在释放本层锁后调用。
#include <algorithm>
#include <cstddef>
#include <limits>
#include <memory>
#include <new>
#include <cstring>

struct GLFWcursor {
    GLFWcursor* next = nullptr;
    int shape = 0;
    int width = 0, height = 0, xhot = 0, yhot = 0;
    // 创建custom cursor时立即复制RGBA；调用者的MemoryStack像素可在返回后释放。
    std::unique_ptr<unsigned char[]> pixels;
};
static GLFWcursor* g_cursors = nullptr;

// 查询不解引用调用者句柄，拒绝外国/已销毁指针。和上游一样，销毁后继续使用
// 句柄不属于支持契约；若分配器复用地址，裸指针本身无法证明旧代次。
static bool glfwOHOS_HasCursorLocked(const GLFWcursor* value) {
    for (const auto* cursor = g_cursors; cursor; cursor = cursor->next)
        if (cursor == value) return true;
    return false;
}

// 仅在窗口已全部成功退出、且调用者持有生命周期锁时调用，不触发回调。
static void glfwOHOS_ClearCursorsLocked() {
    while (g_cursors) {
        auto* cursor = g_cursors;
        g_cursors = cursor->next;
        delete cursor;
    }
}

GLFWcursor* glfwCreateStandardCursor(int shape) {
    std::unique_lock<std::recursive_mutex> lock(g_contextLifecycleMutex);
    if (!g_initialized) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_NOT_INITIALIZED, "GLFW is not initialized"); return nullptr;
    }
    if (shape < GLFW_ARROW_CURSOR || shape > GLFW_NOT_ALLOWED_CURSOR) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_INVALID_ENUM, "Invalid standard cursor shape"); return nullptr;
    }
    // 每次创建独立对象，不能返回固定非零哨兵或按shape共享无引用计数对象。
    auto* cursor = new (std::nothrow) GLFWcursor();
    if (!cursor) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_OUT_OF_MEMORY, "Failed to allocate cursor"); return nullptr;
    }
    cursor->shape = shape;
    cursor->next = g_cursors;
    g_cursors = cursor;
    return cursor;
}

GLFWcursor* glfwCreateCursor(const GLFWimage* image, int xhot, int yhot) {
    std::unique_lock<std::recursive_mutex> lock(g_contextLifecycleMutex);
    if (!g_initialized) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_NOT_INITIALIZED, "GLFW is not initialized"); return nullptr;
    }
    if (!image || !image->pixels || image->width <= 0 || image->height <= 0 ||
        xhot < 0 || yhot < 0 || xhot >= image->width || yhot >= image->height) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_INVALID_VALUE, "Invalid cursor image or hotspot"); return nullptr;
    }
    const auto width = static_cast<size_t>(image->width);
    const auto height = static_cast<size_t>(image->height);
    // C++数组可寻址范围、RGBA乘法均先核验；不让整数溢出形成小分配大复制。
    if (width > static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max()) / 4 / height) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_INVALID_VALUE, "Cursor image is too large"); return nullptr;
    }
    const size_t bytes = width * height * 4;
    std::unique_ptr<GLFWcursor> cursor(new (std::nothrow) GLFWcursor());
    if (cursor) cursor->pixels.reset(new (std::nothrow) unsigned char[bytes]);
    if (!cursor || !cursor->pixels) {
        cursor.reset();
        lock.unlock(); glfwOHOS_ReportError(GLFW_OUT_OF_MEMORY, "Failed to allocate cursor image"); return nullptr;
    }
    std::memcpy(cursor->pixels.get(), image->pixels, bytes);
    cursor->width = image->width; cursor->height = image->height;
    cursor->xhot = xhot; cursor->yhot = yhot;
    cursor->next = g_cursors;
    g_cursors = cursor.release();
    return g_cursors;
}

void glfwSetCursor(GLFWwindow* window, GLFWcursor* cursor) {
    std::unique_lock<std::recursive_mutex> lock(g_contextLifecycleMutex);
    if (!g_initialized) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_NOT_INITIALIZED, "GLFW is not initialized"); return;
    }
    if (std::find(g_windows.begin(), g_windows.end(), window) == g_windows.end() ||
        (cursor && !glfwOHOS_HasCursorLocked(cursor))) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_INVALID_VALUE, "Invalid window or cursor handle"); return;
    }
    // nullptr恢复默认逻辑光标；窗口cursorMode、抓取权和键鼠owner保持原语义。
    window->cursor = cursor;
}

void glfwDestroyCursor(GLFWcursor* cursor) {
    std::unique_lock<std::recursive_mutex> lock(g_contextLifecycleMutex);
    if (!g_initialized) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_NOT_INITIALIZED, "GLFW is not initialized"); return;
    }
    if (!cursor) return; // GLFW C API明确允许空句柄；LWJGL调用方可能更早自行检查。
    GLFWcursor** link = &g_cursors;
    while (*link && *link != cursor) link = &(*link)->next;
    if (!*link) {
        lock.unlock(); glfwOHOS_ReportError(GLFW_INVALID_VALUE, "Invalid cursor handle"); return;
    }
    for (auto* window : g_windows) if (window->cursor == cursor) window->cursor = nullptr;
    *link = cursor->next;
    delete cursor;
}

#include "glfw_compat.h"
#include "../platform/desktop_host_api.h"
#include "../platform/system_clipboard.h"

#include <deviceinfo.h>
#include <cstring>
#include <string>
#include <vector>

extern GLFWerrorfun g_errorCallback;

// 无桌面宿主时，游戏内粘贴继续读取本进程复制的内容。
static std::string g_clipboard;

const char* glfwGetClipboardString(GLFWwindow* window) {
    const auto* host = amclDesktopHostResolve();
    if (!host) return g_clipboard.c_str();
    static thread_local std::vector<char> clipboard(4 * 1024 * 1024 + 1);
    const int result = host->clipboardRead(clipboard.data(), clipboard.size());
    if (result < 0) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "System clipboard read failed or permission denied");
        return nullptr;
    }
    return clipboard.data();
}

void glfwSetClipboardString(GLFWwindow* window, const char* string) {
    if (!string) return;
    const auto* host = amclDesktopHostResolve();
    int32_t result = 0;
    if (host) {
        result = host->clipboardWrite(string);
    } else {
        g_clipboard = string;
        // 桌面宿主尚未就绪时也可能返回空，只给已识别的手机增加系统写入。
        const char* deviceType = OH_GetDeviceType();
        if (deviceType && std::strcmp(deviceType, "phone") == 0) {
            result = amcl::clipboard::WritePlainText(g_clipboard.c_str());
        }
    }
    if (result != 0 && g_errorCallback) {
        g_errorCallback(GLFW_PLATFORM_ERROR, "System clipboard write failed");
    }
}

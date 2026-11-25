#include "../../glfw/glfw_compat.h"
#include "../../platform/desktop_host_api.h"
#include "../../platform/system_clipboard.h"
#include <deviceinfo.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#define CHECK(condition) do { \
    if (!(condition)) { std::fprintf(stderr, "line %d: %s\n", __LINE__, #condition); std::exit(1); } \
} while (false)

namespace {
const char* deviceType = nullptr;
bool desktopAvailable = false;
AmclDesktopHostV1 desktopHost{};
std::string systemText = "existing-system-value";
std::string desktopText = "existing-desktop-value";
int32_t systemWriteStatus = 0;
int32_t desktopWriteStatus = 0;
bool desktopReadFails = false;
int systemWrites = 0;
int desktopWrites = 0;
int desktopReads = 0;
int errors = 0;
int lastError = 0;

void RecordError(int code, const char*) {
    ++errors;
    lastError = code;
}

int32_t WriteDesktop(const char* text) {
    ++desktopWrites;
    if (desktopWriteStatus == 0) desktopText = text;
    return desktopWriteStatus;
}

int32_t ReadDesktop(char* buffer, size_t capacity) {
    ++desktopReads;
    if (desktopReadFails || desktopText.size() >= capacity) return -1;
    std::memcpy(buffer, desktopText.c_str(), desktopText.size() + 1);
    return static_cast<int32_t>(desktopText.size());
}

void CheckLocalText(const char* expected) {
    const char* text = glfwGetClipboardString(nullptr);
    CHECK(text != nullptr && std::strcmp(text, expected) == 0);
}

/** 手机复制向系统写入一次，游戏内读取继续使用自己的 UTF-8 缓存。 */
void CheckPhone() {
    const char* unicode = u8"复制到系统😀";
    glfwSetClipboardString(nullptr, unicode);
    CHECK(systemWrites == 1 && systemText == unicode && errors == 0);
    systemText = "changed-by-another-app";
    CheckLocalText(unicode);
    CHECK(desktopReads == 0 && systemWrites == 1);

    // 系统拒绝时保留本轮游戏内复制文本，避免系统失败同时破坏游戏内粘贴。
    systemWriteStatus = -3;
    glfwSetClipboardString(nullptr, "copy-with-system-error");
    CHECK(systemWrites == 2 && systemText == "changed-by-another-app");
    CHECK(errors == 1 && lastError == GLFW_PLATFORM_ERROR);
    CheckLocalText("copy-with-system-error");

    glfwSetClipboardString(nullptr, nullptr);
    CHECK(systemWrites == 2 && desktopWrites == 0 && errors == 1);
    CheckLocalText("copy-with-system-error");
}

/** 桌面宿主未发布时沿用缓存，发布后只通过既有桌面函数表读写。 */
void CheckDesktop() {
    glfwSetClipboardString(nullptr, "before-desktop-host");
    CheckLocalText("before-desktop-host");
    CHECK(systemWrites == 0 && desktopWrites == 0 && desktopReads == 0);

    desktopHost.clipboardWrite = WriteDesktop;
    desktopHost.clipboardRead = ReadDesktop;
    desktopAvailable = true;
    glfwSetClipboardString(nullptr, "desktop-host");
    CHECK(systemWrites == 0 && desktopWrites == 1 && desktopText == "desktop-host" && errors == 0);
    CheckLocalText("desktop-host");
    CHECK(desktopReads == 1);

    desktopWriteStatus = -4;
    glfwSetClipboardString(nullptr, "rejected-by-desktop-host");
    CHECK(systemWrites == 0 && desktopWrites == 2 && desktopText == "desktop-host");
    CHECK(errors == 1 && lastError == GLFW_PLATFORM_ERROR);
    desktopReadFails = true;
    CHECK(glfwGetClipboardString(nullptr) == nullptr);
    CHECK(desktopReads == 2 && errors == 2 && lastError == GLFW_PLATFORM_ERROR);
}

void CheckLocalOnly() {
    glfwSetClipboardString(nullptr, "local-only");
    CheckLocalText("local-only");
    CHECK(systemWrites == 0 && desktopWrites == 0 && desktopReads == 0 && errors == 0);
}
}

GLFWerrorfun g_errorCallback = RecordError;

extern "C" const char* OH_GetDeviceType(void) {
    return deviceType;
}

extern "C" const AmclDesktopHostV1* amclDesktopHostResolve() {
    return desktopAvailable ? &desktopHost : nullptr;
}

namespace amcl::clipboard {
int32_t WritePlainText(const char* text) {
    ++systemWrites;
    if (systemWriteStatus == 0) systemText = text;
    return systemWriteStatus;
}
}

// 每种设备作为独立 CTest 进程，真实设备类型在一次应用进程中不会变化。
int main(int argc, char** argv) {
    CHECK(argc == 2);
    const std::string mode = argv[1];
    if (mode == "phone") {
        deviceType = "phone";
        CheckPhone();
    } else if (mode == "desktop") {
        deviceType = "2in1";
        CheckDesktop();
    } else if (mode == "tablet" || mode == "unknown") {
        deviceType = mode == "tablet" ? "tablet" : nullptr;
        CheckLocalOnly();
    } else {
        CHECK(false);
    }
    std::printf("GLFW clipboard %s PASS\n", argv[1]);
}

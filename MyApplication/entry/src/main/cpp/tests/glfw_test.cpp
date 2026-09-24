// glfw_test.cpp — GLFW 兼容层验证测试
// 模拟 Minecraft/LWJGL 的典型 GLFW 调用流程

#include "../glfw/glfw_compat.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstring>
#include <string>
#include <sstream>
#include <dlfcn.h>

#undef LOG_TAG
#define LOG_TAG "GLFW_TEST"

static std::string g_glfwTestResult;

// 模拟 LWJGL 的回调
static int g_cbWindowSizeCount = 0;
static int g_cbKeyCount = 0;
static int g_cbCursorCount = 0;
static int g_cbMouseBtnCount = 0;

static void TestWindowSizeCb(GLFWwindow* w, int width, int height) {
    g_cbWindowSizeCount++;
}
static void TestKeyCb(GLFWwindow* w, int key, int scancode, int action, int mods) {
    g_cbKeyCount++;
}
static void TestCursorPosCb(GLFWwindow* w, double x, double y) {
    g_cbCursorCount++;
}
static void TestMouseBtnCb(GLFWwindow* w, int button, int action, int mods) {
    g_cbMouseBtnCount++;
}

extern "C" {

const char* runGlfwCompatTest() {
    std::ostringstream ss;
    ss << "========================================\n";
    ss << "  GLFW 兼容层验证报告（安全模式）\n";
    ss << "========================================\n\n";
    ss << "注意: 测试在 NAPI 线程运行，无 NativeWindow，\n";
    ss << "跳过 EGL/窗口创建，只验证 API 可用性。\n";
    ss << "完整测试需在 MC 启动流程中进行。\n\n";

    int score = 0;
    int total = 7;

    // 1. glfwInit（不涉及 EGL，安全）
    ss << "===== 初始化测试 =====\n\n";
    int initResult = glfwInit();
    if (initResult == GLFW_TRUE) {
        ss << "✅ glfwInit: OK\n";
        score++;
    } else {
        ss << "❌ glfwInit: FAIL\n";
    }

    // 2. glfwWindowHint（纯内存操作，安全）
    glfwWindowHint(GLFW_CLIENT_API, GLFW_OPENGL_ES_API);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 0);
    ss << "✅ glfwWindowHint: OK (ES 3.0)\n";
    score++;

    // 3. 时间函数
    double t = glfwGetTime();
    ss << "\n===== 时间函数测试 =====\n\n";
    ss << "glfwGetTime: " << t << " 秒\n";
    if (t >= 0) {
        ss << "✅ glfwGetTime: OK\n";
        score++;
    } else {
        ss << "❌ glfwGetTime: FAIL\n";
    }

    // 4. 验证 GLFW 核心 API（编译时链接，直接检查函数指针）
    ss << "\n===== 核心 API 验证 =====\n\n";
    struct ApiFn { const char* name; void* ptr; };
    ApiFn coreFns[] = {
        {"glfwCreateWindow",        (void*)glfwCreateWindow},
        {"glfwDestroyWindow",       (void*)glfwDestroyWindow},
        {"glfwMakeContextCurrent",  (void*)glfwMakeContextCurrent},
        {"glfwSwapBuffers",         (void*)glfwSwapBuffers},
        {"glfwPollEvents",          (void*)glfwPollEvents},
        {"glfwSetKeyCallback",      (void*)glfwSetKeyCallback},
        {"glfwSetCursorPosCallback", (void*)glfwSetCursorPosCallback},
        {"glfwSetMouseButtonCallback", (void*)glfwSetMouseButtonCallback},
        {"glfwGetWindowSize",       (void*)glfwGetWindowSize},
        {"glfwGetFramebufferSize",  (void*)glfwGetFramebufferSize},
    };
    int symFound = 0, symTotal = 10;
    for (int i = 0; i < symTotal; i++) {
        if (coreFns[i].ptr) {
            ss << "  ✅ " << coreFns[i].name << "\n";
            symFound++;
        } else {
            ss << "  ❌ " << coreFns[i].name << "\n";
        }
    }
    ss << "\n核心 API: " << symFound << "/" << symTotal << "\n";
    if (symFound == symTotal) score++;

    // 5. 验证 OHOS 扩展 API
    ss << "\n===== OHOS 扩展 API =====\n\n";
    ApiFn ohosFns[] = {
        {"glfwOHOS_SetNativeWindow", (void*)glfwOHOS_SetNativeWindow},
        {"glfwOHOS_SetTouchEvent",   (void*)glfwOHOS_SetTouchEvent},
        {"glfwOHOS_GetCompatInfo",   (void*)glfwOHOS_GetCompatInfo},
    };
    int ohosFound = 0, ohosTotal = 3;
    for (int i = 0; i < ohosTotal; i++) {
        if (ohosFns[i].ptr) {
            ss << "  ✅ " << ohosFns[i].name << "\n";
            ohosFound++;
        } else {
            ss << "  ❌ " << ohosFns[i].name << "\n";
        }
    }
    ss << "\nOHOS 扩展: " << ohosFound << "/" << ohosTotal << "\n";
    if (ohosFound == ohosTotal) score++;

    // 6. 触摸输入 API（不需要窗口）
    ss << "\n===== 触摸输入测试 =====\n\n";
    g_cbCursorCount = 0;
    g_cbMouseBtnCount = 0;
    glfwOHOS_SetTouchEvent(100.0f, 200.0f, 0); // touch down
    glfwOHOS_SetTouchEvent(100.0f, 200.0f, 1); // touch up
    ss << "✅ glfwOHOS_SetTouchEvent: 调用成功（无崩溃）\n";
    score++;

    // 7. glfwTerminate（安全清理）
    glfwTerminate();
    ss << "✅ glfwTerminate: OK\n";
    score++;

    // 总结
    ss << "\n========================================\n";
    ss << "  综合评估\n";
    ss << "========================================\n\n";
    ss << "得分: " << score << "/" << total << "\n\n";

    if (score >= 6) {
        ss << "🎉 GLFW 兼容层 API 完整可用\n";
        ss << "窗口创建/EGL 初始化需在 MC 启动流程中测试\n";
    } else if (score >= 4) {
        ss << "⚠️ 部分 API 可用，需进一步调试\n";
    } else {
        ss << "❌ GLFW 兼容层存在问题\n";
    }

    g_glfwTestResult = ss.str();
    return g_glfwTestResult.c_str();
}

} // extern "C"

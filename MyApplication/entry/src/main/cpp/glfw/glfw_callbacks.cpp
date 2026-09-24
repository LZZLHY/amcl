// GLFW callbacks, desktop window services and mobile compatibility queries.

#include "glfw_internal.h"
#include "../platform/desktop_host_api.h"
#include "../platform/native_gl.h"
#include "egl_dispatch.h"
#include "../platform/desktop_drop_packet.h"
#include "../input/adapters/glfw_input_mode.h"
#include "../input/amcl_input_host_descriptor.h"
#include <hilog/log.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <cstdlib>

#undef LOG_TAG
#define LOG_TAG "GLFW_CB"

// 桥接层（input_bridge_ohos.c，同属 libglfw.so）：grab 单一真相权威写点。
extern "C" void inputBridge_setGrabState(int grabbing);
// 记录 Minecraft 经 glfwSetCursorPos 请求的 grabbed 光标基准，供 menu→grabbed 时重锚。
extern "C" void inputBridge_setLookCursor(double x, double y);

static bool api26RawMouseMotionSupported() {
    const AmclInputHostApiV1* api = nullptr;
    if (amclInputHostDescriptorResolveV1(&api) !=
        AMCL_INPUT_HOST_DESCRIPTOR_OK) {
        return false;
    }
    return amcl::input::GlfwApi26RawMouseMotionSupported(api);
}

// ==================== 回调设置 ====================
GLFWerrorfun glfwSetErrorCallback(GLFWerrorfun callback) {
    GLFWerrorfun old = g_errorCallback;
    g_errorCallback = callback;
    return old;
}

GLFWwindowsizefun glfwSetWindowSizeCallback(GLFWwindow* window, GLFWwindowsizefun callback) {
    if (!window) return nullptr;
    GLFWwindowsizefun old = window->windowSizeCb;
    window->windowSizeCb = callback;
    // Registration does not imply that the consumer's render resources exist.
    return old;
}

GLFWframebuffersizefun glfwSetFramebufferSizeCallback(GLFWwindow* window, GLFWframebuffersizefun callback) {
    if (!window) return nullptr;
    GLFWframebuffersizefun old = window->framebufferSizeCb;
    window->framebufferSizeCb = callback;
    // Pending changes are dispatched from the event pump; initial size is queryable.
    return old;
}

GLFWkeyfun glfwSetKeyCallback(GLFWwindow* window, GLFWkeyfun callback) {
    if (!window) return nullptr;
    GLFWkeyfun old = window->keyCb;
    window->keyCb = callback;
    return old;
}

GLFWcursorposfun glfwSetCursorPosCallback(GLFWwindow* window, GLFWcursorposfun callback) {
    if (!window) return nullptr;
    GLFWcursorposfun old = window->cursorPosCb;
    window->cursorPosCb = callback;
    return old;
}

GLFWmousebuttonfun glfwSetMouseButtonCallback(GLFWwindow* window, GLFWmousebuttonfun callback) {
    if (!window) return nullptr;
    GLFWmousebuttonfun old = window->mouseButtonCb;
    window->mouseButtonCb = callback;
    return old;
}

GLFWscrollfun glfwSetScrollCallback(GLFWwindow* window, GLFWscrollfun callback) {
    if (!window) return nullptr;
    GLFWscrollfun old = window->scrollCb;
    window->scrollCb = callback;
    return old;
}

GLFWwindowclosefun glfwSetWindowCloseCallback(GLFWwindow* window, GLFWwindowclosefun callback) {
    if (!window) return nullptr;
    GLFWwindowclosefun old = window->closeCb;
    window->closeCb = callback;
    return old;
}

GLFWwindowfocusfun glfwSetWindowFocusCallback(GLFWwindow* window, GLFWwindowfocusfun callback) {
    if (!window) return nullptr;
    GLFWwindowfocusfun old = window->focusCb;
    window->focusCb = callback;
    return old;
}

// ==================== 更多回调 stub ====================
// 方案 B：char / charMods / cursorEnter 在 B 路径下由上游原版 GLFW.class 经 libffi
// 直接调到这里的 C 函数（A 路径走 JNI nglfwSet*，不经过这三个 C 函数 → A 行为不变）。
// 每个窗口独立保存callback；只有当前呈现窗口可写InputBridge全局分发入口。隐藏辅助窗口
// 注册回调不能覆盖主窗口，隐藏主窗口show时由promotion统一发布已经保存的回调。
extern "C" {
    void* inputBridge_replaceCharCallback(void* cb);
    void* inputBridge_replaceCharModsCallback(void* cb);
    void* inputBridge_replaceCursorEnterCallback(void* cb);
}
GLFWcharfun glfwSetCharCallback(GLFWwindow* window, GLFWcharfun callback) {
    if (!window) return nullptr;
    const auto old = window->charCb; window->charCb = callback;
    window->charCallbackAssigned = true;
    if (!window->auxiliary && window == g_currentWindow) inputBridge_replaceCharCallback((void*)callback);
    return old;
}
GLFWcharmodsfun glfwSetCharModsCallback(GLFWwindow* window, GLFWcharmodsfun callback) {
    if (!window) return nullptr;
    const auto old = window->charModsCb; window->charModsCb = callback;
    window->charModsCallbackAssigned = true;
    if (!window->auxiliary && window == g_currentWindow) inputBridge_replaceCharModsCallback((void*)callback);
    return old;
}
GLFWcursorenterfun glfwSetCursorEnterCallback(GLFWwindow* window, GLFWcursorenterfun callback) {
    if (!window) return nullptr;
    const auto old = window->cursorEnterCb; window->cursorEnterCb = callback;
    window->cursorEnterCallbackAssigned = true;
    if (!window->auxiliary && window == g_currentWindow) inputBridge_replaceCursorEnterCallback((void*)callback);
    return old;
}
GLFWdropfun glfwSetDropCallback(GLFWwindow* window, GLFWdropfun callback) {
    if (!window) return nullptr;
    const auto old=window->dropCb; window->dropCb=callback; return old;
}
GLFWwindowiconifyfun glfwSetWindowIconifyCallback(GLFWwindow* window, GLFWwindowiconifyfun callback) {
    if (!window) return nullptr;
    const auto old = window->iconifyCb; window->iconifyCb = callback; return old;
}
GLFWwindowmaximizefun glfwSetWindowMaximizeCallback(GLFWwindow* window, GLFWwindowmaximizefun callback) {
    if (!window) return nullptr;
    const auto old = window->maximizeCb; window->maximizeCb = callback; return old;
}
GLFWwindowcontentscalefun glfwSetWindowContentScaleCallback(GLFWwindow* window, GLFWwindowcontentscalefun callback) {
    if (!window) return nullptr;
    const auto old = window->contentScaleCb; window->contentScaleCb = callback; return old;
}
GLFWwindowrefreshfun glfwSetWindowRefreshCallback(GLFWwindow* window, GLFWwindowrefreshfun callback) {
    if (!window) return nullptr;
    const auto old = window->refreshCb; window->refreshCb = callback; return old;
}
GLFWwindowposfun glfwSetWindowPosCallback(GLFWwindow* window, GLFWwindowposfun callback) {
    if (!window) return nullptr;
    const auto old = window->positionCb; window->positionCb = callback; return old;
}

// ==================== 输入查询 ====================
int glfwGetKey(GLFWwindow* window, int key) {
    if (!window || key < 0 || key >= 512) return GLFW_RELEASE;
    const int state = window->keys[key];
    // ---- 决定性探针：MC 到底有没有在轮询修饰键 ----
    //
    // 背景：shift+左键在创造物品栏应当取整组，实测退化成取一个。而
    // `AMCL_KBD leftPress` 已证明按下左键那一刻 `win->keys[340]==1`。两者矛盾，
    // 只可能是 MC 这条路径**不读轮询**（而是读事件自带的 mods，那一项我们此前恒为 0）。
    //
    // 本探针只对修饰键、且只在**返回按下**时打，限量 20 条：
    //   · 出现 ⇒ MC 确实在轮询，且拿到的是 1 ⇒ 我们这条链没问题，问题在 MC 侧；
    //   · 从不出现 ⇒ MC 不轮询修饰键，走的是事件 mods ⇒ 补齐 mods 才是正解。
    // glfwGetKey 可能被高频调用，所以判据刻意做到两次整型比较即短路。
    if (state != GLFW_RELEASE &&
        (key == 340 || key == 344 || key == 341 || key == 345)) {
        static std::atomic<int> logged{0};
        if (logged.fetch_add(1, std::memory_order_relaxed) < 20) {
            OH_LOG_INFO(LOG_APP,
                        "AMCL_KBD glfwGetKey polled key=%{public}d state=%{public}d "
                        "(caller believes this modifier is held)",
                        key, state);
        }
    }
    return state;
}

int glfwGetMouseButton(GLFWwindow* window, int button) {
    if (!window || button < 0 || button >= 8) return GLFW_RELEASE;
    return window->mouseButtons[button];
}

void glfwGetCursorPos(GLFWwindow* window, double* xpos, double* ypos) {
    if (window) {
        if (xpos) *xpos = window->cursorX;
        if (ypos) *ypos = window->cursorY;
    }
}

// GLFW_CURSOR 是 grab 状态的唯一权威入口：记录 cursorMode、发布兼容 env，
// 再由 inputBridge_setGrabState() 同步 native grab 状态。menu→grabbed 时 bridge 会使用
// 最近一次 glfwSetCursorPos() 记录的 MC 中心重锚 look/pump 基准；菜单残余位移则由
// MENU_POINTER 的 +2 present 提交屏障在 Screen 关闭前消费。
void glfwSetInputMode(GLFWwindow* window, int mode, int value) {
    OH_LOG_INFO(LOG_APP, "GLFW: setInputMode mode=%{public}d value=%{public}d", mode, value);
    if (mode == GLFW_CURSOR) {
        if (!window) return;
        window->cursorMode = value;
        window->cursorModeAssigned = true;
        // 离屏窗口只记录本地请求，不改变主窗口的grab、兼容环境或平台捕获状态。
        if (window->auxiliary || window != g_currentWindow) return;
        g_cursorMode = value;
        if (window) {
            const bool requested = value == GLFW_CURSOR_DISABLED;
            window->inputCapture.requested = requested;
            // Stop accepting relative input immediately on release intent.  A
            // grant is set only by the later typed capture-result sink.
            if (!requested) window->inputCapture.active = false;
        }
        // 通过环境变量发布 grab 状态（过渡期兜底；touch_input 现主要读 inputBridge_isGrabbing 原子）。
        setenv("AMCL_CURSOR_MODE", (value == GLFW_CURSOR_DISABLED) ? "grabbed" : "normal", 1);
        inputBridge_setGrabState(value == GLFW_CURSOR_DISABLED);
        OH_LOG_INFO(LOG_APP, "GLFW: cursor mode -> %{public}s",
                    (value == GLFW_CURSOR_DISABLED) ? "grabbed" : "normal");
        return;
    }
    if (mode == GLFW_RAW_MOUSE_MOTION) {
        if (!window || (value != GLFW_TRUE && value != GLFW_FALSE)) {
            if (g_errorCallback) {
                g_errorCallback(GLFW_PLATFORM_ERROR,
                                "Invalid GLFW raw mouse motion request");
            }
            return;
        }
        const bool enabled = value == GLFW_TRUE;
        if (!amcl::input::GlfwSetRawMouseMotion(
                &window->inputCapture, enabled,
                api26RawMouseMotionSupported())) {
            if (g_errorCallback) {
                g_errorCallback(GLFW_PLATFORM_ERROR,
                                "API 26 raw mouse motion is unavailable");
            }
            return;
        }
    }
}

int glfwGetInputMode(GLFWwindow* window, int mode) {
    if (mode == GLFW_CURSOR) return window ? window->cursorMode : GLFW_CURSOR_NORMAL;
    if (mode == GLFW_RAW_MOUSE_MOTION) {
        return window && window->inputCapture.rawMouseMotion
            ? GLFW_TRUE : GLFW_FALSE;
    }
    return 0;
}

// 更新 GLFW 窗口局部光标坐标，同时记录 Minecraft 请求的光标位置。
// Minecraft 1.21.11 在 grabMouse() 中先把 MouseHandler.xpos/ypos 设为窗口中心，
// 再依次调用 glfwSetCursorPos(center) 与 glfwSetInputMode(DISABLED)。bridge 因而只在这里
// 记录该中心，并在随后的 menu→grabbed 转换中把 look 累加器及 pump 去重基准重锚到它。
void glfwSetCursorPos(GLFWwindow* window, double xpos, double ypos) {
    if (window) { window->cursorX = xpos; window->cursorY = ypos; }
    if (window && !window->auxiliary && window == g_currentWindow) inputBridge_setLookCursor(xpos, ypos);
}
int glfwRawMouseMotionSupported(void) {
    return api26RawMouseMotionSupported() ? GLFW_TRUE : GLFW_FALSE;
}

// glfwGetKeyName — 复刻 real GLFW / PojavLauncher：**可打印键**返回其字符名，供 MC 显示按键名
// （新手教程提示 “Move with W, A, S and D”、控制菜单、mod 配置界面等）。
//
// 背景（问题根因）：MC 取按键显示名时先调本函数；返回非空 → 直接用该字面名；返回 null → 回退
// Component.translatable("key.keyboard.x")。此前本函数对所有键返回 nullptr，字母键的翻译回退
// 在首启/教程场景下未被正确解析，露出了原始的 “key.keyboard.w”。实现本表后 MC 直接拿到 “W” 等，
// 不再依赖语言文件是否加载 → 稳定正确。
//
// 设计：
//  - 字母 A–Z、数字 0–9、主键区标点 → 返回字符名（字母统一**大写**，与我们屏幕虚拟按键标签
//    glfwKeyName / keyShortLabel 一致，也贴合 MC 控制菜单观感）。
//  - **特殊键**（Space / Enter / Tab / Esc / F1–F25 / 方向 / 修饰键 / 小键盘 等）返回 nullptr，
//    交给 MC 用其**本地化译名**显示（Space / Left Shift / Keypad 0 …），保留多语言友好性
//    （real GLFW 同样对这些键返回 null）。
//  - 返回值均为**静态字符串字面量**（永久生命周期、可重入安全），不使用临时 buffer。
//  - key<0（SCANCODE 型）时用 scancode 兜底（本实现里 glfwGetKeyScancode 为恒等，二者等价）。
const char* glfwGetKeyName(int key, int scancode) {
    if (key < 0 && scancode > 0) key = scancode;
    // 字母 A–Z（GLFW 65..90）
    static const char* const kLetters[26] = {
        "A","B","C","D","E","F","G","H","I","J","K","L","M",
        "N","O","P","Q","R","S","T","U","V","W","X","Y","Z"
    };
    if (key >= 65 && key <= 90) return kLetters[key - 65];
    // 数字 0–9（GLFW 48..57）
    static const char* const kDigits[10] = { "0","1","2","3","4","5","6","7","8","9" };
    if (key >= 48 && key <= 57) return kDigits[key - 48];
    // 主键区标点（值取自 GLFW 键码常量）
    switch (key) {
        case 39: return "'";   // GLFW_KEY_APOSTROPHE
        case 44: return ",";   // GLFW_KEY_COMMA
        case 45: return "-";   // GLFW_KEY_MINUS
        case 46: return ".";   // GLFW_KEY_PERIOD
        case 47: return "/";   // GLFW_KEY_SLASH
        case 59: return ";";   // GLFW_KEY_SEMICOLON
        case 61: return "=";   // GLFW_KEY_EQUAL
        case 91: return "[";   // GLFW_KEY_LEFT_BRACKET
        case 92: return "\\";  // GLFW_KEY_BACKSLASH
        case 93: return "]";   // GLFW_KEY_RIGHT_BRACKET
        case 96: return "`";   // GLFW_KEY_GRAVE_ACCENT
        default: break;
    }
    // 特殊键：返回 null，让 MC 用本地化译名（Space / Enter / Left Shift / F3 / Keypad 0 …）。
    return nullptr;
}

int glfwGetKeyScancode(int key) { return key; }
GLFWcursor* glfwCreateStandardCursor(int shape) { return nullptr; }
GLFWcursor* glfwCreateCursor(const GLFWimage* image, int xhot, int yhot) { return nullptr; }
void glfwDestroyCursor(GLFWcursor* cursor) { }
void glfwSetCursor(GLFWwindow* window, GLFWcursor* cursor) { }


static bool desktopCommand(int kind, int a = 0, int b = 0, int c = 0, int d = 0, const char* text = nullptr) {
    const auto* host = amclDesktopHostResolve();
    if (!host) return false;
    if (!host->submit(kind, a, b, c, d, text) && g_errorCallback)
        g_errorCallback(GLFW_PLATFORM_ERROR, "Desktop window command rejected (inactive or full queue)");
    return true;
}
static AmclDesktopSnapshot desktopFacts() {
    AmclDesktopSnapshot facts{};
    const auto* host = amclDesktopHostResolve();
    if (host) host->snapshot(&facts);
    return facts;
}

// Clipboard
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
    if (!host) { g_clipboard = string; return; }
    if (host->clipboardWrite(string) != 0 && g_errorCallback)
        g_errorCallback(GLFW_PLATFORM_ERROR, "System clipboard write failed");
}

// Native gamepad mode exposes canonical OHOS state. Launcher mapping stays separate.
static bool readDesktopPad(int jid, AmclDesktopGamepad& pad) {
    if(jid<0 || jid>=16)return false;
    const auto* host=amclDesktopHostResolve(); return host && host->gamepadRead(jid,&pad)!=0;
}
int glfwJoystickPresent(int jid) { AmclDesktopGamepad pad{}; return readDesktopPad(jid,pad) ? 1 : 0; }
const float* glfwGetJoystickAxes(int jid, int* count) {
    static thread_local AmclDesktopGamepad pads[16]; if(jid<0 || jid>=16){if(count)*count=0;return nullptr;} auto& pad=pads[jid];
    if(!readDesktopPad(jid,pad)) {if(count)*count=0;return nullptr;}
    if(count)*count=6;return pad.axes;
}
const unsigned char* glfwGetJoystickButtons(int jid, int* count) {
    static thread_local AmclDesktopGamepad pads[16]; if(jid<0 || jid>=16){if(count)*count=0;return nullptr;} auto& pad=pads[jid];
    if(!readDesktopPad(jid,pad)) {if(count)*count=0;return nullptr;}
    if(count)*count=18;return pad.buttons;
}
const unsigned char* glfwGetJoystickHats(int jid, int* count) {
    static thread_local AmclDesktopGamepad pads[16]; if(jid<0 || jid>=16){if(count)*count=0;return nullptr;} auto& pad=pads[jid];
    if(!readDesktopPad(jid,pad)) {if(count)*count=0;return nullptr;}
    if(count)*count=1;return pad.hats;
}
const char* glfwGetJoystickName(int jid) {static thread_local AmclDesktopGamepad pads[16]; if(jid<0 || jid>=16)return nullptr; auto& pad=pads[jid];return readDesktopPad(jid,pad)?pad.name:nullptr;}
const char* glfwGetJoystickGUID(int jid) {
    AmclDesktopGamepad pad{}; if(!readDesktopPad(jid,pad))return nullptr;
    static thread_local char guids[16][33]; auto& guid=guids[jid]; uint64_t hash=14695981039346656037ULL;
    for(const unsigned char* s=reinterpret_cast<const unsigned char*>(pad.id);*s;++s){hash^=*s;hash*=1099511628211ULL;}
    snprintf(guid,sizeof(guid),"616d636c00000000%016llx",static_cast<unsigned long long>(hash));return guid;
}
int glfwJoystickIsGamepad(int jid) {return glfwJoystickPresent(jid);}
const char* glfwGetGamepadName(int jid) {return glfwGetJoystickName(jid);}
static GLFWjoystickfun g_desktopJoystickCallback=nullptr;
static bool g_padConnected[16]{};
static uint64_t g_padGenerations[16]{};
GLFWjoystickfun glfwSetJoystickCallback(GLFWjoystickfun callback) {
    const auto previous=g_desktopJoystickCallback;g_desktopJoystickCallback=callback;return previous;
}
static void pollDesktopPads() {
    for(int i=0;i<16;++i){AmclDesktopGamepad pad{};const bool connected=readDesktopPad(i,pad);
        const bool replaced=connected && g_padConnected[i] && pad.generation!=g_padGenerations[i];
        if(g_padConnected[i] && (!connected || replaced) && g_desktopJoystickCallback)g_desktopJoystickCallback(i,0x00040002);
        if(connected && (!g_padConnected[i] || replaced) && g_desktopJoystickCallback)g_desktopJoystickCallback(i,0x00040001);
        g_padConnected[i]=connected;g_padGenerations[i]=pad.generation;
    }
}
static void* g_joystickUserPointers[16]{};
void glfwSetJoystickUserPointer(int jid, void* pointer) {if(jid>=0 && jid<16)g_joystickUserPointers[jid]=pointer;}
void* glfwGetJoystickUserPointer(int jid) {return jid>=0 && jid<16?g_joystickUserPointers[jid]:nullptr;}
int glfwUpdateGamepadMappings(const char*) {
    if(g_errorCallback)g_errorCallback(GLFW_PLATFORM_ERROR, "Custom gamepad mappings are unavailable; HarmonyOS supplies the standard layout");
    return GLFW_FALSE;
}
int glfwGetGamepadState(int jid, GLFWgamepadstate* state) {
    if(!state)return GLFW_FALSE;
    memset(state,0,sizeof(*state));AmclDesktopGamepad pad{};if(!readDesktopPad(jid,pad))return GLFW_FALSE;
    memcpy(state->buttons,pad.buttons,sizeof(state->buttons));memcpy(state->axes,pad.axes,sizeof(state->axes));return GLFW_TRUE;
}

// ==================== 窗口管理（桌面转发系统窗口） ====================
void glfwSetWindowTitle(GLFWwindow* window, const char* title) {
    if (!window) return;
    // Real GLFW copies the title; the caller's buffer is transient (LWJGL
    // MemoryStack). Keep ownership inside GLFWwindow (freed on destroy).
    char* copy = title ? strdup(title) : nullptr;
    free(const_cast<char*>(window->title));
    window->title = copy;
    if (!window->auxiliary) desktopCommand(AMCL_DESKTOP_TITLE, 0, 0, 0, 0, title);
}
void glfwSetWindowIcon(GLFWwindow* window, int count, const GLFWimage* images) {
    if (amclDesktopHostResolve() && g_errorCallback) g_errorCallback(0x0001000C, "HarmonyOS public Window API does not expose runtime application icons");
}
void glfwSetWindowPos(GLFWwindow* window, int xpos, int ypos) { if (window && !window->auxiliary) desktopCommand(AMCL_DESKTOP_MOVE, xpos, ypos); }
void glfwGetWindowPos(GLFWwindow* window, int* xpos, int* ypos) {
    if (window && window->auxiliary) { if (xpos) *xpos = 0; if (ypos) *ypos = 0; return; }
    if (amclDesktopHostResolve()) { const auto f=desktopFacts(); if(xpos)*xpos=f.x; if(ypos)*ypos=f.y; return; }
    AmclInputSurfaceContextPayload context{};
    const bool hasRect = glfwOHOS_ReadInputSurfaceContext(&context) &&
        (context.validFields & AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT) != 0u;
    if (xpos) *xpos = hasRect ? context.leftPx : 0;
    if (ypos) *ypos = hasRect ? context.topPx : 0;
}
void glfwSetWindowSize(GLFWwindow* window, int width, int height) {
    if (window && !window->auxiliary && desktopCommand(AMCL_DESKTOP_RESIZE, width, height)) return;
    // 移动设备：忽略窗口尺寸改变请求，保持 EGL surface 的实际尺寸
    // MC 切换全屏时会通过此函数改变窗口尺寸，导致触摸坐标映射错乱
    if (window) {
        OH_LOG_INFO(LOG_APP, "GLFW: glfwSetWindowSize(%{public}dx%{public}d) ignored, keeping %{public}dx%{public}d",
                    width, height, window->width, window->height);
    }
}
void glfwSetWindowSizeLimits(GLFWwindow* window, int minw, int minh, int maxw, int maxh) { if (window && !window->auxiliary) desktopCommand(AMCL_DESKTOP_LIMITS, minw, minh, maxw, maxh); }
void glfwSetWindowAspectRatio(GLFWwindow* window, int numer, int denom) { if (window && !window->auxiliary) desktopCommand(AMCL_DESKTOP_ASPECT, numer, denom); }
void glfwIconifyWindow(GLFWwindow* window) { if (window && !window->auxiliary) desktopCommand(AMCL_DESKTOP_MINIMIZE); }
void glfwRestoreWindow(GLFWwindow* window) { if (window && !window->auxiliary) desktopCommand(AMCL_DESKTOP_RESTORE); }
void glfwMaximizeWindow(GLFWwindow* window) { if (window && !window->auxiliary) desktopCommand(AMCL_DESKTOP_MAXIMIZE); }
void glfwShowWindow(GLFWwindow* window) { if (glfwOHOS_PromoteWindow(window)) desktopCommand(AMCL_DESKTOP_SHOW); }
void glfwHideWindow(GLFWwindow* window) {
    if (!window) return;
    window->visible = false;
    if (!window->auxiliary) desktopCommand(AMCL_DESKTOP_HIDE);
}
void glfwFocusWindow(GLFWwindow* window) { if (window && !window->auxiliary) desktopCommand(AMCL_DESKTOP_SHOW); }
void glfwRequestWindowAttention(GLFWwindow* window) {
    if (amclDesktopHostResolve() && g_errorCallback) g_errorCallback(0x0001000C, "HarmonyOS public Window API does not expose attention requests");
}

void glfwSetWindowUserPointer(GLFWwindow* window, void* pointer) { if (window) window->userPointer = pointer; }
void* glfwGetWindowUserPointer(GLFWwindow* window) { return window ? window->userPointer : nullptr; }

int glfwGetWindowAttrib(GLFWwindow* window, int attrib) {
    if (!window) return 0;
    if (attrib == GLFW_VISIBLE) return !window->auxiliary && window->visible;
    if (window->auxiliary && (attrib == GLFW_FOCUSED || attrib == GLFW_MAXIMIZED || attrib == GLFW_ICONIFIED)) return 0;
    if (attrib == GLFW_CLIENT_API) return window->clientAPI;
    if (window->clientAPI == GLFW_NO_API && (attrib == GLFW_CONTEXT_VERSION_MAJOR || attrib == GLFW_CONTEXT_VERSION_MINOR ||
        attrib == GLFW_OPENGL_PROFILE || attrib == GLFW_OPENGL_FORWARD_COMPAT || attrib == GLFW_CONTEXT_CREATION_API)) return 0;
    if (amcl::desktop::UsesDesktopOpenGlContext()) {
        switch (attrib) {
            case GLFW_CONTEXT_VERSION_MAJOR: return window->actualContextMajor;
            case GLFW_CONTEXT_VERSION_MINOR: return window->actualContextMinor;
            case GLFW_OPENGL_PROFILE: return window->actualContextProfile;
            case GLFW_OPENGL_FORWARD_COMPAT: return (window->actualContextFlags & 1) != 0;
            case GLFW_CONTEXT_CREATION_API: return 0x00036002; // GLFW_EGL_CONTEXT_API
            default: break;
        }
    }
    if (amclDesktopHostResolve()) {
        const auto facts = desktopFacts();
        switch (attrib) {
            case GLFW_VISIBLE: return facts.active && facts.status != 3;
            case GLFW_MAXIMIZED: return facts.status == 2;
            case GLFW_RESIZABLE: return facts.resizable;
            case GLFW_DECORATED: return facts.decorated;
            case GLFW_ICONIFIED: return facts.status == 3;
            default: break;
        }
    }
    switch (attrib) {
        case GLFW_FOCUSED: return window->focused;
        case GLFW_VISIBLE: return 1;
        case GLFW_MAXIMIZED: return 1;
        case GLFW_RESIZABLE: return 0;
        case GLFW_DECORATED: return 0;
        case GLFW_FLOATING: return 0;
        case GLFW_CONTEXT_VERSION_MAJOR: return g_hintMajor;
        case GLFW_CONTEXT_VERSION_MINOR: return g_hintMinor;
        default: return 0;
    }
}
void glfwSetWindowAttrib(GLFWwindow* window, int attrib, int value) {
    if (!window) return;
    if (window->auxiliary) return;
    if (attrib == GLFW_RESIZABLE) desktopCommand(AMCL_DESKTOP_RESIZABLE, value);
    else if (attrib == GLFW_DECORATED) desktopCommand(AMCL_DESKTOP_DECORATED, value);
}

void glfwGetWindowContentScale(GLFWwindow* window, float* xscale, float* yscale) {
    if (window && window->auxiliary) { if (xscale) *xscale = 1; if (yscale) *yscale = 1; return; }
    if (amclDesktopHostResolve()) {
        const float scale = amcl::desktop::WindowScale(desktopFacts());
        if (scale > 0) { if (xscale) *xscale=scale; if (yscale) *yscale=scale; return; }
    }
    AmclInputSurfaceContextPayload context{};
    const bool hasDensity = glfwOHOS_ReadInputSurfaceContext(&context) &&
        (context.validFields &
         AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY) != 0u;
    const float scale = hasDensity ? context.density : 1.0f;
    if (xscale) *xscale = scale;
    if (yscale) *yscale = scale;
}
float glfwGetWindowOpacity(GLFWwindow* window) { return 1.0f; }
void glfwSetWindowOpacity(GLFWwindow* window, float opacity) {
    if (amclDesktopHostResolve() && g_errorCallback) g_errorCallback(0x0001000C, "HarmonyOS public Window API does not expose persistent window opacity");
}

void glfwGetWindowFrameSize(GLFWwindow* window, int* left, int* top, int* right, int* bottom) {
    if (window && window->auxiliary) { if (left) *left = 0; if (top) *top = 0; if (right) *right = 0; if (bottom) *bottom = 0; return; }
    if(amclDesktopHostResolve()){const auto f=desktopFacts();if(left)*left=f.frameLeft;if(top)*top=f.frameTop;if(right)*right=f.frameRight;if(bottom)*bottom=f.frameBottom;return;}
    if (left) *left = 0; if (top) *top = 0; if (right) *right = 0; if (bottom) *bottom = 0;
}

// ==================== 监视器 stub ====================
static GLFWvidmode g_defaultMode = { 1080, 2400, 8, 8, 8, 60 };
static GLFWmonitor g_defaultMonitor;

GLFWmonitor* glfwGetWindowMonitor(GLFWwindow* window) {
    if (window && window->auxiliary) return nullptr;
    if (amclDesktopHostResolve()) {
        const auto facts = desktopFacts();
        if (facts.status != 1) return nullptr;
        int count = 0; GLFWmonitor** monitors = glfwGetMonitors(&count);
        for (int i = 0; i < count; ++i) if (monitors[i]->desktopId == facts.displayId) return monitors[i];
        return nullptr;
    }
    // 返回非空 = 告诉 MC 窗口已经是全屏模式
    // MC 检测到已全屏时不会再尝试切换，避免全屏切换导致触摸坐标错乱
    return &g_defaultMonitor;
}
void glfwSetWindowMonitor(GLFWwindow* window, GLFWmonitor* monitor, int xpos, int ypos, int width, int height, int refreshRate) {
    if (window && window->auxiliary) {
        // Minecraft会在ShowWindow之前应用初始monitor。NULL仅是隐藏窗口的布局请求，
        // 不能因此抢呈现权或报错；非NULL是明确全屏请求，沿唯一promotion事务取得呈现权。
        // 第二个窗口想成为presented时仍由broker/registry拒绝，不能绕过单owner约束。
        if (!monitor) return;
        if (!glfwOHOS_PromoteWindow(window)) return;
    }
    if (window && !window->auxiliary && desktopCommand(AMCL_DESKTOP_FULLSCREEN, monitor ? 1 : 0, monitor ? static_cast<int>(monitor->desktopId) : -1, width, height)) {
        if (!monitor) {
            desktopCommand(AMCL_DESKTOP_MOVE, xpos, ypos);
            desktopCommand(AMCL_DESKTOP_RESIZE, width, height);
        }
        return;
    }
    // Mobile compatibility hosts keep their surface-owned geometry.
    // MC 切换"全屏显示"时会调用此函数，传入的 width/height 可能与 EGL surface 不匹配
    // 如果改变窗口尺寸会导致触摸坐标映射错乱，菜单无法点击
    OH_LOG_INFO(LOG_APP, "GLFW: glfwSetWindowMonitor called (ignored) req=%{public}dx%{public}d actual=%{public}dx%{public}d",
                width, height, window ? window->width : 0, window ? window->height : 0);
}

bool glfwOHOS_ApplyInitialMonitor(GLFWwindow* window, GLFWmonitor* monitor, int width, int height) {
    if (!window || !monitor) return true;
    const auto* host = amclDesktopHostResolve();
    if (!host) {
        if (!amcl::desktop::NativeGlRequested()) return true;
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "Desktop window service is unavailable for initial fullscreen");
        return false;
    }
    // Submission is transactional; glfwGetWindowMonitor continues to read actual host facts.
    if (!host->submit(AMCL_DESKTOP_FULLSCREEN, 1, static_cast<int>(monitor->desktopId), width, height, nullptr)) {
        if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, "Initial fullscreen request rejected (inactive or full queue)");
        return false;
    }
    return true;
}

static GLFWmonitor g_desktopMonitors[AMCL_DESKTOP_MAX_DISPLAYS]{};
static GLFWmonitor* g_desktopMonitorPointers[AMCL_DESKTOP_MAX_DISPLAYS]{};
static bool g_desktopMonitorActive[AMCL_DESKTOP_MAX_DISPLAYS]{};
static bool g_desktopMonitorInitialized = false;
static int g_desktopMonitorCount = 0;
static GLFWmonitorfun g_desktopMonitorCallback = nullptr;
void glfwOHOS_PrimeDesktopWindow(GLFWwindow* window) {
    if (window && amclDesktopHostResolve()) amcl::desktop::ObserveWindow(window->desktopObservation, desktopFacts());
}
static void pollDesktopWindow(const AmclDesktopSnapshot& facts) {
    GLFWwindow* window = g_currentWindow;
    if (!window) return;
    const unsigned changes = amcl::desktop::ObserveWindow(window->desktopObservation, facts);
    if ((changes & amcl::desktop::WindowMoved) && window->positionCb) window->positionCb(window,facts.x,facts.y);
    if (window != g_currentWindow) return;
    if ((changes & amcl::desktop::WindowIconified) && window->iconifyCb) window->iconifyCb(window,facts.status==3);
    if (window != g_currentWindow) return;
    if ((changes & amcl::desktop::WindowMaximized) && window->maximizeCb) window->maximizeCb(window,facts.status==2);
    if (window != g_currentWindow) return;
    if ((changes & amcl::desktop::WindowScaleChanged) && window->contentScaleCb)
        window->contentScaleCb(window,window->desktopObservation.scale,window->desktopObservation.scale);
    if (window != g_currentWindow) return;
    if ((changes & amcl::desktop::WindowRefresh) && window->refreshCb) window->refreshCb(window);
    if (window != g_currentWindow) return;
    const auto* host = amclDesktopHostResolve();
    if (!host) return;
    static thread_local std::vector<char> packet(65536);
    for (int batch=0; batch<8 && window==g_currentWindow; ++batch) {
        const int bytes = host->takeDrop(packet.data(), packet.size());
        if (bytes <= 0) break;
        const char* paths[32];
        const int count = amclDecodeDesktopDrop(packet.data(), bytes, paths, 32);
        if (count > 0 && window->dropCb) window->dropCb(window,count,paths);
    }
}
void glfwOHOS_PollDesktopDisplays() {
    if (!amclDesktopHostResolve()) return;
    pollDesktopPads();
    const auto facts = desktopFacts();
    const bool notify = g_desktopMonitorInitialized;
    for (int slot = 0; slot < AMCL_DESKTOP_MAX_DISPLAYS; ++slot) {
        if (!g_desktopMonitorActive[slot]) continue;
        bool found = false;
        for (int i = 0; i < facts.displayCount; ++i)
            if (g_desktopMonitors[slot].desktopId == facts.displays[i].id) found = true;
        if (!found) {
            g_desktopMonitorActive[slot] = false;
            if (notify && g_desktopMonitorCallback) g_desktopMonitorCallback(&g_desktopMonitors[slot], 0x00040002);
            g_desktopMonitors[slot].userPointer = nullptr;
        }
    }
    g_desktopMonitorCount = 0;
    for (int i = 0; i < facts.displayCount; ++i) {
        int slot = -1;
        for (int j = 0; j < AMCL_DESKTOP_MAX_DISPLAYS; ++j)
            if (g_desktopMonitorActive[j] && g_desktopMonitors[j].desktopId == facts.displays[i].id) { slot = j; break; }
        bool added = false;
        if (slot < 0) for (int j = 0; j < AMCL_DESKTOP_MAX_DISPLAYS; ++j) if (!g_desktopMonitorActive[j]) {
            slot = j; added = true; g_desktopMonitorActive[j] = true;
            g_desktopMonitors[j].desktopId = facts.displays[i].id; break;
        }
        if (slot < 0) continue;
        g_desktopMonitorPointers[g_desktopMonitorCount++] = &g_desktopMonitors[slot];
        if (notify && added && g_desktopMonitorCallback) g_desktopMonitorCallback(&g_desktopMonitors[slot], 0x00040001);
    }
    g_desktopMonitorInitialized = true;
    pollDesktopWindow(facts);
}
static int desktopMonitors() {
    if (!g_desktopMonitorInitialized) glfwOHOS_PollDesktopDisplays();
    return g_desktopMonitorCount;
}
static bool desktopMonitor(GLFWmonitor* monitor, AmclDesktopDisplay& result) {
    if (!amclDesktopHostResolve() || !monitor) return false;
    const auto facts = desktopFacts();
    for (int i = 0; i < facts.displayCount; ++i) if (facts.displays[i].id == monitor->desktopId) {
        result = facts.displays[i]; return true;
    }
    return false;
}
GLFWmonitor* glfwGetPrimaryMonitor(void) {
    if (amclDesktopHostResolve()) return desktopMonitors() ? g_desktopMonitorPointers[0] : nullptr;
    return &g_defaultMonitor;
}
GLFWmonitor** glfwGetMonitors(int* count) {
    if (amclDesktopHostResolve()) { const int size = desktopMonitors(); if (count) *count = size; return size ? g_desktopMonitorPointers : nullptr; }
    static GLFWmonitor* monitors[] = { &g_defaultMonitor };
    if (count) *count = 1;
    return monitors;
}
const GLFWvidmode* glfwGetVideoMode(GLFWmonitor* monitor) {
    if (amclDesktopHostResolve()) {
        AmclDesktopDisplay display{};
        if (!desktopMonitor(monitor, display)) return nullptr;
        static thread_local GLFWvidmode modes[AMCL_DESKTOP_MAX_DISPLAYS];
        const int slot=static_cast<int>(monitor-g_desktopMonitors);
        if(slot<0 || slot>=AMCL_DESKTOP_MAX_DISPLAYS)return nullptr;
        auto& mode=modes[slot];
        mode = {display.width, display.height, 8, 8, 8, static_cast<int>(std::lround(display.refreshRate))};
        return &mode;
    }
    g_defaultMode.width = 1080;
    g_defaultMode.height = 2400;
    g_defaultMode.redBits = 8;
    g_defaultMode.greenBits = 8;
    g_defaultMode.blueBits = 8;
    g_defaultMode.refreshRate = 60;
    AmclInputSurfaceContextPayload context{};
    if (glfwOHOS_ReadInputSurfaceContext(&context)) {
        if ((context.validFields &
             AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT) != 0u) {
            g_defaultMode.width = static_cast<int>(context.widthPx);
            g_defaultMode.height = static_cast<int>(context.heightPx);
        }
        if ((context.validFields &
             AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE) != 0u) {
            g_defaultMode.refreshRate =
                static_cast<int>(std::lround(context.refreshRateHz));
        }
    }
    return &g_defaultMode;
}
const GLFWvidmode* glfwGetVideoModes(GLFWmonitor* monitor, int* count) {
    const GLFWvidmode* mode = glfwGetVideoMode(monitor);
    if (count) *count = mode ? 1 : 0;
    return mode;
}
void glfwGetMonitorPos(GLFWmonitor* monitor, int* xpos, int* ypos) {
    AmclDesktopDisplay d{}; if (desktopMonitor(monitor, d)) { if (xpos) *xpos=d.x; if (ypos) *ypos=d.y; return; }
    if (xpos) *xpos = 0; if (ypos) *ypos = 0;
}
void glfwGetMonitorWorkarea(GLFWmonitor* monitor, int* xpos, int* ypos, int* width, int* height) {
    AmclDesktopDisplay d{}; if (desktopMonitor(monitor, d)) { if(xpos)*xpos=d.workX; if(ypos)*ypos=d.workY; if(width)*width=d.workWidth; if(height)*height=d.workHeight; return; }
    if (xpos) *xpos = 0; if (ypos) *ypos = 0;
    if (width) *width = amclDesktopHostResolve() ? 0 : 1080; if (height) *height = amclDesktopHostResolve() ? 0 : 2400;
}
void glfwGetMonitorPhysicalSize(GLFWmonitor* monitor, int* widthMM, int* heightMM) {
    AmclDesktopDisplay d{}; if (desktopMonitor(monitor, d)) { if(widthMM)*widthMM=static_cast<int>(std::lround(d.widthMM)); if(heightMM)*heightMM=static_cast<int>(std::lround(d.heightMM)); return; }
    if (widthMM) *widthMM = amclDesktopHostResolve() ? 0 : 70; if (heightMM) *heightMM = amclDesktopHostResolve() ? 0 : 155;
}
void glfwGetMonitorContentScale(GLFWmonitor* monitor, float* xscale, float* yscale) {
    AmclDesktopDisplay d{}; if (desktopMonitor(monitor, d)) { if(xscale)*xscale=d.scale; if(yscale)*yscale=d.scale; return; }
    if (xscale) *xscale = 1.0f; if (yscale) *yscale = 1.0f;
}
const char* glfwGetMonitorName(GLFWmonitor* monitor) {
    static thread_local AmclDesktopDisplay names[AMCL_DESKTOP_MAX_DISPLAYS];
    if(amclDesktopHostResolve() && monitor){
        for(int slot=0;slot<AMCL_DESKTOP_MAX_DISPLAYS;++slot)if(monitor==&g_desktopMonitors[slot] && desktopMonitor(monitor,names[slot]))return names[slot].name;
        return nullptr;
    }
    return "OHOS Display";
}
GLFWmonitorfun glfwSetMonitorCallback(GLFWmonitorfun callback) {
    if (amclDesktopHostResolve()) desktopMonitors();
    GLFWmonitorfun previous = g_desktopMonitorCallback; g_desktopMonitorCallback = callback; return previous;
}

void glfwSetMonitorUserPointer(GLFWmonitor* monitor, void* pointer) { if(monitor)monitor->userPointer=pointer; }
void* glfwGetMonitorUserPointer(GLFWmonitor* monitor) { return monitor ? monitor->userPointer : nullptr; }

void glfwSetGamma(GLFWmonitor* monitor, float gamma) { }
const void* glfwGetGammaRamp(GLFWmonitor* monitor) { return nullptr; }
void glfwSetGammaRamp(GLFWmonitor* monitor, const void* ramp) { }

// ==================== GLFW 3.3+ 新增 stub ====================
static int g_platformHint = GLFW_ANY_PLATFORM;
void glfwInitHint(int hint, int value) {
    if (hint == GLFW_PLATFORM) g_platformHint = value;
    OH_LOG_INFO(LOG_APP, "GLFW: glfwInitHint hint=%d value=%d", hint, value);
}
void glfwInitAllocator(const void* allocator) { }

static int g_lastError = 0;
static const char* g_lastErrorDesc = nullptr;
int glfwGetError(const char** description) {
    if (description) *description = g_lastErrorDesc;
    int err = g_lastError;
    g_lastError = 0;
    g_lastErrorDesc = nullptr;
    return err;
}

// GLFW owns a virtual window; OHOS supplies the external NativeWindow. It exposes
// none of the Cocoa/X11/Wayland native-window APIs, so use the official NULL enum.
int glfwGetPlatform(void) { return GLFW_PLATFORM_NULL; }
int glfwPlatformSupported(int platform) { return platform == GLFW_PLATFORM_NULL ? GLFW_TRUE : GLFW_FALSE; }
bool glfwOHOS_ValidatePlatformHint() {
    if (g_platformHint == GLFW_ANY_PLATFORM || glfwPlatformSupported(g_platformHint)) return true;
    g_lastError = GLFW_PLATFORM_UNAVAILABLE;
    g_lastErrorDesc = "OHOS host window does not provide the requested GLFW native platform";
    if (g_errorCallback) g_errorCallback(g_lastError, g_lastErrorDesc);
    return false;
}

void glfwWindowHintString(int hint, const char* value) {
    OH_LOG_INFO(LOG_APP, "GLFW: glfwWindowHintString hint=%d value=%s", hint, value ? value : "null");
}

// ==================== GLFW IME/preedit 扩展（LWJGL 3.4 fork）====================
static GlfwPreeditState* ensurePreeditState(GLFWwindow* window) {
    if (!window) return nullptr;
    if (!window->preeditState) window->preeditState = new GlfwPreeditState();
    return window->preeditState;
}

static void dispatchPreedit(GLFWwindow* window) {
    if (!window || !window->preeditCb) return;
    GlfwPreeditState* state = ensurePreeditState(window);
    if (!state) return;
    int blockSize = static_cast<int>(state->text.size());
    const int blockCount = state->text.empty() ? 0 : 1;
    const int caret = state->selectionStart + state->selectionLength;
    window->preeditCb(
        window, static_cast<int>(state->text.size()),
        state->text.empty() ? nullptr : state->text.data(), blockCount,
        blockCount == 0 ? nullptr : &blockSize,
        blockCount == 0 ? -1 : 0, caret);
}

GLFWpreeditfun glfwSetPreeditCallback(
        GLFWwindow* window, GLFWpreeditfun cbfun) {
    if (!window) return nullptr;
    GLFWpreeditfun old = window->preeditCb;
    window->preeditCb = cbfun;
    return old;
}

GLFWimestatusfun glfwSetIMEStatusCallback(
        GLFWwindow* window, GLFWimestatusfun cbfun) {
    if (!window) return nullptr;
    GLFWimestatusfun old = window->imeStatusCb;
    window->imeStatusCb = cbfun;
    return old;
}

GLFWpreeditcandidatefun glfwSetPreeditCandidateCallback(
        GLFWwindow* window, GLFWpreeditcandidatefun cbfun) {
    if (!window) return nullptr;
    GLFWpreeditcandidatefun old = window->preeditCandidateCb;
    window->preeditCandidateCb = cbfun;
    return old;
}
void glfwGetPreeditCursorRectangle(GLFWwindow* window, int* x, int* y, int* w, int* h) {
    GlfwPreeditState* state = ensurePreeditState(window);
    if (x) *x = state ? state->x : 0;
    if (y) *y = state ? state->y : 0;
    if (w) *w = state ? state->width : 0;
    if (h) *h = state ? state->height : 0;
}
void glfwSetPreeditCursorRectangle(
        GLFWwindow* window, int x, int y, int w, int h) {
    GlfwPreeditState* state = ensurePreeditState(window);
    if (!state) return;
    state->x = x;
    state->y = y;
    state->width = w;
    state->height = h;
}
void glfwResetPreeditText(GLFWwindow* window) {
    glfwOHOS_ResetPreedit(window, true);
}
unsigned int* glfwGetPreeditCandidate(GLFWwindow* window, int index, int* textCount) {
    if (textCount) *textCount = 0;
    if (!window || !window->preeditState || index < 0 ||
        static_cast<size_t>(index) >=
            window->preeditState->candidates.size()) {
        return nullptr;
    }
    std::vector<unsigned int>& value =
        window->preeditState->candidates[static_cast<size_t>(index)];
    if (textCount) *textCount = static_cast<int>(value.size());
    return value.empty() ? nullptr : value.data();
}

void glfwOHOS_UpdatePreedit(
        GLFWwindow* window, const std::vector<unsigned int>& text,
        int selectionStart, int selectionLength) {
    GlfwPreeditState* state = ensurePreeditState(window);
    if (!state) return;
    state->text = text;
    state->selectionStart = selectionStart;
    state->selectionLength = selectionLength;
    dispatchPreedit(window);
}

bool glfwOHOS_UpdatePreeditSelection(
        GLFWwindow* window, int selectionStart, int selectionLength) {
    if (!window || !window->preeditState ||
        window->preeditState->text.empty()) {
        return false;
    }
    const size_t start = static_cast<size_t>(selectionStart);
    const size_t length = static_cast<size_t>(selectionLength);
    if (selectionStart < 0 || selectionLength < 0 ||
        start > window->preeditState->text.size() ||
        length > window->preeditState->text.size() - start) {
        return false;
    }
    window->preeditState->selectionStart = selectionStart;
    window->preeditState->selectionLength = selectionLength;
    dispatchPreedit(window);
    return true;
}

void glfwOHOS_UpdatePreeditCandidates(
        GLFWwindow* window,
        const std::vector<std::vector<unsigned int>>& candidates,
        int selectedIndex, int pageStart, int pageSize) {
    GlfwPreeditState* state = ensurePreeditState(window);
    if (!state) return;
    state->candidates = candidates;
    if (window->preeditCandidateCb) {
        window->preeditCandidateCb(
            window, static_cast<int>(state->candidates.size()),
            selectedIndex, pageStart, pageSize);
    }
}

void glfwOHOS_NotifyImeStatus(GLFWwindow* window) {
    if (window && window->imeStatusCb) window->imeStatusCb(window);
}

void glfwOHOS_ResetPreedit(GLFWwindow* window, bool notify) {
    if (!window || !window->preeditState) return;
    window->preeditState->text.clear();
    window->preeditState->candidates.clear();
    window->preeditState->selectionStart = 0;
    window->preeditState->selectionLength = 0;
    if (!notify) return;
    dispatchPreedit(window);
    if (window->preeditCandidateCb) {
        window->preeditCandidateCb(window, 0, 0, 0, 0);
    }
}

void glfwOHOS_DestroyPreeditState(GLFWwindow* window) {
    if (!window) return;
    delete window->preeditState;
    window->preeditState = nullptr;
}

// Timer
unsigned long long glfwGetTimerValue(void) {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count();
}
unsigned long long glfwGetTimerFrequency(void) { return 1000000000ULL; }

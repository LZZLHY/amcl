/**
 * HarmonyOS 触摸/键鼠桥：实际加载器首次使用本类时完成专用 JNI 绑定。
 *
 * Java sendXxx → input_bridge_ohos.c → 既有输入队列 → 游戏事件泵；本类不创建另一套输入
 * owner，也不提前初始化 LWJGL。派生自 Pojav 的接口仅保留兼容外形：未移植的共享手柄
 * 缓冲区明确返回 null，不能用伪缓冲区把 native 绑定失败或缺失能力伪装成输入就绪。
 */
package org.lwjgl.glfw;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

public class CallbackBridge {
    // Clipboard actions
    public static final int CLIPBOARD_COPY = 2000;
    public static final int CLIPBOARD_PASTE = 2001;

    // Event types (must match input_bridge_ohos.c)
    public static final int EVENT_TYPE_CHAR = 1000;
    public static final int EVENT_TYPE_CHAR_MODS = 1001;
    public static final int EVENT_TYPE_CURSOR_ENTER = 1002;
    public static final int EVENT_TYPE_KEY = 1005;
    public static final int EVENT_TYPE_MOUSE_BUTTON = 1006;
    public static final int EVENT_TYPE_SCROLL = 1007;

    // For Pojav compatibility
    public static final int ANDROID_TYPE_GRAB_STATE = 2002;
    public static final boolean INPUT_DEBUG_ENABLED = false;

    // Window dimensions (set from native side)
    public static volatile int windowWidth, windowHeight;
    public static volatile int physicalWidth, physicalHeight;

    // Cursor position
    public static float mouseX, mouseY;

    // Modifier key state
    public volatile static boolean holdingAlt, holdingCapslock, holdingCtrl,
            holdingNumlock, holdingShift;

    // Grab state
    private static boolean isGrabbing = false;

    // 旧共享手柄缓冲区协议未实现；与 typed/GLFW/SDL 自身的手柄支持是不同能力。
    public static boolean sGamepadDirectEnabled = false;
    public static final boolean GAMEPAD_SHARED_BUFFER_SUPPORTED;
    public static final ByteBuffer sGamepadButtonBuffer;
    public static final FloatBuffer sGamepadAxisBuffer;

    // ============================================================
    //  Public API: send events from Java side
    // ============================================================

    public static void sendCursorPos(float x, float y) {
        mouseX = x;
        mouseY = y;
        nativeSendCursorPos(mouseX, mouseY);
    }

    public static void sendMouseButton(int button, boolean status) {
        sendMouseKeycode(button, getCurrentMods(), status);
    }

    public static void sendMouseKeycode(int button, int modifiers, boolean isDown) {
        nativeSendMouseButton(button, isDown ? 1 : 0, modifiers);
    }

    public static void sendMouseKeycode(int keycode) {
        sendMouseKeycode(keycode, getCurrentMods(), true);
        sendMouseKeycode(keycode, getCurrentMods(), false);
    }

    public static void putMouseEventWithCoords(int button, float x, float y) {
        sendCursorPos(x, y);
        sendMouseKeycode(button, getCurrentMods(), true);
        // Schedule release after ~33ms (one frame at 30fps)
        // On OHOS we do immediate release since we don't have Choreographer
        sendMouseKeycode(button, getCurrentMods(), false);
    }

    public static void putMouseEventWithCoords(int button, boolean isDown, float x, float y) {
        sendCursorPos(x, y);
        sendMouseKeycode(button, getCurrentMods(), isDown);
    }

    public static void sendKeycode(int keycode, char keychar, int scancode, int modifiers, boolean isDown) {
        if (keycode != 0) nativeSendKey(keycode, scancode, isDown ? 1 : 0, modifiers);
        if (isDown && keychar != '\u0000') {
            nativeSendCharMods(keychar, modifiers);
            nativeSendChar(keychar);
        }
    }

    public static void sendChar(char keychar, int modifiers) {
        nativeSendCharMods(keychar, modifiers);
        nativeSendChar(keychar);
    }

    public static void sendKeyPress(int keyCode, int modifiers, boolean status) {
        sendKeyPress(keyCode, 0, modifiers, status);
    }

    public static void sendKeyPress(int keyCode, int scancode, int modifiers, boolean status) {
        sendKeyPress(keyCode, '\u0000', scancode, modifiers, status);
    }

    public static void sendKeyPress(int keyCode, char keyChar, int scancode, int modifiers, boolean status) {
        sendKeycode(keyCode, keyChar, scancode, modifiers, status);
    }

    public static void sendKeyPress(int keyCode) {
        sendKeyPress(keyCode, getCurrentMods(), true);
        sendKeyPress(keyCode, getCurrentMods(), false);
    }

    public static void sendScroll(double xoffset, double yoffset) {
        nativeSendScroll(xoffset, yoffset);
    }

    public static void sendUpdateWindowSize(int w, int h) {
        nativeSendScreenSize(w, h);
    }

    // ============================================================
    //  Grab state
    // ============================================================

    public static boolean isGrabbing() {
        return isGrabbing;
    }

    // Called from native side via JNI
    @SuppressWarnings("unused")
    private static void onGrabStateChanged(final boolean grabbing) {
        isGrabbing = grabbing;
        System.out.println("CallbackBridge: Grab changed: " + grabbing);
    }

    // ============================================================
    //  Modifier keys
    // ============================================================

    public static int getCurrentMods() {
        int currMods = 0;
        if (holdingAlt)      currMods |= 0x0004; // GLFW_MOD_ALT
        if (holdingCapslock)  currMods |= 0x0010; // GLFW_MOD_CAPS_LOCK
        if (holdingCtrl)     currMods |= 0x0002; // GLFW_MOD_CONTROL
        if (holdingNumlock)  currMods |= 0x0020; // GLFW_MOD_NUM_LOCK
        if (holdingShift)    currMods |= 0x0001; // GLFW_MOD_SHIFT
        return currMods;
    }

    public static void setModifiers(int keyCode, boolean isDown) {
        switch (keyCode) {
            case 340: // GLFW_KEY_LEFT_SHIFT
                holdingShift = isDown; return;
            case 341: // GLFW_KEY_LEFT_CONTROL
                holdingCtrl = isDown; return;
            case 342: // GLFW_KEY_LEFT_ALT
                holdingAlt = isDown; return;
            case 280: // GLFW_KEY_CAPS_LOCK
                holdingCapslock = isDown; return;
            case 282: // GLFW_KEY_NUM_LOCK
                holdingNumlock = isDown; return;
        }
    }

    // ============================================================
    //  Gamepad (stub)
    // ============================================================

    public static void enableGamepadDirectInput() {
        // native 当前明确返回 false；不能仅凭调用 enable 就对外宣称缓冲区通路可用。
        sGamepadDirectEnabled = GAMEPAD_SHARED_BUFFER_SUPPORTED && nativeEnableGamepadDirectInput();
    }

    @SuppressWarnings("unused")
    private static void onDirectInputEnable() {
        enableGamepadDirectInput();
    }

    public static FloatBuffer createGamepadAxisBuffer() {
        // null 是 native 已声明的“不支持”，不是初始化异常；由调用者检查能力标志。
        ByteBuffer axisByteBuffer = nativeCreateGamepadAxisBuffer();
        return axisByteBuffer == null ? null : axisByteBuffer.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();
    }

    // Pojav compatibility
    public static void sendData(int type, String data) {
        nativeSendData(false, type, data);
    }

    // ============================================================
    //  Native methods (implemented in input_bridge_ohos.c)
    // ============================================================

    private static native boolean nativeSendChar(char codepoint);
    private static native boolean nativeSendCharMods(char codepoint, int mods);
    private static native void nativeSendKey(int key, int scancode, int action, int mods);
    // 多键轮询查询（2026-05-30）：读 native 维护的按住状态，供 GLFW.glfwGetKey/glfwGetMouseButton。
    static native int nativeGetKeyDown(int key);
    static native int nativeGetMouseDown(int button);
    private static native void nativeSendCursorPos(float x, float y);
    private static native void nativeSendMouseButton(int button, int action, int mods);
    private static native void nativeSendScroll(double xoffset, double yoffset);
    private static native void nativeSendScreenSize(int width, int height);

    public static native void nativeSetUseInputStackQueue(boolean useInputStackQueue);
    public static native boolean nativeSetInputReady(boolean inputReady);
    public static native String nativeClipboard(int action, byte[] copySrc);
    public static native void nativeSetGrabbing(boolean grabbing);
    public static native void nativeSetWindowAttrib(int attrib, int value);

    public static native void nativeSendData(boolean useStackQueue, int type, String data);
    private static native ByteBuffer nativeCreateGamepadButtonBuffer();
    private static native ByteBuffer nativeCreateGamepadAxisBuffer();
    private static native boolean nativeEnableGamepadDirectInput();

    // ============================================================
    //  Static initializer
    // ============================================================

    static {
        // 首次 native 调用前同步加载专用 bridge。JNI_OnLoad 在本类所属加载器的上下文中
        // 取得当前 Class 并注册全部自有 native；失败必须终止 <clinit>，不可吞异常继续启动。
        // java.library.path 已由宿主在创建 JVM 前冻结；不另开路径、不复制/改名同一 JNI 库。
        System.loadLibrary("jni_reregister");
        sGamepadButtonBuffer = nativeCreateGamepadButtonBuffer();
        sGamepadAxisBuffer = createGamepadAxisBuffer();
        GAMEPAD_SHARED_BUFFER_SUPPORTED = sGamepadButtonBuffer != null && sGamepadAxisBuffer != null;
    }
}

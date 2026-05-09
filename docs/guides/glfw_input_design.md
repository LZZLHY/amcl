# HarmonyOS GLFW Input System Design

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│ HarmonyOS ArkTS Layer                               │
│                                                     │
│  McGamePage.ets                                     │
│    XComponent.onTouch → NAPI sendTouchEvent()       │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│ Native C Layer (input_bridge_ohos.c)                │
│                                                     │
│  Ring Buffer (lock-free, atomic counter)            │
│  ┌─────────────────────────────────────────┐        │
│  │ events[4096] - GLFWInputEvent structs   │        │
│  │ cursorX, cursorY - atomic doubles       │        │
│  │ eventCounter - atomic size_t            │        │
│  └─────────────────────────────────────────┘        │
│                                                     │
│  NAPI entry: sendTouchEvent(x,y,action)             │
│    → updates cursorX/cursorY                        │
│    → pushes MOUSE_BUTTON events to ring buffer      │
│                                                     │
│  JNI functions (called from MC's JVM):              │
│    Java_org_lwjgl_glfw_CallbackBridge_nativeSendXxx │
│    Java_org_lwjgl_glfw_GLFW_nglfwSetXxxCallback     │
│    Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos       │
│                                                     │
│  Callback function pointers:                        │
│    GLFW_invoke_CursorPos, GLFW_invoke_MouseButton   │
│    GLFW_invoke_Key, GLFW_invoke_Scroll, etc.        │
│                                                     │
│  Pump functions (called from glfwPollEvents):       │
│    pojavStartPumping() → snapshot event count       │
│    pojavPumpEvents()   → dispatch to callbacks      │
│    pojavStopPumping()  → advance read index         │
└──────────────────────▲──────────────────────────────┘
                       │
┌──────────────────────┴──────────────────────────────┐
│ Java Layer (custom lwjgl-glfw-ohos.jar)             │
│                                                     │
│  org.lwjgl.glfw.GLFW                                │
│    glfwPollEvents() → native pojavStartPumping()    │
│                     → native pojavPumpEvents(window) │
│                     → native pojavStopPumping()     │
│    glfwSetMouseButtonCallback() → native nglfwSet.. │
│    glfwCreateWindow() → native, returns window ptr  │
│    glfwSwapBuffers() → native EGL swap              │
│    glfwInit/Terminate/WindowHint etc.               │
│                                                     │
│  org.lwjgl.glfw.CallbackBridge                      │
│    sendCursorPos(x,y) → nativeSendCursorPos()       │
│    sendMouseButton()  → nativeSendMouseButton()     │
│    sendKeycode()      → nativeSendKey()             │
│    nativeSetInputReady() / nativeSetGrabbing()      │
│    Clipboard: nativeClipboard() → OHOS clipboard    │
│                                                     │
│  All GLFW callback wrapper classes (from LWJGL):    │
│    GLFWKeyCallback, GLFWMouseButtonCallback, etc.   │
│    These are unchanged from standard LWJGL          │
└─────────────────────────────────────────────────────┘
```

## Key Differences from Pojav

| Aspect | Pojav (Android) | MC-OHOS (HarmonyOS) |
|--------|----------------|---------------------|
| JVM count | 2 (Dalvik + MC JVM) | 1 (MC JVM only) |
| Touch source | Android View.onTouchEvent | XComponent.onTouch via NAPI |
| Native lib name | libpojavexec.so | libglfw.so (reuse existing) |
| Clipboard | Android ClipboardManager | OHOS pasteboard API |
| Choreographer | Android Choreographer | Not needed (single JVM) |
| Grab state | JNI callback to Dalvik | Direct flag in C |

## Files to Create/Modify

### New Files:
1. `entry/src/main/cpp/glfw/input_bridge_ohos.c` — Core input bridge
2. `jre_lwjgl3glfw/org/lwjgl/glfw/CallbackBridge.java` — OHOS CallbackBridge
3. `jre_lwjgl3glfw/org/lwjgl/glfw/GLFW.java` — Custom GLFW main class

### Modified Files:
1. `entry/src/main/cpp/CMakeLists.txt` — Add input_bridge to libglfw.so
2. `entry/src/main/cpp/glfw/glfw_compat.cpp` — Keep EGL, delegate input to bridge
3. `entry/src/main/resources/rawfile/lwjgl/lwjgl-glfw.jar` — Replace with custom

## Implementation Order

1. input_bridge_ohos.c (C native layer)
2. CallbackBridge.java (Java bridge)  
3. GLFW.java (Java GLFW implementation)
4. Compile lwjgl-glfw-ohos.jar
5. Integration & testing

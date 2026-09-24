#ifndef AMCL_BACKEND_KEYMAPS_H
#define AMCL_BACKEND_KEYMAPS_H

#include "glfw_input_adapter.h"

namespace amcl::input {

// LWJGL2 后端（MC ≤1.12）的 raw OHOS identity → `org.lwjgl.input.Keyboard.KEY_*`
// （DirectInput 扫描码）。⚠️ 与 `GlfwOhosInputMapper()` 是**并列**关系，不是它的下游：
// 旧链是 OHOS→GLFW→DirectInput 两跳，这里一跳到底。逐条等价由
// `scripts/check-backend-keymap-parity.mjs` 钉住（新表 == 旧两步的复合）。
GlfwInputMapper Lwjgl2OhosInputMapper();

// SDL3 后端（MC 26.3+）的 raw OHOS identity → SDL_Scancode（USB HID 位置码，上游类型）。
// 同上：一跳到底，等价关系由同一道门禁钉住。
GlfwInputMapper Sdl3OhosInputMapper();

}  // namespace amcl::input

#endif

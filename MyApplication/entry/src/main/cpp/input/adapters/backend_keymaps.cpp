#include "backend_keymaps.h"

#include <climits>

// ============================================================================
// 三个后端各自的 raw OHOS identity → 自己那套编码。**每个后端只翻一次。**
//
// 旧架构把物理键先压成 GLFW 编码写进 legacy ring，LWJGL2 与 SDL3 再各自翻第二次
// （AMCLDisplay.glfwToLwjgl2Key（Java）/ OPENHARMONY_ScancodeFromGlfwKey（SDL patch））。那条二次翻译
// 是计划 §一 约束 4 明令禁止的形状，而且第一次翻译是**有损**的：
// `GLFWInputEvent{type,i1..i4}` 装不下 timestamp / deviceId / 真实 scancode / repeat /
// 连续滚轮，而这些恰是 SDL3 需要的。
//
// ⚠️ 本文件的表**不是手写的**：它们由
// `node scripts/check-backend-keymap-parity.mjs --emit=<backend>` 按"旧两步的复合"
// 生成，再由同一道门禁反向校验（新表[ohos] == 第二步[第一步[ohos]]）。改这里之前先读
// 那个脚本的头部 —— 手改一条而不更新旧链，门禁会红；两边一起改则是**故意改行为**，
// 那需要单独一批与真机复测，不属于迁移。
//
// ⚠️ 两张表的条目数**不同**（LWJGL2 105 / SDL3 106），差的那一条是 PRINT_SCREEN：
// glfwToLwjgl2Key（Java 侧）没有 GLFW 283 的 case（LWJGL2 的 `Keyboard` 里没有对应键位），
// 而 SDL 有 SDL_SCANCODE_PRINTSCREEN。这是**旧链既有的**差异，迁移不改它。
// ============================================================================

namespace amcl::input {
namespace {

// ⚠️ 墓碑: ScanCodeFor 已删除（它是 `MapOhosKey` 里那份 fallback 链的第二份副本，只是恰好
// 等价 —— 与 §91 收敛滚轮分格前的形状逐字相同），现在三个 mapper 共用
// `ScanCodeFromOhosIdentity`，详见计划 §106.1

bool Lwjgl2MapOhosKey(void*, uint64_t, uint32_t physicalKey,
                      uint32_t hardwareScanCode, uint32_t hidUsage,
                      GlfwMappedKey* outKey) {
    if (!outKey) return false;
    int32_t mapped = 0;
    {
        switch (physicalKey) {
            case 2000u: mapped = 11; break;
            case 2001u: mapped = 2; break;
            case 2002u: mapped = 3; break;
            case 2003u: mapped = 4; break;
            case 2004u: mapped = 5; break;
            case 2005u: mapped = 6; break;
            case 2006u: mapped = 7; break;
            case 2007u: mapped = 8; break;
            case 2008u: mapped = 9; break;
            case 2009u: mapped = 10; break;
            case 2012u: mapped = 200; break;
            case 2013u: mapped = 208; break;
            case 2014u: mapped = 203; break;
            case 2015u: mapped = 205; break;
            case 2016u: mapped = 28; break;
            case 2017u: mapped = 30; break;
            case 2018u: mapped = 48; break;
            case 2019u: mapped = 46; break;
            case 2020u: mapped = 32; break;
            case 2021u: mapped = 18; break;
            case 2022u: mapped = 33; break;
            case 2023u: mapped = 34; break;
            case 2024u: mapped = 35; break;
            case 2025u: mapped = 23; break;
            case 2026u: mapped = 36; break;
            case 2027u: mapped = 37; break;
            case 2028u: mapped = 38; break;
            case 2029u: mapped = 50; break;
            case 2030u: mapped = 49; break;
            case 2031u: mapped = 24; break;
            case 2032u: mapped = 25; break;
            case 2033u: mapped = 16; break;
            case 2034u: mapped = 19; break;
            case 2035u: mapped = 31; break;
            case 2036u: mapped = 20; break;
            case 2037u: mapped = 22; break;
            case 2038u: mapped = 47; break;
            case 2039u: mapped = 17; break;
            case 2040u: mapped = 45; break;
            case 2041u: mapped = 21; break;
            case 2042u: mapped = 44; break;
            case 2043u: mapped = 51; break;
            case 2044u: mapped = 52; break;
            case 2045u: mapped = 56; break;
            case 2046u: mapped = 184; break;
            case 2047u: mapped = 42; break;
            case 2048u: mapped = 54; break;
            case 2049u: mapped = 15; break;
            case 2050u: mapped = 57; break;
            case 2054u: mapped = 28; break;
            case 2055u: mapped = 14; break;
            case 2056u: mapped = 41; break;
            case 2057u: mapped = 12; break;
            case 2058u: mapped = 13; break;
            case 2059u: mapped = 26; break;
            case 2060u: mapped = 27; break;
            case 2061u: mapped = 43; break;
            case 2062u: mapped = 39; break;
            case 2063u: mapped = 40; break;
            case 2064u: mapped = 53; break;
            case 2067u: mapped = 221; break;
            case 2068u: mapped = 201; break;
            case 2069u: mapped = 209; break;
            case 2070u: mapped = 1; break;
            case 2071u: mapped = 211; break;
            case 2072u: mapped = 29; break;
            case 2073u: mapped = 157; break;
            case 2074u: mapped = 58; break;
            case 2075u: mapped = 70; break;
            case 2076u: mapped = 219; break;
            case 2077u: mapped = 220; break;
            case 2080u: mapped = 197; break;
            case 2081u: mapped = 199; break;
            case 2082u: mapped = 207; break;
            case 2083u: mapped = 210; break;
            case 2090u: mapped = 59; break;
            case 2091u: mapped = 60; break;
            case 2092u: mapped = 61; break;
            case 2093u: mapped = 62; break;
            case 2094u: mapped = 63; break;
            case 2095u: mapped = 64; break;
            case 2096u: mapped = 65; break;
            case 2097u: mapped = 66; break;
            case 2098u: mapped = 67; break;
            case 2099u: mapped = 68; break;
            case 2100u: mapped = 87; break;
            case 2101u: mapped = 88; break;
            case 2102u: mapped = 69; break;
            case 2103u: mapped = 82; break;
            case 2104u: mapped = 79; break;
            case 2105u: mapped = 80; break;
            case 2106u: mapped = 81; break;
            case 2107u: mapped = 75; break;
            case 2108u: mapped = 76; break;
            case 2109u: mapped = 77; break;
            case 2110u: mapped = 71; break;
            case 2111u: mapped = 72; break;
            case 2112u: mapped = 73; break;
            case 2113u: mapped = 181; break;
            case 2114u: mapped = 55; break;
            case 2115u: mapped = 74; break;
            case 2116u: mapped = 78; break;
            case 2117u: mapped = 83; break;
            case 2119u: mapped = 156; break;
            case 2120u: mapped = 141; break;
            default: return false;
        }
    }
    outKey->key = mapped;
    outKey->scanCode = ScanCodeFromOhosIdentity(
        physicalKey, hardwareScanCode, hidUsage, &outKey->scanCodeSource);
    return true;
}

// LWJGL2 的按钮索引与 GLFW 相同（AMCLDisplay 直接把 GLFW index 当
// `mouseButtonState[]` 的下标）。所以这张表与 `MapOhosButton` 逐字相同 ——
// **刻意各写一份而不共用**：两者相等是当前事实，不是契约，共用会让"将来 LWJGL2 改了
// 按钮顺序"变成一次静默的 GLFW 回归。
bool Lwjgl2MapOhosButton(void*, uint64_t, uint32_t nativeButton,
                         int32_t* outButton) {
    if (!outButton) return false;
    switch (nativeButton) {
        case 1u: *outButton = 0; return true;
        case 2u: *outButton = 1; return true;
        case 4u: *outButton = 2; return true;
        case 8u: *outButton = 3; return true;
        case 16u: *outButton = 4; return true;
        default: return false;
    }
}

bool Sdl3MapOhosKey(void*, uint64_t, uint32_t physicalKey,
                    uint32_t hardwareScanCode, uint32_t hidUsage,
                    GlfwMappedKey* outKey) {
    if (!outKey) return false;
    int32_t mapped = 0;
    {
        switch (physicalKey) {
            case 2000u: mapped = 39; break;
            case 2001u: mapped = 30; break;
            case 2002u: mapped = 31; break;
            case 2003u: mapped = 32; break;
            case 2004u: mapped = 33; break;
            case 2005u: mapped = 34; break;
            case 2006u: mapped = 35; break;
            case 2007u: mapped = 36; break;
            case 2008u: mapped = 37; break;
            case 2009u: mapped = 38; break;
            case 2012u: mapped = 82; break;
            case 2013u: mapped = 81; break;
            case 2014u: mapped = 80; break;
            case 2015u: mapped = 79; break;
            case 2016u: mapped = 40; break;
            case 2017u: mapped = 4; break;
            case 2018u: mapped = 5; break;
            case 2019u: mapped = 6; break;
            case 2020u: mapped = 7; break;
            case 2021u: mapped = 8; break;
            case 2022u: mapped = 9; break;
            case 2023u: mapped = 10; break;
            case 2024u: mapped = 11; break;
            case 2025u: mapped = 12; break;
            case 2026u: mapped = 13; break;
            case 2027u: mapped = 14; break;
            case 2028u: mapped = 15; break;
            case 2029u: mapped = 16; break;
            case 2030u: mapped = 17; break;
            case 2031u: mapped = 18; break;
            case 2032u: mapped = 19; break;
            case 2033u: mapped = 20; break;
            case 2034u: mapped = 21; break;
            case 2035u: mapped = 22; break;
            case 2036u: mapped = 23; break;
            case 2037u: mapped = 24; break;
            case 2038u: mapped = 25; break;
            case 2039u: mapped = 26; break;
            case 2040u: mapped = 27; break;
            case 2041u: mapped = 28; break;
            case 2042u: mapped = 29; break;
            case 2043u: mapped = 54; break;
            case 2044u: mapped = 55; break;
            case 2045u: mapped = 226; break;
            case 2046u: mapped = 230; break;
            case 2047u: mapped = 225; break;
            case 2048u: mapped = 229; break;
            case 2049u: mapped = 43; break;
            case 2050u: mapped = 44; break;
            case 2054u: mapped = 40; break;
            case 2055u: mapped = 42; break;
            case 2056u: mapped = 53; break;
            case 2057u: mapped = 45; break;
            case 2058u: mapped = 46; break;
            case 2059u: mapped = 47; break;
            case 2060u: mapped = 48; break;
            case 2061u: mapped = 49; break;
            case 2062u: mapped = 51; break;
            case 2063u: mapped = 52; break;
            case 2064u: mapped = 56; break;
            case 2067u: mapped = 101; break;
            case 2068u: mapped = 75; break;
            case 2069u: mapped = 78; break;
            case 2070u: mapped = 41; break;
            case 2071u: mapped = 76; break;
            case 2072u: mapped = 224; break;
            case 2073u: mapped = 228; break;
            case 2074u: mapped = 57; break;
            case 2075u: mapped = 71; break;
            case 2076u: mapped = 227; break;
            case 2077u: mapped = 231; break;
            case 2079u: mapped = 70; break;
            case 2080u: mapped = 72; break;
            case 2081u: mapped = 74; break;
            case 2082u: mapped = 77; break;
            case 2083u: mapped = 73; break;
            case 2090u: mapped = 58; break;
            case 2091u: mapped = 59; break;
            case 2092u: mapped = 60; break;
            case 2093u: mapped = 61; break;
            case 2094u: mapped = 62; break;
            case 2095u: mapped = 63; break;
            case 2096u: mapped = 64; break;
            case 2097u: mapped = 65; break;
            case 2098u: mapped = 66; break;
            case 2099u: mapped = 67; break;
            case 2100u: mapped = 68; break;
            case 2101u: mapped = 69; break;
            case 2102u: mapped = 83; break;
            case 2103u: mapped = 98; break;
            case 2104u: mapped = 89; break;
            case 2105u: mapped = 90; break;
            case 2106u: mapped = 91; break;
            case 2107u: mapped = 92; break;
            case 2108u: mapped = 93; break;
            case 2109u: mapped = 94; break;
            case 2110u: mapped = 95; break;
            case 2111u: mapped = 96; break;
            case 2112u: mapped = 97; break;
            case 2113u: mapped = 84; break;
            case 2114u: mapped = 85; break;
            case 2115u: mapped = 86; break;
            case 2116u: mapped = 87; break;
            case 2117u: mapped = 99; break;
            case 2119u: mapped = 88; break;
            case 2120u: mapped = 103; break;
            default: return false;
        }
    }
    outKey->key = mapped;
    // SDL 把它当 rawcode 用（`SDL_SendKeyboardKey(0, id, rawcode, scancode, down)`）。
    // ⚠️ 而 SDL 想要的是 evdev 语义，只有 `kHardware` 那一支才是；另两支是别的编码空间。
    // 三条分支在真机上各占多少由 `AMCL_BACKEND_SCANSRC` 计数回答（计划 §106.2）。
    outKey->scanCode = ScanCodeFromOhosIdentity(
        physicalKey, hardwareScanCode, hidUsage, &outKey->scanCodeSource);
    return true;
}

// SDL 的按钮编号与 GLFW **不同**（SDL_BUTTON_LEFT=1 / MIDDLE=2 / RIGHT=3 / X1=4 / X2=5，
// 取自上游 `SDL3/SDL_mouse.h`），所以这一步是真翻译而不是恒等。⚠️ 旧链在 SDL patch 里
// 做的是 GLFW→SDL（0→LEFT、1→RIGHT、2→MIDDLE），这里直接从 OH_NativeXComponent 的
// **位标识**（1/2/4/8/16）到 SDL 编号，中间那一跳没了。
bool Sdl3MapOhosButton(void*, uint64_t, uint32_t nativeButton,
                       int32_t* outButton) {
    if (!outButton) return false;
    switch (nativeButton) {
        case 1u: *outButton = 1; return true;   // SDL_BUTTON_LEFT
        case 2u: *outButton = 3; return true;   // SDL_BUTTON_RIGHT
        case 4u: *outButton = 2; return true;   // SDL_BUTTON_MIDDLE
        case 8u: *outButton = 4; return true;   // SDL_BUTTON_X1
        case 16u: *outButton = 5; return true;  // SDL_BUTTON_X2
        default: return false;
    }
}

}  // namespace

GlfwInputMapper Lwjgl2OhosInputMapper() {
    return {nullptr, Lwjgl2MapOhosKey, Lwjgl2MapOhosButton};
}

GlfwInputMapper Sdl3OhosInputMapper() {
    return {nullptr, Sdl3MapOhosKey, Sdl3MapOhosButton};
}

}  // namespace amcl::input

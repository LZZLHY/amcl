#pragma once
#include <cmath>
#include <cstring>
namespace amcl::desktop {
// GameControllerKit 的标准按键与轴在这三种 AMCL 产品均从 API 21 提供。
inline bool SupportsGamepadCapture(const char* type, int api) {
    return api >= 21 && type &&
        (std::strcmp(type, "phone") == 0 || std::strcmp(type, "tablet") == 0 || std::strcmp(type, "2in1") == 0);
}
// OHOS key values are the platform's published button codes. Home (2311)
// is BUTTON_SELECT, so it maps to Back rather than inventing a Guide press.
inline int StandardGamepadButton(int code) {
    switch (code) {
        case 2301: return 0; case 2302: return 1;
        case 2304: return 2; case 2305: return 3;
        case 2307: return 4; case 2308: return 5;
        case 2311: return 6; case 2312: return 7; case 2313: return 8;
        case 2314: return 9; case 2315: return 10;
        case 2012: return 11; case 2015: return 12;
        case 2013: return 13; case 2014: return 14;
        case 2303: return 15; case 2309: return 16; case 2310: return 17;
        default: return -1;
    }
}
inline float GamepadAxis(double value) {
    if (!std::isfinite(value)) return 0;
    return static_cast<float>(value < -1 ? -1 : value > 1 ? 1 : value);
}
// MMI 对 BRAKE/GAS 这两个非中心轴归一到 [0,1]；标准 GLFW 轴以 -1 代表松开。
inline float GamepadTriggerAxis(double value) {
    if (!std::isfinite(value) || value <= 0) return -1.0f;
    return value >= 1 ? 1.0f : static_cast<float>(value * 2.0 - 1.0);
}
// LT/RT 既可能只报按钮，也可能同时报连续轴。只要该连接已报告过轴，按钮就不能把半压抬成满压。
inline float StandardTrigger(float axis, bool hasAxis, unsigned char button) {
    return hasAxis ? axis : (button ? 1.0f : -1.0f);
}
inline unsigned char GamepadHat(double x, double y) {
    return (x < -0.5 ? 8 : x > 0.5 ? 2 : 0) | (y < -0.5 ? 1 : y > 0.5 ? 4 : 0);
}
}

#pragma once
#include <cmath>
namespace amcl::desktop {
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
inline unsigned char GamepadHat(double x, double y) {
    return (x < -0.5 ? 8 : x > 0.5 ? 2 : 0) | (y < -0.5 ? 1 : y > 0.5 ? 4 : 0);
}
}

// joystick_sector.cpp — 摇杆八向扇区判定。契约与跨语言规格见 .h。
#include "joystick_sector.h"

#include <cmath>

extern "C" AmclJoystickSector amcl_joystick_sector(double dx, double dy,
                                                  double deadZone) {
    AmclJoystickSector out = {false, false, false, false};
    // 非有限输入判成松开。让一个 NaN 决定方向的后果是某个方向键永久按住，
    // 而那在 MC 里表现为"角色自己一直走"，比丢一次输入严重得多。
    if (!std::isfinite(dx) || !std::isfinite(dy) || !std::isfinite(deadZone)) {
        return out;
    }
    const double len = std::sqrt(dx * dx + dy * dy);
    if (len < deadZone) return out;
    // 长度为 0 时 atan2(0,0) 有定义（返回 0）但方向无意义。死区为 0 的调用方
    // （手柄端在死区重映射之后可能传 0）必须在这里被挡住，否则摇杆归中会被判成"向右"。
    if (len == 0.0) return out;

    constexpr double kPi = 3.14159265358979323846;
    double deg = std::atan2(dy, dx) * 180.0 / kPi;
    if (deg < 0.0) deg += 360.0;

    // 八段，每段 45°，边界落在 22.5° + k·45°。区间取 [下界, 上界)。
    // dy 向下为正 ⇒ 90° 是屏幕下方 = S，270° 是屏幕上方 = W。
    if (deg >= 337.5 || deg < 22.5)      { out.d = true; }
    else if (deg < 67.5)                 { out.d = true; out.s = true; }
    else if (deg < 112.5)                { out.s = true; }
    else if (deg < 157.5)                { out.a = true; out.s = true; }
    else if (deg < 202.5)                { out.a = true; }
    else if (deg < 247.5)                { out.a = true; out.w = true; }
    else if (deg < 292.5)                { out.w = true; }
    else                                 { out.d = true; out.w = true; }
    return out;
}

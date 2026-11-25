#include "../../platform/desktop_gamepad_mapping.h"
#include <cstdlib>
#include <iostream>
#include <limits>
#define CHECK(e) do { if (!(e)) { std::cerr << "failed line " << __LINE__ << '\n'; std::exit(1); } } while(false)
int main() {
    using namespace amcl::desktop;
    // API 20 保留映射；手机、平板、二合一从 21 可按用户选择采集手柄。
    CHECK(!SupportsGamepadCapture("phone", 20) && SupportsGamepadCapture("phone", 21));
    CHECK(SupportsGamepadCapture("tablet", 26) && SupportsGamepadCapture("2in1", 21));
    CHECK(!SupportsGamepadCapture(nullptr, 26) && !SupportsGamepadCapture("tv", 26));
    CHECK(StandardGamepadButton(2301) == 0);
    CHECK(StandardGamepadButton(2311) == 6);
    CHECK(StandardGamepadButton(2313) == 8);
    CHECK(StandardGamepadButton(2303) == 15);
    CHECK(StandardGamepadButton(2014) == 14);
    CHECK(StandardGamepadButton(99999) == -1);
    CHECK(GamepadAxis(-3) == -1 && GamepadAxis(3) == 1);
    CHECK(GamepadAxis(std::numeric_limits<double>::quiet_NaN()) == 0);
    CHECK(StandardTrigger(0, false, 0) == -1 && StandardTrigger(0, false, 1) == 1);
    CHECK(StandardTrigger(-0.25f, true, 1) == -0.25f);
    CHECK(GamepadTriggerAxis(0) == -1 && GamepadTriggerAxis(0.25) == -0.5f);
    CHECK(GamepadTriggerAxis(0.5) == 0 && GamepadTriggerAxis(1) == 1);
    CHECK(GamepadHat(-1, -1) == 9 && GamepadHat(1, 1) == 6);
    CHECK(GamepadHat(0, 0) == 0);
    std::cout << "desktop gamepad mapping PASS\n";
}

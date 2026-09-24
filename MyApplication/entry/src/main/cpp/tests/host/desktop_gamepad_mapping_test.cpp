#include "../../platform/desktop_gamepad_mapping.h"
#include <cstdlib>
#include <iostream>
#include <limits>
#define CHECK(e) do { if (!(e)) { std::cerr << "failed line " << __LINE__ << '\n'; std::exit(1); } } while(false)
int main() {
    using namespace amcl::desktop;
    CHECK(StandardGamepadButton(2301) == 0);
    CHECK(StandardGamepadButton(2311) == 6);
    CHECK(StandardGamepadButton(2313) == 8);
    CHECK(StandardGamepadButton(2303) == 15);
    CHECK(StandardGamepadButton(2014) == 14);
    CHECK(StandardGamepadButton(99999) == -1);
    CHECK(GamepadAxis(-3) == -1 && GamepadAxis(3) == 1);
    CHECK(GamepadAxis(std::numeric_limits<double>::quiet_NaN()) == 0);
    CHECK(GamepadHat(-1, -1) == 9 && GamepadHat(1, 1) == 6);
    CHECK(GamepadHat(0, 0) == 0);
    std::cout << "desktop gamepad mapping PASS\n";
}

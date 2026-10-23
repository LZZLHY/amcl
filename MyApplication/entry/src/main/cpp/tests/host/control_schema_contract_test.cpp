// 控件定义合同回归：相同语义不作废finger；真实几何/绑定变更必须换代；物品栏外边缘不clamp。
#include "../../platform/control_schema_contract.h"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#define CHECK(x) do { if (!(x)) { std::cerr << "schema contract failed: " << __LINE__ << '\n'; std::exit(1); } } while (0)
int main() {
    AmclCtrlEntry entry{};
    std::strcpy(entry.id, "hotbar"); entry.kind = 4;
    entry.x = 100; entry.y = 100; entry.w = 180; entry.h = 22;
    std::vector<AmclCtrlEntry> old{entry};
    CHECK(amcl::input::SameControlSchemaEntries(old, &entry, 1));
    // 未使用数组槽不构成变化；平台填充字节不能引发一次无意义的owner退休。
    entry.keys[5] = 99;
    CHECK(amcl::input::SameControlSchemaEntries(old, &entry, 1));
    // 完整表必须发现反馈变化，旧动作/命中绑定却继续生存，不能忽略haptic而不安装新定义。
    entry.haptic = 1;
    CHECK(!amcl::input::SameControlSchemaEntry(old[0], entry));
    CHECK(!amcl::input::SameControlSchemaEntries(old, &entry, 1));
    CHECK(amcl::input::SameControlSchemaBinding(old[0], entry));
    CHECK(amcl::input::SameControlSchemaBindings(old, &entry, 1));
    entry.haptic = 0;
    entry.x = 101; CHECK(!amcl::input::SameControlSchemaEntries(old, &entry, 1)); entry.x = 100;
    entry.keyCount = 1; entry.keys[0] = 65;
    CHECK(!amcl::input::SameControlSchemaEntries(old, &entry, 1));
    CHECK(!amcl::input::SameControlSchemaBindings(old, &entry, 1));
    CHECK(amcl::input::ControlHotbarSlot(entry, 95, 110) == -1);
    CHECK(amcl::input::ControlHotbarSlot(entry, 500, 110) == -1);
    CHECK(amcl::input::ControlHotbarSlot(entry, 110, 99) == -1);
    CHECK(amcl::input::ControlHotbarSlot(entry, 110, 122) == -1);
    CHECK(amcl::input::ControlHotbarSlot(entry, 280, 110) == -1);
    CHECK(amcl::input::ControlHotbarSlot(entry, std::numeric_limits<float>::quiet_NaN(), 110) == -1);
    for (int i = 0; i < 9; ++i) CHECK(amcl::input::ControlHotbarSlot(entry, 110.0f + i * 20.0f, 110) == i);
    // 同一12vp滑动在不同密度下都恰好一格；旧36px常量在1x/3.25x会改变手感。
    for (const double density : {1.0, 2.0, 3.0, 3.25}) {
        CHECK(amcl::input::ControlScrollStepPx(density) == static_cast<float>(12.0 * density));
    }
    CHECK(amcl::input::ControlScrollStepPx(0.0) == 12.0f);
    CHECK(amcl::input::ControlScrollStepPx(std::numeric_limits<double>::quiet_NaN()) == 12.0f);
    std::cout << "control schema equality/hotbar boundaries PASS\n";
}

// backend_keymaps_test.cpp — 两份后端 mapper 里**门禁看不到的那一半**（计划 §103.2）
//
// ============================ 它证明什么 ============================
//
// `check-backend-keymap-parity` 钉的是键码表（新表 == 旧两步的复合），而它在自己的文件头
// 里明写**两块不覆盖**：
//   ① `scanCode` / rawcode —— 那条 fallback 链不在 parity 的判据里；
//   ② **按钮表完全不在门禁里**（三个后端的按钮域各不相同，硬凑等式只会得到恒真断言）。
// 而 `backend_keymaps.h` 却写着"逐条等价由门禁钉住" —— 那句话对按钮**不成立**。
// 这个文件补的正是这两块。
//
// ⭐ 为什么按钮值得单独钉：SDL 的编号与 GLFW **不同**（LEFT=1/RIGHT=3/MIDDLE=2），而
// LWJGL2 的编号与 GLFW **相同**（LEFT=0/RIGHT=1/MIDDLE=2）。"相同"是当前事实、不是契约，
// 源码注释因此刻意各写一份。可是"各写一份"只在有人核对时才有意义 —— 没有断言的话，把
// SDL 那张表抄成 LWJGL2 那张（或反过来）不会有任何东西变红，而后果是**右键变中键**。
//
// ============================ 它不证明什么 ============================
//
// ⚠️ **不重复 parity 门禁的工作**：键码表 210 条不在这里逐条抄一遍（那会变成第四份镜像）。
// 这里只做门禁**结构上**做不到的事 + 少量锚点。
// ⚠️ **不能证明 SDL/LWJGL2 上游的编号就是这些数**。那是外部事实，本仓无法自证；数值出处
// 记在源码注释里（上游 SDL_mouse.h / AMCLDisplay 的 mouseButtonState 下标）。
// ⚠️ **不覆盖 scanCode 三个来源的语义混淆**：`hardwareScanCode` / `hidUsage` /
// `physicalKey` 是三个**不同的编码空间**，合并成一个 int 之后消费者（SDL 当 evdev rawcode
// 用）分不出来。这是一条**真缺口**，本文件只能钉住"链的顺序与溢出处置"，分不出来那件事
// 要靠 ABI 加判别位 —— 记在计划 §103.2。

#include "../../input/adapters/backend_keymaps.h"

#include <climits>
#include <cstdlib>
#include <iostream>

using namespace amcl::input;

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "BACKEND KEYMAPS FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

// 一个"肯定在两张表里都有"的键：OHOS KEYCODE_A。锚点刻意选常用键 —— 若哪天表被整体
// 改坏，这一条会先红。
constexpr uint32_t kOhosKeyA = 2017u;
constexpr uint32_t kOhosKeyUnmapped = 0xDEADu;

bool MapKey(const GlfwInputMapper& mapper, uint32_t physicalKey,
            uint32_t hardwareScanCode, uint32_t hidUsage, GlfwMappedKey* out) {
    return mapper.mapKey(mapper.context, 1u, physicalKey, hardwareScanCode,
                         hidUsage, out);
}

}  // namespace

int main() {
    const GlfwInputMapper lwjgl2 = Lwjgl2OhosInputMapper();
    const GlfwInputMapper sdl3 = Sdl3OhosInputMapper();

    // 1. 两份 mapper 的三个字段都必须非空。缺 mapKey/mapButton 会让整个后端静默无输入，
    //    而 adapter 对空 mapper 的处置不在本 TU 里 ⇒ 这里只钉"表是完整的"。
    CHECK(lwjgl2.mapKey != nullptr && lwjgl2.mapButton != nullptr);
    CHECK(sdl3.mapKey != nullptr && sdl3.mapButton != nullptr);
    // 两份表必须是**不同的函数**：同一个指针意味着有人把两个后端合并了，而它们的编码不同。
    CHECK(lwjgl2.mapKey != sdl3.mapKey);
    CHECK(lwjgl2.mapButton != sdl3.mapButton);

    // 2. ⭐ scanCode fallback 链的顺序：hardwareScanCode → hidUsage → physicalKey。
    //    顺序错了不会有任何东西变红（三个都是 uint32），但 SDL 会拿到一个错的 rawcode。
    {
        for (const GlfwInputMapper* m : {&lwjgl2, &sdl3}) {
            GlfwMappedKey k{};
            // 三者齐全 ⇒ 取硬件扫描码。
            CHECK(MapKey(*m, kOhosKeyA, 30u, 4u, &k));
            CHECK(k.scanCode == 30);
            CHECK(k.scanCodeSource == GlfwScanCodeSource::kHardware);
            // 硬件扫描码为 0 ⇒ 退到 HID usage。
            k = {};
            CHECK(MapKey(*m, kOhosKeyA, 0u, 4u, &k));
            CHECK(k.scanCode == 4);
            CHECK(k.scanCodeSource == GlfwScanCodeSource::kHidUsage);
            // 两者都为 0 ⇒ 退到 raw identity。
            k = {};
            CHECK(MapKey(*m, kOhosKeyA, 0u, 0u, &k));
            CHECK(k.scanCode == static_cast<int32_t>(kOhosKeyA));
            CHECK(k.scanCodeSource == GlfwScanCodeSource::kRawIdentity);
            // ⭐ 三支必须**互不相同**：来源枚举的全部用处就是让消费者分辨"这个 rawcode
            //    落在哪个编码空间"，三支报同一个值等于什么都没报（计划 §106.2）。
            GlfwMappedKey hw{};
            GlfwMappedKey hid{};
            CHECK(MapKey(*m, kOhosKeyA, 30u, 4u, &hw));
            CHECK(MapKey(*m, kOhosKeyA, 0u, 4u, &hid));
            CHECK(hw.scanCodeSource != hid.scanCodeSource);
            CHECK(hid.scanCodeSource != k.scanCodeSource);
            CHECK(hw.scanCodeSource != k.scanCodeSource);
        }
    }

    // 3. scanCode 溢出（> INT_MAX）⇒ 0。⚠️ 这是**已知的不彻底处置**：键照样投递，只是
    //    rawcode 变成 0。钉住它是为了让"将来改成整条拒收"成为一次刻意的行为变更，而不是
    //    某天有人顺手改掉、也没人知道原来是什么语义。
    {
        const uint32_t tooBig = static_cast<uint32_t>(INT_MAX) + 1u;
        for (const GlfwInputMapper* m : {&lwjgl2, &sdl3}) {
            GlfwMappedKey k{};
            k.scanCode = 91;
            CHECK(MapKey(*m, kOhosKeyA, tooBig, 0u, &k));
            CHECK(k.scanCode == 0);
            // 溢出时来源报 kNone 而不是 kHardware：值已经被丢掉，声称它来自硬件扫描码
            // 会让下游把一个 0 当成一个真的 evdev 码（计划 §106.2）。
            CHECK(k.scanCodeSource == GlfwScanCodeSource::kNone);
            CHECK(k.key != 0);  // 键本身仍然映射成功
        }
    }

    // 4. 两个后端对同一个 OHOS 键给出**不同**的编码（DirectInput vs SDL_Scancode）。
    //    若哪天两者相等，说明有人把一张表抄成了另一张 —— 这条会红。
    {
        GlfwMappedKey a{};
        GlfwMappedKey b{};
        CHECK(MapKey(lwjgl2, kOhosKeyA, 30u, 4u, &a));
        CHECK(MapKey(sdl3, kOhosKeyA, 30u, 4u, &b));
        CHECK(a.key != 0 && b.key != 0);
        CHECK(a.key != b.key);
    }

    // 5. 未知键 ⇒ 返回 false，且**一个出参都不写**。fail closed 的另一半是"不污染调用方"。
    {
        for (const GlfwInputMapper* m : {&lwjgl2, &sdl3}) {
            GlfwMappedKey k{};
            k.key = 91;
            k.scanCode = 92;
            CHECK(!MapKey(*m, kOhosKeyUnmapped, 30u, 4u, &k));
            CHECK(k.key == 91 && k.scanCode == 92);
        }
    }

    // 6. 出参为空 ⇒ false，不崩。
    {
        CHECK(!lwjgl2.mapKey(lwjgl2.context, 1u, kOhosKeyA, 30u, 4u, nullptr));
        CHECK(!sdl3.mapKey(sdl3.context, 1u, kOhosKeyA, 30u, 4u, nullptr));
        CHECK(!lwjgl2.mapButton(lwjgl2.context, 1u, 1u, nullptr));
        CHECK(!sdl3.mapButton(sdl3.context, 1u, 1u, nullptr));
    }

    // 7. ⭐⭐ 按钮表：门禁里一条都没有，所以这里必须逐条钉。
    //    输入是 OH_NativeXComponent 的**位标识**（1/2/4/8/16），不是序号。
    {
        struct Row { uint32_t native; int32_t lwjgl2; int32_t sdl3; };
        // LWJGL2 与 GLFW 同序（AMCLDisplay 直接把它当 mouseButtonState[] 下标）；
        // SDL 用 SDL_BUTTON_*（LEFT=1 / MIDDLE=2 / RIGHT=3 / X1=4 / X2=5）。
        const Row rows[] = {
            {1u, 0, 1},   // 左键
            {2u, 1, 3},   // 右键 —— ⚠️ 两个后端在这里数值不同，且 SDL 不是 2
            {4u, 2, 2},   // 中键
            {8u, 3, 4},   // X1
            {16u, 4, 5},  // X2
        };
        for (const Row& row : rows) {
            int32_t got = -1;
            CHECK(lwjgl2.mapButton(lwjgl2.context, 1u, row.native, &got));
            CHECK(got == row.lwjgl2);
            got = -1;
            CHECK(sdl3.mapButton(sdl3.context, 1u, row.native, &got));
            CHECK(got == row.sdl3);
        }
        // ⭐ 右键/中键在 SDL 侧**不是**恒等映射。这一条单独立出来，因为"把 SDL 表抄成
        // LWJGL2 表"恰好只在这两个按钮上产生可见后果（右键变中键）。
        int32_t sdlRight = -1;
        int32_t sdlMiddle = -1;
        CHECK(sdl3.mapButton(sdl3.context, 1u, 2u, &sdlRight));
        CHECK(sdl3.mapButton(sdl3.context, 1u, 4u, &sdlMiddle));
        CHECK(sdlRight == 3 && sdlMiddle == 2);
        CHECK(sdlRight != sdlMiddle);
    }

    // 8. 未知按钮位 ⇒ false 且不写出参。0 与"两个位同时置起"都算未知（本 SDK 一次只报
    //    一个按钮，同时置位说明上游语义变了，猜不得）。
    {
        for (const GlfwInputMapper* m : {&lwjgl2, &sdl3}) {
            for (uint32_t native : {0u, 3u, 32u, 0xFFFFFFFFu}) {
                int32_t got = 91;
                CHECK(!m->mapButton(m->context, 1u, native, &got));
                CHECK(got == 91);
            }
        }
    }

    // 9. LWJGL2 与 SDL3 的键码表条目数**不同**（105 / 106，差 PRINT_SCREEN）。
    //    parity 门禁把这个差异钉在注释里，这里用**行为**再钉一次：LWJGL2 必须拒绝
    //    PRINT_SCREEN，SDL3 必须接受它。哪天有人"顺手补齐"，两条同时红。
    //    OHOS 2079 是那一条（`MapOhosKey` 里 2079 → GLFW 283，SDL 侧 → 扫描码 70）。
    {
        constexpr uint32_t kOhosPrintScreen = 2079u;
        GlfwMappedKey k{};
        k.key = 91;
        CHECK(!MapKey(lwjgl2, kOhosPrintScreen, 30u, 4u, &k));
        CHECK(k.key == 91);
        k = {};
        CHECK(MapKey(sdl3, kOhosPrintScreen, 30u, 4u, &k));
        CHECK(k.key == 70);
    }

    // 10. mapper 是**纯函数**：同一输入连调两次结果逐位相同，且不受调用顺序影响。
    //     （零全局状态是它能进 host 构建的前提，也是它可以被两个 channel 共用的前提。）
    {
        GlfwMappedKey first{};
        GlfwMappedKey second{};
        CHECK(MapKey(sdl3, kOhosKeyA, 30u, 4u, &first));
        CHECK(MapKey(lwjgl2, kOhosKeyA, 0u, 0u, &second));
        GlfwMappedKey again{};
        CHECK(MapKey(sdl3, kOhosKeyA, 30u, 4u, &again));
        CHECK(again.key == first.key && again.scanCode == first.scanCode);
    }

    std::cout << "BACKEND KEYMAPS PASS\n";
    return 0;
}

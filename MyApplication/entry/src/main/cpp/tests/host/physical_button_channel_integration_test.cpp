/**
 * 实体鼠标通道与真实legacy owner的组合回归。直接链接生产policy/router/ledger，
 * 验证两个设备重叠按住、跨通道长按、DOWN拒绝、拔除未知桶及复位；不复制生产仲裁。
 */
#include "input_channel_policy.h"
#include "legacy_physical_edge_router.h"
#include "pointer_device_registry.h"

#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <vector>
using namespace amcl::input;
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)

struct Fixture {
    std::vector<int> emitted;
    InputLedger ledger{[this](const Output&, int action) { emitted.push_back(action); }};
    std::recursive_mutex transaction;
    LegacyPhysicalEdgeRouter router{ledger, transaction};
    OwnerToken next = 1u;

    bool desktop = false;

    bool Edge(AmclInputChannel channel, uint64_t device, uint32_t button, bool down, uint64_t eventTimeNs = 0u) {
        const bool accepted = down ? amcl_input_policy_button_begin(channel, device, button, eventTimeNs, desktop)
                                   : amcl_input_policy_button_end(channel, device, button, eventTimeNs);
        if (!accepted) return false;
        const Output output{OutputKind::Mouse, ButtonIndex(button)};
        CHECK(router.Route(true, {OutputKind::Mouse, device, button}, &output,
            down ? LegacyPhysicalAction::Down : LegacyPhysicalAction::Up,
            down ? next++ : 0u) <= AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
        return true;
    }
    static int ButtonIndex(uint32_t button) {
        int index = 0;
        while (button > 1u) { button >>= 1u; ++index; }
        return index;
    }
    static void Removed(uint64_t device, uint32_t button, void* opaque) {
        auto& fixture = *static_cast<Fixture*>(opaque);
        // 回调已在策略锁外，可重入只读策略而不死锁。
        (void)amcl_input_policy_left_held();
        const Output output{OutputKind::Mouse, ButtonIndex(button)};
        CHECK(fixture.router.Route(true, {OutputKind::Mouse, device, button}, &output,
            LegacyPhysicalAction::Up, 0u) <= AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    }
};

int main() {
    Fixture fixture;
    // F03：同channel第二设备不是重复DOWN，其UP不能窃取第一设备的配对。
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 1u, true));
    CHECK(fixture.router.HeldIdentityCount() == 2u);
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 1u, false));
    CHECK(fixture.router.HeldIdentityCount() == 1u);
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, false));
    CHECK(fixture.router.HeldIdentityCount() == 0u);
    CHECK(fixture.emitted == std::vector<int>({1, 0}));

    // F04：全部非左键与左键遵循同一DOWN-time身份规则，任意长按不会换通道。
    for (uint32_t button : {2u, 4u, 8u, 16u}) {
        CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, button, true));
        CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, button, true));
        CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, button, false));
        CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, button, false));
        CHECK(fixture.router.HeldIdentityCount() == 0u);
        CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, button, true));
        CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, button, false));
        CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, button, false));
    }

    // 下游DOWN拒绝不得留下永久策略预留。
    CHECK(amcl_input_policy_button_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 33u, 1u, 0u, false));
    amcl_input_policy_button_abort(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 33u, 1u);
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 33u, 1u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 33u, 1u, false));

    // F05：未知身份并非整端身份。拔一只设备清指定桶和unknown桶，保留另一个known。
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 0u, 2u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 2u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 2u, true));
    amcl_input_policy_release_pointer_device(11u, true, Fixture::Removed, &fixture);
    CHECK(fixture.router.HeldIdentityCount() == 1u);
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 0u, 2u, false));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 2u, false));
    CHECK(fixture.router.HeldIdentityCount() == 0u);

    PointerDeviceRegistry devices;
    using Kind = PointerDeviceRegistry::Kind;
    devices.Added(11u, Kind::Pointer);
    devices.Added(11u, Kind::Unknown);
    CHECK(devices.Removed(11u).releaseUnknown);
    devices.Added(22u, Kind::Other);
    CHECK(!devices.Removed(22u).releaseUnknown);
    const auto missing = devices.Removed(99u);
    CHECK(missing.releaseUnknown && missing.classificationMissing);
    CHECK(!devices.Removed(100u, Kind::Other).releaseUnknown);

    CHECK(amcl_input_policy_button_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 44u, 1u, 0u, false));
    amcl_input_policy_reset_pairing();
    CHECK(!amcl_input_policy_button_end(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 44u, 1u, 0u));

    // 非电脑沿用原历史优先级，哪怕低优先级的边沿有时间和另一设备身份。
    amcl_input_policy_retire_channels();
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true, 100u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, false, 110u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 22u, 1u, true, 111u));

    // 先清独立场景的历史能力。带实际时间的完整迟到副本必须拒绝，下一次真实
    // fallback DOWN 即使紧随其后也能接管；不可用接收时间或固定窗口吞掉快点。
    amcl_input_policy_retire_channels();
    fixture.desktop = true;
    fixture.emitted.clear();
    // Native 先按下时，被拒的高优先级镜像不能把下一次独立的 Native 左键永久封住。
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, true, 100u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 7u, 1u, true, 100u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, false, 120u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 7u, 1u, false, 120u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, true, 200u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, false, 210u));
    CHECK(fixture.emitted == std::vector<int>({1, 0, 1, 0}));
    amcl_input_policy_retire_channels();
    fixture.emitted.clear();
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true, 100u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, true, 101u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, false, 110u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, true, 101u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, false, 110u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, true, 111u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, false, 110u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, false, 120u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true, 112u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true, 121u));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, false, 130u));
    CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 1u, true));
    CHECK(fixture.router.HeldIdentityCount() == 0u);
    CHECK(fixture.emitted == std::vector<int>({1, 0, 1, 0, 1, 0}));

    // 两个来源有独立的已知设备身份时可以共持。第一台抬起不会结束后者。
    amcl_input_policy_retire_channels();
    fixture.emitted.clear();
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 22u, 1u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, false));
    CHECK(fixture.router.HeldIdentityCount() == 1u);
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 22u, 1u, false));
    CHECK(fixture.router.HeldIdentityCount() == 0u);
    CHECK(fixture.emitted == std::vector<int>({1, 0}));
    std::puts("physical_button_channel_integration_test: all checks passed");
}

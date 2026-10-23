// 公共输出服务的生产装配测试。仅五int出口记录边沿，三类来源的路由和账本均为产品实现，
// 不链接触控解释器或平台SDK，证明新的输入端可以独立使用同一运行时。
#include "legacy_output_runtime.h"
#include <cstdlib>
#include <iostream>
#include <vector>

struct Edge { int type; int code; int action; };
static std::vector<Edge> edges;
extern "C" void inputBridge_pushEvent(int type, int code, int second, int third, int) {
    edges.push_back({type, code, type == 1005 ? third : second});
}
#define CHECK(value) do { if (!(value)) { std::cerr << "runtime fail line " << __LINE__ << '\n'; std::exit(1); } } while (0)

int main() {
    using namespace amcl::input;
    auto& runtime = ProcessLegacyOutputRuntime();
    std::lock_guard<std::recursive_mutex> transaction(runtime.TransactionMutex());
    const Output key{OutputKind::Key, 87};
    const auto touch = runtime.AcquireControl(
        {AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 0u, "touch:W"}, {key});
    const auto pad = runtime.AcquireControl(
        {AMCL_INPUT_SOURCE_GAMEPAD, 7u, "gamepad:7:W"}, {key});
    const auto physical = runtime.NextOwner();
    CHECK(touch && pad && physical > pad);
    const LegacyPhysicalIdentity identity{OutputKind::Key, 9u, 2039u};
    (void)runtime.Physical().Route(true, identity, &key, LegacyPhysicalAction::Down, physical);
    CHECK(edges.size() == 1u && edges[0].type == 1005 && edges[0].action == 1);
    CHECK(runtime.Ledger().ownerCount() == 3u);
    // 单源退休从registry取下按下时记录，不需要触控UI参与，不影响兄弟来源。
    CHECK(runtime.ReleaseSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 1u);
    CHECK(runtime.Ledger().ownerCount() == 2u && edges.size() == 1u);
    CHECK(runtime.ReleaseControl(pad));
    CHECK(runtime.Ledger().ownerCount() == 1u && edges.size() == 1u);
    (void)runtime.Physical().Route(true, identity, &key, LegacyPhysicalAction::Up, 0u);
    CHECK(runtime.Ledger().ownerCount() == 0u && edges.size() == 2u && edges[1].action == 0);
    CHECK(runtime.ReleaseControl(touch) && edges.size() == 2u);
    std::cout << "legacy output runtime: touch/gamepad/physical share one owner service PASS\n";
}

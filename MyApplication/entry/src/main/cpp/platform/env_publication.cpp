// env_publication.cpp — 进程级环境的早期发布与启动前封存（I27-05），只编进 libentry。
//
// 不变量：第一个 AMCL 游戏线程或 JVM 线程出现之后（jvm_launcher 的 JNI_CreateJavaVM /
// mc_launcher 的 g_mcThread），第一方代码不再新增或删除任何环境名，也不释放读者可能持有的
// 字符串。本文件负责“之前”的那一半：
//   1. PublishEarlyProcessEnvironment —— NAPI 模块初始化的第一步（ArkUI 尚未回调任何
//      XComponent surface，也没有任何 AMCL 线程）登记重启标记槽位，并提前调用各进程常量描述符
//      的发布函数。那些函数自带一次性守卫，此后 surface 重建与 glfwInit 里的调用只是空操作。
//   2. PrepareRuntimeEnvironmentSlots —— mc_launcher 在建 JVM 之前补登本局只在游戏线程
//      填写的文本槽位；3. SealProcessEnvironment —— jvmInit 认领创建事务后封存登记表。
// 描述符里只有函数/表地址等进程常量，所以“比首个 surface 更早发布”不改变任何读者的语义：
// 读者本来就按“出现即可用、缺席则稍后重试”消费它们，输入仍由 surface gate 按身份准入。
#include "env_publication.h"

#include "env_slot.h"
#include "window_host.h"
#include "../input/adapters/backend_input_bridge.h"
#include "../input/delivery/control_delivery.h"
#include "../input/delivery/look_execution.h"
#include "../input/source/source_control.h"
#include "../jvm/callback_bridge_host.h"
#include "../utils/amcl_log.h"

#include <cstdio>
#include <mutex>

// libamcl_input_runtime 的导出（input_runtime.version 的 inputBridge_*）；它只允许 XComponent
// 所在映像发布，libentry 依赖的这份正是 glfwOHOS_PublishNativeWindow 使用的同一映像。
extern "C" void inputBridge_publishAddress(void);

// 沿用 config/log-domains.json 已登记的 runtime 域 tag：发布与封存都属于 NAPI 入口基础设施。
#undef LOG_TAG
#define LOG_TAG "NAPI_ENTRY"

namespace amcl::ohos {
namespace {

using amcl::envslot::Kind;

// jni_reregister.c 拒绝长度 >= 128 的描述符；容量取 127 保证槽位永远装得下合法值。
constexpr uint32_t kCallbackBridgeHostCapacity = 127u;
// "1:<pid>:<tid>:<session>" 三个 uint64 十进制最长 1+1+20+1+20+1+20 = 64 字节，留余量。
constexpr uint32_t kSdlHostRuntimeCapacity = 95u;

// 把状态码转成日志里的稳定短名，区分“已封存”“被摘走”“登记表冲突”等不同成因。
const char* StatusName(int status) {
    switch (status) {
        case amcl::envslot::kOk: return "ok";
        case amcl::envslot::kUnchanged: return "unchanged";
        case amcl::envslot::kSealed: return "sealed";
        case amcl::envslot::kFull: return "full";
        case amcl::envslot::kInvalidArgument: return "invalid";
        case amcl::envslot::kConflict: return "conflict";
        case amcl::envslot::kUnavailable: return "unavailable";
        case amcl::envslot::kDetached: return "detached";
        case amcl::envslot::kWrongProcess: return "wrong-process";
        case amcl::envslot::kUnregistered: return "unregistered";
        case amcl::envslot::kPutenvFailed: return "putenv-failed";
        default: return "unknown";
    }
}

}  // namespace

int EnsureRendererRestartSlot() {
    // 干净进程登记为 "0"；已登记时保持原值（可能已是 "1"），调用方的污染检查在此之前完成。
    return amcl::envslot::ProcessRegistry().Register(
        amcl::envslot::kRendererRestartEnv, Kind::kBoolean, 1u, "0");
}

void PublishEarlyProcessEnvironment(const char* reason) {
    static std::once_flag once;
    std::call_once(once, [reason]() {
        auto& registry = amcl::envslot::ProcessRegistry();
        // 模块初始化只登记一个动态槽位：渲染器重启标记（它的首次登记同时发布登记表描述符，
        // SDL/libglfw/WSI 经它原位置 '1'）。输入前台位与发布尺寸只经窗口宿主 broker/快照提供，
        // 光标模式已无任何读者或写者，三者都不再占用环境名（I27-05 收尾）。
        const int restart = EnsureRendererRestartSlot();
        // 进程常量描述符：三者都有一次性守卫，这里是它们在进程内的首次（也是唯一一次）写入。
        amclBackendInputPublishAddress();
        inputBridge_publishAddress();
        // 新控制端口同样只发布owner地址；必须早于任意JVM/game/pump线程，不能在输入时重发。
        amclControlDeliveryPublishV1();
        // look端口同样只在预线程module发布，PID和owner表借出后保持不变。
        amclLookExecutionPublishV1();
        // 来源贡献端口也必须预线程发布；JNI/平台借原 Core 身份，输入时不建第二份 owner。
        amclSourceControlPublishV1();
        const int owner = amclWindowHostPublishOwner();
        // 前台门禁的初值同样是 0；在 owner 刚发布后显式写一次，日志里可见 broker 已可用。
        const int foreground = amclWindowHostSetInputForeground(0);
        const bool failed = restart < 0 || owner != 1 || foreground != 1;
        char summary[256];
        std::snprintf(summary, sizeof(summary),
            "event=env-early-publication reason=%s restart=%s windowHostOwner=%d "
            "inputForegroundBroker=%d slots=%u",
            reason ? reason : "unknown", StatusName(restart), owner, foreground, registry.Count());
        if (failed) {
            AMCL_LOG_E(LOG_TAG, "%{public}s", summary);
        } else {
            AMCL_LOG_I(LOG_TAG, "%{public}s", summary);
        }
    });
}

bool PrepareRuntimeEnvironmentSlots(bool sdlHostRuntime, std::string& error) {
    // 正常流程里模块初始化已发布过；这里只是保证“建 JVM 之前一定发布过”的后备，幂等。
    PublishEarlyProcessEnvironment("launch-backstop");
    auto& registry = amcl::envslot::ProcessRegistry();
    const int restart = EnsureRendererRestartSlot();
    // 两个文本槽位由 g_mcThread 在 phase_publishPlatformRuntime 原位填写，读者（JNI_OnLoad、
    // SDL_InitSubSystem）也在同一线程之后执行；登记时的空值被两者都当作“缺席/不可用”。
    // 已登记的名字重复登记返回 kOk 且保留当前值，所以同一进程的重试启动不会互相覆盖。
    const int bridge = registry.Register(
        AMCL_CALLBACK_BRIDGE_HOST_ENV, Kind::kText, kCallbackBridgeHostCapacity, "");
    const int sdl = sdlHostRuntime
        ? registry.Register(amcl::envslot::kSdlHostRuntimeEnv, Kind::kText, kSdlHostRuntimeCapacity, "")
        : static_cast<int>(amcl::envslot::kOk);
    const bool ok = restart >= 0 && bridge >= 0 && sdl >= 0;
    char summary[256];
    std::snprintf(summary, sizeof(summary),
        "event=env-runtime-slots restart=%s callbackBridge=%s sdlHostRuntime=%s(%d) slots=%u sealed=%d",
        StatusName(restart), StatusName(bridge), StatusName(sdl), sdlHostRuntime ? 1 : 0,
        registry.Count(), registry.Sealed() ? 1 : 0);
    if (!ok) {
        error = summary;
        AMCL_LOG_E(LOG_TAG, "%{public}s", summary);
        return false;
    }
    AMCL_LOG_I(LOG_TAG, "%{public}s", summary);
    return true;
}

void SealProcessEnvironment(const char* reason) {
    auto& registry = amcl::envslot::ProcessRegistry();
    // 只记录第一次封存；重复调用（例如同一进程里 DevTools 的 JVM 探针之后）保持幂等。
    if (registry.Sealed()) return;
    registry.Seal();
    AMCL_LOG_I(LOG_TAG, "event=env-sealed reason=%{public}s slots=%{public}u",
        reason ? reason : "unknown", registry.Count());
}

}  // namespace amcl::ohos

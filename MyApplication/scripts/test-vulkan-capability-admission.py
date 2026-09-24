"""验证 Vulkan 要求、生产 capability 投影与最终授权的一致性。

从当前生产文件逐字抽取判定与结果组装函数，编译时同时包含真实计划校验器和要求表。
替换范围仅为设备扫描、库存在性、shader 探针和日志；不访问 GPU 或应用进程。
宿主 PASS 只证明规则与接线，不代表真实设备或游戏通过。
"""
# 宿主测试临时目录统一外置，继续使用上下文退出时仅清理自身目录的语义。
from lib.workspace_paths import temporary_directory as workspace_temporary_directory
from pathlib import Path
import importlib.util
import subprocess
import sys
import os
import tempfile

folder = Path(__file__).resolve().parent
root = folder.parent
sys.path.insert(0, str(root / 'scripts'))
from lib.host_cpp import compile_cpp

# 使用仓库现有抽取器：注释/字符串中的花括号不影响函数边界，缺少正文直接报错。
spec = importlib.util.spec_from_file_location('audit_extract', root / 'scripts/generate-desktop-review-tests.py')
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)
original = (root / 'entry/src/main/cpp/platform/vulkan_probe.cpp').read_text(encoding='utf-8')
availability = original[original.index('bool synchronization2Usable('):original.index('// Zink (GL-on-Vulkan)')]
mapping = extract.block(original, original.index('GraphicsCapability ProbeGraphicsCapability('))

prefix = r'''
// 本文件由审查脚本从当前生产正文生成；系统边界为确定性替身，不代表真实设备结果。
#include "../../entry/src/main/cpp/platform/graphics_plan.cpp"
#include "../../entry/src/main/cpp/platform/vulkan_requirement_policy.cpp"
#include <iostream>
#include <stdexcept>
#if defined(_WIN32)
#include <process.h>
#define getpid _getpid
#else
#include <unistd.h>
#endif
#define AMCL_HAVE_VULKAN_HEADERS 1
#define AMCL_LOG_LEVEL_INFO 1
constexpr uint32_t kMcTargetApi = (1u << 22) | (2u << 12);
using amcl::graphics::GraphicsCapability;
using amcl::graphics::CapabilityEvidence;
// 注入一次完整设备扫描；各用例仅关闭一项已审计硬性能力。
struct VkScanResult {
    bool libLoaded=true, instanceCreated=true, hasDevice=true, hasKhrSurface=true, hasOhosSurface=true;
    bool deviceExtensionsQueried=true, featuresQueried=true, hasSwapchain=true, hasDynamicRendering=true;
    bool hasSynchronization2=true, hasPushDescriptor=true, hasVertexAttributeDivisor=true;
    bool fMultiDrawIndirect=true, fDrawIndirectFirstInstance=true, fFillModeNonSolid=true, fSamplerAnisotropy=true;
    bool featShaderDrawParameters=true, featTimelineSemaphore=true, featHostQueryReset=true;
    bool featSynchronization2=true, featDynamicRendering=true, featVertexAttributeInstanceRateDivisor=true;
    bool surfaceContractQueried=true, sdlSurfaceContract=true;
    uint32_t deviceApiRaw=kMcTargetApi, loaderApiRaw=kMcTargetApi, maxPushDescriptors=32;
    uint64_t surfaceGeneration=1;
    CapabilityEvidence surfaceEvidence=CapabilityEvidence::Yes, presentEvidence=CapabilityEvidence::Yes;
    CapabilityEvidence surfaceOrientationEvidence=CapabilityEvidence::Yes;
    std::string error, deviceName="fixture", driverName="fixture", deviceApiVersion="1.2", driverIdentity="fixture", surfaceReason="surface_queue_verified";
};
VkScanResult scan;
VkScanResult scanVulkan(void*, bool) { return scan; }
int amclLedgerGetLaunchActivity() { return 0; }
void amclLogWriteFor(int, int, const char*, const char*, ...) {}
bool artifactExists(const std::string&, const char*) { return true; }
bool probeShaderToolchain(const std::string&, std::string&) { return true; }
GraphicsCapability queryMobileGlDevice(const std::string&) { throw std::runtime_error("unexpected MobileGL route"); }
struct MobileReport { GraphicsCapability capability; };
template<class Query> MobileReport ProbeMobileGlCapability(const std::string&, Query, const std::string&, const std::string&) {
    throw std::runtime_error("unexpected MobileGL route");
}
'''
suffix = r'''
int main(int argc, char**) try {
    using namespace amcl::graphics;
    GraphicsPlan plan; std::string error;
    // 独立进程验证 26.4，避免强行复位已冻结的生产计划。920 缺失项允许进入最终授权，
    // 910 的剩余 divisor 缺失、未执行查询、窗口与 shader/资产等后续约束仍须拒绝。
    if (argc > 1) {
        if (!ParseGraphicsPlan("v=v2;profile=minecraft-vulkan;api=VULKAN;window=SDL3;route=minecraft-vulkan;transport=YES;strict=0;policy=ALLOW;game=DUAL;slot=LWJGL3;admission=VALIDATION;requirement=minecraft-26.4-snapshot1-sdl-vulkan-v1", plan, error)
            || !ActivateGraphicsPlan(plan, error)) throw std::runtime_error(error);
        scan = {}; scan.hasPushDescriptor = false; scan.maxPushDescriptors = 0;
        scan.hasDynamicRendering = scan.featDynamicRendering = false;
        auto result = ProbeGraphicsCapability(plan.profile, plan.requirement, plan.window, "/fixture", false);
        if (!GrantNativeVulkan(plan, result, error)) throw std::runtime_error("26.4 removed requirements still block: " + error);
        for (auto field : {&VkScanResult::hasVertexAttributeDivisor, &VkScanResult::featVertexAttributeInstanceRateDivisor,
                           &VkScanResult::featSynchronization2, &VkScanResult::featuresQueried, &VkScanResult::deviceExtensionsQueried,
                           &VkScanResult::sdlSurfaceContract}) {
            scan = {}; scan.*field = false;
            result = ProbeGraphicsCapability(plan.profile, plan.requirement, plan.window, "/fixture", false);
            if (GrantNativeVulkan(plan, result, error)) throw std::runtime_error("26.4 remaining prerequisite bypassed");
        }
        result = ProbeGraphicsCapability(plan.profile, plan.requirement, "GLFW", "/fixture", false);
        if (GrantNativeVulkan(plan, result, error)) throw std::runtime_error("26.4 wrong provider admitted");
        std::cout << "PASS: 26.4 plan, device assessment, SDL capability and final native grant\n";
        return 0;
    }
    if (!ParseGraphicsPlan("v=v2;profile=minecraft-vulkan;api=VULKAN;window=GLFW;route=minecraft-vulkan;transport=YES;strict=0;policy=ALLOW;game=DUAL;slot=LWJGL3;admission=VALIDATION;requirement=minecraft-26.2-conservative-v1", plan, error)
        || !ActivateGraphicsPlan(plan, error)) throw std::runtime_error(error);
    struct Case { const char* name; bool VkScanResult::* field; bool admitted; };
    const Case cases[] = {
        {"all-capabilities", nullptr, true},
        {"fillModeNonSolid", &VkScanResult::fFillModeNonSolid, false},
        {"multiDrawIndirect", &VkScanResult::fMultiDrawIndirect, false},
        {"samplerAnisotropy", &VkScanResult::fSamplerAnisotropy, false},
        {"shaderDrawParameters", &VkScanResult::featShaderDrawParameters, false},
        {"timelineSemaphore", &VkScanResult::featTimelineSemaphore, false},
        {"hostQueryReset", &VkScanResult::featHostQueryReset, false},
        {"vertexAttributeDivisor-extension", &VkScanResult::hasVertexAttributeDivisor, false},
        {"vertexAttributeInstanceRateDivisor", &VkScanResult::featVertexAttributeInstanceRateDivisor, false},
        {"pushDescriptor-negative-control", &VkScanResult::hasPushDescriptor, false},
        {"synchronization2-negative-control", &VkScanResult::featSynchronization2, false}
    };
    for (const auto& item : cases) {
        scan = {};
        if (item.field) scan.*item.field = false;
        std::string requirementReason;
        const bool requirement = capabilityAvailable(scan, requirementReason);
        const auto result = ProbeGraphicsCapability(plan.profile, plan.requirement, plan.window, "/fixture", false);
        const bool granted = GrantNativeVulkan(plan, result, error);
        if (requirement != (item.field == nullptr) || granted != item.admitted)
            throw std::runtime_error(std::string("unexpected result for ") + item.name);
        std::cout << item.name << ": requirement=" << requirement << " nativeGrant=" << granted
                  << " capabilityReason=" << result.reasonCode << '\n';
    }
    // GLFW世代也必须消费独立方向证据：不能因未进入SDL专有契约分支而重新放行。
    for (const auto state : {CapabilityEvidence::No, CapabilityEvidence::Unknown, CapabilityEvidence::NotRun}) {
        scan = {}; scan.surfaceOrientationEvidence = state;
        scan.surfaceReason = "native_vulkan_identity_transform_unavailable";
        const auto result = ProbeGraphicsCapability(plan.profile, plan.requirement, plan.window, "/fixture", false);
        if (GrantNativeVulkan(plan, result, error) || result.windowSurface == CapabilityEvidence::Yes ||
            result.reasonCode != scan.surfaceReason) throw std::runtime_error("GLFW orientation evidence bypassed");
    }
    // 正式版与预发布SDL requirement均执行实际投影；正例先确认可用，避免所有用例因
    // 别的缺失而一直拒绝、掩盖方向门漏接。最终grant的同一字段门由上面的真实26.2链覆盖。
    for (const char* requirement : {"minecraft-26.3-pre1-vulkan-conservative-v1", "minecraft-26.3-sdl-vulkan-conservative-v1",
                                   "minecraft-26.4-snapshot1-sdl-vulkan-v1"}) {
        for (const auto state : {CapabilityEvidence::Yes, CapabilityEvidence::No, CapabilityEvidence::Unknown, CapabilityEvidence::NotRun}) {
            scan = {}; scan.surfaceOrientationEvidence = state;
            scan.sdlSurfaceContract = state == CapabilityEvidence::Yes;
            scan.surfaceReason = state == CapabilityEvidence::Yes ? "surface_queue_verified" : "native_vulkan_identity_transform_unavailable";
            const auto result = ProbeGraphicsCapability("minecraft-vulkan", requirement, "SDL3", "/fixture", false);
            if (state == CapabilityEvidence::Yes && result.reasonCode != "launch_prerequisites_verified")
                throw std::runtime_error("SDL positive prerequisites failed: " + result.reasonCode);
            if ((result.windowSurface == CapabilityEvidence::Yes) != (state == CapabilityEvidence::Yes))
                throw std::runtime_error("SDL orientation evidence bypassed");
        }
    }
    std::cout << "PASS: production requirement assessment, capability projection and native grant agree on all hard requirements\n";
    return 0;
} catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
'''
# 编译完整生产链的临时翻译单元；保留原报告的生成样本不覆盖，反控只改临时正文。
prefix = prefix.replace('../../entry/', (root / 'entry').as_posix() + '/')
with workspace_temporary_directory(prefix='amcl-vulkan-admission-') as temporary:
    generated = Path(temporary) / 'probe.cpp'
    code = prefix + availability + '\nnamespace amcl::graphics {\n' + mapping + '\n}\n' + suffix
    generated.write_text(code, encoding='utf-8')
    binary = Path(temporary) / ('probe.exe' if os.name == 'nt' else 'probe')
    compile_cpp(generated, binary)
    subprocess.run([str(binary)], check=True, timeout=30)
    subprocess.run([str(binary), '26.4'], check=True, timeout=30)
    # 反控把已修复的消费字段恢复成错误阳性，必须由同一最终授权断言拒绝。
    anchor = 'result.featureBits = requirement.featureBits;'
    assert code.count(anchor) == 1
    generated.write_text(code.replace(anchor, 'result.featureBits = CapabilityEvidence::Yes;'), encoding='utf-8')
    compile_cpp(generated, binary)
    rejected = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0 and 'unexpected result for fillModeNonSolid' in rejected.stderr, rejected
    print('PASS: false-positive capability projection negative control rejected')
    # 反控移除公共方向证据门，恢复只有SDL受surface检查约束的旧形状，GLFW反例必须拒绝。
    orientation='scan.surfaceOrientationEvidence != CapabilityEvidence::Yes ||'
    assert code.count(orientation)==1
    generated.write_text(code.replace(orientation,'false ||'),encoding='utf-8')
    compile_cpp(generated,binary)
    rejected=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
    assert rejected.returncode!=0 and 'GLFW orientation evidence bypassed' in rejected.stderr,rejected
    print('PASS: omitted GLFW orientation admission negative control rejected')

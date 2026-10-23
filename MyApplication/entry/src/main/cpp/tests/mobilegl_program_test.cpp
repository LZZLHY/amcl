#include "graphics_scene_probe_common.h"
#include "../platform/vulkan_probe.h"
#include "../../../../../tests/graphics-semantics/mobilegl_program_scene.h"
#include "cJSON.h"
#include <mutex>

namespace {
std::mutex mutex;
bool Probe(const amcl::graphics::GraphicsRuntimeBinding& runtime,amcl::test_graphics_scene::Resolver& resolver,
           amcl::test_graphics_scene::Evidence& evidence) {
    using namespace amcl;
    // 预期来自本次真实系统Vulkan物理设备feature；不从GL版本、扩展广告或
    // renderer名字选择golden。当前平板无nativeFloat64，实际事实缺失时不跑。
    const char* raw=getVulkanCapabilityJson();if(!raw)throw std::runtime_error("physical Vulkan report unavailable");
    std::unique_ptr<cJSON,decltype(&cJSON_Delete)> facts(cJSON_Parse(raw),&cJSON_Delete);
    const auto* queried=facts?cJSON_GetObjectItemCaseSensitive(facts.get(),"baseFeaturesQueried"):nullptr;
    const auto* fp=facts?cJSON_GetObjectItemCaseSensitive(facts.get(),"shaderFloat64"):nullptr;
    const auto* gpu=facts?cJSON_GetObjectItemCaseSensitive(facts.get(),"deviceName"):nullptr;
    if(!cJSON_IsTrue(queried)||!cJSON_IsFalse(fp)||!cJSON_IsString(gpu)||!gpu->valuestring||!*gpu->valuestring)
        throw std::runtime_error("this target experiment requires measured nativeFloat64=false and physical device identity");
    evidence.Line("DRIVER_FACTS "+std::string(raw));
    evidence.Line("CALLER_EXPECTATION Float64=Unsupported source=actual-system-Vulkan-baseFeatures fullCoreQualified=0");
    std::unique_ptr<test_graphics_scene::Owner,test_graphics_scene::RetainOnFailure> owner(new test_graphics_scene::Owner{runtime});
    owner->state.auxiliary=1;owner->state.width=16;owner->state.height=16;
    graphics::EglContextState& state=owner->state;
    desktop::ContextRequest request{4,3,0x32001,false};std::string error;
    if(!runtime.contextOperations->create(runtime,state,request,owner->tid,error))throw std::runtime_error("production MGL context: "+error);
    if(runtime.egl.eglGetCurrentContext()!=state.context||runtime.egl.eglGetCurrentDisplay()!=state.display||state.contextOwnerTid!=owner->tid)
        throw std::runtime_error("MGL context is not current on owner thread");
    using GetString=const unsigned char*(*)(unsigned);
    auto string=reinterpret_cast<GetString>(test_graphics_scene::Resolve(&resolver,"glGetString"));
    if(!string)throw std::runtime_error("owned MGL GL string unavailable");
    const char* renderer=reinterpret_cast<const char*>(string(0x1f01));
    const char* version=reinterpret_cast<const char*>(string(0x1f02));
    // 名字这里只证明实际测试transport与物理feature事实属于同一路线，不用于
    // 判断precision是否正确。MGL GLES后端是另一个实验，不能借Vulkan事实选择。
    if(!renderer||std::string(renderer).find("Magma")==std::string::npos||std::string(renderer).find(gpu->valuestring)==std::string::npos)
        throw std::runtime_error("actual MGL transport/device differs from independent physical Vulkan facts");
    if(!version||state.actualContextMajor<4)throw std::runtime_error("#version400 input needs granted desktop GL4 context");
    evidence.Line("ACTUAL_GL renderer="+test_graphics_scene::Quote(renderer)+" version="+test_graphics_scene::Quote(version?version:"UNKNOWN")+
        " requested=4.3 actualMajor="+std::to_string(state.actualContextMajor)+" actualMinor="+std::to_string(state.actualContextMinor));
    const unsigned before=resolver.resolved;
    auto scene=graphics_semantics::RunMobileGlProgramContract(test_graphics_scene::Resolve,&resolver,graphics_semantics::Float64Expectation::Unsupported);
    evidence.Rows(scene.evidence);
    const bool complete=graphics_semantics::ValidateCompleteMobileGlProgramEvidence(scene);
    const bool retired=owner->Retire(error);
    evidence.Line("MOBILEGL_PROGRAM_RESULT sceneVersion=1 completed="+std::to_string(scene.completed)+" checks="+std::to_string(scene.checks)+
        " queryChecks="+std::to_string(scene.queryChecks)+" pixelChecks="+std::to_string(scene.pixelChecks)+" failures="+std::to_string(scene.failures)+
        " resolved="+std::to_string(resolver.resolved-before)+" evidenceComplete="+std::to_string(complete)+" ownerRetired="+std::to_string(retired)+
        " fullCoreQualified=0 coreFP64Qualified=0 retiredError="+test_graphics_scene::Quote(error));
    return complete&&scene.completed&&scene.failures==0&&retired;
}
}
const char* runMobileGlProgramTest() {
    std::lock_guard<std::mutex> lock(mutex);static thread_local std::string result;
    result=amcl::test_graphics_scene::Run("mobilegl-program","mobilegl","libmobilegl.so",Probe);return result.c_str();
}

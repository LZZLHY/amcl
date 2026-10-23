#include "graphics_scene_probe_common.h"
#include "../../../../../tests/graphics-semantics/mg_context_identity_scene.h"
#include <mutex>

namespace { std::mutex identityMutex; }

const char* runMgContextIdentityTest(int highFirst) {
    std::lock_guard<std::mutex> lock(identityMutex);
    static thread_local std::string text;
    const bool high=highFirst!=0;
    text=amcl::test_graphics_scene::Run(high?"mg-context-high-first":"mg-context-low-first",
        "mobileglues","libamcl_gl_host.so",
        [high](const amcl::graphics::GraphicsRuntimeBinding& runtime,
               amcl::test_graphics_scene::Resolver& resolver,
               amcl::test_graphics_scene::Evidence& evidence) {
            // 共享场景自行用原factory创建/退休两个heap owner，并通过真实生产
            // feature probe取得第二aux资格；wrapper不手工赋值准入或创建隐藏context。
            auto result=amcl::graphics_semantics::RunMgContextIdentity(runtime,high,
                amcl::test_graphics_scene::Resolve,&resolver);
            evidence.Rows(result.evidence);
            const bool complete=amcl::graphics_semantics::ValidateCompleteMgContextIdentityEvidence(result);
            evidence.Line("MG_CONTEXT_IDENTITY_RESULT sceneVersion=1 highFirst="+std::to_string(high)+
                " completed="+std::to_string(result.completed)+" checks="+std::to_string(result.checks)+
                " queryChecks="+std::to_string(result.queryChecks)+" pixelChecks="+std::to_string(result.pixelChecks)+
                " failures="+std::to_string(result.failures)+" evidenceComplete="+std::to_string(complete)+" coreQualified=0");
            return complete&&result.completed&&result.failures==0;
        });
    return text.c_str();
}

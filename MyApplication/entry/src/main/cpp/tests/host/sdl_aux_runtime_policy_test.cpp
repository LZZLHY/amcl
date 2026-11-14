// 实际辅助SDL状态机的顺序/身份负例；不替代EGL、broker或SDK接线实证。
#include "../../platform/sdl_aux_runtime_policy.h"
#include <cassert>
#include <cstdio>
using amcl::graphics::SdlAuxRuntimePolicy;
static AmclSdlAuxRequestV1 proof(uint64_t pid=11) {
    AmclSdlAuxRequestV1 p{};p.structSize=sizeof(p);p.abiVersion=1;p.processId=pid;
    p.display=reinterpret_cast<void*>(1);p.context=reinterpret_cast<void*>(2);
    p.drawSurface=reinterpret_cast<void*>(3);p.nativeWindow=reinterpret_cast<void*>(4);
    p.contextPermit=5;p.presentationToken=6;p.generation=7;p.resourceEpoch=8;return p;
}
int main() {
    SdlAuxRuntimePolicy launch;
    assert(launch.configure(0,20,30)==AMCL_SDL_AUX_INVALID);
    assert(launch.configure(11,20,30)==AMCL_SDL_AUX_FIRST);
    assert(launch.configure(11,20,30)==AMCL_SDL_AUX_READY);
    assert(launch.configure(11,21,30)==AMCL_SDL_AUX_CHANGED);
    assert(launch.claim(12,20,20,30,100,false)==AMCL_SDL_AUX_WRONG_PID);
    assert(launch.claim(11,20,20,31,100,false)==AMCL_SDL_AUX_CHANGED);
    assert(launch.claim(11,20,21,30,100,false)==AMCL_SDL_AUX_CHANGED);
    assert(launch.claim(11,21,20,30,100,true)==AMCL_SDL_AUX_UNPROVEN);
    assert(launch.claim(11,20,20,30,100,false)==AMCL_SDL_AUX_FIRST);
    assert(launch.claim(11,20,20,30,100,false)==AMCL_SDL_AUX_READY);
    assert(launch.claim(11,20,20,30,101,true)==AMCL_SDL_AUX_FOREIGN_INSTANCE);
    assert(launch.claim(11,21,20,30,100,true)==AMCL_SDL_AUX_WRONG_THREAD);
    assert(launch.quit(11,21,30,100)==AMCL_SDL_AUX_WRONG_THREAD);
    assert(launch.quit(11,20,31,100)==AMCL_SDL_AUX_FOREIGN_INSTANCE);
    assert(launch.quit(11,20,30,101)==AMCL_SDL_AUX_FOREIGN_INSTANCE);
    assert(launch.quit(11,20,30,100)==AMCL_SDL_AUX_READY);
    assert(launch.quit(11,20,30,100)==AMCL_SDL_AUX_READY);
    assert(launch.claim(11,20,20,30,100,true)==AMCL_SDL_AUX_RETIRED);
    assert(launch.configure(11,20,30)==AMCL_SDL_AUX_RETIRED);

    SdlAuxRuntimePolicy render;assert(render.configure(11,20,30)==AMCL_SDL_AUX_FIRST);
    auto p=proof();assert(render.publishVerified(proof(12),21)==AMCL_SDL_AUX_WRONG_PID);
    auto bad=p;bad.contextPermit=0;assert(render.publishVerified(bad,21)==AMCL_SDL_AUX_INVALID);
    assert(render.publishVerified(p,21)==AMCL_SDL_AUX_READY);
    assert(render.pendingProof(21) && !render.pendingProof(22));
    assert(render.claim(11,21,20,30,200,false)==AMCL_SDL_AUX_UNPROVEN);
    assert(render.claim(11,22,20,30,200,true)==AMCL_SDL_AUX_UNPROVEN);
    render.revoke(p.context,p.contextPermit+1);assert(render.pendingProof(21));
    render.revoke(p.context,p.contextPermit);assert(!render.pendingProof(21));
    assert(render.claim(11,21,20,30,200,true)==AMCL_SDL_AUX_UNPROVEN);
    assert(render.publishVerified(p,21)==AMCL_SDL_AUX_READY);
    assert(render.claim(11,21,20,30,200,true)==AMCL_SDL_AUX_FIRST);
    render.revoke(p.context,p.contextPermit);
    // 准入后临时解绑不剥夺同一SDK线程，第二个候选和第二映像仍无法进入。
    assert(render.claim(11,21,20,30,200,false)==AMCL_SDL_AUX_READY);
    assert(render.claim(11,20,20,30,200,true)==AMCL_SDL_AUX_WRONG_THREAD);
    assert(render.claim(11,21,20,30,201,true)==AMCL_SDL_AUX_FOREIGN_INSTANCE);
    assert(render.retireSession(11,21,30)==AMCL_SDL_AUX_WRONG_THREAD);
    assert(render.retireSession(12,20,30)==AMCL_SDL_AUX_WRONG_PID);
    assert(render.retireSession(11,20,31)==AMCL_SDL_AUX_CHANGED);
    assert(render.retireSession(11,20,30)==AMCL_SDL_AUX_READY);
    assert(render.claim(11,21,20,30,200,true)==AMCL_SDL_AUX_RETIRED);
    AmclSdlAuxResultV1 result{};render.describe(AMCL_SDL_AUX_RETIRED,result);
    assert(result.abiVersion==1 && result.structSize==sizeof(result) && result.ownerThreadId==21 &&
           result.launchThreadId==20 && result.sessionId==30 && result.instanceCookie==200 && result.proofGeneration>0);
    std::puts("SDL auxiliary policy: identity, launch/render candidates, unique instance and retirement passed");
}

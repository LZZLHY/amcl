// 辅助SDL准入的真实owner接线：自取进程/线程，复用已冻结EGL函数表、context permit
// 与NativeWindow broker。全程不创建窗口、input consumer或新EGL资源。
#include "sdl_aux_runtime.h"
#include "graphics_runtime_binding.h"
#include "window_host.h"
#include <sys/syscall.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <unistd.h>

namespace amcl::graphics {
// actual SDK的静态cookie只作为地址交给loader查询；不解引用该地址。必须落在
// 启动器已经cold核过的同一文件映像，两个namespace的同制品可有不同实际cookie。
static bool SelectedSdlImage(const SdlAuxRuntimePolicy& policy,uint64_t cookie) {
    if(!cookie)return false;
    Dl_info image{};struct stat file{};
    return dladdr(reinterpret_cast<void*>(static_cast<uintptr_t>(cookie)),&image) &&
        image.dli_fbase && image.dli_fname && stat(image.dli_fname,&file)==0 && S_ISREG(file.st_mode) &&
        policy.matchesArtifact(static_cast<uint64_t>(file.st_dev),static_cast<uint64_t>(file.st_ino));
}
// 调用者持有features.resourcesMutex；driver查询只读当前线程的已绑定状态。
// broker尾部只核身份，不持broker锁执行外部回调，锁顺序始终resources→broker。
static bool VerifiedPresentingEgl(const GraphicsRuntimeBinding& runtime,
                                 const AmclSdlAuxRequestV1& proof) {
    if(!runtime.egl.ready || !proof.display || !proof.context || !proof.drawSurface ||
       !proof.nativeWindow || !proof.contextPermit || !proof.presentationToken ||
       !proof.generation || !proof.resourceEpoch)return false;
    const auto found=runtime.features->contextPermits.find(proof.contextPermit);
    if(found==runtime.features->contextPermits.end() || found->second!=proof.context)return false;
    const auto surface=runtime.features->presentingSurfaces.find(proof.contextPermit);
    if(surface==runtime.features->presentingSurfaces.end() || !surface->second.matches(proof))return false;
    const auto& egl=runtime.egl;
    if(!egl.eglGetCurrentDisplay || !egl.eglGetCurrentContext || !egl.eglGetCurrentSurface ||
       egl.eglGetCurrentDisplay()!=proof.display || egl.eglGetCurrentContext()!=proof.context ||
       egl.eglGetCurrentSurface(EGL_DRAW)!=proof.drawSurface)return false;
    // READ surface可以合法地与上屏DRAW不同；呈现资格只依据真实draw surface。
    const auto* broker=amclWindowHostGetBroker();
    return broker && broker->abiVersion==AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION &&
        broker->structSize>=AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_IDENTITY_SIZE &&
        broker->matchesPresentationIdentity &&
        broker->matchesPresentationIdentity(proof.nativeWindow,proof.generation,
            proof.presentationToken,proof.resourceEpoch)==1;
}

int SdlAuxRuntimeOperation(const GraphicsRuntimeBinding& runtime,uint32_t operation,
                          const AmclSdlAuxRequestV1* request,AmclSdlAuxResultV1* output) {
    const uint64_t pid=static_cast<uint64_t>(getpid());
    // fork拒绝必须早于任何继承mutex和driver/broker访问。
    if(runtime.processId!=static_cast<int>(pid))return AMCL_SDL_AUX_WRONG_PID;
    if(!runtime.features || !request || request->structSize<sizeof(*request) || request->abiVersion!=1 ||
       request->reserved || !output || output->structSize<sizeof(*output) || output->abiVersion!=1)
        return AMCL_SDL_AUX_INVALID;
    if(request->processId!=pid)return AMCL_SDL_AUX_WRONG_PID;
    auto& features=*runtime.features;
    if(operation==AMCL_SDL_AUX_PEEK_ACTIVE) {
        // alive的acquire对应首次claim的release；身份只写一次，退休并发不改这些值。
        if(!features.sdlAuxAlive.load(std::memory_order_acquire))return AMCL_SDL_AUX_RETIRED;
        if(request->sessionId!=features.sdlAuxSession || request->instanceCookie!=features.sdlAuxInstance ||
           request->launchThreadId!=features.sdlAuxLaunchThread)return AMCL_SDL_AUX_CHANGED;
        *output={sizeof(*output),1u,AMCL_SDL_AUX_READY,features.sdlAuxLaunchThread,
            features.sdlAuxOwnerThread,0u,features.sdlAuxSession,features.sdlAuxInstance,0u};
        return AMCL_SDL_AUX_READY;
    }
    const int32_t tid=static_cast<int32_t>(syscall(SYS_gettid));
    if(tid<=0)return AMCL_SDL_AUX_WRONG_THREAD;
    std::lock_guard<std::recursive_mutex> lock(features.resourcesMutex);
    auto& policy=features.sdlAux;
    int result=AMCL_SDL_AUX_INVALID;
    switch(operation) {
        case AMCL_SDL_AUX_CONFIGURE:
            if(!request->selectedFileInode)result=AMCL_SDL_AUX_INVALID;
            else result=request->launchThreadId==tid ? policy.configure(pid,tid,request->sessionId,
                request->selectedFileDevice,request->selectedFileInode) : AMCL_SDL_AUX_WRONG_THREAD;
            break;
        case AMCL_SDL_AUX_PUBLISH_EGL:
            if(policy.configured(pid) && VerifiedPresentingEgl(runtime,*request))
                result=policy.publishVerified(*request,tid);
            else result=AMCL_SDL_AUX_UNPROVEN;
            break;
        case AMCL_SDL_AUX_REVOKE_EGL:
            // 旧线程的迟到解绑不能撤销新线程已提交的证明。
            if(policy.pendingProof(tid)) { policy.revoke(request->context,request->contextPermit);result=AMCL_SDL_AUX_READY; }
            else result=AMCL_SDL_AUX_UNPROVEN;
            break;
        case AMCL_SDL_AUX_CLAIM: {
            // 首次实际实例必须核制品；锁存之后只接受同cookie/TID，避免重复Init依赖磁盘重查。
            if(!policy.instance() && !SelectedSdlImage(policy,request->instanceCookie)) {
                result=AMCL_SDL_AUX_FOREIGN_INSTANCE;break;
            }
            const auto* proof=policy.pendingProof(tid);
            const bool verified=!policy.instance() && proof && VerifiedPresentingEgl(runtime,*proof);
            result=policy.claim(pid,tid,request->launchThreadId,request->sessionId,request->instanceCookie,verified);
            if(result==AMCL_SDL_AUX_FIRST){
                features.sdlAuxSession=request->sessionId;features.sdlAuxInstance=request->instanceCookie;
                features.sdlAuxLaunchThread=request->launchThreadId;features.sdlAuxOwnerThread=tid;
                features.sdlAuxAlive.store(true,std::memory_order_release);
            }
            break;
        }
        case AMCL_SDL_AUX_QUIT:
            result=policy.quit(pid,tid,request->sessionId,request->instanceCookie);
            if(result>=0)features.sdlAuxAlive.store(false,std::memory_order_release);break;
        case AMCL_SDL_AUX_RETIRE_SESSION:
            result=policy.retireSession(pid,tid,request->sessionId);
            if(result>=0)features.sdlAuxAlive.store(false,std::memory_order_release);break;
        default:break;
    }
    policy.describe(result,*output);
    return result;
}
}

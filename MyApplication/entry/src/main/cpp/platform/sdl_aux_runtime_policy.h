#pragma once
// 辅助SDL唯一实例/线程的纯状态机。调用者须持graphics owner资源锁，并在任何锁之前
// 拒绝fork继承的PID。驱动/broker实证由宿主接线完成，不能从Java参数传入“已验证”布尔值。
#include "sdl_aux_runtime_abi.h"

namespace amcl::graphics {
// 仅供同一 libentry 的启动器与图形宿主使用，SDK 仍用原 claim/peek/quit ABI。
inline constexpr uint32_t SdlControllerRequestVersion = 2;
class SdlAuxRuntimePolicy final {
    uint64_t pid_=0, session_=0, instance_=0, generation_=0;
    uint64_t fileDevice_=0,fileInode_=0;
    int32_t launch_=0, owner_=0;
    bool retired_=false, proofValid_=false, controllerOnly_=false;
    AmclSdlAuxRequestV1 proof_{};
    int32_t proofThread_=0;
public:
    int configure(uint64_t pid,int32_t thread,uint64_t session,uint64_t fileDevice=0,uint64_t fileInode=0,bool controllerOnly=false) noexcept {
        if(!pid || thread<=0 || !session)return AMCL_SDL_AUX_INVALID;
        if(retired_)return AMCL_SDL_AUX_RETIRED;
        if(pid_)return pid_==pid && launch_==thread && session_==session && fileDevice_==fileDevice && fileInode_==fileInode && controllerOnly_==controllerOnly ? AMCL_SDL_AUX_READY : AMCL_SDL_AUX_CHANGED;
        if(controllerOnly && !fileInode)return AMCL_SDL_AUX_INVALID;
        controllerOnly_=controllerOnly;
        pid_=pid;launch_=thread;session_=session;fileDevice_=fileDevice;fileInode_=fileInode;return AMCL_SDL_AUX_FIRST;
    }
    bool configured(uint64_t pid) const noexcept { return pid_==pid && session_ && !retired_; }
    uint64_t session() const noexcept { return session_; }
    int32_t launchThread() const noexcept { return launch_; }
    uint64_t instance() const noexcept { return instance_; }
    bool matchesArtifact(uint64_t device,uint64_t inode) const noexcept {
        return fileInode_ && inode==fileInode_ && device==fileDevice_;
    }
    const AmclSdlAuxRequestV1* pendingProof(int32_t tid) const noexcept {
        return !retired_ && proofValid_ && proofThread_==tid ? &proof_ : nullptr;
    }
    // 只接受宿主刚核过EGL current、已提交permit及broker完整身份的值快照。
    int publishVerified(const AmclSdlAuxRequestV1& proof,int32_t actualThread) noexcept {
        if(!configured(proof.processId))return retired_?AMCL_SDL_AUX_RETIRED:AMCL_SDL_AUX_WRONG_PID;
        if(proof.sessionId && proof.sessionId!=session_)return AMCL_SDL_AUX_CHANGED;
        if(actualThread<=0 || !proof.context || !proof.display || !proof.drawSurface || !proof.nativeWindow ||
           !proof.contextPermit || !proof.presentationToken || !proof.generation || !proof.resourceEpoch)return AMCL_SDL_AUX_INVALID;
        proof_=proof;proofThread_=actualThread;proofValid_=true;++generation_;return AMCL_SDL_AUX_READY;
    }
    // context退休/解绑只撤销尚未消费的角色证明；已锁定SDL main允许暂时无GL current。
    void revoke(void* context,uint64_t permit) noexcept {
        if(proofValid_ && proof_.context==context && proof_.contextPermit==permit){proofValid_=false;++generation_;}
    }
    int claim(uint64_t pid,int32_t tid,int32_t declaredLaunch,uint64_t session,uint64_t instance,
              bool currentRenderProofVerified) noexcept {
        if(!pid || tid<=0 || !instance || !session)return AMCL_SDL_AUX_INVALID;
        if(pid_!=pid)return AMCL_SDL_AUX_WRONG_PID;
        if(retired_)return AMCL_SDL_AUX_RETIRED;
        if(session_!=session || launch_!=declaredLaunch)return AMCL_SDL_AUX_CHANGED;
        if(instance_) {
            if(instance_!=instance)return AMCL_SDL_AUX_FOREIGN_INSTANCE;
            return owner_==tid?AMCL_SDL_AUX_READY:AMCL_SDL_AUX_WRONG_THREAD;
        }
        // 已核独立制品自身禁止 video/显示服务及主输入。首个真实手柄消费者可以是
        // EGL 或 Vulkan 游戏渲染线程；首次绑定后仍只允许同 PID、会话、实例与线程。
        if(!controllerOnly_ && tid!=launch_ && !(pendingProof(tid) && currentRenderProofVerified))return AMCL_SDL_AUX_UNPROVEN;
        instance_=instance;owner_=tid;return AMCL_SDL_AUX_FIRST;
    }
    int quit(uint64_t pid,int32_t tid,uint64_t session,uint64_t instance) noexcept {
        if(pid_!=pid)return AMCL_SDL_AUX_WRONG_PID;
        if(session_!=session || !instance || instance_!=instance)return AMCL_SDL_AUX_FOREIGN_INSTANCE;
        if(owner_!=tid)return AMCL_SDL_AUX_WRONG_THREAD;
        if(retired_)return AMCL_SDL_AUX_READY;
        retired_=true;proofValid_=false;++generation_;return AMCL_SDL_AUX_READY;
    }
    int retireSession(uint64_t pid,int32_t tid,uint64_t session) noexcept {
        if(pid_!=pid)return AMCL_SDL_AUX_WRONG_PID;
        if(session_!=session)return AMCL_SDL_AUX_CHANGED;
        if(launch_!=tid)return AMCL_SDL_AUX_WRONG_THREAD;
        if(retired_)return AMCL_SDL_AUX_READY;
        retired_=true;proofValid_=false;++generation_;return AMCL_SDL_AUX_READY;
    }
    void describe(int status,AmclSdlAuxResultV1& out) const noexcept {
        out={sizeof(out),1u,status,launch_,owner_,0u,session_,instance_,generation_};
    }
};
}

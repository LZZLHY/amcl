#ifndef AMCL_INPUT_LIBRARY_CLAIM_H
#define AMCL_INPUT_LIBRARY_CLAIM_H

// 本局库解析结果与进程DSO寿命之间的薄owner：只认输入计划选定的精确绝对制品路径。
// 不从Graphics profile重选，不按SONAME/RTLD_DEFAULT猜库，也不初始化SDL/游戏class。
// SDL可在JVM另一个namespace装入同一制品；此claim只证明选定制品cold协议，不证明
// 游戏实例或consumer Ready。SDK实际初始化仍核自身协议、实例线程及唯一Core owner。
#include "sdl_input_contract.h"
#include "runtime_bootstrap_contract.h"
#include <mutex>
#include <string>
#ifndef _WIN32
#include <unistd.h>
#endif

namespace amcl::input {

// 读实际OS进程，不以session替代进程边界；在fork child触碰继承mutex前拒绝旧claim。
inline uint32_t InputLibraryProcessId(){
#ifdef _WIN32
    return static_cast<uint32_t>(GetCurrentProcessId());
#else
    return static_cast<uint32_t>(getpid());
#endif
}

// 路径来自同次实际解析的包内nativeDir+已校验binding；这里只校绝对形式，绝不补搜索路径。
inline bool AbsoluteInputLibraryPath(const std::string& path){
#ifdef _WIN32
    return path.size()>2&&((path[1]==':'&&(path[2]=='/'||path[2]=='\\'))||
        (path[0]=='\\'&&path[1]=='\\'));
#else
    return !path.empty()&&path[0]=='/';
#endif
}

class ProcessSdlInputLibraryClaim final {
public:
    // owner在模块/进程建立时构造。只有实际SDL输入plan才调用Claim，非SDL路线不装库。
    ProcessSdlInputLibraryClaim():process_(InputLibraryProcessId()){}
    ProcessSdlInputLibraryClaim(const ProcessSdlInputLibraryClaim&)=delete;
    ProcessSdlInputLibraryClaim& operator=(const ProcessSdlInputLibraryClaim&)=delete;
    // 故意不dlclose：准备失败、主函数返回或页面销毁不能证明没有SDK/Java消费者仍借用DSO。
    ~ProcessSdlInputLibraryClaim()=default;

    // 首次装入精确制品并永久保留handle；同一路径幂等，不把已有SDK换成另一路径/库。
    // 成功只表示该selected artifact满足冻结契约。allowLegacy必须来自显式legacy计划，
    // 只能接受缺marker；错误版本/不同映像永不降级。失败不假Ready或卸载已借出映像。
    bool Claim(const std::string& exactPath,bool allowLegacy,std::string& error){
        if(process_!=InputLibraryProcessId()){error="InputContractMismatch:sdl_claim_inherited";return false;}
        if(!AbsoluteInputLibraryPath(exactPath)){error="InputContractMismatch:sdl_path_not_absolute";return false;}
        std::lock_guard<std::mutex> lock(mutex_);
        if(handle_&&path_!=exactPath){error="InputContractMismatch:sdl_selected_artifact_changed";return false;}
        if(!handle_){
            // 候选字符串先分配；dlopen成功后用noexcept swap保全实际DSO选择，不能丢失claim。
            std::string candidate=exactPath;
#ifdef _WIN32
            void* loaded=reinterpret_cast<void*>(LoadLibraryA(candidate.c_str()));
#else
            void* loaded=dlopen(candidate.c_str(),RTLD_NOW|RTLD_LOCAL);
#endif
            if(!loaded){error="InputContractMismatch:sdl_selected_artifact_unloadable";return false;}
            handle_=loaded;path_.swap(candidate);
        }
        uint32_t observed=0;
        const int result=amclCheckSelectedSdlInputContractV1(handle_,path_.c_str(),allowLegacy,&observed);
        if(result<0){error=amclSdlInputContractReason(result);return false;}
        // ordered-look计划必须同精确库另具look-v1冷标识；旧control标识不能承诺识别1020。
        uint32_t lookObserved=0;
        const int lookResult=amclCheckSelectedSdlLookContractV1(handle_,path_.c_str(),allowLegacy,&lookObserved);
        if(lookResult<0){error=amclSdlLookContractReason(lookResult);return false;}
        protocol_=observed;lookProtocol_=lookObserved;
        legacy_=result==AMCL_SDL_INPUT_CONTRACT_LEGACY||lookResult==AMCL_SDL_INPUT_CONTRACT_LEGACY;
        verified_=true;error.clear();return true;
    }

    // 启动线程只读已冻结claim，不重装/重查SDL，也不把冷协议当作窗口/游戏消费者Ready。
    bool VerifiedForCurrentProcess(bool requireCommon)const{
        if(process_!=InputLibraryProcessId())return false;
        std::lock_guard<std::mutex> lock(mutex_);
        return verified_&&handle_&&(!requireCommon||(protocol_==1&&lookProtocol_==1&&!legacy_));
    }
    uint32_t Protocol()const{
        if(process_!=InputLibraryProcessId())return 0;
        std::lock_guard<std::mutex> lock(mutex_);return verified_?protocol_:0;
    }
    /** 独立私有look声明，0明确未验证；不将common-control数值冒充look能力。 */
    uint32_t LookProtocol()const{
        if(process_!=InputLibraryProcessId())return 0;
        std::lock_guard<std::mutex> lock(mutex_);return verified_?lookProtocol_:0;
    }
private:
    const uint32_t process_;
    mutable std::mutex mutex_;
    void* handle_=nullptr;
    std::string path_;
    uint32_t protocol_=0,lookProtocol_=0;
    bool legacy_=false,verified_=false;
};

// 新AMCL输入plan只允许选定SDK的同映像执行表。SDL3_DYNAMIC_API能把标准API跳转到
// 另一个SDK，从而绕过先前cold marker；非空即明确拒绝，不删除用户值制造成功。
// 实际环境读取由启动入口完成，纯函数便于对缺席/空串/有效非空值作直接正反验证。
inline bool ValidateSelectedSdlEnvironment(const char* dynamicApi,std::string& error){
    if(dynamicApi&&*dynamicApi){error="InputContractMismatch:sdl_dynamic_api_override";return false;}
    error.clear();return true;
}

// 让LWJGL真实消费与这次cold选取一致：原默认basename是同一binding的旧表达，可规范成
// 实际绝对路径；用户指定另一值/裸属性必须拒绝，不能先删除覆盖参数来伪造契约成功。
// 先验证全部参数再提交候选args/properties，失败保持原向量不变；不修改环境或启动Java。
inline bool FreezeSelectedSdlProperty(std::vector<std::string>& arguments,
        std::vector<amcl::jvm::BootstrapProperty>& properties,const std::string& exactPath,
        std::string& error){
    if(!AbsoluteInputLibraryPath(exactPath)){error="InputContractMismatch:sdl_path_not_absolute";return false;}
    const std::string key="org.lwjgl.sdl.libname";
    const std::string selected="-D"+key+"="+exactPath;
    for(const auto& value:arguments){
        if(amcl::jvm::PropertyKey(value)==key&&value!="-D"+key+"=libSDL3.so"&&value!=selected){
            error="InputContractMismatch:sdl_library_override";return false;
        }
    }
    bool found=false;auto nextProperties=properties;auto nextArguments=arguments;
    for(auto& value:nextProperties)if(value.first==key){value.second=exactPath;found=true;}
    if(!found){error="InputContractMismatch:sdl_property_missing";return false;}
    for(auto& value:nextArguments)if(amcl::jvm::PropertyKey(value)==key)value=selected;
    arguments.swap(nextArguments);properties.swap(nextProperties);error.clear();return true;
}
}
#endif

#ifndef AMCL_SDL_INPUT_CONTRACT_H
#define AMCL_SDL_INPUT_CONTRACT_H

// 输入启动子契约的cold检查：只查调用方这次实际选定且仍持有的SDL DSO。
// 不选择图形profile、不另dlopen、不读取环境、不SDL_Init、不创建consumer或加载Java类。
// 私有标识只声明该SDL制品支持common control v1，成功不意味着游戏或设备已Ready。
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#include <link.h>
#include <sys/stat.h>
#endif

#define AMCL_SDL_INPUT_CONTROL_SYMBOL "SDL_AMCL_InputControlProtocolV1"
#define AMCL_SDL_INPUT_CONTROL_V1 1u
#define AMCL_SDL_INPUT_LOOK_SYMBOL "SDL_AMCL_InputLookProtocolV1"
#define AMCL_SDL_INPUT_LOOK_V1 1u
enum AmclSdlInputContractResult {
    AMCL_SDL_INPUT_CONTRACT_OK=0,
    // 只有调用方明确选择legacy计划才能接受标识缺席，不能把坏标识降级为此结果。
    AMCL_SDL_INPUT_CONTRACT_LEGACY=1,
    AMCL_SDL_INPUT_CONTRACT_MISSING=-1,
    AMCL_SDL_INPUT_CONTRACT_VERSION=-2,
    AMCL_SDL_INPUT_CONTRACT_FOREIGN=-3,
    AMCL_SDL_INPUT_CONTRACT_ARGUMENT=-4,
    AMCL_SDL_INPUT_CONTRACT_NOT_SDL=-5
};

#ifndef _WIN32
// 证明准备调用的私有getter属于已选SDL的可执行PT_LOAD，不以非零指针直接调用。
struct AmclSdlExecutableCheck {uintptr_t address;bool executable;};
static inline int amclSdlVisitExecutable(struct dl_phdr_info* image,size_t,void* opaque){
    auto* check=static_cast<AmclSdlExecutableCheck*>(opaque);
    for(size_t index=0;index<image->dlpi_phnum;++index){
        const auto* segment=&image->dlpi_phdr[index];
        if(segment->p_type!=PT_LOAD||!(segment->p_flags&PF_X)||segment->p_vaddr>UINTPTR_MAX-static_cast<uintptr_t>(image->dlpi_addr))continue;
        const uintptr_t start=static_cast<uintptr_t>(image->dlpi_addr)+static_cast<uintptr_t>(segment->p_vaddr);
        if(check->address>=start&&check->address-start<segment->p_memsz){check->executable=true;return 1;}
    }
    return 0;
}
#endif

// 输入selected仅能是现有库owner持有的真实LoadLibrary/dlopen结果，不接受用户给的整数。
// actual输出实际协议（缺席为0）；allowLegacy由冻结计划明确决定，不能从检查失败推导。
// 先校准SDL_GetVersion确在该handle可见，再核私有getter与标准SDL导出同映像：dlsym会
// 搜索依赖，其他DSO提供一个假marker不能替代实际选中SDL。调用结束后不缓存任何借用指针。
static inline int amclCheckSelectedSdlProtocolV1(void* selected,const char* exactPath,
        const char* protocolSymbol,uint32_t expected,bool allowLegacy,uint32_t* actual){
    if(actual)*actual=0;
    if(!selected||!exactPath||!*exactPath||!actual||!protocolSymbol||!expected)return AMCL_SDL_INPUT_CONTRACT_ARGUMENT;
#ifdef _WIN32
    const auto module=static_cast<HMODULE>(selected);
    void* standard=reinterpret_cast<void*>(GetProcAddress(module,"SDL_GetVersion"));
    void* marker=reinterpret_cast<void*>(GetProcAddress(module,protocolSymbol));
    if(!standard)return AMCL_SDL_INPUT_CONTRACT_NOT_SDL;
    HMODULE standardOwner=nullptr,markerOwner=nullptr;MEMORY_BASIC_INFORMATION memory{};
    if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCSTR>(standard),&standardOwner)||standardOwner!=module)return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
    if(!VirtualQuery(standard,&memory,sizeof(memory)))return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
    const DWORD standardAccess=memory.Protect&0xff;
    if(memory.State!=MEM_COMMIT||(memory.Protect&PAGE_GUARD)||
       (standardAccess!=PAGE_EXECUTE&&standardAccess!=PAGE_EXECUTE_READ&&standardAccess!=PAGE_EXECUTE_READWRITE&&standardAccess!=PAGE_EXECUTE_WRITECOPY))return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
    if(!marker)return allowLegacy?AMCL_SDL_INPUT_CONTRACT_LEGACY:AMCL_SDL_INPUT_CONTRACT_MISSING;
    if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCSTR>(marker),&markerOwner)||
       standardOwner!=module||markerOwner!=module||!VirtualQuery(marker,&memory,sizeof(memory)))return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
    const DWORD access=memory.Protect&0xff;
    if(memory.State!=MEM_COMMIT||(memory.Protect&PAGE_GUARD)||
       (access!=PAGE_EXECUTE&&access!=PAGE_EXECUTE_READ&&access!=PAGE_EXECUTE_READWRITE&&access!=PAGE_EXECUTE_WRITECOPY))return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
#else
    void* standard=dlsym(selected,"SDL_GetVersion");
    void* marker=dlsym(selected,protocolSymbol);
    if(!standard)return AMCL_SDL_INPUT_CONTRACT_NOT_SDL;
    Dl_info standardOwner{},markerOwner{};
    // OHOS SDK仅声明RTLD_DI_LINKMAP、没有dlinfo声明/导出，不能自行声明调用不存在接口。
    // exactPath是本次已选绝对制品；核actual standard owner的dev/inode，避免std+marker
    // 都从selected的另一个依赖DSO得到时，仅“彼此同base”就错误接受。路径别名可相同inode，
    // 不按basename猜制品；真实SDK映像由既有handle pin，准备期包内制品不允许被替换。
    struct stat expectedFile{},standardFile{};
    if(!dladdr(standard,&standardOwner)||!standardOwner.dli_fbase||!standardOwner.dli_fname||
       stat(exactPath,&expectedFile)!=0||stat(standardOwner.dli_fname,&standardFile)!=0||
       expectedFile.st_dev!=standardFile.st_dev||expectedFile.st_ino!=standardFile.st_ino)return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
    AmclSdlExecutableCheck standardCheck{reinterpret_cast<uintptr_t>(standard),false};
    dl_iterate_phdr(amclSdlVisitExecutable,&standardCheck);if(!standardCheck.executable)return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
    if(!marker)return allowLegacy?AMCL_SDL_INPUT_CONTRACT_LEGACY:AMCL_SDL_INPUT_CONTRACT_MISSING;
    if(!dladdr(marker,&markerOwner)||
       standardOwner.dli_fbase!=markerOwner.dli_fbase)return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
    AmclSdlExecutableCheck check{reinterpret_cast<uintptr_t>(marker),false};
    dl_iterate_phdr(amclSdlVisitExecutable,&check);
    if(!check.executable)return AMCL_SDL_INPUT_CONTRACT_FOREIGN;
#endif
    using Getter=uint32_t(*)(void);
    *actual=reinterpret_cast<Getter>(marker)();
    return *actual==expected?AMCL_SDL_INPUT_CONTRACT_OK:AMCL_SDL_INPUT_CONTRACT_VERSION;
}
/** control-v1与look-v1是独立冷声明，共用同一实际selected映像/exec/dev-inode判据。 */
static inline int amclCheckSelectedSdlInputContractV1(void* selected,const char* exactPath,bool allowLegacy,uint32_t* actual){
    return amclCheckSelectedSdlProtocolV1(selected,exactPath,AMCL_SDL_INPUT_CONTROL_SYMBOL,1,allowLegacy,actual);
}
static inline int amclCheckSelectedSdlLookContractV1(void* selected,const char* exactPath,bool allowLegacy,uint32_t* actual){
    return amclCheckSelectedSdlProtocolV1(selected,exactPath,AMCL_SDL_INPUT_LOOK_SYMBOL,1,allowLegacy,actual);
}
/** look失败具名独立，不让旧common-control标记被记录成已支持新1020运输。 */
static inline const char* amclSdlLookContractReason(int result){
    switch(result){case AMCL_SDL_INPUT_CONTRACT_MISSING:return "InputContractMismatch:sdl_look_marker_missing";
        case AMCL_SDL_INPUT_CONTRACT_VERSION:return "InputContractMismatch:sdl_look_protocol_version";
        case AMCL_SDL_INPUT_CONTRACT_FOREIGN:return "InputContractMismatch:sdl_look_marker_foreign";
        default:return "InputContractMismatch:sdl_look_selected_handle_invalid";}
}

// 具名原因可直接接启动失败回执；不输出实际路径/用户数据，也不把拒绝写成消费READY。
static inline const char* amclSdlInputContractReason(int result){
    switch(result){
        case AMCL_SDL_INPUT_CONTRACT_OK:return "common_control_v1";
        case AMCL_SDL_INPUT_CONTRACT_LEGACY:return "explicit_legacy_plan";
        case AMCL_SDL_INPUT_CONTRACT_MISSING:return "InputContractMismatch:sdl_common_marker_missing";
        case AMCL_SDL_INPUT_CONTRACT_VERSION:return "InputContractMismatch:sdl_common_protocol_version";
        case AMCL_SDL_INPUT_CONTRACT_FOREIGN:return "InputContractMismatch:sdl_common_marker_foreign";
        case AMCL_SDL_INPUT_CONTRACT_NOT_SDL:return "InputContractMismatch:sdl_standard_symbol_missing";
        default:return "InputContractMismatch:sdl_selected_handle_invalid";
    }
}
#endif

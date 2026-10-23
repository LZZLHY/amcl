#pragma once
// TestHooks专用公共编排：冷进程、生产runtime、同映像解析、checked I/O与外部
// RETURN共用；不包含被测shader/state算法，不替换provider或接管游戏窗口。
#include "tests.h"
#include "test_loaded_image_evidence.h"
#include "../platform/graphics_runtime_binding.h"
#include "../platform/mobilegl_capability.h"
#include "../utils/amcl_log.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>

namespace amcl::test_graphics_scene {
inline std::string Quote(const std::string& text) {
    std::ostringstream out; out << '"';
    for (unsigned char c : text) {
        if (c=='"'||c=='\\') out << '\\' << char(c);
        else if(c=='\n') out << "\\n"; else if(c=='\r') out << "\\r";
        else if(c=='\t') out << "\\t"; else if(c<32) throw std::runtime_error("unsupported control byte in evidence string");
        else out << char(c);
    }
    out << '"'; return out.str();
}
struct Evidence {
    FILE* stream = nullptr;
    std::string text;
    void Line(const std::string& line) {
        if (line.find('\n') != std::string::npos) throw std::runtime_error("evidence line contains raw newline");
        if (!stream || std::fprintf(stream,"%s\n",line.c_str())<0 || std::fflush(stream)!=0 || std::ferror(stream))
            throw std::runtime_error("evidence write/flush failed");
        text += line + '\n';
    }
    void Rows(const std::string& jsonl) { std::istringstream in(jsonl);std::string line;while(std::getline(in,line)) Line(line); }
};
struct Resolver {
    const graphics::GraphicsRuntimeBinding& runtime;
    Evidence& evidence;
    void* imageBase;
    unsigned resolved=0,rejected=0;
};
inline void* Resolve(void* user,const char* name) {
    auto& resolver=*static_cast<Resolver*>(user);
    void* address=resolver.runtime.glProc(name);Dl_info owner{};
    const bool owned=address&&dladdr(address,&owner)&&owner.dli_fbase==resolver.imageBase&&owner.dli_fname;
    ++resolver.resolved;if(!owned)++resolver.rejected;
    std::ostringstream out;out << "FUNCTION name=" << name << " address=" << address << " owned=" << owned
        << " image=" << (owner.dli_fname?owner.dli_fname:"UNKNOWN");
    resolver.evidence.Line(out.str());return owned?address:nullptr;
}
// 与生产资源账本保持相同owner地址；destroy失败时故意保留堆状态至已认领诊断
// 进程重启，不让析构栈对象变成账本悬空指针，也不绕owner直接DestroyContext。
struct Owner {
    const graphics::GraphicsRuntimeBinding& runtime; graphics::EglContextState state{};
    int tid=static_cast<int>(gettid()); bool retired=false;
    bool Retire(std::string& error) {if(retired)return true;retired=runtime.contextOperations->destroy(runtime,state,tid,error);return retired;}
};
struct RetainOnFailure {
    void operator()(Owner* owner) const noexcept {
        if(!owner)return;try{std::string error;if(owner->Retire(error)){delete owner;return;}}
        catch(...){if(owner->retired){delete owner;return;}}
        AMCL_LOG_E("MG_DEPTH_RANGE_PROBE","diagnostic owner retained until process restart");
    }
};
using Probe = std::function<bool(const graphics::GraphicsRuntimeBinding&,Resolver&,Evidence&)>;
inline std::string Run(const char* name,const char* profile,const char* library,const Probe& probe) {
    const auto ns=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    const auto unixNs=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    const std::string id=std::to_string(getpid())+"-"+std::to_string(ns);
    const std::string root="/data/storage/el2/base/haps/entry/files/graphics-semantic-probes";
    const std::string directory=root+"/"+id, path=directory+"/result.txt";
    Evidence e;std::string verdict="FAIL";bool ran=false;
    const std::string header="GRAPHICS_SCENE_RUN probe="+std::string(name)+" runId="+id+" processPid="+std::to_string(getpid())+
        " startUnixNs="+std::to_string(unixNs)+" startSteadyNs="+std::to_string(ns);
    try {
        if((mkdir(root.c_str(),0700)!=0&&errno!=EEXIST)||mkdir(directory.c_str(),0700)!=0)throw std::runtime_error("unique probe directory creation failed");
        e.stream=std::fopen(path.c_str(),"wb");if(!e.stream)throw std::runtime_error("probe report open failed");e.Line(header);
        std::string rejected=graphicsSemanticsCannotStart();
        // MGL没有公开COLD状态报告；已映射映像可能由旧capability/其它诊断初始化，
        // 不能仅因context已退休就称真正冷。这里只NOLOAD，绝不在拒绝检查里加载它。
        if(rejected.empty()&&std::string(profile)=="mobilegl") {
            void* mapped=dlopen("libmobilegl.so",RTLD_NOW|RTLD_LOCAL|RTLD_NOLOAD);
            if(mapped){dlclose(mapped);rejected="NOT_RUN: MobileGL image already mapped; restart application";}
        }
        if(!rejected.empty()) {e.Line(rejected);verdict="NOT_RUN";}
        else {
            if(!graphicsSemanticsTryClaimProcess())throw std::runtime_error("diagnostic process concurrently claimed");ran=true;
            if(std::string(profile)=="mobileglues") {
                test_evidence::SaveReportChecked(directory+"/config.json","{\"customGLVersion\":46,\"fsr1Setting\":0,\"hideMGEnvLevel\":0}");
                if(setenv("MG_DIR_PATH",directory.c_str(),1)!=0)throw std::runtime_error("MG diagnostic config environment failed");
            }
            // 与真实生产准入同一冷态发布；必须早于Freeze的dlopen/首次EGL。
            // 前面的NOLOAD检查和原子认领保护本专用进程，不接管运行中的游戏。
            if(std::string(profile)=="mobilegl") {
                std::string bootstrapError;
                if(!graphics::PublishMobileGlDirectVulkanBeforeLoad(bootstrapError))
                    throw std::runtime_error("production MGL cold publication: "+bootstrapError);
                e.Line("BACKEND_PUBLICATION value=DirectVulkan source=production-cold-publisher");
            }
            std::string error;if(!graphics::FreezeGraphicsRuntime(profile,"OPENGL",error))throw std::runtime_error("production freeze: "+error);
            const auto* runtime=graphics::BoundGraphicsRuntime();
            if(!runtime||!runtime->is(profile)||!runtime->contextOperations||!runtime->desktopGl())throw std::runtime_error("production desktop runtime missing");
            Dl_info entry{},provider{};if(!dladdr(reinterpret_cast<void*>(&Run),&entry)||!entry.dli_fname)throw std::runtime_error("entry image missing");
            std::string requested=entry.dli_fname;requested=requested.substr(0,requested.rfind('/')+1)+library;
            void* anchor=runtime->glProc("glGetString");
            if(!anchor||!dladdr(anchor,&provider)||!provider.dli_fname||
               test_evidence::CanonicalImagePath(provider.dli_fname)!=test_evidence::CanonicalImagePath(requested))throw std::runtime_error("provider facade/path rejected");
            const auto bytes=test_evidence::CopyImageChecked(provider.dli_fname,directory+"/loaded-"+library);
            e.Line("IMAGE_COPY library="+std::string(library)+" bytes="+std::to_string(bytes)+" path="+directory+"/loaded-"+library);
            e.Line("PROVIDER image="+std::string(provider.dli_fname)+" implementation="+Quote(runtime->implementationIdentity)+
                " factory="+runtime->contextOperations->implementation);
            for(const char* symbol:{"eglCreateContext","eglMakeCurrent","eglQueryContext","eglGetCurrentContext"}) {
                // 公共EGL解析与生产factory表使用相同路径，不能用系统依赖补齐。
                void* address=amclGraphicsEglProcV1(symbol);Dl_info image{};
                const bool owned=address&&dladdr(address,&image)&&image.dli_fbase==provider.dli_fbase;
                e.Line("EGL_FUNCTION name="+std::string(symbol)+" owned="+std::to_string(owned)+
                    " image="+(image.dli_fname?std::string(image.dli_fname):"UNKNOWN"));
                if(!owned)throw std::runtime_error("foreign EGL function in production factory");
            }
            Resolver resolver{*runtime,e,provider.dli_fbase};
            const bool pass=probe(*runtime,resolver,e)&&resolver.rejected==0;
            e.Line("RESOLUTION resolved="+std::to_string(resolver.resolved)+" rejected="+std::to_string(resolver.rejected));
            verdict=pass?"PASS_SCOPE":"FAIL";
        }
        e.Line("GRAPHICS_SCENE_END probe="+std::string(name)+" runId="+id+" processPid="+std::to_string(getpid())+
            " restartRequired="+std::to_string(graphicsSemanticsRestartRequired())+" verdict="+verdict);
        FILE* stream=e.stream;e.stream=nullptr;if(std::fclose(stream)!=0)throw std::runtime_error("report close failed");
        // 成功close后只重开读取原文件；不能trunc重写掩掉第一份文件的截断。
        // 外部RETURN晚于close与纯读回，
        // 文件自身的END不能证明函数正常返回；副本也不宣称所有映射内存的hash。
        const std::string readback=test_evidence::ReadReportChecked(path,e.text);
        if(readback!=e.text)throw std::runtime_error("report readback differs");
        e.text+="GRAPHICS_SCENE_RETURN probe="+std::string(name)+" runId="+id+" processPid="+std::to_string(getpid())+
            " reportBytes="+std::to_string(readback.size())+" returned=1 verdict="+verdict+"\n";
    } catch(const std::exception& error) {
        if(e.stream){std::fclose(e.stream);e.stream=nullptr;}
        e.text=header+"\nFAIL reason="+error.what()+"\nGRAPHICS_SCENE_RETURN probe="+std::string(name)+" runId="+id+
            " processPid="+std::to_string(getpid())+" returned=0 restartRequired="+std::to_string(ran)+" verdict=FAIL\n";
    }
    std::istringstream lines(e.text);std::string line;while(std::getline(lines,line))AMCL_LOG_I("MG_DEPTH_RANGE_PROBE","%{public}s",line.c_str());
    return e.text;
}
}

// Linux host CTS的只读解析观察；保存原函数地址所属ELF，不替换返回地址、case判定或GL实现。
// 官方CTS、所属fork原platform、本header/调用点delta分别入账；既有920实验不冒称新fork制品。
// 输入由受控runner显式提供prefix/runId/expected provider；输出独占PID JSONL和/proc/self/maps。
// 观察存在不能证明函数完整语义；外门另核真实QPA、全部core义务、完成/IO和独立制品身份。
#pragma once
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <limits.h>
#include <mutex>
#include <unistd.h>

namespace amcl_cts_observation {
struct Log {
    FILE* file=nullptr;std::mutex mutex;char expected[PATH_MAX]{};const char* run=nullptr;
    unsigned total=0,missing=0,foreign=0,writeErrors=0;bool mapsWritten=false;
    Log() {
        // 构造时打开新文件并绑定实际canonical provider。禁用观察保持原CTS；资格门拒缺报告。
        const char* prefix=std::getenv("AMCL_CTS_PROVIDER_LOG_PREFIX");
        if(!prefix)return; // 非本轮显式实验保持原平台行为；外门会拒绝缺观察证据。
        const char* selected=std::getenv("AMCL_CTS_EXPECTED_PROVIDER");run=std::getenv("AMCL_RUN_ID");
        if(!selected||!run||!realpath(selected,expected))std::_Exit(91);
        char path[PATH_MAX];int size=std::snprintf(path,sizeof path,"%s.%ld.jsonl",prefix,(long)getpid());
        if(size<0||size>=int(sizeof path))std::_Exit(92);
        file=std::fopen(path,"wx");if(!file)std::_Exit(93);
        if(std::fprintf(file,"{\"kind\":\"begin\",\"pid\":%ld,\"runId\":\"%s\",\"provider\":\"%s\"}\n",(long)getpid(),run,expected)<0||std::fflush(file)!=0)std::_Exit(94);
    }
    ~Log() {
        // 终止记录保所有解析/缺失/foreign/IO计数；写/flush/close失败不能产生正常完成假象。
        if(!file)return;
        if(std::fprintf(file,"{\"kind\":\"end\",\"pid\":%ld,\"runId\":\"%s\",\"completed\":true,\"resolutions\":%u,\"missing\":%u,\"foreign\":%u,\"writeErrors\":%u}\n",(long)getpid(),run,total,missing,foreign,writeErrors)<0||std::fflush(file)!=0||std::fclose(file)!=0)std::_Exit(95);
    }
    void observe(const char* source,const char* name,const void* address) {
        // 原平台调用线程只读dladdr/realpath；mutex串行写证据，既不调用被观察函数也不改变地址。
        if(!file)return;std::lock_guard<std::mutex> guard(mutex);Dl_info owner{};char actual[PATH_MAX]{};
        const bool owned=address&&dladdr(address,&owner)&&owner.dli_fname&&realpath(owner.dli_fname,actual);
        const char* verdict=!address?"MISSING":(!owned||std::strcmp(actual,expected)!=0?"FOREIGN":"OWN");
        ++total;if(!address)++missing;else if(!owned||std::strcmp(actual,expected)!=0)++foreign;
        if(std::fprintf(file,"{\"kind\":\"resolve\",\"pid\":%ld,\"runId\":\"%s\",\"source\":\"%s\",\"symbol\":\"%s\",\"address\":\"%p\",\"imageBase\":\"%p\",\"library\":\"%s\",\"verdict\":\"%s\"}\n",(long)getpid(),run,source,name,address,owner.dli_fbase,actual,verdict)<0||std::fflush(file)!=0)++writeErrors;
        // 初始化glGetString时context已current；独立只读收取实际mapped provider/driver。
        if(!mapsWritten&&std::strcmp(name,"glGetString")==0) {
            const char* prefix=std::getenv("AMCL_CTS_PROVIDER_LOG_PREFIX");char path[PATH_MAX];
            int size=std::snprintf(path,sizeof path,"%s.%ld.maps",prefix,(long)getpid());
            FILE* input=std::fopen("/proc/self/maps","rb");FILE* output=(size>=0&&size<int(sizeof path))?std::fopen(path,"wx"):nullptr;
            if(!input||!output)++writeErrors;
            else {char bytes[4096];size_t n;while((n=std::fread(bytes,1,sizeof bytes,input))>0)if(std::fwrite(bytes,1,n,output)!=n){++writeErrors;break;}if(std::ferror(input))++writeErrors;}
            if(input&&std::fclose(input)!=0)++writeErrors;if(output&&std::fclose(output)!=0)++writeErrors;mapsWritten=true;
        }
    }
};
inline Log& log(){static Log value;return value;}
inline void observe(const char* source,const char* name,const void* address){log().observe(source,name,address);}
} // namespace amcl_cts_observation

// B8 宿主JNI边界：只连接stock JVM与真实主runtime/factory/已审MG GL host。
// context固定在创建它的Java线程。函数地址来自唯一冻结owner，禁止系统GL补齐。
#include <jni.h>
#include "graphics_runtime_binding.h"
#include <dlfcn.h>
#include <unistd.h>
#include <cstring>
#include <cstdio>
#include <map>
#include <fstream>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
amcl::graphics::EglContextState state;
const amcl::graphics::GraphicsRuntimeBinding* runtime=nullptr;
int ownerTid=0;
uint64_t calls=0,owned=0,missing=0;
std::map<std::string,uintptr_t> selected;
std::set<std::string> unavailable;
void require(bool value,const std::string& stage);
std::string procMaps(){
    // 保存实际装入的JVM/LWJGL/JNI/runtime/GL host路径，后续宿主按这些实取文件绑定SHA。
    // maps是只读观察，不dlopen另一库，也不以请求文件名推断已经装入该文件。
    std::ifstream input("/proc/self/maps");require(input.good(),"read process maps");
    std::ostringstream out;std::string line;
    while(std::getline(input,line))if(line.find("libjvm.so")!=std::string::npos||line.find("liblwjgl")!=std::string::npos||
        line.find("libfrontend_owner")!=std::string::npos||line.find("libamcl_graphics_runtime")!=std::string::npos||
        line.find("libamcl_gl_host")!=std::string::npos)out<<"LOADED_DSO "<<line<<'\n';
    return out.str();
}

void require(bool value,const std::string& stage){if(!value)throw std::runtime_error(stage);}
void throwJava(JNIEnv* env,const std::exception& error){env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),error.what());}
// Java只拿实际GL入口。所有可用地址必须dladdr到MG provider映像；缺项仍返回0给
// LWJGL自己的capabilities判定，不能把driver地址或占位非零指针伪装成已实现函数。
void* address(const char* name){
    require(runtime&&ownerTid==gettid()&&runtime->egl.eglGetCurrentContext()==state.context,"same JNI owner thread/current context");
    ++calls;void* value=runtime->glProc(name);
    if(!value){++missing;unavailable.insert(name);
        std::printf("PROVIDER_CALL seq=%llu tid=%d current=%p name=%s address=0 image=MISSING\n",
            static_cast<unsigned long long>(calls),ownerTid,state.context,name);std::fflush(stdout);return nullptr;}
    Dl_info info{};
    require(dladdr(value,&info)&&info.dli_fbase==runtime->providerImage,std::string("foreign GL function:")+name);
    ++owned;
    // 每个实际FunctionProvider解析都有顺序、线程、current、地址及真实映像，便于
    // 独立review核对全部调用，而不仅凭一个累计数宣称没有系统GL补齐。
    std::printf("PROVIDER_CALL seq=%llu tid=%d current=%p name=%s address=%p image=%s\n",
        static_cast<unsigned long long>(calls),ownerTid,state.context,name,value,info.dli_fname);
    if(selected.size()<32||std::strcmp(name,"glGetString")==0||std::strcmp(name,"glGetIntegerv")==0)
        selected[name]=reinterpret_cast<uintptr_t>(value);
    std::fflush(stdout);
    return value;
}
std::string inspect(){
    require(runtime&&ownerTid==gettid()&&runtime->egl.eglGetCurrentContext()==state.context,"owner inspect current");
    auto getInt=reinterpret_cast<void(*)(unsigned,int*)>(address("glGetIntegerv"));
    auto getString=reinterpret_cast<const unsigned char*(*)(unsigned)>(address("glGetString"));
    auto getError=reinterpret_cast<unsigned(*)()>(address("glGetError"));
    auto query=reinterpret_cast<decltype(&::eglQueryContext)>(runtime->eglProc("eglQueryContext"));
    require(getInt&&getString&&getError&&query,"owner identity query functions");
    int major=-1,minor=-1,client=0,eglMajor=-1;
    getInt(0x821b,&major);getInt(0x821c,&minor);
    require(query(state.display,state.context,EGL_CONTEXT_CLIENT_TYPE,&client)&&
            query(state.display,state.context,EGL_CONTEXT_CLIENT_VERSION,&eglMajor),"real EGL identity");
    require(getError()==0&&runtime->egl.eglGetError()==EGL_SUCCESS,"owner queries no new error");
    std::ostringstream out;
    out<<"OWNER pid="<<getpid()<<" tid="<<ownerTid<<" api="<<runtime->profile->contextApi
       <<" operation="<<runtime->contextOperations->implementation<<" current="<<state.context
       <<" eglType="<<std::hex<<client<<std::dec<<" eglMajor="<<eglMajor<<" integer="<<major<<'.'<<minor
       <<" ownerGrant="<<state.actualContextMajor<<'.'<<state.actualContextMinor<<" string="<<getString(0x1f02)
       <<" resolverCalls="<<calls<<" owned="<<owned<<" missing="<<missing<<" foreign=0\n";
    out<<"MISSING_FUNCTIONS";for(const auto& name:unavailable)out<<' '<<name;out<<'\n';
    out<<"FUNCTION_OWNERS";for(const auto& [name,value]:selected)out<<' '<<name<<'='<<std::hex<<value;out<<std::dec;
    out<<'\n'<<procMaps();return out.str();
}
}

extern "C" JNIEXPORT jstring JNICALL Java_FrontendLwjglConsumer_createOwner(JNIEnv* env,jclass,jint major,jint minor){try{
    require(!runtime&&state.context==EGL_NO_CONTEXT,"one isolated owner per JVM process");
    std::string error;
    require(amcl::graphics::FreezeGraphicsRuntime("mobileglues","OPENGL",error),"production freeze:"+error);
    runtime=amcl::graphics::BoundGraphicsRuntime();require(runtime&&runtime->egl.ready&&runtime->providerImage,"real MG provider");
    ownerTid=static_cast<int>(gettid());state.width=64;state.height=64;state.auxiliary=1;
    const amcl::desktop::ContextRequest request{major,minor,(major>3||(major==3&&minor>=2))?0x32001:0,false};
    // 使用现有真实auxiliary pbuffer owner；配置仍须满足WINDOW|PBUFFER且parking1x1真实核验。
    require(runtime->contextOperations->create(*runtime,state,request,ownerTid,error),"production context:"+error);
    require(amcl::graphics::ProbeGraphicsFeatures(*runtime,state),"production feature probe restored/retired its resources");
    Dl_info image{};require(dladdr(runtime->glProc("glGetString"),&image)&&image.dli_fbase==runtime->providerImage,"GL host identity");
    std::ostringstream out;out<<"PROVIDER image="<<image.dli_fname<<" base="<<image.dli_fbase<<" identity="<<runtime->implementationIdentity<<'\n'<<inspect();
    return env->NewStringUTF(out.str().c_str());
}catch(const std::exception& error){throwJava(env,error);return nullptr;}}

extern "C" JNIEXPORT jlong JNICALL Java_FrontendLwjglConsumer_resolve(JNIEnv* env,jclass,jlong nameAddress){try{
    const auto* name=reinterpret_cast<const char*>(static_cast<uintptr_t>(nameAddress));
    require(name&&strnlen(name,256)<256,"bounded LWJGL function name");
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(address(name)));
}catch(const std::exception& error){throwJava(env,error);return 0;}}

extern "C" JNIEXPORT jstring JNICALL Java_FrontendLwjglConsumer_inspectOwner(JNIEnv* env,jclass){try{
    return env->NewStringUTF(inspect().c_str());
}catch(const std::exception& error){throwJava(env,error);return nullptr;}}

extern "C" JNIEXPORT jstring JNICALL Java_FrontendLwjglConsumer_extensionEvidence(JNIEnv* env,jclass){try{
    auto enable=reinterpret_cast<void(*)(unsigned)>(address("glEnable"));
    auto getInt=reinterpret_cast<void(*)(unsigned,int*)>(address("glGetIntegerv"));
    auto getString=reinterpret_cast<const unsigned char*(*)(unsigned)>(address("glGetString"));
    auto indexed=reinterpret_cast<const unsigned char*(*)(unsigned,unsigned)>(address("glGetStringi"));
    auto getError=reinterpret_cast<unsigned(*)()>(address("glGetError"));
    require(enable&&getInt&&getString&&indexed&&getError,"real extension/error query functions");
    // 冷cache初始化时保留生产已确认的非法cap错误。不是手写pending queue；真实
    // glEnable入口产生INVALID_ENUM，扩展查询随后必须原样保留至公开GetError。
    enable(0xdeadbeef);int count=-1;getInt(0x821d,&count);require(count>=0&&count<10000,"bounded actual extension count");
    const auto* raw=getString(0x1f03);require(raw,"raw MG extension compatibility string");
    std::istringstream input(reinterpret_cast<const char*>(raw));std::string name;std::vector<std::string> parts;
    while(input>>name)parts.push_back(name);
    require(parts.size()==static_cast<size_t>(count),"raw/indexed/count extension agreement");
    size_t synthetic=0;
    for(int i=0;i<count;++i){const auto* value=indexed(0x1f03,i);require(value&&parts[i]==reinterpret_cast<const char*>(value),"indexed extension exact ordering");
        std::printf("ACTUAL_EXTENSION index=%d name=%s\n",i,value);
        if(parts[i].rfind("OpenGL",0)==0)++synthetic;}
    const unsigned error=getError();require(error==0x500&&getError()==0,"cold extension cache preserves actual prior INVALID_ENUM");
    std::ostringstream out;out<<"EXTENSION_EVIDENCE count="<<count<<" rawIndexedEqual=1 coldOldError="<<error<<" syntheticCoreTokens="<<synthetic;
    return env->NewStringUTF(out.str().c_str());
}catch(const std::exception& error){throwJava(env,error);return nullptr;}}

extern "C" JNIEXPORT jstring JNICALL Java_FrontendLwjglConsumer_retireOwner(JNIEnv* env,jclass){try{
    require(runtime&&ownerTid==gettid(),"retire JNI thread");std::string error;
    require(runtime->contextOperations->destroy(*runtime,state,ownerTid,error),"production retirement:"+error);
    require(!state.context&&!state.surface&&!state.parkingSurface&&!state.contextPermit&&
            runtime->features->contexts.empty()&&runtime->features->contextPermits.empty(),"complete native ledger retirement");
    std::fflush(stdout);
    return env->NewStringUTF("NATIVE_RETIRED context=0 surface=0 parking=0 permit=0 contexts=0 permits=0");
}catch(const std::exception& error){throwJava(env,error);return nullptr;}}

#include "mg_context_identity_scene.h"
#include <array>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <unistd.h>

namespace amcl::graphics_semantics {
namespace {
using E=unsigned int;using I=int;
using State=amcl::graphics::EglContextState;
using Runtime=amcl::graphics::GraphicsRuntimeBinding;
constexpr I kCore=0x00032001;
constexpr std::array<const char*,4> kTurns{"context-identity-0","context-identity-1","context-identity-2","context-identity-3"};
// 证据字符串原样保存字节，仅JSON转义；不解析renderer/GLSL来决定能力资格。
std::string Quote(const std::string& value){
    std::ostringstream out;out<<'"';
    for(unsigned char ch:value){
        if(ch=='"'||ch=='\\')out<<'\\'<<ch;else if(ch=='\n')out<<"\\n";
        else if(ch=='\r')out<<"\\r";else if(ch=='\t')out<<"\\t";else if(ch<32)out<<'?';else out<<ch;
    }return out.str()+'"';
}
std::string Pointer(const void* value){std::ostringstream out;out<<value;return out.str();}
void Check(DepthRangeResult& result,const char* kind,const char* name,bool pass,const std::string& fields={}){
    ++result.checks;if(!pass)++result.failures;if(std::string(kind)=="context-identity")++result.queryChecks;
    result.evidence+="{\"kind\":"+Quote(kind)+",\"case\":"+Quote(name)+",\"pass\":"+(pass?"true":"false")+fields+"}\n";
}
// GL字符串只读取有限4096字节；null/未终止不能作为可解析或可比较身份。
bool Text(const unsigned char* value,std::string& output){
    if(!value)return false;
    const auto* chars=reinterpret_cast<const char*>(value);
    const auto size=strnlen(chars,4096);if(size==4096)return false;output.assign(chars,size);return !output.empty();
}
struct Api{
    const unsigned char*(*GetString)(E)=nullptr;void(*GetIntegerv)(E,I*)=nullptr;E(*GetError)()=nullptr;
    decltype(&::eglQueryContext) QueryContext=nullptr;
};
// 只比较实际dladdr映像base。providerProc的EGL入口也必须与GL同一前端DSO，
// 不能把它的GLES依赖或facade请求文件当成真正provider。
bool Owned(void* address,void* image,std::string& file){
    Dl_info info{};if(!address||!dladdr(address,&info)||!info.dli_fbase||!info.dli_fname)return false;
    file=info.dli_fname;return info.dli_fbase==image;
}
// 生产owner会保存State地址，禁止在destroy失败时释放heap留下悬空账本。
// 非attempted状态没有生产资源；异常析构只用原destroy，不直接操作EGL句柄。
struct Owners{
    const Runtime& runtime;I tid;std::array<std::unique_ptr<State>,2> state;
    std::array<bool,2> attempted{};bool retired=false,retirementSafe=false;
    Owners(const Runtime& value,I owner):runtime(value),tid(owner){
        for(auto& s:state){s=std::make_unique<State>();s->auxiliary=1;s->width=16;s->height=16;}
    }
    bool Retire(DepthRangeResult* result){
        if(retired)return retirementSafe;
        bool all=true;
        for(I i=1;i>=0;--i){
            if(!state[i])continue;
            bool ok=!attempted[i];std::string error;
            if(attempted[i]){
                try{ok=runtime.contextOperations->destroy(runtime,*state[i],tid,error);}
                catch(const std::exception& e){ok=false;error=e.what();}
                catch(...){ok=false;error="unknown production owner retirement exception";}
            }
            const auto& s=*state[i];const bool empty=!s.context&&!s.surface&&!s.parkingSurface&&!s.contextPermit;
            ok=ok&&empty;all=all&&ok;
            const auto permit=s.contextPermit;const auto context=s.context;const auto surface=s.surface;const auto parking=s.parkingSurface;
            // 先落实生命周期再创建任何证据字符串：记录分配抛异常也不能让failed
            // owner被unique_ptr销毁。尚未处理的owner仍由未完成的RAII退休路径接手。
            if(ok)state[i].reset();else(void)state[i].release();
            if(result)Check(*result,"cleanup",i==0?"identity-retire-low":"identity-retire-high",ok,
                ",\"attempted\":"+std::string(attempted[i]?"true":"false")+",\"error\":"+Quote(error)+
                ",\"permit\":"+std::to_string(permit)+",\"context\":"+Quote(Pointer(context))+
                ",\"surface\":"+Quote(Pointer(surface))+",\"parking\":"+Quote(Pointer(parking)));
        }
        retired=true;retirementSafe=all;return all;
    }
    ~Owners(){if(!retired)(void)Retire(nullptr);}
};
}

DepthRangeResult RunMgContextIdentity(const Runtime& runtime,bool highFirst,ResolveProc resolve,void* user){
    DepthRangeResult result;
    const bool ready=runtime.is("mobileglues")&&runtime.processId==getpid()&&runtime.egl.ready&&
        runtime.contextOperations&&runtime.contextOperations->create&&runtime.contextOperations->destroy&&resolve;
    Check(result,"setup","identity-runtime-ready",ready);
    if(!ready)return result;
    const I tid=static_cast<I>(gettid());Api api;
    // GL清单供manifest提取；caller按该次provider固定resolver记录真实地址。
#define ID_LOAD(member) do{api.member=reinterpret_cast<decltype(api.member)>(resolve(user,"gl" #member));}while(false)
    ID_LOAD(GetString);ID_LOAD(GetIntegerv);ID_LOAD(GetError);
#undef ID_LOAD
    Dl_info primary{};bool owned=api.GetString&&api.GetIntegerv&&api.GetError&&
        dladdr(reinterpret_cast<void*>(api.GetString),&primary)&&primary.dli_fbase&&primary.dli_fname;
    std::string image,queryImage;
    if(owned)owned=Owned(reinterpret_cast<void*>(api.GetIntegerv),primary.dli_fbase,image)&&
        Owned(reinterpret_cast<void*>(api.GetError),primary.dli_fbase,image);
    void* query=runtime.providerProc("eglQueryContext");api.QueryContext=reinterpret_cast<decltype(api.QueryContext)>(query);
    if(owned)owned=Owned(query,primary.dli_fbase,queryImage);
    // 运行时真实EGL表的bootstrap/current入口不能被另一namespace库补齐。
    std::string table;
    const auto entry=[&](const char* name,void* address){
        std::string file;const bool same=primary.dli_fbase&&Owned(address,primary.dli_fbase,file);
        if(!table.empty())table+=',';
        table+="{\"name\":"+Quote(name)+",\"address\":"+Quote(Pointer(address))+",\"owned\":"+(same?"true":"false")+",\"image\":"+Quote(file)+"}";
        return same;
    };
    owned=entry("eglBindAPI",reinterpret_cast<void*>(runtime.egl.eglBindAPI))&&owned;
    owned=entry("eglMakeCurrent",reinterpret_cast<void*>(runtime.egl.eglMakeCurrent))&&owned;
    owned=entry("eglGetCurrentContext",reinterpret_cast<void*>(runtime.egl.eglGetCurrentContext))&&owned;
    owned=entry("eglGetCurrentDisplay",reinterpret_cast<void*>(runtime.egl.eglGetCurrentDisplay))&&owned;
    owned=entry("eglGetError",reinterpret_cast<void*>(runtime.egl.eglGetError))&&owned;
    owned=entry("eglGetDisplay",reinterpret_cast<void*>(runtime.egl.eglGetDisplay))&&owned;
    owned=entry("eglInitialize",reinterpret_cast<void*>(runtime.egl.eglInitialize))&&owned;
    owned=entry("eglChooseConfig",reinterpret_cast<void*>(runtime.egl.eglChooseConfig))&&owned;
    owned=entry("eglCreateContext",reinterpret_cast<void*>(runtime.egl.eglCreateContext))&&owned;
    owned=entry("eglCreatePbufferSurface",reinterpret_cast<void*>(runtime.egl.eglCreatePbufferSurface))&&owned;
    owned=entry("eglQuerySurface",reinterpret_cast<void*>(runtime.egl.eglQuerySurface))&&owned;
    owned=entry("eglDestroyContext",reinterpret_cast<void*>(runtime.egl.eglDestroyContext))&&owned;
    owned=entry("eglDestroySurface",reinterpret_cast<void*>(runtime.egl.eglDestroySurface))&&owned;
    owned=entry("eglGetCurrentSurface",reinterpret_cast<void*>(runtime.egl.eglGetCurrentSurface))&&owned;
    owned=entry("eglQueryAPI",reinterpret_cast<void*>(runtime.egl.eglQueryAPI))&&owned;
    owned=entry("eglTerminate",reinterpret_cast<void*>(runtime.egl.eglTerminate))&&owned;
    Check(result,"setup","identity-provider-owned",owned,",\"image\":"+Quote(primary.dli_fname?primary.dli_fname:"UNKNOWN")+
        ",\"imageBase\":"+Quote(Pointer(primary.dli_fbase))+",\"queryAddress\":"+Quote(Pointer(query))+
        ",\"queryImage\":"+Quote(queryImage)+",\"eglEntries\":["+table+"]");
    if(!owned)return result;
    result.evidence+="{\"kind\":\"context-identity-config\",\"sceneVersion\":1,\"highFirst\":"+std::string(highFirst?"true":"false")+
        ",\"ownerTid\":"+std::to_string(tid)+",\"processPid\":"+std::to_string(getpid())+
        ",\"operation\":"+Quote(runtime.contextOperations->implementation?runtime.contextOperations->implementation:"UNKNOWN")+
        ",\"runtimeDesktop\":"+(runtime.desktopGl()?"true":"false")+",\"ownerDesktop\":"+
        (runtime.contextOperations->desktopApi?"true":"false")+",\"scope\":\"frontend-identity-only\",\"coreQualified\":false}\n";
    Owners owners(runtime,tid);
    const auto finish=[&](bool full){
        const bool safe=owners.Retire(&result);result.completed=full&&safe;
        result.evidence+="{\"kind\":\"mg-context-identity-scene-end\",\"completed\":"+std::string(result.completed?"true":"false")+
            ",\"checks\":"+std::to_string(result.checks)+",\"queryChecks\":"+std::to_string(result.queryChecks)+
            ",\"pixelChecks\":0,\"failures\":"+std::to_string(result.failures)+"}\n";return result;
    };
    try{
        const std::array<I,2> order=highFirst?std::array<I,2>{1,0}:std::array<I,2>{0,1};
        const std::array<amcl::desktop::ContextRequest,2> request{{{3,2,kCore,true},{4,0,kCore,false}}};
        for(I sequence=0;sequence<2;++sequence){
            const I index=order[sequence];auto& state=*owners.state[index];std::string error;
            owners.attempted[index]=true;
            const bool created=runtime.contextOperations->create(runtime,state,request[index],tid,error);
            Check(result,"setup",index==0?"identity-create-low":"identity-create-high",created,
                ",\"requested\":["+std::to_string(request[index].major)+','+std::to_string(request[index].minor)+
                "],\"error\":"+Quote(error)+",\"context\":"+Quote(Pointer(state.context))+",\"permit\":"+std::to_string(state.contextPermit));
            if(!created)return finish(false);
            if(sequence==0){
                // 第二owner需已有真实topology资格。调用原生产探针，不手写context或
                // 伪造features；探针本身失败/退休不安全仍按原门拒第二个context。
                const bool probe=amcl::graphics::ProbeGraphicsFeatures(runtime,state);
                const bool qualified=probe&&amcl::graphics::GraphicsAuxiliaryVerified(runtime,false);
                Check(result,"setup","identity-production-feature-probe",qualified,
                    ",\"probed\":"+std::string(probe?"true":"false")+",\"auxiliaryVerified\":"+(qualified?"true":"false"));
                if(!qualified)return finish(false);
            }
        }
        std::array<const unsigned char*,2> held{};std::array<std::string,2> heldText;
        for(I turn=0;turn<4;++turn){
            const I index=order[turn%2];auto& state=*owners.state[index];const auto& wanted=request[index];
            // 按冻结owner的实际公开API切换，旧GLES owner反例仍走它合法的生产路径，
            // 判据始终要求MG桌面frontend；不为制造对照强改它的API或函数表。
            const E apiType=runtime.contextOperations->desktopApi?EGL_OPENGL_API:EGL_OPENGL_ES_API;
            const bool switched=runtime.egl.eglBindAPI(apiType)&&runtime.egl.eglMakeCurrent(state.display,state.surface,state.surface,state.context);
            I eglApi=-1,eglMajor=-1;
            const bool queried=switched&&api.QueryContext(state.display,state.context,EGL_CONTEXT_CLIENT_TYPE,&eglApi)&&
                api.QueryContext(state.display,state.context,EGL_CONTEXT_CLIENT_VERSION,&eglMajor);
            if(!switched||!queried){
                Check(result,"context-identity",kTurns[turn],false,",\"turn\":"+std::to_string(turn)+
                    ",\"switched\":"+std::string(switched?"true":"false")+",\"queried\":"+(queried?"true":"false"));
                return finish(false);
            }
            const bool stringFirst=(turn%2)==0;const unsigned char* version=nullptr;
            if(stringFirst)version=api.GetString(0x1f02);
            I major=-1,minor=-1,profile=-1,flags=-1;
            api.GetIntegerv(0x821b,&major);api.GetIntegerv(0x821c,&minor);api.GetIntegerv(0x9126,&profile);api.GetIntegerv(0x821e,&flags);
            if(!version)version=api.GetString(0x1f02);
            std::string versionText,renderer,glsl;
            const bool strings=Text(version,versionText)&&Text(api.GetString(0x1f01),renderer)&&Text(api.GetString(0x8b8c),glsl);
            I stringMajor=-1,stringMinor=-1;
            const bool parsed=strings&&versionText.rfind("OpenGL ES",0)!=0&&std::sscanf(versionText.c_str(),"%d.%d",&stringMajor,&stringMinor)==2;
            if(!held[index]){held[index]=version;heldText[index]=versionText;}
            bool retainedStrings=true;
            std::string heldValues;
            // 两个context均未退休；旧指针内容在另一context current时也必须仍有效，
            // 不能只在切回时看全局缓存是否恰好恢复成原字串而漏掉中间的覆写。
            for(I slot=0;slot<2;++slot){
                if(!held[slot])continue;
                std::string actual;const bool valid=Text(held[slot],actual)&&actual==heldText[slot];
                retainedStrings=retainedStrings&&valid;
                if(!heldValues.empty())heldValues+=',';
                heldValues+="{\"slot\":"+Quote(slot==0?"low":"high")+",\"pointer\":"+Quote(Pointer(held[slot]))+
                    ",\"expected\":"+Quote(heldText[slot])+",\"actual\":"+Quote(actual)+"}";
            }
            const bool stable=held[index]==version&&heldText[index]==versionText&&retainedStrings;
            unsigned errors=0;E first=0;bool empty=false;
            for(unsigned n=0;n<32;++n){const E error=api.GetError();if(error==0){empty=true;break;}if(errors==0)first=error;++errors;}
            const E eglError=runtime.egl.eglGetError();
            const bool current=switched&&runtime.egl.eglGetCurrentContext()==state.context&&runtime.egl.eglGetCurrentDisplay()==state.display&&state.contextOwnerTid==tid;
            const bool minimum=major>wanted.major||(major==wanted.major&&minor>=wanted.minor);
            // EGL_CLIENT_VERSION对一般桌面EGL是creation属性；这里只核MG既有wrapper
            // 将其覆盖为授予major的明确合同，不把该比较推广到系统Native EGL。
            const bool pass=queried&&current&&parsed&&stable&&minimum&&eglApi==EGL_OPENGL_API&&eglMajor==major&&
                major==stringMajor&&minor==stringMinor&&state.actualContextMajor==major&&state.actualContextMinor==minor&&
                profile==1&&state.actualContextProfile==kCore&&state.actualContextFlags==flags&&(!wanted.forward||(flags&1))&&
                errors==0&&empty&&eglError==EGL_SUCCESS;
            Check(result,"context-identity",kTurns[turn],pass,",\"turn\":"+std::to_string(turn)+",\"slot\":"+Quote(index==0?"low":"high")+
                ",\"readOrder\":"+Quote(stringFirst?"string-first":"integer-first")+",\"requested\":["+std::to_string(wanted.major)+','+std::to_string(wanted.minor)+
                "],\"requestedProfile\":"+std::to_string(wanted.profile)+",\"requestedForward\":"+(wanted.forward?"true":"false")+
                ",\"context\":"+Quote(Pointer(state.context))+",\"eglApi\":"+std::to_string(eglApi)+",\"eglClientMajor\":"+std::to_string(eglMajor)+
                ",\"integer\":["+std::to_string(major)+','+std::to_string(minor)+"],\"stringInteger\":["+std::to_string(stringMajor)+','+std::to_string(stringMinor)+
                "],\"ownerInteger\":["+std::to_string(state.actualContextMajor)+','+std::to_string(state.actualContextMinor)+
                "],\"profile\":"+std::to_string(profile)+",\"flags\":"+std::to_string(flags)+",\"ownerProfile\":"+std::to_string(state.actualContextProfile)+
                ",\"ownerFlags\":"+std::to_string(state.actualContextFlags)+",\"version\":"+Quote(versionText)+",\"renderer\":"+Quote(renderer)+",\"glsl\":"+Quote(glsl)+
                ",\"versionPointer\":"+Quote(Pointer(version))+",\"pointerStable\":"+(stable?"true":"false")+
                ",\"heldPointersStable\":"+(retainedStrings?"true":"false")+",\"heldVersions\":["+heldValues+"]"+
                ",\"current\":"+(current?"true":"false")+",\"ownerTid\":"+std::to_string(state.contextOwnerTid)+
                ",\"error\":"+std::to_string(first)+",\"errorCount\":"+std::to_string(errors)+",\"errorDrainComplete\":"+(empty?"true":"false")+
                ",\"eglError\":"+std::to_string(eglError));
        }
        return finish(true);
    }catch(const std::exception& e){Check(result,"setup","identity-exception",false,",\"error\":"+Quote(e.what()));return finish(false);}
    catch(...){Check(result,"setup","identity-exception",false,",\"error\":\"unknown exception\"");return finish(false);}
}

bool ValidateCompleteMgContextIdentityEvidence(const DepthRangeResult& result){
    if(!result.completed||result.checks!=11||result.queryChecks!=4||result.pixelChecks!=0)return false;
    const auto count=[&](const std::string& prefix){unsigned n=0;std::istringstream lines(result.evidence);std::string line;
        while(std::getline(lines,line))if(line.compare(0,prefix.size(),prefix)==0)++n;
        return n;};
    for(const char* name:kTurns)if(count("{\"kind\":\"context-identity\",\"case\":"+Quote(name)+',')!=1)return false;
    for(const auto& item:std::array<std::pair<const char*,const char*>,7>{{
        {"setup","identity-runtime-ready"},{"setup","identity-provider-owned"},{"setup","identity-create-low"},
        {"setup","identity-create-high"},{"setup","identity-production-feature-probe"},{"cleanup","identity-retire-high"},{"cleanup","identity-retire-low"}}})
        if(count("{\"kind\":"+Quote(item.first)+",\"case\":"+Quote(item.second)+',')!=1)return false;
    if(count("{\"kind\":\"context-identity-config\",")!=1||count("{\"kind\":\"mg-context-identity-scene-end\",")!=1)return false;
    unsigned linesCount=0,falseCount=0;std::istringstream lines(result.evidence);std::string line;
    while(std::getline(lines,line)){++linesCount;if(line.find(",\"pass\":false")!=std::string::npos)++falseCount;}
    const std::string end="{\"kind\":\"mg-context-identity-scene-end\",\"completed\":true,\"checks\":11,\"queryChecks\":4,\"pixelChecks\":0,\"failures\":"+
        std::to_string(result.failures)+"}\n";
    return linesCount==13&&falseCount==result.failures&&result.evidence.size()>=end.size()&&
        result.evidence.compare(result.evidence.size()-end.size(),end.size(),end)==0;
}
}

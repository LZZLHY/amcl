// B2 frontend 隔离实验：真实主桥冻结表 + 已审 MG 全对象 + 本次进程自己的 X11 窗口。
// 不覆盖 GLES 表、不注入 MGContext、不借游戏窗口；X11 资源在 EGL 全部退休后才释放。
#include "graphics_runtime_binding.h"
#include "depth_range_scene.h"
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <dlfcn.h>
#include <unistd.h>
#include <array>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <iomanip>
#include <stdexcept>
#include <string>
#include <vector>

// GLFW 查询函数由 runner 从被测源逐字提取。只有无关的窗口宿主属性边界是明确桩；
// context 字段继承实际 owner 的 C 资源记录，desktop predicate 查询真实冻结 runtime。
struct GLFWwindow : AmclGraphicsContextStateV1 { int clientAPI=0, visible=0, focused=0; };
constexpr int GLFW_NO_API=0, GLFW_OPENGL_API=0x30001, GLFW_OPENGL_ES_API=0x30002;
constexpr int GLFW_VISIBLE=0x20004, GLFW_FOCUSED=0x20001, GLFW_MAXIMIZED=0x20008, GLFW_ICONIFIED=0x20002;
constexpr int GLFW_RESIZABLE=0x20003, GLFW_DECORATED=0x20005, GLFW_FLOATING=0x20007;
constexpr int GLFW_CLIENT_API=0x22001, GLFW_CONTEXT_VERSION_MAJOR=0x22002, GLFW_CONTEXT_VERSION_MINOR=0x22003;
constexpr int GLFW_OPENGL_FORWARD_COMPAT=0x22006, GLFW_OPENGL_PROFILE=0x22008, GLFW_CONTEXT_CREATION_API=0x2200b;
int g_hintMajor=3, g_hintMinor=0;
int g_hintClientAPI=GLFW_OPENGL_API;
// runner从当前生产compat头逐字取得错误码；头缺失时测试也必须前置失败。
#include "glfw_error_constants.inc"
int clientErrors=0,clientErrorCode=0,creationTailCalls=0;
void ClientError(int code,const char*){++clientErrors;clientErrorCode=code;}
auto g_errorCallback=&ClientError;
namespace amcl::desktop {
// 使用当前 egl_dispatch.h 的逐字生产函数，不能用测试自己的 provider 判定替代。
#include "desktop_predicate.inc"
}
bool amclDesktopHostResolve(){return false;}
struct Facts { bool active=false,resizable=false,decorated=false; int status=0; };
Facts desktopFacts(){return {};}
#include "glfw_attribute.inc"
#include "glfw_client_admission.inc"

void Require(bool ok,const std::string& stage){if(!ok)throw std::runtime_error(stage);}
template<class T>T Gl(const char* name){auto*p=amclGraphicsGlProcV1(name);Require(p,std::string("GL symbol ")+name);return reinterpret_cast<T>(p);}

int main(int argc,char**argv){try{
    Require(argc==2||argc==3,"usage [low-first|high-first] [mobileglues|nativegl]");
    const char* provider=argc==3?argv[2]:"mobileglues";
    const bool mg=std::strcmp(provider,"mobileglues")==0;
    std::string error;
    Require(amcl::graphics::FreezeGraphicsRuntime(provider,"OPENGL",error),"freeze:"+error);
    const auto* r=amcl::graphics::BoundGraphicsRuntime();
    Require(r&&r->egl.ready&&r->contextOperations,"real bound operations");
    std::cout<<"RUN pid="<<getpid()<<" order="<<argv[1]<<" contextApi="<<r->profile->contextApi
             <<" operation="<<r->contextOperations->implementation<<" identity="<<r->implementationIdentity<<'\n';
    // 每个 GL/EGL 关键入口来自被冻结的 GL host 同一映像；底层 driver 是 MG 内部负责的 transport。
    Dl_info image{};Require(dladdr(amclGraphicsGlProcV1("glGetString"),&image)&&image.dli_fbase,"GL image");
    for(const char* name:{"eglCreateContext","eglMakeCurrent","eglQueryContext"}){
        Dl_info other{};Require(dladdr(amclGraphicsEglProcV1(name),&other)&&(!mg||other.dli_fbase==image.dli_fbase),"EGL/GL same image");
    }
    std::cout<<"PROVIDER image="<<image.dli_fname<<" base="<<image.dli_fbase<<'\n';
    auto getString=Gl<const unsigned char*(*)(unsigned)>("glGetString");
    auto getInt=Gl<void(*)(unsigned,int*)>("glGetIntegerv");
    auto getError=Gl<unsigned(*)()>("glGetError");
    auto getStringi=Gl<const unsigned char*(*)(unsigned,unsigned)>("glGetStringi");
    auto queryContext=reinterpret_cast<decltype(&::eglQueryContext)>(amclGraphicsEglProcV1("eglQueryContext"));
    Require(queryContext,"owned query context symbol");
    Display* xd=XOpenDisplay(nullptr);Require(xd,"real X11 display");
    EGLDisplay display=r->egl.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    Require(display&&r->egl.eglInitialize(display,nullptr,nullptr),"real EGL display");
    Require(r->egl.eglBindAPI(r->desktopGl()?EGL_OPENGL_API:EGL_OPENGL_ES_API),"select provider public API");
    const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT|EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,
        r->desktopGl()?EGL_OPENGL_BIT:EGL_OPENGL_ES3_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,
        EGL_DEPTH_SIZE,24,EGL_STENCIL_SIZE,8,EGL_NONE};
    EGLConfig cfg{};EGLint count=0,visual=0;
    Require(r->egl.eglChooseConfig(display,attrs,&cfg,1,&count)&&count==1,"real window-and-parking config");
    Require(r->egl.eglGetConfigAttrib(display,cfg,EGL_NATIVE_VISUAL_ID,&visual),"config X visual");
    XVisualInfo key{};key.visualid=visual;int matches=0;
    XVisualInfo* chosen=XGetVisualInfo(xd,VisualIDMask,&key,&matches);Require(chosen&&matches>=1,"real matching X visual");
    Colormap colormap=XCreateColormap(xd,RootWindow(xd,chosen->screen),chosen->visual,AllocNone);
    XSetWindowAttributes wa{};wa.colormap=colormap;wa.border_pixel=0;
    Window xw=XCreateWindow(xd,RootWindow(xd,chosen->screen),0,0,64,64,0,chosen->depth,InputOutput,chosen->visual,CWColormap|CWBorderPixel,&wa);
    XFree(chosen);Require(xw,"own X11 window");XSync(xd,False);
    std::cout<<"WINDOW xid="<<xw<<" visual="<<visual<<" geometry=64x64 mapped=0\n";
    std::array<GLFWwindow,2> states;
    std::array<amcl::desktop::ContextRequest,2> requests{{{3,2,0x32001,true},{4,0,0x32001,false}}};
    const bool highFirst=std::string(argv[1])=="high-first";
    std::array<int,2> order=highFirst?std::array<int,2>{1,0}:std::array<int,2>{0,1};
    int failures=0;
    auto check=[&](bool yes,const char* label){std::cout<<"CHECK "<<label<<" actual="<<yes<<'\n';if(!yes)++failures;};
    // 实际 CreateWindow 零分配 guard 的逐字正文；尾部只数“越过了前置门”，不造窗口。
    if(mg){
        g_hintClientAPI=GLFW_OPENGL_ES_API;
        check(!TestClientAdmission()&&clientErrors==1&&clientErrorCode==GLFW_API_UNAVAILABLE&&creationTailCalls==0,
              "explicit ES hard request rejects before objects");
        g_hintClientAPI=GLFW_OPENGL_API;
        check(TestClientAdmission()==1&&clientErrors==1&&creationTailCalls==1,"default OpenGL frontend admitted");
    }
    for(int sequence=0;sequence<2;++sequence){
        const int i=order[sequence];auto&s=states[i];s.width=64;s.height=64;
        // 首个真实窗口验证 owner 主路径，第二个用 production auxiliary pbuffer 路径。
        s.auxiliary=sequence!=0;s.nativeWindow=s.auxiliary?nullptr:reinterpret_cast<void*>(xw);
        s.clientAPI=r->desktopGl()?GLFW_OPENGL_API:GLFW_OPENGL_ES_API;
        Require(r->contextOperations->create(*r,s,requests[i],gettid(),error),"production create:"+error);
        Require(amcl::graphics::ProbeGraphicsFeatures(*r,s),"production functional probe restored resources");
        std::cout<<"CREATED requested="<<requests[i].major<<'.'<<requests[i].minor<<" auxiliary="<<s.auxiliary
                 <<" actual="<<s.actualContextMajor<<'.'<<s.actualContextMinor<<" profile="<<s.actualContextProfile
                 <<" flags="<<s.actualContextFlags<<" feature="<<amcl::graphics::GraphicsFeaturesJson(*r)<<'\n';
    }
    const char* held[2]{};
    for(int turn=0;turn<4;++turn){
        const int i=order[turn%2];auto&s=states[i];
        Require(r->egl.eglBindAPI(r->desktopGl()?EGL_OPENGL_API:EGL_OPENGL_ES_API),"context switch API");
        Require(r->egl.eglMakeCurrent(s.display,s.surface,s.surface,s.context),"legal current switch");
        EGLint api=-1,eglMajor=-1;
        Require(queryContext(s.display,s.context,EGL_CONTEXT_CLIENT_TYPE,&api)&&
                queryContext(s.display,s.context,EGL_CONTEXT_CLIENT_VERSION,&eglMajor),"legal EGL identity queries");
        int major=-1,minor=-1,profile=-1,flags=-1,stringMajor=-1,stringMinor=-1;
        // 交替整数/字符串先读，不能依赖一个读取顺序修饰另一个 context 的缓存。
        const char* version=nullptr;
        if(turn%2==0)version=reinterpret_cast<const char*>(getString(0x1f02));
        getInt(0x821b,&major);getInt(0x821c,&minor);getInt(0x9126,&profile);getInt(0x821e,&flags);
        if(!version)version=reinterpret_cast<const char*>(getString(0x1f02));
        Require(version&&std::sscanf(version,"%d.%d",&stringMajor,&stringMinor)==2,"parse public desktop version");
        if(!held[i])held[i]=version;
        // hints 变更是窗口创建之后的独立动作；正式 GLFW 属性函数必须返回已授予状态。
        g_hintMajor=9;g_hintMinor=7;
        std::cout<<"IDENTITY turn="<<turn<<" request="<<requests[i].major<<'.'<<requests[i].minor
                 <<" eglApi="<<std::hex<<api<<std::dec<<" eglMajor="<<eglMajor<<" integer="<<major<<'.'<<minor
                 <<" string="<<std::quoted(version)<<" flags="<<flags<<" profile="<<profile
                 <<" glfw="<<glfwGetWindowAttrib(&s,GLFW_CONTEXT_VERSION_MAJOR)<<'.'<<glfwGetWindowAttrib(&s,GLFW_CONTEXT_VERSION_MINOR)
                 <<" client="<<glfwGetWindowAttrib(&s,GLFW_CLIENT_API);
        // indexed GL_VERSION 是 MG 既有非标准兼容入口；原生参照只测试标准接口。
        if(mg)std::cout<<" token="<<getStringi(0x1f02,0)<<'.'<<getStringi(0x1f02,1);
        std::cout<<'\n';
        check(api==EGL_OPENGL_API,"frontend EGL type");
        // Mesa EGL 的 CLIENT_VERSION 实际保留创建参数3，而 GL实际可能4.5；这里
        // 记录两者不同职责，不把合法更高grant误判成运行时故障。MG wrapper 则明确
        // 用自身desktop grant覆盖该EGL属性，按它已有合同检查一致性。
        check((mg?eglMajor==major:eglMajor==requests[i].major)&&(mg?(major==requests[i].major&&minor==requests[i].minor):
          (major>requests[i].major||(major==requests[i].major&&minor>=requests[i].minor))),"requested/granted integer identity");
        check(major==stringMajor&&minor==stringMinor,"string/integer identity");
        check(glfwGetWindowAttrib(&s,GLFW_CONTEXT_VERSION_MAJOR)==major&&glfwGetWindowAttrib(&s,GLFW_CONTEXT_VERSION_MINOR)==minor,"immutable GLFW grant after hints");
        check(glfwGetWindowAttrib(&s,GLFW_CLIENT_API)==GLFW_OPENGL_API,"GLFW frontend API");
        check(profile==1&&(!requests[i].forward||(flags&1)),"core/forward attrs retained");
        check(version==held[i],"context version pointer stable");
        // 与真实 LWJGL GL.java 的 integer 优先输入同源；此处打印输入资格，不伪称 JVM 已运行。
        std::cout<<"LWJGL_INTEGER_INPUT OpenGL32="<<(major>3||(major==3&&minor>=2))
                 <<" OpenGL33="<<(major>3||(major==3&&minor>=3))<<" OpenGL40="<<(major>=4)<<'\n';
        Require(getError()==0&&r->egl.eglGetError()==EGL_SUCCESS,"queries leave no new GL/EGL error");
    }
    // 已创建窗口的真实 surface 暂退、停车与恢复；不得重新创建 context 或抢其他线程。
    auto& primary=states[order[0]];
    Require(r->egl.eglMakeCurrent(primary.display,primary.surface,primary.surface,primary.context),"primary current before parking");
    const auto parkedContext=primary.context;
    Require(!r->contextOperations->suspend(*r,primary,gettid()+1,error)&&primary.surface,"wrong owner refuses without retiring surface");
    Require(r->contextOperations->suspend(*r,primary,gettid(),error)&&!primary.surface&&primary.context==parkedContext&&
            r->egl.eglGetCurrentContext()==parkedContext,"production parking keeps context/current");
    Require(r->contextOperations->attach(*r,primary,reinterpret_cast<void*>(xw),64,64,gettid(),error)&&
            primary.surface&&primary.context==parkedContext&&primary.width==64&&primary.height==64,"production restore retains grant");
    std::cout<<"LIFECYCLE primary-parking-attach context-retained=1 wrong-thread-refused=1 geometry=64x64\n";
    // 新 owner 下复用已资格的同一共享 scene；其像素期望独立于查询与当前版本文本。
    const auto resolver=[](void*,const char*name)->void*{return amclGraphicsGlProcV1(name);};
    const auto depth=amcl::graphics_semantics::RunDepthRange(resolver,nullptr);
    std::cout<<depth.evidence;
    Require(amcl::graphics_semantics::ValidateCompleteDepthRangeEvidence(depth)&&depth.failures==0,"same owner B1 depth query/pixels");
    const auto initializer=amcl::graphics_semantics::RunUniformInitializer(resolver,nullptr);
    std::cout<<initializer.evidence;
    Require(amcl::graphics_semantics::ValidateCompleteUniformInitializerEvidence(initializer)&&initializer.failures==0,"same owner initializer query/pixels");
    std::cout<<"SHARED_SCENES depth="<<depth.checks<<'/'<<depth.queryChecks<<'/'<<depth.pixelChecks<<'/'<<depth.failures
             <<" initializer="<<initializer.checks<<'/'<<initializer.queryChecks<<'/'<<initializer.pixelChecks<<'/'<<initializer.failures<<'\n';
    if(mg){
        // 配置上限4.0与请求9.7不同：desktop wrapper 应拒绝，不静默借低版本 context。
        // 失败仍保留已分配 surface/parking 与 permit；只有 production destroy 成功才退休。
        GLFWwindow rejected;rejected.width=64;rejected.height=64;rejected.auxiliary=1;
        const amcl::desktop::ContextRequest impossible{9,7,0x32001,false};
        const bool accepted=r->contextOperations->create(*r,rejected,impossible,gettid(),error);
        std::cout<<"HIGH_REQUEST accepted="<<accepted<<" context="<<rejected.context<<" surface="<<rejected.surface
                 <<" parking="<<rejected.parkingSurface<<" permit="<<rejected.contextPermit<<" error="<<error<<'\n';
        check(!accepted&&rejected.context==EGL_NO_CONTEXT&&rejected.surface&&rejected.parkingSurface&&rejected.contextPermit,
              "unsupported request rejects while owner retains partial resources");
        Require(r->contextOperations->destroy(*r,rejected,gettid(),error)&&!rejected.contextPermit,"partial creation production retirement");
    }
    // 额外/共享资格只来自刚执行的真实生产 probe；不改变准入表以使测试越过门。
    Require(amcl::graphics::GraphicsAuxiliaryVerified(*r,true),"same-process sharing qualified by real probe");
    Require(r->egl.eglMakeCurrent(primary.display,primary.surface,primary.surface,primary.context),"primary before sharing");
    auto gen=Gl<void(*)(int,unsigned*)>("glGenBuffers");auto bind=Gl<void(*)(unsigned,unsigned)>("glBindBuffer");
    auto data=Gl<void(*)(unsigned,intptr_t,const void*,unsigned)>("glBufferData");
    auto map=Gl<void*(*)(unsigned,intptr_t,intptr_t,unsigned)>("glMapBufferRange");
    auto unmap=Gl<unsigned char(*)(unsigned)>("glUnmapBuffer");
    auto remove=Gl<void(*)(int,const unsigned*)>("glDeleteBuffers");
    unsigned buffer=0;const int payload=7341;gen(1,&buffer);bind(0x8892,buffer);data(0x8892,sizeof(payload),&payload,0x88e4);
    GLFWwindow shared;shared.width=64;shared.height=64;shared.auxiliary=1;shared.shareContext=primary.context;
    const amcl::desktop::ContextRequest sharedRequest{3,3,0x32001,false};
    Require(r->contextOperations->create(*r,shared,sharedRequest,gettid(),error),"production shared 3.3 create:"+error);
    int binding=-1;getInt(0x8894,&binding);Require(binding==0,"shared object does not share binding state");
    bind(0x8892,buffer);const auto* bytes=static_cast<const int*>(map(0x8892,0,sizeof(payload),1));
    Require(bytes&&*bytes==payload,"shared actual object readback");Require(unmap(0x8892),"shared map retirement");
    Require(r->contextOperations->destroy(*r,shared,gettid(),error),"shared context retirement");
    Require(r->egl.eglMakeCurrent(primary.display,primary.surface,primary.surface,primary.context),"primary restored after shared retirement");
    getInt(0x8894,&binding);Require(static_cast<unsigned>(binding)==buffer,"primary independent binding remains");
    remove(1,&buffer);Require(getError()==0,"shared object cleanup error");
    std::cout<<"SHARED request=3.3 actual="<<shared.actualContextMajor<<'.'<<shared.actualContextMinor
             <<" value="<<payload<<" distinct-binding=1 original-current-restored=1\n";
    GLFWwindow defaults;defaults.width=64;defaults.height=64;defaults.auxiliary=1;
    Require(r->contextOperations->create(*r,defaults,{},gettid(),error),"production default 3.0 create:"+error);
    int dm=-1,dn=-1;getInt(0x821b,&dm);getInt(0x821c,&dn);
    std::cout<<"DEFAULT owner="<<defaults.actualContextMajor<<'.'<<defaults.actualContextMinor<<" integer="<<dm<<'.'<<dn<<'\n';
    check(defaults.actualContextMajor==dm&&defaults.actualContextMinor==dn,"default owner is actual grant");
    Require(r->contextOperations->destroy(*r,defaults,gettid(),error),"default context retirement");
    for(auto&s:states){Require(r->contextOperations->destroy(*r,s,gettid(),error),"production destroy:"+error);}
    Require(r->features->contexts.empty()&&r->features->contextPermits.empty(),"owner ledger retired");
    XDestroyWindow(xd,xw);XFreeColormap(xd,colormap);XCloseDisplay(xd);
    std::cout<<"FINAL failures="<<failures<<" contexts=0 permits=0\n";
    return failures?2:0;
}catch(const std::exception&e){std::cerr<<"ENV_OR_OPERATION_FAILURE "<<e.what()<<'\n';return 1;}}

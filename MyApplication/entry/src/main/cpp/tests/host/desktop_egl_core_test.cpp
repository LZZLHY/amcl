#define EGL_NO_PLATFORM_SPECIFIC_TYPES
#include "../../platform/desktop_egl_core.h"
#include "../../platform/desktop_launch_policy.h"
#include <iostream>
#include <stdexcept>

#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while(false)
struct Window {
    void* nativeWindow = reinterpret_cast<void*>(10);
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLSurface parkingSurface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT, shareContext = EGL_NO_CONTEXT;
    EGLConfig config = nullptr;
    int contextOwnerTid = 0, width = 0, height = 0;
    int actualContextMajor = 0, actualContextMinor = 0, actualContextFlags = 0, actualContextProfile = 0;
    bool eglTeardownPending = false, eglSurfaceDetachPending = false, swapIntervalSet = false;
    int swapInterval = 0;
};
struct Fake {
    mutable EGLContext current = EGL_NO_CONTEXT;
    mutable EGLSurface draw = EGL_NO_SURFACE;
    mutable int creates = 0;
    mutable int destroys = 0, binds = 0;
    mutable int errorReads = 0;
    int surfaceWidth = 1280, surfaceHeight = 720;
    std::string fail;
    EGLDisplay eglGetDisplay(EGLNativeDisplayType) const { return reinterpret_cast<EGLDisplay>(1); }
    EGLBoolean eglInitialize(EGLDisplay, EGLint*, EGLint*) const { return fail != "initialize"; }
    EGLBoolean eglBindAPI(EGLenum api) const { CHECK(api==EGL_OPENGL_API); ++binds; return fail != "api"; }
    EGLBoolean eglChooseConfig(EGLDisplay,const EGLint* attrs,EGLConfig* cfg,EGLint,EGLint* count) const {
        CHECK(attrs[1]==(EGL_WINDOW_BIT|EGL_PBUFFER_BIT));
        CHECK(attrs[3]==EGL_OPENGL_BIT); *cfg=reinterpret_cast<EGLConfig>(2);*count=1;return fail!="config";
    }
    EGLSurface eglCreateWindowSurface(EGLDisplay,EGLConfig,EGLNativeWindowType,const EGLint*) const {
        return fail=="surface" ? EGL_NO_SURFACE : reinterpret_cast<EGLSurface>(3);
    }
    EGLContext eglCreateContext(EGLDisplay,EGLConfig,EGLContext,const EGLint* attrs) const {
        ++creates;CHECK(attrs[0]==EGL_CONTEXT_MAJOR_VERSION);return fail=="context" ? EGL_NO_CONTEXT : reinterpret_cast<EGLContext>(4);
    }
    EGLSurface eglCreatePbufferSurface(EGLDisplay,EGLConfig,const EGLint* attrs) const {
        CHECK(attrs[0]==EGL_WIDTH && attrs[1]==1 && attrs[2]==EGL_HEIGHT && attrs[3]==1);
        return fail=="parking" ? EGL_NO_SURFACE : reinterpret_cast<EGLSurface>(5);
    }
    EGLBoolean eglMakeCurrent(EGLDisplay,EGLSurface surface,EGLSurface,EGLContext ctx) const {
        if(fail=="current" || (fail=="unbind" && ctx==EGL_NO_CONTEXT) ||
           ((fail=="park-bind" || fail=="park-lost") && surface==reinterpret_cast<EGLSurface>(5)) ||
           ((fail=="attach-bind" || fail=="attach-bind-destroy" || fail=="attach-lost") && surface==reinterpret_cast<EGLSurface>(3))) return false;
        current=ctx;draw=surface;return true;
    }
    EGLContext eglGetCurrentContext() const {return current;}
    EGLBoolean eglDestroySurface(EGLDisplay,EGLSurface surface) const {
        if(fail=="destroy-surface" || fail=="attach-bind-destroy" ||
           (fail=="destroy-parking" && surface==reinterpret_cast<EGLSurface>(5)))return false;
        ++destroys;return true;
    }
    EGLBoolean eglDestroyContext(EGLDisplay,EGLContext) const {if(fail=="destroy-context")return false;++destroys;return true;}
    EGLBoolean eglQuerySurface(EGLDisplay,EGLSurface surface,EGLint query,EGLint* out) const {
        *out=surface==reinterpret_cast<EGLSurface>(5) ? (fail=="parking-size"?2:1) : (query==EGL_WIDTH?surfaceWidth:surfaceHeight);
        return fail!="size";
    }
    EGLBoolean eglSwapInterval(EGLDisplay,EGLint) const {return fail!="interval";}
    // 只在真实失败调用边界读取；前置条件拒绝必须保留这个计数，防止消费旧错误。
    EGLint eglGetError() const {++errorReads;return fail=="park-lost" || fail=="attach-lost" ? EGL_CONTEXT_LOST : fail.empty()?EGL_SUCCESS:EGL_BAD_SURFACE;}
    // Deliberately no eglTerminate member: production must not call it.
};
static const char* fakeVersion="4.2 Test";
static int mask=1;
static const unsigned char* String(unsigned) {return reinterpret_cast<const unsigned char*>(fakeVersion);}
static void Integer(unsigned query,int* out) {*out=query==0x9126?mask:1;}
static void* Resolve(const char* name) {
    return std::strcmp(name,"glGetString")==0 ? reinterpret_cast<void*>(&String) : reinterpret_cast<void*>(&Integer);
}
int main() try {
    amcl::desktop::ContextRequest request{3,2,0x00032001,true};
    for(const char* fault : {"initialize","api","config","surface","parking","context","current","size","park-bind","parking-size"}) {
        Fake api;api.fail=fault;Window w;std::string error;
        CHECK(!amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));CHECK(!error.empty());
        api.fail.clear();CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));CHECK(w.context==EGL_NO_CONTEXT && w.surface==EGL_NO_SURFACE);
    }
    for(const char* identity : {"OpenGL ES 3.2 Test","2.1 Test","broken"}) {
        Fake api;Window w;std::string error;fakeVersion=identity;
        CHECK(!amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));
        CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));
    }
    fakeVersion="4.2 Test";
    for(const char* fault : {"unbind","destroy-surface","destroy-parking","destroy-context"}) {
        Fake api;Window w;std::string error;
        CHECK(amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));
        CHECK(w.actualContextMajor==4 && w.actualContextMinor==2 && w.width==1280 && w.height==720);
        CHECK(!amcl::desktop::DestroyDesktopEgl(api,w,8));CHECK(w.context!=EGL_NO_CONTEXT);
        api.fail=fault;CHECK(!amcl::desktop::DestroyDesktopEgl(api,w,7));CHECK(w.eglTeardownPending);
        CHECK(w.context!=EGL_NO_CONTEXT);api.fail.clear();CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));
        CHECK(api.destroys==3);CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));CHECK(api.destroys==3);
    }
    for(const char* fault : {"", "park-bind", "destroy-surface"}) {
        Fake api;Window w;std::string error;
        CHECK(amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));
        const EGLContext original=w.context;const EGLSurface originalSurface=w.surface;
        CHECK(!amcl::desktop::SuspendDesktopEglSurface(api,w,8));
        CHECK(api.current==original && w.surface==originalSurface);
        api.fail=fault;
        const bool parked=amcl::desktop::SuspendDesktopEglSurface(api,w,7);
        CHECK(parked==api.fail.empty());CHECK(api.current==original);
        if(!parked)CHECK(w.surface==originalSurface);
        api.fail.clear();CHECK(amcl::desktop::SuspendDesktopEglSurface(api,w,7));
        CHECK(api.current==original && api.draw==w.parkingSurface && w.surface==EGL_NO_SURFACE);
        CHECK(w.contextOwnerTid==7 && api.creates==1);
        CHECK(amcl::desktop::SuspendDesktopEglSurface(api,w,7));
        CHECK(!amcl::desktop::AttachDesktopEglSurface(api,w,w.nativeWindow,1920,1080,8));
        for(const char* attachFault : {"surface","attach-bind"}) {
            api.fail=attachFault;
            CHECK(!amcl::desktop::AttachDesktopEglSurface(api,w,w.nativeWindow,1920,1080,7));
            CHECK(api.current==original && api.draw==w.parkingSurface && w.surface==EGL_NO_SURFACE);
        }
        api.fail="attach-bind-destroy";
        CHECK(!amcl::desktop::AttachDesktopEglSurface(api,w,w.nativeWindow,1920,1080,7));
        CHECK(w.surface!=EGL_NO_SURFACE && w.eglSurfaceDetachPending);
        CHECK(api.current==original && api.draw==w.parkingSurface);
        api.fail.clear();CHECK(amcl::desktop::SuspendDesktopEglSurface(api,w,7));
        api.fail.clear();api.surfaceWidth=1920;api.surfaceHeight=1080;
        CHECK(amcl::desktop::AttachDesktopEglSurface(api,w,w.nativeWindow,1920,1080,7));
        CHECK(api.current==original && api.draw==w.surface && api.creates==1);
        CHECK(w.width==1920 && w.height==1080);
        // A deliberate release must stay released during later surface loss.
        CHECK(api.eglMakeCurrent(w.display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT));
        w.contextOwnerTid=0;
        CHECK(amcl::desktop::SuspendDesktopEglSurface(api,w,7));CHECK(api.current==EGL_NO_CONTEXT);
        CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));CHECK(w.parkingSurface==EGL_NO_SURFACE);
    }
    // 恢复的成功包含实际尺寸与interval；context lost从失败操作保留到有类型的结果。
    for(const char* fault : {"interval","size","attach-lost"}) {
        Fake api;Window w;std::string error;amcl::graphics::EglLifecycleStatus status;
        CHECK(amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));
        CHECK(amcl::desktop::SuspendDesktopEglSurface(api,w,7));w.swapIntervalSet=true;
        api.fail=fault;
        CHECK(!amcl::desktop::AttachDesktopEglSurface(api,w,w.nativeWindow,1280,720,7,amcl::desktop::EglSurfaceGeometry{},&status));
        CHECK(status.driverFailure && status.contextLost()==(api.fail=="attach-lost"));
        api.fail.clear();CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));
    }
    {
        Fake api;Window w;std::string error;amcl::graphics::EglLifecycleStatus status;
        CHECK(amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));
        api.fail="park-lost";const int reads=api.errorReads;
        CHECK(!amcl::desktop::SuspendDesktopEglSurface(api,w,8,&status));
        CHECK(!status.driverFailure && !status.contextLost() && api.errorReads==reads);
        CHECK(!amcl::desktop::SuspendDesktopEglSurface(api,w,7,&status));CHECK(status.contextLost());
        api.fail.clear();CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));
    }
    {
        // 查询返回成功但尺寸非法时，遗留context-lost错误不得被当成本次驱动失败。
        Fake api;Window w;std::string error;amcl::graphics::EglLifecycleStatus status;
        CHECK(amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));
        CHECK(amcl::desktop::SuspendDesktopEglSurface(api,w,7));
        api.fail="park-lost";api.surfaceWidth=0;const int reads=api.errorReads;
        CHECK(!amcl::desktop::AttachDesktopEglSurface(api,w,w.nativeWindow,1280,720,7,amcl::desktop::EglSurfaceGeometry{},&status));
        CHECK(!status.driverFailure && !status.contextLost() && api.errorReads==reads);
        api.fail.clear();CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));
    }
    Fake api;Window w;std::string error;mask=2;
    CHECK(!amcl::desktop::CreateDesktopEgl(api,w,request,Resolve,7,error));CHECK(error=="requested-profile-unavailable");
    CHECK(amcl::desktop::DestroyDesktopEgl(api,w,7));
    std::vector<std::string> args={"-Dorg.lwjgl.opengl.libname=libglfw.so","-Dorg.lwjgl.opengl.libname=wrong.so","-Dorg.lwjgl.libname=lwjgl_v322","-Xmx2G"};
    amcl::desktop::FreezeDesktopLibraryArguments(args);auto before=args;amcl::desktop::FreezeDesktopLibraryArguments(args);CHECK(args==before);
    CHECK(std::count(args.begin(),args.end(),"-Dorg.lwjgl.opengl.libname=libGLv4.so")==1);
    CHECK(std::find(args.begin(),args.end(),"-Dorg.lwjgl.libname=lwjgl_v322")!=args.end());
    CHECK(std::find(args.begin(),args.end(),"-Dorg.lwjgl.opengl.libname=wrong.so")==args.end());
    std::cout<<"desktop EGL production core: creation/identity/teardown failure controls PASS; surface loss/retry/recovery preserves context PASS; pre-JVM binding PASS\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr<<"FAIL: "<<error.what()<<'\n';
    return 1;
}

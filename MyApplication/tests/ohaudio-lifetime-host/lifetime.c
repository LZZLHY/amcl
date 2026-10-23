/**
 * 正式L2 extal与真实OpenAL生命周期反例。系统mock独立持有平台回调，fault23沿
 * 原公开Release失败合同；只观察实际映射和返回，不自行munmap/伪造被测模块寿命。
 * 分normal、失败无额外引用、失败有真实dlopen引用三个冷进程，分开scope与责任。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <jni.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
/* 完整生产TU只编一次；同TU能绑定私有s_glfw/p_create，不向生产增加setter。 */
#include "../../prebuilt/lwjgl2/ohos-backend/amcl_lwjgl2_backend.c"
extern void auditFault(int,int,int);
extern int auditInfo(int);
extern int auditPump(void*,int,int);
extern void* auditCurrentWriteAddress(void);

/* 只有正常dlopen失败才会抵达此上游异常出口；本工具没有JVM，不冒充JNI异常资格。 */
void throwException(JNIEnv* env,const char* message) { (void)env;fprintf(stderr,"UNEXPECTED_LOAD_FAILURE %s\n",message);exit(90); }
static void require(int value,const char* message) { if(!value) {fprintf(stderr,"CONTROL_FAIL %s\n",message);exit(2);} }

/** 仅被测原unload期间武装，准确一次转调真实dlclose，记录系统结果/errno。
 * 原34组不改返回值；两个明确TEST_CONTROL只在真实close后改变wrapper返回，
 * 不改变实际映像寿命，也不把注入的-37称为平台失败。OpenAL DSO不受此wrap影响。 */
extern int __real_dlclose(void* handle);
static int closeArmed,closeCalls,closeWrongHandle,closeEntryErrno,closeRealErrno,closeResult;
static int closeReturnControl,closeReturnedResult,closeReturnedErrno;
static void* closeExpectedHandle;
/* 查询失败仅在原unload武装窗口内、精确handle/地址匹配时注入，不作用于DSO。
 * 先真实查询再报告TEST_LOOKUP_CONTROL；不创建任何额外loader引用。 */
static int lookupControl,lookupHits,lookupRealSucceeded,lookupRealErrno;
static void* identityGetterAnchor;
static void* closeOpenDeviceAnchor;
static const char* lookupControlName;
extern void* __real_dlsym(void* handle,const char* name);
extern int __real_dladdr(const void* address,Dl_info* info);
extern int __real_clock_gettime(clockid_t clock,struct timespec* stamp);

/** 两种精确lookup反例保留真实查询结果成功事实，返回NULL/EIO仅属fixture注入。 */
void* __wrap_dlsym(void* handle,const char* name) {
    void* result=__real_dlsym(handle,name);const int actualErrno=errno;
    if(closeArmed&&((lookupControl==1&&handle==s_glfw&&strcmp(name,"amclDiagnosticBuildIdentity")==0)||
      (lookupControl==2&&handle==closeExpectedHandle&&strcmp(name,"alcOpenDevice")==0))) {
        ++lookupHits;lookupRealSucceeded=result!=NULL;lookupRealErrno=actualErrno;
        errno=EIO;return NULL;
    }
    errno=actualErrno;return result;
}

/** identity/OpenAL owner分别以先前真实取得的地址精确匹配；不伪造任何base。 */
int __wrap_dladdr(const void* address,Dl_info* info) {
    const int result=__real_dladdr(address,info);const int actualErrno=errno;
    if(closeArmed&&((lookupControl==3&&address==identityGetterAnchor)||
      (lookupControl==4&&address==closeOpenDeviceAnchor))) {
        ++lookupHits;lookupRealSucceeded=result!=0;lookupRealErrno=actualErrno;
        errno=EIO;return 0;
    }
    errno=actualErrno;return result;
}

/** 单调时钟仍真实调用一次，再仅给诊断返回失败；不改平台时间或持有引用。 */
int __wrap_clock_gettime(clockid_t clock,struct timespec* stamp) {
    const int result=__real_clock_gettime(clock,stamp);const int actualErrno=errno;
    if(closeArmed&&lookupControl==5&&clock==CLOCK_MONOTONIC) {
        ++lookupHits;lookupRealSucceeded=result==0;lookupRealErrno=actualErrno;
        errno=EIO;return -1;
    }
    errno=actualErrno;return result;
}
int __wrap_dlclose(void* handle) {
    const int incoming=errno;
    if(closeArmed) {
        ++closeCalls;closeWrongHandle|=handle!=closeExpectedHandle;closeEntryErrno=incoming;
    }
    errno=incoming;
    const int result=__real_dlclose(handle);
    const int actualErrno=errno;
    int returnedResult=result,returnedErrno=actualErrno;
    if(closeArmed) {
        closeResult=result;closeRealErrno=actualErrno;
        if(closeReturnControl) returnedErrno=EIO;
        if(closeReturnControl==2) returnedResult=-37;
        closeReturnedResult=returnedResult;closeReturnedErrno=returnedErrno;
    }
    errno=returnedErrno;return returnedResult;
}

/** 显式原文用例不复制生产数字解析算法；每例独立冷进程，provider均为真实DSO。
 * mode:0同映像，1缺handle，2缺anchor，3缺getter，4不同owner，5全局alias陷阱。 */
struct DiagnosticCase {const char* name;const char* identity;int mode,enabled,sinkFailure,empty;};
#define IDENTITY_PREFIX "AMCL_DIAGNOSTICS_V1:product=default;mask="
static const struct DiagnosticCase diagnosticCases[]={
    {"diag-mask-0",IDENTITY_PREFIX "0;",0,0,0,0},
    {"diag-mask-1",IDENTITY_PREFIX "1;",0,0,0,0},
    {"diag-mask-2",IDENTITY_PREFIX "2;",0,0,0,0},
    {"diag-mask-3",IDENTITY_PREFIX "3;",0,1,0,0},
    {"diag-mask-4",IDENTITY_PREFIX "4;",0,0,0,0},
    {"diag-mask-5",IDENTITY_PREFIX "5;",0,0,0,0},
    {"diag-mask-6",IDENTITY_PREFIX "6;",0,0,0,0},
    {"diag-mask-7",IDENTITY_PREFIX "7;",0,1,0,0},
    {"diag-mask-max",IDENTITY_PREFIX "4294967295;",0,1,0,0},
    {"diag-no-provider",IDENTITY_PREFIX "3;",1,0,0,0},
    {"diag-no-anchor",IDENTITY_PREFIX "3;",2,0,0,0},
    {"diag-missing-getter",IDENTITY_PREFIX "3;",3,0,0,0},
    {"diag-owner-mismatch",IDENTITY_PREFIX "3;",4,0,0,0},
    {"diag-global-alias-trap",IDENTITY_PREFIX "3;",5,0,0,0},
    {"diag-nondefault","AMCL_DIAGNOSTICS_V1:product=store;mask=3;",0,0,0,0},
    {"diag-null-identity",NULL,0,0,0,0},
    {"diag-leading-zero",IDENTITY_PREFIX "03;",0,0,0,0},
    {"diag-plus",IDENTITY_PREFIX "+3;",0,0,0,0},
    {"diag-minus",IDENTITY_PREFIX "-3;",0,0,0,0},
    {"diag-space",IDENTITY_PREFIX " 3;",0,0,0,0},
    {"diag-trailing-space",IDENTITY_PREFIX "3; ",0,0,0,0},
    {"diag-empty-number",IDENTITY_PREFIX ";",0,0,0,0},
    {"diag-tail",IDENTITY_PREFIX "3;tail",0,0,0,0},
    {"diag-missing-separator",IDENTITY_PREFIX "3",0,0,0,0},
    {"diag-bad-prefix","prefix:" IDENTITY_PREFIX "3;",0,0,0,0},
    {"diag-overflow",IDENTITY_PREFIX "4294967296;",0,0,0,0},
    {"diag-too-long",IDENTITY_PREFIX "18446744073709551616;",0,0,0,0},
    {"diag-sink-failure",IDENTITY_PREFIX "3;",0,1,1,0},
    {"diag-empty-handle",IDENTITY_PREFIX "3;",0,1,0,1},
    {"diag-test-control-errno",IDENTITY_PREFIX "3;",0,1,0,0},
    {"diag-test-control-result",IDENTITY_PREFIX "3;",0,1,0,0},
    {"diag-identity-lookup-failure",IDENTITY_PREFIX "3;",0,1,0,0},
    {"diag-openal-lookup-failure",IDENTITY_PREFIX "3;",0,1,0,0},
    {"diag-identity-owner-failure",IDENTITY_PREFIX "3;",0,1,0,0},
    {"diag-openal-owner-failure",IDENTITY_PREFIX "3;",0,1,0,0},
    {"diag-clock-failure",IDENTITY_PREFIX "3;",0,1,0,0}
};
static void* identityProvider;
static void* missingProvider;

/** 不调用生产load_glfw或窗口函数；借真实fixture的出口/handle绑定gate前提。
 * global-alias-trap的missing handle与全局getter不同DSO，anchor却与全局getter
 * 同DSO；错误global fallback会通过owner核验并误启用，故该反控有区分力。 */
static void bindDiagnosticProvider(const struct DiagnosticCase* test) {
    typedef void (*SetIdentity)(const char*);
    identityProvider=dlopen("libdiagnostic-identity.so",RTLD_NOW|RTLD_GLOBAL);
    require(identityProvider!=NULL,"real identity provider");
    SetIdentity set=(SetIdentity)dlsym(identityProvider,"auditSetDiagnosticIdentity");
    void* getter=dlsym(identityProvider,"amclDiagnosticBuildIdentity");
    identityGetterAnchor=getter;
    void* anchor=dlsym(identityProvider,"glfwCreateWindow");
    Dl_info getterOwner={0},anchorOwner={0};
    require(set&&getter&&anchor&&dladdr(getter,&getterOwner)&&dladdr(anchor,&anchorOwner)&&
      getterOwner.dli_fbase==anchorOwner.dli_fbase,"actual same-image provider exports");
    set(test->identity);s_glfw=identityProvider;p_create=(PFN_glfwCreateWindow)anchor;
    if(test->mode>=3) {
        missingProvider=dlopen("libdiagnostic-missing.so",RTLD_NOW|RTLD_LOCAL);
        require(missingProvider!=NULL,"real getter-missing provider");
        void* missingAnchor=dlsym(missingProvider,"glfwCreateWindow");
        Dl_info missingOwner={0};
        require(missingAnchor&&dladdr(missingAnchor,&missingOwner)&&
          missingOwner.dli_fbase!=getterOwner.dli_fbase,"actual different provider images");
        require(dlsym(missingProvider,"amclDiagnosticBuildIdentity")==NULL,
          "handle-specific missing getter despite global alias");
        void* globalGetter=dlsym(RTLD_DEFAULT,"amclDiagnosticBuildIdentity");
        require(globalGetter==getter,"actual global identity alias is present");
        if(test->mode==3) {s_glfw=missingProvider;p_create=(PFN_glfwCreateWindow)missingAnchor;}
        if(test->mode==4) p_create=(PFN_glfwCreateWindow)missingAnchor;
        if(test->mode==5) s_glfw=missingProvider;
        printf("PROVIDER_CONTROL mode=%d sameImage=0 globalGetterPresent=1\n",test->mode);
    }
    if(test->mode==1) s_glfw=NULL;
    if(test->mode==2) p_create=NULL;
    const int enabled=l2OpenalUnloadDiagnosticsEnabled();
    printf("DIAGNOSTIC_GATE enabled=%d expected=%d mode=%d\n",enabled,test->enabled,test->mode);
    require(enabled==test->enabled,"production diagnostic gate outcome");
}

/** 释放fixture拥有的真实引用；先清私有借用值，避免清理后误用旧provider地址。 */
static void unbindDiagnosticProvider(void) {
    s_glfw=NULL;p_create=NULL;
    if(missingProvider) require(dlclose(missingProvider)==0,"close missing provider");
    if(identityProvider) require(dlclose(identityProvider)==0,"close identity provider");
    missingProvider=NULL;identityProvider=NULL;
}

/** sink阴性真正把原stderr fd指向/dev/full，确认stdio失败；stdout控制报告保留。
 * close前后的errno以真实wrapper观测为准，日志失败不得改变close次数/handle状态。
 * 空handle也走原生产函数，要求0次close；不制造无效loader handle来假装阴性。 */
static void checkedUnload(int round,int sinkFailure,int empty) {
    int savedStderr=-1,full=-1,sinkRejected=0;
    if(sinkFailure) {
        savedStderr=dup(STDERR_FILENO);full=open("/dev/full",O_WRONLY);
        require(savedStderr>=0&&full>=0&&dup2(full,STDERR_FILENO)>=0,"actual failing stderr sink");
    }
    closeExpectedHandle=s_oal_handle;closeCalls=closeWrongHandle=0;
    if(!empty) {
        void* openDevice=dlsym(closeExpectedHandle,"alcOpenDevice");Dl_info owner={0};
        require(openDevice&&dladdr(openDevice,&owner)&&owner.dli_fbase,"actual unload metadata");
        closeOpenDeviceAnchor=openDevice;
        printf("UNLOAD_BINDING round=%d handle=%p open_device_addr=%p open_device_base=%p\n",
          round,closeExpectedHandle,openDevice,owner.dli_fbase);
    }
    lookupHits=lookupRealSucceeded=lookupRealErrno=0;
    closeEntryErrno=closeRealErrno=closeResult=closeReturnedResult=closeReturnedErrno=0;closeArmed=1;
    const int entrySentinel=EBUSY;errno=entrySentinel;
    extal_UnloadLibrary();
    const int observedErrno=errno;closeArmed=0;
    if(sinkFailure) {
        sinkRejected=ferror(stderr)!=0;
        require(dup2(savedStderr,STDERR_FILENO)>=0,"restore original stderr");
        require(close(savedStderr)==0&&close(full)==0,"close sink fixture fds");clearerr(stderr);
    }
    require(s_oal_handle==NULL,"original handle cleared");
    if(empty) require(closeCalls==0&&observedErrno==entrySentinel,"empty handle preserves zero close/errno");
    else require(closeCalls==1&&!closeWrongHandle&&closeEntryErrno==entrySentinel&&
      closeResult==0&&closeReturnedResult==(closeReturnControl==2?-37:0)&&
      closeReturnedErrno==(closeReturnControl?EIO:closeRealErrno)&&observedErrno==closeReturnedErrno,
      "one real close and exact wrapper-return errno/result preservation");
    require(!sinkFailure||sinkRejected,"actual stderr rejection observed");
    printf("UNLOAD_CONTROL round=%d calls=%d entryErrno=%d realCloseErrno=%d observedErrno=%d result=%d handleCleared=1 sinkFailure=%d sinkRejected=%d empty=%d\n",
      round,closeCalls,empty?entrySentinel:closeEntryErrno,closeRealErrno,observedErrno,closeReturnedResult,sinkFailure,sinkRejected,empty);
    if(closeReturnControl) {
        require(EIO!=entrySentinel,"injected return errno differs from entry");
        printf("TEST_CONTROL round=%d injection=%s realCloseCalls=%d realCloseResult=%d realCloseErrno=%d returnedResult=%d returnedErrno=%d observedErrno=%d source=WRAPPER_AFTER_REAL_CLOSE\n",
          round,closeReturnControl==1?"errno":"result",closeCalls,closeResult,closeRealErrno,
          closeReturnedResult,closeReturnedErrno,observedErrno);
    }
    if(lookupControl) {
        require(lookupHits==1&&lookupRealSucceeded,"exact armed query injection hit real success once");
        printf("TEST_LOOKUP_CONTROL round=%d injection=%s hits=%d realSucceeded=%d realErrno=%d returnedFailure=1 returnedErrno=%d source=WRAPPER_AFTER_REAL_QUERY\n",
          round,lookupControlName,lookupHits,lookupRealSucceeded,lookupRealErrno,EIO);
    }
}
static int mapped(void* address) {
    FILE* file=fopen("/proc/self/maps","r");require(file!=NULL,"read maps");
    char line[2048];unsigned long start,end;int found=0;
    while(fgets(line,sizeof(line),file)) if(sscanf(line,"%lx-%lx",&start,&end)==2 &&
      (uintptr_t)address>=start && (uintptr_t)address<end) {
        printf("ACTUAL_MAPPING address=%p %s",address,line);found=1;break;
    }
    require(fclose(file)==0,"close maps");return found;
}
typedef void* (*Open)(const char*);
typedef void* (*Create)(void*,const int*);
typedef int (*Current)(void*);
typedef void (*Destroy)(void*);
typedef int (*Close)(void*);

int main(int argc,char** argv) {
    setbuf(stdout,NULL);setbuf(stderr,NULL);
    require(argc==2,"one case argument");
    // 仅两种明确冷case武装返回注入；清理provider时closeArmed已关闭，绝不注入。
    closeReturnControl=strcmp(argv[1],"diag-test-control-errno")==0?1:
      strcmp(argv[1],"diag-test-control-result")==0?2:0;
    // 查询反例的目标在武装前真实取得；正常组和provider清理仍完全透传。
    static const char* const lookupCases[]={"diag-identity-lookup-failure","diag-openal-lookup-failure",
      "diag-identity-owner-failure","diag-openal-owner-failure","diag-clock-failure"};
    static const char* const lookupNames[]={"identity-lookup","openal-lookup","identity-owner","openal-owner","clock"};
    for(unsigned i=0;i<5;++i) if(strcmp(argv[1],lookupCases[i])==0) {
        lookupControl=(int)i+1;lookupControlName=lookupNames[i];
    }
    const struct DiagnosticCase* diagnostic=NULL;
    for(unsigned i=0;i<sizeof(diagnosticCases)/sizeof(diagnosticCases[0]);++i)
        if(strcmp(argv[1],diagnosticCases[i].name)==0) diagnostic=&diagnosticCases[i];
    const int rejectLease=!diagnostic&&strncmp(argv[1],"lease-",6)==0;
    const int fail=!diagnostic&&!rejectLease && strcmp(argv[1],"normal")!=0;
    const int hold=strcmp(argv[1],"failure-hold")==0;
    require(!fail || hold || strcmp(argv[1],"failure-unheld")==0,"known case");
    require(!rejectLease || strcmp(argv[1],"lease-no-owner")==0 || strcmp(argv[1],"lease-wrong-owner")==0,"known lease control");
    printf("LIFETIME_START pid=%d case=%s\n",getpid(),argv[1]);
    if(diagnostic) bindDiagnosticProvider(diagnostic);
    if(diagnostic&&diagnostic->empty) {
        require(s_oal_handle==NULL,"cold empty-handle precondition");checkedUnload(0,0,1);
        unbindDiagnosticProvider();printf("LIFETIME_END completed=1 case=%s\n",argv[1]);return 0;
    }
    auditFault(0,0,-1);
    for(int round=0;round<(fail?1:2);++round) {
        extal_LoadLibrary(NULL,NULL);
        Open open=(Open)extal_NativeGetFunctionPointer("alcOpenDevice");
        Create create=(Create)extal_NativeGetFunctionPointer("alcCreateContext");
        Current current=(Current)extal_NativeGetFunctionPointer("alcMakeContextCurrent");
        Destroy destroy=(Destroy)extal_NativeGetFunctionPointer("alcDestroyContext");
        Close close=(Close)extal_NativeGetFunctionPointer("alcCloseDevice");
        require(open&&create&&current&&destroy&&close,"actual ALC functions");
        Dl_info owner;require(dladdr((void*)open,&owner)!=0,"actual OpenAL owner");
        printf("ACTUAL_OPENAL round=%d owner=%s address=%p\n",round,owner.dli_fname,(void*)open);
        void* device=open(NULL);require(device!=NULL,"production open device");
        const int attrs[]={0x1007,48000,0};void* context=create(device,attrs);
        if(rejectLease) {
            // 实际租约缺失/同base失败须在发布任何平台callback和Generate之前拒绝。
            require(context==NULL,"lease failure must reject production context");
            require(auditInfo(8)==0 && auditInfo(9)==0 && auditInfo(10)==0 && auditCurrentWriteAddress()==NULL,"no callback published");
            printf("LEASE_REJECTED contextCreated=0 callbacksPublished=0 generateCalls=0\n");
            require(close(device)!=0,"close rejected device");checkedUnload(round,0,0);
            const int apiMapped=mapped((void*)open);
            void* foreign=dlopen("libforeign-owner.so",RTLD_NOW|RTLD_LOCAL|RTLD_NOLOAD);
            const int foreignMapped=foreign!=NULL;if(foreign) require(dlclose(foreign)==0,"close inspection ref");
            printf("REJECT_UNLOAD apiMapped=%d foreignMapped=%d\n",apiMapped,foreignMapped);
            require(!apiMapped&&!foreignMapped,"failed acquisition rollback releases all images");
            printf("LIFETIME_END completed=1 case=%s\n",argv[1]);return 0;
        }
        require(context!=NULL&&current(context)!=0,"production create/current");
        void* callback=auditCurrentWriteAddress();require(callback!=NULL&&mapped(callback),"actual mapped callback");
        void* extra=hold?dlopen(owner.dli_fname,RTLD_NOW|RTLD_LOCAL):NULL;
        if(hold) require(extra!=NULL,"independent real module reference");
        if(fail) auditFault(23,0,-1);
        require(current(NULL)!=0,"clear current");destroy(context);require(close(device)!=0,"close device");
        require(auditInfo(9)==0,"builders retired");
        require(auditInfo(10)==(fail?1:0),"actual release outcome");
        checkedUnload(round,diagnostic?diagnostic->sinkFailure:0,0);
        const int alive=mapped(callback);
        printf("POST_UNLOAD round=%d callbackMapped=%d retainedRenderers=%d hold=%d\n",round,alive,auditInfo(10),hold);
        if(fail) {
            unsigned char data[64];memset(data,0x5a,sizeof(data));
            printf("BEFORE_ACTUAL_LATE_CALLBACK callbackMapped=%d\n",alive);
            int result=auditPump(data,sizeof(data),1);
            require(result==0,"late callback return");
            for(unsigned i=0;i<sizeof(data);++i) require(data[i]==0,"detached callback silence");
            printf("LATE_CALLBACK_RETURNED result=%d\n",result);
            if(extra) require(dlclose(extra)==0,"release extra reference");
        }
    }
    unbindDiagnosticProvider();printf("LIFETIME_END completed=1 case=%s\n",argv[1]);return 0;
}

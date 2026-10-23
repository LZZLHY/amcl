/** GUI设置的JNI薄适配：缓存启动器自有类，游戏实例必须来自当前JVM的已初始化类集合。 */
#include "game_gui_bridge.h"
#include "game_gui_observation.h"
#include "game_process_exit.h"
#include "jvm_launcher.h"
#include "jni.h"
#include "jvmti.h"
#include "../platform/render_scale.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>

namespace {
// 这把锁仅由进程GUI worker取得；同步NAPI getter/stop只使用另一把短registry锁。
std::mutex mutex;
jclass helper=nullptr;
jmethodID bindMethod=nullptr,pollMethod=nullptr,pollGuideMethod=nullptr,restoreMethod=nullptr,configureMethod=nullptr;
// 缺少scoped恢复协议的旧JAR可继续只读观察，但绝不扩大成可取消的写能力。
jmethodID scopedRestoreMethod=nullptr;
bool guardedRestore=false;
std::vector<std::string> names;
bool bound=false;
unsigned attempts=0;
std::chrono::steady_clock::time_point nextProbe{};

/** JNI环境属于调用线程；只解除本次自己附加的线程，禁止缓存另一个线程的JNIEnv。 */
struct Environment {
    JavaVM* vm=nullptr; JNIEnv* env=nullptr; bool attached=false;
    Environment() {
        if(jvmRuntimeState()!=2 || amclGameExitPendingForCurrentProcess()) return;
        vm=static_cast<JavaVM*>(jvmGetJavaVM()); if(!vm) return;
        const jint result=vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6);
        if(result==JNI_EDETACHED) {
            // 本执行端口只供进程GUI worker，具名附加可在真实JVM线程转储中区分观察者。
            JavaVMAttachArgs arguments{JNI_VERSION_1_6,const_cast<char*>("AMCL-GUI-Observer"),nullptr};
            attached=vm->AttachCurrentThreadAsDaemon(reinterpret_cast<void**>(&env),&arguments)==JNI_OK;
            if(!attached) env=nullptr;
        } else if(result!=JNI_OK) env=nullptr;
    }
    ~Environment() { if(attached) vm->DetachCurrentThread(); }
};
bool clearException(JNIEnv* env) {
    if(!env->ExceptionCheck()) return false;
    env->ExceptionClear(); return true;
}
/**
 * 实际helper Class注册的资格回查，供Java游戏线程在写/回滚前调用。ticket必须是本
 * Native进程分配的非零uint32；其它long值直接返回JNI_FALSE，不截断成另一张票。
 * env/class只在本次JNI callback有效且本函数不借出、缓存或调用它们；资格查询走
 * 原生registry/Core事实，不取本文件JNI mutex，不附加线程或等待worker。true只表示
 * 原scope/source/resource与本票期限当前成立，绝不表示设置已写入或退出已完成。
 */
jboolean JNICALL nativeTicketCurrent(JNIEnv*,jclass,jlong ticket) {
    return ticket>0 && ticket<=UINT32_MAX && amcl::gui::TicketCurrent(static_cast<uint32_t>(ticket))?JNI_TRUE:JNI_FALSE;
}
/**
 * Java完成所有可能阻塞的原值/Screen读取后，立即在实际setter调用前认领本票。
 * 只接受精确uint32票、当前本局唯一Java恢复owner和尚未认领的原资源；成功返回
 * JNI_TRUE并让Native知道已进入执行阶段，失败返回JNI_FALSE且Java应拒绝写入。
 * 不保存JNI env/class，不进入JVM；认领不替代Java最终ACK，也不承诺能撤销已进入
 * set/save的方法，scope退休仍不join可能阻塞的JNI worker。
 */
jboolean JNICALL nativeRestoreBegin(JNIEnv*,jclass,jlong ticket) {
    return ticket>0 && ticket<=UINT32_MAX && amcl::gui::BeginRestore(static_cast<uint32_t>(ticket))?JNI_TRUE:JNI_FALSE;
}
bool prepare(JNIEnv* env) {
    if(helper) return true;
    jclass local=env->FindClass("com/amcl/launcher/GameGuiBridge");
    if(clearException(env) || !local) return false;
    jmethodID candidates=env->GetStaticMethodID(local,"candidateNames","()[Ljava/lang/String;");
    bindMethod=env->GetStaticMethodID(local,"bind","(Ljava/lang/Class;)Z");
    pollMethod=env->GetStaticMethodID(local,"poll","(II)[D");
    restoreMethod=env->GetStaticMethodID(local,"restore","(IJ)J");
    configureMethod=env->GetStaticMethodID(local,"configure","(Ljava/lang/String;)Z");
    if(clearException(env) || !candidates || !bindMethod || !pollMethod || !restoreMethod || !configureMethod) {
        env->DeleteLocalRef(local); return false;
    }
    // 教学参数是可选扩展；旧JAR缺失时清除查找异常，仍保留原尺寸/恢复接口。
    pollGuideMethod=env->GetStaticMethodID(local,"poll","(IIZ)[D");
    if(clearException(env)) pollGuideMethod=nullptr;
    // 只在启动器自有实际helper Class注册端口；不探测或提前初始化游戏平台类。
    scopedRestoreMethod=env->GetStaticMethodID(local,"restoreScoped","(IJJ)J");
    if(clearException(env))scopedRestoreMethod=nullptr;
    if(scopedRestoreMethod) {
        JNINativeMethod ports[]{{const_cast<char*>("nativeRequestCurrent"),const_cast<char*>("(J)Z"),reinterpret_cast<void*>(nativeTicketCurrent)},
            {const_cast<char*>("nativeRestoreBegin"),const_cast<char*>("(J)Z"),reinterpret_cast<void*>(nativeRestoreBegin)}};
        guardedRestore=env->RegisterNatives(local,ports,2)==JNI_OK;
        if(clearException(env))guardedRestore=false;
    }
    auto list=static_cast<jobjectArray>(env->CallStaticObjectMethod(local,candidates));
    if(clearException(env) || !list) { env->DeleteLocalRef(local); return false; }
    const jsize count=env->GetArrayLength(list);
    names.clear();
    for(jsize i=0;i<count && i<32;i++) {
        auto value=static_cast<jstring>(env->GetObjectArrayElement(list,i));
        if(!value) continue;
        const char* chars=env->GetStringUTFChars(value,nullptr);
        if(chars) { std::string name(chars); std::replace(name.begin(),name.end(),'.','/'); names.push_back("L"+name+";");
            env->ReleaseStringUTFChars(value,chars); }
        env->DeleteLocalRef(value);
    }
    helper=static_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(list); env->DeleteLocalRef(local);
    return !clearException(env) && helper;
}

/** 启动按2/10/30秒退避探测；重整合包初始化可能超过一分钟，不能提前永久放弃。成功后停止扫描。 */
void discover(Environment& jni) {
    const auto now=std::chrono::steady_clock::now();
    if(bound || now<nextProbe) return;
    if(attempts<30) attempts++;
    nextProbe=now+std::chrono::seconds(attempts<10 ? 2 : attempts<30 ? 10 : 30);
    jvmtiEnv* ti=nullptr;
    if(jni.vm->GetEnv(reinterpret_cast<void**>(&ti),JVMTI_VERSION_1_2)!=JNI_OK || !ti) return;
    jint count=0; jclass* classes=nullptr;
    if(ti->GetLoadedClasses(&count,&classes)==JVMTI_ERROR_NONE) {
        for(jint i=0;i<count;i++) {
            if(!bound) {
                char* signature=nullptr;
                if(ti->GetClassSignature(classes[i],&signature,nullptr)==JVMTI_ERROR_NONE && signature) {
                    if(std::find(names.begin(),names.end(),signature)!=names.end()) {
                        jint status=0;
                        if(ti->GetClassStatus(classes[i],&status)==JVMTI_ERROR_NONE && (status&JVMTI_CLASS_STATUS_INITIALIZED)) {
                            const jboolean accepted=jni.env->CallStaticBooleanMethod(helper,bindMethod,classes[i]);
                            bound=!clearException(jni.env) && accepted==JNI_TRUE;
                        }
                    }
                    ti->Deallocate(reinterpret_cast<unsigned char*>(signature));
                }
            }
            jni.env->DeleteLocalRef(classes[i]);
        }
        ti->Deallocate(reinterpret_cast<unsigned char*>(classes));
    }
    ti->DisposeEnvironment();
}
}

/**
 * 仅进程GUI worker使用的JNI观察执行端口。request是捕获原scope/source/binding的
 * 固定副本，version数组由调用方保证终止；values是调用方独占的19个double，先清零
 * 并提供真实渲染映射尺寸前缀，JVM/已初始化游戏接口不可用时保持不可写的降级状态。
 * 本函数可能在JNI附加、Java monitor或游戏实现中阻塞，调用方必须已释放registry锁；
 * UI getter/停止不能调用它或等待它。JNI env只属于worker本线程，Environment仅解除
 * 本次自己建立的daemon附加，缓存的helper global ref属于被进程owner固定的同一JVM。
 * 确切接受原13项或完整19项，旧helper缺Native恢复guard时仅撤canRestore，不伪造
 * 交付。返回后的scope/resource仍由调用方再次验证，迟到值不自动改绑新来源。
 */
void amcl::gui::PollOnWorker(const Request& request,double values[AMCL_GAME_GUI_VALUE_COUNT]) {
    const int width=request.width,height=request.height;
    const char* version=request.version;const bool guideActive=request.guide;
    std::fill(values,values+AMCL_GAME_GUI_VALUE_COUNT,0.0);
    if(width<=0 || height<=0 || width>65535 || height>65535 || !version || !*version) return;
    // 即使该加载器没有可绑定GUI接口，也提供已发布的渲染尺寸供只读options估算；status仍为0。
    values[3]=std::lround(amcl::renderscale::MapX(width));
    values[4]=std::lround(amcl::renderscale::MapY(height));
    std::lock_guard<std::mutex> lock(mutex);
    Environment jni; if(!jni.env || !prepare(jni.env)) return;
    jstring text=jni.env->NewStringUTF(version);
    if(clearException(jni.env) || !text) return;
    const jboolean configured=jni.env->CallStaticBooleanMethod(helper,configureMethod,text);
    jni.env->DeleteLocalRef(text);
    if(clearException(jni.env) || configured!=JNI_TRUE) return;
    discover(jni); if(!bound) return;
    const jint w=static_cast<jint>(std::lround(amcl::renderscale::MapX(width)));
    const jint h=static_cast<jint>(std::lround(amcl::renderscale::MapY(height)));
    auto array=static_cast<jdoubleArray>(pollGuideMethod ?
        jni.env->CallStaticObjectMethod(helper,pollGuideMethod,w,h,guideActive ? JNI_TRUE : JNI_FALSE) :
        jni.env->CallStaticObjectMethod(helper,pollMethod,w,h));
    if(clearException(jni.env) || !array) return;
    // 明确接受旧13项或新19项，半份尾表拒绝；旧值只填前缀，不继承上一屏的导航。
    const jsize count=jni.env->GetArrayLength(array);
    if(count==13 || count==AMCL_GAME_GUI_VALUE_COUNT) jni.env->GetDoubleArrayRegion(array,0,count,values);
    if(!guardedRestore)values[9]=0;
    if(clearException(jni.env)) std::fill(values,values+AMCL_GAME_GUI_VALUE_COUNT,0.0);
    jni.env->DeleteLocalRef(array);
}

/**
 * 仅同一worker提交的恢复执行端口，输入包含原Native票、目标scale和已观察revision。
 * 参数/实际helper/guard或原票资格无效返回0；正Java ID仅证明实际游戏队列接受，-2
 * 表示同helper读任务Busy，允许调用方在原Native2s期限内重试，不能把它改报完成。
 * Java ID与Native UI票分开，最终效果由后续poll的同Java ID/result确认；本函数可能
 * 阻塞JNI，绝不在registry锁内调用。借用的VM/global helper属于进程，局部env不跨
 * 线程流转；真正写前仍由Java重核原值/Screen及Native资源、认领本票，防迟到请求。
 */
int64_t amcl::gui::RestoreOnWorker(const Request& request) {
    const int scale=request.scale;const uint64_t revision=request.revision;
    if(scale<0 || scale>64 || revision==0 || revision>9007199254740991ULL) return 0;
    std::lock_guard<std::mutex> lock(mutex);
    Environment jni; if(!jni.env || !helper || !bound || !guardedRestore || !TicketCurrent(request.ticket)) return 0;
    const jlong id=jni.env->CallStaticLongMethod(helper,scopedRestoreMethod,scale,static_cast<jlong>(revision),static_cast<jlong>(request.ticket));
    return clearException(jni.env) ? 0 : static_cast<int64_t>(id);
}

/** GUI设置的JNI薄适配：缓存启动器自有类，游戏实例必须来自当前JVM的已初始化类集合。 */
#include "game_gui_bridge.h"
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
std::mutex mutex;
jclass helper=nullptr;
jmethodID bindMethod=nullptr,pollMethod=nullptr,pollGuideMethod=nullptr,restoreMethod=nullptr,configureMethod=nullptr;
std::vector<std::string> names;
bool bound=false;
unsigned attempts=0;
std::chrono::steady_clock::time_point nextProbe{};

/** JNI环境属于调用线程；只解除本次自己附加的线程，禁止缓存另一个线程的JNIEnv。 */
struct Environment {
    JavaVM* vm=nullptr; JNIEnv* env=nullptr; bool attached=false;
    Environment() {
        if(jvmRuntimeState()!=2) return;
        vm=static_cast<JavaVM*>(jvmGetJavaVM()); if(!vm) return;
        const jint result=vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6);
        if(result==JNI_EDETACHED) {
            attached=vm->AttachCurrentThreadAsDaemon(reinterpret_cast<void**>(&env),nullptr)==JNI_OK;
            if(!attached) env=nullptr;
        } else if(result!=JNI_OK) env=nullptr;
    }
    ~Environment() { if(attached) vm->DetachCurrentThread(); }
};
bool clearException(JNIEnv* env) {
    if(!env->ExceptionCheck()) return false;
    env->ExceptionClear(); return true;
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

void amcl_read_game_gui(int width,int height,const char* version,double values[AMCL_GAME_GUI_VALUE_COUNT],bool guideActive) {
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
    if(clearException(jni.env)) std::fill(values,values+AMCL_GAME_GUI_VALUE_COUNT,0.0);
    jni.env->DeleteLocalRef(array);
}

uint64_t amcl_restore_game_gui(int scale,uint64_t revision) {
    if(scale<0 || scale>64 || revision==0 || revision>9007199254740991ULL) return 0;
    std::lock_guard<std::mutex> lock(mutex);
    Environment jni; if(!jni.env || !helper || !bound) return 0;
    const jlong id=jni.env->CallStaticLongMethod(helper,restoreMethod,scale,static_cast<jlong>(revision));
    return clearException(jni.env) || id<=0 ? 0 : static_cast<uint64_t>(id);
}

#pragma once
// JNI_CreateJavaVM成功并不证明文件堆选项生效（过时选项也可能被忽略）。
// 在任何游戏main前向实际HotSpot管理接口读回冻结目录、严格解析与最终堆大小。
// 此处只核VM事实；文件映射/性能/系统内存可用性仍须各JDK真机资格验证。
#include "jvm_heap_backing.h"
#include "jvm_heap_options.h"
#include "jni_mutf8.h"
#include "jni.h"

namespace amcl::jvm {
inline bool VerifyHeapBackingVm(JNIEnv* env, const std::string& directory,
                                uint64_t plannedMaximum, uint64_t& actualMaximum,
                                std::string& error) {
    error="heapfile_vm_options_unavailable";
    if(!env || env->PushLocalFrame(16)<0) {
        if(env && env->ExceptionCheck())env->ExceptionClear();
        return false;
    }
    struct Frame {
        JNIEnv* env;
        ~Frame() { if(env->ExceptionCheck())env->ExceptionClear(); env->PopLocalFrame(nullptr); }
    } frame{env};
    const auto failed=[&] { return env->ExceptionCheck()==JNI_TRUE; };
    const jclass factory=env->FindClass("java/lang/management/ManagementFactory");
    if(!factory || failed())return false;
    const jclass type=env->FindClass("com/sun/management/HotSpotDiagnosticMXBean");
    if(!type || failed())return false;
    const auto getBean=env->GetStaticMethodID(factory,"getPlatformMXBean","(Ljava/lang/Class;)Ljava/lang/management/PlatformManagedObject;");
    if(!getBean || failed())return false;
    const jobject bean=env->CallStaticObjectMethod(factory,getBean,type);
    if(!bean || failed())return false;
    const auto getOption=env->GetMethodID(type,"getVMOption","(Ljava/lang/String;)Lcom/sun/management/VMOption;");
    if(!getOption || failed())return false;
    const jclass optionType=env->FindClass("com/sun/management/VMOption");
    if(!optionType || failed())return false;
    const auto getValue=env->GetMethodID(optionType,"getValue","()Ljava/lang/String;");
    if(!getValue || failed())return false;
    const auto read=[&](const char* key,std::string& output) {
        error=std::string("heapfile_vm_option_unavailable:")+key;
        const jstring name=env->NewStringUTF(key);
        if(!name || failed())return false;
        const jobject option=env->CallObjectMethod(bean,getOption,name);
        env->DeleteLocalRef(name);
        if(!option || failed())return false;
        const auto value=static_cast<jstring>(env->CallObjectMethod(option,getValue));
        env->DeleteLocalRef(option);
        if(!value || failed())return false;
        const jsize length=env->GetStringLength(value);
        if(failed())return false;
        const jchar* text=env->GetStringChars(value,nullptr);
        if(!text || failed())return false;
        bool valid=false;
        try { valid=amcl::utf16ToUtf8(text,static_cast<size_t>(length),output); } catch (...) { valid=false; }
        env->ReleaseStringChars(value,text); env->DeleteLocalRef(value); return valid;
    };
    std::string actualPath,strict,maximum;
    if(!read("AllocateHeapAt",actualPath) || !read("IgnoreUnrecognizedVMOptions",strict) ||
       !read("MaxHeapSize",maximum))return false;
    if(actualPath!=directory) { error="heapfile_vm_directory_mismatch"; return false; }
    if(strict!="false") { error="heapfile_vm_strict_options_mismatch"; return false; }
    // HotSpot按GC/平台对齐最大堆；允许已计入磁盘准入的有界对齐，不把向上对齐
    // 当成用户参数丢失，也不接受无限增大后的值。实际值另外记录供资格验证使用。
    if(!ParseHeapBytes(maximum,actualMaximum) || !actualMaximum ||
       plannedMaximum>std::numeric_limits<uint64_t>::max()-HeapFileAlignmentReserve ||
       actualMaximum>plannedMaximum+HeapFileAlignmentReserve ||
       (actualMaximum<plannedMaximum && plannedMaximum-actualMaximum>HeapFileAlignmentReserve)) {
        error="heapfile_vm_heap_mismatch"; return false;
    }
    error.clear(); return true;
}
}

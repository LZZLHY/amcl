// 真实宿主 JNI 正反例。生产函数/装配正文由脚本提取到外部 include，平台只替换装载边界。
// 每次执行只创建一个 JVM；任何 HotSpot 直接退出均由父脚本按 OS 状态识别。
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#include <process.h>
#define getpid _getpid
#else
#include <dlfcn.h>
#include <unistd.h>
#endif
#include "jvm/jni.h"
#include "jvm/jni_mutf8.h"
#include "jvm/jvm_heap_options.h"
#include "jvm/runtime_bootstrap_contract.h"
#include "jvm/jvm_common_args.cpp"
#include "platform/graphics_plan.h"

#define AMCL_LOG_I(...) ((void)0)
#define AMCL_LOG_E(...) ((void)0)
namespace amcl::graphics {
const GraphicsPlan* ActiveGraphicsPlan() { static GraphicsPlan plan; return &plan; }
}
namespace amcl::sessionlog {
struct State { const char* directory = ""; } state;
bool owned() { return false; }
}
bool amclGameExitArmedForCurrentProcess() { return false; }
long long amclLedgerGetLaunchActivity() { return 0; }
void JNICALL isolatedGameExitHook(jint) {}
std::string g_classpath, g_extraLibPath, g_status, g_mcStatus;
int g_xmxMb = 4096;
bool g_forkChildMode = false;
jint g_jniVersion;
std::vector<std::string> g_extraArgs;
std::vector<amcl::jvm::BootstrapProperty> g_runtimeBootstrapProperties;
#include "jvm_bootstrap_properties.inc"

namespace {
using CreateVm = jint(JNICALL*)(JavaVM**, void**, void*);
/** 装载父脚本显式指定的宿主 JVM；不寻找产品下载目录、不执行 OHOS ELF loader。 */
CreateVm LoadJvm(const std::string& path, const std::string& javaHome) {
#ifdef _WIN32
    SetDllDirectoryA((javaHome + "/bin").c_str());
    const auto library = LoadLibraryA(path.c_str());
    return library ? reinterpret_cast<CreateVm>(GetProcAddress(library, "JNI_CreateJavaVM")) : nullptr;
#else
    (void)javaHome;
    void* library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    return library ? reinterpret_cast<CreateVm>(dlsym(library, "JNI_CreateJavaVM")) : nullptr;
#endif
}
void Require(bool value, const char* name) {
    if (value) return;
    std::cerr << "ASSERTION_FAILED=" << name << std::endl;
    std::exit(20);
}

/** 在正确 Java 属性上验证正例，再真的改变/移除属性，证明修复未放宽保护。 */
int Properties(CreateVm createVm, bool classicLayout) {
    JavaVMOption options[] = {{const_cast<char*>("-Xmx128m"), nullptr}};
    JavaVMInitArgs arguments{classicLayout ? JNI_VERSION_1_8 : JNI_VERSION_10, 1, options, JNI_TRUE};
    JavaVM* vm = nullptr;
    JNIEnv* env = nullptr;
    Require(createVm(&vm, reinterpret_cast<void**>(&env), &arguments) == JNI_OK, "property JVM creation");
    const std::vector<std::string> paths = {"/game/test", u8"/game/测试", u8"/game/测试😀", u8"/game/𠀋"};
    for (std::size_t index = 0; index < paths.size(); ++index) {
        g_runtimeBootstrapProperties = amcl::jvm::RuntimeBootstrapProperties("/native", paths[index],
            "mobileglues", "libamcl_graphics_runtime.so", false);
        for (const auto& property : g_runtimeBootstrapProperties)
            setSystemProperty(env, property.first.c_str(), property.second.c_str());
        Require(phase_verifyRuntimeProperties(env), "correct Unicode property rejected");
        setSystemProperty(env, "jna.tmpdir", "/tampered");
        Require(!phase_verifyRuntimeProperties(env), "tampered property accepted");
        std::cout << "PROPERTY_CASE=" << index << " CORRECT=accepted TAMPERED=rejected" << std::endl;
    }
    // 空值与未设置严格分开。不能把 JNI 读取失败或 null 统一当成空串而通过校验。
    g_runtimeBootstrapProperties = {{"amcl.test.empty", ""}};
    setSystemProperty(env, "amcl.test.empty", "");
    Require(phase_verifyRuntimeProperties(env), "explicit empty property rejected");
    jclass system = env->FindClass("java/lang/System");
    jmethodID clear = env->GetStaticMethodID(system, "clearProperty", "(Ljava/lang/String;)Ljava/lang/String;");
    jstring key = env->NewStringUTF("amcl.test.empty");
    jobject old = env->CallStaticObjectMethod(system, clear, key);
    if (old) env->DeleteLocalRef(old);
    Require(!phase_verifyRuntimeProperties(env), "missing property accepted as empty");
    // 不合法的 UTF-16 原文也必须拒绝，而非替换为另一条合法路径；直接构造 Java 码元。
    const jchar high = 0xD800;
    jstring invalid = env->NewString(&high, 1);
    jmethodID set = env->GetStaticMethodID(system, "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    old = env->CallStaticObjectMethod(system, set, key, invalid);
    if (old) env->DeleteLocalRef(old);
    Require(!phase_verifyRuntimeProperties(env), "unpaired surrogate accepted as empty");
    // 空 key 会由真实 System.getProperty 抛 IllegalArgumentException。异常读取不能
    // 被当成空值通过，而且 native 边界必须清除异常，避免污染随后的 JNI 清理/调用。
    g_runtimeBootstrapProperties = {{"", ""}};
    Require(!phase_verifyRuntimeProperties(env) && !env->ExceptionCheck(), "Java property exception not rejected and cleared");
    env->DeleteLocalRef(invalid);
    env->DeleteLocalRef(key);
    env->DeleteLocalRef(system);
    Require(!env->ExceptionCheck(), "property test left Java exception");
    Require(vm->DestroyJavaVM() == JNI_OK, "property JVM destruction");
    std::cout << "PROPERTY_PROTECTION=PASS" << std::endl;
    return 0;
}

/** 生产最终 option 装配：仅移除不存在于宿主的 AMCL 系统加载器，完整输出其余选项。 */
int Options(const std::string& jvm, const std::string& javaHomeDir, const std::string& directory,
            bool classicLayout) {
    const std::string nativeLibDir = javaHomeDir + "/bin";
    const std::string jdkDataDir = directory;
    const char* appFilesDir = directory.c_str();
    g_classpath = directory;
    // 此片段包含生产的失败返回；必须在下面 LoadJvm 之前执行。
#include "jvm_bootstrap_heap_preflight.inc"
#include "jvm_bootstrap_options.inc"
    for (const auto& option : optVec) std::cout << "PRODUCTION_OPTION=" << option.optionString << std::endl;
    optVec.erase(std::remove_if(optVec.begin(), optVec.end(), [](const JavaVMOption& option) {
        return std::string(option.optionString).rfind("-Djava.system.class.loader=", 0) == 0;
    }), optVec.end());
    vm_args.nOptions = static_cast<jint>(optVec.size());
    vm_args.options = optVec.data();
    const auto createVm = LoadJvm(jvm, javaHomeDir);
    Require(createVm != nullptr, "host JVM library missing");
    std::cout << "JVM_LIBRARY_LOADED=1" << std::endl;
    JavaVM* vm = nullptr;
    JNIEnv* env = nullptr;
    const jint result = createVm(&vm, reinterpret_cast<void**>(&env), &vm_args);
    std::cout << "CREATE_JVM_RC=" << result << std::endl;
    if (result != JNI_OK) return 5;
    Require(vm->DestroyJavaVM() == JNI_OK, "option JVM destruction");
    return 0;
}
}

int main(int argc, char** argv) {
    if (argc < 6) return 2;
    const std::string mode = argv[1], jvm = argv[2], javaHome = argv[3], directory = argv[4];
    const bool classic = std::string(argv[5]) == "8";
    if (mode == "properties") {
        const auto createVm = LoadJvm(jvm, javaHome);
        Require(createVm != nullptr, "host JVM library missing");
        return Properties(createVm, classic);
    }
    if (argc < 7) return 2;
    g_xmxMb = std::atoi(argv[6]);
    for (int index = 7; index < argc; ++index) g_extraArgs.emplace_back(argv[index]);
    const int result = Options(jvm, javaHome, directory, classic);
    std::cout << "HOST_RESULT=" << result << " STATUS=" << g_status << std::endl;
    // 预检返回码作为数据交父脚本核验，不与 HotSpot 直接终止进程混淆。
    return result == 0 || result == -11 ? 0 : result;
}

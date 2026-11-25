// 真实宿主 JNI 正反例。生产函数/装配正文由脚本提取到外部 include，平台只替换装载边界。
// 每次执行只创建一个 JVM；任何 HotSpot 直接退出均由父脚本按 OS 状态识别。
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
#ifdef _WIN32
// Windows装载边界不能把min/max宏带入生产的numeric_limits空间判据。
#ifndef NOMINMAX
#define NOMINMAX
#endif
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
#include "jvm/jvm_heap_backing.h"
#include "jvm/jdk_native_temp_contract.h"
#include "jvm/runtime_bootstrap_contract.h"
#include "jvm/jvm_common_args.cpp"
#include "jvm/jvm_cf_policy.h"
#include "platform/graphics_plan.h"

// 本套只验证真实宿主JNI的RAM堆/属性装配。POSIX目录权限、fd和磁盘准入由文件堆专项
// 执行；这里的文件系统端口始终明确拒绝，避免Windows夹具伪称已验证OHOS文件背书。
// 显式文件堆请求仍经过生产解析器和失败分支，必须在装载任何JVM之前结束，不回退RAM。
namespace amcl::jvm {
class PreparedHeapBackingDirectory final {
public:
    bool prepare(const char*,const HeapBackingRequest&,uint64_t,std::string& error) {
        error="host_fixture_heapfile_unavailable";return false;
    }
    bool revalidate(std::string& error) { error="host_fixture_heapfile_unavailable";return false; }
    const std::string& path() const { static const std::string empty;return empty; }
    uint64_t requiredBytes() const { return 0; }
    uint64_t freeBytes() const { return 0; }
};
}

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
// 普通宿主 JVM 没有设备的游戏退出所有者。
bool amclPhoneExitArmed() { return false; }
void JNICALL phoneGameExitHook(jint) { std::abort(); }
long long amclLedgerGetLaunchActivity() { return 0; }
void JNICALL isolatedGameExitHook(jint) {}
std::string g_classpath, g_extraLibPath, g_status, g_mcStatus;
int g_xmxMb = 4096;
bool g_forkChildMode = false;
// 宿主bootstrap验证旧包默认；目标新包资格由实际marker和独立只读协议专项授予。
const auto nativeTempContract = amcl::jvm::NativeTempContract::Legacy;
// 本bootstrap套件继续验证未知旧包的保守默认；release/CF实际选择由独立源码消费者覆盖。
const bool addAutomaticCfExclusion = amcl::jvm::NeedsLegacyCfDefault({0, "bootstrap-fixture-unknown"});
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
            bool classicLayout, bool verifyOwnedPaths,int observedMajor) {
    const std::string nativeLibDir = javaHomeDir + "/bin";
    const std::string jdkDataDir = directory;
    const char* appFilesDir = directory.c_str();
    // 版本事实由父脚本实际java -version取得；这里只提供已有发布身份观察，不复制解析。
    const amcl::jvm::ReleaseMajorObservation releaseIdentity{observedMajor,"host-java-version"};
    const char* trustedAppFilesDir=appFilesDir;
    g_classpath = directory;
    if (verifyOwnedPaths) g_extraLibPath = directory + "/native";
    // 此片段包含生产的失败返回；必须在下面 LoadJvm 之前执行。
#include "jvm_bootstrap_heap_preflight.inc"
#include "jvm_bootstrap_options.inc"
    // 同一份生产装配正文持有所有 c_str()，同时验证实际指针内容与 JVM 读取到的属性。
    // 不靠补 NUL 或另拷贝参数修复夹具；旧 512 字节缓冲回归会在创建 JVM 前明确失败。
    const std::vector<amcl::jvm::BootstrapProperty> ownedProperties = {
        {"user.home", directory}, {"user.dir", directory}, {"java.io.tmpdir", directory},
        {"java.class.path", directory}, {"java.library.path", nativeLibDir + ":" + g_extraLibPath}
    };
    if (verifyOwnedPaths) {
        Require(directory.size() > 512, "owned path case did not cross old buffer boundary");
        auto exactOption = [&](const std::string& expected) {
            const auto prefix = expected.substr(0, expected.find('=') + 1);
            int count = 0;
            for (const auto& option : optVec) {
                if (option.optionString && std::string(option.optionString).rfind(prefix, 0) == 0) {
                    Require(option.optionString == expected, "production option was truncated or changed");
                    ++count;
                }
            }
            Require(count == 1, "production owned option missing or duplicated");
        };
        // 启动引导目录由各宿主 JVM 自己规范化/重算，只在 Invocation 输入侧核对其完整内容；
        // 下面的 Java 属性回读仅覆盖本用例实际超过 512 字节的五项路径。
        exactOption("-Djava.home=" + javaHomeDir);
        exactOption("-Dsun.boot.library.path=" + nativeLibDir);
        for (const auto& property : ownedProperties) exactOption("-D" + property.first + "=" + property.second);
        exactOption("-XX:ErrorFile=" + directory + "/hs_err_pid%p.log");
        std::cout << "OWNED_PATH_BYTES=" << directory.size() << " OWNED_OPTIONS=PASS" << std::endl;
    }
    for (const auto& option : optVec) {
        Require(std::string(option.optionString) != "exit", "unarmed host JVM received a game exit hook");
        std::cout << "PRODUCTION_OPTION=" << option.optionString << std::endl;
    }
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
    if (verifyOwnedPaths) {
        for (const auto& property : ownedProperties) {
            std::string actual;
            Require(getSystemProperty(env, property.first.c_str(), actual) && actual == property.second,
                    ("JVM did not retain complete property: " + property.first).c_str());
        }
        Require(!env->ExceptionCheck(), "owned property readback left Java exception");
        std::cout << "OWNED_PROPERTIES=PASS" << std::endl;
    }
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
    const int result = Options(jvm, javaHome, directory, classic, mode == "owned-options",std::atoi(argv[5]));
    std::cout << "HOST_RESULT=" << result << " STATUS=" << g_status << std::endl;
    // 预检返回码作为数据交父脚本核验，不与 HotSpot 直接终止进程混淆。
    return result == 0 || result == -11 ? 0 : result;
}

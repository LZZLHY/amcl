/**
 * 真实宿主 JNI_CreateJavaVM/exit callback 探针。
 * 不链接 AMCL 生产退出策略、不模拟 appspawn，不拦截系统 exit/abort。每次执行只创建
 * 一个 JVM。回调只能写预打开的测试标记，然后 std::_Exit；故意返回模式是独立负例。
 */
#include <jni.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <fcntl.h>

#ifdef _WIN32
#include <windows.h>
#include <io.h>
#include <sys/stat.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif

namespace {
int marker_fd = -1;
bool callback_returns = false;

/** 写入单条有界测试证据。写入不完整直接失败，不把丢失标记误当作钩子未调用。 */
void write_marker(const char* event, jint code) {
    char line[96];
    const int length = std::snprintf(line, sizeof(line), "%s code=%d\n", event, static_cast<int>(code));
    if (length <= 0 || static_cast<size_t>(length) >= sizeof(line)) std::_Exit(91);
#ifdef _WIN32
    const int written = _write(marker_fd, line, static_cast<unsigned int>(length));
    if (written != length || _commit(marker_fd) != 0) std::_Exit(91);
#else
    const ssize_t written = write(marker_fd, line, static_cast<size_t>(length));
    if (written != length || fsync(marker_fd) != 0) std::_Exit(91);
#endif
}

/** 标准 JNI exit hook 签名；原始 jint 不归零，不读取 JNI、不操作 UI、不等待其他线程。 */
void JNICALL invocation_exit(jint code) {
    write_marker("EXIT_HOOK", code);
    if (callback_returns) {
        write_marker("HOOK_RETURNS", code);
        return; // 负例：真实 JVM 必须继续其默认退出，不能回到 Java/native main。
    }
    std::_Exit(static_cast<int>(code));
}

using CreateJavaVM = jint (JNICALL *)(JavaVM**, void**, void*);

/** 只加载脚本指定 JDK 的真实 JVM，不让系统搜索路径误选另一份 libjvm。 */
CreateJavaVM load_vm(const char* filename) {
    CreateJavaVM entry = nullptr;
#ifdef _WIN32
    const HMODULE library = LoadLibraryExA(filename, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!library) {
        std::fprintf(stderr, "LoadLibraryEx failed: %lu\n", GetLastError());
        return nullptr;
    }
    const FARPROC address = GetProcAddress(library, "JNI_CreateJavaVM");
    static_assert(sizeof(address) == sizeof(entry), "host function pointer size mismatch");
    std::memcpy(&entry, &address, sizeof(entry));
#else
    void* library = dlopen(filename, RTLD_NOW | RTLD_GLOBAL);
    if (!library) {
        std::fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return nullptr;
    }
    void* address = dlsym(library, "JNI_CreateJavaVM");
    static_assert(sizeof(address) == sizeof(entry), "host function pointer size mismatch");
    std::memcpy(&entry, &address, sizeof(entry));
#endif
    return entry;
}

/** JNI 异常属于测试失败，不转为退出成功或吞掉异常后继续验收。 */
bool exception_pending(JNIEnv* env) {
    if (!env->ExceptionCheck()) return false;
    env->ExceptionDescribe();
    return true;
}
} // namespace

/**
 * 参数依次为 JVM 动态库、编译后 class 目录、Java 动作、hook 模式、native 标记、Java 标记。
 * 正常 main-return 场景显式 DestroyJavaVM，验证该 API 返回且未调用 exit hook。
 */
int main(int argc, char** argv) {
    if (argc != 7) return 90;
    if (std::strcmp(argv[4], "exit") != 0 && std::strcmp(argv[4], "return") != 0) return 90;
    callback_returns = std::strcmp(argv[4], "return") == 0;
#ifdef _WIN32
    marker_fd = _open(argv[5], _O_WRONLY | _O_CREAT | _O_EXCL | _O_BINARY, _S_IREAD | _S_IWRITE);
#else
    marker_fd = open(argv[5], O_WRONLY | O_CREAT | O_EXCL, 0600);
#endif
    if (marker_fd < 0) return 91;
    const CreateJavaVM create_vm = load_vm(argv[1]);
    if (!create_vm) return 92;
    std::string classpath = "-Djava.class.path=" + std::string(argv[2]);
    JavaVMOption options[2]{};
    options[0].optionString = const_cast<char*>(classpath.c_str());
    options[1].optionString = const_cast<char*>("exit");
    options[1].extraInfo = reinterpret_cast<void*>(&invocation_exit);
    JavaVMInitArgs arguments{};
    arguments.version = JNI_VERSION_1_8;
    arguments.nOptions = 2;
    arguments.options = options;
    arguments.ignoreUnrecognized = JNI_FALSE;
    JavaVM* vm = nullptr;
    JNIEnv* env = nullptr;
    const jint created = create_vm(&vm, reinterpret_cast<void**>(&env), &arguments);
    if (created != JNI_OK || !vm || !env) {
        std::fprintf(stderr, "JNI_CreateJavaVM returned %d\n", static_cast<int>(created));
        return 93;
    }
    const jclass fixture = env->FindClass("JniExitFixture");
    if (exception_pending(env) || !fixture) return 94;
    const jmethodID method = env->GetStaticMethodID(fixture, "main", "([Ljava/lang/String;)V");
    if (exception_pending(env) || !method) return 94;
    const jclass string_class = env->FindClass("java/lang/String");
    if (exception_pending(env) || !string_class) return 94;
    const jobjectArray java_args = env->NewObjectArray(2, string_class, nullptr);
    if (exception_pending(env) || !java_args) return 94;
    env->SetObjectArrayElement(java_args, 0, env->NewStringUTF(argv[3]));
    env->SetObjectArrayElement(java_args, 1, env->NewStringUTF(argv[6]));
    if (exception_pending(env)) return 94;
    env->CallStaticVoidMethod(fixture, method, java_args);
    if (exception_pending(env)) return 94;
    std::printf("MAIN_RETURNED\n");
    std::fflush(stdout);
    const jint destroyed = vm->DestroyJavaVM();
    std::printf("DESTROY_RETURNED code=%d\n", static_cast<int>(destroyed));
    std::fflush(stdout);
#ifdef _WIN32
    _close(marker_fd);
#else
    close(marker_fd);
#endif
    return destroyed == JNI_OK ? 0 : 95;
}

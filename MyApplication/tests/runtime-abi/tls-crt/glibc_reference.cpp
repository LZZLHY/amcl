/**
 * 同一 A/B 源码的 glibc 系统加载器参考程序，绝不调用 AMCL loader。
 * 每个模式在单独进程运行；late 模式若暴露系统不支持的析构期首次 TLS 登记，
 * 外层脚本保留实际信号/退出码，而不安装处理器掩盖问题或把它计成正确性 PASS。
 */
#include "fixture_api.h"
#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <pthread.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

namespace {
struct Context { const char* directory; bool late; };

// 回调驻留在主可执行文件，整个工作线程及其真实系统 TLS 析构队列期间均有效。
void event_sink(int event, int detail) {
    std::printf("{\"kind\":\"event\",\"event\":%d,\"detail\":%d}\n", event, detail);
    std::fflush(stdout);
}

[[noreturn]] void fail(const char* step) {
    const char* detail = dlerror();
    std::fprintf(stderr, "reference failure at %s: %s\n", step, detail ? detail : "no dlerror");
    std::fflush(stderr);
    _exit(2);
}

template<typename T> T symbol(void* handle, const char* name) {
    dlerror();
    auto result = reinterpret_cast<T>(dlsym(handle, name));
    if (!result || dlerror()) fail(name);
    return result;
}

void phase(const char* name) {
    std::printf("{\"kind\":\"phase\",\"name\":\"%s\"}\n", name);
    std::fflush(stdout);
}

void* worker(void* opaque) {
    const auto& context = *static_cast<Context*>(opaque);
    char path[4096];
    const int length = std::snprintf(path, sizeof(path), "%s/libamcl_sdk_tls_a.so", context.directory);
    if (length < 0 || static_cast<size_t>(length) >= sizeof(path)) fail("path");
    void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) fail("dlopen A");
    const auto configure = symbol<void (*)(AmclSdkTlsEventSink)>(handle, "amcl_sdk_tls_configure");
    const auto touch = symbol<int (*)(int)>(handle, "amcl_sdk_tls_touch");
    const auto late = symbol<void (*)(int)>(handle, "amcl_sdk_tls_enable_late");
    const auto exception = symbol<int (*)(int)>(handle, "amcl_sdk_tls_exception_roundtrip");
    const auto live = symbol<int (*)()>(handle, "amcl_sdk_tls_resource_live");
    const auto initial = symbol<int (*)()>(handle, "amcl_sdk_tls_initial_value");
    configure(event_sink);
    if (live() != 1 || initial() != 73 || exception(9041) != 9041) fail("live, relocated TLS initial or EH");
    if (context.late) late(1);
    else if (touch(1) != 38 || touch(2) != 39) fail("warm TLS");
    phase("before-close");
    // 关闭前一直持有 A 的真实公开 handle，B 的可调用性来自 A 的 DT_NEEDED。
    // close 返回后不再调用保存的函数指针，也不使用不存在的系统→自定义依赖推论。
    if (dlclose(handle) != 0) fail("dlclose A");
    phase("after-close");
    return nullptr;
}
}

int main(int argc, char** argv) {
    if (argc != 3 || (std::strcmp(argv[1], "warm") && std::strcmp(argv[1], "late"))) return 64;
    std::printf("{\"kind\":\"environment\",\"glibc\":\"%s\",\"mode\":\"%s\"}\n",
        gnu_get_libc_version(), argv[1]);
    std::fflush(stdout);
    Context context{argv[2], std::strcmp(argv[1], "late") == 0};
    pthread_t thread;
    if (pthread_create(&thread, nullptr, worker, &context) != 0) fail("pthread_create");
    if (pthread_join(thread, nullptr) != 0) fail("pthread_join");
    phase("after-join");
    // glibc 可能把已无 TLS 根的 DSO 留到下一次 dlclose 再回收。只获取仍已加载 B 的
    // 真实新 handle，再归还它以触发该路径；RTLD_NOLOAD 保证没有重新构造另一份 B。
    char path[4096];
    const int length = std::snprintf(path, sizeof(path), "%s/libamcl_sdk_tls_b.so", argv[2]);
    if (length < 0 || static_cast<size_t>(length) >= sizeof(path)) fail("drain path");
    if (void* remaining = dlopen(path, RTLD_NOLOAD | RTLD_NOW | RTLD_LOCAL)) {
        phase("retained-b-acquired");
        if (dlclose(remaining) != 0) fail("drain B");
    }
    phase("finished");
    return 0;
}

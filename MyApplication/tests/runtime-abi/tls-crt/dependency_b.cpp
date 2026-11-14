/** B拥有真实静态Resource与两份非平凡TLS；静态资源先死时只记录违例，不实际解引用死对象。 */
#include "fixture_api.h"

namespace {
AmclSdkTlsEventSink events = nullptr;
int resourceLive = 0;
// 指针需要在.tdata完成R_AARCH64_RELATIVE后才能复制到新线程模板。两层volatile
// 禁止优化器把TLS读取/指针比较/目标读取折叠成常量，确保每次核验都经过实际TLS块。
volatile int relocatedInitialValue = 73;
thread_local volatile int* volatile relocatedPointer = &relocatedInitialValue;
void emit(int event, int detail) { if (events) events(event, detail); }
struct Resource {
    Resource() { resourceLive = 1; }
    ~Resource() { resourceLive = 0; emit(AMCL_SDK_B_STATIC_DESTROYED, 0); }
    __attribute__((noinline)) int read() const { return 37; }
} resource;
struct ThreadValue {
    int which;
    explicit ThreadValue(int value) : which(value) { emit(AMCL_SDK_B_TLS_CREATED, which); }
    ~ThreadValue() {
        // resourceLive是独立标志。错误实现中避免对已经析构的Resource调用方法，
        // 让负对照稳定给出事件，而不是借未定义行为/随机崩溃“证明”顺序错误。
        if (!resourceLive) emit(AMCL_SDK_B_STATIC_DEAD_DURING_TLS, which);
        else if (resource.read() != 37) emit(AMCL_SDK_B_STATIC_DEAD_DURING_TLS, -which);
        emit(AMCL_SDK_B_TLS_DESTROYED, which);
    }
};
struct ExceptionScope { ~ExceptionScope() { emit(AMCL_SDK_EH_B_CLEANUP, 0); } };
}

extern "C" void amcl_sdk_tls_b_configure(AmclSdkTlsEventSink sink) { events = sink; }
extern "C" int amcl_sdk_tls_b_touch(int which) {
    // 必须是两个独立块级TLS，不能用同一TU的命名空间TLS：后者允许在第一次触碰时
    // 一起初始化，会把“系统/custom交错”测试错误地变成同一批注册。
    if (which == 1) { static thread_local ThreadValue first(1); return 37 + first.which; }
    if (which == 2) { static thread_local ThreadValue second(2); return 37 + second.which; }
    return -1;
}
extern "C" __attribute__((noinline)) void amcl_sdk_tls_b_throw(int token) {
    ExceptionScope scope;
    throw AmclSdkTlsException{token};
}
extern "C" int amcl_sdk_tls_b_resource_live() { return resourceLive; }
extern "C" int amcl_sdk_tls_b_initial_value() {
    volatile int* actual = relocatedPointer;
    // 先核实完整地址再解引用；旧模板若复制了未重定位地址，稳定返回-1而非随机崩溃。
    if (actual != &relocatedInitialValue) return -1;
    return *actual;
}

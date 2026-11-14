/** 编译器生成真实 __cxa_thread_atexit 和本模块 TLSDESC；包含 fini 中首次 TLS 构造。 */
extern "C" void test_mark(int);
extern "C" { __attribute__((visibility("hidden"))) void* __dso_handle = &__dso_handle; }
namespace {
struct Value {
    int number = 37;
    ~Value() { test_mark(number == 37 ? 100 : 1000000); }
};
thread_local Value value;
bool late = false;
}
extern "C" __attribute__((visibility("default"))) int touch_thread_tls() { return value.number; }
extern "C" __attribute__((visibility("default"))) void enable_late_tls() { late = true; }
__attribute__((constructor)) static void initialized() { test_mark(1); }
__attribute__((destructor)) static void finalized() {
    test_mark(10);
    if (late) touch_thread_tls();
}

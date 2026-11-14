/** 真正经生产 ELF mapper 装载的 C++ 栈帧；异常回穿时必须执行本库的清理代码。 */
extern "C" void unwind_mark(int);
extern "C" void unwind_initialized(void);
__attribute__((constructor)) static void initialize_fixture() { unwind_initialized(); }
namespace {
struct Scope {
    ~Scope() { unwind_mark(1); }
};
}
extern "C" __attribute__((visibility("default"), noinline))
void frame_call(void (*callback)()) {
    Scope scope;
    callback();
}

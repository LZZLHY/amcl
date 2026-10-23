// 编译真实napi_log.cpp，只替换宿主不可用的NAPI SDK边界及其原生调用端口。
// 本探针验证“JS线程只排队、worker才关闭、失败不兑现成功和work成对释放”；
// writer的真实关闭/超时/原件行为由native_log_durability_test独立编译生产writer验证。
#define NAPI_EXTERN extern
#ifdef _MSC_VER
// 只在宿主SDK替身移除Clang的OHOS availability注解，不改变任何ABI参数或返回类型。
#define __attribute__(attributes)
#endif
#include "../../napi/napi_log.cpp"
#include <cstdlib>
#include <map>
#include <thread>
#include <vector>
#include <stdexcept>
#include <cstdio>

// 每个验收表达式都执行且只求值一次；发布优化配置也必须保留其副作用与失败判据。
// 失败从任意测试线程统一退出2并打印原表达式，不能依赖会被预处理裁掉的标准断言。
#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr, "LEDGER ASYNC CHECK FAIL line %d: %s\n", __LINE__, #condition); \
    std::exit(2); } } while (false)

struct napi_value__ { double number = 0; int state = 0; };
struct napi_deferred__ { napi_value value = nullptr; };
struct napi_callback_info__ { napi_value value = nullptr; };
struct napi_env__ {};
struct napi_async_work__ {
    napi_async_execute_callback execute;
    napi_async_complete_callback complete;
    void* data;
};

namespace {
napi_env__ environment;
napi_value__ undefinedValue;
std::vector<std::unique_ptr<napi_value__>> values;
std::vector<std::unique_ptr<napi_deferred__>> deferreds;
std::map<std::string, napi_callback> methods;
napi_async_work queued = nullptr;
std::thread::id ownerThread;
int created = 0, deleted = 0, nativeCalls = 0, errors = 0;
bool queueFailure = false, createFailure = false, closeSuccess = true, closeThrows = false;
int stringFailures = 0, errorFailures = 0, undefinedFailures = 0;
bool failureLeavesException = false;
napi_value pendingException = nullptr;

// SDK对象由模拟环境持有，避免测试自身的value/deferred分配混入产品native数据生命周期。
napi_value value(double number = 0) {
    auto item = std::make_unique<napi_value__>(); item->number = number;
    napi_value result = item.get(); values.push_back(std::move(item)); return result;
}
void onOwner() { CHECK(std::this_thread::get_id() == ownerThread); }
/** 用数值主键构造宿主callback参数并调用实际注册的生产入口；返回SDK替身持有的Promise值。 */
napi_value request(double id) {
    napi_callback_info__ information{value(id)};
    return methods.at("amclLedgerEndAsync")(&environment, &information);
}
/**
 * status指定complete的SDK状态，execute=false模拟未执行的取消；消费本次queued工作一次。
 * execute=true时实际创建并join宿主线程调用生产execute，再在owner线程执行生产complete。
 * 完成后检查work创建/删除平衡；工作/native数据由生产桥释放，JS值与deferred由测试环境容器管理。
 */
void finish(napi_status status = napi_ok, bool execute = true) {
    CHECK(queued != nullptr); napi_async_work work = queued; queued = nullptr;
    if (execute) { std::thread thread([work] { work->execute(nullptr, work->data); }); thread.join(); }
    work->complete(&environment, status, work->data);
    CHECK(created == deleted);
}
}

// 下列实现只模拟SDK生命周期、线程与失败返回，不重新实现活动关闭或文件业务。
extern "C" napi_status napi_get_cb_info(napi_env, napi_callback_info info, size_t* argc,
    napi_value* args, napi_value*, void**) { onOwner(); *argc = 1; args[0] = info->value; return napi_ok; }
extern "C" napi_status napi_get_value_double(napi_env, napi_value input, double* out) { onOwner(); *out = input->number; return napi_ok; }
extern "C" napi_status napi_get_value_int32(napi_env, napi_value, int32_t* out) { *out = 0; return napi_ok; }
extern "C" napi_status napi_get_value_string_utf8(napi_env, napi_value, char*, size_t, size_t* out) { *out = 0; return napi_ok; }
extern "C" napi_status napi_get_boolean(napi_env, bool input, napi_value* out) { *out = value(input ? 1 : 0); return napi_ok; }
extern "C" napi_status napi_get_undefined(napi_env, napi_value* out) {
    onOwner(); // 实际SDK的get_undefined不检查lastException，settlement入口才检查。
    if (undefinedFailures > 0) { undefinedFailures--; return napi_generic_failure; }
    *out = &undefinedValue; return napi_ok;
}
extern "C" napi_status napi_get_null(napi_env, napi_value* out) { onOwner(); *out = value(); return napi_ok; }
extern "C" napi_status napi_is_exception_pending(napi_env, bool* out) { onOwner(); *out = pendingException != nullptr; return napi_ok; }
extern "C" napi_status napi_get_and_clear_last_exception(napi_env, napi_value* out) { onOwner(); *out = pendingException; pendingException = nullptr; return napi_ok; }
extern "C" napi_status napi_create_string_utf8(napi_env, const char*, size_t, napi_value* out) {
    onOwner(); if (pendingException) return napi_pending_exception;
    if (stringFailures > 0) { stringFailures--; if (failureLeavesException) pendingException = value(); return napi_generic_failure; }
    *out = value(); return napi_ok;
}
extern "C" napi_status napi_create_error(napi_env, napi_value, napi_value, napi_value* out) {
    onOwner(); if (pendingException) return napi_pending_exception;
    if (errorFailures > 0) { errorFailures--; if (failureLeavesException) pendingException = value(); return napi_generic_failure; }
    *out = value(); return napi_ok;
}
extern "C" napi_status napi_throw_type_error(napi_env, const char*, const char*) { onOwner(); errors++; return napi_ok; }
extern "C" napi_status napi_throw_error(napi_env, const char*, const char*) { onOwner(); errors++; return napi_ok; }
extern "C" napi_status napi_create_promise(napi_env, napi_deferred* out, napi_value* promise) {
    onOwner(); *promise = value(); auto item = std::make_unique<napi_deferred__>(); item->value = *promise;
    *out = item.get(); deferreds.push_back(std::move(item)); return napi_ok;
}
extern "C" napi_status napi_resolve_deferred(napi_env, napi_deferred deferred, napi_value) {
    onOwner(); if (pendingException) return napi_pending_exception;
    CHECK(deferred->value->state == 0); deferred->value->state = 1; return napi_ok;
}
extern "C" napi_status napi_reject_deferred(napi_env, napi_deferred deferred, napi_value) {
    onOwner(); if (pendingException) return napi_pending_exception;
    CHECK(deferred->value->state == 0); deferred->value->state = 2; return napi_ok;
}
extern "C" napi_status napi_create_async_work(napi_env, napi_value, napi_value, napi_async_execute_callback execute,
    napi_async_complete_callback complete, void* data, napi_async_work* out) {
    onOwner(); if (createFailure) return napi_generic_failure;
    *out = new napi_async_work__{execute, complete, data}; created++; return napi_ok;
}
extern "C" napi_status napi_queue_async_work(napi_env, napi_async_work work) {
    onOwner(); if (queueFailure) return napi_generic_failure;
    CHECK(queued == nullptr); queued = work; return napi_ok;
}
extern "C" napi_status napi_delete_async_work(napi_env, napi_async_work work) { onOwner(); deleted++; delete work; return napi_ok; }
extern "C" napi_status napi_define_properties(napi_env, napi_value, size_t count, const napi_property_descriptor* descriptors) {
    for (size_t index = 0; index < count; ++index) methods[descriptors[index].utf8name] = descriptors[index].method;
    return napi_ok;
}

// 日志模块其他注册函数未被本测试派发；保留端口定义以链接整个真实注册表。
extern "C" void amclLogInit(const char*, int, int) {}
extern "C" void amclLogShutdown() {}
extern "C" const char* amclLogRead(int) { return ""; }
extern "C" int amclLogFlushChecked() { return 1; }
extern "C" const char* amclLogGetStatus() { return "{}"; }
extern "C" const char* amclLogGetPath() { return ""; }
extern "C" void amclLogWriteFor(long long, AmclLogLevel, const char*, const char*, ...) {}
extern "C" int amclLedgerBegin(long long, const char*) { return 1; }
extern "C" void amclLedgerEnd(long long) { CHECK(false && "async bridge must never use unchecked legacy close"); }
extern "C" void amclLedgerEndAll() {}
extern "C" void amclLedgerUnbindTask(unsigned long long) {}
extern "C" void amclLedgerSetLaunchActivity(long long) {}
extern "C" void amclLedgerBindTask(unsigned long long, long long) {}
extern "C" int amclLedgerEndChecked(long long id) {
    CHECK(std::this_thread::get_id() != ownerThread); CHECK(id == 1789050000000LL); nativeCalls++;
    if (closeThrows) throw std::runtime_error("controlled native port failure");
    return closeSuccess ? 1 : 0;
}
namespace amcl::napi {
napi_value MakeUndefined(napi_env) { return &undefinedValue; }
napi_value WrapStringResult(napi_env, const char*) { return value(); }
}

int main() {
    ownerThread = std::this_thread::get_id();
    amcl::napi::registerLogNapi(&environment, nullptr);
    const double id = 1789050000000.0;
    // 返回pending promise时native尚未调用；唯一worker执行后才兑现成功。
    napi_value success = request(id); CHECK(success && success->state == 0 && nativeCalls == 0);
    finish(); CHECK(success->state == 1 && nativeCalls == 1);
    // timeout/仍未关闭、取消和C++异常均拒绝，不能把未确认关闭当成成功。
    closeSuccess = false; napi_value timeout = request(id); finish(); CHECK(timeout->state == 2);
    closeSuccess = true; napi_value cancel = request(id); finish(napi_cancelled, false); CHECK(cancel->state == 2);
    closeThrows = true; napi_value exception = request(id); finish(); CHECK(exception->state == 2); closeThrows = false;
    // create/queue失败立即拒绝且没有native工作，不遗留已创建的SDK句柄。
    const int previousCalls = nativeCalls;
    queueFailure = true; napi_value queueError = request(id); CHECK(queueError->state == 2 && created == deleted); queueFailure = false;
    createFailure = true; napi_value createError = request(id); CHECK(createError->state == 2 && created == deleted); createFailure = false;
    CHECK(nativeCalls == previousCalls);
    // 真实SDK会在pending exception时拒绝进入reject；桥必须清理并提交原异常值。
    failureLeavesException = true; stringFailures = 1;
    napi_value resourceError = request(id); CHECK(resourceError->state == 2 && pendingException == nullptr);
    closeSuccess = false; errorFailures = 1;
    napi_value constructorError = request(id); finish(); CHECK(constructorError->state == 2 && pendingException == nullptr);
    failureLeavesException = false; errorFailures = 1; undefinedFailures = 1;
    napi_value fallbackError = request(id); finish(); CHECK(fallbackError->state == 2);
    closeSuccess = true; undefinedFailures = 1;
    napi_value resultError = request(id); finish(); CHECK(resultError->state == 2);
    napi_value pendingAtComplete = request(id); pendingException = value(); finish();
    CHECK(pendingAtComplete->state == 2 && pendingException == nullptr);
    stringFailures = 1; napi_value resourceWithoutPending = request(id); CHECK(resourceWithoutPending->state == 2);
    CHECK(request(0) == nullptr && request(1.5) == nullptr && request(9007199254740992.0) == nullptr);
    CHECK(errors == 3 && queued == nullptr && created == deleted);
    std::printf("PASS production NAPI ledger close: worker boundary, timeout, cancel, exception, queue/create failure, invalid identity; work=%d/%d\n", created, deleted);
}

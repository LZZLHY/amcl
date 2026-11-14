/**
 * 编译并直接调用生产 napi_forge.cpp + napi_helpers.cpp。外部 NAPI/进程接口以替身
 * 注入失败，核对动态长输入逐字节传递、取消不得成功、Promise/work/ref 所有权配对。
 * 本测试不启动假 JVM，不把 fork 替身结果当作设备 processor 能力。
 */
#include "napi/napi_forge.h"
#include "jvm/fork_run_java.h"
#include <cassert>
#include <cstring>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

struct napi_value__ { int type = 0; int32_t number = 0; double real = 0; std::string text; std::vector<napi_value> array; };
struct napi_deferred__ {};
struct napi_ref__ { napi_value value; };
struct napi_async_work__ { napi_async_execute_callback execute; napi_async_complete_callback complete; void* data; };
namespace {
napi_callback run = nullptr;
napi_callback cancel = nullptr;
napi_env env = reinterpret_cast<napi_env>(1);
std::vector<std::unique_ptr<napi_value__>> values;
std::vector<napi_value> input;
napi_async_work queued = nullptr;
int operations = 0, failAt = 0, refs = 0, works = 0, deferreds = 0, resolves = 0, rejects = 0, forks = 0;
int32_t lastResult = -100, childResult = 0;
bool pending = false, throwNative = false, failCompletionNumber = false;
napi_value exceptionValue = nullptr;
std::string expectedClasspath, expectedLongArgument;
napi_status step() { return ++operations == failAt ? napi_generic_failure : napi_ok; }
napi_value value(int type = 0, const std::string& text = {}) {
    values.emplace_back(new napi_value__); auto* item = values.back().get(); item->type = type; item->text = text; return item;
}
void prepare() {
    assert(!refs && !works && !deferreds && !queued);
    values.clear(); input.clear(); pending = false; exceptionValue = nullptr;
    operations = 0; failAt = 0; resolves = rejects = forks = 0; childResult = 0; throwNative = failCompletionNumber = false;
    expectedClasspath = "/with spaces/中文/" + std::string(24000, 'c') + ".jar";
    expectedLongArgument = "中文-" + std::string(20000, 'a');
    input = {value(1, "/application/files"), value(1, "8"), value(2), value(1, expectedClasspath),
        value(1, "ExampleMain"), value(3), value(1, "/with spaces/工作目录"), value(1, "/log/file")};
    input[2]->number = 1536; input[5]->array = {value(1, expectedLongArgument), value(1, "emoji-😀")};
}
void complete(napi_status status = napi_ok) {
    assert(queued); auto* work = queued; queued = nullptr;
    if (status == napi_ok) work->execute(nullptr, work->data);
    work->complete(env, status, work->data);
    assert(!refs && !works && !deferreds);
}
}
extern "C" {
int forkRunJavaCwd(const char* files, const char* major, const char* classpath, const char* mainClass,
    int argc, const char** argv, const char* cwd, const char* log, int memory) {
    ++forks;
    assert(std::string(files) == "/application/files" && std::string(major) == "8");
    assert(std::string(classpath) == expectedClasspath && std::string(mainClass) == "ExampleMain");
    assert(argc == 2 && std::string(argv[0]) == expectedLongArgument && std::string(argv[1]) == "emoji-😀");
    assert(std::string(cwd) == "/with spaces/工作目录" && std::string(log) == "/log/file" && memory == 1536);
    if (throwNative) throw std::bad_alloc();
    return childResult;
}
napi_status napi_define_properties(napi_env, napi_value, size_t count, const napi_property_descriptor* properties) {
    assert(count == 2 && !std::strcmp(properties[0].utf8name, "runJavaProcessor") &&
        !std::strcmp(properties[1].utf8name, "cancelJavaProcessor"));
    run = properties[0].method; cancel = properties[1].method; return napi_ok;
}
napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t* count, napi_value* args, napi_value*, void**) {
    if (step() != napi_ok) return napi_generic_failure;
    const size_t capacity = *count; *count = input.size();
    for (size_t i = 0; i < input.size() && i < capacity; ++i) args[i] = input[i]; return napi_ok;
}
napi_status napi_get_value_string_utf8(napi_env, napi_value item, char* buffer, size_t capacity, size_t* length) {
    if (step() != napi_ok) return napi_generic_failure;
    if (!item || item->type != 1) return napi_string_expected;
    *length = buffer ? std::min(capacity - 1, item->text.size()) : item->text.size();
    if (buffer) { std::memcpy(buffer, item->text.data(), *length); buffer[*length] = 0; } return napi_ok;
}
napi_status napi_get_value_int32(napi_env, napi_value item, int32_t* number) {
    if (step() != napi_ok) return napi_generic_failure;
    if (item->type != 2) return napi_number_expected;
    *number = item->number; return napi_ok;
}
napi_status napi_get_value_double(napi_env, napi_value item, double* number) {
    if (step() != napi_ok) return napi_generic_failure;
    if (item->type != 2) return napi_number_expected; *number = item->real; return napi_ok;
}
napi_status napi_typeof(napi_env, napi_value item, napi_valuetype* type) {
    if (step() != napi_ok) return napi_generic_failure;
    *type = item->type == 0 ? napi_undefined : item->type == 1 ? napi_string : item->type == 2 ? napi_number : napi_object;
    return napi_ok;
}
napi_status napi_is_array(napi_env, napi_value item, bool* result) {
    if (step() != napi_ok) return napi_generic_failure; *result = item->type == 3; return napi_ok;
}
napi_status napi_get_array_length(napi_env, napi_value item, uint32_t* length) {
    if (step() != napi_ok) return napi_generic_failure; *length = item->array.size(); return napi_ok;
}
napi_status napi_get_element(napi_env, napi_value item, uint32_t index, napi_value* output) {
    if (step() != napi_ok) return napi_generic_failure; *output = item->array.at(index); return napi_ok;
}
napi_status napi_create_string_utf8(napi_env, const char* text, size_t length, napi_value* output) {
    if (step() != napi_ok) return napi_generic_failure;
    *output = value(1, std::string(text, length == NAPI_AUTO_LENGTH ? std::strlen(text) : length)); return napi_ok;
}
napi_status napi_create_error(napi_env, napi_value, napi_value message, napi_value* output) {
    if (step() != napi_ok) return napi_generic_failure; *output = value(4, message->text); return napi_ok;
}
napi_status napi_create_reference(napi_env, napi_value item, uint32_t, napi_ref* output) {
    if (step() != napi_ok) return napi_generic_failure; *output = new napi_ref__{item}; ++refs; return napi_ok;
}
napi_status napi_get_reference_value(napi_env, napi_ref reference, napi_value* output) { *output = reference->value; return napi_ok; }
napi_status napi_delete_reference(napi_env, napi_ref reference) { delete reference; --refs; return napi_ok; }
napi_status napi_create_async_work(napi_env, napi_value, napi_value, napi_async_execute_callback execute,
    napi_async_complete_callback completion, void* data, napi_async_work* output) {
    if (step() != napi_ok) return napi_generic_failure;
    *output = new napi_async_work__{execute, completion, data}; ++works; return napi_ok;
}
napi_status napi_create_promise(napi_env, napi_deferred* deferred, napi_value* output) {
    if (step() != napi_ok) return napi_generic_failure; *deferred = new napi_deferred__; ++deferreds; *output = value(5); return napi_ok;
}
napi_status napi_queue_async_work(napi_env, napi_async_work work) {
    if (step() != napi_ok) return napi_generic_failure; queued = work; return napi_ok;
}
napi_status napi_delete_async_work(napi_env, napi_async_work work) { delete work; --works; return napi_ok; }
napi_status napi_create_int32(napi_env, int32_t number, napi_value* output) {
    if (failCompletionNumber) return napi_generic_failure; *output = value(2); (*output)->number = number; return napi_ok;
}
napi_status napi_resolve_deferred(napi_env, napi_deferred deferred, napi_value result) {
    ++resolves; lastResult = result->number; delete deferred; --deferreds; return napi_ok;
}
napi_status napi_reject_deferred(napi_env, napi_deferred deferred, napi_value reason) {
    assert(reason); ++rejects; delete deferred; --deferreds; return napi_ok;
}
napi_status napi_throw_error(napi_env, const char*, const char*) { pending = true; exceptionValue = value(4); return napi_ok; }
napi_status napi_throw_type_error(napi_env e, const char* code, const char* text) { return napi_throw_error(e, code, text); }
napi_status napi_is_exception_pending(napi_env, bool* result) { *result = pending; return napi_ok; }
napi_status napi_get_and_clear_last_exception(napi_env, napi_value* result) { *result = exceptionValue; pending = false; return napi_ok; }
napi_status napi_get_undefined(napi_env, napi_value* output) { *output = value(); return napi_ok; }
napi_status napi_get_boolean(napi_env, bool result, napi_value* output) { *output = value(2); (*output)->number = result; return napi_ok; }
}
int amcl::jvm::RunControlledProcessor(const char* files, const char* major, const char* classpath,
    const char* mainClass, int argc, const char** argv, const char* cwd, const char* log, int memory,
    ProcessorControl& control) {
    if (control.stopping()) return control.finish(-1);
    return control.finish(forkRunJavaCwd(files, major, classpath, mainClass, argc, argv, cwd, log, memory));
}
int main() {
    amcl::napi::registerForgeNapi(env, nullptr); assert(run);
    prepare(); assert(run(env, nullptr)); const int prepareOperations = operations;
    complete(); assert(resolves == 1 && !rejects && forks == 1 && lastResult == 0);
    for (int failure = 1; failure <= prepareOperations; ++failure) {
        prepare(); failAt = failure; run(env, nullptr);
        assert(!queued && !refs && !works && !deferreds && !forks);
        assert(pending || rejects == 1);
    }
    for (int mode = 0; mode < 4; ++mode) {
        prepare(); if (mode == 1) childResult = 7;
        if (mode == 2) throwNative = true;
        if (mode == 3) failCompletionNumber = true;
        assert(run(env, nullptr)); complete(mode == 0 ? napi_cancelled : napi_ok);
        assert(mode == 1 ? resolves == 1 && !rejects && lastResult == 7 : !resolves && rejects == 1);
        assert(forks == (mode == 0 ? 0 : 1));
    }
    for (int field : {0, 1, 3, 4, 6, 7}) {
        prepare(); input[field]->text += std::string("\0hidden", 7); run(env, nullptr); assert(pending && !queued && !works && !refs);
    }
    prepare(); input[5]->array[1]->type = 2; run(env, nullptr); assert(pending && !queued);
    prepare(); input[5]->array[1]->text += std::string("\0hidden", 7); run(env, nullptr); assert(pending && !queued);
    prepare(); input.pop_back(); run(env, nullptr); assert(pending && !queued);
    // 公共控制 API 的排队窗口：第一次取消被接受，重复/完成后的同名取消不再成功。
    prepare(); input.push_back(value(1, "request-A")); input.push_back(value(2)); input[9]->real = 10000;
    assert(run(env, nullptr)); input = {value(1, "request-A")};
    assert(cancel(env, nullptr)->number == 1 && cancel(env, nullptr)->number == 0);
    complete(); assert(!forks && resolves == 1 && lastResult == amcl::jvm::ProcessorCancelled);
    assert(cancel(env, nullptr)->number == 0);
    // 重复ID拒绝不能删除仍运行任务的记录；原请求依然可以取消并正常完成资源清理。
    prepare(); input.push_back(value(1, "request-B")); assert(run(env, nullptr));
    napi_async_work original = queued; queued = nullptr;
    run(env, nullptr); assert(pending && !queued && refs == 1 && works == 1 && deferreds == 1);
    pending = false; input = {value(1, "request-B")}; assert(cancel(env, nullptr)->number == 1);
    queued = original; complete(); assert(!forks && rejects == 0 && lastResult == amcl::jvm::ProcessorCancelled);
    prepare(); input.push_back(value()); input.push_back(value(2)); input[9]->real = -1;
    run(env, nullptr); assert(pending && !queued && !works && !refs);
    std::printf("PASS processor NAPI: %d prepare failures, full 24KB classpath/20KB argument, cancellation/native/completion failures, NUL/type rejection and balanced ownership\n", prepareOperations);
}

/**
 * 执行真实napi_game_dialog.cpp，只有SDK分配边界替身注入失败。验证已从broker取走的
 * 请求在每个NAPI复制步骤失败时都能唤醒Java调用者，且不覆盖原pending exception。
 */
#include "napi_game_dialog.h"
#include "napi_helpers.h"
#include "game_dialog.h"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <future>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

struct napi_value__ { std::string text; double number = 0; bool boolean = false; };
struct napi_callback_info__ { std::vector<napi_value> args; };
static std::vector<std::unique_ptr<napi_value__>> arena;
static std::map<std::string, napi_callback> callbacks;
static int step = 0, failureAt = 0, thrown = 0;
static bool pendingException = false, injectPending = false;
static napi_value Value() { arena.push_back(std::make_unique<napi_value__>()); return arena.back().get(); }
static napi_status Allocation() {
    if (++step != failureAt) return napi_ok;
    pendingException = injectPending;
    return injectPending ? napi_pending_exception : napi_generic_failure;
}
extern "C" {
napi_status napi_get_cb_info(napi_env, napi_callback_info info, size_t* count, napi_value* args, napi_value*, void**) {
    const auto length = info->args.size();
    for (size_t i = 0; i < length && i < *count; ++i) args[i] = info->args[i];
    *count = length; return napi_ok;
}
napi_status napi_get_value_double(napi_env, napi_value value, double* out) { *out = value->number; return napi_ok; }
napi_status napi_get_value_bool(napi_env, napi_value value, bool* out) { *out = value->boolean; return napi_ok; }
napi_status napi_get_value_string_utf8(napi_env, napi_value value, char* out, size_t size, size_t* length) {
    *length = value->text.size();
    if (out && size) { const auto count = std::min(size - 1, *length); std::memcpy(out, value->text.data(), count); out[count] = 0; *length = count; }
    return napi_ok;
}
napi_status napi_get_boolean(napi_env, bool value, napi_value* out) {
    const auto s = Allocation(); if (s == napi_ok) { *out = Value(); (*out)->boolean = value; } return s;
}
napi_status napi_create_object(napi_env, napi_value* out) { const auto s = Allocation(); if (s == napi_ok) *out = Value(); return s; }
napi_status napi_create_string_utf8(napi_env, const char* text, size_t, napi_value* out) {
    const auto s = Allocation(); if (s == napi_ok) { *out = Value(); (*out)->text = text; } return s;
}
napi_status napi_create_int32(napi_env, int32_t number, napi_value* out) {
    const auto s = Allocation(); if (s == napi_ok) { *out = Value(); (*out)->number = number; } return s;
}
napi_status napi_set_named_property(napi_env, napi_value, const char*, napi_value) { return Allocation(); }
napi_status napi_is_exception_pending(napi_env, bool* out) { *out = pendingException; return napi_ok; }
napi_status napi_throw_error(napi_env, const char*, const char*) { pendingException = true; ++thrown; return napi_ok; }
napi_status napi_define_properties(napi_env, napi_value, size_t count, const napi_property_descriptor* items) {
    for (size_t i = 0; i < count; ++i) callbacks[items[i].utf8name] = items[i].method;
    return napi_ok;
}
}
namespace amcl::napi {
bool ReadStringValue(napi_env, napi_value value, std::string& out) { out = value->text; return true; }
napi_value MakeUndefined(napi_env) { return nullptr; }
napi_value MakeBoolResult(napi_env, bool value) { const auto out = Value(); out->boolean = value; return out; }
napi_value WrapStringResult(napi_env, const char* value) { const auto out = Value(); out->text = value; return out; }
}

int main() {
    amcl::napi::registerGameDialogNapi(nullptr, nullptr);
    const auto session = Value(); session->number = 1234;
    napi_callback_info__ attachInfo{{session}};
    const auto generation = callbacks.at("gameDialogAttach")(nullptr, &attachInfo);
    assert(generation && !generation->text.empty());
    const uint64_t id = std::stoull(generation->text);
    napi_callback_info__ takeInfo{{generation}};
    for (int exception = 0; exception <= 1; ++exception) {
        for (int fail = 1; fail <= 13; ++fail) {
            step = 0; failureAt = fail; thrown = 0; pendingException = false; injectPending = exception != 0;
            auto worker = std::async(std::launch::async, [] { return AmclGameDialogMessageV1("test", "body", 2, 1); });
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
            while (!step) {
                assert(std::chrono::steady_clock::now() < deadline);
                assert(callbacks.at("gameDialogTake")(nullptr, &takeInfo) == nullptr);
                std::this_thread::yield();
            }
            assert(step == fail && pendingException && thrown == (exception ? 0 : 1));
            assert(worker.wait_for(std::chrono::seconds(3)) == std::future_status::ready && worker.get() == 0);
            // 原失败请求必须已经离开队首，后来的真实请求仍可被同一UI线程消费。
            assert(AmclGameDialogNotifyV1("after-failure", "") == 1);
            AmclGameDialogRequestV1 next{}; next.size = sizeof(next);
            assert(AmclGameDialogTakeV1(id, &next) == 1 && AmclGameDialogReplyV1(id, next.requestId, 0));
        }
    }
    failureAt = 0;
    assert(callbacks.at("gameDialogDetach")(nullptr, &takeInfo)->boolean);
    assert(callbacks.at("gameDialogDetach")(nullptr, &takeInfo)->boolean);
    // Attach副作用后的字符串分配失败必须回滚，JS没有收到的租约不能永久占用窗口。
    for (int exception = 0; exception <= 1; ++exception) {
        step = 0; failureAt = 1; pendingException = false; injectPending = exception != 0;
        assert(callbacks.at("gameDialogAttach")(nullptr, &attachInfo) == nullptr);
        assert(!AmclGameDialogAvailableV1());
    }
    failureAt = 0; pendingException = false;
    const auto laterGeneration = callbacks.at("gameDialogAttach")(nullptr, &attachInfo);
    const auto laterId = std::stoull(laterGeneration->text);
    napi_callback_info__ laterInfo{{laterGeneration}};
    for (int exception = 0; exception <= 1; ++exception) {
        for (int fail = 1; fail <= 2; ++fail) {
            // Reply返回值必须在改变队列前分配，失败后原请求仍等待且可以原结果重试。
            auto worker = std::async(std::launch::async, [] { return AmclGameDialogMessageV1("reply-failure", "", 2, 1); });
            AmclGameDialogRequestV1 request{}; request.size = sizeof(request);
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
            while (AmclGameDialogTakeV1(laterId, &request) == 0) assert(std::chrono::steady_clock::now() < deadline);
            const auto requestId = Value(); requestId->text = std::to_string(request.requestId);
            const auto result = Value(); result->number = 1;
            const auto user = Value(); user->boolean = true;
            napi_callback_info__ replyInfo{{laterGeneration, requestId, result, user}};
            step = 0; failureAt = fail; pendingException = false; injectPending = exception != 0;
            assert(callbacks.at("gameDialogReply")(nullptr, &replyInfo) == nullptr);
            assert(worker.wait_for(std::chrono::milliseconds(10)) == std::future_status::timeout);
            failureAt = 0; pendingException = false;
            assert(callbacks.at("gameDialogReply")(nullptr, &replyInfo)->boolean && worker.get() == 1);
            // Detach分配失败同样没有退休副作用，调用方持有原租约可再次收口。
            step = 0; failureAt = fail; pendingException = false;
            assert(callbacks.at("gameDialogDetach")(nullptr, &laterInfo) == nullptr);
            assert(AmclGameDialogAvailableV1());
        }
    }
    failureAt = 0; pendingException = false;
    assert(callbacks.at("gameDialogDetach")(nullptr, &laterInfo)->boolean);
    std::puts("PASS: 26 actual NAPI allocation/pending-exception failure paths cancel the original request");
    std::puts("PASS: 10 actual Attach/Reply/Detach return-allocation failures preserve atomic ownership");
}

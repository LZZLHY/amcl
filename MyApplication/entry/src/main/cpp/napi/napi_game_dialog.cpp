/**
 * 只把版本化broker请求复制到ArkTS；不传指针、不执行模组文本，也不自动选择按钮。
 * 窗口代次及请求号以十进制字符串往返，避免JavaScript浮点数损坏uint64身份。
 */
#include "napi_game_dialog.h"
#include "napi_helpers.h"
#include "../platform/game_dialog.h"
#include <cmath>
#include <cstdio>

namespace {
/** 完整解析十进制身份；拒绝符号、前导零、零、截断及溢出，不接受数字近似值。 */
bool Identity(napi_env env, napi_value value, uint64_t& result) {
    char text[21]{}; size_t length = 0, copied = 0;
    // 先核实际长度，再读固定缓冲，身份转换没有C++堆分配/异常窗口。
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length == 0 || length > 20 ||
        napi_get_value_string_utf8(env, value, text, sizeof(text), &copied) != napi_ok || copied != length || text[0] == '0') return false;
    result = 0;
    for (size_t index = 0; index < length; ++index) {
        const char c = text[index];
        if (c < '0' || c > '9' || result > (UINT64_MAX - (c - '0')) / 10) return false;
        result = result * 10 + (c - '0');
    }
    return result != 0;
}
/** 不覆盖SDK已pending的原异常；尚无异常时明确报告桥接失败。 */
napi_value Failure(napi_env env, const char* message) {
    bool pending = false;
    if (napi_is_exception_pending(env, &pending) == napi_ok && !pending) napi_throw_error(env, nullptr, message);
    return nullptr;
}
/** 所有成功/拒绝返回值先准备好，后续Native副作用完成后不再调用可失败的NAPI分配。 */
bool PrepareBoolean(napi_env env, napi_value& yes, napi_value& no) {
    return napi_get_boolean(env, true, &yes) == napi_ok && napi_get_boolean(env, false, &no) == napi_ok;
}
bool Text(napi_env env, napi_value object, const char* key, const char* text) {
    napi_value value = nullptr;
    return napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &value) == napi_ok &&
        napi_set_named_property(env, object, key, value) == napi_ok;
}
bool Number(napi_env env, napi_value object, const char* key, int32_t number) {
    napi_value value = nullptr;
    return napi_create_int32(env, number, &value) == napi_ok &&
        napi_set_named_property(env, object, key, value) == napi_ok;
}
napi_value Attach(napi_env env, napi_callback_info info) {
    size_t count = 2; napi_value args[2]{}; double session = 0;
    const bool valid = napi_get_cb_info(env, info, &count, args, nullptr, nullptr) == napi_ok && count == 1 &&
        napi_get_value_double(env, args[0], &session) == napi_ok && std::isfinite(session) && session > 0 &&
        session <= 9007199254740991.0 && std::floor(session) == session;
    // UI窗口装配与JVM的进程退出权限无关。手机/共享进程也有真实McGamePage和UI
    // 事件线程，不能为了显示提示要求独立进程退出授权，更不能反过来授予退出权。
    const uint64_t generation = valid ? AmclGameDialogAttachV1(static_cast<uint64_t>(session)) : 0;
    char identity[24]{};
    if (generation) std::snprintf(identity, sizeof(identity), "%llu", static_cast<unsigned long long>(generation));
    napi_value result = nullptr;
    if (napi_create_string_utf8(env, identity, NAPI_AUTO_LENGTH, &result) != napi_ok) {
        // JS尚未取得租约；回包分配失败必须撤销刚取得的原生租约，不能留下不可退役owner。
        if (generation) AmclGameDialogDetachV1(generation);
        return Failure(env, "Cannot return game dialog lease");
    }
    return result;
}
napi_value Detach(napi_env env, napi_callback_info info) {
    size_t count = 2; napi_value args[2]{}; uint64_t generation = 0;
    napi_value yes = nullptr, no = nullptr;
    if (!PrepareBoolean(env, yes, no)) return Failure(env, "Cannot prepare dialog retirement result");
    const bool valid = napi_get_cb_info(env, info, &count, args, nullptr, nullptr) == napi_ok &&
        count == 1 && Identity(env, args[0], generation);
    return valid && AmclGameDialogDetachV1(generation) == 1 ? yes : no;
}
napi_value Take(napi_env env, napi_callback_info info) {
    size_t count = 2; napi_value args[2]{}; uint64_t generation = 0;
    AmclGameDialogRequestV1 request{}; request.size = sizeof(request);
    if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 1 ||
        !Identity(env, args[0], generation) || AmclGameDialogTakeV1(generation, &request) != 1)
        return amcl::napi::MakeUndefined(env);
    napi_value result = nullptr; char generationText[24]{}, requestText[24]{};
    std::snprintf(generationText, sizeof(generationText), "%llu", static_cast<unsigned long long>(request.generation));
    std::snprintf(requestText, sizeof(requestText), "%llu", static_cast<unsigned long long>(request.requestId));
    const bool copied = napi_create_object(env, &result) == napi_ok &&
        Text(env, result, "generation", generationText) && Text(env, result, "requestId", requestText) &&
        Text(env, result, "title", request.title) && Text(env, result, "message", request.message) &&
        Number(env, result, "kind", request.kind) && Number(env, result, "defaultButton", request.defaultButton);
    if (!copied) {
        // Take已把请求标成已交付；NAPI分配失败时必须用原身份取消，避免Java无限等
        // 一个从未到达UI的请求。保留已pending异常，不以第二个错误覆盖原始根因。
        AmclGameDialogCancelV1(generation, request.requestId);
        return Failure(env, "Cannot copy game dialog request");
    }
    return result;
}
napi_value Reply(napi_env env, napi_callback_info info) {
    size_t count = 5; napi_value args[5]{}; uint64_t generation = 0, id = 0; double value = -1; bool userResponse = false;
    napi_value yes = nullptr, no = nullptr;
    if (!PrepareBoolean(env, yes, no)) return Failure(env, "Cannot prepare dialog response result");
    const bool valid = napi_get_cb_info(env, info, &count, args, nullptr, nullptr) == napi_ok && count == 4 &&
        Identity(env, args[0], generation) && Identity(env, args[1], id) &&
        napi_get_value_double(env, args[2], &value) == napi_ok && value >= 0 && value <= 2 && std::floor(value) == value &&
        napi_get_value_bool(env, args[3], &userResponse) == napi_ok && (userResponse || value == 0);
    return valid && (userResponse ? AmclGameDialogReplyV1(generation, id, static_cast<int>(value)) :
        AmclGameDialogCancelV1(generation, id)) == 1 ? yes : no;
}
}
namespace amcl::napi {
void registerGameDialogNapi(napi_env env, napi_value exports) {
    // 注册不挂接UI；真实McGamePage在UIContent就绪时装配，下载/processor不走该入口。
    const napi_property_descriptor properties[] = {
        {"gameDialogAttach", nullptr, Attach, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gameDialogDetach", nullptr, Detach, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gameDialogTake", nullptr, Take, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gameDialogReply", nullptr, Reply, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
}
}

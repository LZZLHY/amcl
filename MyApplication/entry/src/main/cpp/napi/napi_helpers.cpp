/**
 * napi_helpers.cpp — NAPI 共享类型转换工具实现
 *
 * 本文件函数与 napi_entry.cpp 重构前的 static 版本逐字节等价，
 * 仅签名从 static → namespace amcl::napi 内的 external linkage。
 */
#include "napi_helpers.h"

#include <cstring>

namespace amcl::napi {

napi_value WrapStringResult(napi_env env, const char* result) {
    napi_value str;
    napi_create_string_utf8(env, result, std::strlen(result), &str);
    return str;
}

bool ReadStringValue(napi_env env, napi_value value, std::string& out) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    std::vector<char> buf(len + 1, 0);
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &len) != napi_ok) {
        return false;
    }
    out.assign(buf.data(), len);
    return true;
}

bool ReadStringArrayValue(napi_env env, napi_value value, std::vector<std::string>& out) {
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) {
        return false;
    }

    uint32_t length = 0;
    if (napi_get_array_length(env, value, &length) != napi_ok) {
        return false;
    }

    out.clear();
    out.reserve(length);
    for (uint32_t i = 0; i < length; ++i) {
        napi_value item;
        if (napi_get_element(env, value, i, &item) != napi_ok) {
            return false;
        }
        std::string arg;
        if (!ReadStringValue(env, item, arg)) {
            return false;
        }
        out.push_back(std::move(arg));
    }
    return true;
}

bool ReadStringArg(napi_env env, napi_callback_info info, char* buf, size_t bufSize) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) return false;
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], buf, bufSize, &len);
    return len > 0;
}

napi_value MakeIntResult(napi_env env, int32_t value) {
    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value MakeBoolResult(napi_env env, bool value) {
    napi_value result;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value MakeUndefined(napi_env env) {
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

} // namespace amcl::napi

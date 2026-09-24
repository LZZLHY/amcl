/**
 * download/probe.cpp — libcurl 链接/加载验证
 *
 * 见 probe.h。Stage 1a：只用于 libcurl.so 真机加载验证，无任何网络行为。
 */
#include "probe.h"

#include <curl/curl.h>
#include <hilog/log.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_PROBE"

namespace {

// 组合 feature flag → 可读字符串。和 libcurl 官方命名对齐。
// 只列下载引擎关心的几个；其他 flag（NTLM/Kerberos/HTTP3 等）跳过。
std::string featuresToString(unsigned int features) {
    std::string out;
    auto append = [&](const char* name, bool enabled) {
        if (!out.empty()) out.push_back(',');
        out.append(name);
        out.push_back('=');
        out.push_back(enabled ? '1' : '0');
    };
    append("IPv6",       (features & CURL_VERSION_IPV6) != 0);
    append("ASYNCHDNS",  (features & CURL_VERSION_ASYNCHDNS) != 0);
    append("SSL",        (features & CURL_VERSION_SSL) != 0);
    append("libz",       (features & CURL_VERSION_LIBZ) != 0);
    append("HTTP2",      (features & CURL_VERSION_HTTP2) != 0);
    append("threadsafe", (features & CURL_VERSION_THREADSAFE) != 0);
    return out;
}

std::string protocolsToString(const char* const* protos) {
    std::string out;
    if (!protos) return out;
    for (int i = 0; protos[i]; ++i) {
        if (!out.empty()) out.push_back(',');
        out.append(protos[i]);
    }
    return out;
}

} // namespace

extern "C" const char* downloadEngineProbe() {
    // 静态缓存：首次调用生成，后续调用复用。
    static std::string cached;
    if (!cached.empty()) {
        return cached.c_str();
    }

    curl_version_info_data* info = curl_version_info(CURLVERSION_NOW);
    if (!info) {
        cached = "libcurl: curl_version_info() returned NULL";
        return cached.c_str();
    }

    char header[256];
    std::snprintf(header, sizeof(header),
                  "libcurl/%s %s host=%s",
                  info->version ? info->version : "?",
                  info->ssl_version ? info->ssl_version : "no-ssl",
                  info->host ? info->host : "?");

    cached.assign(header);
    cached.append(" features=");
    cached.append(featuresToString(info->features));
    cached.append(" protocols=");
    cached.append(protocolsToString(info->protocols));

    AMCL_LOG_I(LOG_TAG, "downloadEngineProbe: %{public}s", cached.c_str());
    return cached.c_str();
}

#ifdef MC_OHOS_BUILD_TESTS
extern "C" int downloadEngineSelfTest() {
    // L-3 修复：去掉自检里的 curl_global_init/cleanup，避免与运行中的 Engine
    // 全局 curl 状态（SSL/DNS）冲突。curl 文档明示 curl_global_init/cleanup
    // 非线程安全；DevTools 在 Engine 跑 64 并发 easy handle 时触发自检，
    // 可能撞坏 OpenSSL 的全局静态初始化。
    //
    // 现在自检只做 easy_init/setopt/cleanup（curl 文档允许在 curl_global_init
    // 已被任意路径调过之后并发使用 easy handle）。
    // 调用方应在 Engine 已 init 后再调本函数（DevTools 默认就是这个流程）。
    //
    // 如果 Engine 尚未初始化，curl_easy_init 仍能工作（自带 lazy 全局 init），
    // 这与之前的显式 curl_global_init 行为等价。但为了诊断更明确，建议先调
    // engine.start() 触发 ensureCurlInited。
    CURL* easy = curl_easy_init();
    if (!easy) {
        AMCL_LOG_E(LOG_TAG, "downloadEngineSelfTest: curl_easy_init returned NULL "
                              "(engine未初始化？)");
        return -1;
    }

    // 简单的能力测试：设置一个 option，再取回看是否对称（不做网络）
    CURLcode rc_opt = curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, 5L);
    if (rc_opt != CURLE_OK) {
        AMCL_LOG_E(LOG_TAG, "downloadEngineSelfTest: setopt CONNECTTIMEOUT failed: %{public}d",
                     (int)rc_opt);
    }

    curl_easy_cleanup(easy);

    AMCL_LOG_I(LOG_TAG, "downloadEngineSelfTest: OK (easy/setopt/cleanup chain works)");
    return rc_opt == CURLE_OK ? 0 : (int)rc_opt;
}

#endif

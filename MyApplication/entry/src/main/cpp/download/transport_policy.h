/**
 * download/transport_policy.h — worker 与 CURLM 共用的纯传输决定。
 *
 * 这里只保存请求参数和真实结果的值，不持有任务、线程、fd 或凭据。执行器继续拥有
 * easy handle 与回调；Engine 继续拥有主机账本，NetFile 继续负责校验和持久提交。
 */
#pragma once

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <limits>
#include <string>
#include <curl/curl.h>
#include "exception.h"

namespace download {

/** 一次 HTTP 的兼容参数；先保存原来两种执行方式的数值，再独立验证后续调优。 */
struct TransportRequestProfile {
    long connect_timeout_s = 0;
    long total_timeout_s = 0;
    long low_speed_limit = 0;
    long low_speed_time_s = 0;
    long http_version = CURL_HTTP_VERSION_NONE;
    long buffer_size = 0;
    bool enlarge_socket_buffer = false;
};

/** worker 旧默认的纯投影。单源 full GET 保留低速容忍，不把唯一慢源反复掐断。 */
inline TransportRequestProfile workerRequestProfile(int64_t file_size, bool high_parallel,
                                                     bool single_full_get, bool alternate_source) {
    const bool small = file_size > 0 && file_size < 1024 * 1024;
    TransportRequestProfile p;
    p.connect_timeout_s = small ? 8 : 12;
    p.total_timeout_s = small ? 20 : 0;
    p.low_speed_limit = single_full_get && alternate_source ? 16 * 1024 : 1024;
    p.low_speed_time_s = small ? 10 : 15;
    if (high_parallel && !single_full_get) { p.low_speed_limit = 4096; p.low_speed_time_s = 30; }
    if (high_parallel || file_size >= 4 * 1024 * 1024) {
        p.buffer_size = 512 * 1024;
        p.enlarge_socket_buffer = true;
        p.http_version = CURL_HTTP_VERSION_1_1;
    }
    return p;
}

/** CURLM 配置仍由原 Config 提供；不趁抽取改可达分流或并发。 */
inline TransportRequestProfile multiRequestProfile(long connect_s, long total_s, long low_limit,
                                                   long low_time_s, bool high_parallel) {
    TransportRequestProfile p;
    p.connect_timeout_s = connect_s; p.total_timeout_s = total_s;
    p.low_speed_limit = low_limit; p.low_speed_time_s = low_time_s;
    if (high_parallel) {
        p.http_version = CURL_HTTP_VERSION_1_1; p.buffer_size = 512 * 1024;
        p.low_speed_limit = 96 * 1024; p.low_speed_time_s = 5; p.total_timeout_s = 0;
    }
    return p;
}

/** 两执行器设置同一组普通选项；授权、CA、Range、relay 与回调仍显式安装。 */
inline void applyTransportProfile(CURL* easy, const TransportRequestProfile& p) {
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, p.connect_timeout_s);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT, p.total_timeout_s);
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, p.low_speed_limit);
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, p.low_speed_time_s);
    curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, p.http_version);
    if (p.buffer_size > 0) {
        curl_easy_setopt(easy, CURLOPT_BUFFERSIZE, p.buffer_size);
        curl_easy_setopt(easy, CURLOPT_TCP_NODELAY, 1L);
    }
}

/** 正数相加饱和，避免服务器给出极长 Retry-After 时溢出为“立即可用”。 */
inline int64_t transportDeadlineAfter(int64_t now, int64_t delay) {
    return delay > 0 && now > std::numeric_limits<int64_t>::max() - delay
        ? std::numeric_limits<int64_t>::max() : now + std::max<int64_t>(0, delay);
}

/**
 * 解析 Retry-After 的秒数或 HTTP-date。服务器等待值不受客户端指数退避 cap 截短；
 * 超出一次任务预算由调度器保留真实错误并终止，不能为了继续而提前请求。
 * 非法值返回 0；数字溢出取最大可表示等待值，仍不能被误读成短等待。
 */
inline int64_t parseTransportRetryAfter(const std::string& raw, time_t wall_now = std::time(nullptr)) {
    const size_t a = raw.find_first_not_of(" \t");
    const size_t b = raw.find_last_not_of(" \t\r\n");
    if (a == std::string::npos || b < a) return 0;
    const std::string value = raw.substr(a, b - a + 1);
    bool digits = !value.empty();
    for (char c : value) if (c < '0' || c > '9') { digits = false; break; }
    if (digits) {
        int64_t seconds = 0;
        constexpr int64_t kMaxSeconds = std::numeric_limits<int64_t>::max() / 1000;
        for (char c : value) {
            if (seconds > (kMaxSeconds - (c - '0')) / 10)
                return std::numeric_limits<int64_t>::max();
            seconds = seconds * 10 + (c - '0');
        }
        return seconds * 1000;
    }
    const time_t date = curl_getdate(value.c_str(), nullptr);
    if (date <= wall_now) return 0;
    const long double delay = static_cast<long double>(date) - static_cast<long double>(wall_now);
    if (delay >= static_cast<long double>(std::numeric_limits<int64_t>::max()) / 1000)
        return std::numeric_limits<int64_t>::max();
    return static_cast<int64_t>(delay * 1000);
}

/** 两执行器对本地失败采用同一分类；磁盘故障不得触发换源或健康惩罚。 */
inline bool isLocalTransportFailure(ErrorKind kind) {
    return kind == ErrorKind::FileIoError || kind == ErrorKind::DiskFullError ||
           kind == ErrorKind::QuotaExceededError || kind == ErrorKind::StorageIoError;
}

/** 瞬时连接类只在没有 HTTP 连通证据时才可驱动地址族/主机故障判断。 */
inline bool isTransientTransportFailure(ErrorKind kind) {
    return kind == ErrorKind::ConnectionError || kind == ErrorKind::Timeout || kind == ErrorKind::SslError;
}

/** 原始 CURL 失败是否允许尝试尚未试过的另一族；本地中止与 HTTP 错误不扣族分。 */
inline bool isFamilyConnectFailure(CURLcode rc, long http_code, int64_t bytes) {
    return http_code == 0 && bytes == 0 &&
        (rc == CURLE_COULDNT_CONNECT || rc == CURLE_COULDNT_RESOLVE_HOST ||
         rc == CURLE_OPERATION_TIMEDOUT || rc == CURLE_SSL_CONNECT_ERROR ||
         rc == CURLE_RECV_ERROR || rc == CURLE_SEND_ERROR ||
         rc == CURLE_GOT_NOTHING || rc == CURLE_PARTIAL_FILE);
}

/**
 * 相对慢尾判据只比较其他活跃段的平均速度。聚合sum随段数增长，不能让16条同速
 * 慢链路彼此判定“落后6倍”；单段或没有正向peer证据时不抢占。
 * 外层仍检查15s建立成本、32KiB/s地板和剩余512KiB，不由此函数取消请求。
 */
inline bool slowerThanTransportPeers(int64_t own_bps, int64_t file_bps, int active_segments) {
    if (own_bps < 0 || active_segments < 2 || file_bps <= own_bps) return false;
    const int64_t peer_average = (file_bps - own_bps) / (active_segments - 1);
    return own_bps <= std::numeric_limits<int64_t>::max() / 6 && own_bps * 6 < peer_average;
}

/** 实际 hop 的主机。支持 IPv6 字面量、端口、userinfo 与无路径 URL，统一为小写。 */
inline std::string transportHost(const std::string& url) {
    const size_t scheme = url.find("://");
    if (scheme == std::string::npos) return {};
    const size_t begin = scheme + 3;
    const size_t end = url.find_first_of("/?#", begin);
    std::string authority = url.substr(begin, end == std::string::npos ? std::string::npos : end - begin);
    const size_t at = authority.rfind('@');
    if (at != std::string::npos) authority.erase(0, at + 1);
    if (!authority.empty() && authority.front() == '[') {
        const size_t close = authority.find(']');
        if (close == std::string::npos) return {};
        authority = authority.substr(0, close + 1);
    } else {
        const size_t colon = authority.find(':');
        if (colon != std::string::npos) authority.resize(colon);
    }
    for (char& c : authority) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return authority;
}

/** 手动重定向和自动重定向采用同样的 HTTP(S) 传输边界，不接受其他协议的 Location。 */
inline bool isTransportHttpUrl(const std::string& url) {
    const size_t colon = url.find(':');
    if (colon == std::string::npos) return false;
    std::string scheme = url.substr(0, colon);
    for (char& c : scheme) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return (scheme == "http" || scheme == "https") && !transportHost(url).empty();
}

} // namespace download

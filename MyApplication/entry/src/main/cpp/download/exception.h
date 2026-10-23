/**
 * download/exception.h — 下载引擎统一异常基础设施
 *
 * 照搬 PCL2 的"异常带完整堆栈" 概念，但 C++ 不易拿堆栈，所以只带
 * message + errno/CURLcode + URL 上下文。目的是让 UI 和日志能准确
 * 说出"哪个源、哪个 HTTP 状态码、哪个 curl error"。
 *
 * 不用 std::exception 继承：引擎内部不 throw/catch（避免 RTTI 开销
 * 和 signal handler 复杂度），而是用 std::shared_ptr<DownloadException>
 * 在 NetThread/NetFile/LoaderDownload 的 error 字段里传递。
 */
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace download {

enum class ErrorKind : uint8_t {
    Unknown          = 0,
    // 网络 / curl 层
    ConnectionError  = 1,  // CURLE_COULDNT_CONNECT / CURLE_RESOLVE_HOST
    ProtocolError    = 2,  // HTTP 4xx / 5xx
    Timeout          = 3,  // CURLE_OPERATION_TIMEDOUT
    AbortedByUser    = 4,  // progress callback return non-zero
    SslError         = 5,  // CURLE_SSL_*
    // 本地 / 文件层
    FileIoError      = 6,  // open/pwrite/ftruncate 失败
    DiskFullError    = 7,  // ENOSPC
    // 数据完整性
    ChecksumMismatch = 8,  // sha1 不匹配
    SizeMismatch     = 9,  // file size 和预期不符
    // 配置 / 编程错误
    InvalidConfig    = 10, // 空 URL 列表等
    InternalError    = 11,
    QuotaExceededError = 12, // EDQUOT
    StorageIoError   = 13, // EIO / durable commit failure
    AuthorizationRenewalRequired = 14, // 本次短时权限不能再发HTTP，请业务层在收敛后重领
};

const char* errorKindToString(ErrorKind k);

class DownloadException {
public:
    ErrorKind kind = ErrorKind::Unknown;
    std::string message;                   // 人类可读
    std::string url_context;               // 出问题的 URL（可空）
    int native_code = 0;                   // CURLcode 或 errno
    long http_status = 0;                  // HTTP 状态码（如果适用）
    // v5 新增：下载期间所有试过的源 URL（去重后）。供 UI 显示
    // "已尝试: 2 个源（BMCLAPI / Mojang）"等详情。
    std::vector<std::string> tried_urls;
    // 授权的结构化执行事实；只含次数/状态，不含Bearer或上游授权正文。
    bool needs_new_lease = false;
    bool request_started = false;
    bool successful_headers_seen = false;
    int64_t bytes_written = 0;
    int http_attempts = 0;
    int64_t retry_after_ms = 0;

    DownloadException() = default;
    DownloadException(ErrorKind k, std::string msg) : kind(k), message(std::move(msg)) {}

    /** 生成形如 "[Timeout] (curl=28) https://example.com/foo.jar: timed out" 的字符串 */
    std::string toString() const;
};

using DownloadExceptionPtr = std::shared_ptr<DownloadException>;

/** 便利工厂（少打字） */
inline DownloadExceptionPtr makeException(ErrorKind k, std::string msg) {
    return std::make_shared<DownloadException>(k, std::move(msg));
}

/**
 * 在换源或重试调度停止时保留最近一次真实失败，并补充停止原因。
 *
 * cause 必须来自本段当前执行中的实际异常，不能从多个源的历史错误中任意选取。
 * 有 cause 时完整复制所有字段，保留 HTTP/CURL 分类、出错 URL、授权事实和 Retry-After；
 * 副本只追加调度说明，避免改动其他分段或 NetSource 正在共享的原异常。
 * 尚未产生真实异常时，才返回只描述调度原因的 ConnectionError。
 */
DownloadExceptionPtr makeRetryTerminationException(const DownloadExceptionPtr& cause,
                                                   const std::string& stop_reason);

} // namespace download

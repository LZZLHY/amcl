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

} // namespace download

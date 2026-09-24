/**
 * download/file_checker.h — 下载文件完整性校验
 *
 * 支持两种校验（可同时启用）：
 *   - size：期望文件大小（字节）。PCL2 对每个文件都有 size 期望（来自 version.json）
 *   - sha1：期望的 SHA-1 hex 小写（40 字符）。MC 的 hash 用 sha1（不是 sha256）
 *
 * SHA-1 实现用 OpenSSL 的 EVP API（libcurl.so 里已经静态内联了 OpenSSL 3.3.2）。
 * 为了稳健，即使 libcurl 未来升级我们会重新评估是否要独立一个 sha1 实现。
 * 目前 EVP_sha1() 符号在 libcurl.so 的导出符号里（POC 阶段已确认 2100+ OpenSSL 符号）。
 *
 * 约定：FileChecker 的 expected_size == -1 表示"不检查 size"，expected_sha1 空串
 *       表示"不检查 sha1"。全 disabled 时 check() 永远返回 ok。
 */
#pragma once

#include <cstdint>
#include <string>

#include "exception.h"

namespace download {

/** Untrusted manifests/meta must never request a larger allocation/truncate. */
inline constexpr int64_t kMaxDownloadFileBytes = 1LL * 1024 * 1024 * 1024 * 1024;

struct FileChecker {
    int64_t     expected_size = -1;   // -1 表示不校验
    std::string expected_sha1;        // 空串表示不校验，否则 40 字符 hex 小写

    bool needsAnyCheck() const {
        return expected_size >= 0 || !expected_sha1.empty();
    }

    /**
     * 校验 local_path 处的实际文件。成功返回空指针，失败返回异常。
     *
     * 失败 kind：
     *   - SizeMismatch：size 不匹配
     *   - ChecksumMismatch：sha1 不匹配
     *   - FileIoError：文件打不开 / 读不了
     *
     * 性能：sha1 会全量读文件，对大文件（几百 MB）有明显开销。
     *       NetFile 会在后台线程里调用 check，不阻塞调度线程。
     */
    DownloadExceptionPtr check(const std::string& local_path) const;

    /**
     * v4.6: 快速校验 — 接受预计算的 SHA1（40 字符 hex 小写），通过
     * lstat + no-follow open + fstat 检查文件类型/大小，再比对 SHA1，不重新读内容。
     * 用于单段文件在 onWrite 中增量计算了 SHA1 的场景。
     * 性能：安全打开/关闭 + strcmp，vs check() 的全文件读取 + sha1。
     */
    DownloadExceptionPtr checkFast(const std::string& local_path,
                                   const std::string& precomputed_sha1) const;
};

/** 独立 SHA-1 计算：读文件并返回 40 字符 hex 小写；失败返回空串 */
std::string computeFileSha1(const std::string& local_path);

} // namespace download

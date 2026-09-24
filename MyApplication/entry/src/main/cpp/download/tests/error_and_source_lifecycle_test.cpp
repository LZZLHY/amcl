/**
 * error_and_source_lifecycle_test.cpp — Phase 7 (S3-4) 单元测试
 *
 * 覆盖：download/exception.{h,cpp} + download/net_source.{h,cpp} 的非评分部分
 *   - errorKindToString: 全部 12 个 ErrorKind 值
 *   - DownloadException::toString: 组合格式（kind / code / http / url / message）
 *   - NetSource::recordFailure: 阈值翻转、首次翻转标记、last_error 记录
 *   - NetSource::recordSuccess: success_count 递增、fail_count 清零（但 is_failed 保留）
 *
 * 零依赖 / 零网络，纯内存。
 *
 * 创建日期：2026-05-06
 */

#include "download_tests.h"
#include "../exception.h"
#include "../net_source.h"

#include <memory>
#include <string>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "CORE_TEST"

static std::string g_core_results;

static void appendResult(const char* testName, bool success, const std::string& detail) {
    g_core_results += testName;
    g_core_results += ": ";
    g_core_results += success ? "PASS" : "FAIL";
    g_core_results += " (";
    g_core_results += detail;
    g_core_results += ")\n";
    OH_LOG_INFO(LOG_APP, "[%{public}s] %{public}s - %{public}s",
                testName, success ? "PASS" : "FAIL", detail.c_str());
}

// ============================================================
//  errorKindToString
// ============================================================

static void test_errorKindToString_all_values() {
    using download::ErrorKind;
    using download::errorKindToString;

    bool ok = true;
    std::string detail;
    auto check = [&](ErrorKind k, const char* expected) {
        const char* got = errorKindToString(k);
        if (std::string(got) != expected) {
            ok = false;
            detail += std::string(expected) + "!=" + got + " ";
        }
    };
    check(ErrorKind::Unknown,          "Unknown");
    check(ErrorKind::ConnectionError,  "ConnectionError");
    check(ErrorKind::ProtocolError,    "ProtocolError");
    check(ErrorKind::Timeout,          "Timeout");
    check(ErrorKind::AbortedByUser,    "AbortedByUser");
    check(ErrorKind::SslError,         "SslError");
    check(ErrorKind::FileIoError,      "FileIoError");
    check(ErrorKind::DiskFullError,    "DiskFullError");
    check(ErrorKind::ChecksumMismatch, "ChecksumMismatch");
    check(ErrorKind::SizeMismatch,     "SizeMismatch");
    check(ErrorKind::InvalidConfig,    "InvalidConfig");
    check(ErrorKind::InternalError,    "InternalError");
    appendResult("test_errorKindToString_all_values", ok, detail.empty() ? "all match" : detail);
}

// ============================================================
//  DownloadException::toString
// ============================================================

static void test_exception_toString_minimal() {
    download::DownloadException ex(download::ErrorKind::Timeout, "timed out");
    std::string s = ex.toString();
    bool ok = s.find("[Timeout]") != std::string::npos
           && s.find("timed out") != std::string::npos;
    appendResult("test_exception_toString_minimal", ok, s);
}

static void test_exception_toString_full() {
    download::DownloadException ex(download::ErrorKind::ProtocolError, "not found");
    ex.native_code = 0;
    ex.http_status = 404;
    ex.url_context = "https://example.com/foo.jar";
    std::string s = ex.toString();
    bool ok = s.find("[ProtocolError]") != std::string::npos
           && s.find("http=404") != std::string::npos
           && s.find("https://example.com/foo.jar") != std::string::npos
           && s.find("not found") != std::string::npos;
    appendResult("test_exception_toString_full", ok, s);
}

static void test_exception_toString_with_native_code() {
    download::DownloadException ex(download::ErrorKind::SslError, "cert verification failed");
    ex.native_code = 60;  // CURLE_PEER_FAILED_VERIFICATION
    std::string s = ex.toString();
    bool ok = s.find("[SslError]") != std::string::npos
           && s.find("code=60") != std::string::npos;
    appendResult("test_exception_toString_with_native_code", ok, s);
}

static void test_makeException_factory() {
    auto ex = download::makeException(download::ErrorKind::FileIoError, "pwrite failed");
    bool ok = ex != nullptr
           && ex->kind == download::ErrorKind::FileIoError
           && ex->message == "pwrite failed";
    appendResult("test_makeException_factory", ok, ok ? "ok" : "nullptr or wrong fields");
}

// ============================================================
//  NetSource::recordFailure / recordSuccess
// ============================================================

static void test_recordFailure_below_threshold() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    auto ex = download::makeException(download::ErrorKind::Timeout, "timeout");
    bool just_failed = src->recordFailure(ex);  // 默认阈值 3
    auto last_err = src->lastError();  // C-1 修复后走 mutex 保护的 getter
    bool ok = !just_failed
           && src->fail_count.load() == 1
           && !src->is_failed.load()
           && last_err != nullptr
           && last_err->kind == download::ErrorKind::Timeout;
    appendResult("test_recordFailure_below_threshold", ok,
        "fail_count=" + std::to_string(src->fail_count.load())
        + " is_failed=" + std::to_string(src->is_failed.load()));
}

static void test_recordFailure_at_threshold_first_flip() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    auto ex = download::makeException(download::ErrorKind::ConnectionError, "no route");
    src->recordFailure(ex);                      // 1
    src->recordFailure(ex);                      // 2
    bool just_failed = src->recordFailure(ex);   // 3 -> flip
    bool ok = just_failed
           && src->fail_count.load() == 3
           && src->is_failed.load();
    appendResult("test_recordFailure_at_threshold_first_flip", ok,
        "just_failed=" + std::to_string(just_failed)
        + " fail_count=" + std::to_string(src->fail_count.load()));
}

static void test_recordFailure_second_flip_returns_false() {
    // 已经 is_failed=true 时，再失败不应返回 true（日志去重）
    auto src = std::make_shared<download::NetSource>("https://a/x");
    auto ex = download::makeException(download::ErrorKind::Timeout, "t");
    src->recordFailure(ex);
    src->recordFailure(ex);
    bool first = src->recordFailure(ex);  // true（刚翻转）
    bool second = src->recordFailure(ex); // false（已翻转过）
    bool ok = first && !second;
    appendResult("test_recordFailure_second_flip_returns_false", ok,
        "first=" + std::to_string(first) + " second=" + std::to_string(second));
}

static void test_recordFailure_custom_threshold() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    auto ex = download::makeException(download::ErrorKind::ProtocolError, "404");
    bool just = src->recordFailure(ex, /*max_failures=*/1);  // 1 次就翻转
    bool ok = just && src->is_failed.load();
    appendResult("test_recordFailure_custom_threshold", ok,
        "just=" + std::to_string(just));
}

static void test_recordSuccess_resets_fail_count() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    auto ex = download::makeException(download::ErrorKind::Timeout, "t");
    src->recordFailure(ex);  // fail_count=1
    src->recordFailure(ex);  // fail_count=2
    src->recordSuccess();    // 应该把 fail_count 清零
    bool ok = src->fail_count.load() == 0
           && src->success_count.load() == 1
           && !src->is_failed.load();
    appendResult("test_recordSuccess_resets_fail_count", ok,
        "fail_count=" + std::to_string(src->fail_count.load())
        + " success=" + std::to_string(src->success_count.load()));
}

static void test_recordSuccess_preserves_is_failed() {
    // 已经 is_failed=true 的源，偶然成功一次不应该恢复（避免抖动）
    auto src = std::make_shared<download::NetSource>("https://a/x");
    auto ex = download::makeException(download::ErrorKind::Timeout, "t");
    src->recordFailure(ex);
    src->recordFailure(ex);
    src->recordFailure(ex);  // is_failed=true
    bool was_failed_before = src->is_failed.load();
    src->recordSuccess();
    bool still_failed = src->is_failed.load();
    bool ok = was_failed_before && still_failed;
    appendResult("test_recordSuccess_preserves_is_failed", ok,
        "before=" + std::to_string(was_failed_before)
        + " after=" + std::to_string(still_failed));
}

// ============================================================
//  入口
// ============================================================

extern "C" const char* runErrorAndSourceLifecycleTests() {
    g_core_results.clear();
    g_core_results += "=== Error + NetSource Lifecycle Tests (Phase 7) ===\n";

    test_errorKindToString_all_values();
    test_exception_toString_minimal();
    test_exception_toString_full();
    test_exception_toString_with_native_code();
    test_makeException_factory();
    test_recordFailure_below_threshold();
    test_recordFailure_at_threshold_first_flip();
    test_recordFailure_second_flip_returns_false();
    test_recordFailure_custom_threshold();
    test_recordSuccess_resets_fail_count();
    test_recordSuccess_preserves_is_failed();

    g_core_results += "=== End ===\n";
    return g_core_results.c_str();
}

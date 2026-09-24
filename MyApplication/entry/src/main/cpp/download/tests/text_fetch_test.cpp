/**
 * text_fetch_test.cpp — Phase 3 (元数据走 NAPI 引擎) 验证测试
 *
 * TDD 红阶段：本文件先于 engine.h 的 fetchToBuffer 方法实现。
 *
 * 当前编译预期：链接失败 — DownloadEngine::fetchToBuffer 还不存在。
 *
 * 覆盖范围（依赖真实网络）：
 *   - 单 URL 200 OK 拉取小文本
 *   - 多镜像首个失败 → fallback 到第二个
 *   - 全部失败 → 返回非 0 错误
 *   - 大 buffer (1MB+) 正确拼接
 *   - 超时正常 abort
 *
 * 需在 caBundlePath 已正确设置的前提下跑。
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 3
 *
 * 创建日期：2026-05-05
 */

#include "download_tests.h"
#include "../engine.h"

#include <chrono>
#include <string>
#include <vector>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "FETCH_TEST"
// LOG_APP 是 hilog 头里的 LogType enum (= 0)，不要重定义为 0xFF00
// （之前重定义为 #define 导致 OH_LOG_Print 签名不匹配）

static std::string g_fetch_results;

static void appendResult(const char* testName, bool success, const std::string& detail) {
    g_fetch_results += testName;
    g_fetch_results += ": ";
    g_fetch_results += success ? "✅ PASS" : "❌ FAIL";
    g_fetch_results += " (";
    g_fetch_results += detail;
    g_fetch_results += ")\n";
    OH_LOG_INFO(LOG_APP, "[%{public}s] %{public}s - %{public}s",
                testName, success ? "PASS" : "FAIL", detail.c_str());
}

// ============================================================
//  Test 1: 单 URL 200 OK
// ============================================================

static void test_single_url_200(const std::string& caBundle) {
    std::string body, errKind, errMsg;
    int rc = download::DownloadEngine::instance().fetchToBuffer(
        "https://httpbin.org/get",
        {},
        10,
        body, errKind, errMsg);
    bool ok = (rc == 0 && body.size() > 0 && body.find("\"url\"") != std::string::npos);
    appendResult("test_single_url_200", ok,
        "rc=" + std::to_string(rc) + " bytes=" + std::to_string(body.size())
        + (rc != 0 ? (" kind=" + errKind + " msg=" + errMsg) : ""));
}

// ============================================================
//  Test 2: 多镜像 fallback
// ============================================================

static void test_multi_mirror_fallback(const std::string& caBundle) {
    std::string body, errKind, errMsg;
    std::vector<std::string> mirrors = {
        "https://nonexistent-host-12345.invalid/get",  // DNS fail
        "https://httpbin.org/get",                      // 应 fallback 到这里
    };
    int rc = download::DownloadEngine::instance().fetchToBuffer(
        mirrors[0], {mirrors[1]}, 10,
        body, errKind, errMsg);
    bool ok = (rc == 0 && body.size() > 0);
    appendResult("test_multi_mirror_fallback", ok,
        "rc=" + std::to_string(rc) + " bytes=" + std::to_string(body.size()));
}

// ============================================================
//  Test 3: 全部失败
// ============================================================

static void test_all_mirrors_fail(const std::string& caBundle) {
    std::string body, errKind, errMsg;
    std::vector<std::string> mirrors = {
        "https://nonexistent-host-1.invalid/x",
        "https://nonexistent-host-2.invalid/x",
    };
    int rc = download::DownloadEngine::instance().fetchToBuffer(
        mirrors[0], {mirrors[1]}, 5,
        body, errKind, errMsg);
    bool ok = (rc != 0 && !errKind.empty());
    appendResult("test_all_mirrors_fail", ok,
        "rc=" + std::to_string(rc) + " kind=" + errKind);
}

// ============================================================
//  Test 4: 大 buffer 拼接
// ============================================================

static void test_large_buffer(const std::string& caBundle) {
    std::string body, errKind, errMsg;
    int rc = download::DownloadEngine::instance().fetchToBuffer(
        "https://httpbin.org/bytes/1048576",   // 1 MB
        {},
        30,
        body, errKind, errMsg);
    bool ok = (rc == 0 && body.size() == 1048576);
    appendResult("test_large_buffer_1mb", ok,
        "rc=" + std::to_string(rc) + " bytes=" + std::to_string(body.size()));
}

// ============================================================
//  Test 5: 超时
// ============================================================

static void test_timeout(const std::string& caBundle) {
    std::string body, errKind, errMsg;
    auto start = std::chrono::steady_clock::now();
    int rc = download::DownloadEngine::instance().fetchToBuffer(
        "https://httpbin.org/delay/30",   // 服务器延迟 30s
        {},
        2,                                 // 客户端超时 2s
        body, errKind, errMsg);
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    bool ok = (rc != 0 && elapsed < 5);
    appendResult("test_timeout_2s", ok,
        "rc=" + std::to_string(rc) + " elapsed=" + std::to_string(elapsed) + "s");
}

// ============================================================
//  Test 6: 空响应
// ============================================================

static void test_empty_response(const std::string& caBundle) {
    std::string body, errKind, errMsg;
    int rc = download::DownloadEngine::instance().fetchToBuffer(
        "https://httpbin.org/status/204",   // No Content
        {},
        10,
        body, errKind, errMsg);
    // 204 应当算成功，body 为空
    bool ok = (rc == 0 && body.empty());
    appendResult("test_empty_response_204", ok,
        "rc=" + std::to_string(rc) + " bytes=" + std::to_string(body.size())
        + " kind=" + errKind);
}

// ============================================================
//  入口
// ============================================================

extern "C" const char* runDownloadTextFetchTests(const char* caBundlePath) {
    g_fetch_results.clear();
    g_fetch_results += "=== fetchToBuffer Tests (Phase 3) ===\n";
    g_fetch_results += "caBundle: ";
    g_fetch_results += (caBundlePath ? caBundlePath : "<null>");
    g_fetch_results += "\n";

    if (!caBundlePath || caBundlePath[0] == '\0') {
        g_fetch_results += "❌ ABORT: caBundlePath is empty, all HTTPS will fail.\n";
        g_fetch_results += "Hint: 调用前先 DownloadManager.initializeCaBundle\n";
        return g_fetch_results.c_str();
    }

    std::string ca(caBundlePath);
    test_single_url_200(ca);
    test_multi_mirror_fallback(ca);
    test_all_mirrors_fail(ca);
    test_large_buffer(ca);
    test_timeout(ca);
    test_empty_response(ca);

    g_fetch_results += "=== End of fetchToBuffer Tests ===\n";
    return g_fetch_results.c_str();
}

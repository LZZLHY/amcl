/**
 * sha1_incremental_test.cpp — Phase 4 (增量 SHA1) 验证测试
 *
 * 现状：download/sha1.h 的 Sha1 类已支持 update + finalizeHex 增量更新。
 * 本文件验证：
 *   1. 单 chunk 与多 chunk 输入的 hash 结果一致
 *   2. 边界情况：空数据、单字节、64 字节边界、跨 64 字节
 *   3. RFC 3174 标准测试向量
 *
 * Phase 4 实施时还会新增：
 *   - 接入 NetThread::onWrite 增量更新
 *   - 仅 piece_count == 1 启用
 *   - 与一次性计算结果一致
 *
 * TDD 红阶段说明：
 *   现有 Sha1 类已存在，本测试可立即跑（不属于"接口未实现"的红状态）。
 *   此测试主要锁定行为，让 Phase 4.3 的 NetThread 改造不会破坏 Sha1 行为。
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 4
 *
 * 创建日期：2026-05-05
 */

#include "download_tests.h"
#include "../sha1.h"

#include <cstring>
#include <string>
#include <vector>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "SHA1_INC_TEST"
// LOG_APP 是 hilog 头里的 LogType enum (= 0)，不要重定义

static std::string g_sha1_results;

static void appendResult(const char* testName, bool success, const std::string& detail) {
    g_sha1_results += testName;
    g_sha1_results += ": ";
    g_sha1_results += success ? "✅ PASS" : "❌ FAIL";
    g_sha1_results += " (";
    g_sha1_results += detail;
    g_sha1_results += ")\n";
    OH_LOG_INFO(LOG_APP, "[%{public}s] %{public}s - %{public}s",
                testName, success ? "PASS" : "FAIL", detail.c_str());
}

static std::string sha1OfFull(const uint8_t* data, size_t len) {
    download::Sha1 ctx;
    ctx.update(data, len);
    return ctx.finalizeHex();
}

static std::string sha1Chunked(const uint8_t* data, size_t len, size_t chunk_size) {
    download::Sha1 ctx;
    size_t pos = 0;
    while (pos < len) {
        size_t take = std::min(chunk_size, len - pos);
        ctx.update(data + pos, take);
        pos += take;
    }
    return ctx.finalizeHex();
}

// ============================================================
//  Test 1: RFC 3174 标准测试向量
// ============================================================

static void test_rfc3174_abc() {
    const char* msg = "abc";
    std::string h = sha1OfFull(reinterpret_cast<const uint8_t*>(msg), 3);
    const char* expected = "a9993e364706816aba3e25717850c26c9cd0d89d";
    bool ok = (h == expected);
    appendResult("test_rfc3174_abc", ok,
        "expected=" + std::string(expected) + " actual=" + h);
}

static void test_rfc3174_empty() {
    std::string h = sha1OfFull(nullptr, 0);
    const char* expected = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    bool ok = (h == expected);
    appendResult("test_rfc3174_empty", ok,
        "expected=" + std::string(expected) + " actual=" + h);
}

static void test_rfc3174_long_string() {
    // "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    const char* msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    std::string h = sha1OfFull(reinterpret_cast<const uint8_t*>(msg), 56);
    const char* expected = "84983e441c3bd26ebaae4aa1f95129e5e54670f1";
    bool ok = (h == expected);
    appendResult("test_rfc3174_long_string", ok,
        "expected=" + std::string(expected) + " actual=" + h);
}

// ============================================================
//  Test 2: 增量一致性（核心 Phase 4 验证）
// ============================================================

static void test_incremental_consistency_1mb() {
    // 1 MB 伪随机数据（确定性）
    const size_t SIZE = 1024 * 1024;
    std::vector<uint8_t> data(SIZE);
    for (size_t i = 0; i < SIZE; ++i) {
        data[i] = static_cast<uint8_t>((i * 31 + 7) & 0xFF);
    }
    std::string full = sha1OfFull(data.data(), SIZE);
    std::string chunked = sha1Chunked(data.data(), SIZE, 4096);
    bool ok = (full == chunked);
    appendResult("test_incremental_1mb_4kb_chunks", ok,
        std::string("full=") + full + " chunked=" + chunked);
}

static void test_incremental_byte_by_byte() {
    const char* msg = "The quick brown fox jumps over the lazy dog";
    size_t len = std::strlen(msg);
    std::string full = sha1OfFull(reinterpret_cast<const uint8_t*>(msg), len);
    std::string byByte = sha1Chunked(reinterpret_cast<const uint8_t*>(msg), len, 1);
    bool ok = (full == byByte);
    appendResult("test_incremental_byte_by_byte", ok,
        std::string("full=") + full + " byByte=" + byByte);
}

static void test_incremental_64byte_boundary() {
    // SHA-1 的 block 是 64 字节，测试跨 block 边界
    const size_t SIZE = 64 * 5;
    std::vector<uint8_t> data(SIZE);
    for (size_t i = 0; i < SIZE; ++i) data[i] = static_cast<uint8_t>(i);
    std::string full = sha1OfFull(data.data(), SIZE);
    // 用 63 字节 chunk 强制跨 64 边界
    std::string chunked = sha1Chunked(data.data(), SIZE, 63);
    bool ok = (full == chunked);
    appendResult("test_incremental_64byte_boundary", ok,
        std::string("full=") + full + " chunked=" + chunked);
}

static void test_incremental_random_chunk_sizes() {
    const size_t SIZE = 100000;
    std::vector<uint8_t> data(SIZE);
    for (size_t i = 0; i < SIZE; ++i) data[i] = static_cast<uint8_t>((i * 7 + 13) & 0xFF);
    std::string full = sha1OfFull(data.data(), SIZE);

    // 用伪随机但确定性的 chunk size
    download::Sha1 ctx;
    size_t pos = 0;
    size_t prng = 12345;
    while (pos < SIZE) {
        prng = prng * 1103515245 + 12345;
        size_t chunk = (prng % 10000) + 1;
        if (pos + chunk > SIZE) chunk = SIZE - pos;
        ctx.update(data.data() + pos, chunk);
        pos += chunk;
    }
    std::string randChunked = ctx.finalizeHex();
    bool ok = (full == randChunked);
    appendResult("test_incremental_random_chunks", ok,
        std::string("full=") + full + " rand=" + randChunked);
}

// ============================================================
//  Test 3: 边界条件
// ============================================================

static void test_zero_length_update() {
    download::Sha1 ctx;
    ctx.update(nullptr, 0);
    ctx.update(nullptr, 0);
    std::string h = ctx.finalizeHex();
    const char* expected = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    bool ok = (h == expected);
    appendResult("test_zero_length_update", ok,
        "expected=" + std::string(expected) + " actual=" + h);
}

static void test_single_byte() {
    uint8_t b = 'a';
    std::string h = sha1OfFull(&b, 1);
    const char* expected = "86f7e437faa5a7fce15d1ddcb9eaeaea377667b8";
    bool ok = (h == expected);
    appendResult("test_single_byte", ok,
        "expected=" + std::string(expected) + " actual=" + h);
}

// ============================================================
//  C-3 回归测试：finalizeHex 幂等性 + reset() 可复用
// ============================================================

// 二次调用 finalizeHex 必须返回相同结果（之前的实现会越界写 buffer_[64]）
static void test_finalize_idempotent() {
    download::Sha1 ctx;
    const char* msg = "abc";
    ctx.update(msg, 3);
    std::string h1 = ctx.finalizeHex();
    std::string h2 = ctx.finalizeHex();
    std::string h3 = ctx.finalizeHex();
    const char* expected = "a9993e364706816aba3e25717850c26c9cd0d89d";
    bool ok = (h1 == expected) && (h1 == h2) && (h2 == h3) && ctx.finalized();
    appendResult("test_finalize_idempotent", ok,
        "h1=" + h1 + " h2=" + h2 + " h3=" + h3);
}

// finalize 之后再 update 必须被忽略（不腐蚀缓存结果）
static void test_update_after_finalize_ignored() {
    download::Sha1 ctx;
    ctx.update("abc", 3);
    std::string before = ctx.finalizeHex();
    ctx.update("xyz", 3);  // 应被忽略
    std::string after = ctx.finalizeHex();
    bool ok = (before == after) && (before == "a9993e364706816aba3e25717850c26c9cd0d89d");
    appendResult("test_update_after_finalize_ignored", ok,
        "before=" + before + " after=" + after);
}

// reset() 必须把 hasher 恢复到可以重新计算新数据的状态
static void test_reset_allows_reuse() {
    download::Sha1 ctx;
    ctx.update("abc", 3);
    ctx.finalizeHex();           // finalized = true
    ctx.reset();                 // 应清掉 finalized + cached + buffer
    bool not_finalized = !ctx.finalized();
    ctx.update("hello", 5);
    std::string h = ctx.finalizeHex();
    // sha1("hello") = aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d
    const char* expected = "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d";
    bool ok = not_finalized && (h == expected);
    appendResult("test_reset_allows_reuse", ok,
        "after_reset_finalized=" + std::to_string(ctx.finalized()) + " h=" + h);
}

// ============================================================
//  入口
// ============================================================

extern "C" const char* runSha1IncrementalTests() {
    g_sha1_results.clear();
    g_sha1_results += "=== SHA-1 Incremental Tests (Phase 4) ===\n";

    test_rfc3174_abc();
    test_rfc3174_empty();
    test_rfc3174_long_string();
    test_incremental_consistency_1mb();
    test_incremental_byte_by_byte();
    test_incremental_64byte_boundary();
    test_incremental_random_chunk_sizes();
    test_zero_length_update();
    test_single_byte();
    // C-3 回归
    test_finalize_idempotent();
    test_update_after_finalize_ignored();
    test_reset_allows_reuse();

    g_sha1_results += "=== End of SHA-1 Tests ===\n";
    return g_sha1_results.c_str();
}

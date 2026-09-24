/**
 * source_scoring_test.cpp — Phase 8 (源打分加权) 单元测试
 *
 * TDD 红阶段：本文件先于 NetSource 的 RTT / throughput 滑动窗口实现。
 *
 * 当前编译预期：链接失败 — 以下方法尚未在 net_source.{h,cpp} 中实现：
 *   - NetSource::recordSample(rtt_ms, throughput_bps)
 *   - NetSource::avgRttMs() / avgThroughputBps()
 *   - NetSource::computeScore()
 *   - pickBestSourceWeighted(sources)
 *
 * 覆盖范围（纯内存逻辑，零网络）：
 *   - 滑动窗口正确性（容量、新值覆盖最老值）
 *   - 平均值计算（空窗口、单值、多值）
 *   - score 算法符合预期排序
 *   - 多源排序（低 RTT + 高吞吐 + 低 fail_count 胜出）
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 8
 *
 * 创建日期：2026-05-05
 */

#include "download_tests.h"
#include "../net_source.h"

#include <algorithm>
#include <memory>
#include <string>
#include <vector>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "SCORE_TEST"
// LOG_APP 是 hilog 头里的 LogType enum (= 0)，不要重定义

static std::string g_score_results;

static void appendResult(const char* testName, bool success, const std::string& detail) {
    g_score_results += testName;
    g_score_results += ": ";
    g_score_results += success ? "✅ PASS" : "❌ FAIL";
    g_score_results += " (";
    g_score_results += detail;
    g_score_results += ")\n";
    OH_LOG_INFO(LOG_APP, "[%{public}s] %{public}s - %{public}s",
                testName, success ? "PASS" : "FAIL", detail.c_str());
}

// ============================================================
//  Test 1: 滑动窗口
// ============================================================

static void test_empty_window_avg() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    // Phase 8 待实现：avgRttMs / avgThroughputBps
    int avgRtt = src->avgRttMs();
    double avgThr = src->avgThroughputBps();
    bool ok = (avgRtt == -1 && avgThr <= 0.0);
    appendResult("test_empty_window_returns_unknown", ok,
        "avgRtt=" + std::to_string(avgRtt) + " avgThr=" + std::to_string(avgThr));
}

static void test_single_sample() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    src->recordSample(100, 1024.0 * 1024.0);  // 100ms RTT, 1MB/s
    int avgRtt = src->avgRttMs();
    bool ok = (avgRtt == 100);
    appendResult("test_single_sample", ok, "avgRtt=" + std::to_string(avgRtt));
}

static void test_window_average() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    src->recordSample(100, 1.0);
    src->recordSample(200, 1.0);
    src->recordSample(300, 1.0);
    int avg = src->avgRttMs();
    bool ok = (avg == 200);
    appendResult("test_window_average", ok, "avgRtt=" + std::to_string(avg));
}

static void test_window_capacity_overflow() {
    auto src = std::make_shared<download::NetSource>("https://a/x");
    // 假设窗口容量 ≤ 16，写 20 个样本应只保留最新的 16
    for (int i = 0; i < 20; ++i) {
        src->recordSample(100 + i, 1.0);
    }
    int avg = src->avgRttMs();
    // 不强求知道窗口容量；至少应排除最早的几个低值
    bool ok = (avg >= 110);  // 20 个值 110-119 平均 ~115
    appendResult("test_window_capacity_overflow", ok,
        "avg=" + std::to_string(avg) + " (expected >= 110, latest samples drop oldest)");
}

// ============================================================
//  Test 2: 评分算法
// ============================================================

static void test_score_lower_rtt_wins() {
    auto fast = std::make_shared<download::NetSource>("https://fast/x");
    auto slow = std::make_shared<download::NetSource>("https://slow/x");
    fast->recordSample(50, 1024.0 * 1024.0);
    slow->recordSample(500, 1024.0 * 1024.0);
    double sFast = fast->computeScore();
    double sSlow = slow->computeScore();
    bool ok = (sFast < sSlow);  // 越低越好
    appendResult("test_score_lower_rtt_wins", ok,
        "fast=" + std::to_string(sFast) + " slow=" + std::to_string(sSlow));
}

static void test_score_higher_throughput_wins() {
    auto hi = std::make_shared<download::NetSource>("https://hi/x");
    auto lo = std::make_shared<download::NetSource>("https://lo/x");
    hi->recordSample(100, 10.0 * 1024.0 * 1024.0);  // 10 MB/s
    lo->recordSample(100, 1.0 * 1024.0 * 1024.0);   //  1 MB/s
    double sHi = hi->computeScore();
    double sLo = lo->computeScore();
    bool ok = (sHi < sLo);  // 高吞吐分数更低（更优）
    appendResult("test_score_higher_throughput_wins", ok,
        "hi=" + std::to_string(sHi) + " lo=" + std::to_string(sLo));
}

static void test_score_failure_penalty() {
    auto good = std::make_shared<download::NetSource>("https://good/x");
    auto bad = std::make_shared<download::NetSource>("https://bad/x");
    good->recordSample(100, 1.0 * 1024.0 * 1024.0);
    bad->recordSample(100, 1.0 * 1024.0 * 1024.0);
    bad->fail_count.store(2);
    double sGood = good->computeScore();
    double sBad = bad->computeScore();
    bool ok = (sGood < sBad);
    appendResult("test_score_failure_penalty", ok,
        "good=" + std::to_string(sGood) + " bad=" + std::to_string(sBad));
}

static void test_score_no_data_neutral() {
    // 无数据时应返回中性分数（既不极优也不极差）
    auto neutral = std::make_shared<download::NetSource>("https://neutral/x");
    auto good = std::make_shared<download::NetSource>("https://good/x");
    good->recordSample(50, 10.0 * 1024.0 * 1024.0);
    double sNeutral = neutral->computeScore();
    double sGood = good->computeScore();
    // Neutral 应比 good 差，但不应是 +Infinity
    bool ok = (sNeutral > sGood && sNeutral < 1e9);
    appendResult("test_score_no_data_neutral", ok,
        "neutral=" + std::to_string(sNeutral) + " good=" + std::to_string(sGood));
}

// ============================================================
//  Test 3: 多源排序（pickBestSourceWeighted）
// ============================================================

static void test_pick_best_among_three() {
    auto a = std::make_shared<download::NetSource>("https://a/x");
    auto b = std::make_shared<download::NetSource>("https://b/x");
    auto c = std::make_shared<download::NetSource>("https://c/x");

    a->recordSample(200, 1.0 * 1024.0 * 1024.0);
    b->recordSample(50,  5.0 * 1024.0 * 1024.0);  // 最优
    c->recordSample(100, 2.0 * 1024.0 * 1024.0);

    std::vector<download::NetSourcePtr> sources = { a, b, c };
    download::NetSourcePtr best = download::pickBestSourceWeighted(sources);
    bool ok = (best && best->url == "https://b/x");
    appendResult("test_pick_best_among_three", ok,
        std::string("best.url=") + (best ? best->url : "null"));
}

static void test_pick_skips_failed() {
    auto a = std::make_shared<download::NetSource>("https://a/x");
    auto b = std::make_shared<download::NetSource>("https://b/x");
    a->is_failed.store(true);
    b->recordSample(500, 0.5 * 1024.0 * 1024.0);  // 慢但可用
    std::vector<download::NetSourcePtr> sources = { a, b };
    download::NetSourcePtr best = download::pickBestSourceWeighted(sources);
    bool ok = (best && best->url == "https://b/x");
    appendResult("test_pick_skips_failed", ok,
        std::string("best.url=") + (best ? best->url : "null"));
}

static void test_pick_all_failed_returns_null() {
    auto a = std::make_shared<download::NetSource>("https://a/x");
    auto b = std::make_shared<download::NetSource>("https://b/x");
    a->is_failed.store(true);
    b->is_failed.store(true);
    std::vector<download::NetSourcePtr> sources = { a, b };
    download::NetSourcePtr best = download::pickBestSourceWeighted(sources);
    bool ok = (best == nullptr);
    appendResult("test_pick_all_failed_returns_null", ok,
        best ? "got non-null" : "got null (expected)");
}

static void test_pick_empty_returns_null() {
    std::vector<download::NetSourcePtr> sources;
    download::NetSourcePtr best = download::pickBestSourceWeighted(sources);
    bool ok = (best == nullptr);
    appendResult("test_pick_empty_returns_null", ok, ok ? "ok" : "fail");
}

// ============================================================
//  Test 4: 死循环防护（任何分数都不能让某源永久饿死）
// ============================================================

static void test_starvation_protection() {
    // 所有源失败次数较高时，仍应返回最少失败的
    auto a = std::make_shared<download::NetSource>("https://a/x");
    auto b = std::make_shared<download::NetSource>("https://b/x");
    a->fail_count.store(10);
    b->fail_count.store(2);
    a->recordSample(50, 5.0 * 1024.0 * 1024.0);
    b->recordSample(500, 0.5 * 1024.0 * 1024.0);
    // 即使 a 速度更快，若 fail_count 差距足够大，b 应胜
    std::vector<download::NetSourcePtr> sources = { a, b };
    download::NetSourcePtr best = download::pickBestSourceWeighted(sources);
    bool ok = (best && best->url == "https://b/x");
    appendResult("test_starvation_high_failure_penalty", ok,
        std::string("best=") + (best ? best->url : "null"));
}

// ============================================================
//  入口
// ============================================================

extern "C" const char* runSourceScoringTests() {
    g_score_results.clear();
    g_score_results += "=== Source Scoring Tests (Phase 8) ===\n";

    test_empty_window_avg();
    test_single_sample();
    test_window_average();
    test_window_capacity_overflow();
    test_score_lower_rtt_wins();
    test_score_higher_throughput_wins();
    test_score_failure_penalty();
    test_score_no_data_neutral();
    test_pick_best_among_three();
    test_pick_skips_failed();
    test_pick_all_failed_returns_null();
    test_pick_empty_returns_null();
    test_starvation_protection();

    g_score_results += "=== End of Source Scoring Tests ===\n";
    return g_score_results.c_str();
}

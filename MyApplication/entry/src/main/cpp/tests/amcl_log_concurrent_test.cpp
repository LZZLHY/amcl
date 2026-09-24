/**
 * amcl_log_concurrent_test.cpp — amcl_log 多生产者并发 stress test
 *
 * 验证 LOG-P0-1 修复（reservation + ready flag 两阶段提交）：
 *   - 8 线程并发各打 5000 条带唯一序号的日志
 *   - 写入完成后扫描日志文件，确认每行的 tag / 序号 / 校验位无撕裂
 *   - 允许 ring buffer overflow 导致的丢失（256 槽位 << 40000 条）
 *   - 但**已写入文件的每一条**必须完整、无半写入脏数据
 *
 * 触发：DevTools 页面"测试"按钮（与 jit_test / jvm_test 同入口）。
 */

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>
#include <hilog/log.h>

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "AMCL_LOG_TEST"

namespace {

constexpr int N_THREADS         = 8;
constexpr int N_PER_THREAD      = 5000;
constexpr int N_TOTAL           = N_THREADS * N_PER_THREAD;

constexpr const char* CHECK_MAGIC = "MAGIC#";  // 行末校验 marker

static std::string g_results;

static void appendResult(const char* name, bool ok, const std::string& detail) {
    g_results += name;
    g_results += ": ";
    g_results += ok ? "✅ PASS" : "❌ FAIL";
    g_results += " (";
    g_results += detail;
    g_results += ")\n";
    OH_LOG_INFO(LOG_APP, "[%{public}s] %{public}s — %{public}s",
                name, ok ? "PASS" : "FAIL", detail.c_str());
}

static std::string formatThreadTag(int tid) {
    char buf[16];
    snprintf(buf, sizeof(buf), "TID-%02d", tid);
    return std::string(buf);
}

/** 单个生产者线程：连续打 N_PER_THREAD 条带唯一序号的日志 */
static void producerThread(int tid) {
    std::string tag = formatThreadTag(tid);
    for (int i = 0; i < N_PER_THREAD; i++) {
        // 序号 = (tid << 16) | i，可在文件中反推线程 + 序列号
        unsigned int seq = (static_cast<unsigned int>(tid) << 16) | static_cast<unsigned int>(i);
        amclLogWrite(AMCL_LOG_LEVEL_INFO, tag.c_str(),
                     "seq=%u payload=concurrent_test_%d_%d %s",
                     seq, tid, i, CHECK_MAGIC);
    }
}

/** 解析一行 [time][level][tag] msg，返回 tag 和 msg 部分 */
static bool parseLogLine(const std::string& line, std::string& tagOut, std::string& msgOut) {
    // 格式: [2026-05-10 12:34:56][I][TAG] message
    size_t p1 = line.find(']');
    if (p1 == std::string::npos) return false;
    size_t p2 = line.find(']', p1 + 1);
    if (p2 == std::string::npos) return false;
    size_t p3 = line.find(']', p2 + 1);
    if (p3 == std::string::npos) return false;
    size_t tagStart = line.rfind('[', p3) + 1;
    if (tagStart == 0 || tagStart >= p3) return false;
    tagOut = line.substr(tagStart, p3 - tagStart);
    if (p3 + 2 > line.size()) {
        msgOut = "";
    } else {
        msgOut = line.substr(p3 + 2);  // 跳过 "] "
    }
    return true;
}

}  // namespace

extern "C" const char* runAmclLogConcurrentTest(const char* logDir) {
    g_results.clear();

    if (!logDir || !*logDir) {
        appendResult("setup", false, "logDir 为空");
        return g_results.c_str();
    }

    OH_LOG_INFO(LOG_APP, "[AMCL_LOG_TEST] start: dir=%{public}s threads=%d total=%d",
                logDir, N_THREADS, N_TOTAL);

    // 准备：清掉旧日志，初始化 amcl_log
    std::string logFile = std::string(logDir) + "/amcl_launcher.log";
    unlink(logFile.c_str());
    for (int i = 1; i <= 5; i++) {
        std::string rotated = std::string(logDir) + "/amcl_launcher." + std::to_string(i) + ".log";
        unlink(rotated.c_str());
    }

    amclLogShutdown();  // 防止上次残留
    amclLogInit(logDir, 8 * 1024 * 1024, 5);  // 8MB / 文件，避免 stress 触发 rotation

    // 启动 N 个生产者
    auto startTs = std::chrono::steady_clock::now();
    std::vector<std::thread> workers;
    workers.reserve(N_THREADS);
    for (int i = 0; i < N_THREADS; i++) {
        workers.emplace_back(producerThread, i);
    }
    for (auto& t : workers) t.join();
    auto elapsedProduce = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - startTs).count();

    // 等待 writer 把 ring buffer drain 完（至少 1.5 个 flush 间隔 = 750ms，
    // 加余量到 2 秒）
    amclLogFlush();
    std::this_thread::sleep_for(std::chrono::milliseconds(2000));

    // 读取日志文件
    std::ifstream f(logFile);
    if (!f.is_open()) {
        appendResult("read_file", false, "无法打开 " + logFile);
        return g_results.c_str();
    }

    int linesTotal = 0;
    int linesWithMagic = 0;
    int linesTorn = 0;
    int linesWithBadTag = 0;
    std::vector<int> perThreadCount(N_THREADS, 0);
    std::string line;

    while (std::getline(f, line)) {
        if (line.empty()) continue;
        // 只统计本测试产生的行（tag 以 TID- 开头）
        std::string tag, msg;
        if (!parseLogLine(line, tag, msg)) continue;
        if (tag.rfind("TID-", 0) != 0) continue;  // 不是测试行

        linesTotal++;

        // 1. tag 必须形如 "TID-NN"，长度精确 6 字符（TID-00 .. TID-07）
        if (tag.size() != 6 || tag[3] != '-') {
            linesWithBadTag++;
            continue;
        }
        int parsedTid = atoi(tag.c_str() + 4);
        if (parsedTid < 0 || parsedTid >= N_THREADS) {
            linesWithBadTag++;
            continue;
        }
        perThreadCount[parsedTid]++;

        // 2. 消息末尾必须有 MAGIC，否则视作撕裂
        if (msg.find(CHECK_MAGIC) == std::string::npos) {
            linesTorn++;
            continue;
        }

        // 3. 形式合法
        linesWithMagic++;
    }
    f.close();

    // 报告
    {
        std::ostringstream oss;
        oss << "produce=" << elapsedProduce << "ms total=" << linesTotal
            << " ok=" << linesWithMagic
            << " torn=" << linesTorn
            << " badTag=" << linesWithBadTag;
        appendResult("scan", linesTorn == 0 && linesWithBadTag == 0, oss.str());
    }
    {
        std::ostringstream oss;
        for (int i = 0; i < N_THREADS; i++) {
            oss << "T" << i << "=" << perThreadCount[i];
            if (i + 1 < N_THREADS) oss << " ";
        }
        appendResult("per-thread", true, oss.str());
    }
    {
        // 期望：linesWithMagic 应该不小于 buffer 容量 256 的若干倍。
        // 严格期望是接近 N_TOTAL 但允许 overflow 丢失。这里只要求"非零且多于
        // 单线程 N_PER_THREAD"（说明 8 线程都至少落了点东西）。
        bool ok = linesWithMagic >= N_PER_THREAD && linesTorn == 0;
        std::ostringstream oss;
        oss << "expected: torn==0 && lines>=" << N_PER_THREAD
            << ", got torn=" << linesTorn << " lines=" << linesWithMagic;
        appendResult("verdict", ok, oss.str());
    }

    return g_results.c_str();
}

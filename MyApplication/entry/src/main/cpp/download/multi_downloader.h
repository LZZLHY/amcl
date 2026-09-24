/**
 * download/multi_downloader.h — v4.5 curl_multi 事件循环下载器
 *
 * 专为小文件（assets 等 < 1MB）设计，单线程事件循环驱动多路并发：
 *   - 1 个事件循环线程 + 1 个 CURLM* multi handle
 *   - 最多 max_concurrent 个并发 CURL* easy handles
 *   - **每个 transfer 独立 TCP 连接**（CURLOPT_HTTP_VERSION=CURL_HTTP_VERSION_NONE，
 *     让 curl 自行协商；多数 BMCLAPI/CDN 镜像目前仅协商到 HTTP/1.1）
 *   - 通过 curl_share 复用 DNS 缓存（仅 CURL_LOCK_DATA_DNS；SSL session 不共享，
 *     因 BMCLAPI CDN 多节点 IP 漂移会导致 ticket hostname mismatch。见 Engine::curlShare）
 *
 * 设计变更历史（重要！别被旧文档误导）：
 *   - 早期 v4.5 设计目标是 HTTP/2 多路复用、64 并发 → 1-2 条 TCP，但实测
 *     BMCLAPI / 多数镜像不支持或不稳定，于是 v4.5b 起明确放弃强制 HTTP/2，
 *     采用 v2 ArkTS 同构的"64 条独立 HTTP/1.1 连接"模型。
 *   - 这里保留 multi handle 主要是因为：
 *       (a) 单线程事件循环比 64 个 worker 线程内存/上下文切换更省；
 *       (b) curl_multi_poll 比 select/poll 自管 socket 更省事；
 *       (c) 失败收敛、wait 入队都能在一个线程里串行做。
 *
 * 与 NetThread 的关系：
 *   MultiDownloader 操作的仍然是 NetThread 对象。它接管了 NetThread 中
 *   curl_easy_init / setopt / perform / cleanup 的职责，但 NetThread 的
 *   fd 管理、source 选择、错误处理、状态汇报等逻辑仍然由 NetThread 自身完成。
 *
 * 生命周期：
 *   1. Engine::startTask() 把小文件的 NetThread 推入 MultiDownloader::enqueue()
 *   2. MultiDownloader 事件循环线程取出 NetThread，配置 easy handle，加入 multi
 *   3. curl_multi_poll + curl_multi_perform 驱动所有传输
 *   4. 传输完成时回调 NetThread 的成功/失败逻辑
 *   5. Engine::shutdown() 调 MultiDownloader::shutdown() 停止事件循环
 *
 * 线程安全：
 *   - enqueue() 从任意线程调用（Engine::startTask 线程）
 *   - 事件循环在独立线程运行
 *   - 内部用 mu_ + cv_ 保护 pending queue
 */
#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <curl/curl.h>

#include "net_thread.h"

namespace download {

class NetFile;

class MultiDownloader {
public:
    struct Config {
        /**
         * 全局并发上限。对齐 PCL2 `NetTaskThreadLimit = Settings("ToolDownloadThread") + 1`
         * （默认 63 + 1 = 64，见 ModNet.vb:387-389）。
         */
        int  max_concurrent = 64;

        // ⚠️ 2026-08-04：这两个值原来是 4 / 8，是 assets「4~5 个文件/秒」的**唯一元凶**。
        //
        //   4750 个 asset 全部来自同一个 host（bmclapi2.bangbang93.com），于是有效并发被
        //   钉在 8：真机实测单连接吞吐 avg 1792 KB/s、ttfb 388ms 都很正常，但每秒只完成
        //   4~5 个文件，4750 个要跑 16 分钟以上。
        //
        //   **PCL2 根本没有 per-host 并发上限**（ModNet.vb:1820-1842 的 ThreadStarter 只查
        //   全局 `NetTaskThreadCount >= NetTaskThreadLimit`），它靠的是"启动一条 bmclapi
        //   线程后 Thread.Sleep(100)"来控制**请求频率**而不是并发数；而且它有两个
        //   ThreadStarter 交错（按 `File.Uuid Mod 2` 分片），所以有效间隔约 50ms。
        //
        //   现在对齐 PCL2：稳态上限 = 全局上限（等价于"无 per-host 上限"），改用下面的
        //   `throttled_host_start_interval_ms` 做频率节流。这两个字段**只保留**给
        //   429 触发的自适应收缩当下限保护用（那是 PCL2 没有的额外保险）。
        int  initial_host_concurrent = 64;
        int  max_host_concurrent = 64;

        /**
         * 受限主机的**新连接最小启动间隔**（毫秒）。对齐 PCL2：
         *   `If NewThread.Source.Url.Contains("bmclapi") Then Thread.Sleep(100)`
         *   × 两个 ThreadStarter 交错 ⇒ 有效 ~50ms/条。
         *
         * 与 PCL2 的实现差异（语义等价、必要）：PCL2 是在启动线程的那个线程里直接 sleep，
         * AMCL 的 feedTransfers 跑在**唯一的 curl_multi 事件循环线程**上，在那里 sleep 会
         * 同时冻结所有正在传输的连接。所以改为记录"该主机下次允许启动的时刻"，未到就把
         * 候选留到下一轮（事件循环 50ms 一轮），不阻塞任何在途传输。
         */
        int  throttled_host_start_interval_ms = 50;

        int  connect_timeout_s = 5;     // 小文件连接超时（秒）
        int  total_timeout_s = 30;      // 小文件总超时（秒）
        int  low_speed_limit = 1024;    // 低速阈值 bytes/s
        int  low_speed_time_s = 10;     // 低速持续时间（秒）
    };

    MultiDownloader();
    explicit MultiDownloader(const Config& cfg);
    ~MultiDownloader();

    MultiDownloader(const MultiDownloader&) = delete;
    MultiDownloader& operator=(const MultiDownloader&) = delete;

    /** 启动事件循环线程 */
    void start();

    /** 停止事件循环，等待线程退出 */
    void shutdown();

    /** 批量入队待下载的 NetThread（线程安全，可从任意线程调用） */
    void enqueue(std::vector<NetThreadPtr> threads);

    /** 当前正在传输的数量 */
    int activeCount() const { return active_count_.load(std::memory_order_relaxed); }

    /** 是否已启动 */
    bool isRunning() const { return running_.load(std::memory_order_relaxed); }

private:
    Config cfg_;
    std::atomic<bool> running_{false};
    std::atomic<int>  active_count_{0};

    // 事件循环线程
    std::thread loop_thread_;

    // 待下载队列按 task id 做一任务一轮 round-robin；task 0 为兼容队列。
    std::mutex mu_;
    std::condition_variable cv_;
    std::unordered_map<uint64_t, std::deque<NetThreadPtr>> pending_by_task_;
    std::deque<uint64_t> pending_task_order_;
    size_t pending_count_{0};

    // curl multi handle
    CURLM* multi_ = nullptr;

    // 每个 easy handle 对应的上下文
    struct TransferCtx {
        CURL*          easy = nullptr;
        NetThreadPtr   thread;
        NetSourcePtr   source;
        std::string    host;
        std::string    actual_url;       // 当前请求的 URL（可能经过 302 重定向）
        int64_t        retry_after_ms = 0;
        int64_t        requested_offset = 0;
        bool           range_requested = false;
        bool           content_range_seen = false;
        bool           content_range_valid = false;
        int64_t        content_range_start = -1;
        int64_t        content_range_end = -1;
        int64_t        content_range_total = -1;
        curl_off_t downloaded_bytes = 0;
        curl_off_t total_time_us = 0;
        curl_off_t connect_time_us = 0;
        bool           fd_acquired = false;
        char           err_buf[CURL_ERROR_SIZE] = {0};
        // M-2 修复：header callback 监测 302 Location 头时记录被拦截的 bad host，
        // handleFailure 看到 abort_reason_bad_host 时不再走通用 timeout 路径，
        // 直接换源重试。
        std::string    abort_reason_bad_host;
        // 本次 transfer 实际使用的 CURLOPT_IPRESOLVE 与打分用的主机 key
        //（见 DownloadEngine::ipResolveFor / noteFamilyOutcome）。
        std::string    family_host;
        long           family_resolve = CURL_IPRESOLVE_WHATEVER;
    };

    // M-2 修复：header callback，拦截 302→bad host 重定向。
    // 在 Location 头到达时检查目标主机是否在 Engine::isBadHost；命中返回 0
    // 让 curl 报 CURLE_WRITE_ERROR，handleFailure 看 abort_reason_bad_host
    // 直接换源，避免 connect timeout 浪费 5-10s。
    static size_t onHeader(char* buffer, size_t size, size_t nitems, void* userdata);

    // easy handle → TransferCtx 映射
    std::unordered_map<CURL*, std::unique_ptr<TransferCtx>> transfers_;
    std::unordered_map<std::string, int> host_active_;
    std::unordered_map<std::string, int> host_limit_;
    std::unordered_map<std::string, int> host_success_streak_;
    /** 受限主机（bmclapi）下次允许启动新连接的 steady-clock 毫秒。见 Config 注释。 */
    std::unordered_map<std::string, int64_t> host_next_start_ms_;
    /**
     * 上一次 startTransfer 是否因**准入被推迟**而返回 false（并发已满 / 频率节流），
     * 区别于「终结」（成功/失败/取消）与「源 cooldown」。
     * 只在事件循环线程内读写，无需加锁。供 feedTransfers 做本轮早退。
     */
    bool throttle_deferred_ = false;

    // easy handle 对象池（避免频繁 init/cleanup）
    std::vector<CURL*> easy_pool_;

    CURL* acquireEasy();
    void  releaseEasy(CURL* easy);

    // 事件循环主函数
    void eventLoop();

    // 从 pending 队列取 NetThread，配置 easy handle，加入 multi
    void feedTransfers();

    // 处理已完成的传输
    void drainCompleted();

    // 为一个 NetThread 配置 easy handle 并加入 multi
    bool startTransfer(NetThreadPtr thread);

    // 处理单个传输完成
    void handleComplete(TransferCtx* ctx, CURLcode result);

    // 对单次 perform 结果做成功/失败判定
    void handleSuccess(TransferCtx* ctx);
    void handleFailure(TransferCtx* ctx, CURLcode rc, long http_code);

    // 重新入队让 feedTransfers 选新 source 重试
    void retryTransfer(TransferCtx* ctx);

    // pending 全部延迟时计算精确睡眠，避免事件循环轮询热转。
    int64_t pendingWaitMs() const;

    // 诊断统计
    std::atomic<int> stats_success_{0};
    std::atomic<int> stats_fail_{0};
    std::atomic<int> stats_retry_{0};
};

} // namespace download

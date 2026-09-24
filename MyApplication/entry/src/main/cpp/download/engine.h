/**
 * download/engine.h — v4.1 全局下载引擎（单例）
 *
 * === v4.1 设计复盘（2026-04-20）===
 *
 * 前代 v4 的教训：照搬 PCL2 `ThreadStarter` 里的 `Thread.Sleep(100)` bmclapi gate
 * 会在"大量小文件"场景（3805 个 ~200 KB asset）把稳态并发卡死在 ~6（启动速率
 * 20/s × 每 thread 耗时 0.3s），导致总耗时 6-8 分钟。PCL2 设计针对"少量大文件"
 * 的 libraries 场景，稳态早就靠 NetTaskThreadLimit=64 夹住了，gate 不是瓶颈。
 *
 * v2 ArkTS 下载器（2026-04-15）用 `slidingDownload` 证明了正确解法：
 *   - 冷启动每 100ms 启动一个任务（避免瞬时 N 个 TCP handshake burst）
 *   - 稳态"完成即补位"（thread done 后立即调度下一个，**无 sleep**）
 * 3805 asset 在 v2 下约 40 秒跑完。
 *
 * v4.1 = 把 v2 的策略用 C++ 实现，保留 C++ 的多源/多段/sha1/断点续传优势：
 *
 *   [WorkerPool × 64 threads]
 *        ↓ 每个 worker 从 pending_threads_ 队列 pop
 *        ↓ 冷启动 gate（仅当 active < cold_start_warm_threshold）：
 *            launch_gate_mu_ + last_launch_us_ 保证全局每 cold_start_interval_ms
 *            才启动一个新 thread。worm-up 完成后此分支不再进入。
 *        ↓ 稳态：无 sleep，pop 到就跑
 *        ↓ NetThread::run() 内部 curl_easy_init → perform → curl_easy_cleanup
 *            （per-thread handle 彻底规避 shared-easy 的 rc=43 bug）
 *
 * 被砍掉的（相对 v4 M1.5-1.7）：
 *   - 独立 dispatcher 线程（逻辑内联到 workerLoop）
 *   - task_thread_limit（= thread_pool_size，worker pool 自身就是上限）
 *   - 稳态 mirror gate（PCL2 糟粕，小文件场景严重拖累）
 *   - shared curl_easy handle（reset + setopt 栈指针残留 → rc=43）
 *   - 双 dispatcher 分治（事件驱动 worker pool 无需分治）
 *
 * 保留的 PCL2 精华：
 *   - 多源容错（NetFile 持多个 NetSource，首源失败切次源）
 *   - 多段并行（大文件分 pieces，每段一个 NetThread）
 *   - sha1 + size 校验（FileChecker）
 *   - 断点续传（.download-meta 文件 + Range 请求）
 *   - Retried 状态（per-source 达到上限后标记 Retried 兜底）
 *
 * 职责：
 *   1. 进程生命周期管理：
 *      - curl_global_init 一次（lazy，首次 createTask 时触发）
 *      - curl_global_cleanup 在 shutdown 时（进程退出前）
 *   2. WorkerPool：
 *      - 维护 N 个 std::thread（默认 64，对齐 v2 MAX_CONCURRENT）
 *      - 每个线程循环从 pending_threads_ 队列取 NetThreadPtr 执行 run()
 *      - 内联冷启动 ramp-up gate（见 workerLoop）
 *   3. 任务管理：
 *      - createTask(LoaderDownload::Config) → LoaderDownloadPtr
 *      - startTask / cancelTask
 *      - 查询活跃任务列表
 *   4. 定时任务（ticker 线程）：
 *      - 每 2 秒 flush 所有活跃 NetFile 的 meta 到磁盘
 *      - 每 200ms tickProgress 给所有活跃 LoaderDownload（触发 UI 回调）
 *
 * 线程模型：
 *   - workers_：64 个工作线程，跑 NetThread::run（阻塞 curl_easy_perform）
 *   - ticker_：1 个 ticker 线程，定时 tick progress + flush meta
 *   - 外部 API（createTask / startTask / cancelTask）thread-safe，由 task_mu_ 保护
 */
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <curl/curl.h>

#include "loader_download.h"
#include "multi_downloader.h"
#include "net_thread.h"

namespace download {

/**
 * Phase 2.3 (P2-2): fetchToBufferEx 的扩展返回类型。
 *   - status_code: HTTP 响应码（0 = 未拿到响应，>0 = 完整收到响应头）
 *   - body: 响应正文（对 304 通常为空）
 *   - headers: 响应头映射，key 为小写名（"etag" / "last-modified" / "content-type"）
 *   - err_kind / err_msg: 失败时的错误分类（与 fetchToBuffer 同枚举）
 */
struct FetchResponse {
    int                                   status_code = 0;
    std::string                           body;
    std::map<std::string, std::string>    headers;
    std::string                           err_kind;
    std::string                           err_msg;
};

class DownloadEngine {
public:
    struct Config {
        // C-4 修复：`thread_pool_size` 重命名为 `worker_pool_size`，并删除 `min(.., 8)` 钳制。
        //
        // 历史包袱：原字段名误导，64 在 v4.5b 之后早已被 multi_downloader.max_concurrent
        // 接管（小文件走 curl_multi 事件循环），worker 池仅处理大文件分段下载。
        // worker_count 在 engine.cpp 被钳到 8，导致 16 阈值的 cold_start_warm_threshold
        // 永远无法满足 → gate 对大文件永久启用。
        //
        // 现在：worker_pool_size 直接 = 真实 worker 线程数。
        //       cold_start_warm_threshold 必须 <= worker_pool_size，否则 start() 中夹回。
        // v6.1 (2026-06-14)：32→64，对齐 PCL2 默认下载线程数（ToolDownloadThread=63→64）。
        // 配合模组段强制新连接，让更多段同时吃各自连接的突发带宽。
        int  worker_pool_size = 64;

        // 冷启动 ramp-up gate：active < warm_threshold 时每 pop 强制间隔 cold_start_interval_ms,
        // 避免瞬时 N 个 TCP handshake 撞击 BMCLAPI。warm 后稳态无 sleep，worker
        // 从 queue 拉到就跑。
        //
        // 不变式：warm_threshold <= worker_pool_size（否则 gate 永不退出）。
        // start() 会强制 clamp 并 WARN 日志提示。
        int  cold_start_warm_threshold = 8;
        // v6 (2026-06-14)：100ms→20ms。原 100ms 让模组的多段在冷启动时被拉成 0/100/.../700ms
        // 的阶梯式启动，单个本应秒下的小文件被 ramp 拖慢近 1s。对齐 PCL2 StartManager 的 20ms 节奏，
        // warm 前 8 段 ~160ms 内全部起跑；仍保留间隔避免瞬时 N 个 TCP/TLS 握手撞击镜像。
        int  cold_start_interval_ms = 20;

        int  meta_flush_interval_ms = 2000;
        int  progress_tick_interval_ms = 200;
    };

    static DownloadEngine& instance();   // 单例

    /**
     * 延迟启动（第一次 createTask 时自动调）。可重入。
     * 不用默认参数 `Config cfg = {}`：clang 对 nested struct 的
     * inline initializer + 默认参数组合拒绝，报 "default member
     * initializer needed outside of member functions"。拆成两个 overload。
     */
    void start();
    void start(const Config& cfg);

    /** 进程退出前显式清理：停所有 worker 线程 + curl_global_cleanup */
    void shutdown();

    /** 创建任务。返回 task_id，之后可通过 task_id 查询或取消 */
    LoaderDownloadPtr createTask(LoaderDownload::Config cfg);

    /**
     * 启动一个已创建但 Waiting 的任务。
     *
     * v6.5.1 (2026-05-22) 关键修复：本方法**异步**完成 startup —— 仅做 state check
     * 和 onStart()（< 1ms），随后 detach 一个工作线程跑 `startupBody_`（per-file
     * preCheckExistingFile SHA-1 校验 + thread 入队）。原同步实现在 NAPI 调用线程
     * 上对 1500+ asset 文件做 SHA-1 → 主线程阻塞 6+ 秒 → 系统 THREAD_BLOCK_6S 触发
     * ANR/freeze/闪退。返回值变成"是否成功调度（基本不会失败）"，**不**等表示
     * 文件全部 startup 完成。
     */
    bool startTask(uint64_t task_id);

    /** 取消一个任务（等价于 pause，不清理文件） */
    bool cancelTask(uint64_t task_id);

    /** v5: 暂停任务（等价 cancelTask，语义区分 — 调用方自行决定后续 resume/delete） */
    bool pauseTask(uint64_t task_id) { return cancelTask(task_id); }

    /**
     * v5: 恢复已暂停/失败的任务。
     *   - resetToWaiting → onStart → startTask 重新入队所有未完成文件
     *   - 断点续传由 NetFile.start() 的 meta 恢复逻辑保证
     * 返回 false 表示任务状态不允许（如已 Finished）
     */
    bool resumeTask(uint64_t task_id);

    /**
     * v5: 清理任务的磁盘残留。仅允许在 Aborted / Failed 状态调用。
     * 返回释放的字节数（0 = 无清理或状态不允许）。
     */
    int64_t deleteTaskFiles(uint64_t task_id);

    /**
     * v5: 只重试指定路径的失败文件。
     * 任务状态必须是 Failed（或 Aborted）。
     * 空路径列表 = 重试全部 Failed 文件。
     */
    bool retryFailedFiles(uint64_t task_id, const std::vector<std::string>& local_paths);

    /** v5: 从任务注册表移除（终态任务）— 调用方确保不再持有任务引用 */
    bool purgeTask(uint64_t task_id);

    /** 查询 */
    LoaderDownloadPtr getTask(uint64_t task_id) const;
    std::vector<LoaderDownloadPtr> listTasks() const;

    /** 供 NetFile 调：把一组 pending thread 推到 worker queue（大文件分段） */
    void enqueueThreads(std::vector<NetThreadPtr> threads);

    /** v4.5: 供 Engine 调：把小文件的 thread 推到 MultiDownloader（HTTP/2 多路复用） */
    void enqueueMulti(std::vector<NetThreadPtr> threads);

    /**
     * Phase 3 (S2-2)：同步拉一个 URL 到内存 buffer。
     *
     * 为元数据（version_manifest_v2.json / asset_index.json / Forge file_list.json）
     * 提供与 NetThread 一致的 curl 配置（CA bundle、UserAgent、超时、follow redirect）。
     * 不走 task 队列、不写磁盘、不分段、不 sha1。
     *
     * @param primary_url     首选 URL
     * @param mirrors         次源 URL 列表（首源失败时按顺序尝试）
     * @param timeout_seconds 单次 perform 总超时（含 connect）
     * @param out_body        成功时填充响应体；失败时不保证状态
     * @param out_err_kind    失败时分类：'DnsFail' / 'ConnectFail' / 'Timeout' /
     *                        'SslFail' / 'HttpStatus' / 'PerformFail' / 'Unknown'
     * @param out_err_msg     失败时人类可读消息（含 curl_easy_strerror + http_code）
     * @return 0 = 成功；非 0 = 全部源失败（最后一次尝试的错误填充 out_err_*）
     *
     * 线程安全：内部用 thread-local curl handle，可在任意线程调（包括 NAPI worker）。
     * 不需要 DownloadEngine.start() — 仅依赖 curl_global_init（首次调时自动）。
     */
    int fetchToBuffer(const std::string& primary_url,
                      const std::vector<std::string>& mirrors,
                      int timeout_seconds,
                      std::string& out_body,
                      std::string& out_err_kind,
                      std::string& out_err_msg);

    /**
     * Phase 2.3 — 扩展版：附加请求头 + 返回响应头 + status code，支持 304 条件请求。
     *
     * 与 fetchToBuffer 共享 curl 配置；不同点：
     *   - 接受 request_headers（如 If-None-Match / If-Modified-Since）
     *   - 关闭 CURLOPT_FAILONERROR，HTTP 304 / 4xx 也能拿到 status_code 和 headers
     *   - 返回 0 当且仅当 status_code 在 200-299 或 == 304；其他 HTTP 视为失败
     *
     * @param request_headers key 大小写不敏感；空 map = 没有附加头
     * @param out_resp        填充 status_code / body / headers / err_kind / err_msg
     * @return 0 = 至少一个 URL 成功（含 304）；-1 = 全部源失败
     */
    int fetchToBufferEx(const std::string& primary_url,
                        const std::vector<std::string>& mirrors,
                        int timeout_seconds,
                        const std::map<std::string, std::string>& request_headers,
                        size_t max_response_bytes,
                        FetchResponse& out_resp);

    bool isRunning() const { return running_.load(std::memory_order_relaxed); }

    // v4.3: curl share handle — 所有 worker 共享 DNS 缓存（仅 CURL_LOCK_DATA_DNS）。
    // 注意：SSL session 有意不共享——BMCLAPI CDN 的 IP 会漂移，复用 TLS ticket 会触发
    // "no alternative certificate subject name matches" 错误。锁回调保留 SSL 分支只为
    // 防御，start() 里从未 CURLSHOPT_SHARE(CURL_LOCK_DATA_SSL_SESSION)。
    CURLSH* curlShare() const { return curl_share_; }

    // v4.3: 全局坏主机熔断（302 重定向后的实际目标或直连源主机失败时加入）
    // 所有文件共享，避免同一个坏镜像节点反复被重试。
    void    addBadHost(const std::string& host);
    /**
     * 明确记录主机已恢复健康：清除连接失败计数、开路截止时间和半开探针租约。
     * 完整请求成功，或单次尝试已经交付至少 1 MiB 有效正文后才可调用；少量慢速
     * 数据不能据此洗掉真实故障，避免劣质镜像长期占位。
     */
    void    markHostHealthy(const std::string& host);
    bool    isBadHost(const std::string& host) const;

    // ---- worker 池路径的每主机并发闸门（防 HTTP 429 限流）----
    //
    // NetThread 在真正发起请求前调 tryAcquireHostSlot；成功才继续，失败应换源或稍后重试。
    // 传输结束（无论成功失败）必须调 releaseHostSlot，成对使用。
    // 429 时调 penalizeHost 让该主机的并发上限减半（下限 1）；连续成功由
    // releaseHostSlot(ok=true) 累计，达到阈值后上限缓慢回升。

    /** 尝试占用 host 的一个并发名额。返回 false 表示该主机已达上限。 */
    bool    tryAcquireHostSlot(const std::string& host);
    /** 释放名额；ok=true 表示本次传输成功（用于回升并发上限）。 */
    void    releaseHostSlot(const std::string& host, bool ok);
    /** 该主机返回 429 → 并发上限减半（下限 1）。 */
    void    penalizeHost(const std::string& host);

    /**
     * 该主机熔断的到期时刻（steady-clock 毫秒）；未熔断返回 0。
     * NetFile::nextSourceReadyMs 需要它才能算出"何时该重新尝试"——否则熔断源的
     * NetSource::readyAtMs() 是 0（源级 cooldown 未设），等待逻辑会误判"立即可用"
     * 而空转、或直接放弃换源。
     */
    int64_t badHostReadyAtMs(const std::string& host) const;

    /**
     * 记录一次 429 并返回**该主机**应退避到的时刻（steady-clock 毫秒）。
     *
     * ⚠️ 为什么必须按主机而不是按段（2026-07-29 实测定位）：
     *   旧实现的退避基数是每个 NetThread 自己的 retryCount()，第一次撞 429 时
     *   shift=0 → 仅 500ms。16 个段各自独立睡 500ms 后**同时**重来，代理看到的
     *   依旧是 16 并发 → 立刻再 429。于是「指数退避」对主机维度完全没生效：
     *   真机实测 55 秒内字节零增长（76584KB 不变），而 429 计数从 272 涨到 294。
     *   把退避状态收敛到主机级后，同一主机的连续 429 才能真正指数拉长间隔，
     *   并且所有段共享同一个"何时可再试"的时刻，不再惊群。
     */
    int64_t noteHostRateLimit(const std::string& host, int64_t retry_after_ms);

    /** 该主机当前的 429 退避到期时刻；未退避返回 0。 */
    int64_t hostRateLimitUntilMs(const std::string& host) const;

    // ---- 每主机 IP 地址族选择（PCL2 DNSLookup 等价物）----
    //
    // 移植自 PCL2 Modules/Base/ModNet.vb:314-358 `DNSLookup` + :368-375
    // `RecordIPReliability`。PCL2 自己做 DNS 解析，**当一台主机同时有 A 和 AAAA 时
    // 只挑其中一族**（源码注释原文：「因为 GFW 可能只屏蔽了 IPv4 或 IPv6」），族内再
    // 按 IP 可靠性评分挑最好的一个；成功 +0.5、失败 -0.7，平手偏向 IPv4
    // （`If IPv4Reliability >= IPv6Reliability`）。
    //
    // ⚠️ 为什么必须补这个（2026-07-31 真机实测，零 AMCL 代码参与）：
    //   设备 shell 裸 openssl 下同一个 1.2MB 模组（sodium-neoforge-0.9.2-alpha.1）：
    //     cdn-alt.modrinth.com  -6 → **0 字节 / 137ms 立刻失败**（复测两次一致）
    //     cdn-alt.modrinth.com  -4 → 1,205,063 字节 / 27.6s 与 50.4s（23~43 KB/s）
    //   而设备 DNS 对 cdn.modrinth.com 首选返回 IPv6（2606:4700::6812:1623）。
    //   本引擎从不干预地址族，libcurl 按系统顺序优先 IPv6 → 每段都先在死 IPv6 上
    //   烧一次连接，再靠重试撞回 IPv4。这直接造成两个已记录在案的错误行为：
    //     1) net_thread.cpp 重定向块原注释把「cdn-alt 裸 openssl 也 0 字节」当成
    //        「网络侧不可达」而把官方源整条冷却 —— 结论错了，它只是 IPv6 不可达。
    //     2) 模组 1.2MB 实测 104.3s（11.5 KB/s），比同设备裸单连接 IPv4 的
    //        23~43 KB/s 还慢 2~4 倍。
    //
    // 与 PCL2 的实现差异：PCL2 把 URL 的 host 换成裸 IP 并保留 Host 头；我们直接用
    // libcurl 的 CURLOPT_IPRESOLVE 限定族，把族内选 IP 交给系统解析器 —— 语义等价
    // 但不必自己接管 DNS，也不会破坏 SNI。

    /**
     * 该主机本次请求应使用的 CURLOPT_IPRESOLVE 值。
     *
     * ⚠️ 无记录时返回 **WHATEVER**（交给系统解析器 + Happy Eyeballs），而不是像 PCL2
     *   那样平手就锁 IPv4。这是刻意偏离：PCL2 自己做 DNS、能看见两族各有哪些 IP 再决定；
     *   我们只有 CURLOPT_IPRESOLVE 这个粗粒度开关，**盲选一族的代价已被实测证明是实在的**
     *   —— 2026-07-31 真机把默认改成 V4 后，`ghfast.top` 白付一次 15s 连接超时、
     *   `maven.neoforged.net` 白付一次 SSL connect error（都是原本走 IPv6 就通的主机）。
     *   而"IPv6 死"这个问题只需要**失败之后**能记住即可：noteFamilyOutcome 会用
     *   CURLINFO_PRIMARY_IP 判定这次实际死在哪一族，下一次就锁另一族。
     *   于是首次尝试零回归、第二次起自动避开死族。
     */
    long    ipResolveFor(const std::string& host) const;
    /**
     * 记录一次尝试结果，更新该主机该族的可靠性评分。
     * @param ipresolve   本次使用的 CURLOPT_IPRESOLVE 值（可能是 WHATEVER）
     * @param primary_ip  CURLINFO_PRIMARY_IP。ipresolve 为 WHATEVER 时靠它反推族；
     *                    含 ':' 视为 IPv6。两者都无法确定族时本次不记账。
     * @param ok          是否拿到了真实字节（或整体成功）
     * @param unresolvable 该族解析不出（CURLE_COULDNT_RESOLVE_HOST）→ 屏蔽 60s
     */
    void    noteFamilyOutcome(const std::string& host, long ipresolve,
                             const std::string& primary_ip, bool ok, bool unresolvable);
    /** 从 IP 字面量反推 CURLOPT_IPRESOLVE 族；无法判定返回 WHATEVER。 */
    static long familyFromIp(const std::string& ip);
    /**
     * 该主机是否还有"另一族"值得一试。
     * 用于阻止族特异性失败被误记成全局主机熔断：IPv6 不通时应当换族重试，
     * 而不是把整台主机拉黑（对齐 PCL2 源禁用条件 ModNet.vb:1158-1163 —— 里面
     * 没有任何"某一族连不上"就废掉源的条目）。
     */
    bool    hasUntriedFamily(const std::string& host, long tried_ipresolve) const;

private:
    DownloadEngine() = default;
    ~DownloadEngine();

    DownloadEngine(const DownloadEngine&) = delete;
    DownloadEngine& operator=(const DownloadEngine&) = delete;

    enum class LifecycleState : uint8_t { Stopped, Running, ShuttingDown, Shutdown };

    Config cfg_;
    std::atomic<bool> running_{false};
    std::atomic<bool> shutdown_requested_{false};
    std::atomic<bool> curl_inited_{false};
    std::atomic<uint64_t> next_task_id_{1};

    // 生命周期状态由同一把锁发布；并发 shutdown 调用会等待首个调用完成。
    mutable std::mutex lifecycle_mu_;
    std::condition_variable lifecycle_cv_;
    LifecycleState lifecycle_state_{LifecycleState::Stopped};

    // curl 全局初始化只在成功后发布；fetch 使用计数阻止 cleanup 与 easy handle 并发。
    std::mutex curl_init_mu_;
    std::condition_variable curl_users_cv_;
    size_t active_curl_users_{0};

    // Task registry and final-path ownership share task_mu_. A path stays owned for the
    // whole resumable task lifetime (including Failed/Aborted) and is released only by
    // purge, so two tasks can never race their staging/meta commit into the same target.
    mutable std::mutex task_mu_;
    std::unordered_map<uint64_t, LoaderDownloadPtr> tasks_;
    std::unordered_map<std::string, uint64_t> path_owners_;

    // 受管理 startup 线程：禁止 detached；shutdown 在销毁 multi/worker 前全部 join。
    // completed 标志允许后续 startTask 回收已结束线程，避免长生命周期进程累积
    // joinable thread 句柄；active_startups_ 用于 retry/resume 等待旧 epoch 完全退出。
    struct ManagedStartupThread {
        std::thread thread;
        std::shared_ptr<std::atomic<bool>> completed;
    };
    std::mutex startup_mu_;
    std::condition_variable startup_cv_;
    std::vector<ManagedStartupThread> startup_threads_;
    std::unordered_map<uint64_t, size_t> active_startups_;

    // Worker queue：按 task id 做一任务一轮的 round-robin，避免单任务大量分段长期
    // 压住后来的交互任务。task id 0 是无法归属的兼容队列。
    std::mutex queue_mu_;
    std::condition_variable queue_cv_;
    std::unordered_map<uint64_t, std::deque<NetThreadPtr>> pending_threads_by_task_;
    std::deque<uint64_t> pending_task_order_;
    std::vector<std::thread> workers_;

    // v4.1 冷启动 ramp-up gate 状态：
    //   active_threads_   当前正在 run() 的 worker 数（pop 后 inc，run 完 dec）
    //   last_launch_us_   上一次 pop 一个 thread 的 monotonic 时间戳（微秒）
    //   launch_gate_mu_   保证多个 worker 同时冷启动时互斥，节奏严格 100ms/pop
    // warm 后（active_threads_ >= cold_start_warm_threshold），gate 逻辑直接跳过，
    // worker 从 queue 抢到就跑，零 overhead。
    std::atomic<int>      active_threads_{0};
    std::atomic<int64_t>  last_launch_us_{0};
    std::mutex            launch_gate_mu_;
    // v4.3: 一旦 active 曾达到 warm_threshold，永远跳过 gate（对齐 v2 行为：
    // v2 的 .then(scheduleNext) 补位路径没有 100ms 间隔，只有冷启动 setTimeout 有）
    std::atomic<bool>     warmed_up_{false};

    // Ticker（meta flush / progress tick）
    std::thread ticker_;
    std::condition_variable ticker_cv_;
    std::mutex ticker_mu_;

    // v4.3: curl share handle（当前仅共享 DNS 缓存；SSL session 刻意不共享——
    // BMCLAPI CDN IP 漂移会导致复用 ticket 时 "no alternative certificate subject name"）。
    // share_ssl_mu_ 仅为 LOCKFUNC 回调的完整性保留，实际未注册 CURL_LOCK_DATA_SSL_SESSION。
    CURLSH* curl_share_ = nullptr;
    std::mutex share_dns_mu_;     // CURLSHOPT_LOCKFUNC 需要的锁
    std::mutex share_ssl_mu_;

    // 有 TTL 的坏主机熔断：到期后进入单探针半开态；探针租约内其余请求仍被拒绝。
    mutable std::mutex bad_hosts_mu_;
    mutable std::unordered_map<std::string, int64_t> bad_host_until_ms_;
    mutable std::unordered_map<std::string, int64_t> bad_host_probe_until_ms_;
    mutable std::unordered_map<std::string, int> host_fail_counts_;

    // ⚠️ 2026-07-29：worker 池路径（NetThread，大文件分段下载）的**每主机并发上限**。
    //   MultiDownloader（小文件 curl_multi 路径）早有 host_limit_ 自适应收缩，但
    //   JDK/大文件走 enqueueThreads 工作线程池，此前**完全没有每主机限制** —— 16 段
    //   全压同一个 GitHub 代理，必然触发 HTTP 429（真机实测单次下载 570~887 条 429）。
    //   收到 429 即对该主机减半（下限 1），连续成功若干次后缓慢回升。
    //   0/缺省 = 未初始化，由 hostConcurrencyLimit 按默认值填充。
    mutable std::unordered_map<std::string, int> worker_host_limit_;
    mutable std::unordered_map<std::string, int> worker_host_active_;
    mutable std::unordered_map<std::string, int> worker_host_ok_streak_;
    // 受限主机（bmclapi）下次允许启动新连接的时刻。对齐 PCL2 的 bmclapi Sleep(100)。
    mutable std::unordered_map<std::string, int64_t> worker_host_next_start_ms_;

    // 主机级 429 退避（见 noteHostRateLimit）。所有段共享，避免各段独立短退避后惊群。
    mutable std::unordered_map<std::string, int64_t> host_ratelimit_until_ms_;
    mutable std::unordered_map<std::string, int>     host_ratelimit_streak_;

    // 每主机 IP 地址族可靠性（见 ipResolveFor / noteFamilyOutcome）。
    // 评分口径照搬 PCL2 RecordIPReliability：新值 = 旧值*0.5 + 本次*0.5，
    // 本次成功 +0.5 / 失败 -0.7，取值区间约 -1 ~ +0.5。
    struct HostFamilyScore {
        double v4 = 0.0;
        double v6 = 0.0;
        bool   v4_tried = false;
        bool   v6_tried = false;
        // 该族"解析不出"的屏蔽到期时刻（steady-clock ms，0 = 未屏蔽）。
        // 用 60s TTL 而不是永久 latch —— 对齐 PCL2 的 DNSFailureRecord
        //（ModNet.vb:320-328：同一 host 一分钟内解析失败过就跳过，超过一分钟重新尝试），
        // 避免一次偶发 DNS 抖动把某一族永久废掉。
        int64_t v4_unresolvable_until_ms = 0;
        int64_t v6_unresolvable_until_ms = 0;
    };
    mutable std::mutex host_family_mu_;
    mutable std::unordered_map<std::string, HostFamilyScore> host_family_;

    /**
     * 依据一份评分快照挑地址族。调用方须已持有 host_family_mu_。
     * 抽成函数是为了让 noteFamilyOutcome 能比较"这次记账是否翻转了族选择"，只在
     * 真正翻转时打一条日志，避免每段每次尝试都刷屏。
     */
    static long pickFamilyLocked(const HostFamilyScore& s, int64_t now_ms);

    // v4.5: curl_multi 下载器（小文件 HTTP/2 多路复用）
    std::unique_ptr<MultiDownloader> multi_downloader_;

    /**
     * 懒触发 curl_global_init（线程安全；start / fetchToBuffer / fetchToBufferEx 共享）。
     * 失败时不会标记 curl_inited_=true，调用方可写 err_kind/err_msg 后返回 -1。
     * @return true=已初始化（含本次成功）；false=本次首次初始化失败
     */
    bool ensureCurlInited(std::string* out_err_kind, std::string* out_err_msg);
    bool acquireCurlUse(std::string* out_err_kind, std::string* out_err_msg);
    void releaseCurlUse();

    void workerLoop();
    void tickerLoop();

    /** startup 主体在受管理线程上运行；shutdown 会先请求停止并 join 全部线程。 */
    void startupBody_(LoaderDownloadPtr task, uint64_t epoch);
    void reapCompletedStartupThreads_();
    void waitForStartupIdle_(uint64_t task_id);
    void finishStartup_(uint64_t task_id, const std::shared_ptr<std::atomic<bool>>& completed);
    void trackThreadsForProgress_(const std::vector<NetThreadPtr>& threads);
    void enqueueThreadsForTask(uint64_t task_id, std::vector<NetThreadPtr> threads);
    static void settleThreadsAborted(std::vector<NetThreadPtr> threads);

    void flushAllMeta();        // 遍历所有活跃 task 的 file，writeMetaFile
    void tickAllProgress();     // 调所有活跃 task 的 tickProgress
    void growAllThreads();      // v7.4 自适应分段：按目标并发对大文件补并行下载段（IDM/aria2 风格）

    // curl share lock/unlock callbacks
    static void curlShareLock(CURL* handle, curl_lock_data data,
                              curl_lock_access access, void* userptr);
    static void curlShareUnlock(CURL* handle, curl_lock_data data, void* userptr);
};

} // namespace download

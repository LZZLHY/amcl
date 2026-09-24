#include "product_diagnostics.h"
/**
 * amcl_log.cpp — AMCL 生产级日志系统实现
 *
 * 架构：
 *   - 环形缓冲区存储日志条目
 *   - 独立写入线程异步刷新到文件
 *   - 日志轮转：文件超过 maxFileSize 时重命名为 .1.log, .2.log...
 *   - 多生产者按槽位世代独占预留，单消费者发布下一世代
 */

#include "amcl_log.h"
#include "amcl_log_coalesce.h"
#include "amcl_log_time.h"
#include "render_log_tags.generated.h"
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include <algorithm>
#include <mutex>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <cerrno>
#include <cstdlib>
#include <cstdint>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef _WIN32
#include <process.h>
#include <io.h>
#endif

// ==================== 配置 ====================
// 2026-05-10：buffer 从 1024/32 提升到 4096/64，与 NAPI 桥（napi_log.cpp）的
// msg[2048]/tag[64] 对齐，避免 ArkTS 端 stack trace > 1KB 时静默截断（问题 16）。
static constexpr int LOG_ENTRY_MAX_LEN = 4096;      // 单条日志最大长度
static constexpr int LOG_TAG_MAX_LEN   = 64;        // tag 最大长度
// 2026-06-15（日志系统 v2 · P3）：环形缓冲 256 → 512，降低突发丢弃率
// （下载多段进度 / Forge 安装等高频突发场景）。512 内存占用 ≈ 512×4.2KB ≈ 2.1MB，可接受。
// 必须保持 2 的幂：amclLogWrite 用 unsigned 单调递增 idx % BUFFER_SIZE 定位槽位，
// 因 2^32 能被 512 整除，计数器过零点（UINT_MAX→0）时 slot 映射连续不跳（UINT_MAX % 512 = 511 → 0）。
//
// 2026-07-30（v3 · S1）：容量没有再加大 —— 条目是定长 4KB，2048 槽会吃掉 8.4MB 常驻内存。
// 真正的问题不是容量而是丢弃语义（详见 amclLogWrite 的 CAS 预留注释）：修好之后
// 一次丢弃只损失一条，不再引发整圈停摆，512 槽已足够。若将来仍嫌不够，正确方向是
// 改成变长存储（指针 + 长度 / 环形字节缓冲）而不是简单放大槽数。
static constexpr int LOG_BUFFER_SIZE   = 512;       // 环形缓冲区条目数（必须 2 的幂）
static constexpr int LOG_FLUSH_INTERVAL_MS = 500;   // 刷新间隔

// ==================== 日志条目 ====================
// 每槽位记录世代，区分空闲、已预留但尚未发布、可消费三种状态。
// 仅有 ready 布尔值无法阻止其他 producer 绕一圈后覆盖尚未发布的槽位。
struct LogEntry {
    // sequence == enqueue position 才可预留；position+1 表示发布，消费后推进一圈。
    std::atomic<unsigned int> sequence{0};
    AmclLogLevel level;
    char tag[LOG_TAG_MAX_LEN];
    char message[LOG_ENTRY_MAX_LEN];
    std::string extendedMessage;       // 长堆栈只在需要时分配，短日志保持固定缓冲
    size_t extendedBudget = 0;         // 该槽独占的长消息预算，消费或失败时归还
    time_t timestamp;
    // 2026-07-30（活动账本 · L1-a）：该行归属的活动主键；0 = 不归属任何活动。
    // 由 producer 填（线程本地或显式指定），writer 据此分流写进账本目录。
    long long activityId;
};

// ==================== 活动账本 scope ====================
//
// 每活动的 launcher 与 renderer 完整追加，保留策略只清理已结束的整份会话。
// 历史 launcher.tail* 文件仍由 reader 兼容；新 writer 不再覆盖中间分片。
static constexpr size_t LOG_MESSAGE_SAFETY_LIMIT = 1024 * 1024;
/** 限制全部在途长消息，防止 512 槽各留下 1 MiB；固定短消息缓冲不占此预算。 */
static constexpr size_t LOG_LONG_MESSAGE_BUDGET = 8 * 1024 * 1024;
static std::atomic<size_t> g_longMessageBytes{0};

/** 槽位所有者调用：先释放大块容量再归还预算，发布空闲世代后 producer 才能复用。 */
static void releaseLongMessage(LogEntry& entry) {
    std::string().swap(entry.extendedMessage);
    if (entry.extendedBudget != 0) {
        g_longMessageBytes.fetch_sub(entry.extendedBudget, std::memory_order_acq_rel);
        entry.extendedBudget = 0;
    }
}

/** 多 producer 用 CAS 预留总字节；预算不足时保留短前缀和显式截断原因。 */
static bool reserveLongMessage(size_t bytes) {
    size_t used = g_longMessageBytes.load(std::memory_order_relaxed);
    while (used <= LOG_LONG_MESSAGE_BUDGET && bytes <= LOG_LONG_MESSAGE_BUDGET - used) {
        if (g_longMessageBytes.compare_exchange_weak(used, used + bytes, std::memory_order_acq_rel)) return true;
    }
    return false;
}

struct LedgerScope {
    long long activityId = 0;          // 0 = 空槽
    char dir[512] = {0};
    FILE* head = nullptr;              // launcher/launcher-host.log 或 launcher-game.log
    FILE* tail = nullptr;              // 兼容历史结构，新 writer 不创建 tail
    FILE* render = nullptr;            // render/renderer.log（渲染域低频事件）
    long headBytes = 0;
    long tailBytes = 0;
    long renderBytes = 0;
    bool closing = false;              // end 已请求，等待 writer 消费到 closeTarget
    unsigned int closeTarget = 0;      // g_writeIndex 快照；到达后再关闭文件
    unsigned long accepted = 0;
    unsigned long written = 0;
    unsigned long dropped = 0;
    unsigned long failures = 0;
    unsigned long truncated = 0;
    bool statusDirty = true;
    time_t statusAt = 0;
};

static LedgerScope g_scopes[AMCL_LEDGER_MAX_SCOPES];
// 保护 scope 表。writer 写账本、begin/end 开关文件都要拿它 ——
// begin/end 是低频操作，竞争可以忽略。**临界区内绝不能调 amclLogWrite**（会自锁）。
static std::mutex g_scopeMutex;

// 当前线程的日志归属活动。native 侧是真线程并发，线程本地天然可用。
// （ArkTS 侧不能用：单 JS 线程 + async 交错会串味，走 amclLogWriteFor 显式传）
static thread_local long long t_activityId = 0;

// ==================== 全局状态 ====================
static std::string g_logDir;
static std::string g_logPath;
static int g_maxFileSize = 2 * 1024 * 1024;  // 2MB
static int g_maxFiles = 5;
static FILE* g_logFile = nullptr;
// 文件句柄与重试时间由初始化阶段/唯一 writer 持有；其他线程只读原子健康快照。
static std::atomic<bool> g_globalWritable{false};
static std::atomic<bool> g_reopenRequested{false};
static std::atomic<unsigned long> g_globalFailures{0};
static std::atomic<unsigned long> g_globalLostWrites{0};
static std::atomic<int> g_globalLastError{0};
static std::chrono::steady_clock::time_point g_nextGlobalRetry{};
static int g_globalRetryMs = 500;
static std::atomic<bool> g_initialized{false};
static std::atomic<bool> g_shutdown{false};
static std::atomic<bool> g_atforkRegistered{false};

// 环形缓冲区
// g_writeIndex 只在槽位世代匹配时 CAS 推进；g_readIndex 由 writer 独占。
static LogEntry g_buffer[LOG_BUFFER_SIZE];
static std::atomic<unsigned int> g_writeIndex{0};   // 单调递增；slot = idx % BUFFER_SIZE
static unsigned int g_readIndex = 0;                 // writer 私有，无 atomic 必要
static std::mutex g_mutex;
static std::condition_variable g_cv;
static std::thread g_writerThread;

// 2026-06-15（日志系统 v2 · P3）：精确 flush 同步。
// 原 amclLogFlush 固定 sleep(100ms)（不精确：常态多等、极端少等）。改为：
// flush 记录目标写入序号 target=g_writeIndex，writer 每轮 fflush 后把已落盘进度
// g_flushedIndex=g_readIndex 发布并 notify；flush 等到 g_flushedIndex 追上 target
// （wrap-safe 有符号比较），常态毫秒级返回，最多等 LOG_FLUSH_MAX_WAIT_MS 兜底
// （防止个别槽位 producer 半写入未 ready 时永久阻塞）。
static constexpr int LOG_FLUSH_MAX_WAIT_MS = 500;
static std::mutex g_flushMutex;
static std::condition_variable g_flushCv;
static std::atomic<unsigned int> g_flushedIndex{0};  // writer 每轮 fflush 后发布 g_readIndex
static std::atomic<unsigned int> g_flushRequest{0}; // 显式 flush 也要落下重复计数
static std::atomic<unsigned int> g_flushCompleted{0};
static std::atomic<unsigned int> g_activeProducers{0};

// 2026-07-30（日志系统 v3 · S1）：溢出丢弃计数。
// 此前丢弃是**完全静默**的 —— 事后无法从文件判断自己看到的日志是否完整。
// 现在由 writer 在下一轮落盘时补一行 "dropped N entries"，让缺口可见。
static std::atomic<unsigned long> g_droppedTotal{0};   // 累计丢弃条数（producer 累加）
static unsigned long g_droppedReported = 0;            // 已在文件里报告过的数量（writer 私有）

// 读取缓存
static std::string g_readCache;

// fork-after handler 前向声明
static void onForkInChild();
static void externalLogSink(int level, const char* tag, const char* fmt, va_list args);

/** 通知与 writer 的检查/进入等待共用互斥量，避免发布发生在 wait 前时丢失唤醒。
 * 调用方先完成原子发布再调用本函数，不得持有 g_mutex；锁只覆盖通知，不覆盖文件 IO。
 */
static void notifyWriter() {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_cv.notify_all();
}

/** writer 独占 readIndex。已发布条目、显式 flush 或 shutdown 任一存在就不再睡眠。
 * 尚未发布的预留槽不能算可读，避免等待慢 producer 时空转；普通空闲周期仍按原间隔刷新。
 */
static void waitForWriterWork() {
    std::unique_lock<std::mutex> lock(g_mutex);
    g_cv.wait_for(lock, std::chrono::milliseconds(LOG_FLUSH_INTERVAL_MS), [] {
        return g_shutdown.load(std::memory_order_acquire)
            || g_buffer[g_readIndex % LOG_BUFFER_SIZE].sequence.load(std::memory_order_acquire) == g_readIndex + 1
            || g_flushRequest.load(std::memory_order_acquire) != g_flushCompleted.load(std::memory_order_acquire);
    });
}

// ==================== 工具函数 ====================
static const char* levelToStr(AmclLogLevel level) {
    switch (level) {
        case AMCL_LOG_LEVEL_DEBUG: return "D";
        case AMCL_LOG_LEVEL_INFO:  return "I";
        case AMCL_LOG_LEVEL_WARN:  return "W";
        case AMCL_LOG_LEVEL_ERROR: return "E";
        case AMCL_LOG_LEVEL_FATAL: return "F";
        default: return "?";
    }
}

// 2026-07-31：兼容 hilog 私有性修饰符。
//   AMCL_LOG_* 宏把同一条 fmt 同时喂给 OH_LOG_*（hilog，识别 "%{public}s"/"%{private}d"）
//   和本文件的 amclLogWrite（vsnprintf，只认标准 printf）。下载引擎等大量模块的 fmt 直接
//   沿用 OH_LOG 的 "%{public}…" 写法，而 vsnprintf 不认识 "%{" —— 会把该转换说明符连同
//   后续参数一起吞掉。真机实证：DL_MULTI 的 "multi complete: url=%{public}s" 落盘成
//   "url="（URL 整个丢失）。这里在 vsnprintf 前把 "%{public}"/"%{private}" 归一成标准 "%"，
//   使同一条 fmt 两边都能正确格式化；对本就用标准 "%s" 的老调用方无影响（无 "%{" 可替换）。
static void amclStripHilogSpecifiers(const char* in, char* out, size_t out_sz) {
    if (out_sz == 0) return;
    size_t oi = 0;
    for (size_t i = 0; in[i] != '\0' && oi + 1 < out_sz;) {
        if (in[i] == '%' && in[i + 1] == '{') {
            size_t j = i + 2;
            while (in[j] != '\0' && in[j] != '}') ++j;
            if (in[j] == '}') {
                out[oi++] = '%';   // 保留 '%'，丢弃 "{public}"/"{private}" 修饰符
                i = j + 1;         // 跳到 '}' 之后（后续的 s/d/lld/.3f 等原样保留）
                continue;
            }
            // 无闭合 '}'：异常格式，原样拷贝以保底（不吞字符）
        }
        out[oi++] = in[i++];
    }
    out[oi] = '\0';
}

static long getFileSize(const char* path) {
    struct stat st;
    if (stat(path, &st) == 0) return st.st_size;
    return 0;
}

static void ensureDir(const std::string& dir) {
    struct stat st;
    if (stat(dir.c_str(), &st) != 0) {
        mkdir(dir.c_str(), 0755);
    }
}

// ==================== 日志轮转 ====================
/**
 * 轮转是否**即将**发生。
 *
 * 单独抽出来是因为 writer 需要在轮转**之前**把攒着的合并计数落地（计数不许跨文件），
 * 而 `rotateLogFiles` 自己内部才判断大小、绝大多数周期是 no-op。
 * 不先问一句就无条件收尾，会让合并每 500 ms 断一次 —— 见调用点的注释。
 */
static bool willRotateLogFiles() {
    if (!g_logFile) return false;
    return getFileSize(g_logPath.c_str()) >= g_maxFileSize;
}

/** 记录真实存储失败；错误不经日志队列递归写回。已有缺口累计保留到本次进程结束。 */
static void globalSinkFailure(int error) {
    g_globalWritable.store(false, std::memory_order_release);
    g_globalLastError.store(error != 0 ? error : EIO, std::memory_order_relaxed);
    g_globalFailures.fetch_add(1, std::memory_order_relaxed);
    g_nextGlobalRetry = std::chrono::steady_clock::now() + std::chrono::milliseconds(g_globalRetryMs);
    g_globalRetryMs = std::min(g_globalRetryMs * 2, 30000);
}

/** 仅 writer 重开文件；显式 init/flush 可以提前重试，普通空闲轮询有退避上限。 */
static void reopenGlobalSink(bool force) {
    if (g_logFile) return;
    if (!force && std::chrono::steady_clock::now() < g_nextGlobalRetry) return;
    ensureDir(g_logDir);
    g_logFile = fopen(g_logPath.c_str(), "a");
    if (!g_logFile) { globalSinkFailure(errno); return; }
    g_globalWritable.store(true, std::memory_order_release);
    g_globalLastError.store(0, std::memory_order_relaxed);
    g_globalRetryMs = 500;
    if (g_globalFailures.load() > 0) {
        // 恢复可写不代表补回缺失正文；在文件里也保留可核对的累计缺口。
        if (fprintf(g_logFile, "[amcl_log] storage recovered; failures=%lu lostWrites=%lu\n",
            g_globalFailures.load(), g_globalLostWrites.load()) < 0) {
            const int error = errno; fclose(g_logFile); g_logFile = nullptr; globalSinkFailure(error);
        }
    }
}

/** 正文、合并计数共享错误处理；部分写入也算一次缺口，保留活动 scope 的独立分流。 */
static void writeGlobalSink(const char* text, size_t length) {
    if (!g_logFile) { g_globalLostWrites.fetch_add(1); return; }
    if (fwrite(text, 1, length, g_logFile) != length) {
        const int error = errno;
        g_globalLostWrites.fetch_add(1);
        fclose(g_logFile); g_logFile = nullptr;
        globalSinkFailure(error);
    }
}

/** fflush 失败可能丢失本批缓冲内容；不能把队列消费完成解释为保存成功。 */
static void flushGlobalSink() {
    if (g_logFile && fflush(g_logFile) != 0) {
        const int error = errno;
        g_globalLostWrites.fetch_add(1);
        fclose(g_logFile); g_logFile = nullptr;
        globalSinkFailure(error);
    }
}

static void rotateLogFiles() {
    if (!g_logFile) return;
    
    long size = getFileSize(g_logPath.c_str());
    if (size < g_maxFileSize) return;
    
    // 关闭当前文件
    fclose(g_logFile);
    g_logFile = nullptr;
    
    // 删除最旧的文件
    std::string oldest = g_logDir + "/amcl_launcher." + std::to_string(g_maxFiles) + ".log";
    if (remove(oldest.c_str()) != 0 && errno != ENOENT) globalSinkFailure(errno);
    
    // 重命名 .N-1.log -> .N.log
    for (int i = g_maxFiles - 1; i >= 1; i--) {
        std::string from = g_logDir + "/amcl_launcher." + std::to_string(i) + ".log";
        std::string to = g_logDir + "/amcl_launcher." + std::to_string(i + 1) + ".log";
        if (rename(from.c_str(), to.c_str()) != 0 && errno != ENOENT) globalSinkFailure(errno);
    }
    
    // 重命名当前文件 -> .1.log
    std::string backup = g_logDir + "/amcl_launcher.1.log";
    if (rename(g_logPath.c_str(), backup.c_str()) != 0) globalSinkFailure(errno);
    
    // 重新打开新文件
    reopenGlobalSink(true);
}

// ==================== 活动账本：内部实现 ====================

// writer 线程退出时要关掉全部账本，但公共 API 定义在文件后面 —— 前向声明。
extern "C" void amclLedgerEndAll(void);

/** 找到 activityId 对应的 scope；未找到返回 nullptr。调用方必须已持 g_scopeMutex。 */
static LedgerScope* findScopeLocked(long long activityId) {
    if (activityId == 0) return nullptr;
    for (int i = 0; i < AMCL_LEDGER_MAX_SCOPES; i++) {
        if (g_scopes[i].activityId == activityId) return &g_scopes[i];
    }
    return nullptr;
}

/** 写入状态独立于正文；磁盘失败不能伪装成 complete。调用方持 scope 锁。 */
static void persistScopeStatusLocked(LedgerScope* s, bool sealed, bool force = false) {
    if (!s || s->activityId == 0) return;
    const time_t now = time(nullptr);
    if (!sealed && !force && (!s->statusDirty || s->statusAt == now)) return;
    const bool gameOwner = g_logDir.size() >= 5 && g_logDir.compare(g_logDir.size() - 5, 5, "/game") == 0;
    const std::string target = std::string(s->dir) + (gameOwner ? "/capture-game.json" : "/capture-host.json");
    const std::string temporary = target + ".tmp";
    char body[640];
#ifdef _WIN32
    const int pid = _getpid();
#else
    const int pid = getpid();
#endif
    const int length = snprintf(body, sizeof(body),
        "{\"schema\":1,\"activityId\":%lld,\"pid\":%d,\"sealed\":%s,\"captureMode\":\"full-with-repeat-counts\","
        "\"accepted\":%lu,\"written\":%lu,\"dropped\":%lu,\"writeFailures\":%lu,\"truncated\":%lu}",
        s->activityId, pid, sealed ? "true" : "false", s->accepted, s->written, s->dropped, s->failures, s->truncated);
    FILE* output = fopen(temporary.c_str(), "wb");
    if (!output) { ++s->failures; s->statusDirty = true; return; }
    const bool written = fwrite(body, 1, static_cast<size_t>(length), output) == static_cast<size_t>(length);
    const bool flushed = fflush(output) == 0;
#ifdef _WIN32
    const bool synced = _commit(_fileno(output)) == 0;
#else
    const bool synced = fsync(fileno(output)) == 0;
#endif
    const bool closed = fclose(output) == 0;
#ifdef _WIN32
    // Windows 宿主适配；产品 OHOS 的同目录 rename 原子替换。
    if (written && flushed && synced && closed) remove(target.c_str());
#endif
    if (written && flushed && synced && closed && rename(temporary.c_str(), target.c_str()) == 0) {
        s->statusDirty = false;
        s->statusAt = now;
    } else {
        ++s->failures;
        s->statusDirty = true;
        remove(temporary.c_str());
    }
}

static void noteScopeEvent(long long activityId, bool dropped, bool truncated) {
    if (activityId == 0) return;
    std::lock_guard<std::mutex> lock(g_scopeMutex);
    LedgerScope* s = findScopeLocked(activityId);
    if (!s) return;
    if (dropped) ++s->dropped;
    else if (truncated) ++s->truncated;
    else ++s->accepted;
    s->statusDirty = true;
}

/** 完整追加普通日志；空间不足时记录失败，保留已经写入的原件。 */
static void appendScopeFileLocked(LedgerScope* s, FILE* file, const char* line, int len, long* bytes) {
    if (!s || !file || len <= 0) return;
    size_t total = 0;
    while (total < static_cast<size_t>(len)) {
        const size_t got = fwrite(line + total, 1, static_cast<size_t>(len) - total, file);
        if (got == 0) { ++s->failures; break; }
        total += got;
    }
    *bytes += static_cast<long>(total);
    if (total == static_cast<size_t>(len)) ++s->written;
    s->statusDirty = true;
}

/** 关闭一个 scope 并发布终态；历史 tail 分片仅保留兼容读取，不再覆盖它们。 */
static void closeScopeLocked(LedgerScope* s) {
    if (!s) return;
    for (FILE* file : {s->head, s->tail, s->render}) {
        if (!file) continue;
        if (fflush(file) != 0) ++s->failures;
        if (fclose(file) != 0) ++s->failures;
    }
    s->head = nullptr; s->tail = nullptr; s->render = nullptr;
    persistScopeStatusLocked(s, true);
    *s = LedgerScope{};
}

static void writeToScopeLocked(LedgerScope* s, const char* line, int len) {
    if (!s || len <= 0) return;
    if (!s->head) { ++s->failures; s->statusDirty = true; return; }
    appendScopeFileLocked(s, s->head, line, len, &s->headBytes);
}

/** 与日志域注册表的 render 域一致；独立 DSO 的 stderr 仍由原始输出文件记录。 */
static bool isRenderTag(const char* tag) {
    if (!tag) return false;
    for (const char* registered : AMCL_RENDER_LOG_TAGS) if (strcmp(tag, registered) == 0) return true;
    return false;
}

static void writeRenderToScopeLocked(LedgerScope* s, const char* line, int len) {
    if (!s || !line || len <= 0) return;
    if (!s->render) {
        const std::string directory = std::string(s->dir) + "/render";
        ensureDir(directory);
        const bool gameOwner = g_logDir.size() >= 5 && g_logDir.compare(g_logDir.size() - 5, 5, "/game") == 0;
        const std::string target = directory + (gameOwner ? "/renderer-game.log" : "/renderer.log");
        s->render = fopen(target.c_str(), "a");
        s->renderBytes = s->render ? getFileSize(target.c_str()) : 0;
    }
    if (!s->render) { ++s->failures; s->statusDirty = true; return; }
    appendScopeFileLocked(s, s->render, line, len, &s->renderBytes);
}

static void teeToLedger(long long activityId, const char* tag, const char* line, int len) {
    if (activityId == 0) return;
    std::lock_guard<std::mutex> lock(g_scopeMutex);
    LedgerScope* s = findScopeLocked(activityId);
    if (!s) return;
    if (isRenderTag(tag)) writeRenderToScopeLocked(s, line, len);
    else writeToScopeLocked(s, line, len);
}

/** writer 线程发布 flushedIndex 前刷新所有活动文件。 */
static void flushScopesLocked(bool force = false) {
    std::lock_guard<std::mutex> lk(g_scopeMutex);
    for (int i = 0; i < AMCL_LEDGER_MAX_SCOPES; i++) {
        if (g_scopes[i].activityId == 0) continue;
        LedgerScope& scope = g_scopes[i];
        for (FILE* file : {scope.head, scope.tail, scope.render}) {
            if (file && fflush(file) != 0) { ++scope.failures; scope.statusDirty = true; }
        }
        persistScopeStatusLocked(&scope, false, force);
    }
}

/** writer 消费完 end 请求之前已预留的槽位后，安全关闭对应 scope。 */
static void finishClosingScopes(unsigned int consumed) {
    std::lock_guard<std::mutex> lk(g_scopeMutex);
    for (int i = 0; i < AMCL_LEDGER_MAX_SCOPES; i++) {
        LedgerScope& scope = g_scopes[i];
        if (scope.activityId == 0 || !scope.closing) continue;
        if (static_cast<int>(consumed - scope.closeTarget) >= 0) closeScopeLocked(&scope);
    }
}

// ==================== 连续重复行合并（日志系统重构 · P2）====================
//
// 解决的问题：一个调用点可以把共享保留预算整个吃掉。真机实测（施工记录 §S03.1）
// 一句**逐字相同**的 INFO 心跳占了 amcl_launcher.log 的 72.9% 字节，
// 把 12 MiB 预算的有效保留时长从 511 h 压到 143.9 h。
// 同型事故这是第三次（[GLFW-DIAG] poll# → [MG-FRAME-*] → 本次），
// 前两次都是在下游再加一条字符串匹配，治不了第四次。
//
// ⭐ 为什么放在 writer 线程：
//   · 这里的状态是**写线程私有**的，不碰环形缓冲的任何并发不变量
//     （S1 刚把序号分配改成 CAS 预留，热路径不能再塞东西）；
//   · producer 侧做不了 —— 它看不到「上一条别人写了什么」；
//   · 事后过滤做不了 —— 字节已经付出去了，保留窗已经被挤掉了。
//   这与账本 tee 放在 writer 的理由是同一条（activity-ledger.md §2.4）。
//
// ⭐ 判据只用「连续 + 逐字相同」，**刻意不做数字归一化**。
//   真机实测（施工记录 §S04.2）：心跳 7,491 次只有 21 种原文 ⇒ 逐字合并已压掉 99.7%；
//   而 display-change 93 次有 36 种原文 ⇒ 归一化会把 36 个真实事件压成 1 条。
//   逐字相同的行按定义不携带新信息，合并它是**无损**的；归一化是有损的。
//
// 时序：**先写首行，再抑制重复，变化时补一行计数**。
//   ⇒ 进程随时被杀最多丢一个计数，绝不丢内容。
//   显式 flush / scope close 会落下当前计数；普通空闲周期继续保留游程。
// 判据本身在 amcl_log_coalesce.h 里，是**纯策略**，可在宿主上直接跑用例
// （tests/host/log_coalesce_test.cpp）。这里只负责 IO 与线程私有状态。
/** 只由 writer 线程访问，不需要任何同步。 */
static AmclCoalesceState g_coalesce = {};

/**
 * 把攒着的重复计数落成一行。
 * @param keepRun true = 因为攒满上限而落地，游程继续；false = 因为来了不同的行而收尾
 */
static void flushCoalescedLocked(bool keepRun) {
    if (!amclCoalescePending(&g_coalesce)) {
        if (!keepRun) g_coalesce.active = 0;
        return;
    }
    char body[256];
    int blen = amclCoalesceFormatBody(&g_coalesce, body, sizeof(body));
    if (blen <= 0) {
        amclCoalesceAfterFlush(&g_coalesce, keepRun ? 1 : 0);
        return;
    }

    char timeBuf[32];
    time_t last = static_cast<time_t>(g_coalesce.lastTs);
    amclFormatLogTime(last, timeBuf, sizeof(timeBuf));

    // 用 amcl_log 作 tag，与既有的 "dropped N entries" 元日志同一套约定：
    // 这样按 tag 统计字节份额时，刷屏模块的份额反映的是它**真实的**内容量。
    // 级别沿用被合并行的级别，避免 ERROR 洪泛的计数被级别过滤器吞掉。
    char line[LOG_ENTRY_MAX_LEN + LOG_TAG_MAX_LEN + 128];
    int len = snprintf(line, sizeof(line), "[%s][%s][amcl_log] %s\n",
                       timeBuf, levelToStr(static_cast<AmclLogLevel>(g_coalesce.level)), body);
    if (len < 0) len = 0;
    if (len > static_cast<int>(sizeof(line)) - 1) len = static_cast<int>(sizeof(line)) - 1;
    writeGlobalSink(line, static_cast<size_t>(len));
    teeToLedger(g_coalesce.activityId, g_coalesce.tag, line, len);

    amclCoalesceAfterFlush(&g_coalesce, keepRun ? 1 : 0);
}

/**
 * 消费一条 entry：格式化 + 落盘 + 分流账本，重复的则只计数。
 * 主循环与关停排空共用，避免两处逻辑漂移（此前这段代码是复制粘贴的两份）。
 */
static void emitEntry(const LogEntry& entry) {
    // 环境观测是低频结构化事实，来自实际 JVM/GL 线程。写到独立小文件供会话环境读取，
    // 避免长时间游玩后启动器正文尾窗挤掉设备信息；仍使用既有活动归属，不另建全局路由。
    if (strcmp(entry.tag, "SessionEnvironment") == 0) {
        const char* facts = entry.extendedMessage.empty() ? entry.message : entry.extendedMessage.c_str();
        if (strncmp(facts, "AMCL_ENV_V1\t", 12) == 0) {
            std::lock_guard<std::mutex> lock(g_scopeMutex);
            LedgerScope* scope = findScopeLocked(entry.activityId);
            if (scope) {
                const std::string path = std::string(scope->dir) + "/environment-observed.log";
                FILE* file = fopen(path.c_str(), "a");
                if (!file || fprintf(file, "%s\n", facts) < 0 || fflush(file) != 0) {
                    ++scope->failures; scope->statusDirty = true;
                }
                if (file) fclose(file);
            }
        }
    }
    if (entry.extendedMessage.empty() && amclCoalesceMatches(&g_coalesce, entry.level, entry.activityId,
                            entry.tag, entry.message)) {
        if (amclCoalesceNoteRepeat(&g_coalesce, static_cast<long long>(entry.timestamp))) {
            flushCoalescedLocked(/*keepRun=*/true);
        }
        return;
    }
    flushCoalescedLocked(/*keepRun=*/false);

    char timeBuf[32];
    amclFormatLogTime(entry.timestamp, timeBuf, sizeof(timeBuf));

    // 一次格式化，两处落盘：全局文件 + （若有归属）该活动的账本。
    // 之所以先 snprintf 到栈上再写，而不是两次 fprintf：账本要的是与全局
    // 文件**逐字节一致**的同一行，重复格式化既浪费也容易两边不一致。
    const char* body = entry.extendedMessage.empty() ? entry.message : entry.extendedMessage.c_str();
    const std::string line = std::string("[") + timeBuf + "][" + levelToStr(entry.level)
        + "][" + entry.tag + "] " + body + "\n";
    writeGlobalSink(line.data(), line.size());
    teeToLedger(entry.activityId, entry.tag, line.data(), static_cast<int>(line.size()));

    // 长行不进入定长合并键，避免相同前缀、不同堆栈被错误合并。
    if (entry.extendedMessage.empty()) {
        amclCoalesceBegin(&g_coalesce, entry.level, entry.activityId,
                          entry.tag, entry.message, static_cast<long long>(entry.timestamp));
    }
}

// ==================== 写入线程 ====================
static void writerThreadFunc() {
    while (!g_shutdown.load()) {
        waitForWriterWork();
        const unsigned int flushRequest = g_flushRequest.load(std::memory_order_acquire);
        reopenGlobalSink(g_reopenRequested.exchange(false)
            || flushRequest != g_flushCompleted.load(std::memory_order_relaxed));
        // 只有当前世代已发布才消费；未发布的预留不能被跳过或复用。
        bool drained = false;
        while (!drained) {
            LogEntry& entry = g_buffer[g_readIndex % LOG_BUFFER_SIZE];
            if (entry.sequence.load(std::memory_order_acquire) != g_readIndex + 1) {
                drained = true;
                break;
            }

            // 格式化 + 落盘 + 账本分流；连续逐字相同的行只累加计数（见 emitEntry）。
            emitEntry(entry);

            // 标记槽位空，允许下一轮 producer 复用
            releaseLongMessage(entry);
            entry.sequence.store(g_readIndex + LOG_BUFFER_SIZE, std::memory_order_release);
            g_readIndex++;
        }
        // S1：把"这段时间丢了多少条"写进文件，避免静默缺口。
        // 直接用 fprintf 而不是 amclLogWrite —— 后者会去抢槽位，缓冲满时这条元日志
        // 自己就会被丢掉，正好在最需要它的时候失效。
        {
            unsigned long dropped = g_droppedTotal.load(std::memory_order_relaxed);
            if (dropped > g_droppedReported) {
                // 丢弃元日志必须是**独立可见**的一行，不能被合并计数吞掉，
                // 所以先把攒着的游程收尾。
                flushCoalescedLocked(/*keepRun=*/false);
                unsigned long delta = dropped - g_droppedReported;
                g_droppedReported = dropped;
                char timeBuf[32];
                time_t now = time(nullptr);
                amclFormatLogTime(now, timeBuf, sizeof(timeBuf));
                if (g_logFile) fprintf(g_logFile,
                        "[%s][W][amcl_log] dropped %lu entries due to buffer overflow (total %lu)\n",
                        timeBuf, delta, dropped);
            }
        }
        bool closing = false;
        {
            std::lock_guard<std::mutex> lock(g_scopeMutex);
            for (const LedgerScope& scope : g_scopes) closing = closing || scope.closing;
        }
        if (closing || flushRequest != g_flushCompleted.load(std::memory_order_relaxed)) flushCoalescedLocked(/*keepRun=*/false);
        flushGlobalSink();

        // The global file is not the only durable sink.  Activity files are
        // stdio streams too, so flush them before publishing g_flushedIndex;
        // otherwise amclLogFlush could report success while the ledger still
        // has the last batch in a userspace buffer.
        flushScopesLocked(flushRequest != g_flushCompleted.load(std::memory_order_relaxed));
        finishClosingScopes(g_readIndex);

        // P3：发布已落盘进度，唤醒 amclLogFlush 的等待者（精确 flush）。
        g_flushedIndex.store(g_readIndex, std::memory_order_release);
        g_flushCompleted.store(flushRequest, std::memory_order_release);
        {
            std::lock_guard<std::mutex> fl(g_flushMutex);
        }
        g_flushCv.notify_all();

        // 轮转前把攒着的计数落地：一段游程的计数不许跨文件，
        // 否则备份文件里会出现「首行在这一代、计数在下一代」的断裂。
        //
        // ⚠️ **必须先问一句 willRotateLogFiles()，不能无条件收尾**（2026-09-06 自审抓出的缺陷）：
        // `rotateLogFiles` 内部才判断大小，绝大多数周期是 no-op；而 writer 每 500 ms 醒一次、
        // 心跳约 1 s 一条 ⇒ 无条件收尾会让游程长度恒为 1，**合并直接失效、收益归零**。
        // 这一条正是本文件上面那段注释警告过的形状，我自己还是踩了一次。
        // 宿主用例测的是纯策略，测不到这里 —— 由 scripts/check-log-coalesce-wiring.mjs 钉住。
        if (willRotateLogFiles()) flushCoalescedLocked(/*keepRun=*/false);
        rotateLogFiles();
    }

    // 关闭前最后刷新；shutdown 已等待所有预留者发布。
    {
        while (true) {
            LogEntry& entry = g_buffer[g_readIndex % LOG_BUFFER_SIZE];
            if (entry.sequence.load(std::memory_order_acquire) != g_readIndex + 1) break;
            emitEntry(entry);
            releaseLongMessage(entry);
            entry.sequence.store(g_readIndex + LOG_BUFFER_SIZE, std::memory_order_release);
            g_readIndex++;
        }
        // 关停是最后一次机会，攒着的计数必须落盘，否则永久丢失。
        flushCoalescedLocked(/*keepRun=*/false);
        flushGlobalSink();
        if (g_logFile) fclose(g_logFile);
        g_logFile = nullptr;
        g_globalWritable.store(false, std::memory_order_release);
    }
    // 收尾：关掉所有还开着的账本，避免退出时留下未 flush 的账本文件
    amclLedgerEndAll();
}

// ==================== 公共 API ====================
extern "C" void amclLogInit(const char* logDir, int maxFileSize, int maxFiles) {
    if (g_initialized.load()) { g_reopenRequested.store(true); notifyWriter(); return; }

    g_logDir = logDir;
    g_maxFileSize = maxFileSize > 0 ? maxFileSize : 2 * 1024 * 1024;
    g_maxFiles = maxFiles > 0 ? maxFiles : 5;

    ensureDir(g_logDir);

    g_logPath = g_logDir + "/amcl_launcher.log";
    g_globalFailures.store(0); g_globalLostWrites.store(0); g_globalLastError.store(0);
    g_globalWritable.store(false); g_globalRetryMs = 500; g_nextGlobalRetry = {};
    reopenGlobalSink(true);

    if (g_logFile) {
        // 写入启动分隔符
        time_t now = time(nullptr);
        char timeBuf[32];
        amclFormatLogTime(now, timeBuf, sizeof(timeBuf));
        fprintf(g_logFile, "\n========== AMCL Session Start: %s ==========\n", timeBuf);
        flushGlobalSink();
    }

    // 重置 ring buffer 状态（防止 init/shutdown/init 序列残留）
    g_writeIndex.store(0);
    g_readIndex = 0;
    g_flushedIndex.store(0, std::memory_order_relaxed);  // P3：flush 进度同步重置
    g_flushRequest.store(0, std::memory_order_relaxed);
    g_flushCompleted.store(0, std::memory_order_relaxed);
    g_droppedTotal.store(0, std::memory_order_relaxed);  // S1：丢弃计数同步重置
    g_droppedReported = 0;
    // P2：合并游程状态同步重置。不重置的话，init/shutdown/init 之后第一条日志
    // 会被拿去与**上一个生命周期**的最后一行比较，可能被静默抑制。
    amclCoalesceReset(&g_coalesce);
    for (int i = 0; i < LOG_BUFFER_SIZE; i++) {
        releaseLongMessage(g_buffer[i]);
        g_buffer[i].sequence.store(static_cast<unsigned int>(i), std::memory_order_relaxed);
    }

    g_shutdown.store(false);
    // 防御性 detach：如果之前是 fork 子进程残留的 joinable thread，move-assign
    // 会让 std::thread 析构 terminate。detach 让旧对象变 non-joinable。
    if (g_writerThread.joinable()) g_writerThread.detach();
    g_writerThread = std::thread(writerThreadFunc);
    g_initialized.store(true);
    // 宿主 writer 初始化后才发布回调。描述符包含 PID，独立 namespace 的 GLFW
    // 可以调用同一 writer，而 fork 子进程必须重新初始化后才接受自己的描述符。
    char sinkDescriptor[96];
#ifdef _WIN32
    const long sinkPid = _getpid();
#else
    const long sinkPid = getpid();
#endif
    snprintf(sinkDescriptor, sizeof(sinkDescriptor), "%ld:%llx", sinkPid,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&externalLogSink)));
#ifdef _WIN32
    _putenv_s("AMCL_LOG_SINK_V1", sinkDescriptor);
#else
    setenv("AMCL_LOG_SINK_V1", sinkDescriptor, 1);
#endif

    // 2026-05-10：注册 fork-after-child handler（问题 18），子进程里把 amcl_log
    // 标为未初始化，让 amclLogWrite no-op，避免父子共享 fd 导致的日志撕裂。
    // pthread_atfork 只能注册一次（HarmonyOS musl pthread_atfork 没有 deregister）。
    if (!g_atforkRegistered.exchange(true)) {
        pthread_atfork(nullptr, nullptr, onForkInChild);
    }
}

extern "C" void amclLogShutdown(void) {
    // 2026-05-10：用 exchange 原子切换 g_initialized，避免 join 前 race window
    // 让其他线程仍 pass 初始化检查继续写 buffer（问题 19）。
    if (!g_initialized.exchange(false)) return;
    while (g_activeProducers.load(std::memory_order_acquire) != 0) std::this_thread::yield();
    g_shutdown.store(true);
    notifyWriter();
    g_flushCv.notify_all();  // P3：唤醒可能在 amclLogFlush 中等待的线程

    if (g_writerThread.joinable()) {
        g_writerThread.join();
    }
}

/**
 * 写入实现（归属活动由调用方给定）。
 *
 * 2026-07-30（活动账本 · L1-a）：从 amclLogWrite 抽出来，让「线程本地归属」与
 * 「显式归属」两个入口共用同一份逻辑 —— variadic 函数无法互相转发，必须走 va_list。
 */
static void writeImplV(long long activityId, AmclLogLevel level,
                       const char* tag, const char* fmt, va_list args) {
    if (!amclDiagnosticLogAllowed(AMCL_DIAGNOSTICS_MASK, static_cast<int>(level), tag, fmt)) return;
    if (!g_initialized.load(std::memory_order_acquire)) return;

    // 生命周期租约确保 shutdown 不会在已经预留的 producer 发布前关闭 writer。
    struct ProducerLease {
        ProducerLease() { g_activeProducers.fetch_add(1, std::memory_order_acq_rel); }
        ~ProducerLease() { g_activeProducers.fetch_sub(1, std::memory_order_release); }
    } lease;
    if (!g_initialized.load(std::memory_order_acquire)) return;

    unsigned int idx = g_writeIndex.load(std::memory_order_relaxed);
    for (;;) {
        LogEntry& slot = g_buffer[idx % LOG_BUFFER_SIZE];
        const unsigned int sequence = slot.sequence.load(std::memory_order_acquire);
        const int32_t distance = static_cast<int32_t>(sequence - idx);
        if (distance == 0) {
            if (g_writeIndex.compare_exchange_weak(idx, idx + 1,
                    std::memory_order_relaxed, std::memory_order_relaxed)) break;
        } else if (distance < 0) {
            // 上一世代尚未消费，包含「已预留但未发布」。丢弃不消耗序号。
            g_droppedTotal.fetch_add(1, std::memory_order_relaxed);
            noteScopeEvent(activityId, true, false);
            notifyWriter();
            return;
        } else {
            idx = g_writeIndex.load(std::memory_order_relaxed);
        }
    }
    LogEntry& entry = g_buffer[idx % LOG_BUFFER_SIZE];
    entry.level = level;
    entry.timestamp = time(nullptr);
    entry.activityId = activityId;
    strncpy(entry.tag, tag ? tag : "?", sizeof(entry.tag) - 1);
    entry.tag[sizeof(entry.tag) - 1] = '\0';
    releaseLongMessage(entry);

    // 两遍格式化保留长堆栈。异常大的单条记录明确标记截断，状态同步进入 capture 文件。
    // 格式字符串也用实际长度分配，不能在 printf 转换说明符中间截断。
    std::vector<char> cleanFmt(strlen(fmt ? fmt : "") + 1);
    amclStripHilogSpecifiers(fmt ? fmt : "", cleanFmt.data(), cleanFmt.size());
    va_list copy;
    va_copy(copy, args);
    const int required = vsnprintf(entry.message, sizeof(entry.message), cleanFmt.data(), copy);
    va_end(copy);
    bool truncated = required < 0;
    if (required >= static_cast<int>(sizeof(entry.message))) {
        const size_t length = static_cast<size_t>(required) > LOG_MESSAGE_SAFETY_LIMIT
            ? LOG_MESSAGE_SAFETY_LIMIT : static_cast<size_t>(required);
        const size_t budget = length + 96;
        if (reserveLongMessage(budget)) {
            entry.extendedBudget = budget;
            try {
                entry.extendedMessage.reserve(budget);
                entry.extendedMessage.resize(length + 1);
                va_copy(copy, args);
                vsnprintf(entry.extendedMessage.data(), length + 1, cleanFmt.data(), copy);
                va_end(copy);
                entry.extendedMessage.resize(length);
                truncated = static_cast<size_t>(required) > length;
                if (truncated) entry.extendedMessage += "\n[AMCL capture truncated: single entry exceeds 1 MiB]";
            } catch (...) {
                releaseLongMessage(entry);
                truncated = true;
            }
        } else truncated = true;
        if (entry.extendedMessage.empty()) {
            // 原短缓冲已有正文前缀。缺口进入 scope.truncated，不能伪装为完整堆栈。
            snprintf(entry.message + sizeof(entry.message) - 128, 128,
                "\n[AMCL capture truncated: long-message memory budget exhausted]");
        }
    } else if (required < 0) {
        strcpy(entry.message, "[AMCL capture failed: invalid printf encoding]");
    }
    noteScopeEvent(activityId, false, false);
    if (truncated) noteScopeEvent(activityId, false, true);
    entry.sequence.store(idx + 1, std::memory_order_release);
    notifyWriter();
}

extern "C" void amclLogWrite(AmclLogLevel level, const char* tag, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    // 线程本地归属：native worker 线程进入某活动工作时已 set 过
    writeImplV(t_activityId, level, tag, fmt, args);
    va_end(args);
}

static void externalLogSink(int level, const char* tag, const char* fmt, va_list args) {
    // 只有宿主持有当前游戏活动；启动前尚无活动的失败仍进入全局文件。
    writeImplV(amclLedgerGetLaunchActivity(), static_cast<AmclLogLevel>(level), tag, fmt, args);
}

extern "C" void amclLogPrint(AmclLogLevel level, unsigned int domain, const char* tag, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    va_list systemArgs;
    va_copy(systemArgs, args);
    OH_LOG_VPrint(LOG_APP, level >= AMCL_LOG_LEVEL_FATAL ? LOG_FATAL
        : level >= AMCL_LOG_LEVEL_ERROR ? LOG_ERROR : LOG_WARN, domain, tag, fmt, systemArgs);
    va_end(systemArgs);
    writeImplV(t_activityId, level, tag, fmt, args);
    va_end(args);
}

extern "C" void amclLogWriteFor(long long activityId, AmclLogLevel level,
                                const char* tag, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    writeImplV(activityId, level, tag, fmt, args);
    va_end(args);
}

extern "C" void amclLogSetThreadActivity(long long activityId) {
    t_activityId = activityId;
}

extern "C" long long amclLogGetThreadActivity(void) {
    return t_activityId;
}

// ==================== 活动账本：公共 API ====================

extern "C" int amclLedgerBegin(long long activityId, const char* dir) {
    if (activityId == 0 || !dir || !dir[0]) return 0;
    std::lock_guard<std::mutex> lk(g_scopeMutex);

    // 幂等：同一活动重复 begin 只生效一次
    if (findScopeLocked(activityId) != nullptr) return 1;

    LedgerScope* free_slot = nullptr;
    for (int i = 0; i < AMCL_LEDGER_MAX_SCOPES; i++) {
        if (g_scopes[i].activityId == 0) { free_slot = &g_scopes[i]; break; }
    }
    // 槽位满：不抢占已有 scope（那会让别的活动日志半途断掉），直接失败。
    // 调用方据此降级为「本条活动无账本」，全局日志里仍有内容。
    if (!free_slot) return 0;

    ensureDir(dir);
    const std::string launcherDir = std::string(dir) + "/launcher";
    ensureDir(launcherDir);
    const bool gameOwner = g_logDir.size() >= 5 && g_logDir.compare(g_logDir.size() - 5, 5, "/game") == 0;
    const std::string headPath = launcherDir + (gameOwner ? "/launcher-game.log" : "/launcher-host.log");
    *free_slot = LedgerScope{};
    free_slot->activityId = activityId;
    strncpy(free_slot->dir, dir, sizeof(free_slot->dir) - 1);
    free_slot->head = fopen(headPath.c_str(), "a");
    free_slot->headBytes = getFileSize(headPath.c_str());
    if (!free_slot->head) ++free_slot->failures;
    persistScopeStatusLocked(free_slot, false);
    // 打开失败也保留 scope 状态，使后续归档能报告 write-failed，而非空的 complete。
    return free_slot->head ? 1 : 0;
}

extern "C" void amclLedgerEnd(long long activityId) {
    if (activityId == 0) return;
    // Mark first so a writer that is already draining the ring can still tee
    // the final entries.  Closing the FILE immediately after a fixed sleep
    // loses exactly the crash line this ledger exists to preserve.
    {
        std::lock_guard<std::mutex> lk(g_scopeMutex);
        LedgerScope* scope = findScopeLocked(activityId);
        if (!scope) return;
        scope->closing = true;
        scope->closeTarget = g_writeIndex.load(std::memory_order_acquire);
    }
    amclLogFlush();
    // 关闭由 writer 独占；超时时仍保留 scope，不能在重复计数落盘前提前 fclose。
}

extern "C" void amclLedgerEndAll(void) {
    std::lock_guard<std::mutex> lk(g_scopeMutex);
    for (int i = 0; i < AMCL_LEDGER_MAX_SCOPES; i++) {
        if (g_scopes[i].activityId != 0) closeScopeLocked(&g_scopes[i]);
    }
}

// ==================== 下载任务 → 活动 关联表 ====================
//
// 定长数组 + 自旋友好的短临界区。条目数取 32：并发下载任务上限是 3，
// 但一个活动可能派生多个 native 任务（MC 版本 + libraries + assets 分批），留足余量。
// 定长避免在日志热路径上做内存分配。
static constexpr int LEDGER_TASK_MAP_SIZE = 32;
struct TaskActivityBind {
    unsigned long long taskId = 0;   // 0 = 空槽
    long long activityId = 0;
};
static TaskActivityBind g_taskBinds[LEDGER_TASK_MAP_SIZE];
static std::mutex g_taskBindMutex;

extern "C" void amclLedgerBindTask(unsigned long long taskId, long long activityId) {
    if (taskId == 0) return;
    std::lock_guard<std::mutex> lk(g_taskBindMutex);
    int freeIdx = -1;
    for (int i = 0; i < LEDGER_TASK_MAP_SIZE; i++) {
        if (g_taskBinds[i].taskId == taskId) {
            // 已有条目：activityId 为 0 视为解除
            if (activityId == 0) { g_taskBinds[i].taskId = 0; g_taskBinds[i].activityId = 0; }
            else g_taskBinds[i].activityId = activityId;
            return;
        }
        if (freeIdx < 0 && g_taskBinds[i].taskId == 0) freeIdx = i;
    }
    if (activityId == 0) return;
    // 表满：直接丢弃这次关联（该任务的 native 日志只进全局文件）。
    // 不覆盖别人的条目 —— 那会把另一个活动的日志错误地归到这个活动名下，
    // 「掺别人的行」正是本次改造要根除的问题。
    if (freeIdx < 0) return;
    g_taskBinds[freeIdx].taskId = taskId;
    g_taskBinds[freeIdx].activityId = activityId;
}

extern "C" void amclLedgerUnbindTask(unsigned long long taskId) {
    if (taskId == 0) return;
    std::lock_guard<std::mutex> lk(g_taskBindMutex);
    for (int i = 0; i < LEDGER_TASK_MAP_SIZE; i++) {
        if (g_taskBinds[i].taskId == taskId) {
            g_taskBinds[i].taskId = 0;
            g_taskBinds[i].activityId = 0;
            return;
        }
    }
}

// 游戏启动线程的归属活动。一次只能跑一局 MC，故一个全局值足够（不需要映射表）。
static std::atomic<long long> g_launchActivityId{0};

extern "C" void amclLedgerSetLaunchActivity(long long activityId) {
    g_launchActivityId.store(activityId, std::memory_order_release);
}

extern "C" long long amclLedgerGetLaunchActivity(void) {
    return g_launchActivityId.load(std::memory_order_acquire);
}

extern "C" long long amclLedgerActivityOfTask(unsigned long long taskId) {
    if (taskId == 0) return 0;
    std::lock_guard<std::mutex> lk(g_taskBindMutex);
    for (int i = 0; i < LEDGER_TASK_MAP_SIZE; i++) {
        if (g_taskBinds[i].taskId == taskId) return g_taskBinds[i].activityId;
    }
    return 0;
}

// ==================== fork 处理 ====================
// 2026-05-10：子进程里 writer 线程已死（POSIX：fork 后只剩调用线程），把
// amcl_log 标为未初始化，让所有 amclLogWrite 调用 no-op。父子共享 g_logFile
// FD 也直接 close，避免父子并发写互相破坏文件 offset（问题 18）。
static void onForkInChild() {
    g_initialized.store(false);
    g_globalWritable.store(false);
    g_reopenRequested.store(false);
    // P2：子进程里 writer 线程已不存在，攒着的游程永远不会有人来收尾。
    // 清掉它，避免子进程若重新 init 时拿父进程的最后一行做比较（AGENTS §三·7 那类
    // 「fork 出来的子进程继承了父进程已解析的缓存」是本仓咬过多次的形状）。
    amclCoalesceReset(&g_coalesce);
    if (g_logFile) {
        fclose(g_logFile);
        g_logFile = nullptr;
    }
    // 账本句柄同理：父子共享 FILE* 的 offset 会互相破坏。
    // 这里直接清表而不走 closeScopeLocked —— fork 后子进程里只剩当前线程，
    // g_scopeMutex 可能正被（已不存在的）writer 线程持有，加锁会死锁。
    for (int i = 0; i < AMCL_LEDGER_MAX_SCOPES; i++) {
        if (g_scopes[i].head) { fclose(g_scopes[i].head); g_scopes[i].head = nullptr; }
        if (g_scopes[i].tail) { fclose(g_scopes[i].tail); g_scopes[i].tail = nullptr; }
        if (g_scopes[i].render) { fclose(g_scopes[i].render); g_scopes[i].render = nullptr; }
        g_scopes[i].activityId = 0;
    }
    // 不去 join writer：它在子进程里根本不存在
    // g_writerThread 留着空 thread 对象不影响（destructor 也不 join）
}

extern "C" int amclLogFlushChecked(void) {
    if (!g_initialized.load()) return 0;
    const unsigned int target = g_writeIndex.load(std::memory_order_acquire);
    const unsigned int request = g_flushRequest.fetch_add(1, std::memory_order_acq_rel) + 1;
    notifyWriter();
    std::unique_lock<std::mutex> lk(g_flushMutex);
    // 同时确认正文进度与这次刷新请求；没有新正文时也必须写出重复计数。
    const bool completed = g_flushCv.wait_for(lk, std::chrono::milliseconds(LOG_FLUSH_MAX_WAIT_MS), [target, request]() -> bool {
        return (static_cast<int32_t>(g_flushedIndex.load(std::memory_order_acquire) - target) >= 0
            && static_cast<int32_t>(g_flushCompleted.load(std::memory_order_acquire) - request) >= 0)
            || g_shutdown.load();
    });
    return completed && !g_shutdown.load() && g_globalWritable.load(std::memory_order_acquire) ? 1 : 0;
}

/** 保留旧 ABI；需要准确失败反馈的新调用方使用 checked 或状态接口。 */
extern "C" void amclLogFlush(void) { (void)amclLogFlushChecked(); }

extern "C" const char* amclLogGetStatus(void) {
    thread_local char status[256];
    snprintf(status, sizeof(status), "{\"writable\":%s,\"writeFailures\":%lu,\"lostWrites\":%lu,\"lastError\":%d,\"longMessageBytes\":%zu}",
        g_globalWritable.load() ? "true" : "false", g_globalFailures.load(), g_globalLostWrites.load(),
        g_globalLastError.load(), g_longMessageBytes.load());
    return status;
}

extern "C" const char* amclLogGetPath(void) {
    return g_logPath.c_str();
}

extern "C" const char* amclLogRead(int maxBytes) {
    if (g_logPath.empty()) {
        g_readCache = "(日志系统未初始化)";
        return g_readCache.c_str();
    }
    
    // 先刷新缓冲区
    amclLogFlush();

    // ============================================================
    //  2026-07-30（活动账本 · L1-b）：跨轮转读取。
    //
    //  旧实现只 fopen(g_logPath)，也就是当前 amcl_launcher.log。轮转出去的
    //  .1.log ~ .5.log（最多 10 MiB）就在磁盘上，ArkTS 侧却一个字节都取不到。
    //  后果：凡是稍早一点的活动，「按时间窗回溯它的日志」必然落空，用户看到的
    //  是「该时间段日志已滚动」—— 而日志其实还在，只是读不到。
    //
    //  现在按时间顺序（最旧的 .N → .1 → 当前）拼接，再从整体尾部取 maxBytes。
    //  倒序遍历备份号：.N 是最旧的（rotateLogFiles 每次把 .N-1 改名成 .N）。
    // ============================================================
    if (maxBytes <= 0) {
        g_readCache.clear();
        return g_readCache.c_str();
    }

    // 候选文件按时间从旧到新
    std::vector<std::string> files;
    for (int i = g_maxFiles; i >= 1; i--) {
        std::string p = g_logDir + "/amcl_launcher." + std::to_string(i) + ".log";
        if (getFileSize(p.c_str()) > 0) files.push_back(p);
    }
    files.push_back(g_logPath);

    // 从最新往回累计，凑够 maxBytes 就停 —— 避免把 10 MiB 全读进内存再截断
    struct Piece { std::string path; long start; long len; };
    std::vector<Piece> pieces;
    long remaining = maxBytes;
    for (int i = static_cast<int>(files.size()) - 1; i >= 0 && remaining > 0; i--) {
        long sz = getFileSize(files[i].c_str());
        if (sz <= 0) continue;
        long take = sz > remaining ? remaining : sz;
        Piece pc;
        pc.path = files[i];
        pc.start = sz - take;   // 只有最靠前的那片可能从中间开始
        pc.len = take;
        pieces.push_back(pc);
        remaining -= take;
    }
    if (pieces.empty()) {
        g_readCache = "(日志文件不存在)";
        return g_readCache.c_str();
    }

    // pieces 是从新到旧收集的，输出要从旧到新
    g_readCache.clear();
    g_readCache.reserve(static_cast<size_t>(maxBytes - remaining));
    for (int i = static_cast<int>(pieces.size()) - 1; i >= 0; i--) {
        FILE* f = fopen(pieces[i].path.c_str(), "r");
        if (!f) continue;
        if (pieces[i].start > 0) fseek(f, pieces[i].start, SEEK_SET);
        size_t base = g_readCache.size();
        g_readCache.resize(base + static_cast<size_t>(pieces[i].len));
        size_t got = fread(&g_readCache[base], 1, static_cast<size_t>(pieces[i].len), f);
        fclose(f);
        if (got < static_cast<size_t>(pieces[i].len)) {
            g_readCache.resize(base + got);   // 读少了就按实际长度收缩，不留脏字节
        }
    }
    return g_readCache.c_str();
}

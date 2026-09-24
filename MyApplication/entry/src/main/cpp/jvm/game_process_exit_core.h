/**
 * 游戏退出纯核心：固定容量序列化、一次会话状态与有界 I/O 调用次数。
 * 产品 POSIX 适配和宿主 fake-I/O 使用同一状态机，不在测试里复制退出算法。
 * “有界”指缓冲区和系统调用次数；POSIX fsync/文件系统本身没有墙钟超时保证。
 */
#ifndef AMCL_GAME_PROCESS_EXIT_CORE_H
#define AMCL_GAME_PROCESS_EXIT_CORE_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace amcl::gameexit {

constexpr std::size_t PathCapacity = 4096;
constexpr std::size_t RecordCapacity = 320;
constexpr std::int64_t MaxActivity = INT64_C(9007199254740991);
constexpr int RetryLimit = 32;
constexpr int HandoffTimeoutMs = 3000;
constexpr int PollLimit = 64;
// Pending 与 deferred ack 是两个独立 atomic。四个握手操作必须处于同一个 SC 总序，
// 否则 release/acquire 的 store-buffering 允许双方同时读旧值，导致确认没有进入 pipe。
constexpr std::memory_order HandoffHandshakeOrder = std::memory_order_seq_cst;
static_assert(std::atomic<int>::is_always_lock_free, "exit phase must not acquire a runtime lock");

// 返回值和 EINTR 独立表达，避免多个虚拟操作之间依赖线程 errno 的隐含状态。
struct IoResult { std::int64_t value; bool interrupted; };

/**
 * 产品只提供 POSIX 薄适配。函数均不得抛异常；退出阶段只调用 now/write/sync/publish。
 * openAuthority 必须验证借用锁确已持有，并返回本模块拥有的 filesDir fd；失败返回负数。
 * createRecord 必须拒绝既有 final/tmp 文件。所有 close 都只用于模块自己打开的 fd。
 */
class Operations {
public:
    virtual ~Operations() = default;
    virtual int pid() const noexcept = 0;
    virtual int openAuthority(const char* filesDir, int borrowedLockFd) noexcept = 0;
    virtual bool checkAuthority(int filesDirFd, int borrowedLockFd) noexcept = 0;
    virtual int openRecordDirectory(int filesDirFd) noexcept = 0;
    virtual int createRecord(int directoryFd, const char* temporary, const char* finalName) noexcept = 0;
    // prepare 专用清理：只可删除调用方本次成功创建的空文件，不能删除已有会话证据。
    virtual void removeOwnedTemporary(int directoryFd, const char* name) noexcept = 0;
    virtual bool createAckChannel(int& readFd, int& writeFd) noexcept = 0;
    virtual void closeOwned(int fd) noexcept = 0;
    virtual std::int64_t nowMs() noexcept = 0;
    virtual std::int64_t monotonicMs() noexcept = 0;
    virtual IoResult writeRecord(int fd, const char* bytes, std::size_t count) noexcept = 0;
    virtual IoResult sync(int fd) noexcept = 0;
    virtual IoResult publish(int directoryFd, const char* temporary, const char* finalName) noexcept = 0;
    // sendAck：成功写 1 字节；pollAck：1=读到有效 ack，0=一次 poll 超时，2=可重试唤醒。
    // pipe 必须非阻塞；pollAck 仅等待传入的剩余毫秒，不能自行刷新总截止时间。
    virtual IoResult sendAck(int writeFd) noexcept = 0;
    virtual IoResult pollAck(int readFd, int timeoutMs) noexcept = 0;
};

// filesDir 来自本应用 context，必须是有界绝对目录；拒绝根目录、控制字符及 . / .. 分量。
inline bool ValidDirectory(const char* value) noexcept
{
    if (!value || value[0] != '/') return false;
    std::size_t length = 0;
    while (length < PathCapacity && value[length]) {
        const unsigned char ch = static_cast<unsigned char>(value[length]);
        if (ch < 32 || ch == 127) return false;
        ++length;
    }
    if (length < 2 || length == PathCapacity || value[length - 1] == '/') return false;
    std::size_t begin = 1;
    for (std::size_t index = 1; index <= length; ++index) {
        if (index != length && value[index] != '/') continue;
        const std::size_t part = index - begin;
        if (part == 0 || (part == 1 && value[begin] == '.') ||
            (part == 2 && value[begin] == '.' && value[begin + 1] == '.')) return false;
        begin = index + 1;
    }
    return true;
}

/** 固定缓冲拼接器；不使用 iostream/snprintf/locale，连 INT64_MIN 也不做有符号取负。 */
class Buffer {
public:
    Buffer(char* target, std::size_t capacity) noexcept : bytes_(target), capacity_(capacity) {}
    void text(const char* value) noexcept
    {
        for (std::size_t index = 0; value[index]; ++index) character(value[index]);
    }
    void number(std::int64_t value) noexcept
    {
        std::uint64_t magnitude = static_cast<std::uint64_t>(value);
        if (value < 0) { character('-'); magnitude = static_cast<std::uint64_t>(-(value + 1)) + 1; }
        char reversed[20]; std::size_t count = 0;
        do { reversed[count++] = static_cast<char>('0' + magnitude % 10); magnitude /= 10; } while (magnitude);
        while (count) character(reversed[--count]);
    }
    std::size_t finish() noexcept
    {
        if (!ok_ || !bytes_ || length_ >= capacity_) return 0;
        bytes_[length_] = '\0'; return length_;
    }
private:
    void character(char value) noexcept
    {
        if (!bytes_ || length_ + 1 >= capacity_) { ok_ = false; return; }
        bytes_[length_++] = value;
    }
    char* bytes_; std::size_t capacity_; std::size_t length_ = 0; bool ok_ = true;
};

// 只写可信数字和常量字符串，不拼接路径、用户文本或错误信息到退出 JSON。
inline std::size_t Serialize(char* target, std::size_t capacity, std::int64_t activity,
                             int pid, int parent, int code, std::int64_t timestamp) noexcept
{
    Buffer out(target, capacity);
    out.text("{\"schema\":1,\"activityId\":"); out.number(activity);
    out.text(",\"pid\":"); out.number(pid);
    out.text(",\"parentPid\":"); out.number(parent);
    out.text(",\"exitCode\":"); out.number(code);
    out.text(",\"source\":\"jvm-exit\",\"timestamp\":"); out.number(timestamp < 0 ? 0 : timestamp);
    out.text("}\n"); return out.finish();
}

// handoff 结果只作诊断；acknowledged 表示 UI 已发送确认，不等于系统证明启动器已在前台。
inline std::size_t SerializeHandoff(char* target, std::size_t capacity, std::int64_t activity,
                                    int pid, int code, const char* outcome, std::int64_t timestamp) noexcept
{
    Buffer out(target, capacity);
    out.text("{\"schema\":1,\"activityId\":"); out.number(activity);
    out.text(",\"pid\":"); out.number(pid); out.text(",\"exitCode\":"); out.number(code);
    out.text(",\"source\":\"jvm-exit-handoff\",\"outcome\":\""); out.text(outcome);
    out.text("\",\"waitBudgetMs\":3000,\"timestamp\":"); out.number(timestamp < 0 ? 0 : timestamp);
    out.text("}\n"); return out.finish();
}

enum class Acknowledgement { NoPending, Owned, Failed };

/**
 * 状态只向前，准备失败可回到 Authorized 重试，但成功准备后不能换 activity。
 * 发布身份后所有配置字段不再修改，release/acquire 保证 JVM 退出线程读到完整快照。
 * PID 检查独立于 fd：fork 子进程即使继承同一个 open-file-description，也不继承会话。
 */
class State final {
public:
    int authorize(Operations& ops, const char* filesDir, int parent, int borrowedLock) noexcept
    {
        const int current = ops.pid();
        if (current <= 0 || parent <= 0 || current == parent || borrowedLock < 0 || !ValidDirectory(filesDir)) return -1;
        int phase = phase_.load(std::memory_order_acquire);
        if (phase == Authorized || phase == Prepared) {
            if (owner_ != current || parent_ != parent || lock_ != borrowedLock || std::strcmp(path_, filesDir) != 0) return -2;
            return ops.checkAuthority(files_, lock_) ? 0 : -3;
        }
        if (phase != Empty || !phase_.compare_exchange_strong(phase, Authorizing, std::memory_order_acq_rel)) return -4;
        const int files = ops.openAuthority(filesDir, borrowedLock);
        if (files < 0) { phase_.store(Empty, std::memory_order_release); return -3; }
        std::memcpy(path_, filesDir, std::strlen(filesDir) + 1);
        owner_ = current; parent_ = parent; lock_ = borrowedLock; files_ = files;
        phase_.store(Authorized, std::memory_order_release);
        return 0;
    }

    int prepare(Operations& ops, const char* filesDir, std::int64_t activity) noexcept
    {
        int phase = phase_.load(std::memory_order_acquire);
        if (phase == Empty) return 1;
        if (phase == Authorizing) return -4;
        if (owner_ != ops.pid()) return 1;
        if (!ValidDirectory(filesDir) || std::strcmp(path_, filesDir) != 0 || activity <= 0 || activity > MaxActivity) return -1;
        if (phase == Prepared) return activity == activity_ && ops.checkAuthority(files_, lock_) ? 0 : -2;
        if (phase != Authorized || !phase_.compare_exchange_strong(phase, Preparing, std::memory_order_acq_rel)) return -4;
        if (!ops.checkAuthority(files_, lock_)) { phase_.store(Authorized, std::memory_order_release); return -3; }
        char temporary[48], finalName[48], handoffName[48];
        Buffer temp(temporary, sizeof(temporary)); temp.number(activity); temp.text(".json.tmp");
        Buffer finalBuffer(finalName, sizeof(finalName)); finalBuffer.number(activity); finalBuffer.text(".json");
        Buffer handoff(handoffName, sizeof(handoffName)); handoff.number(activity); handoff.text(".handoff.log");
        if (!temp.finish() || !finalBuffer.finish() || !handoff.finish()) { phase_.store(Authorized, std::memory_order_release); return -1; }
        const int directory = ops.openRecordDirectory(files_);
        if (directory < 0) { phase_.store(Authorized, std::memory_order_release); return -3; }
        int ackRead = -1, ackWrite = -1;
        if (!ops.createAckChannel(ackRead, ackWrite)) {
            ops.closeOwned(directory); phase_.store(Authorized, std::memory_order_release); return -3;
        }
        // 诊断文件同样预先独占创建；绝不在 VM 退出线程上再 open 或动态拼路径。
        const int handoffRecord = ops.createRecord(directory, handoffName, handoffName);
        if (handoffRecord < 0) {
            ops.closeOwned(ackRead); ops.closeOwned(ackWrite); ops.closeOwned(directory);
            phase_.store(Authorized, std::memory_order_release); return -3;
        }
        const int record = ops.createRecord(directory, temporary, finalName);
        if (record < 0) {
            ops.closeOwned(handoffRecord); ops.removeOwnedTemporary(directory, handoffName);
            ops.closeOwned(ackRead); ops.closeOwned(ackWrite); ops.closeOwned(directory);
            phase_.store(Authorized, std::memory_order_release); return -3;
        }
        std::memcpy(temporary_, temporary, std::strlen(temporary) + 1);
        std::memcpy(final_, finalName, std::strlen(finalName) + 1);
        directory_ = directory; record_ = record; activity_ = activity;
        handoffRecord_ = handoffRecord; ackRead_ = ackRead; ackWrite_ = ackWrite;
        phase_.store(Prepared, std::memory_order_release);
        return 0;
    }

    bool armed(Operations& ops) const noexcept
    {
        return phase_.load(std::memory_order_acquire) == Prepared && owner_ == ops.pid();
    }

    bool authorized(Operations& ops) const noexcept
    {
        return phase_.load(std::memory_order_acquire) >= Authorized && owner_ == ops.pid();
    }

    bool pending(Operations& ops) const noexcept
    {
        const int phase = phase_.load(std::memory_order_acquire);
        return (phase == Pending || phase == Finished) && owner_ == ops.pid();
    }

    /** 前台 UI 的非阻塞确认；不等待 VM 线程。重复调用不重复写 pipe。 */
    Acknowledgement acknowledge(Operations& ops, int& originalCode) noexcept
    {
        // 写记录尚未发布 Pending 时，UI 不得误走旧 _exit(0) 抢断 JVM 停机。
        // 只记确认，不读尚未发布的 exitCode。发布后的再次检查关闭与 emit 的交错窗口。
        if (phase_.load(std::memory_order_acquire) == Exiting && owner_ == ops.pid()) {
            ackDeferred_.store(true, HandoffHandshakeOrder);
            if (phase_.load(HandoffHandshakeOrder) == Exiting) return Acknowledgement::Owned;
        }
        if (!pending(ops)) return Acknowledgement::NoPending;
        originalCode = exitCode_;
        bool expected = false;
        if (!ackStarted_.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return Acknowledgement::Owned;
        for (int attempt = 0; attempt <= RetryLimit; ++attempt) {
            const IoResult result = ops.sendAck(ackWrite_);
            if (result.value == 1) return Acknowledgement::Owned;
            if (!(result.value < 0 && result.interrupted)) break;
        }
        reportHandoff(ops, "ack-write-error");
        return Acknowledgement::Failed;
    }

    /**
     * 终态记录只尝试一次：失败保留 .tmp，不制造完整 JSON；重复/并发退出不等待首个线程。
     * 完整请求发布后才把 code 和 Pending release 给 UI，防止 UI 先 ack/退出导致记录丢失。
     * 成功后调用方可做有期限 handoff；无论成败最后都必须 _exit 原 code，不返回 JVM。
     */
    bool emit(Operations& ops, int code) noexcept
    {
        if (!armed(ops)) return false;
        int expected = Prepared;
        if (!phase_.compare_exchange_strong(expected, Exiting, std::memory_order_acq_rel)) return false;
        char json[RecordCapacity];
        const std::size_t length = Serialize(json, sizeof(json), activity_, owner_, parent_, code, ops.nowMs());
        if (length == 0) return false;
        if (!writeAll(ops, record_, json, length) || !retry([&ops, this] { return ops.sync(record_); })) return false;
        if (!retry([&ops, this] { return ops.publish(directory_, temporary_, final_); })) return false;
        // 文件 rename 已成功后，即使目录 fsync 失败，final 仍是一份可解析的退出请求证据。
        if (!retry([&ops, this] { return ops.sync(directory_); })) return false;
        exitCode_ = code;
        phase_.store(Pending, HandoffHandshakeOrder);
        return true;
    }

    /**
     * 退出线程只等待原生 pipe。所有重试共用一个 CLOCK_MONOTONIC 绝对截止点，
     * EINTR/虚假唤醒不能把 3 秒延长为无限等待；时钟失败或调用预算耗尽立即结束交还。
     */
    const char* waitForHandoff(Operations& ops) noexcept
    {
        if (!pending(ops)) return "not-pending";
        if (ackDeferred_.load(HandoffHandshakeOrder)) {
            int code = 0;
            if (acknowledge(ops, code) == Acknowledgement::Failed) return finishHandoff(ops, "ack-write-error");
        }
        const std::int64_t start = ops.monotonicMs();
        if (start < 0 || start > INT64_MAX - HandoffTimeoutMs) return finishHandoff(ops, "clock-error");
        const std::int64_t deadline = start + HandoffTimeoutMs;
        int interrupts = 0;
        for (int attempt = 0; attempt < PollLimit; ++attempt) {
            const std::int64_t now = ops.monotonicMs();
            if (now < start) return finishHandoff(ops, "clock-error");
            if (now >= deadline) return finishHandoff(ops, "timeout");
            const IoResult result = ops.pollAck(ackRead_, static_cast<int>(deadline - now));
            if (result.value == 1) return finishHandoff(ops, "acknowledged");
            if (result.value < 0) {
                if (result.interrupted && interrupts++ < RetryLimit) continue;
                return finishHandoff(ops, result.interrupted ? "interrupt-budget" : "io-error");
            }
        }
        return finishHandoff(ops, "poll-budget");
    }

private:
    static bool writeAll(Operations& ops, int fd, const char* bytes, std::size_t length) noexcept
    {
        std::size_t written = 0;
        int attempts = 0, interrupts = 0;
        while (written < length && attempts++ < static_cast<int>(RecordCapacity) + RetryLimit) {
            const IoResult result = ops.writeRecord(fd, bytes + written, length - written);
            if (result.value < 0 && result.interrupted && interrupts++ < RetryLimit) continue;
            if (result.value <= 0 || static_cast<std::uint64_t>(result.value) > length - written) return false;
            written += static_cast<std::size_t>(result.value);
        }
        return written == length;
    }
    void reportHandoff(Operations& ops, const char* outcome) noexcept
    {
        char line[RecordCapacity];
        const std::size_t length = SerializeHandoff(line, sizeof(line), activity_, owner_, exitCode_, outcome, ops.nowMs());
        // 诊断写失败不改变原始退出码，也不再等待 fsync；它不参与终态账本判定。
        if (length) writeAll(ops, handoffRecord_, line, length);
    }
    const char* finishHandoff(Operations& ops, const char* outcome) noexcept
    {
        reportHandoff(ops, outcome);
        phase_.store(Finished, std::memory_order_release);
        return outcome;
    }
    template <typename Action> static bool retry(Action action) noexcept
    {
        for (int attempt = 0; attempt <= RetryLimit; ++attempt) {
            const IoResult result = action();
            if (result.value == 0) return true;
            if (!result.interrupted) return false;
        }
        return false;
    }
    enum Phase { Empty, Authorizing, Authorized, Preparing, Prepared, Exiting, Pending, Finished };
    std::atomic<int> phase_{Empty};
    std::atomic<bool> ackStarted_{false};
    std::atomic<bool> ackDeferred_{false};
    int owner_ = 0, parent_ = 0, lock_ = -1, files_ = -1, directory_ = -1, record_ = -1;
    int handoffRecord_ = -1, ackRead_ = -1, ackWrite_ = -1, exitCode_ = 0;
    std::int64_t activity_ = 0;
    char path_[PathCapacity]{}, temporary_[48]{}, final_[48]{};
};

} // namespace amcl::gameexit
#endif

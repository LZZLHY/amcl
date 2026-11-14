/**
 * 持有原线程 proc stat 文件的终止 token。当前目标合同只接受完整、身份一致的 X/Z
 * 记录；任何 errno（包括 ESRCH）、短读或身份漂移都不是死亡证据。此模块不释放 TLS，
 * 不领取 pthread_join 所有权，也不把公开 Linux 源码自动当作商业目标内核身份。
 */
#ifndef AMCL_THREAD_TERMINAL_TOKEN_H
#define AMCL_THREAD_TERMINAL_TOKEN_H
#include <cstdint>
#include <cstddef>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <climits>
#include <atomic>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <sys/syscall.h>

namespace amcl::threadterminal {
struct Stat {
    uint32_t tid = 0;
    uint64_t startTime = 0;
    char state = 0;
};

/** 无分配整数解析，拒绝符号错位、溢出和空字段；不会读取指定边界之外的字节。 */
inline bool number(const char*& cursor, const char* end, uint64_t& value, bool& negative) {
    negative = cursor < end && *cursor == '-';
    if (negative) ++cursor;
    const char* first = cursor;
    value = 0;
    while (cursor < end && *cursor >= '0' && *cursor <= '9') {
        const unsigned digit = static_cast<unsigned>(*cursor++ - '0');
        if (value > (UINT64_MAX - digit) / 10) return false;
        value = value * 10 + digit;
    }
    return cursor != first && (!negative || value <= (uint64_t(1) << 63));
}

/** Linux 常返回相对路径，当前 HarmonyOS 返回 /proc/ 绝对前缀；都只接受固定根下的规范组件。 */
inline bool parseSelfPath(const char* path, size_t bytes, uint32_t& group, uint32_t& thread) {
    if (!path || !bytes || bytes >= 128) return false;
    const char* cursor = path;
    const char* end = path + bytes;
    if (bytes >= 6 && std::memcmp(cursor, "/proc/", 6) == 0) cursor += 6;
    uint64_t tgid = 0, tid = 0;
    bool negative = false;
    if (!number(cursor, end, tgid, negative) || negative || !tgid || tgid > INT_MAX ||
        end - cursor < 6 || std::memcmp(cursor, "/task/", 6) != 0) return false;
    cursor += 6;
    if (!number(cursor, end, tid, negative) || negative || !tid || tid > INT_MAX || cursor != end) return false;
    group = static_cast<uint32_t>(tgid); thread = static_cast<uint32_t>(tid);
    return true;
}

/** 按完整 stat 数字区解析；comm 中可以有空格/括号，使用最后一个右括号作为边界。 */
inline bool parseStat(const char* data, size_t size, Stat& output) {
    if (!data || size == 0 || size >= 8192 || std::memchr(data, 0, size)) return false;
    const char* end = data + size;
    const char* cursor = data;
    uint64_t pid = 0;
    bool negative = false;
    if (!number(cursor, end, pid, negative) || negative || !pid || pid > INT_MAX ||
        end - cursor < 3 || cursor[0] != ' ' || cursor[1] != '(') return false;
    const char* close = nullptr;
    for (const char* scan = cursor + 2; scan < end; ++scan) if (*scan == ')') close = scan;
    if (!close || end - close < 4 || close[1] != ' ' || close[3] != ' ') return false;
    const char state = close[2];
    if (!((state >= 'A' && state <= 'Z') || state == 't')) return false;
    cursor = close + 4;
    unsigned field = 4;
    uint64_t startTime = 0;
    while (cursor < end) {
        if (*cursor == '\n' && cursor + 1 == end) { ++cursor; break; }
        uint64_t value = 0;
        if (!number(cursor, end, value, negative)) return false;
        if (field == 22) {
            if (negative || !value) return false;
            startTime = value;
        }
        ++field;
        if (cursor == end) break;
        if (*cursor == '\n' && cursor + 1 == end) { ++cursor; break; }
        if (*cursor++ != ' ' || cursor == end) return false;
    }
    if (cursor != end || field < 53 || !startTime) return false;
    output = {static_cast<uint32_t>(pid), startTime, state};
    return true;
}

enum class Observation { Live, Terminal, Unknown };
enum class Failure { None, Process, Descriptor, Identity, Read, Record };

/**
 * 目标能力探针：signal=0 只查询本进程是否还存在指定线程，不投递信号。
 * ESRCH 的解释来自 tgkill 接口合同，和读取 proc 文件得到 ESRCH/EINVAL 完全不同。
 * 返回成功只能表示该编号当前存在，不能证明仍是原线程；编号复用会保守延迟判定。
 * 此处尚未解决复用造成的回收延迟，也未作为产品 TLS 回收依据，必须单独完成目标资格。
 */
class ExistenceProbe {
public:
    int openCurrent() {
        if (process_ != 0) return EALREADY;
        const pid_t process = getpid();
        const long thread = syscall(SYS_gettid);
        if (process <= 0 || thread <= 0 || thread > INT_MAX) return EPROTO;
        if (syscall(SYS_tgkill, process, static_cast<pid_t>(thread), 0) != 0) return errno;
        process_ = process; tid_ = static_cast<pid_t>(thread);
        return 0;
    }
    Observation observe(int& error, Failure* failure = nullptr) const {
        error = 0;
        if (failure) *failure = Failure::None;
        if (process_ <= 0 || process_ != getpid()) {
            error = ECHILD;
            if (failure) *failure = Failure::Process;
            return Observation::Unknown;
        }
        if (terminal_.load(std::memory_order_acquire)) return Observation::Terminal;
        const long result = syscall(SYS_tgkill, process_, tid_, 0);
        if (result == 0) return Observation::Live;
        const int status = errno;
        if (status == ESRCH) {
            terminal_.store(true, std::memory_order_release);
            return Observation::Terminal;
        }
        // EPERM/ENOSYS/EINVAL 以及任何其他错误都保留为未知，不能用超时改变这个结果。
        error = status;
        if (failure) *failure = Failure::Read;
        return Observation::Unknown;
    }
    uint32_t tid() const { return static_cast<uint32_t>(tid_); }
private:
    pid_t process_ = 0, tid_ = 0;
    mutable std::atomic<bool> terminal_{false};
};

/** 单所有者 RAII token；注册在原线程内完成，之后仅由回收协调者读取/关闭。 */
class Token {
public:
    Token() = default;
    Token(const Token&) = delete;
    Token& operator=(const Token&) = delete;
    ~Token() { if (fd_ >= 0) close(fd_); if (directoryFd_ >= 0) close(directoryFd_); }

    /** 返回 errno 风格状态。全部身份与 warm read 合格之前，不发布可用 fd。 */
    int openCurrent(bool retainDirectory = false) {
        if (fd_ >= 0) return EALREADY;
        struct LocalFd { int fd; ~LocalFd() { if (fd >= 0) close(fd); } };
        LocalFd root{open("/proc", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (root.fd < 0) return errno;
        struct statfs filesystem{};
        if (fstatfs(root.fd, &filesystem) != 0) return errno;
        if (filesystem.f_type != 0x9fa0) return ENOTSUP;
        char identity[128];
        const ssize_t length = readlinkat(root.fd, "thread-self", identity, sizeof(identity));
        if (length < 0) return errno;
        if (length == 0 || length >= static_cast<ssize_t>(sizeof(identity))) return EOVERFLOW;
        uint32_t tgid = 0, tid = 0;
        if (!parseSelfPath(identity, static_cast<size_t>(length), tgid, tid)) return EPROTO;
        char groupName[16], threadName[16];
        std::snprintf(groupName, sizeof(groupName), "%u", static_cast<unsigned>(tgid));
        std::snprintf(threadName, sizeof(threadName), "%u", static_cast<unsigned>(tid));
        LocalFd group{openat(root.fd, groupName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (group.fd < 0) return errno;
        LocalFd tasks{openat(group.fd, "task", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (tasks.fd < 0) return errno;
        LocalFd thread{openat(tasks.fd, threadName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (thread.fd < 0) return errno;
        LocalFd token{openat(thread.fd, "stat", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)};
        if (token.fd < 0) return errno;
        struct stat attributes{};
        if (fstat(token.fd, &attributes) != 0 || fstatfs(token.fd, &filesystem) != 0) return errno;
        if (!S_ISREG(attributes.st_mode) || filesystem.f_type != 0x9fa0) return EPROTO;
        char bytes[8192];
        const ssize_t count = pread(token.fd, bytes, sizeof(bytes), 0);
        if (count < 0) return errno;
        Stat record;
        if (!parseStat(bytes, static_cast<size_t>(count), record) || record.tid != tid ||
            record.state == 'X' || record.state == 'Z') return EPROTO;
        tid_ = record.tid; startTime_ = record.startTime;
        device_ = attributes.st_dev; inode_ = attributes.st_ino; process_ = getpid();
        fd_ = token.fd; token.fd = -1;
        // 目标能力实验可显式保留线程目录；是否需要该额外引用须由设备验证决定。
        if (retainDirectory) { directoryFd_ = thread.fd; thread.fd = -1; }
        return 0;
    }

    /** 活线程/内核拒绝/损坏输入都不能误回收；X/Z 仍需匹配最初持有的同一文件身份。 */
    Observation observe(int& error, Failure* failure = nullptr) const {
        error = 0;
        if (failure) *failure = Failure::None;
        auto unknown = [&](int why, Failure step) { error = why; if (failure) *failure = step; return Observation::Unknown; };
        if (fd_ < 0 || process_ != getpid()) return unknown(ECHILD, Failure::Process);
        if (terminal_.load(std::memory_order_acquire)) return Observation::Terminal;
        struct stat attributes{};
        if (fstat(fd_, &attributes) != 0) return unknown(errno, Failure::Descriptor);
        if (attributes.st_dev != device_ || attributes.st_ino != inode_ || !S_ISREG(attributes.st_mode)) {
            return unknown(ESTALE, Failure::Identity);
        }
        char bytes[8192];
        ssize_t count = -1;
        for (unsigned attempt = 0; attempt < 3; ++attempt) {
            count = pread(fd_, bytes, sizeof(bytes), 0);
            if (count >= 0 || errno != EINTR) break;
        }
        if (count < 0) return unknown(errno, Failure::Read);
        Stat record;
        if (!parseStat(bytes, static_cast<size_t>(count), record) || record.tid != tid_ || record.startTime != startTime_) {
            return unknown(EPROTO, Failure::Record);
        }
        if (record.state == 'X' || record.state == 'Z') {
            // 一旦证明旧线程终止，后续 inode 回收/数值复用不能把该结果撤回为 LIVE。
            terminal_.store(true, std::memory_order_release);
            return Observation::Terminal;
        }
        return Observation::Live;
    }
    uint32_t tid() const { return tid_; }
private:
    int fd_ = -1;
    int directoryFd_ = -1;
    mutable std::atomic<bool> terminal_{false};
    pid_t process_ = 0;
    uint32_t tid_ = 0;
    uint64_t startTime_ = 0;
    dev_t device_ = 0;
    ino_t inode_ = 0;
};
}
#endif

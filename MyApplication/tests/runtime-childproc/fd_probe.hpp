/** 独立childproc资格夹具。准备/JSON/等待都在fork前的宿主或fork父侧执行；
 * childBody只调用固定syscall与C/POD候选，绝不回到C++/JNI运行时。
 * 该夹具不改变JDK默认机制，也不将本次FD清理通过等同完整childProcess安全闭包。
 */
#ifndef AMCL_CHILD_FD_PROBE_HPP
#define AMCL_CHILD_FD_PROBE_HPP
#include "child_fd_cleanup_candidate.h"
#include <chrono>
#include <csignal>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <poll.h>

namespace amcl::childfdprobe {
using Clock = std::chrono::steady_clock;
constexpr unsigned Magic = 0x46445031;
constexpr unsigned DenseCount = 8;
constexpr unsigned KnownCount = DenseCount + 2;

/** 管道只传固定、小于PIPE_BUF的POD；父侧校验长度/magic后才能解释字段。 */
struct ChildReport {
    unsigned magic, version;
    int pid, setupError, cleanupResult, cleanupError;
    unsigned setupStage, parentDeathGuard;
    unsigned closedKnown, unexpectedOpen, stdioPreserved, reportPreserved;
    amcl_child_fd_stats stats;
};
static_assert(sizeof(ChildReport) < 512, "single bounded pipe record");
struct Setup {
    int known[KnownCount], stdioOpen[3], reportRead, reportWrite, parentPid;
};

/** 每一步只使用已核SDK的SYS宏。报告对象在fork前清零，避免child中隐式memset。
 * FD3模拟四代JDK的FAIL_FILENO；stdio是否原本存在也必须保持，不能强造有效状态。
 */
[[noreturn]] inline void childBody(const Setup* setup, int strategy, ChildReport* report) {
    int output = 3;
    report->pid = (int)syscall(SYS_getpid);
    // 外层官方NCP超时终止时，内层直接child也必须由内核收口；核对PPID封住设置前竞态。
    if (syscall(SYS_prctl, (long)PR_SET_PDEATHSIG, (long)SIGKILL, (long)0, (long)0, (long)0) < 0) {
        report->setupError = errno; report->setupStage = 1;
    } else report->parentDeathGuard = 1;
    if (syscall(SYS_getppid) != setup->parentPid) {
        syscall(SYS_exit_group, (long)88);
        for (;;) syscall(SYS_exit, (long)88);
    }
    if (setup->reportWrite != 3 && syscall(SYS_dup3, (long)setup->reportWrite, (long)3, (long)0) < 0) {
        if (!report->setupError) { report->setupError = errno; report->setupStage = 2; }
        output = setup->reportWrite;
    }
    if (!report->setupError) {
        report->cleanupResult = amcl_child_fd_cleanup(4, strategy, &report->stats);
        report->cleanupError = report->cleanupResult ? errno : 0;
        for (unsigned i = 0; i < KnownCount; ++i) {
            const long result = syscall(SYS_fcntl, (long)setup->known[i], (long)F_GETFD, (long)0);
            if (result < 0 && errno == EBADF) ++report->closedKnown;
            else ++report->unexpectedOpen;
        }
        for (unsigned i = 0; i < 3; ++i) {
            const long result = syscall(SYS_fcntl, (long)i, (long)F_GETFD, (long)0);
            if ((result >= 0 && setup->stdioOpen[i]) ||
                (result < 0 && errno == EBADF && !setup->stdioOpen[i])) ++report->stdioPreserved;
        }
        report->reportPreserved = syscall(SYS_fcntl, (long)3, (long)F_GETFD, (long)0) >= 0;
    }
    long written;
    do { written = syscall(SYS_write, (long)output, report, sizeof(*report)); }
    while (written < 0 && errno == EINTR);
    const int ok = !report->setupError && !report->cleanupResult &&
        report->closedKnown == KnownCount && report->stdioPreserved == 3 && report->reportPreserved &&
        written == (long)sizeof(*report);
    syscall(SYS_exit_group, (long)(ok ? 0 : 86));
    // exit_group正常不会返回；即使平台异常拒绝也不能运行任何C++析构/回到NCP。
    for (;;) syscall(SYS_exit, (long)87);
}

/** 以下RAII只在fork父侧析构；丢失wait所有权单独报告，不把ECHILD视作正常退出。 */
class Fd {
    int value_ = -1;
public:
    explicit Fd(int fd = -1) : value_(fd) {}
    ~Fd() { if (value_ >= 0) close(value_); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
    int get() const { return value_; }
    void set(int fd) { if (value_ >= 0) close(value_); value_ = fd; }
};
class ChildOwner {
    pid_t pid_ = -1;
public:
    void adopt(pid_t pid) noexcept { pid_ = pid; }
    void reaped() noexcept { pid_ = -1; }
    ~ChildOwner() {
        if (pid_ < 0) return;
        int status;
        pid_t got;
        do { got = waitpid(pid_, &status, WNOHANG); } while (got < 0 && errno == EINTR);
        if (got == 0) {
            // 未回收的直接child仍占据PID，不能误杀复用后的别的进程。
            kill(pid_, SIGKILL);
            do { got = waitpid(pid_, &status, 0); } while (got < 0 && errno == EINTR);
        }
    }
};
inline void require(bool value, const char* action) {
    if (!value) throw std::runtime_error(std::string(action) + ": errno=" + std::to_string(errno));
}
inline const char* strategyName(int strategy) {
    return strategy == AMCL_CHILD_FD_RANGE_ONLY ? "close-range" :
        strategy == AMCL_CHILD_FD_DENTS_ONLY ? "raw-getdents64" : "auto";
}

/** 每行包含真实waitpid分类；若内核以SIGSYS拒绝syscall，会原样记录signal且没有伪报告。
 * 5秒deadline只控制这个直接child；超时先kill/回收，再返回，外层NCP还有独立官方owner。
 */
inline std::string runOne(int strategy) {
    const auto begin = Clock::now();
    Setup setup{};
    ChildReport packet{};
    packet.magic = Magic; packet.version = 1;
    Fd base(open("/dev/null", O_RDONLY | O_CLOEXEC));
    require(base.get() >= 0, "open fixed null fixture");
    Fd known[KnownCount];
    for (unsigned i = 0; i < DenseCount; ++i) {
        known[i].set(fcntl(base.get(), F_DUPFD_CLOEXEC, 32));
        require(known[i].get() >= 32, "prepare dense FD");
        setup.known[i] = known[i].get();
    }
    struct rlimit limit{};
    require(getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur > 96, "read parent FD bound");
    const int highWanted = limit.rlim_cur > 65536 ? 65535 : (int)limit.rlim_cur - 1;
    known[DenseCount].set(fcntl(base.get(), F_DUPFD_CLOEXEC, highWanted));
    require(known[DenseCount].get() >= highWanted, "prepare sparse high FD");
    setup.known[DenseCount] = known[DenseCount].get();
    // 该FD晚于初始稠密/高位集合创建，证明仅按旧父侧名单关闭会漏掉它。
    known[DenseCount + 1].set(fcntl(base.get(), F_DUPFD_CLOEXEC, 64));
    require(known[DenseCount + 1].get() >= 64, "prepare late FD");
    setup.known[DenseCount + 1] = known[DenseCount + 1].get();
    int descriptors[2]; require(pipe2(descriptors, O_CLOEXEC) == 0, "prepare report pipe");
    Fd input(descriptors[0]), output(descriptors[1]);
    setup.reportRead = input.get(); setup.reportWrite = output.get();
    setup.parentPid = getpid();
    for (unsigned i = 0; i < 3; ++i) setup.stdioOpen[i] = fcntl((int)i, F_GETFD) >= 0;
    // 所有C++对象与报告缓冲在fork前构造；child分支永不返回。
    ChildOwner owner;
    const pid_t child = fork();
    if (child == 0) childBody(&setup, strategy, &packet);
    require(child >= 0, "fork isolated FD child");
    owner.adopt(child); output.set(-1);
    require(fcntl(input.get(), F_SETFL, O_NONBLOCK) == 0, "make parent report read nonblocking");
    size_t bytes = 0;
    int status = 0, waitError = 0;
    bool reaped = false, timedOut = false;
    const auto deadline = Clock::now() + std::chrono::seconds(5);
    for (;;) {
        while (bytes < sizeof(packet)) {
            const ssize_t got = read(input.get(), reinterpret_cast<char*>(&packet) + bytes, sizeof(packet) - bytes);
            if (got > 0) bytes += (size_t)got;
            else if (got < 0 && errno == EINTR) continue;
            else break;
        }
        pid_t got;
        do { got = waitpid(child, &status, WNOHANG); } while (got < 0 && errno == EINTR);
        if (got == child) { reaped = true; owner.reaped(); break; }
        if (got < 0) { waitError = errno; break; }
        if (Clock::now() >= deadline) {
            timedOut = true;
            kill(child, SIGKILL);
            do { got = waitpid(child, &status, 0); } while (got < 0 && errno == EINTR);
            if (got == child) { reaped = true; owner.reaped(); }
            else waitError = errno;
            break;
        }
        pollfd pending{input.get(), POLLIN | POLLHUP, 0};
        poll(&pending, 1, 10);
        if (pending.revents & POLLHUP) poll(nullptr, 0, 1);
    }
    // child可能在上次read与waitpid之间写入；实际结束后再读一次剩余固定记录。
    while (bytes < sizeof(packet)) {
        const ssize_t got = read(input.get(), reinterpret_cast<char*>(&packet) + bytes, sizeof(packet) - bytes);
        if (got > 0) bytes += (size_t)got;
        else if (got < 0 && errno == EINTR) continue;
        else break;
    }
    unsigned parentOpen = 0;
    for (const auto& fd : known) if (fcntl(fd.get(), F_GETFD) >= 0) ++parentOpen;
    const bool packetValid = bytes == sizeof(packet) && packet.magic == Magic && packet.version == 1 && packet.pid == child;
    const bool passed = reaped && !timedOut && !waitError && WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
        packetValid && !packet.cleanupResult && packet.closedKnown == KnownCount && packet.stdioPreserved == 3 &&
        packet.reportPreserved && parentOpen == KnownCount;
    std::ostringstream json;
    json << "{\"strategy\":\"" << strategyName(strategy) << "\",\"passed\":" << (passed ? "true" : "false")
         << ",\"childPid\":" << child << ",\"reaped\":" << (reaped ? "true" : "false")
         << ",\"timedOut\":" << (timedOut ? "true" : "false") << ",\"waitErrno\":" << waitError
         << ",\"waitStatus\":" << (reaped ? std::to_string(status) : "null")
         << ",\"exitCode\":" << (reaped && WIFEXITED(status) ? std::to_string(WEXITSTATUS(status)) : "null")
         << ",\"terminationSignal\":" << (reaped && WIFSIGNALED(status) ? std::to_string(WTERMSIG(status)) : "null")
         << ",\"recordBytes\":" << bytes << ",\"recordValid\":" << (packetValid ? "true" : "false")
         << ",\"knownFdCount\":" << KnownCount << ",\"sparseHighFd\":" << setup.known[DenseCount]
         << ",\"lateFd\":" << setup.known[DenseCount + 1] << ",\"lateCreatedAfterInitialSet\":true"
         << ",\"parentKnownStillOpen\":" << parentOpen;
    if (packetValid) {
        json << ",\"setupErrno\":" << packet.setupError << ",\"cleanupResult\":" << packet.cleanupResult
             << ",\"setupStage\":" << packet.setupStage << ",\"parentDeathGuard\":" << packet.parentDeathGuard
             << ",\"cleanupErrno\":" << packet.cleanupError << ",\"knownClosed\":" << packet.closedKnown
             << ",\"unexpectedOpen\":" << packet.unexpectedOpen << ",\"stdioPreserved\":" << packet.stdioPreserved
             << ",\"reportFd3Preserved\":" << (packet.reportPreserved ? "true" : "false")
             << ",\"method\":" << packet.stats.method << ",\"failureStage\":" << packet.stats.stage
             << ",\"rangeAttempted\":" << packet.stats.range_attempted << ",\"rangeErrno\":" << packet.stats.range_error
             << ",\"getdentsCalls\":" << packet.stats.getdents_calls << ",\"records\":" << packet.stats.records
             << ",\"closeCalls\":" << packet.stats.close_calls;
    }
    json << ",\"elapsedMicros\":" << std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - begin).count() << '}';
    return json.str();
}

/** 三种固定方式分别隔离；AUTO成功不能遮蔽强制内核分支的失败/信号。
 * 没有ArkTS提供的任意指令/路径/模式，也不执行任何Java或下载的二进制。
 */
inline std::string run() {
    std::ostringstream result;
    result << "{\"schema\":1,\"kind\":\"ChildFdCleanupCandidate\",\"parentPid\":" << getpid()
           << ",\"productionMechanismChanged\":false,\"rows\":[";
    const int strategies[] = {AMCL_CHILD_FD_RANGE_ONLY, AMCL_CHILD_FD_DENTS_ONLY, AMCL_CHILD_FD_AUTO};
    bool first = true;
    for (int strategy : strategies) {
        if (!first) result << ',';
        first = false;
        try { result << runOne(strategy); }
        catch (const std::exception& error) {
            // 这里只处理父侧准备失败；字符串不来自任意可执行输入，仍转义JSON特殊字符。
            result << "{\"strategy\":\"" << strategyName(strategy) << "\",\"passed\":false,\"preparationError\":\"";
            for (const char* p = error.what(); *p; ++p) {
                if (*p == '"' || *p == '\\') result << '\\';
                if ((unsigned char)*p >= 32) result << *p;
            }
            result << "\"}";
        }
    }
    result << "]}\n";
    return result.str();
}
}
#endif

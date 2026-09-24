/**
 * 独立游戏进程退出的 POSIX 薄适配。授权/预备发生在 JNI_CreateJavaVM 前，
 * VM Thread 的 hook 做固定容量写盘，并以单调时钟期限等候原生 ack pipe；
 * UI 未确认也会在期限后 _exit，不调用 JVM/NAPI，不依赖常驻 worker 或异步日志线程。
 * 标准 JNI hook 不覆盖 early vm_direct_exit、native 自行 exit 或真正的 abort/fatal。
 */
#include "game_process_exit.h"
#include "game_process_exit_core.h"
#include "../utils/session_log_io.h"

#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace {
using amcl::gameexit::IoResult;

// flock 必须非阻塞，EINTR 重试次数也受限；绝不关闭或解锁调用方借给我们的 fd。
int tryLock(int fd) noexcept
{
    int result = -1;
    for (int attempt = 0; attempt <= amcl::gameexit::RetryLimit; ++attempt) {
        result = flock(fd, LOCK_EX | LOCK_NB);
        if (result == 0 || errno != EINTR) break;
    }
    return result;
}

/**
 * 验证 fd 确实指向当前 filesDir/.desktop-game.lock，并已经拥有排他 flock。
 * 先用另一 open-file-description 探测：如果它能拿锁，原 fd 没持锁，释放探针锁并拒绝；
 * 若它被阻塞，再验证借用 fd 能重申自己的锁，避免把别人的持锁误当成本方授权。
 */
bool ownsGameLock(int files, int borrowed) noexcept
{
    struct stat original{};
    if (borrowed < 0 || fstat(borrowed, &original) != 0 || !S_ISREG(original.st_mode)) return false;
    const int probe = openat(files, ".desktop-game.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (probe < 0) return false;
    struct stat path{};
    if (fstat(probe, &path) != 0 || !S_ISREG(path.st_mode) ||
        original.st_dev != path.st_dev || original.st_ino != path.st_ino) {
        close(probe); return false;
    }
    const int probeResult = tryLock(probe);
    const int probeError = errno;
    if (probeResult == 0) {
        // 仅释放本模块探针的锁；借用 fd 从未被加锁、解锁或关闭。
        flock(probe, LOCK_UN); close(probe); return false;
    }
    close(probe);
    if (probeError != EWOULDBLOCK && probeError != EAGAIN) return false;
    return tryLock(borrowed) == 0;
}

class PosixOperations final : public amcl::gameexit::Operations {
public:
    int pid() const noexcept override { return static_cast<int>(getpid()); }
    int openAuthority(const char* filesDir, int lock) noexcept override
    {
        const int files = open(filesDir, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (files < 0) return -1;
        if (!ownsGameLock(files, lock)) { close(files); return -1; }
        return files;
    }
    bool checkAuthority(int files, int lock) noexcept override { return ownsGameLock(files, lock); }
    int openRecordDirectory(int files) noexcept override
    {
        if (mkdirat(files, "game-exits", 0700) != 0 && errno != EEXIST) return -1;
        return openat(files, "game-exits", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    }
    int createRecord(int directory, const char* temporary, const char* finalName) noexcept override
    {
        struct stat existing{};
        if (fstatat(directory, finalName, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) return -1;
        // activity 为单次启动身份，已有同名临时件也是冲突，不覆盖上次未完成退出的证据。
        return openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    }
    void removeOwnedTemporary(int directory, const char* name) noexcept override { unlinkat(directory, name, 0); }
    bool createAckChannel(int& readFd, int& writeFd) noexcept override
    {
        int channel[2];
        if (pipe2(channel, O_CLOEXEC | O_NONBLOCK) != 0) return false;
        readFd = channel[0]; writeFd = channel[1]; return true;
    }
    void closeOwned(int fd) noexcept override { close(fd); }
    std::int64_t nowMs() noexcept override
    {
        struct timespec now{};
        if (clock_gettime(CLOCK_REALTIME, &now) != 0 || now.tv_sec < 0 ||
            static_cast<std::uint64_t>(now.tv_sec) > (INT64_MAX - 999) / 1000) return 0;
        return static_cast<std::int64_t>(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
    }
    std::int64_t monotonicMs() noexcept override
    {
        struct timespec now{};
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
            static_cast<std::uint64_t>(now.tv_sec) > (INT64_MAX - 999) / 1000) return -1;
        return static_cast<std::int64_t>(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
    }
    IoResult writeRecord(int fd, const char* bytes, std::size_t length) noexcept override
    {
        const ssize_t count = write(fd, bytes, length);
        return {static_cast<std::int64_t>(count), count < 0 && errno == EINTR};
    }
    IoResult sync(int fd) noexcept override
    {
        const int result = fsync(fd); return {result, result < 0 && errno == EINTR};
    }
    IoResult publish(int directory, const char* temporary, const char* finalName) noexcept override
    {
        const int result = renameat(directory, temporary, directory, finalName);
        return {result, result < 0 && errno == EINTR};
    }
    IoResult sendAck(int fd) noexcept override
    {
        const unsigned char byte = 0x41;
        const ssize_t count = write(fd, &byte, 1);
        return {static_cast<std::int64_t>(count), count < 0 && errno == EINTR};
    }
    IoResult pollAck(int fd, int timeoutMs) noexcept override
    {
        struct pollfd descriptor{fd, POLLIN, 0};
        const int result = poll(&descriptor, 1, timeoutMs);
        if (result <= 0) return {result, result < 0 && errno == EINTR};
        if ((descriptor.revents & POLLIN) != 0) {
            unsigned char byte = 0;
            const ssize_t count = read(fd, &byte, 1);
            if (count == 1 && byte == 0x41) return {1, false};
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return {2, false};
            return {-1, count < 0 && errno == EINTR};
        }
        return {-1, false}; // EOF、POLLERR、POLLNVAL 不能伪装成 UI 已确认。
    }
};

PosixOperations operations;
amcl::gameexit::State state;
} // namespace

extern "C" int amclGameExitAuthorize(const char* filesDir, int parentPid, int borrowedLockFd)
{
    return state.authorize(operations, filesDir, parentPid, borrowedLockFd);
}

extern "C" int amclGameExitPrepare(const char* filesDir, int64_t activityId)
{
    return state.prepare(operations, filesDir, activityId);
}

extern "C" bool amclGameExitArmedForCurrentProcess(void)
{
    return state.armed(operations);
}

extern "C" bool amclGameExitAuthorizedForCurrentProcess(void)
{
    return state.authorized(operations);
}

extern "C" bool amclGameExitPendingForCurrentProcess(void)
{
    return state.pending(operations);
}

extern "C" bool amclGameExitAcknowledgeRequested(void)
{
    int originalCode = 0;
    const auto result = state.acknowledge(operations, originalCode);
    if (result == amcl::gameexit::Acknowledgement::Failed) { amcl::sessionlog::finish(); _exit(originalCode); }
    return result == amcl::gameexit::Acknowledgement::Owned;
}

extern "C" void amclGameJvmExitHook(int code)
{
    // 失败/继承身份/重入均不回到已停止的 JVM；不因为记录失败把正常退出改成 abort。
    // _exit 只结束调用它的当前进程。原始 int 代码完整写入 JSON，OS 可能仅保留其低 8 位。
    if (state.emit(operations, code)) state.waitForHandoff(operations);
    amcl::sessionlog::finish();
    _exit(code);
}

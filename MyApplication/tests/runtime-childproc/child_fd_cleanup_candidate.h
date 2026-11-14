/* OHOS childproc候选：只依赖已声明syscall、errno与POD，不使用堆、DIR*、stdio或JNI。
 * 当前仅由独立测试/TestHooks消费，尚未进入JDK活动patch series或改变生产启动机制。
 * 正常范围从FAIL_FILENO+1（四代目前为4）开始；调用者必须保留低位stdio/fail pipe。
 * 测试可强制两个真实内核分支，生产候选AUTO不会把getdents失败替换成RLIMIT慢循环。
 */
#ifndef AMCL_CHILD_FD_CLEANUP_CANDIDATE_H
#define AMCL_CHILD_FD_CLEANUP_CANDIDATE_H
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef AMCL_CHILD_FD_SYSCALL
#define AMCL_CHILD_FD_SYSCALL syscall
#endif
enum amcl_child_fd_strategy { AMCL_CHILD_FD_AUTO = 0, AMCL_CHILD_FD_RANGE_ONLY = 1, AMCL_CHILD_FD_DENTS_ONLY = 2 };
enum amcl_child_fd_stage { AMCL_CHILD_FD_OK = 0, AMCL_CHILD_FD_ARGUMENT = 1, AMCL_CHILD_FD_RANGE = 2,
    AMCL_CHILD_FD_RESERVE = 3, AMCL_CHILD_FD_OPEN = 4, AMCL_CHILD_FD_READ = 5,
    AMCL_CHILD_FD_DECODE = 6, AMCL_CHILD_FD_CLOSE = 7, AMCL_CHILD_FD_DIRECTORY_CLOSE = 8 };
struct amcl_child_fd_stats {
    unsigned method, stage, range_attempted, getdents_calls, records, close_calls;
    int range_error, error;
};

/* 原始linux_dirent64的固定字段偏移来自实际SDK/AArch64编译断言。按字节读d_reclen，
 * 因此故障夹具的未对齐输入也不会产生C未定义行为。每次必定前进或返回错误。 */
static inline int amcl_child_fd_decode(const unsigned char* data, size_t available, size_t* consumed, int* fd) {
    size_t length, i;
    unsigned value = 0, digits = 0;
    int numeric = 1, terminated = 0;
    if (available < 20) { errno = EIO; return -1; }
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    length = ((size_t)data[16] << 8) | data[17];
#else
    length = data[16] | ((size_t)data[17] << 8);
#endif
    if (length < 24 || (length & 7) || length > available) { errno = EIO; return -1; }
    *fd = -1;
    for (i = 19; i < length; ++i) {
        unsigned char c = data[i];
        if (!c) { terminated = 1; break; }
        if (c < '0' || c > '9') numeric = 0;
        if (numeric) {
            if (value > ((unsigned)INT_MAX - (unsigned)(c - '0')) / 10) { errno = EOVERFLOW; return -1; }
            value = value * 10 + (unsigned)(c - '0'); ++digits;
        }
    }
    if (!terminated || i == 19) { errno = EIO; return -1; }
    if (!numeric) {
        if (!((i == 20 && data[19] == '.') || (i == 21 && data[19] == '.' && data[20] == '.'))) {
            errno = EIO; return -1; // /proc/self/fd只有dot与十进制FD，不能静默忽略异常记录。
        }
    } else if (digits) *fd = (int)value;
    *consumed = length;
    return 0;
}

/* 失败阶段与最初errno独立保存；清理目录FD不得把第一错误覆盖掉。 */
static inline int amcl_child_fd_fail(struct amcl_child_fd_stats* stats, unsigned stage, int error) {
    if (stats) { stats->stage = stage; stats->error = error; }
    errno = error; return -1;
}

/* Linux close在EINTR时已释放FD；不能盲目重试并可能关闭后来的新FD。EBADF已满足关闭目标。
 * 其它错误保留为准备失败，调用者必须沿fail pipe/_exit收口，不能继续exec泄漏未知FD。 */
static inline int amcl_child_fd_close_one(int fd, struct amcl_child_fd_stats* stats) {
    long result;
    if (stats) ++stats->close_calls;
    result = AMCL_CHILD_FD_SYSCALL(SYS_close, (long)fd);
    return result == 0 || errno == EBADF || errno == EINTR ? 0 : -1;
}

/* 只有child自己的/proc/self/fd能覆盖fork时的真实表；不能预开父目录FD或仅复制父FD名单。
 * 4096字节对齐栈缓冲与实际FD数量成比例，不根据RLIMIT对空洞执行百万次close。 */
static inline int amcl_child_fd_cleanup(unsigned first, int strategy, struct amcl_child_fd_stats* stats) {
    int directory, saved_error = 0;
    unsigned saved_stage = AMCL_CHILD_FD_OK;
    union { uint64_t alignment; unsigned char bytes[4096]; } buffer;
    if (stats) {
        stats->method = 0; stats->stage = 0; stats->range_attempted = 0; stats->getdents_calls = 0;
        stats->records = 0; stats->close_calls = 0; stats->range_error = 0; stats->error = 0;
    }
    if (first > INT_MAX || strategy < AMCL_CHILD_FD_AUTO || strategy > AMCL_CHILD_FD_DENTS_ONLY)
        return amcl_child_fd_fail(stats, AMCL_CHILD_FD_ARGUMENT, EINVAL);
    if (strategy != AMCL_CHILD_FD_DENTS_ONLY) {
#ifdef SYS_close_range
        if (stats) stats->range_attempted = 1;
        if (AMCL_CHILD_FD_SYSCALL(SYS_close_range, (unsigned long)first, (unsigned long)UINT_MAX, (long)0) == 0) {
            if (stats) stats->method = AMCL_CHILD_FD_RANGE_ONLY;
            return 0;
        }
        if (stats) stats->range_error = errno;
#else
        errno = ENOSYS;
        if (stats) stats->range_error = ENOSYS;
#endif
        if (strategy == AMCL_CHILD_FD_RANGE_ONLY) return amcl_child_fd_fail(stats, AMCL_CHILD_FD_RANGE, errno);
    }
    if (stats) stats->method = AMCL_CHILD_FD_DENTS_ONLY;
    // FD表正好填满时先腾出一个可关闭的低槽；它本就属于目标清理范围。
    if (amcl_child_fd_close_one((int)first, stats) != 0)
        return amcl_child_fd_fail(stats, AMCL_CHILD_FD_RESERVE, errno);
    do {
        directory = (int)AMCL_CHILD_FD_SYSCALL(SYS_openat, (long)AT_FDCWD, "/proc/self/fd",
            (long)(O_RDONLY | O_DIRECTORY | O_CLOEXEC), (long)0);
    } while (directory < 0 && errno == EINTR);
    if (directory < 0) return amcl_child_fd_fail(stats, AMCL_CHILD_FD_OPEN, errno);
    for (;;) {
        long bytes;
        size_t at = 0;
        if (stats) ++stats->getdents_calls;
        bytes = AMCL_CHILD_FD_SYSCALL(SYS_getdents64, (long)directory, buffer.bytes, sizeof(buffer.bytes));
        if (bytes < 0 && errno == EINTR) continue;
        if (bytes < 0) { saved_error = errno; saved_stage = AMCL_CHILD_FD_READ; break; }
        if (bytes == 0) break;
        if ((unsigned long)bytes > sizeof(buffer.bytes)) { saved_error = EIO; saved_stage = AMCL_CHILD_FD_READ; break; }
        while (at < (size_t)bytes) {
            size_t consumed;
            int fd;
            if (amcl_child_fd_decode(buffer.bytes + at, (size_t)bytes - at, &consumed, &fd) != 0) {
                saved_error = errno; saved_stage = AMCL_CHILD_FD_DECODE; break;
            }
            if (stats) ++stats->records;
            if (fd >= 0 && (unsigned)fd >= first && fd != directory && amcl_child_fd_close_one(fd, stats) != 0) {
                saved_error = errno; saved_stage = AMCL_CHILD_FD_CLOSE; break;
            }
            at += consumed;
        }
        if (saved_error) break;
    }
    if (amcl_child_fd_close_one(directory, stats) != 0 && !saved_error) {
        saved_error = errno; saved_stage = AMCL_CHILD_FD_DIRECTORY_CLOSE;
    }
    if (saved_error) return amcl_child_fd_fail(stats, saved_stage, saved_error);
    return 0;
}
#endif

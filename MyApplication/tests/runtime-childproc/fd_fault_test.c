/* 只在宿主父侧注入系统调用故障，验证C候选对畸形数据、errno及回退的精确处理。
 * 真实内核行为另由fd_probe_host执行；替身成功不能当作OHOS内核支持证明。
 */
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
static long fake_syscall(long number, ...);
#define AMCL_CHILD_FD_SYSCALL fake_syscall
#include "child_fd_cleanup_candidate.h"

enum Fault { CLEAN, RANGE_ENOSYS, OPEN_DENIED, READ_FAILED, READ_INTERRUPTED, CLOSE_FAILED,
    DIRECTORY_CLOSE_FAILED, DECODE_FAILED_AND_CLOSE_FAILED, RESERVE_FAILED, OPEN_INTERRUPTED,
    RANGE_DENIED, READ_OVERSIZED, CLOSE_INTERRUPTED, CLOSE_ALREADY_GONE };
static enum Fault fault;
static unsigned ranges, opens, reads, closes, closed_low, closed_high, closed_late;
static unsigned char records[512];
static size_t record_bytes;

/* 构造真实ABI的24/32字节记录；只供宿主故障样本准备，child候选不调用字符串库。 */
static size_t add_record(const char* name) {
    const size_t n = strlen(name), length = (19 + n + 1 + 7) & ~(size_t)7;
    unsigned char* at = records + record_bytes;
    assert(record_bytes + length <= sizeof(records));
    memset(at, 0, length);
    at[16] = (unsigned char)length; at[17] = (unsigned char)(length >> 8);
    memcpy(at + 19, name, n + 1);
    record_bytes += length;
    return length;
}
static void reset(enum Fault selected) {
    fault = selected;
    ranges = opens = reads = closes = closed_low = closed_high = closed_late = 0;
    record_bytes = 0;
    add_record("."); add_record(".."); add_record("0"); add_record("3"); add_record("4");
    add_record("32"); add_record("65535"); add_record("64");
}
static long fail(int error) { errno = error; return -1; }
static long fake_syscall(long number, ...) {
    va_list args;
    va_start(args, number);
    long result = -1;
    if (number == SYS_close_range) {
        assert(va_arg(args, unsigned long) == 4);
        assert(va_arg(args, unsigned long) == UINT_MAX);
        assert(va_arg(args, long) == 0);
        ++ranges;
        result = fault == CLEAN ? 0 : fail(fault == RANGE_DENIED ? EPERM : ENOSYS);
    } else if (number == SYS_close) {
        const long fd = va_arg(args, long);
        ++closes;
        assert(fd != 0 && fd != 3);
        if (fd == 4 && closes == 1 && fault == RESERVE_FAILED) result = fail(EPERM);
        else if (fd == 32 && fault == CLOSE_FAILED) result = fail(EIO);
        else if (fd == 4 && closes > 1 &&
            (fault == DIRECTORY_CLOSE_FAILED || fault == DECODE_FAILED_AND_CLOSE_FAILED)) result = fail(EPERM);
        else {
            if (fd == 32) ++closed_low;
            if (fd == 65535) ++closed_high;
            if (fd == 64) ++closed_late;
            result = fd == 32 && fault == CLOSE_INTERRUPTED ? fail(EINTR) :
                fd == 32 && fault == CLOSE_ALREADY_GONE ? fail(EBADF) : 0;
        }
    } else if (number == SYS_openat) {
        assert(va_arg(args, long) == AT_FDCWD);
        assert(strcmp(va_arg(args, const char*), "/proc/self/fd") == 0);
        assert(va_arg(args, long) == (O_RDONLY | O_DIRECTORY | O_CLOEXEC));
        assert(va_arg(args, long) == 0);
        ++opens;
        result = fault == OPEN_DENIED ? fail(EACCES) :
            fault == OPEN_INTERRUPTED && opens == 1 ? fail(EINTR) : 4;
    } else if (number == SYS_getdents64) {
        assert(va_arg(args, long) == 4);
        unsigned char* out = va_arg(args, unsigned char*);
        const size_t size = va_arg(args, size_t);
        assert(size == 4096);
        ++reads;
        if (fault == READ_FAILED) result = fail(EIO);
        else if (fault == READ_OVERSIZED) result = (long)size + 1;
        else if (fault == READ_INTERRUPTED && reads == 1) result = fail(EINTR);
        else if (reads == (fault == READ_INTERRUPTED ? 2u : 1u)) {
            memcpy(out, records, record_bytes);
            if (fault == DECODE_FAILED_AND_CLOSE_FAILED) out[16] = 0;
            result = (long)record_bytes;
        } else result = 0;
    } else assert(!"unapproved syscall in child cleanup");
    va_end(args);
    return result;
}

/* 解码负例覆盖边界/溢出/非法名称，并测试未对齐地址，ASan/UBSan也检查宿主样本访问。 */
static void decoder_tests(void) {
    unsigned char data[96];
    size_t used = 0;
    int fd = -2;
    reset(CLEAN);
    const unsigned char* source = records + 5 * 24;
    memset(data, 0, sizeof(data)); memcpy(data + 1, source, 24);
    assert(amcl_child_fd_decode(data + 1, 24, &used, &fd) == 0 && used == 24 && fd == 32);
    assert(amcl_child_fd_decode(data + 1, 19, &used, &fd) < 0 && errno == EIO);
    data[17] = 0;
    assert(amcl_child_fd_decode(data + 1, 24, &used, &fd) < 0 && errno == EIO);
    data[17] = 23;
    assert(amcl_child_fd_decode(data + 1, 24, &used, &fd) < 0 && errno == EIO);
    data[17] = 32;
    assert(amcl_child_fd_decode(data + 1, 24, &used, &fd) < 0 && errno == EIO);
    data[17] = 24;
    memset(data + 20, '1', 5);
    assert(amcl_child_fd_decode(data + 1, 24, &used, &fd) < 0 && errno == EIO);
    record_bytes = 0; add_record("2147483647");
    assert(amcl_child_fd_decode(records, record_bytes, &used, &fd) == 0 && fd == INT_MAX);
    record_bytes = 0; add_record("2147483648");
    assert(amcl_child_fd_decode(records, record_bytes, &used, &fd) < 0 && errno == EOVERFLOW);
    const char* invalid[] = {"", "-1", "32x", "...", "x"};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        record_bytes = 0; add_record(invalid[i]);
        assert(amcl_child_fd_decode(records, record_bytes, &used, &fd) < 0 && errno == EIO);
    }
}

static void expect_failure(enum Fault selected, unsigned stage, int error) {
    struct amcl_child_fd_stats stats;
    reset(selected);
    assert(amcl_child_fd_cleanup(4, AMCL_CHILD_FD_DENTS_ONLY, &stats) == -1);
    assert(errno == error && stats.error == error && stats.stage == stage);
    if (stage >= AMCL_CHILD_FD_READ) assert(closes >= 2); // 第一错误之后仍尝试关闭目录。
}
int main(void) {
    struct amcl_child_fd_stats stats;
    decoder_tests();
    reset(CLEAN);
    assert(amcl_child_fd_cleanup(4, AMCL_CHILD_FD_AUTO, &stats) == 0);
    assert(ranges == 1 && !opens && !closes && stats.method == AMCL_CHILD_FD_RANGE_ONLY);
    reset(RANGE_ENOSYS);
    assert(amcl_child_fd_cleanup(4, AMCL_CHILD_FD_RANGE_ONLY, &stats) == -1);
    assert(errno == ENOSYS && stats.stage == AMCL_CHILD_FD_RANGE && !opens);
    const enum Fault successes[] = {RANGE_ENOSYS, RANGE_DENIED, READ_INTERRUPTED,
        OPEN_INTERRUPTED, CLOSE_INTERRUPTED, CLOSE_ALREADY_GONE};
    for (unsigned i = 0; i < sizeof(successes) / sizeof(successes[0]); ++i) {
        reset(successes[i]);
        assert(amcl_child_fd_cleanup(4, AMCL_CHILD_FD_AUTO, &stats) == 0);
        assert(stats.method == AMCL_CHILD_FD_DENTS_ONLY && stats.range_attempted == 1);
        assert(stats.range_error == (successes[i] == RANGE_DENIED ? EPERM : ENOSYS));
        assert(closed_low == 1 && closed_high == 1 && closed_late == 1 && closes == 5);
        assert(stats.records == 8 && stats.getdents_calls <= 3);
    }
    expect_failure(RESERVE_FAILED, AMCL_CHILD_FD_RESERVE, EPERM);
    expect_failure(OPEN_DENIED, AMCL_CHILD_FD_OPEN, EACCES);
    expect_failure(READ_FAILED, AMCL_CHILD_FD_READ, EIO);
    expect_failure(READ_OVERSIZED, AMCL_CHILD_FD_READ, EIO);
    expect_failure(CLOSE_FAILED, AMCL_CHILD_FD_CLOSE, EIO);
    expect_failure(DIRECTORY_CLOSE_FAILED, AMCL_CHILD_FD_DIRECTORY_CLOSE, EPERM);
    expect_failure(DECODE_FAILED_AND_CLOSE_FAILED, AMCL_CHILD_FD_DECODE, EIO);
    reset(CLEAN);
    assert(amcl_child_fd_cleanup(UINT_MAX, AMCL_CHILD_FD_AUTO, &stats) < 0 && errno == EINVAL && !ranges);
    assert(amcl_child_fd_cleanup(4, -1, &stats) < 0 && errno == EINVAL && !ranges);
    puts("PASS childproc FD candidate: malformed records, range fallback, errno preservation, cleanup and EINTR");
    return 0;
}

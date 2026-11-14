/**
 * 不可变内存的标准 FILE 载体。每个流独占一次分配，fclose 调用 cookie close
 * 释放该分配，允许任意数量的并发流，不需要共享环、全局表或 fclose 拦截。
 */
#pragma once
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits>
#include <new>

namespace amcl::ifinet6 {
namespace detail {
struct ReadCookie {
    size_t length;
    size_t position;
};

/** stdio 已串行化同一流的访问；不同流没有共享状态。EOF 不访问尾部之外内存。 */
inline ssize_t cookieRead(void* opaque, char* output, size_t wanted) {
    auto* cookie = static_cast<ReadCookie*>(opaque);
    if (cookie->position >= cookie->length) return 0;
    size_t count = cookie->length - cookie->position;
    if (count > wanted) count = wanted;
    if (count > static_cast<size_t>(std::numeric_limits<ssize_t>::max()))
        count = static_cast<size_t>(std::numeric_limits<ssize_t>::max());
    memcpy(output, reinterpret_cast<const char*>(cookie + 1) + cookie->position, count);
    cookie->position += count;
    return static_cast<ssize_t>(count);
}

/** 支持 seek 到 EOF 之后；拒绝负位置和整数溢出，失败时不改变原游标。 */
inline int cookieSeek(void* opaque, off_t* offset, int origin) {
    auto* cookie = static_cast<ReadCookie*>(opaque);
    off_t base = 0;
    if (origin == SEEK_CUR) base = static_cast<off_t>(cookie->position);
    else if (origin == SEEK_END) base = static_cast<off_t>(cookie->length);
    else if (origin != SEEK_SET) { errno = EINVAL; return -1; }
    if (*offset < -base || *offset > std::numeric_limits<off_t>::max() - base) {
        errno = EINVAL;
        return -1;
    }
    *offset += base;
    cookie->position = static_cast<size_t>(*offset);
    return 0;
}

/** 唯一释放点；不依赖调用线程身份，fclose 在另一个线程执行也成立。 */
inline int cookieClose(void* opaque) {
    free(opaque);
    return 0;
}
}

/** 复制输入快照后返回只读流。失败保留 errno，绝不返回悬空或可共享覆盖的 FILE。 */
inline FILE* openOwnedReadStream(const char* text, size_t length) {
    if (!text && length) { errno = EINVAL; return nullptr; }
    if (length > std::numeric_limits<size_t>::max() - sizeof(detail::ReadCookie) ||
        length > static_cast<size_t>(std::numeric_limits<off_t>::max())) {
        errno = EOVERFLOW;
        return nullptr;
    }
    void* storage = malloc(sizeof(detail::ReadCookie) + length);
    if (!storage) { errno = ENOMEM; return nullptr; }
    auto* cookie = new (storage) detail::ReadCookie{length, 0};
    if (length) memcpy(cookie + 1, text, length);
    cookie_io_functions_t callbacks{};
    callbacks.read = detail::cookieRead;
    callbacks.seek = detail::cookieSeek;
    callbacks.close = detail::cookieClose;
    FILE* stream = fopencookie(cookie, "r", callbacks);
    if (!stream) {
        const int error = errno;
        free(cookie);
        errno = error;
    }
    return stream;
}
}

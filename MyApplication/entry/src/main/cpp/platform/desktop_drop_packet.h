#pragma once
#include <stddef.h>
#include <string.h>
// NUL-terminated absolute UTF-8 paths; pointers borrow the caller's packet.
static inline int amclDecodeDesktopDrop(const char* packet, size_t bytes, const char** paths, size_t capacity) {
    if (!packet || !paths || bytes == 0) return -1;
    size_t offset = 0, count = 0;
    while (offset < bytes) {
        const char* end = (const char*)memchr(packet + offset, 0, bytes - offset);
        if (!end || packet[offset] != '/' || end == packet + offset || count >= capacity) return -1;
        paths[count++] = packet + offset;
        offset = (size_t)(end - packet) + 1;
    }
    return (int)count;
}

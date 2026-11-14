/**
 * 唯一宿主DSO的导出入口。早期env发布与设备准备分开，避免首个JVM线程后setenv增加
 * environ条目。运行时对象保留到进程退出；End关闭设备并撤销能力，不热卸载已执行代码。
 */
#include "audio_core.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <unistd.h>
namespace {
std::mutex hostMutex;
std::atomic<amcl::audio::Runtime *> runtime{nullptr};
std::atomic<bool> active{false};
bool published = false, used = false;
AmclAudioApiV1 api{};
/** C ABI边界捕获分配/系统异常，异常不跨JNI或OpenAL的C函数表传播。 */
template <class F> int guarded(F fn) {
    try {
        return fn();
    } catch (...) {
        return AMCL_AUDIO_PLATFORM;
    }
}
amcl::audio::Runtime *current() { return runtime.load(std::memory_order_acquire); }
int open(int c, int r, int ch, int e, int b, uint64_t *h) {
    return guarded([=]() -> int {
        auto *p = current();
        return p ? p->open(c, r, ch, e, b, h) : AMCL_AUDIO_UNAVAILABLE;
    });
}
#define AMCL_UNARY(name)                                                                                     \
    int name(uint64_t h) {                                                                                   \
        return guarded([=]() -> int {                                                                        \
            auto *p = current();                                                                             \
            return p ? p->name(h) : AMCL_AUDIO_UNAVAILABLE;                                                  \
        });                                                                                                  \
    }
AMCL_UNARY(start)
AMCL_UNARY(stop)
AMCL_UNARY(requestFinish)
AMCL_UNARY(flush) AMCL_UNARY(drain) AMCL_UNARY(close) AMCL_UNARY(available) AMCL_UNARY(bufferSize)
    AMCL_UNARY(state) AMCL_UNARY(frameBytes)
#undef AMCL_UNARY
        int read(uint64_t h, void *data, int count, int block) {
    return guarded([=]() -> int {
        auto *p = current();
        return p ? p->read(h, data, count, block != 0) : AMCL_AUDIO_UNAVAILABLE;
    });
}
int write(uint64_t h, const void *data, int count) {
    return guarded([=]() -> int {
        auto *p = current();
        return p ? p->write(h, data, count) : AMCL_AUDIO_UNAVAILABLE;
    });
}
int64_t framePosition(uint64_t h) {
    try {
        auto *p = current();
        return p ? p->frames(h) : 0;
    } catch (...) {
        return 0;
    }
}
} // namespace
extern "C" AMCL_AUDIO_EXPORT int amclAudioHostPublishEarlyV1(void) {
    std::lock_guard<std::mutex> lock(hostMutex);
    if (published)
        return api.pid == static_cast<uint32_t>(getpid()) ? 0 : AMCL_AUDIO_INVALID;
    api = {AMCL_AUDIO_MAGIC,
           AMCL_AUDIO_ABI,
           sizeof(AmclAudioApiV1),
           static_cast<uint32_t>(getpid()),
           0,
           0,
           open,
           start,
           stop,
           flush,
           drain,
           close,
           read,
           write,
           available,
           bufferSize,
           state,
           frameBytes,
           framePosition,
           requestFinish};
    char text[128];
    std::snprintf(text, sizeof(text), "1:%u:%llx", api.pid,
                  static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&amclAudioHostGetV1)));
    if (setenv(AMCL_AUDIO_HOST_ENV, text, 1) != 0)
        return AMCL_AUDIO_PLATFORM;
    published = true;
    return 0;
}
extern "C" AMCL_AUDIO_EXPORT int amclAudioHostBeginV1(uint64_t session,
                                                      AmclAudioRecordPermissionV1 permission, void *context,
                                                      int foreground) {
    return guarded([=]() -> int {
        std::lock_guard<std::mutex> lock(hostMutex);
        if (!published || used || !session || api.pid != static_cast<uint32_t>(getpid()))
            return AMCL_AUDIO_INVALID;
        used = true;
        auto *owner = new amcl::audio::Runtime(amcl::audio::openOhaudio);
        runtime.store(owner, std::memory_order_release);
        const auto result = owner->begin(session, permission, context, foreground != 0);
        if (result != 0)
            return result;
        api.session = session;
        active.store(true, std::memory_order_release);
        return 0;
    });
}
extern "C" AMCL_AUDIO_EXPORT int amclAudioHostSetForegroundV1(uint64_t session, int foreground) {
    return guarded([=]() -> int {
        auto *p = current();
        return p ? p->foreground(session, foreground != 0) : AMCL_AUDIO_UNAVAILABLE;
    });
}
extern "C" AMCL_AUDIO_EXPORT int amclAudioHostRefreshPermissionV1(uint64_t session) {
    return guarded([=]() -> int {
        auto *p = current();
        return p ? p->refresh(session) : AMCL_AUDIO_UNAVAILABLE;
    });
}
extern "C" AMCL_AUDIO_EXPORT int amclAudioHostEndV1(uint64_t session) {
    return guarded([=]() -> int {
        std::lock_guard<std::mutex> lock(hostMutex);
        if (api.session != session || !session)
            return AMCL_AUDIO_INVALID;
        active.store(false, std::memory_order_release);
        auto *p = current();
        return p ? p->end(session) : AMCL_AUDIO_UNAVAILABLE;
    });
}
extern "C" AMCL_AUDIO_EXPORT const AmclAudioApiV1 *amclAudioHostGetV1(void) {
    return active.load(std::memory_order_acquire) && api.pid == static_cast<uint32_t>(getpid()) ? &api
                                                                                                : nullptr;
}

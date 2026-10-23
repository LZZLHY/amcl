#include "amcl_input_host_descriptor.h"

#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <new>
#ifndef _WIN32
#include <sys/mman.h>
#include <unistd.h>
#endif

#if defined(AMCL_DESCRIPTOR_MAPS_FOPEN_OBSERVER)
namespace {
std::atomic<uint32_t> g_descriptorMapsFopenCount{0u};
}
// GNU Host linker 只转接真实 fopen；无条件进入 __real_fopen，既不替换 maps 内容，
// 也不模拟读取成功。原 Publish 在公共锁前可能校验回调，所以观察计数用 atomic。
extern "C" FILE* __real_fopen(const char* path, const char* mode);
extern "C" FILE* __wrap_fopen(const char* path, const char* mode) {
    if (std::strcmp(path, "/proc/self/maps") == 0) {
        g_descriptorMapsFopenCount.fetch_add(1u, std::memory_order_relaxed);
    }
    return __real_fopen(path, mode);
}
#endif
#include <thread>
#include <vector>

namespace {

static_assert(
    (AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1 &
     (AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE |
      AMCL_INPUT_CAP_BACKEND_CONSUMER_READY |
      AMCL_INPUT_CAP_VERIFIED_RAW_RELATIVE |
      AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE)) == 0u,
    "optional migration capabilities must not become V1 descriptor requirements");

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "HOST DESCRIPTOR FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

int32_t Begin(uint64_t*) { return AMCL_INPUT_OK; }
int32_t End(uint64_t) { return AMCL_INPUT_OK; }
int32_t Submit(const AmclInputEvent*) { return AMCL_INPUT_OK; }
int32_t SubmitBatch(const AmclInputEvent*, uint32_t) { return AMCL_INPUT_OK; }
int32_t SubmitText(const AmclInputEvent*, const uint8_t*, uint32_t) {
    return AMCL_INPUT_OK;
}
int32_t Surface(const AmclInputSurfacePayload*) { return AMCL_INPUT_OK; }
int32_t Focus(uint32_t) { return AMCL_INPUT_OK; }
int32_t Device(uint64_t, uint32_t, uint32_t) { return AMCL_INPUT_OK; }
int32_t Reset(uint32_t) { return AMCL_INPUT_OK; }
int32_t Open(AmclInputConsumerHandle*) { return AMCL_INPUT_OK; }
int32_t Next(AmclInputConsumerHandle, AmclInputEvent*) { return AMCL_INPUT_OK; }
int32_t Read(AmclInputConsumerHandle, const AmclInputBlobRef*, uint8_t*,
             uint32_t, uint32_t*) { return AMCL_INPUT_OK; }
int32_t Release(AmclInputConsumerHandle, uint64_t) { return AMCL_INPUT_OK; }
int32_t Close(AmclInputConsumerHandle) { return AMCL_INPUT_OK; }
int32_t Snapshot(AmclInputSnapshotV1*) { return AMCL_INPUT_OK; }

AmclInputHostApiV1 ValidApi(uint64_t generation) {
    return {AMCL_INPUT_HOST_API_MAGIC, AMCL_INPUT_HOST_API_VERSION,
            sizeof(AmclInputHostApiV1),
            AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1, generation,
            Begin, End, Submit, SubmitBatch, SubmitText, Surface, Focus,
            Device, Reset, Open, Next, Read, Release, Close, Snapshot};
}

// 此 fixture 只提供合法函数地址/完整表布局，验证 descriptor 解析安全；
// 不执行输入 Core，不把这些表函数的返回值当游戏或宿主输入 ACK。
int32_t NextOrdered(AmclInputConsumerHandle, AmclInputEvent*, uint64_t,
                    uint64_t*) { return AMCL_INPUT_OK; }
int32_t DescriptorSpanPeekOrder(AmclInputConsumerHandle, uint64_t*) { return AMCL_INPUT_OK; }
uint64_t Fence() { return 0u; }
AmclInputHostApiV1 DescriptorSpanOrderedApi() {
    auto api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.capabilityBits |= AMCL_INPUT_CAP_INTERACTION_ORDER;
    api.nextOrderedEvent = NextOrdered;
    api.peekEventOrder = DescriptorSpanPeekOrder;
    api.interactionFence = Fence;
    return api;
}

void SetRaw(const char* value) {
    CHECK(amclInputHostDescriptorTestSetRawV1(value) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
}

void TestMissingAndRetry() {
    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    const AmclInputHostApiV1* resolved = reinterpret_cast<const AmclInputHostApiV1*>(1);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING);
    CHECK(resolved == nullptr);

    auto api = ValidApi(1u);
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &api);
}

void TestMalformedAndDescriptorVersion() {
    const char* malformed[] = {
        "", "garbage", "AMCL_INPUT_HOST_V1:",
        "AMCL_INPUT_HOST_V1:0000000000000001:not-hex",
        "AMCL_INPUT_HOST_V1:0000000000000001:0000000000000001:tail"};
    for (const char* value : malformed) {
        SetRaw(value);
        const AmclInputHostApiV1* resolved = nullptr;
        CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
              (value[0] == '\0' ? AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING
                                : AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED));
        CHECK(resolved == nullptr);
    }
    SetRaw("AMCL_INPUT_HOST_V2:0000000000000001:0000000000000001");
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED);
}

void TestZeroAddress() {
    char value[96]{};
    std::snprintf(value, sizeof(value), "AMCL_INPUT_HOST_V1:%016llx:%0*llx",
                  1ull, static_cast<int>(sizeof(uintptr_t) * 2u), 0ull);
    SetRaw(value);
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED);
    CHECK(resolved == nullptr);
}

void TestUnsafePointerRejectedWithoutDereference() {
    char value[96]{};
    std::snprintf(value, sizeof(value), "AMCL_INPUT_HOST_V1:%016llx:%0*llx",
                  static_cast<unsigned long long>(AMCL_INPUT_HOST_API_GENERATION),
                  static_cast<int>(sizeof(uintptr_t) * 2u), 1ull);
    SetRaw(value);
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER);
    CHECK(resolved == nullptr);
}

void TestVersionAndHeaderValidation() {
    auto api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    CHECK((api.capabilityBits & AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) ==
          0u);
    CHECK((api.capabilityBits & AMCL_INPUT_CAP_BACKEND_CONSUMER_READY) == 0u);
    CHECK((api.capabilityBits & AMCL_INPUT_CAP_VERIFIED_RAW_RELATIVE) == 0u);
    CHECK((api.capabilityBits &
           AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE) == 0u);
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    ++api.abiVersion;
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH);
    CHECK(resolved == nullptr);

    api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.magic = 0u;
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH);
    api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.structSize = static_cast<uint32_t>(AMCL_INPUT_HOST_API_V1_PREFIX_SIZE - 1u);
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH);
    api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.capabilityBits &= ~AMCL_INPUT_CAP_TYPED_EVENTS;
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_CAPABILITIES);
    api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.capabilityBits &= ~AMCL_INPUT_CAP_DIAGNOSTIC_DROP;
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_CAPABILITIES);
    api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.capabilityBits |= AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE;
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_CAPABILITIES);
    api.capabilityBits |= AMCL_INPUT_CAP_BACKEND_CONSUMER_READY;
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    api.capabilityBits |= AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE;
    CHECK(amclInputHostDescriptorPublishV1(&api) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
}

void TestGenerationBoundaries() {
    auto zero = ValidApi(0u);
    CHECK(amclInputHostDescriptorPublishV1(&zero) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION);
    auto terminal = ValidApi(UINT64_MAX);
    CHECK(amclInputHostDescriptorPublishV1(&terminal) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION);
    auto future = ValidApi(AMCL_INPUT_HOST_API_GENERATION + 1u);
    CHECK(amclInputHostDescriptorPublishV1(&future) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_GENERATION);
}

void TestEveryRequiredFunction() {
#define CHECK_MISSING(member) do { \
    auto api = ValidApi(AMCL_INPUT_HOST_API_GENERATION); \
    api.member = nullptr; \
    CHECK(amclInputHostDescriptorPublishV1(&api) == \
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INCOMPLETE); \
} while (0)
    CHECK_MISSING(beginSession);
    CHECK_MISSING(endSession);
    CHECK_MISSING(submitEvent);
    CHECK_MISSING(submitBatch);
    CHECK_MISSING(submitTextPacket);
    CHECK_MISSING(publishSurface);
    CHECK_MISSING(publishFocus);
    CHECK_MISSING(publishDeviceChange);
    CHECK_MISSING(requestReset);
    CHECK_MISSING(openConsumer);
    CHECK_MISSING(nextEvent);
    CHECK_MISSING(readPacketBlob);
    CHECK_MISSING(releasePacket);
    CHECK_MISSING(closeConsumer);
    CHECK_MISSING(getSnapshot);
#undef CHECK_MISSING
}

void TestCompleteSuccessAndOwnerPin() {
    auto first = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    auto duplicate = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    const AmclInputHostApiV1* resolved = nullptr;

    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorPublishV1(&first) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorPublishV1(&first) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &first);

    // A duplicate namespace may expose an equally shaped table, but replacing
    // the valid process owner would split existing consumers from producers.
    CHECK(amclInputHostDescriptorPublishV1(&duplicate) ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &first);

    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorPublishV1(&duplicate) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &duplicate);
    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
}

void TestConcurrentFirstValidOwnerWins() {
    constexpr size_t kContenders = 16u;
    std::array<AmclInputHostApiV1, kContenders> apis{};
    std::array<int32_t, kContenders> results{};
    std::vector<std::thread> threads;
    std::atomic<size_t> ready{0u};
    std::atomic<bool> start{false};
    for (auto& api : apis) {
        api = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    }

    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    for (size_t index = 0; index < kContenders; ++index) {
        threads.emplace_back([&, index]() {
            ready.fetch_add(1u, std::memory_order_release);
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            results[index] = amclInputHostDescriptorPublishV1(&apis[index]);
        });
    }
    while (ready.load(std::memory_order_acquire) != kContenders) {
        std::this_thread::yield();
    }
    start.store(true, std::memory_order_release);
    for (auto& thread : threads) thread.join();

    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    size_t winners = 0u;
    for (size_t index = 0; index < kContenders; ++index) {
        if (results[index] == AMCL_INPUT_HOST_DESCRIPTOR_OK) {
            ++winners;
            CHECK(resolved == &apis[index]);
        } else {
            CHECK(results[index] ==
                  AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT);
        }
    }
    CHECK(winners == 1u);
    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
}

void TestConcurrentResolveClearPublishIsNotTorn() {
    std::array<AmclInputHostApiV1, 2u> apis{
        ValidApi(AMCL_INPUT_HOST_API_GENERATION),
        ValidApi(AMCL_INPUT_HOST_API_GENERATION)};
    std::atomic<bool> start{false};
    std::atomic<uint32_t> unexpected{0u};
    constexpr uint32_t kIterations = 1500u;

    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    auto waitForStart = [&]() {
        while (!start.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
    };
    std::thread clearer([&]() {
        waitForStart();
        for (uint32_t index = 0; index < kIterations; ++index) {
            if (amclInputHostDescriptorClearV1() !=
                AMCL_INPUT_HOST_DESCRIPTOR_OK) {
                unexpected.fetch_add(1u, std::memory_order_relaxed);
            }
        }
    });
    std::thread publisherA([&]() {
        waitForStart();
        for (uint32_t index = 0; index < kIterations; ++index) {
            const int32_t result = amclInputHostDescriptorPublishV1(&apis[0]);
            if (result != AMCL_INPUT_HOST_DESCRIPTOR_OK &&
                result != AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT) {
                unexpected.fetch_add(1u, std::memory_order_relaxed);
            }
        }
    });
    std::thread publisherB([&]() {
        waitForStart();
        for (uint32_t index = 0; index < kIterations; ++index) {
            const int32_t result = amclInputHostDescriptorPublishV1(&apis[1]);
            if (result != AMCL_INPUT_HOST_DESCRIPTOR_OK &&
                result != AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT) {
                unexpected.fetch_add(1u, std::memory_order_relaxed);
            }
        }
    });
    std::thread resolver([&]() {
        waitForStart();
        for (uint32_t index = 0; index < kIterations; ++index) {
            const AmclInputHostApiV1* resolved = nullptr;
            const int32_t result = amclInputHostDescriptorResolveV1(&resolved);
            if (result == AMCL_INPUT_HOST_DESCRIPTOR_OK) {
                if (resolved != &apis[0] && resolved != &apis[1]) {
                    unexpected.fetch_add(1u, std::memory_order_relaxed);
                }
            } else if (result != AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING) {
                // A serialized clear may make the descriptor absent, but no
                // reader may observe half-written text or an unsafe pointer.
                unexpected.fetch_add(1u, std::memory_order_relaxed);
            }
        }
    });

    start.store(true, std::memory_order_release);
    clearer.join();
    publisherA.join();
    publisherB.join();
    resolver.join();
    CHECK(unexpected.load(std::memory_order_relaxed) == 0u);

    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorPublishV1(&apis[0]) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &apis[0]);
    CHECK(amclInputHostDescriptorClearV1() ==
          AMCL_INPUT_HOST_DESCRIPTOR_OK);
}


#ifndef _WIN32
// 使用现有 test transport 设置真实 mmap 地址。guard/坏表无法合法 Publish，
// 因此不借 Publish 在直接读取原表时绕过 Resolve 的生产安全读取边界。
void SetMappedTableAddress(const void* table) {
    char value[96]{};
    const int written = std::snprintf(
        value, sizeof(value), "AMCL_INPUT_HOST_V1:%016llx:%0*llx",
        static_cast<unsigned long long>(AMCL_INPUT_HOST_API_GENERATION),
        static_cast<int>(sizeof(uintptr_t) * 2u),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(table)));
    CHECK(written > 0 && static_cast<size_t>(written) < sizeof(value));
    SetRaw(value);
}

// 真实内存权限改变发生在成功 Resolve/warm 之后；每次解析仍须 fresh 拒绝。
// 这是异常安全负向合同，不授权生产 publisher 解除进程 pin 或调用旧借出指针。
void TestPosixWarmTableStillRequiresFreshMapping() {
    const long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0 && static_cast<size_t>(page) >= sizeof(AmclInputHostApiV1));
    const size_t bytes = static_cast<size_t>(page);
    void* region = mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(region != MAP_FAILED);
    auto* api = new (region) AmclInputHostApiV1(DescriptorSpanOrderedApi());
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorPublishV1(api) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == api);
    CHECK(mprotect(region, bytes, PROT_NONE) == 0);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER);
    CHECK(resolved == nullptr);
    CHECK(mprotect(region, bytes, PROT_READ | PROT_WRITE) == 0);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == api);
    CHECK(munmap(region, bytes) == 0);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_UNSAFE_POINTER);
    CHECK(resolved == nullptr);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
}

// 前缀紧贴不可读页仍是合法旧宿主；同一地址宣告 ORDER 才需证明扩展尾表。
// 不复制 guard 区域，不把相邻 VMA 的权限拼接成一个新的可接受表。
void TestPosixPrefixAndOrderedTailGuard() {
    const long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0 && static_cast<size_t>(page) >= sizeof(AmclInputHostApiV1));
    const size_t bytes = static_cast<size_t>(page);
    void* region = mmap(nullptr, bytes * 2u, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(region != MAP_FAILED);
    auto* first = static_cast<unsigned char*>(region);
    void* prefix = first + bytes - AMCL_INPUT_HOST_API_V1_PREFIX_SIZE;
    CHECK(reinterpret_cast<uintptr_t>(prefix) % alignof(AmclInputHostApiV1) == 0u);
    auto legacy = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    legacy.structSize = static_cast<uint32_t>(AMCL_INPUT_HOST_API_V1_PREFIX_SIZE);
    std::memcpy(prefix, &legacy, AMCL_INPUT_HOST_API_V1_PREFIX_SIZE);
    CHECK(mprotect(first + bytes, bytes, PROT_NONE) == 0);
    SetMappedTableAddress(prefix);
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == prefix);
    const auto ordered = DescriptorSpanOrderedApi();
    std::memcpy(prefix, &ordered, AMCL_INPUT_HOST_API_V1_PREFIX_SIZE);
#if defined(AMCL_DESCRIPTOR_MAPS_FOPEN_OBSERVER)
    g_descriptorMapsFopenCount.store(0u, std::memory_order_relaxed);
#endif
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH);
    CHECK(resolved == nullptr);
#if defined(AMCL_DESCRIPTOR_MAPS_FOPEN_OBSERVER)
    // 本次 prefix span 不足必须保留原 full fresh fallback；不是直接拒绝。
    CHECK(g_descriptorMapsFopenCount.load(std::memory_order_relaxed) == 2u);
#endif
    // 完整表落在第一条可读 VMA 中，证明同一 host fixture 的正向尾表仍通过。
    auto* full = new (region) AmclInputHostApiV1(ordered);
    SetMappedTableAddress(full);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == full);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(munmap(region, bytes * 2u) == 0);
}

// 真正 readable 相邻 VMA 保持原 POSIX full-range 能力结果。R/RW 权限使两页
// 不合并，prefix 读成功、full fresh fallback 仍找不到覆盖整个表的单条记录。
void TestPosixAdjacentReadableMappingsPreserveOriginalResult() {
    const long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0 && static_cast<size_t>(page) >= sizeof(AmclInputHostApiV1));
    const size_t bytes = static_cast<size_t>(page);
    void* region = mmap(nullptr, bytes * 2u, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(region != MAP_FAILED);
    auto* first = static_cast<unsigned char*>(region);
    void* table = first + bytes - AMCL_INPUT_HOST_API_V1_PREFIX_SIZE;
    const auto ordered = DescriptorSpanOrderedApi();
    std::memcpy(table, &ordered, sizeof(ordered));
    CHECK(mprotect(first, bytes, PROT_READ) == 0);
    SetMappedTableAddress(table);
    const AmclInputHostApiV1* resolved = nullptr;
#if defined(AMCL_DESCRIPTOR_MAPS_FOPEN_OBSERVER)
    g_descriptorMapsFopenCount.store(0u, std::memory_order_relaxed);
#endif
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH);
    CHECK(resolved == nullptr);
#if defined(AMCL_DESCRIPTOR_MAPS_FOPEN_OBSERVER)
    CHECK(g_descriptorMapsFopenCount.load(std::memory_order_relaxed) == 2u);
#endif
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(munmap(region, bytes * 2u) == 0);
}
#endif

// Publish 之后先真实 Resolve 建立 warm snapshot，再改变各类字段；不能把
// 尚未命中 memoization 的旧 header 测试误当“warm mutation”已经承重。
void TestWarmSnapshotMutationIsNotCachedSuccess() {
    auto api = DescriptorSpanOrderedApi();
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorPublishV1(&api) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &api);
    ++api.abiVersion;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_ABI_MISMATCH);
    CHECK(resolved == nullptr);
    api = DescriptorSpanOrderedApi();
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    api.capabilityBits &= ~AMCL_INPUT_CAP_TYPED_EVENTS;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_CAPABILITIES);
    CHECK(resolved == nullptr);
    api = DescriptorSpanOrderedApi();
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    api.beginSession = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INCOMPLETE);
    CHECK(resolved == nullptr);
    api = DescriptorSpanOrderedApi();
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    api.nextOrderedEvent = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INCOMPLETE);
    CHECK(resolved == nullptr);
    api = DescriptorSpanOrderedApi();
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &api);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
}

#if defined(AMCL_DESCRIPTOR_MAPS_FOPEN_OBSERVER)
// 先完成完整 ORDER 表的真实 callback 校验与 snapshot warm，再隔离观察一笔
// Resolve 的真实 fopen 次数。原 prefix-only fixture 本就一次，不能冒充旧两次。
void TestPosixWarmMapsOpenBudget() {
    auto api = DescriptorSpanOrderedApi();
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorPublishV1(&api) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    const AmclInputHostApiV1* resolved = nullptr;
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &api);
    g_descriptorMapsFopenCount.store(0u, std::memory_order_relaxed);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &api);
    const uint32_t orderedWarmOpens = g_descriptorMapsFopenCount.load(std::memory_order_relaxed);
    std::cout << "ordered warm real maps fopen count=" << orderedWarmOpens << '\n';
    CHECK(orderedWarmOpens == 1u);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    auto prefix = ValidApi(AMCL_INPUT_HOST_API_GENERATION);
    CHECK(amclInputHostDescriptorPublishV1(&prefix) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    g_descriptorMapsFopenCount.store(0u, std::memory_order_relaxed);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(resolved == &prefix);
    CHECK(g_descriptorMapsFopenCount.load(std::memory_order_relaxed) == 1u);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    g_descriptorMapsFopenCount.store(0u, std::memory_order_relaxed);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING);
    CHECK(resolved == nullptr);
    CHECK(g_descriptorMapsFopenCount.load(std::memory_order_relaxed) == 0u);
    SetRaw("malformed");
    g_descriptorMapsFopenCount.store(0u, std::memory_order_relaxed);
    CHECK(amclInputHostDescriptorResolveV1(&resolved) == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED);
    CHECK(resolved == nullptr);
    CHECK(g_descriptorMapsFopenCount.load(std::memory_order_relaxed) == 0u);
    CHECK(amclInputHostDescriptorClearV1() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
}
#endif

}  // namespace

int main() {
    TestMissingAndRetry();
    TestMalformedAndDescriptorVersion();
    TestZeroAddress();
    TestUnsafePointerRejectedWithoutDereference();
    TestVersionAndHeaderValidation();
    TestGenerationBoundaries();
    TestEveryRequiredFunction();
    TestCompleteSuccessAndOwnerPin();
    TestConcurrentFirstValidOwnerWins();
    TestConcurrentResolveClearPublishIsNotTorn();
    TestWarmSnapshotMutationIsNotCachedSuccess();
#ifndef _WIN32
    TestPosixWarmTableStillRequiresFreshMapping();
    TestPosixPrefixAndOrderedTailGuard();
    TestPosixAdjacentReadableMappingsPreserveOriginalResult();
#endif
#if defined(AMCL_DESCRIPTOR_MAPS_FOPEN_OBSERVER)
    TestPosixWarmMapsOpenBudget();
#endif
    std::cout << "host descriptor tests passed\n";
    return 0;
}

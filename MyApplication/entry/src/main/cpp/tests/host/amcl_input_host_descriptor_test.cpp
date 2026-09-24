#include "amcl_input_host_descriptor.h"

#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
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
    api.structSize = static_cast<uint32_t>(sizeof(api) - 1u);
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
    std::cout << "host descriptor tests passed\n";
    return 0;
}

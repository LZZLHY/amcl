#include "amcl_input_host_descriptor.h"

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "HOST DESCRIPTOR DSO FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

using PublishFn = int32_t (*)();
using ClearFn = int32_t (*)();
using AddressFn = uintptr_t (*)();
using ResolveFn = int32_t (*)(uintptr_t*);

struct Fixture {
#ifdef _WIN32
    HMODULE module = nullptr;
#else
    void* module = nullptr;
#endif
    PublishFn publish = nullptr;
    ClearFn clear = nullptr;
    AddressFn address = nullptr;
    ResolveFn resolve = nullptr;
};

void* Symbol(const Fixture& fixture, const char* name) {
#ifdef _WIN32
    return reinterpret_cast<void*>(GetProcAddress(fixture.module, name));
#else
    return dlsym(fixture.module, name);
#endif
}
Fixture Load(const char* path) {
    Fixture fixture{};
#ifdef _WIN32
    fixture.module = LoadLibraryA(path);
#else
    fixture.module = dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
    CHECK(fixture.module != nullptr);
    fixture.publish = reinterpret_cast<PublishFn>(
        Symbol(fixture, "amclDescriptorFixturePublish"));
    fixture.clear = reinterpret_cast<ClearFn>(
        Symbol(fixture, "amclDescriptorFixtureClear"));
    fixture.address = reinterpret_cast<AddressFn>(
        Symbol(fixture, "amclDescriptorFixtureApiAddress"));
    fixture.resolve = reinterpret_cast<ResolveFn>(
        Symbol(fixture, "amclDescriptorFixtureResolve"));
    CHECK(fixture.publish && fixture.clear && fixture.address && fixture.resolve);
    return fixture;
}

void Unload(Fixture& fixture) {
#ifdef _WIN32
    CHECK(FreeLibrary(fixture.module) != FALSE);
#else
    CHECK(dlclose(fixture.module) == 0);
#endif
    fixture.module = nullptr;
}

void TestConcurrentCrossDsoOwnerClaim(Fixture& first, Fixture& second) {
    CHECK(first.clear() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    std::atomic<uint32_t> ready{0u};
    std::atomic<bool> start{false};
    int32_t firstResult = 0;
    int32_t secondResult = 0;
    auto claim = [&](PublishFn publish, int32_t* out) {
        ready.fetch_add(1u, std::memory_order_release);
        while (!start.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        *out = publish();
    };
    std::thread firstThread(claim, first.publish, &firstResult);
    std::thread secondThread(claim, second.publish, &secondResult);
    while (ready.load(std::memory_order_acquire) != 2u) {
        std::this_thread::yield();
    }
    start.store(true, std::memory_order_release);
    firstThread.join();
    secondThread.join();
    CHECK((firstResult == AMCL_INPUT_HOST_DESCRIPTOR_OK &&
           secondResult == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT) ||
          (secondResult == AMCL_INPUT_HOST_DESCRIPTOR_OK &&
           firstResult == AMCL_INPUT_HOST_DESCRIPTOR_ERROR_OWNER_CONFLICT));
    const uintptr_t winner = firstResult == AMCL_INPUT_HOST_DESCRIPTOR_OK
                                 ? first.address()
                                 : second.address();
    uintptr_t fromFirst = 0u;
    uintptr_t fromSecond = 0u;
    CHECK(first.resolve(&fromFirst) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(second.resolve(&fromSecond) == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(fromFirst == winner && fromSecond == winner);
    CHECK(second.clear() == AMCL_INPUT_HOST_DESCRIPTOR_OK);
}
}  // namespace

int main(int argc, char** argv) {
    CHECK(argc == 3);
    Fixture first = Load(argv[1]);
    Fixture second = Load(argv[2]);
    for (uint32_t iteration = 0; iteration < 100u; ++iteration) {
        TestConcurrentCrossDsoOwnerClaim(first, second);
    }
    Unload(second);
    Unload(first);
    std::cout << "host descriptor cross-DSO tests passed\n";
    return 0;
}

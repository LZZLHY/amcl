#include "../../platform/window_host.h"
#include <cstdio>
#include <cstdlib>
#include <future>
#include <iostream>
#include <map>
#include <string>
#ifdef _WIN32
#include <windows.h>
#include <process.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif

namespace {
int failures = 0;
void check(bool value, const char* message) { if (!value) { ++failures; std::cerr << message << '\n'; } }
void environment(const char* key, const char* value) {
#ifdef _WIN32
    _putenv_s(key, value);
#else
    setenv(key, value, 1);
#endif
}
std::string environment(const char* key) { const char* value = std::getenv(key); return value ? value : ""; }
struct Driver {
    std::map<void*, int> references;
    static int reference(void* window, void* context) { ++static_cast<Driver*>(context)->references[window]; return 0; }
    static int unreference(void* window, void* context) {
        auto& count = static_cast<Driver*>(context)->references[window];
        check(count > 0, "DSO unreference requires live ownership");
        --count;
        return 0;
    }
};
struct Image {
#ifdef _WIN32
    HMODULE handle;
#else
    void* handle;
#endif
    explicit Image(const char* path) {
#ifdef _WIN32
        handle = LoadLibraryA(path);
#else
        handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
        check(handle != nullptr, "load actual window host DSO");
    }
    template<typename Function> Function symbol(const char* name) {
#ifdef _WIN32
        const auto address = GetProcAddress(handle, name);
#else
        const auto address = dlsym(handle, name);
#endif
        check(address != nullptr, name);
        return reinterpret_cast<Function>(address);
    }
};
struct Api {
    decltype(&amclWindowHostPublish) publish;
    decltype(&amclWindowHostUpdateSize) update;
    decltype(&amclWindowHostClear) clear;
    decltype(&amclWindowHostAcquire) acquire;
    decltype(&amclWindowHostRelease) release;
    decltype(&amclWindowHostGetBroker) broker;
    decltype(&amclWindowHostBeginInputPublication) begin;
    decltype(&amclWindowHostEndInputPublication) end;
    decltype(&amclWindowHostGetStats) stats;
    decltype(&amclWindowHostReadSnapshot) snapshot;
    decltype(&amclWindowHostSetReferenceDriver) driver;
    decltype(&amclWindowHostTestOverridePid) pid;
    explicit Api(Image& image) {
#define RESOLVE(member, name) member = image.symbol<decltype(member)>(#name)
        RESOLVE(publish, amclWindowHostPublish); RESOLVE(update, amclWindowHostUpdateSize);
        RESOLVE(clear, amclWindowHostClear); RESOLVE(acquire, amclWindowHostAcquire);
        RESOLVE(release, amclWindowHostRelease); RESOLVE(broker, amclWindowHostGetBroker);
        RESOLVE(begin, amclWindowHostBeginInputPublication); RESOLVE(end, amclWindowHostEndInputPublication);
        RESOLVE(stats, amclWindowHostGetStats); RESOLVE(snapshot, amclWindowHostReadSnapshot);
        RESOLVE(driver, amclWindowHostSetReferenceDriver); RESOLVE(pid, amclWindowHostTestOverridePid);
#undef RESOLVE
    }
};
}
int main(int argc, char** argv) {
    if (argc != 3) { std::cerr << "two independent DSO paths required\n"; return 2; }
    environment("AMCL_WINDOW_HOST_OWNER", "");
    environment(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV, "");
    environment("AMCL_NATIVE_WINDOW_SNAPSHOT", "");
    Image first(argv[1]), second(argv[2]);
    if (!first.handle || !second.handle) return 2;
    Api a(first), b(second);
    if (failures) return 2;
    Driver driver;
    check(a.driver(Driver::reference, Driver::unreference, &driver) == 1, "inject native driver into owner image");
    check(a.broker() != b.broker(), "consumer read before publication must not take process ownership");
    void* wa = reinterpret_cast<void*>(0x1234);
    void* wb = reinterpret_cast<void*>(0x5678);
    check(a.publish(wa, 640, 480, nullptr, nullptr) == 1, "first image publishes process owner");
    const std::string encodedBroker = environment(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV);
    unsigned version = 0;
    void* parsed = nullptr;
    int consumed = 0;
    check(std::sscanf(encodedBroker.c_str(), "%u:%p%n", &version, &parsed, &consumed) == 2 &&
        encodedBroker[static_cast<size_t>(consumed)] == '\0' && version == 2 && parsed == a.broker(), "legacy broker wire remains exact 2:%p");
    check(a.broker() == b.broker(), "two real DSO images use one published broker");
    void* leased = nullptr;
    void* leaseBroker = nullptr;
    int width = 0, height = 0;
    uint64_t generation = 0;
    check(b.acquire(nullptr, 0, nullptr, &leased, &width, &height, &generation, &leaseBroker) == 1 &&
        leased == wa && generation == 1 && driver.references[wa] == 2, "second image acquires first image's real reference");
    uint64_t token = 0, secondToken = 0;
    check(b.broker()->claimPresentation(wa, 1, 1, &token) == 1 &&
        a.broker()->claimPresentation(wa, 1, 2, &secondToken) == 0, "cross-DSO presentation ownership is exclusive");
    check(b.publish(wb, 800, 600, nullptr, nullptr) == 2 && driver.references[wa] == 1 && driver.references[wb] == 1,
        "second image writer forwards to the same owner/ref driver");
    void* inputBroker = nullptr;
    check(b.begin(&width, &height, &generation, &inputBroker) == 1 && inputBroker == a.broker(), "input publication token names the owner DSO");
    std::promise<void> writerStarted;
    auto started = writerStarted.get_future();
    auto update = std::async(std::launch::async, [&] { writerStarted.set_value(); return a.update(wb, 2, 900, 700); });
    started.wait();
    check(update.wait_for(std::chrono::milliseconds(30)) == std::future_status::timeout, "cross-DSO writer waits for input publication reader");
    b.end(inputBroker);
    check(update.get() == 3, "foreign image can return the exact input publication lease");
    a.release(wa, leaseBroker);
    check(driver.references[wa] == 0, "retired old window survives until consumer releases its lease");
    check(b.acquire(nullptr, 0, nullptr, &leased, &width, &height, &generation, &leaseBroker) == 1 && generation == 3,
        "second image acquires new epoch");
    check(a.broker()->movePresentation(token, wb, 3) == 1 && b.broker()->releasePresentation(token) == 1,
        "same presentation token moves/releases through either DSO");
    check(b.clear(wb, 3) == 4 && driver.references[wb] == 1, "clear retains leased window across DSO boundary");
    b.release(wb, leaseBroker);
    check(driver.references[wb] == 0, "final consumer release returns native count to zero");
    environment(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV, "2:invalid");
    check(b.broker() == nullptr && b.acquire(nullptr, 0, nullptr, &leased, &width, &height, &generation, &leaseBroker) == 0 && generation == UINT64_MAX,
        "malformed broker cannot fall back to a duplicate local ledger");
    environment(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV, encodedBroker.c_str());

    check(a.publish(wa, 640, 480, nullptr, nullptr) == 5 && driver.references[wa] == 1, "parent-like image keeps a live publication");
    const std::string parentOwner = environment("AMCL_WINDOW_HOST_OWNER");
    const std::string parentSnapshot = environment("AMCL_NATIVE_WINDOW_SNAPSHOT");
#ifdef _WIN32
    const uint64_t childPid = static_cast<uint64_t>(_getpid()) + 100000;
#else
    const uint64_t childPid = static_cast<uint64_t>(getpid()) + 100000;
#endif
    b.pid(childPid);
    AmclWindowHostStats stats{};
    b.stats(&stats);
    check(stats.generation == 0 && stats.liveLeases == 0 && b.broker() != a.broker(), "changed PID ignores inherited owner and allocates fresh synchronization/state");
    Driver childDriver;
    check(b.driver(Driver::reference, Driver::unreference, &childDriver) == 1 && b.publish(wb, 400, 300, nullptr, nullptr) == 1,
        "changed PID can publish its own independent native reference");
    a.stats(&stats);
    check(stats.generation == 5 && driver.references[wa] == 1 && childDriver.references[wb] == 1,
        "changed PID never releases or reuses the original image's live native object");
    check(b.clear(wb, 1) == 2 && childDriver.references[wb] == 0, "child-like publication cleans only its own reference");
    environment("AMCL_WINDOW_HOST_OWNER", parentOwner.c_str());
    environment(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV, encodedBroker.c_str());
    environment("AMCL_NATIVE_WINDOW_SNAPSHOT", parentSnapshot.c_str());
    b.pid(0);
    check(a.broker() == b.broker() && a.clear(wa, 5) == 6 && driver.references[wa] == 0, "same PID resolves the original owner after simulated fork audit");
    b.stats(&stats);
    check(stats.liveLeases == 0 && stats.livePresentationToken == 0 && stats.pendingRetirements == 0 && stats.publicationReference == 0,
        "all cross-DSO ownership and native references retire");
    if (!failures) std::cout << "window_host_dso_test PASS\n";
    return failures ? 1 : 0;
}

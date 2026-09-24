#include "../../platform/window_host_core.h"
#include <chrono>
#include <future>
#include <iostream>
#include <map>
#include <string>
#include <vector>

using amcl::window::NativeReferenceDriver;
using amcl::window::WindowHostCore;
namespace {
int failures = 0;
void check(bool value, const char* message) { if (!value) { ++failures; std::cerr << message << '\n'; } }
struct NativeDriver {
    std::map<void*, int> references;
    std::vector<std::string> events;
    bool failReference = false;
    bool failUnreference = false;
    static int reference(void* window, void* context) {
        auto& self = *static_cast<NativeDriver*>(context);
        self.events.push_back("reference");
        if (self.failReference) return -1;
        ++self.references[window];
        return 0;
    }
    static int unreference(void* window, void* context) {
        auto& self = *static_cast<NativeDriver*>(context);
        self.events.push_back("unreference");
        if (self.failUnreference) return -1;
        check(self.references[window] > 0, "native unreference requires a live reference");
        --self.references[window];
        return 0;
    }
    static void publish(const AmclWindowHostSnapshot&, void* context) {
        static_cast<NativeDriver*>(context)->events.push_back("snapshot-env");
    }
    NativeReferenceDriver api() { return {reference, unreference, this, publish}; }
};
void lifetimeAndFailures() {
    NativeDriver driver;
    WindowHostCore core(driver.api());
    void* a = reinterpret_cast<void*>(0x1234);
    void* b = reinterpret_cast<void*>(0x5678);
    void* leased = nullptr;
    int width = 0, height = 0;
    uint64_t generation = 0;
    check(core.peekGeneration() == 0 && core.peekState() == AMCL_NATIVE_WINDOW_PUBLICATION_UNPUBLISHED, "initial state unpublished");
    check(core.publish(a, 640, 480) == 1 && driver.references[a] == 1, "publisher owns one real native reference");
    check(core.acquire(nullptr, 0, &leased, &width, &height, &generation) == 1, "render lease acquisition");
    check(leased == a && generation == 1 && width == 640 && height == 480 && driver.references[a] == 2, "coherent acquired snapshot");
    check(core.acquire(a, 1, &leased, &width, &height, &generation) == 2 && driver.references[a] == 2, "retained epoch does not add a native reference");
    uint64_t token = 0, competing = 0;
    check(core.claimPresentation(a, 1, 1, &token) == 1 && token != 0, "OpenGL presentation claim");
    check(core.claimPresentation(a, 1, 2, &competing) == 0 && competing == 0, "Vulkan cannot claim occupied presenter");
    check(core.updateSize(a, 1, 0, 0) == 2, "invalid size becomes suspended epoch");
    check(core.peekState() == AMCL_NATIVE_WINDOW_PUBLICATION_SUSPENDED && core.acquire(nullptr, 0, &leased, &width, &height, &generation) == 0,
        "suspended publication cannot lend a renderable native window");
    check(core.beginInputPublication(&width, &height, &generation) == 0, "suspended input publication fails closed");
    check(core.updateSize(a, 2, 800, 600) == 3 && core.movePresentation(token, a, 3) == 1, "same pointer revives under a new epoch");
    check(core.clear(a, 1) == 0 && driver.references[a] == 2, "stale callback cannot clear revived window");
    driver.failReference = true;
    check(core.publish(b, 900, 700) == 0 && core.peekGeneration() == 3 && core.snapshot().nativeWindow == a, "failed reference leaves prior publication untouched");
    driver.failReference = false;
    check(core.publish(b, 900, 700) == 4 && driver.references[a] == 1 && driver.references[b] == 1, "replacement retires only publisher's old reference");
    check(core.claimPresentation(b, 4, 2, &competing) == 0, "replacement does not steal outstanding presentation token");
    check(core.acquire(nullptr, 0, &leased, &width, &height, &generation) == 1 && leased == b, "new epoch render lease");
    check(core.movePresentation(token, b, 4) == 1, "old owner can atomically move after its resource retirement");
    check(core.releasePresentation(token) == 1 && core.releasePresentation(token) == 0, "stale token cannot release twice");
    driver.failUnreference = true;
    core.release(a);
    check(core.stats().pendingRetirements == 1 && driver.references[a] == 1, "failed driver release remains owned by retirement ledger");
    core.release(a);
    check(core.stats().rejectedReleases == 1 && core.stats().pendingRetirements == 1, "duplicate release cannot manufacture another unreference");
    check(core.clear(b, 4) == 5 && driver.references[b] == 2 && core.stats().pendingRetirements == 2, "failed cleared publication reference remains owned");
    core.release(b);
    check(core.stats().pendingRetirements == 3 && core.stats().liveLeases == 0, "all failed native releases have explicit owners");
    driver.failUnreference = false;
    check(core.retryRetiredReferences() && driver.references[a] == 0 && driver.references[b] == 0, "retirement retry releases every actual native reference exactly once");
    check(core.stats().pendingRetirements == 0 && core.stats().livePresentationToken == 0, "complete teardown leaves no pending ownership");
    NativeDriver exhaustedDriver;
    WindowHostCore exhausted(exhaustedDriver.api(), UINT64_MAX);
    check(exhausted.publish(a, 1, 1) == 0 && exhaustedDriver.events.empty(), "generation exhaustion has no driver side effects");
}
struct CommitContext {
    WindowHostCore* core;
    NativeDriver* driver;
    std::promise<void>* entered;
    std::shared_future<void>* release;
    static void beforeCommit(const AmclWindowHostSnapshot* snapshot, void* opaque) {
        auto& self = *static_cast<CommitContext*>(opaque);
        self.driver->events.push_back("input-commit");
        check(snapshot->generation == 2 && self.core->peekGeneration() == 1, "input publisher runs before generation commit");
        self.entered->set_value();
        self.release->wait();
    }
};
void inputTransactionOrder() {
    NativeDriver driver;
    WindowHostCore core(driver.api());
    void* a = reinterpret_cast<void*>(0x1234);
    void* b = reinterpret_cast<void*>(0x5678);
    check(core.publish(a, 640, 480) == 1, "input ordering initial publication");
    int width = 0, height = 0;
    uint64_t generation = 0;
    check(core.beginInputPublication(&width, &height, &generation) == 1, "input holds a shared publication lock");
    std::promise<void> writerStarted;
    auto writerStartedFuture = writerStarted.get_future();
    auto writer = std::async(std::launch::async, [&] {
        writerStarted.set_value();
        return core.updateSize(a, 1, 800, 600);
    });
    writerStartedFuture.wait();
    check(writer.wait_for(std::chrono::milliseconds(30)) == std::future_status::timeout, "host cannot publish a new epoch during old input callback");
    core.endInputPublication();
    check(writer.get() == 2, "queued metadata publication completes after input release");
    check(core.clear(a, 2) == 3, "first transaction cleanup");

    NativeDriver secondDriver;
    WindowHostCore second(secondDriver.api());
    check(second.publish(a, 640, 480) == 1, "callback ordering initial publication");
    secondDriver.events.clear();
    std::promise<void> callbackEntered, callbackRelease;
    auto entered = callbackEntered.get_future();
    auto release = callbackRelease.get_future().share();
    CommitContext context{&second, &secondDriver, &callbackEntered, &release};
    auto publisher = std::async(std::launch::async, [&] { return second.publish(b, 900, 700, CommitContext::beforeCommit, &context); });
    entered.wait();
    auto consumer = std::async(std::launch::async, [&] {
        const int acquired = second.beginInputPublication(&width, &height, &generation);
        if (acquired) second.endInputPublication();
        return acquired;
    });
    check(consumer.wait_for(std::chrono::milliseconds(30)) == std::future_status::timeout, "new input cannot pass the unfinished publisher callback");
    callbackRelease.set_value();
    check(publisher.get() == 2 && consumer.get() == 1 && generation == 2 && width == 900 && height == 700, "first admitted callback sees completed new epoch");
    check(secondDriver.events == std::vector<std::string>({"reference", "snapshot-env", "input-commit", "unreference"}),
        "publication preserves reference, snapshot, input callback, old unreference order");
    check(second.clear(b, 2) == 3 && secondDriver.references[a] == 0 && secondDriver.references[b] == 0, "callback transaction references cleaned");
}
}
// 正例允许连续尺寸变化；同指针 clear→publish 和零尺寸暂停都必须改变资源身份。
void resourceEpochs() {
    NativeDriver driver; WindowHostCore core(driver.api());
    void* window = reinterpret_cast<void*>(0x9876);
    AmclNativeWindowIdentityV1 first{sizeof(first), 1u, nullptr, 0, 0, 0, 0, 0};
    check(core.publish(window, 640, 480) == 1, "identity initial publication");
    check(core.acquireIdentity(nullptr, 0, &first) == 1 && first.resourceEpoch == 1, "atomic identity acquisition");
    uint64_t token = 0;
    check(core.claimPresentation(window, 1, 1, &token) == 1, "identity presenter claim");
    check(core.updateSize(window, 1, 800, 600) == 2, "geometry publication");
    AmclNativeWindowIdentityV1 next{sizeof(next), 1u, nullptr, 0, 0, 0, 0, 0};
    check(core.acquireIdentity(nullptr, 0, &next) == 1 && next.resourceEpoch == first.resourceEpoch &&
        next.geometryEpoch == 2 && next.width == 800, "geometry does not replace resource epoch");
    check(core.movePresentationGeometry(token, window, 1, 2, first.resourceEpoch) == 1, "geometry token commit");
    core.release(window);
    check(core.clear(window, 2) == 3 && core.publish(window, 900, 600) == 4, "same pointer is republished");
    check(!core.movePresentationGeometry(token, window, 2, 4, first.resourceEpoch), "missed clear cannot preserve stale surface");
    check(core.acquireIdentity(nullptr, 0, &next) == 1 && next.resourceEpoch == 4, "replacement has independent identity");
    core.release(window);
    check(core.updateSize(window, 4, 0, 0) == 5 && core.updateSize(window, 5, 900, 600) == 6, "zero size pause resumes");
    check(!core.movePresentationGeometry(token, window, 2, 6, 4), "missed zero-size pause forces retirement");
    check(core.releasePresentation(token) == 1, "identity token retired");
    core.release(window);
    check(core.clear(window, 6) == 7 && driver.references[window] == 0, "identity test reference balance");
}

int main() {
    lifetimeAndFailures();
    inputTransactionOrder();
    resourceEpochs();
    if (!failures) std::cout << "window_host_core_test PASS\n";
    return failures ? 1 : 0;
}

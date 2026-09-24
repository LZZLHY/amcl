#include "SDL_amclpresentation.h"
#include "amcl_presentation_owner.h"
#include "amcl_native_window_lease_broker_abi.h"
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
#include <cstdint>

static_assert(sizeof(AMCL_NativeWindowLeaseBrokerV2) == sizeof(AmclNativeWindowLeaseBrokerV2),
    "SDL private broker size must match the host ABI");
static_assert(offsetof(AMCL_NativeWindowLeaseBrokerV2, acquire) == offsetof(AmclNativeWindowLeaseBrokerV2, acquire),
    "SDL acquire prefix must match the host ABI");
static_assert(offsetof(AMCL_NativeWindowLeaseBrokerV2, peekState) == offsetof(AmclNativeWindowLeaseBrokerV2, peekState),
    "SDL peek prefix must match the host ABI");
static_assert(offsetof(AMCL_NativeWindowLeaseBrokerV2, claimPresentation) == offsetof(AmclNativeWindowLeaseBrokerV2, claimPresentation),
    "SDL presentation tail must match the host ABI");
static_assert(offsetof(AMCL_NativeWindowLeaseBrokerV2, releasePresentation) == offsetof(AmclNativeWindowLeaseBrokerV2, releasePresentation),
    "SDL presentation release offset must match the host ABI");

namespace {
AmclPresentationOwner hostOwner;
void* publishedWindow = nullptr;
uint64_t publishedGeneration = 1;
uint64_t resourceEpoch = 1;
int identityReferences = 0;
uint32_t publishedState = 1;
bool failCreate = false;
bool failDestroy = false;
bool failMove = false;
uintptr_t nextSurface = 100;
std::vector<std::string> events;
unsigned createCalls = 0;
unsigned destroyCalls = 0;
int failures = 0;
void check(bool condition, const char* message) {
    if (!condition) { ++failures; std::cerr << "FAIL " << message << '\n'; }
}
uint64_t peekGeneration() { return publishedGeneration; }
uint32_t peekState() { return publishedState; }
int claim(void* window, uint64_t generation, uint32_t api, uint64_t* token) {
    events.push_back("claim");
    *token = 0;
    if (window != publishedWindow || generation != publishedGeneration || publishedState != 1) return 0;
    return hostOwner.claim(window, generation, api, *token) ? 1 : 0;
}
int move(uint64_t token, void* window, uint64_t generation) {
    events.push_back("move");
    if (failMove || window != publishedWindow || generation != publishedGeneration) return 0;
    return hostOwner.move(token, window, generation) ? 1 : 0;
}
int release(uint64_t token) {
    events.push_back("release");
    return hostOwner.release(token) ? 1 : 0;
}
// 只模拟宿主系统边界；SDL 的 identity 校验和 token 决策由真实生成 header 执行。
int acquireIdentity(void*, uint64_t, AMCL_NativeWindowIdentityV1* out) {
    if (publishedState != 1) return 0;
    out->nativeWindow = publishedWindow; out->generation = publishedGeneration;
    out->resourceEpoch = resourceEpoch; out->geometryEpoch = publishedGeneration;
    out->width = 800; out->height = 600; ++identityReferences; return 1;
}
void releaseIdentity(void*) { --identityReferences; }
int moveGeometry(uint64_t token, void* window, uint64_t previous, uint64_t next, uint64_t resource) {
    if (!resource || resource != resourceEpoch || previous != hostOwner.generation()) return 0;
    return move(token, window, next);
}
void* create(void*, void*) {
    events.push_back("create");
    ++createCalls;
    return failCreate ? nullptr : reinterpret_cast<void*>(++nextSurface);
}
bool destroy(void*, void*) {
    events.push_back("destroy");
    ++destroyCalls;
    return !failDestroy;
}
AMCL_NativeWindowLeaseBrokerV2 broker{
    2, sizeof(AMCL_NativeWindowLeaseBrokerV2), nullptr, releaseIdentity, nullptr, nullptr,
    peekGeneration, peekState, claim, move, release, acquireIdentity, moveGeometry
};
int windows[4]{};
void reset() {
    hostOwner = AmclPresentationOwner{};
    publishedWindow = &windows[0]; publishedGeneration = 1; publishedState = 1;
    resourceEpoch = 1; check(identityReferences == 0, "identity query references balanced");
    failCreate = failDestroy = failMove = false;
    events.clear(); createCalls = destroyCalls = 0;
}
void publish(unsigned index, uint64_t generation) {
    publishedWindow = &windows[index]; publishedGeneration = generation; resourceEpoch = generation;
}
void* make(AMCL_PresentationOwner& owner) {
    return AMCL_PresentationCreate(&owner, &broker, publishedWindow, publishedGeneration, nullptr, create);
}
bool retire(AMCL_PresentationOwner& owner, void* surface) {
    return AMCL_PresentationRetire(&owner, surface, nullptr, destroy);
}
}
int main() {
    reset();
    AMCL_PresentationOwner first{};
    auto* firstSurface = make(first);
    check(firstSurface && first.token && AMCL_PresentationLive(&first) == 1, "first resource is claimed before creation");
    check(events == std::vector<std::string>({"claim", "create"}), "claim precedes driver create");
    uint64_t contender = 0;
    check(!claim(publishedWindow, publishedGeneration, 2, &contender), "Vulkan cannot overlap a live GL session");
    check(!make(first) && createCalls == 1, "same native window cannot own a second EGL window surface");
    check(!AMCL_PresentationRelease(&first), "live resource prevents token release");
    check(retire(first, firstSurface), "driver retirement succeeds");
    check(!retire(first, firstSurface) && destroyCalls == 1, "duplicate retirement cannot call the driver twice");
    check(AMCL_PresentationRelease(&first), "empty session releases token");
    check(claim(publishedWindow, publishedGeneration, 2, &contender), "Vulkan can claim only after GL teardown");
    check(release(contender), "clean up contender");

    reset();
    AMCL_PresentationOwner missingTail{};
    auto legacy = broker;
    legacy.structSize = static_cast<uint32_t>(offsetof(AMCL_NativeWindowLeaseBrokerV2, claimPresentation));
    check(!AMCL_PresentationCreate(&missingTail, &legacy, publishedWindow, 1, nullptr, create), "short descriptor rejects before reading tail");
    check(events.empty(), "short broker cannot call driver or ownership functions");
    failCreate = true;
    check(!make(missingTail), "first driver create failure propagates");
    check(events == std::vector<std::string>({"claim", "create", "release"}), "first create failure rolls claim back");
    check(!missingTail.token && hostOwner.token() == 0, "failed first create leaves no owner");

    reset();
    AMCL_PresentationOwner recovery{};
    auto* oldSurface = make(recovery);
    const auto token = recovery.token;
    publish(1, 2);
    failCreate = true;
    check(!make(recovery), "candidate driver create failure propagates");
    check(recovery.token == token && AMCL_PresentationLive(&recovery) == 1, "failed candidate keeps old session token and resource");
    failCreate = false;
    auto* newSurface = make(recovery);
    check(newSurface && AMCL_PresentationLive(&recovery) == 2, "transaction tracks old and candidate driver resources");
    check(!AMCL_PresentationMove(&recovery, publishedWindow, 2), "moving with old-native-window resource still live is forbidden");
    check(retire(recovery, oldSurface), "old surface is really retired before move");
    check(AMCL_PresentationMove(&recovery, publishedWindow, 2), "atomic generation transfer after old retirement");
    check(events[events.size() - 2] == "destroy" && events.back() == "move", "actual driver destroy precedes broker move");
    check(recovery.token == token && hostOwner.generation() == 2, "move retains the same exclusive owner");
    check(!AMCL_PresentationRelease(&recovery), "new live surface blocks release");
    check(retire(recovery, newSurface) && AMCL_PresentationRelease(&recovery), "normal recovery teardown balances");
    check(recovery.created == 2 && recovery.destroyed == 2, "all successful real resources balance");

    reset();
    AMCL_PresentationOwner samePointer{};
    auto* sameSurface = make(samePointer);
    publishedGeneration = 2; // 只有几何变化；真实宿主的 resource epoch 保持为 1。
    check(AMCL_PresentationMove(&samePointer, publishedWindow, 2), "same-pointer geometry update may move without destroying resource");
    check(destroyCalls == 0 && createCalls == 1, "geometry-only publication causes no EGL surgery");
    publish(0, 4); // 消费者漏看 clear 后同一指针重发。
    check(!AMCL_PresentationMove(&samePointer, publishedWindow, 4), "same pointer with new resource epoch cannot preserve surface");
    check(retire(samePointer, sameSurface) && AMCL_PresentationRelease(&samePointer), "geometry-only session cleans up");

    reset();
    AMCL_PresentationOwner failedRetirement{};
    oldSurface = make(failedRetirement);
    publish(1, 2);
    newSurface = make(failedRetirement);
    failDestroy = true;
    check(!retire(failedRetirement, oldSurface), "driver retirement error propagates");
    check(AMCL_PresentationLive(&failedRetirement) == 2 && failedRetirement.destroyed == 0, "failed real retirement cannot erase resource records");
    check(!AMCL_PresentationMove(&failedRetirement, publishedWindow, 2), "tainted old resources prevent transfer");
    check(!AMCL_PresentationRelease(&failedRetirement), "tainted resources keep token until real cleanup");
    check(!claim(publishedWindow, 2, 2, &contender), "a Vulkan owner cannot steal a tainted GL session");
    failDestroy = false;
    check(retire(failedRetirement, oldSurface) && retire(failedRetirement, newSurface), "controlled cleanup can retry real retirement");
    check(AMCL_PresentationRelease(&failedRetirement), "token can be released after every real resource eventually retired");

    reset();
    AMCL_PresentationOwner stalePublication{};
    oldSurface = make(stalePublication);
    publish(1, 2);
    newSurface = make(stalePublication);
    check(retire(stalePublication, oldSurface), "prepare a complete old-resource retirement");
    failMove = true;
    check(!AMCL_PresentationMove(&stalePublication, publishedWindow, 2), "broker transfer failure is not hidden");
    check(stalePublication.generation == 1 && stalePublication.token != 0, "refused move preserves old owner identity");
    check(retire(stalePublication, newSurface), "unpublished candidate rolls back through real driver");
    check(stalePublication.token != 0 && hostOwner.token() != 0, "suspended session retains its token after candidate rollback");
    check(AMCL_PresentationRelease(&stalePublication), "explicit session teardown releases the final owner");

    reset();
    AMCL_PresentationOwner original{};
    oldSurface = make(original);
    check(retire(original, oldSurface), "prepare stale-token sample");
    auto stale = original;
    check(AMCL_PresentationRelease(&original), "release original");
    AMCL_PresentationOwner replacement{};
    newSurface = make(replacement);
    check(!AMCL_PresentationRelease(&stale), "stale session token cannot release a newer owner");
    check(hostOwner.token() == replacement.token, "stale release leaves replacement ownership intact");
    check(retire(replacement, newSurface) && AMCL_PresentationRelease(&replacement), "replacement cleans up");

    reset();
    AMCL_PresentationOwner overflow{};
    oldSurface = make(overflow); publish(1, 2); newSurface = make(overflow); publish(2, 3);
    const auto callsBefore = createCalls;
    check(!make(overflow) && createCalls == callsBefore, "bounded transaction rejects a third resource before driver allocation");
    check(retire(overflow, oldSurface) && retire(overflow, newSurface) && AMCL_PresentationRelease(&overflow), "bounded transaction cleanup");
    if (failures) return EXIT_FAILURE;
    std::cout << "SDL presentation real callback ordering and failure scenarios PASS\n";
    return EXIT_SUCCESS;
}

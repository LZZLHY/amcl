// 执行真实window_host分派，证明owner验证、回调锁边界和实际观测代次；Native引用仅用计数边界替身。
#include "../../platform/window_host.h"
#include <iostream>

namespace {
int failures = 0, references = 0, configured = 0, observed = 0;
uint32_t work = 1;
void check(bool value, const char* message) { if (!value) { ++failures; std::cerr << message << '\n'; } }
int retain(void*, void*) { ++references; return 0; }
int release(void*, void*) { --references; return 0; }
uint32_t flags() { return work; }
int configure(void* window, uint64_t generation, uint64_t) {
    ++configured;
    AmclWindowHostSnapshot snapshot{};
    // 如果分派仍持core锁，本测试会触发CTest超时；不能用只增计数的回调掩盖死锁。
    check(amclWindowHostReadSnapshot(&snapshot) == 1 && snapshot.generation == generation, "callback can read current owner");
    check(amclWindowHostUpdateSize(window, generation, 2016, 912) == 2, "callback can publish without a retained broker lock");
    work = 2;
    return 1;
}
void observe(void*, uint64_t generation, uint64_t, int width, int height, uint32_t source) {
    ++observed;
    AmclWindowHostSnapshot snapshot{};
    check(amclWindowHostReadSnapshot(&snapshot) == 1 && snapshot.generation == generation, "observation is outside owner lock");
    check(width == 2016 && height == 912 && source == 1, "observation carries supplied actual evidence");
    work = 0;
}
}
int main() {
    const AmclWindowGeometryClientV1 client{sizeof(client), 1, flags, configure, observe};
    check(amclWindowHostRegisterGeometryClient(&client) == 0, "unpublished image cannot retain a geometry client");
    check(amclWindowHostSetReferenceDriver(retain, release, nullptr) == 1, "reference boundary configured");
    check(amclWindowHostPublishOwner() == 1, "early owner published");
    check(amclWindowHostRegisterGeometryClient(&client) == 1 && amclWindowHostRegisterGeometryClient(&client) == 1, "same immutable client is idempotent");
    const AmclWindowGeometryClientV1 other = client;
    check(amclWindowHostRegisterGeometryClient(&other) == 0, "different client cannot replace the owner");
    void* window = reinterpret_cast<void*>(0x1234);
    check(amclWindowHostPublish(window, 2688, 1216, nullptr, nullptr) == 1, "window published");
    const auto* broker = amclWindowHostGetBroker();
    void* leased = nullptr; int width = 0, height = 0; uint64_t generation = 0;
    check(broker->acquire(nullptr, 0, &leased, &width, &height, &generation) == 1, "real lease retained");
    uint64_t token = 0;
    check(broker->claimPresentation(window, 1, 1, &token) == 1, "present owner claimed");
    check(broker->geometryCheckpoint(window, 1, token + 1) == 0 && configured == 0, "foreign token rejected before callback");
    check(broker->geometryCheckpoint(window, 1, token) == 1 && configured == 1, "current owner reaches checkpoint once");
    broker->observeDrawable(window, 1, token, 2016, 912, 1);
    check(observed == 0, "old generation cannot confirm new image");
    check(broker->movePresentationGeometry(token, window, 1, 2, 1) == 1, "frontend adopts new geometry");
    broker->observeDrawable(window, 2, token, 2016, 912, 1);
    check(observed == 1 && broker->geometryWorkFlags() == 0, "actual observation finishes pending work");
    check(amclWindowHostClear(window, 2) == 3 && amclWindowHostPublish(window, 1000, 500, nullptr, nullptr) == 4, "same-address replacement published");
    work = 1;
    check(broker->geometryCheckpoint(window, 2, token) == 0 && configured == 1, "retired owner cannot configure replacement");
    broker->releasePresentation(token);
    broker->release(leased);
    amclWindowHostClear(window, 4);
    check(references == 0, "all reference leases retired");
    if (!failures) std::cout << "window_geometry_callback_test: OK\n";
    return failures ? 1 : 0;
}

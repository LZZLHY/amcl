/**
 * 生产退出纯核心的宿主回归。I/O 明确注入失败、短写和 EINTR，不触发宿主进程退出。
 * POSIX fd/flock 的真实语义由独立 game_process_exit_posix_test.cpp 覆盖。
 */
#include "../../jvm/game_process_exit_core.h"
#include <algorithm>
#include <array>
#include <climits>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <string>
#include <vector>

namespace {
using namespace amcl::gameexit;
constexpr const char* Files = "/data/storage/el2/base/files";
std::size_t checks = 0;
void Require(bool value, const char* why)
{
    ++checks;
    if (!value) { std::cerr << "FAIL " << why << '\n'; std::exit(1); }
}

// 每个测试实例具有自己的虚拟 fd/时钟/故障开关，不让上一个场景的状态污染下一个。
class Fake final : public Operations {
public:
    int current = 100;
    bool locked = true, directoryFails = false, createFails = false;
    bool pipeFails = false, logFails = false, ackFails = false, hasAck = false, pollFails = false;
    int writeFailure = 0, syncFailure = 0, publishFailure = 0;
    int writeInterrupts = 0, syncInterrupts = 0, publishInterrupts = 0;
    int writes = 0, syncs = 0, publishes = 0, closes = 0, opens = 0;
    int removals = 0, ackWrites = 0, ackInterrupts = 0, polls = 0, pollInterrupts = 0, spurious = 0;
    std::int64_t monotonic = 1000, interruptStep = 0;
    std::size_t chunk = RecordCapacity;
    std::string data, diagnostic, tempName, finalName;
    std::vector<int> timeouts;
    std::function<void()> onWrite, onPoll;
    int pid() const noexcept override { return current; }
    int openAuthority(const char*, int lock) noexcept override { ++opens; return locked && lock == 7 ? 10 : -1; }
    bool checkAuthority(int files, int lock) noexcept override { return locked && files == 10 && lock == 7; }
    int openRecordDirectory(int files) noexcept override { return files == 10 && !directoryFails ? 20 : -1; }
    int createRecord(int directory, const char* temporary, const char* final) noexcept override
    {
        if (directory != 20) return -1;
        if (std::strcmp(temporary, final) == 0) return logFails ? -1 : 31;
        if (createFails) return -1;
        tempName = temporary; finalName = final; return 30;
    }
    void removeOwnedTemporary(int directory, const char* name) noexcept override
    {
        Require(directory == 20 && std::string(name) == "42.handoff.log", "only newly created diagnostic log rolled back"); ++removals;
    }
    bool createAckChannel(int& readFd, int& writeFd) noexcept override
    {
        if (pipeFails) return false;
        readFd = 40; writeFd = 41; return true;
    }
    void closeOwned(int fd) noexcept override { Require(fd != 7, "borrowed lock is never closed"); ++closes; }
    std::int64_t nowMs() noexcept override { return INT64_C(1789752395515); }
    std::int64_t monotonicMs() noexcept override { return monotonic; }
    IoResult writeRecord(int fd, const char* bytes, std::size_t count) noexcept override
    {
        Require(fd == 30 || fd == 31, "only prepared record/log written");
        if (fd == 31) { diagnostic.append(bytes, count); return {static_cast<std::int64_t>(count), false}; }
        ++writes;
        if (onWrite) onWrite();
        if (writeInterrupts-- > 0) return {-1, true};
        if (writeFailure == 1) return {-1, false};
        if (writeFailure == 2) return {0, false};
        if (writeFailure == 3) return {static_cast<std::int64_t>(count) + 1, false};
        const std::size_t accepted = (std::min)(count, chunk);
        data.append(bytes, accepted); return {static_cast<std::int64_t>(accepted), false};
    }
    IoResult sync(int fd) noexcept override
    {
        Require(fd == 20 || fd == 30, "sync prepared file/directory"); ++syncs;
        if (syncInterrupts-- > 0) return {-1, true};
        return {syncFailure ? -1 : 0, false};
    }
    IoResult publish(int directory, const char* temporary, const char* final) noexcept override
    {
        Require(directory == 20 && tempName == temporary && finalName == final, "publish own exact prepared names");
        ++publishes;
        if (publishInterrupts-- > 0) return {-1, true};
        return {publishFailure ? -1 : 0, false};
    }
    IoResult sendAck(int fd) noexcept override
    {
        Require(fd == 41, "ack uses prepared write end"); ++ackWrites;
        if (ackInterrupts-- > 0) return {-1, true};
        if (ackFails) return {-1, false};
        hasAck = true; return {1, false};
    }
    IoResult pollAck(int fd, int timeout) noexcept override
    {
        Require(fd == 40 && timeout > 0 && timeout <= HandoffTimeoutMs, "poll uses prepared fd and remaining budget");
        ++polls; timeouts.push_back(timeout);
        if (onPoll) onPoll();
        if (hasAck) return {1, false};
        if (pollInterrupts-- > 0) { monotonic += interruptStep; return {-1, true}; }
        if (pollFails) return {-1, false};
        if (spurious-- > 0) return {2, false};
        monotonic += timeout; return {0, false};
    }
};

void Ready(State& state, Fake& ops)
{
    Require(state.authorize(ops, Files, 200, 7) == 0, "authorize isolated process");
    Require(state.prepare(ops, Files, 42) == 0 && state.armed(ops), "prepare exact session");
}

void TestAuthorization()
{
    for (const char* bad : {"", "/", "relative", "/files/../other", "/files/./other", "/files/", "/files//other", "/files\nother"}) {
        State state; Fake ops;
        Require(state.authorize(ops, bad, 200, 7) < 0 && ops.opens == 0, "invalid path rejected before I/O");
    }
    const std::string longPath = "/" + std::string(PathCapacity, 'x');
    Require(!ValidDirectory(longPath.c_str()) && !ValidDirectory(nullptr), "oversized/null path rejected");
    State state; Fake ops;
    Require(state.prepare(ops, Files, 42) == 1 && !state.armed(ops) && !state.authorized(ops), "unowned process has no hook");
    Require(state.authorize(ops, Files, 100, 7) < 0, "same process rejected");
    Require(state.authorize(ops, Files, 0, 7) < 0, "missing parent rejected");
    Require(state.authorize(ops, Files, 200, -1) < 0, "bad fd rejected");
    Require(state.authorize(ops, Files, 200, 6) < 0, "wrong fd identity rejected");
    ops.locked = false;
    Require(state.authorize(ops, Files, 200, 7) < 0 && !state.authorized(ops), "unheld lock rejected");
    ops.locked = true;
    Require(state.authorize(ops, Files, 200, 7) == 0 && state.authorized(ops), "failed authorization may retry");
    Require(state.authorize(ops, Files, 200, 7) == 0, "same authorization idempotent");
    Require(state.authorize(ops, Files, 201, 7) < 0, "parent cannot change");
    Require(state.authorize(ops, "/other", 200, 7) < 0, "filesDir cannot change");
    ops.current = 101;
    Require(state.prepare(ops, Files, 42) == 1 && !state.armed(ops) && !state.authorized(ops), "fork does not inherit authorization");
    Require(state.authorize(ops, Files, 200, 7) < 0, "fork cannot rebind inherited identity");
    Require(!state.emit(ops, 0) && ops.writes == 0, "inherited process never writes parent session");
}

void TestPreparation()
{
    State state; Fake ops;
    Require(state.authorize(ops, Files, 200, 7) == 0, "prepare setup");
    for (std::int64_t invalid : {INT64_C(0), INT64_C(-1), MaxActivity + 1, INT64_MAX}) {
        Require(state.prepare(ops, Files, invalid) < 0 && !state.armed(ops), "bad activity rejected");
    }
    Require(state.prepare(ops, "/other", 42) < 0, "prepare path must match authority");
    ops.locked = false;
    Require(state.prepare(ops, Files, 42) < 0 && !state.armed(ops), "lost lock rejects hook");
    ops.locked = true; ops.directoryFails = true;
    Require(state.prepare(ops, Files, 42) < 0 && !state.armed(ops), "directory failure rejects hook");
    ops.directoryFails = false; ops.pipeFails = true;
    Require(state.prepare(ops, Files, 42) < 0 && !state.armed(ops) && state.authorized(ops), "pipe failure rejects arm without losing authority");
    ops.pipeFails = false; ops.logFails = true;
    Require(state.prepare(ops, Files, 42) < 0 && !state.armed(ops), "diagnostic log failure rejects arm");
    ops.logFails = false; ops.createFails = true;
    Require(state.prepare(ops, Files, 42) < 0 && ops.removals == 1 && !state.armed(ops), "main tmp collision rolls back newly owned resources only");
    ops.createFails = false;
    Require(state.prepare(ops, Files, 42) == 0 && state.armed(ops), "preparation can retry before successful arm");
    Require(ops.tempName == "42.json.tmp" && ops.finalName == "42.json", "numeric names only");
    Require(state.prepare(ops, Files, 42) == 0 && state.prepare(ops, Files, 43) < 0, "prepared activity immutable");
    ops.current = 101;
    Require(!state.armed(ops) && state.prepare(ops, Files, 42) == 1, "prepared fd inherited without session authority");
    Require(!state.emit(ops, 7) && ops.writes == 0, "inherited prepared fd remains untouched");
    ops.current = 100;
    Require(state.armed(ops), "parent authorization remains intact");
}

void TestHandoff()
{
    { State state; Fake ops; Ready(state, ops); int code = 123;
      Require(state.authorized(ops) && !state.pending(ops), "prepared identity is not pending");
      Require(state.acknowledge(ops, code) == Acknowledgement::NoPending && code == 123, "no premature ack");
      ops.onWrite = [&] { Require(state.authorized(ops) && !state.pending(ops), "record commit precedes pending publication"); };
      Require(state.emit(ops, 7) && state.pending(ops), "committed record publishes pending");
      Require(state.acknowledge(ops, code) == Acknowledgement::Owned && code == 7, "ack retains nonzero code");
      Require(state.acknowledge(ops, code) == Acknowledgement::Owned && ops.ackWrites == 1, "ack idempotent");
      Require(std::string(state.waitForHandoff(ops)) == "acknowledged", "queued ack consumed without sleep");
      Require(state.authorized(ops) && state.pending(ops) && ops.diagnostic.find("acknowledged") != std::string::npos,
              "finished identity cannot fall back to exit zero"); }
    { State state; Fake ops; Ready(state, ops);
      ops.onWrite = [&] { int code = 0;
          Require(state.authorized(ops) && !state.armed(ops) && !state.pending(ops), "recording has continuous authority");
          Require(state.acknowledge(ops, code) == Acknowledgement::Owned && ops.ackWrites == 0, "early UI ack deferred until record commit"); };
      Require(state.emit(ops, -9), "record committed after deferred ack");
      Require(std::string(state.waitForHandoff(ops)) == "acknowledged" && ops.ackWrites == 1,
              "deferred ack delivers after publication"); }
    { State state; Fake ops; Ready(state, ops); Require(state.emit(ops, 0), "timeout setup");
      Require(std::string(state.waitForHandoff(ops)) == "timeout" && ops.monotonic == 4000 && ops.polls == 1,
              "missing UI exits at absolute 3000ms deadline");
      Require(ops.diagnostic.find("timeout") != std::string::npos && ops.diagnostic.find("acknowledged") == std::string::npos,
              "timeout never claims foreground success"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, 13); ops.pollInterrupts = 2; ops.interruptStep = 1000;
      Require(std::string(state.waitForHandoff(ops)) == "timeout" && ops.timeouts == std::vector<int>({3000, 2000, 1000}),
              "EINTR retries consume rather than refresh deadline"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, 13); ops.pollInterrupts = 10000;
      Require(std::string(state.waitForHandoff(ops)) == "interrupt-budget" && ops.polls == RetryLimit + 1,
              "EINTR storm bounded even with stationary injected clock"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, 13); ops.spurious = 10000;
      Require(std::string(state.waitForHandoff(ops)) == "poll-budget" && ops.polls == PollLimit, "spurious wakes bounded"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, 13); ops.pollFails = true;
      Require(std::string(state.waitForHandoff(ops)) == "io-error", "broken ack fd cannot look acknowledged"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, 13); ops.monotonic = -1;
      Require(std::string(state.waitForHandoff(ops)) == "clock-error" && ops.polls == 0, "clock failure cannot wait forever"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, 13); ops.monotonic = INT64_MAX;
      Require(std::string(state.waitForHandoff(ops)) == "clock-error", "deadline overflow refused"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, -23); ops.ackFails = true; int code = 0;
      Require(state.acknowledge(ops, code) == Acknowledgement::Failed && code == -23 && ops.diagnostic.find("ack-write-error") != std::string::npos,
              "UI ack write failure supplies raw code for direct exit"); }
    { State state; Fake ops; Ready(state, ops); state.emit(ops, 7); ops.current = 101; int code = 0;
      Require(!state.authorized(ops) && !state.pending(ops) && state.acknowledge(ops, code) == Acknowledgement::NoPending,
              "fork cannot acknowledge owner session");
      Require(std::string(state.waitForHandoff(ops)) == "not-pending" && ops.polls == 0, "fork cannot wait on owner ack pipe"); }
    { State state; Fake ops; Ready(state, ops); ops.writeFailure = 1;
      Require(!state.emit(ops, 7) && !state.pending(ops) && state.authorized(ops), "write failure never publishes pending"); }
}

void TestEmission()
{
    State state; Fake ops; Ready(state, ops);
    ops.chunk = 1; ops.writeInterrupts = 3; ops.syncInterrupts = 2; ops.publishInterrupts = 2;
    Require(state.emit(ops, -7), "short writes and EINTR complete");
    Require(ops.data == "{\"schema\":1,\"activityId\":42,\"pid\":100,\"parentPid\":200,\"exitCode\":-7,\"source\":\"jvm-exit\",\"timestamp\":1789752395515}\n",
            "exact request record preserves original signed code");
    Require(!state.armed(ops) && !state.emit(ops, 0), "reentry cannot rewrite record");
    Require(state.prepare(ops, Files, 42) < 0 && state.authorize(ops, Files, 200, 7) < 0, "exit is irreversible");
    for (int failure : {1, 2, 3}) {
        State bad; Fake io; Ready(bad, io); io.writeFailure = failure;
        Require(!bad.emit(io, 0) && io.publishes == 0 && io.syncs == 0, "failed/zero/oversized write never publishes");
    }
    { State bad; Fake io; Ready(bad, io); io.writeInterrupts = 10000;
      Require(!bad.emit(io, 0) && io.writes <= RetryLimit + 1 && io.publishes == 0, "EINTR storm is bounded"); }
    { State bad; Fake io; Ready(bad, io); io.syncFailure = 1;
      Require(!bad.emit(io, 0) && io.publishes == 0, "fsync failure leaves temporary evidence"); }
    { State bad; Fake io; Ready(bad, io); io.syncInterrupts = 10000;
      Require(!bad.emit(io, 0) && io.syncs <= RetryLimit + 1 && io.publishes == 0, "fsync EINTR bounded"); }
    { State bad; Fake io; Ready(bad, io); io.publishFailure = 1;
      Require(!bad.emit(io, 0) && io.publishes == 1, "rename failure preserved"); }
    { State bad; Fake io; Ready(bad, io); io.publishInterrupts = 10000;
      Require(!bad.emit(io, 0) && io.publishes <= RetryLimit + 1, "rename EINTR bounded"); }
}

void TestSerialization()
{
    char full[RecordCapacity];
    const std::size_t length = Serialize(full, sizeof(full), MaxActivity, INT_MAX, INT_MAX, INT_MIN, INT64_MAX);
    Require(length > 0 && length < sizeof(full), "maximum numeric record fits fixed buffer");
    const std::string text(full);
    Require(text.find("-2147483648") != std::string::npos && text.find("9223372036854775807") != std::string::npos,
            "signed integer boundaries preserved");
    char small[4] = {'a', 'b', 'c', 'd'};
    Require(Serialize(small, sizeof(small), 1, 2, 3, 0, 0) == 0 && small[3] == 'd', "small buffer never overflows");
    Require(Serialize(nullptr, 0, 1, 2, 3, 0, 0) == 0, "null output rejected");
    char number[24]; Buffer out(number, sizeof(number)); out.number(INT64_MIN);
    Require(out.finish() != 0 && std::string(number) == "-9223372036854775808", "INT64_MIN has no negation overflow");
}

/**
 * 四步握手的确定性 store-buffering 模型，不依赖 Windows/x86 能否碰巧重现 ARM/C++ 弱序。
 * 两线程分别先发布自己的 atomic 再读取对方的 atomic；另列两个写入可见事件。
 * 旧 release/acquire 若读到初始值，不建立跨线程 synchronizes-with，允许本线程读先于
 * 自己的写对另一线程可见。SC 要求本线程后续 SC 读取发生在该 SC 写的总序位置之后。
 * 本模型只证明这四步“不可能同时漏看”的性质，不冒充通用 C++ 内存模型验证器。
 */
enum HandshakeEvent { VmStore, VmLoad, UiStore, UiLoad, VmVisible, UiVisible };
struct ModelResult { bool legal; bool missed; };

ModelResult RunHandshakeOrder(const std::array<int, 6>& order, std::memory_order memoryOrder)
{
    std::array<std::size_t, 6> position{};
    for (std::size_t index = 0; index < order.size(); ++index) position[order[index]] = index;
    // 保持各线程程序顺序，并禁止一个尚未发出的写提前变成可见。
    if (position[VmStore] > position[VmLoad] || position[UiStore] > position[UiLoad] ||
        position[VmStore] > position[VmVisible] || position[UiStore] > position[UiVisible]) return {false, false};
    if (memoryOrder == std::memory_order_seq_cst &&
        (position[VmVisible] > position[VmLoad] || position[UiVisible] > position[UiLoad])) return {false, false};
    bool pendingWrite = false, deferredWrite = false, pendingVisible = false, deferredVisible = false;
    bool vmSeesDeferred = false, uiSeesPending = false;
    for (int event : order) {
        switch (event) {
            case VmStore: pendingWrite = true; break;
            case UiStore: deferredWrite = true; break;
            case VmVisible: pendingVisible = pendingWrite; break;
            case UiVisible: deferredVisible = deferredWrite; break;
            case VmLoad: vmSeesDeferred = deferredVisible; break;
            case UiLoad: uiSeesPending = pendingVisible; break;
        }
    }
    return {true, !vmSeesDeferred && !uiSeesPending};
}

void TestHandshakeMemoryOrder()
{
    // 绑定生产四个操作共用的顺序常量；退回原来的弱序选择会使本回归明确失败。
    Require(HandoffHandshakeOrder == std::memory_order_seq_cst, "production four-step handshake uses one SC order");
    const std::array<int, 6> counterexample{VmStore, UiStore, VmLoad, UiLoad, VmVisible, UiVisible};
    const ModelResult old = RunHandshakeOrder(counterexample, std::memory_order_acq_rel);
    Require(old.legal && old.missed, "negative control reproduces old both-stale store-buffering outcome");
    Require(!RunHandshakeOrder(counterexample, HandoffHandshakeOrder).legal, "SC forbids controlled both-stale order");
    std::array<int, 6> order{0, 1, 2, 3, 4, 5};
    int weakLegal = 0, weakMissed = 0, scLegal = 0, scMissed = 0;
    do {
        const ModelResult weak = RunHandshakeOrder(order, std::memory_order_acq_rel);
        const ModelResult strict = RunHandshakeOrder(order, HandoffHandshakeOrder);
        if (weak.legal) { ++weakLegal; if (weak.missed) ++weakMissed; }
        if (strict.legal) { ++scLegal; if (strict.missed) ++scMissed; }
    } while (std::next_permutation(order.begin(), order.end()));
    Require(weakLegal == 80 && weakMissed > 0, "weak model admits the lost acknowledgement");
    Require(scLegal == 20 && scMissed == 0, "all SC interleavings guarantee at least one acknowledgement route");

    // 控制另一条实际核心路径：VM 已读 deferred=false 并开始 poll，UI 此时看到 Pending，
    // 必须直接投递 pipe；与已有 onWrite 触发的 deferred 路径共同覆盖两方接管。
    State state; Fake ops; Ready(state, ops); Require(state.emit(ops, 19), "late-UI interleaving setup");
    ops.onPoll = [&] {
        int code = 0;
        Require(state.acknowledge(ops, code) == Acknowledgement::Owned && code == 19, "late UI directly sends pending ack");
    };
    Require(std::string(state.waitForHandoff(ops)) == "acknowledged" && ops.polls == 1 && ops.ackWrites == 1,
            "late UI acknowledgement does not consume a timeout");
}
} // namespace

int main()
{
    TestAuthorization(); TestPreparation(); TestEmission(); TestSerialization(); TestHandoff(); TestHandshakeMemoryOrder();
    std::cout << "PASS " << checks << " game exit assertions (production core, fake I/O)\n";
}

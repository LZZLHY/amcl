/**
 * 游戏同步对话框broker：没有shell、文件访问或图形对象所有权。共享库单实例负责
 * 把Java线程的同步等待转换为ArkTS事件线程的有界FIFO读取与精确回包。
 * PID在DSO初始化时固定；fork后的调用在取得继承mutex前拒绝，避免死锁与身份借用。
 */
#include "game_dialog.h"
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <unistd.h>

namespace {
const pid_t ownerPid = getpid();
std::mutex mutex;
uint64_t nextGeneration = 0, nextRequest = 0, generation = 0, session = 0;
std::thread::id uiThread;
bool attached = false;

/** 每个等待者持有自己的shared_ptr，退役移除队列后也不会释放仍被等待的condition。 */
struct Pending {
    AmclGameDialogRequestV1 wire{};
    std::condition_variable changed;
    bool delivered = false, complete = false;
    int result = 0;
};
std::deque<std::shared_ptr<Pending>> pending;

/** 文本只在有界范围内读取，超长明确拒绝，不截断成另一条可能改变决策的提示。 */
template<size_t N> bool Copy(char (&destination)[N], const char* source) {
    if (!source) { destination[0] = '\0'; return true; }
    const size_t length = strnlen(source, N);
    if (length == N) return false;
    std::memcpy(destination, source, length + 1);
    return true;
}
bool OnUi(uint64_t expected) {
    return attached && generation == expected && uiThread == std::this_thread::get_id();
}
/** 不记录模组提供的正文，失败码可观察但不能把环境失败伪装成点击了确定。 */
int Reject(const char* reason) {
    std::fprintf(stderr, "AMCL_GAME_DIALOG rejected=%s\n", reason);
    return 0;
}

int Enqueue(const char* title, const char* message, int kind, int defaultButton, bool wait) {
    if (ownerPid != getpid()) return Reject("fork-owner");
    try {
        uint64_t enteringGeneration = 0;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!attached) return Reject("no-window");
            enteringGeneration = generation;
        }
        auto request = std::make_shared<Pending>();
        request->wire.size = sizeof(request->wire);
        request->wire.kind = static_cast<uint32_t>(kind);
        request->wire.defaultButton = defaultButton;
        if (!Copy(request->wire.title, title) || !Copy(request->wire.message, message))
            return Reject("text-too-long");
        std::unique_lock<std::mutex> lock(mutex);
        if (!attached) return Reject("no-window");
        if (enteringGeneration != generation) return Reject("window-changed-before-enqueue");
        if (wait && uiThread == std::this_thread::get_id()) return Reject("ui-thread-wait");
        if (pending.size() >= 8 || nextRequest == UINT64_MAX) return Reject("queue-full");
        request->wire.generation = generation;
        request->wire.requestId = ++nextRequest;
        pending.push_back(request);
        // 通知没有同步返回值语义；其生命周期仍由同一队列和回包/退役闭合。
        if (!wait) return 1;
        request->changed.wait(lock, [&request] { return request->complete; });
        return request->result;
    } catch (...) { return Reject("allocation-or-wait"); }
}
}

extern "C" uint64_t AmclGameDialogAttachV1(uint64_t currentSession) {
    if (ownerPid != getpid() || !currentSession) return 0;
    std::lock_guard<std::mutex> lock(mutex);
    if (attached || nextGeneration == UINT64_MAX) return 0;
    // 现役GameSessionHost结束后保留墓碑，SharedProcessGameLease派发后也保到进程
    // 结束；两条路线均不在一个已用JVM进程里切新会话。同局窗口重建可以换代次。
    if (session && session != currentSession) return 0;
    session = currentSession;
    generation = ++nextGeneration;
    uiThread = std::this_thread::get_id();
    attached = true;
    return generation;
}

extern "C" int AmclGameDialogDetachV1(uint64_t expected) {
    if (ownerPid != getpid()) return 0;
    std::lock_guard<std::mutex> lock(mutex);
    // 已退的原代次可确认幂等完成；不同代次或线程绝不借此收掉后来窗口。
    if (!expected || generation != expected || uiThread != std::this_thread::get_id()) return 0;
    if (!attached) return 1;
    attached = false;
    for (auto& request : pending) {
        request->result = 0;
        request->complete = true;
        std::fprintf(stderr, "AMCL_GAME_DIALOG completed=window-retired result=0 session=%llu request=%llu\n",
            static_cast<unsigned long long>(session), static_cast<unsigned long long>(request->wire.requestId));
        request->changed.notify_all();
    }
    pending.clear();
    return 1;
}

extern "C" int AmclGameDialogAvailableV1(void) {
    if (ownerPid != getpid()) return 0;
    std::lock_guard<std::mutex> lock(mutex);
    return attached ? 1 : 0;
}

extern "C" int AmclGameDialogTakeV1(uint64_t expected, AmclGameDialogRequestV1* out) {
    if (ownerPid != getpid() || !out || out->size != sizeof(*out)) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    if (!OnUi(expected)) return -2;
    if (pending.empty() || pending.front()->delivered) return 0;
    *out = pending.front()->wire;
    pending.front()->delivered = true;
    return 1;
}

/** 内部保留真实完成原因；旧TinyFD ABI最终仍只能以0表示取消或平台不可用。 */
static int Complete(uint64_t expected, uint64_t id, int result, const char* outcome) {
    if (ownerPid != getpid()) return 0;
    std::lock_guard<std::mutex> lock(mutex);
    if (!OnUi(expected) || pending.empty()) return 0;
    const auto request = pending.front();
    if (!request->delivered || request->wire.requestId != id || result < 0 || result > 2 ||
        (result == 2 && request->wire.kind != AMCL_DIALOG_YES_NO_CANCEL) ||
        (request->wire.kind == AMCL_DIALOG_NOTIFY && result != 0)) return 0;
    pending.pop_front();
    request->result = result;
    request->complete = true;
    std::fprintf(stderr, "AMCL_GAME_DIALOG completed=%s result=%d session=%llu request=%llu\n", outcome, result,
        static_cast<unsigned long long>(session), static_cast<unsigned long long>(id));
    request->changed.notify_all();
    return 1;
}

extern "C" int AmclGameDialogReplyV1(uint64_t expected, uint64_t id, int result) {
    return Complete(expected, id, result, "user-response");
}
extern "C" int AmclGameDialogCancelV1(uint64_t expected, uint64_t id) {
    return Complete(expected, id, 0, "unavailable-or-notification");
}

extern "C" int AmclGameDialogMessageV1(const char* title, const char* message, int kind, int button) {
    if (kind < AMCL_DIALOG_OK || kind > AMCL_DIALOG_YES_NO_CANCEL || button < 0 || button > 2 ||
        (button == 2 && kind != AMCL_DIALOG_YES_NO_CANCEL)) return Reject("invalid-buttons");
    return Enqueue(title, message, kind, button, true);
}
extern "C" int AmclGameDialogNotifyV1(const char* title, const char* message) {
    return Enqueue(title, message, AMCL_DIALOG_NOTIFY, 0, false);
}

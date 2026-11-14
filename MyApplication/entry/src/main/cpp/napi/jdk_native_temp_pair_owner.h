/**
 * 固定target/client双NCP退出owner。Start只在锁内预留槽位，外部SDK调用不持mutex；
 * 同步重入或SDK等待回调完成都可进来。最多保存两个早到事件，再按实际返回PID绑定。
 * 成功却给出非法/重复PID属于SDK合同违例：保留Unknown和原owner，拒绝新Start，
 * 不猜PID终止，也不把未知启动当作无子进程；此边界要求父进程重启。
 * 工作线程有限清理后仍保留两个已知owner，真实迟到exit收齐再通知现有NAPI事件循环回收。
 * 本类不创建线程、不调用SDK/NAPI或轮询；callbackSignal从不解码为OS退出码。
 */
#pragma once
#include <array>
#include <cerrno>
#include <cstdint>
#include <mutex>

namespace amcl::temppair {
enum class StartState { Empty, Reserved, Owned, Unknown };
struct ChildExit {
    int32_t pid = -1, reportedStartPid = -1, callbackSignal = 0;
    int startResult = 0;
    bool observed = false;
    StartState start = StartState::Empty;
};
struct PairSnapshot {
    std::array<ChildExit, 2> slots{};
    bool sealed = false, workerReleased = false, reclaimQueued = false, reclaimed = false;
    bool poisonedStart = false, earlyOverflow = false;
    unsigned earlyEventCount = 0;
};
class PairOwner final {
    struct EarlyExit { int32_t pid = -1, signal = 0; };
    std::mutex mutex_;
    PairSnapshot state_;
    std::array<EarlyExit, 2> early_{};
    int reserved_ = -1;
    void (*notify_)(void*) noexcept;
    void* context_;
    bool allExitedLocked() const noexcept {
        if (state_.poisonedStart) return false;
        for (const auto& item : state_.slots) {
            if (item.start == StartState::Reserved || item.start == StartState::Unknown) return false;
            if (item.start == StartState::Owned && !item.observed) return false;
        }
        return true;
    }
    bool queueLocked() noexcept {
        if (!state_.sealed || !state_.workerReleased || !allExitedLocked() || state_.reclaimQueued) return false;
        state_.reclaimQueued = true; return true;
    }
public:
    // notifier仅非阻塞投递回收事件，不能在SDK回调栈中同步注销/销毁此对象。
    PairOwner(void (*notify)(void*) noexcept, void* context) : notify_(notify), context_(context) {}
    PairOwner(const PairOwner&) = delete;
    PairOwner& operator=(const PairOwner&) = delete;
    template<class Start> int start(unsigned slot, Start&& invoke) {
        {
            std::lock_guard<std::mutex> guard(mutex_);
            if (state_.poisonedStart || state_.earlyOverflow) return EPROTO;
            if (slot >= state_.slots.size() || state_.sealed || state_.slots[slot].start != StartState::Empty) return EINVAL;
            if (reserved_ >= 0) return EBUSY;
            state_.slots[slot].start = StartState::Reserved; reserved_ = static_cast<int>(slot);
            early_ = {}; state_.earlyEventCount = 0;
        }
        int32_t pid = -1; int result;
        try { result = invoke(&pid); }
        catch (...) {
            // 外部调用抛出后无法证明没有创建进程；未知状态不可当作正常非零SDK返回。
            std::lock_guard<std::mutex> guard(mutex_);
            auto& entry = state_.slots[slot];entry.start = StartState::Unknown;entry.reportedStartPid = pid;
            entry.startResult = EIO;state_.poisonedStart = true;reserved_ = -1;return EIO;
        }
        bool notify = false;
        {
            std::lock_guard<std::mutex> guard(mutex_);
            auto& entry = state_.slots[slot];entry.reportedStartPid = pid;entry.startResult = result;
            reserved_ = -1;
            if (result != 0) {
                // 官方非零返回按未启动处理，不因无关早到事件任意扩成未知子进程。
                entry.start = StartState::Empty;
            } else if (pid <= 0 || state_.slots[1 - slot].pid == pid) {
                entry.start = StartState::Unknown;state_.poisonedStart = true;result = EPROTO;
            } else {
                entry.start = StartState::Owned;entry.pid = pid;
                for (const auto& early : early_) if (early.pid == pid) {
                    entry.observed = true;entry.callbackSignal = early.signal;break;
                }
                // 有界缓存溢出不能静默丢弃后宣称成功；已拿到的真实PID仍由本槽持有并清理。
                if (state_.earlyOverflow) result = EOVERFLOW;
            }
            early_ = {};notify = queueLocked();
        }
        if (notify) notify_(context_);
        return result;
    }
    bool exited(int32_t pid, int32_t signal) noexcept {
        bool accepted = false, notify = false;
        {
            std::lock_guard<std::mutex> guard(mutex_);
            if (pid > 0) for (auto& item : state_.slots) {
                if (item.start != StartState::Owned || item.pid != pid) continue;
                accepted = true;
                if (!item.observed) {item.observed = true;item.callbackSignal = signal;}
            }
            if (!accepted && pid > 0 && reserved_ >= 0) {
                for (const auto& early : early_) if (early.pid == pid) accepted = true;
                if (!accepted) {
                    for (auto& early : early_) if (early.pid < 0) {
                        early = {pid, signal};++state_.earlyEventCount;accepted = true;break;
                    }
                    if (!accepted) state_.earlyOverflow = true;
                }
            }
            notify = queueLocked();
        }
        if (notify) notify_(context_);
        return accepted;
    }
    void seal() noexcept {
        bool notify;
        {std::lock_guard<std::mutex> guard(mutex_);state_.sealed = true;notify = queueLocked();}
        if (notify) notify_(context_);
    }
    void releaseWorker() noexcept {
        bool notify;
        {std::lock_guard<std::mutex> guard(mutex_);state_.workerReleased = true;notify = queueLocked();}
        if (notify) notify_(context_);
    }
    PairSnapshot snapshot() noexcept {std::lock_guard<std::mutex> guard(mutex_);return state_;}
    bool allExited() noexcept {std::lock_guard<std::mutex> guard(mutex_);return allExitedLocked();}
    bool reclaimed() noexcept {
        std::lock_guard<std::mutex> guard(mutex_);
        if (!state_.reclaimQueued || !allExitedLocked() || state_.reclaimed) return false;
        state_.reclaimed = true;return true;
    }
};
}

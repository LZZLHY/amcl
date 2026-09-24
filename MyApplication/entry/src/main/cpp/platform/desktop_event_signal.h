#pragma once
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cstdint>

namespace amcl::desktop {
class EventSignal {
    std::mutex mutex_;
    std::condition_variable changed_;
    uint64_t epoch_ = 1;
public:
    uint64_t epoch() { std::lock_guard<std::mutex> lock(mutex_); return epoch_; }
    void wake() {
        { std::lock_guard<std::mutex> lock(mutex_); ++epoch_; }
        changed_.notify_all();
    }
    bool wait(uint64_t observed, int64_t timeoutNs) {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto pending = [&] { return epoch_ != observed; };
        if (timeoutNs < 0) { changed_.wait(lock, pending); return true; }
        return changed_.wait_for(lock, std::chrono::nanoseconds(timeoutNs), pending);
    }
};
}

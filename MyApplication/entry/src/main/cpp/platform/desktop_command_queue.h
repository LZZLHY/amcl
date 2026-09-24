#pragma once
#include "desktop_host_api.h"
#include <deque>
#include <string>

namespace amcl::desktop {
struct Command {
    uint64_t sequence = 0, generation = 0;
    int32_t kind = 0, a = 0, b = 0, c = 0, d = 0;
    std::string text;
};
// External mutex protects the queue and the wake-up callback as one transaction.
class CommandQueue {
public:
    uint64_t attach() { detach(); active_ = true; return ++generation_; }
    void detach() { failed_ += pending_.size() + (inFlight_ ? 1 : 0); pending_.clear(); inFlight_ = 0; active_ = false; }
    uint64_t submit(Command command) {
        if (!active_ || pending_.size() >= 128 || sequence_ >= 9007199254740990ULL ||
            command.kind < AMCL_DESKTOP_RESIZE || command.kind > AMCL_DESKTOP_CLIPBOARD_PERMISSION ||
            command.text.size() > 65536) return 0;
        command.sequence = ++sequence_; command.generation = generation_;
        pending_.push_back(std::move(command)); return sequence_;
    }
    bool take(Command& command) {
        if (!active_ || inFlight_ || pending_.empty()) return false;
        command = std::move(pending_.front()); pending_.pop_front(); inFlight_ = command.sequence; return true;
    }
    bool complete(uint64_t generation, uint64_t sequence, int32_t error) {
        if (!active_ || generation != generation_ || sequence != inFlight_ || !inFlight_) return false;
        completed_ = sequence; inFlight_ = 0; if (error) ++failed_; lastError_ = error; return true;
    }
    bool active() const { return active_; }
    uint64_t generation() const { return generation_; }
    uint64_t accepted() const { return sequence_; }
    uint64_t completed() const { return completed_; }
    uint64_t failed() const { return failed_; }
    int32_t lastError() const { return lastError_; }
private:
    std::deque<Command> pending_;
    uint64_t generation_ = 0, sequence_ = 0, completed_ = 0, failed_ = 0, inFlight_ = 0;
    int32_t lastError_ = 0;
    bool active_ = false;
};
}

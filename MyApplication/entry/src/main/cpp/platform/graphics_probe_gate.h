#pragma once
#include <atomic>
#include <cstdint>

namespace amcl::graphics {
/** 进程期探针互斥门：PID和busy合在同一次CAS中发布，避免首次调用先更新PID、
 * 随后清busy时抹掉另一个线程已取得的资格。fork子进程可以认领自己的空闲门，
 * 但旧PID的资源是否可用仍由各provider单独判定，获得忙门不等于驱动可继承。
 */
class GraphicsProbeGate {
    std::atomic<uint64_t> state_{0};
    bool enter(uint32_t pid) {
        if (!pid) return false;
        const uint64_t owned = (static_cast<uint64_t>(pid) << 1) | 1u;
        auto observed = state_.load(std::memory_order_acquire);
        for (;;) {
            if (observed == owned) return false;
            if (state_.compare_exchange_weak(observed, owned, std::memory_order_acq_rel,
                    std::memory_order_acquire)) return true;
        }
    }
    void leave(uint32_t pid) {
        uint64_t owned = (static_cast<uint64_t>(pid) << 1) | 1u;
        // 释放只针对取得资格时的PID；旧进程/旧租约不能清除后来认领的新PID状态。
        state_.compare_exchange_strong(owned, static_cast<uint64_t>(pid) << 1,
            std::memory_order_release, std::memory_order_relaxed);
    }
public:
    class Lease {
        GraphicsProbeGate& gate_;
        uint32_t pid_;
        bool entered_;
    public:
        Lease(GraphicsProbeGate& gate, uint32_t pid) : gate_(gate), pid_(pid), entered_(gate.enter(pid)) {}
        ~Lease() { if (entered_) gate_.leave(pid_); }
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
        bool entered() const { return entered_; }
    };
};
}

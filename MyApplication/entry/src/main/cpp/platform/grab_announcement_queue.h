// grab_announcement_queue.h — libglfw grab 翻转公告与触摸侧消费的线性化点
//
// 职责：MC 线程在真实 cursor-mode 翻转时调用 `amcl_touch_on_grab_changed` 公告状态；
// 触摸 ingress 与 schema 发布在持 s_touchStateMutex 时取走全部待处理翻转，先迁移旧 epoch
// 的手指 / owner，再按“最新公告状态”解释本次事件。
//
// 为什么要把“读公告状态”放进取队列的同一临界区：旧实现先无锁读一次公告状态，再加锁取队列。
// 两步之间若恰好到达一次翻转，这次翻转会被处理（旧层手指按新模式作废），而本次事件却按
// 翻转前的模式分类 —— game→menu 时新手指可能被绑成游戏层按钮，在菜单里点出一次左键。
// 现在 `Take` 在同一把锁里交换队列并读出状态，调用方只使用 `ApplyGrabAnnouncements` 返回的
// 生效状态；此后到达的翻转属于下一个事件，线性化点唯一。
//
// 线程与锁：队列借用调用方传入的 mutex（产品里是 touch_input.cpp 的 s_grabAnnouncementMutex），
// 该锁只包住队列与状态本身，从不回调、不调用 ingress；公告方可以在 bridge 的物理运动锁内调用
// `Announce`。`ApplyGrabAnnouncements` 是纯函数，调用方负责提供串行化（产品里是
// s_touchStateMutex），onFlip 在调用方的锁内同步执行。
#ifndef AMCL_PLATFORM_GRAB_ANNOUNCEMENT_QUEUE_H
#define AMCL_PLATFORM_GRAB_ANNOUNCEMENT_QUEUE_H

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <utility>

namespace amcl::input {

// 一次消费取走的内容。announced 与 pending 来自同一临界区：pending 非空时它一定等于
// pending.back()，因为公告方在同一把锁里入队并更新状态。
struct GrabAnnouncementBatch {
    std::deque<bool> pending;
    int announced = -1;   // -1 = 进程内还没有任何公告；0 / 1 = 最近一次公告的 grab 状态
};

class GrabAnnouncementQueue final {
public:
    // mutex 必须比本对象活得长（产品里两者都是同一 TU 的文件级静态量，按声明顺序构造）。
    explicit GrabAnnouncementQueue(std::mutex& mutex) : mutex_(mutex) {}
    GrabAnnouncementQueue(const GrabAnnouncementQueue&) = delete;
    GrabAnnouncementQueue& operator=(const GrabAnnouncementQueue&) = delete;

    // MC 线程（经 trampoline）发布一次真实翻转。只入队并更新状态，不做任何迁移。
    void Announce(bool grabbing) {
        std::lock_guard<std::mutex> lock(mutex_);
        queue_.push_back(grabbing);
        announced_.store(grabbing ? 1 : 0, std::memory_order_release);
        announcements_.fetch_add(1u, std::memory_order_relaxed);
    }

    // 原子地取走全部待处理翻转，并在同一临界区读出最新公告状态。
    GrabAnnouncementBatch Take() {
        GrabAnnouncementBatch batch;
        std::lock_guard<std::mutex> lock(mutex_);
        batch.pending.swap(queue_);
        batch.announced = announced_.load(std::memory_order_relaxed);
        return batch;
    }

    // 无锁读最近一次公告状态（-1 表示尚无公告）。只用于“要不要消费”的快速判断，
    // 不能用来解释事件：解释必须用 ApplyGrabAnnouncements 的返回值。
    int AnnouncedState() const {
        return announced_.load(std::memory_order_acquire);
    }

    // 累计公告次数，只供诊断与 host 测试核对“每次翻转恰好入队一次”。
    uint64_t AnnouncementCount() const {
        return announcements_.load(std::memory_order_relaxed);
    }

private:
    std::mutex& mutex_;
    std::deque<bool> queue_;
    std::atomic<int> announced_{-1};
    std::atomic<uint64_t> announcements_{0u};
};

// 按顺序应用一批翻转并返回本次事件应使用的生效 grab 状态。
//   · lastState / initialized：调用方持有的“已迁移到哪个 epoch”（产品里是 s_grabFlipLastState /
//     s_grabFlipInit），只在调用方的锁内读写；
//   · fallbackGrabbed：进程内尚无公告时的兜底读数（bridge 的 isGrabbing），有公告时不参与判定；
//   · onFlip(newState)：每个真实翻转调用一次，顺序与公告顺序一致，先于调用方登记本次事件。
// 首次消费时若公告早于第一次 ingress 到达，基准取第一条公告之前的状态，保证每条翻转都被处理。
template <typename OnFlip>
bool ApplyGrabAnnouncements(bool& lastState, bool& initialized,
                            GrabAnnouncementBatch batch, bool fallbackGrabbed,
                            OnFlip&& onFlip) {
    const bool effective =
        batch.announced >= 0 ? batch.announced != 0 : fallbackGrabbed;
    if (!initialized) {
        lastState = batch.pending.empty() ? effective : !batch.pending.front();
        initialized = true;
    }
    if (batch.pending.empty()) batch.pending.push_back(effective);
    for (const bool announced : batch.pending) {
        if (announced == lastState) continue;
        // 关键顺序：先更新基准再迁移，onFlip 内部若再次读取基准看到的已是新 epoch。
        lastState = announced;
        onFlip(announced);
    }
    return lastState;
}

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_GRAB_ANNOUNCEMENT_QUEUE_H

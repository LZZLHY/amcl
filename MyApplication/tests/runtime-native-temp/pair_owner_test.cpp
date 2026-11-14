/** 两槽生产候选核心的真实并发/失败边界；不模拟成功NCP或虚构目标退出。 */
#include "../../entry/src/main/cpp/napi/jdk_native_temp_pair_owner.h"
#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>
using amcl::temppair::PairOwner;
static void notify(void* data) noexcept { ++*static_cast<std::atomic<int>*>(data); }
int main() {
    {
        std::atomic<int> queued{0}; PairOwner p(notify, &queued);
        assert(p.start(0, [](int32_t* id) { *id=101;return 0; })==0);
        assert(p.start(1, [](int32_t* id) { *id=102;return 0; })==0);
        p.seal(); assert(!p.allExited()); assert(!p.exited(999,0));
        assert(p.exited(102,7)); assert(!p.allExited()); p.releaseWorker(); assert(queued==0);
        assert(p.exited(101,0)); assert(queued==1 && p.allExited());
        assert(p.exited(102,0)); assert(queued==1 && p.snapshot().slots[1].callbackSignal==7);
        assert(p.reclaimed()); assert(!p.reclaimed());
    }
    {
        // SDK等待另一线程回调完成后才返回；Start期间必须无内部mutex，避免锁环。
        std::atomic<int> queued{0}, entered{0}; PairOwner p(notify, &queued); std::thread callback;
        assert(p.start(0, [&](int32_t* id) {
            callback=std::thread([&] {entered=1;p.exited(201,15);});
            while (!entered.load()) std::this_thread::yield();
            callback.join(); *id=201;return 0;
        })==0);
        assert(p.snapshot().slots[0].observed); assert(queued==0);
        // 第二个Start失败也必须等第一个实际退出；此例退出已到，seal/release恰好通知一次。
        assert(p.start(1, [](int32_t*) {return EAGAIN;})==EAGAIN);
        p.seal(); assert(queued==0);p.releaseWorker();assert(queued==1);assert(p.reclaimed());
    }
    {
        // 超时清理到期后不无限析构或伪造退出；固定owner仍忙，直到真实迟到的两个exit都到达。
        std::atomic<int> queued{0}; PairOwner p(notify,&queued);
        assert(p.start(0,[](int32_t* id){*id=301;return 0;})==0);
        assert(p.start(1,[](int32_t* id){*id=302;return 0;})==0);
        p.seal();p.releaseWorker();assert(queued==0 && !p.reclaimed());
        assert(p.start(0,[](int32_t*){assert(false);return 0;})==EINVAL);
        assert(p.exited(301,0));assert(queued==0);assert(p.exited(302,255));assert(queued==1);
        assert(p.reclaimed());
    }
    {
        // 真正同线程inline回调先发生，再把PID交给Start返回值；不得依赖递归mutex。
        std::atomic<int> queued{0};PairOwner p(notify,&queued);
        assert(p.start(0,[&](int32_t* id){assert(p.exited(501,7));*id=501;return 0;})==0);
        assert(p.snapshot().slots[0].observed && p.snapshot().slots[0].callbackSignal==7);
        p.seal();p.releaseWorker();assert(queued==1 && p.reclaimed());
    }
    for (int32_t bad : {0,-1}) {
        std::atomic<int> queued{0};PairOwner p(notify,&queued);
        assert(p.start(0,[&](int32_t* id){*id=bad;return 0;})==EPROTO);
        p.seal();p.releaseWorker();assert(p.snapshot().poisonedStart && !p.allExited() && !p.reclaimed() && queued==0);
        assert(p.start(1,[](int32_t*){assert(false);return 0;})==EPROTO);
        assert(!p.exited(555,0));
    }
    {
        std::atomic<int> queued{0};PairOwner p(notify,&queued);
        assert(p.start(0,[](int32_t* id){*id=601;return 0;})==0);
        assert(p.start(1,[](int32_t* id){*id=601;return 0;})==EPROTO);
        assert(p.snapshot().slots[0].pid==601 && p.snapshot().slots[1].pid==-1);
        p.seal();p.releaseWorker();assert(p.exited(601,0));
        assert(p.snapshot().slots[0].observed && p.snapshot().poisonedStart && !p.allExited() && queued==0);
    }
    {
        std::atomic<int> queued{0};PairOwner p(notify,&queued);
        assert(p.start(0,[&](int32_t* id){p.exited(701,0);p.exited(702,0);p.exited(703,0);*id=704;return 0;})==EOVERFLOW);
        assert(p.snapshot().earlyOverflow && p.snapshot().slots[0].pid==704 && !p.allExited());
        p.seal();p.releaseWorker();assert(p.exited(704,0));assert(queued==1 && p.reclaimed());
    }
    for (int round=0;round<200;++round) {
        // 两个SDK回调并发和worker交还交错，最终只排一个回收事件。
        std::atomic<int> queued{0};PairOwner p(notify,&queued);
        assert(p.start(0,[](int32_t* id){*id=401;return 0;})==0);
        assert(p.start(1,[](int32_t* id){*id=402;return 0;})==0);p.seal();
        std::thread a([&]{p.exited(401,0);}),b([&]{p.exited(402,0);});p.releaseWorker();a.join();b.join();
        assert(queued==1 && p.allExited() && p.reclaimed());
    }
    puts("PASS fixed pair owner: inline/joined early callbacks, zero/negative/duplicate PID poisoned, bounded early overflow, two PIDs/late exits, 200 concurrent reclaim races");
}

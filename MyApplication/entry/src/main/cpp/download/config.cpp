#include "config.h"

#include <hilog/log.h>

#include <atomic>
#include <memory>
#include <mutex>

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_CFG"

namespace download {

namespace {

// L-1 修复：getCaBundlePath 每次 setopt 都 lock 全局 mutex 太重 — 3000+ assets ×
// 64 并发 × 每次 curl_easy_setopt(CAINFO) 都查一次 = 数十万次 lock。
//
// CA bundle path 在 ArkTS init 时设一次，运行期基本不变。改成
// shared_ptr<const string> + atomic_load/store 风格的无锁读路径：
//   - 读路径：atomic_load 一次，零 contention
//   - 写路径：保留 g_mu_writer 串行化 setter（罕见）
//
// shared_ptr 因 atomic_load/atomic_store 在 C++20 标记 deprecated，但项目目前
// 仍是 C++17，且 OHOS NDK 不一定有 std::atomic<std::shared_ptr<T>>，所以这里
// 用 std::atomic<std::shared_ptr<const std::string>*> 套 + mutex 释放旧 ptr
// 的方式。读路径完全无锁。
std::mutex            g_writer_mu;
std::atomic<const std::string*> g_ca_atomic{nullptr};
// 持稳 string 内存，setter 时换出旧的延迟释放（用 unique_ptr 池）
std::vector<std::unique_ptr<const std::string>> g_ca_pool;  // setter 持锁访问

const std::string& emptyStr() {
    static const std::string e;
    return e;
}

} // namespace

void setCaBundlePath(std::string path) {
    auto* fresh = new std::string(std::move(path));
    const std::string* prev = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_writer_mu);
        prev = g_ca_atomic.load(std::memory_order_acquire);
        if (prev && *prev == *fresh) {
            // 路径未变 — 不做切换，直接释放新分配
            delete fresh;
            return;
        }
        g_ca_atomic.store(fresh, std::memory_order_release);
        // 旧 string 不能直接 delete（可能有读者正在使用引用），放入 pool
        // 让进程退出时统一释放。运行期 setCaBundlePath 几乎只调一次，pool
        // 不会增长。
        if (prev) {
            g_ca_pool.emplace_back(prev);
        }
    }
    AMCL_LOG_I(LOG_TAG, "CA bundle path set to: %{public}s",
                fresh->empty() ? "(empty, use curl default)" : fresh->c_str());
}

std::string getCaBundlePath() {
    // 无锁读：原子拿当前指针，拷贝一份返回（按值返回符合现有 API）。
    // 调用方拿到的 std::string 是独立拷贝，即使后续 setCaBundlePath 切换
    // 原子指针也不影响这份拷贝。
    const std::string* p = g_ca_atomic.load(std::memory_order_acquire);
    return p ? *p : emptyStr();
}

} // namespace download

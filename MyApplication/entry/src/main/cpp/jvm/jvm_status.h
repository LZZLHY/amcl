/**
 * JVM 普通状态文本的同步存储。状态只在启动/错误/显式查询时使用，不进入 JIT/TLS 或
 * 渲染热路径。发布先在锁外构造文本，再在锁内 swap；取快照后不向调用者借出共享缓冲。
 * 所有 fork 使用者必须登记 prepare/parent/child 钩子，在 fork 快照期间持锁并在两侧
 * 释放，防止子进程继承由已消失线程持有的锁。钩子不分配、不记录日志、不调用 Java。
 */
#pragma once
#include <pthread.h>
#include <string>

namespace amcl::jvm {
class StatusText {
public:
    StatusText() = default;
    StatusText(const StatusText&) = delete;
    StatusText& operator=(const StatusText&) = delete;
    StatusText& operator=(std::string value) {
        pthread_mutex_lock(&mutex_);
        text_.swap(value);
        pthread_mutex_unlock(&mutex_);
        // 被替换的旧文本在退出函数时于锁外释放，不把分配器与日志放进发布临界区。
        return *this;
    }
    std::string snapshot() {
        pthread_mutex_lock(&mutex_);
        struct Unlock { pthread_mutex_t* mutex; ~Unlock() { pthread_mutex_unlock(mutex); } } unlock{&mutex_};
        return text_; // 分配失败也由栈守卫解锁；外层 C API 决定如何报告读快照失败。
    }
    void beforeFork() { pthread_mutex_lock(&mutex_); }
    void afterFork() { pthread_mutex_unlock(&mutex_); }
private:
    pthread_mutex_t mutex_ = PTHREAD_MUTEX_INITIALIZER;
    std::string text_;
};
} // namespace amcl::jvm

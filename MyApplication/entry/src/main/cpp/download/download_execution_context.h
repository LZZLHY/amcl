/**
 * download_execution_context.h — 下载器同步执行栈的轻量线程上下文。
 *
 * 只记录当前线程是否正在执行下载器操作、内部循环或同步 callback，不保存任务、
 * 线程句柄或跨线程状态。Engine::shutdown 必须由外部生命周期线程发起；内部栈反入
 * 会等待自己的 operation、callback 或 thread join，因此在发布 ShuttingDown 前拒绝。
 * 外部并发 shutdown 仍使用 Engine 原有条件变量等待同一次关闭完成。
 */
#pragma once

#include <cstdint>

namespace download {

class DownloadExecutionContext {
public:
    /** RAII 深度允许 operation -> callback 等嵌套；不得把对象移动到另一线程析构。 */
    DownloadExecutionContext() { ++depth_; }
    ~DownloadExecutionContext() { --depth_; }
    DownloadExecutionContext(const DownloadExecutionContext&) = delete;
    DownloadExecutionContext& operator=(const DownloadExecutionContext&) = delete;

    /** 只读本线程，不能拿来判断别的线程是否已收敛或取代任务执行屏障。 */
    static bool active() { return depth_ != 0; }

private:
    inline static thread_local uint32_t depth_ = 0;
};

} // namespace download

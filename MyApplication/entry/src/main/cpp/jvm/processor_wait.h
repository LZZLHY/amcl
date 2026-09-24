/**
 * processor 精确子进程等待契约。
 *
 * 等待返回值与 status 必须一起验证：waitpid 失败时 status 没有有效退出含义，初始值 0
 * 也不代表子进程成功退出。仅 EINTR 重试，不增加超时、kill 或等待其他子进程的策略。
 * 注入 waitCall 以便宿主直接编译生产分支并模拟系统调用故障，不依赖真实信号时序。
 */
#pragma once

#include <cerrno>
#include <cstdint>

namespace amcl::jvm {
/** status 仅在 reaped=true 时可解码；其他情况保留 actualPid/error 供准确错误归因。 */
struct ProcessorWaitResult {
    bool reaped;
    int status;
    int error;
    int64_t actualPid;
};

/**
 * waitCall(expectedPid, &status, &error) 返回实际 waitpid 返回值，并立即保存对应 errno。
 * 只接受精确 expectedPid；返回 0/其他 PID 也必须失败，不能拿它们的 status 宣称目标已退出。
 * 不限制 EINTR 次数：信号中断不是子进程失败，也不能靠停止等待把仍运行的 processor 判成功。
 */
template <typename WaitCall>
ProcessorWaitResult WaitForProcessor(int64_t expectedPid, WaitCall waitCall) {
    if (expectedPid <= 0) return {false, 0, EINVAL, -1};
    for (;;) {
        int status = 0;
        int waitError = 0;
        const int64_t actualPid = waitCall(expectedPid, &status, &waitError);
        if (actualPid == expectedPid) return {true, status, 0, actualPid};
        if (actualPid == -1 && waitError == EINTR) continue;
        // 未返回目标 PID 时绝不暴露无效 status。缺 errno 的异常适配器也必须 fail closed。
        return {false, 0, actualPid == -1 ? (waitError ? waitError : EIO) : ECHILD, actualPid};
    }
}
}

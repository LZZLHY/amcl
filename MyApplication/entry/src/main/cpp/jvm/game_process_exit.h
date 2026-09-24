/**
 * 独立游戏进程的 JVM 退出所有权。这里只消费可信 native 持锁事实，不接受 JVM 属性授权。
 * 退出记录表示 JVM 请求退出的代码，不表示操作系统已经完成正常退出或 Java hook 全部成功。
 */
#ifndef AMCL_GAME_PROCESS_EXIT_H
#define AMCL_GAME_PROCESS_EXIT_H

#include <stdint.h>
#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 成功获得 .desktop-game.lock 后调用。借用 lockFd，绝不关闭它；0 成功，负值拒绝。
// 当前 PID、parentPid、filesDir 和锁身份只授权一次；同身份重复调用幂等，fork 不继承授权。
int amclGameExitAuthorize(const char* filesDir, int parentPid, int borrowedLockFd);

// 在创建 JVM 前准备本局退出通道：0 已准备，1 当前 PID 未授权（不安装 hook），负值拒绝启动。
// 同 activityId 重复调用幂等，已经准备后不可切换 session；所有 fd/文件名都在此时准备。
int amclGameExitPrepare(const char* filesDir, int64_t activityId);

// 已完成原生授权后的整个生命周期为 true（含准备、写记录、pending、等待结束）。
// 仅查询 PID 绑定元数据，不在 UI 轮询路径重新获取锁；用于避免窗口销毁标记抢先结束 JVM。
bool amclGameExitAuthorizedForCurrentProcess(void);

// 只有预备成功且 owner PID 与 getpid 一致才为 true；未授权/失败/fork/已进入退出均为 false。
bool amclGameExitArmedForCurrentProcess(void);

// 原始退出请求已完整发布后才为 true。mcIsRunning 可据此让前台游戏页面接管返回启动器。
// 状态绑定当前 PID；fork、未写完记录或记录失败均不能看到 pending。
bool amclGameExitPendingForCurrentProcess(void);

// 前台游戏页面完成返回启动器请求后调用。true=确认已交给本协议（写记录中会暂存确认），
// 调用者不可再 _exit(0)。暂存确认只有原始请求写完后才允许唤醒退出线程。
// false=本 PID 没有 pending，可用原有兜底。存在 pending 但 ack 写失败时，本函数直接
// 以保存的原始 JVM code 退出，不返回 false，避免调用者把非零退出码覆盖成 0。
bool amclGameExitAcknowledgeRequested(void);

// JNI exit hook 的非返回主体。调用方按 JNI 的 JNICALL ABI 包装；此函数本身不依赖 JNI。
// 写预开退出记录后发布 pending，只等待预开原生 pipe 的确认；3000ms 单调时钟绝对期限
// 或错误到达即 _exit(code)。不调用 JVM/NAPI/UI，无堆分配/常驻 worker；不处理 abort/fatal。
#ifdef __cplusplus
[[noreturn]]
#else
_Noreturn
#endif
void amclGameJvmExitHook(int code);

#ifdef __cplusplus
}
#endif
#endif

/**
 * amcl_log.h — AMCL 生产级日志系统
 *
 * 特性：
 *   - 异步写入（独立日志线程，不阻塞主线程）
 *   - 双写机制（hilog + 文件）
 *   - 日志轮转（按大小限制，保留最近 N 个文件）
 *   - 统一格式：[时间戳][级别][模块] 消息
 *   - 线程安全
 *
 * 使用方式：
 *   #include "amcl_log.h"
 *   AMCL_LOG_I("MODULE", "message %d", value);
 *   AMCL_LOG_E("MODULE", "error: %s", err);
 */

#ifndef AMCL_LOG_H
#define AMCL_LOG_H

#include <hilog/log.h>

#ifdef __cplusplus
extern "C" {
#endif

// 日志级别
typedef enum {
    AMCL_LOG_LEVEL_DEBUG = 0,
    AMCL_LOG_LEVEL_INFO = 1,
    AMCL_LOG_LEVEL_WARN = 2,
    AMCL_LOG_LEVEL_ERROR = 3,
    AMCL_LOG_LEVEL_FATAL = 4
} AmclLogLevel;

/**
 * 初始化日志系统
 * @param logDir 日志目录路径（如 /data/storage/el2/base/haps/entry/files/logs）
 * @param maxFileSize 单个日志文件最大字节数（默认 2MB）
 * @param maxFiles 保留的日志文件数量（默认 5）
 */
void amclLogInit(const char* logDir, int maxFileSize, int maxFiles);

/**
 * 关闭日志系统（刷新缓冲区，停止写入线程）
 */
void amclLogShutdown(void);

/**
 * 写入日志（内部使用，请用宏）
 */
void amclLogWrite(AmclLogLevel level, const char* tag, const char* fmt, ...);
/** 双写故障日志。变参仅求值一次；各 sink 使用独立 va_list，不能消耗对方游标。 */
void amclLogPrint(AmclLogLevel level, unsigned int domain, const char* tag, const char* fmt, ...);

/**
 * 刷新日志缓冲区到文件
 */
void amclLogFlush(void);
/** 显式刷新并返回是否完成且当前全局文件可写；历史缺口需结合状态查询，不会被重试抹除。 */
int amclLogFlushChecked(void);
/** 线程本地 JSON 快照：writable、writeFailures、lostWrites、lastError、longMessageBytes。 */
const char* amclLogGetStatus(void);

/**
 * 获取当前日志文件路径
 */
const char* amclLogGetPath(void);

/**
 * 读取日志文件内容（最后 maxBytes 字节）
 *
 * 2026-07-30（活动账本 · L1-b）：**跨轮转读取**。此前只读当前
 * `amcl_launcher.log`，轮转出去的 `.1.log`~`.5.log` 共最多 10 MiB 就在磁盘上却一个
 * 字节都取不到 —— 于是「按时间窗回溯某条活动的日志」在稍早的记录上必然落空。
 * 现在按 .N → .1 → 当前 的时间顺序拼接，再从整体尾部取 maxBytes。
 */
const char* amclLogRead(int maxBytes);

// ==================== 活动账本（Activity Ledger · L1-a） ====================
//
// 目的：让每条活动（下载 / 模组安装 / 修复 / JDK / 整合包 / 一局游戏）都拥有一份
// **只属于它自己**的日志，而不是事后从全局日志里按时间窗去猜哪几行属于它。
//
// 为什么归属必须做在这一层：真机统计显示下载引擎 `DL_MULTI`、`JVM_LAUNCHER`、
// `MC_LAUNCHER` 这些**最有排障价值的 tag 全是 native 直接写的**，不经过 ArkTS 的
// AppLogger。在 ArkTS 侧做分流会把它们整体漏掉。而 `amclLogWrite` 是唯一漏斗。
//
// 归属方式分两侧（因为两侧并发模型不同）：
//   - native：真线程并发 → 线程本地归属（amclLogSetThreadActivity）
//   - ArkTS ：单 JS 线程 + async 交错 → 线程本地会串味，必须显式传 activityId
//             （见 amclLogWriteFor 与 ArkTS 侧的 ActivityLogger）
//
// 详见 docs/guides/activity-ledger.md §2.3。

/** 单个活动账本最多同时打开的数量（并发下载上限 3，留足余量）。 */
#define AMCL_LEDGER_MAX_SCOPES 8

/**
 * 打开一个活动账本 scope。此后归属于该 activityId 的日志行会**同时**写入
 * `<dir>/launcher/launcher-host.log` 或 `launcher-game.log`，普通日志完整追加。
 * 渲染域分到 render/renderer*.log，旧 launcher.tail* 仅保留读取兼容。
 *
 * 幂等：同一 activityId 重复调用只生效一次。
 *
 * @param activityId 活动主键（ArkTS 侧 = ActivityRecord.startedAt，毫秒）。0 无效。
 * @param dir        账本目录绝对路径（不存在会尝试创建）
 * @return 1 = 已打开（或此前已打开）；0 = 失败（槽位满 / 目录不可写）
 */
int amclLedgerBegin(long long activityId, const char* dir);

/**
 * 关闭活动账本 scope（flush + 关闭文件句柄）。
 * 关闭后该 activityId 的日志行不再写入账本，只进全局文件。
 */
void amclLedgerEnd(long long activityId);

/** 关闭全部 scope（进程退出 / fork 子进程用）。 */
void amclLedgerEndAll(void);

/**
 * 设置**当前线程**的日志归属活动。native worker 线程在进入某活动的工作时调用，
 * 退出时传 0 清除。
 *
 * 典型用法（下载引擎派发 worker）：
 *   amclLogSetThreadActivity(activityId);
 *   ... 该线程后续所有 AMCL_LOG_* 自动归属到这个活动 ...
 *   amclLogSetThreadActivity(0);
 */
void amclLogSetThreadActivity(long long activityId);

/** 取当前线程的日志归属活动；0 = 未归属。 */
long long amclLogGetThreadActivity(void);

/**
 * 显式指定归属活动写日志（不走线程本地）。
 * ArkTS 侧走这条 —— 单 JS 线程上多个活动 async 交错，线程本地必然串味。
 */
void amclLogWriteFor(long long activityId, AmclLogLevel level,
                     const char* tag, const char* fmt, ...);

// ---- 下载任务 → 活动 的关联表 ----
//
// 为什么需要它：下载引擎用的是**共享 worker 池** + 单事件循环线程
// （`engine.cpp` 的 workers_ / `multi_downloader.cpp` 的 loop_thread_），
// 同一个线程会先后处理不同任务的活儿。所以不能在线程启动时设一次归属，
// 必须在「取到某个任务的活儿时」设、「做完」清。
//
// 而引擎内部到处传的相关键是 `task_id`（uint64_t，由 engine 的 next_task_id_ 发号），
// 不是 activityId。于是在日志层维护一张小映射表：ArkTS 拿到 task_id 后调
// amclLedgerBindTask 建立关联，引擎侧只需按 task_id 查。

/** 关联下载任务与活动。activityId 传 0 等于解除关联。 */
void amclLedgerBindTask(unsigned long long taskId, long long activityId);

/** 解除关联（任务终态时调用，避免表被占满）。 */
void amclLedgerUnbindTask(unsigned long long taskId);

/** 查任务归属的活动；未关联返回 0。 */
long long amclLedgerActivityOfTask(unsigned long long taskId);

// ---- 游戏启动线程的归属 ----
//
// 游戏启动是「一次一个」的（同时只能跑一局 MC），所以不需要像下载那样的多任务映射表，
// 一个全局值就够。ArkTS 在调 native 启动之前设好，`mcLaunchThreadWithProfile` 在
// 线程入口用 AmclActivityScope 取出来 —— 这样 JVM_LAUNCHER / MC_LAUNCHER 那些
// native 日志（占真机启动器日志的 81%）就能落进该局自己的账本。
//
// 之所以不给启动函数加参数：mcLaunchWithProfile 系列有多个重载、参数已经很长，
// 加一个纯日志用途的参数会让签名进一步膨胀，也更容易漏改其中某个重载。

/** 设置后续游戏启动线程的日志归属活动（0 = 不归属）。 */
void amclLedgerSetLaunchActivity(long long activityId);

/** 取当前设定的游戏启动归属活动。 */
long long amclLedgerGetLaunchActivity(void);

#ifdef __cplusplus
} // extern "C"

/**
 * RAII 守卫：在作用域内把当前线程的日志归属切到 activityId，出作用域自动还原。
 *
 * 用在「共享线程池处理某个任务的活儿」这种场景（见 `engine.cpp` 的 workerLoop）：
 * 同一线程会先后服务不同活动，必须成对设置与还原，否则上一个任务的归属会泄漏到
 * 下一个任务 —— 那就等于又开始「掺别人的行」。
 *
 * 还原用的是**进入时的旧值**而不是写死 0，这样嵌套使用也安全。
 */
class AmclActivityScope {
public:
    explicit AmclActivityScope(long long activityId)
        : prev_(amclLogGetThreadActivity()) {
        amclLogSetThreadActivity(activityId);
    }
    ~AmclActivityScope() { amclLogSetThreadActivity(prev_); }
    AmclActivityScope(const AmclActivityScope&) = delete;
    AmclActivityScope& operator=(const AmclActivityScope&) = delete;
private:
    long long prev_;
};

extern "C" {
#endif

// ==================== 日志宏 ====================
// 同时写入 hilog（开发调试）+ 文件（用户可访问）

#define AMCL_LOG_D(tag, fmt, ...) do { \
    OH_LOG_DEBUG(LOG_APP, "[%{public}s] " fmt, tag, ##__VA_ARGS__); \
    amclLogWrite(AMCL_LOG_LEVEL_DEBUG, tag, fmt, ##__VA_ARGS__); \
} while(0)

#define AMCL_LOG_I(tag, fmt, ...) do { \
    OH_LOG_INFO(LOG_APP, "[%{public}s] " fmt, tag, ##__VA_ARGS__); \
    amclLogWrite(AMCL_LOG_LEVEL_INFO, tag, fmt, ##__VA_ARGS__); \
} while(0)

#define AMCL_LOG_W(tag, fmt, ...) do { \
    amclLogPrint(AMCL_LOG_LEVEL_WARN, LOG_DOMAIN, tag, fmt, ##__VA_ARGS__); \
} while(0)

#define AMCL_LOG_E(tag, fmt, ...) do { \
    amclLogPrint(AMCL_LOG_LEVEL_ERROR, LOG_DOMAIN, tag, fmt, ##__VA_ARGS__); \
} while(0)

#define AMCL_LOG_F(tag, fmt, ...) do { \
    amclLogPrint(AMCL_LOG_LEVEL_FATAL, LOG_DOMAIN, tag, fmt, ##__VA_ARGS__); \
} while(0)

#ifdef __cplusplus
}
#endif

#endif // AMCL_LOG_H

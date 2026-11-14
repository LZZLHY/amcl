/**
 * AMCL 平台音频宿主 C ABI。宿主先发布本局 owner，Java/OpenAL 仅取得其函数表。
 * 此协议是进程内生命周期边界，不是同进程不可信 native 代码的安全隔离机制。
 * 所有句柄均为本局递增编号，不能转换成指针；失败返回负的 AmclAudioResult。
 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__)
#define AMCL_AUDIO_EXPORT __attribute__((visibility("default")))
#else
#define AMCL_AUDIO_EXPORT
#endif
#ifdef __cplusplus
extern "C" {
#endif
enum AmclAudioResult {
    AMCL_AUDIO_OK = 0,
    AMCL_AUDIO_INVALID = -1,
    AMCL_AUDIO_PERMISSION = -2,
    AMCL_AUDIO_UNAVAILABLE = -3,
    AMCL_AUDIO_PLATFORM = -4,
    AMCL_AUDIO_LIMIT = -5
};
enum AmclAudioState {
    AMCL_AUDIO_OPEN = 1,
    AMCL_AUDIO_RUNNING = 2,
    AMCL_AUDIO_ACTIVE = 4,
    AMCL_AUDIO_FAILED = 8
};
enum AmclAudioEncoding { AMCL_AUDIO_S16LE = 1, AMCL_AUDIO_F32LE = 2 };
/** 必须是真实 token 权限的线程安全查询；仅在控制线程调用，不可捕获 napi_env/Java 对象。 */
typedef int (*AmclAudioRecordPermissionV1)(void *context);
typedef struct AmclAudioApiV1 {
    uint64_t magic;
    uint32_t abi;
    uint32_t size;
    uint32_t pid;
    uint32_t reserved;
    uint64_t session;
    int (*open)(int capture, int rate, int channels, int encoding, int bufferBytes, uint64_t *handle);
    int (*start)(uint64_t);
    int (*stop)(uint64_t);
    int (*flush)(uint64_t);
    int (*drain)(uint64_t);
    int (*close)(uint64_t);
    /** 数据长度/返回值均为字节；block=0 用于 OpenAL 已做可用量校验的读取。 */
    int (*read)(uint64_t, void *, int, int block);
    int (*write)(uint64_t, const void *, int);
    int (*available)(uint64_t);
    int (*bufferSize)(uint64_t);
    int (*state)(uint64_t);
    int (*frameBytes)(uint64_t);
    int64_t (*framePosition)(uint64_t);
    /** 非阻塞、幂等地请求补足转换尾帧；完成仍由framePosition对照已提交业务帧判断。 */
    int (*requestFinish)(uint64_t);
} AmclAudioApiV1;
#define AMCL_AUDIO_MAGIC UINT64_C(0x414d434c41554431)
#define AMCL_AUDIO_ABI 1u
#define AMCL_AUDIO_HOST_ENV "AMCL_AUDIO_HOST_V1"
/** NAPI进程初始化最早阶段调用：只发布稳定发现文本，不创建线程、不打开设备。 */
AMCL_AUDIO_EXPORT int amclAudioHostPublishEarlyV1(void);
/**
 * 首次 begin 启动独立控制线程；本 PID 不允许更换 session 重用已污染 JVM。
 * checkRecord=null 时播放可用，任何采集 open/start 都拒绝；系统 capturer 仍再次核权限。
 */
AMCL_AUDIO_EXPORT int amclAudioHostBeginV1(uint64_t session, AmclAudioRecordPermissionV1 checkRecord,
                                           void *context, int foreground);
/** 只接受当前 session；转后台会终止采集，不自动重新开麦。调用会等待控制线程完成。 */
AMCL_AUDIO_EXPORT int amclAudioHostSetForegroundV1(uint64_t session, int foreground);
/** 权限变化通知：重新查询真实权限并关闭不再合法的采集。每次 open/start 仍独立查询。 */
AMCL_AUDIO_EXPORT int amclAudioHostRefreshPermissionV1(uint64_t session);
/** 撤销后唤醒阻塞读写、关闭所有设备；之后 getter 返回 NULL。不得再 begin 当前 PID。 */
AMCL_AUDIO_EXPORT int amclAudioHostEndV1(uint64_t session);
AMCL_AUDIO_EXPORT const AmclAudioApiV1 *amclAudioHostGetV1(void);
#ifdef __cplusplus
}
#endif

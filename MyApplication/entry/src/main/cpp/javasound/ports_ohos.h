/*
 * OHOS JavaSound Ports 的设备快照与所有权接口。
 * 这里只映射系统实际返回的端口，不制造可写系统音量/静音控制。普通应用的公开 API
 * 不提供这些 setter；Renderer 的局部 gain 也不能代替硬件 Port 控制。
 * 同步查询只发生在枚举/打开/控制查询，不注册系统回调、不创建线程，不进入 PCM 热路径。
 */
#ifndef AMCL_PORTS_OHOS_H
#define AMCL_PORTS_OHOS_H
#include <stddef.h>
#include <stdint.h>

enum AmclPortsResult {
    AMCL_PORTS_OK = 0,
    AMCL_PORTS_NO_MEMORY = -1,
    AMCL_PORTS_PLATFORM_ERROR = -2,
    AMCL_PORTS_STALE = -3,
    AMCL_PORTS_INVALID = -4
};

/* 字符串是本接口分配的完整 UTF-8 副本；调用者必须用 amcl_ports_info_free 释放。
 * token 标识同一具体设备身份（id/role/type/name/address），不会因列表重排指向其他设备。 */
typedef struct AmclPortInfo {
    uint64_t token;
    uint32_t device_id;
    int role;
    int type;
    char *name;
    char *address;
} AmclPortInfo;

/* 刷新实际设备列表并返回一致的数量/代次；平台错误另写 native_error，不伪装成零设备。 */
int amcl_ports_refresh(size_t *count, uint64_t *generation, int *native_error);
uint64_t amcl_ports_generation(void);
/* 只读取明确代次中的一项；刷新竞争时返回 STALE，调用者不能拼接两个代次。 */
int amcl_ports_info_at(size_t index, uint64_t generation, AmclPortInfo *info);
void amcl_ports_info_free(AmclPortInfo *info);
/* 打开前重新确认具体 token 仍在；handle 是独立单调编号，关闭/重复关闭不解引用旧指针。 */
int amcl_ports_open(uint64_t token, uint64_t *handle, int *native_error);
int amcl_ports_close(uint64_t handle);
int amcl_ports_handle_info(uint64_t handle, AmclPortInfo *info);
int amcl_ports_check_present(uint64_t handle, int *native_error);
/* 仅宿主故障注入使用；生产构建不能从运行期环境或 JVM 属性切换供应者。 */
#ifdef AMCL_PORTS_TEST
void amcl_ports_test_reset(void);
size_t amcl_ports_test_handles(void);
uint64_t amcl_ports_test_handle_sequence(void);
#endif
#endif

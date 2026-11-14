/* ProcessImpl默认机制的本地平台身份。只在父侧类初始化调用，不进入fork child。
 * 编译目标与真实uname必须同时匹配；不读取os.name、AMCL环境或可覆写Java属性。
 * 查询失败保留上游默认值；显式launchMechanism选择完全不经过该默认分支。
 */
#ifndef AMCL_PROCESS_PLATFORM_H
#define AMCL_PROCESS_PLATFORM_H
#include <string.h>
#include <sys/utsname.h>
#ifndef AMCL_PROCESS_UNAME
#define AMCL_PROCESS_UNAME uname
#endif
static inline int amcl_process_is_ohos(void) {
#ifdef __OHOS__
    struct utsname identity;
    if (AMCL_PROCESS_UNAME(&identity) != 0) return 0;
    return strcmp(identity.sysname, "HarmonyOS") == 0 ||
        strcmp(identity.sysname, "OpenHarmony") == 0 || strcmp(identity.sysname, "OHOS") == 0;
#else
    return 0;
#endif
}
#endif

#pragma once

// 语义测试会在冷启动的default诊断进程冻结图形provider和专用配置。该进程从测试
// 开始即只用于取证，不能继续建JVM或进入游戏；必须通过应用重启获得新进程状态。
// 守卫仅在TestHooks构建引用测试标记，正式产品编译为空且没有测试符号依赖。
#ifdef MC_OHOS_BUILD_TESTS
#include "../tests/tests.h"
#include "jdk_java_qualification.h"
#endif

namespace amcl::napi {
inline bool RejectGraphicsSemanticsJvmStart(napi_env env) {
#ifdef MC_OHOS_BUILD_TESTS
    // 共享资格在JS线程受理时即封住游戏/JVM入口；它不是可恢复到普通UI游戏的会话。
    if (JdkSharedQualificationRestartRequired()) {
        napi_throw_error(env, "JDK_SHARED_RESTART_REQUIRED",
            "本进程已受理共享JDK资格，请重新启动AMCL后再启动JVM或游戏。");
        return true;
    }
    if (graphicsSemanticsRestartRequired()) {
        napi_throw_error(env, "GRAPHICS_SEMANTICS_RESTART_REQUIRED",
            "本进程已运行图形语义测试，请重新启动 AMCL 后再启动 JVM 或游戏。");
        return true;
    }
#else
    (void)env;
#endif
    return false;
}
}

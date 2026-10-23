#pragma once

// 语义测试会在冷启动的default诊断进程冻结图形provider和专用配置。该进程从测试
// 开始即只用于取证，不能继续建JVM或进入游戏；必须通过应用重启获得新进程状态。
// 守卫仅在TestHooks构建引用测试标记，正式产品编译为空且没有测试符号依赖。
#ifdef MC_OHOS_BUILD_TESTS
#include "../tests/tests.h"
#endif

namespace amcl::napi {
inline bool RejectGraphicsSemanticsJvmStart(napi_env env) {
#ifdef MC_OHOS_BUILD_TESTS
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

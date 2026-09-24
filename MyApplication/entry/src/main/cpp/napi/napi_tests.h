/**
 * napi_tests.h — 验证测试 NAPI 注册
 *
 * 仅在 MC_OHOS_BUILD_TESTS=ON 时编译/注册。
 *
 * 暴露给 ArkTS 的方法（与重构前 napi_entry.cpp 字面量逐字节一致）：
 *   - runJitTests / runJvmTests / runGlfwTest / runGl4Test / runMgTest / runLwjglTest
 *   - runDownloadSha1IncrementalTests / runDownloadTextFetchTests
 *   - runDownloadSourceScoringTests / runDownloadErrorAndSourceLifecycleTests
 */
#pragma once

#ifdef MC_OHOS_BUILD_TESTS

#include <napi/native_api.h>

namespace amcl::napi {

void registerTestsNapi(napi_env env, napi_value exports);

} // namespace amcl::napi

#endif // MC_OHOS_BUILD_TESTS

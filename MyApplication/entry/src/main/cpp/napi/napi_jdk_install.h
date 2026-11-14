/** JDK 安装存储端口注册；不把候选代码加载进应用进程。 */
#pragma once
#include <napi/native_api.h>
namespace amcl::napi {
void RegisterJdkInstall(napi_env env, napi_value exports);
}

/** sideload完整HDC桥：异步启动/命令，store构建保留拒绝入口但不链接HDC核心。 */
#pragma once
#include <napi/native_api.h>
namespace amcl::napi { void registerSideloadUpdateNapi(napi_env env, napi_value exports); }

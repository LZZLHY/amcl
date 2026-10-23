/** 导出数据面NAPI注册。注册不建线程、不打开文件；具体job在SDK异步作业执行。 */
#pragma once
#include <napi/native_api.h>
namespace amcl::napi { void registerExportNapi(napi_env env, napi_value exports); }

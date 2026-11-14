/** 原生游戏对话框的薄NAPI装配；UI线程不等待Java调用者。 */
#pragma once
#include <napi/native_api.h>
namespace amcl::napi { void registerGameDialogNapi(napi_env env, napi_value exports); }

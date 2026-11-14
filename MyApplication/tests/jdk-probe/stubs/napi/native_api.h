// 仅供宿主验证 NAPI 资源所有权；正式 HAP 始终使用 SDK 真实声明。
#pragma once
#include "../../../export-pipeline/stubs/napi/native_api.h"
typedef struct napi_ref__* napi_ref;
// API10/11的真实SDK形状；仅供宿主控制生命周期，不能模拟成功的ArkTS/NCP执行。
typedef struct napi_threadsafe_function__* napi_threadsafe_function;
typedef void (*napi_finalize)(napi_env, void*, void*);
typedef void (*napi_threadsafe_function_call_js)(napi_env, napi_value, void*, void*);
typedef enum { napi_tsfn_nonblocking, napi_tsfn_blocking } napi_threadsafe_function_call_mode;
typedef enum { napi_tsfn_release, napi_tsfn_abort } napi_threadsafe_function_release_mode;
typedef enum { napi_undefined, napi_null, napi_boolean, napi_number, napi_string,
               napi_symbol, napi_object, napi_function, napi_external, napi_bigint } napi_valuetype;
extern "C" {
napi_status napi_typeof(napi_env, napi_value, napi_valuetype*);
napi_status napi_throw_type_error(napi_env, const char*, const char*);
napi_status napi_create_reference(napi_env, napi_value, uint32_t, napi_ref*);
napi_status napi_delete_reference(napi_env, napi_ref);
napi_status napi_get_reference_value(napi_env, napi_ref, napi_value*);
napi_status napi_create_threadsafe_function(napi_env,napi_value,napi_value,napi_value,size_t,size_t,void*,napi_finalize,void*,napi_threadsafe_function_call_js,napi_threadsafe_function*);
napi_status napi_acquire_threadsafe_function(napi_threadsafe_function);
napi_status napi_release_threadsafe_function(napi_threadsafe_function,napi_threadsafe_function_release_mode);
napi_status napi_call_threadsafe_function(napi_threadsafe_function,void*,napi_threadsafe_function_call_mode);
napi_status napi_unref_threadsafe_function(napi_env,napi_threadsafe_function);
napi_status napi_add_env_cleanup_hook(napi_env,void(*)(void*),void*);
napi_status napi_remove_env_cleanup_hook(napi_env,void(*)(void*),void*);
}

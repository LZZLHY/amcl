/**
 * 仅供无DevEco的Linux CI编译异步owner测试。声明逐项对照锁定SDK native_api.h /
 * js_native_api_types.h / node_api_types.h；本机可切真实SDK头交叉编译同一源。
 * CMake正式entry从不引用此目录，不能把宿主替身作为鸿蒙ABI/运行时验收。
 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#define NAPI_AUTO_LENGTH SIZE_MAX
typedef struct napi_env__* napi_env;
typedef struct napi_value__* napi_value;
typedef struct napi_callback_info__* napi_callback_info;
typedef struct napi_deferred__* napi_deferred;
typedef struct napi_async_work__* napi_async_work;
typedef struct napi_handle_scope__* napi_handle_scope;
typedef struct napi_async_cleanup_hook_handle__* napi_async_cleanup_hook_handle;
typedef enum {
    napi_ok, napi_invalid_arg, napi_object_expected, napi_string_expected, napi_name_expected,
    napi_function_expected, napi_number_expected, napi_boolean_expected, napi_array_expected,
    napi_generic_failure, napi_pending_exception, napi_cancelled
} napi_status;
typedef enum { napi_default = 0 } napi_property_attributes;
typedef napi_value (*napi_callback)(napi_env, napi_callback_info);
typedef void (*napi_async_execute_callback)(napi_env, void*);
typedef void (*napi_async_complete_callback)(napi_env, napi_status, void*);
typedef void (*napi_async_cleanup_hook)(napi_async_cleanup_hook_handle, void*);
typedef struct {
    const char* utf8name; napi_value name; napi_callback method, getter, setter; napi_value value;
    napi_property_attributes attributes; void* data;
} napi_property_descriptor;
#ifdef __cplusplus
extern "C" {
#endif
napi_status napi_get_cb_info(napi_env,napi_callback_info,size_t*,napi_value*,napi_value*,void**);
napi_status napi_create_object(napi_env,napi_value*);
napi_status napi_get_undefined(napi_env,napi_value*);
napi_status napi_get_null(napi_env,napi_value*);
napi_status napi_open_handle_scope(napi_env,napi_handle_scope*);
napi_status napi_close_handle_scope(napi_env,napi_handle_scope);
napi_status napi_create_double(napi_env,double,napi_value*);
napi_status napi_get_boolean(napi_env,bool,napi_value*);
napi_status napi_get_value_bool(napi_env,napi_value,bool*);
napi_status napi_get_value_double(napi_env,napi_value,double*);
napi_status napi_create_string_utf8(napi_env,const char*,size_t,napi_value*);
napi_status napi_get_value_string_utf8(napi_env,napi_value,char*,size_t,size_t*);
napi_status napi_set_named_property(napi_env,napi_value,const char*,napi_value);
napi_status napi_get_named_property(napi_env,napi_value,const char*,napi_value*);
napi_status napi_has_named_property(napi_env,napi_value,const char*,bool*);
napi_status napi_is_array(napi_env,napi_value,bool*);
napi_status napi_get_array_length(napi_env,napi_value,uint32_t*);
napi_status napi_get_element(napi_env,napi_value,uint32_t,napi_value*);
napi_status napi_coerce_to_object(napi_env,napi_value,napi_value*);
napi_status napi_call_function(napi_env,napi_value,napi_value,size_t,const napi_value*,napi_value*);
napi_status napi_is_exception_pending(napi_env,bool*);
napi_status napi_get_and_clear_last_exception(napi_env,napi_value*);
napi_status napi_throw_error(napi_env,const char*,const char*);
napi_status napi_create_error(napi_env,napi_value,napi_value,napi_value*);
napi_status napi_create_promise(napi_env,napi_deferred*,napi_value*);
napi_status napi_resolve_deferred(napi_env,napi_deferred,napi_value);
napi_status napi_reject_deferred(napi_env,napi_deferred,napi_value);
napi_status napi_create_async_work(napi_env,napi_value,napi_value,napi_async_execute_callback,napi_async_complete_callback,void*,napi_async_work*);
napi_status napi_queue_async_work(napi_env,napi_async_work);
napi_status napi_delete_async_work(napi_env,napi_async_work);
napi_status napi_define_properties(napi_env,napi_value,size_t,const napi_property_descriptor*);
napi_status napi_add_async_cleanup_hook(napi_env,napi_async_cleanup_hook,void*,napi_async_cleanup_hook_handle*);
napi_status napi_remove_async_cleanup_hook(napi_async_cleanup_hook_handle);
#ifdef __cplusplus
}
#endif

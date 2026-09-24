// xcomponent.h — XComponent 生命周期管理 + NAPI 注册
#ifndef MC_OHOS_XCOMPONENT_H
#define MC_OHOS_XCOMPONENT_H

#include <napi/native_api.h>

#ifdef __cplusplus
extern "C" {
#endif

void RegisterXComponent(napi_env env, napi_value exports);

#ifdef __cplusplus
}
#endif

#endif // MC_OHOS_XCOMPONENT_H

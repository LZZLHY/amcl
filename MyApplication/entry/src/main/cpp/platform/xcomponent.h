// xcomponent.h — XComponent 生命周期管理 + NAPI 注册
#ifndef MC_OHOS_XCOMPONENT_H
#define MC_OHOS_XCOMPONENT_H

#include <napi/native_api.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void RegisterXComponent(napi_env env, napi_value exports);
// 运行中的会话政策只排队，不从NAPI/UI线程操作NativeWindow生产者。
bool amclResolutionRequestPercent(double percent);
// 返回本线程临时JSON，调用方须立即复制；包含请求/配置/actual来源，不返回窗口地址。
const char* amclResolutionStatusJson(void);

#ifdef __cplusplus
}
#endif

#endif // MC_OHOS_XCOMPONENT_H

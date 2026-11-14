/** default/TestHooks专用：官方NCP或显式shared工具冷进程；单次JVM身份与实际执行模式分别记录。 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include <napi/native_api.h>
/**
 * ArkTS 参数：filesDir、仅含字母数字/-/_ 的 nonce、major("8"/"17"/"21"/"25")、(text:string)=>void。
 * 宿主先投放 filesDir/jdk-runtime-qualification/<nonce>/runtime.zip 和 archive-sha256.txt。
 * 默认完成回调等待真实NCP退出；shared-basic/shared-extended只等待工具VM正常关闭，
 * 不含进程退出证明。shared需要外部HDC有界监督，并且每轮必须是全新主进程。
 */
/** 共享资格受理即使失败也必须重启；普通UI入口复用此固定状态，不能清零来再建VM。 */
bool JdkSharedQualificationRestartRequired() noexcept;

napi_value RunJdkJavaQualificationNapi(napi_env env, napi_callback_info info);
#endif

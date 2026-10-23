// env_publication.h — libentry 在任何游戏/JVM 线程出现前完成的进程级环境发布（I27-05）。
//
// 职责边界：
//   - 登记会在运行期变化的环境名（渲染器重启标记，以及本局的 CallbackBridge / SDL 宿主
//     身份文本），之后只经 env_slot.h 原位改值。输入前台位与发布尺寸不走环境，只由窗口
//     宿主 broker/快照提供（SDL 0022、LWJGL2 重建后打包库里已没有这些环境名的读者）；
//   - 提前发布进程常量描述符（legacy/SDL 输入桥、后端输入通道、窗口宿主 owner/broker），
//     让 surface 回调与 glfwInit 里的同名发布退化为无副作用的一次性守卫；
//   - 在 JVM 创建事务被认领时封存登记表，把之后的越界登记变成可记录的错误。
// 线程约束：全部入口只在 UI/JS 线程调用（NAPI 模块初始化、同步的 mcLaunchWithProfileV2
// 与其中的 jvmInit）；fork 出的单线程子进程里调用封存也无害。
#pragma once

#include <string>

namespace amcl::ohos {

// NAPI 模块初始化的第一步调用；进程内只执行一次，后续调用无副作用。
// reason 只写进日志，便于区分是模块初始化还是启动时的后备调用触发了发布。
void PublishEarlyProcessEnvironment(const char* reason);

// 重启标记槽位的补登，取代旧的“每次启动 unsetenv”：值保持原样（干净进程为 "0"）。
// 返回 env_slot.h 的状态码；负值表示登记失败，调用方必须拒绝继续启动。
int EnsureRendererRestartSlot();

// launchWithProfileImpl 在进入 phase_initJvmWithClasspath 之前调用：补登本局只在游戏线程
// 原位填写的文本槽位（幂等，可在同一进程的多次启动尝试中重复调用）。sdlHostRuntime 只在
// SDL3 窗口路线为 true（其他路线必须保持该名字缺席：SDL 把缺席解释为 standalone，而空值会
// 被判为畸形）。返回 false 时 error 给出失败原因，调用方拒绝启动。
bool PrepareRuntimeEnvironmentSlots(bool sdlHostRuntime, std::string& error);

// jvmInit 认领 JVM 创建事务之后、JNI_CreateJavaVM 之前调用：封存登记表（不可撤销、幂等）。
// 放在认领点而不是 launchWithProfileImpl：认领前的可重试失败（JDK 缺失等）允许同一进程
// 换路线再启动，那时仍要能登记新路线的槽位；认领后进程再也不会创建第二个 JVM。
void SealProcessEnvironment(const char* reason);

}  // namespace amcl::ohos

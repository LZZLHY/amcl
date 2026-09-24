#ifndef AMCL_BACKEND_INPUT_BRIDGE_HOST_STUB_H
#define AMCL_BACKEND_INPUT_BRIDGE_HOST_STUB_H

#include "../../input/adapters/backend_input_bridge.h"

// 后端 pull ABI 的 host 替身。
//
// ⚠️ 它存在的直接原因是一次**真的链接失败**：`inputBridge_l2NextEvent` 2026-08-24 起会调
// `amclBackendInputNext`，而那个符号的实现 TU（backend_input_bridge.cpp）带 hilog + core
// 单例，进不了 host 构建 ⇒ 集成目标直接 LNK2019。可以只补一个恒返回 EMPTY 的空壳，但那样
// 就等于承认"typed 与 ring 的合并逻辑没有任何断言"，而那正是 f5dc4eb 里犯过的真错误
// （把两条通道写成二选一）。所以替身是**可编程**的，让集成测试能驱动真实的合并循环。

#ifdef __cplusplus
extern "C" {
#endif

void amclBackendInputHostStubReset(void);
// unavailable = 1 时 `amclBackendInputNext` 返回 UNAVAILABLE 而不是 EMPTY。这两个返回值
// 必须分开：宿主拿 UNAVAILABLE 表示 legacy 路由生效、物理边沿在 ring 里。
void amclBackendInputHostStubSetUnavailable(int unavailable);
void amclBackendInputHostStubPush(const AmclBackendInputEvent* event);
void amclBackendInputHostStubSetTextPacket(
    uint64_t packetId, const uint8_t* bytes, uint32_t byteCount);
unsigned long long amclBackendInputHostStubActiveCalls(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif

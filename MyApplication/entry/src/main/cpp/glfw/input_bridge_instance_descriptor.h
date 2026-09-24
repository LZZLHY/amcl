// input_bridge_instance_descriptor.h — legacy input bridge 的跨 image 实例描述符编解码
//
// ⭐ 存在理由（2026-09-03，回归 `2026-09-03_LEGACY_GLFW_ROUTE_INPUT_REGRESSION_INVESTIGATION.md`）：
//   `libglfw.so` 在进程里有**两份** —— 一份是 libentry 的 DT_NEEDED 依赖（XComponent 建在
//   它上面），一份被 MC 的 class loader namespace dlopen。而 legacy ring（`g_events[]`）与
//   它的全部消费状态都是 `input_bridge_ohos.c` 的 TU 静态 ⇒ **两份 image = 两条互不相干的
//   bridge**。生产者（libentry 的 touch_input）经 env 只能找到"发布者"那一份，而 GLFW3 /
//   LWJGL2 消费者是 DSO 内直调或 dlsym，落进的是 MC 那一份 ⇒ 它们 drain 的 ring 永远为空。
//
//   修复形状：**bridge 是进程单例，不是 image 单例。** 拥有 XComponent 的那份 image 把自己
//   的整张函数表地址经本描述符发布出去；任何其它 image 的 `inputBridge_*` 入口都转发给它。
//
// 本头只放**纯函数**的 env 编解码：它不依赖 pthread / hilog / atomic，因此能进 host 构建被
// 断言钉住（与 `lwjgl2_event_translate` / `physical_wheel_quantizer` 同一手法）。函数表本体
// 留在 `input_bridge_ohos.c`，那是实现细节。
//
// ⚠️ 解析失败的原因必须**分开**返回（AGENTS.md §二.9）：把"env 还没发布"和"env 格式坏了"
// 合并成一个值，到了真机就分不出"宿主还没起来，下一帧再来"与"两侧版本不一致，永远不会好"。

#ifndef AMCL_INPUT_BRIDGE_INSTANCE_DESCRIPTOR_H
#define AMCL_INPUT_BRIDGE_INSTANCE_DESCRIPTOR_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// env 通道。刻意与 v7 的 `OHOS_INPUT_BRIDGE` 分开：v7 的解析方是 libentry（生产侧，只拿
// 六个操作函数），本描述符的解析方是**另一份 libglfw 自己**（消费侧，拿整张表）。两者的
// 演进节奏不同，合并会让任一侧升版都强迫对侧同时改。
#define AMCL_LEGACY_BRIDGE_INSTANCE_ENV "AMCL_LEGACY_INPUT_BRIDGE_INSTANCE"
#define AMCL_LEGACY_BRIDGE_INSTANCE_MAGIC "AMCLLBIV"
#define AMCL_LEGACY_BRIDGE_INSTANCE_VERSION 1u
// "<MAGIC>:<ver>:<addr>" 的最坏长度：8 + 1 + 10 + 1 + 20 + 1。
#define AMCL_LEGACY_BRIDGE_INSTANCE_ENV_CAPACITY 64

typedef enum AmclLegacyBridgeDescriptorStatus {
    AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK = 0,
    // 宿主那份 image 还没发布。**可重试**，不得缓存成失败。
    AMCL_LEGACY_BRIDGE_DESCRIPTOR_ABSENT = 1,
    AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_MAGIC = 2,
    AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_VERSION = 3,
    AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED = 4,
    // 地址位为 0：发布方写坏了。fail closed，绝不能当成"就用自己那份"。
    AMCL_LEGACY_BRIDGE_DESCRIPTOR_NULL_ADDRESS = 5,
    AMCL_LEGACY_BRIDGE_DESCRIPTOR_BUFFER_TOO_SMALL = 6
} AmclLegacyBridgeDescriptorStatus;

static inline const char* amclLegacyBridgeMatchLiteral(const char* text,
                                                       const char* literal) {
    size_t index = 0u;
    while (literal[index] != '\0') {
        if (text[index] != literal[index]) return NULL;
        ++index;
    }
    return text + index;
}

// 十进制无符号解析。刻意不用 `sscanf`：这里要的是"多一个字符都算坏"的严格判据，而
// `%llu` 会静默接受尾随垃圾，把一个格式错误变成一个看起来合法的地址。
static inline const char* amclLegacyBridgeParseUnsigned(
        const char* text, unsigned long long* outValue) {
    const char* cursor = text;
    unsigned long long value = 0ULL;
    if (*cursor < '0' || *cursor > '9') return NULL;
    while (*cursor >= '0' && *cursor <= '9') {
        const unsigned long long digit = (unsigned long long)(*cursor - '0');
        // 溢出即格式错误：一个被截断的地址与一个正确的地址在类型上无法区分。
        if (value > (0xFFFFFFFFFFFFFFFFULL - digit) / 10ULL) return NULL;
        value = value * 10ULL + digit;
        ++cursor;
    }
    *outValue = value;
    return cursor;
}

static inline AmclLegacyBridgeDescriptorStatus
amclLegacyBridgeEncodeInstanceEnv(char* buffer, size_t capacity,
                                  unsigned long long instanceAddress) {
    if (buffer == NULL || capacity == 0u) {
        return AMCL_LEGACY_BRIDGE_DESCRIPTOR_BUFFER_TOO_SMALL;
    }
    if (instanceAddress == 0ULL) {
        buffer[0] = '\0';
        return AMCL_LEGACY_BRIDGE_DESCRIPTOR_NULL_ADDRESS;
    }
    const int written = snprintf(buffer, capacity, "%s:%u:%llu",
                                 AMCL_LEGACY_BRIDGE_INSTANCE_MAGIC,
                                 AMCL_LEGACY_BRIDGE_INSTANCE_VERSION,
                                 instanceAddress);
    if (written < 0 || (size_t)written >= capacity) {
        buffer[0] = '\0';
        return AMCL_LEGACY_BRIDGE_DESCRIPTOR_BUFFER_TOO_SMALL;
    }
    return AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK;
}

// `encoded` 允许为 NULL / 空串（= 宿主还没发布），返回 ABSENT。
// 成功时 `*outAddress` 一定非 0；失败时一定为 0 —— 调用方不需要在失败分支里再清一次。
static inline AmclLegacyBridgeDescriptorStatus
amclLegacyBridgeParseInstanceEnv(const char* encoded,
                                 unsigned long long* outAddress) {
    if (outAddress != NULL) *outAddress = 0ULL;
    if (encoded == NULL || encoded[0] == '\0') {
        return AMCL_LEGACY_BRIDGE_DESCRIPTOR_ABSENT;
    }
    const char* cursor =
        amclLegacyBridgeMatchLiteral(encoded, AMCL_LEGACY_BRIDGE_INSTANCE_MAGIC);
    if (cursor == NULL) return AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_MAGIC;
    if (*cursor != ':') return AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_MAGIC;
    ++cursor;

    unsigned long long version = 0ULL;
    cursor = amclLegacyBridgeParseUnsigned(cursor, &version);
    if (cursor == NULL) return AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED;
    if (version != (unsigned long long)AMCL_LEGACY_BRIDGE_INSTANCE_VERSION) {
        return AMCL_LEGACY_BRIDGE_DESCRIPTOR_BAD_VERSION;
    }
    if (*cursor != ':') return AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED;
    ++cursor;

    unsigned long long address = 0ULL;
    cursor = amclLegacyBridgeParseUnsigned(cursor, &address);
    if (cursor == NULL) return AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED;
    if (*cursor != '\0') return AMCL_LEGACY_BRIDGE_DESCRIPTOR_MALFORMED;
    if (address == 0ULL) return AMCL_LEGACY_BRIDGE_DESCRIPTOR_NULL_ADDRESS;

    if (outAddress != NULL) *outAddress = address;
    return AMCL_LEGACY_BRIDGE_DESCRIPTOR_OK;
}

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AMCL_INPUT_BRIDGE_INSTANCE_DESCRIPTOR_H

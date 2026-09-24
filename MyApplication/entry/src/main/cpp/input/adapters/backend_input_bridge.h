#ifndef AMCL_BACKEND_INPUT_BRIDGE_H
#define AMCL_BACKEND_INPUT_BRIDGE_H

#include <stdint.h>

// ============================================================================
// 非 GLFW 后端（LWJGL2 / SDL3）的 typed 事件拉取 ABI。
//
// ⭐ 与它取代的那条通道的区别，一句话：**这里的事件已经是那个后端自己的编码**，
// 消费者不再翻第二次。旧通道（`inputBridge_l2NextEvent` / `inputBridge_sdlNextEvent`）
// 送的是 GLFW 编码的 `{type,i1..i4}`，两个后端各自再做 GLFW→DirectInput / GLFW→SDL ——
// 那是计划 §一 约束 4 明令禁止的二次翻译，而且第一次翻译**有损**：五个 int 装不下
// timestamp / deviceId / sequence / repeat / 真实 scancode / 连续滚轮，恰好都是 SDL3 要的。
//
// ⚠️ **本头文件是给另一个 .so 用的**，必须自足：不 include 任何仓内其它头。动作常量在
// 这里重新定义一份，而它们与 core 的 `AMCL_INPUT_ACTION_*` 的一致性由实现侧的
// static_assert 钉住 —— 镜像常量必须有机械判据，否则它就是下一个"两处各说一套"。
//
// 生命周期与线程：
//   · `amclBackendInputNext` **自己驱动 adapter**（内部 Pump 一次再出队），所以是
//     消费者的事件循环在当泵。这与 adapter 的契约一致（Pump 不做后台工作、全部在调用
//     线程同步跑），也免掉一条常驻线程。首次调用惰性 Open。
//   · 每个后端一把锁、一条独立队列、一个独立 core 消费者。互不抢占。
//   · 溢出不静默丢：队列满时整条清空并投一条 RESET，与 legacy ring 同一条纪律 ——
//     消费者收到 RESET 必须释放它已注入的全部键与鼠标按钮。
// ============================================================================

// 本目标编译时带 -fvisibility=hidden，所以必须显式标默认可见性。
//
// ⚠️ env 通道取的是函数地址，**隐藏符号也能用** —— 所以这不是功能需要，是**可验证性**
// 需要：隐藏符号在产物里查不到，而"产物能自证这条通道在里面"是 `AMCL_GATE0_EVIDENCE_IDS`
// 那次付过学费的地方（那个宏只有编译期读者，于是字符串从未进过 .rodata，而三处注释都
// 宣称"产物可反查"）。导出之后 `llvm-readelf --dyn-syms` 能直接看到它。
#if defined(__GNUC__)
#  define AMCL_BACKEND_INPUT_PUBLIC __attribute__((visibility("default")))
#else
#  define AMCL_BACKEND_INPUT_PUBLIC
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define AMCL_BACKEND_INPUT_ABI_VERSION 1u

// 后端身份，与 core 的 `AMCL_INPUT_BACKEND_*` 同值（实现侧 static_assert 钉住）。
#define AMCL_BACKEND_INPUT_LWJGL2 2u
#define AMCL_BACKEND_INPUT_SDL3 3u

#define AMCL_BACKEND_INPUT_EVENT_KEY 1u
#define AMCL_BACKEND_INPUT_EVENT_BUTTON 2u
#define AMCL_BACKEND_INPUT_EVENT_WHEEL 3u
// 队列溢出 / 会话或 surface 边界 / 后端被退休。消费者必须释放全部已注入的持有态：
// 只清键盘会留下一个按住的鼠标键，在游戏里读作"玩家一直按着攻击"。
#define AMCL_BACKEND_INPUT_EVENT_RESET 4u
// Lifecycle records use the existing fixed 64-byte envelope.
// FOCUS: action is 0/1 (unfocused/focused).
#define AMCL_BACKEND_INPUT_EVENT_FOCUS 5u
// CAPTURE: code=requested(0/1), action=active(0/1), resetReason=reason.
#define AMCL_BACKEND_INPUT_EVENT_CAPTURE 6u
// POINTER_RELATIVE: wheelX/wheelY carry dx/dy, modifiers carries the
// AMCL_BACKEND_INPUT_RELATIVE_FLAG_* bitset. The names are frozen by the 64-byte
// ABI; eventType is the discriminator, so no wheel semantics apply here.
#define AMCL_BACKEND_INPUT_EVENT_RELATIVE 7u
#define AMCL_BACKEND_INPUT_EVENT_DEVICE 8u
#define AMCL_BACKEND_INPUT_EVENT_SURFACE_CONTEXT 9u
// Typed text keeps the 64-byte event envelope. Blob events carry a bridge-owned
// packet id in deviceId and byte length in code; consumers copy then release it
// with the functions below. This avoids expanding one commit into the bounded
// physical event queue.
#define AMCL_BACKEND_INPUT_EVENT_TEXT_SESSION 10u
#define AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT 11u
#define AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING 12u
#define AMCL_BACKEND_INPUT_EVENT_TEXT_CANDIDATES 13u
#define AMCL_BACKEND_INPUT_EVENT_TEXT_SELECTION 14u
#define AMCL_BACKEND_INPUT_RELATIVE_FLAG_HARDWARE_RAW (1u << 0)

// DEVICE: code=AMCL_BACKEND_INPUT_DEVICE_*, modifiers=capability bits,
// resetReason=deviceClass. Pointer BUTTON/WHEEL/RELATIVE also carry deviceClass
// in resetReason. This is event-type-specific reuse of an existing 32-bit slot;
// the V1 envelope remains exactly 64 bytes.
#define AMCL_BACKEND_INPUT_DEVICE_ADDED 1u
#define AMCL_BACKEND_INPUT_DEVICE_REMOVED 2u
#define AMCL_BACKEND_INPUT_DEVICE_CLASS_UNKNOWN 0u
#define AMCL_BACKEND_INPUT_DEVICE_CLASS_MOUSE 1u
#define AMCL_BACKEND_INPUT_DEVICE_CLASS_TOUCHPAD 2u

// SURFACE_CONTEXT event-specific slot reuse (the envelope remains 64 bytes):
//   code/rawCode             = windowId/displayId
//   action/modifiers         = leftPx/topPx bit patterns
//   lockState/resetReason    = widthPx/heightPx
//   wheelX/wheelY            = density/refreshRateHz
//   deviceId                 = context generation
//   monotonicTimeNs low/high = validFields/transform
//   sequence                 = core sequence
#define AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_WINDOW (1u << 0)
#define AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY (1u << 1)
#define AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_RECT (1u << 2)
#define AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_DENSITY (1u << 3)
#define AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM (1u << 4)
#define AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE (1u << 5)

// 与 core 的 AMCL_INPUT_ACTION_* 同值。
#define AMCL_BACKEND_INPUT_ACTION_DOWN 1u
#define AMCL_BACKEND_INPUT_ACTION_REPEAT 2u
#define AMCL_BACKEND_INPUT_ACTION_UP 3u

#define AMCL_BACKEND_INPUT_EMPTY 0
#define AMCL_BACKEND_INPUT_EVENT 1
#define AMCL_BACKEND_INPUT_ERROR_ARGUMENT (-1)
#define AMCL_BACKEND_INPUT_ERROR_ABI (-2)
// ⚠️ **`UNAVAILABLE` 与 NOT_READY 必须分开，因为消费者的正确处置相反。**
//   · `UNAVAILABLE` = 本通道**结构上不适用**（宿主在 legacy 路由上，物理边沿在 ring 里）。
//     路由位是启动期闭锁的 ⇒ 重试永远不会改变结果 ⇒ 消费者应**永久闭锁**本通道。
//   · NOT_READY = 本通道适用但**还没就绪**（host table 尚未发布、core 会话还没建立）。
//     "MC 起得比 surface 早"是正常时序 ⇒ 消费者必须**下一帧再来**，不得闭锁。
// 把后者也报成 `UNAVAILABLE` 的后果是：消费者抢在宿主就绪前拉一次，就把一条本来会好的
// 通道永久关掉 ⇒ 那个后端**永久无物理输入**。这与 `EMPTY`/`UNAVAILABLE` 不能混是同一条，
// 只是错在"三种成因共用一个返回值"而不是两种。
#define AMCL_BACKEND_INPUT_ERROR_UNAVAILABLE (-3)
#define AMCL_BACKEND_INPUT_ERROR_NOT_READY (-4)
#define AMCL_BACKEND_INPUT_ERROR_BUFFER_TOO_SMALL (-5)
#define AMCL_BACKEND_INPUT_ERROR_NOT_FOUND (-6)
#define AMCL_BACKEND_INPUT_ERROR_MALFORMED (-7)

typedef struct AmclBackendInputEvent {
    uint16_t abiVersion;
    uint16_t structSize;
    uint32_t eventType;
    // 已经是后端编码：LWJGL2 是 DirectInput 扫描码，SDL3 是 SDL_Scancode / SDL_BUTTON_*。
    int32_t code;
    // 平台硬件扫描码（缺时退回 HID usage，再缺退回 raw identity）。SDL 当 rawcode 用。
    int32_t rawCode;
    uint32_t action;
    uint32_t modifiers;
    uint32_t lockState;
    // RESET/CAPTURE: reason. DEVICE and pointer records: deviceClass.
    uint32_t resetReason;
    // WHEEL 事件：滚轮格数（带符号连续值，GLFW yoffset 方向：向上为正）。**量纲与符号已在生产侧换好**
    // （平台样本是像素、正值 = 向下滚），消费者不得再取反或再乘系数。**刻意不分格**：
    // 一格是 GLFW/LWJGL2 的概念，SDL 的滚轮本来就是浮点，分格该由后端自己做。
    // 横轴恒为 0：本 SDK 没有经验证的横向 getter，生产侧整包 fail closed。
    // RELATIVE 事件：同两个槽改承载 dx/dy；eventType 已区分，消费者不得做滚轮换算。
    float wheelX;
    float wheelY;
    uint64_t deviceId;
    // core 盖的单调时间戳，原样透传。旧的五 int 通道装不下它，而 SDL 的事件需要。
    // **0 表示"没有平台时间戳"**（复位/设备移除时合成的 fail-safe 释放就是 0）——
    // SDL 把 0 读作"现在"，这正是想要的语义。
    // ⚠️ 2026-08-24 之前生产侧**一行都没写过**，字段恒 0 而这段声明照样这么写着。
    uint64_t monotonicTimeNs;
    uint64_t sequence;
} AmclBackendInputEvent;

// 取下一个事件。返回 `AMCL_BACKEND_INPUT_EVENT`=有、`AMCL_BACKEND_INPUT_EMPTY`=队列空、负值=错误。
// `out->abiVersion` / `out->structSize` 由本函数填写；调用方**不需要**预先填。
AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputNext(uint32_t backend,
                                                    AmclBackendInputEvent* out);

// 声明本后端开始/停止消费。`active=1` 时把读位置对齐到"此刻"并清掉挂起的溢出标记，
// 所以它**不重放** SDL/LWJGL2 尚未初始化时产生的历史输入 —— 与旧通道同一语义。
AMCL_BACKEND_INPUT_PUBLIC void amclBackendInputSetActive(uint32_t backend,
                                                         int active);

// Owned text packet access. `outBytes == NULL && capacity == 0` queries the
// exact byte count. The scalar variant applies strict UTF-8 decoding and is the
// zero-allocation hot seam used by LWJGL2. Both require an explicit release.
AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputReadText(
    uint32_t backend, uint64_t packetId, uint8_t* outBytes,
    uint32_t capacity, uint32_t* outByteCount);
AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputReadTextScalars(
    uint32_t backend, uint64_t packetId, uint32_t* outScalars,
    uint32_t capacity, uint32_t* outScalarCount);
AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputReleaseText(
    uint32_t backend, uint64_t packetId);

// 把上面两个函数的地址经环境变量发布出去。
//
// ⚠️ 为什么是 env 而不是让消费者 dlsym 我们：2026-08-04 真机实测，libSDL3 由 MC 的
// class loader namespace dlopen，而本库是宿主 libentry 的 DT_NEEDED 依赖 ——
// `dlsym(RTLD_DEFAULT, …)` 全 NULL、`dlopen("libglfw.so", RTLD_NOLOAD)` 也拿不到。
// env 是本项目**已验证**可跨 namespace 的通道（`AMCL_SDL_INPUT_BRIDGE` 同理）。
AMCL_BACKEND_INPUT_PUBLIC void amclBackendInputPublishAddress(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif

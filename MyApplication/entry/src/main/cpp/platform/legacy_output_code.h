// legacy_output_code.h — legacy ring 持续输出（键 / 鼠标按钮）的取值合同，唯一一份判据
//
// 职责：给 touch_input.cpp 的三个入口提供同一组纯判定：
//   · `schemaOutputCodeValid`（Control Schema 发布校验，沿用“正数=键、负数=鼠标”的符号编码）；
//   · `routerKey` / `routerMouse`（NAPI 按端入口，键与按钮分开传参，不再做符号编码）。
// 此前三处各写一套：schema 有范围、router 完全没有，负键码经符号编码变成鼠标左键、
// 负按钮变成键盘键，INT_MIN 取负还是有符号溢出（普查 I27，施工记录 §129 设计决定 9）。
//
// 取值（与 ArkTS `validOutputCode` 的 1..512 / -16..-1 逐值一致，改动必须两侧同改）：
//   · 键 1..512：512 是历史兼容值。legacy 轮询表 `g_keyDownBuffer` 只有 0..511，
//     所以 512 只能走回调、不可轮询；收紧到 GLFW 实际键域需要持久化布局迁移，本头不改。
//   · 鼠标按钮 0..15：与 bridge 的按钮轮询表 `g_mouseDownBuffer`（16 项）一致；
//     schema 符号编码里对应 -1..-16。
// 本头不含锁、不含日志，所有函数都是 constexpr/noexcept，可在任意线程与 host 测试里直接调用。
#ifndef AMCL_PLATFORM_LEGACY_OUTPUT_CODE_H
#define AMCL_PLATFORM_LEGACY_OUTPUT_CODE_H

#include "input_ledger.h"

namespace amcl::input {

constexpr int kLegacyKeyCodeMin = 1;
constexpr int kLegacyKeyCodeMax = 512;
constexpr int kLegacyMouseButtonMin = 0;
constexpr int kLegacyMouseButtonMax = 15;

// 键码是否落在 legacy 合同内。只做区间比较，不做任何算术，INT_MIN/INT_MAX 都安全。
constexpr bool LegacyKeyCodeValid(int key) noexcept {
    return key >= kLegacyKeyCodeMin && key <= kLegacyKeyCodeMax;
}

// 鼠标按钮号（GLFW 编号，0 = 左键）是否落在 legacy 合同内。
constexpr bool LegacyMouseButtonValid(int button) noexcept {
    return button >= kLegacyMouseButtonMin && button <= kLegacyMouseButtonMax;
}

// schema 符号编码：正数是键码，负数是 -(按钮号 + 1)。先用区间比较挡掉越界值，
// 只有已经确认落在 -16..-1 时才会做 `-code - 1` 的还原，因此 INT_MIN 不会被取负。
constexpr bool LegacySchemaOutputCodeValid(int code) noexcept {
    if (code > 0) return LegacyKeyCodeValid(code);
    return code <= -(kLegacyMouseButtonMin + 1) &&
           code >= -(kLegacyMouseButtonMax + 1);
}

// 把已通过上面判定的 schema 编码还原成 ledger 输出。越界时返回 false 且不写 out，
// 调用方据此直接拒绝，不分配 owner、不触碰任何账本。
inline bool DecodeLegacySchemaOutputCode(int code, Output* out) noexcept {
    if (!out || !LegacySchemaOutputCodeValid(code)) return false;
    *out = code > 0 ? Output{OutputKind::Key, code}
                    : Output{OutputKind::Mouse, -code - 1};
    return true;
}

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_LEGACY_OUTPUT_CODE_H

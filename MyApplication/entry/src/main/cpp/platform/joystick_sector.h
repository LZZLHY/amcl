// joystick_sector.h — 摇杆八向扇区判定（纯函数）
//
// ============================ 为什么要抽出来 ============================
//
// 同一套"归一化偏移 → WASD 八向"的判定在本项目里写了**三遍**：
//   1. native 触控端  `schemaJoystick`（platform/touch_input.cpp）
//   2. 手柄端         `GamepadManager.updateMoveKeys`（ArkTS）
//   3. 触控端 ArkTS 兼容路径（GameControls，菜单态 / schema 降级时生效）
//
// 三份的扇区表当前**逐字一致**（22.5° 起分八段），但没有任何机制保证它们不分叉：
// 谁改了其中一份，另外两份不会有任何编译或测试提示，表现为"同一个八向摇杆在三端手感
// 不同"，而那不会是设计决定，只会是一次漏改。
//
// 所以本文件承担两件事：
//   · native 侧的唯一实现（`schemaJoystick` 调用它）；
//   · 一张**跨语言共享的规格表** —— 主机测试与 ArkTS 单测各自按这张表断言，
//     任何一侧偏离都会有一个测试失败。规格表见 tests/host/joystick_sector_test.cpp
//     与 gamecontrol 的 JoystickSector.ets 顶部注释，两处必须同步。
//
// ⚠️ 本文件**不含**方向锁存（30ms 重按抑制）。锁存是有状态的、且三端策略本来就不同
// （手柄端至今没有），把它一起抽会把"消除重复"与"改变手感"混成一次变更。
// 锁存留在各自的调用点，本文件只回答"这个偏移属于哪个扇区"。
#ifndef AMCL_PLATFORM_JOYSTICK_SECTOR_H
#define AMCL_PLATFORM_JOYSTICK_SECTOR_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool w;
    bool a;
    bool s;
    bool d;
} AmclJoystickSector;

// 由**已归一化**的偏移量决定八向。
//
// 约定（与三份既有实现一致，改动即为行为变更）：
//   · `dx` 向右为正，`dy` **向下为正**（屏幕坐标系，不是数学坐标系）。
//     因此 dy<0 = 向上 = W。三份实现都依赖这一条，不要"顺手修正"成数学坐标系。
//   · `deadZone` 是长度阈值；`len < deadZone` 时四向全 false（松开）。
//     注意是严格小于：等于死区时视为已出死区，与既有实现一致。
//   · 非有限输入（NaN / Inf）一律返回全 false —— 宁可判成松开，也不要产生一个
//     方向永久按住的状态。
//   · 不做长度归一化：调用方负责把偏移压到 [0,1]（native 触控端按半径归一，
//     手柄端由死区重映射给出）。本函数只用长度与死区比较，不改变方向。
AmclJoystickSector amcl_joystick_sector(double dx, double dy, double deadZone);

#ifdef __cplusplus
}
#endif

#endif  // AMCL_PLATFORM_JOYSTICK_SECTOR_H

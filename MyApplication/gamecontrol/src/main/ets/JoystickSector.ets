/**
 * JoystickSector.ets — 摇杆八向扇区判定（纯函数）
 *
 * ============================ 为什么要抽出来 ============================
 *
 * 同一套"归一化偏移 → WASD 八向"的判定在本项目里写了**三遍**：
 *   1. native 触控端  `schemaJoystick`（cpp/platform/touch_input.cpp，现已改调
 *      cpp/platform/joystick_sector.cpp）
 *   2. 手柄端         `GamepadManager.updateMoveKeys`
 *   3. 触控端 ArkTS 兼容路径（`GameControls`，菜单态 / schema 降级时生效）
 *
 * 三份的扇区表当前**逐字一致**，但没有任何机制保证它们不分叉：谁改了其中一份，
 * 另外两份不会有任何编译或测试提示，表现为"同一个八向摇杆在三端手感不同" ——
 * 而那不会是设计决定，只会是一次漏改。
 *
 * ============================ 跨语言规格表 ============================
 *
 * 本文件与 `cpp/platform/joystick_sector.{h,cpp}` 是**同一份规格的两个实现**。
 * 下面这张表同时被 `entry/src/test/JoystickSector.test.ets` 与
 * `cpp/tests/host/joystick_sector_test.cpp` 断言，**两处的数值必须保持同步**：
 *
 *   角度区间（度，dy 向下为正）      方向
 *   [337.5, 360) ∪ [0, 22.5)        D
 *   [22.5, 67.5)                    D + S
 *   [67.5, 112.5)                   S
 *   [112.5, 157.5)                  A + S
 *   [157.5, 202.5)                  A
 *   [202.5, 247.5)                  A + W
 *   [247.5, 292.5)                  W
 *   [292.5, 337.5)                  D + W
 *
 * 约定（改动即为行为变更）：
 *   · `dx` 向右为正，`dy` **向下为正**（屏幕坐标系，不是数学坐标系）。
 *     因此 dy<0 = 向上 = W。三份实现都依赖这一条，不要"顺手修正"成数学坐标系。
 *   · `len < deadZone` 时四向全 false（松开）。严格小于：等于死区视为已出死区。
 *   · 长度为 0 一律松开 —— 否则 `atan2(0,0)` 返回 0，摇杆归中会被判成"向右"。
 *   · 非有限输入（NaN / Infinity）一律松开。让 NaN 决定方向的后果是某个方向键
 *     永久按住，在 MC 里表现为"角色自己一直走"，比丢一次输入严重得多。
 *
 * ⚠️ 本文件**不含**方向锁存（30ms 重按抑制）。锁存是有状态的，且三端策略本来就不同
 * （手柄端至今没有），把它一起抽会把"消除重复"与"改变手感"混成一次变更。
 * 锁存留在各自的调用点。
 */

/** 八向判定结果。四个 bool 而不是位掩码：调用点全都是逐键 apply，位掩码只会多一次解码。 */
export interface JoystickSectorResult {
  w: boolean
  a: boolean
  s: boolean
  d: boolean
}

const SECTOR_RELEASED: JoystickSectorResult = { w: false, a: false, s: false, d: false }

function released(): JoystickSectorResult {
  // 返回新对象而不是共享常量：调用方若就地修改共享对象会污染后续所有调用。
  return { w: false, a: false, s: false, d: false }
}

/**
 * 由**已归一化**的偏移量决定八向。契约见文件头。
 *
 * 不做长度归一化：调用方负责把偏移压到 [0,1]（触控端按半径归一，手柄端由死区重映射
 * 给出）。本函数只用长度与死区比较，不改变方向。
 */
export function joystickSector(dx: number, dy: number, deadZone: number): JoystickSectorResult {
  if (!Number.isFinite(dx) || !Number.isFinite(dy) || !Number.isFinite(deadZone)) {
    return released()
  }
  const len = Math.sqrt(dx * dx + dy * dy)
  if (len < deadZone) return released()
  if (len === 0) return released()

  let deg = Math.atan2(dy, dx) * 180 / Math.PI
  if (deg < 0) deg += 360

  let w = false
  let a = false
  let s = false
  let d = false
  if (deg >= 337.5 || deg < 22.5) { d = true }
  else if (deg < 67.5) { d = true; s = true }
  else if (deg < 112.5) { s = true }
  else if (deg < 157.5) { a = true; s = true }
  else if (deg < 202.5) { a = true }
  else if (deg < 247.5) { a = true; w = true }
  else if (deg < 292.5) { w = true }
  else { d = true; w = true }
  return { w: w, a: a, s: s, d: d }
}

/** 供调用方判断"是否处于松开态"，避免各处重复写四个 `!`。 */
export function joystickSectorIsReleased(r: JoystickSectorResult): boolean {
  return !r.w && !r.a && !r.s && !r.d
}

export { SECTOR_RELEASED }

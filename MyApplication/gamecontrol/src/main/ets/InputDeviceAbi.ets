/**
 * InputDeviceAbi.ets — 物理设备能力位的 ArkTS 镜像 + sources → 能力位纯映射
 *
 * 唯一真相在 entry/src/main/cpp/input/amcl_input_event.h 的
 * AMCL_INPUT_DEVICE_CAP_*。两处必须同时修改；新增能力位只能追加，并同步加入
 * native 侧的 AMCL_INPUT_DEVICE_CAP_MASK，否则 ingress 会把它当未知位丢掉。
 *
 * 为什么需要这层映射（重构计划 §5.2 DeviceRegistry / §10.1 拔设备）：
 *   native core 用 (deviceId, control) 作为 held owner 的键，DEVICE_REMOVED 是唯一
 *   "只释放该设备 owner" 的机制。要让它生效，ArkTS 必须把 inputDevice 的插拔事件
 *   转成带 deviceId 与能力位的中立事件；能力位本身只是给后端的 advisory 信息。
 *
 * 关键边界：**绝不能只凭 sources 宣称能力**。POINTER_RELATIVE 与 CAPTURE 不由
 * `'mouse'` 这个设备类别自动推导；调用方必须把已经解析出的产品/平台能力作为显式参数传入。
 * desktop API22+ 可声明 relative/capture，API26+ 的“硬件 raw”则是更窄的后端能力，
 * 本 V1 位图没有单独 raw 位，不能把 POINTER_RELATIVE 读成 raw。见规范 §十、计划 §109。
 */

/** 键盘按键能力。= 1 << 0 */
export const AMCL_DEVICE_CAP_KEYBOARD: number = 1
/** 绝对坐标指针（菜单点击）。= 1 << 1 */
export const AMCL_DEVICE_CAP_POINTER_ABSOLUTE: number = 2
/** 相对/raw 指针。Gate 0 未证明，本文件不置位。= 1 << 2 */
export const AMCL_DEVICE_CAP_POINTER_RELATIVE: number = 4
/** 指针按键。= 1 << 3 */
export const AMCL_DEVICE_CAP_POINTER_BUTTONS: number = 8
/** 滚轮。= 1 << 4 */
export const AMCL_DEVICE_CAP_WHEEL: number = 16
/** 文本/IME。= 1 << 5 */
export const AMCL_DEVICE_CAP_TEXT: number = 32
/** hover。= 1 << 6 */
export const AMCL_DEVICE_CAP_HOVER: number = 64
/** pointer capture。Gate 0 未证明，本文件不置位。= 1 << 7 */
export const AMCL_DEVICE_CAP_CAPTURE: number = 128

/**
 * `AmclInputEventHeader.deviceClass` 的 ArkTS ABI 镜像。
 *
 * 该字段复用 V1 header 原 reserved1 槽，数值只能追加、不能改号。它与
 * `AmclInputSource` 正交：source 描述事件来源，DeviceClass 描述物理 pointer 是
 * Mouse 还是 Touchpad。0 必须一直表示 Unknown，供旧 producer/native XComponent
 * mouse callback（公开结构无 device/tool 字段）安全降级。
 */
export enum InputDeviceClass {
  Unknown = 0,
  Mouse = 1,
  Touchpad = 2,
}

// ArkUI SourceTool 的公开稳定编号（API 12+）。不要复用 TouchEvent 真机曾上报的
// OH_NativeXComponent 私有 tool 编号 7；那是另一套枚举，混用会把橡皮/画笔误分类。
const ARKUI_SOURCE_TOOL_MOUSE: number = 3
const ARKUI_SOURCE_TOOL_TOUCHPAD: number = 4

/** 只按事件自身的 SourceTool 分类；缺失/未知不猜。 */
export function pointerDeviceClassFromSourceTool(sourceTool: number): InputDeviceClass {
  if (sourceTool === ARKUI_SOURCE_TOOL_MOUSE) return InputDeviceClass.Mouse
  if (sourceTool === ARKUI_SOURCE_TOOL_TOUCHPAD) return InputDeviceClass.Touchpad
  return InputDeviceClass.Unknown
}

/**
 * 按 inputDevice inventory 的 sources 分类设备插拔事件。
 * 同时声明 mouse+touchpad 的复合设备保持 Unknown；单值枚举不能诚实表达复合类。
 */
export function pointerDeviceClassFromSources(sources: string[]): InputDeviceClass {
  let mouse: boolean = false
  let touchpad: boolean = false
  for (let i = 0; i < sources.length; i++) {
    if (sources[i] === 'mouse') mouse = true
    if (sources[i] === 'touchpad') touchpad = true
  }
  if (mouse === touchpad) return InputDeviceClass.Unknown
  return touchpad ? InputDeviceClass.Touchpad : InputDeviceClass.Mouse
}

/** 一次 inputDevice inventory 查询的两项原子结果。 */
export class InputDeviceDescriptor {
  capabilities: number = 0
  deviceClass: InputDeviceClass = InputDeviceClass.Unknown
}

/** 物理设备插拔的中立事件（透传 inputDevice.DeviceListener 的两个字段）。 */
export interface DeviceChangeEvent {
  /** true = 'add'，false = 'remove'。 */
  added: boolean
  /** 平台 deviceId。<=0 无效，native 会拒收并计 missing-identity。 */
  deviceId: number
}

/**
 * 把 `inputDevice.InputDeviceData.sources` 映射为 native 能力位。
 *
 * 边界：
 *   - 未识别的 source 名一律忽略（返回值里不留未知位），native 侧还会再做一次 MASK
 *     校验，两层都 fail-closed。
 *   - 'touchpad' 与 'mouse' 都按"绝对坐标 + 按键 + 滚轮"上报；RELATIVE / CAPTURE 只有
 *     对应显式参数为 true 时才置位，理由见文件头。
 *   - 'touchscreen' 只给绝对坐标：它不是实体键鼠，也没有物理按键。
 *   - 'joystick' / 'trackball' 目前不映射任何位。手柄走 GamepadManager 合成路径，
 *     不参与实体键鼠 core 的能力集；trackball 在目标设备上无证据。
 *   - 空数组或全部未识别 → 返回 0。0 是合法的"没有已知能力"，native 不会因此拒收
 *     ADDED/REMOVED（deviceId 才是 owner 域的关键）。
 */
export function deviceCapabilityBitsFromSources(
  sources: string[], allowRelative: boolean = false, allowCapture: boolean = false
): number {
  let bits = 0
  for (let i = 0; i < sources.length; i++) {
    const s = sources[i]
    if (s === 'keyboard') {
      bits |= AMCL_DEVICE_CAP_KEYBOARD
      bits |= AMCL_DEVICE_CAP_TEXT
    } else if (s === 'mouse' || s === 'touchpad') {
      bits |= AMCL_DEVICE_CAP_POINTER_ABSOLUTE
      bits |= AMCL_DEVICE_CAP_POINTER_BUTTONS
      bits |= AMCL_DEVICE_CAP_WHEEL
      bits |= AMCL_DEVICE_CAP_HOVER
      if (allowRelative) bits |= AMCL_DEVICE_CAP_POINTER_RELATIVE
      if (allowCapture) bits |= AMCL_DEVICE_CAP_CAPTURE
    } else if (s === 'touchscreen') {
      bits |= AMCL_DEVICE_CAP_POINTER_ABSOLUTE
    }
  }
  return bits
}

/**
 * 把平台报来的 deviceId 归一化成可作为 native `HeldId` 稳定分量的非负整数。
 *
 * 契约（改动前必读）：
 *   1. **`0` 是"身份不可用"的共享桶**，不是一个合法设备。调用方拿到 0 时必须**拒绝**
 *      做任何按设备的操作 —— 用 0 去做 REMOVED 会取消无关设备的 owner。
 *      native 侧把 0 记为 `MissingField::Device`。
 *   2. **小数被截断**：deviceId 是整数标识，浮点抖动不能产生两个 owner 域。
 *   3. **超出 `Number.MAX_SAFE_INTEGER` → 0**：NAPI 用 int64 读取，超安全整数范围的值
 *      在 ArkTS 侧已经不精确，宁可当未知也不要造出一个错的 owner 域。
 *
 * ⚠️ **已知局限**：平台真的把设备编号为 0 时本函数无法与"字段不可用"区分（ArkUI 没有
 * 第二个可区分字段），missing-device 计数因此有一个已知假阳性。详见计划 §68.1。
 *
 * ⚠️ **不要复制第二份实现**（5 个调用点跨三个方向；纯函数漂移没有门禁能抓）。
 */
export function normalizeDeviceId(raw: number | undefined): number {
  if (raw === undefined || !Number.isFinite(raw)) return 0
  const truncated: number = Math.trunc(raw)
  if (truncated <= 0 || truncated > Number.MAX_SAFE_INTEGER) return 0
  return truncated
}

/** ArkUI BaseEvent.timestamp（system-monotonic ns）的安全 NAPI 表示。 */
export function normalizeMonotonicTimestampNs(raw: number | undefined): number {
  if (raw === undefined || !Number.isFinite(raw)) return 0
  const truncated: number = Math.trunc(raw)
  if (truncated <= 0 || truncated > Number.MAX_SAFE_INTEGER) return 0
  return truncated
}

/**
 * PhysicalKeyEdge.ets — 物理键盘一次边沿的**纯判定**（提案 D1 / 计划 §66）
 *
 * ============================ 职责 ============================
 *
 * 把「这一次 ArkUI `KeyEvent` 该向两个输出平面各报什么动作」这件事从页面里摘出来，
 * 使它可以在本机 ArkTS 单测里穷举。刻意不依赖 ArkUI / NAPI / `inputDevice` ——
 * 平台对象仍由 `McGamePage` 持有，本文件只做判定（与
 * `InputDeviceLifecycleCoordinator.ets` 同一种分工）。
 *
 * ============================ 为什么这一块值得单独钉住 ============================
 *
 * 它是**链路⑤「shift+左键取整组」的真实安全边界**，而这一点很反直觉：
 * ArkTS 算出的 `mods` 到不了 MC（GLFW 自己从 `win->keys[]` 现算，规范 §九 A 级）。
 * 让修饰键成立的是**Shift 的首个 DOWN 确实以 PRESS 抵达 native 并置了 `win->keys[]`**。
 * 所以一旦 repeat 分类出错、把首个 DOWN 判成 REPEAT，core 不会新增 owner ⇒
 * **修饰键静默失效**（不报错、不卡键，只是 shift+左键不再取整组）。
 * 改错 `mods` 只影响诊断，改错这里改的是功能。
 *
 * 这层判定此前内联在 `handleKeyEvent` 里、无任何断言。
 */

import { GLFW_PRESS, GLFW_RELEASE, GLFW_REPEAT } from './GlfwKeys'
import { HeldKeyDownKind } from './PhysicalHeldKeyTracker'

/**
 * typed core 的动作码。`AMCL_INPUT_ACTION_*` 镜像（`cpp/input/amcl_input_event.h`）。
 *
 * ⚠️ 这三个值作为 `physicalKeyTransaction` 的 shadowAction 参数直接过界，改一边不改
 * 另一边会**静默错标**（DOWN 被当 REPEAT ⇒ core 不新增 owner ⇒ 该键静默失效），
 * 不是编译错误。规范 §4.0：凡是镜像，必须声明自己是镜像。
 */
export const SHADOW_KEY_DOWN: number = 1
export const SHADOW_KEY_REPEAT: number = 2
export const SHADOW_KEY_UP: number = 3

/** 「这次边沿不该上报」的哨兵。两个平面共用，取值刻意不与任何合法动作码重叠。 */
export const PHYSICAL_KEY_EDGE_NONE: number = 0

/** 一次物理键边沿要向两个输出平面上报的动作。 */
export interface PhysicalKeyEdgeActions {
  /** typed core 平面（`SHADOW_KEY_*`）。`PHYSICAL_KEY_EDGE_NONE` = 不上报。 */
  shadowAction: number
  /** legacy GLFW 平面（`GLFW_PRESS` / `GLFW_REPEAT` / `GLFW_RELEASE`）。-1 = 不上报。 */
  glfwAction: number
  /** 两个平面是否都要上报。false 时调用方必须整条早退，不得只发一个平面。 */
  shouldPublish: boolean
}

/**
 * 判定一次边沿的两个动作码。
 *
 * 契约（改动前必读）：
 *   1. **两个平面必须同分类**。同一次边沿在 typed 上是 REPEAT 而在 legacy 上是 PRESS，
 *      会让 legacy edge router 多拿一个 owner，而 typed 不会 —— 两侧 owner 数从此永久
 *      不等，且不变量自检抓不到（各自都自洽）。所以 `isRepeat` 只算一次、喂给两边。
 *   2. **既非 Down 也非 Up 时不得上报**（平台还有 Unknown 等取值）。返回
 *      `shouldPublish=false`，调用方整条早退。
 *   3. `FirstDownAfterStale` **必须与 `FirstDown` 同样处理**（都是 PRESS/DOWN）：
 *      它表示"缓存里的按住已陈旧，中间那个 Up 丢了"，正是要让 native 重新 acquire owner。
 *      当成 REPEAT 会让该键永久发 REPEAT 而 native 那边已无 owner ⇒ 边沿被整条丢弃，
 *      用户看到的就是"这个键失灵了"（ESC 快按后失效即此）。自愈的**记录**由调用方负责，
 *      本函数只管分类。
 */
export function decidePhysicalKeyEdge(
  isDown: boolean, isUp: boolean, downKind: HeldKeyDownKind | undefined
): PhysicalKeyEdgeActions {
  if (isDown) {
    const isRepeat: boolean = downKind === HeldKeyDownKind.Repeat
    return {
      shadowAction: isRepeat ? SHADOW_KEY_REPEAT : SHADOW_KEY_DOWN,
      glfwAction: isRepeat ? GLFW_REPEAT : GLFW_PRESS,
      shouldPublish: true,
    }
  }
  if (isUp) {
    return {
      shadowAction: SHADOW_KEY_UP,
      glfwAction: GLFW_RELEASE,
      shouldPublish: true,
    }
  }
  return {
    shadowAction: PHYSICAL_KEY_EDGE_NONE,
    glfwAction: -1,
    shouldPublish: false,
  }
}

/**
 * 这一次物理按键边沿是否该由应用**自行回灌 char**（菜单 / 命令打字）。
 *
 * 四项**全部**必须成立，每一项都有独立理由：
 *   · `isDown` —— char 是按下语义，抬起不产字；
 *   · `isPrintableKey` —— 功能键没有码位；
 *   · `!isGrabbed` —— grabbed 是游戏态，MC 自己按 keycode 处理，回灌 char 会多出字符；
 *   · `!imeActive` —— 输入法**已经**消费过可打印键，再回灌就是双发（聊天框每个字打两遍）。
 *
 * ⚠️ **两个失效方向的代价不对称**（与 `ImeActivationGate` 的契约第 4 条同一件事）：
 * 错为 `false` = 字符双发；错为 `true` = **物理键盘打不出可打印字符**，更严重。
 * 所以 `imeActive` 的判据必须按 owner 记账（那是 `ImeActivationGate` 的职责），
 * 而本谓词只做合取 —— 不要在这里补任何"猜一下"的兜底。
 *
 * 本函数只回答"该不该发"，**不回答"发什么码位"**：码位由 `ohosKeyToCodepoint` 给出，
 * 且调用方仍须过滤 `cp <= 0`（未映射的可打印键）。两件事刻意分开，因为前者是策略、
 * 后者是查表。
 */
export function shouldRefillChar(
  isDown: boolean, isPrintableKey: boolean, isGrabbed: boolean, imeActive: boolean
): boolean {
  return isDown && isPrintableKey && !isGrabbed && !imeActive
}

/**
 * 物理 ESC 之后的一次 `onBackPress` 是否该被抑制。
 *
 * 背景：OHOS NEXT 上某些设备的物理键盘 ESC 会**同时**触发 `onKeyEvent` 与 `onBackPress`，
 * 于是 MC 收到两次 ESC（菜单刚弹出又被关掉）。
 *
 * 契约：`hasKeyboard` 是**必需**的判据，不能只看时间窗。纯触摸设备没有物理 ESC，
 * 无条件抑制会误吞真实的返回手势（那是用户唯一的退出手段）。
 * 时间窗上界由调用方给出，保持"文档与代码同一个常量"。
 *
 * ⚠️ **已知边界，刻意不改**：`msSinceEscDown` 为负时（`Date.now()` 被回拨）本函数返回
 * 抑制。这与抽出前的行为逐位相同 —— 抽 TU 不改语义。后果是那一小段时间内的返回手势
 * 被吞（用户再按一次即可），比反方向（双发 ESC ⇒ 菜单刚弹出又关掉）轻。真要改，
 * 应作为独立一轮并说明理由，不要顺手塞进抽取步。
 *
 * @param hasKeyboard    当前是否确有物理键盘接入
 * @param msSinceEscDown 距上一次物理 ESC 按下的毫秒数
 * @param debounceMs     去抖窗口
 */
export function shouldSuppressBackPressAfterEsc(
  hasKeyboard: boolean, msSinceEscDown: number, debounceMs: number
): boolean {
  if (!hasKeyboard) return false
  return msSinceEscDown < debounceMs
}

/**
 * ImeActivationGate.ets — 输入法激活闸门
 *
 * **职责**：回答"物理键盘现在该不该自行回灌 char"。有 IME 时输入法已经消费过可打印键，
 * 再回灌就是双发（MC 聊天框里每个字打两遍）；无 IME 时那条回灌是必要兜底（US 布局）。
 * 写者是 `ChatInputBridge`（显示/隐藏时 set），读者是 `McGamePage.handleKeyEvent`。
 *
 * **契约（改动前必读，完整论证见 `输入架构规范.md` §4.3）**：
 *   1. **必须按 owner 记账，不能是裸布尔。** 有两个独立写者（`GameControls.build()` 同时挂
 *      `mode='chat'` 与 `mode='field'` 两个 `ChatInputBridge`），裸布尔是"最后一个写者赢"
 *      → 关掉聊天条会抹掉仍开着的 field 条的声明 → 字符双发。且 ArkUI **未承诺**两个组件的
 *      `@Watch` 按赋值先后触发，所以"先关旧的再开新的"在裸布尔上不可靠；owner 集合的最终
 *      状态与触发顺序无关。
 *   2. **不同写者必须用不同的 owner 值**，否则退化成裸布尔，本类白建。
 *   3. **调用方仍须保证互斥。** `inputMethod.getController()` 是**进程级**实例，后 attach 的
 *      那条会 `off()`+`on()` 静默夺走前一条的全部回调。"两个输入条同时开"从不是合法状态。
 *   4. **失效方向刻意偏向"打不出字"的反面**：错为 false = 双发；错为 true = 物理键盘打不出
 *      可打印字符（更严重）。owner 记账天然保持 true，所以 `clear()` 是必需的恢复路径。
 *
 * **归属**：逻辑上属于物理键鼠端（是那一端的字符回灌开关）。提案 D1 把该端抽成专属类之后
 * 应搬进去，本文件届时可删。
 *
 * ⚠️ 墓碑: `InputModeManager` 已删除（`activeMode` 被删后名不副实、且捆着四件不相关的事，
 * 拆成三个模块，本文件是其中一个），详见提案 D2 与计划 §50。
 */

class ImeActivationGate {
  /** 声称"IME 已激活"的 owner 集合。owner 是稳定字符串（`ChatInputBridge` 用它的 `mode`）。 */
  private owners: Set<string> = new Set<string>()

  /** IME 出现/消失时调用。幂等。`owner` 的取值要求见文件头契约 2。 */
  setActive(owner: string, active: boolean): void {
    if (active) {
      this.owners.add(owner)
    } else {
      this.owners.delete(owner)
    }
  }

  /** 为 true 时物理键盘**不得**再自行回灌 char。 */
  isActive(): boolean {
    return this.owners.size > 0
  }

  /**
   * 无条件清空。唯一调用方是"确定所有输入条都已关闭"的复位边界
   * （`GameControls.resetTransientInputState` 的 `!keepHeldButtons` 分支）。
   *
   * 它让"某个 owner 泄漏 → 物理键盘永久打不出字"可恢复 —— 见文件头契约 4。
   * ⚠️ **必须留在那个分支内**：grab 翻转时输入条刻意保持打开。
   */
  clear(): void {
    this.owners.clear()
  }
}

let gate: ImeActivationGate | undefined = undefined

/** 进程内单例。HAR 作用域约束见 `输入架构规范.md` §4.1。 */
export function getImeActivationGate(): ImeActivationGate {
  if (!gate) gate = new ImeActivationGate()
  return gate
}

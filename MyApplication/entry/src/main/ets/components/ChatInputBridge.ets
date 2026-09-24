/**
 * ChatInputBridge.ets — 系统输入法 → MC 字符流桥接（2026-06 重构 · 鸿蒙原生 inputMethod API）
 *
 * ── 为什么用 @ohos.inputMethod 而不是 TextInput ─────────────────────────────────
 * 之前用隐藏 TextInput + defaultFocus 拉键盘：不可见控件拿不到焦点、唤不起输入法；
 * 受控 text 绑定又和中文候选互斗；空框退格还不触发 onChange（删不掉）。
 *
 * 改用鸿蒙**自绘控件输入法框架**（InputMethodController）：
 *   · attach(true, textConfig)        → 绑定 + 显式弹出软键盘（可靠唤起）。
 *   · on('insertText', text)          → IME 提交文本（中文在候选确认后才来，不会把拼音发给 MC）。
 *   · on('deleteLeft', length)        → 退格：无论编辑区是否为空都会触发（彻底解决删不掉）。
 *   · on('sendFunctionKey', key)      → 回车/发送键。
 *   · on('getLeftTextOfCursor' 等)    → 部分输入法需要查询光标周边文本，返回本地 echo 兜底。
 *   · detach() / hideSoftKeyboard()   → 收起。
 * 我们不维护真实编辑框，只把 IME 的编辑动作转成 MC 的字符/按键事件，并在条上显示 echo。
 *
 * 触摸：整层接管不穿透（HitTestMode 默认 + 半透明 scrim），杜绝误触下层虚拟按键导致卡键。
 */

import { inputMethod } from '@kit.IMEKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { GLFW_KEY_ENTER, GLFW_KEY_BACKSPACE, GLFW_KEY_ESCAPE, GLFW_PRESS, GLFW_RELEASE } from 'gamecontrol';
import { getImeActivationGate } from 'gamecontrol';
import { AmclInputSource } from 'gamecontrol';
import {
  TEXT_INPUT_MAX_SCALARS,
  TextInputBeginResult,
  TextInputBeginStatus,
  TextInputSessionLease
} from 'gamecontrol';
import {
  addEntryTextSessionAvailabilityListener,
  endEntryTextInputSession,
  getEntryTextInputSession,
  removeEntryTextSessionAvailabilityListener
} from './EntryTextInputSession';

const TAG = 'ChatInputBridge';

@Component
export struct ChatInputBridge {
  @Prop @Watch('onVisibleChange') visible: boolean = false
  // 'chat' — 聊天（回车发 ENTER 提交、取消发 ESC）；'field' — MC GUI 文本框（提交/取消都不发 ENTER/ESC）。
  @Prop mode: string = 'chat'
  onClose: () => void = () => {}

  // 用户已输入的可见文本（echo）。光标恒在末尾。
  @State private echo: string = ''
  private preview: string = ''
  // 软键盘高度（vp）——用于把输入条抬到键盘上方，避免被遮挡。
  @State private kbHeightVp: number = 0
  private controller: inputMethod.InputMethodController = inputMethod.getController()
  private mounted: boolean = false
  private attached: boolean = false
  private attaching: boolean = false
  private detaching: boolean = false
  private attachGeneration: number = 0
  private win: window.Window | null = null
  private textLease: TextInputSessionLease | undefined = undefined
  private attachFailedForCurrentActivation: boolean = false
  private sessionRetryTimer: number = -1
  private sessionRetryAttempt: number = 0
  private windowListenerGeneration: number = 0
  private sessionAvailableCb: () => void = (): void => {
    if (this.mounted && this.visible && this.textLease === undefined &&
        !this.attachFailedForCurrentActivation) this.attachIme()
  }

  // 监听软键盘避让区变化 → 更新 kbHeightVp（仅关心 TYPE_KEYBOARD）。
  private avoidCb: (data: window.AvoidAreaOptions) => void = (data: window.AvoidAreaOptions) => {
    if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
      try {
        this.kbHeightVp = this.getUIContext().px2vp(data.area.bottomRect.height)
      } catch (e) { /* ignore */ }
    }
  }

  // 绑定的回调实例（off 时需传同一引用）
  private cbInsert: (text: string) => void = (text: string) => this.onInsert(text)
  private cbDeleteLeft: (length: number) => void = (length: number) => this.onDeleteLeft(length)
  private cbFunctionKey: (fk: inputMethod.FunctionKey) => void = (fk: inputMethod.FunctionKey) => this.onFunctionKey(fk)
  private cbGetLeft: (length: number) => string = (length: number) => this.leftTextOfCursor(length)
  private cbGetRight: (length: number) => string = (length: number) => ''
  private cbGetIndex: () => number = () => this.toCodePoints(this.echo).length
  private cbSetPreview: inputMethod.SetPreviewTextCallback =
    (text: string, range: inputMethod.Range) => { this.onSetPreview(text, range) }
  private cbFinishPreview: () => void = () => { this.onFinishPreview() }
  private cbSelectRange: (range: inputMethod.Range) => void =
    (range: inputMethod.Range) => { this.onSelectRange(range) }

  private onVisibleChange(): void {
    // owner 用 `mode`（'chat' / 'field'）—— 它就是区分这两个实例的东西。
    // ⚠️ 这里曾是 `setActive(this.visible)`（不带 owner），而本组件有**两个实例**
    // 共写同一个进程级布尔 → 最后一个写者赢 → 关掉聊天条会把仍开着的 field 条的
    // 声明一起抹掉 → 物理键盘字符双发。完整故障序列见 ImeActivationGate.ets 的头注释。
    if (this.visible) {
      this.attachFailedForCurrentActivation = false
      this.clearSessionRetry(true)
      this.attachIme()
    } else {
      this.clearSessionRetry(true)
      this.detachIme()
    }
  }

  private attachIme(): void {
    if (!this.mounted || this.attached || this.attaching || this.detaching) return
    if (this.attachFailedForCurrentActivation) return
    if (this.textLease === undefined) {
      const owner: string = `mobile-ime-${this.mode}`
      const begin: TextInputBeginResult = getEntryTextInputSession().tryBegin(owner)
      if (begin.lease === undefined) {
        if (begin.status === TextInputBeginStatus.HostRejected) {
          this.scheduleSessionRetry()
        } else if (begin.status === TextInputBeginStatus.InvalidOwner) {
          this.attachFailedForCurrentActivation = true
        }
        // `Busy` 刻意没有分支：它表示另一个 owner 正持有进程级租约，恢复靠
        // `sessionAvailableCb`（租约归还时广播），重试反而会空转。
        // ⚠️ 但这条早退此前**一条日志都没有** —— "没拿到租约"与"用户没点按钮"在真机上
        // 完全同形。2026-09-05 排查 IME 时正是先怀疑它、又只能靠别的日志才排除掉。
        hilog.warn(0x0, TAG,
          'IME text session not granted mode=%{public}s status=%{public}d',
          this.mode, begin.status as number)
        return
      }
      this.textLease = begin.lease
      this.clearSessionRetry(true)
    }
    const expectedGeneration: number = ++this.attachGeneration
    this.attaching = true
    this.echo = ''
    this.preview = ''
    const textConfig: inputMethod.TextConfig = {
      inputAttribute: {
        textInputType: inputMethod.TextInputType.TEXT,
        enterKeyType: this.mode === 'field' ? inputMethod.EnterKeyType.DONE : inputMethod.EnterKeyType.SEND,
      },
    }
    // showKeyboard=true → 绑定后直接弹出软键盘（这正是「唤起输入法」的原生入口）
    let attachPromise: Promise<void>
    try {
      attachPromise = this.controller.attach(true, textConfig)
    } catch (e) {
      this.handleAttachFailure((e as BusinessError).message)
      return
    }
    attachPromise.then(() => {
      this.attaching = false
      this.attached = true
      if (expectedGeneration !== this.attachGeneration || !this.visible) {
        this.detachIme()
        return
      }
      // ⭐ 回调注册必须在 attach **之后**（2026-09-05）。平台把顺序写在错误信息里：
      // "input method client detached. need to be attached first"。
      //
      // 此前它在 attach 之前，而 `1b6087d7` 又把这个异常从"记一笔然后继续"改成致命
      // （置失败标志 + 关会话 + return）⇒ `attach(true, …)` 从此**一次都没被执行过**，
      // 软键盘再也弹不出来。旧代码之所以没事，正是因为它**忽略**了这个异常。
      // 完整取证见 docs/reports/2026-09-05_IME_SOFT_KEYBOARD_NOT_SUMMONED_INVESTIGATION.md §七。
      if (!this.registerImeCallbacks()) {
        // 已绑定却注册不上：不能留着这个会话。`attached` 为真是 `canEmitIme()` 与
        // IME 闸门的前提，而那两者都假定回调在位。
        this.handleAttachFailure('post-attach callback registration failed')
        return
      }
      // attach 成功才抑制 McGamePage 的 char fallback；失败时物理键盘必须继续可输入。
      getImeActivationGate().setActive(this.mode, true)
      hilog.info(0x0, TAG, 'IME attached, mode=%{public}s', this.mode)
    }).catch((err: BusinessError) => {
      this.handleAttachFailure(err.message)
      hilog.error(0x0, TAG, 'IME attach failed: code=%{public}d msg=%{public}s', err.code, err.message)
    })
  }

  private handleAttachFailure(message: string): void {
    this.attaching = false
    this.attached = false
    this.attachFailedForCurrentActivation = true
    this.unregisterImeCallbacks()
    this.detaching = true
    let detachPromise: Promise<void>
    try {
      detachPromise = this.controller.detach()
    } catch (_) {
      this.finishFailedAttach()
      return
    }
    detachPromise.then(() => {
      this.finishFailedAttach()
    }).catch((_err: BusinessError) => {
      this.finishFailedAttach()
    })
    hilog.warn(0x0, TAG, 'IME attach cleanup started: %{public}s', message)
  }

  private finishFailedAttach(): void {
    this.detaching = false
    this.closeTextSession('attach-failed')
  }

  private scheduleSessionRetry(): void {
    if (this.sessionRetryTimer >= 0 || this.sessionRetryAttempt >= 5) {
      if (this.sessionRetryAttempt >= 5) this.attachFailedForCurrentActivation = true
      return
    }
    const delayMs: number = 50 * Math.pow(2, this.sessionRetryAttempt)
    this.sessionRetryAttempt++
    this.sessionRetryTimer = setTimeout((): void => {
      this.sessionRetryTimer = -1
      if (this.mounted && this.visible && !this.attachFailedForCurrentActivation) {
        this.attachIme()
      }
    }, delayMs) as number
  }

  private clearSessionRetry(resetAttempt: boolean): void {
    if (this.sessionRetryTimer >= 0) clearTimeout(this.sessionRetryTimer)
    this.sessionRetryTimer = -1
    if (resetAttempt) this.sessionRetryAttempt = 0
  }

  private detachIme(): void {
    this.attachGeneration++
    this.unregisterImeCallbacks()
    if (!this.attached || this.detaching) {
      if (!this.attaching) this.closeTextSession('detach-without-controller')
      return
    }
    this.detaching = true
    this.attached = false
    // 先收键盘再解绑
    let hidePromise: Promise<void>
    try {
      hidePromise = this.controller.hideTextInput()
    } catch (e) {
      hilog.warn(0x0, TAG, 'IME hide threw before detach: %{public}s', (e as BusinessError).message)
      this.detachController()
      return
    }
    hidePromise.catch((err: BusinessError) => {
      hilog.warn(0x0, TAG, 'IME hide failed before detach: %{public}s', err.message)
    }).then(() => {
      this.detachController()
    })
    this.echo = ''
    this.preview = ''
  }

  private detachController(): void {
    let detachPromise: Promise<void>
    try {
      detachPromise = this.controller.detach()
    } catch (e) {
      hilog.warn(0x0, TAG, 'IME detach threw: %{public}s', (e as BusinessError).message)
      this.finishDetach()
      return
    }
    detachPromise.then(() => {
      this.finishDetach()
    }).catch((err: BusinessError) => {
      hilog.warn(0x0, TAG, 'IME detach failed: %{public}s', err.message)
      this.finishDetach()
    })
  }

  /**
   * 注册 IME 回调。**只能在 attach 成功之后调用** —— 平台对预编辑/选区那几个
   * （`setPreviewText` / `finishTextPreview` / `selectByRange`）要求客户端已绑定。
   * 返回 false 表示注册失败，调用方必须收拾掉那个已绑定的会话。
   */
  private registerImeCallbacks(): boolean {
    try {
      // 先 off 再 on，避免快速开合时重复注册。
      // ⚠️ 必须带同一 callback 引用：`off(type)` 不带引用会清掉进程级 controller 上
      // 另一个 mode 实例的合法注册。
      this.controller.off('insertText', this.cbInsert)
      this.controller.off('deleteLeft', this.cbDeleteLeft)
      this.controller.off('sendFunctionKey', this.cbFunctionKey)
      this.controller.off('getLeftTextOfCursor', this.cbGetLeft)
      this.controller.off('getRightTextOfCursor', this.cbGetRight)
      this.controller.off('getTextIndexAtCursor', this.cbGetIndex)
      this.controller.off('setPreviewText', this.cbSetPreview)
      this.controller.off('finishTextPreview', this.cbFinishPreview)
      this.controller.off('selectByRange', this.cbSelectRange)
      this.controller.on('insertText', this.cbInsert)
      this.controller.on('deleteLeft', this.cbDeleteLeft)
      this.controller.on('sendFunctionKey', this.cbFunctionKey)
      this.controller.on('getLeftTextOfCursor', this.cbGetLeft)
      this.controller.on('getRightTextOfCursor', this.cbGetRight)
      this.controller.on('getTextIndexAtCursor', this.cbGetIndex)
      this.controller.on('setPreviewText', this.cbSetPreview)
      this.controller.on('finishTextPreview', this.cbFinishPreview)
      this.controller.on('selectByRange', this.cbSelectRange)
      return true
    } catch (e) {
      hilog.error(0x0, TAG,
        'register IME listeners failed after attach: %{public}s',
        (e as BusinessError)?.message ?? String(e))
      return false
    }
  }

  private unregisterImeCallbacks(): void {
    try {
      this.controller.off('insertText', this.cbInsert)
      this.controller.off('deleteLeft', this.cbDeleteLeft)
      this.controller.off('sendFunctionKey', this.cbFunctionKey)
      this.controller.off('getLeftTextOfCursor', this.cbGetLeft)
      this.controller.off('getRightTextOfCursor', this.cbGetRight)
      this.controller.off('getTextIndexAtCursor', this.cbGetIndex)
      this.controller.off('setPreviewText', this.cbSetPreview)
      this.controller.off('finishTextPreview', this.cbFinishPreview)
      this.controller.off('selectByRange', this.cbSelectRange)
    } catch (_) {}
  }

  /**
   * 重建 native 文本会话，保持 IME 绑定与闸门不动。
   *
   * ⚠️ 刻意**不走** `closeTextSession()`：那个会把 IME 闸门置 false，而我们此刻仍然
   * attached、仍然要抑制物理键盘的 char 回灌。这里只换会话号。
   */
  private renewTextSession(): boolean {
    const stale: TextInputSessionLease | undefined = this.textLease
    this.textLease = undefined
    if (stale !== undefined) {
      endEntryTextInputSession(stale, 'renew-after-native-reset')
    }
    const begin: TextInputBeginResult =
      getEntryTextInputSession().tryBegin(`mobile-ime-${this.mode}`)
    if (begin.lease === undefined) {
      hilog.warn(0x0, TAG,
        'AMCL_IMEINSERT renew failed mode=%{public}s status=%{public}d',
        this.mode, begin.status as number)
      return false
    }
    this.textLease = begin.lease
    hilog.info(0x0, TAG,
      'AMCL_IMEINSERT text session renewed mode=%{public}s generation=%{public}d',
      this.mode, begin.lease.generation)
    return true
  }

  private closeTextSession(reason: string): void {
    const lease: TextInputSessionLease | undefined = this.textLease
    this.textLease = undefined
    if (lease !== undefined) {
      endEntryTextInputSession(lease, reason)
    }
    getImeActivationGate().setActive(this.mode, false)
  }

  private finishDetach(): void {
    this.detaching = false
    this.closeTextSession('detach-complete')
    if (this.mounted && this.visible) this.attachIme()
  }

  aboutToAppear(): void {
    this.mounted = true
    this.windowListenerGeneration++
    addEntryTextSessionAvailabilityListener(this.sessionAvailableCb)
    if (this.visible) this.attachIme()
    // 注册软键盘避让监听，拿到键盘高度把输入条抬到键盘上方（默认内嵌游戏窗口即 EntryAbility 窗口）。
    try {
      const ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')
      if (ctx) {
        const expectedWindowGeneration: number = this.windowListenerGeneration
        window.getLastWindow(ctx).then((w: window.Window) => {
          if (!this.mounted || expectedWindowGeneration !== this.windowListenerGeneration) return
          this.win = w
          try { w.on('avoidAreaChange', this.avoidCb) } catch (e) { /* ignore */ }
          try {
            const a = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD)
            this.kbHeightVp = this.getUIContext().px2vp(a.bottomRect.height)
          } catch (e) { /* ignore */ }
        }).catch((err: BusinessError) => {
          hilog.warn(0x0, TAG, 'getLastWindow failed: %{public}s', err.message)
        })
      }
    } catch (e) { /* ignore */ }
  }

  aboutToDisappear(): void {
    this.mounted = false
    this.clearSessionRetry(true)
    this.windowListenerGeneration++
    removeEntryTextSessionAvailabilityListener(this.sessionAvailableCb)
    // 只释放**本实例**的声明。另一个实例（另一个 mode）若仍开着，闸门必须保持激活。
    this.detachIme()
    try { this.win?.off('avoidAreaChange', this.avoidCb) } catch (e) { /* ignore */ }
    this.win = null
  }

  build() {
    if (this.visible) {
      Stack() {
        // ① 全屏触摸接管层（不穿透到下层虚拟按键，杜绝卡键）。半透明暗色 scrim。
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#33000000')
          .onClick(() => { /* 点空白不做事；用显式按钮关闭 */ })

        // ② 底部输入条：只读 echo + 发送/取消（真正输入走系统软键盘）
        Column() {
          Row({ space: 8 }) {
            Text(this.echo.length > 0 ? this.echo :
              (this.mode === 'field' ? $r('app.string.chat_input_field_placeholder') :
                $r('app.string.chat_input_chat_placeholder')))
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .fontColor(this.echo.length > 0 ? '#FFFFFFFF' : '#88FFFFFF')
              .backgroundColor('#E61A1A1A')
              .borderRadius(22)
              .padding({ left: 14, right: 14 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
              .accessibilityRole(AccessibilityRoleType.BUTTON)
              .accessibilityText(this.mode === 'field' ?
                $r('app.string.chat_input_field_control') :
                $r('app.string.chat_input_chat_control'))
              .accessibilityDescription($r('app.string.chat_input_editor_hint'))
              // 点输入条 → 重新唤起软键盘（用户手动收起键盘后再点能弹回来）
              .onClick(() => { this.reshowKeyboard() })
            if (this.mode === 'chat') {
              Button($r('app.string.chat_input_send'))
                .fontSize(14).height(44).width(64).fontColor('#FFFFFF')
                .backgroundColor('#CC2E7D32').borderRadius(22)
                .onClick(() => { this.submit() })
            }
            Button('✕')
              .fontSize(16).height(44).width(44).fontColor('#FFFFFF')
              .backgroundColor('#CC553333').borderRadius(22)
              .accessibilityText($r('app.string.chat_input_close'))
              .onClick(() => { this.cancel() })
          }
          .width('94%')
          .padding({ left: 8, right: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: this.kbHeightVp > 0 ? this.kbHeightVp + 8 : 56 })
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 点输入条重新唤起软键盘：已绑定则直接 show；否则重新 attach。 */
  private reshowKeyboard(): void {
    if (this.attached) {
      let showPromise: Promise<void>
      try {
        showPromise = this.controller.showTextInput(inputMethod.RequestKeyboardReason.TOUCH)
      } catch (e) {
        hilog.warn(0x0, TAG, 'showSoftKeyboard threw, detach before retry: %{public}s',
          (e as BusinessError).message)
        this.detachIme()
        return
      }
      showPromise.catch((err: BusinessError) => {
        hilog.warn(0x0, TAG, 'showSoftKeyboard failed, detach before retry: %{public}s', err.message)
        this.detachIme()
      })
    } else {
      this.attachFailedForCurrentActivation = false
      this.clearSessionRetry(true)
      this.attachIme()
    }
  }

  /** IME 提交文本：逐 codepoint 发给 MC，并追加到 echo。 */
  private onInsert(text: string): void {
    // ⭐ 2026-09-05 探针。"chat 模式打不进字、field 模式可以"这条症状有三个互斥的宿主，
    // 而它们此前**在日志里完全同形**（整条 onInsert 零日志）：
    //   ① 本函数根本没被调用  ⇒ IME 没把文字交给我们（回调没在位 / 平台侧）
    //   ② canEmit=0          ⇒ 我们自己的状态机把它拦了
    //   ③ commit=0           ⇒ native 拒收（见 PlatformInputTextCommit 的 AMCL_TEXTCOMMIT）
    // 三者的修法完全不同，所以这条日志必须**先于**任何早退。
    const emit: boolean = this.canEmitIme()
    hilog.info(0x0, TAG,
      'AMCL_IMEINSERT mode=%{public}s len=%{public}d canEmit=%{public}d ' +
      'mounted=%{public}d visible=%{public}d attached=%{public}d ' +
      'detaching=%{public}d lease=%{public}d',
      this.mode, text ? text.length : 0, emit ? 1 : 0,
      this.mounted ? 1 : 0, this.visible ? 1 : 0, this.attached ? 1 : 0,
      this.detaching ? 1 : 0, this.textLease !== undefined ? 1 : 0)
    if (!emit || !text || text.length === 0) return
    // 个别输入法用 insertText('\n') 表示回车 → 当作提交
    if (text === '\n' || text === '\r\n') {
      this.submit()
      return
    }
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease === undefined) return
    if (!getEntryTextInputSession().commit(lease, text)) {
      // ⭐ 2026-09-05：native 的文本会话号被一次 core RESET 清零了，而我们这边还活着。
      //
      // 成因（真机确证）：游戏内开聊天必然让 MC ungrab ⇒ `PlatformInputCaptureRequested(false)`
      // ⇒ core 判定 capture 丢失并发 RESET ⇒ ingress 的 `RecordAndDrainLocked` 对**任何**
      // RESET 都执行 `g.textSessionId = 0`。于是 chat 的会话在它自己开启的那一刻被摧毁，
      // 而 field（菜单里 capture 本就不 active）不受影响 —— 这正是"游戏内打不进字、
      // 菜单可以"的全部成因。取证见
      // docs/reports/2026-09-05_IME_SOFT_KEYBOARD_NOT_SUMMONED_INVESTIGATION.md §九。
      //
      // ⚠️ 这里刻意做**通用自愈**而不是只针对 capture：重建对任何 RESET 成因都成立，
      // 包括将来新增的。让 native 不再因 capture 变化清文本会话是更根本的修法，
      // 但那要动"所有 RESET 一视同仁"这条既有契约，属独立决定。
      if (!this.renewTextSession() ) return
      const renewed: TextInputSessionLease | undefined = this.textLease
      if (renewed === undefined ||
          !getEntryTextInputSession().commit(renewed, text)) {
        hilog.warn(0x0, TAG,
          'AMCL_IMEINSERT commit rejected after renew mode=%{public}s',
          this.mode)
        return
      }
    }
    this.appendEcho(text)
    if (this.preview.length > 0) {
      getEntryTextInputSession().editing(lease, '', 0, 0)
    }
    this.preview = ''
  }

  private onSetPreview(text: string, range: inputMethod.Range): void {
    if (!this.canEmitIme()) return
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease === undefined) return
    const previewText: string = this.recentText(text)
    const caret: number = this.toCodePoints(previewText).length
    if (!getEntryTextInputSession().editing(
      lease, previewText, caret, 0)) return
    this.preview = previewText
    this.publishSelectionRange(lease, range)
  }

  private onFinishPreview(): void {
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease !== undefined && this.canEmitIme()) {
      getEntryTextInputSession().editing(lease, '', 0, 0)
    }
    this.preview = ''
  }

  private onSelectRange(range: inputMethod.Range): void {
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease === undefined || !this.canEmitIme()) return
    this.publishSelectionRange(lease, range)
  }

  private publishSelectionRange(
    lease: TextInputSessionLease,
    range: inputMethod.Range
  ): void {
    const start: number = this.scalarIndexAtUtf16(this.echo, range.start)
    const end: number = this.scalarIndexAtUtf16(this.echo, range.end)
    if (start < 0 || end < start) return
    getEntryTextInputSession().selection(lease, start, end - start)
  }

  /** 退格：向 MC 发 length 个 BACKSPACE，并从 echo 末尾删 length 个 codepoint。 */
  private onDeleteLeft(length: number): void {
    if (!this.canEmitIme() || !Number.isFinite(length) ||
        Math.trunc(length) !== length || length > TEXT_INPUT_MAX_SCALARS) return
    const count: number = Math.trunc(length)
    if (count <= 0) return
    for (let i = 0; i < count; i++) {
      this.sendKeyTap(GLFW_KEY_BACKSPACE)
    }
    const cps = this.toCodePoints(this.echo)
    const keep = Math.max(0, cps.length - count)
    let s = ''
    for (let i = 0; i < keep; i++) s += String.fromCodePoint(cps[i])
    this.echo = s
  }

  /** 功能键（回车/发送/完成）→ 提交。 */
  private onFunctionKey(_fk: inputMethod.FunctionKey): void {
    if (this.canEmitIme()) this.submit()
  }

  private canEmitIme(): boolean {
    return this.mounted && this.visible && this.attached && !this.detaching &&
      this.textLease !== undefined
  }

  /** 输入法查询光标左侧文本：返回 echo 末尾 length 个 codepoint（兜底兼容部分 IME）。 */
  private leftTextOfCursor(length: number): string {
    const cps = this.toCodePoints(this.echo)
    const safeLength: number = Number.isFinite(length) ? Math.max(0, Math.trunc(length)) : 0
    const start = Math.max(0, cps.length - safeLength)
    let s = ''
    for (let i = start; i < cps.length; i++) s += String.fromCodePoint(cps[i])
    return s
  }

  private toCodePoints(s: string): number[] {
    const out: number[] = []
    let i = 0
    while (i < s.length) {
      const cp = s.codePointAt(i) ?? 0
      out.push(cp)
      i += cp > 0xFFFF ? 2 : 1
    }
    return out
  }

  private scalarIndexAtUtf16(text: string, utf16Index: number): number {
    if (!Number.isFinite(utf16Index) || Math.trunc(utf16Index) !== utf16Index ||
        utf16Index < 0 || utf16Index > text.length) return -1
    let offset: number = 0
    let scalarIndex: number = 0
    while (offset < utf16Index) {
      const cp: number = text.codePointAt(offset) ?? 0
      const width: number = cp > 0xFFFF ? 2 : 1
      if (offset + width > utf16Index) return -1
      offset += width
      scalarIndex++
    }
    return scalarIndex
  }

  private recentText(text: string): string {
    const scalars: number[] = this.toCodePoints(text)
    const start: number = Math.max(0, scalars.length - TEXT_INPUT_MAX_SCALARS)
    let value: string = ''
    for (let i: number = start; i < scalars.length; i++) {
      value += String.fromCodePoint(scalars[i])
    }
    return value
  }

  private appendEcho(text: string): void {
    const scalars: number[] = this.toCodePoints(this.echo + text)
    const start: number = Math.max(0, scalars.length - TEXT_INPUT_MAX_SCALARS)
    let value: string = ''
    for (let i: number = start; i < scalars.length; i++) {
      value += String.fromCodePoint(scalars[i])
    }
    this.echo = value
  }

  /**
   * Enter / ESC 的瞬时 tap。申报**触控虚拟按键端**：这条路径由屏幕上的输入条驱动
   * （ime_chat 按钮 / field 输入框），是该端的一个控件，即使触发它的字符可能来自物理
   * 键盘的软键盘输入法。端身份说的是"哪个控件端产出了这条边沿"，不是"文字从哪来"。
   *
   * press 与 release 紧邻发出，所以持有记录不会跨帧存在；但仍必须申报同一个端，
   * 否则 RELEASE 会在 native 的按端配对里找不到自己的按下。
   */
  private sendKeyTap(glfwKey: number): void {
    const source = AmclInputSource.TouchControls as number
    testNapi.sendSourceKeyEvent(source, glfwKey, 0, GLFW_PRESS, 0)
    testNapi.sendSourceKeyEvent(source, glfwKey, 0, GLFW_RELEASE, 0)
  }

  /** 提交：chat 模式发 ENTER 提交聊天并关闭；field 模式仅收起（文本已实时同步进 EditBox）。 */
  private submit(): void {
    if (this.mode === 'chat') {
      this.sendKeyTap(GLFW_KEY_ENTER)
    }
    this.onClose()
  }

  /** 取消：chat 模式发 ESC 关聊天框；field 模式仅收起（不发 ESC，否则会关掉 MC GUI 屏）。 */
  private cancel(): void {
    if (this.mode === 'chat') {
      this.sendKeyTap(GLFW_KEY_ESCAPE)
    }
    this.onClose()
  }
}

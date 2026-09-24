/**
 * DesktopPhysicalTextInput.ets — formal desktop 的无软键盘 IME 客户端。
 *
 * Windows 桌面式体验不能只支持 US 键盘：未 grabbed 的 Minecraft 菜单/聊天框需要让
 * 系统 IME 完成组合，再把最终 commit 送进 GLFW char 回调。本组件只在 API26 formal
 * desktop 编译身份下由 ProductGameControlSurface 激活；showKeyboard=false，绝不弹
 * 移动软键盘，也不渲染触控输入条。
 */

import { inputMethod } from '@kit.IMEKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import testNapi from 'libentry.so'
import {
  AmclInputSource, GLFW_KEY_BACKSPACE, GLFW_KEY_DELETE, GLFW_KEY_ENTER,
  GLFW_PRESS, GLFW_RELEASE, TEXT_INPUT_MAX_SCALARS, TextInputBeginResult,
  TextInputBeginStatus, TextInputSessionLease, getImeActivationGate
} from 'gamecontrol'
import {
  addEntryTextSessionAvailabilityListener,
  endEntryTextInputSession,
  getEntryTextInputSession,
  removeEntryTextSessionAvailabilityListener
} from './EntryTextInputSession'

const TAG: string = 'DesktopPhysicalIme'
const IME_OWNER: string = 'desktop-physical-ime'

@Component
export struct DesktopPhysicalTextInput {
  @Prop @Watch('onActiveChanged') active: boolean = false

  private controller: inputMethod.InputMethodController = inputMethod.getController()
  private mounted: boolean = false
  private desired: boolean = false
  private attached: boolean = false
  private attaching: boolean = false
  private detaching: boolean = false
  private attachFailedForCurrentActivation: boolean = false
  // ⚰️ 墓碑：这里曾有一个"回调已就绪"标志，既当 attach 的前置又当发射前置。
  // 它只能在 attach 之后为真，却被用来门控 attach 本身 —— 自己挡住自己。
  // 注册移到 attach 之后以后它变成只写不读，已删。现在"已绑定 ⇒ 回调在位"由结构保证：
  // 注册失败会走 handleAttachFailure，那里把 attached 打回 false。
  // IME 周边文本查询的最小本地回声。Minecraft 的真实编辑状态仍由游戏持有；这里只
  // 服务当前 attach 期间的组合输入，不把它冒充成游戏文本模型。
  private echo: string = ''
  private preview: string = ''
  private textLease: TextInputSessionLease | undefined = undefined
  private sessionAvailableCb: () => void = (): void => { this.reconcile() }
  private sessionRetryTimer: number = -1
  private sessionRetryAttempt: number = 0

  private cbInsert: (text: string) => void = (text: string) => this.onInsert(text)
  private cbDeleteLeft: (length: number) => void = (length: number) => this.onDeleteLeft(length)
  private cbDeleteRight: (length: number) => void = (length: number) => this.onDeleteRight(length)
  private cbFunctionKey: (key: inputMethod.FunctionKey) => void =
    (_key: inputMethod.FunctionKey) => this.onFunctionKey()
  private cbGetLeft: (length: number) => string = (length: number) => this.leftText(length)
  private cbGetRight: (length: number) => string = (_length: number) => ''
  private cbGetIndex: () => number = () => this.toCodePoints(this.echo).length
  private cbSetPreview: inputMethod.SetPreviewTextCallback =
    (text: string, range: inputMethod.Range) => { this.onSetPreview(text, range) }
  private cbFinishPreview: () => void = () => { this.onFinishPreview() }
  private cbSelectRange: (range: inputMethod.Range) => void =
    (range: inputMethod.Range) => { this.onSelectRange(range) }

  aboutToAppear(): void {
    this.mounted = true
    addEntryTextSessionAvailabilityListener(this.sessionAvailableCb)
    // ⭐ 2026-09-05：**不再在这里注册回调**。平台要求客户端先 attach
    // （"input method client detached. need to be attached first"），而这里离
    // attach 还很远。此前它在这里失败会让回调就绪标志恒假，于是 `reconcile()` 永远
    // 不会调 `beginAttach()` ⇒ desktop IME 整条静默不可用。
    // 与 `ChatInputBridge` 是同一个缺陷的两份拷贝，同批修。
    this.desired = this.active
    this.reconcile()
  }

  aboutToDisappear(): void {
    this.mounted = false
    this.clearSessionRetry(true)
    removeEntryTextSessionAvailabilityListener(this.sessionAvailableCb)
    this.desired = false
    this.unregisterCallbacks()
    this.reconcile()
  }

  private onActiveChanged(): void {
    this.desired = this.active && this.mounted
    this.attachFailedForCurrentActivation = false
    this.clearSessionRetry(true)
    this.reconcile()
  }

  private reconcile(): void {
    if (this.desired) {
      // ⚠️ 回调就绪标志曾是这里的前置条件，而它只能在 attach 之后才可能为真
      // ⇒ 那是一个自己挡住自己的门。现在注册发生在 attach 的 `.then()` 里。
      if (!this.attached && !this.attaching && !this.detaching &&
          !this.attachFailedForCurrentActivation) {
        this.beginAttach()
      }
      return
    }
    if (this.attached && !this.detaching) this.beginDetach()
  }

  private beginAttach(): void {
    const begin: TextInputBeginResult = getEntryTextInputSession().tryBegin(IME_OWNER)
    if (begin.lease === undefined) {
      if (begin.status === TextInputBeginStatus.HostRejected) {
        this.scheduleSessionRetry()
      } else if (begin.status === TextInputBeginStatus.InvalidOwner) {
        this.attachFailedForCurrentActivation = true
      }
      return
    }
    this.textLease = begin.lease
    this.clearSessionRetry(true)
    this.attaching = true
    this.echo = ''
    this.preview = ''
    const textConfig: inputMethod.TextConfig = {
      inputAttribute: {
        textInputType: inputMethod.TextInputType.TEXT,
        enterKeyType: inputMethod.EnterKeyType.NEWLINE
      },
      newEditBox: true
    }
    const options: inputMethod.AttachOptions = {
      showKeyboard: false,
      requestKeyboardReason: inputMethod.RequestKeyboardReason.NONE
    }
    let attachPromise: Promise<void>
    try {
      attachPromise = this.controller.attachWithUIContext(
        this.getUIContext(), textConfig, options)
    } catch (e) {
      this.handleAttachFailure((e as BusinessError).message)
      return
    }
    attachPromise.then(() => {
      this.attaching = false
      this.attached = true
      if (!this.desired || !this.mounted) {
        this.beginDetach()
        return
      }
      // 绑定成功之后才注册回调 —— 顺序理由见 aboutToAppear 的说明。
      if (!this.registerCallbacks()) {
        this.handleAttachFailure('post-attach callback registration failed')
        return
      }
      getImeActivationGate().setActive(IME_OWNER, true)
      hilog.info(0x0000, TAG, 'Desktop physical IME attached without soft keyboard')
    }).catch((err: BusinessError) => {
      this.handleAttachFailure(err.message)
      hilog.warn(0x0000, TAG,
        'Desktop physical IME attach failed code=%{public}d msg=%{public}s',
        err.code, err.message)
    })
  }

  private handleAttachFailure(message: string): void {
    this.attaching = false
    this.attached = false
    this.attachFailedForCurrentActivation = true
    this.unregisterCallbacks()
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
    hilog.warn(0x0000, TAG, 'Desktop IME attach cleanup started: %{public}s', message)
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
      this.reconcile()
    }, delayMs) as number
  }

  private clearSessionRetry(resetAttempt: boolean): void {
    if (this.sessionRetryTimer >= 0) clearTimeout(this.sessionRetryTimer)
    this.sessionRetryTimer = -1
    if (resetAttempt) this.sessionRetryAttempt = 0
  }

  private beginDetach(): void {
    if (this.detaching) return
    this.detaching = true
    this.attached = false
    let detachPromise: Promise<void>
    try {
      detachPromise = this.controller.detach()
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Desktop physical IME detach threw: %{public}s',
        (e as BusinessError).message)
      this.finishDetach()
      return
    }
    detachPromise.then(() => {
      this.finishDetach()
    }).catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'Desktop physical IME detach failed: %{public}s', err.message)
      this.finishDetach()
    })
  }

  private closeTextSession(reason: string): void {
    const lease: TextInputSessionLease | undefined = this.textLease
    this.textLease = undefined
    if (lease !== undefined) {
      endEntryTextInputSession(lease, reason)
    }
    getImeActivationGate().setActive(IME_OWNER, false)
  }

  private finishDetach(): void {
    this.detaching = false
    this.closeTextSession('detach-complete')
    this.echo = ''
    this.preview = ''
    this.reconcile()
  }

  /** **只能在 attach 成功之后调用**；返回 false 时调用方必须收拾掉已绑定的会话。 */
  private registerCallbacks(): boolean {
    try {
      // 必须带同一 callback 引用；off(type) 会清掉进程级 controller 上别的合法 owner。
      this.controller.off('insertText', this.cbInsert)
      this.controller.off('deleteLeft', this.cbDeleteLeft)
      this.controller.off('deleteRight', this.cbDeleteRight)
      this.controller.off('sendFunctionKey', this.cbFunctionKey)
      this.controller.off('getLeftTextOfCursor', this.cbGetLeft)
      this.controller.off('getRightTextOfCursor', this.cbGetRight)
      this.controller.off('getTextIndexAtCursor', this.cbGetIndex)
      this.controller.off('setPreviewText', this.cbSetPreview)
      this.controller.off('finishTextPreview', this.cbFinishPreview)
      this.controller.off('selectByRange', this.cbSelectRange)
      this.controller.on('insertText', this.cbInsert)
      this.controller.on('deleteLeft', this.cbDeleteLeft)
      this.controller.on('deleteRight', this.cbDeleteRight)
      this.controller.on('sendFunctionKey', this.cbFunctionKey)
      this.controller.on('getLeftTextOfCursor', this.cbGetLeft)
      this.controller.on('getRightTextOfCursor', this.cbGetRight)
      this.controller.on('getTextIndexAtCursor', this.cbGetIndex)
      this.controller.on('setPreviewText', this.cbSetPreview)
      this.controller.on('finishTextPreview', this.cbFinishPreview)
      this.controller.on('selectByRange', this.cbSelectRange)
      return true
    } catch (e) {
      this.unregisterCallbacks()
      hilog.error(0x0000, TAG,
        'Desktop physical IME callback registration failed after attach: %{public}s',
        (e as BusinessError)?.message ?? String(e))
      return false
    }
  }

  private unregisterCallbacks(): void {
    try {
      this.controller.off('insertText', this.cbInsert)
      this.controller.off('deleteLeft', this.cbDeleteLeft)
      this.controller.off('deleteRight', this.cbDeleteRight)
      this.controller.off('sendFunctionKey', this.cbFunctionKey)
      this.controller.off('getLeftTextOfCursor', this.cbGetLeft)
      this.controller.off('getRightTextOfCursor', this.cbGetRight)
      this.controller.off('getTextIndexAtCursor', this.cbGetIndex)
      this.controller.off('setPreviewText', this.cbSetPreview)
      this.controller.off('finishTextPreview', this.cbFinishPreview)
      this.controller.off('selectByRange', this.cbSelectRange)
    } catch (e) { /* controller teardown is idempotent */ }
  }

  private canEmit(): boolean {
    return this.mounted && this.desired && this.attached && !this.detaching
  }

  private onInsert(text: string): void {
    if (!this.canEmit() || text.length === 0) return
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease === undefined || !getEntryTextInputSession().commit(lease, text)) return
    this.echo = this.recentText(this.echo + text)
    if (this.preview.length > 0) {
      getEntryTextInputSession().editing(lease, '', 0, 0)
    }
    this.preview = ''
  }

  private onSetPreview(text: string, range: inputMethod.Range): void {
    if (!this.canEmit()) return
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease === undefined) return
    const previewText: string = this.recentText(text)
    const caret: number = this.toCodePoints(previewText).length
    if (!getEntryTextInputSession().editing(
      lease, previewText, caret, 0)) return
    this.preview = previewText
    // Range identifies the surrounding-text replacement span, not a preedit
    // caret. Publish it through the distinct scalar-indexed selection edge when
    // it lands on valid UTF-16 boundaries in our local echo.
    this.publishSelectionRange(lease, range)
  }

  private onFinishPreview(): void {
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease !== undefined && this.canEmit()) {
      getEntryTextInputSession().editing(lease, '', 0, 0)
    }
    this.preview = ''
  }

  private onSelectRange(range: inputMethod.Range): void {
    const lease: TextInputSessionLease | undefined = this.textLease
    if (lease === undefined || !this.canEmit()) return
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

  private onDeleteLeft(length: number): void {
    if (!this.canEmit() || !Number.isFinite(length) ||
        Math.trunc(length) !== length || length > TEXT_INPUT_MAX_SCALARS) return
    const count: number = Math.trunc(length)
    if (count <= 0) return
    for (let i = 0; i < count; i++) this.sendKeyTap(GLFW_KEY_BACKSPACE)
    const cps: number[] = this.toCodePoints(this.echo)
    const keep: number = Math.max(0, cps.length - count)
    this.echo = this.fromCodePoints(cps, 0, keep)
  }

  private onDeleteRight(length: number): void {
    if (!this.canEmit() || !Number.isFinite(length) ||
        Math.trunc(length) !== length || length > TEXT_INPUT_MAX_SCALARS) return
    const count: number = Math.trunc(length)
    if (count <= 0) return
    for (let i = 0; i < count; i++) this.sendKeyTap(GLFW_KEY_DELETE)
  }

  private onFunctionKey(): void {
    if (this.canEmit()) this.sendKeyTap(GLFW_KEY_ENTER)
  }

  private leftText(length: number): string {
    const cps: number[] = this.toCodePoints(this.echo)
    const count: number = Number.isFinite(length) ? Math.max(0, Math.trunc(length)) : 0
    return this.fromCodePoints(cps, Math.max(0, cps.length - count), cps.length)
  }

  private toCodePoints(text: string): number[] {
    const out: number[] = []
    let index: number = 0
    while (index < text.length) {
      const cp: number = text.codePointAt(index) ?? 0
      out.push(cp)
      index += cp > 0xFFFF ? 2 : 1
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

  private fromCodePoints(cps: number[], start: number, end: number): string {
    let out: string = ''
    for (let i = start; i < end; i++) out += String.fromCodePoint(cps[i])
    return out
  }

  private recentText(text: string): string {
    const scalars: number[] = this.toCodePoints(text)
    const start: number = Math.max(0, scalars.length - TEXT_INPUT_MAX_SCALARS)
    return this.fromCodePoints(scalars, start, scalars.length)
  }

  private sendKeyTap(glfwKey: number): void {
    const source: number = AmclInputSource.PhysicalKbm as number
    testNapi.sendSourceKeyEvent(source, glfwKey, 0, GLFW_PRESS, 0)
    testNapi.sendSourceKeyEvent(source, glfwKey, 0, GLFW_RELEASE, 0)
  }

  build() {
    // 纯输入会话，无视觉、无命中区域；desktop 产品仍只有实体设备控制面。
    Blank()
      .width(0)
      .height(0)
      .hitTestBehavior(HitTestMode.None)
  }
}

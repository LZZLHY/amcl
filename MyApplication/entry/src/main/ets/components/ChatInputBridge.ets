/**
 * 软输入条仅提供真实UI资源、显示投影和用户意图。controller/lease/编辑/重试均由
 * GameSessionHost稳定持有的EntryTextInputRuntime维护，页面重建不复制第二套状态机。
 */
import { AppRoundIconButton } from './AppRoundIconButton';
import { AppIconName } from 'commons'
import { window } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { getGameSessionHost } from '../runtime/GameSessionHost'
import { EntryTextInputRuntime, EntryTextInputBinding, EntryTextInputProjection } from '../runtime/EntryTextInputRuntime'

// 此UI前端仍独立报告窗口避让读取失败；controller运行日志归EntryTextRuntime。
// 用真实TAG声明保持现存ChatInputBridge域和调用同名，不让日志登记把有效前端误判为死条目。
const TAG: string = 'ChatInputBridge'

@Component
export struct ChatInputBridge {
  @Prop @Watch('onVisibleChange') visible: boolean = false
  @Prop @Watch('onModeChange') mode: string = 'chat'
  onClose: () => void = (): void => {}
  @State private echo: string = ''
  /** 只读原运行体的文档能力反馈，不持有Range、lease或任何额外输入权限。 */
  @State private documentMessage: string = ''
  /** 只投影原intent身份，供V1取消子按钮按请求换代；不持有新的输入权限。 */
  @State private cancelIdentity_: string = ''
  @State private kbHeightVp: number = 0
  private mounted: boolean = false
  private runtime: EntryTextInputRuntime | undefined = undefined
  private binding: EntryTextInputBinding | undefined = undefined
  private win: window.Window | null = null
  private windowGeneration: number = 0
  private avoid: (data: window.AvoidAreaOptions) => void = (_data: window.AvoidAreaOptions): void => {}

  /** mount捕获本组件真实UIContext，运行体尚未start时只Pending，不由UI提前attach。 */
  aboutToAppear(): void {
    this.mounted = true
    this.runtime = getGameSessionHost().textInputRuntime
    this.bindResource()
    this.watchWindow()
  }

  /** 资源退出与观察退订分开；unbind原对象会退休回调，不调用进程controller。 */
  aboutToDisappear(): void {
    this.mounted = false; this.windowGeneration++
    const binding = this.binding
    this.binding = undefined
    if (binding !== undefined) { this.runtime?.unobserve(binding); this.runtime?.unbind(binding) }
    try { this.win?.off('avoidAreaChange', this.avoid) } catch (_) {}
    this.win = null; this.echo = ''; this.documentMessage = ''; this.kbHeightVp = 0
    this.cancelIdentity_ = ''
  }

  /** role是原资源身份；mode改变必须退出原绑定，旧callback不能借新role/text lease。 */
  private onModeChange(): void {
    if (!this.mounted) return
    const old = this.binding; this.binding = undefined
    if (old !== undefined) { this.runtime?.unobserve(old); this.runtime?.unbind(old) }
    this.bindResource()
  }
  private onVisibleChange(): void {
    const binding = this.binding
    if (binding !== undefined) this.runtime?.request(binding, this.visible && this.mounted)
    this.syncCancelIdentity_()
  }

  /** 观察只回写显示副本；每个闭包都核原binding，旧投影不能写重建后的输入条。 */
  private bindResource(): void {
    const runtime = this.runtime
    if (runtime === undefined) { this.syncCancelIdentity_(); return }
    const binding: EntryTextInputBinding | undefined = runtime.bind(this.mode, { uiContext: this.getUIContext(), onClose: (): void => {
      if (this.mounted && this.binding === binding) this.onClose()
    } })
    this.binding = binding
    if (binding === undefined) { this.syncCancelIdentity_(); return }
    runtime.observe(binding, (value: EntryTextInputProjection): void => {
      if (this.mounted && this.binding === binding) {
        this.echo = value.echo; this.documentMessage = value.documentMessage
        this.syncCancelIdentity_()
      }
    })
    runtime.request(binding, this.visible)
    this.syncCancelIdentity_()
  }

  /**
   * V1普通函数参数只在子组件首次创建时赋值。只读原binding/activation生成展示key，
   * 新请求仅替换取消按钮，旧Round按原alive生命周期退休；echo投影不改变key。
   * 此方法不创建/更新intent，也不在点击时读取后来current能力，原makeAction工厂保持不变。
   */
  private syncCancelIdentity_(): void {
    const binding = this.binding
    const projectedIntent = binding !== undefined ? this.runtime?.captureIntent(binding) : undefined
    this.cancelIdentity_ = this.mounted && binding !== undefined && projectedIntent !== undefined && projectedIntent.binding === binding
      ? binding.id.toString() + ':' + projectedIntent.activation.toString() : ''
  }

  /** 软键盘避让是原UI窗口资源职责；Promise与已排队事件均捕获原窗口/上下文代次。 */
  private watchWindow(): void {
    const generation: number = ++this.windowGeneration, uiContext = this.getUIContext()
    try {
      const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')
      if (context === undefined) return
      window.getLastWindow(context).then((actual: window.Window): void => {
        if (!this.mounted || this.windowGeneration !== generation) return
        this.win = actual
        this.avoid = (data: window.AvoidAreaOptions): void => {
          if (!this.mounted || this.windowGeneration !== generation || this.win !== actual) return
          if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
            try { this.kbHeightVp = uiContext.px2vp(data.area.bottomRect.height) } catch (_) {}
          }
        }
        try { actual.on('avoidAreaChange', this.avoid) } catch (_) {}
        try { this.kbHeightVp = uiContext.px2vp(actual.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height) } catch (_) {}
      }).catch((error: BusinessError): void => { hilog.warn(0, TAG, 'getLastWindow failed: %{public}s', error.message) })
    } catch (_) {}
  }

  /** 渲染时捕获原runtime/binding/activation能力；已排队点击不读取后来组件current字段。 */
  private makeAction(action: string): () => void {
    const runtime = this.runtime, binding = this.binding
    const intent = binding !== undefined ? runtime?.captureIntent(binding) : undefined
    return (): void => {
      if (runtime === undefined || intent === undefined) return
      if (action === 'show') runtime.show(intent)
      else if (action === 'submit') runtime.submit(intent)
      else if (action === 'cancel') runtime.cancel(intent)
    }
  }
  /** 同步明确操作也走同一资格实现；这些方法不另有编辑/回退状态机。 */
  private reshowKeyboard(): void { this.makeAction('show')() }
  private submit(): void { this.makeAction('submit')() }
  private cancel(): void { this.makeAction('cancel')() }

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
          if (this.documentMessage.length > 0) {
            // 能力不足明确提示；这段文字只投影，不模拟替换、修改游戏光标或截获新的输入。
            Text(this.documentMessage)
              .fontSize(13).fontColor('#FFFFD08A')
              .width('94%').maxLines(3)
              .padding({ left: 12, right: 12, bottom: 8 })
              .hitTestBehavior(HitTestMode.None)
          }
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
              .onClick(this.makeAction('show'))
            if (this.mode === 'chat') {
              Button($r('app.string.chat_input_send'))
                .fontSize(14).height(44).width(64).fontColor('#FFFFFF')
                .backgroundColor('#CC2E7D32').borderRadius(22)
                .onClick(this.makeAction('submit'))
            }
            // 游戏输入层如实使用普通样式；继续捕获同一个会话身份，取消顺序与 IME 清理不变。
            // 单项ForEach只按原请求身份更换子按钮，不能用点击时重取current的回调绕过旧intent围栏。
            ForEach([this.cancelIdentity_], (_identity: string): void => {
              AppRoundIconButton({ name: AppIconName.Close, color: '#FFFFFF', containerBg: '#CC553333',
                accessibilityLabel: $r('app.string.chat_input_close'), controlId: 'chat-input-close',
                onAction: this.makeAction('cancel') })
            }, (identity: string): string => identity)
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
}

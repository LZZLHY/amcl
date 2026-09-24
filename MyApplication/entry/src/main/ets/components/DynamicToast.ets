/**
 * DynamicToast.ets — 应用内灵动弹窗（消息中心与诊断体验 · M5.6）
 *
 * 用户在应用内时用它告知（切后台才发系统通知，见 AppNotifier 的分流表）。
 *
 * 为什么不用 `promptAction.showToast`：它**不可点击**、也承载不了标题 + 正文两行。
 * 而本场景的核心需求恰恰是「点一下回到错误 Sheet 看 AI 结果」—— toast 满足不了，
 * 所以必须自己做一个浮层。
 *
 * 行为：
 *   出现  从状态栏下方滑入 + 渐显（animateTo 250 ms）
 *   停留  4 s 自动收起；**手指按住时暂停计时**（用户正在看就别急着收）
 *   点击  执行回调（回错误 Sheet）
 *   上滑  手动收起
 *
 * 关联：docs/guides/message-center-and-diagnosis-ux.md §5.6
 * 创建日期：2026-07-30
 */

import { ThemeColors, AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

/** 自动收起时长（ms）。 */
const AUTO_DISMISS_MS = 4000;
/** 进出场动画时长（ms）。 */
const ANIM_MS = 250;

@Component
export struct DynamicToast {
  /** 是否可见。父组件置 true 触发出现。 */
  @Prop @Watch('onVisibleChanged_') visible: boolean = false
  @Prop title: string = ''
  @Prop body: string = ''
  @Prop theme: ThemeColors = new ThemeColors()
  /** 顶部安全区高度（状态栏避让）。 */
  @Prop topSafeHeight: number = 0

  /** 点击浮层。 */
  onTap: () => void = () => {}
  /** 收起（自动或手动）。父组件应据此把 visible 置回 false。 */
  onDismiss: () => void = () => {}

  /** 动画位移：-120 = 在屏幕上方之外。 */
  @State private offsetY: number = -120
  @State private opacityV: number = 0
  /** 自动收起定时器 id，-1 = 无。 */
  private timer: number = -1
  /** 手指按住时暂停自动收起。 */
  private held: boolean = false

  aboutToAppear(): void {
    if (this.visible) this.enter_()
  }

  aboutToDisappear(): void {
    this.clearTimer_()
  }

  private onVisibleChanged_(): void {
    if (this.visible) this.enter_()
    else this.clearTimer_()
  }

  private enter_(): void {
    this.offsetY = -120
    this.opacityV = 0
    this.getUIContext().animateTo({ duration: ANIM_MS, curve: Curve.FastOutSlowIn }, () => {
      this.offsetY = 0
      this.opacityV = 1
    })
    this.restartTimer_()
  }

  private restartTimer_(): void {
    this.clearTimer_()
    this.timer = setTimeout(() => {
      this.timer = -1
      // 手指还按着说明用户在看，等松手后再收
      if (this.held) { this.restartTimer_(); return }
      this.leave_()
    }, AUTO_DISMISS_MS)
  }

  private clearTimer_(): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1 }
  }

  private leave_(): void {
    this.clearTimer_()
    this.getUIContext().animateTo({ duration: ANIM_MS, curve: Curve.FastOutSlowIn }, () => {
      this.offsetY = -120
      this.opacityV = 0
    })
    // 等动画走完再通知父组件卸载，否则会看到浮层瞬间消失
    setTimeout(() => { this.onDismiss() }, ANIM_MS)
  }

  build() {
    Row({ space: 10 }) {
      // 左侧图标
      Stack() {
        AppIcon({ name: AppIconName.Ai, iconSize: 18, color: this.theme.textOnPrimary })
      }
      .width(34).height(34)
      .borderRadius(17)
      .backgroundColor(this.theme.primary)

      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.body)
          .fontSize(11).fontColor(this.theme.textSecondary)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textHint })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(18)
    .shadow({ radius: 16, color: '#26000000', offsetY: 4 })
    .alignItems(VerticalAlign.Center)
    .margin({ top: this.topSafeHeight + 8, left: 12, right: 12 })
    .translate({ y: this.offsetY })
    .opacity(this.opacityV)
    .onClick(() => {
      this.clearTimer_()
      this.onTap()
      this.leave_()
    })
    // 按住暂停自动收起
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) { this.held = true }
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) { this.held = false }
    })
    // 上滑手动收起
    .gesture(
      PanGesture({ direction: PanDirection.Up, distance: 12 })
        .onActionEnd(() => { this.leave_() })
    )
  }
}

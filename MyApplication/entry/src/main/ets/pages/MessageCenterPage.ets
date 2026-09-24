/**
 * MessageCenterPage.ets — 消息中心（消息中心与诊断体验 · M4.4）
 *
 * 首页右上角那个铃铛此前是纯占位、点了没反应。现在它是消息中心入口。
 *
 * 当前承载的主要是「AI 分析完成 / 失败」，但 `AppMessageKind` 从一开始就是多值 enum，
 * 后面加「下载完成」「更新可用」「JDK 安装完成」不用改结构，卡片按 kind 取图标即可。
 *
 * 结构与安全区 / 主题跟随的写法对齐 `DownloadHistoryPage`，保持全屏 push 页一致。
 *
 * 关联：docs/guides/message-center-and-diagnosis-ux.md §5.4
 * 创建日期：2026-07-30
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { AppIconName } from 'commons';
import { AppIcon } from '../components/AppIcon';
import {
  AppMessage, AppMessageKind, AppMessageActionType,
  getAppMessageStore, APP_MESSAGE_CAPACITY,
} from '../components/AppMessageStore';
import { refreshUnreadCount, cancelNotification } from '../components/AppNotifier';

const TAG = 'MessageCenter'

@Entry
@Component
struct MessageCenterPage {
  @State messages: AppMessage[] = []
  @State loaded: boolean = false
  @State private loadingError: string = ''
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)

  aboutToAppear() {
    this.applyTheme_()
    this.refresh_()
  }

  private applyTheme_(): void {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
  }

  onColorModeChange(): void {
    this.applyTheme_()
  }

  private async refresh_(): Promise<void> {
    let store = getAppMessageStore()
    this.loaded = false
    this.loadingError = ''
    try {
      await store.init(this.context)
    } catch (e) {
      this.loadingError = '读取消息失败：' + (e as Error).message
      hilog.warn(0x0000, TAG, 'init failed: %{public}s', (e as Error).message)
    }
    this.messages = store.list()
    this.loaded = true
  }

  private unreadCount_(): number {
    let n = 0
    for (let m of this.messages) { if (!m.read) n++ }
    return n
  }

  private async markAllRead_(): Promise<void> {
    this.loadingError = ''
    try {
      await getAppMessageStore().markAllRead()
      refreshUnreadCount()
      this.messages = getAppMessageStore().list()
    } catch (e) { this.loadingError = '标记已读失败：' + (e as Error).message }
  }

  /**
   * 点击一条消息：标已读 → 撤掉对应系统通知 → 执行 action。
   *
   * `OPEN_ERROR_SHEET` 走的是与活动记录「查看详情」**同一条回流路径**（写 AppStorage
   * 的 sessionKey + `router.back()`，由 Index 的 @Watch 消费）—— 四个入口收敛到
   * `openErrorSheetBySession`，不各写一套。
   */
  private async onTapMessage_(msg: AppMessage): Promise<void> {
    this.loadingError = ''
    try {
      await getAppMessageStore().markRead(msg.id)
      refreshUnreadCount()
      this.messages = getAppMessageStore().list()
      cancelNotification(msg.id)
    } catch (e) {
      this.loadingError = '更新消息状态失败：' + (e as Error).message
      return
    }

    if (msg.action.type === AppMessageActionType.OPEN_ERROR_SHEET) {
      let key = Number.parseInt(msg.action.payload, 10)
      if (!Number.isNaN(key) && key > 0) {
        AppStorage.setOrCreate('amcl_open_error_sheet_session', key)
        try {
          this.getUIContext().getRouter().back()
        } catch (e) {
          hilog.warn(0x0000, TAG, 'router.back failed: %{public}s', (e as Error).message)
        }
      }
    } else if (msg.action.type === AppMessageActionType.OPEN_PAGE) {
      if (msg.action.payload.length > 0) {
        try {
          this.getUIContext().getRouter().pushUrl({ url: msg.action.payload })
        } catch (e) {
          hilog.warn(0x0000, TAG, 'pushUrl failed: %{public}s', (e as Error).message)
        }
      }
    }
  }

  private async clearAll_(): Promise<void> {
    this.loadingError = ''
    try {
      await getAppMessageStore().clear()
      refreshUnreadCount()
      this.messages = []
    } catch (e) { this.loadingError = '清空消息失败：' + (e as Error).message }
  }

  private confirmClear_(): void {
    if (this.messages.length === 0) return
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '清空消息？',
        message: '这会删除消息中心里的通知记录，不会删除活动日志或分享链接。',
        buttons: [
          { text: '取消', color: this.theme.primary as string },
          { text: '清空消息', color: this.theme.error as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 1) this.clearAll_()
      }).catch(() => { /* 点框外 = 取消 */ })
    } catch (e) { this.loadingError = '无法打开确认框：' + (e as Error).message }
  }

  // ---- 展示 helper ----

  private kindIcon_(kind: AppMessageKind): AppIconName {
    if (kind === AppMessageKind.AI_ANALYSIS_DONE) return AppIconName.Ai
    if (kind === AppMessageKind.AI_ANALYSIS_FAILED) return AppIconName.Warning
    if (kind === AppMessageKind.DOWNLOAD_DONE) return AppIconName.Download
    if (kind === AppMessageKind.UPDATE_AVAILABLE) return AppIconName.Refresh
    return AppIconName.Info
  }

  private kindColor_(kind: AppMessageKind): ResourceColor {
    if (kind === AppMessageKind.AI_ANALYSIS_FAILED) return this.theme.error
    if (kind === AppMessageKind.DOWNLOAD_DONE) return this.theme.success
    if (kind === AppMessageKind.UPDATE_AVAILABLE) return this.theme.warning
    return this.theme.primary
  }

  private kindBg_(kind: AppMessageKind): ResourceColor {
    if (kind === AppMessageKind.AI_ANALYSIS_FAILED) return this.theme.errorBg
    if (kind === AppMessageKind.DOWNLOAD_DONE) return this.theme.successBg
    if (kind === AppMessageKind.UPDATE_AVAILABLE) return this.theme.warningBg
    return this.theme.primaryLight
  }

  /** 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 / 具体日期。 */
  private relativeTime_(ms: number): string {
    if (ms <= 0) return ''
    let diff = Date.now() - ms
    if (diff < 60_000) return '刚刚'
    if (diff < 3600_000) return Math.floor(diff / 60_000) + ' 分钟前'
    if (diff < 86400_000) return Math.floor(diff / 3600_000) + ' 小时前'
    if (diff < 172800_000) return '昨天'
    let d = new Date(ms)
    let pad = (n: number): string => (n < 10 ? '0' + n.toString() : n.toString())
    return pad(d.getMonth() + 1) + '-' + pad(d.getDate())
  }

  build() {
    Column() {
      // 导航栏
      Row() {
        Row({ space: 4 }) {
          AppIcon({ name: AppIconName.Back, iconSize: 18, color: this.theme.primary })
          Text('返回')
            .fontSize(16).fontWeight(400).fontColor(this.theme.primary)
        }
        .onClick(() => { this.getUIContext().getRouter().back() })
        .padding({ left: 12, top: 8, bottom: 8, right: 8 })

        Text('消息')
          .fontSize(20).fontWeight(700).fontColor(this.theme.textPrimary)
          .layoutWeight(1).textAlign(TextAlign.Center)

        // 有未读 → 「全部已读」；无未读但有消息 → 「清空」
        if (this.unreadCount_() > 0) {
          Text('全部已读')
            .fontSize(14).fontColor(this.theme.primary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => { this.markAllRead_() })
        } else if (this.messages.length > 0) {
          Text('清空')
            .fontSize(14).fontColor(this.theme.textHint)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => { this.confirmClear_() })
        } else {
          Text('')
            .padding({ left: 12, right: 12 })
        }
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)

      if (this.loadingError.length > 0) {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 14, color: this.theme.error })
          Text(this.loadingError).fontSize(12).fontColor(this.theme.error).layoutWeight(1)
          Button('重试').fontSize(12).onClick(() => { this.refresh_() })
        }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }

      if (!this.loaded) {
        Column() {
          Text('加载中...')
            .fontSize(14).fontColor(this.theme.textHint)
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.loadingError.length > 0 && this.messages.length === 0) {
        Column() {
          Text('消息暂不可用，请重试加载').fontSize(16).fontColor(this.theme.textSecondary)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.messages.length === 0) {
        Column({ space: 12 }) {
          AppIcon({ name: AppIconName.Notification, iconSize: 40, color: this.theme.textHint })
          Text('暂无消息')
            .fontSize(16).fontColor(this.theme.textHint)
          Text('AI 分析完成等异步结果会在这里出现，最多保留 '
            + APP_MESSAGE_CAPACITY + ' 条')
            .fontSize(12).fontColor(this.theme.textHint)
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.messages, (m: AppMessage) => {
              this.MessageCard(m)
            }, (m: AppMessage) => m.id)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 24 + this.bottomSafeHeight })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topSafeHeight })
    .backgroundColor(this.theme.bgPrimary)
  }

  @Builder
  MessageCard(m: AppMessage) {
    Row({ space: 10 }) {
      // 左侧 kind 图标
      Stack() {
        AppIcon({ name: this.kindIcon_(m.kind), iconSize: 18, color: this.kindColor_(m.kind) })
      }
      .width(38).height(38)
      .borderRadius(19)
      .backgroundColor(this.kindBg_(m.kind))

      Column({ space: 3 }) {
        Row({ space: 6 }) {
          // 未读圆点
          if (!m.read) {
            Row().width(7).height(7).borderRadius(4).backgroundColor(this.theme.error)
          }
          Text(m.title)
            .fontSize(14)
            .fontWeight(m.read ? FontWeight.Normal : FontWeight.Bold)
            .fontColor(this.theme.textPrimary)
            .layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.relativeTime_(m.createdAt))
            .fontSize(11).fontColor(this.theme.textHint)
        }
        .width('100%').alignItems(VerticalAlign.Center)

        Text(m.body)
          .fontSize(12).lineHeight(17).fontColor(this.theme.textSecondary)
          .width('100%')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (m.action.type !== AppMessageActionType.NONE) {
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textHint })
      }
    }
    .width('100%')
    // 给最小高度：正文 1 行 / 2 行都不至于让列表跳动
    .constraintSize({ minHeight: 68 })
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(this.theme.cardRadius)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.onTapMessage_(m) })
  }
}

/**
 * UpdateDialog.ets — 发现新版本弹窗（替代原来的系统 promptAction.showDialog）
 *
 * 为什么自绘：系统弹窗只能显示一段纯文本 message，无法分类、无法滚动、无法放入
 * 「查看完整更新日志」入口。数据侧已经把更新说明结构化了（update.json 的
 * `notesEntries`，见 AMCL-web/CHANGELOG-SPEC.md），UI 必须跟上才用得到。
 *
 * 数据来源：`UpdateChecker.displayEntries(manifest)` —— 优先结构化条目，
 * 拿不到时自动回退解析 `notes` 纯文本，所以本组件对新旧 update.json 都能渲染。
 *
 * 应用更新提供立即更新、稍后、自行下载；运行时更新保留原来的选择安装行为。
 * mandatory 控制服务停止提示，是否允许游戏继续仍由宿主策略决定，不能剥夺手动下载出口。
 *
 * 应用自更新使用 Pencil check-update.pen 的 R3；JDK 等共享用途仍保留原选择安装面板。
 * 父层从发现态起持有固定外框，状态切换只替换内部内容，不参与新的业务推进。
 *
 * 创建日期：2026-08-08
 */

import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { UpdateNoteEntry, noteTypeLabel } from 'update';
import { AppIcon } from './AppIcon';
import { changelogTone } from './SemanticColors';
import { SideloadUpdateContent } from './SideloadUpdateContent';
import { SideloadUpdatePageParams } from '../sideload/SideloadUpdateViewModel';
import { resolveUpdateDialogLayout, UpdateDialogLayout } from './UpdateDialogLayout';

/** 可选运行时条目；复用更新说明面板但由宿主处理安装任务，不混用 App versionCode。 */
export interface UpdateDialogItem {
  id: string; title: string; current: string; target: string; sizeLabel: string; description: string;
}

/**
 * 条目列表的高度限位。
 *
 * 条目数量由发版者写的 notes / notesEntries 决定（1.0.2 就有 20 条），是弹窗里**唯一**
 * 会无界增长的部分，所以只限它、不限整个弹窗 —— 给弹窗根节点加 maxHeight 反而会把
 * 底部按钮裁掉。
 *
 * 上限按屏幕高度算而不是写死：弹窗其余部分（头部 51 + 对比条 35 + 说明头 18 + 分割线 1 +
 * 日志入口 27 + 按钮 46 + 五处 gap 66 + 上下 padding 36 ≈ 280，强制更新态再多一条横幅）
 * 约占 290vp，再给系统安全区留 15%，剩下的才给列表；最后夹到 [140, 360]，避免小屏塞不下、
 * 大屏又把弹窗拉成一长条。360vp 大约能一屏显示 12 条，20 条（1.0.2 的量）滚动两三下看完。
 */
const LIST_CHROME_VP: number = 290;
const LIST_MIN_HEIGHT: number = 140;
const LIST_MAX_HEIGHT: number = 360;
const LIST_FALLBACK_HEIGHT: number = 232;

function listMaxHeight(): number {
  const height = AppStorage.get<number>('screenHeightVp') ?? 800;
  return Math.max(48, Math.min(LIST_MAX_HEIGHT, height * 0.85 - LIST_CHROME_VP));
}

@CustomDialog
export struct UpdateDialog {
  // @CustomDialog 的编译期必需字段。部分设备运行时不会注入它，业务关闭不得依赖此值。
  controller?: CustomDialogController
  theme: ThemeColors = {} as ThemeColors

  /** 新版本号（如 1.0.2）；空串时退化显示 tag。 */
  newVersion: string = ''
  /** 设备当前版本号（APP_VERSION）。 */
  currentVersion: string = ''
  /** 发布日期 YYYY-MM-DD，可空。 */
  releaseDate: string = ''
  /** 预格式化的体积文案（如 "42.0 MB"），可空 —— 格式化由调用方做，弹窗不依赖 PathUtils。 */
  sizeLabel: string = ''
  /** 强制更新：去掉「稍后」，加红色横幅。 */
  mandatory: boolean = false
  /** 结构化更新说明。 */
  entries: UpdateNoteEntry[] = []
  /** 是否显示「查看完整更新日志」入口（上架轨等场景可关掉）。 */
  showChangelogEntry: boolean = true
  /** App 默认文案保持原样；运行时场景可独立设置标题、动作与来源说明。 */
  title: string = ''
  actionLabel: string = ''
  sourceLabel: string = 'GitHub 发布'
  /** 恢复提示没有新候选，不能套用“有新版本可用”的缺省说明。 */
  emptyNotesLabel: string = '有新版本可用，建议更新。'
  /** 应用更新启用第三个出口；JDK等复用弹窗不显示自行下载。 */
  showManualDownload: boolean = false
  onManualDownload: () => void = () => {}
  /** 应用自更新在原弹窗切换内容；JDK/商店等其他用途仍走原回调。 */
  selfUpdateParams?: SideloadUpdatePageParams
  @State private selfUpdating: boolean = false
  /** 系统Back/ESC和按钮共用显式退出，框架卸载本身不再取消业务。 */
  private exitSelfUpdate: () => boolean = (): boolean => false
  @StorageProp('screenHeightVp') private windowHeight: number = 800
  @StorageProp('screenWidthVp') private windowWidth: number = 360
  @StorageProp('topRectHeight') private topSafe: number = 0
  @StorageProp('bottomRectHeight') private bottomSafe: number = 0
  onExitGuardReady: (exit: () => boolean) => void = (): void => {}
  onDismissGuardReady: (guard: () => boolean) => void = (): void => {}
  items: UpdateDialogItem[] = []
  @State private selectedItems: string[] = []
  onInstallItems: (ids: string[]) => void = () => {}

  aboutToAppear(): void {
    this.selectedItems = this.items.map((item: UpdateDialogItem): string => item.id)
    this.onDismissGuardReady((): boolean => !this.selfUpdating || this.exitSelfUpdate())
    this.onExitGuardReady((): boolean => !this.selfUpdating || this.exitSelfUpdate())
  }

  /** 条目列表高度上限（按屏幕算一次，build 内多处引用不重复取 display）。 */
  private listMaxHeight(): number { return Math.max(48, Math.min(LIST_MAX_HEIGHT, this.windowHeight * 0.85 - LIST_CHROME_VP)); }

  onDownload: () => void = () => {}
  onLater: () => void = () => {}
  onViewChangelog: () => void = () => {}

  private headline_(): string {
    if (this.title.length > 0) return this.title
    return this.mandatory ? '重要更新' : '发现新版本'
  }

  private metaLine_(): string {
    let parts: string[] = []
    if (this.sizeLabel.length > 0) parts.push('约 ' + this.sizeLabel)
    if (this.releaseDate.length > 0) parts.push(this.releaseDate)
    return parts.join(' · ')
  }

  /** 只有应用自更新进入 R3；运行时条目和上架渠道继续沿原出口，不能误入华为授权。 */
  private isAppUpdate(): boolean { return this.selfUpdateParams !== undefined && this.items.length === 0; }

  /**
   * 几何只依赖窗口事实。使用普通方法而非struct自定义getter：当前SDK转换会丢弃getter，
   * 却保留渲染中的属性读取，导致首帧访问undefined.width；方法在真实SDK产物中保留。
   */
  private appFrame(): UpdateDialogLayout {
    return resolveUpdateDialogLayout(this.windowWidth, this.windowHeight, this.topSafe, this.bottomSafe);
  }

  /** 恢复提示保留“查看更新状态”，普通新候选才使用用户确认的“直接下载”。 */
  private appActionLabel(): string {
    return this.selfUpdateParams?.autoStart === false
      ? (this.actionLabel || '查看更新状态') : '直接下载';
  }

  /** 图标仅表达发布者给出的条目类别，不从正文推断或编造新的更新亮点。 */
  private noteIcon(type: string): AppIconName {
    if (type === 'fixed') return AppIconName.Construction;
    if (type === 'added') return AppIconName.Plus;
    if (type === 'improved') return AppIconName.ArrowUpRight;
    if (type === 'refactored') return AppIconName.Refresh;
    if (type === 'highlight') return AppIconName.Celebrate;
    return AppIconName.Info;
  }

  /** 与进行态使用同一显示格式，版本前缀和元数据不因点击下载发生不必要的视觉变化。 */
  private appVersionLabel(version: string): string {
    return version.length === 0 ? '—' : version.startsWith('v') ? version : 'v' + version;
  }

  /** 只拼接真实发布元数据；缺项省略，不使用设计稿中的示例值。 */
  private appReleaseLabel(): string {
    let label = 'AMCL';
    if (this.sizeLabel.length > 0) label += ' · ' + this.sizeLabel;
    if (this.releaseDate.length > 0) label += ' · ' + this.releaseDate;
    return label;
  }

  build() {
    Column() {
      if (this.isAppUpdate()) {
        if (this.selfUpdating && this.selfUpdateParams !== undefined) {
          SideloadUpdateContent({ params: this.selfUpdateParams, currentVersion: this.currentVersion,
            sizeLabel: this.sizeLabel, releaseDate: this.releaseDate, compact: this.appFrame().compact,
            entries: this.entries, showChangelogEntry: this.showChangelogEntry,
            onDismiss: (): void => { this.onLater(); },
            onExitGuardReady: (exit: () => boolean): void => { this.exitSelfUpdate = exit; } })
            .width('100%').height('100%')
        } else {
          this.appDiscoveryPanel()
        }
      } else {
        // JDK 条目是独立安装任务，继续使用其原列表、选择状态和宿主回调。
        Scroll() { this.discoveryPanel() }.width('100%').scrollBar(BarState.Auto)
      }
    }
    .width(this.isAppUpdate() ? this.appFrame().width : '88%')
    .height(this.isAppUpdate() ? this.appFrame().height : undefined)
    .constraintSize({ maxWidth: this.isAppUpdate() ? 320 : 460,
      maxHeight: Math.max(1, this.windowHeight - this.topSafe - this.bottomSafe - 40) })
    .backgroundColor(this.theme.bgCard).borderRadius(20).clip(true)
  }

  /**
   * R3 发现态：图标/短文案、双列版本、单一滚动亮点区与固定页脚。
   * 完整条目仍来自清单，不将设计示例中的四条文案硬编码到产品。
   */
  @Builder
  private appDiscoveryPanel() {
    Column({ space: this.appFrame().compact ? 8 : 14 }) {
      Row({ space: 12 }) {
        Stack() {
          AppIcon({ name: this.mandatory ? AppIconName.Warning : AppIconName.CloudDownload,
            iconSize: 22, color: this.mandatory ? this.theme.errorText : this.theme.primary })
        }.width(this.appFrame().compact ? 36 : 44).height(this.appFrame().compact ? 36 : 44)
          .backgroundColor(this.mandatory ? this.theme.errorBg : this.theme.primaryLight).borderRadius(16)
        Column({ space: 3 }) {
          Text(this.headline_()).fontSize(18).fontWeight(700).fontColor(this.theme.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.appReleaseLabel()).fontSize(12).fontColor(this.theme.textSecondary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').height(this.appFrame().compact ? 40 : 52).flexShrink(0)
      Row({ space: 12 }) {
        Column({ space: 1 }) {
          Text('当前版本').fontSize(12).fontColor(this.theme.textSecondary)
          Text(this.appVersionLabel(this.currentVersion)).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: AppIconName.ArrowRight, iconSize: 16, color: this.theme.textSecondary })
        Column({ space: 1 }) {
          Text('新版本').fontSize(12).fontColor(this.theme.actionPrimary)
          Text(this.appVersionLabel(this.newVersion)).fontSize(14).fontWeight(600).fontColor(this.theme.actionPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.End)
      }.width('100%').height(this.appFrame().compact ? 36 : 44).padding({ left: 12, right: 12 })
        .backgroundColor(this.theme.bgInput).borderRadius(12).flexShrink(0)
      Scroll() {
        Column({ space: 10 }) {
          if (this.mandatory) {
            Text('建议尽快更新，以获得最新版本与修复').fontSize(12).fontColor(this.theme.errorText).width('100%')
          }
          Row() {
            Text('更新亮点').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
            Text('共 ' + this.entries.length + ' 项').fontSize(12).fontColor(this.theme.textSecondary)
          }.width('100%')
          if (this.entries.length > 0) {
            ForEach(this.entries, (entry: UpdateNoteEntry) => {
              Row({ space: 10 }) {
                Stack() {
                  AppIcon({ name: this.noteIcon(entry.type), iconSize: 16, color: changelogTone(entry.type, this.theme).color })
                }.width(30).height(30).backgroundColor(changelogTone(entry.type, this.theme).bg).borderRadius(9)
                Column({ space: 1 }) {
                  Text(noteTypeLabel(entry.type)).fontSize(12).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
                  Text(entry.text).fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').alignItems(VerticalAlign.Top)
            }, (entry: UpdateNoteEntry, index: number): string => index + ':' + entry.text)
          } else {
            Text(this.emptyNotesLabel).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
          }
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      Divider().color(this.theme.divider).strokeWidth(0.5).flexShrink(0)
      Row() {
        if (this.showChangelogEntry) {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.History, iconSize: 14, color: this.theme.actionPrimary })
            Text('查看完整更新日志').fontSize(12).fontColor(this.theme.actionPrimary)
          }.height(32).onClick((): void => { this.onViewChangelog(); }).accessibilityGroup(true)
        }
        Blank()
        if (this.showManualDownload) {
          Text('自行下载 ↗').fontSize(12).fontColor(this.theme.actionPrimary).height(32)
            .onClick((): void => { this.onManualDownload(); }).accessibilityText('自行下载，打开外部下载页面')
        }
      }.width('100%').height(32).alignItems(VerticalAlign.Center).flexShrink(0)
      Row({ space: 10 }) {
        if (!this.mandatory || this.showManualDownload) {
          Button('稍后再说').type(ButtonType.Normal).borderRadius(12).layoutWeight(1)
            .height(this.appFrame().compact ? 44 : 46).fontSize(14)
            .backgroundColor(this.theme.bgInput).fontColor(this.theme.textSecondary)
            .onClick((): void => { this.onLater(); })
        }
        Button() {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.Download, iconSize: 16, color: this.theme.textOnPrimary })
            Text(this.appActionLabel()).fontSize(14).fontWeight(600).fontColor(this.theme.textOnPrimary)
          }
        }.type(ButtonType.Normal).borderRadius(12).layoutWeight(1)
          .height(this.appFrame().compact ? 44 : 46).backgroundColor(this.theme.primary)
          .onClick((): void => { this.selfUpdating = true; })
      }.width('100%').height(this.appFrame().compact ? 44 : 46).flexShrink(0)
    }.width('100%').height('100%')
      .padding({ left: this.appFrame().compact ? 12 : 20, right: this.appFrame().compact ? 12 : 20,
        top: this.appFrame().compact ? 12 : 20, bottom: this.appFrame().compact ? 12 : 16 })
  }

  @Builder
  private discoveryPanel() {
    Column({ space: 14 }) {
      // ===== 头部：图标 + 标题 + 版本药丸 =====
      Row({ space: 12 }) {
        Stack() {
          AppIcon({
            name: this.mandatory ? AppIconName.Warning : AppIconName.CloudDownload,
            iconSize: 23,
            color: this.mandatory ? this.theme.error : this.theme.primary,
          })
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(this.mandatory ? this.theme.errorBg : this.theme.primaryLight)

        Column({ space: 3 }) {
          Text(this.headline_())
            .fontSize(19).fontWeight(700).fontColor(this.theme.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text((this.items.length > 0 ? '' : 'v') + this.newVersion)
              .fontSize(11).fontWeight(600).fontColor(this.theme.textOnPrimary)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(5)
              .backgroundColor(this.mandatory ? this.theme.error : this.theme.primary)
            if (this.metaLine_().length > 0) {
              Text(this.metaLine_())
                .fontSize(11).fontColor(this.theme.textHint)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
          }
          .width('100%').alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // ===== 版本对比条 =====
      if (this.items.length === 0) {
      Row() {
        Row({ space: 7 }) {
          Text('当前 v' + this.currentVersion)
            .fontSize(12).fontColor(this.theme.textSecondary)
          AppIcon({ name: AppIconName.ArrowRight, iconSize: 13, color: this.theme.textHint })
          Text('v' + this.newVersion)
            .fontSize(12).fontWeight(600)
            .fontColor(this.mandatory ? this.theme.error : this.theme.primary)
        }
        .alignItems(VerticalAlign.Center).layoutWeight(1)
        Text(this.sourceLabel)
          .fontSize(11).fontColor(this.theme.textHint)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(10)
      .backgroundColor(this.theme.bgInput)
      .alignItems(VerticalAlign.Center)
      }

      // ===== 强制更新横幅 =====
      if (this.mandatory) {
        Row({ space: 7 }) {
          AppIcon({ name: AppIconName.Warning, iconSize: 14, color: this.theme.error })
          Text('建议尽快更新，以获得最新版本与修复')
            .fontSize(11).lineHeight(16).fontColor(this.theme.error)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(10)
        .backgroundColor(this.theme.errorBg)
        .alignItems(VerticalAlign.Center)
      }

      // ===== 更新内容 =====
      Column({ space: 10 }) {
        Row() {
          Text('更新内容')
            .fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary)
            .layoutWeight(1)
          Text(`共 ${this.items.length > 0 ? this.items.length : this.entries.length} 项`)
            .fontSize(11).fontColor(this.theme.textHint)
        }
        .width('100%').alignItems(VerticalAlign.Center)

        if (this.entries.length > 0 || this.items.length > 0) {
          Scroll() {
            Column({ space: 9 }) {
              ForEach(this.items, (item: UpdateDialogItem) => {
                Row({ space: 8 }) {
                  Checkbox({ name:item.id })
                    .select(this.selectedItems.indexOf(item.id) >= 0)
                    .selectedColor(this.theme.primary)
                    .onChange((selected: boolean): void => {
                      this.selectedItems = selected
                        ? this.selectedItems.concat([item.id])
                        : this.selectedItems.filter((id: string): boolean => id !== item.id)
                    })
                  Column({ space: 4 }) {
                    Text(item.title + ' · ' + item.sizeLabel).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
                    Text(item.current + ' → ' + item.target).fontSize(11).fontColor(this.theme.textHint)
                    Text(item.description).fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%').alignItems(VerticalAlign.Top)
              }, (item: UpdateDialogItem): string => item.id)
              ForEach(this.entries, (e: UpdateNoteEntry) => {
                Row({ space: 8 }) {
                  Text(noteTypeLabel(e.type))
                    .fontSize(11).fontWeight(600)
                    .fontColor(changelogTone(e.type, this.theme).color)
                    .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                    .borderRadius(6)
                    .backgroundColor(changelogTone(e.type, this.theme).bg)
                  Text(e.text)
                    .fontSize(13).lineHeight(19.5).fontColor(this.theme.textSecondary)
                    .layoutWeight(1)
                }
                .width('100%').alignItems(VerticalAlign.Top)
              }, (e: UpdateNoteEntry, i: number) => i + ':' + e.text)
            }
            .width('100%')
          }
          .width('100%')
          // 限位：内容超过 maxHeight 时列表内部滚动，弹窗整体高度不再增长
          // 第三个下载出口增加58vp，把这部分从可滚动日志区扣除，保留小屏上的全部操作按钮。
          .constraintSize({ maxHeight: Math.max(80, this.listMaxHeight() - (this.showManualDownload ? 58 : 0)) })
          .scrollBar(BarState.Auto)
          .scrollBarWidth(3)
          .scrollBarColor(this.theme.divider)
          // Spring 回弹让"这里可以滑"这件事被用户感知到（None 会让人以为列表被截断了）
          .edgeEffect(EdgeEffect.Spring)
        } else {
          Text(this.emptyNotesLabel)
            .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        }
      }
      .width('100%')

      // ===== 完整更新日志入口 =====
      if (this.showChangelogEntry) {
        Divider().color(this.theme.divider).strokeWidth(0.5)
        Row() {
          Row({ space: 7 }) {
            AppIcon({ name: AppIconName.History, iconSize: 15, color: this.theme.primary })
            Text('查看完整更新日志')
              .fontSize(13).fontWeight(500).fontColor(this.theme.primary)
          }
          .alignItems(VerticalAlign.Center).layoutWeight(1)
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 15, color: this.theme.primary })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          let callback: () => void = this.onViewChangelog
          callback()
        })
      }

      // ===== 按钮 =====
      Row({ space: 10 }) {
        if (!this.mandatory || this.showManualDownload) {
          Button('稍后')
            .type(ButtonType.Normal).borderRadius(12)
            .layoutWeight(1).height(46)
            .fontSize(15).fontWeight(500)
            .backgroundColor(this.theme.bgInput)
            .fontColor(this.theme.textSecondary)
            .onClick(() => {
              let callback: () => void = this.onLater
              callback()
            })
        }
        Button() {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.Download, iconSize: 16, color: this.theme.textOnPrimary })
            Text(this.actionLabel.length > 0 ? this.actionLabel : (this.mandatory ? '立即更新' : '前往下载'))
              .fontSize(15).fontWeight(600).fontColor(this.theme.textOnPrimary)
          }
          .alignItems(VerticalAlign.Center)
        }
        .type(ButtonType.Normal).borderRadius(12)
        .layoutWeight(1).height(46)
        .backgroundColor(this.mandatory ? this.theme.error : this.theme.primary)
        .enabled(this.items.length === 0 || this.selectedItems.length > 0)
        .onClick(() => {
          if (this.items.length > 0) { this.onInstallItems(this.selectedItems.slice()); return; }
          if (this.selfUpdateParams !== undefined) { this.selfUpdating = true; return; }
          let callback: () => void = this.onDownload
          callback()
        })
      }
      .width('100%')
      if (this.showManualDownload) {
        Button('自行下载')
          .type(ButtonType.Normal).width('100%').height(44).borderRadius(12)
          .backgroundColor(this.theme.bgInput).fontColor(this.theme.textSecondary).fontSize(14)
          .onClick((): void => { this.onManualDownload(); })
      }
    }
    // customStyle: true 时弹窗容器不做任何默认样式，宽度由本组件决定：
    // 手机 88% ≈ 316vp（对齐设计稿的 312），平板/2in1 用 maxWidth 收住不拉伸。
    .width('100%')
    .padding({ left: 20, right: 20, top: 20, bottom: 16 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(20)
  }
}

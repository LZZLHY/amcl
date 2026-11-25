/**
 * 呈现颜色遵循父层主题快照：操作文字与焦点独立于按钮填充，状态小字独立于进度填充。
 * 本域不读取主题偏好，不改变原事件、任务或账户生命周期；资源类别与第三方品牌保持独立。
 */
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
 * 应用更新提供立即更新、明确退出、自行下载；运行时更新保留选择安装行为。
 * 必需提醒显示调用方提供的真实影响；是否允许游戏继续由宿主策略决定，保留手动下载出口。
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
import { UpdateReminderLevel, RequiredUpdateNotice, isRequiredUpdate,
  canDismissUpdateDiscovery } from './UpdateReminderPolicy';

/** 可选运行时条目；复用更新说明面板但由宿主处理安装任务，不混用 App versionCode。 */
import { LauncherSkillBus } from '../launcherskill/LauncherSkillBus';
import { SettingsSkillData, settingKeys, settingText, settingFailure, nextSettingsReceipt } from '../launcherskill/SettingsSkillValues';

export interface UpdateDialogItem {
  id: string; title: string; current: string; target: string; sizeLabel: string; description: string;
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
  /** 兼容既有发行字段；新调用方使用 reminderLevel 明确选择普通或必需提醒。 */
  mandatory: boolean = false
  /** 两类更新共用同一展示合同；是否启用由App/JDK各自业务判定，不按通道名推断。 */
  reminderLevel: UpdateReminderLevel = UpdateReminderLevel.NORMAL
  /** 必需原因、实际影响与明确退出动作；空值使用中性兜底，不编造服务停止或数据损坏。 */
  requiredNotice: RequiredUpdateNotice = { reason: '', consequence: '', exitLabel: '暂不使用' }
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
  /** 次要元数据和运行时长说明在本弹窗内展开，不叠加新的信息弹窗。 */
  @State private detailsExpanded: boolean = false
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
  private skillNoticeRef_: string = '';

  /** 给当前已展示的更新提示绑定引用。只读已有提示，不用外部数据构造安装清单。 */
  private async noticeSkill_(method: string,args: SettingsSkillData): Promise<SettingsSkillData> {
    if (method === 'getUpdateNotice' && settingKeys(args,[])) {
      return {'state':'ready','reference':this.skillNoticeRef_,'required':this.isRequired_(),'version':this.newVersion,
        'items':this.items.map((item: UpdateDialogItem): SettingsSkillData => ({'id':item.id,'title':item.title,
          'current':item.current,'target':item.target,'selected':this.selectedItems.includes(item.id)}))};
    }
    if (method === 'chooseRuntimeUpdateItem' && settingKeys(args,['reference','id','selected']) &&
      args['reference'] === this.skillNoticeRef_ && typeof args['selected'] === 'boolean') {
      const id=settingText(args,'id');
      if (!this.items.some((item: UpdateDialogItem): boolean => item.id === id)) return settingFailure('itemChanged');
      this.selectNoticeItem_(id,args['selected'] as boolean);
      return {'state':'ready','reference':this.skillNoticeRef_,'selected':this.selectedItems.slice()};
    }
    if (method === 'answerUpdateNotice' && settingKeys(args,['reference','answer']) && args['reference'] === this.skillNoticeRef_) {
      const answer=settingText(args,'answer');
      if (answer === 'later') {
        this.onLater();
        return {'state':'ready','required':this.isRequired_(),'outcome':this.isRequired_()?'notUsingFeature':'postponed'};
      }
      if (answer === 'review') {
        this.detailsExpanded=true;
        return {'state':'needsUser','reason':'confirmDisplayedTarget','reference':this.skillNoticeRef_};
      }
    }
    return settingFailure('invalidOrExpiredNotice');
  }

  private selectNoticeItem_(id: string, selected: boolean): void {
    if (selected && !this.selectedItems.includes(id)) this.selectedItems = this.selectedItems.concat([id]);
    else if (!selected) this.selectedItems = this.selectedItems.filter((item: string): boolean => item !== id);
  }

  aboutToAppear(): void {
    this.skillNoticeRef_ = nextSettingsReceipt();
    LauncherSkillBus.bind('updateNotice',this,(method: string,args: SettingsSkillData): Promise<SettingsSkillData> =>
      this.noticeSkill_(method,args), (): boolean => !this.selfUpdating && AppStorage.get<boolean>('appInForeground') === true);
    this.selectedItems = this.items.map((item: UpdateDialogItem): string => item.id)
    this.onDismissGuardReady((): boolean => this.selfUpdating ? this.exitSelfUpdate()
      : canDismissUpdateDiscovery(this.reminderLevel, this.mandatory))
    // 页面退出/销毁仍须退休正在运行的业务；它与用户点击遮罩的关闭权限不是同一概念。
    this.onExitGuardReady((): boolean => !this.selfUpdating || this.exitSelfUpdate())
  }

  onDownload: () => void = () => {}
  onLater: () => void = () => {}
  onViewChangelog: () => void = () => {}
  aboutToDisappear(): void { LauncherSkillBus.unbind('updateNotice',this); this.skillNoticeRef_=''; }

  /** 在当前参数上求值，保证父层重新展示不同等级时不会沿用旧的提示状态。 */
  private isRequired_(): boolean { return isRequiredUpdate(this.reminderLevel, this.mandatory); }

  /** 显式退出不伪装成普通更新的“稍后再说”；调用方必须保留实际功能准入。 */
  private secondaryLabel_(): string {
    return this.isRequired_() ? (this.requiredNotice.exitLabel || '暂不使用') : '稍后再说';
  }

  private headline_(): string {
    if (this.title.length > 0) return this.title
    return this.isRequired_() ? '需要更新后继续' : '发现新版本'
  }

  /** App/JDK共用的强提醒说明区，必须能读到“为什么”和“不处理会怎样”，长文随正文滚动。 */
  @Builder
  private RequiredNotice_() {
    Column({ space: 6 }) {
      Text(this.requiredNotice.reason || '此更新是继续相关操作所必需的。')
        .fontSize(13).lineHeight(19).fontColor(this.theme.textPrimary).width('100%')
      Text(this.requiredNotice.consequence || '请阅读更新说明，并选择更新或暂不继续。')
        .fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 4 }).id('update-required-notice')
      .accessibilityGroup(true)
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

  /**
   * 发行日期与来源改为按需读取；大小仍在版本/条目区显示，不再为元数据预留页头第二行。
   * 缺失字段不补示例值；此入口只展示已有发行事实，不触发下载、授权或安装流程。
   */
  private showReleaseDetails_(): void {
    this.detailsExpanded = !this.detailsExpanded;
  }

  /** 发行详情使用同一行的独立触点，标题宽度不足时省略标题，不生成另一行说明。 */
  @Builder
  private ReleaseDetailsButton_() {
    Button({ type: ButtonType.Normal }) {
      AppIcon({ name: AppIconName.Info, iconSize: 18, color: this.theme.textSecondary })
    }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText('查看发行信息、日期与下载大小')
      .onClick((): void => { this.showReleaseDetails_(); })
  }

  build() {
    Column() {
      if (this.isAppUpdate()) {
        if (this.selfUpdating && this.selfUpdateParams !== undefined) {
          SideloadUpdateContent({ params: this.selfUpdateParams, currentVersion: this.currentVersion,
            sizeLabel: this.sizeLabel, releaseDate: this.releaseDate, compact: this.appFrame().compact,
            onDismiss: (): void => { this.onLater(); },
            onExitGuardReady: (exit: () => boolean): void => { this.exitSelfUpdate = exit; } })
            .width('100%').height('100%')
        } else {
          this.appDiscoveryPanel()
        }
      } else {
        // JDK 条目是独立安装任务，继续使用其原列表、选择状态和宿主回调。
        this.discoveryPanel()
      }
    }
    .width(this.isAppUpdate() ? this.appFrame().width : '88%')
    .height(this.appFrame().height)
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
          AppIcon({ name: this.isRequired_() ? AppIconName.Warning : AppIconName.CloudDownload,
            iconSize: 22, color: this.isRequired_() ? this.theme.warningText : this.theme.actionText })
        }.width(this.appFrame().compact ? 36 : 44).height(this.appFrame().compact ? 36 : 44)
          .backgroundColor(this.isRequired_() ? this.theme.warningBg : this.theme.primaryLight).borderRadius(16)
        Text(this.headline_()).fontSize(18).fontWeight(700).fontColor(this.theme.textPrimary)
          .maxLines(this.isRequired_() ? 2 : 1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        this.ReleaseDetailsButton_()
      }.width('100%').height(44).alignItems(VerticalAlign.Center).flexShrink(0)
      Column({ space: 4 }) {
        Text(this.appVersionLabel(this.newVersion)).fontSize(24).fontWeight(FontWeight.Medium).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text('当前 ' + this.appVersionLabel(this.currentVersion) + (this.sizeLabel.length > 0 ? ' · ' + this.sizeLabel : ''))
          .fontSize(12).fontColor(this.theme.textSecondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').height(52).alignItems(HorizontalAlign.Start).flexShrink(0)
      Scroll() {
        Column({ space: 10 }) {
          if (this.isRequired_()) { this.RequiredNotice_(); }
          Row() {
            Text('本次更新').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
            Text('共 ' + this.entries.length + ' 项').fontSize(12).fontColor(this.theme.textSecondary)
          }.width('100%')
          if (this.entries.length > 0) {
            ForEach(this.detailsExpanded ? this.entries : this.entries.slice(0, 3), (entry: UpdateNoteEntry) => {
              Row({ space: 10 }) {
                Stack() {
                  AppIcon({ name: this.noteIcon(entry.type), iconSize: 16, color: changelogTone(entry.type, this.theme).color })
                }.width(24).height(24)
                Column({ space: 1 }) {
                  if (this.detailsExpanded) {
                    Text(noteTypeLabel(entry.type)).fontSize(12).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
                  }
                  Text(entry.text).fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').alignItems(VerticalAlign.Top)
            }, (entry: UpdateNoteEntry, index: number): string => index + ':' + entry.text)
          } else {
            Text(this.emptyNotesLabel).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
          }
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      if (this.detailsExpanded) {
        Text([this.releaseDate, this.sourceLabel].filter((value: string): boolean => value.length > 0).join(' · '))
          .fontSize(12).fontColor(this.theme.textSecondary).width('100%').maxLines(2)
      }
      Divider().color(this.theme.divider).strokeWidth(0.5).flexShrink(0)
      Row() {
        if (this.showChangelogEntry) {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.History, iconSize: 14, color: this.theme.actionText })
            Text('查看完整更新日志').fontSize(12).fontColor(this.theme.actionText)
          }.height(32).onClick((): void => { this.onViewChangelog(); }).accessibilityGroup(true)
        }
        Blank()
        if (this.showManualDownload) {
          Text('自行下载 ↗').fontSize(12).fontColor(this.theme.actionText).height(32)
            .onClick((): void => { this.onManualDownload(); }).accessibilityText('自行下载，打开外部下载页面')
        }
      }.width('100%').height(32).alignItems(VerticalAlign.Center).flexShrink(0)
      Row({ space: 10 }) {
          Button(this.secondaryLabel_()).type(ButtonType.Normal).borderRadius(12).layoutWeight(1)
            .height(this.appFrame().compact ? 44 : 46).fontSize(14)
            .backgroundColor(this.theme.bgInput).fontColor(this.theme.textSecondary)
            .onClick((): void => { this.onLater(); })
        Button() {
          Row({ space: 6 }) {
            AppIcon({ name: AppIconName.Download, iconSize: 16, color: this.theme.textOnPrimary })
            Text(this.appActionLabel()).fontSize(14).fontWeight(600).fontColor(this.theme.textOnPrimary)
          }
        }.type(ButtonType.Normal).borderRadius(12).layoutWeight(1)
          .height(this.appFrame().compact ? 44 : 46).backgroundColor(this.theme.actionPrimary)
          .onClick((): void => { this.selfUpdating = true; })
      }.width('100%').height(this.appFrame().compact ? 44 : 46).flexShrink(0)
    }.width('100%').height('100%')
      .padding({ left: this.appFrame().compact ? 12 : 20, right: this.appFrame().compact ? 12 : 20,
        top: this.appFrame().compact ? 12 : 20, bottom: this.appFrame().compact ? 12 : 16 })
  }

  /**
   * 通用发现态保留原条目选择与宿主回调，正文成为唯一滚动区，页头和操作始终可达。
   * 必需提醒和普通提醒共享同一外框；长原因/多槽位只增加滚动内容，不将按钮挤出窗口。
   */
  @Builder
  private discoveryPanel() {
    Column({ space: this.appFrame().compact ? 8 : 12 }) {
      Row({ space: 10 }) {
        Stack() {
          AppIcon({ name: this.isRequired_() ? AppIconName.Warning : AppIconName.CloudDownload,
            iconSize: 22, color: this.isRequired_() ? this.theme.warningText : this.theme.actionText })
        }.width(40).height(40).borderRadius(14)
          .backgroundColor(this.isRequired_() ? this.theme.warningBg : this.theme.primaryLight)
        Text(this.headline_()).fontSize(18).fontWeight(700).fontColor(this.theme.textPrimary)
          .maxLines(this.isRequired_() ? 2 : 1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        this.ReleaseDetailsButton_()
      }.width('100%').height(44).alignItems(VerticalAlign.Center).flexShrink(0)
      Scroll() {
        Column({ space: 12 }) {
          if (this.isRequired_()) { this.RequiredNotice_(); }
          if (this.items.length === 0) {
            Row({ space: 8 }) {
              Text(this.appVersionLabel(this.currentVersion)).fontSize(13).fontColor(this.theme.textSecondary).layoutWeight(1)
              AppIcon({ name: AppIconName.ArrowRight, iconSize: 16, color: this.theme.textHint })
              Text(this.appVersionLabel(this.newVersion)).fontSize(13).fontWeight(600)
                .fontColor(this.theme.actionText).layoutWeight(1).textAlign(TextAlign.End)
            }.width('100%').padding(12).backgroundColor(this.theme.bgInput).borderRadius(12)
          } else if (this.newVersion.length > 0) {
            Text(this.newVersion).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
          }
          Row() {
            Text('更新内容').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
            Text('共 ' + (this.items.length > 0 ? this.items.length : this.entries.length) + ' 项')
              .fontSize(12).fontColor(this.theme.textSecondary)
          }.width('100%')
          ForEach(this.items, (item: UpdateDialogItem) => {
            Row({ space: 8 }) {
              Checkbox({ name: item.id }).select(this.selectedItems.indexOf(item.id) >= 0)
                .selectedColor(this.theme.actionText)
                .onChange((selected: boolean): void => {
                  this.selectNoticeItem_(item.id, selected);
                })
              Column({ space: 4 }) {
                Text(item.title + (item.sizeLabel.length > 0 ? ' · ' + item.sizeLabel : ''))
                  .fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
                if (this.detailsExpanded) {
                  Text(item.current + ' → ' + item.target).fontSize(12).fontColor(this.theme.textHint).width('100%')
                }
                Text(item.description).fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%')
                  .maxLines(this.detailsExpanded ? 50 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').alignItems(VerticalAlign.Top)
          }, (item: UpdateDialogItem): string => item.id)
          ForEach(this.entries, (entry: UpdateNoteEntry) => {
            Row({ space: 8 }) {
              Text(noteTypeLabel(entry.type)).fontSize(12).fontWeight(600)
                .fontColor(changelogTone(entry.type, this.theme).color)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(6)
                .backgroundColor(changelogTone(entry.type, this.theme).bg)
              Text(entry.text).fontSize(13).lineHeight(19).fontColor(this.theme.textSecondary).layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Top)
          }, (entry: UpdateNoteEntry, index: number): string => index + ':' + entry.text)
          if (this.items.length === 0 && this.entries.length === 0) {
            Text(this.emptyNotesLabel).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).id('update-reminder-content')
      if (this.detailsExpanded) {
        Text([this.releaseDate, this.sourceLabel].filter((value: string): boolean => value.length > 0).join(' · '))
          .fontSize(12).fontColor(this.theme.textSecondary).width('100%').maxLines(2)
      }
      Divider().color(this.theme.divider).strokeWidth(0.5).flexShrink(0)
      if (this.items.length > 0) {
        Button(this.detailsExpanded ? '收起详细说明' : '查看详细说明').height(40).fontSize(12)
          .padding({ left: 0, right: 0 }).backgroundColor(Color.Transparent).fontColor(this.theme.actionText)
          .onClick((): void => { this.showReleaseDetails_(); }).alignSelf(ItemAlign.Start).flexShrink(0)
      }
      if (this.showChangelogEntry || this.showManualDownload) {
        Row() {
          if (this.showChangelogEntry) {
            Text('查看完整更新日志').fontSize(12).fontColor(this.theme.actionText).height(32)
              .onClick((): void => { this.onViewChangelog(); })
          }
          Blank()
          if (this.showManualDownload) {
            Text('自行下载 ↗').fontSize(12).fontColor(this.theme.actionText).height(32)
              .onClick((): void => { this.onManualDownload(); })
          }
        }.width('100%').height(32).flexShrink(0)
      }
      Row({ space: 10 }) {
        Button(this.secondaryLabel_()).type(ButtonType.Normal).borderRadius(12).layoutWeight(1).height(46)
          .fontSize(14).backgroundColor(this.theme.bgInput).fontColor(this.theme.textSecondary)
          .id('update-reminder-secondary').onClick((): void => { this.onLater(); })
        Button(this.actionLabel || (this.isRequired_() ? '立即更新' : '前往下载'))
          .type(ButtonType.Normal).borderRadius(12).layoutWeight(1).height(46).fontSize(14).fontWeight(600)
          .backgroundColor(this.theme.actionPrimary).fontColor(this.theme.textOnPrimary)
          .enabled(this.items.length === 0 || this.selectedItems.length > 0).id('update-reminder-primary')
          .onClick((): void => {
            if (this.items.length > 0) { this.onInstallItems(this.selectedItems.slice()); return; }
            this.onDownload();
          })
      }.width('100%').height(46).flexShrink(0)
    }.width('100%').height('100%')
      .padding({ left: this.appFrame().compact ? 12 : 20, right: this.appFrame().compact ? 12 : 20,
        top: this.appFrame().compact ? 12 : 20, bottom: 16 })
  }
}

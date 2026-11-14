/**
 * 活动账本占用与保留面板：用概览、提醒设置和按版本折叠卡呈现当前本地占用。
 * 本轮只重绘展示与滚动结构，异步保留事务、清理策略与空间提醒值仍由既有账本层持有。
 */
/** 活动账本占用面板。统计异步、离页取消；只操作保留设置和提醒，删除在活动详情确认。 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
import { AppIcon } from './AppIcon';
import { ThemeColors, AppIconName, ActivityStorageGroup, ActivityStorageItem, readActivityStorage, formatLogBytes,
  activityStorageAlert, setActivityStorageAlert, ledgerSetPinnedAsync } from 'commons';

/** 按引用传递的分组展示参数；状态刷新不会被按值 Builder 参数截断。 */
interface ActivityStorageGroupView { group: ActivityStorageGroup; }

@Component
export struct ActivityStoragePanel {
  @Prop theme: ThemeColors = new ThemeColors();
  onOpenActivity: (activityId: number) => void = () => {};
  /** 只收起原账本占用 Sheet；选择活动后的延迟导航仍由宿主 onDisappear 执行。 */
  onClose: () => void = () => {};
  @State private groups: ActivityStorageGroup[] = [];
  @State private total: number = 0;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private alertBytes: number = 0;
  @State private expandedKey: string = '';
  private active: boolean = false;
  private generation: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');

  aboutToAppear(): void { this.active = true; this.refresh_(); }
  aboutToDisappear(): void { this.active = false; this.generation++; this.busy = false; }

  private async refresh_(): Promise<void> {
    const context = this.context;
    if (context === undefined || this.busy) return;
    const generation: number = ++this.generation;
    this.busy = true; this.error = ''; this.alertBytes = activityStorageAlert(context.filesDir);
    try {
      const result = await readActivityStorage(context.filesDir, (): boolean => !this.active || generation !== this.generation);
      if (!this.active || generation !== this.generation) return;
      this.groups = result.groups; this.total = result.bytes; this.error = result.issues.join('；');
    } catch (e) { if (this.active && generation === this.generation) this.error = '占用统计未完成：' + (e as Error).message; }
    finally { if (generation === this.generation) this.busy = false; }
  }

  private chooseAlert_(): void {
    const sizes: number[] = [0, 256, 512, 1024, 2048];
    this.getUIContext().getPromptAction().showActionMenu({ title: '账本占用提醒（不会自动删除）',
      // 系统 action menu 使用有界元组（至少一项、最多六项），不能传可能为空的普通数组。
      buttons: [{ text: '不提醒', color: this.theme.actionText as string },
        { text: '256 MiB', color: this.theme.actionText as string }, { text: '512 MiB', color: this.theme.actionText as string },
        { text: '1 GiB', color: this.theme.actionText as string }, { text: '2 GiB', color: this.theme.actionText as string }]
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (this.context === undefined || !this.active) return;
      try { setActivityStorageAlert(this.context.filesDir, sizes[result.index] * 1024 * 1024); this.alertBytes = sizes[result.index] * 1024 * 1024; }
      catch (e) { this.error = '提醒设置未保存：' + (e as Error).message; }
    }).catch((): void => {});
  }

  /**
   * 保留修改排入本活动canonical写门，等待耐久完成再刷新；不能同步覆盖恢复事务的旧快照。
   * 忙态挡住重复点击，离页只撤销展示资格，不撤销用户已派发的持久保存意图。
   */
  private async pin_(item: ActivityStorageItem): Promise<void> {
    if (this.context === undefined || this.busy || !this.active) return;
    const generation: number = ++this.generation;
    this.busy = true; this.error = '';
    let saved: boolean = false;
    try {
      await ledgerSetPinnedAsync(this.context.filesDir, item.activityId, !item.pinned);
      saved = true;
    } catch (e) {
      if (this.active && generation === this.generation) this.error = '保留设置未保存：' + (e as Error).message;
    } finally {
      if (this.active && generation === this.generation) {
        this.busy = false;
        if (saved) await this.refresh_();
      }
    }
  }

  build() {
    Column() {
    ImmersiveTitleScaffold({ title: '账本占用与保留', theme: this.theme, surfaceColor: this.theme.bgPrimary,
      modal: true, closeLabel: '关闭账本占用与保留', onClose: (): void => { this.onClose(); },
      content: (): void => { this.ImmersiveTitleContent1_(); }
    })
    }.width('100%').height('100%')
  }

  /**
   * 占用概览只展示真实可读的分组总量。未知占用不画成零宽度比例，避免给出虚假的完整统计。
   * 比例条只是当前 readActivityStorage 快照的可视化，不改变保留预算或引入自动删除。
   */
  @Builder
  private StorageSummary_() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 6 }) {
          Text('本地日志占用').fontSize(12).fontColor(this.theme.textSecondary)
          Text(this.busy && this.groups.length === 0 ? '正在统计…' : this.total < 0 ? '占用暂不可读' : formatLogBytes(this.total))
            .fontSize(28).fontWeight(600).fontColor(this.theme.textPrimary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button() { AppIcon({ name: AppIconName.Refresh, iconSize: 22, color: this.theme.actionText }) }
          .width(44).height(44).padding(0).borderRadius(22).backgroundColor(this.theme.bgCard)
          .enabled(!this.busy).accessibilityText('刷新账本占用').onClick(() => { this.refresh_(); })
      }.width('100%')
      if (this.total > 0 && this.groups.length > 0 && this.groups.every((group: ActivityStorageGroup): boolean => group.bytes >= 0)) {
        Row({ space: 3 }) {
          ForEach(this.groups, (group: ActivityStorageGroup, index: number) => {
            if (group.bytes > 0) {
              Row().height(8).layoutWeight(group.bytes / this.total)
                .backgroundColor(index === 0 ? this.theme.actionPrimary : index === 1 ? this.theme.primaryLight : this.theme.divider)
            }
          }, (group: ActivityStorageGroup): string => group.key)
        }.width('100%').height(8).borderRadius(4).clip(true)
      }
      Text(this.groups.length + ' 个版本 / 活动分组').fontSize(12).fontColor(this.theme.textSecondary)
    }.width('100%').padding(20).alignItems(HorizontalAlign.Start).backgroundColor(this.theme.bgPrimary).borderRadius(18)
  }

  /**
   * 分组标题与其活动明细放在同一张卡内。展开只改变展示状态，打开活动和耐久保留事务
   * 仍调用原入口；进行中、已保留与未知占用分别表达，不能用颜色或数值代替真实状态。
   */
  @Builder
  private StorageGroup_(params: ActivityStorageGroupView) {
    Column({ space: 0 }) {
      Button() {
        Row({ space: 12 }) {
          Column({ space: 6 }) {
            Text(params.group.title || '其他活动').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            Text((params.group.bytes < 0 ? '占用未知' : formatLogBytes(params.group.bytes)) + ' · ' + params.group.items.length + ' 条')
              .fontSize(12).fontColor(this.theme.textSecondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          AppIcon({ name: this.expandedKey === params.group.key ? AppIconName.ChevronUp : AppIconName.ChevronDown,
            iconSize: 18, color: this.theme.textSecondary })
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 72 }).padding(16).borderRadius(14)
        .backgroundColor(Color.Transparent).accessibilityText((this.expandedKey === params.group.key ? '收起' : '展开') + (params.group.title || '其他活动'))
        .onClick(() => { this.expandedKey = this.expandedKey === params.group.key ? '' : params.group.key; })
      if (this.expandedKey === params.group.key) {
        ForEach(params.group.items, (item: ActivityStorageItem) => {
          Row({ space: 8 }) {
            Button() {
              Column({ space: 5 }) {
                Text(new Date(item.activityId).toLocaleString()).fontSize(14).fontColor(this.theme.textPrimary)
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text((item.bytes < 0 ? '占用未知' : formatLogBytes(item.bytes)) + (item.running ? ' · 进行中' : '')
                  + (item.pinned ? ' · 已保留' : '')).fontSize(12).fontColor(this.theme.textSecondary)
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.layoutWeight(1).constraintSize({ minHeight: 64 }).padding({ top: 12, bottom: 12 })
              .backgroundColor(Color.Transparent).borderRadius(8).onClick(() => { this.onOpenActivity(item.activityId); })
            Button(item.pinned ? '取消保留' : '保留').height(44).fontSize(12).fontWeight(600).enabled(!this.busy)
              .padding({ left: 16, right: 16 }).borderRadius(22)
              .backgroundColor(item.pinned ? this.theme.primaryLight : this.theme.bgCard).fontColor(this.theme.actionText)
              .onClick(() => { this.pin_(item); })
          }.width('100%').border({ width: { top: 1 }, color: this.theme.divider })
            .padding({ left: 16, right: 16 })
        }, (item: ActivityStorageItem): string => String(item.activityId))
      }
    }.width('100%').backgroundColor(this.theme.bgPrimary).borderRadius(14).clip(true)
  }

  /**
   * 概览、提醒和版本卡共用一个列表滚动轴，手机面板较矮时仍能读到完整内容。
   * 不再把高度固定的统计区挤在列表上方；标题、关闭和异步状态所有权继续由原宿主管理。
   */
  @Builder
  private ImmersiveTitleContent1_() {
      List({ space: 12 }) {
        ListItem() { this.StorageSummary_() }
        ListItem() {
          Button() {
            Row({ space: 12 }) {
              AppIcon({ name: AppIconName.Notification, iconSize: 22, color: this.theme.actionText })
              Column({ space: 5 }) {
                Text('空间提醒 · ' + (this.alertBytes === 0 ? '未设置' : formatLogBytes(this.alertBytes)))
                  .fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
                Text('达到阈值时提醒，不会自动删除').fontSize(12).fontColor(this.theme.textSecondary)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textSecondary })
            }.width('100%')
          }.width('100%').constraintSize({ minHeight: 72 }).padding(16).backgroundColor(this.theme.bgPrimary)
            .borderRadius(14).enabled(!this.busy).onClick(() => { this.chooseAlert_(); })
        }
        if (this.alertBytes > 0 && this.total >= this.alertBytes) {
          ListItem() {
            Text('日志占用已达到提醒阈值。可以查看较大的版本，或在活动详情中清理不需要的记录。')
              .fontSize(12).fontColor(this.theme.warningText).width('100%').padding(12)
              .backgroundColor(this.theme.warningBg).borderRadius(12)
          }
        }
        if (this.busy) { ListItem() { LoadingProgress().width(28).height(28).color(this.theme.actionText) } }
        if (this.error.length > 0) {
          ListItem() { Text(this.error).fontSize(12).fontColor(this.theme.warningText).width('100%') }
        }
        ListItem() { Text('按版本查看').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).padding({ top: 8, bottom: 4 }) }
        ForEach(this.groups, (group: ActivityStorageGroup) => {
          ListItem() { this.StorageGroup_({ group: group }) }
        }, (group: ActivityStorageGroup): string => group.key)
        ListItem() {
          Text('游戏按每版本保留数量；已保留和运行中的活动不会自动清理。普通活动的 64 MiB 预算不限制游戏总占用。')
            .fontSize(12).fontColor(this.theme.textSecondary).width('100%').padding({ top: 8, bottom: 12 })
        }
      }.width('100%').height('100%').padding({ top: 12, left: 20, right: 20, bottom: 16 })
        .backgroundColor(this.theme.bgCard).scrollBar(BarState.Auto)
  }
}

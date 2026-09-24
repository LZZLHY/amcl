/** 活动账本占用面板。统计异步、离页取消；只操作保留设置和提醒，删除在活动详情确认。 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { ThemeColors, ActivityStorageGroup, ActivityStorageItem, readActivityStorage, formatLogBytes,
  activityStorageAlert, setActivityStorageAlert, ledgerSetPinned } from 'commons';

@Component
export struct ActivityStoragePanel {
  @Prop theme: ThemeColors = new ThemeColors();
  onOpenActivity: (activityId: number) => void = () => {};
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
  aboutToDisappear(): void { this.active = false; this.generation++; }

  private async refresh_(): Promise<void> {
    const context = this.context;
    if (context === undefined || this.busy) return;
    const generation: number = ++this.generation;
    this.busy = true; this.error = ''; this.alertBytes = activityStorageAlert(context.filesDir);
    try {
      const result = await readActivityStorage(context.filesDir, (): boolean => !this.active || generation !== this.generation);
      if (!this.active || generation !== this.generation) return;
      this.groups = result.groups; this.total = result.bytes; this.error = result.issues.join('；');
    } catch (e) { if (this.active) this.error = '占用统计未完成：' + (e as Error).message; }
    finally { if (generation === this.generation) this.busy = false; }
  }

  private chooseAlert_(): void {
    const sizes: number[] = [0, 256, 512, 1024, 2048];
    this.getUIContext().getPromptAction().showActionMenu({ title: '账本占用提醒（不会自动删除）',
      // 系统 action menu 使用有界元组（至少一项、最多六项），不能传可能为空的普通数组。
      buttons: [{ text: '不提醒', color: this.theme.primary as string },
        { text: '256 MiB', color: this.theme.primary as string }, { text: '512 MiB', color: this.theme.primary as string },
        { text: '1 GiB', color: this.theme.primary as string }, { text: '2 GiB', color: this.theme.primary as string }]
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (this.context === undefined || !this.active) return;
      try { setActivityStorageAlert(this.context.filesDir, sizes[result.index] * 1024 * 1024); this.alertBytes = sizes[result.index] * 1024 * 1024; }
      catch (e) { this.error = '提醒设置未保存：' + (e as Error).message; }
    }).catch((): void => {});
  }

  private pin_(item: ActivityStorageItem): void {
    if (this.context === undefined || this.busy) return;
    try { ledgerSetPinned(this.context.filesDir, item.activityId, !item.pinned); this.refresh_(); }
    catch (e) { this.error = '保留设置未保存：' + (e as Error).message; }
  }

  build() {
    Column({ space: 12 }) {
      Text('账本占用与保留').fontSize(22).fontWeight(600).fontColor(this.theme.textPrimary).width('100%');
      Row() {
        Text(formatLogBytes(this.total)).fontSize(24).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1);
        Button('刷新').height(44).enabled(!this.busy).onClick(() => { this.refresh_(); });
      }.width('100%');
      Text('游戏按每版本保留数量；已保留和运行中的活动不会自动清理。普通活动的 64 MiB 预算不限制游戏总占用。')
        .fontSize(12).fontColor(this.theme.textSecondary).width('100%');
      Button('空间提醒：' + (this.alertBytes === 0 ? '未设置' : formatLogBytes(this.alertBytes)))
        .height(44).onClick(() => { this.chooseAlert_(); });
      if (this.alertBytes > 0 && this.total >= this.alertBytes) {
        Text('日志占用已达到提醒阈值。可以查看较大的版本，或在活动详情中清理不需要的记录。')
          .fontSize(13).fontColor(this.theme.warning).width('100%');
      }
      if (this.busy) { LoadingProgress().width(28).height(28).color(this.theme.primary); }
      if (this.error.length > 0) { Text(this.error).fontSize(12).fontColor(this.theme.warning).width('100%'); }
      List({ space: 12 }) {
        ForEach(this.groups, (group: ActivityStorageGroup) => {
          ListItem() {
            Column({ space: 8 }) {
              Button() {
                Row({ space: 8 }) {
                  Text(group.title || '其他活动').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
                  Text(formatLogBytes(group.bytes) + ' · ' + group.items.length + ' 条').fontSize(12).fontColor(this.theme.primary);
                }.width('100%');
              }.width('100%').padding(12).backgroundColor(this.theme.bgCard).onClick(() => { this.expandedKey = this.expandedKey === group.key ? '' : group.key; });
              if (this.expandedKey === group.key) {
                ForEach(group.items, (item: ActivityStorageItem) => {
                  Row({ space: 8 }) {
                    Button() {
                      Column({ space: 4 }) {
                        Text(new Date(item.activityId).toLocaleString()).fontSize(12).fontColor(this.theme.textPrimary);
                        Text(formatLogBytes(item.bytes) + (item.running ? ' · 进行中' : '')).fontSize(12).fontColor(this.theme.textSecondary);
                      }.alignItems(HorizontalAlign.Start);
                    }.layoutWeight(1).height(52).backgroundColor(Color.Transparent).onClick(() => { this.onOpenActivity(item.activityId); });
                    Button(item.pinned ? '取消保留' : '保留').height(44).fontSize(12).enabled(!this.busy)
                      .backgroundColor(this.theme.primaryLight).fontColor(this.theme.primary).onClick(() => { this.pin_(item); });
                  }.width('100%');
                }, (item: ActivityStorageItem): string => String(item.activityId));
              }
            }.width('100%');
          }
        }, (group: ActivityStorageGroup): string => group.key);
      }.width('100%').layoutWeight(1);
    }.width('100%').height('100%').padding(20).alignItems(HorizontalAlign.Start).backgroundColor(this.theme.bgPrimary);
  }
}

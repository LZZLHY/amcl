import { common } from '@kit.AbilityKit';
import {
  ThemeColors, ThemeMode, resolveTheme, formatLogBytes,
  ledgerList, ledgerManifest, ledgerTotalBytes, ledgerSessionRetention,
  ledgerSetSessionRetention, LedgerState, SESSION_RETENTION_DEFAULT,
  ledgerRetentionVictims, ledgerBytesOf, EARLY_SESSION_RETENTION,
} from 'commons';

@Component
export struct LogRetentionSettings {
  @Prop theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @State private retained: number = SESSION_RETENTION_DEFAULT;
  @State private actualBytes: number = 0;
  @State private sessionCount: number = 0;
  @State private estimatedPerSlot: number = 0;
  @State private versionCount: number = 0;
  @State private errorText: string = '';
  @State private saving: boolean = false;
  @StorageLink('activityLedgerRevision') @Watch('refresh') ledgerRevision: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');

  aboutToAppear(): void { this.refresh(); }

  refresh(): void {
    const context = this.context;
    if (context === undefined) return;
    try {
      this.retained = ledgerSessionRetention(context.filesDir);
      this.actualBytes = ledgerTotalBytes(context.filesDir);
      const totals = new Map<string, number>();
      const counts = new Map<string, number>();
      let sessions = 0;
      for (const entry of ledgerList(context.filesDir)) {
        if (entry.category !== 'launch' || entry.state === LedgerState.RUNNING || !entry.hasGame) continue;
        const manifest = ledgerManifest(context.filesDir, entry.activityId);
        if (manifest === null) continue;
        const key = manifest.mcDir + '\n' + manifest.gameVersionId;
        totals.set(key, (totals.get(key) ?? 0) + entry.bytes);
        counts.set(key, (counts.get(key) ?? 0) + 1);
        sessions++;
      }
      let perSlot = 0;
      totals.forEach((bytes: number, key: string) => { perSlot += bytes / (counts.get(key) ?? 1); });
      this.estimatedPerSlot = perSlot;
      this.versionCount = totals.size;
      this.sessionCount = sessions;
      this.errorText = '';
    } catch (e) { this.errorText = '无法读取日志占用：' + (e as Error).message; }
  }

  /** 减少保留窗口前预览真实淘汰集合；确认期间集合变化则要求重新操作，不扩大删除范围。 */
  private async save(value: number): Promise<void> {
    const context = this.context;
    if (context === undefined || this.saving) return;
    this.saving = true;
    try {
      const victims: number[] = ledgerRetentionVictims(context.filesDir, Math.round(value));
      if (victims.length > 0) {
        let bytes: number = 0;
        for (const id of victims) bytes += ledgerBytesOf(context.filesDir, id);
        const result = await this.getUIContext().getPromptAction().showDialog({
          title: '调整日志保留数量？',
          message: '将清理 ' + victims.length + ' 条已结束的本地记录，释放约 ' + formatLogBytes(bytes)
            + '。在线分享不受影响。',
          buttons: [{ text: '取消', color: this.theme.primary as string }, { text: '应用并清理', color: this.theme.error as string }],
        });
        if (result.index !== 1) { this.refresh(); return; }
        const current: number[] = ledgerRetentionVictims(context.filesDir, Math.round(value));
        if (current.some((id: number): boolean => victims.indexOf(id) < 0)) {
          this.refresh();
          this.errorText = '日志记录已变化，请重新调整并检查清理范围。';
          return;
        }
      }
      ledgerSetSessionRetention(context.filesDir, Math.round(value));
      this.refresh();
    } catch (e) {
      this.retained = ledgerSessionRetention(context.filesDir);
      this.errorText = '保存失败：' + (e as Error).message;
    } finally { this.saving = false; }
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('游戏日志保留').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1);
        Text(this.retained + ' 局 / 版本').fontSize(15).fontWeight(600).fontColor(this.theme.primary);
      }.width('100%').height(40);
      Slider({ value: this.retained, min: 5, max: 100, step: 1 })
        .enabled(!this.saving)
        .id('log-retention-slider').width('100%').height(40)
        .trackColor(this.theme.bgInput).selectedColor(this.theme.primary)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.retained = Math.round(value);
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.save(value);
        });
      Row() {
        Text('5 局 · 默认').fontSize(12).fontColor(this.theme.textHint);
        Blank();
        Text('100 局').fontSize(12).fontColor(this.theme.textHint);
      }.width('100%');
      Text('每个版本保留最近的完整游戏日志；另保留最近 ' + EARLY_SESSION_RETENTION
        + ' 次早期启动记录。减少数量时先确认清理范围。')
        .fontSize(12).lineHeight(18).fontColor(this.theme.textSecondary).width('100%');
      Text('日志实际占用 ' + formatLogBytes(this.actualBytes) + ' · 已归档 ' + this.sessionCount + ' 局')
        .fontSize(12).fontColor(this.theme.textSecondary).width('100%');
      Text(this.sessionCount === 0 ? '游玩并归档后，可根据日志大小估算空间。'
        : this.versionCount + ' 个版本各保留 ' + this.retained + ' 局，预计游戏日志占用 '
          + formatLogBytes(this.estimatedPerSlot * this.retained) + '；实际随游玩时长变化。')
        .fontSize(12).lineHeight(18).fontColor(this.theme.textHint).width('100%');
      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(12).fontColor(this.theme.error).width('100%');
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 8, bottom: 16 });
  }
}

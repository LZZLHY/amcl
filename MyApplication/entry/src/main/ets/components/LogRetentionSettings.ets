import { LauncherSkillBus } from '../launcherskill/LauncherSkillBus';
import { settingFailure, settingKeys, settingText, SettingsSkillData } from '../launcherskill/SettingsSkillValues';
import { common } from '@kit.AbilityKit';
import {
  ThemeColors, ThemeMode, resolveTheme, formatLogBytes,
  ledgerListAsync, ledgerSessionRetentionAsync, ledgerSetSessionRetentionAsync,
  LedgerState, LedgerEntry, SESSION_RETENTION_DEFAULT,
  ledgerRetentionVictimsAsync, EARLY_SESSION_RETENTION,
} from 'commons';

@Component
export struct LogRetentionSettings {
  @Prop theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false);
  @State private retained: number = SESSION_RETENTION_DEFAULT;
  /** 滑动中的值只用于预览；retained 仅由真实账本读回更新。 */
  @State private sliderDraft_: number | undefined = undefined;
  @State private actualBytes: number = 0;
  @State private sessionCount: number = 0;
  @State private estimatedPerSlot: number = 0;
  @State private versionCount: number = 0;
  @State private errorText: string = '';
  @State private saving: boolean = false;
  @State private loading_: boolean = false;
  /** 每轮索引读取的可信标记与 UI 最近一次可展示数据分别维护。 */
  private skillReadValid_: boolean = false;
  /** 设置页隐藏仍可能留在Tab树；revision只在组件/宿主/应用和设置Tab均可见时消费。 */
  @StorageProp('amclSettingsTabVisible') @Watch('visibilityChanged_') private settingsVisible_: boolean = false;
  @StorageProp('amclHostPageVisible') @Watch('visibilityChanged_') private hostVisible_: boolean = false;
  @StorageProp('appInForeground') @Watch('visibilityChanged_') private foreground_: boolean = false;
  @StorageLink('activityLedgerRevision') @Watch('refresh') ledgerRevision: number = 0;
  private active_: boolean = false;
  private readGeneration_: number = 0;
  private saveGeneration_: number = 0;
  private context: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');

  aboutToAppear(): void {
    LauncherSkillBus.bind('settingsRetention',this,(method: string,args: SettingsSkillData): Promise<SettingsSkillData> =>
      this.skillAction_(method,args), (): boolean => this.visible_());
    this.active_ = true; this.refresh();
  }
  aboutToDisappear(): void {
    LauncherSkillBus.unbind('settingsRetention',this);
    this.active_ = false; this.invalidate_();
  }

  /** 可见性只控制读取与UI发布，已派发的耐久设置保存仍由原owner完成。 */
  private visible_(): boolean { return this.active_ && this.settingsVisible_ && this.hostVisible_ && this.foreground_; }
  private invalidate_(): void {
    this.readGeneration_++; this.saveGeneration_++; this.loading_ = false;
    this.sliderDraft_ = undefined; this.skillReadValid_ = false;
  }
  private visibilityChanged_(): void { if (this.visible_()) this.refresh(); else this.invalidate_(); }

  /** 一次异步索引读取复用可信bytes/versionKey，首开和Watch均不再同步递归整个账本。 */
  /** 减少保留局数时仍由真实账本向用户展示本次淘汰集合并二次核验。 */
  private async skillAction_(method: string,args: SettingsSkillData): Promise<SettingsSkillData> {
    if (this.loading_ || this.saving || !this.visible_()) return settingFailure('busy');
    if (method === 'setGameLogRetention' && settingKeys(args,['count'])) {
      const count = args['count'];
      if (typeof count !== 'number' || !Number.isInteger(count) || count < 5 || count > 100) return settingFailure('invalidCount');
      if (this.sliderDraft_ !== undefined) return { 'state':'busy','reason':'sliderBeingEdited' };
      if ((!this.skillReadValid_ || this.retained !== count) && !await this.save(count,true)) return settingFailure('changeNotCommitted');
    } else if (method !== 'getGameLogRetention' || !settingKeys(args,[])) return settingFailure('invalidArguments');
    if (!this.skillReadValid_) return {'state':'unknown','reason':'retentionUnreadable'};
    return {'state':'ready','count':this.retained,'bytes':this.actualBytes,'archivedSessions':this.sessionCount,
      'versionCount':this.versionCount,'estimatedBytesPerSlot':this.estimatedPerSlot,'incomplete':this.errorText.length > 0};
  }

  async refresh(): Promise<void> {
    const context = this.context;
    if (context === undefined || !this.visible_() || this.saving) return;
    const generation: number = ++this.readGeneration_;
    const cancelled: () => boolean = (): boolean => !this.visible_() || generation !== this.readGeneration_;
    this.loading_ = true;
    this.skillReadValid_ = false;
    try {
      const retained: number = await ledgerSessionRetentionAsync(context.filesDir);
      const entries: LedgerEntry[] = await ledgerListAsync(context.filesDir, cancelled);
      if (cancelled()) return;
      const unknown: boolean = entries.some((entry: LedgerEntry): boolean => entry.bytesState !== 'current');
      const actualBytes: number = unknown ? -1 : entries.reduce((sum: number, entry: LedgerEntry): number => sum + entry.bytes, 0);
      const totals = new Map<string, number>();
      const counts = new Map<string, number>();
      let sessions = 0;
      for (const entry of entries) {
        if (entry.category !== 'launch' || entry.state === LedgerState.RUNNING || !entry.hasGame) continue;
        if (entry.bytesState !== 'current' || entry.versionKey === undefined) continue;
        const key: string = entry.versionKey;
        totals.set(key, (totals.get(key) ?? 0) + entry.bytes);
        counts.set(key, (counts.get(key) ?? 0) + 1);
        sessions++;
      }
      let perSlot = 0;
      totals.forEach((bytes: number, key: string) => { perSlot += bytes / (counts.get(key) ?? 1); });
      this.retained = retained;
      this.actualBytes = actualBytes;
      this.estimatedPerSlot = unknown ? -1 : perSlot;
      this.versionCount = totals.size;
      this.sessionCount = sessions;
      this.skillReadValid_ = true;
      this.errorText = unknown ? '部分日志仍在写入或占用无法核实，完整占用与空间预估暂不可读。' : '';
    } catch (e) { if (!cancelled()) this.errorText = '无法读取日志占用：' + (e as Error).message; }
    finally { if (generation === this.readGeneration_) this.loading_ = false; }
  }

  /** 减少保留窗口前预览真实淘汰集合；确认期间集合变化则要求重新操作，不扩大删除范围。 */
  private async save(value: number, fromSkill: boolean = false): Promise<boolean> {
    const context = this.context;
    if (context === undefined || this.saving || !this.visible_()) return false;
    const generation: number = ++this.saveGeneration_;
    const cancelled: () => boolean = (): boolean => !this.visible_() || generation !== this.saveGeneration_;
    this.readGeneration_++;
    this.saving = true;
    let failure: string = '';
    let committed: boolean = false;
    try {
      const victims: number[] = await ledgerRetentionVictimsAsync(context.filesDir, Math.round(value));
      if (cancelled()) return false;
      if (victims.length > 0) {
        const entries: LedgerEntry[] = await ledgerListAsync(context.filesDir, cancelled);
        if (cancelled()) return false;
        const byId: Map<number, LedgerEntry> = new Map<number, LedgerEntry>();
        for (const entry of entries) byId.set(entry.activityId, entry);
        let bytes: number = 0;
        for (const id of victims) {
          const entry: LedgerEntry | undefined = byId.get(id);
          if (entry === undefined || entry.bytesState !== 'current') throw new Error('清理范围占用尚未核实，请刷新后重试');
          bytes += entry.bytes;
        }
        if (fromSkill) LauncherSkillBus.awaitingUser('setGameLogRetention');
        const result = await this.getUIContext().getPromptAction().showDialog({
          title: '调整日志保留数量？',
          message: '将清理 ' + victims.length + ' 条已结束的本地记录，释放约 ' + formatLogBytes(bytes)
            + '。在线分享不受影响。',
          buttons: [{ text: '取消', color: this.theme.actionText as string }, { text: '应用并清理', color: this.theme.errorText as string }],
        });
        if (result.index !== 1 || cancelled()) return false;
        const current: number[] = await ledgerRetentionVictimsAsync(context.filesDir, Math.round(value));
        if (cancelled()) return false;
        if (current.some((id: number): boolean => victims.indexOf(id) < 0)) {
          failure = '日志记录已变化，请重新调整并检查清理范围。';
          return false;
        }
      }
      if (cancelled()) return false;
      // 保存API负责同批末维护并复核pin/running/租约；活跃游戏时只保存设置等待空闲。
      await ledgerSetSessionRetentionAsync(context.filesDir, Math.round(value));
      committed = true;
    } catch (e) {
      if (!cancelled()) failure = '保存失败：' + (e as Error).message;
    } finally {
      this.saving = false;
      if (this.visible_()) {
        await this.refresh();
        if (!cancelled() && failure.length > 0) this.errorText = failure;
      }
    }
    return committed && !cancelled() && this.skillReadValid_ && this.retained === Math.round(value);
  }

  /** 松手前保持草稿，松手和直接点击都走原有清理确认和耐久写入。 */
  private sliderChanged_(value: number, mode: SliderChangeMode): void {
    if (this.saving || !this.visible_()) return;
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.sliderDraft_ = undefined;
      this.save(value);
    } else {
      this.sliderDraft_ = Math.round(value);
    }
  }

  /**
   * 本组件只提供保留策略的组内正文，外层白色分组由设置页承担，避免多层卡片嵌套。
   * 未知占用继续明确显示不可读，读取或保存期间禁用原滑块；减少数量仍走原真实集合确认，
   * 展示层既不把估算写成实际占用，也不改变正在运行、pin或分享记录的保留边界。
   */
  build() {
    Column({ space: 12 }) {
      Row() {
        Text('每个版本保留').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1);
        Text((this.sliderDraft_ ?? this.retained) + ' 局').fontSize(16).fontWeight(600).fontColor(this.theme.actionPrimary);
      }.width('100%').constraintSize({ minHeight: 32 }).alignItems(VerticalAlign.Center);
      Slider({ value: this.sliderDraft_ ?? this.retained, min: 5, max: 100, step: 1 })
        .enabled(!this.saving && !this.loading_)
        .id('log-retention-slider').width('100%').height(48)
        .trackColor(this.theme.bgInput).selectedColor(this.theme.actionText)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.sliderChanged_(value, mode);
        });
      Row() {
        Text('5 局 · 默认').fontSize(14).fontColor(this.theme.textSecondary);
        Blank();
        Text('100 局').fontSize(14).fontColor(this.theme.textSecondary);
      }.width('100%');
      Text('每个版本保留最近的完整游戏日志；另保留最近 ' + EARLY_SESSION_RETENTION
        + ' 次早期启动记录。减少数量时先确认清理范围。')
        .fontSize(14).lineHeight(22).fontColor(this.theme.textSecondary).width('100%');
      Divider().color(this.theme.divider).strokeWidth(0.5);
      Row({ space: 12 }) {
        Text('日志实际占用').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1);
        Text(this.loading_ ? '读取中…' : this.actualBytes < 0 ? '暂不可读' : formatLogBytes(this.actualBytes))
          .fontSize(14).fontColor(this.theme.textSecondary).textAlign(TextAlign.End)
          .constraintSize({ maxWidth: 150 });
      }.width('100%').constraintSize({ minHeight: 32 }).alignItems(VerticalAlign.Center);
      Text('已归档 ' + this.sessionCount + ' 局').fontSize(14).lineHeight(22)
        .fontColor(this.theme.textSecondary).width('100%');
      if (this.loading_) {
        Text('正在读取日志占用与空间预估…').fontSize(14).lineHeight(22)
          .fontColor(this.theme.textSecondary).width('100%');
      } else {
        Text(this.estimatedPerSlot < 0 ? '空间预估需先取得完整可信的日志占用。' : this.sessionCount === 0 ? '游玩并归档后，可根据日志大小估算空间。'
          : this.versionCount + ' 个版本各保留 ' + (this.sliderDraft_ ?? this.retained) + ' 局，预计游戏日志占用 '
            + formatLogBytes(this.estimatedPerSlot * (this.sliderDraft_ ?? this.retained)) + '；实际随游玩时长变化。')
          .fontSize(14).lineHeight(22).fontColor(this.theme.textSecondary).width('100%');
      }
      if (this.saving) {
        Text('正在保存…').fontSize(14).lineHeight(22).fontColor(this.theme.actionPrimary).width('100%');
      }
      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(14).lineHeight(22).fontColor(this.theme.errorText).width('100%');
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20);
  }
}

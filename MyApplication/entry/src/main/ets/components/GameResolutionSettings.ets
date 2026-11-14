import { common } from '@kit.AbilityKit';
import { ThemeColors, splitJvmArguments, resolveResolutionPercent, normalizeResolutionPreference, formatError } from 'commons';
import { PreferenceManager } from 'feature_system';
import { SettingsHint } from './SettingsPrimitives';

/** 一次同步读取的确认快照。0 是继承政策，effectivePercent 是下一次启动解析出的比例。 */
export class GameResolutionPreferenceSnapshot {
  preferencePercent: number;
  effectivePercent: number;

  constructor(preferencePercent: number = 0, effectivePercent: number = 100) {
    this.preferencePercent = normalizeResolutionPreference(preferencePercent);
    this.effectivePercent = normalizeResolutionPreference(effectivePercent) || 100;
  }
}

/**
 * 固定作用域的分辨率编辑器。全局页只修改全局；版本详情显式指定 versionScope/versionId，
 * 不提供能跨作用域误写的切换按钮。版本宿主可注入原偏好 owner 的读写回调，组件只管理
 * 草稿及确认显示；隐藏、换版本或换根目录会使旧 Promise 失去当前页面的显示权。
 */
@Component
export struct GameResolutionSettings {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop @Watch('reload') versionScope: boolean = false;
  @Prop @Watch('reload') versionId: string = '';
  /** 仅绑定页面身份，不作为新的存储键；版本详情使用实际 mcDir。 */
  @Prop @Watch('reload') ownerKey: string = '';
  @Prop @Watch('onVisibilityChanged_') visible: boolean = true;
  /** 仅控制呈现：版本Sheet填满并固定底栏，全局页维持内联布局。 */
  @Prop embedded: boolean = false;
  @Prop bottomSafeHeight: number = 0;
  loadPreference: ((versionId: string, versionScope: boolean) => GameResolutionPreferenceSnapshot) | undefined = undefined;
  savePreference: ((percent: number, versionId: string) => Promise<void>) | undefined = undefined;
  onSaved: (versionId: string, percent: number) => void = () => {};

  @State private draft: number = 100;
  @State private savedPreference: number = 0;
  @State private confirmedEffective: number = 100;
  @State private message: string = '';
  @State private error: string = '';
  @State private saving: boolean = false;
  @State private ready: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  /** 同一可见代次内立即防重；切到另一版本后允许新请求进入原 owner 的串行队列。 */
  private savingGeneration_: number = -1;

  /** 挂载时只读取确认政策，不写偏好或更改游戏会话。 */
  aboutToAppear(): void { this.active = true; this.reload(); }

  /** 已交给偏好 owner 的保存仍会完成，卸载只撤销旧续体更新 UI 的资格。 */
  aboutToDisappear(): void { this.active = false; this.generation++; }

  /** 保留的版本详情槽位切到列表/资源页时同样退休显示权，重新可见再读确认值。 */
  private onVisibilityChanged_(): void { this.reload(); }

  /** 全局宿主沿用现有 Preferences owner；版本宿主通过回调注入同一个业务入口。 */
  private manager(): PreferenceManager {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) throw new Error('设置上下文不可用');
    return new PreferenceManager(context);
  }

  /** 读取使用与启动构造者相同的分词/优先级；继承与明确选择100%保持不同语义。 */
  private readSnapshot_(version: string): GameResolutionPreferenceSnapshot {
    const load = this.loadPreference;
    if (load !== undefined) return load(version, this.versionScope);
    const preferences = this.manager();
    const launch = preferences.resolveLaunch(this.versionScope ? version : '');
    const preference: number = this.versionScope
      ? normalizeResolutionPreference(preferences.getVersionOverride(version).renderScalePercent)
      : preferences.resolutionScalePercent;
    return new GameResolutionPreferenceSnapshot(preference,
      resolveResolutionPercent(this.versionScope ? launch.renderScalePercent : preference,
        splitJvmArguments(this.versionScope ? launch.customJvmArgs : preferences.customJvmArgs)));
  }

  /** 每次改变可见身份先推进代次；版本目标为空时拒绝编辑，不能回退成全局写入。 */
  private reload(): void {
    this.generation++;
    this.saving = false;
    this.ready = false;
    this.error = '';
    this.message = '';
    if (!this.active || !this.visible) return;
    if (this.versionScope && this.versionId.trim().length === 0) {
      this.error = '版本信息尚未就绪，请重新打开版本详情';
      return;
    }
    try {
      const snapshot = this.readSnapshot_(this.versionScope ? this.versionId : '');
      this.savedPreference = snapshot.preferencePercent;
      this.confirmedEffective = snapshot.effectivePercent;
      this.draft = snapshot.effectivePercent;
      this.message = this.savedPreference === 0
        ? (this.versionScope ? '跟随全局，当前解析为 ' : '默认政策，当前解析为 ') + this.confirmedEffective + '%。'
        : '已保存 ' + this.savedPreference + '%，下次启动生效。';
      this.ready = true;
    } catch (error) {
      this.error = '设置读取失败，请重新打开此页面：' + formatError(error);
    }
  }

  /** Slider和快捷档位共用草稿入口；隐藏页、未就绪或保存中的迟到事件不改变草稿。 */
  private selectDraft_(percent: number): void {
    if (!this.active || !this.visible || !this.ready || this.saving || this.savingGeneration_ === this.generation) return;
    if (!Number.isInteger(percent) || percent < 50 || percent > 100) return;
    this.draft = percent;
    this.error = '';
  }

  /** 保存捕获作用域/版本/代次，等待实际 flush；失败保留当前草稿供重试。 */
  private async save(percent: number): Promise<void> {
    if (!this.active || !this.visible || !this.ready || this.saving || this.savingGeneration_ === this.generation) return;
    if (percent !== 0 && normalizeResolutionPreference(percent) === 0) return;
    const generation: number = this.generation;
    const version: string = this.versionScope ? this.versionId : '';
    if (this.versionScope && version.trim().length === 0) return;
    this.savingGeneration_ = generation;
    this.saving = true;
    this.error = '';
    try {
      const save = this.savePreference;
      if (save !== undefined) await save(percent, version);
      else await this.manager().saveResolutionScalePercent(percent, version);
      if (!this.active || !this.visible || this.generation !== generation) return;
      this.reload();
      if (this.ready) this.message = percent === 0
        ? (this.versionScope ? '已恢复跟随全局，下次启动生效。' : '已恢复默认政策，下次启动生效。')
        : '已保存 ' + percent + '%，下次启动生效。';
      this.onSaved(version, percent);
    } catch (error) {
      if (this.active && this.visible && this.generation === generation) this.error = '保存失败，可重试：' + formatError(error);
    } finally {
      if (this.savingGeneration_ === generation) this.savingGeneration_ = -1;
      if (this.active && this.generation === generation) this.saving = false;
    }
  }

  /** 只显示持久确认态；滑动草稿不会冒充下次启动已采用的新比例。 */
  private confirmedLabel_(): string {
    if (!this.ready) return this.error.length > 0 ? '暂不可用' : '读取中';
    return this.savedPreference === 0
      ? (this.versionScope ? '跟随全局 · ' : '默认 · ') + this.confirmedEffective + '%'
      : this.savedPreference + '%';
  }

  /** V14/V15共享主卡：绘制只投影现有草稿；所有事件仍交给原作用域控制器。 */
  @Builder
  private ResolutionCard_() {
    Column({ space: 16 }) {
      Row() {
        Column({ space: 4 }) {
          Text('渲染比例').fontSize(16).fontColor(this.theme.textPrimary).width('100%');
          Text(this.saving ? '保存中…' : this.draft !== this.confirmedEffective ? '调整中 · 尚未保存' : '拖动后保存生效')
            .fontSize(14).fontColor(this.theme.textSecondary).width('100%').id('resolution-draft-state');
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        Text(this.ready ? this.draft + '%' : '—').fontSize(32).fontWeight(600).fontColor(this.theme.actionText)
          .id('resolution-draft-value');
      }.width('100%').alignItems(VerticalAlign.Center);
      Slider({ value: this.draft, min: 50, max: 100, step: 1 })
        .height(48).selectedColor(this.theme.actionText).blockColor(this.theme.actionText).trackColor(this.theme.bgInput)
        .onChange((value: number): void => { this.selectDraft_(value); }).enabled(this.ready && !this.saving)
        .width('100%').id('resolution-preference-slider');
      Row() {
        Text('50%').fontSize(14).fontColor(this.theme.textSecondary).layoutWeight(1).id('resolution-range-min');
        Text('100%').fontSize(14).fontColor(this.theme.textSecondary).id('resolution-range-max');
      }.width('100%');
      Row({ space: 8 }) {
        ForEach([50, 75, 100], (percent: number) => {
          Button(percent + '%').height(48).layoutWeight(1).fontSize(16)
            .fontWeight(this.draft === percent ? 600 : 400).fontColor(this.theme.actionText)
            .backgroundColor(this.draft === percent ? this.theme.primaryLight : this.theme.bgInput).borderRadius(24)
            .enabled(this.ready && !this.saving).id('resolution-preset-' + percent)
            .onClick((): void => { this.selectDraft_(percent); });
        }, (percent: number): string => String(percent));
      }.width('100%');
      Row() {
        Button('−').width(48).height(48).borderRadius(24).fontSize(24)
          .fontColor(this.theme.actionText).backgroundColor(Color.Transparent)
          .enabled(this.ready && !this.saving && this.draft > 50).id('resolution-decrease')
          .onClick((): void => { this.selectDraft_(Math.max(50, Math.ceil(this.draft) - 1)); });
        Text('每次调整 1%').fontSize(14).fontColor(this.theme.textSecondary).layoutWeight(1)
          .textAlign(TextAlign.Center).id('resolution-stepper-description');
        Button('+').width(48).height(48).borderRadius(24).fontSize(24)
          .fontColor(this.theme.actionText).backgroundColor(Color.Transparent)
          .enabled(this.ready && !this.saving && this.draft < 100).id('resolution-increase')
          .onClick((): void => { this.selectDraft_(Math.min(100, Math.floor(this.draft) + 1)); });
      }.width('100%').height(56).padding(4).backgroundColor(this.theme.bgInput).borderRadius(20)
        .alignItems(VerticalAlign.Center).id('resolution-stepper');
    }.width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(24).id('resolution-main-card');
  }

  /** 最小72高只读卡允许文字放大后换行；确认值不随Slider草稿改变。 */
  @Builder
  private ConfirmedCard_() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, alignContent: FlexAlign.Start }) {
      Text('下次启动').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
        .constraintSize({ maxWidth: '100%' }).flexGrow(1).flexShrink(0).padding({ right: 12 });
      Text(this.confirmedLabel_()).fontSize(14).fontColor(this.theme.textSecondary)
        .constraintSize({ maxWidth: '100%' }).flexShrink(0).wordBreak(WordBreak.BREAK_ALL)
        .id('resolution-confirmed-value');
    }.width('100%').constraintSize({ minHeight: 72 }).padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .backgroundColor(this.theme.bgCard).borderRadius(20).id('resolution-confirmed-card');
  }

  /** 共享正文不自行决定存储作用域；全局与版本仍由固定versionScope和原读写回调控制。 */
  @Builder
  private ResolutionContent_() {
    Column({ space: 16 }) {
      SettingsHint({ text: this.versionScope ? '仅调整此版本，下次启动生效。'
        : '调整所有未单独设置版本的默认分辨率。', theme: this.theme });
      this.ResolutionCard_();
      this.ConfirmedCard_();
      if (this.error.length > 0) {
        Text(this.error).fontSize(14).fontColor(this.theme.errorText).width('100%').id('resolution-preference-error');
      }
      Text(this.message).fontSize(14).fontColor(this.theme.textSecondary).width('100%').id('resolution-preference-status');
      SettingsHint({ text: '降低比例会减少游戏图像像素，画面保持全屏；游戏内文字也会随之缩放。保存后下次启动生效，游戏内调整仍只影响当局。', theme: this.theme });
    }.width('100%').alignItems(HorizontalAlign.Start);
  }

  /** 两种展示方式复用同一组真实保存事件；0仍是继承，明确100%仍写入100。 */
  @Builder
  private FooterActions_() {
    Row({ space: 12 }) {
      Button(this.versionScope ? '跟随全局' : '恢复默认').layoutWeight(1).height(48).borderRadius(24).fontSize(16)
        .fontColor(this.theme.actionText).backgroundColor(this.theme.bgInput)
        .enabled(this.ready && !this.saving).onClick((): void => { this.save(0); }).id('resolution-preference-inherit');
      Button(this.saving ? '保存中…' : '保存比例').layoutWeight(1).height(48).borderRadius(24).fontSize(16)
        .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.actionPrimary)
        .enabled(this.ready && !this.saving).onClick((): void => { this.save(this.draft); }).id('resolution-preference-save');
    }.width('100%').id('resolution-preference-actions');
  }

  build() {
    if (this.embedded) {
      Column() {
        Scroll() {
          Column() { this.ResolutionContent_(); }.width('100%').padding(16);
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).id('resolution-editor-scroll');
        Column() { this.FooterActions_(); }.width('100%').padding({ left: 16, right: 16, top: 12,
          bottom: Math.max(16, this.bottomSafeHeight + 12) }).backgroundColor(this.theme.bgPrimary)
          .id('resolution-editor-footer');
      }.width('100%').height('100%').id('resolution-editor-embedded');
    } else {
      // 全局页已有自己的Scroll和留白；内联模式不争抢父高度，也不创建第二层滚动。
      Column({ space: 16 }) {
        this.ResolutionContent_();
        this.FooterActions_();
      }.width('100%').alignItems(HorizontalAlign.Start).id('resolution-editor-inline');
    }
  }
}

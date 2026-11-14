/**
 * 手机底部 Sheet 默认高度的轻量编辑器。
 *
 * 只消费父层已经确认的百分比；拖动过程只更新数值，松手或点击轨道后才交给
 * 原偏好所有者耐久保存。组件不直接访问 Preferences，也不记录系统拖拽位置。
 */
import { ThemeColors, DEFAULT_PHONE_SHEET_HEIGHT_PERCENT, MIN_PHONE_SHEET_HEIGHT_PERCENT,
  MAX_PHONE_SHEET_HEIGHT_PERCENT, PHONE_SHEET_HEIGHT_STEP, normalizePhoneSheetHeightPercent, formatError } from 'commons';

@Component
export struct PhoneSheetHeightSettings {
  @Prop theme: ThemeColors = new ThemeColors();
  @Prop @Watch('onValue_') value: number = DEFAULT_PHONE_SHEET_HEIGHT_PERCENT;
  @Prop @Watch('onActive_') active: boolean = false;
  /** 路由覆盖时 Tab 仍可能保持选中；由宿主发布的真实可见性撤销迟到滑动资格。 */
  @StorageProp('amclSettingsTabVisible') @Watch('onActive_') hostVisible: boolean = false;
  onSave: (percent: number) => Promise<void> = async (): Promise<void> => {};

  @State private percent: number = DEFAULT_PHONE_SHEET_HEIGHT_PERCENT;
  @State private saving: boolean = false;
  @State private saveError: string = '';
  private mounted_: boolean = false;
  private generation_: number = 0;

  /** 初次显示只复制确认态，组件重建不会触发保存或改动系统面板。 */
  aboutToAppear(): void {
    this.mounted_ = true;
    this.percent = normalizePhoneSheetHeightPercent(this.value);
  }

  /** 离开撤销显示资格；已经交出的写入继续完成，迟到错误不能覆盖新的设置页面。 */
  aboutToDisappear(): void {
    this.mounted_ = false;
    this.generation_++;
  }

  /** 只在没有本地提交时跟随父层，避免 put/flush 的异步传播把滑块跳回旧值。 */
  private onValue_(): void {
    if (this.mounted_ && !this.saving) this.percent = normalizePhoneSheetHeightPercent(this.value);
  }

  /** Tab 隐藏或离开分区时丢弃尚未松手的草稿，不撤销用户已经提交的保存。 */
  private onActive_(): void {
    this.generation_++;
    if (this.mounted_ && !this.saving) this.percent = normalizePhoneSheetHeightPercent(this.value);
    this.saveError = '';
  }

  /** 原生滑块的拖动阶段不写盘；Click 和 End 均可提交，saving 同步挡住重复回调。 */
  private change_(value: number, mode: SliderChangeMode): void {
    if (!this.mounted_ || !this.active || !this.hostVisible || this.saving) return;
    this.percent = normalizePhoneSheetHeightPercent(value);
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.save_(this.percent);
  }

  /** 成功后保留请求值；失败恢复已确认值，反馈只交给发起保存的可见代次。 */
  private async save_(value: number): Promise<void> {
    if (!this.mounted_ || !this.active || !this.hostVisible || this.saving) return;
    const requested: number = normalizePhoneSheetHeightPercent(value);
    this.percent = requested;
    if (requested === normalizePhoneSheetHeightPercent(this.value)) return;
    this.saving = true;
    this.saveError = '';
    const generation: number = this.generation_;
    try {
      await this.onSave(requested);
      if (this.mounted_ && generation === this.generation_) this.percent = requested;
    } catch (error) {
      if (this.mounted_ && this.active && this.hostVisible && generation === this.generation_) {
        this.percent = normalizePhoneSheetHeightPercent(this.value);
        this.saveError = '保存失败，已恢复此前高度：' + formatError(error);
      }
    } finally {
      if (this.mounted_) {
        this.saving = false;
        if (generation !== this.generation_) this.percent = normalizePhoneSheetHeightPercent(this.value);
      }
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('手机 Sheet 高度').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1);
        Text(this.percent + '%').fontSize(16).fontWeight(600).fontColor(this.theme.actionText);
      }.width('100%').alignItems(VerticalAlign.Center);
      Text('调整手机底部面板的默认展开高度，松手后自动保存。')
        .fontSize(14).fontColor(this.theme.textSecondary).width('100%');
      Text('只影响手机面板，平板和电脑保留原有布局。')
        .fontSize(14).fontColor(this.theme.textSecondary).width('100%');
      Slider({ value: this.percent, min: MIN_PHONE_SHEET_HEIGHT_PERCENT,
        max: MAX_PHONE_SHEET_HEIGHT_PERCENT, step: PHONE_SHEET_HEIGHT_STEP })
        .width('100%').height(48).selectedColor(this.theme.actionPrimary).blockColor(this.theme.actionPrimary)
        .enabled(this.active && this.hostVisible && !this.saving).id('settings-phone-sheet-height-slider')
        .accessibilityText('手机 Sheet 高度，' + this.percent + '%')
        .onChange((value: number, mode: SliderChangeMode): void => { this.change_(value, mode); });
      Button('恢复默认（80%）').height(48).fontSize(14).fontColor(this.theme.actionText)
        .backgroundColor(this.theme.bgInput).enabled(this.active && this.hostVisible && !this.saving && this.percent !== DEFAULT_PHONE_SHEET_HEIGHT_PERCENT)
        .id('settings-phone-sheet-height-reset').onClick((): void => { this.save_(DEFAULT_PHONE_SHEET_HEIGHT_PERCENT); });
      if (this.saving) {
        Text('正在保存…').fontSize(14).fontColor(this.theme.textSecondary).width('100%');
      }
      if (this.saveError.length > 0) {
        Text(this.saveError).fontSize(14).fontColor(this.theme.errorText).width('100%');
      }
    }.width('100%').padding(20).alignItems(HorizontalAlign.Start);
  }
}

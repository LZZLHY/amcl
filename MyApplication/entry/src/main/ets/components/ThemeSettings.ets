/**
 * 全应用主题选择器：显示模式和强调色选中即显示，并立即交给原偏好所有者保存。
 *
 * 本组件只持当前选择，不读偏好、不查询设备。每次操作立即发布显示快照和保存请求，
 * 父层及同目录偏好队列保证写入顺序；快速连续选择不会被“保存中”丢弃。离开页面
 * 不撤销已经选定的主题，旧请求只能完成自己的持久化，不能覆盖较新选择的显示或错误。
 */
import { ThemeColors, ThemeMode, ThemeAccent, ThemeSelection, ThemeAccentOption,
  themeAccentOptions, getTheme, AppIconName, formatError } from 'commons';
import { AppIcon } from './AppIcon';
import { AnimatedPillBar } from './AnimatedPillBar';

@Component
export struct ThemeSettings {
  @Prop theme: ThemeColors = new ThemeColors();
  @Prop @Watch('onConfirmed_') selection: ThemeSelection = new ThemeSelection();
  @Prop saving: boolean = false;
  @Prop @Watch('onActive_') active: boolean = false;
  @StorageProp('amclSettingsTabVisible') @Watch('onActive_') hostVisible: boolean = false;
  onPreview: (selection: ThemeSelection | undefined) => void = () => {};
  onSave: (selection: ThemeSelection) => Promise<void> = async (): Promise<void> => {};

  @State private draftMode: ThemeMode = ThemeMode.SYSTEM;
  @State private draftAccent: ThemeAccent = ThemeAccent.ROSE;
  @State private saveError: string = '';
  private mounted_: boolean = false;
  /** 每次有效选择及页面隐藏都递增；只有仍可见的最新选择可以收尾局部界面。 */
  private generation_: number = 0;
  /** 跟踪本实例已交给父层的请求；确认态刷新不能覆盖尚在保存的最新选择。 */
  private pendingRequests_: number = 0;
  /** 本地保留最近确认快照，避免父Prop刷新前保存失败退回过期的选择。 */
  private confirmedSelection_: ThemeSelection = new ThemeSelection();

  /** 只从父层确认态建立初始选择；不读取偏好，也不根据当前预览色反推配置。 */
  aboutToAppear(): void {
    this.mounted_ = true;
    this.resetDraft_();
  }

  /** 卸载只撤销迟到结果的局部显示权，所有已选择主题仍由父层继续按序保存。 */
  aboutToDisappear(): void {
    this.generation_++;
    this.mounted_ = false;
  }

  /** 始终记住父层确认值；有本地请求时保留最新选中标记，避免较早保存抢占它。 */
  private onConfirmed_(): void {
    if (!this.mounted_) return;
    this.confirmedSelection_ = new ThemeSelection(this.selection.mode, this.selection.accent);
    if (this.pendingRequests_ === 0) this.resetDraft_();
  }

  /** 隐藏页面使旧回调失去显示权；重新进入时仅在没有待完成选择时同步确认值。 */
  private onActive_(): void {
    if (!this.mounted_) return;
    if (!this.active || !this.hostVisible) this.generation_++;
    else if (this.pendingRequests_ === 0) {
      this.resetDraft_();
      this.saveError = '';
    }
  }

  /**
   * 每次选择立即交给同一个父层所有者，不能把请求留到组件自己的延迟队列。
   * 这样即使页面立刻卸载或另一个实例继续选择，偏好队列仍按真实点击顺序完成保存。
   */
  private requestSelection_(): void {
    if (!this.mounted_ || !this.active || !this.hostVisible) return;
    const requested: ThemeSelection = new ThemeSelection(this.draftMode, this.draftAccent);
    const generation: number = ++this.generation_;
    this.saveError = '';
    this.pendingRequests_++;
    this.onPreview(requested);
    this.saveSelection_(requested, generation);
  }

  /** 事件先核对可见资格；保存期间仍接受新选择，同值点击不产生重复写入。 */
  private selectMode_(index: number): void {
    if (!this.mounted_ || !this.active || !this.hostVisible) return;
    const mode: ThemeMode = index === 0 ? ThemeMode.LIGHT : index === 1 ? ThemeMode.DARK : ThemeMode.SYSTEM;
    if (this.draftMode === mode && this.saveError.length === 0) return;
    this.draftMode = mode;
    this.requestSelection_();
  }

  /** 强调色与显示模式采用相同的即时保存流程，不因父层保存状态丢失后续点击。 */
  private selectAccent_(accent: ThemeAccent): void {
    if (!this.mounted_ || !this.active || !this.hostVisible) return;
    if (this.draftAccent === accent && this.saveError.length === 0) return;
    this.draftAccent = accent;
    this.requestSelection_();
  }

  /** 跟随父层确认值；失败提示独立管理，迟到Prop刷新不会无声抹去错误。 */
  private resetDraft_(): void {
    this.confirmedSelection_ = new ThemeSelection(this.selection.mode, this.selection.accent);
    this.draftMode = this.selection.mode;
    this.draftAccent = this.selection.accent;
  }

  /**
   * 父层负责串行耐久写入及全局回退；这里只处理本实例的选中标记和失败说明。
   * 老请求成功仍推进本地确认快照，但只有最新可见代次能改界面，不能抢占新选择。
   */
  private async saveSelection_(requested: ThemeSelection, generation: number): Promise<void> {
    try {
      await this.onSave(requested);
      this.confirmedSelection_ = new ThemeSelection(requested.mode, requested.accent);
      if (this.mounted_ && this.active && this.hostVisible && generation === this.generation_) {
        this.draftMode = requested.mode;
        this.draftAccent = requested.accent;
      }
    } catch (error) {
      if (this.mounted_ && this.active && this.hostVisible && generation === this.generation_) {
        this.draftMode = this.confirmedSelection_.mode;
        this.draftAccent = this.confirmedSelection_.accent;
        this.saveError = '保存失败，已恢复此前主题，请重新选择以重试：' + formatError(error);
      }
    } finally {
      this.pendingRequests_--;
    }
  }

  /** 色块直接取目标方案的完整快照，不通过当前色相计算随机变体。 */
  private swatch_(accent: ThemeAccent): ResourceColor {
    return getTheme(this.theme.isDark, accent).actionPrimary;
  }

  build() {
    Column({ space: 16 }) {
      Text('显示模式').fontSize(16).fontColor(this.theme.textPrimary).width('100%');
      AnimatedPillBar({ labels: ['浅色', '深色', '跟随系统'], theme: this.theme, largeControls: true,
        selectedIndex: this.draftMode === ThemeMode.LIGHT ? 0 : this.draftMode === ThemeMode.DARK ? 1 : 2,
        onSelect: (index: number): void => { this.selectMode_(index); } });
      Text('主题色').fontSize(16).fontColor(this.theme.textPrimary).width('100%');
      ForEach(themeAccentOptions(), (option: ThemeAccentOption) => {
        Button() {
          Row({ space: 12 }) {
            Row().width(32).height(32).borderRadius(16).backgroundColor(this.swatch_(option.id));
            Column({ space: 4 }) {
              Text(option.label).fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).width('100%');
              Text(option.description).fontSize(14).fontColor(this.theme.textSecondary).width('100%');
            }.layoutWeight(1);
            if (this.draftAccent === option.id) {
              AppIcon({ name: AppIconName.CheckCircle, iconSize: 24, color: this.theme.actionText });
            }
          }.width('100%').constraintSize({ minHeight: 48 });
        }.type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 72 })
          .padding({ left: 16, right: 16, top: 12, bottom: 12 }).borderRadius(16)
          .backgroundColor(this.draftAccent === option.id ? this.theme.primaryLight : this.theme.bgInput)
          .border({ radius: 16, width: this.draftAccent === option.id ? 2 : 1,
            color: this.draftAccent === option.id ? this.theme.actionText : this.theme.divider })
          .id('settings-theme-' + option.id)
          .accessibilityText(option.label + (this.draftAccent === option.id ? '，已选择' : '，未选择'))
          .onClick((): void => { this.selectAccent_(option.id); });
      }, (option: ThemeAccentOption): string => option.id);
      Text(this.saving ? '正在保存主题…' : '选择后立即生效并自动保存。')
        .fontSize(14).fontColor(this.theme.textSecondary).width('100%');
      if (this.saveError.length > 0) {
        Text(this.saveError).fontSize(14).fontColor(this.theme.errorText).width('100%');
      }
    }.width('100%');
  }
}

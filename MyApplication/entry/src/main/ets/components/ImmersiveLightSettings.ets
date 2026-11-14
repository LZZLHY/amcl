/**
 * 沉浸光感详情的纯展示组件。
 *
 * 父页面只下发已确认的偏好及保存状态；此组件不访问存储、不查询设备，也不改写
 * Prop 中的对象。每次操作复制一份完整偏好交回父页面，保存成功或失败均由父页面
 * 重新发布确认态，避免把未落盘的选择当作已生效设置。
 */
import {
  DockLightMode,
  dockLightModeLabel,
  ImmersiveLightPreferences,
  copyImmersiveLightPreferences,
  ThemeColors
} from 'commons';
import { SettingsDivider, SettingsGroup, SettingsHint, SettingsToggleRow } from './SettingsPrimitives';

/** 关闭由总开关表达；这里的四档只表示 HDS 导航材质的渲染偏好。 */
const NAVIGATION_MATERIAL_MODES: DockLightMode[] = [
  DockLightMode.AUTO,
  DockLightMode.EXQUISITE,
  DockLightMode.GENTLE,
  DockLightMode.SMOOTH
];

@Component
export struct ImmersiveLightSettings {
  @Prop theme: ThemeColors = {} as ThemeColors;
  /** 完整的已确认偏好；总关闭不清空其中已保存的模块选择。 */
  @Prop preferences: ImmersiveLightPreferences = new ImmersiveLightPreferences();
  @Prop saving: boolean = false;
  /** 由父页面给出请求档位、设备回退等实际状态，详情组件不自行猜测能力。 */
  @Prop status: string = '';
  @Prop saveError: string = '';
  @Prop hasPresets: boolean = false;
  onChange: (preferences: ImmersiveLightPreferences) => void = () => {};

  /** 总开关始终可在非保存期操作；只改变 enabled，保留档位和两个模块的勾选。 */
  private requestEnabled_(enabled: boolean): void {
    if (this.saving || this.preferences.enabled === enabled) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.enabled = enabled;
    this.onChange(next);
  }

  /** 档位仅影响已启用导航；能力不足时只提供自动，不保存无法兑现的手动选择。 */
  private requestNavigationMode_(mode: DockLightMode): void {
    if (this.saving || !this.preferences.enabled ||
      (!this.hasPresets && mode !== DockLightMode.AUTO) || this.preferences.navigationMode === mode) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.navigationMode = mode;
    this.onChange(next);
  }

  /** 底部栏和标题栏独立保存；关闭任一模块不覆盖另一个模块及材质档位。 */
  private requestBottomBar_(enabled: boolean): void {
    if (this.saving || !this.preferences.enabled || this.preferences.bottomBar === enabled) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.bottomBar = enabled;
    this.onChange(next);
  }

  /** 只控制父层实际接入的返回/关闭按钮，不扩张到所有正文图标或整个弹层背板。 */
  private requestTitleButtons_(enabled: boolean): void {
    if (this.saving || !this.preferences.enabled || this.preferences.titleButtons === enabled) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.titleButtons = enabled;
    this.onChange(next);
  }

  /** 保存与回退信息全部来自父层，失败时保留旧确认态和原错误节点身份，允许用户再次操作。 */
  @Builder
  private SaveFeedback_() {
    Column({ space: 8 }) {
      if (this.status.length > 0) { SettingsHint({ text: this.status, theme: this.theme }); }
      if (!this.preferences.enabled) {
        SettingsHint({ text: '已暂停效果。下方的档位与模块选择会保留，再次开启后恢复。', theme: this.theme });
      }
      if (this.saving) { SettingsHint({ text: '正在保存…', theme: this.theme }); }
      if (this.saveError.length > 0) {
        Text(this.saveError).fontSize(14).lineHeight(22).fontColor(this.theme.errorText).width('100%')
          .id('immersive-light-save-error');
      }
    }.width('100%').padding({ left: 16, right: 16, bottom: 16 }).alignItems(HorizontalAlign.Start);
  }

  /**
   * 四档采用等宽分段样式；文字可换行、按钮保持至少48vp，系统大字体不会被固定高度截短。
   * 按钮和请求方法同时执行原能力检查，不能通过分段样式绕过设备限制。
   */
  @Builder
  private NavigationModes_() {
    Column({ space: 16 }) {
      Text('导航材质档位').fontSize(16).fontColor(this.theme.textPrimary).width('100%');
      Row({ space: 4 }) {
        ForEach(NAVIGATION_MATERIAL_MODES, (mode: DockLightMode) => {
          Button({ type: ButtonType.Normal }) {
            Text(dockLightModeLabel(mode)).fontSize(14).textAlign(TextAlign.Center).maxLines(2)
              .fontWeight(this.preferences.navigationMode === mode ? 600 : 400)
              .fontColor(this.preferences.navigationMode === mode ? this.theme.actionText : this.theme.textSecondary);
          }.layoutWeight(1).constraintSize({ minHeight: 48 }).padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .borderRadius(24).backgroundColor(this.preferences.navigationMode === mode ? this.theme.bgCard : Color.Transparent)
            .enabled(this.preferences.enabled && !this.saving && (this.hasPresets || mode === DockLightMode.AUTO))
            .accessibilityText('导航材质，' + dockLightModeLabel(mode) +
              (this.preferences.navigationMode === mode ? '，已选中' : ''))
            .id('immersive-light-mode-' + mode)
            .onClick((): void => { this.requestNavigationMode_(mode); });
        }, (mode: DockLightMode): string => mode);
      }.width('100%').padding(4).borderRadius(28).backgroundColor(this.theme.bgInput).alignItems(VerticalAlign.Center);
      SettingsHint({ text: '应用于已启用的导航模块。实际观感随设备能力与系统设置调整。', theme: this.theme });
      if (!this.hasPresets) {
        SettingsHint({ text: '当前设备未提供手动材质档位，可保留自动适配。', theme: this.theme });
      }
    }.width('100%').padding(20).alignItems(HorizontalAlign.Start);
  }

  /** 总开关、真实状态和材质档位合为一个功能组；稳定开关节点在保存期间仅禁用，不替换身份。 */
  @Builder
  private LightGroupContent_() {
    SettingsToggleRow({
      title: '启用沉浸光感', description: '控制底部导航与圆形图标按钮，不更改系统光感设置。',
      value: this.preferences.enabled, actionEnabled: !this.saving, theme: this.theme,
      controlId: 'immersive-light-master', onChange: (enabled: boolean): void => { this.requestEnabled_(enabled); }
    });
    if (this.status.length > 0 || !this.preferences.enabled || this.saving || this.saveError.length > 0) {
      this.SaveFeedback_();
    }
    SettingsDivider({ theme: this.theme });
    this.NavigationModes_();
  }

  /** 模块开关分别透传原确认态；关闭总开关只禁用操作，不重置已保存的模块选择。 */
  @Builder
  private PlacementGroupContent_() {
    SettingsToggleRow({
      title: '底部导航栏', description: '为底部页签保留轻盈的悬浮材质。',
      value: this.preferences.bottomBar, actionEnabled: this.preferences.enabled && !this.saving,
      theme: this.theme, controlId: 'immersive-light-bottom-bar',
      onChange: (enabled: boolean): void => { this.requestBottomBar_(enabled); }
    });
    SettingsDivider({ theme: this.theme });
    SettingsToggleRow({
      title: '圆形图标按钮', description: '统一控制返回、关闭和同类标题操作；不支持材质的位置使用一致的普通样式。',
      value: this.preferences.titleButtons, actionEnabled: this.preferences.enabled && !this.saving,
      theme: this.theme, controlId: 'immersive-light-title-buttons',
      onChange: (enabled: boolean): void => { this.requestTitleButtons_(enabled); }
    });
  }

  /** 主题选择由设置页统一呈现；这里仅负责沉浸光感的两组展示，不创建第二套主题状态。 */
  build() {
    Column({ space: 24 }) {
      SettingsGroup({ title: '沉浸光感', theme: this.theme, content: (): void => { this.LightGroupContent_(); } });
      SettingsGroup({ title: '应用位置', theme: this.theme, content: (): void => { this.PlacementGroupContent_(); } });
    }.width('100%').alignItems(HorizontalAlign.Start);
  }
}

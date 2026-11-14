/**
 * 下载分类共用的固定搜索栏，统一版本与资源页的外壳、搜索图标、输入和清除操作。
 * 文本、焦点引起的退让复位和查询时机均归父页面所有；组件不保存第二份查询状态，
 * 不创建计时器或发起网络请求。可选筛选按钮只投影父页面发布的实际收展状态。
 */
import { AppIconName, ThemeColors } from 'commons';
import { AppIcon } from './AppIcon';
import { AppRoundIconButton } from './AppRoundIconButton';

@Component
export struct DownloadSearchField {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop text: string = '';
  @Prop placeholder: string = '';
  /** 保留各分类原来的可定位身份；共用外观不意味着共用输入或焦点状态。 */
  @Prop controlId: string = '';
  /** 版本页没有手动筛选收起功能；资源页继续使用已有的有效收展状态。 */
  @Prop showFilterToggle: boolean = false;
  @Prop filtersCollapsed: boolean = false;
  onTextChange: (value: string) => void = () => {};
  /** 避免与CustomComponent的onFocus/onBlur链式接口同名；这里只通知输入自身焦点。 */
  onInputFocus: () => void = () => {};
  onInputBlur: () => void = () => {};
  onClear: () => void = () => {};
  onToggleFilters: () => void = () => {};

  build() {
    Column() {
      Row() {
        AppIcon({ name: AppIconName.Search, iconSize: 15, color: this.theme.textHint })
        TextInput({ placeholder: this.placeholder, text: this.text })
          .id(this.controlId).caretColor(this.theme.actionText)
          .height(36).fontSize(14).layoutWeight(1).margin({ left: 8 })
          .backgroundColor(Color.Transparent).borderRadius(0)
          .onChange((value: string) => { this.onTextChange(value); })
          .onFocus(() => { this.onInputFocus(); })
          .onBlur(() => { this.onInputBlur(); })
        if (this.text.length > 0) {
          // 与资源页原控件相同：28vp视觉圆、44vp真实Button命中区，空查询不显示清除。
          AppRoundIconButton({ name: AppIconName.Close, theme: this.theme, visualDiameter: 28, iconSize: 14,
            color: this.theme.textHint, containerBg: Color.Transparent, accessibilityLabel: '清除搜索',
            onAction: (): void => { this.onClear(); } })
        }
        if (this.showFilterToggle) {
          AppRoundIconButton({
            name: this.filtersCollapsed ? AppIconName.ChevronDown : AppIconName.ChevronUp,
            theme: this.theme, visualDiameter: 28, iconSize: 13,
            color: this.filtersCollapsed ? this.theme.textSecondary : this.theme.actionText,
            containerBg: this.filtersCollapsed ? this.theme.bgInput : this.theme.primaryLight,
            accessibilityLabel: this.filtersCollapsed ? '展开筛选' : '收起筛选',
            onAction: (): void => { this.onToggleFilters(); } })
            .margin({ left: 6 })
        }
      }.width('100%').height(44).padding({ left: 12, right: 6 })
        .backgroundColor(this.theme.bgCard).borderRadius(20).alignItems(VerticalAlign.Center)
    }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.theme.bgPrimary)
  }
}

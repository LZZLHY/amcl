/**
 * 页面、面板和设置富标题的共同宿主；一个完整内容区只有一个导航宿主。
 * 原生 HDS 标题项与普通圆按钮共享动作契约，业务只提供请求回调。
 * API20～22 使用普通按钮；API23 起才进入真实 HDS 材质，切档不重建正文。
 */
import { deviceInfo } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import {
  HdsNavigation, HdsNavigationTitleMode, HdsNavigationTitleBarOptions,
  HdsNavigationMenuItemOptions, IconStyleMode, TextStyleMode, TitleSize, hdsMaterial,
} from '@kit.UIDesignKit';
import { DockLightMode, ThemeColors, AppIconName, lookupIcon } from 'commons';
import { AppRoundIconButton } from './AppRoundIconButton';
import { AppTitleAction } from './AppTitleAction';
import { effectiveTitleLightMode, initializeImmersiveLightRuntime } from './ImmersiveLightRuntime';

@Component
export struct ImmersiveTitleScaffold {
  @Prop title: string = '';
  /** 设置域可选择原生 MINI 的中大标题；默认关闭，其他页面的标题尺寸保持原契约。 */
  @Prop emphasizedTitle: boolean = false;
  /**
   * 当前版本、账户等操作对象只通过标题同行的紧凑入口出现，不为说明文字另占一行。
   * 调用方传完整身份；可视标签按字符缩短，点击时仍能查看完整值，不改变业务选择。
   */
  @Prop contextLabel: string = '';
  /** 完整对象信息弹窗的标题，例如“当前版本”“当前账户”。 */
  @Prop contextTitle: string = '当前对象';
  @Prop titleId: string = '';
  /** 无返回的品牌标题保留真实图片节点，宽度用于预留同行标题起点。 */
  @Prop brandWidth: number = 0;
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop topSafeHeight: number = 0;
  @Prop surfaceColor: ResourceColor = Color.Transparent;
  /** 单关闭采用MODAL；双操作采用MINI和showClose，左返回不会被模态样式隐藏。 */
  @Prop modal: boolean = false;
  @Prop showBack: boolean = true;
  @Prop showClose: boolean = false;
  @Prop backLabel: string = '返回';
  @Prop closeLabel: string = '关闭';
  @Prop backEnabled: boolean = true;
  @Prop closeEnabled: boolean = true;
  @Prop externalEnabled: boolean = true;
  @Prop backId: string = 'app-title-back';
  @Prop closeId: string = 'app-title-close';
  @Prop showExternal: boolean = false;
  @Prop menuActions: AppTitleAction[] = [];
  /** 固定搜索等附加区的高度由调用方给出；该区域不参与正文滚动。 */
  @Prop accessoryHeight: number = 0;
  onBack: () => void = () => {};
  onClose: () => void = () => {};
  onExternal: () => void = () => {};
  onMenuAction: (id: string) => void = () => {};
  @BuilderParam headerAccessory: () => void = this.emptyContent_;
  @BuilderParam headerBrand: () => void = this.emptyContent_;
  /** 多个BuilderParam须显式传content；箭头仅转调父@Builder，不能使用尾随闭包或直接内联UI正文。 */
  @BuilderParam content: () => void = this.emptyContent_;
  @StorageLink('amclImmersiveLightConfig') private rawConfig: string = '';
  /** 原生options的迟到回调与普通Button使用同一退役边界。 */
  private alive_: boolean = false;

  @Builder
  private emptyContent_() { Column() {} }

  /** 独立路由首达由唯一运行时加载；每枚按钮不自行探测设备或读盘。 */
  aboutToAppear(): void {
    this.alive_ = true;
    const context = this.getUIContext().getHostContext();
    if (context !== undefined) initializeImmersiveLightRuntime(context);
  }
  aboutToDisappear(): void { this.alive_ = false; }

  private hasBack_(): boolean { return this.showBack && !this.modal; }
  private hasClose_(): boolean { return this.modal || this.showClose; }
  private hasBrand_(): boolean { return this.brandWidth > 0 && !this.hasBack_(); }
  private requestBack_(): void { if (this.alive_ && this.hasBack_() && this.backEnabled) this.onBack(); }
  private requestClose_(): void { if (this.alive_ && this.hasClose_() && this.closeEnabled) this.onClose(); }
  private requestExternal_(): void { if (this.alive_ && this.showExternal && this.externalEnabled) this.onExternal(); }

  /** 原生项可能在禁用前排队；按id重读当前规格，拒绝旧options里的可用快照。 */
  private requestMenu_(id: string): void {
    const action: AppTitleAction | undefined = this.menuActions.find((item: AppTitleAction): boolean => item.id === id);
    if (this.alive_ && action !== undefined && action.enabled !== false) this.onMenuAction(id);
  }

  /** Builder中的对象可能继续变化；生成回调时复制字符串，旧系统也按原身份派发。 */
  private menuRequest_(id: string): () => void {
    const identity: string = id;
    return (): void => { this.requestMenu_(identity); };
  }

  /**
   * 按字符预算中间省略，保留名称首尾且不切断Unicode代理项。中文/表情按双份预算处理，
   * 返回、关闭或其他动作较多时继续收紧；预算是保守文案限制，真实像素仍由系统布局决定。
   * 网页来源的协议已在完整信息中保留，同行标签优先显示可辨认的主机名。
   */
  private contextShortLabel_(): string {
    const label: string = this.contextLabel.startsWith('https://') ? this.contextLabel.slice(8) : this.contextLabel;
    const characters: string[] = Array.from(label);
    const budget: number = (this.hasBack_() && this.hasClose_()) || this.menuActions.length > 0 ? 8 : 12;
    let total: number = 0;
    for (const character of characters) total += character.charCodeAt(0) <= 255 ? 1 : 2;
    if (total <= budget) return label;
    const prefixBudget: number = budget === 8 ? 4 : 7;
    let prefix: string = '', suffix: string = '', prefixUnits: number = 0, suffixUnits: number = 0;
    for (const character of characters) {
      const units: number = character.charCodeAt(0) <= 255 ? 1 : 2;
      if (prefixUnits + units > prefixBudget) break;
      prefix += character; prefixUnits += units;
    }
    for (let index: number = characters.length - 1; index >= 0; index--) {
      const character: string = characters[index];
      const units: number = character.charCodeAt(0) <= 255 ? 1 : 2;
      if (suffixUnits + units > budget - prefixBudget - 1) break;
      suffix = character + suffix; suffixUnits += units;
    }
    return prefix + '…' + suffix;
  }

  /**
   * 查看身份是只读操作。事件捕获生成时的身份，退休或切换对象后拒绝迟到点击，
   * 防止旧页面的标签打开另一个实例的信息；原生弹窗取消不应转成业务错误。
   */
  private requestContext_(identity: string): void {
    if (!this.alive_ || identity.length === 0 || identity !== this.contextLabel) return;
    try {
      this.getUIContext().showAlertDialog({ title: this.contextTitle, message: identity,
        confirm: { value: '知道了', fontColor: this.theme.actionText, action: (): void => {} } });
    } catch (_) { /* 宿主失效时不改变业务对象；查看信息没有需要回滚的写入。 */ }
  }

  /** 返回固定身份的闭包，新旧系统共用，不能在点击时把旧标签重定向到新对象。 */
  private contextRequest_(): () => void {
    const identity: string = this.contextLabel;
    return (): void => { this.requestContext_(identity); };
  }

  /** 文字操作保留胶囊，图标操作使用原生圆形项，角标交给同一个原生项。 */
  private menuItems_(): HdsNavigationMenuItemOptions[] {
    const items: HdsNavigationMenuItemOptions[] = [];
    if (this.contextLabel.length > 0) {
      items.push({ content: { label: this.contextShortLabel_(), componentId: 'app-title-context',
        type: TextStyleMode.NORMAL, action: this.contextRequest_() } });
    }
    if (this.showExternal) {
      items.push({ content: { icon: lookupIcon(AppIconName.ArrowUpRight).resource, label: '在浏览器中打开',
        componentId: 'app-title-external', isEnabled: this.externalEnabled, type: IconStyleMode.SMALL,
        action: (): void => { this.requestExternal_(); } } });
    }
    this.menuActions.forEach((action: AppTitleAction): void => {
      // 捕获生成时身份；旧规格对象被调用方原位修改id也不能重定向迟到事件。
      const id: string = action.id;
      const item: HdsNavigationMenuItemOptions = { content: {
        label: action.label, componentId: id, isEnabled: action.enabled !== false,
        type: action.icon === undefined ? TextStyleMode.NORMAL : IconStyleMode.SMALL,
        action: (): void => { this.requestMenu_(id); },
      } };
      if (action.icon !== undefined && item.content !== undefined) item.content.icon = lookupIcon(action.icon).resource;
      if (action.badge !== undefined && action.badge.length > 0) {
        item.badge = { value: action.badge, accessibilityText: action.label + '，' + action.badge };
      }
      items.push(item);
    });
    // 关闭始终位于最右侧，与普通分支的顺序一致，避免双动作面板出现错位。
    if (this.hasClose_()) {
      items.push({ content: { icon: lookupIcon(AppIconName.Close).resource, label: this.closeLabel,
        componentId: this.closeId, isEnabled: this.closeEnabled, type: IconStyleMode.SMALL,
        action: (): void => { this.requestClose_(); } } });
    }
    return items;
  }

  /** 附加区只为真实搜索、筛选、页签等控件分配高度；没有控件时不保留空白行。 */
  private accessoryHeight_(): number { return Math.max(0, this.accessoryHeight); }

  /**
   * MINI标题的装饰品牌使用公开stackBuilder，真实Image仍可测量并独立透明交接。
   * 节点不处理输入，避免遮挡右侧原生操作；不以原生图标外框冒充图片矩形。
   */
  @Builder
  private brand_() {
    Row() { this.headerBrand() }.width('100%').height(56)
      .padding({ left: 16 }).alignItems(VerticalAlign.Center).hitTestBehavior(HitTestMode.None)
  }

  /** 固定搜索等功能附件由调用方持有；普通按钮不声称继承原生标题材质。 */
  @Builder
  private accessory_() {
    Column({ space: 0 }) {
      this.headerAccessory()
    }.width('100%').padding({ left: 16, right: 16 })
  }

  /** 新枚举只在保护分支触达；关闭显式使用NONE，不能恢复系统默认而重新亮起。 */
  private nativeTitleOptions_(): HdsNavigationTitleBarOptions {
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: false, enableComponentSafeArea: true,
      content: {
        title: { mainTitle: this.title, mainTitleId: this.titleId },
        backIcon: { icon: lookupIcon(AppIconName.Back).resource, label: this.backLabel,
          componentId: this.backId, isEnabled: this.backEnabled, action: (): void => { this.requestBack_(); } },
        menu: { value: this.menuItems_(), maxCount: 3 },
      },
    };
    if (this.hasBrand_() && options.content !== undefined) {
      options.padding = { start: LengthMetrics.vp(this.brandWidth + 28) };
      options.content.stackBuilder = (): void => { this.brand_(); };
    }
    if (this.accessoryHeight_() > 0 && options.content !== undefined) {
      options.content.bottomBuilder = { builder: (): void => { this.accessory_(); }, height: this.accessoryHeight_() };
    }
    if (deviceInfo.apiAvailable('6.1.0')) {
      // mainTitleSize 是 API23 的离散字号规格，只在已有版本保护内触达；不虚构自由数值字号。
      if (this.emphasizedTitle && !this.modal && options.content?.title !== undefined) {
        options.content.title.mainTitleSize = TitleSize.TITLE_ML;
      }
      const mode: DockLightMode = effectiveTitleLightMode(this.rawConfig);
      const off: boolean = mode === DockLightMode.OFF;
      let level: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
      if (mode === DockLightMode.EXQUISITE) level = hdsMaterial.MaterialLevel.EXQUISITE;
      else if (mode === DockLightMode.GENTLE) level = hdsMaterial.MaterialLevel.GENTLE;
      else if (mode === DockLightMode.SMOOTH) level = hdsMaterial.MaterialLevel.SMOOTH;
      options.style = {
        scrollEffectOpts: { enableScrollEffect: false },
        originalStyle: {
          backgroundStyle: { backgroundColor: this.surfaceColor },
          contentStyle: {
            titleStyle: { mainTitleColor: this.theme.textPrimary },
            backIconStyle: { iconColor: this.theme.textPrimary, backgroundColor: off ? this.theme.bgCard : Color.Transparent },
            menuStyle: { iconColor: this.theme.textPrimary, backgroundColor: off ? this.theme.bgCard : Color.Transparent },
          },
        },
        systemMaterialEffect: { materialType: off ? hdsMaterial.MaterialType.NONE : hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: level },
      };
    }
    return options;
  }

  /** 旧系统共用动作、禁用和读屏语义，不复制各页面的旧按钮实现。 */
  @Builder
  private ordinaryTitle_() {
    Column() {
      Row({ space: 8 }) {
        if (this.hasBack_()) {
          AppRoundIconButton({ name: AppIconName.Back, theme: this.theme, accessibilityLabel: this.backLabel,
            actionEnabled: this.backEnabled, controlId: this.backId, onAction: (): void => { this.requestBack_(); } })
        }
        if (this.hasBrand_()) this.headerBrand()
        Text(this.title).fontSize(this.emphasizedTitle && !this.modal ? 28 : 20).fontWeight(700).fontColor(this.theme.textPrimary)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).id(this.titleId)
        if (this.contextLabel.length > 0) {
          Button() {
            Text(this.contextShortLabel_()).fontSize(12).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(this.theme.textSecondary)
          }.height(44).constraintSize({ maxWidth: 88 }).backgroundColor(this.theme.bgCard)
            .accessibilityText(this.contextTitle + '，' + this.contextLabel + '，查看完整名称')
            .id('app-title-context').onClick(this.contextRequest_())
        }
        if (this.showExternal) {
          AppRoundIconButton({ name: AppIconName.ArrowUpRight, theme: this.theme, accessibilityLabel: '在浏览器中打开',
            actionEnabled: this.externalEnabled, onAction: (): void => { this.requestExternal_(); } })
        }
        ForEach(this.menuActions, (action: AppTitleAction) => {
          if (action.icon !== undefined) {
            AppRoundIconButton({ name: action.icon, theme: this.theme, accessibilityLabel: action.label,
              actionEnabled: action.enabled !== false, controlId: action.id, badge: action.badge ?? '',
              onAction: this.menuRequest_(action.id) })
          } else {
            Button(action.label).height(44).enabled(action.enabled !== false)
              .fontColor(this.theme.textPrimary).backgroundColor(this.theme.bgCard).id(action.id)
              .onClick(this.menuRequest_(action.id))
          }
        }, (action: AppTitleAction): string => action.id)
        if (this.hasClose_()) {
          AppRoundIconButton({ name: AppIconName.Close, theme: this.theme, accessibilityLabel: this.closeLabel,
            actionEnabled: this.closeEnabled, controlId: this.closeId, onAction: (): void => { this.requestClose_(); } })
        }
      // 普通标题与原生一行MINI的56vp保持一致（44vp触点+上下各6vp）；
      // MODAL另外保留原生契约的8vp顶部背板，安全区仅在这里追加一次。
      }.width('100%').padding({ left: 16, right: 16, top: this.topSafeHeight + (this.modal ? 14 : 6), bottom: 6 })
        .alignItems(VerticalAlign.Center)
      if (this.accessoryHeight_() > 0) this.accessory_()
    }.width('100%')
  }

  build() {
    // 固定系统版本决定宿主；用户切档不会销毁任务、编辑状态或正文滚动器。
    if (deviceInfo.apiAvailable('6.1.0')) {
      HdsNavigation() {
        Column() { this.content() }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      }.mode(NavigationMode.Stack)
        .titleMode(this.modal ? HdsNavigationTitleMode.MODAL : HdsNavigationTitleMode.MINI)
        .hideBackButton(!this.hasBack_()).hideToolBar(true).titleBar(this.nativeTitleOptions_())
        .width('100%').height('100%').padding({ top: this.topSafeHeight }).backgroundColor(this.surfaceColor)
    } else {
      Column() {
        this.ordinaryTitle_()
        Column() { this.content() }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').backgroundColor(this.surfaceColor)
    }
  }
}

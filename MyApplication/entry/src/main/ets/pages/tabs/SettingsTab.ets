import { DesktopGamepadSettings } from '../../components/DesktopGamepadSettings';
import { MobileglRendererSettings } from '../../components/MobileglRendererSettings'
import { ProductDeveloperSettings } from 'entry/ProductDeveloperSettings'
import { ProductTouchSettings } from 'entry/ProductTouchSettings';
import { DistributionPolicy } from 'commons';
/**
 * SettingsTab.ets — 设置 Tab 组件
 *
 * 包含内存配置、主题、游戏设置、日志、关于等卡片。
 * 从 Index.ets 提取，通过 @Prop 接收状态，通过回调通知父组件。
 *
 * 2026-05-18 P2-NEW：JDK 选择从单选 17 解锁到 17/21。
 *   - 17 是默认 + 推荐（覆盖大多数 MC 版本，Forge/Fabric 兼容性最高）
 *   - 21 是新增 + "⚠️ 实验性"（首次给 MC 1.20.5+ 用户支持）
 *   - 切换后 Index.updateJdkReadyState 会基于 selectedJdkVersion 决定 jdkReady
 */

import { router, promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, ThemeMode } from 'commons';
import { APP_VERSION } from 'commons';
import { DOCS_INSTALL_URL, DOCS_INSTALL_FALLBACK_URL, DOCS_NO_JIT_URL, DOCS_NO_JIT_FALLBACK_URL } from 'commons';
import { AMCL_WEB_BASE } from 'commons';
import { DeviceProfile } from 'commons';
import { JDK_AUTO } from 'commons';
import { GAME_LANGUAGES, GameLanguageOption, gameLanguageLabel } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from '../../components/AppIcon';
import { LogRetentionSettings } from '../../components/LogRetentionSettings';
// 2026-05-24：FloatingDock 占高预留
import { floatingDockReserveHeight } from 'commons';
import { AnimatedPillBar } from '../../components/AnimatedPillBar';
import { MotionSection } from '../../components/MotionSection';
import { ProductInputProfile } from 'entry/ProductInputProfile';


/** 设置分区的检索词仅用于本地导航，不改变任一配置值。 */
interface SettingsSection {
  id: string;
  title: string;
  description: string;
  keywords: string;
  icon: AppIconName;
}
const SETTINGS_SECTIONS: SettingsSection[] = [
  { id: 'performance', title: '游戏与性能', description: '内存 · Java · 游戏进程', keywords: '内存 堆 虚拟 java jdk jvm 性能 独立 进程 平板 启动 重启', icon: AppIconName.Memory },
  { id: 'controls', title: '显示与操控', description: '主题 · 帧率 · 语言 · 输入与渲染', keywords: '显示 主题 浅色 深色 帧率 语言 隔离 窗口 触控 手柄 渲染 mobilegl 开发', icon: AppIconName.GameController },
  { id: 'download', title: '下载与存储', description: '下载源 · 加速 · 游戏数据位置', keywords: '下载 存储 镜像 官方 jdk 模组 数据 位置 缓存 并发 加速', icon: AppIconName.Download },
  { id: 'logs', title: '日志与支持', description: '日志保留 · 网络检测 · 反馈', keywords: '日志 保留 导出 剪贴板 网络 检测 jit 安装 帮助 支持 反馈 关于 更新', icon: AppIconName.Help },
];

@Component
export struct SettingsTab {
  @Prop mcDir: string = ''
  @Prop mcVersion: string = ''
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop topSafeHeight: number = 0
  /** home indicator 安全区高度。用于算最后一项 margin.bottom，避开底部悬浮 dock。 */
  @Prop bottomSafeHeight: number = 0
  @Prop @Watch('onXmxChanged_') mcXmx: number = 0
  /** JVM 最大内存滑块上限。由 Index 按设备物理内存动态下发，默认 8192。 */
  @Prop xmxMax: number = 8192
  /** 虚拟内存（堆文件 / -XX:AllocateHeapAt）模式开关。 */
  @Prop virtualMemoryMode: boolean = false
  @Prop themeMode: ThemeMode = ThemeMode.SYSTEM
  @Prop selectedJdkVersion: string = '17'
  @Prop versionIsolation: boolean = true
  @Prop useNewWindow: boolean = false
  /** 保存值与本进程有效值分别展示，不能把待重启设置显示为已经切换。 */
  @Prop tabletIndependentGameProcess: boolean = true
  @Prop tabletProcessActive: boolean = false
  @Prop tabletProcessSaving: boolean = false
  @Prop tabletProcessMessage: string = ''
  /** 游戏数据存储位置：'sandbox' | 'external' */
  @Prop storageLocation: string = 'sandbox'
  /** 本设备外部存储(Download/com.amcl.launcher)是否可用（取得到 Download 路径） */
  @Prop externalAvailable: boolean = false
  /** 外部根路径提示文案（如 /storage/Users/currentUser/Download/com.amcl.launcher/.minecraft） */
  @Prop externalPathHint: string = ''
  @Prop modSource: string = 'auto'
  @Prop cacheRemoteMeta: boolean = true
  @Prop modConcurrentDownloads: number = 3
  /**
   * 加速下载（经 AMCL 加速网关）。只改写**官方源** URL 走网关（relay.cpp 只放行官方主机），
   * 镜像源 URL 原样保留 —— 上面的各个源偏好在加速期间**仍然生效**。
   */
  @Prop accelDownload: boolean = false
  /** 加速状态提示：''=未启用，'ok'=已就绪，其它=错误原因 */
  @Prop accelStatus: string = ''
  /** JDK 下载源偏好：'auto'|'github'|'gitee'|'mirror'。 */
  @Prop jdkSource: string = 'auto'
  /** MC 版本下载源偏好：'auto'|'mirror'|'official'（client.jar / 依赖库 / 游戏资源）。 */
  @Prop mcSource: string = 'auto'
  /** 全局自定义 JVM 参数（空格分隔）。对所有版本生效；单版本参数会在其后追加。 */
  @Prop customJvmArgs: string = ''
  /** 全局游戏语言（options.txt lang code，如 'zh_cn'）。默认简体中文；单版本可覆盖。 */
  @Prop gameLanguage: string = 'zh_cn'
  /** OHOS XComponent 调度帧率上限。0 = 自动跟随显示刷新率；不修改游戏内 FPS 设置。 */
  @Prop ohosFrameRateCap: number = 0
  /** 是否有可用更新（驱动「检查更新」行红点）。 */
  @Prop hasUpdate: boolean = false

  // 回调
  onXmxChange: (value: number) => void = () => {}
  onVirtualMemoryModeChange: (isOn: boolean) => void = () => {}
  onThemeChange: (mode: ThemeMode) => void = () => {}
  onVersionIsolationChange: (isOn: boolean) => void = () => {}
  onNewWindowChange: (isOn: boolean) => void = () => {}
  /** 父页面负责等待保存/错误回滚；此组件不修改当前进程路线或正在运行的游戏。 */
  onTabletProcessChange: (enabled: boolean) => void = () => {}
  /** 用户切换游戏数据存储位置（'sandbox'|'external'）；父组件负责权限/迁移/落盘。 */
  onStorageLocationChange: (loc: string) => void = () => {}
  onOpenLog: () => void = () => {}
  /** 最近游戏通过父页面解析活动身份，与应用运行摘要保持明确的内容边界。 */
  onOpenGameLog: () => void = () => {}
  onExportLog: () => void = () => {}
  onModSourceChange: (value: string) => void = () => {}
  onCacheRemoteMetaChange: (isOn: boolean) => void = () => {}
  /** 用户切换加速下载；父组件持久化 + 握手 + 注入 native */
  onAccelDownloadChange: (isOn: boolean) => void = () => {}
  onModConcurrentDownloadsChange: (value: number) => void = () => {}
  /** 用户在 JDK 版本 chip 上做切换；父组件持久化到 prefs 并同步 jdkReady 状态。 */
  onJdkVersionChange: (version: string) => void = () => {}
  /** 用户切换 JDK 下载源；父组件持久化到 prefs 并注入 setJdkDownloadSource。 */
  onJdkSourceChange: (value: string) => void = () => {}
  /** 用户切换 MC 版本下载源；父组件持久化到 prefs 并注入 setMcSourcePreference。 */
  onMcSourceChange: (value: string) => void = () => {}
  /** 用户编辑全局自定义 JVM 参数；父组件持久化到 prefs（PreferenceManager.customJvmArgs）。 */
  onCustomJvmArgsChange: (args: string) => void = () => {}
  /** 用户切换全局游戏语言；父组件持久化到 prefs（PreferenceManager.gameLanguage）。 */
  onGameLanguageChange: (code: string) => void = () => {}
  /** 用户切换 OHOS 调度帧率上限；父组件持久化并同步到 native policy。 */
  onOhosFrameRateCapChange: (fpsCap: number) => void = () => {}
  /** 用户点击「检查更新」；父组件拉 update.json 比对 versionCode 并提示结果。 */
  onCheckUpdate: () => void = () => {}

  /**
   * 全局「自定义 JVM 参数」内联编辑状态：
   *   - jvmArgsExpanded: 是否展开编辑区（点击行标题切换，animateTo 平滑伸缩）
   *   - jvmArgsDraft:    编辑中的文本草稿。aboutToAppear 由 prop 初始化；
   *                      失焦 / 收起时经 onCustomJvmArgsChange 落盘。
   */
  @State private jvmArgsExpanded: boolean = false
  @State private jvmArgsDraft: string = ''
  /** 宽度取自当前窗口；折叠屏与分屏缩放时不依赖设备出厂类型。 */
  @State private viewportWidth: number = 0
  @State private activeSection: string = 'overview'
  @State private settingsQuery: string = ''
  @State private xmxDraft: string = ''
  @State private memoryError: string = ''
  /** 只控制设置内容区；标题和搜索栏为固定兄弟节点，不随内容滚走。 */
  private contentScroller: Scroller = new Scroller()

  aboutToAppear() {
    this.jvmArgsDraft = this.customJvmArgs
    this.xmxDraft = String(this.mcXmx)
  }

  /** 持久化全局自定义 JVM 参数（trim 首尾空白）。 */
  private saveCustomJvmArgs(): void {
    this.onCustomJvmArgsChange(this.jvmArgsDraft.trim())
  }

  // ===== 大内存风险确认（2026-05-31）=====
  // 设备物理内存的 80% 是安全分界：超过后 Java 堆 + native/GL/直接内存的总占用
  // 容易触发 HarmonyOS lowmemkiller 把游戏进程杀掉。所以用户拖过 80% 时弹一次确认，
  // 讲清风险；用户确认后本会话内放行（rememberHighXmxAck=true），不再反复打扰；
  // 取消则把值回弹到 80% 阈值。
  private static readonly XMX_RISK_RATIO: number = 0.8
  /** 本会话用户是否已确认过"高内存风险"。确认后同一会话不再弹。 */
  @State private highXmxAck: boolean = false

  /** 设备物理内存 80% 对应的安全阈值（MB，对齐 256MB）。基于滑块上限反推。 */
  private xmxRiskThreshold(): number {
    let raw = Math.floor((this.xmxMax * SettingsTab.XMX_RISK_RATIO) / 256) * 256
    if (raw < 512) raw = 512
    return raw
  }

  /**
   * 滑块变更处理。低于 80% 阈值直接放行；首次拖过阈值（且本会话未确认过）弹风险
   * 确认框：「了解风险，继续」→ 记住放行并应用该值；「停在 80%」→ 回弹到阈值。
   *
   * 注：finalValue 仅在 SliderChangeMode.End（松手）时弹框，拖动过程（Moving）只要
   * 已确认过就实时应用，避免每滑一格弹一次。
   */
  private onXmxSliderChange(value: number, mode: SliderChangeMode): void {
    let threshold = this.xmxRiskThreshold()
    // 未越过阈值，或已确认过风险 → 直接应用
    if (value <= threshold || this.highXmxAck) {
      this.onXmxChange(value)
      return
    }
    // 越过阈值且未确认：拖动中先不弹（避免频繁），等松手再弹
    if (mode !== SliderChangeMode.End && mode !== SliderChangeMode.Click) {
      // 拖动过程中先把值临时夹在阈值，UI 不越线；松手时再决定
      this.onXmxChange(threshold)
      return
    }
    this.confirmHighXmx(value, threshold)
  }

  /** 弹出大内存风险确认框。 */
  private confirmHighXmx(value: number, threshold: number): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '内存分配过高',
        message: '你正在把 JVM 最大内存设到 ' + value + ' MB，已超过设备物理内存的 80%（'
          + threshold + ' MB）。\n\n'
          + '游戏除了 Java 堆还需要图形驱动、native 库等额外内存。分配过高时，系统'
          + '可能在内存紧张时强制结束游戏进程（闪退）。\n\n'
          + '确认了解风险后可继续调高，或停留在 80% 安全值。',
        buttons: [
          { text: '停在 ' + threshold + ' MB', color: this.theme.primary as string },
          { text: '了解风险，继续', color: this.theme.error as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 1) {
          // 用户确认风险：本会话放行，应用其选择的值
          this.highXmxAck = true
          this.onXmxChange(value)
        } else {
          // 停在 80%
          this.onXmxChange(threshold)
        }
      }).catch(() => {
        // 弹框异常：保守回退到阈值
        this.onXmxChange(threshold)
      })
    } catch (e) {
      this.onXmxChange(threshold)
    }
  }

  /** 分区切换前保存 JVM 草稿，进入任何分区都从顶部开始，不继承上个分区的滚动位置。 */
  private selectSection_(section: string): void {
    if (this.jvmArgsExpanded) this.saveCustomJvmArgs()
    this.jvmArgsExpanded = false
    this.activeSection = section
    this.settingsQuery = ''
    this.xmxDraft = String(this.mcXmx)
    this.memoryError = ''
    // 非动画滚动会停止原页面的惯性滚动；配置回调和新内容的数据不受影响。
    this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false })
  }

  /** 搜索结果同样从顶部呈现，清空关键词时不会回到原先已经滚到底部的位置。 */
  private changeSearch_(value: string): void {
    this.settingsQuery = value
    this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false })
  }

  /** 风险确认取消或外部配置变化后同步输入框，避免显示未真正保存的内存值。 */
  private onXmxChanged_(): void { this.xmxDraft = String(this.mcXmx) }

  /** 精确输入与快捷档位共用原有风险阈值，不绕过 80% 确认。 */
  private applyPreciseMemory_(): void {
    const value: number = Number(this.xmxDraft)
    if (!Number.isInteger(value) || value < 512 || value > this.xmxMax || value % 256 !== 0) {
      this.memoryError = '请输入 512–' + this.xmxMax + ' MB，且为 256 的整数倍'
      return
    }
    this.memoryError = ''
    this.onXmxSliderChange(value, SliderChangeMode.Click)
  }

  /** 内存快捷档位按设备上限裁剪，不向小内存设备写入超界值。 */
  private quickMemoryValues_(): number[] {
    return [2048, 4096, 6144].filter((value: number): boolean => value <= this.xmxMax)
  }

  private visibleSections_(): SettingsSection[] {
    const query: string = this.settingsQuery.trim().toLowerCase()
    return SETTINGS_SECTIONS.filter((section: SettingsSection): boolean =>
      query.length === 0 || (section.title + ' ' + section.description + ' ' + section.keywords).toLowerCase().indexOf(query) >= 0)
  }

  private sectionTitle_(): string {
    const section = SETTINGS_SECTIONS.find((candidate: SettingsSection): boolean => candidate.id === this.activeSection)
    return section?.title ?? '设置'
  }

  /** 路由失败提供可见反馈，不让首页快捷入口悄悄失效。 */
  private openLedger_(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/DownloadHistoryPage' }).catch((): void => {
        this.settingsNavigationError_()
      })
    } catch (e) { this.settingsNavigationError_() }
  }

  private settingsNavigationError_(): void {
    try { this.getUIContext().getPromptAction().showToast({ message: '无法打开活动账本，请重试' }) }
    catch (e) { /* 当前页面可能已离开，不再触发第二次导航。 */ }
  }

  build() {
    Row({ space: 24 }) {
      if (this.viewportWidth >= 840) {
        Column({ space: 12 }) {
          Text('AMCL').fontSize(14).fontWeight(600).fontColor(this.theme.primary).padding({ bottom: 16 })
          Button('常用设置').height(48).width('100%').fontSize(14)
            .fontColor(this.activeSection === 'overview' ? this.theme.primary : this.theme.textPrimary)
            .backgroundColor(this.activeSection === 'overview' ? this.theme.bgCard : Color.Transparent)
            .onClick(() => { this.selectSection_('overview') })
          ForEach(SETTINGS_SECTIONS, (section: SettingsSection) => {
            Button(section.title).height(48).width('100%').fontSize(14)
              .fontColor(this.activeSection === section.id ? this.theme.primary : this.theme.textSecondary)
              .backgroundColor(this.activeSection === section.id ? this.theme.bgCard : Color.Transparent)
              .onClick(() => { this.selectSection_(section.id) })
          }, (section: SettingsSection): string => section.id)
          Button('活动账本').height(48).width('100%').fontSize(14).onClick(() => { this.openLedger_() })
        }.width(184).height('100%').padding({ top: this.topSafeHeight + 32, bottom: 24 })
      }
      Column({ space: 20 }) {
        // 固定栏与 Scroll 平级，不用覆盖层遮住滚动内容，也不随二级设置的内容高度移动。
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            if (this.activeSection !== 'overview' && this.viewportWidth < 840) {
              Button() { AppIcon({ name: AppIconName.Back, iconSize: 20, color: this.theme.primary }) }
                .width(44).height(44).backgroundColor(this.theme.bgCard)
                .accessibilityText('返回常用设置').onClick(() => { this.selectSection_('overview') })
            }
            Column({ space: 4 }) {
              Text('AMCL / YOUR LAUNCHER').fontSize(12).fontColor(this.theme.textSecondary)
              Text(this.sectionTitle_()).fontSize(28).fontWeight(600).fontColor(this.theme.textPrimary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            AppIcon({ name: AppIconName.Settings, iconSize: 24, color: this.theme.primary })
          }.width('100%')
          TextInput({ placeholder: '搜索设置或功能', text: this.settingsQuery })
            .height(44).fontSize(14).borderRadius(22).backgroundColor(this.theme.bgCard).id('settings-fixed-search')
            .onChange((value: string): void => { this.changeSearch_(value) })
        }.width('100%').padding({ top: this.topSafeHeight + 16 }).backgroundColor(this.theme.bgPrimary)
        Scroll(this.contentScroller) {
          Column({ space: 20 }) {
            if (this.settingsQuery.trim().length > 0) {
              ForEach(this.visibleSections_(), (section: SettingsSection) => { this.SectionRow_(section) },
                (section: SettingsSection): string => section.id)
              if (this.visibleSections_().length === 0) {
                Text('没有匹配的设置，试试“内存”“日志”或“下载源”。').fontSize(14).fontColor(this.theme.textSecondary).padding(24)
              }
            } else if (this.activeSection === 'overview') {
              this.Overview_()
            } else if (this.activeSection === 'performance') {
              MotionSection({ order: 0 }) { this.MemorySection_() }
              MotionSection({ order: 1 }) { this.RuntimeSection_() }
            } else if (this.activeSection === 'controls') {
              MotionSection({ order: 0 }) { this.ControlsSection_() }
            } else if (this.activeSection === 'download') {
              MotionSection({ order: 0 }) { this.DownloadsSection_() }
            } else {
              MotionSection({ order: 0 }) { this.SupportSection_() }
            }
            Text('AMCL v' + APP_VERSION).fontSize(12).fontColor(this.theme.textSecondary)
              .width('100%').textAlign(TextAlign.Center).padding({ top: 8, bottom: 24 })
          }.width('100%').padding({ bottom: floatingDockReserveHeight(this.bottomSafeHeight) })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).id('settings-content-scroll')
          // 视口始终铺满，dock 覆盖在内容上方；仅内容尾部留可滚动余量，不截短整个页面。
      }.layoutWeight(1).height('100%')
    }.width('100%').height('100%').padding({ left: 20, right: 20 }).backgroundColor(this.theme.bgPrimary)
      .onAreaChange((_old: Area, current: Area) => { this.viewportWidth = Number(current.width) })
  }

  /** 600vp 起双栏；小屏的内存和 Java 卡片保留非对称比例。 */
  @Builder
  private Overview_() {
    Column({ space: 20 }) {
      Row() {
        Text('常用配置').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
        Blank()
        Text('全局生效').fontSize(12).fontColor(this.theme.textSecondary)
      }.width('100%')
      if (this.viewportWidth >= 600) {
        Row({ space: 20 }) {
          Column({ space: 20 }) {
            MotionSection({ order: 0 }) { this.QuickMemory_() }
            MotionSection({ order: 2 }) { this.QuickTheme_() }
          }.layoutWeight(1.35)
          Column({ space: 20 }) {
            MotionSection({ order: 1 }) { this.QuickJava_() }
            MotionSection({ order: 3 }) { this.LedgerShortcut_() }
          }.layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Top)
      } else {
        Row({ space: 12 }) {
          Column() { MotionSection({ order: 0 }) { this.QuickMemory_() } }.layoutWeight(1.6)
          Column() { MotionSection({ order: 1 }) { this.QuickJava_() } }.layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Top)
        MotionSection({ order: 2 }) { this.QuickTheme_() }
        MotionSection({ order: 3 }) { this.LedgerShortcut_() }
      }
      Text('按场景调整').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
      Column({ space: 2 }) {
        ForEach(SETTINGS_SECTIONS, (section: SettingsSection) => { this.SectionRow_(section) },
          (section: SettingsSection): string => section.id)
      }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(24)
      Button('关于 AMCL').height(44).fontSize(14).fontColor(this.theme.primary).backgroundColor(Color.Transparent)
        .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutPage' }) })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private QuickMemory_() {
    Column({ space: 12 }) {
      Button() {
        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Memory, iconSize: 20, color: this.theme.primary })
          Text('游戏内存').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).layoutWeight(1)
          AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textSecondary })
        }.width('100%')
      }.width('100%').height(44).padding(0).backgroundColor(Color.Transparent)
        .onClick(() => { this.selectSection_('performance') })
      Text((this.mcXmx / 1024).toFixed(this.mcXmx % 1024 === 0 ? 0 : 1) + ' GB')
        .fontSize(28).fontWeight(600).fontFamily('monospace').fontColor(this.theme.textPrimary).width('100%')
      Text('上限 ' + (this.xmxMax / 1024).toFixed(1) + ' GB').fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      Row({ space: 4 }) {
        ForEach(this.quickMemoryValues_(), (value: number) => {
          Button((value / 1024) + ' GB').height(44).layoutWeight(1).fontSize(12).padding({ left: 4, right: 4 })
            .fontColor(this.mcXmx === value ? this.theme.primary : this.theme.textSecondary)
            .backgroundColor(this.mcXmx === value ? this.theme.primaryLight : this.theme.bgInput)
            .onClick(() => { this.onXmxSliderChange(value, SliderChangeMode.Click) })
        }, (value: number): string => String(value))
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(this.theme.bgCard).borderRadius(24).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private QuickJava_() {
    Button() {
      Column({ space: 16 }) {
        Row() { AppIcon({ name: AppIconName.Java, iconSize: 24, color: this.theme.textOnPrimary }); Blank()
          AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 18, color: this.theme.textOnPrimary }) }.width('100%')
        Text(this.selectedJdkVersion === JDK_AUTO ? '自动' : this.selectedJdkVersion)
          .fontSize(28).fontWeight(600).fontColor(this.theme.textOnPrimary).width('100%')
        Text('Java 运行环境').fontSize(12).fontColor(this.theme.textOnPrimary).width('100%')
        Text(this.selectedJdkVersion === JDK_AUTO ? '按版本匹配' : '固定版本').fontSize(12).fontColor(this.theme.textOnPrimary).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').constraintSize({ minHeight: 214 }).padding(20).borderRadius(24)
      .backgroundColor(this.theme.actionPrimary).onClick(() => { this.selectSection_('performance') })
  }

  @Builder
  private QuickTheme_() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.Settings, iconSize: 20, color: this.theme.primary })
        Text('外观主题').fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
      }.width('100%')
      AnimatedPillBar({ labels: ['浅色', '深色', '自动'], theme: this.theme,
        selectedIndex: this.themeMode === ThemeMode.LIGHT ? 0 : this.themeMode === ThemeMode.DARK ? 1 : 2,
        onSelect: (index: number): void => {
          this.onThemeChange(index === 0 ? ThemeMode.LIGHT : index === 1 ? ThemeMode.DARK : ThemeMode.SYSTEM)
        } })
    }.width('100%').padding(20).borderRadius(24).backgroundColor(this.theme.bgCard)
  }

  @Builder
  private LedgerShortcut_() {
    Button() {
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.History, iconSize: 24, color: this.theme.primary })
        Column({ space: 4 }) {
          Text('活动账本').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary)
          Text('记录、日志与 AI 分析，一处回溯').fontSize(12).fontColor(this.theme.textSecondary).maxLines(2)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 18, color: this.theme.primary })
      }.width('100%')
    }.width('100%').padding(20).borderRadius(24).backgroundColor(this.theme.primaryLight)
      .onClick(() => { this.openLedger_() })
  }

  @Builder
  private SectionRow_(section: SettingsSection) {
    Button() {
      Row({ space: 12 }) {
        AppIcon({ name: section.icon, iconSize: 22, color: this.theme.primary })
        Column({ space: 4 }) {
          Text(section.title).fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary)
          Text(section.description).fontSize(12).fontColor(this.theme.textSecondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textSecondary })
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 76 }).padding(16).borderRadius(20)
      .backgroundColor(this.theme.bgCard).onClick(() => { this.selectSection_(section.id) })
  }

  /** 完整保留原有内存风险确认、虚拟内存回调和物理上限，增加精确值入口。 */
  @Builder
  private MemorySection_() {
    Column({ space: 20 }) {
      // 内存配置卡片
      Column() {
        this.SettingSectionTitle('内存配置')
        Row() {
          Text('JVM 最大内存')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary).layoutWeight(1)
          Text(this.mcXmx + ' MB')
            .fontSize(16).fontWeight(500)
            .fontColor(this.mcXmx > this.xmxRiskThreshold() ? this.theme.error : this.theme.primary)
        }
        .width('100%').height(48).alignItems(VerticalAlign.Center)

        Slider({ value: this.mcXmx, min: 512, max: this.xmxMax, step: 256 })
          .width('100%')
          .trackColor(this.theme.bgInput)
          .selectedColor(this.mcXmx > this.xmxRiskThreshold() ? this.theme.error : this.theme.primary)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.onXmxSliderChange(value, mode)
          })

        Text('设备物理内存上限 ' + this.xmxMax + ' MB · 建议不超过 '
          + this.xmxRiskThreshold() + ' MB（80%）')
          .fontSize(12).fontWeight(400).fontColor(this.theme.textHint)
          .width('100%').margin({ top: 2, bottom: 4 })

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        // 虚拟内存（堆文件）开关
        Row() {
          Column() {
            Text('虚拟内存（堆文件）')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('低内存设备跑大型整合包时开启：把 Java 堆放到存储上，避免世界生成被系统强杀。代价是加载/世界生成会变慢。')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ right: 12 })
          Toggle({ type: ToggleType.Switch, isOn: this.virtualMemoryMode })
            .onChange((isOn: boolean) => { this.onVirtualMemoryModeChange(isOn) })
        }
        .width('100%').padding({ top: 12, bottom: 8 }).alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 12 })
      .backgroundColor(this.theme.bgCard)
      .borderRadius(24)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
      Row({ space: 12 }) {
        TextInput({ text: this.xmxDraft, placeholder: '内存 MB' }).type(InputType.Number)
          .height(48).layoutWeight(1).fontColor(this.theme.textPrimary).backgroundColor(this.theme.bgCard)
          .onChange((value: string): void => { this.xmxDraft = value; this.memoryError = '' })
        Button('应用内存').height(48).onClick(() => { this.applyPreciseMemory_() })
      }.width('100%')
      if (this.memoryError.length > 0) {
        Text(this.memoryError).fontSize(12).fontColor(this.theme.error).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** Java 与 JVM 的持久化回调仍由 Index 提供，单版本覆盖语义不变。 */
  @Builder
  private RuntimeSection_() {
    Column() {
      if (ProductInputProfile.canChooseTabletProcess()) {
        Column({ space: 8 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('独立游戏进程').fontSize(16).fontWeight(500).fontColor(this.theme.textPrimary)
              Text(this.tabletIndependentGameProcess
                ? '推荐开启：游戏单独运行，退出后保留启动器。触控与渲染设置不变。'
                : '关闭后与启动器共用进程，退出或崩溃可能同时关闭启动器。')
                .fontSize(12).fontColor(this.theme.textHint)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.tabletIndependentGameProcess })
              .id('tabletIndependentGameProcessSwitch').width(52).height(44)
              .enabled(!this.tabletProcessSaving)
              .onChange((enabled: boolean): void => { this.onTabletProcessChange(enabled) })
          }.width('100%').alignItems(VerticalAlign.Center)
          Text(this.tabletProcessSaving ? '正在保存…' : this.tabletIndependentGameProcess !== this.tabletProcessActive
            ? '待重启生效 · 当前：' + (this.tabletProcessActive ? '独立进程' : '兼容模式')
            : '当前：' + (this.tabletProcessActive ? '独立进程' : '兼容模式') + ' · 修改后需重启启动器')
            .fontSize(12).fontColor(this.theme.primary).width('100%')
          if (this.tabletProcessMessage.length > 0) {
            Text(this.tabletProcessMessage).fontSize(12)
              .fontColor(this.tabletProcessMessage.startsWith('保存失败') ? this.theme.error : this.theme.textHint)
              .width('100%')
          }
        }.width('100%').padding({ top: 12, bottom: 16 }).alignItems(HorizontalAlign.Start)
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      }
      Column() {
        Text('Java 版本')
          .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
        Text('自动 = 按 MC 版本自动选择（推荐）；也可固定某个 JDK。JDK 8 为实验性，主要用于老版本 / 旧 Forge 调试。')
          .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
        Flex({ wrap: FlexWrap.Wrap }) {
          this.JdkChoiceChip(JDK_AUTO, '自动', '')
          this.JdkChoiceChip('8', 'JDK 8', '实验')
          this.JdkChoiceChip('17', 'JDK 17', '')
          this.JdkChoiceChip('21', 'JDK 21', '新')
          this.JdkChoiceChip('25', 'JDK 25', '新')
        }
        .width('100%').margin({ top: 12 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%').padding({ top: 12, bottom: 12 })

      Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      // 全局自定义 JVM 参数 —— 点击行标题就地展开编辑区（与版本详情的单版本参数同款交互）
      Column() {
        Row() {
          Column() {
            Text('自定义 JVM 参数')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('全局生效 · 空格分隔 · 单版本参数会在其后追加（优先级更高）')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)

          Row({ space: 6 }) {
            if (!this.jvmArgsExpanded && this.jvmArgsDraft.trim().length > 0) {
              Text('已设置')
                .fontSize(11).fontWeight(600).fontColor(this.theme.primary)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(8).backgroundColor(this.theme.bgInput)
            }
            AppIcon({
              name: this.jvmArgsExpanded ? AppIconName.ChevronUp : AppIconName.ChevronDown,
              iconSize: 16,
              color: this.theme.textHint,
            })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%').padding({ top: 12, bottom: 12 }).alignItems(VerticalAlign.Center)
        .onClick(() => {
          let willExpand = !this.jvmArgsExpanded
          if (!willExpand) this.saveCustomJvmArgs()   // 收起前先落盘
          this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
            this.jvmArgsExpanded = willExpand
          })
        })

        if (this.jvmArgsExpanded) {
          Column({ space: 8 }) {
            TextArea({
              text: this.jvmArgsDraft,
              placeholder: '例如：-Dsodium.checks.issue2561=true -XX:+UseStringDeduplication',
            })
              .width('100%')
              .height(96)
              .fontSize(13)
              .fontColor(this.theme.textPrimary)
              .backgroundColor(this.theme.bgInput)
              .borderRadius(10)
              .onChange((v: string) => { this.jvmArgsDraft = v })
              .onBlur(() => { this.saveCustomJvmArgs() })

            Text('留空使用默认配置。单版本参数在「版本管理 → 版本详情」中编辑。修改后需重新启动游戏生效。')
              .fontSize(12).fontColor(this.theme.textHint).width('100%')
          }
          .width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 8 })
        }
      }
      .width('100%')

      Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
    }
    .width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(24).alignItems(HorizontalAlign.Start)
  }

  /** 显示/控制复用现有产品组件，设备能力和发行渠道的开关不在此重定义。 */
  @Builder
  private ControlsSection_() {
    Column({ space: 20 }) {
      // 显示卡片
      Column() {
        this.SettingSectionTitle('显示')
        Row() {
          Text('主题')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary).layoutWeight(1)
          Row({ space: 6 }) {
            this.ThemeChip('浅色', ThemeMode.LIGHT)
            this.ThemeChip('深色', ThemeMode.DARK)
            this.ThemeChip('系统', ThemeMode.SYSTEM)
          }
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        Column() {
          Text('系统调度帧率上限')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
          Text('只约束 HarmonyOS 给游戏渲染面的调度提示，不修改 Minecraft 的最大帧率选项。自动 = 跟随当前显示刷新率。')
            .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          Flex({ wrap: FlexWrap.Wrap }) {
            this.FrameRateCapChip(0, '自动')
            this.FrameRateCapChip(30, '30')
            this.FrameRateCapChip(60, '60')
            this.FrameRateCapChip(90, '90')
            this.FrameRateCapChip(120, '120')
            this.FrameRateCapChip(144, '144')
            this.FrameRateCapChip(165, '165')
            this.FrameRateCapChip(240, '240')
          }
          .width('100%').margin({ top: 12 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%').padding({ top: 12, bottom: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(this.theme.bgCard)
      .borderRadius(24)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
      Column() {
        // 游戏语言（options.txt 的 lang）—— 全局默认；单版本可在「版本管理 → 版本详情」覆盖
        Row() {
          Column() {
            Text('游戏语言')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('进入游戏后的界面语言（默认简体中文）。单个版本可在「版本管理 → 版本详情」里单独设置。')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)

          Row({ space: 4 }) {
            Text(gameLanguageLabel(this.gameLanguage))
              .fontSize(13).fontWeight(500).fontColor(this.theme.primary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            AppIcon({ name: AppIconName.ChevronDown, iconSize: 12, color: this.theme.primary })
          }
          .constraintSize({ maxWidth: 150 })
          .height(44)
          .padding({ left: 12, right: 10 })
          .borderRadius(15)
          .backgroundColor(this.theme.primaryLight)
          .alignItems(VerticalAlign.Center)
          .bindMenu(this.buildGameLangMenu())
        }
        .width('100%').padding({ top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
        Row() {
          Column() {
            Text('版本隔离')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('每个版本独立存档、模组、资源包')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.versionIsolation })
            .onChange((isOn: boolean) => { this.onVersionIsolationChange(isOn) })
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)

        // 平板的实际路线由“游戏与性能”中的独立进程开关解释，不再并列一条错误的页面路线说明。
        if (!ProductInputProfile.canChooseTabletProcess()) {
          Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
          Row() {
            Column() {
              Text(ProductInputProfile.selection().desktopWindow ? '独立游戏窗口' : '新窗口模式')
                .fontSize(16).fontWeight(400).fontColor(this.theme.textHint)
              Text(ProductInputProfile.selection().desktopWindow
                ? '游戏在独立进程和窗口运行，可调整大小、最小化或全屏'
                : '游戏在启动器窗口内运行')
                .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: ProductInputProfile.selection().desktopWindow })
              .enabled(false).opacity(0.4)
          }.width('100%').height(56).alignItems(VerticalAlign.Center)
        }

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        ProductTouchSettings({ theme: this.theme })
        DesktopGamepadSettings({ theme: this.theme })
        MobileglRendererSettings({ theme: this.theme, mcDir: this.mcDir, mcVersion: this.mcVersion })

        ProductDeveloperSettings({ theme: this.theme })

      }
      .width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(24).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 下载源、数据位置与模组下载迁入同一分类，但保留所有原有回调与禁用条件。 */
  @Builder
  private DownloadsSection_() {
    Column({ space: 20 }) {
      Column() {
        // 游戏下载源偏好（client.jar / 依赖库 / 游戏资源 / 版本清单）
        Column() {
          Text('游戏下载源')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
          Text('自动 = 实测两边延迟选更快的（推荐）；镜像 = 固定 BMCLAPI 优先；官方 = 固定 Mojang 优先。选定的源永远排第一，另一个仍作为备源兜底，不会因此下载失败。')
            .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          Flex({ wrap: FlexWrap.Wrap }) {
            this.McSourceChip('auto', '自动')
            this.McSourceChip('mirror', '镜像')
            this.McSourceChip('official', '官方')
          }
          .width('100%').margin({ top: 12 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%').padding({ top: 12, bottom: 12 })

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        // JDK 下载源偏好
        Column() {
          Text('JDK 下载源')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
          Text('自动 = Gitee 国内直连优先（推荐）；源站 = 优先直连 GitHub（开代理/VPN 时最快，快过任何镜像）；Gitee = 强制国内镜像；镜像 = 只走 GitHub 加速代理。')
            .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          Flex({ wrap: FlexWrap.Wrap }) {
            this.JdkSourceChip('auto', '自动')
            this.JdkSourceChip('github', '源站')
            this.JdkSourceChip('gitee', 'Gitee')
            this.JdkSourceChip('mirror', '镜像')
          }
          .width('100%').margin({ top: 12 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%').padding({ top: 12, bottom: 12 })

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
        // 游戏数据位置：沙箱(默认,卸载即删) / 外部 Download/com.amcl.launcher(文件管理器显示为 AMCL,卸载不丢)
        Row() {
          Column() {
            Text('游戏数据位置')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text(this.storageLocation === 'external'
              ? '外部 · ' + (this.externalPathHint.length > 0 ? this.externalPathHint : 'Download/AMCL') + '（卸载不丢）'
              : (this.externalAvailable
                  ? '沙箱 · 应用私有（卸载即删）'
                  : '沙箱 · 应用私有（本设备不支持外部存储）'))
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Row({ space: 6 }) {
            this.StorageChip('沙箱', 'sandbox')
            this.StorageChip('外部', 'external')
          }
        }
        .width('100%').padding({ top: 12, bottom: 12 }).alignItems(VerticalAlign.Center)

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
      }
      .width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(24).alignItems(HorizontalAlign.Start)
      // 模组下载卡片
      Column() {
        this.SettingSectionTitle('模组下载')

        Row() {
          Column() {
            Text('数据源')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('auto=自动探测延迟，mcim=强制镜像，official=强制官方')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Row({ space: 6 }) {
            this.ModSourceChip('auto')
            this.ModSourceChip('mcim')
            this.ModSourceChip('official')
          }
        }
        .width('100%').padding({ top: 12, bottom: 12 })

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        if (DistributionPolicy.allowPublisherServices()) {
        Row() {
          Column() {
            Text('加速下载')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text(this.accelHint_())
              .fontSize(12).fontWeight(400).fontColor(this.accelHintColor_()).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.accelDownload })
            .onChange((isOn: boolean) => { this.onAccelDownloadChange(isOn) })
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        }

        Row() {
          Column() {
            Text('缓存远程元数据')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('缓存项目详情和版本列表，减少网络请求')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.cacheRemoteMeta })
            .onChange((isOn: boolean) => { this.onCacheRemoteMetaChange(isOn) })
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        Row() {
          Column() {
            Text('并发下载数')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('由 C++ 下载引擎自动管理（multi 64 + worker 8），暂无 UI 调节项')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('自动')
            .fontSize(13).fontColor(this.theme.textSecondary)
            .backgroundColor(this.theme.bgInput)
            .borderRadius(14)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        }
        .width('100%').padding({ top: 12, bottom: 12 }).alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 12 })
      .backgroundColor(this.theme.bgCard)
      .borderRadius(24)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 日志与帮助遵循原来的商店/侧载策略；不会隐式改为作者上报。 */
  @Builder
  private SupportSection_() {
    Column({ space: 20 }) {
      // 日志卡片
      Column() {
        this.SettingSectionTitle('日志')
        LogRetentionSettings({ theme: this.theme })
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
        Row() {
          Text('查看启动器运行日志')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary).layoutWeight(1)
          this.SettingNavChevron()
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)
        .onClick(() => { this.onOpenLog() })

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        Row() {
          Text('复制应用诊断摘要（脱敏）')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary).layoutWeight(1)
          this.SettingNavChevron()
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)
        .onClick(() => { this.onExportLog() })
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
        Row() {
          Text('最近游戏的完整日志').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1)
          this.SettingNavChevron()
        }.width('100%').height(56).onClick(() => { this.onOpenGameLog() })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(this.theme.bgCard)
      .borderRadius(24)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
      // 常见问题卡片（内嵌 AMCL-web 文档）
      Column() {
        this.SettingSectionTitle('常见问题')
        // 上架轨隐藏「怎么安装 / 无 JIT 解决办法」：正式上架经应用市场安装、JIT 在平板/2in1
        // 由系统授予，这两个问题均不存在；且这两篇文档在自有服务器上，上架轨不内嵌自有服务器内容。
        if (!DistributionPolicy.isStore()) {
          Row() {
            Column() {
              Text('怎么安装')
                .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
              Text('用 HoKit 侧载安装 AMCL 图文教程')
                .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            this.SettingNavChevron()
          }
          .width('100%').height(56).alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({
              url: 'pages/DocWebPage',
              params: { src: DOCS_INSTALL_URL, title: '怎么安装', fallback: DOCS_INSTALL_FALLBACK_URL },
            })
          })

          Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

          Row() {
            Column() {
              Text('JIT 的解决办法')
                .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
              Text('提示「JIT 不可用」时怎么办')
                .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            this.SettingNavChevron()
          }
          .width('100%').height(56).alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({
              url: 'pages/DocWebPage',
              params: { src: DOCS_NO_JIT_URL, title: 'JIT 的解决办法', fallback: DOCS_NO_JIT_FALLBACK_URL },
            })
          })

          Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
        }

        Row() {
          Column() {
            Text('网络检测')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('下载 / 搜索失败时，检测网络环境与下载源可达性')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          this.SettingNavChevron()
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)
        .onClick(() => { AppStorage.setOrCreate('amcl_open_netdiag_nonce', Date.now()) })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(this.theme.bgCard)
      .borderRadius(24)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
      // 支持作者卡片（内嵌 AMCL-web 赞助页）
      Column() {
        this.SettingSectionTitle('支持')
        Row() {
          Column() {
            Text('支持作者')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('请作者喝杯奶茶 · 赞助登记')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          this.SettingNavChevron()
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)
        .onClick(() => {
          // 上架轨（无自有服务器）：改为浏览器跳转，不内嵌自有服务器 WebView；侧载轨内嵌页原样。
          if (DistributionPolicy.isStore()) { this.openExternal_(AMCL_WEB_BASE + '/sponsor') }
          else { this.getUIContext().getRouter().pushUrl({ url: 'pages/SponsorPage' }) }
        })

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        Row() {
          Column() {
            Text('问题反馈')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text('报 Bug · 提建议 · 可附截图')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          this.SettingNavChevron()
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)
        .onClick(() => {
          // 上架轨（无自有服务器）：改为浏览器跳转，不内嵌自有服务器 WebView；侧载轨内嵌页原样。
          if (DistributionPolicy.isStore()) { this.openExternal_(AMCL_WEB_BASE + '/feedback') }
          else { this.getUIContext().getRouter().pushUrl({ url: 'pages/FeedbackPage' }) }
        })

        Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

        Row() {
          Column() {
            Text('关于')
              .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
            Text(DistributionPolicy.isStore() ? '版本信息 · GitHub · 联系方式' : '版本信息 · GitHub · 联系方式 · 检查更新')
              .fontSize(12).fontWeight(400).fontColor(this.theme.textHint).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          // 有可用更新时在箭头前显示红点（上架轨不做 GitHub 检查更新，故不显示红点）
          if (this.hasUpdate && !DistributionPolicy.isStore()) {
          Row().width(8).height(8).borderRadius(4).backgroundColor(this.theme.error).margin({ right: 8 })
          }
          this.SettingNavChevron()
        }
        .width('100%').height(56).alignItems(VerticalAlign.Center)
        .onClick(() => { this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutPage' }) })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .backgroundColor(this.theme.bgCard)
      .borderRadius(24)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 全局游戏语言选择 menu。当前选中项加 "✓" 前缀。 */
  private buildGameLangMenu(): MenuElement[] {
    let items: MenuElement[] = []
    for (let opt of GAME_LANGUAGES) {
      let prefix = (opt.code === this.gameLanguage) ? '✓  ' : '    '
      items.push({
        value: prefix + opt.label,
        action: () => { this.onGameLanguageChange(opt.code) },
      } as MenuElement)
    }
    return items
  }

  @Builder
  SettingSectionTitle(title: string) {
    Text(title)
      .fontSize(13).fontWeight(500).fontColor(this.theme.textHint)
      .width('100%').padding({ top: 8, bottom: 8 })
  }

  /** 设置项右侧的下一级箭头 —— 全部用同一个 SymbolGlyph，避免散在各 Text('›') 里 */
  @Builder
  SettingNavChevron() {
    AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textHint })
  }

  @Builder
  ThemeChip(label: string, mode: ThemeMode) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.themeMode === mode ? 500 : 400)
      .fontColor(this.themeMode === mode ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.themeMode === mode ? this.theme.primary : this.theme.bgInput)
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .constraintSize({ minHeight: 44 })
      .onClick(() => { this.onThemeChange(mode) })
  }

  /** OHOS 调度帧率上限 chip；0 显示为 Auto，其余值以 Hz 表示。 */
  @Builder
  FrameRateCapChip(value: number, label: string) {
    Text(value === 0 ? label : label + ' Hz')
      .fontSize(13)
      .fontWeight(this.ohosFrameRateCap === value ? 500 : 400)
      .fontColor(this.ohosFrameRateCap === value ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.ohosFrameRateCap === value ? this.theme.primary : this.theme.bgInput)
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8, bottom: 8 })
      .constraintSize({ minHeight: 44 })
      .onClick(() => { this.onOhosFrameRateCapChange(value) })
  }

  /**
   * 游戏数据存储位置 chip。外部不可用(本设备取不到 Download)时"外部"项置灰。
   * 点击通过 onStorageLocationChange 透传给父组件（Index 处理权限/迁移/落盘）。
   */
  @Builder
  StorageChip(label: string, loc: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.storageLocation === loc ? 500 : 400)
      .fontColor(this.storageLocation === loc ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.storageLocation === loc ? this.theme.primary : this.theme.bgInput)
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .opacity((loc === 'external' && !this.externalAvailable) ? 0.4 : 1)
      .constraintSize({ minHeight: 44 })
      .onClick(() => { this.onStorageLocationChange(loc) })
  }

  /** 用系统浏览器打开外部链接（上架轨的赞助/反馈跳转用，避免内嵌自有服务器 WebView）。 */
  private openExternal_(url: string): void {
    try {
      let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
      if (!ctx) return;
      let want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url,
      };
      ctx.startAbility(want);
    } catch (e) {
      hilog.error(0x0000, 'SettingsTab', 'openExternal failed: %{public}s', (e as Error).message);
      try {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开浏览器，请手动访问 ' + url, duration: 2500 });
      } catch (_) { /* ignore */ }
    }
  }

  /**
   * 加速开关的副标题。
   * 关闭时说明它做什么；打开时反馈真实状态（握手失败要让用户看得见，
   * 否则"开了但其实在直连"会造成误解）。
   */
  private accelHint_(): string {
    // 2026-08-04：文案改成与实际行为一致。加速**只**把官方源 URL 改写成经网关
    // （relay.cpp 的 relayCanAccelerate 只放行官方主机），镜像 URL 原样保留在候选列表里，
    // 上面几个源偏好依然生效。原文案说"忽略源偏好"是错的，会让用户以为换源没用。
    if (!this.accelDownload) {
      return '把官方源请求改走 AMCL 中转加速；镜像源不受影响，上面的源偏好照旧生效'
    }
    if (this.accelStatus === 'ok') {
      return '已就绪 · 官方源请求经加速网关（镜像源仍按你选的偏好直连）'
    }
    if (this.accelStatus.length === 0) {
      return '正在连接加速服务…'
    }
    return '加速不可用，已自动回退直连：' + this.accelStatus
  }

  private accelHintColor_(): ResourceColor {
    if (this.accelDownload && this.accelStatus.length > 0 && this.accelStatus !== 'ok') {
      return this.theme.warning
    }
    return this.theme.textHint
  }

  @Builder
  ModSourceChip(source: string) {
    Text(source)
      .fontSize(13)
      .fontWeight(this.modSource === source ? 500 : 400)
      .fontColor(this.modSource === source ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.modSource === source ? this.theme.primary : this.theme.bgInput)
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .constraintSize({ minHeight: 44 })
      .onClick(() => { this.onModSourceChange(source) })
  }

  /** 游戏下载源 chip。value 是持久化枚举（auto/mirror/official），label 是中文展示。 */
  @Builder
  McSourceChip(value: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.mcSource === value ? 500 : 400)
      .fontColor(this.mcSource === value ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.mcSource === value ? this.theme.primary : this.theme.bgInput)
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8, bottom: 8 })
      .constraintSize({ minHeight: 44 })
      .onClick(() => { this.onMcSourceChange(value) })
  }

  /** JDK 下载源 chip。value 是持久化的英文枚举（auto/github/gitee/mirror），label 是中文展示。 */
  @Builder
  JdkSourceChip(value: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.jdkSource === value ? 500 : 400)
      .fontColor(this.jdkSource === value ? this.theme.textOnPrimary : this.theme.textSecondary)
      .backgroundColor(this.jdkSource === value ? this.theme.primary : this.theme.bgInput)
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8, bottom: 8 })
      .constraintSize({ minHeight: 44 })
      .onClick(() => { this.onJdkSourceChange(value) })
  }

  /**
   * JDK 版本 chip。`isNew=true` 时右上角带"新"标，提示用户这是新加入的版本，
   * 相对默认 17 测试覆盖较少（不是"危险/实验性"，而是"还在收用户反馈"）。
   * 点击后通过 onJdkVersionChange 回调把 version 字符串透传给父组件。
   *
   * 设计决策（2026-05-18，用户确认 1.20.5 vanilla + Forge 已跑通后）：
   *   - 移除 ⚠️ 黄色警告角标，改为绿色"新"标
   *   - "新"语义中性，不会让用户产生"会出问题"的印象
   *   - 等 21 真机回归 N 个版本后（见 docs/ROADMAP.md P2-NEW），可整体移除该标
   */
  @Builder
  JdkChoiceChip(value: string, label: string, badge: string) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Text(label)
        .fontSize(13)
        .fontWeight(this.selectedJdkVersion === value ? 500 : 400)
        .fontColor(this.selectedJdkVersion === value ? this.theme.textOnPrimary : this.theme.textSecondary)
        .backgroundColor(this.selectedJdkVersion === value ? this.theme.primary : this.theme.bgInput)
        .borderRadius(16)
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .margin({ right: 8, bottom: 8 })
        .constraintSize({ minHeight: 44 })
        .onClick(() => { this.onJdkVersionChange(value) })
      if (badge.length > 0) {
        // 角标：'新'（绿色，中性）/ '实验'（橙色，提示实验性）
        Text(badge)
          .fontSize(9)
          .fontWeight(600)
          .fontColor('#FFFFFF')
          .backgroundColor(badge === '实验' ? '#FF9800' : '#4CAF50')
          .borderRadius(7)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ top: -3, right: 5 })
      }
    }
  }
}

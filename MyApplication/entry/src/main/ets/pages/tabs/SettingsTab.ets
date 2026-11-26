/**
 * AMCL 原生设置域：概览、具体项搜索、功能分区与确认式编辑面板。
 *
 * 本组件只消费 Index 发布的确认态并发送业务请求；偏好事务、存储迁移、JDK 更新、
 * 运行准入和设备能力继续归原服务所有。V1 状态范式与共同 HDS 标题宿主保持一致。
 * 手机使用单列，840 vp 起展示分类侧栏；1120 vp 起性能正文按可用宽度分成两列。
 */
import { LauncherSkillBus } from '../../launcherskill/LauncherSkillBus';
import { SettingsSkillData, settingFailure, settingKeys, settingText, nextSettingsReceipt } from '../../launcherskill/SettingsSkillValues';
import { themeAccentOptions, normalizePhoneSheetHeightPercent, DockLightMode, normalizeDockLightMode, copyImmersiveLightPreferences } from 'commons';
import { promptAction } from '@kit.ArkUI';
import { ThemeColors, ThemeMode, ThemeSelection, themeAccentLabel, ImmersiveLightPreferences, dockLightModeLabel,
  APP_VERSION, DOCS_INSTALL_URL, DOCS_INSTALL_FALLBACK_URL, DOCS_NO_JIT_URL,
  DOCS_NO_JIT_FALLBACK_URL, DeviceForm, Breakpoint, detailSheetHeightForLayout,
  DEFAULT_PHONE_SHEET_HEIGHT_PERCENT, JDK_AUTO, GAME_LANGUAGES, GameLanguageOption,
  gameLanguageLabel, AppIconName, floatingDockReserveHeight, DistributionPolicy, DiagnosticPolicy } from 'commons';
import { JdkVersionInfo } from 'launch';
import { ProductDeveloperSettings, developerToolRoute } from 'entry/ProductDeveloperSettings';
import { ProductTouchSettings } from 'entry/ProductTouchSettings';
import { ProductInputProfile } from 'entry/ProductInputProfile';

import { MobileglRendererSettings } from '../../components/MobileglRendererSettings';
import { GameResolutionSettings } from '../../components/GameResolutionSettings';
import { TouchLearningStore } from '../../components/TouchLearningStore';
import { AppIcon } from '../../components/AppIcon';
import { LogRetentionSettings } from '../../components/LogRetentionSettings';
import { AnimatedPillBar } from '../../components/AnimatedPillBar';
import { ThemeSettings } from '../../components/ThemeSettings';
import { PhoneSheetHeightSettings } from '../../components/PhoneSheetHeightSettings';
import { ImmersiveLightSettings } from '../../components/ImmersiveLightSettings';
import { ModAudioSettings } from '../../components/ModAudioSettings';
import { BluetoothMidiPermissionSettings } from '../../components/BluetoothMidiPermissionSettings';
import { ImmersiveTitleScaffold } from '../../components/ImmersiveTitleScaffold';
import { SettingsGroup, SettingsDivider, SettingsValueRow, SettingsToggleRow, SettingsHint } from '../../components/SettingsPrimitives';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SettingsCapabilities, SettingsSection, SettingsItem, SettingsChoice,
  SETTINGS_WIDE_WIDTH, settingsSections, settingsItems, searchSettings } from './SettingsCatalog';

@Component
export struct SettingsTab {
  /** 父页面统一发布有效运行能力；商店管理态保留主题、文件归属和下载配置。 */
  @Prop @Watch('onRunCapabilityChanged_') canRunGame: boolean = true
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
  @Prop themeSelection: ThemeSelection = new ThemeSelection()
  @Prop themeSaving: boolean = false
  /** 设备形态与已确认高度由父层发布；窗口变宽不会把手机误判为居中面板。 */
  @Prop deviceForm: DeviceForm = DeviceForm.PHONE
  @Prop phoneSheetHeightPercent: number = DEFAULT_PHONE_SHEET_HEIGHT_PERCENT
  /** 光感详情只消费父层的完整确认态；保存、回退和设备查询均留在父层。 */
  @Prop immersiveLight: ImmersiveLightPreferences = new ImmersiveLightPreferences()
  @Prop immersiveLightSaving: boolean = false
  @Prop immersiveLightHasPresets: boolean = false
  @Prop immersiveLightStatus: string = ''
  @Prop immersiveLightSaveError: string = ''
  /** Tab 隐藏不会卸载组件；显式可见性用于撤销设置二级页的系统返回消费资格。 */
  @Prop @Watch('syncSectionBack_') visible: boolean = false
  /** 内存不足处理复用搜索目录中的内存卡；父页先切 Tab，首次挂载和再次切换均能消费。 */
  @Link @Watch('syncSectionBack_') openMemoryRequested: boolean
  @Prop selectedJdkVersion: string = '17'
  @Prop versionIsolation: boolean = true
  @Prop useNewWindow: boolean = false
  /** 保存值与本进程有效值分别展示，不能把待重启设置显示为已经切换。 */
  @Prop tabletIndependentGameProcess: boolean = true
  @Prop tabletProcessActive: boolean = false
  @Prop tabletProcessSaving: boolean = false
  @Prop tabletProcessMessage: string = ''
  @Prop gameKeepScreenOn: boolean = true
  @Prop gameKeepScreenOnSaving: boolean = false
  /** 游戏数据存储位置：'sandbox' | 'external' */
  @Prop storageLocation: string = 'sandbox'
  /** 父层的 isExternalSupported 能力；手机目录准备和平板授权仍由父层切换流程完成。 */
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
  @Prop jdkVersions: JdkVersionInfo[] = []
  @Prop jdkChannel: string = 'stable'
  @Prop jdkWebEnabled: boolean = false
  @Prop jdkAutoCheck: boolean = true
  @Prop jdkChecking: boolean = false
  @Prop jdkHasUpdate: boolean = false
  @Prop jdkCatalogStatus: string = ''
  /** MC 版本下载源偏好：'auto'|'mirror'|'official'（client.jar / 依赖库 / 游戏资源）。 */
  @Prop mcSource: string = 'auto'
  /** 全局自定义 JVM 参数（空格分隔）。对所有版本生效；单版本参数会在其后追加。 */
  @Prop customJvmArgs: string = ''
  /** 全局游戏语言（options.txt lang code，如 'zh_cn'）。默认简体中文；单版本可覆盖。 */
  @Prop gameLanguage: string = 'zh_cn'
  /** OHOS XComponent 调度帧率上限。0 = 自动跟随显示刷新率；不修改游戏内 FPS 设置。 */
  @Prop ohosFrameRateCap: number = 0
  @Prop ohosFixedRefreshRate: number = 0
  /** 是否有可用更新（驱动「检查更新」行红点）。 */
  @Prop hasUpdate: boolean = false

  /** 由真实首页裁定弹窗、前台、初始化与扫描状态。 */
  skillInteractive: () => boolean = (): boolean => false;
  // 回调
  onXmxChange: (value: number) => Promise<boolean> = async (): Promise<boolean> => false
  onVirtualMemoryModeChange: (isOn: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  /** 主题选中立即更新显示，并由父层的同目录所有者耐久保存。 */
  onThemePreview: (selection: ThemeSelection | undefined) => void = () => {}
  onThemeSave: (selection: ThemeSelection) => Promise<void> = async (): Promise<void> => {}
  /** 高度编辑只提交百分比，不直接访问偏好或更改设备形态。 */
  onPhoneSheetHeightSave: (percent: number) => Promise<void> = async (): Promise<void> => {}
  onImmersiveLightChange: (preferences: ImmersiveLightPreferences) => Promise<boolean> = async (): Promise<boolean> => false
  /** 父页面保有系统返回优先级，设置页仅登记当前二级分区是否可以退回概览。 */
  onSectionBackReady: (handler: (() => boolean) | undefined) => void = () => {}
  onVersionIsolationChange: (isOn: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  onNewWindowChange: (isOn: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  /** 父页面负责等待保存/错误回滚；此组件不修改当前进程路线或正在运行的游戏。 */
  onTabletProcessChange: (enabled: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  /** 与其他运行设置一样由启动器保存，界面只展示父页面确认的值。 */
  onGameKeepScreenOnChange: (enabled: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  /** 用户切换游戏数据存储位置（'sandbox'|'external'）；父组件负责权限/迁移/落盘。 */
  onStorageLocationChange: (loc: string, migrate?: boolean, report?: (outcome: string) => void) => void = () => {}
  onOpenLog: () => void = () => {}
  /** 最近游戏通过父页面解析活动身份，与应用运行摘要保持明确的内容边界。 */
  onOpenGameLog: () => Promise<boolean> = async (): Promise<boolean> => false
  onExportLog: () => void = () => {}
  onCopySkillDiagnostic: () => Promise<boolean> = async (): Promise<boolean> => false;
  onReadDiagnosticSummary: () => string = (): string => '';
  readCommittedSettings: (item: string) => SettingsSkillData = (): SettingsSkillData => ({});
  onReadRelayStatus: () => SettingsSkillData = (): SettingsSkillData => ({});
  onModSourceChange: (value: string) => Promise<boolean> = async (): Promise<boolean> => false
  onCacheRemoteMetaChange: (isOn: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  /** 用户切换加速下载；父组件持久化 + 握手 + 注入 native */
  onAccelDownloadChange: (isOn: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  onModConcurrentDownloadsChange: (value: number) => void = () => {}
  /** 用户在 JDK 版本 chip 上做切换；父组件持久化到 prefs 并同步 jdkReady 状态。 */
  onJdkVersionChange: (version: string) => Promise<boolean> = async (): Promise<boolean> => false
  /** 用户切换 JDK 下载源；父组件持久化到 prefs 并注入 setJdkDownloadSource。 */
  onJdkSourceChange: (value: string) => Promise<boolean> = async (): Promise<boolean> => false
  onJdkChannelChange: (value: string) => Promise<boolean> = async (): Promise<boolean> => false
  onJdkWebChange: (enabled: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  onJdkAutoCheckChange: (enabled: boolean) => Promise<boolean> = async (): Promise<boolean> => false
  onCheckJdkUpdate: () => void = () => {}
  /** 用户切换 MC 版本下载源；父组件持久化到 prefs 并注入 setMcSourcePreference。 */
  onMcSourceChange: (value: string) => Promise<boolean> = async (): Promise<boolean> => false
  /** 用户编辑全局自定义 JVM 参数；父组件持久化到 prefs（PreferenceManager.customJvmArgs）。 */
  onCustomJvmArgsChange: (args: string) => Promise<void> = async (): Promise<void> => {}
  /** 用户切换全局游戏语言；父组件持久化到 prefs（PreferenceManager.gameLanguage）。 */
  onGameLanguageChange: (code: string) => Promise<boolean> = async (): Promise<boolean> => false
  /** 用户切换 OHOS 调度帧率上限；父组件持久化并同步到 native policy。 */
  onOhosFrameRateCapChange: (fpsCap: number) => Promise<boolean> = async (): Promise<boolean> => false
  onOhosFixedRefreshRateChange: (rate: number) => Promise<boolean> = async (): Promise<boolean> => false
  /** 用户点击「检查更新」；父组件拉 update.json 比对 versionCode 并提示结果。 */
  onCheckUpdate: () => void = () => {}

  /** 当前分区、搜索和编辑草稿只属于本次挂载；确认值始终来自父层 Prop。 */
  @State @Watch('syncSectionBack_') private activeSection: string = 'overview';
  @State private viewportWidth: number = 0;
  @State private settingsQuery: string = '';
  @State private xmxDraft: string = '';
  @State private memoryError: string = '';
  @State private highlightedItem: string = '';
  @State private showSettingsSheet: boolean = false;
  @State private sheetKind: string = '';
  @State private choiceDraft: string = '';
  @State private jvmArgsDraft: string = '';
  @State private jvmSaving: boolean = false;
  /** 等待用户选择或落盘时卸载原生 Toggle，结束后按已保存的值重建。 */
  @State private isolationPending_: boolean = false;
  @State private sheetError: string = '';
  @State private highXmxAck: boolean = false;
  private contentScroller: Scroller = new Scroller();
  private mounted_: boolean = false;
  private sheetClosing_: boolean = false;
  private sheetGeneration_: number = 0;
  private focusGeneration_: number = 0;
  private pendingStorage_: string = '';
  private pendingMigration_: boolean = false;
  private skillEditorRef_: string = '';
  private skillEditorKind_: string = '';
  private skillEditorState_: string = '';
  private skillStorageRequested_: string = '';
  private skillStorageSelected_: string = '';

  /** 返回资格只在本 Tab 真实可见时有效；优先退出局部草稿，再清搜索，最后回到概览。 */
  private sectionBackHandler_: () => boolean = (): boolean => {
    if (!this.mounted_ || !this.visible) return false;
    if (this.showSettingsSheet) { this.cancelSheet_(); return true; }
    if (this.settingsQuery.trim().length > 0) { this.changeSearch_(''); return true; }
    if (this.activeSection === 'graphics' || this.activeSection === 'resolution') {
      this.selectSection_('controls'); return true;
    }
    if (this.activeSection !== 'overview') { this.selectSection_('overview'); return true; }
    return false;
  };

  /** 首次挂载只初始化轻量草稿，不进行偏好读取、网络查询或额外设备探测。 */
  aboutToAppear(): void {
    this.mounted_ = true;
    this.skillChildTargets_.forEach((item: string, domain: string): void => {
      LauncherSkillBus.bindOpener(domain,this,(): boolean => {
        if (!this.mounted_ || !this.visible || !this.skillInteractive() || this.showSettingsSheet || this.sheetClosing_ || !this.hasItem_(item)) return false;
        if (item === 'graphics' || item === 'resolution') this.selectSection_(item);
        else this.openSearchItem_(item);
        return true;
      });
    });
    LauncherSkillBus.bind('settings', this, (method: string, args: SettingsSkillData): Promise<SettingsSkillData> =>
      this.runSettingsSkill_(method, args), (): boolean => this.mounted_ && this.visible && this.skillInteractive());
    this.xmxDraft = String(this.mcXmx);
    this.syncSectionBack_();
  }

  /** 退出仅撤销显示权；已经交给父层的耐久保存继续由原 owner 完成。 */
  aboutToDisappear(): void {
    this.skillChildTargets_.forEach((_item: string,domain: string): void => { LauncherSkillBus.unbindOpener(domain,this); });
    LauncherSkillBus.unbind('settings', this);
    this.mounted_ = false;
    this.sheetGeneration_++;
    this.focusGeneration_++;
    this.withdrawStorageIntent_();
    this.onSectionBackReady(undefined);
  }

  /** 产品能力只转译原策略，不在 UI 中重新决定某个设备或发行包支持什么。 */
  private capabilities_(): SettingsCapabilities {
    return { run: this.canRunGame, store: DistributionPolicy.isStore(),
      publisher: DistributionPolicy.allowPublisherServices(),
      touch: ProductInputProfile.supportsTouchLayouts(),
      chooseInteraction: ProductInputProfile.canChooseInteraction(),
      mobileInput: ProductInputProfile.canChooseMobileInput(),
      tabletProcess: ProductInputProfile.canChooseTabletProcess(),
      developer: DiagnosticPolicy.hasTestHooks(), fixedRefreshRate: deviceInfo.sdkApiVersion >= 20 };
  }

  private availableSections_(): SettingsSection[] { return settingsSections(this.capabilities_()); }
  private availableItems_(): SettingsItem[] { return settingsItems(this.capabilities_()); }
  private searchResults_(): SettingsItem[] { return searchSettings(this.availableItems_(), this.settingsQuery); }
  private hasItem_(id: string): boolean { return this.availableItems_().some((item: SettingsItem): boolean => item.id === id); }

  /** 保留分区检索入口供现有回归使用，实际 UI 展示的是同库存的具体设置项结果。 */
  private visibleSections_(): SettingsSection[] {
    const results: SettingsItem[] = this.searchResults_();
    return this.availableSections_().filter((section: SettingsSection): boolean =>
      this.settingsQuery.trim().length === 0 || results.some((item: SettingsItem): boolean => item.section === section.id));
  }

  /** Tab 隐藏时关闭未提交草稿与定位资格；迟到保存不得向再次打开的面板发布状态。 */
  private syncSectionBack_(): void {
    if (!this.mounted_) return;
    if (this.visible && this.openMemoryRequested) {
      this.openMemoryRequested = false;
      this.openSearchItem_('memory');
    }
    if (!this.visible) {
      this.sheetGeneration_++;
      this.focusGeneration_++;
      this.withdrawStorageIntent_();
      if (this.showSettingsSheet) this.sheetClosing_ = true;
      this.showSettingsSheet = false;
      this.jvmSaving = false;
    }
    const ready: boolean = this.visible && (this.showSettingsSheet || this.settingsQuery.trim().length > 0 || this.activeSection !== 'overview');
    this.onSectionBackReady(ready ? this.sectionBackHandler_ : undefined);
  }

  /** 准入被撤回后重建目录并退出失效分区；不提交被关闭的 Java/JVM 等运行草稿。 */
  private onRunCapabilityChanged_(): void {
    this.cancelSheet_();
    this.settingsQuery = '';
    if (!this.availableSections_().some((section: SettingsSection): boolean => section.id === this.activeSection)) {
      this.activeSection = 'overview';
    }
    this.highlightedItem = '';
    this.focusGeneration_++;
    this.syncSectionBack_();
  }

  /** 分区切换永远不保存编辑草稿，并显式停止上一分区的惯性滚动。 */
  private selectSection_(section: string): void {
    if (section === 'immersive') section = 'appearance';
    if (section !== 'overview' && !((section === 'graphics' || section === 'resolution') && this.canRunGame)
      && !this.availableSections_().some((item: SettingsSection): boolean => item.id === section)) section = 'overview';
    this.cancelSheet_();
    // 搜索框在宽屏仍保留挂载；主动结束其焦点，防止浮动输入法继续遮住已打开的设置。
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_) { /* 页面退役时无需再操作焦点。 */ }
    this.activeSection = section;
    this.settingsQuery = '';
    this.xmxDraft = String(this.mcXmx);
    this.memoryError = '';
    this.highlightedItem = '';
    this.focusGeneration_++;
    this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
    this.syncSectionBack_();
  }

  /** 查询变化只影响本地库存及滚动位置，不调用任何配置写入或网络服务。 */
  private changeSearch_(value: string): void {
    // TextInput可能回送父层已发布的清空值；同值通知不能撤销刚建立的目标高亮和定位。
    if (value === this.settingsQuery) return;
    this.settingsQuery = value;
    this.highlightedItem = '';
    this.focusGeneration_++;
    this.contentScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
    this.syncSectionBack_();
  }

  private sectionTitle_(): string {
    if (this.activeSection === 'graphics' && this.canRunGame) return '图形后端';
    if (this.activeSection === 'resolution' && this.canRunGame) return '游戏分辨率';
    return this.availableSections_().find((section: SettingsSection): boolean => section.id === this.activeSection)?.title ?? '设置';
  }
  private sectionIcon_(id: string): AppIconName {
    if (id === 'performance') return AppIconName.Memory;
    if (id === 'controls') return AppIconName.GameController;
    if (id === 'appearance') return AppIconName.Appearance;
    if (id === 'download') return AppIconName.Download;
    if (id === 'files') return AppIconName.Folder;
    return AppIconName.Help;
  }

  /** 入口再次用实时目录校验，避免旧搜索结果在产品能力变化后打开已隐藏的功能。 */
  private async openSearchItem_(id: string): Promise<boolean> {
    const item: SettingsItem | undefined = this.availableItems_().find((candidate: SettingsItem): boolean => candidate.id === id);
    if (item === undefined) return false;
    if (item.section === 'about') return this.openPage_('pages/AboutPage');
    if (item.section === 'ledger') return this.openLedger_();
    // 设置搜索与总览共用常驻更新入口，允许在更新任务以外查看并完成开发者登录。
    if (item.section === 'software-update') return this.openPage_('pages/SoftwareUpdatePage');
    // 分辨率包含自身的作用域、保存与继承操作，搜索直接进入同一个详情页，避免跨分区
    // 首次布局/键盘收起时对尚未稳定的长卡片坐标重复补偿而滚过目标。
    if (id === 'resolution') { this.selectSection_('resolution'); return true; }
    this.selectSection_(item.section);
    this.highlightedItem = item.id;
    return true;
  }

  /**
   * 目标与视口均采用当前 UIContext 查询的窗口像素坐标，转换为 Scroller 所需的 vp。
   * 由布局回调触发，不猜测父子 onAreaChange 顺序，也不把局部 Area.position 当整页偏移。
   */
  private locateItem_(id: string): void {
    if (!this.mounted_ || !this.visible || this.highlightedItem !== id) return;
    try {
      const context = this.getUIContext();
      const target = context.getComponentUtils().getRectangleById('settings-item-' + id);
      const viewport = context.getComponentUtils().getRectangleById('settings-content-scroll');
      if (target.size.width <= 0 || target.size.height <= 0 || viewport.size.height <= 0) return;
      const offset: number = Math.max(0, this.contentScroller.currentOffset().yOffset
        + context.px2vp(target.windowOffset.y - viewport.windowOffset.y) - 12);
      this.contentScroller.scrollTo({ xOffset: 0, yOffset: offset, animation: false });
    } catch (_) { /* 未完成布局时保持目标标记，后续目标/视口布局回调会再次尝试。 */ }
  }

  /** 视口后完成布局时再核对一次目标，解决目标先于视口就绪的合法顺序。 */
  private locatePending_(): void { if (this.highlightedItem.length > 0) this.locateItem_(this.highlightedItem); }
  private onXmxChanged_(): void { this.xmxDraft = String(this.mcXmx); }
  private xmxRiskThreshold(): number { return Math.max(512, Math.floor(this.xmxMax * 0.8 / 256) * 256); }
  private quickMemoryValues_(): number[] { return [2048, 4096, 6144].filter((value: number): boolean => value <= this.xmxMax); }
  private memoryLabel_(): string { return this.mcXmx > 0 ? (this.mcXmx / 1024).toFixed(this.mcXmx % 1024 === 0 ? 0 : 1) + ' GB' : '未设置'; }

  /** 三种内存入口共享范围、粒度和风险确认，精确输入不会绕过滑块的保护。 */
  private applyPreciseMemory_(): void {
    const value: number = Number(this.xmxDraft);
    if (!Number.isInteger(value) || value < 512 || value > this.xmxMax || value % 256 !== 0) {
      this.memoryError = '请输入 512–' + this.xmxMax + ' MB，且为 256 的整数倍';
      return;
    }
    this.memoryError = '';
    this.onXmxSliderChange(value, SliderChangeMode.Click);
  }

  /** 风险确认只在松手/点击发生；拖动越界时先保持建议阈值，避免连续弹窗。 */
  private async onXmxSliderChange(value: number, mode: SliderChangeMode): Promise<boolean> {
    const threshold: number = this.xmxRiskThreshold();
    if (value <= threshold || this.highXmxAck) return this.onXmxChange(value);
    if (mode !== SliderChangeMode.End && mode !== SliderChangeMode.Click) return this.onXmxChange(threshold);
    return this.confirmHighXmx(value, threshold);
  }

  /** 松开滑块的原风险选择同样等待实际偏好所有者，失败不会发布目标容量。 */
  private async confirmHighXmx(value: number, threshold: number): Promise<boolean> {
    let desired: number = threshold;
    try {
      const answer = await this.getUIContext().getPromptAction().showDialog({title:'内存分配过高',
        message:'选择了 '+value+' MB，超过建议的 '+threshold+' MB，游戏还需要图形和其他内存。',
        buttons:[{text:'使用建议值',color:this.theme.actionText as string},{text:'仍要使用',color:this.theme.errorText as string}]});
      if (!this.mounted_ || !this.visible) return false;
      if (answer.index === 1) { this.highXmxAck = true; desired = value; }
    } catch (_) { if (!this.mounted_ || !this.visible) return false; }
    return this.onXmxChange(desired);
  }

  /** 稳定的可见项 id 同时定义单选入口资格，能力撤回或目录换代时不能提交旧候选。 */
  /** 可见目录是页面与系统能力的共同白名单。忙碌或失效的视图不会替用户提交设置。 */
  private async runSettingsSkill_(method: string, args: SettingsSkillData): Promise<SettingsSkillData> {
    if (!this.mounted_ || !this.visible || !this.skillInteractive()) return settingFailure('notInteractive');
    if (method === 'readSettingHandoff') {
      if (!settingKeys(args,['reference']) || !this.skillEditorRef_ || args['reference'] !== this.skillEditorRef_) return settingFailure('editorExpired');
      const reply: SettingsSkillData = {'state':'ready','reference':this.skillEditorRef_,'item':this.skillEditorKind_,'outcome':this.skillEditorState_};
      if (this.skillEditorKind_ === 'storage') {
        if (this.skillStorageRequested_) reply['requestedTarget'] = this.skillStorageRequested_;
        if (this.skillStorageSelected_) reply['selectedTarget'] = this.skillStorageSelected_;
      }
      return reply;
    }
    if (method === 'navigateLauncherSettings' && settingKeys(args,['section'])) {
      const section=settingText(args,'section');
      if (section === 'back') {
        if (this.jvmSaving || this.sheetClosing_) return settingFailure('busy');
        this.sectionBackHandler_();
      } else if (section === 'clearSearch') this.changeSearch_('');
      else if (!this.showSettingsSheet && !this.sheetClosing_ && (section === 'overview' ||
        this.availableSections_().some((item: SettingsSection): boolean => item.id === section))) this.selectSection_(section);
      else return settingFailure('sectionUnavailable');
      return {'state':'ready','section':this.activeSection,'editorOpen':this.showSettingsSheet};
    }
    const child = this.skillChildMethods_.get(method);
    if (child) {
      const item = this.skillChildTargets_.get(child);
      if (!item || !this.hasItem_(item) || this.showSettingsSheet || this.sheetClosing_) return settingFailure('settingUnavailable');
      return LauncherSkillBus.forward(this,child,method,args);
    }
    if (method === 'findLauncherSettings') {
      if (!settingKeys(args, []) && !settingKeys(args, ['query'])) return settingFailure('invalidArguments');
      const query = settingText(args, 'query');
      if (query.length > 128 || (args['query'] !== undefined && typeof args['query'] !== 'string')) return settingFailure('invalidArguments');
      const items = query.trim() ? searchSettings(this.availableItems_(), query) : this.availableItems_();
      return { 'state': 'ready', 'items': items.map((item: SettingsItem): SettingsSkillData =>
        ({ 'item': item.id, 'section': item.section, 'title': item.title })), 'section': this.activeSection };
    }
    if (method === 'readLauncherSetting') {
      if (!settingKeys(args, ['item'])) return settingFailure('invalidArguments');
      const id = settingText(args, 'item');
      return this.hasItem_(id) ? this.readSkillSetting_(id) : settingFailure('settingUnavailable');
    }
    if (this.showSettingsSheet || this.sheetClosing_) return settingFailure('editorAlreadyOpen');
    if (method === 'openLauncherSetting') {
      if (!settingKeys(args, ['item'])) return settingFailure('invalidArguments');
      return this.openSkillSetting_(settingText(args, 'item'));
    }
    if (method === 'openLauncherDiagnostic' && settingKeys(args,['tool'])) {
      if (!this.hasItem_('developer') || !DiagnosticPolicy.hasTestHooks()) return settingFailure('notAvailable');
      const tool=settingText(args,'tool');
      const route = developerToolRoute(tool);
      if (!route) return settingFailure('toolUnavailable');
      const router = this.getUIContext().getRouter();
      await router.pushUrl({url:route});
      const page = router.getState().name;
      if (page !== route && 'pages/' + page !== route) return { 'state':'unknown','reason':'destinationUnconfirmed' };
      return {'state':'needsUser','tool':tool,'reason':'performDiagnosticsInApp'};
    }
    if (method === 'prepareStorageChange' && settingKeys(args,['target'])) {
      const target=settingText(args,'target');
      if (!this.hasItem_('storage') || !this.choiceOptions_('storage').some((o: SettingsChoice): boolean => o.value === target && o.enabled)) return settingFailure('storageUnavailable');
      if (this.storageLocation === target) {
        // 当前会话可能临时回退沙箱。只有持久选择也一致，才能直接返回而跳过用户确认。
        const stored = this.readSkillSetting_('storage');
        if (stored['state'] !== 'ready' || stored['value'] === target) return stored;
      }
      this.openSheet_('storage');
      if (!this.showSettingsSheet || this.sheetKind !== 'storage') return settingFailure('editorUnavailable');
      this.choiceDraft=target;
      return this.beginSkillEditor_('storage',method,target);
    }
    if (method === 'setLauncherChoice') {
      if (!settingKeys(args, ['item','value']) || typeof args['value'] !== 'string') return settingFailure('invalidArguments');
      const id = settingText(args, 'item');
      const value = settingText(args, 'value');
      if (!this.hasItem_(id) || id === 'storage') return settingFailure('settingUnavailable');
      const kind = this.skillChoiceKind_(id);
      if (!kind || !this.choiceOptions_(kind).some((option: SettingsChoice): boolean =>
        option.value === value && option.enabled)) return settingFailure('invalidChoice');
      if (!await this.submitChoice_(kind,value)) return settingFailure('settingNotSaved');
      const confirmed=this.readSkillSetting_(id);
      return confirmed['value'] === value ? confirmed : settingFailure('settingChanged');
    }
    if (method === 'setLauncherSwitch') return await this.skillSwitch_(args);
    if (method === 'copyLauncherDiagnostic' && settingKeys(args,[])) {
      if (!this.hasItem_('diagnostics')) return settingFailure('notAvailable');
      LauncherSkillBus.awaitingUser(method);
      const confirm = await this.getUIContext().getPromptAction().showDialog({ title:'复制本机诊断摘要？',
        message:'将脱敏后的启动器日志摘要写入系统剪贴板，系统智能体只收到复制结果。',
        buttons:[{text:'取消',color:this.theme.textSecondary as string},{text:'复制',color:this.theme.actionText as string}]});
      if (confirm.index !== 1) return {'state':'cancelled'};
      if (!this.mounted_ || !this.visible || !this.skillInteractive()) return settingFailure('ownerChanged');
      return await this.onCopySkillDiagnostic() ? {'state':'ready','copied':true} : settingFailure('copyFailed');
    }
    if (method === 'setLauncherAppearance') {
      if (!settingKeys(args,['mode','accent']) || !this.hasItem_('theme')) return settingFailure('invalidArguments');
      const mode = settingText(args,'mode');
      const accent = themeAccentOptions().find(option => option.id === args['accent']);
      if (!accent || !['system','light','dark'].includes(mode)) return settingFailure('invalidArguments');
      const target = new ThemeSelection(mode === 'system' ? ThemeMode.SYSTEM : mode === 'light' ? ThemeMode.LIGHT : ThemeMode.DARK, accent.id);
      await this.onThemeSave(target);
      return { 'state':'ready', 'mode':mode, 'accent':accent.id };
    }
    if (method === 'setLauncherSheetHeight') {
      const percent = args['percent'];
      if (!settingKeys(args,['percent']) || this.deviceForm !== DeviceForm.PHONE || !this.hasItem_('phone-sheet-height') || typeof percent !== 'number' ||
        !Number.isInteger(percent) || normalizePhoneSheetHeightPercent(percent) !== percent) return settingFailure('invalidHeight');
      await this.onPhoneSheetHeightSave(percent);
      return { 'state':'ready', 'percent':percent };
    }
    if (method === 'setLauncherLightMaterial') return this.skillLight_(args);
    if (method === 'setLauncherMemory') {
      const value = args['megabytes'];
      if (!this.hasItem_('memory') || !settingKeys(args,['megabytes']) || typeof value !== 'number' ||
        !Number.isInteger(value) || value < 512 || value > this.xmxMax || value % 256 !== 0) return settingFailure('invalidMemory');
      if (value > this.xmxRiskThreshold() && !this.highXmxAck) LauncherSkillBus.awaitingUser(method);
      if (!await this.onXmxSliderChange(value, SliderChangeMode.Click)) return settingFailure('settingNotSaved');
      return this.readSkillSetting_('memory');
    }
    if (method === 'scheduleTouchGuide') {
      if (!settingKeys(args,[]) || !this.hasItem_('touch-help')) return settingFailure('notAvailable');
      const before=this.readSkillSetting_('touch-help');
      if (before['state'] !== 'ready') return before;
      if (before['requested'] !== true) this.requestTouchGuide_();
      const after=this.readSkillSetting_('touch-help');
      return after['state']==='ready' && after['requested']!==true ? settingFailure('guideNotSaved') : after;
    }
    return settingFailure('unsupportedMethod');
  }

  private skillChoiceKind_(id: string): string {
    if (id === 'frame-rate') return 'frame';
    if (id === 'jdk-update') return 'jdk-channel';
    return ['java','fixed-refresh-rate','language','mc-source','mod-source','jdk-source','storage'].includes(id) ? id : '';
  }

  /** 子组件的视觉开关、存储事务与系统权限由其当前所有者执行。 */
  private skillChildTargets_: Map<string,string> = new Map<string,string>([
    ['settingsGraphics','graphics'],['settingsResolution','resolution'],['settingsRetention','retention'],
    ['settingsMic','mod-audio'],['settingsMidi','mod-audio'],['settingsInteraction','interaction'],
    ['settingsMobileInput','mobile-input']
  ]);
  private skillChildMethods_: Map<string,string> = new Map<string,string>([
    ['listGraphicsBackends','settingsGraphics'],['selectGraphicsBackend','settingsGraphics'],
    ['getGlobalResolution','settingsResolution'],['setGlobalResolution','settingsResolution'],
    ['getGameLogRetention','settingsRetention'],['setGameLogRetention','settingsRetention'],
    ['bluetoothMidiAccess','settingsMidi'],['configureModMicrophone','settingsMic'],['getModMicrophone','settingsMic'],
    ['getDesktopInteraction','settingsInteraction'],['setDesktopInteraction','settingsInteraction'],
    ['getMobileInputMode','settingsMobileInput'],['setMobileInputMode','settingsMobileInput'],
  ]);

  private readSkillSetting_(id: string): SettingsSkillData {
    const result: SettingsSkillData = { 'state':'ready','item':id };
    const kind = this.skillChoiceKind_(id);
    let stored: SettingsSkillData;
    try { stored=this.readCommittedSettings(id); } catch (_) { return {'state':'unknown','item':id,'reason':'settingUnreadable'}; }
    if (stored['confirmed'] !== true) return {'state':'unknown','item':id,'reason':'preferenceUnconfirmed'};
    if (kind) {
      if ((kind==='jdk-source' && stored['jdk-web'] !== this.jdkWebEnabled) ||
        (kind==='fixed-refresh-rate' && stored['cap'] !== this.ohosFrameRateCap)) return {'state':'unknown','item':id,'reason':'choicesChanged'};
      result['value'] = String(stored[id]);
      result['choices'] = this.choiceOptions_(kind).map((o: SettingsChoice): SettingsSkillData =>
        ({'value':o.value, 'enabled':o.enabled,'title':o.title}));
    }
    switch (id) {
      case 'theme':
        result['mode'] = stored['mode'];
        result['accent'] = stored['accent'];
        break;
      case 'phone-sheet-height': result['percent'] = stored['percent']; break;
      case 'immersive':
        result['enabled'] = stored['enabled']; result['navigation'] = stored['navigation'];
        result['bottomBar'] = stored['bottomBar']; result['titleButtons'] = stored['titleButtons'];
        result['manualMaterial'] = this.immersiveLightHasPresets; result['saving'] = this.immersiveLightSaving;
        result['saveFailed'] = this.immersiveLightSaveError.length > 0;
        break;
      case 'memory': result['megabytes'] = stored['memory']; result['max'] = this.xmxMax; break;
      case 'virtual-memory': result['enabled'] = stored['virtual-memory']; break;
      case 'isolation': result['enabled'] = stored['isolation']; break;
      case 'game-keep-screen-on': result['enabled'] = stored['game-keep-screen-on']; break;
      case 'process': result['enabled'] = stored['process']; result['active'] = this.tabletProcessActive; result['saving']=this.tabletProcessSaving; break;
      case 'window': result['independent'] = ProductInputProfile.selection().desktopWindow; break;
      case 'remote-cache': result['enabled'] = stored['remote-cache']; break;
      case 'acceleration': result['enabled'] = stored['acceleration']; result['relay'] = this.onReadRelayStatus(); break;
      case 'download-concurrency': result['policy'] = 'automatic'; break;
      case 'jdk-source': result['publisherEnabled'] = stored['jdk-web']; break;
      case 'jdk-update': result['autoCheck'] = stored['jdk-auto']; result['checking'] = this.jdkChecking; result['available'] = this.jdkHasUpdate; break;
      case 'jvm': result['hasCustomArguments'] = stored['hasCustomArguments']; break;
      case 'diagnostics': result['summary'] = this.onReadDiagnosticSummary(); break;
      case 'software-update':
        result['delivery'] = DistributionPolicy.isStore() ? 'appMarket' : 'sideload';
        result['currentVersion'] = stored['currentVersion'];
        result['currentCode'] = stored['currentCode'];
        break;
      case 'touch-help': {
        const ctx = this.getUIContext().getHostContext();
        if (!ctx) return settingFailure('contextUnavailable');
        try { result['requested'] = new TouchLearningStore(ctx.filesDir).strictRequested(); }
        catch (_) { return {'state':'unknown','reason':'guideUnreadable'}; }
        break;
      }
      default: if (!kind) return { 'state':'needsUser','item':id }; break;
    }
    return result;
  }

  /** 玩家与系统共用隔离确认。取消、页面离开或原值变化时保留已保存的目录选择。 */
  private async requestIsolation_(enabled: boolean, fromSkill: boolean = false): Promise<SettingsSkillData> {
    if (this.isolationPending_) return settingFailure('busy');
    const before = this.readSkillSetting_('isolation');
    if (before['state'] !== 'ready') return before;
    const baseline = this.versionIsolation;
    if (before['enabled'] !== baseline) return settingFailure('settingChanged');
    if (baseline === enabled) return before;
    const generation = this.sheetGeneration_;
    this.isolationPending_ = true;
    try {
      if (!enabled || fromSkill) {
        if (fromSkill) LauncherSkillBus.awaitingUser('setLauncherSwitch');
        const answer: promptAction.ShowDialogSuccessResponse | undefined = await this.getUIContext().getPromptAction().showDialog({
          title: enabled ? '开启版本隔离？' : '关闭版本隔离？',
          message: enabled ? '普通版本将重新使用各自目录里的存档和模组。共享目录里的内容会留在原处。' :
            '关闭后，普通版本将共用存档和模组。原先独立的存档和模组会保留，重新开启隔离后可以继续使用。关闭期间新增的共享存档和模组会留在共享目录。整合包继续独立使用自己的目录。',
          buttons: [{ text: '取消', color: this.theme.textSecondary as string },
            { text: enabled ? '开启隔离' : '关闭隔离', color: (enabled ? this.theme.actionText : this.theme.errorText) as string }]
        }).catch((): undefined => undefined);
        if (answer?.index !== 1) return {'state':'cancelled','item':'isolation'};
        if (!this.mounted_ || !this.visible || this.sheetGeneration_ !== generation ||
          (fromSkill && !this.skillInteractive()) || this.versionIsolation !== baseline ||
          this.readSkillSetting_('isolation')['enabled'] !== baseline) return settingFailure('settingChanged');
      }
      if (!await this.onVersionIsolationChange(enabled)) return settingFailure('settingNotSaved');
      const result = this.readSkillSetting_('isolation');
      return result['enabled'] === enabled ? result : settingFailure('settingNotSaved');
    } catch (_) {
      return settingFailure('settingNotSaved');
    } finally {
      this.isolationPending_ = false;
    }
  }

  /** 高影响偏好在当前界面询问具体值，用户答复后重新检查可见状态与原基线。 */
  private async skillSwitch_(args: SettingsSkillData): Promise<SettingsSkillData> {
    if (!settingKeys(args,['item','enabled']) || typeof args['enabled'] !== 'boolean') return settingFailure('invalidArguments');
    const key = settingText(args, 'item');
    const id = key === 'jdk-web' ? 'jdk-source' : key === 'jdk-auto' ? 'jdk-update' : key;
    if (!this.hasItem_(id)) return settingFailure('settingUnavailable');
    const enabled = args['enabled'] as boolean;
    if (key === 'isolation') return await this.requestIsolation_(enabled, true);
    if (key === 'process') {
      const baseline = this.tabletIndependentGameProcess;
      if (baseline === enabled && this.readCommittedSettings(key)[key] === enabled) return this.readSkillSetting_(id);
      LauncherSkillBus.awaitingUser('setLauncherSwitch');
      const answer = await this.getUIContext().getPromptAction().showDialog({title:'更改启动器设置？', message:(enabled?'开启':'关闭')+'下次启动的独立游戏进程',
        buttons:[{text:'取消',color:this.theme.textSecondary as string},{text:'确认',color:this.theme.actionText as string}]});
      if (answer.index !== 1) return { 'state':'cancelled','item':id };
      if (!this.mounted_ || !this.visible || !this.skillInteractive() || !this.hasItem_(id) ||
        this.tabletIndependentGameProcess !== baseline) return settingFailure('settingChanged');
    }
    let saved=false;
    switch (key) {
      case 'virtual-memory': saved=await this.onVirtualMemoryModeChange(enabled); break;
      case 'game-keep-screen-on':
        if (this.gameKeepScreenOnSaving) return settingFailure('busy');
        saved=await this.onGameKeepScreenOnChange(enabled); break;
      case 'process':
        if (this.tabletProcessSaving) return settingFailure('busy');
        saved=await this.onTabletProcessChange(enabled); break;
      case 'remote-cache': saved=await this.onCacheRemoteMetaChange(enabled); break;
      case 'acceleration': saved=await this.onAccelDownloadChange(enabled); break;
      case 'jdk-web':
        if (!DistributionPolicy.allowPublisherServices()) return settingFailure('notAvailable');
        saved=await this.onJdkWebChange(enabled); break;
      case 'jdk-auto': saved=await this.onJdkAutoCheckChange(enabled); break;
      default: return settingFailure('invalidSwitch');
    }
    return saved && this.readCommittedSettings(key)[key] === enabled ? this.readSkillSetting_(id) : settingFailure('settingNotSaved');
  }

  private async skillLight_(args: SettingsSkillData): Promise<SettingsSkillData> {
    if (!settingKeys(args,['part','value']) || !this.hasItem_('immersive') || this.immersiveLightSaving) return settingFailure('notAvailable');
    const part = settingText(args,'part'), value = settingText(args,'value');
    const next = copyImmersiveLightPreferences(this.immersiveLight);
    if (part === 'material') {
      const mode = normalizeDockLightMode(value);
      if (value !== mode || mode === DockLightMode.OFF || !next.enabled ||
        (!this.immersiveLightHasPresets && mode !== DockLightMode.AUTO)) return settingFailure('invalidMaterial');
      next.navigationMode = mode;
    } else {
      if (value !== 'on' && value !== 'off') return settingFailure('invalidValue');
      if (part === 'enabled') next.enabled = value === 'on';
      else if (part === 'bottomBar' && next.enabled) next.bottomBar = value === 'on';
      else if (part === 'titleButtons' && next.enabled) next.titleButtons = value === 'on';
      else return settingFailure('invalidPart');
    }
    if (!await this.onImmersiveLightChange(next)) return settingFailure('settingNotSaved');
    return {'state':'ready','item':'immersive','enabled':next.enabled,'navigation':next.navigationMode,'bottomBar':next.bottomBar,'titleButtons':next.titleButtons};
  }

  /** 留在应用的编辑、授权与分享按实际设置目录进入原页面，不接受自由 URL。 */
  private async openSkillSetting_(id: string): Promise<SettingsSkillData> {
    if (!this.hasItem_(id)) return settingFailure('settingUnavailable');
    if (id === 'software-update' && DistributionPolicy.isStore()) return settingFailure('marketUpdateOnly');
    if (!await this.openSearchItem_(id)) return settingFailure('destinationUnavailable');
    if (id === 'jvm' || id === 'storage') {
      this.openSheet_(id);
      if (!this.showSettingsSheet || this.sheetKind !== id) return settingFailure('editorUnavailable');
      return this.beginSkillEditor_(id,'openLauncherSetting');
    }
    else if (id === 'graphics') this.selectSection_('graphics');
    else if (id === 'input') await this.getUIContext().getRouter().pushUrl({url:'pages/LayoutEditorPage', params:{settingsOnly:true}});
    else if (id === 'layouts') await this.getUIContext().getRouter().pushUrl({url:'pages/LayoutListPage'});
    else if (id === 'network') {
      // 面板亲自确认挂载；首次探测可以仍在进行中，结果另由 inspectNetwork 查询。
      const opened = await LauncherSkillBus.forward(this,'settingsNetwork','observeNetworkPanel',{});
      if (opened['surface'] !== 'network') return settingFailure('diagnosticsUnavailable');
    }
    else if (id === 'launcher-log') this.onOpenLog();
    else if (id === 'game-log' && !await this.onOpenGameLog()) return settingFailure('destinationUnavailable');
    else if (id === 'feedback' || id === 'sponsor') await this.getUIContext().getRouter().pushUrl({url:id === 'feedback'?'pages/FeedbackPage':'pages/SponsorPage'});
    else if ((id === 'jit-help' || id === 'install-help') && !await this.openHelp_(id === 'install-help')) return settingFailure('destinationUnavailable');
    return { 'state':'needsUser','item':id };
  }

  private choiceItem_(kind: string): string {
    if (kind === 'frame') return 'frame-rate';
    if (kind === 'jdk-channel') return 'jdk-update';
    return kind;
  }
  private currentChoice_(kind: string): string {
    if (kind === 'java') return this.selectedJdkVersion;
    if (kind === 'frame') return String(this.ohosFrameRateCap);
    if (kind === 'fixed-refresh-rate') return String(this.ohosFixedRefreshRate);
    if (kind === 'language') return this.gameLanguage;
    if (kind === 'mc-source') return this.mcSource;
    if (kind === 'jdk-source') return this.jdkSource;
    if (kind === 'mod-source') return this.modSource;
    if (kind === 'jdk-channel') return this.jdkChannel;
    if (kind === 'storage') return this.storageLocation;
    return '';
  }

  /** Java 动态目录与产品能力在每次渲染/确认时重新消费，不硬编码设计稿中的示例版本。 */
  private choiceOptions_(kind: string = this.sheetKind): SettingsChoice[] {
    if (kind === 'java') {
      const options: SettingsChoice[] = [{ value: JDK_AUTO, title: '自动选择', description: '按 Minecraft 版本匹配，推荐日常使用', enabled: true }];
      for (const jdk of this.jdkVersions) options.push({ value: jdk.version, title: 'JDK ' + jdk.version,
        description: jdk.version === '8' ? '实验性 · 旧版游戏与调试' : '固定使用 JDK ' + jdk.version + (jdk.updateAvailable ? ' · 有可用更新' : ''), enabled: true });
      return options;
    }
    if (kind === 'frame') return [0, 30, 60, 90, 120, 144, 165, 240].map((value: number): SettingsChoice =>
      ({ value: String(value), title: value === 0 ? '自动' : value + ' Hz', description: value === 0 ? '跟随当前显示刷新率' : '系统渲染调度提示上限', enabled: true }));
    if (kind === 'fixed-refresh-rate') {
      // 设置页选择想要的档位，游戏启动后再核对实际游戏窗口的显示设备。
      return [0, 30, 60, 90, 120, 144].map((rate: number): SettingsChoice => {
        const withinCap: boolean = this.ohosFrameRateCap === 0 || rate <= this.ohosFrameRateCap;
        return { value: String(rate), title: rate === 0 ? '不固定' : rate + ' Hz', enabled: withinCap,
          description: rate === 0 ? '沿用系统调度帧率上限' : (withinCap ? '游戏屏幕支持时生效' : '高于系统调度帧率上限') };
      });
    }
    if (kind === 'language') return GAME_LANGUAGES.map((language: GameLanguageOption): SettingsChoice =>
      ({ value: language.code, title: language.label, description: language.code, enabled: true }));
    if (kind === 'mc-source') return [
      { value: 'auto', title: '自动', description: '保留各源，按实际下载表现选择', enabled: true },
      { value: 'mirror', title: '镜像优先', description: '优先 BMCLAPI，官方继续作为备用', enabled: true },
      { value: 'official', title: '源站', description: '仅 Mojang 官方来源，可经过 AMCL 网关', enabled: true }];
    if (kind === 'jdk-source') {
      const sources: SettingsChoice[] = [
        { value: 'auto', title: '自动', description: '源站与镜像实际竞速，按当前线路选择', enabled: true },
        { value: 'github', title: '源站', description: '仅 GitHub 官方来源，可经过 AMCL 网关', enabled: true },
        { value: 'gitee', title: 'Gitee', description: '使用 Gitee 分卷', enabled: true },
        { value: 'mirror', title: '镜像', description: '使用 GitHub 加速代理', enabled: true }];
      if (this.jdkWebEnabled && DistributionPolicy.allowPublisherServices()) sources.push({ value: 'web', title: 'AMCL 服务器', description: '使用已启用的 AMCL 来源', enabled: true });
      return sources;
    }
    if (kind === 'mod-source') return [
      { value: 'auto', title: '自动', description: '保留各源，由下载引擎选择', enabled: true },
      { value: 'mcim', title: '镜像', description: '优先使用模组镜像数据源', enabled: true },
      { value: 'official', title: '源站', description: '仅源站文件，可经过 AMCL 网关；CF 元数据仍使用 MCIM', enabled: true }];
    if (kind === 'jdk-channel') return [
      { value: 'stable', title: '稳定', description: '日常使用推荐的更新通道', enabled: true },
      { value: 'preview', title: '预览', description: '较新的修复，仍需更多设备与模组验证', enabled: true }];
    if (kind === 'storage') return [
      { value: 'sandbox', title: '应用私有', description: '卸载应用时删除', enabled: true },
      { value: 'external', title: '外部存储', description: this.externalAvailable ? 'Download/AMCL · 卸载后保留' : '当前设备不支持外部存储', enabled: this.externalAvailable }];
    return [];
  }

  private sheetTitle_(): string {
    if (this.sheetKind === 'frame') return '系统调度帧率上限';
    if (this.sheetKind === 'jdk-channel') return 'JDK 更新通道';
    return this.availableItems_().find((item: SettingsItem): boolean => item.id === this.sheetKind)?.title ?? '设置';
  }

  /** 每次打开都从最新确认值建草稿；关闭动画期间拒绝新 owner，避免旧 onDisappear 清理新面板。 */
  private openSheet_(kind: string): void {
    if (!this.mounted_ || !this.visible || this.showSettingsSheet || this.sheetClosing_ || !this.hasItem_(this.choiceItem_(kind))) return;
    this.sheetGeneration_++;
    this.sheetKind = kind;
    this.choiceDraft = this.currentChoice_(kind);
    this.jvmArgsDraft = this.customJvmArgs;
    this.jvmSaving = false;
    this.sheetError = '';
    this.pendingStorage_ = '';
    this.showSettingsSheet = true;
    this.syncSectionBack_();
  }

  /** 关闭不写配置；已开始的 JVM 耐久保存仅失去显示权，不被伪装为取消写入。 */
  private cancelSheet_(): void {
    if (this.skillEditorKind_ === this.sheetKind && this.skillEditorState_ === 'waiting') this.skillEditorState_='cancelled';
    this.sheetGeneration_++;
    this.withdrawStorageIntent_();
    this.jvmSaving = false;
    if (this.showSettingsSheet) this.sheetClosing_ = true;
    this.showSettingsSheet = false;
    this.syncSectionBack_();
  }

  /** 只撤销仍属于面板的意图。父层已接手后，以其事务回调作为最终结果。 */
  private withdrawStorageIntent_(): void {
    if (this.skillEditorKind_ === 'storage' && (this.skillEditorState_ === 'waiting' ||
      (this.skillEditorState_ === 'submitted' && this.pendingStorage_.length > 0))) this.skillEditorState_ = 'cancelled';
    this.pendingStorage_ = '';
  }

  /** 普通单选只在显式确定时提交一次；候选失效保留面板并说明，不静默改成另一项。 */
  private confirmChoice_(): void {
    if (!this.showSettingsSheet || this.sheetClosing_ || !this.hasItem_(this.choiceItem_(this.sheetKind))) return;
    const choice: SettingsChoice | undefined = this.choiceOptions_().find((item: SettingsChoice): boolean => item.value === this.choiceDraft && item.enabled);
    if (choice === undefined) { this.sheetError = '该选项已不可用，请重新选择。'; return; }
    const kind: string = this.sheetKind;
    const value: string = choice.value;
    this.sheetClosing_ = true;
    this.showSettingsSheet = false;
    this.submitChoice_(kind, value);
    this.syncSectionBack_();
  }

  /** 已核对的候选由同一个父级回调应用到页面、偏好与下载引擎。 */
  private async submitChoice_(kind: string, value: string): Promise<boolean> {
    if (kind === 'java') return this.onJdkVersionChange(value);
    else if (kind === 'frame') return this.onOhosFrameRateCapChange(Number(value));
    else if (kind === 'fixed-refresh-rate') return this.onOhosFixedRefreshRateChange(Number(value));
    else if (kind === 'language') return this.onGameLanguageChange(value);
    else if (kind === 'mc-source') return this.onMcSourceChange(value);
    else if (kind === 'jdk-source') return this.onJdkSourceChange(value);
    else if (kind === 'mod-source') return this.onModSourceChange(value);
    else if (kind === 'jdk-channel') return this.onJdkChannelChange(value);
    return false;
  }

  /** 存储意图在面板消失后才交给父层，保留原权限/复制事务并避免叠加询问。 */
  private confirmStorage_(migrate: boolean): void {
    if (!this.showSettingsSheet || this.sheetClosing_ || this.sheetKind !== 'storage') return;
    const choice: SettingsChoice | undefined = this.choiceOptions_().find((item: SettingsChoice): boolean => item.value === this.choiceDraft && item.enabled);
    if (choice === undefined) { this.sheetError = '该位置已不可用，请重新选择。'; return; }
    this.pendingStorage_ = choice.value;
    if (this.skillEditorKind_ === 'storage' && this.skillEditorState_ === 'waiting') {
      // 玩家可在面板改选；保留原请求，另记实际交给迁移事务的位置。
      this.skillStorageSelected_=choice.value; this.skillEditorState_='submitted';
    }
    this.pendingMigration_ = migrate;
    this.sheetClosing_ = true;
    this.showSettingsSheet = false;
  }

  /** onDisappear 负责退役该次面板；宿主已隐藏时不再启动新的权限或迁移 UI。 */
  private sheetDisappeared_(): void {
    const location: string = this.pendingStorage_;
    const migrate: boolean = this.pendingMigration_;
    this.pendingStorage_ = '';
    this.sheetClosing_ = false;
    this.sheetKind = '';
    this.sheetError = '';
    this.syncSectionBack_();
    if (location.length === 0) return;
    const receipt=this.skillEditorKind_ === 'storage' && this.skillEditorState_ === 'submitted' ? this.skillEditorRef_ : '';
    if (this.mounted_ && this.visible) {
      if (!receipt) this.onStorageLocationChange(location, migrate);
      else this.onStorageLocationChange(location, migrate, (state: string): void => {
        if (this.skillEditorRef_ !== receipt) return;
        const changed = this.skillStorageRequested_.length > 0 && location !== this.skillStorageRequested_;
        this.skillEditorState_ = state === 'saved' && changed ? 'changedTarget' : state;
      });
    } else if (receipt) this.skillEditorState_ = 'cancelled';
  }

  /** 显式保存等待父层真实 put/flush；失败保留草稿，隐藏或换 owner 后只撤销显示发布。 */
  private async saveCustomJvmArgs(): Promise<void> {
    if (!this.mounted_ || !this.visible || !this.showSettingsSheet || this.sheetKind !== 'jvm' || this.jvmSaving) return;
    const generation: number = this.sheetGeneration_;
    const receipt=this.skillEditorKind_ === 'jvm' && this.skillEditorState_ === 'waiting' ? this.skillEditorRef_ : '';
    if (receipt) this.skillEditorState_='saving';
    this.jvmSaving = true;
    this.sheetError = '';
    try {
      await this.onCustomJvmArgsChange(this.jvmArgsDraft.trim());
      if (receipt && this.skillEditorRef_ === receipt) this.skillEditorState_='saved';
      if (this.mounted_ && this.visible && generation === this.sheetGeneration_) this.cancelSheet_();
    } catch (error) {
      if (receipt && this.skillEditorRef_ === receipt) this.skillEditorState_='waiting';
      if (this.mounted_ && this.visible && generation === this.sheetGeneration_) this.sheetError = '保存失败：' + (error as Error).message;
    } finally {
      if (this.mounted_ && generation === this.sheetGeneration_) this.jvmSaving = false;
    }
  }

  /** 手机面板读取已确认的用户高度；其他设备保留原有宽屏居中和高度策略。 */
  private sheetOptions_(): SheetOptions {
    const center: boolean = this.deviceForm !== DeviceForm.PHONE && this.viewportWidth >= SETTINGS_WIDE_WIDTH;
    const options: SheetOptions = { height: this.deviceForm === DeviceForm.PHONE
      ? detailSheetHeightForLayout(this.deviceForm, Breakpoint.SM, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent)
      : '80%', preferType: center ? SheetType.CENTER : SheetType.BOTTOM,
      dragBar: true, showClose: false, backgroundColor: this.theme.bgPrimary,
      onWillDismiss: (action: DismissSheetAction): void => { this.cancelSheet_(); action.dismiss(); },
      onDisappear: (): void => { this.sheetDisappeared_(); } };
    if (center) options.width = 480;
    return options;
  }

  /** 既有独立页面继续由原 router 所有；失败始终给出可见反馈。 */
  private async openPage_(url: string): Promise<boolean> {
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_) { /* 导航仍由原router处理。 */ }
    try { await this.getUIContext().getRouter().pushUrl({url}); return true; }
    catch (_) { this.navigationError_(); return false; }
  }
  private openLedger_(): Promise<boolean> { return this.openPage_('pages/DownloadHistoryPage'); }
  private navigationError_(): void {
    try { this.getUIContext().getPromptAction().showToast({ message: '无法打开页面，请重试' }); } catch (_) { /* 页面可能已退出。 */ }
  }

  /** 触控帮助只登记学习请求，真实控件教学仍在游戏世界开始。 */
  private requestTouchGuide_(): void {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) return;
      const success: boolean = new TouchLearningStore(context.filesDir).request();
      this.getUIContext().getPromptAction().showToast({ message: success ? '已开启引导，进入游戏世界后开始' : '未能保存引导设置，请重试' });
    } catch (_) { /* 页面退出或提示服务不可用时不再次创建提示，也不伪造引导已保存。 */ }
  }

  /** 已有内嵌文档继续使用原 fallback，不把设置导航改成新的联网服务。 */
  private async openHelp_(install: boolean): Promise<boolean> {
    try { await this.getUIContext().getRouter().pushUrl({ url: 'pages/DocWebPage', params: {
      src: install ? DOCS_INSTALL_URL : DOCS_NO_JIT_URL, title: install ? '怎么安装' : 'JIT 的解决办法',
      fallback: install ? DOCS_INSTALL_FALLBACK_URL : DOCS_NO_JIT_FALLBACK_URL,
    } }); return true; }
    catch (_) { this.navigationError_(); return false; }
  }

  private sourceLabel_(value: string): string {
    if (value === 'auto') return '自动';
    if (value === 'official') return '源站';
    if (value === 'mirror' || value === 'mcim') return '镜像';
    if (value === 'github') return '源站';
    if (value === 'gitee') return 'Gitee';
    if (value === 'web') return 'AMCL 服务器';
    return value;
  }

  private beginSkillEditor_(kind: string, method: string, requestedTarget: string = ''): SettingsSkillData {
    this.skillStorageRequested_=requestedTarget;
    this.skillStorageSelected_='';
    this.skillEditorRef_=nextSettingsReceipt();
    this.skillEditorKind_=kind;
    this.skillEditorState_='waiting';
    const ref=this.skillEditorRef_;
    LauncherSkillBus.followUserCondition(method, (): boolean => this.skillEditorRef_ === ref &&
      ['waiting','submitted','saving'].includes(this.skillEditorState_));
    return {'state':'needsUser','item':kind,'reference':this.skillEditorRef_};
  }
  private immersiveLightSummary_(): string {
    if (!this.immersiveLight.enabled) return '已关闭';
    if (!this.immersiveLight.bottomBar && !this.immersiveLight.titleButtons) return '未启用模块';
    return dockLightModeLabel(this.immersiveLight.navigationMode);
  }
  private accelHint_(): string {
    if (!this.accelDownload) return '关闭时按保存的来源偏好下载';
    if (this.accelStatus === 'ok') return '已就绪 · 官方源经加速网关';
    if (this.accelStatus.length === 0) return '正在连接加速服务…';
    // 开关意图仍为开启时，路由故障只允许源站直连，不能把保存的镜像偏好重新放进来。
    return '加速不可用，仍按源站下载：' + this.accelStatus;
  }

  /** 固定搜索不进入正文 Scroll；宽屏挪到分类侧栏，两个位置共享同一个查询状态。 */
  @Builder
  private SettingsHeaderAccessory_() {
    Row({ space: 12 }) {
      AppIcon({ name: AppIconName.Search, iconSize: 20, color: this.theme.textSecondary });
      TextInput({ placeholder: '搜索设置或功能', text: this.settingsQuery })
        .fontSize(16).fontColor(this.theme.textPrimary).placeholderColor(this.theme.textSecondary)
        .height(48).layoutWeight(1).padding(0).backgroundColor(Color.Transparent)
        .onChange((value: string): void => { this.changeSearch_(value); });
    }.width('100%').height(48).padding({ left: 16, right: 12 })
      .backgroundColor(this.theme.bgCard).borderRadius(24).id('settings-fixed-search');
  }

  /** 分类侧栏只改变布局，不建立独立的配置状态或绕过原运行准入。 */
  @Builder
  private Sidebar_() {
    Column({ space: 20 }) {
      Text('AMCL').fontSize(14).fontWeight(600).fontColor(this.theme.actionText).width('100%').padding({ left: 12 });
      Text('设置').fontSize(28).fontWeight(600).fontColor(this.theme.textPrimary).width('100%').padding({ left: 12 });
      this.SettingsHeaderAccessory_();
      Scroll() {
        Column({ space: 8 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 12 }) {
              AppIcon({ name: AppIconName.Settings, iconSize: 22, color: this.activeSection === 'overview' ? this.theme.actionText : this.theme.textSecondary });
              Text('常用设置').fontSize(16).fontColor(this.activeSection === 'overview' ? this.theme.actionText : this.theme.textPrimary).layoutWeight(1);
            }.width('100%').padding(16);
          }.width('100%').constraintSize({ minHeight: 56 }).padding(0).borderRadius(16)
            .backgroundColor(this.activeSection === 'overview' ? this.theme.primaryLight : Color.Transparent)
            .onClick((): void => { this.selectSection_('overview'); });
          ForEach(this.availableSections_(), (section: SettingsSection) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                AppIcon({ name: this.sectionIcon_(section.id), iconSize: 22,
                  color: this.activeSection === section.id ? this.theme.actionText : this.theme.textSecondary });
                Text(section.title).fontSize(16).fontColor(this.activeSection === section.id ? this.theme.actionText : this.theme.textPrimary).layoutWeight(1);
              }.width('100%').padding(16);
            }.width('100%').constraintSize({ minHeight: 56 }).padding(0).borderRadius(16)
              .backgroundColor(this.activeSection === section.id ? this.theme.primaryLight : Color.Transparent)
              .onClick((): void => { this.selectSection_(section.id); });
          }, (section: SettingsSection): string => section.id);
          SettingsValueRow({ title: '软件更新', showIcon: true, icon: AppIconName.Refresh, theme: this.theme,
            controlId: 'settings-sidebar-software-update', onAction: (): void => { this.openPage_('pages/SoftwareUpdatePage'); } });
          SettingsValueRow({ title: '关于 AMCL', showIcon: true, icon: AppIconName.Info, theme: this.theme,
            value: this.hasUpdate && !DistributionPolicy.isStore() ? '有更新' : '', actionValue: true,
            onAction: (): void => { this.openPage_('pages/AboutPage'); } });
        }.width('100%');
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).id('settings-sidebar-scroll');
      Button('活动账本').width('100%').height(48).fontSize(16).fontColor(this.theme.actionText)
        .backgroundColor(this.theme.bgCard).onClick((): void => { this.openLedger_(); });
    }.width(280).height('100%').padding({ left: 16, right: 16, top: this.topSafeHeight + 28,
      bottom: floatingDockReserveHeight(this.bottomSafeHeight) });
  }

  build() {
    Row({ space: 24 }) {
      if (this.viewportWidth >= SETTINGS_WIDE_WIDTH) this.Sidebar_();
      ImmersiveTitleScaffold({ title: this.sectionTitle_(), emphasizedTitle: true, theme: this.theme,
        titleId: 'settings-section-title', topSafeHeight: this.topSafeHeight, surfaceColor: this.theme.bgPrimary,
        showBack: (this.activeSection !== 'overview' || this.settingsQuery.trim().length > 0) && this.viewportWidth < SETTINGS_WIDE_WIDTH,
        backLabel: '返回设置', backId: 'settings-section-back',
        onBack: (): void => { this.sectionBackHandler_(); },
        accessoryHeight: this.viewportWidth >= SETTINGS_WIDE_WIDTH ? 0 : 60,
        headerAccessory: (): void => { this.SettingsHeaderAccessory_(); },
        content: (): void => { this.ImmersiveTitleContent1_(); },
      }).layoutWeight(1).height('100%');
    }.width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
      .onAreaChange((_old: Area, current: Area): void => { this.viewportWidth = Number(current.width); })
      .bindSheet($$this.showSettingsSheet, this.SettingsSheet_(), this.sheetOptions_());
  }

  /** 正文视口保持满高，只有滚动尾部预留主导航空间；不以 bottom margin 截短整页。 */
  @Builder
  private ImmersiveTitleContent1_() {
    Scroll(this.contentScroller) {
      Column({ space: 24 }) {
        if (this.settingsQuery.trim().length > 0) this.SearchResults_();
        else if (this.activeSection === 'overview') this.Overview_();
        else if (this.activeSection === 'performance') this.Performance_();
        else if (this.activeSection === 'controls') this.Controls_();
        else if (this.activeSection === 'appearance') this.Appearance_();
        else if (this.activeSection === 'download') this.Downloads_();
        else if (this.activeSection === 'files') this.Isolation_();
        else if (this.activeSection === 'graphics' && this.canRunGame) {
          MobileglRendererSettings({ theme: this.theme, mcDir: this.mcDir, mcVersion: this.mcVersion,
            onConfirmed: (): void => { this.selectSection_('controls'); } });
        } else if (this.activeSection === 'resolution' && this.canRunGame) {
          // 设置页只提供全局政策；每版本覆盖由该版本详情固定绑定身份后编辑。
          GameResolutionSettings({ theme: this.theme, visible: this.visible });
        } else this.Support_();
        Text('AMCL ' + APP_VERSION).fontSize(14).fontColor(this.theme.textSecondary)
          .width('100%').textAlign(TextAlign.Center).padding({ top: 8 });
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: floatingDockReserveHeight(this.bottomSafeHeight) + 24 });
    }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).id('settings-content-scroll')
      .onAreaChange((): void => { this.locatePending_(); });
  }

  /** 结果只导航，不在搜索列表中直接写配置；路径让用户知道该项的正式归属。 */
  @Builder
  private SearchResults_() {
    Column({ space: 16 }) {
      if (this.searchResults_().length > 0) {
        Text('找到 ' + this.searchResults_().length + ' 项设置').fontSize(14).fontColor(this.theme.textSecondary).width('100%');
        Column() {
          ForEach(this.searchResults_(), (item: SettingsItem) => {
            SettingsValueRow({ title: item.title, description: this.availableSections_().find((section: SettingsSection): boolean => section.id === item.section)?.title ?? item.description,
              showIcon: true, icon: this.sectionIcon_(item.section), theme: this.theme,
              controlId: 'settings-search-' + item.id, onAction: (): void => { this.openSearchItem_(item.id); } });
            SettingsDivider({ theme: this.theme });
          }, (item: SettingsItem): string => item.id);
        }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true);
      } else {
        Column({ space: 16 }) {
          AppIcon({ name: AppIconName.Search, iconSize: 32, color: this.theme.textSecondary });
          Text('没有找到相关设置').fontSize(20).fontColor(this.theme.textPrimary);
          SettingsHint({ text: this.canRunGame ? '试试“内存”“Java”或“日志”。' : '试试“主题”“存储”或“日志”。', theme: this.theme });
          Button('清空搜索').height(48).fontSize(16).fontColor(this.theme.actionText).backgroundColor(this.theme.primaryLight)
            .onClick((): void => { this.changeSearch_(''); });
        }.width('100%').padding(24).alignItems(HorizontalAlign.Center);
      }
    }.width('100%');
  }

  /** 首页仅保留紧凑的当前值摘要，完整配置均进入有明确归属的设置组。 */
  @Builder
  private Overview_() {
    Column({ space: 24 }) {
      if (this.canRunGame) {
        Row({ space: 16 }) {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 8 }) {
              Text('游戏内存').fontSize(14).fontColor(this.theme.textSecondary);
              Text(this.memoryLabel_()).fontSize(28).fontWeight(600).fontColor(this.theme.textPrimary);
              Text('点击调整').fontSize(14).fontColor(this.theme.actionText);
            }.width('100%').padding(20).alignItems(HorizontalAlign.Start);
          }.layoutWeight(1).constraintSize({ minHeight: 124 }).padding(0).borderRadius(0).backgroundColor(Color.Transparent)
            .onClick((): void => { this.openSearchItem_('memory'); });
          Button({ type: ButtonType.Normal }) {
            Column({ space: 8 }) {
              Text('Java 运行环境').fontSize(14).fontColor(this.theme.textSecondary);
              Text(this.selectedJdkVersion === JDK_AUTO ? '自动' : 'JDK ' + this.selectedJdkVersion)
                .fontSize(28).fontWeight(600).fontColor(this.theme.textPrimary);
              Text(this.selectedJdkVersion === JDK_AUTO ? '按游戏版本匹配' : '固定版本').fontSize(14).fontColor(this.theme.actionText);
            }.width('100%').padding(20).alignItems(HorizontalAlign.Start);
          }.layoutWeight(1).constraintSize({ minHeight: 124 }).padding(0).borderRadius(0).backgroundColor(Color.Transparent)
            .onClick((): void => { this.openSheet_('java'); });
        }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true);
        SettingsGroup({ title: '游戏', theme: this.theme, content: (): void => { this.OverviewGame_(); } });
      }
      SettingsGroup({ title: '通用', theme: this.theme, content: (): void => { this.OverviewCommon_(); } });
      if (!this.canRunGame) this.Isolation_();
      SettingsGroup({ title: '记录与支持', theme: this.theme, content: (): void => { this.OverviewSupport_(); } });
    }.width('100%');
  }
  @Builder
  private OverviewGame_() {
    SettingsValueRow({ title: '游戏与性能', description: '内存、Java 与启动方式', showIcon: true, icon: AppIconName.Memory,
      theme: this.theme, onAction: (): void => { this.selectSection_('performance'); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '显示与操控', description: '图形、语言、触控与手柄', showIcon: true, icon: AppIconName.GameController,
      theme: this.theme, onAction: (): void => { this.selectSection_('controls'); } });
  }
  @Builder
  private OverviewCommon_() {
    SettingsValueRow({ title: '外观与光感', description: themeAccentLabel(this.themeSelection.accent) + ' · ' + (this.themeMode === ThemeMode.SYSTEM ? '跟随系统' : this.themeMode === ThemeMode.LIGHT ? '浅色' : '深色') + ' · 光感' + this.immersiveLightSummary_(),
      showIcon: true, icon: AppIconName.Appearance, theme: this.theme, controlId: 'settings-quick-immersive',
      onAction: (): void => { this.selectSection_('appearance'); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '下载与存储', description: '下载源与游戏数据位置', showIcon: true, icon: AppIconName.Download,
      theme: this.theme, onAction: (): void => { this.selectSection_('download'); } });
  }
  @Builder
  private OverviewSupport_() {
    SettingsValueRow({ title: '软件更新', description: DistributionPolicy.isStore() ? '应用版本与应用市场更新' : '更新通道与华为开发者账号',
      showIcon: true, icon: AppIconName.Refresh, value: this.hasUpdate && !DistributionPolicy.isStore() ? '有新版本' : '',
      actionValue: true, theme: this.theme, controlId: 'settings-software-update',
      onAction: (): void => { this.openPage_('pages/SoftwareUpdatePage'); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '活动账本', description: '查看游戏、下载与文件管理记录', showIcon: true, icon: AppIconName.History,
      theme: this.theme, onAction: (): void => { this.openLedger_(); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '日志与支持', description: '日志保留、网络检测与帮助', showIcon: true, icon: AppIconName.Help,
      theme: this.theme, onAction: (): void => { this.selectSection_('logs'); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '关于 AMCL', description: '版本信息与联系方式', showIcon: true, icon: AppIconName.Info,
      value: this.hasUpdate && !DistributionPolicy.isStore() ? '有新版本' : '', actionValue: true,
      theme: this.theme, onAction: (): void => { this.openPage_('pages/AboutPage'); } });
  }

  /** 1120 vp 起才在正文内并排内存/运行环境，840–1119 的双栏窗口仍保持内容单列。 */
  @Builder
  private Performance_() {
    Column({ space: 24 }) {
      SettingsGroup({ theme: this.theme, content: (): void => { this.GameKeepScreenOn_(); } });
      SettingsHint({ text: '作为全局默认值；单个版本可在版本详情中覆盖。', theme: this.theme });
      if (this.viewportWidth >= 1120) {
        Row({ space: 24 }) {
          Column({ space: 24 }) { this.Memory_(); this.Isolation_(); }.layoutWeight(1.1);
          Column({ space: 24 }) { this.Runtime_(); this.Process_(); }.layoutWeight(1);
        }.width('100%').alignItems(VerticalAlign.Top);
      } else { this.Memory_(); this.Runtime_(); this.Process_(); this.Isolation_(); }
    }.width('100%');
  }
  @Builder
  private GameKeepScreenOn_() {
    SettingsToggleRow({ title: '游戏中保持屏幕常亮', description: '游戏在前台时防止自动息屏。修改后在下次启动游戏时生效。',
      value: this.gameKeepScreenOn, saving: this.gameKeepScreenOnSaving, theme: this.theme,
      controlId: 'settings-item-game-keep-screen-on', highlighted: this.highlightedItem === 'game-keep-screen-on',
      onLayout: (): void => { this.locateItem_('game-keep-screen-on'); },
      onChange: (value: boolean): void => { this.onGameKeepScreenOnChange(value); } });
  }
  @Builder
  private Memory_() {
    SettingsGroup({ title: '内存', theme: this.theme, content: (): void => { this.MemoryContent_(); } });
  }
  @Builder
  private MemoryContent_() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text('JVM 最大内存').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1);
        Text(this.memoryLabel_()).fontSize(28).fontWeight(600)
          .fontColor(this.mcXmx > this.xmxRiskThreshold() ? this.theme.errorText : this.theme.actionText);
      }.width('100%');
      Slider({ value: this.mcXmx, min: 512, max: this.xmxMax, step: 256 }).width('100%')
        .trackColor(this.theme.bgInput).selectedColor(this.mcXmx > this.xmxRiskThreshold() ? this.theme.errorText : this.theme.actionText)
        .onChange((value: number, mode: SliderChangeMode): void => { this.onXmxSliderChange(value, mode); });
      Row() {
        Text('512 MB').fontSize(14).fontColor(this.theme.textSecondary); Blank();
        Text((this.xmxMax / 1024).toFixed(1) + ' GB').fontSize(14).fontColor(this.theme.textSecondary);
      }.width('100%');
      Row({ space: 8 }) {
        ForEach(this.quickMemoryValues_(), (value: number) => {
          Button(value / 1024 + ' GB').layoutWeight(1).height(48).fontSize(14)
            .fontColor(this.mcXmx === value ? this.theme.actionText : this.theme.textSecondary)
            .backgroundColor(this.mcXmx === value ? this.theme.primaryLight : this.theme.bgInput)
            .onClick((): void => { this.onXmxSliderChange(value, SliderChangeMode.Click); });
        }, (value: number): string => String(value));
      }.width('100%');
      Row({ space: 12 }) {
        TextInput({ text: this.xmxDraft, placeholder: '内存 MB' }).type(InputType.Number).height(48).layoutWeight(1)
          .fontSize(16).fontColor(this.theme.textPrimary).backgroundColor(this.theme.bgInput)
          .onChange((value: string): void => { this.xmxDraft = value; this.memoryError = ''; });
        Button('应用').height(48).fontSize(16).fontColor(this.theme.actionText).backgroundColor(this.theme.primaryLight)
          .onClick((): void => { this.applyPreciseMemory_(); });
      }.width('100%');
      SettingsHint({ text: '以 256 MB 递增；建议不超过 ' + this.xmxRiskThreshold() + ' MB。', theme: this.theme });
      if (this.memoryError.length > 0) SettingsHint({ text: this.memoryError, theme: this.theme, isError: true });
    }.width('100%').padding(20).backgroundColor(this.highlightedItem === 'memory' ? this.theme.primaryLight : Color.Transparent)
      .id('settings-item-memory').onAreaChange((): void => { this.locateItem_('memory'); });
    SettingsDivider({ theme: this.theme });
    SettingsToggleRow({ title: '虚拟内存（堆文件）', description: '适合低内存设备；加载与世界生成会变慢',
      value: this.virtualMemoryMode, theme: this.theme, controlId: 'settings-item-virtual-memory', highlighted: this.highlightedItem === 'virtual-memory',
      onLayout: (): void => { this.locateItem_('virtual-memory'); },
      onChange: (value: boolean): void => { this.onVirtualMemoryModeChange(value); } });
  }
  @Builder
  private Runtime_() {
    Column({ space: 12 }) {
      SettingsGroup({ title: '运行环境', theme: this.theme, content: (): void => { this.RuntimeContent_(); } });
      SettingsHint({ text: 'Java 与 JVM 参数修改后，在下次启动游戏时生效。', theme: this.theme });
    }.width('100%');
  }
  @Builder
  private RuntimeContent_() {
    SettingsValueRow({ title: 'Java 版本', value: this.selectedJdkVersion === JDK_AUTO ? '自动 · 推荐' : 'JDK ' + this.selectedJdkVersion,
      theme: this.theme, controlId: 'settings-item-java', highlighted: this.highlightedItem === 'java',
      onLayout: (): void => { this.locateItem_('java'); }, onAction: (): void => { this.openSheet_('java'); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '自定义 JVM 参数', value: this.customJvmArgs.trim().length > 0 ? '已设置' : '未设置',
      theme: this.theme, controlId: 'settings-item-jvm', highlighted: this.highlightedItem === 'jvm',
      onLayout: (): void => { this.locateItem_('jvm'); }, onAction: (): void => { this.openSheet_('jvm'); } });
    SettingsDivider({ theme: this.theme });
    ModAudioSettings({ theme: this.theme, onLayout: (): void => { this.locateItem_('mod-audio'); } });
    // MIDI 仅提供显式授权入口；PCM 录音继续复用唯一 ModAudioSettings 政策。
    BluetoothMidiPermissionSettings({ theme: this.theme });
  }
  @Builder
  private Process_() {
    if (this.canRunGame && ProductInputProfile.canChooseTabletProcess()) {
      SettingsGroup({ title: '平板运行方式', theme: this.theme, content: (): void => { this.ProcessContent_(); } });
    }
  }
  @Builder
  private ProcessContent_() {
    Column() {
      SettingsToggleRow({ title: '独立游戏进程', description: this.tabletIndependentGameProcess ? '退出游戏后保留启动器' : '与启动器共用进程，退出时可能一起关闭',
        value: this.tabletIndependentGameProcess, saving: this.tabletProcessSaving, theme: this.theme,
        controlId: 'tabletIndependentGameProcessSwitch', highlighted: this.highlightedItem === 'process',
        onChange: (value: boolean): void => { this.onTabletProcessChange(value); } });
      Column({ space: 8 }) {
        SettingsHint({ text: this.tabletProcessSaving ? '正在保存…' : this.tabletIndependentGameProcess !== this.tabletProcessActive
          ? '已保存，下次重启启动器后生效。当前：' + (this.tabletProcessActive ? '独立进程' : '兼容模式')
          : '当前：' + (this.tabletProcessActive ? '独立进程' : '兼容模式') + ' · 修改后需重启启动器', theme: this.theme, isAccent: true });
        if (this.tabletProcessMessage.length > 0) SettingsHint({ text: this.tabletProcessMessage, theme: this.theme,
          isError: this.tabletProcessMessage.startsWith('保存失败') });
      }.width('100%').padding({ left: 16, right: 16, bottom: 16 });
    }.width('100%').id('settings-item-process').onAreaChange((): void => { this.locateItem_('process'); });
  }
  @Builder
  private Isolation_() {
    SettingsGroup({ title: this.canRunGame ? '版本管理' : '文件归属', theme: this.theme, content: (): void => { this.IsolationContent_(); } });
  }
  @Builder
  private IsolationContent_() {
    SettingsToggleRow({ title: '版本隔离', description: '每个版本独立保存存档、模组与资源包', value: this.versionIsolation,
      saving: this.isolationPending_, theme: this.theme, controlId: 'settings-item-isolation', highlighted: this.highlightedItem === 'isolation',
      onLayout: (): void => { this.locateItem_('isolation'); }, onChange: (value: boolean): void => { this.requestIsolation_(value); } });
  }

  /** 输入、渲染等子域继续使用其原产品组件，UI 不复制冻结设置或图形能力库存。 */
  @Builder
  private Controls_() {
    Column({ space: 24 }) {
      SettingsGroup({ title: '显示', theme: this.theme, content: (): void => { this.DisplayContent_(); } });
      SettingsHint({ text: '调度帧率只影响 HarmonyOS 渲染调度提示，不更改 Minecraft 的最大帧率。', theme: this.theme });
      MobileglRendererSettings({ theme: this.theme, mcDir: this.mcDir, mcVersion: this.mcVersion, compact: true,
        onOpen: (): void => { this.selectSection_('graphics'); } })
        .onAreaChange((): void => { this.locateItem_('graphics'); });
      // 与图形后端同为详情入口；实际比例和保存状态由原组件管理，入口不维护第二份偏好。
      Column() {
        SettingsValueRow({ title: '游戏分辨率', description: '调整全局默认，单版本请在版本详情设置',
          theme: this.theme, controlId: 'settings-item-resolution',
          onAction: (): void => { this.selectSection_('resolution'); } });
      }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20);
      if (ProductInputProfile.supportsTouchLayouts()) {
        SettingsGroup({ title: '触控与输入', theme: this.theme, content: (): void => { this.InputContent_(); } });
        SettingsGroup({ title: '操作帮助', theme: this.theme, content: (): void => { this.TouchHelp_(); } });
      }
      if (!ProductInputProfile.canChooseTabletProcess()) {
        SettingsGroup({ title: '游戏窗口', theme: this.theme, content: (): void => { this.WindowContent_(); } });
      }
      if (DiagnosticPolicy.hasTestHooks()) {
        Column() { ProductDeveloperSettings({ theme: this.theme }); }
          .width('100%').padding({ left: 16, right: 16 }).backgroundColor(this.theme.bgCard).borderRadius(20)
          .id('settings-item-developer').onAreaChange((): void => { this.locateItem_('developer'); });
      }
    }.width('100%');
  }
  @Builder
  private DisplayContent_() {
    SettingsValueRow({ title: '系统调度帧率上限', value: this.ohosFrameRateCap === 0 ? '自动' : this.ohosFrameRateCap + ' Hz',
      theme: this.theme, controlId: 'settings-item-frame-rate', highlighted: this.highlightedItem === 'frame-rate',
      onLayout: (): void => { this.locateItem_('frame-rate'); }, onAction: (): void => { this.openSheet_('frame'); } });
    if (this.hasItem_('fixed-refresh-rate')) {
      SettingsDivider({ theme: this.theme });
      SettingsValueRow({ title: '游戏屏幕刷新率',
        value: this.ohosFixedRefreshRate === 0 ? '不固定' : this.ohosFixedRefreshRate + ' Hz',
        theme: this.theme, controlId: 'settings-item-fixed-refresh-rate',
        highlighted: this.highlightedItem === 'fixed-refresh-rate',
        onLayout: (): void => { this.locateItem_('fixed-refresh-rate'); },
        onAction: (): void => { this.openSheet_('fixed-refresh-rate'); } });
    }
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '游戏语言', value: gameLanguageLabel(this.gameLanguage),
      theme: this.theme, controlId: 'settings-item-language', highlighted: this.highlightedItem === 'language',
      onLayout: (): void => { this.locateItem_('language'); }, onAction: (): void => { this.openSheet_('language'); } });
  }
  @Builder
  private InputContent_() {
    SettingsValueRow({ title: '手感与输入', description: '视角与触觉反馈', showIcon: true, icon: AppIconName.GameController,
      theme: this.theme, controlId: 'settings-item-input', highlighted: this.highlightedItem === 'input',
      onLayout: (): void => { this.locateItem_('input'); }, onAction: (): void => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/LayoutEditorPage', params: { settingsOnly: true } })
          .catch((): void => { this.navigationError_(); });
      } });
    SettingsDivider({ theme: this.theme });
    Column() { ProductTouchSettings({ theme: this.theme }); }.width('100%')
      .onAreaChange((): void => { this.locatePending_(); });
  }
  @Builder
  private TouchHelp_() {
    Column({ space: 16 }) {
      Text('触控操作帮助').fontSize(16).fontColor(this.theme.textPrimary).width('100%');
      SettingsHint({ text: '进入游戏世界后，使用真正的摇杆、物品栏和菜单学习操作。', theme: this.theme });
      Button('进入游戏后开始引导').width('100%').height(48).fontSize(16).fontColor(this.theme.actionText)
        .backgroundColor(this.theme.primaryLight).onClick((): void => { this.requestTouchGuide_(); });
    }.width('100%').padding(20).backgroundColor(this.highlightedItem === 'touch-help' ? this.theme.primaryLight : Color.Transparent)
      .id('settings-item-touch-help').onAreaChange((): void => { this.locateItem_('touch-help'); });
  }
  @Builder
  private WindowContent_() {
    SettingsValueRow({ title: ProductInputProfile.selection().desktopWindow ? '独立游戏窗口' : '游戏窗口',
      description: ProductInputProfile.selection().desktopWindow ? '游戏在独立进程和窗口运行，可调整大小、最小化或全屏' : '游戏在启动器窗口内运行',
      value: ProductInputProfile.selection().desktopWindow ? '独立窗口' : '启动器窗口', theme: this.theme, interactive: false,
      controlId: 'settings-item-window', onLayout: (): void => { this.locateItem_('window'); } });
  }

  @Builder
  private Appearance_() {
    Column({ space: 24 }) {
      SettingsGroup({ title: '外观', theme: this.theme, content: (): void => { this.ThemeContent_(); } });
      SettingsGroup({ title: '手机面板', theme: this.theme, content: (): void => { this.PhoneSheetHeightContent_(); } });
      Column() {
        ImmersiveLightSettings({ theme: this.theme, preferences: this.immersiveLight,
          saving: this.immersiveLightSaving, hasPresets: this.immersiveLightHasPresets,
          status: this.immersiveLightStatus, saveError: this.immersiveLightSaveError,
          onChange: (next: ImmersiveLightPreferences): void => { this.onImmersiveLightChange(next); } });
      }.width('100%').id('settings-item-immersive').onAreaChange((): void => { this.locateItem_('immersive'); });
    }.width('100%');
  }
  /** 与搜索目录使用同一锚点；组件只持滑动草稿，确认值和保存仍来自 Index。 */
  @Builder
  private PhoneSheetHeightContent_() {
    Column() {
      PhoneSheetHeightSettings({ theme: this.theme, value: this.phoneSheetHeightPercent,
        active: this.visible && this.activeSection === 'appearance',
        onSave: async (percent: number): Promise<void> => { await this.onPhoneSheetHeightSave(percent); } });
    }.width('100%').backgroundColor(this.highlightedItem === 'phone-sheet-height' ? this.theme.primaryLight : Color.Transparent)
      .id('settings-item-phone-sheet-height').onAreaChange((): void => { this.locateItem_('phone-sheet-height'); });
  }
  @Builder
  private ThemeContent_() {
    Column({ space: 16 }) {
      ThemeSettings({ theme: this.theme, selection: this.themeSelection, saving: this.themeSaving,
        active: this.visible && this.activeSection === 'appearance',
        onPreview: (selection: ThemeSelection | undefined): void => { this.onThemePreview(selection); },
        onSave: async (selection: ThemeSelection): Promise<void> => { await this.onThemeSave(selection); } });
    }.width('100%').padding(20).backgroundColor(this.highlightedItem === 'theme' ? this.theme.primaryLight : Color.Transparent)
      .id('settings-item-theme').onAreaChange((): void => { this.locateItem_('theme'); });
  }

  @Builder
  private Downloads_() {
    Column({ space: 24 }) {
      SettingsGroup({ title: '下载源', theme: this.theme, content: (): void => { this.SourcesContent_(); } });
      SettingsHint({ text: this.accelDownload
        ? '加速开启时正文仅用源站，网关不可用时仍回源站；关闭后使用保存的来源偏好。CurseForge 列表元数据仍由 MCIM 提供。'
        : '关闭加速时按保存偏好下载；源站模式保留原始地址，自动模式由引擎按实际传输表现选择。CurseForge 列表元数据仍由 MCIM 提供。', theme: this.theme });
      SettingsGroup({ title: '下载偏好', theme: this.theme, content: (): void => { this.DownloadOptions_(); } });
      if (this.canRunGame) {
        SettingsGroup({ title: 'JDK 更新', theme: this.theme, content: (): void => { this.JdkUpdateContent_(); } });
        if (this.jdkChannel === 'preview') SettingsHint({ text: '预览包包含较新的修复，仍需更多设备和模组验证。现有 JDK 可继续使用。', theme: this.theme });
      }
      SettingsGroup({ title: '存储', theme: this.theme, content: (): void => { this.StorageContent_(); } });
      SettingsHint({ text: '切换前可选择复制现有游戏数据；原位置的数据继续保留。', theme: this.theme });
    }.width('100%');
  }
  @Builder
  private SourcesContent_() {
    // 开启加速时展示的是为关闭后保存的偏好；不能改写它来实现临时的源站约束。
    SettingsValueRow({ title: this.accelDownload ? '游戏下载源（关闭加速后）' : '游戏下载源', value: this.sourceLabel_(this.mcSource), theme: this.theme,
      controlId: 'settings-item-mc-source', highlighted: this.highlightedItem === 'mc-source',
      onLayout: (): void => { this.locateItem_('mc-source'); }, onAction: (): void => { this.openSheet_('mc-source'); } });
    if (this.canRunGame) {
      SettingsDivider({ theme: this.theme });
      SettingsValueRow({ title: 'JDK 下载源', value: this.sourceLabel_(this.jdkSource), theme: this.theme,
        controlId: 'settings-item-jdk-source', highlighted: this.highlightedItem === 'jdk-source',
        onLayout: (): void => { this.locateItem_('jdk-source'); }, onAction: (): void => { this.openSheet_('jdk-source'); } });
    }
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: this.accelDownload ? '模组数据源（关闭加速后）' : '模组数据源', value: this.sourceLabel_(this.modSource), theme: this.theme,
      controlId: 'settings-item-mod-source', highlighted: this.highlightedItem === 'mod-source',
      onLayout: (): void => { this.locateItem_('mod-source'); }, onAction: (): void => { this.openSheet_('mod-source'); } });
  }
  @Builder
  private DownloadOptions_() {
    if (DistributionPolicy.allowPublisherServices()) {
      SettingsToggleRow({ title: '加速下载', description: this.accelHint_(), value: this.accelDownload,
        theme: this.theme, controlId: 'settings-item-acceleration', highlighted: this.highlightedItem === 'acceleration',
        onLayout: (): void => { this.locateItem_('acceleration'); }, onChange: (value: boolean): void => { this.onAccelDownloadChange(value); } });
      SettingsDivider({ theme: this.theme });
    }
    SettingsToggleRow({ title: '缓存远程元数据', description: '减少重复请求，更快打开项目详情', value: this.cacheRemoteMeta,
      theme: this.theme, controlId: 'settings-item-remote-cache', highlighted: this.highlightedItem === 'remote-cache',
      onLayout: (): void => { this.locateItem_('remote-cache'); }, onChange: (value: boolean): void => { this.onCacheRemoteMetaChange(value); } });
    SettingsDivider({ theme: this.theme });
    Column() {
      SettingsValueRow({ title: '并发下载数', description: '由下载引擎自动管理', value: '自动', interactive: false, theme: this.theme });
    }.width('100%').id('settings-item-download-concurrency')
      .onAreaChange((): void => { this.locateItem_('download-concurrency'); });
  }
  @Builder
  private JdkUpdateContent_() {
    Column() {
      SettingsValueRow({ title: '检查 JDK 更新', value: this.jdkChecking ? '检查中…' : this.jdkHasUpdate ? '有更新 · 检查' : '检查',
        showTrailing: false, actionValue: true, actionEnabled: !this.jdkChecking, theme: this.theme,
        onAction: (): void => { if (!this.jdkChecking) this.onCheckJdkUpdate(); } });
      if (this.jdkCatalogStatus.length > 0) {
        Column() { SettingsHint({ text: this.jdkCatalogStatus, theme: this.theme }); }
          .width('100%').padding({ left: 16, right: 16, bottom: 12 });
      }
      SettingsDivider({ theme: this.theme });
      SettingsToggleRow({ title: '自动检查 JDK 更新', description: '检查可用更新，按需下载', value: this.jdkAutoCheck,
        theme: this.theme, onChange: (value: boolean): void => { this.onJdkAutoCheckChange(value); } });
      SettingsDivider({ theme: this.theme });
      SettingsValueRow({ title: '更新通道', value: this.jdkChannel === 'preview' ? '预览' : '稳定', theme: this.theme,
        onAction: (): void => { this.openSheet_('jdk-channel'); } });
      if (DistributionPolicy.allowPublisherServices()) {
        SettingsDivider({ theme: this.theme });
      // 此保存值仅决定关闭网关时的独立来源；开启网关可使用同官方构建的第一方缓存，
      // 无需为临时路由改写该偏好，关闭网关后仍可恢复用户选择。
      SettingsToggleRow({ title: '启用 AMCL 服务器', description: '用于关闭加速后的独立来源；加速开启可使用同构建第一方缓存', value: this.jdkWebEnabled,
          theme: this.theme, onChange: (value: boolean): void => { this.onJdkWebChange(value); } });
      }
    }.width('100%').backgroundColor(this.highlightedItem === 'jdk-update' ? this.theme.primaryLight : Color.Transparent)
      .id('settings-item-jdk-update').onAreaChange((): void => { this.locateItem_('jdk-update'); });
  }
  @Builder
  private StorageContent_() {
    SettingsValueRow({ title: '游戏数据位置', description: this.storageLocation === 'external' ? '外部存储 · 卸载后保留' : '应用私有 · 卸载时删除',
      showIcon: true, icon: AppIconName.Folder, theme: this.theme,
      controlId: 'settings-item-storage', highlighted: this.highlightedItem === 'storage',
      onLayout: (): void => { this.locateItem_('storage'); }, onAction: (): void => { this.openSheet_('storage'); } });
    if (this.storageLocation === 'external' && this.externalPathHint.length > 0) {
      Column() { SettingsHint({ text: this.externalPathHint, theme: this.theme }); }
        .width('100%').padding({ left: 16, right: 16, bottom: 16 });
    }
  }

  @Builder
  private Support_() {
    Column({ space: 24 }) {
      SettingsGroup({ title: '日志', theme: this.theme, content: (): void => { this.LogEntries_(); } });
      SettingsGroup({ title: '保留策略', theme: this.theme, content: (): void => { this.Retention_(); } });
      SettingsHint({ text: '减少保留数量前会确认清理范围。运行中的记录与在线分享继续受到保护。', theme: this.theme });
      SettingsGroup({ title: '帮助', theme: this.theme, content: (): void => { this.HelpContent_(); } });
      if (!DistributionPolicy.isStore()) SettingsGroup({ title: '支持', theme: this.theme, content: (): void => { this.SupportContent_(); } });
    }.width('100%');
  }
  @Builder
  private LogEntries_() {
    SettingsValueRow({ title: '活动账本', description: '从一次游戏或下载找到对应记录', showIcon: true, icon: AppIconName.History,
      theme: this.theme, onAction: (): void => { this.openLedger_(); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '启动器运行日志', value: '查看', theme: this.theme, controlId: 'settings-item-launcher-log',
      highlighted: this.highlightedItem === 'launcher-log', onLayout: (): void => { this.locateItem_('launcher-log'); },
      onAction: (): void => { this.onOpenLog(); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '应用诊断摘要', value: '复制脱敏摘要', trailingIcon: AppIconName.Copy, actionValue: true, theme: this.theme,
      controlId: 'settings-item-diagnostics', highlighted: this.highlightedItem === 'diagnostics',
      onLayout: (): void => { this.locateItem_('diagnostics'); }, onAction: (): void => { this.onExportLog(); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '最近游戏的完整日志', value: '查看', theme: this.theme, controlId: 'settings-item-game-log',
      highlighted: this.highlightedItem === 'game-log', onLayout: (): void => { this.locateItem_('game-log'); },
      onAction: (): void => { this.onOpenGameLog(); } });
  }
  @Builder
  private Retention_() {
    Column() { LogRetentionSettings({ theme: this.theme }); }.width('100%').padding(20)
      .id('settings-item-retention').onAreaChange((): void => { this.locateItem_('retention'); });
  }
  @Builder
  private HelpContent_() {
    SettingsValueRow({ title: '网络检测', description: '下载或搜索失败时，检查来源可达性', showIcon: true, icon: AppIconName.Search,
      theme: this.theme, controlId: 'settings-item-network', highlighted: this.highlightedItem === 'network',
      onLayout: (): void => { this.locateItem_('network'); },
      onAction: (): void => { AppStorage.setOrCreate('amcl_open_netdiag_nonce', Date.now()); } });
    if (!DistributionPolicy.isStore()) {
      SettingsDivider({ theme: this.theme });
      SettingsValueRow({ title: '怎么安装', value: 'HoKit 侧载教程', theme: this.theme, controlId: 'settings-item-install-help',
        highlighted: this.highlightedItem === 'install-help', onLayout: (): void => { this.locateItem_('install-help'); },
        onAction: (): void => { this.openHelp_(true); } });
      SettingsDivider({ theme: this.theme });
      SettingsValueRow({ title: 'JIT 的解决办法', value: '查看帮助', theme: this.theme, controlId: 'settings-item-jit-help',
        highlighted: this.highlightedItem === 'jit-help', onLayout: (): void => { this.locateItem_('jit-help'); },
        onAction: (): void => { this.openHelp_(false); } });
    }
  }
  @Builder
  private SupportContent_() {
    SettingsValueRow({ title: '问题反馈', description: '反馈问题与建议，可附截图', showIcon: true, icon: AppIconName.Document,
      theme: this.theme, controlId: 'settings-item-feedback', highlighted: this.highlightedItem === 'feedback',
      onLayout: (): void => { this.locateItem_('feedback'); }, onAction: (): void => { this.openPage_('pages/FeedbackPage'); } });
    SettingsDivider({ theme: this.theme });
    SettingsValueRow({ title: '支持作者', description: '赞助登记与支持方式', showIcon: true, icon: AppIconName.Person,
      theme: this.theme, controlId: 'settings-item-sponsor', highlighted: this.highlightedItem === 'sponsor',
      onLayout: (): void => { this.locateItem_('sponsor'); }, onAction: (): void => { this.openPage_('pages/SponsorPage'); } });
  }

  /** 面板仍使用共同 HDS 标题/关闭契约；输入正文有确定高度并可滚动，底部动作始终可达。 */
  @Builder
  private SettingsSheet_() {
    Column() {
      ImmersiveTitleScaffold({ title: this.sheetTitle_(), theme: this.theme, modal: true,
        surfaceColor: this.theme.bgPrimary, onClose: (): void => { this.cancelSheet_(); },
        content: (): void => { this.SheetContent_(); } });
    }.width('100%').height('100%');
  }
  @Builder
  private SheetContent_() {
    Column({ space: 0 }) {
      Scroll() {
        Column({ space: 20 }) {
          if (this.sheetKind === 'jvm') {
            SettingsHint({ text: '全局默认值。单个版本的参数会在其后追加，优先级更高。', theme: this.theme });
            TextArea({ text: this.jvmArgsDraft, placeholder: '留空使用默认配置' }).width('100%').height(160)
              .fontSize(16).fontColor(this.theme.textPrimary).backgroundColor(this.theme.bgCard).borderRadius(16)
              .enabled(!this.jvmSaving).id('settings-jvm-draft')
              .onChange((value: string): void => { this.jvmArgsDraft = value; this.sheetError = ''; });
            SettingsHint({ text: '多个参数用空格分隔。保存后，下次启动游戏时生效。', theme: this.theme });
            if (this.jvmSaving) SettingsHint({ text: '正在保存。关闭面板不会撤销已提交的保存。', theme: this.theme, isAccent: true });
          } else {
            if (this.sheetKind === 'frame') SettingsHint({ text: '仅调整系统渲染调度提示，不更改游戏内的最大帧率。', theme: this.theme });
            if (this.sheetKind === 'fixed-refresh-rate') {
              SettingsHint({ text: '下次启动游戏时生效。所选档位须受游戏所在屏幕支持，且不高于系统调度帧率上限。', theme: this.theme });
            }
            if (this.sheetKind === 'language') SettingsHint({ text: '设置游戏内的默认语言，单个版本可单独覆盖。', theme: this.theme });
            if (this.sheetKind === 'java') SettingsHint({ text: '自动按 Minecraft 版本匹配，推荐日常使用。下次启动游戏时生效。', theme: this.theme });
            Column() {
              ForEach(this.choiceOptions_(), (choice: SettingsChoice) => {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: 16 }) {
                    Column({ space: 4 }) {
                      Text(choice.title).fontSize(16).fontColor(choice.enabled ? this.theme.textPrimary : this.theme.textSecondary).width('100%');
                      Text(choice.description).fontSize(14).lineHeight(20).fontColor(this.theme.textSecondary).width('100%');
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start);
                    Radio({ value: choice.value, group: 'amcl-settings-choice-' + this.sheetKind })
                      .checked(this.choiceDraft === choice.value).width(24).height(24).enabled(choice.enabled)
                      .radioStyle({ checkedBackgroundColor: this.theme.primary, uncheckedBorderColor: this.theme.textSecondary })
                      .onChange((checked: boolean): void => { if (checked && choice.enabled) { this.choiceDraft = choice.value; this.sheetError = ''; } });
                  }.width('100%').constraintSize({ minHeight: 76 }).padding({ left: 16, right: 16, top: 12, bottom: 12 });
                }.width('100%').constraintSize({ minHeight: 76 }).padding(0).borderRadius(0).backgroundColor(Color.Transparent).enabled(choice.enabled)
                  .id('settings-choice-' + choice.value).accessibilityText(choice.title + '，' + choice.description + (this.choiceDraft === choice.value ? '，已选择' : ''))
                  .onClick((): void => { if (choice.enabled) { this.choiceDraft = choice.value; this.sheetError = ''; } });
                SettingsDivider({ theme: this.theme });
              }, (choice: SettingsChoice): string => choice.value);
            }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true);
            if (this.sheetKind === 'storage') {
              Column({ space: 12 }) {
                Text('切换数据位置').fontSize(16).fontColor(this.theme.textPrimary).width('100%');
                SettingsHint({ text: '迁移数据：复制现有版本、存档和模组到新位置，原位置的数据仍会保留。', theme: this.theme });
                SettingsHint({ text: '仅切换：直接使用新位置；尚未复制的数据不会在新位置显示。', theme: this.theme });
              }.width('100%').padding(20).backgroundColor(this.theme.bgCard).borderRadius(20);
            }
          }
        }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 20 });
      }.width('100%').layoutWeight(1);
      Column({ space: 12 }) {
        if (this.sheetError.length > 0) SettingsHint({ text: this.sheetError, theme: this.theme, isError: true });
        if (this.sheetKind === 'storage') {
          Button('迁移数据并切换').width('100%').height(48).fontSize(16).fontColor(Color.White)
            .backgroundColor(this.theme.actionPrimary).id('settings-storage-copy')
            .onClick((): void => { this.confirmStorage_(true); });
          Button('仅切换，不复制').width('100%').height(48).fontSize(16).fontColor(this.theme.actionText)
            .backgroundColor(this.theme.primaryLight).id('settings-storage-switch')
            .onClick((): void => { this.confirmStorage_(false); });
        } else if (this.sheetKind === 'jvm') {
          Row({ space: 12 }) {
            Button('取消').layoutWeight(1).height(48).fontSize(16).fontColor(this.theme.actionText)
              .backgroundColor(this.theme.primaryLight).enabled(!this.jvmSaving).id('settings-sheet-cancel')
              .onClick((): void => { this.cancelSheet_(); });
            Button(this.jvmSaving ? '保存中…' : '保存').layoutWeight(1).height(48).fontSize(16).fontColor(Color.White)
              .backgroundColor(this.theme.actionPrimary).enabled(!this.jvmSaving).id('settings-jvm-save')
              .onClick((): void => { this.saveCustomJvmArgs(); });
          }.width('100%');
        } else {
          Button('确定').width('100%').height(48).fontSize(16).fontColor(Color.White)
            .backgroundColor(this.theme.actionPrimary).id('settings-choice-confirm')
            .onClick((): void => { this.confirmChoice_(); });
        }
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: Math.max(16, this.bottomSafeHeight) });
    }.width('100%').height('100%');
  }
}

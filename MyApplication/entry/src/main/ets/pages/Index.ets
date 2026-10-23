import { LauncherStartupRuntime } from '../runtime/LauncherStartupRuntime';
import { StartupSplash } from '../components/startup/StartupSplash';
import { StartupTargetRect } from '../components/startup/StartupTypes';
import { UiMotion } from '../components/UiMotion';
import { ProcessPreferences } from 'commons';
import { util } from '@kit.ArkTS';
import { DesktopLaunchSnapshot, DesktopLaunchSnapshotRef } from '../runtime/DesktopLaunchSnapshot';
import { GraphicsRecoveryStore } from '../runtime/GraphicsRecoveryStore';
import { GraphicsHistoryStore } from '../runtime/GraphicsHistoryStore';
import { GraphicsRecoveryTicket, GraphicsRecoveryDispatch, graphicsRecoveryPermitted } from '../runtime/GraphicsRecoveryPolicy';
import { GameLayoutJournal, GameLayoutImportReport } from '../runtime/GameLayoutJournal';
import { SessionRecoveryRuntime } from '../runtime/SessionRecoveryRuntime';
import { GameRunAdmission } from '../runtime/GameRunAdmission';
import { getGameSessionHost } from '../runtime/GameSessionHost';
import { getGameExportCoordinator } from '../export/GameExportCoordinator';
import { storeManagerAction, storeManagerActionLabel } from '../components/StoreManagerUiPolicy';
import { DiagnosticPolicy } from 'commons';
import { DistributionPolicy } from 'commons';
// 渠道决定更新入口；不能用构建模式推断store与侧载产品。
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { SideloadUpdateTestSession, SideloadUpdateCheckSource, SideloadUpdatePromptCandidate,
  SideloadUpdatePromptPolicy } from '../sideload/SideloadUpdateTestSession';
/**
 * Index.ets — AMCL 启动器主页面（骨架）
 *
 * 三 Tab 布局：首页 / 下载 / 设置
 * Tab 内容已拆分到 tabs/HomeTab.ets、tabs/DownloadTab.ets、tabs/SettingsTab.ets
 * 本文件仅保留：Tabs 骨架、生命周期、全局状态管理、Sheet 弹窗、业务逻辑方法
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { router, mediaquery, window, promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
// 鸿蒙官方 HDS 沉浸光感悬浮 dock —— @kit.UIDesignKit
// 文档：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material
import { HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { LauncherTabsStyle } from '../components/LauncherTabsStyle';
import { immersiveLightCapabilities, publishImmersiveLightPreferences,
  effectiveBottomLightMode, immersiveLightStatus } from '../components/ImmersiveLightRuntime';
import { ImmersiveLightPreferences, copyImmersiveLightPreferences } from 'commons';
import { common, Want, ConfigurationConstant, bundleManager } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { JdkManager, JdkStatus, JdkVersionInfo } from 'launch';
import { setJdkDownloadSource, setJdkWebEnabled, RuntimeCatalogRepository, RuntimeBuild,
  RuntimeRefreshResult, runtimeCheckDue, runtimePromptDue } from 'launch';
import { setAccelActive } from 'launch';
import { RuntimeDeployer } from 'launch';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { VersionLaunchOverride } from 'feature_system';
import { GameStorage, StorageLocation, parseStorageLocation } from 'feature_system';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
// 加速下载（经 AMCL 加速网关）：握手在 ArkTS，URL 改写与每请求签名在 native
import { getRelayClient, generateDeviceId } from 'feature_core';
import { ModLoaderType } from 'feature_core';
import { DownloadTask, DownloadPhase } from 'feature_core';
import { DownloadFab } from '../components/DownloadFab';
import {
  DownloadFabLayoutPolicy, DownloadFabPosition,
} from '../window/DownloadFabLayoutPolicy';
// v6.5 (2026-05-22)：统一下载任务架构取代双 Sheet
import { DownloadTasksSheet } from '../components/DownloadTasksSheet';
import {
  DownloadTaskRegistry, RegistryListener, getDownloadTaskRegistry,
} from 'feature_core';
import { McVersionTask, McInstallSession } from 'feature_core';
import { mergeVersionOrder } from 'feature_core';
import { JdkInstallTask } from 'launch';
// 2026-08-29（JDK 更新系统 / 本地导入）：导入器 + 槽位列表 + 文件选择封装。
import { JdkImporter } from 'launch';
import { SUPPORTED_JDK_VERSIONS, isJdkSlotVersion } from 'commons';
import { GameArchiveIO } from '../components/GameArchiveIO';
// 2026-05-23：Fabric API 伴随下载——需要 ResourceInstallTask + RemoteVersion 类型。
import { ResourceInstallTask } from 'mods';
import { DownloadManager } from 'feature_core';
import { ModInstallTask, ModInstallRequest, ModSourceRouter, ModrinthRepository, CurseForgeRepository,
  ModrinthSourceMode, getModrinthSourceMode, resourceKindToInstallDir, modInstallationActive } from 'mods';
import { RemoteVersion, pickPrimaryFile } from 'mods';
import { ModpackInstallTask } from 'mods';
// 注：ResourceKind 在下面已有 import（line ~43），不在此重复导入。
import {
  UnifiedTaskState, TaskCategory, isActiveState, isTerminalState, UnifiedTaskView,
} from 'feature_core';
// Phase 5.3: 下载历史持久化
import { getDownloadHistoryStore, buildHistoryRecordFromTask } from 'feature_core'
import { ActivityCategory, ActivityStatus, ActivityRecord } from 'feature_core';
// M3：会话快照 —— 错误 Sheet 按 sessionKey 重入
import {
  resolveSessionSnapshot, snapshotToSessionInfo, readSnapshotLogTail,
  loadSessionAiText, saveSessionAiText, saveSessionShare, clearSessionShare,
} from '../components/McSessionSnapshot';
// 活动账本（L2-b）：每条活动一份完整、精确归属的日志
import { SessionRecoveryResult, writeSessionRecoveryReceiptAsync } from 'launch';
import {
  ledgerBegin, ledgerBeginAsync, ledgerEndAsync, ledgerManifest, ledgerManifestAsync, LedgerBeginMeta, LedgerOutcome, LedgerState,
} from 'commons';
// M4/M5：消息中心 + 灵动弹窗
import {
  AppMessage, AppMessageActionType, getAppMessageStore, formatBadge,
} from '../components/AppMessageStore';
import { refreshUnreadCount } from '../components/AppNotifier';
import { DynamicToast } from '../components/DynamicToast';
// Phase 2.3: 元数据 TTL 缓存
import { getMetadataCacheStore } from 'feature_core';
import { setMcSourcePreference } from 'feature_core';
import { VersionConfigPanel } from '../components/VersionConfigPanel';
import { VersionManagerSheet } from '../components/VersionManagerSheet';
import { ResourceKind } from 'mods';
import { removeDirRecursive, countFilesWithExtensions, renameVersion } from 'commons';
import { resolveInstanceGameDir, isIsolatedModpackInstance } from 'commons';
// v6.5：formatBytes 曾迁出 Index；2026-08-08 更新弹窗要显示 HAP 体积（update.json 的
// sizeBytes），重新引入。格式化在宿主做，UpdateDialog 只收预格式化文案。
import { formatBytes } from 'commons';
import { formatError } from 'commons';
import { AppLogger } from 'commons';
import { LogTags } from 'commons';
import { LOG_DOMAIN_UI, LOG_DOMAIN_ACCOUNT, LOG_DOMAIN_DOWNLOAD, LOG_DOMAIN_LAUNCH } from 'commons';
import { DiagnosticBundle, DiagnosticEnv } from 'commons';
import { sanitizeLogForExport, LogExportTarget } from 'commons';
import { JDK_AUTO } from 'commons';
import { APP_VERSION } from 'commons';
import { centerSheetForLayout, sheetWidthForLayout, detailSheetHeightForLayout } from 'commons';
import { HomeTab } from './tabs/HomeTab';
import { DownloadTab } from './tabs/DownloadTab';
import { SettingsTab } from './tabs/SettingsTab';
// M2 Phase B：账户系统 UI
import { AccountListSheet } from '../components/AccountListSheet';
// v6 (2026-05-19) — MC 异常退出错误信息 Sheet
import { McErrorSheet } from '../components/McErrorSheet';
import { PreLaunchCheckSheet } from '../components/PreLaunchCheckSheet';
import { NetworkDiagnosticsSheet } from '../components/NetworkDiagnosticsSheet';
import { SideloadUpdateService } from '../sideload/SideloadUpdateService';
import { UpdatePromptPresenter } from '../components/UpdatePromptPresenter';
import { UpdateDialog, UpdateDialogItem } from '../components/UpdateDialog';
import { quickConnectivityCheck } from 'feature_core';
import { VersionFileVerifier, VerifyReport } from 'feature_core';
import { RepairTask } from 'feature_core';
import { ForgeRepairTask } from 'feature_core';
import { UpdateChecker, UpdateCheckResult, UpdateManifest } from 'update';
import { getAccountManager } from 'account';
import { AccountType } from 'account';
import { McSessionInfo, SessionMarker } from 'launch'
import { classifyMcError, shouldDiagnose } from 'launch';
import { LaunchCoordinator } from 'launch';
// JDK 可用区间（下限来自游戏纪元、上限实读该版本自带的 ASM）。与路由同源。
import { JdkRange } from 'launch';

import { AppIconName } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { AppRoundIconButton } from '../components/AppRoundIconButton';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
import { inferLoaderInfo, resolveInstalledLoaderInfo } from '../components/LoaderCatalog';
import { invalidateInstalledLoaderCache } from 'mods';
// 三层架构重构（执行计划第 0 步）：设备形态 / 响应式断点统一抽象（公共能力层）。
// 经 @Provide 下沉到全应用，供任意产品层 UI @Consume 做手机/平板/PC 分支与响应式布局。
import { DeviceProfile, DeviceForm, Breakpoint } from 'commons';
import { PrivacyConsentDialog } from '../components/PrivacyConsentDialog';
import { ProductInputProfile } from 'entry/ProductInputProfile';
import { ProductLauncherWindowChrome } from 'entry/ProductLauncherWindowChrome';

const TAG = LogTags.PAGE_INDEX


@Entry
@Component
struct Index {
  // ==================== Tab 状态 ====================
  @State @Watch('onHomeTabVisibilityChanged_') currentTab: number = 0
  /** 首页页签可见事实供本页自动滚动组件使用，避免下载/设置页仍运行首页动画。 */
  private onHomeTabVisibilityChanged_(): void {
    AppStorage.setOrCreate<boolean>('amclHomeTabVisible', this.currentTab === 0 && this.startupFinished_
      && AppStorage.get<boolean>('amclHostPageVisible') !== false)
    AppStorage.setOrCreate<boolean>('amclSettingsTabVisible', this.currentTab === 2 && this.startupFinished_
      && AppStorage.get<boolean>('amclHostPageVisible') !== false)
  }
  /**
   * 下载页二级 Tab 受控导航命令：编码 = dlNavCounter_ × 10 + 目标子页序号。
   * 目标子页：0=版本 / 1=模组 / 2=光影 / 3=资源包 / 4=整合包 / 5=JDK。
   * 由 jumpToDownloadSub() 在切到下载 Tab 的同时 bump，透传给 DownloadTab.navCommand。
   */
  @State dlNavCommand: number = -1
  private dlNavCounter_: number = 0
  // 官方沉浸光感悬浮 dock 专用 controller（HdsTabs 要求同套 controller）
  private tabController: HdsTabsController = new HdsTabsController()

  // ==================== 设备形态 / 响应式（三层架构重构 · 建层）====================
  // 经 @Provide 下沉全应用：deviceForm=出厂形态（选触摸/键鼠范式、product 分支）；
  // appBreakpoint=随窗口宽度变化的响应式断点（选布局列数/侧栏）。
  // 本次仅"建层 + 提供能力"，默认布局不变；后续产品层 UI 按需 @Consume 分支。
  @Provide('deviceForm') deviceForm: DeviceForm = DeviceForm.PHONE
  @Provide('appBreakpoint') appBreakpoint: Breakpoint = Breakpoint.SM

  /** 开屏隐私政策弹窗可见性（上架合规）：首次启动未同意 → true。 */
  @State private showPrivacy: boolean = false

  // ==================== MC 核心状态 ====================
  @State mcVersion: string = '1.20.4'
  @State mcXmx: number = 0
  // JVM 最大内存滑块上限。默认 8192，aboutToAppear 时设为设备真实物理内存
  // （对齐 256MB），让用户最大可分配到全部物理内存（超 80% 时 UI 会弹风险确认）。
  @State xmxSliderMax: number = 8192
  @State isRunning: boolean = false
  @State private canRunGame_: boolean = GameRunAdmission.isAllowed()
  @State private storeManagerAction_: string = 'checking'
  @State private storeManagerStatus_: string = '正在检查版本文件…'
  @State private storeReadyVersions_: string[] = []
  @State private storeHasSession_: boolean = false
  private storeCheckGeneration_: number = 0
  private storeCheckSignature_: string = ''
  private storeScanError_: string = ''
  /** 所有产品复用同一导出内存订阅；历史字段名保留，隐藏/销毁时统一解除。 */
  private storeExportUnsubscribe_: (() => void) | null = null
  private pendingRunAdmission_: string = ''
  @State statusMsg: string = ''
  @State availableVersions: string[] = []
  @State orphanVersionDirs: string[] = []

  // ==================== JDK 状态 ====================
  @State jdkReady: boolean = false
  @State jdkExtractProgress: string = ''
  @State jdkVersions: JdkVersionInfo[] = []
  @State jdkDownloadMsg: string = ''
  @State jdkDownloadPercent: number = 0
  /**
   * 本地 JDK 导入进行中。
   * 单独一个标志而不是复用 registry：导入不是下载任务（没有网络、没有分段、不可取消到一半），
   * 硬塞进 registry 会让"取消"这类语义变成谎话。
   */
  @State jdkImporting: boolean = false

  // ==================== 下载状态（v6.5 2026-05-22 重构）====================
  // 所有任务状态（MC 整版 / mod / jdk）现由 DownloadTaskRegistry 管。
  // 以下仅保留 UI 局部 state（FAB 位置 / sheet 可见性 / 监听 tick）。

  // v5.1: FAB 浮动圆位置
  @State fabOffsetX: number = 16    // aboutToAppear 里根据当前窗口 drawableRect 算初始值
  @State fabOffsetY: number = 16
  @State fabViewportWidth: number = 360
  @State fabViewportHeight: number = 800
  /** v6.5：统一任务 sheet 可见性 */
  @State showTasksSheet: boolean = false
  @State downloadTaskFocusId: string = ''
  /** v6.5：registry listener tick，每次 registry 变动 +1，driver FAB 计算 fn 重设 */
  @State private tasksRev: number = 0

  // ==================== 设置 ====================
  @State useNewWindow: boolean = false
  /** 保存选择与本进程实际路线分开；修改此值不会让已有 JVM/游戏会话热切换。 */
  @State tabletIndependentGameProcess: boolean = true
  @State tabletProcessSaving: boolean = false
  @State tabletProcessMessage: string = ''
  @State versionIsolation: boolean = true
  @State virtualMemoryMode: boolean = false
  // 游戏数据(.minecraft)存储位置：沙箱(默认) / 外部 Download/com.amcl.launcher（文件管理器显示为 AMCL，卸载不丢）。
  // 切换由 SettingsTab 处理（权限 + 可选迁移）；这里仅持有当前会话生效值。
  @State storageLocation: StorageLocation = StorageLocation.SANDBOX
  @State themeMode: ThemeMode = ThemeMode.SYSTEM
  /** 整组光感配置只发布已确认值；总关闭保留两模块及档位偏好。 */
  @State private immersiveLight: ImmersiveLightPreferences = new ImmersiveLightPreferences()
  @State private immersiveLightSaving: boolean = false
  @State private immersiveLightSaveError: string = ''
  private settingsSectionBack_: (() => boolean) | undefined = undefined
  @State systemIsDark: boolean = false
  @State selectedJdkVersion: string = JDK_AUTO
  /** 当前 MC 版本【实际生效】的 JDK 版本（由 updateJdkReadyState 经 LaunchCoordinator.resolveJdk 算出）。
   *  全局选"自动"时这里是真正会用的版本号，供首页 Hero chip 展示，比直接显示 'auto' 更有意义。 */
  @State effectiveJdkVersion: string = '17'
  /** 全局游戏语言（options.txt lang code）。默认简体中文；单版本可在版本详情覆盖。 */
  @State gameLanguage: string = 'zh_cn'
  /** OHOS XComponent 调度帧率上限：0 = 自动跟随当前显示刷新率。 */
  @State ohosFrameRateCap: number = 0
  // P1-MODS §6.4: 模组下载偏好
  @State modSource: string = 'auto'
  @State cacheRemoteMeta: boolean = true
  @State modConcurrentDownloads: number = 3
  /** 加速下载开关（经 AMCL 加速网关；打开后强制官方源、忽略镜像偏好） */
  @State accelDownload: boolean = false
  /** 加速状态：''=连接中，'ok'=就绪，其它=错误原因（展示给用户） */
  @State accelStatus: string = ''
  /** JDK 下载源偏好：'auto'|'github'|'gitee'|'mirror'。同步注入 launch.setJdkDownloadSource。 */
  @State jdkSource: string = 'auto'
  @State jdkChannel: string = 'stable'
  @State jdkWebEnabled: boolean = false
  @State jdkAutoCheck: boolean = true
  @State jdkChecking: boolean = false
  @State jdkHasUpdate: boolean = false
  @State jdkCatalogStatus: string = ''
  private runtimeAutoCheckStarted_: boolean = false
  private pendingRuntimePrompt_: boolean = false
  private pendingRuntimePromptManual_: boolean = false
  private pendingRuntimeCheck_: boolean = false
  /** 清单、原始来源代次和手动意图一起排队；展示时不得重新猜测当前全局测试来源。 */
  private pendingAppUpdate_: SideloadUpdatePromptCandidate | null = null
  /** 返回手动更新页后重新采样订阅；旧队列与旧节流不能跨通道。 */
  private shownAppUpdateChannel: string = 'stable'
  /**
   * MC 版本下载源偏好：'auto'|'mirror'|'official'。同步注入 feature_core.setMcSourcePreference。
   * 2026-08-04 新增 —— 在此之前版本下载的源顺序只由 RTT 探测决定，设置页那个开关只管模组。
   */
  @State mcSource: string = 'auto'
  // ==================== Sheet 弹窗状态 ====================
  @State showVersionConfig: boolean = false
  @State configGameVersion: string = ''
  /**
   * 选中版本的子类别（从 DownloadTab manifest 推出），透传给 VersionConfigPanel。
   * '' = 未识别，让 VersionConfigPanel fallback 到按 versionId 推断。
   */
  @State configGameCategory: string = ''
  @State showLogDialog: boolean = false
  @State launcherLog: string = ''
  @State showVersionManager: boolean = false
  /**
   * 导出内容嵌入版本管理 Sheet 后，系统返回、下拉及遮罩关闭也必须经过草稿保护。
   * 回调只在导出组件存活期间注册；普通版本管理仍交给系统原有关闭行为。
   * 这里仅转交交互，不持有导出选择，也不因宿主收起而取消协调器任务。
   */
  private versionExportDismiss_: ((back?: boolean) => void) | undefined = undefined
  // M2 Phase B：账户管理 Sheet
  @State showAccountListSheet: boolean = false
  @State accountUsername: string = 'MCPlayer'
  @State accountTypeLabel: string = '离线账户'
  /** 当前账户的 MC UUID（36 位 dash 格式）；HomeTab 拼 Crafatar 头像 URL 用。 */
  @State accountUuid: string = ''
  /** 当前账户皮肤 URL（textures.minecraft.net）；HomeTab 头像优先从皮肤本地裁头。 */
  @State accountSkinUrl: string = ''

  // 已装资源管理统一收敛进"版本管理 Sheet"的第三步（同 sheet 横滑），不再单独弹窗。
  // 下面三个 state 作为打开版本管理 sheet 时的"深链初始参数"传给 VersionManagerSheet。
  /** 打开版本管理 sheet 落在哪一步：'list'（默认）/ 'detail' / 'resources' */
  @State versionManagerInitialStep: string = 'list'
  /** 深链目标版本（resources/detail 步用；默认与 mcVersion 同步） */
  @State installedResourcesTargetVersion: string = ''
  /** 深链目标资源类型（resources 步用） */
  @State installedResourcesKind: ResourceKind = ResourceKind.MOD
  /** 当前选中版本的已装模组数（含禁用），由 scanInstalledModsCount() 维护 */
  @State installedModsCount: number = 0
  /** 上次成功启动 MC 的 wall-clock 时间戳（ms），由 launchMC 写入 PreferenceManager 同步 */
  @State lastPlayedAt: number = 0

  // ==================== 系统状态 ====================
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0
  @State isLandscape: boolean = false
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  /** 上次下发给 ApplicationContext 的 colorMode，避免重复 setColorMode 触发多余配置更新。 */
  private lastAppliedColorMode_: number = -999
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0

  // v6.5: 取消对话框 已由 DownloadTasksSheet 内部接管，这里不再需要。

  // ==================== 私有成员 ====================
  // 2026-05-23 API NEXT 迁移：getContext(this) 已弃用（API 18+）。改成从
  // EntryAbility.onCreate 缓存到 AppStorage 的 'uiAbilityContext' 取。
  // 字段初始化时 EntryAbility 已经跑完 onCreate（顺序由 onWindowStageCreate
  // → loadContent 保证），非空断言 ! 安全。详见 docs/guides/api-migration-2026-05.md。
  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!;
  /** 三个业务服务惰性建立，避免目录/偏好同步加载挡住开屏首帧。 */
  private jdkManager_: JdkManager | null = null;
  private launchCoordinator_: LaunchCoordinator | null = null;
  private prefManager_: PreferenceManager | null = null;

  private getJdkManager_(): JdkManager {
    if (this.jdkManager_ === null) this.jdkManager_ = new JdkManager(this.context);
    return this.jdkManager_;
  }
  private getLaunchCoordinator_(): LaunchCoordinator {
    if (this.launchCoordinator_ === null) this.launchCoordinator_ = new LaunchCoordinator(this.getJdkManager_());
    return this.launchCoordinator_;
  }
  private getPrefManager_(): PreferenceManager {
    if (this.prefManager_ === null) this.prefManager_ = new PreferenceManager(this.context);
    return this.prefManager_;
  }
  private landscapeListener: mediaquery.MediaQueryListener | null = null
  /** 启动器主窗口；同时是 FAB 坐标空间与 windowSizeChange 监听的所有者。 */
  private launcherWindow_: window.Window | null = null
  private fabPositionInitialized_: boolean = false
  private rootViewportUpdateTimer_: number = -1
  private launcherWindowSizeListener_: (size: window.Size) => void =
    (size: window.Size): void => {
      this.refreshLauncherViewport_(size.width, size.height)
    }
  private themeInitialized: boolean = false
  @StorageProp('desktopSessionRevision') @Watch('onDesktopSessionChanged') private desktopSessionRevision: number = 0
  @StorageProp('desktopLaunchError') @Watch('onDesktopLaunchError') private desktopLaunchError: string = ''
  @StorageProp('graphicsRecoverySignal') @Watch('onGraphicsRecoverySignal_') private graphicsRecoverySignal_: number = 0
  private pendingGraphicsRecoveryId_: string = ''
  private graphicsRecoveryPolling_: boolean = false
  private graphicsPreferenceStamp_(): string {
    const preferences = new PreferenceManager(this.context)
    return GraphicsRecoveryStore.preferenceHash(preferences.graphicsProfile + ':' + preferences.graphicsProfileExplicit
      + ':' + preferences.devRendererOverride + ':' + JSON.stringify(preferences.resolveLaunch(this.mcVersion)))
  }
  private onGraphicsRecoverySignal_(): void {
    this.recoverGraphics_().catch((error: Error) => {
      AppLogger.warn(TAG, 'Graphics recovery stopped; original attempt remains in history', error, LOG_DOMAIN_LAUNCH)
      this.safeToast_('图形恢复未能完成：' + error.message)
    })
  }
  /** 返回信号只唤醒核验。必须等待游戏锁和原 PID 都结束，且用户没有另选实例/设置。 */
  private async recoverGraphics_(): Promise<void> {
    if (!GameRunAdmission.isAllowed()) return
    if (this.graphicsRecoveryPolling_ || this.pendingGraphicsRecoveryId_.length === 0) return
    const id: string = this.pendingGraphicsRecoveryId_
    const ticket = GraphicsRecoveryStore.ticket(this.context.filesDir, id)
    const failure = GraphicsRecoveryStore.failure(this.context.filesDir, id)
    const outcome = GraphicsHistoryStore.outcome(this.context.filesDir, id)
    if (ticket === undefined || (failure === undefined && outcome === undefined)) return
    // 恢复仍属于原用户启动，不能在等待旧进程结束后重新捕获授权给旧请求续命。
    const admission: string = this.pendingRunAdmission_
    GameRunAdmission.assertToken(this.context, admission)
    const childPid: number = failure !== undefined ? failure.childPid : outcome!.childPid
    this.graphicsRecoveryPolling_ = true
    try {
      const deadline: number = Date.now() + 5000
      let state: number = -1
      let alive: number = -1
      do {
        GameRunAdmission.assertToken(this.context, admission)
        if (this.pendingGraphicsRecoveryId_ !== id) return
        state = testNapi.desktopGameProcessState(this.context.filesDir, 0)
        alive = testNapi.desktopProcessAlive(childPid)
        if (state === 0 && alive === 0) break
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100) })
      } while (Date.now() < deadline)
      GameRunAdmission.assertToken(this.context, admission)
      if (state === 0 && alive === 0 && outcome !== undefined && outcome.childPid === childPid && failure?.diagnosticInjected !== true) {
        try {
          if (GraphicsHistoryStore.learn(this.context.filesDir, ticket, outcome, testNapi.desktopProcessId(),
            this.pendingGraphicsRecoveryId_, Date.now())) AppLogger.info(TAG,
            `graphics_history_learned profile=${outcome.profile} scope=${outcome.scopeHash} status=${outcome.status}`, LOG_DOMAIN_LAUNCH)
        } catch (historyError) { AppLogger.warn(TAG, 'Optional graphics history persistence deferred', historyError, LOG_DOMAIN_LAUNCH) }
      }
      if (failure === undefined) return
      if (!graphicsRecoveryPermitted(ticket, failure, this.pendingGraphicsRecoveryId_, testNapi.desktopProcessId(),
        state, alive, this.mcVersion, this.mcRoot(), this.graphicsPreferenceStamp_(), Date.now())) return
      if (!GraphicsRecoveryStore.claim(this.context.filesDir, id)) return
      this.pendingGraphicsRecoveryId_ = ''
      DesktopLaunchSnapshot.discard(this.context, this.pendingDesktopSnapshot)
      this.pendingDesktopSnapshot = ''
      this.preLaunchGameDir = ticket.gameDir; this.preLaunchJdkVersion = ticket.jdk; this.preLaunchXmx = ticket.xmx
      this.safeToast_('图形初始化失败，正在新进程尝试兼容后端')
      AppLogger.warn(TAG, `graphics_recovery_start root=${ticket.rootActivityId} previous=${ticket.activityId}`
        + ` failed=${failure.profile} candidate=${failure.nextProfile}`, undefined, LOG_DOMAIN_LAUNCH)
      const retry: GraphicsRecoveryDispatch = { rootActivityId: ticket.rootActivityId, attempt: 1, profile: failure.nextProfile }
      if (failure.diagnosticInjected === true || ticket.diagnosticInjected === true) retry.diagnosticInjected = true
      await this.performLaunch(retry, admission)
    } finally { this.graphicsRecoveryPolling_ = false }
  }
  @StorageProp('gameLayoutSyncNotice') @Watch('onGameLayoutSyncNotice') private gameLayoutSyncNotice: string = ''
  /** 布局保存的冲突/暂失败不伪装成游戏启动失败；原文保留，用户知道去哪里查看。 */
  private onGameLayoutSyncNotice(): void {
    if (!this.startupFinished_) return;
    if (this.gameLayoutSyncNotice.length === 0) return
    this.safeToast_(this.gameLayoutSyncNotice)
    AppStorage.setOrCreate<string>('gameLayoutSyncNotice', '')
  }
  private onDesktopSessionChanged(): void { this.lastSessionShown = false; this.consumeLastSession() }
  /** 错误通知只负责展示；启动快照由确认撤回的交接或child消费，不凭一条错误通知提前删除。 */
  private onDesktopLaunchError(): void {
    if (!this.startupFinished_) return;
    if (this.desktopLaunchError.length === 0) return
    this.getUIContext().getPromptAction().showToast({ message: this.desktopLaunchError, duration: 3500 })
    AppStorage.setOrCreate<string>('desktopLaunchError', '')
  }
  private lastSessionShown: boolean = false  // SessionMarker Sheet 去重
  /** 恢复串行闸门，防止冷启动/前台两个通知同时为同一活动写历史。 */
  private recoveringSessions_: boolean = false
  /** 页面只拥有结果展示资格；离页后完成的owner恢复仍继续，旧UI回调不得确认展示。 */
  private recoveryPresentationEpoch_: number = 0
  /** 首次可见首页的准入条件：本地初始化与整批历史恢复完成，不能把同步续作留给首次点击。 */
  @State private launcherStartupReady_: boolean = false
  /** 初始化、首页揭示与最终输入资格独立，避免 onFinish 被系统提前触发时越过准备。 */
  @State private launcherInitialized_: boolean = false;
  @State private startupRevealed_: boolean = false;
  @State private startupFinished_: boolean = false;
  @State private startupTarget_: StartupTargetRect = new StartupTargetRect();
  @State private startupHomeLaidOut_: boolean = false;
  @State private startupRouteVisible_: boolean = true;
  @State private startupReduced_: boolean = false;
  private startupAlive_: boolean = false;
  private launcherPreparationStarted_: boolean = false;
  @State private launcherInitializationComplete_: boolean = false;
  /** 首次挂载只扫描一次；普通路由返回仍按旧行为刷新。 */
  private startupInitialPageShow_: boolean = true;
  private recoveryPresentationDeferred_: boolean = false;
  private versionScanEpoch_: number = 0;
  /** 库存异步刷新时禁止按上一个存储根的选择派发游戏。 */
  private versionScanPending_: boolean = false;
  /** Sheet 动画完成后的呈现回执，必须与当前会话及页面代次匹配。 */
  private errorSheetVisibleKey_: number = 0;
  private errorSheetVisibleEpoch_: number = -1;
  private errorSheetWaitKey_: number = 0;
  private errorSheetWaitEpoch_: number = 0;
  private errorSheetWait_: ((shown: boolean) => void) | null = null;
  private errorSheetWaitTask_: Promise<boolean> | null = null;
  private errorSheetWaitTimer_: number = -1;

  /** 显示失败、离页或销毁都必须收口 Promise；无法证明呈现就保留恢复义务。 */
  private finishErrorSheetWait_(shown: boolean): void {
    if (this.errorSheetWaitTimer_ >= 0) clearTimeout(this.errorSheetWaitTimer_);
    this.errorSheetWaitTimer_ = -1;
    const finish = this.errorSheetWait_;
    this.errorSheetWait_ = null;
    this.errorSheetWaitTask_ = null;
    if (finish !== null) finish(shown);
  }

  /** SheetOptions.onAppear 在显示动画结束后触发，而非设置 show=true 的时刻。 */
  private recoverySheetOptions_(): SheetOptions {
    const options: SheetOptions = this.adaptiveSheetOptions(this.theme.bgSecondary);
    options.onAppear = (): void => {
      if (!this.startupAlive_ || !this.startupRouteVisible_ || !this.startupFinished_
        || this.errorSheetWaitEpoch_ !== this.recoveryPresentationEpoch_) return;
      this.errorSheetVisibleKey_ = this.mcErrorSessionKey;
      this.errorSheetVisibleEpoch_ = this.recoveryPresentationEpoch_;
      if (this.startupAlive_ && this.startupRouteVisible_ && this.startupFinished_
        && this.errorSheetWaitKey_ === this.mcErrorSessionKey
        && this.errorSheetWaitEpoch_ === this.recoveryPresentationEpoch_) this.finishErrorSheetWait_(true);
    };
    options.onDisappear = (): void => {
      this.errorSheetVisibleKey_ = 0;
      this.finishErrorSheetWait_(false);
      this.resumeRecoveryPresentation_();
      this.onOpenErrorSheetReq();
      this.drainUpdateDialogs_();
    };
    return options;
  }

  /** 同一已显示会话可复用；不同会话必须等上一张 Sheet 关闭，避免覆盖后误 ack。 */
  private waitForErrorSheet_(key: number): Promise<boolean> {
    if (this.startupAlive_ && this.startupRouteVisible_ && this.errorSheetVisibleKey_ === key
      && this.errorSheetVisibleEpoch_ === this.recoveryPresentationEpoch_) return Promise.resolve(true);
    if (this.errorSheetWaitKey_ === key && this.errorSheetWaitTask_ !== null) return this.errorSheetWaitTask_;
    this.finishErrorSheetWait_(false);
    this.errorSheetWaitTask_ = new Promise<boolean>((resolve: (shown: boolean) => void): void => {
      this.errorSheetWaitKey_ = key;
      this.errorSheetWaitEpoch_ = this.recoveryPresentationEpoch_;
      this.errorSheetWait_ = resolve;
      this.errorSheetWaitTimer_ = setTimeout((): void => { this.finishErrorSheetWait_(false); }, 4000);
    });
    return this.errorSheetWaitTask_;
  }

  /** 隐私优先，错误结果逐张展示；原件只在匹配的实际呈现之后才确认。 */
  private resumeRecoveryPresentation_(): void {
    if (!this.startupFinished_ || !this.startupRouteVisible_ || this.showPrivacy || this.showMcErrorSheet
      || this.recoveringSessions_) return;
    if (this.recoveryPresentationDeferred_) {
      this.recoveryPresentationDeferred_ = false;
      this.lastSessionShown = false;
      this.consumeLastSession();
    }
  }

  /** 收到真实窗口内品牌矩形后才允许归位；页面尺寸变化沿用同一启动轮次。 */
  private onStartupTarget_(rect: StartupTargetRect): void {
    if (!this.startupAlive_) return;
    this.startupTarget_ = rect;
    if (rect.valid) this.startupHomeLaidOut_ = true;
  }

  /** 退场时显示首页但保留输入遮挡，header 图像由飞行斧占位。 */
  private revealStartupHome_(): void {
    if (!this.startupAlive_ || !this.launcherStartupReady_ || !this.startupHomeLaidOut_) return;
    this.startupRevealed_ = true;
  }

  /** 最后一帧才交还原图、触控与可见事实；自动弹窗和外部导入从这里排队交接。 */
  private finishStartup_(): void {
    if (!this.startupAlive_ || this.startupFinished_ || !this.launcherStartupReady_) return;
    this.startupRevealed_ = true;
    this.startupFinished_ = true;
    this.onHomeTabVisibilityChanged_();
    this.resumeRecoveryPresentation_();
    this.onDesktopLaunchError();
    this.onGameLayoutSyncNotice();
    if (AppStorage.get<boolean>('amclSideloadUpdateCompleted') === true) {
      AppStorage.setOrCreate<boolean>('amclSideloadUpdateCompleted', false);
      this.safeToast_('AMCL 已更新完成');
    }
    this.onOpenErrorSheetReq();
    this.onPendingToast();
    this.onOpenNetDiagReq();
    this.tryConsumeLayoutImport();
    this.drainUpdateDialogs_();
    this.showUpdateRecovery_();
    AppLogger.info(TAG, 'Launcher splash handoff completed; home input enabled', LOG_DOMAIN_UI);
  }
  /** 启动失败保留准备页和原始证据；用户可重试，不能按“已经显示首页”掩盖未完成的恢复。 */
  @State private launcherStartupFailed_: boolean = false
  /** 只等待现有本地存储/账户初始化，联网更新与目录请求不阻止应用进入首页。 */
  private launcherStartupJobs_: Promise<void>[] = []
  /** 恢复任务包括历史写入、展示回执和 finally 收尾；新前台批次会替换此身份。 */
  private sessionRecoveryTask_: Promise<void> = Promise.resolve()
  private sessionRecoveryError_: Error | null = null
  /** 组件销毁或重试会推进代次，旧异步回调不能开放已退出的页面。 */
  private launcherStartupAttempt_: number = 0
  /** 开账异步任务按ID跟踪，终态必须等待自己的开账，不能被全局owner忙碌异常吞掉。 */
  private activityBeginJobs_: Map<number, Promise<void>> = new Map<number, Promise<void>>()

  // v6.5: 统一任务 registry + listener
  private registry: DownloadTaskRegistry = getDownloadTaskRegistry();
  private registryListener: RegistryListener = () => {
    this.onRegistryChanged_();
  };
  /** 本页生命周期与Ability前台共同决定视觉/网络观察资格，不能仅凭组件尚存活。 */
  private launcherWorkVisible_: boolean = false
  @StorageProp('appInForeground') @Watch('onLauncherWorkVisibilityChanged_')
  private launcherWorkForeground_: boolean = false
  private tasksProjectionDirty_: boolean = false

  /** 业务终态/活动封账始终处理；隐藏页的每次进度事件只记一次待投影标记。 */
  private onRegistryChanged_(): void {
    if (this.launcherWorkVisible_ && this.launcherWorkForeground_) this.tasksRev++
    else this.tasksProjectionDirty_ = true
    this.syncStatusFromRegistry_()
    this.refreshStoreManager_()
  }

  /** 前台或页面边沿停止自动网络复检，返回后合并刷新视觉投影，不补跑历史定时tick。 */
  private onLauncherWorkVisibilityChanged_(): void {
    if (!this.launcherInitialized_) return;
    if (!this.launcherWorkVisible_ || !this.launcherWorkForeground_) {
      this.netCheckEpoch_++
      this.stopNetRecheck_()
      return
    }
    if (this.tasksProjectionDirty_) {
      this.tasksProjectionDirty_ = false
      this.tasksRev++
    }
    if (this.netInitialCheckPending_) this.runNetCheck_(true)
    this.onNetBannerChange()
  }

  // v6 (2026-05-19) — McErrorSheet 数据
  // aboutToAppear 检测到 lastMcSession 时填充这三个字段并把 showMcErrorSheet=true
  @State lastMcSession: McSessionInfo = { startedAt: 0, version: '', mcDir: '' }
  @State lastMcSessionSummary: string = ''
  /** 最近活动记录（活动时间线 · 阶段4）：传给 HomeTab 最近活动卡展示，最新在前。 */
  @State recentActivities: ActivityRecord[] = []
  @State lastMcSessionLogTail: string = ''
  @State showMcErrorSheet: boolean = false

  // M3 — 会话快照：让错误 Sheet 可以按 sessionKey 重入，并把已有的分享 / AI 结果带回。
  /** 当前 Sheet 展示的会话主键（= ActivityRecord.startedAt）；0 = 无。 */
  @State private mcErrorSessionKey: number = 0
  @State private mcErrorLsId: string = ''
  @State private mcErrorLsUrl: string = ''
  @State private mcErrorLsToken: string = ''
  @State private mcErrorLsSharedAt: number = 0
  /** 上次已保存的 AI 正文（从 filesDir/logs/ai/<key>.md 读回）。 */
  @State private mcErrorAiText: string = ''
  /** 其它页面把 sessionKey 写进这里请求打开错误 Sheet（活动记录「查看详情」/ 消息中心 / 通知）。 */
  @StorageLink('amcl_open_error_sheet_session') @Watch('onOpenErrorSheetReq')
  openErrorSheetSession: number = 0

  // M4/M5 — 消息中心与灵动弹窗
  /** 未读消息数（驱动铃铛角标）。由 AppNotifier 写入 AppStorage。 */
  @StorageLink('amcl_message_unread') unreadCount: number = 0
  /** 待展示的灵动弹窗消息 id（前台收到消息时由 AppNotifier 写入）。 */
  @StorageLink('amcl_pending_toast_msg_id') @Watch('onPendingToast') pendingToastMsgId: string = ''
  @State private toastVisible: boolean = false
  @State private toastTitle: string = ''
  @State private toastBody: string = ''
  /** 弹窗点击后要打开的会话；0 = 无动作。 */
  private toastSessionKey: number = 0
  private toastMsgId: string = ''

  // 「打开方式」导入布局：EntryAbility 在冷/热启动收到 .json viewData Want 时写入本 key。
  // 冷启动由 onPageShow 消费（初值），热启动由 @Watch 消费（app 已在前台时点文件）。
  @StorageLink('pendingLayoutImportUri') @Watch('onPendingLayoutImport') pendingLayoutImportUri: string = ''

  // 网络诊断（2026-07-04）：顶部「网络异常」横幅 + 网络环境检测 Sheet。
  // 横幅可见性/文案放 AppStorage，供任意页面（模组/版本/JDK 下载失败处）触发。
  @StorageLink('amcl_net_banner_visible') @Watch('onNetBannerChange') netBannerVisible: boolean = false
  @StorageLink('amcl_net_banner_text') netBannerText: string = '网络连接异常，部分功能可能不可用'
  @State showNetDiagSheet: boolean = false
  // 其它页面把此 nonce 置为时间戳即可请求打开诊断 Sheet（@Watch 触发）。
  @StorageLink('amcl_open_netdiag_nonce') @Watch('onOpenNetDiagReq') openNetDiagNonce: number = 0
  // 横幅显示时的周期性复检定时器（网络恢复后自动隐藏横幅）。-1 = 未运行。
  private netRecheckTimer: number = -1
  /** 请求不重叠；离页代次使旧结果失效。初次检查可延后到真实可见时执行。 */
  private netCheckBusy_: boolean = false
  private netCheckEpoch_: number = 0
  private netInitialCheckPending_: boolean = false

  // 启动前硬校验 Sheet（JIT / 运行时环境 / 版本文件完整性）。
  // launchMC 点击后先弹此 Sheet 校验，三项全通过才 doLaunchAfterChecks 真正创建 JVM。
  @State private showPreLaunchSheet: boolean = false
  @State private preLaunchGameDir: string = ''
  @State private preLaunchJdkVersion: string = ''
  /**
   * 启动前 JDK 校验用的**可用区间**（下限来自游戏纪元、上限实读该版本自带的 ASM）。
   * 与 JDK 路由同源；区间内任何已装 JDK 都能启动，纪元理想只是推荐（施工记录 §S12）。
   */
  @State private preLaunchJdkRange: JdkRange = { minMajor: 0, maxMajor: 0, preferredJdk: '',
    ceilingSource: 'none', ceilingEvidence: '', generation: '', displayName: '' }
  @State private preLaunchXmx: number = 0

  /** 检查更新红点：目标满足code/发行名/通道准入时为true，升级后同code的旧预览也会清除。 */
  @State private updateDot: boolean = false

  /**
   * 更新弹窗控制器。每次弹之前重建（内容随 manifest 变化，@CustomDialog 的入参在
   * 构造时固化），持有引用只为让实例活到弹窗关闭。
   */
  private exitPresentedUpdate: () => boolean = (): boolean => true
  private updatePresenterOwner: string = 'index-' + util.generateRandomUUID()
  private updateDialogCtrl_: CustomDialogController | null = null

  /**
   * 本次 app 会话（进程）是否已点击过「启动游戏」。
   * 已启动游戏后，自动检查更新即使发现新版也只刷红点、不弹提示框，避免打扰游戏体验。
   * 进程级标志（非 @State，不参与渲染），随进程销毁自然重置。
   */
  private gameLaunchedThisSession: boolean = false

  /** aboutToAppear 可能在同一进程重复进入；自动更新检查每个进程最多启动一次。 */
  @StorageProp('amclSideloadUpdateAttentionRevision') @Watch('onUpdateAttentionChanged_') private updateAttentionRevision_: number = 0
  @StorageProp('amclSideloadUpdateCompleted') @Watch('onUpdateCompleted_') private updateCompleted_: boolean = false
  private onUpdateAttentionChanged_(): void {
    this.recoveryPromptShown = false; this.showUpdateRecovery_()
  }
  private onUpdateCompleted_(): void {
    if (this.startupFinished_ && this.updateCompleted_ && AppStorage.get<boolean>('amclHostPageVisible') === true) {
      AppStorage.setOrCreate<boolean>('amclSideloadUpdateCompleted', false)
      this.getUIContext().getPromptAction().showToast({ message: 'AMCL 已更新完成' })
    }
  }
  private recoveryPromptShown: boolean = false
  private autoUpdateCheckStarted: boolean = false
  /** default测试入口只通知真实“检查更新”动作，不从测试侧构造弹窗或安装结果。 */
  @StorageProp('amclSideloadTestRequest') @Watch('onSideloadTestRequest_') private sideloadTestRequest_: number = 0
  private handledSideloadTestRequest_: number = 0
  /** 自更新缺少运行时的明确出口；只切到既有设置页，不自行下载用户运行时。 */
  @StorageProp('amclUpdateOpenSettings') @Watch('onUpdateOpenSettings_') private updateOpenSettings_: number = 0
  // 更新服务独立于本页面封账；成功/失败/取消都刷新最近活动，不能只等待路由再次显示。
  @StorageProp('amclUpdateActivityRevision') @Watch('refreshRecentActivities_') private updateActivityRevision_: number = 0
  private onUpdateOpenSettings_(): void { this.currentTab = 2; }
  @StorageProp('amclUpdateRecoveryRequested') @Watch('onUpdateRecoveryRequested_') private updateRecoveryRequested_: number = 0
  private handledUpdateRecovery_: number = 0
  private onUpdateRecoveryRequested_(): void {
    if (AppStorage.get<boolean>('amclHostPageVisible') !== true || this.updateRecoveryRequested_ === this.handledUpdateRecovery_) return
    this.handledUpdateRecovery_ = this.updateRecoveryRequested_; this.checkForUpdate()
  }


  private onSideloadTestRequest_(): void {
    if (!SideloadUpdateTestSession.active() || this.sideloadTestRequest_ === this.handledSideloadTestRequest_) return
    this.handledSideloadTestRequest_ = this.sideloadTestRequest_
    this.checkForUpdate()
  }

  // 版本文件全量校验（SHA1）覆盖层：版本详情手动触发，跑 VersionFileVerifier.verifyAll。
  @State private showVerifyOverlay: boolean = false
  @State private verifyRunning: boolean = false       // true=校验中（显示进度），false=已出结果
  @State private verifyTitle: string = ''             // 校验的版本 id
  @State private verifyText: string = ''              // 进度文案 / 结果摘要
  @State private verifyProblemCount: number = 0       // 缺失+损坏总数（>0 才显示"重新下载"按钮）

  // ==================== 生命周期 ====================

  /**
   * 应用一次窗口内 viewport（vp），并把 FAB 重排回当前窗口可见区。
   *
   * 这里不读 display：PC 浮动窗口与物理屏幕不是同一个坐标空间。
   */
  private applyLauncherViewportVp_(viewportWidth: number, viewportHeight: number): void {
    if (!Number.isFinite(viewportWidth) || !Number.isFinite(viewportHeight) ||
        viewportWidth <= 0 || viewportHeight <= 0) return

    let position: DownloadFabPosition
    if (this.fabPositionInitialized_) {
      position = DownloadFabLayoutPolicy.reflow(
        this.fabOffsetX, this.fabOffsetY,
        this.fabViewportWidth, this.fabViewportHeight,
        viewportWidth, viewportHeight,
        this.bottomSafeHeight)
    } else {
      position = DownloadFabLayoutPolicy.initial(
        viewportWidth, viewportHeight, this.bottomSafeHeight)
      this.fabPositionInitialized_ = true
    }

    this.fabViewportWidth = viewportWidth
    this.fabViewportHeight = viewportHeight
    this.fabOffsetX = position.x
    this.fabOffsetY = position.y
    this.isLandscape = viewportWidth > viewportHeight
    this.appBreakpoint = DeviceProfile.breakpointOf(viewportWidth)
  }

  /**
   * 读取当前窗口可绘制区域。drawableRect 是 ArkUI 内容坐标；回调 size 只作平台异常兜底。
   */
  private refreshLauncherViewport_(fallbackWidthPx: number, fallbackHeightPx: number): void {
    let widthPx: number = fallbackWidthPx
    let heightPx: number = fallbackHeightPx
    if (this.launcherWindow_ !== null) {
      try {
        const properties: window.WindowProperties =
          this.launcherWindow_.getWindowProperties()
        const rect: window.Rect = properties.drawableRect
        if (rect.width > 0 && rect.height > 0) {
          widthPx = rect.width
          heightPx = rect.height
        } else if (properties.windowRect.width > 0 && properties.windowRect.height > 0) {
          widthPx = properties.windowRect.width
          heightPx = properties.windowRect.height
        }
      } catch (e) { /* 窗口切换瞬间允许回退到 windowSizeChange 的 size */ }
    }
    if (widthPx <= 0 || heightPx <= 0) return
    const uiCtx = this.getUIContext()
    this.applyLauncherViewportVp_(uiCtx.px2vp(widthPx), uiCtx.px2vp(heightPx))
  }

  /**
   * 根 Stack 的布局尺寸是首帧最终兜底，也是 drawableRect 与真实 ArkUI 内容区的交叉校验。
   * 延后一帧写 @State，避免在 onSizeChange 的同步布局阶段把坐标更新卷入其它动画闭包。
   */
  private queueRootViewportUpdate_(viewportWidth: number, viewportHeight: number): void {
    if (!Number.isFinite(viewportWidth) || !Number.isFinite(viewportHeight) ||
        viewportWidth <= 0 || viewportHeight <= 0) return
    if (this.rootViewportUpdateTimer_ >= 0) {
      clearTimeout(this.rootViewportUpdateTimer_)
    }
    this.rootViewportUpdateTimer_ = setTimeout(() => {
      this.rootViewportUpdateTimer_ = -1
      this.applyLauncherViewportVp_(viewportWidth, viewportHeight)
    }, 0)
  }

  /**
   * 首次出现只确定主题。只读一个设置键，不执行 loadAll、JDK 检查或整棵首页构建；
   * 真正业务准备由开屏提交空背景并开始入场后触发。系统启动窗不能预读私有主题。
   */
  aboutToAppear(): void {
    this.startupAlive_ = true;
    this.systemIsDark = this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    try {
      const raw = ProcessPreferences.open(this.context, 'amcl_settings').getSync('themeMode', ThemeMode.SYSTEM);
      this.themeMode = raw === ThemeMode.LIGHT ? ThemeMode.LIGHT
        : raw === ThemeMode.DARK ? ThemeMode.DARK : ThemeMode.SYSTEM;
    } catch (_) { this.themeMode = ThemeMode.SYSTEM; }
    this.theme = resolveTheme(this.themeMode, this.systemIsDark);
    this.startupReduced_ = UiMotion.reduced();
    this.onHomeTabVisibilityChanged_();
  }

  /** 首个动画绘制机会以后才挂载首页并执行原有初始化；路由身份始终为 Index。 */
  private async beginLauncherPreparation_(): Promise<void> {
    if (!this.startupAlive_ || this.launcherPreparationStarted_) return;
    this.launcherPreparationStarted_ = true;
    try {
      await LauncherStartupRuntime.prepare();
      if (!this.startupAlive_) return;
      this.launcherInitialized_ = true;
      this.initializeLauncher_();
      this.launcherInitializationComplete_ = true;
      if (this.startupRouteVisible_) this.onPageShow();
    } catch (error) {
      this.launcherStartupFailed_ = true;
      AppLogger.error(TAG, 'Launcher startup initialization failed; retry retains preparation gate', error, LOG_DOMAIN_LAUNCH);
    }
  }

  /** 同步初始化失败与恢复失败分开重试，不能用空 jobs 数组放行一个未初始化的首页。 */
  private retryStartup_(): void {
    if (this.launcherInitializationComplete_) {
      this.consumeLastSession();
      this.completeLauncherStartup_();
      return;
    }
    this.launcherStartupAttempt_++;
    this.registry.removeListener(this.registryListener);
    this.landscapeListener?.off('change');
    this.landscapeListener = null;
    if (this.launcherWindow_ !== null) {
      this.launcherWindow_.off('windowSizeChange', this.launcherWindowSizeListener_);
      this.launcherWindow_ = null;
    }
    this.launcherPreparationStarted_ = false;
    this.launcherInitialized_ = false;
    this.launcherStartupFailed_ = false;
    this.beginLauncherPreparation_();
  }

  /** 延续既有初始化及恢复所有权，不用动画结束代替真实就绪。 */
  private initializeLauncher_(): void {
    // 2026-05-23 API NEXT 迁移：全局 mediaquery / px2vp / promptAction / router /
    //   animateTo 均已弃用，本页全部改走 this.getUIContext().XXX(...)。
    //   详见 docs/guides/api-migration-2026-05.md。
    let uiCtx = this.getUIContext()
    // 三层架构重构（建层）：解析设备形态 + 初始响应式断点，下沉给全应用 UI 分支用。
    this.deviceForm = DeviceProfile.form()
    this.appBreakpoint = DeviceProfile.currentBreakpoint()
    // MediaQuery 监听横竖屏
    this.landscapeListener = uiCtx.getMediaQuery().matchMediaSync('(orientation: landscape)')
    this.isLandscape = this.landscapeListener.matches
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isLandscape = result.matches
    })
    // v5.1: 初始化 FAB 位置（当前窗口右下角，悬浮 dock 上方）。
    // PC 浮动窗口必须用 drawableRect；物理 display 会把坐标算到窗口外。
    try {
      const win: window.Window | undefined =
        (this.context as common.UIAbilityContext).windowStage?.getMainWindowSync()
      if (win) {
        this.launcherWindow_ = win
        this.refreshLauncherViewport_(0, 0)
        win.on('windowSizeChange', this.launcherWindowSizeListener_)
      }
    } catch (e) {
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, 'INDEX', 'Window size listener setup skipped: %{public}s', formatError(e))
    }

    // 深色模式
    try {
      let ctx = this.context as common.UIAbilityContext
      let config = ctx.config
      if (config && config.colorMode !== undefined) {
        this.systemIsDark = (config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
      }
    } catch (e) { /* ignore */ }

    this.loadPreferences()
    // 开屏隐私政策（上架合规）：仅"上架轨"形态（平板 / 2in1）且未同意过时弹窗。
    // 手机（侧载轨）不弹（视使用即同意，见隐私政策正文）。
    if (DistributionPolicy.requiresPrivacyConsent() && !this.getPrefManager_().privacyAgreed) {
      this.showPrivacy = true
    }
    // 启动检查更新：先按缓存即时显示红点（无需联网），再按 24h 节流静默联网刷新。
    this.initUpdateCheck()
    // 启动轻量网络自检：疑似异常时显示顶部横幅（不阻塞、静默）。
    this.initNetworkCheck()
    // 在两处存储根（与隐藏的 .minecraft 同级）写说明 txt，引导用户开启"显示隐藏文件"。
    // 沙箱说明始终写（沙箱必然存在，从"来源"浏览到应用内目录时可见）；外部说明仅在外部激活时写。
    GameStorage.writeSandboxHint(this.context)
    if (this.storageLocation === StorageLocation.EXTERNAL) {
      GameStorage.migrateLegacyExternalFolder()  // 旧 AMCL 文件夹 → 包名（带数据），先于解析/部署
      GameStorage.writeExternalHint()
    }
    this.applyTheme()
    this.themeInitialized = true

    // 设备内存
    try {
      let recommended: number = testNapi.getRecommendedXmx()
      if (recommended > 0) this.mcXmx = recommended
      // 滑块上限 = 设备真实物理内存（对齐 256MB）。允许用户拉满，但 SettingsTab
      // 在超过 80% 时会弹确认框提示进程被杀风险（详见 SettingsTab.onXmxSliderChange）。
      let deviceMb: number = testNapi.getDeviceMemoryMB()
      if (deviceMb > 0) {
        let full = Math.floor(deviceMb / 256) * 256
        if (full > this.xmxSliderMax) this.xmxSliderMax = full
      }
    } catch (e) {
      this.mcXmx = 1024
    }
    // 关键兜底：避免 mcXmx 卡在 0（NAPI 返回 0 不抛错的边缘场景），
    // SettingsTab 的 Slider min=512，0 会让控件渲染异常；C 层 xmxMb=0 也需要自己兜底。
    // 默认 1024 MB 对绝大多数设备是合理保守值。
    if (this.mcXmx < 512) {
      this.mcXmx = 1024
    }

    // 独立游戏进程可能仍在读取 JAR；首页重新建立不能覆盖它使用中的运行时。
    const runtimeReady: Promise<void> = this.deployRuntimeIfIdle_(true);

    // 下载历史沿用现有初始化；其本地数据发布完成后才允许首次显示首页。
    const historyReady: Promise<void> = getDownloadHistoryStore().init(this.context).then(() => {
      this.refreshRecentActivities_()
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'DownloadHistoryStore.init failed', e, LOG_DOMAIN_DOWNLOAD)
    })

    // 消息初始化同样纳入本地就绪条件，避免准备页退出后再集中刷新角标与列表。
    const messagesReady: Promise<void> = getAppMessageStore().init(this.context).then(() => {
      refreshUnreadCount()
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'AppMessageStore.init failed', e, LOG_DOMAIN_UI)
    })

    // Phase 2.3: 元数据 TTL 缓存 — 同步 init 即可（只 mkdir）
    try {
      getMetadataCacheStore().init(this.context)
    } catch (e) {
      AppLogger.warn(TAG, 'MetadataCacheStore.init failed', e, LOG_DOMAIN_DOWNLOAD)
    }

    // JDK
    this.getJdkManager_().setStatusCallback((s: JdkStatus) => {
      this.updateJdkReadyState()
      this.jdkExtractProgress = s.progress
    })
    // v6.5：JDK 下载进度可视化全部迁到 DownloadTasksSheet（JdkInstallTask、Index 不再接管 onDownload）。
    // checkAndExtract 只会用 setStatusCallback 报完成状态，不需要 setDownloadCallback。
    this.getJdkManager_().checkAndExtract()
    // v6.5：registry listener 启动后才能接收 task 事件
    this.registry.addListener(this.registryListener)
    this.jdkVersions = this.getJdkManager_().listVersions()
    this.updateJdkReadyState()

    const versionsReady: Promise<void> = this.scanVersions();

    // 账户探测和本地加载在准备阶段完成；网络登录仍由用户进入账户界面后发起。
    const accountReady: Promise<void> = getAccountManager().init(this.context).then(() => {
      this.refreshCurrentAccount()
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'AccountManager.init failed', e, LOG_DOMAIN_ACCOUNT)
    })

    // 进程恢复owner已经拥有原件、终态提交和历史投影；页面仅消费持久待展示结果。
    // 离页不取消owner，不确认尚未应用的结果。首次首页仍等待本地初始化及这轮展示确认。
    this.consumeLastSession()
    this.launcherStartupJobs_ = [historyReady, messagesReady, accountReady, versionsReady, runtimeReady]
    this.completeLauncherStartup_()
  }

  private consumeLastSession(): void {
    if (this.lastSessionShown || this.recoveringSessions_) return
    this.lastSessionShown = true
    this.recoveringSessions_ = true
    this.sessionRecoveryError_ = null
    const revision: number = this.desktopSessionRevision
    const epoch: number = this.recoveryPresentationEpoch_
    this.sessionRecoveryTask_ = this.consumeRecoveredSessions_(epoch).then((): void => {
      if (revision !== this.desktopSessionRevision || epoch !== this.recoveryPresentationEpoch_) this.lastSessionShown = false
    }).catch((error: Error) => {
      this.lastSessionShown = false
      this.sessionRecoveryError_ = error
      AppLogger.warn(TAG, 'Cannot resolve previous game outcome; evidence retained', error, LOG_DOMAIN_LAUNCH)
    }).finally((): void => {
      this.recoveringSessions_ = false
      if (revision !== this.desktopSessionRevision) this.consumeLastSession()
      // 用户可能在呈现回执落盘前就已关闭Sheet；此时没有第二个onDisappear可唤醒下一项。
      if (this.sessionRecoveryError_ === null) {
        this.resumeRecoveryPresentation_();
        this.drainUpdateDialogs_();
        this.showUpdateRecovery_();
      }
    })
  }

  /** 仅消费进程owner已经耐久提交并投影历史的结果；页面不再裁决/封账或扫描原件。 */
  private async consumeRecoveredSessions_(epoch: number): Promise<void> {
    await SessionRecoveryRuntime.wake(this.context, [], false)
    // 启动仅等待 owner 的耐久恢复/历史投影。展示义务留到首页真实揭示后消费，
    // 不在动画下方打开系统 Sheet，也不等待退场而形成 ready/展示相互等待。
    if (!this.startupFinished_ || this.showPrivacy || this.showMcErrorSheet) {
      this.recoveryPresentationDeferred_ = true;
      return;
    }
    const coordinator = SessionRecoveryRuntime.coordinator(this.context)
    for (const result of await coordinator.results()) {
      if (epoch !== this.recoveryPresentationEpoch_ || AppStorage.get<boolean>('amclHostPageVisible') === false) return
      await this.consumeRecoveredSession_(result, epoch)
      if (epoch !== this.recoveryPresentationEpoch_) return
      await coordinator.acknowledgePresentation(result.session.startedAt, result.revision)
      if (result.outcome.state === LedgerState.CRASHED || result.outcome.state === LedgerState.FAILED) {
        this.recoveryPresentationDeferred_ = true;
        break;
      }
    }
    await SessionRecoveryRuntime.reportSettled(this.context)
  }

  /** 同结果版本只应用一次原错误Sheet和列表刷新，不拥有用户当前Tab的选择权。 */
  private async consumeRecoveredSession_(result: SessionRecoveryResult, epoch: number): Promise<void> {
    const session = result.session; const outcome = result.outcome
    this.lastMcSession = session
    this.refreshRecentActivities_()
    // 旧会话恢复不拥有当前Tab的选择权；用户已切到设置/下载时保持其实际导航，
    // 历史结果和原错误Sheet仍展示、确认，不重启父进程或复用已退出的JVM。
    if (outcome.state === LedgerState.CRASHED || outcome.state === LedgerState.FAILED) {
      // 原入口等待历史就绪后才设置Sheet；必须等真正应用成功，不能把“已发起Promise”当展示完成。
      if (!await this.openErrorSheetBySession_(session.startedAt, epoch)) throw new Error('恢复结果尚未应用到当前页面，展示义务保留');
    }
    await writeSessionRecoveryReceiptAsync(this.context.filesDir, session.startedAt, outcome)
  }

  /**
   * 首次首页等待本地初始化及本页实际消费的必要恢复/展示任务。ended历史迁移单独后台排队，
   * 浏览ready不代表游戏已准入；所有真实新游戏派发仍await owner.trackLaunch的来源保护和发布互斥。
   * 耗时准备已由进程owner
   * 和异步文件边界承接，本页只在它们完成后发布可见事实；事件循环让步用于观察
   * 追加批次，不能当成耗时工作已移出UI线程的证据。失败保留原批次，销毁代次失效。
   */
  private async completeLauncherStartup_(): Promise<void> {
    const attempt: number = ++this.launcherStartupAttempt_
    this.launcherStartupFailed_ = false
    try {
      await Promise.all(this.launcherStartupJobs_)
      while (true) {
        const recovery: Promise<void> = this.sessionRecoveryTask_
        await recovery
        // 最后一段文件/历史回调收尾后让渲染队列获得一轮机会，再检查是否有新批次。
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0) })
        if (attempt !== this.launcherStartupAttempt_) return
        if (recovery !== this.sessionRecoveryTask_) continue
        if (this.sessionRecoveryError_ !== null) throw this.sessionRecoveryError_
        break
      }
      this.launcherStartupReady_ = true
      this.onHomeTabVisibilityChanged_()
      AppLogger.info(TAG, 'Launcher startup ready; local initialization and critical recovery completed; history migration runs separately', LOG_DOMAIN_LAUNCH)
    } catch (error) {
      if (attempt !== this.launcherStartupAttempt_) return
      this.launcherStartupFailed_ = true
      AppLogger.warn(TAG, 'Launcher preparation incomplete; original recovery batch retained', error, LOG_DOMAIN_LAUNCH)
    }
  }

  onPageShow() {
    this.startupRouteVisible_ = true;
    if (!this.launcherInitializationComplete_) return;
    const initialShow: boolean = this.startupInitialPageShow_;
    this.startupInitialPageShow_ = false;
    const channel=this.getPrefManager_().appUpdateChannel
    if(channel!==this.shownAppUpdateChannel) {
      this.shownAppUpdateChannel=channel; this.pendingAppUpdate_=null; this.autoUpdateCheckStarted=false
      this.initUpdateCheck()
    }
    this.updateDot=!DistributionPolicy.isStore() && UpdateChecker.hasCachedUpdate(UpdateChecker.currentVersionCode(),
      this.getPrefManager_().appUpdateLatestSeen(ProductBuildProfile.product,channel),UpdateChecker.currentVersionName(),
      this.getPrefManager_().appUpdateLatestName(ProductBuildProfile.product,channel),channel)
    this.launcherWorkVisible_ = true
    this.onLauncherWorkVisibilityChanged_()
    this.onSideloadTestRequest_()
    // 只消费新进程按版本/UID/载荷/一次性凭据核实后的成功信号，不以旧安装命令返回值报成功。
    if (this.startupFinished_ && AppStorage.get<boolean>('amclSideloadUpdateCompleted') === true) {
      AppStorage.setOrCreate<boolean>('amclSideloadUpdateCompleted', false)
      this.getUIContext().getPromptAction().showToast({ message: 'AMCL 已更新完成' })
    }
    // 本页被覆盖期间（pushUrl 进游戏）本页组件并不销毁，仍会继续跑自己的定时器。
    // 该标志是"看不见就别占 UI 线程"的唯一权威来源，游戏内的鼠标事件与本页共用
    // 同一条 ArkUI 线程，所以这直接关系到键鼠输入延迟。
    AppStorage.setOrCreate('amclHostPageVisible', true)
    this.onHomeTabVisibilityChanged_()
    this.lastSessionShown = false; this.consumeLastSession()
    this.onUpdateRecoveryRequested_()
    if (!initialShow) {
      this.scanVersions();
      this.loadPreferences();
    }
    this.refreshStoreManager_(true)
    this.updateJdkReadyState()
    this.refreshRecentActivities_()  // 从下载页/活动页/游戏页返回时刷新最近活动
    // 账户可能被其他页面改过（未来扩展），重新拉一次
    if (getAccountManager().isReady()) {
      this.refreshCurrentAccount()
    }
    // 冷启动经「打开方式」拉起（EntryAbility.onCreate 已写入 uri）→ 消费并跳到导入流程。
    this.tryConsumeLayoutImport()
    this.onGraphicsRecoverySignal_()
    this.drainUpdateDialogs_()
    this.showUpdateRecovery_()
    // 路由被覆盖时保留的通知不会再次触发 Watch，返回后按真实可见资格补消费。
    if (this.startupFinished_) {
      this.onOpenErrorSheetReq();
      this.onPendingToast();
      this.onOpenNetDiagReq();
      this.onDesktopLaunchError();
      this.onGameLayoutSyncNotice();
    }
  }

  /**
   * 被其他页面覆盖（含 pushUrl 进游戏）时发布不可见，让本页的周期性动画自行停摆。
   * 各子组件订阅可见事实；本页自己拥有的网络观察由同一生命周期收口。
   */
  onPageHide() {
    this.startupRouteVisible_ = false;
    this.errorSheetVisibleKey_ = 0;
    this.errorSheetVisibleEpoch_ = -1;
    this.finishErrorSheetWait_(false);
    if (!this.launcherInitialized_) return;
    this.storeCheckGeneration_++
    this.storeCheckSignature_ = ''
    if (this.storeExportUnsubscribe_ !== null) this.storeExportUnsubscribe_()
    this.storeExportUnsubscribe_ = null
    this.launcherWorkVisible_ = false
    this.onLauncherWorkVisibilityChanged_()
    AppStorage.setOrCreate('amclHostPageVisible', false)
    AppStorage.setOrCreate<boolean>('amclHomeTabVisible', false)
    AppStorage.setOrCreate<boolean>('amclSettingsTabVisible', false)
    this.recoveryPresentationEpoch_++
    this.exitUpdateForRoute_(); setTimeout((): void => { this.exitUpdateForRoute_(); }, 0)
    // 页面后台只发布可见事实；系统设置往返保留原更新席位与本轮许可。
  }

  /** @Watch 回调：app 已在前台时点击 .json（onNewWant 写入 uri）→ 消费。 */
  onPendingLayoutImport(): void {
    this.tryConsumeLayoutImport()
  }

  /** 若有待处理的布局导入 uri：清空并跳转到布局方案页执行导入（分析→检测→导入）。 */
  private tryConsumeLayoutImport(): void {
    if (!this.startupFinished_ || !this.startupRouteVisible_) return;
    const uri = this.pendingLayoutImportUri
    if (!uri || uri.length === 0) return
    // 管理态保留待导入原文，开启调试后才允许进入纯操控配置。
    if (!GameRunAdmission.isAllowed()) return
    // API22+ desktop 不提供触控虚拟布局。module profile 仍是多产品共享时，必须在这里
    // fail closed，避免系统 FileOpen 深链绕过 Settings 的产品入口门。
    if (!ProductInputProfile.supportsTouchLayouts()) return
    setTimeout(() => {
      if (!GameRunAdmission.isAllowed()) return
      this.pendingLayoutImportUri = ''
      try {
        this.getUIContext().getRouter().pushUrl({
          url: 'pages/LayoutListPage',
          params: { importUri: uri }
        })
      } catch (e) {
        AppLogger.warn(TAG, 'route to layout import failed', e, LOG_DOMAIN_UI)
      }
    }, 0)
  }

  /** 从 AccountManager 同步当前账户名 / 类型 / UUID 到 @State，驱动 HomeTab 头部卡片刷新。 */
  private refreshCurrentAccount(): void {
    let acc = getAccountManager().getSelected()
    this.accountUsername = acc.getDisplayName()
    if (acc.type === AccountType.MICROSOFT) {
      this.accountTypeLabel = '微软正版'
    } else if (acc.type === AccountType.AUTHLIB_INJECTOR) {
      this.accountTypeLabel = '第三方皮肤站'
    } else {
      this.accountTypeLabel = '离线账户'
    }
    // UUID 给 HomeTab AccountCard 拼 Crafatar 头像；离线账户 UUID 不一定 36 位，
    // HomeTab.shouldFetchAvatar 内部会按 type + length 校验，这里直接透传即可。
    this.accountUuid = acc.uuid
    this.accountSkinUrl = acc.getSkinUrl() ?? ''
    AppLogger.info(TAG, `refreshCurrentAccount: name=${this.accountUsername} type=${this.accountTypeLabel} uuid=${this.accountUuid} len=${this.accountSkinUrl.length}`, LOG_DOMAIN_ACCOUNT)
  }

  aboutToDisappear() {
    this.startupAlive_ = false;
    this.errorSheetVisibleKey_ = 0;
    this.errorSheetVisibleEpoch_ = -1;
    this.versionScanEpoch_++;
    this.finishErrorSheetWait_(false);
    // 旧设置子组件的返回闭包不跨启动器实例存活。
    this.settingsSectionBack_ = undefined
    this.storeCheckGeneration_++
    if (this.storeExportUnsubscribe_ !== null) this.storeExportUnsubscribe_()
    this.storeExportUnsubscribe_ = null
    this.launcherWorkVisible_ = false
    this.onLauncherWorkVisibilityChanged_()
    // 只取消本组件发布就绪状态的资格；正在执行的耐久恢复仍按原契约完成并保留证据。
    this.launcherStartupAttempt_++
    this.recoveryPresentationEpoch_++
    AppStorage.setOrCreate<boolean>('amclHomeTabVisible', false)
    AppStorage.setOrCreate<boolean>('amclSettingsTabVisible', false)
    if (UpdatePromptPresenter.owns(this.updatePresenterOwner)) this.exitPresentedUpdate()
    this.closeUpdateDialog_()
    UpdatePromptPresenter.forget(this.updatePresenterOwner)
    if (this.landscapeListener) {
      this.landscapeListener.off('change')
    }
    if (this.launcherWindow_ !== null) {
      try {
        this.launcherWindow_.off('windowSizeChange', this.launcherWindowSizeListener_)
      } catch (e) { /* 窗口已销毁时无需继续清理 */ }
      this.launcherWindow_ = null
    }
    if (this.rootViewportUpdateTimer_ >= 0) {
      clearTimeout(this.rootViewportUpdateTimer_)
      this.rootViewportUpdateTimer_ = -1
    }
    this.registry.removeListener(this.registryListener)
  }

  onColorModeChange(): void {
    if (!this.themeInitialized) return
    this.systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    if (this.themeMode === ThemeMode.SYSTEM) {
      this.applyTheme()
    }
  }

  // ==================== 偏好与状态管理 ====================

  private applyTheme() {
    this.theme = resolveTheme(this.themeMode, this.systemIsDark)
    // 让 App 全局 colorMode 跟随【App 内选的主题】（而非死跟系统）。这样 HdsTabs 悬浮 dock 的
    // 底部沉浸渐变(gradientMask)用 App 主题色渲染、与内容融为一体——主题不一致时不再显出对比色带，
    // 同时保留 dock 的沉浸光感（不像删 gradientMask 那样把沉浸效果一起去掉）。
    try {
      let cm = this.themeMode === ThemeMode.DARK ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : this.themeMode === ThemeMode.LIGHT ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
      if (cm !== this.lastAppliedColorMode_) {
        this.lastAppliedColorMode_ = cm
        let appCtx = (this.context as common.UIAbilityContext).getApplicationContext()
        appCtx.setColorMode(cm)
      }
    } catch (e) { /* setColorMode 失败不阻断主题应用 */ }
    try {
      const isDark: boolean = resolveIsDark(this.themeMode, this.systemIsDark)
      const win: window.Window | undefined =
        (this.context as common.UIAbilityContext).windowStage?.getMainWindowSync()
      if (win) {
        ProductLauncherWindowChrome.applyTheme(win, isDark).catch((_e: Error) => {})
      }
    } catch (e) { /* ignore */ }
  }

  /** 隐私政策：同意 → 落盘 + 关闭弹窗。 */
  private onPrivacyAgree(): void {
    this.getPrefManager_().privacyAgreed = true
    this.showPrivacy = false
    this.resumeRecoveryPresentation_();
    this.onOpenErrorSheetReq();
    this.initRuntimeUpdateCheck_()
  }

  /** 隐私政策：不同意 → 退出应用。 */
  private onPrivacyDisagree(): void {
    try {
      (this.context as common.UIAbilityContext).terminateSelf()
    } catch (e) {
      AppLogger.warn(TAG, 'terminateSelf failed', e, LOG_DOMAIN_UI)
    }
  }

  private loadPreferences() {
    this.canRunGame_ = GameRunAdmission.isAllowed()
    if (!this.canRunGame_) this.showPreLaunchSheet = false
    let snap = this.getPrefManager_().loadAll()
    this.themeMode = snap.themeMode
    // 新记录缺失才迁移旧五档；在途保存由同目录读取屏障保证不会发布缓存中间态。
    this.immersiveLight = this.getPrefManager_().immersiveLightPreferences
    publishImmersiveLightPreferences(this.immersiveLight)
    this.mcVersion = snap.mcVersion
    // 历史 useNewWindow 不再参与进程选择；新设置独立存储，由 RuntimeProductProfile 冷启动锁存。
    this.useNewWindow = false
    this.tabletIndependentGameProcess = ProductInputProfile.canChooseTabletProcess()
      ? this.getPrefManager_().tabletIndependentGameProcess : false
    this.versionIsolation = snap.versionIsolation
    this.selectedJdkVersion = snap.jdkVersion
    if (snap.mcXmx > 0) this.mcXmx = snap.mcXmx
    this.modSource = this.getPrefManager_().modSource
    this.cacheRemoteMeta = this.getPrefManager_().cacheRemoteMeta
    this.modConcurrentDownloads = this.getPrefManager_().modConcurrentDownloads
    // 加速下载：读盘后若为开则后台握手（不阻塞启动；失败静默回退直连）
    this.accelDownload = DistributionPolicy.allowPublisherServices() && this.getPrefManager_().accelDownload
    if (this.accelDownload) {
      this.initRelay_()
    }
    // JDK 下载源偏好：读盘 + 注入到 launch 模块级全局（JdkInstaller 下载时读取）
    this.jdkSource = this.getPrefManager_().jdkSource
    this.jdkChannel = this.getPrefManager_().jdkChannel
    this.jdkWebEnabled = this.getPrefManager_().jdkWebEnabled
    this.jdkAutoCheck = this.getPrefManager_().jdkAutoCheck
    setJdkWebEnabled(this.jdkWebEnabled)
    setJdkDownloadSource(this.jdkSource)
    RuntimeCatalogRepository.instance(this.context).configure(this.jdkChannel,this.jdkSource,this.jdkWebEnabled)
      .then((): void => { this.updateJdkReadyState(); this.initRuntimeUpdateCheck_(); })
      .catch((e: Error): void => { this.jdkCatalogStatus = '目录加载失败：' + e.message; })
    // MC 版本下载源偏好：读盘 + 注入 feature_core 模块级全局（McDownloader 的
    // buildSortedUrls 会读它）。必须在任何下载发起之前注入，否则第一次下载仍按默认走。
    this.mcSource = this.getPrefManager_().mcSource
    setMcSourcePreference(this.mcSource)
    this.virtualMemoryMode = this.getPrefManager_().virtualMemoryMode
    this.gameLanguage = this.getPrefManager_().gameLanguage
    this.ohosFrameRateCap = this.getPrefManager_().ohosFrameRateCap
    this.lastPlayedAt = this.getPrefManager_().lastPlayedAt

    // 存储位置：偏好选了外部,但本设备不可用 / 平板权限被回收 → 本会话回落沙箱(留 pref,
    // 重新就绪后自动恢复)。设备差异：平板需 READ_WRITE_DOWNLOAD_DIRECTORY 仍在授权；
    // 手机靠 GameStorage 启动期注入的缓存路径，isExternalAvailable() 已能反映是否就绪。
    let locPref = parseStorageLocation(this.getPrefManager_().mcStorageLocation)
    let tabletPermMissing = GameStorage.isTabletSilent() && !GameStorage.isDownloadPermissionGranted(this.context)
    if (locPref === StorageLocation.EXTERNAL
        && (!GameStorage.isExternalAvailable() || tabletPermMissing)) {
      AppLogger.warn(TAG, 'External storage selected but unavailable/permission missing; using sandbox this session', null, LOG_DOMAIN_LAUNCH)
      this.storageLocation = StorageLocation.SANDBOX
    } else {
      this.storageLocation = locPref
    }

    // 新窗口模式已停用：历史偏好若仍为开启，落盘退回 false（只在首次命中时写一次，后续 load 不再触发）。
    if (snap.useNewWindow) {
      this.savePreferences()
    }
  }

  /**
   * 当前激活的 .minecraft 根（沙箱 filesDir/.minecraft 或外部 Download/com.amcl.launcher/.minecraft）。
   * 全页所有 .minecraft 路径的唯一来源。storageLocation 变化时 @State 触发 build → 各处自动更新。
   */
  private mcRoot(): string {
    return GameStorage.resolveMcDir(this.context, this.storageLocation)
  }

  // ==================== 存储位置切换 ====================

  private toast_(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2200 })
    } catch (e) { /* UI 实例已销毁，忽略 */ }
    this.statusMsg = msg
  }

  /**
   * 用户在设置里切换"游戏数据位置"。切到外部时按设备准备外部根（平板申请权限 / 手机 picker 学路径），
   * 准备好后两端复用同一套"询问迁移 → 落盘 → 重部署 → 重扫"。任一步失败都不破坏现状（保持原位置 + Toast）。
   */
  private handleStorageLocationChange(loc: string): void {
    let target = parseStorageLocation(loc)
    if (target === this.storageLocation) return

    if (target === StorageLocation.SANDBOX) {
      this.promptSwitchStorage(StorageLocation.SANDBOX)  // 沙箱永远可用
      return
    }

    // target === EXTERNAL：按设备能力准备"外部根"
    if (GameStorage.isTabletSilent()) {
      // 平板/2in1：申请 READ_WRITE_DOWNLOAD_DIRECTORY，走 Environment 路线
      if (!GameStorage.isExternalAvailable()) {
        this.toast_('本设备不支持外部存储（取不到 Download 目录）')
        return
      }
      GameStorage.requestDownloadPermission(this.context).then((granted: boolean) => {
        if (!granted) {
          this.toast_('未授予下载目录权限，已保持沙箱存储')
          return
        }
        // 授权后：旧 AMCL 文件夹改名为包名（带数据），再写"开启显示隐藏文件"说明 txt
        GameStorage.migrateLegacyExternalFolder()
        GameStorage.writeExternalHint()
        this.promptSwitchStorage(StorageLocation.EXTERNAL)
      }).catch((e: Error) => {
        AppLogger.warn(TAG, 'requestDownloadPermission failed', e, LOG_DOMAIN_LAUNCH)
        this.toast_('权限申请失败：' + e.message)
      })
    } else {
      // 手机：DocumentViewPicker DOWNLOAD 模式（无弹窗）学一次公共目录路径，无需权限弹窗 / persist / activate
      GameStorage.ensurePhoneExternalDir(this.context, this.getPrefManager_()).then((dir: string) => {
        if (dir.length === 0) {
          this.toast_('未获取到下载目录，已保持沙箱存储')
          return
        }
        GameStorage.writeExternalHint()
        this.promptSwitchStorage(StorageLocation.EXTERNAL)
      }).catch((e: Error) => {
        AppLogger.warn(TAG, 'ensurePhoneExternalDir failed', e, LOG_DOMAIN_LAUNCH)
        this.toast_('获取下载目录失败：' + e.message)
      })
    }
  }

  /** 切换前询问是否迁移已有数据；源无版本数据时直接切换。 */
  private promptSwitchStorage(target: StorageLocation): void {
    let from = this.mcRoot()
    if (!GameStorage.hasVersions(from)) {
      this.applyStorageSwitch(target, false)
      return
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '切换游戏数据位置',
        message: '当前位置已有游戏数据（版本/存档/模组）。\n\n'
          + '· 迁移数据：复制全部数据到新位置（版本多时可能较大、耗时；旧数据仍保留）。\n'
          + '· 仅切换：新位置从空白开始，旧数据留在原位置。',
        buttons: [
          { text: '仅切换', color: this.theme.primary as string },
          { text: '迁移数据', color: this.theme.error as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        this.applyStorageSwitch(target, res.index === 1)
      }).catch(() => { /* 点框外 = 取消 */ })
    } catch (e) {
      this.applyStorageSwitch(target, false)
    }
  }

  /**
   * 首页与存储切换共用的运行时部署入口。已有游戏持有 OS 锁、或无法核验锁时，
   * 推迟部署并记录原因，绝不把只读失败解释成空闲。完整匹配槽由部署器只读复用。
   * 这不是完整跨进程部署租约：本批只防止已运行的游戏被首页重建覆盖，后续事务另验。
   */
  private async deployRuntimeIfIdle_(startup: boolean = false): Promise<void> {
    try {
      const state: number = testNapi.desktopGameProcessState(this.context.filesDir, 0)
      if (state !== 0) {
        AppLogger.warn(TAG, 'Runtime deployment deferred: active game or unknown process state=' + state,
          undefined, LOG_DOMAIN_LAUNCH)
        return
      }
      // 只有开屏入口采用异步准备并由 startupJobs 封住输入。存储切换仍在同一
      // UI 调用内同步完成旧部署契约，不能因 await 引入用户提前启动的窗口。
      if (startup) await new RuntimeDeployer(this.context).deployAllForStartup(this.mcRoot());
      else new RuntimeDeployer(this.context).deployAll(this.mcRoot());
    } catch (e) {
      AppLogger.warn(TAG, 'Runtime deployment deferred: process check or deployment failed', e, LOG_DOMAIN_LAUNCH)
    }
  }

  /** 真正执行切换。migrate=true 时先把当前根的数据复制到目标根。 */
  private applyStorageSwitch(target: StorageLocation, migrate: boolean): void {
    let from = GameStorage.resolveMcDir(this.context, this.storageLocation)
    let to = GameStorage.resolveMcDir(this.context, target)

    let commit = (): void => {
      this.getPrefManager_().mcStorageLocation = target
      this.storageLocation = target
      // 私有游戏进程仍活跃时推迟部署；不能因切换首页路径改写正在使用的运行时。
      this.deployRuntimeIfIdle_()
      this.scanVersions()
      this.updateJdkReadyState()
      this.toast_('已切换到' + (target === StorageLocation.EXTERNAL ? '外部存储 (Download/AMCL)' : '沙箱存储'))
    }

    if (migrate) {
      this.toast_('正在迁移游戏数据，请稍候...')
      let migStartedAt = Date.now()
      let migLabel = (this.storageLocation === StorageLocation.EXTERNAL ? '外部' : '沙箱')
        + ' → ' + (target === StorageLocation.EXTERNAL ? '外部' : '沙箱')
      this.beginActivity_(ActivityCategory.STORAGE, '存储迁移', migStartedAt)
      GameStorage.migrate(from, to).then(() => {
        this.toast_('数据迁移完成')
        this.addActivity_(ActivityCategory.STORAGE, '存储迁移', ActivityStatus.SUCCESS, migStartedAt, migLabel, '')
        commit()
      }).catch((e: Error) => {
        AppLogger.error(TAG, 'migrate failed', e, LOG_DOMAIN_LAUNCH)
        this.toast_('迁移失败：' + e.message + '（已保持原位置）')
        this.addActivity_(ActivityCategory.STORAGE, '存储迁移', ActivityStatus.FAILED, migStartedAt, migLabel, e.message)
      })
    } else {
      commit()
    }
  }

  /** 只消费当前设置二级分区的系统返回，不改变首页或其他路由的退出语义。 */
  onBackPress(): boolean {
    if (this.currentTab !== 2 || this.settingsSectionBack_ === undefined) return false
    try { return this.settingsSectionBack_() }
    catch (error) { AppLogger.warn(TAG, '设置分区返回暂不可用', error, LOG_DOMAIN_UI); return false }
  }

  /** 只允许一个设置写入在途；失败重新发布已确认副本，复位原生开关的内部状态。 */
  private async changeImmersiveLight_(next: ImmersiveLightPreferences): Promise<void> {
    if (this.immersiveLightSaving) return
    this.immersiveLightSaving = true
    this.immersiveLightSaveError = ''
    try {
      await this.getPrefManager_().saveImmersiveLightPreferences(next)
      this.immersiveLight = this.getPrefManager_().immersiveLightPreferences
      publishImmersiveLightPreferences(this.immersiveLight)
    } catch (error) {
      this.immersiveLight = copyImmersiveLightPreferences(this.getPrefManager_().immersiveLightPreferences)
      this.immersiveLightSaveError = '保存失败，请重试：' + formatError(error)
      AppLogger.warn(TAG, '沉浸光感保存失败', error, LOG_DOMAIN_UI)
    } finally {
      this.immersiveLightSaving = false
    }
  }

  private savePreferences() {
    this.getPrefManager_().saveAll({
      themeMode: this.themeMode,
      mcVersion: this.mcVersion,
      useNewWindow: this.useNewWindow,
      versionIsolation: this.versionIsolation,
      mcXmx: this.mcXmx,
      jdkVersion: this.selectedJdkVersion,
    })
  }

  private updateJdkReadyState() {
    let validVersions: string[] = []
    let versions = this.getJdkManager_().listVersions()
    for (let v of versions) validVersions.push(v.version)
    // 只迁移无效槽位语法。离线/下架/新增版本都不能悄悄覆盖用户保存的选择。
    if (this.selectedJdkVersion !== JDK_AUTO &&
        !isJdkSlotVersion(this.selectedJdkVersion)) {
      AppLogger.warn(TAG, `Force selected JDK ${this.selectedJdkVersion} -> ${JDK_AUTO} (not a known version)`, null, LOG_DOMAIN_LAUNCH)
      this.selectedJdkVersion = JDK_AUTO
      this.savePreferences()
    }
    // jdkReady = 当前 MC 版本【实际生效】的 JDK 是否已安装（单版本覆盖 > 全局 hint > 纪元路由）。
    // 复用 LaunchCoordinator.resolveJdk，与真正启动时的路由一致，避免就绪态与实际不符。
    let pvJdk = this.getPrefManager_().getVersionOverride(this.mcVersion).jdkVersion
    let effJdk = this.getLaunchCoordinator_().resolveJdk(
      this.mcVersion, this.mcRoot(), pvJdk, this.selectedJdkVersion)
    this.jdkReady = this.getJdkManager_().isInstalled(effJdk)
    this.effectiveJdkVersion = effJdk
    this.jdkVersions = versions
    this.jdkHasUpdate = versions.some((version: JdkVersionInfo): boolean => version.updateAvailable && !version.userImported)
  }

  /**
   * 设备已安装的 JDK 大版本集合（如 [17, 25]），供 VersionConfigPanel 做 Forge/NeoForge
   * 安装器 JDK 的自动匹配与「需安装 JDK X」选择时提示。从 jdkManager.listVersions() 过滤已装。
   */
  private installedJdkMajors_(): number[] {
    let out: number[] = []
    for (let v of this.getJdkManager_().listVersions()) {
      if (!v.installed) continue
      let n = parseInt(v.version, 10)
      if (!isNaN(n)) out.push(n)
    }
    return out
  }

  private async scanVersions(): Promise<void> {
    const epoch: number = ++this.versionScanEpoch_;
    this.versionScanPending_ = true;
    this.storeScanError_ = ''
    // 版本集合可能变化（新装/删除/重命名整合包等）→ 清 loader 解析缓存，避免读到旧结果
    invalidateInstalledLoaderCache()
    let versionsDir = this.mcRoot() + '/versions'
    let versions: string[] = []
    let orphans: string[] = []
    let mtimes = new Map<string, number>()   // 版本目录名 → mtime（秒），用于"最新下载在上"默认排序
    try {
      let entries = await fs.listFile(versionsDir)
      for (let name of entries) {
        if (name === 'download-temp' || name.startsWith('.')) continue
        let dirPath = versionsDir + '/' + name
        try {
          let dirStat = await fs.stat(dirPath)
          if (!dirStat.isDirectory()) continue
          mtimes.set(name, dirStat.mtime)
        } catch (e) {
          if ((e as BusinessError).code !== 13900002) this.storeScanError_ = (e as Error).message
          continue
        }

        // 判定规则 (2026-05-05 加强): 一个版本"真已安装" 当且仅当 同时满足:
        //   1. <id>.jar 存在且 > 1 MB
        //   2. <id>.json 存在且是合法 JSON, 且含 id 字段 + (mainClass 或 inheritsFrom)
        // 任一不满足 → orphan. 这样能识别出旧 DownloadTask bug 产生的
        // versions/<gameVersion>/<gameVersion>.jar (只有 vanilla jar 没有完整启动 JSON) 这种"假原版"残留.
        let jarPath = dirPath + '/' + name + '.jar'
        let jsonPath = dirPath + '/' + name + '.json'
        let jarOk = false
        try {
          let stat = await fs.stat(jarPath)
          jarOk = stat.size > 1024 * 1024
        } catch (e) { /* jar missing */ }

        let jsonOk = false
        if (jarOk) {
          try {
            let jsonText = await fs.readText(jsonPath)
            let obj = JSON.parse(jsonText) as Record<string, Object>
            let hasId = obj['id'] !== undefined && obj['id'] !== null
            let hasMainClass = obj['mainClass'] !== undefined && obj['mainClass'] !== null
            let hasInheritsFrom = obj['inheritsFrom'] !== undefined && obj['inheritsFrom'] !== null
            jsonOk = hasId && (hasMainClass || hasInheritsFrom)
          } catch (e) { /* json missing or malformed */ }
        }

        if (jarOk && jsonOk) {
          versions.push(name)
        } else {
          orphans.push(name)
        }
      }
    } catch (e) {
      if ((e as BusinessError).code !== 13900002) this.storeScanError_ = (e as Error).message
    }
    if (!this.startupAlive_ || epoch !== this.versionScanEpoch_ || versionsDir !== this.mcRoot() + '/versions') {
      if (epoch === this.versionScanEpoch_) this.versionScanPending_ = false;
      return;
    }
    const previousVersion: string = this.mcVersion;
    // 排序：用户拖拽自定义顺序优先；新下载（未在自定义顺序里）按 mtime 倒序排在最上面。
    this.availableVersions = mergeVersionOrder(versions, mtimes, this.getPrefManager_().versionOrder)
    this.orphanVersionDirs = orphans
    if (this.availableVersions.length > 0 && this.availableVersions.indexOf(this.mcVersion) < 0) {
      this.mcVersion = this.availableVersions[0]
    } else if (DistributionPolicy.isStore() && this.availableVersions.length === 0 && orphans.length > 0 && !orphans.includes(this.mcVersion)) {
      this.mcVersion = orphans[0]
    }
    this.versionScanPending_ = false;
    this.updateJdkReadyState();
    if (previousVersion !== this.mcVersion) this.savePreferences();
    this.scanInstalledModsCount()
    this.refreshStoreManager_()
  }

  /** 管理态仅消费异步真实核验；代次和源身份绑定，旧响应不能把切换后的版本标为完整。 */
  private forceStoreSourceRecheck_(): void {
    if (!DistributionPolicy.isStore()) return
    // 文件内容变化不一定改变版本ID库存。先撤销旧资格；隐藏页不启动检查，返回时再核验。
    this.storeCheckSignature_ = ''
    this.storeReadyVersions_ = []
    if (!this.launcherWorkVisible_) { this.storeCheckGeneration_++; return }
    this.refreshStoreManager_(true)
  }

  /** 文件浏览器及资源面板共用这一真实回调，不额外重扫版本目录或复制修改源文件。 */
  private onVersionFilesChanged_(): void {
    this.scanInstalledModsCount()
    this.forceStoreSourceRecheck_()
  }

  private selectManagedVersion_(version: string): void {
    this.mcVersion = version
    this.savePreferences()
    this.scanInstalledModsCount()
    this.forceStoreSourceRecheck_()
  }

  private changeManagedIsolation_(enabled: boolean): void {
    this.versionIsolation = enabled
    this.savePreferences()
    this.forceStoreSourceRecheck_()
  }

  /**
   * 可见首页在所有产品订阅进程内导出通知。内嵌Sheet关闭不会触发onPageShow，
   * 因此终态及历史add耐久完成后的稳定通知都须重新投影LRU；每个字节的活动进度
   * 只读取内存任务，不读历史、不盘点源。store额外消费原有管理行动，其余产品不进入源扫描。
   * 注册幂等，生命周期继续由既有onPageHide/aboutToDisappear解除，不创建第二套监听或轮询。
   */
  private observeExportActivities_(): void {
    if (!this.launcherWorkVisible_ || this.storeExportUnsubscribe_ !== null) return
    this.storeExportUnsubscribe_ = getGameExportCoordinator().subscribe((): void => {
      if (!this.launcherWorkVisible_) return
      const task = getGameExportCoordinator().getTask()
      if (task !== null && (task.state === 'succeeded' || task.state === 'failed' || task.state === 'cancelled')) {
        this.refreshRecentActivities_()
      }
      if (DistributionPolicy.isStore()) this.refreshStoreManager_()
    })
  }

  private refreshStoreManager_(force: boolean = false): void {
    // 挂载首页共用的轻量订阅后才判断store策略，default仍在下方guard返回，不做源检查。
    this.observeExportActivities_()
    if (!DistributionPolicy.isStore() || !this.launcherWorkVisible_) return
    const root: string = this.mcRoot()
    const version: string = this.mcVersion
    const tasks = this.registry.listAll()
    const task = getGameExportCoordinator().getTask()
    const exporting: boolean = task !== null && (task.state === 'running' || task.state === 'cancelling')
    let session = false
    let unknownSession = false
    try {
      const remote: number = testNapi.desktopGameProcessState(this.context.filesDir, 0)
      session = testNapi.mcIsRunning() || remote === 1
      unknownSession = remote < 0
    } catch (_) { unknownSession = true }
    this.storeHasSession_ = session
    const busy: boolean = session || unknownSession || tasks.some((view): boolean => !isTerminalState(view.state))
    if (exporting) {
      this.storeCheckGeneration_++
      this.storeCheckSignature_ = ''
      this.storeManagerAction_ = 'progress'
      this.storeManagerStatus_ = '导出任务进行中，点击查看进度。'
      return
    }
    if (this.storeScanError_.length > 0) {
      this.storeCheckGeneration_++
      this.storeCheckSignature_ = ''
      this.storeReadyVersions_ = []
      this.storeManagerAction_ = 'storage'
      this.storeManagerStatus_ = '无法读取游戏目录：' + this.storeScanError_
      return
    }
    if (busy) {
      this.storeCheckGeneration_++
      this.storeCheckSignature_ = ''
      this.storeReadyVersions_ = []
      this.storeManagerAction_ = session ? 'session' : unknownSession ? 'check' : 'downloads'
      this.storeManagerStatus_ = session ? '已有游戏运行；返回游戏退出后重新检查并导出。' : unknownSession ? '暂时无法确认游戏空闲，请稍后重新检查。' : '下载或资源任务尚未结束，请先处理任务。'
      return
    }
    const candidates: string[] = this.availableVersions.concat(this.orphanVersionDirs)
    const signature: string = root + '\n' + version + '\n' + String(this.versionIsolation) + '\n' + candidates.join('\n')
      + '\n' + tasks.map((view): string => view.id + ':' + view.state).join('|')
    if (!force && signature === this.storeCheckSignature_) return
    this.storeCheckSignature_ = signature
    const generation: number = ++this.storeCheckGeneration_
    this.storeReadyVersions_ = []
    this.storeManagerAction_ = candidates.length > 0 ? 'checking' : 'download'
    this.storeManagerStatus_ = candidates.length > 0 ? '正在核验游戏文件；无需登录或安装运行时。' : '下载游戏版本后，可管理文件并导出到电脑。'
    if (candidates.length === 0) return
    const ordered: string[] = candidates.includes(version) ? [version].concat(candidates.filter((id: string): boolean => id !== version)) : candidates
    this.checkStoreVersions_(root, version, ordered, generation)
  }

  private async checkStoreVersions_(root: string, selected: string, candidates: string[], generation: number): Promise<void> {
    const ready: string[] = []
    let selectedIssue = ''
    let selectedMissing = false
    for (const version of candidates) {
      if (generation !== this.storeCheckGeneration_) return
      try {
        const source = await getGameExportCoordinator().inspectSource(root, version, this.versionIsolation)
        // 标准包只核源就绪；Windows完整包补依赖和接收端限制留给用户选择后的导出向导。
        source.request.format = 'modrinth'
        source.request.launcher = 'hmcl'
        const preview = await getGameExportCoordinator().checkPlan(source.request, false)
        const errors = preview.issues.filter((issue): boolean => issue.severity === 'error')
        if (errors.length === 0) ready.push(version)
        else if (version === selected) {
          selectedIssue = errors[0].message
          selectedMissing = errors.some((issue): boolean => issue.code === 'SOURCE_FILE_INVALID')
        }
      } catch (error) {
        if (version === selected) {
          selectedIssue = (error as Error).message
          selectedMissing = (error as BusinessError).code === 13900002
        }
      }
      if (generation !== this.storeCheckGeneration_ || root !== this.mcRoot() || selected !== this.mcVersion) return
      this.storeReadyVersions_ = ready.slice()
      this.storeManagerAction_ = storeManagerAction({ checking: true, currentReady: ready.includes(selected),
        otherReady: ready.length > 0, hasCandidates: true, busy: false, failed: false, exporting: false })
      if (ready.includes(selected)) {
        this.storeManagerStatus_ = '版本文件核验通过，可选择完整包或标准整合包。'
        return
      }
      if (ready.length > 0) {
        this.storeManagerStatus_ = '当前版本尚未就绪，可选择其他已核验版本。'
        return
      }
    }
    if (generation !== this.storeCheckGeneration_) return
    this.storeManagerAction_ = storeManagerAction({ checking: false, currentReady: ready.includes(selected),
      otherReady: ready.length > 0, hasCandidates: true, busy: false, failed: selectedMissing, exporting: false })
    this.storeManagerStatus_ = ready.includes(selected) ? '版本文件核验通过，可选择完整包或标准整合包。' : ready.length > 0 ? '当前版本尚未就绪，可选择其他已核验版本。' : selectedIssue || '请选择版本并检查必需文件。'
  }

  private async openStoreExport_(version: string, taskId: string = ''): Promise<void> {
    try {
      const task = taskId.length > 0 ? getGameExportCoordinator().getTask() : null
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/GameExportPage', params: {
        'mcRoot': task?.request.mcRoot ?? this.mcRoot(), 'versionId': task?.request.versionId ?? version,
        'versionIsolation': this.versionIsolation, 'taskId': taskId } })
    } catch (error) { this.safeToast_('无法打开导出：' + (error as Error).message) }
  }

  private handleStoreManagerAction_(): void {
    try {
    if (this.storeManagerAction_ === 'progress') {
      const task = getGameExportCoordinator().getTask()
      if (task !== null) this.openStoreExport_(task.request.versionId, task.id)
    } else if (this.storeManagerAction_ === 'export') this.openStoreExport_(this.mcVersion)
    else if (this.storeManagerAction_ === 'choose') {
      const choices: string[] = this.storeReadyVersions_.slice(0, 6)
      if (choices.length === 0) { this.refreshStoreManager_(true); return }
      const buttons: [promptAction.Button, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?, promptAction.Button?] = [
        { text: choices[0], color: this.theme.primary as string } ]
      for (let index = 1; index < choices.length; index++) buttons.push({ text: choices[index], color: this.theme.primary as string })
      this.getUIContext().getPromptAction().showActionMenu({ title: '选择可导出的版本',
        buttons: buttons })
        .then((result): void => {
          const version: string = choices[result.index]
          if (version) { this.mcVersion = version; this.savePreferences(); this.refreshStoreManager_(true) }
        }).catch((): void => {})
    } else if (this.storeManagerAction_ === 'session') this.returnExistingGame_()
    else if (this.storeManagerAction_ === 'downloads') this.showTasksSheet = true
    else if (this.storeManagerAction_ === 'repair') {
      const version: string = this.mcVersion
      this.getUIContext().getPromptAction().showActionMenu({ title: '版本文件需要补全', buttons: [
        { text: '查看版本与文件', color: this.theme.primary as string }, { text: '补全当前版本文件', color: this.theme.primary as string } ] }).then((result): void => {
          if (result.index === 1) this.repairVersionFiles(version)
          else { this.versionManagerInitialStep = 'list'; this.showVersionManager = true }
        }).catch((): void => {})
    } else if (this.storeManagerAction_ === 'check') this.refreshStoreManager_(true)
    else if (this.storeManagerAction_ === 'storage') { this.tabController.changeIndex(2); this.currentTab = 2 }
    else if (this.storeManagerAction_ === 'download') this.jumpToDownloadSub(0)
    } catch (error) { this.safeToast_('无法打开管理操作：' + (error as Error).message) }
  }

  /** 既有Host可重新挂接；不能为了“返回”创建新的Host/JVM，真实新派发仍由服务收口。 */
  private async returnExistingGame_(): Promise<void> {
    try {
      if (getGameSessionHost().isRunning()) {
        await this.getUIContext().getRouter().pushUrl({ url: 'pages/McGamePage' })
      } else if (testNapi.desktopGameProcessState(this.context.filesDir, 0) === 1) {
        await this.context.startAbility({ bundleName: 'com.amcl.launcher', abilityName: 'GameAbility' })
      } else { this.safeToast_('原游戏会话已结束'); this.refreshStoreManager_(true) }
    } catch (error) { this.safeToast_('无法返回游戏：' + (error as Error).message) }
  }

  /**
   * 合并"用户自定义拖拽顺序"与磁盘实际版本，产出版本列表显示顺序。
   * 纯排序逻辑已下沉到 feature_core 的 mergeVersionOrder（三层架构第4步）；本页只负责取
   * prefManager.versionOrder 传入并落 @State。
   */

  /** 用户在版本列表拖拽排序后：持久化新顺序并即时应用到 availableVersions。 */
  private onReorderVersions(newOrder: string[]) {
    // 只保留当前确实存在的版本（防御：传入脏数据）
    let cleaned: string[] = []
    for (let v of newOrder) {
      if (this.availableVersions.indexOf(v) >= 0 && cleaned.indexOf(v) < 0) cleaned.push(v)
    }
    // 补回任何遗漏的现存版本（理论上不会发生）
    for (let v of this.availableVersions) {
      if (cleaned.indexOf(v) < 0) cleaned.push(v)
    }
    this.getPrefManager_().versionOrder = cleaned
    this.availableVersions = cleaned
  }

  /**
   * 扫描当前选中版本的 mods/ 目录，仅取文件总数（含 .jar / .jar.disabled）。
   *
   * 跟 LocalModScanner 不同：
   *   - 不算 sha1，不调 Modrinth 反查 — 这里只为 HomeTab Quick Stats 的"已装模组"
   *     卡片提供一个数字，需要极快返回（每次 onPageShow / scanVersions 都要重算）。
   *   - 不读文件大小，不打开 jar — 单次磁盘 listFile + 字符串后缀判断即可。
   *
   * 实现走 utils/FileUtils.countFilesWithExtensions，与 VersionManagerSheet 详情资源格
   * 共用同一份扫描逻辑，避免两处统计结果不一致。
   *
   * 失败语义：目录不存在 / 权限错误 → 0；不抛异常。
   */
  private scanInstalledModsCount(): void {
    if (this.mcVersion.length === 0) {
      this.installedModsCount = 0
      return
    }
    let mcDir = this.mcRoot()
    let dir = resolveInstanceGameDir(mcDir, this.mcVersion, this.versionIsolation) + '/mods'
    this.installedModsCount = countFilesWithExtensions(dir, ['.jar', '.jar.disabled'])
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, 'INDEX',
      'scanInstalledModsCount ver=%{public}s dir=%{public}s count=%{public}d',
      this.mcVersion, dir, this.installedModsCount)
  }

  private detectVersionType(versionId: string): string {
    // 整合包/重命名版本名无 loader 关键字，读 version.json 内容判定（名字判得出时零 IO）。
    return resolveInstalledLoaderInfo(this.mcRoot(), versionId).displayName
  }

  @State pendingDeleteVersion: string = ''
  @State showDeleteConfirm: boolean = false

  private confirmDeleteVersion(version: string) {
    this.pendingDeleteVersion = version
    this.showDeleteConfirm = true
  }

  private async executeDeleteVersion(): Promise<void> {
    let version = this.pendingDeleteVersion
    if (!version) return
    let versionDir = this.mcRoot() + '/versions/' + version
    let delStartedAt = Date.now()
    this.beginActivity_(ActivityCategory.VERSION_MANAGE, version, delStartedAt, version)
    try {
      removeDirRecursive(versionDir)
      this.statusMsg = version + ' 已删除'
      this.addActivity_(ActivityCategory.VERSION_MANAGE, version, ActivityStatus.SUCCESS, delStartedAt, '删除版本', '')
    } catch (e) {
      this.statusMsg = '删除失败: ' + (e as Error).message
      this.addActivity_(ActivityCategory.VERSION_MANAGE, version, ActivityStatus.FAILED, delStartedAt, '删除版本', (e as Error).message)
    }
    this.pendingDeleteVersion = ''
    this.showDeleteConfirm = false
    await this.scanVersions()
    this.savePreferences()
  }

  private deleteInstalledVersion(version: string) {
    this.confirmDeleteVersion(version)
  }

  /**
   * 打开"版本管理 Sheet"并直达资源管理步（同 sheet 第三步），目标版本 + 资源类型显式传入。
   *
   * 来源：HomeTab Quick Stats "已装模组" 卡 → kind=MOD, version=mcVersion。
   * （VersionManagerSheet 详情资源格的四个 cell 改为 sheet 内部横滑，不再走父组件回调。）
   *
   * 防御：版本 id 为空 / 没有任何已装版本时仍打开（让用户看到空态引导文案），不静默吞掉。
   */
  private openInstalledResourcesSheet(version: string, kind: ResourceKind): void {
    this.installedResourcesTargetVersion = version || ''
    this.installedResourcesKind = kind
    this.versionManagerInitialStep = 'resources'
    this.showVersionManager = true
  }

  // ==================== 业务逻辑 ====================

  private launchMC() {
    if (!this.startupFinished_ || this.versionScanPending_) {
      this.safeToast_('正在刷新本地版本，请稍候');
      return;
    }
    if (this.storeHasSession_) { this.returnExistingGame_(); return }
    try { this.pendingRunAdmission_ = GameRunAdmission.capture(this.context) }
    catch (error) { this.safeToast_((error as Error).message); return }
    // 标记本次会话已启动游戏：之后自动检查更新只刷红点、不再弹提示框（不打扰）。
    this.gameLaunchedThisSession = true
    let mcDir = this.mcRoot()
    // JDK 路由（按当前 MC 版本纪元）。注意：不再在此直接拦"JDK 未安装"并跳转——
    // 改由启动前校验 Sheet 统一呈现（JIT / 运行时环境 / 版本文件完整性三项），
    // 任一不过都不启动；全部通过才在 doLaunchAfterChecks 真正创建 JVM。
    //
    // 单版本设置：先解析该版本【实际生效】的启动配置（单版本覆盖 or 沿用全局），
    // 得到生效的 xmx / jdk / customJvmArgs（customJvmArgs 由 McGamePage 按 mcVersion 自行解析）。
    // 启动计划（版本隔离 gameDir + JDK 路由）下沉到 launch HAR 的 LaunchCoordinator（三层架构第四步）。
    let eff = this.getPrefManager_().resolveLaunch(this.mcVersion)
    let plan = this.getLaunchCoordinator_().resolvePlan({
      mcVersion: this.mcVersion,
      mcDir: mcDir,
      versionIsolation: this.versionIsolation,
      userPreferredJdk: this.selectedJdkVersion,
      overrideJdkVersion: eff.jdkVersion,
      effectiveXmx: eff.xmx,
    })
    this.preLaunchGameDir = plan.gameDir
    this.preLaunchJdkVersion = plan.jdkVersion
    // 区间与"选了哪个 JDK"无关（单版本硬覆盖会绕过路由），所以独立取一次。
    this.preLaunchJdkRange = this.getJdkManager_().jdkRangeFor(this.mcVersion, mcDir)
    this.preLaunchXmx = plan.xmx
    this.showPreLaunchSheet = true
  }

  /**
   * "改用自动 JDK"（启动前 JDK 版本匹配警告里的一键修复）：把当前版本的单版本 JDK 覆盖改为
   * 自动，重新按纪元路由出兼容的 JDK，更新启动计划用的 preLaunchJdkVersion 并返回新版本号
   * （供 PreLaunchCheckSheet 用新值重跑校验）。
   */
  private switchCurrentVersionJdkToAuto(): string {
    let o = this.getPrefManager_().getVersionOverride(this.mcVersion)
    o.jdkVersion = JDK_AUTO
    this.getPrefManager_().setVersionOverride(this.mcVersion, o)
    let newJdk = this.getLaunchCoordinator_().resolveJdk(this.mcVersion, this.mcRoot(), JDK_AUTO, this.selectedJdkVersion)
    this.preLaunchJdkVersion = newJdk
    this.updateJdkReadyState()
    AppLogger.info(TAG, `switchCurrentVersionJdkToAuto: ${this.mcVersion} -> ${newJdk}`, LOG_DOMAIN_LAUNCH)
    return newJdk
  }

  /**
   * 启动前校验里「一同下载 JDK」：enqueue JdkInstallTask 到统一下载系统（registry），
   * **不弹 DownloadTasksSheet**——进度由 PreLaunchCheckSheet 内联轮询 'jdk:<ver>' 显示。
   * jdkVersion 由 PreLaunchCheckSheet 传入（= 当前 MC 版本自动匹配出的版本，高版本=25）。
   * 装好后刷新 jdkReady；Sheet 侧 DONE 会自动重跑校验并继续启动。
   */
  private startInlineJdkDownload(jdkVersion: string): void {
    // 空区间没有可下载的推荐 JDK；也拒绝未知槽，避免把策略错误转成空任务 ID。
    if (!LaunchCoordinator.isSpecificJdk(jdkVersion)) {
      AppLogger.warn(TAG, 'Refusing inline download without a supported JDK selection', undefined, LOG_DOMAIN_LAUNCH)
      return
    }
    // 先定 activityId 再造任务：任务要拿它去绑 native 下载日志的归属
    let startedAt = Date.now()
    let task = new JdkInstallTask(jdkVersion, this.getJdkManager_(), startedAt)
    this.registry.enqueue(task).then(() => {
      this.updateJdkReadyState()
    }).catch((e: Error) => {
      AppLogger.warn(TAG, `inline JDK download failed: ${jdkVersion}`, e, LOG_DOMAIN_LAUNCH)
    })
  }

  /**
   * 一多：构造按「设备形态 + 响应式断点」自适应的 bindSheet 选项。
   * - 手机形态（含横屏）/ 窄窗口 → 底部抽屉（BOTTOM）+ 拖拽条 + 不限宽（沿用原貌）。
   * - 平板 / PC 且窗口 ≥ 600vp → 居中悬浮卡片（CENTER）+ 限宽 + 系统关闭按钮。
   * 各 sheet 仅 backgroundColor 不同，其余决策统一走 commons/SheetSizes 的一多 helper。
   */
  private adaptiveSheetOptions(bgColor: ResourceColor): SheetOptions {
    const center: boolean = centerSheetForLayout(this.deviceForm, this.appBreakpoint)
    return {
      height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight),
      width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
      dragBar: !center,
      showClose: false,
      backgroundColor: bgColor,
      blurStyle: BlurStyle.NONE,
      preferType: center ? SheetType.CENTER : SheetType.BOTTOM,
    }
  }

  /**
   * 仅版本管理宿主增加关闭接缝，其余 Sheet 继续使用统一的尺寸与系统交互。
   * onWillDismiss 自 API 12 提供，涵盖系统 Back、手势及遮罩；注册后由内容确认
   * 是否关闭，避免系统先销毁组件，再尝试询问尚未保存的导出选择。
   */
  private versionManagerSheetOptions_(): SheetOptions {
    const options: SheetOptions = this.adaptiveSheetOptions(this.theme.bgCard)
    options.onWillDismiss = (action: DismissSheetAction): void => {
      const dismissExport: ((back?: boolean) => void) | undefined = this.versionExportDismiss_
      if (dismissExport !== undefined) dismissExport(action.reason === DismissReason.PRESS_BACK)
      else action.dismiss()
    }
    return options
  }

  /**
   * 启动前三项校验全通过后真正启动游戏（导航 / 创建 JVM）。
   *
   * 交互：先收起校验 Sheet（失败时不会走到这里，所以"失败不收回"天然成立），
   * 等收回动画播放完（~300ms）再真正拉起游戏，避免 Sheet 还没缩回去就被
   * McGamePage 盖住的突兀感。
   *
   * 从旧 launchMC 提取：把"记录上次游戏 + startAbility/pushUrl"延后到校验通过之后，
   * 这样校验失败时不会误记一次"已游玩"（lastPlayedAt 只在真正进游戏时写）。
   */
  private doLaunchAfterChecks() {
    const admission: string = this.pendingRunAdmission_
    try { GameRunAdmission.assertToken(this.context, admission) }
    catch (error) { this.showPreLaunchSheet = false; this.safeToast_((error as Error).message); return }
    // 1) 先收起 Sheet（触发 bindSheet 的收回动画）
    this.showPreLaunchSheet = false
    // 2) 等收回动画播放完再启动。300ms ≈ bindSheet 默认收起时长。
    setTimeout(() => { this.performLaunch(undefined, admission).catch((e: Error) => {
      AppLogger.error(TAG, 'Launch dispatch failed', e, LOG_DOMAIN_LAUNCH)
      this.getUIContext().getPromptAction().showToast({ message: '启动准备失败：' + e.message })
    }) }, 300)
  }

  /**
   * 保存派发失败原文并请求owner核验父意图能否撤回。错误保存失败不能继续删除
   * 快照或消费义务，也不能覆盖原始派发异常；调用方仍向用户报告该次启动失败。
   */
  private async retainLaunchDispatchFailure_(activityId: number, intentToken: string, stage: string,
    error: Error): Promise<boolean> {
    try {
      return await SessionRecoveryRuntime.reportLaunchDispatchFailure(this.context, activityId, intentToken, stage, error)
    } catch (persistenceError) {
      AppLogger.warn(TAG, 'Launch dispatch evidence persistence deferred; original intent retained', persistenceError, LOG_DOMAIN_LAUNCH)
      return false
    }
  }

  /** 真正拉起游戏（新窗口 startAbility 或内嵌 pushUrl McGamePage）。 */
  private desktopPreparing: boolean = false
  private pendingDesktopSnapshot: string = ''
  private async performLaunch(recovery: GraphicsRecoveryDispatch | undefined = undefined,
    admission: string = this.pendingRunAdmission_): Promise<void> {
    if (this.desktopPreparing || DesktopLaunchSnapshot.pending(this.context, this.pendingDesktopSnapshot)) return
    if (getGameSessionHost().isRunning()) { await this.returnExistingGame_(); return }
    // 新的用户启动取消尚未消费的旧恢复请求；恢复自身则携带一次性的明确候选。
    // 无论用户保存了开启还是关闭，只要旧的独立游戏仍活着，就只能聚焦现有会话。
    // 尤其父进程重启并应用关闭值后，不得绕过隔离分支而在启动器里再建第二个 JVM。
    // 手机不进入此设备能力路径；未知锁状态准确拒绝，不当作“没有游戏”。
    if (ProductInputProfile.selection().desktopWindow || ProductInputProfile.canChooseTabletProcess()) {
      const existingGame: number = testNapi.desktopGameProcessState(this.context.filesDir, 0)
      if (existingGame < 0) throw new Error('无法核验现有游戏进程，请稍后重试')
      if (existingGame === 1) {
        const focusWant: Want = { bundleName: 'com.amcl.launcher', abilityName: 'GameAbility' }
        await this.context.startAbility(focusWant)
        return
      }
      GameRunAdmission.assertToken(this.context, admission)
      // 切回兼容模式也要先接收旧独立会话的布局，不能只在 prepare 独立快照时同步。
      // 活跃草稿/未持久化提交保留原文并阻止本次新启动，避免把“同步尚未完成”当已保存。
      const layouts: GameLayoutImportReport = await GameLayoutJournal.importPending(this.context)
      if (layouts.deferred || layouts.pending > 0) {
        throw new Error('游戏内布局尚未同步，请先关闭布局编辑器后重试')
      }
      if (layouts.conflicts.length > 0) {
        this.safeToast_('布局存在同时修改，已保留双方方案，可在布局管理中查看')
      }
    }
    let mcDir = this.mcRoot()
    let gameDir = this.preLaunchGameDir
    let jdkVer = this.preLaunchJdkVersion
    let xmx = this.preLaunchXmx
    // R-5：记录"上次启动"时间，给 HomeTab Quick Stats "上次游戏" 卡用。
    let now = Date.now()
    // U08：启动活动主键在派发前确定，内嵌页和 desktop 独立进程必须复用同一个值。
    const launchActivityId: number = now
    // 父意图token仅区分本次派发；游戏进程的runNonce由自己的RUNNING基线发布，不能伪造为同值。
    const launchIntentToken: string = util.generateRandomUUID().toLowerCase()
    this.lastPlayedAt = now
    this.getPrefManager_().lastPlayedAt = now
    this.getPrefManager_().lastPlayedVersion = this.mcVersion
    // 私有进程与桌面交互是独立决策。平板验证仍使用真实 tablet 身份和触控输入，
    // 这里只决定启动边界，不通过伪造 desktopWindow 强制改变渲染或窗口样式。
    GameRunAdmission.assertToken(this.context, admission)
    GameRunAdmission.installTicket(this.context, admission)
    if (ProductInputProfile.selection().isolatedGameProcess) {
      let wantParams: Record<string, string | number> = {
        'parentPid': testNapi.desktopProcessId(),
        'filesDir': this.context.filesDir,
        'mcDir': mcDir,
        'gameDir': gameDir,
        'mcVersion': this.mcVersion,
        'mcXmx': xmx,
        'jdkVersion': jdkVer,
        'activityId': launchActivityId
      }
      let want: Want = {
        bundleName: 'com.amcl.launcher',
        abilityName: 'GameAbility',
        parameters: wantParams
      };
      // 独立游戏派发失败继续向用户报告，不在启动器进程静默回退创建JVM。
      this.desktopPreparing = true
      let registrationAttempted: boolean = false
      let intentTracked: boolean = false
      try {
        const state: number = testNapi.desktopGameProcessState(this.context.filesDir, 0)
        if (state < 0) throw new Error('无法核验游戏进程状态')
        if (state === 0) {
          // 聚焦仍在运行的GameAbility不能清掉其待消费回执；只有确实新建一局才替换身份。
          if (recovery === undefined) this.pendingGraphicsRecoveryId_ = ''
          const snapshot: DesktopLaunchSnapshotRef = await DesktopLaunchSnapshot.prepare(this.context,
            wantParams['parentPid'] as number, wantParams['mcVersion'] as string, launchActivityId)
          this.pendingDesktopSnapshot = snapshot.id
          const recoveryTicket: GraphicsRecoveryTicket = { id: snapshot.id,
            parentPid: wantParams['parentPid'] as number, activityId: launchActivityId,
            rootActivityId: recovery === undefined ? launchActivityId : recovery.rootActivityId,
            attempt: recovery === undefined ? 0 : recovery.attempt, createdAt: Date.now(),
            version: this.mcVersion, mcDir: mcDir, gameDir: gameDir, jdk: jdkVer, xmx: xmx,
            preferenceStamp: this.graphicsPreferenceStamp_(), retryProfile: recovery === undefined ? '' : recovery.profile,
            diagnosticInjected: recovery !== undefined && recovery.diagnosticInjected === true }
          try {
            GraphicsRecoveryStore.create(this.context.filesDir, recoveryTicket)
            // 票据提交之后才做有界维护；当前启动身份排除，缓存清理失败不能改变启动结果。
            try { testNapi.graphicsRecoveryMaintain(this.context.filesDir + '/graphics-recovery', snapshot.id) }
            catch (maintenanceError) { AppLogger.warn(TAG, 'Graphics ticket maintenance deferred', maintenanceError, LOG_DOMAIN_LAUNCH) }
            this.pendingGraphicsRecoveryId_ = snapshot.id
          } catch (recoveryError) {
            this.pendingGraphicsRecoveryId_ = ''
            // 首次正常启动的可选恢复记录失败，不应阻断已经准备好的游戏启动。
            // 重试则必须携带明确候选；票据失败时拒绝派发，防止又回到原自动后端。
            if (recovery !== undefined) throw recoveryError as Error
            AppLogger.warn(TAG, 'Graphics recovery disabled for this attempt; ticket persistence failed',
              recoveryError, LOG_DOMAIN_LAUNCH)
          }
          wantParams['snapshotId'] = snapshot.id
          wantParams['accountSnapshot'] = snapshot.account
          // 快照和可选恢复票据准备完毕才建立父退出义务；准备失败从未派发child，不留缺基线待办。
          // 义务仍必须在实际dispatch前耐久完成，游戏极早退出也能按本局ID找到journal。
          registrationAttempted = true
          await SessionRecoveryRuntime.coordinator(this.context).trackLaunch(launchActivityId, launchIntentToken)
          intentTracked = true
        }
        GameRunAdmission.assertToken(this.context, admission)
        if (state === 0 && !ProductInputProfile.selection().desktopWindow) {
          // 平板新建独立游戏登记终局回调，注册后立即结束派发；不能 await 到整局游戏结束。
          // 既有游戏仅聚焦、电脑窗口仍保留原来的普通 startAbility 协议。
          this.startTabletGameForResult_(want, launchActivityId, this.pendingDesktopSnapshot, launchIntentToken)
        } else {
          await this.context.startAbility(want)
        }
      } catch (e) {
        // 系统拒绝派发不证明child没有启动；只有owner确认尚无基线/生产者且空闲才撤回父意图。
        // 不确定时保留快照，迟到child仍能消费自己的启动输入并建立RUNNING基线。
        // 登记await失败可能已发布意图或队列字节，独立错误原文必须覆盖该耐久性未知窗口。
        const withdrawn: boolean = registrationAttempted && await this.retainLaunchDispatchFailure_(launchActivityId,
          launchIntentToken, intentTracked ? 'ability.dispatch' : 'ability.intent', e as Error)
        if (!intentTracked || withdrawn) {
          // 尚未走到dispatch的快照从未交付child，可以清理；这不代表登记义务已被消费。
          DesktopLaunchSnapshot.discard(this.context, this.pendingDesktopSnapshot)
          this.pendingDesktopSnapshot = ''
        }
        AppLogger.error(TAG, 'startAbility failed', e, LOG_DOMAIN_LAUNCH)
        throw e as Error
      } finally {
        this.desktopPreparing = false
      }
    } else {
      let registrationAttempted: boolean = false
      let intentTracked: boolean = false
      try {
        registrationAttempted = true
        await SessionRecoveryRuntime.coordinator(this.context).trackLaunch(launchActivityId, launchIntentToken)
        intentTracked = true
        // 键必须写成引号字符串：读侧 McGamePage 用 params?.['filesDir'] 取值，而标识符键
        // 会被属性名混淆改名、字符串下标不会 —— 两者口径不一致时 release 下 6 个参数
        // 全变 undefined（debug 恒正常）。上面 startAbility 那支的 wantParams 同理，
        // 它一直是引号键，本支此前是标识符键，是这条链路上唯一的例外。
        // Promise兑现才表示本次路由派发成功；异步拒绝与同步throw走相同原件保留入口。
        GameRunAdmission.assertToken(this.context, admission)
        GameRunAdmission.installTicket(this.context, admission)
        await this.getUIContext().getRouter().pushUrl({
          url: 'pages/McGamePage',
          params: {
            'filesDir': this.context.filesDir,
            'mcDir': mcDir,
            'gameDir': gameDir,
            'mcVersion': this.mcVersion,
            'mcXmx': xmx,
            'jdkVersion': jdkVer,
            'activityId': launchActivityId
          }
        })
      } catch (e) {
        if (registrationAttempted) await this.retainLaunchDispatchFailure_(launchActivityId, launchIntentToken,
          intentTracked ? 'router.dispatch' : 'router.intent', e as Error)
        AppLogger.error(TAG, 'pushUrl McGamePage failed', e, LOG_DOMAIN_LAUNCH)
        throw e as Error
      }
    }
  }

  /**
   * 平板的独立 UI 返回控制面。系统 resultCode=-1 可以仅表示目标进程结束，绝不是 JVM
   * 退出码；只记录该结果，并在游戏锁明确空闲后请求父 EntryAbility 前台恢复。
   * 真正游戏结局仍由原生 journal 和会话证据裁决。旧回调遇到新游戏持锁时不抢前台。
   */
  private startTabletGameForResult_(want: Want, activityId: number, snapshotId: string, intentToken: string): void {
    this.context.startAbilityForResult(want, (error: BusinessError, result: common.AbilityResult): void => {
      const errorCode: number = error ? error.code : 0
      const resultCode: string = result && typeof result.resultCode === 'number'
        ? result.resultCode.toString() : 'absent'
      AppLogger.info(TAG, `AMCL_TABLET_ABILITY_RESULT activityId=${activityId}`
        + ` errorCode=${errorCode} abilityResultCode=${resultCode}`, LOG_DOMAIN_LAUNCH)
      // callback返回错误也可能迟于child开始。先保留原文并由owner核验撤回，不能先删启动快照。
      const report: Promise<void> = errorCode === 0 ? Promise.resolve()
        : this.retainLaunchDispatchFailure_(activityId, intentToken, 'ability.result', error).then((withdrawn: boolean): void => {
          if (withdrawn) {
            DesktopLaunchSnapshot.discard(this.context, snapshotId)
            if (this.pendingDesktopSnapshot === snapshotId) this.pendingDesktopSnapshot = ''
          }
          AppStorage.setOrCreate<string>('desktopLaunchError', `游戏窗口返回错误（${errorCode}），请查看本局日志。`)
        })
      report.then((): void => {
        try {
          if (testNapi.desktopGameProcessState(this.context.filesDir, 0) !== 0) {
            AppLogger.info(TAG, 'Tablet return deferred: game process is active or unconfirmed', LOG_DOMAIN_LAUNCH)
            return
          }
          const returnParameters: Record<string, number> = { 'gameExitActivityId': activityId }
          const returnWant: Want = { bundleName: 'com.amcl.launcher', abilityName: 'EntryAbility',
            parameters: returnParameters }
          // onNewWant 与 onForeground 都复用 Entry 的退出恢复入口；这里只请求 UI，不写历史终态。
          this.context.startAbility(returnWant).then((): void => {
            AppLogger.info(TAG, `AMCL_TABLET_RETURN_REQUESTED activityId=${activityId}`, LOG_DOMAIN_LAUNCH)
          }).catch((failure: Error) => {
            AppLogger.warn(TAG, 'Tablet return request failed; exit journal retained', failure, LOG_DOMAIN_LAUNCH)
          })
        } catch (failure) {
          AppLogger.warn(TAG, 'Tablet return control unavailable; exit journal retained', failure, LOG_DOMAIN_LAUNCH)
        }
      }).catch((failure: Error): void => {
        AppLogger.warn(TAG, 'Tablet result evidence retained; return control deferred', failure, LOG_DOMAIN_LAUNCH)
      })
    })
  }

  /** 开关只保存下次冷启动的选择；等待持久化完成，失败还原显示，不重启当前游戏或下载。 */
  private async changeTabletProcess_(enabled: boolean): Promise<void> {
    if (this.tabletProcessSaving || !ProductInputProfile.canChooseTabletProcess()) return
    const previous: boolean = this.tabletIndependentGameProcess
    this.tabletProcessSaving = true
    this.tabletProcessMessage = ''
    this.tabletIndependentGameProcess = enabled
    try {
      await this.getPrefManager_().saveTabletIndependentGameProcess(enabled)
      this.tabletProcessMessage = '已保存。修改仅在重启启动器后生效。'
    } catch (error) {
      this.tabletIndependentGameProcess = previous
      this.tabletProcessMessage = '保存失败，请重试；本次运行方式未改变。'
      AppLogger.warn(TAG, 'Tablet process preference save failed', error, LOG_DOMAIN_LAUNCH)
    } finally {
      this.tabletProcessSaving = false
    }
  }

  /**
   * 统一跳转到下载 Tab 的指定二级子页。所有"去下载页"的入口都应走这里，
   * 以保证不仅切到下载大 Tab，还把内部二级 Tab 定位到正确分类（避免落到上次停留的子页）。
   * subTab：0=版本 / 1=模组 / 2=光影 / 3=资源包 / 4=整合包 / 5=JDK。
   */
  private jumpToDownloadSub(subTab: number): void {
    this.currentTab = 1
    try { this.tabController.changeIndex(1) } catch (e) { /* ignore */ }
    // bump nonce 确保即使连续两次跳同一子页，navCommand 值也会变化以触发 DownloadTab 的 @Watch
    this.dlNavCounter_ += 1
    this.dlNavCommand = this.dlNavCounter_ * 10 + subTab
  }

  /** 资源类别 → 下载页二级子页序号（模组/光影/资源包/整合包）。未知类别兜底到"模组"。 */
  private resourceKindToDlSubTab(kind: ResourceKind): number {
    if (kind === ResourceKind.SHADER) return 2
    if (kind === ResourceKind.RESOURCE_PACK) return 3
    if (kind === ResourceKind.MODPACK) return 4
    return 1  // MOD / DATAPACK 及其他 → 模组
  }

  /** 启动前校验失败时的一键修复路由（关 Sheet + 切到对应 Tab / 触发补全）。 */
  private handlePreLaunchFix(key: string) {
    this.showPreLaunchSheet = false
    if (key === 'open_jdk_manager') {
      this.currentTab = 2   // 设置 Tab（JDK 管理）
      try { this.tabController.changeIndex(2) } catch (e) { /* ignore */ }
    } else if (key === 'redownload') {
      // 版本文件/资源校验失败 → 直接一键补全当前版本（方案 B：基于磁盘 json 增量修复）
      this.repairVersionFiles(this.mcVersion)
    } else if (key === 'open_versions') {
      this.jumpToDownloadSub(0)   // 下载 Tab → 版本子页
    }
  }

  /**
   * 版本详情触发的【全量 SHA1 校验】：主 jar + 全部依赖库逐个算 sha1 比对 version.json，
   * assets 走存在/size。带进度覆盖层，结果以摘要 + 可选"重新下载"呈现。
   *
   * 与启动前校验的分工：启动前只 hash 主 jar（快、每次启动跑）；这里是用户主动的深度
   * 体检（慢、几秒到十几秒），对齐 PCL2 的"校验/补全文件"。
   */
  private async verifyVersionFilesFull(ver: string) {
    if (!ver || ver.length === 0) return
    this.verifyTitle = ver
    this.verifyRunning = true
    this.verifyProblemCount = 0
    this.verifyText = '正在准备校验…'
    this.showVerifyOverlay = true
    let mcDir = this.mcRoot()
    try {
      let report: VerifyReport = await VersionFileVerifier.verifyAll(mcDir, ver,
        (done: number, total: number, label: string) => {
          this.verifyText = '校验中 ' + done + '/' + total + '\n' + label
        })
      this.verifyRunning = false
      let problems = report.missing.length + report.corrupted.length
      this.verifyProblemCount = problems
      if (!report.hadMeta) {
        this.verifyText = '该版本的 version.json 未包含官方校验信息（常见于自定义 / 模组版本），'
          + '无法做 SHA1 校验。\n已检查资源：缺失 ' + report.assetsMissing + '/' + report.assetsTotal + '。'
        return
      }
      if (problems === 0 && report.assetsMissing === 0) {
        this.verifyText = '校验通过 ✓\n共 ' + report.total + ' 个文件，全部完整。'
        return
      }
      let lines: string[] = []
      lines.push('共校验 ' + report.total + ' 个文件')
      if (report.missing.length > 0) {
        lines.push('缺失 ' + report.missing.length + ' 个：' + report.missing.slice(0, 3).join('、')
          + (report.missing.length > 3 ? ' 等' : ''))
      }
      if (report.corrupted.length > 0) {
        lines.push('损坏/不匹配 ' + report.corrupted.length + ' 个：' + report.corrupted.slice(0, 3).join('、')
          + (report.corrupted.length > 3 ? ' 等' : ''))
      }
      if (report.assetsMissing > 0) {
        lines.push('资源缺失 ' + report.assetsMissing + '/' + report.assetsTotal + ' 项')
      }
      this.verifyText = lines.join('\n')
    } catch (e) {
      this.verifyRunning = false
      this.verifyProblemCount = 0
      this.verifyText = '校验过程出错：' + formatError(e)
      AppLogger.error(TAG, 'verifyVersionFilesFull failed', e, LOG_DOMAIN_LAUNCH)
    }
  }

  /**
   * 一键修复某版本文件。非破坏性：普通版本只增量补全文件、绝不改写 version.json。
   *
   * Forge 生成产物（forge-<ver>-client.jar）损坏的特例 → 走 ForgeRepairTask：
   * 它会在快照保护存档/模组的前提下，重建生成产物并【重做 vanilla+forge 合并】，
   * 恢复完整的自包含 version.json（修复"清单被裸装写残"的根因）。
   */
  /** 刷新首页「最近活动」展示数据（取 store 最新前 5 条）。 */
  private refreshRecentActivities_(): void {
    let store = getDownloadHistoryStore()
    store.waitReady().then(() => {
      // 恢复owner已耐久upsert最新结局；首页小卡仅取LRU投影，不在显示回调同步合并全部账本。
      this.recentActivities = store.listStored().slice(0, 5)
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'refreshRecentActivities failed', e, LOG_DOMAIN_DOWNLOAD)
    })
  }

  /**
   * 写一条通用活动记录（repair/jdk/account 等非下载类操作）。
   * 量化字段（totalBytes/fileCount）对这些操作无意义，留 0；UI 按 category 自适应展示。
   */
  // ============================================================
  //  活动账本（Activity Ledger · L2-b）
  //
  //  每条活动开始时开一个账本，结束时封账。activityId 直接用 startedAt ——
  //  它同时也是 ActivityRecord 的主键与 M3 的 sessionKey，三者天然对应，
  //  不另造 id 就不会出现「两套主键对不上」。
  // ============================================================

  /**
   * 活动开始：开账本。
   *
   * 必须在活动**真正开始之前**调用 —— native 的日志分流只对「scope 已打开」期间的
   * 行生效，开晚了前面的日志就归属不上（那正是启动阶段最有价值的部分）。
   */
  private beginActivity_(category: string, title: string, startedAt: number,
    gameVersionId: string = '', parentActivityId: number = 0, relation: string = ''): void {
    try {
      let meta: LedgerBeginMeta = { category: category, title: title }
      if (parentActivityId > 0 && parentActivityId !== startedAt) { meta.parentActivityId = parentActivityId; meta.relation = relation }
      if (gameVersionId.length > 0) {
        meta.gameVersionId = gameVersionId
        meta.mcDir = this.mcRoot()
      }
      try { meta.appFilesDir = this.context.getApplicationContext().filesDir }
      catch (e) { /* 旧宿主没有应用级 filesDir 时保持空 */ }
      // registry观察者返回后producer就可能写第一行；新ID沿用有界同步scope注册顺序，
      // 不将开账变为fire-and-forget异步。只有已有scope的同ID元信息更新才可排队。
      let job: Promise<void>
      try {
        if (!ledgerBegin(this.context.filesDir, startedAt, meta)) throw new Error('活动账本尚未耐久建立，原任务事实保留')
        job = Promise.resolve()
      } catch (error) {
        if (ledgerManifest(this.context.filesDir, startedAt) === null) throw error as Error
        job = ledgerBeginAsync(this.context.filesDir, startedAt, meta).then((began: boolean): void => {
          if (!began) throw new Error('已有活动元信息更新尚未完成，保留原scope和任务事实')
        })
      }
      this.activityBeginJobs_.set(startedAt, job)
      job.catch((error: Error): void => { AppLogger.warn(TAG, '活动异步开账失败，终态将保留重试', error, LOG_DOMAIN_UI) })
    } catch (e) {
      // 账本开失败不能影响活动本身，全局日志里仍有内容
      AppLogger.warn(TAG, 'beginActivity_ failed', e, LOG_DOMAIN_UI)
    }
  }

  /** ActivityStatus 字符串 → 账本结局枚举。 */
  private ledgerStateOf_(status: string): LedgerState {
    if (status === ActivityStatus.SUCCESS) return LedgerState.SUCCESS
    if (status === ActivityStatus.FAILED) return LedgerState.FAILED
    if (status === ActivityStatus.ABORTED) return LedgerState.ABORTED
    if (status === ActivityStatus.CRASHED) return LedgerState.CRASHED
    return LedgerState.SUCCESS
  }

  /** 活动结束等待本局开账和真实async scope关闭；全局维护由owner合并，不在这里逐局淘汰。 */
  private async endActivity_(startedAt: number, status: string, summary: string,
    errorKind: string = '', fallbackMeta: LedgerBeginMeta | undefined = undefined): Promise<void> {
    try {
      let outcome: LedgerOutcome = {
        state: this.ledgerStateOf_(status),
        source: 'task.terminalState',
        summary: summary,
        endedAt: Date.now(),
      }
      if (errorKind.length > 0) outcome.errorKind = errorKind
      const begin = this.activityBeginJobs_.get(startedAt)
      if (begin !== undefined) await begin
      else if (await ledgerManifestAsync(this.context.filesDir, startedAt) === null && fallbackMeta !== undefined) {
        if (!await ledgerBeginAsync(this.context.filesDir, startedAt, fallbackMeta)) throw new Error('活动账本建立失败')
      }
      await ledgerEndAsync(this.context.filesDir, startedAt, outcome)
      this.activityBeginJobs_.delete(startedAt)
    } catch (e) {
      AppLogger.warn(TAG, 'endActivity_ failed', e, LOG_DOMAIN_UI)
      throw e as Error
    }
  }

  private addActivity_(category: string, title: string, status: string,
    startedAt: number, subtitle: string, errorMessage: string): void {
    // 活动记录与账本同一主键、同一时刻封账 —— 保证「有记录就有账本入口」
    const commit = this.endActivity_(startedAt, status, errorMessage.length > 0 ? errorMessage : subtitle,
      '', { category: category, title: title })
    let nowMs = Date.now()
    let rec: ActivityRecord = {
      versionName: title,
      gameVersion: '-',
      loaderType: category,
      startedAt: startedAt,
      durationMs: nowMs - startedAt,
      totalBytes: 0,
      fileCount: 0,
      status: status,
      category: category,
      endedAt: nowMs,
      title: title,
      subtitle: subtitle,
    }
    if (errorMessage.length > 0) rec.errorMessage = errorMessage
    commit.then((): Promise<void> => getDownloadHistoryStore().add(rec)).then(() => {
      this.refreshRecentActivities_()
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'activity record add failed', e, LOG_DOMAIN_DOWNLOAD)
    })
  }

  /** 队列Promise收口不代表业务成功；ERROR/未知态保守记失败，避免修复/JDK错误冒充成功。 */
  private terminalStatus_(state: string): string {
    if (state === UnifiedTaskState.ABORTED) return ActivityStatus.ABORTED
    return state === UnifiedTaskState.DONE ? ActivityStatus.SUCCESS : ActivityStatus.FAILED
  }

  private repairVersionFiles(ver: string, inSheet: boolean = false) {
    if (!ver || ver.length === 0) return
    let mcDir = this.mcRoot()
    let fg = LaunchCoordinator.parseForgeVersionId(ver)
    if (fg !== null && LaunchCoordinator.needsForgeDeepRepair(mcDir, ver, fg)) {
      let ftask = new ForgeRepairTask(ver, fg.game, fg.loader, mcDir, this.context.filesDir)
      this.registry.enqueue(ftask)
        .catch((e: Error) => {
          AppLogger.warn(TAG, 'enqueue forge repair rejected', e, LOG_DOMAIN_DOWNLOAD)
          this.statusMsg = '修复启动失败: ' + e.message
        })
    } else {
      let task = new RepairTask(ver, mcDir)
      this.registry.enqueue(task)
        .catch((e: Error) => {
          AppLogger.warn(TAG, 'enqueue repair rejected', e, LOG_DOMAIN_DOWNLOAD)
          this.statusMsg = '修复启动失败: ' + e.message
        })
    }
    // inSheet=true：留在启动前校验 Sheet 内镜像进度，不跳转下载页、不关弹层。
    if (inSheet) return
    // 关掉相关弹层 + 切到下载 Tab 展示进度
    this.showVerifyOverlay = false
    this.showVersionManager = false
    this.showPreLaunchSheet = false
    this.jumpToDownloadSub(0)   // 下载 Tab → 版本子页
  }

  /**
   * 检查更新：按所选通道比对安装编号与发行名。toast提示检查中，结果分三路：
   * 失败 → toast；已是最新 → toast；有新版 → 弹窗（版本 + 更新日志 + 前往下载/稍后）。
   */
  private async checkForUpdate() {
    if (DistributionPolicy.isStore()) return
    // 发请求前固定来源；TestWant 的 finally clear 或重新 configure 不能改写迟到响应的身份。
    const source = SideloadUpdateTestSession.captureSource()
    const channel = this.getPrefManager_().appUpdateChannel
    let pa = this.getUIContext().getPromptAction()
    try { pa.showToast({ message: '正在检查更新…', duration: 1500 }) } catch (e) { /* */ }
    let res: UpdateCheckResult = await UpdateChecker.checkForUpdate(source.urls, ProductBuildProfile.product,channel)
    // 过期测试检查不刷新正式红点/时间戳，也不进入弹窗队列，更不能按 GitHub 候选继续。
    if (channel !== this.getPrefManager_().appUpdateChannel || !SideloadUpdateTestSession.isCurrent(source)) {
      AppLogger.info(TAG, '丢弃已结束测试会话的迟到更新检查', LOG_DOMAIN_UI)
      return
    }
    SideloadUpdateTestSession.validateResult(res, source)
    this.applyUpdateResult(res)   // 同步红点 + 持久化（节流时间戳 + latestSeen）
    if (!res.ok) {
      try { pa.showToast({ message: '检查更新失败：' + res.error, duration: 2500 }) } catch (e) { /* */ }
      return
    }
    if (!res.hasUpdate) {
      try { pa.showToast({ message: res.error || '已是最新版本', duration: 1800 }) } catch (e) { /* */ }
      return
    }
    this.showUpdateDialog(res.manifest!, true, source)
  }

  /**
   * 发现新版本时弹更新提示。手动检查与启动自动检查共用。
   *
   * 2026-08-08：从系统 `promptAction.showDialog`（只能显示一段纯文本）换成自绘
   * `UpdateDialog` —— 按分类渲染结构化条目 + 「查看完整更新日志」入口 + 强制更新态。
   * 条目取自 `UpdateChecker.displayEntries`（结构化优先，缺失时回退解析 notes），
   * 所以新旧 update.json 都能渲染，详见 AMCL-web/CHANGELOG-SPEC.md。
   *
   * 「稍后」记录延后时间并保留红点；24 小时内冷启动不再联网/弹框，期满后再提示。
   * 弹窗构建失败（极端情况）时退化为直接打开下载页，不能把用户卡在"什么都没发生"。
   */
  private showUpdateDialog(m: UpdateManifest, manual: boolean = true,
    source: SideloadUpdateCheckSource = SideloadUpdateTestSession.productionSource()): void {
    if (!this.startupFinished_ || this.showMcErrorSheet || this.recoveringSessions_ || this.recoveryPresentationDeferred_) {
      this.pendingAppUpdate_ = SideloadUpdatePromptPolicy.queue(this.pendingAppUpdate_, { manifest: m, manual: manual, source: source });
      return;
    }

    if(!source.testSource && (m.updateChannel ?? 'stable')!==this.getPrefManager_().appUpdateChannel) return
    // 首次展示和出队重入共用同一来源判据；过期测试清单直接丢弃，不改标识或降级安装参数。
    const candidate = SideloadUpdatePromptPolicy.candidate(m, source, manual)
    if (candidate === null) return
    // 后续 builder 和回调只使用候选拥有的深复制 DTO，检查调用方不能反向修改提示身份。
    m = candidate.manifest; source = candidate.source
    // 迟到自动结果和其他页面手动controller不能占第二席；仅可见的合格宿主展示。
    if (AppStorage.get<boolean>('amclHostPageVisible') !== true || this.showPrivacy || !UpdatePromptPresenter.claim(this.updatePresenterOwner)) {
      this.pendingAppUpdate_ = SideloadUpdatePromptPolicy.queue(this.pendingAppUpdate_, candidate)
      UpdatePromptPresenter.defer(this.updatePresenterOwner, (): void => { this.drainUpdateDialogs_(); }); return;
    }
    if (this.updateDialogCtrl_ !== null) {
      this.pendingAppUpdate_ = SideloadUpdatePromptPolicy.queue(this.pendingAppUpdate_, candidate); return;
    }
    try {
      // 参数只在合法展示时生成一次。ArkUI builder 后续重建仍使用这份固定值，
      // 不能因为全局测试配置已 clear 而让一个已展示面板突然改走正式资产解析。
      const selfUpdateParams = ProductBuildProfile.storeChannel ? undefined : SideloadUpdateTestSession.parameters(m, source)
      const sourceLabel = source.testSource ? '临时测试源' : 'GitHub 发布'
      // 正在展示的新提示已经消费旧的延后状态；若用户再次点「稍后」，回调会写入新时间。
      // 延后由成功检查时的目标身份变化自动清理。
      let ctrl: CustomDialogController | null = null
      // 同一弹窗进入连续更新后，遮罩/返回键不能越过内容层的取消与安装状态保护。
      let allowDismiss: () => boolean = (): boolean => true
      ctrl = new CustomDialogController({
        builder: UpdateDialog({
          theme: this.theme,
          newVersion: m.versionName.length > 0 ? m.versionName : m.tag,
          currentVersion: UpdateChecker.currentVersionName() || APP_VERSION,
          title: UpdateChecker.isStableReturn(m) ? '返回正式版' : '',
          releaseDate: m.date,
          sizeLabel: m.sizeBytes > 0 ? formatBytes(m.sizeBytes) : '',
          mandatory: m.mandatory,
          entries: UpdateChecker.displayEntries(m),
          showChangelogEntry: true,
          actionLabel: UpdateChecker.isStableReturn(m) ? '返回此正式版' : '立即更新',
          selfUpdateParams: selfUpdateParams,
          onDismissGuardReady: (guard: () => boolean): void => { allowDismiss = guard; },
          onExitGuardReady: (exit: () => boolean): void => { this.exitPresentedUpdate = exit; },
          sourceLabel: sourceLabel,
          showManualDownload: !ProductBuildProfile.storeChannel,
          onManualDownload: (): void => {
            this.closeUpdateDialog_()
            this.openExternalUrl(m.url)
          },
          onDownload: () => {
            this.closeUpdateDialog_()
            // 非侧载用途保留原下载出口；侧载立即更新已由弹窗内部连续推进。
            this.openExternalUrl(m.url)
          },
          onLater: () => {
            this.getPrefManager_().deferAppUpdate(ProductBuildProfile.product,m.updateChannel ?? 'stable',UpdateChecker.targetKey(m,ProductBuildProfile.product))
            // updateDot/latestSeenVersionCode 均不清除，所以下次启动红点仍在。
            this.closeUpdateDialog_()
          },
          onViewChangelog: () => {
            this.closeUpdateDialog_()
            this.openChangelogPage_()
          },
        }),
        autoCancel: !m.mandatory,
        onWillDismiss: (action: DismissDialogAction): void => { if (allowDismiss()) action.dismiss(); },
        cancel: (): void => {
          this.getPrefManager_().deferAppUpdate(ProductBuildProfile.product,m.updateChannel ?? 'stable',UpdateChecker.targetKey(m,ProductBuildProfile.product))
          this.updateDialogCtrl_ = null
          UpdatePromptPresenter.release(this.updatePresenterOwner)
          this.drainUpdateDialogs_()
        },
        customStyle: true,
        alignment: DialogAlignment.Center,
      })
      this.updateDialogCtrl_ = ctrl
      ctrl.open()
    } catch (e) {
      this.updateDialogCtrl_ = null; UpdatePromptPresenter.release(this.updatePresenterOwner)
      AppLogger.warn(TAG, 'UpdateDialog open failed, fallback to browser', e, LOG_DOMAIN_UI)
      // 打开失败时仍核来源有效性；过期测试候选连浏览器回退也不再自动触发。
      if (SideloadUpdateTestSession.matchesManifest(m, source)) this.openExternalUrl(m.url)
    }
  }

  /** UpdateDialog 不拥有 controller；关闭统一由创建它的父页面执行。 */
  /** 恢复入口独立于新清单；已安装latest但系统执行权未知仍能进入真实核实。 */
  private showUpdateRecovery_(): void {
    if (!this.startupFinished_ || this.showMcErrorSheet || this.recoveringSessions_ || this.recoveryPresentationDeferred_) return;
    if (ProductBuildProfile.storeChannel || this.recoveryPromptShown || this.updateDialogCtrl_ !== null || this.showPrivacy ||
      AppStorage.get<boolean>('amclHostPageVisible') !== true) return
    const service = SideloadUpdateService.get(this.context)
    if (!service.needsAttention() || !UpdatePromptPresenter.claim(this.updatePresenterOwner)) return
    this.recoveryPromptShown = true
    let allowDismiss: () => boolean = (): boolean => true
    try {
    this.updateDialogCtrl_ = new CustomDialogController({
      builder: UpdateDialog({ theme: this.theme, title: '核实上次更新', actionLabel: '查看更新状态',
        newVersion: service.state()?.asset.versionName ?? '', currentVersion: APP_VERSION, showChangelogEntry: false,
        sourceLabel: '上次更新', emptyNotesLabel: '上次安装仍有待核实状态。查看更新状态可以安全核实执行权，不会重复安装。',
        selfUpdateParams: { autoStart: false }, onDismissGuardReady: (guard: () => boolean): void => { allowDismiss = guard; },
          onExitGuardReady: (exit: () => boolean): void => { this.exitPresentedUpdate = exit; },
        onLater: (): void => { this.closeUpdateDialog_(); } }),
      autoCancel: true, onWillDismiss: (action: DismissDialogAction): void => { if (allowDismiss()) action.dismiss(); },
      cancel: (): void => { this.updateDialogCtrl_ = null; UpdatePromptPresenter.release(this.updatePresenterOwner); },
      customStyle: true, alignment: DialogAlignment.Center
    })
    this.updateDialogCtrl_.open()
    } catch (error) {
      this.updateDialogCtrl_ = null; UpdatePromptPresenter.release(this.updatePresenterOwner); this.recoveryPromptShown = false
      AppLogger.warn(TAG, '更新恢复提示暂无法显示，可从关于页打开', error, LOG_DOMAIN_UI)
    }
  }

  /** 路由离开与系统后台/helper往返区分，只有本实例仍持席位才退出自己的更新。 */
  private exitUpdateForRoute_(): void {
    if (this.updateDialogCtrl_ === null || !UpdatePromptPresenter.owns(this.updatePresenterOwner)) return
    try {
      const current = this.getUIContext().getRouter().getState()
      if (current.name !== 'Index' && current.name !== 'pages/Index') { this.exitPresentedUpdate(); this.closeUpdateDialog_(); }
    } catch (_) { /* 路由尚未更新时不把后台误判退出；真正销毁仍执行显式出口。 */ }
  }

  private closeUpdateDialog_(): void {
    let ctrl: CustomDialogController | null = this.updateDialogCtrl_
    this.updateDialogCtrl_ = null
    if (ctrl !== null) ctrl.close()
    UpdatePromptPresenter.release(this.updatePresenterOwner)
    this.resumeRecoveryPresentation_();
    this.onOpenErrorSheetReq();
    setTimeout((): void => { this.drainUpdateDialogs_(); }, 150)
  }

  /** 两类更新共用一个面板席位；自动提示只在启动器可见且本会话未开过游戏时排队。 */
  private drainUpdateDialogs_(): void {
    if (!this.startupFinished_ || this.showMcErrorSheet || this.recoveringSessions_ || this.recoveryPresentationDeferred_) return;
    if (this.updateDialogCtrl_ !== null || this.showPrivacy ||
      AppStorage.get<boolean>('amclHostPageVisible') !== true) return
    if (this.pendingAppUpdate_ !== null) {
      // 延迟展示前必须重新检查原测试代次。失效候选被消费并丢弃，让后续运行时提示正常排队。
      const candidate = SideloadUpdatePromptPolicy.select(this.pendingAppUpdate_, this.gameLaunchedThisSession)
      this.pendingAppUpdate_ = null
      if (candidate !== null && (candidate.source.testSource || (candidate.manifest.updateChannel ?? 'stable')===this.getPrefManager_().appUpdateChannel)) {
        this.showUpdateDialog(candidate.manifest, candidate.manual, candidate.source); return;
      }
    }
    if (this.pendingRuntimePrompt_) {
      const manual = this.pendingRuntimePromptManual_;
      this.pendingRuntimePrompt_ = false; this.pendingRuntimePromptManual_ = false;
      this.showRuntimeUpdateDialog_(manual);
    }
  }

  /** 运行时自动检查独立于 App/store 更新策略，只读取自己的成功时间与用户开关。 */
  private initRuntimeUpdateCheck_(): void {
    if (DistributionPolicy.isStore() && !GameRunAdmission.isAllowed()) return
    if (this.runtimeAutoCheckStarted_ || this.showPrivacy || !this.jdkAutoCheck) return
    this.runtimeAutoCheckStarted_ = true
    if (runtimeCheckDue(Date.now(),this.getPrefManager_().jdkLastCheck)) this.checkRuntimeUpdates_(false)
    else if (this.jdkHasUpdate) { this.pendingRuntimePrompt_ = true; this.drainUpdateDialogs_(); }
  }

  private async checkRuntimeUpdates_(manual: boolean): Promise<void> {
    // 检查中切换通道/手动重查不能丢弃请求。旧请求结束后只补一次最新偏好的检查。
    if (this.jdkChecking) { this.pendingRuntimeCheck_ = this.pendingRuntimeCheck_ || manual; return; }
    const channel = this.jdkChannel; const source = this.jdkSource; const web = this.jdkWebEnabled;
    this.jdkChecking = true; this.jdkCatalogStatus = '正在检查 JDK 更新…'
    try {
      const repository = RuntimeCatalogRepository.instance(this.context)
      await repository.configure(channel,source,web)
      const result: RuntimeRefreshResult = await repository.refresh()
      if (channel !== this.jdkChannel || source !== this.jdkSource || web !== this.jdkWebEnabled) return
      this.updateJdkReadyState()
      if (!result.ok) { this.jdkCatalogStatus = '检查未完成：' + result.error + '；保留现有运行时'; return; }
      this.getPrefManager_().jdkLastCheck = Date.now()
      this.jdkCatalogStatus = this.jdkHasUpdate ? '有 JDK 更新可用' : '当前通道的已装 JDK 暂无更新，版本列表已刷新'
      if (this.jdkHasUpdate) {
        if (manual) this.showRuntimeUpdateDialog_(true)
        else { this.pendingRuntimePrompt_ = true; this.drainUpdateDialogs_(); }
      }
    } catch (e) { this.jdkCatalogStatus = '检查失败：' + (e as Error).message; }
    finally {
      this.jdkChecking = false;
      if (this.pendingRuntimeCheck_) {
        this.pendingRuntimeCheck_ = false;
        setTimeout((): void => { this.checkRuntimeUpdates_(true); },0);
      }
    }
  }

  /** 复用 UpdateDialog 的说明、滚动和稍后按钮；选中的 JDK 进入既有统一下载任务。 */
  private showRuntimeUpdateDialog_(manual: boolean): void {
    if (!this.startupFinished_ || this.showMcErrorSheet || this.recoveringSessions_ || this.recoveryPresentationDeferred_) {
      this.pendingRuntimePrompt_ = true;
      this.pendingRuntimePromptManual_ = this.pendingRuntimePromptManual_ || manual;
      return;
    }
    // 已有面板继续持有自己的席位；本次手动意图仅排队，不能提前释放或创建第二个面板。
    if (this.updateDialogCtrl_ !== null) {
      this.pendingRuntimePrompt_ = true; this.pendingRuntimePromptManual_ = this.pendingRuntimePromptManual_ || manual; return;
    }
    // 自动提示在开过游戏后直接消费。后台或隐私页期间仍保留手动意图，等宿主重新可见再展示。
    // 这些准入检查必须先于 claim，否则一次不展示的检查就会占住 App/关于页共用的席位。
    if (!manual && this.gameLaunchedThisSession) return
    if (this.showPrivacy || AppStorage.get<boolean>('amclHostPageVisible') !== true) {
      this.pendingRuntimePrompt_ = true; this.pendingRuntimePromptManual_ = this.pendingRuntimePromptManual_ || manual;
      UpdatePromptPresenter.defer(this.updatePresenterOwner, (): void => { this.drainUpdateDialogs_(); }); return;
    }
    const repository = RuntimeCatalogRepository.instance(this.context)
    const items: UpdateDialogItem[] = []; const targets: Record<string,string> = {}; let total = 0
    for (const state of this.getJdkManager_().listVersions()) {
      if (!state.updateAvailable || state.userImported) continue
      const build = repository.buildFor(state.version); if (build === undefined) continue
      const item: UpdateDialogItem = { id:state.version,title:'JDK ' + state.version + (state.rollback ? ' · 回退修复' : ''),
        current:state.installedTag || '旧安装',target:build.id,sizeLabel:formatBytes(build.archive.sizeBytes),
        description:(state.rollback ? state.stateText + '\n' : '') + build.notes.join('\n') }
      items.push(item); targets[state.version] = build.id + ':' + build.archive.sha256; total += build.archive.sizeBytes
    }
    if (items.length === 0) return
    const fingerprint = this.jdkChannel + ':' + JSON.stringify(targets)
    if (!manual && !runtimePromptDue(Date.now(),this.getPrefManager_().jdkDeferredAt,this.getPrefManager_().jdkDeferredTarget,fingerprint)) return
    // 只有确实存在允许提示的更新目标时才申请展示席位；空列表和有效延后均不能阻塞其他更新。
    if (!UpdatePromptPresenter.claim(this.updatePresenterOwner)) {
      this.pendingRuntimePrompt_ = true; this.pendingRuntimePromptManual_ = this.pendingRuntimePromptManual_ || manual;
      UpdatePromptPresenter.defer(this.updatePresenterOwner, (): void => { this.drainUpdateDialogs_(); }); return;
    }
    const defer = (): void => {
      this.getPrefManager_().jdkDeferredAt = Date.now(); this.getPrefManager_().jdkDeferredTarget = fingerprint
      this.closeUpdateDialog_()
    }
    try {
      this.updateDialogCtrl_ = new CustomDialogController({
        builder:UpdateDialog({ theme:this.theme,title:'JDK 更新',actionLabel:'更新所选 JDK',
          newVersion:this.jdkChannel === 'preview' ? '预览通道' : '稳定通道',currentVersion:'',
          releaseDate:repository.snapshot().issuedAt.substring(0,10),sizeLabel:formatBytes(total),
          showChangelogEntry:false,items:items,onLater:defer,
          onInstallItems:(versions: string[]): void => {
            this.closeUpdateDialog_(); this.showTasksSheet = true
            for (const version of versions) {
              const build = repository.buildFor(version)
              if (build === undefined || targets[version] !== build.id + ':' + build.archive.sha256 || !this.getJdkManager_().inspect(version).offerUpdate) {
                this.jdkCatalogStatus = '推荐已改变，请重新检查后选择更新'; continue
              }
              const started = Date.now(); const task = new JdkInstallTask(version,this.getJdkManager_(),started,true)
              this.registry.enqueue(task).then((): void => {
                this.updateJdkReadyState()
              }).catch((error: Error): void => {
                this.jdkCatalogStatus = 'JDK ' + version + ' 更新失败：' + error.message
              })
            }
          } }),
        autoCancel:true,cancel:(): void => {
          this.getPrefManager_().jdkDeferredAt = Date.now(); this.getPrefManager_().jdkDeferredTarget = fingerprint
          this.updateDialogCtrl_ = null; UpdatePromptPresenter.release(this.updatePresenterOwner); this.drainUpdateDialogs_()
        },customStyle:true,alignment:DialogAlignment.Center
      })
      this.updateDialogCtrl_.open()
    } catch (e) {
      // controller 构造或 open 失败时没有可关闭的面板，必须在这里释放刚取得的全局席位。
      this.updateDialogCtrl_ = null; UpdatePromptPresenter.release(this.updatePresenterOwner)
      this.jdkCatalogStatus = '无法打开 JDK 更新面板：' + (e as Error).message
    }
  }

  /** 打开更新日志页。 */
  private openChangelogPage_() {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/ChangelogPage' })
    } catch (e) {
      AppLogger.warn(TAG, 'push ChangelogPage failed', e, LOG_DOMAIN_UI)
    }
  }

  /** 其它页面请求打开网络诊断 Sheet（把 amcl_open_netdiag_nonce 置时间戳触发）。 */
  onOpenNetDiagReq(): void {
    if (!this.startupFinished_) return;
    if (this.openNetDiagNonce > 0) {
      this.showNetDiagSheet = true
    }
  }

  /** 自动复检只服务真实可见且前台的横幅；其它页面报告错误不能唤醒隐藏首页。 */
  onNetBannerChange(): void {
    if (this.netBannerVisible && this.launcherWorkVisible_ && this.launcherWorkForeground_) {
      this.startNetRecheck_()
    } else {
      this.stopNetRecheck_()
    }
  }

  /** 保留15秒周期，但慢请求不叠加；页面/Ability失活时清理定时器。 */
  private startNetRecheck_(): void {
    if (this.netRecheckTimer >= 0) return
    this.netRecheckTimer = setInterval(() => {
      this.runNetCheck_(false)
    }, 15000)
  }

  /** 同时最多一个真实请求；不能取消的网络调用允许自然结束，但旧页结果不回写UI。
   * 初次检查若因离页失效，回到前台后重试一次；周期复检失败保持已有横幅。 */
  private async runNetCheck_(initial: boolean): Promise<void> {
    if (this.netCheckBusy_ || !this.launcherWorkVisible_ || !this.launcherWorkForeground_) return
    const epoch: number = this.netCheckEpoch_
    this.netCheckBusy_ = true
    if (initial) this.netInitialCheckPending_ = false
    try {
      const ok: boolean = await quickConnectivityCheck()
      if (epoch !== this.netCheckEpoch_ || !this.launcherWorkVisible_ || !this.launcherWorkForeground_) {
        if (initial) this.netInitialCheckPending_ = true
        return
      }
      if (initial && !ok) this.netBannerText = '网络连接异常，下载 / 搜索可能不可用，点此检测'
      if (initial || ok) this.netBannerVisible = !ok
    } catch (_) { /* 检查失败不改变用户现有状态，也不阻止其它业务。 */ }
    finally {
      this.netCheckBusy_ = false
      if (this.netInitialCheckPending_ && this.launcherWorkVisible_ && this.launcherWorkForeground_) {
        this.runNetCheck_(true)
      }
    }
  }

  private stopNetRecheck_(): void {
    if (this.netRecheckTimer >= 0) {
      clearInterval(this.netRecheckTimer)
      this.netRecheckTimer = -1
    }
  }

  /**
   * 启动轻量网络自检（每冷启动一次）：疑似异常时点亮顶部横幅，引导用户做完整检测。
   * 只读心跳，不弹窗、不阻塞；正常则隐藏横幅。横幅显示后由 onNetBannerChange 启动周期复检。
   */
  private initNetworkCheck(): void {
    this.netInitialCheckPending_ = true
    this.runNetCheck_(true)
  }

  /**
   * 初始化加速网关：准备设备信息 → 握手 → 注入 native。
   *
   * 全程不抛异常、不阻塞 UI：握手失败只把原因写进 accelStatus 给设置页展示，
   * 下载自动走直连。加速是增强，不能因为它让人下不了东西。
   */
  private initRelay_(): void {
    if (!DistributionPolicy.allowPublisherServices()) { this.disableRelay_(); return }
    let client = getRelayClient()
    // deviceId 持久化，保证同一台设备在面板里是同一条记录（便于溯源与配额）
    let did = this.getPrefManager_().relayDeviceId
    if (did.length === 0) {
      did = generateDeviceId()
      this.getPrefManager_().relayDeviceId = did
    }
    client.setDeviceInfo({
      deviceId: did,
      appVersionCode: UpdateChecker.currentVersionCode(),
      appVersionName: APP_VERSION,
      model: deviceInfo.productModel,
      osVersion: deviceInfo.osFullName,
      abi: deviceInfo.abiList,
    })
    this.accelStatus = ''
    client.setEnabled(true).then((ok: boolean) => {
      // 旧握手可能晚于关闭/新握手返回；界面和JDK来源只能投影当前会话，不能复用
      // 旧Promise的ok重新打开加速，也不能用旧失败覆盖已经成功的新代次。
      const status = client.status()
      this.accelStatus = status.active ? 'ok' : status.lastError
      // 注入到 launch：加速生效时 JDK 也强制走官方源（见 JdkManager.getJdkDownloadSource）
      setAccelActive(status.active)
      AppLogger.info(TAG,
        `加速下载握手${ok ? '成功' : '失败'}${ok ? '' : '：' + this.accelStatus}`,
        LOG_DOMAIN_DOWNLOAD)
    })
  }

  /** 关闭加速：清 native 配置，恢复原有源偏好 */
  private disableRelay_(): void {
    getRelayClient().setEnabled(false)
    setAccelActive(false)
    this.accelStatus = ''
  }

  /**
   * 启动时初始化检查更新（aboutToAppear 调，同一进程用 autoUpdateCheckStarted 去重）：
   *   1. 即时红点：缓存目标与实际安装版本走相同的code/发行名/通道判据，无需联网。
   *   2. 自动联网：距上次成功检查满 24h 才拉 update.json。
   *      - 有新版 且 本次会话【尚未启动游戏】→ 弹更新提示框（+ 红点）。
   *      - 有新版 但 用户已点过「启动游戏」→ 只保留红点，不弹框（不打扰）。
   *      - 「稍后」后 24h 内不联网、不弹框，红点保留；期满后刷新 manifest 并再次弹框。
   */
  private initUpdateCheck(): void {
    if (this.autoUpdateCheckStarted) return
    this.autoUpdateCheckStarted = true
    let cur = UpdateChecker.currentVersionCode()
    // 上架轨（应用市场分发）：更新交由应用市场，App 内不做 GitHub 检查更新（不弹窗、不点红点）。
    // 未来方向：接入应用市场更新接口 / 跳转应用市场详情页。侧载轨保持 GitHub update.json 自检。
    if (DistributionPolicy.isStore()) return
    let hasCachedUpdate: boolean = UpdateChecker.hasCachedUpdate(
      cur, this.getPrefManager_().appUpdateLatestSeen(ProductBuildProfile.product,this.getPrefManager_().appUpdateChannel),UpdateChecker.currentVersionName(),
      this.getPrefManager_().appUpdateLatestName(ProductBuildProfile.product,this.getPrefManager_().appUpdateChannel),this.getPrefManager_().appUpdateChannel)
    this.updateDot = hasCachedUpdate
    let now: number = Date.now()
    if (!UpdateChecker.shouldRunAutoCheck(
      now,
      this.getPrefManager_().appUpdateLastCheck(ProductBuildProfile.product,this.getPrefManager_().appUpdateChannel),
      this.getPrefManager_().appUpdateDeferredAt(ProductBuildProfile.product,this.getPrefManager_().appUpdateChannel),
      hasCachedUpdate
    )) {
      AppLogger.debug(TAG,
        `auto update check throttled: cached=${hasCachedUpdate ? 'yes' : 'no'} `
          + `lastCheckAt=${this.getPrefManager_().appUpdateLastCheck(ProductBuildProfile.product,this.getPrefManager_().appUpdateChannel)} `
          + `deferredAt=${this.getPrefManager_().appUpdateDeferredAt(ProductBuildProfile.product,this.getPrefManager_().appUpdateChannel)}`,
        LOG_DOMAIN_UI)
      return
    }
    // 启动自动检查固定为正式源；后来收到 TestWant 也不能给这个请求补上测试候选。
    const source = SideloadUpdateTestSession.productionSource()
    const channel = this.getPrefManager_().appUpdateChannel
    UpdateChecker.checkForUpdate(source.urls, ProductBuildProfile.product,channel).then((res: UpdateCheckResult) => {
      if(channel !== this.getPrefManager_().appUpdateChannel) return
      SideloadUpdateTestSession.validateResult(res, source)
      this.applyUpdateResult(res)
      if (res.ok && res.hasUpdate && res.manifest !== null && !this.gameLaunchedThisSession
          && UpdateChecker.shouldShowAutoPrompt(Date.now(), this.getPrefManager_().appUpdateDeferredAt(ProductBuildProfile.product,this.getPrefManager_().appUpdateChannel))) {
        this.showUpdateDialog(res.manifest, false, source)
      }
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'auto update check failed', e, LOG_DOMAIN_UI)
    })
  }

  /** 把检查结果落到红点 + 持久化（节流时间戳 + latestSeen），手动/自动共用。 */
  private applyUpdateResult(res: UpdateCheckResult): void {
    if (!res.ok || res.manifest === null) return
    const channel=this.getPrefManager_().appUpdateChannel
    if((res.manifest.updateChannel ?? 'stable')!==channel) return
    this.getPrefManager_().rememberAppUpdate(ProductBuildProfile.product,channel,res.manifest.versionCode,
      UpdateChecker.targetKey(res.manifest,ProductBuildProfile.product))
    this.updateDot=res.hasUpdate
  }

  /** 用系统浏览器打开外部链接（release 下载页）。 */
  private openExternalUrl(url: string) {
    // store即便从旧缓存/错误兜底来到这里，也不恢复一般网页下载或更新跳转。
    if (DistributionPolicy.isStore()) return
    if (!url || url.length === 0) {
      try { this.getUIContext().getPromptAction().showToast({ message: '下载链接为空', duration: 2000 }) } catch (e) { /* */ }
      return
    }
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    }
    try {
      this.context.startAbility(want)
    } catch (e) {
      AppLogger.error(TAG, 'open url failed', e, LOG_DOMAIN_UI)
      try { this.getUIContext().getPromptAction().showToast({ message: '无法打开浏览器', duration: 2000 }) } catch (e2) { /* */ }
    }
  }

  private refreshLauncherLog() {    try {
      this.launcherLog = testNapi.amclLogRead(65536)
    } catch (e) {
      this.launcherLog = '读取日志失败: ' + formatError(e)
    }
  }

  /** 取 App 版本名 (versionName + versionCode)，失败返回空串。 */
  private appVersionLabel(): string {
    try {
      let info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      let name = info.versionName ?? ''
      let code = info.versionCode
      if (name.length === 0) return ''
      return name + ' (' + code + ')'
    } catch (e) {
      return ''
    }
  }

  /** 单次复制锁防止重复系统请求；应用摘要明确不夹带任何推测的历史游戏正文。 */
  private exportingAppLog: boolean = false

  private async exportLogToClipboard(): Promise<void> {
    if (this.exportingAppLog) return
    this.exportingAppLog = true
    try {
      AppLogger.flush()
      const log: string = testNapi.amclLogRead(65536)
      const env: DiagnosticEnv = { appVersion: this.appVersionLabel(),
        note: '当前应用诊断摘要；启动器日志尾部最多 64 KiB。游戏会话请在活动账本中单独查看与导出。' }
      const text: string = sanitizeLogForExport(DiagnosticBundle.buildEnvHeader(env)
        + '\n\n===== 启动器运行日志（最近 64 KiB）=====\n' + log, LogExportTarget.CLIPBOARD)
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text))
      this.statusMsg = '应用诊断摘要已复制'
      this.safeToast_(this.statusMsg)
    } catch (e) {
      this.statusMsg = '复制失败：' + formatError(e)
      this.safeToast_(this.statusMsg)
    } finally { this.exportingAppLog = false }
  }

  /** 最近游戏入口按历史活动身份导航，共用 Evidence 阅读器；不从所选版本猜测上一局。 */
  private async openLatestGameLog_(): Promise<void> {
    try {
      const store = getDownloadHistoryStore()
      await store.init(this.context)
      const epoch = this.recoveryPresentationEpoch_
      const snapshot = await store.readSnapshotAsync((): boolean => epoch !== this.recoveryPresentationEpoch_)
      const recent = snapshot.records.find((record: ActivityRecord): boolean => record.category === ActivityCategory.LAUNCH)
      if (recent === undefined) { this.safeToast_('尚无游戏活动，启动一次游戏后可在这里查看'); return }
      const params: Record<string, Object> = { 'activityId': recent.startedAt, 'view': 'logs' }
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/ActivityLogPage', params: params })
    } catch (e) { this.safeToast_('无法打开游戏日志：' + (e as Error).message) }
  }

  /**
   * 启动 MC 版本下载。
   *
   * 2026-05-23新增 fabricApi 参数：非 null 时在 MC 任务 DONE 后串行 enqueue
   * 一个 ResourceInstallTask将 Fabric API jar 装进 versions/<versionName>/mods/。
   * MC 任务失败 / cancel 时 promise reject，自动跳过伴随装载。
   */
  private beginDownload(gameVersion: string, loaderType: ModLoaderType | null,
    loaderVersion: string, versionName: string,
    fabricApi: RemoteVersion | null, fabricApiIconUrl: string = ''): void {
    // v6.5：registry.enqueue 会判重复 id 并拒绝，不再需要 Index 自己判 mcDownloading。
    let mcDir = this.mcRoot()
    let filesDir = this.context.filesDir
    const installIsolation = this.versionIsolation
    let adapter = new McVersionTask(gameVersion, loaderType, loaderVersion, versionName, mcDir, filesDir)
    this.statusMsg = '正在下载 ' + versionName + '...'
    let mcPromise = this.registry.enqueue(adapter)
    mcPromise.catch((e: Error) => {
      AppLogger.warn(TAG, 'enqueue MC task rejected', e, LOG_DOMAIN_DOWNLOAD)
      this.statusMsg = '下载启动失败: ' + e.message
    })
    if (fabricApi !== null) {
      // 串行调度：等 MC 任务 DONE 后才 enqueue Fabric API 任务。
      // 原因：ResourceInstallTask 需要 versionId 存在对应的版本目录才能装 mod，
      // 而 versions/<versionName>/ 是 MC 任务过程中才创建的。如果并发启动，
      // mod 可能装到一个空目录里，后续 MC 跳动时看不到。
      mcPromise.then(() => { this.enqueueFabricApiCompanion_(versionName, fabricApi, fabricApiIconUrl, mcDir, installIsolation, adapter.startedAtMs) })
        .catch((e: Error) => {
          // MC 失败 / cancel 不装 API，已在上面记 statusMsg，这里吃掉。
          AppLogger.info(TAG, `skip fabric-api install (MC task ended early): ${e.message}`, LOG_DOMAIN_DOWNLOAD)
        })
    }
  }

  private enqueueFabricApiCompanion_(versionName: string, fabricApi: RemoteVersion, iconUrl: string,
    mcDir: string, isolation: boolean, parentActivityId: number): void {
    const dm = DownloadManager.instance();
    const cache = getMetadataCacheStore();
    const mr = new ModrinthRepository(dm, cache, (): ModrinthSourceMode => getModrinthSourceMode(), 'AMCL/mod-install', (): boolean => this.cacheRemoteMeta);
    const cf = new CurseForgeRepository(dm, cache, 'AMCL/mod-install', (): boolean => true, (): boolean => this.cacheRemoteMeta);
    const request: ModInstallRequest = { mcDir: mcDir, versionId: versionName, versionIsolation: isolation,
      root: fabricApi, title: 'Fabric API', router: new ModSourceRouter([mr, cf]), optionalIds: [] };
    const task = new ModInstallTask(request);
    // 附属安装由这次游戏下载直接触发，保留真实父活动而非靠相近时间猜测。
    task.view.parentActivityId = parentActivityId;
    task.view.activityRelation = 'companion';
    if (iconUrl.length > 0) task.view.iconUrl = iconUrl;
    this.registry.enqueue(task).catch((e: Error): void => {
      this.statusMsg = 'Fabric API 安装失败：' + e.message;
      AppLogger.warn(TAG, this.statusMsg, e, LOG_DOMAIN_DOWNLOAD);
    });
  }

  /**
   * v6.5: registry listener 触发时被调用，做以下几件事：
   *   1. 检测刚进入终态的 MC 任务 → recordHistory + scanVersions + 状态栏
   *   2. 用 mcTerminalRecorded_ 去重，避免同一 task 多次写历史
   */
  private mcTerminalRecorded_: Set<string> = new Set<string>()
  /**
   * 已开过账本的 activityId（活动账本 · L2-b）。
   *
   * listener 会被每次进度 tick 触发，必须去重否则一个任务会反复 begin。
   * 用 activityId（= startedAtMs）而不是 task id 做 key —— 同一任务 retry 后
   * startedAtMs 会变，那本来就该算一条新活动、开新账本。
   */
  private ledgerBegun_: Set<number> = new Set<number>()

  private syncStatusFromRegistry_(): void {
    for (let v of this.registry.listAll()) {
      // JDK 的初次执行与重试共用出队身份；入口只提交意图，不提前开一个不同的账本。
      if (v.category === TaskCategory.JDK) {
        if (v.startedAtMs > 0 && !this.ledgerBegun_.has(v.startedAtMs)) {
          this.ledgerBegun_.add(v.startedAtMs)
          this.beginActivity_(ActivityCategory.JDK, v.title, v.startedAtMs, '', v.parentActivityId, v.activityRelation)
        }
        const jdkKey = 'jdk:' + v.id + ':' + v.startedAtMs.toString()
        if (v.startedAtMs > 0 && isTerminalState(v.state) && !this.mcTerminalRecorded_.has(jdkKey)) {
          this.mcTerminalRecorded_.add(jdkKey)
          this.addActivity_(ActivityCategory.JDK, v.title, this.terminalStatus_(v.state), v.startedAtMs, 'JDK 安装', v.errorMessage)
          this.updateJdkReadyState()
        }
        continue
      }
      // 附属 Fabric API 安装也拥有自己的账本，并能从父游戏下载记录回溯。
      if (v.category === TaskCategory.MOD && v.activityRelation === 'companion' && v.startedAtMs > 0) {
        if (!this.ledgerBegun_.has(v.startedAtMs)) {
          this.ledgerBegun_.add(v.startedAtMs)
          this.beginActivity_(ActivityCategory.MOD_INSTALL, v.title, v.startedAtMs, '', v.parentActivityId, v.activityRelation)
        }
        const companionKey: string = 'companion:' + v.startedAtMs
        if (isTerminalState(v.state) && !this.mcTerminalRecorded_.has(companionKey)) {
          this.mcTerminalRecorded_.add(companionKey)
          this.addActivity_(ActivityCategory.MOD_INSTALL, v.title, this.terminalStatus_(v.state), v.startedAtMs, '附属组件安装', v.errorMessage)
        }
      }
      // 整合包安装完成 → 刷新版本列表让新版本出现（去重一次）+ 写活动记录
      if (v.category === TaskCategory.MODPACK) {
        // 账本开账：与 MC 下载同理，等 startedAtMs 就位（= 活动记录主键）
        if (v.startedAtMs > 0 && !this.ledgerBegun_.has(v.startedAtMs)) {
          this.ledgerBegun_.add(v.startedAtMs)
          this.beginActivity_(ActivityCategory.MODPACK, v.title, v.startedAtMs, '', v.parentActivityId, v.activityRelation)
        }
        if (isTerminalState(v.state)) {
          // 同标题重装/重试是新的安装尝试；不能用永久 taskId 吞掉其终态和启动参数应用。
          let dedupMp = 'mp:' + v.id + ':' + v.startedAtMs.toString() + ':' + v.state
          if (!this.mcTerminalRecorded_.has(dedupMp)) {
            this.mcTerminalRecorded_.add(dedupMp)
            this.recordModpackActivity_(v)
            if (v.state === UnifiedTaskState.DONE) {
              this.statusMsg = v.title + ' 整合包安装完成'
              this.applyModpackResult_(v.id)
              this.scanVersions()
            } else if (v.state === UnifiedTaskState.ERROR) {
              this.statusMsg = '整合包安装失败: ' + v.errorMessage
            }
          }
        }
        continue
      }
      if (v.category !== TaskCategory.MC_VERSION) continue
      // 分类用于外观，接口资格由真实 adapter 决定；修复活动同样按每次尝试结账，
      // 不能读取它不存在的 getTask/dlState，也不能只记录初次 enqueue 的 Promise。
      const service = this.registry.getAdapter(v.id)
      if (service instanceof RepairTask || service instanceof ForgeRepairTask) {
        if (v.startedAtMs > 0 && !this.ledgerBegun_.has(v.startedAtMs)) {
          this.ledgerBegun_.add(v.startedAtMs)
          this.beginActivity_(ActivityCategory.REPAIR, v.title, v.startedAtMs, v.title, v.parentActivityId, v.activityRelation)
        }
        const repairKey = 'repair:' + v.id + ':' + v.startedAtMs.toString()
        if (v.startedAtMs > 0 && isTerminalState(v.state) && !this.mcTerminalRecorded_.has(repairKey)) {
          this.mcTerminalRecorded_.add(repairKey)
          this.addActivity_(ActivityCategory.REPAIR, v.title, this.terminalStatus_(v.state), v.startedAtMs, v.currentLabel, v.errorMessage)
          if (v.state === UnifiedTaskState.DONE) this.scanVersions()
        }
        continue
      }
      if (!(service instanceof McVersionTask)) continue

      // 活动账本（L2-b）：任务真正开始跑（拿到 startedAtMs）时开账本。
      // 不在 enqueue 时开 —— 排队中的任务 startedAtMs 还是 0，而 activityId 必须
      // 等于活动记录的主键（recordHistory 用的就是 startedAtMs），否则账本与记录对不上。
      let mcAd = this.registry.getAdapter(v.id)
      if (mcAd) {
        let sa = (mcAd as object as McVersionTask).startedAtMs
        if (sa > 0 && !this.ledgerBegun_.has(sa)) {
          this.ledgerBegun_.add(sa)
          this.beginActivity_(ActivityCategory.DOWNLOAD, v.title, sa, v.title, v.parentActivityId, v.activityRelation)
        }
      }

      let dedup = v.id + ':' + v.state
      if (!isTerminalState(v.state)) {
        // 仍在跑：清掉这个 task 上一次终态的去重标记，下次终态时可再次写
        // 这样支持"失败 → retry → 成功"两次写入
        this.mcTerminalRecorded_.delete(v.id + ':' + UnifiedTaskState.DONE)
        this.mcTerminalRecorded_.delete(v.id + ':' + UnifiedTaskState.ERROR)
        this.mcTerminalRecorded_.delete(v.id + ':' + UnifiedTaskState.ABORTED)
        continue
      }
      if (this.mcTerminalRecorded_.has(dedup)) continue
      this.mcTerminalRecorded_.add(dedup)

      // 拿底层 task 写历史
      let adapter = this.registry.getAdapter(v.id)
      if (!adapter) continue
      let mcAdapter = adapter as object as McVersionTask
      let task = mcAdapter.getTask()
      let status: string = v.state === UnifiedTaskState.DONE ? 'success'
                          : v.state === UnifiedTaskState.ERROR ? 'failed' : 'aborted'
      this.recordHistory(task, mcAdapter.startedAtMs, mcAdapter.getMaxBytesEver(), status)

      if (v.state === UnifiedTaskState.DONE) {
        this.statusMsg = v.title + ' 下载完成'
        this.scanVersions()
        this.mcVersion = v.title
        this.savePreferences()
      } else if (v.state === UnifiedTaskState.ERROR) {
        this.statusMsg = '下载失败: ' + v.errorMessage
        // 出错时主动弹 sheet 让用户看到错误信息
        this.showTasksSheet = true
      } else {
        this.statusMsg = '已取消: ' + v.title
      }
    }
  }

  /** 整合包安装终态 → 写活动记录（成功/失败），让"最近活动"和活动页可见。 */
  private recordModpackActivity_(v: UnifiedTaskView): void {
    let status = this.terminalStatus_(v.state)
    let startedAt = v.startedAtMs > 0 ? v.startedAtMs : Date.now()
    let subtitle = '整合包'
    let errMsg = ''
    if (v.state === UnifiedTaskState.DONE) {
      let adapter = this.registry.getAdapter(v.id)
      if (adapter) {
        let mp = adapter as object as ModpackInstallTask
        let res = mp.getResult()
        if (res !== null) {
          subtitle = res.missing.length > 0 ? ('整合包 · ' + res.missing.length + ' 项缺失') : '整合包'
        }
      }
    } else {
      errMsg = v.errorMessage
    }
    this.addActivity_(ActivityCategory.MODPACK, v.title, status, startedAt, subtitle, errMsg)
  }

  /**
   * 整合包安装完成后：把推荐启动参数（user_jvm_args.txt 解析）应用到该版本的启动覆盖，
   * 并把缺失项数反映到状态栏。决策5：整合包附带的特殊启动配置必须生效。
   */
  private applyModpackResult_(taskId: string): void {
    let adapter = this.registry.getAdapter(taskId)
    if (!adapter) return
    let mp = adapter as object as ModpackInstallTask
    let res = mp.getResult()
    if (res === null) return
    let args = res.recommendedJvmArgs
    let xmx = res.recommendedMaxMemMb
    if ((args !== undefined && args.length > 0) || xmx > 0) {
      // 合并而非整体覆盖：读现有 override，仅写本次解析出的字段，保留用户已设的 jdkVersion 等。
      let ov: VersionLaunchOverride
      try {
        ov = this.getPrefManager_().getVersionOverride(res.versionName)
      } catch (e) {
        ov = { xmx: 0, jdkVersion: '', customJvmArgs: '', gameLanguage: '' }
      }
      if (xmx > 0) ov.xmx = xmx
      if (args !== undefined && args.length > 0) ov.customJvmArgs = args
      try {
        this.getPrefManager_().setVersionOverride(res.versionName, ov)
        AppLogger.info(TAG, `applied modpack recommended jvm to ${res.versionName}: xmx=${xmx} args="${args}"`, LOG_DOMAIN_LAUNCH)
      } catch (e) {
        AppLogger.warn(TAG, 'apply modpack jvm override failed', e as Error, LOG_DOMAIN_LAUNCH)
      }
    }
    if (res.missing.length > 0) {
      this.statusMsg = res.versionName + ' 安装完成，但有 ' + res.missing.length + ' 项缺失'
    }
  }

  /**
   * Phase 5.3: 把终态任务存入下载历史 LRU。
   * fileCount 估算：libraries / assets phase 的 total（文件数）+ 其他已完成阶段每 1 计 1。
   * totalBytes 估算：跨 phase 监听到的最大 bytesTotal（一般 = assets 阶段总字节）。
   */
  private recordHistory(t: DownloadTask, startedAtMs: number, maxBytesTotal: number, status: string): void {
    let record = buildHistoryRecordFromTask(t, startedAtMs, maxBytesTotal, status)
    // 活动账本封账（L2-b）：与活动记录同一主键、同一时刻
    const commit = this.endActivity_(startedAtMs, status,
      (record.errorMessage && record.errorMessage.length > 0) ? record.errorMessage : '下载完成',
      '', { category: record.category ?? ActivityCategory.DOWNLOAD, title: record.title ?? record.versionName })
    record.mcDir = this.mcRoot()
    commit.then((): Promise<void> => getDownloadHistoryStore().add(record)).then(() => {
      this.refreshRecentActivities_()
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'DownloadHistory.add failed', e, LOG_DOMAIN_DOWNLOAD)
    })
  }

  /**
   * 打开错误 Sheet 的**唯一入口**（M3）。
   *
   * 收敛前有两类打开方式各写一遍状态：冷启动会话恢复直接塞三个 @State，别处想打开就
   * 没办法。现在统一按 sessionKey 从持久化的活动记录取快照 —— 冷启动、活动记录
   * 「查看详情」、（后续 M4/M5 的）消息中心与灵动弹窗都走这一个函数。
   *
   * 与 `shouldDiagnose` 门控的关系（§4.3）：门控只管**是否自动弹**。走到这个函数时
   * 说明要么已经判定该弹，要么是用户**主动点开**的 —— 后者即使 `not_diagnosable`
   * 也必须允许，用户明确想看日志，这时候拦他没有道理。
   *
   * @param sessionKey 会话主键（= ActivityRecord.startedAt）
   */
  private openErrorSheetBySession_(sessionKey: number, expectedEpoch: number | undefined = undefined): Promise<boolean> {
    if (sessionKey <= 0) return Promise.resolve(false)
    let store = getDownloadHistoryStore()
    return store.waitReady().then((): boolean | Promise<boolean> => {
      if (!this.startupFinished_ || !this.startupRouteVisible_ || this.showPrivacy || this.updateDialogCtrl_ !== null) return false;
      if (this.showMcErrorSheet && this.mcErrorSessionKey !== sessionKey) return false;
      if (expectedEpoch !== undefined && (expectedEpoch !== this.recoveryPresentationEpoch_
        || AppStorage.get<boolean>('amclHostPageVisible') === false)) return false
      let rec = store.findByStartedAt(sessionKey)
      if (rec === null) {
        this.safeToast_('这条记录已被清理，无法查看详情')
        return false
      }
      let snap = resolveSessionSnapshot(rec, this.mcRoot())
      if (snap.logExpired && expectedEpoch === undefined) {
        // 日志已被后续会话挤出保留窗口：老实说清楚，不要让用户点进一个空白 Sheet
        this.safeToast_('该次日志已不可用，可在“设置 → 日志”调整保留数量')
        return false
      }
      // 恢复结局可以有准确退出事实但没有正文；展示真实摘要及缺失说明，不伪造完整日志。
      let logTail = snap.logExpired ? '本次日志正文不可用或尚未完整归档，退出事实与活动结局仍保留。' : readSnapshotLogTail(snap)
      this.lastMcSession = snapshotToSessionInfo(snap)
      this.lastMcSessionSummary = (rec.errorMessage && rec.errorMessage.length > 0)
        ? rec.errorMessage
        : SessionMarker.extractErrorSummary(logTail)
      this.lastMcSessionLogTail = logTail
      this.mcErrorSessionKey = snap.sessionKey
      // 已保存的分享结果 / AI 正文一并带回，用户不必重新分析
      this.mcErrorLsId = snap.lsId
      this.mcErrorLsUrl = snap.lsUrl
      this.mcErrorLsToken = snap.lsToken
      this.mcErrorLsSharedAt = snap.lsSharedAt
      this.mcErrorAiText = loadSessionAiText(snap.aiPath)
      const shown: Promise<boolean> = this.waitForErrorSheet_(sessionKey);
      this.showMcErrorSheet = true
      AppLogger.info(TAG, 'error sheet reopened: key=' + sessionKey
        + ' log=' + snap.logPath + ' archive=' + snap.logArchiveIndex
        + ' exact=' + snap.logExact + ' ai=' + (this.mcErrorAiText.length > 0),
        LOG_DOMAIN_LAUNCH)
      return shown
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'openErrorSheetBySession failed', e, LOG_DOMAIN_LAUNCH)
      return false
    })
  }

  /** @Watch：别的页面把 sessionKey 写进 AppStorage 请求打开错误 Sheet（活动记录「查看详情」）。 */
  onOpenErrorSheetReq(): void {
    if (!this.startupFinished_ || this.showPrivacy || this.updateDialogCtrl_ !== null) return;
    const key: number = this.openErrorSheetSession;
    if (key <= 0 || (this.showMcErrorSheet && this.mcErrorSessionKey !== key)) return;
    this.openErrorSheetBySession_(key).then((shown: boolean): void => {
      // 只有同一个请求确实显示后才消费，期间到来的新会话请求不能被旧闭包清掉。
      if (shown && this.openErrorSheetSession === key) this.openErrorSheetSession = 0;
    });
  }

  private safeToast_(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2400 })
    } catch (e) { /* UI 已销毁，忽略 */ }
  }

  /**
   * @Watch：前台收到消息 → 弹自定义灵动弹窗（M5.6）。
   *
   * 只有前台会走到这里（后台由 AppNotifier 发系统通知）。用自定义浮层而不是
   * promptAction.showToast，因为后者不可点击、也放不下标题+正文两行，
   * 而「点一下回到错误 Sheet」正是这条消息的意义所在。
   */
  onPendingToast(): void {
    if (!this.startupFinished_) return;
    let id = this.pendingToastMsgId
    if (id.length === 0) return
    this.pendingToastMsgId = ''   // 立即清空，允许下一条
    let store = getAppMessageStore()
    store.init(this.context).then(() => {
      let hit: AppMessage | null = null
      for (let m of store.list()) {
        if (m.id === id) { hit = m; break }
      }
      if (hit === null) return
      this.toastTitle = hit.title
      this.toastBody = hit.body
      this.toastMsgId = hit.id
      this.toastSessionKey = 0
      if (hit.action.type === AppMessageActionType.OPEN_ERROR_SHEET) {
        let k = Number.parseInt(hit.action.payload, 10)
        if (!Number.isNaN(k)) this.toastSessionKey = k
      }
      this.unreadCount = store.unreadCount()
      this.toastVisible = true
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'onPendingToast failed', e, LOG_DOMAIN_UI)
    })
  }

  /** 点灵动弹窗：标已读 + 回到对应会话的错误 Sheet。 */
  private onToastTap_(): void {
    let id = this.toastMsgId
    let key = this.toastSessionKey
    this.toastVisible = false
    if (id.length > 0) {
      getAppMessageStore().markRead(id).then(() => { refreshUnreadCount() })
        .catch((e: Error) => { AppLogger.warn(TAG, 'markRead failed', e, LOG_DOMAIN_UI) })
    }
    if (key > 0) this.openErrorSheetBySession_(key)
  }

  // v6.5: cancel/perform/retry/pause/resume/resetDownloadUiState 全部迁出到 DownloadTaskRegistry。
  // 调用入口：DownloadTasksSheet 内部按钮 → registry.cancel/pause/resume/retry(id)

  private isMcDownloading_(): boolean {
    if (this.tasksRev < 0) return false;
    for (const v of this.registry.listByCategory(TaskCategory.MC_VERSION)) {
      if (isActiveState(v.state) || v.state === UnifiedTaskState.PAUSED || v.state === UnifiedTaskState.WAITING) return true;
    }
    if (this.mcVersion.length === 0) return false;
    const dir = resourceKindToInstallDir(ResourceKind.MOD, this.mcRoot(), this.mcVersion, this.versionIsolation);
    if (modInstallationActive(dir)) return true;
    for (const v of this.registry.listByCategory(TaskCategory.MOD)) {
      if ((v.id.startsWith('mod-plan:' + dir + ':') || v.id.endsWith('@dir=' + dir))
        && (isActiveState(v.state) || v.state === UnifiedTaskState.WAITING)) return true;
    }
    return false;
  }

  // ==================== UI 构建 ====================

  /**
   * 构造单个 HDS dock tab 的 BottomTabBarStyle（官方推荐做法）。
   *
   * 按 HarmonyOS 官方文档 ui-design-hds-component-material 的 MENU_CONFIG 范式，
   * 但图标/文字色用 BottomTabBarStyle.iconStyle / labelStyle 这一对官方 API
   * 直接驱动，不再用 SymbolGlyphModifier 上的双 sys.color fontColor —— 后者
   * 在玻璃 dock 上对比度不够，浅色态会偏白。
   *
   * 颜色来源完全跟主题：
   *   · 未选中：theme.tabInactive （浅色 = #6B7280 深灰，深色 = #B8BCC2 浅灰）
   *   · 选中：  theme.primary     （浅色 = #007DFF，深色 = #317AF7）
   *
   * 之所以做成方法不做成 const 数组：每个 tab 的两个 modifier 都是 new 出来的实例，
   * 直接放到 class field 里会被多次共享导致主题切换时状态错乱。
   */
  private buildDockTabBar(iconRes: Resource, label: string): BottomTabBarStyle {
    // SymbolGlyphModifier 只指定图标资源 + 单色渲染；颜色让外层 iconStyle 给
    let normal = new SymbolGlyphModifier(iconRes)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    let selected = new SymbolGlyphModifier(iconRes)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    return new BottomTabBarStyle({ normal, selected }, label)
      .iconStyle({
        selectedColor: this.theme.primary,
        unselectedColor: this.theme.tabInactive,
      })
      .labelStyle({
        selectedColor: this.theme.primary,
        unselectedColor: this.theme.tabInactive,
      })
  }

  /**
   * 准备阶段保持主内容的布局与组件实例，避免开放首页时重新构造整棵 UI 树；
   * 隐藏同时禁止输入，真实首页的可见与点击资格由同一个就绪状态控制。
   */
  build() {
    Stack() {
      if (this.launcherInitializationComplete_) {
        this.LauncherContent_()
      }
      if (!this.startupFinished_) {
        StartupSplash({
          ready: this.launcherStartupReady_ && this.startupHomeLaidOut_,
          failed: this.launcherStartupFailed_,
          isDark: resolveIsDark(this.themeMode, this.systemIsDark),
          active: this.startupRouteVisible_ && this.launcherWorkForeground_,
          reducedMotion: this.startupReduced_,
          targetRect: this.startupTarget_,
          onFirstFrame: (): void => { this.beginLauncherPreparation_(); },
          onReveal: (): void => { this.revealStartupHome_(); },
          onFinished: (): void => { this.finishStartup_(); },
          onRetry: (): void => { this.retryStartup_(); }
        })
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.startupRevealed_ ? this.theme.bgPrimary
      : resolveIsDark(this.themeMode, this.systemIsDark) ? '#101114' : '#FFFFFF')
  }

  /** 原主界面与全部 Sheet 仍由同一组件持有，准备期间不消费用户输入。 */
  @Builder
  private LauncherContent_() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // API23 uses adaptive floating material; LauncherTabsStyle supplies the API20–22 fallback.
        HdsTabs({
          barPosition: BarPosition.End,
          controller: this.tabController,
        }) {
          TabContent() {
            HomeTab({
              startupRevealed: this.startupRevealed_,
              startupHandoffPending: !this.startupFinished_,
              onStartupAxeRect: (rect: StartupTargetRect): void => { this.onStartupTarget_(rect); },
              storeManager: DistributionPolicy.isStore(),
              canRunGame: this.canRunGame_,
              managerAction: this.storeManagerAction_,
              managerLabel: storeManagerActionLabel(this.storeManagerAction_),
              managerStatus: this.storeManagerStatus_,
              hasExistingGame: this.storeHasSession_,
              onManagerAction: (): void => { this.handleStoreManagerAction_() },
              onReturnGame: (): void => { this.returnExistingGame_() },
              theme: this.theme,
              topSafeHeight: this.topSafeHeight,
              bottomSafeHeight: this.bottomSafeHeight,
              isLandscape: this.isLandscape,
              showUpdateDot: this.updateDot,
              unreadBadge: formatBadge(this.unreadCount),
              onOpenMessages: () => {
                try { this.getUIContext().getRouter().pushUrl({ url: 'pages/MessageCenterPage' }) }
                catch (e) { AppLogger.warn(TAG, 'open message center failed', e, LOG_DOMAIN_UI) }
              },
              recentActivities: this.recentActivities,
              mcVersion: this.mcVersion,
              mcDir: this.mcRoot(),
              mcXmx: this.mcXmx,
              selectedJdkVersion: this.selectedJdkVersion,
              effectiveJdkVersion: this.effectiveJdkVersion,
              availableVersions: this.availableVersions,
              jdkReady: this.jdkReady,
              jdkExtractProgress: this.jdkExtractProgress,
              isRunning: this.isRunning,
              mcDownloading: this.isMcDownloading_(),
              statusMsg: this.statusMsg,
              versionIsolation: this.versionIsolation || isIsolatedModpackInstance(this.mcRoot(), this.mcVersion),
              accountUsername: this.accountUsername,
              accountTypeLabel: this.accountTypeLabel,
              accountUuid: this.accountUuid,
              accountSkinUrl: this.accountSkinUrl,
              installedModsCount: this.installedModsCount,
              lastPlayedAt: this.lastPlayedAt,
              onLaunch: () => { this.launchMC() },
              onGoDownload: () => { this.jumpToDownloadSub(0) },
              onSelectVersion: (ver: string) => {
                this.selectManagedVersion_(ver)
              },
              onDeleteVersion: (ver: string) => { this.deleteInstalledVersion(ver) },
              onOpenVersionManager: () => { this.versionManagerInitialStep = 'list'; this.showVersionManager = true },
              onOpenAccountList: () => { this.showAccountListSheet = true },
              onOpenInstalledMods: () => { this.openInstalledResourcesSheet(this.mcVersion, ResourceKind.MOD) },
              // 2026-05-24：HomeTab 右上 ⚙ → 切设置 Tab（index=2）。
              // HdsTabsController.changeIndex 走系统动画；同步 currentTab 让 dock 高亮跟上。
              onOpenSettings: () => {
                this.tabController.changeIndex(2)
                this.currentTab = 2
              },
            })
          }
          .tabBar(this.buildDockTabBar($r('sys.symbol.house_fill'), '首页'))

          TabContent() {
            DownloadTab({
              theme: this.theme,
              topSafeHeight: this.topSafeHeight,
              isLandscape: this.isLandscape,
              bottomSafeHeight: this.bottomSafeHeight,
              // 受控二级 Tab 导航命令：sheet「安装」等入口据此定位到模组/资源包/光影/版本子页
              navCommand: this.dlNavCommand,
              jdkVersions: this.jdkVersions,
              // 下载页直接展示当前通道、目录检查结果和重试入口；目录失败也有明确的恢复动作。
              jdkChannel: this.jdkChannel,
              jdkChecking: this.jdkChecking,
              jdkCatalogStatus: this.jdkCatalogStatus,
              onRefreshJdkCatalog: (): void => { this.checkRuntimeUpdates_(true); },
              jdkDownloadMsg: '',         // v6.5：JDK 进度全部在 DownloadTasksSheet 里展示
              jdkDownloadPercent: 0,
              // P1-MODS Phase 1.7：模组浏览页的上下文（.minecraft 根目录 + 当前版本 + 隔离开关）
              mcDir: this.mcRoot(),
              filesDir: this.context.filesDir,
              taskRevision: this.tasksRev,
              onRecoverMc: (session: McInstallSession): void => {
                if (session.mcDir !== this.mcRoot()) return
                const loader: ModLoaderType | null = session.loaderType.length > 0 ? session.loaderType as ModLoaderType : null
                this.beginDownload(session.gameVersion, loader, session.loaderVersion, session.versionName, null)
                this.showTasksSheet = true
              },
              currentMcVersion: this.mcVersion,
              versionIsolation: this.versionIsolation,
              onSelectGameVersion: (ver: string, category: string) => {
                this.configGameVersion = ver
                this.configGameCategory = category
                this.showVersionConfig = true
              },
              onJdkDelete: (version: string) => {
                // writer/use 租约或文件系统错误都可能拒绝删除；反馈必须与实际结果一致。
                const deleted = this.getJdkManager_().deleteVersion(version)
                this.updateJdkReadyState()
                this.jdkExtractProgress = deleted ? 'JDK ' + version + ' 已删除'
                  : 'JDK ' + version + ' 删除失败，请关闭游戏或相关安装任务后重试'
                if (!deleted) this.showToast_(this.jdkExtractProgress)
              },
              onJdkDownload: (version: string) => {
                // v6.5：走 registry —— 任务在 DownloadTasksSheet 中呈现
                this.statusMsg = '添加 JDK ' + version + ' 下载任务...'
                this.showTasksSheet = true  // 自动弹开 sheet 让用户看到
                let jdkStartedAt = Date.now()
                let task = new JdkInstallTask(version, this.getJdkManager_(), jdkStartedAt)
                this.registry.enqueue(task).then(() => {
                  this.updateJdkReadyState()
                }).catch((e: Error) => {
                  AppLogger.warn(TAG, 'enqueue JDK task rejected', e, LOG_DOMAIN_DOWNLOAD)
                  this.statusMsg = 'JDK 下载启动失败: ' + e.message
                  if (e.message.indexOf('已在进行中') < 0) {
                  }
                })
              },
              // 「更新」：与下载同一条任务链，唯一差别是 forceReinstall=true。
              // ⚠️ 不传 force 会命中 JdkInstaller 的幂等门（tag 过期在新语义下仍算已装），
              //   表现为点了瞬间报"安装完成"而什么都没做，且不报错。
              onJdkUpdate: (version: string) => {
                this.statusMsg = '添加 JDK ' + version + ' 更新任务...'
                this.showTasksSheet = true
                let jdkStartedAt = Date.now()
                let task = new JdkInstallTask(version, this.getJdkManager_(), jdkStartedAt, true)
                this.registry.enqueue(task).then(() => {
                  this.updateJdkReadyState()
                }).catch((e: Error) => {
                  AppLogger.warn(TAG, 'enqueue JDK update task rejected', e, LOG_DOMAIN_DOWNLOAD)
                  this.statusMsg = 'JDK 更新启动失败: ' + e.message
                  if (e.message.indexOf('已在进行中') < 0) {
                  }
                })
              },
              onJdkImport: () => { this.importLocalJdk_() },
              jdkImporting: this.jdkImporting,
              // B-1 修复（2026-05-26）：按版本查 registry —— 不再用全局锁阻断其他版本
              // 同版本重复点会被 registry 用 id='jdk:'+version 拒绝，不需要 UI 防抖
              isJdkDownloading: (version: string): boolean => {
                let a = this.registry.getAdapter('jdk:' + version)
                return a !== null && !isTerminalState(a.view.state)
              },
              onModStatusMessage: (msg: string) => {
                this.statusMsg = msg
              },
              onOpenDownloadTask: (id: string): void => {
                this.downloadTaskFocusId = id; this.showTasksSheet = true
              },
              // P0 修复 #4：传给 ModBrowsePage 用于版本存在性校验
              availableVersions: this.availableVersions,
              // P1-MODS：把用户偏好真正接通到 ModrinthRepository / CurseForgeRepository
              modSource: this.modSource,
              cacheRemoteMeta: this.cacheRemoteMeta,
              // v6.5: ModBrowsePage 改为直接 registry.enqueue，Index 不再中转模组下载状态。
            })
          }
          .tabBar(this.buildDockTabBar($r('sys.symbol.arrow_down_to_line'), '下载'))

          TabContent() {
            SettingsTab({
              canRunGame: this.canRunGame_,
              mcDir: this.mcRoot(),
              mcVersion: this.mcVersion,
              theme: this.theme,
              topSafeHeight: this.topSafeHeight,
              bottomSafeHeight: this.bottomSafeHeight,
              mcXmx: this.mcXmx,
              xmxMax: this.xmxSliderMax,
              virtualMemoryMode: this.virtualMemoryMode,
              themeMode: this.themeMode,
              immersiveLight: this.immersiveLight,
              immersiveLightSaving: this.immersiveLightSaving,
              immersiveLightHasPresets: immersiveLightCapabilities().floatingSupported,
              immersiveLightStatus: immersiveLightStatus(this.immersiveLight),
              immersiveLightSaveError: this.immersiveLightSaveError,
              visible: this.currentTab === 2,
              onSectionBackReady: (handler: (() => boolean) | undefined): void => { this.settingsSectionBack_ = handler },
              onImmersiveLightChange: (next: ImmersiveLightPreferences): void => { this.changeImmersiveLight_(next) },
              selectedJdkVersion: this.selectedJdkVersion,
              versionIsolation: this.versionIsolation,
              useNewWindow: this.useNewWindow,
              tabletIndependentGameProcess: this.tabletIndependentGameProcess,
              tabletProcessActive: ProductInputProfile.selection().isolatedGameProcess,
              tabletProcessSaving: this.tabletProcessSaving,
              tabletProcessMessage: this.tabletProcessMessage,
              onTabletProcessChange: (enabled: boolean): void => {
                this.changeTabletProcess_(enabled).catch((error: Error): void => {
                  AppLogger.warn(TAG, 'Tablet process setting unavailable', error, LOG_DOMAIN_LAUNCH)
                })
              },
              storageLocation: this.storageLocation,
              externalAvailable: GameStorage.isExternalSupported(),
              externalPathHint: GameStorage.externalMcDir(),
              onStorageLocationChange: (loc: string) => { this.handleStorageLocationChange(loc) },
              onXmxChange: (value: number) => {
                this.mcXmx = value
                this.savePreferences()
              },
              onVirtualMemoryModeChange: (isOn: boolean) => {
                this.virtualMemoryMode = isOn
                this.getPrefManager_().virtualMemoryMode = isOn
              },
              onThemeChange: (mode: ThemeMode) => {
                this.themeMode = mode
                this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
                  this.applyTheme()
                })
                this.savePreferences()
              },
              onVersionIsolationChange: (isOn: boolean) => {
                this.changeManagedIsolation_(isOn)
              },
              onNewWindowChange: (isOn: boolean) => {
                this.useNewWindow = isOn
                this.savePreferences()
              },
              onOpenLog: () => {
                this.showLogDialog = true
                this.refreshLauncherLog()
              },
              onExportLog: () => { this.exportLogToClipboard() },
              onOpenGameLog: () => { this.openLatestGameLog_() },
              modSource: this.modSource,
              cacheRemoteMeta: this.cacheRemoteMeta,
              modConcurrentDownloads: this.modConcurrentDownloads,
              onModSourceChange: (value: string) => {
                this.modSource = value
                this.getPrefManager_().modSource = value
              },
              accelDownload: this.accelDownload,
              accelStatus: this.accelStatus,
              onAccelDownloadChange: (isOn: boolean) => {
                this.accelDownload = DistributionPolicy.allowPublisherServices() && isOn
                this.getPrefManager_().accelDownload = isOn
                if (isOn) {
                  this.initRelay_()
                } else {
                  this.disableRelay_()
                }
              },
              onCacheRemoteMetaChange: (isOn: boolean) => {
                this.cacheRemoteMeta = isOn
                this.getPrefManager_().cacheRemoteMeta = isOn
              },
              onModConcurrentDownloadsChange: (value: number) => {
                this.modConcurrentDownloads = value
                this.getPrefManager_().modConcurrentDownloads = value
              },
              jdkSource: this.jdkSource,
              jdkVersions: this.jdkVersions,
              jdkChannel: this.jdkChannel,
              jdkWebEnabled: this.jdkWebEnabled,
              jdkAutoCheck: this.jdkAutoCheck,
              jdkChecking: this.jdkChecking,
              jdkHasUpdate: this.jdkHasUpdate,
              jdkCatalogStatus: this.jdkCatalogStatus,
              onCheckJdkUpdate: (): void => { this.checkRuntimeUpdates_(true); },
              onJdkChannelChange: (channel: string): void => {
                this.jdkChannel = channel; this.getPrefManager_().jdkChannel = channel
                this.getPrefManager_().jdkLastCheck = 0
                // configure 先失效旧通道请求，即使当前已有检查，队列也会以新通道重查。
                RuntimeCatalogRepository.instance(this.context).configure(channel,this.jdkSource,this.jdkWebEnabled)
                  .then((): void => { this.updateJdkReadyState(); this.checkRuntimeUpdates_(true); })
                  .catch((e: Error): void => { this.jdkCatalogStatus = '切换通道失败：' + e.message; })
              },
              onJdkAutoCheckChange: (enabled: boolean): void => {
                this.jdkAutoCheck = enabled; this.getPrefManager_().jdkAutoCheck = enabled
                if (enabled) { this.runtimeAutoCheckStarted_ = false; this.initRuntimeUpdateCheck_(); }
              },
              onJdkWebChange: (enabled: boolean): void => {
                this.jdkWebEnabled = enabled; this.getPrefManager_().jdkWebEnabled = enabled; setJdkWebEnabled(enabled)
                if (!enabled && this.jdkSource === 'web') {
                  this.jdkSource = 'auto'; this.getPrefManager_().jdkSource = 'auto'; setJdkDownloadSource('auto')
                }
                RuntimeCatalogRepository.instance(this.context).configure(this.jdkChannel,this.jdkSource,enabled)
                  .then((): void => {
                    // 先使旧来源请求失效，再沿用检查队列合并一次最新偏好的手动检查；
                    // 检查正在运行时也不能丢掉用户刚修改的来源选择。
                    this.updateJdkReadyState(); this.checkRuntimeUpdates_(true)
                  })
                  .catch((e: Error): void => { this.jdkCatalogStatus = '切换自有来源失败：' + e.message; })
              },
              onJdkSourceChange: (value: string) => {
                this.jdkSource = value
                this.getPrefManager_().jdkSource = value
                setJdkDownloadSource(value)
                RuntimeCatalogRepository.instance(this.context).configure(this.jdkChannel,value,this.jdkWebEnabled)
                  .then((): void => {
                    // 与通道切换共用最新检查意图；旧请求的成功结果不能代替新来源检查。
                    this.updateJdkReadyState(); this.checkRuntimeUpdates_(true)
                  })
                  .catch((e: Error): void => { this.jdkCatalogStatus = '切换下载源失败：' + e.message; })
                AppLogger.info(TAG, `User switched JDK download source to ${value}`, LOG_DOMAIN_LAUNCH)
              },
              mcSource: this.mcSource,
              onMcSourceChange: (value: string) => {
                this.mcSource = value
                this.getPrefManager_().mcSource = value
                // 立即注入：正在排队/尚未开始的下载也会用新顺序（已在传输中的任务不受影响，
                // 它的 URL 列表在建 task 时就固化了）。
                setMcSourcePreference(value)
                AppLogger.info(TAG, `User switched MC download source to ${value}`, LOG_DOMAIN_DOWNLOAD)
              },
              onJdkVersionChange: (version: string) => {
                // 用户切换 JDK 版本：持久化 → 刷新 jdkReady → 触发 listVersions 重读
                this.selectedJdkVersion = version
                this.savePreferences()
                this.updateJdkReadyState()
                AppLogger.info(TAG, `User switched JDK to ${version}`, LOG_DOMAIN_LAUNCH)
              },
              customJvmArgs: this.getPrefManager_().customJvmArgs,
              onCustomJvmArgsChange: (args: string) => {
                // 全局自定义 JVM 参数：直接落盘到 PreferenceManager（McGamePage 启动时按 mcVersion 解析合并）
                this.getPrefManager_().customJvmArgs = args
              },
              gameLanguage: this.gameLanguage,
              onGameLanguageChange: (code: string) => {
                // 全局游戏语言：落盘 + 更新 @State（启动时经 resolveLaunch 注入 options.txt lang）
                this.gameLanguage = code
                this.getPrefManager_().gameLanguage = code
                AppLogger.info(TAG, `User switched global game language to ${code}`, LOG_DOMAIN_LAUNCH)
              },
              ohosFrameRateCap: this.ohosFrameRateCap,
              onOhosFrameRateCapChange: (fpsCap: number) => {
                this.ohosFrameRateCap = fpsCap
                this.getPrefManager_().ohosFrameRateCap = fpsCap
                let accepted = false
                try {
                  accepted = testNapi.setOhosFrameRateCap(fpsCap)
                } catch (e) {
                  AppLogger.warn(TAG, 'Failed to set OHOS frame-rate cap', e, LOG_DOMAIN_LAUNCH)
                }
                AppLogger.info(TAG,
                  `User switched OHOS scheduler cap to ${fpsCap === 0 ? 'auto' : fpsCap + ' Hz'}; nativeAccepted=${accepted}`,
                  LOG_DOMAIN_LAUNCH)
              },
              onCheckUpdate: () => { this.checkForUpdate() },
              hasUpdate: this.updateDot,
            })
          }
          .tabBar(this.buildDockTabBar($r('sys.symbol.gearshape_fill'), '设置'))
        }
        .width('100%')
        .layoutWeight(1)
        .barOverlap(true)
        .vertical(false)
        // 档位和主题状态直接作为修饰器输入；不重建 Tabs，保留页签、滚动与 Sheet 状态。
        .attributeModifier(new LauncherTabsStyle(this.bottomSafeHeight,
          effectiveBottomLightMode(this.immersiveLight), this.theme.bgCard))
        .animationDuration(300)
        .onAnimationStart((_index: number, targetIndex: number) => {
          this.currentTab = targetIndex
        })
      }
      .width('100%')
      .height('100%')

      // v5.1: 浮动下载进度圆 (FAB)
      // P0 修复 #1：FAB 同时服务 MC 整版下载和模组下载，优先 MC。
      // Phase R-4：activeTaskCount 提供多任务 badge（>1 时显示）。
      DownloadFab({
        active: this.isFabActive(),
        phase: this.computeFabPhase(),
        progress: this.computeFabProgress(),
        activeTaskCount: this.computeFabTaskCount(),
        theme: this.theme,
        fabOffsetX: $fabOffsetX,
        fabOffsetY: $fabOffsetY,
        viewportWidth: this.fabViewportWidth,
        viewportHeight: this.fabViewportHeight,
        bottomSafeHeight: this.bottomSafeHeight,
        onTap: () => { this.handleFabTap() }
      })

      // v6.5: 统一任务 Sheet 锚点（取代双 Sheet）
      Column().width(0).height(0)
        .bindSheet($$this.showTasksSheet, this.DownloadTasksSheetBuilder(),
          this.adaptiveSheetOptions(this.theme.bgPrimary))

      // 不可见锚点：承载 VersionConfig Sheet（避免多个 bindSheet 绑定同一组件冲突）
      Column().width(0).height(0)
        .bindSheet($$this.showVersionConfig, this.VersionConfigBuilder(),
          this.adaptiveSheetOptions(this.theme.bgCard))

      // 不可见锚点：承载 VersionManager Sheet
      Column().width(0).height(0)
        .bindSheet($$this.showVersionManager, this.VersionManagerBuilder(),
          this.versionManagerSheetOptions_())

      // M2 Phase B：账户管理 Sheet 锚点
      // 走 detailSheetHeight (80%) —— 跟其他详情类 sheet 一致。账户管理虽然有 Hero 卡，
      // 但 Hero + 2~3 行其他账户的总高度 (~400vp) 在 80% 安全区下还有空间，不需要加高。
      // 加高的策略 (largeSheetHeight 92%) 仅留给嵌套的 AddAccountSheet —— 它含 Microsoft
      // WebView，需要更多垂直空间。
      Column().width(0).height(0)
        .bindSheet($$this.showAccountListSheet, this.AccountListSheetBuilder(),
          this.adaptiveSheetOptions(this.theme.bgSecondary))

      // v6 (2026-05-19) — McErrorSheet 锚点
      // EntryAbility.onCreate 读到 SessionMarker 时，aboutToAppear 会填充
      // lastMcSession + lastMcSessionSummary + lastMcSessionLogTail 后翻 true 这个 flag。
      Column().width(0).height(0)
        .bindSheet($$this.showMcErrorSheet, this.McErrorSheetBuilder(),
          this.recoverySheetOptions_())

      // 网络诊断 Sheet 锚点（横幅点击 / 各下载错误处「网络检测」触发）
      Column().width(0).height(0)
        .bindSheet($$this.showNetDiagSheet, this.NetworkDiagnosticsSheetBuilder(),
          this.adaptiveSheetOptions(this.theme.bgSecondary))

      // 顶部「网络异常」横幅（可点，浮于内容上方；容器 hitTest 透明不挡下方交互）
      Column() {
        if (this.netBannerVisible) {
          Row({ space: 8 }) {
            AppIcon({ name: AppIconName.Warning, iconSize: 16, color: this.theme.warning })
            Text(this.netBannerText)
              .fontSize(13).fontColor(this.theme.textPrimary).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textHint })
          }
          .width('100%').padding({ left: 14, right: 12, top: 9, bottom: 9 })
          .backgroundColor(this.theme.warningBg)
          .borderRadius(10)
          .onClick(() => { this.showNetDiagSheet = true })
        }
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: 12, right: 12, top: this.topSafeHeight + 6 })
      .hitTestBehavior(HitTestMode.Transparent)

      // 启动前硬校验 Sheet 锚点：launchMC 点击后翻 showPreLaunchSheet=true，
      // 三项校验全过 → onProceed → doLaunchAfterChecks 真正创建 JVM。
      Column().width(0).height(0)
        .bindSheet($$this.showPreLaunchSheet, this.PreLaunchCheckSheetBuilder(),
          this.adaptiveSheetOptions(this.theme.bgSecondary))

      // 灵动弹窗（M5.6）：挂在最外层 Stack 顶部、zIndex 高于 Sheet，
      // 这样不管用户在哪个 tab / 有没有开着 Sheet 都能看到。
      if (this.toastVisible) {
        Column() {
          DynamicToast({
            visible: this.toastVisible,
            title: this.toastTitle,
            body: this.toastBody,
            theme: this.theme,
            topSafeHeight: this.topSafeHeight,
            onTap: () => { this.onToastTap_() },
            onDismiss: () => { this.toastVisible = false },
          })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(999)
      }

      // 开屏隐私政策弹窗（上架合规）：未同意时盖最顶层全屏遮罩，必须先决策。
      if (this.showPrivacy) {
        PrivacyConsentDialog({
          theme: this.theme,
          onAgree: () => { this.onPrivacyAgree() },
          onDisagree: () => { this.onPrivacyDisagree() },
        })
      }

    }
    .width('100%')
    .height('100%')
    .onSizeChange((_oldValue: SizeOptions, newValue: SizeOptions) => {
      if (typeof newValue.width === 'number' &&
          typeof newValue.height === 'number') {
        this.queueRootViewportUpdate_(newValue.width, newValue.height)
      }
    })
    .backgroundColor(this.theme.bgPrimary)
    .bindSheet($$this.showLogDialog, this.LogDialogBuilder(),
      this.adaptiveSheetOptions(this.theme.bgCard))
    .visibility(this.startupRevealed_ ? Visibility.Visible : Visibility.Hidden)
    .enabled(this.startupFinished_)
    .accessibilityLevel(this.startupFinished_ ? 'auto' : 'no-hide-descendants')
  }

  // ==================== P0 修复 #1：FAB 决策 + 模组下载状态处理 ====================

  // ==================== v6.5 FAB 数据 ====================
  //
  // FAB 不再区分 mc/mod owner —— 整个 sheet 统一了。FAB 仅从 registry 取聚合数据。
  // tasksRev 是 listener 触发的 ticker，让 FAB 重算（@State 引发 build）。

  /**
   * FAB 是否应当显示。
   *
   * 规则（v6.5.1，2026-05-22 修复）：仅在还有非终态任务时展示。
   *   - 活跃中（PREPARING/DOWNLOADING/VERIFYING/EXTRACTING/INSTALLING）→ 显示
   *   - 等待（WAITING）→ 显示
   *   - 暂停（PAUSED）→ 显示（用户可继续）
   *   - 全部终态（DONE/ERROR/ABORTED）→ 隐藏（用户不再需要"还在下载"提示）
   *
   * 之前用 `totalCount() > 0` 把已完成任务也算 active，FAB 永驻屏幕，
   * 用户反馈"任务结束后这个圆环还显示在页面上"。
   */
  private isFabActive(): boolean {
    // 读 tasksRev 让 ArkUI 跟踪依赖（registry 变动时 listener 会 +1 该字段→ 重算 build）
    if (this.tasksRev < 0) return false
    return this.registry.activeCount() > 0
        || this.registry.waitingCount() > 0
  }

  /**
   * FAB 显示用 phase：把 unifiedState 映射回 DownloadPhase（FAB 内部还在用这个枚举选色）。
   *   - 所有任务都 DONE → DONE
   *   - 任意 ERROR/ABORTED → ERROR
   *   - 任意 PAUSED → PAUSED
   *   - 活跃中 → 用 ASSETS 当下载中的代表
   */
  private computeFabPhase(): string {
    if (this.tasksRev < 0) return DownloadPhase.PREPARE  // 依赖跟踪
    let allDone = true
    let anyError = false
    let anyPaused = false
    let anyActive = false
    let total = 0
    for (let v of this.registry.listAll()) {
      total++
      if (v.state === UnifiedTaskState.ERROR || v.state === UnifiedTaskState.ABORTED) anyError = true
      else if (v.state === UnifiedTaskState.PAUSED) anyPaused = true
      else if (isActiveState(v.state)) { anyActive = true; allDone = false }
      else if (v.state !== UnifiedTaskState.DONE) { allDone = false }
    }
    if (total === 0) return DownloadPhase.PREPARE
    if (anyActive) return DownloadPhase.ASSETS
    if (anyError) return DownloadPhase.ERROR
    if (anyPaused) return DownloadPhase.PAUSED
    if (allDone) return DownloadPhase.DONE
    return DownloadPhase.ASSETS
  }

  /** FAB 进度：registry 聚合（字节加权平均，全活跃任务） */
  private computeFabProgress(): number {
    if (this.tasksRev < 0) return 0  // 依赖跟踪
    return this.registry.aggregateProgress()
  }

  /** FAB badge：活跃 + 等待任务数（终态不计） */
  private computeFabTaskCount(): number {
    if (this.tasksRev < 0) return 0  // 依赖跟踪
    return this.registry.activeCount() + this.registry.waitingCount()
  }

  private handleFabTap(): void {
    this.showTasksSheet = true
  }

  // ==================== Sheet 弹窗 Builders ====================

  @Builder
  DownloadTasksSheetBuilder() {
    DownloadTasksSheet({
      initialTaskId: this.downloadTaskFocusId,
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      topSafeHeight: this.topSafeHeight,
      onClose: () => { this.showTasksSheet = false; this.downloadTaskFocusId = '' },
    })
  }

  @Builder
  NetworkDiagnosticsSheetBuilder() {
    NetworkDiagnosticsSheet({
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      onClose: () => { this.showNetDiagSheet = false },
    })
  }

  // M2 Phase B：账户管理 Sheet builder
  @Builder
  AccountListSheetBuilder() {
    AccountListSheet({
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      topSafeHeight: this.topSafeHeight,
      deviceForm: this.deviceForm,
      appBreakpoint: this.appBreakpoint,
      onClose: () => { this.showAccountListSheet = false },
      onAccountsChanged: () => { this.refreshCurrentAccount() },
    })
  }

  // 启动前硬校验 Sheet builder（JIT / 运行时环境 / 版本文件完整性）
  @Builder
  PreLaunchCheckSheetBuilder() {
    PreLaunchCheckSheet({
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      filesDir: this.context.filesDir,
      mcDir: this.mcRoot(),
      gameDir: this.preLaunchGameDir,
      version: this.mcVersion,
      jdkVersion: this.preLaunchJdkVersion,
      jdkRange: this.preLaunchJdkRange,
      xmxMb: this.preLaunchXmx,
      checkJdkInstalled: (v: string): boolean => this.getJdkManager_().isInstalled(v),
      onProceed: () => { this.doLaunchAfterChecks() },
      onFix: (key: string) => { this.handlePreLaunchFix(key) },
      onStartRepair: () => { this.repairVersionFiles(this.mcVersion, true) },
      onStartJdkDownload: (jdkVersion: string) => { this.startInlineJdkDownload(jdkVersion) },
      onClose: () => { this.showPreLaunchSheet = false },
      // "改用自动 JDK"：把当前版本的单版本 JDK 覆盖改为自动，重新路由出兼容 JDK，返回新版本号。
      switchJdkToAuto: (): string => this.switchCurrentVersionJdkToAuto(),
    })
  }

  // v6 (2026-05-19) — MC 异常退出错误信息 Sheet builder
  // v6.5.1 (2026-05-22) 改为 McErrorClassifier 驱动 + onAction 路由到对应 tab
  @Builder
  McErrorSheetBuilder() {
    McErrorSheet({
      session: this.lastMcSession,
      summary: this.lastMcSessionSummary,
      logTail: this.lastMcSessionLogTail,
      theme: this.theme,
      bottomSafeHeight: this.bottomSafeHeight,
      // M3：会话快照 —— 让 Sheet 知道自己属于哪一局，并带回已有的分享 / AI 结果
      sessionKey: this.mcErrorSessionKey,
      initialLsId: this.mcErrorLsId,
      initialLsUrl: this.mcErrorLsUrl,
      initialLsToken: this.mcErrorLsToken,
      initialLsSharedAt: this.mcErrorLsSharedAt,
      initialAiText: this.mcErrorAiText,
      onClose: () => { this.showMcErrorSheet = false },
      onAction: (key: string) => { this.handleMcErrorAction_(key) },
      // 分享 / 撤回 / AI 完成时把结果持久化回活动记录，供下次重入取回
      onShareChanged: (id: string, url: string, token: string, sharedAt: number) => {
        if (id.length === 0) { clearSessionShare(this.mcErrorSessionKey) }
        else { saveSessionShare(this.mcErrorSessionKey, id, url, token, sharedAt) }
      },
      onAiDone: (text: string) => {
        saveSessionAiText(this.context, this.mcErrorSessionKey, text)
      },
    })
  }

  /**
   * 从本地压缩包导入 JDK（离线 / 用户自带）。
   *
   * 两步：先让用户选**装到哪个槽位**，再选文件。顺序刻意是这个 ——
   * 反过来（先选文件再问槽位）会让用户在文件选择器里挑完半天才被问一个他没准备好的问题。
   *
   * ⚠️ 槽位必须让用户选，不能从 zip 里猜：包里的目录名/release 文件都是可以任意改的，
   * 猜错就等于把用户的 JDK 21 装进 25 的槽位，而 JDK↔MC 的路由完全靠槽位号。
   */
  private async importLocalJdk_(): Promise<void> {
    if (this.jdkImporting) return
    const versions: string[] = SUPPORTED_JDK_VERSIONS.slice()
    // 首次目录尚未就绪时不给用户展示 undefined 槽位，也不让包内容自行决定安装位置。
    if (versions.length === 0) {
      this.showToast_('暂无可用的 JDK 槽位，请先刷新运行时目录后重试')
      return
    }
    let pickedIdx = -1
    try {
      // ⚠️ ArkTS 严格模式：对象/数组字面量必须有显式声明类型
      //（arkts-no-untyped-obj-literals / arkts-no-noninferrable-arr-literals），
      // 所以逐个声明成 promptAction.Button，不能图省事写内联字面量数组。
      // promptAction.Button.color 只接受 string | Resource，而主题色是 ResourceColor（含 number）。
      // 本仓主题用的是十六进制字符串，所以能直接用；不是字符串时退到系统默认前景色，
      // 不硬编码一个在深色模式下会瞎掉的颜色。
      const tp = this.theme.textPrimary
      const menuColor: string = typeof tp === 'string' ? tp as string : '#000000'
      // SDK 的操作菜单最多展示六个按钮。每页四个真实槽位，为上一页/下一页各留一席；
      // 注册表增加第五个或更多主版本时仍能选择，离线只剩少量槽位也不生成空白按钮。
      const pageSize: number = 4
      let offset: number = 0
      while (pickedIdx < 0) {
        const pageVersions: string[] = versions.slice(offset,offset + pageSize)
        // ActionMenuOptions.buttons 的 SDK 类型要求至少一项、最多六项的元组，不能传普通数组。
        const first: promptAction.Button = { text:'JDK ' + pageVersions[0],color:menuColor }
        const buttons: [promptAction.Button,promptAction.Button?,promptAction.Button?,
          promptAction.Button?,promptAction.Button?,promptAction.Button?] = [first]
        for (let i = 1; i < pageVersions.length; i++) {
          const button: promptAction.Button = { text:'JDK ' + pageVersions[i],color:menuColor }
          buttons.push(button)
        }
        let previousIndex: number = -1
        let nextIndex: number = -1
        if (offset > 0) {
          previousIndex = buttons.length
          const previous: promptAction.Button = { text:'上一页',color:menuColor }
          buttons.push(previous)
        }
        if (offset + pageSize < versions.length) {
          nextIndex = buttons.length
          const next: promptAction.Button = { text:'下一页',color:menuColor }
          buttons.push(next)
        }
        const opts: promptAction.ActionMenuOptions = {
          title:'把这个包装到哪个 JDK 槽位？',buttons:buttons,
        }
        const res: promptAction.ActionMenuSuccessResponse =
          await this.getUIContext().getPromptAction().showActionMenu(opts)
        const index: number = res.index !== undefined ? res.index : -1
        if (index >= 0 && index < pageVersions.length) pickedIdx = offset + index
        else if (previousIndex >= 0 && index === previousIndex) offset -= pageSize
        else if (nextIndex >= 0 && index === nextIndex) offset += pageSize
        else return
      }
    } catch (e) {
      // showActionMenu 在用户点遮罩/返回时以 reject 表达取消 —— 这不是错误，静默返回
      return
    }
    if (pickedIdx < 0 || pickedIdx >= versions.length) return
    const version = versions[pickedIdx]

    this.jdkImporting = true
    let zipPath = ''
    try {
      const ctx = this.context as common.UIAbilityContext
      const importDir = this.context.filesDir + '/jdk-import'
      const picked = await GameArchiveIO.importResourceFile(ctx, importDir, ['.zip'])
      if (picked.cancelled) return
      if (!picked.ok) {
        this.showToast_(picked.message.length > 0 ? picked.message : '选择文件失败')
        return
      }
      zipPath = importDir + '/' + picked.name
      this.statusMsg = '正在导入 JDK ' + version + '…'
      const r = await JdkImporter.importFromZip(this.context, version, zipPath,
        (phase: string, percent: number, message: string) => {
          this.statusMsg = message
          this.jdkExtractProgress = message
        })
      this.showToast_(r.message)
      this.statusMsg = r.ok ? r.message : ''
      if (r.ok) {
        AppLogger.info(TAG, `local JDK import ok: version=${version} stamp=${r.stamp}`, LOG_DOMAIN_LAUNCH)
      } else {
        AppLogger.warn(TAG, `local JDK import failed: version=${version} ${r.message}`, null, LOG_DOMAIN_LAUNCH)
      }
    } catch (e) {
      const err = e as Error
      AppLogger.warn(TAG, 'local JDK import threw', e as Object, LOG_DOMAIN_LAUNCH)
      this.showToast_('导入失败：' + err.message)
    } finally {
      // 拷进沙箱的那份 zip 无论成败都删掉：它可能有 100+ MB，留着就是白占用户空间。
      if (zipPath.length > 0) {
        try { fs.unlinkSync(zipPath) } catch (e) { /* ignore */ }
      }
      this.jdkImporting = false
      this.updateJdkReadyState()
    }
  }

  private showToast_(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 3000 })
    } catch (e) { /* toast 失败不影响主流程 */ }
  }

  /**
   * McErrorSheet 主按钮 / 建议步骤透传上来的 actionKey 路由。
   * 大多数动作 = 关 sheet + 切到对应 tab（用户在那里自己继续操作）。
   * 不处理 'copy_log'（McErrorSheet 内部自己复制）。
   */
  private handleMcErrorAction_(key: string): void {
    // 关 sheet（每个动作都需要）
    this.showMcErrorSheet = false
    // 路由到对应 tab
    if (key === 'open_mod_list' || key === 'open_mod_browse') {
      this.jumpToDownloadSub(1)   // 下载 Tab → 模组子页
    } else if (key === 'open_versions' || key === 'redownload') {
      this.jumpToDownloadSub(0)   // 下载 Tab → 版本子页
    } else if (key === 'open_jdk_manager' || key === 'open_memory_settings') {
      this.currentTab = 2   // 设置 Tab
      try { this.tabController.changeIndex(2) } catch (e) { /* ignore */ }
    }
    // 'copy_log' 已由 sheet 内部自行处理，无需父组件响应
  }

  @Builder
  VersionConfigBuilder() {
    VersionConfigPanel({
      gameVersion: this.configGameVersion,
      gameCategory: this.configGameCategory,
      theme: this.theme,
      installedJdkMajors: this.installedJdkMajors_(),
      mcDir: this.mcRoot(),
      downloading: this.isMcDownloading_(),
      onStartDownload: (gameVersion: string, loaderType: ModLoaderType | null,
        loaderVersion: string, versionName: string,
        fabricApi: RemoteVersion | null, fabricApiIconUrl: string) => {
        this.showVersionConfig = false
        this.beginDownload(gameVersion, loaderType, loaderVersion, versionName, fabricApi, fabricApiIconUrl)
      },
      onClose: () => { this.showVersionConfig = false },
      // Forge 安装前 JIT 拦截：产品层用 testNapi 探测，异常按不可用处理。
      checkJitAvailable: (): boolean => {
        try { return testNapi.checkJitAvailable() } catch (e) { return false }
      },
      // Forge/NeoForge 需安装器 JDK 但无可用版本：关下载 sheet → 入队对应 JDK 下载任务 → 弹任务 sheet。
      onInstallJdk: (requiredMajor: number) => {
        this.showVersionConfig = false
        let jdkVer = String(requiredMajor)
        this.statusMsg = '添加 JDK ' + jdkVer + ' 下载任务...'
        this.showTasksSheet = true
        let jdkStartedAt = Date.now()
        let task = new JdkInstallTask(jdkVer, this.getJdkManager_(), jdkStartedAt)
        this.registry.enqueue(task).then(() => {
          this.updateJdkReadyState()
        }).catch((e: Error) => {
          AppLogger.warn(TAG, 'enqueue JDK task rejected', e, LOG_DOMAIN_DOWNLOAD)
          if (e.message.indexOf('已在进行中') < 0) {
          }
        })
      }
    })
  }

  // ============================================================
  //  Phase R-3：版本管理 Sheet（取代原 VersionManagerBuilder）
  //
  //  原 inline builder 保留为 VersionManagerLegacyBuilder（暂未使用，
  //  作为回退选项保留至 R-4 真机回归通过后再删除）。
  // ============================================================

  @Builder
  VersionManagerBuilder() {
    Stack() {
      VersionManagerSheet({
        onRegisterExportDismiss: (handler: ((back?: boolean) => void) | undefined): void => {
          this.versionExportDismiss_ = handler
        },
        canRunGame: this.canRunGame_,
        storeManager: DistributionPolicy.isStore(),
        onOpenDownloadTask: (id: string): void => {
          this.downloadTaskFocusId = id; this.showTasksSheet = true
        },
        theme: this.theme,
        bottomSafeHeight: this.bottomSafeHeight,
        mcXmx: this.mcXmx,
        mcDir: this.mcRoot(),
        selectedJdkVersion: this.selectedJdkVersion,
        // 全局 Java 版本设置（'auto' 或具体版本），供单版本"跟随全局"选项附注展示。
        globalJdkVersion: this.selectedJdkVersion,
        // 全局游戏语言，供单版本"跟随全局"选项附注展示。
        globalGameLanguage: this.gameLanguage,
        // R-JDK21：版本详情 sheet 的 JDK 行可以下拉选择 跟随全局/自动/具体版本；
        // suggestedJdkVersion 是按当前 mcVersion 推算的"自动选择"结果，
        // sheet 内会在对应具体版本加" · 推荐"标签
        suggestedJdkVersion: this.getJdkManager_().autoSelectVersion(this.mcVersion),
        supportedJdkVersions: this.jdkVersions.map((v: JdkVersionInfo) => v.version),
        currentVersion: this.mcVersion,
        availableVersions: this.availableVersions,
        orphanVersionDirs: this.orphanVersionDirs,
        versionIsolation: this.versionIsolation,
        // 仅外部存储显示系统文件管理入口；沙箱使用应用内版本文件夹。
        isExternalStorage: this.storageLocation === StorageLocation.EXTERNAL,
        onSelectVersion: (ver: string) => {
          this.selectManagedVersion_(ver)
        },
        onDeleteVersion: (ver: string) => {
          this.confirmDeleteVersion(ver)
        },
        onRenameVersion: (oldVer: string, newVer: string): boolean => {
          // 执行真正的文件系统重命名（目录 + 内部 jar/json + json id，原子带回滚）。
          let res = renameVersion(this.mcRoot(), oldVer, newVer)
          if (!res.ok) {
            // 失败：toast 具体原因；sheet 保持浮层让用户修改后重试。
            this.getUIContext().getPromptAction().showToast({ message: res.error, duration: 2000 })
            this.addActivity_(ActivityCategory.VERSION_MANAGE, oldVer + ' → ' + newVer, ActivityStatus.FAILED, Date.now(), '重命名版本', res.error)
            return false
          }
          // 若重命名的是当前选中版本，先把 mcVersion 指向新名再重扫——
          // 否则 scanVersions 发现"旧名已不在列表"会把当前版本回退到列表首项。
          if (this.mcVersion === oldVer) {
            this.mcVersion = newVer
            this.savePreferences()
          }
          this.scanVersions()
          this.scanInstalledModsCount()
          this.getUIContext().getPromptAction().showToast({ message: '已重命名为「' + newVer + '」', duration: 1800 })
          this.addActivity_(ActivityCategory.VERSION_MANAGE, oldVer + ' → ' + newVer, ActivityStatus.SUCCESS, Date.now(), '重命名版本', '')
          return true
        },
        onAddNew: () => {
          this.showVersionManager = false
          // 切到下载 Tab 版本子页让用户选版本
          this.jumpToDownloadSub(0)
        },
        onCleanupOrphans: () => {
          let versionsDir = this.mcRoot() + '/versions'
          for (let name of this.orphanVersionDirs) {
            try { removeDirRecursive(versionsDir + '/' + name) } catch (e) { /* */ }
          }
          this.scanVersions()
          this.statusMsg = '已清理 ' + this.orphanVersionDirs.length + ' 个残留目录'
        },
        onRepairVersion: (ver: string) => {
          // 残留/损坏版本的"修复"：走统一修复（Forge 深度修复 / 普通增量补全），切到下载页看进度
          this.repairVersionFiles(ver)
        },
        onReorderVersions: (newOrder: string[]) => {
          // 用户拖拽排序：持久化新顺序并即时应用
          this.onReorderVersions(newOrder)
        },
        onOpenVersionDetail: (ver: string) => {
          // v2 重设计：详情视图改为 sheet 内部第二步（VersionManagerSheet 自管 currentStep
          //   并以 animateTo + translate 做横向滑动转场）。原 pages/VersionDetailPage
          //   已删除，此回调保留为公共 API 兼容点（当前空实现）。
        },
        // v3：资源管理改为版本管理 sheet 的第三步（同 sheet 横滑），不再各开独立 sheet。
        //   深链初始参数（首页"已装模组"直达模组管理步）：
        initialStep: this.versionManagerInitialStep,
        initialResourceVersion: this.installedResourcesTargetVersion,
        initialResourceKind: this.installedResourcesKind,
        onJumpToBrowse: (kind: ResourceKind) => {
          // 资源步"安装" / 空态 → 关闭版本管理 sheet 并按资源类别切到下载 Tab 对应子页
          this.showVersionManager = false
          this.jumpToDownloadSub(this.resourceKindToDlSubTab(kind))
        },
        onResourcesChanged: () => {
          this.onVersionFilesChanged_()
        },
        onClose: () => { this.showVersionManager = false },
        onLaunchVersion: (ver: string) => {
          // 版本详情"启动"：切到该版本 → 关闭版本管理 sheet → 待收回动画后走通用启动路径
          // （launchMC → 启动前硬校验 Sheet → doLaunchAfterChecks 真正创建 JVM），与首页同链路。
          this.mcVersion = ver
          this.savePreferences()
          this.scanInstalledModsCount()
          this.showVersionManager = false
          setTimeout(() => { this.launchMC() }, 320)
        },
        // 单版本 JDK 选择：详情 sheet 内联下拉，读写走 PreferenceManager 的版本覆盖 jdkVersion 字段。
        //   '' = 跟随全局 | 'auto' = 该版本自动路由 | 具体版本 = 硬覆盖（即便不匹配也照用，供调试）。
        loadVersionJdk: (ver: string): string => this.getPrefManager_().getVersionOverride(ver).jdkVersion,
        onSaveVersionJdk: (ver: string, choice: string) => {
          let o = this.getPrefManager_().getVersionOverride(ver)
          o.jdkVersion = choice
          this.getPrefManager_().setVersionOverride(ver, o)
          // 若改的是当前选中版本，刷新启动按钮的 jdkReady 就绪态
          if (ver === this.mcVersion) this.updateJdkReadyState()
          AppLogger.info(TAG, `Set per-version JDK: ${ver} -> ${choice}`, LOG_DOMAIN_LAUNCH)
        },
        // 单版本自定义 JVM 参数：详情 sheet 内联编辑，读写走 PreferenceManager 的版本覆盖
        // （只动 customJvmArgs 字段，xmx/jdk 各有独立入口）。
        loadVersionJvmArgs: (ver: string): string => this.getPrefManager_().getVersionOverride(ver).customJvmArgs,
        onSaveVersionJvmArgs: (ver: string, args: string) => {
          let o = this.getPrefManager_().getVersionOverride(ver)
          o.customJvmArgs = args
          this.getPrefManager_().setVersionOverride(ver, o)
        },
        // 单版本游戏语言：详情 sheet 内联下拉，读写走 PreferenceManager 的版本覆盖 gameLanguage 字段。
        //   '' = 跟随全局设置 | 具体 code（'zh_cn'/'en_us'…）= 单版本硬覆盖。
        loadVersionGameLang: (ver: string): string => this.getPrefManager_().getVersionOverride(ver).gameLanguage,
        onSaveVersionGameLang: (ver: string, code: string) => {
          let o = this.getPrefManager_().getVersionOverride(ver)
          o.gameLanguage = code
          this.getPrefManager_().setVersionOverride(ver, o)
          AppLogger.info(TAG, `Set per-version game language: ${ver} -> ${code === '' ? '(follow global)' : code}`, LOG_DOMAIN_LAUNCH)
        },
        onVerifyVersionFiles: (ver: string) => { this.verifyVersionFilesFull(ver) },
      })

      // 删除确认对话框（modal overlay，保留原行为）
      if (this.showDeleteConfirm && this.pendingDeleteVersion.length > 0) {
        this.DeleteConfirmOverlay()
      }

      // 全量 SHA1 校验覆盖层
      if (this.showVerifyOverlay) {
        this.VerifyOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 删除版本确认对话框 overlay（从原 LegacyBuilder 中抽出） */
  @Builder
  DeleteConfirmOverlay() {
    Column() {
      Column() {
        Text('确认删除')
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .margin({ bottom: 12 })
        Text('确定要删除版本 ' + this.pendingDeleteVersion + '？')
          .fontSize(14).fontColor(this.theme.textSecondary)
          .margin({ bottom: 4 })
        Text('版本隔离目录下的所有文件（mods、存档、配置）将一并删除，且无法恢复。')
          .fontSize(12).fontColor(this.theme.textHint)
          .margin({ bottom: 16 })
        Row({ space: 12 }) {
          Button('取消')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
            .onClick(() => { this.showDeleteConfirm = false; this.pendingDeleteVersion = '' })
          Button('删除')
            .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
            .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.error)
            .onClick(() => {
              this.executeDeleteVersion()
              if (this.availableVersions.length === 0) { this.showVersionManager = false }
            })
        }
        .width('100%')
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { this.showDeleteConfirm = false; this.pendingDeleteVersion = '' })
  }

  /** 全量 SHA1 校验覆盖层：校验中显示进度，结束显示结果摘要 + 关闭/重新下载。 */
  @Builder
  VerifyOverlay() {
    Column() {
      Column() {
        Text('校验文件完整性')
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .margin({ bottom: 4 })
        Text(this.verifyTitle)
          .fontSize(12).fontColor(this.theme.textHint)
          .margin({ bottom: 14 })

        if (this.verifyRunning) {
          Row({ space: 10 }) {
            LoadingProgress().width(22).height(22).color(this.theme.primary)
            Text(this.verifyText)
              .fontSize(13).fontColor(this.theme.textSecondary).layoutWeight(1)
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%').margin({ bottom: 16 })
          .alignItems(VerticalAlign.Center)
        } else {
          Text(this.verifyText)
            .fontSize(13).fontColor(this.theme.textSecondary)
            .width('100%').margin({ bottom: 16 })
        }

        // 校验中不给按钮（强制等完成，避免中途态混乱）；结束才给关闭/重新下载
        if (!this.verifyRunning) {
          Row({ space: 12 }) {
            Button('关闭')
              .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
              .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
              .onClick(() => { this.showVerifyOverlay = false })
            if (this.verifyProblemCount > 0) {
              Button('一键修复')
                .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
                .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.primary)
                .onClick(() => { this.repairVersionFiles(this.verifyTitle) })
            }
          }
          .width('100%')
        }
      }
      .width('90%').padding(20)
      .backgroundColor(this.theme.bgCard).borderRadius(16)
      .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // 校验中点背景不关闭（防误触）；结束后允许点背景关闭
    .onClick(() => { if (!this.verifyRunning) this.showVerifyOverlay = false })
  }
  @Builder
  VersionManagerLegacyBuilder() {
    Column() {
      Row() {
        Text('版本管理')
          .fontSize(20).fontWeight(700).fontColor(this.theme.textPrimary).layoutWeight(1)
        // 兼容保留的旧Builder也复用普通按钮；现役版本管理走独立完整标题宿主。
        AppRoundIconButton({ name: AppIconName.Close, theme: this.theme, accessibilityLabel: '关闭版本管理',
          onAction: (): void => { this.showVersionManager = false } })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 16 })

      Row() {
        Text((this.versionIsolation || isIsolatedModpackInstance(this.mcRoot(), this.mcVersion)) ? '版本隔离已开启' : '版本隔离已关闭')
          .fontSize(13).fontWeight(400).fontColor(this.theme.textSecondary)
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 16 })

      if (this.availableVersions.length === 0) {
        Column() {
          Text('暂无已安装的版本')
            .fontSize(16).fontWeight(400).fontColor(this.theme.textSecondary).margin({ bottom: 8 })
          Text('请在「下载」页面下载游戏版本')
            .fontSize(13).fontWeight(400).fontColor(this.theme.textHint)
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.availableVersions, (ver: string) => {
            ListItem() {
              Row() {
                Column()
                  .width(3).height(32).borderRadius(2)
                  .backgroundColor(this.mcVersion === ver ? this.theme.primary : Color.Transparent)
                  .margin({ right: 16 })
                Column() {
                  Row({ space: 8 }) {
                    Text(ver)
                      .fontSize(16).fontWeight(500)
                      .fontColor(this.mcVersion === ver ? this.theme.primary : this.theme.textPrimary)
                    Text(this.detectVersionType(ver))
                      .fontSize(10).fontColor(this.theme.textSecondary)
                      .backgroundColor(this.theme.bgInput)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
                    if (this.mcVersion === ver) {
                      Text('当前')
                        .fontSize(10).fontColor(this.theme.textOnPrimary)
                        .backgroundColor(this.theme.primary)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
                    }
                  }
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.mcVersion !== ver) {
                  Button('选择')
                    .type(ButtonType.Capsule).height(32).fontSize(13)
                    .fontColor(this.theme.primary).backgroundColor(this.theme.primaryLight)
                    .margin({ right: 8 })
                    .onClick(() => { this.mcVersion = ver; this.savePreferences() })
                }
                Button('删除')
                  .type(ButtonType.Capsule).height(32).fontSize(13)
                  .fontColor(this.theme.error).backgroundColor(this.theme.bgInput)
                  .onClick(() => {
                    this.confirmDeleteVersion(ver)
                  })
              }
              .width('100%').padding(16)
              .backgroundColor(this.theme.bgCard).borderRadius(12)
              .onClick(() => { this.mcVersion = ver; this.savePreferences() })
            }
          })
        }
        .width('100%').layoutWeight(1).padding({ left: 16, right: 16 })
      }

      if (this.orphanVersionDirs.length > 0) {
        Row() {
          Text(this.orphanVersionDirs.length + ' 个残留目录')
            .fontSize(12).fontColor(this.theme.warning)
          Blank()
          Button('清理')
            .type(ButtonType.Capsule).height(28).fontSize(12)
            .fontColor(this.theme.error).backgroundColor(this.theme.bgInput)
            .onClick(() => {
              let versionsDir = this.mcRoot() + '/versions'
              for (let name of this.orphanVersionDirs) {
                try { removeDirRecursive(versionsDir + '/' + name) } catch (e) { /* */ }
              }
              this.scanVersions()
              this.statusMsg = '已清理 ' + this.orphanVersionDirs.length + ' 个残留目录'
            })
        }
        .width('100%').padding({ left: 16, right: 16, top: 8 })
      }

      Text('已安装 ' + this.availableVersions.length + ' 个版本')
        .fontSize(12).fontWeight(400).fontColor(this.theme.textHint)
        .padding({ top: 12, bottom: 16 })

      if (this.showDeleteConfirm && this.pendingDeleteVersion.length > 0) {
        Column() {
          Column() {
            Text('确认删除')
              .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
              .margin({ bottom: 12 })
            Text('确定要删除版本 ' + this.pendingDeleteVersion + '？')
              .fontSize(14).fontColor(this.theme.textSecondary)
              .margin({ bottom: 4 })
            Text('版本隔离目录下的所有文件（mods、存档、配置）将一并删除，且无法恢复。')
              .fontSize(12).fontColor(this.theme.textHint)
              .margin({ bottom: 16 })
            Row({ space: 12 }) {
              Button('取消')
                .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
                .fontColor(this.theme.textSecondary).backgroundColor(this.theme.bgInput)
                .onClick(() => { this.showDeleteConfirm = false; this.pendingDeleteVersion = '' })
              Button('删除')
                .type(ButtonType.Capsule).height(36).fontSize(14).layoutWeight(1)
                .fontColor(this.theme.textOnPrimary).backgroundColor(this.theme.error)
                .onClick(() => {
                  this.executeDeleteVersion()
                  if (this.availableVersions.length === 0) { this.showVersionManager = false }
                })
            }
            .width('100%')
          }
          .width('90%').padding(20)
          .backgroundColor(this.theme.bgCard).borderRadius(16)
          .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
        }
        .width('100%').height('100%')
        .position({ x: 0, y: 0 })
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => { this.showDeleteConfirm = false; this.pendingDeleteVersion = '' })
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  LogDialogBuilder() {
    Column() {
      // 只接管日志Sheet标题，关闭仍更新原flag，日志刷新和复制行为保持原样。
      ImmersiveTitleScaffold({ title: '启动器运行日志', theme: this.theme, modal: true,
        closeLabel: '关闭运行日志', surfaceColor: this.theme.bgCard,
        onClose: (): void => { this.showLogDialog = false },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
    .width('100%').height('100%')
    .backgroundColor(this.theme.bgCard)
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
      Row({ space: 12 }) {
        Button('刷新')
          .type(ButtonType.Capsule).fontSize(13).height(36)
          .backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary)
          .onClick(() => { this.refreshLauncherLog() })
        Button('复制应用诊断摘要')
          .type(ButtonType.Capsule).fontSize(13).height(36)
          .backgroundColor(this.theme.primaryLight).fontColor(this.theme.primary)
          .onClick(() => { this.exportLogToClipboard(); this.showLogDialog = false })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 12 })

      Scroll() {
        Text(this.launcherLog || '(无日志)')
          .fontSize(12).fontColor(this.theme.textSecondary)
          .fontFamily('monospace').width('100%').padding(16)
      }
      .layoutWeight(1)
      .backgroundColor(this.theme.bgInput)
      .borderRadius(12)
      .margin({ left: 16, right: 16, bottom: 16 })
      }
}

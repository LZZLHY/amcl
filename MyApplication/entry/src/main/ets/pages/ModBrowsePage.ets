/**
 * 浏览页的普通错误文字与图标使用错误前景色，原生缺失清单按钮使用主题操作文字色；
 * 只调整显示角色，不改变搜索、安装恢复、排序和复制清单的原有判断及回调。
 */
import { DiagnosticPolicy, DistributionPolicy } from 'commons';
/**
 * ModBrowsePage.ets — 模组、光影、资源包与整合包的共享下载浏览页。
 *
 * 搜索栏常驻，二级面板管理加载器/排序；其他资源保留原目标版本选择，网络状态只替换结果区。
 * 整合包使用适应实际内容宽度的卡片网格，新安装沿用设置的全局存储根，本地导入与恢复
 * 在筛选收起、加载、空结果或错误时仍可用。恢复使用持久记录的原根，不迁移已有实例。
 * 详情选版、可选前置与统一任务由现有仓库/安装服务负责，页面销毁不拥有后台安装生命周期。
 * 当前行为与验收入口见 docs/guides/download-system.md。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ThemeColors } from 'commons';
import { GameStorage } from 'feature_system';
import { VersionPickerSheet } from '../components/VersionPickerSheet';
import { APP_NAME, APP_VERSION } from 'commons';
// DownloadManager 仍需 instance() 构造 Repository；DownloadTaskView 不再直接消费
import { DownloadManager } from 'feature_core';
import { UnifiedTaskView } from 'feature_core';
import { ModInstallTask, ModInstallRequest, dependencyPlanErrors, isModVersionCompatible } from 'mods';
import { getMetadataCacheStore } from 'feature_core';
// 来源约束优先于网关自动排序（见 resolveModrinthMode）。
import { getRelayClient } from 'feature_core';
import { ModrinthRepository } from 'mods';
import { CurseForgeRepository } from 'mods';
import { ModSourceRouter } from 'mods';
import {
  ModDependencyResolver,
  ResolveOptions,
  ResolveResult,
  ResolvedDependency,
  makeResolverFromRouter,
  pickBestVersion,
} from 'mods';
// v6.5：ModInstaller 不再直接使用 —— ResourceInstallTask 隐含了。
import {
  ModSearchController,
  ModSearchState,
  makeInitialSearchState,
  describeSearchFailureForUser,
} from 'mods';
import {
  getModrinthSourceMode,
  ensureModrinthRanking,
  isMcimAvailable,
} from 'mods';
import {
  ModSource, ResourceKind, RemoteProject, RemoteVersion, DependencyType, makeEmptyRemoteProject,
  pickPrimaryFile, RemoteFile, LocalMod,
} from 'mods';
import { buildCurseForgeFileDownloadUrls } from 'mods';
import { resolveInstalledLoader, resolveInstalledMcVersion } from 'mods';
import { IRemoteModRepository, SortBy } from 'mods';
import { ModrinthSourceMode } from 'mods';
import { ModCard } from '../components/ModCard';
import { ModpackCard } from '../components/ModpackCard';
import { loadModTranslationStores, ModTranslationStores,
  getCachedTranslationStores, onTranslationStoresUpdated, offTranslationStoresUpdated } from '../services/ModTranslationLoader';
// v6.5 (2026-05-22)：ModBrowsePage 不再推送 ModDlState 给 Index；改为 registry.enqueue。
import { ModDetailSheet, ModDetailDepRow } from '../components/ModDetailSheet';
import { getDownloadTaskRegistry } from 'feature_core';
import { ResourceInstallTask } from 'mods';
import { ModpackInstallTask, abandonModpackRecovery, readModpackRecoveryKind,
  sanitizeVersionName, validateModpackVersionName, displayTitleOf } from 'mods';
import { ModpackNameInput } from '../components/ModpackNameInput';
import { createModpackFileResolver, scanModpackRecovery, LocalModScanControl, ModpackRecoveryItem, CurseForgeFileSourceMode,
  resolveModrinthSourcePreference, resolveCurseForgeFileSourcePreference } from 'mods';
import { isIsolatedModpackInstance } from 'commons';
import { UnifiedTaskState, newVersionInstallOwner } from 'feature_core';
import { ModpackMissingItem } from 'mods';
import { GameArchiveIO } from '../components/GameArchiveIO';
import { LocalModScanner } from 'mods';
import { InstalledModIndex } from 'mods';
import { ModUpdateCoordinator } from '../components/ModUpdateCoordinator';
import { centerSheetForLayout, sheetWidthForLayout, detailSheetHeightForLayout, floatingDockReserveHeight } from 'commons';
import { Breakpoint, DeviceForm } from 'commons';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppIconName } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
import { DownloadSearchField } from '../components/DownloadSearchField';
import { LayerRetreatPolicy, RetreatFrame, retreatLayerHeight, retreatLayerOffset,
  retreatStableInset, retreatLeadItemHeight, retreatNeedsTopRestore } from '../components/LayerRetreatPolicy';
import { UiMotion } from '../components/UiMotion';
import { pickAndStartModFileSave, supportsCustomResourceSave } from '../services/ModFileSave';

const TAG = 'ModBrowsePage';
/** 单局真实业务终态原件；nonce绑定原manifest，冷启只能消费匹配的安装活动。 */


const SEARCH_DEBOUNCE_MS = 300;
const USER_AGENT = APP_NAME + '/' + APP_VERSION + ' (https://github.com/axecraft/amcl)';

// 主模组及前置的独立卡片由 ModInstallTask 依据最终安装计划登记；
// 页面只提交用户选择，安装服务重新核对已装状态并统一提交，避免沿用过期依赖信息。

/** 详情 sheet 里本地已装的"主文件"引用（用于"升级"时真正替换旧文件，而非新增一个）。 */
interface InstalledPrimaryRef {
  /** 旧文件绝对路径（.jar 或 .jar.disabled）。 */
  filePath: string;
  /** 旧文件是否启用（.jar=true / .jar.disabled=false），升级后保持该状态。 */
  enabled: boolean;
  /** 去 .disabled 的基名，用于判断"选中版本是否与已装同名（同版本）"。 */
  baseName: string;
}

@Component
export struct ModBrowsePage {
  /** 由偏好所有者发布的确认比例；改变后重新计算手机资源详情和导入面板高度。 */
  @StorageProp('phoneSheetHeightPercent') private phoneSheetHeightPercent_: number = 80;
  @Prop theme: ThemeColors = {} as ThemeColors;
  /** 原生Tabs保留隐藏内容，显式可见性阻止离页后的动画续体继续消费旧手势。 */
  @Prop @Watch('onRetreatHostVisible_') hostVisible: boolean = true;
  /** .minecraft 根目录绝对路径（不带尾部 /） */
  @Prop @Watch('onResourceTargetPropsChanged_') mcDir: string = '';
  /** 当前选中的已装 MC 版本 id（用于目标目录计算 + 默认筛选） */
  @Prop @Watch('onResourceTargetPropsChanged_') currentMcVersion: string = '';
  @Prop versionIsolation: boolean = true;
  /** P0 修复 #4：用于校验 currentMcVersion 是否真的存在（防止凭空创建版本目录） */
  @Prop @Watch('onResourceTargetPropsChanged_') availableVersions: string[] = [];
  /** 顶/底部安全区高度（来自 Index 透传，详情 sheet 70% 高度计算用） */
  @Prop topSafeHeight: number = 0;
  @Prop bottomSafeHeight: number = 0;
  // 一多适配：设备形态 + 响应式断点（由 Index @Provide 下沉）。决定详情/选版 sheet 形态：
  // 仅「非手机形态 + 窗口≥600vp」走居中卡片(CENTER)；手机(含横屏)一律底部抽屉(BOTTOM)。
  @Consume('deviceForm') deviceForm: DeviceForm;
  @Consume('appBreakpoint') appBreakpoint: Breakpoint;
  /**
   * 用户偏好的模组源：
   *   'auto'     → 走 ModSourceProber 自动决策（MCIM 与官方 RTT 较快者）
   *   'mcim'     → 强制 MCIM_FIRST
   *   'official' → 强制 OFFICIAL_FIRST
   * 通过闭包传给 ModrinthRepository，支持运行期热切（用户切设置后无需重启页面）。
   */
  @Prop modSource: string = 'auto';
  /**
   * 是否缓存远程元数据（项目详情 / 版本列表的 TTL + 304）。
   * false 时 ModrinthRepository / CurseForgeRepository 的 cachedFetch 退化为无缓存 fetchText。
   */
  @Prop cacheRemoteMeta: boolean = true;
  /**
   * 外部下载胶囊控制资源类别：0=模组、1=资源包、2=光影、3=整合包。
   * 首次挂载读取初值，之后由Watch同步；不再以销毁页面来切换资源类别。
   */
  @Prop @Watch('externalKindChanged_') defaultKindIdx: number = 0;

  /** 给 Index 做 toast/log 的回调（可选） */
  onStatusMessage: (msg: string) => void = () => {};
  /** 打开已登记任务的详情；确认界面属于任务面板，浏览页销毁不丢计划。 */
  onOpenDownloadTask: (id: string) => void = () => {};
  // v6.5：以下两个回调已下台，走 registry 是唯一的模组下载路径。

  // ===================== 内部状态 =====================

  @State private inited_: boolean = false;

  // 0=MOD, 1=RESOURCE_PACK, 2=SHADER；aboutToAppear 中按 defaultKindIdx 同步
  @State private kindIdx_: number = 0;
  @State private queryInput_: string = '';
  @State private gameVersionInput_: string = '';
  @State private loaderInput_: string = 'fabric';
  /** 另存不使用安装实例的自动筛选。用户在该模式手动选的加载器单独保留。 */
  @State private customModLoaderInput_: string = '';
  @State private sortInput_: SortBy = SortBy.DOWNLOADS;
  private sortExplicit_: boolean = false;
  @State private modpackRecovery_: ModpackRecoveryItem[] = [];
  @State private showModpackRecovery_: boolean = false;
  @State private modpackRecoveryLoading_: boolean = false;
  @State private modpackRecoveryFailed_: boolean = false;
  /** 一次只确认一条放弃操作；同一记录在处理期间不能从此面板重复恢复。 */
  @State private modpackDismissId_: string = '';
  /** 只保留当前可见恢复面板的扫描；运行中有新请求时至多补扫一次。 */
  private modpackRecoveryScan_: LocalModScanControl | undefined = undefined;
  private modpackRecoveryPending_: boolean = false;
  /** 面板退场后，尚未弹出的确认框和未处理的确认结果随该轮会话失效。 */
  private modpackRecoveryEpoch_: number = 0;

  /** ctrl.getState() 的快照，UI 渲染用 */
  @State private view_: ModSearchState = makeInitialSearchState();

  /** 正在下载中的卡片 id 集合（允许多个不同资源并发；同一资源不重复入队）。 */
  private downloadingProjectIds_: Set<string> = new Set<string>();

  // ===================== 详情 Sheet 状态（Phase R-3 收尾） =====================

  /** 详情 sheet 显示开关 */
  @State private showDetailSheet_: boolean = false;
  /** 仅表示版本目录请求失败；安装目标、文件地址与依赖错误另存，不影响完整目录浏览。 */
  @State private detailError_: string = '';
  /** 安装准备独立于详情展示；异步扫描、补地址或解依赖期间禁止提交安装。 */
  @State private detailPreparingInstall_: boolean = false;
  /** 当前文件不能安装的具体原因；为空不代表可安装，还须检查 ready 和目标快照。 */
  @State private detailInstallError_: string = '';
  /** 仅在当前选版、依赖计划和目标快照全部准备完成时为 true。 */
  @State private detailInstallReady_: boolean = false;
  /** 系统保存窗口返回前禁止重复唤起；它不代表已建立下载任务。 */
  @State private detailSavePickerPending_: boolean = false;
  /** false 时依赖卡仅展示远端直接声明，不能当作已解析且可勾选的安装计划。 */
  @State private detailDependenciesResolved_: boolean = false;
  /** 准备成功时绑定的真实安装目标，防止相同 MC/loader 的另一个实例误用旧计划。 */
  private detailPreparedMcDir_: string = '';
  private detailPreparedVersionId_: string = '';
  /** 只在当前文件通过另存准备后置位，安装计划的旧 ready 不得打开保存窗口。 */
  private detailPreparedForResourceSave_: boolean = false;
  /** 下载详情中的名称草稿；选版只刷新文件元数据，不能覆盖用户正在编辑的名称。 */
  @State private detailModpackName_: string = '';
  @State private detailModpackNameError_: string = '';
  /** 本地文件选择结束后的安装前详情。原根在打开文件选择器之前快照。 */
  @State private showLocalModpackDetail_: boolean = false;
  @State private localModpackName_: string = '';
  @State private localModpackNameError_: string = '';
  private localModpackArchive_: string = '';
  private localModpackRoot_: string = '';
  private localModpackFilesDir_: string = '';
  private detailOptionalIds_: string[] = [];
  /** 当前详情的展示快照；关闭请求保留它，真实退场后才回收为字段完整的空态。 */
  @State private detailProject_: RemoteProject = makeEmptyRemoteProject();
  /** 当前浏览版本：优先推荐适配目标的文件，无推荐时仍展示项目的最新客户端文件。 */
  @State private detailSelectedVersion_: RemoteVersion | null = null;
  /** 该项目全部版本列表（picker step 用） */
  @State private detailAllVersions_: RemoteVersion[] = [];
  /** primary file（决定下载大小、文件名） */
  @State private detailPrimaryFile_: RemoteFile | null = null;
  /** 依赖项展示 */
  @State private detailDeps_: ModDetailDepRow[] = [];
  /** 仅版本目录请求中的标记；选中文件和依赖准备不隐藏已经可浏览的版本。 */
  @State private detailLoading_: boolean = false;
  /** LocalModScanner 命中的本地版本 id（picker 用） */
  @State private detailInstalledVersionIds_: string[] = [];
  /** 本地已装的"主文件"引用（升级时真正替换旧文件用）；null=未装该 project。 */
  private detailInstalledPrimary_: InstalledPrimaryRef | null = null;

  /**
   * 防止重入的 fetch token —— 用户快速点多张卡时只保留最后一次的结果。
   * 每次 openDetail 自增；resolve 回写前比较，不一致则丢弃。
   */
  private detailFetchEpoch_: number = 0;
  /** Sheet 实例身份独立于请求代次；显示期间切源/换文件不更换实例身份。 */
  private detailSessionCounter_: number = 0;
  private detailSession_: number = 0;
  /** Native 已开始呈现的实例；同帧开关尚未呈现时不会依赖不存在的退出回调。 */
  private detailPresentedSession_: number = 0;
  /** 从请求关闭到真实退场结束的屏障，防止迟到点击重新建立有效请求。 */
  private detailClosing_: boolean = false;
  /** 页面析构后只取消普通字段工作，不再经任何迟到回调写入视图状态。 */
  private detailDisposed_: boolean = false;

  /** 缓存解析得到的全量 ResolvedDependency（含失败 / OPTIONAL 全集），install 时按勾选过滤 */
  private detailResolvedDeps_: ResolvedDependency[] = [];

  /** Phase 3 LocalModScanner 缓存（同 mcDir + versionId 之间共享一次扫描结果） */
  private localScanCache_: Map<string, LocalMod[]> = new Map<string, LocalMod[]>();
  /** 缓存失效代次：换实例、开关详情或安装结束后，在途旧扫描不能重新填入缓存。 */
  private localScanCacheEpoch_: number = 0;

  /**
   * 详情 sheet 内的本地扫描诊断信息（直接展示在版本选择卡底部）。
   * 让用户和我们都能直接看到"本地是否真的扫到、是否真的命中本 project"。
   */
  @State private detailScanInfo_: string = '';

  // ===================== 安装目标版本（沙箱 / 外部 双根可选） =====================
  // mcDir / currentMcVersion 是 Index 透传的"当前激活根 + 当前版本"，作为默认目标。
  // 用户可通过 VersionPickerSheet 改选到任一根下的任一已装版本；改选后下面这组
  // "有效目标"覆盖 props，安装 / 本地扫描 / 落地目录提示一律以它们为准。

  /** 有效安装根（.minecraft 绝对路径）。默认 = props.mcDir */
  @State private targetMcDir_: string = '';
  /** 有效安装版本 id。默认 = props.currentMcVersion */
  @State private targetVersionId_: string = '';
  /** 有效安装位置：'sandbox' | 'external'（用于 ContextCard 角标 + picker 初始页签） */
  @State private targetLocation_: string = 'sandbox';
  /** 目标版本是否真实存在（picker 选中的天然为真；初始按 availableVersions 校验） */
  @State private targetValid_: boolean = false;
  /** 三类资源各自记住明确的另存选择；切换类别不会替用户改写另一类别的保存模式。 */
  @State private customSaveKindIndices_: number[] = [];
  /** 手动选择的实例可在另一存储根；首页扫描结果只更新自动跟随的实例。 */
  private instanceTargetPicked_: boolean = false;

  /** 版本选择 Sheet 显隐 */
  @State private showVersionPicker_: boolean = false;
  /** 沙箱根 versions/ 下真实存在的版本（openVersionPicker 时扫描刷新） */
  @State private sandboxVersions_: string[] = [];
  /** 外部根 versions/ 下真实存在的版本（外部不可用时为空） */
  @State private externalVersions_: string[] = [];
  /** 版本选择器解析 MC 版本/loader 用的两根（openVersionPicker 时刷新） */
  @State private sandboxRoot_: string = '';
  @State private externalRoot_: string = '';
  /** 本设备外部存储是否可用（取得到 Download 路径） */
  @State private externalAvailable_: boolean = false;

  // ===================== 常驻搜索与二级筛选 =====================

  /**
   * 搜索栏始终是结果容器外的稳定节点；展开按钮只改变二级筛选区的显隐。
   * 加载、错误、空结果及列表滚动均不能重建搜索输入，也不能代替用户的筛选开关。
   * 整合包默认收起筛选以优先展示内容，其他资源沿用首次展开的入口习惯。
   */
  @State private headerCollapsed_: boolean = false;
  /** 当前内容区宽度（vp）；使用实际可用空间，避免平板侧栏或分屏使卡片过窄。 */
  @State private browseWidth_: number = 0;

  /** 四类资源共用自动退让端点，分类切换由几何复位移除不存在的辅助层。 */
  @State private retreatHidden_: number = 0;
  /** 负值表示新结果/尺寸上下文尚未开始浏览；冻结后不随辅助区收展或手动开关改变。 */
  @State private retreatAnchorInset_: number = -1;
  /** 逻辑端点先更新、视觉动画后完成，独立门控防止恢复动画中误接收受限测量。 */
  @State private retreatAnimating_: boolean = false;
  /** 动画期间保留起止覆盖范围，避免内容尚在滑出时点击穿透到下面的列表。 */
  @State private retreatHitHeight_: number = 0;
  private retreatAnimationEpoch_: number = 0;
  @State private retreatTargetHeight_: number = 0;
  @State private retreatLoaderHeight_: number = 0;
  @State private retreatSortHeight_: number = 0;
  /** 仅在完全展开时按实际可见索引评估长内容，收展本身不反复改变资格。 */
  private retreatScrollable_: boolean = false;
  /** 缓存各原生容器最后一次可见范围；同尺寸复位后索引不变时框架不会再发回调。 */
  private retreatListFirst_: number = -1;
  private retreatListLast_: number = -1;
  private retreatGridFirst_: number = -1;
  private retreatGridLast_: number = -1;
  private retreatSearchFocused_: boolean = false;
  private retreatViewportHeight_: number = 0;
  private retreatPolicy_: LayerRetreatPolicy = new LayerRetreatPolicy();
  /** 当前结果List独占控制器，只读真实总偏移，不向它发送补偿/定位滚动。 */
  private retreatScroller_: Scroller = new Scroller();
  /** 整合包Grid独占控制器，避免类别切换时与List复用同一原生绑定。 */
  private retreatGridScroller_: Scroller = new Scroller();
  private retreatReturning_: boolean = false;
  private retreatTouchActive_: boolean = false;
  private retreatHostActive_: boolean = false;

  // ===================== 运行时服务（aboutToAppear 注入） =====================

  private ctrl_: ModSearchController | null = null;
  // v6.5：installer_ 已下台。
  /** P2: 双源路由器（替代单一 ModrinthRepository） */
  private router_: ModSourceRouter | null = null;
  /** P2: 依赖解析器（基于 router_ 构造） */
  private resolver_: ModDependencyResolver | null = null;
  /** Phase 3：本地已装扫描器 */
  private scanner_: LocalModScanner | null = null;
  /** ModrinthRepository 引用，scanner 反查 sha1 时使用 */
  private modrinth_: ModrinthRepository | null = null;

  private debounceTimer_: number = 0;

  /** 译名库后台远程刷新完成的监听器引用（aboutToDisappear 注销用）。 */
  private translationListener_: (() => void) | null = null;

  /** 首屏搜索仅触发一次的守卫（本地译名就绪后 or 兜底超时，取先到者）。 */
  private initialSearchDone_: boolean = false;

  aboutToAppear() {
    this.detailDisposed_ = false;
    this.retreatHostActive_ = this.hostVisible;
    this.resetRetreat_();
    // Phase R-1：外部 DownloadTab 顶级 Tab 切换决定的默认资源类别
    if (this.defaultKindIdx >= 0 && this.defaultKindIdx <= 3) {
      this.kindIdx_ = this.defaultKindIdx;
    }
    this.headerCollapsed_ = this.kindIdx_ === 3;

    // 1. 构造服务（复用全局单例）
    let dm = DownloadManager.instance();
    let cache = getMetadataCacheStore();
    // 关键修复：把用户偏好闭包传给 Repository。
    //   - modSource='auto' / 'mcim' / 'official' 真正决定每次请求的源顺序
    //   - cacheRemoteMeta=false 时退化无缓存（保持新鲜度优先于流量）
    // 闭包每次请求时再 evaluate this.modSource / this.cacheRemoteMeta，因此
    // 用户在 SettingsTab 改了偏好，回到 ModBrowsePage 立刻生效，无需重建页面。
    let modeProvider: () => ModrinthSourceMode = () => this.resolveModrinthMode();
    let cacheEnabled: () => boolean = () => this.cacheRemoteMeta;
    let modrinth = new ModrinthRepository(dm, cache, modeProvider, USER_AGENT, cacheEnabled);
    // 把 ModSourceProber 的 MCIM 健康检查闭包传给 CurseForge 仓库——
    // mcim 挂掉时 isAvailable() 返回 false，ModSourceRouter 跳过本源，
    // 避免每次搜索都等 30s 超时（CurseForge 没 API Key，mcim 是唯一通路）。
    let curseforge = new CurseForgeRepository(dm, cache, USER_AGENT,
      () => isMcimAvailable(), cacheEnabled, (): CurseForgeFileSourceMode => this.resolveCurseForgeFileMode());
    this.router_ = new ModSourceRouter([modrinth, curseforge]);
    this.resolver_ = makeResolverFromRouter(this.router_);
    // v6.5：installer_ 已下台。
    this.ctrl_ = new ModSearchController(this.router_);
    this.modrinth_ = modrinth;
    this.scanner_ = new LocalModScanner(modrinth);

    // 译名库加载（本地优先，几十毫秒就绪）。首屏搜索**等译名就绪后只跑一次**：
    //   - 首屏即中文名（不再"先英文再重搜刷中文"闪一下）；
    //   - 省掉旧实现"无译名先搜一次 + 译名就绪重搜一次"的**多余一次网络搜索**（首开更快）；
    //   - 从根上消除"陈旧搜索清 loading → 暂无结果闪现"。
    // 失败/未就绪(返回 null)也照常触发首搜（降级英文），绝不因译名而卡住列表。
    loadModTranslationStores().then((stores: ModTranslationStores) => {
      if ((stores.mod !== null || stores.modpack !== null) && this.router_ !== null) {
        this.router_.setTranslationStores(stores.mod, stores.modpack);
      }
      this.doInitialSearch_();
    }).catch((e: Error) => {
      AppLogger.warn(TAG, '译名库加载失败 (non-fatal)', e, LOG_DOMAIN_DOWNLOAD);
      this.doInitialSearch_();
    });

    // 译名库后台远程刷新若带来更新 → 重新注入 + 重搜，让新增译名当场生效。
    this.translationListener_ = () => { this.onTranslationsRefreshed_(); };
    onTranslationStoresUpdated(this.translationListener_);

    // 1.5 初始化"安装目标"：默认沿用 Index 透传的当前激活根 + 当前版本。
    //     判定当前根是沙箱还是外部，给 picker 初始页签 + ContextCard 角标用。
    this.targetMcDir_ = this.mcDir;
    this.targetVersionId_ = this.currentMcVersion;
    this.externalAvailable_ = GameStorage.isExternalAvailable();
    let extRoot = GameStorage.externalMcDir();
    this.targetLocation_ = (extRoot.length > 0 && this.mcDir === extRoot) ? 'external' : 'sandbox';
    this.targetValid_ = this.targetMcDir_.length > 0 && this.currentMcVersion.length > 0
      && this.availableVersions.indexOf(this.currentMcVersion) >= 0;

    // 2. P0 修复 #2/#7：从目标版本提取 game version + 推断 loader（整合包/重命名版本名
    //    无版本号/无 loader 关键字，走快照/内容解析，避免拿到整合包名当 MC 版本）
    const saveFileOnly = this.usesCustomResourceSave_();
    this.gameVersionInput_ = saveFileOnly ? '' : resolveInstalledMcVersion(this.targetMcDir_, this.targetVersionId_);
    let detectedLoader = saveFileOnly ? '' : resolveInstalledLoader(this.targetMcDir_, this.targetVersionId_);
    // 原版（detected===''）保留 'fabric' 默认（搜模组最常见）
    this.loaderInput_ = this.kindIdx_ === 3 ? '' : (detectedLoader.length > 0 ? detectedLoader : 'fabric');

    // 3. 应用到控制器
    this.applyFiltersToController();

    // 4. 仅关闭网关且未明确官方时复用原可达性顺序提示。网关/官方档不得为选源
    // 额外访问MCIM；这不是正文吞吐测速，也不会给每个内容文件增加一组探测。
    if (!getRelayClient().isEnabled() && this.modSource !== 'official') {
      ensureModrinthRanking().catch((e: Error) => {
        AppLogger.warn(TAG, 'probe failed (non-fatal)', e, LOG_DOMAIN_DOWNLOAD);
      });
    }

    // 5. 首次搜索由译名库就绪回调触发（见上方 doInitialSearch_）。
    //    兜底：本地译名加载极快，但万一 loadModTranslationStores 异常/未按预期触发，
    //    600ms 后仍强制搜一次，保证列表一定会加载。
    setTimeout(() => { this.doInitialSearch_(); }, 600);
    this.inited_ = true;
  }

  /**
   * 外部资源胶囊复用同一个浏览器。只切换控制器类别，原查询、安装目标、排序、折叠和
   * TextInput节点继续存在；未初始化时由aboutToAppear读取最新Prop，不重复构造仓库或首搜。
   * 丢弃旧的输入去抖计时，当前查询同步应用到新类别；控制器epoch负责拒绝旧网络结果。
   */
  private externalKindChanged_(): void {
    const next: number = this.defaultKindIdx;
    if (!this.inited_ || !Number.isInteger(next) || next < 0 || next > 3 || next === this.kindIdx_) return;
    if (this.debounceTimer_ !== 0) { clearTimeout(this.debounceTimer_); this.debounceTimer_ = 0; }
    this.closeDetail();
    this.kindIdx_ = next;
    this.syncDefaultResourceTarget_();
    if (next !== 3) this.closeModpackRecovery_();
    // 同一个浏览器跨类别复用，不能将模组的Loader/目标高度带到没有这些层的资源页。
    this.resetRetreatGeometry_();
    this.applyFiltersToController();
    if (this.initialSearchDone_) this.triggerSearch(true);
  }

  /** 首屏搜索仅触发一次（本地译名就绪 or 兜底超时，取先到者）。 */
  private doInitialSearch_(): void {
    if (this.initialSearchDone_) return;
    this.initialSearchDone_ = true;
    this.triggerSearch(true);
  }

  aboutToDisappear() {
    this.retreatHostActive_ = false;
    this.retreatReturning_ = false;
    this.retreatTouchActive_ = false;
    // 退休旧动画完成回调，避免页面离开后解除新页面的测量锁。
    this.retreatAnimationEpoch_++;
    this.retreatPolicy_.reset();
    // 析构中禁止修改 @State。仅退休会话和异步身份，视图快照随组件销毁自然释放。
    this.detailDisposed_ = true;
    this.retireModpackRecoveryScan_();
    this.invalidateDetailWork_();
    this.detailSession_ = 0;
    this.detailPresentedSession_ = 0;
    this.detailClosing_ = false;
    if (this.debounceTimer_ !== 0) {
      clearTimeout(this.debounceTimer_);
      this.debounceTimer_ = 0;
    }
    // 注销译名库更新监听，避免累积
    if (this.translationListener_ !== null) {
      offTranslationStoresUpdated(this.translationListener_);
      this.translationListener_ = null;
    }
    // 释放服务引用，让 controller 持有的 hits 数组（可能数百个 RemoteProject）可被 GC
    this.ctrl_ = null;
    this.router_ = null;
    this.resolver_ = null;
    // v6.5：installer_ 已下台。
    this.scanner_ = null;
    this.modrinth_ = null;
  }

  /** 译名库经后台远程刷新有更新时回调：重新注入路由器 + 重搜刷新译名。 */
  private onTranslationsRefreshed_(): void {
    let stores = getCachedTranslationStores();
    if (stores === null || this.router_ === null) return;
    if (stores.mod === null && stores.modpack === null) return;
    this.router_.setTranslationStores(stores.mod, stores.modpack);
    if (this.inited_) this.triggerSearch(true);
  }

  /**
   * 根据用户偏好 `modSource` 解析最终的 ModrinthSourceMode。
   * 与 ModSourceProber.getModrinthSourceMode 形成两层决策：
   *   - 'auto'     → 走 prober 的自动探测结果（首次进入时尚未 probe 完成会回退 MCIM_FIRST）
   *   - 'mcim'     → 网关关闭时 MCIM_FIRST
   *   - 'official' → OFFICIAL_ONLY，仅官方 API/文件，自家网关照常可用
   */
  private resolveModrinthMode(): ModrinthSourceMode {
    // 网关开关意图决定候选约束；usable只决定Native路由，不授予镜像回退。关闭后
    // 仍读取原保存偏好，不通过改写modSource伪造“恢复”。
    return resolveModrinthSourcePreference(this.modSource, getModrinthSourceMode(), getRelayClient().isEnabled());
  }

  /** CF 文件 CDN 无须 API Key；仅对正文应用偏好，列表元数据继续现有 MCIM 通道。 */
  private resolveCurseForgeFileMode(): CurseForgeFileSourceMode {
    return resolveCurseForgeFileSourcePreference(this.modSource, getRelayClient().isEnabled());
  }

  /** 入队时冻结正文约束；首包、清单与冷恢复都使用同一纯策略，持久计划只可收紧。 */
  private onlyOfficialModpackFiles_(): boolean {
    return this.resolveCurseForgeFileMode() === CurseForgeFileSourceMode.OFFICIAL_ONLY;
  }

  // ===================== 构建 UI（v2 重构）=====================

  build() {
    Column() {
      // ============== Pinned 搜索框（始终渲染，不受 loading/error/empty 状态切换影响） ==============
      // 关键：必须放在 List 外面，否则 List 在 loading↔result 切换时会 unmount 整个 List
      // 包括其 header（搜索框），TextInput 重挂载会触发 onChange 形成无限循环。
      this.PinnedSearchHeader()

      // 导入与恢复为浏览操作，收起筛选或离线时仍可达；没有持久任务时不展示恢复入口。
      if (this.kindIdx_ === 3) {
        this.ModpackImportRow()
      }

      this.BrowseResults_()

      // ============== ModDetailSheet 锚点 ==============
      Column().width(0).height(0)
        .bindSheet($$this.showDetailSheet_, this.ModDetailSheetBuilder(), {
          height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_),
          // 一多：仅平板/PC 宽屏限宽（手机返回 undefined，绝不给底部抽屉加宽度）
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          // 平板/PC 居中卡片不再显示系统关闭按钮（会与 sheet 内功能按钮重叠）；底部抽屉用拖拽条
          dragBar: !centerSheetForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false,
          backgroundColor: this.theme.bgPrimary,
          blurStyle: BlurStyle.NONE,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          onWillAppear: this.detailWillAppearCallback_(),
          onWillDisappear: this.detailWillDisappearCallback_(),
          onDisappear: this.detailDidDisappearCallback_(),
        })

      // ============== VersionPickerSheet 锚点（选安装目标版本） ==============
      Column().width(0).height(0)
        .bindSheet($$this.showModpackRecovery_, this.ModpackRecoveryPanel(), {
          height: this.deviceForm === DeviceForm.PHONE
            ? detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_)
            : '70%', showClose: false, backgroundColor: this.theme.bgPrimary,
          onWillDisappear: (): void => { this.retireModpackRecoveryScan_(); },
        })

      Column().width(0).height(0)
        .bindSheet($$this.showVersionPicker_, this.VersionPickerBuilder(), {
          height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_),
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          dragBar: !centerSheetForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false,
          backgroundColor: this.theme.bgPrimary,
          blurStyle: BlurStyle.NONE,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          onDisappear: () => { this.showVersionPicker_ = false },
        })
      Column().width(0).height(0)
        .bindSheet($$this.showLocalModpackDetail_, this.LocalModpackDetailBuilder_(), {
          height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight, this.phoneSheetHeightPercent_),
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false, backgroundColor: this.theme.bgPrimary,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
        })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_, area) => {
      // ArkUI 返回 vp 布局宽度。仅在宽度真正改变时刷新，避免滚动触发重复布局。
      const nextWidth = area.width as number;
      const nextHeight = area.height as number;
      if (Math.abs(nextHeight - this.retreatViewportHeight_) > 1) {
        this.resetRetreatGeometry_();
        this.retreatViewportHeight_ = nextHeight;
      }
      if (nextWidth > 0 && Math.abs(nextWidth - this.browseWidth_) > 1) {
        this.browseWidth_ = nextWidth;
        this.resetRetreatGeometry_();
      }
    })
  }

  /** 固定几何的结果视口，辅助层在其顶部覆盖，不参与List父级的纵向占位。 */
  @Builder
  private BrowseResults_() {
    // 结果容器可按加载/错误/空态替换；上方操作区的身份和可达性保持不变。
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.view_.hits.length === 0) {
        // 空态仍在辅助区下方提供可操作空间，避免覆盖层挡住重试/清筛选入口。
        Column() {
          if (this.view_.loading) this.LoadingBlock('正在搜索...')
          else if (this.view_.errorMessage !== null) {
            this.ErrorBlock(describeSearchFailureForUser(this.view_.errorKind, this.view_.httpStatus, this.view_.errorMessage))
          } else this.EmptyBlock()
        }.id('mod-empty-state-viewport').width('100%').height('100%').padding({ top: this.retreatListInset_() })
      } else if (this.kindIdx_ === 3) {
        this.ModpackResultsGrid()
      } else {
        List({ space: 8, scroller: this.retreatScroller_ }) {
          // 三类资源均使用真正参与内容滚动的固定首项；收展不能改它的高度。
          ListItem() { Column().width('100%').height('100%') }
              .height(retreatLeadItemHeight(this.retreatListInset_(), 8))
              .id('mod-retreat-content-inset').focusable(false)
              .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          ForEach(this.view_.hits, (p: RemoteProject) => {
            ListItem() {
              Row() {
                ModCard({
                  theme: this.theme,
                  project: p,
                  onTap: (project: RemoteProject) => {
                    this.openDetail(project);
                  },
                })
              }
              .width('100%')
            }
          }, (p: RemoteProject) => p.source + ':' + p.id)

          // 底部"加载更多"
          if (this.view_.hasMore) {
            ListItem() {
              Row() {
                if (this.view_.loading) {
                  LoadingProgress().width(20).height(20).color(this.theme.actionText)
                  Text('加载中...').fontSize(12).fontColor(this.theme.textHint).margin({ left: 8 })
                } else {
                  Text('上滑加载更多').fontSize(12).fontColor(this.theme.textHint)
                }
              }
              .width('100%').height(40).justifyContent(FlexAlign.Center)
            }
          }

          // 底部"全部展示完"
          if (!this.view_.hasMore && this.view_.hits.length > 0) {
            ListItem() {
              Text('—— 已展示 ' + this.view_.hits.length + ' / ' + this.view_.totalHits + ' ——')
                .fontSize(11)
                .fontColor(this.theme.textHint)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 16 })
            }
          }
        }
        .width('100%')
        .height('100%')
        .id('resource-browser-results')
        // 扩大视口后即使内容恰好装满，也保留反向输入；短内容仍由退让资格禁止收起。
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .padding({ left: 16, right: 16, bottom: 16 })
        .onScrollStart(() => {
          // 新滚动开始不应在上一层动画中提前解除同向锁；动画完成会自行重新接收位移。
          if (!this.retreatAnimating_) this.retreatPolicy_.reset();
        })
        .onScrollFrameBegin((offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult => {
          return this.consumeRetreatFrame_(offset, state);
        })
        .onTouch((event: TouchEvent) => { this.observeRetreatTouch_(event); })
        .onReachStart(() => { this.restoreRetreatAtStart_(); })
        .onDidScroll((offset: number, state: ScrollState) => { this.observeRetreatPosition_(offset, state); })
        .onScrollStop(() => { this.observeRetreatStop_(); })
        .onScrollIndex((first: number, last: number) => {
          // 辅助区展开时的视口作为资格基准；完全收起后仍允许反向恢复。
          if (this.retreatHidden_ === 0) {
            this.retreatListFirst_ = first;
            this.retreatListLast_ = last;
            // 三类List均有固定首占位，真实资源索引从1开始；不能把占位算作资源。
            this.retreatScrollable_ = first > 1 || last < this.view_.hits.length;
          }
        })
        .onReachEnd(() => {
          if (this.view_.hasMore && !this.view_.loading) {
            this.loadNextPage();
          }
        })
      }
        // 四类资源的辅助层均覆盖在稳定结果视口上，正文尺寸不再随收展改变。
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            if (this.kindIdx_ !== 3) this.RetreatTarget_()
            if (!this.headerCollapsed_) this.ModRetreatFilters_()
          }.width('100%').backgroundColor(this.theme.bgPrimary).clip(true)
          if (this.retreatAnimating_ && this.retreatHitHeight_ > 0) {
            // 仅无子控件的透明保护层使用Block，不能阻断正常辅助控件的子节点命中。
            Column().width('100%').height(this.retreatHitHeight_).hitTestBehavior(HitTestMode.Block)
          }
        }.id('mod-retreat-overlay').width('100%')
        .height(this.retreatAnimating_ ? this.retreatHitHeight_
          : (this.retreatListInset_() > 0 ? this.retreatOverlayHeight_() : LayoutPolicy.fixAtIdealSize))
        .clip(true)
        .hitTestBehavior(this.retreatAnimating_ || this.retreatOverlayHeight_() > 0 ? HitTestMode.Default : HitTestMode.None)
    }.id('resource-browser-viewport').width('100%')
    .layoutWeight(1)
    .clip(true)
  }

  /** 模组、光影与资源包复用完整目标层；整合包创建独立实例，不显示安装目标。 */
  @Builder
  private RetreatTarget_() {
    Column() {
      Column() { this.ContextCard() }
        .width('100%').padding({ left: 16, right: 16, bottom: 8 }).flexShrink(0)
        .height((this.retreatAnimating_ || this.retreatHidden_ > 0)
          && this.retreatTargetHeight_ > 0 ? this.retreatTargetHeight_ : LayoutPolicy.fixAtIdealSize)
        .constraintSize({ minHeight: (this.retreatAnimating_ || this.retreatHidden_ > 0)
          ? this.retreatTargetHeight_ : 0 })
        .translate({ y: retreatLayerOffset(this.retreatTargetHeight_, this.retreatHidden_,
            this.headerCollapsed_ ? 0 : this.retreatSortHeight_ + this.retreatLoaderHeight_) })
        .renderFit(RenderFit.TOP_LEFT)
        .onAreaChange((_, area) => { this.measureRetreatHeight_(0, area); })
    }
    .id('mod-retreat-target')
    .width('100%').justifyContent(FlexAlign.Start)
    .height(this.retreatTargetHeight_ > 0
      ? this.retreatTargetVisible_() : LayoutPolicy.fixAtIdealSize)
    .clip(true)
    .enabled(this.retreatTargetHeight_ <= 0
      || (!this.retreatAnimating_ && this.retreatTargetVisible_() >= this.retreatTargetHeight_))
    .accessibilityLevel((this.retreatAnimating_ || this.retreatTargetVisible_() <= 0)
      ? 'no-hide-descendants' : 'auto')
  }

  /** 新查询、显式操作或尺寸变化恢复原手动布局，不改变筛选、目标或结果身份。 */
  private resetRetreat_(): void {
    this.retreatReturning_ = false;
    this.retreatTouchActive_ = false;
    this.retreatAnimationEpoch_++;
    this.retreatAnimating_ = false;
    this.retreatHitHeight_ = 0;
    this.retreatHidden_ = 0;
    this.retreatPolicy_.reset();
  }

  /**
   * 类别/尺寸变化释放冻结坐标，并抹掉本类别不存在的层。仍挂载的自然高保持到下一次
   * 真实测量：相同大小的节点未必再次发onAreaChange，不能清零后永远等不到测量。
   */
  private resetRetreatGeometry_(): void {
    this.resetRetreat_();
    this.retreatAnchorInset_ = -1;
    this.retreatScrollable_ = false;
    if (this.kindIdx_ === 3) this.retreatTargetHeight_ = 0;
    if (this.kindIdx_ === 1 || this.kindIdx_ === 2 || (this.kindIdx_ === 3 && this.browseWidth_ >= 600)) {
      this.retreatLoaderHeight_ = 0;
    }
  }

  /** 离开下载主Tab或宿主页隐藏时使旧完成回调失效，不改变查询、筛选或正文位置。 */
  private onRetreatHostVisible_(): void {
    this.retreatHostActive_ = this.hostVisible;
    this.resetRetreat_();
    if (!this.inited_) return;
    if (this.hostVisible) {
      this.refreshModpackRecovery_();
    } else {
      this.retireModpackRecoveryScan_();
    }
  }

  /** 只观察List自己的触点生命周期，不拦截或竞争原滚动手势。 */
  private observeRetreatTouch_(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.retreatPolicy_.cancelQueuedContinuation();
      this.retreatTouchActive_ = true;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.retreatTouchActive_ = false;
      this.retreatPolicy_.cancelQueuedContinuation();
    }
  }

  /** 原生stop可能先于新手势结束，只有没有活动触点时才取消剩余位移预算。 */
  private observeRetreatStop_(): void {
    if (!this.retreatTouchActive_) this.retreatPolicy_.cancelQueuedContinuation();
    this.restoreRetreatAtStart_(!this.retreatTouchActive_);
  }

  /** 完成实际位移后再核对位置，覆盖惯性、回弹及不经过frameBegin的滚动条回顶。 */
  private observeRetreatPosition_(offset: number, state: ScrollState): void {
    if (!this.retreatHostActive_) return;
    if (offset < -0.01) this.retreatReturning_ = true;
    else if (state === ScrollState.Scroll && offset > 0.01) this.retreatReturning_ = false;
    this.restoreRetreatAtStart_();
  }

  /**
   * 到真实起点时直接恢复全部自动层，不再等反向阈值或下一次有效Scroll帧。
   * 首占位部分可见不等于到顶，读取独占Scroller的实际总偏移；未绑定/退休/空态不推定0。
   * 只更新覆盖层端点，不改手动筛选、冻结inset、数据源或列表位置。模型目标已0时幂等。
   */
  private restoreRetreatAtStart_(settled: boolean = false): boolean {
    if (!this.retreatHostActive_ || this.view_.hits.length === 0
      || this.retreatHidden_ <= 0) return false;
    try {
      const position: OffsetResult = this.kindIdx_ === 3
        ? this.retreatGridScroller_.currentOffset() : this.retreatScroller_.currentOffset();
      if (!position || !retreatNeedsTopRestore(this.retreatHidden_, position.yOffset,
        this.retreatReturning_, settled && !this.retreatTouchActive_)) return false;
    } catch (_) { return false; }
    this.retreatPolicy_.reset();
    this.animateRetreatTo_(0);
    return true;
  }

  /** 初始排布使用完整辅助区自然高度；开始浏览后该内容坐标基准固定。 */
  private retreatListInset_(): number {
    const expanded: number = this.retreatTargetHeight_
      + (this.headerCollapsed_ ? 0 : this.retreatLoaderHeight_ + this.retreatSortHeight_);
    return retreatStableInset(this.retreatAnchorInset_, expanded);
  }

  /** 在首个用户帧或显式辅助操作前冻结，防止手动恢复也改变条目的内容坐标。 */
  private freezeRetreatAnchor_(): void {
    if (this.retreatAnchorInset_ >= 0) return;
    if (this.kindIdx_ !== 3 && this.retreatTargetHeight_ <= 0) return;
    if (!this.headerCollapsed_ && (this.retreatSortHeight_ <= 0
      || ((this.kindIdx_ === 0 || (this.kindIdx_ === 3 && this.browseWidth_ < 600))
        && this.retreatLoaderHeight_ <= 0))) return;
    this.retreatAnchorInset_ = this.retreatListInset_();
  }

  /** 只让可见覆盖区域阻挡命中；完整退场后不留下透明的触摸屏障。 */
  private retreatOverlayHeight_(hidden: number = this.retreatHidden_): number {
    const preceding: number = this.headerCollapsed_ ? 0 : this.retreatSortHeight_ + this.retreatLoaderHeight_;
    return retreatLayerHeight(this.retreatTargetHeight_, hidden, preceding) + (this.headerCollapsed_ ? 0
      : retreatLayerHeight(this.retreatLoaderHeight_, hidden, this.retreatSortHeight_)
        + retreatLayerHeight(this.retreatSortHeight_, hidden, 0));
  }

  /** 每次取下一层时重新读取实际层集合，避免缓存手动偏好或已失效目标。 */
  private retreatLayers_(): number[] {
    const layers: number[] = this.headerCollapsed_ ? [] : [this.retreatSortHeight_, this.retreatLoaderHeight_];
    // 自定义位置与已选实例同为可提交的资源目标，均随结果退让。整合包没有目标层。
    if (this.kindIdx_ !== 3 && (this.hasValidCurrentVersion() || this.usesCustomResourceSave_())) layers.push(this.retreatTargetHeight_);
    return layers;
  }

  private retreatInputEnabled_(): boolean {
    return this.retreatHostActive_ && !this.retreatSearchFocused_
      && !this.showDetailSheet_ && !this.showVersionPicker_ && !this.showModpackRecovery_
      && !this.showLocalModpackDetail_ && this.retreatAnchorInset_ >= 0
      && this.view_.hits.length > 0 && (this.retreatContentOverflows_() || this.retreatHidden_ > 0);
  }

  /** 当前结果数与最近实际可见范围共同判断长度；复位不能要求一个不会重发的索引事件。 */
  private retreatContentOverflows_(): boolean {
    const first: number = this.kindIdx_ === 3 ? this.retreatGridFirst_ : this.retreatListFirst_;
    const last: number = this.kindIdx_ === 3 ? this.retreatGridLast_ : this.retreatListLast_;
    if (!Number.isFinite(first) || !Number.isFinite(last) || first < 0 || last < 0) return this.retreatScrollable_;
    const lead: number = this.kindIdx_ === 3 && this.retreatListInset_() <= 0 ? 0 : 1;
    return this.view_.hits.length > 0 && (first > lead || last < this.view_.hits.length + lead - 1);
  }

  /**
   * 只在全展开时接受自然高度。父裁剪高度会成为子层的测量约束，收起期间的0或
   * padding底线不是自然高度；若回写容量，会发生残留一行、恢复失败及反复重布局。
   */
  private measureRetreatHeight_(layer: number, area: Area): void {
    const height: number = Number(area.height);
    if (this.retreatHidden_ > 0 || this.retreatAnimating_
      || !Number.isFinite(height) || height <= 0) return;
    // 退役节点可能仍有已投递的测量通知；不能重新创建当前类别不存在的层。
    if (layer === 0 && this.kindIdx_ === 3) return;
    if (layer === 1 && this.kindIdx_ !== 0 && !(this.kindIdx_ === 3 && this.browseWidth_ < 600)) return;
    if (layer === 0 && Math.abs(this.retreatTargetHeight_ - height) > 0.5) this.retreatTargetHeight_ = height;
    if (layer === 1 && Math.abs(this.retreatLoaderHeight_ - height) > 0.5) this.retreatLoaderHeight_ = height;
    if (layer === 2 && Math.abs(this.retreatSortHeight_ - height) > 0.5) this.retreatSortHeight_ = height;
  }

  /** 已有目标可完全退让；目标缺失时保留用户下一步需要的选择入口。 */
  private retreatTargetVisible_(): number {
    return retreatLayerHeight(this.retreatTargetHeight_, this.retreatHidden_,
      this.headerCollapsed_ ? 0 : this.retreatSortHeight_ + this.retreatLoaderHeight_);
  }

  /**
   * 结果List只提供方向段，达到阈值后整层滑出；正文获得完整原始位移。
   * 一次状态闭包只更新整层端点，不刷新数据或定位列表。反向时由框架从当前视觉位置
   * 重定向，完成回调只解除其自身世代的测量锁，不排队补播旧目标。
   */
  private consumeRetreatFrame_(offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult {
    if (state === ScrollState.Scroll) {
      if (offset < -0.01) this.retreatReturning_ = true;
      else if (offset > 0.01) this.retreatReturning_ = false;
      // 负向帧只核对当前事实，不用offset推算“马上到顶”；正向从0出发不触发此分支。
      if (offset < -0.01 && this.restoreRetreatAtStart_()) return { offsetRemain: offset };
    }
    if (state === ScrollState.Scroll) this.freezeRetreatAnchor_();
    const frame: RetreatFrame = this.retreatPolicy_.step(offset, this.retreatHidden_, this.retreatLayers_(),
      this.retreatInputEnabled_(), state === ScrollState.Scroll);
    this.animateRetreatTo_(frame.hidden);
    return { offsetRemain: frame.offsetRemain };
  }

  /** 整层端点变化的唯一动画入口；滚动与显式展开按钮复用同一测量/世代保护。 */
  private animateRetreatTo_(next: number): void {
    if (next === this.retreatHidden_) return;
    const epoch: number = ++this.retreatAnimationEpoch_;
    this.retreatHitHeight_ = Math.max(this.retreatHitHeight_, this.retreatOverlayHeight_(), this.retreatOverlayHeight_(next));
    this.retreatAnimating_ = true;
    this.getUIContext().animateTo({ duration: UiMotion.reduced() ? 0 : 180, curve: Curve.EaseOut,
      onFinish: (): void => {
        if (epoch !== this.retreatAnimationEpoch_) return;
        this.retreatAnimating_ = false;
        this.retreatHitHeight_ = 0;
        // 到顶完整恢复优先；否则只按当前活动手势已有预算串接一层，不制造滚动输入。
        if (this.restoreRetreatAtStart_()) return;
        const continuation: RetreatFrame = this.retreatPolicy_.finishTransition(this.retreatHidden_,
          this.retreatLayers_(), this.retreatInputEnabled_(), this.retreatTouchActive_);
        this.animateRetreatTo_(continuation.hidden);
      } }, (): void => { this.retreatHidden_ = next; });
  }

  /**
   * 箭头表示筛选区当前显示端点，不仅表示手动偏好。排序单独退场时Loader仍在，
   * 继续表示可收起；Loader与排序均退场后表示可展开。自动状态不回写手动偏好，
   * 避免卸载筛选节点并改变目标层的高度分配。
   */
  private filtersCollapsedForDisplay_(): boolean {
    if (this.headerCollapsed_) return true;
    const height: number = this.retreatSortHeight_ + this.retreatLoaderHeight_;
    return height > 0 && this.retreatHidden_ >= height - 0.5;
  }

  /** 自动退让后的“展开”直接恢复可见筛选；再次点击才明确改变用户的手动收起偏好。 */
  private toggleBrowseFilters_(): void {
    this.freezeRetreatAnchor_();
    if (!this.headerCollapsed_ && this.filtersCollapsedForDisplay_()) {
      this.retreatPolicy_.reset();
      this.animateRetreatTo_(0);
      return;
    }
    this.setHeaderCollapsed(!this.filtersCollapsedForDisplay_());
  }

  /**
   * 四类资源按实际控件形成完整层：光影/资源包只有排序，模组另有Loader；
   * 整合包窄屏分两层，宽屏沿用一行工具栏并整体退让，避免破坏原来的多列浏览布局。
   */
  @Builder
  private ModRetreatFilters_() {
    if (this.kindIdx_ === 0 || (this.kindIdx_ === 3 && this.browseWidth_ < 600)) {
    Column() {
      Column() {
        Scroll() { this.LoaderChipsRow() }
          .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      }
      .width('100%').padding({ bottom: 8 }).flexShrink(0)
      .height((this.retreatAnimating_ || this.retreatHidden_ > 0) && this.retreatLoaderHeight_ > 0
        ? this.retreatLoaderHeight_ : LayoutPolicy.fixAtIdealSize)
      .constraintSize({ minHeight: this.retreatAnimating_ || this.retreatHidden_ > 0 ? this.retreatLoaderHeight_ : 0 })
      .translate({ y: retreatLayerOffset(this.retreatLoaderHeight_, this.retreatHidden_, this.retreatSortHeight_) })
      .renderFit(RenderFit.TOP_LEFT)
      .onAreaChange((_, area) => { this.measureRetreatHeight_(1, area); })
    }
    .id('mod-retreat-loader').width('100%').justifyContent(FlexAlign.Start)
    .padding({ left: 16, right: 16 })
    .height(this.retreatLoaderHeight_ > 0
      ? retreatLayerHeight(this.retreatLoaderHeight_, this.retreatHidden_, this.retreatSortHeight_) : LayoutPolicy.fixAtIdealSize)
    .clip(true)
    .enabled(!this.retreatAnimating_ && this.retreatHidden_ <= this.retreatSortHeight_)
    .accessibilityLevel(this.retreatAnimating_ || retreatLayerHeight(this.retreatLoaderHeight_, this.retreatHidden_, this.retreatSortHeight_) <= 0
      ? 'no-hide-descendants' : 'auto')
    }
    Column() {
      Column() {
        if (this.kindIdx_ === 3 && this.browseWidth_ >= 600) {
          Row({ space: 16 }) {
            Scroll() { this.LoaderChipsRow() }
              .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
            this.SortButton()
          }.width('100%').alignItems(VerticalAlign.Center)
        } else this.SortRow()
      }
        .width('100%').padding({ bottom: 8 }).flexShrink(0)
        .height((this.retreatAnimating_ || this.retreatHidden_ > 0) && this.retreatSortHeight_ > 0
          ? this.retreatSortHeight_ : LayoutPolicy.fixAtIdealSize)
        .constraintSize({ minHeight: this.retreatAnimating_ || this.retreatHidden_ > 0 ? this.retreatSortHeight_ : 0 })
        .translate({ y: retreatLayerOffset(this.retreatSortHeight_, this.retreatHidden_, 0) })
        .renderFit(RenderFit.TOP_LEFT)
        .onAreaChange((_, area) => { this.measureRetreatHeight_(2, area); })
    }
    .id('mod-retreat-sort').width('100%').justifyContent(FlexAlign.Start)
    .padding({ left: 16, right: 16 })
    .height(this.retreatSortHeight_ > 0
      ? retreatLayerHeight(this.retreatSortHeight_, this.retreatHidden_, 0) : LayoutPolicy.fixAtIdealSize)
    .clip(true)
    .enabled(!this.retreatAnimating_ && this.retreatHidden_ <= 0)
    .accessibilityLevel(this.retreatAnimating_ || retreatLayerHeight(this.retreatSortHeight_, this.retreatHidden_, 0) <= 0
      ? 'no-hide-descendants' : 'auto')
  }

  /**
   * 常驻搜索下方的第二层：展开时才显示加载器和排序。
   * 宽屏整合包将两者排在同一工具行；窄屏允许加载器横向滚动，避免压缩点击热区。
   * 目标版本卡片由外层稳定展示，本面板只管理筛选与排序。
   */
  @Builder
  BrowseFilterPanel() {
    Column({ space: 8 }) {
      if (this.kindIdx_ === 3 && this.browseWidth_ >= 600) {
        Row({ space: 16 }) {
          Scroll() { this.LoaderChipsRow() }
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
          this.SortButton()
        }.width('100%').alignItems(VerticalAlign.Center)
      } else {
        if (this.kindIdx_ === 0 || this.kindIdx_ === 3) {
          Scroll() { this.LoaderChipsRow() }
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
        }
        this.SortRow()
      }
    }
    .width('100%').padding({ left: 16, right: 16, bottom: 8 })
  }

  /** 手机保持单列；平板/电脑按内容区每列至少 320vp 排为一至三列，分屏随宽度降列。 */
  private modpackColumnCount_(): number {
    if (this.deviceForm === DeviceForm.PHONE) return 1;
    return Math.max(1, Math.min(3, Math.floor((this.browseWidth_ - 32 + 12) / 332)));
  }

  /** Grid 的列模板由当前可用空间生成，不能只使用整个窗口的断点。 */
  private modpackColumnsTemplate_(): string {
    return '1fr '.repeat(this.modpackColumnCount_()).trim();
  }

  /**
   * 整合包结果使用同一网格容器完成单列/多列切换，项目 key 与详情回调保持稳定。
   * 分页继续由生产搜索控制器负责；末尾完整跨列，并在内容尾部预留悬浮导航的空间。
   */
  @Builder
  ModpackResultsGrid() {
    // GridLayoutOptions明确首占位与尾状态跨完整一行；各列不会重复制造辅助区占位。
    Grid(this.retreatGridScroller_, { regularSize: [1, 1],
      irregularIndexes: this.retreatListInset_() > 0 ? [0, this.view_.hits.length + 1] : [this.view_.hits.length] }) {
      if (this.retreatListInset_() > 0) {
        GridItem() { Column().width('100%').height('100%') }
          .height(retreatLeadItemHeight(this.retreatListInset_(), 12))
          .id('modpack-retreat-content-inset').focusable(false)
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      ForEach(this.view_.hits, (project: RemoteProject) => {
        GridItem() {
          ModpackCard({ theme: this.theme, project: project,
            onTap: (selected: RemoteProject) => { this.openDetail(selected); } })
        }.width('100%')
      }, (project: RemoteProject): string => project.source + ':' + project.id)
      GridItem() {
        Column() {
          Row({ space: 8 }) {
            if (this.view_.loading) {
              LoadingProgress().width(20).height(20).color(this.theme.actionText)
            }
            Text(this.view_.hasMore ? (this.view_.loading ? '加载中…' : '上滑加载更多') : '已展示全部结果')
              .fontSize(12).fontColor(this.theme.textSecondary)
          }.height(44).justifyContent(FlexAlign.Center)
        }
        .width('100%').height(44 + floatingDockReserveHeight(this.bottomSafeHeight))
        .alignItems(HorizontalAlign.Center)
      }
    }.columnsTemplate(this.modpackColumnsTemplate_()).columnsGap(12).rowsGap(12)
    .width('100%').height('100%').padding({ left: 16, right: 16 })
    .id('modpack-browser-results')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .onScrollStart(() => { if (!this.retreatAnimating_) this.retreatPolicy_.reset(); })
    .onScrollFrameBegin((offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult => {
      return this.consumeRetreatFrame_(offset, state);
    })
    .onTouch((event: TouchEvent) => { this.observeRetreatTouch_(event); })
    .onReachStart(() => { this.restoreRetreatAtStart_(); })
    .onDidScroll((offset: number, state: ScrollState) => { this.observeRetreatPosition_(offset, state); })
    .onScrollStop(() => { this.observeRetreatStop_(); })
    .onScrollIndex((first: number, last: number) => {
      if (this.retreatHidden_ !== 0) return;
      this.retreatGridFirst_ = first;
      this.retreatGridLast_ = last;
      // 与List一样只统计真实结果是否超出视口，跨列占位和尾部状态不充当长列表证据。
      const lead: number = this.retreatListInset_() > 0 ? 1 : 0;
      this.retreatScrollable_ = first > lead || last < this.view_.hits.length + lead - 1;
    })
    .onReachEnd(() => {
      if (this.view_.hasMore && !this.view_.loading) this.loadNextPage();
    })
  }

  /** VersionPickerSheet builder（被 bindSheet 引用） */
  @Builder
  VersionPickerBuilder() {
    VersionPickerSheet({
      theme: this.theme,
      sandboxVersions: this.sandboxVersions_,
      externalVersions: this.externalVersions_,
      sandboxMcDir: this.sandboxRoot_,
      externalMcDir: this.externalRoot_,
      externalAvailable: this.externalAvailable_,
      selectedLocation: this.targetLocation_,
      selectedVersionId: this.usesCustomResourceSave_() ? '' : this.targetVersionId_,
      initialTab: this.targetLocation_ === 'external' ? 1 : 0,
      allowCustomResourceSave: supportsCustomResourceSave(this.currentBrowseKind_()),
      customResourceSaveSelected: this.usesCustomResourceSave_(),
      onPickCustomResourceSave: (): void => { this.onPickCustomResourceSave_(); },
      onPick: (location: string, versionId: string) => { this.onPickVersion(location, versionId) },
      onClose: () => { this.showVersionPicker_ = false },
    })
  }

  /** ModDetailSheet builder（被 bindSheet 引用） */
  @Builder
  ModDetailSheetBuilder() {
    ModDetailSheet({
      theme: this.theme,
      project: this.detailProject_,
      selectedVersion: this.detailSelectedVersion_,
      primaryFile: this.detailPrimaryFile_,
      dependencies: this.detailDeps_,
      allVersions: this.detailAllVersions_,
      installedVersionIds: this.detailInstalledVersionIds_,
      loading: this.detailLoading_,
      blockingError: this.detailError_,
      preparingInstall: this.detailPreparingInstall_,
      installBlockReason: this.detailInstallError_,
      installReady: this.detailInstallReady_,
      saveFileOnly: this.usesCustomResourceSave_(this.detailProject_.kind),
      savePickerPending: this.detailSavePickerPending_,
      dependenciesResolved: this.detailDependenciesResolved_,
      modpackName: this.detailModpackName_,
      modpackNameError: this.detailModpackNameError_,
      onModpackNameChange: (value: string): void => { this.updateDetailModpackName_(value); },
      scanInfo: this.detailScanInfo_,
      // 浏览时目标卡允许退让，实际安装动作旁继续显示同一父页校验的目标身份。
      installTargetLabel: this.kindIdx_ !== 3 ? (this.targetVersionId_ || '未选择版本') : '',
      installTargetLocation: this.targetLocation_ === 'external' ? '外部' : '沙箱',
      onInstall: () => { this.confirmInstallFromSheet() },
      onOpenWebsite: () => { this.openWebsiteFromSheet() },
      onOpenUrl: (url: string) => { this.openExternalUrl_(url) },
      onOpenCrossSourceWeb: (source: ModSource) => {
        this.openCrossSourceWeb(source).catch((e: Error) => {
          AppLogger.warn(TAG, 'openCrossSourceWeb failed', e, LOG_DOMAIN_DOWNLOAD);
        });
      },
      onSwitchSource: (source: ModSource) => {
        this.switchDetailSource(source).catch((e: Error) => {
          AppLogger.warn(TAG, 'switchDetailSource failed', e, LOG_DOMAIN_DOWNLOAD);
        });
      },
      onClose: () => { this.closeDetail() },
      onToggleDep: (key: string) => { this.toggleDetailDep(key) },
      onSelectAllDeps: () => { this.selectAllDetailDeps() },
      onSelectVersion: (v: RemoteVersion) => { this.pickDetailVersion(v) },
    })
  }

  /** 本地导入的安装前详情，名称输入和在线资源详情共用样式；短屏可滚动内容。 */
  @Builder
  LocalModpackDetailBuilder_() {
    Column() {
    // 接管原系统叉号，仍通过原绑定flag收起；名称草稿和安装请求不由标题组件处理。
    ImmersiveTitleScaffold({ title: '导入整合包', theme: this.theme, modal: true,
      closeLabel: '关闭整合包导入详情', surfaceColor: this.theme.bgPrimary,
      onClose: (): void => { this.showLocalModpackDetail_ = false },
      content: (): void => { this.ImmersiveTitleContent1_(); }
    })
    }.width('100%').height('100%')
  }

  /** 在线草稿只在当前下载详情中编辑，开始安装时以值传入任务。 */
  private updateDetailModpackName_(value: string): void {
    if (!this.detailInteractionActive_()) return;
    this.detailModpackName_ = value;
    this.detailModpackNameError_ = validateModpackVersionName(value);
  }

  /** 本地开始按钮与在线入口一样，先校验并快照名称，再创建独立安装任务。 */
  private confirmLocalModpack_(): void {
    this.localModpackNameError_ = validateModpackVersionName(this.localModpackName_);
    if (this.localModpackNameError_.length > 0 || this.localModpackArchive_.length === 0) return;
    let task = new ModpackInstallTask({
      title: this.localModpackName_.trim(), subtitle: '整合包 · 本地导入',
      versionName: this.localModpackName_.trim(), archivePath: this.localModpackArchive_,
      mcDir: this.localModpackRoot_, filesDir: this.localModpackFilesDir_,
      existingVersions: this.availableVersions, requireConfirmation: true,
      officialFilesOnly: this.onlyOfficialModpackFiles_(),
      resolveCfFile: createModpackFileResolver(this.cacheRemoteMeta, this.onlyOfficialModpackFiles_(),
        this.resolveCurseForgeFileMode() === CurseForgeFileSourceMode.OFFICIAL_FIRST),
    });
    this.showLocalModpackDetail_ = false;
    this.localModpackArchive_ = '';
    this.runModpackInstall_(task);
  }

  /** 只有恢复面板可见才读取候选。分类浏览和后台安装终态不为预先统计名单做扫描。 */
  private refreshModpackRecovery_(): void {
    if (this.detailDisposed_ || !this.hostVisible || this.kindIdx_ !== 3 || !this.showModpackRecovery_) return;
    const ctx = this.uiCtx();
    if (ctx === undefined) return;
    this.modpackRecoveryPending_ = true;
    if (this.modpackRecoveryScan_ !== undefined) return;
    const scan = new LocalModScanControl();
    this.modpackRecoveryScan_ = scan;
    this.modpackRecoveryLoading_ = true;
    this.modpackRecoveryFailed_ = false;
    void this.readModpackRecovery_(ctx.filesDir, scan);
  }

  /** 安装终态若与扫描重叠，丢弃可能早于终态的结果并补读；已退休的扫描不能写入新分类。 */
  private async readModpackRecovery_(filesDir: string, scan: LocalModScanControl): Promise<void> {
    try {
      while (!scan.isCancelled() && this.modpackRecoveryPending_) {
        this.modpackRecoveryPending_ = false;
        try {
          const items = await scanModpackRecovery(filesDir, scan);
          if (!scan.isCancelled() && !this.modpackRecoveryPending_) this.modpackRecovery_ = items;
        } catch (e) {
          if (!scan.isCancelled() && !this.modpackRecoveryPending_) {
            AppLogger.warn(TAG, '读取整合包恢复记录失败', e as Error, LOG_DOMAIN_DOWNLOAD);
            this.modpackRecoveryFailed_ = true;
          }
        }
      }
    } finally {
      if (this.modpackRecoveryScan_ === scan) {
        this.modpackRecoveryScan_ = undefined;
        this.modpackRecoveryLoading_ = false;
      }
    }
  }

  /** 离开可见范围时撤销提交资格；销毁阶段只操作普通字段，避免修改 ArkUI 状态。 */
  private retireModpackRecoveryScan_(): void {
    this.modpackRecoveryEpoch_++;
    this.modpackRecoveryPending_ = false;
    this.modpackRecoveryScan_?.cancel();
    this.modpackRecoveryScan_ = undefined;
  }

  /** 先展示恢复面板，再发起只读扫描。 */
  private openModpackRecovery_(): void {
    this.showModpackRecovery_ = true;
    this.refreshModpackRecovery_();
  }

  /** 主动关闭面板或选择恢复时撤销这一轮尚未返回的结果。 */
  private closeModpackRecovery_(): void {
    this.showModpackRecovery_ = false;
    this.retireModpackRecoveryScan_();
  }

  private resumeModpack_(item: ModpackRecoveryItem): void {
    if (this.modpackDismissId_ === item.id) return;
    let ctx = this.uiCtx();
    if (ctx === undefined) return;
    this.closeModpackRecovery_();
    let id = 'modpack:' + item.id;
    if (getDownloadTaskRegistry().getAdapter(id) !== null) {
      this.onOpenDownloadTask(id); return;
    }
    let task = new ModpackInstallTask({ title: item.title, sessionId: item.id,
      filesDir: ctx.filesDir, mcDir: item.mcDir, existingVersions: this.availableVersions,
      requireConfirmation: true, officialFilesOnly: this.onlyOfficialModpackFiles_(),
      resolveCfFile: createModpackFileResolver(this.cacheRemoteMeta, this.onlyOfficialModpackFiles_(),
        this.resolveCurseForgeFileMode() === CurseForgeFileSourceMode.OFFICIAL_FIRST) });
    this.runModpackInstall_(task);
  }

  /** 同一面板关闭或切出分类后，迟到结果不能弹窗或刷新离屏列表。 */
  private modpackRecoveryVisible_(): boolean {
    return !this.detailDisposed_ && this.hostVisible && this.kindIdx_ === 3 && this.showModpackRecovery_;
  }

  /** 只为选中的会话读取提交状态。确认后交给任务层重验并持久化，UI 不直接操作文件。 */
  private async confirmDismissModpack_(item: ModpackRecoveryItem): Promise<void> {
    if (!this.modpackRecoveryVisible_() || this.modpackDismissId_.length > 0) return;
    const ctx = this.uiCtx();
    if (ctx === undefined) return;
    const epoch = this.modpackRecoveryEpoch_;
    const name = item.versionName.length > 0 ? item.versionName : item.title;
    this.modpackDismissId_ = item.id;
    try {
      const kind = await readModpackRecoveryKind(ctx.filesDir, item.id);
      if (epoch !== this.modpackRecoveryEpoch_ || !this.modpackRecoveryVisible_()) return;
      const repair = kind === 'repair';
      const action = repair ? '不再补齐' : '放弃安装';
      const choice = await this.getUIContext().getPromptAction().showDialog({
        title: action + '「' + name + '」？',
        message: repair ? '此版本将从继续安装列表移除。已安装的实例、存档和配置会保留。'
          : '本次安装将停止并从列表移除。以后仍可从整合包详情重新安装。',
        buttons: [
          { text: '返回', color: this.theme.textSecondary as string },
          { text: action, color: this.theme.errorText as string },
        ],
      }).catch((): undefined => undefined);
      if (choice?.index !== 1 || epoch !== this.modpackRecoveryEpoch_ || !this.modpackRecoveryVisible_()) return;
      const cleaned = await abandonModpackRecovery(ctx.filesDir, item.id, kind);
      if (!this.modpackRecoveryVisible_()) return;
      // 持久标记已经写入。先移除该条，再废弃可能早于放弃动作的扫描结果并重读。
      this.modpackRecovery_ = this.modpackRecovery_.filter((candidate: ModpackRecoveryItem): boolean => candidate.id !== item.id);
      this.refreshModpackRecovery_();
      if (epoch === this.modpackRecoveryEpoch_) {
        this.toast((repair ? '已停止补齐' : '已放弃安装') + (cleaned ? '' : '，部分临时文件已保留'));
      }
    } catch (e) {
      const error = e as Error;
      AppLogger.warn(TAG, '放弃整合包恢复失败', error, LOG_DOMAIN_DOWNLOAD);
      if (this.modpackRecoveryVisible_()) {
        this.refreshModpackRecovery_();
        if (epoch === this.modpackRecoveryEpoch_) this.toast('处理安装记录失败：' + error.message);
      }
    } finally {
      if (!this.detailDisposed_) this.modpackDismissId_ = '';
    }
  }

  @Builder
  ModpackRecoveryRow() {
    // 固定入口无需为显示数量或判断显隐提前读取磁盘。
    Button('继续安装')
      .height(28).fontSize(12).fontColor(this.theme.actionText)
      .backgroundColor(this.theme.primaryLight)
      .padding({ left: 12, right: 12 })
      .responseRegion({ x: 0, y: -8, width: '100%', height: 44 })
      .onClick(() => { this.openModpackRecovery_(); })
  }

  @Builder
  ModpackRecoveryPanel() {
    Column() {
    // 复用完整模态标题，系统showClose关闭以避免两个叉号；原恢复入口保持原动作。
    ImmersiveTitleScaffold({ title: '继续安装与补齐', theme: this.theme, modal: true,
      closeLabel: '关闭安装恢复列表', surfaceColor: this.theme.bgPrimary,
      onClose: (): void => { this.closeModpackRecovery_(); },
      content: (): void => { this.ImmersiveTitleContent2_(); }
    })
    }.width('100%').height('100%')
  }

  private sortLabel_(): string {
    if (this.sortInput_ === SortBy.RELEVANCE) return '按相关度';
    if (this.sortInput_ === SortBy.NEWEST) return '按发布时间';
    if (this.sortInput_ === SortBy.UPDATED) return '按更新时间';
    return '按下载量';
  }

  /** 实际提交所选排序，选项与标签共享 SortBy，避免只有外观没有行为。 */
  private chooseSort_(): void {
    // ActionMenu 的颜色类型比普通组件的 ResourceColor 更窄，只接受 string/Resource。
    let textColor = this.theme.textPrimary;
    // 当前主题色板提供字面量颜色；窄类型菜单的降级值也跟随主题，不额外固定蓝色。
    let menuColor: string = typeof textColor === 'string' ? textColor : this.theme.actionText as string;
    this.getUIContext().getPromptAction().showActionMenu({
      title: '排序方式', buttons: [
        { text: '相关度', color: menuColor }, { text: '下载量', color: menuColor },
        { text: '最新发布', color: menuColor }, { text: '最近更新', color: menuColor }],
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      let values: SortBy[] = [SortBy.RELEVANCE, SortBy.DOWNLOADS, SortBy.NEWEST, SortBy.UPDATED];
      if (result.index < 0 || result.index >= values.length) return;
      this.sortInput_ = values[result.index]; this.sortExplicit_ = true;
      this.applyFiltersToController(); this.triggerSearch(true);
    }).catch((): void => {});
  }

  private searchPlaceholder(): string {
    if (this.kindIdx_ === 1) return '搜索资源包';
    if (this.kindIdx_ === 2) return '搜索光影';
    if (this.kindIdx_ === 3) return '搜索整合包';
    return '搜索模组';
  }

  /** 把内部 kindIdx 转为用户可读的资源类型标签（Context Card / 状态栏用） */
  private currentKindLabel(): string {
    if (this.kindIdx_ === 1) return '资源包';
    if (this.kindIdx_ === 2) return '光影';
    if (this.kindIdx_ === 3) return '整合包';
    return '模组';
  }

  // ===================== @Builder 辅助 =====================

  /**
   * 目标卡两种模式共用原安装卡的三行测量结构：标题和角标、目标名、说明。
   * 另存只替换文字与语义，保持卡片和退让层的自然高度。切换入口仍打开版本选择面板。
   */
  @Builder
  ContextCard() {
    Row({ space: 10 }) {
      AppIcon({ name: AppIconName.Folder, iconSize: 16, color: this.theme.textSecondary })
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(this.usesCustomResourceSave_() ? '下载到' : '安装到')
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textHint)
          Text(this.usesCustomResourceSave_() ? '另存' : (this.targetLocation_ === 'external' ? '外部' : '沙箱'))
            .fontSize(10)
            .fontWeight(600)
            .fontColor(!this.usesCustomResourceSave_() && this.targetLocation_ === 'external'
              ? this.theme.actionText : this.theme.textSecondary)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(6)
            .backgroundColor(!this.usesCustomResourceSave_() && this.targetLocation_ === 'external'
              ? this.theme.primaryLight : this.theme.bgInput)
        }
        .alignItems(VerticalAlign.Center)

        Text(this.usesCustomResourceSave_() ? '自定义位置' : (this.targetVersionId_.length > 0 ? this.targetVersionId_ : '未选择版本'))
          .id(this.usesCustomResourceSave_() ? 'mod-custom-save-target' : 'mod-instance-target')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(this.usesCustomResourceSave_() || this.hasValidCurrentVersion() ? this.theme.textPrimary : this.theme.errorText)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 4 }) {
          Text(this.usesCustomResourceSave_() ? '下载时选择保存位置'
            : (this.gameVersionInput_.length > 0 ? 'MC ' + this.gameVersionInput_ : '全部 MC 版本'))
            .fontSize(11)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!this.usesCustomResourceSave_() && this.kindIdx_ === 0 && this.loaderInput_.length > 0) {
            Text('·')
              .fontSize(11)
              .fontColor(this.theme.textHint)
            Text(this.capitalize(this.loaderInput_))
              .fontSize(11)
              .fontWeight(500)
              .fontColor(this.theme.actionText)
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // "切换" 按钮 —— 弹出 VersionPickerSheet
      Row({ space: 4 }) {
        AppIcon({ name: AppIconName.Game, iconSize: 12, color: this.theme.actionText })
        Text('切换')
          .fontSize(12)
          .fontWeight(600)
          .fontColor(this.theme.actionText)
      }
      .height(28)
      .padding({ left: 12, right: 12 })
      .borderRadius(14)
      .backgroundColor(this.theme.primaryLight)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => { this.openVersionPicker() })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
  }

  /** 搜索栏身份保持稳定；固定外壳与版本页共用DownloadSearchField。 */
  @Builder
  PinnedSearchHeader() { this.SearchBox() }

  /** 查询仍归资源浏览器，保持输入去抖、清除后立即搜索及实际筛选箭头的原语义。 */
  @Builder
  SearchBox() {
    DownloadSearchField({
      theme: this.theme, text: this.queryInput_, placeholder: this.searchPlaceholder(),
      controlId: 'resource-browser-search', showFilterToggle: true,
      filtersCollapsed: this.filtersCollapsedForDisplay_(),
      onTextChange: (value: string): void => {
        this.resetRetreat_();
        this.queryInput_ = value;
        this.debouncedSearch();
      },
      onInputFocus: (): void => { this.retreatSearchFocused_ = true; this.resetRetreat_(); },
      onInputBlur: (): void => { this.retreatSearchFocused_ = false; },
      onClear: (): void => {
        this.queryInput_ = '';
        this.applyFiltersToController();
        this.triggerSearch(true);
      },
      onToggleFilters: (): void => { this.toggleBrowseFilters_(); },
    })
  }

  /** Loader chips 行（与设计稿 Screen B 一致：Fabric / Forge / NeoForge / Quilt） */
  @Builder
  LoaderChipsRow() {
    Row({ space: 8 }) {
      this.LoaderChip('')
      this.LoaderChip('fabric')
      this.LoaderChip('forge')
      this.LoaderChip('neoforge')
      this.LoaderChip('quilt')
    }
    .width('100%')
  }

  /** 窄屏筛选中的排序行；整合包统计放在稳定操作行，避免重复占据首屏。 */
  @Builder
  SortRow() {
    Row() {
      // 左侧统计
      if (this.kindIdx_ === 3) {
        Text('排序方式').fontSize(12).fontColor(this.theme.textSecondary).layoutWeight(1)
      } else if (this.view_.totalHits > 0) {
        Text('共 ' + this.view_.totalHits + ' 条 · ' + this.sortLabel_())
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.textSecondary)
          .layoutWeight(1)
      } else if (this.usesCustomResourceSave_()) {
        Text('下载时选择保存位置').fontSize(11).fontColor(this.theme.textHint).layoutWeight(1)
      } else if (this.hasValidCurrentVersion()) {
        Text(this.computeInstallDirShortcut())
          .fontSize(11)
          .fontColor(this.theme.textHint)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
          .layoutWeight(1)
      } else {
        Text('请先在首页选择 / 下载一个 MC 版本')
          .fontSize(11)
          .fontColor(this.theme.errorText)
          .layoutWeight(1)
      }

      this.SortButton()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 排序标签直接展示已提交的值；宽窄布局复用同一菜单，不产生仅改变外观的筛选。 */
  @Builder
  SortButton() {
    Row({ space: 8 }) {
      Text(this.sortLabel_()).fontSize(12).fontColor(this.theme.textSecondary)
      AppIcon({ name: AppIconName.ChevronDown, iconSize: 12, color: this.theme.textSecondary })
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(14)
    .responseRegion({ x: 0, y: -9, width: '100%', height: 44 })
    .backgroundColor(this.theme.bgCard).alignItems(VerticalAlign.Center)
    .accessibilityText('排序方式：' + this.sortLabel_()).focusable(true)
    .onClick(() => { this.chooseSort_(); })
  }

  /** 首字母大写（loader 名展示用） */
  private capitalize(s: string): string {
    if (s.length === 0) return s
    return s.charAt(0).toUpperCase() + s.substring(1)
  }

  /** 取 UIAbilityContext（EntryAbility 写入 AppStorage；用于解析沙箱根） */
  private uiCtx(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  }

  /**
   * 扫描某个 .minecraft 根下 versions/ 里真实存在的版本（含有效 <id>.jar，>1MB），降序返回。
   * 与 VersionSettingsPage.scanVersions 同一判定口径，保证"真实存在的版本号"一致。
   */
  private scanRootVersions(root: string): string[] {
    let versionsDir = root + '/versions';
    let result: string[] = [];
    try {
      let entries = fs.listFileSync(versionsDir);
      for (let name of entries) {
        let jarPath = versionsDir + '/' + name + '/' + name + '.jar';
        try {
          let st = fs.statSync(jarPath);
          if (st.size > 1024 * 1024) result.push(name);
        } catch (e) { /* 无 jar，跳过 */ }
      }
    } catch (e) { /* versions 目录不存在 */ }
    result.sort((a: string, b: string) => (a > b ? -1 : (a < b ? 1 : 0)));
    return result;
  }

  /** 打开版本选择 Sheet：现扫一遍沙箱 / 外部两根的真实版本再弹出 */
  private openVersionPicker(): void {
    let ctx = this.uiCtx();
    let sandboxRoot = ctx !== undefined ? GameStorage.sandboxMcDir(ctx) : this.mcDir;
    let extRoot = GameStorage.externalMcDir();
    this.sandboxRoot_ = sandboxRoot;
    this.externalRoot_ = extRoot;
    this.sandboxVersions_ = sandboxRoot.length > 0 ? this.scanRootVersions(sandboxRoot) : [];
    this.externalVersions_ = extRoot.length > 0 ? this.scanRootVersions(extRoot) : [];
    this.externalAvailable_ = extRoot.length > 0;
    this.showVersionPicker_ = true;
  }

  /**
   * 用户在 picker 里选定目标版本：覆盖有效安装根 + 版本，并把搜索筛选同步过去。
   */
  private onPickVersion(location: string, versionId: string): void {
    let ctx = this.uiCtx();
    let root = location === 'external'
      ? GameStorage.externalMcDir()
      : (ctx !== undefined ? GameStorage.sandboxMcDir(ctx) : this.mcDir);
    if (root.length === 0) {
      this.toast('该存储位置不可用');
      return;
    }
    this.targetLocation_ = location;
    this.targetMcDir_ = root;
    this.targetVersionId_ = versionId;
    this.targetValid_ = true;
    this.instanceTargetPicked_ = true;
    // 真实实例仍是三类资源共用的安装目标；另存偏好只退出当前类别。
    if (this.customSaveKindIndices_.indexOf(this.kindIdx_) >= 0) {
      this.customSaveKindIndices_ = this.customSaveKindIndices_.filter((kind: number): boolean => kind !== this.kindIdx_);
    }
    // 必须先废弃旧缓存再开始新准备，否则切回实例时可能同步取到已失效的扫描结果。
    this.invalidateLocalScanCache();
    // 完整版本目录与目标无关；改选实例只重新准备当前文件的安装计划，不重拉/缩窄目录。
    if (this.showDetailSheet_ && this.detailSelectedVersion_ !== null) {
      this.pickDetailVersion(this.detailSelectedVersion_);
    }
    // 把搜索筛选同步到所选版本：MC 版本号 + loader（整合包/重命名走快照/内容解析）
    this.gameVersionInput_ = resolveInstalledMcVersion(root, versionId);
    let dl = resolveInstalledLoader(root, versionId);
    if (dl.length > 0) this.loaderInput_ = dl;
    this.showVersionPicker_ = false;
    this.applyFiltersToController();
    this.triggerSearch(true);
    this.toast('安装目标：' + (location === 'external' ? '外部' : '沙箱') + ' · ' + versionId);
  }

  /** 明确切到单文件保存，不读取实例或依赖；原实例身份保留给其他资源分类。 */
  private onPickCustomResourceSave_(): void {
    if (!this.showVersionPicker_ || !supportsCustomResourceSave(this.currentBrowseKind_())) return;
    this.showVersionPicker_ = false;
    const alreadySaving = this.usesCustomResourceSave_();
    if (this.customSaveKindIndices_.indexOf(this.kindIdx_) < 0) {
      this.customSaveKindIndices_ = [...this.customSaveKindIndices_, this.kindIdx_];
    }
    // 已经因没有有效实例而默认另存时，记住显式选择即可，不重复发起搜索或准备。
    if (!alreadySaving) this.refreshResourceTargetProjection_();
  }

  /** 首页版本扫描可能晚于页面挂载；更新可另存类别的默认目标，尊重明确的实例或另存选择。 */
  private syncDefaultResourceTarget_(): boolean {
    if (!supportsCustomResourceSave(this.currentBrowseKind_()) || this.instanceTargetPicked_
      || this.customSaveKindIndices_.indexOf(this.kindIdx_) >= 0) return false;
    const valid = this.mcDir.length > 0 && this.currentMcVersion.length > 0
      && this.availableVersions.indexOf(this.currentMcVersion) >= 0;
    if (!valid && !this.targetValid_) return false;
    if (valid === this.targetValid_ && this.targetMcDir_ === this.mcDir
      && this.targetVersionId_ === this.currentMcVersion) return false;
    this.targetMcDir_ = this.mcDir;
    this.targetVersionId_ = this.currentMcVersion;
    this.targetValid_ = valid;
    const external = GameStorage.externalMcDir();
    this.targetLocation_ = external.length > 0 && this.mcDir === external ? 'external' : 'sandbox';
    this.gameVersionInput_ = valid ? resolveInstalledMcVersion(this.targetMcDir_, this.targetVersionId_) : '';
    const detectedLoader = valid ? resolveInstalledLoader(this.targetMcDir_, this.targetVersionId_) : '';
    this.loaderInput_ = detectedLoader.length > 0 ? detectedLoader : 'fabric';
    this.invalidateLocalScanCache();
    return true;
  }

  /** 默认目标变化仅重准备当前文件。旧选版请求由同一详情代次退休。 */
  private onResourceTargetPropsChanged_(): void {
    if (!this.inited_ || this.detailDisposed_ || !this.syncDefaultResourceTarget_()) return;
    this.refreshResourceTargetProjection_();
  }

  /** 目标投影变化时重建退让测量并重新准备所选文件；详情请求代次使旧计划失效。 */
  private refreshResourceTargetProjection_(): void {
    this.resetRetreatGeometry_();
    this.applyFiltersToController();
    if (this.initialSearchDone_) this.triggerSearch(true);
    if (this.detailInteractionActive_() && this.detailSelectedVersion_ !== null) {
      void this.pickDetailVersion(this.detailSelectedVersion_);
    }
  }

  // ============================================================
  //  二级筛选面板显隐
  // ============================================================

  /**
   * 按钮直接切换面板布局，结果列表保持自己的滚动位置。
   * 不滚走结果来冒充收起，也不重建搜索输入；筛选选择由页面状态保存，重新展开仍保留。
   */
  private setHeaderCollapsed(collapsed: boolean): void {
    this.freezeRetreatAnchor_();
    this.resetRetreat_();
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
      this.headerCollapsed_ = collapsed;
    });
  }

  // ============================================================
  //  Phase R-3 详情 Sheet 流转
  // ============================================================

  /**
   * 用户点击 ModCard：打开详情 sheet 并异步预取版本 / 依赖。
   * 不再直接触发安装。
   *
   * 浏览不要求已经选择或安装 MC；安装目标和依赖仅参与推荐及安装准备。
   * 每次打开废弃上一轮异步回写；真实提交仍由 confirmInstallFromSheet 和安装服务复验。
   */
  private openDetail(project: RemoteProject): void {
    // 原生 Sheet 退场不可被新打开打断；保持当前实例直到 onDisappear，避免显隐状态失配。
    if (this.detailDisposed_ || this.detailClosing_) return;
    if (!this.showDetailSheet_) {
      this.detailSession_ = ++this.detailSessionCounter_;
      this.detailPresentedSession_ = 0;
    }
    this.invalidateLocalScanCache();

    // 1. 重置 detail 状态 + 显式打开 sheet（先弹后等）
    this.detailFetchEpoch_ += 1;
    let myEpoch = this.detailFetchEpoch_;
    this.detailProject_ = project;
    this.detailModpackName_ = sanitizeVersionName(displayTitleOf(project) || project.title);
    this.detailModpackNameError_ = validateModpackVersionName(this.detailModpackName_);
    this.detailError_ = '';
    this.detailPreparingInstall_ = false;
    this.detailInstallReady_ = false;
    this.detailInstallError_ = '';
    this.detailDependenciesResolved_ = false;
    this.detailPreparedMcDir_ = '';
    this.detailPreparedVersionId_ = '';
    this.detailPreparedForResourceSave_ = false;
    this.detailOptionalIds_ = [];
    this.detailSelectedVersion_ = null;
    this.detailPrimaryFile_ = null;
    this.detailAllVersions_ = [];
    this.detailDeps_ = [];
    this.detailInstalledVersionIds_ = [];
    this.detailInstalledPrimary_ = null;
    this.detailResolvedDeps_ = [];
    this.detailLoading_ = true;
    this.detailScanInfo_ = '';
    this.showDetailSheet_ = true;

    // 异步预取
    this.prefetchDetail(project, myEpoch).catch((e: Error) => {
      // 仅当本次 fetch 仍是最新一轮才提示（用户已点别的卡时不打扰）
      if (this.detailFetchEpoch_ !== myEpoch) return;
      let msg = e.message !== undefined ? e.message : String(e);
      AppLogger.warn(TAG, 'prefetchDetail failed', e, LOG_DOMAIN_DOWNLOAD);
      this.detailLoading_ = false;
      this.detailError_ = msg;
      this.toast('版本信息加载失败：' + msg);
    });
  }

  /**
   * 获取完整客户端版本目录。当前实例只用于默认推荐，绝不成为目录请求的过滤条件。
   * 无匹配推荐时回退到最新客户端文件；空目录是可展示的空态，不冒充网络/安装失败。
   */
  private async prefetchDetail(project: RemoteProject, epoch: number): Promise<void> {
    const router = this.router_;
    if (router === null) throw new Error('模组来源未就绪');
    const repo = router.repoFor(project.source);
    if (repo === null) throw new Error('没有对应的模组来源');
    const fetched = await repo.getVersions(project.id, undefined, undefined);
    const versions = fetched.filter((version: RemoteVersion): boolean => version.isServerPack !== true);
    if (this.detailFetchEpoch_ !== epoch) return;
    this.detailAllVersions_ = versions.slice();
    this.detailLoading_ = false;
    const useTarget = project.kind === ResourceKind.MOD && !this.usesCustomResourceSave_(project.kind) && this.hasValidCurrentVersion();
    const loader = useTarget ? resolveInstalledLoader(this.targetMcDir_, this.targetVersionId_) : '';
    const game = useTarget ? resolveInstalledMcVersion(this.targetMcDir_, this.targetVersionId_) : '';
    const picked = pickBestVersion(versions, loader, game) ?? pickBestVersion(versions, '', '');
    if (picked === null) {
      this.detailInstallError_ = '该项目暂无可浏览的客户端版本';
      return;
    }
    await this.loadChosenDetail(picked, epoch);
  }

  /** 手选只切换浏览文件；先同步展示元数据，再独立准备当前目标的安装计划。 */
  private async pickDetailVersion(v: RemoteVersion): Promise<void> {
    if (!this.detailInteractionActive_()) return;
    const epoch = ++this.detailFetchEpoch_;
    // 可选前置属于具体发布文件；切换文件清空旧勾选，重算同一文件时保留用户选择。
    if (this.detailSelectedVersion_ === null || this.detailSelectedVersion_.id !== v.id
      || this.detailSelectedVersion_.source !== v.source) this.detailOptionalIds_ = [];
    await this.loadChosenDetail(v, epoch);
  }

  /**
   * 浏览态只投影所选文件的直接依赖声明，不替其他 MC/loader 伪造依赖解析结果。
   * 未指定项目时保留精确版本 ID/文件名；这些行仅供阅读，安装计划成功后再整体替换。
   */
  private buildDeclaredDepRows(v: RemoteVersion): ModDetailDepRow[] {
    const rows: ModDetailDepRow[] = [];
    const seen: Set<string> = new Set<string>();
    for (const dep of v.dependencies) {
      // 浏览保留冲突/内嵌等所有声明，只有安装下载投影才过滤无需下载的类型。
      // 业务身份不用数组序号；重复的相同声明合并，避免 ForEach 重复 key。
      const key = JSON.stringify([v.source, v.projectId, v.id, dep.projectId ?? '', dep.versionId ?? '',
        dep.fileName ?? '', dep.dependencyType]);
      if (seen.has(key)) continue;
      seen.add(key);
      rows.push({ displayName: dep.projectId || dep.versionId || dep.fileName || '未命名前置',
        author: '', iconUrl: '', downloads: -1, dependencyType: dep.dependencyType, estimatedSizeBytes: 0,
        selected: false, alreadyInstalled: false, key: key,
        versionNumber: dep.versionId ?? '' });
    }
    return rows;
  }

  /**
   * 只判断当前文件对当前目标的安装准入。返回原因不影响浏览；提交时再次调用，
   * 防止 UI 旧状态、空加载器/MC 标签的通配行为或目标变动绕过安装边界。
   */
  private detailInstallIssue(v: RemoteVersion): string {
    if (v.isServerPack === true) return '服务端整合包不能安装到客户端';
    const saveResourceFile = this.usesCustomResourceSave_(this.detailProject_.kind);
    if (this.detailProject_.kind !== ResourceKind.MODPACK && !saveResourceFile) {
      if (!this.hasValidCurrentVersion() || this.targetMcDir_.length === 0) return '请先选择已安装的 MC 实例；仍可浏览全部版本';
      if (this.detailProject_.kind === ResourceKind.MOD) {
        const loader = resolveInstalledLoader(this.targetMcDir_, this.targetVersionId_);
        const game = resolveInstalledMcVersion(this.targetMcDir_, this.targetVersionId_);
        if (loader.length === 0) return '当前实例未识别到模组加载器；仍可查看此版本';
        if (game.length === 0) return '当前实例的 MC 版本无法识别；仍可查看此版本';
        if (!isModVersionCompatible(v, loader, game)) return '此文件不匹配当前实例（' + loader + ' / MC ' + game + '），仍可查看详情';
      }
    }
    if (pickPrimaryFile(v.files) === null) return '此版本没有可下载主文件，仍可查看版本信息';
    return '';
  }

  /**
   * 把 ResolvedDependency[] 投影成 ModDetailDepRow[]：
   *   - displayName / author / downloads 从 RemoteProject 拿
   *   - estimatedSizeBytes 从 primary file 拿
   *   - selected：REQUIRED 默认 true，OPTIONAL 默认 false
   *   - alreadyInstalled：直接透传 ResolvedDependency.alreadyInstalled
   */
  private buildDepRows(deps: ResolvedDependency[], _installed: LocalMod[]): ModDetailDepRow[] {
    const rows: ModDetailDepRow[] = [];
    for (const d of deps) {
      if (d.dependencyType === DependencyType.EMBEDDED || d.dependencyType === DependencyType.INCOMPATIBLE) continue;
      const file = d.version === null ? null : pickPrimaryFile(d.version.files);
      rows.push({ displayName: d.project?.title ?? d.projectId, author: d.project?.author ?? '',
        iconUrl: d.project?.iconUrl ?? '', downloads: d.project?.downloads ?? -1,
        dependencyType: d.dependencyType, estimatedSizeBytes: file?.size ?? 0,
        selected: d.selected === true && !d.alreadyInstalled, alreadyInstalled: d.alreadyInstalled,
        key: d.projectId, compatWarning: d.errorMessage ?? undefined, versionNumber: d.version?.versionNumber ?? '' });
    }
    return rows;
  }

  private toggleDetailDep(key: string): void {
    if (!this.detailInteractionActive_()) return;
    if (this.detailPreparingInstall_ || !this.detailDependenciesResolved_) return;
    const row = this.detailDeps_.find((r: ModDetailDepRow): boolean => r.key === key);
    if (row === undefined || row.dependencyType !== DependencyType.OPTIONAL) return;
    this.detailOptionalIds_ = this.detailOptionalIds_.indexOf(key) >= 0
      ? this.detailOptionalIds_.filter((id: string): boolean => id !== key) : [...this.detailOptionalIds_, key];
    if (this.detailSelectedVersion_ !== null) this.pickDetailVersion(this.detailSelectedVersion_);
  }

  private selectAllDetailDeps(): void {
    if (!this.detailInteractionActive_()) return;
    if (this.detailPreparingInstall_ || !this.detailDependenciesResolved_) return;
    this.detailOptionalIds_ = this.detailDeps_.filter((r: ModDetailDepRow): boolean => r.dependencyType === DependencyType.OPTIONAL)
      .map((r: ModDetailDepRow): string => r.key);
    if (this.detailSelectedVersion_ !== null) this.pickDetailVersion(this.detailSelectedVersion_);
  }

  /** 详情操作共用准入；退出期间排队的选版/依赖/安装回调不得重启已退休的工作。 */
  private detailInteractionActive_(): boolean {
    return !this.detailDisposed_ && !this.detailClosing_ && this.detailSession_ !== 0 && this.showDetailSheet_;
  }

  /** 只退休请求和扫描缓存，允许在 onWillDisappear/aboutToDisappear 中安全执行。 */
  private invalidateDetailWork_(): void {
    this.detailFetchEpoch_ += 1;
    this.invalidateLocalScanCache();
  }

  /** 请求关闭：立即挡住后续交互与异步回写，退出动画仍使用原展示快照。 */
  private closeDetail(): void {
    if (this.detailDisposed_ || this.detailClosing_ || !this.showDetailSheet_) return;
    this.detailClosing_ = true;
    this.invalidateDetailWork_();
    this.showDetailSheet_ = false;
    // 尚未进入 Native 呈现的同帧开关可能没有 onDisappear。此时只退休普通身份，
    // 仍保留安全快照，不抢先清空可能已排队的正文；下一次打开会完整覆盖旧数据。
    if (this.detailPresentedSession_ !== this.detailSession_) {
      this.detailSession_ = 0;
      this.detailClosing_ = false;
    }
  }

  /** Native 真正开始呈现时才建立退场等待义务；回调本身不写入视图状态。 */
  private detailWillAppearCallback_(): () => void {
    const session: number = this.detailSession_;
    return (): void => {
      if (!this.detailDisposed_ && session !== 0 && session === this.detailSession_) {
        this.detailPresentedSession_ = session;
      }
    };
  }

  /** options 注册时捕获实例，不能在回调执行时才读取可能已经更换的当前身份。 */
  private detailWillDisappearCallback_(): () => void {
    const session: number = this.detailSession_;
    return (): void => { this.onDetailWillDisappear_(session); };
  }

  /** 退出完成回调也绑定同一实例，旧 Sheet 的迟到通知不能清空新详情。 */
  private detailDidDisappearCallback_(): () => void {
    const session: number = this.detailSession_;
    return (): void => { this.onDetailDidDisappear_(session); };
  }

  /** 遮罩/返回键/拖动等系统关闭也在动画开始前失效工作；此回调不修改 @State。 */
  private onDetailWillDisappear_(session: number): void {
    if (this.detailDisposed_ || session === 0 || session !== this.detailSession_) return;
    if (!this.detailClosing_) {
      this.detailClosing_ = true;
      this.invalidateDetailWork_();
    }
  }

  /** 真实退场结束后释放当前实例的数据；重复、旧会话与页面销毁后的回调均无副作用。 */
  private onDetailDidDisappear_(session: number): void {
    if (this.detailDisposed_ || session === 0 || session !== this.detailSession_) return;
    this.onDetailWillDisappear_(session);
    this.detailSession_ = 0;
    this.detailPresentedSession_ = 0;
    this.showDetailSheet_ = false;
    this.resetDetailState_();
    this.detailClosing_ = false;
  }

  /** 只由当前 Sheet 的退场完成调用；完整空态也能承受框架剩余的渲染回调。 */
  private resetDetailState_(): void {
    this.detailLoading_ = false;
    this.detailPreparingInstall_ = false;
    this.detailInstallReady_ = false;
    this.detailInstallError_ = '';
    this.detailError_ = '';
    this.detailDependenciesResolved_ = false;
    this.detailPreparedMcDir_ = '';
    this.detailPreparedVersionId_ = '';
    this.detailPreparedForResourceSave_ = false;
    this.detailProject_ = makeEmptyRemoteProject();
    this.detailSelectedVersion_ = null;
    this.detailPrimaryFile_ = null;
    this.detailAllVersions_ = [];
    this.detailDeps_ = [];
    this.detailResolvedDeps_ = [];
    this.detailInstalledVersionIds_ = [];
    this.detailInstalledPrimary_ = null;
    this.detailScanInfo_ = '';
    this.detailOptionalIds_ = [];
    this.detailModpackName_ = '';
    this.detailModpackNameError_ = '';
  }



  /** sheet 中点"网页"：拉起浏览器（默认打开项目自身页面；多源/百科由菜单分项走 openExternalUrl_） */
  private openWebsiteFromSheet(): void {
    // 商店不暴露资源网页，旧 Sheet 回调也不能恢复此动作；API 资源解析/下载不受影响。
    if (DistributionPolicy.isStore()) return;
    if (!this.detailInteractionActive_()) return;
    let url = this.detailProject_.websiteUrl;
    if (!url || url.length === 0) {
      this.toast('该项目无可用网址');
      return;
    }
    this.openExternalUrl_(url);
  }

  /** 经系统 Want 拉起浏览器打开外部 URL。 */
  private openExternalUrl_(url: string): void {
    if (DistributionPolicy.isStore()) return;
    if (!this.detailInteractionActive_()) return;
    if (!url || url.length === 0) {
      this.toast('网址为空');
      return;
    }
    let ctx = this.uiCtx();
    if (ctx === undefined) {
      this.toast('无法打开浏览器');
      return;
    }
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    };
    try {
      ctx.startAbility(want);
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'openExternalUrl: %{public}s', url);
    } catch (e) {
      AppLogger.error(TAG, 'open url failed', e as Error, LOG_DOMAIN_DOWNLOAD);
      this.toast('无法打开浏览器：' + url);
    }
  }

  /**
   * 解析"另一源"的真实工程数据（真实 id + 真实网址 + 真实分类）。
   *   - merge 已带真实数字 altId → 直接 getProject(altId)（顺带拿真实网址）。
   *   - 仅 mcmod 库给了 slug → CurseForge 用 getProjectBySlug 解析；Modrinth getProject 接受 slug。
   * 拿到后补上回指原源的 alt* 与译名字段，便于在双源间来回切。失败返回 null。
   */
  private async resolveCounterpart(p: RemoteProject, target: ModSource): Promise<RemoteProject | null> {
    let router = this.router_;
    if (router === null) return null;
    let repo = router.repoFor(target);
    if (repo === null) return null;

    let resolved: RemoteProject | null = null;
    if (p.altSource === target && p.altId !== undefined && p.altId.length > 0) {
      // 有真实 id（来自 merge）：直接取详情（拿真实网址）
      resolved = await repo.getProject(p.altId);
    } else {
      let slug = (p.altSlug !== undefined && p.altSlug.length > 0)
        ? p.altSlug
        : (target === ModSource.CURSEFORGE
            ? (p.cfSlug !== undefined ? p.cfSlug : '')
            : (p.mrSlug !== undefined ? p.mrSlug : ''));
      if (slug.length === 0) return null;
      if (target === ModSource.CURSEFORGE) {
        let cfRepo = repo as CurseForgeRepository;
        resolved = await cfRepo.getProjectBySlug(slug);
      } else {
        // Modrinth getProject 接受 slug
        resolved = await repo.getProject(slug);
      }
    }
    if (resolved === null) return null;
    // 回指原源 + 保留译名（便于来回切 + mcmod 链接）
    resolved.altSource = p.source;
    resolved.altId = p.id;
    resolved.altSlug = p.slug;
    if (p.chineseName !== undefined) resolved.chineseName = p.chineseName;
    if (p.wikiId !== undefined) resolved.wikiId = p.wikiId;
    if (p.cfSlug !== undefined) resolved.cfSlug = p.cfSlug;
    if (p.mrSlug !== undefined) resolved.mrSlug = p.mrSlug;
    return resolved;
  }

  /**
   * 切换详情页的下载源（双源资源）：解析另一源真实工程 → openDetail 重拉版本/依赖。
   * 用户随后点"一键安装"即从该源下载。
   */
  private async switchDetailSource(source: ModSource): Promise<void> {
    if (!this.detailInteractionActive_()) return;
    let p = this.detailProject_;
    const epoch = this.detailFetchEpoch_;
    if (p.source === source) return;
    if (p.altSource !== source) {
      this.toast('该源暂无此资源');
      return;
    }
    this.toast('正在解析' + (source === ModSource.CURSEFORGE ? ' CurseForge ' : ' Modrinth ') + '工程…');
    let resolved: RemoteProject | null = null;
    try {
      resolved = await this.resolveCounterpart(p, source);
    } catch (e) {
      AppLogger.warn(TAG, 'resolveCounterpart failed', e as Object, LOG_DOMAIN_DOWNLOAD);
    }
    // 切源也是详情请求：关闭、换项目、换文件或页面销毁后，旧响应不能重新打开旧项目。
    if (epoch !== this.detailFetchEpoch_ || !this.showDetailSheet_ || this.router_ === null) return;
    if (resolved === null) {
      this.toast((source === ModSource.CURSEFORGE ? 'CurseForge' : 'Modrinth') + ' 上未找到该资源');
      return;
    }
    this.openDetail(resolved);
  }

  /** 网页菜单"打开另一源页面"：解析另一源真实工程 → 用其真实网址拉起浏览器（避免按分类猜 URL 404）。 */
  private async openCrossSourceWeb(source: ModSource): Promise<void> {
    // 在任何“解析另一网站”网络请求之前拒绝商店的一般网页操作。
    if (DistributionPolicy.isStore()) return;
    if (!this.detailInteractionActive_()) return;
    const epoch: number = this.detailFetchEpoch_;
    let p = this.detailProject_;
    this.toast('正在解析' + (source === ModSource.CURSEFORGE ? ' CurseForge ' : ' Modrinth ') + '页面…');
    let resolved: RemoteProject | null = null;
    try {
      resolved = await this.resolveCounterpart(p, source);
    } catch (e) {
      AppLogger.warn(TAG, 'openCrossSourceWeb resolve failed', e as Object, LOG_DOMAIN_DOWNLOAD);
    }
    // 网页解析与详情请求共享代次，旧菜单的迟到结果不能在新详情打开后拉起旧网页。
    if (epoch !== this.detailFetchEpoch_ || !this.detailInteractionActive_()) return;
    if (resolved === null || resolved.websiteUrl.length === 0) {
      this.toast((source === ModSource.CURSEFORGE ? 'CurseForge' : 'Modrinth') + ' 上未找到该资源');
      return;
    }
    this.openExternalUrl_(resolved.websiteUrl);
  }

  private confirmInstallFromSheet(): void {
    if (!this.detailInteractionActive_()) return;
    if (this.detailLoading_ || this.detailPreparingInstall_) { this.toast('正在准备安装，请等待完成'); return; }
    if (this.detailError_.length > 0) { this.toast(this.detailError_); return; }
    const project = this.detailProject_;
    const picked = this.detailSelectedVersion_;
    const primary = this.detailPrimaryFile_;
    if (picked?.isServerPack === true) { this.toast('服务端整合包不能安装到客户端'); return; }
    if (picked === null || primary === null || primary.url.length === 0) { this.toast('该版本不可下载'); return; }
    // 先按真实当前目标复验，再检查准备结果；可浏览不代表存在可提交的安装计划。
    const issue = this.detailInstallIssue(picked);
    if (issue.length > 0) { this.toast(issue); return; }
    if (!this.detailInstallReady_ || this.detailInstallError_.length > 0) {
      this.toast(this.detailInstallError_ || '安装计划尚未准备完成'); return;
    }
    if (this.usesCustomResourceSave_(project.kind)) {
      if (!this.detailPreparedForResourceSave_) {
        this.toast('下载目标已变化，请重新选择文件'); return;
      }
      void this.saveResourceFileFromSheet_(project, picked, primary);
      return;
    }
    if (project.kind !== ResourceKind.MODPACK && (this.detailPreparedMcDir_ !== this.targetMcDir_
      || this.detailPreparedVersionId_ !== this.targetVersionId_)) {
      this.toast('安装目标已变化，请重新选择版本'); return;
    }
    if (this.downloadingProjectIds_.has(project.id)) { this.toast('该资源正在安装'); return; }
    if (project.kind === ResourceKind.MODPACK) {
      this.detailModpackNameError_ = validateModpackVersionName(this.detailModpackName_);
      if (this.detailModpackNameError_.length > 0) return;
      // sheet 的 onDisappear 会清空详情状态，必须在关闭前捕获名称，与来源/文件一起入队。
      const name = this.detailModpackName_.trim();
      this.closeDetail(); this.installModpackFromSheet(project, picked, primary, name); return;
    }
    if (!this.hasValidCurrentVersion()) { this.toast('安装目标已失效'); return; }
    if (project.kind === ResourceKind.MOD && !isModVersionCompatible(picked,
      resolveInstalledLoader(this.targetMcDir_, this.targetVersionId_), resolveInstalledMcVersion(this.targetMcDir_, this.targetVersionId_))) {
      this.toast('所选文件与目标游戏版本或加载器不匹配'); return;
    }
    const deps = this.detailResolvedDeps_.slice();
    this.closeDetail();
    this.executeInstall(project, picked, primary, deps).catch((e: Error): void => { this.toast(e.message); });
  }

  /**
   * 整合包安装入口：下载 .mrpack/.zip → 建带 loader 的新隔离版本 → 批量下文件 → 铺 overrides。
   * 走 ModpackInstallTask（统一下载任务），在 DownloadTasksSheet 显示橙色卡片。
   */
  private installModpackFromSheet(project: RemoteProject, picked: RemoteVersion, primary: RemoteFile,
    versionName?: string): void {
    let ctx = this.uiCtx();
    if (ctx === undefined) { this.toast('环境未就绪，无法安装整合包'); return; }
    let filesDir = ctx.filesDir;
    this.onStatusMessage('开始安装整合包 ' + project.title + '…');

    let sourceLabel = project.source === ModSource.CURSEFORGE ? 'CurseForge' : 'Modrinth';
    let task = new ModpackInstallTask({
      title: project.title,
      versionName: versionName ?? sanitizeVersionName(displayTitleOf(project) || project.title),
      subtitle: '整合包 · ' + sourceLabel,
      iconUrl: project.iconUrl,
      archiveUrl: primary.url,
      archiveMirrors: primary.mirrors,
      archiveFilename: primary.filename,
      archiveSha1: primary.sha1,
      archiveSha512: primary.sha512,
      archiveSize: primary.size,
      sourceVersionId: picked.id,
      requireConfirmation: true,
      // 新整合包使用设置传入的当前全局根，不消费其他资源的临时目标版本选择。
      mcDir: this.mcDir,
      filesDir: filesDir,
      existingVersions: this.availableVersions,
      projectId: project.id,
      officialFilesOnly: this.onlyOfficialModpackFiles_(),
      resolveCfFile: createModpackFileResolver(this.cacheRemoteMeta, this.onlyOfficialModpackFiles_(),
        this.resolveCurseForgeFileMode() === CurseForgeFileSourceMode.OFFICIAL_FIRST),
    });
    this.runModpackInstall_(task, project.id);
  }

  /** 统一的整合包任务入队 + 完成处理（toast + 缺失清单对话框）。在线/本地导入共用。 */
  private runModpackInstall_(task: ModpackInstallTask, lockId?: string): void {
    if (lockId !== undefined) this.downloadingProjectIds_.add(lockId);
    getDownloadTaskRegistry().enqueue(task).then(() => {
      if (lockId !== undefined) this.downloadingProjectIds_.delete(lockId);
      this.refreshModpackRecovery_();
      if (task.view.state !== UnifiedTaskState.DONE) {
        this.onStatusMessage(task.view.currentLabel);
        return;
      }
      let res = task.getResult();
      let name = res !== null ? res.versionName : task.view.title;
      if (res !== null && res.missing.length > 0) {
        this.onStatusMessage(name + ' 安装完成（' + res.missing.length + ' 项缺失）');
        this.showModpackMissingDialog_(name, res.missing);
      } else {
        this.onStatusMessage(name + ' 整合包安装完成');
        this.toast(name + ' 整合包安装完成');
      }
    }).catch((e: Error) => {
      if (lockId !== undefined) this.downloadingProjectIds_.delete(lockId);
      // 等待取消收敛时，原入队 Promise 可以拒绝；主动取消由任务终态和放弃面板反馈。
      if (task.view.state === UnifiedTaskState.ABORTED) return;
      let msg = e.message !== undefined ? e.message : String(e);
      AppLogger.error(TAG, 'modpack install failed', e, LOG_DOMAIN_DOWNLOAD);
      this.toast('整合包安装失败：' + msg);
    });
    this.onOpenDownloadTask(task.view.id);
  }

  /** 绑定本次另存的详情会话和选中文件；系统窗口暂时隐藏宿主页时仍允许正常返回。 */
  private async saveResourceFileFromSheet_(project: RemoteProject, version: RemoteVersion, file: RemoteFile): Promise<void> {
    if (this.detailSavePickerPending_) return;
    const context = this.uiCtx();
    if (context === undefined) { this.toast('环境未就绪，无法选择保存位置'); return; }
    const session = this.detailSession_;
    const epoch = this.detailFetchEpoch_;
    const isCurrent = (): boolean => this.detailInteractionActive_() && this.usesCustomResourceSave_(project.kind)
      && this.detailSession_ === session && this.detailFetchEpoch_ === epoch;
    this.detailSavePickerPending_ = true;
    try {
      const id = await pickAndStartModFileSave(context, project, version, file, isCurrent);
      // 取消和过期均保留详情；已入队的任务交给 Registry，不依赖页面继续存活。
      if (id.length === 0 || !isCurrent()) return;
      this.closeDetail();
      this.onOpenDownloadTask(id);
    } catch (error) {
      if (isCurrent()) this.toast((error as Error).message || '无法开始下载，请重试');
    } finally {
      if (!this.detailDisposed_) this.detailSavePickerPending_ = false;
    }
  }

  /** 缺失清单对话框（决策4：明确告知整合包不完整 + 列出缺失项 + 可复制手动补齐清单）。 */
  private showModpackMissingDialog_(versionName: string, missing: ModpackMissingItem[]): void {
    let lines: string[] = [];
    let limit = Math.min(missing.length, 12);
    for (let i = 0; i < limit; i++) {
      let m = missing[i];
      let line = '• ' + m.name + ' — ' + m.reason;
      if (m.url !== undefined && m.url.length > 0) line += '\n   ↳ ' + m.url;
      lines.push(line);
    }
    if (missing.length > limit) lines.push('… 其余 ' + (missing.length - limit) + ' 项（点「复制清单」查看全部）');
    let hasUrl = false;
    for (let m of missing) { if (m.url !== undefined && m.url.length > 0) { hasUrl = true; break; } }
    let tail = hasUrl ? '\n\n含下载地址的项可手动下载后放入对应目录。' : '';
    let msg = '「' + versionName + '」已安装，但以下 ' + missing.length
      + ' 项未能装上（不影响其余内容，可手动补齐）：\n\n' + lines.join('\n') + tail;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '整合包部分内容缺失',
        message: msg,
        buttons: [
          { text: '复制清单', color: this.theme.actionText as string },
          { text: '知道了', color: this.theme.textSecondary as string },
        ],
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 0) this.copyMissingList_(versionName, missing);
      }).catch(() => { /* 用户关闭，忽略 */ });
    } catch (e) {
      this.toast(versionName + ' 安装完成（' + missing.length + ' 项缺失）');
    }
  }

  /** 把完整缺失清单（名称 — 原因 — 下载地址）复制到剪贴板，方便用户手动补齐。 */
  private copyMissingList_(versionName: string, missing: ModpackMissingItem[]): void {
    let parts: string[] = ['整合包「' + versionName + '」缺失清单（共 ' + missing.length + ' 项）:'];
    for (let m of missing) {
      let line = '- ' + m.name + ' — ' + m.reason;
      if (m.url !== undefined && m.url.length > 0) line += '\n  ' + m.url;
      parts.push(line);
    }
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, parts.join('\n'));
      pasteboard.getSystemPasteboard().setData(data);
      this.toast('缺失清单已复制到剪贴板');
    } catch (e) {
      this.toast('复制失败');
    }
  }

  /** 从本地导入 .mrpack / CurseForge .zip 整合包并安装。 */
  private async importLocalModpack_(): Promise<void> {
    let ctx = this.uiCtx();
    if (ctx === undefined) { this.toast('环境未就绪，无法导入整合包'); return; }
    let filesDir = ctx.filesDir;
    // 文件选择是异步操作；在入口快照设置中的全局根，避免等待期间被页面临时目标覆盖。
    const installRoot = this.mcDir;
    // 每次导入使用独占目录，排队期间再次选择同名 ZIP 不会替换前一任务输入。
    let importDir = filesDir + '/modpack-import/' + newVersionInstallOwner();
    let res = await GameArchiveIO.importResourceFile(ctx, importDir, ['.mrpack', '.zip']);
    if (res.cancelled) return;
    if (!res.ok) { this.toast(res.message); return; }
    let archivePath = importDir + '/' + res.name;
    let title = res.name;
    let dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    // 本地没有在线项目详情可预填，使用文件名生成安全默认名；选完文件后仍先展示
    // 下载详情，让用户像普通版本一样改名并点击开始。此时尚未入队，也未写实例目录。
    this.localModpackArchive_ = archivePath;
    this.localModpackRoot_ = installRoot;
    this.localModpackFilesDir_ = filesDir;
    this.localModpackName_ = sanitizeVersionName(title);
    this.localModpackNameError_ = validateModpackVersionName(this.localModpackName_);
    this.showLocalModpackDetail_ = true;
  }



  private async executeInstall(project: RemoteProject, picked: RemoteVersion, primary: RemoteFile,
    _dependencies: ResolvedDependency[]): Promise<void> {
    const router = this.router_;
    if (router === null) throw new Error('模组来源不可用');
    const mcDir = this.targetMcDir_;
    const versionId = this.targetVersionId_;
    const isolation = this.versionIsolation;
    const optionalIds = this.detailOptionalIds_.slice();
    const old = this.detailInstalledPrimary_;
    this.downloadingProjectIds_.add(project.id);
    try {
      // Registry在producer前建立固定attempt；页面不另造startedAt或打开另一条scope。
      if (project.kind === ResourceKind.MOD) {
        const request: ModInstallRequest = { mcDir: mcDir, versionId: versionId, versionIsolation: isolation, root: picked,
          title: project.title, router: router, optionalIds: optionalIds, oldPath: old?.filePath, wasEnabled: old?.enabled };
        const task = new ModInstallTask(request);
        await getDownloadTaskRegistry().enqueue(task);
      } else {
        const task = new ResourceInstallTask({ projectTitle: project.title, iconUrl: project.iconUrl,
          request: { kind: project.kind, mcDir: mcDir, versionId: versionId, versionIsolation: isolation, primary: primary, dependencies: [] } });
        await getDownloadTaskRegistry().enqueue(task);
      }
      this.onStatusMessage(project.title + ' 安装完成');
      this.toast(project.title + ' 安装完成');
    } catch (e) {
      throw e as Error;
    } finally { this.downloadingProjectIds_.delete(project.id); this.invalidateLocalScanCache(); }
  }

  /** 同时清除现有条目和退休在途扫描；仅 clear Map 无法阻止旧请求迟到回填。 */
  private invalidateLocalScanCache(): void {
    this.localScanCacheEpoch_ += 1;
    this.localScanCache_.clear();
  }

  /**
   * 取已装 LocalMod[]（按 mcDir + versionId 缓存一次扫描结果，避免每次详情展开都重扫）。
   * scanner_ 为空（aboutToDisappear 之后）或 currentMcVersion 无效时返回 []。
   */
  private async getOrScanInstalled(): Promise<LocalMod[]> {
    if (this.scanner_ === null) return [];
    if (!this.hasValidCurrentVersion()) return [];
    let cacheKey = this.targetMcDir_ + '::' + this.targetVersionId_ + '::' + (this.versionIsolation ? '1' : '0');
    let cached = this.localScanCache_.get(cacheKey);
    if (cached !== undefined) return cached;
    const epoch = this.localScanCacheEpoch_;
    try {
      let result = await this.scanner_!.scan({
        mcDir: this.targetMcDir_,
        versionId: this.targetVersionId_,
        versionIsolation: this.versionIsolation,
        kind: ResourceKind.MOD,
        lookupLimit: 64,
      });
      // 调用方仍接收本次快照并按详情代次处理；已失效请求不再污染后续选版缓存。
      if (epoch === this.localScanCacheEpoch_) this.localScanCache_.set(cacheKey, result.mods);
      return result.mods;
    } catch (e) {
      AppLogger.warn(TAG, 'localScan failed', e, LOG_DOMAIN_DOWNLOAD);
      return [];
    }
  }


  /**
   * v2: 资源类型卡片（取代 KindChip）。emoji + 文字双行，更明显的选中态。
   *
   * 注：Phase R-1 之后，DownloadTab 顶级横向 Tabs 已接管资源类型切换。
   * 本 KindCard builder 保留但不在 build() 中渲染，作为未来"快速切换"按钮的备用 UI。
   */
  @Builder
  KindCard(emoji: string, label: string, idx: number) {
    Column() {
      Text(emoji)
        .fontSize(22)
      Text(label)
        .fontSize(12)
        .fontWeight(this.kindIdx_ === idx ? 600 : 400)
        .fontColor(this.kindIdx_ === idx ? this.theme.textOnPrimary : this.theme.textSecondary)
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .height(64)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(this.theme.cardRadius)
    .backgroundColor(this.kindIdx_ === idx ? this.theme.primary : this.theme.bgInput)
    .onClick(() => {
      if (this.kindIdx_ === idx) return;
      this.kindIdx_ = idx;
      this.resetRetreatGeometry_();
      this.applyFiltersToController();
      this.triggerSearch(true);
    })
  }

  /** 整合包稳定操作行：统计、轻量导入与有任务时才出现的恢复入口，不跟随筛选收起。 */
  @Builder
  ModpackImportRow() {
    Row({ space: 8 }) {
      Text(this.view_.totalHits > 0 ? '共 ' + this.view_.totalHits + ' 个整合包' : '整合包')
        .fontSize(12).fontColor(this.theme.textSecondary).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button() {
        Row({ space: 4 }) {
          AppIcon({ name: AppIconName.Import, iconSize: 14, color: this.theme.actionText })
          Text('本地导入').fontSize(12).fontColor(this.theme.actionText)
        }.alignItems(VerticalAlign.Center)
      }
      .height(28).type(ButtonType.Normal).borderRadius(14)
      .responseRegion({ x: 0, y: -8, width: '100%', height: 44 })
      .padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent)
      .accessibilityText('从本地导入 .mrpack 或 .zip 整合包')
      .onClick(() => {
        this.importLocalModpack_().catch((e: Error) => {
          AppLogger.warn(TAG, 'importLocalModpack failed', e, LOG_DOMAIN_DOWNLOAD);
          this.toast('导入失败：' + (e.message !== undefined ? e.message : String(e)));
        });
      })
      this.ModpackRecoveryRow()
    }
    .width('100%').alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  LoaderChip(loader: string) {
    // 与 DownloadTab 的正式版/快照胶囊保持一致：12vp 字号、横12/纵6留白、14vp圆角。
    // 扩展触摸热区而不设置 minHeight，避免将紧凑筛选视觉膨胀为44vp的大按钮。
    Text(loader === 'neoforge' ? 'NeoForge' : (loader.length > 0 ? this.capitalize(loader) : '全部'))
      .fontSize(12)
      .fontColor(this.activeLoaderFilter_() === loader ? this.theme.textOnPrimary : this.theme.textSecondary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.activeLoaderFilter_() === loader ? this.theme.primary : this.theme.bgCard)
      .responseRegion({ x: 0, y: -9, width: '100%', height: 44 })
      .onClick(() => {
        if (this.activeLoaderFilter_() === loader) return;
        this.setActiveLoaderFilter_(loader);
        this.applyFiltersToController();
        this.triggerSearch(true);
      })
  }

  @Builder
  LoadingBlock(text: string) {
    Column() {
      LoadingProgress().width(40).height(40).color(this.theme.actionText)
      Text(text)
        .fontSize(13).fontColor(this.theme.textHint).margin({ top: 12 })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorBlock(msg: string) {
    Column({ space: 8 }) {
      AppIcon({ name: AppIconName.Error, iconSize: 28, color: this.theme.errorText })
      Text('搜索失败')
        .fontSize(15).fontWeight(500).fontColor(this.theme.errorText)
      Text(msg)
        .fontSize(12)
        .fontColor(this.theme.textHint)
        .textAlign(TextAlign.Center)
        .padding({ left: 16, right: 16, top: 6 })
      Button('重试')
        .type(ButtonType.Capsule).height(32).fontSize(13)
        .backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary)
        .margin({ top: 16 })
        .onClick(() => { this.triggerSearch(true); })
      Button('网络检测')
        .type(ButtonType.Capsule).height(32).fontSize(13)
        .backgroundColor(Color.Transparent).fontColor(this.theme.textSecondary)
        .borderWidth(1).borderColor(this.theme.divider)
        .margin({ top: 8 })
        .onClick(() => { AppStorage.setOrCreate('amcl_open_netdiag_nonce', Date.now()); })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(24)
  }

  @Builder
  EmptyBlock() {
    Column({ space: 8 }) {
      AppIcon({ name: AppIconName.Search, iconSize: 28, color: this.theme.textHint })
      Text('没有找到匹配的内容')
        .fontSize(14).fontColor(this.theme.textSecondary)
      Text('试试换一个关键词 / 修改筛选条件')
        .fontSize(12).fontColor(this.theme.textHint).margin({ top: 6 })
      Button('清除搜索与加载器筛选').height(44)
        .onClick(() => {
          this.queryInput_ = ''; this.setActiveLoaderFilter_('');
          this.applyFiltersToController(); this.triggerSearch(true);
        })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  // ===================== 行为 =====================

  private debouncedSearch(): void {
    if (this.debounceTimer_ !== 0) {
      clearTimeout(this.debounceTimer_);
    }
    this.debounceTimer_ = setTimeout(() => {
      this.debounceTimer_ = 0;
      this.applyFiltersToController();
      this.triggerSearch(true);
    }, SEARCH_DEBOUNCE_MS);
  }

  private applyFiltersToController(): void {
    let ctrl = this.ctrl_;
    if (ctrl === null) return;
    const kind = this.currentBrowseKind_();
    ctrl.setKind(kind);
    ctrl.setQuery(this.queryInput_);
    // 另存没有目标实例，整合包自带 MC 版本，两者均不套用当前实例的 MC 版本筛选。
    ctrl.setGameVersion(kind === ResourceKind.MODPACK || this.usesCustomResourceSave_() ? '' : this.gameVersionInput_);
    if (kind === ResourceKind.MOD || kind === ResourceKind.MODPACK) {
      ctrl.setLoader(this.activeLoaderFilter_());
    } else {
      ctrl.setLoader('');
    }
    this.sortInput_ = this.sortExplicit_ ? this.sortInput_
      : (this.queryInput_.trim().length > 0 ? SortBy.RELEVANCE : SortBy.DOWNLOADS);
    ctrl.setSortBy(this.sortInput_);
  }

  private triggerSearch(first: boolean): void {
    if (first) { this.resetRetreat_(); this.retreatScrollable_ = false; this.retreatAnchorInset_ = -1; }
    let ctrl = this.ctrl_;
    if (ctrl === null) return;
    let p = first ? ctrl.loadFirstPage() : ctrl.loadNextPage();
    this.syncViewFromController();
    p.then(() => {
      this.syncViewFromController();
    }).catch((e: Error) => {
      AppLogger.warn(TAG, 'search error', e, LOG_DOMAIN_DOWNLOAD);
      this.syncViewFromController();
    });
  }

  private loadNextPage(): void {
    this.triggerSearch(false);
  }

  private syncViewFromController(): void {
    let ctrl = this.ctrl_;
    if (ctrl === null) return;
    this.view_ = ctrl.getState();
    if (this.view_.hits.length === 0) this.resetRetreat_();
  }

  /**
   * P0 修复 #3：计算下载落地的目录片段（用于 UI 提示，不做 IO）。
   *   versionIsolation=true  → `versions/<id>/<sub>/`
   *   versionIsolation=false → `.minecraft/<sub>/`
   * sub 来自当前选中的 kind（mods / resourcepacks / shaderpacks）。
   */
  private computeInstallDirShortcut(): string {
    let sub: string;
    if (this.kindIdx_ === 1) sub = 'resourcepacks';
    else if (this.kindIdx_ === 2) sub = 'shaderpacks';
    else sub = 'mods';
    if ((this.versionIsolation || isIsolatedModpackInstance(this.targetMcDir_, this.targetVersionId_)) && this.targetVersionId_.length > 0) {
      return 'versions/' + this.targetVersionId_ + '/' + sub + '/';
    }
    return '.minecraft/' + sub + '/';
  }

  /**
   * P0 修复 #4：校验"安装目标版本"是否真实存在，避免 installBatch 凭空创建空版本目录。
   *
   * 初始目标来自 props（按 availableVersions 校验）；用户用 VersionPickerSheet 选过之后，
   * 目标一定是从真实扫描列表里挑出来的，targetValid_ 恒为真。
   */
  private hasValidCurrentVersion(): boolean {
    return this.targetValid_ && this.targetVersionId_.length > 0;
  }

  /** 模组、资源包、光影、整合包胶囊和搜索、详情共用这一份类别映射。 */
  private currentBrowseKind_(): ResourceKind {
    if (this.kindIdx_ === 1) return ResourceKind.RESOURCE_PACK;
    if (this.kindIdx_ === 2) return ResourceKind.SHADER;
    if (this.kindIdx_ === 3) return ResourceKind.MODPACK;
    return ResourceKind.MOD;
  }

  /** 没有有效安装目标时默认另存；详情必须属于当前类别，旧详情不能借切换后的目标获得资格。 */
  private usesCustomResourceSave_(kind?: ResourceKind): boolean {
    const current = this.currentBrowseKind_();
    return (kind === undefined || kind === current) && supportsCustomResourceSave(current)
      && (this.customSaveKindIndices_.indexOf(this.kindIdx_) >= 0 || !this.hasValidCurrentVersion());
  }

  /** 另存模式保留用户明确选的加载器；实例模式继续使用原筛选。 */
  private activeLoaderFilter_(): string {
    return this.usesCustomResourceSave_(ResourceKind.MOD) ? this.customModLoaderInput_ : this.loaderInput_;
  }

  private setActiveLoaderFilter_(loader: string): void {
    if (this.usesCustomResourceSave_(ResourceKind.MOD)) this.customModLoaderInput_ = loader;
    else this.loaderInput_ = loader;
  }

  // ===================== 快速安装（已退役 — Phase R-3 之后由详情 sheet 流转替代） =====================
  // 旧 handleQuickInstall / fetchAndInstallLatest / askOptionalDeps 已合并进
  // openDetail / prefetchDetail / confirmInstallFromSheet / executeInstall。

  /** ResourceKind → 用户可读中文标签 */
  private kindLabelOf(kind: ResourceKind): string {
    if (kind === ResourceKind.RESOURCE_PACK) return '资源包';
    if (kind === ResourceKind.SHADER) return '光影';
    if (kind === ResourceKind.DATAPACK) return '数据包';
    if (kind === ResourceKind.MODPACK) return '整合包';
    return '模组';
  }

  private toast(msg: string): void {
    try {
      // 2026-05-23 API NEXT 迁移：promptAction.showToast 全局函数弃用，
      // 改走 this.getUIContext().getPromptAction().showToast(...)。
      // 详见 docs/guides/api-migration-2026-05.md。
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
    } catch (e) {
      // 某些测试或者非 UIAbility 环境下 promptAction 不可用，忽略
    }
  }

  /**
   * 先发布可浏览的版本/文件/直接依赖，再独立补齐安装所需的地址、本地扫描和依赖计划。
   * 所有 await 后都受选版代次与目标快照约束；失败只禁止安装，不清除浏览元数据。
   */
  private async loadChosenDetail(v: RemoteVersion, epoch: number): Promise<void> {
    if (this.detailFetchEpoch_ !== epoch) return;
    const project = this.detailProject_;
    const saveFileOnly = this.usesCustomResourceSave_(project.kind);
    const mcDir = this.targetMcDir_;
    const versionId = this.targetVersionId_;
    let primary = pickPrimaryFile(v.files);
    this.detailSelectedVersion_ = v;
    this.detailPrimaryFile_ = primary;
    this.detailDeps_ = this.buildDeclaredDepRows(v);
    this.detailResolvedDeps_ = [];
    this.detailDependenciesResolved_ = false;
    this.detailInstalledVersionIds_ = [];
    this.detailInstalledPrimary_ = null;
    this.detailScanInfo_ = '';
    this.detailLoading_ = false;
    this.detailPreparingInstall_ = false;
    this.detailInstallReady_ = false;
    this.detailPreparedMcDir_ = '';
    this.detailPreparedVersionId_ = '';
    this.detailPreparedForResourceSave_ = false;
    this.detailInstallError_ = this.detailInstallIssue(v);
    if (this.detailInstallError_.length > 0 || primary === null) return;

    this.detailPreparingInstall_ = true;
    try {
      const router = this.router_;
      if (router === null) throw new Error('模组来源未就绪');
      // 地址获取属于安装准备；即使 CF 的补地址请求失败，也保留原文件名/大小供浏览。
      if (primary.url.length === 0 && v.source === ModSource.CURSEFORGE) {
        const repo = router.repoFor(v.source) as CurseForgeRepository;
        const info = project.kind === ResourceKind.MODPACK
          ? await repo.resolveArchiveDownloadInfo(v.projectId, v.id)
          : await repo.resolveFileDownloadInfo(v.projectId, v.id);
        if (this.detailFetchEpoch_ !== epoch) return;
        primary = { url: info.urls[0] ?? '', mirrors: info.urls.slice(1), filename: info.filename,
          size: info.size, sha1: info.sha1, isPrimary: true };
      }
      if (primary.url.length === 0) throw new Error('此版本的下载地址暂不可用，仍可查看详情');
      if (saveFileOnly) {
        // 另存只准备真实分发文件；依赖继续展示声明，不扫描本地实例或运行安装解析器。
        this.detailPrimaryFile_ = primary;
        this.detailPreparedForResourceSave_ = true;
        this.detailInstallReady_ = true;
        return;
      }
      const installed = project.kind === ResourceKind.MOD ? await this.getOrScanInstalled() : [];
      if (this.detailFetchEpoch_ !== epoch) return;
      if (mcDir !== this.targetMcDir_ || versionId !== this.targetVersionId_) throw new Error('安装目标已变化，请重新选择版本');
      let dependencies: ResolvedDependency[] = [];
      let errors: string[] = [];
      if (project.kind === ResourceKind.MOD) {
        const loader = resolveInstalledLoader(mcDir, versionId);
        const game = resolveInstalledMcVersion(mcDir, versionId);
        const opt: ResolveOptions = { loader: loader, gameVersion: game, installed: installed,
          followOptional: true, selectedOptionalIds: this.detailOptionalIds_.slice() };
        const result = await makeResolverFromRouter(router).resolve(v, opt);
        dependencies = result.dependencies;
        errors = dependencyPlanErrors(result);
      }
      if (this.detailFetchEpoch_ !== epoch) return;
      if (mcDir !== this.targetMcDir_ || versionId !== this.targetVersionId_) throw new Error('安装目标已变化，请重新选择版本');
      const own = installed.filter((m: LocalMod): boolean => m.remoteSource === project.source && m.remoteProjectId === project.id);
      this.detailInstalledVersionIds_ = own.map((m: LocalMod): string => m.remoteVersionId ?? '');
      this.detailInstalledPrimary_ = own.length === 0 ? null : {
        filePath: own[0].filePath, enabled: own[0].enabled, baseName: InstalledModIndex.baseNameOf(own[0].filename)
      };
      this.detailScanInfo_ = project.kind === ResourceKind.MOD ? '本地共 ' + installed.length + ' 个模组，已识别 '
        + installed.filter((m: LocalMod): boolean => (m.remoteProjectId ?? '').length > 0).length + ' 个来源' : '';
      this.detailPrimaryFile_ = primary;
      this.detailResolvedDeps_ = dependencies;
      this.detailDeps_ = this.buildDepRows(dependencies, installed);
      this.detailDependenciesResolved_ = true;
      this.detailInstallError_ = errors.join('\n');
      this.detailPreparedMcDir_ = mcDir;
      this.detailPreparedVersionId_ = versionId;
      this.detailInstallReady_ = errors.length === 0;
    } catch (error) {
      if (this.detailFetchEpoch_ !== epoch) return;
      this.detailInstallError_ = (error as Error).message || '安装准备失败，仍可查看详情';
    } finally {
      if (this.detailFetchEpoch_ === epoch) this.detailPreparingInstall_ = false;
    }
  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
    Column({ space: 12 }) {
      Scroll() {
        Column({ space: 12 }) {
          Text('将在设置选择的位置创建独立版本').fontSize(12).fontColor(this.theme.textSecondary)
          ModpackNameInput({ theme: this.theme, value: this.localModpackName_, error: this.localModpackNameError_,
            onChange: (value: string): void => {
              this.localModpackName_ = value;
              this.localModpackNameError_ = validateModpackVersionName(value);
            } })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      Button('开始安装').width('100%').height(44).borderRadius(14)
        .backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary)
        .enabled(this.localModpackNameError_.length === 0 && this.localModpackArchive_.length > 0)
        .onClick((): void => { this.confirmLocalModpack_(); })
    }.width('100%').height('100%').padding(16).alignItems(HorizontalAlign.Start)
    }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent2_() {
    Column({ space: 12 }) {
      if (this.modpackRecoveryLoading_) {
        Text('正在读取恢复记录…').fontColor(this.theme.textSecondary)
      } else if (this.modpackRecoveryFailed_) {
        Text('读取恢复记录失败').fontColor(this.theme.textSecondary)
        Button('重试').onClick(() => this.refreshModpackRecovery_())
      } else if (this.modpackRecovery_.length === 0) {
        Text('没有需要继续的安装').fontColor(this.theme.textSecondary)
      } else {
        List({ space: 8 }) {
          ForEach(this.modpackRecovery_, (item: ModpackRecoveryItem) => {
            ListItem() {
              Row({ space: 4 }) {
                Column({ space: 4 }) {
                  Text(item.versionName.length > 0 ? item.versionName : item.title)
                    .fontSize(15).fontColor(this.theme.textPrimary).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.confirmed ? ('继续原实例 · ' + item.missingCount + ' 项待处理') : '清单已保存 · 待确认安装')
                    .fontSize(12).fontColor(this.theme.textSecondary)
                }
                .layoutWeight(1).padding({ left: 14, top: 10, bottom: 10 }).alignItems(HorizontalAlign.Start)
                .enabled(this.modpackDismissId_ !== item.id).focusable(true)
                .onClick(() => { this.resumeModpack_(item); })

                // 恢复区与叉号是兄弟节点，点击叉号不会触发恢复。
                Button({ type: ButtonType.Circle }) {
                  if (this.modpackDismissId_ === item.id) {
                    LoadingProgress().width(16).height(16).color(this.theme.textSecondary)
                  } else {
                    AppIcon({ name: AppIconName.Close, iconSize: 16, color: this.theme.textSecondary })
                  }
                }
                .width(44).height(44).backgroundColor(Color.Transparent)
                .accessibilityText(this.modpackDismissId_ === item.id ? '正在处理安装记录'
                  : '放弃「' + (item.versionName.length > 0 ? item.versionName : item.title) + '」的继续安装')
                .enabled(this.modpackDismissId_.length === 0)
                .onClick(() => { void this.confirmDismissModpack_(item); })
              }
              .width('100%').padding({ right: 6 }).backgroundColor(this.theme.bgCard).borderRadius(12)
            }
          }, (item: ModpackRecoveryItem): string => item.id)
        }.layoutWeight(1).width('100%')
      }
    }.padding(20).width('100%').height('100%')
    }
}

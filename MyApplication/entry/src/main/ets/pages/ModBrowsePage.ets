import { DiagnosticPolicy } from 'commons';
/**
 * ModBrowsePage.ets — 模组浏览页（P1-MODS Phase 1.6 → 2.3 升级）
 *
 * 文档：docs/guides/mod-download-system-plan.md §八.2
 *
 * Phase 2 升级范围（本次）：
 *   - 双数据源：Modrinth + CurseForge（通过 ModSourceRouter 自动合并去重）
 *   - 依赖自动解析：点击卡片 → 解析 root 版本 + REQUIRED 依赖图 → 一次性下载
 *   - OPTIONAL 依赖：弹一次性确认对话框，"全部安装" / "只装必需"
 *
 * 保留 Phase 1 已有：
 *   - 类别切换 / 搜索框 + 去抖 / 版本+loader 筛选 / ModCard 列表 + 无限滚动
 *   - 状态消息 / 加载 / 错误 / 空状态
 *
 * 后续 Phase（待做）：完整 ModDetailSheet（用户手动选版本 + 单独勾选每个依赖）
 *
 * 创建日期：2026-05-11
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
import { getDownloadHistoryStore, DownloadHistoryRecord } from 'feature_core';
import { ActivityCategory } from 'feature_core';
// 活动账本：模组/资源安装也要有自己的日志（2026-08-01 自审补漏）
import { ledgerBegin, ledgerEnd, LedgerBeginMeta, LedgerOutcome, LedgerState } from 'commons';
import { getMetadataCacheStore } from 'feature_core';
// 加速下载开启时强制官方源（见 resolveModrinthMode）
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
  ModSource, ResourceKind, RemoteProject, RemoteVersion, DependencyType,
  pickPrimaryFile, RemoteFile, LocalMod,
} from 'mods';
import { buildCurseForgeFileDownloadUrls } from 'mods';
import { resolveInstalledLoader, resolveInstalledMcVersion } from 'mods';
import { IRemoteModRepository, SortBy } from 'mods';
import { ModrinthSourceMode } from 'mods';
import { ModCard } from '../components/ModCard';
import { loadModTranslationStores, ModTranslationStores,
  getCachedTranslationStores, onTranslationStoresUpdated, offTranslationStoresUpdated } from '../services/ModTranslationLoader';
// v6.5 (2026-05-22)：ModBrowsePage 不再推送 ModDlState 给 Index；改为 registry.enqueue。
import { ModDetailSheet, ModDetailDepRow } from '../components/ModDetailSheet';
import { getDownloadTaskRegistry } from 'feature_core';
import { ResourceInstallTask } from 'mods';
import { ModpackInstallTask } from 'mods';
import { CfFileResolution } from 'mods';
import { ModpackMissingItem } from 'mods';
import { GameArchiveIO } from '../components/GameArchiveIO';
import { LocalModScanner } from 'mods';
import { InstalledModIndex } from 'mods';
import { ModUpdateCoordinator } from '../components/ModUpdateCoordinator';
import { centerSheetForLayout, sheetWidthForLayout, detailSheetHeightForLayout } from 'commons';
import { Breakpoint, DeviceForm } from 'commons';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppIconName } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_DOWNLOAD } from 'commons';
import { AppIcon } from '../components/AppIcon';

const TAG = 'ModBrowsePage';

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
  @Prop theme: ThemeColors = {} as ThemeColors;
  /** .minecraft 根目录绝对路径（不带尾部 /） */
  @Prop mcDir: string = '';
  /** 当前选中的已装 MC 版本 id（用于目标目录计算 + 默认筛选） */
  @Prop currentMcVersion: string = '';
  @Prop versionIsolation: boolean = true;
  /** P0 修复 #4：用于校验 currentMcVersion 是否真的存在（防止凭空创建版本目录） */
  @Prop availableVersions: string[] = [];
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
   * Phase R-1 新增：外部 DownloadTab 顶级横向 Tabs 切换时传入的默认资源类别。
   * 0 = MOD / 1 = RESOURCE_PACK / 2 = SHADER。aboutToAppear 时同步到内部 kindIdx_。
   * 注：组件挂载后再修改此 prop 不会重新触发 aboutToAppear（ArkUI @Prop 单向语义）；
   *     R-3 后由外部完全受控时再做 controlled 化重构。
   */
  @Prop defaultKindIdx: number = 0;

  /** 给 Index 做 toast/log 的回调（可选） */
  onStatusMessage: (msg: string) => void = () => {};
  // v6.5：以下两个回调已下台，走 registry 是唯一的模组下载路径。

  // ===================== 内部状态 =====================

  @State private inited_: boolean = false;

  // 0=MOD, 1=RESOURCE_PACK, 2=SHADER；aboutToAppear 中按 defaultKindIdx 同步
  @State private kindIdx_: number = 0;
  @State private queryInput_: string = '';
  @State private gameVersionInput_: string = '';
  @State private loaderInput_: string = 'fabric';

  /** ctrl.getState() 的快照，UI 渲染用 */
  @State private view_: ModSearchState = makeInitialSearchState();

  /** 正在下载中的卡片 id 集合（允许多个不同资源并发；同一资源不重复入队）。 */
  private downloadingProjectIds_: Set<string> = new Set<string>();

  // ===================== 详情 Sheet 状态（Phase R-3 收尾） =====================

  /** 详情 sheet 显示开关 */
  @State private showDetailSheet_: boolean = false;
  @State private detailError_: string = '';
  private detailOptionalIds_: string[] = [];
  /** 当前打开详情的 project；空对象 → 占位 */
  @State private detailProject_: RemoteProject = {} as RemoteProject;
  /** 已解析的 best version；null 表示尚在 fetch 中 */
  @State private detailSelectedVersion_: RemoteVersion | null = null;
  /** 该项目全部版本列表（picker step 用） */
  @State private detailAllVersions_: RemoteVersion[] = [];
  /** primary file（决定下载大小、文件名） */
  @State private detailPrimaryFile_: RemoteFile | null = null;
  /** 依赖项展示 */
  @State private detailDeps_: ModDetailDepRow[] = [];
  /** 详情 fetch 中标记 */
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

  /** 缓存解析得到的全量 ResolvedDependency（含失败 / OPTIONAL 全集），install 时按勾选过滤 */
  private detailResolvedDeps_: ResolvedDependency[] = [];

  /** Phase 3 LocalModScanner 缓存（同 mcDir + versionId 之间共享一次扫描结果） */
  private localScanCache_: Map<string, LocalMod[]> = new Map<string, LocalMod[]>();

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

  // ===================== Phase R-3+ 头部滑动收起 =====================

  /**
   * 折叠态：true 表示 ContextCard / Loader chips / Sort row 都收起，
   * 只保留搜索框（顶部 6-tab 由 DownloadTab 负责，始终可见）。
   *
   * 实现：用 ListItemGroup({ header: SearchBox }) + .sticky(StickyStyle.Header)。
   * 搜索框作为 List 的粘性头部，**永远钉在 List 视口顶端**；
   * 折叠区（ContextCard/Loader/Sort）作为 List 的第一个普通 ListItem，
   * 跟卡片一起滚 — 上滑被搜索框遮挡消失，下滑从搜索框背后浮现。
   *
   * 这是 ArkUI 标准的"粘性头部"模式：
   *   - 折叠区和卡片必须在**同一个 List 容器**才能视觉同步、无空隙
   *   - 任意位置下拉都能召回折叠区，因为它本来就在 list 的滚动序列里
   *   - 不漂移：列表布局不重排（外层 Column / 兄弟节点都不变化）
   *
   * 触发：
   *   ① 自然滚动 — onDidScroll 仅读 yOffset 决定 chev 朝向，不参与动画
   *   ② 搜索框右侧 ▾ / ▴ 按钮 → scroller.scrollTo({ yOffset: 0 / FilterPanelHeight })
   */
  @State private headerCollapsed_: boolean = false;
  /** 列表滚动控制器（按钮触发滚动用） */
  private listScroller_: Scroller = new Scroller();
  /** 折叠区域占用的 vp 高度（按钮滚动 + 阈值判定用它） */
  private static readonly FILTER_PANEL_HEIGHT = 160;
  /** 滚动方向状态判断阈值（vp） */
  private static readonly COLLAPSE_THRESHOLD = 20;

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
    // Phase R-1：外部 DownloadTab 顶级 Tab 切换决定的默认资源类别
    if (this.defaultKindIdx >= 0 && this.defaultKindIdx <= 3) {
      this.kindIdx_ = this.defaultKindIdx;
    }

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
      () => isMcimAvailable(), cacheEnabled);
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
    this.targetValid_ = this.currentMcVersion.length > 0
      && this.availableVersions.indexOf(this.currentMcVersion) >= 0;

    // 2. P0 修复 #2/#7：从目标版本提取 game version + 推断 loader（整合包/重命名版本名
    //    无版本号/无 loader 关键字，走快照/内容解析，避免拿到整合包名当 MC 版本）
    this.gameVersionInput_ = resolveInstalledMcVersion(this.targetMcDir_, this.targetVersionId_);
    let detectedLoader = resolveInstalledLoader(this.targetMcDir_, this.targetVersionId_);
    // 原版（detected===''）保留 'fabric' 默认（搜模组最常见）
    this.loaderInput_ = detectedLoader.length > 0 ? detectedLoader : 'fabric';

    // 3. 应用到控制器
    this.applyFiltersToController();

    // 4. 异步触发源探测（不阻塞）
    ensureModrinthRanking().catch((e: Error) => {
      AppLogger.warn(TAG, 'probe failed (non-fatal)', e, LOG_DOMAIN_DOWNLOAD);
    });

    // 5. 首次搜索由译名库就绪回调触发（见上方 doInitialSearch_）。
    //    兜底：本地译名加载极快，但万一 loadModTranslationStores 异常/未按预期触发，
    //    600ms 后仍强制搜一次，保证列表一定会加载。
    setTimeout(() => { this.doInitialSearch_(); }, 600);
    this.inited_ = true;
  }

  /** 首屏搜索仅触发一次（本地译名就绪 or 兜底超时，取先到者）。 */
  private doInitialSearch_(): void {
    if (this.initialSearchDone_) return;
    this.initialSearchDone_ = true;
    this.triggerSearch(true);
  }

  aboutToDisappear() {
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
    this.localScanCache_.clear();
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
   *   - 'mcim'     → 强制 MCIM_FIRST
   *   - 'official' → 强制 OFFICIAL_FIRST
   */
  private resolveModrinthMode(): ModrinthSourceMode {
    // 加速下载开启时**强制官方源**，忽略上面三档偏好：
    // 网关到 cdn.modrinth.com 实测 5.36MB/s 且不会被地域重定向甩到慢节点；
    // 此时再走 mcim 镜像只会多一跳转发，还可能撞上镜像自身缓存未命中回源。
    // 注意判据是"加速真的可用"（握手成功且票据有效），不是"用户打开了开关"——
    // 握手失败时必须退回原偏好，否则会把用户按在一条没有加速的官方源上。
    if (getRelayClient().status().active) return ModrinthSourceMode.OFFICIAL_FIRST;
    if (this.modSource === 'mcim') return ModrinthSourceMode.MCIM_FIRST;
    if (this.modSource === 'official') return ModrinthSourceMode.OFFICIAL_FIRST;
    return getModrinthSourceMode();
  }

  // ===================== 构建 UI（v2 重构）=====================

  build() {
    Column() {
      // ============== Pinned 搜索框（始终渲染，不受 loading/error/empty 状态切换影响） ==============
      // 关键：必须放在 List 外面，否则 List 在 loading↔result 切换时会 unmount 整个 List
      // 包括其 header（搜索框），TextInput 重挂载会触发 onChange 形成无限循环。
      this.PinnedSearchHeader()

      // ============== 列表区 ==============
      // 设计：用 ListItemGroup + sticky:Header 让搜索框作为 List 的真正粘性头部？
      // ✗ 不行 —— 见上面注释，TextInput 不能跟 List 一起 unmount。
      // ✓ 做法：搜索框外置 + 折叠区作为 List 的第一个普通 ListItem。
      //   - 上滑：折叠区 + 卡片一起从屏幕顶端滑出（被搜索框区域遮住，clip 在 Stack 边界）
      //   - 下滑：从搜索框背后一起滑出来（任意位置都能召回）
      //   - 不漂移：折叠区在 List 内部，跟卡片一起滚动，外层 Column 不重排
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.view_.loading && this.view_.hits.length === 0) {
          this.LoadingBlock('正在搜索...')
        } else if (this.view_.errorMessage !== null && this.view_.hits.length === 0) {
          this.ErrorBlock(describeSearchFailureForUser(
            this.view_.errorKind, this.view_.httpStatus, this.view_.errorMessage))
        } else if (this.view_.hits.length === 0) {
          this.EmptyBlock()
        } else {
          List({ space: 8, scroller: this.listScroller_ }) {
            // 第一项：折叠区（ContextCard / Loader chips / Sort row）
            ListItem() {
              Column({ space: 10 }) {
                // 整合包创建独立新版本，无"安装到目标版本"概念，不显示 ContextCard
                if (this.kindIdx_ !== 3) {
                  this.ContextCard()
                }
                if (this.kindIdx_ === 0 || this.kindIdx_ === 3) {
                  this.LoaderChipsRow()
                }
                if (this.kindIdx_ === 3) {
                  this.ModpackImportRow()
                }
                this.SortRow()
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 4, bottom: 8 })
            }

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
                    LoadingProgress().width(20).height(20).color(this.theme.primary)
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
          .padding({ left: 12, right: 12, bottom: 16 })
          .onReachEnd(() => {
            if (this.view_.hasMore && !this.view_.loading) {
              this.loadNextPage();
            }
          })
          .onDidScroll((_scrollOffset: number, _scrollState: ScrollState) => {
            this.handleListScroll()
          })
        }
      }
      .width('100%')
      .layoutWeight(1)

      // ============== ModDetailSheet 锚点 ==============
      Column().width(0).height(0)
        .bindSheet($$this.showDetailSheet_, this.ModDetailSheetBuilder(), {
          height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight),
          // 一多：仅平板/PC 宽屏限宽（手机返回 undefined，绝不给底部抽屉加宽度）
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          // 平板/PC 居中卡片不再显示系统关闭按钮（会与 sheet 内功能按钮重叠）；底部抽屉用拖拽条
          dragBar: !centerSheetForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false,
          backgroundColor: this.theme.bgPrimary,
          blurStyle: BlurStyle.NONE,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          onDisappear: () => { this.closeDetail() },
        })

      // ============== VersionPickerSheet 锚点（选安装目标版本） ==============
      Column().width(0).height(0)
        .bindSheet($$this.showVersionPicker_, this.VersionPickerBuilder(), {
          height: detailSheetHeightForLayout(this.deviceForm, this.appBreakpoint, this.bottomSafeHeight, this.topSafeHeight),
          width: sheetWidthForLayout(this.deviceForm, this.appBreakpoint),
          dragBar: !centerSheetForLayout(this.deviceForm, this.appBreakpoint),
          showClose: false,
          backgroundColor: this.theme.bgPrimary,
          blurStyle: BlurStyle.NONE,
          preferType: centerSheetForLayout(this.deviceForm, this.appBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          onDisappear: () => { this.showVersionPicker_ = false },
        })
    }
    .width('100%')
    .height('100%')
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
      selectedVersionId: this.targetVersionId_,
      initialTab: this.targetLocation_ === 'external' ? 1 : 0,
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
      scanInfo: this.detailScanInfo_,
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

  private searchPlaceholder(): string {
    if (this.kindIdx_ === 1) return '搜索资源包 / Modrinth + CurseForge…';
    if (this.kindIdx_ === 2) return '搜索光影 / Modrinth + CurseForge…';
    if (this.kindIdx_ === 3) return '搜索整合包 / Modrinth + CurseForge…';
    return '搜索模组 / Modrinth + CurseForge…';
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
   * Context Card —— "安装到：<目标版本> [沙箱/外部]"，副行显示匹配的 MC 版本 + loader。
   * "切换"按钮弹出 VersionPickerSheet：左右页签切沙箱 / 外部，选真实已装版本。
   */
  @Builder
  ContextCard() {
    Row({ space: 10 }) {
      AppIcon({ name: AppIconName.Folder, iconSize: 16, color: this.theme.textSecondary })
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text('安装到')
            .fontSize(11)
            .fontWeight(500)
            .fontColor(this.theme.textHint)
          // 沙箱 / 外部 角标
          Text(this.targetLocation_ === 'external' ? '外部' : '沙箱')
            .fontSize(10)
            .fontWeight(600)
            .fontColor(this.targetLocation_ === 'external' ? this.theme.primary : this.theme.textSecondary)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(6)
            .backgroundColor(this.targetLocation_ === 'external' ? this.theme.primaryLight : this.theme.bgInput)
        }
        .alignItems(VerticalAlign.Center)

        Text(this.targetVersionId_.length > 0 ? this.targetVersionId_ : '未选择版本')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(this.hasValidCurrentVersion() ? this.theme.textPrimary : this.theme.error)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 4 }) {
          Text(this.gameVersionInput_.length > 0 ? 'MC ' + this.gameVersionInput_ : '全部 MC 版本')
            .fontSize(11)
            .fontColor(this.theme.textSecondary)
          if (this.kindIdx_ === 0 && this.loaderInput_.length > 0) {
            Text('·')
              .fontSize(11)
              .fontColor(this.theme.textHint)
            Text(this.capitalize(this.loaderInput_))
              .fontSize(11)
              .fontWeight(500)
              .fontColor(this.theme.primary)
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // "切换" 按钮 —— 弹出 VersionPickerSheet
      Row({ space: 4 }) {
        AppIcon({ name: AppIconName.Game, iconSize: 12, color: this.theme.primary })
        Text('切换')
          .fontSize(12)
          .fontWeight(600)
          .fontColor(this.theme.primary)
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

  /**
   * sticky 搜索框头部：作为 ListItemGroup.header。
   * 关键约束：
   *   - 必须实色背景（this.theme.bgPrimary），否则身后滚动的 list 内容会透出来
   *   - padding 跟整个 List 的水平 padding 对齐，让搜索框跟卡片视觉对齐
   *   - 不能加 shadow / borderRadius，否则会破坏"内容滑过后面消失"的错觉
   */
  @Builder
  PinnedSearchHeader() {
    Column() {
      this.SearchBox()
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .backgroundColor(this.theme.bgPrimary)
  }

  /** Phase R-2：搜索框（圆角 22dp + 图标 + 清除） */
  @Builder
  SearchBox() {
    Row() {
      AppIcon({ name: AppIconName.Search, iconSize: 15, color: this.theme.textHint })
      TextInput({ placeholder: this.searchPlaceholder(), text: this.queryInput_ })
        .height(38)
        .fontSize(13)
        .layoutWeight(1)
        .margin({ left: 8 })
        .backgroundColor(Color.Transparent)
        .borderRadius(0)
        .onChange((val: string) => {
          this.queryInput_ = val;
          this.debouncedSearch();
        })
      if (this.queryInput_.length > 0) {
        Row() {
          AppIcon({ name: AppIconName.Close, iconSize: 14, color: this.theme.textHint })
        }
        .padding({ left: 10, right: 6 })
        .onClick(() => {
          this.queryInput_ = '';
          this.applyFiltersToController();
          this.triggerSearch(true);
        })
      }

      // 折叠 / 展开切换按钮（搜索框右端 ▾ / ▴）
      Row() {
        AppIcon({
          name: this.headerCollapsed_ ? AppIconName.ChevronUp : AppIconName.ChevronDown,
          iconSize: 13,
          color: this.headerCollapsed_ ? this.theme.primary : this.theme.textSecondary,
          weight: FontWeight.Bold,
        })
      }
      .width(28).height(28)
      .borderRadius(14)
      .backgroundColor(this.headerCollapsed_ ? this.theme.primaryLight : this.theme.bgInput)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ left: 6 })
      .onClick(() => { this.setHeaderCollapsed(!this.headerCollapsed_) })
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 8 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(22)
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
  }

  /** Loader chips 行（与设计稿 Screen B 一致：Fabric / Forge / NeoForge / Quilt） */
  @Builder
  LoaderChipsRow() {
    Row({ space: 8 }) {
      this.LoaderChip('fabric')
      this.LoaderChip('forge')
      this.LoaderChip('neoforge')
      this.LoaderChip('quilt')
    }
    .width('100%')
  }

  /** 排序行：左侧 "共 N 条 · 按下载量"、右侧"排序 ▾" */
  @Builder
  SortRow() {
    Row() {
      // 左侧统计
      if (this.view_.totalHits > 0) {
        Text('共 ' + this.view_.totalHits + ' 条 · 按下载量')
          .fontSize(11)
          .fontWeight(500)
          .fontColor(this.theme.textSecondary)
          .layoutWeight(1)
      } else if (this.hasValidCurrentVersion()) {
        Text(this.computeInstallDirShortcut())
          .fontSize(11)
          .fontColor(this.theme.textHint)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
          .layoutWeight(1)
      } else {
        Text('请先在首页选择 / 下载一个 MC 版本')
          .fontSize(11)
          .fontColor(this.theme.error)
          .layoutWeight(1)
      }

      // 右侧排序按钮（P3 占位 - 当前只有"下载量"排序）
      Row({ space: 4 }) {
        Text('排序').fontSize(11).fontWeight(500).fontColor(this.theme.textSecondary)
        AppIcon({ name: AppIconName.ChevronDown, iconSize: 11, color: this.theme.textSecondary })
      }
      .height(28)
      .padding({ left: 10, right: 10 })
      .borderRadius(14)
      .backgroundColor(this.theme.bgCard)
      .alignItems(VerticalAlign.Center)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
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
    // 把搜索筛选同步到所选版本：MC 版本号 + loader（整合包/重命名走快照/内容解析）
    this.gameVersionInput_ = resolveInstalledMcVersion(root, versionId);
    let dl = resolveInstalledLoader(root, versionId);
    if (dl.length > 0) this.loaderInput_ = dl;
    // 目标根/版本变了 → 失效本地扫描缓存
    this.localScanCache_.clear();
    this.showVersionPicker_ = false;
    this.applyFiltersToController();
    this.triggerSearch(true);
    this.toast('安装目标：' + (location === 'external' ? '外部' : '沙箱') + ' · ' + versionId);
  }

  // ============================================================
  //  头部滑动收起
  // ============================================================

  /**
   * 切换折叠态（按钮触发）：把列表平滑滚到指定位置。
   * 注意：headerCollapsed_ 不立即写入 — 由 onDidScroll 根据真实滚动位置判定，
   * 这样按钮触发的滚动和手势触发的滚动状态保持一致。
   */
  private setHeaderCollapsed(collapsed: boolean): void {
    let target: number = collapsed ? ModBrowsePage.FILTER_PANEL_HEIGHT : 0;
    try {
      this.listScroller_.scrollTo({
        xOffset: 0, yOffset: target,
        animation: { duration: 220, curve: Curve.FastOutSlowIn },
      });
    } catch (e) {
      // scroller 还没绑定（极早调用）— 直接更新 state，下次绘制时生效
      this.headerCollapsed_ = collapsed;
    }
  }

  /**
   * List.onDidScroll 回调：根据 scroller.currentOffset() 判定折叠态（仅控制 chev 朝向）。
   *
   * 阈值取折叠区 1/3 防抖：滚过 1/3 就算折叠，没滚过就算展开。
   */
  private handleListScroll(): void {
    try {
      let off = this.listScroller_.currentOffset();
      let y = (off as object as Record<string, number>)['yOffset'];
      if (typeof y !== 'number') return;
      let threshold = Math.max(ModBrowsePage.COLLAPSE_THRESHOLD,
        ModBrowsePage.FILTER_PANEL_HEIGHT / 3);
      let nextCollapsed = y >= threshold;
      if (nextCollapsed !== this.headerCollapsed_) {
        this.headerCollapsed_ = nextCollapsed;
      }
    } catch (e) { /* scroller not ready */ }
  }

  // ============================================================
  //  Phase R-3 详情 Sheet 流转
  // ============================================================

  /**
   * 用户点击 ModCard：打开详情 sheet 并异步预取版本 / 依赖。
   * 不再直接触发安装。
   *
   * 防御：
   *   - 没装好 currentMcVersion 不弹 sheet（避免后续依赖解析无的放矢），仅 toast 提示
   *   - 已经在装别的 mod → 仍可弹详情，但 confirmInstallFromSheet 会拒绝
   */
  private openDetail(project: RemoteProject): void {
    this.localScanCache_.clear();
    // 整合包创建独立新版本（不装进已有版本），不需要先选目标版本；
    // 仅 模组/资源包/光影/数据包 这类"装进已有版本"的资源才要求先选版本。
    if (project.kind !== ResourceKind.MODPACK && !this.hasValidCurrentVersion()) {
      this.toast('请先点上方"切换"选择一个已安装的 MC 版本');
      return;
    }

    // 1. 重置 detail 状态 + 显式打开 sheet（先弹后等）
    this.detailFetchEpoch_ += 1;
    let myEpoch = this.detailFetchEpoch_;
    this.detailProject_ = project;
    this.detailError_ = '';
    this.detailOptionalIds_ = [];
    this.detailSelectedVersion_ = null;
    this.detailPrimaryFile_ = null;
    this.detailAllVersions_ = [];
    this.detailDeps_ = [];
    this.detailInstalledVersionIds_ = [];
    this.detailInstalledPrimary_ = null;
    this.detailResolvedDeps_ = [];
    this.detailLoading_ = true;
    this.detailScanInfo_ = '正在扫描本地 mods/…';
    this.showDetailSheet_ = true;

    // 异步预取
    this.prefetchDetail(project, myEpoch).catch((e: Error) => {
      // 仅当本次 fetch 仍是最新一轮才提示（用户已点别的卡时不打扰）
      if (this.detailFetchEpoch_ !== myEpoch) return;
      let msg = e.message !== undefined ? e.message : String(e);
      AppLogger.warn(TAG, 'prefetchDetail failed', e, LOG_DOMAIN_DOWNLOAD);
      this.detailLoading_ = false;
      this.detailScanInfo_ = '扫描失败：' + msg;
      this.detailError_ = msg;
      this.toast('版本信息加载失败：' + msg);
    });
  }

  private async prefetchDetail(project: RemoteProject, epoch: number): Promise<void> {
    const router = this.router_;
    if (router === null) throw new Error('模组来源未就绪');
    const repo = router.repoFor(project.source);
    if (repo === null) throw new Error('没有对应的模组来源');
    const mcDir = this.targetMcDir_;
    const versionId = this.targetVersionId_;
    const loader = project.kind === ResourceKind.MOD ? resolveInstalledLoader(mcDir, versionId) : '';
    const game = project.kind === ResourceKind.MOD ? resolveInstalledMcVersion(mcDir, versionId) : '';
    this.detailError_ = '';
    const versions = await repo.getVersions(project.id, loader.length > 0 ? [loader] : undefined, game.length > 0 ? [game] : undefined);
    if (this.detailFetchEpoch_ !== epoch) return;
    if (mcDir !== this.targetMcDir_ || versionId !== this.targetVersionId_) throw new Error('安装目标已变化，请重新打开详情');
    this.detailAllVersions_ = versions.slice();
    const picked = pickBestVersion(versions, loader, game);
    if (picked === null) throw new Error('没有匹配目标版本的可下载文件');
    this.detailSelectedVersion_ = picked;
    const installed = project.kind === ResourceKind.MOD ? await this.getOrScanInstalled() : [];
    if (this.detailFetchEpoch_ !== epoch) return;
    const own = installed.filter((m: LocalMod): boolean => m.remoteSource === project.source && m.remoteProjectId === project.id);
    this.detailInstalledVersionIds_ = own.map((m: LocalMod): string => m.remoteVersionId ?? '');
    this.detailInstalledPrimary_ = own.length === 0 ? null : {
      filePath: own[0].filePath, enabled: own[0].enabled, baseName: InstalledModIndex.baseNameOf(own[0].filename)
    };
    this.detailScanInfo_ = '本地共 ' + installed.length + ' 个模组，已识别 '
      + installed.filter((m: LocalMod): boolean => (m.remoteProjectId ?? '').length > 0).length + ' 个来源';
    await this.loadChosenDetail(picked, epoch, installed);
  }

  private async pickDetailVersion(v: RemoteVersion): Promise<void> {
    const epoch = ++this.detailFetchEpoch_;
    this.detailLoading_ = true;
    this.detailError_ = '';
    this.detailPrimaryFile_ = null;
    this.detailSelectedVersion_ = v;
    try {
      const installed = this.detailProject_.kind === ResourceKind.MOD ? await this.getOrScanInstalled() : [];
      if (epoch !== this.detailFetchEpoch_) return;
      await this.loadChosenDetail(v, epoch, installed);
    } catch (e) {
      if (epoch !== this.detailFetchEpoch_) return;
      this.detailError_ = (e as Error).message;
      this.detailLoading_ = false;
    }
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
    if (this.detailLoading_) return;
    const row = this.detailDeps_.find((r: ModDetailDepRow): boolean => r.key === key);
    if (row === undefined || row.dependencyType !== DependencyType.OPTIONAL) return;
    this.detailOptionalIds_ = this.detailOptionalIds_.indexOf(key) >= 0
      ? this.detailOptionalIds_.filter((id: string): boolean => id !== key) : [...this.detailOptionalIds_, key];
    if (this.detailSelectedVersion_ !== null) this.pickDetailVersion(this.detailSelectedVersion_);
  }

  private selectAllDetailDeps(): void {
    if (this.detailLoading_) return;
    this.detailOptionalIds_ = this.detailDeps_.filter((r: ModDetailDepRow): boolean => r.dependencyType === DependencyType.OPTIONAL)
      .map((r: ModDetailDepRow): string => r.key);
    if (this.detailSelectedVersion_ !== null) this.pickDetailVersion(this.detailSelectedVersion_);
  }

  /** sheet 关闭 → 复位状态 */
  private closeDetail(): void {
    this.showDetailSheet_ = false;
    this.detailFetchEpoch_ += 1; // 失效任何在飞的 prefetch
    this.detailLoading_ = false;
    this.detailProject_ = {} as RemoteProject;
    this.detailSelectedVersion_ = null;
    this.detailPrimaryFile_ = null;
    this.detailAllVersions_ = [];
    this.detailDeps_ = [];
    this.detailResolvedDeps_ = [];
    this.detailInstalledVersionIds_ = [];
    this.detailInstalledPrimary_ = null;
    this.detailScanInfo_ = '';
  }



  /** sheet 中点"网页"：拉起浏览器（默认打开项目自身页面；多源/百科由菜单分项走 openExternalUrl_） */
  private openWebsiteFromSheet(): void {
    let url = this.detailProject_.websiteUrl;
    if (!url || url.length === 0) {
      this.toast('该项目无可用网址');
      return;
    }
    this.openExternalUrl_(url);
  }

  /** 经系统 Want 拉起浏览器打开外部 URL。 */
  private openExternalUrl_(url: string): void {
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
    let p = this.detailProject_;
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
    if (resolved === null) {
      this.toast((source === ModSource.CURSEFORGE ? 'CurseForge' : 'Modrinth') + ' 上未找到该资源');
      return;
    }
    this.openDetail(resolved);
  }

  /** 网页菜单"打开另一源页面"：解析另一源真实工程 → 用其真实网址拉起浏览器（避免按分类猜 URL 404）。 */
  private async openCrossSourceWeb(source: ModSource): Promise<void> {
    let p = this.detailProject_;
    this.toast('正在解析' + (source === ModSource.CURSEFORGE ? ' CurseForge ' : ' Modrinth ') + '页面…');
    let resolved: RemoteProject | null = null;
    try {
      resolved = await this.resolveCounterpart(p, source);
    } catch (e) {
      AppLogger.warn(TAG, 'openCrossSourceWeb resolve failed', e as Object, LOG_DOMAIN_DOWNLOAD);
    }
    if (resolved === null || resolved.websiteUrl.length === 0) {
      this.toast((source === ModSource.CURSEFORGE ? 'CurseForge' : 'Modrinth') + ' 上未找到该资源');
      return;
    }
    this.openExternalUrl_(resolved.websiteUrl);
  }

  private confirmInstallFromSheet(): void {
    if (this.detailLoading_) { this.toast('正在解析依赖，请等待完成'); return; }
    if (this.detailError_.length > 0) { this.toast(this.detailError_); return; }
    const project = this.detailProject_;
    const picked = this.detailSelectedVersion_;
    const primary = this.detailPrimaryFile_;
    if (picked === null || primary === null || primary.url.length === 0) { this.toast('该版本不可下载'); return; }
    if (this.downloadingProjectIds_.has(project.id)) { this.toast('该资源正在安装'); return; }
    if (project.kind === ResourceKind.MODPACK) {
      this.showDetailSheet_ = false; this.installModpackFromSheet(project, picked, primary); return;
    }
    if (!this.hasValidCurrentVersion()) { this.toast('安装目标已失效'); return; }
    if (project.kind === ResourceKind.MOD && !isModVersionCompatible(picked,
      resolveInstalledLoader(this.targetMcDir_, this.targetVersionId_), resolveInstalledMcVersion(this.targetMcDir_, this.targetVersionId_))) {
      this.toast('所选文件与目标游戏版本或加载器不匹配'); return;
    }
    const deps = this.detailResolvedDeps_.slice();
    this.showDetailSheet_ = false;
    this.executeInstall(project, picked, primary, deps).catch((e: Error): void => { this.toast(e.message); });
  }

  /**
   * 整合包安装入口：下载 .mrpack/.zip → 建带 loader 的新隔离版本 → 批量下文件 → 铺 overrides。
   * 走 ModpackInstallTask（统一下载任务），在 DownloadTasksSheet 显示橙色卡片。
   */
  private installModpackFromSheet(project: RemoteProject, picked: RemoteVersion, primary: RemoteFile): void {
    let ctx = this.uiCtx();
    if (ctx === undefined) { this.toast('环境未就绪，无法安装整合包'); return; }
    let filesDir = ctx.filesDir;
    this.onStatusMessage('开始安装整合包 ' + project.title + '…');

    let sourceLabel = project.source === ModSource.CURSEFORGE ? 'CurseForge' : 'Modrinth';
    let task = new ModpackInstallTask({
      title: project.title,
      subtitle: '整合包 · ' + sourceLabel,
      iconUrl: project.iconUrl,
      archiveUrl: primary.url,
      archiveMirrors: primary.mirrors,
      archiveFilename: primary.filename,
      mcDir: this.targetMcDir_,
      filesDir: filesDir,
      existingVersions: this.availableVersions,
      projectId: project.id,
      resolveCfFile: (pid: number, fid: number, gv: string, ld: string): Promise<CfFileResolution> => {
        return this.resolveCfFileForModpack_(pid, fid, gv, ld);
      },
    });
    this.runModpackInstall_(task, project.id);
  }

  /** 统一的整合包任务入队 + 完成处理（toast + 缺失清单对话框）。在线/本地导入共用。 */
  private runModpackInstall_(task: ModpackInstallTask, lockId?: string): void {
    if (lockId !== undefined) this.downloadingProjectIds_.add(lockId);
    getDownloadTaskRegistry().enqueue(task).then(() => {
      if (lockId !== undefined) this.downloadingProjectIds_.delete(lockId);
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
      let msg = e.message !== undefined ? e.message : String(e);
      AppLogger.error(TAG, 'modpack install failed', e, LOG_DOMAIN_DOWNLOAD);
      this.toast('整合包安装失败：' + msg);
    });
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
          { text: '复制清单', color: '#3478F6' },
          { text: '知道了', color: '#666666' },
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
    let importDir = filesDir + '/modpack-import';
    let res = await GameArchiveIO.importResourceFile(ctx, importDir, ['.mrpack', '.zip']);
    if (res.cancelled) return;
    if (!res.ok) { this.toast(res.message); return; }
    let archivePath = importDir + '/' + res.name;
    let title = res.name;
    let dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    this.onStatusMessage('开始导入整合包 ' + title + '…');
    let task = new ModpackInstallTask({
      title: title,
      subtitle: '整合包 · 本地导入',
      archivePath: archivePath,
      mcDir: this.targetMcDir_,
      filesDir: filesDir,
      existingVersions: this.availableVersions,
      resolveCfFile: (pid: number, fid: number, gv: string, ld: string): Promise<CfFileResolution> => {
        return this.resolveCfFileForModpack_(pid, fid, gv, ld);
      },
    });
    this.runModpackInstall_(task);
  }

  /** 为整合包内 CurseForge 文件解析下载 URL + 文件名（projectID/fileID → CDN 直链）。
   *  gameVersion/loader 供"精确 fileId 已被作者删除时回退到兼容版本"使用。 */
  private async resolveCfFileForModpack_(
    projectId: number, fileId: number, gameVersion: string, loader: string,
  ): Promise<CfFileResolution> {
    let router = this.router_;
    if (router === null) throw new Error('CurseForge 仓库不可用');
    let repo = router.repoFor(ModSource.CURSEFORGE);
    if (repo === null) throw new Error('CurseForge 仓库不可用');
    let cfRepo = repo as CurseForgeRepository;
    // 用增强解析：downloadUrl 为空（作者禁用分发）时按 fileId 反推 CDN；
    // 精确 fileId 已删除时回退到同 MC 版本 + loader 的最新兼容文件。
    let info = await cfRepo.resolveFileDownloadInfo(
      projectId.toString(), fileId.toString(), gameVersion, loader);
    let resolution: CfFileResolution = { urls: info.urls, filename: info.filename, size: info.size, sha1: info.sha1 };
    return resolution;
  }



  private async executeInstall(project: RemoteProject, picked: RemoteVersion, primary: RemoteFile,
    _dependencies: ResolvedDependency[]): Promise<void> {
    const router = this.router_;
    if (router === null) throw new Error('模组来源不可用');
    const mcDir = this.targetMcDir_;
    const versionId = this.targetVersionId_;
    const isolation = this.versionIsolation;
    const historyGame = resolveInstalledMcVersion(mcDir, versionId);
    const historyLoader = resolveInstalledLoader(mcDir, versionId);
    const optionalIds = this.detailOptionalIds_.slice();
    const old = this.detailInstalledPrimary_;
    const started = Date.now();
    const kindLabel = this.kindLabelOf(project.kind);
    this.downloadingProjectIds_.add(project.id);
    const context = this.uiCtx();
    if (context !== undefined) {
      const meta: LedgerBeginMeta = {
        category: ActivityCategory.MOD_INSTALL, title: project.title + '（' + kindLabel + '）',
        gameVersionId: versionId, mcDir: mcDir,
        appFilesDir: context.getApplicationContext().filesDir,
      };
      ledgerBegin(context.filesDir, started, meta);
    }
    try {
      let view: UnifiedTaskView;
      if (project.kind === ResourceKind.MOD) {
        const request: ModInstallRequest = { mcDir: mcDir, versionId: versionId, versionIsolation: isolation, root: picked,
          title: project.title, router: router, optionalIds: optionalIds, oldPath: old?.filePath, wasEnabled: old?.enabled };
        const task = new ModInstallTask(request);
        view = task.view;
        await getDownloadTaskRegistry().enqueue(task);
      } else {
        const task = new ResourceInstallTask({ projectTitle: project.title, iconUrl: project.iconUrl,
          request: { kind: project.kind, mcDir: mcDir, versionId: versionId, versionIsolation: isolation, primary: primary, dependencies: [] } });
        view = task.view;
        await getDownloadTaskRegistry().enqueue(task);
      }
      this.recordHistory(project, kindLabel, started, view.filesDone, view.bytesDone, 'success', '', historyGame, historyLoader);
      this.onStatusMessage(project.title + ' 安装完成');
      this.toast(project.title + ' 安装完成');
    } catch (e) {
      this.recordHistory(project, kindLabel, started, 0, 0, 'failed', (e as Error).message, historyGame, historyLoader);
      throw e as Error;
    } finally { this.downloadingProjectIds_.delete(project.id); this.localScanCache_.clear(); }
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
    try {
      let result = await this.scanner_!.scan({
        mcDir: this.targetMcDir_,
        versionId: this.targetVersionId_,
        versionIsolation: this.versionIsolation,
        kind: ResourceKind.MOD,
        lookupLimit: 64,
      });
      this.localScanCache_.set(cacheKey, result.mods);
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
      this.applyFiltersToController();
      this.triggerSearch(true);
    })
  }

  /** 整合包标签下的「从本地导入」行（kindIdx_===3 时显示）。 */
  @Builder
  ModpackImportRow() {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Import, iconSize: 16, color: this.theme.primary })
      Text('从本地导入 .mrpack / .zip')
        .fontSize(13)
        .fontWeight(500)
        .fontColor(this.theme.primary)
        .layoutWeight(1)
      AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textHint })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(this.theme.cardRadius)
    .backgroundColor(this.theme.bgCard)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => {
      this.importLocalModpack_().catch((e: Error) => {
        AppLogger.warn(TAG, 'importLocalModpack failed', e, LOG_DOMAIN_DOWNLOAD);
        this.toast('导入失败：' + (e.message !== undefined ? e.message : String(e)));
      });
    })
  }

  @Builder
  LoaderChip(loader: string) {
    Text(loader)
      .fontSize(12)
      .fontWeight(this.loaderInput_ === loader ? 600 : 400)
      .fontColor(this.loaderInput_ === loader ? this.theme.textOnPrimary : this.theme.textSecondary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.loaderInput_ === loader ? this.theme.primary : this.theme.bgInput)
      .onClick(() => {
        if (this.loaderInput_ === loader) return;
        this.loaderInput_ = loader;
        this.applyFiltersToController();
        this.triggerSearch(true);
      })
  }

  @Builder
  LoadingBlock(text: string) {
    Column() {
      LoadingProgress().width(40).height(40).color(this.theme.primary)
      Text(text)
        .fontSize(13).fontColor(this.theme.textHint).margin({ top: 12 })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorBlock(msg: string) {
    Column({ space: 8 }) {
      AppIcon({ name: AppIconName.Error, iconSize: 28, color: this.theme.error })
      Text('搜索失败')
        .fontSize(15).fontWeight(500).fontColor(this.theme.error)
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
    let kind: ResourceKind;
    if (this.kindIdx_ === 1) kind = ResourceKind.RESOURCE_PACK;
    else if (this.kindIdx_ === 2) kind = ResourceKind.SHADER;
    else if (this.kindIdx_ === 3) kind = ResourceKind.MODPACK;
    else kind = ResourceKind.MOD;
    ctrl.setKind(kind);
    ctrl.setQuery(this.queryInput_);
    // 整合包自带 MC 版本，不按当前已装版本过滤（否则会过滤掉其它 MC 版本的整合包）
    ctrl.setGameVersion(kind === ResourceKind.MODPACK ? '' : this.gameVersionInput_);
    if (kind === ResourceKind.MOD || kind === ResourceKind.MODPACK) {
      ctrl.setLoader(this.loaderInput_);
    } else {
      ctrl.setLoader('');
    }
    ctrl.setSortBy(SortBy.DOWNLOADS);
  }

  private triggerSearch(first: boolean): void {
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
    if (this.versionIsolation && this.targetVersionId_.length > 0) {
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

  /**
   * 防重入：同一次安装的 startedAt 时间戳只能写入历史一次。
   * 已写入的 startedAt 进集合；下次同 startedAt 写入直接 short-circuit。
   * 长会话用户可能装 ≥几十个 mod，集合大小可控（每次成功/失败一条记录）。
   */
  private recordedHistoryKeys_: Set<number> = new Set<number>();

  /**
   * v2: 把单次模组安装写入 DownloadHistory，跟 MC 整版下载共用一套历史表。
   * loaderType 用 "mod-modrinth" / "mod-curseforge"，便于 DownloadHistoryPage UI 区分。
   *
   * 防重入：使用 startedAtMs 作 dedup key，避免成功路径 + catch 路径双触发导致两份历史。
   */
  private recordHistory(
    project: RemoteProject,
    kindLabel: string,
    startedAtMs: number,
    fileCount: number,
    totalBytes: number,
    status: string,
    errorMessage: string,
    gameVersion: string,
    loaderVersion: string,
  ): void {
    if (this.recordedHistoryKeys_.has(startedAtMs)) {
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'recordHistory skipped (already recorded for startedAt=%{public}d)',
        startedAtMs);
      return;
    }
    this.recordedHistoryKeys_.add(startedAtMs);
    let loaderType = project.source === ModSource.MODRINTH ? 'mod-modrinth' : 'mod-curseforge';
    let nowMs = Date.now();
    let record: DownloadHistoryRecord = {
      versionName: project.title + '（' + kindLabel + '）',
      gameVersion: gameVersion.length > 0 ? gameVersion : '-',
      loaderType: loaderType,
      loaderVersion: loaderVersion.length > 0 ? loaderVersion : undefined,
      startedAt: startedAtMs,
      durationMs: nowMs - startedAtMs,
      totalBytes: totalBytes,
      fileCount: fileCount,
      status: status,
      errorMessage: errorMessage.length > 0 ? errorMessage : undefined,
      category: ActivityCategory.MOD_INSTALL,
      endedAt: nowMs,
      title: project.title,
      subtitle: kindLabel,
    };
    // 活动账本封账：与活动记录同一主键、同一时刻
    try {
      let outcome: LedgerOutcome = {
        state: status === 'success' ? LedgerState.SUCCESS : LedgerState.FAILED,
        source: 'modInstall.terminal',
        summary: errorMessage.length > 0 ? errorMessage
          : (fileCount + ' 个文件安装完成'),
      }
      let lc = this.uiCtx()
      if (lc !== undefined) ledgerEnd(lc.filesDir, startedAtMs, outcome)
    } catch (e) {
      AppLogger.warn(TAG, 'ledgerEnd for mod install failed', e, LOG_DOMAIN_DOWNLOAD);
    }
    getDownloadHistoryStore().add(record).catch((e: Error) => {
      AppLogger.warn(TAG, 'recordHistory failed', e, LOG_DOMAIN_DOWNLOAD);
    });
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

  private async loadChosenDetail(v: RemoteVersion, epoch: number, installed: LocalMod[]): Promise<void> {
    const project = this.detailProject_;
    const mcDir = this.targetMcDir_;
    const versionId = this.targetVersionId_;
    const router = this.router_;
    if (router === null) throw new Error('模组来源未就绪');
    let primary = pickPrimaryFile(v.files);
    if (primary === null) throw new Error('该版本没有可下载文件');
    if (primary.url.length === 0 && v.source === ModSource.CURSEFORGE) {
      const repo = router.repoFor(v.source) as CurseForgeRepository;
      const info = await repo.resolveFileDownloadInfo(v.projectId, v.id);
      primary = { url: info.urls[0] ?? '', mirrors: info.urls.slice(1), filename: info.filename,
        size: info.size, sha1: info.sha1, isPrimary: true };
    }
    let dependencies: ResolvedDependency[] = [];
    let errors: string[] = [];
    if (project.kind === ResourceKind.MOD) {
      const loader = resolveInstalledLoader(mcDir, versionId);
      const game = resolveInstalledMcVersion(mcDir, versionId);
      if (!isModVersionCompatible(v, loader, game)) throw new Error('所选文件不支持 ' + loader + ' / MC ' + game);
      const opt: ResolveOptions = { loader: loader, gameVersion: game, installed: installed,
        followOptional: true, selectedOptionalIds: this.detailOptionalIds_.slice() };
      const result = await makeResolverFromRouter(router).resolve(v, opt);
      dependencies = result.dependencies;
      errors = dependencyPlanErrors(result);
    }
    if (this.detailFetchEpoch_ !== epoch) return;
    if (mcDir !== this.targetMcDir_ || versionId !== this.targetVersionId_) throw new Error('安装目标已变化，请重新选择');
    this.detailPrimaryFile_ = primary;
    this.detailResolvedDeps_ = dependencies;
    this.detailDeps_ = this.buildDepRows(dependencies, installed);
    this.detailError_ = errors.join('\n');
    this.detailLoading_ = false;
  }
}

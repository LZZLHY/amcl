/**
 * GameExportSheet — 全产品共用的游戏包导出 Sheet 内容。
 *
 * 仅负责 R4 单列视图、选择草稿和协调器事实的投影；源文件盘点、下载、归档及保存仍由
 * 进程级 GameExportCoordinator 持有。关闭和返回不会隐式取消后台任务。
 * 宿主必须把系统 Back/手势/遮罩的关闭意图交给 onRegisterDismiss 注册的处理器，
 * 不能依赖普通子组件的 onBackPress 拦截宿主；销毁时解除注册和任务订阅。
 */
import { ImmersiveTitleScaffold } from './ImmersiveTitleScaffold';
import { common } from '@kit.AbilityKit';
import { ThemeColors, AppIconName } from 'commons';
import { ExportRequest, ExportFormat, ExportLauncher, ExportIssue, exportHasErrors,
  ExportContentTree, ExportContentGroup, ExportContentItem, ExportContentSelectionResult, defaultExportContentSelection,
  setExportContentSelection, ExportContentSelectionEvaluator, reconcileExportContentSelection } from 'feature_core';
import { AppIcon } from './AppIcon';
import { SheetPageMotion } from './SheetPageMotion';
import { getGameExportCoordinator, ExportSourceView, ExportPreview, ExportTaskView } from '../export/GameExportCoordinator';
import { shouldProjectExportTask } from '../export/ExportTaskProjection';

/** 页面内的目录说明只改善可读性，传给计划器的路径仍然是原始真实相对路径。 */
function contentLabel(path: string): string {
  if (path === 'mods') return '模组（保留禁用状态）';
  if (path === 'config') return '配置';
  if (path === 'resourcepacks') return '资源包';
  if (path === 'shaderpacks') return '光影包';
  if (path === 'scripts') return '脚本';
  if (path === 'screenshots') return '截图';
  if (path === 'logs') return '游戏日志（可能含聊天及服务器信息）';
  if (path === 'servers.dat') return '服务器列表（可能含私人地址）';
  if (path === 'options.txt') return '游戏选项';
  return path;
}

/** 仅显示已经获取的真实字节数；未知的压缩后大小不从源大小推算。 */
function exportSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '未知';
  if (bytes >= 1024 * 1024 * 1024) return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GiB';
  if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MiB';
  if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KiB';
  return bytes.toString() + ' B';
}

/** 设置页只有一个纵向List；展开树先投影为可见行，懒加载不再嵌入同向Scroll。 */
interface ExportContentVisibleRow {
  id: string;
  depth: number;
  group?: ExportContentGroup;
  item?: ExportContentItem;
}

/**
 * 只负责ArkUI可见行与DataChangeListener，不保存选择或源文件句柄。
 * 源重新扫描/展开变化时整体发布新行；选择变化由组件V1选择投影整体赋值驱动。
 */
class ExportContentRowsDataSource implements IDataSource {
  private rows_: ExportContentVisibleRow[] = [];
  private listeners_: DataChangeListener[] = [];
  totalCount(): number { return this.rows_.length; }
  getData(index: number): ExportContentVisibleRow { return this.rows_[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners_.includes(listener)) this.listeners_.push(listener);
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners_ = this.listeners_.filter((value: DataChangeListener): boolean => value !== listener);
  }
  update(rows: ExportContentVisibleRow[]): void {
    this.rows_ = rows.slice();
    for (const listener of this.listeners_.slice()) listener.onDataReloaded();
  }
}

/** Builder只接一个对象字面量，建立V1的选择/展开依赖，不传多份按值状态参数。 */
interface ExportContentGroupRowOptions {
  group: ExportContentGroup;
  depth: number;
  expanded: boolean;
  selection: string;
  editable: boolean;
}
interface ExportContentItemRowOptions {
  item: ExportContentItem;
  depth: number;
  selected: boolean;
  editable: boolean;
}

/** 一次请求内的显示汇总；分类按真实路径去重，与纯选择契约的三态含义一致。 */
interface ExportContentGroupSelection {
  total: number;
  selected: number;
  state: string;
}
/**
 * 仅供当前页面绘制的选择投影，不记录文件可读性、摘要或检查资格。
 * 完整计算后整体替换State对象，V1可观察发布边界；不依靠嵌套Map的原地修改刷新UI。
 */
interface ExportContentSelectionProjection {
  items: Map<string, boolean>;
  groups: Map<string, ExportContentGroupSelection>;
  total: number;
  selected: number;
  all: boolean;
}

@Component
export struct GameExportSheet {
  /** 源身份由版本详情固定传入；界面配置只影响导出副本。 */
  @Prop mcRoot: string = '';
  @Prop versionId: string = '';
  @Prop versionIsolation: boolean = true;
  @Prop theme: ThemeColors = new ThemeColors();
  /** 父版本管理已拥有唯一标题，内嵌时不再创建第二个 HDS 宿主。 */
  @Prop embeddedHeader: boolean = false;
  /** 活动记录重入可在源版本已删除时继续展示该任务的历史结果。 */
  @Prop initialTaskId: string = '';
  /** 嵌入版本详情与兼容活动路由的返回目的地不同，文案由宿主明确传入。 */
  @Prop backLabel: string = '返回版本详情';
  onBack: () => void = () => {};
  onClose: () => void = () => {};
  /** 宿主转交所有 dismiss 意图；undefined 表示组件已销毁，不再拥有关闭处理权。 */
  onRegisterDismiss: (handler: ((back?: boolean) => void) | undefined) => void = () => {};
  @StorageProp('bottomRectHeight') private bottomSafe_: number = 0;
  @State private layer_: string = 'main';
  @State private detailsKind_: string = 'plan';
  @State private showLeaveConfirm_: boolean = false;
  @State private savingLeave_: boolean = false;
  @State private draftSaving_: boolean = false;
  @State private taskStage_: string = '';
  /** 加载器身份直接来自协调器解析结果，不能从实例名称或摘要文字推断兼容性。 */
  @State private loaderKind_: string = 'unknown';
  /** 确认面板记住返回或关闭目的地，保存结束后才调用对应宿主回调。 */
  private leaveToClose_: boolean = false;
  @State private versionId_: string = '';
  @State private sourceSummary_: string = '';
  @State private sourceIssues_: string[] = [];
  @State private shared_: boolean = false;
  @State private directories_: string[] = [];
  @State private files_: string[] = [];
  @State private worlds_: string[] = [];
  @State private selectedDirectories_: string[] = [];
  @State private selectedFiles_: string[] = [];
  @State private selectedWorlds_: string[] = [];
  /** v2排除项必须与三旧数组同时进草稿/请求，不能因页面重组请求而丢失取消子项。 */
  @State private excludedPaths_: string[] = [];
  @State private expandedGroups_: string[] = [];
  @State private scanState_: string = 'loading';
  @State private contentProjection_: ExportContentSelectionProjection = {
    items: new Map<string, boolean>(), groups: new Map<string, ExportContentGroupSelection>(),
    total: 0, selected: 0, all: false,
  };
  @State private format_: ExportFormat = 'full';
  @State private launcher_: ExportLauncher = 'pcl';
  /** 0=配置，1=已检查的预览，2=任务。缩放只重排视图，不重置这些业务状态。 */
  @State private step_: number = 0;
  /**
   * 正文使用保留式横向页槽，与版本管理父 Sheet 共用 280ms/FastOutSlowIn 手感。
   * 页面 key 与业务步骤分离：内容概览和各类别拥有独立 Scroll，返回不丢滚动位置；
   * navFrom_ 在动画完成前仍挂载、可见，不能先换 if 分支再给新内容做伪动画。
   */
  @State private navPages_: string[] = ['settings'];
  @State private navPage_: string = 'settings';
  @State private navFrom_: string = '';
  @State private navDirection_: number = 1;
  @State private pageMotion_: SheetPageMotion = new SheetPageMotion();
  private navQueuedDirection_: number = 1;
  @State private busy_: boolean = false;
  @State private loaded_: boolean = false;
  @State private dirty_: boolean = false;
  @State private error_: string = '';
  @State private notice_: string = '';
  @State private previewIssues_: string[] = [];
  @State private previewSummary_: string[] = [];
  @State private previewReady_: boolean = false;
  @State private previewFiles_: number = 0;
  @State private previewBytes_: number = 0;
  @State private previewTempBytes_: number = 0;
  @State private previewDownloads_: number = 0;
  @State private previewDownloadBytes_: number = 0;
  @State private taskState_: string = '';
  @State private taskMessage_: string = '';
  @State private taskVersion_: string = '';
  @State private taskFormat_: string = '';
  @State private taskLauncher_: string = '';
  @State private taskPlatform_: string = '';
  @State private taskFiles_: number = 0;
  @State private taskTotalFiles_: number = 0;
  @State private taskBytes_: number = 0;
  @State private taskTotalBytes_: number = 0;
  @State private taskFilename_: string = '';
  @State private taskSize_: number = 0;
  @State private taskSha256_: string = '';
  @State private taskVerified_: boolean = false;
  private context_: common.UIAbilityContext | undefined = undefined;
  private source_: ExportSourceView | null = null;
  private preview_: ExportPreview | null = null;
  private unsubscribe_: (() => void) | null = null;
  private alive_: boolean = false;
  /** 草稿落盘期间用户仍可能修改选项，用修订号避免旧保存回调抹掉新的未保存状态。 */
  private editRevision_: number = 0;
  /** 活动重入指定私有记录，可在源版本已删除时继续展示已保存的结果。 */
  private requestedTaskId_: string = '';
  /** 已展示任务即使来自另一版本，也必须继续接收终态，避免页面永久停在“正在导出”。 */
  private displayedTaskId_: string = '';
  private contentTree_: ExportContentTree | null = null;
  private readonly contentRows_: ExportContentRowsDataSource = new ExportContentRowsDataSource();
  /** full和标准包各自保存选择；MR/CF只切清单格式，不互相重置标准包勾选。 */
  private readonly formatSelections_: Map<string, ExportRequest> = new Map<string, ExportRequest>();
  /** 同一组件可能被宿主重新挂载；旧扫描不能回填新一轮选择或把读取错误吞成空。 */
  private scanGeneration_: number = 0;
  private viewGeneration_: number = 0;


  /** 注册保护先于异步读取；检查、Picker 与草稿写入期间宿主不能提前销毁组件。 */
  aboutToAppear(): void {
    this.viewGeneration_++;
    this.alive_ = true;
    // 旧挂载的异步结果只由原代次结算；重挂不得继承一个永远等不到finally的busy。
    this.busy_ = false;
    this.draftSaving_ = false;
    this.savingLeave_ = false;
    this.pageMotion_.reset(0);
    this.requestedTaskId_ = this.initialTaskId;
    this.versionId_ = this.versionId;
    this.context_ = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    // 系统 Back 与页头返回逐层回退；下拉/遮罩/关闭按钮表示真正关闭宿主。
    this.onRegisterDismiss((back: boolean = false): void => {
      if (back) this.requestBack_(); else this.requestClose_();
    });
    this.unsubscribe_ = getGameExportCoordinator().subscribe((): void => {
      if (this.alive_) this.refreshTask_();
    });
    this.refreshTask_();
    this.initialize_(this.loaded_);
  }

  /** 只解除页面资源；任务所有权属于协调器，切回详情或关闭 Sheet 均继续运行。 */
  aboutToDisappear(): void {
    this.alive_ = false;
    this.viewGeneration_++;
    this.scanGeneration_++;
    this.pageMotion_.dispose();
    this.onRegisterDismiss(undefined);
    if (this.unsubscribe_ !== null) this.unsubscribe_();
    this.unsubscribe_ = null;
  }

  /**
   * 只读盘点后恢复同一实际数据目录的草稿；保守保留合法历史意图及未知范围并提示。
   * 不以本次未发现为由静默丢弃路径，也不套用新默认；只有用户明确恢复默认才重置。
   * 历史任务自身的源身份优先于活动列表摘要；恢复结果后盘点失败也不会抹掉结果。
   */
  private async initialize_(preserveSelection: boolean = false): Promise<void> {
    if (this.busy_) return;
    const previous: ExportRequest | null = preserveSelection ? this.request_() : null;
    const generation: number = ++this.scanGeneration_;
    let mcRoot: string = this.mcRoot;
    let versionId: string = this.versionId;
    let isolation: boolean = this.versionIsolation;
    if (this.context_ === undefined) { this.scanState_ = 'error'; this.error_ = '无法取得应用上下文，请返回版本详情后重试。'; return; }
    if (!mcRoot || !versionId) { this.scanState_ = 'error'; this.error_ = '缺少导出源版本，请从版本详情重新进入。'; return; }
    this.busy_ = true;
    this.scanState_ = 'loading';
    this.error_ = '';
    // 重新发现内容本身即使未改变勾选，也已使旧检查事实过期，不能沿用另存资格。
    this.preview_ = null;
    this.previewReady_ = false;
    this.previewIssues_ = [];
    this.previewSummary_ = [];
    // 重挂或刷新撤销检查事实时一并回到设置，否则会留在没有preview的空检查页。
    // step2由进程级任务持有，包含运行中与历史结果；重新盘点不能把它降回设置。
    if (this.step_ === 1) {
      this.step_ = 0;
      this.layer_ = 'main';
      this.syncNavigation_(-1, false);
    }
    try {
      if (this.requestedTaskId_.length > 0) {
        const restored: boolean = await getGameExportCoordinator().restoreTask(this.requestedTaskId_);
        if (!this.currentScan_(generation)) return;
        const task: ExportTaskView | null = getGameExportCoordinator().getTask();
        if (restored && task !== null && task.id === this.requestedTaskId_) {
          mcRoot = task.request.mcRoot;
          versionId = task.request.versionId;
          isolation = !task.request.sharedGameDir;
          this.versionId_ = versionId;
          this.refreshTask_();
          this.step_ = 2;
          this.syncNavigation_(1, false);
        } else {
          this.notice_ = this.activeTask_() ? '已有另一项导出正在进行，先展示当前任务。' : '原导出记录已不可用，可以重新检查源版本。';
        }
      }
      const source: ExportSourceView = await getGameExportCoordinator().inspectSource(mcRoot, versionId, isolation);
      if (!this.currentScan_(generation)) return;
      this.source_ = source;
      this.contentTree_ = source.contentTree;
      this.sourceSummary_ = source.summary;
      this.loaderKind_ = source.loaderKind;
      this.sourceIssues_ = this.issueTexts_(source.issues);
      this.shared_ = source.sharedGameDir;
      this.directories_ = source.directories;
      this.files_ = source.files;
      this.worlds_ = source.worlds;
      // 新默认按导出目的由纯选择契约决定；共享目录也显示真实全部范围，不暗中当空。
      let selection: ExportRequest = defaultExportContentSelection(this.request_() as ExportRequest, source.contentTree);
      const draft: ExportRequest | null = previous ?? await getGameExportCoordinator().loadDraft(source.request.mcRoot, source.request.versionId);
      if (!this.currentScan_(generation)) return;
      if (draft !== null && draft.gameDir === source.request.gameDir && draft.sharedGameDir === source.sharedGameDir) {
        const restored: ExportContentSelectionResult = reconcileExportContentSelection(draft, source.contentTree);
        this.format_ = restored.request.format;
        this.launcher_ = restored.request.launcher;
        selection = restored.request;
        this.sourceIssues_ = this.sourceIssues_.concat(this.issueTexts_(restored.issues));
        this.notice_ = previous !== null ? '内容已重新读取，保留当前选择；请重新检查。' : '已恢复上次选择，请重新检查文件。';
      } else {
        this.formatSelections_.clear();
        this.expandedGroups_ = [];
      }
      this.applySelection_(selection);
      if (!this.pclAllowed_()) {
        this.launcher_ = 'hmcl';
        this.dirty_ = true;
        this.editRevision_++;
        this.notice_ = '此加载器的标准包使用 HMCL，接收端已调整。';
      }
      this.rebuildContentProjection_();
      this.formatSelections_.set(this.selectionFamily_(), this.request_() as ExportRequest);
      this.rebuildContentRows_();
      this.scanState_ = 'ready';
      this.loaded_ = true;
      this.refreshTask_();
      if (this.taskState_.length > 0) this.step_ = 2;
      this.syncNavigation_(1, false);
    } catch (e) {
      if (this.currentScan_(generation)) {
        this.scanState_ = 'error';
        this.preview_ = null;
        this.previewReady_ = false;
        this.error_ = '读取版本或内容失败：' + (e as Error).message;
      }
    } finally {
      if (this.currentScan_(generation)) this.busy_ = false;
    }
  }

  /** 销毁后或新扫描开始后，旧I/O结果不能把错误/空组回填到新的选择范围。 */
  private currentScan_(generation: number): boolean { return this.alive_ && this.scanGeneration_ === generation; }

  /** 检查、Picker与草稿保存的旧回调不能修改重新挂载后的页面或解除其busy保护。 */
  private currentView_(generation: number): boolean { return this.alive_ && this.viewGeneration_ === generation; }

  /** 问题按实际严重度展示；不把无法确认变为空库存或“检查通过”。 */
  private issueTexts_(issues: ExportIssue[]): string[] {
    return issues.map((issue: ExportIssue): string =>
      (issue.severity === 'error' ? '需要处理：' : '提示：') + issue.message + (issue.path ? '（' + issue.path + '）' : ''));
  }

  /** 复制草稿形成一次固定请求，后续异步任务不持有页面可修改的数组引用。 */
  private request_(): ExportRequest | null {
    if (this.source_ === null) return null;
    const base: ExportRequest = this.source_.request;
    return {
      mcRoot: base.mcRoot, versionId: base.versionId, gameDir: base.gameDir,
      exportId: base.exportId, displayName: base.displayName, format: this.format_, launcher: this.launcher_,
      platform: { os: 'windows', arch: 'x64', version: '' },
      includeDirectories: this.selectedDirectories_.slice(), includeFiles: this.selectedFiles_.slice(),
      selectedWorlds: this.selectedWorlds_.slice(), sharedGameDir: this.shared_,
      selectionVersion: 2, excludePaths: this.excludedPaths_.slice(),
    };
  }

  /** 配置变化只撤销计划资格；已启动的任务持有自己的固定请求，不能被这里更改。 */
  private changed_(): void {
    this.rebuildContentProjection_();
    this.editRevision_++;
    this.preview_ = null;
    this.previewReady_ = false;
    this.previewIssues_ = [];
    this.previewSummary_ = [];
    this.dirty_ = true;
    this.notice_ = '';
    this.error_ = '';
    this.step_ = 0;
    this.syncNavigation_(-1);
  }

  /** 选择与树元数据分开；所有数组复制后整体赋值，保留V1刷新及请求不可变边界。 */
  private applySelection_(request: ExportRequest): void {
    this.selectedDirectories_ = request.includeDirectories.slice();
    this.selectedFiles_ = request.includeFiles.slice();
    this.selectedWorlds_ = request.selectedWorlds.slice();
    this.excludedPaths_ = (request.excludePaths ?? []).slice();
  }

  /** MR/CF只是标准包的清单变体，切完整包才切换独立的选择快照。 */
  private selectionFamily_(): string { return this.format_ === 'full' ? 'full' : 'standard'; }

  /** 展开只影响可见行，不改变勾选、不弄脏草稿，也不撤销已有检查。 */
  private toggleContentGroup_(id: string): void {
    if (!this.editable_()) return;
    this.expandedGroups_ = this.expandedGroups_.includes(id)
      ? this.expandedGroups_.filter((value: string): boolean => value !== id) : this.expandedGroups_.concat([id]);
    this.rebuildContentRows_();
  }

  /** leaf与group均交同一纯helper；错误范围也允许显式排除，只有空类没有可选项。 */
  private selectNode_(id: string, selected: boolean): void {
    if (!this.editable_() || this.contentTree_ === null) return;
    const request: ExportRequest | null = this.request_();
    if (request === null) return;
    this.applySelection_(setExportContentSelection(request, this.contentTree_, id, selected));
    this.formatSelections_.set(this.selectionFamily_(), this.request_() as ExportRequest);
    this.changed_();
  }

  /** 可见树只存组/项的引用；不复制或重新解释helper的路径包含/排除规则。 */
  private rebuildContentRows_(): void {
    const rows: ExportContentVisibleRow[] = [];
    if (this.contentTree_ !== null) this.appendVisibleGroups_(this.contentTree_.groups, 0, rows);
    this.contentRows_.update(rows);
  }
  private appendVisibleGroups_(groups: ExportContentGroup[], depth: number, rows: ExportContentVisibleRow[]): void {
    for (const group of groups) {
      rows.push({ id: group.id, depth, group });
      if (!this.expandedGroups_.includes(group.id)) continue;
      for (const item of group.items) rows.push({ id: item.id, depth: depth + 1, item });
      this.appendVisibleGroups_(group.children, depth + 1, rows);
    }
  }

  /**
   * 当前请求完成变更后只构造一次Evaluator，整树共用四个路径索引。初始化及每次编辑
   * 都发布新投影；展开/滚动/统计只读投影，避免每行复制请求并重建全部Set造成N平方。
   * 这里只缓存同一请求的纯选择结果，不跨扫描复用，更不能替代盘点、检查或freeze。
   */
  private rebuildContentProjection_(): void {
    const projection: ExportContentSelectionProjection = {
      items: new Map<string, boolean>(), groups: new Map<string, ExportContentGroupSelection>(),
      total: 0, selected: 0, all: false,
    };
    const request: ExportRequest | null = this.request_();
    if (request !== null && this.contentTree_ !== null) {
      const evaluator: ExportContentSelectionEvaluator = new ExportContentSelectionEvaluator(request);
      const paths: Map<string, boolean> = new Map<string, boolean>();
      for (const group of this.contentTree_.groups) {
        const groupPaths: Map<string, boolean> = this.projectContentGroup_(group, evaluator, projection);
        groupPaths.forEach((selected: boolean, path: string): void => { if (!paths.has(path)) paths.set(path, selected); });
      }
      projection.total = paths.size;
      paths.forEach((selected: boolean): void => { if (selected) projection.selected++; });
      // 即使当前发现项都选中，显式排除仍表示自定义范围；空树与纯helper保持一致。
      projection.all = projection.selected === projection.total && (request.excludePaths ?? []).length === 0;
    }
    this.contentProjection_ = projection;
  }

  /**
   * 单次深度遍历，按分类祖先累积路径以保持重复来源去重；复杂度与单元数乘分类深度
   * 成正比，不再在每次绘制时重走整树。关联光影设置仍交Evaluator按真实包选择判断。
   */
  private projectContentGroup_(group: ExportContentGroup, evaluator: ExportContentSelectionEvaluator,
    projection: ExportContentSelectionProjection): Map<string, boolean> {
    const paths: Map<string, boolean> = new Map<string, boolean>();
    for (const item of group.items) {
      const selected: boolean = evaluator.isItemSelected(item);
      projection.items.set(item.id, selected);
      if (!paths.has(item.path)) paths.set(item.path, selected);
    }
    for (const child of group.children) {
      const childPaths: Map<string, boolean> = this.projectContentGroup_(child, evaluator, projection);
      childPaths.forEach((selected: boolean, path: string): void => { if (!paths.has(path)) paths.set(path, selected); });
    }
    let selected: number = 0;
    paths.forEach((value: boolean): void => { if (value) selected++; });
    projection.groups.set(group.id, { total: paths.size, selected,
      state: selected === 0 ? 'none' : selected === paths.size ? 'all' : 'some' });
    return paths;
  }

  private contentGroupCount_(group: ExportContentGroup): number {
    return this.contentProjection_.groups.get(group.id)?.total ?? 0;
  }
  private contentGroupSelectedCount_(group: ExportContentGroup): number {
    return this.contentProjection_.groups.get(group.id)?.selected ?? 0;
  }
  private contentGroupState_(group: ExportContentGroup): string {
    return this.contentProjection_.groups.get(group.id)?.state ?? 'none';
  }
  private contentItemSelected_(item: ExportContentItem): boolean {
    return this.contentProjection_.items.get(item.id) ?? false;
  }

  /** 草稿写入失败仍留在当前页并明确报错，不提示虚假的“已保存”。 */
  private async saveDraft_(): Promise<boolean> {
    const generation: number = this.viewGeneration_;
    const request: ExportRequest | null = this.request_();
    if (request === null || this.draftSaving_) return false;
    const revision: number = this.editRevision_;
    this.draftSaving_ = true;
    try {
      await getGameExportCoordinator().saveDraft(request);
      if (!this.currentView_(generation)) return false;
      if (this.editRevision_ === revision) {
        this.dirty_ = false;
        this.notice_ = '导出选择已保存，下次进入后仍需重新检查。';
        return true;
      }
      this.notice_ = '较早的选择已保存，当前新修改尚未保存。';
      return false;
    } catch (e) {
      if (this.currentView_(generation)) this.error_ = '保存草稿失败：' + (e as Error).message;
      return false;
    } finally { if (this.currentView_(generation)) this.draftSaving_ = false; }
  }

  /** 检查与另存互斥；计划记录实际依赖、大小与阻断项，成功也不直接触发压缩。 */
  private async check_(): Promise<void> {
    const generation: number = this.viewGeneration_;
    if (this.busy_ || this.activeTask_() || this.scanState_ !== 'ready') return;
    const request: ExportRequest | null = this.request_();
    if (request === null) return;
    this.busy_ = true;
    this.error_ = '';
    this.notice_ = '';
    try {
      const preview: ExportPreview = await getGameExportCoordinator().checkPlan(request);
      if (!this.currentView_(generation)) return;
      this.preview_ = preview;
      this.previewReady_ = !exportHasErrors(preview.issues);
      this.previewIssues_ = this.issueTexts_(preview.issues);
      this.previewSummary_ = preview.summary;
      this.previewFiles_ = preview.files;
      this.previewBytes_ = preview.totalBytes;
      this.previewTempBytes_ = preview.tempBytes;
      this.previewDownloads_ = preview.downloads;
      this.previewDownloadBytes_ = preview.downloadBytes;
      this.step_ = 1;
      this.syncNavigation_(1);
      await this.saveDraft_();
    } catch (e) {
      if (this.currentView_(generation)) this.error_ = '检查导出方案失败：' + (e as Error).message;
    } finally {
      if (this.currentView_(generation)) this.busy_ = false;
    }
  }

  /** 取得系统另存目标后才执行重工作。取消另存返回空 ID，保持预览供用户再次选择。 */
  private async start_(): Promise<void> {
    const generation: number = this.viewGeneration_;
    if (this.busy_ || this.activeTask_() || this.preview_ === null || !this.previewReady_) return;
    if (this.context_ === undefined) { this.error_ = '应用上下文已失效，请返回后重试。'; return; }
    this.busy_ = true;
    this.error_ = '';
    this.notice_ = '';
    try {
      const id: string = await getGameExportCoordinator().pickAndStart(this.context_, this.preview_);
      if (!this.currentView_(generation)) return;
      if (id.length === 0) this.notice_ = '已取消另存，导出选择和检查结果仍保留。';
      else { this.step_ = 2; this.refreshTask_(); this.syncNavigation_(1); }
    } catch (e) {
      if (this.currentView_(generation)) this.error_ = '无法开始导出：' + (e as Error).message;
    } finally {
      if (this.currentView_(generation)) this.busy_ = false;
    }
  }

  /** 任务展示使用任务自己的身份，其他版本的任务不会被页面当前标题冒充。 */
  private refreshTask_(): void {
    const task: ExportTaskView | null = getGameExportCoordinator().getTask();
    if (task === null) return;
    const active: boolean = task.state === 'running' || task.state === 'cancelling';
    const sourceRoot: string = this.source_?.request.mcRoot ?? '';
    const sourceVersion: string = this.source_?.request.versionId ?? '';
    if (!shouldProjectExportTask(task, sourceRoot, sourceVersion, this.requestedTaskId_, this.displayedTaskId_)) return;
    this.displayedTaskId_ = task.id;
    this.taskState_ = task.state;
    this.taskMessage_ = task.message;
    this.taskStage_ = task.stage;
    this.taskVersion_ = task.request.displayName || task.request.versionId;
    this.taskFormat_ = task.request.format;
    this.taskLauncher_ = task.request.launcher;
    this.taskPlatform_ = task.request.format === 'full' ?
      (task.request.platform.os === 'windows' ? 'Windows' : task.request.platform.os === 'linux' ? 'Linux' : 'macOS') +
        ' ' + task.request.platform.arch : '平台依赖由接收启动器安装';
    this.taskFiles_ = task.processedFiles;
    this.taskTotalFiles_ = task.totalFiles;
    this.taskBytes_ = task.processedBytes;
    this.taskTotalBytes_ = task.totalBytes;
    this.taskFilename_ = task.filename;
    this.taskSize_ = task.size;
    this.taskSha256_ = task.sha256;
    this.taskVerified_ = task.readbackVerified;
    // 阶段刷新不能把用户正在查看的“任务详情”弹回主层；进入任务只更新业务步骤。
    if (active) this.step_ = 2;
    // 真实终态会从进度页向结果页前进；详情子层仍留在原层，任务刷新不抢导航。
    if (this.step_ === 2 && this.layer_ === 'main') this.syncNavigation_(1);
  }

  /** 取消只是请求；“正在取消”持续到 SDK 压缩/写入真正结束，页面不自行宣布终态。 */
  private cancel_(): void {
    if (this.taskState_ !== 'running') return;
    getGameExportCoordinator().cancelTask();
    this.refreshTask_();
  }

  private activeTask_(): boolean { return this.taskState_ === 'running' || this.taskState_ === 'cancelling'; }
  private formatLabel_(format: string): string {
    if (format === 'modrinth') return 'Modrinth 标准整合包（.mrpack）';
    if (format === 'curseforge') return 'CurseForge 标准整合包（.zip）';
    return '完整游戏包（.zip）';
  }

  /** 汇总当前实际选择条目；目录、存档、普通文件分别仍保留独立数量和原始路径。 */
  private selectedEntryCount_(): number {
    return this.contentProjection_.selected;
  }

  /** 当前业务状态投影成唯一页 key；不会复制草稿、计划或后台任务。 */
  private navigationKey_(): string {
    if (this.layer_ === 'details') return 'details:' + this.detailsKind_;
    if (this.step_ === 2) return this.activeTask_() ? 'progress' : 'result';
    return this.step_ === 1 ? 'check' : 'settings';
  }

  /**
   * 先保留、挂载前后两页，再通过共用位移状态横滑；新层右进，返回左退。
   * 首帧和深链直接定位，避免生命周期尚未布局时动画。后台终态若恰逢翻页，
   * 等当前动画真正结束后再投影一次最新业务状态，不抢占当前转场或重挂任务 owner。
   */
  private syncNavigation_(direction: number, animated: boolean = true): void {
    const target: string = this.navigationKey_();
    if (target === this.navPage_) return;
    if (this.pageMotion_.moving) { this.navQueuedDirection_ = direction; return; }
    if (!this.navPages_.includes(target)) this.navPages_ = this.navPages_.concat([target]);
    if (!animated || !this.alive_ || this.pageMotion_.viewport <= 0) {
      this.navPage_ = target;
      this.navFrom_ = '';
      this.pageMotion_.reset(0);
      return;
    }
    this.navFrom_ = this.navPage_;
    this.navPage_ = target;
    this.navDirection_ = direction < 0 ? -1 : 1;
    this.pageMotion_.reset(0);
    this.pageMotion_.move(this.getUIContext(), this.navDirection_, (): void => {
      if (!this.alive_) return;
      this.navFrom_ = '';
      this.pageMotion_.reset(0);
      this.syncNavigation_(this.navQueuedDirection_);
    });
  }

  /** 收尾时目标页仍为 x=0；离场面板只隐藏，不销毁其 Scroll 和选项状态。 */
  private navigationOffset_(page: string): number {
    return this.navFrom_.length === 0 ? 0 : this.pageMotion_.offset(page === this.navPage_ ? this.navDirection_ : 0);
  }

  private editable_(): boolean { return this.loaded_ && this.scanState_ === 'ready' && !this.busy_ && !this.draftSaving_ && !this.pageMotion_.moving && !this.activeTask_(); }
  private selectionCount_(): string {
    if (this.contentTree_ === null) return '正在读取可导出内容';
    return '已选 ' + this.selectedEntryCount_() + ' / ' + this.contentProjection_.total + ' 个内容项';
  }
  /** 完整包的自定义标记只说明用户范围，不把必需运行闭包当可取消项。 */
  private contentPurpose_(): string {
    if (this.format_ !== 'full') return '标准整合包 · 游戏与官方资源由接收端安装';
    return this.contentProjection_.all
      ? '完整游戏包 · 全部可导出资料' : '完整游戏包 · 自定义内容';
  }
  /** 完整包保留 PCL；标准包 NeoForge/Quilt 的接收端限制与清单生成器保持一致。 */
  private pclAllowed_(): boolean {
    return this.format_ === 'full' || (this.loaderKind_ !== 'neoforge' && this.loaderKind_ !== 'quilt');
  }
  private chooseFormat_(format: string): void {
    if (!this.editable_() || this.format_ === format || this.contentTree_ === null) return;
    const previous: ExportRequest | null = this.request_();
    if (previous !== null) this.formatSelections_.set(this.selectionFamily_(), previous);
    this.format_ = format as ExportFormat;
    const current: ExportRequest = this.request_() as ExportRequest;
    const remembered: ExportRequest | undefined = this.formatSelections_.get(this.selectionFamily_());
    // 另一个格式族的选择也可能来自刷新前的树。恢复时重新对账并保留未知历史范围，
    // 不能无提示地隐藏旧世界/包；异常提示在changed_撤销旧资格之后发布，用户可恢复默认。
    const restored: ExportContentSelectionResult | undefined = remembered === undefined ? undefined :
      reconcileExportContentSelection(remembered, this.contentTree_);
    this.applySelection_(restored === undefined ? defaultExportContentSelection(current, this.contentTree_) : restored.request);
    // 发现问题属于当前库存，必须保留；旧选择问题只属于其格式族，不能跟随切换后仍显示。
    // 从不可变发现结果重建展示列表，恢复旧格式族时再附加本轮对账出的真实未知范围。
    this.sourceIssues_ = this.issueTexts_(this.source_ === null ? [] : this.source_.issues);
    if (restored !== undefined) this.sourceIssues_ = this.sourceIssues_.concat(this.issueTexts_(restored.issues));
    if (!this.pclAllowed_()) this.launcher_ = 'hmcl';
    this.formatSelections_.set(this.selectionFamily_(), this.request_() as ExportRequest);
    this.changed_();
    if (restored !== undefined && restored.issues.length > 0) this.notice_ = this.issueTexts_(restored.issues).join(' ');
  }
  /**
   * 由用户明确重置当前格式的内容范围。旧草稿中未发现的合法路径仍保守保留并给提示，
   * 此动作才允许改成当前库存的默认集合，避免隐藏历史范围没有可恢复的UI出口。
   */
  private resetContentSelection_(): void {
    if (!this.editable_() || this.contentTree_ === null) return;
    const request: ExportRequest | null = this.request_();
    if (request === null) return;
    this.applySelection_(defaultExportContentSelection(request, this.contentTree_));
    // 用户已明确放弃未知旧范围，移除对应的陈旧选择提示；共享目录、权限等发现问题仍保留。
    // 只更新显示事实，不绕过随后checkPlan对本次请求重新执行的独立检查。
    this.sourceIssues_ = this.issueTexts_(this.source_ === null ? [] : this.source_.issues);
    this.formatSelections_.set(this.selectionFamily_(), this.request_() as ExportRequest);
    this.changed_();
    this.notice_ = '已恢复当前格式的默认内容，请核对存档和共享目录后重新检查。';
  }
  private formatShort_(format: string): string {
    return format === 'full' ? '完整 ZIP' : format === 'modrinth' ? 'Modrinth' : 'CurseForge';
  }
  private receiverLabel_(): string {
    return (this.launcher_ === 'pcl' ? 'PCL' : 'HMCL') + (this.format_ === 'full' ? ' · Windows x64' : ' · 联网安装');
  }
  private taskReceiver_(): string {
    return (this.taskLauncher_ === 'pcl' ? 'PCL' : 'HMCL') +
      (this.taskFormat_ === 'full' ? ' · ' + this.taskPlatform_ : ' · 标准包安装');
  }
  /** 检查后的“包含什么”仅显示快照摘要；调整内容须回到设置，避免旧预览继续可执行。 */
  private openDetails_(kind: string): void {
    if (this.pageMotion_.moving) return;
    this.detailsKind_ = kind;
    this.layer_ = 'details';
    this.syncNavigation_(1);
  }

  /**
   * 页头返回只处理一层内部导航；任务层返回版本详情，后台任务仍由协调器持有。
   * 检查/Picker/保存是不可中断的 UI 事务，等待其返回后才允许销毁组件。
   */
  private requestBack_(): void {
    if (this.busy_ || this.savingLeave_ || this.draftSaving_ || this.pageMotion_.moving) { this.notice_ = '当前操作正在完成，请稍候。'; return; }
    if (this.showLeaveConfirm_) { this.showLeaveConfirm_ = false; return; }
    if (this.layer_ !== 'main') { this.layer_ = 'main'; this.syncNavigation_(-1); return; }
    if (this.step_ === 1) { this.step_ = 0; this.syncNavigation_(-1); return; }
    this.requestLeave_(false);
  }
  /** 关闭始终离开宿主；活动任务仅收起，草稿改动需要保存、放弃或继续编辑。 */
  private requestClose_(): void { this.requestLeave_(true); }
  private requestLeave_(close: boolean): void {
    if (this.busy_ || this.savingLeave_ || this.draftSaving_ || this.pageMotion_.moving) { this.notice_ = '当前操作正在完成，请稍候。'; return; }
    if (this.activeTask_() || !this.dirty_ || this.source_ === null) {
      if (close) this.onClose(); else this.onBack();
      return;
    }
    this.leaveToClose_ = close;
    this.showLeaveConfirm_ = true;
  }
  /** 放弃仅丢弃本次未保存的界面选择，不能删除其他已落盘草稿或已启动任务。 */
  private finishLeave_(): void {
    this.showLeaveConfirm_ = false;
    if (this.leaveToClose_) this.onClose(); else this.onBack();
  }
  private async saveAndLeave_(): Promise<void> {
    const generation: number = this.viewGeneration_;
    if (this.savingLeave_) return;
    this.savingLeave_ = true;
    try {
      if (await this.saveDraft_() && this.currentView_(generation)) this.finishLeave_();
    } finally { if (this.currentView_(generation)) this.savingLeave_ = false; }
  }
  /** 重试只回配置并废弃旧计划，不自动创建第二个任务或重复弹系统另存。 */
  private retry_(): void {
    if (this.busy_ || this.activeTask_()) return;
    this.preview_ = null;
    this.previewReady_ = false;
    this.layer_ = 'main';
    this.step_ = 0;
    this.syncNavigation_(-1);
    this.error_ = '';
    this.notice_ = '';
    if (!this.loaded_) this.initialize_();
  }
  private title_(): string {
    if (this.layer_ === 'details') return this.detailsKind_ === 'hash' ? '文件校验' :
      this.detailsKind_ === 'use' ? '在电脑端使用' : this.detailsKind_ === 'task' ? '任务详情' :
      this.detailsKind_ === 'result' ? '导出详情' : this.detailsKind_ === 'platform' ?
      (this.format_ === 'full' ? '电脑平台' : '安装方式') : '检查详情';
    if (this.step_ === 1) return '检查导出';
    if (this.step_ !== 2) return '导出游戏包';
    return this.activeTask_() ? (this.taskState_ === 'cancelling' ? '正在取消' : '正在导出') : '导出结果';
  }
  /** 只有协调器已进入的阶段才能标为完成；下载大小未知、校验与保存阶段不造百分比。 */
  private taskPhase_(): number {
    if (this.taskStage_ === '冻结输入') return 1;
    if (this.taskStage_ === '打包') return 2;
    if (this.taskStage_ === '校验归档') return 3;
    if (this.taskStage_ === '写入目标') return 4;
    return this.taskState_ === 'succeeded' ? 5 : 0;
  }
  private hasByteProgress_(): boolean {
    return this.taskState_ === 'running' && (this.taskStage_ === '冻结输入' || this.taskStage_ === '打包') && this.taskTotalBytes_ > 0;
  }
  private taskHeadline_(): string {
    if (this.taskState_ === 'succeeded') return this.taskVerified_ ? '已保存并验证' : '已保存，未回读';
    if (this.taskState_ === 'cancelled') return '导出已取消';
    return '导出未完成';
  }
  /** 已保存和已回读是不同事实；任何其他状态即使残留旧标志也不能显示验证绿色。 */
  private resultVerified_(): boolean { return this.taskState_ === 'succeeded' && this.taskVerified_; }

  /** 名称未知时使用通用标题，不从源实例名、exportId 或建议路径拼造实际目标名。 */
  private taskFilenameLabel_(): string { return this.taskFilename_ || '已保存的导出文件'; }

  private primaryLabel_(): string {
    if (this.layer_ !== 'main') return '返回';
    if (this.step_ === 2) return this.activeTask_() ? (this.taskState_ === 'cancelling' ? '收起任务' : '收起并继续') : this.taskState_ === 'succeeded' ? this.backLabel : '调整并重新检查';
    if (this.busy_) return this.step_ === 1 ? '正在打开另存…' : '正在检查文件…';
    return this.step_ === 1 ? (this.previewReady_ ? '另存并开始' : '返回调整选项') : '检查导出内容';
  }
  private primaryEnabled_(): boolean {
    if (this.busy_ || this.savingLeave_ || this.draftSaving_ || this.pageMotion_.moving) return false;
    return this.step_ === 2 || this.layer_ !== 'main' || (this.loaded_ && this.scanState_ === 'ready');
  }
  private primary_(): void {
    if (!this.primaryEnabled_()) return;
    if (this.layer_ !== 'main') { this.layer_ = 'main'; this.syncNavigation_(-1); return; }
    if (this.step_ === 2) {
      if (this.activeTask_() || this.taskState_ === 'succeeded') this.requestBack_();
      else this.retry_();
    } else if (this.step_ === 1) {
      if (this.previewReady_) this.start_(); else { this.step_ = 0; this.syncNavigation_(-1); }
    } else this.check_();
  }

  /** 内嵌导出的局部步骤标题；返回和关闭由唯一标题宿主执行原guard，不重复建按钮。 */
  @Builder
  Header() {
    // 父标题负责返回/关闭；局部步骤标题只投影当前导出层级，不伪装成系统标题栏。
    if (this.embeddedHeader && this.title_() !== '导出游戏包') {
      Text(this.title_()).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
        .width('100%').padding({ left: 20, right: 20, top: 4, bottom: 8 });
    } else {
      Column().height(0);
    }
  }

  /** 身份卡优先使用当前展示任务的固定身份，避免另一个版本的活动任务被当前标题冒充。 */
  @Builder
  Identity() {
    Row({ space: 12 }) {
      Row() { AppIcon({ name: AppIconName.ModPack, iconSize: 27, color: this.theme.primary }) }
        .width(44).height(44).borderRadius(14).backgroundColor(this.theme.primaryLight).justifyContent(FlexAlign.Center)
      Column({ space: 4 }) {
        Text(this.step_ === 2 ? this.taskVersion_ : (this.source_?.request.displayName || this.versionId_))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).width('100%')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.step_ === 2 ? this.formatShort_(this.taskFormat_) + ' · ' + this.taskReceiver_() :
          this.sourceSummary_ || '正在确认版本身份…')
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(12).borderRadius(18).backgroundColor(this.theme.bgCard)
  }

  @Builder
  Steps() {
    Row({ space: 6 }) {
      ForEach([0, 1, 2], (step: number) => {
        Row({ space: 6 }) {
          if (step < this.step_) {
            AppIcon({ name: AppIconName.Check, iconSize: 14, color: this.theme.successText })
          }
          Text((step < this.step_ ? '' : (step + 1) + '  ') + (step === 0 ? '设置' : step === 1 ? '检查' : '导出'))
            .fontSize(14).fontWeight(step === this.step_ ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(step === this.step_ ? this.theme.primary : this.theme.textSecondary)
        }.layoutWeight(1).height(34).justifyContent(FlexAlign.Center).borderRadius(12)
          .backgroundColor(step === this.step_ ? this.theme.primaryLight : Color.Transparent)
      }, (step: number): string => step.toString())
    }.width('100%')
  }

  /** 三个格式卡只均分单列的完整正文宽度；字体仅在小容器内做有下限的自适应。 */
  @Builder
  FormatCard(format: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 10 }) {
        Row() {
          AppIcon({ name: format === 'full' ? AppIconName.Save : format === 'modrinth' ? AppIconName.ModPack : AppIconName.LoaderNeoForge,
            iconSize: 22, color: this.format_ === format ? this.theme.primary : this.theme.textSecondary })
          Blank()
          if (this.format_ === format) AppIcon({ name: AppIconName.CheckCircle, iconSize: 14, color: this.theme.primary })
        }.width('100%')
        Text(this.formatShort_(format)).fontSize(14).minFontSize(12).maxFontSize(14)
          .fontWeight(this.format_ === format ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.format_ === format ? this.theme.primary : this.theme.textSecondary)
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
    }.layoutWeight(1).height(80).borderRadius(16)
      .backgroundColor(this.format_ === format ? this.theme.primaryLight : this.theme.bgCard)
      // border.radius 显式保留选中／未选中两态圆角，避免 border 重置先前 borderRadius。
      .border({ width: this.format_ === format ? 2 : 1, color: this.format_ === format ? this.theme.primary : this.theme.divider, radius: 16 })
      .enabled(this.editable_()).accessibilityText(this.formatLabel_(format) + (this.format_ === format ? '，已选中' : ''))
      .onClick(() => { this.chooseFormat_(format); })
  }

  /** 格式、接收端与平台保留原能力；内容分组直接接在设置中，草稿仍可手动保存。 */
  @Builder
  FormatSettings() {
    Column({ space: 12 }) {
      Row() {
        Text('导出格式').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.theme.textSecondary)
        Blank()
        Button() { AppIcon({ name: AppIconName.Save, iconSize: 20, color: this.theme.primary }) }
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('保存导出草稿')
          .enabled(this.editable_()).onClick(() => { this.saveDraft_(); })
      }.width('100%')
      Row({ space: 8 }) {
        this.FormatCard('full')
        this.FormatCard('modrinth')
        this.FormatCard('curseforge')
      }.width('100%')
      Text('接收启动器').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.theme.textSecondary)
        .width('100%').margin({ top: 4 })
      Row({ space: 4 }) {
        ForEach(['hmcl', 'pcl'], (launcher: string) => {
          Button({ type: ButtonType.Normal }) {
            Text(launcher === 'pcl' ? 'PCL 2' : 'HMCL').fontSize(16)
              .fontWeight(this.launcher_ === launcher ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.launcher_ === launcher ? this.theme.primary : this.theme.textSecondary)
          }.layoutWeight(1).height(44).borderRadius(12)
            .backgroundColor(this.launcher_ === launcher ? this.theme.bgCard : Color.Transparent)
            .opacity(launcher === 'pcl' && !this.pclAllowed_() ? 0.4 : 1)
            .enabled(this.editable_() && (launcher !== 'pcl' || this.pclAllowed_()))
            .onClick(() => { this.launcher_ = launcher as ExportLauncher; this.changed_(); })
        }, (launcher: string): string => launcher)
      }.width('100%').padding(3).borderRadius(14).backgroundColor(this.theme.bgInput)
      if (!this.pclAllowed_()) {
        Text('此加载器的标准包使用 HMCL。').fontSize(12).fontColor(this.theme.warningText).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 平台能力来自现有请求契约；信息子层说明固定 Windows x64，不提供后端不支持的选项。 */
  @Builder
  PlatformRow() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.Game, iconSize: 21, color: this.theme.textSecondary })
        Text(this.format_ === 'full' ? '电脑平台' : '安装方式').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary).layoutWeight(1)
        Text(this.format_ === 'full' ? 'Windows · x64' : '接收端联网安装').fontSize(14).fontColor(this.theme.textSecondary)
          .maxLines(2).textAlign(TextAlign.End)
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textSecondary })
      }.width('100%').padding(16)
    }.width('100%').constraintSize({ minHeight: 52 }).borderRadius(16).backgroundColor(this.theme.bgCard)
      .enabled(this.editable_()).onClick(() => { this.openDetails_('platform'); })
  }

  /**
   * 可展开分组直接位于设置正文。列表是本页唯一滚动owner；固定页头、Footer与原有
   * 横向页槽仍在外层，不在Scroll里嵌同向List。只有已展开节点进入LazyForEach。
   */
  @Builder
  Configuration() {
    List({ space: 10 }) {
      ListItem() {
        Column({ space: 14 }) {
          if (this.error_.length > 0) Text(this.error_).fontSize(13).fontColor(this.theme.errorText).width('100%')
          if (this.notice_.length > 0) Text(this.notice_).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
          this.FormatSettings()
          this.PlatformRow()
          this.ContentHeader()
          if (this.shared_) {
            Text('共享目录：选择范围来自当前实际游戏目录，可能包含其他版本共用资料，请逐组确认。')
              .fontSize(13).fontColor(this.theme.warningText).width('100%').padding(12)
              .backgroundColor(this.theme.warningBg).borderRadius(14)
          }
          ForEach(this.sourceIssues_, (message: string) => {
            Text(message).fontSize(12).fontColor(this.theme.warningText).width('100%')
          }, (message: string): string => message)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      LazyForEach(this.contentRows_, (row: ExportContentVisibleRow) => {
        ListItem() {
          if (row.group !== undefined) {
            this.ContentGroupRow({ group: row.group, depth: row.depth,
              expanded: this.expandedGroups_.includes(row.id), selection: this.contentGroupState_(row.group), editable: this.editable_() })
          } else if (row.item !== undefined) {
            this.ContentItemRow({ item: row.item, depth: row.depth, selected: this.contentItemSelected_(row.item), editable: this.editable_() })
          }
        }
      }, (row: ExportContentVisibleRow): string => row.id)
    }.width('100%').height('100%').cachedCount(8).scrollBar(BarState.Auto)
      .padding({ left: 20, right: 20, top: 2, bottom: 18 }).backgroundColor(this.theme.bgPrimary)
  }

  /** 扫描、真空类和读取错误是三种事实；重读保留当前选择，不以新默认覆盖已取消项。 */
  @Builder
  ContentHeader() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('导出内容').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).layoutWeight(1)
        if (this.scanState_ === 'loading') LoadingProgress().width(22).height(22).color(this.theme.primary)
        Button('恢复默认', { type: ButtonType.Normal })
          .height(44).padding({ left: 8, right: 8 }).fontSize(12).fontColor(this.theme.textSecondary)
          .backgroundColor(Color.Transparent).enabled(this.editable_())
          .onClick(() => { this.resetContentSelection_(); })
        Button(this.scanState_ === 'error' ? '重新读取' : '刷新', { type: ButtonType.Normal })
          .height(44).padding({ left: 12, right: 12 }).fontSize(14).fontColor(this.theme.primary)
          .backgroundColor(Color.Transparent).enabled(!this.busy_ && !this.activeTask_())
          .onClick(() => { this.initialize_(true); })
      }.width('100%')
      Text(this.scanState_ === 'loading' ? '正在读取内容，尚未确认空分类' : this.scanState_ === 'error'
        ? '内容读取失败，请重试；未将失败范围当作空目录。' : this.selectionCount_())
        .fontSize(13).fontColor(this.scanState_ === 'error' ? this.theme.errorText : this.theme.textSecondary).width('100%')
      Text(this.contentPurpose_()).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      Text(this.format_ === 'full' ? '本体、库和当前版本所需的官方资源自动包含，不能取消。' :
        '不携带本体、电脑依赖或官方 assets；资源包和光影包是独立可选内容。')
        .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 4 })
  }

  /** 父复选与展开是两个独立按钮；部分选中点复选变全选，展开不改草稿。 */
  @Builder
  ContentGroupRow(options: ExportContentGroupRowOptions) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Stack({ alignContent: Alignment.Center }) {
            if (options.selection === 'all' || options.selection === 'some') {
              AppIcon({ name: options.selection === 'some' ? AppIconName.Minus : AppIconName.Check,
                iconSize: 16, color: this.theme.textOnPrimary })
            }
          }.width(23).height(23).borderRadius(6)
            .backgroundColor(options.selection === 'none' ? Color.Transparent : this.theme.primary)
            .border({ width: 1.5, color: options.selection === 'none' ? this.theme.textHint : this.theme.primary, radius: 6 })
        }.width(44).height(44).backgroundColor(Color.Transparent)
          .enabled(options.editable && options.group.availability !== 'empty')
          .accessibilityRole(AccessibilityRoleType.CHECKBOX).accessibilityChecked(options.selection === 'all')
          .accessibilityText(options.group.label + (options.selection === 'all' ? '，全选，点按取消全部' :
            options.selection === 'some' ? '，部分选中，点按全选' : '，未选，点按全选'))
          .onClick(() => { this.selectNode_(options.group.id, options.selection !== 'all'); })
        Button({ type: ButtonType.Normal }) {
          Column({ space: 3 }) {
            Text(options.group.label).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).width('100%')
            Text(options.group.availability === 'empty' ? '暂无可导出内容' :
              this.contentGroupSelectedCount_(options.group) + ' / ' + this.contentGroupCount_(options.group) + ' 项' +
              (options.group.availability === 'error' ? ' · 存在读取问题' : ''))
              .fontSize(12).fontColor(options.group.availability === 'error' ? this.theme.warningText : this.theme.textSecondary).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent)
          .enabled(options.editable && options.group.availability !== 'empty')
          .accessibilityText((options.expanded ? '收起' : '展开') + options.group.label)
          .onClick(() => { this.toggleContentGroup_(options.group.id); })
        Button() {
          AppIcon({ name: options.expanded ? AppIconName.ChevronDown : AppIconName.ChevronRight,
            iconSize: 16, color: this.theme.textSecondary })
        }.width(44).height(44).backgroundColor(Color.Transparent)
          .enabled(options.editable && options.group.availability !== 'empty')
          .accessibilityText((options.expanded ? '收起' : '展开') + options.group.label)
          .onClick(() => { this.toggleContentGroup_(options.group.id); })
      }.width('100%')
      if (options.group.reason.length > 0) {
        Text(options.group.reason).fontSize(12).fontColor(this.theme.warningText).width('100%')
      } else if (options.group.description.length > 0 && options.expanded) {
        Text(options.group.description).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
      }
    }.width('100%').padding({ left: 8 + Math.min(options.depth, 3) * 14, right: 8, top: 5, bottom: 5 })
      .backgroundColor(this.theme.bgCard).borderRadius(14).opacity(options.group.availability === 'empty' ? 0.5 : 1)
  }

  /** 包/世界由选择契约作为原子项；读取失败项仍允许取消，不能被disabled锁成必选错误。 */
  @Builder
  ContentItemRow(options: ExportContentItemRowOptions) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(options.item.label).fontSize(14).fontColor(this.theme.textPrimary).width('100%').maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
        Text(options.item.path).fontSize(12).fontColor(this.theme.textSecondary).width('100%').copyOption(CopyOptions.LocalDevice)
        Text(options.item.reason.length > 0 ? options.item.reason : options.item.size === undefined
          ? '目录大小待统计' : exportSize(options.item.size)).fontSize(12)
          .fontColor(options.item.reason.length > 0 ? this.theme.warningText : this.theme.textSecondary).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Checkbox({ name: options.item.id }).select(options.selected).selectedColor(this.theme.primary)
        .width(22).height(22).enabled(options.editable).responseRegion({ x: -10, y: -10, width: 44, height: 44 })
        .accessibilityText(options.item.label + '，' + options.item.path + (options.item.reason.length > 0 ? '，读取存在问题，可取消排除' : ''))
        .onChange((selected: boolean): void => { this.selectNode_(options.item.id, selected); })
    }.width('100%').constraintSize({ minHeight: 64 })
      .padding({ left: 18 + Math.min(options.depth, 3) * 14, right: 18, top: 12, bottom: 12 })
      .borderRadius(14).backgroundColor(options.selected ? this.theme.primaryLight : this.theme.bgCard)
  }

  /** 检查卡只投影计划事实；压缩前字节不伪装成最终归档大小，未准备依赖不显示完成。 */
  @Builder
  Preview() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        AppIcon({ name: this.previewReady_ ? AppIconName.CheckCircle : AppIconName.Warning, iconSize: 32,
          color: this.previewReady_ ? this.theme.successText : this.theme.warningText })
        Column({ space: 5 }) {
          Text(this.previewReady_ ? '可以导出' : '需要处理').fontSize(21).fontWeight(FontWeight.Bold)
            .fontColor(this.previewReady_ ? this.theme.successText : this.theme.warningText).width('100%')
          Text(this.formatShort_(this.format_) + ' · ' + this.receiverLabel_()).fontSize(13)
            .fontColor(this.previewReady_ ? this.theme.successText : this.theme.warningText).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding(18).borderRadius(18)
        .backgroundColor(this.previewReady_ ? this.theme.successBg : this.theme.warningBg)
      Row({ space: 18 }) {
        Column({ space: 5 }) {
          Text(this.previewFiles_ + ' 项').fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
          Text('计划文件').fontSize(13).fontColor(this.theme.textSecondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Column({ space: 5 }) {
          Text(exportSize(this.previewBytes_)).fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
          Text('压缩前大小').fontSize(13).fontColor(this.theme.textSecondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding(18).borderRadius(16).backgroundColor(this.theme.bgCard)
      Row({ space: 12 }) {
        AppIcon({ name: AppIconName.Download, iconSize: 22,
          color: this.previewDownloads_ > 0 ? this.theme.warningText : this.theme.textSecondary })
        Text('电脑依赖').fontSize(16).fontColor(this.theme.textPrimary).layoutWeight(1)
        Text(this.previewDownloads_ > 0 ? '另存后准备' : this.format_ === 'full' ? '已就绪' : '接收端安装')
          .fontSize(14).fontColor(this.previewDownloads_ > 0 ? this.theme.warningText : this.theme.textSecondary)
      }.width('100%').padding(16).borderRadius(16)
        .backgroundColor(this.previewDownloads_ > 0 ? this.theme.warningBg : this.theme.bgCard)
      this.DetailRow(AppIconName.LayoutList, '检查详情', 'plan')
      if (this.previewIssues_.length > 0) {
        Text(this.previewIssues_[0]).fontSize(13).width('100%')
          .fontColor(this.previewReady_ ? this.theme.warningText : this.theme.errorText)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 实际阶段及实际计数投影；无法获得阶段总量时仅显示加载指示，不根据耗时补进度。 */
  @Builder
  TaskProgress() {
    Column({ space: 12 }) {
      Column({ space: 14 }) {
        Row({ space: 8 }) {
          Text(this.taskState_ === 'cancelling' ? '正在取消' : this.taskStage_ || '准备导出')
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).layoutWeight(1)
          LoadingProgress().width(23).height(23).color(this.theme.primary)
        }.width('100%')
        Text(exportSize(this.taskBytes_) + (this.hasByteProgress_() ? ' / ' + exportSize(this.taskTotalBytes_) : ' 已处理'))
          .fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).width('100%')
        if (this.hasByteProgress_()) {
          Progress({ value: Math.min(this.taskBytes_, this.taskTotalBytes_), total: this.taskTotalBytes_, type: ProgressType.Linear })
            .width('100%').color(this.theme.primary).backgroundColor(this.theme.bgInput)
        }
        Text('本阶段已处理 ' + this.taskFiles_ +
          (this.hasByteProgress_() ? ' / ' + this.taskTotalFiles_ : '') + ' 个文件')
          .fontSize(12).fontColor(this.theme.textSecondary).width('100%')
        if (this.taskState_ === 'cancelling') {
          Text('已请求取消，等待下载、文件写入或归档操作安全结束。').fontSize(13).fontColor(this.theme.warningText).width('100%')
        }
      }.width('100%').padding(17).backgroundColor(this.theme.bgCard).borderRadius(18)
      Column({ space: 20 }) {
        ForEach(['准备电脑文件', '生成稳定副本', '写入归档', '校验归档', '保存并读回'], (phase: string, index: number) => {
          Row({ space: 12 }) {
            AppIcon({ name: this.taskPhase_() > index ? AppIconName.CheckCircle : this.taskPhase_() === index ? AppIconName.Time : AppIconName.Hourglass,
              iconSize: 20, color: this.taskPhase_() > index ? this.theme.successText :
                this.taskPhase_() === index ? this.theme.primary : this.theme.textHint })
            Text(phase).fontSize(15).fontWeight(this.taskPhase_() === index ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.taskPhase_() === index ? this.theme.primary : this.theme.textPrimary).layoutWeight(1)
            if (this.taskPhase_() === index) Text(this.taskState_ === 'cancelling' ? '正在取消' : '进行中').fontSize(13).fontColor(this.theme.primary)
          }.width('100%')
        }, (phase: string): string => phase)
      }.width('100%').padding(17).backgroundColor(this.theme.bgCard).borderRadius(16)
      this.DetailRow(AppIconName.LayoutList, '任务详情', 'task')
      // 取消留在可滚动正文，足够触控高度；取消中禁止重复请求，底栏收起不改变 owner。
      Button(this.taskState_ === 'cancelling' ? '正在取消，等待安全结束…' : '取消导出', { type: ButtonType.Normal })
        .width('100%').height(48).borderRadius(14).backgroundColor(this.theme.bgCard).fontColor(this.theme.errorText)
        .enabled(!this.busy_ && this.taskState_ === 'running').onClick(() => { this.cancel_(); })
      Text(this.taskState_ === 'cancelling' ? '正在等待本次操作安全结束，可收起后查看结果。' : '收起后任务继续，可从版本详情或活动记录查看。')
        .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
    }.width('100%')
  }

  /** 成功卡只在已回读时用绿色；未知回读、失败、取消均保留实际状态和详细原因。 */
  @Builder
  TaskResult() {
    Column({ space: 16 }) {
      Column({ space: 12 }) {
        AppIcon({ name: this.resultVerified_() ? AppIconName.CheckCircle : AppIconName.Warning,
          iconSize: 42, color: this.resultVerified_() ? this.theme.successText : this.theme.warningText })
        Text(this.taskHeadline_()).fontSize(23).fontWeight(FontWeight.Bold)
          .fontColor(this.resultVerified_() ? this.theme.successText : this.theme.warningText)
          .width('100%').textAlign(TextAlign.Center)
        if (this.taskState_ === 'succeeded') {
          // 只显示提供方确认的实际文件名；未知名称不退回建议名。
          Text(this.taskFilenameLabel_()).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary)
            .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
          Text(this.taskSize_ > 0 ? exportSize(this.taskSize_) : '大小未确认').fontSize(14).fontColor(this.theme.textSecondary)
          if (!this.resultVerified_()) {
            Text('保存提供方未完成目标回读，归档摘要不能代替目标校验。').fontSize(13)
              .fontColor(this.theme.warningText).width('100%').textAlign(TextAlign.Center)
          }
        } else {
          Text(this.taskMessage_).fontSize(14).fontColor(this.theme.warningText).width('100%').textAlign(TextAlign.Center)
        }
      }.width('100%').padding(22).borderRadius(20)
        .backgroundColor(this.resultVerified_() ? this.theme.successBg : this.theme.warningBg)
      this.DetailRow(AppIconName.Document, this.taskState_ === 'succeeded' ? '导出详情' : '错误详情',
        this.taskState_ === 'succeeded' ? 'result' : 'task')
      if (this.taskState_ === 'succeeded') {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            AppIcon({ name: AppIconName.Refresh, iconSize: 20, color: this.theme.primary })
            Text('再次导出').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.primary)
          }.justifyContent(FlexAlign.Center)
        }.width('100%').height(48).borderRadius(16).backgroundColor(this.theme.bgCard)
          .enabled(!this.busy_).onClick(() => { this.retry_(); })
      } else {
        Button(this.backLabel, { type: ButtonType.Normal }).width('100%').height(44).borderRadius(14)
          .backgroundColor(this.theme.bgCard).fontColor(this.theme.primary).onClick(() => { this.requestBack_(); })
      }
    }.width('100%')
  }


  @Builder
  DetailRow(icon: AppIconName, title: string, kind: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        AppIcon({ name: icon, iconSize: 21, color: this.theme.textSecondary })
        Text(title).fontSize(15).fontColor(this.theme.textPrimary).layoutWeight(1)
        Text(kind === 'hash' ? 'SHA-256' : kind === 'use' ? (this.taskLauncher_ === 'pcl' ? 'PCL' : 'HMCL') :
          kind === 'plan' || kind === 'result' ? '查看' : this.taskStage_)
          .fontSize(13).fontColor(this.theme.textSecondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 140 })
        AppIcon({ name: AppIconName.ChevronRight, iconSize: 14, color: this.theme.textSecondary })
      }.width('100%').padding(15)
    }.width('100%').backgroundColor(this.theme.bgCard).borderRadius(14).onClick(() => { this.openDetails_(kind); })
  }
  /** 详细说明仍在同一 Sheet 内，返回只弹回当前检查或任务结果。 */
  @Builder
  Details(kind: string) {
    Column({ space: 12 }) {
      if (kind === 'platform') {
        Text(this.format_ === 'full' ? 'Windows · x64' : '接收启动器联网安装').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary).width('100%')
        Text(this.format_ === 'full' ? '当前完整包导出目标为 Windows x64。平台不改变源实例或本机运行配置。' :
          '标准整合包不固定电脑平台，游戏与加载器由所选启动器联网安装。')
          .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
      } else if (kind === 'result') {
        Text(this.taskHeadline_()).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(this.resultVerified_() ? this.theme.successText : this.theme.warningText).width('100%')
        Text(this.taskFilename_ || '保存提供方未返回可确认的文件名').fontSize(15).fontColor(this.theme.textPrimary).width('100%')
        Text(this.taskReceiver_()).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        Text('SHA-256').fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        Text(this.taskSha256_ || '未取得摘要').fontSize(13).fontColor(this.theme.textPrimary).width('100%').copyOption(CopyOptions.LocalDevice)
        Text(this.resultVerified_() ? '以上摘要与目标文件读回结果一致。' : '以上摘要属于生成归档，不能证明保存位置中的目标文件一致。')
          .fontSize(13).fontColor(this.resultVerified_() ? this.theme.textSecondary : this.theme.warningText).width('100%')
        Text('使用 ' + (this.taskLauncher_ === 'pcl' ? 'PCL' : 'HMCL') + ' 导入').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary).width('100%')
        Text(this.taskFormat_ === 'full' ? '解压到电脑上的新目录，在启动器中添加其中的 .minecraft 游戏目录，并确认版本隔离。' :
          '在所选启动器的整合包安装入口导入归档，保持联网以安装游戏、加载器和清单资源。')
          .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        Text('电脑端仍需合适的 Java 和自己的游戏账户；请在文件管理器查看所选保存位置。')
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      } else if (kind === 'hash') {
        Text(this.resultVerified_() ? '目标回读校验通过' : '已保存，目标未回读验证').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.resultVerified_() ? this.theme.successText : this.theme.warningText).width('100%')
        Text('SHA-256').fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        Text(this.taskSha256_ || '未取得摘要').fontSize(13).fontColor(this.theme.textPrimary).width('100%').copyOption(CopyOptions.LocalDevice)
        Text(this.resultVerified_() ? '以上摘要与目标文件读回结果一致。' : '以上摘要属于生成归档，不能证明保存提供方中的目标文件一致。')
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      } else if (kind === 'use') {
        Text('使用 ' + (this.taskLauncher_ === 'pcl' ? 'PCL' : 'HMCL') + ' 导入').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).width('100%')
        Text(this.taskFormat_ === 'full' ? '将完整游戏包解压到电脑上的新目录，在启动器中添加其中的 .minecraft 游戏目录，并确认版本隔离。' :
          '在所选启动器的整合包安装入口导入归档，保持联网以安装游戏、加载器和清单资源。')
          .fontSize(14).fontColor(this.theme.textPrimary).width('100%')
        Text('电脑端仍需安装合适的 Java，并使用自己的游戏账户。归档中附有使用说明；请在文件管理器中查看刚才选择的保存位置。')
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      } else if (kind === 'task') {
        Text(this.taskStage_).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).width('100%')
        Text(this.taskMessage_).fontSize(14).fontColor(this.theme.textSecondary).width('100%').copyOption(CopyOptions.LocalDevice)
        Text('本阶段已处理 ' + this.taskFiles_ + ' / ' + this.taskTotalFiles_ + ' 个文件 · ' + exportSize(this.taskBytes_))
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        Text('计数来自协调器实际回调，进入新阶段时从零开始；压缩或校验没有细进度时只展示阶段。')
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      } else {
        Text(this.formatLabel_(this.format_)).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).width('100%')
        Text(this.receiverLabel_()).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        Text(this.selectionCount_()).fontSize(14).fontColor(this.theme.textPrimary).width('100%')
        Text('临时空间 ' + exportSize(this.previewTempBytes_) + ' · 需准备 ' + this.previewDownloads_ + ' 项 / ' + exportSize(this.previewDownloadBytes_))
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        ForEach(this.previewIssues_, (message: string) => {
          Text(message).fontSize(13).fontColor(this.previewReady_ ? this.theme.warningText : this.theme.errorText).width('100%')
        }, (message: string): string => 'issue:' + message)
        ForEach(this.selectedDirectories_, (path: string) => {
          Text('文件夹 · ' + contentLabel(path) + ' (' + path + ')').fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        }, (path: string): string => 'directory:' + path)
        ForEach(this.selectedWorlds_, (path: string) => {
          Text('存档 · ' + path).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        }, (path: string): string => 'world:' + path)
        ForEach(this.selectedFiles_, (path: string) => {
          Text('文件 · ' + contentLabel(path)).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        }, (path: string): string => 'file:' + path)
        ForEach(this.previewSummary_, (message: string) => {
          Text(message).fontSize(13).fontColor(this.theme.textSecondary).width('100%')
        }, (message: string): string => message)
        Text('不包含 OHOS 运行槽、JDK、账户与认证信息、AMCL 控制记录及安装中间文件。')
          .fontSize(13).fontColor(this.theme.textSecondary).width('100%')
      }
    }.width('100%').padding(16).backgroundColor(this.theme.bgCard).borderRadius(16).alignItems(HorizontalAlign.Start)
  }

  /** R4 底栏只有一个主行动；取消、再次导出等次行动放在可滚动正文。 */
  @Builder
  PrimaryButton() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        AppIcon({ name: this.layer_ === 'content' ? AppIconName.Check : this.layer_ === 'details' ? AppIconName.Back :
          this.step_ === 2 ? (this.activeTask_() ? AppIconName.ChevronDown : AppIconName.Back) :
            this.step_ === 1 ? AppIconName.Save : AppIconName.CheckCircle, iconSize: 20, color: this.theme.textOnPrimary })
        Text(this.primaryLabel_()).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.textOnPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.justifyContent(FlexAlign.Center)
    }.width('100%').height(48).borderRadius(16).backgroundColor(this.theme.primary)
      .enabled(this.primaryEnabled_()).onClick(() => { this.primary_(); })
  }

  @Builder
  Footer() {
    Column() { this.PrimaryButton() }
      .width('100%').padding({ left: 20, right: 20, top: 16, bottom: Math.max(16, this.bottomSafe_) })
      .backgroundColor(this.theme.bgCard).flexShrink(0)
  }

  /** 草稿确认在同一 Sheet 叠层内完成；遮罩和系统关闭再次进入时也不会绕过确认。 */
  @Builder
  LeaveConfirmation() {
    Column() {
      // 矮窗口或放大字体时确认内容独立滚动，保存/放弃/继续均可触达。
      Scroll() {
        Column({ space: 14 }) {
        Text('保留这次选择？').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.theme.textPrimary).width('100%')
        Text('返回前保存当前选项，下次进入可以继续；检查结果仍需重新生成。')
          .fontSize(14).fontColor(this.theme.textSecondary).width('100%')
        Button(this.savingLeave_ ? '正在保存…' : '保存草稿并离开').width('100%').height(46)
          .backgroundColor(this.theme.primary).fontColor(this.theme.textOnPrimary).enabled(!this.savingLeave_)
          .onClick(() => { this.saveAndLeave_(); })
        Button('放弃本次修改').width('100%').height(44).backgroundColor(this.theme.bgInput).fontColor(this.theme.textPrimary)
          .enabled(!this.savingLeave_).onClick(() => { this.finishLeave_(); })
        Button('继续编辑').width('100%').height(44).backgroundColor(Color.Transparent).fontColor(this.theme.primary)
          .enabled(!this.savingLeave_).onClick(() => { this.showLeaveConfirm_ = false; })
        if (this.error_.length > 0) Text(this.error_).fontSize(13).fontColor(this.theme.errorText).width('100%')
        }.width('100%').padding(22).backgroundColor(this.theme.bgCard).borderRadius(22)
      }.width('100%').constraintSize({ maxWidth: 420, maxHeight: '90%' }).scrollBar(BarState.Auto).borderRadius(22)
    }.width('100%').height('100%').padding(20).justifyContent(FlexAlign.Center).backgroundColor($r('sys.color.mask_tertiary'))
      .onClick(() => {})
  }

  /**
   * 每个已访问 key 保留独立 Scroll。前后页同时存在且真正横移；页头、身份和底部行动
   * 固定在正文视口外，正文单列限宽和原 safe-area padding 均由原布局继续负责。
   */
  @Builder
  NavigationPage(page: string) {
    if (page === 'settings' && this.loaded_) {
      this.Configuration()
    } else {
    Scroll() {
      Column({ space: 14 }) {
        if (this.error_.length > 0) Text(this.error_).fontSize(13).fontColor(this.theme.errorText).width('100%')
        if (this.step_ !== 2 && page !== 'progress' && page !== 'result' && this.notice_.length > 0) {
          Text(this.notice_).fontSize(12).fontColor(this.theme.textSecondary).width('100%')
        }
        if (page.startsWith('details:')) {
          this.Details(page.substring('details:'.length))
        } else if (page === 'progress') {
          this.TaskProgress()
        } else if (page === 'result') {
          this.TaskResult()
        } else if (!this.loaded_) {
          if (this.busy_) {
            LoadingProgress().width(32).height(32).color(this.theme.primary)
            Text('正在盘点源实例…').fontSize(14).fontColor(this.theme.textSecondary)
          } else {
            Button('重新读取').width('100%').height(48).onClick(() => { this.initialize_(); })
          }
        } else if (page === 'check') {
          this.Preview()
        } else {
          Text('正在同步导出状态…').fontSize(14).fontColor(this.theme.textSecondary)
        }
      }.width('100%').padding({ left: 20, right: 20, top: 2, bottom: 18 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto).align(Alignment.Top)
      .backgroundColor(this.theme.bgPrimary)
    }
  }

  /** 固定页头／身份／步骤和唯一 footer 包围横向正文视口；所有宽度仍单列。 */
  build() {
    if (this.embeddedHeader) {
      this.ExportBody_();
    } else {
      ImmersiveTitleScaffold({ title: this.title_(), theme: this.theme, modal: false, showClose: true,
        surfaceColor: this.theme.bgPrimary, backLabel: this.backLabel, closeLabel: '关闭导出',
        backId: 'game-export-back', closeId: 'game-export-close',
        backEnabled: !this.busy_ && !this.savingLeave_ && !this.draftSaving_ && !this.pageMotion_.moving,
        closeEnabled: !this.busy_ && !this.savingLeave_ && !this.draftSaving_ && !this.pageMotion_.moving,
        onBack: (): void => { this.requestBack_(); }, onClose: (): void => { this.requestClose_(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }
  }

  /** 原面板正文与覆盖层保持原组件所有权，宿主只接管导航动作。 */
  @Builder
  private ExportBody_() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 0 }) {
        this.Header()
        Column({ space: 8 }) {
          this.Identity()
          if (this.layer_ === 'main' && (this.step_ !== 2 || this.activeTask_())) this.Steps()
        }.width('100%').padding({ left: 20, right: 20, bottom: 12 }).flexShrink(0)
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.navPages_, (page: string) => {
            Column() { this.NavigationPage(page) }
              .width('100%').height('100%')
              .translate({ x: this.navigationOffset_(page) })
              .visibility(page === this.navPage_ || page === this.navFrom_ ? Visibility.Visible : Visibility.Hidden)
              .enabled(page === this.navPage_ && !this.pageMotion_.moving)
          }, (page: string): string => page)
        }.width('100%').layoutWeight(1).clip(true)
          .onAreaChange((_, area) => { this.pageMotion_.resize(area.width as number); })
        this.Footer()
      }.width('100%').constraintSize({ maxWidth: 600 }).height('100%').backgroundColor(this.theme.bgPrimary)
      if (this.showLeaveConfirm_) this.LeaveConfirmation()
    }.width('100%').height('100%').backgroundColor(this.theme.bgPrimary)

  }

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
        this.ExportBody_();
      }
}

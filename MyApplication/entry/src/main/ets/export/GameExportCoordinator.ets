/**
 * 所有产品共用的游戏包导出 owner。页面只持有草稿和投影；固定请求、补文件、冻结、
 * ZIP 校验及目标确认由本单例串行管理。重开页面不会创建第二个任务或丢失取消请求。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker, statfs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AtomicFileWriter, resolveInstanceGameDir, AppLogger } from 'commons';
import { ExportRequest, ExportIssue, ExportVersionSource, ExportResolvedVersion, ExportInventoryFile,
  ExportDependency, ExportPlannedFile, ExportFilePlanResult, ExportVersionResolver, DesktopDependencyPlanner,
  ExportFilePlan, exportHasErrors, DownloadManager, DownloadFileSpec, DownloadTaskView, DownloadTaskRegistry, compileDownloadFiles,
  buildMavenArtifactUrls, artifactSidecarUrl, shouldUseBmclapiFirst,
  safeBaseName, safeRelPath, claimVersionInstall, isTerminalState, UnifiedTaskView, ExportPlatform,
  ActivityRecord, ActivityCategory, getDownloadHistoryStore, ExportPath, ExportLoaderKind, ProcessActivityCoordinator,
  ExportContentTree, defaultExportContentSelection, exportContentSelectionIssues } from 'feature_core';
import testNapi from 'libentry.so';
import { exportPathExists, assertExportPath, readExportText, readExportVersions, discoverExportContentTree,
  validateExportRequest, inventoryExportContent, inspectExportDependency, selectExportDependencySources, ExportCheckDigestContext,
  exportIssue } from './ExportSourceInspector';
import { hashExportFile, writeExportArchive, verifyExportArchive, copyExportArchiveToUri } from './ExportArchiveIO';
import { prepareForgelikeExport, ExportDependencyCandidates } from './ExportForgelikePreparation';
import { ExportPreparationDownloadTask } from './ExportPreparationDownloadTask';
import { ensureExportDirectory } from './ExportDirectory';
import { ExportNativeContext } from './ExportNativeArchive';

/** 源身份与实际可选择内容；没有账号或 OHOS JDK 也可执行这份只读检查。 */
export interface ExportSourceView {
  request: ExportRequest; worlds: string[]; directories: string[]; files: string[];
  sharedGameDir: boolean; issues: ExportIssue[]; summary: string;
  /** 同一源发现的层级模型；UI只投影此树，具体选择仍由纯规则和冻结请求决定。 */
  contentTree: ExportContentTree;
  /** 界面兼容提示读取解析器的结构化身份，不从版本名或可翻译的摘要文案反推加载器。 */
  loaderKind: ExportLoaderKind;
}
/** id 绑定 owner 内部的不可变计划；UI 不能用修改后的请求复用旧预览资格。 */
export interface ExportPreview {
  id: string; request: ExportRequest; issues: ExportIssue[]; files: number; totalBytes: number;
  tempBytes: number; downloads: number; downloadBytes: number; summary: string[];
}
/** 成功只在目标关闭及 SHA256 读回完成之后发布；stage 是可测阶段而不是虚构百分比。 */
export interface ExportTaskView {
  id: string; request: ExportRequest; stage: string;
  state: 'running' | 'cancelling' | 'cancelled' | 'failed' | 'succeeded';
  message: string; processedFiles: number; totalFiles: number; processedBytes: number; totalBytes: number;
  /** 新任务为Picker确认的实际名，不支持查询则空；旧schema1记录保留原字段，可能仍为旧建议名。 */
  filename: string; size: number; sha256: string; readbackVerified: boolean;
}
interface CheckedExport {
  preview: ExportPreview; versions: ExportVersionSource[]; resolved: ExportResolvedVersion;
  inventory: ExportInventoryFile[]; dependencies: ExportDependency[]; missing: ExportDependency[];
  plan: ExportFilePlanResult;
  /** 保留只读预览时使用的同一资产清单；安装器准备后重算闭包不重新读取可变化的源。 */
  assetIndexJson: string;
}
interface ExportStoredTask { schemaVersion: number; updatedAt: number; view: ExportTaskView; }
interface ExportDraft { key: string; request: ExportRequest; }
interface ExportOwner { id: string; schemaVersion: number; }

/** JSON 深复制只用于明确的公共模型，调用者后续勾选不能改变已执行任务的范围。 */
function copyRequest(value: ExportRequest): ExportRequest { return JSON.parse(JSON.stringify(value)) as ExportRequest; }
function checkCancelled(cancelled: () => boolean): void { if (cancelled()) throw new Error('已请求取消'); }
/** 所有私有工作目录共用真实FileIO收敛和EEXIST复核，错误包含实际目录与操作。 */
async function makeDirectory(path: string, trustedRoot: string): Promise<void> { await ensureExportDirectory(path, trustedRoot); }
function parentPath(path: string): string { return path.substring(0, path.lastIndexOf('/')); }

/** 小型任务/草稿使用现有 durable 原子写入器；大文件从不进入该同步 JSON 路径。 */
async function savePrivateJson(path: string, value: Object, trustedRoot: string): Promise<void> {
  await makeDirectory(parentPath(path), trustedRoot);
  AtomicFileWriter.write(path, JSON.stringify(value));
}
/** 只核对草稿容器与记录形状；具体请求仍由读取方按当前源逐项验证，过期源不在保存时被删除。 */
function parseDraftRecords(text: string): ExportDraft[] {
  const records = JSON.parse(text) as ExportDraft[];
  if (!Array.isArray(records) || records.some((entry: ExportDraft): boolean => entry === null ||
    typeof entry !== 'object' || typeof entry.key !== 'string' || entry.request === null ||
    typeof entry.request !== 'object')) throw new Error('导出草稿记录格式无效');
  return records;
}
/**
 * 损坏草稿仅在用户明确保存新选择时隔离。复制原始文件字节而非重新编码JSON，并比较复制前、
 * 副本和复制后的SHA256/长度，并同步副本与目录；备份未确认前不得覆盖旧文件。
 * 隔离副本留在私有区供恢复。
 * @throws 复制、身份核验或同步失败向保存调用方传播，原草稿保持原位。
 */
async function quarantineDraft(path: string, trustedRoot: string): Promise<void> {
  const directory = parentPath(path) + '/quarantine';
  await makeDirectory(directory, trustedRoot);
  const backup = directory + '/drafts-invalid-' + Date.now() + '-' + util.generateRandomUUID() + '.json';
  const before = await hashExportFile(path, (): boolean => false);
  await fs.copyFile(path, backup);
  const copiedFile = await fs.open(backup, fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
  try { await fs.fsync(copiedFile.fd); } finally { await fs.close(copiedFile); }
  const copied = await hashExportFile(backup, (): boolean => false);
  const after = await hashExportFile(path, (): boolean => false);
  if (before.sha256 !== copied.sha256 || before.sha256 !== after.sha256 || before.size !== copied.size) {
    throw new Error('旧导出草稿隔离备份未能确认，原件已保留，请重试');
  }
  const parent = await fs.open(directory, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { await fs.fsync(parent.fd); } finally { await fs.close(parent); }
}
/** 只清已取得 owner 的独占树，拒绝链接；取消必须先等 Native 和 FileIO 结束才能调用。 */
async function removeOwnedTree(root: string): Promise<void> {
  if (!(await exportPathExists(root))) return;
  const stat = await fs.lstat(root);
  if (stat.isSymbolicLink()) throw new Error('工作目录身份变化，保留现场');
  if (!stat.isDirectory()) { await fs.unlink(root); return; }
  for (const name of await fs.listFile(root)) {
    if (safeBaseName(name) !== name) throw new Error('工作目录含无效名称，保留现场');
    await removeOwnedTree(root + '/' + name);
  }
  await fs.rmdir(root);
}

export class GameExportCoordinator {
  private context_: common.UIAbilityContext | undefined = undefined;
  private task_: ExportTaskView | null = null;
  private listeners_: (() => void)[] = [];
  private previews_: Map<string, CheckedExport> = new Map();
  private cancelRequested_: boolean = false;
  private choosing_: boolean = false;
  /** 原导出owner持有本轮所有Native ID；可见终态不删除，必须purge成功才移除。 */
  private downloadIds_: Set<number> = new Set<number>();
  /** 当前导出准备的统一队列owner；只排除这一个明确ID，不忽略其他导出/安装任务。 */
  private preparation_: ExportPreparationDownloadTask | null = null;
  /** 包括终态记录/清理的整段 Promise；展示终态不代表 owner 的 finally 已经收口。 */
  private execution_: Promise<void> | undefined = undefined;
  private recovered_: boolean = false;
  private draftTail_: Promise<void> = Promise.resolve();
  /** 历史记录恢复只拥有本次展示代次；新恢复请求或另存预约都会撤销旧异步读取的发布权。 */
  private restoreGeneration_: number = 0;

  /** 恢复由启动器 owner 调用；仅发现任务记录，不自动下载、压缩或重用已失效的目标授权。 */
  async recover(context: common.UIAbilityContext): Promise<void> {
    this.context_ = context;
    if (this.recovered_) return;
    this.recovered_ = true;
    const records = context.filesDir + '/game-export/records';
    if (!(await exportPathExists(records))) return;
    await assertExportPath(records);
    let latest: ExportStoredTask | undefined = undefined;
    for (const name of (await fs.listFile(records)).sort().reverse().slice(0, 100)) {
      if (!/^[0-9]+-[a-zA-Z0-9-]+\.json$/.test(name)) continue;
      try {
        const raw = await readExportText(records, name);
        const record = JSON.parse(raw) as ExportStoredTask;
        if (record.schemaVersion !== 1 || record.view === undefined || name !== record.view.id + '.json' ||
          typeof record.updatedAt !== 'number' || record.view.request === undefined) continue;
        if (latest === undefined || record.updatedAt > latest.updatedAt) latest = record;
      } catch (_) { /* 损坏记录保留原件，不据其删除任何目录或发起工作。 */ }
    }
    if (latest !== undefined && this.task_ === null) {
      this.task_ = latest.view;
      if (this.task_.state === 'running' || this.task_.state === 'cancelling') {
        this.task_.state = 'failed'; this.task_.stage = '任务中断';
        this.task_.message = '上次进程已结束，原任务材料保留；请重新检查并选择保存位置。目标可能有半成品。';
        await this.persistTask();
      }
      this.changed();
    }
  }

  /** 页面在 Ability 初始化完成后也可幂等获取 owner；缺少上下文时不偷偷选择其他沙箱。 */
  private context(): common.UIAbilityContext {
    const context = this.context_ ?? AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (context === undefined) throw new Error('应用上下文尚未就绪，请返回后重试');
    this.context_ = context; return context;
  }
  getTask(): ExportTaskView | null {
    return this.task_ === null ? null : JSON.parse(JSON.stringify(this.task_)) as ExportTaskView;
  }
  /** 活动列表只读重入指定记录；不得替换正在执行的 owner，也不自动重用目标授权。 */
  async restoreTask(taskId: string): Promise<boolean> {
    if (!/^[0-9]+-[a-zA-Z0-9-]+$/.test(taskId)) throw new Error('导出任务身份无效');
    const generation = ++this.restoreGeneration_;
    if (this.active() || this.execution_ !== undefined || this.choosing_) return this.task_?.id === taskId;
    const root = this.context().filesDir + '/game-export/records';
    if (!(await exportPathExists(root + '/' + taskId + '.json'))) return false;
    const text = await readExportText(root, taskId + '.json');
    // 文件读取会让出执行权。历史页离开后，用户可能已在另一页预约/执行新任务；旧结果
    // 此时只能返回当前身份是否匹配，绝不能替换真实owner或把后续阶段写进历史记录。
    if (generation !== this.restoreGeneration_ || this.active() || this.execution_ !== undefined || this.choosing_) {
      return this.task_?.id === taskId;
    }
    const record = JSON.parse(text) as ExportStoredTask;
    if (record.schemaVersion !== 1 || record.view?.id !== taskId || record.view.request === undefined) throw new Error('导出记录身份不一致');
    if (record.view.state === 'running' || record.view.state === 'cancelling') {
      record.view.state = 'failed'; record.view.stage = '任务中断';
      record.view.message = '原进程已结束，请重新检查并选择保存位置；目标可能有半成品。';
    }
    this.task_ = record.view; this.changed(); return true;
  }
  subscribe(listener: () => void): () => void {
    this.listeners_.push(listener);
    return (): void => { this.listeners_ = this.listeners_.filter((item: () => void): boolean => item !== listener); };
  }
  private changed(): void { for (const listener of this.listeners_.slice()) { try { listener(); } catch (_) { /* 一个离开的页面不终止任务。 */ } } }
  private active(): boolean { return this.task_ !== null && (this.task_.state === 'running' || this.task_.state === 'cancelling'); }
  private async persistTask(): Promise<void> {
    if (this.task_ === null) return;
    const record: ExportStoredTask = { schemaVersion: 1, updatedAt: Date.now(), view: this.getTask() as ExportTaskView };
    await savePrivateJson(this.context().filesDir + '/game-export/records/' + this.task_.id + '.json', record, this.context().filesDir);
  }
  private async stage(label: string, message: string): Promise<void> {
    if (this.task_ === null) throw new Error('导出任务已失去 owner');
    this.task_.stage = label; this.task_.message = message;
    this.task_.processedBytes = 0; this.task_.processedFiles = 0;
    await this.persistTask(); this.changed();
  }

  /** 忙碌判断保守覆盖等待/暂停/安装结账以及两个游戏进程，未知 Native 状态同样阻断。 */
  private async assertSourceIdle(request: ExportRequest): Promise<void> {
    const context = this.context();
    if (testNapi.mcIsRunning() || testNapi.desktopGameProcessState(context.filesDir, 0) !== 0) {
      throw new Error('请结束现有游戏会话后再检查或导出');
    }
    if (DownloadTaskRegistry.instance().listAll().some((view: UnifiedTaskView): boolean =>
      (this.preparation_ === null || view.id !== this.preparation_.view.id) && !isTerminalState(view.state)) ||
      DownloadManager.instance().getTasks().some((view: DownloadTaskView): boolean =>
        !this.downloadIds_.has(view.taskId) && ['Finished', 'Failed', 'Aborted'].indexOf(view.state) < 0)) {
      throw new Error('下载、等待、暂停或资源安装尚未结束，请先完成或取消这些任务');
    }
    for (const base of [request.mcRoot + '/versions/' + request.versionId, request.gameDir]) {
      for (const marker of ['.amcl-mc-pending.json', '.amcl-modpack-pending.json']) {
        if (await exportPathExists(base + '/' + marker)) throw new Error('该实例仍有未完成安装意图，请先恢复或处理下载');
      }
    }
    const recovery = context.filesDir + '/mc-install-work';
    if (await exportPathExists(recovery)) {
      await assertExportPath(recovery);
      for (const name of await fs.listFile(recovery)) {
        if (!name.endsWith('.json')) continue;
        const record = JSON.parse(await readExportText(recovery, name)) as Record<string, Object>;
        if (record['mcDir'] === request.mcRoot && record['complete'] === false) {
          throw new Error('游戏目录存在未结账的安装任务，请先处理下载恢复');
        }
      }
    }
  }

  async inspectSource(mcRoot: string, versionId: string, versionIsolation: boolean): Promise<ExportSourceView> {
    const root = mcRoot.replace(/\/+$/, '');
    const gameDir = resolveInstanceGameDir(root, versionId, versionIsolation);
    const platform: ExportPlatform = { os: 'windows', arch: 'x64', version: '' };
    const request: ExportRequest = { mcRoot: root, versionId, gameDir, exportId: versionId, displayName: versionId,
      format: 'full', launcher: 'pcl', platform,
      includeDirectories: [], includeFiles: [], selectedWorlds: [], sharedGameDir: gameDir === root };
    const issues: ExportIssue[] = [];
    await validateExportRequest(request);
    try { await this.assertSourceIdle(request); } catch (error) { issues.push(exportIssue('SOURCE_BUSY', (error as Error).message)); }
    const sources = await readExportVersions(root, versionId);
    const resolved = ExportVersionResolver.resolve(versionId, sources);
    issues.push(...resolved.issues);
    // 只发现内容名称和基础元数据，不为展示勾选树先读取assets正文。
    // 完整包默认全部可导出资料；旧草稿是否恢复由读取方保留原选择，不能在此覆盖。
    const contentTree = await discoverExportContentTree(request);
    issues.push(...contentTree.issues);
    const defaults = defaultExportContentSelection(request, contentTree);
    if (request.sharedGameDir) issues.push(exportIssue('SHARED_CONTENT',
      '这些内容由多个版本共用，完整范围可能包含其他版本资料，请核对所选目录和存档。', '', true));
    return { request: defaults, worlds: contentTree.worlds, directories: contentTree.directories, files: contentTree.files,
      contentTree, sharedGameDir: request.sharedGameDir, issues, loaderKind: resolved.loader.kind,
      summary: 'Minecraft ' + resolved.vanillaVersion + ' · ' + resolved.loader.kind +
        (resolved.loader.version.length > 0 ? ' ' + resolved.loader.version : '') };
  }

  /** 草稿仅存私有目录，按源根+版本绑定；不能把目标 URI 或账户内容混入包内元数据。 */
  async loadDraft(mcRoot: string, versionId: string): Promise<ExportRequest | null> {
    const path = this.context().filesDir + '/game-export/drafts.json';
    try {
      await this.draftTail_;
      if (!(await exportPathExists(path))) return null;
      const records = parseDraftRecords(await readExportText(parentPath(path), 'drafts.json'));
      const saved = records.find((entry: ExportDraft): boolean => entry !== null && typeof entry === 'object' &&
        entry.key === mcRoot + '\n' + versionId);
      if (saved === undefined) return null;
      await validateExportRequest(saved.request);
      if (saved.request.mcRoot !== mcRoot || saved.request.versionId !== versionId) throw new Error('草稿来源与当前版本不一致');
      return copyRequest(saved.request);
    } catch (error) {
      // 草稿只是可选的历史选择，不拥有当前源的准入权。旧目录迁移/删除、存储撤权、
      // 截断JSON或旧保存失败均只令本次草稿失效；原件保持原位，当前有效源仍可重新选择。
      AppLogger.warn('GameExport', '历史导出草稿不可用，已保留原件并使用当前源选择', error as Error);
      return null;
    }
  }
  saveDraft(request: ExportRequest): Promise<void> {
    const frozen = copyRequest(request);
    const job = this.draftTail_.catch((): void => {}).then(async (): Promise<void> => {
      await validateExportRequest(frozen);
      const path = this.context().filesDir + '/game-export/drafts.json';
      let records: ExportDraft[] = [];
      if (await exportPathExists(path)) {
        try { records = parseDraftRecords(await readExportText(parentPath(path), 'drafts.json')); }
        catch (error) {
          await quarantineDraft(path, this.context().filesDir);
          AppLogger.warn('GameExport', '损坏导出草稿的原始字节已隔离保存，将保存本次新选择', error as Error);
        }
      }
      const key = frozen.mcRoot + '\n' + frozen.versionId;
      const updated = records.filter((entry: ExportDraft): boolean => entry.key !== key).slice(-19);
      updated.push({ key, request: frozen }); await savePrivateJson(path, updated, this.context().filesDir);
    });
    this.draftTail_ = job; return job;
  }

  /**
   * 只读检查不联网补文件；缺少电脑依赖在结果列出，执行按钮才授权实际准备。
   * retainPreview=false供首页资格检查使用，仍核对真实源，但不替换用户在向导确认的计划。
   */
  async checkPlan(request: ExportRequest, retainPreview: boolean = true,
    cancelled: () => boolean = (): boolean => false): Promise<ExportPreview> {
    // 检查取消只属于本次调用，不复用正式导出任务的cancelRequested_或其它下载owner。
    checkCancelled(cancelled);
    const frozen = copyRequest(request);
    // 仅在这一次检查内复用稳定真实源的摘要事实。两个平台计划可能引用同一资源或库，
    // 但每个依赖仍独立核对期望；该实例不进入preview、成员字段、执行准备或最终冻结。
    // 两轮依赖检查只消费SHA1/长度；上下文固定用途，不能影响用户库存或最终快照双摘要。
    const checkContext = new ExportCheckDigestContext('sha1');
    await validateExportRequest(frozen); await this.assertSourceIdle(frozen);
    const sources = await readExportVersions(frozen.mcRoot, frozen.versionId);
    checkCancelled(cancelled);
    const resolved = ExportVersionResolver.resolve(frozen.versionId, sources);
    const issues: ExportIssue[] = resolved.issues.slice();
    // 检查入口也必须核对本轮真实发现错误，不能只依赖UI预先禁用按钮。这里只扫描
    // 内容元数据、不读payload或assets；未选中的错误分支不会阻断精确选择的合法子项。
    // 发现失败的选中范围保留为明确error，不能用空inventory把漏读伪装成可导出计划。
    const contentTree = await discoverExportContentTree(frozen, cancelled);
    const selectionIssues = exportContentSelectionIssues(frozen, contentTree);
    issues.push(...selectionIssues);
    let indexText = '';
    let dependencies: ExportDependency[] = [];
    const missing: ExportDependency[] = [];
    if (frozen.format === 'full' && !exportHasErrors(selectionIssues)) {
      // 完整包要交付可运行字节闭包，保留源JAR/库/assets与PC目标的全部严格核验。
      // 标准包只交付精确版本/加载器清单和所选覆盖文件，不读取、准备或hash未输出的assets。
      // 已有选中范围发现错误时先返回阻断，不继续整份资产hash让用户等待无效检查。
      const assetIndex = resolved.json['assetIndex'] as Record<string, Object> | undefined;
      if (assetIndex !== undefined && typeof assetIndex['id'] === 'string') {
        indexText = await readExportText(frozen.mcRoot, 'assets/indexes/' + assetIndex['id'] + '.json');
      }
      const dependencyPlan = DesktopDependencyPlanner.plan(resolved, frozen.platform, indexText);
      dependencies = dependencyPlan.dependencies;
      issues.push(...dependencyPlan.issues);
      const sourcePlatform: ExportPlatform = { os: 'linux', arch: 'x64', version: '' };
      const sourcePlan = DesktopDependencyPlanner.plan(resolved, sourcePlatform, indexText);
      if (sourcePlan.dependencies.filter((dependency: ExportDependency): boolean => dependency.kind === 'client').length !== 1) {
        issues.push(exportIssue('SOURCE_CLIENT_IDENTITY', '源实例没有唯一且可核验的本体 JAR 元数据，请先补全版本'));
      }
      for (const issue of sourcePlan.issues) {
        const ignoredPcLibrary = /^libraries\/(?:org\/lwjgl|net\/java\/(?:jinput|jutils))\//.test(issue.path);
        // artifact() 失败时不会生成依赖；必须接住其错误，不能让后续“遍历已有依赖”漏掉缺失本体。
        // 原版 PC 输入/图形库在 OHOS 安装中明确跳过，其目标元数据仍由完整包的 planner 负责。
        const targetOnly = issue.code === 'FORGELIKE_GENERATED_ARTIFACTS' || issue.code === 'FORGELIKE_PROFILE_PREPARATION' || issue.code === 'NATIVE_CLASSIFIER';
        if (!targetOnly && !ignoredPcLibrary) issues.push(issue);
      }
      const sourcePaths = new Set<string>();
      const sourceDependencies = sourcePlan.dependencies.filter((dependency: ExportDependency): boolean =>
        dependency.kind !== 'native' && !(dependency.kind === 'library' &&
          /^libraries\/(?:org\/lwjgl|net\/java\/(?:jinput|jutils))\//.test(dependency.path)));
      // 两轮各自最多四项在途；源轮先真实drain，PC轮才开始，保留同check的强身份摘要复用。
      // 先按index取得结果，再按原顺序折叠，不能让异步完成顺序改变问题/缺件或实际来源。
      const sourceSelections = await selectExportDependencySources(frozen.mcRoot, sourceDependencies, cancelled, checkContext);
      for (let index = 0; index < sourceDependencies.length; index++) {
        const dependency = sourceDependencies[index];
        const selected = sourceSelections[index];
        const path = selected ?? dependency.sourcePath ?? dependency.path;
        if (sourcePaths.has(path)) continue;
        sourcePaths.add(path);
        if (selected === undefined) {
          issues.push(exportIssue('SOURCE_FILE_INVALID', '源文件缺失或损坏，请先校验或补全版本：' + path, path));
        } else if (dependency.sha1.length === 0) {
          issues.push(exportIssue('SOURCE_LOCAL_IDENTITY', '此历史库缺少上游摘要，将记录实际字节身份；完整包仍须在副本取得可信远端摘要。', path, true));
        }
      }
      const targetSelections = await selectExportDependencySources(frozen.mcRoot, dependencyPlan.dependencies, cancelled, checkContext);
      for (let index = 0; index < dependencyPlan.dependencies.length; index++) {
        const dependency = dependencyPlan.dependencies[index];
        const selected = targetSelections[index];
        const sourcePath = selected ?? dependency.sourcePath ?? dependency.path;
        const valid = dependency.sha1.length > 0 && selected !== undefined;
        // 预览核验到哪一份实际源，后续快照就固定读取哪一份；不得在导出时重新回到候选首项。
        if (selected !== undefined) dependency.sourcePath = selected;
        // 本体、资产和日志属于源管理完整性，不能把缺失源数据伪装成只缺电脑版文件。
        if (!valid && ['client', 'assetIndex', 'asset', 'logging'].indexOf(dependency.kind) >= 0) {
          issues.push(exportIssue('SOURCE_FILE_INVALID', '源文件缺失或摘要不符，请先校验或补全版本：' + sourcePath, sourcePath));
        } else if (!valid) {
          if (dependency.generated || !dependency.url.startsWith('https://')) {
            issues.push(exportIssue('DEPENDENCY_UNAVAILABLE', '必需文件没有可验证的准备来源：' + dependency.path, dependency.path));
          } else missing.push(dependency);
        }
      }
    }
    // 两格式都核对真正选中的用户内容；目录增删/内容变化、路径和目标读回门不因标准包减弱。
    const inventory = exportHasErrors(selectionIssues) ? [] : await inventoryExportContent(frozen, cancelled);
    checkCancelled(cancelled);
    const plan = ExportFilePlan.build(frozen, resolved, dependencies, inventory);
    issues.push(...plan.issues);
    if (frozen.sharedGameDir) issues.push(exportIssue('SHARED_CONTENT', '仅导出你勾选的共享内容，其他版本的资料不会自动归入本版本。', '', true));
    if (frozen.format !== 'full') issues.push(exportIssue('LOCAL_OVERRIDES', '本地资源按当前字节放入 overrides；请确认有权分享这些文件。接收端仍需联网安装游戏和加载器。', '', true));
    const totalBytes = plan.totalBytes;
    const downloadBytes = missing.reduce((sum: number, item: ExportDependency): number => sum + item.size, 0);
    const needsLoaderPreparation = frozen.format === 'full' && (resolved.loader.kind === 'forge' || resolved.loader.kind === 'neoforge');
    const preview: ExportPreview = { id: util.generateRandomUUID(), request: copyRequest(frozen), issues,
      // profile 在另存后才获取；先为 installer/processor/展开校验预留额外空间，准备结束仍按实际闭包复核。
      files: plan.files.length, totalBytes, tempBytes: totalBytes * 2 + downloadBytes + (needsLoaderPreparation ? 576 : 64) * 1024 * 1024,
      downloads: missing.length, downloadBytes, summary: [
        '目标：' + frozen.launcher.toUpperCase() + (frozen.format === 'full' ? ' / Windows x64' : ' / 标准整合包'),
        '源资料保持原位；导出副本使用版本隔离目录。',
        '不包含账户、启动器、Java、OHOS 运行库或安装控制记录。',
        'ZIP64 按原字节存储；JAR 和资源 ZIP 通常已压缩，文件大小接近所选数据总量。',
        '远程依赖大小缺失时仅显示已知大小，准备后会重新检查临时空间。',
        '目标剩余空间可能无法查询，写满或撤销权限会失败并可能留下半成品。',
        '接收端实际导入、隔离目录和游戏运行需以对应启动器验收为准。'
      ] };
    if (needsLoaderPreparation) preview.summary.push('Forge/NeoForge 将校验精确官方安装器并补齐运行件；最终文件数和下载量在准备后确定。需要重建时使用设备已有兼容 JDK 与 JIT 权限。');
    if (retainPreview) {
      this.previews_.clear();
      this.previews_.set(preview.id, { preview, versions: sources, resolved, inventory,
        dependencies, missing, plan, assetIndexJson: indexText });
    }
    return JSON.parse(JSON.stringify(preview)) as ExportPreview;
  }

  /**
   * 系统公共文档URI可通过CoreFileKit.FileUri.name取得已由Picker确认的名称，百分号编码
   * 由SDK负责解码。适用范围依据FileUri官方constructor的公共文档格式；未知提供方的
   * content URI或解析失败只返回空名，不能把尾部ID猜成文件名，也不能回退为newFileNames建议名。
   * 本方法只读取本次授权的显示元数据，不持久化URI、更不延长或复用目标授权。
   */
  private pickedFilename_(uri: string): string {
    if (!uri.startsWith('file://docs/storage/Users/currentUser/') || uri.endsWith('/')) return '';
    try {
      const name: string = new fileUri.FileUri(uri).name;
      return name.length > 0 && name !== '.' && name !== '..' && !/[\u0000-\u001f\u007f/\\]/.test(name) ? name : '';
    } catch (_) { return ''; }
  }

  /** 系统另存先于补依赖、复制和打包；取消另存不是导出失败，也不会创建重任务。 */
  async pickAndStart(context: common.UIAbilityContext, preview: ExportPreview): Promise<string> {
    if (this.active() || this.execution_ !== undefined || this.choosing_) throw new Error('已有导出任务或正在结束，请查看当前任务');
    // 旧下载终态回调可能早于worker退出；即便父任务已显示失败，也须先证明旧owner确已释放。
    if (!this.purgeDownloadOwners_()) throw new Error('上次下载 owner 尚未释放，请稍后重试');
    const checked = this.previews_.get(preview.id);
    if (checked === undefined || JSON.stringify(checked.preview.request) !== JSON.stringify(preview.request)) throw new Error('导出计划已失效，请重新检查');
    if (exportHasErrors(checked.preview.issues)) throw new Error('请先处理预览中的问题');
    // 预约系统另存本身就取得新的任务意图，不能让已离页的历史恢复在Picker等待中接管展示。
    this.restoreGeneration_++;
    this.choosing_ = true; this.context_ = context;
    let releaseProcessTask: (() => void) | undefined = undefined;
    try {
      const request = copyRequest(checked.preview.request);
      const extension = request.format === 'modrinth' ? '.mrpack' : '.zip';
      const suggestedFilename = request.exportId + (request.format === 'full' ? '-full-windows-x64' : '-' + request.format) + extension;
      const options = new picker.DocumentSaveOptions(); options.newFileNames = [suggestedFilename];
      options.fileSuffixChoices = [request.format === 'modrinth' ? 'Modrinth|.mrpack' : 'ZIP|.zip'];
      const destinations = await new picker.DocumentViewPicker(context).save(options);
      if (destinations.length === 0) return '';
      // Picker等待不占用进程；确认目标后立即在同一同步栈预约，覆盖接下来的源复核和
      // 初始记录写入，禁止游戏趁execute尚未登记的await窗口先派发共享JVM。
      releaseProcessTask = ProcessActivityCoordinator.instance().acquireFileTask('游戏包导出');
      await this.assertSourceIdle(request);
      const id = DownloadTaskRegistry.instance().reserveActivityId().toString() + '-' + util.generateRandomUUID();
      this.cancelRequested_ = false;
      this.task_ = { id, request, stage: '准备导出', state: 'running', message: '正在复核检查结果',
        processedFiles: 0, totalFiles: checked.plan.files.length, processedBytes: 0, totalBytes: checked.plan.totalBytes,
        filename: this.pickedFilename_(destinations[0]), size: 0, sha256: '', readbackVerified: false };
      try { await this.persistTask(); }
      catch (_) {
        // 还未交给 execute 的预约必须在这里收口，私有磁盘写满不能留下无人负责的 running。
        this.task_.state = 'failed'; this.task_.stage = '导出未开始';
        this.task_.message = '任务记录保存失败，尚未准备或写入游戏包，请检查应用存储后重试。';
        this.changed(); throw new Error(this.task_.message);
      }
      this.changed();
      // owner 明确接住异步任务，所有失败在 execute 内转成可重入的终态，不依赖页面生命周期。
      const execution = this.execute(checked, destinations[0], releaseProcessTask);
      releaseProcessTask = undefined; // 预约已移交真实执行owner，页面finally不能提前释放。
      this.execution_ = execution;
      const settled = (): void => { if (this.execution_ === execution) this.execution_ = undefined; };
      execution.then(settled, (error: Error): void => {
        settled(); AppLogger.error('GameExport', '导出记录保存失败：' + error.message);
      });
      return id;
    } finally { releaseProcessTask?.(); this.choosing_ = false; }
  }

  cancelTask(): void {
    if (!this.active()) return;
    const alreadyRequested = this.cancelRequested_;
    this.cancelRequested_ = true;
    if (this.task_ !== null) { this.task_.state = 'cancelling'; this.task_.message = '正在等待当前文件读写和下载 owner 结束'; }
    for (const id of this.downloadIds_) DownloadManager.instance().cancel(id);
    // Registry取消会回调adapter.stop_到本方法；只首次转发，避免递归和重复排队取消。
    if (!alreadyRequested && this.preparation_ !== null && this.preparation_.view.canCancel) {
      DownloadTaskRegistry.instance().cancel(this.preparation_.view.id, false).catch((error: Error): void => {
        AppLogger.error('GameExport', '导出准备取消等待失败：' + error.message);
      });
    }
    this.changed();
  }

  /**
   * 只释放本owner明确登记且Native已退出的ID。失败项继续留在集合，禁止新导出或
   * cleanup假借终态卡片提前使用其目录；遍历快照，单项purge异常也不丢其他归属。
   */
  private purgeDownloadOwners_(): boolean {
    for (const id of Array.from(this.downloadIds_)) {
      try { if (DownloadManager.instance().purgeTask(id)) this.downloadIds_.delete(id); }
      catch (_) { /* 保留ID，后继显式重试或有限等待重新核验。 */ }
    }
    return this.downloadIds_.size === 0;
  }

  /**
   * 此调用栈持有Registry action/文件读租约，必须持续等到全部ID真实释放。共用
   * Manager的retainOwner模式：超时只警告，不能throw后令队列finally提前放槽位。
   * Set仍逐项删除已释放ID，显式下一任务准入继续用上面的同步purge检查。
   */
  private async settleDownloadOwners_(): Promise<void> {
    for (const id of Array.from(this.downloadIds_)) {
      await DownloadManager.instance().awaitTaskReleased(id, true);
      this.downloadIds_.delete(id);
    }
  }

  /** 已知独立依赖合成一个Native批次；动态profile/processor阶段仍由调用方顺序推进。 */
  private async prepareDependencies(checked: CheckedExport, cache: string,
    dependencies: ExportDependency[] = checked.missing, candidateUrls?: string[], candidates?: ExportDependencyCandidates[]): Promise<void> {
    const cancelled = (): boolean => this.cancelRequested_;
    if (candidateUrls !== undefined && dependencies.length !== 1) throw new Error('多源下载必须绑定唯一依赖');
    if (dependencies.length === 0) return;
    // profile的私服/坐标候选必须逐工件绑定；重复目标或计划外path不允许静默覆盖。
    const sources: Map<string, string[]> = new Map<string, string[]>();
    for (const source of candidates || []) {
      if (sources.has(source.path) || !dependencies.some((dependency: ExportDependency): boolean => dependency.path === source.path)) {
        throw new Error('电脑依赖候选未绑定唯一计划项：' + source.path);
      }
      sources.set(source.path, source.urls);
    }
    const prepared: Map<number, DownloadFileSpec> = new Map<number, DownloadFileSpec>();
    let next = 0;
    // 有界worker共享首个Error；使用明确元素类型的容器，使ArkTS在await后仍能
    // 正确识别跨闭包写入的异常，不把可空局部变量错误收窄为never。
    const preparationErrors: Error[] = [];
    // 仅准备metadata/目录，不另建正文下载循环。小并发有界获取缺失sidecar，并等所有
    // 已启动操作结束后才抛首错；Promise.all直接reject会令在途metadata越过owner收尾。
    const prepare = async (): Promise<void> => {
      while (next < dependencies.length && preparationErrors.length === 0 && !cancelled()) {
        const index = next++;
        const dependency = dependencies[index];
        try {
          checkCancelled(cancelled);
          const declaredUrls = sources.get(dependency.path);
          // 显式候选已按工件绑定并由调用方依统一源偏好排序；这里仅核验HTTPS、稳定去重，
          // 不把官方直链重新插到队首，否则会覆盖镜像优先设置。无显式候选的普通库仍用
          // 既有Maven规则生成等价来源，不能根据另一个依赖的坐标猜测本工件候选。
          const orderedUrls: string[] = declaredUrls !== undefined ? declaredUrls : candidateUrls !== undefined ? candidateUrls :
            (dependency.kind === 'library' || dependency.kind === 'native') ?
              buildMavenArtifactUrls(dependency.url, !shouldUseBmclapiFirst()) : [dependency.url];
          const urls: string[] = [];
          for (const url of orderedUrls) if (ExportPath.https(url) && urls.indexOf(url) < 0) urls.push(url);
          // artifact.path/url本身即可合法；缺少Maven name会令builder返回[]。始终补回合法
          // 原URL作为后备，但不修改调用方的数组或打乱已过滤候选，保住这类显式输入。
          if (ExportPath.https(dependency.url) && urls.indexOf(dependency.url) < 0) urls.push(dependency.url);
          if (urls.length === 0) throw new Error('电脑依赖没有安全下载源：' + dependency.path);
          if (dependency.sha1.length === 0) {
            this.preparation_?.message('获取电脑依赖摘要：' + dependency.path);
            const sidecars = urls.map((url: string): string => artifactSidecarUrl(url, '.sha1'));
            const sidecar = (await DownloadManager.instance().fetchText(sidecars[0], sidecars.slice(1), 30)).trim();
            checkCancelled(cancelled);
            const match = sidecar.match(/^([0-9a-fA-F]{40})(?:\s|$)/);
            if (match === null) throw new Error('远端没有可靠 SHA1，不能准备完整包：' + dependency.path);
            dependency.sha1 = match[1].toLowerCase();
          }
          if (safeRelPath(dependency.path) !== dependency.path) throw new Error('电脑依赖目标路径不安全');
          const target = cache + '/' + dependency.path;
          await makeDirectory(parentPath(target), this.context().filesDir);
          checkCancelled(cancelled);
          const spec: DownloadFileSpec = { localPath: target, allowedRoot: cache, urls,
            check: { sha1: dependency.sha1 } };
          if (dependency.size > 0 && spec.check !== undefined) spec.check.size = dependency.size;
          prepared.set(index, spec);
        } catch (error) { if (preparationErrors.length === 0) preparationErrors.push(error as Error); }
      }
    };
    const workers: Promise<void>[] = [];
    for (let index = 0; index < Math.min(3, dependencies.length); index++) workers.push(prepare());
    await Promise.all(workers);
    if (preparationErrors.length > 0) throw preparationErrors[0];
    checkCancelled(cancelled);
    const specs: DownloadFileSpec[] = [];
    for (let index = 0; index < dependencies.length; index++) {
      const spec = prepared.get(index);
      if (spec === undefined) throw new Error('电脑依赖计划未完整准备');
      specs.push(spec);
    }
    try {
      const result = await DownloadManager.instance().createAndWait({ name: '导出准备 ' + checked.preview.request.versionId,
        files: compileDownloadFiles(specs) }, (view: DownloadTaskView): void => {
          if (view.taskId > 0) this.downloadIds_.add(view.taskId);
          if (this.cancelRequested_ && view.taskId > 0) DownloadManager.instance().cancel(view.taskId);
          const label = '准备电脑依赖：' + (view.currentFile || dependencies[0].path);
          this.preparation_?.progress(view, label);
          if (this.task_ !== null) { this.task_.processedBytes = view.bytesDone; this.task_.message = label; this.changed(); }
        });
      if (result.taskId > 0) this.downloadIds_.add(result.taskId);
    } finally { await this.settleDownloadOwners_(); }
    checkCancelled(cancelled);
    let verifiedBytes = 0;
    for (const dependency of dependencies) {
      if (!(await inspectExportDependency(cache, dependency, cancelled))) throw new Error('下载后的电脑依赖校验失败：' + dependency.path);
      dependency.size = (await fs.lstat(cache + '/' + dependency.path)).size;
      verifiedBytes += dependency.size;
    }
    this.preparation_?.batchVerified(dependencies.length, verifiedBytes);
  }

  /** 快照复制按块读取、短写循环；读前后源摘要及最终重盘点共同拒绝观察到的并发变化。 */
  private async copySnapshotFile(source: string, target: string, expected: ExportPlannedFile,
    cancelled: () => boolean): Promise<void> {
    const before = await hashExportFile(source, cancelled);
    if ((expected.sha1.length > 0 && before.sha1 !== expected.sha1.toLowerCase()) ||
      (expected.sha256.length > 0 && before.sha256 !== expected.sha256) || (expected.size > 0 && before.size !== expected.size)) {
      throw new Error('源文件已变化，请重新检查：' + expected.sourcePath);
    }
    await makeDirectory(parentPath(target), this.context().filesDir);
    const input = await fs.open(source, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    let output: fs.File | undefined = undefined;
    try {
      output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
      // 小文件按实际长度分配，大文件最多256KiB；减少块桥接，同时不把整份资源装入内存。
      // 内容摘要前/副本/源后仍全部fresh，块大小只改变搬运粒度，不改变一致性协议。
      const buffer = new ArrayBuffer(Math.max(1, Math.min(256 * 1024, before.size)));
      // 显式推进读取位置，短读后仍从实际读取长度继续，便于逐块核验复制边界。
      let position = 0;
      while (true) {
        checkCancelled(cancelled);
        const read = await fs.read(input.fd, buffer, { offset: position, length: buffer.byteLength });
        if (!Number.isSafeInteger(read) || read < 0 || read > buffer.byteLength) throw new Error('快照读取返回无效长度');
        if (read === 0) break;
        position += read;
        let offset = 0;
        while (offset < read) {
          const written = await fs.write(output.fd, buffer.slice(offset, read));
          if (!Number.isSafeInteger(written) || written <= 0 || written > read - offset) throw new Error('快照写入不完整');
          offset += written;
        }
      }
      await fs.fsync(output.fd);
    } finally { try { if (output !== undefined) await fs.close(output); } finally { await fs.close(input); } }
    const copied = await hashExportFile(target, cancelled);
    const after = await hashExportFile(source, cancelled);
    if (before.sha256 !== copied.sha256 || before.sha256 !== after.sha256 || before.size !== copied.size) {
      throw new Error('复制期间源文件发生变化：' + expected.sourcePath);
    }
    expected.size = copied.size; expected.sha1 = copied.sha1; expected.sha256 = copied.sha256;
  }

  /**
   * 快照只在同一execute/版本/Registry租约内并发，最多两个普通文件在途。先一次验证
   * 全部归档路径并去重创建所需目录；每项写前仍由原makeDirectory重新核验真实目录，
   * 预建不充当永久安全缓存。每个copy完整保留源前/副本/源后三份fresh摘要和fsync/close。
   *
   * 本批故障取消与用户cancelRequested_分开：首错停止派新项并通知其它已入场copy，
   * 等所有原copy的fd/Native positive release收口才抛首因，外层finally才能释放租约。
   * plan数组不重排，各文件只更新自己的摘要；计数在JS同步片段累加，完成顺序不使进度回退。
   * 版本JSON/接收端设置等生成元数据最后串行写，完整性报告仍由调用方在全体成功后生成。
   */
  private async copySnapshotFiles(plan: ExportFilePlanResult, snapshot: string, cache: string,
    request: ExportRequest, task: ExportTaskView, cancelled: () => boolean): Promise<void> {
    const directories: Set<string> = new Set<string>();
    for (const file of plan.files) {
      checkCancelled(cancelled);
      if (safeRelPath(file.archivePath) !== file.archivePath) throw new Error('归档路径无效');
      let directory = file.directory ? file.archivePath : parentPath(file.archivePath);
      while (directory.length > 0) { directories.add(directory); directory = parentPath(directory); }
    }
    const ordered = Array.from(directories).sort((left: string, right: string): number =>
      left.split('/').length - right.split('/').length || left.localeCompare(right));
    for (const directory of ordered) { checkCancelled(cancelled); await makeDirectory(snapshot + '/' + directory, this.context().filesDir); }
    for (const file of plan.files) if (file.directory) { task.processedFiles++; this.changed(); }

    const files = plan.files.filter((file: ExportPlannedFile): boolean => !file.directory && file.source !== 'generated');
    let next = 0;
    let stopped = false;
    let failed = false;
    let failure: Error = new Error('快照复制未完成');
    const stop = (error: Object | null | undefined): void => {
      if (!failed) { failed = true; failure = error instanceof Error ? error : new Error('快照复制返回了非Error异常'); }
      stopped = true;
    };
    const interrupted = (): boolean => stopped || cancelled();
    const worker = async (): Promise<void> => {
      while (!stopped) {
        try {
          checkCancelled(interrupted);
          const index = next++;
          if (index >= files.length) return;
          const file = files[index];
          const cached = cache + '/' + file.sourcePath;
          let source = request.mcRoot + '/' + file.sourcePath;
          if (file.source === 'gameDir') {
            await assertExportPath(request.gameDir, file.sourcePath); source = request.gameDir + '/' + file.sourcePath;
          } else if (await exportPathExists(cached)) source = cached;
          else await assertExportPath(request.mcRoot, file.sourcePath);
          checkCancelled(interrupted);
          await this.copySnapshotFile(source, snapshot + '/' + file.archivePath, file, interrupted);
          checkCancelled(interrupted);
          task.processedFiles++; task.processedBytes += file.size; this.changed();
        } catch (error) { stop(error as Object); return; }
      }
    };
    const workers: Promise<void>[] = [];
    for (let index = 0; index < Math.min(2, files.length); index++) workers.push(worker());
    // worker接住全部错误，所以本Promise只负责完整drain，不是Promise.all首错退出。
    await Promise.all(workers);
    if (failed) throw failure;
    checkCancelled(cancelled);
    for (const file of plan.files) if (!file.directory && file.source === 'generated' && file.archivePath !== 'amcl-export.json') {
      checkCancelled(cancelled);
      const target = snapshot + '/' + file.archivePath;
      await savePrivateText(target, file.content, this.context().filesDir);
      const digest = await hashExportFile(target, cancelled);
      file.size = digest.size; file.sha1 = digest.sha1; file.sha256 = digest.sha256;
      task.processedFiles++; task.processedBytes += file.size; this.changed();
    }
  }

  /**
   * 数据阶段异常都落终态；源保护在快照结束释放，不占着用户目录等待云盘 URI 写完。
   * 临时目录只在本次 I/O 和 Native owner 确认收敛后清理，失败材料保留供重试调查。
   */
  private async execute(original: CheckedExport, uri: string, releaseProcessTask: () => void): Promise<void> {
    const task = this.task_;
    if (task === null) { releaseProcessTask(); return; }
    const cancelled = (): boolean => this.cancelRequested_;
    const request = task.request;
    const workRelative = 'game-export/work/' + task.id;
    const work = this.context().filesDir + '/' + workRelative;
    const nativeContext: ExportNativeContext = { filesDir: this.context().filesDir, workRelative };
    let releaseRegistry: (() => void) | undefined = undefined;
    let releaseVersion: (() => void) | undefined = undefined;
    let safeToClean = false;
    try {
      // 沿用Picker确认时已取得的预约；直到目标关闭/回读/记录和清理全部结束才释放。
      await makeDirectory(parentPath(work), this.context().filesDir); await fs.mkdir(work);
      const owner: ExportOwner = { id: task.id, schemaVersion: 1 };
      await savePrivateJson(work + '/owner.json', owner, this.context().filesDir);
      const free = await statfs.getFreeSize(work);
      if (free < original.preview.tempBytes) throw new Error('应用临时空间不足，请减少导出内容后重试');
      await this.assertSourceIdle(request);
      await this.assertVersionsUnchanged(original);
      const currentInventory = await inventoryExportContent(request, cancelled);
      if (JSON.stringify(currentInventory) !== JSON.stringify(original.inventory)) throw new Error('预览后实例内容已变化，请重新检查');
      await this.stage('准备电脑文件', '缺少的电脑依赖只写入本次导出目录');
      const cache = work + '/dependencies'; await makeDirectory(cache, this.context().filesDir);
      const forgelike = request.format === 'full' && (original.resolved.loader.kind === 'forge' || original.resolved.loader.kind === 'neoforge');
      if (forgelike || original.missing.length > 0) {
        const exportId = task.id;
        const preparation = new ExportPreparationDownloadTask(exportId, request.versionId, request.mcRoot,
          !request.sharedGameDir, async (): Promise<void> => {
            checkCancelled(cancelled);
            if (forgelike) {
              // 安装器只在用户确认另存后取得；无官方输出摘要的运行件在本次私有root重建。
              // Registry只投影/排队，全部Native下载仍交原导出owner追踪取消与purge。
              original.dependencies = await prepareForgelikeExport(original.resolved, request.platform, original.assetIndexJson,
                request.mcRoot, this.context().filesDir, work, cache,
                async (dependencies: ExportDependency[], root: string, urls?: string[], candidates?: ExportDependencyCandidates[]): Promise<void> => {
                  await this.prepareDependencies(original, root, dependencies, urls, candidates);
                }, (message: string): void => {
                  task.message = message; this.preparation_?.message(message); this.changed();
                }, cancelled);
            } else await this.prepareDependencies(original, cache);
          }, (): void => { if (this.task_?.id === exportId) this.cancelTask(); },
          (): boolean => this.task_?.id !== exportId || this.downloadIds_.size === 0);
        this.preparation_ = preparation;
        try {
          // 整个阶段只占一个FIFO槽；内部文件直接交同一Native owner，不再嵌套enqueue。
          // Registry承诺在实际action/文件租约/运行槽位退出后才resolve，之后才能申请冻结租约。
          await DownloadTaskRegistry.instance().enqueue(preparation);
        } finally { if (this.preparation_ === preparation) this.preparation_ = null; }
      }
      checkCancelled(cancelled);
      await this.assertSourceIdle(request);
      // 沿用 registry 的全局空闲预约封住新的排队安装，并以版本租约保护父/子安装写入。
      releaseRegistry = DownloadTaskRegistry.instance().acquireReplacementLease();
      releaseVersion = claimVersionInstall(request.mcRoot, request.versionId, 'export-' + task.id);
      await this.stage('冻结输入', '复制所选内容并核对源文件前后摘要');
      await this.assertVersionsUnchanged(original);
      const plan = ExportFilePlan.build(request, original.resolved,
        request.format === 'full' ? original.dependencies : [], original.inventory);
      if (exportHasErrors(plan.issues)) throw new Error(plan.issues.find((issue: ExportIssue): boolean => issue.severity === 'error')?.message ?? '导出计划不完整');
      const actualBytes = plan.files.reduce((sum: number, file: ExportPlannedFile): number => sum + file.size, 0);
      if ((await statfs.getFreeSize(work)) < actualBytes * 2 + 64 * 1024 * 1024) throw new Error('准备依赖后临时空间不足，请减少导出内容');
      task.totalBytes = actualBytes; task.totalFiles = plan.files.length;
      const snapshot = work + '/snapshot'; await makeDirectory(snapshot, this.context().filesDir);
      await this.copySnapshotFiles(plan, snapshot, cache, request, task, cancelled);
      const report = plan.files.find((file: ExportPlannedFile): boolean => file.archivePath === 'amcl-export.json');
      if (report === undefined) throw new Error('导出缺少完整性说明');
      const exported: Record<string, Object>[] = plan.files.filter((file: ExportPlannedFile): boolean => file !== report)
        .map((file: ExportPlannedFile): Record<string, Object> => {
          const entry: Record<string, Object> = { 'path': file.archivePath, 'size': file.size, 'sha256': file.sha256, 'directory': file.directory };
          if (file.provenance !== undefined) entry['provenance'] = file.provenance;
          return entry;
        });
      const manifest: Record<string, Object> = { 'schemaVersion': 1, 'format': request.format, 'launcher': request.launcher,
        'minecraft': original.resolved.vanillaVersion, 'loader': original.resolved.loader.kind,
        'loaderVersion': original.resolved.loader.version, 'exportId': request.exportId,
        'requiresNetworkInstall': request.format !== 'full', 'files': exported };
      if (request.format === 'full') manifest['platform'] = request.platform.os + '-' + request.platform.arch;
      report.content = JSON.stringify(manifest, null, 2);
      await savePrivateText(snapshot + '/amcl-export.json', report.content, this.context().filesDir);
      const reportDigest = await hashExportFile(snapshot + '/amcl-export.json', cancelled);
      report.size = reportDigest.size; report.sha1 = reportDigest.sha1; report.sha256 = reportDigest.sha256;
      await this.assertSourceIdle(request); await this.assertVersionsUnchanged(original);
      const after = await inventoryExportContent(request, cancelled);
      if (JSON.stringify(after) !== JSON.stringify(original.inventory)) throw new Error('冻结期间实例内容已变化，请重新检查');
      releaseVersion(); releaseVersion = undefined; releaseRegistry(); releaseRegistry = undefined;
      checkCancelled(cancelled);
      await this.stage('打包', '正在写入 ZIP64 归档');
      const archive = work + '/export.zip';
      await writeExportArchive(snapshot, archive, plan.files, cancelled, (files: number, bytes: number): void => {
        task.processedFiles = files; task.processedBytes = bytes; this.changed();
      }, nativeContext);
      await this.stage('校验归档', '逐条读回归档并比对路径、大小和摘要');
      await verifyExportArchive(archive, plan.files, cancelled, nativeContext);
      await this.stage('写入目标', '正在写入所选位置，写完后读回复核');
      const result = await copyExportArchiveToUri(archive, uri, cancelled, (bytes: number): void => {
        task.processedBytes = bytes; this.changed();
      });
      checkCancelled(cancelled);
      task.size = result.size; task.sha256 = result.sha256; task.readbackVerified = result.readbackVerified;
      task.state = 'succeeded'; task.stage = '导出完成';
      task.message = result.readbackVerified ? '目标文件已写入、关闭并读回校验成功。' : '目标已写入并关闭，当前目标不支持读回校验。';
      safeToClean = true;
    } catch (error) {
      task.state = this.cancelRequested_ ? 'cancelled' : 'failed';
      task.stage = this.cancelRequested_ ? '已取消' : '导出失败';
      task.message = (error as Error).message + '。源资料保留；若已开始写目标，目标可能有半成品，请在文件管理器核对。';
      safeToClean = this.cancelRequested_ && this.downloadIds_.size === 0;
    } finally {
      if (releaseVersion !== undefined) releaseVersion();
      if (releaseRegistry !== undefined) releaseRegistry();
      try { await this.persistTask(); }
      catch (_) { task.message += ' 任务记录暂未保存，请保留本页结果并检查应用存储。'; }
      this.changed();
      try {
        const startedAt = Number(task.id.substring(0, task.id.indexOf('-')));
        const record: ActivityRecord = { versionName: request.versionId, gameVersion: original.resolved.vanillaVersion,
          loaderType: original.resolved.loader.kind, loaderVersion: original.resolved.loader.version,
          startedAt, endedAt: Date.now(), durationMs: Math.max(0, Date.now() - startedAt), totalBytes: task.size,
          fileCount: task.totalFiles, status: task.state === 'succeeded' ? 'success' : task.state === 'cancelled' ? 'aborted' : 'failed',
          category: ActivityCategory.GAME_EXPORT, title: '导出 ' + request.displayName,
          subtitle: request.format + ' · ' + request.launcher.toUpperCase(), mcDir: request.mcRoot, exportTaskId: task.id };
        if (task.state !== 'succeeded') record.errorMessage = task.message;
        const history = getDownloadHistoryStore(); await history.init(this.context()); await history.add(record);
        // 私有任务终态先于活动LRU的异步耐久提交。内嵌Sheet可能已经返回详情/关闭，
        // 此时首页不会经过onPageShow；只有add成功后再通知，消费者才能取得最新持久视图。
        // 本次是稳定终态通知，与归档字节进度分开；写入失败仍沿下方原路径发布明确警告。
        this.changed();
      } catch (_) {
        task.message += ' 活动摘要暂未保存，导出私有记录仍保留。';
        try { await this.persistTask(); } catch (_) { /* 私有存储不可写时仍发布内存终态，释放owner。 */ }
        this.changed();
      }
      if (safeToClean) {
        try { await removeOwnedTree(work); } catch (_) { /* 清理失败不抹掉已确认的交付结果，记录保留供后续处理。 */ }
      }
      releaseProcessTask?.();
    }
  }

  /** 比较本轮实际读过的整条元数据链；继承身份变化也会使预览失效。 */
  private async assertVersionsUnchanged(checked: CheckedExport): Promise<void> {
    const current = await readExportVersions(checked.preview.request.mcRoot, checked.preview.request.versionId);
    if (JSON.stringify(current) !== JSON.stringify(checked.versions)) throw new Error('版本描述已变化，请重新检查');
  }
}

/** 生成文件仅写快照；UTF-8编码与成功短写循环，不把绝对源路径写入使用说明。 */
async function savePrivateText(path: string, content: string, trustedRoot: string): Promise<void> {
  await makeDirectory(parentPath(path), trustedRoot);
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    const bytes = new util.TextEncoder().encodeInto(content);
    let offset = 0;
    while (offset < bytes.length) {
      const written = await fs.write(file.fd, bytes.slice(offset, Math.min(offset + 65536, bytes.length)).buffer);
      if (written <= 0) throw new Error('导出说明写入不完整'); offset += written;
    }
    await fs.fsync(file.fd);
  } finally { await fs.close(file); }
}

const gameExportCoordinator = new GameExportCoordinator();
export function getGameExportCoordinator(): GameExportCoordinator { return gameExportCoordinator; }

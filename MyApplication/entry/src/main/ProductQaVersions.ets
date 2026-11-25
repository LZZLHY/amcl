import { qaTaskId, qaTaskRef } from './QaTaskIdentity';
import { QaTaskControl } from './QaTaskControl';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LedgerState, ledgerManifest, writeEvidenceTextAtomic } from 'commons';
import { ActivityCategory, McVersionTask, ModLoaderType, TaskCategory, UnifiedTaskView, UnifiedTaskState, listMcInstallRecovery, safeBaseName, versionInstallNameError } from 'feature_core';
import { inspectInstalledVersion, inspectLegacyVanilla, RemoteVersion } from 'mods';
import { LauncherVersionAccess, VersionCompanionTask, VersionInstallation } from './ets/runtime/LauncherVersionAccess';

/** 只保存请求与真实下载尝试的关联，业务终态始终从队列或生产活动账本取证。 */
interface InstallReference {
  request: string;
  target: string;
  game: string;
  root: string;
  loader: string;
  loaderVersion: string;
  activity: number;
  companionRequired: boolean;
  companionActivity: number;
  companionDispatchFailed: boolean;
}

interface LoaderVersionId {
  id: string;
  stable: boolean;
}
interface PageWindow { offset: number; limit: number; }

function pageWindow(args: Record<string, Object>): PageWindow | null {
  const offset = args['offset'] === undefined ? 0 : args['offset'] as number;
  const limit = args['limit'] === undefined ? 50 : args['limit'] as number;
  return Number.isSafeInteger(offset) && offset >= 0 && Number.isSafeInteger(limit) && limit > 0 && limit <= 100
    ? { offset: offset, limit: limit } : null;
}

interface RemoteVersionId {
  id: string;
  type: string;
}

function reply(status: string, reason: string = '', data: Record<string, Object> = {}): string {
  return JSON.stringify({ 'status': status, 'reason': reason, 'data': data });
}

/** 宿主提交的请求 ID 仅作为会话内文件名的一段使用，领域 ID 不能参与路径构造。 */
function validRequest(id: string): boolean {
  return /^[a-zA-Z0-9_-]{1,96}$/.test(id);
}

function stringArg(args: Record<string, Object>, key: string): string {
  const value = args[key];
  return typeof value === 'string' ? value as string : '';
}

function only(args: Record<string, Object>, allowed: string[]): boolean {
  return Object.keys(args).every((key: string): boolean => allowed.includes(key));
}

/** 新安装若遇已有目录、文件、链接或未完成计划，一律保留现场，让用户另选实例名。 */
function freshTarget(port: LauncherVersionAccess, root: string, name: string): boolean {
  try {
    fs.lstatSync(root + '/versions/' + name);
    return false;
  } catch (error) {
    if ((error as BusinessError).code !== 13900002) throw error as Error;
  }
  return !listMcInstallRecovery(port.filesDir, root).some(record => record.versionName === name);
}

function validRef(ref: InstallReference, id: string, task: string): boolean {
  return ref !== null && ref.request === id && typeof ref.target === 'string' && ref.target.length > 0
    && ref.target === safeBaseName(ref.target) && 'mc:' + ref.target === task && typeof ref.game === 'string'
    && ref.game.length > 0 && typeof ref.companionRequired === 'boolean' && typeof ref.companionDispatchFailed === 'boolean'
    && Number.isSafeInteger(ref.companionActivity) && ref.companionActivity >= 0 && typeof ref.root === 'string' && Number.isSafeInteger(ref.activity) && ref.activity >= 0;
}

function taskData(ref: InstallReference, state: string, bytesDone: number, bytesTotal: number): Record<string, Object> {
  return { 'taskId': 'mc:' + ref.target, 'installRequestId': ref.request, 'versionName': ref.target,
    'gameVersion': ref.game, 'activityId': ref.activity, 'companionActivityId': ref.companionActivity, 'state': state, 'bytesDone': bytesDone, 'bytesTotal': bytesTotal };
}

export class ProductQaVersions {
  private static liveDir: string = '';
  private static completedChildren: Set<string> = new Set<string>();
  private static children: Map<string, UnifiedTaskView> = new Map<string, UnifiedTaskView>();
  private static live: Map<string, McVersionTask> = new Map<string, McVersionTask>();

  /** 页面与宿主共用产品操作；只有 default source set 含协议分派和请求关联文件。 */
  static async run(port: LauncherVersionAccess, action: string, json: string, request: string,
    session: () => string): Promise<string> {
    const dir = session();
    if (dir.length === 0 || !validRequest(request)) return reply('rejected', 'INVALID_SESSION_OR_REQUEST');
    if (dir !== ProductQaVersions.liveDir) {
      ProductQaVersions.live.clear();
      ProductQaVersions.children.clear();
      ProductQaVersions.completedChildren.clear();
      ProductQaVersions.liveDir = dir;
    }
    let args: Record<string, Object>;
    try { args = JSON.parse(json) as Record<string, Object>; }
    catch (_) { return reply('rejected', 'INVALID_ARGUMENTS'); }
    if (args === null || typeof args !== 'object' || Array.isArray(args)) return reply('rejected', 'INVALID_ARGUMENTS');
    try {
      if (!port.initialized()) {
        const reason = port.blockReason();
        return reply(reason === 'LAUNCHER_NOT_INTERACTIVE' ? 'needsUser' : 'unknown', reason || 'LAUNCHER_INITIALIZING');
      }
      if (action === 'tasks.list') {
        const window = pageWindow(args);
        if (!only(args, ['offset','limit']) || window === null) return reply('rejected', 'INVALID_ARGUMENTS');
        const views = port.registry.listAll();
        const rows = views.slice(window.offset, window.offset + window.limit).map((v: UnifiedTaskView): Record<string, Object> => {
          const id = qaTaskId(dir, v);
          return { 'taskId':id, 'taskRef':qaTaskRef(dir,v,request), 'state':v.state, 'activityId':v.startedAtMs, 'bytesDone':v.bytesDone, 'bytesTotal':v.bytesTotal };
        });
        return reply('ok', '', { 'tasks': rows, 'offset': window.offset, 'total': views.length });
      }
      if (action === 'tasks.get') return ProductQaVersions.observe(port, dir, args);
      if (action === 'tasks.control' || action === 'tasks.controlState') {
        if (action === 'tasks.control' && port.taskBlock()) return reply('needsUser',port.taskBlock());
        return QaTaskControl.run(port.registry, dir, action, args, request);
      }
      // 库存与已装身份是只读事实，允许在普通下载面板中查询。选择与安装仍服从完整交互门禁。
      const localRead = action === 'versions.list' || action === 'versions.inspect';
      const block = (): string => localRead ? port.taskBlock() : port.blockReason();
      const blocked = block();
      if (blocked) {
        return reply(blocked === 'LAUNCHER_INITIALIZING' || blocked === 'VERSION_SCAN_PENDING' ? 'unknown' : 'needsUser', blocked);
      }
      const root = port.root();
      const current = (): boolean => block() === '' && port.root() === root && session() === dir;
      if (action === 'loaders.list') {
        if (!only(args, [])) return reply('rejected', 'INVALID_ARGUMENTS');
        return reply('ok', '', { 'loaders': port.supportedLoaders() });
      }
      if (action === 'loaders.games' || action === 'loaders.versions') {
        const games = action === 'loaders.games';
        const window = pageWindow(args);
        const loader = stringArg(args, 'loader') as ModLoaderType;
        const game = stringArg(args, 'gameVersion');
        if (window === null || !only(args, games ? ['loader','offset','limit'] : ['loader','gameVersion','offset','limit'])
          || !port.supportedLoaders().includes(loader) || (!games && (!game || safeBaseName(game) !== game))) return reply('rejected','INVALID_ARGUMENTS');
        if (games) {
          const items = await port.loaders.getSupportedGameVersions(loader);
          if (!current()) return reply('needsUser', 'LAUNCHER_CHANGED');
          return reply('ok','',{ 'versions': items.slice(window.offset,window.offset + window.limit), 'offset':window.offset, 'total':items.length });
        }
        const items = await port.loaders.getLoaderVersions(loader, game);
        if (!current()) return reply('needsUser', 'LAUNCHER_CHANGED');
        const page: LoaderVersionId[] = items.slice(window.offset,window.offset + window.limit).map((item): LoaderVersionId =>
          ({id:item.loaderVersion,stable:item.stable}));
        return reply('ok','',{ 'versions':page,'offset':window.offset,'total':items.length });
      }
      if (action === 'versions.remote') {
        if (!only(args, ['gameVersion','offset','limit'])) return reply('rejected', 'INVALID_ARGUMENTS');
        const version = stringArg(args, 'gameVersion');
        const window = pageWindow(args);
        if ((args['gameVersion'] !== undefined && !version) || window === null) return reply('rejected', 'INVALID_ARGUMENTS');
        const offset = window.offset;
        const limit = window.limit;
        const result = await port.catalog.getVersionList();
        if (!current()) return reply('needsUser', 'LAUNCHER_CHANGED');
        const items = version ? result.versions.filter(item => item.id === version) : result.versions;
        const page: RemoteVersionId[] = items.slice(offset, offset + limit).map((item): RemoteVersionId =>
          ({ id: item.id, type: item.type }));
        return reply('ok', '', { 'versions': page, 'total': items.length, 'offset': offset });
      }
      if (action === 'versions.list' || action === 'versions.select' || action === 'versions.inspect') {
        const list = action === 'versions.list';
        const select = action === 'versions.select';
        const version = stringArg(args, 'version');
        const hint = stringArg(args, 'expectedGameVersion');
        if (!only(args, list ? [] : select ? ['version','ifSelected'] : ['version','expectedGameVersion'])
          || (args['expectedGameVersion'] !== undefined && (!hint || safeBaseName(hint) !== hint))
          || (!list && (!version || safeBaseName(version) !== version))) return reply('rejected', 'INVALID_ARGUMENTS');
        const before = port.selected();
        const inventory = await port.inventory();
        if (!current() || (select && before !== port.selected())) {
          const reason = block();
          return reply(reason === 'VERSION_SCAN_PENDING' || reason === 'LAUNCHER_INITIALIZING' ? 'unknown' : 'needsUser', reason || 'LAUNCHER_CHANGED');
        }
        if (inventory.error) return reply('unknown', 'INVENTORY_INCOMPLETE');
        if (list) {
          const selected = port.selected();
          return reply('ok', '', { 'installed': inventory.installed, 'orphans': inventory.orphans,
            'selected': inventory.installed.includes(selected) ? selected : '' });
        }
        if (!inventory.installed.includes(version)) return reply('rejected', 'VERSION_NOT_INSTALLED');
        if (!select) {
          const identity = inspectInstalledVersion(root, version) ?? await inspectLegacyVanilla(root, version, hint);
          if (!current()) return reply('unknown', 'LAUNCHER_CHANGED');
          if (identity === null) return reply('unknown','INSTALLED_IDENTITY_UNPROVEN');
          return reply('ok','',{'version':version,'gameVersion':identity.gameVersion,'loader':identity.loader,'loaderVersion':identity.loaderVersion});
        }
        if (args['ifSelected'] !== undefined && args['ifSelected'] !== port.selected()) return reply('rejected','SELECTION_CHANGED');
        if (!await port.select(version)) return reply('unknown','SELECTION_NOT_SAVED');
        return reply('ok', '', { 'selected': port.selected() });
      }
      if (action !== 'versions.install') return reply('rejected', 'UNKNOWN_ACTION');
      const game = stringArg(args, 'gameVersion');
      const loader: ModLoaderType | null = args['loader'] === undefined ? null : stringArg(args, 'loader') as ModLoaderType;
      const loaderVer = stringArg(args, 'loaderVersion');
      if (!only(args, ['gameVersion','versionName','loader','loaderVersion','withFabricApi']) || !game || safeBaseName(game) !== game
        || (loader === null && args['loaderVersion'] !== undefined) || (loader !== null && (!port.supportedLoaders().includes(loader)
        || !loaderVer || safeBaseName(loaderVer) !== loaderVer))
        || (args['withFabricApi'] !== undefined && (loader !== ModLoaderType.FABRIC || typeof args['withFabricApi'] !== 'boolean'))) {
        return reply('rejected', 'INVALID_ARGUMENTS');
      }
      const name = args['versionName'] === undefined ? port.suggestedName(game, loader, loaderVer) : stringArg(args, 'versionName');
      if (!name || name !== safeBaseName(name)) return reply('rejected', 'INVALID_ARGUMENTS');
      const catalog = await port.catalog.getVersionList();
      if (!current()) return reply('needsUser', 'LAUNCHER_CHANGED');
      if (!catalog.versions.some(item => item.id === game)) return reply('rejected', 'REMOTE_VERSION_NOT_FOUND');
      let api: RemoteVersion | null = null;
      let apiIcon = '';
      if (loader !== null) {
        const admission = port.loaderAdmission(game, loader);
        if (admission) return reply('needsUser', admission);
        const options = await port.loaders.getLoaderVersions(loader, game);
        if (!current()) return reply('needsUser', 'LAUNCHER_CHANGED');
        if (!options.some(item => item.loader === loader && item.loaderVersion === loaderVer && item.gameVersion === game)) {
          return reply('rejected', 'LOADER_VERSION_NOT_FOUND');
        }
        if (loader === ModLoaderType.FABRIC && args['withFabricApi'] !== false) {
          const companion = await port.companion(game);
          if (!current()) return reply('needsUser','LAUNCHER_CHANGED');
          if (companion === null) return reply('needsUser','FABRIC_API_UNAVAILABLE');
          api = companion.version;
          apiIcon = companion.iconUrl;
        }
      }
      if (versionInstallNameError(root, name) || !freshTarget(port, root, name)) return reply('rejected', 'TARGET_UNAVAILABLE');
      const task = 'mc:' + name;
      if (port.registry.get(task) !== null) return reply('rejected', 'TASK_ALREADY_EXISTS');
      const path = dir + '/version-' + request + '.json';
      // 派发前持久捕获请求。崩溃窗口仅能报告未知，绝不从同名目录推断本轮安装成功。
      if (fs.accessSync(path)) return reply('unknown', 'REQUEST_ALREADY_RECORDED');
      const ref: InstallReference = { request: request, game: game, target: name, root: root, loader: loader ?? 'vanilla', loaderVersion: loaderVer, activity: 0,
        companionRequired: api !== null, companionActivity: 0, companionDispatchFailed: false };
      writeEvidenceTextAtomic(path, JSON.stringify(ref));
      let installation: VersionInstallation;
      try { installation = port.install(game, name, loader, loaderVer, api, apiIcon); }
      catch (_) { return reply('rejected', 'INSTALL_NOT_ADMITTED'); }
      const adapter = installation.adapter;
      if (port.registry.getAdapter(task) !== adapter) return reply('rejected', 'INSTALL_NOT_ADMITTED');
      ProductQaVersions.live.set(request, adapter);
      // 排队状态可能尚无活动。监听生产队列，第一次分配 ID 即固定，不追随后续 UI 重试。
      const bindActivity = (): void => {
        if (port.registry.getAdapter(task) !== adapter || session() !== dir) {
          port.registry.removeListener(bindActivity);
          return;
        }
        if (adapter.startedAtMs <= 0) return;
        ref.activity = adapter.startedAtMs;
        try { writeEvidenceTextAtomic(path, JSON.stringify(ref)); }
        catch (_) { /* 未持久关联时，跨进程读取保持未知。 */ }
        port.registry.removeListener(bindActivity);
      };
      port.registry.addListener(bindActivity);
      bindActivity();
      if (ref.companionRequired && installation.companion !== undefined) {
        ProductQaVersions.trackCompanion(port, ref, installation.companion, path, dir, session);
      }
      const initial = ref.companionRequired && adapter.view.state === UnifiedTaskState.DONE ? UnifiedTaskState.WAITING : adapter.view.state;
      return reply('accepted', '', taskData(ref, initial, adapter.view.bytesDone, adapter.view.bytesTotal));
    } catch (_) { return reply('unknown', 'PRODUCT_OBSERVATION_UNAVAILABLE'); }
  }

  /** 只跟随父操作返回的精确子对象。异步入队被拒时永久记录失败，在途失联时保持未知。 */
  private static trackCompanion(port: LauncherVersionAccess, ref: InstallReference, pending: Promise<VersionCompanionTask>,
    path: string, dir: string, session: () => string): void {
    const save = (): void => {
      if (session() !== dir) return;
      try { writeEvidenceTextAtomic(path, JSON.stringify(ref)); } catch (_) { /* 没有原件就不给冷恢复资格。 */ }
    };
    const fail = (): void => { ref.companionDispatchFailed = true; save(); };
    pending.then((child: VersionCompanionTask): void => {
      if (session() !== dir) return;
      const view = child.view;
      ProductQaVersions.children.set(ref.request, view);
      const bind = (): void => {
        if (session() !== dir || port.registry.get(view.id) !== view) {
          port.registry.removeListener(bind); return;
        }
        if (view.startedAtMs <= 0 || ref.activity <= 0) return;
        if (view.parentActivityId === ref.activity && view.activityRelation === 'companion'
          && view.activityMcDir === ref.root && view.activityGameVersion === ref.target && view.title === 'Fabric API') {
          ref.companionActivity = view.startedAtMs; save();
        }
        port.registry.removeListener(bind);
      };
      port.registry.addListener(bind);
      bind();
      child.completion.then((): void => {
        bind(); port.registry.removeListener(bind);
        if (session() === dir) ProductQaVersions.completedChildren.add(ref.request);
      },
        (): void => { bind(); port.registry.removeListener(bind); fail(); });
    }).catch(fail);
  }

  /** 要求伴随安装时，父库已提交仅代表进入子步骤。成功必须归属到父活动和原子尝试。 */
  private static projection(port: LauncherVersionAccess, ref: InstallReference, parentState: string,
    bytesDone: number, bytesTotal: number, liveParent: boolean): string {
    if (parentState !== UnifiedTaskState.DONE || !ref.companionRequired) return reply('ok','',taskData(ref,parentState,bytesDone,bytesTotal));
    if (ref.companionDispatchFailed) return reply('ok','',taskData(ref,UnifiedTaskState.ERROR,bytesDone,bytesTotal));
    const child = ProductQaVersions.children.get(ref.request);
    if (child !== undefined && port.registry.get(child.id) === child && ref.activity > 0
      && child.parentActivityId === ref.activity && child.startedAtMs === ref.companionActivity
      && child.activityRelation === 'companion' && child.activityMcDir === ref.root && child.activityGameVersion === ref.target) {
      // 未分配子活动的 waiting 可以展示；终态的证据需要非零的确切活动 ID。
      if (child.state !== UnifiedTaskState.DONE) return reply('ok','',taskData(ref,child.state,child.bytesDone,child.bytesTotal));
      if (ref.companionActivity > 0) {
        const state = ProductQaVersions.completedChildren.has(ref.request) ? UnifiedTaskState.DONE : UnifiedTaskState.VERIFYING;
        return reply('ok','',taskData(ref,state,child.bytesDone,child.bytesTotal));
      }
    }
    if (!ref.companionActivity) return liveParent
      ? reply('ok','',taskData(ref,UnifiedTaskState.WAITING,bytesDone,bytesTotal)) : reply('unknown','COMPANION_ACTIVITY_UNAVAILABLE');
    const m = ledgerManifest(port.filesDir, ref.companionActivity);
    if (m === null || m.activityId !== ref.companionActivity || m.parentActivityId !== ref.activity || m.relation !== 'companion'
      || m.title !== 'Fabric API' || m.mcDir !== ref.root || m.gameVersionId !== ref.target || m.category !== 'mod_install'
      || m.outcomeSource !== 'task.owner') return reply('unknown','COMPANION_ACTIVITY_UNAVAILABLE');
    let state = '';
    if (m.state === LedgerState.SUCCESS) state = UnifiedTaskState.DONE;
    if (m.state === LedgerState.FAILED) state = UnifiedTaskState.ERROR;
    if (m.state === LedgerState.ABORTED) state = UnifiedTaskState.ABORTED;
    return state ? reply('ok','',taskData(ref,state,m.taskFacts?.totalBytes ?? 0,0)) : reply('unknown','COMPANION_ACTIVITY_UNAVAILABLE');
  }

  /** 只认原适配器或原活动的业务结局，不把同名任务、进程消失或残留 JAR 认作成功。 */
  private static observe(port: LauncherVersionAccess, dir: string, args: Record<string, Object>): string {
    const id = stringArg(args, 'installRequestId');
    const task = stringArg(args, 'taskId');
    if (!only(args, ['installRequestId','taskId']) || !validRequest(id) || !task) return reply('rejected', 'INVALID_ARGUMENTS');
    const path = dir + '/version-' + id + '.json';
    if (!fs.accessSync(path)) return reply('unknown', 'ORIGINAL_REQUEST_UNAVAILABLE');
    const stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 8192) return reply('unknown', 'INVALID_REQUEST_RECORD');
    const ref = JSON.parse(fs.readTextSync(path)) as InstallReference;
    if (!validRef(ref, id, task)) return reply('rejected', 'TASK_IDENTITY_MISMATCH');
    const adapter = ProductQaVersions.live.get(id);
    if (adapter !== undefined && port.registry.getAdapter(task) === adapter
      && ref.activity === adapter.startedAtMs) {
      const view = adapter.view;
      return ProductQaVersions.projection(port, ref, view.state, view.bytesDone, view.bytesTotal, true);
    }
    const m = ref.activity > 0 ? ledgerManifest(port.filesDir, ref.activity) : null;
    if (m === null || m.activityId !== ref.activity || m.mcDir !== ref.root || m.gameVersionId !== ref.game
      || m.loaderType !== ref.loader || m.loaderVersion !== ref.loaderVersion || m.title !== ref.target || m.category !== ActivityCategory.DOWNLOAD
      || m.outcomeSource !== 'task.owner') return reply('unknown', 'ORIGINAL_TASK_UNAVAILABLE');
    let state = '';
    if (m.state === LedgerState.SUCCESS) state = UnifiedTaskState.DONE;
    if (m.state === LedgerState.FAILED) state = UnifiedTaskState.ERROR;
    if (m.state === LedgerState.ABORTED) state = UnifiedTaskState.ABORTED;
    if (state.length === 0) return reply('unknown', 'ORIGINAL_TASK_UNAVAILABLE');
    return ProductQaVersions.projection(port, ref, state, m.taskFacts?.totalBytes ?? 0, 0, false);
  }
}

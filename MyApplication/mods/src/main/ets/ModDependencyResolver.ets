/** Dependency plans retain exact file identities and every incoming edge. */
import { ModSource, DependencyType, RemoteProject, RemoteVersion, RemoteFile, RemoteDependency,
  LocalMod, ModIntegrity, pickLatestModVersion, pickPrimaryFile } from './ModTypes';
import { ModSourceRouter } from './ModSourceRouter';

export type ProjectFetcher = (source: ModSource, id: string) => Promise<RemoteProject>;
export type VersionsFetcher = (source: ModSource, id: string, loaders: string[], games: string[]) => Promise<RemoteVersion[]>;
export type VersionByIdFetcher = (source: ModSource, id: string) => Promise<RemoteVersion>;

export interface ResolveOptions {
  gameVersion: string;
  loader: string;
  installed: LocalMod[];
  maxDepth?: number;
  /** Display optional rows. Only selectedOptionalIds expand their subtrees. */
  followOptional?: boolean;
  selectedOptionalIds?: string[];
}
export interface ResolvedDependency {
  dependencyType: DependencyType;
  parentProjectId: string;
  projectId: string;
  project: RemoteProject | null;
  version: RemoteVersion | null;
  alreadyInstalled: boolean;
  errorMessage: string | null;
  compatWarning: string | null;
  selected?: boolean;
}
export interface ResolveResult {
  primary: RemoteVersion;
  dependencies: ResolvedDependency[];
  conflicts: ResolvedDependency[];
  depthExceeded: boolean;
  hasCompatWarning: boolean;
}
interface PendingDependency {
  source: ModSource;
  parent: string;
  dep: RemoteDependency;
  depth: number;
}
interface ResolvePass { result: ResolveResult; pins: Map<string, string>; }

export function isModVersionCompatible(v: RemoteVersion, loader: string, game: string): boolean {
  const loaderOk = loader.length === 0 || v.loaders.indexOf(loader) >= 0
    || (loader === 'quilt' && v.loaders.indexOf('fabric') >= 0);
  return loaderOk && (game.length === 0 || v.gameVersions.indexOf(game) >= 0);
}
export function pickBestVersion(versions: RemoteVersion[], loader: string, game: string): RemoteVersion | null {
  return pickLatestModVersion(versions.filter((v: RemoteVersion): boolean => isModVersionCompatible(v, loader, game)));
}
export function isProjectInstalled(source: ModSource, id: string, installed: LocalMod[], versionId: string = ''): boolean {
  return installed.some((m: LocalMod): boolean => m.enabled && id.length > 0 && m.remoteSource === source
    && m.remoteProjectId === id && (m.remoteVersionId ?? '').length > 0
    && (versionId.length === 0 || m.remoteVersionId === versionId)
    && (m.integrity === ModIntegrity.VERIFIED || m.integrity === ModIntegrity.LINKED));
}
function samePins(a: Map<string, string>, b: Map<string, string>): boolean {
  if (a.size !== b.size) return false;
  let equal = true;
  a.forEach((v: string, k: string): void => { if (b.get(k) !== v) equal = false; });
  return equal;
}
export function dependencyPlanErrors(plan: ResolveResult): string[] {
  const errors: string[] = [];
  for (const d of plan.dependencies) {
    if (d.selected === false || (d.dependencyType === DependencyType.OPTIONAL && d.selected !== true)) continue;
    if (d.errorMessage !== null) errors.push((d.project?.title ?? d.projectId) + '：' + d.errorMessage);
    else if (!d.alreadyInstalled && (d.version === null || pickPrimaryFile(d.version.files) === null))
      errors.push((d.project?.title ?? d.projectId) + ' 没有可下载文件');
  }
  for (const c of plan.conflicts) errors.push(c.errorMessage ?? ('依赖冲突：' + c.projectId));
  if (plan.depthExceeded) errors.push('依赖图超出解析深度，尚未完成');
  return errors;
}

export class ModDependencyResolver {
  private projectFetcher_: ProjectFetcher;
  private versionsFetcher_: VersionsFetcher;
  private versionByIdFetcher_: VersionByIdFetcher | undefined;
  constructor(projectFetcher: ProjectFetcher, versionsFetcher: VersionsFetcher, exact?: VersionByIdFetcher) {
    this.projectFetcher_ = projectFetcher;
    this.versionsFetcher_ = versionsFetcher;
    this.versionByIdFetcher_ = exact;
  }
  async resolve(root: RemoteVersion, opt: ResolveOptions): Promise<ResolveResult> {
    let pins = new Map<string, string>();
    // Rebuild after a later edge pins an unpinned project, discarding the superseded subtree.
    for (let pass = 0; pass < 16; pass++) {
      const next = await this.resolvePass(root, opt, pins);
      if (samePins(pins, next.pins)) return next.result;
      pins = next.pins;
    }
    throw new Error('依赖版本要求无法收敛，请检查相互矛盾的指定版本');
  }
  private async exact(source: ModSource, projectId: string, id: string): Promise<RemoteVersion> {
    if (this.versionByIdFetcher_ === undefined) throw new Error('无法解析指定依赖版本 ' + id);
    const key = source === ModSource.CURSEFORGE && id.indexOf('/') < 0 ? projectId + '/' + id : id;
    return this.versionByIdFetcher_(source, key);
  }
  private async choose(item: PendingDependency, pid: string, pin: string, opt: ResolveOptions): Promise<RemoteVersion> {
    if (pin.length > 0) return this.exact(item.source, pid, pin);
    const local = opt.installed.find((m: LocalMod): boolean => isProjectInstalled(item.source, pid, [m]));
    if (local !== undefined && this.versionByIdFetcher_ !== undefined) {
      const existing = await this.exact(item.source, pid, local.remoteVersionId ?? '');
      if (isModVersionCompatible(existing, opt.loader, opt.gameVersion)) return existing;
    }
    const loaders = opt.loader.length > 0 ? [opt.loader] : [];
    const games = opt.gameVersion.length > 0 ? [opt.gameVersion] : [];
    const candidates = await this.versionsFetcher_(item.source, pid, loaders, games);
    const picked = pickBestVersion(candidates, opt.loader, opt.gameVersion);
    if (picked === null) throw new Error('没有匹配 ' + opt.loader + ' / MC ' + opt.gameVersion + ' 的版本');
    return picked;
  }
  private async resolvePass(root: RemoteVersion, opt: ResolveOptions, hints: Map<string, string>): Promise<ResolvePass> {
    const result: ResolveResult = { primary: root, dependencies: [], conflicts: [], depthExceeded: false, hasCompatWarning: false };
    const pins = new Map<string, string>();
    const rows = new Map<string, ResolvedDependency>();
    const expanded = new Set<string>();
    const queue: PendingDependency[] = [];
    for (const d of root.dependencies) queue.push({ source: root.source, parent: root.projectId, dep: d, depth: 1 });
    const maxDepth = opt.maxDepth ?? 8;
    for (let head = 0; head < queue.length; head++) {
      if (queue.length > 2048) throw new Error('依赖图过大，安装计划未完成');
      const item = queue[head];
      const dep = item.dep;
      if (dep.dependencyType === DependencyType.EMBEDDED) continue;
      let pid = dep.projectId ?? '';
      const pin = dep.versionId ?? '';
      const optional = dep.dependencyType === DependencyType.OPTIONAL;
      let selected = !optional || (opt.selectedOptionalIds ?? []).indexOf(pid) >= 0;
      const row: ResolvedDependency = { dependencyType: dep.dependencyType, parentProjectId: item.parent, projectId: pid,
        project: null, version: null, alreadyInstalled: false, errorMessage: null, compatWarning: null, selected: selected };
      try {
        if (item.depth > maxDepth) { if (selected) result.depthExceeded = true; throw new Error('依赖层数超过 ' + maxDepth); }
        let exact: RemoteVersion | undefined;
        if (pid.length === 0 && pin.length > 0) { exact = await this.exact(item.source, '', pin); pid = exact.projectId; row.projectId = pid; }
        selected = !optional || (opt.selectedOptionalIds ?? []).indexOf(pid) >= 0;
        row.selected = selected;
        if (pid.length === 0) throw new Error('依赖缺少项目和版本标识：' + (dep.fileName ?? '?'));
        const key = item.source + ':' + pid;
        if (dep.dependencyType === DependencyType.INCOMPATIBLE) {
          const local = opt.installed.some((m: LocalMod): boolean => m.enabled && m.remoteSource === item.source
            && m.remoteProjectId === pid && (pin.length === 0 || m.remoteVersionId === pin));
          if (local) { row.errorMessage = item.parent + ' 与已启用的 ' + pid + ' 冲突'; result.conflicts.push(row); }
          continue;
        }
        if (pid === root.projectId && item.source === root.source) {
          if (pin.length > 0 && pin !== root.id) { row.errorMessage = '循环依赖要求主模组的另一个版本：' + pin; result.conflicts.push(row); }
          continue;
        }
        if (selected && pin.length > 0) {
          const previousPin = pins.get(key);
          if (previousPin !== undefined && previousPin !== pin) throw new Error('同一前置被要求使用不同指定版本：' + previousPin + ' / ' + pin);
          pins.set(key, pin);
        }
        const previous = rows.get(key);
        if (previous !== undefined && (!selected || previous.selected === true)) {
          if (selected && pin.length > 0 && previous.version !== null && previous.version.id !== pin && hints.get(key) === pin)
            throw new Error('依赖版本与指定版本不一致：' + pin);
          continue;
        }
        if (optional && !selected && opt.followOptional !== true) { rows.set(key, row); result.dependencies.push(row); continue; }
        row.project = await this.projectFetcher_(item.source, pid);
        const effectivePin = pin.length > 0 ? pin : (hints.get(key) ?? '');
        const chosen = exact ?? await this.choose(item, pid, effectivePin, opt);
        if (chosen.projectId !== pid || chosen.source !== item.source) throw new Error('依赖返回了错误的项目或来源');
        if (!isModVersionCompatible(chosen, opt.loader, opt.gameVersion))
          throw new Error('指定版本 ' + chosen.versionNumber + ' 不支持 ' + opt.loader + ' / MC ' + opt.gameVersion);
        if (pickPrimaryFile(chosen.files) === null) throw new Error('指定版本没有可下载主文件');
        row.version = chosen;
        row.alreadyInstalled = isProjectInstalled(item.source, pid, opt.installed, chosen.id);
        if (previous !== undefined) {
          const index = result.dependencies.indexOf(previous);
          if (index >= 0) result.dependencies.splice(index, 1);
        }
        rows.set(key, row); result.dependencies.push(row);
        const expandKey = key + '@' + chosen.id;
        if (selected && !expanded.has(expandKey)) {
          expanded.add(expandKey);
          for (const child of chosen.dependencies) queue.push({ source: item.source, parent: pid, dep: child, depth: item.depth + 1 });
        }
      } catch (e) {
        row.errorMessage = e instanceof Error ? e.message : String(e);
        result.dependencies.push(row);
      }
    }
    for (const item of queue) {
      if (item.dep.dependencyType !== DependencyType.INCOMPATIBLE) continue;
      const row = rows.get(item.source + ':' + (item.dep.projectId ?? ''));
      if (row !== undefined && row.selected === true && ((item.dep.versionId ?? '').length === 0 || item.dep.versionId === row.version?.id)) {
        const conflict: ResolvedDependency = { dependencyType: DependencyType.INCOMPATIBLE, parentProjectId: item.parent,
          projectId: row.projectId, project: row.project, version: row.version, alreadyInstalled: row.alreadyInstalled,
          errorMessage: item.parent + ' 与 ' + row.projectId + ' 冲突', compatWarning: null, selected: true };
        result.conflicts.push(conflict);
      }
    }
    return { result: result, pins: pins };
  }
}
export function makeResolverFromRouter(router: ModSourceRouter): ModDependencyResolver {
  const projects: ProjectFetcher = async (s: ModSource, id: string): Promise<RemoteProject> => {
    const r = router.repoFor(s); if (r === null) throw new Error('没有对应的模组来源'); return r.getProject(id);
  };
  const versions: VersionsFetcher = async (s: ModSource, id: string, loaders: string[], games: string[]): Promise<RemoteVersion[]> => {
    const r = router.repoFor(s); if (r === null) throw new Error('没有对应的模组来源'); return r.getVersions(id, loaders, games);
  };
  const exact: VersionByIdFetcher = async (s: ModSource, id: string): Promise<RemoteVersion> => {
    const r = router.repoFor(s); if (r === null) throw new Error('没有对应的模组来源'); return r.getVersion(id);
  };
  return new ModDependencyResolver(projects, versions, exact);
}
export function extractDependencyFiles(deps: ResolvedDependency[]): RemoteFile[] {
  const files: RemoteFile[] = [];
  for (const d of deps) {
    if (d.selected === false || (d.dependencyType === DependencyType.OPTIONAL && d.selected !== true)) continue;
    if (d.errorMessage !== null) throw new Error(d.projectId + '：' + d.errorMessage);
    if (d.alreadyInstalled) continue;
    const file = d.version === null ? null : pickPrimaryFile(d.version.files);
    if (file === null) throw new Error('必需依赖没有可下载文件：' + d.projectId);
    files.push(file);
  }
  return files;
}

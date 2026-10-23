/**
 * 本地模组更新候选策略。
 *
 * 一轮列表检查通过 ModUpdateSession 共享已装版本请求和反向依赖索引，避免对 N 个模组
 * 分别重读其余 N 个已装版本。会话仅属于创建时的已装集合快照；扫描、安装或启禁后应
 * 新建会话，不把旧约束带到下一轮。这里只筛选远程候选，不修改本地文件或远程版本。
 */
import { LocalMod, ModSource, RemoteVersion, DependencyType, versionChannelRank, compareModVersionFreshness, pickLatestModVersion } from './ModTypes';
import { ModSourceRouter } from './ModSourceRouter';

/** 一轮检查是否已失效；由页面按自身生命周期提供，不要求仓库实现网络中止接口。 */
export type ModUpdateCancelChecker = () => boolean;

/** 已启用且具有完整远程身份的条目快照，避免异步等待期间被调用方修改。 */
interface InstalledModUpdateIdentity {
  project: string;
  version: string;
}

/** 指向目标项目的约束；保留声明者项目，以继续排除目标项目自身的声明。 */
interface ModUpdateConstraint {
  ownerProject: string;
  dependencyType: DependencyType;
  pin: string;
}

/**
 * 一个来源的一次索引构建状态。worker 只在当前 JS 事件循环里领取下标和追加约束，
 * await 之间没有共享内存线程写入；失败后停止领取新项，等待已发请求结束再发布失败。
 */
class ModUpdateSourceState {
  next: number = 0;
  error: Error | null = null;
  constraints: Map<string, ModUpdateConstraint[]> = new Map<string, ModUpdateConstraint[]>();
}

/** 每个来源最多用三个 worker 获取依赖元数据，避免首个候选把整包请求一次性展开。 */
const MOD_UPDATE_INDEX_WORKERS: number = 3;

/**
 * 当前已装集合的更新检查会话。
 *
 * 具体版本的 Promise 在发起请求时立即入缓存，成功对象和失败结果都复用；并发 pick
 * 与索引 worker 因而不会重复读取同一版本。反向索引按来源分别构建、分别失败：同源
 * 任一启用项的信息缺失时不能证明它没有精确 pin，因此该来源建议保持未知并抛错，
 * 另一来源仍可独立检查，不能因为网络失败而悄悄放宽已有依赖要求。
 */
export class ModUpdateSession {
  private router: ModSourceRouter;
  private isCanceled: ModUpdateCancelChecker | undefined;
  private installedBySource: Map<ModSource, InstalledModUpdateIdentity[]> =
    new Map<ModSource, InstalledModUpdateIdentity[]>();
  private versions: Map<string, Promise<RemoteVersion>> = new Map<string, Promise<RemoteVersion>>();
  private sourceIndexes: Map<ModSource, Promise<ModUpdateSourceState>> =
    new Map<ModSource, Promise<ModUpdateSourceState>>();

  /** 只复制约束需要的启用态/来源/项目/具体版本，构造阶段不发起网络请求。 */
  constructor(installed: LocalMod[], router: ModSourceRouter, isCanceled?: ModUpdateCancelChecker) {
    this.router = router;
    this.isCanceled = isCanceled;
    const seen: Set<string> = new Set<string>();
    for (const mod of installed) {
      const source = mod.remoteSource;
      const project = mod.remoteProjectId ?? '';
      const version = mod.remoteVersionId ?? '';
      if (!mod.enabled || source === undefined || project.length === 0 || version.length === 0) continue;
      // 相同项目/版本的重复文件只登记一次；不同声明者仍分别保留自项目排除语义。
      const key = source + '\u0000' + project + '\u0000' + version;
      if (seen.has(key)) continue;
      seen.add(key);
      let identities = this.installedBySource.get(source);
      if (identities === undefined) {
        identities = [];
        this.installedBySource.set(source, identities);
      }
      identities.push({ project: project, version: version });
    }
  }

  /**
   * 为指定已装版本选择更新，参数含义与旧 pickModUpdate 的前四项相同。
   * 保留“确实更新、通道不更不稳定、同源启用项的 required 精确 pin / incompatible”
   * 规则；无候选返回 null，信息不足或已取消抛错，由调用方把该行标记为未知。
   */
  async pick(source: ModSource, project: string, installedId: string,
    versions: RemoteVersion[]): Promise<RemoteVersion | null> {
    this.checkCanceled();
    const current = await this.installedVersion(source, project, installedId);
    this.checkCanceled();
    let candidates = versions.filter((v: RemoteVersion): boolean =>
      v.id !== current.id && compareModVersionFreshness(v, current) > 0
        && versionChannelRank(v.versionType) <= versionChannelRank(current.versionType));
    if (candidates.length === 0) return null;

    const index = await this.sourceIndex(source);
    this.checkCanceled();
    const constraints = index.constraints.get(project);
    if (constraints !== undefined) {
      for (const constraint of constraints) {
        // 原策略不让目标项目自身的依赖声明约束自身，重复本地版本也遵循此规则。
        if (constraint.ownerProject === project) continue;
        if (constraint.dependencyType === DependencyType.REQUIRED) {
          candidates = candidates.filter((v: RemoteVersion): boolean => v.id === constraint.pin);
        } else if (constraint.dependencyType === DependencyType.INCOMPATIBLE) {
          candidates = candidates.filter((v: RemoteVersion): boolean =>
            constraint.pin.length > 0 && v.id !== constraint.pin);
        }
        if (candidates.length === 0) return null;
      }
    }
    return pickLatestModVersion(candidates);
  }

  /**
   * 缓存键对应真实仓库请求：Modrinth 具体版本全局唯一，不因本地项目别名重读；
   * CurseForge 路径包含项目，仍区分 project/fileId，并始终隔离两种来源。
   */
  private versionKey(source: ModSource, project: string, version: string): string {
    return source + '\u0000' + (source === ModSource.CURSEFORGE ? project + '/' : '') + version;
  }

  /**
   * 先存进行中的 Promise，再允许调用方等待；同轮失败也不重新请求，避免多行同时
   * 遇到同一损坏来源记录时反复超时。会话结束后由调用方释放整个会话及其缓存。
   */
  private installedVersion(source: ModSource, project: string, version: string): Promise<RemoteVersion> {
    this.checkCanceled();
    const key = this.versionKey(source, project, version);
    const cached = this.versions.get(key);
    if (cached !== undefined) return cached;
    const request = this.fetchInstalledVersion(source, project, version);
    this.versions.set(key, request);
    return request;
  }

  /** 仓库接口保持旧路径约定：CurseForge 使用 project/fileId，Modrinth 使用 versionId。 */
  private async fetchInstalledVersion(source: ModSource, project: string, version: string): Promise<RemoteVersion> {
    const repo = this.router.repoFor(source);
    if (repo === null) throw new Error('模组来源不可用');
    return repo.getVersion(source === ModSource.CURSEFORGE ? project + '/' + version : version);
  }

  /** 每个来源只发布一个构建 Promise；拒绝结果仍保留，其他行不会重新遍历整个包。 */
  private sourceIndex(source: ModSource): Promise<ModUpdateSourceState> {
    this.checkCanceled();
    const cached = this.sourceIndexes.get(source);
    if (cached !== undefined) return cached;
    const request = this.buildSourceIndex(source);
    this.sourceIndexes.set(source, request);
    return request;
  }

  /**
   * 已装身份只在此遍历一次，把“声明者 -> 依赖”转为“目标项目 -> 所有声明者约束”。
   * 并发保持固定上限；Promise.all 等待的是最多三个 worker，而不是 N 个网络请求。
   */
  private async buildSourceIndex(source: ModSource): Promise<ModUpdateSourceState> {
    const state = new ModUpdateSourceState();
    const installed = this.installedBySource.get(source) ?? [];
    const workers: Promise<void>[] = [];
    const count = Math.min(MOD_UPDATE_INDEX_WORKERS, installed.length);
    for (let i = 0; i < count; i++) workers.push(this.buildSourceWorker(source, installed, state));
    await Promise.all(workers);
    this.checkCanceled();
    if (state.error !== null) throw state.error;
    return state;
  }

  /**
   * 领取一个身份、复用具体版本、登记其精确约束。失败会关闭本来源的建议，不能把
   * 读取失败当作“无依赖”；已发出的请求由仓库正常收尾，之后不再继续领取新项。
   */
  private async buildSourceWorker(source: ModSource, installed: InstalledModUpdateIdentity[],
    state: ModUpdateSourceState): Promise<void> {
    while (state.error === null && state.next < installed.length) {
      try {
        this.checkCanceled();
        const identity = installed[state.next++];
        const version = await this.installedVersion(source, identity.project, identity.version);
        this.checkCanceled();
        for (const dependency of version.dependencies) {
          const target = dependency.projectId ?? '';
          const pin = dependency.versionId ?? '';
          if (target.length === 0) continue;
          if (dependency.dependencyType !== DependencyType.INCOMPATIBLE
            && (dependency.dependencyType !== DependencyType.REQUIRED || pin.length === 0)) continue;
          let constraints = state.constraints.get(target);
          if (constraints === undefined) {
            constraints = [];
            state.constraints.set(target, constraints);
          }
          constraints.push({ ownerProject: identity.project, dependencyType: dependency.dependencyType, pin: pin });
        }
      } catch (e) {
        if (state.error === null) state.error = e as Error;
      }
    }
  }

  /** 取消只阻止后续请求与结果发布；仓库没有 abort 契约，不能声称中止在途 HTTP。 */
  private checkCanceled(): void {
    if (this.isCanceled !== undefined && this.isCanceled()) throw new Error('模组更新检查已取消');
  }
}

/** 一次扫描创建一个会话供全部行复用；启禁、安装、换版本或重扫时应重新创建。 */
export function createModUpdateSession(installed: LocalMod[], router: ModSourceRouter,
  isCanceled?: ModUpdateCancelChecker): ModUpdateSession {
  return new ModUpdateSession(installed, router, isCanceled);
}

/**
 * 单项调用的兼容入口，保留原参数和返回类型。列表检查应显式共享会话；旧调用方无需
 * 改参数即可继续使用相同的版本筛选与依赖规则，且不会与别的扫描轮次串用缓存。
 */
export async function pickModUpdate(source: ModSource, project: string, installedId: string,
  versions: RemoteVersion[], installed: LocalMod[], router: ModSourceRouter): Promise<RemoteVersion | null> {
  return createModUpdateSession(installed, router).pick(source, project, installedId, versions);
}

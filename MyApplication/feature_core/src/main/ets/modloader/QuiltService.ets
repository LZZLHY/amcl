/**
 * Quilt 官方 Meta v3 安装服务：获取客户端 profile，验证精确游戏/加载器身份，复用
 * Maven 原子下载事务安装全部依赖，最后在调用方独占沙箱中发布版本 JSON。
 * 不运行 installer/JVM，不把 Quilt 降级为 Fabric。取消由 ModloaderPhase 的进度
 * 回调抛出；每次 await 后及发布前都再次经过回调，依赖下载等待真实 owner 收敛。
 * 官方接口契约：https://meta.quiltmc.org/（/v3/versions/.../profile/json）。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger, LOG_DOMAIN_MODLOADER } from 'commons';
import { fetchPublicMcMetadata, useOrderedMcDownload } from '../download/SourceProber';
import { ModLoaderType, ModLoaderVersion, ModLoaderInstallCallback, ModLoaderInstallResult,
  IModLoaderService } from './ModLoaderTypes';
import { MavenLibEntry, downloadMavenLibraries, selectFailedLibs, safeBaseName,
  mavenToRelativePath, isSafeHttpUrl, isValidSha1, computeFileSha1 } from './MavenUtils';
import { buildMavenUrls } from './MavenSpecBuilder';

const TAG: string = 'QuiltService';
const QUILT_META: string = 'https://meta.quiltmc.org/v3/versions';

interface QuiltGameVersion { version: string; stable?: boolean; }
interface QuiltLoaderVersion { version: string; stable?: boolean; }
interface QuiltLoaderForGame { loader: QuiltLoaderVersion; }
interface QuiltArguments { game?: string[]; jvm?: string[]; }
interface QuiltProfile {
  id: string;
  inheritsFrom: string;
  mainClass: string;
  type?: string;
  arguments?: QuiltArguments;
  libraries: MavenLibEntry[];
}
export interface QuiltVersionIdInfo { loaderVersion: string; gameVersion: string; }

/** 独立缓存不与 Fabric 共享，避免把相同的 MC 标签误当作两种加载器的等价支持证据。 */
export class QuiltService implements IModLoaderService {
  private games_: string[] | null = null;
  private loaders_: Map<string, ModLoaderVersion[]> = new Map<string, ModLoaderVersion[]>();

  /** 官方游戏版本只读列表；失败向调用方传播，不缓存空结果作为永久不支持证据。 */
  async getSupportedGameVersions(): Promise<string[]> {
    if (this.games_ !== null) return this.games_.slice();
    // Quilt官方公开Meta GET显式允许relay；未知作者/带凭据的动态地址仍由共享边界直连。
    const text = await fetchPublicMcMetadata([QUILT_META + '/game']);
    const entries = JSON.parse(text) as QuiltGameVersion[];
    if (!Array.isArray(entries)) throw new Error('Quilt 游戏版本响应不是数组');
    const games: string[] = [];
    for (const entry of entries) {
      if (entry !== null && typeof entry.version === 'string' && safeBaseName(entry.version) === entry.version) games.push(entry.version);
    }
    this.games_ = games;
    return games.slice();
  }

  /** 精确游戏版本对应的 loader 列表；稳定状态由明确字段或版本预发布后缀确定。 */
  async getLoaderVersions(gameVersion: string): Promise<ModLoaderVersion[]> {
    this.requireSegment_(gameVersion, 'Minecraft');
    const cached = this.loaders_.get(gameVersion);
    if (cached !== undefined) return cached.slice();
    const text = await fetchPublicMcMetadata([QUILT_META + '/loader/' + encodeURIComponent(gameVersion)]);
    const entries = JSON.parse(text) as QuiltLoaderForGame[];
    if (!Array.isArray(entries)) throw new Error('Quilt 加载器版本响应不是数组');
    const versions: ModLoaderVersion[] = [];
    for (const entry of entries) {
      if (entry === null || entry.loader === undefined || entry.loader === null) continue;
      const version = entry.loader.version;
      if (typeof version !== 'string' || safeBaseName(version) !== version) continue;
      versions.push({ loader: ModLoaderType.QUILT, loaderVersion: version, gameVersion: gameVersion,
        stable: entry.loader.stable ?? !/[-+](alpha|beta|rc)/i.test(version), displayName: 'Quilt ' + version });
    }
    this.loaders_.set(gameVersion, versions);
    return versions.slice();
  }

  /**
   * 所有路径来自安全版本段与调用方独占沙箱。必须先验证 profile、补齐每个 Maven
   * 摘要，再下载并复核真实文件；任一步失败或取消均不发布最终 JSON。旧最终文件不同
   * 时拒绝覆盖；暂存写入完成并 fsync 后同目录 rename，沙箱生命周期仍由父任务管理。
   */
  async install(gameVersion: string, loaderVersion: string, mcDir: string,
    callback?: ModLoaderInstallCallback, filesDirOverride?: string): Promise<ModLoaderInstallResult> {
    void filesDirOverride;
    const versionId = 'quilt-loader-' + loaderVersion + '-' + gameVersion;
    let staged: string = '';
    try {
      this.requireSegment_(gameVersion, 'Minecraft');
      this.requireSegment_(loaderVersion, 'Quilt Loader');
      this.requireSegment_(versionId, 'Quilt 实例');
      // 产品沙箱使用OHOS绝对路径。拒绝调用方把相对路径、反斜杠或点段带进目录创建，
      // 真实目录的链接准入仍在写入前检查，并由Native可信根打开契约兜底。
      if (!mcDir.startsWith('/') || mcDir.indexOf('\\') >= 0 || /[\x00-\x1f\x7f]/.test(mcDir)
        || mcDir.split('/').some((segment: string): boolean => segment === '.' || segment === '..')) throw new Error('Quilt 安装根路径不安全');
      this.progress_(callback, 'downloading_profile', 0, 3, '获取 Quilt 客户端配置');
      const text = await fetchPublicMcMetadata([QUILT_META + '/loader/'
        + encodeURIComponent(gameVersion) + '/' + encodeURIComponent(loaderVersion) + '/profile/json']);
      const profile = JSON.parse(text) as QuiltProfile;
      if (profile === null || profile.id !== versionId || profile.inheritsFrom !== gameVersion
        || profile.mainClass !== 'org.quiltmc.loader.impl.launch.knot.KnotClient' || !Array.isArray(profile.libraries)
        || profile.libraries.length === 0 || profile.libraries.length > 512) throw new Error('Quilt 客户端配置身份或依赖列表不符');
      if (!profile.libraries.some((lib: MavenLibEntry): boolean => lib !== null
        && lib.name === 'org.quiltmc:quilt-loader:' + loaderVersion)) throw new Error('Quilt 配置缺少所选加载器依赖');

      // profile 常无摘要，逐库从相同已登记 Maven 候选获取 .sha1；不把零校验下载当成功。
      const libs: MavenLibEntry[] = [];
      for (const lib of profile.libraries) {
        this.progress_(callback, 'downloading_libraries', 1, 3, '校验 Quilt 依赖元数据');
        if (lib === null || typeof lib.name !== 'string' || mavenToRelativePath(lib.name).length === 0
          || typeof lib.url !== 'string' || !lib.url.startsWith('https://') || !isSafeHttpUrl(lib.url)) throw new Error('Quilt 依赖坐标或仓库不安全');
        if (lib.size !== undefined && (!Number.isSafeInteger(lib.size) || lib.size < 0)) throw new Error('Quilt 依赖大小无效');
        if (lib.sha1 !== undefined && !isValidSha1(lib.sha1)) throw new Error('Quilt 依赖 SHA-1 无效');
        if (lib.sha1 === undefined) {
          const urls = buildMavenUrls(lib.name, lib.url, true).map((url: string): string => url + '.sha1');
          if (urls.length === 0) throw new Error('Quilt 依赖没有安全下载地址');
          const checksum = await fetchPublicMcMetadata(urls);
          const hash = checksum.trim().split(/\s+/)[0];
          if (!isValidSha1(hash)) throw new Error('Quilt 依赖摘要响应无效：' + lib.name);
          lib.sha1 = hash.toLowerCase();
        }
        libs.push(lib);
      }
      this.progress_(callback, 'downloading_libraries', 1, 3, '下载 Quilt 依赖库');
      this.ensureDirectory_(mcDir);
      const libDir = mcDir + '/libraries';
      this.ensureDirectory_(libDir);
      // 首轮固定本次安装的重试策略，设置变化不重新开启有序下载预算。
      const orderedVersionDownload = useOrderedMcDownload();
      let result = await downloadMavenLibraries(libs, libDir, (done: number, total: number, name: string): void => {
        this.progress_(callback, 'downloading_libraries', 1, 3, '下载 Quilt 依赖 (' + done + '/' + total + ') ' + name);
      }, true, orderedVersionDownload);
      this.progress_(callback, 'downloading_libraries', 1, 3, '验证 Quilt 依赖下载结果');
      if (result.failed > 0) {
        const retry: MavenLibEntry[] = orderedVersionDownload ? [] : selectFailedLibs(libs, result);
        if (retry.length > 0) result = await downloadMavenLibraries(retry, libDir, (): void => {
          this.progress_(callback, 'downloading_libraries', 1, 3, '重试 Quilt 缺失依赖');
        }, true, orderedVersionDownload);
        if (result.failed > 0) throw new Error('Quilt 依赖库下载失败：' + (result.failedNames ?? []).join(', '));
      }
      for (const lib of libs) {
        this.progress_(callback, 'downloading_libraries', 1, 3, '复核 Quilt 依赖：' + lib.name);
        const path = libDir + '/' + mavenToRelativePath(lib.name);
        const stat = fs.lstatSync(path);
        if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0
          || (await computeFileSha1(path)).toLowerCase() !== lib.sha1!.toLowerCase()) throw new Error('Quilt 依赖文件校验失败：' + lib.name);
      }
      this.progress_(callback, 'generating_json', 2, 3, '发布 Quilt 版本配置');
      this.ensureDirectory_(mcDir + '/versions');
      const versionDir = mcDir + '/versions/' + versionId;
      this.ensureDirectory_(versionDir);
      const destination = versionDir + '/' + versionId + '.json';
      const content = JSON.stringify(profile, null, 2);
      let exists = false;
      try { fs.lstatSync(destination); exists = true; } catch (_) { /* 不存在时才允许创建。 */ }
      if (exists) {
        const stat = fs.lstatSync(destination);
        if (!stat.isFile() || stat.isSymbolicLink() || fs.readTextSync(destination) !== content) throw new Error('Quilt 版本配置已存在不同内容，未覆盖');
      } else {
        staged = destination + '.writing-' + Date.now() + '-' + Math.floor(Math.random() * 1000000);
        const handle = fs.openSync(staged, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try { fs.writeSync(handle.fd, content); fs.fsyncSync(handle.fd); } finally { fs.closeSync(handle); }
        this.progress_(callback, 'generating_json', 2, 3, '完成 Quilt 配置校验');
        if (fs.readTextSync(staged) !== content) throw new Error('Quilt 配置写入不完整');
        fs.renameSync(staged, destination);
        staged = '';
      }
      this.progress_(callback, 'done', 3, 3, 'Quilt ' + loaderVersion + ' 安装完成');
      return { success: true, versionId: versionId };
    } catch (error) {
      const message = (error as Error).message ?? String(error);
      AppLogger.warn(TAG, 'Quilt 安装失败：' + message, error as Error, LOG_DOMAIN_MODLOADER);
      return { success: false, versionId: versionId, error: message };
    } finally {
      // 仅删除本次亲建且未发布的暂存；最终配置和用户目录均不进入失败清理范围。
      if (staged.length > 0) { try { fs.unlinkSync(staged); } catch (_) { /* 留给父沙箱收尾。 */ } }
    }
  }

  /** 只删除本服务规范 ID 的配置；目录含其他内容时 rmdir 失败，不能递归误删用户字节。 */
  async uninstall(versionId: string, mcDir: string): Promise<boolean> {
    if (QuiltService.parseQuiltVersionId(versionId) === null) return false;
    try {
      const dir = mcDir + '/versions/' + versionId;
      const stat = fs.lstatSync(dir);
      if (!stat.isDirectory() || stat.isSymbolicLink()) return false;
      fs.unlinkSync(dir + '/' + versionId + '.json');
      fs.rmdirSync(dir);
      return true;
    } catch (_) { return false; }
  }

  /** ID 解析只接受安全的两个版本段；以首个 '-' 分隔，保留 MC 快照/预发布后缀。 */
  static parseQuiltVersionId(versionId: string): QuiltVersionIdInfo | null {
    if (safeBaseName(versionId) !== versionId || !versionId.startsWith('quilt-loader-')) return null;
    const rest = versionId.substring('quilt-loader-'.length);
    // Loader 可有 -beta.N 后缀，MC 普通版以 -1. 开始；快照与新年份版用显式模式定位。
    const match = /-(1\.\d[^/]*|\d{2}w\d{2}[a-z]|\d{2}\.\d[^/]*)$/.exec(rest);
    if (match === null || match.index <= 0) return null;
    return { loaderVersion: rest.substring(0, match.index), gameVersion: match[1] };
  }

  /** 版本段不得承担URL/文件路径语义，拒绝后才构造官方端点及本地目录。 */
  private requireSegment_(value: string, label: string): void {
    if (typeof value !== 'string' || value.length === 0 || safeBaseName(value) !== value) throw new Error(label + ' 版本不安全');
  }
  /** 所有写入目录都拒绝现有链接；调用方负责独占沙箱，不在此接管既有安装事务。 */
  private ensureDirectory_(path: string): void {
    try { fs.mkdirSync(path, true); } catch (_) { /* 随后检查真实类型，不吞权限/文件冲突。 */ }
    const stat = fs.lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Quilt 安装目录不是普通目录');
  }
  /** 回调可抛出取消异常；不吞异常，以阻止后续网络请求、复制和配置发布。 */
  private progress_(callback: ModLoaderInstallCallback | undefined, phase: string, current: number,
    total: number, message: string): void {
    callback?.({ phase: phase, current: current, total: total, message: message });
  }
}

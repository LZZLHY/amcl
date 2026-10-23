/**
 * 运行时目录的唯一可信入口：HAP 内置快照 → 已验签缓存 → 有界 HTTPS 刷新。
 * 不依赖 App 更新开关，store 也可查询运行时。缓存失败不移除现有 JDK；
 * 私钥永不进入应用，公钥仅来自 HAP。所有消费者拿深拷贝，安装任务冻结旧快照。
 */
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { ensureDirSync, AppLogger } from 'commons';
import {
  RuntimeCatalog, RuntimeBuild, RuntimeDefinition, RuntimeSignedEnvelope, RuntimeProtectedHeader,
  RuntimeTrustedKeys, RuntimeRefreshResult
} from './RuntimeCatalogTypes';
import {
  RUNTIME_CATALOG_LIMIT, parseRuntimeCatalog, validateRuntimeTransition, supportsRuntime,
  requireCatalogObject, p1363ToDer
} from './RuntimeCatalogValidation';
import { runtimeBuildIdentity } from './RuntimeCatalogValidation';

const TAG: string = 'RuntimeCatalog';
const RAW_BASE: string = 'https://raw.githubusercontent.com/LZZLHY/mc-ohos-resources/main/catalog/v1/';
const WEB_BASE: string = 'https://amcl.lovedhy.cn/runtimes/catalog/v1/';

/** UTF-8 无效字节必须拒绝，不能把替换字符后的文本用于签名或 JSON 解释。 */
export function runtimeUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
}

/** JWS 的无 padding base64url 规范形式；禁止解码器宽松忽略无效字符。 */
export function runtimeDecode64(value: string): Uint8Array {
  if (typeof value !== 'string' || value.length === 0 || value.length > RUNTIME_CATALOG_LIMIT ||
    !new RegExp('^[A-Za-z0-9_-]+$').test(value) || value.length % 4 === 1) throw new Error('JWS 编码无效');
  const normal = value.replace(new RegExp('-', 'g'), '+').replace(new RegExp('_', 'g'), '/');
  const bytes = new util.Base64Helper().decodeSync(normal + '='.repeat((4 - normal.length % 4) % 4));
  const canonical = new util.Base64Helper().encodeToStringSync(bytes).replace(new RegExp('=', 'g'), '')
    .replace(new RegExp('\\+', 'g'), '-').replace(new RegExp('/', 'g'), '_');
  if (canonical !== value) throw new Error('JWS 编码不是规范形式');
  return bytes;
}

/** 固定 P-256/SHA-256 和 HAP 公钥，验证原始 protected.payload；不重新编码远程对象。 */
export async function verifyRuntimeEnvelope(raw: string, keys: RuntimeTrustedKeys, channel: string,
  allowExpired: boolean = false): Promise<RuntimeCatalog> {
  if (typeof raw !== 'string' || raw.length > RUNTIME_CATALOG_LIMIT) throw new Error('JDK 目录超过上限');
  const envelope = JSON.parse(raw) as RuntimeSignedEnvelope;
  requireCatalogObject(envelope, ['protected','payload','signature'], 'JWS');
  const header = JSON.parse(runtimeUtf8(runtimeDecode64(envelope.protected))) as RuntimeProtectedHeader;
  requireCatalogObject(header, ['alg','typ','kid'], 'JWS header');
  if (header.alg !== 'ES256' || header.typ !== 'amcl-runtime-catalog+jws') throw new Error('不支持的目录签名');
  const key = keys.keys.find((item): boolean => item.kid === header.kid && item.algorithm === 'ES256');
  if (key === undefined) throw new Error('目录签名密钥不受信任');
  const publicBytes = new util.Base64Helper().decodeSync(key.spki);
  const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
  const pair = await generator.convertKey({ data: publicBytes }, null);
  const verifier = cryptoFramework.createVerify('ECC256|SHA256');
  await verifier.init(pair.pubKey);
  const data = new util.TextEncoder().encodeInto(envelope.protected + '.' + envelope.payload);
  const der = p1363ToDer(runtimeDecode64(envelope.signature));
  if (!await verifier.verify({ data: data }, { data: der })) throw new Error('JDK 目录签名不匹配');
  const result = parseRuntimeCatalog(runtimeUtf8(runtimeDecode64(envelope.payload)), channel);
  if (Date.parse(result.issuedAt) > Date.now() + 300000) throw new Error('目录签发时间在未来');
  if (!allowExpired && Date.parse(result.expiresAt) <= Date.now()) throw new Error('JDK 目录已过期');
  return result;
}

/** 来源选择在创建任何 HTTP 请求之前完成。关闭 web 时连目录请求都不发往自有服务器。 */
export function runtimeCatalogUrls(channel: string, source: string, webEnabled: boolean): string[] {
  const file = (channel === 'preview' ? 'preview' : 'stable') + '.json';
  const github = RAW_BASE + file;
  const mirrored: string[] = ['https://ghfast.top/' + github, 'https://gh-proxy.com/' + github];
  if (source === 'web' && webEnabled) return [WEB_BASE + file];
  if (source === 'github') return [github];
  if (source === 'mirror') return mirrored;
  const result: string[] = [github];
  for (const url of mirrored) result.push(url);
  if (webEnabled) result.push(WEB_BASE + file);
  return result;
}

export class RuntimeCatalogRepository {
  private static shared: RuntimeCatalogRepository | null = null;
  private context: Context;
  private builtin: RuntimeCatalog;
  private current: RuntimeCatalog;
  private highest: RuntimeCatalog;
  private keys: RuntimeTrustedKeys;
  private previous: RuntimeCatalog | null = null;
  private channel: string = 'stable';
  private source: string = 'auto';
  private webEnabled: boolean = false;
  private generation: number = 0;
  private inFlight: Promise<RuntimeRefreshResult> | null = null;
  /** 配置与刷新各自绑定偏好代次；同参调用必须等待正在加载的缓存，不能越过验签。 */
  private configuration: Promise<void> | null = null;
  private inFlightGeneration: number = -1;
  private configured: boolean = false;

  private constructor(context: Context) {
    this.context = context;
    // 这是编译入 HAP 的数据文件：其信任来自 HAP，不允许网络给它降级替换。
    this.builtin = parseRuntimeCatalog(runtimeUtf8(context.resourceManager.getRawFileContentSync('runtime-catalog/builtin.json')), 'stable');
    this.current = this.builtin;
    this.highest = this.builtin;
    this.keys = JSON.parse(runtimeUtf8(context.resourceManager.getRawFileContentSync('runtime-catalog/trusted-keys.json'))) as RuntimeTrustedKeys;
  }

  static instance(context: Context): RuntimeCatalogRepository {
    if (RuntimeCatalogRepository.shared === null) RuntimeCatalogRepository.shared = new RuntimeCatalogRepository(context);
    return RuntimeCatalogRepository.shared;
  }

  snapshot(): RuntimeCatalog { return JSON.parse(JSON.stringify(this.current)) as RuntimeCatalog; }

  /**
   * 返回可展示的槽位。缓存过期、切换通道或代次落后只暂停新下载，不能把整个列表清空。
   * 新任务必须另外经 buildFor 取推荐；未来主版本仍由本地适配器决定能否展示和安装。
   */
  definitions(): RuntimeDefinition[] {
    return this.snapshot().runtimes.filter((r: RuntimeDefinition): boolean => supportsRuntime(r, deviceInfo.sdkApiVersion));
  }

  /** 说明推荐为何暂不可用。旧快照只供展示，不能被当成所选通道的新下载或降级建议。 */
  recommendationUnavailableReason(): string {
    if (this.configuration !== null) return '正在加载 JDK 目录，请稍候';
    if (this.current.channel !== this.channel) return '当前通道目录尚未获取，请刷新列表';
    if (Date.parse(this.current.expiresAt) <= Date.now()) return '当前通道目录已过期，请刷新列表';
    if (this.current.catalogRevision < this.highest.catalogRevision) return '当前通道目录落后于已验证版本，请刷新列表';
    return '';
  }

  buildFor(major: string): RuntimeBuild | undefined {
    if (this.recommendationUnavailableReason().length > 0) return undefined;
    const c = this.snapshot();
    const r = c.runtimes.find((x: RuntimeDefinition): boolean => x.javaMajor.toString() === major && supportsRuntime(x,deviceInfo.sdkApiVersion));
    if (r === undefined) return undefined;
    return c.builds.find((b: RuntimeBuild): boolean => b.id === r.recommendedBuildId && b.status === 'available' && this.isBuildAllowed(b.id));
  }

  /** 撤回知识属于全局构建身份，切换通道不能重新放行已经验证过的坏包。 */
  isBuildAllowed(id: string): boolean {
    const build = this.highest.builds.find((b: RuntimeBuild): boolean => b.id === id);
    if (build === undefined || build.status !== 'available') return false;
    return !this.highest.runtimes.some((r: RuntimeDefinition): boolean => r.rollback !== undefined && r.rollback.fromBuildIds.indexOf(id) >= 0);
  }

  private validateGlobalIdentity(catalog: RuntimeCatalog): void {
    if (catalog.catalogRevision < this.highest.catalogRevision) throw new Error('目录低于已接受的全局代次');
    for (const old of this.highest.builds) {
      const build = catalog.builds.find((b: RuntimeBuild): boolean => b.id === old.id);
      if (build === undefined || runtimeBuildIdentity(old) !== runtimeBuildIdentity(build)) throw new Error('跨通道构建身份漂移');
      if (old.status === 'withdrawn' && build.status !== 'withdrawn') throw new Error('已撤回的 buildId 不能恢复发布');
    }
  }

  /**
   * 偏好变化立即使旧请求失效；同一组偏好的所有调用共享缓存加载任务。
   * 不能在设置 configured 后就让第二次调用返回，否则远程新目录会被稍后完成的旧缓存覆盖。
   */
  configure(channel: string, source: string, webEnabled: boolean): Promise<void> {
    const normalized = channel === 'preview' ? 'preview' : 'stable';
    if (this.configured && this.channel === normalized && this.source === source && this.webEnabled === webEnabled) {
      return this.configuration !== null ? this.configuration : Promise.resolve();
    }
    this.configured = true; this.channel = normalized; this.source = source; this.webEnabled = webEnabled;
    this.generation++; const generation = this.generation;
    // 同通道换源必须保留已接受的推荐代次，即使磁盘缓存暂不可读也不能接受推荐倒退。
    // highest 恰属目标通道时可恢复同一份已验证快照；否则内置槽位仅供占位展示。
    const retained = this.current.channel === normalized ? this.current
      : (this.highest.channel === normalized ? this.highest : null);
    this.current = retained !== null ? retained : this.builtin;
    this.previous = retained;
    const task = this.loadCachedCatalogs(normalized, generation);
    this.configuration = task;
    return task.finally((): void => {
      if (this.configuration === task) this.configuration = null;
    });
  }

  /** 两个通道的缓存共同积累撤回知识，但只展示所选通道；过期缓存仍保留槽位和身份。 */
  private async loadCachedCatalogs(normalized: string, generation: number): Promise<void> {
    for (const cachedChannel of ['stable','preview']) {
      try {
        const path = this.cachePath(cachedChannel);
        if (fs.statSync(path).size > RUNTIME_CATALOG_LIMIT) throw new Error('缓存超限');
        const cached = await verifyRuntimeEnvelope(fs.readTextSync(path), this.keys, cachedChannel, true);
        if (generation !== this.generation) return;
        // 缓存也不能倒退本会话已接受的推荐；校验失败时保留内存快照，且不污染 highest。
        if (cachedChannel === normalized && this.previous !== null) validateRuntimeTransition(this.previous, cached);
        // 过期缓存仍保存最高代次/撤回知识。buildFor 会阻止过期或低代次目录的新下载。
        if (cached.catalogRevision >= this.highest.catalogRevision) { this.validateGlobalIdentity(cached); this.highest = cached; }
        if (cachedChannel === normalized) {
          this.previous = cached;
          this.current = cached;
        }
      } catch (e) { AppLogger.info(TAG, '该通道暂无可加载的可信缓存：' + cachedChannel); }
    }
  }

  refresh(): Promise<RuntimeRefreshResult> {
    const generation = this.generation;
    if (this.inFlight !== null && this.inFlightGeneration === generation) return this.inFlight;
    const task = this.refreshConfigured(generation);
    this.inFlight = task; this.inFlightGeneration = generation;
    return task.finally((): void => {
      // 新通道可立即创建自己的请求；旧请求结束不能清掉新请求的去重句柄。
      if (this.inFlight === task) this.inFlight = null;
    });
  }

  /** 先完成同代缓存验签，再发网络请求，防止缓存和远程提交交错产生伪降级。 */
  private async refreshConfigured(generation: number): Promise<RuntimeRefreshResult> {
    if (this.configuration !== null) await this.configuration;
    if (generation !== this.generation) return { ok:false,error:'JDK 目录设置已改变，请重新检查',catalog:this.snapshot() };
    return this.refreshOnce();
  }

  private cachePath(channel: string): string { return this.context.filesDir + '/runtime-catalog/' + channel + '.json'; }

  private async refreshOnce(): Promise<RuntimeRefreshResult> {
    const channel = this.channel; const generation = this.generation;
    let error = '未获取到可信 JDK 目录';
    for (const url of runtimeCatalogUrls(channel, this.source, this.webEnabled)) {
      if (generation !== this.generation) break;
      const request = http.createHttp();
      try {
        // maxLimit 在原生接收层限制分配，不能等 JSON/string 分配完成后才拦截大响应。
        const response = await request.request(url, { method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING, usingCache: false, maxLimit: RUNTIME_CATALOG_LIMIT,
          connectTimeout: 10000, readTimeout: 15000 });
        if (response.responseCode !== 200 || typeof response.result !== 'string') throw new Error('目录 HTTP ' + response.responseCode);
        const raw = response.result as string;
        const next = await verifyRuntimeEnvelope(raw, this.keys, channel);
        if (generation !== this.generation) throw new Error('JDK 目录设置已改变，请重新检查');
        if (this.previous !== null) validateRuntimeTransition(this.previous, next);
        else if (channel === 'stable') validateRuntimeTransition(this.builtin, next);
        // 只在缓存提交前校验；highest 的更新与 current 在同一成功提交阶段生效。
        this.validateGlobalIdentity(next);
        // 先写临时文件并 fsync，再原子 rename；失败时 current 和旧缓存都保持有效。
        const path = this.cachePath(channel); ensureDirSync(this.context.filesDir + '/runtime-catalog');
        const temp = path + '.writing';
        const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try { fs.writeSync(file.fd,raw); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
        fs.renameSync(temp,path);
        this.previous = next; this.current = next; this.highest = next;
        return { ok:true, error:'', catalog:this.snapshot() };
      } catch (e) {
        error = (e as Error).message;
        AppLogger.warn(TAG, '目录刷新失败：' + error);
        if (generation !== this.generation) break;
      } finally { request.destroy(); }
    }
    return { ok:false,error:error,catalog:this.snapshot() };
  }
}

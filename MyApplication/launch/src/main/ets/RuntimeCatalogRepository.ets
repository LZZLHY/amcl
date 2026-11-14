/**
 * 运行时目录的唯一可信入口：HAP 内置快照 → 已验签缓存 → 有界 HTTPS 刷新。
 * 不依赖 App 更新开关，store 也可查询运行时。缓存失败不移除现有 JDK；
 * 私钥永不进入应用，公钥仅来自 HAP。所有消费者拿深拷贝，安装任务冻结旧快照。
 */
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppLogger } from 'commons';
import { DownloadManager, getRelayClient } from 'feature_core';
import {
  RuntimeCatalog, RuntimeBuild, RuntimeDefinition, RuntimeSignedEnvelope, RuntimeProtectedHeader,
  RuntimeTrustedKeys, RuntimeRefreshResult
} from './RuntimeCatalogTypes';
import {
  RUNTIME_CATALOG_LIMIT, parseRuntimeCatalog, validateRuntimeTransition, supportsRuntime,
  requireCatalogObject, p1363ToDer
} from './RuntimeCatalogValidation';
import { runtimeBuildIdentity, runtimeRecommendationIds, runtimeRequiredHost, runtimeBuildForHost } from './RuntimeCatalogValidation';
import { runtimeHostProtocols, runtimeRequiredCapabilities } from './RuntimeHostProtocol';
import { writeRuntimeCatalogAtomic } from './RuntimeCatalogStore';

interface RuntimeAcceptedLedger { schemaVersion: number; envelopes: string[]; }
interface RuntimeCatalogIoError { code?: number | string; message?: string; }
function catalogMissing(error: Object): boolean {
  const detail = error as RuntimeCatalogIoError;
  return detail.code === 13900002 || detail.code === 'ENOENT' || detail.message === 'ENOENT';
}

const TAG: string = 'RuntimeCatalog';
const RAW_BASE: string = 'https://raw.githubusercontent.com/LZZLHY/mc-ohos-resources/main/catalog/v';
const WEB_BASE: string = 'https://amcl.lovedhy.cn/runtimes/catalog/v';

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

/**
 * 请求前选择目录路径。网关关闭时独立web仍需opt-in，显式GitHub不含代理；网关开启
 * 可用固定第一方目录缓存再向GitHub回源，两者仍必须通过相同JWS验签，绝不探第三方。
 */
export function runtimeCatalogUrls(channel: string, source: string, webEnabled: boolean, version: number = 1,
  gatewayEnabled: boolean = false): string[] {
  const file = (channel === 'preview' ? 'preview' : 'stable') + '.json';
  const github = RAW_BASE + version.toString() + '/' + file;
  if (gatewayEnabled) return [WEB_BASE + version.toString() + '/' + file,github];
  const mirrored: string[] = ['https://ghfast.top/' + github, 'https://gh-proxy.com/' + github];
  if (source === 'web') return webEnabled ? [WEB_BASE + version.toString() + '/' + file] : [];
  if (source === 'github') return [github];
  if (source === 'mirror') return mirrored;
  const result: string[] = [github];
  for (const url of mirrored) result.push(url);
  if (webEnabled) result.push(WEB_BASE + version.toString() + '/' + file);
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
  /** v2宿主要求按build记忆，不能被较新v1投影覆盖后遗忘；跨通道缓存共同恢复该知识。 */
  private acceptedHostRequirements: Record<string,number> = {};
  /** 四种投影的已接受签名原文独立于展示缓存；损坏缓存不能抹掉全局撤回/宿主要求。 */
  private acceptedEnvelopes: Record<string,string> = {};
  /** 与原文一一对应的投影基线；展示缓存只能推进自己的schema/channel，不能覆写旧代原文。 */
  private acceptedSnapshots: Record<string,RuntimeCatalog> = {};
  private ledgerLoaded: boolean = false;
  private ledgerFailure: string = '';
  private ledgerCorrupt: boolean = false;

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
    if (this.ledgerFailure !== '') return this.ledgerFailure;
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
    const selected = runtimeBuildForHost(c,r,runtimeHostProtocols(),runtimeRequiredCapabilities());
    return selected !== undefined && this.isBuildAllowed(selected.id) ? selected : undefined;
  }

  /** 按目标App真实能力规划兼容返回；仅用于冻结计划，不授予当前宿主运行新协议的权限。 */
  buildForHost(major: string, protocols: number[], forRestore: boolean = false, requiredCapabilities: string[] = []): RuntimeBuild | undefined {
    if (this.recommendationUnavailableReason().length > 0) return undefined;
    const c = this.snapshot();
    const runtime = c.runtimes.find((r: RuntimeDefinition): boolean => r.javaMajor.toString() === major && supportsRuntime(r,deviceInfo.sdkApiVersion));
    if (runtime === undefined) return undefined;
    if (forRestore) c.builds = c.builds.filter((b: RuntimeBuild): boolean => b.validationLevel === 'device-matrix-tested');
    const build = runtimeBuildForHost(c,runtime,protocols,requiredCapabilities);
    return build !== undefined && this.isBuildAllowed(build.id) ? build : undefined;
  }

  /** 最新推荐不兼容仍给出原因；兼容旧项可继续下载，不能把“需要App”误写为暂无更新。 */
  hostUpgradeReason(major: string = ''): string {
    const c = this.snapshot();
    for (const r of c.runtimes) {
      if (major !== '' && r.javaMajor.toString() !== major) continue;
      const ids = runtimeRecommendationIds(r); if (ids.length === 0) continue;
      const newest = c.builds.find((b: RuntimeBuild): boolean => b.id === ids[0] && b.status === 'available');
      if (newest !== undefined && runtimeHostProtocols().indexOf(runtimeRequiredHost(c,newest)) < 0) {
        return '有新 JDK 构建，需要先更新 AMCL（宿主协议 ' + runtimeRequiredHost(c,newest).toString() + '）；保留当前运行时和兼容下载';
      }
      if (newest !== undefined && runtimeBuildForHost(c,r,runtimeHostProtocols(),runtimeRequiredCapabilities()) === undefined) {
        return '当前JDK通道尚未提供本应用所需的兼容修复包，请刷新目录后重试；不会重复下载不兼容旧包';
      }
    }
    return '';
  }

  /** 撤回知识属于全局构建身份，切换通道不能重新放行已经验证过的坏包。 */
  isBuildAllowed(id: string): boolean {
    const build = this.highest.builds.find((b: RuntimeBuild): boolean => b.id === id);
    if (build === undefined || build.status !== 'available') return false;
    return !this.highest.runtimes.some((r: RuntimeDefinition): boolean => r.rollback !== undefined && r.rollback.fromBuildIds.indexOf(id) >= 0);
  }

  private rememberHostRequirements(catalog: RuntimeCatalog): void {
    if (catalog.schemaVersion !== 2) return;
    for (const build of catalog.builds) {
      const old = this.acceptedHostRequirements[build.id];
      if (old !== undefined && old !== build.requiredHostProtocol) throw new Error('已接受构建的宿主要求漂移');
    }
    for (const build of catalog.builds) this.acceptedHostRequirements[build.id] = build.requiredHostProtocol!;
  }

  private validateGlobalIdentity(catalog: RuntimeCatalog): void {
    if (catalog.schemaVersion === 2) for (const b of catalog.builds) {
      const accepted = this.acceptedHostRequirements[b.id];
      if (accepted !== undefined && accepted !== b.requiredHostProtocol) throw new Error('已接受构建的宿主要求漂移');
    }
    if (catalog.catalogRevision < this.highest.catalogRevision) throw new Error('目录低于已接受的全局代次');
    for (const old of this.highest.builds) {
      const build = catalog.builds.find((b: RuntimeBuild): boolean => b.id === old.id);
      if (build === undefined || runtimeBuildIdentity(old) !== runtimeBuildIdentity(build)) throw new Error('跨通道构建身份漂移');
      if (this.highest.schemaVersion === 2 && catalog.schemaVersion === 2 && old.requiredHostProtocol !== build.requiredHostProtocol) throw new Error('跨通道宿主要求漂移');
      if (old.status === 'withdrawn' && build.status !== 'withdrawn') throw new Error('已撤回的 buildId 不能恢复发布');
    }
  }

  /** 同一投影独立保持代次、推荐和撤回单调；不能仅看全局highest而放行另一通道的旧缓存。 */
  private validateProjection(catalog: RuntimeCatalog): void {
    const previous = this.acceptedSnapshots[catalog.schemaVersion.toString() + ':' + catalog.channel];
    if (previous !== undefined) validateRuntimeTransition(previous,catalog);
  }

  /**
   * 较老的另一投影仍可能是唯一携带逐build宿主要求的v2证据。允许保存它，但必须与较新
   * 全局快照的不可变构建/撤回历史相容；它不推进highest，也不倒退当前通道展示。
   */
  private validateHistoricalProjection(catalog: RuntimeCatalog): void {
    for (const old of catalog.builds) {
      const current = this.highest.builds.find((b: RuntimeBuild): boolean => b.id === old.id);
      if (current === undefined || runtimeBuildIdentity(old) !== runtimeBuildIdentity(current) ||
        old.status === 'withdrawn' && current.status !== 'withdrawn') throw new Error('旧投影与已接受的全局构建历史冲突');
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
    await this.loadAcceptedLedger(normalized,generation);
    if (generation !== this.generation || this.ledgerFailure !== '') return;
    for (const version of [1,2]) for (const cachedChannel of ['stable','preview']) {
      try {
        const path = this.cachePath(cachedChannel,version);
        if (fs.statSync(path).size > RUNTIME_CATALOG_LIMIT) throw new Error('缓存超限');
        const raw = fs.readTextSync(path);
        const cached = await verifyRuntimeEnvelope(raw, this.keys, cachedChannel, true);
        if (cached.schemaVersion !== version) throw new Error('目录缓存格式命名空间不匹配');
        if (generation !== this.generation) return;
        this.validateProjection(cached);
        // 缓存也不能倒退本会话已接受的推荐；校验失败时保留内存快照，且不污染 highest。
        const display = cachedChannel === normalized && (this.previous === null || cached.catalogRevision >= this.previous.catalogRevision);
        if (display && this.previous !== null) validateRuntimeTransition(this.previous, cached);
        // 过期缓存仍保存最高代次/撤回知识。buildFor 会阻止过期或低代次目录的新下载。
        if (cached.catalogRevision >= this.highest.catalogRevision) { this.validateGlobalIdentity(cached); this.highest = cached; }
        else this.validateHistoricalProjection(cached);
        this.rememberHostRequirements(cached);
        const key = cached.schemaVersion.toString() + ':' + cached.channel;
        this.acceptedEnvelopes[key] = raw; this.acceptedSnapshots[key] = cached;
        if (display) {
          this.previous = cached;
          this.current = cached;
        }
      } catch (e) { AppLogger.info(TAG, '该通道暂无可加载的可信缓存：' + cachedChannel); }
    }
    // 首次迁移旧缓存也建立耐久账本；写失败不允许以不受保护的推荐继续新安装。
    if (Object.keys(this.acceptedEnvelopes).length > 0) {
      try { this.persistAcceptedLedger(this.acceptedEnvelopes); }
      catch (error) { this.ledgerFailure = 'JDK目录信任记录尚未耐久保存，请重试检查：' + (error as Error).message; }
    }
  }

  /** 冷启动先恢复验签原文中的最高代次/撤回，再读取可丢弃的展示缓存。未知损坏失败关闭。 */
  private async loadAcceptedLedger(normalized: string, generation: number): Promise<void> {
    if (this.ledgerLoaded) return;
    const path = this.context.filesDir + '/runtime-catalog/accepted.json';
    let raw = '';
    try {
      const stat = fs.lstatSync(path);
      if (!stat.isFile() || stat.size <= 0 || stat.size > 5 * RUNTIME_CATALOG_LIMIT) throw new Error('信任账本类型或大小无效');
      raw = fs.readTextSync(path);
    } catch (error) {
      if (catalogMissing(error as Object)) { this.ledgerLoaded = true; return; }
      this.ledgerFailure = 'JDK目录信任记录损坏，已暂停新下载并保留已安装运行时'; this.ledgerCorrupt = true; this.ledgerLoaded = true; return;
    }
    try {
      const ledger = JSON.parse(raw) as RuntimeAcceptedLedger;
      requireCatalogObject(ledger,['schemaVersion','envelopes'],'已接受目录账本');
      if (ledger.schemaVersion !== 1 || !Array.isArray(ledger.envelopes) || ledger.envelopes.length < 1 || ledger.envelopes.length > 4) throw new Error('信任账本格式无效');
      const snapshots: RuntimeCatalog[] = []; const originals: Record<string,string> = {};
      const projections: Record<string,RuntimeCatalog> = {};
      for (const envelope of ledger.envelopes) {
        // 通道本身仍由验签后的 payload 约束；各通道分别尝试，不把账本外壳当可信声明。
        let catalog: RuntimeCatalog;
        try { catalog = await verifyRuntimeEnvelope(envelope,this.keys,'stable',true); }
        catch (_) { catalog = await verifyRuntimeEnvelope(envelope,this.keys,'preview',true); }
        if (generation !== this.generation) return;
        const key = catalog.schemaVersion.toString() + ':' + catalog.channel;
        if (originals[key] !== undefined) throw new Error('信任账本重复投影');
        originals[key] = envelope; projections[key] = catalog; snapshots.push(catalog);
      }
      // 升级HAP可能带来比磁盘更高的内置基线，按代次合并而不是把合法旧账本误判为降级。
      snapshots.push(this.builtin);
      snapshots.sort((a: RuntimeCatalog,b: RuntimeCatalog): number => a.catalogRevision - b.catalogRevision || a.schemaVersion - b.schemaVersion);
      this.highest = snapshots[0];
      for (const catalog of snapshots) {
        this.validateGlobalIdentity(catalog); this.rememberHostRequirements(catalog); this.highest = catalog;
        if (catalog.channel === normalized) { this.previous = catalog; this.current = catalog; }
      }
      this.acceptedEnvelopes = originals; this.acceptedSnapshots = projections; this.ledgerLoaded = true;
    } catch (error) {
      if (generation !== this.generation) return;
      this.ledgerFailure = 'JDK目录信任记录损坏，已暂停新下载并保留已安装运行时'; this.ledgerCorrupt = true; this.ledgerLoaded = true;
    }
  }

  /** 先提交信任账本，再写展示缓存；后者失败不能让重启忘记已接受的撤回。 */
  private persistAcceptedLedger(envelopes: Record<string,string>): void {
    const ledger: RuntimeAcceptedLedger = {schemaVersion:1,envelopes:Object.keys(envelopes).sort().map((key: string): string => envelopes[key])};
    const raw = JSON.stringify(ledger);
    if (raw.length > 5 * RUNTIME_CATALOG_LIMIT) throw new Error('JDK信任账本超过预算');
    const directory = this.context.filesDir + '/runtime-catalog';
    writeRuntimeCatalogAtomic(this.context.filesDir,directory,directory + '/accepted.json',raw);
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

  private cachePath(channel: string, version: number = 1): string {
    return this.context.filesDir + '/runtime-catalog/' + (version === 2 ? 'v2/' : '') + channel + '.json';
  }

  private async refreshOnce(): Promise<RuntimeRefreshResult> {
    const channel = this.channel; const generation = this.generation;
    const gateway = getRelayClient().isEnabled();
    let error = '未获取到可信 JDK 目录';
    if (this.ledgerFailure !== '') {
      if (this.ledgerCorrupt) return {ok:false,error:this.ledgerFailure,catalog:this.snapshot()};
      try { this.persistAcceptedLedger(this.acceptedEnvelopes); this.ledgerFailure = ''; }
      catch (failure) { return {ok:false,error:this.ledgerFailure,catalog:this.snapshot()}; }
    }
    // 优先v2；尚未部署v2时允许沿可信v1继续。任何格式仍必须通过签名与全局反回退。
    const modernUrls = runtimeCatalogUrls(channel,this.source,this.webEnabled,2,gateway);
    const urls = modernUrls.concat(runtimeCatalogUrls(channel,this.source,this.webEnabled,1,gateway));
    for (let urlIndex = 0; urlIndex < urls.length; urlIndex++) {
      const url = urls[urlIndex];
      const expectedSchemaVersion: number = urlIndex < modernUrls.length ? 2 : 1;
      if (generation !== this.generation) break;
      if (getRelayClient().isEnabled() !== gateway) { error='下载方式已改变，请重新检查JDK目录'; break; }
      try {
        // 只有公共可信目录显式允许自有网关；来源URL仍由上面的github/mirror/web过滤
        // 决定，不混入第三方镜像或替用户开启web。Native保持原始URL与签名证明私有，
        // 每跳重新鉴权、失败最多直连同候选一次，25秒覆盖准入/连接/跳转和回退全链。
        // 接收层限制解压后字节，不能等JS分配出超大字符串再检查；之后的JWS验签、
        // 推荐防回退及缓存事务完全保留，网关/HTTP成功从不等于目录可信。
        const manager = DownloadManager.instance(); manager.initializeCaBundle(this.context);
        const response = await manager.fetchTextEx(url, [], 25, { 'Cache-Control': 'no-cache' },
          RUNTIME_CATALOG_LIMIT, true);
        if (response.statusCode !== 200) throw new Error('目录 HTTP ' + response.statusCode);
        const raw = response.body;
        const next = await verifyRuntimeEnvelope(raw, this.keys, channel);
        // 签名只证明正文真实，镜像仍可能把旧格式放错目录。先核对本次请求的格式，
        // 再更新任何信任账本，避免首个错配响应遮住后续v2来源。全部v2来源失败后，
        // 请求序列仍会正常尝试v1；只有与对应命名空间一致的正文才有提交资格。
        if (next.schemaVersion !== expectedSchemaVersion) {
          throw new Error('JDK目录格式与请求地址不一致，请尝试下一来源');
        }
        if (generation !== this.generation || getRelayClient().isEnabled() !== gateway)
          throw new Error('JDK 目录设置或下载方式已改变，请重新检查');
        this.validateProjection(next);
        if (this.previous !== null) validateRuntimeTransition(this.previous, next);
        else if (channel === 'stable') validateRuntimeTransition(this.builtin, next);
        // 只在缓存提交前校验；highest 的更新与 current 在同一成功提交阶段生效。
        this.validateGlobalIdentity(next);
        const accepted: Record<string,string> = JSON.parse(JSON.stringify(this.acceptedEnvelopes)) as Record<string,string>;
        accepted[next.schemaVersion.toString() + ':' + next.channel] = raw;
        // 验签后的撤回知识立即保守记忆。若rename已发生但父目录fsync失败，也不能在本进程
        // 用更旧目录覆盖未知耐久结果；下次检查先重试保存同一份已知原文。
        this.acceptedEnvelopes = accepted; this.acceptedSnapshots[next.schemaVersion.toString() + ':' + next.channel] = next;
        this.rememberHostRequirements(next); this.highest = next;
        try {
          this.persistAcceptedLedger(accepted);
          // 同一次refresh可以在下一来源成功重试。只有当前已知信任知识确实耐久后
          // 才结束临时I/O阻断；未知账本损坏在本函数入口已失败关闭，不在这里清除。
          this.ledgerFailure = '';
        }
        catch (failure) { this.ledgerFailure = 'JDK目录信任记录尚未耐久保存，请重试检查：' + (failure as Error).message; throw failure as Error; }
        // 信任知识已经耐久；展示缓存失败仍保留最高代次，重启也从独立账本恢复。
        const path = this.cachePath(channel,next.schemaVersion);
        writeRuntimeCatalogAtomic(this.context.filesDir,this.context.filesDir + '/runtime-catalog' + (next.schemaVersion === 2 ? '/v2' : ''),path,raw);
        this.previous = next; this.current = next; this.highest = next;
        return { ok:true, error:'', catalog:this.snapshot() };
      } catch (e) {
        error = (e as Error).message;
        AppLogger.warn(TAG, '目录刷新失败：' + error);
        if (generation !== this.generation) break;
      }
    }
    return { ok:false,error:error,catalog:this.snapshot() };
  }
}

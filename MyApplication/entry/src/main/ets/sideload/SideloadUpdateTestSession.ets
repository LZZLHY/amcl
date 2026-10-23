/**
 * default诊断包的更新源注入。测试仍由真实UpdateChecker、更新弹窗和ViewModel执行完整链路。
 * 只接受本站临时测试目录，不更改正式更新源；进程结束或测试结束即丢弃这份内存配置。
 * 检查请求必须先捕获来源快照，并带着同一快照经过 await、排队和弹窗展示。
 * configure/clear 会使旧测试代次失效，不能把其迟到清单重新解释为正式 GitHub 来源。
 */
import { DiagnosticPolicy, UPDATE_MANIFEST_URLS } from 'commons';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { UpdateManifest, UpdateCheckResult, SideloadUpdateAsset, SideloadMirror } from 'update';

export interface SideloadUpdatePageParams {
  manifest?: UpdateManifest; autoStart?: boolean;
  /** Coordinator 核验后的不透明令牌；路由不能提供任意安装路径。 */
  importToken?: string;
  testAsset?: SideloadUpdateAsset; sameVersionTest?: boolean;
}

/**
 * 一次检查的来源身份。正式请求固定使用正式 URL，不受后来配置的测试会话影响；
 * 测试请求携带代次、固定候选及同版本开关，只在该代次仍有效时可以产生新提示。
 * readonly 约束调用方，asset/urls 还会复制，避免原 Want DTO 或调用方数组反向改写会话。
 */
export interface SideloadUpdateCheckSource {
  readonly testSource: boolean;
  readonly generation: number;
  readonly source: string;
  readonly urls: string[];
  readonly asset?: SideloadUpdateAsset;
  readonly assetKey: string;
  readonly sameVersionTest: boolean;
}

/** 排队保存完整候选，不拆开保存 manifest 和“届时再读取”的全局测试配置。 */
export interface SideloadUpdatePromptCandidate {
  readonly manifest: UpdateManifest;
  readonly source: SideloadUpdateCheckSource;
  readonly manual: boolean;
}

export class SideloadUpdateTestSession {
  private static source: string = '';
  private static asset: SideloadUpdateAsset | undefined = undefined;
  private static sameVersion: boolean = false;
  /** 每次成功配置或 clear 都推进代次；相同 URL/包再次配置也不能复活旧请求。 */
  private static generation: number = 0;

  /** 只复制公开资产 DTO，包含镜像定位对象；不保留读取 fixture 时的任何可变引用。 */
  private static copyAsset_(asset: SideloadUpdateAsset): SideloadUpdateAsset {
    return { tag: asset.tag, name: asset.name, url: asset.url, sha256: asset.sha256,
      sizeBytes: asset.sizeBytes, versionCode: asset.versionCode, versionName: asset.versionName,
      product: asset.product, legacyUniversal: asset.legacyUniversal, websiteUrl: asset.websiteUrl,
      mirrors: asset.mirrors?.map((mirror: SideloadMirror): SideloadMirror => ({ provider: mirror.provider,
        projectId: mirror.projectId, assetId: mirror.assetId, filePath: mirror.filePath, ready: mirror.ready })) };
  }

  /** 以同一显式 DTO 字段顺序绑定快照，嵌套镜像变动也不能绕过候选复制边界。 */
  private static assetKey_(asset: SideloadUpdateAsset): string {
    return JSON.stringify(SideloadUpdateTestSession.copyAsset_(asset));
  }

  /** 两道产品门禁同时生效；store/sideload/desktop不能借路由参数使用测试资产。 */
  private static enabled(): boolean { return ProductBuildProfile.product === 'default' && DiagnosticPolicy.hasTestHooks(); }
  static allowedAssetUrl(url: string): boolean {
    return SideloadUpdateTestSession.enabled() &&
      (new RegExp('^http://127\\.0\\.0\\.1:[0-9]{1,5}/candidate\\.hap$').test(url) ||
        new RegExp('^https://amcl\\.lovedhy\\.cn/uploads/self-update-tests/[0-9a-f]{32}/[a-z0-9-]+\\.hap$').test(url));
  }
  static configure(source: string, asset: SideloadUpdateAsset, sameVersion: boolean): void {
    if (!SideloadUpdateTestSession.enabled() ||
      !new RegExp('^https://amcl\\.lovedhy\\.cn/uploads/self-update-tests/[0-9a-f]{32}/[a-z0-9-]+\\.json$').test(source) ||
      !SideloadUpdateTestSession.allowedAssetUrl(asset.url) ||
      source.substring(0, source.lastIndexOf('/')) !== asset.url.substring(0, asset.url.lastIndexOf('/')) ||
      !new RegExp('^[0-9a-f]{64}$').test(asset.sha256) || asset.product !== 'sideload' ||
      !Number.isSafeInteger(asset.sizeBytes) || asset.sizeBytes <= 0 || asset.sizeBytes > 2 * 1024 * 1024 * 1024) {
      throw new Error('更新测试源或候选身份无效');
    }
    SideloadUpdateTestSession.generation++;
    SideloadUpdateTestSession.source = source; SideloadUpdateTestSession.asset = SideloadUpdateTestSession.copyAsset_(asset);
    SideloadUpdateTestSession.sameVersion = sameVersion;
  }
  static active(): boolean { return SideloadUpdateTestSession.enabled() && SideloadUpdateTestSession.source.length > 0; }
  static clear(): void {
    SideloadUpdateTestSession.generation++;
    SideloadUpdateTestSession.source = ''; SideloadUpdateTestSession.asset = undefined; SideloadUpdateTestSession.sameVersion = false;
  }
  /** 自动正式检查明确捕获本入口；不得在其返回后借用新测试会话的固定资产。 */
  static productionSource(): SideloadUpdateCheckSource {
    return { testSource: false, generation: 0, source: '', urls: UPDATE_MANIFEST_URLS.slice(),
      assetKey: '', sameVersionTest: false };
  }

  /** 手动检查在发网络请求前调用一次，之后只能传递此快照，不能重新读全局来源。 */
  static captureSource(): SideloadUpdateCheckSource {
    const asset = SideloadUpdateTestSession.asset;
    if (!SideloadUpdateTestSession.active() || asset === undefined) return SideloadUpdateTestSession.productionSource();
    const fixed = SideloadUpdateTestSession.copyAsset_(asset);
    return { testSource: true, generation: SideloadUpdateTestSession.generation,
      source: SideloadUpdateTestSession.source, urls: [SideloadUpdateTestSession.source], asset: fixed,
      assetKey: SideloadUpdateTestSession.assetKey_(fixed), sameVersionTest: SideloadUpdateTestSession.sameVersion };
  }

  /**
   * 正式快照与全局测试代次无关。测试快照则同时核对产品门、代次、URL 和固定资产；
   * clear、重新配置相同 fixture、切换产品门或修改快照中的资产都会阻止后续提示。
   */
  static isCurrent(source: SideloadUpdateCheckSource): boolean {
    if (!source.testSource) {
      if (source.generation !== 0 || source.source !== '' || source.asset !== undefined ||
        source.assetKey !== '' || source.sameVersionTest || source.urls.length !== UPDATE_MANIFEST_URLS.length) return false;
      // readonly 不能冻结数组元素；正式快照必须逐项保持固定官方源及其兜底顺序。
      for (let index = 0; index < UPDATE_MANIFEST_URLS.length; index++) {
        if (source.urls[index] !== UPDATE_MANIFEST_URLS[index]) return false;
      }
      return true;
    }
    const asset = SideloadUpdateTestSession.asset;
    return SideloadUpdateTestSession.active() && source.generation === SideloadUpdateTestSession.generation &&
      source.source === SideloadUpdateTestSession.source && source.urls.length === 1 && source.urls[0] === source.source &&
      source.sameVersionTest === SideloadUpdateTestSession.sameVersion && asset !== undefined && source.asset !== undefined &&
      source.assetKey === SideloadUpdateTestSession.assetKey_(asset) &&
      source.assetKey === SideloadUpdateTestSession.assetKey_(source.asset);
  }

  /** 同步兼容入口；异步调用方应使用 captureSource().urls 并保留快照。 */
  static urls(): string[] { return SideloadUpdateTestSession.captureSource().urls; }

  /** 测试清单必须绑定原快照的版本、URL 和大小；正式身份仍由真实 UpdateChecker/Resolver 核对。 */
  static matchesManifest(manifest: UpdateManifest, source: SideloadUpdateCheckSource): boolean {
    if (!SideloadUpdateTestSession.isCurrent(source)) return false;
    if (!source.testSource) return true;
    const asset = source.asset;
    return asset !== undefined && manifest.versionCode === asset.versionCode && manifest.versionName === asset.versionName &&
      manifest.tag === asset.tag && manifest.sizeBytes === asset.sizeBytes && manifest.url === asset.url;
  }

  /** 网络清单仍由产品解析器解析、比较；同版本实验仅调整是否展示提示，不放宽签名器的版本核对。 */
  static validateResult(result: UpdateCheckResult,
    source: SideloadUpdateCheckSource = SideloadUpdateTestSession.captureSource()): void {
    if (!SideloadUpdateTestSession.isCurrent(source)) {
      result.ok = false; result.hasUpdate = false; result.manifest = null;
      result.error = '测试更新会话已结束，请重新检查更新'; return;
    }
    if (!source.testSource || !result.ok || result.manifest === null) return;
    const manifest = result.manifest;
    if (!SideloadUpdateTestSession.matchesManifest(manifest, source)) {
      result.ok = false; result.hasUpdate = false; result.error = '测试清单与固定候选身份不一致'; return;
    }
    if (source.sameVersionTest && manifest.versionCode === result.current) result.hasUpdate = true;
  }
  /**
   * 在展示前只生成一次参数。测试来源失效时明确拒绝，绝不降级成不带 testAsset 的正式安装；
   * 正式来源始终只返回正式 manifest，即使此刻已经存在一个新测试会话。
   */
  static parameters(manifest: UpdateManifest,
    source: SideloadUpdateCheckSource = SideloadUpdateTestSession.captureSource()): SideloadUpdatePageParams {
    if (!SideloadUpdateTestSession.matchesManifest(manifest, source)) throw new Error('测试更新候选已失效，请重新检查更新');
    const params: SideloadUpdatePageParams = { manifest: manifest, autoStart: true };
    const asset = source.asset;
    if (source.testSource && asset !== undefined) {
      params.testAsset = SideloadUpdateTestSession.copyAsset_(asset); params.sameVersionTest = source.sameVersionTest;
    }
    return params;
  }
}

/**
 * 首页实际使用的纯排队判据。只决定候选是否可保留/展示，不创建 UI、不持安装许可。
 * 回归直接执行本类和真实解析器，避免测试另写一套“类似”的来源判据。
 */
export class SideloadUpdatePromptPolicy {
  /** await 后和直接展示前的共同入口：过期测试候选返回 null，不占排队位置。 */
  static candidate(manifest: UpdateManifest, source: SideloadUpdateCheckSource,
    manual: boolean): SideloadUpdatePromptCandidate | null {
    if (!SideloadUpdateTestSession.matchesManifest(manifest, source)) return null;
    try {
      // 两种输入均是内部显式 DTO，manifest 已经过真实解析器的 8 KiB 输入限制。
      // 在候选边界深复制清单、delivery、来源数组和固定资产，调用方修改原对象不能改写队列。
      // 异常仅拒绝这份候选；不得用不可复制的数据重新推导一个“正式”来源来兜底。
      const fixedManifest = JSON.parse(JSON.stringify(manifest)) as UpdateManifest;
      const fixedSource = JSON.parse(JSON.stringify(source)) as SideloadUpdateCheckSource;
      if (!SideloadUpdateTestSession.matchesManifest(fixedManifest, fixedSource)) return null;
      return { manifest: fixedManifest, source: fixedSource, manual: manual };
    } catch (_) { return null; }
  }

  /**
   * 最新合法候选覆盖旧位置。同一来源保留已表达的手动意图；不同测试代次、正式/测试来源
   * 之间不继承该意图，失效的迟到候选也不能覆盖一个仍然合法的待提示候选。
   */
  static queue(previous: SideloadUpdatePromptCandidate | null,
    next: SideloadUpdatePromptCandidate): SideloadUpdatePromptCandidate | null {
    if (!SideloadUpdateTestSession.matchesManifest(next.manifest, next.source)) return SideloadUpdatePromptPolicy.select(previous, false);
    const old = SideloadUpdatePromptPolicy.select(previous, false);
    const sameSource = old !== null && old.source.testSource === next.source.testSource &&
      old.source.generation === next.source.generation && old.source.source === next.source.source;
    return SideloadUpdatePromptPolicy.candidate(next.manifest, next.source,
      next.manual || (sameSource && old !== null && old.manual));
  }

  /** 出队后重核来源代次；开过游戏只抑制自动候选，手动候选沿用既有提示策略。 */
  static select(candidate: SideloadUpdatePromptCandidate | null,
    gameLaunchedThisSession: boolean): SideloadUpdatePromptCandidate | null {
    if (candidate === null || !SideloadUpdateTestSession.matchesManifest(candidate.manifest, candidate.source) ||
      (!candidate.manual && gameLaunchedThisSession)) return null;
    // 出队结果再次复制，展示方不能反向修改仍由其他调用方持有的待提示对象。
    return SideloadUpdatePromptPolicy.candidate(candidate.manifest, candidate.source, candidate.manual);
  }
}

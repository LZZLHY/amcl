/**
 * JDK 内容来源和传输路径的任务内计划。目录签名/防回退在 Repository 完成，完整文件
 * SHA 与发布事务仍由 Installer 执行；本模块不下载文件、不修改偏好，也不根据 VPN 状态猜路。
 * Gitee 分卷与 GitHub 整包是不同 transport，必须整组选择，绝不能混入同一文件的 urls。
 */
import { RuntimeArchive, RuntimeBuild, RuntimeDownload, RuntimePart } from './RuntimeCatalogTypes';

const OFFICIAL_RELEASE_PREFIX = 'https://github.com/LZZLHY/mc-ohos-resources/releases/download/';
const FIRST_PARTY_PACKAGE_PREFIX = 'https://amcl.lovedhy.cn/runtimes/packages/';

/** 路由标签是实际传输事实，canonicalSource 单列，不能把自家缓存的 URL 冒称 GitHub URL。 */
export interface JdkDownloadRoute {
  key: string;
  label: string;
  canonicalSource: string;
  source: RuntimeDownload;
  githubPreference: string;
  /** 缺少Gitee/web对象组时，仅一个已配置代理也可竞速；正式下载固定同一模板，避免测A用B。 */
  githubTemplate?: string;
  probe: boolean;
}

/** 只消费 Native 的有界测量，不回传二进制正文；reject 代表没有取得合格样本。 */
export interface JdkTransferMeasurement {
  httpStatus: number;
  receivedBytes: number;
  elapsedMs: number;
  ttfbMs: number;
  completedSample: boolean;
  rangeHonored: boolean;
  errorKind: string;
}
export type JdkTransferProbe = (url: string, size: number) => Promise<JdkTransferMeasurement>;

/** 网关回源限于发布者明确的GitHub发行地址；未知sourceId标签本身不能授予官方网关资格。 */
function officialGithub(download: RuntimeDownload): boolean {
  if (download.transport === 'single-file') return (download.url ?? '').startsWith(OFFICIAL_RELEASE_PREFIX);
  return download.transport === 'concat-parts' && download.parts !== undefined && download.parts.length > 0
    && download.parts.every((part: RuntimePart): boolean => part.url.startsWith(OFFICIAL_RELEASE_PREFIX));
}

/** 第一方缓存资格只授予同一已验签 build 的精确整包；未知路径、别的归档或无官方描述不授予。 */
function firstPartyCache(build: RuntimeBuild | undefined, archive: RuntimeArchive,
  downloads: RuntimeDownload[]): RuntimeDownload | undefined {
  if (build === undefined || build.archive.fileName !== archive.fileName
    || build.archive.sizeBytes !== archive.sizeBytes || build.archive.sha256.toLowerCase() !== archive.sha256.toLowerCase()
    || !/^[A-Za-z0-9._-]+\.zip$/.test(archive.fileName)) return undefined;
  const hasOrigin = downloads.some((d: RuntimeDownload): boolean => d.sourceId === 'github'
    && d.transport === 'single-file' && (d.url ?? '').startsWith(OFFICIAL_RELEASE_PREFIX)
    && build.downloads.some((signed: RuntimeDownload): boolean => signed.sourceId === 'github'
      && signed.transport === 'single-file' && signed.url === d.url));
  if (!hasOrigin) return undefined;
  const expected = FIRST_PARTY_PACKAGE_PREFIX + archive.fileName;
  return downloads.find((d: RuntimeDownload): boolean => d.sourceId === 'web' && d.transport === 'single-file'
    && d.url === expected && build.downloads.some((signed: RuntimeDownload): boolean => signed.sourceId === 'web'
      && signed.transport === 'single-file' && signed.url === expected));
}

/**
 * 生成有序候选。网关开启是使用自家源站加速的同意，不改独立 webEnabled 的持久值；
 * 此时只允许同官方归档的第一方缓存及 GitHub 回源。网关关闭，显式源站不借此扩充缓存/镜像。
 * 自动档的三个真实对象组参加后续竞速；GitHub 代理仅是未取得有效样本/整组失败后的后备。
 */
export function buildJdkDownloadRoutes(downloads: RuntimeDownload[], archive: RuntimeArchive,
  build: RuntimeBuild | undefined, preference: string, webEnabled: boolean, gatewayEnabled: boolean,
  mirrorTemplates: string[] = []): JdkDownloadRoute[] {
  const github = downloads.find((d: RuntimeDownload): boolean => d.sourceId === 'github');
  const gitee = downloads.find((d: RuntimeDownload): boolean => d.sourceId === 'gitee');
  const web = webEnabled ? downloads.find((d: RuntimeDownload): boolean => d.sourceId === 'web') : undefined;
  const result: JdkDownloadRoute[] = [];
  if (gatewayEnabled) {
    const cache = firstPartyCache(build, archive, downloads);
    if (cache !== undefined) result.push({ key:'gateway-cache',label:'源站·AMCL缓存',canonicalSource:'github',
      source:cache,githubPreference:'github',probe:false });
    if (github !== undefined && officialGithub(github)) result.push({ key:'gateway-origin',label:'源站·网关回源',canonicalSource:'github',
      source:github,githubPreference:'github',probe:false });
    return result;
  }
  if (preference === 'web') {
    if (web !== undefined) result.push({ key:'web',label:'web',canonicalSource:'web',source:web,githubPreference:'github',probe:false });
    return result;
  }
  if (preference === 'github' || preference === 'mirror') {
    if (github !== undefined) result.push({ key:preference === 'github' ? 'github-origin' : 'github-mirror',
      label:'github',canonicalSource:preference === 'github' ? 'github' : 'github-proxy',
      source:github,githubPreference:preference,probe:false });
    return result;
  }
  const automatic = preference === 'auto';
  if (gitee !== undefined) result.push({ key:'gitee',label:'gitee',canonicalSource:'gitee',source:gitee,githubPreference:'github',probe:automatic });
  if (github !== undefined) result.push({ key:'github-origin',label:'github',canonicalSource:'github',source:github,
    githubPreference:automatic ? 'github' : 'auto',probe:automatic });
  if (web !== undefined) result.push({ key:'web',label:'web',canonicalSource:'web',source:web,githubPreference:'github',probe:automatic });
  if (automatic && github !== undefined && result.filter((r: JdkDownloadRoute): boolean => r.probe).length < 2) {
    const template = mirrorTemplates.find((value: string): boolean => value !== '{url}' && value.split('{url}').length === 2);
    if (template !== undefined) result.push({ key:'github-proxy-sample',label:'GitHub镜像',canonicalSource:'github-proxy',
      source:github,githubPreference:'mirror',githubTemplate:template,probe:true });
  }
  if (automatic && github !== undefined) result.push({ key:'github-mirror',label:'GitHub代理后备',canonicalSource:'github-proxy',
    source:github,githubPreference:'mirror',probe:false });
  return result;
}

/** 各组只测第一个真实分卷/整包，不把不同大小的对象误作可互换分段。 */
export function jdkRouteProbePart(route: JdkDownloadRoute, archive: RuntimeArchive): RuntimePart | undefined {
  const part: RuntimePart | undefined = route.source.transport === 'single-file' && route.source.url !== undefined
    ? {url:route.source.url,sizeBytes:archive.sizeBytes,sha256:archive.sha256}
    : (route.source.parts !== undefined && route.source.parts.length > 0 ? route.source.parts[0] : undefined);
  if (part === undefined || route.githubTemplate === undefined) return part;
  return {url:route.githubTemplate.replace('{url}',part.url),sizeBytes:part.sizeBytes,sha256:part.sha256};
}

/**
 * 最多三个候选组并行取样，所有 Native Promise 有界结束后再发布排序。先从同一steady
 * 时间原点扣除排队/建连/首字节，估计正文吞吐，再按完整归档摊销一次启动成本；不能仅
 * 比256KiB到达时刻，让高RTT但快正文的官方源在VPN场景被低RTT慢镜像压住。
 * 短于20ms的正文窗口按20ms保守计，避免单个突发包产生无限速率。失败不污染原transport或哈希。
 * current 失效只撤销本次结果，不声称在途 HTTP 已瞬时中断；原生资源寿命由 bridge 管理。
 */
export async function rankJdkDownloadRoutes(routes: JdkDownloadRoute[], archive: RuntimeArchive, probe: JdkTransferProbe,
  current: () => boolean, observed: (route: JdkDownloadRoute, result: JdkTransferMeasurement | undefined) => void): Promise<JdkDownloadRoute[]> {
  const measured = routes.filter((route: JdkDownloadRoute): boolean => route.probe).slice(0,3);
  if (measured.length < 2) return routes;
  const rates = new Map<string, number>();
  await Promise.all(measured.map(async (route: JdkDownloadRoute): Promise<void> => {
    const part = jdkRouteProbePart(route,archive);
    let result: JdkTransferMeasurement | undefined = undefined;
    try {
      if (part !== undefined && current()) result = await probe(part.url,part.sizeBytes);
    } catch (_) { /* 超时/拒绝没有有效测量，实际文件下载仍由原有校验与后备处理。 */ }
    if (!current()) return;
    observed(route,result);
    if (part !== undefined && result !== undefined && result.completedSample && result.errorKind.length === 0
      && (result.httpStatus === 200 || result.httpStatus === 206) && result.elapsedMs > 0
      && result.ttfbMs >= 0 && result.ttfbMs <= result.elapsedMs
      && result.receivedBytes === Math.min(262144,part.sizeBytes)) {
      const bodyMs = Math.max(20,result.elapsedMs-result.ttfbMs);
      const bodyRate = result.receivedBytes * 1000 / bodyMs;
      const estimatedSeconds = result.ttfbMs / 1000 + archive.sizeBytes / bodyRate;
      rates.set(route.key,archive.sizeBytes/estimatedSeconds);
    }
  }));
  if (!current()) throw new Error('下载来源竞速已取消或方式已改变');
  const ready = measured.filter((route: JdkDownloadRoute): boolean => rates.has(route.key));
  ready.sort((a: JdkDownloadRoute,b: JdkDownloadRoute): number => {
    const ar = rates.get(a.key)!; const br = rates.get(b.key)!;
    // 相近样本优先源站，避免毫秒抖动反复切向镜像；差异显著时只按实际有效吞吐。
    if (Math.abs(ar-br) <= Math.max(ar,br)*0.05 && a.key !== b.key) {
      if (a.key === 'github-origin') return -1;
      if (b.key === 'github-origin') return 1;
    }
    return br-ar;
  });
  const used = new Set<string>(ready.map((route: JdkDownloadRoute): string => route.key));
  const fallback = routes.filter((route: JdkDownloadRoute): boolean => !route.probe && !used.has(route.key));
  const unmeasured = routes.filter((route: JdkDownloadRoute): boolean => route.probe && !used.has(route.key));
  return ready.concat(fallback,unmeasured);
}

/**
 * Minecraft 版本正文选源与公共元数据权限。自动档参考一次可验证的官方版本清单，
 * 进程内只会从镜像优先切换为官方优先。持久偏好与网关授权始终由原设置决定。
 */

import { AppLogger, BMCLAPI_BASE } from 'commons';
import { DownloadManager } from './DownloadManager';
import { getRelayClient } from './RelayClient';

const TAG = 'SourceProber';

/** 自动版本列表先请求官方；5 秒后并发启镜像，官方提早失败则立即启镜像。 */
const VERSION_MIRROR_DELAY_MS = 5000;
/** 官方清单足够快时锁定同进程的正文优先级；只采信真实完整请求。 */
const PREFER_MOJANG_MAX_RTT_MS = 4000;

let sourcePreference: string = 'auto';
let preferMojang: boolean = false;

/** 归一化脏数据到 'auto'。 */
function normalizeMode(mode: string): string {
  return (mode === 'mirror' || mode === 'official') ? mode : 'auto';
}

/**
 * 注入用户的版本下载源偏好。由 Index 在读盘时和用户切换时各调一次
 * （与 `setJdkDownloadSource` 同款注入模式，避免 feature_core 反向依赖 feature_system）。
 */
export function setMcSourcePreference(mode: string): void {
  let normalized = normalizeMode(mode);
  if (normalized === sourcePreference) return;
  sourcePreference = normalized;
  AppLogger.info(TAG, 'MC download source preference set to ' + normalized);
}

export function getMcSourcePreference(): string {
  return sourcePreference;
}

/**
 * 以网关开关意图收紧候选。isEnabled不会因票据过期/熔断变为false，避免把路由
 * 故障变成镜像授权；关闭后仍读原偏好，不用额外缓存一个可能失配的加速bool。
 */
export function isOfficialMcSourceOnly(): boolean {
  return getRelayClient().isEnabled() || sourcePreference === 'official';
}

/**
 * 只识别现有下载器认识的公共镜像。精确解析authority，不能把相似前缀的作者域名
 * 或未知私有Maven仓库误删；原URL及query不被重写，也不据“未知”宣称它是官方。
 */
export function isKnownSourceMirror(url: string): boolean {
  let match = /^https?:\/\/([^/?#]+)(\/[^?#]*)?(?:[?#]|$)/i.exec(url);
  if (match === null) return false;
  let authority = match[1];
  let host = authority.substring(authority.lastIndexOf('@') + 1)
    .replace(/:[0-9]+$/, '').replace(/\.$/, '').toLowerCase();
  if (host === 'bmclapi2.bangbang93.com' || host === 'download.mcbbs.net'
    || host === 'mod.mcimirror.top') return true;
  let path = match[2] ?? '/';
  return host === 'maven.aliyun.com'
    && (path === '/repository/public' || path.startsWith('/repository/public/'));
}

/** 纯候选过滤：非严格档保持原顺序/字节；严格档删空时返回空，由调用者明确报错。 */
export function filterKnownSourceMirrors(urls: string[], officialOnly: boolean): string[] {
  return urls.filter((url: string): boolean => !officialOnly || !isKnownSourceMirror(url));
}

/** MC与加载器的公共入口；未知作者原始地址保留，禁止删空后再暗补BMCL。 */
export function selectMcSourceUrls(urls: string[]): string[] {
  return filterKnownSourceMirrors(urls, isOfficialMcSourceOnly());
}

/**
 * 公共GET调用点的额外URI凭据边界。加载器/Mojang/Maven固定端点没有query或userinfo；
 * 动态作者地址若携带这些信息，保留原URL直连，不因新opt-in把潜在凭据送网关。
 * MR搜索的公开query由其已核实的独立API调用点处理，不使用本窄校验。
 */
export function canRelayPublicMcMetadata(urls: string[]): boolean {
  return urls.length > 0 && urls.every((url: string): boolean => /^https:\/\/[^/@?#]+\/[^?#]*$/i.test(url));
}

/**
 * 仅供已核实的Mojang/加载器/Maven公共GET使用。接口不接受业务头或请求正文，不能
 * 用于CF鉴权/账号请求；调用方必须明确选这个入口才启用metadata relay，通用
 * fetchTextEx的默认false不变。关闭网关时Native保持直连/原候选，不增加测速请求。
 */
export async function fetchPublicMcMetadata(urls: string[], timeoutSeconds: number = 30): Promise<string> {
  let allowed = selectMcSourceUrls(urls);
  if (allowed.length === 0) throw new Error('仅官方来源下没有可用的公共元数据地址');
  let response = await DownloadManager.instance().fetchTextEx(
    allowed[0], allowed.slice(1), timeoutSeconds, undefined, undefined, canRelayPublicMcMetadata(allowed));
  return response.body;
}

/** 仅在用户保留自动来源且网关关闭时，使用游戏版本专用的有序传输策略。 */
export function useOrderedMcDownload(): boolean {
  return sourcePreference === 'auto' && !getRelayClient().isEnabled();
}

/** 调用者已验证官方清单正文。磁盘、304 与网关响应不得作为官方直连样本。 */
export function observeDirectMojangManifest(elapsedMs: number): void {
  if (!preferMojang && elapsedMs >= 0 && elapsedMs < PREFER_MOJANG_MAX_RTT_MS) {
    preferMojang = true;
    AppLogger.info(TAG, 'Direct Mojang manifest ready in ' + elapsedMs.toString() + 'ms; prefer official files');
  }
}

/**
 * 调度两个完整版本列表请求。回调负责验证数据结构，首个有效结果生效。
 * 已启动的 Native 元数据请求各自有期限，丢失竞争的请求只观察结果，不重复发布。
 * 进入显式官方或网关模式后，尚未开始的镜像不得启动，在途镜像也失去发布权。
 */
export async function fetchMcVersionListSources<T>(official: () => Promise<T>, mirror: () => Promise<T>): Promise<T> {
  if (isOfficialMcSourceOnly()) return official();
  if (sourcePreference === 'mirror') {
    try {
      const value = await mirror();
      if (!isOfficialMcSourceOnly()) return value;
    } catch (error) { /* 镜像不成立时尝试真实上游。 */ }
    return official();
  }
  return new Promise<T>((resolve, reject): void => {
    let settled = false;
    let startedMirror = false;
    let officialError: Error | undefined = undefined;
    let mirrorError: Error | undefined = undefined;
    let delayTimer = -1;
    const succeed = (value: T): void => {
      if (settled) return;
      settled = true;
      clearTimeout(delayTimer);
      resolve(value);
    };
    const failIfExhausted = (): void => {
      if (settled || officialError === undefined || (mirrorError === undefined && !isOfficialMcSourceOnly())) return;
      settled = true;
      clearTimeout(delayTimer);
      reject(mirrorError ?? officialError);
    };
    const startMirror = (): void => {
      if (settled || startedMirror || isOfficialMcSourceOnly()) { failIfExhausted(); return; }
      startedMirror = true;
      mirror().then((value: T): void => {
        if (isOfficialMcSourceOnly()) {
          mirrorError = new Error('版本列表镜像已被当前来源策略禁止');
          failIfExhausted();
          return;
        }
        succeed(value);
      }, (error: Error): void => {
        mirrorError = error;
        failIfExhausted();
      });
    };
    delayTimer = setTimeout(startMirror, VERSION_MIRROR_DELAY_MS);
    official().then(succeed, (error: Error): void => {
      officialError = error;
      startMirror();
      failIfExhausted();
    });
  });
}

/** 显式源优先级高于进程内官方清单观察。自动档在首次成功观察前从镜像起步。 */
export function shouldUseBmclapiFirst(): boolean {
  if (isOfficialMcSourceOnly()) return false;
  return sourcePreference === 'mirror' || !preferMojang;
}

/** 生成公开文件候选。明确官方或网关模式只保留官方；其他模式保持两源回退。 */
export function buildSortedUrls(bmclapiUrl: string, mojangUrl: string): string[] {
  if (isOfficialMcSourceOnly()) return [mojangUrl];
  return shouldUseBmclapiFirst() ? [bmclapiUrl, mojangUrl] : [mojangUrl, bmclapiUrl];
}

/** 重排已解析的加载器安装器候选，不改写源 URL 或额外授予来源权限。 */
export function orderMcLoaderDownloadUrls(urls: string[]): string[] {
  const allowed = selectMcSourceUrls(urls);
  if (!useOrderedMcDownload()) return allowed;
  const primary = allowed.filter((url: string): boolean => url.startsWith(BMCLAPI_BASE + '/maven/'));
  const secondary = allowed.filter((url: string): boolean => url.startsWith(BMCLAPI_BASE + '/libraries/'));
  const direct = allowed.filter((url: string): boolean => primary.indexOf(url) < 0 && secondary.indexOf(url) < 0);
  return shouldUseBmclapiFirst() ? primary.concat(direct, secondary) : direct.concat(primary, secondary);
}

/** 宁泽/枫源独立协议层：公开身份发现、短时权限、固定宽度PoW和源级退避；不拥有更新流程。 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { SideloadUpdateAsset } from 'update';
import testNapi from 'libentry.so';
import { SideloadDownloadSource, SideloadMirrorCandidate, MirrorJsonFetcher } from './SideloadMirrorTypes';
interface MiawaPrepareRequest { file_path: string; source: string; }
interface FyhubChallengeRequest { asset_id: string; }
interface FyhubAuthorizeRequest { challenge_id: string; asset_id: string; solution: string; }

export class SideloadMirrorProviders {
  private static requestBoundary: MirrorJsonFetcher | undefined = undefined;
  /** 受控宿主只替换平台边界；生产未注入时始终走固定HTTP实现，不覆写对象方法。 */
  static setRequestBoundary(fetcher: MirrorJsonFetcher): void { SideloadMirrorProviders.requestBoundary = fetcher; }
  /** @throws 供应方错误只由协调器按来源隔离，不能输出授权正文。 */
  static json(url: string, body?: Object): Promise<Record<string, Object>> {
    const boundary = SideloadMirrorProviders.requestBoundary;
    return boundary === undefined ? SideloadMirrorProviders.requestJson(url, body) : boundary(url, body);
  }
  private static retryAfter: Map<string, number> = new Map();
  private static responseDate: Map<string, number> = new Map();
  private static leaseSequence: number = 0;
  /** 产品/版本/摘要/长度/名字共同绑定权限；刷新不能从旧候选偷换为另一个原件。 */
  static identity(asset: SideloadUpdateAsset): string {
    return JSON.stringify([asset.tag, asset.product, asset.versionCode.toString(), asset.sha256, asset.sizeBytes.toString(), asset.name]);
  }
  /** Native与ArkTS使用同一steady基准，用户改时钟不能延长已经签发的lease。 */
  static now(): number { return testNapi.downloadSteadyTime(); }
  /** 下载节点429/503与授权API共用主机退避事实，备用请求不能靠换新token绕过Retry-After。 */
  static noteCooldown(url: string, delayMs: number): void {
    const host = url.split('/')[2];
    SideloadMirrorProviders.retryAfter.set(host, Math.max(SideloadMirrorProviders.retryAfter.get(host) ?? 0,
      SideloadMirrorProviders.now() + Math.min(86400000, Math.max(1000, delayMs))));
  }
  static sourceReady(url: string): boolean { return (SideloadMirrorProviders.retryAfter.get(url.split('/')[2]) ?? 0) <= SideloadMirrorProviders.now(); }
  /** 复制已核实的公开目标，外部UI对象后续改变不能偷换一次发现结果。 */
  private static candidate(asset: SideloadUpdateAsset, provider: string, locator: string): SideloadMirrorCandidate {
    const fixed: SideloadUpdateAsset = { tag: asset.tag, product: asset.product, versionCode: asset.versionCode,
      versionName: asset.versionName, name: asset.name, sha256: asset.sha256, sizeBytes: asset.sizeBytes,
      url: asset.url, legacyUniversal: asset.legacyUniversal };
    return { asset: fixed, assetKey: SideloadMirrorProviders.identity(fixed), provider: provider, locator: locator };
  }
  /** 只重领当前候选权限；不重跑公开目录请求，也不允许locator或产品身份换成其他原件。
   * @throws 取消、权限或候选格式不匹配的Promise交协调器处理。
   */
  static authorize(candidate: SideloadMirrorCandidate, active: () => boolean): Promise<SideloadDownloadSource> {
    if (candidate.assetKey !== SideloadMirrorProviders.identity(candidate.asset)) return Promise.reject(new Error('镜像候选身份已变化'));
    if (candidate.provider === 'miawa') return SideloadMirrorProviders.authorizeMiawa(candidate, active);
    if (candidate.provider === 'fyhub') return SideloadMirrorProviders.authorizeFyhub(candidate, active);
    return Promise.reject(new Error('镜像候选来源无效'));
  }
  /** HTTP实例正文收齐后释放；错误不携带上游响应。
   * @throws 网络/限流/无效正文由调用方按来源隔离，不能把授权正文写入错误日志。
   */
  private static async requestJson(url: string, body?: Object): Promise<Record<string, Object>> {
    const host = url.split('/')[2];
    if ((SideloadMirrorProviders.retryAfter.get(host) ?? 0) > SideloadMirrorProviders.now()) throw new Error('镜像暂时繁忙，正在使用备用来源');
    const request = http.createHttp();
    try {
      const response = await request.request(url, { method: body === undefined ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'User-Agent': 'AMCL' },
        extraData: body === undefined ? '' : JSON.stringify(body), expectDataType: http.HttpDataType.STRING,
        connectTimeout: 12000, readTimeout: 15000 });
      if (response.responseCode === 429 || response.responseCode === 503) {
        const headers = response.header as Record<string, Object>;
        const raw = String(headers['retry-after'] ?? headers['Retry-After'] ?? '60');
        const seconds = Number(raw);
        const delay = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(raw) - Date.now();
        SideloadMirrorProviders.retryAfter.set(host, SideloadMirrorProviders.now() + Math.min(86400000, Math.max(1000, Number.isFinite(delay) ? delay : 60000)));
      }
      const responseHeaders = response.header as Record<string, Object>;
      const remoteDate = Date.parse(String(responseHeaders['date'] ?? responseHeaders['Date'] ?? ''));
      if (Number.isFinite(remoteDate)) SideloadMirrorProviders.responseDate.set(host, remoteDate);
      else SideloadMirrorProviders.responseDate.delete(host);
      if (response.responseCode < 200 || response.responseCode >= 300 || typeof response.result !== 'string' || response.result.length > 2 * 1024 * 1024) {
        throw new Error('镜像暂不可用');
      }
      return JSON.parse(response.result) as Record<string, Object>;
    } finally { request.destroy(); }
  }
  /** 在新下载前重新领取一次性授权；不把带token的URL交给持久化下载器。
   * @throws 公开目录或授权失败交协调器处理。
   */
  static async miawa(asset: SideloadUpdateAsset, active: () => boolean = (): boolean => true): Promise<SideloadDownloadSource> {
    return SideloadMirrorProviders.authorize(await SideloadMirrorProviders.discoverMiawa(asset, active), active);
  }
  /** 公开目录发现只核实资产，不提前创建可消费token。
   * @throws 网络、取消或唯一资产身份不匹配由协调器隔离该来源。
   */
  static async discoverMiawa(asset: SideloadUpdateAsset, active: () => boolean): Promise<SideloadMirrorCandidate> {
    const response = await SideloadMirrorProviders.json('https://miawa.cn/api/v2/launchers/amcl');
    if (!active()) throw new Error('更新已取消');
    const releases = response['data'] as Record<string, Object>[];
    if (!Array.isArray(releases)) throw new Error('宁泽镜像尚未同步');
    let matches = 0;
    for (const release of releases) {
      if (release === null || typeof release !== 'object' || release['tag_name'] !== asset.tag || !Array.isArray(release['assets'])) continue;
      for (const item of release['assets'] as Record<string, Object>[]) {
        if (item !== null && typeof item === 'object' && item['name'] === asset.name && item['size'] === asset.sizeBytes && String(item['sha256']).toLowerCase() === asset.sha256) matches++;
      }
    }
    if (matches !== 1) throw new Error('宁泽镜像文件身份不匹配');
    const filePath = 'amcl/' + asset.tag + '/' + asset.name;
    return SideloadMirrorProviders.candidate(asset, 'miawa', filePath);
  }
  /** @throws 短时权限失败保留公开候选，不携带上游响应或token进入诊断。 */
  private static async authorizeMiawa(candidate: SideloadMirrorCandidate, active: () => boolean): Promise<SideloadDownloadSource> {
    const asset = candidate.asset;
    const filePath = 'amcl/' + asset.tag + '/' + asset.name;
    if (candidate.locator !== filePath || !active()) throw new Error('镜像候选已失效');
    const prepare: MiawaPrepareRequest = { file_path: filePath, source: 'amcl-updater' };
    const issued = SideloadMirrorProviders.now();
    const authorized = await SideloadMirrorProviders.json('https://miawa.cn/api/v2/downloads/prepare', prepare);
    if (!active()) throw new Error('更新已取消');
    const data = authorized['data'] as Record<string, Object>;
    const token = String(data?.['download_token'] ?? '');
    const expected = '/download/' + filePath.split('/').map((part: string): string => encodeURIComponent(part)).join('/');
    const url = String(data?.['download_url'] ?? '').split('?')[0];
    if (!new RegExp('^[A-Za-z0-9_-]{43}$').test(token) || (url !== expected && url !== 'https://miawa.cn' + expected)) {
      throw new Error('宁泽镜像下载授权无效');
    }
    // 五分钟从请求开始保守计时，预留五秒；GET消费之后必须领取新权限。
    const deadline = issued + 295000;
    return { label: '宁泽镜像', provider: 'miawa', url: 'https://miawa.cn' + expected, token: token,
      candidate: candidate,
      assetKey: SideloadMirrorProviders.identity(asset), leaseGeneration: ++SideloadMirrorProviders.leaseSequence,
      leaseDeadlineMs: deadline, authorizedPolicy: { singleUse: true, maxHttpAttempts: 1,
        validForNewRequestMs: Math.max(1, Math.floor(deadline - SideloadMirrorProviders.now())), maxBytes: asset.sizeBytes } };
  }
  /** 固定 384 字节 base64url 与 hex 转换。输出前导零必须保留，不能按变长整数编码。 */
  private static decodeHex(value: string): string {
    if (!new RegExp('^[A-Za-z0-9_-]{512}$').test(value)) throw new Error('镜像挑战编码无效');
    const bytes = new util.Base64Helper().decodeSync(value.replace(new RegExp('-', 'g'), '+').replace(new RegExp('_', 'g'), '/'));
    if (bytes.length !== 384) throw new Error('镜像挑战长度无效');
    let result = ''; for (const byte of bytes) result += byte.toString(16).padStart(2, '0'); return result;
  }
  private static encodeSolution(value: string): string {
    if (!new RegExp('^[0-9a-f]{768}$').test(value)) throw new Error('镜像验证计算未完成');
    const bytes = new Uint8Array(384);
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(value.substring(i * 2, i * 2 + 2), 16);
    return new util.Base64Helper().encodeToStringSync(bytes).replace(new RegExp('\\+', 'g'), '-').replace(new RegExp('/', 'g'), '_').replace(new RegExp('=+$'), '');
  }
  /** 严格实现枫源公开V2，挑战与授权同一设备发出，不携带Developer key。
   * @throws 公开目录、挑战或权限失败交协调器处理。
   */
  static async fyhub(asset: SideloadUpdateAsset, active: () => boolean = (): boolean => true): Promise<SideloadDownloadSource> {
    return SideloadMirrorProviders.authorize(await SideloadMirrorProviders.discoverFyhub(asset, active), active);
  }
  /** asset_id只在公开身份完整匹配后建立候选，不能从外部清单直接领取任意权限。
   * @throws 网络、取消或错误资产不允许继续挑战。
   */
  static async discoverFyhub(asset: SideloadUpdateAsset, active: () => boolean): Promise<SideloadMirrorCandidate> {
    const response = await SideloadMirrorProviders.json('https://fyhub.cn/api/public/v1/projects/amcl/assets');
    if (!active()) throw new Error('更新已取消');
    const data = response['data'] as Record<string, Object>;
    const assets = data?.['assets'] as Record<string, Object>[];
    if (!Array.isArray(assets)) throw new Error('枫源镜像尚未同步');
    const matches = assets.filter((item: Record<string, Object>): boolean => item !== null && typeof item === 'object' && item['available'] === true &&
      item['version'] === asset.tag && item['file_name'] === asset.name && item['size_bytes'] === asset.sizeBytes &&
      String(item['digest_sha256']).toLowerCase().replace(new RegExp('^sha256:'), '') === asset.sha256);
    if (matches.length !== 1) throw new Error('枫源镜像文件身份不匹配');
    const id = String(matches[0]['asset_id']);
    if (!new RegExp('^[A-Za-z0-9_:-]{1,128}$').test(id)) throw new Error('枫源资产编号无效');
    return SideloadMirrorProviders.candidate(asset, 'fyhub', id);
  }
  /** @throws 挑战/过期/预算或节点格式错误由协调器有限恢复，不写授权内容。 */
  private static async authorizeFyhub(candidate: SideloadMirrorCandidate, active: () => boolean): Promise<SideloadDownloadSource> {
    const asset = candidate.asset, id = candidate.locator;
    if (!new RegExp('^[A-Za-z0-9_:-]{1,128}$').test(id) || !active()) throw new Error('镜像候选已失效');
    const input: FyhubChallengeRequest = { asset_id: id };
    const challengeResponse = await SideloadMirrorProviders.json('https://fyhub.cn/api/public/v2/api/challenges', input);
    if (!active()) throw new Error('更新已取消');
    const challenge = challengeResponse['data'] as Record<string, Object>;
    const iterations = Number(challenge?.['iterations']);
    if (challenge?.['algorithm'] !== 'rsa-repeated-squaring-v1' || challenge['encoding'] !== 'base64url-uint-be-384' ||
      challenge['asset_id'] !== id || !Number.isInteger(iterations) || iterations < 1 || iterations > 1000000) throw new Error('枫源挑战格式不受支持');
    const solution = SideloadMirrorProviders.encodeSolution(await testNapi.solveSideloadPow(
      SideloadMirrorProviders.decodeHex(String(challenge['modulus'])), SideloadMirrorProviders.decodeHex(String(challenge['base'])), iterations));
    if (!active()) throw new Error('更新已取消');
    const request: FyhubAuthorizeRequest = { challenge_id: String(challenge['challenge_id']), asset_id: id, solution: solution };
    const authorized = await SideloadMirrorProviders.json('https://fyhub.cn/api/public/v2/api/authorizations', request);
    if (!active()) throw new Error('更新已取消');
    const auth = authorized['data'] as Record<string, Object>;
    const token = String(auth?.['download_token'] ?? ''); const url = String(auth?.['download_url'] ?? '');
    const concurrency = Number(auth?.['range_concurrency_limit']);
    const budget = Number(auth?.['max_bytes']);
    // 节点由官方 API 指定，可以是合作节点域名；只接收 HTTPS 域名，不允许 IP、凭据或任意本地协议。
    if (!new RegExp('^https://[a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*\\.[a-zA-Z]{2,}(?::[0-9]{1,5})?/[^\\r\\n]*$').test(url) ||
      !new RegExp('^[A-Za-z0-9_-]{43}$').test(token) || !Number.isSafeInteger(concurrency) || concurrency < 1 ||
      !Number.isSafeInteger(budget) || budget < asset.sizeBytes || url.includes(token) ||
      new RegExp('[?&](token|download_token|authorization)=', 'i').test(url)) throw new Error('枫源下载授权无效');
    const expiry = Date.parse(String(auth?.['expires_at'] ?? ''));
    const serverDate = SideloadMirrorProviders.responseDate.get('fyhub.cn');
    // 优先服务端Date消除本机时钟偏差；无Date时只给保守短窗口，不保存UTC作为单调截止。
    const remaining = Math.min(serverDate === undefined ? 60000 : 3600000,
      expiry - (serverDate === undefined ? Date.now() : serverDate) - 5000);
    if (!Number.isFinite(remaining) || remaining < 5000) throw new Error('枫源授权已过期');
    const deadline = SideloadMirrorProviders.now() + remaining;
    return { label: '枫源镜像', provider: 'fyhub', url: url, token: token, leaseDeadlineMs: deadline,
      candidate: candidate,
      assetKey: SideloadMirrorProviders.identity(asset), leaseGeneration: ++SideloadMirrorProviders.leaseSequence,
      authorizedPolicy: { singleUse: false, maxHttpAttempts: 4, validForNewRequestMs: Math.floor(remaining), maxBytes: budget } };
  }

}

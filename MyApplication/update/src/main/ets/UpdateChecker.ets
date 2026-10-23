import { DistributionPolicy, DiagnosticPolicy } from 'commons';
import { SideloadDelivery } from './SideloadUpdateModels';
import { GitHubUpdateAssetResolver } from './GitHubUpdateAssetResolver';
import { AppUpdatePolicy } from './AppUpdatePolicy';
/**
 * UpdateChecker.ets — 检查更新（官网当前推荐头、发布者静态快照兜底）
 *
 * 系统 versionCode 负责安装兼容性，发行 versionName 负责同 code 的预览序列与返回正式版。
 * 清单按产品和订阅通道隔离；GitHub 的 /latest 跳过 prerelease，不能用作预览通道事实源。
 *
 * 网络走 DownloadManager.fetchText（libcurl NAPI，CA bundle 已在 EntryAbility 初始化，
 * 内置多源 fallback）。纯逻辑 + 易测：解析与比较拆成静态纯函数。
 */

import { bundleManager } from '@kit.AbilityKit';
import { DownloadManager, DownloadFailure } from 'feature_core';
import { UPDATE_MANIFEST_URLS } from 'commons';
import { formatError } from 'commons';
import { AppLogger } from 'commons';
import { normalizeNoteType } from './ChangelogTypes';

const TAG = 'UpdateChecker';

/** 本客户端支持的 update.json 结构版本。线上 schema 更大 → 只用老字段（前向兼容）。 */
const SUPPORTED_MANIFEST_SCHEMA: number = 1;

/** 更新说明的一个结构化条目（新弹窗按分类渲染）。type 见 AMCL-web/CHANGELOG-SPEC.md。 */
export interface UpdateNoteEntry {
  type: string;   // highlight | added | improved | refactored | fixed | notice
  text: string;   // 纯文本（生成期已剥掉 Markdown，可直接显示）
}

/**
 * 线上 update.json 的结构（由 AMCL-web/scripts/gen-update-manifest.mjs 生成，不再手写）。
 *
 * 兼容硬约束（详见 AMCL-web/CHANGELOG-SPEC.md 第四节）：
 *   - 上半部分是**老字段**，语义/类型永不变更：≤1.0.1 的客户端只认这些，且把 `notes`
 *     原样塞进系统弹窗，所以 notes 必须一直是 ≤6 行中文纯文本。
 *   - 下半部分是**新字段**：老客户端静默忽略；新客户端按 `schema` 判定可用性，
 *     拿不到就降级回 `notes`（update.json 被回滚时会走到这条路）。
 */
export interface UpdateManifest {
  /** 缺失仅兼容旧稳定正式清单；preview 必须由发布者明确声明。 */
  updateChannel?: string;
  prerelease?: boolean;
  publicationId?: string;
  /** 新清单只在官网副本及主镜像就绪后发布；旧客户端可忽略此扩展字段。 */
  delivery?: SideloadDelivery;
  versionCode: number;   // 与 app.json5 同数轴；预览版沿用上一正式版编号
  versionName: string;   // 发行身份，如 "1.0.6-pre1"，也是同 code 比较依据
  tag: string;           // git tag，如 "v1.0.0-beta.1"
  url: string;           // 下载/发布页（前往下载时浏览器打开）
  notes: string;         // 更新说明（多行纯文本，老客户端唯一可读的字段）
  mandatory: boolean;    // 是否强制更新（弹窗改为单按钮）

  schema: number;                   // 线上结构版本；老清单缺省 0
  date: string;                     // 发布日期 YYYY-MM-DD，缺省 ''
  sizeBytes: number;                // HAP 体积，缺省 0（不展示）
  changelogUrl: string;             // 网页版完整更新日志，缺省 ''
  notesEntries: UpdateNoteEntry[];  // 结构化条目，缺省 []（此时 UI 应回退解析 notes）
}

/** 检查结果。ok=网络+解析成功；hasUpdate=有新版。 */
export interface UpdateCheckResult {
  ok: boolean;
  hasUpdate: boolean;
  current: number;                 // 设备已装 versionCode
  manifest: UpdateManifest | null;
  error: string;
}

export class UpdateChecker {
  /** 红点延后绑定资产身份，镜像健康变化不制造新版本提示。 */
  static targetKey(manifest: UpdateManifest, product: string): string {
    const name=GitHubUpdateAssetResolver.assetProduct(product);
    const asset=Array.isArray(manifest.delivery?.assets) ? manifest.delivery?.assets.find((value): boolean => value.product===name) : undefined;
    return manifest.tag+':'+manifest.versionCode+':'+(asset?.sha256 ?? '');
  }
  /** 启动自动检查的节流间隔（ms）。同一设备 24 小时内最多自动查一次，避免每次启动都联网。 */
  static readonly AUTO_CHECK_INTERVAL_MS: number = 24 * 60 * 60 * 1000;

  /**
   * wall-clock 间隔是否已满。时间回拨或损坏值按“已满”处理，避免更新检查被永久压制。
   */
  private static autoCheckIntervalElapsed_(nowMs: number, sinceMs: number): boolean {
    if (!Number.isFinite(nowMs) || nowMs <= 0) return true;
    if (!Number.isFinite(sinceMs) || sinceMs <= 0) return true;
    if (nowMs < sinceMs) return true;
    return nowMs - sinceMs >= UpdateChecker.AUTO_CHECK_INTERVAL_MS;
  }

  /** 点击「稍后」后是否已经可以再次自动弹窗。 */
  static shouldShowAutoPrompt(nowMs: number, deferredAtMs: number): boolean {
    return UpdateChecker.autoCheckIntervalElapsed_(nowMs, deferredAtMs);
  }

  /** 红点沿用与联网候选相同的比较，升级后同 code 的旧预览缓存也会自然消失。 */
  static hasCachedUpdate(currentVersionCode: number, latestSeenVersionCode: number,
    currentName: string = '', latestName: string = '', channel: string = 'stable'): boolean {
    return AppUpdatePolicy.canInstall(currentVersionCode,currentName,latestSeenVersionCode,latestName,channel);
  }

  /** 版本名必须读取实际安装包，不能使用可能滞后的展示常量作为同 code 安装证据。 */
  static currentVersionName(): string {
    try { return bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName; }
    catch (_) { return ''; }
  }

  /** 页面、自动检查和手动包预检共享准入，防止 UI 仍只按数字过滤掉预览版。 */
  static canInstall(manifest: UpdateManifest, channel: string = 'stable'): boolean {
    return AppUpdatePolicy.canInstall(UpdateChecker.currentVersionCode(),UpdateChecker.currentVersionName(),
      manifest.versionCode,manifest.versionName,channel);
  }

  /** 切回稳定版是显式候选操作，仍由用户点击安装，自动检查本身不会覆盖应用。 */
  static isStableReturn(manifest: UpdateManifest): boolean {
    return manifest.versionCode === UpdateChecker.currentVersionCode() && AppUpdatePolicy.prerelease(UpdateChecker.currentVersionName()) &&
      !AppUpdatePolicy.prerelease(manifest.versionName) && AppUpdatePolicy.compare(manifest.versionName,UpdateChecker.currentVersionName()) < 0;
  }

  /**
   * 启动时是否应联网检查：
   * - 已知有新版且「稍后」未满 24h：不联网、不弹窗，缓存红点继续显示；
   * - 「稍后」已满 24h：即使上次检查较新，也刷新 manifest 后重新提示；
   * - 其它情况：按上次成功检查时间做 24h 节流。
   */
  static shouldRunAutoCheck(
    nowMs: number,
    lastCheckAtMs: number,
    deferredAtMs: number,
    hasCachedUpdate: boolean
  ): boolean {
    if (hasCachedUpdate && !UpdateChecker.shouldShowAutoPrompt(nowMs, deferredAtMs)) return false;
    if (hasCachedUpdate && deferredAtMs > 0) return true;
    return UpdateChecker.autoCheckIntervalElapsed_(nowMs, lastCheckAtMs);
  }

  /** 取设备已装 versionCode（同步）。失败返回 0（→ 任意线上版本都视为更新）。 */
  static currentVersionCode(): number {
    try {
      let info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionCode;
    } catch (e) {
      AppLogger.warn(TAG, 'getBundleInfoForSelfSync failed', e as Object);
      return 0;
    }
  }

  /**
   * 解析 update.json。缺 versionCode（核心字段）→ null。其余字段缺失给默认值。
   *
   * 新字段一律「宽进」：类型不对 / 缺失 / schema 超前，都退化为默认值而**不是**解析失败
   * ——检查更新的可用性绝不能被展示层的新字段拖累。
   */
  static parseManifest(body: string): UpdateManifest | null {
    try {
      let o = JSON.parse(body) as Record<string, Object>;
      // 版本身份使用正整数；展示字段损坏不得影响这个核心事实。
      if (typeof o['versionCode'] !== 'number' || !Number.isSafeInteger(o['versionCode']) || Number(o['versionCode']) < 1) return null;
      if ((o['updateChannel'] !== undefined && o['updateChannel'] !== 'stable' && o['updateChannel'] !== 'preview') ||
        (o['prerelease'] !== undefined && typeof o['prerelease'] !== 'boolean')) return null;
      let schema: number = typeof o['schema'] === 'number' ? o['schema'] as number : 0;
      return {
        updateChannel: typeof o['updateChannel'] === 'string' ? String(o['updateChannel']) : undefined,
        prerelease: typeof o['prerelease'] === 'boolean' ? o['prerelease'] as boolean : undefined,
        publicationId: typeof o['publicationId'] === 'string' ? String(o['publicationId']) : '',
        versionCode: o['versionCode'] as number,
        versionName: typeof o['versionName'] === 'string' ? o['versionName'] as string : '',
        tag: typeof o['tag'] === 'string' ? o['tag'] as string : '',
        url: typeof o['url'] === 'string' ? o['url'] as string : '',
        notes: typeof o['notes'] === 'string' ? o['notes'] as string : '',
        mandatory: o['mandatory'] === true,
        schema: schema,
        date: typeof o['date'] === 'string' ? o['date'] as string : '',
        sizeBytes: typeof o['sizeBytes'] === 'number' ? o['sizeBytes'] as number : 0,
        changelogUrl: typeof o['changelogUrl'] === 'string' ? o['changelogUrl'] as string : '',
        // schema 比本客户端支持的更新 → 结构可能已改口径，不冒险解析，交给 notes 兜底
        notesEntries: schema > 0 && schema <= SUPPORTED_MANIFEST_SCHEMA
          ? UpdateChecker.parseNoteEntries_(o['notesEntries'])
          : [],
        delivery: typeof o['delivery'] === 'object' && o['delivery'] !== null ? o['delivery'] as SideloadDelivery : undefined,
      };
    } catch (e) {
      AppLogger.warn(TAG, 'parseManifest failed', e as Object);
      return null;
    }
  }

  /** notesEntries 数组解析。非数组 / 元素残缺 → 跳过该元素，不抛异常。 */
  private static parseNoteEntries_(raw: Object | undefined): UpdateNoteEntry[] {
    let out: UpdateNoteEntry[] = [];
    if (raw === undefined || !Array.isArray(raw)) return out;
    let arr = raw as Object[];
    for (let item of arr) {
      // JSON 的 null 同样具有 object 类型，必须先排除再读属性；数组也不是展示条目。
      if (item === null || typeof item !== 'object' || Array.isArray(item)) continue;
      let e = item as Record<string, Object>;
      let text = typeof e['text'] === 'string' ? e['text'] as string : '';
      if (text.length === 0) continue;
      let type = typeof e['type'] === 'string' ? e['type'] as string : '';
      out.push({ type: normalizeNoteType(type), text: text });
    }
    return out;
  }

  /**
   * 取用于展示的结构化更新说明：优先 `notesEntries`，为空时**回退解析 `notes` 纯文本**。
   *
   * 回退分支不是可选项 —— update.json 一旦被回滚到老格式（或 schema 超前），新版 App
   * 只能拿到 notes，此时必须仍能渲染出条目，否则弹窗会变成空白。
   */
  static displayEntries(m: UpdateManifest): UpdateNoteEntry[] {
    if (m.notesEntries.length > 0) return m.notesEntries;
    return UpdateChecker.entriesFromNotes(m.notes, m.versionName);
  }

  /**
   * 把 notes 纯文本拆成条目：`- 修复：xxx` / `- 修复 xxx` → { type: 'fixed', text: 'xxx' }。
   * 首行若只是版本号则丢弃；识别不出分类的行归为 notice（规范要求"未知归 notice，不丢弃"）。
   */
  static entriesFromNotes(notes: string, versionName: string): UpdateNoteEntry[] {
    let out: UpdateNoteEntry[] = [];
    if (notes.length === 0) return out;
    let lines = notes.split('\n');
    for (let i = 0; i < lines.length; i++) {
      let line = lines[i].trim();
      if (line.length === 0) continue;
      // 首行通常是 "1.0.2" / "1.0.2 紧急修复"，不作为条目
      if (i === 0 && versionName.length > 0 && line.indexOf(versionName) === 0) continue;
      if (line.startsWith('- ') || line.startsWith('· ') || line.startsWith('• ')) line = line.substring(2).trim();
      if (line.length === 0) continue;
      let type = 'notice';
      let text = line;
      let sep = line.indexOf('：');
      if (sep < 0) sep = line.indexOf(':');
      if (sep > 0 && sep <= 6) {
        let head = line.substring(0, sep).trim();
        let mapped = normalizeNoteType(head);
        if (mapped.length > 0 && mapped !== 'notice') {
          type = mapped;
          text = line.substring(sep + 1).trim();
        } else if (head === '提醒' || head === '注意') {
          type = 'notice';
          text = line.substring(sep + 1).trim();
        }
      }
      if (text.length > 0) out.push({ type: type, text: text });
    }
    return out;
  }

  /**
   * 读取当前产品和订阅通道的推荐，再与实际安装版本比较。
   * 正式检查优先官网当前头；只有官网不可用或元数据无效才回退发布者静态快照。
   * 不能在多个源中取最高版本：发布者可以撤回或降低推荐，静态镜像也可能暂时滞后。
   * 显式注入源只在给定列表中读取，避免诊断会话失败后混入真正的生产候选。
   */
  static async checkForUpdate(urls: string[] = UPDATE_MANIFEST_URLS, product: string = 'sideload', channel: string = 'stable'): Promise<UpdateCheckResult> {
    let current = UpdateChecker.currentVersionCode();
    let result: UpdateCheckResult = { ok: false, hasUpdate: false, current: current, manifest: null, error: '' };

    if (!DistributionPolicy.allowSideloadUpdates()) { result.error = '此渠道使用应用市场更新'; return result; }
    if (urls.length === 0) {
      result.error = '未配置更新源';
      return result;
    }
    // 调用方保留自己的来源/通道代次快照；本方法只返回结果，不触碰偏好、红点、
    // 弹窗或安装执行权。各次 await 返回后，是否仍消费结果继续由原调用方判定。
    channel = AppUpdatePolicy.channel(channel);
    const officialUrl = 'https://amcl.lovedhy.cn/api/packages/manifest?product=' + GitHubUpdateAssetResolver.assetProduct(product) + '&channel=' + channel;
    const production = urls.length === UPDATE_MANIFEST_URLS.length && urls.every((url: string, index: number): boolean => url === UPDATE_MANIFEST_URLS[index]);
    const candidates: string[] = production ? [officialUrl].concat(AppUpdatePolicy.urls(product,channel)) : urls.slice();
    // 老 update.json 只作稳定通道的末级兼容入口，预览检查不能退回稳定推荐。
    if (production && channel === 'stable') for (const url of UPDATE_MANIFEST_URLS) candidates.push(url);
    const fixture = DiagnosticPolicy.hasTestHooks() && urls[0].startsWith('https://amcl.lovedhy.cn/uploads/self-update-tests/');
    let m: UpdateManifest | null = null;
    let lastError = '';
    for (const source of candidates) {
      const currentHead = production && source === officialUrl;
      try {
        // 每个入口单独请求并解析；不能由网络层首个 HTTP 200 把 HTML/坏 JSON
        // 当成后续入口的成功结果。15 秒和 8191 字节限制继续下传 Native。
        const body = await DownloadManager.instance().fetchText(source, [], 15, 8191);
        const parsed = UpdateChecker.parseManifest(body);
        if (parsed === null || !AppUpdatePolicy.validVersion(parsed.versionName) || parsed.tag !== 'v' + parsed.versionName ||
          (!fixture && !AppUpdatePolicy.accepts(parsed.tag,parsed.updateChannel,parsed.prerelease,channel))) {
          lastError = '更新信息解析失败';
          continue;
        }
        // 当前头明确“没有更新”时不去静态源挑更高版本，兼容旧稳定清单尚无收据。
        // 静态快照则无论是否可更新都要求完整收据，缺收据的旧版不能再截断后源。
        if (!fixture && (!currentHead || UpdateChecker.canInstall(parsed,channel))) {
          try { GitHubUpdateAssetResolver.fromDelivery(parsed, product); }
          catch (_) {
            lastError = '新版本资源正在同步，准备完成后会提示更新';
            if (currentHead) {
              // 官网已经给出合法当前推荐，但目标未就绪或收据损坏。不能用静态
              // 旧头绕过这次决定；无 manifest 保证调用方不写入可更新缓存或红点。
              result.ok = true;
              result.error = lastError;
              return result;
            }
            continue;
          }
        }
        m = parsed;
        break;
      } catch (error) {
        // fetchText 只对 Native 失败补充 detail；其他普通 Error 没有该字段。
        // 404/409 是官网明确尚无就绪推荐，区别于超时、5xx或非法响应正文；此时
        // 不能复活可能已经撤回的静态推荐，也不能把“没有推荐”写成成功检查时间。
        const detail = (error as DownloadFailure).detail;
        if (currentHead && detail !== undefined && detail.kind === 'HttpStatus' &&
          (detail.httpStatus === 404 || detail.httpStatus === 409)) {
          result.error = '当前通道尚无已就绪的更新推荐';
          return result;
        }
        lastError = '网络请求失败：' + formatError(error);
      }
    }
    if (!m) {
      result.error = lastError || '更新信息解析失败';
      return result;
    }
    result.ok = true;
    result.manifest = m;
    result.hasUpdate = UpdateChecker.canInstall(m,channel);
    AppLogger.info(TAG, `checkForUpdate: current=${current} latest=${m.versionCode} hasUpdate=${result.hasUpdate ? 'yes' : 'no'}`);
    return result;
  }

  /** 本地 HAP 只凭包内版本定位官方历史收据，安装前仍匹配完整摘要及产品身份。 */
  static async publishedVersion(tag: string, product: string, channel: string): Promise<UpdateManifest> {
    if(!tag.startsWith('v') || !AppUpdatePolicy.validVersion(tag.substring(1))) throw new Error('安装包版本格式不受支持');
    const name=GitHubUpdateAssetResolver.assetProduct(product);
    const body=await DownloadManager.instance().fetchText('https://amcl.lovedhy.cn/api/packages/manifest?product='+name+'&channel='+AppUpdatePolicy.channel(channel)+'&tag='+encodeURIComponent(tag),[],15,8191);
    const manifest=UpdateChecker.parseManifest(body);
    if(manifest===null || manifest.tag!==tag || !AppUpdatePolicy.accepts(tag,manifest.updateChannel,manifest.prerelease,channel)) throw new Error('此版本不属于当前通道，或尚无官方发布记录');
    GitHubUpdateAssetResolver.fromDelivery(manifest,product);
    return manifest;
  }
}

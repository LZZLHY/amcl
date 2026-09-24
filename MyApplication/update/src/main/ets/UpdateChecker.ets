import { DistributionPolicy } from 'commons';
/**
 * UpdateChecker.ets — 检查更新（GitHub 权威源）
 *
 * 方案 B（versionCode 比较）：
 *   - 设备已装版本 versionCode 由 bundleManager.getBundleInfoForSelfSync 取（与 app.json5 同数轴）。
 *   - 线上最新版本由 amcl-public 仓库的 update.json 提供（发版者随发布手动同步）。
 *   - update.json.versionCode > 设备 versionCode → 有新版。
 *
 * 为什么不用 GitHub Releases API：它只暴露 tag_name、不暴露 versionCode；且 /releases/latest
 * 会跳过 pre-release（项目当前全是 alpha/beta）。用我们自维护的 update.json 最稳、最简单。
 *
 * 网络走 DownloadManager.fetchText（libcurl NAPI，CA bundle 已在 EntryAbility 初始化，
 * 内置多源 fallback）。纯逻辑 + 易测：解析与比较拆成静态纯函数。
 */

import { bundleManager } from '@kit.AbilityKit';
import { DownloadManager } from 'feature_core';
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
  versionCode: number;   // 与 app.json5 同数轴，比较的唯一依据
  versionName: string;   // 展示用，如 "1.0.0-beta.1"
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

  /** 持久化的线上版本仍高于已装版本时，红点必须立即显示，与弹窗延后状态无关。 */
  static hasCachedUpdate(currentVersionCode: number, latestSeenVersionCode: number): boolean {
    return latestSeenVersionCode > currentVersionCode;
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
      if (typeof o['versionCode'] !== 'number') return null;
      let schema: number = typeof o['schema'] === 'number' ? o['schema'] as number : 0;
      return {
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
      if (typeof item !== 'object') continue;
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
   * 拉取 update.json 并与设备版本比较。网络/解析失败时 ok=false + error。
   */
  static async checkForUpdate(): Promise<UpdateCheckResult> {
    let current = UpdateChecker.currentVersionCode();
    let result: UpdateCheckResult = { ok: false, hasUpdate: false, current: current, manifest: null, error: '' };

    if (!DistributionPolicy.allowSideloadUpdates()) { result.error = '此渠道使用应用市场更新'; return result; }
    if (UPDATE_MANIFEST_URLS.length === 0) {
      result.error = '未配置更新源';
      return result;
    }
    let primary = UPDATE_MANIFEST_URLS[0];
    let mirrors = UPDATE_MANIFEST_URLS.slice(1);
    let body = '';
    try {
      body = await DownloadManager.instance().fetchText(primary, mirrors, 15);
    } catch (e) {
      result.error = '网络请求失败：' + formatError(e);
      return result;
    }
    let m = UpdateChecker.parseManifest(body);
    if (!m) {
      result.error = '更新信息解析失败';
      return result;
    }
    result.ok = true;
    result.manifest = m;
    result.hasUpdate = m.versionCode > current;
    AppLogger.info(TAG, `checkForUpdate: current=${current} latest=${m.versionCode} hasUpdate=${result.hasUpdate ? 'yes' : 'no'}`);
    return result;
  }
}

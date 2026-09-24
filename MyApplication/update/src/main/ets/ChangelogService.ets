import { DistributionPolicy } from 'commons';
/**
 * ChangelogService.ets — 更新日志（全量历史）数据层
 *
 * 数据事实源在 AMCL-web 仓库的 `web/changelog/*.md`，由 `scripts/gen-changelog.mjs`
 * 生成 `changelog.json` 并同时发布三处（规范：AMCL-web/CHANGELOG-SPEC.md）：
 *   1. AMCL-web 权威接口      GET https://amcl.lovedhy.cn/api/changelog（带 ETag，最新）
 *      + 同源静态兜底         /changelog.json（-FrontendOnly 部署时前端会先于后端更新）
 *   2. amcl-public 仓库       GitHub Pages / raw / 3 个 ghproxy 镜像（国内兜底）
 *   3. 本包 rawfile 快照      随 HAP 发布，首装即有内容、离线可看
 *
 * 取数策略（照搬 ModTranslationLoader 已验证的形状）：
 *   - `loadLocal()`：内存 → 磁盘缓存 → 打包快照，**不联网**，几十毫秒返回，页面先出内容。
 *   - `refreshRemote()`：后台带 `If-None-Match` 拉一次，200 才写盘并通知 UI 重刷；
 *     304 / 失败 / 空 → 无操作（沿用本地）。每进程最多刷一次。
 *
 * ⚠️ 上架轨（`DistributionPolicy.isStore()`）**完全不联网**，只读随包快照：
 *    APP 备案口径「无自有服务器」，且商店分发的版本更新由应用市场负责。
 *
 * 兼容（规范第三节 + 第四节铁律 3/4）：
 *   - `schema` 大于本客户端支持值 → 视为不可解析，沿用已有本地数据，不抛错。
 *   - 未知 `type` 归 notice；缺失字段给默认值；任何一条坏数据只跳过它自己。
 *
 * 创建日期：2026-08-08
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { DownloadManager, FetchTextRichResult } from 'feature_core';
import { AppLogger, LOG_DOMAIN_DOWNLOAD } from 'commons';
import { DeviceProfile } from 'commons';
import { CHANGELOG_JSON_URLS, CHANGELOG_RAWFILE } from 'commons';
import { normalizeNoteType, noteTypeRank } from './ChangelogTypes';

const TAG = 'ChangelogService';
/** 本客户端支持的 changelog.json 结构版本。 */
const SUPPORTED_SCHEMA: number = 1;
const FETCH_TIMEOUT_SECONDS: number = 12;
/** 响应体上限：13 个版本双语约 60KB，留足余量同时挡住异常大响应。 */
const MAX_RESPONSE_BYTES: number = 1024 * 1024;
const CACHE_DIR_NAME = 'changelog';

/** 更新日志的一条变更。 */
export interface ChangelogEntry {
  type: string;   // highlight | added | improved | refactored | fixed | notice
  text: string;   // 纯文本，可直接显示
}

/** 一个版本的更新日志。 */
export interface ChangelogRelease {
  versionName: string;
  versionCode: number;
  tag: string;
  date: string;
  prerelease: boolean;
  url: string;            // 该版本的 GitHub Release 页
  title: string;          // 一句话主题，可能为空
  summary: string;        // 导语，可能为空
  entries: ChangelogEntry[];
}

/** 一次加载的结果。releases 倒序（最新在前）。 */
export interface ChangelogSnapshot {
  ok: boolean;
  schema: number;
  releases: ChangelogRelease[];
  /** 数据来自哪一层：remote / cache / bundled / none */
  source: string;
  error: string;
}

const EMPTY_SNAPSHOT: ChangelogSnapshot = { ok: false, schema: 0, releases: [], source: 'none', error: '' };

let cached_: ChangelogSnapshot | null = null;
let inflightLocal_: Promise<ChangelogSnapshot> | null = null;
let remoteRefreshDone_: boolean = false;

// ---------------- 远程刷新完成通知（供页面重刷） ----------------

type ChangelogUpdateListener = () => void;
let listeners_: ChangelogUpdateListener[] = [];

/** 注册「远程刷新拿到新内容」的监听器（页面 aboutToAppear 注册）。 */
export function onChangelogUpdated(cb: ChangelogUpdateListener): void {
  listeners_.push(cb);
}

/** 注销监听器（页面 aboutToDisappear 调用，避免累积）。 */
export function offChangelogUpdated(cb: ChangelogUpdateListener): void {
  let i = listeners_.indexOf(cb);
  if (i >= 0) listeners_.splice(i, 1);
}

function notifyUpdated_(): void {
  for (let cb of listeners_) {
    try { cb(); } catch (e) { /* 单个监听器抛错不影响其他 */ }
  }
}

// ---------------- 文件 IO ----------------

function readTextFile_(path: string): string {
  try {
    if (!fileIo.accessSync(path)) return '';
    let stat = fileIo.statSync(path);
    if (stat.size <= 0) return '';
    let f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    let buf = new ArrayBuffer(stat.size);
    let len = fileIo.readSync(f.fd, buf);
    fileIo.closeSync(f);
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(buf.slice(0, len)));
  } catch (e) {
    return '';
  }
}

function writeTextFile_(path: string, text: string): void {
  try {
    let f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, text);
    fileIo.closeSync(f);
  } catch (e) {
    AppLogger.warn(TAG, '写缓存失败: ' + path, e as Object, LOG_DOMAIN_DOWNLOAD);
  }
}

async function readRawText_(ctx: common.UIAbilityContext, name: string): Promise<string> {
  try {
    let bytes = await ctx.resourceManager.getRawFileContent(name);
    if (bytes === undefined || bytes.byteLength === 0) return '';
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(bytes);
  } catch (e) {
    // 首个带本特性的版本之前打的包没有这个 rawfile，属正常情况，降为 info
    AppLogger.info(TAG, '无随包更新日志快照: ' + name, LOG_DOMAIN_DOWNLOAD);
    return '';
  }
}

// ---------------- 解析 ----------------

function asString_(v: Object | undefined): string {
  return typeof v === 'string' ? v as string : '';
}

function asNumber_(v: Object | undefined): number {
  return typeof v === 'number' ? v as number : 0;
}

function parseEntries_(raw: Object | undefined): ChangelogEntry[] {
  let out: ChangelogEntry[] = [];
  if (raw === undefined || !Array.isArray(raw)) return out;
  let arr = raw as Object[];
  for (let item of arr) {
    if (typeof item !== 'object') continue;
    let e = item as Record<string, Object>;
    let text = asString_(e['text']);
    if (text.length === 0) continue;
    out.push({ type: normalizeNoteType(asString_(e['type'])), text: text });
  }
  // 归一化展示顺序（生成器已排好，这里再兜一次，避免手工改过的镜像顺序错乱）
  out.sort((a: ChangelogEntry, b: ChangelogEntry) => noteTypeRank(a.type) - noteTypeRank(b.type));
  return out;
}

/** 取 zh 语言块；zh 缺失或为空时回退 en（离线快照被裁剪等极端情况）。 */
function pickLocale_(item: Record<string, Object>): Record<string, Object> | null {
  let zh = item['zh'];
  if (zh !== undefined && typeof zh === 'object') {
    let block = zh as Record<string, Object>;
    let entries = block['entries'];
    if (entries !== undefined && Array.isArray(entries) && (entries as Object[]).length > 0) return block;
  }
  let en = item['en'];
  if (en !== undefined && typeof en === 'object') return en as Record<string, Object>;
  return null;
}

/**
 * 解析 changelog.json。整体不可解析 → null（调用方沿用旧数据）；
 * 单个 release 残缺 → 跳过它自己。
 */
export function parseChangelog(body: string, source: string): ChangelogSnapshot | null {
  try {
    let o = JSON.parse(body) as Record<string, Object>;
    let schema = asNumber_(o['schema']);
    if (schema > SUPPORTED_SCHEMA) {
      AppLogger.warn(TAG, `changelog schema=${schema} 超出支持范围 ${SUPPORTED_SCHEMA}，忽略该来源`, null, LOG_DOMAIN_DOWNLOAD);
      return null;
    }
    let rawReleases = o['releases'];
    if (rawReleases === undefined || !Array.isArray(rawReleases)) return null;

    let releases: ChangelogRelease[] = [];
    for (let raw of (rawReleases as Object[])) {
      if (typeof raw !== 'object') continue;
      let item = raw as Record<string, Object>;
      let versionName = asString_(item['versionName']);
      if (versionName.length === 0) continue;
      let block = pickLocale_(item);
      releases.push({
        versionName: versionName,
        versionCode: asNumber_(item['versionCode']),
        tag: asString_(item['tag']),
        date: asString_(item['date']),
        prerelease: item['prerelease'] === true,
        url: asString_(item['url']),
        title: asString_(item['title']),
        summary: block !== null ? asString_(block['summary']) : '',
        entries: block !== null ? parseEntries_(block['entries']) : [],
      });
    }
    if (releases.length === 0) return null;
    return { ok: true, schema: schema, releases: releases, source: source, error: '' };
  } catch (e) {
    AppLogger.warn(TAG, 'parseChangelog failed (' + source + ')', e as Object, LOG_DOMAIN_DOWNLOAD);
    return null;
  }
}

// ---------------- 本地优先加载 ----------------

function cacheDir_(ctx: common.UIAbilityContext): string {
  let dir = ctx.filesDir + '/' + CACHE_DIR_NAME;
  try { fileIo.mkdirSync(dir); } catch (e) { /* 已存在则忽略 */ }
  return dir;
}

async function doLoadLocal_(ctx: common.UIAbilityContext): Promise<ChangelogSnapshot> {
  let dir = cacheDir_(ctx);
  let cachedText = readTextFile_(dir + '/changelog.json');
  if (cachedText.length > 0) {
    let parsed = parseChangelog(cachedText, 'cache');
    if (parsed !== null) {
      AppLogger.info(TAG, `更新日志本地就绪：来源=磁盘缓存，${parsed.releases.length} 个版本`, LOG_DOMAIN_DOWNLOAD);
      return parsed;
    }
  }
  let bundled = await readRawText_(ctx, CHANGELOG_RAWFILE);
  if (bundled.length > 0) {
    let parsed = parseChangelog(bundled, 'bundled');
    if (parsed !== null) {
      AppLogger.info(TAG, `更新日志本地就绪：来源=随包快照，${parsed.releases.length} 个版本`, LOG_DOMAIN_DOWNLOAD);
      return parsed;
    }
  }
  AppLogger.warn(TAG, '更新日志本地无数据（无缓存且无随包快照）', null, LOG_DOMAIN_DOWNLOAD);
  return EMPTY_SNAPSHOT;
}

// ---------------- 后台远程刷新 ----------------

async function fetchRemote_(ctx: common.UIAbilityContext): Promise<ChangelogSnapshot | null> {
  let dir = cacheDir_(ctx);
  let etagPath = dir + '/changelog.etag';
  let cachedEtag = readTextFile_(etagPath);

  let headers: Record<string, string> = {};
  if (cachedEtag.length > 0 && cached_ !== null && cached_.ok) headers['If-None-Match'] = cachedEtag;

  let primary = CHANGELOG_JSON_URLS[0];
  let mirrors = CHANGELOG_JSON_URLS.slice(1);
  let rich: FetchTextRichResult;
  try {
    rich = await DownloadManager.instance().fetchTextEx(
      primary, mirrors, FETCH_TIMEOUT_SECONDS, headers, MAX_RESPONSE_BYTES);
  } catch (e) {
    AppLogger.warn(TAG, '更新日志远程刷新失败（沿用本地）', e as Object, LOG_DOMAIN_DOWNLOAD);
    return null;
  }

  if (rich.statusCode === 304) {
    AppLogger.info(TAG, '更新日志远程 304（无变化）', LOG_DOMAIN_DOWNLOAD);
    return null;
  }
  if (rich.body.length === 0) return null;

  let parsed = parseChangelog(rich.body, 'remote');
  if (parsed === null) return null;

  writeTextFile_(dir + '/changelog.json', rich.body);
  let etag = rich.headers['etag'];
  if (etag !== undefined && etag.length > 0) writeTextFile_(etagPath, etag);
  AppLogger.info(TAG, `更新日志远程更新（${parsed.releases.length} 个版本，${rich.body.length} 字节）`, LOG_DOMAIN_DOWNLOAD);
  return parsed;
}

async function refreshRemote_(ctx: common.UIAbilityContext): Promise<void> {
  if (remoteRefreshDone_) return;
  remoteRefreshDone_ = true;

  if (!DistributionPolicy.allowPublisherServices()) {
    AppLogger.info(TAG, '上架轨：跳过更新日志远程刷新（不连接自有服务器）', LOG_DOMAIN_DOWNLOAD);
    return;
  }
  let fresh = await fetchRemote_(ctx);
  if (fresh === null) return;
  cached_ = fresh;
  notifyUpdated_();
}

// ---------------- 对外入口 ----------------

export class ChangelogService {
  /**
   * 取更新日志（进程内单例 + 本地优先）。返回后在后台刷新远程，
   * 有新内容时经 `onChangelogUpdated` 通知调用方重刷。
   */
  static async load(): Promise<ChangelogSnapshot> {
    if (cached_ !== null) {
      ChangelogService.kickRemote_();
      return cached_;
    }
    if (inflightLocal_ !== null) return inflightLocal_;

    let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (ctx === undefined) {
      AppLogger.warn(TAG, 'uiAbilityContext 尚未就绪，无法加载更新日志', null, LOG_DOMAIN_DOWNLOAD);
      return EMPTY_SNAPSHOT;
    }

    inflightLocal_ = doLoadLocal_(ctx);
    let snapshot = await inflightLocal_;
    inflightLocal_ = null;
    if (snapshot.ok) cached_ = snapshot;

    ChangelogService.kickRemote_();
    return snapshot;
  }

  /** 触发后台远程刷新（fire-and-forget，每进程一次）。 */
  private static kickRemote_(): void {
    let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (ctx === undefined) return;
    refreshRemote_(ctx).catch((e: Error) => {
      AppLogger.warn(TAG, '更新日志后台刷新异常', e, LOG_DOMAIN_DOWNLOAD);
    });
  }

  /** 同步取已缓存快照；未加载完成返回 null。 */
  static peek(): ChangelogSnapshot | null {
    return cached_;
  }

  /** 按版本号或 tag 找一个版本（深链 / 弹窗跳转定位用）。 */
  static findRelease(snapshot: ChangelogSnapshot, key: string): ChangelogRelease | null {
    if (key.length === 0) return null;
    for (let r of snapshot.releases) {
      if (r.versionName === key || r.tag === key || r.tag === 'v' + key) return r;
    }
    return null;
  }
}

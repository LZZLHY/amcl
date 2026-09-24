import { DistributionPolicy } from 'commons';
/**
 * ModTranslationLoader.ets — 加载社区资源译名库（entry 侧 IO 适配层）
 *
 * 取数策略（2026-07-03 由「远程优先」改为「本地优先 + 后台远程刷新」）：
 *   1) **本地优先（同步/近同步，无网络）**：磁盘缓存 filesDir/translations/*.txt →
 *      打包 rawfile 兜底（moddata-amcl.txt / modpackdata-amcl.txt）。`loadModTranslationStores`
 *      仅用本地数据构建 store 并**立即返回**，几十毫秒内就绪。
 *   2) **后台远程刷新（fire-and-forget，带 ETag/304）**：从 AMCL-web
 *      `/api/translations/{mod|modpack}.txt` 拉最新，写回磁盘缓存；若拿到 200 新内容则
 *      更新进程内单例并通过监听器通知 UI 重新 enrich（当场生效）；304/失败则无操作。
 *
 * 为什么改：原「远程优先」会先发远程请求（最长 8s 超时）才 ready → 冷启动时模组列表
 * 已经（借 search 磁盘缓存）秒显但译名库未就绪 → 全是英文名，要等远程回来才中文化。
 * 改为本地优先后，译名库随列表几乎同时就绪，首屏即中文；远程新增译名经后台刷新当场
 * 通知重刷（或最迟下次启动生效）。离线 / 服务波动时本地缓存 + 打包兜底保证可用。
 *
 * 进程内单例缓存：首次加载后复用。任一库缺失则其为 null（该类资源降级为英文）。
 *
 * 创建日期：2026-05-12
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { ModTranslationStore } from 'mods';
import { AppLogger, LOG_DOMAIN_DOWNLOAD, AMCL_WEB_BASE } from 'commons';
import { DeviceProfile } from 'commons';

const TAG = 'ModTranslationLoader';
const FETCH_TIMEOUT_MS = 8000;

interface KindSpec {
  kind: string;        // mod | modpack
  remote: string;      // 远程文件名
  rawfile: string;     // 打包兜底 rawfile 名
  hasRanks: boolean;   // 模组库含人气排名行
}
const SPECS: KindSpec[] = [
  { kind: 'mod', remote: 'mod.txt', rawfile: 'moddata-amcl.txt', hasRanks: true },
  { kind: 'modpack', remote: 'modpack.txt', rawfile: 'modpackdata-amcl.txt', hasRanks: false },
];

export interface ModTranslationStores {
  mod: ModTranslationStore | null;
  modpack: ModTranslationStore | null;
}

let cached_: ModTranslationStores | null = null;
let inflight_: Promise<ModTranslationStores> | null = null;
/** 后台远程刷新每进程最多跑一次 */
let remoteRefreshDone_: boolean = false;

// ---------------- 远程刷新完成通知（供 UI 重新 enrich） ----------------

type TranslationUpdateListener = () => void;
let updateListeners_: TranslationUpdateListener[] = [];

/** 注册"译名库经后台远程刷新有更新"的监听器（UI 收到后应重新 enrich / 重搜）。 */
export function onTranslationStoresUpdated(cb: TranslationUpdateListener): void {
  updateListeners_.push(cb);
}

/** 注销监听器（页面 aboutToDisappear 调用，避免累积）。 */
export function offTranslationStoresUpdated(cb: TranslationUpdateListener): void {
  let i = updateListeners_.indexOf(cb);
  if (i >= 0) updateListeners_.splice(i, 1);
}

function notifyUpdated_(): void {
  for (let cb of updateListeners_) {
    try { cb(); } catch (e) { /* 监听器抛错不影响其他 */ }
  }
}

// ---------------- 文件 IO ----------------

function readTextFile(path: string): string {
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

function writeTextFile(path: string, text: string): void {
  try {
    let f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, text);
    fileIo.closeSync(f);
  } catch (e) {
    AppLogger.warn(TAG, `写缓存失败: ${path}`, e as Object, LOG_DOMAIN_DOWNLOAD);
  }
}

/** 读打包 rawfile 文本 */
async function readRawText(ctx: common.UIAbilityContext, name: string): Promise<string> {
  try {
    let bytes = await ctx.resourceManager.getRawFileContent(name);
    if (bytes === undefined || bytes.byteLength === 0) return '';
    let decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(bytes);
  } catch (e) {
    AppLogger.warn(TAG, `读取 rawfile 失败: ${name}`, e as Object, LOG_DOMAIN_DOWNLOAD);
    return '';
  }
}

function headerGet(headers: object, key: string): string {
  let h = headers as Record<string, Object>;
  let lower = key.toLowerCase();
  for (let k of Object.keys(h)) {
    if (k.toLowerCase() === lower) {
      let v = h[k];
      return typeof v === 'string' ? v : String(v);
    }
  }
  return '';
}

// ---------------- 本地优先加载 ----------------

/** 取某类资源的本地译名文本（磁盘缓存 → 打包 rawfile），无网络。 */
async function loadKindTextLocal(ctx: common.UIAbilityContext, spec: KindSpec, cacheDir: string): Promise<string> {
  let cachedText = readTextFile(cacheDir + '/' + spec.kind + '.txt');
  if (cachedText.length > 0) return cachedText;
  return await readRawText(ctx, spec.rawfile);
}

/** 仅用本地数据构建两份译名库（快，无网络）。 */
async function doLoadLocal(ctx: common.UIAbilityContext): Promise<ModTranslationStores> {
  let cacheDir = ctx.filesDir + '/translations';
  try { fileIo.mkdirSync(cacheDir); } catch (e) { /* 已存在则忽略 */ }

  let result: ModTranslationStores = { mod: null, modpack: null };
  for (let spec of SPECS) {
    let text = await loadKindTextLocal(ctx, spec, cacheDir);
    if (text.length === 0) {
      AppLogger.warn(TAG, `${spec.kind} 译名库本地为空`, null, LOG_DOMAIN_DOWNLOAD);
      continue;
    }
    let store = ModTranslationStore.fromText(text, spec.hasRanks);
    if (spec.kind === 'mod') result.mod = store;
    else result.modpack = store;
    AppLogger.info(TAG, `${spec.kind} 译名库(本地)就绪，共 ${store.size()} 条`, LOG_DOMAIN_DOWNLOAD);
  }
  return result;
}

// ---------------- 后台远程刷新 ----------------

/**
 * 拉某类资源的远程译名（带 ETag）。仅当返回 200 且有新内容时写回磁盘缓存并返回文本；
 * 304 / 失败 / 空 → 返回空串（表示"无变化，沿用本地"）。
 */
async function fetchKindTextRemote(spec: KindSpec, cacheDir: string): Promise<string> {
  let txtPath = cacheDir + '/' + spec.kind + '.txt';
  let etagPath = cacheDir + '/' + spec.kind + '.etag';
  let cachedEtag = readTextFile(etagPath);

  let req = http.createHttp();
  try {
    let header: Record<string, string> = {};
    if (cachedEtag.length > 0) header['If-None-Match'] = cachedEtag;
    let resp = await req.request(AMCL_WEB_BASE + '/api/translations/' + spec.remote, {
      method: http.RequestMethod.GET,
      header,
      connectTimeout: FETCH_TIMEOUT_MS,
      readTimeout: FETCH_TIMEOUT_MS,
    });
    if (resp.responseCode === 304) {
      AppLogger.info(TAG, `${spec.kind} 译名库远程 304（无变化）`, LOG_DOMAIN_DOWNLOAD);
      return '';
    }
    if (resp.responseCode === 200 && typeof resp.result === 'string' && resp.result.length > 0) {
      let text = resp.result as string;
      writeTextFile(txtPath, text);
      let et = headerGet(resp.header, 'etag');
      if (et.length > 0) writeTextFile(etagPath, et);
      AppLogger.info(TAG, `${spec.kind} 译名库远程更新（${text.length} 字节）`, LOG_DOMAIN_DOWNLOAD);
      return text;
    }
    AppLogger.warn(TAG, `${spec.kind} 译名库远程响应码 ${resp.responseCode}`, null, LOG_DOMAIN_DOWNLOAD);
  } catch (e) {
    AppLogger.warn(TAG, `${spec.kind} 译名库远程刷新失败（沿用本地）`, e as Object, LOG_DOMAIN_DOWNLOAD);
  } finally {
    try { req.destroy(); } catch (e2) { /* ignore */ }
  }
  return '';
}

/**
 * 后台远程刷新（每进程最多一次）：拉最新译名写回磁盘缓存；若有 200 新内容则更新进程内
 * 单例并通知监听器当场重刷。不阻塞 loadModTranslationStores 的返回。
 */
async function refreshRemote_(ctx: common.UIAbilityContext): Promise<void> {
  if (remoteRefreshDone_) return;
  remoteRefreshDone_ = true;

  // 上架轨（APP 备案「无自有服务器」）：不连接自有服务器 amcl.lovedhy.cn 的译名库更新接口，
  // 仅使用随包/缓存的本地译名库（doLoadLocal 已提供）。侧载轨保持在线增量更新。
  if (!DistributionPolicy.allowPublisherServices()) {
    AppLogger.info(TAG, '上架轨：跳过译名库远程刷新（不连接自有服务器）', LOG_DOMAIN_DOWNLOAD);
    return;
  }

  let cacheDir = ctx.filesDir + '/translations';
  try { fileIo.mkdirSync(cacheDir); } catch (e) { /* 已存在则忽略 */ }

  let base: ModTranslationStores = cached_ !== null ? cached_ : { mod: null, modpack: null };
  let next: ModTranslationStores = { mod: base.mod, modpack: base.modpack };
  let changed = false;
  for (let spec of SPECS) {
    let fresh = await fetchKindTextRemote(spec, cacheDir);
    if (fresh.length === 0) continue;   // 无变化，沿用本地
    let store = ModTranslationStore.fromText(fresh, spec.hasRanks);
    if (spec.kind === 'mod') next.mod = store;
    else next.modpack = store;
    changed = true;
  }
  if (changed) {
    cached_ = next;
    AppLogger.info(TAG, '译名库后台远程刷新已应用，通知 UI 重刷', LOG_DOMAIN_DOWNLOAD);
    notifyUpdated_();
  }
}

// ---------------- 对外入口 ----------------

/**
 * 取两份译名库（进程内单例，本地优先）。并发调用复用同一个 in-flight Promise。
 * 返回本地数据后在后台异步刷新远程（更新经监听器通知）。
 */
export async function loadModTranslationStores(): Promise<ModTranslationStores> {
  if (cached_ !== null) return cached_;
  if (inflight_ !== null) return inflight_;

  let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  if (ctx === undefined) {
    AppLogger.warn(TAG, 'uiAbilityContext 尚未就绪，跳过译名库加载', null, LOG_DOMAIN_DOWNLOAD);
    return { mod: null, modpack: null };
  }

  inflight_ = doLoadLocal(ctx);
  let stores = await inflight_;
  inflight_ = null;
  if (stores.mod !== null || stores.modpack !== null) cached_ = stores;

  // 后台远程刷新（不阻塞返回；有更新时经监听器通知 UI 重新 enrich）
  refreshRemote_(ctx).catch((e: Error) => {
    AppLogger.warn(TAG, '译名库后台刷新异常', e, LOG_DOMAIN_DOWNLOAD);
  });

  return stores;
}

/** 同步取已缓存的译名库；未加载完成时返回 null */
export function getCachedTranslationStores(): ModTranslationStores | null {
  return cached_;
}

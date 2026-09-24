import { DiagnosticPolicy } from './DiagnosticPolicy';
/**
 * RemoteImageCache.ets — 全局 HTTP → PixelMap 解码缓存（内存 + 磁盘两级）
 *
 * 背景：OpenHarmony 5 / API 14 的 `Image(httpsUrl)` 和 `new ImageBitmap(httpsUrl)`
 * 都有"静默不发请求"的 quirk —— URL 没问题、curl/浏览器都能拉，但 ArkUI 控件
 * **根本不发出任何网络流水**。详见 RemoteImage.ets 顶部的考古注释。
 *
 * Workaround：自己用 @kit.NetworkKit 的 http.request 拿 ArrayBuffer，
 * 再用 @kit.ImageKit 的 image.createImageSource(buf).createPixelMap() 解码成 PixelMap。
 * 然后把 PixelMap 喂给 Image 控件 / Canvas drawImage，全都稳定。
 *
 * 这套缓存原本住在 RemoteImage.ets 内部（仅 fallback 图标用）；2026-05-23 把它抽到
 * common/ 共享给 SkinCanvas3D（皮肤 PNG 也要走这条），避免 RemoteImage 和 Skin 路径
 * 各自维护一份 fetch 逻辑。
 *
 * 缓存语义（两级）：
 *   L1 内存（pixelCache_）：url → 已解码 PixelMap
 *     - hit → 立即返回（同步 Promise）
 *     - inflight → 共享同一个 promise，避免并发重复请求同一张图
 *   L2 磁盘（cacheDir/remote-image-cache/<hash>.img）：url → 原始图片字节（png/jpg/webp）
 *     - 2026-07-03 新增：内存未命中时先读盘解码（省一次网络往返，跨 APP 重启持久）
 *     - 冷取网络成功后把原始字节落盘（原子写：.tmp → rename），供下次复用
 *     - 目录容量上限 MAX_DISK_FILES，首次访问时按 mtime 淘汰最旧的一批（LRU 近似）
 *   任何阶段失败返回 null（调用方自己降级 / fallback）。
 *
 * 所有模组图标（列表 / 下载 / 已装 / 详情）、皮肤 PNG 都走本函数 → 一处加磁盘缓存全局受益。
 *
 * 创建日期：2026-05-23（从 RemoteImage.ets 抽出）
 * 磁盘层：2026-07-03
 */

import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

const TAG = 'RemoteImageCache';

/** 磁盘缓存文件数上限；超出则在初始化时按 mtime 淘汰到 ~80%。图标多为几 KB，600 张约几 MB。 */
const MAX_DISK_FILES = 600;

/** url → PixelMap（已解码完成的图片） */
const pixelCache_: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
/** url → 正在进行的 fetch+decode promise，避免并发重复请求同一张图 */
const inflight_: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();

// ---------------- 磁盘层 ----------------

/** 磁盘缓存目录状态：0=未尝试初始化 / 1=就绪 / 2=不可用（本进程内不再重试） */
let diskState_: number = 0;
let diskDir_: string = '';
let pruned_: boolean = false;

interface ImgFileMeta {
  name: string;
  mtime: number;
}

/**
 * 惰性解析磁盘缓存目录（context 可能在极早冷启动时尚未就绪 → 保持"未尝试"态下次重试）。
 * 返回空串表示当前不可用（调用方降级为纯网络）。
 */
function ensureDiskDir_(): string {
  if (diskState_ === 1) return diskDir_;
  if (diskState_ === 2) return '';
  let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
  if (ctx === undefined || ctx === null) {
    // context 还没缓存进 AppStorage（冷启动早期）→ 不标记不可用，下次再试
    return '';
  }
  try {
    let dir = ctx.cacheDir + '/remote-image-cache';
    try { fileIo.mkdirSync(dir); } catch (e) { /* 已存在则忽略 */ }
    diskDir_ = dir;
    diskState_ = 1;
    pruneDisk_(dir);
    return dir;
  } catch (e) {
    diskState_ = 2;
    hilog.warn(0x0000, TAG, 'disk cache dir init failed: %{public}s', errMsg_(e));
    return '';
  }
}

/** 目录文件数超上限时，按 mtime 升序删除最旧的一批（每进程仅跑一次）。 */
function pruneDisk_(dir: string): void {
  if (pruned_) return;
  pruned_ = true;
  try {
    let files = fileIo.listFileSync(dir);
    if (files.length <= MAX_DISK_FILES) return;
    let metas: ImgFileMeta[] = [];
    for (let name of files) {
      let mt = 0;
      try { mt = fileIo.statSync(dir + '/' + name).mtime; } catch (e) { /* 读不到 mtime 视为最旧 */ }
      metas.push({ name, mtime: mt });
    }
    metas.sort((a: ImgFileMeta, b: ImgFileMeta) => a.mtime - b.mtime);
    let keep = Math.floor(MAX_DISK_FILES * 0.8);
    let deleteCount = metas.length - keep;
    for (let i = 0; i < deleteCount; i++) {
      try { fileIo.unlinkSync(dir + '/' + metas[i].name); } catch (e) { /* ignore */ }
    }
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'disk prune: removed %{public}d of %{public}d', deleteCount, metas.length);
  } catch (e) {
    /* 目录列举失败无害，忽略 */
  }
}

/**
 * url → 磁盘缓存文件路径。用 FNV-1a + djb2 双哈希拼成 16 位十六进制文件名，
 * 碰撞概率极低；万一碰撞最坏只是偶发显示错图（有 fallback 兜底），不影响正确性。
 */
function diskPathFor_(dir: string, url: string): string {
  return dir + '/' + hashUrl_(url) + '.img';
}

function hashUrl_(url: string): string {
  let h1 = 0x811c9dc5;            // FNV-1a 32-bit
  let h2 = 5381;                  // djb2
  for (let i = 0; i < url.length; i++) {
    let c = url.charCodeAt(i);
    h1 ^= c;
    h1 = Math.imul(h1, 0x01000193);
    h2 = (Math.imul(h2, 33) + c) | 0;
  }
  return toHex8_(h1 >>> 0) + toHex8_(h2 >>> 0);
}

/** 无符号 32 位整数 → 定长 8 位十六进制（手动左补零，规避 padStart 兼容性顾虑）。 */
function toHex8_(n: number): string {
  let s = n.toString(16);
  while (s.length < 8) s = '0' + s;
  return s;
}

/** 从磁盘读原始字节并解码成 PixelMap；未命中 / 失败返回 null。 */
async function decodeFromDisk_(url: string): Promise<image.PixelMap | null> {
  let dir = ensureDiskDir_();
  if (dir.length === 0) return null;
  let path = diskPathFor_(dir, url);
  try {
    if (!fileIo.accessSync(path)) return null;
    let src = image.createImageSource(path);
    let pm = await src.createPixelMap({
      editable: false,
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
    });
    src.release();
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'disk HIT %{public}s', url);
    return pm;
  } catch (e) {
    return null;
  }
}

/** 把原始图片字节落盘（原子写：.tmp → rename）。best-effort，失败静默。 */
function writeToDisk_(url: string, buf: ArrayBuffer): void {
  let dir = ensureDiskDir_();
  if (dir.length === 0) return;
  if (buf.byteLength === 0) return;
  let path = diskPathFor_(dir, url);
  let tmp = path + '.tmp';
  let f: fileIo.File | null = null;
  try {
    f = fileIo.openSync(tmp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, buf);
    fileIo.closeSync(f);
    f = null;
    fileIo.renameSync(tmp, path);
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'disk PUT %{public}s (%{public}d bytes)', url, buf.byteLength);
  } catch (e) {
    if (f !== null) { try { fileIo.closeSync(f); } catch (e2) { /* */ } }
    try { fileIo.unlinkSync(tmp); } catch (e3) { /* */ }
  }
}

function errMsg_(e: object): string {
  let err = e as Error;
  return err.message !== undefined ? err.message : String(e);
}

/**
 * 取或异步拉取 url 对应的 PixelMap。
 *
 * - L1 内存命中 → 立即返回（同步路径）
 * - inflight → 共享同一个 promise
 * - L2 磁盘命中 → 读盘 + 解码 → 入内存 → 返回（省一次网络往返）
 * - cold → http.request → 解码 → 入内存 + 落盘 → 返回
 *
 * 任何阶段失败返回 null（调用方负责降级 / fallback）。
 */
export async function getRemotePixelMap(url: string): Promise<image.PixelMap | null> {
  if (pixelCache_.has(url)) {
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'mem HIT %{public}s', url);
    return pixelCache_.get(url)!;
  }
  let pending = inflight_.get(url);
  if (pending !== undefined) {
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'inflight HIT %{public}s', url);
    return pending;
  }

  let task = (async (): Promise<image.PixelMap | null> => {
    let httpReq: http.HttpRequest | null = null;
    try {
      // L2：先试磁盘（跨进程持久，省网络往返）
      let fromDisk = await decodeFromDisk_(url);
      if (fromDisk !== null) {
        pixelCache_.set(url, fromDisk);
        return fromDisk;
      }

      // cold：网络拉取原始字节
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'cold fetch start %{public}s', url);
      httpReq = http.createHttp();
      let resp = await httpReq.request(url, {
        method: http.RequestMethod.GET,
        // ArkUI 的 ImageSource 需要 ArrayBuffer，所以请求体走 expectDataType=ARRAY_BUFFER
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 12000,
        readTimeout: 12000,
        // 部分镜像对 UA 敏感；用一个通用 UA 避免被识别成爬虫拒绝
        header: { 'User-Agent': 'AMCL/1.0.0 (https://github.com/axecraft/amcl)' } as Record<string, string>,
      });
      if (resp.responseCode !== 200) {
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'http %{public}d for %{public}s', resp.responseCode, url);
        return null;
      }
      let body = resp.result;
      if (!(body instanceof ArrayBuffer)) {
        if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'unexpected body type for %{public}s', url);
        return null;
      }
      let bytes = body as ArrayBuffer;
      // 解码：image.createImageSource 接受 ArrayBuffer；webp / png / jpg 都自动识别
      let src = image.createImageSource(bytes);
      let pm = await src.createPixelMap({
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      // ImageSource 用完释放（PixelMap 已经独立持有数据）
      src.release();
      pixelCache_.set(url, pm);
      // 落盘（best-effort，不阻塞返回语义；文件小、同步开销可忽略）
      writeToDisk_(url, bytes);
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'decoded %{public}s (mem size=%{public}d)', url, pixelCache_.size);
      return pm;
    } catch (e) {
      if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'fetch+decode failed %{public}s: %{public}s', url, errMsg_(e));
      return null;
    } finally {
      try { httpReq?.destroy(); } catch (e) { /* ignore */ }
      inflight_.delete(url);
    }
  })();
  inflight_.set(url, task);
  return task;
}

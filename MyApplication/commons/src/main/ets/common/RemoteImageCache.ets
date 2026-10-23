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
 *   L1 图标按 URL + 输出长边共享有界 PixelMap，消费者必须持有并归还租约；
 *      仅无租约的项可淘汰并显式释放。在用项占满预算时返回 null，保持 fallback。
 *      旧 getRemotePixelMap(url) 保留皮肤/披风原图语义，独立有界缓存只丢强引用，
 *      不显式 release 裸引用，避免破坏既有消费者正在读取的像素。
 *   不同 URL 的网络与解码共用有界队列；同一输出规格合并正在进行的工作。
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
import { RemoteImageCacheEntry, RemoteImageMemoryCache, RemoteImageTaskQueue,
  RemoteImageLoadToken, remoteImageDecodeSize, RemoteImageDecodeSize, RemoteImageRetirableLease } from './RemoteImagePolicy';

export { RemoteImageLoadToken, RemoteImageRetirementGuard } from './RemoteImagePolicy';

const TAG = 'RemoteImageCache';

/** 磁盘缓存文件数上限；超出则在初始化时按 mtime 淘汰到 ~80%。图标多为几 KB，600 张约几 MB。 */
const MAX_DISK_FILES = 600;

/** 图标响应在 NetworkKit 收包阶段限制为 2 MiB；兼容原图为 8 MiB。 */
const MAX_ICON_BYTES: number = 2 * 1024 * 1024;
const MAX_ORIGINAL_BYTES: number = 8 * 1024 * 1024;
/** 所有远程图片至多同时进行四次获取/解码，等候区最多保留 96 个工作身份。 */
const imageQueue_: RemoteImageTaskQueue<DecodedRemoteImage> = new RemoteImageTaskQueue<DecodedRemoteImage>(4, 96);
/** 租约图标和兼容原图分开管理，避免相同 URL 的缩略结果替代原图像素坐标。 */
const thumbnailCache_: RemoteImageMemoryCache<image.PixelMap> =
  new RemoteImageMemoryCache<image.PixelMap>(16 * 1024 * 1024, 192, releasePixelMap_);
const originalCache_: RemoteImageMemoryCache<image.PixelMap> =
  new RemoteImageMemoryCache<image.PixelMap>(16 * 1024 * 1024, 32, (_pm: image.PixelMap): void => {
    // 兼容调用者没有归还协议；只移除缓存强引用，由运行时在最后一个引用消失后回收。
  });
/** 原图去重不与图标混用；图标待交付数同时用于预留租约，消除完成/淘汰竞态。 */
const originalInflight_: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();
const thumbnailInflight_: Map<string, ThumbnailLoad> = new Map<string, ThumbnailLoad>();

/** 已解码结果附带真实像素字节数，供 L1 预算登记。 */
interface DecodedRemoteImage {
  pixelMap: image.PixelMap;
  bytes: number;
}

/** 一次共享图标工作：每个调用者各有取消标记和一个预留租约。 */
class ThumbnailLoad {
  tokens: RemoteImageLoadToken[] = [];
  promise: Promise<RemoteImageCacheEntry<image.PixelMap> | null> = Promise.resolve(null);

  /** 仅当还有消费者需要结果才继续出队、网络后的解码或结果缓存。 */
  isNeeded(): boolean { return this.tokens.some((token: RemoteImageLoadToken): boolean => !token.isCancelled()); }
}

/**
 * 一个图标的共享租约。调用者在 Image 停止引用后调用 release；操作幂等，
 * 只减少自己的 pin，不会释放其他组件仍在使用的同一张 PixelMap。
 */
export class RemotePixelMapLease implements RemoteImageRetirableLease {
  readonly pixelMap: image.PixelMap;
  private entry_: RemoteImageCacheEntry<image.PixelMap>;
  private released_: boolean = false;

  /** 仅由缓存创建；entry 已为当前消费者预留一个 pin。 */
  constructor(entry: RemoteImageCacheEntry<image.PixelMap>) {
    this.entry_ = entry;
    this.pixelMap = entry.value;
  }

  /** 重复释放无副作用；仍被其他租约使用的项不可成为 LRU 淘汰对象。 */
  release(): void {
    if (this.released_) return;
    this.released_ = true;
    thumbnailCache_.unpin(this.entry_);
  }

  /**
   * UIContext 已销毁、无法等待最后一帧时的安全退化：之后淘汰仅删除强引用，
   * 不显式销毁仍可能被渲染层引用的位图；缓存预算和其他消费者的 pin 仍有效。
   */
  releaseToGc(): void {
    if (this.released_) return;
    this.entry_.disposeAllowed = false;
    this.release();
  }
}

/** 显式释放仅用于租约管理的闲置项或从未交付的新位图，吸收异步释放错误。 */
function releasePixelMap_(pm: image.PixelMap): void {
  try { pm.release().catch((): void => { /* best-effort；最终仍由运行时回收。 */ }); }
  catch (e) { /* 释放异常不能影响其他图标。 */ }
}

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

/**
 * 在 ImageSource 上串行读取尺寸并解码，finally 覆盖坏图、拒绝及解码失败路径。
 * 不对同一个 ImageSource 并发调用 SDK 方法；原图与缩略图使用独立输出规格。
 */
async function decodeSource_(src: image.ImageSource, maxEdgePx: number): Promise<DecodedRemoteImage | null> {
  let pm: image.PixelMap | null = null;
  try {
    const info: image.ImageInfo = await src.getImageInfo();
    const size: RemoteImageDecodeSize | null = remoteImageDecodeSize(info.size.width, info.size.height, maxEdgePx);
    if (size === null) return null;
    pm = await src.createPixelMap({
      editable: false,
      desiredSize: size,
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
    });
    const bytes: number = pm.getPixelBytesNumber();
    if (bytes <= 0 || bytes > (maxEdgePx === 0 ? 16 * 1024 * 1024 : 256 * 256 * 4)) {
      releasePixelMap_(pm);
      pm = null;
      return null;
    }
    return { pixelMap: pm, bytes };
  } catch (e) {
    if (pm !== null) releasePixelMap_(pm);
    return null;
  } finally {
    try { await src.release(); } catch (e) { /* source 清理失败不覆盖获取结果。 */ }
  }
}

/** 磁盘也先校验压缩大小，再交给统一的尺寸限制和失败释放流程。 */
async function decodeFromDisk_(url: string, maxEdgePx: number, maxBytes: number): Promise<DecodedRemoteImage | null> {
  let dir = ensureDiskDir_();
  if (dir.length === 0) return null;
  let path = diskPathFor_(dir, url);
  try {
    if (!fileIo.accessSync(path)) return null;
    const fileSize: number = fileIo.statSync(path).size;
    if (fileSize <= 0 || fileSize > maxBytes) return null;
    const decoded: DecodedRemoteImage | null = await decodeSource_(image.createImageSource(path), maxEdgePx);
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'disk HIT %{public}s', url);
    return decoded;
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

/** URL 的基本准入，避免无效/超长身份占据有限队列。 */
function validUrl_(url: string): boolean {
  return url.length > 0 && url.length <= 16384 && (url.startsWith('https://') || url.startsWith('http://'));
}

/**
 * 队列里的实际 I/O 工作。maxLimit 在 SDK 收包阶段生效，随后再校验返回字节，
 * 不依赖下载完成后的单层检查。每个 HttpRequest 在 finally 销毁；need 只引用
 * 加载身份，不引用组件，全部消费者取消时跳过尚未开始或尚未解码的工作。
 */
async function loadRemoteImage_(url: string, maxEdgePx: number,
  need: () => boolean): Promise<DecodedRemoteImage | null> {
  if (!need()) return null;
  const maxBytes: number = maxEdgePx === 0 ? MAX_ORIGINAL_BYTES : MAX_ICON_BYTES;
  const fromDisk: DecodedRemoteImage | null = await decodeFromDisk_(url, maxEdgePx, maxBytes);
  if (fromDisk !== null) return fromDisk;
  if (!need()) return null;
  let request: http.HttpRequest | null = null;
  try {
    request = http.createHttp();
    const response: http.HttpResponse = await request.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      maxLimit: maxBytes,
      connectTimeout: 12000,
      readTimeout: 12000,
      header: { 'User-Agent': 'AMCL/1.0.0 (https://github.com/axecraft/amcl)' } as Record<string, string>,
    });
    if (!need() || response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) return null;
    const bytes: ArrayBuffer = response.result as ArrayBuffer;
    if (bytes.byteLength === 0 || bytes.byteLength > maxBytes) return null;
    const decoded: DecodedRemoteImage | null = await decodeSource_(image.createImageSource(bytes), maxEdgePx);
    if (decoded !== null) writeToDisk_(url, bytes);
    return decoded;
  } catch (e) {
    if (DiagnosticPolicy.isDeveloperBuild()) hilog.debug(0x0000, TAG, 'fetch+decode failed %{public}s: %{public}s', url, errMsg_(e));
    return null;
  } finally {
    try { request?.destroy(); } catch (e) { /* 不让 HTTP 清理异常影响其他加载。 */ }
  }
}

/**
 * 兼容原图入口。保持原始像素几何、相同 URL 去重和磁盘复用；内存缓存限制
 * 16 MiB/32 项，淘汰只丢强引用。旧消费者没有租约，缓存绝不显式 release
 * 仍可能由皮肤 Canvas/头像裁切持有的 PixelMap。新图标应使用下面的租约入口。
 */
export async function getRemotePixelMap(url: string): Promise<image.PixelMap | null> {
  if (!validUrl_(url)) return null;
  const cached: RemoteImageCacheEntry<image.PixelMap> | null = originalCache_.get(url);
  if (cached !== null) return cached.value;
  const pending: Promise<image.PixelMap | null> | undefined = originalInflight_.get(url);
  if (pending !== undefined) return pending;
  const task: Promise<image.PixelMap | null> = (async (): Promise<image.PixelMap | null> => {
    try {
      const decoded: DecodedRemoteImage | null = await imageQueue_.run((): Promise<DecodedRemoteImage | null> =>
        loadRemoteImage_(url, 0, (): boolean => true));
      if (decoded === null) return null;
      originalCache_.put(url, decoded.pixelMap, decoded.bytes);
      return decoded.pixelMap;
    } finally { originalInflight_.delete(url); }
  })();
  originalInflight_.set(url, task);
  return task;
}

/**
 * 为图标申请一个独立租约。规格包含归一化长边，既不把皮肤缩小，也不会让
 * 同 URL 的不同图标尺寸互相覆盖。任务完成时按等待者数量预留 pins，然后
 * 每个取消者归还自己的预留，消除 Promise 交付前被 LRU 淘汰的竞态。
 */
export async function acquireRemotePixelMap(url: string, maxEdgePx: number,
  token: RemoteImageLoadToken): Promise<RemotePixelMapLease | null> {
  if (!validUrl_(url) || token.isCancelled()) return null;
  const edge: number = Number.isFinite(maxEdgePx) ? Math.max(16, Math.min(256, Math.ceil(maxEdgePx))) : 128;
  const key: string = edge.toString() + '|' + url;
  const cached: RemoteImageCacheEntry<image.PixelMap> | null = thumbnailCache_.get(key, true);
  if (cached !== null) return new RemotePixelMapLease(cached);
  let load: ThumbnailLoad | undefined = thumbnailInflight_.get(key);
  if (load === undefined) {
    load = new ThumbnailLoad();
    load.tokens.push(token);
    thumbnailInflight_.set(key, load);
    const shared: ThumbnailLoad = load;
    shared.promise = (async (): Promise<RemoteImageCacheEntry<image.PixelMap> | null> => {
      try {
        const decoded: DecodedRemoteImage | null = await imageQueue_.run((): Promise<DecodedRemoteImage | null> =>
          loadRemoteImage_(url, edge, (): boolean => shared.isNeeded()));
        if (decoded === null) return null;
        if (!shared.isNeeded()) { releasePixelMap_(decoded.pixelMap); return null; }
        const entry: RemoteImageCacheEntry<image.PixelMap> | null =
          thumbnailCache_.put(key, decoded.pixelMap, decoded.bytes, shared.tokens.length);
        if (entry === null) releasePixelMap_(decoded.pixelMap);
        return entry;
      } finally { thumbnailInflight_.delete(key); }
    })();
  } else {
    load.tokens.push(token);
  }
  const entry: RemoteImageCacheEntry<image.PixelMap> | null = await load.promise;
  if (entry === null) return null;
  if (token.isCancelled()) { thumbnailCache_.unpin(entry); return null; }
  return new RemotePixelMapLease(entry);
}

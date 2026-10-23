/**
 * 远程图片的纯策略层：约束解码尺寸、缓存保留量和异步任务并发。
 * 本文件不依赖 ImageKit/ArkUI，宿主回归直接运行这些生产策略；PixelMap 的实际
 * 销毁由调用方提供，因而可区分“租约独占管理”和“兼容裸引用仅交给 GC”。
 */

/** 一次加载的取消标记。取消只影响这个消费者，不会取消其他人共享的同 URL 工作。 */
export class RemoteImageLoadToken {
  private cancelled_: boolean = false;

  /** 组件离页或输入变化时调用；重复取消无副作用。 */
  cancel(): void { this.cancelled_ = true; }

  /** 队列开始、解码完成及结果交付前检查，避免把过期结果绑定到界面。 */
  isCancelled(): boolean { return this.cancelled_; }
}

/** 退休守卫只需要这两个资源操作，不依赖具体 PixelMap 或 ArkUI 实例。 */
export interface RemoteImageRetirableLease {
  release(): void;
  releaseToGc(): void;
}

/**
 * 旧帧资源的有界退休守卫。FrameCallback 注册成功也不保证将来一定有空闲帧：
 * UI 可能停帧或始终没有足够余量，所以最多等待 1000ms，超时仅撤销缓存 pin
 * 并禁止显式销毁，交给 GC 在最后引用消失后回收。正常 onIdle 才允许显式释放。
 * 两条路径共用完成标志；迟到的帧回调不能把已经交 GC 的位图再次显式释放。
 */
export class RemoteImageRetirementGuard {
  private lease_: RemoteImageRetirableLease | null;
  private timer_: number = -1;
  private finished_: boolean = false;

  /** timeoutMs 可供宿主回归缩短等待；生产调用保留 1000ms 默认有界窗口。 */
  constructor(lease: RemoteImageRetirableLease, timeoutMs: number = 1000) {
    this.lease_ = lease;
    this.timer_ = setTimeout((): void => { this.finish_(false); }, Math.max(1, timeoutMs));
  }

  /** 已确认旧帧停止引用时归还普通租约，并取消不再需要的兜底计时器。 */
  onIdle(): void { this.finish_(true); }

  /** 注册回调失败时立即走安全 GC 路径；重复调用或随后迟到的 onIdle 均无副作用。 */
  releaseToGc(): void { this.finish_(false); }

  /**
   * 先标记完成，并把租约移入局部变量、清空守卫的强引用，再取消计时器和执行
   * 资源操作。FrameCallback 即使永远没有 idle、被 UIContext 长期保留，也不能
   * 再经守卫持有旧 PixelMap。先脱链同时保证资源回调重入或抛错仍不会重新持有
   * payload；超时只撤销 pin、不显式 release 可能仍被旧帧使用的 PixelMap。
   */
  private finish_(idleConfirmed: boolean): void {
    if (this.finished_) return;
    this.finished_ = true;
    const lease: RemoteImageRetirableLease | null = this.lease_;
    this.lease_ = null;
    if (this.timer_ !== -1) { clearTimeout(this.timer_); this.timer_ = -1; }
    if (lease === null) return;
    if (idleConfirmed) lease.release();
    else lease.releaseToGc();
  }
}

/** 经检查的输出像素尺寸；0 不是合法输出。 */
export interface RemoteImageDecodeSize {
  width: number;
  height: number;
}

/**
 * 在解码之前校验来源尺寸，并生成保持宽高比的缩略尺寸。
 * maxEdgePx=0 保留原图几何语义，供皮肤/披风按源像素坐标采样；原图限制为
 * 2048 长边/4M 像素。图标允许读取较大来源元信息，但输出长边最多 256px，
 * 不放大小图；超大或无效来源直接拒绝，避免用压缩小文件诱发巨大解码。
 */
export function remoteImageDecodeSize(width: number, height: number,
  maxEdgePx: number): RemoteImageDecodeSize | null {
  if (!Number.isFinite(width) || !Number.isFinite(height)
    || width <= 0 || height <= 0 || Math.floor(width) !== width || Math.floor(height) !== height) return null;
  const sourceEdge: number = maxEdgePx === 0 ? 2048 : 8192;
  const sourcePixels: number = maxEdgePx === 0 ? 4 * 1024 * 1024 : 16 * 1024 * 1024;
  if (width > sourceEdge || height > sourceEdge || width * height > sourcePixels) return null;
  if (maxEdgePx === 0) return { width, height };
  const edge: number = Number.isFinite(maxEdgePx) ? Math.max(16, Math.min(256, Math.ceil(maxEdgePx))) : 128;
  const scale: number = Math.min(1, edge / Math.max(width, height));
  return { width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale)) };
}

/** 一个缓存项的身份与占用；pins 是尚未归还的消费者租约数。 */
export class RemoteImageCacheEntry<T> {
  key: string;
  value: T;
  bytes: number;
  pins: number;
  lastUse: number = 0;
  /** UIContext 已失效时不能证明最后一帧结束，改为仅移除强引用、交给 GC 回收。 */
  disposeAllowed: boolean = true;

  /** 调用方须提供真实像素字节数；首次交付给多个等待者时预留相应 pins。 */
  constructor(key: string, value: T, bytes: number, pins: number) {
    this.key = key;
    this.value = value;
    this.bytes = bytes;
    this.pins = pins;
  }
}

/**
 * 同时受字节数和条目数约束的 LRU。仅淘汰 pins=0 的项；全部在使用时拒绝
 * 新项，不通过强制释放仍显示的共享 PixelMap 来满足预算。dispose 不得影响
 * 其他缓存项，异常会隔离；兼容裸引用缓存应传入空 dispose，只移除强引用。
 */
export class RemoteImageMemoryCache<T> {
  private entries_: Map<string, RemoteImageCacheEntry<T>> = new Map<string, RemoteImageCacheEntry<T>>();
  private bytes_: number = 0;
  private clock_: number = 0;
  private maxBytes_: number;
  private maxEntries_: number;
  private dispose_: (value: T) => void;

  /** limits 由模块固定配置，dispose 明确决定资源的所有权。 */
  constructor(maxBytes: number, maxEntries: number, dispose: (value: T) => void) {
    this.maxBytes_ = Math.max(1, Math.floor(maxBytes));
    this.maxEntries_ = Math.max(1, Math.floor(maxEntries));
    this.dispose_ = dispose;
  }

  /** 命中同时更新 LRU；pin=true 为新消费者增加一个租约。 */
  get(key: string, pin: boolean = false): RemoteImageCacheEntry<T> | null {
    const entry: RemoteImageCacheEntry<T> | undefined = this.entries_.get(key);
    if (entry === undefined) return null;
    entry.lastUse = ++this.clock_;
    if (pin) entry.pins++;
    return entry;
  }

  /**
   * 接纳一个新身份；失败时不接管 value，调用方必须自行处置它。
   * 先验证容量和在用项，拒绝不可能容纳的项时不会破坏已有缓存。
   */
  put(key: string, value: T, bytes: number, pins: number = 0): RemoteImageCacheEntry<T> | null {
    if (!Number.isFinite(bytes) || bytes <= 0 || bytes > this.maxBytes_ || this.entries_.has(key)) return null;
    let pinnedBytes: number = 0;
    let pinnedCount: number = 0;
    this.entries_.forEach((entry: RemoteImageCacheEntry<T>): void => {
      if (entry.pins > 0) { pinnedBytes += entry.bytes; pinnedCount++; }
    });
    if (pinnedBytes + bytes > this.maxBytes_ || pinnedCount + 1 > this.maxEntries_) return null;
    while (this.bytes_ + bytes > this.maxBytes_ || this.entries_.size + 1 > this.maxEntries_) {
      let oldest: RemoteImageCacheEntry<T> | null = null;
      this.entries_.forEach((entry: RemoteImageCacheEntry<T>): void => {
        if (entry.pins === 0 && (oldest === null || entry.lastUse < oldest.lastUse)) oldest = entry;
      });
      if (oldest === null) return null;
      this.remove_(oldest);
    }
    const entry: RemoteImageCacheEntry<T> = new RemoteImageCacheEntry<T>(key, value, bytes, Math.max(0, pins));
    entry.lastUse = ++this.clock_;
    this.entries_.set(key, entry);
    this.bytes_ += bytes;
    return entry;
  }

  /** 归还预留或已交付租约；以对象身份核对，旧租约不能减掉同 key 新项的计数。 */
  unpin(entry: RemoteImageCacheEntry<T>): void {
    if (this.entries_.get(entry.key) === entry && entry.pins > 0) entry.pins--;
  }

  /** 诊断/测试读取当前强引用预算；不含 UI 自己持有的兼容裸引用。 */
  retainedBytes(): number { return this.bytes_; }

  /** 诊断/测试读取当前缓存条目数。 */
  retainedCount(): number { return this.entries_.size; }

  /** 删除只发生在无人持有租约时；先去登记再调用销毁回调，防止异常留下半删状态。 */
  private remove_(entry: RemoteImageCacheEntry<T>): void {
    this.entries_.delete(entry.key);
    this.bytes_ -= entry.bytes;
    if (entry.disposeAllowed) {
      try { this.dispose_(entry.value); } catch (e) { /* 释放失败交给运行时回收，不影响其他项。 */ }
    }
  }
}

/** 队列节点只持有本次工作与其 Promise 完成器，不持有组件或 UIContext。 */
class RemoteImageQueueTask<T> {
  work: () => Promise<T | null>;
  resolve: (value: T | null) => void;

  /** work 内负责按消费者取消标记跳过过期工作。 */
  constructor(work: () => Promise<T | null>, resolve: (value: T | null) => void) {
    this.work = work;
    this.resolve = resolve;
  }
}

/**
 * 跨 URL 的有界 FIFO：同时运行数量固定，等候区也有上限。过载、异常均返回
 * null 以触发图标 fallback；失败仍释放运行槽，避免一张坏图堵住之后的图片。
 */
export class RemoteImageTaskQueue<T> {
  private active_: number = 0;
  private pending_: RemoteImageQueueTask<T>[] = [];
  private concurrency_: number;
  private maxPending_: number;

  /** concurrency/maxPending 均至少为 1，不依赖系统 HTTP/解码器内部线程池大小。 */
  constructor(concurrency: number, maxPending: number) {
    this.concurrency_ = Math.max(1, Math.floor(concurrency));
    this.maxPending_ = Math.max(1, Math.floor(maxPending));
  }

  /** 入队时限制等候数；调用方可通过工作闭包检查共享消费者是否都已取消。 */
  run(work: () => Promise<T | null>): Promise<T | null> {
    if (this.pending_.length >= this.maxPending_) return Promise.resolve(null);
    return new Promise<T | null>((resolve): void => {
      this.pending_.push(new RemoteImageQueueTask<T>(work, resolve));
      this.pump_();
    });
  }

  /** 仅在持有空闲槽时派发；执行器无 UI 操作。 */
  private pump_(): void {
    while (this.active_ < this.concurrency_ && this.pending_.length > 0) {
      const next: RemoteImageQueueTask<T> | undefined = this.pending_.shift();
      if (next === undefined) return;
      this.active_++;
      this.execute_(next);
    }
  }

  /** 成功/异常统一结束 Promise 并归还槽；finally 继续派发后续任务。 */
  private async execute_(task: RemoteImageQueueTask<T>): Promise<void> {
    try { task.resolve(await task.work()); }
    catch (e) { task.resolve(null); }
    finally { this.active_--; this.pump_(); }
  }
}

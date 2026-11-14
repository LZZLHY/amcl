/**
 * 全应用的离线皮肤/披风资产库。账号仅持有 AppearanceAsset 引用；原始 PNG 按
 * SHA-256 存入 filesDir/account-textures，改名或切换账号不会复制、覆盖纹理。
 * 仅主进程负责修改库；游戏进程应使用启动快照并预读纹理，不能成为第二个写者。
 * 进程内修改串行化，JSON 提交复用公共 AtomicFileWriter，保留上一代索引供恢复。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AtomicFileWriter, AtomicWriteError, getRemotePixelMap, utf8ToString } from 'commons';
import { AppearanceAsset, AppearanceKind } from './AppearanceTypes';
import { AppearancePngInfo, MAX_APPEARANCE_PNG_BYTES, isAppearanceSize, validateAppearancePng } from './AppearancePng';

/** 固定目录和来源协议均是内部身份，不能接收调用者任意路径。 */
const DIRECTORY: string = 'account-textures';
const SOURCE_PREFIX: string = 'amcl-texture:';
const MAX_INDEX_BYTES: number = 4 * 1024 * 1024;
const MAX_PREVIEW_ENTRIES: number = 24;

/** 索引带格式号，未来迁移必须显式实现，不能将未知格式当作空库覆盖。 */
interface AppearanceLibraryRecord {
  version: number;
  assets: AppearanceAsset[];
}

/** 未知版本属于待迁移数据，不能擅自回退旧备份并丢失新版条目。 */
class AppearanceLibraryVersionError extends Error {
  constructor() { super('外观库格式版本尚不支持，请使用兼容版本打开'); }
}

/** 返回独立对象，防止 UI 修改列表项时绕过校验和持久提交。 */
function copyAsset_(asset: AppearanceAsset): AppearanceAsset {
  return { id: asset.id, kind: asset.kind, name: asset.name, sha256: asset.sha256,
    relativePath: asset.relativePath, width: asset.width, height: asset.height, createdAt: asset.createdAt };
}

/** 只接纳摘要命名的单层 PNG；拒绝绝对路径、URI、编码分隔符和上级目录。 */
function safeRelativePath_(value: string): boolean {
  return typeof value === 'string' && new RegExp('^account-textures/[a-f0-9]{64}\\.png$').test(value);
}

/** 名字仅用于显示；不参与物理路径或内容身份。URI 不可读时使用明确的本地默认名。 */
function displayName_(uri: string, kind: AppearanceKind): string {
  const fallback: string = kind === 'skin' ? '导入皮肤' : '导入披风';
  try {
    let name: string = uri.split('?')[0].split('#')[0];
    name = decodeURIComponent(name.substring(name.lastIndexOf('/') + 1));
    name = name.replace(new RegExp('[\\x00-\\x1f\\x7f/\\\\]', 'g'), '').trim();
    if (!new RegExp('\\.png$', 'i').test(name)) return fallback;
    name = name.substring(0, name.length - 4).trim().substring(0, 80);
    return name.length > 0 ? name : fallback;
  } catch (_) { return fallback; }
}

/** 对可信内部路径按 lstat 判断存在；只把确实的 ENOENT 当不存在，不吞权限/IO 错误。 */
function exists_(path: string): boolean {
  try { fs.lstatSync(path); return true; }
  catch (error) {
    // FileIO 的 ENOENT 统一码为 13900002；宿主测试也按同一平台错误合同映射。
    if ((error as ErrorWithCode).code === 13900002) return false;
    throw error as Error;
  }
}

/** FileIO 平台错误的最小静态形状，避免 any/动态属性访问。 */
interface ErrorWithCode { code: number; }

/** 读取有界文件，循环处理短读并检查尾部；offset 是文件偏移，不是缓冲区偏移。 */
function readFd_(fd: number, maximum: number): Uint8Array {
  const stat: fs.Stat = fs.statSync(fd);
  if (!stat.isFile() || !Number.isInteger(stat.size) || stat.size <= 0 || stat.size > maximum) {
    throw new Error('文件为空、不是普通文件或超过允许的大小');
  }
  const bytes: Uint8Array = new Uint8Array(stat.size);
  let offset: number = 0;
  while (offset < bytes.byteLength) {
    const chunk: ArrayBuffer = new ArrayBuffer(Math.min(65536, bytes.byteLength - offset));
    const count: number = fs.readSync(fd, chunk, { offset: offset, length: chunk.byteLength });
    if (!Number.isInteger(count) || count <= 0 || count > chunk.byteLength) throw new Error('文件读取不完整');
    bytes.set(new Uint8Array(chunk, 0, count), offset);
    offset += count;
  }
  const tail: ArrayBuffer = new ArrayBuffer(1);
  if (fs.readSync(fd, tail, { offset: offset, length: 1 }) !== 0 || fs.statSync(fd).size !== bytes.byteLength) {
    throw new Error('文件在导入时发生变化，请重新选择');
  }
  return bytes;
}

/** 内部文件不跟随链接；调用者解析出的目录同样须在初始化时确认不是链接。 */
function readPath_(path: string, maximum: number): Uint8Array {
  if (!fs.lstatSync(path).isFile()) throw new Error('外观文件不是普通文件');
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { return readFd_(file.fd, maximum); } finally { fs.closeSync(file); }
}

/** 摘要输入总是非空的完整 PNG；不对 Uint8Array 的额外 backing bytes 计算摘要。 */
async function sha256_(bytes: Uint8Array): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  await md.update({ data: bytes });
  const result: cryptoFramework.DataBlob = await md.digest();
  let text: string = '';
  for (let i: number = 0; i < result.data.byteLength; i++) {
    text += result.data[i].toString(16).padStart(2, '0');
  }
  if (text.length !== 64) throw new Error('无法确认外观文件摘要');
  return text;
}

/** 对 JSON 反序列化对象逐字段校验；不能因一个损坏记录而悄悄丢失整个资产库。 */
function parseRecord_(bytes: Uint8Array): AppearanceAsset[] {
  const record: AppearanceLibraryRecord = JSON.parse(utf8ToString(bytes)) as AppearanceLibraryRecord;
  if (!record || typeof record.version !== 'number') throw new Error('外观库索引格式无效');
  if (record.version !== 1) throw new AppearanceLibraryVersionError();
  if (!Array.isArray(record.assets)) throw new Error('外观库索引格式无效');
  const ids: Set<string> = new Set<string>();
  const assets: AppearanceAsset[] = [];
  for (const item of record.assets) {
    if (!item || (item.kind !== 'skin' && item.kind !== 'cape') || typeof item.sha256 !== 'string' ||
      !new RegExp('^[a-f0-9]{64}$').test(item.sha256) || item.id !== item.kind + '-' + item.sha256 ||
      item.relativePath !== DIRECTORY + '/' + item.sha256 + '.png' || !safeRelativePath_(item.relativePath) ||
      typeof item.name !== 'string' || item.name.length === 0 || item.name.length > 80 ||
      new RegExp('[\\x00-\\x1f\\x7f]').test(item.name) ||
      !isAppearanceSize(item.kind, item.width, item.height) || !Number.isFinite(item.createdAt) ||
      item.createdAt <= 0 || ids.has(item.id)) throw new Error('外观库包含无效条目');
    ids.add(item.id);
    assets.push(copyAsset_(item));
  }
  return assets;
}

export class AppearanceLibrary {
  private filesDir_: string = '';
  private directory_: string = '';
  private initialized_: boolean = false;
  private recoveryNeeded_: boolean = false;
  private assets_: AppearanceAsset[] = [];
  private queue_: Promise<void> = Promise.resolve();
  /** 主账号域提供已提交与正在持久化的选择查询，避免删除与另一个编辑提交竞态。 */
  private usageGuard_: ((assetId: string) => boolean) | undefined = undefined;
  /** 兼容现有裸 PixelMap 消费者：淘汰只丢引用，不能销毁其他组件正在显示的位图。 */
  private previews_: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private previewLoads_: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();

  /**
   * 幂等初始化并恢复上次已确认索引。初始化失败可重试，不把异常保存为空库。
   * 同一实例禁止切换沙箱；并发 init/import/remove 都经过同一进程内队列。
   */
  init(context: Context): Promise<void> {
    return this.enqueue_(async (): Promise<void> => {
      const base: string = context.filesDir;
      if (!base || (this.filesDir_.length > 0 && this.filesDir_ !== base)) throw new Error('外观库存储上下文不一致');
      this.filesDir_ = base;
      this.directory_ = base + '/' + DIRECTORY;
      if (!exists_(this.directory_)) {
        fs.mkdirSync(this.directory_);
      }
      if (!fs.lstatSync(this.directory_).isDirectory()) throw new Error('外观库存储目录无效');
      if (this.initialized_ && !this.recoveryNeeded_) return;
      this.syncPath_(base);
      this.recover_();
      this.initialized_ = true;
    });
  }

  /** 只列出已持久确认的记录，返回新数组与新对象，绝不暴露库内可变引用。 */
  list(kind: AppearanceKind): AppearanceAsset[] {
    this.ready_();
    return this.assets_.filter((asset: AppearanceAsset): boolean => asset.kind === kind)
      .map((asset: AppearanceAsset): AppearanceAsset => copyAsset_(asset));
  }

  /** 由主进程 AccountManager 初始化时注册；不引入资产库到账号管理器的反向依赖。 */
  setUsageGuard(guard: (assetId: string) => boolean): void { this.usageGuard_ = guard; }

  /**
   * 原字节导入、解码确认、摘要去重、先保存 PNG 后提交索引。相同 kind+摘要返回
   * 既有条目，独立账号可共享；跨类型允许各有条目并引用同一张 64×32 PNG。
   */
  importFromUri(uri: string, kind: AppearanceKind): Promise<AppearanceAsset> {
    return this.enqueue_(async (): Promise<AppearanceAsset> => {
      this.ensureRecovered_();
      if (!uri || !new RegExp('^file://', 'i').test(uri)) throw new Error('请选择有效的本地 PNG 文件');
      const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      let bytes: Uint8Array;
      try { bytes = readFd_(file.fd, MAX_APPEARANCE_PNG_BYTES); } finally { fs.closeSync(file); }
      const info: AppearancePngInfo = validateAppearancePng(bytes, kind);
      await this.validateDecode_(bytes, info);
      const hash: string = await sha256_(bytes);
      const existing: AppearanceAsset | undefined = this.assets_.find((asset: AppearanceAsset): boolean =>
        asset.kind === kind && asset.sha256 === hash);
      const path: string = this.directory_ + '/' + hash + '.png';
      // 重复导入也检查并修复缺失/损坏的同内容文件，不能返回一个已失效的旧引用。
      let contentMatches: boolean = false;
      if (exists_(path)) contentMatches = await sha256_(readPath_(path, MAX_APPEARANCE_PNG_BYTES)) === hash;
      if (!contentMatches) this.writeConfirmed_(path, bytes);
      else { this.syncPath_(path); this.syncPath_(this.directory_); }
      if (existing !== undefined) return copyAsset_(existing);
      const asset: AppearanceAsset = { id: kind + '-' + hash, kind: kind, name: displayName_(uri, kind),
        sha256: hash, relativePath: DIRECTORY + '/' + hash + '.png', width: info.width,
        height: info.height, createdAt: Date.now() };
      const next: AppearanceAsset[] = this.assets_.map((item: AppearanceAsset): AppearanceAsset => copyAsset_(item));
      next.push(asset);
      this.commit_(next);
      return copyAsset_(asset);
    });
  }

  /**
   * 调用方须先确认没有账号仍选择该条目。先持久提交移除，再尝试回收没有其他库
   * 条目引用的原件；运行侧须在启动前预读 bytes，不能把本 API 当游戏租约管理器。
   */
  remove(id: string): Promise<void> {
    return this.enqueue_(async (): Promise<void> => {
      this.ensureRecovered_();
      const removed: AppearanceAsset | undefined = this.assets_.find((asset: AppearanceAsset): boolean => asset.id === id);
      if (removed === undefined) return;
      if (this.usageGuard_ !== undefined && this.usageGuard_(id)) throw new Error('此外观仍被账号使用，请先更换后再删除');
      this.commit_(this.assets_.filter((asset: AppearanceAsset): boolean => asset.id !== id));
      if (!this.assets_.some((asset: AppearanceAsset): boolean => asset.relativePath === removed.relativePath)) {
        // 回收前令备份也不再引用原件，避免主索引损坏时恢复出文件已被删除的条目。
        // 回收失败只留下孤立小文件，不把已经确认的主索引提交报告为失败。
        try {
          const record: AppearanceLibraryRecord = { version: 1, assets: this.assets_ };
          this.writeConfirmed_(this.directory_ + '/library.backup.json', JSON.stringify(record));
          fs.unlinkSync(this.resolvePath(removed));
          this.syncPath_(this.directory_);
        }
        catch (_) { /* 下次导入同摘要可复用；不扫描或扩大删除范围。 */ }
      }
      this.previews_.delete(removed.relativePath);
    });
  }

  /**
   * 将不可变账号/启动快照解析为当前沙箱路径，不要求条目仍在列表中。
   * 路径必须与摘要完全匹配，不能由外部相对路径构造任意沙箱读取。
   */
  resolvePath(asset: AppearanceAsset): string {
    if (!this.initialized_) throw new Error('外观库尚未初始化');
    if (!asset || !safeRelativePath_(asset.relativePath) ||
      asset.relativePath !== DIRECTORY + '/' + asset.sha256 + '.png') throw new Error('外观文件引用无效');
    this.checkDirectory_();
    const path: string = this.filesDir_ + '/' + asset.relativePath;
    if (exists_(path) && !fs.lstatSync(path).isFile()) throw new Error('外观文件不是普通文件');
    return path;
  }

  /**
   * 统一纹理入口。本地来源只接纳 amcl-texture:内部路径，远程保持 commons 现有
   * 共享缓存语义；返回的裸 PixelMap 不由调用者主动 release，最后持有者交由 GC。
   */
  async loadTexture(source: string): Promise<image.PixelMap | null> {
    if (!source.startsWith(SOURCE_PREFIX)) return getRemotePixelMap(source);
    if (!this.initialized_) return null;
    const relative: string = source.substring(SOURCE_PREFIX.length);
    if (!safeRelativePath_(relative)) return null;
    const cached: image.PixelMap | undefined = this.previews_.get(relative);
    if (cached !== undefined) return cached;
    const running: Promise<image.PixelMap | null> | undefined = this.previewLoads_.get(relative);
    if (running !== undefined) return running;
    const work: Promise<image.PixelMap | null> = this.decodePreview_(relative);
    this.previewLoads_.set(relative, work);
    try { return await work; } finally { this.previewLoads_.delete(relative); }
  }

  /** 队列的拒绝只影响当前调用，不使后续任务永久继承 rejected Promise。 */
  private enqueue_<T>(action: () => Promise<T>): Promise<T> {
    const work: Promise<T> = this.queue_.then(action);
    this.queue_ = work.then((): void => {}, (): void => {});
    return work;
  }

  /** 同步读者不能在发布状态未知时观察旧内存；init 或下一次修改会先尝试恢复。 */
  private ready_(): void {
    if (!this.initialized_) throw new Error('外观库尚未初始化');
    if (this.recoveryNeeded_) throw new Error('外观库保存状态待确认，请重新加载后重试');
    this.checkDirectory_();
  }

  /** 防止初始化后目录被替换成链接；NOFOLLOW 只能保护最后一段文件名。 */
  private checkDirectory_(): void {
    if (!fs.lstatSync(this.directory_).isDirectory()) throw new Error('外观库存储目录无效');
  }

  /** 修改前先收敛上次发布后异常，避免以旧内存覆盖已替换到磁盘的新索引。 */
  private ensureRecovered_(): void {
    if (!this.initialized_) throw new Error('外观库尚未初始化');
    if (this.recoveryNeeded_) this.recover_();
    this.ready_();
  }

  /** 同步具体文件或目录，用于确认 rename 发布后的真实持久边界。 */
  private syncPath_(path: string): void {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try { fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
  }

  /**
   * 公共 writer 在 rename 后异常时不假装回滚。仅当读回字节完全相等，并重新
   * fsync 文件与父目录都成功，才转为本次已确认；否则阻止后续写者，交给恢复。
   */
  private writeConfirmed_(path: string, data: string | Uint8Array): void {
    try { AtomicFileWriter.write(path, data); }
    catch (error) {
      if (!(error instanceof AtomicWriteError) || !error.published) throw error as Error;
      try {
        const actual: Uint8Array = readPath_(path, typeof data === 'string' ? MAX_INDEX_BYTES : MAX_APPEARANCE_PNG_BYTES);
        const matches: boolean = typeof data === 'string' ? utf8ToString(actual) === data :
          actual.byteLength === data.byteLength && actual.every((value: number, index: number): boolean => value === data[index]);
        if (!matches) throw new Error('文件提交读回不一致');
        this.syncPath_(path);
        this.syncPath_(this.directory_);
      } catch (_) {
        if (path === this.directory_ + '/library.json') this.recoveryNeeded_ = true;
        throw new Error('外观库保存状态待确认，请检查存储后重新加载');
      }
    }
  }

  /** 上一代备份先于新索引 durable，内存只在主索引提交成功后前移。 */
  private commit_(next: AppearanceAsset[]): void {
    const previous: AppearanceLibraryRecord = { version: 1, assets: this.assets_ };
    const updated: AppearanceLibraryRecord = { version: 1, assets: next };
    const text: string = JSON.stringify(updated);
    if (text.length > MAX_INDEX_BYTES / 4) throw new Error('外观库索引过大，请先删除不再使用的条目');
    this.writeConfirmed_(this.directory_ + '/library.backup.json', JSON.stringify(previous));
    this.writeConfirmed_(this.directory_ + '/library.json', text);
    this.assets_ = next.map((asset: AppearanceAsset): AppearanceAsset => copyAsset_(asset));
  }

  /**
   * 首选主索引；仅其缺失或格式损坏时回到上代备份。未知 IO 错误始终抛出。
   * 两份均损坏不能清空重建；没有任何索引才创建初始空库。恢复不扫描/删除 PNG。
   */
  private recover_(): void {
    const primary: string = this.directory_ + '/library.json';
    const backup: string = this.directory_ + '/library.backup.json';
    let assets: AppearanceAsset[] | undefined = undefined;
    if (exists_(primary)) {
      const size: number = fs.statSync(primary).size;
      if (size > 0 && size <= MAX_INDEX_BYTES) {
        const bytes: Uint8Array = readPath_(primary, MAX_INDEX_BYTES);
        try { assets = parseRecord_(bytes); }
        catch (error) {
          if (error instanceof AppearanceLibraryVersionError) throw error;
          /* 只允许格式错误进入备份恢复；真正 IO 错误在读取阶段直接抛出。 */
        }
      }
      if (assets !== undefined) this.syncPath_(primary);
    }
    if (assets === undefined && exists_(backup)) {
      assets = parseRecord_(readPath_(backup, MAX_INDEX_BYTES));
      const record: AppearanceLibraryRecord = { version: 1, assets: assets };
      this.writeConfirmed_(primary, JSON.stringify(record));
    }
    if (assets === undefined) {
      if (exists_(primary)) throw new Error('外观库索引已损坏，原文件已保留，请勿覆盖');
      assets = [];
      const record: AppearanceLibraryRecord = { version: 1, assets: assets };
      this.writeConfirmed_(primary, JSON.stringify(record));
    }
    this.syncPath_(this.directory_);
    this.assets_ = assets;
    this.recoveryNeeded_ = false;
  }

  /** 对小尺寸图片完成真实解码，头部/CRC通过不代表 IDAT 压缩数据可用。 */
  private async validateDecode_(bytes: Uint8Array, expected: AppearancePngInfo): Promise<void> {
    const source: image.ImageSource = image.createImageSource(bytes.buffer as ArrayBuffer);
    let pixels: image.PixelMap | undefined = undefined;
    try {
      const info: image.ImageInfo = await source.getImageInfo(0);
      if (info.mimeType !== 'image/png' || info.size.width !== expected.width ||
        info.size.height !== expected.height || await source.getFrameCount() !== 1) throw new Error('请选择有效的单帧 PNG');
      pixels = await source.createPixelMap();
      if (!pixels) throw new Error('PNG 像素解码失败');
    } finally {
      try { if (pixels !== undefined) await pixels.release(); }
      finally { await source.release(); }
    }
  }

  /** 有界本地预览缓存；加载失败返回 null，调用 UI 保留现有默认外观。 */
  private async decodePreview_(relative: string): Promise<image.PixelMap | null> {
    let source: image.ImageSource | undefined = undefined;
    try {
      this.checkDirectory_();
      const bytes: Uint8Array = readPath_(this.filesDir_ + '/' + relative, MAX_APPEARANCE_PNG_BYTES);
      // 本地来源不携带 kind；64×32 同时可用于皮肤/披风，两者尺寸的并集即皮肤白名单。
      validateAppearancePng(bytes, 'skin');
      const expectedHash: string = relative.substring(DIRECTORY.length + 1, relative.length - 4);
      if (await sha256_(bytes) !== expectedHash) return null;
      source = image.createImageSource(bytes.buffer as ArrayBuffer);
      // 账号头像和软件皮肤/披风渲染器按 RGBA 字节采样，不能依赖平台默认 BGRA/RGBA
      // 顺序，否则红蓝可能互换；与 commons 的远程原图路径保持同一像素契约。
      const pixels: image.PixelMap = await source.createPixelMap({
        editable: false, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      if (!pixels) return null;
      if (this.previews_.size >= MAX_PREVIEW_ENTRIES) {
        for (const first of this.previews_.keys()) { this.previews_.delete(first); break; }
      }
      this.previews_.set(relative, pixels);
      return pixels;
    } catch (_) { return null; }
    finally { if (source !== undefined) { try { await source.release(); } catch (_) { /* 位图不随 source 释放。 */ } } }
  }
}

/** 进程内共享实例；不跨进程共享可变对象，游戏只消费自己的不可变启动数据。 */
const appearanceLibrary_: AppearanceLibrary = new AppearanceLibrary();

/** 应用账号域唯一资产库入口，初始化由上层账号生命周期负责。 */
export function getAppearanceLibrary(): AppearanceLibrary { return appearanceLibrary_; }

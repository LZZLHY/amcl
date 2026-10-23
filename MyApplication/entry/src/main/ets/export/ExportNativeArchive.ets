/**
 * 导出Native数据面的唯一ArkTS适配：把已经冻结的私有计划交给异步job，独占其取消、
 * 进度和释放。业务源选择、Picker、版本租约与最终交付仍属于Coordinator。
 * 宿主/旧桥没有这一能力时返回undefined，沿原受测实现；正式包由注册与产物门验证新桥。
 */
import testNapi, { NativeExportArchiveSpec, NativeExportEntry, NativeExportHandle,
  NativeExportResult, NativeExportProgress } from 'libentry.so';
import { AppLogger } from 'commons';
import { ExportPlannedFile } from 'feature_core';

/** 工作位置由同一Coordinator产生，不从绝对字符串截取或猜测其他沙箱根。 */
export interface ExportNativeContext { filesDir: string; workRelative: string; }
/** 内容摘要与源SDK身份复核分开；这个结果只证明借用fd实际读过的字节。 */
export interface ExportNativeHashes { size: number; sha1: string; sha256: string; }

/** 所有相关入口必须成套存在，避免部分旧模块把新任务留在没有可查询/释放的桥上。 */
function available(): boolean {
  return typeof testNapi.exportArchiveStart === 'function' && typeof testNapi.exportArchiveVerifyStart === 'function' &&
    typeof testNapi.exportFileHashStart === 'function' && typeof testNapi.exportJobQuery === 'function' &&
    typeof testNapi.exportJobCancel === 'function' && typeof testNapi.exportJobRelease === 'function';
}

/** 首次释放重入只需让出当前SDK回调；持续故障再退避，避免每个小文件固定增加20ms。 */
async function wait(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, milliseconds); });
}

/** SDK在错误对象构造失败时可用null/undefined拒绝；统一成Error再交给页面读取message。 */
function nativeFailure(error: Object | null | undefined): Error {
  return error instanceof Error ? error : new Error('Native导出任务返回了非Error异常');
}

/**
 * Promise、进度和release三个事实一起收口。即使进度/回调报错，也先请求取消并等待
 * 同一job真正退出，才让上层抛错/清理；只清本轮timer，绝不取消别的下载或导出。
 */
async function run(handle: NativeExportHandle, cancelled: () => boolean,
  onProgress: (files: number, bytes: number) => void): Promise<NativeExportResult> {
  const id = handle.jobId;
  if (!Number.isSafeInteger(id) || id <= 0 || handle.completion === undefined) throw new Error('导出Native任务身份无效');
  let failure: Error | undefined = undefined;
  let result: NativeExportResult | undefined = undefined;
  let cancellationSent = false;
  // SDK可能已消费deferred却未能兑现Promise。只观察Native明确发布的交付失败，
  // 不重试同一句柄；race在第一次sample之前挂好，避免同步拒绝成为未处理异常。
  let rejectDelivery: ((error: Error) => void) | undefined = undefined;
  const deliveryFailure = new Promise<NativeExportResult>((_resolve, reject): void => {
    rejectDelivery = (error: Error): void => { reject(error); };
  });
  const completion = Promise.race<NativeExportResult>([handle.completion, deliveryFailure]);
  const observeDelivery = (state: NativeExportProgress): void => {
    if (!state.exists || !state.settled || state.errorCode !== 'DeliveryFailed') return;
    const error = new Error(state.errorMessage || 'Native导出结果交付失败');
    if (failure === undefined) failure = error;
    const reject = rejectDelivery; rejectDelivery = undefined;
    if (reject !== undefined) reject(error);
  };
  const cancel = (): void => {
    if (cancellationSent) return;
    cancellationSent = true; testNapi.exportJobCancel(id);
  };
  const sample = (): void => {
    try {
      if (cancelled()) cancel();
      const state: NativeExportProgress = testNapi.exportJobQuery(id);
      if (!state.exists) {
        if (!state.released) throw new Error('导出Native任务查询丢失');
        return;
      }
      if (state.jobId !== id || !Number.isSafeInteger(state.filesDone) || state.filesDone < 0 ||
        !Number.isSafeInteger(state.bytesDone) || state.bytesDone < 0) throw new Error('导出Native进度身份或长度无效');
      observeDelivery(state);
      onProgress(state.filesDone, state.bytesDone);
    } catch (error) {
      if (failure === undefined) failure = nativeFailure(error);
      try { cancel(); } catch (_) { /* completion/release屏障继续等待，查询故障不能触发提前清理。 */ }
    }
  };
  const timer = setInterval(sample, 125);
  try {
    sample();
    try { result = await completion; } catch (error) { if (failure === undefined) failure = nativeFailure(error); }
  } finally {
    clearInterval(timer);
    // Native契约要求completion之前已经join/close；这里仍用positive release收据确认，
    // 不把可见终态或一次query失败当作释放。异常时保持同一owner，避免清理仍在写入的目录。
    let warned = false; const began = Date.now();
    let firstReleaseWait = true;
    while (true) {
      // Promise续体可在SDK resolve内部同步进入finally。首次Release仍在交付守卫内时
      // 必须让出一个宏任务；返回后在退役前再次取交付状态，不能把已resolve但SDK报错
      // 的结果当成功。查询自身失败也不妨碍独立尝试真实release，沿用原取消收敛语义。
      try { observeDelivery(testNapi.exportJobQuery(id)); }
      catch (error) { if (failure === undefined) failure = nativeFailure(error); }
      try {
        if (testNapi.exportJobRelease(id)) break;
        cancel();
      } catch (error) { if (failure === undefined) failure = nativeFailure(error); }
      if (!warned && Date.now() - began >= 5000) {
        warned = true; AppLogger.warn('GameExport', '等待Native导出任务实际释放：' + id);
      }
      await wait(firstReleaseWait ? 0 : 20); firstReleaseWait = false;
    }
    rejectDelivery = undefined;
  }
  if (failure !== undefined) throw failure;
  if (cancelled()) throw new Error('已取消导出');
  if (result === undefined || result.jobId !== id) throw new Error('导出Native任务没有返回同一身份的结果');
  return result;
}

/** 只把归档需要的不可变字段复制给Native；不传认证、源mcRoot、下载源或可执行业务闭包。 */
function specification(context: ExportNativeContext, files: ExportPlannedFile[]): NativeExportArchiveSpec {
  const entries: NativeExportEntry[] = files.map((file: ExportPlannedFile): NativeExportEntry => {
    return { path: file.archivePath, size: file.size, sha256: file.sha256, directory: file.directory };
  });
  return { filesDir: context.filesDir, jobRelative: context.workRelative, snapshotRelative: 'snapshot',
    archiveRelative: 'export.zip', entries, workerCount: 2 };
}

/** Native写入只在完整成功、fsync/close/join和release之后返回；这里不发布业务成功。 */
export async function tryNativeWriteArchive(context: ExportNativeContext | undefined, files: ExportPlannedFile[],
  cancelled: () => boolean, onProgress: (files: number, bytes: number) => void): Promise<boolean> {
  if (context === undefined || !available()) return false;
  if (cancelled()) throw new Error('已取消导出');
  AppLogger.info('GameExport', 'Native ZIP64 writer: ' + context.workRelative + ' files=' + files.length);
  const result = await run(testNapi.exportArchiveStart(specification(context, files)), cancelled, onProgress);
  const bytes = files.reduce((sum: number, file: ExportPlannedFile): number => sum + file.size, 0);
  if (result.operation !== 'write' || result.files !== files.length || result.payloadBytes !== bytes ||
    !Number.isSafeInteger(result.archiveBytes) || result.archiveBytes <= 0 || result.size !== result.archiveBytes) {
    throw new Error('Native归档写入结果与计划不一致');
  }
  onProgress(result.files, result.payloadBytes); return true;
}

/** 独立parser仍逐entry读回结构/CRC/SHA，不调用writer头编码器来比较自己。 */
export async function tryNativeVerifyArchive(context: ExportNativeContext | undefined, files: ExportPlannedFile[],
  cancelled: () => boolean): Promise<boolean> {
  if (context === undefined || !available()) return false;
  if (cancelled()) throw new Error('已取消导出');
  AppLogger.info('GameExport', 'Native ZIP64 verifier: ' + context.workRelative + ' files=' + files.length);
  const result = await run(testNapi.exportArchiveVerifyStart(specification(context, files)), cancelled,
    (_files: number, _bytes: number): void => {});
  const bytes = files.reduce((sum: number, file: ExportPlannedFile): number => sum + file.size, 0);
  if (result.operation !== 'verify' || result.files !== files.length || result.payloadBytes !== bytes ||
    !Number.isSafeInteger(result.archiveBytes) || result.archiveBytes <= 0 || result.size !== result.archiveBytes) {
    throw new Error('Native归档校验结果与计划不一致');
  }
  return true;
}

/**
 * SDK调用方继续拥有原fd；Native在同步入口dup后只用pread，返回前结束自有fd。
 * 两个算法按调用用途独立选择：原四参数调用仍默认包含SHA256；依赖预览可明确只算
 * SHA1，URI读回仍只算SHA256。未请求的摘要必须为空，避免把不完整结果误作双摘要。
 * SDK路径身份检查留在原hashOpenedFile负责人；算法选择不改变job释放/取消屏障。
 */
export async function tryNativeHashFile(fd: number, size: number, needSha1: boolean,
  cancelled: () => boolean, needSha256: boolean = true): Promise<ExportNativeHashes | undefined> {
  if (!needSha1 && !needSha256) throw new Error('文件摘要至少需要一种算法');
  if (!available()) return undefined;
  if (cancelled()) throw new Error('已取消导出');
  const result = await run(testNapi.exportFileHashStart({ fd, size, sha1: needSha1, sha256: needSha256 }), cancelled,
    (_files: number, _bytes: number): void => {});
  if (result.operation !== 'hash' || result.files !== 1 || result.size !== size ||
    (needSha256 && !/^[0-9a-f]{64}$/.test(result.sha256)) || (!needSha256 && result.sha256.length !== 0) ||
    (needSha1 && !/^[0-9a-f]{40}$/.test(result.sha1)) || (!needSha1 && result.sha1.length !== 0)) {
    throw new Error('Native文件摘要结果无效');
  }
  return { size: result.size, sha1: result.sha1, sha256: result.sha256 };
}

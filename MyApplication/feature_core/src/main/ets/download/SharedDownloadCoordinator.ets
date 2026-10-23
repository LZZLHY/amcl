/**
 * 公共 libraries/assets 的内容协调器。一个 Native 批次仍能包含成千文件，不为每个
 * asset 新建 Native 任务；后来的安装只订阅所需路径，取消仅解除当前消费者。
 * Native 仍持有唯一最终路径所有权，所有映射直到 execution-settled 才可释放。
 */
import { DownloadTaskSpec, DownloadFileSpec, DownloadTaskView, DownloadListener, DownloadFailedFile,
  copyDownloadFileSpec } from './DownloadManager';
import { AppLogger } from 'commons';

export interface SharedDownloadBackend {
  run: (spec: DownloadTaskSpec, progress: DownloadListener) => Promise<DownloadTaskView>;
  cancel: (id: number) => boolean;
  purge: (id: number) => boolean;
}

/** 批次是传输 owner，消费者只保存订阅，不直接操作它的 Native taskId。 */
class SharedBatch {
  files: DownloadFileSpec[] = [];
  /** 创建时累计一次；进度热路径不得重新遍历整批assets计算权重。 */
  weight: number = 0;
  subscribers: Set<number> = new Set<number>();
  view: DownloadTaskView = new DownloadTaskView();
  done: boolean = false;
  settled: boolean = false;
  releaseDelayed: boolean = false;
  error: string = '';
}
/** 订阅时一次性计算交集与权重；进度回调不得对数千 assets 做二次方路径搜索。 */
class SharedSlice {
  batch: SharedBatch;
  files: DownloadFileSpec[] = [];
  weight: number = 0;
  /** 仅可明确归属本切片的basename；与未订阅文件重名时保守不展示。 */
  displayNames: Set<string> = new Set<string>();
  constructor(batch: SharedBatch) { this.batch = batch; }
}
class SharedRequest {
  view: DownloadTaskView = new DownloadTaskView();
  files: DownloadFileSpec[] = [];
  batches: SharedBatch[] = [];
  slices: SharedSlice[] = [];
  cancelled: boolean = false;
  callback: DownloadListener | undefined = undefined;
  resolve: (view: DownloadTaskView) => void = (): void => {};
  reject: (error: Error) => void = (): void => {};
  /** 订阅时固定一次，进度热路径不重新扫描数千文件。 */
  knownBytes: boolean = false;
  bytesTotal: number = 0;
}

/** 仅接受规范绝对路径；链接别名仍由 Native 的 canonical ownership 拒绝，不放宽边界。 */
function sharedPath(value: string): string {
  let path = value.replace(new RegExp('\\\\', 'g'), '/');
  if (!path.startsWith('/') && !new RegExp('^[A-Za-z]:/').test(path)) throw new Error('公共下载路径必须是绝对路径');
  if (path.split('/').some((part: string): boolean => part === '..' || part === '.')) throw new Error('公共下载路径不能含相对跳转');
  return path.replace(new RegExp('/+$'), '');
}

/** 有哈希时镜像顺序不影响内容身份；无哈希的旧 Maven 件只允许完全相同来源集合复用。 */
function contentIdentity(file: DownloadFileSpec): string {
  let digest = file.check?.sha1?.toLowerCase() ?? '';
  return sharedPath(file.allowedRoot) + '\n' + (file.check?.size ?? -1).toString() + '\n'
    + (digest.length > 0 ? 'sha1:' + digest : 'urls:' + file.urls.slice().sort().join('\n'))
    // 显式连接数是调用方的硬约束。已有批次的权限不能因内容相同而扩给另一消费者；
    // 缺省也不等于显式1，二者可能选择不同Range/传输模式，必须分别核对。
    + '\nconnections:' + (file.maxConnections === undefined ? 'default' : file.maxConnections.toString());
}

export class SharedDownloadCoordinator {
  /** 与 Native 的进程递增小整数域分离，保持现有 taskId > 0 消费者兼容。 */
  private nextId_: number = 1000000000000;
  private paths_: Map<string, SharedBatch> = new Map<string, SharedBatch>();
  private identities_: Map<string, string> = new Map<string, string>();
  private requests_: Map<number, SharedRequest> = new Map<number, SharedRequest>();
  private backend_: SharedDownloadBackend;

  constructor(backend: SharedDownloadBackend) { this.backend_ = backend; }

  /** 查询消费者快照；释放后不再暴露它的旧状态。 */
  get(id: number): DownloadTaskView | undefined { return this.requests_.get(id)?.view; }
  /** 已释放的逻辑 ID 也不能误送回 Native，因此用保留数值域而非当前 Map 成员判断。 */
  owns(id: number): boolean { return id >= 1000000000000; }

  /** 先完整检查所有路径，全部兼容后才登记；任何冲突都不留下半项订阅或隐形下载。 */
  run(spec: DownloadTaskSpec, progress?: DownloadListener): Promise<DownloadTaskView> {
    let seen = new Set<string>();
    for (let file of spec.files) {
      // 内容摘要不代表消费权限。短Bearer/限次grant的次数、字节和撤销属于各自lease，
      // 当前公共共享身份没有表达这些授权域；整批在登记前拒绝，不能偷用第一位的权限。
      if (file.bearerToken !== undefined || file.authorizedPolicy !== undefined) {
        return Promise.reject(new Error('受限授权下载不能进入公共文件共享，请使用独立下载任务'));
      }
      let path = sharedPath(file.localPath);
      if (seen.has(path)) return Promise.reject(new Error('公共下载目标重复：' + path));
      seen.add(path);
      let old = this.paths_.get(path);
      if (old !== undefined && old.done && this.trySettle_(old)) this.forget_(old);
      if (this.paths_.has(path) && this.identities_.get(path) !== contentIdentity(file))
        return Promise.reject(new Error('同一路径有不兼容的下载内容：' + path));
      if (old !== undefined && old.done && !old.settled)
        return Promise.reject(new Error('公共文件的旧下载仍在收敛：' + path));
    }
    let request = new SharedRequest();
    request.view.taskId = this.nextId_++;
    request.view.name = spec.name;
    request.view.state = 'Loading';
    // 把调用者可变数组变成此次意图的快照；回调重入不能改变已校验的路径或内容身份。
    request.files = spec.files.map((file: DownloadFileSpec): DownloadFileSpec => {
      // URL/校验对象独立复制，但未提供的可选属性必须继续缺省；显式 undefined 会让
      // Native 误以为调用方提供了连接数或摘要，进而在创建任务时拒绝整个库/资源批次。
      let snapshot: DownloadFileSpec = copyDownloadFileSpec(file);
      snapshot.localPath = sharedPath(file.localPath);
      snapshot.allowedRoot = sharedPath(file.allowedRoot);
      return snapshot;
    });
    request.callback = progress;
    request.knownBytes = request.files.every((file: DownloadFileSpec): boolean => file.check?.size !== undefined && file.check.size >= 0);
    request.bytesTotal = request.knownBytes ? request.files.reduce((sum: number, file: DownloadFileSpec): number =>
      sum + (file.check?.size ?? 0), 0) : 0;
    let fresh = new SharedBatch();
    for (let file of request.files) {
      let path = sharedPath(file.localPath);
      let batch = this.paths_.get(path);
      if (batch === undefined) {
        batch = fresh;
        fresh.files.push(file);
        fresh.weight += Math.max(1, file.check?.size ?? 1);
        this.paths_.set(path, batch);
        this.identities_.set(path, contentIdentity(file));
      }
      batch.subscribers.add(request.view.taskId);
      if (request.batches.indexOf(batch) < 0) request.batches.push(batch);
      let slice = request.slices.find((item: SharedSlice): boolean => item.batch === batch);
      if (slice === undefined) { slice = new SharedSlice(batch); request.slices.push(slice); }
      slice.files.push(file);
      slice.weight += Math.max(1, file.check?.size ?? 1);
    }
    // 路径/名字交集只在订阅时计算一次。进度事件通常非常频繁，不能每次对数千个
    // assets反复做map/reduce或二次方查找。重名但不在本切片的文件不会冒充当前文件。
    for (const slice of request.slices) {
      const paths = new Set<string>();
      for (const file of slice.files) {
        paths.add(file.localPath);
        slice.displayNames.add(file.localPath.substring(file.localPath.lastIndexOf('/') + 1));
      }
      for (const file of slice.batch.files) {
        if (!paths.has(file.localPath)) {
          slice.displayNames.delete(file.localPath.substring(file.localPath.lastIndexOf('/') + 1));
        }
      }
    }
    this.requests_.set(request.view.taskId, request);
    let completion = new Promise<DownloadTaskView>((resolve, reject): void => { request.resolve = resolve; request.reject = reject; });
    this.refresh_(request);
    if (fresh.files.length > 0) {
      let nativeSpec: DownloadTaskSpec = { name: 'shared:' + request.view.taskId + ':' + spec.name,
        files: fresh.files, activityId: spec.activityId };
      this.execute_(fresh, nativeSpec).catch((error: Error): void => {
        fresh.error = error.message; fresh.done = true; this.notifyBatch_(fresh);
      });
    }
    this.finish_(request);
    return completion;
  }

  /** Native 回调只更新传输快照；每个消费者收到自己的稳定逻辑 ID。 */
  private async execute_(batch: SharedBatch, spec: DownloadTaskSpec): Promise<void> {
    try {
      if (batch.subscribers.size === 0) { batch.settled = true; return; }
      batch.view = await this.backend_.run(spec, (view: DownloadTaskView): void => {
        batch.view = view;
        if (batch.subscribers.size === 0 && !view.finished) this.backend_.cancel(view.taskId);
        this.notifyBatch_(batch);
      });
    } catch (error) { batch.error = (error as Error).message; }
    finally {
      batch.done = true;
      // onComplete 不是执行栈已退出的证明。保留路径直到 Native purge 成功。
      for (let attempt = 0; !this.trySettle_(batch); attempt++) {
        if (attempt === 120 && !batch.releaseDelayed) {
          batch.releaseDelayed = true;
          AppLogger.warn('SharedDownload', '公共下载仍在收敛，继续保留等待者及父业务owner');
        }
        await new Promise<void>((resolve): void => { setTimeout(resolve, 250); });
      }
      if (batch.settled) this.forget_(batch);
      this.notifyBatch_(batch);
      // 最后一个消费者取消后已解除订阅，也需要通知它释放等待中的 Promise。
      this.requests_.forEach((request: SharedRequest): void => {
        if (request.batches.indexOf(batch) >= 0) this.finish_(request);
      });
    }
  }

  /** Native 释放失败/异常都保留 owner，交给有限等待或下一次显式清理重试。 */
  private trySettle_(batch: SharedBatch): boolean {
    if (batch.settled) return true;
    if (!batch.done) return false;
    try { batch.settled = batch.view.taskId <= 0 || this.backend_.purge(batch.view.taskId); }
    catch (error) { batch.settled = false; }
    return batch.settled;
  }
  /** 只移除仍指向本批次的路径，旧批次迟到收尾不能清掉新 owner。 */
  private forget_(batch: SharedBatch): void {
    for (let file of batch.files) {
      let path = sharedPath(file.localPath);
      if (this.paths_.get(path) === batch) { this.paths_.delete(path); this.identities_.delete(path); }
    }
  }
  /** 按现存订阅扇出；消费者终态在 finish 中幂等处理。 */
  private notifyBatch_(batch: SharedBatch): void {
    batch.subscribers.forEach((id: number): void => {
      let request = this.requests_.get(id);
      if (request !== undefined) { this.refresh_(request); this.finish_(request); }
    });
  }
  /** 批内其他文件失败不使已成功的共享文件失败；只有完整终态清单才允许这种隔离。 */
  private failures_(request: SharedRequest): DownloadFailedFile[] {
    let failures: DownloadFailedFile[] = [];
    for (let slice of request.slices) {
      let batch = slice.batch;
      if (!batch.done || (batch.error.length === 0 && batch.view.success)) continue;
      let listed = batch.view.failedFiles;
      // Native filesDone 统计所有已终结文件，包含失败；不可再加失败数，否则会误伤成功订阅。
      let completeList = !batch.view.aborted && listed.length > 0 && batch.view.filesDone === batch.files.length;
      for (let file of slice.files) {
        let failure = listed.find((item: DownloadFailedFile): boolean => item.localPath === file.localPath);
        if (failure !== undefined) failures.push(failure);
        else if (!completeList) failures.push({ localPath: file.localPath,
          basename: file.localPath.substring(file.localPath.lastIndexOf('/') + 1), triedUrls: file.urls,
          lastError: { kind: batch.view.errorKind || 'DownloadError', message: batch.error || batch.view.errorMessage,
            httpStatus: 0, nativeCode: 0 } });
      }
    }
    return failures;
  }
  /** 按订阅切片聚合工作量；缺大小的旧库只显示估算进度，不伪造字节总量。 */
  private refresh_(request: SharedRequest): void {
    if (request.view.finished) return;
    let total = 0; let done = 0; let speed = 0; let physicalSpeed = 0; let filesDone = 0;
    let estimated = false;
    let currentFiles: string[] = [];
    for (let slice of request.slices) {
      let batch = slice.batch;
      let fraction = batch.done && batch.view.success ? 1 : batch.view.progress;
      total += slice.weight; done += slice.weight * fraction;
      filesDone += Math.floor(slice.files.length * fraction);
      const wholeBatch = slice.files.length === batch.files.length;
      // 当前Native只提供批次总量。子集消费者的逻辑速度只能按工作量估算，另存物理
      // 吞吐供诊断；不把其他消费者的全部流量伪称本订阅的精确下载速度。
      physicalSpeed += batch.view.speedBps;
      speed += batch.view.speedBps * (wholeBatch || batch.weight <= 0 ? 1 : slice.weight / batch.weight);
      estimated = estimated || !wholeBatch;
      const active = batch.view.currentFiles.length > 0 ? batch.view.currentFiles : [batch.view.currentFile];
      for (const name of active) {
        if (name.length > 0 && slice.displayNames.has(name) && currentFiles.indexOf(name) < 0) currentFiles.push(name);
      }
    }
    request.view.filesTotal = request.files.length;
    request.view.filesDone = filesDone;
    // 无大小的历史 Maven 件仍可用文件权重展示进度，但不能把“权重 1”显示为真实 1 字节。
    const knownBytes = request.knownBytes;
    request.view.progressEstimated = estimated || !knownBytes;
    request.view.physicalSpeedBps = physicalSpeed;
    request.view.bytesTotal = request.bytesTotal;
    request.view.bytesDone = knownBytes && total > 0 ? request.view.bytesTotal * Math.min(1, done / total) : 0;
    request.view.progress = total > 0 ? done / total : 1;
    request.view.speedBps = speed;
    request.view.currentFiles = currentFiles;
    request.view.currentFile = currentFiles[0] ?? '';
    try { request.callback?.(request.view); } catch (error) { /* UI 回调不能破坏传输所有权。 */ }
  }
  /** 成功/失败等待所有关联批次收敛；取消可立即退出仍被其他消费者持有的批次。 */
  private finish_(request: SharedRequest): void {
    if (request.view.finished) return;
    if (request.cancelled) {
      if (request.batches.some((batch: SharedBatch): boolean => batch.subscribers.size === 0 && !batch.settled)) return;
      request.view.aborted = true;
      request.view.errorMessage = '已取消';
    } else {
      if (request.batches.some((batch: SharedBatch): boolean => !batch.settled)) return;
      request.view.failedFiles = this.failures_(request);
      request.view.success = request.view.failedFiles.length === 0;
      request.view.filesDone = request.files.length;
      request.view.errorMessage = request.view.failedFiles[0]?.lastError?.message ?? '';
    }
    request.view.finished = true;
    request.view.finishedAt = Date.now();
    request.view.durationMs = request.view.finishedAt - request.view.createdAt;
    request.view.state = request.cancelled ? 'Aborted' : request.view.success ? 'Finished' : 'Failed';
    if (request.view.success) { request.view.progress = 1; request.view.bytesDone = request.view.bytesTotal; }
    try { request.callback?.(request.view); } catch (error) { /* 同上。 */ }
    for (let batch of request.batches) batch.subscribers.delete(request.view.taskId);
    if (request.view.success) request.resolve(request.view);
    else request.reject(new Error(request.view.errorMessage || '公共文件下载失败'));
    // Maven 等调用者只消费 Promise，不持有 Registry adapter 来主动 purge。
    // 保留快照到当前 Promise 链读完错误详情，再在下一事件轮安全回收；purge 自身的
    // owner barrier 仍会保留未收敛批次，不能用自动回收掩盖实际在途 Native 执行。
    const id = request.view.taskId;
    setTimeout((): void => { this.purge(id); }, 0);
  }
  /** 解除消费者订阅；只有最后订阅者离开才请求 Native 取消，Promise 仍等待必要的收尾。 */
  cancel(id: number): boolean {
    let request = this.requests_.get(id);
    if (request === undefined || request.view.finished) return false;
    request.cancelled = true;
    for (let batch of request.batches) {
      batch.subscribers.delete(id);
      if (batch.subscribers.size === 0 && batch.view.taskId > 0 && !batch.done) this.backend_.cancel(batch.view.taskId);
    }
    this.finish_(request);
    return true;
  }
  /** 消费者不再引用共享传输即可释放；最后消费者必须等待自己的 Native 执行真正停止。 */
  purge(id: number): boolean {
    let request = this.requests_.get(id);
    if (request === undefined) return true;
    if (!request.view.finished) return false;
    for (let batch of request.batches) {
      if (batch.subscribers.size === 0 && !this.trySettle_(batch)) return false;
      if (batch.settled) this.forget_(batch);
    }
    this.requests_.delete(id);
    return true;
  }
}

/** 自更新的持久活动身份。只记录阶段和公开诊断，不写授权正文、设备标识或签名材料。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger, LOG_DOMAIN_DOWNLOAD, ledgerBegin, ledgerEndAsync, ledgerHas, ledgerManifest, ledgerDirOf, LedgerState } from 'commons';
import { SideloadFiles } from './SideloadFiles';
import { DownloadTaskRegistry } from 'feature_core';

interface UpdateActivityCheckpoint { schema: number; id: number; title: string; }
/** 业务已经取得的终态先耐久保存，关闭日志失败只留下收尾义务，不重新裁决安装结果。 */
interface UpdateActivityTerminal {
  schema: number; activityId: number; category: string; runNonce: string;
  state: LedgerState; summary: string; endedAt: number;
}

export class SideloadUpdateActivity {
  private filesDir: string;
  private checkpoint: string;
  private category: string;
  private id: number = 0;
  private title: string = '';
  private lastEvent: string = '';
  private running: boolean = false;
  /** 每次收尾冻结活动身份；失败清除Promise但保留事实，下一次核实或冷启可续作。 */
  private pendingTerminal: UpdateActivityTerminal | undefined = undefined;
  private finishing: Promise<void> | undefined = undefined;
  private terminalBlocked: boolean = false;

  /** 整轮更新保留身份以跨覆盖安装恢复；下载子活动由统一任务持有，无需另建恢复文件。 */
  constructor(filesDir: string, checkpoint: string = '', category: string = 'app_update') {
    this.filesDir = filesDir; this.checkpoint = checkpoint; this.category = category;
    if (checkpoint.length === 0) return;
    try {
      if (!fs.accessSync(checkpoint) || fs.statSync(checkpoint).size > 2048) return;
      const saved = JSON.parse(fs.readTextSync(checkpoint)) as UpdateActivityCheckpoint;
      const manifest = Number.isSafeInteger(saved.id) && saved.id > 0 ? ledgerManifest(filesDir, saved.id) : null;
      if (saved.schema === 1 && manifest !== null && manifest.category === category) {
        this.id = saved.id; this.title = manifest.title;
        this.running = manifest.state === LedgerState.RUNNING;
        const terminalPath: string = ledgerDirOf(filesDir, saved.id) + '/update-terminal.json';
        if (this.running && fs.accessSync(terminalPath)) {
          const terminal = JSON.parse(fs.readTextSync(terminalPath)) as UpdateActivityTerminal;
          if (terminal.schema !== 1 || terminal.activityId !== saved.id || terminal.category !== category
            || terminal.runNonce.length === 0 || terminal.runNonce !== manifest.runNonce || typeof terminal.summary !== 'string'
            || !Number.isSafeInteger(terminal.endedAt) || terminal.endedAt < saved.id
            || ![LedgerState.SUCCESS, LedgerState.FAILED, LedgerState.ABORTED, LedgerState.INTERRUPTED].includes(terminal.state)) {
            throw new Error('更新活动终态原件损坏，请保留现场核实');
          }
          this.pendingTerminal = terminal;
        }
      }
    } catch (_) {
      // 身份尚未承认时不关联其他活动；已承认身份后发现终态原件损坏则保留并阻断收尾。
      if (this.id > 0) this.terminalBlocked = true;
    }
  }

  activityId(): number { return this.id; }
  isRunning(): boolean { return this.running; }

  /**
   * 新更新默认独立开账；只有调用方核实同目标并明确提供retryOf时才关联前次失败。
   * checkpoint只用于恢复当前身份，不代表下次更新是重试。显式parent仍是下载子活动；
   * RUNNING重复调用继续复用原身份，不消费新的重试关系或覆盖已保存结局。
   */
  begin(title: string, parent: number = 0, preferred: number = 0, retryOf: number = 0): number {
    if (this.pendingTerminal !== undefined || this.terminalBlocked) throw new Error('上次更新活动正在保存结果，请核实收尾后重试');
    if (this.isRunning()) return this.id;
    const previous = this.id;
    let retryParent = 0;
    if (parent === 0 && Number.isSafeInteger(retryOf) && retryOf > 0 && retryOf === previous) {
      // 原活动必须仍存在且属于本类；SUCCESS、损坏/缺失或别类身份绝不成为重试来源。
      // 不匹配只省略关联，仍按新活动开账，不改写任何历史manifest。
      try {
        const prior = ledgerManifest(this.filesDir, retryOf);
        if (prior !== null && prior.category === this.category &&
          (prior.state === LedgerState.FAILED || prior.state === LedgerState.ABORTED || prior.state === LedgerState.INTERRUPTED)) retryParent = retryOf;
      } catch (_) { /* 无法证明关系时保留独立新活动。 */ }
    }
    const registry = DownloadTaskRegistry.instance();
    let id = registry.reserveActivityId(Math.max(preferred, parent + 1));
    while (ledgerHas(this.filesDir, id)) id = registry.reserveActivityId(id + 1);
    if (!ledgerBegin(this.filesDir, id, { category: this.category, title: title,
      parentActivityId: parent || retryParent, relation: parent > 0 ? 'download' : retryParent > 0 ? 'retry' : '' })) {
      throw new Error('无法建立更新活动记录，请检查可用存储后重试');
    }
    this.id = id; this.title = title; this.lastEvent = ''; this.running = true;
    try {
      if (this.checkpoint.length > 0) {
        const saved: UpdateActivityCheckpoint = { schema: 1, id: id, title: title };
        SideloadFiles.write(this.checkpoint, JSON.stringify(saved));
      }
    } catch (error) { this.finish(LedgerState.FAILED, '更新活动身份保存失败'); throw error as Error; }
    this.event('开始', title);
    this.notifyHistory();
    return id;
  }

  /** 冷启动只重接仍进行中的同一活动日志；终态不重新开账，也不改写前次失败的结论。 */
  resume(): void {
    if (this.isRunning() && this.pendingTerminal === undefined && !this.terminalBlocked) {
      ledgerBegin(this.filesDir, this.id, { category: this.category, title: this.title });
    }
  }

  /** 相邻相同状态去重，下载字节留给 Native scope，避免定时复检和每帧进度刷满日志。 */
  event(stage: string, message: string): void {
    const text = stage + '：' + message;
    if (!this.isRunning() || text === this.lastEvent) return;
    this.lastEvent = text;
    AppLogger.info('SideloadUpdate', text, LOG_DOMAIN_DOWNLOAD, this.id);
  }

  /** Void协调入口仍显式处理失败；原件与pending保留，安装核实用finishAsync真正等待。 */
  finish(state: LedgerState, summary: string): void {
    this.finishAsync(state, summary).catch((error: Error): void => {
      AppLogger.warn('SideloadUpdate', '活动结果尚未保存，原终态保留等待重试', error, LOG_DOMAIN_DOWNLOAD);
    });
  }

  /**
   * 先保存小型终态原件，再等待真实Native关闭与同ID canonical队列。
   * 并发同结局复用同一Promise；结局冲突不能覆盖原事实。只有成功才解除running并通知历史。
   * 这里的小型同步原件提交保留现有AtomicWriter耐久契约，不同步等待writer或扫描日志。
   */
  finishAsync(state: LedgerState, summary: string): Promise<void> {
    if (this.terminalBlocked) return Promise.reject(new Error('更新活动终态原件损坏，请保留现场核实'));
    if (![LedgerState.SUCCESS, LedgerState.FAILED, LedgerState.ABORTED, LedgerState.INTERRUPTED].includes(state)) {
      return Promise.reject(new Error('更新活动收尾只能提交明确终态'));
    }
    if (!this.isRunning()) return Promise.resolve();
    if (this.pendingTerminal !== undefined && this.pendingTerminal.state !== state) {
      return Promise.reject(new Error('更新活动已有待保存终态，不能用其他结局覆盖'));
    }
    if (this.finishing !== undefined) return this.finishing;
    if (this.pendingTerminal === undefined) {
      this.event('结果', summary);
      // 先冻结业务事实，身份/原件写盘异常也不能让waitForFinish错误认为没有待收尾工作。
      this.pendingTerminal = { schema: 1, activityId: this.id, category: this.category, runNonce: '',
        state: state, summary: summary, endedAt: Date.now() };
    }
    const terminal: UpdateActivityTerminal = this.pendingTerminal;
    try {
      const manifest = ledgerManifest(this.filesDir, terminal.activityId);
      if (manifest === null || manifest.category !== terminal.category || (manifest.runNonce ?? '').length === 0
        || terminal.runNonce.length > 0 && terminal.runNonce !== manifest.runNonce) {
        throw new Error('更新活动身份无法核实，原业务结果保留');
      }
      terminal.runNonce = manifest.runNonce ?? '';
      const directory: string = ledgerDirOf(this.filesDir, terminal.activityId);
      SideloadFiles.ensureDirectory(directory);
      SideloadFiles.write(directory + '/update-terminal.json', JSON.stringify(terminal));
    } catch (error) { return Promise.reject(error as Error); }
    const commit = ledgerEndAsync(this.filesDir, terminal.activityId, { state: terminal.state,
      source: 'sideload.update', summary: terminal.summary, endedAt: terminal.endedAt });
    const completed: Promise<void> = commit.then((): void => {
      // 活动身份只能在本次提交成功后复用；额外身份比较拒绝旧异步结果污染新attempt。
      if (this.id === terminal.activityId) { this.running = false; this.pendingTerminal = undefined; this.notifyHistory(); }
      this.finishing = undefined;
    }, (error: Error): void => { this.finishing = undefined; throw error as Error; });
    this.finishing = completed;
    return completed;
  }

  /** 冷启和安装核实续作已保存的原结局，不重新生成结束时间或把IO失败改成安装失败。 */
  waitForFinishAsync(): Promise<void> {
    if (this.terminalBlocked) return Promise.reject(new Error('更新活动终态原件损坏，请保留现场核实'));
    const terminal = this.pendingTerminal;
    return terminal === undefined ? Promise.resolve() : this.finishAsync(terminal.state, terminal.summary);
  }

  /** 通用stale必须暂时豁免仍未耐久提交的活动，否则它会抢先写INTERRUPTED。 */
  hasPendingTerminal(): boolean { return this.pendingTerminal !== undefined || this.terminalBlocked; }

  /** 只在开账/封账已落盘后通知首页，不用每个下载进度 tick 扫描整个账本。 */
  private notifyHistory(): void {
    const revision = AppStorage.get<number>('amclUpdateActivityRevision') ?? 0;
    AppStorage.setOrCreate<number>('amclUpdateActivityRevision', revision + 1);
  }
}

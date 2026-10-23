/**
 * 应用UID域的持久安装阻断。fence存在即禁止新游戏和关键文件执行；解析损坏也不能放行。
 * 创建由已持EX的Executor执行，清除仅接受Executor核实的终态，普通取消/页面销毁不删除。
 * Native独立进程直接在SH下读取同一路径，因此不依赖ArkTS单例跨进程存活。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';
import { AtomicWriteError } from 'commons';
import { SideloadFiles } from './SideloadFiles';
import { InstallExecutionIdentity, InstallExecutionError } from './SideloadInstallProtocol';

interface InstallFenceRecord {
  schema: number; installId: string; nonce: string; ownerAttemptId: string; protocol: number; createdAt: number;
  decisionMode?: string; state?: string;
}

export class InstallFence {
  private root: string;
  private path: string;
  constructor(filesDir: string) { this.root = filesDir + '/sideload-update'; this.path = this.root + '/install-fence.json'; }

  /**
   * Entry最早固定Native根。旧Installing/Pending即使尚无fence也迁移为阻断；这不是授予
   * 旧脚本v2撤销能力。坏journal进入unknown阻断，不能通过隔离坏文件自动获得新安装许可。
   */
  static init(filesDir: string): boolean {
    if (!testNapi.configureSideloadInstallRoot(filesDir)) throw new InstallExecutionError('storage', '无法固定安装保护目录');
    const fence = new InstallFence(filesDir);
    SideloadFiles.ensureDirectory(fence.root);
    if (fence.blocked()) return true;
    const transaction = fence.root + '/transaction.json';
    try { if (!fs.accessSync(transaction)) return false; }
    catch (_) { throw new InstallExecutionError('storage', '无法读取原安装事务，保留安装保护'); }
    let row: Record<string, Object>;
    try {
      if (!fs.statSync(transaction).isFile() || fs.statSync(transaction).size > 512 * 1024) throw new Error('Invalid journal');
      row = JSON.parse(fs.readTextSync(transaction)) as Record<string, Object>;
    } catch (_) {
      fence.write({ schema: 1, installId: 'unknown', nonce: '', ownerAttemptId: '', protocol: 1, createdAt: Date.now() });
      return true;
    }
    const phase = String(row['phase'] ?? '');
    if (phase !== 'installing' && phase !== 'confirmation-pending' && phase !== 'dispatch-intent') return false;
    const record: InstallFenceRecord = { schema: 1, installId: String(row['installId'] ?? row['id'] ?? 'unknown'),
      nonce: String(row['restartNonce'] ?? ''), ownerAttemptId: String(row['ownerAttemptId'] ?? row['id'] ?? ''),
      protocol: Number(row['installProtocol'] ?? 1), createdAt: Date.now() };
    fence.write(record); return true;
  }

  /** 任何已存在的fence都是阻断；未知格式只供恢复，不得将它降成不存在。 */
  blocked(): boolean {
    try { return fs.accessSync(this.path); }
    catch (_) { return true; } // 无法读取不是无fence，关键业务保持阻断。
  }
  private read(): InstallFenceRecord {
    try {
    if (!fs.statSync(this.path).isFile() || fs.statSync(this.path).size > 4096) throw new InstallExecutionError('storage', '安装保护记录无法读取');
    const row = JSON.parse(fs.readTextSync(this.path)) as InstallFenceRecord;
    if ((row.schema !== 1 && row.schema !== 2) || typeof row.installId !== 'string' || typeof row.nonce !== 'string') {
      throw new InstallExecutionError('storage', '安装保护记录损坏，请核实上次安装');
    }
      return row;
    } catch (_) { throw new InstallExecutionError('storage', '安装保护记录无法核实，请保留现场'); }
  }
  private write(record: InstallFenceRecord): void { SideloadFiles.write(this.path, JSON.stringify(record)); }

  /** EX已取得后才发布；另一个owner或legacy未知记录不能被新尝试覆写。 */
  arm(identity: InstallExecutionIdentity): void {
    if (this.blocked()) {
      const current = this.read();
      if (current.installId !== identity.installId || current.nonce !== identity.nonce || current.protocol !== 2) {
        throw new InstallExecutionError('outcome-unknown', '上一次安装尚未核实，不能建立新的安装事务');
      }
      return;
    }
    this.write({ schema: 2, installId: identity.installId, nonce: identity.nonce,
      ownerAttemptId: identity.ownerAttemptId, protocol: 2, createdAt: Date.now(), state: 'preparing' });
  }
  /**
   * 无mode准备阶段的崩溃仍可恢复：schema2 Preparing是“未安排执行请求”的durable证明。
   * 旧schema1/no-state绝不补造该证明；dispatch必须先markDispatching才可入HDC队列。
   */
  preparing(identity: InstallExecutionIdentity): boolean {
    if (!this.blocked()) return false;
    try {
      const record = this.read();
      return record.schema === 2 && record.protocol === 2 && record.state === 'preparing' &&
        record.installId === identity.installId && record.nonce === identity.nonce && record.ownerAttemptId === identity.ownerAttemptId;
    } catch (_) { return false; }
  }
  /** 同Repository DispatchIntent之后、任何HDC执行请求之前提交，不允许回退到Preparing。 */
  markDispatching(identity: InstallExecutionIdentity): void {
    const current = this.read();
    if (!this.preparing(identity) || ['link', 'flock-rename'].indexOf(current.decisionMode ?? '') < 0) {
      throw new InstallExecutionError('outcome-unknown', '安装准备或后端身份尚未成立');
    }
    current.state = 'dispatching'; this.write(current);
  }
  /** 能力后端在上传worker/授执行权之前可靠保存；恢复者不能改用另一套锁协议。 */
  setMode(identity: InstallExecutionIdentity, mode: string): void {
    const current = this.read();
    if (!this.preparing(identity) || current.installId !== identity.installId || current.nonce !== identity.nonce || current.protocol !== 2 ||
      ['link', 'flock-rename'].indexOf(mode) < 0) throw new InstallExecutionError('outcome-unknown', '安装能力与事务不匹配');
    if (current.decisionMode !== undefined && current.decisionMode !== mode) throw new InstallExecutionError('outcome-unknown', '不能改变已准备的安装协议后端');
    current.decisionMode = mode; this.write(current);
  }
  mode(identity: InstallExecutionIdentity): string {
    const current = this.read();
    return current.installId === identity.installId && current.nonce === identity.nonce && current.protocol === 2 ? current.decisionMode ?? '' : '';
  }

  /**
   * 调用方持有EX且已核实同owner的终态后才清除。unlink后目录同步失败仍抛出，不能向
   * 上层报告持久清除完成；Native的安全依据同时包括已存的业务终态和实际fence。
   */
  clear(identity: InstallExecutionIdentity): void {
    const exists = this.blocked();
    if (exists) {
      const current = this.read();
      if (current.installId !== identity.installId || current.nonce !== identity.nonce || current.protocol !== 2) {
        throw new InstallExecutionError('outcome-unknown', '不能解除其他安装事务的保护');
      }
    }
    // 前次unlink成功但目录同步失败时，重试必须同步“缺文件”事实，不能因不存在直接成功。
    let removed = !exists;
    let directory: fs.File | undefined = undefined;
    try {
      if (exists) fs.unlinkSync(this.path);
      removed = true;
      directory = fs.openSync(this.root, fs.OpenMode.READ_ONLY);
      fs.fsyncSync(directory.fd); fs.closeSync(directory); directory = undefined;
    } catch (_) {
      if (directory !== undefined) { try { fs.closeSync(directory); } catch (_) { /* 维持原持久性分类。 */ } }
      throw new AtomicWriteError(removed);
    }
  }
}

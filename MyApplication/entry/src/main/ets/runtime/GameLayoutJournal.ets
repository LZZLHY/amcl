/**
 * 独立游戏的有界布局提交日志。游戏只写应用私有 journal，不打开 Preferences/XML；
 * 启动器确认游戏锁空闲后，通过 LayoutStore 三方合并并持久化，编辑草稿未结束则延后。
 * 账号/设置不走此通道，允许的数据仅为 control_layout 的 profiles 与 active_profile。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import testNapi from 'libentry.so';
import { ProcessPreferences, GameLayoutCommitSink, LaunchPreferenceSnapshot, LaunchPreferenceValue,
  copyLaunchPreferenceSnapshot, writeEvidenceTextAtomic, ensureDirSync, evidenceFileDigestSync,
  AppLogger, LOG_DOMAIN_LAUNCH } from 'commons';
import { getLayoutStore, mergeLayoutPreferences, utf8ByteLength, GameLayoutImportResult } from 'gamecontrol';

const MAX_JOURNAL_BYTES: number = 4 * 1024 * 1024;

interface LayoutJournalIdentity {
  schema: number;
  snapshotId: string;
  activityId: number;
  parentPid: number;
  gamePid: number;
  createdAt: number;
  base: LaunchPreferenceSnapshot;
}

interface LayoutJournalRecord extends LayoutJournalIdentity {
  revision: number;
  submittedAt: number;
  proposed: LaunchPreferenceSnapshot;
}

/** 导入失败抛错；deferred 是明确未应用，不得显示“布局已同步”。 */
export interface GameLayoutImportReport {
  imported: number;
  pending: number;
  deferred: boolean;
  conflicts: string[];
}

/** 快照 UUID 是唯一文件名输入，禁止路径片段及宽松 parseInt 身份。 */
function validSnapshotId(id: string): boolean {
  return new RegExp('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').test(id);
}

function positiveInteger(value: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

/**
 * 内存快照可带历史 control_layout 键，但传输文件只投影两项可编辑值。
 * 投影不修改 owner 原对象或 Preferences，缺省字符串保留首装“尚未选择布局”的语义。
 * 此函数不能直接用于信任磁盘输入；磁盘入口必须经过下面的严格白名单校验。
 */
function projectLayout(snapshot: LaunchPreferenceSnapshot): LaunchPreferenceSnapshot {
  const checked: LaunchPreferenceSnapshot = copyLaunchPreferenceSnapshot(snapshot);
  if (checked.name !== 'control_layout') throw new Error('布局通道拒绝非 control_layout 快照');
  const profiles: LaunchPreferenceValue = checked.values['profiles'] ?? '';
  const active: LaunchPreferenceValue = checked.values['active_profile'] ?? '';
  if (typeof profiles !== 'string' || typeof active !== 'string') throw new Error('布局偏好必须是字符串');
  const values: Record<string, LaunchPreferenceValue> = { 'profiles': profiles, 'active_profile': active };
  return { name: 'control_layout', values: values };
}

/** 磁盘 schema 不接受额外键，不能用兼容历史内存快照的投影隐去非法写入。 */
function requireOnlyKeys(value: Object, allowed: string[]): void {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('布局日志对象无效');
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw new Error('布局通道包含未授权字段');
  }
}

function layoutOnly(snapshot: LaunchPreferenceSnapshot): LaunchPreferenceSnapshot {
  requireOnlyKeys(snapshot, ['name', 'values']);
  const checked: LaunchPreferenceSnapshot = copyLaunchPreferenceSnapshot(snapshot);
  requireOnlyKeys(checked.values, ['profiles', 'active_profile']);
  return projectLayout(checked);
}

/** 全量原始基线只存在 child 内存；逐键比较不受 JSON 属性顺序影响，也禁止增删历史键。 */
function samePreferenceSnapshot(left: LaunchPreferenceSnapshot, right: LaunchPreferenceSnapshot): boolean {
  const keys: string[] = Object.keys(left.values);
  return left.name === right.name && keys.length === Object.keys(right.values).length
    && keys.every((key: string): boolean => left.values[key] === right.values[key]);
}

/** 读取前限制普通文件字节数；原子 rename 后正式名称才可被导入，tmp 永远不是提交。 */
function readJournalText(path: string): string {
  const stat = fs.statSync(path);
  if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_JOURNAL_BYTES) throw new Error('布局日志不是有效的有界普通文件');
  const text: string = fs.readTextSync(path);
  if (utf8ByteLength(text) > MAX_JOURNAL_BYTES) throw new Error('布局日志超过字节上限');
  return text;
}

function journalDirectory(context: common.Context): string { return context.filesDir + '/game-layout-journal'; }

/** 所有写入都等到文件与父目录 fsync 成功才返回；短写/rename/flush 失败向编辑器传播。 */
function writeJournal(path: string, text: string): void {
  if (utf8ByteLength(text) > MAX_JOURNAL_BYTES) throw new Error('布局提交超过 4 MiB 上限');
  ensureDirSync(path.substring(0, path.lastIndexOf('/')));
  writeEvidenceTextAtomic(path, text);
}

function readIdentity(context: common.Context, snapshotId: string): LayoutJournalIdentity {
  const identity = JSON.parse(readJournalText(journalDirectory(context) + '/' + snapshotId + '.base.json')) as LayoutJournalIdentity;
  requireOnlyKeys(identity, ['schema', 'snapshotId', 'activityId', 'parentPid', 'gamePid', 'createdAt', 'base']);
  if (!identity || identity.schema !== 1 || identity.snapshotId !== snapshotId
    || !positiveInteger(identity.activityId) || !positiveInteger(identity.parentPid)
    || !Number.isSafeInteger(identity.gamePid) || identity.gamePid < 0
    || !positiveInteger(identity.createdAt)) throw new Error('布局会话基线身份无效');
  identity.base = layoutOnly(identity.base);
  return identity;
}

/** 成功回执绑定整份已验证 journal 的摘要；它只能避免重放，不能替代一次新的身份验证。 */
function isAppliedReceipt(path: string, record: LayoutJournalRecord, digest: string): boolean {
  try {
    const receipt = JSON.parse(readJournalText(path)) as Record<string, Object>;
    requireOnlyKeys(receipt, ['schema', 'snapshotId', 'activityId', 'gamePid', 'digest']);
    return receipt['schema'] === 1 && receipt['snapshotId'] === record.snapshotId
      && receipt['activityId'] === record.activityId && receipt['gamePid'] === record.gamePid
      && receipt['digest'] === digest;
  } catch (e) { return false; }
}

/** sink 固定原始 base，revision 只在提交已落盘后推进；子进程不会取得 owner XML 句柄。 */
class GameLayoutJournalSink implements GameLayoutCommitSink {
  private context: common.Context;
  private identity: LayoutJournalIdentity;
  private originalBase: LaunchPreferenceSnapshot;
  private revision: number = 0;

  constructor(context: common.Context, identity: LayoutJournalIdentity, base: LaunchPreferenceSnapshot) {
    this.context = context;
    this.identity = identity;
    this.originalBase = copyLaunchPreferenceSnapshot(base);
  }

  async commit(base: LaunchPreferenceSnapshot, proposed: LaunchPreferenceSnapshot): Promise<void> {
    if (!ProcessPreferences.isGameProcess() || testNapi.desktopProcessId() !== this.identity.gamePid) {
      throw new Error('布局提交进程不匹配');
    }
    const original: LaunchPreferenceSnapshot = copyLaunchPreferenceSnapshot(base);
    if (!samePreferenceSnapshot(original, this.originalBase)) throw new Error('布局提交试图替换本局启动基线');
    // 先校验全量内存快照：历史其它键只读透传，增删或改值均拒绝；通过后才投影写盘。
    // 不可先投影再校验，否则越权修改会被静默丢弃，编辑器却错误地显示保存成功。
    mergeLayoutPreferences(original, proposed, original, this.identity.snapshotId);
    const cleanBase: LaunchPreferenceSnapshot = projectLayout(original);
    const cleanProposed: LaunchPreferenceSnapshot = projectLayout(proposed);
    if (JSON.stringify(cleanBase) !== JSON.stringify(this.identity.base)) throw new Error('布局提交试图替换本局启动基线');
    const record: LayoutJournalRecord = { schema: 1, snapshotId: this.identity.snapshotId,
      activityId: this.identity.activityId, parentPid: this.identity.parentPid, gamePid: this.identity.gamePid,
      createdAt: this.identity.createdAt, base: cleanBase, proposed: cleanProposed,
      revision: this.revision + 1, submittedAt: Date.now() };
    writeJournal(journalDirectory(this.context) + '/' + this.identity.snapshotId + '.json', JSON.stringify(record));
    this.revision = record.revision;
  }
}

export class GameLayoutJournal {
  private static importing: Promise<GameLayoutImportReport> | undefined = undefined;

  /** 启动器生成 ticket 时建立不可混局的原始基线；gamePid 在授权 consume 后仅绑定一次。 */
  static prepare(context: common.Context, snapshotId: string, activityId: number, parentPid: number,
    base: LaunchPreferenceSnapshot): void {
    if (ProcessPreferences.isGameProcess() || !validSnapshotId(snapshotId) || !positiveInteger(activityId)
      || parentPid !== testNapi.desktopProcessId()) throw new Error('不能创建布局会话基线');
    const clean: LaunchPreferenceSnapshot = projectLayout(base);
    mergeLayoutPreferences(clean, clean, clean, snapshotId);
    const identity: LayoutJournalIdentity = { schema: 1, snapshotId: snapshotId, activityId: activityId,
      parentPid: parentPid, gamePid: 0, createdAt: Date.now(), base: clean };
    writeJournal(journalDirectory(context) + '/' + snapshotId + '.base.json', JSON.stringify(identity));
  }

  /** 必须在已验证独立 PID/游戏锁、已安装三类快照后且首次 LayoutStore.open 前调用。 */
  static installGame(context: common.Context, snapshotId: string, activityId: number, parentPid: number,
    gamePid: number, base: LaunchPreferenceSnapshot): void {
    if (!validSnapshotId(snapshotId) || !ProcessPreferences.isGameProcess() || gamePid !== testNapi.desktopProcessId()
      || gamePid === parentPid || !positiveInteger(gamePid)) throw new Error('布局游戏进程身份无效');
    const identity: LayoutJournalIdentity = readIdentity(context, snapshotId);
    if (identity.activityId !== activityId || identity.parentPid !== parentPid || identity.gamePid !== 0
      || JSON.stringify(identity.base) !== JSON.stringify(projectLayout(base))) throw new Error('布局基线与启动票据不匹配');
    identity.gamePid = gamePid;
    writeJournal(journalDirectory(context) + '/' + snapshotId + '.base.json', JSON.stringify(identity));
    ProcessPreferences.installGameLayoutCommitSink(new GameLayoutJournalSink(context, identity, base));
  }

  /** 同一启动器内多个前台/prepare 入口复用一次导入；失败保持 rejected 供调用方明确处理。 */
  static importPending(context: common.UIAbilityContext): Promise<GameLayoutImportReport> {
    if (GameLayoutJournal.importing !== undefined) return GameLayoutJournal.importing;
    const job: Promise<GameLayoutImportReport> = GameLayoutJournal.importInternal(context);
    GameLayoutJournal.importing = job;
    job.then((): void => { GameLayoutJournal.importing = undefined; },
      (): void => { GameLayoutJournal.importing = undefined; });
    return job;
  }

  private static async importInternal(context: common.UIAbilityContext): Promise<GameLayoutImportReport> {
    const report: GameLayoutImportReport = { imported: 0, pending: 0, deferred: false, conflicts: [] };
    if (ProcessPreferences.isGameProcess()) throw new Error('游戏进程不能导入 owner 布局');
    if (testNapi.desktopGameProcessState(context.filesDir, 0) !== 0) {
      report.deferred = true;
      return report;
    }
    const directory: string = journalDirectory(context);
    let names: string[] = [];
    try { names = fs.listFileSync(directory); }
    catch (e) {
      // 首次使用尚无目录是唯一“没有提交”情形。权限、IO 或文件类型错误必须阻止
      // 下一局 prepare，不能把无法读取待同步布局伪装为空队列而发出旧快照。
      if ((e as BusinessError).code === 13900002) return report;
      throw e as Error;
    }
    const pending: string[] = names.filter((name: string): boolean =>
      name.endsWith('.json') && validSnapshotId(name.substring(0, name.length - 5)));
    report.pending = pending.length;
    if (pending.length === 0) {
      GameLayoutJournal.cleanSettledBases(context, names);
      return report;
    }
    const store = getLayoutStore();
    await store.init(context);
    for (const name of pending.sort()) {
      if (store.isEditorActive() || testNapi.desktopGameProcessState(context.filesDir, 0) !== 0) {
        report.deferred = true;
        break;
      }
      const snapshotId: string = name.substring(0, name.length - 5);
      const path: string = directory + '/' + name;
      const record = JSON.parse(readJournalText(path)) as LayoutJournalRecord;
      requireOnlyKeys(record, ['schema', 'snapshotId', 'activityId', 'parentPid', 'gamePid', 'createdAt',
        'base', 'proposed', 'revision', 'submittedAt']);
      if (!record || record.schema !== 1 || record.snapshotId !== snapshotId) throw new Error('布局日志身份无效');
      const digest: string = evidenceFileDigestSync(path);
      const receiptPath: string = directory + '/' + snapshotId + '.applied.json';
      if (isAppliedReceipt(receiptPath, record, digest)) {
        // 已持久化的同字节 journal 即使清理重试，也不能再次覆盖后来 owner 的编辑。
        report.pending--;
        try { fs.unlinkSync(path); } catch (e) { /* 小回执继续保护幂等。 */ }
        continue;
      }
      const identity: LayoutJournalIdentity = readIdentity(context, snapshotId);
      if (!record || record.schema !== 1 || record.snapshotId !== snapshotId || record.activityId !== identity.activityId
        || record.parentPid !== identity.parentPid || record.gamePid !== identity.gamePid || !positiveInteger(record.gamePid)
        || record.gamePid === record.parentPid || record.createdAt !== identity.createdAt || !positiveInteger(record.revision)
        || !positiveInteger(record.submittedAt) || record.submittedAt < identity.createdAt || record.submittedAt > Date.now()
        || JSON.stringify(layoutOnly(record.base)) !== JSON.stringify(identity.base)) throw new Error('布局日志归属不匹配，已保留原文');
      const proposed: LaunchPreferenceSnapshot = layoutOnly(record.proposed);
      const result: GameLayoutImportResult = await store.importGamePreferences(identity.base, proposed, snapshotId, digest);
      if (result.deferred) { report.deferred = true; break; }
      const receipt: Record<string, Object> = { 'schema': 1, 'snapshotId': snapshotId,
        'activityId': record.activityId, 'gamePid': record.gamePid, 'digest': digest };
      writeJournal(receiptPath, JSON.stringify(receipt));
      report.imported++;
      report.conflicts.push(...result.conflicts);
      // 仅在 owner flush 与回执均确认后清除已处理 pending；删除失败保留供 digest 幂等重放。
      report.pending--;
      try { fs.unlinkSync(path); }
      catch (e) { AppLogger.warn('GameLayoutJournal', '已应用布局的提交文件暂未清理，回执将阻止重复导入', e, LOG_DOMAIN_LAUNCH); }
    }
    if (!report.deferred) GameLayoutJournal.cleanSettledBases(context, names);
    return report;
  }

  /**
   * 完成/未编辑会话的基线只是传输临时物，不应每局永久累计整套布局。
   * 仅在游戏锁仍空闲、无 pending、无待消费 ticket 时清理自身 UUID 文件；任何保存原文均不动。
   */
  private static cleanSettledBases(context: common.UIAbilityContext, names: string[]): void {
    if (testNapi.desktopGameProcessState(context.filesDir, 0) !== 0) return;
    const directory: string = journalDirectory(context);
    for (const name of names) {
      if (!name.endsWith('.base.json')) continue;
      const id: string = name.substring(0, name.length - 10);
      if (!validSnapshotId(id)) continue;
      try {
        if (fs.accessSync(directory + '/' + id + '.json')
          || fs.accessSync(context.filesDir + '/desktop-launch/' + id + '.json')) continue;
        const identity: LayoutJournalIdentity = readIdentity(context, id);
        // 尚未绑定 child 的失败准备保留五分钟，避免与正在发布 ticket 的准备事务争抢。
        if (identity.gamePid === 0 && Date.now() - identity.createdAt < 300000) continue;
        fs.unlinkSync(directory + '/' + name);
      } catch (e) { /* 清理不影响已经确认的导入，下一次安全空闲时再处理。 */ }
    }
  }
}

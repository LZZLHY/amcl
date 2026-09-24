/**
 * DownloadHistory.ets — Phase 5 (下载历史 LRU 20)
 *
 * 目标：保留最近 20 条下载任务记录（成功/失败/取消），故障排查 + 用户回溯。
 *
 * 当前状态：**Phase 5.2 — 纯函数 + LRU 类已实现**。
 * 待办：Preferences 持久化（DownloadHistory class wrapper） + UI 集成。
 *
 * 测试：entry/src/test/DownloadHistory.test.ets
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 5
 *
 * 创建日期：2026-05-05
 */

import { formatBytes } from './DownloadManager';
import { formatDurationMs } from 'commons';
import { ledgerList, ledgerManifest, LedgerState, LedgerManifest } from 'commons';
import { DownloadTask } from './DownloadTask';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppLogger } from 'commons';

const TAG = 'DownloadHistory';

// ============================================================
//  公开 interface
// ============================================================

/**
 * 活动类别常量（单一来源）。category 标识一条记录是哪种用户操作。
 * 旧记录无 category 字段 → 反序列化时按 loaderType 推断回填（见 deserializeRecord）。
 */
export class ActivityCategory {
  static readonly DOWNLOAD:        string = 'download';        // MC 版本下载（含加载器）
  static readonly MOD_INSTALL:     string = 'mod_install';     // 模组/资源包/光影/数据包安装
  static readonly LAUNCH:          string = 'launch';          // 启动游戏
  static readonly REPAIR:          string = 'repair';          // 版本修复
  static readonly JDK:             string = 'jdk';             // JDK 下载/删除
  static readonly ACCOUNT:         string = 'account';         // 账户添加/登录/删除
  static readonly MODPACK:         string = 'modpack';         // 整合包安装（创建一个新版本）
  // 扩展档（按需）
  static readonly VERSION_MANAGE:  string = 'version_manage';  // 版本删除/重命名
  static readonly RESOURCE_MANAGE: string = 'resource_manage'; // 模组启停/删除/更新、存档导入导出
  static readonly STORAGE:         string = 'storage';         // 存储位置迁移
  static readonly SKIN:            string = 'skin';            // 皮肤/披风切换
  static readonly VERIFY:          string = 'verify';          // 版本文件校验
}

/**
 * 活动状态常量。'success'/'failed'/'aborted' 为通用三态；'crashed' 为 launch 专用（异常退出）。
 */
export class ActivityStatus {
  static readonly SUCCESS: string = 'success';
  static readonly FAILED:  string = 'failed';
  static readonly ABORTED: string = 'aborted';
  static readonly CRASHED: string = 'crashed';
}

/**
 * 单条历史/活动记录。
 *
 * 三层架构演进（2026-06-15 活动时间线）：本接口从"下载历史"泛化为通用"活动记录"，
 * 向后兼容旧序列化（新增字段全部可选，旧数据缺失时按 loaderType 推断 category）。
 *
 * status 字段约束："success" / "failed" / "aborted" / "crashed"(launch)
 */
export interface DownloadHistoryRecord {
  /** 由账本合并的保留与关联信息，原记录字段仍向后兼容。 */
  pinned?: boolean;
  parentActivityId?: number;
  relation?: string;
  versionName: string;
  gameVersion: string;
  loaderType: string;
  loaderVersion?: string;
  startedAt: number;        // ms
  durationMs: number;
  /** true 表示缺少可信退出时间，durationMs 为 0，页面展示未知而非恢复间隔。 */
  durationEstimated?: boolean;
  totalBytes: number;
  fileCount: number;
  status: string;
  errorMessage?: string;

  // ---- 活动时间线扩展（全部可选，向后兼容）----
  category?: string;        // 见 ActivityCategory；缺省时按 loaderType 推断
  endedAt?: number;         // ms；缺省 = startedAt + durationMs（方案 A 时间窗取日志用）
  title?: string;           // 展示主标题；缺省回退 versionName
  subtitle?: string;        // 展示副标题（加载器+版本 / 资源类型 / 设备 等）
  errorKind?: string;       // McErrorClassifier errorKind（启动失败时）
  errorCategory?: string;   // McErrorClassifier category
  uploadedLogId?: string;   // 已上传到 web 返回的 log id；非空 = 已上传（去重 + UI 标记）

  // ---- 会话快照扩展（M3：错误 Sheet 可重入；全部可选，向后兼容）----
  // 背景：McErrorSheet 原本只能靠 AppStorage 的 lastMcSession 打开 —— 那是进程级、
  // 一次性的，用户关掉 Sheet 就再也回不去。要支持从活动记录重入，就得把「打开这个
  // Sheet 所需的一切」持久化下来。按设计文档 §4.1，不新引入一套存储，直接挂在
  // ActivityRecord 上跟着同一份 LRU 走。
  /** 该次会话的 .minecraft 根目录。重入时要用它重新定位日志（旧记录没有此字段）。 */
  mcDir?: string;
  /** 写记录时该次会话的日志落点。归档后会变，故读取时以 findSessionLog 反查为准。 */
  logPath?: string;
  /** 该次日志是否已被后续会话挤出保留窗口（读取时回填，不作为持久事实）。 */
  logArchived?: boolean;
  /** LogShare 分享 id（已分享过才有）。 */
  lsId?: string;
  /** LogShare 分享链接。 */
  lsUrl?: string;
  /** LogShare 删除凭据（撤回用）。 */
  lsToken?: string;
  /** 分享时刻（ms），算剩余有效期用。 */
  lsSharedAt?: number;
  /** AI 分析结果的落盘路径（filesDir/logs/ai/<sessionKey>.md）。正文可能很大，不入 LRU。 */
  aiPath?: string;
}

/** 活动记录类型别名（新代码统一用此名；与 DownloadHistoryRecord 同构，过渡期并存）。 */
export type ActivityRecord = DownloadHistoryRecord;

/** 旧活动记录已离开 LRU 时，从持久账本恢复可查看的入口。 */
function historyRecordFromLedger(m: LedgerManifest): DownloadHistoryRecord {
  const record: DownloadHistoryRecord = {
    versionName: m.gameVersionId || m.title, gameVersion: m.gameVersionId,
    loaderType: m.loaderType, loaderVersion: m.loaderVersion,
    startedAt: m.startedAt, endedAt: m.endedAt,
    durationMs: m.endTimeEstimated !== true && m.endedAt > 0 ? Math.max(0, m.endedAt - m.startedAt) : 0,
    durationEstimated: m.endTimeEstimated === true,
    pinned: m.pinned === true, parentActivityId: m.parentActivityId, relation: m.relation,
    totalBytes: 0, fileCount: m.files.length,
    status: m.state === LedgerState.RUNNING ? 'running' : m.state === LedgerState.INTERRUPTED ? 'interrupted'
      : m.state === LedgerState.SUCCESS ? ActivityStatus.SUCCESS
      : (m.state === LedgerState.CRASHED ? ActivityStatus.CRASHED
        : (m.state === LedgerState.FAILED ? ActivityStatus.FAILED : ActivityStatus.ABORTED)),
    category: m.category, title: m.title, mcDir: m.mcDir,
    errorMessage: m.outcomeSummary, errorKind: m.errorKind,
  };
  return record;
}

/**
 * 推断旧记录的 category（无 category 字段的历史数据）：mod-* 加载器 → 模组安装，其余 → 下载。
 */
export function inferCategory(loaderType: string): string {
  if (loaderType.indexOf('mod-') === 0) return ActivityCategory.MOD_INSTALL;
  return ActivityCategory.DOWNLOAD;
}

/**
 * 从一个终态 DownloadTask 构造历史记录（三层架构第4步：Index.recordHistory 纯转换下沉到 feature_core）。
 *
 * fileCount 估算：libraries / assets phase 取其 total（无则 current）；其它已完成阶段每阶段计 1。
 * totalBytes 由调用方传入跨 phase 监听到的最大 bytesTotal（一般 = assets 阶段总字节）。
 *
 * @param t            终态任务（DONE / ERROR / ABORTED）
 * @param startedAtMs  任务开始时间戳（ms）
 * @param maxBytesTotal 跨 phase 最大总字节
 * @param status       "success" / "failed" / "aborted"
 */
export function buildHistoryRecordFromTask(
  t: DownloadTask, startedAtMs: number, maxBytesTotal: number, status: string): DownloadHistoryRecord {
  let fileCount = 0;
  for (let d of t.phaseDetails) {
    if (d.phase === 'libraries' || d.phase === 'assets') {
      let n = d.total > 0 ? d.total : d.current;
      fileCount += n;
    } else if (d.status === 'done') {
      fileCount += 1;
    }
  }
  let loaderTypeStr: string = t.loaderType ? String(t.loaderType) : 'vanilla';
  let record: DownloadHistoryRecord = {
    versionName: t.versionName,
    gameVersion: t.gameVersion,
    loaderType: loaderTypeStr,
    startedAt: startedAtMs,
    durationMs: t.durationMs,
    totalBytes: maxBytesTotal,
    fileCount: fileCount,
    status: status,
    category: ActivityCategory.DOWNLOAD,
    endedAt: startedAtMs + t.durationMs,
    title: t.versionName,
  };
  if (t.loaderVersion && t.loaderVersion.length > 0) record.loaderVersion = t.loaderVersion;
  if (status !== 'success' && t.errorMessage && t.errorMessage.length > 0) {
    record.errorMessage = t.errorMessage;
  }
  return record;
}

// ============================================================
//  LRU 类
// ============================================================

/**
 * 简单 LRU：最新记录置于数组头部；超出容量从尾部驱逐。
 *
 * 不在线程安全考虑内（ArkTS 单线程主线程；后台异步均通过 ets event loop）。
 *
 * @param capacity 最大保留条数（>= 1）
 * @param initial 可选初始记录（顺序：[0]=最新；超容量时尾部被截断）
 */
export class DownloadHistoryLru {
  private capacity_: number;
  private items_: DownloadHistoryRecord[];

  constructor(capacity: number, initial?: DownloadHistoryRecord[]) {
    this.capacity_ = Math.max(1, capacity);
    if (initial !== undefined && initial.length > 0) {
      // 截断到容量
      this.items_ = initial.slice(0, this.capacity_);
    } else {
      this.items_ = [];
    }
  }

  /** 添加新记录（置顶）；超容量驱逐最老。 */
  add(record: DownloadHistoryRecord): void {
    this.items_.unshift(record);
    if (this.items_.length > this.capacity_) {
      this.items_ = this.items_.slice(0, this.capacity_);
    }
  }

  /**
   * 游戏退出恢复专用：同一活动主键替换结局，不改变普通下载 add 的追加语义。
   * 晚到崩溃可以更正正常结果，同时保留该局已有的分享凭据和 AI/日志快照字段。
   */
  upsertLaunchSession(record: DownloadHistoryRecord): void {
    if (record.category !== ActivityCategory.LAUNCH || !Number.isSafeInteger(record.startedAt)
      || record.startedAt <= 0) throw new Error('游戏会话恢复记录身份无效');
    const previous = this.items_.find((item: DownloadHistoryRecord): boolean =>
      item.startedAt === record.startedAt && item.category === ActivityCategory.LAUNCH);
    if (previous !== undefined) {
      if (record.uploadedLogId === undefined) record.uploadedLogId = previous.uploadedLogId;
      if (record.lsId === undefined) record.lsId = previous.lsId;
      if (record.lsUrl === undefined) record.lsUrl = previous.lsUrl;
      if (record.lsToken === undefined) record.lsToken = previous.lsToken;
      if (record.lsSharedAt === undefined) record.lsSharedAt = previous.lsSharedAt;
      if (record.aiPath === undefined) record.aiPath = previous.aiPath;
      if (record.logPath === undefined) record.logPath = previous.logPath;
      if (record.logArchived === undefined) record.logArchived = previous.logArchived;
      if (record.loaderVersion === undefined) record.loaderVersion = previous.loaderVersion;
      if (record.mcDir === undefined) record.mcDir = previous.mcDir;
    }
    this.items_ = this.items_.filter((item: DownloadHistoryRecord): boolean =>
      item.startedAt !== record.startedAt || item.category !== ActivityCategory.LAUNCH);
    this.add(record);
  }

  /** 返回当前所有记录的副本（最新 → 最老） */
  list(): DownloadHistoryRecord[] {
    return this.items_.slice();
  }

  /** 清空所有记录 */
  clear(): void {
    this.items_ = [];
  }

  /** 当前条数 */
  size(): number {
    return this.items_.length;
  }

  /** 按 startedAt 找到记录并标记已上传的 logId（返回是否命中）。 */
  markUploaded(startedAt: number, logId: string): boolean {
    for (let r of this.items_) {
      if (r.startedAt === startedAt) {
        r.uploadedLogId = logId;
        return true;
      }
    }
    return false;
  }

  /** 按 startedAt（= sessionKey）查一条记录；没有返回 null。 */
  findByStartedAt(startedAt: number): DownloadHistoryRecord | null {
    for (let r of this.items_) {
      if (r.startedAt === startedAt) return r;
    }
    return null;
  }

  /**
   * 把 LogShare 结果 / AI 落盘路径写回某条会话记录（M3）。
   *
   * 只覆盖显式传入的字段（空串视为「不改」），这样调用方可以只更新 AI 路径而不碰
   * 分享信息，反之亦然。返回是否命中。
   */
  patchSessionSnapshot(startedAt: number, lsId: string, lsUrl: string,
    lsToken: string, lsSharedAt: number, aiPath: string): boolean {
    for (let r of this.items_) {
      if (r.startedAt !== startedAt) continue;
      if (lsId.length > 0) r.lsId = lsId;
      if (lsUrl.length > 0) r.lsUrl = lsUrl;
      if (lsToken.length > 0) r.lsToken = lsToken;
      if (lsSharedAt > 0) r.lsSharedAt = lsSharedAt;
      if (aiPath.length > 0) r.aiPath = aiPath;
      return true;
    }
    return false;
  }

  /** 清掉某条会话记录的分享信息（撤回后调用）。返回是否命中。 */
  clearSessionShare(startedAt: number): boolean {
    for (let r of this.items_) {
      if (r.startedAt !== startedAt) continue;
      r.lsId = '';
      r.lsUrl = '';
      r.lsToken = '';
      r.lsSharedAt = 0;
      return true;
    }
    return false;
  }
}

// ============================================================
//  序列化（JSON 往返）
// ============================================================

/**
 * 单条记录 → JSON 字符串。
 * 用 JSON.stringify 直接（DownloadHistoryRecord 全部 JSON-friendly 类型）。
 */
export function serializeRecord(record: DownloadHistoryRecord): string {
  return JSON.stringify(record);
}

/**
 * 反序列化单条；损坏 JSON / 缺关键字段返回 null。
 *
 * 必填字段：versionName / gameVersion / loaderType / startedAt / durationMs /
 *           totalBytes / fileCount / status
 */
export function deserializeRecord(json: string): DownloadHistoryRecord | null {
  if (json.length === 0) return null;
  let obj: Record<string, Object> | null = null;
  try {
    let parsed = JSON.parse(json) as Object;
    if (typeof parsed !== 'object' || parsed === null) return null;
    obj = parsed as Record<string, Object>;
  } catch (e) {
    return null;
  }

  // 校验必填字段类型
  let versionName = obj['versionName'];
  let gameVersion = obj['gameVersion'];
  let loaderType = obj['loaderType'];
  let startedAt = obj['startedAt'];
  let durationMs = obj['durationMs'];
  let totalBytes = obj['totalBytes'];
  let fileCount = obj['fileCount'];
  let status = obj['status'];
  if (typeof versionName !== 'string') return null;
  if (typeof gameVersion !== 'string') return null;
  if (typeof loaderType !== 'string') return null;
  if (typeof startedAt !== 'number') return null;
  if (typeof durationMs !== 'number') return null;
  if (typeof totalBytes !== 'number') return null;
  if (typeof fileCount !== 'number') return null;
  if (typeof status !== 'string') return null;

  let result: DownloadHistoryRecord = {
    versionName: versionName as string,
    gameVersion: gameVersion as string,
    loaderType: loaderType as string,
    startedAt: startedAt as number,
    durationMs: durationMs as number,
    totalBytes: totalBytes as number,
    fileCount: fileCount as number,
    status: status as string,
  };

  // 可选字段
  result.durationEstimated = obj['durationEstimated'] === true;
  let lv = obj['loaderVersion'];
  if (typeof lv === 'string') result.loaderVersion = lv as string;
  let em = obj['errorMessage'];
  if (typeof em === 'string') result.errorMessage = em as string;

  // ---- 活动时间线扩展字段（向后兼容：缺失则推断/留空）----
  let cat = obj['category'];
  result.category = (typeof cat === 'string' && (cat as string).length > 0)
    ? cat as string
    : inferCategory(result.loaderType);   // 旧记录无 category → 按 loaderType 推断
  let ea = obj['endedAt'];
  result.endedAt = (typeof ea === 'number') ? ea as number : (result.startedAt + result.durationMs);
  let ti = obj['title'];
  if (typeof ti === 'string' && (ti as string).length > 0) result.title = ti as string;
  let st = obj['subtitle'];
  if (typeof st === 'string') result.subtitle = st as string;
  let ek = obj['errorKind'];
  if (typeof ek === 'string') result.errorKind = ek as string;
  let ec = obj['errorCategory'];
  if (typeof ec === 'string') result.errorCategory = ec as string;
  let ul = obj['uploadedLogId'];
  if (typeof ul === 'string') result.uploadedLogId = ul as string;

  // ---- 会话快照扩展字段（M3）----
  let md = obj['mcDir'];
  if (typeof md === 'string') result.mcDir = md as string;
  let lp = obj['logPath'];
  if (typeof lp === 'string') result.logPath = lp as string;
  let la = obj['logArchived'];
  if (typeof la === 'boolean') result.logArchived = la as boolean;
  let lsi = obj['lsId'];
  if (typeof lsi === 'string') result.lsId = lsi as string;
  let lsu = obj['lsUrl'];
  if (typeof lsu === 'string') result.lsUrl = lsu as string;
  let lst = obj['lsToken'];
  if (typeof lst === 'string') result.lsToken = lst as string;
  let lsa = obj['lsSharedAt'];
  if (typeof lsa === 'number') result.lsSharedAt = lsa as number;
  let ap = obj['aiPath'];
  if (typeof ap === 'string') result.aiPath = ap as string;

  return result;
}

/** 数组序列化 */
export function serializeRecords(records: DownloadHistoryRecord[]): string {
  return JSON.stringify(records);
}

/**
 * 数组反序列化：损坏 JSON 返回空数组（容错）；
 * 数组中非法元素被跳过。
 */
export function deserializeRecords(json: string): DownloadHistoryRecord[] {
  if (json.length === 0) return [];
  let arr: Object[] | null = null;
  try {
    let parsed = JSON.parse(json) as Object;
    if (!Array.isArray(parsed)) return [];
    arr = parsed as Object[];
  } catch (e) {
    return [];
  }

  let result: DownloadHistoryRecord[] = [];
  for (let item of arr) {
    let one = deserializeRecord(JSON.stringify(item));
    if (one !== null) result.push(one);
  }
  return result;
}

// ============================================================
//  展示格式化
// ============================================================

/**
 * 格式化记录为人类可读的单行摘要。
 * 包含版本名、状态、字节数、耗时；失败时附错误信息。
 */
export function formatRecordSummary(record: DownloadHistoryRecord): string {
  let statusZh: string;
  if (record.status === 'success') {
    statusZh = '成功';
  } else if (record.status === 'failed') {
    statusZh = '失败';
  } else if (record.status === 'aborted') {
    statusZh = '取消';
  } else {
    statusZh = record.status;
  }

  let loaderTag = '';
  if (record.loaderType === 'forge') {
    loaderTag = ' Forge' + (record.loaderVersion !== undefined ? ' ' + record.loaderVersion : '');
  } else if (record.loaderType === 'fabric') {
    loaderTag = ' Fabric' + (record.loaderVersion !== undefined ? ' ' + record.loaderVersion : '');
  }

  let bytesStr = formatBytes(record.totalBytes);
  let durStr = formatDurationMs(record.durationMs);

  let summary = record.versionName + loaderTag + ' [' + statusZh + ']'
    + ' ' + bytesStr + ' / ' + durStr;
  if (record.status !== 'success' && record.errorMessage !== undefined && record.errorMessage.length > 0) {
    summary += ' — ' + record.errorMessage;
  }
  return summary;
}

// ============================================================
//  Phase 5.3 持久化层：Preferences-backed singleton store
// ============================================================

const PREF_NAME = 'download_history';
const PREF_KEY_RECORDS = 'records';
/** LRU 容量上限（活动时间线泛化后从 20 提到 50，容纳多类型操作） */
export const HISTORY_CAPACITY = 50;

/**
 * 持久化版下载历史。LayoutStore 同款模式：
 *   - `init(context)` 只允许调一次，幂等返回相同 promise
 *   - `waitReady()` 让消费者侧 await 完成
 *   - `add` / `clear` 同步更新内存 LRU + 异步刷盘
 *
 * 单例：用全局工厂 `getDownloadHistoryStore()` 获取实例（不在 module scope 直接 new
 * 是为避免 ArkTS 严格模式下静态构造时机问题）。
 */
export class DownloadHistoryStore {
  private filesDir_: string = '';
  private pref_: preferences.Preferences | null = null;
  private lru_: DownloadHistoryLru = new DownloadHistoryLru(HISTORY_CAPACITY);
  private ready_: boolean = false;
  private initPromise_: Promise<void> | null = null;
  /** 串行提交，避免多个活动的异步保存互相覆盖；失败不阻断后续重试。 */
  private writeQueue_: Promise<void> = Promise.resolve();

  isReady(): boolean { return this.ready_; }

  /** 首次调用绑定 context + 加载 Preferences；后续调用复用 promise */
  async init(context: common.Context): Promise<void> {
    if (this.ready_) return;
    if (this.initPromise_ !== null) return this.initPromise_;
    this.initPromise_ = this.doInit_(context);
    try { await this.initPromise_; }
    finally { this.initPromise_ = null; }
  }

  private async doInit_(context: common.Context): Promise<void> {
    this.filesDir_ = context.filesDir;
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      let json = await store.get(PREF_KEY_RECORDS, '') as string;
      // 空的未初始化存储是正常情况；格式损坏不可降级成“没有活动”。原件留给重试。
      if (json.length > 0 && !Array.isArray(JSON.parse(json) as Object[])) throw new Error('历史记录格式损坏');
      let records = deserializeRecords(json);
      if (json.length > 0 && records.length !== (JSON.parse(json) as Object[]).length) throw new Error('存在不可读取的历史记录');
      this.lru_ = new DownloadHistoryLru(HISTORY_CAPACITY, records);
      this.pref_ = store;
      this.ready_ = true;
      AppLogger.info(TAG, 'DownloadHistoryStore loaded: ' + records.length + ' records');
    } catch (e) {
      AppLogger.warn(TAG, 'DownloadHistoryStore init failed: ' + (e as Error).message);
      // 不清空旧视图、不发布 ready；上层能够显示错误，再次 init 会重新读取。
      throw new Error('活动历史读取失败：' + (e as Error).message);
    }
  }

  async waitReady(): Promise<void> {
    if (this.initPromise_ !== null) await this.initPromise_;
    if (!this.ready_) throw new Error('活动历史尚未读取成功，请重试');
  }

  /**
   * 添加普通活动。提交到独立草稿，持久化成功后才替换当前视图；失败传递给调用方。
   * 调用前不必 await 已开始的 init，事务会等待读取完成。
   */
  async add(record: DownloadHistoryRecord): Promise<void> {
    const snapshot = deserializeRecord(serializeRecord(record));
    if (snapshot === null) throw new Error('活动记录无效');
    await this.commit_((draft: DownloadHistoryLru): void => { draft.add(snapshot); });
  }

  /**
   * 游戏恢复专用幂等写入。只有 Preferences put/flush 均成功才返回，失败交给上层重试；
   * 不复用会吞写盘错误的普通 add，因此回执不会冒充历史已持久化，原生原文始终保留。
   */
  async upsertLaunchSession(record: DownloadHistoryRecord): Promise<void> {
    const snapshot = deserializeRecord(serializeRecord(record));
    if (snapshot === null) throw new Error('游戏活动记录无效');
    await this.commit_((draft: DownloadHistoryLru): void => { draft.upsertLaunchSession(snapshot); });
  }

  /** 清空所有记录（同步内存 + 异步刷盘） */
  async clear(): Promise<void> {
    await this.commit_((draft: DownloadHistoryLru): void => { draft.clear(); });
  }

  /** 当前所有记录的副本（最新 → 最老） */
  list(): DownloadHistoryRecord[] {
    const records = this.lru_.list();
    // 账本是日志入口的事实源，不能被通用活动 LRU 挤掉。
    if (this.filesDir_.length > 0) {
      for (const entry of ledgerList(this.filesDir_)) {
        const m = ledgerManifest(this.filesDir_, entry.activityId);
        if (m === null) continue;
        const index: number = records.findIndex((record: DownloadHistoryRecord): boolean => record.startedAt === entry.activityId);
        if (index >= 0) records[index] = this.withLedgerOutcome_(records[index], m);
        else records.push(historyRecordFromLedger(m));
      }
    }
    return records.sort((a: DownloadHistoryRecord, b: DownloadHistoryRecord): number => b.startedAt - a.startedAt);
  }

  size(): number { return this.lru_.size(); }

  /** 标记某条记录（按 startedAt 定位）已上传 logId，并刷盘。 */
  async markUploaded(startedAt: number, logId: string): Promise<void> {
    await this.commit_((draft: DownloadHistoryLru): void => { draft.markUploaded(startedAt, logId); });
  }

  /** 按 sessionKey（= startedAt）取一条记录（M3：错误 Sheet 重入的入口）。 */
  findByStartedAt(startedAt: number): DownloadHistoryRecord | null {
    const record = this.lru_.findByStartedAt(startedAt);
    if (this.filesDir_.length === 0) return record;
    const manifest = ledgerManifest(this.filesDir_, startedAt);
    if (manifest === null) return record;
    return record === null ? historyRecordFromLedger(manifest) : this.withLedgerOutcome_(record, manifest);
  }

  /**
   * 账本是结局事实源，迟到平台事件必须立即反映到所有读取入口。
   * 复制缓存记录后只覆盖终态字段，保留分享凭据、AI 路径和下载统计，且不污染待保存的 LRU。
   * 运行中账本没有最终结局，不能把已有历史记录降为中断。
   */
  private withLedgerOutcome_(record: DownloadHistoryRecord, manifest: LedgerManifest): DownloadHistoryRecord {
    const copy = deserializeRecord(serializeRecord(record));
    if (copy === null) return historyRecordFromLedger(manifest);
    copy.pinned = manifest.pinned === true; copy.parentActivityId = manifest.parentActivityId; copy.relation = manifest.relation;
    if (manifest.state === LedgerState.RUNNING) return copy;
    const current = historyRecordFromLedger(manifest);
    copy.status = current.status;
    copy.endedAt = current.endedAt;
    copy.durationMs = current.durationMs;
    copy.durationEstimated = current.durationEstimated;
    copy.errorMessage = current.errorMessage;
    copy.errorKind = current.errorKind;
    return copy;
  }

  /** 把 LogShare 结果 / AI 落盘路径写回会话记录并刷盘（M3）。 */
  async patchSessionSnapshot(startedAt: number, lsId: string, lsUrl: string,
    lsToken: string, lsSharedAt: number, aiPath: string): Promise<void> {
    await this.commit_((draft: DownloadHistoryLru): void => {
      draft.patchSessionSnapshot(startedAt, lsId, lsUrl, lsToken, lsSharedAt, aiPath);
    });
  }

  /** 清掉会话记录里的分享信息并刷盘（撤回后调用）。 */
  async clearSessionShare(startedAt: number): Promise<void> {
    await this.commit_((draft: DownloadHistoryLru): void => { draft.clearSessionShare(startedAt); });
  }

  /**
   * 同一队列覆盖新增、退出恢复、分享回写与清空。深拷贝防止草稿修改到已发布记录。
   * Preferences.put 可能先更新内部缓存，flush 失败时尽力恢复旧缓存；磁盘结果不明仍抛错，
   * 绝不把恢复缓存解释成保存成功。调用方可用同一活动身份重试。
   */
  private async commit_(change: (draft: DownloadHistoryLru) => void): Promise<void> {
    const operation: Promise<void> = this.writeQueue_.then(async (): Promise<void> => {
      if (!this.ready_) await this.waitReady();
      const store = this.pref_;
      if (store === null) throw new Error('活动历史存储不可用');
      const previous: string = serializeRecords(this.lru_.list());
      const draft: DownloadHistoryLru = new DownloadHistoryLru(HISTORY_CAPACITY, deserializeRecords(previous));
      change(draft);
      const next: string = serializeRecords(draft.list());
      if (next === previous) return;
      try { await store.put(PREF_KEY_RECORDS, next); await store.flush(); }
      catch (e) {
        try { await store.put(PREF_KEY_RECORDS, previous); } catch (ignored) { /* 保留原始保存失败。 */ }
        throw new Error('活动历史保存失败：' + (e as Error).message);
      }
      this.lru_ = draft;
    });
    this.writeQueue_ = operation.catch((): void => {});
    await operation;
  }
}

// 全局单例
let storeInstance_: DownloadHistoryStore | null = null;

export function getDownloadHistoryStore(): DownloadHistoryStore {
  if (storeInstance_ === null) {
    storeInstance_ = new DownloadHistoryStore();
  }
  return storeInstance_;
}

/**
 * AppMessageStore.ets — 应用内消息中心的数据层（消息中心与诊断体验 · M4）
 *
 * 为什么需要它：LogShare 的 AI 分析实测要半分钟。用户很可能等不及就切走 / 关掉
 * Sheet，回来却不知道分析已经好了。M3 已经让「回到 Sheet」这条路走得通（活动记录
 * 「查看详情」），但那要用户自己想起来去翻。消息中心补的是**主动告知**这一环，
 * 也是「即使用户拒绝系统通知授权也一定收得到」的兜底通道 —— 见 §5.5 的硬要求。
 *
 * 设计要点：
 *   - `kind` 与 `action.type` 从一开始就是多值 enum，后面加「下载完成」「更新可用」
 *     「JDK 安装完成」不用改结构。
 *   - 容量 50，**超出时优先淘汰已读**，未读永远保留 —— 未读代表用户还没看到的信息，
 *     被静默丢掉等于这套机制失效。
 *   - 持久化用 preferences（store `amcl_messages`），与 LogShareClient 同款写法。
 *
 * 关联：docs/guides/message-center-and-diagnosis-ux.md §5.1、§5.2
 * 创建日期：2026-07-30
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppLogger, LOG_DOMAIN_UI } from 'commons';

const TAG = 'AppMessageStore';
const PREF_STORE = 'amcl_messages';
const PREF_KEY_LIST = 'list';
/** 容量上限。超出优先淘汰最旧的**已读**消息。 */
export const APP_MESSAGE_CAPACITY: number = 50;
/** 铃铛角标显示上限，超过显示 '99+'。 */
export const APP_MESSAGE_BADGE_MAX: number = 99;

/** 消息类别。数值持久化，**只能追加、不能重排**。 */
export enum AppMessageKind {
  /** LogShare AI 分析完成。 */
  AI_ANALYSIS_DONE = 0,
  /** AI 分析失败。 */
  AI_ANALYSIS_FAILED = 1,
  /** 预留：下载完成。 */
  DOWNLOAD_DONE = 2,
  /** 预留：有可用更新。 */
  UPDATE_AVAILABLE = 3,
  /** 通用信息。 */
  INFO = 4,
}

/** 点击消息后要做什么。数值持久化，只能追加。 */
export enum AppMessageActionType {
  NONE = 0,
  /** 打开某次会话的错误 Sheet，payload = sessionKey。 */
  OPEN_ERROR_SHEET = 1,
  /** 打开某个页面，payload = 路由 url。 */
  OPEN_PAGE = 2,
}

/** 消息的点击行为。 */
export interface AppMessageAction {
  type: AppMessageActionType;
  /** 目标标识（sessionKey 字符串 / 路由 url）。 */
  payload: string;
}

/** 一条应用内消息。 */
export interface AppMessage {
  /** 稳定唯一 id（如 'ai-' + sessionKey）。同 id 视为同一条，重复投递会覆盖。 */
  id: string;
  kind: AppMessageKind;
  title: string;
  body: string;
  createdAt: number;
  read: boolean;
  action: AppMessageAction;
}

/** 便捷构造：AI 分析完成。 */
export function buildAiDoneMessage(sessionKey: number, versionLabel: string): AppMessage {
  let act: AppMessageAction = {
    type: AppMessageActionType.OPEN_ERROR_SHEET,
    payload: sessionKey.toString(),
  };
  let m: AppMessage = {
    id: 'ai-' + sessionKey,
    kind: AppMessageKind.AI_ANALYSIS_DONE,
    title: 'AI 分析完成',
    body: (versionLabel.length > 0 ? versionLabel : '上次会话') + ' 的崩溃分析已就绪，点击查看',
    createdAt: Date.now(),
    read: false,
    action: act,
  };
  return m;
}

/** 便捷构造：AI 分析失败。 */
export function buildAiFailedMessage(sessionKey: number, versionLabel: string,
  reason: string): AppMessage {
  let act: AppMessageAction = {
    type: AppMessageActionType.OPEN_ERROR_SHEET,
    payload: sessionKey.toString(),
  };
  let m: AppMessage = {
    id: 'ai-' + sessionKey,
    kind: AppMessageKind.AI_ANALYSIS_FAILED,
    title: 'AI 分析失败',
    body: (versionLabel.length > 0 ? versionLabel : '上次会话') + '：'
      + (reason.length > 0 ? reason : '未知原因') + '。点击可重试',
    createdAt: Date.now(),
    read: false,
    action: act,
  };
  return m;
}

// ============================================================================
//  序列化
//
//  逐字段校验类型，损坏的条目跳过而不是整份丢弃 —— 与 DownloadHistory 的
//  deserializeRecords 同一取向：宁可少一条，也不要因为一条脏数据清空用户所有消息。
// ============================================================================

function deserializeOne(item: Object): AppMessage | null {
  if (typeof item !== 'object' || item === null) return null;
  let obj = item as Record<string, Object>;
  let id = obj['id'];
  let kind = obj['kind'];
  let title = obj['title'];
  let createdAt = obj['createdAt'];
  if (typeof id !== 'string' || (id as string).length === 0) return null;
  if (typeof kind !== 'number') return null;
  if (typeof title !== 'string') return null;
  if (typeof createdAt !== 'number') return null;

  let body = obj['body'];
  let read = obj['read'];
  let actType = AppMessageActionType.NONE;
  let actPayload = '';
  let act = obj['action'];
  if (typeof act === 'object' && act !== null) {
    let a = act as Record<string, Object>;
    let t = a['type'];
    let p = a['payload'];
    if (typeof t === 'number') actType = t as number as AppMessageActionType;
    if (typeof p === 'string') actPayload = p as string;
  }
  let action: AppMessageAction = { type: actType, payload: actPayload };
  let m: AppMessage = {
    id: id as string,
    kind: kind as number as AppMessageKind,
    title: title as string,
    body: (typeof body === 'string') ? body as string : '',
    createdAt: createdAt as number,
    read: (typeof read === 'boolean') ? read as boolean : false,
    action: action,
  };
  return m;
}

export function deserializeMessages(json: string): AppMessage[] {
  if (json.length === 0) return [];
  let arr: Object[] | null = null;
  try {
    let parsed = JSON.parse(json) as Object;
    if (!Array.isArray(parsed)) return [];
    arr = parsed as Object[];
  } catch (e) {
    return [];
  }
  let out: AppMessage[] = [];
  for (let item of arr) {
    let one = deserializeOne(item);
    if (one !== null) out.push(one);
  }
  return out;
}

/**
 * 容量裁剪：**未读全保留，只淘汰最旧的已读**。
 *
 * 朴素做法是「按时间排序砍尾巴」，但那会把未读一起砍掉。未读代表用户还没看到的
 * 信息，静默丢掉等于这套告知机制白做，所以宁可让已读少留几条。
 * 极端情况（50 条全是未读）就允许超出一点，下次有已读了再回落。
 */
export function trimMessages(list: AppMessage[], capacity: number): AppMessage[] {
  if (list.length <= capacity) return list;
  let unread: AppMessage[] = [];
  let read: AppMessage[] = [];
  for (let m of list) {
    if (m.read) read.push(m); else unread.push(m);
  }
  // list 已是「最新在前」，read 保持同序，从尾部（最旧）开始砍
  let allowedRead = capacity - unread.length;
  if (allowedRead < 0) allowedRead = 0;
  let keptRead = read.slice(0, allowedRead);
  // 合并后按时间重排，保持「最新在前」
  let merged: AppMessage[] = [];
  for (let m of unread) merged.push(m);
  for (let m of keptRead) merged.push(m);
  merged.sort((a: AppMessage, b: AppMessage): number => b.createdAt - a.createdAt);
  return merged;
}

/** 未读数（供铃铛角标）。 */
export function countUnread(list: AppMessage[]): number {
  let n = 0;
  for (let m of list) { if (!m.read) n++; }
  return n;
}

/** 角标文案：0 时返回空串，超上限返回 '99+'。 */
export function formatBadge(unread: number): string {
  if (unread <= 0) return '';
  if (unread > APP_MESSAGE_BADGE_MAX) return APP_MESSAGE_BADGE_MAX + '+';
  return unread.toString();
}

// ============================================================================
//  持久化存储
// ============================================================================

/**
 * 消息中心存储。单例，用 `getAppMessageStore()` 取。
 *
 * 写入串行保存后再发布内存态；存储失败可重试，不能将读取失败视为空列表。
 */
export class AppMessageStore {
  private pref_: preferences.Preferences | null = null;
  private list_: AppMessage[] = [];
  private ready_: boolean = false;
  private initPromise_: Promise<void> | null = null;
  private writeQueue_: Promise<void> = Promise.resolve();

  isReady(): boolean { return this.ready_; }

  /** 成功初始化可复用；失败移除缓存 Promise，使页面的“重试”能再次读取持久存储。 */
  async init(ctx: common.Context): Promise<void> {
    if (this.initPromise_ !== null) return this.initPromise_;
    this.initPromise_ = this.doInit_(ctx);
    try { await this.initPromise_; }
    catch (e) { this.initPromise_ = null; throw e as Error; }
  }

  private async doInit_(ctx: common.Context): Promise<void> {
    try {
      this.pref_ = await preferences.getPreferences(ctx, PREF_STORE);
      let raw = await this.pref_.get(PREF_KEY_LIST, '') as string;
      if (raw.length > 0 && !Array.isArray(JSON.parse(raw))) throw new Error('消息数据格式无效');
      this.list_ = deserializeMessages(raw);
      this.list_.sort((a: AppMessage, b: AppMessage): number => b.createdAt - a.createdAt);
      AppLogger.info(TAG, 'loaded ' + this.list_.length + ' messages, unread='
        + countUnread(this.list_), LOG_DOMAIN_UI);
    } catch (e) {
      AppLogger.warn(TAG, 'init failed', e, LOG_DOMAIN_UI);
      this.pref_ = null;
      this.ready_ = false;
      throw new Error('消息存储读取失败：' + (e as Error).message);
    }
    this.ready_ = true;
  }

  async waitReady(): Promise<void> {
    if (this.initPromise_ !== null) await this.initPromise_;
    if (!this.ready_) throw new Error('消息存储未就绪，请重试加载');
  }

  /** 全部消息（最新在前）。 */
  list(): AppMessage[] { return this.list_.slice(0, this.list_.length); }

  unreadCount(): number { return countUnread(this.list_); }

  size(): number { return this.list_.length; }

  /**
   * 投递一条消息。同 id 覆盖（AI 分析对同一 sessionKey 重试时不该堆两条）。
   * 覆盖时重置为未读 —— 内容变了就该重新提醒。
   */
  async post(msg: AppMessage): Promise<void> {
    await this.change_((list: AppMessage[]): AppMessage[] => {
      const next: AppMessage[] = [msg];
      for (const item of list) { if (item.id !== msg.id) next.push(item); }
      next.sort((a: AppMessage, b: AppMessage): number => b.createdAt - a.createdAt);
      return trimMessages(next, APP_MESSAGE_CAPACITY);
    });
  }

  /** 标记单条已读。返回是否有变化。 */
  async markRead(id: string): Promise<boolean> {
    let changed = false;
    await this.change_((list: AppMessage[]): AppMessage[] => {
      for (const m of list) { if (m.id === id && !m.read) { m.read = true; changed = true; } }
      return list;
    });
    return changed;
  }

  /** 全部已读。返回被标记的条数。 */
  async markAllRead(): Promise<number> {
    let n = 0;
    await this.change_((list: AppMessage[]): AppMessage[] => {
      for (const m of list) { if (!m.read) { m.read = true; n++; } }
      return list;
    });
    return n;
  }

  /** 删除单条。 */
  async remove(id: string): Promise<void> {
    await this.change_((list: AppMessage[]): AppMessage[] => list.filter((m: AppMessage): boolean => m.id !== id));
  }

  /** 清空。 */
  async clear(): Promise<void> {
    await this.change_((): AppMessage[] => []);
  }

  /** 串行执行变更并保存：先深拷贝当前消息，避免已读字段提前污染 UI；
   * put/flush 完成后才发布列表。失败保留旧内存并恢复 Preferences 缓存，
   * 向调用方抛错；队列自身吸收拒绝，使下一次用户重试仍可继续。
   */
  private async change_(change: (list: AppMessage[]) => AppMessage[]): Promise<void> {
    const pending: Promise<void> = this.writeQueue_.then(async (): Promise<void> => {
      await this.waitReady();
      const p = this.pref_;
      if (p === null) throw new Error('消息存储未就绪');
      const before: string = JSON.stringify(this.list_);
      const next: AppMessage[] = change(deserializeMessages(before));
      try {
        await p.put(PREF_KEY_LIST, JSON.stringify(next));
        await p.flush();
        this.list_ = next;
      } catch (e) {
        try { await p.put(PREF_KEY_LIST, before); } catch (rollback) { AppLogger.warn(TAG, 'restore cache failed', rollback, LOG_DOMAIN_UI); }
        AppLogger.warn(TAG, 'save failed', e, LOG_DOMAIN_UI);
        throw new Error('消息保存失败，请重试：' + (e as Error).message);
      }
    });
    this.writeQueue_ = pending.catch((): void => {});
    await pending;
  }
}

let instance_: AppMessageStore | null = null;

export function getAppMessageStore(): AppMessageStore {
  if (instance_ === null) instance_ = new AppMessageStore();
  return instance_;
}

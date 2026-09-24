/**
 * AppNotifier.ets — 消息投递与通知分流（消息中心与诊断体验 · M5）
 *
 * 一条消息产生时要走哪条路，取决于用户当下在哪（§5.5）：
 *
 *   | 用户状态          | 判定依据                  | 通知方式         |
 *   | 在应用内（前台）   | appInForeground = true    | 自定义灵动弹窗   |
 *   | 已切后台、进程存活 | appInForeground = false   | 系统通知         |
 *   | 进程已退出        | 代码根本没在跑            | 不发，留未读     |
 *
 * **硬要求**：无论走哪条路，消息一定先落进消息中心。用户拒绝通知授权也必须收得到 ——
 * 消息中心是唯一可靠通道，系统通知与灵动弹窗都只是「顺手提醒」。这条不能因为
 * 「没授权就干脆不记」而妥协，否则整套告知机制在拒绝授权的用户身上完全失效。
 *
 * 授权时机（§5.5）：**不在启动时弹**。只在用户首次触发一个「会产生异步通知」的动作
 * （即点「AI 智能分析」的那一刻）才请求，此时弹授权框用户才知道是为什么。
 *
 * 关联：docs/guides/message-center-and-diagnosis-ux.md §5.5
 * 创建日期：2026-07-30
 */

import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common, Want } from '@kit.AbilityKit';
import { AppLogger, LOG_DOMAIN_UI } from 'commons';
import {
  AppMessage, AppMessageActionType, getAppMessageStore,
} from './AppMessageStore';

const TAG = 'AppNotifier';

/** 系统通知 id 基数。用固定 id 让同一条消息重复投递时替换而不是堆叠。 */
const NOTIFY_ID_BASE = 0x4143;   // 'AC'

/** AppStorage key：Ability 是否在前台（由 EntryAbility 的 onForeground/onBackground 写）。 */
export const KEY_APP_IN_FOREGROUND = 'appInForeground';
/** AppStorage key：待展示的灵动弹窗消息 id（Index 消费）。 */
export const KEY_PENDING_TOAST = 'amcl_pending_toast_msg_id';
/** AppStorage key：未读数（铃铛角标读它，避免各处自己算）。 */
export const KEY_UNREAD_COUNT = 'amcl_message_unread';

/** 是否已请求过通知授权（进程级，避免同一次运行里反复请求）。 */
let permissionAsked_ = false;
/** 上次已知的授权结果。 */
let permissionGranted_ = false;

/**
 * 请求通知授权。
 *
 * `requestEnableNotification` 首次调用会弹系统框，之后不再弹（系统行为，不需要我们
 * 自己做「只弹一次」的记账，但仍然用进程级标志避免无谓的重复调用）。
 * **不需要在 module.json5 声明权限。**
 *
 * @returns 是否已获授权。拒绝时返回 false，但**调用方不得因此跳过消息中心投递**。
 */
export async function ensureNotifyPermission(ctx: common.UIAbilityContext): Promise<boolean> {
  try {
    // 已启用就不必再问
    if (notificationManager.isNotificationEnabledSync()) {
      permissionGranted_ = true;
      return true;
    }
  } catch (e) {
    // 老设备 / 接口不可用：按未授权处理，不阻断
  }
  if (permissionAsked_) return permissionGranted_;
  permissionAsked_ = true;
  try {
    await notificationManager.requestEnableNotification(ctx);
    permissionGranted_ = true;
    AppLogger.info(TAG, 'notification permission granted', LOG_DOMAIN_UI);
  } catch (e) {
    permissionGranted_ = false;
    AppLogger.info(TAG, 'notification permission denied (messages still go to message center)',
      LOG_DOMAIN_UI);
  }
  return permissionGranted_;
}

/** 当前 Ability 是否在前台。 */
function inForeground(): boolean {
  let v = AppStorage.get<boolean>(KEY_APP_IN_FOREGROUND);
  // 读不到时按「前台」处理：宁可弹应用内浮层（用户看得见就看见了），
  // 也不要在用户明明在用的时候推一条系统通知。
  return v === undefined ? true : v;
}

/** 把消息 id 稳定映射成通知 id（同 id 重复投递会替换旧通知）。 */
function notifyIdOf(msgId: string): number {
  let h = 0;
  for (let i = 0; i < msgId.length; i++) {
    h = ((h << 5) - h + msgId.charCodeAt(i)) | 0;
  }
  return NOTIFY_ID_BASE + Math.abs(h % 100000);
}

/**
 * 构造点击通知回到应用的 WantAgent。
 *
 * 携带 `sessionKey` 参数，`EntryAbility.onNewWant` 解析后写进 AppStorage，
 * Index 的 @Watch 消费并打开对应会话的错误 Sheet。
 */
async function buildTapAgent(ctx: common.UIAbilityContext,
  msg: AppMessage): Promise<WantAgent | null> {
  try {
    let want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: ctx.abilityInfo.name,
      parameters: {
        'amclMessageId': msg.id,
        'amclSessionKey': msg.action.type === AppMessageActionType.OPEN_ERROR_SHEET
          ? msg.action.payload : '',
      },
    };
    let info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: notifyIdOf(msg.id),
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    return await wantAgent.getWantAgent(info);
  } catch (e) {
    AppLogger.warn(TAG, 'buildTapAgent failed', e, LOG_DOMAIN_UI);
    return null;
  }
}

/** 发一条系统通知（后台场景）。失败只警告 —— 消息已经在消息中心了。 */
async function publishSystemNotification(ctx: common.UIAbilityContext,
  msg: AppMessage): Promise<void> {
  let granted = await ensureNotifyPermission(ctx);
  if (!granted) {
    AppLogger.info(TAG, 'skip system notification (no permission), message kept unread',
      LOG_DOMAIN_UI);
    return;
  }
  try {
    let agent = await buildTapAgent(ctx, msg);
    let request: notificationManager.NotificationRequest = {
      id: notifyIdOf(msg.id),
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      // 点击后自动移除通知，否则用户回到应用还得手动划掉
      tapDismissed: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: msg.title,
          text: msg.body,
        },
      },
    };
    if (agent !== null) request.wantAgent = agent;
    await notificationManager.publish(request);
    AppLogger.info(TAG, 'system notification published: ' + msg.id, LOG_DOMAIN_UI);
  } catch (e) {
    AppLogger.warn(TAG, 'publish system notification failed', e, LOG_DOMAIN_UI);
  }
}

/**
 * 投递一条消息：**先入消息中心**，再按前后台决定顺手怎么提醒。
 *
 * 顺序很关键 —— 先落存储，这样即使后面通知/弹窗环节整个失败，用户打开铃铛仍然
 * 能看到这条消息。
 */
export async function postAppMessage(ctx: common.UIAbilityContext,
  msg: AppMessage): Promise<void> {
  let store = getAppMessageStore();
  try {
    await store.init(ctx);
    await store.post(msg);
  } catch (e) {
    AppLogger.warn(TAG, 'post to message center failed', e, LOG_DOMAIN_UI);
  }
  // 未读数放 AppStorage，铃铛角标直接读，省得各处自己算
  AppStorage.setOrCreate<number>(KEY_UNREAD_COUNT, store.unreadCount());

  if (inForeground()) {
    // 前台：交给 Index 弹自定义灵动弹窗（可点、能承载标题+正文，
    // promptAction.showToast 做不到这两点）
    AppStorage.setOrCreate<string>(KEY_PENDING_TOAST, msg.id);
  } else {
    await publishSystemNotification(ctx, msg);
  }
}

/** 刷新 AppStorage 里的未读数（消息中心标已读后调用）。 */
export function refreshUnreadCount(): void {
  AppStorage.setOrCreate<number>(KEY_UNREAD_COUNT, getAppMessageStore().unreadCount());
}

/** 撤掉某条消息对应的系统通知（用户已在应用内看过了）。 */
export async function cancelNotification(msgId: string): Promise<void> {
  try {
    await notificationManager.cancel(notifyIdOf(msgId));
  } catch (e) {
    // 通知本来就不存在时会报错，属正常情况
  }
}

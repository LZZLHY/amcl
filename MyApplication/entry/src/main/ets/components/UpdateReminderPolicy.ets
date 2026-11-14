/**
 * App 与运行时共用的更新提醒展示合同。这里只决定提醒等级、文案与交互式关闭资格，
 * 不读取网络、不安装软件，也不授予游戏运行资格；功能拦截始终由相应业务准入负责。
 */
export enum UpdateReminderLevel {
  NORMAL = 'normal',
  REQUIRED = 'required',
}

/** 必需更新由调用方提供真实原因和不处理的影响；退出按钮只放弃本次操作，不代表已经修复。 */
export interface RequiredUpdateNotice {
  reason: string;
  consequence: string;
  exitLabel: string;
}

/** 兼容已有发行清单的 mandatory 字段，调用方也能通过明确等级复用强提醒。 */
export function isRequiredUpdate(level: UpdateReminderLevel, legacyMandatory: boolean): boolean {
  return level === UpdateReminderLevel.REQUIRED || legacyMandatory;
}

/** 普通发现态可交互式关闭；强提醒须走具名按钮，不能将遮罩/Back误作用户接受或延期。 */
export function canDismissUpdateDiscovery(level: UpdateReminderLevel, legacyMandatory: boolean): boolean {
  return !isRequiredUpdate(level, legacyMandatory);
}

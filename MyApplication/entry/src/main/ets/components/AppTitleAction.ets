/** 标题动作的纯数据契约；事件通过稳定 id 返回页面，业务回调不放入 @Prop 深拷贝对象。 */
import { AppIconName } from 'commons';

/** 原生标题项和普通按钮共享的描述；没有 icon 时保留原来的文字操作。 */
export interface AppTitleAction {
  id: string;
  label: string;
  icon?: AppIconName;
  enabled?: boolean;
  badge?: string;
}

/** 普通圆按钮最小命中直径；紧凑视觉圆不能缩小触控和键盘操作区域。 */
export const ROUND_ACTION_HIT_SIZE: number = 44;

/** 基础读屏语义兜底；调用方应优先给出具体返回目的地或关闭对象。 */
export function roundActionLabel(name: AppIconName): string {
  if (name === AppIconName.Back) return '返回';
  if (name === AppIconName.Close) return '关闭';
  if (name === AppIconName.ArrowUpRight) return '在浏览器中打开';
  if (name === AppIconName.Settings) return '设置';
  if (name === AppIconName.Notification) return '消息';
  return '更多操作';
}

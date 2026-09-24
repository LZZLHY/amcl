/**
 * ErrorFormat.ets — 把任意 Error / unknown 值序列化成人类可读字符串
 *
 * 修复全项目 49+ 处 `JSON.stringify(e)` 反模式：
 *   - JS 的 Error 对象 name/message/stack 字段是非枚举属性
 *   - JSON.stringify(new Error('boom')) === '{}'
 *   - 直接进 hilog 就是 `failed: {}` 黑盒，开发者要凭猜测定位
 *
 * 优先级：message + stack > name + message > JSON.stringify > String(e)
 *
 * 使用：
 *   import { formatError } from '../utils/ErrorFormat';
 *   try { ... } catch (e) {
 *     hilog.warn(0, TAG, 'op failed: %{public}s', formatError(e));
 *   }
 *
 * 创建日期：2026-05-10（LOG-P1-1）
 * 关联：docs/guides/logging-system-review-and-plan.md 问题 4
 */

export function formatError(e: Object | null | undefined): string {
  if (e === null || e === undefined) return '<null>';
  // Error（或子类）有 message/stack 字段
  // ArkTS 严格模式下 `e instanceof Error` 需要显式类型守卫
  let err = e as Error;
  if (typeof err.message === 'string') {
    let name = err.name ? err.name : 'Error';
    let stack = err.stack ? ('\n' + err.stack) : '';
    return `${name}: ${err.message}${stack}`;
  }
  // BusinessError-like：{ code, data, message } 或任意对象
  try {
    let s = JSON.stringify(e);
    if (s && s !== '{}') return s;
  } catch (jsonErr) { /* fall through */ }
  return String(e);
}

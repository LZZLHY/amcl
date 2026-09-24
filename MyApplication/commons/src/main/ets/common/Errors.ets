/**
 * Errors.ets — 共用异常类型定义
 *
 * L-7 修复：原代码用 `msg.indexOf('已取消') >= 0` 字符串字面量做控制流，
 * 易被 i18n / 异常重新抛出（如 `throw new Error('aborted: ' + e.message)`）
 * 破坏。改用专用 `CancelledError` 类 + `instanceof` 判定，
 * 同时保留消息字段方便日志/UI 展示。
 */

/**
 * 用户主动取消下载/安装任务时抛出。
 *
 * 用法：
 *   throw new CancelledError();              // 默认消息 '已取消'
 *   throw new CancelledError('用户中止下载');  // 自定义消息
 *
 * 判定（替代旧的 indexOf 字符串匹配）：
 *   if (CancelledError.is(err)) { ... }       // 推荐
 *   if (err instanceof CancelledError) { ... } // 同义
 */
export class CancelledError extends Error {
  static readonly DEFAULT_MESSAGE = '已取消';

  constructor(message?: string) {
    super(message !== undefined ? message : CancelledError.DEFAULT_MESSAGE);
    this.name = 'CancelledError';
  }

  /**
   * 判定一个 Error 是否是 CancelledError。
   * 兼容 (1) 真 CancelledError 实例 (2) 旧路径未来还可能从 NAPI / 第三方
   * 抛出 "已取消" / "cancelled" 字符串错误的场景。新代码应当抛 CancelledError，
   * 但这个判定保留字符串后备防止历史代码漏改。
   *
   * 注意：ArkTS 不支持 unknown 类型；调用方应当先把 catch 的 e 当 Object 用
   *      `e as Error` 转换。`Object` 是 ArkTS 推荐的通配符顶层类型。
   */
  static is(e: Object): boolean {
    if (e instanceof CancelledError) return true;
    if (e instanceof Error) {
      let msg = e.message;
      // 字符串后备：兼容历史代码 + NAPI 层 'cancelled' / 'aborted' 字面量
      if (msg.indexOf(CancelledError.DEFAULT_MESSAGE) >= 0) return true;
      if (msg === 'cancelled') return true;
    }
    return false;
  }
}

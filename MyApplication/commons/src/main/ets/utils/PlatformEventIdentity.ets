/**
 * 平台事件的只读身份与原因解析。API26的APP_KILLED把PID放入last_exit_detail_info，
 * 官方接口可交付JSON字符串，实机也有对象形态；两者共用严格的十进制解析，不改写原件。
 * 接收时刻只表示迟到投递，绝不能替代故障时刻。未知/冲突身份保持pending，由账本决定归属。
 */
export interface PlatformEventIdentity {
  pid: number;
  eventAt: number;
  reason: string;
  conflict: boolean;
}

/** 只接受JSON对象，排除null/数组；坏的可选细节返回空对象，不从正文猜字段。 */
export function platformEventObject(value: Object | undefined): Record<string, Object> {
  try {
    let decoded: Object | undefined = value;
    if (typeof value === 'string') decoded = JSON.parse(value as string) as Object;
    if (decoded !== undefined && decoded !== null && typeof decoded === 'object' && !Array.isArray(decoded)) {
      return decoded as Record<string, Object>;
    }
  } catch (_) { /* 原件保持不变，缺少字段继续按无身份处理。 */ }
  return {};
}

/** PID/时间必须是有限正整数；字符串只接收完整十进制，不接受parseInt部分成功或指数形式。 */
function positiveInteger(value: Object | undefined, maximum: number): number {
  let numeric: number = 0;
  if (typeof value === 'number') numeric = value as number;
  else if (typeof value === 'string' && /^[1-9][0-9]{0,15}$/.test(value as string)) numeric = Number(value as string);
  return Number.isSafeInteger(numeric) && numeric > 0 && numeric <= maximum ? numeric : 0;
}

function text(value: Object | undefined): string { return typeof value === 'string' ? value as string : ''; }

/**
 * 旧的平铺pid与新的嵌套pid都可识别；两者同时有效却不同则不任意选择。
 * 只有APP_KILLED消费退出详情，不能把其它事件的任意同名嵌套对象当作进程身份。
 */
export function readPlatformEventIdentity(event: Record<string, Object>, params: Record<string, Object>): PlatformEventIdentity {
  const killed: boolean = text(event['name']) === 'APP_KILLED';
  const details: Record<string, Object> = killed ? platformEventObject(params['last_exit_detail_info']) : {};
  const flatPid: number = positiveInteger(params['pid'], 2147483647);
  const nestedPid: number = positiveInteger(details['pid'], 2147483647);
  const conflict: boolean = flatPid > 0 && nestedPid > 0 && flatPid !== nestedPid;
  const wrapperTime: number = positiveInteger(event['eventAt'], Number.MAX_SAFE_INTEGER);
  const platformTime: number = positiveInteger(params['time'], Number.MAX_SAFE_INTEGER);
  const detailTime: number = positiveInteger(details['timestamp'], Number.MAX_SAFE_INTEGER);
  let reason: string = text(event['reason']);
  if (killed) reason = text(params['reason']) || text(details['kill_reason']);
  return { pid: conflict ? 0 : flatPid || nestedPid,
    eventAt: wrapperTime || platformTime || detailTime, reason: reason, conflict: conflict };
}

/** 只翻译平台明确枚举，不通过RSS数字或日志词语猜测OOM、热终止或原生崩溃。 */
export function platformKilledSummary(reason: string): string {
  if (reason === 'RssThresholdKiller') return '游戏进程的常驻内存超过系统阈值，被系统结束';
  if (reason === 'LowMemoryKill' || reason === 'OomKiller') return '系统可用内存不足，游戏进程被系统结束';
  if (reason === 'SwapFull') return '系统交换空间接近占满，游戏进程被系统结束';
  if (reason === 'HighTemperature') return '系统报告温度超限，游戏进程被结束';
  if (reason === 'ResourceLeak(GpuLeak)' || reason === 'GpuKiller') return '系统报告游戏进程的GPU内存占用超限';
  // 仅允许有界机器原因码附加展示，不把exit_msg等任意正文或外部路径放进摘要。
  if (/^[A-Za-z0-9_().-]{1,80}$/.test(reason)) return '应用由系统结束，平台原因：' + reason;
  return '应用由系统结束，游戏终态未知';
}

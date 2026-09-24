/**
 * AppLogger.ets — ArkTS 侧持久化日志封装
 *
 * 同时输出到：
 *   1. hilog（DevEco/Hilog 面板，临时 buffer，会滚）
 *   2. 文件 filesDir/logs/amcl_launcher.log（C++ amcl_log 环形缓冲 + 轮转）
 *
 * 设计目标：下载/安装/启动失败时，所有关键错误详情都能从设备日志文件直接拉回，
 * 不再依赖 hilog buffer（16MB 满了就滚，错过失败现场就再也找不到）。
 *
 * 使用：
 *   AppLogger.info('McDownloader', `fetch version=${version}`);
 *   AppLogger.error('DownloadManager', `task ${id} failed`, err);   // 自动展开 Error
 *
 * 注意：
 *   - AppLogger 依赖 C++ NAPI amclLogInit（由 EntryAbility.onCreate 调）。
 *   - 如果 amclLogInit 还没跑，amclLogWrite 内部会自己 no-op。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN } from '../common/Constants';
import { DiagnosticPolicy } from '../common/DiagnosticPolicy';
import { formatError } from './ErrorFormat';

/** 与 C++ AmclLogLevel 对齐 */
const enum AmclLevel {
  DEBUG = 0,
  INFO  = 1,
  WARN  = 2,
  ERROR = 3,
  FATAL = 4,
}

/**
 * native 日志落盘 sink 抽象（三层架构重构 · D1=方案 a / 控制反转）。
 *
 * commons 公共能力层**不直接依赖 libentry.so**（否则 commons 抽成 HAR 时会反向依赖
 * 持有 .so 的 entry HAP）。改为：由持有 native 的 entry(HAP) 在启动时通过
 * `AppLogger.setNativeLogSink(...)` 注入真正的 testNapi 落盘实现。
 *
 * 未注入时所有方法 no-op —— 与以前「testNapi 未就绪/amcl_log 未 init 时静默降级到
 * hilog-only」的行为完全等价。
 */
export interface NativeLogSink {
  /**
   * @param activityId 该行归属的活动主键（活动账本 · L2-a）；0 = 不归属任何活动。
   *
   * ArkTS 侧**必须显式传**，不能像 native 那样用线程本地：ArkTS 跑在单个 JS 线程上，
   * 多个活动是 async 交错而非线程并发 —— 任务 A `await` 让出后 B 的回调接着跑，
   * 任何「当前活动」的环境态都是错的。详见 docs/guides/activity-ledger.md §2.3。
   */
  write(level: number, tag: string, message: string, activityId: number): void;
  flush(): void;
  getPath(): string;
  /** 可选健康查询，兼容测试/其他宿主尚未实现此接口的 sink。 */
  getStatus?(): string;
}

/** 当前注入的 native 落盘实现；null = 仅 hilog（启动早期或非 entry 宿主）。 */
let g_nativeSink: NativeLogSink | null = null;

function napiWrite(level: AmclLevel, tag: string, message: string, activityId: number = 0): void {
  if (!g_nativeSink) return;
  try {
    g_nativeSink.write(level as number, tag, message, activityId);
  } catch (e) {
    // sink 抛异常时静默降级 —— 避免日志函数再抛异常
  }
}

/**
 * 静态门面，避免调用方需要维护单例。
 *
 * 2026-05-10（LOG-P1-2）：每个方法多了可选 `domain` 参数，传入子系统域（如
 * LOG_DOMAIN_ACCOUNT）。不传则用默认 LOG_DOMAIN，与旧调用兼容。
 */
export class AppLogger {
  /** 返回可呈现的存储异常；尚未注入或旧宿主不支持时不伪造失败状态。 */
  static storageIssue(): string {
    const sink = g_nativeSink;
    if (sink === null || sink.getStatus === undefined) return '';
    try {
      const status = JSON.parse(sink.getStatus()) as Record<string, Object>;
      if (status['writable'] === false) return '启动器日志暂时无法保存，系统正在重试；请检查存储空间。';
      if (Number(status['lostWrites'] ?? 0) > 0) return '日志写入已恢复，但本次运行有部分启动器日志未能保存。';
    } catch (e) { return '暂时无法读取日志存储状态。'; }
    return '';
  }
  /**
   * 由 entry（持有 libentry.so 的 HAP）在启动时注入 native 落盘实现；传 null 卸载。
   * 见 EntryAbility.onCreate（amclLogInit 之后）。
   */
  static setNativeLogSink(sink: NativeLogSink | null): void {
    g_nativeSink = sink;
  }

  static debug(tag: string, message: string, domain: number = LOG_DOMAIN,
    activityId: number = 0): void {
    if (!DiagnosticPolicy.isDeveloperBuild()) return;
    hilog.debug(domain, tag, '%{public}s', message);
    napiWrite(AmclLevel.DEBUG, tag, message, activityId);
  }

  static info(tag: string, message: string, domain: number = LOG_DOMAIN,
    activityId: number = 0): void {
    hilog.info(domain, tag, '%{public}s', message);
    napiWrite(AmclLevel.INFO, tag, message, activityId);
  }

  static warn(tag: string, message: string, err?: Object | null, domain: number = LOG_DOMAIN,
    activityId: number = 0): void {
    let line = err ? `${message} | ${formatError(err)}` : message;
    hilog.warn(domain, tag, '%{public}s', line);
    napiWrite(AmclLevel.WARN, tag, line, activityId);
  }

  static error(tag: string, message: string, err?: Object | null, domain: number = LOG_DOMAIN,
    activityId: number = 0): void {
    let line = err ? `${message} | ${formatError(err)}` : message;
    hilog.error(domain, tag, '%{public}s', line);
    napiWrite(AmclLevel.ERROR, tag, line, activityId);
  }

  static fatal(tag: string, message: string, err?: Object | null, domain: number = LOG_DOMAIN,
    activityId: number = 0): void {
    let line = err ? `${message} | ${formatError(err)}` : message;
    hilog.fatal(domain, tag, '%{public}s', line);
    napiWrite(AmclLevel.FATAL, tag, line, activityId);
  }

  /**
   * 强制刷盘。调用方在关键节点（任务失败终态、Ability onDestroy 前）可以主动触发，
   * 避免异步线程还没来得及刷就被进程清掉。
   */
  static flush(): void {
    if (g_nativeSink) {
      try { g_nativeSink.flush(); } catch (e) { /* ignore */ }
    }
  }

  /** 获取当前日志文件路径（给 UI 显示 / 导出按钮用） */
  static getPath(): string {
    if (g_nativeSink) {
      try { return g_nativeSink.getPath(); } catch (e) { return ''; }
    }
    return '';
  }
}

/**
 * 绑定了某条活动的 logger（活动账本 · L2-a）。
 *
 * 任务类持有一个实例，把原来的 `AppLogger.info(...)` 换成 `this.alog.info(...)`，
 * 该活动期间的日志就会**同时**落进它自己的账本 `ledger/<activityId>/launcher.log`。
 *
 * 为什么不做成「设置当前活动」的环境态：ArkTS 跑在单个 JS 线程上，多个活动是
 * **async 交错**而非线程并发。任务 A `await` 让出后任务 B 的回调接着执行，此时
 * 任何全局的「当前活动」都指向错误的活动。native 侧能用线程本地是因为那里是真
 * 线程并发（下载引擎 worker、JVM 启动线程），两者不能类比。
 *
 * 用法：
 * ```ts
 * class McVersionTask {
 *   private alog: ActivityLogger
 *   constructor(activityId: number) { this.alog = new ActivityLogger(activityId) }
 *   private step() { this.alog.info('McVersionTask', 'resolving manifest…') }
 * }
 * ```
 *
 * 关联：docs/guides/activity-ledger.md §2.3
 */
export class ActivityLogger {
  /** 归属的活动主键（= ActivityRecord.startedAt）。0 = 退化为普通全局日志。 */
  private readonly activityId: number;

  constructor(activityId: number) {
    this.activityId = activityId > 0 ? activityId : 0;
  }

  /** 当前绑定的活动主键（0 = 未绑定）。 */
  id(): number { return this.activityId; }

  debug(tag: string, message: string, domain: number = LOG_DOMAIN): void {
    AppLogger.debug(tag, message, domain, this.activityId);
  }

  info(tag: string, message: string, domain: number = LOG_DOMAIN): void {
    AppLogger.info(tag, message, domain, this.activityId);
  }

  warn(tag: string, message: string, err?: Object | null, domain: number = LOG_DOMAIN): void {
    AppLogger.warn(tag, message, err, domain, this.activityId);
  }

  error(tag: string, message: string, err?: Object | null, domain: number = LOG_DOMAIN): void {
    AppLogger.error(tag, message, err, domain, this.activityId);
  }

  fatal(tag: string, message: string, err?: Object | null, domain: number = LOG_DOMAIN): void {
    AppLogger.fatal(tag, message, err, domain, this.activityId);
  }

  /** 关键节点主动刷盘（任务进入失败终态时用，避免被进程清理带走）。 */
  flush(): void { AppLogger.flush(); }
}

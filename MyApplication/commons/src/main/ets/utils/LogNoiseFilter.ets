/**
 * LogNoiseFilter.ets — 游戏日志「无害噪声」白名单（日志系统 v3 · S0）
 *
 * 背景（2026-07-30 真机复核）：
 *   一局完整跑到主菜单、随后被用户从后台划掉的会话，被现有链路诊断成
 *   「LWJGL 版本不兼容 → 建议改用 1.19 以上版本」。根因是 `classifyMcError`
 *   的规则命中了 **每次启动必现的无害输出**：
 *     - 规则 3 matchLwjglVersion 命中 "Incompatible Java and native library
 *       versions detected."（AMCL 用定制 LWJGL 替换官方 jar 后的固有自检告警）× 5
 *     - 规则 8 matchMissingFile 命中 "libflite.so: No such file or directory"
 *       （OHOS 无旁白语音库，必然缺失）× 4
 *   两条都会让用户对一个本来能正常运行的版本做破坏性操作（换版本 / 删版本重下）。
 *
 * 本模块的职责：在 **摘要提取与错误分类之前** 把这些已知无害行剥掉。
 *
 * 设计原则：
 *   1. **只影响判定，不影响留存**：原始日志文件一个字节都不改，UI 的「技术详情」
 *      仍展示完整原文。这里产出的是一份"只留信号"的副本，仅供 extractErrorSummary /
 *      classifyMcError 消费。
 *   2. **数据驱动**：规则集中在 NOISE_RULES 一处，加/删规则不用改逻辑；每条带 id，
 *      将来若发现误杀可按 id 精确回退。
 *   3. **保守**：needle 取尽可能特异的原文子串，不用宽泛正则，避免吃掉真问题。
 *
 * ⭐ **NOISE_RULES 是镜像，不是事实源**（2026-09-06，日志系统重构 · 批次 A）。
 * 事实源是 `config/log-noise-rules.json`，由 `scripts/check-log-noise-rules.mjs`
 * 逐字段比对并在语料上跑回归。改规则请改 JSON 再同步到这里，只改一侧门禁会红。
 *
 * ⚠️ **本模块不保证「剥离之后剩下的都是真信号」。** 这条前提已被 2026-09-05 的实测否证：
 * 噪声总体是**用户模组列表的函数**，而本表是按有限几套模组标定的。判定链因此不能只靠
 * 白名单，还要求错误信号自带级别语义 —— 见 `LogErrorSignal.ets`。
 *
 * 关联：docs/guides/logging-system.md §1.4、§3.5.1；docs/refactor/日志系统重构方案.md 批次 A
 * 创建日期：2026-07-30
 */

/** 一条无害噪声规则。 */
export interface LogNoiseRule {
  /** 稳定标识（便于按 id 单独禁用 / 统计命中）。 */
  id: string;
  /** 匹配用的**小写**原文子串（对整行做 indexOf，命中即视为噪声）。 */
  needle: string;
  /** 为什么无害 —— 写给后来人看，避免有人把规则当"掩盖问题"删掉。 */
  reason: string;
  /**
   * true = 同时丢弃紧随其后的 Java 堆栈续行（`\tat …` / `Caused by:` /
   * `Suppressed:` / `… N more`）。
   * 异常型噪声必须开，否则堆栈帧会被 extractErrorSummary 的兜底分支当成摘要。
   */
  dropStack: boolean;
}

/**
 * 已确认的无害噪声规则集。
 *
 * 每条都来自真机日志实证（2026-07-30，MRDI-W10，26.1.2-neoforge-26.1.2.87），
 * 不是凭推测添加的。新增规则前请先确认：该输出在**游戏正常可玩**的会话里也会出现。
 */
const NOISE_RULES: LogNoiseRule[] = [
  {
    id: 'lwjgl-native-version-selfcheck',
    needle: 'incompatible java and native library versions',
    reason: 'AMCL 在 OHOS 上统一打包定制 LWJGL 并替换官方 jar，LWJGL 自带的 jar↔native '
      + '配对自检必然告警；游戏照常运行（真机每局出现约 5 次）',
    dropStack: false,
  },
  {
    id: 'narrator-flite-missing',
    needle: "unable to load library 'flite'",
    reason: 'OHOS 无 flite 旁白语音库，Narrator 初始化失败被 MC 自行捕获，不影响游戏',
    dropStack: true,
  },
  {
    id: 'narrator-flite-library',
    // 2026-07-30 实测：flite 缺失在日志里有至少 4 种措辞
    //   "libflite.so: No such file or directory"
    //   "Unable to load library 'flite'"
    //   "Native library (linux-aarch64/libflite.so) not found in resource path (…)"
    //   "libflite.so: cannot open shared object file"
    // 逐条写规则会漏（首轮验证就漏了 JNA 的 "not found in resource path" 变体），
    // 故直接按库名匹配 —— OHOS 上永远不会有这个库，命中即噪声。
    needle: 'libflite',
    reason: 'OHOS 无 flite 旁白语音库；这条曾被 matchMissingFile 误判成「游戏文件缺失」并建议重下版本',
    dropStack: true,
  },
  {
    id: 'narrator-init-exception',
    needle: 'narrator$initializeexception',
    reason: 'Narrator 初始化异常，MC 内部已捕获并降级为无旁白',
    dropStack: true,
  },
  {
    id: 'narrator-load-error',
    needle: 'error while loading the narrator',
    reason: '同上，MC 自己打的 ERROR 行，非致命',
    dropStack: false,
  },
  {
    id: 'realms-service-exception',
    needle: 'realmsserviceexception',
    reason: 'Realms 是可选联网功能，未登录正版 / 网络不通时必然失败，不影响单人游戏',
    dropStack: true,
  },
  {
    id: 'realms-not-authorized',
    needle: 'could not authorize you against realms',
    reason: '同上（HTTP 401），真机上是本局日志的最后一行，会被当成崩溃原因',
    dropStack: false,
  },
  {
    id: 'realms-feature-flags',
    needle: 'failed to fetch realms feature flags',
    reason: '同上',
    dropStack: false,
  },
  {
    id: 'realms-connect-failed',
    needle: "couldn't connect to realms",
    reason: '同上',
    dropStack: false,
  },
  {
    id: 'user-properties-not-authorized',
    needle: 'failed to fetch user properties',
    reason: 'Minecraft 后台可选用户属性请求在离线/占位账户下返回 HTTP 401，不影响渲染或单人游戏',
    dropStack: true,
  },
  {
    id: 'user-properties-invalid-credentials',
    needle: 'invalidcredentialsexception: status: 401',
    reason: '与 failed to fetch user properties 同一后台可选请求的异常顶行，属于离线/占位账户的非致命 401',
    dropStack: true,
  },
  {
    id: 'procfs-stat-unreadable',
    needle: 'not readable: /proc/stat',
    reason: '应用沙箱无权读 /proc/stat，OSHI 之类的硬件探测必然失败，不影响游戏',
    dropStack: false,
  },
  {
    id: 'sysfs-cpu-access-denied',
    needle: '/sys/devices/system/cpu',
    reason: '沙箱无权读 CPU 拓扑，抛 AccessDeniedException 后被上层捕获',
    dropStack: true,
  },
  {
    id: 'log4j-no-tty',
    needle: 'advanced terminal features are not available',
    reason: '无 TTY 环境下 log4j 的正常提示',
    dropStack: false,
  },
  {
    id: 'glfw-diag-poll',
    needle: '[glfw-diag] poll#',
    reason: 'AMCL 自己的每帧诊断输出，纯噪声（native 侧已过滤一部分，这里兜底）',
    dropStack: false,
  },
  {
    id: 'mg-frame-telemetry',
    // 2026-09-05 实测：这一族在一份真实用户日志里占 1,092 / 1,642 行（66.5%），
    //   6 行/秒、2,322 B/秒 ⇒ 32 KB 诊断尾窗只覆盖最后约 14 秒，且那 14 秒全是它。
    //   与 1000183 / 1000202 那次 [GLFW-DIAG] 把 Stopping! 挤出尾部是同一个形状。
    // ⚠️ 1000591 已经把 AMCL_MG_FRAME_STATS 关出出货包，**这条规则仍然必须存在**：
    //   用户手上装的是 ≤1000590 的包，上报的就是塞满遥测的日志，而诊断链读的正是
    //   那些历史日志。删掉编译开关不会让已经写下的行消失。
    needle: '[mg-frame-',
    reason: 'MobileGlues 呈现边界帧遥测；出货包自 1000591 起不再产生，但历史日志里仍占多数',
    dropStack: false,
  },
  {
    id: 'mod-online-data-expired',
    // ⚠️ 本表第一条**不是**在标定设备上采到的规则。前 13 条来自 2026-07-30 那台 MRDI-W10
    //   加一套 NeoForge 语料；这条来自一位装了 133 个模组的用户，它就是「噪声总体是用户
    //   模组列表的函数，不是常量」的实证。同一条措辞在 WARN 与 [Render thread/ERROR]
    //   两个级别都出现过，而游戏停在标题界面照常可玩。
    needle: 'online mod data expired',
    reason: 'Xaero 系及同族模组按期检查作者的联网数据，过期即打一行；不影响游戏',
    dropStack: false,
  },
];

/** 暴露规则集（只读用途：UI 展示「已忽略哪些已知无害项」、测试断言）。 */
export function listLogNoiseRules(): LogNoiseRule[] {
  return NOISE_RULES;
}

/**
 * 判断一行是否命中噪声规则。
 * @param lowerLine 已经 toLowerCase 的整行文本（调用方转换，避免重复开销）
 * @returns 命中的规则；未命中返回 null
 */
function matchNoiseRule(lowerLine: string): LogNoiseRule | null {
  for (let i = 0; i < NOISE_RULES.length; i++) {
    let rule = NOISE_RULES[i];
    if (lowerLine.indexOf(rule.needle) >= 0) return rule;
  }
  return null;
}

/**
 * 是否为 Java 堆栈的续行（属于上一条异常，不是独立事件）。
 * 形如：
 *   "\tat com.foo.Bar.baz(Bar.java:12)"
 *   "\t... 12 more"
 *   "Caused by: java.io.IOException: ..."
 *   "\tSuppressed: java.io.IOException: ..."
 */
function isStackContinuation(line: string): boolean {
  let t = line.trim();
  if (t.length === 0) return false;
  if (t.indexOf('at ') === 0) return true;
  if (t.indexOf('... ') === 0 && t.indexOf('more') > 0) return true;
  if (t.indexOf('Caused by:') === 0) return true;
  if (t.indexOf('Suppressed:') === 0) return true;
  return false;
}

/** stripLogNoise 的结果：只留信号的文本 + 命中统计。 */
export interface NoiseStripResult {
  /** 剥离噪声后的日志文本（供摘要提取 / 错误分类消费）。 */
  text: string;
  /** 被剥掉的行数（含堆栈续行）。 */
  removedLines: number;
  /** 命中的规则 id 列表（去重，保持首次命中顺序）。 */
  matchedRuleIds: string[];
}

/**
 * 剥离已知无害噪声。
 *
 * **不修改任何文件**，返回一份新字符串。原始日志始终完整保留在会话文件与
 * UI「技术详情」里。
 *
 * @param logText 原始日志文本（通常是 mc_output.log 的尾部或全文）
 */
export function stripLogNoise(logText: string): NoiseStripResult {
  let empty: NoiseStripResult = { text: '', removedLines: 0, matchedRuleIds: [] };
  if (!logText || logText.length === 0) return empty;

  let lines = logText.split('\n');
  let kept: string[] = [];
  let matched: string[] = [];
  let removed = 0;
  let skippingStack = false;

  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];

    // 上一条噪声要求连带丢弃堆栈 → 持续吞掉续行
    if (skippingStack && isStackContinuation(line)) {
      removed++;
      continue;
    }
    skippingStack = false;

    let rule = matchNoiseRule(line.toLowerCase());
    if (rule !== null) {
      removed++;
      if (rule.dropStack) skippingStack = true;
      if (matched.indexOf(rule.id) < 0) matched.push(rule.id);
      continue;
    }
    kept.push(line);
  }

  let result: NoiseStripResult = {
    text: kept.join('\n'),
    removedLines: removed,
    matchedRuleIds: matched,
  };
  return result;
}

/**
 * 便捷封装：只要剥离后的文本。
 * 供不关心统计信息的调用点使用（如 classifyMcError 的入参预处理）。
 */
export function stripLogNoiseText(logText: string): string {
  return stripLogNoise(logText).text;
}

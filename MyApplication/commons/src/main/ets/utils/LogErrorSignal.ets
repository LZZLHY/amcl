/**
 * LogErrorSignal.ets — 「这一行到底算不算错误」的单一判据（日志系统重构 · 批次 A）
 *
 * 背景（2026-09-05 调研 §6.3 实测否证的一条前提）：
 *   `McErrorClassifier` 的注释里写着
 *     > 本函数的输入已经过 stripLogNoiseText …… ⇒ 剥离后仍剩的错误级别标记是真信号。
 *   这条前提**只在「噪声集合是已知且封闭的」时成立**，而噪声集合是**用户模组列表的函数**。
 *   在一份 133 模组的真实用户日志上，剥完 13 条白名单之后仍有 7 行被判成「真实错误」，
 *   而它们一行都不是错误。其中最说明问题的一条：
 *     `... multidrawMode/... for per-function exceptions.`
 *   —— 判据用的是 `low.indexOf('exception')`，它命中了英文散文里的 **"exceptions"** 这个普通单词。
 *
 * 本模块的职责：把「错误信号」从**全文子串匹配**改成**按行的、带级别语义的判据**。
 *
 * 为什么按行而不是全文：级别标记就写在那一行里。一条 `[WARN]` 行即使正文里出现了
 * `ClassNotFoundException` 这个词，它也仍然是 WARN —— 是模组作者主动打的、游戏照常跑。
 * 全文 `indexOf` 会把这一行的词汇算到整份日志头上，于是 32 KB 尾窗里**任何一处**提到
 * exception 的散文都能让整个会话被判成「有真实错误」。调研里 7 行幸存行中有 4 行是 `[WARN]`。
 *
 * ⚠️ **本模块是在收紧判定，而收紧的失效形态是静默漏报**（真崩溃被判成 not_diagnosable，
 * 用户看到「上次游戏已结束」）。所以每加一条收紧，必须同时有一条反向语料钉住
 * 「真实的启动失败仍然被判成有错误」。反向语料在 `scripts/fixtures/log-error-signal/`。
 *
 * 关联：docs/refactor/日志系统重构方案.md 批次 A、docs/guides/logging-system.md §3.5.1
 * 创建日期：2026-09-06
 */

/**
 * 错误级别标记。两种排版都要认，它们来自不同的日志框架：
 *   - `[13:14:15] [Render thread/ERROR]: …`  ← Minecraft (log4j)，级别跟在线程名后面
 *   - `[12:39:44] [ERROR] [FabricLoader/GameProvider]: …`  ← Fabric loader，级别单独成段
 * 只认这两种的**闭合形态**（带 `]`），避免命中正文里的 "error" 一词。
 */
import { explicitLogLevel } from './LogEvent';

const ERROR_LEVEL_MARKERS: string[] = ['/error]', '/fatal]', '[error]', '[fatal]'];

/**
 * Java 异常顶行。要求**行首**是一个带包名的全限定类名，且以 Exception / Error / Throwable 结尾。
 *
 * 「带包名」（至少一个 `.`）是这条正则的承重部分：它把
 *   `java.lang.NullPointerException: Cannot invoke …`      ← 认
 *   `net.fabricmc.loader.impl.FormattedException: …`       ← 认
 * 与
 *   `[WARN]: Error loading class: …ClassNotFoundException`  ← 不认（类名不在行首，且这行是 WARN）
 *   `… for per-function exceptions.`                        ← 不认（散文）
 * 分开。
 *
 * 两个前缀形态也要认，它们是同一个事件的另一种排版：
 *   `Exception in thread "main" java.lang.RuntimeException: …`
 *   `Caused by: java.io.IOException: …`   ← 32 KB 尾窗可能从堆栈中间切进来，顶行不在窗内
 */
const JAVA_THROWABLE_TOP_LINE =
  /^(?:exception in thread\s+"[^"]*"\s+|caused by:\s+)?(?:[a-z][a-z0-9_$]*\.)+[a-z0-9_$]*(?:exception|error|throwable)\b/i;

/**
 * JVM 启动器自己打的错误行，**没有任何级别标记**，例如
 *   `Error: Could not find or load main class net.minecraft.client.main.Main`
 * 必须锚在行首：正文中段的 "error:" 在模组文案里并不罕见。
 */
const BARE_ERROR_PREFIX = /^error:\s/i;

/**
 * 崩溃强信号。与 `SessionMarker.analyzeMcLog` 的 `hasCrashMarker` **取同一组常量**。
 *
 * 这里刻意用完整措辞而不是 `crash report` / `fatal error` 这种短子串：
 * 短子串会命中模组的提示文案（"please attach the crash report"）。
 * 旧实现两处各写一份、且宽窄不同，本模块把它们收敛成一处。
 */
const CRASH_MARKERS: string[] = [
  '---- minecraft crash report ----',
  '# a fatal error has been detected',
  'sigsegv',
];

/** 这一行是否带 ERROR / FATAL 级别标记。 */
export function lineHasErrorLevelMarker(line: string): boolean {
  // 官方控制台把级别保存在 Event 属性中，与文本日志复用同一个只读解析规则。
  const explicit: number = explicitLogLevel(line);
  if (explicit >= 0) return explicit === 2;
  let low = line.toLowerCase();
  for (let i = 0; i < ERROR_LEVEL_MARKERS.length; i++) {
    if (low.indexOf(ERROR_LEVEL_MARKERS[i]) >= 0) return true;
  }
  return false;
}

/** 这一行是否是 Java 异常顶行（或 JVM 的裸 `Error:` 行）。 */
export function lineIsJavaThrowableTopLine(line: string): boolean {
  let t = line.trim();
  if (t.length === 0) return false;
  if (BARE_ERROR_PREFIX.test(t)) return true;
  return JAVA_THROWABLE_TOP_LINE.test(t);
}

/**
 * 崩溃强信号的常量表。
 *
 * 暴露出来是为了让 `SessionMarker.looksLikeNormalExit` 能用同一组字面量做
 * `lastIndexOf` 比位置（它要的是「关闭标记与崩溃标记谁更靠后」，不是布尔），
 * 从而不必再抄一份。抄一份的代价是两处会分别演化 —— 本模块建立之前就已经是那样了。
 */
export function listCrashMarkers(): string[] {
  return CRASH_MARKERS;
}

/** 这一行是否是崩溃强信号。 */
export function lineIsCrashMarker(line: string): boolean {
  let low = line.toLowerCase();
  for (let i = 0; i < CRASH_MARKERS.length; i++) {
    if (low.indexOf(CRASH_MARKERS[i]) >= 0) return true;
  }
  return false;
}

/**
 * 这一行是否值得当成「错误」。
 * 供 `SessionMarker.extractErrorSummary` 的兜底分支与 `hasErrorSignal` 共用，
 * 保证「能当摘要的行」与「算错误信号的行」是**同一个集合** —— 旧实现这两处的判据不一致。
 */
export function lineLooksLikeError(line: string): boolean {
  return lineHasErrorLevelMarker(line)
    || lineIsCrashMarker(line)
    || lineIsJavaThrowableTopLine(line);
}

/**
 * 整段日志里是否存在**任何**错误信号。
 *
 * @param cleanText 建议传已经过 `stripLogNoiseText` 的文本；本函数不依赖这一点，
 *                  但白名单能减少需要靠级别判据兜住的行数。
 */
export function hasErrorSignal(cleanText: string): boolean {
  if (!cleanText || cleanText.length === 0) return false;
  let lines = cleanText.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lineLooksLikeError(lines[i])) return true;
  }
  return false;
}

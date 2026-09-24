/**
 * SessionMarker.ets — MC 会话标记机制
 *
 * 历史背景：早期设备/产品的 GameAbility 并未取得独立进程，不能把当时观察泛化为
 * 所有 HarmonyOS 设备都不支持隔离。当前是否隔离以实际 PID 与游戏进程锁验证为准。
 * 在历史同进程路线中：
 *   2. MC 调 `System.exit()` 会触发 libappspawn_helper 的 exit() hook：
 *      若 `APPSPAWN_CHECK_EXIT == getpid()` 则 `abort()` 终止整个进程。
 *   3. `appRecovery.enableAppRecovery(ALWAYS_RESTART)` 仅覆盖 JS_CRASH 和 APP_FREEZE，
 *      对 native 层 SIGABRT/SIGSEGV 不触发自动重启。
 *
 * 因此该历史路线可能 MC 退出 → SIGABRT → 宿主进程死亡，无法在原进程内返回启动器。
 * 独立游戏进程则由启动器前台/冷启动恢复同一 marker，并补读有身份校验的 JVM 退出记录。
 * 我们靠 SessionMarker 实现下次冷启动时的 UX 恢复：
 *
 *   1. MC 启动成功后写一个标记文件 `${filesDir}/mc_running.flag`
 *   2. 进程因 MC exit 而崩溃，标记文件残留
 *   3. 用户下次冷启动 app，EntryAbility.onCreate 读取并清除该标记
 *   4. Index.ets aboutToAppear 检测到标记 → toast 提示"上次 MC 已退出"
 *
 * 注：标记同样会在用户主动从后台杀 app 时残留，这种情况下也会显示提示，
 *     视为"会话被中断"的合理 UX，不算误报。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_LAUNCH } from 'commons';
import { stripLogNoise, NoiseStripResult } from 'commons';
import { lineLooksLikeError, listCrashMarkers } from 'commons';
import { readGameLogTail, GameLogRead, GAME_LOG_PREVIEW_BYTES } from 'commons';

const TAG = 'SessionMarker';
const MARKER_NAME = 'mc_running.flag';

export interface McSessionInfo {
  /** MC 启动时的 wall clock 时间戳（ms） */
  startedAt: number;
  /** 当时启动的 MC 版本 ID（如 "1.20.4" 或 "1.20.4-forge-49.0.50"） */
  version: string;
  /**
   * 当时启动的 mcDir（.minecraft 根目录），用于后续读 mc_output.log。
   * 旧 marker 可能没这字段，readAndClear 时会兜底为空字符串。
   */
  mcDir: string;
  /** 可选的本局退出请求时间；旧 marker 没有此字段，不能据此假定正常退出。 */
  endedAt?: number;
}

export class SessionMarker {
  private static markerPath(filesDir: string): string {
    return filesDir + '/' + MARKER_NAME;
  }

  /**
   * 在 MC 启动成功后立即调用。
   * 不抛异常：写失败只打 warn，不阻断启动。
   *
   * @param filesDir  app filesDir，用于定位 marker 文件
   * @param version   MC 版本 ID（如 "1.20.4-forge-49.0.50"）
   * @param mcDir     启动时的 .minecraft 根目录，用于冷启动后定位 mc_output.log
   *                  （新版游戏隔离场景下 mcDir != filesDir/.minecraft，必须显式传）
   * @returns 本次会话的 `startedAt`（毫秒）；写失败返回 0。
   *
   * 2026-07-30（活动账本 · L3）：改为返回 startedAt。它同时是活动记录主键、M3 的
   * sessionKey 与账本 activityId —— 调用方必须复用**这一个**值去开账本，自己再取一次
   * `Date.now()` 会得到差几毫秒的另一个 id，导致账本与会话记录对不上。
   */
  static writeStart(filesDir: string, version: string, mcDir: string,
    startedAtOverride: number = 0): number {
    if (!filesDir) {
      AppLogger.warn(TAG, 'writeStart skipped: empty filesDir', null, LOG_DOMAIN_LAUNCH);
      return 0;
    }
    // 本方法在「MC 启动成功后」才被调用，但账本必须在**启动之前**就开好
    // （native 启动线程一开跑就在打 MC_LAUNCHER / JVM_LAUNCHER 日志）。
    // 所以调用方会先自己定好 startedAt 去开账本，再把同一个值传进来，
    // 保证 marker / 活动记录 / 账本三者主键一致。
    let startedAt = startedAtOverride > 0 ? startedAtOverride : Date.now();
    let info: McSessionInfo = {
      startedAt: startedAt,
      version: version || '<unknown>',
      mcDir: mcDir || '',
    };
    let path = SessionMarker.markerPath(filesDir);
    try {
      let f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        let payload = JSON.stringify(info);
        fs.writeSync(f.fd, payload);
        fs.fsyncSync(f.fd); // 让 marker 在 crash 前真正落盘
      } finally {
        fs.closeSync(f);
      }
      AppLogger.info(TAG, `Marker written: ${path}`, LOG_DOMAIN_LAUNCH);
    } catch (e) {
      AppLogger.warn(TAG, `Failed to write marker ${path}`, e, LOG_DOMAIN_LAUNCH);
      return 0;
    }
    return startedAt;
  }

  /**
   * 冷启动时调用。读取 marker（若存在），并立即删除。
   * 返回上次会话信息；marker 不存在或读取失败时返回 null。
   */
  static readAndClear(filesDir: string): McSessionInfo | null {
    if (!filesDir) return null;
    let path = SessionMarker.markerPath(filesDir);
    let exists = false;
    try {
      let st = fs.statSync(path);
      exists = st.size > 0;
    } catch (e) {
      return null; // 不存在
    }
    if (!exists) return null;

    let info: McSessionInfo | null = null;
    try {
      let text = fs.readTextSync(path);
      let obj = JSON.parse(text) as Record<string, Object>;
      let startedAt = obj['startedAt'] as number;
      let version = obj['version'] as string;
      // mcDir 是 v6 (2026-05-19) 新增字段，旧 marker 无该字段时兜底空字符串
      let mcDir = (obj['mcDir'] as string) || '';
      if (typeof startedAt === 'number' && typeof version === 'string') {
        info = { startedAt, version, mcDir };
      } else {
        AppLogger.warn(TAG, `Marker payload malformed: ${text}`, null, LOG_DOMAIN_LAUNCH);
      }
    } catch (e) {
      AppLogger.warn(TAG, 'Failed to read marker', e, LOG_DOMAIN_LAUNCH);
    }

    // 不论解析成功与否，都删除 marker，避免反复触发
    try {
      fs.unlinkSync(path);
      AppLogger.info(TAG, `Marker cleared: ${path}`, LOG_DOMAIN_LAUNCH);
    } catch (e) {
      AppLogger.warn(TAG, 'Failed to delete marker', e, LOG_DOMAIN_LAUNCH);
    }
    return info;
  }

  /**
   * 读取 mc_output.log 的尾部内容（用于冷启动后展示崩溃信息 Sheet）。
   *
   * 调用时机：EntryAbility 把 McSessionInfo 塞进 AppStorage 后，Index/Sheet 在
   *           真正展开时再 lazy 调用，避免空跑（多数情况下用户正常退出，不弹 Sheet）。
   *
   * 2026-07-30（日志系统 v3 · S0）：路径解析改走 `commons/GameLogPaths`。
   *   原实现固定拼 `<mcDir>/versions/<id>/mc_output.log`，**版本隔离关闭时**游戏目录
   *   退化为 mcDir 本身，恒读不到日志（与 native `mcReadLog` 只读 mcDir 根、
   *   隔离开启时恒读不到，正好是互补的两个半场）。现由单一解析入口同时覆盖两种布局。
   *
   * @param mcDir     .minecraft 根目录
   * @param versionId 版本 ID（用于定位版本隔离布局；为空则只探非隔离布局）
   * 2026-07-30（日志系统 v3 · M2）：函数体整段委托给 `commons/GameLogPaths` 的
   *   `readGameLogTail`。原实现自己手写了逐字节 UTF-8 解码 + `s += String.fromCharCode()`
   *   字符串累加，注释里写的理由是「ArkTS 没有 TextDecoder」—— 这个前提是错的，
   *   `util.TextDecoder` 一直有（LogShareClient 的 SSE 解码就在用）。逐字符累加在
   *   32 KB 时勉强能用，但 M2 要支持全量读取（可达数 MB），O(n) 次字符串重分配会
   *   直接卡死 UI 线程。现在读取口径与解码实现都只有一份。
   *
   * @param maxBytes  最多读多少字节尾部（默认 32 KB，对 Java 异常 stack trace 够用）
   * @returns         日志尾部文本；找不到文件 / 读失败时返回空串
   */
  static readMcLogTail(mcDir: string, versionId: string,
    maxBytes: number = GAME_LOG_PREVIEW_BYTES): string {
    if (!mcDir) return '';
    let r: GameLogRead = readGameLogTail(mcDir, versionId, maxBytes);
    if (r.text.length === 0 && r.totalBytes === 0) {
      AppLogger.info(TAG, 'mc_output.log not found or empty under ' + mcDir
        + ' (versionId=' + versionId + ')', LOG_DOMAIN_LAUNCH);
    }
    return r.text;
  }

  /**
   * 从 mc_output.log 尾部 heuristic 提取关键错误摘要（Sheet 标题区显示用）。
   *
   * 策略：
   *   - 命中 Java 异常类（FQN 中含 'Exception' / 'Error'）的第一行 → 用作摘要
   *   - 命中 Fabric "Some of your mods are incompatible" 类标题 → 用作摘要
   *   - 否则取最后一段非空行（前 200 字符）
   *
   * 2026-07-30（日志系统 v3 · S0）：**入口先过无害噪声白名单**。
   *   真机复核发现：一局正常跑到主菜单、被用户从后台划掉的会话，其日志尾部最后一条
   *   异常是 Realms 的 HTTP 401（可选联网功能，未登录正版必然失败），旧实现把它当成
   *   崩溃原因展示给用户。现在 Realms / Narrator-flite / LWJGL 自检 / procfs 权限等
   *   已确认无害的输出会先被剥掉；剥完没有真实错误时返回空串，由调用方据此**不展示**
   *   错误信息，而不是编造一个原因。
   *
   * @param logTail readMcLogTail 返回的尾部文本
   * @returns       简短摘要字符串（≤ 200 字符）；无真实错误时返回空串
   */
  static extractErrorSummary(logTail: string): string {
    if (!logTail) return '';
    let stripped: NoiseStripResult = stripLogNoise(logTail);
    if (stripped.text.trim().length === 0) return '';
    let lines = stripped.text.split('\n');
    // 优先级 1：Fabric formatted error 标题（v6 实测路径）
    for (let line of lines) {
      let t = line.trim();
      if (t.length === 0) continue;
      if (t.indexOf('Some of your mods are incompatible') >= 0
        || t.indexOf('Mod resolution failed') >= 0
        || t.indexOf('Incompatible mods found') >= 0) {
        return t.length > 200 ? t.substring(0, 200) + '...' : t;
      }
    }
    // 优先级 2：Java 异常顶行
    for (let line of lines) {
      let t = line.trim();
      // 形如 "net.fabricmc.loader.impl.FormattedException: Some of..."
      // 或 "java.lang.NullPointerException: Cannot invoke..."
      let m = t.match(/^[a-z][a-zA-Z0-9_.$]+(Exception|Error|Throwable):\s*(.*)$/);
      if (m) {
        let msg = m[2] || '(no message)';
        let short = m[0].length > 200 ? m[0].substring(0, 200) + '...' : m[0];
        void msg;
        return short;
      }
    }
    // 兜底：最后一条**看起来确实是错误**的行。
    // 2026-07-30：旧实现直接取「最后一行非空内容」，剥离噪声后这往往是一条无害的
    //   INFO（如 "Created: 2048x2048 …-atlas"），照样会被当成崩溃原因。现在要求该行
    //   带 ERROR/FATAL 级别标记或 Java 异常特征，否则视为「日志里没有可归因的错误」
    //   并返回空串，让调用方老实说"无法确定原因"。
    // 2026-09-06（日志系统重构 · 批次 A）：判据整体换成 `LogErrorSignal.lineLooksLikeError`。
    //   ⚠️ 这里原来与 `McErrorClassifier.hasAnyErrorSignal` 是**两份宽窄不同的判据**：
    //   本处认 `crash` 却不认 `[ERROR]`（Fabric 排版），那边认 `[ERROR]` 却把 `crash report`
    //   放得更宽。于是存在「算得上错误信号、却抽不出摘要」和它的反面两种夹缝。
    //   现在两处共用一个集合，且都要求级别标记 / 异常顶行 / 崩溃强信号。
    for (let i = lines.length - 1; i >= 0; i--) {
      let t = lines[i].trim();
      if (t.length === 0) continue;
      // 堆栈续行不是独立事件，不能当摘要（否则会拿到 "Suppressed: java.io.IOException: …"
      // 或 "at com.foo.Bar(...)" 这种半截上下文）。
      if (t.indexOf('at ') === 0) continue;
      if (t.indexOf('Caused by:') === 0) continue;
      if (t.indexOf('Suppressed:') === 0) continue;
      if (t.indexOf('... ') === 0 && t.indexOf('more') > 0) continue;
      if (lineLooksLikeError(t)) {
        return t.length > 200 ? t.substring(0, 200) + '...' : t;
      }
    }
    return '';
  }

  /**
   * 判断上次会话是否为【正常退出】（用户主动退游戏，而非崩溃）。
   *
   * 背景：AMCL 故意让 MC 的 System.exit() 触发 SIGABRT 杀掉整个 app 进程
   * （HarmonyOS 三方应用单进程限制，详见本文件头注释）。因此【正常退出】和
   * 【崩溃】一样都会残留 marker、下次冷启动都会被读到。若不区分，用户正常退游戏
   * 后重进启动器也会弹"启动失败"错误 Sheet —— 这是误报。
   *
   * 判据（看日志尾部）：
   *   - 正常关闭：MC 会打印 "Stopping!"（客户端）/ "Stopping server"（集成服务器）等；
   *   - 崩溃：会出现 Crash Report 头 / "fatal error" / SIGSEGV。
   * 比较两类标记在日志里【最后出现的位置】：正常关闭标记更靠后 → 正常退出。
   * 这样即便"关闭过程中又崩了"（Stopping! 之后还有崩溃）也会被正确判为崩溃。
   *
   * 保守取向：日志为空 / 没有任何关闭标记 → 返回 false（当作异常，宁可多弹一次
   * Sheet，也不漏报真实崩溃）。
   *
   * @param logTail readMcLogTail 返回的尾部文本
   * @returns true = 正常退出（调用方应跳过错误 Sheet）
   */
  static looksLikeNormalExit(logTail: string): boolean {
    if (!logTail || logTail.length === 0) return false;
    let lower = logTail.toLowerCase();

    // 崩溃强信号——取最后出现位置。
    // 2026-09-06：常量取自 `LogErrorSignal.listCrashMarkers()`，与 analyzeMcLog、
    //   classifyMcError 的早退判据同源。此前三处各抄一份且宽窄不同。
    let crashIdx = -1;
    const crashMarkers: string[] = listCrashMarkers();
    for (let m of crashMarkers) {
      let i = lower.lastIndexOf(m);
      if (i > crashIdx) crashIdx = i;
    }

    // 正常关闭信号——取最后出现位置
    let stopIdx = -1;
    const stopMarkers: string[] = [
      'stopping!',                 // net.minecraft.client.Minecraft 关闭（退到桌面）
      'stopping server',           // 集成服务器关闭
      'stopping worker threads',
    ];
    for (let m of stopMarkers) {
      let i = lower.lastIndexOf(m);
      if (i > stopIdx) stopIdx = i;
    }

    if (stopIdx < 0) return false;          // 没有任何关闭标记 → 不是正常退出
    return stopIdx > crashIdx;              // 关闭标记在崩溃标记之后（更靠近末尾）→ 正常
  }

  /**
   * 从日志尾部提取**日志侧证据**（日志系统 v3 · S0）。
   *
   * 与 looksLikeNormalExit 的区别：后者只回答「是不是正常退出」这一个是非题，
   * 且「没有关闭标记」会被保守判成异常 —— 真机证明这条保守取向直接造成误报
   * （用户从后台划掉进程时日志里既无关闭标记也无崩溃标记，却被判成崩溃）。
   *
   * 本方法不做最终裁决，只把日志里**能看到的事实**摊开，交给调用方与平台退出原因
   * （`launchParam.lastExitReason` / HiAppEvent `APP_KILLED`，见 logging-system.md
   * §3.5）合并判定。日志证据不足时诚实地报 hasRealError=false，而不是编造原因。
   *
   * @param logTail readMcLogTail 返回的尾部文本
   */
  static analyzeMcLog(logTail: string): McLogEvidence {
    let empty: McLogEvidence = {
      hasLog: false,
      hasStopMarker: false,
      hasCrashMarker: false,
      hasRealError: false,
      summary: '',
      noiseRuleIds: [],
      strippedText: '',
    };
    if (!logTail || logTail.length === 0) return empty;

    let lower = logTail.toLowerCase();
    let hasStop = lower.indexOf('stopping!') >= 0
      || lower.indexOf('stopping server') >= 0
      || lower.indexOf('stopping worker threads') >= 0;
    let hasCrash = false;
    const crashMarkers: string[] = listCrashMarkers();
    for (let m of crashMarkers) {
      if (lower.indexOf(m) >= 0) { hasCrash = true; break; }
    }

    let stripped: NoiseStripResult = stripLogNoise(logTail);
    let summary = SessionMarker.extractErrorSummary(logTail);

    let ev: McLogEvidence = {
      hasLog: true,
      hasStopMarker: hasStop,
      hasCrashMarker: hasCrash,
      // 有崩溃强信号，或剥离噪声后仍能提取到错误摘要 → 存在真实错误
      hasRealError: hasCrash || summary.length > 0,
      summary: summary,
      noiseRuleIds: stripped.matchedRuleIds,
      strippedText: stripped.text,
    };
    return ev;
  }
}

/**
 * 上一局游戏在**日志里留下的证据**（不含平台退出原因）。
 *
 * 消费方：`McErrorClassifier.shouldDiagnose` 做门控、`McErrorSheet` 决定展示什么。
 */
export interface McLogEvidence {
  /** 是否拿到了非空日志。false = 日志缺失/读失败，任何结论都不可靠。 */
  hasLog: boolean;
  /** 出现 MC 正常关闭标记（Stopping! 等）。 */
  hasStopMarker: boolean;
  /** 出现崩溃强信号（Crash Report 头 / fatal error / SIGSEGV）。 */
  hasCrashMarker: boolean;
  /** 剥离已知无害噪声后，日志里是否仍存在可归因的真实错误。 */
  hasRealError: boolean;
  /** 错误摘要；hasRealError=false 时为空串。 */
  summary: string;
  /** 本次被剥离的噪声规则 id（可在「技术详情」里说明「已忽略 N 项已知无害输出」）。 */
  noiseRuleIds: string[];
  /** 剥离噪声后的日志文本（供分类器消费，避免它再次踩到噪声）。 */
  strippedText: string;
}

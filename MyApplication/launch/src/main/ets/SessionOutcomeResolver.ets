/** 会话恢复的唯一裁决入口：显式终态优先，完整游戏流与平台证据分别保留。 */
import { ledgerManifest, ledgerEnd, LedgerState, LedgerOutcome, listSessionEvidence,
  EvidenceFileRecord, EvidenceFileState, EvidenceRole, EvidenceTextCursor, listCrashMarkers } from 'commons';
import { checkpointSessionCapture, listActivityIds, archivePlatformEventFiles_ } from 'commons';
import { SessionMarker } from './SessionMarker';
import { readJvmExitEvidence } from './JvmExitEvidence';

/**
 * 归属字段只表示来源关系，不代表本局已捕获文件。SessionEvidence 会保留启动前旧
 * crash-report 的 not-produced/零字节占位项，不能把它的 source-baseline 当成新崩溃。
 * 只有明确本局归属且状态允许读取的非空候选才进入裁决；正文仍须由游标实际读到。
 * 不复用默认分享策略：用户的上传选择与本地会话结局是两个独立决策。
 */
function isCapturedSessionSource(file: EvidenceFileRecord): boolean {
  return hasSessionAttribution(file)
    && (file.state === EvidenceFileState.AVAILABLE || file.state === EvidenceFileState.COMPLETE
      || file.state === EvidenceFileState.WRITING || file.state === EvidenceFileState.PARTIAL);
}

/** 来源归属与捕获/可读状态分开判断：本局报告不可读也必须保留不确定性。 */
function hasSessionAttribution(file: EvidenceFileRecord): boolean {
  return file.attribution === 'source-baseline' || file.attribution === 'exact';
}

/** 非空路径和长度只筛选读取候选，绝不代替下面真正的正文读取。 */
function isSessionBodyCandidate(file: EvidenceFileRecord): boolean {
  return isCapturedSessionSource(file) && file.bytes > 0 && file.localPath.length > 0;
}

/**
 * 报告存在的最终证据是本局归档文件里实际可读的正文，不是清单中的 bytes 声明。
 * 文件在清单生成后被清理、变空或读取失败时返回 false；调用者保留不确定性，
 * 不能因此弹“本次崩溃”，也不能再以一条正常关闭标记保证没有遗漏此报告。
 */
async function hasCrashReportBody(file: EvidenceFileRecord): Promise<boolean> {
  const cursor = new EvidenceTextCursor();
  let hasBody: boolean = false;
  try {
    await cursor.open(file.localPath, file.path.endsWith('.gz'));
    let eof: boolean = false;
    while (!hasBody && !eof) {
      const page = await cursor.read();
      hasBody = page.bytesRead > 0 && page.text.trim().length > 0;
      eof = page.eof;
    }
  } catch (e) { hasBody = false; }
  finally {
    try { await cursor.close(); } catch (e) { hasBody = false; }
  }
  return hasBody;
}

export async function resolveRecoveredSessionOutcome(filesDir: string, activityId: number): Promise<LedgerOutcome> {
  // 热恢复没有经过全局 resolveStale。只补采本局，绝不能把启动器仍在运行的下载活动标成中断。
  // 下一局边界继续使用既有 capture 契约，不能读到后续版本覆盖的 latest/crash 文件。
  const initialExit = readJvmExitEvidence(filesDir, activityId);
  let nextLaunchAt: number = 0;
  for (const id of listActivityIds(filesDir)) {
    if (id <= activityId || ledgerManifest(filesDir, id)?.category !== 'launch') continue;
    if (nextLaunchAt === 0 || id < nextLaunchAt) nextLaunchAt = id;
  }
  try { checkpointSessionCapture(filesDir, activityId, initialExit?.timestamp ?? Date.now(), nextLaunchAt); }
  catch (e) { /* 保留现有已捕获证据；采集失败不能伪造正常终态。 */ }
  archivePlatformEventFiles_(filesDir);
  const manifest = ledgerManifest(filesDir, activityId);
  if (manifest !== null && manifest.state !== LedgerState.RUNNING && manifest.state !== LedgerState.INTERRUPTED
    && !manifest.outcomeSource.startsWith('platform.') && manifest.outcomeSource !== 'session.full-evidence'
    && manifest.outcomeSource !== 'session.jvm-exit') {
    return { state: manifest.state, source: manifest.outcomeSource, summary: manifest.outcomeSummary, errorKind: manifest.errorKind };
  }
  // 退出文件是 JVM 请求事实，不是原生崩溃的免责证明；后续真实 crash/平台事件仍优先。
  const exit = initialExit;
  const files: EvidenceFileRecord[] = listSessionEvidence(filesDir, activityId);
  let crash: EvidenceFileRecord | undefined = undefined;
  let unreadableCrash: boolean = false;
  for (const file of files) {
    if ((file.role !== EvidenceRole.CRASH_REPORT && file.role !== EvidenceRole.JVM_FATAL)
      || !hasSessionAttribution(file)) continue;
    // 只有明确的未产出/不适用项才可忽略。已归属本局但 missing/unavailable/
    // 未知状态的报告并不等于“不存在”，不能在读取失败后被 Stopping 掩盖。
    if (file.state === EvidenceFileState.NOT_PRODUCED || file.state === EvidenceFileState.NOT_APPLICABLE) continue;
    if (isSessionBodyCandidate(file) && await hasCrashReportBody(file)) { crash = file; break; }
    // complete/partial 等记录意味着本局已有捕获；其正文若后来消失，只能报告不确定，
    // 与从未产出的旧 baseline 占位项不同，不能借正常日志宣称该报告不存在。
    unreadableCrash = true;
  }
  let summary: string = crash === undefined ? '' : '本次启动产生了崩溃报告：' + crash.path;
  let crashAt: number = -1;
  let stopAt: number = -1;
  let position: number = 0;
  let readable: boolean = false;
  const main = files.find((file: EvidenceFileRecord): boolean => file.path === 'game/logs/latest.log'
    && isSessionBodyCandidate(file))
    ?? files.find((file: EvidenceFileRecord): boolean => file.role === EvidenceRole.MINECRAFT_OUTPUT
      && file.attribution === 'exact' && isSessionBodyCandidate(file));
  if (main !== undefined) {
    const cursor = new EvidenceTextCursor();
    let carry: string = '';
    try {
      await cursor.open(main.localPath, main.path.endsWith('.gz'));
      let eof: boolean = false;
      let hasBody: boolean = false;
      while (!eof) {
        const page = await cursor.read();
        eof = page.eof;
        if (page.bytesRead > 0 && page.text.trim().length > 0) hasBody = true;
        const text: string = carry + page.text;
        const lower: string = text.toLowerCase();
        for (const marker of listCrashMarkers()) {
          const index: number = lower.lastIndexOf(marker);
          if (index >= 0) crashAt = Math.max(crashAt, position - carry.length + index);
        }
        // 集成服务器停止只表示离开存档，不能据此判定整个客户端正常退出。
        const stop: number = lower.lastIndexOf('stopping!');
        if (stop >= 0) stopAt = Math.max(stopAt, position - carry.length + stop);
        if (summary.length === 0) summary = SessionMarker.extractErrorSummary(text);
        position += page.text.length;
        carry = text.substring(Math.max(0, text.length - 8192));
      }
      // 读取到 EOF 才能使用“最后一个关闭标记”作成功结论；partial/writing 仍可
      // 提供明确崩溃线索，但不能把已知采集缺口或未封账流表述为“完整正常关闭”。
      readable = hasBody && main.state !== EvidenceFileState.PARTIAL
        && main.state !== EvidenceFileState.WRITING;
    } catch (e) { readable = false; }
    finally {
      try { await cursor.close(); } catch (e) { readable = false; }
    }
  }
  let outcome: LedgerOutcome;
  if (crash !== undefined || crashAt >= 0 && crashAt > stopAt) {
    outcome = { state: LedgerState.CRASHED, source: 'session.full-evidence', summary: summary || '游戏日志包含崩溃现场' };
  } else if (manifest !== null && manifest.state === LedgerState.CRASHED
    && manifest.outcomeSource.startsWith('platform.')) {
    // 精确归属的平台崩溃不能被 Stopping 或 exit(0) 请求覆盖；原始退出事实仍归档保留。
    outcome = { state: manifest.state, source: manifest.outcomeSource, summary: manifest.outcomeSummary };
  } else if (!unreadableCrash && exit !== undefined) {
    outcome = { state: exit.exitCode === 0 ? LedgerState.SUCCESS : LedgerState.FAILED,
      source: 'session.jvm-exit', summary: exit.exitCode === 0
        ? 'JVM 已请求正常退出（请求代码 0），独立游戏进程已结束；该记录不是操作系统退出状态证明'
        : `JVM 已请求以非零代码 ${exit.exitCode} 退出，请查看本局日志` };
  } else if (!unreadableCrash && readable && stopAt >= 0 && stopAt > crashAt) {
    outcome = { state: LedgerState.SUCCESS, source: 'session.full-evidence', summary: '完整游戏日志记录了客户端正常关闭' };
  } else if (manifest !== null && manifest.outcomeSource.startsWith('platform.')) {
    outcome = { state: manifest.state, source: manifest.outcomeSource, summary: manifest.outcomeSummary };
  } else {
    outcome = { state: LedgerState.INTERRUPTED, source: 'session.full-evidence',
      summary: unreadableCrash ? '本局报告正文不可读，无法确定本次退出原因'
        : readable ? '本次游戏会话已结束，未发现明确的客户端退出或崩溃终态'
          : '游戏日志不可用或采集不完整，无法判定本次退出原因' };
  }
  // 已核验的平台时间优先；JVM 退出记录次之。日志关键词只有顺序，没有可靠墙钟终点。
  outcome.endedAt = manifest !== null && manifest.outcomeSource.startsWith('platform.')
    && manifest.endTimeEstimated !== true && manifest.endedAt > 0 ? manifest.endedAt : exit?.timestamp ?? 0;
  outcome.recoveredAt = Date.now();
  ledgerEnd(filesDir, activityId, outcome);
  return outcome;
}

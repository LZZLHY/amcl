/**
 * BMS只认系统BMSTool OnFinished，不以CLI/新版本代替终态。
 * 新证据把同child exec前的完整baseline与完整post按SHA和UTF-8原字节绑定；
 * 只分析新增suffix。旧记录缺baseline、截断/丢失/重复/未知前缀均保持unknown。
 * hilog monotonic仅整数秒为CLOCK_MONOTONIC，小数来自REALTIME，不能当单调浮点。
 */
import { util } from '@kit.ArkTS';
import { InstallExecutionIdentity, InstallExecutionObservation, BmEvidenceAuthority } from './SideloadInstallProtocol';

/** undefined表示没有读到文件；0字节真实普通文件才是合法空baseline。 */
export interface BmLogSnapshot { bytes: Uint8Array; sha256: string; }
interface BmLogLine { seconds: number; text: string; }

export class BmTerminalEvidence {
  /**
   * 固定PID/domain/tag/msec格式。最多剥一层已核实HiTrace：
   * 官方逗号三id/单id与API26实测空格三id，只允许有界十六进制字段。
   * 后续仍精确匹配source/function，不用任意方括号通配。
   */
  private static line(pid: number, body: string): BmLogLine | undefined {
    const match = new RegExp('^\\s*([0-9]+)\\.[0-9]{3}\\s+' + pid + '\\s+[0-9]+\\s+I\\s+C01123/bm/BMSTool: (.*)$').exec(body);
    if (match === null) return undefined;
    const seconds = Number(match[1]); if (!Number.isSafeInteger(seconds) || seconds < 0) return undefined;
    let text = match[2];
    const trace = new RegExp('^\\[(?:[0-9a-f]{1,16}(?:, [0-9a-f]{1,16}, [0-9a-f]{1,16}| [0-9a-f]{1,16} [0-9a-f]{1,16})?)\\] ?').exec(text);
    if (trace !== null) text = text.substring(trace[0].length);
    return { seconds: seconds, text: text };
  }
  /**
   * 帮助命令只核对整数秒区间[sec,sec+1)与proc start相容，不授安装终态。
   * 精度来自官方格式；安装的同秒PID歧义必须另外由可靠baseline消除。
   */
  static clockAligned(identity: InstallExecutionIdentity, processJson: string, log: string): boolean {
    try {
      const row = JSON.parse(processJson) as Record<string, Object>;
      const pid = Number(row['bmPid']); const start = Number(row['startTicks']); const ticks = Number(row['clockTicks']);
      if (row['installId'] !== identity.installId || row['nonce'] !== identity.nonce || !Number.isSafeInteger(pid) || pid <= 0 ||
        !Number.isSafeInteger(start) || start <= 0 || !Number.isInteger(ticks) || ticks <= 0 || ticks > 1000000 || log.length >= 65536) return false;
      const lower = start / ticks; let began = false; let ended = false;
      for (const body of log.split('\n')) {
        const parsed = BmTerminalEvidence.line(pid, body); if (parsed === undefined || parsed.seconds + 1 <= lower) continue;
        if (new RegExp('^\\[main\\.cpp\\(main:[0-9]+\\)\\]bm exec start$').test(parsed.text)) {
          if (began || parsed.seconds > Math.floor(lower) + 2) return false; began = true;
        }
        if (new RegExp('^\\[main\\.cpp\\(main:[0-9]+\\)\\]bm exec end$').test(parsed.text)) {
          if (!began || ended) return false; ended = true;
        }
      }
      return began && ended;
    } catch (_) { return false; }
  }
  /**
   * authority来自同nonce原子CLAIM，snapshot来自Executor实际字节读取及SHA。
   * receipt明确绑定完整采集版本/格式/长度/摘要；不得把旧v2的读取失败''补成空baseline。
   */
  static classify(identity: InstallExecutionIdentity, authority: BmEvidenceAuthority | undefined,
    processJson: string, receiptJson: string, baseline: BmLogSnapshot | undefined,
    post: BmLogSnapshot | undefined): InstallExecutionObservation | undefined {
    if (authority === undefined || baseline === undefined || post === undefined || authority.version !== 1 ||
      processJson.length > 2048 || receiptJson.length > 4096 || baseline.bytes.byteLength >= 65536 || post.bytes.byteLength >= 65536) return undefined;
    try {
      const process = JSON.parse(processJson) as Record<string, Object>, receipt = JSON.parse(receiptJson) as Record<string, Object>;
      const pid = Number(process['bmPid']), start = Number(process['startTicks']), ticks = Number(process['clockTicks']);
      if (process['installId'] !== identity.installId || process['nonce'] !== identity.nonce || process['bmEvidenceVersion'] !== 1 ||
        pid !== authority.pid || !Number.isSafeInteger(pid) || pid <= 0 || !Number.isSafeInteger(start) || start <= 0 ||
        process['bmGroup'] !== pid || process['bmSession'] !== pid ||
        process['reservationPid'] !== authority.reservationPid || process['reservationStartTicks'] !== authority.reservationStartTicks ||
        process['reservationInode'] !== authority.reservationInode ||
        !Number.isInteger(ticks) || ticks <= 0 || ticks > 1000000) return undefined;
      if (receipt['protocol'] !== 2 || receipt['bmEvidenceVersion'] !== 1 || receipt['installId'] !== identity.installId ||
        receipt['nonce'] !== identity.nonce || receipt['candidateSha256'] !== identity.signedSha256 ||
        receipt['targetVersionCode'] !== identity.versionCode || receipt['beforeUid'] !== identity.beforeUid ||
        receipt['bmPid'] !== pid || receipt['format'] !== 'hilog-monotonic-msec' ||
        receipt['pidReservationComplete'] !== true || receipt['reservationPid'] !== authority.reservationPid ||
        receipt['reservationStartTicks'] !== authority.reservationStartTicks || receipt['reservationInode'] !== authority.reservationInode ||
        receipt['baselineComplete'] !== true || receipt['postComplete'] !== true) return undefined;
      const sha = new RegExp('^[0-9a-f]{64}$');
      if (!sha.test(baseline.sha256) || !sha.test(post.sha256) ||
        authority.baselineBytes !== baseline.bytes.byteLength || authority.baselineSha256 !== baseline.sha256 ||
        process['baselineBytes'] !== baseline.bytes.byteLength || process['baselineSha256'] !== baseline.sha256 ||
        receipt['baselineBytes'] !== baseline.bytes.byteLength || receipt['baselineSha256'] !== baseline.sha256 ||
        receipt['postBytes'] !== post.bytes.byteLength || receipt['postSha256'] !== post.sha256) return undefined;
      // 原始字节前缀不能用trim/排序/替换字符归一化；完整行边界防止把截断末行当有效baseline。
      if (post.bytes.byteLength < baseline.bytes.byteLength) return undefined;
      for (let i = 0; i < baseline.bytes.byteLength; i++) if (baseline.bytes[i] !== post.bytes[i]) return undefined;
      if (baseline.bytes.byteLength > 0 && baseline.bytes[baseline.bytes.byteLength - 1] !== 10) return undefined;
      if (post.bytes.byteLength === 0 || post.bytes[post.bytes.byteLength - 1] !== 10) return undefined;
      util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(baseline.bytes);
      const suffix = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(post.bytes.slice(baseline.bytes.byteLength));
      const lower = start / ticks; let began = false; let ended = false; let code: number | undefined = undefined; let previousSeconds = -1;
      for (const body of suffix.split('\n')) {
        const parsed = BmTerminalEvidence.line(pid, body); if (parsed === undefined) continue;
        // 不比较混合小数；整数秒回退或与当前proc明确不相交仍拒绝。
        if (parsed.seconds < previousSeconds || parsed.seconds + 1 <= lower) return undefined;
        previousSeconds = parsed.seconds;
        const startLine = new RegExp('^\\[main\\.cpp\\(main:[0-9]+\\)\\]bm exec start$').test(parsed.text);
        const endLine = new RegExp('^\\[main\\.cpp\\(main:[0-9]+\\)\\]bm exec end$').test(parsed.text);
        const terminal = new RegExp('^\\[status_receiver_impl\\.cpp\\(OnFinished:[0-9]+\\)\\]on finished result is ([0-9]+),').exec(parsed.text);
        if ((parsed.text.includes('bm exec start') && !startLine) || (parsed.text.includes('bm exec end') && !endLine) ||
          (parsed.text.includes('on finished result is') && terminal === null)) return undefined;
        if (startLine) {
          // 完整baseline采集/fsync可耗时，不能把child出生后的2秒误当exec期限。
          // 来源归属由CLAIM绑定baseline与持续PID预留证明；此处只保持proc粗下界和唯一性。
          if (began) return undefined; began = true; continue;
        }
        if (terminal !== null) {
          if (!began || ended || code !== undefined) return undefined; code = Number(terminal[1]); if (!Number.isSafeInteger(code)) return undefined;
        }
        if (endLine) { if (!began || ended) return undefined; ended = true; }
      }
      if (!began || !ended || code === undefined) return undefined;
      return { kind: code === 0 ? 'bms-success' : 'bms-failure', safeToRelease: true, bmSubmitted: true, code: code,
        message: code === 0 ? '系统安装已完成，等待目标版本身份确认' : '系统安装已明确结束，错误码 ' + code,
        installId: identity.installId, nonce: identity.nonce };
    } catch (_) { return undefined; }
  }
}

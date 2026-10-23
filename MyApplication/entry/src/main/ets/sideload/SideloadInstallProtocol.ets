/**
 * 独立安装执行者的一次性协议。只有经能力核实的后端本次首次发布返回0才授bm执行权；
 * 相同 nonce 的重复进程不得根据已有 decision 恢复执行。回执只包含公开身份与结果，
 * CLI 返回与 BMS OnFinished 分开，没有合格系统终态时始终保持 unknown。
 */
import { SideloadFiles } from './SideloadFiles';

export interface InstallExecutionIdentity {
  installId: string; ownerAttemptId: string; nonce: string; bundleName: string; product: string;
  beforeVersionCode: number; beforeUid: number; versionCode: number; expectedPayloadIdentity: string;
  signedPath: string; signedSha256: string; protocol?: number; legacyTransactionId?: string;
}
/** CLAIM把真实child与exec前的完整日志baseline绑定；整体安装CAS仍是protocol2。 */
export interface BmEvidenceAuthority {
  version: number; pid: number; directory: string; baselineSha256: string; baselineBytes: number;
  reservationPid: number; reservationStartTicks: number; reservationInode: string;
}
export interface InstallExecutionGuards { assertCurrent: () => void; assertForeground: () => void; }
export interface InstallExecutionObservation {
  kind: string; safeToRelease: boolean; bmSubmitted: boolean; code: number; message: string;
  installId: string; nonce: string;
}
/** 异常用于区分等待前台/撤销/存储；一般异常绝不能推断派发后的副作用已停止。 */
export class InstallExecutionError extends Error {
  readonly kind: string;
  constructor(kind: string, message: string) { super(message); this.kind = kind; }
}

export class SideloadInstallProtocol {
  static validate(identity: InstallExecutionIdentity): boolean {
    const id = new RegExp('^[0-9a-f]{32}$');
    return id.test(identity.installId) && id.test(identity.ownerAttemptId) && id.test(identity.nonce) &&
      identity.bundleName === 'com.amcl.launcher' && ['sideload', 'desktop'].indexOf(identity.product) >= 0 &&
      Number.isSafeInteger(identity.beforeUid) && identity.beforeUid > 0 &&
      Number.isSafeInteger(identity.beforeVersionCode) && Number.isSafeInteger(identity.versionCode) &&
      identity.versionCode >= identity.beforeVersionCode && new RegExp('^[0-9a-f]{40}$').test(identity.expectedPayloadIdentity) &&
      new RegExp('^[0-9a-f]{64}$').test(identity.signedSha256) && identity.signedPath.startsWith('/') &&
      !new RegExp('[\r\n\x00\t]').test(identity.signedPath);
  }
  static remote(identity: InstallExecutionIdentity): string {
    if (!SideloadInstallProtocol.validate(identity)) throw new InstallExecutionError('preparation', '安装事务身份无效');
    return '/data/local/tmp/amcl-update-v2-' + identity.beforeUid + '-' + identity.installId;
  }
  /** 使用完全相同的字段生成claim/revoke记录，避免不同attempt/包拼接成一个可信回执。 */
  static record(identity: InstallExecutionIdentity, kind: string, bmSubmitted: boolean, sequence: number, mode: string = 'link'): string {
    return JSON.stringify({ protocol: 2, installId: identity.installId, nonce: identity.nonce,
      candidateSha256: identity.signedSha256, targetVersionCode: identity.versionCode, beforeUid: identity.beforeUid,
      kind: kind, bmSubmitted: bmSubmitted, sequence: sequence, decisionMode: mode });
  }
  /**
   * 无害能力检查只操作本次随机目录，不调用bm、不读用户文件、不修改系统安全开关。
   * 真实验证link的EEXIST不覆写以及文件/目录fsync，命令存在本身不是能力证明。
   */
  static capabilityScript(root: string): string {
    const q = SideloadFiles.quote(root);
    return 'set -eu\numask 077\nmkdir -p ' + q + '\ncd ' + q + '\n' +
      'command -v setsid >/dev/null\ncommand -v fsync >/dev/null\ncommand -v sha256sum >/dev/null\n' +
      'command -v hilog >/dev/null\ncommand -v timeout >/dev/null\ncommand -v wc >/dev/null\ncommand -v dirname >/dev/null\n[ -r /proc/$$/stat ]\n' +
      'printf a > cap-a\nprintf b > cap-b\nfsync cap-a cap-b\n' +
      'if command -v link >/dev/null 2>&1 && link cap-a cap-decision 2>/dev/null; then\n' +
      '  if link cap-b cap-decision 2>/dev/null; then exit 41; fi\n  mode=link\n' +
      'else\n  command -v flock >/dev/null\n  : > cap-lock\n  exec 0<>cap-lock\n  flock -xn 0\n' +
      // 目标shell不继承fd9，标准fd0已真机验证保留同open-file-description。
      '  child=$(sh -c \'exec 0<>cap-lock; if flock -xn 0; then echo BAD_LOCK; else echo BLOCKED_LOCK; fi\')\n' +
      '  [ "$child" = BLOCKED_LOCK ]\n  cp cap-a cap-decision.pending\n  fsync cap-decision.pending\n' +
      '  mv cap-decision.pending cap-decision\n  fsync .\n  mode=flock-rename\nfi\n' +
      '[ "$(cat cap-decision)" = a ]\nfsync .\nrm -f cap-a cap-b cap-decision\nfsync .\n' +
      // PGID/SID/PID预留是新终态证据的必要平台能力；probe没有bm安装，失败不发布能力标记。
      'sh -c ' + SideloadInstallProtocol.quoteScript_(SideloadInstallProtocol.reservationProbeScript(root)) + ' > cap-reservation.log 2>&1\nfsync cap-reservation.log\n' +
      'printf "AMCL_INSTALL_CAPABILITY_V2:%s" "$mode"\n';
  }
  /**
   * 单调时间轴的无害校准：child先写自己的proc startTicks和真实CLK_TCK再exec同PID
   * 的bm帮助命令，不包含候选路径、不提交安装。实际区间由BmTerminalEvidence核对。
   */
  static clockCalibrationScript(identity: InstallExecutionIdentity, remote: string, clockTicks: number): string {
    if (!Number.isInteger(clockTicks) || clockTicks <= 0) throw new InstallExecutionError('preparation', '时钟滴答未知');
    const quote = SideloadFiles.quote;
    const format = '{"installId":"' + identity.installId + '","nonce":"' + identity.nonce +
      '","bmPid":%s,"startTicks":%s,"clockTicks":' + clockTicks + '}';
    const child = 'ticks=$(cut -d " " -f 22 /proc/$$/stat) || exit 60; ' +
      'case "$ticks" in ""|*[!0-9]*) exit 61;; esac; printf ' + quote(format) +
      ' "$$" "$ticks" > clock-process.json.pending && fsync clock-process.json.pending && ' +
      'mv clock-process.json.pending clock-process.json && fsync . || exit 62; exec bm install -h';
    return 'set -eu\ncd ' + quote(remote) + '\nsh -c ' + quote(child) + ' > clock-help.log 2>&1 &\n' +
      'pid=$!\nwait "$pid"\nhilog -x -P "$pid" -T BMSTool -v monotonic | head -c 65536 > clock-axis.log\nfsync clock-axis.log\n';
  }
  /**
   * 独立worker先核实候选摘要，失败也先以同decision撤销执行权才发整轮NoInvocation。
   * bm使用真实等待参数但退出0仍只记录CLI_RETURNED；未取得系统OnFinished不删除candidate。
   * aa重开只作观察通道，应用的新版本也不能替代BMS终态/一次执行权收尾的判断。
   */
  static workerScript(identity: InstallExecutionIdentity, remote: string, clockTicks: number, mode: string = 'link'): string {
    if (!SideloadInstallProtocol.validate(identity) || ['link', 'flock-rename'].indexOf(mode) < 0) throw new InstallExecutionError('preparation', '安装协议后端无效');
    if (!Number.isInteger(clockTicks) || clockTicks < 1 || clockTicks > 1000000) throw new InstallExecutionError('preparation', '系统单调时间能力未核实');
    const quote = SideloadFiles.quote;
    const record = (kind: string, submitted: boolean, seq: number): string => quote(SideloadInstallProtocol.record(identity, kind, submitted, seq, mode));
    const decision = SideloadInstallProtocol.decisionFunction(mode);
    // 每个child独占自己的目录。CLAIM直接绑定该目录和baseline摘要，输家不能覆写赢家proc/日志。
    // 完整采集先于CLAIM；超时、超界、fsync失败走原子REVOKE，不产生“已claim但未采到baseline”。
    const publish = 'publish() { temporary="$1.pending.$$"; printf "%s" "$2" > "$temporary" && fsync "$temporary" && [ "$(cat "$temporary")" = "$2" ] && mv "$temporary" "$1" && fsync "$(dirname "$1")"; }\n';
    const capture = SideloadInstallProtocol.captureFunction();
    const reservation = SideloadInstallProtocol.reservationFunctions();
    const preflight = 'preflight_failed() {\n  if [ -n "$directory" ] && [ -f "$directory/reservation-lock" ]; then release_pid || true; fi\n' +
      '  if decide revoke.record; then\n    publish result.json ' + record('pre-install-failed', false, 4) + '\n  fi\n  exit 52\n}\n';
    const commonFields = SideloadInstallProtocol.record(identity, 'claimed', true, 2, mode).slice(0, -1);
    const processFormat = '{"installId":"' + identity.installId + '","nonce":"' + identity.nonce +
      '","bmPid":%s,"startTicks":%s,"clockTicks":' + clockTicks +
      ',"bmEvidenceVersion":1,"baselineBytes":%s,"baselineSha256":"%s","bmGroup":%s,"bmSession":%s,' +
      '"reservationPid":%s,"reservationStartTicks":%s,"reservationInode":"%s"}';
    const claimFormat = commonFields + ',"bmEvidenceVersion":1,"bmEvidenceDirectory":"bm-evidence-%s",' +
      '"bmPid":%s,"baselineBytes":%s,"baselineSha256":"%s","bmGroup":%s,"bmSession":%s,' +
      '"reservationPid":%s,"reservationStartTicks":%s,"reservationInode":"%s"}';
    const child = 'set -u\ndirectory=""\n' + publish + decision + capture + reservation + preflight +
      'directory="bm-evidence-$$"\nmkdir "$directory" || preflight_failed\nreserve_pid || preflight_failed\nexec > "$directory/bm.log" 2>&1\n' +
      'ticks=$(cut -d " " -f 22 /proc/$$/stat) || preflight_failed\n' +
      'case "$ticks" in ""|*[!0-9]*) preflight_failed;; esac\n' +
      'capture_snapshot "$directory/bm-before.log" "$$" || preflight_failed\n' +
      'baseline_bytes=$(wc -c < "$directory/bm-before.log")\n' +
      'baseline_hash=$(sha256sum "$directory/bm-before.log" | cut -d " " -f 1)\n' +
      'publish "$directory/bm-process.json" "$(printf ' + quote(processFormat) + ' "$$" "$ticks" "$baseline_bytes" "$baseline_hash" "$$" "$$" "$reservation_pid" "$reservation_start" "$reservation_inode")" || preflight_failed\n' +
      'publish "$directory/claim.record" "$(printf ' + quote(claimFormat) + ' "$$" "$$" "$baseline_bytes" "$baseline_hash" "$$" "$$" "$reservation_pid" "$reservation_start" "$reservation_inode")" || preflight_failed\n' +
      // 已有同nonce decision也必须退出；赢得首次CAS后不再进行会失败的准备IO，直接exec同PID。
      'reservation_alive "$$" || preflight_failed\nif ! decide "$directory/claim.record"; then release_pid || true; exit 53; fi\n' +
      'exec bm install -r -p candidate.hap -w 600 -u ' + Math.floor(identity.beforeUid / 200000);
    const evidenceFormat = '{"protocol":2,"bmEvidenceVersion":1,"installId":"' + identity.installId +
      '","nonce":"' + identity.nonce + '","candidateSha256":"' + identity.signedSha256 +
      '","targetVersionCode":' + identity.versionCode + ',"beforeUid":' + identity.beforeUid +
      ',"bmPid":%s,"format":"hilog-monotonic-msec","baselineComplete":true,"postComplete":true,' +
      '"baselineBytes":%s,"baselineSha256":"%s","postBytes":%s,"postSha256":"%s",' +
      '"pidReservationComplete":true,"reservationPid":%s,"reservationStartTicks":%s,"reservationInode":"%s"}';
    return '#!/bin/sh\nset -u\numask 077\ndirectory=""\ncd ' + quote(remote) + ' || exit 50\n' +
      publish + decision + capture + reservation + preflight +
      'actual=$(sha256sum candidate.hap 2>/dev/null | cut -d " " -f 1)\n' +
      '[ "$actual" = ' + quote(identity.signedSha256) + ' ] || preflight_failed\n' +
      'publish started.json ' + record('started', false, 1) + ' || preflight_failed\n' +
      'setsid sh -c ' + SideloadInstallProtocol.quoteScript_(child) + ' &\nbm_pid=$!\nwait "$bm_pid"\nbm_code=$?\n' +
      'directory="bm-evidence-$bm_pid"\n' +
      // 只有自己的child首次CLAIM赢家可以封CLI结果；不能根据“已有claimed”复活执行权。
      '[ -f "$directory/claim.record" ] && [ "$(cat decision)" = "$(cat "$directory/claim.record")" ] || exit 53\n' +
      // wait已返回只证明CLI结束，先保存该诊断；终态仍必须等完整post及预留PID证明。
      'publish result.json ' + record('cli-returned', true, 3) + ' || exit 56\n' +
      // worker与前台核实可以同时抵达封账。双方共用child预建且不替换的同一锁，
      // 锁内复查sealed；已封账后的post/receipt不能被另一采集者覆盖。
      'seal_parent() {\n[ -f "$directory/evidence-seal-lock" ] || return 57\n' +
      'exec 0<>"$directory/evidence-seal-lock" || return 57\nflock -xn 0 || return 57\n' +
      'if [ -f "$directory/bm-log-evidence.json" ]; then return 0; fi\n' +
      'read reservation_pid reservation_start ready_pgrp ready_sid reservation_inode < "$directory/reservation.ready" || return 57\n' +
      'reservation_alive "$bm_pid" || return 57\n' +
      'capture_snapshot "$directory/bm-terminal.log" "$bm_pid" || return 57\n' +
      'reservation_alive "$bm_pid" || return 57\n' +
      'baseline_bytes=$(wc -c < "$directory/bm-before.log")\nbaseline_hash=$(sha256sum "$directory/bm-before.log" | cut -d " " -f 1)\n' +
      'post_bytes=$(wc -c < "$directory/bm-terminal.log")\npost_hash=$(sha256sum "$directory/bm-terminal.log" | cut -d " " -f 1)\n' +
      'publish "$directory/bm-log-evidence.json" "$(printf ' + quote(evidenceFormat) +
      ' "$bm_pid" "$baseline_bytes" "$baseline_hash" "$post_bytes" "$post_hash" "$reservation_pid" "$reservation_start" "$reservation_inode")" || return 58\n' +
      'release_pid || true\n}\nseal_status=0\nseal_parent || seal_status=$?\n' +
      'printf "%s" "$bm_code" > "$directory/bm-exit.txt"\nfsync "$directory/bm-exit.txt"\n' +
      // 日志采集失败仍尝试重开原应用/新版本，让用户看到待核实并由原观察入口恢复。
      // 重开不授予终态、清fence或第二次bm执行权，seal失败仍以非零结果保留现场。
      'aa start -b com.amcl.launcher -m entry -a EntryAbility --ps amclSideloadUpdateTransaction ' + identity.installId +
      ' --ps amclSideloadUpdateNonce ' + identity.nonce + ' > start.log 2>&1\nexit "$seal_status"\n';
  }
  /**
   * 两次snapshot均用同一msec格式。timeout和文件上限约束完整命令，绝不用head截断后假装成功。
   * 输出必须正常EOF、退出0、小于64KiB且文件/目录同步成功；空文件仍保留真实存在及SHA。
   */
  private static captureFunction(): string {
    return 'capture_snapshot() {\n  snapshot="$1"; log_pid="$2"; temporary="$snapshot.pending.$$"\n' +
      '  (ulimit -f 128 && timeout 15 hilog -x -P "$log_pid" -T BMSTool -v monotonic > "$temporary") || return 1\n' +
      '  bytes=$(wc -c < "$temporary") || return 1\n  [ "$bytes" -ge 0 ] && [ "$bytes" -lt 65536 ] || return 1\n' +
      '  fsync "$temporary" && mv "$temporary" "$snapshot" && fsync "$(dirname "$snapshot")"\n}\n';
  }
  /**
   * 用真实会话/进程组成员保留BM leader的数字PID，不能假设shell延迟wait就能保留zombie。
   * POSIX Process ID Reuse规定同数字进程组存活时PID不得复用；Linux源码只是公开实现例子，
   * 商用Kernel支持必须由当前设备无安装probe确认。leader已wait回收后，同组sentinel仍
   * 保留该数字身份。私有flock及同一proc incarnation前后核对防止
   * sentinel丢失被当成预留有效。ready/锁inode不替换，release只在完整post封账以后发布。
   */
  static reservationFunctions(): string {
    const sentinel = 'set -eu\ntrap "" HUP\ndirectory="$1"; leader="$2"\n' +
      'exec 0<>"$directory/reservation-lock"\nflock -xn 0\n' +
      'ticks=$(cut -d " " -f 22 /proc/$$/stat)\npgrp=$(cut -d " " -f 5 /proc/$$/stat)\nsid=$(cut -d " " -f 6 /proc/$$/stat)\n' +
      '[ "$pgrp" = "$leader" ] && [ "$sid" = "$leader" ]\ninode=$(stat -c %i "$directory/reservation-lock")\n' +
      'printf "%s %s %s %s %s\\n" "$$" "$ticks" "$pgrp" "$sid" "$inode" > "$directory/reservation.ready.pending"\n' +
      'fsync "$directory/reservation.ready.pending"\nmv "$directory/reservation.ready.pending" "$directory/reservation.ready"\nfsync "$directory"\n' +
      // 未封账可能跨越页面/进程寿命；一秒轮询保持预留而不长期每秒派生十个sleep。
      'while [ ! -f "$directory/release-reservation" ]; do sleep 1; done\n';
    return 'reservation_pid=0\nreservation_start=0\nreservation_inode=0\n' +
      'reservation_alive() {\n  leader="$1"\n' +
      '  [ -f "$directory/reservation.ready" ] && [ -f "$directory/reservation-lock" ] || return 1\n' +
      '  read ready_pid ready_start ready_pgrp ready_sid ready_inode < "$directory/reservation.ready" || return 1\n' +
      '  [ "$ready_pid" = "$reservation_pid" ] && [ "$ready_start" = "$reservation_start" ] && [ "$ready_inode" = "$reservation_inode" ] || return 1\n' +
      '  [ "$ready_pgrp" = "$leader" ] && [ "$ready_sid" = "$leader" ] || return 1\n' +
      '  [ "$(cut -d " " -f 22 /proc/$reservation_pid/stat)" = "$reservation_start" ] || return 1\n' +
      '  [ "$(cut -d " " -f 5 /proc/$reservation_pid/stat)" = "$leader" ] && [ "$(cut -d " " -f 6 /proc/$reservation_pid/stat)" = "$leader" ] || return 1\n' +
      '  [ "$(stat -c %i "$directory/reservation-lock")" = "$reservation_inode" ] || return 1\n' +
      '  lock_status=0\n  (exec 0<>"$directory/reservation-lock" || exit 20; flock -xn 0) || lock_status=$?\n' +
      '  [ "$lock_status" -eq 1 ]\n}\n' +
      'reserve_pid() {\n' +
      '  [ "$(cut -d " " -f 5 /proc/$$/stat)" = "$$" ] && [ "$(cut -d " " -f 6 /proc/$$/stat)" = "$$" ] || return 1\n' +
      '  : > "$directory/reservation-lock"\n  : > "$directory/evidence-seal-lock"\n' +
      '  fsync "$directory/reservation-lock" "$directory/evidence-seal-lock" && fsync "$directory" || return 1\n' +
      '  sh -c ' + SideloadInstallProtocol.quoteScript_(sentinel) + ' reservation "$directory" "$$" &\n  reservation_pid=$!\n' +
      '  n=0\n  while [ ! -f "$directory/reservation.ready" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done\n' +
      '  [ -f "$directory/reservation.ready" ] || return 1\n' +
      '  read ready_pid reservation_start ready_pgrp ready_sid reservation_inode < "$directory/reservation.ready" || return 1\n' +
      '  reservation_alive "$$"\n}\n' +
      'release_pid() { printf release > "$directory/release-reservation" && fsync "$directory/release-reservation" && fsync "$directory"; }\n';
  }
  /** 无安装能力probe直接复用生产sentinel/检查函数，只产生自身随机目录及公开PID收据。 */
  static reservationProbeScript(remote: string): string {
    const quote = SideloadFiles.quote;
    const child = 'set -eu\n' + SideloadInstallProtocol.reservationFunctions() +
      'directory="bm-evidence-$$"\nmkdir "$directory"\nreserve_pid\n' +
      'printf "LEADER=%s START=%s PGID=%s SID=%s SENTINEL=%s SENTINEL_START=%s INODE=%s\\n" "$$" "$(cut -d " " -f 22 /proc/$$/stat)" "$(cut -d " " -f 5 /proc/$$/stat)" "$(cut -d " " -f 6 /proc/$$/stat)" "$reservation_pid" "$reservation_start" "$reservation_inode" > "$directory/probe-leader.txt"\n' +
      'fsync "$directory/probe-leader.txt"\nfsync "$directory"\nreservation_alive "$$"\nprintf "BEFORE_HELD\\n"\n';
    return 'set -eu\numask 077\ncd ' + quote(remote) + '\n' + SideloadInstallProtocol.reservationFunctions() +
      'setsid sh -c ' + SideloadInstallProtocol.quoteScript_(child) + ' > probe-child.log 2>&1 &\nleader_pid=$!\nwait "$leader_pid"\n' +
      'directory="bm-evidence-$leader_pid"\nread reservation_pid reservation_start ready_pgrp ready_sid reservation_inode < "$directory/reservation.ready"\n' +
      'reservation_alive "$leader_pid"\ncat "$directory/probe-leader.txt"\ncat "$directory/reservation.ready"\nprintf "AFTER_LEADER_EXIT_HELD\\n"\n' +
      'test ! -e /proc/$leader_pid/stat\ntimeout 5 hilog -x -P "$leader_pid" -T BMSTool -v monotonic > "$directory/probe-empty-baseline.log"\n' +
      'printf "EMPTY_BASELINE_BYTES="\nwc -c < "$directory/probe-empty-baseline.log"\nreservation_alive "$leader_pid"\n' +
      'code=0\ntimeout 1 sh -c "sleep 2" || code=$?\n[ "$code" -ne 0 ]\nprintf "TIMEOUT_ENFORCED\\n"\n' +
      'reservation_alive "$leader_pid"\nrelease_pid\nprintf "OWN_PROBE_RELEASED\\n"\n';
  }
  /** 只引用本类生成的固定多行脚本。路径/外部值仍用SideloadFiles.quote且拒绝换行；不开放用户脚本入口。 */
  private static quoteScript_(body: string): string {
    if (body.includes('\x00')) throw new InstallExecutionError('preparation', '内部安装配方无效');
    return "'" + body.replace(new RegExp("'", 'g'), "'\\''") + "'";
  }
  /** 撤销与worker的claim竞争同一decision；CLAIM输家绝不能写整轮失败回执。 */
  static revokeScript(identity: InstallExecutionIdentity, remote: string, source: string = 'revoke.record', mode: string = 'link'): string {
    if (!SideloadInstallProtocol.validate(identity)) throw new InstallExecutionError('preparation', '撤销事务身份无效');
    if (source !== 'revoke.record' && !new RegExp('^revoke-[0-9a-f]{32}\\.record$').test(source)) throw new InstallExecutionError('preparation', '撤销记录路径无效');
    return 'set -eu\ncd ' + SideloadFiles.quote(remote) + '\n' +
      SideloadInstallProtocol.decisionFunction(mode) +
      'if decide ' + SideloadFiles.quote(source) + '; then :; fi\ncat decision\n';
  }
  /**
   * 两种经验证的首次决定后端。flock模式全部参与者打开永不替换的同一锁inode，
   * 只有本进程在锁内发现无decision并成功发布、同步记录才返回0；已有同nonce也失败。
   * fd0在worker/bm执行窗口保留；revoker非阻塞，不能为等系统安装而卡住UI。
   */
  static decisionFunction(mode: string): string {
    if (mode === 'link') return 'decide() { fsync "$1" && link "$1" decision 2>/dev/null && fsync .; }\n';
    if (mode !== 'flock-rename') throw new InstallExecutionError('preparation', '未知安装协议后端');
    return 'decide() {\n  [ -f decision-lock ] || : > decision-lock\n  exec 0<>decision-lock || return 1\n' +
      '  flock -xn 0 || return 1\n  [ ! -e decision ] || return 1\n  target="decision.pending.$$"\n' +
      '  cp "$1" "$target" && fsync "$target" && mv "$target" decision && fsync .\n}\n';
  }
  /** 新版本证据目录只来自已经匹配全部身份的CLAIM；旧CLAIM没有baseline身份则仍待核实。 */
  static evidenceAuthority(identity: InstallExecutionIdentity, body: string, mode: string): BmEvidenceAuthority | undefined {
    const decision = SideloadInstallProtocol.parse(identity, body, mode);
    if (decision.kind !== 'claimed' || !decision.bmSubmitted) return undefined;
    try {
      const row = JSON.parse(body) as Record<string, Object>;
      const pid = Number(row['bmPid']), bytes = Number(row['baselineBytes']);
      const reservationPid = Number(row['reservationPid']), reservationStart = Number(row['reservationStartTicks']);
      if (row['bmEvidenceVersion'] !== 1 || !Number.isSafeInteger(pid) || pid <= 0 ||
        row['bmEvidenceDirectory'] !== 'bm-evidence-' + pid || !Number.isSafeInteger(bytes) || bytes < 0 || bytes >= 65536 ||
        row['bmGroup'] !== pid || row['bmSession'] !== pid || !Number.isSafeInteger(reservationPid) || reservationPid <= 0 || reservationPid === pid ||
        !Number.isSafeInteger(reservationStart) || reservationStart <= 0 || typeof row['reservationInode'] !== 'string' ||
        !new RegExp('^[0-9]{1,20}$').test(String(row['reservationInode'])) ||
        typeof row['baselineSha256'] !== 'string' || !new RegExp('^[0-9a-f]{64}$').test(String(row['baselineSha256']))) return undefined;
      return { version: 1, pid: pid, directory: String(row['bmEvidenceDirectory']),
        baselineSha256: String(row['baselineSha256']), baselineBytes: bytes, reservationPid: reservationPid,
        reservationStartTicks: reservationStart, reservationInode: String(row['reservationInode']) };
    } catch (_) { return undefined; }
  }
  /**
   * 首次post超时后只读重采，不重新执行bm、不创建baseline、不改变原decision/proc。
   * 只有原sentinel持续保留PID、原CLI已返回且尚无sealed receipt时才能采；已有receipt即保持原字节。
   * 任意保护/采集失败仍保留sentinel和unknown，不能为恢复界面补造完整证据。
   */
  static observeEvidenceScript(identity: InstallExecutionIdentity, authority: BmEvidenceAuthority, decisionBody: string): string {
    if (!SideloadInstallProtocol.validate(identity) || authority.version !== 1 ||
      authority.directory !== 'bm-evidence-' + authority.pid) throw new InstallExecutionError('preparation', '系统观测身份无效');
    const quote = SideloadFiles.quote;
    const format = '{"protocol":2,"bmEvidenceVersion":1,"installId":"' + identity.installId +
      '","nonce":"' + identity.nonce + '","candidateSha256":"' + identity.signedSha256 +
      '","targetVersionCode":' + identity.versionCode + ',"beforeUid":' + identity.beforeUid +
      ',"bmPid":' + authority.pid + ',"format":"hilog-monotonic-msec","baselineComplete":true,"postComplete":true,' +
      '"baselineBytes":%s,"baselineSha256":"%s","postBytes":%s,"postSha256":"%s","pidReservationComplete":true,' +
      '"reservationPid":' + authority.reservationPid + ',"reservationStartTicks":' + authority.reservationStartTicks +
      ',"reservationInode":"' + authority.reservationInode + '"}';
    return 'set -eu\numask 077\ncd ' + quote(SideloadInstallProtocol.remote(identity)) + '\n' +
      SideloadInstallProtocol.captureFunction() + SideloadInstallProtocol.reservationFunctions() +
      'directory=' + quote(authority.directory) + '\nreservation_pid=' + authority.reservationPid +
      '\nreservation_start=' + authority.reservationStartTicks + '\nreservation_inode=' + quote(authority.reservationInode) + '\n' +
      '[ "$(cat decision)" = ' + quote(decisionBody) + ' ]\n' +
      // 只打开child已可靠建立的锁，恢复观察者不能补建另一inode绕过正在封账的worker。
      '[ -f "$directory/evidence-seal-lock" ]\nexec 0<>"$directory/evidence-seal-lock"\nflock -xn 0\n' +
      'if [ -f "$directory/bm-log-evidence.json" ]; then exit 0; fi\n' +
      '[ -f "$directory/bm-before.log" ] && [ -f "$directory/bm-process.json" ]\n' +
      '[ ! -e /proc/' + authority.pid + '/stat ]\nreservation_alive ' + authority.pid + '\n' +
      'capture_snapshot "$directory/bm-terminal.log" ' + authority.pid + '\nreservation_alive ' + authority.pid + '\n' +
      'baseline_bytes=$(wc -c < "$directory/bm-before.log")\nbaseline_hash=$(sha256sum "$directory/bm-before.log" | cut -d " " -f 1)\n' +
      'post_bytes=$(wc -c < "$directory/bm-terminal.log")\npost_hash=$(sha256sum "$directory/bm-terminal.log" | cut -d " " -f 1)\n' +
      'temporary="$directory/bm-log-evidence.json.pending.$$"\nprintf ' + quote(format) +
      ' "$baseline_bytes" "$baseline_hash" "$post_bytes" "$post_hash" > "$temporary"\nfsync "$temporary"\n' +
      'mv "$temporary" "$directory/bm-log-evidence.json"\nfsync "$directory"\nrelease_pid\nprintf AMCL_BM_EVIDENCE_SEALED\n';
  }
  /** 只有原子decision的REVOKED，或配方已可靠封住该decision的NoInvocation才安全解除。 */
  static parse(identity: InstallExecutionIdentity, body: string, mode: string = 'link'): InstallExecutionObservation {
    const unknown: InstallExecutionObservation = { kind: 'unknown', safeToRelease: false, bmSubmitted: true, code: 0,
      message: '尚未取得本次安装的系统终态，保留待核实', installId: identity.installId, nonce: identity.nonce };
    if (body.length > 8192) return unknown;
    try {
      const row = JSON.parse(body) as Record<string, Object>;
      if (row['protocol'] !== 2 || row['installId'] !== identity.installId || row['nonce'] !== identity.nonce ||
        row['candidateSha256'] !== identity.signedSha256 || row['targetVersionCode'] !== identity.versionCode || row['beforeUid'] !== identity.beforeUid) return unknown;
      if (row['decisionMode'] !== mode) return unknown;
      const kind = String(row['kind'] ?? '');
      if (['prepared', 'started', 'claimed', 'cli-returned', 'revoked', 'pre-install-failed'].indexOf(kind) < 0 ||
        typeof row['bmSubmitted'] !== 'boolean') return unknown;
      // 单个preflight输家也可能尚未调用bm，因此NoInvocation结果本身不授清fence权。
      // Executor还须读同decision的REVOKED；本进程未派发证明则由Executor内存owner提供。
      const safe = kind === 'revoked' && row['bmSubmitted'] === false;
      return { kind: kind, safeToRelease: safe, bmSubmitted: row['bmSubmitted'] as boolean, code: 0,
        message: safe ? '本次安装执行权已撤销，原应用保留' : '安装已派发，等待系统终态核实',
        installId: identity.installId, nonce: identity.nonce };
    } catch (_) { return unknown; }
  }
}

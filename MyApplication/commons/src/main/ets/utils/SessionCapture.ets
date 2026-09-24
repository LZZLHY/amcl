/** 启动来源基线：固定实际运行目录，增量检查点不能读取下一次启动的全局文件。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureDirSync } from './FileUtils';
import { evidenceFileStamp, evidenceFileDigestSync, hashGzipEvidenceContent, writeEvidenceTextAtomic } from './EvidenceIo';
import { readSessionEnvironment, environmentValue } from './SessionEnvironment';

export interface CaptureSource {
  source: string;
  destination: string;
  baseline: string;
  captured: string;
  state: string;
  reason: string;
  baselineDigest?: string;
  attribution?: string;
  /** 固定归档收据；封账后不以当前文件重新计算并覆盖这些原始期望值。 */
  capturedBytes?: number;
  capturedSha256?: string;
  mode?: string;
  sealed?: boolean;
}
export interface SessionCapturePlan {
  schema: number;
  activityId: number;
  startedAt: number;
  endedAt: number;
  gameDir: string;
  filesDir: string;
  appFilesDir: string;
  jdk: string;
  sources: CaptureSource[];
}

function stamp(path: string): string {
  try { return evidenceFileStamp(path); } catch (e) { return ''; }
}
function source(plan: SessionCapturePlan, path: string, destination: string,
  baseline: boolean, owned: boolean = false): void {
  const previous = plan.sources.find((item: CaptureSource): boolean => item.destination === destination);
  if (previous !== undefined && (previous.mode === 'owned' || owned)) {
    if (owned && previous.mode !== 'owned') {
      previous.source = path; previous.baseline = ''; previous.baselineDigest = '';
      previous.captured = ''; previous.capturedSha256 = ''; previous.capturedBytes = 0;
      previous.mode = 'owned'; previous.state = 'not-produced'; previous.attribution = 'exact';
    }
    return;
  }
  if (plan.sources.some((item: CaptureSource): boolean => item.source === path)) return;
  let digest: string = '';
  if (baseline && stamp(path).length > 0 && destination === 'game/logs/latest.log') {
    try { digest = evidenceFileDigestSync(path); } catch (e) { /* 无法核验的分片保留不确定归属 */ }
  }
  plan.sources.push({ source: path, destination: destination,
    baseline: baseline ? stamp(path) : '', baselineDigest: digest,
    captured: '', state: 'not-produced', reason: '', attribution: owned ? 'exact' : 'source-baseline',
    mode: owned ? 'owned' : 'snapshot' });
}
function family(plan: SessionCapturePlan, directory: string, destination: string,
  pattern: RegExp, baseline: boolean, owned: boolean = false): void {
  try {
    for (const name of fs.listFileSync(directory)) {
      if (pattern.test(name) && fs.statSync(directory + '/' + name).isFile()) {
        source(plan, directory + '/' + name, destination + '/' + name, baseline, owned);
      }
    }
  } catch (e) { /* 尚未生成目录 */ }
}
function discover(plan: SessionCapturePlan, baseline: boolean): void {
  const dir: string = plan.filesDir + '/logs/ledger/' + plan.activityId;
  const io = nativeSessionIo(plan.filesDir, plan.activityId);
  if (io !== undefined) {
    source(plan, dir + '/game/mc_output.log', 'game/mc_output.log', false, true);
    source(plan, dir + '/jvm/jvm-stderr.log', 'jvm/jvm-stderr.log', false, true);
    family(plan, dir + '/jvm', 'jvm', new RegExp('^(hs_err_pid.*\\.log|gc-amcl\\.log.*)$'), false, true);
  }
  const environment = readSessionEnvironment(plan.filesDir, plan.activityId);
  if (environmentValue(environment, 'logging.configurationStatus') === 'owned') {
    source(plan, dir + '/game/logs/latest.log', 'game/logs/latest.log', false, true);
    family(plan, dir + '/game/logs', 'game/logs', new RegExp('\\.(log|gz)(\\..*)?$'), false, true);
  }
  if (plan.gameDir.length > 0) {
    for (const name of ['latest.log', 'debug.log']) source(plan, plan.gameDir + '/logs/' + name, 'game/logs/' + name, baseline);
    family(plan, plan.gameDir + '/logs', 'game/logs', new RegExp('\\.log\\.gz$'), baseline);
    family(plan, plan.gameDir + '/logs', 'jvm', new RegExp('^gc-amcl\\.log'), baseline);
    family(plan, plan.gameDir + '/crash-reports', 'crash-reports', new RegExp('\\.txt$'), baseline);
    family(plan, plan.gameDir, 'jvm', new RegExp('^hs_err_pid.*\\.log$'), baseline);
  }
  source(plan, plan.filesDir + '/jvm_stderr.log', 'jvm/jvm-stderr.log', baseline);
  source(plan, plan.filesDir + '/logs/system/crash-tail.log', 'system/crash-tail.log', baseline);
  source(plan, plan.filesDir + '/logs/agent-probe.log', 'agent/agent-probe.log', baseline);
  if (plan.jdk.length > 0) family(plan, plan.filesDir + '/jdk/' + plan.jdk, 'jvm', new RegExp('^hs_err_pid.*\\.log$'), baseline);
  if (plan.appFilesDir.length > 0) source(plan, plan.appFilesDir + '/MG/latest.log', 'renderer/mobileglues.log', baseline);
}

/** 原始 IO 状态只接受同活动身份；旧会话没有该状态时不推测重定向或关闭成功。 */
export interface NativeSessionIo {
  schema: number; activityId: number; pid: number; consoleReady: boolean; javaAttached: boolean; ended: boolean; ioError: number;
  gameStarted?: boolean;
}
export function nativeSessionIo(filesDir: string, activityId: number): NativeSessionIo | undefined {
  try {
    const io = JSON.parse(fs.readTextSync(filesDir + '/logs/ledger/' + activityId + '/native-io.json')) as NativeSessionIo;
    return io.schema === 1 && io.activityId === activityId && io.pid > 0 ? io : undefined;
  } catch (e) { return undefined; }
}

/** 已封存目标按固定长度和摘要核验；高精度指纹只作缓存键，首次/变化后必须读全文。 */
const verifiedReceipts: Map<string, string> = new Map<string, string>();
export function verifyCapturedSource(item: CaptureSource, path: string): string {
  if (!item.capturedSha256 || item.capturedBytes === undefined) return '历史文件没有固定的归档校验收据';
  try {
    const stat = fs.statSync(path);
    if (stat.size !== item.capturedBytes) return '文件长度与归档收据不符';
    const before: string = evidenceFileStamp(path);
    const key: string = path + '|' + item.capturedSha256;
    if (stat.mtimeNs !== undefined && stat.ctimeNs !== undefined && verifiedReceipts.get(key) === before) return '';
    if (evidenceFileDigestSync(path) !== item.capturedSha256 || evidenceFileStamp(path) !== before) return '文件内容与归档收据不符';
    if (verifiedReceipts.size >= 512) verifiedReceipts.clear();
    verifiedReceipts.set(key, before);
    return '';
  } catch (e) { return '已归档文件缺失或无法读取'; }
}
function planPath(filesDir: string, activityId: number): string {
  return filesDir + '/logs/ledger/' + activityId + '/capture-sources.json';
}
export function readSessionCapture(filesDir: string, activityId: number): SessionCapturePlan | undefined {
  try { return JSON.parse(fs.readTextSync(planPath(filesDir, activityId))) as SessionCapturePlan; }
  catch (e) { return undefined; }
}

/** 重复 begin 只补充尚未知的源；已经记录的基线绝不重置。 */
export function beginSessionCapture(filesDir: string, activityId: number, gameDir: string,
  appFilesDir: string, jdk: string): void {
  let plan = readSessionCapture(filesDir, activityId);
  if (plan === undefined) {
    plan = { schema: 1, activityId: activityId, startedAt: activityId, endedAt: 0,
      gameDir: gameDir, filesDir: filesDir, appFilesDir: appFilesDir, jdk: jdk, sources: [] };
  }
  if (gameDir.length > 0) plan.gameDir = gameDir;
  if (appFilesDir.length > 0) plan.appFilesDir = appFilesDir;
  if (jdk.length > 0) plan.jdk = jdk;
  discover(plan, true);
  writeEvidenceTextAtomic(planPath(filesDir, activityId), JSON.stringify(plan));
}

/** 只有固定基线之后变更、且未越过下一次启动的源才允许更新检查点。 */
export function checkpointSessionCapture(filesDir: string, activityId: number,
  endedAt: number, nextLaunchAt: number, seal: boolean = false): boolean {
  const plan = readSessionCapture(filesDir, activityId);
  if (plan === undefined) return false;
  plan.endedAt = endedAt;
  discover(plan, false);
  const upper: number = nextLaunchAt > 0 ? nextLaunchAt : endedAt > 0 ? endedAt + 1000 : Date.now() + 1000;
  const io = nativeSessionIo(filesDir, activityId);
  for (const item of plan.sources) {
    const destination: string = filesDir + '/logs/ledger/' + activityId + '/' + item.destination;
    // 一旦固定收据已经封账，读取/重新恢复只能核验，不得把损坏的新内容重新签成完整。
    if (item.capturedSha256 && item.sealed === true) {
      item.sealed = true;
      const issue: string = verifyCapturedSource(item, destination);
      if (issue.length > 0) { item.state = 'partial'; item.reason = issue; }
      continue;
    }
    if (item.capturedSha256 && item.state === 'partial' && item.reason.indexOf('归档收据') >= 0) continue;
    const current: string = stamp(item.source);
    if (item.mode === 'owned') {
      if (current.length === 0) continue;
      try {
        item.capturedBytes = fs.statSync(item.source).size;
        item.capturedSha256 = evidenceFileDigestSync(item.source);
        if (stamp(item.source) !== current) throw new Error('原始输出仍在增长，稍后重新核验');
        item.captured = current;
        item.attribution = 'exact';
        const closed: boolean = endedAt > 0 && io?.ended === true && io.ioError === 0;
        item.state = closed ? 'complete' : endedAt > 0 ? 'partial' : 'writing';
        item.sealed = closed;
        item.reason = closed ? '' : endedAt > 0 ? '原始输出没有有序关闭证明；已保留当前落盘范围' : '原始输出仍在写入';
      } catch (e) { item.state = 'partial'; item.reason = (e as Error).message; }
      continue;
    }
    if (current === item.captured && current.length > 0) {
      if (endedAt > 0 && item.state === 'writing') item.state = 'complete';
      if (seal && item.capturedSha256) item.sealed = true;
      continue;
    }
    if (current.length === 0 || current === item.baseline) continue;
    const modified: number = fs.statSync(item.source).mtime * 1000;
    if (modified < plan.startedAt - 1000 || modified >= upper) continue;
    // 下一局已开始时不再补采可覆盖全局文件；旧账本保留自己的最后检查点。
    if (nextLaunchAt > 0 && Date.now() >= nextLaunchAt) continue;
    const temporary: string = destination + '.partial';
    try {
      ensureDirSync(destination.substring(0, destination.lastIndexOf('/')));
      fs.copyFileSync(item.source, temporary);
      if (stamp(item.source) !== current || fs.statSync(temporary).size !== fs.statSync(item.source).size) {
        throw new Error('复制期间来源发生变化，将在下个检查点重试');
      }
      const digest: string = evidenceFileDigestSync(temporary);
      if (evidenceFileDigestSync(item.source) !== digest) throw new Error('来源内容校验失败');
      const saved = fs.openSync(temporary, fs.OpenMode.READ_WRITE);
      try { fs.fsyncSync(saved.fd); } finally { fs.closeSync(saved); }
      fs.renameSync(temporary, destination);
      item.captured = current;
      item.capturedBytes = fs.statSync(destination).size;
      item.capturedSha256 = digest;
      item.sealed = seal;
      item.state = endedAt > 0 ? 'complete' : 'writing';
      item.reason = '';
      // Log4j 启动轮转可能压缩上一局 latest；保留原件但不冒称精确归属。
      if (item.destination.endsWith('.gz')) {
        item.state = 'partial'; item.reason = '压缩轮转分片需核验会话边界；可能包含启动前的 latest';
        item.attribution = 'ambiguous';
      }
    } catch (e) {
      item.state = 'partial'; item.reason = (e as Error).message;
      try { fs.unlinkSync(temporary); } catch (ignored) { /* 尚未创建 */ }
    }
  }
  writeEvidenceTextAtomic(planPath(filesDir, activityId), JSON.stringify(plan));
  return true;
}

/** 旧工作 stdout 的精确复制也保存固定收据，不能只有新 owned 路径才验证内容。 */
export function recordArchivedSessionSource(filesDir: string, activityId: number,
  sourcePath: string, destination: string): void {
  const plan = readSessionCapture(filesDir, activityId);
  if (plan === undefined) return;
  const existing = plan.sources.find((item: CaptureSource): boolean => item.destination === destination);
  if (existing?.sealed === true || existing?.mode === 'owned') return;
  const path: string = filesDir + '/logs/ledger/' + activityId + '/' + destination;
  try {
    const digest: string = evidenceFileDigestSync(path);
    if (digest !== evidenceFileDigestSync(sourcePath)) throw new Error('游戏输出归档内容校验失败');
    const item: CaptureSource = { source: sourcePath, destination: destination, baseline: '',
      captured: stamp(sourcePath), capturedBytes: fs.statSync(path).size, capturedSha256: digest,
      state: 'complete', reason: '', attribution: 'exact', mode: 'legacy-archive', sealed: true };
    if (existing !== undefined) plan.sources = plan.sources.filter((record: CaptureSource): boolean => record !== existing);
    plan.sources.push(item);
    writeEvidenceTextAtomic(planPath(filesDir, activityId), JSON.stringify(plan));
  } catch (e) { /* 失败保持未核验，不能签发新的完整收据。 */ }
}

/** 启动产生的旧 latest 轮转与当前会话分片区分；归属确认前不会默认上传。 */
export async function verifySessionCaptureRotations(filesDir: string, activityId: number): Promise<void> {
  const plan = readSessionCapture(filesDir, activityId);
  if (plan === undefined) return;
  const baseline = plan.sources.find((item: CaptureSource): boolean => item.destination === 'game/logs/latest.log');
  for (const item of plan.sources) {
    if (!item.destination.endsWith('.gz') || item.captured.length === 0 || item.attribution !== 'ambiguous') continue;
    // 有旧 latest 却没有基线摘要时不能排除前局内容。
    if ((baseline?.baseline ?? '').length > 0 && !(baseline?.baselineDigest ?? '').length) continue;
    const path: string = filesDir + '/logs/ledger/' + activityId + '/' + item.destination;
    try {
      const issue: string = verifyCapturedSource(item, path);
      if (issue.length > 0) { item.state = 'partial'; item.reason = issue; continue; }
      const digest: string = await hashGzipEvidenceContent(path);
      if (digest === baseline?.baselineDigest) {
        item.attribution = 'previous-session'; item.reason = '启动时轮转的上一局 latest，已排除默认分享';
      } else {
        item.attribution = 'source-baseline'; item.state = plan.endedAt > 0 ? 'complete' : 'writing'; item.reason = '';
      }
    } catch (e) { item.state = 'partial'; item.reason = 'gzip 会话边界校验失败：' + (e as Error).message; }
  }
  writeEvidenceTextAtomic(planPath(filesDir, activityId), JSON.stringify(plan));
}

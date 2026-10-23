/** 启动来源基线：固定实际运行目录，增量检查点不能读取下一次启动的全局文件。 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ensureDirSync } from './FileUtils';
import { evidenceFileStamp, evidenceFileDigestSync, hashGzipEvidenceContent, writeEvidenceTextAtomic,
  evidenceFileStampAsync, evidenceFileDigestAsync, writeEvidenceTextAtomicAsync, ensureEvidenceDirectoryAsync,
  assertEvidencePreparationCurrent, EvidencePreparationStaleError, noteEvidencePublicationUnknown } from './EvidenceIo';
import { AtomicWriteError } from './AtomicFileWriter';
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
  const previousText: string = JSON.stringify(plan);
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
      // 已知writing/partial不能仅凭恢复时间或seal请求升级complete；真实owned关闭走上方io证明。
      if (seal && item.capturedSha256 && item.state === 'complete') item.sealed = true;
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
  const nextText: string = JSON.stringify(plan);
  if (nextText !== previousText) writeEvidenceTextAtomic(planPath(filesDir, activityId), nextText);
  return true;
}

/** 异步恢复读基线：不存在返回undefined；保留旧schema原件，不用新进程环境补造来源。 */
export async function readSessionCaptureAsync(filesDir: string, activityId: number): Promise<SessionCapturePlan | undefined> {
  try { return JSON.parse(await fs.readText(planPath(filesDir, activityId))) as SessionCapturePlan; }
  catch (error) { if ((error as BusinessError).code === 13900002 || error instanceof SyntaxError) return undefined; throw error as Error; }
}

/** 新活动异步固定启动前来源基线；必须在本局producer启动之前await完成，旧基线绝不重置。 */
export async function beginSessionCaptureAsync(filesDir: string, activityId: number, gameDir: string,
  appFilesDir: string, jdk: string): Promise<void> {
  let plan = await readSessionCaptureAsync(filesDir, activityId);
  const previousText: string = plan === undefined ? '' : JSON.stringify(plan);
  if (plan === undefined) plan = { schema: 1, activityId: activityId, startedAt: activityId, endedAt: 0,
    gameDir: gameDir, filesDir: filesDir, appFilesDir: appFilesDir, jdk: jdk, sources: [] };
  if (gameDir.length > 0) plan.gameDir = gameDir;
  if (appFilesDir.length > 0) plan.appFilesDir = appFilesDir;
  if (jdk.length > 0) plan.jdk = jdk;
  const known: Set<string> = new Set<string>(plan.sources.map((item: CaptureSource): string => item.destination));
  await discoverAsync_(plan);
  // 固定文件即使尚未生成也登记not-produced；后续不能把首次发现时刻补造成启动前基线。
  const fixedSources: string[] = [plan.filesDir + '/jvm_stderr.log', plan.filesDir + '/logs/system/crash-tail.log', plan.filesDir + '/logs/agent-probe.log'];
  const fixedTargets: string[] = ['jvm/jvm-stderr.log', 'system/crash-tail.log', 'agent/agent-probe.log'];
  if (plan.gameDir.length > 0) {
    fixedSources.push(plan.gameDir + '/logs/latest.log', plan.gameDir + '/logs/debug.log');
    fixedTargets.push('game/logs/latest.log', 'game/logs/debug.log');
  }
  if (plan.appFilesDir.length > 0) { fixedSources.push(plan.appFilesDir + '/MG/latest.log'); fixedTargets.push('renderer/mobileglues.log'); }
  for (let index: number = 0; index < fixedSources.length; index++) {
    const destination: string = fixedTargets[index];
    if (!plan.sources.some((item: CaptureSource): boolean => item.destination === destination)) {
      plan.sources.push({ source: fixedSources[index], destination: destination, baseline: '', baselineDigest: '',
        captured: '', state: 'not-produced', reason: '', attribution: 'source-baseline', mode: 'snapshot' });
    }
  }
  for (const item of plan.sources) {
    if (known.has(item.destination) || item.mode === 'owned') continue;
    try {
      item.baseline = await evidenceFileStampAsync(item.source);
      if (item.destination === 'game/logs/latest.log') item.baselineDigest = await evidenceFileDigestAsync(item.source);
    } catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
  }
  const text: string = JSON.stringify(plan);
  if (text !== previousText) await writeEvidenceTextAtomicAsync(planPath(filesDir, activityId), text);
}

/** 已封存文件在真正异步IO上按固定收据核验；缓存仍只接受纳秒指纹。 */
export async function verifyCapturedSourceAsync(item: CaptureSource, path: string): Promise<string> {
  if (!item.capturedSha256 || item.capturedBytes === undefined) return '历史文件没有固定的归档校验收据';
  try {
    const stat = await fs.stat(path);
    if (stat.size !== item.capturedBytes) return '文件长度与归档收据不符';
    const before: string = await evidenceFileStampAsync(path);
    const key: string = path + '|' + item.capturedSha256;
    if (stat.mtimeNs !== undefined && stat.ctimeNs !== undefined && verifiedReceipts.get(key) === before) return '';
    if (await evidenceFileDigestAsync(path) !== item.capturedSha256 || await evidenceFileStampAsync(path) !== before) return '文件内容与归档收据不符';
    if (verifiedReceipts.size >= 512) verifiedReceipts.clear();
    verifiedReceipts.set(key, before); return '';
  } catch (_) { return '已归档文件缺失或无法读取'; }
}

/** 原生状态是小型原子记录；同活动校验与同步API一致。 */
export async function nativeSessionIoAsync(filesDir: string, activityId: number): Promise<NativeSessionIo | undefined> {
  try {
    const io = JSON.parse(await fs.readText(filesDir + '/logs/ledger/' + activityId + '/native-io.json')) as NativeSessionIo;
    return io.schema === 1 && io.activityId === activityId && io.pid > 0 ? io : undefined;
  } catch (error) { if ((error as BusinessError).code === 13900002 || error instanceof SyntaxError) return undefined; throw error as Error; }
}

/** 只登记基线已知文件之外新产生的同族来源；恢复不能建立新的“启动前基线”。 */
async function familyAsync_(plan: SessionCapturePlan, directory: string, destination: string, pattern: RegExp, owned: boolean = false): Promise<void> {
  let names: string[];
  try { names = await fs.listFile(directory); }
  catch (error) { if ((error as BusinessError).code === 13900002) return; throw error as Error; }
  for (const name of names) {
    if (!pattern.test(name)) continue;
    try {
      if (!(await fs.stat(directory + '/' + name)).isFile()) continue;
      const path: string = directory + '/' + name;
      const remote: string = destination + '/' + name;
      const previous = plan.sources.find((item: CaptureSource): boolean => item.destination === remote);
      if (previous !== undefined) {
        if (owned && previous.mode !== 'owned') {
          previous.source = path; previous.baseline = ''; previous.baselineDigest = '';
          previous.captured = ''; previous.capturedSha256 = ''; previous.capturedBytes = 0;
          previous.mode = 'owned'; previous.state = 'not-produced'; previous.attribution = 'exact'; previous.sealed = false;
        }
        continue;
      }
      if (plan.sources.some((item: CaptureSource): boolean => item.source === path)) continue;
      plan.sources.push({ source: path, destination: remote, baseline: '', baselineDigest: '', captured: '',
        state: 'not-produced', reason: '', attribution: owned ? 'exact' : 'source-baseline', mode: owned ? 'owned' : 'snapshot' });
    } catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; /* 来源消失保留已有记录。 */ }
  }
}

/**
 * 恢复单局来源发现只使用SDK异步目录/元数据IO。已知owned来源不重新设基线；
 * 与同步discover一致发现轮转、崩溃及JVM同族文件，跨局界限由检查点随后复核。
 */
async function discoverAsync_(plan: SessionCapturePlan): Promise<void> {
  const dir: string = plan.filesDir + '/logs/ledger/' + plan.activityId;
  const io = await nativeSessionIoAsync(plan.filesDir, plan.activityId);
  if (io !== undefined) {
    for (const name of ['game/mc_output.log', 'jvm/jvm-stderr.log']) {
      const previous = plan.sources.find((item: CaptureSource): boolean => item.destination === name);
      if (previous === undefined) {
        plan.sources.push({ source: dir + '/' + name, destination: name, baseline: '', baselineDigest: '', captured: '',
          state: 'not-produced', reason: '', attribution: 'exact', mode: 'owned' });
      } else if (previous.mode !== 'owned') {
        // native重定向确已绑定本局后，兼容工作文件不再承担唯一来源；不能继续读取跨局global stderr。
        previous.source = dir + '/' + name; previous.baseline = ''; previous.baselineDigest = '';
        previous.captured = ''; previous.capturedSha256 = ''; previous.capturedBytes = 0;
        previous.mode = 'owned'; previous.state = 'not-produced'; previous.attribution = 'exact'; previous.sealed = false;
      }
    }
    await familyAsync_(plan, dir + '/jvm', 'jvm', new RegExp('^(hs_err_pid.*\\.log|gc-amcl\\.log.*)$'), true);
  }
  // 环境记录只读本局的小型原子JSON，不能调用当前设备环境去修补历史身份。
  let ownedLogging: boolean = false;
  try {
    const environment = JSON.parse(await fs.readText(dir + '/environment.json')) as Record<string, Object>;
    const facts = environment['facts'] as Record<string, Object>[];
    ownedLogging = Array.isArray(facts) && facts.some((fact: Record<string, Object>): boolean => fact['key'] === 'logging.configurationStatus' && fact['value'] === 'owned');
  } catch (error) {
    if ((error as BusinessError).code !== 13900002 && !(error instanceof SyntaxError)) throw error as Error;
    /* 无环境说明时只按既有基线采集。 */
  }
  if (ownedLogging) await familyAsync_(plan, dir + '/game/logs', 'game/logs', new RegExp('\\.(log|gz)(\\..*)?$'), true);
  if (plan.gameDir.length > 0) {
    await familyAsync_(plan, plan.gameDir + '/logs', 'game/logs', new RegExp('\\.log\\.gz$'));
    await familyAsync_(plan, plan.gameDir + '/logs', 'jvm', new RegExp('^gc-amcl\\.log'));
    await familyAsync_(plan, plan.gameDir + '/crash-reports', 'crash-reports', new RegExp('\\.txt$'));
    await familyAsync_(plan, plan.gameDir, 'jvm', new RegExp('^hs_err_pid.*\\.log$'));
  }
  if (plan.jdk.length > 0) await familyAsync_(plan, plan.filesDir + '/jdk/' + plan.jdk, 'jvm', new RegExp('^hs_err_pid.*\\.log$'));
}

/**
 * owner串行使用的异步检查点。归属、固定SHA-256收据、下一局边界及partial行为与原API一致；
 * 所有目录枚举/复制/读取/同步均使用真实异步IO，不在Promise续作里回退同步全文件处理。
 * 无变化不重写capture-sources；失败保留来源和旧目标，不能签发新的完整性收据。
 */
export async function checkpointSessionCaptureAsync(filesDir: string, activityId: number,
  endedAt: number, nextLaunchAt: number, seal: boolean = false,
  isCurrent: (() => boolean) | undefined = undefined, trustedEndedAt: boolean = false,
  protectedIntentBoundary: boolean = false): Promise<boolean> {
  assertEvidencePreparationCurrent(isCurrent);
  const plan = await readSessionCaptureAsync(filesDir, activityId);
  if (plan === undefined) return false;
  const previousText: string = JSON.stringify(plan);
  // 已有正边界不随恢复发现时钟移动。调用方只有取得真实退出/精确平台终点才可显式升级；
  // 固定原件收据继续只核验，不能以升级边界重新签损坏正文。
  if (endedAt > 0 && (plan.endedAt <= 0 || trustedEndedAt)) plan.endedAt = endedAt;
  const effectiveEndedAt: number = plan.endedAt;
  await discoverAsync_(plan);
  assertEvidencePreparationCurrent(isCurrent);
  const upper: number = nextLaunchAt > 0 ? nextLaunchAt : effectiveEndedAt > 0 ? effectiveEndedAt + 1000 : Date.now() + 1000;
  const io = await nativeSessionIoAsync(filesDir, activityId);
  for (const item of plan.sources) {
    assertEvidencePreparationCurrent(isCurrent);
    const destination: string = filesDir + '/logs/ledger/' + activityId + '/' + item.destination;
    if (item.capturedSha256 && item.sealed === true) {
      const issue: string = await verifyCapturedSourceAsync(item, destination);
      if (issue.length > 0) { item.state = 'partial'; item.reason = issue; }
      continue;
    }
    if (item.capturedSha256 && item.state === 'partial' && item.reason.indexOf('归档收据') >= 0) continue;
    let current: string = '';
    try { current = await evidenceFileStampAsync(item.source); }
    catch (error) { if ((error as BusinessError).code === 13900002) continue; throw error as Error; }
    if (item.mode === 'owned') {
      try {
        item.capturedBytes = (await fs.stat(item.source)).size;
        item.capturedSha256 = await evidenceFileDigestAsync(item.source);
        assertEvidencePreparationCurrent(isCurrent);
        if (await evidenceFileStampAsync(item.source) !== current) throw new Error('原始输出仍在增长，稍后重新核验');
        item.captured = current; item.attribution = 'exact';
        const closed: boolean = effectiveEndedAt > 0 && io?.ended === true && io.ioError === 0;
        item.state = closed ? 'complete' : effectiveEndedAt > 0 ? 'partial' : 'writing'; item.sealed = closed;
        item.reason = closed ? '' : effectiveEndedAt > 0 ? '原始输出没有有序关闭证明；已保留当前落盘范围' : '原始输出仍在写入';
      } catch (e) {
        if (e instanceof EvidencePreparationStaleError) throw e;
        item.state = 'partial'; item.reason = (e as Error).message;
        if ((e as BusinessError).code !== undefined && (e as BusinessError).code !== 13900002) throw e as Error;
      }
      continue;
    }
    if (current === item.captured) {
      // 稳定长度只证明这次没有增长，不证明已完成有序关闭；保留已有不完整性事实。
      if (seal && item.capturedSha256 && item.state === 'complete') item.sealed = true;
      continue;
    }
    if (current === item.baseline) continue;
    let modified: number;
    try { modified = (await fs.stat(item.source)).mtime * 1000; }
    catch (_) { item.state = 'partial'; item.reason = '来源在检查点期间消失或无法读取'; continue; }
    // 已发生的后继launch仍禁止补采可覆盖来源；owner派发尚在真实互斥中且仅有未派发intent时，
    // 才允许保存mtime在意图界限之前的旧来源。isCurrent守卫和源stamp+全文SHA继续全部核验。
    if (modified < plan.startedAt - 1000 || modified >= upper
      || nextLaunchAt > 0 && Date.now() >= nextLaunchAt && !protectedIntentBoundary) continue;
    const temporary: string = destination + '.' + Date.now() + '.partial';
    let published: boolean = false;
    try {
      await ensureEvidenceDirectoryAsync(destination.substring(0, destination.lastIndexOf('/')));
      assertEvidencePreparationCurrent(isCurrent);
      await fs.copyFile(item.source, temporary);
      if (await evidenceFileStampAsync(item.source) !== current || (await fs.stat(temporary)).size !== (await fs.stat(item.source)).size) throw new Error('复制期间来源发生变化，将在下个检查点重试');
      const digest: string = await evidenceFileDigestAsync(temporary);
      if (await evidenceFileDigestAsync(item.source) !== digest) throw new Error('来源内容校验失败');
      const saved = await fs.open(temporary, fs.OpenMode.READ_WRITE);
      try { await fs.fsync(saved.fd); } finally { await fs.close(saved); }
      // 全文校验和临时文件同步后，在真实目标rename之前再次核验。新游戏进入又退出也不能绕过世代。
      assertEvidencePreparationCurrent(isCurrent);
      await fs.rename(temporary, destination); published = true;
      // 已发布旧候选不能回滚；不确认其plan，交给owner保留待办重新核验。
      assertEvidencePreparationCurrent(isCurrent);
      const parent = await fs.open(destination.substring(0, destination.lastIndexOf('/')), fs.OpenMode.READ_ONLY);
      try { await fs.fsync(parent.fd); } finally { await fs.close(parent); }
      item.captured = current; item.capturedBytes = (await fs.stat(destination)).size; item.capturedSha256 = digest;
      item.sealed = seal; item.state = effectiveEndedAt > 0 ? 'complete' : 'writing'; item.reason = '';
      if (item.destination.endsWith('.gz')) { item.state = 'partial'; item.reason = '压缩轮转分片需核验会话边界；可能包含启动前的 latest'; item.attribution = 'ambiguous'; }
    } catch (e) {
      item.state = 'partial'; item.reason = (e as Error).message;
      try { await fs.unlink(temporary); } catch (_) { /* 只清本轮临时文件。 */ }
      if (published) { noteEvidencePublicationUnknown(destination); throw new AtomicWriteError(true); }
      if (e instanceof EvidencePreparationStaleError) throw e;
      if ((e as BusinessError).code !== undefined && (e as BusinessError).code !== 13900002) throw e as Error;
    }
  }
  const nextText: string = JSON.stringify(plan);
  assertEvidencePreparationCurrent(isCurrent);
  if (nextText !== previousText) await writeEvidenceTextAtomicAsync(planPath(filesDir, activityId), nextText, isCurrent);
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

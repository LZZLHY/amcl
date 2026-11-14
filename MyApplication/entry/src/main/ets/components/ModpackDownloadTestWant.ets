/**
 * default/TestHooks 的整合包验收编排入口。Want 仅携带固定夹具 ID 与动作，来源、
 * 摘要和内容选择来自 debug 沙箱的小型 JSON。安装、确认、取消和恢复均调用产品
 * ModpackInstallTask/DownloadTaskRegistry；本文件不解析整合包、不下载或修补游戏文件。
 * 每个夹具只使用 AMCL-QA- 前缀的新实例和 qa-dl- 会话，不能接管用户原恢复现场。
 */
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DiagnosticPolicy, ProductIdentity, ensureDirSync, hasPendingModpackInstall, writeEvidenceTextAtomic } from 'commons';
import { DownloadTaskRegistry, UnifiedTaskView, UnifiedTaskState, VersionFileVerifier,
  VerifyReport, safeRelPath } from 'feature_core';
import { GameStorage, PreferenceManager, parseStorageLocation } from 'feature_system';
import { ModpackInstallTask, ModpackInstallSession, ModpackSnapshot,
  createModpackFileResolver, readModpackSnapshot } from 'mods';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';
import { hashExportFile } from '../export/ExportArchiveIO';
import { collectProductIdentity } from '../product/ProductIdentityCollector';

/** 夹具只接受固定目录内的本地 archive.zip，或有精确摘要的公开 HTTPS 归档。 */
interface ModpackQaFixture {
  schema: number;
  id: string;
  source: string;
  archiveUrl?: string;
  archiveMirrors?: string[];
  archiveSha1: string;
  archiveSha512?: string;
  archiveSize: number;
  projectId?: string;
  sourceVersionId?: string;
  selectedOptional?: string[];
  selectedPackageId?: string;
}

/** 只记录观测值。bytesDone 会在阶段切换时复位，宿主不得把不同阶段累计值直接相加。 */
interface ModpackQaSample {
  at: number;
  activityId: number;
  state: string;
  label: string;
  bytesDone: number;
  bytesTotal: number;
  filesDone: number;
  filesTotal: number;
}

/** 摘要来自产品共用的完整文件读取器；逐文件保留失败，不把未读完的文件报告为通过。 */
interface ModpackQaFileFact {
  path: string;
  bytes: number;
  sha1: string;
  sha256: string;
  error: string;
}

/** 每次真实Registry执行独立计时，暂停/取消/重试不能覆盖先前attempt的时间或身份。 */
interface ModpackQaAttempt {
  number: number;
  action: string;
  startedAt: number;
  settledAt: number;
  activityId: number;
  state: string;
  operationError: string;
}

/** 一份收据绑定一次真实任务；终态与完整性报告分开，部分安装不会变成完整通过。 */
class ModpackQaReceipt {
  schema: number = 1;
  fixtureId: string = '';
  action: string = '';
  receivedAt: number = 0;
  updatedAt: number = 0;
  /** 紧邻Registry入队/恢复调用，不包含本地原包输入SHA的准备成本。 */
  businessStartedAt: number = 0;
  /** Registry 的业务 Promise 已收敛；宿主安装耗时用它，不包含后续只读完整性/摘要成本。 */
  businessSettledAt: number = 0;
  /** 完整性和实际文件摘要均已结束；宿主须等待它才能评估这一轮证据。 */
  settledAt: number = 0;
  operationError: string = '';
  evidenceError: string = '';
  task: UnifiedTaskView | null = null;
  session: ModpackInstallSession | undefined = undefined;
  snapshot: ModpackSnapshot | null = null;
  versionVerification: VerifyReport | undefined = undefined;
  archive: ModpackQaFileFact | undefined = undefined;
  files: ModpackQaFileFact[] = [];
  samples: ModpackQaSample[] = [];
  attempts: ModpackQaAttempt[] = [];
}

/**
 * 已交付实例在新检查器下的独立只读结果。这里没有task/DONE/新安装时间字段，
 * 旧业务结局仍由原attempt收据证明；本收据只证明当前产品执行了新的完整性和字节检查。
 */
class ModpackQaPostVerifyReceipt {
  schema: number = 1;
  fixtureId: string = '';
  postVerificationOnly: boolean = true;
  startedAt: number = 0;
  finishedAt: number = 0;
  versionName: string = '';
  expectedInstallId: string = '';
  productIdentity: ProductIdentity | undefined = undefined;
  snapshot: ModpackSnapshot | null = null;
  versionVerification: VerifyReport | undefined = undefined;
  files: ModpackQaFileFact[] = [];
  error: string = '';
}

/** 安装结束与事后复验共用同一纯取证结果形状，不保存业务控制或执行句柄。 */
interface ModpackQaVersionFacts {
  versionVerification: VerifyReport;
  files: ModpackQaFileFact[];
}

/** 进程内仅保存编排/观测状态，业务恢复身份仍由产品持久计划持有。 */
class ModpackQaRun {
  fixture: ModpackQaFixture;
  task: ModpackInstallTask;
  receipt: ModpackQaReceipt = new ModpackQaReceipt();
  timer: number = 0;
  executing: boolean = false;
  controlPending: boolean = false;
  /** 首个await之前先预约ID；输入摘要期间拒绝控制，避免未入队cancel失效后仍启动。 */
  preparing: boolean = true;
  archiveObservation: Promise<void> | undefined = undefined;
  constructor(fixture: ModpackQaFixture, task: ModpackInstallTask) {
    this.fixture = fixture; this.task = task; this.receipt.fixtureId = fixture.id;
  }
}
const qaRuns: Map<string, ModpackQaRun> = new Map<string, ModpackQaRun>();
const qaPostVerifying: Set<string> = new Set<string>();

/** 严格的单段 ID 同时约束目录、文件名和实例名，不接受 URI、路径或外部会话 ID。 */
function validId(id: string): boolean { return new RegExp('^[a-z0-9][a-z0-9_-]{0,47}$').test(id); }

/**
 * 公网仍限定公开CDN的HTTPS；唯一HTTP例外是本轮受控网络夹具的固定loopback端口和
 * 与当前ID完全一致的文件名。它经独占HDC反向端口映射读取宿主已核验ZIP，仍走真实
 * DownloadManager和安装器，只证明网络功能/字节身份，不能当作公网CDN性能结果。
 * fixture已在调用前强制精确size/SHA；Want不能注入URL，通用下载安全策略不在此改动。
 */
function validArchiveUrl(value: string, id: string): boolean {
  if (value === 'http://127.0.0.1:18131/modpack-qa-fixtures/' + id + '.zip') return true;
  return new RegExp('^https://(cdn\\.modrinth\\.com|mod\\.mcimirror\\.top|mediafilez?\\.forgecdn\\.net|edge\\.forgecdn\\.net)/[^#\\s]+$').test(value);
}

/** 拒绝大文件、软链接和不匹配身份；本地来源路径由程序固定，JSON 不能提供任意路径。 */
function readFixture(context: common.UIAbilityContext, id: string): ModpackQaFixture {
  const path = context.filesDir + '/modpack-qa-fixtures/' + id + '.json';
  const info = fs.lstatSync(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size > 16384) throw new Error('整合包 QA 夹具必须是小型普通文件');
  const fixture = JSON.parse(fs.readTextSync(path)) as ModpackQaFixture;
  if (fixture.schema !== 1 || fixture.id !== id || (fixture.source !== 'local' && fixture.source !== 'online')
    || !new RegExp('^[a-f0-9]{40}$').test(fixture.archiveSha1)
    || !Number.isSafeInteger(fixture.archiveSize) || fixture.archiveSize <= 0
    || (fixture.archiveSha512 !== undefined && !new RegExp('^[a-f0-9]{128}$').test(fixture.archiveSha512)))
    throw new Error('整合包 QA 夹具身份或摘要无效');
  if (fixture.source === 'online' && (fixture.archiveUrl === undefined || !validArchiveUrl(fixture.archiveUrl, id)))
    throw new Error('整合包 QA 仅允许公开HTTPS CDN或固定loopback夹具');
  if (fixture.archiveMirrors !== undefined && (!Array.isArray(fixture.archiveMirrors)
    || fixture.archiveMirrors.length > 4 || fixture.archiveMirrors.some((url: string): boolean => !validArchiveUrl(url, id))))
    throw new Error('整合包 QA 镜像无效');
  if (fixture.selectedOptional !== undefined && (!Array.isArray(fixture.selectedOptional)
    || fixture.selectedOptional.length > 4096 || fixture.selectedOptional.some((key: string): boolean => typeof key !== 'string' || key.length > 512)))
    throw new Error('整合包 QA 内容选择无效');
  return fixture;
}

/** 原子覆盖最新观测；宿主按两秒固定采样和实际 settledAt 读取，不以 aa 成功作结论。 */
function save(context: common.UIAbilityContext, run: ModpackQaRun): void {
  const receipt = run.receipt;
  receipt.updatedAt = Date.now(); receipt.task = run.task.view;
  ensureDirSync(context.filesDir + '/modpack-qa-results');
  writeEvidenceTextAtomic(context.filesDir + '/modpack-qa-results/' + run.fixture.id + '.json', JSON.stringify(receipt));
}

/** 固定间隔采样，不拦截产品监听器；两小时以上仍继续任务，只停止膨胀采样数组。 */
function sample(context: common.UIAbilityContext, run: ModpackQaRun): void {
  const view = run.task.view;
  if (run.receipt.samples.length < 3600) run.receipt.samples.push({ at: Date.now(), activityId: view.startedAtMs,
    state: view.state, label: view.currentLabel, bytesDone: view.bytesDone, bytesTotal: view.bytesTotal,
    filesDone: view.filesDone, filesTotal: view.filesTotal });
  save(context, run);
}

/**
 * 产品进入解压/基础安装后归档才是完整输入。监听只发起一次只读摘要，不持有业务 gate；
 * 原安装器可正常清缓存。若读取撞到清理则留下失败事实，绝不重新下载或延迟产品提交。
 */
function observeArchive(context: common.UIAbilityContext, run: ModpackQaRun): void {
  if (run.fixture.source !== 'online' || run.archiveObservation !== undefined
    || (run.task.view.state !== UnifiedTaskState.EXTRACTING && run.task.getSession() === undefined)) return;
  const path = context.filesDir + '/modpack-work/qa-dl-' + run.fixture.id + '/archive.zip';
  run.archiveObservation = hashFact(path, 'archive.zip').then((fact: ModpackQaFileFact): void => {
    run.receipt.archive = fact;
  });
}

/** 完整读取一个实际文件并留下双摘要。只读失败保留为证据缺口，不触发补下载或替换。 */
async function hashFact(path: string, relative: string): Promise<ModpackQaFileFact> {
  const fact: ModpackQaFileFact = { path: relative, bytes: 0, sha1: '', sha256: '', error: '' };
  try {
    const digest = await hashExportFile(path, (): boolean => false);
    fact.bytes = digest.size; fact.sha1 = digest.sha1; fact.sha256 = digest.sha256;
  } catch (error) { fact.error = (error as Error).message; }
  return fact;
}

/** 只解释产品收据中的文件路径并调用原校验/摘要API，绝不补下载、改配置或重写安装判据。 */
async function collectVersionFacts(root: string, version: string, snapshot: ModpackSnapshot | null): Promise<ModpackQaVersionFacts> {
  const directory = root + '/versions/' + version;
  const verification = await VersionFileVerifier.verifyAll(root, version);
  const paths = [version + '.jar', version + '.json'];
  if (snapshot !== null) {
    for (const path of snapshot.installedFiles.concat(snapshot.overrideFiles)) {
      if (safeRelPath(path) !== path || path.length === 0) throw new Error('产品收据含非 canonical 文件路径');
      if (paths.indexOf(path) < 0) paths.push(path);
    }
  }
  const files: ModpackQaFileFact[] = [];
  for (const path of paths) files.push(await hashFact(directory + '/' + path, path));
  return { versionVerification: verification, files: files };
}

/** 只读产品收据与其声明的落地文件；版本完整性复用页面的 VersionFileVerifier。 */
async function collectInstalled(context: common.UIAbilityContext, run: ModpackQaRun): Promise<void> {
  const session = run.task.getSession();
  // 完整清单只在业务执行收敛后记录一次；活动中的两秒采样不反复序列化整个文件计划。
  run.receipt.session = session;
  if (session === undefined || session.versionName.length === 0) return;
  const root = run.task.getInstallRoot(); const version = session.versionName;
  run.receipt.snapshot = readModpackSnapshot(root + '/versions/' + version);
  if (run.task.view.state !== UnifiedTaskState.DONE) return;
  const facts = await collectVersionFacts(root, version, run.receipt.snapshot);
  run.receipt.versionVerification = facts.versionVerification; run.receipt.files = facts.files;
}

/**
 * 固定QA身份的事后复验不依赖旧进程Map，也不创建Registry任务。必须存在本fixture的
 * 已提交snapshot且没有pending写者；取证后再核身份/安装时间，防止把并发替换混作一轮。
 * 当前profile身份使用启动banner同一采集器，不能由Want或宿主填写一个期望身份冒充事实。
 */
async function postVerify(context: common.UIAbilityContext, id: string): Promise<void> {
  if (qaPostVerifying.has(id)) throw new Error('该QA实例已经在只读复验');
  qaPostVerifying.add(id);
  const receipt = new ModpackQaPostVerifyReceipt();
  receipt.fixtureId = id; receipt.versionName = 'AMCL-QA-' + id;
  receipt.expectedInstallId = 'qa-dl-' + id; receipt.startedAt = Date.now();
  const output = context.filesDir + '/modpack-qa-results/' + id + '-postverify.json';
  try {
    readFixture(context, id);
    receipt.productIdentity = collectProductIdentity();
    const preferences = new PreferenceManager(context);
    const root = GameStorage.resolveMcDir(context, parseStorageLocation(preferences.mcStorageLocation));
    const directory = root + '/versions/' + receipt.versionName;
    const snapshot = readModpackSnapshot(directory);
    if (snapshot === null || snapshot.installId !== receipt.expectedInstallId || hasPendingModpackInstall(directory))
      throw new Error('只读复验只接受当前fixture已提交且没有在途写者的原QA实例');
    receipt.snapshot = snapshot;
    ensureDirSync(context.filesDir + '/modpack-qa-results');
    writeEvidenceTextAtomic(output, JSON.stringify(receipt));
    const facts = await collectVersionFacts(root, receipt.versionName, snapshot);
    const after = readModpackSnapshot(directory);
    if (after === null || after.installId !== snapshot.installId || after.installedAt !== snapshot.installedAt
      || hasPendingModpackInstall(directory)) throw new Error('只读复验期间QA实例身份发生变化');
    receipt.versionVerification = facts.versionVerification; receipt.files = facts.files;
  } catch (error) { receipt.error = (error as Error).message; }
  finally {
    receipt.finishedAt = Date.now(); qaPostVerifying.delete(id);
    ensureDirSync(context.filesDir + '/modpack-qa-results');
    writeEvidenceTextAtomic(output, JSON.stringify(receipt));
  }
}

/** 首次入队与恢复都保留相同业务调用；成功或失败后先结束计时器，再只读收集终态事实。 */
async function execute(context: common.UIAbilityContext, run: ModpackQaRun, action: string): Promise<void> {
  if (run.executing) throw new Error('当前 QA 任务仍在执行');
  run.executing = true; run.receipt.operationError = ''; run.receipt.evidenceError = '';
  run.receipt.businessSettledAt = 0; run.receipt.settledAt = 0;
  // 新attempt撤销全部上轮终验事实。归档事实绑定同一固定fixture，可保留有效完整摘要；
  // 当前版本、收据、文件清单与校验结论必须在本轮实际执行收敛后重新取得。
  run.receipt.versionVerification = undefined; run.receipt.files = [];
  run.receipt.snapshot = null; run.receipt.session = undefined;
  const archive = run.receipt.archive;
  if (run.fixture.source === 'online' && archive !== undefined && (archive.error.length > 0
    || archive.sha1 !== run.fixture.archiveSha1 || archive.bytes !== run.fixture.archiveSize)) {
    run.receipt.archive = undefined; run.archiveObservation = undefined;
  }
  const attempt: ModpackQaAttempt = { number: run.receipt.attempts.length + 1, action: action,
    startedAt: Date.now(), settledAt: 0, activityId: 0, state: '', operationError: '' };
  run.receipt.businessStartedAt = attempt.startedAt;
  run.receipt.attempts.push(attempt);
  const registry = DownloadTaskRegistry.instance();
  const listener = (): void => { observeArchive(context, run); };
  registry.addListener(listener);
  run.timer = setInterval((): void => { try { sample(context, run); } catch (_) { /* 无收据即无完成证据。 */ } }, 2000);
  try {
    if (action === 'start') await registry.enqueue(run.task);
    else if (action === 'retry') await registry.retry(run.task.view.id);
    else await registry.resume(run.task.view.id);
  } catch (error) { run.receipt.operationError = (error as Error).message; }
  finally {
    run.receipt.businessSettledAt = Date.now();
    attempt.settledAt = run.receipt.businessSettledAt; attempt.activityId = run.task.view.startedAtMs;
    attempt.state = run.task.view.state; attempt.operationError = run.receipt.operationError;
    clearInterval(run.timer); run.timer = 0; registry.removeListener(listener);
    try { await run.archiveObservation; await collectInstalled(context, run); }
    catch (error) { run.receipt.evidenceError = (error as Error).message; }
    run.executing = false;
    run.receipt.settledAt = Date.now(); sample(context, run);
  }
}

/**
 * 返回 true 表示识别并吞掉本专用 Want；正式产品即使收到相同参数也不读夹具。
 * 每个 start 固定新 QA 名称，碰到已提交实例直接拒绝；resume/retry 仅操纵本进程
 * 该 QA task，冷恢复重新 start 仍由 qa-dl- 固定会话和产品自己的 source/session 恢复。
 */
export function isModpackDownloadTestWant(want: Want): boolean {
  return want.parameters?.['amclModpackDownloadTest'] !== undefined;
}

/** 双门控只接受此专用标记；识别后由Ability阻止该Want流向其他业务消费者。 */
export function runModpackDownloadTestWant(context: common.UIAbilityContext, want: Want): boolean {
  const actionValue = want.parameters?.['amclModpackDownloadTest'];
  if (actionValue === undefined) return false;
  if (ProductBuildProfile.product !== 'default' || !DiagnosticPolicy.hasTestHooks()) return true;
  const idValue = want.parameters?.['fixtureId'];
  if (typeof actionValue !== 'string' || typeof idValue !== 'string' || !validId(idValue)
    || ['start', 'read', 'cancel', 'resume', 'retry', 'confirm', 'postverify'].indexOf(actionValue) < 0) return true;
  dispatch(context, idValue, actionValue).catch((error: Error): void => {
    // 参数拒绝同样写独立错误收据，绝不打印整个夹具或原 Want。
    try {
      ensureDirSync(context.filesDir + '/modpack-qa-results');
      const receipt = new ModpackQaReceipt(); receipt.fixtureId = idValue; receipt.action = actionValue;
      receipt.receivedAt = Date.now(); receipt.updatedAt = receipt.receivedAt; receipt.settledAt = receipt.receivedAt;
      receipt.operationError = error.message;
      writeEvidenceTextAtomic(context.filesDir + '/modpack-qa-results/' + idValue + '-rejected.json', JSON.stringify(receipt));
    } catch (_) { /* 没有实际落盘收据不能声称拒绝原因已采到。 */ }
  });
  return true;
}

/** 只编排已公开的产品 API；取消固定 cleanupFiles=false，原实例/恢复材料不能被测试入口删除。 */
async function dispatch(context: common.UIAbilityContext, id: string, action: string): Promise<void> {
  if (action === 'postverify') { await postVerify(context, id); return; }
  let run = qaRuns.get(id);
  if (action === 'start') {
    if (run !== undefined) throw new Error('该 QA 夹具已经入队，请使用 read/cancel/resume/retry');
    const fixture = readFixture(context, id);
    const name = 'AMCL-QA-' + id;
    const preferences = new PreferenceManager(context);
    const root = GameStorage.resolveMcDir(context, parseStorageLocation(preferences.mcStorageLocation));
    if (readModpackSnapshot(root + '/versions/' + name) !== null) throw new Error('同名 QA 实例已提交，请使用新夹具 ID');
    const task = new ModpackInstallTask({ title: name, versionName: name, sessionId: 'qa-dl-' + id,
      subtitle: '整合包 · QA', filesDir: context.filesDir, mcDir: root, existingVersions: [],
      archivePath: fixture.source === 'local' ? context.filesDir + '/modpack-qa-fixtures/' + id + '.zip' : undefined,
      archiveUrl: fixture.source === 'online' ? fixture.archiveUrl : undefined,
      archiveMirrors: fixture.archiveMirrors, archiveFilename: id + '.zip', archiveSha1: fixture.archiveSha1,
      archiveSha512: fixture.archiveSha512, archiveSize: fixture.archiveSize,
      projectId: fixture.projectId, sourceVersionId: fixture.sourceVersionId,
      selectedOptional: fixture.selectedOptional, requireConfirmation: false,
      resolveCfFile: createModpackFileResolver(true) });
    run = new ModpackQaRun(fixture, task);
    // 必须在首个异步摘要之前预约；第二个同ID start不能覆盖即将入队的原owner。
    qaRuns.set(id, run);
    run.receipt.action = action; run.receipt.receivedAt = Date.now(); save(context, run);
    // 本地归档的双摘要在业务入队之前采集，产品随后仍执行自身来源校验；不以采集替代产品验证。
    if (fixture.source === 'local') run.receipt.archive = await hashFact(context.filesDir + '/modpack-qa-fixtures/' + id + '.zip', id + '.zip');
    run.preparing = false;
    await execute(context, run, action); return;
  }
  if (run === undefined) throw new Error('本进程没有该 QA 任务；冷恢复使用同一夹具 start');
  // read只刷新观测时间，不能把它伪装成一次新的业务动作开始，或覆盖宿主等待的动作身份。
  if (action === 'read') { sample(context, run); return; }
  if (run.preparing) throw new Error('QA输入摘要尚未完成，任务尚未入队');
  if (action !== 'cancel' && run.executing) throw new Error('当前 QA 任务仍在执行');
  if (run.controlPending) throw new Error('该 QA 任务的上一控制动作尚未收敛');
  run.receipt.action = action; run.receipt.receivedAt = Date.now();
  run.controlPending = true;
  try {
    const registry = DownloadTaskRegistry.instance();
    if (action === 'cancel') {
      await registry.cancel(run.task.view.id, false); sample(context, run); return;
    }
    if (action === 'confirm') {
      if (run.task.requiresPackageSelection()) {
        const candidates = run.task.packageCandidates(); const selected = run.fixture.selectedPackageId;
        if (selected !== undefined) run.task.selectPackage(selected);
        else if (candidates.length === 1) run.task.selectPackage(candidates[0].id);
        else throw new Error('多候选归档必须在固定夹具中指定 selectedPackageId');
      }
      run.task.confirmSelection();
    }
    const execution = execute(context, run, action === 'retry' ? 'retry' : 'resume');
    // Registry.resume/retry的Promise覆盖完整业务执行；启动动作已串行接线后允许cancel，
    // 不能把整个安装时长当成“控制分派尚未完成”而锁死恢复后的取消按钮。
    run.controlPending = false;
    await execution;
  } finally { run.controlPending = false; }
}

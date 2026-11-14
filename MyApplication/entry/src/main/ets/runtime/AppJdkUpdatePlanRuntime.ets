/**
 * App更新与全部可选JDK之间的持久计划。准备只下载/验证原件；手机重签完成且App安装器
 * 已持全局EX/fence后才切槽。App/BMS结果未知时保留计划，不把两个系统伪装成原子提交。
 */
import { fileIo as fs, statfs } from '@kit.CoreFileKit';
import { AppUpdateSuperseder, stringToUtf8, parseAppRuntimeRequirements } from 'commons';
import { jdkSlotIdentity, sameJdkSlotIdentity, validateJdkSlotIdentity } from './JdkSlotIdentity';
import { JdkManager, JdkVersionConfig, JdkInstaller, JdkDirectoryLease, JdkInstallStorage, RuntimeCatalogRepository, RuntimeInstallReceipt, RuntimeBuild, RuntimeDefinition, JdkVersionInfo,
  runtimeRequiredHost, runtimeHostProtocols, runtimeRequiredCapabilities, runtimeRecommendationIds, validateRuntimeForHost, RUNTIME_INSTALL_RECEIPT_LIMIT,
  serializeRuntimeInstallReceipt, RUNTIME_RECEIPT_MAX_ISO_TIMESTAMP } from 'launch';

export interface AppJdkUpdateTarget {
  runtimeRequiredCapabilities?: string[];
  runtimeRequiredMajors?: number[];
  product: string; versionName: string; versionCode: number; sha256: string; sourceRevision: string;
  runtimeHostProtocols: number[]; runtimePlanProtocol?: number;
}
interface PlanIoError { code?: number | string; message?: string; }
interface SlotReaderMetadata { receiptSize: number; }
const LEGACY_RECEIPT_LIMIT: number = 65536;
function missing(error: Object): boolean {
  const detail = error as PlanIoError;
  return detail.code === 13900002 || detail.code === 'ENOENT' || detail.message === 'ENOENT';
}
interface RuntimePlanEntry {
  major: string; before: string; requiredProtocol: number; replacement?: JdkVersionConfig;
  archive: string; complete: boolean;
  /** original before永不改；新一轮切槽从已观察到的真实身份开始，旧效果逐条保存在history。 */
  activeFrom?: string;
  history?: RuntimePlanAttempt[];
}
interface RuntimePlanFrozenBuild {
  runtimeId: string; javaMajor: number; buildId: string; archiveSha256: string; archiveSizeBytes: number; requiredHostProtocol: number;
}
interface RuntimePlanAttempt {
  from: string; installedIdentity: string;
  /** 仅旧记录读取保留完整config；新历史只存固定构建身份，不复制notes/来源/大分卷清单。 */
  replacement?: JdkVersionConfig;
  frozen?: RuntimePlanFrozenBuild;
}
interface AppRuntimePlan {
  schemaVersion: number; transactionId: string; target: AppJdkUpdateTarget;
  phase: string; signedPath: string; entries: RuntimePlanEntry[];
}

/** 单文件元数据有界；不能因JSON parse异常把未知现场当成“没有计划”。 */
function planPath(context: Context): string { return context.filesDir + '/update-runtime-plan.json'; }
function readPlan(context: Context): AppRuntimePlan | null {
  const path = planPath(context); let present = false;
  try { fs.lstatSync(path); present = true; } catch (error) {
    if (!missing(error as Object)) throw error as Error;
  }
  if (!present) return null;
  const stat = fs.lstatSync(path);
  if (!stat.isFile() || stat.size <= 0 || stat.size > 1048576) throw new Error('App/JDK恢复计划损坏，已保留现场');
  const plan = JSON.parse(fs.readTextSync(path)) as AppRuntimePlan;
  if (plan.schemaVersion !== 1 || !Array.isArray(plan.entries) || plan.entries.length > 64 ||
    ['preparing','prepared','signed','restoring','ready-to-install'].indexOf(plan.phase) < 0) throw new Error('App/JDK恢复计划格式不受支持');
  if (!new RegExp('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$').test(plan.transactionId) || plan.transactionId.indexOf('..') >= 0) throw new Error('App/JDK计划事务标识无效');
  targetIdentity(plan.target);
  if (typeof plan.signedPath !== 'string' || (plan.signedPath !== '' && plan.signedPath !== context.filesDir + '/sideload-update/tasks/' + plan.transactionId + '/signed.hap')) throw new Error('App/JDK签名产物路径不属于该事务');
  if (['signed','restoring','ready-to-install'].indexOf(plan.phase) >= 0 && plan.signedPath === '') throw new Error('App/JDK计划缺少已签名产物');
  const seen: string[] = [];
  for (const entry of plan.entries) {
    if (entry === null || typeof entry !== 'object' || !new RegExp('^[1-9][0-9]{0,2}$').test(entry.major) || Number(entry.major) < 8 || seen.indexOf(entry.major) >= 0 ||
      typeof entry.before !== 'string' || entry.before.length === 0 || entry.before.length > 131072 || typeof entry.complete !== 'boolean' ||
      !Number.isSafeInteger(entry.requiredProtocol) || entry.requiredProtocol < 0 || entry.requiredProtocol > 999) throw new Error('App/JDK计划槽位身份无效');
    seen.push(entry.major);
    validateJdkSlotIdentity(entry.before);
    let expectedFrom = entry.before;
    if (entry.history !== undefined) {
      if (!Array.isArray(entry.history) || entry.history.length < 1 || entry.history.length > 8) throw new Error('App/JDK重规划历史无效');
      for (const attempt of entry.history) {
        if (attempt === null || typeof attempt !== 'object' || attempt.from !== expectedFrom ||
          typeof attempt.installedIdentity !== 'string' || attempt.installedIdentity.length > 131072) throw new Error('App/JDK重规划效果链断裂');
        if ((attempt.replacement === undefined) === (attempt.frozen === undefined)) throw new Error('App/JDK历史冻结身份无效');
        if (attempt.replacement !== undefined) validatePlanConfig(attempt.replacement,entry.major);
        else validateFrozenBuild(attempt.frozen!,entry.major);
        if (attempt.installedIdentity !== '') validateJdkSlotIdentity(attempt.installedIdentity);
        expectedFrom = attempt.installedIdentity === '' ? attempt.from : attempt.installedIdentity;
      }
      if (entry.activeFrom !== expectedFrom) throw new Error('App/JDK重规划当前身份不属于历史效果');
    } else if (entry.activeFrom !== undefined) throw new Error('App/JDK计划不能凭空改写原槽身份');
    if (entry.replacement === undefined) { if (entry.archive !== '') throw new Error('无恢复动作不能携带原件路径'); }
    else {
      const config = entry.replacement;
      validatePlanConfig(config,entry.major);
      if (entry.archive !== context.cacheDir + '/app-runtime-plan/' + plan.transactionId + '/jdk-' + entry.major + '.zip') throw new Error('App/JDK计划冻结原件无效');
    }
    if (entry.complete && ['restoring','ready-to-install'].indexOf(plan.phase) < 0) throw new Error('App/JDK计划步骤与阶段不一致');
    if (!entry.complete && plan.phase === 'ready-to-install') throw new Error('App/JDK计划尚有未完成步骤');
  }
  return plan;
}
/** 历史与活跃步骤使用同一原件身份约束；历史只证明物理效果，不授予撤回包执行资格。 */
function validatePlanConfig(config: JdkVersionConfig, major: string): void {
  if (config === null || typeof config !== 'object' || config.build === undefined || config.runtime === undefined ||
    typeof config.build.id !== 'string' || !new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(config.build.id) ||
    config.runtime.javaMajor.toString() !== major || !new RegExp('^[0-9a-f]{64}$').test(config.sha256 ?? '') ||
    !Number.isSafeInteger(config.sizeBytes) || config.sizeBytes! <= 0) throw new Error('App/JDK计划冻结原件无效');
}
/** 历史只需不可变来源身份和原宿主要求；业务描述/下载URL不参与已发生效果认领。 */
function validateFrozenBuild(build: RuntimePlanFrozenBuild, major: string): void {
  if (build === null || typeof build !== 'object' || build.javaMajor.toString() !== major ||
    typeof build.runtimeId !== 'string' || !new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(build.runtimeId) ||
    typeof build.buildId !== 'string' || !new RegExp('^[a-z0-9][a-z0-9._-]{0,95}$').test(build.buildId) ||
    typeof build.archiveSha256 !== 'string' || !new RegExp('^[0-9a-f]{64}$').test(build.archiveSha256) ||
    !Number.isSafeInteger(build.archiveSizeBytes) || build.archiveSizeBytes <= 0 || build.archiveSizeBytes > 2147483647 ||
    !Number.isSafeInteger(build.requiredHostProtocol) || build.requiredHostProtocol < 1 || build.requiredHostProtocol > 999) throw new Error('App/JDK历史冻结身份无效');
}
function frozenBuild(config: JdkVersionConfig, major: string): RuntimePlanFrozenBuild {
  const result: RuntimePlanFrozenBuild = {runtimeId:config.runtime!.id,javaMajor:Number(major),buildId:config.build!.id,
    archiveSha256:config.sha256!,archiveSizeBytes:config.sizeBytes!,requiredHostProtocol:config.build!.requiredHostProtocol ?? config.runtime!.loaderProtocol};
  validateFrozenBuild(result,major); return result;
}
function activeFrom(entry: RuntimePlanEntry): string { return entry.activeFrom ?? entry.before; }
function savePlan(context: Context, plan: AppRuntimePlan): void {
  const value = JSON.stringify(plan).replace(new RegExp('[^\\x00-\\x7f]','g'),(c: string): string => '\\u' + c.charCodeAt(0).toString(16).padStart(4,'0'));
  if (value.length > 1048576) throw new Error('App/JDK计划超过恢复预算，旧记录已保留');
  const path = planPath(context); const file = fs.openSync(path + '.writing',fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
  try {
    if (fs.writeSync(file.fd,value) !== value.length) throw new Error('App/JDK计划写入不完整');
    fs.fsyncSync(file.fd);
  } finally { fs.closeSync(file); }
  fs.renameSync(path + '.writing',path);
  const directory = fs.openSync(context.filesDir,fs.OpenMode.READ_ONLY);
  try { fs.fsyncSync(directory.fd); } finally { fs.closeSync(directory); }
}
/** 每个await期间仍持真实文件锁；进程死亡释放执行锁，但持久计划保留未知结果。 */
function lock(context: Context, id: string): JdkDirectoryLease { return JdkDirectoryLease.appPlan(context.filesDir,id); }
function unlock(owner: JdkDirectoryLease): void { owner.release(); }
function targetIdentity(target: AppJdkUpdateTarget): string {
  if (target === null || typeof target !== 'object' || typeof target.product !== 'string' || !new RegExp('^[a-z][a-z0-9-]{0,31}$').test(target.product) ||
    typeof target.versionName !== 'string' || target.versionName.length === 0 || target.versionName.length > 128 ||
    !Number.isSafeInteger(target.versionCode) || target.versionCode <= 0 || target.versionCode > 2147483647 ||
    typeof target.sourceRevision !== 'string' || target.sourceRevision.length > 80 || !new RegExp('^[0-9a-f]{64}$').test(target.sha256) || !Array.isArray(target.runtimeHostProtocols) ||
    target.runtimeHostProtocols.length === 0 || target.runtimeHostProtocols.length > 8 ||
    target.runtimeHostProtocols.some((p: number,index: number): boolean => target.runtimeHostProtocols.indexOf(p) !== index) ||
    target.runtimeHostProtocols.some((p: number): boolean => !Number.isSafeInteger(p) || p < 1 || p > 999) ||
    target.runtimePlanProtocol !== undefined && (!Number.isSafeInteger(target.runtimePlanProtocol) || target.runtimePlanProtocol < 0 || target.runtimePlanProtocol > 2)) {
    throw new Error('目标App缺少可信宿主能力身份');
  }
  const requirements = parseAppRuntimeRequirements(target.runtimeRequiredCapabilities,target.runtimeRequiredMajors);
  // 旧plan没有行为字段时保持其原绑定原字节；新要求必须进入目标身份，不能续作时偷偷更换。
  const identity: Object[] = [target.product,target.versionName,target.versionCode,target.sha256,target.sourceRevision,target.runtimeHostProtocols,target.runtimePlanProtocol ?? 0];
  if (requirements.runtimeRequiredCapabilities.length > 0 || requirements.runtimeRequiredMajors.length > 0) {
    identity.push(requirements.runtimeRequiredCapabilities); identity.push(requirements.runtimeRequiredMajors);
  }
  return JSON.stringify(identity);
}
/** plan2是恢复数据reader能力，独立于宿主[1,2]和目录协议，不用versionCode猜测。 */
function receiptReaderLimit(target: AppJdkUpdateTarget): number {
  return (target.runtimePlanProtocol ?? 0) >= 2 ? RUNTIME_INSTALL_RECEIPT_LIMIT : LEGACY_RECEIPT_LIMIT;
}
/**
 * 与生产Installer生成完全相同的receipt字段，时间戳预留JS合法ISO的最大27字节。
 * 只计算最终UTF-8预算，不写收据、不下载；既有plan1仍可选择旧reader真正可读的小包。
 */
function replacementFitsReader(target: AppJdkUpdateTarget, major: string, config: JdkVersionConfig): boolean {
  try {
    const text = serializeRuntimeInstallReceipt(config.runtime!,config.build!,Number(major),config.sha256!,config.sizeBytes!,RUNTIME_RECEIPT_MAX_ISO_TIMESTAMP);
    return stringToUtf8(text).byteLength <= receiptReaderLimit(target);
  } catch (_) { return false; /* producer共享预算失败也不能给目标App推荐该构建。 */ }
}
/**
 * 跨App切槽与发布端qualifiedReturnBuild采用同一来源资格：可用的源码构建、完整清单摘要、
 * 设备矩阵验收缺一不可。legacy即使标上设备验收等级也不能成为自动恢复目标；这个限制
 * 只管新切槽，不因现存JDK是历史包就强制更换它。准备与执行前复核共用，防目录变化漏检。
 */
function qualifiedReplacement(build: RuntimeBuild): boolean {
  return build.status === 'available' && build.validationLevel === 'device-matrix-tested' &&
    build.provenance !== undefined && build.provenance.kind === 'source-build' &&
    new RegExp('^[0-9a-f]{64}$').test(build.provenance.manifestSha256);
}
/** 有序推荐中同时通过来源/宿主/设备资格及目标数据reader预算的第一项；不放行旧reader大收据。 */
function readerCompatibleReplacement(major: string, target: AppJdkUpdateTarget, repository: RuntimeCatalogRepository, manager: JdkManager): JdkVersionConfig | undefined {
  const catalog = repository.snapshot(); const runtime = catalog.runtimes.find((r: RuntimeDefinition): boolean => r.javaMajor.toString() === major);
  if (runtime === undefined || repository.recommendationUnavailableReason() !== '') return undefined;
  for (const id of runtimeRecommendationIds(runtime)) {
    const build = catalog.builds.find((b: RuntimeBuild): boolean => b.id === id && b.runtimeId === runtime.id);
    if (build === undefined || !qualifiedReplacement(build) || !repository.isBuildAllowed(id) ||
      target.runtimeHostProtocols.indexOf(runtimeRequiredHost(catalog,build)) < 0 || runtimeHostProtocols().indexOf(runtimeRequiredHost(catalog,build)) < 0 ||
      (target.runtimeRequiredCapabilities ?? []).concat(runtimeRequiredCapabilities()).some((capability: string): boolean => build.capabilities.indexOf(capability) < 0)) continue;
    const config = manager.compatibilityConfig(major,id);
    if (replacementFitsReader(target,major,config)) return config;
  }
  return undefined;
}
/** 旧reader数据修复也不能把“非imported标签”当托管授权，须认得catalog来源的精确原件身份。 */
function managedReaderRepairSource(context: Context, entry: RuntimePlanEntry, repository: RuntimeCatalogRepository): boolean {
  try {
    const receipt = JSON.parse(fs.readTextSync(context.filesDir + '/jdk/' + entry.major + '/.amcl-runtime-receipt.json')) as RuntimeInstallReceipt;
    const known = repository.snapshot().builds.find((build: RuntimeBuild): boolean => build.id === receipt.buildId && build.runtimeId === receipt.runtimeId);
    return receipt.schemaVersion === 1 && receipt.origin === 'catalog' && receipt.javaMajor === Number(entry.major) && known !== undefined &&
      receipt.runtime.id === receipt.runtimeId && receipt.runtime.javaMajor === receipt.javaMajor && receipt.build.id === receipt.buildId && receipt.build.runtimeId === receipt.runtimeId &&
      receipt.archiveSha256 === known.archive.sha256 && receipt.archiveSizeBytes === known.archive.sizeBytes &&
      receipt.build.archive.sha256 === receipt.archiveSha256 && receipt.build.archive.sizeBytes === receipt.archiveSizeBytes;
  } catch (_) { return false; }
}
/** inode与来源收据共同冻结安装身份，避免仅比较主版本导致并发替换未被察觉。 */
function slotIdentity(context: Context, major: string): string {
  return jdkSlotIdentity(context.filesDir,major);
}
function assertBinding(plan: AppRuntimePlan, id: string, target: AppJdkUpdateTarget): void {
  if (plan.transactionId !== id || targetIdentity(plan.target) !== targetIdentity(target)) throw new Error('已有App/JDK计划属于其他原件，请先完成或恢复该事务');
}

/** 删除记录也同步父目录；重复Verified在已无记录时仍能完成上次未成功的父目录同步。 */
function syncPlanDirectory(context: Context): void {
  if (!fs.lstatSync(context.filesDir).isDirectory()) throw new Error('App/JDK计划父目录不是独立目录');
  const file = fs.openSync(context.filesDir,fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
}
function removePlan(context: Context): void { fs.unlinkSync(planPath(context)); syncPlanDirectory(context); }
/** 恢复既有持久效果不需要再次运行候选JDK；不在此执行新下载或新切槽。 */
function recoverSlots(context: Context, plan: AppRuntimePlan): void {
  for (const entry of plan.entries) if (JdkInstallStorage.recoveryRequired(context.filesDir,entry.major)) {
    const writer: JdkDirectoryLease = JdkDirectoryLease.writer(context.filesDir,entry.major,plan.transactionId);
    try { JdkInstallStorage.recoverWithWriter(context.filesDir,entry.major,writer); } finally { writer.release(); }
  }
}
function replacementPresent(context: Context, entry: RuntimePlanEntry): boolean {
  if (entry.replacement === undefined) return false;
  try {
    const directory = context.filesDir + '/jdk/' + entry.major;
    if (!fs.lstatSync(directory).isDirectory()) return false;
    const path = directory + '/.amcl-runtime-receipt.json'; const stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.size > RUNTIME_INSTALL_RECEIPT_LIMIT) return false;
    const receipt = JSON.parse(fs.readTextSync(path)) as RuntimeInstallReceipt;
    return receipt.schemaVersion === 1 && receipt.origin === 'catalog' && receipt.javaMajor.toString() === entry.major &&
      receipt.runtimeId === entry.replacement.runtime!.id && receipt.buildId === entry.replacement.build!.id &&
      receipt.archiveSha256 === entry.replacement.sha256 && receipt.archiveSizeBytes === entry.replacement.sizeBytes &&
      JSON.stringify(receipt.runtime) === JSON.stringify(entry.replacement.runtime) && JSON.stringify(receipt.build) === JSON.stringify(entry.replacement.build) &&
      fs.readTextSync(directory + '/.amcl_release_tag') === entry.replacement.tag;
  } catch (_) { return false; }
}

/** 当前签名目录中的资格判断只服务新动作；历史已切槽收据不能替代这一准入。 */
function replacementAllowed(plan: AppRuntimePlan, entry: RuntimePlanEntry, repository: RuntimeCatalogRepository): boolean {
  if (entry.replacement === undefined) return true;
  const catalog = repository.snapshot(); const frozen = entry.replacement;
  const build = catalog.builds.find((b: RuntimeBuild): boolean => b.id === frozen.build!.id);
  const runtime = catalog.runtimes.find((r: RuntimeDefinition): boolean => r.javaMajor.toString() === entry.major);
  return build !== undefined && runtime !== undefined && build.runtimeId === runtime.id &&
    repository.isBuildAllowed(build.id) && qualifiedReplacement(build) &&
    runtimeRecommendationIds(runtime).indexOf(build.id) >= 0 && build.archive.sha256 === frozen.sha256 && build.archive.sizeBytes === frozen.sizeBytes &&
    plan.target.runtimeHostProtocols.indexOf(runtimeRequiredHost(catalog,build)) >= 0 && runtimeHostProtocols().indexOf(runtimeRequiredHost(catalog,build)) >= 0 &&
    (plan.target.runtimeRequiredCapabilities ?? []).concat(runtimeRequiredCapabilities()).every((capability: string): boolean => build.capabilities.indexOf(capability) >= 0) &&
    replacementFitsReader(plan.target,entry.major,frozen);
}

/**
 * 原事务显式重试时追加安全重规划。先精确认领已发生效果，再冻结另一合格兼容构建；不删除
 * 单槽journal、不覆盖original before、不把已撤回构建重新发布。每次追加都先持久化再下载。
 */
function replanUnavailable(context: Context, plan: AppRuntimePlan, repository: RuntimeCatalogRepository, manager: JdkManager): void {
  if (repository.recommendationUnavailableReason() !== '') throw new Error('请刷新可信JDK目录后重试原更新事务');
  for (const entry of plan.entries) {
    if (entry.replacement === undefined || replacementAllowed(plan,entry,repository)) continue;
    const observed = slotIdentity(context,entry.major); const from = activeFrom(entry);
    const installed = replacementPresent(context,entry);
    if (!sameJdkSlotIdentity(observed,from) && !installed || entry.complete && !installed) throw new Error('重规划发现未知JDK槽位效果，已保留原计划');
    const config = readerCompatibleReplacement(entry.major,plan.target,repository,manager);
    if (config === undefined || config.build!.id === entry.replacement.build!.id) throw new Error('原兼容JDK已撤回或资格/推荐/reader预算变化，暂没有新的合格兼容构建；请保留原事务并等待目录修复');
    const history = entry.history ?? [];
    if (history.length >= 8) throw new Error('兼容JDK连续变化次数超过恢复预算，已保留全部效果历史');
    validatePlanConfig(config,entry.major);
    history.push({from:from,frozen:frozenBuild(entry.replacement,entry.major),installedIdentity:installed ? observed : ''});
    entry.history = history; entry.activeFrom = installed ? observed : from; entry.replacement = config; entry.complete = false;
    plan.phase = plan.phase === 'restoring' || plan.phase === 'ready-to-install' ? 'restoring' : 'preparing';
    savePlan(context,plan);
  }
}

/**
 * 旧plan1的原始不变槽也可能带有旧reader读不了的UTF-8大收据。只在原before仍精确匹配、
 * 且是受管槽时追加小收据修复；不接管用户导入，不改旧binding或假造此前的切槽效果。
 */
function repairLegacyReaderEntries(context: Context, plan: AppRuntimePlan, repository: RuntimeCatalogRepository, manager: JdkManager): void {
  if ((plan.target.runtimePlanProtocol ?? 0) >= 2) return;
  for (const entry of plan.entries) {
    if (entry.replacement !== undefined) continue;
    const observed = slotIdentity(context,entry.major); const metadata = JSON.parse(observed) as SlotReaderMetadata;
    if (metadata.receiptSize <= LEGACY_RECEIPT_LIMIT) continue;
    if (!sameJdkSlotIdentity(observed,entry.before)) throw new Error('旧reader修复发现未知JDK效果，已保留原计划');
    const state = manager.listVersions().find((item: JdkVersionInfo): boolean => item.version === entry.major);
    if (state === undefined || state.userImported || !managedReaderRepairSource(context,entry,repository)) {
      throw new Error('未知来源或用户运行时收据超出目标App读取能力，请明确处理后继续');
    }
    const config = readerCompatibleReplacement(entry.major,plan.target,repository,manager);
    if (config === undefined) throw new Error('旧目标App没有可读取的合格兼容JDK收据，请保留原事务等待修复');
    entry.replacement = config; entry.archive = context.cacheDir + '/app-runtime-plan/' + plan.transactionId + '/jdk-' + entry.major + '.zip';
    entry.complete = false; plan.phase = plan.phase === 'restoring' || plan.phase === 'ready-to-install' ? 'restoring' : 'preparing';
    savePlan(context,plan);
  }
}

/** 本轮已准备/已提交都必须复核当前目录资格；receipt不是撤回/正式恢复资格的替代品。 */
function assertReplacementAllowed(context: Context, plan: AppRuntimePlan, repository: RuntimeCatalogRepository): void {
  if (repository.recommendationUnavailableReason() !== '') throw new Error('可信JDK目录暂不可用于确认兼容恢复');
  for (const entry of plan.entries) {
    if (entry.replacement === undefined) {
      if (!sameJdkSlotIdentity(slotIdentity(context,entry.major),entry.before)) throw new Error('兼容JDK安装身份改变');
      continue;
    }
    if (!replacementAllowed(plan,entry,repository)) {
      throw new Error('冻结的兼容JDK已撤回，或资格/推荐、宿主或目标reader预算改变，请重新核定返回计划');
    }
    if (entry.complete && !replacementPresent(context,entry)) throw new Error('已完成的兼容JDK槽位被外部替换');
  }
}

/**
 * 这里只复核桥所需的当前事实形状；原安装权可信终态和同原UID证明由Coordinator持有。
 * 更高code不能代替product/source/真实宿主集合，重复/未知能力也不能扩大本进程的权限。
 */
function validateSuperseder(target: AppJdkUpdateTarget, current: AppUpdateSuperseder): void {
  if (current === null || typeof current !== 'object' || current.product !== target.product ||
    typeof current.versionName !== 'string' || current.versionName.length === 0 || current.versionName.length > 128 ||
    !Number.isSafeInteger(current.versionCode) || current.versionCode <= target.versionCode || current.versionCode > 2147483647 ||
    !Number.isSafeInteger(current.uid) || current.uid <= 0 || typeof current.sourceRevision !== 'string' ||
    !new RegExp('^[0-9a-f]{40}$').test(current.sourceRevision) || !Array.isArray(current.runtimeHostProtocols) ||
    current.runtimeHostProtocols.length === 0 || current.runtimeHostProtocols.length > 8 ||
    current.runtimeHostProtocols.some((p: number,index: number): boolean => !Number.isSafeInteger(p) || p < 1 || p > 999 || current.runtimeHostProtocols.indexOf(p) !== index)) {
    throw new Error('取代App缺少更高版本、同产品或可信当前身份');
  }
}
/** 未知槽位journal不由取代桥猜测恢复；已知单槽效果恢复后仍要逐项核对真实身份。 */
function recoverSupersededSlots(context: Context, plan: AppRuntimePlan): void {
  let names: string[] = [];
  try { names = fs.listFileSync(context.filesDir + '/jdk/.locks'); }
  catch (error) { if (!missing(error as Object)) throw error as Error; }
  if (names.length > 8192) throw new Error('取代确认的JDK恢复目录超限');
  for (const name of names) {
    const match = name.match(new RegExp('^([1-9][0-9]{0,2})\\.(publish\\.json|journal)$'));
    if (match !== null && !plan.entries.some((entry: RuntimePlanEntry): boolean => entry.major === match[1])) {
      throw new Error('另一个JDK槽位存在未知恢复现场，暂不能结束原兼容计划');
    }
  }
  recoverSlots(context,plan);
  for (const entry of plan.entries) if (JdkInstallStorage.recoveryRequired(context.filesDir,entry.major)) {
    throw new Error('JDK单槽恢复尚未完成，暂不能结束原兼容计划');
  }
}

export class AppJdkUpdatePlanRuntime {
  /**
   * 安装前的数据reader兼容断言。调用者必须已持App EX/fence（prepare内部则持plan EX）；
   * 这里只读全部可选物理槽，不清意图、不恢复/删除未知记录，也不把旧reader能力放大。
   */
  static assertTargetDataCompatibility(context: Context, target: AppJdkUpdateTarget): void {
    targetIdentity(target);
    // Manager普通恢复可能因调用方持plan EX而取不到SH；先查稳定bank，不能只看尚存在的数字槽。
    if (JdkInstallStorage.pendingRecoveryMajors(context.filesDir).length > 0) throw new Error('JDK单槽恢复尚未完成，请先恢复再安装App');
    const manager = new JdkManager(context); const limit = receiptReaderLimit(target);
    for (const state of manager.listVersions()) {
      if (!manager.isStructurallyPresent(state.version)) continue;
      if (JdkInstallStorage.recoveryRequired(context.filesDir,state.version)) throw new Error('JDK单槽恢复尚未完成，请先恢复再安装App');
      const metadata = JSON.parse(slotIdentity(context,state.version)) as SlotReaderMetadata;
      if (metadata.receiptSize > limit) throw new Error('目标App读取能力不足，不能安装后遗留不可读取的JDK收据；请选择恢复reader协议2的App或合格小收据运行时');
      const runtimeIssue=validateRuntimeForHost(context.filesDir + '/jdk/' + state.version,target.runtimeHostProtocols,target.runtimeRequiredCapabilities ?? []);
      if(runtimeIssue!=='')throw new Error('目标App的运行时要求尚未满足：'+runtimeIssue);
    }
    if (JdkInstallStorage.pendingRecoveryMajors(context.filesDir).length > 0) throw new Error('JDK单槽恢复尚未完成，请先恢复再安装App');
  }

  /** Java检查/手机签名前先恢复唯一签名JDK的中断现场，必须绑定原事务和原HAP SHA。 */
  static recoverPendingSlots(context: Context, id: string, assetSha256: string): void {
    const owner = lock(context,id);
    try {
      const plan = readPlan(context); if (plan === null) return;
      if (plan.transactionId !== id || plan.target.sha256 !== assetSha256) throw new Error('JDK恢复计划属于另一更新原件');
      recoverSlots(context,plan);
    } finally { unlock(owner); }
  }

  /** 任何记录都表示有待接续结果；格式损坏不会被静默清除。 */
  static pending(context: Context): boolean { return readPlan(context) !== null; }

  /** 用户在任何槽位切换前取消，可释放本计划；restoring/未知安装结果必须走恢复，不可丢账。 */
  static cancelBeforeRestore(context: Context, id: string, target: AppJdkUpdateTarget): void {
    const owner = lock(context,id);
    try {
      const plan = readPlan(context); if (plan === null) return; assertBinding(plan,id,target);
      if (plan.phase === 'restoring' || plan.phase === 'ready-to-install' || plan.entries.some((e: RuntimePlanEntry): boolean => e.complete)) {
        throw new Error('兼容槽位已经切换，请先确认App更新结果后恢复');
      }
      for (const entry of plan.entries) if (entry.archive.length > 0) {
        if (entry.archive !== context.cacheDir + '/app-runtime-plan/' + id + '/jdk-' + entry.major + '.zip') throw new Error('计划缓存路径身份无效');
        try { fs.unlinkSync(entry.archive); } catch (_) { /* 缓存可能已被系统回收。 */ }
      }
      removePlan(context);
    } finally { unlock(owner); }
  }

  /**
   * 仅原安装器已经证明NoInvocation的分支调用。阶段标签/不变条目的complete不代表有切槽；
   * 全部实际目录仍是before且没有未决单槽记录，才能释放未产生效果的冻结计划并重新选择。
   */
  static cancelNoInvocation(context: Context, id: string, target: AppJdkUpdateTarget): void {
    const owner = lock(context,id);
    try {
      const plan = readPlan(context); if (plan === null) { syncPlanDirectory(context); return; } assertBinding(plan,id,target);
      for (const entry of plan.entries) {
        if (JdkInstallStorage.recoveryRequired(context.filesDir,entry.major) || !sameJdkSlotIdentity(slotIdentity(context,entry.major),entry.before)) {
          throw new Error('兼容计划已有或存在未知槽位效果，必须继续恢复而不能取消');
        }
      }
      for (const entry of plan.entries) if (entry.archive !== '') {
        try { fs.unlinkSync(entry.archive); } catch (error) { if (!missing(error as Object)) throw error as Error; }
      }
      removePlan(context);
    } finally { unlock(owner); }
  }

  static async prepare(context: Context, id: string, target: AppJdkUpdateTarget): Promise<void> {
    if (!new RegExp('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$').test(id) || id.indexOf('..') >= 0) throw new Error('更新事务标识非法');
    targetIdentity(target); const owner = lock(context,id);
    try {
      let plan = readPlan(context);
      JdkInstallStorage.recoverAllWithOwner(context.filesDir,id);
      if (plan !== null) { assertBinding(plan,id,target); recoverSlots(context,plan); }
      const manager = new JdkManager(context); const repository = RuntimeCatalogRepository.instance(context);
      if (plan === null) {
        const entries: RuntimePlanEntry[] = [];
        // 所有可选已安装槽均盘点，不能只检查当前游戏；手机签名也可能优先选另一个JDK。
        for (const state of manager.listVersions()) {
          if (!state.installed && !manager.isStructurallyPresent(state.version)) continue;
          let required = 0;
          const path = context.filesDir + '/jdk/' + state.version;
          if (!state.userImported) {
            try {
              const receipt = JSON.parse(fs.readTextSync(path + '/.amcl-runtime-receipt.json')) as RuntimeInstallReceipt;
              required = receipt.build.requiredHostProtocol !== undefined ? receipt.build.requiredHostProtocol : receipt.runtime.loaderProtocol;
            } catch (_) {
              const catalog = repository.snapshot();
              const build = catalog.builds.find((b: RuntimeBuild): boolean => b.id === state.installedTag || b.legacyTags.indexOf(state.installedTag) >= 0);
              if (build !== undefined) required = runtimeRequiredHost(catalog,build);
            }
          }
          const dropsCapability = runtimeHostProtocols().some((p: number): boolean => target.runtimeHostProtocols.indexOf(p) < 0);
          if (required === 0 && dropsCapability) throw new Error('JDK ' + state.version + ' 来源或宿主要求未知，请明确处理用户运行时后返回');
          const entry: RuntimePlanEntry = {major:state.version,before:slotIdentity(context,state.version),requiredProtocol:required,archive:'',complete:false};
          const behaviorIssue = validateRuntimeForHost(path,target.runtimeHostProtocols,target.runtimeRequiredCapabilities ?? []);
          if (required > 0 && target.runtimeHostProtocols.indexOf(required) < 0 || behaviorIssue !== '') {
            if (state.userImported) throw new Error('本地导入JDK不会自动替换');
            if ((target.runtimePlanProtocol ?? 0) < 2) throw new Error('目标App不支持组合恢复reader协议2，暂不能在此返回路径中替换JDK');
            entry.replacement = readerCompatibleReplacement(state.version,target,repository,manager);
            if (entry.replacement === undefined) throw new Error('JDK ' + state.version + ' 没有目标App可读取的合格兼容构建，暂不能返回此App');
            entry.archive = context.cacheDir + '/app-runtime-plan/' + id + '/jdk-' + state.version + '.zip';
          }
          entries.push(entry);
        }
        // 无槽位变化时沿用原App事务即可；历史目标不理解新sidecar，也不会被新锁永久保护。
        if (entries.every((entry: RuntimePlanEntry): boolean => entry.replacement === undefined)) {
          AppJdkUpdatePlanRuntime.assertTargetDataCompatibility(context,target); return;
        }
        plan = {schemaVersion:1,transactionId:id,target:JSON.parse(JSON.stringify(target)) as AppJdkUpdateTarget,
          phase:'preparing',signedPath:'',entries:entries};
        savePlan(context,plan);
      }
      assertBinding(plan,id,target);
      repairLegacyReaderEntries(context,plan,repository,manager);
      replanUnavailable(context,plan,repository,manager);
      assertReplacementAllowed(context,plan,repository);
      if (plan.phase === 'ready-to-install') { AppJdkUpdatePlanRuntime.assertTargetDataCompatibility(context,target); return; }
      const previousPhase = plan.phase;
      // 真实重试总会先prepare：先认领已发布的完整替代收据，不能让before不相等挡住后续恢复。
      if (plan.phase === 'restoring') for (const entry of plan.entries) {
        if (!entry.complete && !sameJdkSlotIdentity(slotIdentity(context,entry.major),activeFrom(entry))) {
          if (!replacementPresent(context,entry)) throw new Error('JDK身份在恢复期间改变，保留计划');
          entry.complete = true; savePlan(context,plan);
        }
      }
      // 缺签名JDK时，用户可能按恢复引导新装了一份兼容运行时；只把不增加恢复动作的新增槽纳入。
      for (const state of manager.listVersions()) {
        if (!manager.isStructurallyPresent(state.version) || plan.entries.some((entry: RuntimePlanEntry): boolean => entry.major === state.version)) continue;
        let required = 0;
        try {
          const receipt = JSON.parse(fs.readTextSync(context.filesDir + '/jdk/' + state.version + '/.amcl-runtime-receipt.json')) as RuntimeInstallReceipt;
          required = receipt.build.requiredHostProtocol !== undefined ? receipt.build.requiredHostProtocol : receipt.runtime.loaderProtocol;
        } catch (_) { /* 未知导入只能在目标能力不缩减时保留。 */ }
        const drops = runtimeHostProtocols().some((p: number): boolean => target.runtimeHostProtocols.indexOf(p) < 0);
        if (required > 0 && target.runtimeHostProtocols.indexOf(required) < 0 || required === 0 && drops ||
          validateRuntimeForHost(context.filesDir + '/jdk/' + state.version,target.runtimeHostProtocols,target.runtimeRequiredCapabilities ?? []) !== '') throw new Error('新增JDK需重新确认兼容返回计划');
        plan.entries.push({major:state.version,before:slotIdentity(context,state.version),requiredProtocol:required,archive:'',complete:false});
      }
      repairLegacyReaderEntries(context,plan,repository,manager);
      assertReplacementAllowed(context,plan,repository);

      const replacements = plan.entries.filter((entry: RuntimePlanEntry): boolean => entry.replacement !== undefined && !entry.complete);
      if (replacements.length > 0) {
        let originalBytes = 0; for (const entry of replacements) originalBytes += entry.replacement!.sizeBytes!;
        // 完整原件同时保留，解压逐槽执行；按既有安全解压最大输出预算留出一次新目录和收据余量。
        if (statfs.getFreeSizeSync(context.filesDir) < originalBytes + 2147483647 + 67108864) throw new Error('空间不足以安全准备兼容JDK与回滚目录');
      }
      for (const entry of plan.entries) {
        if (entry.complete) continue;
        if (!sameJdkSlotIdentity(slotIdentity(context,entry.major),activeFrom(entry))) throw new Error('JDK安装身份已变化，请重新核定兼容计划');
        if (entry.replacement === undefined) continue;
        const installer = new JdkInstaller({context:context,version:entry.major,config:entry.replacement,
          targetDir:context.filesDir + '/jdk/' + entry.major,isInstalledFn:(): boolean => manager.isInstalled(entry.major),forceReinstall:true});
        // 每轮准备重新校验；缓存文件可能被系统收回，不能把上次prepared当成本轮仍存在。
        await installer.prepareArchive(entry.archive);
      }
      assertReplacementAllowed(context,plan,repository);
      plan.phase = previousPhase === 'preparing' ? 'prepared' : previousPhase; savePlan(context,plan);
    } finally { unlock(owner); }
  }

  /** 只由已核验签名结果的Coordinator调用；原件SHA与目标能力每次重新绑定。 */
  static markAppSigned(context: Context, id: string, target: AppJdkUpdateTarget, signedPath: string): void {
    const owner = lock(context,id);
    try {
      const plan = readPlan(context); if (plan === null) return; assertBinding(plan,id,target);
      if (signedPath !== context.filesDir + '/sideload-update/tasks/' + id + '/signed.hap') throw new Error('签名产物不属于本更新事务');
      if (['prepared','signed','restoring','ready-to-install'].indexOf(plan.phase) < 0 || !fs.lstatSync(signedPath).isFile()) throw new Error('目标App尚未完成签名准备');
      plan.signedPath = signedPath; if (plan.phase === 'prepared') plan.phase = 'signed'; savePlan(context,plan);
    } finally { unlock(owner); }
  }

  /** 必须由已持App EX/fence的同一安装owner调用；不再次申请App共享锁造成自死锁。 */
  static async restore(context: Context, id: string, target: AppJdkUpdateTarget): Promise<void> {
    const owner = lock(context,id);
    try {
      const plan = readPlan(context);
      if (plan === null) {
        targetIdentity(target);
        // prepare之后普通写者也可能遗留新的两次rename中间现场。此处已有真实plan owner，
        // 必须用它恢复整个bank；不能让Manager的普通SH恢复冲突被吞成“该槽未安装”。
        JdkInstallStorage.recoverAllWithOwner(context.filesDir,id);
        if (JdkInstallStorage.pendingRecoveryMajors(context.filesDir).length > 0) throw new Error('JDK单槽恢复尚未完成，暂不能安装App');
        const manager = new JdkManager(context); const c = RuntimeCatalogRepository.instance(context).snapshot();
        for (const state of manager.listVersions()) {
          if (!manager.isStructurallyPresent(state.version)) continue;
          let required = 0;
          try {
            const receipt = JSON.parse(fs.readTextSync(context.filesDir + '/jdk/' + state.version + '/.amcl-runtime-receipt.json')) as RuntimeInstallReceipt;
            required = receipt.build.requiredHostProtocol ?? receipt.runtime.loaderProtocol;
          } catch (_) {
            const b = c.builds.find((build: RuntimeBuild): boolean => build.id === state.installedTag || build.legacyTags.indexOf(state.installedTag) >= 0);
            if (b !== undefined) required = runtimeRequiredHost(c,b);
          }
          const drops = runtimeHostProtocols().some((p: number): boolean => target.runtimeHostProtocols.indexOf(p) < 0);
          if (required > 0 && target.runtimeHostProtocols.indexOf(required) < 0 || required === 0 && drops ||
            validateRuntimeForHost(context.filesDir + '/jdk/' + state.version,target.runtimeHostProtocols,target.runtimeRequiredCapabilities ?? []) !== '') throw new Error('JDK在App安装前改变，请先重新准备兼容计划');
        }
        AppJdkUpdatePlanRuntime.assertTargetDataCompatibility(context,target); return;
      }
      assertBinding(plan,id,target);
      if (['signed','restoring','ready-to-install'].indexOf(plan.phase) < 0 || !fs.lstatSync(plan.signedPath).isFile()) throw new Error('请先完成目标App重签');
      // 若上次死在单槽两次rename之间，先用本计划owner恢复，再盘点数字目录；不能因target缺席漏槽。
      recoverSlots(context,plan);
      const repository = RuntimeCatalogRepository.instance(context); const manager = new JdkManager(context);
      const availableSlots = manager.listVersions().filter((state: JdkVersionInfo): boolean => manager.isStructurallyPresent(state.version)).map((state: JdkVersionInfo): string => state.version).sort();
      if (JSON.stringify(availableSlots) !== JSON.stringify(plan.entries.map((entry: RuntimePlanEntry): string => entry.major).sort())) throw new Error('JDK槽位集合已变化，请先恢复/重新核定兼容计划');
      assertReplacementAllowed(context,plan,repository);
      if (plan.phase === 'ready-to-install') { AppJdkUpdatePlanRuntime.assertTargetDataCompatibility(context,target); return; }
      plan.phase = 'restoring'; savePlan(context,plan);
      for (const entry of plan.entries) {
        if (entry.complete) continue;
        if (!sameJdkSlotIdentity(slotIdentity(context,entry.major),activeFrom(entry))) {
          // 单槽已提交而高层complete尚未持久化时，按完整收据认领该步，不能重下或覆盖未知安装。
          const matches = replacementPresent(context,entry);
          if (!matches) throw new Error('JDK身份在兼容切换前改变，保留计划等待恢复');
          entry.complete = true; savePlan(context,plan); continue;
        }
        if (entry.replacement !== undefined) {
          if (!repository.isBuildAllowed(entry.replacement.build!.id)) throw new Error('准备的兼容JDK已被撤回，不能切换');
          const installer = new JdkInstaller({context:context,version:entry.major,config:entry.replacement,
            targetDir:context.filesDir + '/jdk/' + entry.major,isInstalledFn:(): boolean => manager.isInstalled(entry.major),forceReinstall:true});
          await installer.installPreparedArchive(entry.archive,id);
        }
        entry.complete = true; savePlan(context,plan);
      }
      assertReplacementAllowed(context,plan,repository);
      AppJdkUpdatePlanRuntime.assertTargetDataCompatibility(context,target);
      plan.phase = 'ready-to-install'; savePlan(context,plan);
    } finally { unlock(owner); }
  }

  /** 仅真实App Verified后封账；未知BMS/新App不认领时持续保留，不自动降级为成功。 */
  static verified(context: Context, id: string, target: AppJdkUpdateTarget): void {
    const owner = lock(context,id);
    try {
      const plan = readPlan(context); if (plan === null) { syncPlanDirectory(context); return; } assertBinding(plan,id,target);
      if (plan.phase !== 'ready-to-install') throw new Error('App/JDK兼容切换尚未完成，不能封账');
      removePlan(context);
    } finally { unlock(owner); }
  }

  /**
   * 只由Coordinator已持久化的真实Superseded终态调用，绝不把原target标成Verified或确认
   * 旧JDK意图。原执行权/同UID由调用者证明；桥在真实plan EX内绑定原目标、当前宿主，
   * 检查全部可选槽位为已知效果且当前Manager可用后，才幂等移除原计划并同步父目录。
   */
  static superseded(context: Context, id: string, originalTarget: AppJdkUpdateTarget, current: AppUpdateSuperseder): void {
    targetIdentity(originalTarget); validateSuperseder(originalTarget,current);
    const actual = runtimeHostProtocols().slice().sort((a: number,b: number): number => a - b);
    const claimed = current.runtimeHostProtocols.slice().sort((a: number,b: number): number => a - b);
    if (JSON.stringify(actual) !== JSON.stringify(claimed)) throw new Error('取代App宿主声明不是本进程真实能力');
    const owner = lock(context,id);
    try {
      const plan = readPlan(context); if (plan === null) { syncPlanDirectory(context); return; }
      assertBinding(plan,id,originalTarget); recoverSupersededSlots(context,plan);
      const manager = new JdkManager(context);
      const slots = manager.listVersions().filter((state: JdkVersionInfo): boolean => manager.isStructurallyPresent(state.version))
        .map((state: JdkVersionInfo): string => state.version).sort();
      const expected = plan.entries.map((entry: RuntimePlanEntry): string => entry.major).sort();
      if (JSON.stringify(slots) !== JSON.stringify(expected)) throw new Error('取代App的JDK槽位集合有未知变化，已保留原计划');
      for (const entry of plan.entries) {
        const observed = slotIdentity(context,entry.major);
        let known = sameJdkSlotIdentity(observed,entry.before) || sameJdkSlotIdentity(observed,activeFrom(entry)) || replacementPresent(context,entry);
        for (const attempt of entry.history ?? []) {
          if (sameJdkSlotIdentity(observed,attempt.from) || attempt.installedIdentity !== '' && sameJdkSlotIdentity(observed,attempt.installedIdentity)) known = true;
        }
        if (!known || !manager.isInstalled(entry.major)) throw new Error('取代App仍有未知或不兼容JDK效果，已保留原计划');
      }
      // Coordinator是唯一耐久终态；不给接近1MiB预算的旧计划再追加第二套终态数据。
      // unlink或目录同步失败时调用者保持attention；无plan重试仍会再次同步父目录。
      removePlan(context);
    } finally { unlock(owner); }
  }
}

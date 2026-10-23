/**
 * Forge/NeoForge 完整包的共享准备层。只在本次导出 owner 的私有树工作，绝不调用安装入口、
 * 写回源 libraries 或改变版本列表。固定官方安装器经 SHA1 核验后提供 profile、内嵌运行件和
 * processor 输入；缺少官方输出摘要的产物必须用这些已验证输入在独立 root 重建。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ExportDependency, ExportResolvedVersion, ExportPlatform, ExportForgelikeEvidence,
  ForgelikeExportPlanner, DesktopDependencyPlanner, ExportVersionResolver as V, ExportPath,
  exportHasErrors, safeRelPath, mavenToRelativePath, installedJdkMajors, forgeNative,
  ForgelikeProcessorRunner, ModLoaderInstallProgress, ExportIssue, buildMavenUrls, shouldUseBmclapiFirst } from 'feature_core';
import { exportPathExists, assertExportPath, readExportText, selectExportDependencySource } from './ExportSourceInspector';
import { hashExportFile } from './ExportArchiveIO';
import { verifyExportJar, extractVerifiedExportJar } from './ExportJarVerifier';
import { ensureExportDirectory } from './ExportDirectory';

/** 每个工件携带自己的候选；批次不能把A的私服或坐标候选误用于B。 */
export interface ExportDependencyCandidates { path: string; urls: string[]; }
/** 下载回调由 coordinator 独占管理 Native owner；旧单工件候选参数继续兼容。 */
export type ExportDependencyDownload = (dependencies: ExportDependency[], root: string, urls?: string[],
  candidates?: ExportDependencyCandidates[]) => Promise<void>;
export type ExportPreparationProgress = (message: string) => void;
/** 同阶段输入在解析后统一准备；可信本地副本仍逐件校验，远端缺件才组成一个批次。 */
interface ExportPreparationInput { dependency: ExportDependency; urls?: string[]; }

/** 每个 await 后才检查取消；进行中的 SDK 解压或 Native JVM 必须先真实结算。 */
function active(cancelled: () => boolean): void { if (cancelled()) throw new Error('已请求取消导出'); }
/** @throws 目录不可建、权限撤回或发现链接时交给导出 owner 终止并保留现场。 */
async function mkdir(path: string, trustedRoot: string): Promise<void> {
  await ensureExportDirectory(path, trustedRoot);
  await assertExportPath(path);
}
function parent(path: string): string { return path.substring(0, path.lastIndexOf('/')); }

/** 文件复制前后核对来源，任何链接、摘要变化或短副本都阻断，目标始终属于本任务。
 * @throws 来源不安全、摘要不匹配、取消或 FileIO 失败交给导出 owner 处理。
 */
async function verifiedCopy(sourceRoot: string, relative: string, target: string, trustedRoot: string,
  sha1: string, cancelled: () => boolean): Promise<void> {
  active(cancelled); await assertExportPath(sourceRoot, relative);
  const source = sourceRoot + '/' + relative;
  const before = await hashExportFile(source, cancelled);
  if (sha1.length > 0 && before.sha1 !== sha1.toLowerCase()) throw new Error('准备输入摘要不符：' + relative);
  await mkdir(parent(target), trustedRoot); await fs.copyFile(source, target);
  const copied = await hashExportFile(target, cancelled);
  const after = await hashExportFile(source, cancelled);
  if (before.sha256 !== copied.sha256 || before.sha256 !== after.sha256 || before.size !== copied.size) {
    throw new Error('准备输入在复制期间变化：' + relative);
  }
}

/**
 * 优先复用可信 SHA 对应的源字节，否则走任务下载缓存。无上游 SHA 的远端库必须先取同源
 * sidecar，再下载；不能仅因原实例有同名 JAR 就让 processor 执行未核实字节。
 * @throws 输入无法核实、下载失败或取消时停止准备，不回写源文件。
 */
async function prepareInputs(inputs: ExportPreparationInput[], sourceRoot: string, targetRoot: string,
  download: ExportDependencyDownload, cancelled: () => boolean): Promise<void> {
  const missing: ExportDependency[] = [];
  const candidates: ExportDependencyCandidates[] = [];
  for (const input of inputs) {
    active(cancelled);
    const dependency = input.dependency;
    if (dependency.sha1.length > 0) {
      const selected = await selectExportDependencySource(sourceRoot, dependency, cancelled);
      if (selected !== undefined) {
        await verifiedCopy(sourceRoot, selected, targetRoot + '/' + dependency.path, targetRoot, dependency.sha1, cancelled);
        continue;
      }
    }
    if (!ExportPath.https(dependency.url)) throw new Error('安装器输入没有可信的下载来源：' + dependency.path);
    missing.push(dependency);
    if (input.urls !== undefined) candidates.push({ path: dependency.path, urls: input.urls });
  }
  // 不在此另建Promise.all/下载循环，统一owner负责元数据并发、正文批次和真实取消结算。
  if (missing.length > 0) await download(missing, targetRoot, undefined, candidates);
  active(cancelled);
}

/** profile 输入只取真实 artifact/path 或 Maven 坐标，内嵌件由已验证 installer 提供。
 * @throws 输入声明不安全、复制/下载失败或取消时停止当前准备。
 */
async function prepareProcessorLibraries(profile: Record<string, Object>, unpacked: string,
  runtimeRoot: string, cancelled: () => boolean): Promise<ExportPreparationInput[]> {
  const libraries = Array.isArray(profile['libraries']) ? profile['libraries'] as Object[] : [];
  const inputs: ExportPreparationInput[] = [];
  for (const raw of libraries) {
    active(cancelled);
    const lib = V.object(raw);
    const artifact = V.object(V.object(lib['downloads'])['artifact']);
    const relative = V.string(artifact, 'path') || mavenToRelativePath(V.string(lib, 'name'));
    if (relative.length === 0 || safeRelPath(relative) !== relative) throw new Error('安装器输入路径不安全');
    const path = 'libraries/' + relative;
    const bundled = 'maven/' + relative;
    const sha1 = V.string(artifact, 'sha1').toLowerCase();
    if (sha1.length > 0 && !/^[0-9a-f]{40}$/.test(sha1)) throw new Error('安装器输入 SHA1 无效：' + relative);
    if (await exportPathExists(unpacked + '/' + bundled)) {
      await verifiedCopy(unpacked, bundled, runtimeRoot + '/' + path, runtimeRoot, sha1, cancelled);
      continue;
    }
    const url = V.string(artifact, 'url');
    // 空 URL 的生成件不是 processor 输入下载；后续由运行闭包核验输出是否真实存在。
    if (url.length === 0) continue;
    const size = artifact['size'];
    const dependency: ExportDependency = { path: path, url: url, sha1: sha1,
      size: typeof size === 'number' && Number.isSafeInteger(size) && size > 0 ? size as number : 0,
      kind: 'library', generated: false };
    // 候选只来自既有Maven等价来源规则；先后顺序遵守统一下载设置与已缓存排名，
    // 不再在导出准备层固定官方优先。无论选哪一源，输入仍须匹配同一工件SHA。
    inputs.push({ dependency, urls: buildMavenUrls(V.string(lib, 'name'), undefined, !shouldUseBmclapiFirst(), url) });
  }
  return inputs;
}

/** MOJMAPS 是 processor 输入，来自原版 downloads.client_mappings 的精确 URL/SHA，而不是无摘要文本下载。
 * @throws 需要映射但缺少可信元数据、下载失败或取消时阻断重建。
 */
function prepareMappings(version: ExportResolvedVersion, profile: Record<string, Object>): ExportPreparationInput | undefined {
  const raw = V.string(V.object(V.object(profile['data'])['MOJMAPS']), 'client');
  if (raw.length === 0) return undefined;
  const relative = raw.startsWith('[') && raw.endsWith(']') ? mavenToRelativePath(raw.substring(1, raw.length - 1)) : '';
  const mapping = V.object(V.object(version.json['downloads'])['client_mappings']);
  const sha1 = V.string(mapping, 'sha1').toLowerCase();
  const url = V.string(mapping, 'url');
  if (relative.length === 0 || !/^[0-9a-f]{40}$/.test(sha1) || !ExportPath.https(url)) {
    throw new Error('安装器需要原版客户端映射，但源元数据没有可验证的映射身份');
  }
  const size = mapping['size'];
  return { dependency: { path: 'libraries/' + relative, url: url, sha1: sha1,
    size: typeof size === 'number' ? size as number : 0, kind: 'library', generated: false } };
}

/** 只选择已安装且完整的兼容 JDK。仅实际需要重建时检查；传统内嵌包和可信输出复用均不要求 JDK/JIT。
 * @throws JDK 文件不可读/不完整、没有兼容 JDK 或 JIT 权限时说明重建所缺前提。
 */
async function processorJdk(filesDir: string, version: ExportResolvedVersion, installerVersion: Record<string, Object>): Promise<string> {
  const java = V.object(installerVersion['javaVersion']);
  const declared = java['majorVersion'];
  const mcJava = V.object(version.json['javaVersion'])['majorVersion'];
  const minimum = typeof declared === 'number' ? declared as number : typeof mcJava === 'number' ? mcJava as number : 17;
  const chosen = installedJdkMajors(filesDir).filter((major: number): boolean => major >= minimum).sort((a: number, b: number): number => a - b)[0];
  if (chosen === undefined) throw new Error('重建加载器运行件需要已安装的 JDK ' + minimum + ' 或更高版本，请在下载页安装后重试');
  for (const relative of ['release', 'lib/server/libjvm.so', 'lib/modules']) {
    const path = filesDir + '/jdk/' + chosen + '/' + relative;
    await assertExportPath(filesDir + '/jdk/' + chosen, relative);
    if ((await fs.lstat(path)).size <= 0) throw new Error('重建所需的 JDK 运行时不完整');
  }
  if (!forgeNative().checkJitAvailable()) throw new Error('当前设备没有执行加载器处理器所需的 JIT 权限');
  return String(chosen);
}

/**
 * 返回可直接交给最终 FilePlan 的完整依赖。cache 为 coordinator 的独占 dependency 根，generated
 * 的 sourcePath 也固定为 cache 内路径；失败保留工作现场，取消由外层在本 Promise 结束后清理。
 * @throws 安装器/生成件校验失败、processor 失败、I/O/网络失败或取消由同一导出 owner 收口。
 */
export async function prepareForgelikeExport(version: ExportResolvedVersion, platform: ExportPlatform,
  indexText: string, sourceRoot: string, filesDir: string, work: string, cache: string,
  download: ExportDependencyDownload, progress: ExportPreparationProgress,
  cancelled: () => boolean): Promise<ExportDependency[]> {
  const installer = ForgelikeExportPlanner.describe(version);
  const preparation = work + '/forgelike'; await mkdir(preparation, work);
  const installerFile: ExportDependency = { path: installer.path, url: installer.url, sha1: '', size: 0, kind: 'library', generated: false };
  progress('取得并校验 ' + installer.loaderKind + ' ' + installer.loaderVersion + ' 的精确安装器');
  // 安装器沿用与普通库相同的源偏好；显式官方URL仍保留为候选，镜像缺件可由引擎回退。
  // 此处不另发测速/正文请求，也不改变后续sidecar、安装器校验及processor的依赖顺序。
  await download([installerFile], preparation,
    buildMavenUrls(installer.coordinate, undefined, !shouldUseBmclapiFirst(), installer.url)); active(cancelled);
  // 同一校验器事前检查路径/链接/边界，解压后逐条核对 CRC；不存在直接解压未知归档的分支。
  const unpacked = preparation + '/installer';
  await extractVerifiedExportJar(preparation + '/' + installer.path, unpacked, ['install_profile.json'], [], cancelled);
  const profileText = await readExportText(unpacked, 'install_profile.json');
  const profile = V.object(JSON.parse(profileText) as Object);
  let versionText = '';
  const reference = V.string(profile, 'json').replace(/^\/+/, '');
  if (reference.length > 0) {
    if (safeRelPath(reference) !== reference) throw new Error('安装器版本描述路径不安全');
    versionText = await readExportText(unpacked, reference);
  } else if (Object.keys(V.object(profile['versionInfo'])).length > 0) versionText = JSON.stringify(profile['versionInfo']);
  else versionText = await readExportText(unpacked, 'version.json');
  const profileDigest = await hashExportFile(unpacked + '/install_profile.json', cancelled);
  const evidence: ExportForgelikeEvidence = { installerProfileJson: profileText, installerVersionJson: versionText,
    installerSha1: installerFile.sha1, profileSha256: profileDigest.sha256 };
  const plan = DesktopDependencyPlanner.plan(version, platform, indexText, evidence);
  if (exportHasErrors(plan.issues)) throw new Error(plan.issues.find((issue: ExportIssue): boolean => issue.severity === 'error')?.message ?? '加载器运行闭包无效');
  const generated = plan.dependencies.filter((dependency: ExportDependency): boolean => dependency.generated);
  const runtimeRoot = preparation + '/runtime'; await mkdir(runtimeRoot, work);
  let rebuild = false;
  for (const dependency of generated) {
    const provenance = dependency.provenance;
    if (provenance === undefined) throw new Error('加载器生成件没有绑定的安装器来源');
    const target = cache + '/' + dependency.path;
    if (provenance.validation === 'installer-entry') {
      await verifiedCopy(unpacked, provenance.entryPath, target, cache, provenance.expectedSha1, cancelled);
      provenance.preparation = 'installer-entry';
    } else if (provenance.expectedSha1.length > 0) {
      const selected = await selectExportDependencySource(sourceRoot, dependency, cancelled);
      if (selected !== undefined) {
        await verifiedCopy(sourceRoot, selected, target, cache, provenance.expectedSha1, cancelled);
        provenance.preparation = 'verified-source';
      } else rebuild = true;
    } else rebuild = true;
  }
  if (rebuild) {
    const jdk = await processorJdk(filesDir, version, V.object(JSON.parse(versionText) as Object));
    progress('在导出专用目录中准备已校验的加载器处理器输入');
    const inputs = await prepareProcessorLibraries(profile, unpacked, runtimeRoot, cancelled);
    const mapping = prepareMappings(version, profile);
    if (mapping !== undefined) inputs.push(mapping);
    await prepareInputs(inputs, sourceRoot, runtimeRoot, download, cancelled);
    const client = plan.dependencies.find((dependency: ExportDependency): boolean => dependency.kind === 'client');
    if (client === undefined || client.sha1.length === 0) throw new Error('重建缺少可信的原版客户端');
    const selected = await selectExportDependencySource(sourceRoot, client, cancelled);
    if (selected === undefined) throw new Error('原版客户端已变化，请重新检查');
    await verifiedCopy(sourceRoot, selected, runtimeRoot + '/versions/' + version.vanillaVersion + '/' + version.vanillaVersion + '.jar', runtimeRoot, client.sha1, cancelled);
    active(cancelled);
    // 沿用安装链路的 clean-classpath fork 和全局 processor 锁；callback 仅在步骤边界取消，
    // 正在运行的 JVM 完成后 Promise 才收口，外层绝不会提前删除其工作目录。
    const result = await ForgelikeProcessorRunner.run(unpacked + '/install_profile.json', unpacked, runtimeRoot,
      runtimeRoot + '/libraries', filesDir, version.vanillaVersion, jdk,
      Math.max(512, Math.min(2048, forgeNative().getRecommendedXmx())), installer.loaderKind,
      (step: ModLoaderInstallProgress): void => { active(cancelled); progress(step.message); });
    active(cancelled);
    if (!result.success) throw new Error('导出专用运行件重建失败：' + result.error);
    for (const dependency of generated) {
      const provenance = dependency.provenance;
      if (provenance === undefined || provenance.validation === 'installer-entry') continue;
      await verifiedCopy(runtimeRoot, dependency.path, cache + '/' + dependency.path, cache, provenance.expectedSha1, cancelled);
      provenance.preparation = 'verified-processor-rebuild';
    }
  }
  let sequence = 0;
  for (const dependency of generated) {
    active(cancelled);
    const provenance = dependency.provenance;
    if (provenance === undefined) throw new Error('运行件来源已失效');
    progress('校验加载器运行件：' + provenance.role);
    const path = cache + '/' + dependency.path;
    await verifyExportJar(path, preparation + '/verify-' + sequence++, provenance.expectedEntries, provenance.expectedEntryPrefixes, cancelled);
    const digest = await hashExportFile(path, cancelled);
    if (provenance.expectedSha1.length > 0 && digest.sha1 !== provenance.expectedSha1) throw new Error('运行件与安装器预期 SHA1 不符：' + provenance.role);
    dependency.size = digest.size; dependency.sha1 = digest.sha1; dependency.sourcePath = dependency.path;
    dependency.generatedIdentity = { sha1: digest.sha1, sha256: digest.sha256, size: digest.size,
      validation: provenance.expectedSha1.length > 0 ? 'installer-output-sha1' : 'jar-crc32' };
  }
  const runtimeInputs: ExportPreparationInput[] = [];
  for (const dependency of plan.dependencies) {
    if (dependency.generated) continue;
    const selected = await selectExportDependencySource(sourceRoot, dependency, cancelled);
    if (dependency.sha1.length > 0 && selected !== undefined) dependency.sourcePath = selected;
    else runtimeInputs.push({ dependency });
  }
  await prepareInputs(runtimeInputs, sourceRoot, cache, download, cancelled);
  return plan.dependencies;
}

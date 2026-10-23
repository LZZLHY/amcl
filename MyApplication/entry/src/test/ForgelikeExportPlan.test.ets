/**
 * Forge/NeoForge 导出运行闭包回归。固定小样本来自已核对的 installer 结构，测试执行真实纯规划器，
 * 不伪造 I/O 已经验证文件；只有测试“最终准入”时才显式注入完整 JAR 校验边界的结果。
 */
import { describe, expect, it } from '@ohos/hypium';
import { DesktopDependencyPlanner, ExportDependency, ExportDependencyPlan, ExportFilePlan, ExportForgelikeEvidence,
  ExportForgelikePlan, ExportIssue, ExportPlannedFile, ExportRequest, ExportResolvedVersion,
  ExportVersionResolver, ExportVersionSource, ForgelikeExportPlanner } from 'feature_core';

const FL_SHA1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const FL_SHA256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/** 小样本只保存角色、坐标、来源及摘要形状，不把整个安装器或用户资料纳入仓库。 */
function flLibrary(coordinate: string, path: string, url: string = 'https://example.org/runtime.jar'): Record<string, Object> {
  const artifact: Record<string, Object> = { 'path': path, 'url': url, 'sha1': FL_SHA1, 'size': 120 };
  const downloads: Record<string, Object> = { 'artifact': artifact };
  return { 'name': coordinate, 'downloads': downloads };
}

/** 精确产品参数与 FML 模块版本刻意不同，保护 NeoForge 的真实产品身份。 */
function flVersion(kind: string, yearly: boolean = false): ExportResolvedVersion {
  const mc = yearly ? '26.2' : '1.21.1';
  const product = yearly ? '26.2.0.40-beta' : kind === 'neoforge' ? '21.1.9' : '52.0.1';
  const game = [kind === 'neoforge' ? '--fml.neoForgeVersion' : '--fml.forgeVersion', product, '--fml.mcVersion', mc];
  const args: Record<string, Object> = { 'game': game, 'jvm': ['-DlibraryDirectory=${library_directory}'] };
  const module = flLibrary('net.neoforged.fancymodloader:loader:11.0.13', 'net/neoforged/fancymodloader/loader/11.0.13/loader-11.0.13.jar');
  const body: Record<string, Object> = { 'id': 'chosen', 'clientVersion': mc, 'arguments': args,
    'mainClass': kind === 'neoforge' ? 'net.neoforged.fml.startup.Client' : 'cpw.mods.bootstraplauncher.BootstrapLauncher',
    'libraries': [module] };
  const source: ExportVersionSource = { id: 'chosen', jsonText: JSON.stringify(body) };
  return ExportVersionResolver.resolve('chosen', [source]);
}

/** 构造同一已验安装器中的 profile/version 文本；expected hashes 与实际身份在测试中仍分开。 */
function flEvidence(version: ExportResolvedVersion, yearly: boolean = false): ExportForgelikeEvidence {
  const installer = ForgelikeExportPlanner.describe(version);
  const product = installer.coordinate.substring(0, installer.coordinate.lastIndexOf(':'));
  const parts = product.split(':');
  const group = parts[0].split('.').join('/');
  const universalPath = group + '/' + parts[1] + '/' + parts[2] + '/' + parts[1] + '-' + parts[2] + '-universal.jar';
  const libraries: Object[] = [flLibrary(product + ':universal', universalPath)];
  if (version.loader.kind === 'forge') {
    for (const name of ['fmlcore', 'javafmllanguage', 'lowcodelanguage', 'mclanguage']) libraries.push(flLibrary(parts[0] + ':' + name + ':' + parts[2], group + '/' + name + '/' + parts[2] + '/' + name + '-' + parts[2] + '.jar'));
  }
  const data: Record<string, Object> = {};
  const patched: Record<string, Object> = { 'client': '[' + (yearly ? 'net.neoforged:minecraft-client-patched:' + version.loader.version : product + ':client') + ']' };
  data['PATCHED'] = patched;
  if (!yearly) {
    const srg: Record<string, Object> = { 'client': '[net.minecraft:client:' + version.vanillaVersion + '-stamp:srg]' };
    const extra: Record<string, Object> = { 'client': '[net.minecraft:client:' + version.vanillaVersion + '-stamp:extra]' };
    const slim: Record<string, Object> = { 'client': '[net.minecraft:client:' + version.vanillaVersion + '-stamp:slim]' };
    data['MC_SRG'] = srg; data['MC_EXTRA'] = extra; data['MC_SLIM'] = slim;
  }
  if (version.loader.kind === 'forge') {
    const hash: Record<string, Object> = { 'client': "'" + FL_SHA1 + "'" };
    data['PATCHED_SHA'] = hash;
  }
  const processor: Record<string, Object> = { 'jar': 'example:processor:1', 'args': ['--output', '{PATCHED}'] };
  const profile: Record<string, Object> = { 'spec': 1, 'minecraft': version.vanillaVersion,
    'version': version.loader.kind === 'neoforge' ? 'neoforge-' + version.loader.version : version.vanillaVersion + '-forge-' + version.loader.version,
    'data': data, 'processors': [processor], 'libraries': libraries };
  return { installerProfileJson: JSON.stringify(profile), installerVersionJson: JSON.stringify(version.json),
    installerSha1: FL_SHA1, profileSha256: FL_SHA256 };
}

/** 最终文件计划测试固定 Windows x64，不依赖账户、OHOS JDK 或启动器运行。 */
function flRequest(): ExportRequest {
  return { mcRoot: '/source', gameDir: '/source/versions/chosen', versionId: 'chosen', exportId: 'portable',
    displayName: '可移植版本', format: 'full', launcher: 'hmcl', platform: { os: 'windows', arch: 'x64', version: '' },
    includeDirectories: [], includeFiles: [], selectedWorlds: [], sharedGameDir: false };
}

/** 只为准入测试注入 I/O 边界结果，不能让规划器自行把“有路径”变成文件已通过验证。 */
function flValidated(plan: ExportForgelikePlan): void {
  for (const dependency of plan.dependencies) {
    if (!dependency.generated || dependency.provenance === undefined) continue;
    const origin = dependency.provenance;
    origin.preparation = origin.validation === 'installer-entry' ? 'installer-entry'
      : origin.expectedSha1.length > 0 ? 'verified-source' : 'verified-processor-rebuild';
    dependency.generatedIdentity = { sha1: origin.expectedSha1 || FL_SHA1, sha256: FL_SHA256, size: 123,
      validation: origin.expectedSha1.length > 0 ? 'installer-output-sha1' : 'jar-crc32' };
  }
}

/**
 * 传统库样本逐字段取自 Forge 1.7.10-10.13.4.1614-1.7.10 的真实 install_profile.json。
 * 原 installer SHA1=fccafccf8ad4ce6d9f008e786b48ff53172bf9de；这里只保留两件缺 sidecar 的库，
 * 不复制原用户实例，也不把缩减后的测试 JSON 冒充原 profile 字节或实际已经验证的 JAR。
 * 这两个 primary 已由官方原 JAR 完整 SHA1 复核，测试仍只断言规划结果中的“期望值”。
 */
function flLegacyChecksumLibrary(xml: boolean): Record<string, Object> {
  return xml ? {
    'name': 'org.scala-lang:scala-xml_2.11:1.0.2', 'url': 'https://maven.minecraftforge.net/',
    'checksums': ['7a80ec00aec122fba7cd4e0d4cdd87ff7e4cb6d0', '62736b01689d56b6d09a0164b7ef9da2b0b9633d'],
    'serverreq': true, 'clientreq': true
  } : {
    'name': 'org.scala-lang:scala-parser-combinators_2.11:1.0.1', 'url': 'https://maven.minecraftforge.net/',
    'checksums': ['f05d7345bf5a58924f2837c6c1f4d73a938e1ff0', 'a1cbbcbde1dcc614f4253ed1aa0b320bc78d8f1d'],
    'serverreq': true, 'clientreq': true
  };
}

/** 当前实例仅有 name/url；可信 checksums 必须来自另行传入并通过发布身份绑定的 evidence。 */
function flLegacyChecksumVersion(): ExportResolvedVersion {
  const product = 'net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10';
  const loader: Record<string, Object> = { 'name': product, 'url': 'https://maven.minecraftforge.net/' };
  const libraries: Object[] = [loader];
  for (const xml of [false, true]) {
    const trusted = flLegacyChecksumLibrary(xml);
    const source: Record<string, Object> = { 'name': trusted['name'], 'url': trusted['url'] };
    libraries.push(source);
  }
  const client: Record<string, Object> = { 'url': 'https://example.org/client.jar', 'sha1': FL_SHA1, 'size': 120 };
  const downloads: Record<string, Object> = { 'client': client };
  const index: Record<string, Object> = { 'id': '1.7.10', 'url': 'https://example.org/index.json', 'sha1': FL_SHA1, 'size': 12 };
  const body: Record<string, Object> = { 'id': 'chosen', 'clientVersion': '1.7.10',
    'mainClass': 'net.minecraft.launchwrapper.Launch', 'libraries': libraries,
    'minecraftArguments': '--tweakClass cpw.mods.fml.common.launcher.FMLTweaker',
    'downloads': downloads, 'assetIndex': index };
  return ExportVersionResolver.resolve('chosen', [{ id: 'chosen', jsonText: JSON.stringify(body) }]);
}

/**
 * 小样本把已验 I/O 作为明确输入边界；FL_SHA1/FL_SHA256 只满足证据形状，不是假造缩减 JSON 的实测哈希。
 * 安装器 product、MC、legacy entry 与选中版本精确一致，调用方可改 evidence 来测试拒绝边界。
 */
function flLegacyChecksumEvidence(): ExportForgelikeEvidence {
  const install: Record<string, Object> = { 'path': 'net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10',
    'filePath': 'forge-1.7.10-10.13.4.1614-1.7.10-universal.jar', 'minecraft': '1.7.10' };
  const metadata: Record<string, Object> = { 'id': '1.7.10-Forge10.13.4.1614-1.7.10', 'inheritsFrom': '1.7.10',
    'libraries': [flLegacyChecksumLibrary(false), flLegacyChecksumLibrary(true)] };
  const profile: Record<string, Object> = { 'install': install, 'versionInfo': metadata };
  return { installerProfileJson: JSON.stringify(profile), installerVersionJson: JSON.stringify(metadata),
    installerSha1: FL_SHA1, profileSha256: FL_SHA256 };
}

/** 只执行纯生产计划，空 assets 对象使回归聚焦同一可信 installer 的普通库身份。 */
function flLegacyChecksumPlan(version: ExportResolvedVersion, evidence?: ExportForgelikeEvidence): ExportDependencyPlan {
  return DesktopDependencyPlanner.plan(version, flRequest().platform, '{"objects":{}}', evidence);
}

export default function forgelikeExportPlanTest(): void {
  describe('ForgelikeExportPlan', (): void => {
    it('readsNeoProductVersionFromFmlArgumentsRatherThanFmlModule', 0, (): void => {
      const version = flVersion('neoforge', true);
      expect(version.loader.kind).assertEqual('neoforge');
      expect(version.loader.version).assertEqual('26.2.0.40-beta');
      expect(ForgelikeExportPlanner.describe(version).coordinate).assertEqual('net.neoforged:neoforge:26.2.0.40-beta:installer');
      expect(version.issues.length).assertEqual(0);
    });

    it('keepsProfileAcquisitionAsPreparationInsteadOfRejectingLoaderClass', 0, (): void => {
      const plan = ForgelikeExportPlanner.plan(flVersion('forge'), flRequest().platform);
      expect(plan.profileRequired).assertTrue();
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_PROFILE_PREPARATION' && issue.severity === 'warning')).assertTrue();
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.severity === 'error')).assertFalse();
    });

    it('includesClassicSrgExtraPatchedUniversalAndForgeLanguageModules', 0, (): void => {
      const version = flVersion('forge');
      const plan = ForgelikeExportPlanner.plan(version, flRequest().platform, flEvidence(version));
      expect(plan.issues.length).assertEqual(0);
      expect(plan.dependencies.length).assertEqual(8);
      for (const role of ['MC_SRG', 'MC_EXTRA', 'PATCHED', 'UNIVERSAL']) expect(plan.dependencies.some((dependency: ExportDependency): boolean => dependency.provenance?.role === role)).assertTrue();
      expect(plan.dependencies.some((dependency: ExportDependency): boolean => dependency.path.endsWith('-slim.jar'))).assertFalse();
      const patched = plan.dependencies.find((dependency: ExportDependency): boolean => dependency.provenance?.role === 'PATCHED');
      expect(patched?.provenance?.expectedSha1).assertEqual(FL_SHA1);
    });

    it('usesOnlyPatchedClientAndUniversalForYearlyNeoPipeline', 0, (): void => {
      const version = flVersion('neoforge', true);
      const plan = ForgelikeExportPlanner.plan(version, flRequest().platform, flEvidence(version, true));
      expect(plan.issues.length).assertEqual(0);
      expect(plan.dependencies.length).assertEqual(2);
      expect(plan.dependencies.some((dependency: ExportDependency): boolean => dependency.path.indexOf('/minecraft-client-patched/') >= 0)).assertTrue();
      expect(plan.dependencies.some((dependency: ExportDependency): boolean => dependency.provenance?.role === 'MC_SRG' || dependency.provenance?.role === 'MC_EXTRA')).assertFalse();
    });

    it('requiresVerifiedRuntimeIdentityAndRebuildForMissingOfficialOutputHash', 0, (): void => {
      const version = flVersion('neoforge');
      const runtime = ForgelikeExportPlanner.plan(version, flRequest().platform, flEvidence(version));
      const client: ExportDependency = { path: 'versions/chosen/chosen.jar', url: 'https://example.org/client.jar', sha1: FL_SHA1, size: 12, kind: 'client', generated: false };
      const dependencies = runtime.dependencies.concat([client]);
      expect(ExportFilePlan.build(flRequest(), version, dependencies, []).issues.some((issue: ExportIssue): boolean => issue.code === 'GENERATED_ARTIFACT_IDENTITY')).assertTrue();
      flValidated(runtime);
      const completed = ExportFilePlan.build(flRequest(), version, dependencies, []);
      expect(completed.issues.some((issue: ExportIssue): boolean => issue.severity === 'error')).assertFalse();
      expect(completed.files.some((file: ExportPlannedFile): boolean => file.provenance?.role === 'PATCHED' && file.sha256 === FL_SHA256)).assertTrue();
      const patched = runtime.dependencies.find((dependency: ExportDependency): boolean => dependency.provenance?.role === 'PATCHED');
      if (patched !== undefined && patched.provenance !== undefined) patched.provenance.preparation = 'verified-source';
      expect(ExportFilePlan.build(flRequest(), version, dependencies, []).issues.some((issue: ExportIssue): boolean => issue.code === 'GENERATED_ARTIFACT_IDENTITY')).assertTrue();
    });

    it('bindsLegacyEmbeddedJarWithoutInventingMavenDownloadUrl', 0, (): void => {
      const coordinate = 'net.minecraftforge:forge:1.12.2-14.23.5.2864';
      const path = 'net/minecraftforge/forge/1.12.2-14.23.5.2864/forge-1.12.2-14.23.5.2864.jar';
      const metadata: Record<string, Object> = { 'id': 'legacy', 'clientVersion': '1.12.2', 'mainClass': 'net.minecraft.launchwrapper.Launch',
        'minecraftArguments': '--tweakClass net.minecraftforge.fml.common.launcher.FMLTweaker', 'libraries': [flLibrary(coordinate, path, '')] };
      const version = ExportVersionResolver.resolve('legacy', [{ id: 'legacy', jsonText: JSON.stringify(metadata) }]);
      const profile: Record<string, Object> = { 'spec': 0, 'minecraft': '1.12.2', 'path': coordinate, 'data': {} as Record<string, Object>, 'processors': [] as Object[] };
      const evidence: ExportForgelikeEvidence = { installerProfileJson: JSON.stringify(profile), installerVersionJson: JSON.stringify(metadata), installerSha1: FL_SHA1, profileSha256: FL_SHA256 };
      const plan = ForgelikeExportPlanner.plan(version, flRequest().platform, evidence);
      expect(plan.issues.length).assertEqual(0);
      expect(plan.dependencies.length).assertEqual(1);
      expect(plan.dependencies[0].url).assertEqual('');
      expect(plan.dependencies[0].provenance?.entryPath).assertEqual('maven/' + path);
      const desktop = DesktopDependencyPlanner.plan(version, flRequest().platform, '', evidence);
      expect(desktop.issues.some((issue: ExportIssue): boolean => issue.code === 'DEPENDENCY_METADATA' && issue.path === 'libraries/' + path)).assertFalse();
    });

    it('rejectsMismatchedInstallerAndMissingOrUnsafeRuntimeDeclarations', 0, (): void => {
      const version = flVersion('neoforge');
      const evidence = flEvidence(version);
      const profile = JSON.parse(evidence.installerProfileJson) as Record<string, Object>;
      profile['minecraft'] = 'wrong';
      evidence.installerProfileJson = JSON.stringify(profile);
      expect(ForgelikeExportPlanner.plan(version, flRequest().platform, evidence).issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_PROFILE_MINECRAFT')).assertTrue();
      profile['minecraft'] = version.vanillaVersion;
      const data = profile['data'] as Record<string, Object>;
      const bad: Record<string, Object> = { 'client': '[net.neoforged:../bad:1]' };
      data['PATCHED'] = bad;
      evidence.installerProfileJson = JSON.stringify(profile);
      expect(ForgelikeExportPlanner.plan(version, flRequest().platform, evidence).issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_PATCHED_METADATA')).assertTrue();
    });

    it('resolvesAdditionalModulepathLibraryOrBlocksUnknownReference', 0, (): void => {
      const version = flVersion('neoforge', true);
      const args = version.json['arguments'] as Record<string, Object>;
      args['jvm'] = ['--module-path', '${library_directory}/example/extra/1/extra-1.jar'];
      const evidence = flEvidence(version, true);
      const missing = ForgelikeExportPlanner.plan(version, flRequest().platform, evidence);
      expect(missing.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_RUNTIME_LIBRARY')).assertTrue();
      const profile = JSON.parse(evidence.installerProfileJson) as Record<string, Object>;
      (profile['libraries'] as Object[]).push(flLibrary('example:extra:1', 'example/extra/1/extra-1.jar'));
      evidence.installerProfileJson = JSON.stringify(profile);
      const complete = ForgelikeExportPlanner.plan(version, flRequest().platform, evidence);
      expect(complete.issues.length).assertEqual(0);
      expect(complete.dependencies.some((dependency: ExportDependency): boolean => dependency.path === 'libraries/example/extra/1/extra-1.jar')).assertTrue();
    });

    it('enrichesOnlySameCoordinateAndPathWithoutMutatingSourceLibrary', 0, (): void => {
      const version = flVersion('neoforge', true);
      const evidence = flEvidence(version, true);
      const official = JSON.parse(evidence.installerVersionJson) as Record<string, Object>;
      (official['libraries'] as Object[]).push(flLibrary('example:old:1', 'example/old/1/old-1.jar'));
      evidence.installerVersionJson = JSON.stringify(official);
      const original: Record<string, Object> = { 'name': 'example:old:1', 'url': 'https://legacy.example.org/' };
      (version.json['libraries'] as Object[]).push(original);
      const desktop = DesktopDependencyPlanner.plan(version, flRequest().platform, '', evidence);
      const recovered = desktop.dependencies.find((dependency: ExportDependency): boolean => dependency.path === 'libraries/example/old/1/old-1.jar');
      expect(recovered?.sha1).assertEqual(FL_SHA1);
      expect(recovered?.size).assertEqual(120);
      expect(original['downloads'] === undefined).assertTrue();
      original['name'] = 'example:old:2';
      const different = DesktopDependencyPlanner.plan(version, flRequest().platform, '', evidence);
      expect(different.dependencies.some((dependency: ExportDependency): boolean => dependency.path === 'libraries/example/old/2/old-2.jar' && dependency.sha1 === '')).assertTrue();
      expect(different.dependencies.some((dependency: ExportDependency): boolean => dependency.path === 'libraries/example/old/1/old-1.jar')).assertFalse();
    });

    it('rejectsOfficialMetadataConflictInsteadOfReplacingSelectedBytes', 0, (): void => {
      const version = flVersion('neoforge', true);
      const evidence = flEvidence(version, true);
      const official = JSON.parse(evidence.installerVersionJson) as Record<string, Object>;
      (official['libraries'] as Object[]).push(flLibrary('example:old:1', 'example/old/1/old-1.jar'));
      evidence.installerVersionJson = JSON.stringify(official);
      const changed = flLibrary('example:old:1', 'example/old/1/old-1.jar');
      const changedArtifact = (changed['downloads'] as Record<string, Object>)['artifact'] as Record<string, Object>;
      changedArtifact['sha1'] = 'cccccccccccccccccccccccccccccccccccccccc';
      (version.json['libraries'] as Object[]).push(changed);
      const desktop = DesktopDependencyPlanner.plan(version, flRequest().platform, '', evidence);
      expect(desktop.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_LIBRARY_SOURCE_CONFLICT')).assertTrue();
      expect(changedArtifact['sha1']).assertEqual('cccccccccccccccccccccccccccccccccccccccc');
    });

    it('plansRealLegacyParserAndXmlPrimaryHashesWithoutInventingSizeOrVerifiedBytes', 0, (): void => {
      const version = flLegacyChecksumVersion();
      const before = JSON.stringify(version.json);
      const plan = flLegacyChecksumPlan(version, flLegacyChecksumEvidence());
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.severity === 'error')).assertFalse();
      for (const xml of [false, true]) {
        const official = flLegacyChecksumLibrary(xml);
        const name = official['name'] as string;
        const parts = name.split(':');
        const path = 'libraries/' + parts[0].split('.').join('/') + '/' + parts[1] + '/' + parts[2] + '/' + parts[1] + '-' + parts[2] + '.jar';
        const dependency = plan.dependencies.find((item: ExportDependency): boolean => item.path === path);
        expect(dependency?.sha1).assertEqual((official['checksums'] as string[])[0]);
        expect(dependency?.size).assertEqual(0);
        expect(dependency?.url).assertEqual('https://maven.minecraftforge.net/' + path.substring('libraries/'.length));
        expect(dependency?.generated).assertFalse();
        expect(dependency?.generatedIdentity === undefined).assertTrue();
      }
      expect(JSON.stringify(version.json)).assertEqual(before);
    });

    it('doesNotTrustLegacySourceChecksumsWithoutValidatedInstallerEvidence', 0, (): void => {
      const version = flLegacyChecksumVersion();
      (version.json['libraries'] as Object[]).push(flLegacyChecksumLibrary(false));
      const plan = flLegacyChecksumPlan(version);
      const parser = plan.dependencies.find((item: ExportDependency): boolean => item.path.indexOf('scala-parser-combinators') >= 0);
      expect(parser?.sha1).assertEqual('');
    });

    it('doesNotBorrowLegacyPrimaryFromAnotherCoordinateOrArtifactPath', 0, (): void => {
      const version = flLegacyChecksumVersion();
      const libraries = version.json['libraries'] as Record<string, Object>[];
      libraries[1]['name'] = 'org.scala-lang:scala-parser-combinators_2.11:1.0.9';
      let plan = flLegacyChecksumPlan(version, flLegacyChecksumEvidence());
      let parser = plan.dependencies.find((item: ExportDependency): boolean => item.path.indexOf('scala-parser-combinators') >= 0);
      expect(parser?.sha1).assertEqual('');
      libraries[1] = flLibrary('org.scala-lang:scala-parser-combinators_2.11:1.0.1', 'example/another/1/another-1.jar');
      const artifact = (libraries[1]['downloads'] as Record<string, Object>)['artifact'] as Record<string, Object>;
      artifact['sha1'] = '';
      plan = flLegacyChecksumPlan(version, flLegacyChecksumEvidence());
      parser = plan.dependencies.find((item: ExportDependency): boolean => item.path === 'libraries/example/another/1/another-1.jar');
      expect(parser === undefined || parser.sha1.length === 0).assertTrue();
      expect(artifact['sha1']).assertEqual('');
    });

    it('rejectsLegacyPrimaryConflictWithExplicitArtifactHash', 0, (): void => {
      const version = flLegacyChecksumVersion();
      const path = 'org/scala-lang/scala-parser-combinators_2.11/1.0.1/scala-parser-combinators_2.11-1.0.1.jar';
      const original = flLibrary('org.scala-lang:scala-parser-combinators_2.11:1.0.1', path);
      (version.json['libraries'] as Object[])[1] = original;
      const before = JSON.stringify(original);
      const plan = flLegacyChecksumPlan(version, flLegacyChecksumEvidence());
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_LIBRARY_SOURCE_CONFLICT')).assertTrue();
      expect(JSON.stringify(original)).assertEqual(before);
    });

    it('rejectsWholeMalformedLegacyChecksumDeclarationRatherThanOnlyReadingFirstItem', 0, (): void => {
      const primary = (flLegacyChecksumLibrary(false)['checksums'] as string[])[0];
      const invalid: Object[] = [[], 'not-an-array', [primary, 7], [primary, 'bad'], new Array<string>(65).fill(primary)];
      for (const value of invalid) {
        const evidence = flLegacyChecksumEvidence();
        const metadata = JSON.parse(evidence.installerVersionJson) as Record<string, Object>;
        (metadata['libraries'] as Record<string, Object>[])[0]['checksums'] = value;
        evidence.installerVersionJson = JSON.stringify(metadata);
        const plan = flLegacyChecksumPlan(flLegacyChecksumVersion(), evidence);
        expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_LEGACY_CHECKSUMS')).assertTrue();
        const parser = plan.dependencies.find((item: ExportDependency): boolean => item.path.indexOf('scala-parser-combinators') >= 0);
        expect(parser?.sha1).assertEqual('');
      }
    });

    it('normalizesOnlyTrustedPrimaryAndDoesNotPretendToSupportSecondaryVariants', 0, (): void => {
      const evidence = flLegacyChecksumEvidence();
      const metadata = JSON.parse(evidence.installerVersionJson) as Record<string, Object>;
      const reference = (metadata['libraries'] as Record<string, Object>[])[0];
      const hashes = reference['checksums'] as string[];
      // 刻意交换：生产计划必须严格选择声明的 primary，不能猜哪一项更像本地实测值。
      reference['checksums'] = [hashes[1].toUpperCase(), hashes[0]];
      evidence.installerVersionJson = JSON.stringify(metadata);
      const plan = flLegacyChecksumPlan(flLegacyChecksumVersion(), evidence);
      const parser = plan.dependencies.find((item: ExportDependency): boolean => item.path.indexOf('scala-parser-combinators') >= 0);
      expect(parser?.sha1).assertEqual(hashes[1]);
      expect(parser?.sha1 === hashes[0]).assertFalse();
      expect(parser?.generatedIdentity === undefined).assertTrue();
    });

    it('keepsModernArtifactAheadOfLegacyChecksumsAndPreservesExplicitSizeConflict', 0, (): void => {
      const version = flLegacyChecksumVersion();
      const evidence = flLegacyChecksumEvidence();
      const metadata = JSON.parse(evidence.installerVersionJson) as Record<string, Object>;
      const name = 'org.scala-lang:scala-parser-combinators_2.11:1.0.1';
      const path = 'org/scala-lang/scala-parser-combinators_2.11/1.0.1/scala-parser-combinators_2.11-1.0.1.jar';
      const modern = flLibrary(name, path);
      modern['checksums'] = ['malformed-unused-legacy-value'];
      (metadata['libraries'] as Object[])[0] = modern;
      evidence.installerVersionJson = JSON.stringify(metadata);
      let plan = flLegacyChecksumPlan(version, evidence);
      const parser = plan.dependencies.find((item: ExportDependency): boolean => item.path === 'libraries/' + path);
      expect(parser?.sha1).assertEqual(FL_SHA1);
      expect(parser?.size).assertEqual(120);
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_LEGACY_CHECKSUMS')).assertFalse();
      const selected = flLibrary(name, path);
      const artifact = (selected['downloads'] as Record<string, Object>)['artifact'] as Record<string, Object>;
      artifact['size'] = 121;
      (version.json['libraries'] as Object[])[1] = selected;
      plan = flLegacyChecksumPlan(version, evidence);
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_LIBRARY_SOURCE_CONFLICT')).assertTrue();
      expect(artifact['size']).assertEqual(121);
    });

    it('doesNotGrantLegacyIdentityForMismatchedOrUnverifiedInstallerEvidence', 0, (): void => {
      for (const wrongHash of [false, true]) {
        const evidence = flLegacyChecksumEvidence();
        if (wrongHash) evidence.installerSha1 = '';
        else {
          const profile = JSON.parse(evidence.installerProfileJson) as Record<string, Object>;
          (profile['install'] as Record<string, Object>)['minecraft'] = '1.8';
          evidence.installerProfileJson = JSON.stringify(profile);
        }
        const plan = flLegacyChecksumPlan(flLegacyChecksumVersion(), evidence);
        expect(plan.issues.some((issue: ExportIssue): boolean => issue.severity === 'error')).assertTrue();
        const parser = plan.dependencies.find((item: ExportDependency): boolean => item.path.indexOf('scala-parser-combinators') >= 0);
        expect(parser?.sha1).assertEqual('');
      }
    });

    it('rejectsConflictingLegacyPrimaryAcrossSameInstallerDocuments', 0, (): void => {
      const evidence = flLegacyChecksumEvidence();
      const profile = JSON.parse(evidence.installerProfileJson) as Record<string, Object>;
      const conflicting = flLegacyChecksumLibrary(false);
      conflicting['checksums'] = [FL_SHA1];
      profile['libraries'] = [conflicting];
      evidence.installerProfileJson = JSON.stringify(profile);
      const plan = flLegacyChecksumPlan(flLegacyChecksumVersion(), evidence);
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_LIBRARY_METADATA_COLLISION')).assertTrue();
    });

    it('checksExactModulepathAfterTargetLibraryRules', 0, (): void => {
      const version = flVersion('neoforge', true);
      const path = 'example/target/1/target-1.jar';
      const library = flLibrary('example:target:1', path);
      const linux: Record<string, Object> = { 'name': 'linux' };
      const rule: Record<string, Object> = { 'action': 'allow', 'os': linux };
      library['rules'] = [rule];
      (version.json['libraries'] as Object[]).push(library);
      const args = version.json['arguments'] as Record<string, Object>;
      args['jvm'] = ['--module-path', '${library_directory}/' + path];
      const evidence = flEvidence(version, true);
      const failed = DesktopDependencyPlanner.plan(version, flRequest().platform, '', evidence);
      expect(failed.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_ARGUMENT_LIBRARY_MISSING')).assertTrue();
      const conditional: Record<string, Object> = { 'rules': [rule], 'value': ['--module-path', '${library_directory}/' + path] };
      args['jvm'] = [conditional];
      const skipped = DesktopDependencyPlanner.plan(version, flRequest().platform, '', flEvidence(version, true));
      expect(skipped.issues.some((issue: ExportIssue): boolean => issue.code === 'FORGELIKE_ARGUMENT_LIBRARY_MISSING')).assertFalse();
    });
  });
}

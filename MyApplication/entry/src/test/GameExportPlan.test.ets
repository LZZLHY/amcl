/**
 * 通用游戏包导出的纯领域回归。不调用文件、网络、账户或游戏运行；直接执行生产解析与计划。
 * 重点覆盖“表面成功但少依赖/泄漏资料/覆盖文件”的反例，平台写入由独立归档用例验证。
 */
import { describe, expect, it } from '@ohos/hypium';
import { DesktopDependencyPlanner, ExportDependency, ExportDependencyPlan, ExportFilePlan, ExportInventoryFile,
  ExportIssue, ExportPath, ExportPlannedFile, ExportRequest, ExportResolvedVersion, ExportVersionResolver, ExportVersionSource,
  ExportContentTree, ExportContentItem, ExportContentGroup, createExportContentTree, addExportContentItem, finalizeExportContentTree,
  defaultExportContentSelection, setExportContentSelection, isExportContentItemSelected, exportContentSelectionState,
  isExportContentAllSelected, validateExportSelection, exportContentSelectionIssues, reconcileExportContentSelection } from 'feature_core';

const SHA1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const SHA256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/** 固定官方形状小样本有本体、资源索引和精确库身份，名称改写不影响真实版本。 */
function fixtureVersionJson(): Record<string, Object> {
  const client: Record<string, Object> = { 'url': 'https://example.org/client.jar', 'sha1': SHA1, 'size': 12 };
  const downloads: Record<string, Object> = { 'client': client };
  const index: Record<string, Object> = { 'id': '1', 'url': 'https://example.org/index.json', 'sha1': SHA1, 'size': 12 };
  const args: Record<string, Object> = { 'game': ['--username', '${auth_player_name}'], 'jvm': [] as Object[] };
  return { 'id': '1.21.1', 'mainClass': 'net.minecraft.client.main.Main', 'downloads': downloads,
    'assetIndex': index, 'libraries': [] as Object[], 'arguments': args };
}

/** 请求使用固定源根；断言生成内容不会把这些绝对路径写到包中。 */
function fixtureRequest(): ExportRequest {
  return { mcRoot: '/private/source', versionId: '1.21.1', gameDir: '/private/source/versions/1.21.1',
    exportId: 'Copy', displayName: '测试导出', format: 'full', launcher: 'pcl',
    platform: { os: 'windows', arch: 'x64', version: '' }, includeDirectories: ['mods', 'config', 'saves', 'logs'],
    includeFiles: ['launcher_accounts.json'], selectedWorlds: ['世界'], sharedGameDir: false };
}

/** 文件库存用实际摘要形状；目录为空也可参与计划，不将来源记录当作读取结果。 */
function fixtureFile(path: string): ExportInventoryFile {
  return { path: path, size: 4, sha1: SHA1, sha256: SHA256, directory: false };
}

/** 解析器输入保留原始 JSON 文本，确保测试走实际继承和身份判断。 */
function fixtureVersion(): ExportResolvedVersion {
  const source: ExportVersionSource = { id: '1.21.1', jsonText: JSON.stringify(fixtureVersionJson()) };
  return ExportVersionResolver.resolve(source.id, [source]);
}

/** 选择fixture只描述真实来源单元；不伪造文件已读/摘要已通过，I/O由独立实盘回归负责。 */
function selectionTree(): ExportContentTree {
  const tree = createExportContentTree();
  tree.directories = ['mods', 'config', 'shaderpacks', 'saves']; tree.worlds = ['世界'];
  const entries: ExportContentItem[] = [
    { id: 'item:config', path: 'config', label: '其它配置', kind: 'directory', defaultSelected: true, available: true, reason: '' },
    { id: 'item:config/jei/world', path: 'config/jei/world', label: 'JEI个人记录', kind: 'directory', defaultSelected: false, available: true, reason: '' },
    { id: 'item:mods/a.jar', path: 'mods/a.jar', label: 'a.jar', kind: 'file', defaultSelected: true, available: true, reason: '' },
    { id: 'item:mods/b.jar.disabled', path: 'mods/b.jar.disabled', label: 'b.jar.disabled', kind: 'file', defaultSelected: false, available: true, reason: '' },
    { id: 'item:saves/世界', path: 'saves/世界', label: '世界', kind: 'world', defaultSelected: false, available: true, reason: '' },
    { id: 'item:shaderpacks/a.zip', path: 'shaderpacks/a.zip', label: 'a.zip', kind: 'file', defaultSelected: true, available: true, reason: '' },
    { id: 'item:shaderpacks/a.zip.txt', path: 'shaderpacks/a.zip.txt', label: 'a.zip.txt', kind: 'file', associatedPath: 'shaderpacks/a.zip', defaultSelected: true, available: true, reason: '' },
  ];
  for (const item of entries) addExportContentItem(tree, item);
  return finalizeExportContentTree(tree);
}

export default function gameExportPlanTest(): void {
  describe('GameExportPlan', (): void => {
    it('contentDefaultsSeparateAllFullFromConventionalStandardWithoutMutatingSource', 0, (): void => {
      const request = fixtureRequest(); const tree = selectionTree(); const before = JSON.stringify(request);
      const full = defaultExportContentSelection(request, tree);
      expect(full.selectionVersion).assertEqual(2); expect(isExportContentAllSelected(full, tree)).assertTrue();
      expect(full.selectedWorlds).assertDeepEquals(['世界']); expect(full.includeDirectories.indexOf('mods') >= 0).assertTrue();
      request.format = 'modrinth'; const standard = defaultExportContentSelection(request, tree);
      expect(standard.selectedWorlds.length).assertEqual(0); expect(standard.excludePaths?.indexOf('config/jei/world') ?? -1).assertEqual(0);
      expect(standard.includeFiles.indexOf('mods/b.jar.disabled') >= 0).assertFalse();
      request.format = 'full'; expect(JSON.stringify(request)).assertEqual(before);
    });

    it('contentChildExclusionSurvivesBroadConfigAndReachesActualFilePlan', 0, (): void => {
      const tree = selectionTree(); const request = defaultExportContentSelection(fixtureRequest(), tree);
      const selected = setExportContentSelection(request, tree, 'item:config/jei/world', false);
      const config = tree.groups.find((group: ExportContentGroup): boolean => group.id === 'group:mods');
      expect(config !== undefined).assertTrue();
      if (config !== undefined) expect(exportContentSelectionState(selected, config)).assertEqual('some');
      selected.format = 'modrinth';
      const plan = ExportFilePlan.build(selected, fixtureVersion(), [], [fixtureFile('config/general.json'), fixtureFile('config/jei/world/personal.json')]);
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath === 'overrides/config/general.json')).assertTrue();
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath.indexOf('personal.json') >= 0)).assertFalse();
      const restored = setExportContentSelection(selected, tree, 'item:config/jei/world', true);
      expect(restored.excludePaths?.length ?? -1).assertEqual(0);
    });

    it('contentUnknownAndPartialAtomicPathsDoNotBecomeLegalBecauseV2Exists', 0, (): void => {
      for (const path of ['../escape', 'config/../escape', '/absolute', 'a\\b', 'config//x', 'resourcepacks/pack/inside.txt']) {
        const request = fixtureRequest(); request.selectionVersion = 2; request.includeDirectories = []; request.includeFiles = [path];
        expect(validateExportSelection(request).some((entry: ExportIssue): boolean => entry.severity === 'error')).assertTrue();
      }
      const partial = fixtureRequest(); partial.selectionVersion = 2; partial.excludePaths = ['saves/世界/level.dat'];
      expect(validateExportSelection(partial).some((entry: ExportIssue): boolean => entry.code === 'SELECTION_EXCLUSION_PATH')).assertTrue();
    });

    it('contentErrorsRemainSelectedForFullUntilExplicitExclusionButNotUnselectedStandard', 0, (): void => {
      const tree = selectionTree();
      const error: ExportContentItem = { id: 'item:screenshots', path: 'screenshots', label: '截图', kind: 'directory',
        defaultSelected: false, available: false, reason: '权限已撤回' };
      addExportContentItem(tree, error); finalizeExportContentTree(tree);
      const request = fixtureRequest(); const full = defaultExportContentSelection(request, tree);
      expect(isExportContentItemSelected(full, error)).assertTrue();
      expect(exportContentSelectionIssues(full, tree).some((entry: ExportIssue): boolean => entry.code === 'CONTENT_SELECTION_UNREADABLE')).assertTrue();
      const excluded = setExportContentSelection(full, tree, error.id, false);
      expect(exportContentSelectionIssues(excluded, tree).some((entry: ExportIssue): boolean => entry.code === 'CONTENT_SELECTION_UNREADABLE')).assertFalse();
      expect(isExportContentAllSelected(excluded, tree)).assertFalse();
      request.format = 'curseforge'; const standard = defaultExportContentSelection(request, tree);
      expect(isExportContentItemSelected(standard, error)).assertFalse();
    });

    it('contentShaderSidecarsFollowTheirRealPackageAndNeverReturnViaOtherFiles', 0, (): void => {
      const tree = selectionTree(); const request = defaultExportContentSelection(fixtureRequest(), tree);
      const off = setExportContentSelection(request, tree, 'item:shaderpacks/a.zip', false);
      expect(off.includeFiles.indexOf('shaderpacks/a.zip.txt') >= 0).assertFalse();
      const on = setExportContentSelection(off, tree, 'item:shaderpacks/a.zip.txt', true);
      const sidecar = tree.groups.find((group: ExportContentGroup): boolean => group.id === 'group:shaders');
      expect(sidecar !== undefined).assertTrue();
      if (sidecar !== undefined) expect(exportContentSelectionState(on, sidecar)).assertEqual('all');
    });

    it('contentLegacyDraftsKeepTheirExactOldScopeIncludingDisabledFiles', 0, (): void => {
      const tree = selectionTree(); const old = fixtureRequest(); old.includeDirectories = ['mods']; old.includeFiles = []; old.selectedWorlds = [];
      const before = JSON.stringify(old); const restored = reconcileExportContentSelection(old, tree);
      expect(JSON.stringify(old)).assertEqual(before); expect(JSON.stringify(restored.request)).assertEqual(before);
      const disabled: ExportContentItem = { id: 'item:mods/b.jar.disabled', path: 'mods/b.jar.disabled', label: 'disabled',
        kind: 'file', defaultSelected: false, available: true, reason: '' };
      expect(isExportContentItemSelected(restored.request, disabled)).assertTrue();
      expect(restored.request.selectedWorlds.length).assertEqual(0);
    });

    it('contentParentIntentStillSeesNewFilesWhileExplicitLeafSubsetDoesNotBroaden', 0, (): void => {
      const tree = selectionTree(); const full = defaultExportContentSelection(fixtureRequest(), tree);
      const withoutDisabled = setExportContentSelection(full, tree, 'item:mods/b.jar.disabled', false);
      expect(withoutDisabled.includeDirectories.indexOf('mods') >= 0).assertTrue();
      const newFile: ExportContentItem = { id: 'item:mods/new.jar', path: 'mods/new.jar', label: 'new', kind: 'file',
        defaultSelected: true, available: true, reason: '' };
      expect(isExportContentItemSelected(withoutDisabled, newFile)).assertTrue();
      const empty = fixtureRequest(); empty.includeDirectories = []; empty.includeFiles = []; empty.selectedWorlds = [];
      const leaf = setExportContentSelection(empty, tree, 'item:mods/a.jar', true);
      expect(isExportContentItemSelected(leaf, newFile)).assertFalse();
      expect(leaf.includeDirectories.indexOf('mods') >= 0).assertFalse();
    });

    it('contentLegacyResourceAliasDeduplicatesOnlyAnExactlyVerifiedRequiredTarget', 0, (): void => {
      const request = fixtureRequest(); request.includeDirectories = ['resources']; request.includeFiles = []; request.selectedWorlds = [];
      const client: ExportDependency = { path: 'versions/1.21.1/1.21.1.jar', url: 'https://example.org/client.jar',
        sha1: SHA1, size: 12, kind: 'client', generated: false };
      const asset: ExportDependency = { path: 'resources/a', url: 'https://example.org/a', sha1: SHA1, size: 4, kind: 'asset', generated: false };
      const plan = ExportFilePlan.build(request, fixtureVersion(), [client, asset], [fixtureFile('resources/a')]);
      expect(plan.files.filter((file: ExportPlannedFile): boolean => file.archivePath.endsWith('/resources/a')).length).assertEqual(1);
      const bad = fixtureFile('resources/a'); bad.sha1 = 'cccccccccccccccccccccccccccccccccccccccc';
      expect(ExportFilePlan.build(request, fixtureVersion(), [client, asset], [bad]).issues.some((entry: ExportIssue): boolean => entry.code === 'ARCHIVE_COLLISION')).assertTrue();
      expect(ExportFilePlan.build(request, fixtureVersion(), [client, asset], [fixtureFile('resources/A')]).issues.some((entry: ExportIssue): boolean => entry.code === 'ARCHIVE_COLLISION')).assertTrue();
    });

    it('resolvesInheritedJarAndRejectsMissingOrCyclicParents', 0, (): void => {
      const child: ExportVersionSource = { id: 'child', jsonText: '{"id":"child","inheritsFrom":"1.21.1","libraries":[]}' };
      const parent: ExportVersionSource = { id: '1.21.1', jsonText: JSON.stringify(fixtureVersionJson()) };
      const resolved = ExportVersionResolver.resolve('child', [child, parent]);
      expect(resolved.jarVersionId).assertEqual('1.21.1');
      expect(resolved.vanillaVersion).assertEqual('1.21.1');
      expect(ExportVersionResolver.resolve('child', [child]).issues.some((issue: ExportIssue): boolean => issue.code === 'PARENT_MISSING')).assertTrue();
      const a: ExportVersionSource = { id: 'a', jsonText: '{"id":"a","inheritsFrom":"b"}' };
      const b: ExportVersionSource = { id: 'b', jsonText: '{"id":"b","inheritsFrom":"a"}' };
      expect(ExportVersionResolver.resolve('a', [a, b]).issues.some((issue: ExportIssue): boolean => issue.code === 'INHERITANCE_CYCLE')).assertTrue();
      const childOwn = fixtureVersionJson();
      childOwn['id'] = 'own';
      childOwn['inheritsFrom'] = 'child';
      const own: ExportVersionSource = { id: 'own', jsonText: JSON.stringify(childOwn) };
      expect(ExportVersionResolver.resolve('own', [own, child, parent]).jarVersionId).assertEqual('own');
    });

    it('usesTargetOsAndLastMatchingRule', 0, (): void => {
      const out: ExportDependencyPlan = { dependencies: [], issues: [] };
      const windows: Record<string, Object> = { 'name': 'windows', 'arch': 'x86_64' };
      const linux: Record<string, Object> = { 'name': 'linux' };
      const allow: Record<string, Object> = { 'action': 'allow' };
      const deny: Record<string, Object> = { 'action': 'disallow', 'os': windows };
      const restore: Record<string, Object> = { 'action': 'allow', 'os': windows };
      const other: Record<string, Object> = { 'action': 'allow', 'os': linux };
      expect(DesktopDependencyPlanner.allowed([allow, deny, restore], fixtureRequest().platform, out)).assertTrue();
      expect(DesktopDependencyPlanner.allowed([other], fixtureRequest().platform, out)).assertFalse();
    });

    it('blocksAmbiguousLegacyInheritanceWithoutGuessingArguments', 0, (): void => {
      const parentJson = fixtureVersionJson();
      parentJson['minecraftArguments'] = '--username ${auth_player_name} --version ${version_name}';
      const parent: ExportVersionSource = { id: '1.21.1', jsonText: JSON.stringify(parentJson) };
      const child: ExportVersionSource = { id: 'child',
        jsonText: '{"id":"child","inheritsFrom":"1.21.1","minecraftArguments":"--tweakClass example.Tweaker"}' };
      const resolved = ExportVersionResolver.resolve('child', [child, parent]);
      expect(resolved.issues.some((issue: ExportIssue): boolean => issue.code === 'LEGACY_INHERITANCE_ARGUMENTS')).assertTrue();
      const same: ExportVersionSource = { id: 'same', jsonText: JSON.stringify({
        'id': 'same', 'inheritsFrom': '1.21.1', 'minecraftArguments': parentJson['minecraftArguments'] } as Record<string, Object>) };
      expect(ExportVersionResolver.resolve('same', [same, parent]).issues.some((issue: ExportIssue): boolean => issue.code === 'LEGACY_INHERITANCE_ARGUMENTS')).assertFalse();
      const inherited: ExportVersionSource = { id: 'inherited', jsonText: '{"id":"inherited","inheritsFrom":"1.21.1"}' };
      const unchanged = ExportVersionResolver.resolve('inherited', [inherited, parent]);
      expect(unchanged.issues.some((issue: ExportIssue): boolean => issue.code === 'LEGACY_INHERITANCE_ARGUMENTS')).assertFalse();
      expect(unchanged.json['minecraftArguments']).assertEqual(parentJson['minecraftArguments']);
    });

    it('keepsMissingLibraryIdentityInPreparationPlan', 0, (): void => {
      const dep: ExportDependency = { path: 'libraries/org/example/a/1/a-1.jar', url: 'https://example.org/a.jar',
        sha1: '', size: 0, kind: 'library', generated: false };
      const client: ExportDependency = { path: 'versions/1.21.1/1.21.1.jar', url: 'https://example.org/client.jar',
        sha1: SHA1, size: 12, kind: 'client', generated: false };
      const plan = ExportFilePlan.build(fixtureRequest(), fixtureVersion(), [client, dep], []);
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.sourcePath === dep.path)).assertTrue();
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'DEPENDENCY_PREPARATION')).assertTrue();
    });

    it('selectsCompleteWorldAndExcludesPrivateData', 0, (): void => {
      const req = fixtureRequest();
      req.format = 'modrinth';
      const plan = ExportFilePlan.build(req, fixtureVersion(), [], [fixtureFile('mods/a.jar'), fixtureFile('saves/世界/level.dat'),
        fixtureFile('saves/世界/region/r.0.0.mca'), fixtureFile('saves/other/level.dat'), fixtureFile('logs/latest.log'),
        fixtureFile('launcher_accounts.json'), fixtureFile('logs/amcl-launch.log')]);
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath === 'overrides/saves/世界/region/r.0.0.mca')).assertTrue();
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath.indexOf('other') >= 0 || file.archivePath.indexOf('amcl-launch.log') >= 0 || file.archivePath.indexOf('accounts') >= 0)).assertFalse();
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath === 'overrides/logs/latest.log')).assertTrue();
    });

    it('writesExactlyOneStandardManifestAndLocalOverrides', 0, (): void => {
      for (const format of ['modrinth', 'curseforge']) {
        const req = fixtureRequest();
        req.format = format === 'modrinth' ? 'modrinth' : 'curseforge';
        const plan = ExportFilePlan.build(req, fixtureVersion(), [], [fixtureFile('mods/local.jar')]);
        expect(plan.files.filter((file: ExportPlannedFile): boolean => file.archivePath === 'manifest.json' || file.archivePath === 'modrinth.index.json').length).assertEqual(1);
        expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath === 'overrides/mods/local.jar')).assertTrue();
        expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath.startsWith('.minecraft/'))).assertFalse();
        const manifest = plan.files.find((file: ExportPlannedFile): boolean => file.archivePath === (format === 'modrinth' ? 'modrinth.index.json' : 'manifest.json'));
        expect(manifest !== undefined).assertTrue();
        if (manifest !== undefined) expect((JSON.parse(manifest.content) as Record<string, Object>)['files'] as Object[]).assertDeepEquals([] as Object[]);
      }
    });

    it('rejectsCaseCollisionAndUnsafePcPaths', 0, (): void => {
      const req = fixtureRequest();
      req.format = 'modrinth';
      const plan = ExportFilePlan.build(req, fixtureVersion(), [], [fixtureFile('mods/a.jar'), fixtureFile('mods/A.jar')]);
      expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'ARCHIVE_COLLISION')).assertTrue();
      for (const path of ['../a', 'a/../b', 'C:/a', 'a\\b', 'CON.txt', 'a.', 'a//b']) expect(ExportPath.relative(path)).assertFalse();
      expect(ExportPath.relative('saves/中文/level.dat')).assertTrue();
      expect(ExportPath.https('https://user:pass@example.org/x')).assertFalse();
    });

    it('keepsVanillaIdentityAndRewritesOnlyDiskId', 0, (): void => {
      const dep: ExportDependency = { path: 'versions/1.21.1/1.21.1.jar', url: 'https://example.org/client.jar',
        sha1: SHA1, size: 12, kind: 'client', generated: false };
      const plan = ExportFilePlan.build(fixtureRequest(), fixtureVersion(), [dep], []);
      const file = plan.files.find((item: ExportPlannedFile): boolean => item.archivePath === '.minecraft/versions/Copy/Copy.json');
      expect(file !== undefined).assertTrue();
      if (file !== undefined) {
        const json = JSON.parse(file.content) as Record<string, Object>;
        expect(json['id']).assertEqual('Copy');
        expect(json['clientVersion']).assertEqual('1.21.1');
        expect(file.content.indexOf('/private/source')).assertEqual(-1);
        expect(json['inheritsFrom'] === undefined).assertTrue();
      }
    });

    it('rejectsCorruptOrMissingAssetIndexBeforeFullExport', 0, (): void => {
      const version = fixtureVersion();
      const platform = fixtureRequest().platform;
      expect(DesktopDependencyPlanner.plan(version, platform).issues.some((issue: ExportIssue): boolean => issue.code === 'ASSET_INDEX_REQUIRED')).assertTrue();
      expect(DesktopDependencyPlanner.plan(version, platform, 'not-json').issues.some((issue: ExportIssue): boolean => issue.code === 'ASSET_INDEX_JSON')).assertTrue();
      expect(DesktopDependencyPlanner.plan(version, platform, '{"objects":42}').issues.some((issue: ExportIssue): boolean => issue.code === 'ASSET_OBJECTS')).assertTrue();
      expect(DesktopDependencyPlanner.plan(version, platform, '{"objects":{"x":{"hash":"bad","size":1}}}').issues.some((issue: ExportIssue): boolean => issue.code === 'ASSET_OBJECT_METADATA')).assertTrue();
    });

    it('mapsLegacyResourcesToIsolatedRunDirectory', 0, (): void => {
      const object: Record<string, Object> = { 'hash': SHA1, 'size': 4 };
      const objects: Record<string, Object> = { 'sound/x.ogg': object };
      const index: Record<string, Object> = { 'objects': objects, 'virtual': true, 'map_to_resources': true };
      const version = fixtureVersion();
      const dependencies = DesktopDependencyPlanner.plan(version, fixtureRequest().platform, JSON.stringify(index));
      const plan = ExportFilePlan.build(fixtureRequest(), version, dependencies.dependencies, []);
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath === '.minecraft/assets/virtual/1/sound/x.ogg')).assertTrue();
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath === '.minecraft/versions/Copy/resources/sound/x.ogg')).assertTrue();
      expect(plan.files.some((file: ExportPlannedFile): boolean => file.archivePath === '.minecraft/resources/sound/x.ogg')).assertFalse();
    });

    it('keepsLegacyAssetSourcesSeparateFromPcTargets', 0, (): void => {
      // AMCL 旧安装只有命名资源，电脑包仍需 objects；候选必须贯穿每个目标项而非只给 virtual 映射补路径。
      const objects: Record<string, Object> = { 'sound/x.ogg': { 'hash': SHA1, 'size': 4 } as Record<string, Object> };
      for (const layout of ['virtual', 'map_to_resources']) {
        const index: Record<string, Object> = { 'objects': objects };
        index[layout] = true;
        const dependencies = DesktopDependencyPlanner.plan(fixtureVersion(), fixtureRequest().platform, JSON.stringify(index));
        const assets = dependencies.dependencies.filter((file: ExportDependency): boolean => file.kind === 'asset');
        const objectPath = 'assets/objects/aa/' + SHA1;
        expect(assets.length).assertEqual(2);
        for (const asset of assets) {
          expect(asset.sourcePath).assertEqual('assets/virtual/legacy/sound/x.ogg');
          expect(asset.sourceCandidates !== undefined).assertTrue();
          if (asset.sourceCandidates !== undefined) {
            expect(asset.sourceCandidates[0]).assertEqual('assets/virtual/legacy/sound/x.ogg');
            expect(asset.sourceCandidates.indexOf(objectPath) >= 0).assertTrue();
          }
        }
        const plan = ExportFilePlan.build(fixtureRequest(), fixtureVersion(), dependencies.dependencies, []);
        const object = plan.files.find((file: ExportPlannedFile): boolean => file.archivePath === '.minecraft/' + objectPath);
        expect(object !== undefined).assertTrue();
        if (object !== undefined) expect(object.sourcePath).assertEqual('assets/virtual/legacy/sound/x.ogg');
      }
      // 现代资源继续直接使用 objects，不为所有版本引入旧布局候选或更改归档目标。
      const modern = DesktopDependencyPlanner.plan(fixtureVersion(), fixtureRequest().platform, JSON.stringify({ 'objects': objects } as Record<string, Object>));
      const asset = modern.dependencies.find((file: ExportDependency): boolean => file.kind === 'asset');
      expect(asset !== undefined).assertTrue();
      if (asset !== undefined) { expect(asset.sourcePath === undefined).assertTrue(); expect(asset.sourceCandidates === undefined).assertTrue(); }
    });

    it('preservesNamedCandidatesWhenLegacyObjectsShareAHash', 0, (): void => {
      // 相同对象可以有不同资源名：objects 目标去重后仍保留两个命名源，供 I/O 按摘要选可用候选。
      const objects: Record<string, Object> = {
        'sound/a.ogg': { 'hash': SHA1, 'size': 4 } as Record<string, Object>,
        'sound/b.ogg': { 'hash': SHA1, 'size': 4 } as Record<string, Object>,
      };
      const index: Record<string, Object> = { 'objects': objects, 'virtual': true };
      const dependencies = DesktopDependencyPlanner.plan(fixtureVersion(), fixtureRequest().platform, JSON.stringify(index));
      const targets = dependencies.dependencies.filter((file: ExportDependency): boolean => file.path.startsWith('assets/objects/'));
      expect(targets.length).assertEqual(1);
      if (targets.length === 1 && targets[0].sourceCandidates !== undefined) {
        expect(targets[0].sourceCandidates.indexOf('assets/virtual/legacy/sound/a.ogg') >= 0).assertTrue();
        expect(targets[0].sourceCandidates.indexOf('assets/virtual/legacy/sound/b.ogg') >= 0).assertTrue();
        expect(targets[0].sourceCandidates.indexOf('assets/virtual/1/sound/a.ogg') >= 0).assertTrue();
      } else expect(false).assertTrue();
    });

    it('blocksLiteralCredentialsAndNestedPrivateMetadata', 0, (): void => {
      const version = fixtureVersion();
      const args: Record<string, Object> = { 'game': ['--accessToken', 'literal-secret'] };
      version.json['arguments'] = args;
      const client: ExportDependency = { path: 'versions/1.21.1/1.21.1.jar', url: 'https://example.org/client.jar', sha1: SHA1, size: 12, kind: 'client', generated: false };
      expect(ExportFilePlan.build(fixtureRequest(), version, [client], []).issues.some((issue: ExportIssue): boolean => issue.code === 'LITERAL_AUTH_ARGUMENT')).assertTrue();
      const other = fixtureVersion();
      const java: Record<string, Object> = { 'majorVersion': 21, 'accessToken': 'secret' };
      other.json['javaVersion'] = java;
      expect(ExportFilePlan.build(fixtureRequest(), other, [client], []).issues.some((issue: ExportIssue): boolean => issue.code === 'PRIVATE_VERSION_METADATA')).assertTrue();
    });

    it('blocksEqualsAndLegacyAuthenticationValuesWithoutWritingThem', 0, (): void => {
      // 等号参数也是有效的命令行形式；每个认证字段都必须经同一检查，不能只封 accessToken 的分隔写法。
      const client: ExportDependency = { path: 'versions/1.21.1/1.21.1.jar', url: 'https://example.org/client.jar',
        sha1: SHA1, size: 12, kind: 'client', generated: false };
      for (const option of ['--accessToken', '--clientId', '--xuid', '--username', '--uuid', '--userProperties', '--session']) {
        for (const legacy of [false, true]) {
          const version = fixtureVersion();
          const literal = option + '=FAKE_PRIVATE_REVIEW_VALUE';
          if (legacy) version.json['minecraftArguments'] = literal;
          else version.json['arguments'] = { 'game': [literal] } as Record<string, Object>;
          const plan = ExportFilePlan.build(fixtureRequest(), version, [client], []);
          expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'LITERAL_AUTH_ARGUMENT')).assertTrue();
          const json = plan.files.find((file: ExportPlannedFile): boolean => file.archivePath.endsWith('/Copy.json'));
          expect(json !== undefined).assertTrue();
          if (json !== undefined) expect(json.content.indexOf('FAKE_PRIVATE_REVIEW_VALUE')).assertEqual(-1);
        }
      }
    });

    it('blocksMissingSplitAndRuleAuthenticationValues', 0, (): void => {
      // 缺值、下一项其实是选项、未知模板以及 rules.value 的分隔/等号形式，都不能作为安全正文导出。
      const client: ExportDependency = { path: 'versions/1.21.1/1.21.1.jar', url: 'https://example.org/client.jar',
        sha1: SHA1, size: 12, kind: 'client', generated: false };
      const invalid: Object[][] = [
        ['--accessToken'], ['--uuid', '--width', '800'], ['--username', ''],
        ['--accessToken', '${not_an_authentication_placeholder}'], ['--session', 'FAKE_PRIVATE_REVIEW_VALUE'],
        ['--accessToken', { 'value': 'FAKE_PRIVATE_REVIEW_VALUE' } as Record<string, Object>],
        [{ 'value': ['--accessToken', 'FAKE_PRIVATE_REVIEW_VALUE'] } as Record<string, Object>],
        [{ 'value': '--accessToken=FAKE_PRIVATE_REVIEW_VALUE' } as Record<string, Object>],
      ];
      for (const args of invalid) {
        const version = fixtureVersion();
        version.json['arguments'] = { 'game': args } as Record<string, Object>;
        const plan = ExportFilePlan.build(fixtureRequest(), version, [client], []);
        expect(plan.issues.some((issue: ExportIssue): boolean => issue.code === 'LITERAL_AUTH_ARGUMENT')).assertTrue();
        const json = plan.files.find((file: ExportPlannedFile): boolean => file.archivePath.endsWith('/Copy.json'));
        if (json !== undefined) expect(json.content.indexOf('FAKE_PRIVATE_REVIEW_VALUE')).assertEqual(-1);
      }
    });

    it('preservesExactAuthenticationPlaceholdersInBothArgumentForms', 0, (): void => {
      // 各字段对应上游真实占位符；合法分隔参数和等号参数保持原写法，让电脑启动器注入自己的账户。
      const client: ExportDependency = { path: 'versions/1.21.1/1.21.1.jar', url: 'https://example.org/client.jar',
        sha1: SHA1, size: 12, kind: 'client', generated: false };
      const options = ['--accessToken', '--clientId', '--xuid', '--username', '--uuid', '--userProperties', '--session'];
      const placeholders = ['${auth_access_token}', '${clientid}', '${auth_xuid}', '${auth_player_name}',
        '${auth_uuid}', '${user_properties}', '${auth_session}'];
      for (const equals of [false, true]) {
        const args: string[] = [];
        for (let index = 0; index < options.length; index++) {
          if (equals) args.push(options[index] + '=' + placeholders[index]);
          else { args.push(options[index]); args.push(placeholders[index]); }
        }
        const version = fixtureVersion();
        version.json['arguments'] = { 'game': args } as Record<string, Object>;
        const plan = ExportFilePlan.build(fixtureRequest(), version, [client], []);
        expect(plan.issues.some((issue: ExportIssue): boolean => issue.severity === 'error')).assertFalse();
        const json = plan.files.find((file: ExportPlannedFile): boolean => file.archivePath.endsWith('/Copy.json'));
        expect(json !== undefined).assertTrue();
        if (json !== undefined) {
          const output = JSON.parse(json.content) as Record<string, Object>;
          const argumentsObject = output['arguments'] as Record<string, Object>;
          expect(argumentsObject['game'] as string[]).assertDeepEquals(args);
        }
      }
    });
  });
}

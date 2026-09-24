/*
 * ModTypes.test.ets — 模组下载子系统纯函数单元测试（P1-MODS Phase 1.1）
 *
 * 覆盖范围：
 *   - ResourceKind ↔ Modrinth project_type / CurseForge classId 双向映射
 *   - parseVersionChannel / parseDependencyType 字符串映射
 *   - resourceKindToInstallDir 在版本隔离 on/off 两种情况下的路径
 *   - normalizeSlug 跨源去重归一化
 *   - pickPrimaryFile 主文件选择规则
 *   - mergeProjects 跨源合并去重
 *   - versionChannelRank 排序键
 *   - ModRepoError.fromUnknown 错误分类启发
 *
 * 全部为纯函数测试，可在 hvigor test（Node v8 + hypium）下直接跑。
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ResourceKind,
  ModSource,
  DependencyType,
  VersionChannel,
  RemoteFile,
  RemoteProject,
  fromModrinthType,
  toModrinthType,
  fromCurseForgeClassId,
  toCurseForgeClassId,
  parseVersionChannel,
  parseDependencyType,
  resourceKindToInstallDir,
  normalizeSlug,
  pickPrimaryFile,
  mergeProjects,
  versionChannelRank,
} from 'mods';
import {
  ModRepoError,
  ModRepoErrorKind,
} from 'mods';

// ------------------------------------------------------------
//  小工具：构造 RemoteProject / RemoteFile（避免每条测试重复字段）
// ------------------------------------------------------------

function makeProject(source: ModSource, slug: string, id: string,
                     title: string = ''): RemoteProject {
  return {
    source,
    id,
    slug,
    kind: ResourceKind.MOD,
    title: title.length > 0 ? title : slug,
    summary: '',
    author: '',
    iconUrl: '',
    downloads: 0,
    follows: 0,
    categories: [],
    loaders: [],
    gameVersions: [],
    websiteUrl: '',
    dateModified: '',
  };
}

function makeFile(filename: string, size: number, isPrimary: boolean,
                  sha1: string = ''): RemoteFile {
  let f: RemoteFile = {
    url: 'https://example.com/' + filename,
    mirrors: [],
    filename,
    size,
    isPrimary,
  };
  if (sha1.length > 0) f.sha1 = sha1;
  return f;
}

export default function modTypesTest() {

  // ==========================================================
  //  ResourceKind ↔ Modrinth
  // ==========================================================
  describe('ModTypes.fromModrinthType', () => {
    it('已知字符串映射到对应 ResourceKind', 0, () => {
      expect(fromModrinthType('mod')).assertEqual(ResourceKind.MOD);
      expect(fromModrinthType('resourcepack')).assertEqual(ResourceKind.RESOURCE_PACK);
      expect(fromModrinthType('shader')).assertEqual(ResourceKind.SHADER);
      expect(fromModrinthType('datapack')).assertEqual(ResourceKind.DATAPACK);
      expect(fromModrinthType('modpack')).assertEqual(ResourceKind.MODPACK);
    });

    it('未知字符串返回 null', 0, () => {
      expect(fromModrinthType('plugin')).assertNull();
      expect(fromModrinthType('')).assertNull();
      expect(fromModrinthType('Mod')).assertNull(); // 大小写敏感
    });

    it('与 toModrinthType 往返一致', 0, () => {
      let kinds: ResourceKind[] = [
        ResourceKind.MOD, ResourceKind.RESOURCE_PACK, ResourceKind.SHADER,
        ResourceKind.DATAPACK, ResourceKind.MODPACK,
      ];
      for (let k of kinds) {
        expect(fromModrinthType(toModrinthType(k))).assertEqual(k);
      }
    });
  });

  // ==========================================================
  //  ResourceKind ↔ CurseForge classId
  // ==========================================================
  describe('ModTypes.fromCurseForgeClassId', () => {
    it('已知 classId 映射正确', 0, () => {
      expect(fromCurseForgeClassId(6)).assertEqual(ResourceKind.MOD);
      expect(fromCurseForgeClassId(12)).assertEqual(ResourceKind.RESOURCE_PACK);
      expect(fromCurseForgeClassId(6552)).assertEqual(ResourceKind.SHADER);
      expect(fromCurseForgeClassId(6945)).assertEqual(ResourceKind.DATAPACK);
      expect(fromCurseForgeClassId(4471)).assertEqual(ResourceKind.MODPACK);
    });

    it('未知 classId 返回 null', 0, () => {
      expect(fromCurseForgeClassId(0)).assertNull();
      expect(fromCurseForgeClassId(17)).assertNull(); // 17 = Worlds，V1 不支持
      expect(fromCurseForgeClassId(99999)).assertNull();
    });

    it('与 toCurseForgeClassId 往返一致', 0, () => {
      let kinds: ResourceKind[] = [
        ResourceKind.MOD, ResourceKind.RESOURCE_PACK, ResourceKind.SHADER,
        ResourceKind.DATAPACK, ResourceKind.MODPACK,
      ];
      for (let k of kinds) {
        expect(fromCurseForgeClassId(toCurseForgeClassId(k))).assertEqual(k);
      }
    });
  });

  // ==========================================================
  //  parseVersionChannel / parseDependencyType
  // ==========================================================
  describe('ModTypes.parseVersionChannel', () => {
    it('已知字符串映射正确', 0, () => {
      expect(parseVersionChannel('release')).assertEqual(VersionChannel.RELEASE);
      expect(parseVersionChannel('beta')).assertEqual(VersionChannel.BETA);
      expect(parseVersionChannel('alpha')).assertEqual(VersionChannel.ALPHA);
    });

    it('未知字符串保守回退到 release', 0, () => {
      expect(parseVersionChannel('')).assertEqual(VersionChannel.RELEASE);
      expect(parseVersionChannel('snapshot')).assertEqual(VersionChannel.RELEASE);
    });
  });

  describe('ModTypes.parseDependencyType', () => {
    it('已知字符串映射正确', 0, () => {
      expect(parseDependencyType('required')).assertEqual(DependencyType.REQUIRED);
      expect(parseDependencyType('optional')).assertEqual(DependencyType.OPTIONAL);
      expect(parseDependencyType('incompatible')).assertEqual(DependencyType.INCOMPATIBLE);
      expect(parseDependencyType('embedded')).assertEqual(DependencyType.EMBEDDED);
    });

    it('未知字符串保守回退到 optional', 0, () => {
      expect(parseDependencyType('')).assertEqual(DependencyType.OPTIONAL);
      expect(parseDependencyType('soft')).assertEqual(DependencyType.OPTIONAL);
    });
  });

  // ==========================================================
  //  resourceKindToInstallDir
  // ==========================================================
  describe('ModTypes.resourceKindToInstallDir', () => {
    const MC_DIR = '/data/storage/el2/base/files/.minecraft';
    const VID = '1.20.4-fabric-0.16.10';

    it('版本隔离启用：mod → versions/<id>/mods', 0, () => {
      expect(resourceKindToInstallDir(ResourceKind.MOD, MC_DIR, VID, true))
        .assertEqual(MC_DIR + '/versions/' + VID + '/mods');
    });

    it('版本隔离启用：resourcepack → versions/<id>/resourcepacks', 0, () => {
      expect(resourceKindToInstallDir(ResourceKind.RESOURCE_PACK, MC_DIR, VID, true))
        .assertEqual(MC_DIR + '/versions/' + VID + '/resourcepacks');
    });

    it('版本隔离启用：shader → versions/<id>/shaderpacks', 0, () => {
      expect(resourceKindToInstallDir(ResourceKind.SHADER, MC_DIR, VID, true))
        .assertEqual(MC_DIR + '/versions/' + VID + '/shaderpacks');
    });

    it('版本隔离关闭：mod → mcDir/mods', 0, () => {
      expect(resourceKindToInstallDir(ResourceKind.MOD, MC_DIR, VID, false))
        .assertEqual(MC_DIR + '/mods');
    });

    it('版本隔离关闭：resourcepack → mcDir/resourcepacks', 0, () => {
      expect(resourceKindToInstallDir(ResourceKind.RESOURCE_PACK, MC_DIR, '', false))
        .assertEqual(MC_DIR + '/resourcepacks');
    });

    it('版本隔离启用但 versionId 为空 → 抛错', 0, () => {
      let threw = false;
      try {
        resourceKindToInstallDir(ResourceKind.MOD, MC_DIR, '', true);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('DATAPACK 抛错（V2 实现）', 0, () => {
      let threw = false;
      try {
        resourceKindToInstallDir(ResourceKind.DATAPACK, MC_DIR, VID, true);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('MODPACK 抛错（走 ModpackInstaller）', 0, () => {
      let threw = false;
      try {
        resourceKindToInstallDir(ResourceKind.MODPACK, MC_DIR, VID, true);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('返回路径不带尾部斜杠', 0, () => {
      let p = resourceKindToInstallDir(ResourceKind.MOD, MC_DIR, VID, true);
      expect(p.endsWith('/')).assertFalse();
    });
  });

  // ==========================================================
  //  normalizeSlug
  // ==========================================================
  describe('ModTypes.normalizeSlug', () => {
    it('全小写化', 0, () => {
      expect(normalizeSlug('Sodium')).assertEqual('sodium');
      expect(normalizeSlug('JEI')).assertEqual('jei');
    });

    it('去 mc- 前缀', 0, () => {
      expect(normalizeSlug('mc-just-enough-items')).assertEqual('just-enough-items');
    });

    it('去 minecraft- 前缀', 0, () => {
      expect(normalizeSlug('minecraft-comes-alive')).assertEqual('comes-alive');
    });

    it('去 -fabric / -forge / -neoforge / -quilt 后缀', 0, () => {
      expect(normalizeSlug('sodium-fabric')).assertEqual('sodium');
      expect(normalizeSlug('jei-forge')).assertEqual('jei');
      expect(normalizeSlug('jei-neoforge')).assertEqual('jei');
      expect(normalizeSlug('iris-quilt')).assertEqual('iris');
    });

    it('-mod 后缀也剥', 0, () => {
      expect(normalizeSlug('JEI-Mod')).assertEqual('jei');
      expect(normalizeSlug('cool-mod')).assertEqual('cool');
    });

    it('空字符串安全', 0, () => {
      expect(normalizeSlug('')).assertEqual('');
    });

    it('前后缀同时存在：仅各剥一层（不递归）', 0, () => {
      // 'mc-foo-fabric' → 去 'mc-' 得 'foo-fabric' → 去 '-fabric' 得 'foo'
      expect(normalizeSlug('mc-foo-fabric')).assertEqual('foo');
    });

    it('长后缀优先：-neoforge 不被 -forge 误剥', 0, () => {
      // 'iris-neoforge' 必须只剥 -neoforge（变 'iris'），不能剥成 'iris-neo'
      expect(normalizeSlug('iris-neoforge')).assertEqual('iris');
    });

    it('不剥到只剩前缀本身（防止 `-mod` 把 `mod` 剥成空）', 0, () => {
      // 'mod' 只有 3 字符，剥后会变空 — 实现里要求 s.length > suf.length
      expect(normalizeSlug('mod')).assertEqual('mod');
      expect(normalizeSlug('-mod')).assertEqual('-mod'); // 实际不会出现，但安全兜底
    });

    it('多个候选后缀只匹配第一个', 0, () => {
      // 自身 slug 含 -fabric 又含 -mod 的极端情况：只剥最先匹配到的（neoforge>fabric>forge>quilt>mod）
      expect(normalizeSlug('xxx-fabric')).assertEqual('xxx');
      expect(normalizeSlug('xxx-mod')).assertEqual('xxx');
    });
  });

  // ==========================================================
  //  pickPrimaryFile
  // ==========================================================
  describe('ModTypes.pickPrimaryFile', () => {
    it('空数组返回 null', 0, () => {
      expect(pickPrimaryFile([])).assertNull();
    });

    it('仅一个文件直接返回', 0, () => {
      let f = makeFile('sodium.jar', 1000, false);
      let got = pickPrimaryFile([f]);
      expect(got !== null).assertTrue();
      if (got) expect(got.filename).assertEqual('sodium.jar');
    });

    it('优先返回 isPrimary=true 的文件', 0, () => {
      let a = makeFile('sodium-sources.jar', 5000, false);
      let b = makeFile('sodium.jar', 1000, true);  // primary 但 size 小
      let c = makeFile('sodium-javadoc.jar', 3000, false);
      let got = pickPrimaryFile([a, b, c]);
      expect(got !== null).assertTrue();
      if (got) expect(got.filename).assertEqual('sodium.jar');
    });

    it('多个 primary 取第一个', 0, () => {
      let a = makeFile('a.jar', 100, true);
      let b = makeFile('b.jar', 200, true);
      let got = pickPrimaryFile([a, b]);
      expect(got !== null).assertTrue();
      if (got) expect(got.filename).assertEqual('a.jar');
    });

    it('无 primary 时取 size 最大（且过滤 sources/javadoc/dev）', 0, () => {
      let a = makeFile('mod-sources.jar', 99999, false);
      let b = makeFile('mod-javadoc.jar', 88888, false);
      let c = makeFile('mod.jar', 5000, false);
      let d = makeFile('mod-extra.jar', 6000, false);
      let got = pickPrimaryFile([a, b, c, d]);
      expect(got !== null).assertTrue();
      if (got) expect(got.filename).assertEqual('mod-extra.jar');
    });

    it('全部都是 sources/javadoc 时回退到原始列表选最大', 0, () => {
      let a = makeFile('mod-sources.jar', 1000, false);
      let b = makeFile('mod-javadoc.jar', 2000, false);
      let got = pickPrimaryFile([a, b]);
      expect(got !== null).assertTrue();
      if (got) expect(got.filename).assertEqual('mod-javadoc.jar');
    });
  });

  // ==========================================================
  //  mergeProjects
  // ==========================================================
  describe('ModTypes.mergeProjects', () => {
    it('空输入返回空数组', 0, () => {
      expect(mergeProjects([], []).length).assertEqual(0);
    });

    it('两源无重复全部保留', 0, () => {
      let m: RemoteProject[] = [
        makeProject(ModSource.MODRINTH, 'sodium', 'AANobbMI'),
      ];
      let c: RemoteProject[] = [
        makeProject(ModSource.CURSEFORGE, 'jei', '238222'),
      ];
      let merged = mergeProjects(m, c);
      expect(merged.length).assertEqual(2);
      expect(merged[0].slug).assertEqual('sodium');   // Modrinth 先
      expect(merged[1].slug).assertEqual('jei');
    });

    it('同 slug 跨源 → 仅保留 Modrinth', 0, () => {
      let m: RemoteProject[] = [
        makeProject(ModSource.MODRINTH, 'sodium', 'AANobbMI'),
      ];
      let c: RemoteProject[] = [
        makeProject(ModSource.CURSEFORGE, 'sodium', '394468'),
      ];
      let merged = mergeProjects(m, c);
      expect(merged.length).assertEqual(1);
      expect(merged[0].source).assertEqual(ModSource.MODRINTH);
    });

    it('归一化 slug 跨源 → 去重', 0, () => {
      // Modrinth 上 'sodium' 与 CurseForge 上 'sodium-fabric' 应去重
      let m: RemoteProject[] = [
        makeProject(ModSource.MODRINTH, 'sodium', 'AANobbMI'),
      ];
      let c: RemoteProject[] = [
        makeProject(ModSource.CURSEFORGE, 'sodium-fabric', '394468'),
      ];
      let merged = mergeProjects(m, c);
      expect(merged.length).assertEqual(1);
      expect(merged[0].source).assertEqual(ModSource.MODRINTH);
    });

    it('Modrinth 内部重复也去重', 0, () => {
      let m: RemoteProject[] = [
        makeProject(ModSource.MODRINTH, 'Sodium', 'AANobbMI'),
        makeProject(ModSource.MODRINTH, 'sodium', 'OTHER'),
      ];
      let merged = mergeProjects(m, []);
      expect(merged.length).assertEqual(1);
      expect(merged[0].id).assertEqual('AANobbMI');
    });

    it('保持原数据顺序（modrinth 先，curseforge 后）', 0, () => {
      let m: RemoteProject[] = [
        makeProject(ModSource.MODRINTH, 'a', '1'),
        makeProject(ModSource.MODRINTH, 'b', '2'),
      ];
      let c: RemoteProject[] = [
        makeProject(ModSource.CURSEFORGE, 'c', '3'),
        makeProject(ModSource.CURSEFORGE, 'd', '4'),
      ];
      let merged = mergeProjects(m, c);
      expect(merged[0].slug).assertEqual('a');
      expect(merged[1].slug).assertEqual('b');
      expect(merged[2].slug).assertEqual('c');
      expect(merged[3].slug).assertEqual('d');
    });

    it('空 slug 项目被丢弃', 0, () => {
      let m: RemoteProject[] = [
        makeProject(ModSource.MODRINTH, '', 'broken'),
        makeProject(ModSource.MODRINTH, 'ok', 'good'),
      ];
      let merged = mergeProjects(m, []);
      expect(merged.length).assertEqual(1);
      expect(merged[0].slug).assertEqual('ok');
    });
  });

  // ==========================================================
  //  versionChannelRank
  // ==========================================================
  describe('ModTypes.versionChannelRank', () => {
    it('release < beta < alpha', 0, () => {
      let r = versionChannelRank(VersionChannel.RELEASE);
      let b = versionChannelRank(VersionChannel.BETA);
      let a = versionChannelRank(VersionChannel.ALPHA);
      expect(r < b).assertTrue();
      expect(b < a).assertTrue();
    });

    it('排序后 release 在最前', 0, () => {
      let arr: VersionChannel[] = [VersionChannel.ALPHA, VersionChannel.RELEASE, VersionChannel.BETA];
      arr.sort((x, y) => versionChannelRank(x) - versionChannelRank(y));
      expect(arr[0]).assertEqual(VersionChannel.RELEASE);
      expect(arr[1]).assertEqual(VersionChannel.BETA);
      expect(arr[2]).assertEqual(VersionChannel.ALPHA);
    });
  });

  // ==========================================================
  //  ModRepoError.fromUnknown
  // ==========================================================
  describe('ModRepoError.fromUnknown', () => {
    it('已是 ModRepoError 直接返回', 0, () => {
      let e = new ModRepoError(ModSource.MODRINTH, ModRepoErrorKind.NETWORK, 'down');
      let got = ModRepoError.fromUnknown(ModSource.MODRINTH, e);
      expect(got === e).assertTrue();
    });

    it('HTTP 5xx 报文 → HTTP_SERVER', 0, () => {
      let e = new Error('[HttpError] http=503 service unavailable');
      let got = ModRepoError.fromUnknown(ModSource.MODRINTH, e);
      expect(got.kind).assertEqual(ModRepoErrorKind.HTTP_SERVER);
      expect(got.httpStatus).assertEqual(503);
    });

    it('HTTP 4xx 报文 → HTTP_CLIENT', 0, () => {
      let e = new Error('[HttpError] http=429 too many');
      let got = ModRepoError.fromUnknown(ModSource.MODRINTH, e);
      expect(got.kind).assertEqual(ModRepoErrorKind.HTTP_CLIENT);
      expect(got.httpStatus).assertEqual(429);
    });

    it('Network 报文 → NETWORK', 0, () => {
      let e = new Error('[NetworkError] DnsError host unresolved');
      let got = ModRepoError.fromUnknown(ModSource.MODRINTH, e);
      expect(got.kind).assertEqual(ModRepoErrorKind.NETWORK);
    });

    it('SSL 报文 → NETWORK', 0, () => {
      let e = new Error('[SslError] certificate expired');
      let got = ModRepoError.fromUnknown(ModSource.MODRINTH, e);
      expect(got.kind).assertEqual(ModRepoErrorKind.NETWORK);
    });

    it('未知报文 → UNKNOWN', 0, () => {
      let e = new Error('something weird');
      let got = ModRepoError.fromUnknown(ModSource.MODRINTH, e);
      expect(got.kind).assertEqual(ModRepoErrorKind.UNKNOWN);
    });

    it('保留 source 字段', 0, () => {
      let e = new Error('whatever');
      let g1 = ModRepoError.fromUnknown(ModSource.MODRINTH, e);
      let g2 = ModRepoError.fromUnknown(ModSource.CURSEFORGE, e);
      expect(g1.source).assertEqual(ModSource.MODRINTH);
      expect(g2.source).assertEqual(ModSource.CURSEFORGE);
    });
  });
}

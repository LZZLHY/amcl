/*
 * CurseForgeUrls.test.ets — CurseForge URL/参数/响应映射纯函数单测（P1-MODS Phase 2.1a）
 *
 * 覆盖：
 *   - ModLoaderType / releaseType / relationType / sortField 数字编码双向映射
 *   - URL 构造（search / project / files / file / download-url）
 *   - CDN 镜像化（mirrorifyCurseForgeCdn / buildCurseForgeFileDownloadUrls）
 *   - 响应映射（mapCurseForgeMod / mapCurseForgeFileAsVersion 等）
 *   - 边界：downloadUrl 为空、loader 推断回退
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  CURSEFORGE_API_OFFICIAL,
  CURSEFORGE_API_MCIM,
  CURSEFORGE_GAME_ID,
  MCIM_CDN_PREFIX,
  toCurseForgeModLoaderType,
  fromCurseForgeModLoaderType,
  parseCurseForgeReleaseType,
  parseCurseForgeRelationType,
  toCurseForgeSortField,
  buildCurseForgeSearchUrl,
  buildCurseForgeProjectUrl,
  buildCurseForgeFilesUrl,
  buildCurseForgeFileUrl,
  buildCurseForgeFileDownloadUrl,
  mirrorifyCurseForgeCdn,
  buildCurseForgeFileDownloadUrls,
  extractSha1FromCfHashes,
  mapCurseForgeFile,
  mapCurseForgeDependency,
  mapCurseForgeFileAsVersion,
  mapCurseForgeMod,
  CFFileHashRaw,
  CFFileDependencyRaw,
  CFFileRaw,
  CFFileIndexRaw,
  CFModRaw,
  CFCategoryRaw,
  CFAuthorRaw,
} from 'mods';
import {
  ModSource,
  ResourceKind,
  VersionChannel,
  DependencyType,
} from 'mods';
import { SortBy } from 'mods';

// ============================================================
//  小工具：构造 fixture
// ============================================================

function makeHash(value: string, algo: number): CFFileHashRaw {
  return { value, algo };
}

function makeFile(overrides: Partial<CFFileRaw>): CFFileRaw {
  let base: CFFileRaw = {
    id: 12345,
    modId: 999,
    displayName: 'Test 1.0.0',
    fileName: 'test-1.0.0.jar',
    releaseType: 1,
    fileDate: '2024-01-01T00:00:00Z',
    fileLength: 1024,
    downloadCount: 100,
    downloadUrl: 'https://edge.forgecdn.net/files/3838/383/test.jar',
    gameVersions: ['1.20.4', 'Fabric'],
    dependencies: [],
    hashes: [makeHash('aaaa1111', 1)],
    isAvailable: true,
  };
  if (overrides.id !== undefined) base.id = overrides.id;
  if (overrides.modId !== undefined) base.modId = overrides.modId;
  if (overrides.displayName !== undefined) base.displayName = overrides.displayName;
  if (overrides.fileName !== undefined) base.fileName = overrides.fileName;
  if (overrides.releaseType !== undefined) base.releaseType = overrides.releaseType;
  if (overrides.fileDate !== undefined) base.fileDate = overrides.fileDate;
  if (overrides.fileLength !== undefined) base.fileLength = overrides.fileLength;
  if (overrides.downloadCount !== undefined) base.downloadCount = overrides.downloadCount;
  if (overrides.downloadUrl !== undefined) base.downloadUrl = overrides.downloadUrl;
  if (overrides.gameVersions !== undefined) base.gameVersions = overrides.gameVersions;
  if (overrides.dependencies !== undefined) base.dependencies = overrides.dependencies;
  if (overrides.hashes !== undefined) base.hashes = overrides.hashes;
  if (overrides.isAvailable !== undefined) base.isAvailable = overrides.isAvailable;
  return base;
}

function makeMod(overrides: Partial<CFModRaw>): CFModRaw {
  let base: CFModRaw = {
    id: 999,
    gameId: 432,
    name: 'Sodium',
    slug: 'sodium',
    summary: 'A modern rendering engine',
    classId: 6,
    downloadCount: 5000000,
    primaryCategoryId: 1,
    categories: [],
    authors: [{ id: 1, name: 'JellySquid' }] as CFAuthorRaw[],
    latestFilesIndexes: [],
    dateModified: '2024-01-01T00:00:00Z',
    isAvailable: true,
  };
  if (overrides.id !== undefined) base.id = overrides.id;
  if (overrides.name !== undefined) base.name = overrides.name;
  if (overrides.slug !== undefined) base.slug = overrides.slug;
  if (overrides.summary !== undefined) base.summary = overrides.summary;
  if (overrides.classId !== undefined) base.classId = overrides.classId;
  if (overrides.downloadCount !== undefined) base.downloadCount = overrides.downloadCount;
  if (overrides.thumbsUpCount !== undefined) base.thumbsUpCount = overrides.thumbsUpCount;
  if (overrides.categories !== undefined) base.categories = overrides.categories;
  if (overrides.authors !== undefined) base.authors = overrides.authors;
  if (overrides.logo !== undefined) base.logo = overrides.logo;
  if (overrides.links !== undefined) base.links = overrides.links;
  if (overrides.latestFilesIndexes !== undefined) base.latestFilesIndexes = overrides.latestFilesIndexes;
  if (overrides.latestFiles !== undefined) base.latestFiles = overrides.latestFiles;
  if (overrides.dateModified !== undefined) base.dateModified = overrides.dateModified;
  return base;
}

export default function curseForgeUrlsTest() {

  // ==========================================================
  //  ModLoaderType 双向映射
  // ==========================================================
  describe('CurseForgeUrls.ModLoaderType', () => {
    it('字符串 → 数字', 0, () => {
      expect(toCurseForgeModLoaderType('forge')).assertEqual(1);
      expect(toCurseForgeModLoaderType('liteloader')).assertEqual(3);
      expect(toCurseForgeModLoaderType('fabric')).assertEqual(4);
      expect(toCurseForgeModLoaderType('quilt')).assertEqual(5);
      expect(toCurseForgeModLoaderType('neoforge')).assertEqual(6);
    });

    it('未知 loader → 0 (Any)', 0, () => {
      expect(toCurseForgeModLoaderType('')).assertEqual(0);
      expect(toCurseForgeModLoaderType('rift')).assertEqual(0);
      expect(toCurseForgeModLoaderType('cauldron')).assertEqual(0);
    });

    it('大小写不敏感', 0, () => {
      expect(toCurseForgeModLoaderType('Fabric')).assertEqual(4);
      expect(toCurseForgeModLoaderType('NEOFORGE')).assertEqual(6);
    });

    it('数字 → 字符串', 0, () => {
      expect(fromCurseForgeModLoaderType(1)).assertEqual('forge');
      expect(fromCurseForgeModLoaderType(4)).assertEqual('fabric');
      expect(fromCurseForgeModLoaderType(5)).assertEqual('quilt');
      expect(fromCurseForgeModLoaderType(6)).assertEqual('neoforge');
    });

    it('未知数字 / 0 → ""', 0, () => {
      expect(fromCurseForgeModLoaderType(0)).assertEqual('');
      expect(fromCurseForgeModLoaderType(2)).assertEqual('');  // Cauldron
      expect(fromCurseForgeModLoaderType(99)).assertEqual('');
    });
  });

  // ==========================================================
  //  releaseType / relationType / sortField
  // ==========================================================
  describe('CurseForgeUrls.parseCurseForgeReleaseType', () => {
    it('1/2/3 → RELEASE/BETA/ALPHA', 0, () => {
      expect(parseCurseForgeReleaseType(1)).assertEqual(VersionChannel.RELEASE);
      expect(parseCurseForgeReleaseType(2)).assertEqual(VersionChannel.BETA);
      expect(parseCurseForgeReleaseType(3)).assertEqual(VersionChannel.ALPHA);
    });

    it('未知 → RELEASE', 0, () => {
      expect(parseCurseForgeReleaseType(0)).assertEqual(VersionChannel.RELEASE);
      expect(parseCurseForgeReleaseType(99)).assertEqual(VersionChannel.RELEASE);
    });
  });

  describe('CurseForgeUrls.parseCurseForgeRelationType', () => {
    it('1=Embedded / 6=Include → EMBEDDED', 0, () => {
      expect(parseCurseForgeRelationType(1)).assertEqual(DependencyType.EMBEDDED);
      expect(parseCurseForgeRelationType(6)).assertEqual(DependencyType.EMBEDDED);
    });

    it('2=Optional / 4=Tool → OPTIONAL', 0, () => {
      expect(parseCurseForgeRelationType(2)).assertEqual(DependencyType.OPTIONAL);
      expect(parseCurseForgeRelationType(4)).assertEqual(DependencyType.OPTIONAL);
    });

    it('3=Required → REQUIRED', 0, () => {
      expect(parseCurseForgeRelationType(3)).assertEqual(DependencyType.REQUIRED);
    });

    it('5=Incompatible → INCOMPATIBLE', 0, () => {
      expect(parseCurseForgeRelationType(5)).assertEqual(DependencyType.INCOMPATIBLE);
    });

    it('未知 → OPTIONAL', 0, () => {
      expect(parseCurseForgeRelationType(99)).assertEqual(DependencyType.OPTIONAL);
    });
  });

  describe('CurseForgeUrls.toCurseForgeSortField', () => {
    it('每个 SortBy 都映射到合法 sortField', 0, () => {
      expect(toCurseForgeSortField(SortBy.RELEVANCE)).assertEqual(1);
      expect(toCurseForgeSortField(SortBy.FOLLOWS)).assertEqual(2);
      expect(toCurseForgeSortField(SortBy.NEWEST)).assertEqual(3);
      expect(toCurseForgeSortField(SortBy.UPDATED)).assertEqual(3);
      expect(toCurseForgeSortField(SortBy.DOWNLOADS)).assertEqual(6);
    });
  });

  // ==========================================================
  //  URL 构造
  // ==========================================================
  describe('CurseForgeUrls.buildCurseForgeSearchUrl', () => {
    it('最小参数：仅必填', 0, () => {
      let r = buildCurseForgeSearchUrl('', 6, undefined, 0, 6, true, 0, 50);
      expect(r.primary.startsWith(CURSEFORGE_API_MCIM + '/mods/search?')).assertTrue();
      expect(r.primary.includes('gameId=' + CURSEFORGE_GAME_ID)).assertTrue();
      expect(r.primary.includes('classId=6')).assertTrue();
      expect(r.primary.includes('sortField=6')).assertTrue();
      expect(r.primary.includes('sortOrder=desc')).assertTrue();
      expect(r.primary.includes('index=0')).assertTrue();
      expect(r.primary.includes('pageSize=50')).assertTrue();
      // 未传过滤参数，不应该出现
      expect(r.primary.includes('searchFilter=')).assertFalse();
      expect(r.primary.includes('gameVersion=')).assertFalse();
      expect(r.primary.includes('modLoaderType=')).assertFalse();
      expect(r.mirrors.length).assertEqual(0);
    });

    it('完整参数 + URL 编码', 0, () => {
      let r = buildCurseForgeSearchUrl('sodium foo', 6, '1.20.4', 4, 6, true, 20, 20);
      expect(r.primary.includes('searchFilter=sodium%20foo')).assertTrue();
      expect(r.primary.includes('gameVersion=1.20.4')).assertTrue();
      expect(r.primary.includes('modLoaderType=4')).assertTrue();
    });

    it('modLoaderType=0 时省略参数', 0, () => {
      let r = buildCurseForgeSearchUrl('q', 6, '1.20.4', 0, 6, true, 0, 20);
      expect(r.primary.includes('modLoaderType=')).assertFalse();
    });

    it('sortOrderDesc=false → asc', 0, () => {
      let r = buildCurseForgeSearchUrl('', 6, undefined, 0, 4, false, 0, 50);
      expect(r.primary.includes('sortOrder=asc')).assertTrue();
    });

    it('mirrors 永远为空（仅 MCIM）', 0, () => {
      let r = buildCurseForgeSearchUrl('q', 6, '1.20.4', 4, 6, true, 0, 50);
      expect(r.mirrors.length).assertEqual(0);
      expect(r.primary.startsWith(CURSEFORGE_API_OFFICIAL)).assertFalse();
    });
  });

  describe('CurseForgeUrls.buildCurseForgeProjectUrl', () => {
    it('数字 modId 直接拼', 0, () => {
      let r = buildCurseForgeProjectUrl('394468');
      expect(r.primary).assertEqual(CURSEFORGE_API_MCIM + '/mods/394468');
      expect(r.mirrors.length).assertEqual(0);
    });

    it('特殊字符走 encode', 0, () => {
      let r = buildCurseForgeProjectUrl('a/b');
      expect(r.primary.includes('/mods/a%2Fb')).assertTrue();
    });
  });

  describe('CurseForgeUrls.buildCurseForgeFilesUrl', () => {
    it('最小参数', 0, () => {
      let r = buildCurseForgeFilesUrl('999', undefined, 0, 0, 50);
      expect(r.primary.startsWith(CURSEFORGE_API_MCIM + '/mods/999/files?')).assertTrue();
      expect(r.primary.includes('index=0')).assertTrue();
      expect(r.primary.includes('pageSize=50')).assertTrue();
      expect(r.primary.includes('gameVersion=')).assertFalse();
      expect(r.primary.includes('modLoaderType=')).assertFalse();
    });

    it('带过滤', 0, () => {
      let r = buildCurseForgeFilesUrl('999', '1.20.4', 4, 0, 50);
      expect(r.primary.includes('gameVersion=1.20.4')).assertTrue();
      expect(r.primary.includes('modLoaderType=4')).assertTrue();
    });
  });

  describe('CurseForgeUrls.buildCurseForgeFileUrl / buildCurseForgeFileDownloadUrl', () => {
    it('单文件元数据', 0, () => {
      let r = buildCurseForgeFileUrl('999', '5500');
      expect(r.primary).assertEqual(CURSEFORGE_API_MCIM + '/mods/999/files/5500');
    });

    it('真实下载 URL 兜底端点', 0, () => {
      let r = buildCurseForgeFileDownloadUrl('999', '5500');
      expect(r.primary).assertEqual(CURSEFORGE_API_MCIM + '/mods/999/files/5500/download-url');
    });
  });

  // ==========================================================
  //  CDN 镜像化
  // ==========================================================
  describe('CurseForgeUrls.mirrorifyCurseForgeCdn', () => {
    it('edge.forgecdn.net → mod.mcimirror.top', 0, () => {
      let r = mirrorifyCurseForgeCdn('https://edge.forgecdn.net/files/3838/383/sodium.jar');
      expect(r).assertEqual(MCIM_CDN_PREFIX + 'files/3838/383/sodium.jar');
    });

    it('mediafilez.forgecdn.net → mod.mcimirror.top', 0, () => {
      let r = mirrorifyCurseForgeCdn('https://mediafilez.forgecdn.net/files/4000/100/x.jar');
      expect(r).assertEqual(MCIM_CDN_PREFIX + 'files/4000/100/x.jar');
    });

    it('未知主机原样返回', 0, () => {
      let r = mirrorifyCurseForgeCdn('https://example.com/file.jar');
      expect(r).assertEqual('https://example.com/file.jar');
    });

    it('空串原样返回', 0, () => {
      expect(mirrorifyCurseForgeCdn('')).assertEqual('');
    });
  });

  describe('CurseForgeUrls.buildCurseForgeFileDownloadUrls', () => {
    it('已知 CDN: mcim 主、官方备', 0, () => {
      let r = buildCurseForgeFileDownloadUrls('https://edge.forgecdn.net/files/1/2/x.jar');
      expect(r.primary).assertEqual(MCIM_CDN_PREFIX + 'files/1/2/x.jar');
      expect(r.mirrors.length).assertEqual(1);
      expect(r.mirrors[0]).assertEqual('https://edge.forgecdn.net/files/1/2/x.jar');
    });

    it('未知 CDN: 仅返回原 URL', 0, () => {
      let r = buildCurseForgeFileDownloadUrls('https://example.com/x.jar');
      expect(r.primary).assertEqual('https://example.com/x.jar');
      expect(r.mirrors.length).assertEqual(0);
    });

    it('空串 → 空 primary + 空 mirrors', 0, () => {
      let r = buildCurseForgeFileDownloadUrls('');
      expect(r.primary).assertEqual('');
      expect(r.mirrors.length).assertEqual(0);
    });
  });

  // ==========================================================
  //  hash / file / dependency / version 映射
  // ==========================================================
  describe('CurseForgeUrls.extractSha1FromCfHashes', () => {
    it('algo===1 → 取出 sha1', 0, () => {
      let h: CFFileHashRaw[] = [makeHash('abcd', 1), makeHash('1234', 2)];
      expect(extractSha1FromCfHashes(h)).assertEqual('abcd');
    });

    it('无 algo===1 → null', 0, () => {
      let h: CFFileHashRaw[] = [makeHash('xxxx', 2)];
      expect(extractSha1FromCfHashes(h) === null).assertTrue();
    });

    it('空数组 → null', 0, () => {
      expect(extractSha1FromCfHashes([]) === null).assertTrue();
    });

    it('algo===1 但 value 为空 → null', 0, () => {
      let h: CFFileHashRaw[] = [makeHash('', 1)];
      expect(extractSha1FromCfHashes(h) === null).assertTrue();
    });
  });

  describe('CurseForgeUrls.mapCurseForgeFile', () => {
    it('正常文件：MCIM 主 + 官方 CDN 备 + sha1', 0, () => {
      let f = makeFile({});
      let rf = mapCurseForgeFile(f, true);
      expect(rf.url).assertEqual(MCIM_CDN_PREFIX + 'files/3838/383/test.jar');
      expect(rf.mirrors.length).assertEqual(1);
      expect(rf.filename).assertEqual('test-1.0.0.jar');
      expect(rf.size).assertEqual(1024);
      expect(rf.isPrimary).assertTrue();
      expect(rf.sha1).assertEqual('aaaa1111');
    });

    it('downloadUrl 为空 → url=空字符串，等待 /download-url 兜底', 0, () => {
      let f = makeFile({ downloadUrl: '' });
      let rf = mapCurseForgeFile(f, true);
      expect(rf.url).assertEqual('');
      expect(rf.mirrors.length).assertEqual(0);
    });

    it('isPrimary=false 透传', 0, () => {
      let f = makeFile({});
      let rf = mapCurseForgeFile(f, false);
      expect(rf.isPrimary).assertFalse();
    });

    it('hashes 不含 sha1 → 不写 sha1 字段', 0, () => {
      let f = makeFile({ hashes: [makeHash('md5val', 2)] });
      let rf = mapCurseForgeFile(f, true);
      expect(rf.sha1 === undefined).assertTrue();
    });
  });

  describe('CurseForgeUrls.mapCurseForgeDependency', () => {
    it('数字 modId → 字符串 projectId', 0, () => {
      let dep: CFFileDependencyRaw = { modId: 12345, relationType: 3 };
      let rd = mapCurseForgeDependency(dep);
      expect(rd.projectId).assertEqual('12345');
      expect(rd.dependencyType).assertEqual(DependencyType.REQUIRED);
    });

    it('relationType 5 → INCOMPATIBLE', 0, () => {
      let dep: CFFileDependencyRaw = { modId: 1, relationType: 5 };
      expect(mapCurseForgeDependency(dep).dependencyType).assertEqual(DependencyType.INCOMPATIBLE);
    });
  });

  describe('CurseForgeUrls.mapCurseForgeFileAsVersion', () => {
    it('loader/gameVersions 拆分正确', 0, () => {
      let f = makeFile({ gameVersions: ['1.20.4', 'Fabric', 'Quilt'] });
      let v = mapCurseForgeFileAsVersion(f);
      expect(v.source).assertEqual(ModSource.CURSEFORGE);
      expect(v.id).assertEqual('12345');
      expect(v.projectId).assertEqual('999');
      expect(v.gameVersions.length).assertEqual(1);
      expect(v.gameVersions[0]).assertEqual('1.20.4');
      expect(v.loaders.length).assertEqual(2);
      expect(v.loaders[0]).assertEqual('fabric');
      expect(v.loaders[1]).assertEqual('quilt');
    });

    it('versionType 来自 releaseType', 0, () => {
      let f = makeFile({ releaseType: 2 });
      expect(mapCurseForgeFileAsVersion(f).versionType).assertEqual(VersionChannel.BETA);
    });

    it('依赖被映射', 0, () => {
      let f = makeFile({
        dependencies: [
          { modId: 100, relationType: 3 },
          { modId: 200, relationType: 2 },
        ],
      });
      let v = mapCurseForgeFileAsVersion(f);
      expect(v.dependencies.length).assertEqual(2);
      expect(v.dependencies[0].projectId).assertEqual('100');
      expect(v.dependencies[0].dependencyType).assertEqual(DependencyType.REQUIRED);
      expect(v.dependencies[1].dependencyType).assertEqual(DependencyType.OPTIONAL);
    });

    it('files 数组只含一个 primary', 0, () => {
      let f = makeFile({});
      let v = mapCurseForgeFileAsVersion(f);
      expect(v.files.length).assertEqual(1);
      expect(v.files[0].isPrimary).assertTrue();
    });
  });

  // ==========================================================
  //  mapCurseForgeMod
  // ==========================================================
  describe('CurseForgeUrls.mapCurseForgeMod', () => {
    it('基础字段映射', 0, () => {
      let m = makeMod({});
      let p = mapCurseForgeMod(m);
      expect(p.source).assertEqual(ModSource.CURSEFORGE);
      expect(p.id).assertEqual('999');
      expect(p.slug).assertEqual('sodium');
      expect(p.kind).assertEqual(ResourceKind.MOD);
      expect(p.title).assertEqual('Sodium');
      expect(p.author).assertEqual('JellySquid');
      expect(p.downloads).assertEqual(5000000);
    });

    it('loader 从 latestFilesIndexes 推断', 0, () => {
      let m = makeMod({
        latestFilesIndexes: [
          { gameVersion: '1.20.4', fileId: 1, filename: 'a.jar', releaseType: 1, modLoader: 4 },
          { gameVersion: '1.20.4', fileId: 2, filename: 'b.jar', releaseType: 1, modLoader: 5 },
          { gameVersion: '1.20.2', fileId: 3, filename: 'c.jar', releaseType: 1, modLoader: 4 },  // dup
        ],
      });
      let p = mapCurseForgeMod(m);
      expect(p.loaders.length).assertEqual(2);
      // Set 顺序：根据插入顺序 fabric 先，quilt 后
      expect(p.loaders.indexOf('fabric') >= 0).assertTrue();
      expect(p.loaders.indexOf('quilt') >= 0).assertTrue();
    });

    it('loader 从 latestFiles 兜底（latestFilesIndexes 缺 modLoader）', 0, () => {
      let m = makeMod({
        latestFilesIndexes: [
          { gameVersion: '1.20.4', fileId: 1, filename: 'a.jar', releaseType: 1 },  // no modLoader
        ],
        latestFiles: [makeFile({ gameVersions: ['1.20.4', 'Forge'] })],
      });
      let p = mapCurseForgeMod(m);
      expect(p.loaders.length).assertEqual(1);
      expect(p.loaders[0]).assertEqual('forge');
    });

    it('gameVersions 去重保序', 0, () => {
      let m = makeMod({
        latestFilesIndexes: [
          { gameVersion: '1.20.4', fileId: 1, filename: 'a', releaseType: 1, modLoader: 4 },
          { gameVersion: '1.20.4', fileId: 2, filename: 'b', releaseType: 1, modLoader: 4 },
          { gameVersion: '1.20.2', fileId: 3, filename: 'c', releaseType: 1, modLoader: 4 },
        ],
      });
      let p = mapCurseForgeMod(m);
      expect(p.gameVersions.length).assertEqual(2);
      expect(p.gameVersions[0]).assertEqual('1.20.4');
      expect(p.gameVersions[1]).assertEqual('1.20.2');
    });

    it('classId → ResourceKind', 0, () => {
      expect(mapCurseForgeMod(makeMod({ classId: 6 })).kind).assertEqual(ResourceKind.MOD);
      expect(mapCurseForgeMod(makeMod({ classId: 12 })).kind).assertEqual(ResourceKind.RESOURCE_PACK);
      expect(mapCurseForgeMod(makeMod({ classId: 6552 })).kind).assertEqual(ResourceKind.SHADER);
    });

    it('未知 classId 回退 MOD', 0, () => {
      expect(mapCurseForgeMod(makeMod({ classId: 99999 })).kind).assertEqual(ResourceKind.MOD);
    });

    it('thumbsUpCount → follows', 0, () => {
      let p = mapCurseForgeMod(makeMod({ thumbsUpCount: 1234 }));
      expect(p.follows).assertEqual(1234);
    });

    it('未填 thumbsUpCount → follows=0', 0, () => {
      expect(mapCurseForgeMod(makeMod({})).follows).assertEqual(0);
    });

    it('categories 取 slug', 0, () => {
      let cats: CFCategoryRaw[] = [
        { id: 1, name: 'Optimization', slug: 'optimization' },
        { id: 2, name: 'API', slug: 'library-api' },
      ];
      let p = mapCurseForgeMod(makeMod({ categories: cats }));
      expect(p.categories.length).assertEqual(2);
      expect(p.categories[0]).assertEqual('optimization');
      expect(p.categories[1]).assertEqual('library-api');
    });

    it('logo / links 为 undefined 时回退空字符串', 0, () => {
      let p = mapCurseForgeMod(makeMod({}));
      expect(p.iconUrl).assertEqual('');
      expect(p.websiteUrl).assertEqual('');
    });

    it('logo / links 给定时被映射', 0, () => {
      let m = makeMod({
        logo: { url: 'https://example.com/logo.png' },
        links: { websiteUrl: 'https://www.curseforge.com/minecraft/mc-mods/sodium' },
      });
      let p = mapCurseForgeMod(m);
      expect(p.iconUrl).assertEqual('https://example.com/logo.png');
      expect(p.websiteUrl).assertEqual('https://www.curseforge.com/minecraft/mc-mods/sodium');
    });

    it('authors 空数组 → author=""', 0, () => {
      let p = mapCurseForgeMod(makeMod({ authors: [] }));
      expect(p.author).assertEqual('');
    });
  });
}

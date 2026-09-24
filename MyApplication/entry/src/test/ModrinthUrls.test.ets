/*
 * ModrinthUrls.test.ets — Modrinth URL 构造 + facets 编码 + 响应映射（P1-MODS Phase 1.2）
 *
 * 覆盖范围（纯函数，无 HTTP）：
 *   - buildModrinthFacets：loaders 折叠到 categories facet；MOD 以外忽略 loaders
 *   - buildSearchUrl / buildProjectUrl / buildVersionsUrl / buildVersionUrl / buildVersionFileSha1Url
 *   - mirrorifyModrinthCdn：cdn.modrinth.com → mod.mcimirror.top
 *   - buildFileDownloadUrls：primary/mirrors 顺序随 ModrinthSourceMode 变化
 *   - mapModrinthHit：loader 从 categories 拆分
 *   - mapModrinthProject / mapModrinthVersion / mapModrinthFile / mapModrinthDependency
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ModrinthSourceMode,
  MODRINTH_API_OFFICIAL,
  MODRINTH_API_MCIM,
  buildModrinthFacets,
  buildSearchUrl,
  buildProjectUrl,
  buildVersionsUrl,
  buildVersionUrl,
  buildVersionFileSha1Url,
  mirrorifyModrinthCdn,
  buildFileDownloadUrls,
  mapModrinthHit,
  mapModrinthProject,
  mapModrinthVersion,
  mapModrinthFile,
  mapModrinthDependency,
  ModrinthHitRaw,
  ModrinthProjectRaw,
  ModrinthVersionRaw,
  ModrinthFileRaw,
  ModrinthDependencyRaw,
} from 'mods';
import {
  ResourceKind,
  ModSource,
  VersionChannel,
  DependencyType,
} from 'mods';

export default function modrinthUrlsTest() {

  // ==========================================================
  //  buildModrinthFacets
  // ==========================================================
  describe('ModrinthUrls.buildModrinthFacets', () => {
    it('仅 kind：产生 project_type facet', 0, () => {
      let f = buildModrinthFacets(ResourceKind.MOD);
      expect(f).assertEqual('[["project_type:mod"]]');
    });

    it('kind + gameVersion + 单 loader：三个 facet', 0, () => {
      let f = buildModrinthFacets(ResourceKind.MOD, '1.20.4', ['fabric']);
      expect(f).assertEqual('[["project_type:mod"],["categories:fabric"],["versions:1.20.4"]]');
    });

    it('多 loader 合并到同一 OR 组', 0, () => {
      let f = buildModrinthFacets(ResourceKind.MOD, '1.20.4', ['fabric', 'quilt']);
      expect(f).assertEqual(
        '[["project_type:mod"],["categories:fabric","categories:quilt"],["versions:1.20.4"]]');
    });

    it('RESOURCE_PACK 忽略 loaders 参数（资源包不依赖 loader）', 0, () => {
      let f = buildModrinthFacets(ResourceKind.RESOURCE_PACK, '1.20.4', ['fabric']);
      expect(f).assertEqual('[["project_type:resourcepack"],["versions:1.20.4"]]');
    });

    it('SHADER 忽略 loaders', 0, () => {
      let f = buildModrinthFacets(ResourceKind.SHADER, undefined, ['iris']);
      expect(f).assertEqual('[["project_type:shader"]]');
    });

    it('categories 参数追加', 0, () => {
      let f = buildModrinthFacets(ResourceKind.MOD, undefined, undefined, ['performance']);
      expect(f).assertEqual('[["project_type:mod"],["categories:performance"]]');
    });

    it('空字符串 loader/category 被过滤', 0, () => {
      let f = buildModrinthFacets(ResourceKind.MOD, '', ['', 'fabric'], ['']);
      expect(f).assertEqual('[["project_type:mod"],["categories:fabric"]]');
    });
  });

  // ==========================================================
  //  buildSearchUrl
  // ==========================================================
  describe('ModrinthUrls.buildSearchUrl', () => {
    it('MCIM_FIRST：primary 是 MCIM，mirror 是官方', 0, () => {
      let u = buildSearchUrl('sodium', '[["project_type:mod"]]', 'downloads', 0, 20,
        ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.startsWith(MODRINTH_API_MCIM + '/search?')).assertTrue();
      expect(u.mirrors.length).assertEqual(1);
      expect(u.mirrors[0].startsWith(MODRINTH_API_OFFICIAL + '/search?')).assertTrue();
    });

    it('OFFICIAL_FIRST：primary 是官方，mirror 是 MCIM', 0, () => {
      let u = buildSearchUrl('sodium', '[]', 'relevance', 0, 20,
        ModrinthSourceMode.OFFICIAL_FIRST);
      expect(u.primary.startsWith(MODRINTH_API_OFFICIAL)).assertTrue();
      expect(u.mirrors[0].startsWith(MODRINTH_API_MCIM)).assertTrue();
    });

    it('query 被 URL 编码', 0, () => {
      let u = buildSearchUrl('cool mod', '[]', 'downloads', 0, 20,
        ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.indexOf('query=cool%20mod') >= 0).assertTrue();
    });

    it('facets 空 / "[]" 时不追加 facets 参数', 0, () => {
      let u = buildSearchUrl('x', '[]', 'downloads', 0, 20,
        ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.indexOf('facets=') < 0).assertTrue();
    });

    it('含 facets 时 URL 编码 JSON', 0, () => {
      let u = buildSearchUrl('x', '[["project_type:mod"]]', 'downloads', 0, 20,
        ModrinthSourceMode.MCIM_FIRST);
      // JSON 中的冒号 / 方括号 / 引号都会被编码
      expect(u.primary.indexOf('facets=%5B%5B%22project_type%3Amod%22%5D%5D') >= 0).assertTrue();
    });

    it('offset / limit 注入', 0, () => {
      let u = buildSearchUrl('x', '[]', 'downloads', 40, 20,
        ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.indexOf('offset=40') >= 0).assertTrue();
      expect(u.primary.indexOf('limit=20') >= 0).assertTrue();
    });
  });

  // ==========================================================
  //  buildProjectUrl / buildVersionsUrl / buildVersionUrl / buildVersionFileSha1Url
  // ==========================================================
  describe('ModrinthUrls.buildProjectUrl', () => {
    it('slug 直接拼到路径', 0, () => {
      let u = buildProjectUrl('sodium', ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary).assertEqual(MODRINTH_API_MCIM + '/project/sodium');
      expect(u.mirrors[0]).assertEqual(MODRINTH_API_OFFICIAL + '/project/sodium');
    });

    it('特殊字符被 URL 编码', 0, () => {
      let u = buildProjectUrl('foo/bar', ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.endsWith('/project/foo%2Fbar')).assertTrue();
    });
  });

  describe('ModrinthUrls.buildVersionsUrl', () => {
    it('无过滤参数', 0, () => {
      let u = buildVersionsUrl('AANobbMI', undefined, undefined, ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary).assertEqual(MODRINTH_API_MCIM + '/project/AANobbMI/version');
    });

    it('loaders 编码为 JSON 数组', 0, () => {
      let u = buildVersionsUrl('AANobbMI', ['fabric'], undefined, ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.indexOf('loaders=%5B%22fabric%22%5D') >= 0).assertTrue();
    });

    it('game_versions 编码为 JSON 数组', 0, () => {
      let u = buildVersionsUrl('AANobbMI', undefined, ['1.20.4'], ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.indexOf('game_versions=%5B%221.20.4%22%5D') >= 0).assertTrue();
    });

    it('两者都有时 & 连接', 0, () => {
      let u = buildVersionsUrl('AANobbMI', ['fabric'], ['1.20.4'], ModrinthSourceMode.MCIM_FIRST);
      let p = u.primary;
      expect(p.indexOf('loaders=') >= 0).assertTrue();
      expect(p.indexOf('game_versions=') >= 0).assertTrue();
      // 只能有一个 ?
      let qCount = 0;
      for (let i = 0; i < p.length; i++) {
        if (p.charAt(i) === '?') qCount++;
      }
      expect(qCount).assertEqual(1);
    });

    it('空数组视为无过滤', 0, () => {
      let u = buildVersionsUrl('AANobbMI', [], [], ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary.indexOf('?') < 0).assertTrue();
    });
  });

  describe('ModrinthUrls.buildVersionUrl', () => {
    it('直接拼 versionId', 0, () => {
      let u = buildVersionUrl('gbFgsJkh', ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary).assertEqual(MODRINTH_API_MCIM + '/version/gbFgsJkh');
    });
  });

  describe('ModrinthUrls.buildVersionFileSha1Url', () => {
    it('含 algorithm=sha1 query', 0, () => {
      let u = buildVersionFileSha1Url('deadbeef', ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary).assertEqual(MODRINTH_API_MCIM + '/version_file/deadbeef?algorithm=sha1');
    });
  });

  // ==========================================================
  //  mirrorifyModrinthCdn / buildFileDownloadUrls
  // ==========================================================
  describe('ModrinthUrls.mirrorifyModrinthCdn', () => {
    it('cdn.modrinth.com → mod.mcimirror.top', 0, () => {
      let got = mirrorifyModrinthCdn(
        'https://cdn.modrinth.com/data/AANobbMI/versions/xxx/sodium.jar');
      expect(got).assertEqual(
        'https://mod.mcimirror.top/data/AANobbMI/versions/xxx/sodium.jar');
    });

    it('非 cdn.modrinth.com URL 原样返回', 0, () => {
      let got = mirrorifyModrinthCdn('https://example.com/foo.jar');
      expect(got).assertEqual('https://example.com/foo.jar');
    });

    it('空串安全', 0, () => {
      expect(mirrorifyModrinthCdn('')).assertEqual('');
    });
  });

  describe('ModrinthUrls.buildFileDownloadUrls', () => {
    const OFFICIAL = 'https://cdn.modrinth.com/data/AANobbMI/versions/xxx/sodium.jar';
    const MCIM = 'https://mod.mcimirror.top/data/AANobbMI/versions/xxx/sodium.jar';

    it('MCIM_FIRST：MCIM 主，官方 fallback', 0, () => {
      let u = buildFileDownloadUrls(OFFICIAL, ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary).assertEqual(MCIM);
      expect(u.mirrors[0]).assertEqual(OFFICIAL);
    });

    it('OFFICIAL_FIRST：官方主，MCIM fallback', 0, () => {
      let u = buildFileDownloadUrls(OFFICIAL, ModrinthSourceMode.OFFICIAL_FIRST);
      expect(u.primary).assertEqual(OFFICIAL);
      expect(u.mirrors[0]).assertEqual(MCIM);
    });

    it('非 Modrinth CDN URL 不生成 mirror', 0, () => {
      let u = buildFileDownloadUrls('https://example.com/x.jar', ModrinthSourceMode.MCIM_FIRST);
      expect(u.primary).assertEqual('https://example.com/x.jar');
      expect(u.mirrors.length).assertEqual(0);
    });
  });

  // ==========================================================
  //  mapModrinthHit
  // ==========================================================
  describe('ModrinthUrls.mapModrinthHit', () => {
    it('从 categories 拆出 loader', 0, () => {
      let hit = makeHit({
        project_id: 'AANobbMI', slug: 'sodium', project_type: 'mod', title: 'Sodium',
        description: 'Fast', categories: ['fabric', 'performance', 'optimization'],
        versions: ['1.20.4', '1.20.3'], downloads: 50_000_000, follows: 1000,
        icon_url: 'https://cdn.modrinth.com/icon.png', author: 'jellysquid3',
        date_modified: '2024-02-10T00:00:00Z',
      });
      let p = mapModrinthHit(hit);
      expect(p.source).assertEqual(ModSource.MODRINTH);
      expect(p.id).assertEqual('AANobbMI');
      expect(p.kind).assertEqual(ResourceKind.MOD);
      expect(p.loaders.length).assertEqual(1);
      expect(p.loaders[0]).assertEqual('fabric');
      expect(p.categories.length).assertEqual(2);  // performance / optimization
      expect(p.gameVersions.length).assertEqual(2);
      expect(p.downloads).assertEqual(50_000_000);
    });

    it('project_type 未知 → 回退 MOD', 0, () => {
      let hit = makeHit({
        project_id: 'x', slug: 'x', project_type: 'weird', title: '', description: '',
        categories: [], versions: [], downloads: 0, follows: 0, icon_url: '', author: '',
        date_modified: '',
      });
      let p = mapModrinthHit(hit);
      expect(p.kind).assertEqual(ResourceKind.MOD);
    });

    it('resourcepack 无 loader', 0, () => {
      let hit = makeHit({
        project_id: 'x', slug: 'faithful', project_type: 'resourcepack', title: 'Faithful',
        description: '', categories: ['combat', 'decoration'], versions: ['1.20.4'],
        downloads: 100, follows: 0, icon_url: '', author: 'a',
        date_modified: '',
      });
      let p = mapModrinthHit(hit);
      expect(p.kind).assertEqual(ResourceKind.RESOURCE_PACK);
      expect(p.loaders.length).assertEqual(0);
      expect(p.categories.length).assertEqual(2);
    });

    it('websiteUrl 构造', 0, () => {
      let hit = makeHit({
        project_id: 'x', slug: 'sodium', project_type: 'mod', title: '',
        description: '', categories: [], versions: [], downloads: 0, follows: 0,
        icon_url: '', author: '',
        date_modified: '',
      });
      let p = mapModrinthHit(hit);
      expect(p.websiteUrl).assertEqual('https://modrinth.com/mod/sodium');
    });
  });

  // ==========================================================
  //  mapModrinthProject（字段与 hit 不同）
  // ==========================================================
  describe('ModrinthUrls.mapModrinthProject', () => {
    it('loaders 直接取自 loaders 字段', 0, () => {
      let proj = makeProjectRaw({
        id: 'x', slug: 'sodium', project_type: 'mod', title: 'Sodium',
        description: '', categories: ['performance'], additional_categories: [],
        loaders: ['fabric', 'quilt'], game_versions: ['1.20.4'],
        downloads: 0, followers: 100, icon_url: '', team: 'team1',
        source_url: '', issues_url: '', wiki_url: '',
        updated: '2024-02-10T00:00:00Z',
      });
      let p = mapModrinthProject(proj);
      expect(p.loaders.length).assertEqual(2);
      expect(p.author).assertEqual('team1');
      expect(p.categories.length).assertEqual(1);
      expect(p.follows).assertEqual(100);
    });
  });

  // ==========================================================
  //  mapModrinthFile / mapModrinthDependency / mapModrinthVersion
  // ==========================================================
  describe('ModrinthUrls.mapModrinthFile', () => {
    it('提取 sha1/sha512 + mirrors', 0, () => {
      let f = mapModrinthFile({
        url: 'https://cdn.modrinth.com/data/a/versions/b/sodium.jar',
        filename: 'sodium.jar',
        primary: true,
        size: 1024,
        hashes: { 'sha1': 'deadbeef', 'sha512': 'cafebabe' },
      }, ModrinthSourceMode.MCIM_FIRST);
      expect(f.isPrimary).assertTrue();
      expect(f.sha1).assertEqual('deadbeef');
      expect(f.sha512).assertEqual('cafebabe');
      expect(f.size).assertEqual(1024);
      expect(f.url.indexOf('mcimirror.top') >= 0).assertTrue();
      expect(f.mirrors[0].indexOf('cdn.modrinth.com') >= 0).assertTrue();
    });

    it('缺 hash 字段安全', 0, () => {
      let f = mapModrinthFile({
        url: 'https://example.com/x.jar', filename: 'x.jar', primary: false, size: 1,
        hashes: {},
      }, ModrinthSourceMode.MCIM_FIRST);
      expect(f.sha1 === undefined).assertTrue();
      expect(f.sha512 === undefined).assertTrue();
    });
  });

  describe('ModrinthUrls.mapModrinthDependency', () => {
    it('全字段', 0, () => {
      let d = mapModrinthDependency({
        project_id: 'p1', version_id: 'v1', file_name: 'x.jar',
        dependency_type: 'required',
      });
      expect(d.projectId).assertEqual('p1');
      expect(d.versionId).assertEqual('v1');
      expect(d.fileName).assertEqual('x.jar');
      expect(d.dependencyType).assertEqual(DependencyType.REQUIRED);
    });

    it('空字段被省略', 0, () => {
      let d = mapModrinthDependency({
        project_id: 'p1',
        dependency_type: 'optional',
      });
      expect(d.projectId).assertEqual('p1');
      expect(d.versionId === undefined).assertTrue();
      expect(d.fileName === undefined).assertTrue();
      expect(d.dependencyType).assertEqual(DependencyType.OPTIONAL);
    });
  });

  describe('ModrinthUrls.mapModrinthVersion', () => {
    it('完整版本映射', 0, () => {
      let v = mapModrinthVersion({
        id: 'v1', project_id: 'p1', name: '0.5.8 (1.20.4)', version_number: '0.5.8',
        changelog: 'fix bug', version_type: 'release',
        game_versions: ['1.20.4'], loaders: ['fabric'],
        dependencies: [{ project_id: 'fabric-api', dependency_type: 'required' }],
        files: [{
          url: 'https://cdn.modrinth.com/data/p1/versions/v1/sodium.jar',
          filename: 'sodium.jar', primary: true, size: 500_000,
          hashes: { 'sha1': 'aa', 'sha512': 'bb' },
        }],
        date_published: '2024-02-10T00:00:00Z', downloads: 100,
      }, ModrinthSourceMode.MCIM_FIRST);
      expect(v.id).assertEqual('v1');
      expect(v.projectId).assertEqual('p1');
      expect(v.versionNumber).assertEqual('0.5.8');
      expect(v.versionType).assertEqual(VersionChannel.RELEASE);
      expect(v.gameVersions[0]).assertEqual('1.20.4');
      expect(v.loaders[0]).assertEqual('fabric');
      expect(v.files.length).assertEqual(1);
      expect(v.files[0].sha1).assertEqual('aa');
      expect(v.dependencies.length).assertEqual(1);
      expect(v.dependencies[0].dependencyType).assertEqual(DependencyType.REQUIRED);
      expect(v.downloads).assertEqual(100);
    });

    it('beta / alpha 映射', 0, () => {
      let beta = mapModrinthVersion(makeMinimalVersion('beta'), ModrinthSourceMode.MCIM_FIRST);
      expect(beta.versionType).assertEqual(VersionChannel.BETA);
      let alpha = mapModrinthVersion(makeMinimalVersion('alpha'), ModrinthSourceMode.MCIM_FIRST);
      expect(alpha.versionType).assertEqual(VersionChannel.ALPHA);
    });

    it('缺字段安全兜底', 0, () => {
      let v = mapModrinthVersion({
        id: 'v1', project_id: 'p1', name: '1.0', version_number: '1.0',
        changelog: '', version_type: 'release',
        game_versions: [], loaders: [], dependencies: [], files: [],
        date_published: '', downloads: 0,
      }, ModrinthSourceMode.MCIM_FIRST);
      expect(v.gameVersions.length).assertEqual(0);
      expect(v.loaders.length).assertEqual(0);
      expect(v.files.length).assertEqual(0);
      expect(v.dependencies.length).assertEqual(0);
    });
  });
}

// ============================================================
//  测试 fixture（精确类型，避开 ESObject / any）
// ============================================================

interface HitFixture {
  project_id: string;
  slug: string;
  project_type: string;
  title: string;
  description: string;
  categories: string[];
  versions: string[];
  downloads: number;
  follows: number;
  icon_url: string;
  author: string;
  date_modified: string;
}

function makeHit(x: HitFixture): ModrinthHitRaw {
  return {
    project_id: x.project_id,
    slug: x.slug,
    project_type: x.project_type,
    title: x.title,
    description: x.description,
    categories: x.categories,
    display_categories: x.categories,
    versions: x.versions,
    downloads: x.downloads,
    follows: x.follows,
    icon_url: x.icon_url,
    author: x.author,
    date_modified: x.date_modified,
  };
}

function makeProjectRaw(x: ModrinthProjectRaw): ModrinthProjectRaw {
  return x;
}

function makeMinimalVersion(channel: string): ModrinthVersionRaw {
  return {
    id: 'v', project_id: 'p', name: 'n', version_number: '1.0',
    changelog: '', version_type: channel,
    game_versions: [], loaders: [], dependencies: [], files: [],
    date_published: '', downloads: 0,
  };
}

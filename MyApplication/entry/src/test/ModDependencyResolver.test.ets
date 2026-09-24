/*
 * ModDependencyResolver.test.ets — 模组依赖图解析单测（P1-MODS Phase 2.3a）
 *
 * 覆盖：
 *   - pickBestVersion / isProjectInstalled 纯函数
 *   - BFS 链式遍历、防环、深度上限
 *   - REQUIRED / OPTIONAL / EMBEDDED / INCOMPATIBLE 四种依赖类型分别处理
 *   - 已装跳过、无匹配版本、缺 projectId 等失败路径
 *   - extractDependencyFiles 抽取主文件
 *
 * 通过注入 fetcher（Map 数据源）避免 HTTP 依赖。
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ModDependencyResolver,
  ProjectFetcher,
  VersionsFetcher,
  ResolveOptions,
  ResolveResult,
  ResolvedDependency,
  pickBestVersion,
  isProjectInstalled,
  extractDependencyFiles,
} from 'mods';
import {
  ModSource,
  ModIntegrity,
  ResourceKind,
  VersionChannel,
  DependencyType,
  RemoteProject,
  RemoteVersion,
  RemoteFile,
  RemoteDependency,
  LocalMod,
} from 'mods';

// ============================================================
//  Fixture 工厂
// ============================================================

function P(id: string, slug: string): RemoteProject {
  return {
    source: ModSource.MODRINTH, id, slug, kind: ResourceKind.MOD,
    title: slug, summary: '', author: '', iconUrl: '',
    downloads: 0, follows: 0, categories: [], loaders: [],
    gameVersions: [], websiteUrl: '', dateModified: '',
  };
}

function V(
  id: string, projectId: string,
  loaders: string[], gameVersions: string[],
  channel: VersionChannel,
  date: string,
  deps: RemoteDependency[] = [],
  files: RemoteFile[] = [],
): RemoteVersion {
  return {
    source: ModSource.MODRINTH, id, projectId,
    name: id, versionNumber: id,
    changelog: '',
    versionType: channel,
    gameVersions, loaders, files, dependencies: deps,
    datePublished: date, downloads: 0,
  };
}

function F(filename: string, isPrimary: boolean = true, sha1: string = ''): RemoteFile {
  let rf: RemoteFile = { url: 'https://x/' + filename, mirrors: [], filename, size: 1, isPrimary };
  if (sha1.length > 0) rf.sha1 = sha1;
  return rf;
}

function D(projectId: string, t: DependencyType): RemoteDependency {
  return { projectId, dependencyType: t };
}

interface FakeFetchers {
  projectFetcher: ProjectFetcher;
  versionsFetcher: VersionsFetcher;
  callsGetProject: number;
  callsGetVersions: number;
}

interface CallCounter { proj: number; ver: number; }

function makeFetchers(
  projects: Map<string, RemoteProject>,
  versions: Map<string, RemoteVersion[]>,
  failProjects?: Set<string>,
  failVersions?: Set<string>,
): FakeFetchers {
  let counter: CallCounter = { proj: 0, ver: 0 };
  let pf: ProjectFetcher = async (s: ModSource, pid: string) => {
    counter.proj++;
    let key = s + ':' + pid;
    if (failProjects !== undefined && failProjects.has(key)) {
      throw new Error('mock getProject fail: ' + key);
    }
    let p = projects.get(key);
    if (p === undefined) throw new Error('not in fixture: ' + key);
    return p;
  };
  let vf: VersionsFetcher = async (
    s: ModSource, pid: string, loaders: string[], gvs: string[],
  ) => {
    counter.ver++;
    let key = s + ':' + pid;
    if (failVersions !== undefined && failVersions.has(key)) {
      throw new Error('mock getVersions fail: ' + key);
    }
    let arr = versions.get(key);
    if (arr === undefined) return [];
    return arr;
  };
  return {
    projectFetcher: pf,
    versionsFetcher: vf,
    get callsGetProject() { return counter.proj; },
    get callsGetVersions() { return counter.ver; },
  };
}

function defaultOpt(): ResolveOptions {
  return { gameVersion: '1.20.4', loader: 'fabric', installed: [] };
}

export default function modDependencyResolverTest() {

  // ==========================================================
  //  pickBestVersion 纯函数
  // ==========================================================
  describe('ModDependencyResolver.pickBestVersion', () => {
    it('严格匹配 loader+gameVersion', 0, () => {
      let v1 = V('1', 'x', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01');
      let v2 = V('2', 'x', ['forge'], ['1.20.4'], VersionChannel.RELEASE, '2024-02-01');
      let v3 = V('3', 'x', ['fabric'], ['1.20.2'], VersionChannel.RELEASE, '2024-03-01');
      expect(pickBestVersion([v1, v2, v3], 'fabric', '1.20.4')!.id).assertEqual('1');
    });

    it('release 优先 beta', 0, () => {
      let v1 = V('1', 'x', ['fabric'], ['1.20.4'], VersionChannel.BETA, '2024-12-01');
      let v2 = V('2', 'x', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01');
      // release 旧但仍优先
      expect(pickBestVersion([v1, v2], 'fabric', '1.20.4')!.id).assertEqual('2');
    });

    it('同 channel 按 datePublished 降序', 0, () => {
      let a = V('a', 'x', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01');
      let b = V('b', 'x', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-12-01');
      expect(pickBestVersion([a, b], 'fabric', '1.20.4')!.id).assertEqual('b');
    });

    it('loader 为空 → 不参与过滤', 0, () => {
      let v = V('1', 'x', ['forge'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01');
      expect(pickBestVersion([v], '', '1.20.4')!.id).assertEqual('1');
    });

    it('gameVersion 为空 → 不参与过滤', 0, () => {
      let v = V('1', 'x', ['fabric'], ['1.19.2'], VersionChannel.RELEASE, '2024-01-01');
      expect(pickBestVersion([v], 'fabric', '')!.id).assertEqual('1');
    });

    it('无匹配 → null', 0, () => {
      let v = V('1', 'x', ['forge'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01');
      expect(pickBestVersion([v], 'fabric', '1.20.4') === null).assertTrue();
    });

    it('空数组 → null', 0, () => {
      expect(pickBestVersion([], 'fabric', '1.20.4') === null).assertTrue();
    });
  });

  // ==========================================================
  //  isProjectInstalled
  // ==========================================================
  describe('ModDependencyResolver.isProjectInstalled', () => {
    it('来源、版本与完整性均已确认且启用时命中', 0, () => {
      let installed: LocalMod[] = [
        {
          filePath: '/a.jar', filename: 'a.jar', enabled: true, sizeBytes: 1, sha1: '',
          remoteSource: ModSource.MODRINTH, remoteProjectId: 'sodium',
          remoteVersionId: 'sodium-current', integrity: ModIntegrity.VERIFIED,
        },
      ];
      expect(isProjectInstalled(ModSource.MODRINTH, 'sodium', installed)).assertTrue();
    });

    it('不同 source 同 id → false', 0, () => {
      let installed: LocalMod[] = [
        {
          filePath: '', filename: '', enabled: true, sizeBytes: 0, sha1: '',
          remoteSource: ModSource.MODRINTH, remoteProjectId: 'sodium',
        },
      ];
      expect(isProjectInstalled(ModSource.CURSEFORGE, 'sodium', installed)).assertFalse();
    });

    it('空 projectId → false', 0, () => {
      let installed: LocalMod[] = [
        {
          filePath: '', filename: '', enabled: true, sizeBytes: 0, sha1: '',
          remoteSource: ModSource.MODRINTH, remoteProjectId: 'sodium',
        },
      ];
      expect(isProjectInstalled(ModSource.MODRINTH, '', installed)).assertFalse();
    });

    it('空 installed → false', 0, () => {
      expect(isProjectInstalled(ModSource.MODRINTH, 'sodium', [])).assertFalse();
    });
  });

  // ==========================================================
  //  resolve — 简单链式
  // ==========================================================
  describe('ModDependencyResolver.resolve 链式', () => {
    it('root 无依赖 → 空 dependencies', 0, async () => {
      let f = makeFetchers(new Map<string, RemoteProject>(), new Map<string, RemoteVersion[]>());
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('r', 'rp', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01');
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(0);
      expect(res.conflicts.length).assertEqual(0);
      expect(res.depthExceeded).assertFalse();
    });

    it('root → A：1 个 REQUIRED 依赖被解析', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:fabric-api', P('fabric-api', 'fabric-api'));
      let versions = new Map<string, RemoteVersion[]>();
      versions.set('modrinth:fabric-api',
        [V('fa-1', 'fabric-api', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [], [F('fa.jar')])]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('sodium-1', 'sodium', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('fabric-api', DependencyType.REQUIRED)]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].projectId).assertEqual('fabric-api');
      expect(res.dependencies[0].version !== null).assertTrue();
      expect(res.dependencies[0].alreadyInstalled).assertFalse();
    });

    it('root → A → B：链式 BFS', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:A', P('A', 'A'));
      projects.set('modrinth:B', P('B', 'B'));
      let versions = new Map<string, RemoteVersion[]>();
      versions.set('modrinth:A', [
        V('A-1', 'A', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
          [D('B', DependencyType.REQUIRED)], [F('A.jar')]),
      ]);
      versions.set('modrinth:B', [
        V('B-1', 'B', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [], [F('B.jar')]),
      ]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('A', DependencyType.REQUIRED)]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(2);
      expect(res.dependencies[0].projectId).assertEqual('A');
      expect(res.dependencies[1].projectId).assertEqual('B');
    });
  });

  // ==========================================================
  //  resolve — 防环
  // ==========================================================
  describe('ModDependencyResolver.resolve 防环', () => {
    it('A → root 循环不死', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:A', P('A', 'A'));
      let versions = new Map<string, RemoteVersion[]>();
      versions.set('modrinth:A', [
        V('A-1', 'A', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
          [D('R', DependencyType.REQUIRED)], [F('A.jar')]),  // 反指 root
      ]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('A', DependencyType.REQUIRED)]);
      let res = await resolver.resolve(root, defaultOpt());
      // 只看到 A，不会再次解析 R
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].projectId).assertEqual('A');
    });

    it('A → B → A 间接循环', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:A', P('A', 'A'));
      projects.set('modrinth:B', P('B', 'B'));
      let versions = new Map<string, RemoteVersion[]>();
      versions.set('modrinth:A', [
        V('A-1', 'A', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
          [D('B', DependencyType.REQUIRED)], [F('A.jar')]),
      ]);
      versions.set('modrinth:B', [
        V('B-1', 'B', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
          [D('A', DependencyType.REQUIRED)], [F('B.jar')]),
      ]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('A', DependencyType.REQUIRED)]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(2);
    });
  });

  // ==========================================================
  //  resolve — 类型分支
  // ==========================================================
  describe('ModDependencyResolver.resolve 类型分支', () => {
    it('EMBEDDED 跳过', 0, async () => {
      let f = makeFetchers(new Map<string, RemoteProject>(), new Map<string, RemoteVersion[]>());
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('libX', DependencyType.EMBEDDED)]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(0);
      expect(f.callsGetProject).assertEqual(0);
    });

    it('INCOMPATIBLE 仅在冲突模组实际启用时生效', 0, async () => {
      let f = makeFetchers(new Map<string, RemoteProject>(), new Map<string, RemoteVersion[]>());
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('optifine', DependencyType.INCOMPATIBLE)]);
      const options = defaultOpt();
      options.installed = [{ filePath: '/optifine.jar', filename: 'optifine.jar', enabled: true,
        sizeBytes: 1, sha1: '', remoteSource: ModSource.MODRINTH, remoteProjectId: 'optifine' }];
      let res = await resolver.resolve(root, options);
      expect(res.dependencies.length).assertEqual(0);
      expect(res.conflicts.length).assertEqual(1);
      expect(res.conflicts[0].projectId).assertEqual('optifine');
    });

    it('OPTIONAL 默认不展开（标记 version=null）', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:O', P('O', 'O'));
      let versions = new Map<string, RemoteVersion[]>();
      versions.set('modrinth:O', [V('O-1', 'O', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [], [F('O.jar')])]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('O', DependencyType.OPTIONAL)]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].dependencyType).assertEqual(DependencyType.OPTIONAL);
      expect(res.dependencies[0].version === null).assertTrue();
      expect(f.callsGetProject).assertEqual(0);
    });

    it('OPTIONAL followOptional=true → 当 REQUIRED 处理', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:O', P('O', 'O'));
      let versions = new Map<string, RemoteVersion[]>();
      versions.set('modrinth:O', [V('O-1', 'O', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [], [F('O.jar')])]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('O', DependencyType.OPTIONAL)]);
      let opt = defaultOpt();
      opt.followOptional = true;
      let res = await resolver.resolve(root, opt);
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].version !== null).assertTrue();
    });
  });

  // ==========================================================
  //  resolve — 已装跳过 / 失败路径
  // ==========================================================
  describe('ModDependencyResolver.resolve 失败/已装路径', () => {
    it('已装项目 → 仍调 getProject（拿元数据）但不调 getVersions', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:fabric-api', P('fabric-api', 'Fabric API'));
      let f = makeFetchers(projects, new Map<string, RemoteVersion[]>());
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher,
        async (_source: ModSource, id: string): Promise<RemoteVersion> =>
          V(id, 'fabric-api', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [], [F('api.jar')]));
      let opt = defaultOpt();
      opt.installed = [
        {
          filePath: '', filename: '', enabled: true, sizeBytes: 0, sha1: '',
          remoteSource: ModSource.MODRINTH, remoteProjectId: 'fabric-api',
          remoteVersionId: 'api-current', integrity: ModIntegrity.VERIFIED,
        },
      ];
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('fabric-api', DependencyType.REQUIRED)]);
      let res = await resolver.resolve(root, opt);
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].alreadyInstalled).assertTrue();
      // 2026-05-17：alreadyInstalled 项目仍调 getProject，让 UI 能展示 mod 名 / 作者
      // （原行为是 0，但 ModDetailSheet 的依赖行需要 project.title，否则只显示 projectId）。
      // 已装项读取具体版本及其依赖，不需要查询候选版本列表。
      expect(f.callsGetProject).assertEqual(1);
      expect(f.callsGetVersions).assertEqual(0);
      expect(res.dependencies[0].project !== null).assertTrue();
    });

    it('getProject 失败 → errorMessage 填入 + project=null', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      let versions = new Map<string, RemoteVersion[]>();
      let failProj: Set<string> = new Set<string>();
      failProj.add('modrinth:bad');
      let f = makeFetchers(projects, versions, failProj);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('bad', DependencyType.REQUIRED)]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].project === null).assertTrue();
      expect(res.dependencies[0].errorMessage !== null).assertTrue();
    });

    it('无匹配版本 → version=null', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:X', P('X', 'X'));
      let versions = new Map<string, RemoteVersion[]>();
      // X 只有 forge 版本
      versions.set('modrinth:X', [V('X-1', 'X', ['forge'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [], [F('X.jar')])]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('X', DependencyType.REQUIRED)]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].version === null).assertTrue();
      expect(res.dependencies[0].errorMessage !== null).assertTrue();
    });

    it('缺 projectId → errorMessage 填入', 0, async () => {
      let f = makeFetchers(new Map<string, RemoteProject>(), new Map<string, RemoteVersion[]>());
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      // dep 仅给 fileName
      let dep: RemoteDependency = { fileName: 'mystery.jar', dependencyType: DependencyType.REQUIRED };
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [dep]);
      let res = await resolver.resolve(root, defaultOpt());
      expect(res.dependencies.length).assertEqual(1);
      expect(res.dependencies[0].projectId).assertEqual('');
      expect(res.dependencies[0].errorMessage !== null).assertTrue();
    });
  });

  // ==========================================================
  //  resolve — 深度上限
  // ==========================================================
  describe('ModDependencyResolver.resolve 深度上限', () => {
    it('maxDepth=1 时第 2 层不展开', 0, async () => {
      let projects = new Map<string, RemoteProject>();
      projects.set('modrinth:A', P('A', 'A'));
      projects.set('modrinth:B', P('B', 'B'));
      let versions = new Map<string, RemoteVersion[]>();
      versions.set('modrinth:A', [
        V('A-1', 'A', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
          [D('B', DependencyType.REQUIRED)], [F('A.jar')]),
      ]);
      versions.set('modrinth:B', [
        V('B-1', 'B', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01', [], [F('B.jar')]),
      ]);
      let f = makeFetchers(projects, versions);
      let resolver = new ModDependencyResolver(f.projectFetcher, f.versionsFetcher);
      let root = V('R', 'R', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024-01-01',
        [D('A', DependencyType.REQUIRED)]);
      let opt = defaultOpt();
      opt.maxDepth = 1;
      let res = await resolver.resolve(root, opt);
      // A 在深度 1，可解析；B 在深度 2，超限
      expect(res.dependencies.length).assertEqual(2);
      let resolvedA = res.dependencies.filter((d) => d.projectId === 'A')[0];
      expect(resolvedA.version !== null).assertTrue();
      let resolvedB = res.dependencies.filter((d) => d.projectId === 'B')[0];
      expect(resolvedB.version === null).assertTrue();
      expect(resolvedB.errorMessage !== null).assertTrue();
      expect(res.depthExceeded).assertTrue();
    });
  });

  // ==========================================================
  //  extractDependencyFiles
  // ==========================================================
  describe('ModDependencyResolver.extractDependencyFiles', () => {
    it('跳过已满足项，但必需依赖解析失败必须阻断', 0, () => {
      let f1 = F('a.jar', true);
      let v1 = V('v1', 'a', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024', [], [f1]);
      let f2 = F('b.jar', true);
      let v2 = V('v2', 'b', ['fabric'], ['1.20.4'], VersionChannel.RELEASE, '2024', [], [f2]);
      let d1: ResolvedDependency = {
        dependencyType: DependencyType.REQUIRED, parentProjectId: 'r',
        projectId: 'a', project: null, version: v1,
        alreadyInstalled: false, errorMessage: null, compatWarning: null,
      };
      let d2: ResolvedDependency = {
        dependencyType: DependencyType.REQUIRED, parentProjectId: 'r',
        projectId: 'b', project: null, version: v2,
        alreadyInstalled: true, errorMessage: null, compatWarning: null,
      };
      let d3: ResolvedDependency = {
        dependencyType: DependencyType.REQUIRED, parentProjectId: 'r',
        projectId: 'c', project: null, version: null,
        alreadyInstalled: false, errorMessage: 'fail', compatWarning: null,
      };
      let deps: ResolvedDependency[] = [d1, d2, d3];
      let files = extractDependencyFiles([d1, d2]);
      expect(files.length).assertEqual(1);
      expect(files[0].filename).assertEqual('a.jar');
      let rejected = false;
      try { extractDependencyFiles(deps); } catch (e) { rejected = true; }
      expect(rejected).assertTrue();
    });
  });
}

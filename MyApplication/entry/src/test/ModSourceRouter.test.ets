/*
 * ModSourceRouter.test.ets — 双源路由器单测（P1-MODS Phase 2.2）
 *
 * 覆盖：
 *   - isAvailable：任一源可用即真
 *   - repoFor / allRepos
 *   - search 双源合并 + slug 跨源去重
 *   - search 一源失败不阻塞另一源
 *   - search 两源都失败 → 抛 ModRepoError
 *   - 排序：DOWNLOADS / FOLLOWS / NEWEST / RELEVANCE round-robin
 *   - getProject fallback 行为
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ModSourceRouter,
  sortMergedHits,
} from 'mods';
import {
  ModSource,
  ResourceKind,
  RemoteProject,
  RemoteVersion,
} from 'mods';
import {
  IRemoteModRepository,
  SearchOptions,
  SearchResult,
  SortBy,
  ModRepoError,
  ModRepoErrorKind,
} from 'mods';

// ============================================================
//  FakeRepo
// ============================================================

class FakeRepo implements IRemoteModRepository {
  readonly source: ModSource;
  available: boolean = true;
  /** 下次 search 返回什么 */
  nextSearchResult: SearchResult | null = null;
  /** 下次 search 抛错 */
  nextSearchError: Object | null = null;
  /** 下次 getProject 返回什么 */
  nextProject: RemoteProject | null = null;
  nextProjectError: Object | null = null;

  searchCalls: SearchOptions[] = [];

  constructor(source: ModSource) {
    this.source = source;
  }

  isAvailable(): boolean { return this.available; }

  async search(opt: SearchOptions): Promise<SearchResult> {
    this.searchCalls.push(opt);
    if (this.nextSearchError !== null) {
      let e = this.nextSearchError as Error;
      this.nextSearchError = null;
      throw e;
    }
    if (this.nextSearchResult !== null) {
      let r = this.nextSearchResult;
      return r;
    }
    return { hits: [], totalHits: 0, offset: opt.offset, pageSize: opt.pageSize };
  }

  async getProject(idOrSlug: string): Promise<RemoteProject> {
    if (this.nextProjectError !== null) {
      let e = this.nextProjectError as Error;
      this.nextProjectError = null;
      throw e;
    }
    if (this.nextProject !== null) return this.nextProject;
    throw new Error('no fixture');
  }

  async getVersions(): Promise<RemoteVersion[]> { return []; }
  async getVersion(): Promise<RemoteVersion> { throw new Error('not impl'); }
}

function makeProj(
  source: ModSource, id: string, slug: string,
  downloads: number, follows: number, dateModified: string,
): RemoteProject {
  return {
    source, id, slug, kind: ResourceKind.MOD,
    title: slug, summary: '', author: '', iconUrl: '',
    downloads, follows, categories: [], loaders: [],
    gameVersions: [], websiteUrl: '', dateModified,
  };
}

function makeOpt(
  query: string = '', kind: ResourceKind = ResourceKind.MOD,
  sortBy: SortBy = SortBy.DOWNLOADS,
): SearchOptions {
  return {
    query, kind, sortBy, offset: 0, pageSize: 20,
  };
}

export default function modSourceRouterTest() {

  // ==========================================================
  //  构造 + isAvailable + repoFor
  // ==========================================================
  describe('ModSourceRouter 构造', () => {
    it('空 repos 构造抛错', 0, () => {
      try {
        let r = new ModSourceRouter([]);
        // 不应到达
        let unreached = r.isAvailable();
        expect(unreached).assertFalse();
      } catch (e) {
        let err = e as Error;
        expect(err.message.indexOf('at least one') >= 0).assertTrue();
      }
    });

    it('source 字段取首个 repo', 0, () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      let r = new ModSourceRouter([m, c]);
      expect(r.source).assertEqual(ModSource.MODRINTH);
    });
  });

  describe('ModSourceRouter.isAvailable', () => {
    it('两源都可用 → true', 0, () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      let r = new ModSourceRouter([m, c]);
      expect(r.isAvailable()).assertTrue();
    });

    it('仅一源可用 → true', 0, () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.available = false;
      let r = new ModSourceRouter([m, c]);
      expect(r.isAvailable()).assertTrue();
    });

    it('两源都不可用 → false', 0, () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.available = false;
      c.available = false;
      let r = new ModSourceRouter([m, c]);
      expect(r.isAvailable()).assertFalse();
    });
  });

  describe('ModSourceRouter.repoFor / allRepos', () => {
    it('按 source 命中', 0, () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      let r = new ModSourceRouter([m, c]);
      expect(r.repoFor(ModSource.MODRINTH) === m).assertTrue();
      expect(r.repoFor(ModSource.CURSEFORGE) === c).assertTrue();
    });

    it('未注册的 source → null', 0, () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let r = new ModSourceRouter([m]);
      expect(r.repoFor(ModSource.CURSEFORGE) === null).assertTrue();
    });

    it('allRepos 返回独立副本', 0, () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      let r = new ModSourceRouter([m, c]);
      let arr = r.allRepos();
      expect(arr.length).assertEqual(2);
      arr.pop();
      expect(r.allRepos().length).assertEqual(2);  // 没影响内部
    });
  });

  // ==========================================================
  //  search 双源合并 + 去重
  // ==========================================================
  describe('ModSourceRouter.search 双源合并', () => {
    it('两源各 2 条 → 合并 4 条', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.nextSearchResult = {
        hits: [
          makeProj(ModSource.MODRINTH, 'a', 'sodium', 5_000_000, 1000, '2024-03-01'),
          makeProj(ModSource.MODRINTH, 'b', 'lithium', 3_000_000, 500, '2024-02-01'),
        ],
        totalHits: 2, offset: 0, pageSize: 20,
      };
      c.nextSearchResult = {
        hits: [
          makeProj(ModSource.CURSEFORGE, 'c', 'jei', 8_000_000, 0, '2024-04-01'),
          makeProj(ModSource.CURSEFORGE, 'd', 'create', 7_000_000, 0, '2024-05-01'),
        ],
        totalHits: 2, offset: 0, pageSize: 20,
      };
      let r = new ModSourceRouter([m, c]);
      let res = await r.search(makeOpt());
      expect(res.hits.length).assertEqual(4);
      expect(res.totalHits).assertEqual(4);
    });

    it('跨源同 slug → 去重保留先 push 源（Modrinth 优先）', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.nextSearchResult = {
        hits: [
          makeProj(ModSource.MODRINTH, 'mod-id-a', 'sodium', 5_000_000, 1000, '2024-03-01'),
        ],
        totalHits: 1, offset: 0, pageSize: 20,
      };
      c.nextSearchResult = {
        hits: [
          makeProj(ModSource.CURSEFORGE, 'cf-id-a', 'sodium', 8_000_000, 0, '2024-04-01'),
        ],
        totalHits: 1, offset: 0, pageSize: 20,
      };
      let r = new ModSourceRouter([m, c]);
      let res = await r.search(makeOpt());
      expect(res.hits.length).assertEqual(1);
      expect(res.hits[0].source).assertEqual(ModSource.MODRINTH);
      expect(res.hits[0].id).assertEqual('mod-id-a');
    });

    it('一源失败不阻塞另一源', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.nextSearchError = new ModRepoError(ModSource.MODRINTH, ModRepoErrorKind.NETWORK, 'offline');
      c.nextSearchResult = {
        hits: [makeProj(ModSource.CURSEFORGE, 'x', 'jei', 1_000, 0, '2024-04-01')],
        totalHits: 1, offset: 0, pageSize: 20,
      };
      let r = new ModSourceRouter([m, c]);
      let res = await r.search(makeOpt());
      expect(res.hits.length).assertEqual(1);
      expect(res.hits[0].source).assertEqual(ModSource.CURSEFORGE);
    });

    it('两源都失败 → 抛 ModRepoError', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.nextSearchError = new Error('m fail');
      c.nextSearchError = new Error('c fail');
      let r = new ModSourceRouter([m, c]);
      let threw = false;
      try { await r.search(makeOpt()); }
      catch (e) { threw = true; }
      expect(threw).assertTrue();
    });

    it('没有可用源 → 抛 ModRepoError(NETWORK)', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.available = false;
      c.available = false;
      let r = new ModSourceRouter([m, c]);
      let threw = false;
      try { await r.search(makeOpt()); }
      catch (e) {
        threw = true;
        expect(e instanceof ModRepoError).assertTrue();
      }
      expect(threw).assertTrue();
    });

    it('不可用源不发请求', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.available = false;
      c.nextSearchResult = {
        hits: [makeProj(ModSource.CURSEFORGE, 'x', 'jei', 100, 0, '2024-01-01')],
        totalHits: 1, offset: 0, pageSize: 20,
      };
      let r = new ModSourceRouter([m, c]);
      await r.search(makeOpt());
      expect(m.searchCalls.length).assertEqual(0);
      expect(c.searchCalls.length).assertEqual(1);
    });
  });

  // ==========================================================
  //  排序
  // ==========================================================
  describe('ModSourceRouter sortMergedHits', () => {
    it('DOWNLOADS：按下载量降序', 0, () => {
      let a = makeProj(ModSource.MODRINTH, '1', 'a', 100, 0, '');
      let b = makeProj(ModSource.MODRINTH, '2', 'b', 999, 0, '');
      let c = makeProj(ModSource.CURSEFORGE, '3', 'c', 500, 0, '');
      let result = sortMergedHits([a, b, c], SortBy.DOWNLOADS, [[a, b], [c]]);
      expect(result[0].slug).assertEqual('b');
      expect(result[1].slug).assertEqual('c');
      expect(result[2].slug).assertEqual('a');
    });

    it('FOLLOWS：按 follows 降序', 0, () => {
      let a = makeProj(ModSource.MODRINTH, '1', 'a', 0, 100, '');
      let b = makeProj(ModSource.MODRINTH, '2', 'b', 0, 999, '');
      let result = sortMergedHits([a, b], SortBy.FOLLOWS, [[a, b], []]);
      expect(result[0].slug).assertEqual('b');
    });

    it('NEWEST：dateModified 字符串降序', 0, () => {
      let a = makeProj(ModSource.MODRINTH, '1', 'a', 0, 0, '2024-01-01');
      let b = makeProj(ModSource.MODRINTH, '2', 'b', 0, 0, '2024-12-01');
      let c = makeProj(ModSource.MODRINTH, '3', 'c', 0, 0, '2024-06-01');
      let result = sortMergedHits([a, b, c], SortBy.NEWEST, [[a, b, c], []]);
      expect(result[0].slug).assertEqual('b');
      expect(result[1].slug).assertEqual('c');
      expect(result[2].slug).assertEqual('a');
    });

    it('RELEVANCE：round-robin 交错', 0, () => {
      let m1 = makeProj(ModSource.MODRINTH, 'm1', 'one', 0, 0, '');
      let m2 = makeProj(ModSource.MODRINTH, 'm2', 'two', 0, 0, '');
      let c1 = makeProj(ModSource.CURSEFORGE, 'c1', 'three', 0, 0, '');
      let c2 = makeProj(ModSource.CURSEFORGE, 'c2', 'four', 0, 0, '');
      let result = sortMergedHits([m1, m2, c1, c2], SortBy.RELEVANCE, [[m1, m2], [c1, c2]]);
      // 期望交错：m1 → c1 → m2 → c2
      expect(result.length).assertEqual(4);
      expect(result[0].slug).assertEqual('one');
      expect(result[1].slug).assertEqual('three');
      expect(result[2].slug).assertEqual('two');
      expect(result[3].slug).assertEqual('four');
    });

    it('RELEVANCE：单源场景仍然返回原序', 0, () => {
      let a = makeProj(ModSource.MODRINTH, '1', 'a', 0, 0, '');
      let b = makeProj(ModSource.MODRINTH, '2', 'b', 0, 0, '');
      let result = sortMergedHits([a, b], SortBy.RELEVANCE, [[a, b]]);
      expect(result[0].slug).assertEqual('a');
      expect(result[1].slug).assertEqual('b');
    });
  });

  // ==========================================================
  //  getProject fallback
  // ==========================================================
  describe('ModSourceRouter.getProject fallback', () => {
    it('第一个源失败 → 试第二个', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.nextProjectError = new Error('m down');
      c.nextProject = makeProj(ModSource.CURSEFORGE, 'cf-1', 'sodium', 1, 0, '');
      let r = new ModSourceRouter([m, c]);
      let p = await r.getProject('sodium');
      expect(p.source).assertEqual(ModSource.CURSEFORGE);
    });

    it('两源都失败 → 抛错', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.nextProjectError = new Error('m down');
      c.nextProjectError = new Error('c down');
      let r = new ModSourceRouter([m, c]);
      let threw = false;
      try { await r.getProject('sodium'); }
      catch (e) { threw = true; }
      expect(threw).assertTrue();
    });

    it('不可用源被跳过', 0, async () => {
      let m = new FakeRepo(ModSource.MODRINTH);
      let c = new FakeRepo(ModSource.CURSEFORGE);
      m.available = false;
      c.nextProject = makeProj(ModSource.CURSEFORGE, 'cf-1', 'sodium', 1, 0, '');
      let r = new ModSourceRouter([m, c]);
      let p = await r.getProject('sodium');
      expect(p.source).assertEqual(ModSource.CURSEFORGE);
    });
  });
}

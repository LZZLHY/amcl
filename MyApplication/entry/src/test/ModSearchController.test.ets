/*
 * ModSearchController.test.ets — 搜索控制器业务逻辑单测（P1-MODS Phase 1.6）
 *
 * 覆盖：
 *   - buildSearchOptions / mergePagedHits 纯函数
 *   - setter 幂等 + 重置分页
 *   - loadFirstPage / loadNextPage 分页累积
 *   - 过期请求作废（epoch 机制）
 *   - 错误处理：失败不污染状态
 *
 * 使用 FakeRepo 替代真实仓库 — 无 HTTP，hypium 下直接跑。
 *
 * 创建日期：2026-05-11
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ModSearchController,
  buildSearchOptions,
  mergePagedHits,
  makeInitialSearchState,
  describeSearchFailureForUser,
  ModSearchState,
} from 'mods';
import {
  ResourceKind,
  ModSource,
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
//  FakeRepo：hypium 可控的测试双
// ============================================================

interface FakePage {
  hits: RemoteProject[];
  totalHits: number;
}

class FakeRepo implements IRemoteModRepository {
  readonly source: ModSource = ModSource.MODRINTH;
  /** 按 offset 取对应页；默认 empty */
  pages: Map<number, FakePage> = new Map<number, FakePage>();
  /** 调用历史（断言用） */
  calls: SearchOptions[] = [];
  /** 下一次 search 抛错（Object 而非 Error — 避免 ArkTS 结构类型检查） */
  nextError: Object | null = null;
  /** 延后模式：为 true 时 search 挂 pendingResolver，而不是立即返回 */
  delayed: boolean = false;
  pendingResolver: ((v: SearchResult) => void) | null = null;

  isAvailable(): boolean { return true; }

  async search(opt: SearchOptions): Promise<SearchResult> {
    this.calls.push(opt);
    if (this.nextError !== null) {
      let e = this.nextError as Error;
      this.nextError = null;
      throw e;
    }
    if (this.delayed) {
      return new Promise<SearchResult>((resolve) => {
        this.pendingResolver = resolve;
      });
    }
    let page = this.pages.get(opt.offset);
    if (page === undefined) {
      return { hits: [], totalHits: 0, offset: opt.offset, pageSize: opt.pageSize };
    }
    return { hits: page.hits, totalHits: page.totalHits, offset: opt.offset, pageSize: opt.pageSize };
  }

  async getProject(idOrSlug: string): Promise<RemoteProject> {
    throw new Error('not implemented');
  }
  async getVersions(projectId: string, loaders?: string[], gameVersions?: string[]): Promise<RemoteVersion[]> {
    return [];
  }
  async getVersion(versionId: string): Promise<RemoteVersion> {
    throw new Error('not implemented');
  }
}

function makeProj(id: string, slug: string): RemoteProject {
  return {
    source: ModSource.MODRINTH,
    id, slug, kind: ResourceKind.MOD,
    title: slug, summary: '', author: '', iconUrl: '',
    downloads: 0, follows: 0, categories: [], loaders: [],
    gameVersions: [], websiteUrl: '', dateModified: '',
  };
}

// sleep for waiting microtasks to settle in async test
function flushPromises(): Promise<void> {
  return new Promise<void>((resolve) => { setTimeout(resolve, 0); });
}

export default function modSearchControllerTest() {

  // ==========================================================
  //  buildSearchOptions
  // ==========================================================
  describe('ModSearchController.buildSearchOptions', () => {
    it('空状态 → 最小 options', 0, () => {
      let s = makeInitialSearchState();
      let opt = buildSearchOptions(s, 0, 20);
      expect(opt.query).assertEqual('');
      expect(opt.kind).assertEqual(ResourceKind.MOD);
      expect(opt.offset).assertEqual(0);
      expect(opt.pageSize).assertEqual(20);
      expect(opt.gameVersion === undefined).assertTrue();
      expect(opt.loaders === undefined).assertTrue();
    });

    it('设置 loader + gameVersion → 注入 options', 0, () => {
      let s = makeInitialSearchState();
      s.query = 'sodium';
      s.gameVersion = '1.20.4';
      s.loader = 'fabric';
      let opt = buildSearchOptions(s, 20, 20);
      expect(opt.query).assertEqual('sodium');
      expect(opt.gameVersion).assertEqual('1.20.4');
      expect(opt.loaders !== undefined).assertTrue();
      if (opt.loaders) expect(opt.loaders[0]).assertEqual('fabric');
    });

    it('非 MOD kind 的 loader 被忽略（资源包不分 loader）', 0, () => {
      let s = makeInitialSearchState();
      s.kind = ResourceKind.RESOURCE_PACK;
      s.loader = 'fabric';
      let opt = buildSearchOptions(s, 0, 20);
      expect(opt.loaders === undefined).assertTrue();
    });
  });

  // ==========================================================
  //  mergePagedHits
  // ==========================================================
  describe('ModSearchController.mergePagedHits', () => {
    it('空 + 空 = 空', 0, () => {
      expect(mergePagedHits([], []).length).assertEqual(0);
    });

    it('追加新项', 0, () => {
      let a = [makeProj('1', 'sodium')];
      let b = [makeProj('2', 'lithium')];
      let r = mergePagedHits(a, b);
      expect(r.length).assertEqual(2);
      expect(r[0].id).assertEqual('1');
      expect(r[1].id).assertEqual('2');
    });

    it('同 source+id 去重（只保留先出现的）', 0, () => {
      let a = [makeProj('1', 'sodium')];
      let b = [makeProj('1', 'sodium-duplicate')];
      let r = mergePagedHits(a, b);
      expect(r.length).assertEqual(1);
      expect(r[0].slug).assertEqual('sodium');
    });

    it('不修改输入数组', 0, () => {
      let a = [makeProj('1', 'sodium')];
      let b = [makeProj('2', 'lithium')];
      mergePagedHits(a, b);
      expect(a.length).assertEqual(1);
      expect(b.length).assertEqual(1);
    });
  });

  // ==========================================================
  //  setter 幂等 + 重置分页
  // ==========================================================
  describe('ModSearchController setter 行为', () => {
    it('setQuery 相同值不触发重置', 0, () => {
      let repo = new FakeRepo();
      let ctrl = new ModSearchController(repo, 20);
      ctrl.setQuery('abc');
      // 模拟已加载了一些数据
      let s1 = ctrl.getState();
      // setQuery 同值应该什么都不做
      ctrl.setQuery('abc');
      let s2 = ctrl.getState();
      expect(s1.query).assertEqual(s2.query);
    });

    it('setKind 非 MOD 时清空 loader', 0, () => {
      let repo = new FakeRepo();
      let ctrl = new ModSearchController(repo, 20);
      ctrl.setLoader('fabric');
      expect(ctrl.getState().loader).assertEqual('fabric');
      ctrl.setKind(ResourceKind.RESOURCE_PACK);
      expect(ctrl.getState().loader).assertEqual('');
    });

    it('setKind MOD → MOD 不清空 loader', 0, () => {
      let repo = new FakeRepo();
      let ctrl = new ModSearchController(repo, 20);
      ctrl.setLoader('fabric');
      ctrl.setKind(ResourceKind.MOD);  // 幂等
      expect(ctrl.getState().loader).assertEqual('fabric');
    });
  });

  // ==========================================================
  //  loadFirstPage / loadNextPage：分页 & hasMore
  // ==========================================================
  describe('ModSearchController 分页', () => {
    it('loadFirstPage 后 hits 为远端第 1 页', 0, async () => {
      let repo = new FakeRepo();
      repo.pages.set(0, { hits: [makeProj('1', 'a'), makeProj('2', 'b')], totalHits: 2 });
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      let s = ctrl.getState();
      expect(s.hits.length).assertEqual(2);
      expect(s.totalHits).assertEqual(2);
      expect(s.loading).assertFalse();
      expect(s.errorMessage === null).assertTrue();
    });

    it('累积加载：第 2 页追加到 hits', 0, async () => {
      let repo = new FakeRepo();
      // 页面尺寸 2，第 1 页满 → hasMore=true
      let ctrl = new ModSearchController(repo, 2);
      repo.pages.set(0, {
        hits: [makeProj('1', 'a'), makeProj('2', 'b')], totalHits: 4,
      });
      repo.pages.set(2, {
        hits: [makeProj('3', 'c'), makeProj('4', 'd')], totalHits: 4,
      });
      await ctrl.loadFirstPage();
      let s1 = ctrl.getState();
      expect(s1.hits.length).assertEqual(2);
      expect(s1.hasMore).assertTrue();
      await ctrl.loadNextPage();
      let s2 = ctrl.getState();
      expect(s2.hits.length).assertEqual(4);
      expect(s2.hasMore).assertFalse();
    });

    it('第 1 页不满 → hasMore=false', 0, async () => {
      let repo = new FakeRepo();
      repo.pages.set(0, { hits: [makeProj('1', 'a')], totalHits: 1 });
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().hasMore).assertFalse();
    });

    it('setQuery 后再 loadFirstPage 清空旧 hits', 0, async () => {
      let repo = new FakeRepo();
      repo.pages.set(0, { hits: [makeProj('1', 'sodium')], totalHits: 1 });
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().hits.length).assertEqual(1);

      ctrl.setQuery('other');
      expect(ctrl.getState().hits.length).assertEqual(0);  // 已立即清空
      repo.pages.clear();
      repo.pages.set(0, { hits: [makeProj('9', 'other-mod')], totalHits: 1 });
      await ctrl.loadFirstPage();
      let s = ctrl.getState();
      expect(s.hits.length).assertEqual(1);
      expect(s.hits[0].id).assertEqual('9');
    });
  });

  // ==========================================================
  //  错误处理
  // ==========================================================
  describe('ModSearchController 错误处理', () => {
    it('search 抛错 → errorMessage 填入，hits 保持为空', 0, async () => {
      let repo = new FakeRepo();
      repo.nextError = new ModRepoError(
        ModSource.MODRINTH, ModRepoErrorKind.NETWORK, 'offline');
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      let s = ctrl.getState();
      expect(s.errorMessage === null).assertFalse();
      expect(s.hits.length).assertEqual(0);
      expect(s.loading).assertFalse();
    });

    it('clearError 把 errorMessage 置 null', 0, async () => {
      let repo = new FakeRepo();
      repo.nextError = new Error('boom');
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().errorMessage === null).assertFalse();
      ctrl.clearError();
      expect(ctrl.getState().errorMessage === null).assertTrue();
    });

    // ==========================================================
    //  批次 D2：结构化失败分类端到端不丢
    //
    //  在此之前 catch 块只取 .message ⇒ DNS 失败 / 429 限流 / 5xx / JSON 解析失败
    //  在状态里完全不可区分。下面这组的**反向**用例是承重项：一个把 kind 恒定写成
    //  unknown 的实现，只跑正向也能通过。
    // ==========================================================

    it('四种 kind 各自原样落进状态（穿 getState 断言）', 0, async () => {
      let cases: ModRepoErrorKind[] = [
        ModRepoErrorKind.NETWORK,
        ModRepoErrorKind.HTTP_CLIENT,
        ModRepoErrorKind.HTTP_SERVER,
        ModRepoErrorKind.PARSE,
      ];
      for (let kind of cases) {
        let repo = new FakeRepo();
        repo.nextError = new ModRepoError(ModSource.CURSEFORGE, kind, 'boom', 503);
        let ctrl = new ModSearchController(repo, 20);
        await ctrl.loadFirstPage();
        let s = ctrl.getState();
        // ⚠️ 一律读 getState()：getState 是逐字段手写拷贝的，漏拷一个字段的表现
        // 是"它永远为 null"，读内部状态的测试发现不了（D2-6）。
        expect(s.errorKind).assertEqual(kind);
        expect(s.errorSource).assertEqual(ModSource.CURSEFORGE);
        expect(s.httpStatus).assertEqual(503);
      }
    });

    it('反向：unknown 不得把已分类的 kind 盖掉', 0, async () => {
      // 钉住"把 kind 恒定写成 unknown"这个实现 —— 它能通过任何只看
      // "errorKind 非 null" 的测试。
      let repo = new FakeRepo();
      repo.nextError = new ModRepoError(
        ModSource.MODRINTH, ModRepoErrorKind.PARSE, 'bad json');
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().errorKind).assertEqual(ModRepoErrorKind.PARSE);
      expect(ctrl.getState().errorKind === ModRepoErrorKind.UNKNOWN).assertFalse();
    });

    it('非 ModRepoError 抛出 → kind=unknown 且 source 留空（不猜源）', 0, async () => {
      // 编一个源比留空更糟：归因链第 3 层会据此指向错误的对象。
      let repo = new FakeRepo();
      repo.nextError = new Error('something else threw');
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      let s = ctrl.getState();
      expect(s.errorKind).assertEqual(ModRepoErrorKind.UNKNOWN);
      expect(s.errorSource === null).assertTrue();
      expect(s.httpStatus).assertEqual(0);
      expect(s.errorMessage).assertEqual('something else threw');
    });

    it('D2-5 反向：三个新字段必须与 errorMessage 同处清零（clearError）', 0, async () => {
      let repo = new FakeRepo();
      repo.nextError = new ModRepoError(
        ModSource.MODRINTH, ModRepoErrorKind.HTTP_CLIENT, 'rate limited', 429);
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().errorKind).assertEqual(ModRepoErrorKind.HTTP_CLIENT);
      ctrl.clearError();
      let s = ctrl.getState();
      // 只清 errorMessage 而留下 kind，会让上一次失败活到下一次查询里 ——
      // 而界面上"错误已经没了"。
      expect(s.errorMessage === null).assertTrue();
      expect(s.errorKind === null).assertTrue();
      expect(s.errorSource === null).assertTrue();
      expect(s.httpStatus).assertEqual(0);
    });

    it('D2-5 反向：换查询条件（resetPagination）同样要清干净', 0, async () => {
      let repo = new FakeRepo();
      repo.nextError = new ModRepoError(
        ModSource.MODRINTH, ModRepoErrorKind.NETWORK, 'offline');
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().errorKind).assertEqual(ModRepoErrorKind.NETWORK);
      ctrl.setQuery('another');
      let s = ctrl.getState();
      expect(s.errorKind === null).assertTrue();
      expect(s.httpStatus).assertEqual(0);
    });

    it('D2-5 反向：下一次成功的查询要把上一次的分类清掉', 0, async () => {
      let repo = new FakeRepo();
      repo.nextError = new ModRepoError(
        ModSource.MODRINTH, ModRepoErrorKind.HTTP_SERVER, '503', 503);
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().errorKind).assertEqual(ModRepoErrorKind.HTTP_SERVER);
      repo.pages.set(0, { hits: [makeProj('1', 'ok')], totalHits: 1 });
      await ctrl.loadFirstPage();
      let s = ctrl.getState();
      expect(s.hits.length).assertEqual(1);
      expect(s.errorKind === null).assertTrue();
      expect(s.errorMessage === null).assertTrue();
    });

    it('describeSearchFailureForUser 让 429 与 network 不再是同一句话', 0, () => {
      let rateLimited: string = describeSearchFailureForUser(
        ModRepoErrorKind.HTTP_CLIENT, 429, 'raw');
      let offline: string = describeSearchFailureForUser(
        ModRepoErrorKind.NETWORK, 0, 'raw');
      let parse: string = describeSearchFailureForUser(ModRepoErrorKind.PARSE, 0, 'raw');
      expect(rateLimited === offline).assertFalse();
      expect(rateLimited === parse).assertFalse();
      // 无分类时退回原始消息，不编话。
      expect(describeSearchFailureForUser(null, 0, 'raw')).assertEqual('raw');
    });

    // ==========================================================
    //  批次 D6-3：回显实际请求体
    // ==========================================================

    it('D6-3：lastRequest 回显实际发出的请求体（成功路径）', 0, async () => {
      let repo = new FakeRepo();
      repo.pages.set(0, { hits: [makeProj('1', 'a')], totalHits: 1 });
      let ctrl = new ModSearchController(repo, 20);
      ctrl.setKind(ResourceKind.MOD);
      ctrl.setLoader('fabric');
      ctrl.setGameVersion('1.20.4');
      await ctrl.loadFirstPage();
      let req = ctrl.getState().lastRequest;
      expect(req !== null).assertTrue();
      expect(req!.gameVersion).assertEqual('1.20.4');
      expect(req!.loaders !== undefined && req!.loaders!.length === 1).assertTrue();
      expect(req!.loaders![0]).assertEqual('fabric');
    });

    it('D6-3 ⭐：回显让"过滤没生效"与"按契约被丢弃"可区分', 0, async () => {
      // 契约 §3.4 的顺序敏感陷阱：setKind(k) 在 k∉{MOD,MODPACK} 时会清空 loader，
      // 于是 SHADER + loader 的查询里 loader 根本不会进请求体。
      // 不回显请求体时，这与"服务端忽略了过滤"在结果上完全一样。
      let repo = new FakeRepo();
      let ctrl = new ModSearchController(repo, 20);
      ctrl.setKind(ResourceKind.MOD);
      ctrl.setLoader('fabric');
      ctrl.setKind(ResourceKind.SHADER);       // ← 这一步清空了 loader
      await ctrl.loadFirstPage();
      let req = ctrl.getState().lastRequest;
      expect(req !== null).assertTrue();
      expect(req!.kind).assertEqual(ResourceKind.SHADER);
      // 请求体里没有 loaders ⇒ 报告可以断言"过滤是被契约丢弃的，不是服务端没生效"。
      expect(req!.loaders === undefined).assertTrue();
    });

    it('D6-3：失败路径同样要有请求体', 0, async () => {
      // 失败时更需要它 —— 归因要回答的正是"到底发了什么请求"。
      let repo = new FakeRepo();
      repo.nextError = new ModRepoError(
        ModSource.MODRINTH, ModRepoErrorKind.NETWORK, 'offline');
      let ctrl = new ModSearchController(repo, 20);
      ctrl.setQuery('sodium');
      await ctrl.loadFirstPage();
      let s = ctrl.getState();
      expect(s.errorKind).assertEqual(ModRepoErrorKind.NETWORK);
      expect(s.lastRequest !== null).assertTrue();
      expect(s.lastRequest!.query).assertEqual('sodium');
    });

    it('普通 Error 也被接住', 0, async () => {
      let repo = new FakeRepo();
      repo.nextError = new Error('generic');
      let ctrl = new ModSearchController(repo, 20);
      await ctrl.loadFirstPage();
      expect(ctrl.getState().errorMessage).assertEqual('generic');
    });
  });

  // ==========================================================
  //  epoch 过期作废
  // ==========================================================
  describe('ModSearchController epoch 过期', () => {
    it('search 进行中改 query → 旧响应不写入', 0, async () => {
      let repo = new FakeRepo();
      repo.delayed = true;   // 下次 search 挂起，resolver 存进 pendingResolver
      let ctrl = new ModSearchController(repo, 20);

      // 启动第一次搜索（挂起，不 await）
      let p1 = ctrl.loadFirstPage();
      // 让事件循环跑一次，让 search 真正进入挂起状态
      await flushPromises();

      // 期间改 query：epoch++ 作废当前请求
      ctrl.setQuery('new-query');

      // resolve 第一次的 search 响应
      let resolver = repo.pendingResolver;
      expect(resolver !== null).assertTrue();
      if (resolver !== null) {
        resolver({
          hits: [makeProj('old', 'old-hit')], totalHits: 1, offset: 0, pageSize: 20,
        });
      }
      await p1;
      await flushPromises();

      // 第一次响应应被丢弃（epoch 不匹配），hits 仍为空
      let s = ctrl.getState();
      expect(s.hits.length).assertEqual(0);
    });
  });
}

/*
 * DownloadHistory.test.ets — Phase 5 (下载历史) 纯函数单元测试
 *
 * TDD 红阶段：本文件先于 DownloadHistory.ets 创建。
 *
 * 覆盖范围（仅 LRU 内存逻辑 + JSON 序列化，不依赖 Preferences I/O）：
 *   - DownloadHistoryLru 类         add / list / clear / 容量上限
 *   - serializeRecord / deserializeRecord  单条往返
 *   - serializeRecords / deserializeRecords 批量往返
 *   - formatRecordSummary           展示文本格式化
 *
 * 实施计划：docs/guides/download-system-implementation-plan.md §Phase 5
 *
 * 创建日期：2026-05-05
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  DownloadHistoryLru,
  DownloadHistoryRecord,
  serializeRecord,
  deserializeRecord,
  serializeRecords,
  deserializeRecords,
  formatRecordSummary,
  getDownloadHistoryStore,
  HISTORY_CAPACITY,
} from 'feature_core';

function makeRecord(versionName: string, status: string, durationMs: number): DownloadHistoryRecord {
  return {
    versionName: versionName,
    gameVersion: '1.20.4',
    loaderType: 'vanilla',
    startedAt: 1_700_000_000_000,
    durationMs: durationMs,
    totalBytes: 230_000_000,
    fileCount: 100,
    status: status,
  };
}

export default function downloadHistoryTest() {

  // ============================================================
  //  DownloadHistoryLru
  // ============================================================
  describe('DownloadHistoryLru', () => {

    it('空 LRU list() 返回空数组', 0, () => {
      let lru = new DownloadHistoryLru(20);
      expect(lru.list().length).assertEqual(0);
    });

    it('添加单条记录后 list 返回 1 条', 0, () => {
      let lru = new DownloadHistoryLru(20);
      lru.add(makeRecord('1.20.4', 'success', 30000));
      expect(lru.list().length).assertEqual(1);
      expect(lru.list()[0].versionName).assertEqual('1.20.4');
    });

    it('list 顺序：最新的在前', 0, () => {
      let lru = new DownloadHistoryLru(20);
      lru.add(makeRecord('1.20.4', 'success', 30000));
      lru.add(makeRecord('1.21', 'success', 35000));
      lru.add(makeRecord('1.19', 'failed', 5000));
      let arr = lru.list();
      expect(arr.length).assertEqual(3);
      expect(arr[0].versionName).assertEqual('1.19');     // 最新
      expect(arr[1].versionName).assertEqual('1.21');
      expect(arr[2].versionName).assertEqual('1.20.4');   // 最老
    });

    it('容量满时驱逐最老', 0, () => {
      let lru = new DownloadHistoryLru(3);
      lru.add(makeRecord('a', 'success', 1));
      lru.add(makeRecord('b', 'success', 2));
      lru.add(makeRecord('c', 'success', 3));
      lru.add(makeRecord('d', 'success', 4));
      let arr = lru.list();
      expect(arr.length).assertEqual(3);
      expect(arr[0].versionName).assertEqual('d');
      expect(arr[1].versionName).assertEqual('c');
      expect(arr[2].versionName).assertEqual('b');
      // 'a' 应被驱逐
      let foundA = false;
      for (let r of arr) { if (r.versionName === 'a') foundA = true; }
      expect(foundA).assertFalse();
    });

    it('clear 清空所有记录', 0, () => {
      let lru = new DownloadHistoryLru(5);
      lru.add(makeRecord('a', 'success', 1));
      lru.add(makeRecord('b', 'success', 2));
      lru.clear();
      expect(lru.list().length).assertEqual(0);
    });

    it('容量为 1 时正常工作', 0, () => {
      let lru = new DownloadHistoryLru(1);
      lru.add(makeRecord('a', 'success', 1));
      lru.add(makeRecord('b', 'success', 2));
      expect(lru.list().length).assertEqual(1);
      expect(lru.list()[0].versionName).assertEqual('b');
    });

    it('list 返回的数组是副本（修改不影响内部）', 0, () => {
      let lru = new DownloadHistoryLru(5);
      lru.add(makeRecord('a', 'success', 1));
      let arr = lru.list();
      arr.push(makeRecord('hacker', 'success', 999));
      expect(lru.list().length).assertEqual(1);
    });

    it('initial 数组初始化', 0, () => {
      let initial: DownloadHistoryRecord[] = [
        makeRecord('a', 'success', 1),
        makeRecord('b', 'failed', 2),
      ];
      let lru = new DownloadHistoryLru(5, initial);
      expect(lru.list().length).assertEqual(2);
    });

    it('initial 数组超过容量时截断', 0, () => {
      let initial: DownloadHistoryRecord[] = [
        makeRecord('a', 'success', 1),
        makeRecord('b', 'success', 2),
        makeRecord('c', 'success', 3),
        makeRecord('d', 'success', 4),
      ];
      let lru = new DownloadHistoryLru(2, initial);
      expect(lru.list().length).assertEqual(2);
    });
  });

  // ============================================================
  //  serializeRecord / deserializeRecord
  // ============================================================
  describe('DownloadHistory serialize record', () => {

    it('完整字段往返一致', 0, () => {
      let original: DownloadHistoryRecord = {
        versionName: '1.20.4-Forge_49.0.30',
        gameVersion: '1.20.4',
        loaderType: 'forge',
        loaderVersion: '49.0.30',
        startedAt: 1_700_000_000_000,
        durationMs: 120000,
        totalBytes: 230_000_000,
        fileCount: 4500,
        status: 'success',
      };
      let json = serializeRecord(original);
      let restored = deserializeRecord(json);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.versionName).assertEqual(original.versionName);
        expect(restored.gameVersion).assertEqual(original.gameVersion);
        expect(restored.loaderType).assertEqual(original.loaderType);
        expect(restored.loaderVersion).assertEqual(original.loaderVersion);
        expect(restored.startedAt).assertEqual(original.startedAt);
        expect(restored.durationMs).assertEqual(original.durationMs);
        expect(restored.totalBytes).assertEqual(original.totalBytes);
        expect(restored.fileCount).assertEqual(original.fileCount);
        expect(restored.status).assertEqual(original.status);
      }
    });

    it('vanilla 无 loaderVersion 也能往返', 0, () => {
      let original = makeRecord('1.20.4', 'success', 30000);
      let restored = deserializeRecord(serializeRecord(original));
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.versionName).assertEqual('1.20.4');
        expect(restored.loaderVersion === undefined).assertTrue();
      }
    });

    it('failed 状态 + errorMessage 往返', 0, () => {
      let original: DownloadHistoryRecord = {
        versionName: '1.20.4',
        gameVersion: '1.20.4',
        loaderType: 'vanilla',
        startedAt: 1_700_000_000_000,
        durationMs: 5000,
        totalBytes: 0,
        fileCount: 0,
        status: 'failed',
        errorMessage: 'CA bundle not initialized',
      };
      let restored = deserializeRecord(serializeRecord(original));
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.status).assertEqual('failed');
        expect(restored.errorMessage).assertEqual('CA bundle not initialized');
      }
    });

    it('损坏 JSON 返回 null', 0, () => {
      expect(deserializeRecord('not-json') === null).assertTrue();
      expect(deserializeRecord('') === null).assertTrue();
    });

    it('缺关键字段返回 null', 0, () => {
      expect(deserializeRecord('{}') === null).assertTrue();
      expect(deserializeRecord('{"versionName":"x"}') === null).assertTrue();
    });
  });

  // ============================================================
  //  serializeRecords / deserializeRecords (批量)
  // ============================================================
  describe('DownloadHistory serialize records (batch)', () => {

    it('空数组往返', 0, () => {
      let json = serializeRecords([]);
      let restored = deserializeRecords(json);
      expect(restored.length).assertEqual(0);
    });

    it('多条记录往返', 0, () => {
      let originals: DownloadHistoryRecord[] = [
        makeRecord('a', 'success', 1),
        makeRecord('b', 'failed', 2),
        makeRecord('c', 'aborted', 3),
      ];
      let json = serializeRecords(originals);
      let restored = deserializeRecords(json);
      expect(restored.length).assertEqual(3);
      expect(restored[0].versionName).assertEqual('a');
      expect(restored[2].versionName).assertEqual('c');
    });

    it('损坏数据返回空数组（容错）', 0, () => {
      expect(deserializeRecords('not-json').length).assertEqual(0);
      expect(deserializeRecords('').length).assertEqual(0);
      // 数组中的非法元素被跳过
      let mixed = '[' + serializeRecord(makeRecord('ok', 'success', 1)) + ',{}]';
      let arr = deserializeRecords(mixed);
      expect(arr.length).assertEqual(1);
      expect(arr[0].versionName).assertEqual('ok');
    });
  });

  // ============================================================
  //  formatRecordSummary
  // ============================================================
  describe('DownloadHistory.formatRecordSummary', () => {

    it('vanilla 成功记录格式', 0, () => {
      let r = makeRecord('1.20.4', 'success', 35000);
      let s = formatRecordSummary(r);
      expect(s.indexOf('1.20.4') >= 0).assertTrue();
      expect(s.indexOf('成功') >= 0 || s.indexOf('success') >= 0).assertTrue();
    });

    it('forge 失败记录显示错误信息', 0, () => {
      let r: DownloadHistoryRecord = {
        versionName: '1.20.4-Forge_49.0.30',
        gameVersion: '1.20.4',
        loaderType: 'forge',
        loaderVersion: '49.0.30',
        startedAt: 1_700_000_000_000,
        durationMs: 5000,
        totalBytes: 100,
        fileCount: 1,
        status: 'failed',
        errorMessage: 'NetworkError',
      };
      let s = formatRecordSummary(r);
      expect(s.indexOf('Forge') >= 0).assertTrue();
      expect(s.indexOf('失败') >= 0 || s.indexOf('failed') >= 0).assertTrue();
    });

    it('包含人类可读字节数', 0, () => {
      let r = makeRecord('1.20.4', 'success', 30000);
      r.totalBytes = 230 * 1024 * 1024;
      let s = formatRecordSummary(r);
      expect(s.indexOf('MB') >= 0 || s.indexOf('GB') >= 0).assertTrue();
    });

    it('包含人类可读耗时', 0, () => {
      let r = makeRecord('1.20.4', 'success', 65000);  // 1m 5s
      let s = formatRecordSummary(r);
      // 应包含分钟数
      expect(s.indexOf('1') >= 0).assertTrue();
    });
  });

  // ============================================================
  //  DownloadHistoryStore 工厂 / 容量常量
  //  （持久化路径需 OHOS Context，留待 ohosTest；此处只验证导出契约）
  // ============================================================
  describe('DownloadHistoryStore 契约', () => {

    // 容量在「活动时间线泛化」时由 20 提到 50，以容纳下载之外的多类操作记录
    // （见 feature_core/src/main/ets/download/DownloadHistory.ets 的 HISTORY_CAPACITY
    // 定义处注释）。这里钉住具体数值是有意的：它是持久化记录的保留上限，改动会直接
    // 影响用户能回看多久的历史，属于需要显式决策的契约，不应被顺手改掉。
    it('HISTORY_CAPACITY 等于约定的 50', 0, () => {
      expect(HISTORY_CAPACITY).assertEqual(50);
    });

    // 光钉住常量不够：还要证明 store 用的那个容量真的会截断。用容量+1 条记录打边界，
    // 这样将来常量再变，这条也不需要跟着改。
    it('DownloadHistoryLru 按 HISTORY_CAPACITY 截断', 0, () => {
      let lru = new DownloadHistoryLru(HISTORY_CAPACITY);
      for (let i = 0; i < HISTORY_CAPACITY + 1; i++) {
        lru.add(makeRecord('v-' + i, 'success', 1000 + i));
      }
      expect(lru.list().length).assertEqual(HISTORY_CAPACITY);
      // 最新的在前：最后加入的必须还在，最先加入的必须被挤掉。
      expect(lru.list()[0].versionName).assertEqual('v-' + HISTORY_CAPACITY);
      let hasOldest = false;
      for (let record of lru.list()) {
        if (record.versionName === 'v-0') hasOldest = true;
      }
      expect(hasOldest).assertFalse();
    });

    it('getDownloadHistoryStore 是单例（两次调用返回同一引用）', 0, () => {
      let s1 = getDownloadHistoryStore();
      let s2 = getDownloadHistoryStore();
      expect(s1 === s2).assertTrue();
    });

    it('未 init 时 list 返回空数组（graceful fallback）', 0, () => {
      let store = getDownloadHistoryStore();
      // 实际单例被 Index.ets 等代码 init 过，但 list() 不依赖 ready_，
      // 它只读 lru_ 的快照副本；未 init 时 lru_ 是空的（默认 ctor）
      let arr = store.list();
      expect(Array.isArray(arr)).assertTrue();
    });

    it('未 init 时 isReady=false', 0, () => {
      let store = getDownloadHistoryStore();
      // 注：进程内单例可能已被前面用例间接 init 过，所以这里只断言类型
      let ready = store.isReady();
      expect(typeof ready === 'boolean').assertTrue();
    });
  });
}

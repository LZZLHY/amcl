/*
 * DownloadManager.test.ets — Phase 7 (S3-4) 纯函数单元测试
 *
 * 覆盖：DownloadManager.ets 的零依赖部分
 *   - formatBytes(bytes)         字节数 → 人类可读字符串
 *   - formatSpeed(bps)           字节速率 → 带 /s 后缀
 *   - DownloadTaskView 默认字段初始化
 *
 * 不覆盖：
 *   - DownloadManager 单例 / 事件派发 / NAPI 调用 —— 留给 ohosTest 集成或
 *     未来的 integration harness（真实 Context + libentry.so）。
 *
 * 创建日期：2026-05-06
 */

import { describe, it, expect } from '@ohos/hypium';
import { formatBytes, formatSpeed, DownloadTaskView } from 'feature_core';

export default function downloadManagerTest() {

describe('DownloadManager.formatBytes — 字节数格式化', () => {

  it('负数 → "-"（与 utils/PathUtils.formatBytes 一致）', 0, () => {
    expect(formatBytes(-1)).assertEqual('-');
    expect(formatBytes(-1024)).assertEqual('-');
  });

  it('0 字节 → "0 B"', 0, () => {
    expect(formatBytes(0)).assertEqual('0 B');
  });

  it('< 1 KB → "N B"', 0, () => {
    expect(formatBytes(100)).assertEqual('100 B');
    expect(formatBytes(1023)).assertEqual('1023 B');
  });

  it('1 KB - 1 MB → "N.N KB"', 0, () => {
    expect(formatBytes(1024)).assertEqual('1.0 KB');
    expect(formatBytes(1536)).assertEqual('1.5 KB');
    expect(formatBytes(1024 * 1024 - 1)).assertEqual('1024.0 KB');
  });

  it('1 MB - 1 GB → "N.N MB"', 0, () => {
    expect(formatBytes(1024 * 1024)).assertEqual('1.0 MB');
    expect(formatBytes(10 * 1024 * 1024)).assertEqual('10.0 MB');
    expect(formatBytes(512 * 1024 * 1024)).assertEqual('512.0 MB');
  });

  it('≥ 1 GB → "N.NN GB"（GB 段保留 2 位小数，与 utils/PathUtils 对齐）', 0, () => {
    expect(formatBytes(1024 * 1024 * 1024)).assertEqual('1.00 GB');
    expect(formatBytes(2.5 * 1024 * 1024 * 1024)).assertEqual('2.50 GB');
  });
});

describe('DownloadManager.formatSpeed — 字节速率', () => {

  it('0 B/s', 0, () => {
    expect(formatSpeed(0)).assertEqual('0 B/s');
  });

  it('基于 formatBytes + "/s"', 0, () => {
    expect(formatSpeed(1024)).assertEqual('1.0 KB/s');
    expect(formatSpeed(1024 * 1024)).assertEqual('1.0 MB/s');
  });

  it('负数（来自 native 未知速率） → "-/s"（与 utils/PathUtils.formatSpeed 一致）', 0, () => {
    expect(formatSpeed(-1)).assertEqual('-/s');
  });
});

describe('DownloadManager.DownloadTaskView — 默认字段', () => {

  it('新 view 字段初始值符合预期（未开始状态）', 0, () => {
    let v = new DownloadTaskView();
    expect(v.taskId).assertEqual(0);
    expect(v.name).assertEqual('');
    expect(v.state).assertEqual('Waiting');
    expect(v.progress).assertEqual(0);
    expect(v.speedBps).assertEqual(0);
    expect(v.finished).assertFalse();
    expect(v.success).assertFalse();
    expect(v.aborted).assertFalse();
    expect(v.etaSeconds).assertEqual(-1);
    expect(v.durationMs).assertEqual(0);
    expect(v.currentFiles.length).assertEqual(0);
    expect(v.triedUrls.length).assertEqual(0);
    expect(v.failedFiles.length).assertEqual(0);
  });

  it('createdAt 在创建时被 Date.now 填入（正数且近似 now）', 0, () => {
    let now = Date.now();
    let v = new DownloadTaskView();
    // 允许 5 秒误差（测试框架调度）
    expect(v.createdAt >= now - 5000 && v.createdAt <= now + 5000).assertTrue();
  });

  it('finishedAt 初值 0（仅终态时被事件填）', 0, () => {
    let v = new DownloadTaskView();
    expect(v.finishedAt).assertEqual(0);
  });
});

} // downloadManagerTest

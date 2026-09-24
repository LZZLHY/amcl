/*
 * PathUtils.test.ets — PathUtils 通用格式化函数单元测试
 *
 * 覆盖范围（全部为纯函数）：
 *   - basename        路径 → 文件名
 *   - formatBytes     字节数 → 人类可读
 *   - formatSpeed     字节/秒 → 人类可读（带 /s）
 *   - formatEta       剩余秒数 → 可读时长
 *   - formatDurationMs 耗时毫秒 → m:ss / h:mm:ss
 *   - formatPercent   0~1 进度 → 百分比串
 *
 * 新增日期：2026-05-04
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  basename,
  formatBytes,
  formatSpeed,
  formatEta,
  formatDurationMs,
  formatPercent,
} from 'commons';

export default function pathUtilsTest() {
  describe('PathUtils', () => {

    // ============================================================
    //  basename
    // ============================================================

    it('basename: Unix 风格路径', 0, () => {
      expect(basename('/data/storage/el2/base/files/jdk/17/bin/java')).assertEqual('java');
    });

    it('basename: Windows 风格路径', 0, () => {
      expect(basename('C:\\Users\\dhao\\AppData\\amcl\\log.txt')).assertEqual('log.txt');
    });

    it('basename: 无分隔符的纯文件名', 0, () => {
      expect(basename('plain-file.jar')).assertEqual('plain-file.jar');
    });

    it('basename: 空字符串返回空串', 0, () => {
      expect(basename('')).assertEqual('');
    });

    it('basename: 末尾带斜杠的路径返回空串', 0, () => {
      expect(basename('/data/storage/')).assertEqual('');
    });

    // ============================================================
    //  formatBytes
    // ============================================================

    it('formatBytes: < 1024 显示 B', 0, () => {
      expect(formatBytes(0)).assertEqual('0 B');
      expect(formatBytes(1)).assertEqual('1 B');
      expect(formatBytes(512)).assertEqual('512 B');
      expect(formatBytes(1023)).assertEqual('1023 B');
    });

    it('formatBytes: KB 段保留 1 位小数', 0, () => {
      expect(formatBytes(1024)).assertEqual('1.0 KB');
      expect(formatBytes(1536)).assertEqual('1.5 KB');
      expect(formatBytes(1024 * 1023)).assertEqual('1023.0 KB');
    });

    it('formatBytes: MB 段保留 1 位小数', 0, () => {
      expect(formatBytes(1024 * 1024)).assertEqual('1.0 MB');
      expect(formatBytes(1024 * 1024 * 100)).assertEqual('100.0 MB');
    });

    it('formatBytes: GB 段保留 2 位小数', 0, () => {
      expect(formatBytes(1024 * 1024 * 1024)).assertEqual('1.00 GB');
    });

    it('formatBytes: 负值返回 "-"', 0, () => {
      expect(formatBytes(-1)).assertEqual('-');
      expect(formatBytes(-100)).assertEqual('-');
    });

    // ============================================================
    //  formatSpeed
    // ============================================================

    it('formatSpeed: 在 formatBytes 基础上追加 /s', 0, () => {
      expect(formatSpeed(0)).assertEqual('0 B/s');
      expect(formatSpeed(1024)).assertEqual('1.0 KB/s');
      expect(formatSpeed(1024 * 1024)).assertEqual('1.0 MB/s');
    });

    // ============================================================
    //  formatEta
    // ============================================================

    it('formatEta: < 60 秒', 0, () => {
      expect(formatEta(5)).assertEqual('5 秒');
      expect(formatEta(59)).assertEqual('59 秒');
    });

    it('formatEta: 分钟 + 秒，整分钟省略秒', 0, () => {
      expect(formatEta(60)).assertEqual('1 分');
      expect(formatEta(83)).assertEqual('1 分 23 秒');
      expect(formatEta(120)).assertEqual('2 分');
      expect(formatEta(3599)).assertEqual('59 分 59 秒');
    });

    it('formatEta: 小时 + 分，整小时省略分', 0, () => {
      expect(formatEta(3600)).assertEqual('1 小时');
      expect(formatEta(3660)).assertEqual('1 小时 1 分');
      expect(formatEta(7200)).assertEqual('2 小时');
    });

    it('formatEta: 负值返回空串（UI 隐藏）', 0, () => {
      expect(formatEta(-1)).assertEqual('');
      expect(formatEta(-60)).assertEqual('');
    });

    // ============================================================
    //  formatDurationMs
    // ============================================================

    it('formatDurationMs: 分:秒 格式', 0, () => {
      expect(formatDurationMs(0)).assertEqual('0:00');
      expect(formatDurationMs(35000)).assertEqual('0:35');
      expect(formatDurationMs(83000)).assertEqual('1:23');
      expect(formatDurationMs(600000)).assertEqual('10:00');
    });

    it('formatDurationMs: 小时:分:秒 格式', 0, () => {
      expect(formatDurationMs(3600000)).assertEqual('1:00:00');
      expect(formatDurationMs(3735000)).assertEqual('1:02:15');
    });

    it('formatDurationMs: 负值返回空串', 0, () => {
      expect(formatDurationMs(-1)).assertEqual('');
    });

    // ============================================================
    //  formatPercent
    // ============================================================

    it('formatPercent: ≥ 10% 取整', 0, () => {
      expect(formatPercent(0.1)).assertEqual('10%');
      expect(formatPercent(0.5)).assertEqual('50%');
      expect(formatPercent(1.0)).assertEqual('100%');
    });

    it('formatPercent: < 10% 保留 1 位小数', 0, () => {
      expect(formatPercent(0.005)).assertEqual('0.5%');
      expect(formatPercent(0.09)).assertEqual('9.0%');
    });

    it('formatPercent: 0 或负值返回 0%', 0, () => {
      expect(formatPercent(0)).assertEqual('0%');
      expect(formatPercent(-0.1)).assertEqual('0%');
    });

    it('formatPercent: NaN / Infinity 返回 0%', 0, () => {
      expect(formatPercent(NaN)).assertEqual('0%');
      expect(formatPercent(Infinity)).assertEqual('0%');
    });
  });
}

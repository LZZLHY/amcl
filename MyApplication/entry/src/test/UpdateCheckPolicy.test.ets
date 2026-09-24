import { describe, it, expect } from '@ohos/hypium';
import { UpdateChecker } from 'update';

const HOUR_MS: number = 60 * 60 * 1000;
const DAY_MS: number = 24 * HOUR_MS;
const NOW_MS: number = 2_000_000_000;

export default function updateCheckPolicyTest(): void {
  describe('UpdateChecker auto-check throttle and reminder policy', () => {
    it('从未检查过时自动联网', 0, () => {
      expect(UpdateChecker.shouldRunAutoCheck(NOW_MS, 0, 0, false)).assertTrue();
    });

    it('成功检查后 24h 内不重复联网', 0, () => {
      expect(UpdateChecker.shouldRunAutoCheck(NOW_MS, NOW_MS - HOUR_MS, 0, false)).assertFalse();
    });

    it('距上次检查恰满 24h 时重新联网', 0, () => {
      expect(UpdateChecker.shouldRunAutoCheck(NOW_MS, NOW_MS - DAY_MS, 0, false)).assertTrue();
    });

    it('点击稍后后红点已知但 24h 内不联网也不弹窗', 0, () => {
      let deferredAt: number = NOW_MS - HOUR_MS;
      expect(UpdateChecker.hasCachedUpdate(100, 101)).assertTrue();
      expect(UpdateChecker.shouldRunAutoCheck(NOW_MS, NOW_MS - DAY_MS, deferredAt, true)).assertFalse();
      expect(UpdateChecker.shouldShowAutoPrompt(NOW_MS, deferredAt)).assertFalse();
    });

    it('稍后恰满 24h 时强制刷新并允许再次弹窗', 0, () => {
      let deferredAt: number = NOW_MS - DAY_MS;
      expect(UpdateChecker.shouldRunAutoCheck(NOW_MS, NOW_MS - HOUR_MS, deferredAt, true)).assertTrue();
      expect(UpdateChecker.shouldShowAutoPrompt(NOW_MS, deferredAt)).assertTrue();
    });

    it('没有缓存更新时忽略遗留稍后时间，只按检查时间节流', 0, () => {
      let deferredAt: number = NOW_MS - HOUR_MS;
      expect(UpdateChecker.shouldRunAutoCheck(NOW_MS, NOW_MS - HOUR_MS, deferredAt, false)).assertFalse();
    });

    it('系统时间回拨不会把检查或弹窗永久压制', 0, () => {
      let futureAt: number = NOW_MS + HOUR_MS;
      expect(UpdateChecker.shouldRunAutoCheck(NOW_MS, futureAt, futureAt, true)).assertTrue();
      expect(UpdateChecker.shouldShowAutoPrompt(NOW_MS, futureAt)).assertTrue();
    });
  });
}

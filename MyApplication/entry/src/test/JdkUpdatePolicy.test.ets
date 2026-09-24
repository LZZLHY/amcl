/**
 * JdkUpdatePolicy.test.ets — 已装 JDK 与期望版本的关系判定
 *
 * ⭐ 这份测试存在的直接原因：这条判定的失效形态**是静默的**，两个方向都不报错 ——
 *   往严了坏 ⇒ 所有 tag 变更又变回「判定未安装 + 拒绝启动 + 强制重下 110 MB」；
 *   往松了坏 ⇒ 已知有害的旧包（如 JDK 8 那个 C2 会崩的 `-ohos-1`）永远不被强制换掉。
 * 门禁全绿、日志无告警，只有真机上的用户会吃到，所以必须钉在离线测试里。
 *
 * 判定本身的取舍与「harmfulTags 不许滥用」的理由写在
 * `launch/src/main/ets/JdkUpdatePolicy.ets` 的文件开头，这里只钉行为。
 *
 * 创建日期：2026-08-29
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  JdkTagState, JdkTagInput, IMPORTED_TAG_PREFIX,
  classifyJdkTag, isUsableState, shouldOfferUpdate, describeJdkTagState,
} from 'launch';

/** 造判定入参。默认没有有害 tag（这也是生产默认）。 */
function input(installedTag: string, expectedTag: string, harmful: string[] = []): JdkTagInput {
  return { installedTag, expectedTag, harmfulTags: harmful };
}

export default function jdkUpdatePolicyTest() {
  describe('JdkUpdatePolicy', () => {

    // ---------- 基本四态 ----------

    it('戳与期望一致 ⇒ current，可用、不提示更新', 0, () => {
      const st: JdkTagState = classifyJdkTag(input('v25.0.4-ohos-1', 'v25.0.4-ohos-1'));
      expect(st).assertEqual('current');
      expect(isUsableState(st)).assertTrue();
      expect(shouldOfferUpdate(st)).assertFalse();
    });

    it('戳不同且不在 harmfulTags ⇒ stale-advisory：**仍可用**且提示更新', 0, () => {
      const st: JdkTagState = classifyJdkTag(input('v25.0.4-ohos-1', 'v25.0.4-ohos-2'));
      expect(st).assertEqual('stale-advisory');
      // 这两条断言是本文件的核心：有更新 ≠ 不能用。
      expect(isUsableState(st)).assertTrue();
      expect(shouldOfferUpdate(st)).assertTrue();
    });

    it('戳在 harmfulTags 里 ⇒ stale-blocking：不可用（保留强制重下）', 0, () => {
      const st: JdkTagState = classifyJdkTag(
        input('v8u452-ohos-1', 'v8u452-ohos-3', ['v8u452-ohos-1']));
      expect(st).assertEqual('stale-blocking');
      expect(isUsableState(st)).assertFalse();
      expect(shouldOfferUpdate(st)).assertTrue();
    });

    it('无戳 ⇒ unstamped：容忍为可用，不强制 churn', 0, () => {
      const st: JdkTagState = classifyJdkTag(input('', 'v25.0.4-ohos-2'));
      expect(st).assertEqual('unstamped');
      expect(isUsableState(st)).assertTrue();
      expect(shouldOfferUpdate(st)).assertFalse();
    });

    // ---------- 用户导入 ----------

    it('导入包的戳 ⇒ user-import：可用，且**永不**提示更新', 0, () => {
      const st: JdkTagState = classifyJdkTag(
        input(IMPORTED_TAG_PREFIX + 'a1b2c3d4e5f6', 'v25.0.4-ohos-2'));
      expect(st).assertEqual('user-import');
      expect(isUsableState(st)).assertTrue();
      // 用户自己塞的包，我们不知道它是什么，提示"更新"会把它覆盖掉 —— 那是数据破坏。
      expect(shouldOfferUpdate(st)).assertFalse();
    });

    it('导入包即使恰好被列进 harmfulTags 也不判 blocking（前缀优先）', 0, () => {
      const tag = IMPORTED_TAG_PREFIX + 'deadbeef0000';
      const st: JdkTagState = classifyJdkTag(input(tag, 'v25.0.4-ohos-2', [tag]));
      expect(st).assertEqual('user-import');
      expect(isUsableState(st)).assertTrue();
    });

    // ---------- 边界：期望值缺失时不许下结论 ----------

    it('expectedTag 为空 ⇒ current（不拿一个缺失的事实当结论）', 0, () => {
      const st: JdkTagState = classifyJdkTag(input('v25.0.4-ohos-1', ''));
      expect(st).assertEqual('current');
      expect(shouldOfferUpdate(st)).assertFalse();
    });

    it('两端都带空白 ⇒ 按 trim 后比较，不误判成过期', 0, () => {
      const st: JdkTagState = classifyJdkTag(input('  v21.0.5-ohos-6\n', 'v21.0.5-ohos-6  '));
      expect(st).assertEqual('current');
    });

    // ---------- 反向对照：harmfulTags 只对**已装的那个** tag 生效 ----------

    it('harmfulTags 里有别的 tag，不影响当前已装的判定', 0, () => {
      const st: JdkTagState = classifyJdkTag(
        input('v21.0.5-ohos-6', 'v21.0.5-ohos-7', ['v21.0.5-ohos-3', 'v21.0.5-ohos-4']));
      expect(st).assertEqual('stale-advisory');
      expect(isUsableState(st)).assertTrue();
    });

    it('把期望 tag 自己写进 harmfulTags 也不会让最新版变成不可用', 0, () => {
      // 防御一种手滑：维护者把新 tag 而不是旧 tag 填进了 harmfulTags。
      const st: JdkTagState = classifyJdkTag(
        input('v21.0.5-ohos-7', 'v21.0.5-ohos-7', ['v21.0.5-ohos-7']));
      expect(st).assertEqual('current');
      expect(isUsableState(st)).assertTrue();
    });

    // ---------- 文案：必须把两个 tag 都说出来 ----------

    it('说明文案带上「装的是什么 → 期望什么」（用户截这一行就能定位）', 0, () => {
      const inp = input('v25.0.4-ohos-1', 'v25.0.4-ohos-2');
      const text = describeJdkTagState(classifyJdkTag(inp), inp);
      expect(text.indexOf('v25.0.4-ohos-1') >= 0).assertTrue();
      expect(text.indexOf('v25.0.4-ohos-2') >= 0).assertTrue();
    });

    it('blocking 的文案要说清是「已知问题」而不是「未安装」（J-b 的教训）', 0, () => {
      const inp = input('v8u452-ohos-1', 'v8u452-ohos-3', ['v8u452-ohos-1']);
      const text = describeJdkTagState(classifyJdkTag(inp), inp);
      expect(text.indexOf('已知问题') >= 0).assertTrue();
      expect(text.indexOf('未安装') >= 0).assertFalse();
    });

    it('current 的文案不提更新', 0, () => {
      const inp = input('v25.0.4-ohos-2', 'v25.0.4-ohos-2');
      expect(describeJdkTagState(classifyJdkTag(inp), inp)).assertEqual('已是最新');
    });
  });
}

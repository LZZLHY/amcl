/*
 * LogExportBudget.test.ets — 导出配额分配与头尾截断（日志系统重构 · P5）
 *
 * ⭐ 这份测试钉的是调研 N-7：**上传出去的正文可能一行启动器日志都没有。**
 *
 * 旧做法是「把各 part 按固定顺序拼成一整段，再保尾截断」，而拼装顺序是
 *   环境头 → 活动摘要 → LAUNCHER → GAME → MC_LATEST → JVM → CRASH_REPORT → SYSTEM_CRASH
 * 且 GAME 段不传上限时读到 16 MB。⇒ 游戏日志一大，前面几段全部落在被丢掉的头部。
 * 而启动器日志正是「AMCL 自己做了什么决定」（classpath / JDK / 渲染后端）的唯一记录。
 *
 * 两条承重判据：
 *   1. **小而关键的段永远不被大段挤掉**（崩溃报告几 KB，信息密度比 16 MB 游戏日志高几个数量级）；
 *   2. **超配额的段保头 + 保尾**：启动期根因（类加载 / Mixin / 依赖冲突）在头部，
 *      失败现场在尾部，只保一端必丢一半（P1-4）。
 *
 * 失效形态是**静默的**：导出成功、内容看起来正常、只是少了最关键的那一段。
 * 没有这份测试，回归了也不会有人发现。
 *
 * 创建日期：2026-09-06
 */
import { describe, it, expect } from '@ohos/hypium';
import { allocateExportBudget, ExportPartDemand, ExportPartGrant,
  truncateUtf8HeadTail, truncateUtf8Tail, utf8ByteLength } from 'commons';

const KB: number = 1024;

/** 真实形状：游戏日志巨大，其余都很小。这正是 N-7 的触发条件。 */
function n7Demands(): ExportPartDemand[] {
  return [
    { id: 'LAUNCHER',     bytes: 300 * KB,   priority: 2, floorBytes: 48 * KB },
    { id: 'GAME',         bytes: 16000 * KB, priority: 3, floorBytes: 64 * KB },
    { id: 'MC_LATEST',    bytes: 800 * KB,   priority: 4, floorBytes: 16 * KB },
    { id: 'JVM',          bytes: 4 * KB,     priority: 5, floorBytes: 8 * KB },
    { id: 'CRASH_REPORT', bytes: 12 * KB,    priority: 1, floorBytes: 32 * KB },
  ];
}

function grantOf(gs: ExportPartGrant[], id: string): number {
  for (let i = 0; i < gs.length; i++) {
    if (gs[i].id === id) return gs[i].granted;
  }
  return -1;
}

export default function logExportBudgetTest() {
  describe('LogExportBudget', () => {

    // ── 承重：N-7 本体

    it('游戏日志巨大时，启动器日志仍然拿得到配额', 0, () => {
      // 240 KB 是上传 AMCL-web 的实际配额。
      const gs = allocateExportBudget(n7Demands(), 240 * KB);
      // 旧行为等价于「LAUNCHER 被整段丢掉」⇒ 这一条就是 N-7 的回归钉子。
      expect(grantOf(gs, 'LAUNCHER') >= 48 * KB).assertTrue();
    });

    it('崩溃报告很小但优先级最高，必须完整保留', 0, () => {
      const gs = allocateExportBudget(n7Demands(), 240 * KB);
      // 它只有 12 KB，低于 32 KB 保底 ⇒ 应当全给。
      expect(grantOf(gs, 'CRASH_REPORT')).assertEqual(12 * KB);
    });

    it('16 MB 的游戏日志不许吃掉全部预算', 0, () => {
      const gs = allocateExportBudget(n7Demands(), 240 * KB);
      expect(grantOf(gs, 'GAME') < 240 * KB).assertTrue();
    });

    it('分配总量不超预算', 0, () => {
      const gs = allocateExportBudget(n7Demands(), 240 * KB);
      let sum = 0;
      for (let i = 0; i < gs.length; i++) sum += gs[i].granted;
      expect(sum <= 240 * KB).assertTrue();
    });

    it('每一段都拿到了非零配额（没有段被静默丢掉）', 0, () => {
      const gs = allocateExportBudget(n7Demands(), 240 * KB);
      for (let i = 0; i < gs.length; i++) {
        expect(gs[i].granted > 0).assertTrue();
      }
    });

    // ── 基本性质

    it('装得下时全给，且不标记截断', 0, () => {
      const gs = allocateExportBudget(
        [{ id: 'A', bytes: 10, priority: 1, floorBytes: 5 },
         { id: 'B', bytes: 20, priority: 2, floorBytes: 5 }], 1000);
      expect(grantOf(gs, 'A')).assertEqual(10);
      expect(grantOf(gs, 'B')).assertEqual(20);
      expect(gs[0].truncated).assertFalse();
    });

    it('预算为 0 或负 ⇒ 视为不限', 0, () => {
      const gs = allocateExportBudget([{ id: 'A', bytes: 99, priority: 1, floorBytes: 1 }], 0);
      expect(grantOf(gs, 'A')).assertEqual(99);
    });

    it('返回顺序与传入顺序一致（拼装顺序 ≠ 优先级顺序）', 0, () => {
      const gs = allocateExportBudget(n7Demands(), 240 * KB);
      expect(gs[0].id).assertEqual('LAUNCHER');
      expect(gs[4].id).assertEqual('CRASH_REPORT');
    });

    it('预算极小时优先级决定谁活下来', 0, () => {
      const gs = allocateExportBudget(n7Demands(), 20 * KB);
      // CRASH_REPORT 优先级 1，应当先拿到
      expect(grantOf(gs, 'CRASH_REPORT') > 0).assertTrue();
    });

    it('空输入不炸', 0, () => {
      expect(allocateExportBudget([], 100).length).assertEqual(0);
    });

    // ── 头尾截断

    it('头尾截断同时保住开头与结尾', 0, () => {
      let lines: string[] = [];
      for (let i = 0; i < 2000; i++) lines.push('line-' + i + ' padding padding padding');
      const text = lines.join('\n');
      const out = truncateUtf8HeadTail(text, 4000);
      expect(out.indexOf('line-0 ') >= 0).assertTrue();
      expect(out.indexOf('line-1999 ') >= 0).assertTrue();
      expect(out.indexOf('中间省略') >= 0).assertTrue();
    });

    it('头尾截断的结果不超预算', 0, () => {
      let lines: string[] = [];
      for (let i = 0; i < 2000; i++) lines.push('line-' + i + ' padding padding padding');
      const out = truncateUtf8HeadTail(lines.join('\n'), 4000);
      expect(utf8ByteLength(out) <= 4000).assertTrue();
    });

    it('装得下时头尾截断原样返回', 0, () => {
      const s = 'short text';
      expect(truncateUtf8HeadTail(s, 1000)).assertEqual(s);
    });

    it('⭐ 对照：只保尾会丢掉开头 —— 这正是本批要修的那一半', 0, () => {
      let lines: string[] = [];
      for (let i = 0; i < 2000; i++) lines.push('line-' + i + ' padding padding padding');
      const text = lines.join('\n');
      const tailOnly = truncateUtf8Tail(text, 4000);
      // 旧策略：开头没了（启动期根因就在这里）
      expect(tailOnly.indexOf('line-0 ') < 0).assertTrue();
      // 新策略：两端都在
      expect(truncateUtf8HeadTail(text, 4000).indexOf('line-0 ') >= 0).assertTrue();
    });

    it('中文（3 字节/字符）不被切出半个字符', 0, () => {
      let s = '';
      for (let i = 0; i < 3000; i++) s += '日志';
      const out = truncateUtf8HeadTail(s, 900);
      expect(utf8ByteLength(out) <= 900).assertTrue();
      // 没有替换字符 / 半个码点
      expect(out.indexOf('\uFFFD') < 0).assertTrue();
    });
  });
}

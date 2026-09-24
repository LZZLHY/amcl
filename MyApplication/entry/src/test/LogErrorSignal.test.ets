/*
 * LogErrorSignal.test.ets — 「这一行算不算错误」的判据（日志系统重构 · 批次 A）
 *
 * ⭐ 这份测试存在的直接原因：**`1000591` 只发出去了半批。**
 *
 * 2026-09-05 的调研 §6.4 写明两件事必须同批做 —— 收缩帧遥测、扩噪声/收紧错误判据 ——
 * 否则「健康会话被判成 CRASHED」那族误报（`1000451`）会复活。`1000591` 关掉了
 * `AMCL_MG_FRAME_STATS`（前一半），后一半没做。
 *
 * 形式上 `1000591` 没有动尾窗，但判定链的输入不是「32 KB」这个数字，是**那 32 KB 里装着什么**：
 * 遥测在时，尾窗全部落在纯遥测里（14 条判据全 false，凑巧判对）；遥测不在时，同样的
 * 32 KB 会装进真实的 Minecraft 输出，包括调研 §6.3 那 7 行「剥完噪声仍被判成真实错误、
 * 但一行都不是错误」的行。推演见 docs/refactor/日志系统重构施工记录.md §S01.2。
 *
 * 三类判定在这里同等重要：
 *   - **正向**：那 7 行的每一族都不再让健康会话被判成崩溃；
 *   - **反向**（承重）：真实的启动失败**仍然**被判成有错误。本批是在收紧判定，
 *     而收紧的失效形态是**静默漏报** —— 用户看到「上次游戏已结束」，实际上启动失败了。
 *     反向用例坏掉不会抛异常、不会打告警；
 *   - **端到端**：不只测判据函数，还要测 `analyzeMcLog` + `shouldDiagnose` 合起来的结局，
 *     因为用户看到的是那个结局，不是某个布尔。
 *
 * ⚠️ 与 `scripts/check-log-noise-rules.mjs` 的分工：那道门禁在 Node 里跑同一批语料，
 * 用的是从 .ets 源码里抽出来的判据字面量（离线、提交前必然红）；本套跑的是**真实运行时**
 * （设备上跑）。两者都要有：门禁证明判据数据没漂，本套证明代码真的那么执行。
 *
 * 语料出处：调研 §6.3 逐行记录的措辞。⚠️ **不是原始样本的切片** ——
 * 原始样本 2026-09-06 复核时已不在原路径，无法重跑（施工记录 §S01.2）。
 *
 * 创建日期：2026-09-06
 */
import { describe, it, expect } from '@ohos/hypium';
import { hasErrorSignal, lineLooksLikeError, stripLogNoiseText, listLogNoiseRules } from 'commons';
import { SessionMarker, shouldDiagnose, McLogEvidence } from 'launch';

// ============================================================
//  语料
// ============================================================

/** 调研 §6.3 幸存行 1/5：可选模组没装，Mixin target 不存在。WARN 级。 */
const LINE_CONTROLIFY: string =
  '[04:02:29] [main/WARN]: Error loading class: dev/isxander/controlify/api/ControlifyApi '
  + '(java.lang.ClassNotFoundException: dev.isxander.controlify.api.ControlifyApi)';

/** 调研 §6.3 幸存行 3/5：7 行里**唯一**带 /ERROR] 的一条。 */
const LINE_XAERO_ERROR: string =
  '[04:02:36] [Render thread/ERROR]: io exception while checking versions: Online mod data expired!';

/** 调研 §6.3 幸存行 5/5：散文里的普通英文单词 "exceptions"。 */
const LINE_MG_PROSE: string =
  '[MG] multidrawMode is deprecated; see docs/multidraw.md for per-function exceptions.';

/** 帧遥测。出货包自 1000591 起不再产生，但用户手上 ≤1000590 的包仍在写。 */
const LINE_MG_FRAME: string =
  '[MG-FRAME-STATS] seq=105 fps=58.21 frame_ms=17.18 present_ms=2.03';

/**
 * 一局**健康**会话的尾部：玩家停在标题界面，随后被结束进程。
 * 既没有 Stopping! 也没有 Crash Report —— 这正是调研那份真实用户日志的形状。
 */
const TAIL_HEALTHY_SESSION: string =
  '[04:02:14] [main/INFO]: Loading Minecraft 26.2 with Fabric Loader 0.19.3\n'
  + '[04:02:20] [Render thread/INFO]: Created: 2048x2048x4 minecraft:textures/atlas/blocks.png-atlas\n'
  + LINE_CONTROLIFY + '\n'
  + '[04:02:33] [main/WARN]: io exception while checking patreon: Online mod data expired!\n'
  + LINE_XAERO_ERROR + '\n'
  + LINE_MG_PROSE + '\n'
  + LINE_MG_FRAME + '\n';

/** Fabric 在游戏起来之前就失败。级别单独成段，**没有**Java 异常顶行兜底。 */
const TAIL_FABRIC_FAILURE: string =
  '[12:39:44] [ERROR] [FabricLoader/GameProvider]: Minecraft game provider couldn\'t locate '
  + 'the game! The game may be absent from the class path.\n';

export default function logErrorSignalTest() {
  describe('LogErrorSignal', () => {

    // ── 正向：调研 §6.3 的幸存行不再算错误信号

    it('WARN 级的 Mixin target 缺失不算错误信号', 0, () => {
      // 旧判据 low.indexOf('exception') 会命中行内的 ClassNotFoundException。
      expect(lineLooksLikeError(LINE_CONTROLIFY)).assertFalse();
      expect(hasErrorSignal(LINE_CONTROLIFY)).assertFalse();
    });

    it('散文里的 "exceptions" 不算错误信号', 0, () => {
      expect(lineLooksLikeError(LINE_MG_PROSE)).assertFalse();
    });

    it('ERROR 级的联网数据过期靠噪声规则剥掉（级别判定救不了它）', 0, () => {
      // ⭐ 这一条要分两步看，顺序不能反：
      //   1. 它**确实**带级别标记 ⇒ 单看判据它就是错误信号；
      expect(lineLooksLikeError(LINE_XAERO_ERROR)).assertTrue();
      //   2. 所以只能靠噪声规则把它剥掉。
      expect(stripLogNoiseText(LINE_XAERO_ERROR).trim().length).assertEqual(0);
    });

    it('帧遥测被当噪声剥掉', 0, () => {
      expect(stripLogNoiseText(LINE_MG_FRAME).trim().length).assertEqual(0);
    });

    // ── 反向（承重）：真实失败必须仍被判成有错误

    it('Fabric 的 [ERROR] 排版仍算错误信号', 0, () => {
      // 2026-08-29 曾因只认 MC 的 /ERROR] 而让这一整类静默漏判。
      expect(hasErrorSignal(TAIL_FABRIC_FAILURE)).assertTrue();
    });

    it('没有级别标记的 Java 异常顶行仍算错误信号', 0, () => {
      expect(lineLooksLikeError(
        'java.lang.NullPointerException: Cannot invoke "Minecraft.getWindow()"')).assertTrue();
      expect(lineLooksLikeError(
        'Exception in thread "main" java.lang.RuntimeException: boom')).assertTrue();
      // 32 KB 尾窗从堆栈中间切进来时，Caused by 是唯一剩下的证据。
      expect(lineLooksLikeError(
        'Caused by: java.io.IOException: Failed to read version manifest')).assertTrue();
    });

    it('JVM 自己的裸 Error: 行仍算错误信号', 0, () => {
      expect(lineLooksLikeError(
        'Error: Could not find or load main class net.minecraft.client.main.Main')).assertTrue();
    });

    it('崩溃强信号仍算错误信号', 0, () => {
      expect(lineLooksLikeError('---- Minecraft Crash Report ----')).assertTrue();
      expect(lineLooksLikeError(
        '# A fatal error has been detected by the Java Runtime Environment:')).assertTrue();
    });

    it('INFO 行既不是噪声也不是错误信号', 0, () => {
      const info = '[13:14:16] [Render thread/INFO]: Preparing spawn area: 0%';
      expect(lineLooksLikeError(info)).assertFalse();
      // 不是噪声 ⇒ 不许被剥掉（剥掉会让「技术详情」丢上下文）。
      expect(stripLogNoiseText(info).length > 0).assertTrue();
    });

    // ── 端到端：用户看到的那个结局

    it('健康会话不弹错误 Sheet（1000591 之后的回归防线）', 0, () => {
      const ev: McLogEvidence = SessionMarker.analyzeMcLog(TAIL_HEALTHY_SESSION);
      expect(ev.hasLog).assertTrue();
      expect(ev.hasCrashMarker).assertFalse();
      // 摘要必须是空串：非空就会被当成"崩溃原因"展示给用户。
      expect(ev.summary).assertEqual('');
      expect(ev.hasRealError).assertFalse();
      // 结局：ABORTED（中性文案），不是 CRASHED。
      expect(shouldDiagnose(ev)).assertFalse();
    });

    it('真实启动失败仍然会弹错误 Sheet', 0, () => {
      const ev: McLogEvidence = SessionMarker.analyzeMcLog(TAIL_FABRIC_FAILURE);
      expect(ev.hasRealError).assertTrue();
      expect(shouldDiagnose(ev)).assertTrue();
    });

    // ── 规则表本身

    it('噪声规则表的 needle 全小写且不过宽', 0, () => {
      // 匹配方对整行 toLowerCase 后做 indexOf ⇒ 带大写的 needle 永远命中不了，
      // 而"永远命中不了"在日志里是看不见的。
      const rules = listLogNoiseRules();
      expect(rules.length > 0).assertTrue();
      for (let i = 0; i < rules.length; i++) {
        expect(rules[i].needle).assertEqual(rules[i].needle.toLowerCase());
        expect(rules[i].needle.length >= 8).assertTrue();
        expect(rules[i].reason.length > 0).assertTrue();
      }
    });
  });
}

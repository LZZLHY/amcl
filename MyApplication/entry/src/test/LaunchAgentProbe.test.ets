/*
 * LaunchAgentProbe.test.ets — C0 探针的注入决策（批次 C Phase 0）
 *
 * ⭐ **这份测试钉的是一个开关的"默认关"，而那正是最容易变成假声明的东西。**
 *
 * 批次 C 的 C0-A2 要求探针"由 -D 默认关闭且门禁断言其默认值"，理由是
 * AGENTS.md §二.5：**一个开关的"声明默认值"与"产品实际值"是两个事实，写在两个文件里。**
 * 三者分工（缺一个这条判据就不成立）：
 *   · 声明默认值 → `AGENT_PROBE_DEFAULT_ON`，由 scripts/check-launch-agent-probe.mjs 断言；
 *   · **决策行为** → 本文件（marker 缺失/取 0/取别的值时都不许注入）；
 *   · 产品实际值 → 真机日志里的 `AMCL_AGENT_PROBE ... injected=` 与 `[AMCL-AGENT]`。
 *
 * ⚠️ 另一条同等重要：`requested=1 injected=0` 必须是一个**能看见的**状态。
 * 若把"没请求"和"请求了但拿不到 jar"都记成"没装"，真机上就会出现
 * "开关放上去了没反应"且无从归因 —— AGENTS.md §三.7 那一族（本仓已咬过三次）。
 *
 * 创建日期：2026-09-04
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  resolveAgentProbe, AgentProbeDecision,
  AGENT_PROBE_ARG_KEY, AGENT_PROBE_ON_VALUE, AGENT_PROBE_DEFAULT_ON, AGENT_PROBE_JAR_NAME,
} from 'launch';

const JAR: string = '/data/storage/el2/base/haps/entry/files/amcl-launcher.jar';
const ON: string = AGENT_PROBE_ARG_KEY + AGENT_PROBE_ON_VALUE;

/** 一份"正常启动"的 JVM 参数（没有任何探针 marker）。 */
function baseArgs(): string[] {
  return [
    '-Xmx2048M',
    '-Damcl.classpathDelivery=jvm-classpath-full',
    '-Damcl.loaderGeneration=forge-bootstrap',
  ];
}

export default function launchAgentProbeTest() {
  describe('LaunchAgentProbe', () => {

    // ── 一、默认关 ──────────────────────────────────────────────────
    it('声明默认值是关（C0-A2 的声明那一半）', 0, () => {
      expect(AGENT_PROBE_DEFAULT_ON).assertFalse();
      expect(AGENT_PROBE_JAR_NAME).assertEqual('amcl-launcher.jar');
    });

    it('没有 marker 时不注入任何参数', 0, () => {
      const d: AgentProbeDecision = resolveAgentProbe(baseArgs(), JAR);
      expect(d.requested).assertFalse();
      expect(d.injected).assertFalse();
      expect(d.args.length).assertEqual(0);
    });

    it('空参数表也不注入（不许把"没参数"当成"开"）', 0, () => {
      const d: AgentProbeDecision = resolveAgentProbe([], JAR);
      expect(d.injected).assertFalse();
      expect(d.args.length).assertEqual(0);
    });

    // ── 二、开启：只认唯一的那个值 ──────────────────────────────────
    it('marker=1 时注入 -javaagent，且只注入这一条', 0, () => {
      const args: string[] = baseArgs();
      args.push(ON);
      const d: AgentProbeDecision = resolveAgentProbe(args, JAR);
      expect(d.requested).assertTrue();
      expect(d.injected).assertTrue();
      expect(d.args.length).assertEqual(1);
      expect(d.args[0]).assertEqual('-javaagent:' + JAR);
    });

    // ⭐ 跨局结论文件：mc_output.log 每局被截断重写，一次性结论只写它等于会丢
    // （2026-09-04 真机第一次跑探针就丢了一整轮，见施工记录 §S09.2）。
    it('给了日志目录时连带下传结论文件路径', 0, () => {
      const args: string[] = baseArgs();
      args.push(ON);
      const d: AgentProbeDecision = resolveAgentProbe(args, JAR, '/data/x/files/logs');
      expect(d.args.length).assertEqual(2);
      expect(d.args[1]).assertEqual('-Damcl.agentProbe.log=/data/x/files/logs/agent-probe.log');
    });

    it('拿不到日志目录仍然注入 agent（只是结论不跨局保留）', 0, () => {
      const args: string[] = baseArgs();
      args.push(ON);
      const d: AgentProbeDecision = resolveAgentProbe(args, JAR, '');
      expect(d.injected).assertTrue();
      expect(d.args.length).assertEqual(1);
    });

    it('探针关闭时不下传结论文件路径', 0, () => {
      const d: AgentProbeDecision = resolveAgentProbe(baseArgs(), JAR, '/data/x/files/logs');
      expect(d.args.length).assertEqual(0);
    });

    it('=0 / =false / 空值都算关（不许把"写了这个键"当成开）', 0, () => {
      const off: string[] = [AGENT_PROBE_ARG_KEY + '0', AGENT_PROBE_ARG_KEY + 'false',
        AGENT_PROBE_ARG_KEY];
      for (let i = 0; i < off.length; i++) {
        const args: string[] = baseArgs();
        args.push(off[i]);
        const d: AgentProbeDecision = resolveAgentProbe(args, JAR);
        expect(d.requested).assertFalse();
        expect(d.injected).assertFalse();
      }
    });

    it('同键多次出现时后者胜（与 JVM 的 -D 语义一致）', 0, () => {
      const onThenOff: string[] = [ON, AGENT_PROBE_ARG_KEY + '0'];
      expect(resolveAgentProbe(onThenOff, JAR).injected).assertFalse();
      const offThenOn: string[] = [AGENT_PROBE_ARG_KEY + '0', ON];
      expect(resolveAgentProbe(offThenOn, JAR).injected).assertTrue();
    });

    it('前缀相近的别的 marker 不许命中', 0, () => {
      // 真实参数表里有 -Damcl.classpathDelivery= / -Damcl.loaderGeneration= 等一族同前缀键。
      const args: string[] = baseArgs();
      args.push('-Damcl.agentProbeExtra=1');
      const d: AgentProbeDecision = resolveAgentProbe(args, JAR);
      expect(d.requested).assertFalse();
    });

    // ── 三、requested=1 injected=0 必须看得见 ───────────────────────
    it('请求了但拿不到 jar 路径 ⇒ 不注入，且两个字段分开留痕', 0, () => {
      const args: string[] = baseArgs();
      args.push(ON);
      const d: AgentProbeDecision = resolveAgentProbe(args, '');
      expect(d.requested).assertTrue();
      expect(d.injected).assertFalse();
      expect(d.args.length).assertEqual(0);
      expect(d.logLine.indexOf('requested=1') >= 0).assertTrue();
      expect(d.logLine.indexOf('injected=0') >= 0).assertTrue();
      expect(d.logLine.indexOf('jar=(absent)') >= 0).assertTrue();
    });

    // ── 四、判据行 ──────────────────────────────────────────────────
    it('无论装不装都产出一行可 grep 的判据', 0, () => {
      // "探针没装"必须与"装了没命中"在日志里长得不一样（AGENTS §二.3）。
      const off: AgentProbeDecision = resolveAgentProbe(baseArgs(), JAR);
      expect(off.logLine.indexOf('AMCL_AGENT_PROBE') >= 0).assertTrue();
      expect(off.logLine.indexOf('default=off') >= 0).assertTrue();
      expect(off.logLine.indexOf('requested=0 injected=0') >= 0).assertTrue();

      const args: string[] = baseArgs();
      args.push(ON);
      const on: AgentProbeDecision = resolveAgentProbe(args, JAR);
      expect(on.logLine.indexOf('requested=1 injected=1') >= 0).assertTrue();
      expect(on.logLine.indexOf(JAR) >= 0).assertTrue();
    });
  });
}

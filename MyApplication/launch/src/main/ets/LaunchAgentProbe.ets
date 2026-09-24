/**
 * LaunchAgentProbe.ets — C0 探针的 ArkTS 半边（纯函数，无 IO）
 *
 * ⛔ **批次 C 已证伪并归档（2026-09-05）。本文件不是"通往 C1 的半成品"，
 * 而是一个已经交付了结论的量具的注入侧。** C0-1 为否：真机上 Forge 与 Fabric
 * 各自又定义了一份 `com.amcl.launcher.*` helper（`sameClassAsHost=0`）⇒
 * 按方案 §5.5 预设的闸门整批停止。结论见施工记录 §S10，结案与"若重启该换什么方向"见 §S13。
 * ⇒ **刻意保留且默认关**：它是重启这条路时唯一现成的量具。
 *
 * 方案 `docs/refactor/启动变换Agent化与诊断收口方案.md` §5.2。
 * Java 半边是 `JavaApp/src/com/amcl/launcher/AmclAgentProbe.java`；
 * 两侧的 marker 字面量由 `scripts/check-launch-agent-probe.mjs` 静态校验一致。
 *
 * ⭐ **本文件唯一的职责是回答"这次启动要不要把 amcl-launcher.jar 当 agent 装上"。**
 * 本纯函数解释 `-Damcl.agentProbe=1` marker，**默认关**；调用方只在 default 开发产品执行注入。
 *
 * ⚠️ 为什么开关必须走 `-D` marker 而不是环境变量：应用进程**不继承** `hdc shell` 的
 * 环境变量（AGENTS.md §三.5）⇒ 用 env 当开关在真机上默认是按不到的。
 * `-D` 这条通道用户自己就能用（设置 → 自定义 JVM 参数），且它会同时成为一个系统属性
 * ⇒ Java 侧的 premain 能读到同一个事实，两道门各自独立。
 *
 * ⚠️ **声明默认值与产品实际值是两个事实**（AGENTS.md §二.5）：
 * 本文件的 `AGENT_PROBE_DEFAULT_ON` 是**声明**，门禁断言它是 false；
 * 产品实际值只能从 `AMCL_AGENT_PROBE` 那一行日志与真机 `[AMCL-AGENT]` 行反查。
 * 所以 `resolveAgentProbe` 无论装不装都返回判据，由 default 的 Debug logger 按需记录，用户包不输出探针状态。
 *
 * 创建日期：2026-09-04
 */

/** 开关键。**与 Java 侧 `AmclAgentProbe.PROBE_PROP` 逐字对应。** */
export const AGENT_PROBE_ARG_KEY: string = '-Damcl.agentProbe=';
/** 唯一的开启值。任何其它值都视为关（含空值），避免 `=0` / `=false` 被读成开。 */
export const AGENT_PROBE_ON_VALUE: string = '1';
/**
 * 探针结论文件的路径键。**与 Java 侧 `AmclAgentProbe.PROBE_LOG_PROP` 逐字对应。**
 *
 * ⚠️ 存在的理由是一次真机学费（施工记录 §S09.2）：C0 的结论原来只写 `System.out` ⇒
 * 落在 `mc_output.log`，而**那个文件每局都会被截断重写**。用户为对比又启动了一次同一版本，
 * 上一局那三条一次性结论就整个没了 —— "探针跑过并得出结论"与"探针从未装上"不可区分。
 * ⇒ 路径由 ArkTS 给（只有它知道 filesDir），Java 侧只管追加写。
 */
export const AGENT_PROBE_LOG_ARG_KEY: string = '-Damcl.agentProbe.log=';
/** 结论文件名。放在 `filesDir/logs/` 下，与 `amcl_launcher.log` 同目录，方便一起取。 */
export const AGENT_PROBE_LOG_NAME: string = 'agent-probe.log';
/** ⭐ 声明默认值：产品里探针**默认关**（C0-A2）。门禁断言这一行是 false。 */
export const AGENT_PROBE_DEFAULT_ON: boolean = false;
/** agent jar 的文件名。它就是启动器自己那个 jar（方案 §5.1：无需第二个 jar）。 */
export const AGENT_PROBE_JAR_NAME: string = 'amcl-launcher.jar';

export interface AgentProbeDecision {
  /** 本次启动是否请求了探针（marker 命中）。 */
  requested: boolean;
  /** 是否真的注入了 `-javaagent:`。请求了但拿不到 jar 路径时为 false。 */
  injected: boolean;
  /** 要追加进 jvmArgs 的参数；未注入时为空数组。 */
  args: string[];
  /** 一行判据，直接打进启动日志。**请求与注入是两个字段，不许压成一个。** */
  logLine: string;
}

/**
 * 判定是否注入 C0 探针 agent。
 *
 * @param jvmArgs         **最终**的 JVM 参数（必须在用户自定义参数合并之后调用 ——
 *                        marker 正是用户从设置里加进来的，合并之前看不到它）
 * @param launcherJarPath `filesDir/amcl-launcher.jar` 的绝对路径；空串 = 拿不到
 *
 * `requested && !injected` 是一个**有信息量的失败**：它意味着用户确实开了探针、
 * 而启动器没能把 jar 路径给出来。若把这两种情形都记成"没装"，真机上就会出现
 * "开关放上去了没反应"且无从归因（AGENTS.md §三.7 那一族）。
 */
export function resolveAgentProbe(jvmArgs: string[], launcherJarPath: string,
                                  logDir: string = ''): AgentProbeDecision {
  const requested: boolean = readProbeMarker(jvmArgs) === AGENT_PROBE_ON_VALUE;
  const hasJar: boolean = launcherJarPath.length > 0;
  const injected: boolean = requested && hasJar;
  const args: string[] = injected ? ['-javaagent:' + launcherJarPath] : [];
  // 结论文件是**跨局**证据；拿不到目录时仍然注入 agent（只是结论只进 mc_output.log）。
  if (injected && logDir.length > 0) {
    args.push(AGENT_PROBE_LOG_ARG_KEY + logDir + '/' + AGENT_PROBE_LOG_NAME);
  }
  return {
    requested: requested,
    injected: injected,
    args: args,
    logLine: `AMCL_AGENT_PROBE schema=1 default=${AGENT_PROBE_DEFAULT_ON ? 'on' : 'off'}`
      + ` requested=${requested ? 1 : 0} injected=${injected ? 1 : 0}`
      + ` jar=${hasJar ? launcherJarPath : '(absent)'}`,
  };
}

/**
 * 取 marker 的值；没有该 marker 返回空串。
 *
 * **取最后一条命中**，与 JVM 的"同名 `-D` 后者胜"一致：用户在自定义参数里写了
 * `-Damcl.agentProbe=0` 就应该真的关掉，即便前面还有一条 `=1`。
 */
function readProbeMarker(jvmArgs: string[]): string {
  let value: string = '';
  for (let i = 0; i < jvmArgs.length; i++) {
    const arg: string = jvmArgs[i];
    if (arg.startsWith(AGENT_PROBE_ARG_KEY)) {
      value = arg.substring(AGENT_PROBE_ARG_KEY.length);
    }
  }
  return value;
}

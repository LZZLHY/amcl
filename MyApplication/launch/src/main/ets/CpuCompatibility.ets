/**
 * CPU 事实到 JVM 的生产启动桥；不依赖游戏版本或加载器类型。
 * 属性在用户参数合并后生成，Agent 在任何 OSHI 类初始化前消费相同的宿主快照。
 */
import { HostCpuInfo } from 'commons';
import { CPU_AGENT_RUNTIME_JAR } from './CpuCompatibilityArtifact';

/** 内容寻址路径可与旧应用版本并存，避免其他正在启动的进程读到被替换的 Agent。 */
export function cpuCompatibilityPath(filesDir: string): string {
  return filesDir + '/runtime-compat/' + CPU_AGENT_RUNTIME_JAR;
}

/** 禁止外部参数伪造宿主 CPU 事实；其他 Agent、加载器参数保持原有次序。 */
export function applyCpuCompatibility(args: string[], filesDir: string, cpu: HostCpuInfo): string[] {
  const path: string = cpuCompatibilityPath(filesDir);
  for (const arg of args) {
    if (arg.startsWith('-Damcl.cpu.') || arg.startsWith('-javaagent:' + filesDir + '/runtime-compat/amcl-cpu-agent-')) {
      throw new Error('CPU 信息由鸿蒙系统采集，不允许自定义 JVM 参数覆盖');
    }
  }
  return args.concat([
    '-Damcl.cpu.schema=1', '-Damcl.cpu.model=' + cpu.model, '-Damcl.cpu.abi=' + cpu.abi,
    '-Damcl.cpu.online=' + cpu.logicalIds.join(','), '-Damcl.cpu.topology=' + cpu.topology,
    '-javaagent:' + path,
  ]);
}

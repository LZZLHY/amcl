/**
 * 会话环境事实的唯一存储与公开视图。采集由 entry/product 执行，commons 不依赖 native。
 * 每个事实保留来源、采集时间和可信状态；旧会话缺字段只标未知，绝不用当前设备补造历史。
 * 写入只允许诊断白名单，公开值统一脱敏；原始日志的采集完整性由独立的封账清单负责。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensureDirSync } from './FileUtils';
import { writeEvidenceTextAtomic } from './EvidenceIo';
import { sanitizeLogForExport, LogExportTarget } from './LogExport';

export interface SessionEnvironmentFact {
  key: string;
  value: string;
  source: string;
  status: string;
  observedAt: number;
}
export interface SessionEnvironment {
  schema: number;
  activityId: number;
  revision: number;
  facts: SessionEnvironmentFact[];
}

const KEYS: string[] = [
  'launcher.name', 'launcher.version', 'launcher.versionCode', 'launcher.product', 'launcher.channel',
  'host.os', 'host.osVersion', 'host.api', 'host.device', 'host.brand', 'host.abi',
  'cpu.model', 'cpu.cores', 'memory.physicalMb', 'memory.jvmMaxMb',
  'gpu.model', 'gpu.vendor', 'gpu.apiVersion', 'gpu.probeModel', 'gpu.driver',
  'graphics.requestedProfile', 'graphics.profile', 'graphics.api', 'graphics.provider', 'graphics.windowProvider',
  'game.instance', 'game.version', 'game.loader', 'game.loaderVersion', 'game.generation',
  'java.major', 'java.version', 'java.vendor', 'java.vm', 'java.arch', 'java.guestOs', 'java.arguments',
  'logging.configuration', 'logging.configurationStatus', 'logging.configurationReason',
];

export function sessionEnvironmentPath(filesDir: string, activityId: number): string {
  if (!Number.isSafeInteger(activityId) || activityId <= 0) throw new Error('会话环境身份无效');
  return filesDir + '/logs/ledger/' + activityId + '/environment.json';
}

/** 构造有来源的事实；不可取得时由调用方给出具体原因，空值不能冒充已知。 */
export function sessionEnvironmentFact(key: string, value: string, source: string,
  status: string = 'observed'): SessionEnvironmentFact {
  return { key: key, value: value.length > 0 ? value : 'unavailable', source: source,
    status: value.length > 0 ? status : 'unavailable', observedAt: Date.now() };
}

/** 只解析本局、白名单且类型有效的字段；损坏/旧会话返回空事实，不抛到页面。 */
export function readSessionEnvironment(filesDir: string, activityId: number): SessionEnvironment {
  const result: SessionEnvironment = { schema: 1, activityId: activityId, revision: 0, facts: [] };
  try {
    const path: string = sessionEnvironmentPath(filesDir, activityId);
    if (fs.statSync(path).size > 512 * 1024) return result;
    const data = JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
    if (data['activityId'] !== activityId || data['schema'] !== 1 || !Array.isArray(data['facts'])) return result;
    result.revision = typeof data['revision'] === 'number' ? data['revision'] as number : 0;
    for (const item of data['facts'] as Object[]) {
      const record = item as Record<string, Object>;
      if (typeof record['key'] !== 'string' || typeof record['value'] !== 'string'
        || typeof record['source'] !== 'string' || typeof record['status'] !== 'string') continue;
      const key: string = record['key'] as string;
      if (!KEYS.includes(key)) continue;
      result.facts.push({ key: key, value: record['value'] as string, source: record['source'] as string,
        status: record['status'] as string, observedAt: Number(record['observedAt']) || 0 });
    }
  } catch (e) { /* 旧账本没有环境文件；缺失本身由公开视图明确表达。 */ }
  return result;
}

/** 合并启动准备各阶段的事实并原子保存；不跨活动、也不把未知值覆盖已有实测值。 */
export function updateSessionEnvironment(filesDir: string, activityId: number,
  facts: SessionEnvironmentFact[]): SessionEnvironment {
  const environment = readSessionEnvironment(filesDir, activityId);
  let changed: boolean = environment.revision === 0;
  for (const fact of facts) {
    if (!KEYS.includes(fact.key)) continue;
    const index: number = environment.facts.findIndex((item: SessionEnvironmentFact): boolean => item.key === fact.key);
    const old = index < 0 ? undefined : environment.facts[index];
    if (old?.status === 'observed' && fact.status === 'unavailable') continue;
    const clean: SessionEnvironmentFact = { key: fact.key,
      value: sanitizeLogForExport(fact.value, LogExportTarget.LOGSHARE, fact.key === 'java.arguments' ? 32768 : 2048),
      source: fact.source.substring(0, 256), status: fact.status, observedAt: fact.observedAt };
    if (old?.value === clean.value && old?.source === clean.source && old?.status === clean.status) continue;
    if (index >= 0) environment.facts[index] = clean;
    else environment.facts.push(clean);
    changed = true;
  }
  if (changed) {
    environment.revision++;
    const path: string = sessionEnvironmentPath(filesDir, activityId);
    ensureDirSync(path.substring(0, path.lastIndexOf('/')));
    writeEvidenceTextAtomic(path, JSON.stringify(environment));
  }
  return environment;
}

/** native/Java 在真实运行线程通过受控日志标记补交事实，不能在 UI 线程伪造 GL 实测。 */
export function readObservedSessionEnvironment(filesDir: string, activityId: number): SessionEnvironment {
  const environment = readSessionEnvironment(filesDir, activityId);
  const path: string = filesDir + '/logs/ledger/' + activityId + '/environment-observed.log';
  try {
    if (fs.statSync(path).size > 256 * 1024) return environment;
    for (const line of fs.readTextSync(path).split('\n')) {
      const start: number = line.indexOf('AMCL_ENV_V1\t');
      if (start < 0) continue;
      const parts: string[] = line.substring(start).split('\t');
      // 结构：版本、key、value、source；缺字段或非白名单完全忽略。
      if (parts.length < 4 || !KEYS.includes(parts[1])) continue;
      const value: string = sanitizeLogForExport(parts[2], LogExportTarget.LOGSHARE, 2048);
      if (value.length === 0 || value === 'N/A' || value === 'null') continue;
      const fact: SessionEnvironmentFact = { key: parts[1], value: value,
        source: parts[3].substring(0, 256), status: 'observed', observedAt: 0 };
      const index: number = environment.facts.findIndex((item: SessionEnvironmentFact): boolean => item.key === fact.key);
      if (index < 0) environment.facts.push(fact); else environment.facts[index] = fact;
    }
  } catch (e) { /* 初始化前失败的会话没有 GPU/Java 运行观测，保留初始未知原因。 */ }
  return environment;
}

export function environmentValue(environment: SessionEnvironment, key: string): string {
  return environment.facts.find((fact: SessionEnvironmentFact): boolean => fact.key === key)?.value ?? 'unknown (not recorded)';
}

/** 用于小型主诊断概览；详细 JVM 参数仍在完整环境附件中，不挤占 AI 的基础事实。 */
export function sessionEnvironmentSummary(environment: SessionEnvironment): string {
  const lines: string[] = ['AMCL session environment (schema 1)', 'activityId=' + environment.activityId];
  // 初始概览只包含确定的基础集合，值限制为短文本；完整事实/参数在环境附件中保留。
  const essentials: string[] = ['launcher.name', 'launcher.version', 'launcher.versionCode', 'launcher.product',
    'host.os', 'host.osVersion', 'host.api', 'host.device', 'host.abi', 'cpu.model', 'cpu.cores',
    'memory.physicalMb', 'memory.jvmMaxMb', 'gpu.model', 'gpu.probeModel', 'gpu.vendor', 'gpu.driver',
    'graphics.profile', 'graphics.api', 'graphics.provider', 'game.version', 'game.loader', 'game.loaderVersion',
    'java.major', 'java.version', 'java.vendor', 'logging.configurationStatus'];
  for (const key of essentials) {
    const fact = environment.facts.find((item: SessionEnvironmentFact): boolean => item.key === key);
    lines.push(key + '=' + (fact === undefined ? 'unknown (not recorded)' : fact.value.substring(0, 48))
      + (fact !== undefined && fact.status !== 'observed' ? ' [' + fact.status + ']' : ''));
  }
  return lines.join('\n');
}

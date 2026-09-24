/**
 * 证据的展示与主动分享模板。仅从已记录事实推导文案/排序，不修改采集状态、退出结局
 * 或原始收据。列表、阅读器和分享选择页使用同一规则，避免同一文件多套解释。
 */
import { EvidenceFileRecord, EvidenceFileState, EvidenceRole, defaultEvidenceSelection,
  normalizeEvidenceSelection, evidenceRoleLabel } from './EvidenceTypes';

/** 已保存且允许阅读的文件；未知归属仍可本地查看，外发由选择规则单独控制。 */
export function evidenceReadable(file: EvidenceFileRecord): boolean {
  return file.bytes > 0 && file.state !== EvidenceFileState.MISSING && file.state !== EvidenceFileState.CLEANED
    && file.state !== EvidenceFileState.NOT_PRODUCED && file.state !== EvidenceFileState.NOT_APPLICABLE
    && file.state !== EvidenceFileState.UNAVAILABLE;
}

/** 可读性与确定缺口分开；没有关闭证明不能翻译为“文件内容确定丢失”。 */
export function evidenceCaptureLabel(file: EvidenceFileRecord, running: boolean): string {
  if (file.state === EvidenceFileState.WRITING) return running ? '正在记录' : '退出前未封账';
  if (file.state === EvidenceFileState.PARTIAL) {
    if (new RegExp('收据不符|内容校验失败|文件长度|文件内容|原件.*不符').test(file.reason)) return '归档校验不符';
    if (new RegExp('截断|丢弃|写入失败|重定向.*失败').test(file.reason)) return '存在已知记录缺口';
    return '已保存，完整性待确认';
  }
  if (file.state === EvidenceFileState.COMPLETE) return file.verification === 'verified' ? '原件校验通过' : '已保存，记录已结束';
  if (file.state === EvidenceFileState.AVAILABLE) return '已保存';
  if (file.state === EvidenceFileState.NOT_PRODUCED) return '本次未生成';
  if (file.state === EvidenceFileState.NOT_APPLICABLE) return '本次不适用';
  if (file.state === EvidenceFileState.CLEANED) return '已清理';
  if (file.state === EvidenceFileState.MISSING) return '文件未找到';
  if (file.state === EvidenceFileState.UNAVAILABLE) return '当前不可读取';
  return '记录状态未知';
}

/** 不把未知完整性当成崩溃原因。只有计数/校验等明确证据才使用“已知缺口”。 */
export function evidenceIntegrityCaption(integrity: string, reasons: string[], running: boolean): string {
  if (running) return '日志正在记录，本页是当前快照';
  if (integrity === 'complete') return '已保存的日志通过完整性检查';
  if (integrity === 'missing') return '没有可读取的日志';
  if (reasons.some((reason: string): boolean => new RegExp('收据不符|截断|丢弃|写入失败|采集有缺口').test(reason))) {
    return '已保存日志，存在已知记录缺口';
  }
  return '已保存的内容可查看，完整性尚未确认';
}

/** 优先展示有信息的可读来源，未产生的占位项最后显示；同角色保持稳定路径次序。 */
export function evidenceViewPriority(file: EvidenceFileRecord): number {
  let priority: number = 70;
  if (file.role === EvidenceRole.CRASH_REPORT || file.role === EvidenceRole.JVM_FATAL || file.role === EvidenceRole.SYSTEM_CRASH) priority = 0;
  else if (file.role === EvidenceRole.MINECRAFT_MAIN) priority = 10;
  else if (file.role === EvidenceRole.MINECRAFT_OUTPUT) priority = 20;
  else if (file.role === EvidenceRole.JVM_STDERR) priority = 25;
  else if (file.role === EvidenceRole.LAUNCHER) priority = 30;
  else if (file.role === EvidenceRole.MINECRAFT_DEBUG) priority = 40;
  else if (file.role === EvidenceRole.RENDERER || file.role === EvidenceRole.RENDERER_PROBE) priority = 45;
  else if (file.role === EvidenceRole.JVM_GC) priority = 50;
  return priority + (evidenceReadable(file) ? 0 : 100);
}

export function sortEvidenceForView(files: EvidenceFileRecord[]): EvidenceFileRecord[] {
  return files.slice().sort((left: EvidenceFileRecord, right: EvidenceFileRecord): number => {
    const priority: number = evidenceViewPriority(left) - evidenceViewPriority(right);
    return priority !== 0 ? priority : left.path < right.path ? -1 : left.path > right.path ? 1 : 0;
  });
}

/** 只推荐本局可信来源；启动早期没有主日志时优先 JVM 输出，其次控制台/启动器。 */
export function recommendedEvidenceFile(files: EvidenceFileRecord[]): EvidenceFileRecord | undefined {
  const available: EvidenceFileRecord[] = sortEvidenceForView(files).filter((file: EvidenceFileRecord): boolean =>
    evidenceReadable(file) && file.attribution !== 'previous-session' && file.attribution !== 'ambiguous');
  const primary = available.find((file: EvidenceFileRecord): boolean => evidenceViewPriority(file) <= 10);
  return primary ?? available.find((file: EvidenceFileRecord): boolean => file.role === EvidenceRole.JVM_STDERR)
    ?? available[0];
}

/** 名称后保留真实文件名，多个同角色文件不会呈现成无法分辨的同名按钮。 */
export function evidenceDisplayName(file: EvidenceFileRecord): string {
  return evidenceRoleLabel(file.role) + ' · ' + file.path.substring(file.path.lastIndexOf('/') + 1);
}

/** 常见环境字段使用用户可读名称，未知扩展字段仍保留原键，避免丢失诊断语义。 */
export function environmentFactLabel(key: string): string {
  const labels: Record<string, string> = { 'launcher.name': '启动器', 'launcher.version': '应用版本',
    'launcher.versionCode': '构建版本', 'launcher.product': '产品类型', 'launcher.channel': '安装渠道',
    'host.os': '主机系统', 'host.osVersion': '系统版本', 'host.api': '系统 API', 'host.device': '设备型号',
    'host.brand': '设备品牌', 'host.abi': '处理器架构', 'cpu.model': '芯片型号', 'cpu.cores': 'CPU 核心',
    'memory.physicalMb': '设备内存（MiB）', 'memory.jvmMaxMb': 'JVM 内存上限（MiB）',
    'gpu.model': '实际图形设备', 'gpu.probeModel': '图形能力探测设备', 'gpu.vendor': '图形实现厂商',
    'gpu.driver': '图形驱动', 'graphics.profile': '图形方案', 'graphics.requestedProfile': '请求的图形方案',
    'graphics.api': '图形 API', 'graphics.provider': '图形实现', 'graphics.windowProvider': '窗口实现',
    'game.instance': '游戏实例', 'game.version': 'Minecraft 版本', 'game.loader': '加载器',
    'game.loaderVersion': '加载器版本', 'game.generation': '游戏运行代际', 'java.major': 'Java 主版本',
    'java.version': 'Java 完整版本', 'java.vendor': 'Java 发行方', 'java.arguments': 'JVM 参数',
    'logging.configurationStatus': '日志配置归属', 'logging.configurationReason': '日志配置说明' };
  return labels[key] ?? key;
}

export enum EvidenceScenario { RECOMMENDED = 'recommended', MODS = 'mods', GRAPHICS = 'graphics', MEMORY = 'memory', DOWNLOAD = 'download', CUSTOM = 'custom' }
export const EVIDENCE_SCENARIOS: EvidenceScenario[] = [EvidenceScenario.RECOMMENDED, EvidenceScenario.MODS,
  EvidenceScenario.GRAPHICS, EvidenceScenario.MEMORY, EvidenceScenario.DOWNLOAD];
export const EVIDENCE_SCENARIO_LABELS: string[] = ['推荐日志', '模组问题', '图形问题', '内存问题', '下载问题'];

/**
 * 仅供高级选择页的主动模板，快捷分享仍使用原 defaultEvidenceSelection。
 * 模板包含推荐基础文件和对应角色；禁止自动混入上一局/归属冲突文件。
 */
export function evidenceScenarioSelection(files: EvidenceFileRecord[], scenario: EvidenceScenario): string[] {
  const selected: string[] = defaultEvidenceSelection(files);
  for (const file of files) {
    if (file.attribution === 'previous-session' || file.attribution === 'ambiguous') continue;
    const role: EvidenceRole = file.role;
    const include: boolean = scenario === EvidenceScenario.MODS && (role === EvidenceRole.MINECRAFT_DEBUG || role === EvidenceRole.INSTALLER)
      || scenario === EvidenceScenario.GRAPHICS && (role === EvidenceRole.RENDERER || role === EvidenceRole.RENDERER_PROBE
        || role === EvidenceRole.RENDERER_TRACE || role === EvidenceRole.MOBILEGLUES || role === EvidenceRole.SYSTEM_TRACE)
      || scenario === EvidenceScenario.MEMORY && (role === EvidenceRole.JVM_GC || role === EvidenceRole.SYSTEM_TRACE)
      || scenario === EvidenceScenario.DOWNLOAD && (role === EvidenceRole.NETWORK || role === EvidenceRole.INSTALLER);
    if (include && !selected.includes(file.fileId)) selected.push(file.fileId);
  }
  return normalizeEvidenceSelection(sortEvidenceForView(files), selected);
}

/**
 * 鸿蒙 CPU 事实的唯一采集入口。日志和 OSHI 启动桥共用；不依赖 native 或游戏状态。
 * 每次调用读取当前 online 快照，型号不可用与拓扑不可用互不影响，不猜测商业型号。
 */
import deviceInfo from '@ohos.deviceInfo';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 传给日志与 JVM 的只含基础数据的快照；空拓扑及 0 个物理对象表示未知。 */
export interface HostCpuInfo {
  model: string;
  abi: string;
  logicalIds: number[];
  topology: string;
  physicalCount: number;
  packageCount: number;
}

/** 严格解析 Linux online 语法；拒绝重复、倒置、非整数和过大列表，避免部分坏值入账。 */
export function parseOnlineCpuIds(text: string): number[] {
  const result: number[] = [];
  for (const part of text.trim().split(',')) {
    if (!/^\d+(-\d+)?$/.test(part)) throw new Error('CPU online 列表格式无效');
    const ends: string[] = part.split('-');
    const first: number = Number(ends[0]);
    const last: number = ends.length === 1 ? first : Number(ends[1]);
    if (first > last || last > 65535 || last - first >= 1024) throw new Error('CPU online 范围无效');
    for (let id: number = first; id <= last; id++) {
      if (result.indexOf(id) >= 0 || result.length >= 1024) throw new Error('CPU online 重复或过大');
      result.push(id);
    }
  }
  return result.sort((left: number, right: number): number => left - right);
}

/** 读取非负 topology 整数；负值是内核的未知值，不能据此生成物理拓扑。 */
function topologyNumber(path: string): number {
  const value: string = fs.readTextSync(path).trim();
  if (!/^\d+$/.test(value) || Number(value) > 65535) throw new Error('CPU topology 不可用');
  return Number(value);
}

/**
 * 只访问明确的 online 和 cpuN/topology 文件，不递归遍历含受限 core_ctl 的 sysfs 树。
 * API 20 不访问新增字段；型号/列表/拓扑各自失败时只清除对应事实，其他信息仍可交付。
 */
export function collectHostCpuInfo(): HostCpuInfo {
  const info: HostCpuInfo = { model: '', abi: '', logicalIds: [], topology: '', physicalCount: 0, packageCount: 0 };
  try {
    if (deviceInfo.sdkApiVersion >= 21) info.model = deviceInfo.chipType.trim().replace(/[\x00-\x1f\x7f]/g, '').slice(0, 128);
  } catch (error) { /* 旧系统或厂商未提供型号时保持空值。 */ }
  try { info.abi = deviceInfo.abiList; } catch (error) { /* ABI 不可用由 JVM 判断位数。 */ }
  try { info.logicalIds = parseOnlineCpuIds(fs.readTextSync('/sys/devices/system/cpu/online')); }
  catch (error) { return info; }
  try {
    const rows: string[] = [];
    const cores: string[] = [];
    const packages: number[] = [];
    for (const id of info.logicalIds) {
      const root: string = '/sys/devices/system/cpu/cpu' + id.toString() + '/topology/';
      const core: number = topologyNumber(root + 'core_id');
      const pkg: number = topologyNumber(root + 'physical_package_id');
      rows.push(id.toString() + ',' + core.toString() + ',' + pkg.toString());
      const key: string = pkg.toString() + ':' + core.toString();
      if (cores.indexOf(key) < 0) cores.push(key);
      if (packages.indexOf(pkg) < 0) packages.push(pkg);
    }
    info.topology = rows.join(';');
    info.physicalCount = cores.length;
    info.packageCount = packages.length;
  } catch (error) { /* 任一 CPU 拓扑缺失则整体未知，禁止拼接真实与推测的映射。 */ }
  return info;
}

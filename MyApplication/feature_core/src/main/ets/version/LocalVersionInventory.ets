import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { isVersionInstalled } from 'commons';
import { safeBaseName } from '../modloader/MavenUtils';
import { mergeVersionOrder } from './VersionOrdering';

/** 当前存储根的本地快照；读取本身不写选中版本、偏好、活动或页面状态。 */
export interface LocalVersionInventory {
  installed: string[];
  orphans: string[];
  error: string;
}

/** 读取与首页一致的 JAR/元数据判据，保留旧安装及残留目录，最后应用用户保存的顺序。 */
export async function readLocalVersionInventory(root: string, currentOrder: () => string[]): Promise<LocalVersionInventory> {
  const versionsDir = root + '/versions';
  const versions: string[] = [];
  const orphans: string[] = [];
  const mtimes = new Map<string, number>();
  let error = '';
  try {
    let entries = await fs.listFile(versionsDir)
    for (let name of entries) {
      if (name === 'download-temp' || name.startsWith('.')) continue
      let dirPath = versionsDir + '/' + name
      try {
        let dirStat = await fs.stat(dirPath)
        if (!dirStat.isDirectory()) continue
        mtimes.set(name, dirStat.mtime)
      } catch (e) {
        if ((e as BusinessError).code !== 13900002) error = (e as Error).message
        continue
      }

      // 判定规则 (2026-05-05 加强): 一个版本"真已安装" 当且仅当 同时满足:
      //   1. <id>.jar 存在且 > 1 MB
      //   2. <id>.json 存在且是合法 JSON, 且含 id 字段 + (mainClass 或 inheritsFrom)
      // 任一不满足 → orphan. 这样能识别出旧 DownloadTask bug 产生的
      // versions/<gameVersion>/<gameVersion>.jar (只有 vanilla jar 没有完整启动 JSON) 这种"假原版"残留.
      let jarPath = dirPath + '/' + name + '.jar'
      let jsonPath = dirPath + '/' + name + '.json'
      let jarOk = false
      try {
        let stat = await fs.stat(jarPath)
        jarOk = stat.size > 1024 * 1024
      } catch (e) { /* jar missing */ }

      let jsonOk = false
      if (jarOk) {
        try {
          let jsonText = await fs.readText(jsonPath)
          let obj = JSON.parse(jsonText) as Record<string, Object>
          let hasId = obj['id'] !== undefined && obj['id'] !== null
          let hasMainClass = obj['mainClass'] !== undefined && obj['mainClass'] !== null
          let hasInheritsFrom = obj['inheritsFrom'] !== undefined && obj['inheritsFrom'] !== null
          jsonOk = hasId && (hasMainClass || hasInheritsFrom)
        } catch (e) { /* json missing or malformed */ }
      }

      if (jarOk && jsonOk) {
        versions.push(name)
      } else {
        orphans.push(name)
      }
    }
  } catch (e) {
    if ((e as BusinessError).code !== 13900002) error = (e as Error).message
  }
  return { installed: mergeVersionOrder(versions, mtimes, currentOrder()), orphans: orphans, error: error };
}

/** 输入框与提交时使用同一文件名规则。底层任务仍负责目录归属和执行期独占校验。 */
export function versionInstallNameError(root: string, name: string): string {
  if (name.length === 0) return '版本名称不能为空';
  if (name.length > 64) return '版本名称不能超过 64 个字符';
  for (let i = 0; i < name.length; i++) {
    if ('/\\:*?"<>|'.includes(name[i])) return '不能包含字符: ' + name[i];
  }
  if (safeBaseName(name) !== name || name.startsWith('.') || name === 'download-temp') return '版本名称无效';
  return isVersionInstalled(root, name) ? '版本 ' + name + ' 已存在' : '';
}

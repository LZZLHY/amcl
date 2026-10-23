/**
 * 实例目录策略：整合包收据或持久安装计划存在时，该实例始终独立运行。
 * commons 只识别文件布局标记，不解释整合包内容；启动、资源管理与下载共用此策略。
 * 历史整合包沿用 .amcl-modpack.json，新任务在创建内容前写入安装计划标记。
 */
import { fileIo as fs } from '@kit.CoreFileKit';

export const MODPACK_PENDING_FILE: string = '.amcl-modpack-pending.json';
export const MODPACK_RECEIPT_FILE: string = '.amcl-modpack.json';

/** 拒绝目录分隔符和点段，保证元数据探测不会离开指定 versions 子目录。 */
function safeInstanceId(id: string): boolean {
  return id.length > 0 && id !== '.' && id !== '..'
    && id.indexOf('/') < 0 && id.indexOf('\\') < 0 && id.indexOf('\u0000') < 0;
}

/** 只认可普通元数据文件；探测失败不改变普通版本的全局隔离偏好。 */
export function isIsolatedModpackInstance(mcDir: string, versionId: string): boolean {
  if (!safeInstanceId(versionId)) return false;
  for (let marker of [MODPACK_RECEIPT_FILE, MODPACK_PENDING_FILE]) {
    try {
      let st = fs.lstatSync(mcDir + '/versions/' + versionId + '/' + marker);
      if (st.isFile() && !st.isSymbolicLink()) return true;
    } catch (e) { /* 普通版本或尚未创建的实例没有整合包标记。 */ }
  }
  return false;
}

/** 不创建目录；整合包独立目录优先于全局开关，普通版本维持原有行为。 */
export function resolveInstanceGameDir(mcDir: string, versionId: string, globalIsolation: boolean): string {
  if (!globalIsolation && !isIsolatedModpackInstance(mcDir, versionId)) return mcDir;
  if (!safeInstanceId(versionId)) throw new Error('独立实例缺少安全的版本名称');
  return mcDir + '/versions/' + versionId;
}

/** 持久 pending 表示该实例尚未交付，进程重启后也不能把半完成配置交给游戏。 */
export function hasPendingModpackInstall(gameDir: string): boolean {
  try { return fs.lstatSync(gameDir + '/' + MODPACK_PENDING_FILE).isFile(); }
  catch (e) { return false; }
}

/** 整合包恢复列表的 TaskPool 边界。只跨线程传递沙箱路径和界面摘要。 */
import { taskpool } from '@kit.ArkTS';
import { listModpackRecoveryPreview, ModpackRecoveryItem, ModpackRecoveryKind,
  cleanupDismissedModpackWork } from './ModpackInstallSession';
import { inspectModpackRecovery } from './ModpackInstaller';
import { LocalModScanControl, runModFileTask } from './ModScanWork';

/** 在工作线程枚举历史计划，沿用恢复资格与原安装根判定。 */
@Concurrent
function scanRecoveryTask(filesDir: string): ModpackRecoveryItem[] {
  return listModpackRecoveryPreview(filesDir, (): boolean => taskpool.Task.isCanceled());
}

/** 复用本地文件任务的共享并发预算。页面取消后由调用方丢弃已开始的读取结果。 */
export async function scanModpackRecovery(filesDir: string, control: LocalModScanControl): Promise<ModpackRecoveryItem[]> {
  return await runModFileTask(new taskpool.Task(scanRecoveryTask, filesDir), control) as ModpackRecoveryItem[];
}

/** 只为用户选中的记录检查实例收据；确认框不得在 TaskPool 中打开主执行环境的 WAL。 */
@Concurrent
function recoveryKindTask(filesDir: string, id: string): ModpackRecoveryKind {
  return inspectModpackRecovery(filesDir, id);
}

export async function readModpackRecoveryKind(filesDir: string, id: string): Promise<ModpackRecoveryKind> {
  return await runModFileTask(new taskpool.Task(recoveryKindTask, filesDir, id)) as ModpackRecoveryKind;
}

/** 在工作线程清理已放弃会话的私有下载文件。放弃记录与实例原件留在原处。 */
@Concurrent
async function cleanupRecoveryTask(filesDir: string, id: string): Promise<boolean> {
  return await cleanupDismissedModpackWork(filesDir, id);
}

export async function cleanupModpackRecoveryWork(filesDir: string, id: string): Promise<boolean> {
  return await runModFileTask(new taskpool.Task(cleanupRecoveryTask, filesDir, id)) as boolean;
}

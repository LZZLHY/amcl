/** 本地资源 TaskPool 边界。并发函数只引用导入符号，避免捕获宿主闭包。 */
import { taskpool } from '@kit.ArkTS';
import { LocalMod } from './ModTypes';
import { enumerateResourceFilesSync, computeModSha1Sync, computeModFingerprintSync } from './LocalModFileWorker';
import { LocalModScanControl, runModFileTask } from './ModScanWork';

/** 工作线程枚举入口；只传可序列化路径与扩展名，返回完整轻量记录。 */
@Concurrent
function enumerateTask(directory: string, extensions: string[]): LocalMod[] {
  return enumerateResourceFilesSync(directory, extensions);
}

/** 工作线程 SHA-1 入口，取消由底层每块检查。 */
@Concurrent
function sha1Task(path: string): string { return computeModSha1Sync(path); }

/** 工作线程 CF 指纹入口，避免把整个 JAR 复制进宿主堆。 */
@Concurrent
function fingerprintTask(path: string): number { return computeModFingerprintSync(path); }

/** 通用目录枚举供模组、资源包、光影和数据包 Sheet 复用，由调用方提供实际目录。 */
export async function enumerateLocalResourceFiles(directory: string, extensions: string[],
  control?: LocalModScanControl): Promise<LocalMod[]> {
  const result = await runModFileTask(new taskpool.Task(enumerateTask, directory, extensions), control);
  return result as LocalMod[];
}

/** 扫描专用摘要，不改动服务于其他安装流程的全局 computeFileSha1。 */
export async function computeLocalModSha1(path: string, control?: LocalModScanControl): Promise<string> {
  return await runModFileTask(new taskpool.Task(sha1Task, path), control) as string;
}

/** 有预算且可取消的 CF 文件计算，普通文件异常由公开包装层降级为 0。 */
export async function computeLocalModFingerprint(path: string, control?: LocalModScanControl): Promise<number> {
  return await runModFileTask(new taskpool.Task(fingerprintTask, path), control) as number;
}

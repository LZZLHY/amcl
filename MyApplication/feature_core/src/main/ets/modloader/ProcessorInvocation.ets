/**
 * processor 执行期间延续现有进度回调的取消契约。回调抛错时提交取消，但仍等待 Native
 * 真实退出回收，再向外抛回第一个错误；不靠 Promise.race 提前释放安装锁/清理工作目录。
 * 仅运行当前 processor 时存在定时器，finally 始终移除；无回调时不创建 ArkTS 定时器。
 */
import { ForgeNativeBridge } from './ForgelikeNative';
import { newVersionInstallOwner } from '../version/VersionInstallLease';

export async function invokeInstallerProcessor(bridge: ForgeNativeBridge, filesDir: string,
  major: string, xmxMb: number, classpath: string, mainClass: string, args: string[],
  workDir: string, logFile: string, checkProgress?: () => void, timeoutMs: number = 0): Promise<number> {
  if (checkProgress === undefined && timeoutMs === 0) {
    // 没有取消入口也没有截止的调用仍走原来的阻塞 waitpid，避免无消费者的轮询。
    return bridge.runJavaProcessor(filesDir, major, xmxMb, classpath, mainClass, args, workDir, logFile);
  }
  const requestId: string = 'processor-' + newVersionInstallOwner();
  let callbackError: Error | null = null;
  let timer: number = -1;
  if (checkProgress !== undefined) checkProgress();
  try {
    const running: Promise<number> = bridge.runJavaProcessor(filesDir, major, xmxMb, classpath, mainClass,
      args, workDir, logFile, requestId, timeoutMs);
    if (checkProgress !== undefined) {
      const inspect: () => void = checkProgress;
      timer = setInterval((): void => {
        if (callbackError === null) {
          try { inspect(); } catch (error) { callbackError = error as Error; }
        }
        if (callbackError !== null) {
          // 失败意图不可撤回。若暂时无法提交则下次重试；不能先向外抛错遗留正在写盘的VM。
          try { bridge.cancelJavaProcessor(requestId); } catch (error) { /* 原任务仍由 running 持有。 */ }
        }
      }, 250);
    }
    const result: number = await running;
    if (callbackError !== null) throw (callbackError as Error);
    return result;
  } catch (error) {
    // Native在停止/回收时失败也不得覆盖更早的取消/进度错误；它仍然已经结束了Promise。
    if (callbackError !== null) throw (callbackError as Error);
    throw (error as Error);
  } finally {
    if (timer >= 0) clearInterval(timer);
  }
}

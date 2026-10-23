/**
 * 版本目录写入租约：普通安装、整合包父任务及其基础版本子任务共享同一个所有者。
 * 同所有者允许嵌套，其他所有者立即得到可重试错误，避免跨类别任务互删半成品。
 * 持久恢复身份由整合包 pending 文件保存；本表仅负责当前进程的并发准入。
 */
interface VersionLease { owner: string; depth: number; }
let leases: Map<string, VersionLease> = new Map<string, VersionLease>();
let nextOwner: number = 0;
let processorTail: Promise<void> = Promise.resolve();

/**
 * 仅串行实际 JVM processor，不占住归档/依赖网络阶段。
 * Native fork 有 Fresh→fork 的原子准入窗口；同进程多个安装需排队，不能将 busy 当下载失败。
 * action 在拿到槽之后执行，因此调用方可在其中再次检查取消；异常同样释放后继任务。
 */
export async function withInstallerProcessorLock<T>(action: () => Promise<T>): Promise<T> {
  let release: () => void = (): void => {};
  let previous = processorTail;
  processorTail = new Promise<void>((resolve: () => void): void => { release = resolve; });
  await previous;
  try { return await action(); } finally { release(); }
}

/** 同一进程单调后缀保证快速创建的任务也不重名，重试继续使用对象原 owner。 */
export function newVersionInstallOwner(): string {
  nextOwner++;
  return Date.now().toString() + '-' + nextOwner.toString() + '-' + Math.floor(Math.random() * 1000000000).toString();
}

/** 获取租约并返回幂等释放函数；所有异常路径都必须在 finally 释放。 */
export function claimVersionInstall(mcDir: string, version: string, owner: string): () => void {
  let key = mcDir.replace(new RegExp('\\\\', 'g'), '/').replace(new RegExp('/+$'), '') + '/versions/' + version;
  let lease = leases.get(key);
  if (lease !== undefined && lease.owner !== owner) throw new Error('该版本目录正在被另一项安装使用');
  if (lease === undefined) { lease = { owner: owner, depth: 0 }; leases.set(key, lease); }
  lease.depth++;
  let released = false;
  return (): void => {
    if (released) return;
    released = true;
    let current = leases.get(key);
    if (current === undefined || current.owner !== owner) return;
    current.depth--;
    if (current.depth === 0) leases.delete(key);
  };
}

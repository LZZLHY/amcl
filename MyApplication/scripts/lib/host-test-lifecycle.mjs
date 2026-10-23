/**
 * 宿主回归的独占运行目录与资源收尾。只管理本进程亲自 mkdtemp 创建的目录，
 * 成功退出后先等待登记的异步资源结束再删除；失败或调试保留时留下完整现场。
 * 共享输出根、源码、SDK 构建缓存均不属于本模块的清理范围。
 */
import fs from 'node:fs';
import path from 'node:path';
import { assertExternalOutputPath, createWorkspaceTemp } from './workspace-paths.mjs';

const scopes = new Set();
let installed = false;

/**
 * 校验创建时的目录身份仍然成立。真实父目录、目录自身 inode/dev 和最终路径均需一致，
 * 防止外部替换目录或 junction 后，把递归删除导向其他任务或用户资料。
 */
function assertOwnedDirectory(directory, identity) {
  if (!path.isAbsolute(directory) || path.dirname(directory) !== identity.parent ||
      !path.basename(directory).startsWith(identity.prefix)) throw new Error('Host test cleanup ownership mismatch');
  const stat = fs.lstatSync(directory, { bigint: true });
  if (stat.isSymbolicLink() || !stat.isDirectory() || stat.dev !== identity.dev || stat.ino !== identity.ino ||
      fs.realpathSync(directory) !== identity.real || fs.realpathSync(identity.parent) !== identity.realParent) {
    throw new Error('Host test cleanup directory identity changed; evidence retained: ' + directory);
  }
  assertExternalOutputPath(directory);
}

/**
 * lstat 检查每个目录项：符号链接/junction 只删除链接本身，不进入目标。
 * 不接受任何调用方传入的删除路径；入口只能来自本模块捕获的 mkdtemp 返回值。
 */
function removeTreeNoFollow(directory) {
  for (const name of fs.readdirSync(directory)) {
    const entry = path.join(directory, name), stat = fs.lstatSync(entry);
    if (stat.isDirectory() && !stat.isSymbolicLink()) removeTreeNoFollow(entry);
    else fs.rmSync(entry, { force: true });
  }
  fs.rmdirSync(directory);
}

/**
 * 创建一次脚本独占的运行域。显式 parent 只是共享父目录，永远不会被递归删除。
 * defer 用于登记关闭连接、停止定时器、等待 Promise、关闭句柄等收尾，按登记顺序执行。
 * close 可供测试或显式 runner 使用；普通脚本由 beforeExit 自动调用。异常退出不触发删除。
 */
export function createHostTestScope(prefix, {
  parent = process.env.AMCL_TEST_OUTPUT_DIR || undefined, automatic = true, teardownTimeoutMs = 10000
} = {}) {
  if (!prefix || /[\\/]/.test(prefix) || prefix === '..') throw new Error('Invalid host test scope prefix');
  // ref'ed deadline 是 beforeExit 能可靠等到收尾结果的生命期保证；拒绝 0/NaN/溢出等会被 Node
  // 自动归一化的 timer 输入，测试可以显式缩短期限，正常运行默认最多等待十秒。
  if (!Number.isSafeInteger(teardownTimeoutMs) || teardownTimeoutMs < 1 || teardownTimeoutMs > 60000) {
    throw new Error('Host test teardownTimeoutMs must be an integer from 1 to 60000');
  }
  let directory;
  if (parent !== undefined) {
    if (!path.isAbsolute(parent)) throw new Error('Host test output parent must be absolute');
    parent = assertExternalOutputPath(parent); fs.mkdirSync(parent, { recursive: true });
    directory = fs.mkdtempSync(path.join(parent, prefix));
  } else directory = createWorkspaceTemp(prefix, { kind: 'run' });
  const stat = fs.lstatSync(directory, { bigint: true });
  const identity = { parent: path.dirname(directory), realParent: fs.realpathSync(path.dirname(directory)),
    real: fs.realpathSync(directory), prefix, dev: stat.dev, ino: stat.ino };
  const teardowns = [];
  let closing;
  const scope = {
    directory,
    /** 收尾函数必须返回其异步工作；已经开始关闭后不能再登记新资源。 */
    defer(teardown) {
      if (closing || typeof teardown !== 'function') throw new Error('Host test scope already closing or invalid teardown');
      teardowns.push(teardown);
    },
    /** 清理失败同样保留目录并让本次回归失败，不能假报成功或吞掉 Windows 句柄错误。 */
    close({ success = true } = {}) {
      if (!closing) closing = (async () => {
        const keep = process.env.AMCL_KEEP_TEST_OUTPUT === '1';
        if (!success || keep) {
          // 失败和调试现场必须保持断言结束时的 journal/文件内容；cancel 或放行 gate 本身会
          // 推进生产状态，因此此处连业务收尾也跳过。进程退出由 OS 回收句柄，不改写证据。
          console.log('Host test evidence retained (' + (keep ? 'AMCL_KEEP_TEST_OUTPUT=1' : 'failed run') + '): ' + directory);
          return;
        }
        let deadline;
        try {
          // Promise 本身不保持 Node 事件循环存活；此 timer 必须保持默认 ref 状态。即使某个
          // defer 等待永不落定且没有任何 OS handle 的 Promise，也会超时报错并保留现场。
          await Promise.race([
            (async () => { for (const teardown of teardowns) await teardown(); })(),
            new Promise((_, reject) => {
              deadline = setTimeout(() => reject(new Error('Host test teardown timed out after ' +
                teardownTimeoutMs + 'ms; evidence retained: ' + directory)), teardownTimeoutMs);
            })
          ]);
        } finally {
          // 正常收尾与失败均及时释放 deadline；成功测试不能因为十秒保护 timer 额外驻留。
          clearTimeout(deadline);
        }
        assertOwnedDirectory(directory, identity);
        removeTreeNoFollow(directory);
        scopes.delete(scope);
      })();
      return closing;
    }
  };
  if (automatic) {
    scopes.add(scope);
    if (!installed) {
      installed = true;
      // beforeExit 在主脚本及正常事件队列完成后执行；不要在 exit 中启动无法等待的异步清理。
      // once 避免收尾产生的事件再触发第二轮，也不使用固定延时猜测用例已经结束。
      process.once('beforeExit', async code => {
        for (const pending of scopes) {
          try { await pending.close({ success: code === 0 && !process.exitCode }); }
          catch (error) { console.error('Host test teardown failed; evidence retained:', error); process.exitCode = 1; }
        }
      });
    }
  }
  return scope;
}

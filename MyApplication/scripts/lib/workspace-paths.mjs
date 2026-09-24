/**
 * 宿主运行资料的唯一落盘策略。工程源码与 SDK 原生输出不经过本模块；自建日志、
 * 测试夹具、Native 构建树必须在工作区 .workspace 或仓库外的系统临时目录。
 * 解析只返回路径，不创建目录，也不修改全局环境变量或删除旧资料。
 */
import { existsSync, mkdirSync, mkdtempSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROJECT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const RUN_STAMP = `${new Date().toISOString().replace(/[-:]/g, '').slice(0, 15)}-${process.pid}`;

/** 解析最近存在的祖先，防止 junction/symlink 把看似外置的路径重新导回源码仓库。 */
function physicalPath(value) {
  let ancestor = path.resolve(value);
  const suffix = [];
  while (!existsSync(ancestor)) {
    const parent = path.dirname(ancestor);
    if (parent === ancestor) break;
    suffix.unshift(path.basename(ancestor));
    ancestor = parent;
  }
  return path.resolve(existsSync(ancestor) ? realpathSync(ancestor) : ancestor, ...suffix);
}

function inside(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

/** 显式路径也必须外置；既保护当前工程，也保护公开快照外层仓库及其他现有 Git 项目。 */
export function assertExternalOutputPath(value, { root = PROJECT_ROOT } = {}) {
  const candidate = physicalPath(value);
  const project = physicalPath(root);
  if (inside(project, candidate)) throw new Error(`Output must be outside the project: ${value}`);
  for (let current = candidate; ; current = path.dirname(current)) {
    if (existsSync(path.join(current, '.git'))) {
      throw new Error(`Output must be outside Git repositories: ${value}`);
    }
    if (path.dirname(current) === current) break;
  }
  return path.resolve(value);
}

/** 使用显式工作区优先；只有同时有 .workspace 与根规则/规划标记的祖先才自动认作工作区。 */
function workspaceRoot(root, env) {
  if (env.AMCL_WORKSPACE_ROOT) {
    if (!path.isAbsolute(env.AMCL_WORKSPACE_ROOT)) throw new Error('AMCL_WORKSPACE_ROOT must be absolute');
    return path.resolve(env.AMCL_WORKSPACE_ROOT);
  }
  for (let current = path.dirname(root); ; current = path.dirname(current)) {
    if (existsSync(path.join(current, '.workspace')) &&
        (existsSync(path.join(current, 'AGENTS.md')) || existsSync(path.join(current, 'WORKSPACE-ORGANIZATION-PLAN.md')))) {
      return current;
    }
    if (path.dirname(current) === current) return null;
  }
}

function checkedId(id) {
  if (!/^[a-z0-9][a-z0-9-]{0,47}$/i.test(id) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i.test(id)) {
    throw new Error(`Invalid short workspace id: ${id}`);
  }
  return id;
}

/**
 * kind=build/wt 的目录按工程真实绝对路径哈希隔离，便于跨进程复用缓存且不混用不同克隆。
 * kind=run 默认每次进程独立；AMCL_RUN_DIR 可将多条命令归入同一显式任务目录。
 * 独立克隆/CI 没有本机工作区时使用系统临时容器；系统 TMP 若被设到仓内会明确失败。
 */
export function resolveWorkspacePath(kind, id, { root = PROJECT_ROOT, env = process.env } = {}) {
  if (!['run', 'build', 'wt'].includes(kind)) throw new Error(`Invalid workspace kind: ${kind}`);
  checkedId(id);
  root = physicalPath(root);
  const identity = process.platform === 'win32' ? root.toLowerCase() : root;
  const checkout = createHash('sha256').update(identity).digest('hex').slice(0, 8);
  const workspace = workspaceRoot(root, env);
  const container = workspace ? path.join(workspace, '.workspace') : path.join(os.tmpdir(), 'amcl-workspace');
  let output;
  if (kind === 'run' && env.AMCL_RUN_DIR) {
    if (!path.isAbsolute(env.AMCL_RUN_DIR)) throw new Error('AMCL_RUN_DIR must be absolute');
    output = path.join(env.AMCL_RUN_DIR, id);
  } else {
    output = path.join(container, kind, `${id}-${checkout}${kind === 'run' ? `-${RUN_STAMP}` : ''}`);
  }
  return assertExternalOutputPath(output, { root });
}

/** 各调用者只追加受控相对文件名；不允许通过绝对路径或 .. 绕过上述边界。 */
export function workspacePath(kind, id, ...parts) {
  for (const part of parts) {
    if (path.isAbsolute(part) || part.split(/[\\/]/).includes('..')) throw new Error(`Invalid output suffix: ${part}`);
  }
  return assertExternalOutputPath(path.join(resolveWorkspacePath(kind, id), ...parts));
}

/** 返回宿主测试临时目录的父目录。清理由创建该临时子目录的测试负责，不能删除整个共享父目录。 */
export function workspaceTempRoot() {
  const directory = workspacePath('build', 'host-tests');
  mkdirSync(directory, { recursive: true });
  return directory;
}

/** 独占目录防止并行测试覆盖；前缀仍由调用者决定，便于对应已有清理边界检查。 */
export function createWorkspaceTemp(prefix, { kind = 'build', root = PROJECT_ROOT } = {}) {
  if (!prefix || /[\\/]/.test(prefix) || prefix === '..') throw new Error('Invalid temporary directory prefix');
  const directory = resolveWorkspacePath(kind, 'host-tests', { root });
  mkdirSync(directory, { recursive: true });
  return mkdtempSync(path.join(directory, prefix));
}

// PowerShell 通过此 CLI 复用策略；Python/WSL 使用等价的独立实现，并由跨语言测试防止漂移。
// 参数是独立 argv，避免 shell 拼接。
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [kind, id, root = PROJECT_ROOT, explicit] = process.argv.slice(2);
    console.log(explicit ? assertExternalOutputPath(explicit, { root }) : resolveWorkspacePath(kind, id, { root }));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

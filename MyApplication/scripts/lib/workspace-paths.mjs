/**
 * 宿主运行资料的唯一落盘策略。工程源码与 SDK 原生输出不经过本模块；自建日志、
 * 测试夹具、Native 构建树必须在工作区 .workspace 或仓库外的系统临时目录。
 * 解析只返回路径，不创建目录，也不修改全局环境变量或删除旧资料。
 */
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
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

/** 最近的真实工作区管理路由；独立公开克隆没有标记时仍保留系统临时目录退路。 */
function discoveredWorkspaceRoot(root) {
  for (let current = path.dirname(root); ; current = path.dirname(current)) {
    if (existsSync(path.join(current, '.workspace')) &&
        (existsSync(path.join(current, 'AGENTS.md')) || existsSync(path.join(current, 'WORKSPACE-ORGANIZATION-PLAN.md')))) {
      return current;
    }
    if (path.dirname(current) === current) return null;
  }
}

/** 显式环境只选择本轮输出容器，不抹掉工程最近工作区现行的存储路由。 */
function workspaceRoot(discovered, env) {
  if (!env.AMCL_WORKSPACE_ROOT) return discovered;
  if (!path.isAbsolute(env.AMCL_WORKSPACE_ROOT)) throw new Error('AMCL_WORKSPACE_ROOT must be absolute');
  return path.resolve(env.AMCL_WORKSPACE_ROOT);
}

/** Windows 盘符清单供 WSL 共用；只调用实际 wslpath，不猜测发行版的挂载前缀。 */
function nativeStorageRoot(value, name) {
  if (typeof value !== 'string') throw new Error(`${name} must be absolute`);
  if (path.isAbsolute(value)) return path.resolve(value);
  if (process.platform !== 'linux' || !/^[a-z]:[\\/]/i.test(value)) throw new Error(`${name} must be a native absolute path`);
  const converted = spawnSync('wslpath', ['-u', value], { encoding: 'utf8', timeout: 5000 });
  if (converted.error || converted.status !== 0) throw new Error(`${name}: Windows drive routing requires working wslpath: ${converted.error?.message ?? converted.stderr?.trim()}`);
  const native = converted.stdout.trim();
  if (!native || /[\r\n]/.test(native) || !path.isAbsolute(native)) throw new Error(`${name}: wslpath did not return one native absolute path`);
  return path.resolve(native);
}

/**
 * 只映射本次新算出的路径，不移动历史目录，也不修改全局 TEMP/环境。
 * 路由文件存在但损坏时必须失败，不能悄悄把新输出写回 canonical。外部显式容器
 * 不在 canonical 中则保持原值；显式 --out 仍由 assertExternalOutputPath 单独处理。
 */
function routeNewOutput(output, workspace, root) {
  if (!workspace) return output;
  const filename = path.join(workspace, '.workspace/storage-routing.json');
  // existsSync 会把访问拒绝也压成 false；只有确实没有文件才允许采用原策略。
  try { lstatSync(filename); }
  catch (error) {
    if (error.code === 'ENOENT') return output;
    throw new Error(`Invalid storage routing (${filename}): ${error.message}`);
  }
  try {
    const routing = JSON.parse(readFileSync(filename, 'utf8').replace(/^\uFEFF/, ''));
    if (!routing || Array.isArray(routing) || routing.schemaVersion !== 1 ||
        typeof routing.status !== 'string' || !routing.status.trim()) throw new Error('invalid schema/status');
    if (routing.status === 'INACTIVE' || routing.status.startsWith('INACTIVE_')) return output;
    if (routing.status !== 'ACTIVE' && !routing.status.startsWith('ACTIVE_')) throw new Error('unknown routing status');
    const canonical = nativeStorageRoot(routing.canonicalStorageRoot, 'canonicalStorageRoot');
    // 交接期旧资源/控制记录仍可留E，但本轮新资料明确以newOutputStorageRoot为准。
    // 没有新字段的旧清单继续遵守newStorageRoot，不把兼容控制根当新输出目的地。
    const hasOutputRoot = routing.newOutputStorageRoot !== undefined && routing.newOutputStorageRoot !== null;
    const destination = nativeStorageRoot(routing.newOutputStorageRoot ?? routing.newStorageRoot,
      hasOutputRoot ? 'newOutputStorageRoot' : 'newStorageRoot');
    const canonicalPhysical = physicalPath(canonical), destinationPhysical = physicalPath(destination);
    if (path.relative(canonicalPhysical, physicalPath(path.join(workspace, '.workspace'))) !== '') throw new Error('canonicalStorageRoot does not match workspace');
    // 用户显式将新资料恢复到canonical时允许完全相同的物理/声明根；仍拒绝嵌套根和
    // 通过别名重叠的其它组合，后续最终子路径的物理逃逸检查保持原样。
    const explicitCanonical = hasOutputRoot && path.relative(canonical, destination) === '' &&
      path.relative(canonicalPhysical, destinationPhysical) === '';
    if (!explicitCanonical && (inside(canonicalPhysical, destinationPhysical) || inside(destinationPhysical, canonicalPhysical)))
      throw new Error('storage roots must be disjoint');
    assertExternalOutputPath(destination, { root });
    // 用规范化的路径名判断路由，再对实际目的地做原有物理边界检查；不追随旧目录中的链接复制内容。
    if (!inside(canonical, output)) return output;
    const mapped = path.join(destination, path.relative(canonical, output));
    if (!inside(destinationPhysical, physicalPath(mapped))) throw new Error('routed output escapes newStorageRoot');
    return mapped;
  } catch (error) {
    throw new Error(`Invalid storage routing (${filename}): ${error.message}`);
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
function resolveOutputWithSuffix(kind, id, { root = PROJECT_ROOT, env = process.env } = {}, parts = []) {
  if (!['run', 'build', 'wt'].includes(kind)) throw new Error(`Invalid workspace kind: ${kind}`);
  checkedId(id);
  root = physicalPath(root);
  const identity = process.platform === 'win32' ? root.toLowerCase() : root;
  const checkout = createHash('sha256').update(identity).digest('hex').slice(0, 8);
  const discovered = discoveredWorkspaceRoot(root);
  const workspace = workspaceRoot(discovered, env);
  const container = workspace ? path.join(workspace, '.workspace') : path.join(os.tmpdir(), 'amcl-workspace');
  let output;
  if (kind === 'run' && env.AMCL_RUN_DIR) {
    if (!path.isAbsolute(env.AMCL_RUN_DIR)) throw new Error('AMCL_RUN_DIR must be absolute');
    output = path.join(env.AMCL_RUN_DIR, id);
  } else {
    output = path.join(container, kind, `${id}-${checkout}${kind === 'run' ? `-${RUN_STAMP}` : ''}`);
  }
  // 必须先拼接最终子路径再检查物理路由边界。若只检查任务目录，后续 suffix 中的
  // junction 可把仓外输出重新导回 canonical；普通仓外检查无法识别这种旧盘回流。
  return assertExternalOutputPath(routeNewOutput(path.join(output, ...parts), discovered ?? workspace, root), { root });
}

/** 只解析任务根目录；与追加 suffix 的入口共用同一次最终物理边界检查。 */
export function resolveWorkspacePath(kind, id, options) {
  return resolveOutputWithSuffix(kind, id, options);
}

/** 各调用者只追加受控相对文件名；不允许通过绝对路径或 .. 绕过上述边界。 */
export function workspacePath(kind, id, ...parts) {
  for (const part of parts) {
    if (path.isAbsolute(part) || part.split(/[\\/]/).includes('..')) throw new Error(`Invalid output suffix: ${part}`);
  }
  return resolveOutputWithSuffix(kind, id, undefined, parts);
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

/**
 * 导出私有工作目录的创建边界。调用方仍持有原导出owner并等待本Promise；此处只合并
 * 可信根以下每一层的在途mkdir，不缓存“目录永远安全”的结论，不删除占位，也不接管
 * 取消或下载。逐级单层mkdir避免先跟随稳定存在的祖先链接再创建后代；它不是Native
 * trusted-fd锁，仍不能消除核验后被其它线程恶意替换祖先的TOCTOU。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 只记录在途操作；完成或失败都会移除，下次使用前重新核验普通目录身份。 */
const pendingDirectories: Map<string, Promise<void>> = new Map<string, Promise<void>>();

/** FileIO原错误保留数值code，并补充实际操作/目录；不把私有路径写入归档内容。 */
export class ExportDirectoryError extends Error {
  readonly code: number;
  readonly operation: string;
  readonly directory: string;

  constructor(directory: string, operation: string, error: Object) {
    const native = error as BusinessError;
    const code = typeof native.code === 'number' ? native.code : 0;
    const detail = (error as Error).message || String(error);
    super('准备导出目录失败 [' + operation + ', code=' + code.toString() + '] ' + directory + ': ' + detail);
    this.name = 'ExportDirectoryError';
    this.code = code; this.operation = operation; this.directory = directory;
  }
}

/**
 * lstat不跟随末端链接。只有ENOENT代表尚未创建；权限、设备和磁盘错误都保持失败，
 * 文件/链接占位也不能被“目录存在”掩盖。本函数不承诺Native trusted-fd级的路径锁。
 */
async function isPlainDirectory(path: string): Promise<boolean> {
  let stat: fs.Stat;
  try { stat = await fs.lstat(path); }
  catch (error) {
    if ((error as BusinessError).code === 13900002) return false;
    throw new ExportDirectoryError(path, 'lstat', error as Object);
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new ExportDirectoryError(path, 'verify', new Error('目标已被文件、链接或非目录占用'));
  }
  return true;
}

/**
 * 输入必须是规范绝对路径，保留调用方已经选定的沙箱映射，不自行realpath或折叠点段。
 * 仅去掉末尾斜杠便于根比较；拒绝空段、反斜杠、点段与控制字符，不把逃逸路径“修好”。
 * 不把根目录/作为导出锚点，避免调用方意外把范围扩大为整个文件系统。
 */
function directoryPath(value: string): string {
  let path = value;
  while (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
  if (!path.startsWith('/') || path === '/' || path.indexOf('\\') >= 0 || /[\u0000-\u001f\u007f]/.test(path)
    || path.substring(1).split('/').some((part: string): boolean => part.length === 0 || part === '.' || part === '..')) {
    throw new ExportDirectoryError(value, 'boundary', new Error('目录必须是可信根内的规范绝对路径'));
  }
  return path;
}

/**
 * 父目录已由当前调用链逐级核验后，只创建一层。新建成功及EEXIST都重新lstat；只有
 * 实际普通目录才算满足，其它mkdir错误继续失败。递归mkdir不能替代祖先no-follow检查。
 */
async function createDirectoryComponent(path: string): Promise<void> {
  if (await isPlainDirectory(path)) return;
  try { await fs.mkdir(path); }
  catch (error) {
    if ((error as BusinessError).code !== 13900015) {
      throw new ExportDirectoryError(path, 'mkdir', error as Object);
    }
  }
  if (!(await isPlainDirectory(path))) {
    throw new ExportDirectoryError(path, 'verify', new Error('创建操作结束后目录仍不存在'));
  }
}

/**
 * 每个根/组成目录独立归集，两个不同叶子也会等待同一个共享祖先。根进入key，不能借
 * 另一个较宽根下的在途核验跳过当前边界；完成/失败后撤销登记，下次重新核验。
 */
async function ensureDirectoryComponent(path: string, trustedRoot: string): Promise<void> {
  const key = trustedRoot + '\n' + path;
  const previous = pendingDirectories.get(key);
  if (previous !== undefined) return previous;
  const pending = createDirectoryComponent(path);
  pendingDirectories.set(key, pending);
  try { await pending; }
  finally { if (pendingDirectories.get(key) === pending) pendingDirectories.delete(key); }
}

/**
 * trustedRoot由调用方明确提供且必须已经存在。只核验锚点及其以下，不能从/开始把平台
 * 沙箱映射祖先当作应用自行创建的目录。先检查边界，再按序核验/创建每个分量；遇到
 * 稳定存在的祖先文件或链接立即拒绝，绝不通过它lstat叶子或写入链接目标。调用方必须
 * 等本Promise实际结束，取消不能提前释放外层owner；本函数不持久化、不删除任何目录。
 */
export async function ensureExportDirectory(path: string, trustedRoot: string): Promise<void> {
  const target = directoryPath(path);
  const root = directoryPath(trustedRoot);
  if (target !== root && !target.startsWith(root + '/')) {
    throw new ExportDirectoryError(path, 'boundary', new Error('目标目录不在本次可信私有根内'));
  }
  if (!(await isPlainDirectory(root))) {
    throw new ExportDirectoryError(root, 'root', new Error('可信私有根不存在，不能自动扩大创建范围'));
  }
  if (target === root) return;
  let current = root;
  for (const part of target.substring(root.length + 1).split('/')) {
    current += '/' + part;
    await ensureDirectoryComponent(current, root);
  }
}

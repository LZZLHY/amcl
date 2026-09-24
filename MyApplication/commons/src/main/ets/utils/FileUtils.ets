/**
 * FileUtils.ets — 文件操作工具
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const INSTALL_COMMIT_MARKER: string = '.amcl-install-complete';

/**
 * 统一的版本安装检测标准。
 * 新安装必须存在 durable commit marker、jar > 1MiB、json 非空；旧版本为兼容历史
 * 仍允许 jar+json，但新流水线只在全部阶段成功后写 marker。
 */
export function isVersionInstalled(mcDir: string, versionId: string): boolean {
  let versionDir = mcDir + '/versions/' + versionId;
  let jarPath = versionDir + '/' + versionId + '.jar';
  let jsonPath = versionDir + '/' + versionId + '.json';
  try {
    let jar = fs.statSync(jarPath);
    let json = fs.statSync(jsonPath);
    if (!jar.isFile() || !json.isFile() || jar.size <= 1024 * 1024 || json.size <= 0) return false;
    try {
      let marker = fs.statSync(versionDir + '/' + INSTALL_COMMIT_MARKER);
      return marker.isFile() && marker.size > 0;
    } catch (markerError) {
      // 历史安装没有 marker：保留兼容，但不能把只有 jar 的残留算完整。
      return true;
    }
  } catch (e) {
    return false;
  }
}

export function writeVersionInstallCommit(mcDir: string, versionId: string): void {
  let versionDir = mcDir + '/versions/' + versionId;
  let markerPath = versionDir + '/' + INSTALL_COMMIT_MARKER;
  let tempPath = markerPath + '.tmp-' + Date.now().toString();
  let file: fs.File | null = null;
  try {
    file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, 'amcl-install-v1\n');
    fs.fsyncSync(file.fd);
    fs.closeSync(file);
    file = null;
    fs.renameSync(tempPath, markerPath);
    let dir = fs.openSync(versionDir, fs.OpenMode.READ_ONLY);
    try { fs.fsyncSync(dir.fd); } finally { fs.closeSync(dir); }
  } catch (e) {
    if (file) { try { fs.closeSync(file); } catch (closeError) { /* */ } }
    try { fs.unlinkSync(tempPath); } catch (cleanupError) { /* */ }
    throw e as Error;
  }
}

export function removeVersionInstallCommit(mcDir: string, versionId: string): void {
  try { fs.unlinkSync(mcDir + '/versions/' + versionId + '/' + INSTALL_COMMIT_MARKER); }
  catch (e) { /* absent */ }
}

/**
 * 幂等递归建目录：目录已存在 = 成功；路径被非目录占用 = 抛错。
 *
 * ⚠️ 背景（2026-07-28 真机定位，JDK 下载点击即失败）：
 *   `fs.mkdirSync(path, true)` 的 recursion **只作用于中间层级**，当【目标目录本身】
 *   已存在时仍抛 EEXIST（"File exists"）。项目里 30+ 处调用点全都靠
 *   `catch (e) { /* exists *\/ }` 吞掉，唯独 JdkInstaller 直接 rethrow，于是
 *   `filesDir/jdk` 一旦存在（任何装过一次 JDK 的设备都存在），第二次下载任何版本的 JDK
 *   都会在**下载开始之前**以 "下载失败: File exists" 终止，UI 无任何进度。
 *
 * 收敛成本函数的意义：
 *   - 语义单一事实源，避免各调用点 catch 语义漂移（有的吞、有的抛）
 *   - 仍然把真错误暴露出来：权限不足 / 磁盘满 / 路径被普通文件占用
 *   - stat→mkdir 之间的并发竞争按"已成为目录即成功"处理（多任务并发建同一父目录）
 */
export function ensureDirSync(dirPath: string): void {
  if (dirPath.length === 0) throw new Error('ensureDirSync: 目录路径为空');
  if (isExistingDirectory(dirPath)) return;
  // 路径存在但不是目录（普通文件 / 链接）：不能静默当成功，否则后续写入会以更难懂的错误失败。
  if (pathExists(dirPath)) throw new Error('ensureDirSync: 路径已被非目录占用: ' + dirPath);
  try {
    fs.mkdirSync(dirPath, true);
  } catch (e) {
    // 竞争或 EEXIST：只要现在已经是目录就算成功，否则把原始错误抛给调用方。
    if (isExistingDirectory(dirPath)) return;
    throw e as Error;
  }
}

/** 路径是否为已存在的目录。不存在 / 不是目录都返回 false，不抛错。 */
function isExistingDirectory(path: string): boolean {
  try { return fs.statSync(path).isDirectory(); } catch (e) { return false; }
}

/** 路径是否已存在（任意类型：文件 / 目录 / 链接）。不抛错。 */
function pathExists(path: string): boolean {
  try { fs.statSync(path); return true; } catch (e) { return false; }
}

/**
 * 递归删除目录
 */
export function removeDirRecursive(dirPath: string): void {
  try {
    let files = fs.listFileSync(dirPath)
    for (let file of files) {
      let fullPath = dirPath + '/' + file
      try {
        // lstatSync 不跟随符号链接：若用 statSync，指向目录的 symlink 会被判为目录并递归删除
        // 链接目标（可能在 dirPath 之外）。清理解压出的不可信内容时这会造成越界删除。
        let stat = fs.lstatSync(fullPath)
        if (stat.isSymbolicLink()) {
          fs.unlinkSync(fullPath)
        } else if (stat.isDirectory()) {
          removeDirRecursive(fullPath)
        } else {
          fs.unlinkSync(fullPath)
        }
      } catch (e) {
        // 忽略单个文件删除失败
      }
    }
    fs.rmdirSync(dirPath)
  } catch (e) {
    // 忽略
  }
}

/**
 * 检查文件是否存在且非空（size > 0）。
 *
 * 工程注意：本函数曾在 ForgeInstallerUtils 内定义（功能与 utils 模块归属不符），
 * 2026-05-06 收敛到 FileUtils。所有调用方应从 utils/FileUtils 导入。
 */
export function fileExistsAndNonEmpty(path: string): boolean {
  try {
    let st = fs.statSync(path);
    return st.size > 0;
  } catch (e) {
    return false;
  }
}

/**
 * 同步写文本文件（覆盖模式 / RW + CREATE + TRUNC）。
 *
 * 工程注意：原本在 VersionJsonMerger / PreparePhase / ModloaderPhase 各
 * 维护一份 private static writeTextFile（行为完全一致），2026-05-06 收敛
 * 到 FileUtils。所有写 .json / 文本 stub 的场景都应改用此函数。
 *
 * 失败时抛原生异常（fs / 文件系统层），调用方按需 try/catch。
 *
 * 2026-05-23 ArkTS 严格模式：fs.openSync / writeSync / closeSync 都会报
 * 'Function may throw'。包外层 try-catch + hilog + rethrow 保持原行为，
 * 只是多了一行可观测性日志。详见 docs/guides/api-migration-2026-05.md。
 */
export function writeTextFile(path: string, content: string): void {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, content);
  } catch (e) {
    hilog.warn(0x0000, 'FileUtils', 'writeTextFile %{public}s failed: %{public}s',
      path, (e as Error).message);
    throw e as Error;
  } finally {
    if (file) {
      try { fs.closeSync(file); } catch (_) { /* ignore close error */ }
    }
  }
}

/**
 * 版本重命名结果。ok=true 表示成功；否则 error 是可直接展示给用户的中文原因。
 */
export interface RenameVersionResult {
  ok: boolean;
  error: string;
}

// 版本目录名禁用字符（路径分隔符 + Windows/通用保留字符）。
// 不限制中文——本项目已统一按 UTF-8 处理路径，中文目录名是受支持的。
const ILLEGAL_VERSION_NAME_CHARS = /[\/\\:\*\?"<>\|]/;

/**
 * 校验用户输入的版本名能否作为 .minecraft/versions/ 下的目录名。
 * 仅做"文件系统安全 + 跨平台合理"的最小约束。
 *
 * @returns 空串 = 合法；否则返回可直接展示的中文错误原因。
 */
export function validateVersionName(name: string): string {
  let n = name.trim();
  if (n.length === 0) return '名称不能为空';
  if (n === '.' || n === '..') return '名称不合法';
  if (ILLEGAL_VERSION_NAME_CHARS.test(n)) return '名称不能包含 / \\ : * ? " < > |';
  if (n.endsWith('.') || n.endsWith(' ')) return '名称不能以空格或点结尾';
  if (n.length > 120) return '名称过长（≤120 字符）';
  return '';
}

/**
 * 把 version.json 顶层 "id" 字段从 oldId 改成 newId（best-effort，不抛）。
 *
 * 背景：MC 版本布局约定 版本目录名 == <id>.jar / <id>.json 文件名 == json 内的 "id" 字段
 * （HMCL / PCL / 官方启动器同此约定）。重命名时同步 id，保持版本自洽。
 * 注：JDK 路由已改为读 json 内容（clientVersion / patches 等，见 VersionParser.detectVanillaVersion），
 * 故即便此处失败也不影响"启动哪个 JDK"，仅影响版本元数据的自洽性，所以做成 best-effort。
 */
function rewriteVersionJsonId(jsonPath: string, oldId: string, newId: string): void {
  try {
    let content = fs.readTextSync(jsonPath);
    let obj = JSON.parse(content) as Record<string, Object>;
    if ((obj['id'] as string) === oldId) {
      obj['id'] = newId;
      writeTextFile(jsonPath, JSON.stringify(obj));
    }
  } catch (e) {
    hilog.warn(0x0000, 'FileUtils', 'rewriteVersionJsonId %{public}s failed (non-fatal): %{public}s',
      jsonPath, (e as Error).message);
  }
}

/**
 * 重命名一个已安装的 MC 版本目录（含内部 <id>.jar / <id>.json 与 json 的 id 字段）。
 *
 * 为什么不能只 rename 目录：启动链路（LaunchProfileBuilder / mc_launcher）按
 * `versions/<folder>/<folder>.jar|json` 定位文件——目录名与内部文件名必须一致，
 * 否则 scanVersions 会把它判为 orphan、无法启动。所以这里三者一起改。
 *
 * 隔离性说明：版本隔离模式下 mods/saves/config 等都在 versions/<id>/ 内，随目录
 * 整体 rename 一并迁移（同父目录 rename 是 O(1) 元数据操作，已由 SandboxProbe 实测确认）。
 *
 * 原子性：先整目录 rename，再改内部 jar/json；内部任一步失败则按逆序回滚，
 * 保证要么全部成功、要么完全回到改名前的可启动状态（不留半成品）。
 *
 * @param mcDir   .minecraft 根目录（不带尾部 /）
 * @param oldId   原版本目录名
 * @param newIdRaw 用户输入的新名称（内部会 trim）
 */
export function renameVersion(mcDir: string, oldId: string, newIdRaw: string): RenameVersionResult {
  let newId = newIdRaw.trim();

  // 1. 名称合法性 + 是否真的改了
  let nameErr = validateVersionName(newId);
  if (nameErr.length > 0) return { ok: false, error: nameErr };
  if (newId === oldId) return { ok: false, error: '新名称与原名称相同' };

  let versionsDir = mcDir + '/versions';
  let oldDir = versionsDir + '/' + oldId;
  let newDir = versionsDir + '/' + newId;

  // 2. 旧目录必须存在
  try {
    let st = fs.statSync(oldDir);
    if (!st.isDirectory()) return { ok: false, error: '原版本目录不存在' };
  } catch (e) {
    return { ok: false, error: '原版本目录不存在' };
  }

  // 3. 新目录不能已存在（避免覆盖/合并到别的版本）
  try {
    fs.statSync(newDir);
    return { ok: false, error: '已存在同名版本「' + newId + '」' };
  } catch (e) { /* 不存在，符合预期 */ }

  // 4. 整目录 rename
  try {
    fs.renameSync(oldDir, newDir);
  } catch (e) {
    return { ok: false, error: '重命名目录失败：' + (e as Error).message };
  }

  // 5. 同步内部 <id>.jar / <id>.json（失败则逆序回滚）
  let renamedJar = false;
  let renamedJsonPath = '';
  try {
    let oldJar = newDir + '/' + oldId + '.jar';
    if (fileExistsAndNonEmpty(oldJar)) {
      fs.renameSync(oldJar, newDir + '/' + newId + '.jar');
      renamedJar = true;
    }
    let oldJson = newDir + '/' + oldId + '.json';
    let jsonExists = false;
    try { fs.statSync(oldJson); jsonExists = true; } catch (e) { /* 无 json */ }
    if (jsonExists) {
      let newJson = newDir + '/' + newId + '.json';
      fs.renameSync(oldJson, newJson);
      renamedJsonPath = newJson;
    }
  } catch (e) {
    // 逆序回滚：先回滚已改名的 jar，再把目录改回原名
    if (renamedJar) {
      try { fs.renameSync(newDir + '/' + newId + '.jar', newDir + '/' + oldId + '.jar'); } catch (_) { /* 尽力 */ }
    }
    try { fs.renameSync(newDir, oldDir); } catch (_) { /* 尽力 */ }
    return { ok: false, error: '重命名内部文件失败：' + (e as Error).message };
  }

  // 6. 同步 json 内的 id 字段（best-effort，不影响成败）
  if (renamedJsonPath.length > 0) {
    rewriteVersionJsonId(renamedJsonPath, oldId, newId);
  }

  hilog.info(0x0000, 'FileUtils', 'renameVersion ok: %{public}s -> %{public}s', oldId, newId);
  return { ok: true, error: '' };
}

/**
 * 统计目录下匹配若干扩展名的文件数（不递归）。
 *
 * 用途：HomeTab Quick Stats、VersionManagerSheet 详情资源格、InstalledResourcesSheet 行数
 *      统一走这一份扫描，确保三处的"已装数量"语义一致。
 *
 * 行为：
 *   - 目录不存在 / 权限错误：返回 0，不抛
 *   - 大小写不敏感（filename → toLowerCase 再 endsWith）
 *   - 优先匹配最长扩展名，避免 `.jar.disabled` 既被 `.jar` 命中又被 `.jar.disabled` 命中
 *
 * @param dir 目标目录绝对路径，不带尾部 /
 * @param extensions 要计入的扩展名列表（如 ['.jar', '.jar.disabled']）。空数组返回 0。
 */
export function countFilesWithExtensions(dir: string, extensions: string[]): number {
  if (extensions.length === 0) return 0;
  let entries: string[] = [];
  try {
    entries = fs.listFileSync(dir);
  } catch (e) {
    return 0;
  }
  let count = 0;
  for (let name of entries) {
    let lower = name.toLowerCase();
    let bestExt = '';
    for (let ext of extensions) {
      if (lower.endsWith(ext) && ext.length > bestExt.length) bestExt = ext;
    }
    if (bestExt.length > 0) count++;
  }
  return count;
}

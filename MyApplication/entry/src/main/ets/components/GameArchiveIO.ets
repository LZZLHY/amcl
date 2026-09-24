/**
 * GameArchiveIO.ets — 游戏资源「导入 / 导出」工具（系统 picker + zlib + fileIo）
 *
 * 统一封装版本详情页里各资源板块的本地导入 / 导出能力：
 *   - importResourceFiles(): 模组 / 资源包 / 光影 / 数据包 —— 多选并逐项导入
 *   - importSaveZips():      存档 —— 多选 .zip，解压并整理成 saves/<世界名>/ 文件夹
 *   - exportSaveZip():       存档 —— 把 saves/<世界名>/ 打包成 .zip 让用户另存
 *
 * 设计要点：
 *   - 所有路径都基于调用方传入的目录（来自 mcDir，已是「沙箱 / 沙箱外」位置感知），
 *     因此沙箱外存档走同一套逻辑，无需特判。
 *   - picker 返回的是 file://docs/... uri，zlib.decompressFile 需要真实沙箱路径，
 *     故先把选中的 zip 用 fd 拷到 tempDir，再解压。
 *   - 不用 Record<string,Object> 字面量（ArkTS 严格模式禁），统一用显式 interface。
 *
 * 创建日期：见 CHANGELOG。
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { removeDirRecursive } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_UI } from 'commons';

const TAG = 'GameArchiveIO';

/** launched 仅表示系统接受启动请求，不代表已验证文件管理器最终定位的目录。 */
export interface OpenFolderResult {
  launched: boolean;
  message: string;
}

export interface ImportFailure {
  name: string;
  message: string;
}

export interface BatchImportResult {
  cancelled: boolean;
  names: string[];
  failures: ImportFailure[];
  message: string;
}

function batchResult(names: string[], failures: ImportFailure[], cancelled: boolean = false): BatchImportResult {
  let message = names.length > 0 ? `已导入 ${names.length} 个文件` : '没有文件导入成功';
  if (failures.length > 0) {
    message += `，${failures.length} 个失败：${failures[0].name} ${failures[0].message}`;
  }
  return { cancelled, names, failures, message: cancelled ? '' : message };
}

/** 导入结果。cancelled=true 表示用户在 picker 里取消，不算失败。 */
export interface ImportResult {
  ok: boolean;
  cancelled: boolean;
  /** 成功时为落地的文件名 / 世界名；失败时为空 */
  name: string;
  /** 失败原因（toast 用）；成功时为空 */
  message: string;
}

function okResult(name: string): ImportResult {
  return { ok: true, cancelled: false, name, message: '' };
}
function failResult(message: string): ImportResult {
  return { ok: false, cancelled: false, name: '', message };
}
function cancelledResult(): ImportResult {
  return { ok: false, cancelled: true, name: '', message: '' };
}

/** 从 picker uri 取末尾文件名（去掉 query，按 / 切，解码一次百分号转义）。 */
function basenameFromUri(uri: string): string {
  let u = uri;
  let q = u.indexOf('?');
  if (q >= 0) u = u.substring(0, q);
  let slash = u.lastIndexOf('/');
  let name = slash >= 0 ? u.substring(slash + 1) : u;
  try { name = decodeURIComponent(name); } catch (e) { /* 保留原值 */ }
  return name;
}

/** 去掉文件名扩展名（最后一个 .）。无扩展名则原样返回。 */
function stripExt(filename: string): string {
  let dot = filename.lastIndexOf('.');
  return dot > 0 ? filename.substring(0, dot) : filename;
}

/** 递归 mkdir；已存在不报错。 */
function ensureDir(dir: string): void {
  try { fs.mkdirSync(dir, true); } catch (e) {
    try { let st = fs.statSync(dir); if (st.isDirectory()) return; } catch (ee) { /* */ }
    throw new Error('mkdir failed: ' + (e as BusinessError).message);
  }
}

/** 路径是否存在。 */
function pathExists(p: string): boolean {
  try { fs.statSync(p); return true; } catch (e) { return false; }
}

/** 复制单个 picker uri 指向的文件到 destPath（用 fd，兼容 file://docs/ uri）。 */
function copyUriToPath(uri: string, destPath: string): void {
  let f: fs.File | null = null;
  try {
    f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    fs.copyFileSync(f.fd, destPath);
  } catch (e) {
    throw new Error('copy from uri failed: ' + (e as BusinessError).message);
  } finally {
    if (f !== null) {
      try { fs.closeSync(f); } catch (ee) { /* ignore close error */ }
    }
  }
}

/** 把 srcPath 文件内容写入 picker 另存 uri（用 fd）。 */
function copyPathToUri(srcPath: string, uri: string): void {
  let f: fs.File | null = null;
  try {
    f = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.copyFileSync(srcPath, f.fd);
  } catch (e) {
    throw new Error('copy to uri failed: ' + (e as BusinessError).message);
  } finally {
    if (f !== null) {
      try { fs.closeSync(f); } catch (ee) { /* ignore close error */ }
    }
  }
}

/** 把 srcDir 下的每个子项复制进 destDir（destDir 须已存在）。 */
async function copyTreeInto(srcDir: string, destDir: string): Promise<void> {
  ensureDir(destDir);
  let entries: string[] = [];
  entries = fs.listFileSync(srcDir);
  for (let name of entries) {
    let src = srcDir + '/' + name;
    try {
      let st = fs.statSync(src);
      if (st.isDirectory()) {
        await fs.copyDir(src, destDir, 1); // → destDir/<name>
      } else {
        fs.copyFileSync(src, destDir + '/' + name);
      }
    } catch (e) {
      AppLogger.warn(TAG, `copyTreeInto failed ${name}`, e, LOG_DOMAIN_UI);
      throw e as Error;
    }
  }
}

/** Promise 化 zlib.decompressFile（沿用 JdkInstaller 的 3 参回调形式 + 超时保护）。 */
function decompress(zipPath: string, destDir: string, timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    let timer = setTimeout(() => { reject(new Error('解压超时')); }, timeoutMs);
    try {
      zlib.decompressFile(zipPath, destDir, (err: BusinessError) => {
        clearTimeout(timer);
        if (err && err.code) reject(new Error(err.message)); else resolve();
      });
    } catch (e) {
      clearTimeout(timer);
      reject(e as Error);
    }
  });
}

/** Promise 化 zlib.compressFile（压缩目录或文件为 zip）。 */
function compress(srcPath: string, zipPath: string, timeoutMs: number): Promise<void> {
  let opts: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };
  return new Promise<void>((resolve, reject) => {
    let timer = setTimeout(() => { reject(new Error('压缩超时')); }, timeoutMs);
    try {
      zlib.compressFile(srcPath, zipPath, opts, (err: BusinessError) => {
        clearTimeout(timer);
        if (err && err.code) reject(new Error(err.message)); else resolve();
      });
    } catch (e) {
      clearTimeout(timer);
      reject(e as Error);
    }
  });
}

export class GameArchiveIO {
  /** 解压 / 压缩超时（存档可能较大，给 300s，与 JDK 解压一致）。 */
  private static readonly ZIP_TIMEOUT_MS = 300_000;

  /** JDK/整合包安装仍为单任务流程，不把多个安装包混入一次安装。 */
  static async importResourceFile(ctx: common.UIAbilityContext, targetDir: string,
    expectedExts: string[]): Promise<ImportResult> {
    const result = await GameArchiveIO.importResourceFiles(ctx, targetDir, expectedExts, 1);
    if (result.cancelled) return cancelledResult();
    return result.names.length > 0 ? okResult(result.names[0]) : failResult(result.message);
  }

  /**
   * 多选资源文件，逐项校验、导入；一次失败不阻断其他选中项。
   *
   * @param expectedExts 允许的小写扩展名（含点），如 ['.jar'] 或 ['.zip']
   */
  static async importResourceFiles(
    ctx: common.UIAbilityContext,
    targetDir: string,
    expectedExts: string[],
    maxSelectNumber: number = 500,
  ): Promise<BatchImportResult> {
    if (targetDir.length === 0) return batchResult([], [{ name: '', message: '目标目录无效' }]);
    let uris: string[] = [];
    try {
      let opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = maxSelectNumber;
      if (expectedExts.length > 0) opt.fileSuffixFilters = [expectedExts.join(',')];
      let dp = new picker.DocumentViewPicker(ctx);
      uris = await dp.select(opt);
    } catch (e) {
      return batchResult([], [{ name: '', message: '选择文件失败: ' + (e as BusinessError).message }]);
    }
    if (!uris || uris.length === 0) return batchResult([], [], true);
    const names: string[] = [];
    const failures: ImportFailure[] = [];
    for (let index = 0; index < uris.length; index++) {
      const uri = uris[index];
      const filename = basenameFromUri(uri);
      let temp = '';
      let source: fs.File | null = null;
      try {
        if (filename.length === 0 || filename === '.' || filename === '..' ||
          filename.includes('/') || filename.includes('\\') || filename.includes('\0')) {
          throw new Error('文件名无效');
        }
        if (expectedExts.length > 0 &&
          !expectedExts.some((ext: string) => filename.toLowerCase().endsWith(ext))) {
          throw new Error('文件类型不符，需要 ' + expectedExts.join(' / '));
        }
        ensureDir(targetDir);
        // staging 与目标位于同目录；源读取/复制失败时不触碰已有资源文件。
        temp = targetDir + '/.amcl-import-' + Date.now() + '-' + index + '-' + Math.random() + '.tmp';
        source = await fs.open(uri, fs.OpenMode.READ_ONLY);
        await fs.copyFile(source.fd, temp);
        await fs.rename(temp, targetDir + '/' + filename);
        temp = '';
        names.push(filename);
        AppLogger.info(TAG, `importResourceFiles imported=${names.length}/${uris.length} name=${filename}`, LOG_DOMAIN_UI);
      } catch (e) {
        const message = (e as BusinessError).message;
        failures.push({ name: filename, message });
        AppLogger.warn(TAG, `importResourceFiles failed name=${filename}`, e, LOG_DOMAIN_UI);
      } finally {
        if (source !== null) { try { fs.closeSync(source); } catch (e) { /* */ } }
        if (temp.length > 0) { try { fs.unlinkSync(temp); } catch (e) { /* */ } }
      }
    }
    AppLogger.info(TAG, `importResourceFiles completed selected=${uris.length} imported=${names.length} failed=${failures.length}`, LOG_DOMAIN_UI);
    return batchResult(names, failures);
  }

  /**
   * 导入存档：选 .zip → 解压 → 整理成 saves/<世界名>/（确保 level.dat 在世界根）。
   *
   * 兼容两种 zip 结构：
   *   - 顶层即世界内容（level.dat 在根）→ 世界名取自 zip 文件名
   *   - 顶层是单个世界文件夹（<世界>/level.dat）→ 世界名取自该文件夹
   * 名称冲突时自动追加 " (1)" / " (2)"。
   */
  static async importSaveZips(
    ctx: common.UIAbilityContext,
    savesDir: string,
  ): Promise<BatchImportResult> {
    if (savesDir.length === 0) return batchResult([], [{ name: '', message: '存档目录无效' }]);
    let uris: string[] = [];
    try {
      let opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 500;
      opt.fileSuffixFilters = ['.zip'];
      let dp = new picker.DocumentViewPicker(ctx);
      uris = await dp.select(opt);
    } catch (e) {
      return batchResult([], [{ name: '', message: '选择文件失败: ' + (e as BusinessError).message }]);
    }
    if (!uris || uris.length === 0) return batchResult([], [], true);
    const names: string[] = [];
    const failures: ImportFailure[] = [];
    for (const uri of uris) {
      const result = await GameArchiveIO.importSaveUri(ctx, savesDir, uri);
      if (result.ok) names.push(result.name);
      else failures.push({ name: basenameFromUri(uri), message: result.message });
    }
    return batchResult(names, failures);
  }

  private static async importSaveUri(ctx: common.UIAbilityContext, savesDir: string, uri: string): Promise<ImportResult> {
    let filename = basenameFromUri(uri);
    if (!filename.toLowerCase().endsWith('.zip')) {
      return failResult('存档需为 .zip 文件');
    }

    let stamp = Date.now().toString();
    let tmpZip = ctx.tempDir + '/amcl_save_' + stamp + '.zip';
    let tmpExtract = ctx.tempDir + '/amcl_save_x_' + stamp;
    let incompleteTarget = '';
    try {
      // 1. 选中的 zip 拷到沙箱临时路径（zlib 需要真实路径）
      copyUriToPath(uri, tmpZip);
      // 2. 解压到临时目录
      try { removeDirRecursive(tmpExtract); } catch (e) { /* */ }
      ensureDir(tmpExtract);
      await decompress(tmpZip, tmpExtract, GameArchiveIO.ZIP_TIMEOUT_MS);

      // 3. 定位世界根（含 level.dat 的目录）
      let worldRoot = GameArchiveIO.locateWorldRoot(tmpExtract);
      let defaultName = stripExt(filename);
      let worldName: string;
      if (worldRoot === tmpExtract) {
        worldName = defaultName;
      } else {
        // 取子文件夹名
        let slash = worldRoot.lastIndexOf('/');
        worldName = slash >= 0 ? worldRoot.substring(slash + 1) : defaultName;
      }
      worldName = GameArchiveIO.sanitizeName(worldName, defaultName);

      // 4. 落地：saves/<worldName>，冲突追加序号
      ensureDir(savesDir);
      let finalName = GameArchiveIO.uniqueName(savesDir, worldName);
      let target = savesDir + '/' + finalName;
      incompleteTarget = target;
      await copyTreeInto(worldRoot, target);

      // 5. 校验：level.dat 必须在世界根，否则视为无效存档
      if (!pathExists(target + '/level.dat')) {
        try { removeDirRecursive(target); } catch (e) { /* */ }
        return failResult('zip 内未找到 level.dat，不是有效的 MC 存档');
      }
      AppLogger.info(TAG, `importSaveZips -> ${target}`, LOG_DOMAIN_UI);
      incompleteTarget = '';
      return okResult(finalName);
    } catch (e) {
      return failResult('导入失败: ' + (e as BusinessError).message);
    } finally {
      if (incompleteTarget.length > 0) {
        try { removeDirRecursive(incompleteTarget); } catch (e) { /* */ }
      }
      try { fs.unlinkSync(tmpZip); } catch (e) { /* */ }
      try { removeDirRecursive(tmpExtract); } catch (e) { /* */ }
    }
  }

  /**
   * 导出存档：把 saves/<worldName>/ 压成 zip → 系统另存 picker 让用户选位置。
   * @returns true=已保存，false=用户取消
   */
  static async exportSaveZip(
    ctx: common.UIAbilityContext,
    savesDir: string,
    worldName: string,
  ): Promise<ImportResult> {
    let worldDir = savesDir + '/' + worldName;
    if (!pathExists(worldDir)) return failResult('存档不存在');

    let stamp = Date.now().toString();
    let tmpZip = ctx.tempDir + '/amcl_export_' + stamp + '.zip';
    try {
      try { fs.unlinkSync(tmpZip); } catch (e) { /* */ }
      // 1. 压缩世界目录到临时 zip
      await compress(worldDir, tmpZip, GameArchiveIO.ZIP_TIMEOUT_MS);

      // 2. 另存 picker
      let saveOpt = new picker.DocumentSaveOptions();
      saveOpt.newFileNames = [worldName + '.zip'];
      let dp = new picker.DocumentViewPicker(ctx);
      let result = await dp.save(saveOpt);
      if (!result || result.length === 0) return cancelledResult();

      // 3. 临时 zip 内容写入用户选定 uri
      copyPathToUri(tmpZip, result[0]);
      AppLogger.info(TAG, `exportSaveZip ${worldName} -> ${result[0]}`, LOG_DOMAIN_UI);
      return okResult(worldName);
    } catch (e) {
      return failResult('导出失败: ' + (e as BusinessError).message);
    } finally {
      try { fs.unlinkSync(tmpZip); } catch (e) { /* */ }
    }
  }

  /**
   * 导入任意文件到 targetDir（虚拟文件管理器用，无扩展名限制；同名覆盖）。
   */
  static async importAnyFiles(
    ctx: common.UIAbilityContext,
    targetDir: string,
  ): Promise<BatchImportResult> {
    return GameArchiveIO.importResourceFiles(ctx, targetDir, []);
  }

  /**
   * 导出单个文件：系统另存 picker，把 srcPath 写入用户选定位置。
   */
  static async exportFile(
    ctx: common.UIAbilityContext,
    srcPath: string,
    fileName: string,
  ): Promise<ImportResult> {
    if (!pathExists(srcPath)) return failResult('文件不存在');
    try {
      let saveOpt = new picker.DocumentSaveOptions();
      saveOpt.newFileNames = [fileName];
      let dp = new picker.DocumentViewPicker(ctx);
      let result = await dp.save(saveOpt);
      if (!result || result.length === 0) return cancelledResult();
      copyPathToUri(srcPath, result[0]);
      AppLogger.info(TAG, `exportFile ${fileName} -> ${result[0]}`, LOG_DOMAIN_UI);
      return okResult(fileName);
    } catch (e) {
      return failResult('导出失败: ' + (e as BusinessError).message);
    }
  }

  /**
   * 导出文件夹：压成 .zip → 系统另存 picker。
   */
  static async exportDirZip(
    ctx: common.UIAbilityContext,
    srcDir: string,
    dirName: string,
  ): Promise<ImportResult> {
    if (!pathExists(srcDir)) return failResult('文件夹不存在');
    let stamp = Date.now().toString();
    let tmpZip = ctx.tempDir + '/amcl_dir_' + stamp + '.zip';
    try {
      try { fs.unlinkSync(tmpZip); } catch (e) { /* */ }
      await compress(srcDir, tmpZip, GameArchiveIO.ZIP_TIMEOUT_MS);
      let saveOpt = new picker.DocumentSaveOptions();
      saveOpt.newFileNames = [dirName + '.zip'];
      let dp = new picker.DocumentViewPicker(ctx);
      let result = await dp.save(saveOpt);
      if (!result || result.length === 0) return cancelledResult();
      copyPathToUri(tmpZip, result[0]);
      AppLogger.info(TAG, `exportDirZip ${dirName} -> ${result[0]}`, LOG_DOMAIN_UI);
      return okResult(dirName);
    } catch (e) {
      return failResult('导出失败: ' + (e as BusinessError).message);
    } finally {
      try { fs.unlinkSync(tmpZip); } catch (e) { /* */ }
    }
  }

  /**
   * 拉起系统文件管理器浏览公共目录。DocumentViewPicker 仅用于导入/导出。
   * 当前未配置沙箱目录捐献，只接受公共文档 URI。
   * 目录不存在时先创建（便于用户提前进去放文件）。
   */
  static async openFolder(
    ctx: common.UIAbilityContext,
    dirPath: string,
  ): Promise<OpenFolderResult> {
    if (dirPath.length === 0) return { launched: false, message: '目录无效' };
    let uri = '';
    let stage = 'uri';
    try {
      uri = fileUri.getUriFromPath(dirPath);
      AppLogger.info(TAG, `openFolder request path=${dirPath} uri=${uri}`, LOG_DOMAIN_UI);
      if (!uri.startsWith('file://docs/')) {
        AppLogger.warn(TAG, `openFolder unsupported uri=${uri}`, undefined, LOG_DOMAIN_UI);
        return { launched: false, message: '此目录请使用应用内的“版本文件夹”查看' };
      }
      stage = 'directory';
      if (!pathExists(dirPath)) ensureDir(dirPath);
      if (!fs.statSync(dirPath).isDirectory()) {
        return { launched: false, message: '目标不是文件夹' };
      }
      const want: Want = {
        bundleName: 'com.huawei.hmos.filemanager',
        abilityName: 'MainAbility',
        parameters: { 'fileUri': uri },
      };
      stage = 'startAbility';
      await ctx.startAbility(want);
      AppLogger.info(TAG, `openFolder launchAccepted uri=${uri}`, LOG_DOMAIN_UI);
      return { launched: true, message: '' };
    } catch (e) {
      const err = e as BusinessError;
      AppLogger.warn(TAG, `openFolder failed stage=${stage} path=${dirPath} uri=${uri} code=${err.code}`,
        err, LOG_DOMAIN_UI);
      return { launched: false, message: stage === 'startAbility'
        ? '无法打开系统文件管理器，请使用应用内的“版本文件夹”'
        : '无法访问目录，请使用应用内的“版本文件夹”检查' };
    }
  }

  /**
   * 在解压目录里定位「世界根」：
   *   - root 直接含 level.dat → 返回 root
   *   - root 下恰有一个子目录且该子目录含 level.dat → 返回该子目录
   *   - 否则遍历一层子目录找第一个含 level.dat 的 → 返回它
   *   - 都没有 → 返回 root（由调用方做 level.dat 兜底校验）
   */
  private static locateWorldRoot(root: string): string {
    if (pathExists(root + '/level.dat')) return root;
    let entries: string[] = [];
    try { entries = fs.listFileSync(root); } catch (e) { return root; }
    let subDirs: string[] = [];
    for (let name of entries) {
      let p = root + '/' + name;
      try { if (fs.statSync(p).isDirectory()) subDirs.push(p); } catch (e) { /* */ }
    }
    for (let d of subDirs) {
      if (pathExists(d + '/level.dat')) return d;
    }
    return root;
  }

  /** 清理世界名里的非法路径字符；空则回退 fallback。 */
  private static sanitizeName(name: string, fallback: string): string {
    let n = name.replace(/[\/\\:*?"<>|]/g, '_').trim();
    if (n.length === 0) n = fallback;
    if (n.length === 0) n = 'world';
    return n;
  }

  /** 在 dir 下为 base 取一个不冲突的名字：base / base (1) / base (2) ... */
  private static uniqueName(dir: string, base: string): string {
    if (!pathExists(dir + '/' + base)) return base;
    for (let i = 1; i < 1000; i++) {
      let cand = base + ' (' + i + ')';
      if (!pathExists(dir + '/' + cand)) return cand;
    }
    return base + ' (' + Date.now() + ')';
  }
}

/**
 * GameStorage.ets — .minecraft 存储位置解析器（沙箱 / 沙箱外双结构）
 *
 * 单一来源（SSOT）：所有需要 .minecraft 根的地方都走 resolveMcDir(context, location)，
 * 不再各自硬编码 `filesDir + '/.minecraft'`。
 *
 *   - SANDBOX  : context.filesDir + '/.minecraft'（旧版默认、外部不可用时回退，卸载即删）
 *   - EXTERNAL : <Download>/com.amcl.launcher/.minecraft（包名文件夹 → 文件管理器显示为 AMCL 图标
 *                并进"来源"；卸载不丢）
 *
 * 设备能力分叉（canIUse FolderObtain；见 docs/adaptation/手机端沙箱外存储适配方案.md）：
 *   - 平板/2in1：Environment.getUserDownloadDir() 取 Download 根（实时），需 READ_WRITE_DOWNLOAD_DIRECTORY；
 *   - 手机：getUserDownloadDir 报 801 → 改用 DocumentViewPicker DOWNLOAD 模式（无弹窗）「学」一次
 *     公共应用目录路径，落盘 Preferences 后直接按原始路径用（native + ArkTS 均可，所有权式访问，
 *     跨重启有效，**无需 persist/activate**，由 PhoneStorageProbe 真机 NATIVE_RW_OK + 跨重启验证确认）。
 *
 * 版本隔离在两种根下完全一致：<root>/versions/<id>/...
 *
 * 运行时产物（JDK / amcl-launcher.jar / cacert / 日志 / forge-install-sandbox）始终留在沙箱
 * （filesDir），不随本解析器改变 —— 它们随安装重建，且 JDK .so 必须由 ELF loader 从沙箱加载。
 *
 * 同步契约：resolveMcDir / externalMcDir / isExternalAvailable 全同步、可在热路径调用。
 * 新安装首次准备外部目录后才交付实际根；已存在的位置始终优先，部署和扫描沿用同一结果。
 */

import { common, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Environment, fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { AppLogger } from 'commons';
import { PreferenceManager } from './PreferenceManager';
import { systemNative } from './SystemNativeBridge';

const TAG = 'GameStorage';
const DOWNLOAD_PERM: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY';

// 平板静默路线能力：能取到则走 Environment，取不到（手机）走 picker 学路径。
const SYSCAP_TABLET_SILENT = 'SystemCapability.FileManagement.File.Environment.FolderObtain';

// 外部公共目录里的应用文件夹名 = 包名。文件管理器会把"Docs/Download/<包名>"识别为已安装
// 应用，用 App 图标 + 标签("AMCL")显示，并自动列进"来源"侧栏（实测空的包名文件夹也会出现）。
// 早期用过自定义名 "AMCL"（不被识别、不进来源），migrateLegacyExternalFolder() 会一次性改名迁移。
const EXTERNAL_FOLDER = 'com.amcl.launcher';
const LEGACY_EXTERNAL_FOLDER = 'AMCL';

export enum StorageLocation {
  SANDBOX = 'sandbox',
  EXTERNAL = 'external',
}

export type ExternalStorageResult = 'ready' | 'permissionDenied' | 'unavailable';

/** 把持久化的字符串还原成枚举（未知值→沙箱） */
export function parseStorageLocation(s: string): StorageLocation {
  return s === StorageLocation.EXTERNAL ? StorageLocation.EXTERNAL : StorageLocation.SANDBOX;
}

export class GameStorage {
  // Download 根路径缓存（getUserDownloadDir 同一会话内不变；避免热路径反复 syscall/抛异常）
  private static cachedDownloadDir: string | null = null;

  // 手机端「学」到的外部应用目录（…/Download/com.amcl.launcher）。'' = 尚未学过。
  // 启动期由 EntryAbility 从 Preferences 注入；启用流程学到新值后即时再注入（本会话生效）。
  private static phoneExternalDir: string = '';

  /** 注入手机端缓存的外部应用目录（启动期 / 启用流程调用）。 */
  static setPhoneExternalDir(dir: string): void {
    GameStorage.phoneExternalDir = (dir && dir.length > 0) ? dir : '';
  }

  /** 平板静默路线是否可用（决定 externalAppDir 走 Environment 还是手机缓存路径）。 */
  static isTabletSilent(): boolean {
    return canIUse(SYSCAP_TABLET_SILENT);
  }

  /**
   * Download 沙箱映射根（如 /storage/Users/currentUser/Download）。
   * 设备不支持 / 取不到 → 返回 ''。结果缓存。仅平板路线使用。
   */
  static downloadDir(): string {
    if (GameStorage.cachedDownloadDir === null) {
      try {
        let d = Environment.getUserDownloadDir();
        GameStorage.cachedDownloadDir = (d && d.length > 0) ? d : null;
      } catch (e) {
        AppLogger.warn(TAG, 'getUserDownloadDir failed', e);
        GameStorage.cachedDownloadDir = null;
      }
    }
    return GameStorage.cachedDownloadDir !== null ? GameStorage.cachedDownloadDir : '';
  }

  /** 沙箱内 .minecraft 根 */
  static sandboxMcDir(context: common.Context): string {
    return context.filesDir + '/.minecraft';
  }

  /** 首装包管理记录的安装/更新时间相同；即使时间命中，已有或读不清的旧游戏根也沿用沙箱。 */
  static isFreshInstall(context: common.UIAbilityContext): boolean {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (!Number.isSafeInteger(info.installTime) || info.installTime <= 0 || info.installTime !== info.updateTime) return false;
    } catch (error) {
      AppLogger.warn(TAG, 'Bundle installation history unavailable; retaining private game directory', error);
      return false;
    }
    try {
      fs.lstatSync(GameStorage.sandboxMcDir(context));
      return false;
    } catch (error) {
      // 只有文件 API 的明确 ENOENT 才代表没有旧根；包信息失败或其他 I/O 错误保守处理。
      return (error as BusinessError).code === 13900002;
    }
  }

  /** 目录创建/枚举与实际游戏用的 POSIX 读写都要成功；探针只使用自己的临时文件。 */
  static verifyExternalRoot(): boolean {
    const root = GameStorage.externalMcDir();
    if (!root) return false;
    try {
      try { fs.mkdirSync(root, true); } catch (error) {
        if ((error as BusinessError).code !== 13900015) throw error as Error;
      }
      fs.listFileSync(root, { listNum: 1 });
      return systemNative().verifyGameDirectoryWritable(root);
    } catch (error) {
      AppLogger.warn(TAG, 'External game directory read/write check failed', error);
      return false;
    }
  }

  /** 首次/设置切换可请求下载权限，已选外部在冷启动只复核已有授权。先接续旧目录再创建新根。 */
  static async prepareExternal(context: common.UIAbilityContext, pref: PreferenceManager,
    requestPermission: boolean): Promise<ExternalStorageResult> {
    if (GameStorage.isTabletSilent()) {
      if (!GameStorage.downloadDir()) return 'unavailable';
      if (!GameStorage.isDownloadPermissionGranted(context) &&
        (!requestPermission || !await GameStorage.requestDownloadPermission(context))) return 'permissionDenied';
      if (!GameStorage.migrateLegacyExternalFolder()) return 'unavailable';
    } else {
      const cached = !GameStorage.needsPhoneLearn();
      if (!await GameStorage.ensurePhoneExternalDir(context, pref)) return 'unavailable';
      if (GameStorage.verifyExternalRoot()) return 'ready';
      // 手动重试能够更正失效的旧 picker 路径。新学到但不可写的目录只确认一次，交回用户。
      if (!cached || !requestPermission || !await GameStorage.ensurePhoneExternalDir(context, pref, true)) return 'unavailable';
    }
    return GameStorage.verifyExternalRoot() ? 'ready' : 'unavailable';
  }

  /** 页面返回时只复核已选位置，不弹授权。可读写时接回外部根，权限撤销只影响当前会话。 */
  static currentLocation(context: common.UIAbilityContext, preferred: StorageLocation): StorageLocation {
    if (preferred !== StorageLocation.EXTERNAL || !GameStorage.isExternalAvailable()) return StorageLocation.SANDBOX;
    if (GameStorage.isTabletSilent() && (!GameStorage.isDownloadPermissionGranted(context) ||
      !GameStorage.migrateLegacyExternalFolder())) return StorageLocation.SANDBOX;
    return GameStorage.verifyExternalRoot() ? StorageLocation.EXTERNAL : StorageLocation.SANDBOX;
  }

  /** 缺键旧用户固定原沙箱；新安装只确认一次实际可用根。已有外部偏好临时不可用时保留原偏好。 */
  static async prepareStartupLocation(context: common.UIAbilityContext, pref: PreferenceManager,
    active: () => boolean, publish?: (location: StorageLocation) => void): Promise<StorageLocation> {
    let stored = await pref.confirmedMcStorageLocation();
    while (active()) {
      let selected = StorageLocation.SANDBOX;
      if (stored === StorageLocation.EXTERNAL || (stored === undefined && GameStorage.isFreshInstall(context))) {
        if (await GameStorage.prepareExternal(context, pref, stored === undefined) === 'ready') {
          selected = StorageLocation.EXTERNAL;
        } else {
          AppLogger.warn(TAG, 'External game storage unavailable; using private game directory');
        }
      }
      if (stored === undefined) await pref.saveLauncherFields({ 'mcStorageLocation': selected }, active, true);
      // 系统授权、picker 或保存期间，另一窗口可能已改选。按最新选择复核后同步发布实际根。
      const expected = stored ?? selected;
      const confirmed = await pref.confirmedMcStorageLocation((value: string | undefined): void => {
        if (value === expected && active() && publish) publish(selected);
      });
      if (confirmed === undefined) throw new Error('游戏数据位置保存后未读回');
      if (confirmed === expected) {
        if (!active()) break;
        return selected;
      }
      stored = confirmed;
    }
    throw new Error('启动页面已离开');
  }

  /**
   * 外部应用目录（…/Download/com.amcl.launcher）；不可用返回 ''。
   * 设备差异封死在这里：平板用 Environment，手机用注入的缓存路径。调用方不感知设备类型。
   */
  static externalAppDir(): string {
    if (GameStorage.isTabletSilent()) {
      let d = GameStorage.downloadDir();
      return d.length > 0 ? d + '/' + EXTERNAL_FOLDER : '';
    }
    return GameStorage.phoneExternalDir;
  }

  /**
   * 外部游戏数据根（…/com.amcl.launcher/.minecraft）；不可用返回 ''。
   *
   * 内层沿用 MC 约定名 `.minecraft`（与 PC 启动器互通）。注意 Linux 文件系统下"隐藏"=
   * 文件名以 `.` 开头的约定（没有可单独开关的隐藏属性位），所以文件管理器默认不显示
   * `.minecraft`；writeExternalHint() 会在同级放一个可见 txt 引导用户开启"显示隐藏文件"。
   */
  static externalMcDir(): string {
    let app = GameStorage.externalAppDir();
    return app.length > 0 ? app + '/.minecraft' : '';
  }

  /**
   * 解析当前激活的 .minecraft 根（同步，可在热路径调用）。
   * EXTERNAL 但外部不可用（设备/能力缺失/手机未学过）→ 回落沙箱并 warn，保证永远返回可用路径。
   */
  static resolveMcDir(context: common.Context, location: StorageLocation): string {
    if (location === StorageLocation.EXTERNAL) {
      let ext = GameStorage.externalMcDir();
      if (ext.length > 0) return ext;
      AppLogger.warn(TAG, 'EXTERNAL selected but unavailable; fallback to sandbox .minecraft');
    }
    return GameStorage.sandboxMcDir(context);
  }

  /** 外部存储在本设备是否「可用或已就绪」（平板看 Environment；手机看是否已学到路径）。 */
  static isExternalAvailable(): boolean {
    return GameStorage.externalAppDir().length > 0;
  }

  /**
   * 外部存储在本设备是否「可启用」（UI 是否允许点「外部」）。
   *   - 平板：取得到 Download 路径才行（取不到 = 真不支持）；
   *   - 手机：恒 true（picker DOWNLOAD 总能学到路径），即使尚未学过也允许点击触发学习流程。
   * 与 isExternalAvailable 的区别：Available=「已就绪能直接用」，Supported=「能不能启用」。
   */
  static isExternalSupported(): boolean {
    return GameStorage.isTabletSilent() ? (GameStorage.downloadDir().length > 0) : true;
  }

  /** 手机端是否还需先跑 picker「学」路径（UI 据此选择启用流程；平板恒 false）。 */
  static needsPhoneLearn(): boolean {
    return !GameStorage.isTabletSilent() && GameStorage.phoneExternalDir.length === 0;
  }

  /**
   * 手机：用 DocumentViewPicker DOWNLOAD 模式（无弹窗）「学」一次公共应用目录原始路径。
   * 返回 …/Download/com.amcl.launcher（已是包名目录，勿再取父目录）；取消/失败返回 ''。
   */
  private static async learnPhoneExternalDir(ctx: common.UIAbilityContext): Promise<string> {
    try {
      let opts = new picker.DocumentSaveOptions();
      opts.pickerMode = picker.DocumentPickerMode.DOWNLOAD;   // 只取目录，不设 newFileNames
      let vp = new picker.DocumentViewPicker(ctx);
      let uris: string[] = await vp.save(opts);
      if (!uris || uris.length === 0) return '';
      return new fileUri.FileUri(uris[0]).path;
    } catch (e) {
      AppLogger.warn(TAG, 'learnPhoneExternalDir failed', e);
      return '';
    }
  }

  /**
   * 手机：确保已学到外部应用目录。已学过直接返回；否则 picker（无弹窗）学一次并落盘 + 注入。
   * 仅在「启用外部」动作里 await。返回 appDir（…/com.amcl.launcher）或 ''（取消/失败）。
   * 平板不应调用（平板走 Environment + requestDownloadPermission）。
   */
  static async ensurePhoneExternalDir(ctx: common.UIAbilityContext, pref: PreferenceManager, refresh: boolean = false): Promise<string> {
    if (!refresh && GameStorage.phoneExternalDir.length > 0) return GameStorage.phoneExternalDir;
    let dir = await GameStorage.learnPhoneExternalDir(ctx);
    if (dir.length === 0) return '';
    // 这个偏好只缓存系统返回的路径；是否选用由 prepareExternal 在实际读写后单独确认。
    pref.phoneExternalDir = dir;            // 落盘（跨重启）
    GameStorage.setPhoneExternalDir(dir);   // 即时注入（本会话生效）
    AppLogger.info(TAG, `learned phone external dir: ${dir}`);
    return dir;
  }

  /** 同步查询 READ_WRITE_DOWNLOAD_DIRECTORY 是否已授权（仅平板路线需要） */
  static isDownloadPermissionGranted(context: common.UIAbilityContext): boolean {
    try {
      let atm = abilityAccessCtrl.createAtManager();
      let tokenId = context.applicationInfo.accessTokenId;
      let status = atm.checkAccessTokenSync(tokenId, DOWNLOAD_PERM);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      AppLogger.warn(TAG, 'checkAccessTokenSync failed', e);
      return false;
    }
  }

  /**
   * 是否存在已安装版本（versions 目录非空）。用于切换位置时判断"要不要问迁移"。
   */
  static hasVersions(mcDir: string): boolean {
    try {
      let entries = fs.listFileSync(mcDir + '/versions');
      return entries.length > 0;
    } catch (e) {
      return false;
    }
  }

  /**
   * 把整个游戏数据从 fromMcDir 迁移(复制)到 toMcDir。
   *
   * 逐个拷贝 from 的子项到 to（而不是 copyDir(from, parent) 那种"按 from 的 basename 落位"）：
   * 解析器返回的是完整路径，这样写对"目标根与源 basename 是否相同"都健壮（当前两根内层都叫
   * .minecraft，但不依赖这一点）。
   *   - 子目录：fs.copyDir(childDir, toMcDir, 1) 会在 toMcDir 下创建 basename(childDir)；
   *   - 子文件：fs.copyFileSync。
   * 异步（copyDir 走 libuv 线程池，不阻塞 JS 主线程）。源数据保留不删（更安全）。
   */
  static async migrate(fromMcDir: string, toMcDir: string): Promise<void> {
    try { fs.mkdirSync(toMcDir, true); } catch (e) { /* exists */ }
    let entries: string[] = [];
    try { entries = fs.listFileSync(fromMcDir); } catch (e) { return; }
    for (let name of entries) {
      let src = fromMcDir + '/' + name;
      try {
        let st = fs.statSync(src);
        if (st.isDirectory()) {
          await fs.copyDir(src, toMcDir, 1);  // → toMcDir/<name>
        } else {
          fs.copyFileSync(src, toMcDir + '/' + name);
        }
      } catch (e) {
        AppLogger.warn(TAG, `migrate skip ${name}`, e);
      }
    }
    AppLogger.info(TAG, `migrated game data: ${fromMcDir} -> ${toMcDir}`);
  }

  /**
   * 一次性把旧的外部公共文件夹 Download/AMCL 改名为 Download/com.amcl.launcher（包名）。
   * 早期用自定义名 "AMCL"（不被文件管理器识别为应用、不进"来源"）；改成包名后会带 App 图标、
   * 自动出现在"来源"，且把里面已下载的 .minecraft 数据无缝带过去。
   * 仅当新文件夹不存在、旧文件夹存在时改名；失败保留重试机会，避免随后创建空根遮住旧数据。
   */
  static migrateLegacyExternalFolder(): boolean {
    let d = GameStorage.downloadDir();
    if (d.length === 0) return false;
    let newDir = d + '/' + EXTERNAL_FOLDER;
    let oldDir = d + '/' + LEGACY_EXTERNAL_FOLDER;
    try { return fs.statSync(newDir).isDirectory(); } catch (error) {
      if ((error as BusinessError).code !== 13900002) return false;
    }
    try {
      if (!fs.statSync(oldDir).isDirectory()) return false;
    } catch (error) {
      return (error as BusinessError).code === 13900002;
    }
    try {
      fs.renameSync(oldDir, newDir);
      AppLogger.info(TAG, `migrated external folder ${oldDir} -> ${newDir}`);
      return true;
    } catch (error) {
      AppLogger.warn(TAG, 'Legacy external game directory could not be moved', error);
      return false;
    }
  }

  /**
   * 在外部 Download/com.amcl.launcher/ 下（与 .minecraft 同级）自动生成一个说明 txt，引导用户开启
   * 文件管理器的"显示隐藏文件"才能看到 .minecraft 里的游戏资源。
   *
   * 写-if-absent：已存在则不覆盖（不打扰用户已读/已删的本会话状态；删了下次启动会补回）。
   * 设备无关：用 externalAppDir()（平板=Environment、手机=学到的缓存路径）；不可用则静默跳过。
   */
  static writeExternalHint(): void {
    let amclDir = GameStorage.externalAppDir();
    if (amclDir.length === 0) return;
    let hintPath = amclDir + '/请开启“显示隐藏文件”查看游戏数据.txt';
    try { fs.mkdirSync(amclDir, true); } catch (e) { /* exists */ }
    try { fs.statSync(hintPath); return; } catch (e) { /* 不存在，继续写 */ }
    let content =
      'AMCL 游戏数据说明\n' +
      '====================\n\n' +
      '你的 Minecraft 游戏数据（版本 versions / 存档 saves / 模组 mods / 资源 assets 等）\n' +
      '都保存在本文件夹下的  .minecraft  文件夹里。\n\n' +
      '由于 .minecraft 以点(.)开头，文件管理器默认会把它当作"隐藏文件夹"而不显示。\n' +
      '这是 Linux/鸿蒙文件系统的命名约定，不是出了问题。\n\n' +
      '查看 / 管理这些文件的方法：\n' +
      '  打开文件管理器右上角菜单 → 开启"显示隐藏文件 / 显示隐藏项"\n' +
      '  即可看到本目录下的 .minecraft 文件夹及其中内容。\n\n' +
      '提示：本文件夹在公共下载目录里，卸载 AMCL 也不会被删除。\n' +
      '此说明文件由 AMCL 自动生成，可以删除。\n';
    try {
      let f = fs.openSync(hintPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(f.fd, content); } finally { fs.closeSync(f); }
      AppLogger.info(TAG, `wrote external hint file: ${hintPath}`);
    } catch (e) {
      AppLogger.warn(TAG, 'writeExternalHint failed', e);
    }
  }

  /**
   * 在沙箱 filesDir 下（与隐藏的 .minecraft 同级）自动生成说明 txt。
   * 当用户从文件管理器"来源"浏览到 AMCL 的应用内（沙箱）目录时，能看到这份说明：
   * 解释这是沙箱目录、.minecraft 被隐藏需开启显示隐藏文件、且卸载即删。
   *
   * 写-if-absent。沙箱 filesDir 必然存在且可写，故无需权限判断。
   */
  static writeSandboxHint(context: common.Context): void {
    let hintPath = context.filesDir + '/请开启“显示隐藏文件”查看游戏数据.txt';
    try { fs.statSync(hintPath); return; } catch (e) { /* 不存在，继续写 */ }
    let content =
      'AMCL 游戏数据说明（应用内 / 沙箱）\n' +
      '================================\n\n' +
      '这是 AMCL 的"沙箱内"存储目录。你的 Minecraft 游戏数据\n' +
      '（版本 versions / 存档 saves / 模组 mods / 资源 assets 等）保存在本目录下的\n' +
      '.minecraft 文件夹里。\n\n' +
      '由于 .minecraft 以点(.)开头，文件管理器默认会把它当作"隐藏文件夹"而不显示。\n' +
      '这是 Linux/鸿蒙文件系统的命名约定，不是出了问题。\n\n' +
      '查看 / 管理这些文件的方法：\n' +
      '  打开文件管理器右上角菜单 → 开启"显示隐藏文件 / 显示隐藏项"\n' +
      '  即可看到本目录下的 .minecraft 文件夹及其中内容。\n\n' +
      '注意：沙箱目录会随 AMCL 卸载一并删除（不保留）。\n' +
      '若想让游戏数据卸载不丢，请到 AMCL 设置 → "游戏数据位置" 切换到 "外部"\n' +
      '（数据会存到 下载目录 里的 AMCL 文件夹，卸载不丢）。\n\n' +
      '此说明文件由 AMCL 自动生成，可以删除。\n';
    try {
      let f = fs.openSync(hintPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(f.fd, content); } finally { fs.closeSync(f); }
      AppLogger.info(TAG, `wrote sandbox hint file: ${hintPath}`);
    } catch (e) {
      AppLogger.warn(TAG, 'writeSandboxHint failed', e);
    }
  }

  /** 运行时申请 READ_WRITE_DOWNLOAD_DIRECTORY；返回是否已授权 */
  static async requestDownloadPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      let atm = abilityAccessCtrl.createAtManager();
      let perms: Array<Permissions> = [DOWNLOAD_PERM];
      let res = await atm.requestPermissionsFromUser(context, perms);
      let code: number = (res.authResults && res.authResults.length > 0) ? res.authResults[0] : -1;
      return code === 0;
    } catch (e) {
      AppLogger.warn(TAG, 'requestPermissionsFromUser failed', e);
      return false;
    }
  }
}

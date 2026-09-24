/**
 * PhoneStorageProbe.ets — 手机端沙箱外存储可行性探针（Phase 0 决策门 · 手机路线）
 *
 * 背景：StorageProbe.ets 走的是「平板路线」——Environment.getUserDownloadDir() + 原始路径直写
 * + READ_WRITE_DOWNLOAD_DIRECTORY。该 API 在手机上报 801（device doesn't support），所以手机
 * 上「外部存储」实际不可用。
 *
 * 本探针验证「手机路线」（dev-notes-public-download-dir.md 的路线 C）能否支撑 AMCL：
 *   DocumentViewPicker DOWNLOAD 模式（无弹窗）→ 目录 URI
 *   → fileShare.persistPermission（持久化，跨重启）
 *   → fileShare.activatePermission（每次启动激活）
 *   → 在该目录下建 .minecraft 子树
 *   → ArkTS fileIo 写测试 + **native 裸 POSIX 写测试**（JVM 可行性的忠实代理）
 *
 * 关键问题（AMCL 特有，HLib 那篇文档没有也不需要验证）：
 *   picker 授权的目录，**native libc open() 能不能访问**？因为 MC 的 JVM 是 native 代码，
 *   要按原始路径加载 version jar / libraries、读写 saves。若只有 ArkTS fileIo 能写、native
 *   被拒，则手机端「把外部目录当运行时根」从原理上不成立。
 *
 * 跨重启验证：首次运行把目录 URI 持久化并存进 AppStorage('probe_phonePublicUri')。
 *   **杀进程重启 App 后再点一次**，探针会先走「复用」分支：activatePermission(已存 URI)
 *   → native 在该目录重写读 → 验证授权在重启后仍对 native 生效。这是真正的成败判据。
 *
 * 结论三态（与 StorageProbe 对齐）：
 *   NATIVE_OK   → 手机端真外部可行（JVM 可直接跑）→ 走 Phase 1
 *   ARKTS_ONLY  → 仅 ArkTS 可写、native 被拒 → 真外部不可行，走导入/导出桥
 *   UNAVAILABLE → 取不到目录 / 都不可写
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker, fileUri, fileShare } from '@kit.CoreFileKit';
import { systemNative } from './SystemNativeBridge';
import { AppLogger } from 'commons';
import { formatError } from 'commons';

const TAG = 'PhoneStorageProbe';

// 跨重启复用：存放 picker 授权拿到的目录 URI。探针专用键，避免与正式偏好冲突。
const STORE_KEY_URI = 'probe_phonePublicUri';
// 同时缓存解析出的原始路径，供重启后「不依赖 activate」直接 native 复测（验证包名文件夹的所有权式访问）。
const STORE_KEY_PATH = 'probe_phonePublicPath';

// fileShare 读写组合（必须用 fileShare 自己的枚举，不能用 want 的 Flags —— 见文档 Error 5）
const RW_MODE: number = fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE;

// 能力 syscap
const SYSCAP_TABLET_SILENT = 'SystemCapability.FileManagement.File.Environment.FolderObtain';
const SYSCAP_FOLDER_AUTH = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';

// AppStorage 是进程内存、不跨重启；跨重启复用须落到沙箱文件。
const DISK_PATH_FILE = '/.probe_phone_public_path';

/** 把已学到的公共目录原始路径落到沙箱文件（跨重启复用）。 */
function persistPathToDisk(context: common.UIAbilityContext, path: string): void {
  try {
    let f = fs.openSync(context.filesDir + DISK_PATH_FILE,
      fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(f.fd, path); } finally { fs.closeSync(f); }
  } catch (e) { AppLogger.warn(TAG, 'persistPathToDisk failed', e); }
}

/** 读回沙箱文件里缓存的公共目录原始路径；无则返回 ''。 */
function readPathFromDisk(context: common.UIAbilityContext): string {
  try {
    return fs.readTextSync(context.filesDir + DISK_PATH_FILE);
  } catch (e) { return ''; }
}

export enum PhoneStorageProbeVerdict {
  NATIVE_OK = 'native_ok',
  ARKTS_ONLY = 'arkts_only',
  UNAVAILABLE = 'unavailable',
}

export interface PhoneStorageProbeResult {
  verdict: PhoneStorageProbeVerdict;
  dirUri: string;
  dirPath: string;
  report: string;
}

function makePolicy(uri: string): fileShare.PolicyInfo {
  return { uri: uri, operationMode: RW_MODE };
}

/** 激活已持久化的授权；返回是否成功。 */
async function activate(uri: string): Promise<boolean> {
  try {
    await fileShare.activatePermission([makePolicy(uri)]);
    return true;
  } catch (e) {
    AppLogger.warn(TAG, 'activatePermission failed', e);
    return false;
  }
}

/**
 * 运行手机端存储探针。需要 UIAbilityContext（picker / 权限要求）。
 */
export async function runPhoneStorageProbe(context: common.UIAbilityContext): Promise<PhoneStorageProbeResult> {
  let lines: string[] = [];
  const add = (s: string): void => { lines.push(s); };

  add('=== AMCL 手机端沙箱外存储探针 (picker DOWNLOAD + 持久化) ===');

  // 0) 设备能力
  let tabletSilent = false;
  let folderAuth = false;
  try {
    tabletSilent = canIUse(SYSCAP_TABLET_SILENT);
    folderAuth = canIUse(SYSCAP_FOLDER_AUTH);
  } catch (e) { /* canIUse 不应抛，保险起见 */ }
  add('0) 设备能力:');
  add('   FolderObtain(平板静默路线) = ' + tabletSilent + (tabletSilent ? '  ← 本机像平板/2in1' : '  ← 本机像手机(预期)'));
  add('   FolderAuthorization(持久化) = ' + folderAuth + (folderAuth ? '' : '  ← 不支持持久化，手机路线无法跨重启'));

  let arktsOk = false;
  let nativeOk = false;
  let dirUri = '';
  let dirPath = '';

  // 1) 复用分支：已存 URI/路径 → 直接 native 复测（**不依赖 activate**，验证跨重启可访问性）
  //    实测发现 persist/activate 在本机报 Operation not permitted，但 picker 返回的是应用
  //    **包名文件夹**(Download/com.amcl.launcher)；怀疑是「所有权式」访问而非 picker 临时授权。
  //    所以重启后即使 activate 失败，也要直接拿缓存路径让 native 试访问——这才是真正的判据。
  let stored: string = AppStorage.get<string>(STORE_KEY_URI) ?? '';
  let storedPath: string = AppStorage.get<string>(STORE_KEY_PATH) ?? '';
  // 跨重启的真凭据来自沙箱文件（AppStorage 重启即清空）
  if (storedPath.length === 0) storedPath = readPathFromDisk(context);
  if (storedPath.length > 0 || stored.length > 0) {
    add('1) 复用已存路径（杀进程重启后这一步证明 native 仍可访问 = 所有权式访问成立）:');
    add('   storedUri  = ' + (stored.length > 0 ? stored : '(无)'));
    add('   storedPath = ' + (storedPath.length > 0 ? storedPath : '(无)'));
    // activate 仅作信息记录，不作为 native 复测的前置条件
    if (stored.length > 0) {
      let act = await activate(stored);
      add('   activatePermission = ' + (act ? 'OK' : 'FAIL（不阻断 native 复测）'));
    }
    // 解析路径（优先用缓存路径；缺失则从 uri 还原）
    if (storedPath.length === 0 && stored.length > 0) {
      try { storedPath = new fileUri.FileUri(stored).path; } catch (e) { /* ignore */ }
    }
    if (storedPath.length > 0) {
      dirUri = stored;
      dirPath = storedPath;
      try {
        let reuseProbeDir = dirPath + '/.minecraft/.probe';
        try { fs.mkdirSync(reuseProbeDir, true); } catch (e) { /* exists */ }
        let nativeReport = systemNative().probeNativePath(reuseProbeDir);
        add('   [复用] native 探针（重启后直访缓存路径）:');
        add(nativeReport);
        if (nativeReport.indexOf('NATIVE_RW_OK') >= 0) {
          nativeOk = true;
          arktsOk = true;
        }
      } catch (e) {
        add('   [复用] native 探针异常: ' + formatError(e));
      }
    }
  } else {
    add('1) 复用已存路径: 无（首次运行）');
  }

  // 2) 首次/重取目录：picker DOWNLOAD 模式（无弹窗）→ 持久化
  if (dirUri.length === 0) {
    add('2) 通过 picker DOWNLOAD 模式取目录（应无弹窗、直接返回）:');
    try {
      let opts = new picker.DocumentSaveOptions();
      opts.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      let vp = new picker.DocumentViewPicker(context);
      let uris: string[] = await vp.save(opts);
      dirUri = (uris && uris.length > 0) ? uris[0] : '';
      add('   返回 URI = ' + (dirUri.length > 0 ? dirUri : '(空)'));
    } catch (e) {
      add('   picker.save 异常: ' + formatError(e));
    }

    if (dirUri.length === 0) {
      add('=== 结论 === ❌ 未取到目录 URI（取消/不支持）');
      let report0 = lines.join('\n');
      AppLogger.info(TAG, report0);
      return { verdict: PhoneStorageProbeVerdict.UNAVAILABLE, dirUri: '', dirPath: '', report: report0 };
    }

    // 持久化（best-effort：DOWNLOAD URI 本就可持久，报错可忽略）
    try {
      await fileShare.persistPermission([makePolicy(dirUri)]);
      add('   persistPermission = OK');
    } catch (e) {
      add('   persistPermission = 失败(可忽略): ' + formatError(e));
    }
    // 激活
    let act2 = await activate(dirUri);
    add('   activatePermission = ' + (act2 ? 'OK' : 'FAIL'));

    // 存起来供下次（重启后）复用：URI + 解析出的原始路径（路径落沙箱文件以跨重启）
    AppStorage.setOrCreate<string>(STORE_KEY_URI, dirUri);
    try {
      let p = new fileUri.FileUri(dirUri).path;
      if (p.length > 0) {
        AppStorage.setOrCreate<string>(STORE_KEY_PATH, p);
        persistPathToDisk(context, p);
      }
    } catch (e) { /* ignore */ }
    add('   已缓存 URI+路径（路径落沙箱文件）。请杀进程重启 App 后再点一次本探针（验证跨重启）。');
  }

  // 3) 解析原始路径 + 确认是目录
  if (dirPath.length === 0) {
    try {
      dirPath = new fileUri.FileUri(dirUri).path;
      add('3) FileUri(uri).path = ' + dirPath);
    } catch (e) {
      add('3) 路径解析异常: ' + formatError(e));
    }
  } else {
    add('3) 路径（复用分支已解析）= ' + dirPath);
  }
  if (dirPath.length > 0) {
    try {
      let st = fs.statSync(dirPath);
      add('   statSync.isDirectory() = ' + st.isDirectory() + '（DOWNLOAD 模式应为 true）');
    } catch (e) {
      add('   statSync 异常: ' + formatError(e));
    }
  }

  // 4) ArkTS 建多层 .minecraft 子树 + 写测试（仅在还没经复用分支确认时跑）
  let probeDir = dirPath + '/.minecraft/.probe';
  if (dirPath.length > 0 && !nativeOk) {
    add('4) ArkTS 建子树 + 写测试:');
    try {
      fs.mkdirSync(dirPath + '/.minecraft/versions/probe', true);  // 验证多层子目录
      fs.mkdirSync(probeDir, true);
      let probeFile = probeDir + '/arkts_probe.txt';
      let f = fs.openSync(probeFile, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try { fs.writeSync(f.fd, 'amcl-phone-arkts-probe'); } finally { fs.closeSync(f); }
      let st = fs.statSync(probeFile);
      arktsOk = st.size > 0;
      add('   ArkTS fileIo 写入: OK (' + st.size + ' bytes)');
      try { fs.unlinkSync(probeFile); } catch (e) { /* ignore */ }
    } catch (e) {
      add('   ArkTS fileIo 写入: FAIL ' + formatError(e));
    }
  }

  // 5) native 裸 POSIX 写测试（JVM 可行性忠实代理；复用分支已做则跳过）
  if (dirPath.length > 0 && !nativeOk) {
    add('5) native 裸 POSIX 探针:');
    try {
      let nativeReport = systemNative().probeNativePath(probeDir);
      add(nativeReport);
      nativeOk = nativeReport.indexOf('NATIVE_RW_OK') >= 0;
    } catch (e) {
      add('   native 探针调用异常: ' + formatError(e));
    }
  }

  // 结论
  let verdict: PhoneStorageProbeVerdict;
  add('=== 结论 ===');
  if (nativeOk) {
    verdict = PhoneStorageProbeVerdict.NATIVE_OK;
    add('✅ 手机端真外部可行: MC 的 JVM 可直接运行在 ' + dirPath + '/.minecraft');
    add('   下一步：把 GameStorage 的 EXTERNAL 在手机分支接到本路线（picker+persist+每次启动 activate）。');
  } else if (arktsOk) {
    verdict = PhoneStorageProbeVerdict.ARKTS_ONLY;
    add('⚠️ 仅 ArkTS 可写、native 被拒 → 手机端「外部运行时根」不成立。');
    add('   退路：外部目录降级为导入/导出桥（运行时仍用沙箱）。');
  } else {
    verdict = PhoneStorageProbeVerdict.UNAVAILABLE;
    add('❌ ArkTS 与 native 都不可写 / 取不到路径。');
  }

  let report = lines.join('\n');
  AppLogger.info(TAG, report);
  return { verdict, dirUri, dirPath, report };
}

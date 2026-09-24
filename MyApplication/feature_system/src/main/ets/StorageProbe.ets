/**
 * StorageProbe.ets — 沙箱外存储可行性探针（Phase 0 决策门）
 *
 * 目的：在真机上判定"把 .minecraft 放到公共 Download/com.amcl.launcher 并让 MC 的 JVM 直接跑在那里"
 * 是否可行。鸿蒙 NEXT 的铁律是 native 代码只能 POSIX open() 沙箱路径,公共目录需授权 +
 * 沙箱映射路径,且 READ_WRITE_DOWNLOAD_DIRECTORY 官方注明"仅 2in1/PC 稳定支持"。所以只能实测。
 *
 * 探针三步:
 *   1. 申请 READ_WRITE_DOWNLOAD_DIRECTORY 运行时权限
 *   2. Environment.getUserDownloadDir() 取 Download 的沙箱映射路径
 *   3. ArkTS fileIo 写测试 + NAPI 裸 POSIX 写测试(probeNativePath,JVM 可行性的忠实代理)
 *
 * 结论三态:
 *   NATIVE_RW_OK   → 真外部可行 → 走 Phase 1
 *   仅 ArkTS 可写   → 真外部不可行 → 走 Phase 1-alt(导出/导入)
 *   都不可写        → 仅 picker 单文件
 */

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { Environment, fileIo as fs } from '@kit.CoreFileKit';
import { systemNative } from './SystemNativeBridge';
import { AppLogger } from 'commons';
import { formatError } from 'commons';

const TAG = 'StorageProbe';

export enum StorageProbeVerdict {
  NATIVE_OK = 'native_ok',       // 真外部可行
  ARKTS_ONLY = 'arkts_only',     // 仅 ArkTS 可写
  UNAVAILABLE = 'unavailable',   // 都不可写 / 取不到路径
}

export interface StorageProbeResult {
  verdict: StorageProbeVerdict;
  downloadDir: string;
  permissionGranted: boolean;
  report: string;
}

/**
 * 运行完整探针。需要 UIAbilityContext（权限申请要求）。
 */
export async function runStorageProbe(context: common.UIAbilityContext): Promise<StorageProbeResult> {
  let lines: string[] = [];
  const add = (s: string): void => { lines.push(s); };

  add('=== AMCL 沙箱外存储探针 (Phase 0) ===');

  // 1. 申请权限
  let granted = false;
  try {
    let atManager = abilityAccessCtrl.createAtManager();
    let perms: Array<Permissions> = ['ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'];
    let res = await atManager.requestPermissionsFromUser(context, perms);
    let code: number = (res.authResults && res.authResults.length > 0) ? res.authResults[0] : -1;
    granted = (code === 0);
    add('1) 权限 READ_WRITE_DOWNLOAD_DIRECTORY: ' + (granted ? '已授权' : '未授权 (authResult=' + code + ')'));
  } catch (e) {
    add('1) 权限申请异常: ' + formatError(e));
  }

  // 2. 取 Download 沙箱映射路径
  let downloadDir = '';
  try {
    downloadDir = Environment.getUserDownloadDir();
    add('2) getUserDownloadDir() = ' + downloadDir);
  } catch (e) {
    add('2) getUserDownloadDir() 异常(本设备可能不支持该能力): ' + formatError(e));
  }

  if (!downloadDir || downloadDir.length === 0) {
    add('=== 结论 === ❌ 取不到 Download 路径 → 真外部不可行(本设备)');
    let report = lines.join('\n');
    AppLogger.info(TAG, report);
    return { verdict: StorageProbeVerdict.UNAVAILABLE, downloadDir: '', permissionGranted: granted, report };
  }

  // 与 GameStorage.EXTERNAL_FOLDER 保持一致：用包名文件夹（避免在 Download 留下游离的 AMCL 目录）
  let amclDir = downloadDir + '/com.amcl.launcher';
  let probeDir = amclDir + '/.probe';

  // 3a. ArkTS fileIo 写测试
  let arktsOk = false;
  try {
    fs.mkdirSync(amclDir, true);
    fs.mkdirSync(probeDir, true);
    let probeFile = probeDir + '/arkts_probe.txt';
    let f = fs.openSync(probeFile, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, 'amcl-arkts-probe');
    } finally {
      fs.closeSync(f);
    }
    let st = fs.statSync(probeFile);
    arktsOk = st.size > 0;
    add('3a) ArkTS fileIo 写入: OK (' + st.size + ' bytes)');
    try { fs.unlinkSync(probeFile); } catch (e) { /* ignore */ }
  } catch (e) {
    add('3a) ArkTS fileIo 写入: FAIL ' + formatError(e));
  }

  // 3b. NAPI 裸 POSIX 写测试（JVM 可行性忠实代理）
  let nativeOk = false;
  try {
    let nativeReport = systemNative().probeNativePath(probeDir);
    add('3b) native 探针:');
    add(nativeReport);
    nativeOk = nativeReport.indexOf('NATIVE_RW_OK') >= 0;
  } catch (e) {
    add('3b) native 探针调用异常: ' + formatError(e));
  }

  // 结论
  let verdict: StorageProbeVerdict;
  add('=== 结论 ===');
  if (nativeOk) {
    verdict = StorageProbeVerdict.NATIVE_OK;
    add('✅ 真外部可行: MC 的 JVM 可直接运行在 ' + amclDir + '/.minecraft (走 Phase 1)');
  } else if (arktsOk) {
    verdict = StorageProbeVerdict.ARKTS_ONLY;
    add('⚠️ 仅 ArkTS 可写, native 被拒 → 真外部不可行, 走 Phase 1-alt(导出/导入)');
  } else {
    verdict = StorageProbeVerdict.UNAVAILABLE;
    add('❌ ArkTS 与 native 都不可写 → 仅能 picker 单文件导出');
  }

  let report = lines.join('\n');
  AppLogger.info(TAG, report);
  return { verdict, downloadDir, permissionGranted: granted, report };
}

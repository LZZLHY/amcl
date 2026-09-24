// 关键故障路径的持久化门禁：按明确文件检查 WARN/ERROR/FATAL，不能以全仓
// 百分比掩盖某个启动/安装/输入模块退回易失日志。缺文件、缺门面都作为失败。
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { stripComments } from './lib/source-noise.mjs';
const root = path.resolve(import.meta.dirname, '..');
export const criticalFiles = [
  'entry/src/main/ets/entryability/EntryAbility.ets',
  'entry/src/main/ets/runtime/ProcessRuntime.ets',
  'launch/src/main/ets/LaunchProfileBuilder.ets', 'launch/src/main/ets/JdkInstaller.ets',
  'feature_core/src/main/ets/download/PhaseRunner.ets',
  'feature_core/src/main/ets/download/SourceProber.ets',
  'feature_core/src/main/ets/download/DownloadManager.ets',
  'feature_core/src/main/ets/download/phases/MergePhase.ets',
  'feature_core/src/main/ets/download/phases/ModloaderPhase.ets',
  'gamecontrol/src/main/ets/InputSourceRegistry.ets', 'gamecontrol/src/main/ets/InputDeviceMonitor.ets',
  'gamecontrol/src/main/ets/LayoutStore.ets', 'gamecontrol/src/main/ets/GamepadManager.ets',
  'gamecontrol/src/main/ets/PointerVisibilityCoordinator.ets',
  'entry/src/main/cpp/jvm/jvm_launcher.cpp', 'entry/src/main/cpp/jvm/mc_launcher.cpp',
  'entry/src/main/cpp/jvm/elf_loader.cpp', 'entry/src/main/cpp/platform/touch_input.cpp',
  'entry/src/main/cpp/glfw/glfw_egl.cpp', 'entry/src/main/cpp/glfw/glfw_compat.cpp',
];
export function checkCriticalLogging(read = name => fs.readFileSync(path.join(root, name), 'utf8')) {
  const errors = [];
  for (const file of criticalFiles) {
    let source;
    try { source = stripComments(read(file)); } catch { errors.push(file + ': missing source'); continue; }
    if (file.endsWith('/elf_loader.cpp')) {
      // abort/assert 可能由日志运行库自身触发，不能递归进入异步 writer。
      // 只豁免这两个确定的终止钩子，持久现场仍由既有信号安全采集器负责。
      source = source.replace(/OH_LOG_ERROR\(LOG_APP, "!!! abort\(\) called from ELF-loaded library !!!"\);/, '')
        .replace(/OH_LOG_ERROR\(LOG_APP, "!!! ASSERT FAILED in ELF lib:[\s\S]*?func \? func : "\?"\);/, '');
    }
    if (/\bhilog\.(?:warn|error|fatal)\s*\(|\bOH_LOG_(?:WARN|ERROR|FATAL)\s*\(/.test(source)) {
      errors.push(file + ': volatile-only failure log');
    }
    if (!/\b(?:AppLogger|ActivityLogger)|\bAMCL_(?:EXTERNAL_)?LOG_[WEF]\s*\(/.test(source)) errors.push(file + ': persistent facade absent');
    if (file.includes('/glfw/') && /\bAMCL_LOG_[WEF]\s*\(/.test(source)) errors.push(file + ': provider must use host sink bridge, not link a duplicate writer');
  }
  return errors;
}
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const errors = checkCriticalLogging();
  console.log(errors.length ? errors.join('\n') : `PASS persistent failure logs in ${criticalFiles.length} critical sources`);
  process.exitCode = errors.length ? 1 : 0;
}

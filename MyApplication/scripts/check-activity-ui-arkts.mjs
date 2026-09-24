/**
 * 使用 SDK 正式导出的 etsStandaloneChecker 检查活动账本 UI 源码。
 * 复用上一次 Hvigor 生成的模块解析配置，使用独立临时缓存，不生成或签名 HAP，
 * 因而不能替代 build-hap.ps1 的依赖、native、产物和发布门禁。
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const configurationPath = path.join(root, '.hvigor/cache/project-config.json');
if (!fs.existsSync(configurationPath)) throw new Error('需要已有 Hvigor 模块配置，先运行项目正式构建初始化环境');
const config = JSON.parse(fs.readFileSync(configurationPath, 'utf8'));
if (path.resolve(config.modulePath) !== path.join(root, 'entry')) throw new Error('缓存配置不是当前 entry 模块，拒绝混用其他产品');
// Hvigor 的缓存记录原始构建配置；独立检查补上 loader 清单中的模块映射和已验证源码根。
Object.assign(config, JSON.parse(fs.readFileSync(config.aceBuildJson, 'utf8')));
config.projectPath = config.aceModuleRoot;
config.moduleRootPath = config.modulePath;
config.resolveModulePaths = Object.values(config.modulePathMap || {});
config.globalModulePaths = config.resolveModulePaths;
// 生产 init_config 会把 6.0.0(20) 转为 API 整数；独立入口执行同样的显式解析。
for (const key of ['compatibleSdkVersion', 'compileSdkVersion']) {
  const value = String(config[key]);
  const match = value.match(/\((\d+)\)$/) || value.match(/^(\d+)$/);
  if (!match) throw new Error('无法解析 SDK API 数值：' + key + '=' + value);
  config[key] = Number(match[1]);
}
// JSON 缓存不会保留 Map/Set 原型；恢复 SDK 独立检查入口要求的容器。
for (const key of ['depName2RootPath', 'depName2DepInfo', 'depName2OhExports']) {
  const value = config[key];
  config[key] = new Map(Array.isArray(value) ? value : Object.entries(value || {}));
}
config.rootPathSet = new Set(Array.isArray(config.rootPathSet) ? config.rootPathSet : []);
for (const key of ['syscapIntersectionSet', 'syscapUnionSet']) {
  if (config[key] !== undefined) config[key] = new Set(Array.isArray(config[key]) ? config[key] : []);
}
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'amcl-ui-arkts-check-'));
// entry/Product* 是产品源集别名，不是 npm 包。检查目录只映射真实 default 源集，绝不造类型桩。
fs.symlinkSync(path.join(root, 'entry/src/main'), path.join(temporary, 'entry'), 'junction');
for (const [name, moduleRoot] of Object.entries(config.modulePathMap)) {
  if (name !== 'entry') fs.symlinkSync(moduleRoot, path.join(temporary, name), 'junction');
}
fs.symlinkSync(path.join(root, 'entry/oh_modules'), path.join(temporary, 'oh_modules'), 'junction');
config.resolveModulePaths.push(temporary);
config.originCompatibleSdkVersion = config.compatibleSdkVersion;
const require = createRequire(import.meta.url);
const loader = config.etsLoaderPath;
if (!loader || !fs.existsSync(path.join(loader, 'compile_plugin.js'))) throw new Error('SDK etsStandaloneChecker 不可用');
const files = [
  'entry/src/main/ets/components/ActivitySharePreparation.ets',
  'entry/src/main/ets/components/ActivityShareSheet.ets',
  'entry/src/main/ets/components/UiMotion.ets',
  'entry/src/main/ets/components/MotionSection.ets',
  'entry/src/main/ets/components/AnimatedPillBar.ets',
  'entry/src/main/ets/components/ActivityTimelineItem.ets',
  'entry/src/main/ets/components/ActivityViewTabs.ets',
  'entry/src/main/ets/components/ActivityPaneMotion.ets',
  'entry/src/main/ets/components/LauncherTabsStyle.ets',
  'entry/src/main/ets/components/ActivityUiModel.ets',
  'entry/src/main/ets/components/AiReportStore.ets',
  'entry/src/main/ets/components/AiAnalysisService.ets',
  'entry/src/main/ets/components/AiDiagnostic.ets',
  'entry/src/main/ets/components/AiDiagnosticCard.ets',
  'entry/src/main/ets/components/ActivityAiCard.ets',
  'entry/src/main/ets/components/McErrorSheet.ets',
  'entry/src/main/ets/pages/DownloadHistoryPage.ets',
  'entry/src/main/ets/pages/ActivityLogPage.ets',
  'entry/src/main/ets/pages/LogShareHistoryPage.ets',
  'entry/src/main/ets/pages/tabs/SettingsTab.ets',
  'entry/src/main/ets/pages/tabs/HomeTab.ets',
];
const entries = Object.fromEntries(files.map(file => [file, path.join(root, file)]));
// SDK 会把 tsbuildinfo 写到 cachePath 的父级，因此再设一层目录，将全部缓存限制在本次临时目录。
const cacheDirectory = path.join(temporary, 'cache');
fs.mkdirSync(cacheDirectory);
config.cachePath = cacheDirectory;
config.arkCompileCachePath = cacheDirectory;
config.buildCacheProjectDir = cacheDirectory;
config.watchMode = false;
process.env.watchMode = 'false';
process.env.compileTool = 'rollup';
// 与 SDK main.initProjectConfig 保持一致：注解声明及 Harmony 扩展 API 均是真实 SDK，不能用桩跳过。
config.allowEtsAnnotations = true;
process.env.externalApiPaths = (config.externalApiPaths || []).join(path.delimiter);
let errors = 0, warnings = 0;
const diagnostics = [];
const logger = {
  error: (...values) => { errors++; diagnostics.push({ severity: 'error', message: values.join(' ') }); console.error(...values); },
  warn: (...values) => { warnings++; diagnostics.push({ severity: 'warning', message: values.join(' ') }); if (warnings <= 3) console.warn(...values); },
  info: (...values) => console.log(...values),
  debug() {},
  getLevel: () => 'info',
};
console.log('SDK 源码检查（非 HAP 构建）:', loader);
console.log('配置:', configurationPath, '临时缓存:', temporary);
const sdk = require(path.join(loader, 'compile_plugin.js'));
const main = require(path.join(loader, 'main.js'));
if (config.appResource && fs.existsSync(config.appResource)) main.readAppResource(config.appResource);
try {
  sdk.etsStandaloneChecker(entries, logger, config);
} catch (error) {
  errors++;
  console.error('SDK checker failed:', error.stack);
}
const reportPath = path.join(temporary, 'diagnostics.json');
fs.writeFileSync(reportPath, JSON.stringify({ kind: 'arkts-source-only', files, errors, warnings, diagnostics }, null, 2));
// 只解除本次创建的 junction，不递归访问目标源码；诊断文件与缓存保留供追溯。
for (const name of [...Object.keys(config.modulePathMap), 'oh_modules']) {
  const link = path.join(temporary, name);
  if (fs.lstatSync(link).isSymbolicLink()) fs.unlinkSync(link);
}
console.log(JSON.stringify({ kind: 'arkts-source-only', files, errors, warnings, reportPath }));
process.exitCode = errors > 0 ? 1 : 0;

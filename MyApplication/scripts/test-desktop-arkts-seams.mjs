// 执行真实Ability生命周期和按API启用的Tab属性；平台服务边界隔离，保留桌面错误交接断言。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from './lib/ets-compiler.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const noop = () => {};
function load(relative, dependencies, globals = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const compiled = ts.transpileModule(source, { fileName: relative.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', ...Object.keys(globals), compiled)(
    dependencies, module, module.exports, ...Object.values(globals));
  return module.exports;
}
const state = new Map();
// 本测试保留真实Ability调用顺序，仅替换导出owner的平台边界；重型任务链由独立导出回归执行。
// 记录上下文以核对恢复只在启动器onCreate发生，普通onNewWant不能重启或重复接管导出。
const exportRecoveryContexts = [];
const runAdmissionContexts = [];
const storage = { setOrCreate: (key, value) => state.set(key, value), get: key => state.get(key) };
const logger = { info: noop, warn: noop, error: noop, setNativeLogSink: noop };
class UIAbility { constructor() { this.context = { filesDir: '/test', config: {}, getApplicationContext: () => ({ setColorMode: noop }) }; } }
const commons = { AppLogger: logger, LogTags: { ENTRY_ABILITY: 'EntryAbility' }, LOG_DOMAIN_LAUNCH: 1,
  DiagnosticPolicy: { configure: noop }, DistributionPolicy: { configure: noop }, DistributionChannel: {},
  setLedgerScopeSink: noop, ledgerResolveStale: () => 0, formatProductIdentity: () => '' };
// 文件保护由独立安装租约/Coordinator回归验证；此处为Ability注入成功的平台根配置边界。
const native = { getDiagnosticCapabilities: () => 0, desktopGameProcessState: () => 0, amclLogInit: noop,
  configureSideloadInstallRoot: () => true };
// 加载真实诊断Want解析；普通Want必须确实绕过新通道，不能用一个永远false的替身掩盖冲突。
const observationWant=load('entry/src/main/ets/components/InputObservationTestWant.ets',name=>{
  if(name==='commons')return commons;
  if(name==='entry/ProductBuildProfile')return {ProductBuildProfile:{}};
  if(name==='libentry.so')return {default:native};
  if(name.endsWith('GameSessionHost'))return {getGameSessionHost:()=>assert.fail('ordinary Want cannot create diagnostic Host')};
  if(name.endsWith('EntryInputObservationPort'))return load('entry/src/main/ets/components/EntryInputObservationPort.ets',()=>({}));
  return {};
});
// onCreate 将首帧后的准备闭包交给真实进程交接类。这里直接装载生产类，
// 不能返回空模块让 install 报错，也不能用无行为 install 替身吞掉本轮生命周期依赖。
// 此套件仍只验证 Ability 错误Want/准入初始化顺序；实际prepare的等待/重试另有开屏回归。
const launcherStartupRuntime=load('entry/src/main/ets/runtime/LauncherStartupRuntime.ets',name=>{
  throw new Error('Unexpected startup-runtime dependency: '+name);
});
const Ability = load('entry/src/main/ets/entryability/EntryAbility.ets', name => {
  if(name.endsWith('InputObservationTestWant'))return observationWant;
  if(name.endsWith('LauncherStartupRuntime'))return launcherStartupRuntime;
  // 本组固定非store：initialize必须正常完成，不能靠生产catch吞缺失依赖后假装启动成功。
  if (name.endsWith('GameRunAdmission')) return { GameRunAdmission: {
    initialize: context => { runAdmissionContexts.push(context); },
  } };
  if (name.endsWith('GameExportCoordinator')) return { getGameExportCoordinator: () => ({
    recover: context => { exportRecoveryContexts.push(context); return Promise.resolve(); },
  }) };
  if (name === '@kit.AbilityKit') return { UIAbility, ConfigurationConstant: { ColorMode: {} } };
  if (name === 'commons') return commons;
  if (name === 'gamecontrol') return { getInputDeviceMonitor: () => ({ ensureStarted: noop }) };
  if (name === 'libentry.so') return { default: native };
  if (name === 'entry/ProductBuildProfile') return { ProductBuildProfile: {} };
  if (name === 'entry/ProductInputProfile') return { ProductInputProfile: { initialize: noop } };
  if (name === 'launch') return { SessionMarker: { readAndClear: () => null } };
  if (name.endsWith('LogShareConnectivityProbe')) return { runLogShareConnectivityWant: noop };
  // 自更新属于独立服务，本用例只核对Ability既有启动错误交接；不执行网络或安装事务。
  if (name.endsWith('SideloadUpdateTestWant')) return { runSideloadUpdateTestWant: noop };
  if (name.endsWith('InstallFence')) return { InstallFence: { init: noop } };
  if (name.endsWith('SideloadUpdateService')) return { SideloadUpdateService: { get: () => ({ recover: noop }) } };
  if (name.endsWith('ProductIdentityCollector')) return { collectProductIdentity: () => ({}) };
  if (name.endsWith('PlatformDfxWatcher')) return { PlatformDfxWatcher: { start: noop, recordLastExit: noop } };
  if (name.endsWith('ProcessRuntime')) return { EntryNativeLogSink: class {}, EntryLedgerScopeSink: class {}, installProcessNativeBridges: noop };
  return {};
}, { AppStorage: storage, setTimeout: noop }).default;
for (const lifecycle of ['onCreate', 'onNewWant']) {
  for (const message of ['启动快照已过期', '游戏必须在独立进程运行', 'HAR 初始化失败']) {
    state.clear();
    new Ability()[lifecycle]({ parameters: { desktopLaunchError: message } }, {});
    assert.equal(state.get('desktopLaunchError'), message, lifecycle);
    assert.equal(state.has('gameRunAdmissionError'), false, 'default准入依赖缺失不能被catch吞成正常路径');
  }
  for (const parameters of [undefined, {}, { desktopLaunchError: '' }, { desktopLaunchError: 42 }]) {
    state.clear();
    new Ability()[lifecycle]({ parameters }, {});
    assert.equal(state.has('desktopLaunchError'), false, lifecycle + ': invalid error');
    assert.equal(state.has('gameRunAdmissionError'), false, 'default初始化必须不产生虚假运行授权错误');
  }
}
assert.equal(exportRecoveryContexts.length, 7, 'only the seven launcher onCreate cases discover export recovery');
assert.ok(exportRecoveryContexts.every(context => context.filesDir === '/test'), 'export owner receives the actual launcher context');
assert.equal(runAdmissionContexts.length, 7, '准入初始化只由七次真实onCreate触发，热Want不重复初始化');
assert.ok(runAdmissionContexts.every(context => exportRecoveryContexts.includes(context)), '准入与导出owner接收同一真实Ability上下文');

// 使用真实的稳定偏好枚举；平台 apiAvailable 在此隔离，编译器改写由正式构建确认。
const dockLight = load('commons/src/main/ets/common/DockLight.ets', name => { throw new Error('Unexpected dependency: ' + name); });
for (const version of [20, 21, 22, 23, 26]) {
  const calls = [];
  let materialReads = 0;
  const designKit = { get hdsMaterial() {
    assert.ok(version >= 23, 'API22 must not read the API23 material namespace');
    materialReads++;
    return { MaterialType: { ADAPTIVE: 11 }, MaterialLevel: { ADAPTIVE: 12 } };
  } };
  const globals = { Color: { Transparent: 'transparent' }, BlurStyle: { NONE: 0, COMPONENT_THICK: 3 }, TabsCacheMode: { CACHE_BOTH_SIDE: 1 } };
  const Style = load('entry/src/main/ets/components/LauncherTabsStyle.ets', name => {
    if (name === '@kit.BasicServicesKit') return { deviceInfo: { apiAvailable: required => {
      assert.equal(required, '6.1.0'); return version >= 23;
    } } };
    if (name === '@kit.UIDesignKit') return designKit;
    if (name === 'commons') return dockLight;
    throw new Error('Unexpected dependency: ' + name);
  }, globals).LauncherTabsStyle;
  const attributes = { barOverlap: value => calls.push(['overlap', value]),
    barBackgroundColor: value => calls.push(['color', value]),
    barBackgroundBlurStyle: value => calls.push(['blur', value]) };
  if (version >= 23) {
    attributes.barFloatingStyle = value => calls.push(['floating', value]);
    attributes.cachedMaxCount = (...args) => calls.push(['cache', ...args]);
  }
  new Style(30, dockLight.DockLightMode.AUTO, '#fff').applyNormalAttribute(attributes);
  if (version < 23) {
    assert.deepEqual(calls, [['color', 'transparent'], ['overlap', true], ['blur', 3]]);
    assert.equal(materialReads, 0);
  } else {
    assert.deepEqual(calls, [['color', 'transparent'], ['blur', 0], ['floating', { barBottomMargin: 38, systemMaterialEffect: { materialType: 11, materialLevel: 12 } }], ['cache', 2, 1]]);
  }
}
console.log('Desktop ArkTS lifecycle errors and API20–26 tab compatibility PASS');

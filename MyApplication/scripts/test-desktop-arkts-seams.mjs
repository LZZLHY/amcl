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
// 这些端口只记录Ability装配，不执行权限、账本或音频设备业务；深层行为由各自专项验证。
// 必须观测实际调用，避免近期新增依赖返回空模块后被生产catch吞掉而伪装正常启动。
const audioEvents = [], lifecycleEvents = [], recoveryContexts = [], layoutContexts = [];
const ownerConfigurations = [], ownerForeground = [], dfxStarts = [], inputMonitorStarts = [];
const runtimeValidationReads = [];
const unexpectedLogs = [];
const storage = { setOrCreate: (key, value) => state.set(key, value), get: key => state.get(key) };
const logger = { info: noop, warn: (...args) => unexpectedLogs.push(args),
  error: (...args) => unexpectedLogs.push(args), setNativeLogSink: noop,
  flush: () => lifecycleEvents.push(['log-flush']) };
class UIAbility {
  constructor() {
    const applicationContext = { filesDir: '/test-app', setColorMode: noop };
    this.context = { filesDir: '/test', config: {}, getApplicationContext: () => applicationContext };
  }
}
const commons = { AppLogger: logger, LogTags: { ENTRY_ABILITY: 'EntryAbility' }, LOG_DOMAIN_LAUNCH: 1,
  DiagnosticPolicy: { configure: noop, hasTestHooks: () => true }, DistributionPolicy: { configure: noop }, DistributionChannel: {},
  setLedgerScopeSink: noop, ledgerResolveStale: () => 0, formatProductIdentity: () => '' };
// 文件保护由独立安装租约/Coordinator回归验证；此处为Ability注入成功的平台根配置边界。
const native = { getDiagnosticCapabilities: () => 0, desktopGameProcessState: () => 0, amclLogInit: noop,
  configureSideloadInstallRoot: () => true, setOhosFrameRateForeground: noop, cancelAllInput: noop,
  downloadDetachCallbacks: () => lifecycleEvents.push(['download-callbacks-detach']) };
const taskOwner = {
  configure: (...args) => ownerConfigurations.push(args),
  setForeground: value => { ownerForeground.push(value); lifecycleEvents.push(['owner-foreground', value]); },
};
const updater = { recoverActivity: () => [], recover: noop,
  setAbilityForeground: value => lifecycleEvents.push(['updater-foreground', value]) };
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
// 新增的传输验收装配也必须走真实实现。普通启动没有固定夹具，只允许一次存在性检查，
// 不能靠空模块被生产 catch 吞掉，也不能替换下载传输后仍把 owner 装配算通过。
const validationEngine={installValidationTransport:()=>assert.fail('ordinary boot cannot install fixture transport')};
const runtimeValidation=load('entry/src/main/ets/devtools/RuntimeDownloadValidation.ets',name=>{
  if(name==='commons')return commons;
  if(name==='@kit.CoreFileKit')return {fileIo:{accessSync:file=>{runtimeValidationReads.push(file);return false;}}};
  throw new Error('Unexpected runtime-validation dependency: '+name);
});
// JDK资格入口现在也参与热Want生命周期。启用测试能力并加载真实过滤逻辑，
// 普通启动/桌面错误Want必须在选择探针、访问文件和启动Native之前返回。
// 不能用空导出或无条件noop掩盖入口变化；资格本身的正向执行由专门套件验证。
const jdkQualificationWant=load('entry/src/main/ets/devtools/JdkQualificationWant.ets',name=>{
  if(name==='commons')return commons;
  if(name==='@kit.AbilityKit'||name==='@kit.CoreFileKit'||name==='feature_system')return {};
  if(name.endsWith('NativeProbeRegistry'))return {
    nativeProbeRegistry:()=>assert.fail('ordinary Want cannot select a JDK probe'),
  };
  if(name.endsWith('ProbeRegistryModel'))return {
    findProbe:()=>assert.fail('ordinary Want cannot resolve a JDK probe'),
    runProbe:()=>assert.fail('ordinary Want cannot run a JDK probe'),
  };
  throw new Error('Unexpected JDK qualification dependency: '+name);
});
// EntryAbility新增了整合包QA Want通道。装载真实识别/准入函数，证明普通启动和
// 桌面错误交接不会触发该通道；文件、下载和探针业务一旦被误调用，立即让用例失败。
const modpackDownloadWant=load('entry/src/main/ets/components/ModpackDownloadTestWant.ets',name=>{
  if(name==='commons')return commons;
  if(name==='entry/ProductBuildProfile')return {ProductBuildProfile:{product:'default'}};
  if(['@kit.AbilityKit','@kit.CoreFileKit','feature_core','feature_system','mods',
    '../export/ExportArchiveIO','../product/ProductIdentityCollector'].includes(name)){
    return new Proxy({}, {get:(_,member)=>assert.fail('ordinary Want cannot enter modpack QA: '+name+'.'+String(member))});
  }
  throw new Error('Unexpected modpack QA dependency: '+name);
});
const Ability = load('entry/src/main/ets/entryability/EntryAbility.ets', name => {
  if(name.endsWith('RuntimeDownloadValidation'))return runtimeValidation;
  if(name.endsWith('ModpackDownloadTestWant'))return modpackDownloadWant;
  if(name.endsWith('InputObservationTestWant'))return observationWant;
  if(name.endsWith('LauncherStartupRuntime'))return launcherStartupRuntime;
  if (name.endsWith('ModAudioRuntime')) return { ModAudioRuntime: {
    attach: context => { audioEvents.push(['attach', context]); lifecycleEvents.push(['audio-attach', context]); },
    setForeground: value => { audioEvents.push(['foreground', value]); lifecycleEvents.push(['audio-foreground', value]); },
    detach: () => { audioEvents.push(['detach']); lifecycleEvents.push(['audio-detach']); },
  } };
  if (name.endsWith('GameLayoutJournal')) return { GameLayoutJournal: {
    importPending: context => { layoutContexts.push(context); return Promise.resolve({ imported: 0, conflicts: [], deferred: false }); },
  } };
  if (name.endsWith('SessionRecoveryRuntime')) return { SessionRecoveryRuntime: {
    wake: context => { recoveryContexts.push(context); return Promise.resolve(); },
  } };
  if (name.endsWith('GameSessionHost')) return { stopGameSession: reason => lifecycleEvents.push(['game-stop', reason]) };
  if(name.endsWith('JdkQualificationWant'))return jdkQualificationWant;
  // 本组固定非store：initialize必须正常完成，不能靠生产catch吞缺失依赖后假装启动成功。
  if (name.endsWith('GameRunAdmission')) return { GameRunAdmission: {
    initialize: context => { runAdmissionContexts.push(context); },
  } };
  if (name.endsWith('GameExportCoordinator')) return { getGameExportCoordinator: () => ({
    recover: context => { exportRecoveryContexts.push(context); return Promise.resolve(); },
  }) };
  if (name === '@kit.AbilityKit') return { UIAbility, ConfigurationConstant: { ColorMode: {} } };
  if (name === 'commons') return commons;
  if (name === 'gamecontrol') return { getInputDeviceMonitor: () => ({ ensureStarted: () => inputMonitorStarts.push('start') }),
    getInputSourceRegistry: () => ({ notifyAbilityForeground: noop, releaseAllEnds: noop }) };
  if (name === 'feature_core') return { getTaskActivityOwner: () => taskOwner,
    setDownloadNativeEngine: engine => lifecycleEvents.push(['download-engine', engine]) };
  if (name === 'libentry.so') return { default: native };
  if (name === 'entry/ProductBuildProfile') return { ProductBuildProfile: {} };
  if (name === 'entry/ProductInputProfile') return { ProductInputProfile: {
    initialize: noop, selection: () => ({ isolatedGameProcess: false }) } };
  if (name === 'launch') return { SessionMarker: { readAndClear: () => null } };
  if (name.endsWith('LogShareConnectivityProbe')) return { runLogShareConnectivityWant: noop };
  // 自更新属于独立服务，本用例只核对Ability既有启动错误交接；不执行网络或安装事务。
  if (name.endsWith('SideloadUpdateTestWant')) return { runSideloadUpdateTestWant: noop };
  if (name.endsWith('InstallFence')) return { InstallFence: { init: noop } };
  if (name.endsWith('SideloadUpdateService')) return { SideloadUpdateService: { get: () => updater } };
  if (name.endsWith('ProductIdentityCollector')) return { collectProductIdentity: () => ({}) };
  if (name.endsWith('PlatformDfxWatcher')) return { PlatformDfxWatcher: {
    start: filesDir => dfxStarts.push(filesDir), recordLastExit: noop } };
  if (name.endsWith('ProcessRuntime')) return { EntryNativeLogSink: class {}, EntryLedgerScopeSink: class {}, installProcessNativeBridges: () => validationEngine };
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
assert.deepEqual(audioEvents.map(event => event[0]), Array(7).fill('attach'), '普通热Want不重新装配音频');
assert.ok(audioEvents.every(event => exportRecoveryContexts.includes(event[1])), '音频装配使用同一个真实Ability上下文');
assert.deepEqual(layoutContexts, exportRecoveryContexts, '冷启动必须继续进入真实恢复入口，不能因缺模块提前catch');
assert.deepEqual(recoveryContexts, exportRecoveryContexts, '布局交接后仍调用会话恢复owner');
assert.deepEqual(ownerConfigurations, Array.from({ length: 7 }, () => ['/test', '/test-app']), '活动owner配置真实模块与应用根');
assert.deepEqual(runtimeValidationReads,Array(7).fill('/test/runtime-download-validation.json'),'冷启动检查固定传输夹具，热Want不重复装配');
assert.deepEqual(dfxStarts, Array(7).fill('/test'));
assert.equal(inputMonitorStarts.length, 7, '每次真实onCreate仍确保进程输入监听启动');
assert.deepEqual(unexpectedLogs, [], '初始化不能靠生产catch吞掉缺失边界后假装成功');

// 音频没有独立start接口：前台事实由setForeground传入。这里只核Ability对端口的真实顺序，
// 不录音、不请求权限、不启动恢复任务；销毁仍保留进程owner并释放本Ability的音频挂接。
{
  const ability = new Ability();
  audioEvents.length = 0; lifecycleEvents.length = 0; ownerForeground.length = 0;
  ability.onCreate({}, {}); ability.onForeground(); ability.onBackground(); ability.onDestroy();
  assert.deepEqual(audioEvents, [['attach', ability.context], ['foreground', true], ['foreground', false], ['detach']]);
  assert.deepEqual(ownerForeground, [true, false, false]);
  const detachAt = lifecycleEvents.findIndex(event => event[0] === 'audio-detach');
  const gameStopAt = lifecycleEvents.findIndex(event => event[0] === 'game-stop');
  const callbackDetachAt = lifecycleEvents.findIndex(event => event[0] === 'download-callbacks-detach');
  assert.ok(detachAt >= 0 && detachAt < gameStopAt && gameStopAt < callbackDetachAt,
    '销毁先退休音频，再交接游戏会话，最后分离下载回调');
  assert.deepEqual(lifecycleEvents.at(-1), ['log-flush'], 'Ability退役刷出日志边沿，不关闭进程writer');
  assert.deepEqual(unexpectedLogs, [], '前后台与销毁不能因缺边界失败或由catch掩盖');
}

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

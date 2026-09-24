// Execute the actual Ability lifecycle methods and API-gated tab modifier with isolated system services.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const sdk = process.env.DEVECO_SDK_HOME || 'D:/Huawei/command-line-tools/sdk';
const candidates = ['typescript', path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'),
  path.join(sdk, 'ets/build-tools/ets-loader/node_modules/typescript')];
let ts;
for (const candidate of candidates) {
  try { ts = require(candidate); break; } catch (error) { if (error.code !== 'MODULE_NOT_FOUND') throw error; }
}
if (!ts) throw new Error('TypeScript compiler required: set DEVECO_SDK_HOME or install the project test compiler');
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
const storage = { setOrCreate: (key, value) => state.set(key, value), get: key => state.get(key) };
const logger = { info: noop, warn: noop, error: noop, setNativeLogSink: noop };
class UIAbility { constructor() { this.context = { filesDir: '/test', config: {}, getApplicationContext: () => ({ setColorMode: noop }) }; } }
const commons = { AppLogger: logger, LogTags: { ENTRY_ABILITY: 'EntryAbility' }, LOG_DOMAIN_LAUNCH: 1,
  DiagnosticPolicy: { configure: noop }, DistributionPolicy: { configure: noop }, DistributionChannel: {},
  setLedgerScopeSink: noop, ledgerResolveStale: () => 0, formatProductIdentity: () => '' };
const native = { getDiagnosticCapabilities: () => 0, desktopGameProcessState: () => 0, amclLogInit: noop };
const Ability = load('entry/src/main/ets/entryability/EntryAbility.ets', name => {
  if (name === '@kit.AbilityKit') return { UIAbility, ConfigurationConstant: { ColorMode: {} } };
  if (name === 'commons') return commons;
  if (name === 'gamecontrol') return { getInputDeviceMonitor: () => ({ ensureStarted: noop }) };
  if (name === 'libentry.so') return { default: native };
  if (name === 'entry/ProductBuildProfile') return { ProductBuildProfile: {} };
  if (name === 'entry/ProductInputProfile') return { ProductInputProfile: { initialize: noop } };
  if (name === 'launch') return { SessionMarker: { readAndClear: () => null } };
  if (name.endsWith('LogShareConnectivityProbe')) return { runLogShareConnectivityWant: noop };
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
  }
  for (const parameters of [undefined, {}, { desktopLaunchError: '' }, { desktopLaunchError: 42 }]) {
    state.clear();
    new Ability()[lifecycle]({ parameters }, {});
    assert.equal(state.has('desktopLaunchError'), false, lifecycle + ': invalid error');
  }
}

for (const version of [20, 21, 22, 23, 26]) {
  const calls = [];
  let materialReads = 0;
  const designKit = { get hdsMaterial() {
    assert.ok(version >= 23, 'API22 must not read the API23 material namespace');
    materialReads++;
    return { MaterialType: { ADAPTIVE: 11 }, MaterialLevel: { ADAPTIVE: 12 } };
  } };
  const globals = { BlurStyle: { COMPONENT_THICK: 3 }, TabsCacheMode: { CACHE_BOTH_SIDE: 1 } };
  const Style = load('entry/src/main/ets/components/LauncherTabsStyle.ets', name => {
    if (name === '@kit.BasicServicesKit') return { deviceInfo: { sdkApiVersion: version } };
    if (name === '@kit.UIDesignKit') return designKit;
    throw new Error('Unexpected dependency: ' + name);
  }, globals).LauncherTabsStyle;
  const attributes = { barOverlap: value => calls.push(['overlap', value]),
    barBackgroundBlurStyle: value => calls.push(['blur', value]) };
  if (version >= 23) {
    attributes.barFloatingStyle = value => calls.push(['floating', value]);
    attributes.cachedMaxCount = (...args) => calls.push(['cache', ...args]);
  }
  new Style(30).applyNormalAttribute(attributes);
  if (version < 23) {
    assert.deepEqual(calls, [['overlap', true], ['blur', 3]]);
    assert.equal(materialReads, 0);
  } else {
    assert.deepEqual(calls, [['floating', { barBottomMargin: 38, systemMaterialEffect: { materialType: 11, materialLevel: 12 } }], ['cache', 2, 1]]);
  }
}
console.log('Desktop ArkTS lifecycle errors and API20–26 tab compatibility PASS');

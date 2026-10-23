/**
 * 执行实际设置组件方法、能力adapter与resolver，覆盖重叠刷新、生命周期和busy重试。
 * 平台/NAPI边界可以控制完成顺序；负控只回退本次修复接缝，证明测试能识别旧行为。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const pure = makePureEtsLoader();
const launch = {};
for (const name of ['GraphicsProfileRegistry', 'GraphicsCapabilityContract', 'DeviceGraphicsFacts',
  'GraphicsGameFacts', 'GraphicsProfileResolver']) {
  Object.assign(launch, pure('launch/src/main/ets/' + name + '.ets'));
}
const componentSource = fs.readFileSync(new URL('../entry/src/main/ets/components/MobileglRendererSettings.ets', import.meta.url), 'utf8')
  .replaceAll('\r\n', '\n');
const adapterSource = fs.readFileSync(new URL('../entry/src/main/ets/runtime/GraphicsCapabilityAdapter.ets', import.meta.url), 'utf8');
const busy = { systemLibrary: false, querySupported: false, ready: false, contextCreated: false,
  pixelVerified: false, version: '', vendor: '', renderer: '', stage: 'native-gl-probe-busy' };
const good = { ...busy, systemLibrary: true, querySupported: true, stage: 'system-gl-entry-ready' };
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}

/** 每场景独立实例化生产模块；除显式旧行为负控，不改写adapter正文。 */
function fixture(probe, options = {}) {
  const calls = { native: 0, prepare: 0, delays: [], otherProfiles: [], warnings: [] };
  class PreferenceManager {
    graphicsProfile = 'auto'; graphicsProfileExplicit = true; devRendererOverride = '';
  }
  const manifestFor = manifestPath => {
    const version = manifestPath.includes('/26.3/') ? '26.3' : '1.20.1';
    const window = version === '26.3' ? 'sdl' : 'glfw';
    return { id: version, inheritsFrom: '', clientSha1: '', libraries: [
      'org/lwjgl/lwjgl/3.4.2/lwjgl.jar', 'org/lwjgl/lwjgl-opengl/3.4.2/opengl.jar',
      `org/lwjgl/lwjgl-${window}/3.4.2/window.jar`] };
  };
  const artifact = { schemaVersion: 1, abi: 'arm64-v8a',
    availableProfileIds: ['mobileglues', 'nativegl', 'mobilegl'],
    profiles: ['mobileglues', 'nativegl', 'mobilegl'].map(id => ({ id, artifactIds: ['fixture.so'] })) };
  const context = { bundleCodeDir: '/bundle', resourceManager: {
    getRawFileContent: async () => {
      if (options.artifactFailure?.()) throw new Error('manifest unavailable');
      return new TextEncoder().encode(JSON.stringify(artifact));
    } } };
  const native = {
    getNativeGlCapability: async (detailed, availability) => {
      assert.equal(detailed, false); assert.equal(availability, true);
      return probe(++calls.native);
    },
    getGraphicsCapabilityJson: (id, requirementId, windowProvider) => {
      calls.otherProfiles.push(id);
      return JSON.stringify({ evidenceProfileId: id, requirementId, windowProvider, loader: 'YES', instance: 'YES',
        windowSurface: 'NOT_RUN', physicalDevice: 'YES', apiVersion: '1.3', deviceExtensions: 'YES',
        featureBits: 'YES', queuePresentation: 'NOT_RUN', shaderToolchain: 'NOT_RUN', nativeArtifacts: 'YES' });
    },
  };
  const dependencies = { launch,
    feature_core: { VersionParser: { parse: manifestFor, detectVanillaVersion: path => manifestFor(path).id } },
    mods: { resolveInstalledMcVersion: (_dir, version) => version },
    commons: { AppLogger: { warn: (...args) => calls.warnings.push(args) } },
    'libentry.so': { default: native }, '@ohos.deviceInfo': { default: { deviceType: '2in1', sdkApiVersion: 26 } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => true } }, '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
    feature_system: { PreferenceManager }, '@kit.ArkTS': { util: { TextDecoder: { create: () => ({
      decodeToString: bytes => new TextDecoder().decode(bytes) }) } } } };
  // availabilityOnly会使真实历史作用域函数立即退出，不用伪造历史实现。
  dependencies['./GraphicsHistoryScope'] = makePureEtsLoader(dependencies)('entry/src/main/ets/runtime/GraphicsHistoryScope.ets');
  let source = adapterSource;
  if (options.oldAdapter) {
    source = source.replace('await nativeGlEntryCapability()', 'await testNapi.getNativeGlCapability(false, true)')
      .replaceAll('busy ? CapabilityEvidence.UNKNOWN : ', '');
  }
  const js = compiler.transpileModule(source, { compilerOptions: {
    module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'setTimeout', js)(name => {
    assert.ok(Object.hasOwn(dependencies, name), name); return dependencies[name];
  }, module, module.exports, (callback, delay) => { calls.delays.push(delay); queueMicrotask(callback); });
  const api = module.exports;
  const prepare = async (...args) => {
    calls.prepare++;
    const result = await api.prepareGraphicsProfileInput(...args);
    if (options.afterPrepare) await options.afterPrepare(args[2]);
    return result;
  };
  const componentDependencies = { PreferenceManager, ...launch, prepareGraphicsProfileInput: prepare,
    AppLogger: dependencies.commons.AppLogger };
  // 保留原方法正文，包括生命周期和最终行生成；不复制generation或错误处理逻辑。
  let component = componentSource;
  if (options.oldComponent) component = component.replace(
    'pending = this.pendingAvailabilityKey === key ? this.pendingAvailability : undefined', 'pending = undefined');
  const names = ['aboutToAppear', 'aboutToDisappear', 'refreshAvailability', 'loadAvailability', 'refreshPeerRows', 'availabilityReason'];
  const bodies = names.map(name => {
    const match = new RegExp('  (?:private )?(?:async )?' + name + '\\(').exec(component); assert.ok(match, name);
    const end = component.indexOf('\n  }', match.index); assert.ok(end > match.index);
    return component.slice(match.index, end + 4);
  });
  const componentJs = compiler.transpileModule('class Probe {\n' + bodies.join('\n') + '\n}\nmodule.exports=Probe;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  const componentModule = { exports: {} };
  new Function('module', ...Object.keys(componentDependencies), componentJs)(componentModule, ...Object.values(componentDependencies));
  const subject = new componentModule.exports();
  Object.assign(subject, { refreshGeneration: 0, availabilityActive: true, pendingAvailabilityKey: '',
    pendingAvailability: undefined, lastInputKey: '', lastInput: undefined, peerRows: [],
    mcDir: '/mc', mcVersion: '1.20.1', getUIContext: () => ({ getHostContext: () => context }) });
  return { api, subject, calls, context };
}

// 旧审查反例：两个生命周期刷新重叠时只允许一份prepare/native查询，成功结果必须可选。
{
  const pending = deferred();
  const f = fixture(() => pending.promise);
  const first = f.subject.loadAvailability();
  const second = f.subject.loadAvailability();
  await tick();
  assert.equal(f.calls.prepare, 1); assert.equal(f.calls.native, 1);
  pending.resolve(good);
  await Promise.all([first, second]);
  assert.equal(f.subject.peerRows.find(row => row.id === 'nativegl').enabled, true);
  assert.equal(f.subject.pendingAvailability, undefined);
  await f.subject.loadAvailability();
  assert.equal(f.calls.native, 2, '完成后重新查询，不保留阳性缓存');
}

// 即使不同组件/游戏并行准备，也共享仅入口NAPI，返回证据各自绑定游戏/provider。
{
  const pending = deferred();
  const f = fixture(() => pending.promise);
  const glfw = f.api.prepareGraphicsProfileInput(f.context, '/mc', '1.20.1', 'auto', true);
  const sdl = f.api.prepareGraphicsProfileInput(f.context, '/mc', '26.3', 'auto', true);
  await tick(); assert.equal(f.calls.native, 1);
  pending.resolve(good);
  const results = await Promise.all([glfw, sdl]);
  assert.deepEqual(results.map(value => value.capabilityResults[0].gameVersion), ['1.20.1', '26.3']);
  assert.deepEqual(results.map(value => value.capabilityResults[0].windowProvider), ['GLFW', 'SDL3']);
}

// 外部详细探针造成busy：有界重试成功或耗尽，均不影响其他候选的证据准备。
for (const exhausted of [false, true]) {
  const f = fixture(call => exhausted || call < 3 ? busy : good);
  await f.subject.loadAvailability();
  assert.equal(f.calls.native, 3);
  assert.deepEqual(f.calls.delays, [25, 50]);
  const evidence = f.subject.lastInput.capabilityResults.find(value => value.evidenceProfileId === 'nativegl');
  assert.equal(evidence.systemLibrary, exhausted ? 'UNKNOWN' : 'YES');
  assert.equal(evidence.queryGl, exhausted ? 'UNKNOWN' : 'YES');
  for (const key of ['eglContext', 'glVersion', 'pixelReadback']) assert.equal(evidence[key], 'NOT_RUN');
  assert.ok(f.calls.otherProfiles.includes('mobilegl'));
  assert.equal(f.subject.peerRows.find(row => row.id === 'mobilegl').enabled, true);
  assert.equal(f.subject.peerRows.find(row => row.id === 'nativegl').enabled, !exhausted);
  if (exhausted) assert.match(f.subject.peerRows.find(row => row.id === 'nativegl').reason, /暂时忙碌/);
  const fullScope = f.api.nativeGlCapabilityResult(busy, 'GLFW', '1.20.1', false);
  for (const key of ['eglContext', 'glVersion', 'pixelReadback']) assert.equal(fullScope[key], 'NOT_RUN');
}

// NAPI拒绝会释放合并槽位；下一次查询可恢复，失败候选不拖垮MobileGL。
{
  const f = fixture(call => { if (call === 1) throw new Error('worker unavailable'); return good; });
  await f.subject.loadAvailability();
  assert.equal(f.subject.peerRows.find(row => row.id === 'mobilegl').enabled, true);
  await f.subject.loadAvailability();
  assert.equal(f.calls.native, 2);
  assert.equal(f.subject.peerRows.find(row => row.id === 'nativegl').enabled, true);
}

// 切实例立即撤销旧行；两种完成顺序均不能让旧请求覆盖SDL实例或清掉其在途引用。
for (const oldFirst of [false, true]) {
  const old = deferred();
  const current = deferred();
  const f = fixture(() => good, { afterPrepare: version => version === '1.20.1' ? old.promise : current.promise });
  const first = f.subject.loadAvailability();
  await tick();
  f.subject.peerRows = [{ id: 'stale-fixture' }];
  f.subject.mcVersion = '26.3';
  const second = f.subject.loadAvailability();
  assert.deepEqual(f.subject.peerRows, []);
  const currentPending = f.subject.pendingAvailability;
  if (oldFirst) {
    old.resolve(); await first;
    assert.equal(f.subject.pendingAvailability, currentPending);
    assert.equal(f.subject.lastInput, undefined);
    current.resolve(); await second;
  } else {
    current.resolve(); await second;
    old.resolve(); await first;
  }
  assert.equal(f.subject.lastInput.realMcVersion, '26.3');
  assert.equal(f.subject.peerRows.find(row => row.id === 'nativegl').provider, 'SDL3');
  assert.match(f.subject.availabilityMessage, /26\.3/);
}

// 必需manifest异常共享给同键等待者，但必须清掉失败Promise，后续刷新可重新读取。
{
  let unavailable = true;
  const f = fixture(() => good, { artifactFailure: () => unavailable });
  await Promise.all([f.subject.loadAvailability(), f.subject.loadAvailability()]);
  assert.equal(f.calls.prepare, 1); assert.equal(f.calls.native, 0);
  assert.equal(f.subject.pendingAvailability, undefined);
  assert.deepEqual(f.subject.peerRows, []);
  assert.match(f.subject.availabilityMessage, /能力读取失败/);
  unavailable = false;
  await f.subject.loadAvailability();
  assert.equal(f.calls.prepare, 2); assert.equal(f.calls.native, 1);
  assert.equal(f.subject.peerRows.find(row => row.id === 'nativegl').enabled, true);
}

// 离开时撤销发布，离开后的Watch不发起查询；重新进入同实例可等候在途任务。
for (const reenter of [false, true]) {
  const pending = deferred();
  const f = fixture(() => pending.promise);
  const first = f.subject.loadAvailability();
  await tick();
  f.subject.aboutToDisappear();
  await f.subject.loadAvailability();
  assert.equal(f.calls.prepare, 1);
  if (reenter) f.subject.aboutToAppear();
  pending.resolve(good); await first; await tick();
  assert.equal(f.calls.prepare, 1);
  assert.equal(f.subject.peerRows.length > 0, reenter);
  if (reenter) assert.equal(f.subject.peerRows.find(row => row.id === 'nativegl').enabled, true);
}

// 负控：回退同键合并与旧busy布尔归一化，真实链重新得到“systemLibrary=NO/不可选”。
{
  const pending = deferred();
  const f = fixture(call => call === 1 ? pending.promise : busy, { oldAdapter: true, oldComponent: true });
  const first = f.subject.loadAvailability();
  const second = f.subject.loadAvailability();
  await second; pending.resolve(good); await first;
  assert.equal(f.calls.prepare, 2); assert.equal(f.calls.native, 2);
  const native = f.subject.lastInput.capabilityResults.find(value => value.evidenceProfileId === 'nativegl');
  assert.equal(native.systemLibrary, 'NO');
  assert.equal(f.subject.peerRows.find(row => row.id === 'nativegl').enabled, false);
  assert.throws(() => assert.equal(native.systemLibrary, 'UNKNOWN'), assert.AssertionError);
  assert.throws(() => assert.equal(f.calls.prepare, 1), assert.AssertionError);
}
console.log('Graphics availability PASS: actual settings/adapter/resolver, shared entry query, scoped evidence, bounded busy retries, candidate isolation, lifecycle/order guards and old-behavior negative control');

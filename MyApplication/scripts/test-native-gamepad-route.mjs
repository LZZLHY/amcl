/**
 * 原生手柄路由的生产组合回归：正式input plan/parser、策略、完整ProcessRuntime、
 * GamepadManager/GameInputRuntime均用真实源码。只替换系统时钟、Preferences和NAPI
 * 运输边缘；平台init成功不能代替route资格，更不能代替真实游戏或mod消费证明。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { environment } from './lib/ets-runtime-fixture.mjs';

const root = path.resolve(import.meta.dirname, '..');
const policyPath = 'entry/src/main/ets/runtime/NativeGamepadRoutePolicy.ets';
const processPath = 'entry/src/main/ets/runtime/ProcessRuntime.ets';
const plan = makePureEtsLoader()('launch/src/main/ets/ResolvedInputPlan.ets');
const policy = makePureEtsLoader({ launch: plan })(policyPath);
const { GamepadOutputRoute: Route, NativeGamepadRouteStatus: Status,
  NativeGamepadRouteReason: Reason } = policy;
const noop = () => {};
let passed = 0;
const pass = name => { passed++; console.log('PASS ' + name); };

/** 输入计划由正式决议与序列化产生；L2仍使用GLFW窗口，不能靠window字段误判出口。 */
function wire(abi) {
  return plan.serializeInputPlan(plan.resolveInputPlan({ lwjglVersion: abi === 'LWJGL2' ? 2 : 3,
    needsLwjgl322Slot: false, usesSdl3: abi === 'SDL3' }, '/frozen/selected-java-slot'));
}
const wires = { empty: '', LWJGL2: wire('LWJGL2'), GLFW: wire('GLFW'), SDL3: wire('SDL3') };

/** 完整执行ProcessRuntime初始化；未声明的系统依赖必须失败，不用三行规则镜像代替模块。 */
function processFixture(requested, captureResult, override) {
  const values = new Map(), calls = [], ledgerOwnership = [], preferences = { requested };
  const storage = { setOrCreate: (key, value) => values.set(key, value), get: key => values.get(key) };
  const native = { getDiagnosticCapabilities: () => 0,
    desktopSetGamepadNativeMode: enabled => { calls.push(['native-mode', enabled]); return captureResult; } };
  class Preferences { phoneExternalDir = ''; desktopNativeGamepad = preferences.requested; }
  const dependencies = {
    'libentry.so': { default: native },
    'commons': { DiagnosticPolicy: { configure: noop }, DistributionPolicy: { configure: noop },
      DistributionChannel: {}, AppLogger: { warn: noop }, setLedgerScopeSink: noop,
      // 完整ProcessRuntime现在显式禁止游戏进程承担父账本维护；记录实际接线而非吞掉新调用。
      configureLedgerMaintenanceOwner: owner => ledgerOwnership.push(owner) },
    'feature_core': { DownloadManager: { instance: () => ({ initializeCaBundle: noop }) },
      setDownloadNativeEngine: noop, setRelayNativeBridge: noop, setForgeNativeBridge: noop },
    'feature_system': { GameStorage: { setPhoneExternalDir: noop }, PreferenceManager: Preferences,
      setSystemNativeBridge: noop },
    'gamecontrol': { setControlNativeSink: noop, getInputSourceRegistry: () => ({ setNativeSink: noop }),
      getInputDeviceMonitor: () => ({ ensureStarted: noop }) },
    'launch': { setLaunchNativeBridge: noop, setRuntimeSlotNativeOps: noop },
    'entry/ProductBuildProfile': { ProductBuildProfile: {} },
    'entry/ProductInputProfile': { ProductInputProfile: { initialize: noop } },
    'entry/ProductLauncherWindowChrome': {}, '@kit.AbilityKit': {}, '@kit.ArkUI': {}, '@kit.CoreFileKit': {},
    './NativeGamepadRoutePolicy': policy
  };
  const body = override ?? fs.readFileSync(path.join(root, processPath), 'utf8');
  const result = compiler.transpileModule(body, { fileName: processPath,
    compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 }, reportDiagnostics: true });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === compiler.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'AppStorage', result.outputText)(name => {
    assert.ok(Object.hasOwn(dependencies, name), 'unmocked ProcessRuntime boundary ' + name);
    return dependencies[name];
  }, module, module.exports, storage);
  const initialize = () => module.exports.initializeGameProcess({ filesDir: '/private/files', config: { colorMode: 1 } });
  initialize();
  assert.deepEqual(ledgerOwnership, [false], '游戏进程初始化必须明确关闭父账本维护所有权');
  return { values, calls, preferences, initialize,
    requested: () => values.get(policy.NATIVE_GAMEPAD_ROUTE_REQUESTED_KEY),
    ready: () => values.get(policy.NATIVE_GAMEPAD_CAPTURE_READY_KEY) };
}

/** 真实来源输出记录；emitControl是生产采用的按设备/控件运输接缝，不另造owner归约器。 */
function sourceFixture(rejectRelease = false) {
  const env = environment();
  const manager = env.load('gamecontrol/src/main/ets/GamepadManager.ets');
  const keys = env.load('gamecontrol/src/main/ets/OhosKeyCodes.ets');
  const { GameInputRuntime } = env.load('gamecontrol/src/main/ets/GameInputRuntime.ets');
  const output = [], state = { rejectRelease, now: 0 };
  const pad = new manager.GamepadManager(undefined, {
    emitControl: (device, control, code, action) => {
      if (action === 0 && state.rejectRelease) return false;
      output.push([device, control, code, action]); return true;
    }, emitKey: () => { throw Error('unexpected compatibility key route'); },
    emitMouse: () => { throw Error('unexpected compatibility mouse route'); },
    emitScroll: noop, emitLookDelta: (x, y, ns) => output.push(['look', x, y, ns])
  });
  const runtime = new GameInputRuntime(pad, () => state.now, noop);
  runtime.setState(true, true);
  const applied = () => pad.isMappedOutputEnabled() ? Route.Mapped : Route.Native;
  return { env, manager, keys, pad, runtime, output, state, applied };
}

/** 这只是调用正式setter/getter的测试组织，不承担路由规则；规则完全来自被测policy。 */
function apply(fixture, requested, ready, inputWire, implementation = policy) {
  const candidate = implementation.resolveNativeGamepadRoute(requested, ready, inputWire, fixture.applied());
  fixture.pad.setMappedOutputEnabled(candidate.mappedOutputEnabled);
  return implementation.resolveNativeGamepadRoute(requested, ready, inputWire, fixture.applied());
}

for (const [name, inputWire] of Object.entries(wires)) {
  for (const requested of [false, true]) for (const ready of [false, true]) {
    const f = sourceFixture(), decision = apply(f, requested, ready, inputWire);
    const native = requested && ready && (name === 'GLFW' || name === 'SDL3');
    assert.equal(decision.desired, requested ? Route.Native : Route.Mapped);
    assert.equal(decision.applied, native ? Route.Native : Route.Mapped);
    assert.equal(decision.abiNativeOutlet, name === 'GLFW' || name === 'SDL3');
    assert.equal(f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true), true);
    assert.equal(f.output.length, native ? 0 : 1, name + ': actual mapped press');
    if (!requested) assert.equal(decision.status, Status.Applied);
    else if (name === 'empty') assert.equal(decision.reason, Reason.PlanUnbound);
    else if (name === 'LWJGL2') assert.equal(decision.status, Status.Unsupported);
    else if (!ready) assert.equal(decision.reason, Reason.CaptureUnavailable);
    else assert.equal(decision.status, Status.Applied);
    f.runtime.stop();
  }
}
assert.equal(policy.resolveNativeGamepadRoute(true, true, wires.LWJGL2).inputAbi, 'LWJGL2');
assert.equal(policy.resolveNativeGamepadRoute(true, true, wires.GLFW.replace('binding=libglfw.so', 'binding=liblwjgl_v2.so')).reason, Reason.PlanInvalid);
assert.equal(policy.resolveNativeGamepadRoute(true, true, wires.GLFW.replace('abi=GLFW', 'abi=LWJGL2')).abiNativeOutlet, false);
pass('actual input plans empty/L2/GLFW/SDL × request/capture; invalid combinations; mapped source output');

for (const requested of [false, true]) for (const rawReady of [false, true]) {
  const f = processFixture(requested, rawReady);
  assert.equal(f.requested(), requested);
  assert.equal(f.ready(), requested && rawReady, 'mode-off success must not claim capture READY');
  assert.equal(f.values.has('nativeGamepadOutputActive'), false);
  assert.deepEqual(f.calls, [['native-mode', requested]]);
}
pass('actual ProcessRuntime publishes requested/capture facts only; platform init is not route selection');

{
  // SetNativeMode(false)的成功不能升级采集事实；直接撤回完整ProcessRuntime中的这道限定。
  const original = fs.readFileSync(path.join(root, processPath), 'utf8');
  const before = 'NATIVE_GAMEPAD_CAPTURE_READY_KEY, nativePad && padReady';
  assert.equal(original.split(before).length, 2, 'unique capture-fact mutation');
  const bad = processFixture(false, true, original.replace(before, 'NATIVE_GAMEPAD_CAPTURE_READY_KEY, padReady'));
  assert.throws(() => assert.equal(bad.ready(), false), assert.AssertionError);
  pass('compiled ProcessRuntime negative rejected: mode-off success falsely claims capture READY');
}

{
  const f = sourceFixture();
  f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true);
  assert.equal(f.output.at(-1)[3], 1);
  const decision = apply(f, true, true, wires.GLFW);
  assert.equal(decision.applied, Route.Native);
  assert.equal(f.output.at(-1)[3], 0, 'old mapped DOWN-time contribution released before route change');
  const previous = f.output.length;
  f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true);
  assert.equal(f.output.length, previous, 'native selected must not additionally send mapped presses');
  apply(f, false, true, wires.GLFW);
  f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true);
  assert.equal(f.output.length, previous + 1);
  f.runtime.stop();
}
pass('actual manager held-route transition releases old contribution and never duplicates mapped press');

{
  const f = sourceFixture(true);
  f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true);
  const pending = apply(f, true, true, wires.SDL3);
  assert.equal(pending.target, Route.Native);
  assert.equal(pending.applied, Route.Mapped);
  assert.equal(pending.status, Status.Pending);
  assert.equal(pending.reason, Reason.ApplyPending);
  assert.equal(f.pad.isMappedOutputEnabled(), true, 'failed RELEASE cannot fake native applied');
  f.state.rejectRelease = false;
  assert.equal(apply(f, true, true, wires.SDL3).applied, Route.Native);
  assert.equal(f.output.filter(e => e[3] === 0).length, 1);
  f.runtime.stop();
}
{
  const f = sourceFixture();
  const layout = f.env.load('gamecontrol/src/main/ets/ControlLayout.ets');
  const disabled = layout.defaultGamepadConfig(); disabled.enabled = false;
  assert.equal(f.pad.updateConfig(disabled), true);
  assert.equal(f.pad.isEnabled(), false);
  assert.equal(f.pad.isMappedOutputEnabled(), true, 'feature disabled is not a native route acknowledgement');
  assert.equal(apply(f, false, false, wires.GLFW).applied, Route.Mapped);
  f.runtime.stop();
}
pass('actual RELEASE rejection retains pending/applied, successful retry finishes; config.enabled is separate');

{
  const process = processFixture(true, true), f = sourceFixture();
  const requested = process.requested(), ready = process.ready();
  assert.equal(apply(f, requested, ready, wires.GLFW).applied, Route.Native);
  process.preferences.requested = false;
  assert.equal(process.requested(), true, 'setting change does not update current frozen process fact');
  assert.equal(apply(f, requested, ready, wires.GLFW).applied, Route.Native);
  const next = processFixture(false, true), nextSource = sourceFixture();
  assert.equal(apply(nextSource, next.requested(), next.ready(), wires.GLFW).applied, Route.Mapped);
  nextSource.pad.handleButtonForDevice(9, nextSource.keys.OHOS_BUTTON_A, true);
  assert.equal(nextSource.output.length, 1);
  f.runtime.stop(); nextSource.runtime.stop();
}
pass('actual Preferences initialization freezes this session; new preference is adopted by next process session');

/** 撤回候选只修改内存生产正文，要求成功转译且由真实source行为/应用回执拒绝。 */
for (const [name, before, after] of [
  ['L2 window provider mistaken for input ABI', 'plan.abi === InputAbi.SDL3)', 'plan.abi === InputAbi.SDL3 || plan.abi === InputAbi.LWJGL2)'],
  ['empty plan pending qualification removed', 'if (inputPlanWire.length === 0) {', "if (false) {"],
  ['platform capture ignored', '} else if (!platformCaptureReady) {', '} else if (false) {'],
  ['target pretends applied', 'status === NativeGamepadRouteStatus.Applied && applied !== target', 'false']
]) {
  const original = fs.readFileSync(path.join(root, policyPath), 'utf8');
  assert.equal(original.split(before).length, 2, name + ': unique mutation');
  const bad = makePureEtsLoader({ launch: plan }, { [policyPath]: original.replace(before, after) })(policyPath);
  const f = sourceFixture(name === 'target pretends applied');
  if (name === 'target pretends applied') f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true);
  // 空计划负控让其退到Invalid，仍须由状态事实识别，而不是靠编译错误。
  const inputWire = name.startsWith('L2') ? wires.LWJGL2 : name.startsWith('empty') ? '' : wires.GLFW;
  const decision = apply(f, true, !name.startsWith('platform'), inputWire, bad);
  assert.throws(() => {
    if (name.startsWith('L2')) {
      f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true); assert.equal(f.output.length, 1);
    } else if (name.startsWith('empty')) assert.equal(decision.reason, Reason.PlanUnbound);
    else if (name.startsWith('platform')) {
      f.pad.handleButtonForDevice(7, f.keys.OHOS_BUTTON_A, true); assert.equal(f.output.length, 1);
    } else assert.equal(decision.status, Status.Pending);
  }, assert.AssertionError, name);
  f.state.rejectRelease = false; f.runtime.stop();
  pass('compiled production negative rejected: ' + name);
}
// 真正的政策快照才进入产品文字；保存开关不被格式化函数读取，也不把目标当实际应用。
for (const [inputWire, capture, applied, expected] of [
  [wires.LWJGL2, true, Route.Mapped, /不支持原生手柄/],
  ['bad-plan', true, Route.Mapped, /路线无法确认/],
  [wires.empty, true, Route.Mapped, /等待游戏输入准备/],
  [wires.GLFW, false, Route.Mapped, /采集暂不可用/],
  [wires.GLFW, true, Route.Mapped, /等待原输入结束/],
  [wires.GLFW, true, Route.Native, /已启用原生手柄路线.*游戏还需支持控制器/]
]) {
  const decision = policy.resolveNativeGamepadRoute(true, capture, inputWire, applied);
  const message = policy.nativeGamepadRouteStatusMessage(decision);
  assert.match(message, expected);
  if (decision.status !== Status.Applied) assert.doesNotMatch(message, /已启用原生手柄路线/);
  assert.doesNotMatch(message, /input-|source-|unsupported|pending|consumer/);
}
assert.equal(policy.nativeGamepadRouteStatusMessage(undefined), '');
assert.equal(policy.nativeGamepadRouteStatusMessage(policy.resolveNativeGamepadRoute(false, true, wires.GLFW)), '');
pass('real route messages: original Applied/Pending/Unsupported, L2/unknown/capture false and no internal reason tokens');

// 当前Host冻结事实不会因设置热变更进入这些回执；纯政策契约仍接收真实applied参数。
// 每例都由正式resolver生成，不能手造DTO再宣称当前产品已发生Native→Mapped等待。
for(const [requested,capture,inputWire,expectedReason] of [
  [true,true,wires.LWJGL2,Reason.AbiUnsupported],
  [true,true,'bad-plan',Reason.PlanInvalid],
  [true,true,wires.empty,Reason.PlanUnbound],
  [true,false,wires.GLFW,Reason.CaptureUnavailable],
  [false,true,wires.GLFW,Reason.ApplyPending]
]){
  const decision=policy.resolveNativeGamepadRoute(requested,capture,inputWire,Route.Native);
  assert.equal(decision.applied,Route.Native);assert.equal(decision.target,Route.Mapped);
  assert.equal(decision.reason,expectedReason);assert.notEqual(decision.status,Status.Applied);
  const message=policy.nativeGamepadRouteStatusMessage(decision);
  assert.match(message,/仍保持原生手柄路线/,'ACTUAL_APPLIED_ROUTE 目标映射不能伪装实际已切换');
  assert.doesNotMatch(message,/仍使用启动器映射|已启用原生手柄路线/);
}
pass('real resolver receipts preserve Native applied during Pending/Unsupported, including mapped request awaiting original route');

// 移除Pending分支须真正改变用户提示，编译正常的生产负控不能靠导入失败冒充命中。
{
  const original = fs.readFileSync(path.join(root, policyPath), 'utf8');
  const anchor = 'if (decision.status === NativeGamepadRouteStatus.Pending) {';
  assert.equal(original.split(anchor).length, 2);
  const bad = makePureEtsLoader({ launch: plan }, { [policyPath]: original.replace(anchor, 'if (false) {') })(policyPath);
  const pending = policy.resolveNativeGamepadRoute(true, true, wires.GLFW, Route.Mapped);
  assert.throws(() => assert.match(bad.nativeGamepadRouteStatusMessage(pending), /等待原输入结束/), assert.AssertionError);
  pass('compiled route-message withdrawal cannot hide actual pending application');
}
{
  const original=fs.readFileSync(path.join(root,policyPath),'utf8');
  const anchor='const currentRoute: string = decision.applied === GamepadOutputRoute.Native';
  assert.equal(original.split(anchor).length,2);
  const bad=makePureEtsLoader({launch:plan},{[policyPath]:original.replace(anchor,
    'const currentRoute: string = decision.target === GamepadOutputRoute.Native')})(policyPath);
  const waiting=policy.resolveNativeGamepadRoute(false,true,wires.GLFW,Route.Native);
  assert.throws(()=>assert.match(bad.nativeGamepadRouteStatusMessage(waiting),/仍保持原生手柄路线/,
    'ACTUAL_APPLIED_ROUTE'),error=>error instanceof assert.AssertionError&&error.message.includes('ACTUAL_APPLIED_ROUTE'));
  pass('compiled target-as-applied message withdrawal rejected by actual resolver Native receipt');
}
console.log('Native gamepad route production tests: ' + passed + ' groups passed; no consumer/mod-use claim');

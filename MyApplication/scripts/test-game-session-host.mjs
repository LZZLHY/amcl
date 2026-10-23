/**
 * 完整执行生产GameSessionHost，系统时钟、NAPI、Window和来源端口均显式注入。
 * 不复制宿主状态机；检查原租约、迟到窗口、无前端维护及退出、故障后继续和重复停止。
 * 这些是事件线程/平台边界的宿主证明，不代替真实Surface、JVM或设备最终ABI轨迹。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { environment } from './lib/ets-runtime-fixture.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import compiler from './lib/ets-compiler.mjs';

const plan = makePureEtsLoader()('launch/src/main/ets/ResolvedInputPlan.ets');
const wire = 'v=v1;abi=LWJGL2;slot=LWJGL2;window=GLFW;binding=liblwjgl_v2.so;policy=l2-pull';
const noop = () => {};
const flush = async () => { for (let index = 0; index < 15; index++) await Promise.resolve(); };
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }

/** 只替换宿主依赖的系统/子系统边缘；所有生命周期决策由实际Host类执行。 */
function fixture({ isolated = false, realSources = false, hostSource = undefined, sharedLook = undefined, timerFaults = false, touchApi = undefined } = {}) {

  const calls = [];
  const state = { running: true, grab: false, now: 0, throwOn: new Set(), deferredEnter: undefined, deferredRestore: undefined };
  const record = (name, ...values) => { calls.push([name, ...values]); if (state.throwOn.has(name)) throw new Error('fault:' + name); };
  const windows = [];
  class Window {
    constructor() { this.id = windows.length + 1; windows.push(this); }
    enter() { record('window-enter', this.id); const pending = state.deferredEnter; state.deferredEnter = undefined;
      return pending ? pending.promise : Promise.resolve(this.snapshot()); }
    snapshot() { return { windowId: this.id, contextGeneration: this.id, width: 1200, height: 800 }; }
    restore() { record('window-restore', this.id); const pending = state.deferredRestore; state.deferredRestore = undefined;
      return pending ? pending.promise : Promise.resolve(); }
  }
  class Runtime {
    constructor(_pad, _clock, _reset, _beforeSample, suspended, foreground) { this.suspended = suspended; this.foreground = foreground; this.live = true; }
    start(store) { if (this.store === store) return; this.store = store; record('runtime-start'); }
    stop() { this.store = undefined; record('runtime-stop'); }
    setState(active, grabbed) { this.active = active; this.grabbed = grabbed; record('runtime-state', active, grabbed); }
    resumeAfterLifecycle() { this.live = true; record('runtime-resume'); }
    isLifecycleActive() { return this.live; }
    reconcile() { record('runtime-reconcile'); }
  }
  class Configuration {
    prepareStatus(store, activity) { record('configuration-report-prepare', store, activity); }
    bindSession(activity) { record('configuration-bind', activity); return this.store !== undefined; }
    start(store) { if (this.store === store) return; this.store = store; record('configuration-start'); }
    stop() { this.store = undefined; record('configuration-stop'); }
    reconcile() { record('configuration-reconcile'); }
  }
  /** 文本子系统边界仅返回受控回执；Host读取/异步步骤更新仍执行真实生产逻辑。 */
  class TextRuntime {
    listeners = new Set();
    start() { record('text-start'); }
    maintain() { record('text-reconcile'); }
    stop() { record('text-stop'); return this.snapshot(); }
    snapshot() { return { stopOutcome: state.textStopOutcome ?? 'Completed', failure: '',
      callbackFenced: true, localLeaseClosed: true, platformDetachResolved: true }; }
    addStopOutcomeListener(callback) { this.listeners.add(callback); }
    removeStopOutcomeListener(callback) { this.listeners.delete(callback); }
    emitOutcome(snapshot) { for (const listener of this.listeners) listener(snapshot); }
  }
  class Gamepad {
    constructor(_config, emitter) { this.mapped = true; this.emitter = emitter; }
    setMappedOutputEnabled(value) { if (!value && state.rejectMappedRetirement) return;
      this.mapped = value; record('mapped-choice', value); }
    isMappedOutputEnabled() { return this.mapped; }
    // 该子系统边缘只确认维护调用与原对象转交；原连接持有/退休算法由realSources分支的真实Manager验证。
    reconcileConnectionCleanup() { record('mapped-connection-reconcile'); return true; }
    releaseConnection(connection) { record('mapped-connection-retire', connection); return this.emitter.releaseConnectionControls(connection); }
  }
  const ends = new Set();
  let registry = { register: end => { ends.add(end); record('source-register'); }, unregister: end => { ends.delete(end); record('source-unregister'); },
    releaseAllEnds: reason => record('source-release', reason), releaseEndsOfSource: (source, reason) => record('source-grab-release', source, reason) };
  const pointer = { sync: (...values) => record('pointer-sync', ...values), tick: () => record('pointer-tick'), restore: () => record('pointer-restore') };
  const native = { configureInputProduct: () => { record('product-configure'); return state.sourceOwnerUnavailable ? 5 : 0; },
    sendSourceKeyEvent: () => true, sendSourceMouseEvent: () => true, sendSourceScrollEvent: () => true, sendSourceCursorSample: () => true,
    setCursorLocked: (...values) => record('cursor-lock', ...values), desktopGamepadFocus: value => record('pad-focus', value),
    onGrabChange: callback => { record(callback ? 'grab-subscribe' : 'grab-unsubscribe'); state.grabCallback = callback; },
    cancelAllInput: () => record('native-cancel'), uninstallWindowInputFilters: id => record('filter-retire', id),
    isGrabbed: () => { record('grab-read'); return state.grab; }, cursorLockWatchdogTick: () => false,
    inputInvariantTick: () => record('invariant'), mcIsRunning: () => state.running, mcForceExit: () => record('force-exit'),
    gameGuiStartSession: activity => { record('gui-start', activity); return 17; },
    gameGuiStopSession: scope => { record('gui-stop', scope); return true; },
    setOhosFrameRateForeground: (...values) => record('ability-foreground', ...values) };
  if (sharedLook !== undefined) native.sharedLookExecutionSupported = () => { record('look-cold-contract'); return sharedLook; };
  class Logger { constructor(activityId) { this.activityId = activityId; } info(_tag, text) { record('log', text); } }
  const context = { startAbility: async want => { record('return-ability', want.parameters.gameExitActivityId);
    if (state.handoff !== undefined) await state.handoff.promise; } };
  const gamecontrol = { GamepadManager: Gamepad, GameInputRuntime: Runtime, InputConfigurationRuntime: Configuration,
    AmclInputSource: { Gamepad: 2 }, GLFW_PRESS: 1, getInputSourceRegistry: () => registry,
    getInputDeviceMonitor: () => deviceMonitor, getPointerVisibility: () => pointer };
  let deviceMonitor;
  let deviceConnections;
  const hostPath = 'entry/src/main/ets/runtime/GameSessionHost.ets';
  // 修复前原文只用于撤回负控；当前源码仍是默认的被测生产实现，证据文件留在外部run目录。
  const sourceOverrides = hostSource !== undefined && hostSource !== fs.readFileSync(new URL('../' + hostPath, import.meta.url), 'utf8')
    ? { [hostPath]: () => hostSource } : undefined;
  // 仅故障组替换系统timer边缘；回调仍为真实Host闭包，timer登记格式与原fixture一致。
  let timerSerial=10000;
  const timerEdges=timerFaults?{
    setTimeout(fn,delay=0){if(state.failTimerSchedule)throw Error('controlled schedule failure');
      const id=++timerSerial;env.timer.set(id,{fn,delay});return id;},
    clearTimeout(id){if(state.failTimerClear)throw Error('controlled clear failure');env.timer.delete(id);},
  }:{};
  const env = environment({ commons: { ActivityLogger: Logger, LOG_DOMAIN_LAUNCH: 1,
    // 记录真实Host的故障出口及原错误，仅作为诊断oracle，不改变异常和清理政策。
    AppLogger: { warn: (_tag,text,error) => record('fault',text,error?.message ?? String(error)),
      error: noop, info: noop, debug: noop } }, sourceOverrides,
    globals: { ...timerEdges, AppStorage: { get: key => key === 'desktopGameProcess' ? isolated
      : key === 'nativeGamepadRouteRequested' ? state.nativeGamepadRequested
      : key === 'nativeGamepadCaptureReady' ? state.nativeGamepadCaptureReady : undefined } },
    imports: {
      '@kit.AbilityKit': { appRecovery: { restartApp: () => record('restart-app') } },
      '@kit.BasicServicesKit': { systemDateTime: { TimeType: { ACTIVE: 1 }, getUptime: () => { if(state.clockThrows)throw Error('controlled clock failure'); return state.now; } } },

      'gamecontrol': gamecontrol,
      'launch': plan, 'libentry.so': { default: native },
      'entry/ProductInputProfile': { ProductInputProfile: { freeze: () => record('product-freeze'),
        current: () => ({ productKind: 0, runtimeApi: 26, supportsCursorLock: true }), selection: () => ({ desktopWindow: isolated }) } },
      'entry/ProductGameWindowCoordinator': { ProductGameWindowCoordinator: Window },
      // 只替换Native发回token/释放回执的边缘，Client journal和原lease准入使用完整生产类；不声称consumer Ready。
      '../components/EntrySourceControlClient': { createEntrySourceControlClient: () => {
        const { SourceControlClient } = env.load('gamecontrol/src/main/ets/SourceControlClient.ets');
        let nextToken = 1;
        return new SourceControlClient(2, {
          acquire: (source, device, control, codes) => { record('control-acquire', source, device, control, [...codes]); return String(nextToken++); },
          // 只控制Native单次回执，不在夹具里复制持有/退休FSM；false由真实Client保原墓碑。
          release: token => { record('control-release', token); return state.rejectControlRelease !== true; },
        }, deviceConnections.reader);
      } },
      '../components/EntryInputSessionCoordinator': { reconcileEntryInputSession: () => record('reset-reconcile') },
      './EntryTextInputRuntime': { EntryTextInputRuntime: TextRuntime },
      '../components/EntryTouchInputMaintenance': {
        startEntryTouchInputMaintenance: () => { record('touch-start'); return {}; },
        reconcileEntryTouchInputMaintenance: () => { record('touch-reconcile'); return true; },
        stopEntryTouchInputMaintenance: () => {
          record('touch-stop');
          // 明确受控边缘返回原stop receipt；生产Host决定Pending/截止，不拿void当完成。
          return {complete:()=>state.touchPending!==true,waiting:()=>state.touchPending===true,
            reconcile:()=>{record('touch-stop-retry');return state.touchPending!==true;}};
        },
        reconcileEntryTouchInputMaintenanceCleanup: () => { record('touch-cleanup-maintain'); return true; },
      },
      ...(touchApi ? { '../components/EntryTouchInputMaintenance': touchApi } : {}),
    } });
  // Monitor只提供受控的实时add/remove发布边缘；连接身份、known0/compat0和sameid退休由真实Registry拥有。
  const { InputDeviceConnectionRegistry } = env.load('gamecontrol/src/main/ets/InputDeviceConnectionLease.ets');
  deviceConnections = new InputDeviceConnectionRegistry();
  const connectionListeners = new Set();
  const publishConnection = event => { for (const listener of [...connectionListeners]) listener(event); return event; };
  deviceMonitor = { hasMouse: () => true, connectionReader: () => deviceConnections.reader,
    addConnectionListener: listener => { connectionListeners.add(listener); record('device-subscribe'); },
    removeConnectionListener: listener => { connectionListeners.delete(listener); record('device-unsubscribe'); },
    add: rawId => publishConnection(deviceConnections.observeAdd(rawId)),
    remove: rawId => publishConnection(deviceConnections.retireCurrent(rawId)) };
  // 前后台用真实来源运行体和注册表组合；只把Native/时钟/配置仓库边缘留在fixture。
  if (realSources) {
    Object.assign(gamecontrol, env.load('gamecontrol/src/main/ets/GameInputRuntime.ets'),
      env.load('gamecontrol/src/main/ets/GamepadManager.ets'), env.load('gamecontrol/src/main/ets/InputSourceRegistry.ets'));
    registry = gamecontrol.getInputSourceRegistry();
  }
  const module = env.load('entry/src/main/ets/runtime/GameSessionHost.ets');
  const host = module.getGameSessionHost();
  assert.equal(module.getGameSessionHost(), host, '同进程只保存一个会话宿主');
  const run = delay => { const items = [...env.timer].filter(([, timer]) => timer.delay === delay);
    for (const [id, timer] of items) { env.timer.delete(id); timer.fn(); } };
  const count = name => calls.filter(call => call[0] === name).length;
  const attach = (activity = 100, frontend = { onState: noop, onMaintenance: noop, onLog: noop }) => host.attach(context, activity, frontend);
  const store = realSources ? { addInputConfigurationListener: callback => callback(env.load('gamecontrol/src/main/ets/ControlLayout.ets').getDefaultLayout(), 1),
    removeInputConfigurationListener: noop, reconcileInputConfiguration: noop } : {};
  const prepare = () => { host.configureProduct(); host.prepare(store); host.bindPlan(wire); };
  return { host, env, calls, state, windows, context, count, run, attach, prepare, module, ends, registry, native, store,
    deviceConnections, deviceMonitor, connectionListeners, publishConnection };
}

// 新连接接口须走真实Manager/Runtime/Client，不允许通过补一个恒true reader使旧夹具“通过”。
// 平台边缘只发布Registry已经产生的原add/remove事件；Native端只记录独立token回执，未承诺ABI消费。
{
  const f = fixture({ realSources: true }); const front = f.attach(); f.prepare(); f.host.markRunning();
  f.state.grab = true; f.host.setFrontendState(front, true, 7); f.state.grabCallback(true);
  const { AXIS_ABS_Y } = f.env.load('gamecontrol/src/main/ets/GamepadManager.ets');
  const original = f.deviceMonitor.add(7).originalConnection;
  assert.ok(original && f.deviceConnections.reader.accepts(original));
  const firstFact = f.host.inputRuntime.captureAxisForConnection(original, axis => axis === AXIS_ABS_Y ? -1 : 0);
  assert.ok(firstFact); f.host.inputRuntime.handleAxisFact(firstFact);
  assert.equal(f.count('control-acquire'), 1, '原连接事实经真实Client取得一个独立Native token');
  assert.equal(f.calls.find(row => row[0] === 'control-acquire')[2], original.rawPlatformId);
  const removed = f.deviceMonitor.remove(7);
  assert.equal(removed.originalConnection, original); assert.equal(f.deviceConnections.reader.accepts(original), false);
  assert.equal(f.count('control-release'), 1, '真实remove listener只退休当时原对象持有');
  const replacement = f.deviceMonitor.add(7).originalConnection;
  assert.notEqual(replacement, original); assert.notEqual(replacement.applicationScope, original.applicationScope);
  assert.equal(f.host.inputRuntime.captureAxisForConnection(original, () => 0), undefined);
  const currentFact = f.host.inputRuntime.captureAxisForConnection(replacement, axis => axis === AXIS_ABS_Y ? -1 : 0);
  assert.ok(currentFact); f.host.inputRuntime.handleAxisFact(currentFact);
  assert.equal(f.count('control-acquire'), 2);
  f.publishConnection(removed);
  assert.equal(f.count('control-release'), 1, '晚到原remove事件不能按raw ID释放新sameid贡献');
  assert.equal(f.host.gamepad.hasConnectionState(replacement), true);
  // 原frontend捕获的fact即使connection仍live，也不能在detach/rebind后借新的active继续输出。
  const oldFrontFact = f.host.inputRuntime.captureAxisForConnection(replacement, axis => axis === AXIS_ABS_Y ? -1 : 0);
  assert.ok(oldFrontFact); f.host.detach(front); const rebound = f.attach(); f.host.setFrontendState(rebound, true, 7);
  const beforeLate = f.count('control-acquire'); f.host.inputRuntime.handleAxisFact(oldFrontFact);
  assert.equal(f.count('control-acquire'), beforeLate, '真实Runtime原activation/fact阻断旧frontend续体');
  // known hardware0保留合法应用身份，但当前Native字段未准入；不能用兼容0或成功token替代。
  const knownZero = f.deviceMonitor.add(0).originalConnection;
  assert.ok(knownZero && f.deviceConnections.reader.accepts(knownZero));
  assert.equal(f.deviceConnections.reader.allowsLegacyDeviceField(knownZero), false);
  assert.equal(f.host.inputRuntime.captureAxisForConnection(knownZero, () => 0), undefined);
  f.host.stop('connection-fixture-stop'); await flush();
  assert.equal(f.connectionListeners.size, 0); assert.equal(f.env.timer.size, 0);
  console.log('PASS actual Host connection chain: original remove/sameid, late original remove, old frontend fact and known0 NativePending');
}

// 停止后的清理事实必须来自真实Manager/Runtime/Client：明确RELEASE拒绝和已调用未知acquire
// 都不能因Native cancel是void、Runtime.stop已停钟、或Manager无已知按下记录而宣称Clean。
for (const failure of ['release-rejected', 'acquire-uncertain']) {
  const f = fixture({ realSources: true }); const front = f.attach(); f.prepare(); f.host.markRunning();
  f.state.grab = true; f.host.setFrontendState(front, true, 7); f.state.grabCallback(true);
  const connection = f.deviceMonitor.add(7).originalConnection;
  if (failure === 'acquire-uncertain') f.state.throwOn.add('control-acquire');
  f.host.gamepad.handleButtonForConnection(connection, 2301, true);
  if (failure === 'release-rejected') f.state.rejectControlRelease = true;
  const steps = f.host.stop(failure); await flush();
  const mapped = steps.find(step => step.name === 'mapped-stop');
  assert.equal(mapped.completed, false, failure + ': original mapped cleanup remains unconfirmed');
  assert.equal(mapped.reason, 'Pending');
  assert.equal(f.host.controls.reconcileRetirements(), false, 'actual Client keeps the original retirement/unknown intent');
  assert.equal(f.host.gamepad.hasConnectionState(connection), failure === 'release-rejected',
    'unknown acquire cannot be inferred clean just because no accepted token is known to Manager');
  assert.equal(f.env.timer.size, 0, 'Pending does not restart stopped maintenance clocks');
  const last = f.calls.filter(row => row[0] === 'log' && row[1].includes('input_session_end')).at(-1)[1];
  assert.ok(last.includes('outcome=Pending'), failure + ': final outcome must preserve the unconfirmed step');
  const beforeRepeat = f.count('control-release');
  f.host.stop('repeat-stop'); assert.equal(f.count('control-release'), beforeRepeat, 'repeated stop cannot loop old side effects');
  console.log('PASS actual Host stopped cleanup Pending for ' + failure + '; no void-reset inference or background retry');
}

{
  const f = fixture({ realSources: true }); const front = f.attach(); f.prepare(); f.host.markRunning();
  f.state.grab = true; f.host.setFrontendState(front, true, 7); f.state.grabCallback(true);
  const connection = f.deviceMonitor.add(7).originalConnection;
  f.host.gamepad.handleButtonForConnection(connection, 2301, true);
  const steps = f.host.stop('confirmed-release'); await flush();
  assert.equal(steps.find(step => step.name === 'mapped-stop').completed, true);
  assert.equal(f.host.controls.reconcileRetirements(), true);assert.equal(f.host.gamepad.hasConnectionState(connection), false);
  const last = f.calls.filter(row => row[0] === 'log' && row[1].includes('input_session_end')).at(-1)[1];
  assert.ok(last.includes('outcome=Clean'));assert.equal(f.env.timer.size, 0);
  console.log('PASS actual Host confirmed mapped cleanup preserves normal Clean outcome');
}

{
  const f = fixture(); let starts = 0;
  const first = f.attach(); f.prepare();
  f.host.scheduleStart(first, async () => { starts++; });
  const late = [...f.env.timer.values()].find(timer => timer.delay === 500).fn;
  f.host.detach(first); const second = f.attach();
  late(); f.run(500); await flush();
  assert.equal(starts, 0, '已经进入投递队列的旧启动闭包也必须核原租约');
  assert.equal(f.host.accepts(first), false); assert.equal(f.host.accepts(second), true);
  f.host.scheduleStart(second, async () => { starts++; }); f.run(500); await flush(); assert.equal(starts, 1);
  f.host.stop('test-stop'); await flush(); assert.equal(f.env.timer.size, 0);
  assert.throws(() => f.attach(), /retired/, '停止墓碑不得被UI重建解除');
  assert.throws(() => f.host.bindPlan(wire), /retired/);
  console.log('PASS host frontend: stable owner, attach/detach/rebind, queued old startup, stop tombstone');
}

{
  const f = fixture(); const first = f.attach(); f.prepare();
  const original = deferred(); f.state.deferredEnter = original;
  const entering = f.host.enterWindow(first, f.context);
  const firstCoordinator = f.windows.at(-1);
  const rejected = assert.rejects(entering, /retired/);
  f.host.detach(first); const second = f.attach();
  const rebound = f.host.enterWindow(second, f.context);
  original.resolve(firstCoordinator.snapshot()); await rejected;
  const snapshot = await rebound;
  assert.notEqual(snapshot.windowId, firstCoordinator.id);
  assert.equal(f.calls.filter(call => call[0] === 'window-restore' && call[1] === firstCoordinator.id).length, 1);
  assert.equal(f.host.accepts(second), true);
  assert.equal(f.host.retireWindow(first, snapshot.windowId), false, '迟到旧页不能解锁当前窗口');
  f.host.stop('test-stop'); await flush();
  console.log('PASS host window: late old enter restored, rebind serialized, old lease cannot retire new window');
}

{
  const f = fixture(); const lease = f.attach(); f.prepare();
  const pending = deferred(); f.state.deferredEnter = pending;
  const entering = f.host.enterWindow(lease, f.context); const coordinator = f.windows.at(-1);
  const rejected = assert.rejects(entering, /retired/);
  f.host.stop('during-enter'); pending.resolve(coordinator.snapshot()); await rejected; await flush();
  assert.equal(f.host.isEnded(), true); assert.equal(f.env.timer.size, 0);
  assert.equal(f.host.accepts(lease), false);
  assert.ok(f.calls.some(call => call[0] === 'window-restore' && call[1] === coordinator.id));
  console.log('PASS host stop: pending window enter cannot reopen ended session');
}

{
  const f = fixture({ isolated: true }); let observed = 0;
  const first = f.attach(100, { onState: () => observed++, onMaintenance: () => observed++, onLog: () => observed++ });
  f.prepare(); f.host.markRunning(); f.host.setFrontendState(first, true, 9); f.host.detach(first);
  const before = observed; f.state.grab = true; f.run(250); await flush();
  assert.equal(observed, before); assert.ok(f.count('configuration-reconcile') && f.count('text-reconcile') && f.count('reset-reconcile'));
  const reads = f.count('grab-read'); f.run(250); assert.equal(f.count('grab-read'), reads + 1, '无前端维护必须继续续排');
  f.state.running = false; f.run(1000); await flush();
  assert.equal(f.count('return-ability'), 1); assert.equal(f.count('force-exit'), 1); assert.equal(f.env.timer.size, 0);
  assert.ok(f.calls.findIndex(call => call[0] === 'return-ability') < f.calls.findIndex(call => call[0] === 'force-exit'));
  await f.host.requestExit(); assert.equal(f.count('force-exit'), 1, '重复退出只确认原事务');
  console.log('PASS host independence: detached frontend leaves maintenance/exit alive, original activity returned before native ACK');
}

{
  const f = fixture(); const lease = f.attach(100, { onState: noop, onMaintenance: () => { throw new Error('observer fault'); }, onLog: noop });
  f.prepare(); f.host.markRunning(); f.host.setFrontendState(lease, true, 7);
  f.run(250); assert.ok([...f.env.timer.values()].some(timer => timer.delay === 250));
  const lateGrab = f.state.grabCallback;
  f.state.throwOn.add('source-release'); f.state.throwOn.add('native-cancel'); f.state.throwOn.add('runtime-stop');
  const result = f.host.stop('injected-stop'); await flush();
  assert.ok(result.some(step => step.name === 'native-cancel' && !step.completed));
  assert.ok(f.count('configuration-stop') && f.count('source-unregister') && f.count('pointer-restore') && f.count('grab-unsubscribe'));
  assert.equal(f.env.timer.size, 0); assert.equal(f.ends.size, 0);
  const before = f.calls.length; f.host.stop('repeat-stop'); lateGrab(true);
  assert.equal(f.calls.length, before, '重复停止/迟到Native回调不得再产生副作用');
  console.log('PASS host fault isolation: observer/cleanup failures retain later domains and stop clocks, repeated stop is idempotent');
}

{
  const f = fixture({ isolated: true }); f.attach(); f.prepare(); f.host.markRunning();
  f.state.throwOn.add('log');
  await f.host.requestExit(); await flush();
  assert.equal(f.count('force-exit'), 1, '终态日志失败不能跳过Native退出握手');
  console.log('PASS host shutdown: terminal log failure cannot block process exit handshake');
}

/**
 * 只抽出实际Ability的前后台方法原文执行，绑定真实注册表及实际Host/来源组合。
 * 这样不启动UIAbility实例、窗口或Preferences，也不在测试里重写生命周期转发逻辑。
 */
function abilityLifecycle(relative, f) {
  const source = fs.readFileSync(new URL('../' + relative, import.meta.url), 'utf8');
  const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'onForeground'));
  assert.ok(owner, relative);
  const members = ['onBackground', 'onForeground'].map(name => owner.members.find(member => member.name?.getText(ast) === name).getText(ast));
  const code = compiler.transpileModule('class Ability {\n' + members.join('\n') + '\n}\nreturn Ability;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  const bindings = { getInputSourceRegistry: () => f.registry, testNapi: f.native,
    ProductInputProfile: { selection: () => ({ isolatedGameProcess: false }) }, ProductBuildProfile: { storeChannel: true },
    AppLogger: { info: noop, warn: noop }, AppStorage: { setOrCreate: noop }, LOG_DOMAIN_LAUNCH: 1, TAG: 'ability-test',
    FRAME_RATE_FOREGROUND_SOURCE_ENTRY: 1, FRAME_RATE_FOREGROUND_SOURCE_GAME: 2 };
  const Ability = new Function(...Object.keys(bindings), code)(...Object.values(bindings));
  const ability = new Ability(); ability.isolated = true; return ability;
}

for (const relative of ['entry/src/main/ets/entryability/EntryAbility.ets', 'entry/src/main/ets/gameability/GameAbility.ets']) {
  for (const lateRegistration of [false, true]) {
    const f = fixture({ realSources: true }); const lease = f.attach();
    const ability = abilityLifecycle(relative, f);
    if (lateRegistration) ability.onBackground();
    f.prepare(); f.host.markRunning(); f.host.setFrontendState(lease, true, 7);
    if (!lateRegistration) ability.onBackground();
    f.host.setFrontendState(lease, true, 7); f.state.grab = true; f.run(250);
    assert.equal(f.host.inputRuntime.isLifecycleActive(), false, '后台或晚注册的真实来源保留Ability墓碑');
    assert.equal(f.host.inputRuntime.active, false, '旧页面/心跳不能伪造Ability前台');
    f.host.inputRuntime.resumeAfterLifecycle(); f.host.setFrontendState(lease, true, 7);
    assert.equal(f.host.inputRuntime.active, false, '组件焦点只恢复自身边界，不能改写Ability事实');
    ability.onForeground();
    assert.equal(f.host.inputRuntime.isLifecycleActive(), true);
    assert.equal(f.host.inputRuntime.active, true, '真实Ability前台恢复通过宿主合取原前端资格');
    f.host.setFrontendState(lease, false, 7); ability.onBackground(); ability.onForeground();
    assert.equal(f.host.inputRuntime.active, false, 'Ability前台不能越过当前前端焦点/可见性失效');
    f.host.stop('test-stop'); await flush(); assert.equal(f.env.timer.size, 0);
  }
}
console.log('PASS real Ability/Host/Runtime/Registry: both process routes, background-first registration, stale UI/focus, explicit foreground eligibility');

for (const mode of ['deferred-success', 'deferred-reject', 'synchronous-reject', 'force-error']) {
  const f = fixture({ isolated: true }); f.attach(); f.prepare(); f.host.markRunning();
  if (mode.startsWith('deferred')) f.state.handoff = deferred();
  if (mode === 'synchronous-reject') f.state.throwOn.add('return-ability');
  if (mode === 'force-error') f.state.throwOn.add('force-exit');
  const exiting = f.host.requestExit();
  assert.equal(f.count('return-ability'), 1);
  await f.host.requestExit();
  assert.equal(f.count('return-ability'), 1, '重复请求不能生成第二个前台交接');
  if (mode.startsWith('deferred')) {
    assert.equal(f.count('force-exit'), 0, '期限内退出ACK等待原前台请求完成或失败');
    assert.equal(f.env.timer.size, 1, '仅保本次交接截止timer，输入维护已停止');
    assert.equal([...f.env.timer.values()][0].delay,3000);
    if (mode === 'deferred-success') f.state.handoff.resolve(); else f.state.handoff.reject(new Error('platform denied'));
  }
  await exiting; await flush();
  assert.equal(f.count('force-exit'), 1, '失败/拒绝同样必须尝试ACK');
  await f.host.requestExit(); assert.equal(f.count('force-exit'), 1, '失败ACK也不能重复退出产生新副作用');
  assert.equal(f.env.timer.size, 0);
}
{
  const f = fixture(); f.attach(); f.prepare(); f.host.markRunning(); f.state.throwOn.add('force-exit');
  await f.host.requestExit(); assert.equal(f.count('force-exit'), 1); assert.equal(f.count('restart-app'), 1);
}
console.log('PASS real host exit matrix: deferred success/reject, synchronous failure, native ACK failure, duplicates and shared-process restart');

// 主动退出尚无Native退出hook时也必须在本地等待期限后尝试ACK。平台请求永不settle、
// 超时后才成功/拒绝、timer建立/撤销失败分别验证；所有迟到闭包不能重复退出或重开输入。
for(const mode of ['never-settles','late-success','late-reject','timer-schedule-fails','timer-clear-fails']) {
  const f=fixture({isolated:true,timerFaults:true});f.attach();f.prepare();f.host.markRunning();
  f.state.handoff=deferred();
  if(mode==='timer-schedule-fails')f.state.failTimerSchedule=true;
  const exiting=f.host.requestExit();
  assert.equal(f.count('return-ability'),1);assert.equal(f.host.isEnded(),true);
  if(mode!=='timer-schedule-fails'){
    assert.equal(f.count('force-exit'),0);
    if(mode==='timer-clear-fails'){
      f.state.failTimerClear=true;f.state.handoff.resolve();await flush();
    }else f.run(3000);
  }
  await exiting;await flush();
  assert.equal(f.count('force-exit'),1,'有限等待后恰一次Native ACK: '+mode);
  if(mode==='late-success')f.state.handoff.resolve();
  if(mode==='late-reject'||mode==='timer-schedule-fails')f.state.handoff.reject(Error('late OS rejection'));
  f.run(3000);await flush();await f.host.requestExit();
  assert.equal(f.count('return-ability'),1);assert.equal(f.count('force-exit'),1);
  assert.equal(f.env.timer.size,0);assert.equal(f.host.isEnded(),true);
  if(mode==='never-settles'||mode.startsWith('late-'))
    assert.ok(f.calls.some(row=>row[0]==='fault'&&row[2]==='ReturnToLauncherDeadlineExceeded'));
}
console.log('PASS real Host bounded handoff: never-settling/late OS Promise, timer faults, one ACK and no input revival');

{
  const f = fixture(); const first = f.attach(); f.prepare(); const pending = deferred();
  let preparing = 0, completed = 0, nativeCalls = 0;
  const old = f.host.runLaunch(first, async () => { preparing++; try { await pending.promise; } finally { completed++; preparing--; } });
  await flush(); assert.equal(preparing, 1);
  f.host.detach(first); const second = f.attach();
  const resumed = f.host.runLaunch(second, async () => { assert.equal(preparing, 0); assert.equal(completed, 1);
    f.host.markNativeAttempted(second); nativeCalls++; });
  await flush(); assert.equal(nativeCalls, 0, '原准备finally未收口之前不能并行接续');
  pending.resolve(); await old; await resumed;
  assert.equal(nativeCalls, 1); f.host.detach(second); const third = f.attach();
  await f.host.runLaunch(third, async () => { f.host.markNativeAttempted(third); nativeCalls++; });
  assert.equal(nativeCalls, 1, 'Native边界墓碑不能被前端退休解除');
  f.host.stop('test-stop'); await flush();
}
for (const rejected of [false, true]) {
  const f = fixture(); const first = f.attach(); f.prepare(); let nativeCalls = 0;
  const initial = f.host.runLaunch(first, async () => { f.host.markNativeAttempted(first); nativeCalls++;
    if (rejected) throw new Error('Native call threw'); });
  if (rejected) await assert.rejects(initial, /Native call threw/); else await initial;
  f.host.detach(first); const second = f.attach();
  const next = f.host.runLaunch(second, async () => { f.host.markNativeAttempted(second); nativeCalls++; });
  if (rejected) await assert.rejects(next, /Native call threw/); else await next;
  assert.equal(nativeCalls, 1, 'Native rc失败或异常不得允许第二次调用');
  f.host.stop('test-stop'); await flush();
}
console.log('PASS host launch gate: retired preparation waits original finally, Native success/failure/exception stays frozen');

{
  const f = fixture(); const first = f.attach(); f.prepare(); const pending = deferred(); let nativeCalls = 0;
  const old = f.host.runLaunch(first, async () => { await pending.promise; }); await flush();
  f.host.detach(first); const second = f.attach();
  const middle = f.host.runLaunch(second, async () => {
    f.host.markNativeAttempted(second); nativeCalls++; });
  f.host.detach(second); const third = f.attach();
  const latest = f.host.runLaunch(third, async () => {
    f.host.markNativeAttempted(third); nativeCalls++; });
  await flush(); assert.equal(nativeCalls, 0); pending.resolve(); await Promise.all([old, middle, latest]);
  assert.equal(nativeCalls, 1, '连续前端重建只让最新合法租约接续，不能粘住中间已退前端');
  f.host.stop('test-stop'); await flush();
}
console.log('PASS host repeated frontend rebuild: latest lease resumes one Native launch after original preparation');

for (const failure of ['product-freeze', 'product-configure', 'source-register', 'touch-start',
  'configuration-start', 'runtime-start', 'mapped-choice']) {
  const f = fixture(); const lease = f.attach(); f.state.throwOn.add(failure);
  assert.throws(() => f.prepare(), new RegExp('fault:' + failure));
  await flush();
  assert.equal(f.host.isEnded(), true, failure + ':准备失败必须进入结束墓碑');
  assert.equal(f.host.accepts(lease), false); assert.equal(f.env.timer.size, 0); assert.equal(f.ends.size, 0);
  assert.ok(f.count('native-cancel') && f.count('configuration-stop') && f.count('runtime-stop'),
    failure + ':收口取得或部分取得的资源，单域失败不能漏掉其它清理');
}
console.log('PASS host preparation rollback: seven product/source/configuration/mapped failures retire leases, clocks and partial registrations');

{
  const oldFlag = process.argv.find(argument => argument.startsWith('--prepared-before-source='));
  const oldSource = oldFlag === undefined ? undefined : fs.readFileSync(oldFlag.substring('--prepared-before-source='.length), 'utf8');
  const f = fixture({ hostSource: oldSource }); f.attach(); f.host.configureProduct(); f.host.bindPlan(wire);
  assert.throws(() => f.host.markRunning(), /prepared|prepare/i,
    'Surface启动请求早于异步LayoutStore准备时，不能仅凭产品和ABI计划声明输入已运行');
  f.host.stop('test-stop'); await flush();
}
console.log('PASS host preparation barrier: product/plan alone cannot mark running before source/configuration assembly');

{
  const f = fixture(); const lease = f.attach(); let outcome = 'Pending';
  const waiting = f.host.waitPrepared(lease).then(value => { outcome = value; return value; });
  await flush(); assert.equal(outcome, 'Pending'); assert.equal(f.count('window-enter'), 0);
  f.prepare(); assert.equal(await waiting, true);
  assert.equal(await f.host.waitPrepared(lease), true, '已经完成装配的当前前端不再等待');
  f.host.markRunning(); assert.equal(f.host.isRunning(), true);
  f.host.stop('test-stop'); await flush();
}
for (const retirement of ['detach', 'replace', 'stop', 'prepare-failure']) {
  const f = fixture(); const lease = f.attach(); let outcome = 'Pending';
  f.host.waitPrepared(lease).then(value => { outcome = value; }); await flush();
  if (retirement === 'detach') f.host.detach(lease);
  else if (retirement === 'replace') f.attach();
  else if (retirement === 'stop') f.host.stop('before-prepared');
  else { f.state.throwOn.add('configuration-start'); assert.throws(() => f.prepare(), /configuration-start/); }
  await flush(); assert.equal(outcome, false, retirement + ':旧等待者必须完成false，不能永久挂起');
  assert.equal(await f.host.waitPrepared(lease), false, retirement + ':旧租约不能等待或认领后续装配');
  if (!f.host.isEnded()) f.host.stop('test-stop'); await flush();
}
console.log('PASS preparation waiters: original lease succeeds after prepare, detach/rebind/stop/failure finish false without orphan waits');

/** 执行真实Page启动入口；完整Runtime/JVM准备由边界替身记录，测试不复制其等待或身份判断。 */
function pageStart(f, lease) {
  const relative = 'entry/src/main/ets/pages/McGamePage.ets';
  const source = fs.readFileSync(new URL('../' + relative, import.meta.url), 'utf8');
  const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'startMCOnce'));
  assert.ok(owner); const method = owner.members.find(member => member.name?.getText(ast) === 'startMCOnce').getText(ast);
  const code = compiler.transpileModule('class Page {\n' + method + '\n}\nreturn Page;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  // 本组为default启动：真实准入类在非store返回空票据，不改变原输入准备/窗口/JVM边界顺序。
  const Page = new Function('AppStorage', 'ProductInputProfile', 'LOG_DOMAIN_LAUNCH', 'TAG', 'GameRunAdmission', code)(
    { get: key => key === 'mcLaunchActivityId' ? 100 : undefined }, { selection: () => ({ desktopWindow: true }) }, 1, 'page-start-test',
    { captureDispatch: () => '', reserveProcessLaunch: () => undefined });
  const page = new Page(); const actions = [];
  Object.assign(page, { sessionHost: f.host, frontendLease: lease, context: f.context, inputLifecycleEpoch: 1,
    navigatedAway: false, mcStarted: false, inputProductFailure_: '', gameWindowCoordinator: f.host.windowCoordinator,
    getUIContext: () => ({ getRouter: () => ({ getParams: () => ({ activityId: 100 }) }) }),
    beginLaunchLedgerEarly_: () => actions.push('ledger'), launchLogger_: () => ({ error: noop }),
    recordLaunchFailure_: () => actions.push('launch-failed'), restoreGameWindow: async () => actions.push('window-restore'),
    startMCInternal: async () => { actions.push('jvm-boundary'); f.host.markRunning(); page.mcStarted = true; } });
  return { page, actions };
}
for (const retire of [false, true]) {
  const f = fixture(); const lease = f.attach(); const { page, actions } = pageStart(f, lease);
  const starting = page.startMCOnce(); await flush();
  assert.deepEqual(actions, [], '等待真实输入装配前不能提前固定活动/触碰启动边界');
  assert.equal(f.count('window-enter'), 0, 'Surface启动定时器不能抢在LayoutStore.init完成前取得启动Window');
  if (retire) f.host.detach(lease); else f.prepare();
  await starting;
  if (retire) { assert.deepEqual(actions, []); assert.equal(f.count('window-enter'), 0); }
  else { assert.deepEqual(actions, ['ledger', 'jvm-boundary']); assert.equal(f.count('window-enter'), 1); }
  f.host.stop('test-stop'); await flush();
}
console.log('PASS real Page.startMCOnce: waits host assembly before Window/JVM, retired preparation cannot start through old Surface request');

{
  const f = fixture(); const lease = f.attach(); const { page, actions } = pageStart(f, lease);
  const starting = page.startMCOnce(); await flush();
  // resolve(true)与Promise续体执行之间仍可能到达detach；消费返回值时必须再核原租约。
  f.prepare(); f.host.detach(lease); await starting;
  assert.deepEqual(actions, [], 'prepare刚resolve但原前端已退，不得用冻结true开始旧活动/资源准备');
  assert.equal(f.count('window-enter'), 0); f.host.stop('test-stop'); await flush();
}
{
  const f = fixture(); const lease = f.attach(); const outcomes = [];
  for (let index = 0; index < 16; index++) f.host.waitPrepared(lease).then(value => outcomes.push(value));
  assert.equal(await f.host.waitPrepared(lease), false, '等待者达到预算必须明确拒绝，不能继续累积');
  f.run(120000); await flush();
  assert.equal(outcomes.length, 16); assert.ok(outcomes.every(value => value === false));
  assert.equal(f.host.isEnded(), true); assert.equal(f.env.timer.size, 0);
  assert.throws(() => f.prepare(), /retired|ended|not configured/i, '超时后迟到准备不能重新开启本局');
}
console.log('PASS preparation race/budget: resolved old lease rechecked, sixteen bounded waiters finish on timeout, late assembly stays retired');

// 实际Host必须在bindPlan后才升级原生资格，且focus跟随真正的来源开关，而不是target。
// 来源本身的拒绝/释放行为由真实Manager组合测试另证；此处控制该边缘以核宿主接线。
for (const [actualWire, expectedRoute] of [[wire, 'mapped'],
  ['v=v1;abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2', 'native'],
  ['v=v1;abi=SDL3;slot=LWJGL3;window=SDL3;binding=libSDL3.so;policy=sdl-present-1', 'native']]) {
  const f = fixture({isolated:true}); f.state.nativeGamepadRequested=true; f.state.nativeGamepadCaptureReady=true;
  const lease=f.attach(); f.host.configureProduct(); f.host.prepare(f.store);
  assert.equal(f.host.nativeGamepadRoute().reason, 'input-plan-unbound');
  assert.equal(f.host.nativeGamepadRoute().applied, 'mapped');
  f.host.bindPlan(actualWire); f.host.setFrontendState(lease,true,1);
  assert.equal(f.host.nativeGamepadRoute().applied, expectedRoute);
  assert.equal(f.calls.filter(call=>call[0]==='pad-focus').at(-1)[1], expectedRoute==='native');
  f.state.nativeGamepadRequested=false; f.state.nativeGamepadCaptureReady=false;
  f.run(250);
  assert.equal(f.host.nativeGamepadRoute().requestedNative,true,'本局不能采用新设置替代冻结请求');
  assert.equal(f.host.nativeGamepadRoute().platformCaptureReady,true,'本局不能从后来平台字段热借另一capture事实');
  if(expectedRoute==='native'){
    // Native之后的正式Host没有另一个合法计划/请求写点；不是把任意可造DTO
    // 当成该产品正在发生的回切。真正的resolver contract组合在独立政策测试执行。
    assert.throws(()=>f.host.bindPlan(wire),/Input plan already frozen/);
    assert.throws(()=>f.host.bindPlan('bad-plan'),/Invalid or retired input plan/);
    assert.equal(f.host.nativeGamepadRoute().status,'applied');
    assert.equal(f.host.nativeGamepadRoute().applied,'native');
  }
  f.host.stop('route-test'); await flush();
}
{
  const f=fixture({isolated:true}); f.state.nativeGamepadRequested=true; f.state.nativeGamepadCaptureReady=true;
  f.state.rejectMappedRetirement=true; const lease=f.attach(); f.host.configureProduct(); f.host.prepare(f.store);
  f.host.bindPlan('v=v1;abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2');
  f.host.setFrontendState(lease,true,1);
  assert.equal(f.host.nativeGamepadRoute().status,'pending');
  assert.equal(f.calls.filter(call=>call[0]==='pad-focus').at(-1)[1],false,'映射旧持有未结束不能同时开native焦点');
  f.state.rejectMappedRetirement=false; f.run(250);
  assert.equal(f.host.nativeGamepadRoute().applied,'native');
  assert.equal(f.calls.filter(call=>call[0]==='pad-focus').at(-1)[1],true);
  f.host.stop('route-test'); await flush();
}
console.log('PASS real Host native route: ABI qualification, frozen preference, actual apply and focus exclusivity');

/** 真正Host的只读前端入口：原对象身份、同局重挂接与跨局不能借相同编号。 */
function frontendRouteScope(hostSource = undefined, retireDuringRead = false) {
  const f=fixture({isolated:true,hostSource});
  f.state.nativeGamepadRequested=true; f.state.nativeGamepadCaptureReady=true;
  const first=f.attach(), reads=[];
  f.host.configureProduct(); f.host.prepare(f.store);
  f.host.bindPlan('v=v1;abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2');
  const effects=f.calls.length;
  const snapshot=f.host.nativeGamepadRouteForFrontend(first);
  assert.equal(snapshot.applied,'native');snapshot.status='corrupted';
  assert.equal(f.host.nativeGamepadRouteForFrontend(first).status,'applied','值副本不能写回运行权威');
  assert.equal(f.calls.length,effects,'观察不重试来源、焦点或采集');
  assert.equal(f.host.nativeGamepadRouteForFrontend({id:first.id,retired:false}),undefined,'复制编号不是原lease');
  if(retireDuringRead){
    const read=f.host.gamepad.isMappedOutputEnabled.bind(f.host.gamepad);
    f.host.gamepad.isMappedOutputEnabled=()=>{const value=read();f.host.detach(first);return value;};
    assert.equal(f.host.nativeGamepadRouteForFrontend(first),undefined,'ROUTE_READ_REENTRY 原lease读回前已失权');
  }else{
    f.host.detach(first);
    const second=f.attach(100,{onState:noop,onMaintenance:()=>reads.push(f.host.nativeGamepadRouteForFrontend(second)),onLog:noop});
    assert.equal(f.host.nativeGamepadRouteForFrontend(first),undefined,'旧页不能借同局后来frontend');
    assert.equal(f.host.nativeGamepadRouteForFrontend(second).requestedNative,true);
    f.state.nativeGamepadRequested=false;f.run(250);
    assert.equal(reads.at(-1).requestedNative,true,'保存新设置不授本局路线变化');
    const other=fixture({isolated:true});const otherLease=other.attach(200);
    other.state.nativeGamepadRequested=true;other.state.nativeGamepadCaptureReady=true;
    other.prepare();
    assert.equal(otherLease.id,first.id);
    assert.equal(other.host.nativeGamepadRouteForFrontend(first),undefined,'另一会话相同编号不可借');
    const maintained=f.count('mapped-choice');f.host.detach(second);f.run(250);
    assert.ok(f.count('mapped-choice')>maintained,'关闭UI观察后必要route维护继续');
    other.host.stop('route-read-test');
  }
  f.host.stop('route-read-test');
  assert.equal(f.host.nativeGamepadRouteForFrontend(first),undefined,'已结束会话不显示旧Applied');
}
frontendRouteScope();frontendRouteScope(undefined,true);
{
  const original=fs.readFileSync(new URL('../entry/src/main/ets/runtime/GameSessionHost.ets',import.meta.url),'utf8');
  const anchor='return this.accepts(lease) ? decision : undefined';
  assert.equal(original.split(anchor).length,2);
  assert.throws(()=>frontendRouteScope(original.replace(anchor,'return decision'),true),
    error=>error instanceof assert.AssertionError&&error.message.includes('ROUTE_READ_REENTRY'));
}
console.log('PASS real Host route reader: original lease/session, inert copies, setting isolation, closed observer and compiled reentry withdrawal');

// 只有当前私有契约声明存在时选择新执行模型；校准失败必须收口准备，不偷偷旧积分。
{
  const f=fixture({sharedLook:true});f.attach();f.host.configureProduct(f.store);
  const product=f.calls.findIndex(row=>row[0]==='product-configure');
  const report=f.calls.findIndex(row=>row[0]==='configuration-report-prepare');
  assert.ok(product>=0&&report>product,'产品事实先于纯报告准备');
  assert.equal(f.host.gamepad.emitter.lookExecutionMode,'neutral-rate-v1');
  f.host.prepare(f.store);assert.equal(f.count('look-cold-contract'),1);f.host.stop('test');
}
{
  const f=fixture({sharedLook:false});f.attach();f.host.configureProduct(f.store);
  assert.equal(f.host.gamepad.emitter.lookExecutionMode,'neutral-rate-v1');
  assert.throws(()=>f.host.prepare(f.store),/Shared look execution owner/);
  assert.equal(f.host.isEnded(),true);assert.equal(f.env.timer.size,0);
}
console.log('PASS real Host shared look cold owner qualification, prepared report ordering and no fallback on bad owner');

{
  const f=fixture();f.attach();f.host.configureProduct();f.host.prepare(f.store);
  assert.equal(f.count('text-start'),1);f.state.textStopOutcome='Pending';
  const steps=f.host.stop('text-pending'),original=steps.find(step=>step.name==='text-input-stop');
  assert.equal(original.completed,false);assert.equal(original.reason,'Pending');
  assert.equal(f.host.isEnded(),true,'真实OS Promise不能阻塞同步会话结束围栏');
  assert.ok(f.calls.filter(row=>row[0]==='log'&&row[1].includes('InputSession stop')).every(row=>row[1].includes('text-input-stop')),
    '不能在所有清理域登记前记录临时Clean');
  f.host.textInputRuntime.emitOutcome({stopOutcome:'Completed',failure:'',platformDetachResolved:true,localLeaseClosed:true});
  assert.equal(original.completed,false);assert.equal(original.reason,'Pending','旧文本快照不随异步结果变化');
  const latest=f.host.cleanupSnapshot().find(step=>step.name==='text-input-stop');
  assert.equal(latest.completed,true);assert.equal(latest.reason,'');
  assert.equal(f.host.textInputRuntime.listeners.size,0);assert.equal(f.count('text-stop'),1);
  f.host.stop('duplicate');assert.equal(f.count('text-stop'),1);
}
{
  const f=fixture();f.attach();f.host.configureProduct();f.host.prepare(f.store);f.state.textStopOutcome='Pending';
  const original=f.host.stop('timeout').find(step=>step.name==='text-input-stop');
  f.host.textInputRuntime.emitOutcome({stopOutcome:'TimedOut',failure:'stop deadline exceeded',platformDetachResolved:false,localLeaseClosed:true});
  assert.equal(original.completed,false);assert.equal(original.reason,'Pending');
  const timedOut=f.host.cleanupSnapshot().find(step=>step.name==='text-input-stop');
  assert.equal(timedOut.completed,false);assert.match(timedOut.reason,/deadline/);
  f.host.textInputRuntime.emitOutcome({stopOutcome:'TimedOut',failure:'stop deadline exceeded',platformDetachResolved:true,localLeaseClosed:true});
  assert.deepEqual(f.host.cleanupSnapshot().find(step=>step.name==='text-input-stop'),timedOut,
    '迟到detach不能回写本次超时为Clean');assert.equal(f.host.textInputRuntime.listeners.size,0);
}
console.log('PASS actual Host text prepare/stop original async step, terminal completion and irreversible deadline result');

{
  const f=fixture();f.attach();f.state.sourceOwnerUnavailable=true;
  assert.throws(()=>f.host.configureProduct(f.store),/source owner contract unavailable/);
  assert.equal(f.host.isEnded(),true);assert.equal(f.host.productConfigured,false);
  assert.equal(f.count('text-start'),0);assert.equal(f.count('runtime-start'),0);
  assert.equal(f.count('source-register'),0);assert.equal(f.env.timer.size,0);
  assert.equal(f.host.launchGate.nativeAttempted,false,'冷源合同失败不能升级JVM占用事实');
}
console.log('PASS actual Host source owner cold rejection before source/controller/JVM assembly; no implicit fallback');
// 时钟未知不能阻止原停源；已同步确认仍可Completed，pending只保原墓碑/具名失败。
for(const pending of [false,true]){
 const f=fixture();f.attach();f.prepare();f.state.touchPending=pending;f.state.clockThrows=true;
 const steps=f.host.stop('clock-stop');const touch=steps.find(s=>s.name==='touch-maintenance-stop');
 assert.equal(f.count('touch-stop'),1,'clock throw still invokes original source stop exactly once');
 assert.equal(touch.completed,!pending);
 assert.equal(touch.reason,pending?'TouchSourceCleanupClockUnavailable':'');
 assert.equal(f.count('native-cancel'),1,'clock failure does not skip sibling native cancellation');
 assert.equal(f.env.timer.size,0,'unknown clock never starts cleanup retry');
 f.host.stop('repeat');assert.equal(f.count('touch-stop'),1);
}
{
 const f=fixture();f.attach();f.prepare();f.state.touchPending=true;
 const steps=f.host.stop('touch-pending');const touch=steps.find(s=>s.name==='touch-maintenance-stop');
 assert.equal(touch.completed,false);assert.equal(touch.reason,'Pending');
 assert.equal(f.env.timer.size,1,'only original heartbeat slot carries retired-source cleanup');
 const old=f.host.touchStopReceipt;f.state.touchPending=false;f.run(250);
 assert.equal(touch.completed,false);assert.equal(touch.reason,'Pending');
 const latest=f.host.cleanupSnapshot().find(s=>s.name==='touch-maintenance-stop');
 assert.equal(latest.completed,true);assert.equal(latest.reason,'');assert.equal(f.env.timer.size,0);
 assert.equal(f.count('touch-stop'),1,'retry does not ordinary-stop or rebuild source again');
 assert.equal(f.count('touch-stop-retry'),1);
 assert.equal(f.host.touchStopReceipt,undefined);
}
for(const limit of ['attempt','deadline']){
 const f=fixture();f.attach();f.prepare();f.state.touchPending=true;
 const steps=f.host.stop('touch-budget');const touch=steps.find(s=>s.name==='touch-maintenance-stop');
 const original=f.host.touchStopReceipt;
 if(limit==='deadline'){f.state.now=2001;f.run(250);}
 else {for(let i=0;i<4;i++)f.run(250);}
 assert.equal(touch.completed,false);assert.equal(touch.reason,'Pending');
 const latest=f.host.cleanupSnapshot().find(s=>s.name==='touch-maintenance-stop');
 assert.equal(latest.completed,false);assert.equal(latest.reason,limit==='deadline'?'TouchSourceCleanupDeadlineExceeded':'TouchSourceCleanupAttemptBudgetExceeded');
 assert.equal(f.env.timer.size,0,'finite cleanup has no live timer after cutoff');
 assert.equal(f.host.touchStopReceipt,original,'unconfirmed original resource receipt retained');
 assert.equal(f.count('touch-stop'),1);assert.equal(f.count('touch-stop-retry'),limit==='deadline'?0:4);
}
console.log('PASS original Host touch-source pending/clock/confirmation/5-attempt/2s cleanup receipts');

// timer系统边缘失败不能中断首次停源，也不能把未确认receipt写成Completed。
{
 const f=fixture({timerFaults:true});f.attach();f.prepare();f.host.markRunning();
 f.state.touchPending=true;f.state.failTimerSchedule=true;f.state.failTimerClear=true;
 const steps=f.host.stop('timer-failure'),touch=steps.find(step=>step.name==='touch-maintenance-stop');
 assert.equal(f.count('touch-stop'),1);assert.equal(f.count('native-cancel'),1);
 assert.equal(touch.completed,false);assert.equal(touch.reason,'TouchSourceCleanupTimerUnavailable');
 assert.ok(steps.some(step=>step.name==='heartbeat-stop'&&!step.completed));
 const retries=f.count('touch-stop-retry');f.env.runTimers();
 assert.equal(f.count('touch-stop-retry'),retries,'未撤掉的旧生产timer已失权，不能当清理重试');
 assert.equal(f.env.timer.size,0);assert.ok(f.host.touchStopReceipt);
}
// 原生产tick排队后发生stop，晚到tick不得抹掉现在用于清理的heartbeat句柄。
{
 const f=fixture();f.attach();f.prepare();f.host.markRunning();
 const queued=[...f.env.timer.values()].find(timer=>timer.delay===250).fn;
 f.state.touchPending=true;f.host.stop('late-production-tick');
 const cleanupTimer=f.host.heartbeat;queued();
 assert.equal(f.host.heartbeat,cleanupTimer,'旧生产tick不能擦掉清理timer句柄');
 f.state.touchPending=false;f.run(250);assert.equal(f.host.touchStopStep.completed,true);
 assert.equal(f.env.timer.size,0);
}
console.log('PASS original Host timer failures and queued production tick preserve stop receipt and sibling cleanup');

// Host与完整维护模块直接组合；Source仅提供平台清理结果边缘，receipt由生产模块真正生成。
{
 const touchApi=makePureEtsLoader({'libentry.so':{__esModule:true,default:{maintainTouchInput:()=>true}},
  '@kit.PerformanceAnalysisKit':{hilog:{warn(){}}}})('entry/src/main/ets/components/EntryTouchInputMaintenance.ets');
 const f=fixture({touchApi});f.attach();f.prepare();const scope=touchApi.captureEntryTouchInputMaintenanceScope();
 let stopped=0,retried=0,ready=false,laterStopped=0;
 const old={stopSources(){stopped++;return false;},reconcileStoppedSources(){retried++;return ready;}};
 touchApi.registerEntryTouchInputMaintenanceSource(scope,old);
 const step=f.host.stop('real-stop-receipt').find(row=>row.name==='touch-maintenance-stop');
 assert.equal(step.completed,false);assert.equal(step.reason,'Pending');assert.equal(stopped,1);
 const later=touchApi.startEntryTouchInputMaintenance();
 assert.equal(touchApi.registerEntryTouchInputMaintenanceSource(later,old),false);
 touchApi.registerEntryTouchInputMaintenanceSource(later,{stopSources(){laterStopped++;return true;},reconcileStoppedSources(){return true;}});
 f.run(250);assert.equal(step.completed,false);assert.equal(retried,1);ready=true;
 f.run(250);assert.equal(step.completed,false);assert.equal(step.reason,'Pending');
 assert.equal(f.host.cleanupSnapshot().find(row=>row.name==='touch-maintenance-stop').completed,true);
 assert.equal(retried,2);assert.equal(stopped,1);
 assert.equal(laterStopped,0);assert.equal(touchApi.captureEntryTouchInputMaintenanceScope(),later);
 touchApi.stopEntryTouchInputMaintenance(later);assert.equal(laterStopped,1);
 assert.equal(f.env.timer.size,0);
}
console.log('PASS real Host plus real maintenance receipt: original pending resource retries, later scope untouched');

// 五个相互独立的故障轴作32种组合：初停异常、首重试异常、旧timer撤销失败、
// 已排清理tick的时钟失败、清理调度失败。Host与receipt都执行原生产类，夹具只控制
// 系统边缘结果；旧生产闭包/后来scope/兄弟停源同时在场，避免孤立故障都绿而组合漏清理。
for(let mask=0;mask<32;mask++){
 const touchApi=makePureEtsLoader({'libentry.so':{__esModule:true,default:{maintainTouchInput:()=>true}},
  '@kit.PerformanceAnalysisKit':{hilog:{warn(){throw Error('controlled logging failure');}}}})
  ('entry/src/main/ets/components/EntryTouchInputMaintenance.ets');
 const f=fixture({touchApi,timerFaults:true});f.attach();f.prepare();f.host.markRunning();
 const originalScope=touchApi.captureEntryTouchInputMaintenanceScope();
 const queued=[...f.env.timer.values()].find(timer=>timer.delay===250).fn;
 let stops=0,retries=0,siblingStops=0,laterStops=0;
 const old={stopSources(){stops++;if(mask&1)throw Error('controlled first stop failure');return false;},
  reconcileStoppedSources(){retries++;if((mask&2)&&retries===1)throw Error('controlled retry failure');return retries>=2;}};
 assert.equal(touchApi.registerEntryTouchInputMaintenanceSource(originalScope,old),true);
 assert.equal(touchApi.registerEntryTouchInputMaintenanceSource(originalScope,{stopSources(){siblingStops++;return true;},
  reconcileStoppedSources(){throw Error('completed sibling must not retry');}}),true);
 f.state.failTimerClear=!!(mask&4);f.state.failTimerSchedule=!!(mask&16);
 const steps=f.host.stop('combined-fault-'+mask),step=steps.find(row=>row.name==='touch-maintenance-stop');
 assert.equal(stops,1,'mask='+mask);assert.equal(siblingStops,1,'stop/log failure cannot skip sibling, mask='+mask);
 assert.equal(f.count('native-cancel'),1);assert.equal(step.completed,false);
 const receipt=f.host.touchStopReceipt;
 const later=touchApi.startEntryTouchInputMaintenance();
 assert.equal(touchApi.registerEntryTouchInputMaintenanceSource(later,old),false,'old source cannot rebind, mask='+mask);
 assert.equal(touchApi.registerEntryTouchInputMaintenanceSource(later,{stopSources(){laterStops++;return true;},
  reconcileStoppedSources(){return true;}}),true);
 // 已经排队的旧生产tick重复到达也不能清掉现在的清理句柄；真正清理仍只借原receipt。
 const heartbeat=f.host.heartbeat;queued();queued();assert.equal(f.host.heartbeat,heartbeat);
 f.state.clockThrows=!!(mask&8);
 for(let tick=0;tick<8;tick++){
  f.state.now+=250;f.env.runTimers();await flush();
  f.host.stop('duplicate-after-tick');
  assert.equal(stops,1);assert.equal(laterStops,0);assert.ok(retries<=4);
  assert.equal(touchApi.captureEntryTouchInputMaintenanceScope(),later);
 }
 const expectedComplete=(mask&(1|2|8|16))===0;
 assert.equal(step.completed,false,'最初快照保持停止时的结果，mask='+mask);
 const latest=f.host.cleanupSnapshot().find(row=>row.name==='touch-maintenance-stop');
 assert.equal(latest.completed,expectedComplete,'real receipt final outcome, mask='+mask);
 assert.equal(f.env.timer.size,0,'no unbounded residual timer, mask='+mask);
 if(expectedComplete){assert.equal(latest.reason,'');assert.equal(f.host.touchStopReceipt,undefined);assert.equal(retries,2);}
 else{
  assert.notEqual(latest.reason,'Pending','terminal failure must be explicit, mask='+mask);
  assert.equal(f.host.touchStopReceipt,receipt,'original failure receipt retained, mask='+mask);
 }
 touchApi.stopEntryTouchInputMaintenance(later);assert.equal(laterStops,1);
}
console.log('PASS 32 actual Host/maintenance fault combinations: stop/retry/log/timer/clock with stale ticks, bounded receipts and later-scope isolation');

/**
 * 在完整生产Host上篡改对外值，核内部日志与真实清理进展；不能仅比较对象地址。
 * stop首次返回、重复stop和纯读取均覆盖，随后由原资源确认完成，旧值仍保留其时点。
 */
async function verifyCleanupSnapshots(hostSource) {
  const f=fixture({hostSource});f.attach();f.prepare();
  assert.deepEqual(f.host.cleanupSnapshot(),[]);
  f.state.touchPending=true;f.state.textStopOutcome='Pending';
  const first=f.host.stop('snapshot-origin');
  const original=first.map(step=>({...step}));
  for(const read of [()=>first,()=>f.host.stop('repeat-reason'),()=>f.host.cleanupSnapshot()]) {
    const returned=read();
    for(const step of returned){step.completed=true;step.reason='forged';step.name='forged';}
    returned.length=0;
    assert.deepEqual(f.host.cleanupSnapshot(),original,'外部返回值不能改写内部清理权威');
  }
  const pending=f.host.cleanupSnapshot();
  f.run(250);await flush();
  assert.equal(f.count('touch-stop-retry'),1);
  assert.equal(f.env.timer.size,1,'篡改完成位后，原未完成资源仍必须继续清理');
  assert.ok(f.calls.filter(row=>row[0]==='log'&&row[1].includes('input_session_end')).every(row=>
    row[1].includes('reason=snapshot-origin')&&!row[1].includes('forged')));
  f.state.touchPending=false;f.run(250);
  f.host.textInputRuntime.emitOutcome({stopOutcome:'Completed',failure:'',platformDetachResolved:true,localLeaseClosed:true});
  await flush();
  assert.equal(f.host.cleanupSnapshot().every(step=>step.completed),true);
  assert.equal(pending.find(step=>step.name==='touch-maintenance-stop').completed,false);
  assert.equal(pending.find(step=>step.name==='text-input-stop').reason,'Pending');
  assert.equal(f.count('touch-stop'),1);assert.equal(f.count('touch-stop-retry'),2);assert.equal(f.env.timer.size,0);
}
await verifyCleanupSnapshots();
// 撤回逐项复制的内存负控仍运行同一生产类；必须命中语义断言，语法/加载失败不能冒充反控。
const snapshotSource=fs.readFileSync(new URL('../entry/src/main/ets/runtime/GameSessionHost.ets',import.meta.url),'utf8');
const snapshotCopy=/return this\.cleanup\.map\([\s\S]*?\n    \}\)/;
assert.match(snapshotSource,snapshotCopy);
await assert.rejects(()=>verifyCleanupSnapshots(snapshotSource.replace(snapshotCopy,'return this.cleanup.slice()')),
  error=>error.code==='ERR_ASSERTION'&&error.message.includes('外部返回值不能改写内部清理权威'));
console.log('PASS actual Host cleanup snapshots: mutation isolation, asynchronous history, retry progress and compiled shallow-copy negative control');

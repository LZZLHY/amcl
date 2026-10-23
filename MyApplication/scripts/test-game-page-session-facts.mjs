/**
 * 页面事实/宿主投影的真实闭包回归：Host、GameInputRuntime、Registry和两Ability都执行生产代码。
 * Page方法及onState/onFocus从真实源码提取；按真实isInGame的@Watch连接决定是否派发，
 * 不在测试里硬编码已退出的handler。系统/NAPI/Window/配置仓库边缘显式替换。
 * --source-snapshot=<外部旧Page原文> --expect-regression 用于旧源负控，普通CI只测当前源码。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { environment } from './lib/ets-runtime-fixture.mjs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const root = path.resolve(import.meta.dirname, '..');
const snapshotFlag = process.argv.find(argument => argument.startsWith('--source-snapshot='));
const negative = process.argv.includes('--expect-regression');
// 热插拔负控复放真实旧Page；沿用完整资格正例，只有新增兄弟连接断言预期识别旧行为。
const hotplugNegative = process.argv.includes('--expect-hotplug-regression');
if (negative) assert.ok(snapshotFlag, '撤回负控必须提供真实外部旧源码');
if (hotplugNegative) assert.ok(snapshotFlag, '热插拔负控必须提供真实旧页面源码');
const pageRelative = 'entry/src/main/ets/pages/McGamePage.ets';
const pageSource = fs.readFileSync(snapshotFlag ? snapshotFlag.substring('--source-snapshot='.length) : path.join(root, pageRelative), 'utf8');
const pageAst = compiler.createSourceFile(pageRelative, pageSource, compiler.ScriptTarget.Latest, true);
const owner = pageAst.statements.find(node => node.members?.some(member => member.name?.getText(pageAst) === 'syncCursorLock'));
assert.ok(owner, '真实Page实例');
const grabField = owner.members.find(member => member.name?.getText(pageAst) === 'isInGame');
assert.ok(grabField, '真实grab投影字段');
const watch = /@Watch\(\s*['"]([^'"]+)['"]\s*\)/.exec(grabField.getText(pageAst));
const watcher = watch?.[1];
const names = ['syncCursorLock', 'updatePageInputActive', ...(watcher ? [watcher] : [])];
const methods = names.map(name => {
  const method = owner.members.find(member => member.name?.getText(pageAst) === name);
  assert.ok(method, '真实连接的Page方法:' + name); return method.getText(pageAst);
}).join('\n');
let onState, onFocus;
/** 只定位声明与回调，保留生产函数体；注释或测试自写回调不能满足生产连接。 */
function visit(node) {
  if (node.kind === compiler.SyntaxKind.PropertyAssignment && node.name?.getText(pageAst) === 'onState'
    && node.initializer.getText(pageAst).includes('this.isInGame')) onState = node.initializer.getText(pageAst);
  if (node.kind === compiler.SyntaxKind.CallExpression && node.expression?.name?.getText(pageAst) === 'onFocus'
    && node.arguments[0]?.getText(pageAst).includes('this.surfaceFocused')) onFocus = node.arguments[0].getText(pageAst);
  compiler.forEachChild(node, visit);
}
visit(owner); assert.ok(onState && onFocus, '真实Page投影和焦点回调');
const noop = () => {};
const flush = async () => { for (let index = 0; index < 20; index++) await Promise.resolve(); };
function execute(text, bindings = {}) {
  const code = compiler.transpileModule(text, { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  return new Function(...Object.keys(bindings), code)(...Object.values(bindings));
}

/** 两条进程路线仅抽取实际前后台方法；恢复/设置/日志边缘不参与输入资格裁决。 */
function ability(relative, f) {
  const body = fs.readFileSync(path.join(root, relative), 'utf8');
  const ast = compiler.createSourceFile(relative, body, compiler.ScriptTarget.Latest, true);
  const abilityOwner = ast.statements.find(node => node.members?.some(member => member.name?.getText(ast) === 'onForeground'));
  const members = ['onBackground', 'onForeground'].map(name => abilityOwner.members.find(member => member.name?.getText(ast) === name).getText(ast)).join('\n');
  const Ability = execute('class Ability {\n' + members + '\n}\nreturn Ability;', {
    getInputSourceRegistry: () => f.registry, testNapi: f.native, AppLogger: { info: noop, warn: noop },
    AppStorage: { setOrCreate: noop }, ProductBuildProfile: { storeChannel: true },
    ProductInputProfile: { selection: () => ({ isolatedGameProcess: false }) },
    TAG: 'page-facts-fixture', LOG_DOMAIN_LAUNCH: 1,
    FRAME_RATE_FOREGROUND_SOURCE_GAME: 2, FRAME_RATE_FOREGROUND_SOURCE_ENTRY: 1,
  });
  const instance = new Ability(); instance.isolated = true; return instance;
}

/** 每组装载独立真实模块单例；关闭观察回调必须不影响运行资格或前台恢复。 */
function fixture(observe) {
  const gamecontrol = {};
  const controlTokens = new Map(), physicalEvents = []; let nextControlToken = 1;
  const native = { configureInputProduct: () => 0, setCursorLocked: noop, desktopGamepadFocus: noop,
    onGrabChange: callback => { native.grab = callback; },
    sendSourceKeyEvent: () => true, sendSourceMouseEvent: () => true, sendSourceScrollEvent: () => true, sendSourceCursorSample: () => true,
    isGrabbed: () => false, cursorLockWatchdogTick: () => false, inputInvariantTick: noop, mcIsRunning: () => true,
    cancelAllInput: noop, uninstallWindowInputFilters: noop, setOhosFrameRateForeground: noop, mcForceExit: noop };
  class Configuration { start() {} stop() {} reconcile() {} }
  /** 本组只验证页面/Ability资格；IME真实controller由独立完整runtime测试覆盖。 */
  class TextRuntime {
    start() {} maintain() {}
    stop() { return { stopOutcome: 'Completed', failure: '', localLeaseClosed: true, platformDetachResolved: true }; }
    addStopOutcomeListener() {} removeStopOutcomeListener() {}
  }
  class Window { enter() { return Promise.resolve(this.snapshot()); } snapshot() { return { windowId: 9 }; } restore() { return Promise.resolve(); } }
  class Logger { info() {} warn() {} error() {} }
  const env = environment({ commons: { ActivityLogger: Logger, LOG_DOMAIN_LAUNCH: 1 }, imports: {
    'gamecontrol': gamecontrol, 'launch': makePureEtsLoader()('launch/src/main/ets/ResolvedInputPlan.ets'),
    'libentry.so': { default: native },
    '@kit.BasicServicesKit': { systemDateTime: { TimeType: { ACTIVE: 1 }, getUptime: () => 0 } },
    '@kit.AbilityKit': { appRecovery: { restartApp: noop } },
    'entry/ProductInputProfile': { ProductInputProfile: { freeze: noop, current: () => ({ productKind: 0, runtimeApi: 26, supportsCursorLock: true }),
      selection: () => ({ desktopWindow: true }) } },
    'entry/ProductGameWindowCoordinator': { ProductGameWindowCoordinator: Window },
    // Native边缘只返回受控token，实际Client执行原connection准入/journal；不把此回执算作ABI Ready。
    '../components/EntrySourceControlClient': { createEntrySourceControlClient: () => {
      const { SourceControlClient } = env.load('gamecontrol/src/main/ets/SourceControlClient.ets');
      return new SourceControlClient(2, { acquire: (source, device, control, codes) => {
        const token = String(nextControlToken++); controlTokens.set(token, { source, device, control, codes }); return token;
      }, release: token => { controlTokens.delete(token); return true; } }, deviceConnections.reader);
    } },
    '../components/EntryInputSessionCoordinator': { reconcileEntryInputSession: noop },
    './EntryTextInputRuntime': { EntryTextInputRuntime: TextRuntime },
    '../components/EntryTouchInputMaintenance': { startEntryTouchInputMaintenance: () => ({}), reconcileEntryTouchInputMaintenance: () => true, stopEntryTouchInputMaintenance: noop },
  } });
  // 平台Monitor仅发布原add/remove边沿；纯Registry是实际生产身份表，查询不create新的硬件资格。
  const { InputDeviceConnectionRegistry } = env.load('gamecontrol/src/main/ets/InputDeviceConnectionLease.ets');
  const deviceConnections = new InputDeviceConnectionRegistry();
  const connectionListeners = new Set();
  const deviceMonitor = { hasMouse: () => true, connectionReader: () => deviceConnections.reader,
    addConnectionListener: callback => connectionListeners.add(callback),
    removeConnectionListener: callback => connectionListeners.delete(callback) };
  Object.assign(gamecontrol, env.load('gamecontrol/src/main/ets/GameInputRuntime.ets'), env.load('gamecontrol/src/main/ets/GamepadManager.ets'),
    env.load('gamecontrol/src/main/ets/InputSourceRegistry.ets'), { InputConfigurationRuntime: Configuration,
      GLFW_PRESS: 1, getInputDeviceMonitor: () => deviceMonitor, getPointerVisibility: () => ({ sync: noop, tick: noop, restore: noop }) });
  const registry = gamecontrol.getInputSourceRegistry();
  const host = env.load('entry/src/main/ets/runtime/GameSessionHost.ets').getGameSessionHost();
  const Page = execute('class Page {\n' + methods + '\n}\nreturn Page;'); const page = new Page();
  Object.assign(page, { sessionHost: host, inputRuntime: host.inputRuntime, pageVisible: true, surfaceFocused: true,
    gameWindowReady: true, inputOverlayPaused: false, pageInputActive: false, gameWindowId: 9 });
  let grabbed = false;
  Object.defineProperty(page, 'isInGame', { get: () => grabbed, set: value => {
    const changed = value !== grabbed; grabbed = value;
    // 只模拟源码实际连接的Watch，按事件末microtask执行其真实handler；没有连接就没有副作用。
    if (changed && watcher) Promise.resolve().then(() => page[watcher]());
  } });
  const callback = text => new Function(compiler.transpileModule('return (' + text + ');',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText).call(page);
  const focus = callback(onFocus);
  page.frontendLease = host.attach({}, 100, { onState: observe ? callback(onState) : noop, onMaintenance: noop, onLog: noop });
  host.configureProduct(); host.prepare({ addInputConfigurationListener: listener => listener(env.load('gamecontrol/src/main/ets/ControlLayout.ets').getDefaultLayout(), 1),
    removeInputConfigurationListener: noop, reconcileInputConfiguration: noop });
  host.bindPlan('v=v1;abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2');
  host.markRunning(); page.updatePageInputActive();
  const snapshot = () => ({ requested: host.requestedActive, lifecycle: host.inputRuntime.isLifecycleActive(), active: host.inputRuntime.active,
    raw: [page.pageVisible, page.surfaceFocused, page.gameWindowReady, page.inputOverlayPaused] });
  const close = async () => { host.stop('page-facts-test'); await flush(); assert.equal(env.timer.size, 0); assert.equal(connectionListeners.size, 0); };
  return { host, page, registry, native, focus, snapshot, close, env, gamecontrol,
    deviceConnections, connectionListeners, deviceMonitor, controlTokens, physicalEvents };
}

const routes = ['entry/src/main/ets/entryability/EntryAbility.ets', 'entry/src/main/ets/gameability/GameAbility.ets'];
for (const route of routes) {
  for (const observe of [false, true]) {
    const f = fixture(observe); const lifecycle = ability(route, f);
    assert.equal(f.snapshot().active, true);
    lifecycle.onBackground(); await flush(); assert.equal(f.snapshot().lifecycle, false);
    f.native.grab(true); await flush(); lifecycle.onForeground(); await flush();
    const expected = negative && observe ? false : true;
    assert.equal(f.snapshot().active, expected, route + ':grab投影不能改变原前端期望');
    assert.equal(f.snapshot().lifecycle, true); assert.deepEqual(f.snapshot().raw, [true, true, true, false]);
    await f.close();
  }
  const f = fixture(true); const lifecycle = ability(route, f);
  lifecycle.onBackground(); await flush(); f.focus(); await flush(); lifecycle.onForeground(); await flush();
  assert.equal(f.snapshot().lifecycle, true);
  assert.equal(f.snapshot().active, !negative, route + ':后台晚到focus不能把Ability失活写成持久页面请求false');
  assert.deepEqual(f.snapshot().raw, [true, true, true, false]); await f.close();
}
console.log(negative ? 'PASS old-source negative replay: both Ability routes reproduce observer and late-focus writeback failure'
  : 'PASS actual Page/Host/Runtime/Registry: observer on/off and background grab/late-focus restore without new UI event on both Ability routes');

// 真正的页面资源/模态变化仍由生产Page更新端口关闭资格；修复不能为了前台恢复放行失效资源。
if (!negative) {
  for (const [field, inactive, restored] of [['pageVisible', false, true], ['surfaceFocused', false, true],
    ['gameWindowReady', false, true], ['inputOverlayPaused', true, false]]) {
    for (const route of routes) {
      const f = fixture(true); const lifecycle = ability(route, f);
      f.page[field] = inactive; f.page.updatePageInputActive(); await flush();
      assert.equal(f.snapshot().active, false, field + ':真实事实失效必须关闭');
      lifecycle.onBackground(); await flush(); f.native.grab(true); await flush(); lifecycle.onForeground(); await flush();
      assert.equal(f.snapshot().lifecycle, true); assert.equal(f.snapshot().active, false, field + ':Ability前台不能覆盖真实页面失效');
      f.page[field] = restored; f.page.updatePageInputActive(); await flush();
      assert.equal(f.snapshot().active, true, field + ':原始事实恢复后重新合取资格'); await f.close();
    }
  }
  console.log('PASS real page facts: visible/focus/window/overlay independently block admission through foreground and restore only on their own fact');
}
// 抽取实际Page热插拔方法，保原异常/早退/物理清理正文；平台描述和Native回执是显式边缘。
// 映射侧使用上述真实Host/Runtime/Manager/Client/Registry，不在fixture重写按连接退休算法。
if (!negative) {
  function hotplugPage(f) {
    const member = owner.members.find(node => node.name?.getText(pageAst) === 'handleDeviceChange');
    assert.ok(member, '真实Page热插拔入口');
    const abi = f.env.load('gamecontrol/src/main/ets/InputDeviceAbi.ets');
    const lifecycle = f.env.load('gamecontrol/src/main/ets/InputDeviceLifecycleCoordinator.ets');
    const keys = f.env.load('gamecontrol/src/main/ets/KeyMap.ets');
    const gl = f.env.load('gamecontrol/src/main/ets/GlfwKeys.ets');
    const Subject = execute('class HotplugPage {\n' + member.getText(pageAst) + '\n}\nreturn HotplugPage;', {
      normalizeDeviceId: abi.normalizeDeviceId, InputDeviceClass: abi.InputDeviceClass,
      composeGlfwMods: keys.composeGlfwMods, glfwKeyFromOhos: keys.glfwKeyFromOhos,
      SHADOW_KEY_UP: f.env.load('gamecontrol/src/main/ets/PhysicalKeyEdge.ets').SHADOW_KEY_UP,
      GLFW_RELEASE: gl.GLFW_RELEASE, testNapi: f.native,
      // 旧源真实负控仍要能读其类型分支；Unknown明确提供未知元数据，不能吞ReferenceError假失败。
      DeviceGamepadKind: lifecycle.DeviceGamepadKind,
      getInputDeviceMonitor: () => ({ gamepadKindOf: () => lifecycle.DeviceGamepadKind.Unknown }),
      getInputSourceRegistry: () => f.registry, AmclInputSource: f.gamecontrol.AmclInputSource,
      TAG: 'page-hotplug-fixture', LOG_DOMAIN_LAUNCH: 1,
    });
    const page = new Subject(); const { PhysicalHeldKeyTracker } = f.env.load('gamecontrol/src/main/ets/PhysicalHeldKeyTracker.ets');
    Object.assign(page, { gamepad: f.host.gamepad, heldKeys: new PhysicalHeldKeyTracker(),
      deviceInventoryGuard: new lifecycle.DeviceInventoryPublicationGuard(),
      reconcileNativeResetEpoch: () => f.physicalEvents.push(['reconcile']),
      readDeviceDescriptor: () => undefined,
      launchLogger_: () => ({ info: noop, warn: (...args) => assert.fail('热插拔抛错: ' + args.join(' ')) }),
    });
    f.native.physicalKeyTransaction = (...args) => { f.physicalEvents.push(['key-up', ...args]); return 1; };
    f.native.publishInputDeviceChange = (...args) => f.physicalEvents.push(['device', ...args]);
    return page;
  }
  for (const started of [false, true]) {
    const f = fixture(false), page = hotplugPage(f); page.mcStarted = started;
    f.native.grab(true);
    const first = f.deviceConnections.observeAdd(7).originalConnection;
    const sibling = f.deviceConnections.observeAdd(8).originalConnection;
    const { AXIS_ABS_Y } = f.env.load('gamecontrol/src/main/ets/GamepadManager.ets');
    for (const connection of [first, sibling]) {
      const fact = f.host.inputRuntime.captureAxisForConnection(connection, axis => axis === AXIS_ABS_Y ? -1 : 0);
      assert.ok(fact); f.host.inputRuntime.handleAxisFact(fact);
    }
    assert.equal(f.controlTokens.size, 2, '两个真实连接各有独立Native贡献回执');
    // Monitor的生产顺序先发布原connection，后旧raw fanout；原身份由真实Registry签发。
    const removed = f.deviceConnections.retireCurrent(7);
    for (const listener of [...f.connectionListeners]) listener(removed);
    assert.equal(f.controlTokens.size, 1, 'Host先精确退休原连接');
    page.heldKeys.noteDown(7, 2017); page.heldKeys.noteDown(8, 2017);
    page.handleDeviceChange({ deviceId: 7, added: false });
    if (hotplugNegative) assert.equal(f.host.gamepad.hasConnectionState(sibling), false, '真实旧Page会误清仍连接的兄弟');
    else {
      assert.equal(f.host.gamepad.hasConnectionState(sibling), true, '拔一路不能清掉兄弟映射状态');
      assert.equal(f.controlTokens.size, 1, '页面不得再取消整个Gamepad来源');
      assert.deepEqual([...page.heldKeys.heldKeys()], [2017], '兄弟物理同键持有保持');
      assert.equal(page.heldKeys.releaseDevice(7).length, 0, '被拔设备物理缓存已摘');
      assert.equal(page.heldKeys.releaseDevice(8).length, 1);
      assert.deepEqual(f.physicalEvents.map(row => row[0]), started ? ['reconcile', 'key-up', 'device'] : [],
        '已启动时保先对账、补UP、最后device removed；未启动无Native副作用');
      if (started) {
        assert.deepEqual(f.physicalEvents.at(-1).slice(1), [7, false, 0, 0]);
        assert.equal(f.physicalEvents[1][4], f.env.load('gamecontrol/src/main/ets/PhysicalKeyEdge.ets').SHADOW_KEY_UP);
      }
    }
    await f.close();
  }
  console.log(hotplugNegative ? 'PASS actual old Page negative replay: before/after game-start hotplug clears unrelated sibling'
    : 'PASS actual Page hotplug and Host connection cleanup: before/after game-start keeps sibling, physical UP/device order preserved');
}
console.log('page-session-facts source_sha256=' + createHash('sha256').update(pageSource).digest('hex')
  + ' watch=' + (watcher ?? 'none') + ' replay=' + Boolean(snapshotFlag));

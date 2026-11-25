/** 真实状态解码与桌面命令回归：请求不能冒充actual，虚拟L不能在退出全屏时缩小OS窗口。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import compiler from './lib/ets-compiler.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const pure = makePureEtsLoader();
const resolution = pure('entry/src/main/ets/runtime/GameResolutionState.ets');
const native = { schema: 1, requestId: '2', generation: '4', phase: 'confirmed', requestedPercent: 75,
  configuredPercent: 75, displayWidth: 2688, displayHeight: 1216, logicalWidth: 2016, logicalHeight: 912,
  actualWidth: 2016, actualHeight: 912, actualSource: 1, canRequest: true, virtualWindowManaged: true, reason: '' };
const parse = value => resolution.parseGameResolutionState(JSON.stringify(value));
assert.equal(parse(native).phase, 'confirmed');
assert.match(resolution.gameResolutionMessage(parse(native)), /2016 × 912/);
for (const changed of [{ actualSource: 0 }, { actualWidth: 0 }, { logicalWidth: 2688 }, { generation: '0' },
  { requestedPercent: 101 }, { actualHeight: -1 }, { actualSource: 9 }, { phase: 'fake-success' }, { canRequest: 'true' }]) {
  assert.equal(parse({ ...native, ...changed }).phase, 'unavailable');
}
const pending = parse({ ...native, phase: 'pending', requestedPercent: 50 });
assert.equal(pending.actualWidth, 2016, 'old observed pixels remain distinct from the new requested percent');
assert.doesNotMatch(resolution.gameResolutionMessage(pending), /已生效/);
assert.equal(resolution.parseGameResolutionState('{broken').phase, 'unavailable');

// 窗口系统是唯一替身。实际DesktopSystemBridge.execute决定是否转交resize/recover，
// 不在fixture复制其窗口或分辨率政策。
let status = 1, width = 3840, height = 2160, resized = 0, recovered = 0;
let snapshot = { ...native, requestedPercent: 100, configuredPercent: 100,
  displayWidth: 3840, displayHeight: 2160, logicalWidth: 3840, logicalHeight: 2160, actualWidth: 3840, actualHeight: 2160 };
const windowModule = { WindowStatusType: { FULL_SCREEN: 1, MAXIMIZE: 2, MINIMIZE: 3, FLOATING: 4 },
  MaximizePresentation: { ENTER_IMMERSIVE: 2, EXIT_IMMERSIVE: 1 } };
const displayService = {};
const nativeWindowApi = { mcGetResolutionState: () => JSON.stringify(snapshot) };
const load = makePureEtsLoader({
  '@kit.ArkUI': { window: windowModule, display: displayService }, '@kit.BasicServicesKit': {}, '@kit.AbilityKit': {},
  '@ohos.deviceInfo': { default: { sdkApiVersion: 26 } }, commons: { AppLogger: { warn() {}, info() {} } },
  'libentry.so': { default: nativeWindowApi },
  '../runtime/GameResolutionState': resolution,
});
const { DesktopSystemBridge } = load('entry/src/main/ets/window/DesktopSystemBridge.ets');
const bridge = Object.create(DesktopSystemBridge.prototype);
const win = { getWindowStatus: () => status,
  getWindowProperties: () => ({ displayId: 0, windowRect: { width, height }, drawableRect: { width, height, left: 0, top: 0 } }),
  async recover() { recovered++; status = 4; width = 1280; height = 720; },
  async resize(w, h) { resized++; width = w; height = h; },
};
await bridge.execute({ kind: 3, a: 0, b: 0, c: 0, d: 0 }, win);
await bridge.execute({ kind: 1, a: 960, b: 540, c: 0, d: 0 }, win);
assert.equal(recovered, 1);
assert.equal(resized, 0);
assert.deepEqual([width, height], [1280, 720], 'old 75 percent saved L cannot resize restored physical P after returning to 100 percent');
snapshot = { ...snapshot, virtualWindowManaged: false };
await bridge.execute({ kind: 1, a: 1000, b: 700, c: 0, d: 0 }, win);
assert.deepEqual([width, height], [1000, 700], 'native-only session keeps existing game window resize behavior');
await assert.rejects(bridge.execute({ kind: 1, a: 0, b: 700, c: 0, d: 0 }, win), /Invalid window size/);
snapshot = {};
await assert.rejects(bridge.execute({ kind: 1, a: 960, b: 540, c: 0, d: 0 }, win), /政策不可用/);
assert.deepEqual([width, height], [1000, 700], 'unknown policy cannot reinterpret virtual dimensions as physical');
// 同一个主窗的枚举故障必须保留已确认双屏，窗口位置继续更新；真正拔屏在成功枚举后生效。
{
  const noop = () => {};
  const rect = { left: 0, top: 0, width: 1280, height: 720 };
  const primary = { id: 0, name: 'Internal', width: 1920, height: 1080, densityPixels: 1,
    refreshRate: 60, xDPI: 96, yDPI: 96, getAvailableArea: async () => rect, on: noop, off: noop };
  const external = { ...primary, id: 1, name: 'External' };
  let devices = [primary, external], unavailable = true, left = 0;
  Object.assign(displayService, { on: noop, off: noop, getDisplayByIdSync: () => primary,
    getDefaultDisplaySync: () => primary, convertRelativeToGlobalCoordinate: () => ({ x: 1920, y: 0 }),
    async getAllDisplays() { if (unavailable) throw Error('display service unavailable'); return [...devices]; } });
  const published = [];
  Object.assign(nativeWindowApi, { desktopAttach: () => 1, desktopDetach: noop,
    desktopPublishState(_generation, facts, values, names) {
      published.push({ left: facts[2], names: [...names], values: [...values] }); return true;
    } });
  const systemWindow = { getWindowStatus: () => 4, getWindowLimits: () => ({}), on: noop, off: noop,
    getWindowProperties: () => ({ id: 8, displayId: 0, windowRect: rect, drawableRect: rect,
      globalDisplayRect: { ...rect, left } }) };
  const systemBridge = new DesktopSystemBridge();
  await systemBridge.start(systemWindow);
  unavailable = false;
  await systemBridge.start(systemWindow);
  unavailable = true; left = 125;
  await systemBridge.start(systemWindow);
  unavailable = false; devices = [primary];
  await systemBridge.start(systemWindow);
  systemBridge.stop();
  assert.deepEqual(published.map(row => row.names), [['Internal'], ['Internal','External'],
    ['Internal','External'], ['Internal']]);
  assert.equal(published[2].left, 125);
  assert.deepEqual(published[2].values, published[1].values);
}
// 游戏在 A 全屏请求 B。逐阶段注入系统拒绝，通过正式命令队列检查补偿和完成前的实际状态。
for (const fault of ['missing', 'move', 'maximize', 'from-maximized', 'floating-lost-on-move',
  'floating-lost-on-maximize', 'original-unplugged', 'replaced', 'success']) {
  const noop = () => {};
  const rect = { left: 0, top: 0, width: 1280, height: 720 };
  const screens = [0, 1].map(id => ({ id, name: String(id), width: 1920, height: 1080,
    densityPixels: 1, refreshRate: 60, xDPI: 96, yDPI: 96, on: noop, off: noop, getAvailableArea: async () => rect }));
  const initialMode = fault.startsWith('floating-') ? 4 : fault === 'from-maximized' ? 2 : 1;
  const originalX = initialMode === 4 ? 122 : 0;
  let monitor = 0, mode = initialMode, x = originalX, generation = 1, command, wake, lastFacts;
  const writes = [], completions = [];
  Object.assign(displayService, { on: noop, off: noop, getAllDisplays: async () => screens,
    getDefaultDisplaySync: () => screens[0], convertRelativeToGlobalCoordinate: p => ({ x: p.displayId * 1920, y: 0 }),
    getDisplayByIdSync(id) {
      if ((fault === 'missing' && id === 1) || (fault === 'original-unplugged' && monitor === 1 && id === 0)) throw Error('display gone');
      return screens[id];
    } });
  Object.assign(nativeWindowApi, { desktopAttach(fn) { wake = fn; return generation; }, desktopDetach: noop,
    desktopTakeCommand() { const next = command; command = undefined; return next; },
    desktopPublishState(_g, facts) { lastFacts = [facts[1],facts[6]]; return true; },
    desktopCompleteCommand(g,_seq,err) { completions.push({ g, err, facts: lastFacts }); } });
  const realBridge = new DesktopSystemBridge();
  const win = { on: noop, off: noop, getWindowLimits: () => ({}), getWindowStatus: () => mode,
    getWindowProperties: () => ({ id: 42, displayId: monitor, windowRect: rect, drawableRect: rect,
      globalDisplayRect: {...rect,left:x} }),
    async recover() { writes.push('restore'+monitor); mode=4; x=monitor*1920+80; },
    async moveWindowToGlobal(left) {
      const dest = left >= 1920 ? 1 : 0;
      writes.push('move'+dest);
      if (dest === 1 && fault === 'move') throw Error('move refused');
      monitor=dest; x=left;
      if (dest === 1 && fault === 'floating-lost-on-move') { monitor=0; x=73; }
      if (fault === 'replaced') { generation++; realBridge.stop(); }
    },
    async maximize(presentation) {
      writes.push('max'+monitor);
      if (monitor === 1 && ['maximize','from-maximized','original-unplugged'].includes(fault)) throw Error('maximize refused');
      mode=presentation === windowModule.MaximizePresentation.ENTER_IMMERSIVE ? 1 : 2;
      x=monitor*1920;
      if (monitor === 1 && fault === 'floating-lost-on-maximize') { monitor=0; x=0; }
    } };
  await realBridge.start(win);
  command={ kind:3, a:1, b:1, generation, sequence:1 };
  assert.equal(typeof wake,'function');
  await realBridge.drain();
  assert.equal(completions.length,1);
  assert.equal(completions[0].err === 0,fault === 'success');
  if (fault === 'replaced') {
    assert.deepEqual(writes,['restore0','move1'],'旧代不能最大化或回退新窗口');
    assert.equal(completions[0].g,1);
  } else {
    const expected = fault === 'success' ? [1,1] : fault === 'original-unplugged' ? [1,4] : [0,initialMode];
    assert.deepEqual([monitor,mode],expected,fault);
    assert.deepEqual(completions[0].facts,expected,'完成前已发布真实显示器和状态 '+fault);
    if (fault === 'missing') assert.deepEqual(writes,[],'目标不存在时保持原屏全屏');
    if (initialMode === 4) {
      assert.equal(x,originalX,'回到原屏的浮动窗口位置');
      if (fault === 'floating-lost-on-move') assert.ok(!writes.some(w => w.startsWith('max')));
      else assert.ok(writes.includes('restore0'),'最大化之后目标消失也须恢复原屏浮窗');
    }
  }
  realBridge.stop();
}
console.log('PASS cross-display fullscreen: prior target validation, partial failure recovery, window lease and actual completion facts');
// 执行真实守卫生命周期，仅替换定时器和Native读口；异常不能伪造终局或刷屏。
{
  const file = 'entry/src/main/ets/components/GameResolutionGuard.ets';
  const text = fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
  const tree = compiler.createSourceFile(file, text, compiler.ScriptTarget.Latest, true);
  const owner = tree.statements.find(node => node.name?.text === 'GameResolutionGuard');
  const methods = ['aboutToAppear', 'aboutToDisappear'].map(name => {
    const member = owner.members.find(node => node.name?.text === name); assert.ok(member); return member.getText(tree);
  });
  const output = compiler.transpileModule('return class Guard {' + methods.join('\n') + '}',
    {compilerOptions: {target: compiler.ScriptTarget.ES2022}}).outputText;
  let tick, warnings = 0, failures = 0, reads = 0, cleared = 0, unavailable = true;
  const ports = {setInterval: (callback, delay) => {assert.equal(delay, 1000);tick = callback;return 17;},
    clearInterval: id => {assert.equal(id, 17);cleared++;},
    testNapi: {mcGetResolutionState: () => {reads++;if (unavailable) throw Error('native unavailable');return JSON.stringify({...native, phase: 'restart-required'});}},
    parseGameResolutionState: resolution.parseGameResolutionState,
    AppLogger: {warn: () => warnings++}, LogTags: {PAGE_MC_GAME: 'McGamePage'}, LOG_DOMAIN_UI: 0};
  const Type = new Function(...Object.keys(ports), output)(...Object.values(ports));
  const guard = Object.assign(new Type(), {syncPalette_() {}, fatal: false, onFailure: () => failures++});
  guard.aboutToAppear();tick();tick();
  assert.equal(warnings, 1);assert.equal(guard.fatal, false);assert.equal(failures, 0);
  guard.aboutToDisappear();const before = reads;tick();assert.equal(reads, before);assert.equal(cleared, 1);
  guard.aboutToAppear();tick();assert.equal(warnings, 2, '新显示周期可记录新的首次失败');
  unavailable = false;tick();tick();assert.equal(guard.fatal, true);assert.equal(failures, 1);
  guard.aboutToDisappear();
}

// 守卫已经确认终局时，即使下一次读取失败，取消/确认仍能分别保留/结束本局。
{
  const file = 'entry/src/main/ets/components/GameResolutionPanel.ets';
  const text = fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
  const tree = compiler.createSourceFile(file, text, compiler.ScriptTarget.Latest, true);
  const owner = tree.statements.find(node => node.name?.text === 'GameResolutionPanel');
  const names = ['aboutToAppear', 'aboutToDisappear', 'requiresRestart', 'apply', 'confirmEndGame',
    'refresh', 'navigate_', 'confirmedPercent_'];
  const methods = names.map(name => {
    const member = owner.members.find(node => node.name?.text === name);
    assert.ok(member, name);
    return member.getText(tree);
  });
  const output = compiler.transpileModule('return class Panel {' + methods.join('\n') + '}',
    { compilerOptions: { target: compiler.ScriptTarget.ES2022 } }).outputText;
  let resolveDialog, exits = 0, liveReads = 0, state = native;
  const routes = [];
  const ports = {
    testNapi: {
      mcForceExit: () => exits++,
      mcGetResolutionState: () => { liveReads++; return JSON.stringify(state); },
      mcRequestResolutionScale: () => assert.fail('故障面板不得提交比例'),
    },
    parseGameResolutionState: resolution.parseGameResolutionState, unavailableGameResolution: resolution.unavailableGameResolution,
    setInterval: () => assert.fail('故障面板无需再次轮询'),
    clearInterval: () => assert.fail('故障面板没有轮询定时器'),
  };
  const Type = new Function(...Object.keys(ports), output)(...Object.values(ports));
  const panel = Object.assign(new Type(), {
    exitOnly: true, timer: -1, snapshot: resolution.unavailableGameResolution(), palette: {},
    onNavigate: id => routes.push(id), onDone: () => routes.push('directory'), onReturnGame: () => routes.push('resume'),
    refresh: () => assert.fail('故障面板无需重新读取已锁存的终局'),
    getUIContext: () => ({ getPromptAction: () => ({
      showDialog: () => new Promise(resolve => { resolveDialog = resolve; }),
    }) }),
  });
  panel.aboutToAppear();
  assert.equal(panel.requiresRestart(), true);
  panel.apply();
  assert.equal(panel.error, undefined, '故障模式拒绝请求而非显示可重试的应用错误');
  panel.confirmEndGame();
  resolveDialog({ index: 0 });
  await Promise.resolve();
  assert.equal(exits, 0);
  panel.confirmEndGame();
  resolveDialog({ index: 1 });
  await Promise.resolve();
  assert.equal(exits, 1);
  panel.confirmEndGame();
  panel.aboutToDisappear();
  resolveDialog({ index: 1 });
  await Promise.resolve();
  assert.equal(exits, 1, '旧面板离开后不再终止当前游戏');

  // 分辨率页与手感页共用宿主导航。退出确认独立于侧栏，故障或迟到的操作不能释放编辑事务。
  for (const id of ['look', 'layout', 'home', 'game']) panel.navigate_(id);
  assert.deepEqual(routes, []);
  const live = Object.assign(new Type(), { active: true, exitOnly: false, snapshot: resolution.unavailableGameResolution(),
    onNavigate: panel.onNavigate, onDone: panel.onDone, onReturnGame: panel.onReturnGame });
  for (const id of ['look', 'layout', 'resolution', 'home', 'game']) live.navigate_(id);
  assert.deepEqual(routes, ['look', 'layout', 'directory', 'resume']);
  live.active = false;
  live.navigate_('move');
  assert.equal(routes.length, 4);
  live.active = true;
  live.refresh();
  assert.equal(live.confirmedPercent_(), '75%');
  state = { ...native, phase: 'pending', requestedPercent: 50 };
  live.refresh();
  assert.equal(live.confirmedPercent_(), '—', '新的手动请求不能充当已确认的比例');
  state = { ...native, phase: 'restart-required' };
  live.refresh();
  const readsAtFailure = liveReads;
  state = { ...native, phase: 'confirmed' };
  live.refresh();
  assert.equal(liveReads, readsAtFailure, '正常页锁存终局后不会被迟到的真实回读重新开放');
  assert.equal(live.requiresRestart(), true);
  for (const id of ['look', 'layout', 'home', 'game']) live.navigate_(id);
  assert.equal(routes.length, 4);
}
console.log('game-resolution-state: protocol negatives, physical restoration and failure-only exit passed');

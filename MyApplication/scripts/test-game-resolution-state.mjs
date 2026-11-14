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
  MaximizePresentation: { ENTER_IMMERSIVE: 0 } };
const load = makePureEtsLoader({
  '@kit.ArkUI': { window: windowModule, display: {} }, '@kit.BasicServicesKit': {}, '@kit.AbilityKit': {},
  '@ohos.deviceInfo': { default: { sdkApiVersion: 26 } }, commons: { AppLogger: { warn() {}, info() {} } },
  'libentry.so': { default: { mcGetResolutionState: () => JSON.stringify(snapshot) } },
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
console.log('game-resolution-state: protocol negatives, physical restoration and bounded guard failure/recovery passed');

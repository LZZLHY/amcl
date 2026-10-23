// 执行真实预检的槽选择接线；校验器替身只记录路径和返回结果，不复制内容校验算法。
// 实际 SHA、部署中断和 marker 负例由 test-lwjgl-runtime-slots.mjs 覆盖。
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
let manifest;
const checked = [];
let integrity = { ok: true, detail: 'selected slot verified' };
const load = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo: {} },
  '@kit.PerformanceAnalysisKit': { hilog: {} },
  // 真实 PreLaunchValidator 会传递装载 RuntimeDeployer；本用例不传 context，也不执行摘要。
  // 只提供模块边界，任何意外 createMd 调用仍立即失败，不能用固定摘要放行完整性检查。
  '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
  './LaunchNativeBridge': {}, './LaunchProfileBuilder': {}, mods: {},
  // 2f4bd47 起 PreLaunchValidator 从 commons 取整合包 pending 判定，只供 runModInstallState 使用。
  // 本测试只跑 runRuntime：替身一旦被调用即失败，防止运行时槽检查悄悄依赖安装状态。
  commons: { hasPendingModpackInstall: () => { throw new Error('runRuntime must not consult modpack install state'); } },
  feature_core: { VersionParser: { parse: () => manifest } },
  './LwjglSlotIntegrity': { verifyLwjglRuntimeSlot: async path => { checked.push(path); return integrity; } },
});
const { PreLaunchValidator } = load('launch/src/main/ets/PreLaunchValidator.ets');
const { lwjglGenerationDirectory } = load('launch/src/main/ets/RuntimeSlotGenerations.ets');
const input = { mcDir: '/fixture/mc', version: 'renamed-instance', jdkVersion: '17' };
for (const [library, directory] of [
  ['org/lwjgl/lwjgl/lwjgl/2.9.4/lwjgl-2.9.4.jar', 'lwjgl-ohos-2'],
  ['org/lwjgl/lwjgl/3.2.2/lwjgl-3.2.2.jar', 'lwjgl-ohos-322'],
  ['org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar', 'lwjgl-ohos'],
]) {
  manifest = { libraries: [library], inheritsFrom: '' };
  checked.length = 0;
  assert.equal((await PreLaunchValidator.runRuntime(input, true)).status, 'pass');
  assert.deepEqual(checked, [lwjglGenerationDirectory('/fixture/mc', directory, 17)]);
}
// 使用真实预检函数核对三种 JDK 的代际选择；不能仅在选择器单测里构造正确路径。
for (const feature of [17, 21, 25]) {
  input.jdkVersion = String(feature);
  checked.length = 0;
  assert.equal((await PreLaunchValidator.runRuntime(input, true)).status, 'pass');
  assert.deepEqual(checked, [lwjglGenerationDirectory('/fixture/mc', 'lwjgl-ohos', feature)]);
}
input.jdkVersion = '23';
assert.equal((await PreLaunchValidator.runRuntime(input, true)).status, 'fail', '未交付的 JDK 视图不能回退原包');
input.jdkVersion = '17';
integrity = { ok: false, detail: 'selected digest mismatch' };
assert.equal((await PreLaunchValidator.runRuntime(input, true)).status, 'fail');
manifest = null;
checked.length = 0;
assert.equal((await PreLaunchValidator.runRuntime(input, true)).status, 'fail');
assert.equal(checked.length, 0);
assert.equal((await PreLaunchValidator.runRuntime(input, true)).fixActionKey, 'redownload', '清单缺失仍保留版本修复入口');
manifest = { libraries: [], inheritsFrom: '1.20.4' };
assert.equal((await PreLaunchValidator.runRuntime(input, true)).status, 'fail');
assert.equal(checked.length, 0);
assert.equal((await PreLaunchValidator.runRuntime(input, true)).fixActionKey, 'redownload', '未合并清单必须允许原有深度修复');
assert.equal((await PreLaunchValidator.runRuntime(input, false)).fixActionKey, 'download_jdk');
console.log('prelaunch-runtime-slot PASS: manifest-selected 2/322/modern; no unrelated-slot IO; fail-closed invalid manifest/digest');

#!/usr/bin/env node
/**
 * 离线执行真实 ArkTS 槽位选择器和 LaunchProfileBuilder.buildClasspath。
 * 文件系统为只读桩，不需要设备、游戏安装或 JVM；故意放入残留 JAR、缺必需文件、
 * 官方 Maven 副本，证明最终 classpath 由清单决定，而不是只匹配源码字符串。
 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const present = new Set();
let directoryScans = 0;
let writes = 0;
const fsStub = {
  statSync(path) {
    if (!present.has(path)) throw new Error('fixture missing: ' + path);
    return { size: 512 };
  },
  listFileSync() { directoryScans++; return ['lwjgl.jar', 'lwjgl-glfw-patch.jar', 'foreign.jar']; },
  copyFileSync() { writes++; throw new Error('共享缓存不得被改写'); },
};
class SilentLogger {
  info() {}
  warn() {}
  error() {}
}
const load = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo: fsStub },
  commons: { ActivityLogger: SilentLogger },
  feature_core: { parseLibraryPathGav: () => null },
  account: {},
  mods: {},
  './LaunchNativeBridge': {},
  './GameCompatibility': {},
  './GraphicsProfileRegistry': { GraphicsGameApi: { UNKNOWN: 'unknown' } },
  './GraphicsBackendPlan': { VulkanPolicy: { ALLOW: 'allow' } },
  './GraphicsGameFacts': {},
  './LoaderGenerationResolver': {},
  './LaunchContractPreflight': {},
  './LaunchAgentProbe': {},
});
const { lwjglSlotClasspath, lwjglSlotJarNames } = load('launch/src/main/ets/RuntimeSlotClasspath.ets');
const { LWJGL_MODERN_JARS } = load('launch/src/main/ets/LwjglModernSlot.ets');
const { lwjglRuntimeSlot } = load('launch/src/main/ets/LwjglRuntimeSlots.ets');
const { LaunchProfileBuilder } = load('launch/src/main/ets/LaunchProfileBuilder.ets');
const { lwjglGenerationDirectory } = load('launch/src/main/ets/RuntimeSlotGenerations.ets');
const root = '/fixture/.minecraft';
const modernNames = LWJGL_MODERN_JARS.map((jar) => jar.name);
assert.deepEqual(lwjglSlotJarNames(root + '/lwjgl-ohos'), modernNames);
assert.equal(modernNames.includes('lwjgl-jemalloc.jar'), false, 'modern 必须保持已验证的 allocator 回退');
const oldNames = ['lwjgl-glfw.jar', 'lwjgl-jemalloc.jar', 'lwjgl-openal.jar',
  'lwjgl-opengl.jar', 'lwjgl-stb.jar', 'lwjgl-tinyfd.jar', 'lwjgl.jar'];
assert.deepEqual(lwjglSlotJarNames(root + '/lwjgl-ohos-322'), oldNames);
assert.deepEqual(lwjglSlotJarNames(root + '/lwjgl-ohos-2'), ['lwjgl.jar']);
assert.throws(() => lwjglSlotClasspath(root + '/lwjgl-ohos-unapproved'), /未知 LWJGL/);
assert.throws(() => lwjglSlotClasspath(root + '/lwjgl-ohos-2-extra'), /未知 LWJGL/);
const mutableCopy = lwjglSlotJarNames(root + '/lwjgl-ohos');
mutableCopy.push('injected.jar');
assert.deepEqual(lwjglSlotJarNames(root + '/lwjgl-ohos'), modernNames, '调用方不得污染后续启动');

// 与部署/预检直接共享槽描述符，而不是从消费者源码反推第三份名单。修改返回的
// 副本也不能污染下一次启动；内容摘要正确性由三槽交付门禁另行验证。
for (const directory of ['lwjgl-ohos', 'lwjgl-ohos-322', 'lwjgl-ohos-2']) {
  const slot = lwjglRuntimeSlot(root + '/' + directory);
  assert.equal(slot.deploymentDirectory, directory);
  assert.deepEqual(lwjglSlotJarNames(root + '/' + directory), slot.jars.map((jar) => jar.name));
  slot.jars[0].name = 'polluted.jar';
  assert.equal(lwjglSlotJarNames(root + '/' + directory).includes('polluted.jar'), false);
}

const builder = new LaunchProfileBuilder().setMcDir(root).setVersion('fixture');
const gameJar = root + '/versions/fixture/fixture.jar';
const ordinaryLibrary = 'com/example/api/1/api-1.jar';
const officialLwjgl = 'org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar';
const parsed = { libraries: [officialLwjgl, ordinaryLibrary], mainClass: 'net.minecraft.client.main.Main' };
present.add(gameJar);
present.add(root + '/libraries/' + ordinaryLibrary);
present.add(root + '/libraries/' + officialLwjgl);

for (const slot of ['lwjgl-ohos', 'lwjgl-ohos-322', 'lwjgl-ohos-2']) {
  const directory = lwjglGenerationDirectory(root, slot);
  const expected = lwjglSlotClasspath(directory);
  for (const jar of expected) present.add(jar);
  present.add(directory + '/foreign.jar');
  present.add(directory + '/lwjgl-glfw-patch.jar');
  const result = builder.buildClasspath(parsed, directory, true);
  assert.deepEqual(result.jars, [gameJar, root + '/libraries/' + ordinaryLibrary, ...expected]);
  assert.deepEqual(result.missingJars, []);
  assert.equal(result.jars.some((path) => path.includes('/libraries/org/lwjgl/')), false);

  // 对每个槽故意移除核心 JAR：旧目录扫描会漏报，现在必须保留路径并报缺失。
  const missing = directory + '/lwjgl.jar';
  present.delete(missing);
  const incomplete = builder.buildClasspath(parsed, directory, true);
  assert.ok(incomplete.jars.includes(missing));
  assert.deepEqual(incomplete.missingJars, [missing]);
  present.add(missing);
}
assert.equal(directoryScans, 0, '构建 classpath 不得枚举目录作为依赖来源');
assert.equal(writes, 0, '构建 classpath 不得修改 Maven 缓存');

// 退役旧的库覆盖/恢复入口；检查原型而不是注释，防止死代码今后被重新接回。
assert.equal(LaunchProfileBuilder.prototype.patchLwjglJarForFabric, undefined);
assert.equal(LaunchProfileBuilder.prototype.restoreOriginalLwjglJars, undefined);
assert.equal(LaunchProfileBuilder.prototype.listJarsInDir, undefined);
console.log('[runtime-slot-classpath] PASS: 三槽精确名单、旧槽部署一致、残留隔离、缺文件诊断、无共享缓存改写');

/**
 * 输入启动子契约的生产纯模块与私有快照回归。
 * 版本/槽判断取真实GraphicsGameFacts，故意用可重命名实例及L2+GLFW证明输入身份独立。
 * 文件、账户与进程边界沿既有布局fixture隔离；不把这些宿主测试称为真实consumer Ready。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import { fixture } from './lib/game-layout-fixture.mjs';

const load = makePureEtsLoader();
const { graphicsGameFacts } = load('launch/src/main/ets/GraphicsGameFacts.ets');
const { resolveInputPlan, serializeInputPlan, parseInputPlan, inputPlanMatchesRuntime, InputAbi,
  INPUT_PLAN_SCHEMA } = load('launch/src/main/ets/ResolvedInputPlan.ets');
const plans = [];
for (const [libraries, slot, abi, window] of [
  [['org/lwjgl/lwjgl/lwjgl/2.9.4/lwjgl-2.9.4.jar'], 'LWJGL2', InputAbi.LWJGL2, 'GLFW'],
  [['org/lwjgl/lwjgl/3.2.2/lwjgl-3.2.2.jar'], 'LWJGL322', InputAbi.GLFW, 'GLFW'],
  [['org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar'], 'LWJGL3', InputAbi.GLFW, 'GLFW'],
  [['org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar', 'org/lwjgl/lwjgl-sdl/3.4.3/lwjgl-sdl-3.4.3.jar'],
    'LWJGL3', InputAbi.SDL3, 'SDL3'],
]) {
  const plan = resolveInputPlan(graphicsGameFacts(libraries, 'renamed-instance'), '/leased/java/' + slot);
  assert.equal(plan.abi, abi);
  assert.equal(plan.lwjglSlot, slot);
  assert.equal(plan.windowProvider, window);
  assert.equal(plan.javaSlotDirectory, '/leased/java/' + slot);
  assert.equal(inputPlanMatchesRuntime(plan, slot, window), true);
  assert.equal(inputPlanMatchesRuntime(plan, slot, 'unselected-window'), false);
  const wire = serializeInputPlan(plan);
  const restored = parseInputPlan(wire);
  assert.deepEqual(restored, { ...plan, javaSlotDirectory: '' });
  plans.push(wire);
}
assert.throws(() => resolveInputPlan(graphicsGameFacts([
  'org/lwjgl/lwjgl/lwjgl/2.9.4/lwjgl-2.9.4.jar', 'org/lwjgl/lwjgl-sdl/3.4.3/lwjgl-sdl-3.4.3.jar'], 'legacy'), '/leased'), /不兼容/);
assert.throws(() => resolveInputPlan(graphicsGameFacts([], 'unknown'), ''), /不兼容/);
for (const wire of plans) {
  for (const invalid of ['', wire + ';', wire + ';unknown=1', wire.replace('v=v1', 'v=v9'),
    wire.replace('binding=', 'unknown='), wire.replace('abi=', 'abi=unknown'), wire.replace('policy=', 'policy=unknown'),
    wire + ';abi=GLFW', 'x'.repeat(257)]) assert.equal(parseInputPlan(invalid), undefined, invalid);
}
console.log('PASS input plan: same manifest facts, four actual ABI/slot routes, strict wire and L2+GLFW identity');

// 执行完整Builder.build的真实装配/参数发布。这里只替换版本读取、ZIP IO和图形
// 提供者选择边界，输入决议/两契约对账/用户参数合并仍执行生产实现。
let libraries = [];
let parses = 0;
let graphicsWindowOverride = '';
let versionJvmArgs = ['-Xlog:gc=off'];
let diagnosticDirectoryWrites = 0;
class Logger { info() {} warn() {} error() {} debug() {} id() { return 0; } }
const builderLoad = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo: {
    mkdirSync: () => { diagnosticDirectoryWrites++; }, statSync: () => ({ size: 0 }),
  } },
  feature_core: { VersionParser: { parse: () => { parses++; return {
    mainClass: 'net.minecraft.client.main.Main', type: 'release', libraries: [...libraries],
    jvmArgs: [...versionJvmArgs], gameArgs: [], assetIndex: 'fixture', inheritsFrom: '',
  }; } }, parseLibraryPathGav: () => null },
  commons: { ActivityLogger: Logger, DiagnosticPolicy: { isDeveloperBuild: () => false }, isMcVersionAtLeast: () => false },
  account: {}, mods: { resolveInstalledMcVersion: () => '1.20.4', resolveInstalledLoader: () => 'vanilla' },
  './LaunchNativeBridge': { launchNative: () => ({ getCommonJvmArgs: () => ['-XX:-UseCompressedOops'] }) },
  './GameCompatibility': { applyGameCompatibility: arguments_ => arguments_ },
  './GraphicsBackendPlan': { VulkanPolicy: { ALLOW: 'ALLOW' }, resolveGraphicsPlan: input => ({
    lwjglSlot: input.lwjglVersion === 2 ? 'LWJGL2' : (input.needsLwjgl322Slot ? 'LWJGL322' : 'LWJGL3'),
    windowProvider: graphicsWindowOverride || (input.usesSdl3 ? 'SDL3' : 'GLFW'), apiFamily: 'OPENGL',
    legacyGlBackendMarker: '', decision: { backendId: 'mobileglues', logLine: 'graph fixture' },
  }), serializeGraphicsPlan: () => 'graph-fixture' },
});
const { LaunchProfileBuilder } = builderLoad('launch/src/main/ets/LaunchProfileBuilder.ets');
function build(custom = '') {
  parses = 0;
  const builder = new LaunchProfileBuilder().setFilesDir('/files').setMcDir('/mc').setGameDir('/game')
    .setVersion('renamed-instance').setJdkVersion('17').setCustomJvmArgs(custom);
  builder.buildClasspath = () => ({ classpath: '/mc/client.jar', jars: ['/mc/client.jar'], missingJars: [] });
  builder.validateAllJarsZipHeader = () => [];
  return { builder, profile: builder.build() };
}
for (const [library, abi] of [
  ['org/lwjgl/lwjgl/lwjgl/2.9.4/lwjgl-2.9.4.jar', InputAbi.LWJGL2],
  ['org/lwjgl/lwjgl/3.2.2/lwjgl-3.2.2.jar', InputAbi.GLFW],
  ['org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar', InputAbi.GLFW],
  ['org/lwjgl/lwjgl-sdl/3.4.3/lwjgl-sdl-3.4.3.jar', InputAbi.SDL3],
]) {
  libraries = [library];
  const { profile, builder } = build();
  assert.ok(profile, builder.getLastBuildError());
  assert.equal(parses, 1, '两个子契约必须共享同次版本解析');
  assert.equal(profile.inputPlan.abi, abi);
  assert.equal(profile.inputPlan.javaSlotDirectory, profile.lwjglJarDir);
  assert.equal(profile.extraJvmArgs.includes('-Damcl.gpuWaitDiagnostics=true'), false,
    '任何窗口路线都不能默认安装GPU等待诊断');
  assert.deepEqual(profile.extraJvmArgs.filter(arg => arg.startsWith('-Damcl.input.plan=')),
    ['-Damcl.input.plan=' + profile.inputPlanWire]);
  const denied = build('-Damcl.input.plan=' + profile.inputPlanWire);
  assert.equal(denied.profile, null);
  assert.match(denied.builder.getLastBuildError(), /输入启动计划/);
}
// 用完整生产Builder证明默认静默且显式诊断仍可传递，文件Kit边界保留可计数反控。
// 原自动GC日志代码在这个可写目录下会产生mkdir及-Xlog参数，不能用IO故障假装静默。
versionJvmArgs = [];
libraries = ['org/lwjgl/lwjgl-sdl/3.4.3/lwjgl-sdl-3.4.3.jar'];
const quiet = build().profile;
assert.ok(quiet);
assert.equal(quiet.extraJvmArgs.some(arg => arg.startsWith('-Xlog:gc')), false);
assert.equal(diagnosticDirectoryWrites, 0);
const requestedDiagnostics = ['-Damcl.gpuWaitDiagnostics=true', '-Damcl.graphics.observation=1',
  '-Damcl.log.mirror=1', '-Damcl.audio.diagnostics=1', '-Xlog:gc=off'];
const explicit = build(requestedDiagnostics.join(' ')).profile;
assert.ok(explicit);
for (const argument of requestedDiagnostics) assert.ok(explicit.extraJvmArgs.includes(argument), argument);
assert.equal(diagnosticDirectoryWrites, 0);
console.log('PASS production Builder diagnostics: silent defaults, zero directory IO, explicit arguments preserved');

graphicsWindowOverride = 'unselected-window';
const conflict = build();
assert.equal(conflict.profile, null);
assert.match(conflict.builder.getLastBuildError(), /不一致/);
console.log('PASS production Builder: one parse, selected leased slot, one owned marker, user override and cross-contract conflict rejected');

// 新父进程schema3票据必须保留版本/计划版本；错Want不能在安装设置/布局前越过核验。
for (const change of [ticket => { ticket.version = 'other-instance'; },
  ticket => { ticket.inputPlanSchema = 'v999'; }, ticket => { delete ticket.inputPlanSchema; }]) {
  const f = fixture();
  try {
    const ref = await f.owner.snapshot.prepare(f.disk.context, 100, '1.16.5', f.activity);
    const path = f.disk.directory + '/desktop-launch/' + ref.id + '.json';
    const ticket = JSON.parse(fs.readFileSync(path, 'utf8'));
    assert.equal(ticket.schema, 3);
    assert.equal(ticket.version, '1.16.5');
    assert.equal(ticket.inputPlanSchema, INPUT_PLAN_SCHEMA);
    change(ticket); fs.writeFileSync(path, JSON.stringify(ticket));
    f.state.lock = 1;
    assert.throws(() => f.child.snapshot.consume(f.disk.context, ref.id, ref.account, 100, f.activity, 200, '1.16.5'), /mismatched/);
    assert.equal(f.child.process.isGameProcess(), false, '核验失败不能提前安装跨进程设置');
    assert.equal(fs.existsSync(path), true, '拒绝保留原票据以供取证');
  } finally { f.disk.close(); }
}
{
  const f = fixture();
  try { await f.launchV2(); assert.equal(f.child.process.isGameProcess(), true); }
  finally { f.disk.close(); }
}
console.log('PASS private snapshot: schema3 version/contract mismatch rejected before side effects, valid launch retained');

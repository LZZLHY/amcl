/** 执行真实历史文件协议与canonical resolver；编码器/原子提交器来自生产，替身仅为OHOS系统API。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import compiler from './lib/ets-compiler.mjs';
const loadLaunch = makePureEtsLoader();
const registry = loadLaunch('launch/src/main/ets/GraphicsProfileRegistry.ets');
const { resolveGraphicsProfile: resolve } = loadLaunch('launch/src/main/ets/GraphicsProfileResolver.ets');
let nextDirectory = -1, failRename = false;
const directories = new Set();
const fileIo = {
  OpenMode: { CREATE: 64, WRITE_ONLY: 1, READ_ONLY: 0, TRUNC: 512 },
  accessSync: file => fs.existsSync(file), statSync: file => typeof file === 'number' ? fs.fstatSync(file) : fs.statSync(file),
  readTextSync: file => fs.readFileSync(file, 'utf8'),
  readSync: (fd, bytes, options) => fs.readSync(fd, Buffer.from(bytes), 0, options.length, options.offset),
  openSync(file, flags) {
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) { const fd = nextDirectory--; directories.add(fd); return { fd }; }
    return { fd: fs.openSync(file, flags === 577 ? 'w' : 'r') };
  },
  writeSync: (fd, bytes) => fs.writeSync(fd, Buffer.from(bytes).subarray(0, 29)),
  fsyncSync: fd => { if (!directories.has(fd)) fs.fsyncSync(fd); },
  closeSync: value => { const fd = value.fd ?? value; if (!directories.delete(fd)) fs.closeSync(fd); },
  unlinkSync: file => fs.unlinkSync(file),
  renameSync: (a, b) => { if (failRename) throw new Error('injected commit failure'); fs.renameSync(a, b); }
};
const ports = { launch: registry, '@kit.CoreFileKit': { fileIo }, '@kit.ArkTS': { util: {} },
  '@kit.BasicServicesKit': { zlib: {} }, '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => {
    const hash = createHash('sha256'); return { updateSync: v => hash.update(v.data), digestSync: () => ({ data: hash.digest() }) };
  } } } };
const commonLoad = makePureEtsLoader(ports);
const commons = { ...commonLoad('commons/src/main/ets/utils/Base64Util.ets'), ...commonLoad('commons/src/main/ets/utils/EvidenceIo.ets') };
const load = makePureEtsLoader({ ...ports, commons });
const { GraphicsHistoryStore: history, graphicsHistoryOutcomePermitted: permitted } = load('entry/src/main/ets/runtime/GraphicsHistoryStore.ets');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'amcl-graphics-history-'));
fs.mkdirSync(path.join(root, 'graphics-recovery'));
const scope = 'a'.repeat(64), changed = 'b'.repeat(64), day = 86400000;
const id = '01234567-89ab-cdef-0123-456789abcdef';
const ticket = { id, parentPid: 21, activityId: 100, createdAt: 1000, diagnosticInjected: false };
const outcome = { id, parentPid: 21, childPid: 22, activityId: 100, createdAt: 2000,
  scopeHash: scope, profile: 'mobilegl', status: 'presented', stage: '', code: '', presentCount: 300,
  automatic: true, diagnosticInjected: false };
try {
  history.report(root, outcome); assert.deepEqual(history.outcome(root, id), outcome);
  assert.equal(history.learn(root, ticket, outcome, 21, id, 2100), true);
  assert.equal(history.learn(root, ticket, outcome, 21, id, 2100), false, '同一局不能重复学习');
  assert.equal(history.hints(root, changed, 2100).length, 0, '任何scope变化必须失效');
  assert.equal(history.hints(root, scope, 2100)[0].priority, 1);
  assert.equal(history.hints(root, scope, 2000 + day)[0].priority, 0, '成功优先权到期后回到静态排序');
  for (const override of [{ automatic: false }, { diagnosticInjected: true }, { scopeHash: 'invalid' },
    { childPid: 21 }, { parentPid: 23 }, { status: 'game-crashed' }, { presentCount: 299 }, { createdAt: 2101 },
    { profile: 'minecraft-vulkan' }, { profile: 'zink' }, { profile: 'unknown' }]) {
    assert.equal(permitted(ticket, { ...outcome, ...override }, 21, id, 2100), false, JSON.stringify(override));
  }
  assert.equal(permitted({ ...ticket, diagnosticInjected: true }, outcome, 21, id, 2100), false, '注入链的真实fallback成功也不能训练');
  assert.equal(permitted(ticket, outcome, 21, 'other', 2100), false);
  for (let i = 1; i <= 2; i++) {
    const failure = { ...outcome, activityId: 100 + i, createdAt: 2000 + i * 1000, status: 'startup-failed',
      stage: 'admission', code: 'vulkan_capability_rejected', presentCount: 0 };
    assert.equal(history.learn(root, { ...ticket, activityId: failure.activityId }, failure, 21, id, failure.createdAt), true);
  }
  assert.equal(history.hints(root, scope, 4000)[0].priority, -1);
  assert.equal(history.hints(root, scope, 4000 + day).length, 0, '隔离到期强制重评，不能被fallback成功永久压住');
  const fallback = { ...outcome, profile: 'mobileglues', activityId: 104, createdAt: 5000 };
  assert.equal(history.learn(root, { ...ticket, activityId: 104 }, fallback, 21, id, 5000), true);
  const capability = { evidenceProfileId: 'mobilegl', requirementId: 'mobilegl-direct-vulkan-v1', windowProvider: 'GLFW',
    loader: 'YES', instance: 'YES', windowSurface: 'YES', physicalDevice: 'YES', apiVersion: '1.3',
    deviceExtensions: 'YES', featureBits: 'YES', queuePresentation: 'YES', shaderToolchain: 'YES', nativeArtifacts: 'YES', lifecycleSmoke: 'NOT_RUN' };
  const input = { realMcVersion: '26.2', lwjglVersion: 3, needsLwjgl322Slot: false, usesSdl3: false,
    gameApi: 'OPENGL', userPreferredBackendId: 'auto', graphicsProfilePreference: 'auto', graphicsProfileExplicit: false,
    platformFamily: 'MOBILE', availableProfileIds: ['mobilegl', 'mobileglues'], capabilityResults: [capability],
    graphicsHistoryScope: scope, graphicsHistory: history.hints(root, scope, 5000) };
  assert.equal(resolve(input).decision.backendId, 'mobileglues', '真实resolver消费本scope记录');
  assert.equal(resolve({ ...input, graphicsHistoryScope: changed }).decision.backendId, 'mobilegl', '错身份提示不能重排');
  assert.equal(resolve({ ...input, graphicsProfilePreference: 'mobilegl', graphicsProfileExplicit: true }).decision.backendId, 'mobilegl');
  assert.equal(resolve({ ...input, graphicsRecoveryProfile: 'mobilegl' }).decision.backendId, 'mobilegl', '冷重试锁定优先于历史');
  assert.equal(resolve({ ...input, availableProfileIds: ['mobilegl'] }).decision.backendId, 'mobilegl', '历史不绕过缺资产准入');
  assert.equal(history.hints(root, scope, 5000 + 8 * day).length, 0);
  const before = fs.readFileSync(path.join(root, 'graphics-history.json'));
  failRename = true;
  assert.throws(() => history.learn(root, { ...ticket, activityId: 105 }, { ...fallback, activityId: 105, createdAt: 6000 }, 21, id, 6000), /保存失败/);
  failRename = false; assert.deepEqual(fs.readFileSync(path.join(root, 'graphics-history.json')), before);
  fs.writeFileSync(path.join(root, 'graphics-history.json'), '{broken');
  assert.deepEqual(history.hints(root, scope, 5000), []);
  fs.writeFileSync(path.join(root, 'graphics-recovery', id + '.outcome.json'), JSON.stringify({ ...outcome, schema: 1, childPid: '22' }));
  assert.equal(history.outcome(root, id), undefined);

  // 真实Scope工厂读取真实临时库字节、生产SHA256与偏好解析结果；设备/API只替换系统边界。
  const bundle = path.join(root, 'bundle'); fs.mkdirSync(path.join(bundle, 'libs', 'arm64'), { recursive: true });
  const libraries = ['libentry.so', 'libamcl_graphics_runtime.so', 'libamcl_gl_host.so', 'libmobilegl.so', 'libgl4es.so', 'libglfw.so', 'libSDL3.so', 'liblwjgl.so'];
  for (const library of libraries) fs.writeFileSync(path.join(bundle, 'libs', 'arm64', library), library);
  const manifestPath = path.join(root, 'game.json'); fs.writeFileSync(manifestPath, '{"id":"26.2","loader":"fixture"}');
  const device = { productModel: 'fixture-gpu', osFullName: 'fixture-os-1', sdkApiVersion: 26 };
  const makeScope = () => makePureEtsLoader({ ...ports, commons, '@ohos.deviceInfo': { default: device },
    feature_system: { PreferenceManager: class { resolveLaunch() { return { heap: 3840, args: ['-Dtest=1'] }; } } }
  })('entry/src/main/ets/runtime/GraphicsHistoryScope.ets').attachGraphicsHistory;
  const context = { bundleCodeDir: bundle, filesDir: root, resourceManager: { getRawFileContentSync: () => Buffer.from('actual-java-fixture-bytes') } };
  const scopeInput = () => ({ realMcVersion: '26.2', usesSdl3: false, gameApi: 'OPENGL', graphicsProfilePreference: 'auto',
    graphicsProfileExplicit: false, capabilityResults: [{ evidenceProfileId: 'mobilegl', driverIdentity: '1:2:3:' + 'a'.repeat(32) }] });
  const captureScope = (input = scopeInput()) => { makeScope()(context, input, manifestPath, 'renamed-instance'); return input.graphicsHistoryScope; };
  const originalScope = captureScope(); assert.match(originalScope, /^[0-9a-f]{64}$/);
  assert.equal(captureScope({ ...scopeInput(), surfaceGeneration: 99 }), originalScope, '窗口事实不缓存');
  assert.notEqual(captureScope({ ...scopeInput(), usesSdl3: true }), originalScope);
  assert.notEqual(captureScope({ ...scopeInput(), realMcVersion: '26.3' }), originalScope);
  assert.notEqual(captureScope({ ...scopeInput(), capabilityResults: [{ evidenceProfileId: 'mobilegl', driverIdentity: '1:2:4:' + 'a'.repeat(32) }] }), originalScope);
  device.osFullName = 'fixture-os-2'; assert.notEqual(captureScope(), originalScope); device.osFullName = 'fixture-os-1';
  fs.appendFileSync(path.join(bundle, 'libs', 'arm64', 'libmobilegl.so'), 'new-build'); assert.notEqual(captureScope(), originalScope);
  assert.equal(captureScope({ ...scopeInput(), graphicsProfilePreference: 'mobilegl', graphicsProfileExplicit: true }), undefined);

  // 抽取真实父进程消费方法，验证只有旧PID及OS锁都结束后才写历史。没有failure回执时不重试。
  const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  const start = source.indexOf('  private async recoverGraphics_('); const end = source.indexOf('\n  }', start) + 4;
  const code = compiler.transpileModule('class Parent {\n' + source.slice(start, end) + '\n}\nmodule.exports=Parent;',
    { compilerOptions: { target: compiler.ScriptTarget.ES2020 } }).outputText;
  const policy = load('entry/src/main/ets/runtime/GraphicsRecoveryPolicy.ets');
  for (const alive of [1, 0]) {
    const directory = path.join(root, 'parent-' + alive); fs.mkdirSync(path.join(directory, 'graphics-recovery'), { recursive: true });
    history.report(directory, outcome); let now = 3000;
    const dependencies = { ...policy, Date: { now: () => now }, setTimeout: fn => { now += 100; fn(); },
      GraphicsHistoryStore: history, GraphicsRecoveryStore: { ticket: () => ticket, failure: () => undefined },
      testNapi: { desktopProcessId: () => 21, desktopGameProcessState: () => alive, desktopProcessAlive: () => alive },
      AppLogger: { info() {}, warn() {} }, TAG: 'fixture', LOG_DOMAIN_LAUNCH: 1 };
    const module = { exports: {} }; new Function('module', ...Object.keys(dependencies), code)(module, ...Object.values(dependencies));
    const parent = new module.exports(); Object.assign(parent, { pendingGraphicsRecoveryId_: id, graphicsRecoveryPolling_: false, context: { filesDir: directory } });
    await parent.recoverGraphics_();
    assert.equal(fs.existsSync(path.join(directory, 'graphics-history.json')), !alive, '真实父路径必须等子进程结束');
  }
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log('Graphics history PASS: production encoding/atomic files, identity/expiry/diagnostic gates, repeat failures, canonical AUTO ordering, explicit/retry/admission preservation');

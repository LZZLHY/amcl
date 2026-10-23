#!/usr/bin/env node
/**
 * check-env-mutation.mjs 的自测（I27-05）。三层：
 *   1. 扫描器单元夹具：注释/字符串/声明不算调用，#ifdef 之后的调用照样识别，函数归属带 namespace/类名，
 *      转发包装的调用点被追踪，补丁只数新增行；
 *   2. 纯判定夹具：unlisted / stale / count-mismatch / invalid-entry / slot-name / retired-name / 通配；
 *   3. 生产变异：只在内存里改写真实源码的一处，要求门禁以指定种类失败——每个变异先断言锚点唯一命中，
 *      找不到旧锚点就报错，避免“无效变异”被当成通过。另以空清单跑真实树，证明扫描器确实看得见调用点。
 * 不写任何文件、不编译、不访问设备。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import {
  ALLOWLIST, MUTATION_CALLS, ORDER_PINS, canonicalName, evaluate, runGate, scanPatch, scanSource,
} from './check-env-mutation.mjs';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const cache = new Map();
const readReal = (rel) => {
  if (!cache.has(rel)) cache.set(rel, fs.readFileSync(path.join(ROOT, rel), 'utf8'));
  return cache.get(rel);
};
let checks = 0;
const kinds = (result) => new Set(result.problems.map((p) => p.kind));

// ---------------- 1. 扫描器单元夹具 ----------------
{
  const text = [
    '// setenv("IN_COMMENT", "1", 1);',
    '/* unsetenv("IN_BLOCK"); */',
    'int setenv(const char*, const char*, int);',
    'extern "C" int putenv(char*);',
    'static void log() { printf("setenv(MG_DIR_PATH) failed"); }',
    'void plain() { setenv("PLAIN", "1", 1); }',
    'void guarded() {',
    '#ifdef _WIN32',
    '    _putenv_s("GUARDED", "1");',
    '#else',
    '    setenv("GUARDED", "1", 1);',
    '#endif',
    '}',
    'namespace a::b { void g() { unsetenv("Y"); } }',
    'struct S { void m() { ::setenv("Z", "1", 1); } };',
    'static void publishEnv(const char* n, const char* v) { setenv(n, v, 1); }',
    'void h() { publishEnv("W", "1"); }',
  ].join('\n');
  const { sites, balanced } = scanSource(text, { wrappers: ['publishEnv'] });
  const got = sites.map((s) => `${s.function}|${s.call}|${s.name}`);
  assert.equal(balanced, true);
  assert.deepEqual(got, [
    'plain|setenv|"PLAIN"',
    'guarded|_putenv_s|"GUARDED"',
    'guarded|setenv|"GUARDED"',
    'a::b::g|unsetenv|"Y"',
    'S::m|setenv|"Z"',
    'publishEnv|setenv|n',
    'h|publishEnv|"W"',
  ], 'scanner fixture: comments/strings/declarations ignored, #ifdef-adjacent call kept, scopes qualified, wrapper tracked');
  checks++;
}
{
  const patch = [
    'diff --git a/src/x.c b/src/x.c',
    '--- a/src/x.c',
    '+++ b/src/x.c',
    '@@ -1,4 +1,5 @@ static void OldContext(void)',
    ' static void Existing(void)',
    ' {',
    '-    SDL_setenv_unsafe("REMOVED", "1", 1);',
    '+    SDL_setenv_unsafe("ADDED", "1", 1);',
    '+    SDL_unsetenv_unsafe("ADDED_TOO");',
    '     SDL_setenv_unsafe("CONTEXT", "1", 1);',
    ' }',
  ].join('\n');
  const sites = scanPatch(patch).map((s) => `${s.target}|${s.function}|${s.call}|${s.name}`);
  assert.deepEqual(sites, ['src/x.c|Existing|SDL_setenv_unsafe|"ADDED"', 'src/x.c|Existing|SDL_unsetenv_unsafe|"ADDED_TOO"'],
    'patch fixture: only added lines count; function comes from the nearest definition line');
  checks++;
}
assert.equal(canonicalName('"AMCL_WINDOW_FOREGROUND"'), 'AMCL_WINDOW_FOREGROUND');
assert.equal(canonicalName('amcl::envslot::kWindowWidthEnv'), 'AMCL_WINDOW_WIDTH');
assert.equal(canonicalName('AMCL_CALLBACK_BRIDGE_HOST_ENV'), 'AMCL_CALLBACK_BRIDGE_HOST_V1');
assert.equal(canonicalName('entry.name'), null);
assert.equal(canonicalName('amcl::envslot::kCursorModePlaceholderEnv'), 'AMCL_CURSOR_MODE');
checks++;

// ---------------- 2. 纯判定夹具 ----------------
const site = (over) => ({ file: 'entry/src/main/cpp/x.cpp', function: 'f', call: 'setenv', name: '"A"', line: 1, ...over });
const entry = (over) => ({ file: 'entry/src/main/cpp/x.cpp', function: 'f', call: 'setenv', name: '"A"', phase: 'pre-thread',
  why: 'fixture: runs before any thread', ...over });
function expectKinds(name, sites, allowlist, expected) {
  const result = evaluate(sites, allowlist);
  const got = kinds(result);
  for (const kind of expected) assert.ok(got.has(kind), `${name}: expected ${kind}, got ${[...got].join(',') || 'none'}`);
  if (!expected.length) assert.equal(result.ok, true, `${name}: ${result.problems.map((p) => p.detail).join('; ')}`);
  checks++;
}
expectKinds('listed site passes', [site()], [entry()], []);
expectKinds('unlisted site fails', [site(), site({ name: '"B"' })], [entry()], ['unlisted']);
expectKinds('stale entry fails', [], [entry()], ['stale']);
expectKinds('count mismatch fails', [site(), site({ line: 2 })], [entry()], ['count-mismatch']);
expectKinds('moved to another function fails twice', [site({ function: 'g' })], [entry()], ['unlisted', 'stale']);
expectKinds('wildcard absorbs remaining names', [site(), site({ name: 'x' }), site({ name: '"C"' })],
  [entry(), entry({ name: '*', count: 2 })], []);
expectKinds('wildcard count enforced', [site({ name: 'x' }), site({ name: '"C"' })], [entry({ name: '*', count: 1 })], ['count-mismatch']);
expectKinds('unknown phase rejected', [site()], [entry({ phase: 'diagnostic-probe' })], ['invalid-entry']);
expectKinds('missing why rejected', [site()], [entry({ why: 'short' })], ['invalid-entry']);
expectKinds('pending outside prebuilt rejected', [site()], [entry({ phase: 'pending-prebuilt-rebuild' })], ['invalid-entry']);
expectKinds('slot-registry outside env_slot.h rejected', [site()], [entry({ phase: 'slot-registry' })], ['invalid-entry']);
expectKinds('duplicate entry rejected', [site()], [entry(), entry()], ['invalid-entry']);
expectKinds('slot name cannot be allowlisted in first-party code', [site({ name: 'amcl::envslot::kWindowForegroundEnv' })],
  [entry({ name: 'amcl::envslot::kWindowForegroundEnv' })], ['slot-name']);
expectKinds('retired name cannot be allowlisted in first-party code', [site({ name: '"AMCL_CURSOR_MODE"' })],
  [entry({ name: '"AMCL_CURSOR_MODE"' })], ['retired-name']);
expectKinds('retired placeholder constant cannot be written raw', [site({ name: 'amcl::envslot::kCursorModePlaceholderEnv' })],
  [entry({ name: 'amcl::envslot::kCursorModePlaceholderEnv' })], ['retired-name']);
expectKinds('prebuilt pending slot writer is allowed', [site({ file: 'prebuilt/sdl3/patches/p.patch', target: 's.c', name: '"AMCL_RENDERER_REQUIRES_PROCESS_RESTART"' })],
  [entry({ file: 'prebuilt/sdl3/patches/p.patch', target: 's.c', name: '"AMCL_RENDERER_REQUIRES_PROCESS_RESTART"', phase: 'pending-prebuilt-rebuild' })], []);

// ---------------- 3. 真实树与生产变异 ----------------
const baseline = runGate({ read: readReal });
assert.equal(baseline.ok, true, baseline.problems.map((p) => `[${p.kind}] ${p.detail}`).join('\n'));
const phases = new Set(ALLOWLIST.map((e) => e.phase));
assert.deepEqual([...phases].sort(), ['pending-prebuilt-rebuild', 'pre-thread', 'slot-registry']);
assert.ok(baseline.sites.length > 50, 'real tree positive control: the scanner must see the known call sites');
checks++;
// 负对照：空清单下真实树必须大面积失败——证明“通过”来自清单核对，而不是什么都没扫到。
// 空清单不声明任何转发包装，所以对照数只计直接的环境原语调用点。
const empty = runGate({ read: readReal, allowlist: [] });
const directSites = baseline.sites.filter((s) => MUTATION_CALLS.includes(s.call)).length;
assert.ok(!empty.ok && empty.problems.filter((p) => p.kind === 'unlisted').length === directSites,
  'empty allowlist must report every real direct call site as unlisted');
checks++;

let mutations = 0;
function mutate(name, file, oldText, newText, expected) {
  const original = readReal(file);
  const index = original.indexOf(oldText);
  assert.ok(index >= 0 && original.indexOf(oldText, index + 1) < 0, `${name}: mutation anchor must match exactly once in ${file}`);
  const changed = original.replace(oldText, newText);
  const result = runGate({ read: (rel) => (rel === file ? changed : readReal(rel)) });
  const got = kinds(result);
  assert.equal(result.ok, false, `${name}: gate should fail`);
  for (const kind of expected) {
    assert.ok(got.has(kind), `${name}: expected [${kind}], got ${result.problems.map((p) => `[${p.kind}] ${p.detail}`).join(' | ')}`);
  }
  mutations++;
}
mutate('cursor-mode env mirror returns on the game thread', 'entry/src/main/cpp/glfw/glfw_callbacks.cpp',
  '        inputBridge_setGrabState(value == GLFW_CURSOR_DISABLED);',
  '        setenv("AMCL_CURSOR_MODE", value == GLFW_CURSOR_DISABLED ? "grabbed" : "normal", 1);\n        inputBridge_setGrabState(value == GLFW_CURSOR_DISABLED);',
  ['retired-name', 'unlisted']);
mutate('AMCL_GRAB_CB setenv moves back into onGrabChange', 'entry/src/main/cpp/napi/napi_input.cpp',
  '        napi_create_string_utf8(env, "GrabChange", NAPI_AUTO_LENGTH, &name);',
  '        setenv("AMCL_GRAB_CB", "1", 1);\n        napi_create_string_utf8(env, "GrabChange", NAPI_AUTO_LENGTH, &name);',
  ['unlisted']);
mutate('grab callback no longer published at module init', 'entry/src/main/cpp/napi/napi_input.cpp',
  '    std::call_once(g_grabTrampolinePublished, PublishGrabChangeTrampolineOnce);', '', ['order-pin']);
mutate('Vulkan WSI restart marker falls back to setenv via the wrapper', 'entry/src/main/cpp/platform/vulkan_wsi.cpp',
  '        const int restartStatus = amcl::envslot::RequestRendererRestart();',
  '        publishEnv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1");\n        const int restartStatus = 0;',
  ['slot-name', 'unlisted']);
mutate('surface destroy unsets the width slot again', 'entry/src/main/cpp/platform/xcomponent.cpp',
  '    AMCL_LOG_I(LOG_TAG, "Surface snapshot cleared generation=%{public}llu",',
  '    unsetenv(amcl::envslot::kWindowWidthEnv);\n    AMCL_LOG_I(LOG_TAG, "Surface snapshot cleared generation=%{public}llu",',
  ['slot-name', 'unlisted']);
mutate('launch env write moved after the JVM', 'entry/src/main/cpp/jvm/mc_launcher.cpp',
  '    g_mcThread = std::thread(mcLaunchThreadWithProfile,',
  '    setenv("AMCL_GAME_DIR", gameDirStr.c_str(), 1);\n    g_mcThread = std::thread(mcLaunchThreadWithProfile,',
  ['order', 'count-mismatch']);
// 新登记的诊断项也必须受同一启动顺序约束；即使名字在清单中，JVM 初始化
// 之后新增一次写入仍须同时触发顺序与数量错误，不能因补清单而放行运行期写者。
for (const name of ['AMCL_MC_LOG_MIRROR', 'AMCL_AUDIO_DIAGNOSTICS']) {
  mutate(`${name} cannot be rewritten after JVM initialization`, 'entry/src/main/cpp/jvm/mc_launcher.cpp',
    '    g_mcThread = std::thread(mcLaunchThreadWithProfile,',
    `    setenv("${name}", "1", 1);\n    g_mcThread = std::thread(mcLaunchThreadWithProfile,`,
    ['order', 'count-mismatch']);
}
{
  // 把认领处的封存挪到建 JVM 之后（两处替换，mutate 只做一处，所以单独写）。
  const file = 'entry/src/main/cpp/jvm/jvm_launcher.cpp';
  const original = readReal(file);
  const seal = '    amcl::ohos::SealProcessEnvironment(g_forkChildMode ? "fork-child-jvm-claim" : "jvm-create-claim");';
  assert.ok(original.includes(seal), 'seal anchor present');
  const changed = original.replace(seal, '').replace('    jint rc = createVM(&jvm, (void**)&env, &vm_args);',
    '    jint rc = createVM(&jvm, (void**)&env, &vm_args);\n    amcl::ohos::SealProcessEnvironment("late");');
  const result = runGate({ read: (rel) => (rel === file ? changed : readReal(rel)) });
  assert.ok(!result.ok && kinds(result).has('order-pin'), 'seal moved after createVM must break seal-at-jvm-claim');
  mutations++;
}
mutate('real OnSurfaceChanged republishes identical geometry again', 'entry/src/main/cpp/platform/xcomponent.cpp',
  '    if (amcl::ohos::SurfacePublicationUnchanged(current, next)) {', '    if (false) {', ['order-pin']);
mutate('module init no longer publishes first', 'entry/src/main/cpp/napi/napi_entry.cpp',
  '    amcl::ohos::PublishEarlyProcessEnvironment("module-init");', '', ['order-pin']);
// 新登记仍须绑定原一次发布分支；去掉真实调用或guard不能因名在白名单中就通过。
mutate('L2 keyboard descriptor loses the original publication call', 'entry/src/main/cpp/input/delivery/control_delivery.cpp',
  'published.store(true,std::memory_order_release);amclInputL2KeyboardPublishV1();',
  'published.store(true,std::memory_order_release);', ['order-pin']);
mutate('control publication loses its once guard', 'entry/src/main/cpp/input/delivery/control_delivery.cpp',
  'if(published.load(std::memory_order_acquire))return;', '', ['order-pin']);
// 新私有SDL尾表沿现有module-init发布，不能借登记在surface/present期间重写环境。
mutate('input descriptor loses once guard', 'entry/src/main/cpp/glfw/input_bridge_ohos.c',
  '    if (atomic_load_explicit(&g_bridgeAddressPublished, memory_order_acquire)) return;',
  '', ['order-pin']);
mutate('SDL touch descriptor republishes from live present', 'entry/src/main/cpp/glfw/input_bridge_ohos.c',
  'void inputBridge_sdlNotifyFramePresented(void) {',
  'void inputBridge_sdlNotifyFramePresented(void) {\n    setenv("AMCL_SDL_TOUCH_BRIDGE", "late", 1);', ['unlisted']);
mutate('graphics plan grows an unreviewed wrapper write', 'entry/src/main/cpp/platform/graphics_plan.cpp',
  '    writeEnvironment("AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN", nativeVulkanGranted ? "1" : "0");',
  '    writeEnvironment("AMCL_GRAPHICS_ALLOW_NATIVE_VULKAN", nativeVulkanGranted ? "1" : "0");\n    writeEnvironment("AMCL_GRAPHICS_EXTRA", "1");',
  ['count-mismatch']);
mutate('allowlisted launch write deleted', 'entry/src/main/cpp/jvm/mc_launcher.cpp',
  '        setenv("LIBGL_NOBANNER", "0", 1);', '', ['stale']);
mutate('SDL patch adds a new env writer', 'prebuilt/sdl3/patches/0012-openharmony-presentation-session.patch',
  '+    SDL_setenv_unsafe("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);',
  '+    SDL_setenv_unsafe("AMCL_WINDOW_FOREGROUND", "0", 1);', ['unlisted', 'stale']);
mutate('callback bridge revoke unsets its slot again', 'entry/src/main/cpp/jvm/jni_registry.cpp',
  'void revokeCallbackBridgeHostV1(void) {',
  'void revokeCallbackBridgeHostV1(void) {\n    unsetenv(AMCL_CALLBACK_BRIDGE_HOST_ENV);', ['slot-name', 'unlisted']);
mutate('GLFW restart marker falls back to setenv', 'entry/src/main/cpp/glfw/glfw_compat.cpp',
  '    requestRendererProcessRestart("egl-context-lost");',
  '    setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);', ['slot-name', 'unlisted']);
mutate('window host mirrors the snapshot into the environment again', 'entry/src/main/cpp/platform/window_host.cpp',
  '    publishEnv(kOwnerEnv, encoded);',
  '    publishEnv(kOwnerEnv, encoded);\n    publishEnv("AMCL_NATIVE_WINDOW_SNAPSHOT", encoded);', ['retired-name', 'unlisted']);
{
  // 正对照：同一文件只加注释与字符串里的“调用”，门禁必须仍然通过。
  const file = 'entry/src/main/cpp/glfw/glfw_callbacks.cpp';
  const changed = readReal(file).replace('        inputBridge_setGrabState(value == GLFW_CURSOR_DISABLED);',
    '        // setenv("AMCL_CURSOR_MODE", "grabbed", 1);\n        OH_LOG_INFO(LOG_APP, "setenv(AMCL_CURSOR_MODE) removed");\n        inputBridge_setGrabState(value == GLFW_CURSOR_DISABLED);');
  const result = runGate({ read: (rel) => (rel === file ? changed : readReal(rel)) });
  assert.equal(result.ok, true, result.problems.map((p) => p.detail).join('; '));
  checks++;
}
assert.ok(ORDER_PINS.length >= 5);
console.log(`[env-mutation self-test] PASS: ${checks} fixture checks, ${mutations} production mutations rejected, ` +
  `${baseline.sites.length} real call sites allowlisted across ${ALLOWLIST.length} entries`);

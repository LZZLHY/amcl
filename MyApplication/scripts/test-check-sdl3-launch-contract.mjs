#!/usr/bin/env node
/**
 * SDL 所有权门禁的变异回归：每例只破坏一条真实生产输入并要求具名失败。
 * 所有变异均在内存执行，不改设备/游戏/第三方源码；不依赖 javap 或宿主 C 编译器。
 */
import assert from 'node:assert/strict';
import { join } from 'node:path';
import {
  analyzeSdlLaunchSources, loadSdlLaunchSources, analyzeSdlBindingApis, locateJavap,
} from './check-sdl3-launch-contract.mjs';

const base = loadSdlLaunchSources();
const baseline = analyzeSdlLaunchSources(base);
assert.equal(baseline.ok, true, baseline.failures.join('\n'));
let controls = 0;

/** 校验变异确实命中当前实现；源码调整导致找不到旧锚时不能把无效测试当通过。 */
function reject(name, key, oldText, newText, expected) {
  assert.ok(base[key].includes(oldText), name + ': mutation target missing');
  const candidate = { ...base, [key]: base[key].replace(oldText, newText) };
  const result = analyzeSdlLaunchSources(candidate);
  assert.equal(result.ok, false, name + ': should fail');
  assert.ok(result.failures.includes(expected), name + ': wrong diagnostic ' + result.failures.join(', '));
  controls++;
}

reject('manifest detection disconnected', 'gameFacts', "value.indexOf('org/lwjgl/lwjgl-sdl/') >= 0",
  "value.indexOf('lwjgl-sdl.jar') >= 0", 'manifest-provider-input');
reject('classpath heuristic returns', 'source', 'static bool phase_publishPlatformRuntime(uint64_t session) {',
  'static bool phase_publishPlatformRuntime(uint64_t session) { if (strstr(classpath, "lwjgl-sdl.jar")) {}', 'no-classpath-sdl-heuristic');
reject('Java preload returns', 'source', 'static bool phase_publishPlatformRuntime(uint64_t session) {',
  'static bool phase_publishPlatformRuntime(uint64_t session) { env->FindClass("org/lwjgl/sdl/SDLMain");', 'no-host-java-platform-preload');
reject('native preload bypass', 'source', 'static bool phase_publishPlatformRuntime(uint64_t session) {',
  'static bool phase_publishPlatformRuntime(uint64_t session) { dlopen("libSDL3.so", 0);', 'publish-has-no-platform-loading');
reject('SDL init bypass', 'source', 'static bool phase_publishPlatformRuntime(uint64_t session) {',
  'static bool phase_publishPlatformRuntime(uint64_t session) { SDL_SetMainReady();', 'no-host-java-platform-preload');
reject('Vulkan receives GL hints', 'source', 'if (usesSdl3 && graphicsPlan.api == "OPENGL")',
  'if (usesSdl3)', 'opengl-only-provider-hints');
reject('SDL libname drift', 'bootstrap', '{"org.lwjgl.sdl.libname", "libSDL3.so"}',
  '{"org.lwjgl.sdl.libname", "libSDL3-copy.so"}', 'sdl-libname-frozen');
reject('freeze moved after JVM input', 'source', 'if (!amcl::jvm::FreezeBootstrapProperties(finalJvmArgs, g_runtimeBootstrapProperties, bootstrapError)) {',
  'jvmSetExtraArgsList(finalJvmArgs); if (!amcl::jvm::FreezeBootstrapProperties(finalJvmArgs, g_runtimeBootstrapProperties, bootstrapError)) {',
  'bootstrap-freeze-before-jvm');
reject('late property write', 'source', 'static bool phase_verifyRuntimeProperties(JNIEnv* env) {',
  'static bool phase_verifyRuntimeProperties(JNIEnv* env) { setSystemProperty(env, "org.lwjgl.sdl.libname", "libSDL3.so");',
  'bootstrap-readback-not-late-write');
reject('publish failure swallowed', 'source', 'if (!phase_publishPlatformRuntime(session))',
  'if (false)', 'publish-and-verify-fail-closed');
reject('property readback failure swallowed', 'source', 'if (!phase_verifyRuntimeProperties(env))',
  'if (false)', 'publish-and-verify-fail-closed');
reject('descriptor ABI drift', 'source', '"1:%llu:%llu:%llu"', '"2:%llu:%llu:%llu"', 'publish-exact-runtime-identity');
reject('descriptor overwritten', 'source', 'previous && std::strcmp(previous, descriptor) != 0',
  'false', 'publish-exact-runtime-identity');
reject('bridge publish bypass', 'source', 'publishCallbackBridgeHostV1(session) != JNI_OK',
  'false', 'bridge-descriptor-first');
reject('patch omitted from build recipe', 'series', '\n0013-openharmony-host-runtime-ownership.patch',
  '\n#0013-openharmony-host-runtime-ownership.patch', 'host-runtime-patch-active');
reject('main ready removed', 'patch', '+        SDL_SetMainReady();',
  '+        /* SDL_SetMainReady(); */', 'actual-instance-main-ready');
reject('init validation ignored', 'patch', '+    if (!SDL_AMCL_PrepareHostRuntime()) {',
  '+    if (false) {', 'main-ready-before-upstream-rejection');
reject('host ABI validation removed', 'patch', 'abi != 1', 'abi != 2', 'host-identity-validated-before-commit');
reject('host PID validation removed', 'patch', 'pid != current_pid', 'false', 'host-identity-validated-before-commit');
reject('host TID validation removed', 'patch', 'tid != current_tid', 'false', 'host-identity-validated-before-commit');
reject('release pump thread guard removed', 'patch', 'mode < 0 || SDL_GetCurrentThreadID() != SDL_MainThreadID',
  'mode < 0', 'release-pump-thread-identity');
reject('release pump error swallowed', 'patch', '+    if (!SDL_AMCL_ValidateEventThread(true)) {',
  '+    if (false) {', 'release-pump-guard-before-consumption');
reject('Wait/Poll still reads wrong-thread queue', 'patch', '+    if (!SDL_AMCL_ValidateEventThread(false)) {',
  '+    if (false) {', 'wait-poll-reject-before-queue');
reject('quit retirement removed', 'patch', '+    if (!SDL_AMCL_RetireHostRuntime()) {',
  '+    if (false) {', 'quit-retires-before-cleanup');
reject('video evidence collapsed', 'patch', 'phase=video-ready', 'phase=ready', 'readiness-evidence-separate');

// 错误示例放在注释中不应制造假失败；同理前面的新增锚删除后只留注释必须真失败。
assert.equal(analyzeSdlLaunchSources({ ...base,
  source: base.source + '\n/* env->FindClass("org/lwjgl/system/Library"); glfwInit(); */' }).ok, true);
assert.equal(analyzeSdlLaunchSources({ ...base, patch: undefined }).ok, false);

// JAR API 的描述符必须精确；错误返回值、参数或可见性不能因同名方法而通过。
const sdl = '  public static org.lwjgl.system.SharedLibrary getLibrary();';
const init = '  public static boolean SDL_Init(int);';
const glfw = '  public static boolean glfwInit();';
assert.equal(analyzeSdlBindingApis(sdl, init, glfw).ok, true);
assert.deepEqual(analyzeSdlBindingApis(sdl.replace('SharedLibrary', 'Object'), init, glfw).failures, ['SDL.getLibrary']);
assert.deepEqual(analyzeSdlBindingApis(sdl, init.replace('boolean', 'int'), glfw).failures, ['SDLInit.SDL_Init']);
assert.deepEqual(analyzeSdlBindingApis(sdl, init, glfw.replace('public', 'private')).failures, ['GLFW.glfwInit']);
assert.equal(locateJavap({ JAVA_HOME: '/fixture/jdk' }, () => true, 'win32'), join('/fixture/jdk', 'bin', 'javap.exe'));
assert.equal(locateJavap({ JAVA_HOME: '/fixture/jdk' }, () => true, 'linux'), join('/fixture/jdk', 'bin', 'javap'));
assert.equal(locateJavap({ JAVA_HOME: '/missing/jdk' }, () => false), 'javap');
assert.equal(locateJavap({}, () => { throw new Error('无 JAVA_HOME 不应检查文件'); }), 'javap');
console.log(`[sdl3-launch-contract self-test] PASS: ${baseline.passed.length} 源码命题、${controls} 生产变异、API 描述符及 JAVA_HOME/PATH 选择`);

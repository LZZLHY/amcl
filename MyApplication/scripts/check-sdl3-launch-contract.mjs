#!/usr/bin/env node
/**
 * SDL 启动所有权的源码/制品门禁。宿主只在 JVM 前冻结属性，在实际启动线程发布
 * 数值身份；不得为准备 SDL 而先加载一份 LWJGL。0013 补丁在实际使用的 SDL
 * 实例和允许线程完成 main-ready，事件泵和退出遵守同一身份。
 * 源码形状不等于真机通过：test-sdl3-host-runtime.mjs 执行初始化行为回归，设备
 * 仍须核对 main/events/video/pump 与持续呈现证据。本脚本不执行游戏或加载 JNI。
 */
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import { stripComments, stripStringLiterals } from './lib/source-noise.mjs';
import { hasBootstrapLibraryName } from './check-lwjgl-target-manifest.mjs';
import { parseSdl3PatchSeries } from './sdl3-patchset-digest.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PATCH = '0013-openharmony-host-runtime-ownership.patch';
const SOURCE_PATHS = {
  source: 'entry/src/main/cpp/jvm/mc_launcher.cpp',
  bootstrap: 'entry/src/main/cpp/jvm/runtime_bootstrap_contract.h',
  profile: 'launch/src/main/ets/LaunchProfileBuilder.ets',
  gameFacts: 'launch/src/main/ets/GraphicsGameFacts.ets',
  patch: 'prebuilt/sdl3/patches/' + PATCH,
  series: 'prebuilt/sdl3/patches/series',
};

/** 完整读取受检输入；负向测试只替换内存文本，不修改工作树或第三方仓库。 */
export function loadSdlLaunchSources(root = ROOT) {
  return Object.fromEntries(Object.entries(SOURCE_PATHS)
    .map(([key, path]) => [key, readFileSync(join(root, path), 'utf8')]));
}

/** 去掉注释并屏蔽字符串后按平衡括号取函数体，避免注释/日志伪造函数锚点。 */
function functionBody(text, name) {
  const code = stripComments(text, { lang: 'c' });
  const mask = stripStringLiterals(code, { lang: 'c' });
  const match = new RegExp(`\\b${name}\\s*\\([^;{}]*\\)\\s*\\{`).exec(mask);
  if (!match) throw new Error(`missing-function:${name}`);
  const start = match.index + match[0].length - 1;
  let depth = 1;
  let end = start + 1;
  while (end < mask.length && depth > 0) {
    if (mask[end] === '{') depth++;
    if (mask[end] === '}') depth--;
    end++;
  }
  if (depth) throw new Error(`unclosed-function:${name}`);
  return code.slice(start, end);
}

/** 检查同一函数内的消费顺序；任何缺失锚都失败，不允许负下标比较伪通过。 */
function ordered(text, needles) {
  let previous = -1;
  for (const needle of needles) {
    const index = text.indexOf(needle, previous + 1);
    if (index < 0 || index <= previous) return false;
    previous = index;
  }
  return true;
}

/**
 * 提取 unified diff 的最终新增/上下文片段，删除行不能满足门禁。
 * 完整补丁应用与编译另由 SDL 行为测试验证，本函数不伪造完整第三方源码。
 */
function patchedFragments(patch, path) {
  const block = patch.replace(/\r\n/g, '\n').split(/^diff --git /m)
    .find((part) => part.startsWith(`a/${path} b/${path}\n`));
  if (!block) throw new Error(`missing-patch-file:${path}`);
  return block.split('\n').filter((line) => (line.startsWith('+') && !line.startsWith('+++')) || line.startsWith(' '))
    .map((line) => line.slice(1)).join('\n');
}

/** 纯分析器以稳定失败 ID 报告独立命题，供真实源码变异测试验证门禁可失败性。 */
export function analyzeSdlLaunchSources(files) {
  const failures = [];
  const passed = [];
  const check = (name, condition) => (condition ? passed : failures).push(name);
  try {
    for (const key of Object.keys(SOURCE_PATHS)) {
      if (typeof files[key] !== 'string') throw new Error('missing-source:' + key);
    }
    const source = stripComments(files.source, { lang: 'c' });
    const profile = stripComments(files.profile, { lang: 'js' });
    const gameFacts = stripComments(files.gameFacts, { lang: 'js' });
    check('manifest-provider-input', gameFacts.includes("value.indexOf('org/lwjgl/lwjgl-sdl/') >= 0")
      && profile.includes('graphicsGameFacts(parsed.libraries,')
      && profile.includes('const usesSdl3: boolean = gameFacts.usesSdl3')
      && profile.includes("parsed.jvmArgs.push('-Damcl.sdl3=1')"));
    check('no-classpath-sdl-heuristic', !/\b(?:strstr\s*\(\s*classpath\s*,|classpath\s*\.\s*find\s*\()\s*"lwjgl-sdl\.jar"/.test(source));
    check('no-host-java-platform-preload', !/FindClass\s*\(\s*"(?:org\/lwjgl\/|org\/lwjglx\/)/.test(source)
      && !/\bphase_prepareSdl\s*\(/.test(source)
      && !/\b(?:glfwInit|SDL_SetMainReady)\s*\(/.test(source));
    const resolveDir = functionBody(source, 'resolveHapNativeDir');
    const launch = functionBody(source, 'launchWithProfileImpl');
    const thread = functionBody(source, 'mcLaunchThreadWithProfile');
    const publish = functionBody(source, 'phase_publishPlatformRuntime');
    const verify = functionBody(source, 'phase_verifyRuntimeProperties');
    check('absolute-native-fallback', resolveDir.includes('"/data/storage/el1/bundle/libs/arm64"'));
    check('structured-provider-authority', launch.includes('const bool usesSdl3 = graphicsPlan.window == "SDL3";')
      && launch.includes('legacySdl != (graphicsPlan.window == "SDL3")'));
    check('opengl-only-provider-hints', launch.includes('if (usesSdl3 && graphicsPlan.api == "OPENGL")')
      && launch.includes('amcl::renderer::FindBackendGlLibrary(sdlBackendId)')
      && launch.includes('const std::string glProviderPath = sdlBackend->systemLibrary ? sdlBackend->glLibName : hapNativeDir + "/" + sdlBackend->glLibName;'));
    check('provider-hints-before-jvm', ordered(launch, [
      'resolveHapNativeDir(filesDir)',
      'setenv("SDL_OPENGL_LIBRARY", glProviderPath.c_str(), 1)',
      'setenv("SDL_EGL_LIBRARY", sdlBackend->systemLibrary ? "libEGL.so" : glProviderPath.c_str(), 1)',
      'phase_initJvmWithClasspath(', 'std::thread(mcLaunchThreadWithProfile',
    ]));
    check('sdl-libname-frozen', hasBootstrapLibraryName(files.bootstrap, 'org.lwjgl.sdl.libname', 'libSDL3.so'));
    check('bootstrap-freeze-before-jvm', ordered(launch, [
      'amcl::jvm::RuntimeBootstrapProperties(', 'amcl::jvm::FreezeBootstrapProperties(',
      'jvmSetExtraArgsList(finalJvmArgs)', 'phase_initJvmWithClasspath(',
    ]) && launch.includes('if (!amcl::jvm::FreezeBootstrapProperties(finalJvmArgs, g_runtimeBootstrapProperties, bootstrapError)) {')
      && /return\s+-\d+;/.test(launch.slice(launch.indexOf('amcl::jvm::FreezeBootstrapProperties('),
        launch.indexOf('jvmSetExtraArgsList(finalJvmArgs)'))));
    check('bootstrap-readback-not-late-write', verify.includes('getSystemProperty(env, property.first.c_str()) != property.second')
      && verify.includes('return false;') && !/setSystemProperty\s*\(/.test(verify)
      && !/setSystemProperty\s*\([^;]*"org\.lwjgl\./.test(source));
    check('attached-thread-publish-before-owner', ordered(thread, [
      'AttachCurrentThread', 'phase_redirectIO(', 'phase_publishPlatformRuntime(',
      'phase_verifyRuntimeProperties(', 'phase_prepareJavaLaunch(', 'phase_launchMain(',
    ]));
    check('publish-and-verify-fail-closed', /if\s*\(!phase_publishPlatformRuntime\(session\)\)\s*goto cleanup;/.test(thread)
      && /if\s*\(!phase_verifyRuntimeProperties\(env\)\)\s*goto cleanup;/.test(thread));
    check('publish-has-no-platform-loading', !/\b(?:FindClass|dlopen|dlsym|glfwInit|SDL_SetMainReady)\s*\(/.test(publish));
    check('publish-exact-runtime-identity', publish.includes('"1:%llu:%llu:%llu"')
      && publish.includes('getpid()') && publish.includes('syscall(SYS_gettid)')
      && publish.includes('static_cast<unsigned long long>(session)')
      && ordered(publish, ['plan->window == "SDL3"', 'setenv("AMCL_SDL_HOST_RUNTIME", descriptor, 1)'])
      && publish.includes('previous && std::strcmp(previous, descriptor) != 0')
      && publish.includes('setenv("AMCL_SDL_HOST_RUNTIME", descriptor, 1) != 0'));
    check('bridge-descriptor-first', /if\s*\(publishCallbackBridgeHostV1\(session\)\s*!=\s*JNI_OK\)/.test(publish));

    check('host-runtime-patch-active', parseSdl3PatchSeries(files.series).includes(PATCH));
    const sdl = stripComments(patchedFragments(files.patch, 'src/SDL.c'), { lang: 'c' });
    const host = patchedFragments(files.patch, 'src/core/openharmony/SDL_amclhostruntime.h');
    const events = patchedFragments(files.patch, 'src/events/SDL_events.c');
    const prepare = functionBody(sdl, 'SDL_AMCL_PrepareHostRuntime');
    check('actual-instance-main-ready', ordered(prepare, [
      'SDL_LockSpinlock(&SDL_amclHostLock)', 'AMCL_SdlHostPrepare(&SDL_amclHostRuntime,',
      'SDL_MainThreadID != thread', 'SDL_SetMainReady();', 'SDL_UnlockSpinlock(&SDL_amclHostLock)',
    ]) && prepare.includes('SDL_getenv_unsafe("AMCL_SDL_HOST_RUNTIME"), pid, tid)')
      && prepare.includes('if (result == AMCL_SDL_HOST_FIRST)')
      && prepare.includes('return SDL_AMCL_HostError("prepare", result);')
      && !/\b(?:dlopen|dlsym|SDL_InitSubSystem)\s*\(/.test(prepare));
    check('main-ready-before-upstream-rejection', /if\s*\(!SDL_AMCL_PrepareHostRuntime\(\)\)\s*\{\s*return false;\s*\}\s*#endif\s*if\s*\(!SDL_MainIsReady\)/.test(sdl));
    const accept = functionBody(host, 'AMCL_SdlHostPrepare');
    check('host-identity-validated-before-commit', ordered(accept, [
      'abi != 1', 'pid != current_pid', 'tid != current_tid', 'runtime->state == 3',
      'runtime->session != session', 'runtime->pid = pid;',
    ]) && accept.includes('AMCL_SDL_HOST_STANDALONE') && accept.includes('AMCL_SDL_HOST_CHANGED'));
    const pump = functionBody(sdl, 'SDL_AMCL_ValidateEventThread');
    check('release-pump-thread-identity', pump.includes('mode < 0 || SDL_GetCurrentThreadID() != SDL_MainThreadID')
      && pump.includes('return SDL_AMCL_HostError("event-pump",')
      && pump.includes('SDL_EventsThreadID') && pump.includes('SDL_VideoThreadID'));
    // 事件函数片段只保留补丁提供的前半段；无需伪造函数闭合来取完整函数体。
    const eventCode = stripComments(events, { lang: 'c' });
    check('release-pump-guard-before-consumption', /if\s*\(!SDL_AMCL_ValidateEventThread\(true\)\)\s*\{\s*return;\s*\}/.test(eventCode)
      && ordered(eventCode, ['SDL_AMCL_ValidateEventThread(true)', 'SDL_assert(SDL_IsMainThread())']));
    check('wait-poll-reject-before-queue', /if\s*\(!SDL_AMCL_ValidateEventThread\(false\)\)\s*\{\s*return false;\s*\}/.test(eventCode)
      && ordered(eventCode, ['SDL_AMCL_ValidateEventThread(false)', 'if (timeoutNS > 0)']));
    check('quit-retires-before-cleanup', /if\s*\(!SDL_AMCL_RetireHostRuntime\(\)\)\s*\{\s*return;\s*\}\s*#endif\s*SDL_bInMainQuit = true;/.test(sdl));
    check('readiness-evidence-separate', sdl.includes('phase=main-ready') && sdl.includes('phase=events-ready')
      && sdl.includes('phase=video-ready') && sdl.includes('phase=event-pump'));
  } catch (error) {
    failures.push(error.message);
  }
  return { ok: failures.length === 0, passed, failures };
}

/** 优先用户指定 JDK；未配置或缺少 javap 才尝试 PATH，不硬编码构建机路径。 */
export function locateJavap(env = process.env, exists = existsSync, platform = process.platform) {
  if (env.JAVA_HOME) {
    const candidate = join(env.JAVA_HOME, 'bin', platform === 'win32' ? 'javap.exe' : 'javap');
    if (exists(candidate)) return candidate;
  }
  return 'javap';
}

/** SDL 的真实 Java 入口保持可用；GLFW 仅验旧游戏公共 API，不要求宿主调用它。 */
export function analyzeSdlBindingApis(sdlApi, initApi, glfwApi) {
  const failures = [];
  if (!/^\s*public static org\.lwjgl\.system\.SharedLibrary getLibrary\(\);\s*$/m.test(sdlApi)) failures.push('SDL.getLibrary');
  if (!/^\s*public static boolean SDL_Init\(int\);\s*$/m.test(initApi)) failures.push('SDLInit.SDL_Init');
  if (!/^\s*public static boolean glfwInit\(\);\s*$/m.test(glfwApi)) failures.push('GLFW.glfwInit');
  return { ok: failures.length === 0, failures };
}

/** CLI 才运行只读 javap 检查；导入纯分析器的负向测试不依赖 JDK 安装。 */
export function checkSdlBindingJars(root = ROOT) {
  const javap = locateJavap();
  const inspect = (jar, className) => {
    const path = join(root, 'prebuilt/lwjgl3/jars', jar);
    if (!existsSync(path)) throw new Error('required-binding-jar:' + path);
    const result = spawnSync(javap, ['-classpath', path, '-public', className], { cwd: root, encoding: 'utf8' });
    if (result.error || result.status !== 0) {
      throw new Error(`javap ${className}: ${result.error?.message || result.stderr || result.stdout}; configure JAVA_HOME or PATH`);
    }
    return result.stdout;
  };
  return analyzeSdlBindingApis(inspect('lwjgl-sdl.jar', 'org.lwjgl.sdl.SDL'),
    inspect('lwjgl-sdl.jar', 'org.lwjgl.sdl.SDLInit'), inspect('lwjgl-glfw.jar', 'org.lwjgl.glfw.GLFW'));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const report = analyzeSdlLaunchSources(loadSdlLaunchSources());
    const bindings = checkSdlBindingJars();
    for (const failure of [...report.failures, ...bindings.failures]) console.error('[sdl3-launch-contract] FAIL ' + failure);
    process.exitCode = report.ok && bindings.ok ? 0 : 1;
    if (process.exitCode === 0) console.log('[sdl3-launch-contract] PASS: pre-JVM properties, no host Java preloading, actual SDL instance/thread/retirement, shipping binding APIs');
  } catch (error) {
    console.error('[sdl3-launch-contract] FAIL ' + error.message);
    process.exitCode = 1;
  }
}

// Desktop service contract: source mirrors, actual HAP and native build inputs.
// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import { readFileSync, writeFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { resolve, join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { PRODUCT_ROOT, parseJson5 } from './product-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { computeSdl3PatchsetDigest, artifactEmbedsSdl3Patchset } from './sdl3-patchset-digest.mjs';
import { stripComments, stripStringLiterals } from './lib/source-noise.mjs';
import { graphicsBootstrapIssues } from './graphics-bootstrap-contract.mjs';

const normalize = s => s.replace(/\r\n/g, '\n');
export function addedFile(patch, path) {
  const section = normalize(patch).split(/^diff --git /m).find(s => s.startsWith(`a/${path} b/${path}\n`));
  if (!section || !section.includes('new file mode')) return '';
  return section.split('\n').filter(line => line.startsWith('+') && !line.startsWith('+++')).map(line => line.slice(1)).join('\n') + '\n';
}
export function evaluateMirror(header, patch) {
  return normalize(header) === addedFile(patch, 'src/video/openharmony/desktop_host_api.h') ? [] : ['SDL desktop ABI header differs from the canonical host header'];
}
export function evaluateEglDispatch(source, header) {
  const issues = [];
  if (!source.includes('#include "egl_dispatch.h"')) issues.push('GLFW EGL dispatch include missing');
  const names = new Set([...stripComments(source, 'cpp').matchAll(/\b(egl[A-Z]\w*)\s*\(/g)].map(m => m[1]));
  for (const name of names) if (!new RegExp(`^#define ${name}\\(`, 'm').test(header)) issues.push(`System EGL dispatch missing ${name}`);
  return issues;
}
function bodyAfter(source, signature) {
  const code = stripComments(source, 'cpp');
  const start = code.indexOf(signature);
  if (start < 0) return '';
  // 默认实参可以包含 JnaBootstrap{}；先越过完整形参括号，不能把实参初始化器
  // 当成函数体。用共享词法屏蔽字面量后匹配界符，仍返回原正文供契约判断。
  const delimiters = stripStringLiterals(code);
  const parameters = delimiters.indexOf('(', start);
  if (parameters < 0) return '';
  let parentheses = 1, afterParameters = parameters + 1;
  for (; afterParameters < delimiters.length && parentheses; afterParameters++) {
    if (delimiters[afterParameters] === '(') parentheses++;
    else if (delimiters[afterParameters] === ')') parentheses--;
  }
  if (parentheses) return '';
  const open = delimiters.indexOf('{', afterParameters);
  if (open < 0) return '';
  let depth = 1, end = open + 1;
  for (; end < delimiters.length && depth; end++) {
    if (delimiters[end] === '{') depth++;
    else if (delimiters[end] === '}') depth--;
  }
  if (depth) return '';
  return code.slice(open + 1, end - 1);
}
export function evaluateDesktopCompletionSources(callbacks, page, ability) {
  const issues = [];
  const poll = bodyAfter(callbacks, 'void pollDesktopWindow(');
  for (const [name, field, change] of [
    ['Position', 'positionCb', 'WindowMoved'], ['Iconify', 'iconifyCb', 'WindowIconified'],
    ['Maximize', 'maximizeCb', 'WindowMaximized'], ['ContentScale', 'contentScaleCb', 'WindowScaleChanged'],
    ['Refresh', 'refreshCb', 'WindowRefresh']
  ]) {
    const setter = `glfwSetWindow${name === 'Position' ? 'Pos' : name}Callback(`;
    const body = bodyAfter(callbacks, setter);
    if (!new RegExp(`window->${field}\\s*=\\s*callback`).test(body) || !body.includes(`old = window->${field}`) || !body.includes('return old')) issues.push(`${setter}: callback storage/previous value missing`);
    if (!poll.includes(change) || !new RegExp(`window->${field}\\s*\\(`).test(poll)) issues.push(`${field}: system state callback dispatch missing`);
  }
  const launch = bodyAfter(page, 'private async startMCOnce()');
  const prepare = launch.indexOf('await this.gameWindowCoordinator.enter(');
  const native = launch.indexOf('await this.startMCInternal()');
  if (prepare < 0 || native < prepare || !launch.includes('snapshot.contextGeneration <= 0') || !launch.includes('throw new Error')) issues.push('Desktop launch must require valid Window before launch preparation');
  if (!bodyAfter(page, 'private startMC()').includes('this.gameLaunchGate.run(')) issues.push('Page launch single-flight gate disconnected');
  for (const phase of ['onBackground()', 'onDestroy()']) if (!bodyAfter(ability, phase).includes('testNapi.desktopGamepadFocus(false)')) issues.push(`${phase}: native gamepad reset missing`);
  return issues;
}
/**
 * SystemOpenGL and Minecraft Vulkan are peer routes in the formal desktop
 * binary. Compile-time desktop identity may select the system provider for a
 * GL plan, but it must not force Vulkan through the GL resolver or allow an
 * unadmitted GLFW_NO_API window to be created.
 */
export function evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl, runtimeBootstrap) {
  const issues = [];
  const launch = stripComments(launcher, 'cpp');
  const glfw = stripComments(glfwCompat, 'cpp');
  const gl = stripComments(nativeGl, 'cpp');
  if (!gl.includes('if (api && strcmp(api, "VULKAN") == 0) return false;') ||
      !gl.includes('if (profile && strcmp(profile, "minecraft-vulkan") == 0) return false;')) {
    issues.push('NativeGlRequested must yield false for an active Minecraft Vulkan plan');
  }
  // 所有 profile 的库路径都必须在 JVM 前冻结；只有 SystemOpenGL 的 contextAPI=native
  // 是该 profile 专属。不能恢复旧 helper 擦除异值，也不能让 Vulkan/移动 GL 继承此属性。
  const bootstrap = bodyAfter(runtimeBootstrap || '', 'RuntimeBootstrapProperties(');
  const nativeContext = /if\s*\(profile\s*==\s*"nativegl"\)\s*result\.emplace_back\("org\.lwjgl\.opengl\.contextAPI",\s*"native"\);/;
  // 存在两次冻结：基础属性必须先于provider绑定，实际实现身份随后补齐。
  // 只查某处有同名调用会让“删掉前一次、仅剩后一次”的错误顺序通过。
  const firstFreeze = launch.indexOf('if (!amcl::jvm::FreezeBootstrapProperties(finalJvmArgs, g_runtimeBootstrapProperties, bootstrapError))');
  const providerBind = launch.indexOf('amclGraphicsBindRuntimeV1(');
  if (!nativeContext.test(bootstrap) || (bootstrap.match(/"org\.lwjgl\.opengl\.contextAPI"/g) || []).length !== 1
      || !launch.includes('amcl::jvm::RuntimeBootstrapProperties(')
      || firstFreeze < 0 || providerBind < 0 || firstFreeze > providerBind) {
    issues.push('Desktop LWJGL argument freezing must retain the nativegl-only contextAPI and consume the shared pre-JVM property contract');
  }
  if (!glfw.includes('const bool selectedVulkanPlan = selectedProfile &&') ||
      !glfw.includes('graphicsApi && strcmp(graphicsApi, "VULKAN") == 0') ||
      !glfw.includes('amclVulkanAdmissionGranted() == 1')) {
    issues.push('GLFW Vulkan peer route must require the structured Vulkan API/profile identity');
  }
  if (!glfw.includes('if (g_hintClientAPI == GLFW_NO_API && !admittedVulkanWindow)')) {
    issues.push('GLFW_NO_API must fail closed before NativeGlRequested-dependent checks');
  }
  return issues;
}
export function checkDesktopSources(root = PRODUCT_ROOT, sdlRepo = '') {
  const read = p => readFileSync(join(root, p), 'utf8');
  const header = read('entry/src/main/cpp/platform/desktop_host_api.h');
  const patch = read('prebuilt/sdl3/patches/0010-openharmony-desktop-services.patch');
  const issues = evaluateMirror(header, patch);
  if (normalize(read('entry/src/main/cpp/platform/desktop_drop_packet.h')) !== addedFile(patch, 'src/video/openharmony/desktop_drop_packet.h')) issues.push('SDL drop packet ABI mirror differs');
  for (const path of ['account/src/main/ets/AccountStorage.ets','feature_system/src/main/ets/PreferenceManager.ets','gamecontrol/src/main/ets/LayoutStore.ets']) {
    const code = stripComments(read(path), 'ts');
    if (!code.includes('ProcessPreferences.open(') || /preferences\.getPreferences(?:Sync)?\(/.test(code)) issues.push(`${path}: shared XML bypasses process snapshot ownership`);
  }
  const gameAbility = read('entry/src/main/ets/gameability/GameAbility.ets');
  const snapshotIndex = gameAbility.indexOf('DesktopLaunchSnapshot.consume(');
  // 初始化现在可携带 activityId/launchMeta；检查调用前缀而不是旧的无参字面量。
  const runtimeInitIndex = gameAbility.indexOf('initializeGameProcess(this.context');
  if (snapshotIndex < 0 || runtimeInitIndex < 0 || snapshotIndex > runtimeInitIndex) issues.push('Game snapshot must be installed before runtime initialization');
  const launchSnapshot = read('entry/src/main/ets/runtime/DesktopLaunchSnapshot.ets');
  if (!launchSnapshot.includes('captureOwner(') || !launchSnapshot.includes('installGameSnapshots(') ||
      !launchSnapshot.includes('fsyncSync') || !launchSnapshot.includes('static consume(')) {
    issues.push('Desktop launch snapshot must persist an atomic owner snapshot and install it in the game process');
  }
  const runtimePolicy = read('gamecontrol/src/main/ets/ProductRuntimePolicy.ets');
  const gamePage = read('entry/src/main/ets/pages/McGamePage.ets');
  const launcher = read('entry/src/main/cpp/jvm/mc_launcher.cpp');
  const glfwCompat = read('entry/src/main/cpp/glfw/glfw_compat.cpp');
  const nativeGl = read('entry/src/main/cpp/platform/native_gl.cpp');
  if (runtimePolicy.includes('static requiresNativeGl(') || gamePage.includes('ProductRuntimePolicy.requiresNativeGl(')
      || !gamePage.includes('prepareGraphicsProfileInput(')) {
    issues.push('Graphics admission must consume shared device/game/artifact facts');
  }
  if (/NativeGlRequired\(\)\s*&&\s*!nativeGl/.test(stripComments(launcher, 'cpp'))) {
    issues.push('Desktop launch must not reject an admitted Minecraft Vulkan profile in favor of nativegl');
  }
  if (!stripComments(launcher, 'cpp').includes('graphicsPlan.profile')) {
    issues.push('Desktop launch must use the immutable graphics plan profile for API routing');
  }
  issues.push(...evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl,
    read('entry/src/main/cpp/jvm/runtime_bootstrap_contract.h')));
  const cmake = read('entry/src/main/cpp/CMakeLists.txt');
  if (!cmake.includes('set(AMCL_GRAPHICS_ARTIFACT_SET "complete"') ||
      /set\(AMCL_NATIVE_DESKTOP_ONLY ON/.test(cmake)) {
    issues.push('All products must retain the complete graphics artifact set');
  }
  issues.push(...evaluateDesktopCompletionSources(read('entry/src/main/cpp/glfw/glfw_callbacks.cpp'),
    read('entry/src/main/ets/pages/McGamePage.ets'), read('entry/src/main/ets/gameability/GameAbility.ets')));
  issues.push(...evaluateEglDispatch(glfwCompat, read('entry/src/main/cpp/glfw/egl_dispatch.h')));
  // 生命周期适配器只允许消费冻结操作表；它已经不再直接调用EGL，不能要求重新引入
  // 旧宏派发层。真实swap/current调用仍由上面的完整EGL派发检查约束。
  const adapter = stripComments(read('entry/src/main/cpp/glfw/glfw_egl.cpp'), 'cpp');
  for (const operation of ['create', 'suspend', 'attach', 'destroy']) {
    if (!adapter.includes(`contextOperations->${operation}(`)) issues.push(`Neutral EGL operation missing: ${operation}`);
  }
  if (/\begl[A-Z]\w*\s*\(/.test(adapter)) issues.push('GLFW lifecycle adapter bypasses neutral operations');
  if (sdlRepo && normalize(header) !== normalize(readFileSync(join(sdlRepo, 'src/video/openharmony/desktop_host_api.h'), 'utf8'))) issues.push('Applied SDL source ABI mirror differs');
  const ability = parseJson5(read('entry/src/main/module.json5')).module.abilities.find(a => a.name === 'GameAbility');
  if (ability?.process !== ':game' || ability?.launchType !== 'singleton') issues.push('GameAbility private process declaration missing');
  for (const [path, needles] of [
    ['entry/src/main/ets/gameability/GameAbility.ets', ['desktopGameProcessState', 'initializeGameProcess']],
    ['entry/src/main/ets/window/DesktopSystemBridge.ets', ['desktopCompleteCommand', 'desktopPublishState', 'windowWillClose', 'moveWindowToGlobal', 'requestPermissionsFromUser', 'sdkApiVersion >= 26', 'getDefaultDisplaySync']],
    ['entry/src/main/cpp/glfw/glfw_callbacks.cpp', ['amclDesktopHostResolve', 'clipboardRead', 'clipboardWrite', 'gamepadRead']],
    // 完整探针主体移入可执行的共享核心，同时检查生产入口确实调用它，不能只查死头文件。
    ['entry/src/main/cpp/platform/native_gl.cpp', ['QueryGL', 'ProbeNativeGlContext(SystemEgl(), state.resources', 'SystemGraphicsBootstrapConfigured', 'libGLv4.so']],
    ['entry/src/main/cpp/platform/native_gl_probe_core.h', ['EGL_OPENGL_API', 'glReadPixels', 'cleanupFailure', 'resources.ownsCurrent']],
    ['entry/src/main/cpp/platform/desktop_event_signal.h', ['wait(', 'wake()']],
    ['entry/src/main/cpp/platform/desktop_drop_packet.h', ['amclDecodeDesktopDrop']],
    ['commons/src/main/ets/utils/ProcessPreferences.ets', ['installGameSnapshots', 'captureOwner']],
    ['entry/hvigorfile.ts', ['AMCL_DESKTOP_NATIVE_GL_VALIDATE', 'check-desktop-runtime.mjs']],
    ['scripts/build-sdl3-ohos.ps1', ['SDL_AMCL_DESKTOP_HOST:BOOL=ON', 'check-desktop-runtime.mjs']],
  ]) for (const needle of needles) if (!read(path).includes(needle)) issues.push(`${path}: missing ${needle}`);
  const sdl = addedFile(patch, 'src/video/openharmony/SDL_amcldesktop.c');
  for (const needle of ['amclDesktopHostResolve', 'SDL_AttachVirtualJoystick', 'fullscreen_sequence', 'GetDisplayUsableBounds', 'SetClipboardText']) if (!sdl.includes(needle)) issues.push(`SDL desktop adapter missing ${needle}`);
  return issues;
}
export function evaluateDesktopManifest(manifest, metadata, validation) {
  const issues = [];
  const game = manifest.module?.abilities?.find(a => a.name === 'GameAbility');
  if (game?.process !== ':game' || game?.launchType !== 'singleton') issues.push('HAP GameAbility is not a private singleton process');
  if (!['fullscreen', 'floating', 'split'].every(m => game?.supportWindowMode?.includes(m))) issues.push('HAP game window modes incomplete');
  const desktop = metadata.name === 'desktop';
  if (metadata.name === 'desktopLegacy') issues.push('desktopLegacy is retired and must not be packaged');
  const clipboard = manifest.module?.requestPermissions?.some(p => p.name === 'ohos.permission.READ_PASTEBOARD') ?? false;
  if (clipboard !== desktop) issues.push('HAP clipboard permission differs from the desktop product contract');
  if (metadata.build?.nativeGlValidation !== validation) issues.push('HAP native GL validation metadata mismatch');
  issues.push(...graphicsBootstrapIssues(manifest.app));
  if (validation && metadata.name !== 'desktop') issues.push('Native GL validation requires desktop');
  return issues;
}
export function evaluateNativeBuild(cache, commands, validation, nativeOnly = false) {
  const issues = [];
  const flag = validation ? 'ON' : 'OFF';
  if (!new RegExp(`^AMCL_DESKTOP_NATIVE_GL_VALIDATE:BOOL=${flag}$`, 'm').test(normalize(cache))) issues.push('CMakeCache native GL value differs');
  if (nativeOnly && !/^AMCL_NATIVE_DESKTOP_ONLY:BOOL=OFF$/m.test(normalize(cache))) issues.push('Desktop must retain the complete graphics providers');
  if (nativeOnly && !/^AMCL_API26_LINK_PROBE:BOOL=OFF$/m.test(normalize(cache))) issues.push('API22 desktop must not strong-link API26 probe');
  if (nativeOnly) {
    if (commands.filter(c => /[/\\]glfw_egl\.cpp$/.test(c.file)).length !== 1) issues.push('Desktop must compile the unified EGL implementation');
    for (const row of commands) {
      if (/[/\\]desktop_egl\.cpp$/i.test(row.file)) {
        issues.push('Desktop compile graph still includes the retired exclusive EGL route: ' + row.file);
      }
    }
  }
  for (const target of ['entry', 'glfw']) {
    const records = commands.filter(c => /[/\\]native_gl\.cpp$/.test(c.file) && c.command.replaceAll('\\', '/').includes(`CMakeFiles/${target}.dir/`));
    if (records.length !== 1 || !records[0].command.includes(`-DAMCL_DESKTOP_NATIVE_GL_VALIDATE=${validation ? 1 : 0} `)) issues.push(`${target}: actual native_gl.cpp compile definition differs or missing`);
    if (nativeOnly && records.length === 1 && !records[0].command.includes('-DAMCL_NATIVE_DESKTOP_ONLY=0 ')) issues.push(`${target}: unified provider compile definition missing`);
  }
  return issues;
}
export function hasDefinedSymbol(output, name) { return new RegExp(`^[0-9a-fA-F]+\\s+[TW]\\s+${name}(?:@@?[A-Za-z0-9_.]+)?$`, 'm').test(normalize(output)); }

export function desktopDependencyIssues(dynamic) {
  const needed=[...dynamic.matchAll(/Shared library: \[([^\]]+)\]/g)].map(m=>m[1]);
  if (!needed.includes('libc.so')) return ['Desktop ELF dependency inspection is incomplete'];
  return needed.filter(name=>/GLES|gallium|glapi|EGL_mesa|mobilegl/i.test(name)).map(name=>'Desktop links forbidden provider '+name);
}

function inspectHap(path, nativeBuild, validation, sdk) {
  const bytes = readFileSync(path);
  const manifest = JSON.parse(readUniqueZipEntry(bytes, 'module.json'));
  const metadata = JSON.parse(readUniqueZipEntry(bytes, 'resources/rawfile/product-profile.json'));
  const issues = evaluateDesktopManifest(manifest, metadata, validation);
  if (!nativeBuild) throw new Error('--native-build is required with --hap; source defaults are insufficient');
  const cache = readFileSync(join(nativeBuild, 'CMakeCache.txt'), 'utf8');
  const commands = JSON.parse(readFileSync(join(nativeBuild, 'compile_commands.json'), 'utf8'));
  const nativeOnly = metadata.name === 'desktop';
  issues.push(...evaluateNativeBuild(cache, commands, validation, nativeOnly));
  const configuredNm = /^CMAKE_NM:FILEPATH=(.+)$/m.exec(normalize(cache))?.[1];
  const nm = configuredNm && existsSync(configuredNm) ? configuredNm : join(sdk, 'native/llvm/bin', process.platform === 'win32' ? 'llvm-nm.exe' : 'llvm-nm');
  if (!existsSync(nm)) throw new Error('LLVM nm missing; pass --sdk <openharmony SDK>');
  const dir = mkdtempSync(join(workspaceTempRoot(), 'amcl-desktop-artifact-'));
  const libraries = {};
  try {
    for (const [lib, symbol] of [['libentry.so', 'amclDesktopHostGetV1'], ['libglfw.so', 'amclDesktopHostResolve'], ['libSDL3.so', 'SDL_GetRevision']]) {
      const data = readUniqueZipEntry(bytes, `libs/arm64-v8a/${lib}`);
      const target = join(dir, lib); writeFileSync(target, data);
      const symbols = execFileSync(nm, ['--dynamic', '--defined-only', target], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
      if (nativeOnly && (lib === 'libentry.so' || lib === 'libglfw.so')) {
        const readelf=join(dirname(nm),process.platform==='win32'?'llvm-readelf.exe':'llvm-readelf');
        const dynamic=execFileSync(readelf,['-d',target],{encoding:'utf8'});
        issues.push(...desktopDependencyIssues(dynamic).map(issue=>`${lib}: ${issue}`));
      }
      if (!hasDefinedSymbol(symbols, symbol)) issues.push(`${lib}: exported definition ${symbol} missing`);
      if (nativeOnly && lib === 'libglfw.so') {
        if (!data.includes(Buffer.from('AMCL_UNIFIED_EGL_V1'))) issues.push('Desktop HAP predates runtime EGL provider dispatch');
        for (const forbidden of ['mg_initialize_v1','glXGetProcAddress','glBegin','glGetError']) {
          if (hasDefinedSymbol(symbols, forbidden)) issues.push(`Desktop GLFW contains forbidden translation symbol ${forbidden}`);
        }
      }
      if (nativeOnly && lib === 'libentry.so') {
        if (hasDefinedSymbol(symbols,'AMCL_Api26InputCompileLinkSymbolSurface')) issues.push('API26 strong-link probe remains in API22-compatible HAP');
        const undefinedSymbols = execFileSync(nm, ['--dynamic','--undefined-only',target], {encoding:'utf8'});
        for (const forbidden of ['OH_ArkUI_MouseEvent_GetRawDeltaX','OH_ArkUI_MouseEvent_GetRawDeltaY']) {
          if (new RegExp(`\\bU\\s+${forbidden}(?:@|$)`, 'm').test(undefinedSymbols)) issues.push(`API26 raw symbol is a mandatory import: ${forbidden}`);
        }
      }
      if (lib === 'libSDL3.so' && !artifactEmbedsSdl3Patchset(data, computeSdl3PatchsetDigest().sha256)) issues.push('HAP SDL patchset identity missing');
      libraries[lib] = { size: data.length, sha256: createHash('sha256').update(data).digest('hex'), symbol };
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
  return { issues, product: metadata.name, nativeGlValidation: validation, size: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'), libraries, nativeBuild: resolve(nativeBuild),
    runtimeAccepted: false, signingAclVerified: false };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const arg = name => { const i = process.argv.indexOf(name); return i < 0 ? '' : process.argv[i + 1]; };
    const issues = checkDesktopSources(PRODUCT_ROOT, arg('--sdl-repo'));
    const sdkRoot = arg('--sdk') || process.env.DEVECO_SDK_HOME || 'D:/Huawei/command-line-tools/sdk';
    const sdk = [sdkRoot, join(sdkRoot, 'openharmony'), join(sdkRoot, 'default/openharmony')]
      .find(p => existsSync(join(p, 'native/llvm/bin', process.platform === 'win32' ? 'llvm-nm.exe' : 'llvm-nm'))) || sdkRoot;
    const report = arg('--hap') ? inspectHap(arg('--hap'), arg('--native-build'), process.argv.includes('--native-gl-validation'), sdk) : { issues: [] };
    report.issues.unshift(...issues);
    if (arg('--report')) writeFileSync(arg('--report'), JSON.stringify(report, null, 2) + '\n');
    if (report.issues.length) throw new Error(report.issues.join('\n'));
    console.log(`[desktop-runtime] PASS ${report.product || 'source'}${arg('--hap') ? ' HAP + native compile inputs' : ''}; PC runtime remains unverified`);
  } catch (error) { console.error(`[desktop-runtime] FAIL: ${error.message}`); process.exitCode = 1; }
}

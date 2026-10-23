import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { evaluateDiagnosticMetadata } from './check-diagnostics-contract.mjs';
import { desktopDependencyIssues } from './check-desktop-runtime.mjs';
import { evaluateMirror, evaluateDesktopManifest, evaluateNativeBuild, hasDefinedSymbol, evaluateEglDispatch, evaluateDesktopCompletionSources, evaluateDesktopGraphicsPeerRouting } from './check-desktop-runtime.mjs';
const header = readFileSync(new URL('../entry/src/main/cpp/platform/desktop_host_api.h', import.meta.url), 'utf8');
const patch = readFileSync(new URL('../prebuilt/sdl3/patches/0010-openharmony-desktop-services.patch', import.meta.url), 'utf8');
const callbacks = readFileSync(new URL('../entry/src/main/cpp/glfw/glfw_callbacks.cpp', import.meta.url), 'utf8');
const page = readFileSync(new URL('../entry/src/main/ets/pages/McGamePage.ets', import.meta.url), 'utf8');
const ability = readFileSync(new URL('../entry/src/main/ets/gameability/GameAbility.ets', import.meta.url), 'utf8');
const launcher = readFileSync(new URL('../entry/src/main/cpp/jvm/mc_launcher.cpp', import.meta.url), 'utf8');
const glfwCompat = readFileSync(new URL('../entry/src/main/cpp/glfw/glfw_compat.cpp', import.meta.url), 'utf8');
const nativeGl = readFileSync(new URL('../entry/src/main/cpp/platform/native_gl.cpp', import.meta.url), 'utf8');
const runtimeBootstrap = readFileSync(new URL('../entry/src/main/cpp/jvm/runtime_bootstrap_contract.h', import.meta.url), 'utf8');
assert.deepEqual(evaluateDesktopCompletionSources(callbacks,page,ability),[]);
// 执行真实页面原文，调用可以携带进程预约或保留旧空参；允许正常空白/注释调整，
// 不要求维护者为通过文本门禁而删除实际业务参数。替换必须命中，防负控空跑。
function replacePage(before, after) {
  const start = page.indexOf('private async startMCOnce()');
  const end = page.indexOf('private async startMCInternal(', start);
  const target = page.indexOf(before, start);
  assert.ok(start >= 0 && end > start && target >= start && target < end,
    '真实 startMCOnce 内负控锚点不存在：' + before);
  const changed = page.slice(0, target) + after + page.slice(target + before.length);
  assert.notEqual(changed, page); return changed;
}
const internalCall = 'await this.startMCInternal(processLaunch)';
const enterWindow = 'const snapshot: ProductGameWindowSnapshot = await this.sessionHost.enterWindow(this.frontendLease, this.context)';
const completionIssues = candidate => evaluateDesktopCompletionSources(callbacks, candidate, ability)
  .filter(issue => issue.includes('valid Window'));
assert.deepEqual(completionIssues(replacePage(internalCall, 'await this.startMCInternal()')), []);
assert.deepEqual(completionIssues(replacePage(internalCall, 'await /* original reservation */ this . startMCInternal (processLaunch)')), []);
assert.deepEqual(completionIssues(replacePage(internalCall, 'await this.startMCInternal("argument text with } and )")')), []);
for (const replacement of ['', 'this.startMCInternal(processLaunch)',
  '/* await this.startMCInternal(processLaunch) */',
  'const diagnostic = "await this.startMCInternal(processLaunch)"',
  'const diagnostic = `await this.startMCInternal(processLaunch)`',
  'const diagnostic = /await this.startMCInternal(processLaunch)/']) {
  assert.ok(completionIssues(replacePage(internalCall, replacement)).length,
    '注释、字面量或没有 await 的调用不能代替真实内部启动');
}
assert.ok(completionIssues(replacePage(enterWindow, internalCall + '\n' + enterWindow)).length,
  '即使后面还有正常调用，也必须拒绝窗口取得前的首次真实启动');
assert.ok(completionIssues(replacePage(enterWindow, 'this.startMCInternal(processLaunch)\n' + enterWindow)).length,
  '窗口取得前的无 await 真实调用不能被后面的合法 await 掩盖');
assert.ok(completionIssues(replacePage('if (snapshot.windowId <= 0', internalCall + '\nif (snapshot.windowId <= 0')).length,
  '窗口已取得但尚未检查快照前也不能先启动内部流程');
assert.ok(completionIssues(replacePage('if (snapshot.windowId <= 0', 'this.startMCInternal(processLaunch)\nif (snapshot.windowId <= 0')).length,
  '快照取得后守卫前的无 await 调用同样不能被后面的合法 await 掩盖');
assert.ok(completionIssues(replacePage('snapshot.contextGeneration <= 0', 'false')).length,
  '删除真实快照代次检查不能由其它 throw 代替');
assert.ok(completionIssues(replacePage('snapshot.contextGeneration <= 0', '"snapshot.contextGeneration <= 0".length === 0')).length,
  '字符串内的 guard 名称不能伪造真实快照验证');
console.log('[desktop-runtime self-test] PASS: real argument-carrying call and lexical Window/guard/start order negative controls');
assert.deepEqual(evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl, runtimeBootstrap),[]);
// 默认实参中的花括号不是函数体；两种合法初始化写法都必须解析到相同契约正文。
assert.deepEqual(evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl,
  runtimeBootstrap.replace('JnaBootstrap{}', 'JnaBootstrap()')), []);
// 通用冻结不应再局限于 desktop；但 native contextAPI 必须只属于 nativegl。
assert.ok(evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl,
  runtimeBootstrap.replace('if (profile == "nativegl")', 'if (true)')).some(s=>s.includes('freezing')));
assert.ok(evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl,
  runtimeBootstrap.replace('if (profile == "nativegl")', 'if (profile == "minecraft-vulkan")')).some(s=>s.includes('freezing')));
assert.ok(evaluateDesktopGraphicsPeerRouting(launcher.replace('if (!amcl::jvm::FreezeBootstrapProperties(', 'if (!unusedFreeze('),
  glfwCompat, nativeGl, runtimeBootstrap).some(s=>s.includes('freezing')));
assert.ok(evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl, '').some(s=>s.includes('freezing')));
assert.ok(evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat.replace('if (g_hintClientAPI == GLFW_NO_API && !admittedVulkanWindow)', 'if (false)'), nativeGl, runtimeBootstrap).some(s=>s.includes('NO_API')));
assert.ok(evaluateDesktopGraphicsPeerRouting(launcher, glfwCompat, nativeGl.replace('if (api && strcmp(api, "VULKAN") == 0) return false;', 'if (false) return false;'), runtimeBootstrap).some(s=>s.includes('NativeGlRequested')));
assert.ok(evaluateDesktopCompletionSources(callbacks.replace('window->iconifyCb = callback','/* removed */'),page,ability).some(s=>s.includes('Iconify')));
assert.ok(evaluateDesktopCompletionSources(callbacks.replace('window->positionCb(window,facts.x,facts.y)','/* removed */'),page,ability).some(s=>s.includes('positionCb')));
assert.ok(evaluateDesktopCompletionSources(callbacks,page.replaceAll('await this.sessionHost.enterWindow(this.frontendLease, this.context)','Promise.resolve(new ProductGameWindowSnapshot())'),ability).length);
assert.ok(evaluateDesktopCompletionSources(callbacks,page.replace('this.sessionHost.runLaunch(', 'this.otherGate.run('),ability).length);
assert.ok(evaluateDesktopCompletionSources(callbacks,page,ability.replaceAll('testNapi.desktopGamepadFocus(false);','')).length);
assert.deepEqual(evaluateMirror(header, patch), []);
assert.ok(evaluateMirror(header.replace('int32_t connected', 'int64_t connected'), patch).length);
assert.ok(evaluateMirror(header, '').length);
assert.deepEqual(evaluateEglDispatch('#include "egl_dispatch.h"\neglSwapBuffers(d,s);', '#define eglSwapBuffers(...) dispatch(__VA_ARGS__)'), []);
assert.ok(evaluateEglDispatch('#include "egl_dispatch.h"\neglSwapBuffers(d,s);', '').length);
assert.ok(evaluateEglDispatch('eglSwapBuffers(d,s);', '#define eglSwapBuffers(...) dispatch(__VA_ARGS__)').length);
const manifest = { app: { appEnvironments: [{name:'NEED_OPENGL',value:'1'}] }, module: { abilities: [{ name: 'GameAbility', process: ':game', launchType: 'singleton', supportWindowMode: ['floating','split','fullscreen'] }], requestPermissions: [{ name: 'ohos.permission.READ_PASTEBOARD' }] } };
const metadata = { name: 'desktop', build: { nativeGlValidation: false } };
assert.deepEqual(evaluateDiagnosticMetadata({mode:'release',mask:0,nativeGlValidation:true},{mode:'release',mask:0},'desktop'),[]);
assert.ok(evaluateDiagnosticMetadata({mode:'release',mask:1,nativeGlValidation:true},{mode:'release',mask:0},'desktop').length);
assert.ok(evaluateDiagnosticMetadata({mode:'release',mask:0,nativeGlValidation:true},{mode:'release',mask:0},'sideload').length);
assert.ok(evaluateDiagnosticMetadata({mode:'release',mask:0,nativeGlValidation:'false'},{mode:'release',mask:0},'desktop').length);
assert.deepEqual(evaluateDesktopManifest(manifest, metadata, false), []);
for (const mutate of [m => delete m.module.abilities[0].process, m => m.module.abilities[0].supportWindowMode=['fullscreen'], m => m.module.requestPermissions=[], m => m.app.appEnvironments=[]]) {
  const broken=structuredClone(manifest);mutate(broken);assert.ok(evaluateDesktopManifest(broken,metadata,false).length);
}
const validation=structuredClone(manifest);
assert.deepEqual(evaluateDesktopManifest(validation,{name:'desktop',build:{nativeGlValidation:true}},true),[]);
assert.ok(evaluateDesktopManifest(validation,metadata,true).length);
const commands=['entry','glfw'].map(t=>({file:'a/platform/native_gl.cpp',command:`clang -DAMCL_DESKTOP_NATIVE_GL_VALIDATE=0 -o CMakeFiles/${t}.dir/platform/native_gl.cpp.o`}));
assert.deepEqual(evaluateNativeBuild('AMCL_DESKTOP_NATIVE_GL_VALIDATE:BOOL=OFF\n',commands,false),[]);
assert.ok(evaluateNativeBuild('AMCL_DESKTOP_NATIVE_GL_VALIDATE:BOOL=OFF\n',commands,true).length);
assert.ok(evaluateNativeBuild('AMCL_DESKTOP_NATIVE_GL_VALIDATE:BOOL=OFF\n',commands.slice(1),false).length);
assert.ok(evaluateNativeBuild('AMCL_DESKTOP_NATIVE_GL_VALIDATE:BOOL=OFF\n',commands.map(c=>({...c,command:c.command.replace('=0','=1')})),false).length);
assert.ok(hasDefinedSymbol('000000000a T amclDesktopHostGetV1\n','amclDesktopHostGetV1'));
assert.ok(hasDefinedSymbol('000000000a T SDL_GetRevision@@SDL3_0.0.0\n','SDL_GetRevision'));
assert.equal(hasDefinedSymbol('                 U amclDesktopHostGetV1\n','amclDesktopHostGetV1'),false);
assert.equal(hasDefinedSymbol('000000000a T amclDesktopHostGetV1Fake\n','amclDesktopHostGetV1'),false);
console.log('[desktop-runtime self-test] PASS: ABI, manifest, route, actual compile flag and symbol negative controls');

const nativeCache='AMCL_DESKTOP_NATIVE_GL_VALIDATE:BOOL=OFF\nAMCL_NATIVE_DESKTOP_ONLY:BOOL=OFF\nAMCL_API26_LINK_PROBE:BOOL=OFF\n';
const nativeRows=commands.map(c=>({...c,command:c.command+' -DAMCL_NATIVE_DESKTOP_ONLY=0 '}));
nativeRows.push({file:'a/glfw/glfw_egl.cpp',command:'clang -DAMCL_NATIVE_DESKTOP_ONLY=0 '});
assert.deepEqual(evaluateNativeBuild(nativeCache,nativeRows,false,true),[]);
for (const file of ['a/glfw/desktop_egl.cpp']) {
  assert.ok(evaluateNativeBuild(nativeCache,[...nativeRows,{file,command:'clang'}],false,true).some(s=>s.includes('still includes')));
}
assert.ok(evaluateNativeBuild(nativeCache,nativeRows.slice(0,-1),false,true).some(s=>s.includes('unified EGL')));
console.log('[desktop-runtime self-test] PASS: desktop mobile/MG compile contamination controls');
assert.deepEqual(desktopDependencyIssues('Shared library: [libc.so]\nShared library: [libEGL.so]'),[]);
assert.ok(desktopDependencyIssues('').length);
assert.ok(desktopDependencyIssues('Shared library: [libc.so]\nShared library: [libGLESv3.so]').length);

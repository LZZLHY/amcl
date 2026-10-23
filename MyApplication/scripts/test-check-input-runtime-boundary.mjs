#!/usr/bin/env node
// 独立正反例验证门禁判据：不依赖SDK、不伪造真实HAP通过。源码fixture与ELF元数据
// fixture分别覆盖所有权、链接、宏闭包、导出和编译标记；CLI真HAP路径仍另行验收。
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { diagnosticProfile } from './diagnostic-profile.mjs';
import {
  INPUT_OWNER_SOURCES, INPUT_BUILD_FLAGS, INPUT_BUILD_VALUES, INPUT_RUNTIME_EXPORTS, INPUT_SCOPED_IMPORTS,
  inputRuntimeSourceIssues, inputRuntimeArtifactIssues, inputBuildMarkers,
  inputRuntimeDiagnosticPolicy, INPUT_LATENCY_HOOKS, INPUT_LATENCY_INTERNAL_HOOKS,

  textHookDynsym, inputRuntimeSymbolVersions,
} from './check-input-runtime-boundary.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const version = `INPUT_V1 { global:
 amclInput*; amclBackendInput*; inputBridge_*;
 inputBridgeStartPumping; inputBridgePumpEvents; inputBridgeStopPumping;
 Java_org_lwjgl_glfw_CallbackBridge_*;
 amclControlDeliveryGetPortV1; amclControlDeliveryBindSessionV1; amclControlDeliveryPublishV1;
 amclSourceControlGetPortV1; amclSourceControlPublishV1; amclSourceControlPrepareV1;
 amclSourceControlCompatEdgeV1; amclSourceControlDrainTerminalsV1;
 local: *; };`;
const flags = INPUT_BUILD_FLAGS.map(name => `${name}=${INPUT_BUILD_VALUES[name]}`).join('\n');
const source = `
add_library(amcl_input_runtime SHARED ${INPUT_OWNER_SOURCES.join('\n')})
add_library(glfw SHARED glfw/glfw_compat.cpp input/adapters/glfw_input_adapter.cpp)
add_library(entry SHARED entry.cpp)
target_link_libraries(amcl_input_runtime PRIVATE amcl_graphics_runtime libhilog_ndk.z.so dl)
target_link_libraries(glfw PRIVATE amcl_input_runtime)
target_link_libraries(entry PUBLIC amcl_input_runtime glfw)
target_compile_definitions(glfw PRIVATE ${flags})
target_compile_definitions(amcl_input_runtime PRIVATE ${flags})
`;
let cases = 0;
const rejectedSource = (candidate, expected, candidateVersion = version) => {
  assert.match(inputRuntimeSourceIssues(candidate, candidateVersion).join('\n'), expected);
  cases += 1;
};
assert.deepEqual(inputRuntimeSourceIssues(source, version), []); cases += 1;
for (const symbol of ['amclControlDeliveryGetPortV1', 'amclControlDeliveryBindSessionV1', 'amclControlDeliveryPublishV1']) {
  rejectedSource(source, /private control port export/, version.replace(symbol+';', '/* '+symbol+'; */'));
}
for (const symbol of ['amclSourceControlGetPortV1','amclSourceControlPublishV1','amclSourceControlPrepareV1',
  'amclSourceControlCompatEdgeV1','amclSourceControlDrainTerminalsV1']) {
  rejectedSource(source,/private source port export/,version.replace(symbol+';','/* '+symbol+'; */'));
}
assert.deepEqual(inputRuntimeSourceIssues(`${source}\n# target_sources(entry PRIVATE input/input_state_core.cpp)\n`, version), []); cases += 1;
for (const owned of INPUT_OWNER_SOURCES) {
  rejectedSource(`${source}\ntarget_sources(glfw PRIVATE ${owned})`, /unique owner/);
  rejectedSource(source.replace(owned, `# ${owned}\n`), /unique owner/);
}
rejectedSource(`${source}\nset(ILLEGAL input/input_state_core.cpp)\ntarget_sources(entry PRIVATE \$\{ILLEGAL\})`, /unique owner/);
rejectedSource(`${source}\nset(A \$\{B\})\nset(B input/input_state_core.cpp)\ntarget_sources(entry PRIVATE \$\{A\})`, /unique owner/);
rejectedSource(`${source}\nset(ILLEGAL other.cpp)\nlist(APPEND ILLEGAL input/input_state_core.cpp)\ntarget_sources(entry PRIVATE \$\{ILLEGAL\})`, /unique owner/);
rejectedSource(source.replace('target_link_libraries(glfw PRIVATE amcl_input_runtime)', ''), /glfw: missing direct/);
rejectedSource(source.replace('target_link_libraries(entry PUBLIC amcl_input_runtime glfw)', ''), /entry: missing direct/);
for (const dependency of ['glfw', 'entry', 'SDL3', 'mobilegl', 'amcl_gl_host', 'libEGL.so', 'libGLESv3.so']) {
  rejectedSource(`${source}\ntarget_link_libraries(amcl_input_runtime PRIVATE ${dependency})`, /frontend\/renderer dependency/);
}
for (const flag of INPUT_BUILD_FLAGS) {
  rejectedSource(source.replace(`${flag}=${INPUT_BUILD_VALUES[flag]}`, `${flag}=0`), /compile closure mismatch/);
  rejectedSource(`${source}\ntarget_compile_definitions(amcl_input_runtime PRIVATE ${flag}=0)`, /compile closure mismatch/);
}
rejectedSource(source.replaceAll('AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=$<BOOL:${AMCL_GLFW_TYPED_PHYSICAL_DEFAULT}>', 'AMCL_GLFW_TYPED_PHYSICAL_DEFAULT=0'), /compile closure mismatch/);
rejectedSource(source, /non-underscore compatibility/, version.replace('inputBridgePumpEvents;', ''));
rejectedSource(source, /must hide private/, version.replace('local: *;', 'local: unrelated;'));
rejectedSource(source, /exports frontend/, version.replace('global:', 'global: glfw*;'));
rejectedSource(`${source}\nunknown_without_parentheses`, /parse failed/);
rejectedSource('', /unique owner/);

const marker = 'AMCL_INPUT_BUILD_V1|typed=1|relative=1|absolute=0|monotonic=0|api26Raw=1|evidence=test-lock|END';
assert.deepEqual(inputBuildMarkers(Buffer.from(`\0${marker}\0${marker}\0`)), [marker]); cases += 1;
assert.deepEqual(inputBuildMarkers(Buffer.from('AMCL_INPUT_BUILD_V1|typed=%d\0')), []); cases += 1;
assert.deepEqual(inputBuildMarkers(Buffer.from(marker.replace('|END', '\0'))), []); cases += 1;

const image = (name, needed, exports, markers = []) => ({
  soname: name, machine: 183, runpath: ['$ORIGIN'], needed, exports, undefined: [],
  strongUndefined: [...(INPUT_SCOPED_IMPORTS[name] ?? [])], markers,
  latencyDiagnosticTextPresent: false,
});
// 固定业务判据独立于checker表：若测试全从该表生成，误删真实relative/ACK caller也会自洽通过。
const entryCoreCallers = [
  'inputBridge_publishTouchMenuToolRelativeV1', 'inputBridge_publishTouchMenuRelativeV1',
  'inputBridge_getCommittedMenuCursorV1', 'inputBridge_configureMenuCursorConsumerV1',
  'inputBridge_legacyRingDiscontinuityEpochV1',
  'amclInputOwnerReadTextResourceV1',
  'amclInputOwnerL2KeyboardScopeV1',
];
// 新契约独立写出当前生产名字，不能从checker数组生成后再自洽验证。该组不包含
// host诊断getter；默认导出族及L2纯getter解析模型仍沿原规则。
const keyboardOwnerHooks = [
  'amclInputL2KeyboardGetPortV1', 'amclInputL2KeyboardPublishV1',
  'amclInputOwnerL2KeyboardScopeV1', 'amclInputOwnerCompareL2KeyboardScopeV1',
  'amclInputOwnerSelectKeyboardBackendV1', 'amclInputOwnerSelectedKeyboardBackendV1',
  'amclInputOwnerReadL2KeyStampV1', 'amclInputOwnerReadL2HeldKeyV1',
  'amclBackendInputL2ReadKeyScopeV1', 'inputBridge_pushKeyScopedV1',
];
for (const symbol of keyboardOwnerHooks) {
  assert.ok(INPUT_RUNTIME_EXPORTS.includes(symbol), `actual Keyboard owner definition absent: ${symbol}`); cases += 1;
}
const toolCursorCompatibility = 'inputBridge_publishTouchMenuToolCursorV1';
assert.ok(INPUT_RUNTIME_EXPORTS.includes(toolCursorCompatibility)); cases += 1;
assert.ok(!INPUT_SCOPED_IMPORTS['libentry.so'].includes(toolCursorCompatibility)); cases += 1;
for (const symbol of entryCoreCallers) {
  assert.ok(INPUT_SCOPED_IMPORTS['libentry.so'].includes(symbol), `actual entry caller absent: ${symbol}`);
  assert.ok(INPUT_RUNTIME_EXPORTS.includes(symbol), `neutral definition contract absent: ${symbol}`);
  cases += 1;
}
const definedHook = name => ({name: name+'@@AMCL_INPUT_RUNTIME', value: '1000', size: 64,
  type: 'FUNC', bind: 'GLOBAL', visibility: 'DEFAULT', section: '15'});
/** 分类器fixture显式给出ordinal/版本表；只证规则，不把这段合成文字冒称真实ELF。
 * 实际LLVM输出和同名版本不同provider另由外置真实编译fixture承接。
 */
const versionSymbolText = indices => {
  const values = [0,...indices], lines = [];
  for (let start=0;start<values.length;start+=4)
    lines.push(` ${start.toString(16).padStart(3,'0')}: `+values.slice(start,start+4)
      .map(value=>`${value.toString(16)} (${value===0?'*local*':'AMCL_INPUT_RUNTIME'})`).join(' '));
  return ` '.gnu.version' contains ${values.length} entries:\n Addr: 0 Offset: 0 Link: 3 (.dynsym)\n${lines.join('\n')}\n`;
};
const withVersionTable = image => {
  (image.textHookDynsym??=[]).forEach((row,index)=>{row.symbolIndex=index+1;});
  image.textHookVersionSymbols=versionSymbolText(image.textHookDynsym.map(()=>2));return image;
};
const fixture = () => ({
  'libamcl_input_runtime.so': {...image('libamcl_input_runtime.so', ['libamcl_graphics_runtime.so', 'libc.so'], [...INPUT_RUNTIME_EXPORTS], [marker]),
    textHookDynsym: ['amclInputOwnerReadTextResourceV1','amclInputOwnerValidateTextScopeV1',...keyboardOwnerHooks].map(definedHook)},
  'libglfw.so': image('libglfw.so', ['libamcl_input_runtime.so', 'libamcl_graphics_runtime.so'], ['glfwInit', 'glfwOHOS_InputBuildIdentityV1'], [marker]),
  'libentry.so': withVersionTable({...image('libentry.so', ['libglfw.so', 'libamcl_input_runtime.so'], []),
    textHookDynsym: ['amclInputOwnerReadTextResourceV1','amclInputOwnerL2KeyboardScopeV1'].map(name =>
      ({...definedHook(name), name: name+'@AMCL_INPUT_RUNTIME', section: 'UND'})),
    textHookVersionNeeds: 'File: libamcl_input_runtime.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2'}),
});
// 元数据selftest只验判据，不能授予真实新HAP资格。实际CLI另读所选ELF原dynsym/version_r。
const offPolicy = inputRuntimeDiagnosticPolicy({ name: 'default', build: diagnosticProfile('default', 'debug', 'none') });
assert.deepEqual(offPolicy, {inputTraceEnabled:false, issues:[]}); cases += 1;
assert.deepEqual(inputRuntimeArtifactIssues(fixture(), offPolicy), []); cases += 1;
const rejectedArtifact = (mutate, expected) => {
  const images = fixture(); mutate(images);
  assert.match(inputRuntimeArtifactIssues(images, offPolicy).join('\n'), expected);
  cases += 1;
};
for (const hook of ['amclInputOwnerReadTextResourceV1','amclInputOwnerValidateTextScopeV1']) {
  for (const [field,value] of [['bind','WEAK'],['visibility','HIDDEN'],['value','0000'],['section','UND'],['size',0],
    ['name',hook+'@@WRONG_RUNTIME']]) {
    rejectedArtifact(images => {images['libamcl_input_runtime.so'].textHookDynsym.find(row=>row.name.startsWith(hook+'@'))[field]=value;},
      /missing exact strong default versioned text hook/);
  }
  for (const consumer of ['libentry.so','libglfw.so'])
    rejectedArtifact(images=>{images[consumer].exports.push(hook);},/duplicates runtime/);
}
for (const hook of keyboardOwnerHooks) {
  // 真实新owner必须有强default版本FUNC定义；“名字还在exports表”不能掩盖以下任一行退化。
  for (const [field,value] of [['bind','WEAK'],['bind','LOCAL'],['visibility','HIDDEN'],['visibility','PROTECTED'],
    ['type','OBJECT'],['type','NOTYPE'],['value','0000'],['section','UND'],['section','ABS'],['section','0'],['size',0],
    ['name',hook+'@@WRONG_RUNTIME'],['name',hook+'@AMCL_INPUT_RUNTIME'],['name',hook]])
    rejectedArtifact(images => {images['libamcl_input_runtime.so'].textHookDynsym.find(row=>row.name.startsWith(hook+'@'))[field]=value;},
      /missing exact strong default versioned keyboard owner hook/);
  rejectedArtifact(images => {
    images['libamcl_input_runtime.so'].textHookDynsym = images['libamcl_input_runtime.so'].textHookDynsym
      .filter(row=>row.name!==hook+'@@AMCL_INPUT_RUNTIME');
  }, /missing exact strong default versioned keyboard owner hook/);
  rejectedArtifact(images => {
    images['libamcl_input_runtime.so'].textHookDynsym.push(definedHook(hook));
  }, /missing exact strong default versioned keyboard owner hook/);
  for (const consumer of ['libentry.so','libglfw.so'])
    rejectedArtifact(images=>{images[consumer].exports.push(hook);},/duplicates runtime/);
}
for (const [field,value] of [['bind','WEAK'],['visibility','HIDDEN'],['section','15'],
  ['name','amclInputOwnerReadTextResourceV1@WRONG_RUNTIME']])
  rejectedArtifact(images=>{images['libentry.so'].textHookDynsym[0][field]=value;},/missing exact version-bound strong text resource reader/);
for (const value of ['', 'File: unrelated.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2',
  'File: libamcl_input_runtime.so Cnt: 1 Name: WRONG_RUNTIME Flags: none Version: 2'])
  rejectedArtifact(images=>{images['libentry.so'].textHookVersionNeeds=value;},/missing exact version-bound strong text resource reader/);
for (const [field,value] of [['bind','WEAK'],['visibility','HIDDEN'],['type','NOTYPE'],['section','15'],
  ['name','amclInputOwnerL2KeyboardScopeV1@WRONG_RUNTIME'],['name','amclInputOwnerL2KeyboardScopeV1']])
  rejectedArtifact(images => {
    images['libentry.so'].textHookDynsym.find(row=>row.name.startsWith('amclInputOwnerL2KeyboardScopeV1'))[field]=value;
  }, /missing exact version-bound strong keyboard scope reader/);
rejectedArtifact(images => {
  images['libentry.so'].textHookDynsym = images['libentry.so'].textHookDynsym
    .filter(row=>!row.name.startsWith('amclInputOwnerL2KeyboardScopeV1'));
}, /missing exact version-bound strong keyboard scope reader/);
for (const value of ['', 'File: unrelated.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2',
  'File: libamcl_input_runtime.so Cnt: 1 Name: WRONG_RUNTIME Flags: none Version: 2'])
  rejectedArtifact(images=>{images['libentry.so'].textHookVersionNeeds=value;},/missing exact version-bound strong keyboard scope reader/);
// entry无需把兼容toolCursor链接成强U，但neutral必须继续强定义它，两个责任不能合并成一张表。
const compatibilityOnly = fixture();
compatibilityOnly['libentry.so'].strongUndefined = compatibilityOnly['libentry.so'].strongUndefined
  .filter(value => value !== toolCursorCompatibility);
assert.deepEqual(inputRuntimeArtifactIssues(compatibilityOnly, offPolicy), []); cases += 1;
rejectedArtifact(images => {
  images['libamcl_input_runtime.so'].exports = images['libamcl_input_runtime.so'].exports
    .filter(value => value !== toolCursorCompatibility);
}, /runtime missing defined ABI inputBridge_publishTouchMenuToolCursorV1/);
for (const symbol of entryCoreCallers) {
  // 即使名称保留为weak UND且neutral定义存在，也不能替代该真实caller必须具有的strong U。
  rejectedArtifact(images => {
    images['libentry.so'].strongUndefined = images['libentry.so'].strongUndefined.filter(value => value !== symbol);
    images['libentry.so'].undefined.push(symbol);
  }, new RegExp(`libentry\\.so: missing strong scoped ABI ${symbol}`));
}
rejectedArtifact(images => {
  images['libentry.so'].strongUndefined = images['libentry.so'].strongUndefined
    .filter(value => value !== 'inputBridge_publishTouchMenuToolRelativeV1');
  images['libentry.so'].strongUndefined.push(toolCursorCompatibility);
}, /missing strong scoped ABI inputBridge_publishTouchMenuToolRelativeV1/);
for (const name of Object.keys(fixture())) {
  rejectedArtifact(images => { delete images[name]; }, /missing HAP/);
  rejectedArtifact(images => { images[name].machine = 62; }, /architecture/);
  rejectedArtifact(images => { images[name].soname = 'wrong.so'; }, /SONAME/);
  rejectedArtifact(images => { images[name].runpath = ['D:/host/build']; }, /RUNPATH/);
}
for (const symbol of INPUT_RUNTIME_EXPORTS) {
  rejectedArtifact(images => { images['libamcl_input_runtime.so'].exports = images['libamcl_input_runtime.so'].exports.filter(value => value !== symbol); }, /missing defined ABI/);
}
// 保留名称但撤成弱引用也要失败，不能由exports/NEEDED存在掩盖新的跨DSO接线缺失。
for (const [name, imports] of Object.entries(INPUT_SCOPED_IMPORTS)) {
  for (const symbol of imports) {
    rejectedArtifact(images => {
      images[name].undefined.push(symbol);
      images[name].strongUndefined = images[name].strongUndefined.filter(value => value !== symbol);
    }, /missing strong scoped ABI/);
  }
}
for (const consumer of ['libglfw.so', 'libentry.so']) {
  rejectedArtifact(images => { images[consumer].needed = []; }, /missing physical input/);
  rejectedArtifact(images => { images[consumer].exports.push('amclInputGetHostApiV1'); }, /duplicates runtime/);
  rejectedArtifact(images => { images[consumer].exports.push('inputBridgePumpEvents'); }, /duplicates runtime/);
  // look/source getter已有neutral真实定义；consumer同名再定义也必须拒绝，不能因族名漏表放过。
  for (const symbol of ['amclLookExecutionGetPortV1','amclSourceControlGetPortV1']) {
    rejectedArtifact(images => { images[consumer].exports.push(symbol); }, /duplicates runtime/);
  }
}
for (const name of ['libglfw.so', 'libentry.so', 'libSDL3.so', 'libmobilegl.so', 'libamcl_gl_host.so', 'libEGL.so', 'libGLESv3.so']) {
  rejectedArtifact(images => { images['libamcl_input_runtime.so'].needed.push(name); }, /frontend\/renderer DT_NEEDED/);
}
for (const symbol of ['glfwPollEvents', 'SDL_SendMouseMotion', 'eglMakeCurrent', 'ohos_send_cursor_delta_checked']) {
  rejectedArtifact(images => { images['libamcl_input_runtime.so'].undefined.push(symbol); }, /reverse undefined/);
}
rejectedArtifact(images => { images['libamcl_input_runtime.so'].exports.push('_ZPrivateState'); }, /private C\+\+/);
for (const local of ['amclLookExecutionGetPortV1', 'amclInputOwnerLookCommitReadyV1']) {
  rejectedArtifact(images => { images['libglfw.so'].strongUndefined.push(local); }, /look consumer directly imports namespace-local owner/);
}
rejectedArtifact(images => { images['libglfw.so'].markers = []; }, /complete input build marker/);
rejectedArtifact(images => { images['libamcl_input_runtime.so'].markers.push(marker.replace('typed=1', 'typed=0')); }, /complete input build marker/);
rejectedArtifact(images => { images['libglfw.so'].markers[0] = marker.replace('api26Raw=1', 'api26Raw=0'); }, /markers disagree/);
rejectedArtifact(images => {
  images['libglfw.so'].markers[0] = marker.replace('typed=1', 'typed=0');
  images['libamcl_input_runtime.so'].markers[0] = images['libglfw.so'].markers[0];
}, /shipping typed/);
rejectedArtifact(images => { images['libglfw.so'].exports = ['glfwInit']; }, /build identity ABI/);
// 诊断合同名字独立写出；真实HAP元数据及ELF读取仍由CLI证明，此处只证明判据。
const latencyHooks = ['inputBridge_formatInputLatencyV1', 'inputBridge_noteInputLatencyV1',
  'inputBridge_finishInputLatencyV1', 'inputBridge_drainInputLatencyV1', 'inputBridge_finishInputLatencyTicketV1',
  'inputBridge_getInputLatencyPortV2'];
// 独立名字与精确计数防止checker/fixture自洽漏新口；旧entry0/3与旧四导出序号不变。
assert.deepEqual(INPUT_LATENCY_HOOKS,latencyHooks);assert.equal(latencyHooks.length,6);assert.equal(new Set(latencyHooks).size,6);cases+=3;
const latencyReaders = {'libentry.so':[latencyHooks[0],latencyHooks[3]], 'libglfw.so':[latencyHooks[1],latencyHooks[4]]};
const onPolicy = inputRuntimeDiagnosticPolicy({name:'default',build:diagnosticProfile('default','debug','input-trace')});
assert.deepEqual(onPolicy,{inputTraceEnabled:true,issues:[]}); cases += 1;
const traceFixture = () => {
  const images = fixture(), owner = images['libamcl_input_runtime.so'];
  owner.exports.push(...latencyHooks); owner.textHookDynsym.push(...latencyHooks.map(definedHook));
  owner.latencyDiagnosticTextPresent = true; images['libentry.so'].latencyDiagnosticTextPresent = true;
  for (const [name,readers] of Object.entries(latencyReaders)) {
    images[name].strongUndefined.push(...readers); images[name].undefined.push(...readers);
    images[name].textHookDynsym ??= [];
    images[name].textHookDynsym.push(...readers.map(symbol=>({...definedHook(symbol),name:symbol+'@AMCL_INPUT_RUNTIME',section:'UND'})));
    images[name].textHookVersionNeeds = 'File: libamcl_input_runtime.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2';
    withVersionTable(images[name]);
  }
  return images;
};
assert.deepEqual(inputRuntimeArtifactIssues(traceFixture(),onPolicy),[]); cases += 1;
assert.match(inputRuntimeArtifactIssues(fixture()).join('\n'),/missing verified diagnostic/); cases += 1;
for (const metadata of [{}, {name:'default',build:{}},
  {name:'store',build:diagnosticProfile('default','debug','input-trace')},
  {name:'default',build:{...diagnosticProfile('default','debug','input-trace'),mask:3}},
  {name:'default',build:{...diagnosticProfile('default','debug','none'),flags:{AMCL_INPUT_TRACE:'ON'}}}]) {
  assert.ok(inputRuntimeDiagnosticPolicy(metadata).issues.length); cases += 1;
}
const rejectedTrace = (mutate,expected) => {const images=traceFixture();mutate(images);
  assert.match(inputRuntimeArtifactIssues(images,onPolicy).join('\n'),expected);cases += 1;};
for (const hook of latencyHooks) {
  for (const [field,value] of [['bind','WEAK'],['bind','LOCAL'],['visibility','HIDDEN'],['visibility','PROTECTED'],
    ['type','OBJECT'],['value','0000'],['section','UND'],['section','ABS'],['section','0'],['size',0],
    ['name',hook+'@@WRONG_RUNTIME'],['name',hook]])
    rejectedTrace(images=>{images['libamcl_input_runtime.so'].textHookDynsym.find(row=>row.name===hook+'@@AMCL_INPUT_RUNTIME')[field]=value;},
      /missing exact strong default versioned latency/);
  rejectedTrace(images=>{images['libamcl_input_runtime.so'].exports=images['libamcl_input_runtime.so'].exports.filter(value=>value!==hook);},
    /missing exact strong default versioned latency/);
  rejectedTrace(images=>{images['libamcl_input_runtime.so'].textHookDynsym.push(definedHook(hook));},/missing exact strong default versioned latency/);
  for (const name of Object.keys(fixture())) {
    rejectedArtifact(images=>{images[name].exports.push(hook);},/TRACE OFF retains/);
    rejectedArtifact(images=>{images[name].undefined.push(hook);},/TRACE OFF retains/);
    rejectedArtifact(images=>{images[name].textHookDynsym??=[];images[name].textHookDynsym.push(definedHook(hook));},/TRACE OFF retains/);
  }
  for(const name of Object.keys(latencyReaders))
    rejectedTrace(images=>{images[name].exports.push(hook);},/duplicates runtime latency/);
}
for(const [name,readers] of Object.entries(latencyReaders)) {
  for(const hook of readers) {
    for(const [field,value] of [['bind','WEAK'],['visibility','HIDDEN'],['type','OBJECT'],['section','15'],['name',hook+'@WRONG_RUNTIME']])
      rejectedTrace(images=>{images[name].textHookDynsym.find(row=>row.name===hook+'@AMCL_INPUT_RUNTIME')[field]=value;},/version-bound strong latency/);
    rejectedTrace(images=>{images[name].strongUndefined=images[name].strongUndefined.filter(value=>value!==hook);},/version-bound strong latency/);
  }
  for(const provider of ['', 'File: unrelated.so Cnt: 1 Name: AMCL_INPUT_RUNTIME',
    'File: libamcl_input_runtime.so Cnt: 1 Name: WRONG_RUNTIME'])
    rejectedTrace(images=>{images[name].textHookVersionNeeds=provider;},/version-bound strong latency/);
}
for(const name of ['libentry.so','libamcl_input_runtime.so']) {
  rejectedTrace(images=>{images[name].latencyDiagnosticTextPresent=false;},/body inclusion mismatch/);
  rejectedArtifact(images=>{images[name].latencyDiagnosticTextPresent=true;},/body inclusion mismatch/);
}
// 内部实现名字独立列出；ON/OFF都不能因amclInput通配把未授予的调用面放出来。
const internalLatency = ['amclInputLatencyBeginV1','amclInputLatencyEndV1','amclInputLatencyCurrentV1',
  'amclInputLatencyAcceptV1','amclInputLatencyNoteV1','amclInputLatencyFinishV1','amclInputLatencyDrainV1','amclInputLatencyFinishTicketV1',
  'amclInputLatencyConfigureBackendV2','amclInputLatencyNoteBackendV2','amclInputLatencyFinishBackendV2'];
assert.deepEqual(INPUT_LATENCY_INTERNAL_HOOKS,internalLatency);assert.equal(internalLatency.length,11);assert.equal(new Set(internalLatency).size,11);cases+=3;
for (const name of Object.keys(fixture())) for (const hook of internalLatency) {
  rejectedTrace(images=>{images[name].exports.push(hook);},/internal latency implementation leaks/);
  rejectedArtifact(images=>{images[name].undefined.push(hook);},/internal latency implementation leaks/);
  rejectedTrace(images=>{images[name].textHookDynsym??=[];images[name].textHookDynsym.push(definedHook(hook));},/internal latency implementation leaks/);
}
// 真LLVM的十进制dynsym ordinal与十六进制版本table不能混读；名字没有(N)也应可绑定。
const parsedRow=textHookDynsym(' 12: 0000000000000000 0 FUNC GLOBAL DEFAULT UND inputBridge_noteInputLatencyV1@AMCL_INPUT_RUNTIME');
assert.equal(parsedRow[0].symbolIndex,12);cases+=1;
const parsedVersions=inputRuntimeSymbolVersions(versionSymbolText([2,2,2,2,2,2,2,2,2,2,2,10]),
  'File: libamcl_input_runtime.so Cnt: 2 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2\n Name: AMCL_INPUT_RUNTIME Flags: none Version: 10');
assert.deepEqual(parsedVersions.issues,[]);assert.equal(parsedVersions.symbols[12].versionIndex,10);cases+=1;
for (const [table,needs] of [
  ['', 'File: libamcl_input_runtime.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2'],
  [versionSymbolText([2]).replace('contains 2','contains 3'),'File: libamcl_input_runtime.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2'],
  [versionSymbolText([2])+' 000: 0 (*local*) 2 (AMCL_INPUT_RUNTIME)\n','File: libamcl_input_runtime.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2'],
  [versionSymbolText([2]),'File: libamcl_input_runtime.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2\nFile: wrong.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 2'],
]) {assert.ok(inputRuntimeSymbolVersions(table,needs).issues.length);cases+=1;}
for (const name of Object.keys(latencyReaders)) {
  rejectedTrace(images=>{images[name].textHookVersionSymbols='';},/version-bound strong latency/);
  rejectedTrace(images=>{delete images[name].textHookDynsym.find(row=>row.name.startsWith('inputBridge_')).symbolIndex;},/version-bound strong latency/);
  // neutral同名版本仍真实在index2；reader自身index3指向wrong.so时必须失败，不能借index2。
  rejectedTrace(images=>{const image=images[name];image.textHookVersionSymbols=versionSymbolText(image.textHookDynsym.map(()=>3));
    image.textHookVersionNeeds+='\nFile: wrong.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 3';},/version-bound strong latency/);
}
for (const name of ['amclInputOwnerReadTextResourceV1','amclInputOwnerL2KeyboardScopeV1']) {
  rejectedTrace(images=>{const image=images['libentry.so'],row=image.textHookDynsym.find(row=>row.name.startsWith(name+'@'));
    const indices=image.textHookDynsym.map(candidate=>candidate===row?3:2);image.textHookVersionSymbols=versionSymbolText(indices);
    image.textHookVersionNeeds+='\nFile: wrong.so Cnt: 1 Name: AMCL_INPUT_RUNTIME Flags: none Version: 3';},/version-bound strong (text resource|keyboard scope)/);
}
// 验真实在役CMake，避免fixture和实现各自自洽却与产品声明脱节。
const actual = inputRuntimeSourceIssues(
  readFileSync(resolve(root, 'entry/src/main/cpp/CMakeLists.txt'), 'utf8'),
  readFileSync(resolve(root, 'entry/src/main/cpp/input/input_runtime.version'), 'utf8'));
assert.deepEqual(actual, []); cases += 1;
console.log(`test-check-input-runtime-boundary: PASS ${cases} positive/negative cases; actual source closure verified`);

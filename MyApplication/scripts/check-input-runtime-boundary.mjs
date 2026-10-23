#!/usr/bin/env node
// 中立输入运行时的双层门禁：源码层核对TU唯一归属/链接方向/编译能力闭包，
// --hap模式另读真实ELF导出、DT_NEEDED及两映像的编译标记。源码通过不冒充产物通过。
// 所有解包证据必须外置；ZIP成员缺失/重复、未知ELF或读不懂的声明均直接失败。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readElfIdentity } from './check-mg-build-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { diagnosticProfile } from './diagnostic-profile.mjs';
import { evaluateDiagnosticMetadata } from './check-diagnostics-contract.mjs';
import { assertExternalOutputPath, workspacePath } from './lib/workspace-paths.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const INPUT_OWNER_SOURCES = [
  'input/source/source_control.cpp', 'platform/input_ledger.cpp', 'platform/external_held_registry.cpp',
  'platform/external_held_edge_router.cpp', 'platform/legacy_output_runtime.cpp', 'platform/legacy_physical_edge_router.cpp',
  'input/delivery/control_delivery.cpp',
  'input/delivery/look_execution.cpp', 'platform/look_delta_math.cpp', 'platform/look_pipeline_stats.cpp',
  'input/input_latency_observation.cpp',
  'input/input_state_core.cpp', 'input/amcl_input_host_descriptor.cpp',
  'input/adapters/backend_input_bridge.cpp', 'glfw/input_bridge_ohos.c',
];
export const INPUT_BUILD_FLAGS = [
  'AMCL_GLFW_TYPED_PHYSICAL_DEFAULT', 'AMCL_GLFW_RAW_RELATIVE_VERIFIED',
  'AMCL_GLFW_API26_RAW_MOUSE_MOTION', 'AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED',
  'AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED', 'AMCL_GATE0_EVIDENCE_IDS',
];
// 与build-profile的显式参数闭包相接。两个target都误写成0也不能靠“彼此相等”过关；
// relative/absolute/timestamp必须使用Gate0归一值，不能绕过证据层另作真假解释。
export const INPUT_BUILD_VALUES = {
  AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: '$<BOOL:${AMCL_GLFW_TYPED_PHYSICAL_DEFAULT}>',
  AMCL_GLFW_RAW_RELATIVE_VERIFIED: '${AMCL_GATE0_DEF_AMCL_GLFW_RAW_RELATIVE_VERIFIED}',
  AMCL_GLFW_API26_RAW_MOUSE_MOTION: '$<BOOL:${AMCL_GLFW_API26_RAW_MOUSE_MOTION}>',
  AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED: '${AMCL_GATE0_DEF_AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED}',
  AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED: '${AMCL_GATE0_DEF_AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED}',
  AMCL_GATE0_EVIDENCE_IDS: '${AMCL_GATE0_EVIDENCE_IDS_STRING}',
};
export const INPUT_RUNTIME_EXPORTS = [
  'amclSourceControlGetPortV1', 'amclSourceControlPublishV1', 'amclSourceControlPrepareV1',
  'amclSourceControlCompatEdgeV1', 'amclSourceControlDrainTerminalsV1', 'inputBridge_beginSourceActionV1',
  'amclControlDeliveryGetPortV1', 'amclControlDeliveryBindSessionV1', 'amclControlDeliveryPublishV1',
  'amclLookExecutionGetPortV1', 'amclLookExecutionPublishV1', 'amclLookExecutionCommitV1',
  'amclLookExecutionCommitProcessedV1', 'amclLookExecutionSetRecipientsV1',
  'amclLookCompatProcess', 'amclLookCompatFlush', 'amclLookCompatReset', 'amclLookCompatSet', 'amclLookCompatSnapshot',
  'inputBridge_getLookResourceV1', 'inputBridge_submitLookV1', 'inputBridge_beginLookActionV1',
  'inputBridge_endLookActionV1', 'inputBridge_setLookPrefixCallbackV1',
  'amclInputGetHostApiV1', 'amclInputHostDescriptorPublishV1',
  'amclInputHostDescriptorResolveV1', 'amclInputHostDescriptorClearV1',
  'amclInputRuntimeBuildIdentityV1',
  // owned编辑键只借唯一Core文字resource；与entry的新caller必须同一制品cohort。
  'amclInputOwnerReadTextResourceV1', 'amclInputOwnerValidateTextScopeV1',
  // 新Keyboard私有端口及Core发布围栏必须属于同一真实neutral owner；这里只加
  // 必须定义的产品契约，不扩大version-script允许导出的函数族，也不伪造L2强UND。
  'amclInputL2KeyboardGetPortV1', 'amclInputL2KeyboardPublishV1',
  'amclInputOwnerL2KeyboardScopeV1', 'amclInputOwnerCompareL2KeyboardScopeV1',
  'amclInputOwnerSelectKeyboardBackendV1', 'amclInputOwnerSelectedKeyboardBackendV1',
  'amclInputOwnerReadL2KeyStampV1', 'amclInputOwnerReadL2HeldKeyV1',
  'amclBackendInputL2ReadKeyScopeV1', 'inputBridge_pushKeyScopedV1',
  'amclBackendInputNext', 'amclBackendInputSetActive', 'amclBackendInputReadText',
  'amclBackendInputReadTextScalars', 'amclBackendInputReleaseText',
  'amclBackendInputSetLookProcessorV1', 'amclBackendInputSetLookResetV1',
  'amclBackendInputPublishAddress',
  'inputBridge_publishAddress', 'inputBridge_pushEvent', 'inputBridge_addLookDelta',
  'inputBridge_addSourceLookDelta', 'inputBridge_getCursorSnapshot',
  'inputBridge_setGrabState', 'inputBridge_isGrabbing',
  'inputBridge_beginPhysicalMotionTransaction', 'inputBridge_endPhysicalMotionTransaction',
  'inputBridge_glfwSetActive', 'inputBridge_l2SetActive', 'inputBridge_l2NextEvent',
  'inputBridge_sdlSetActive', 'inputBridge_sdlNextEvent',
  'inputBridge_sdlNotifyFramePresented', 'inputBridge_notifyFramePresented',
  // 新触控菜单能力必须真实定义于同一neutral owner，源码函数名/只读字符串不算产物实现。
  'inputBridge_retireTouchMenuScopeV1', 'inputBridge_pushTouchMenuToolV1',
  'inputBridge_retireTouchMenuToolScopeV1',
  'inputBridge_publishTouchMenuCursorV1', 'inputBridge_glfwSetTargetV1',
  'inputBridge_sdlSetTargetV1', 'inputBridge_notifyFramePresentedForTargetV1',
  'inputBridge_sdlNotifyFramePresentedForTargetV1',
  'inputBridge_publishTouchMenuScrollV1', 'inputBridge_pushTouchMenuToolScrollV1',
  'inputBridge_publishTouchMenuToolCursorV1',
  'inputBridge_configureMenuCursorConsumerV1', 'inputBridge_getCommittedMenuCursorV1',
  'inputBridge_legacyRingDiscontinuityEpochV1',
  'inputBridge_beginGlfwMenuCursorV1', 'inputBridge_completeGlfwMenuCursorV1',
  'inputBridge_publishTouchMenuToolRelativeV1', 'inputBridge_publishTouchMenuRelativeV1',
  'inputBridge_setCursorReceiptCallbackV1',
  'inputBridge_readSurfaceContextV1',
  'inputBridgeStartPumping', 'inputBridgePumpEvents', 'inputBridgeStopPumping',
  'Java_org_lwjgl_glfw_CallbackBridge_nativeSendKey',
];

// 此表约束真实在役caller的强引用，不能把“neutral保留兼容导出”误当“entry仍应调用”。
// toolCursor绝对兼容入口只要求上表neutral定义；Native面板真实移动走toolRelative，不能为门禁造空引用。
// 相对通道/ACK/局选择及ring不连续读取仍必须强链接；弱符号、声明、env文字或dlsym不证明接线。
export const INPUT_SCOPED_IMPORTS = {
  'libentry.so': ['inputBridge_retireTouchMenuScopeV1', 'inputBridge_pushTouchMenuToolV1',
    'inputBridge_publishTouchMenuCursorV1', 'inputBridge_retireTouchMenuToolScopeV1',
    'inputBridge_publishTouchMenuScrollV1', 'inputBridge_pushTouchMenuToolScrollV1',
    'inputBridge_configureMenuCursorConsumerV1', 'inputBridge_legacyRingDiscontinuityEpochV1',
    'inputBridge_getCommittedMenuCursorV1', 'inputBridge_publishTouchMenuToolRelativeV1',
    'inputBridge_publishTouchMenuRelativeV1', 'amclInputOwnerReadTextResourceV1', 'amclInputOwnerL2KeyboardScopeV1'],
  'libglfw.so': ['inputBridge_glfwSetTargetV1', 'inputBridge_notifyFramePresentedForTargetV1',
    'inputBridge_beginGlfwMenuCursorV1', 'inputBridge_completeGlfwMenuCursorV1',
    'inputBridge_setCursorReceiptCallbackV1', 'inputBridge_readSurfaceContextV1',
    'inputBridge_setLookPrefixCallbackV1'],
};

// 只解析声明，不执行CMake。词法器保留引号内容，忽略行/块注释，按真实括号层级
// 读取命令；变量引用递归展开为所有静态可能值，条件分支采用并集以免漏掉第二归属。
function cmakeCommands(text) {
  const commands = [];
  let at = 0;
  const skip = () => {
    for (;;) {
      while (/\s/.test(text[at] ?? '') && at < text.length) at += 1;
      if (text[at] !== '#') return;
      const bracket = text.slice(at + 1).match(/^\[(=*)\[/);
      if (bracket) {
        const end = text.indexOf(`]${bracket[1]}]`, at + bracket[0].length + 1);
        if (end < 0) throw new Error('unterminated CMake bracket comment');
        at = end + bracket[1].length + 2;
      } else {
        const end = text.indexOf('\n', at);
        at = end < 0 ? text.length : end + 1;
      }
    }
  };
  while (at < text.length) {
    skip();
    if (at >= text.length) break;
    const name = text.slice(at).match(/^([A-Za-z_]\w*)\s*\(/);
    if (!name) throw new Error(`unparsed CMake statement at ${at}`);
    at += name[0].length;
    const args = [];
    let token = '', quote = false, depth = 1;
    while (at < text.length && depth > 0) {
      const char = text[at];
      if (!quote && char === '#') { skip(); continue; }
      if (char === '"') { quote = !quote; at += 1; continue; }
      if (char === '\\' && quote && at + 1 < text.length) {
        token += char + text[at + 1]; at += 2; continue;
      }
      if (!quote && char === '(') { depth += 1; token += char; at += 1; continue; }
      if (!quote && char === ')') {
        depth -= 1; at += 1;
        if (depth === 0) break;
        token += char; continue;
      }
      if (!quote && /\s/.test(char)) {
        if (token) args.push(token);
        token = ''; at += 1; continue;
      }
      token += char; at += 1;
    }
    if (depth !== 0 || quote) throw new Error(`unterminated CMake command ${name[1]}`);
    if (token) args.push(token);
    commands.push({ name: name[1].toLowerCase(), args });
  }
  return commands;
}

function staticVariables(commands) {
  const vars = new Map();
  for (const { name, args } of commands) {
    const values = name === 'set' ? args.slice(1) :
      name === 'list' && args[0]?.toUpperCase() === 'APPEND' ? args.slice(2) : null;
    const key = name === 'set' ? args[0] : args[1];
    if (values && key) vars.set(key, [...(vars.get(key) ?? []), ...values]);
  }
  return token => {
    const expand = (value, seen = new Set()) => {
      const exact = value.match(/^\$\{([^}]+)\}$/);
      if (!exact || !vars.has(exact[1]) || seen.has(exact[1])) return [value];
      const next = new Set(seen).add(exact[1]);
      return vars.get(exact[1]).flatMap(item => expand(item, next));
    };
    return expand(token);
  };
}

const forbiddenDependency = value => /(?:^|[/:;$<>])(?:lib)?(?:entry|glfw|SDL\w*|mobilegl\w*|amcl_gl_host|GLv4|EGL|GLES\w*)(?:\.so|$|[>;$])/i.test(value);
// 两项在役私有source/look owner同属neutral；consumer不得借遗漏的命名前缀定义第二份端口。
const runtimeDefinition = name => /^(?:amclInput|amclBackendInput|amclControlDelivery|amclSourceControl|amclLook|inputBridge|Java_org_lwjgl_glfw_CallbackBridge_)/.test(name);

/** 源码合同只接受能枚举的目标声明；重要TU必须恰好归属于中立target。 */
export function inputRuntimeSourceIssues(cmake, versionScript) {
  const issues = [];
  let commands;
  try { commands = cmakeCommands(cmake); }
  catch (error) { return [`CMake parse failed: ${error.message}`]; }
  const expand = staticVariables(commands);
  const sources = new Map(), links = new Map(), definitions = new Map();
  for (const { name, args } of commands) {
    const target = args[0];
    if (name === 'add_library' || name === 'target_sources') {
      sources.set(target, [...(sources.get(target) ?? []), ...args.slice(1).flatMap(expand)]);
    }
    if (name === 'target_link_libraries') {
      links.set(target, [...(links.get(target) ?? []), ...args.slice(1).flatMap(expand)]);
    }
    if (name === 'target_compile_definitions') {
      definitions.set(target, [...(definitions.get(target) ?? []), ...args.slice(1).flatMap(expand)]);
    }
  }
  for (const source of INPUT_OWNER_SOURCES) {
    const owners = [...sources].flatMap(([owner, entries]) => entries.filter(value =>
      value.replaceAll('\\', '/').replace(/^\.\//, '') === source || value.endsWith(`/${source}`)).map(() => owner));
    if (owners.length !== 1 || owners[0] !== 'amcl_input_runtime') {
      issues.push(`${source}: unique owner must be amcl_input_runtime (actual=${owners.join(',') || 'missing'})`);
    }
  }
  for (const target of ['glfw', 'entry']) {
    if (!(links.get(target) ?? []).includes('amcl_input_runtime')) {
      issues.push(`${target}: missing direct neutral input dependency`);
    }
  }
  const runtimeLinks = links.get('amcl_input_runtime') ?? [];
  if (runtimeLinks.length === 0) issues.push('amcl_input_runtime: missing explicit dependency closure');
  for (const value of runtimeLinks) {
    if (forbiddenDependency(value)) issues.push(`amcl_input_runtime: frontend/renderer dependency ${value}`);
  }
  if (!runtimeLinks.includes('amcl_graphics_runtime')) issues.push('amcl_input_runtime: missing neutral presentation-event dependency');
  for (const flag of INPUT_BUILD_FLAGS) {
    const values = target => (definitions.get(target) ?? []).filter(item => item.startsWith(`${flag}=`));
    const owner = values('amcl_input_runtime'), frontend = values('glfw');
    if (owner.length !== 1 || frontend.length !== 1 || owner[0] !== frontend[0] ||
        owner[0] !== `${flag}=${INPUT_BUILD_VALUES[flag]}`) {
      issues.push(`${flag}: runtime/GLFW compile closure mismatch (${owner.join('|')} vs ${frontend.join('|')})`);
    }
  }
  // version script保持C ABI兼容，同时不得放出C++状态或GLFW/renderer实现。
  const script = versionScript.replace(/#[^\n]*/g, '');
  const global = script.match(/global\s*:\s*([\s\S]*?)local\s*:/)?.[1] ?? '';
  const patterns = global.split(';').map(value => value.trim()).filter(Boolean);
  for (const required of ['amclInput*', 'amclBackendInput*', 'inputBridge_*', 'Java_org_lwjgl_glfw_CallbackBridge_*']) {
    if (!patterns.includes(required)) issues.push(`runtime version script missing ${required}`);
  }
  // 新私有port是明确V1符号向量；漏export不能由旧通配/源码字符串猜成就绪。
  const privatePortVersionCode = versionScript.replace(/#.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  for (const required of ['amclControlDeliveryGetPortV1', 'amclControlDeliveryBindSessionV1', 'amclControlDeliveryPublishV1']) {
    if (!new RegExp(`\\b${required}\\s*;`).test(privatePortVersionCode)) issues.push(`runtime missing explicit private control port export ${required}`);
  }
  for (const required of ['amclSourceControlGetPortV1','amclSourceControlPublishV1','amclSourceControlPrepareV1',
    'amclSourceControlCompatEdgeV1','amclSourceControlDrainTerminalsV1']) {
    if (!new RegExp(`\\b${required}\\s*;`).test(privatePortVersionCode)) issues.push(`runtime missing explicit private source port export ${required}`);
  }
  for (const pump of ['inputBridgeStartPumping', 'inputBridgePumpEvents', 'inputBridgeStopPumping']) {
    if (!patterns.includes(pump) && !patterns.includes('inputBridge*')) {
      issues.push(`runtime version script missing non-underscore compatibility ABI ${pump}`);
    }
  }
  if (!/local\s*:\s*\*\s*;/.test(script)) issues.push('runtime version script must hide private symbols');
  if (patterns.some(value => value === '*' || /^(?:glfw|egl|gl[A-Z]|SDL_|_Z)/.test(value))) {
    issues.push('runtime version script exports frontend/renderer/private C++ surface');
  }
  return issues;
}

/** 标记必须具有完整字段和结束符。只出现字符串前缀或日志format不算能力证据。 */
export function inputBuildMarkers(bytes) {
  const matches = bytes.toString('latin1').match(/AMCL_INPUT_BUILD_V1\|typed=[01]\|relative=[01]\|absolute=[01]\|monotonic=[01]\|api26Raw=[01]\|evidence=[^\0\r\n]{1,4096}?\|END/g) ?? [];
  return [...new Set(matches)];
}

// 原文字Core hook组保持既有精确规则；下面的新Keyboard组另列当前生产契约，
// 两组都不能把nm basename或amclInput族名当动态ABI资格。
const TEXT_CORE_HOOKS = ['amclInputOwnerReadTextResourceV1', 'amclInputOwnerValidateTextScopeV1'];
// 每个名字对应当前public/default声明或生产default C端口；无消费者的host诊断getter
// 不属于这一组。保留旧textHookDynsym字段作为审计格式，新增行仍从真实完整dynsym提取。
const KEYBOARD_OWNER_HOOKS = [
  'amclInputL2KeyboardGetPortV1', 'amclInputL2KeyboardPublishV1',
  'amclInputOwnerL2KeyboardScopeV1', 'amclInputOwnerCompareL2KeyboardScopeV1',
  'amclInputOwnerSelectKeyboardBackendV1', 'amclInputOwnerSelectedKeyboardBackendV1',
  'amclInputOwnerReadL2KeyStampV1', 'amclInputOwnerReadL2HeldKeyV1',
  'amclBackendInputL2ReadKeyScopeV1', 'inputBridge_pushKeyScopedV1',
];
// 仅TRACE产品需要的真实跨DSO诊断定义；不能加入无条件ABI表而要求关闭产品保留它们。
export const INPUT_LATENCY_HOOKS = ['inputBridge_formatInputLatencyV1', 'inputBridge_noteInputLatencyV1',
  'inputBridge_finishInputLatencyV1', 'inputBridge_drainInputLatencyV1', 'inputBridge_finishInputLatencyTicketV1',
  'inputBridge_getInputLatencyPortV2'];
// 这些名字是runtime内的采集实现，不是跨DSO协议；amclInput*既有通配不能替代hidden。
// ON/OFF包都不得给外部留下这些动态符号，否则caller可绕过真实bridge owner去记另一表。
export const INPUT_LATENCY_INTERNAL_HOOKS = ['amclInputLatencyBeginV1','amclInputLatencyEndV1',
  'amclInputLatencyCurrentV1','amclInputLatencyAcceptV1','amclInputLatencyNoteV1',
  'amclInputLatencyFinishV1','amclInputLatencyDrainV1','amclInputLatencyFinishTicketV1',
  'amclInputLatencyConfigureBackendV2','amclInputLatencyNoteBackendV2','amclInputLatencyFinishBackendV2'];
const LATENCY_READERS = {
  'libentry.so': ['inputBridge_formatInputLatencyV1', 'inputBridge_drainInputLatencyV1'],
  // 新caller只强借原票qualified终态；旧prefix口仍由neutral保留，不能为门禁造旧空调用。
  'libglfw.so': ['inputBridge_noteInputLatencyV1', 'inputBridge_finishInputLatencyTicketV1'],
};
const OWNER_RUNTIME_HOOKS = [...TEXT_CORE_HOOKS, ...KEYBOARD_OWNER_HOOKS, ...INPUT_LATENCY_HOOKS,
  ...INPUT_LATENCY_INTERNAL_HOOKS];
/** 从本次HAP实际product-profile核对原诊断政策；未知/不一致元数据不能默认为OFF成功。 */
export function inputRuntimeDiagnosticPolicy(metadata) {
  try {
    const build = metadata?.build;
    if (!Array.isArray(build?.diagnostics)) throw new Error('missing diagnostics declaration');
    const expected = diagnosticProfile(metadata.name, build.mode, build.diagnostics.join(','));
    return { inputTraceEnabled: expected.flags.AMCL_INPUT_TRACE === 'ON',
      issues: evaluateDiagnosticMetadata(build, expected, metadata.name) };
  } catch (error) {
    return { inputTraceEnabled: false, issues: [`invalid diagnostic product policy: ${error.message}`] };
  }
}
/** 保存真实dynsym十进制ordinal；LLVM名字没有版本索引，不能从name@版本反猜提供者。 */
export function textHookDynsym(text) {
  return text.split(/\r?\n/).flatMap(line => {
    const row = line.trim().match(/^(\d+):\s+([0-9a-fA-F]+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/);
    return row && OWNER_RUNTIME_HOOKS.includes(row[8].split('@')[0]) ? [{ symbolIndex: Number(row[1]),
      value: row[2], size: Number(row[3]), type: row[4], bind: row[5], visibility: row[6],
      section: row[7], name: row[8] }] : [];
  });
}

/** 解析同一次LLVM version-info的两个原段。table行起点/版本值为十六进制，VERNEED
 * Version为十进制；按ordinal连续完整校验，不用版本名称把一个File的证据贴到另一索引。
 * 对缺段、乱序/重复、无法解析或重复provider索引失败关闭。只供包审核，不影响生产输入。
 */
export function inputRuntimeSymbolVersions(symbolsText, needsText) {
  const issues = [], symbols = {}, needs = [];
  const header = symbolsText?.match(/contains\s+(\d+)\s+entries:/);
  const count = header ? Number(header[1]) : -1;
  if (!Number.isSafeInteger(count) || count < 1 || !/Link:\s+\d+\s+\(\.dynsym\)/.test(symbolsText ?? ''))
    issues.push('missing exact .gnu.version/dynsym identity');
  let next = 0;
  for (const line of (symbolsText ?? '').split(/\r?\n/)) {
    const row = line.match(/^\s*([0-9a-fA-F]+):\s*(.*)$/);
    if (!row) continue;
    const start = Number.parseInt(row[1],16);
    const entries = [...row[2].matchAll(/\b([0-9a-fA-F]+)(h?)\s*\(([^)]*)\)/g)];
    const residue = row[2].replace(/\b([0-9a-fA-F]+)(h?)\s*\(([^)]*)\)/g,'').trim();
    if (start !== next || !entries.length || residue) issues.push('invalid ordinal sequence in .gnu.version');
    for (const [offset,entry] of entries.entries()) {
      const ordinal = start + offset, raw = Number.parseInt(entry[1],16);
      if (!Number.isSafeInteger(raw) || raw > 0xffff || Object.hasOwn(symbols,ordinal))
        issues.push('invalid/duplicate symbol version ordinal');
      symbols[ordinal] = { versionIndex: raw & 0x7fff, hidden: entry[2] === 'h' || (raw & 0x8000) !== 0,
        name: entry[3].trim() };
    }
    next = start + entries.length;
  }
  if (next !== count || Object.keys(symbols).length !== count) issues.push('incomplete .gnu.version table');
  let file = '';
  for (const token of (needsText ?? '').matchAll(/File:\s+(\S+)|Name:\s+(\S+)\s+Flags:\s+(\S+)\s+Version:\s+(\d+)/g)) {
    if (token[1]) { file = token[1]; continue; }
    const versionIndex = Number(token[4]);
    if (!file || versionIndex < 2 || !Number.isSafeInteger(versionIndex) || needs.some(item => item.versionIndex === versionIndex))
      issues.push('invalid/duplicate VERNEED provider index');
    needs.push({ file, name: token[2], flags: token[3], versionIndex });
  }
  if (!needs.length) issues.push('missing VERNEED providers');
  return { symbols, needs, issues };
}

/** 一个真实reader必须以自己的ordinal取VERSYM，再精确取对应VERNEED File/Name。
 * strong U与FUNC/DEFAULT/UND保持既有契约；同名版本存在于neutral其它索引绝不能授予资格。
 */
export function inputRuntimeReaderIsBound(image, row, versions) {
  if (versions.issues.length || !Number.isSafeInteger(row?.symbolIndex) || row.symbolIndex < 0 ||
      row.type !== 'FUNC' || row.bind !== 'GLOBAL' || row.visibility !== 'DEFAULT' || row.section !== 'UND') return false;
  const version = versions.symbols[row.symbolIndex];
  const providers = versions.needs.filter(item => item.versionIndex === version?.versionIndex);
  return version?.versionIndex >= 2 && version.name === 'AMCL_INPUT_RUNTIME' && providers.length === 1 &&
    providers[0].file === 'libamcl_input_runtime.so' && providers[0].name === 'AMCL_INPUT_RUNTIME' &&
    (image.strongUndefined ?? []).includes(row.name.split('@')[0]);
}

/** 产物判据基于真实dynsym，不把UND、.rodata符号名或源码声明当实现存在。 */
export function inputRuntimeArtifactIssues(images, diagnosticPolicy) {
  const issues = [];
  if (typeof diagnosticPolicy?.inputTraceEnabled !== 'boolean' || !Array.isArray(diagnosticPolicy?.issues))
    issues.push('missing verified diagnostic product policy');
  else issues.push(...diagnosticPolicy.issues);
  const runtime = images['libamcl_input_runtime.so'];
  const names = ['libamcl_input_runtime.so', 'libglfw.so', 'libentry.so'];
  for (const name of names) {
    const image = images[name];
    if (!image) { issues.push(`${name}: missing HAP member`); continue; }
    if (image.machine !== 183 || image.soname !== name) issues.push(`${name}: wrong architecture/SONAME`);
    if (!image.runpath?.some(value => value.split(':').includes('$ORIGIN'))) issues.push(`${name}: missing sibling RUNPATH`);
    if (image.runpath?.some(value => /[A-Za-z]:[\\/]/.test(value))) issues.push(`${name}: host path in RUNPATH`);
    if (!Array.isArray(image.exports) || !Array.isArray(image.needed)) issues.push(`${name}: incomplete ELF evidence`);
  }
  if (issues.length) return issues;
  const versions = Object.fromEntries(names.map(name => [name,
    inputRuntimeSymbolVersions(images[name].textHookVersionSymbols, images[name].textHookVersionNeeds)]));
  // ON核函数定义、实际调用者强UND和version provider；OFF核同包诊断符号与记录正文裁剪。
  // 正文只作编译保留/裁剪证明，不表示真正运行、单调钟开销或游戏已经采用输入。
  for (const name of names) {
    const image = images[name];
    for (const symbol of INPUT_LATENCY_INTERNAL_HOOKS)
      if (image.exports.includes(symbol) || (image.undefined ?? []).includes(symbol) ||
          (image.strongUndefined ?? []).includes(symbol) || (image.textHookDynsym ?? []).some(row => row.name.split('@')[0] === symbol))
        issues.push(`${name}: internal latency implementation leaks dynamic ABI ${symbol}`);
    const expectedText = diagnosticPolicy.inputTraceEnabled && name !== 'libglfw.so';
    if (image.latencyDiagnosticTextPresent !== expectedText)
      issues.push(`${name}: latency diagnostic body inclusion mismatch`);
    if (!diagnosticPolicy.inputTraceEnabled) {
      for (const symbol of INPUT_LATENCY_HOOKS)
        if (image.exports.includes(symbol) || image.undefined.includes(symbol) ||
            image.strongUndefined.includes(symbol) || (image.textHookDynsym ?? []).some(row => row.name.split('@')[0] === symbol))
          issues.push(`${name}: TRACE OFF retains latency diagnostic ABI ${symbol}`);
      continue;
    }
    if (name === 'libamcl_input_runtime.so') {
      for (const symbol of INPUT_LATENCY_HOOKS) {
        const rows = (image.textHookDynsym ?? []).filter(row => row.name === `${symbol}@@AMCL_INPUT_RUNTIME` &&
          row.type === 'FUNC' && row.bind === 'GLOBAL' && row.visibility === 'DEFAULT' &&
          /^[1-9]\d*$/.test(row.section) && !/^0+$/.test(row.value) && row.size > 0);
        if (!image.exports.includes(symbol) || rows.length !== 1)
          issues.push(`runtime missing exact strong default versioned latency diagnostic hook ${symbol}`);
      }
    } else {
      for (const symbol of INPUT_LATENCY_HOOKS)
        if (image.exports.includes(symbol)) issues.push(`${name}: duplicates runtime latency diagnostic ABI ${symbol}`);
      for (const symbol of LATENCY_READERS[name]) {
        const readers = (image.textHookDynsym ?? []).filter(row => row.name === `${symbol}@AMCL_INPUT_RUNTIME` &&
          row.type === 'FUNC' && row.bind === 'GLOBAL' && row.visibility === 'DEFAULT' && row.section === 'UND');
        if (readers.length !== 1 || !inputRuntimeReaderIsBound(image,readers[0],versions[name]))
          issues.push(`${name}: missing exact version-bound strong latency diagnostic reader ${symbol}`);
      }
    }
  }
  for (const symbol of INPUT_RUNTIME_EXPORTS) {
    if (!runtime.exports.includes(symbol)) issues.push(`runtime missing defined ABI ${symbol}`);
  }
  for (const symbol of TEXT_CORE_HOOKS) {
    const rows = (runtime.textHookDynsym ?? []).filter(row => row.name === `${symbol}@@AMCL_INPUT_RUNTIME` &&
      row.type === 'FUNC' && row.bind === 'GLOBAL' && row.visibility === 'DEFAULT' &&
      /^\d+$/.test(row.section) && !/^0+$/.test(row.value) && row.size > 0);
    if (rows.length !== 1) issues.push(`runtime missing exact strong default versioned text hook ${symbol}`);
  }
  // Getter字符串、nm去版本basename、weak或UND行均不能证明新owner实现存在；必须是
  // 同一neutral的唯一强default版本FUNC。数值section要求非0，拒绝ABS/UND和伪造零槽。
  for (const symbol of KEYBOARD_OWNER_HOOKS) {
    const rows = (runtime.textHookDynsym ?? []).filter(row => row.name === `${symbol}@@AMCL_INPUT_RUNTIME` &&
      row.type === 'FUNC' && row.bind === 'GLOBAL' && row.visibility === 'DEFAULT' &&
      /^[1-9]\d*$/.test(row.section) && !/^0+$/.test(row.value) && row.size > 0);
    if (rows.length !== 1) issues.push(`runtime missing exact strong default versioned keyboard owner hook ${symbol}`);
  }
  const entryReader = (images['libentry.so'].textHookDynsym ?? []).filter(row =>
    row.name === 'amclInputOwnerReadTextResourceV1@AMCL_INPUT_RUNTIME' && row.type === 'FUNC' &&
    row.bind === 'GLOBAL' && row.visibility === 'DEFAULT' && row.section === 'UND');
  // version_r必须把所需版本绑定到本次所选neutral的SONAME；目录外同名/global dlsym无效。
  if (entryReader.length !== 1 || !inputRuntimeReaderIsBound(images['libentry.so'],entryReader[0],versions['libentry.so']))
    issues.push('libentry.so: missing exact version-bound strong text resource reader');
  // NAPI在Source prepare之前直接读取唯一Core的原键资格。只有这个真实entry调用点
  // 要求强UND与version_r；L2 SO使用私有getter解析，不对它捏造neutral强import/NEEDED。
  const entryKeyboardReader = (images['libentry.so'].textHookDynsym ?? []).filter(row =>
    row.name === 'amclInputOwnerL2KeyboardScopeV1@AMCL_INPUT_RUNTIME' && row.type === 'FUNC' &&
    row.bind === 'GLOBAL' && row.visibility === 'DEFAULT' && row.section === 'UND');
  if (entryKeyboardReader.length !== 1 || !inputRuntimeReaderIsBound(images['libentry.so'],entryKeyboardReader[0],versions['libentry.so']))
    issues.push('libentry.so: missing exact version-bound strong keyboard scope reader');
  for (const name of ['libglfw.so', 'libentry.so']) {
    const image = images[name];
    if (!image.needed.includes('libamcl_input_runtime.so')) issues.push(`${name}: missing physical input runtime dependency`);
    for (const symbol of INPUT_SCOPED_IMPORTS[name]) {
      if (!(image.strongUndefined ?? []).includes(symbol)) issues.push(`${name}: missing strong scoped ABI ${symbol}`);
    }
    for (const symbol of image.exports) {
      if (runtimeDefinition(symbol)) issues.push(`${name}: duplicates runtime definition ${symbol}`);
    }
  }
  for (const dependency of runtime.needed) {
    if (forbiddenDependency(dependency)) issues.push(`runtime has frontend/renderer DT_NEEDED ${dependency}`);
  }
  for (const symbol of runtime.undefined ?? []) {
    if (/^(?:glfw|SDL_|egl[A-Z]|gl[A-Z]|mg_|ohos_send_)/.test(symbol)) issues.push(`runtime has reverse undefined symbol ${symbol}`);
  }
  for (const symbol of runtime.exports) {
    if (/^(?:glfw|SDL_|egl[A-Z]|gl[A-Z]|_Z)/.test(symbol)) issues.push(`runtime leaks frontend/renderer/private C++ symbol ${symbol}`);
  }
  if (!runtime.needed.includes('libamcl_graphics_runtime.so')) issues.push('runtime missing physical presentation-event dependency');
  const glfw = images['libglfw.so'];
  // GLFW控制handle与look prefix均归发布owner。强链接到namespace本地getter/本地Core
  // readiness会重新形成实际双image分叉；新callback setter仍必须真实强导入neutral。
  for (const local of ['amclLookExecutionGetPortV1', 'amclInputOwnerLookCommitReadyV1']) {
    if ((glfw.strongUndefined ?? []).includes(local)) issues.push(`GLFW look consumer directly imports namespace-local owner ${local}`);
  }
  if (!glfw.exports.includes('glfwOHOS_InputBuildIdentityV1')) issues.push('GLFW missing defined input build identity ABI');
  if (runtime.markers?.length !== 1 || glfw.markers?.length !== 1) {
    issues.push('runtime/GLFW require exactly one complete input build marker each');
  } else if (runtime.markers[0] !== glfw.markers[0]) {
    issues.push('runtime/GLFW input build markers disagree');
  } else if (!/^AMCL_INPUT_BUILD_V1\|typed=1\|relative=1\|absolute=[01]\|monotonic=[01]\|api26Raw=1\|/.test(runtime.markers[0])) {
    issues.push('input build marker does not match shipping typed/relative/API26 compile ceilings');
  }
  return issues;
}

/** 从真实HAP解包到已验证的外置目录，保存可复核的ELF身份、符号和错误。 */
export function auditInputRuntimeArtifact(hap, output) {
  output = assertExternalOutputPath(output);
  fs.mkdirSync(output, { recursive: true });
  const zip = fs.readFileSync(hap), images = {};
  const metadata = JSON.parse(readUniqueZipEntry(zip, 'resources/rawfile/product-profile.json'));
  const diagnosticPolicy = inputRuntimeDiagnosticPolicy(metadata);
  const llvm = process.env.AMCL_LLVM_BIN || 'D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin';
  const exe = name => path.join(llvm, name + (process.platform === 'win32' ? '.exe' : ''));
  for (const name of ['libamcl_input_runtime.so', 'libglfw.so', 'libentry.so']) {
    const bytes = readUniqueZipEntry(zip, `libs/arm64-v8a/${name}`);
    const local = path.join(output, name);
    fs.writeFileSync(local, bytes);
    const dynamic = execFileSync(exe('llvm-readelf'), ['-d', local], { encoding: 'utf8' });
    const symbols = flag => execFileSync(exe('llvm-nm'), ['--dynamic', flag, local], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    const exported = symbols('--defined-only'), undefinedText = symbols('--undefined-only');
    const dynsym = execFileSync(exe('llvm-readelf'), ['--dyn-syms', '--wide', local], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    const versions = execFileSync(exe('llvm-readelf'), ['--version-info', '--wide', local], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    fs.writeFileSync(path.join(output, name + '.text-hook-dynsym.txt'), dynsym);
    fs.writeFileSync(path.join(output, name + '.text-hook-versions.txt'), versions);
    const names = text => text.split(/\r?\n/).filter(line => line.trim())
      .map(line => line.trim().split(/\s+/).pop().split('@')[0]);
    images[name] = { ...readElfIdentity(bytes), size: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      needed: [...dynamic.matchAll(/\(NEEDED\).*?\[([^\]]+)\]/g)].map(match => match[1]),
      runpath: [...dynamic.matchAll(/\((?:RUNPATH|RPATH)\).*?\[([^\]]+)\]/g)].map(match => match[1]),
      exports: names(exported), undefined: names(undefinedText),
      // llvm-nm强未定义符号类型为大写U；小写w/v等弱引用不能满足本轮跨DSO能力的强链接合同。
      strongUndefined: names(undefinedText.split(/\r?\n/).filter(line =>
        line.trim().split(/\s+/).slice(-2, -1)[0] === 'U').join('\n')),
      textHookDynsym: textHookDynsym(dynsym),
      // 与上面的dynsym同一实际ELF、同一次version-info。保存原symbol表，不截成name清单。
      textHookVersionSymbols: (versions.split('Version symbols section')[1] ?? '').split(/\nVersion (?:definition|needs) section/)[0],
      textHookVersionNeeds: versions.split('Version needs section')[1] ?? '',
      latencyDiagnosticTextPresent: bytes.includes(Buffer.from(name === 'libentry.so' ? 'ILAT1_SUM n=' : 'ILAT1 id=')),
      markers: inputBuildMarkers(bytes) };
  }
  const issues = inputRuntimeArtifactIssues(images, diagnosticPolicy);
  const report = { schema: 1, hap: path.resolve(hap),
    hapSha256: createHash('sha256').update(zip).digest('hex'), diagnosticPolicy, images, issues,
    verdict: issues.length ? 'FAIL' : 'PASS', scope: 'HAP input ownership/linkage/compile identity; not device input acceptance' };
  fs.writeFileSync(path.join(output, 'input-runtime.json'), `${JSON.stringify(report, null, 2)}\n`);
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const arg = flag => { const at = process.argv.indexOf(flag); return at < 0 ? '' : process.argv[at + 1]; };
    const root = path.resolve(arg('--root') || ROOT);
    const issues = inputRuntimeSourceIssues(
      fs.readFileSync(path.join(root, 'entry/src/main/cpp/CMakeLists.txt'), 'utf8'),
      fs.readFileSync(path.join(root, 'entry/src/main/cpp/input/input_runtime.version'), 'utf8'));
    if (arg('--hap')) {
      issues.push(...auditInputRuntimeArtifact(path.resolve(arg('--hap')),
        arg('--out') || workspacePath('run', 'input-runtime-artifact')).issues);
    }
    console.log(`[input-runtime-boundary] ${issues.length ? 'FAIL' : 'PASS'} ${arg('--hap') ? 'source+HAP' : 'source-only'}`);
    if (issues.length) { console.error(issues.join('\n')); process.exitCode = 1; }
  } catch (error) { console.error(`[input-runtime-boundary] ERROR: ${error.message}`); process.exitCode = 2; }
}

#!/usr/bin/env node
// Gate F（菜单 absolute / legacy 退役）源码就绪门禁。
//
// 这道门不批准任何设备事实，也不打开 bit14。它只回答一个更窄的问题：
//   “如果有人开始批准 native absolute / timestamp 证据，或把 bit14 写进产品配置，
//    代码是否已经具备不拆分 absolute→button、且三个后端都能消费的完整形状？”
//
// 状态只有三种：
//   DORMANT  两份证据均未批准，产品配置也未尝试打开 bit14。允许尚未完成迁移；
//            这是当前出货的安全状态，不得被表述为 Gate F 已完成。
//   BLOCKED  已有人开始切换，但下面任一先决条件没有机械证据；退出码为 1。
//   READY    切换已开始，且四组源码契约全部存在。它仍不等于真机通过；证据内容、
//            哈希、设备矩阵与批准人继续由 check-gate0-evidence.mjs / CMake 门禁负责。
//
// 四组先决条件：
//   1. owner 原子路由：真实 ArkUI/native 竞争入口都进入同一个 menu transaction，
//      并有 route-aware owner 测试，而不是只对 ingress 直调做测试；
//   2. 三后端组合 transaction：GLFW、SDL3、LWJGL2 都消费不可拆的 pointer transaction；
//   3. physical legacy 退役：要么删除旧物理 writer，要么以产品作用域契约 + host test
//      证明它只属于 compatibility 构建；
//   4. touch MENU_POINTER：允许继续明确保留 token/present-barrier 合同，或以 typed
//      等价 transaction 完整替换。物理 bit14 不能顺手删除触摸点击协议。
//
// 为什么不用一句 `AMCL_GATE_F_READY=1`：那只能证明有人写了一个 1。下面每组都跨生产者、
// 适配器、消费端与测试查实际符号；注释/字符串字面量会先被剥掉。SDL 的既有合同按
// series 顺序抵消后续删除行；新 Gate F 消费代码只接受 series 最后一个具名
// gate-f-pointer-transaction patch 的新增行，避免墓碑或后续删除伪造就绪。

import {
  existsSync, readFileSync, readdirSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));

export const GATE_F_CAPABILITIES = {
  absolute: 'AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED',
  timestamp: 'AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED',
};

export const GATE_F_SOURCE_PATHS = {
  manifest: 'gate0-evidence.lock',
  profile: 'entry/build-profile.json5',
  policyHeader: 'entry/src/main/cpp/platform/input_channel_policy.h',
  policySource: 'entry/src/main/cpp/platform/input_channel_policy.cpp',
  policyTest: 'entry/src/main/cpp/tests/host/input_channel_policy_test.cpp',
  nativeRouteHeader: 'entry/src/main/cpp/platform/native_mouse_route_policy.h',
  nativeRouteSource: 'entry/src/main/cpp/platform/native_mouse_route_policy.cpp',
  ingressHeader: 'entry/src/main/cpp/input/platform_input_ingress.h',
  ingressSource: 'entry/src/main/cpp/input/platform_input_ingress.cpp',
  touch: 'entry/src/main/cpp/platform/touch_input.cpp',
  napi: 'entry/src/main/cpp/napi/napi_input.cpp',
  page: 'entry/src/main/ets/pages/McGamePage.ets',
  eventHeader: 'entry/src/main/cpp/input/amcl_input_event.h',
  adapterHeader: 'entry/src/main/cpp/input/adapters/glfw_input_adapter.h',
  adapterSource: 'entry/src/main/cpp/input/adapters/glfw_input_adapter.cpp',
  backendHeader: 'entry/src/main/cpp/input/adapters/backend_input_bridge.h',
  backendSource: 'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp',
  glfw: 'entry/src/main/cpp/glfw/glfw_compat.cpp',
  lwjglBridge: 'entry/src/main/cpp/glfw/input_bridge_ohos.c',
  pointerTransaction: 'entry/src/main/cpp/input/delivery/pointer_transaction.h',
  lwjglTranslateHeader: 'entry/src/main/cpp/input/adapters/lwjgl2_event_translate.h',
  lwjglTranslateSource: 'entry/src/main/cpp/input/adapters/lwjgl2_event_translate.cpp',
  backendPointerTest: 'entry/src/main/cpp/tests/host/backend_pointer_transaction_test.cpp',
  physicalLegacyTest: 'entry/src/main/cpp/tests/host/gate_f_physical_legacy_contract_test.cpp',
  hostCmake: 'entry/src/main/cpp/tests/host/CMakeLists.txt',
  sdlSeries: 'prebuilt/sdl3/patches/series',
};

function readText(root, relative, missing) {
  const absolute = join(root, relative);
  if (!existsSync(absolute)) {
    missing.push(relative);
    return '';
  }
  return readFileSync(absolute, 'utf8');
}

// Build two conservative source views without pretending that concatenating
// patches is the same as applying them. `netText` removes an exact added line
// when a later patch deletes it; it is sufficient for the already-shipping
// legacy MENU_POINTER token contract. New Gate F SDL code is accepted only
// from one explicitly named final patch, so no later patch can silently delete
// it while an older `+token` remains visible to readiness.
export function analyzeSdlPatchViews(seriesText, patchTexts) {
  const names = String(seriesText ?? '').split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line !== '' && !line.startsWith('#') && line.endsWith('.patch'));
  const liveAddedLines = [];
  const addedByPatch = new Map();
  for (const name of names) {
    const text = patchTexts instanceof Map
      ? (patchTexts.get(name) ?? '')
      : (patchTexts?.[name] ?? '');
    const additions = [];
    for (const line of String(text).split(/\r?\n/)) {
      if (line.startsWith('+') && !line.startsWith('+++')) {
        const code = line.slice(1);
        liveAddedLines.push(code);
        additions.push(code);
      } else if (line.startsWith('-') && !line.startsWith('---')) {
        const code = line.slice(1);
        const liveIndex = liveAddedLines.lastIndexOf(code);
        if (liveIndex >= 0) liveAddedLines.splice(liveIndex, 1);
      }
    }
    addedByPatch.set(name, additions);
  }
  const finalName = names.at(-1) ?? '';
  const gateFFinalName = /gate-f-pointer-transaction\.patch$/i.test(finalName)
    ? finalName : '';
  return {
    names,
    netText: liveAddedLines.join('\n'),
    gateFFinalName,
    gateFFinalText: gateFFinalName
      ? (addedByPatch.get(gateFFinalName) ?? []).join('\n')
      : '',
  };
}

function readSdlPatchViews(root, seriesText, missing) {
  const patchRoot = join(root, 'prebuilt/sdl3/patches');
  const names = seriesText.split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line !== '' && !line.startsWith('#') && line.endsWith('.patch'));
  const patchTexts = new Map();
  for (const name of names) {
    const absolute = join(patchRoot, name);
    if (!existsSync(absolute)) {
      missing.push(`prebuilt/sdl3/patches/${name}`);
      continue;
    }
    patchTexts.set(name, readFileSync(absolute, 'utf8'));
  }
  return analyzeSdlPatchViews(seriesText, patchTexts);
}

export function readGateFSources(root = ROOT) {
  const missing = [];
  const texts = { missing };
  for (const [key, relative] of Object.entries(GATE_F_SOURCE_PATHS)) {
    texts[`${key}Text`] = readText(root, relative, missing);
  }
  const sdlViews = readSdlPatchViews(root, texts.sdlSeriesText, missing);
  texts.sdlPatchText = sdlViews.netText;
  texts.sdlGateFFinalPatchText = sdlViews.gateFFinalText;
  texts.sdlGateFFinalPatchName = sdlViews.gateFFinalName;
  return texts;
}

// 目标是让注释不能满足 readiness token。这里不是通用语言解析器；被检查的 token 都是
// C/C++/ArkTS 标识符，不依赖字符串字面量。字符串中的 `//` 对这些判据没有意义。
export function stripGateFComments(text, stripStrings = false) {
  const source = String(text ?? '');
  let out = '';
  let state = 'code';
  let quote = '';
  for (let index = 0; index < source.length; index += 1) {
    const ch = source[index];
    const next = source[index + 1] ?? '';
    if (state === 'line-comment') {
      if (ch === '\n' || ch === '\r') {
        state = 'code';
        out += ch;
      } else {
        out += ' ';
      }
      continue;
    }
    if (state === 'block-comment') {
      if (ch === '*' && next === '/') {
        out += '  ';
        index += 1;
        state = 'code';
      } else {
        out += (ch === '\n' || ch === '\r') ? ch : ' ';
      }
      continue;
    }
    if (state === 'string') {
      out += stripStrings && ch !== '\n' && ch !== '\r' ? ' ' : ch;
      if (ch === '\\') {
        if (index + 1 < source.length) {
          const escaped = source[++index];
          out += stripStrings && escaped !== '\n' && escaped !== '\r'
            ? ' ' : escaped;
        }
      } else if (ch === quote) {
        state = 'code';
        quote = '';
      }
      continue;
    }
    if (ch === '/' && next === '/') {
      out += '  ';
      index += 1;
      state = 'line-comment';
    } else if (ch === '/' && next === '*') {
      out += '  ';
      index += 1;
      state = 'block-comment';
    } else if (ch === '"' || ch === "'" || ch === '`') {
      out += stripStrings ? ' ' : ch;
      quote = ch;
      state = 'string';
    } else {
      out += ch;
    }
  }
  return out;
}

export const stripGateFCode = (text) => stripGateFComments(text, true);

const CMAKE_FALSE_VALUES = new Set([
  '', '0', 'n', 'no', 'off', 'false', 'ignore', 'notfound',
]);

export function gateFCmakeValueLooksEnabled(value) {
  const normalized = String(value ?? '').trim()
    .replace(/[\\"']/g, '').toLowerCase();
  if (CMAKE_FALSE_VALUES.has(normalized)) return false;
  return !normalized.endsWith('-notfound');
}

export function findGateFProfileEnablements(profileText) {
  const text = stripGateFComments(profileText);
  const capability = GATE_F_CAPABILITIES.absolute;
  const pattern = new RegExp(
    `-D\\s*${capability}(?::[A-Za-z]+)?\\s*=\\s*([^\\s,]*)`, 'gi');
  const values = [];
  for (const match of text.matchAll(pattern)) {
    if (gateFCmakeValueLooksEnabled(match[1])) values.push(match[1]);
  }
  return values;
}

function has(text, pattern) {
  return typeof pattern === 'string'
    ? text.includes(pattern)
    : pattern.test(text);
}

function count(text, pattern) {
  const flags = pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`;
  return [...text.matchAll(new RegExp(pattern.source, flags))].length;
}

function extractSwitchCaseBody(text, eventName) {
  const startPattern = new RegExp(`case\\s+${eventName}\\s*:`);
  const match = startPattern.exec(text);
  if (!match) return '';
  const bodyStart = match.index + match[0].length;
  const tail = text.slice(bodyStart);
  const next = /\n\s*(?:case\s+[^:]+:|default\s*:)/.exec(tail);
  return next ? tail.slice(0, next.index) : tail;
}

// 这里只抽取已剥去注释/字符串的函数定义。原型、调用和其它函数中的同名常量不能
// 替代生产函数的实际接线；花括号配对保留函数内的嵌套分支，不以第一处 `}` 截断。
function extractFunctionBody(text, name) {
  const pattern = new RegExp(`\\b${name}\\s*\\(`, 'g');
  for (const match of text.matchAll(pattern)) {
    let cursor = match.index + match[0].length;
    let depth = 1;
    while (cursor < text.length && depth !== 0) {
      if (text[cursor] === '(') ++depth;
      if (text[cursor] === ')') --depth;
      ++cursor;
    }
    while (/\s/.test(text[cursor] ?? '') && cursor < text.length) ++cursor;
    if (text[cursor] !== '{') continue;
    const start = ++cursor;
    depth = 1;
    while (cursor < text.length && depth !== 0) {
      if (text[cursor] === '{') ++depth;
      if (text[cursor] === '}') --depth;
      ++cursor;
    }
    if (depth === 0) return text.slice(start, cursor - 1);
  }
  return '';
}

function containsAll(text, patterns) {
  return patterns.every(pattern => has(text, pattern));
}

// 先验证资格再解算 relative，避免已经退休的 delta 更新 consumer current。各后端的
// 数字身份是冻结的实际 consumer，不能从其它后端借用一次 helper 调用满足本合同。
function scopedRelativeConsumer(text, backend, shared = false) {
  const validAt = text.search(/scopedMenuEventValid\s*\(/);
  const relativeAt = text.search(new RegExp(`resolveRelativeMenuEvent\\s*\\(\\s*${backend}\\s*,`));
  const ownedState = backend === 1 ? 'g_glfwPointer' : backend === 2 ? 'g_l2Pointer' : 'g_sdlMenuState.pointer';
  const phaseContract = shared
    ? has(text, new RegExp(`amclPointerAccept\\s*\\(\\s*&${ownedState.replace('.', '\\.')}\\s*,`))
    : containsAll(text, [/MENU_POINTER_BEGIN/, /MENU_POINTER_END/, /MENU_POINTER_CANCEL/]);
  return phaseContract && validAt >= 0 && relativeAt > validAt && containsAll(text, [
    /queuedMenuInvalidates\s*\(/, /acceptMenuGestureStart\s*\(/,
    /MENU_POINTER_BEGIN/,
  ]);
}

function oneCheck(id, label, ok, evidence) {
  return { id, label, ok: Boolean(ok), evidence };
}

function group(id, label, checks, mode = null) {
  return {
    id,
    label,
    ok: checks.every(check => check.ok),
    mode,
    checks,
  };
}

function ownerAtomicRouteGroup(t) {
  const policyHeader = stripGateFCode(t.policyHeaderText);
  const policySource = stripGateFCode(t.policySourceText);
  const policyTest = stripGateFCode(t.policyTestText);
  const ingressHeader = stripGateFCode(t.ingressHeaderText);
  const ingressSource = stripGateFCode(t.ingressSourceText);
  const touch = stripGateFCode(t.touchText);
  const transaction = 'PlatformInputMenuPointerTransaction';
  const owner = 'amcl_input_policy_left_begin_atomic_menu';
  return group('owner-atomic-route', 'owner 原子路由', [
    oneCheck('generic-transaction-declared', '声明通用 menu pointer transaction',
      has(ingressHeader, new RegExp(`\\b${transaction}\\s*\\(`)),
      GATE_F_SOURCE_PATHS.ingressHeader),
    oneCheck('generic-transaction-defined', '定义通用 menu pointer transaction',
      has(ingressSource, new RegExp(`\\b${transaction}\\s*\\(`)) &&
        has(ingressSource, /AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND/) &&
        has(ingressSource, /SubmitBatchLocked\s*\(/),
      GATE_F_SOURCE_PATHS.ingressSource),
    oneCheck('route-aware-owner-declared', '声明 route-aware atomic owner',
      has(policyHeader, new RegExp(`\\b${owner}\\s*\\(`)),
      GATE_F_SOURCE_PATHS.policyHeader),
    oneCheck('route-aware-owner-defined', '定义 route-aware atomic owner',
      has(policySource, new RegExp(`\\b${owner}\\s*\\(`)),
      GATE_F_SOURCE_PATHS.policySource),
    oneCheck('both-real-producers-use-owner', 'ArkUI/native 两个真实入口都经过 atomic owner',
      count(touch, new RegExp(`\\b${owner}\\s*\\(`, 'g')) >= 2,
      GATE_F_SOURCE_PATHS.touch),
    oneCheck('both-real-producers-use-transaction', 'ArkUI/native 两个真实入口都进入同一 transaction',
      count(touch, new RegExp(`\\b${transaction}\\s*\\(`, 'g')) >= 2,
      GATE_F_SOURCE_PATHS.touch),
    oneCheck('owner-integration-test', '存在真实 owner 竞争集成测试',
      has(policyTest, /TestGateFOwnerAtomicRoute\s*\(/) &&
        has(policyTest, /AMCL_INPUT_CHANNEL_ARKUI_MOUSE/) &&
        has(policyTest, /AMCL_INPUT_CHANNEL_NATIVE_MOUSE/),
      GATE_F_SOURCE_PATHS.policyTest),
  ]);
}

function backendCombinedPointerGroup(t) {
  const adapterHeader = stripGateFCode(t.adapterHeaderText);
  const adapterSource = stripGateFCode(t.adapterSourceText);
  const backendHeader = stripGateFCode(t.backendHeaderText);
  const backendSource = stripGateFCode(t.backendSourceText);
  const glfw = stripGateFCode(t.glfwText);
  const lwjglBridge = stripGateFCode(t.lwjglBridgeText);
  const lwjglHeader = stripGateFCode(t.lwjglTranslateHeaderText);
  const lwjglSource = stripGateFCode(t.lwjglTranslateSourceText);
  const sdl = stripGateFCode(t.sdlGateFFinalPatchText ?? '');
  const test = stripGateFCode(t.backendPointerTestText);
  const hostCmake = stripGateFCode(t.hostCmakeText);
  const event = 'AMCL_BACKEND_INPUT_EVENT_POINTER_TRANSACTION';
  const sdlPointerCase = extractSwitchCaseBody(sdl, event);
  const sdlMotionAt = sdlPointerCase.search(/SDL_SendMouseMotion\s*\(/);
  const sdlButtonAt = sdlPointerCase.search(/SDL_SendMouseButton\s*\(/);
  const sdlHasConditional = /(?:^|\n)\s*#\s*(?:if|ifdef|ifndef|elif|else|endif)\b/.test(sdl);
  return group('three-backend-pointer-transaction',
    '三后端组合 pointer transaction', [
      oneCheck('combined-sink-contract', 'adapter 暴露不可拆 absolute+button sink',
        has(adapterHeader, /GlfwAbsoluteButtonSinkFn/) &&
          has(adapterHeader, /\babsoluteButton\b/),
        GATE_F_SOURCE_PATHS.adapterHeader),
      oneCheck('adapter-emits-combined', 'adapter 对 bound button 发组合 sink',
        has(adapterSource, /requiresAbsoluteAuthorization/) &&
          has(adapterSource, /\.absoluteButton\b|\babsoluteButton\s*\(/),
        GATE_F_SOURCE_PATHS.adapterSource),
      oneCheck('glfw-consumes-combined', 'GLFW3 接入组合 sink',
        has(glfw, /typedAbsoluteButtonSink/) &&
          has(glfw, /sink\.absoluteButton\s*=\s*typedAbsoluteButtonSink/) &&
          has(glfw, /GlfwTypedRuntimeCommitAbsolute/) &&
          has(glfw, /GlfwTypedRuntimeCommitButton/),
        GATE_F_SOURCE_PATHS.glfw),
      oneCheck('backend-wire-event', 'pull ABI 定义组合 transaction 事件',
        has(backendHeader, new RegExp(`\\b${event}\\b`)),
        GATE_F_SOURCE_PATHS.backendHeader),
      oneCheck('backend-enqueues-combined', 'pull bridge 以一个 envelope 入队',
        has(backendSource, /PointerTransactionSink/) &&
          has(backendSource, /sink\.absoluteButton\s*=\s*PointerTransactionSink/) &&
          has(backendSource, new RegExp(`\\b${event}\\b`)),
        GATE_F_SOURCE_PATHS.backendSource),
      oneCheck('sdl-final-patch-unconditional', 'SDL3 Gate F final patch 不得把消费者包进条件编译',
        sdl.length > 0 && !sdlHasConditional,
        'prebuilt/sdl3/patches/series（最后一个 gate-f-pointer-transaction patch）'),
      oneCheck('sdl-consumes-combined', 'SDL3 同一 case 发送 motion 后发送 button',
        sdlMotionAt >= 0 && sdlButtonAt > sdlMotionAt,
        'prebuilt/sdl3/patches/series（最后一个 gate-f-pointer-transaction patch 的 added case）'),
      oneCheck('lwjgl2-consumes-combined', 'LWJGL2 有专用组合 transaction 消费器',
        has(lwjglHeader, /amclConsumeBackendPointerTransactionLwjgl2/) &&
          has(lwjglSource, /amclConsumeBackendPointerTransactionLwjgl2\s*\(/) &&
          has(lwjglSource, new RegExp(`\\b${event}\\b`)) &&
          has(lwjglBridge, /amclConsumeBackendPointerTransactionLwjgl2\s*\(/) &&
          has(lwjglBridge, /inputBridge_setMenuCursor\s*\(/),
        `${GATE_F_SOURCE_PATHS.lwjglTranslateSource} + ${GATE_F_SOURCE_PATHS.lwjglBridge}`),
      oneCheck('combined-transaction-host-test', '组合队列/overflow/三后端合同进入 host test',
        has(test, /TestGateFBackendPointerTransaction\s*\(/) &&
          has(test, /AMCL_BACKEND_INPUT_LWJGL2/) &&
          has(test, /AMCL_BACKEND_INPUT_SDL3/) &&
          has(hostCmake, /backend_pointer_transaction_test\.cpp/),
        GATE_F_SOURCE_PATHS.backendPointerTest),
  ]);
}

function physicalLegacyRetiredGroup(t) {
  const routeHeader = stripGateFCode(t.nativeRouteHeaderText);
  const routeSource = stripGateFCode(t.nativeRouteSourceText);
  const napi = stripGateFCode(t.napiText);
  const ingressHeader = stripGateFCode(t.ingressHeaderText);
  const ingressSource = stripGateFCode(t.ingressSourceText);
  const test = stripGateFCode(t.physicalLegacyTestText);
  const hostCmake = stripGateFCode(t.hostCmakeText);

  const strictlyRemoved =
    !has(routeHeader, /\bLegacyMenuAbsolute\b/) &&
    !has(routeSource, /\bLegacyMenuAbsolute\b/) &&
    !has(napi, /\bLegacyMenuAbsolute\b/) &&
    !has(napi, /ohos_send_cursor_pos_checked\s*\(/);

  // compatibility 产品若仍需 legacy，可保留实现，但必须通过一个显式产品判据和 host test
  // 证明 formal absolute route 与 legacy writer 互斥；只有注释或 capability 名不算。
  const scopedContract =
    has(ingressHeader, /PlatformInputPhysicalLegacyMenuRouteIsCompatibilityOnly\s*\(/) &&
    has(ingressSource, /PlatformInputPhysicalLegacyMenuRouteIsCompatibilityOnly\s*\(/) &&
    has(napi, /PlatformInputPhysicalLegacyMenuRouteIsCompatibilityOnly\s*\(/) &&
    has(test, /TestGateFPhysicalLegacyCompatibilityOnly\s*\(/) &&
    has(hostCmake, /gate_f_physical_legacy_contract_test\.cpp/);

  const mode = strictlyRemoved ? 'removed'
    : (scopedContract ? 'compatibility-only' : 'active-or-unproven');
  return group('physical-legacy-retired', 'physical legacy 退役', [
    oneCheck('physical-writer-retired',
      '旧物理 writer 已删除，或被产品作用域互斥合同与 host test 封住',
      strictlyRemoved || scopedContract,
      strictlyRemoved ? 'strict symbol absence'
        : `${GATE_F_SOURCE_PATHS.ingressSource} + ${GATE_F_SOURCE_PATHS.physicalLegacyTest}`),
  ], mode);
}

// BEGIN/END 和 private relative 是既有 touch MENU_POINTER 的扩展传输，仍在 neutral
// bridge 内归约成原 GLFW callback / LWJGL2 / SDL 五 int ABI。它不是 Gate F 的 typed
// 等价替代，也不批准 absolute/timestamp 证据。旧 inline 与旧统一解释器 fixture 继续
// 走原合同；一旦出现新协议符号，必须验证下面整条生产/消费路线，不能回退到旧宽松匹配。
function causalTouchMenuChecks(touch, bridge, transaction) {
  const emit = extractFunctionBody(touch, 'emitMenuInteraction');
  const retire = extractFunctionBody(touch, 'schemaRetireTouchPolicyLocked');
  const publish = extractFunctionBody(bridge, 'inputBridge_publishTouchMenuRelativeV1');
  const freeze = extractFunctionBody(bridge, 'sendData_locked');
  const retireBridge = extractFunctionBody(bridge, 'inputBridge_retireTouchMenuScopeV1');
  const valid = extractFunctionBody(bridge, 'scopedMenuEventValid');
  const scanner = extractFunctionBody(bridge, 'queuedMenuInvalidates');
  const resolve = extractFunctionBody(bridge, 'resolveRelativeMenuEvent');
  const cursor = extractFunctionBody(bridge, 'resolveRelativeMenuCursor');
  const glfw = extractFunctionBody(bridge, 'inputBridge_pumpOrdered');
  const glfwPending = extractFunctionBody(bridge, 'advanceGlfwMenuPending');
  const l2 = extractFunctionBody(bridge, 'inputBridge_l2NextEvent');
  const sdl = extractFunctionBody(bridge, 'inputBridge_sdlNextThrough');
  const sdlPointer = extractFunctionBody(bridge, 'consumeSdlMenuPointer');
  const sdlPending = extractFunctionBody(bridge, 'returnDueSdlMenuButton');
  const legacy = extractFunctionBody(bridge, 'returnLegacyEvent');
  const orderedCursor = extractFunctionBody(bridge, 'returnOrderedMenuCursor');
  const sdlButton = extractFunctionBody(bridge, 'returnSdlMenuButtonEvent');
  // 使用新入口时必须核真实共同实现和三个调用方，不能借历史变量名或旧分支通过。
  const shared = has(bridge, /amclPointerAccept\s*\(/);
  const accept = extractFunctionBody(transaction, 'amclPointerAccept');
  const advance = extractFunctionBody(transaction, 'amclPointerAdvance');
  const delivered = extractFunctionBody(transaction, 'amclPointerSourceDelivered');
  const finishUp = extractFunctionBody(transaction, 'amclPointerFinishUp');
  const sharedLifecycle = containsAll(accept, [
    /phase\s*==\s*AMCL_POINTER_BEGIN/, /phase\s*==\s*AMCL_POINTER_DOWN/,
    /token\s*!=\s*state->token/, /state->sourceX\s*=\s*x/, /state->sourceY\s*=\s*y/,
    /state->downAccepted\s*=\s*true/,
    /phase\s*==\s*AMCL_POINTER_UP/, /phase\s*==\s*AMCL_POINTER_END/,
    /phase\s*==\s*AMCL_POINTER_CANCEL/, /amclPointerRetire\s*\(/,
  ]) && containsAll(finishUp, [/state->buttonDown\s*=/, /!state->gestureBegun/, /memset\s*\(/]);
  const sharedBarriers = sharedLifecycle && containsAll(bridge, [
    /g_glfwPointerPolicy\s*=\s*\{2u,\s*false,\s*false\}/,
    /g_sdlPointerPolicy\s*=\s*\{1u,\s*true,\s*true\}/,
    /g_l2PointerPolicy\s*=\s*\{0u,\s*false,\s*false\}/,
  ]) && containsAll(advance, [
    /invalid\s*\|\|\s*state->releasePending/, /cancelled\s*\|\|\s*expired/,
    /presentSerial\s*<\s*state->pressAfterPresent/, /state->pendingOrder\s*>\s*maxOrder/,
    /currentX\s*!=\s*state->sourceX/, /AMCL_POINTER_RESTORE_SOURCE/,
    /state->sourceFrameBaselinePending/, /amclPointerSourceDelivered\s*\(/,
  ]) && has(delivered, /state->pressAfterPresent\s*=\s*presentSerial\s*\+\s*policy->presentFrames/) &&
    containsAll(glfwPending, [/queuedMenuInvalidates\s*\(/,
      /g_glfwPointer.inputTargetEpoch\s*!=/, /g_glfwPresentedIdentity\s*!=\s*g_menuPresentedIdentity/,
      /amclPointerAdvance\s*\(\s*&g_glfwPointer\s*,\s*&g_glfwPointerPolicy/,
      /amclPointerSourceDelivered\s*\(\s*&g_glfwPointer/]) &&
    has(glfw, /amclPointerSourceDelivered\s*\(\s*&g_glfwPointer/) &&
    containsAll(sdlPending, [/queuedMenuInvalidates\s*\(/,
      /g_sdlMenuState.pointer.inputTargetEpoch\s*!=/, /g_sdlMenuState.targetPresentedIdentity\s*!=/,
      /amclPointerAdvance\s*\(\s*&g_sdlMenuState.pointer\s*,\s*&g_sdlPointerPolicy/]);
  const sourceEvidence = GATE_F_SOURCE_PATHS.touch;
  const consumerEvidence = GATE_F_SOURCE_PATHS.lwjglBridge;

  return [
    oneCheck('touch-token-allocation', 'BEGIN 分配不可复用 token，真实 Event/Cancel 仍接入解释器',
      containsAll(emit, [
        /action\s*==\s*MenuTouchAction::Begin\s*\|\|\s*action\s*==\s*MenuTouchAction::RelativeBegin/,
        /if\s*\(\s*s_touchMenuNextToken\s*==\s*0\s*\)\s*return\s*;/,
        /s_touchMenuToken\s*=\s*s_touchMenuNextToken\s*;/,
        /s_touchMenuNextToken\s*=\s*s_touchMenuNextToken\s*==\s*0x7fffffffu\s*\?\s*0\s*:\s*s_touchMenuNextToken\s*\+\s*1\s*;/,
      ]) && containsAll(touch, [
        /s_menuTouch\.Event\s*\(/, /s_menuTouch\.Cancel\s*\(\s*emitMenuInteraction\s*\)/,
      ]), sourceEvidence),
    oneCheck('touch-gesture-lifetime', 'absolute/relative 的 UP 只释放左键，END/CANCEL 才退休 token',
      containsAll(emit, [
        /MenuTouchAction::RelativeBegin\s*\?\s*MENU_POINTER_BEGIN/,
        /MenuTouchAction::RelativeDown\s*\?\s*MENU_POINTER_DOWN/,
        /MenuTouchAction::RelativeUp\s*\?\s*MENU_POINTER_UP/,
        /MenuTouchAction::RelativeEnd\s*\?\s*MENU_POINTER_END/,
        /MenuTouchAction::RelativeCancel\s*\?\s*MENU_POINTER_CANCEL\s*:\s*MENU_POINTER_MOVE/,
        /if\s*\(\s*phase\s*==\s*MENU_POINTER_END\s*\|\|\s*phase\s*==\s*MENU_POINTER_CANCEL\s*\)\s*s_touchMenuToken\s*=\s*0\s*;/,
        /if\s*\(\s*action\s*==\s*MenuTouchAction::End\s*\|\|\s*action\s*==\s*MenuTouchAction::Cancel\s*\)\s*s_touchMenuToken\s*=\s*0\s*;/,
        /sendEvent\s*\(\s*EVENT_TYPE_MENU_POINTER\s*,\s*MENU_POINTER_MOVE\s*,\s*mx\s*,\s*my\s*,\s*s_touchMenuToken\s*\)/,
        /MenuTouchAction::Begin\s*\?\s*MENU_POINTER_BEGIN\s*:\s*MENU_POINTER_DOWN\s*,\s*mx\s*,\s*my\s*,\s*s_touchMenuToken/,
        /MenuTouchAction::Up\s*\?\s*MENU_POINTER_UP\s*:\s*action\s*==\s*MenuTouchAction::End\s*\?\s*MENU_POINTER_END\s*:\s*MENU_POINTER_CANCEL/,
      ]) && count(emit, /s_touchMenuToken\s*=\s*0\s*;/g) === 2, sourceEvidence),
    oneCheck('touch-relative-publication', 'relative 的 phase/token/真实 delta/bounds 在原槽中发布',
      has(emit, /inputBridge_publishTouchMenuRelativeV1\s*\(\s*phase\s*,\s*s_touchMenuToken\s*,\s*dx\s*,\s*dy\s*,\s*maxX\s*,\s*maxY\s*\)/) &&
        has(emit, /mapMenuRelativePayload\s*\(/) && containsAll(publish, [
          /token\s*==\s*0/, /phase\s*>\s*MENU_POINTER_END/,
          /publishMenuRelative\s*\(\s*EVENT_TYPE_TOUCH_MENU_RELATIVE\s*,\s*phase\s*,\s*token\s*,\s*dx\s*,\s*dy\s*,\s*maxX\s*,\s*maxY\s*\)/,
        ]) && containsAll(freeze, [
          /slot->relative\s*=\s*\*relative/, /slot->menuScopeEpoch\s*=\s*atomic_load_explicit\s*\(\s*&g_touchMenuScopeEpoch/,
          /slot->gestureToken\s*=/, /MENU_POINTER_BEGIN/, /MENU_POINTER_END/, /MENU_POINTER_CANCEL/,
        ]), `${sourceEvidence} + ${consumerEvidence}`),
    oneCheck('touch-scope-retirement', '模态/策略完整退休撤已结束但未消费的菜单，消费时核冻结 epoch',
      containsAll(retire, [/inputBridge_retireTouchMenuScopeV1\s*\(/, /s_menuTouch\.Cancel\s*\(\s*emitMenuInteraction\s*\)/]) &&
        has(retireBridge, /atomic_fetch_add_explicit\s*\(\s*&g_touchMenuScopeEpoch\s*,\s*1ULL/) &&
        has(valid, /menuEpoch\s*!=\s*atomic_load_explicit\s*\(\s*&g_touchMenuScopeEpoch/) &&
        containsAll(scanner, [
          /epoch\s*!=\s*atomic_load_explicit\s*\(\s*&g_touchMenuScopeEpoch/,
          /value\s*==\s*token\s*&&\s*phase\s*==\s*MENU_POINTER_CANCEL\s*\)\s*canceled\s*=\s*true/,
          /phase\s*==\s*MENU_POINTER_END\s*\|\|\s*\(\s*!gestureBegun\s*&&\s*phase\s*==\s*MENU_POINTER_UP\s*\)/,
          /!normallyEnded\s*&&\s*\(\s*phase\s*==\s*MENU_POINTER_BEGIN\s*\|\|\s*phase\s*==\s*MENU_POINTER_DOWN\s*\)\s*&&\s*value\s*!=\s*token/,
        ]), `${sourceEvidence} + ${consumerEvidence}`),
    oneCheck('touch-relative-current', '相对命令在实际 consumer current 上有序解算，不借 Native desired',
      containsAll(resolve, [
        /token\s*!=\s*currentToken/, /resolveRelativeMenuCursor\s*\(/,
        /event->type\s*=\s*EVENT_TYPE_MENU_POINTER/, /event->i1\s*=\s*phase/, /event->i4\s*=\s*\(int\)token/,
      ]) && containsAll(cursor, [
        /currentMenuCursor\s*\(\s*backend\s*,\s*x\s*,\s*y\s*\)/,
        /\*x\s*\+=\s*dx/, /\*y\s*\+=\s*dy/, /relative->maxX/, /relative->maxY/,
      ]), consumerEvidence),
    oneCheck('touch-three-consumers', '三个真实消费者在 relative 解算前核 scope 并消费 BEGIN/END/CANCEL',
      scopedRelativeConsumer(glfw, 1, shared) && scopedRelativeConsumer(l2, 2, shared) &&
        scopedRelativeConsumer(`${sdl}\n${sdlPointer}`, 3, shared) && (!shared || sharedLifecycle) &&
        has(sdl, /consumeSdlMenuPointer\s*\(/), consumerEvidence),
    oneCheck('touch-present-barriers', 'GLFW/SDL 保留实际 present 屏障，提交前先撤 CANCEL/旧 target',
      shared ? sharedBarriers : containsAll(glfwPending, [
        /queuedMenuInvalidates\s*\(/, /cancelMenuTransaction\s*\(/,
        /g_menuInputTargetEpoch\s*!=/, /g_glfwPresentedIdentity\s*!=\s*g_menuPresentedIdentity/,
        /g_presentSerial\s*<\s*g_menuPressAfterPresent/, /g_menuPressAfterPresent\s*=\s*g_presentSerial\s*\+\s*2ULL/,
      ]) && containsAll(glfw, [/g_menuPressAfterPresent\s*=\s*g_presentSerial\s*\+\s*2ULL/]) &&
        containsAll(sdlPending, [
          /queuedMenuInvalidates\s*\(/, /clearSdlMenuTransactionLocked\s*\(/,
          /g_sdlMenuState.inputTargetEpoch\s*!=/, /g_sdlMenuState.targetPresentedIdentity\s*!=/,
          /g_sdlMenuState.pressAfterPresent\s*=\s*g_sdlMenuState.presentSerial\s*\+\s*1ULL/,
          /g_sdlMenuState.presentSerial\s*>=\s*g_sdlMenuState.pressAfterPresent/,
        ]), consumerEvidence),
    oneCheck('touch-old-game-abi', 'private relative 归约后保持旧坐标/按键出口与五 int ABI',
      containsAll(bridge, [
        /#define\s+EVENT_TYPE_MENU_POINTER\s+1008\b/,
        /#define\s+EVENT_TYPE_CURSOR_POSITION\s+1010\b/,
        /#define\s+EVENT_TYPE_MOUSE_BUTTON\s+1006\b/,
        /#define\s+EVENT_TYPE_TOUCH_MENU_RELATIVE\s+1017\b/,
      ]) && containsAll(legacy, [
        /\*outType\s*=\s*event->type/, /\*o1\s*=\s*event->i1/, /\*o2\s*=\s*event->i2/,
        /\*o3\s*=\s*event->i3/, /\*o4\s*=\s*event->i4/,
      ]) && has(orderedCursor, /\*outType\s*=\s*EVENT_TYPE_CURSOR_POSITION/) &&
        containsAll(l2, [/returnOrderedMenuCursor\s*\(/, /e.type\s*=\s*EVENT_TYPE_MOUSE_BUTTON/, /returnLegacyEvent\s*\(/]) &&
        containsAll(sdlPointer, [/returnOrderedMenuCursor\s*\(/, /returnSdlMenuButtonEvent\s*\(/]) &&
        containsAll(sdlButton, [/EVENT_TYPE_MOUSE_BUTTON/, /returnLegacyEvent\s*\(/]), consumerEvidence),
  ];
}

function touchMenuPointerContractGroup(t) {
  const touch = stripGateFCode(t.touchText);
  const bridge = stripGateFCode(t.lwjglBridgeText);
  const eventHeader = stripGateFCode(t.eventHeaderText);
  const adapterHeader = stripGateFCode(t.adapterHeaderText);
  const backendHeader = stripGateFCode(t.backendHeaderText);
  const glfw = stripGateFCode(t.glfwText);
  const sdl = stripGateFCode(t.sdlPatchText);
  const sdlGateF = stripGateFCode(t.sdlGateFFinalPatchText ?? '');
  const transaction = stripGateFCode(t.pointerTransactionText ?? '');
  const shared = has(bridge, /amclPointerAccept\s*\(/);

  // 新解释器仍使用同一组带token的MENU_POINTER事件及present屏障。
  // 除了兼容旧直接入口，必须同时看到token分配、Event入口和Cancel收口；
  // 只改一个变量名、留下常量或取消路径断开，都不能据此宣称合同成立。
  const causalProtocol = has(touch, /MenuTouchAction::RelativeBegin|\bMENU_POINTER_BEGIN\b|inputBridge_publishTouchMenuRelativeV1/);
  const causalChecks = causalProtocol ? causalTouchMenuChecks(touch, bridge, transaction) : [];
  const touchProducer = causalProtocol ? causalChecks.every(check => check.ok) : (has(touch, /s_activeMenuTransactionToken/) || (
    has(touch, /s_touchMenuToken\s*=\s*s_touchMenuNextToken\s*\+\+/) &&
    has(touch, /s_menuTouch\.Event\s*\(/) &&
    has(touch, /s_menuTouch\.Cancel\s*\(\s*emitMenuInteraction\s*\)/)));
  const preserved =
    has(touch, /EVENT_TYPE_MENU_POINTER/) &&
    has(touch, /MENU_POINTER_DOWN/) &&
    has(touch, /MENU_POINTER_MOVE/) &&
    has(touch, /MENU_POINTER_UP/) &&
    has(touch, /MENU_POINTER_CANCEL/) &&
    touchProducer &&
    has(bridge, /case\s+EVENT_TYPE_MENU_POINTER\s*:/) &&
    (shared ? has(bridge, /g_glfwPointer\.token/) && has(bridge, /g_glfwPointerPolicy/)
      : has(bridge, /g_menuPressAfterPresent/) && has(bridge, /g_menuTransactionToken/)) &&
    has(bridge, /MENU_POINTER_CANCEL/) &&
    has(sdl, /AMCL_EVENT_MENU_POINTER/) &&
    has(sdl, /AMCL_MENU_POINTER_DOWN/) &&
    has(sdl, /SDL_SendMouseMotion\s*\(/) &&
    has(sdl, /SDL_SendMouseButton\s*\(/);

  const replacementEvent = 'AMCL_INPUT_EVENT_MENU_POINTER_TRANSACTION';
  const backendEvent = 'AMCL_BACKEND_INPUT_EVENT_MENU_POINTER_TRANSACTION';
  const replaced =
    has(eventHeader, new RegExp(`\\b${replacementEvent}\\b`)) &&
    has(touch, /PlatformInputTouchMenuPointerTransaction\s*\(/) &&
    has(adapterHeader, /\bmenuPointer\b/) &&
    has(glfw, /typedMenuPointerSink/) &&
    has(backendHeader, new RegExp(`\\b${backendEvent}\\b`)) &&
    has(bridge, new RegExp(`\\b${backendEvent}\\b`)) &&
    has(sdlGateF, new RegExp(`\\b${backendEvent}\\b`));

  const mode = replaced ? 'typed-replacement'
    : (preserved ? 'preserved-legacy' : 'missing');
  return group('touch-menu-pointer-contract',
    'touch MENU_POINTER 等价替代/明确保留', [
      oneCheck('touch-contract',
        '触摸 token/cancel/present-barrier 合同仍完整，或三个后端已有 typed 等价替代',
        preserved || replaced,
        mode),
    ...causalChecks,
  ], mode);
}

function parseManifest(manifestText, issues) {
  let manifest;
  try {
    manifest = JSON.parse(String(manifestText ?? ''));
  } catch (error) {
    issues.push(`gate0-evidence.lock is not valid JSON: ${error.message}`);
    return null;
  }
  if (manifest?.schemaVersion !== 1) {
    issues.push(
      `gate0-evidence.lock schemaVersion must be 1; got ${manifest?.schemaVersion}`);
  }
  const capabilities = manifest?.capabilities;
  if (!capabilities || typeof capabilities !== 'object' || Array.isArray(capabilities)) {
    issues.push('gate0-evidence.lock capabilities must be an object');
    return null;
  }
  for (const name of Object.values(GATE_F_CAPABILITIES)) {
    if (!capabilities[name] || typeof capabilities[name].approved !== 'boolean') {
      issues.push(`${name}: missing entry or non-boolean approved field`);
    }
  }
  return capabilities;
}

export function analyzeGateFReadiness(texts) {
  const issues = [];
  if (Array.isArray(texts.missing)) {
    for (const required of [GATE_F_SOURCE_PATHS.manifest, GATE_F_SOURCE_PATHS.profile]) {
      if (texts.missing.includes(required)) issues.push(`${required} is missing`);
    }
  }
  if (typeof texts.profileText !== 'string' || texts.profileText.trim() === '') {
    issues.push('entry/build-profile.json5 is missing or empty');
  }
  const capabilities = parseManifest(texts.manifestText, issues);
  const absoluteApproved = capabilities?.[GATE_F_CAPABILITIES.absolute]?.approved === true;
  const timestampApproved = capabilities?.[GATE_F_CAPABILITIES.timestamp]?.approved === true;
  const profileEnablements = findGateFProfileEnablements(texts.profileText);
  const profileAttemptsBit14 = profileEnablements.length > 0;
  const activationReasons = [];
  if (absoluteApproved) activationReasons.push(`evidence:${GATE_F_CAPABILITIES.absolute}`);
  if (timestampApproved) activationReasons.push(`evidence:${GATE_F_CAPABILITIES.timestamp}`);
  if (profileAttemptsBit14) {
    activationReasons.push(`profile:${GATE_F_CAPABILITIES.absolute}=${profileEnablements.join(',')}`);
  }
  const activationRequested = activationReasons.length > 0;

  const prerequisites = [
    ownerAtomicRouteGroup(texts),
    backendCombinedPointerGroup(texts),
    physicalLegacyRetiredGroup(texts),
    touchMenuPointerContractGroup(texts),
  ];

  if (absoluteApproved && !timestampApproved) {
    issues.push(
      `${GATE_F_CAPABILITIES.absolute} is approved before its timestamp dependency`);
  }
  // 本脚本不能依赖另一道 source gate 才保持正确：产品已经尝试开 bit14 时，两份批准
  // 必须同时存在。check-gate0-evidence 仍负责核验批准内容与哈希。
  if (profileAttemptsBit14 && (!absoluteApproved || !timestampApproved)) {
    issues.push(
      `product profile enables bit14 before both Gate F evidence entries are approved`);
  }

  if (activationRequested) {
    for (const prerequisite of prerequisites) {
      if (prerequisite.ok) continue;
      const missing = prerequisite.checks
        .filter(check => !check.ok)
        .map(check => check.id)
        .join(', ');
      issues.push(
        `Gate F prerequisite '${prerequisite.id}' is incomplete: ${missing}`);
    }
  }

  const ok = issues.length === 0;
  const state = !activationRequested ? (ok ? 'DORMANT' : 'BLOCKED')
    : (ok ? 'READY' : 'BLOCKED');
  return {
    ok,
    state,
    activationRequested,
    activationReasons,
    evidence: { absoluteApproved, timestampApproved },
    profileEnablements,
    prerequisites,
    issues,
    // readGateFSources 收集的缺失文件只影响相应 prerequisite；在 DORMANT 状态不应把
    // 尚未创建的未来实现文件误报成发布故障。保留列表便于诊断。
    missingSourceFiles: Array.isArray(texts.missing) ? [...texts.missing] : [],
  };
}

function printReport(report) {
  if (!report.ok) {
    for (const issue of report.issues) {
      console.error(`[check-gate-f-readiness] ${issue}`);
    }
    console.error(`[check-gate-f-readiness] BLOCKED`);
    return;
  }
  if (report.state === 'DORMANT') {
    console.log('[check-gate-f-readiness] PASS DORMANT');
    console.log('  bit14/timestamp evidence and product enablement remain OFF');
    console.log('  this is the safe shipping state, not Gate F completion');
  } else {
    console.log('[check-gate-f-readiness] PASS READY');
    console.log(`  activation reasons: ${report.activationReasons.join(', ')}`);
    console.log('  source prerequisites are complete; real-device approval remains external');
  }
  for (const prerequisite of report.prerequisites) {
    const suffix = prerequisite.mode ? ` (${prerequisite.mode})` : '';
    console.log(`  ${prerequisite.ok ? 'ready  ' : 'pending'} ${prerequisite.id}${suffix}`);
  }
}

const invokedDirectly = process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) {
  const report = analyzeGateFReadiness(readGateFSources());
  printReport(report);
  process.exitCode = report.ok ? 0 : 1;
}

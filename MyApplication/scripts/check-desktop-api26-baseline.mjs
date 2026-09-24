#!/usr/bin/env node
// desktop formal/legacy 产品与本机 SDK 的 fail-closed 契约。规范 §十、计划 §109。

import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function stripJson5(text) {
  let result = '';
  let quote = '';
  let escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];
    if (quote) {
      result += char;
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      result += char;
      continue;
    }
    if (char === '/' && next === '/') {
      while (index < text.length && text[index] !== '\n') index += 1;
      result += '\n';
      continue;
    }
    if (char === '/' && next === '*') {
      index += 2;
      while (index < text.length && !(text[index] === '*' && text[index + 1] === '/')) {
        if (text[index] === '\n') result += '\n';
        index += 1;
      }
      index += 1;
      continue;
    }
    result += char;
  }
  return result.replace(/,\s*([}\]])/g, '$1');
}

function findEntryTarget(projectProfile, productName) {
  const entry = projectProfile?.modules?.find(item => item.name === 'entry');
  return entry?.targets?.find(item =>
    item.name === productName && Array.isArray(item.applyToProducts) &&
    item.applyToProducts.includes(productName));
}

function findModuleTarget(moduleProfile, productName) {
  return moduleProfile?.targets?.find(item => item.name === productName);
}

function cmakeFlagValue(argumentsText, flag) {
  const prefix = `-D${flag}=`;
  const definitions = String(argumentsText ?? '').split(/\s+/)
    .filter(token => token.startsWith(prefix))
    .map(token => token.slice(prefix.length).toUpperCase());
  return definitions.at(-1) ?? null;
}

function hasCmakeFlag(argumentsText, flag) {
  return cmakeFlagValue(argumentsText, flag) === 'ON';
}

function countOccurrences(text, needle) {
  return String(text ?? '').split(needle).length - 1;
}

function stripCppComments(text) {
  return String(text ?? '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/.*$/gm, '');
}

export function evaluateApi26InputProbeSourceContract({ nativeCmakeText, probeSourceText }) {
  const issues = [];
  const cmake = String(nativeCmakeText ?? '');
  const probe = String(probeSourceText ?? '');
  const probePath = 'platform/api26_input_link_probe.cpp';
  const rawFlag = 'AMCL_API26_LINK_PROBE';

  if (countOccurrences(cmake, probePath) !== 1) {
    issues.push('API26 native probe TU must appear exactly once in product CMake');
  }
  if (!new RegExp(
    `if\\(${rawFlag}\\)[\\s\\S]*list\\(APPEND PLATFORM_SOURCES ${probePath.replace('.', '\\.')}\\)`,
  ).test(cmake)) {
    issues.push('API26 native probe TU must be appended only under the raw API26 option');
  }
  if (countOccurrences(cmake, 'libohgame_controller.z.so') !== 1 || !new RegExp(
    `if\\(${rawFlag}\\)[\\s\\S]*target_link_libraries\\(entry PRIVATE libohgame_controller\\.z\\.so\\)`,
  ).test(cmake)) {
    issues.push('GameControllerKit must be a conditional formal-desktop link dependency');
  }
  if (!cmake.includes('if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")') ||
      !cmake.includes('message(FATAL_ERROR')) {
    issues.push('API26 native probe must fail loud outside the OHOS toolchain');
  }


  for (const header of [
    '<ace/xcomponent/native_interface_xcomponent.h>',
    '<arkui/ui_input_event.h>',
    '<arkui/native_key_event.h>',
    '<GameControllerKit/game_device.h>',
    '<GameControllerKit/game_device_event.h>',
    '<GameControllerKit/game_pad.h>',
    '<GameControllerKit/game_pad_event.h>',
  ]) {
    if (!probe.includes(`#include ${header}`)) {
      issues.push(`API26 native probe missing candidate header ${header}`);
    }
  }
  for (const symbol of [
    'OH_NativeXComponent_RegisterUIInputEventCallback',
    'OH_ArkUI_UIInputEvent_GetType',
    'OH_ArkUI_UIInputEvent_GetDeviceId',
    'OH_ArkUI_UIInputEvent_GetPressedKeys',
    'OH_ArkUI_UIInputEvent_GetModifierKeyStates',
    'OH_ArkUI_KeyEvent_GetType',
    'OH_ArkUI_KeyEvent_GetKeyCode',
    'OH_ArkUI_KeyEvent_GetKeyText',
    'OH_ArkUI_KeyEvent_GetKeySource',
    'OH_ArkUI_KeyEvent_GetUnicode',
    'OH_ArkUI_MouseEvent_GetRawDeltaX',
    'OH_ArkUI_MouseEvent_GetRawDeltaY',
    'OH_GameDevice_GetAllDeviceInfos',
    'OH_GameDevice_AllDeviceInfos_GetCount',
    'OH_GamePad_ButtonEvent_GetDeviceId',
    'OH_GamePad_AxisEvent_GetXAxisValue',
  ]) {
    if (!probe.includes(`&${symbol}`)) {
      issues.push(`API26 native probe missing retained symbol address &${symbol}`);
    }
  }
  const executableProbe = stripCppComments(probe);
  const runtimeCalls = executableProbe.match(
    /\bOH_(?:NativeXComponent|ArkUI|GameDevice|GamePad)_[A-Za-z0-9_]+\s*\(/g,
  ) ?? [];
  if (runtimeCalls.length > 0) {
    issues.push(`API26 native probe must not call platform input APIs (${runtimeCalls.join(', ')})`);
  }
  if (!probe.includes('__attribute__((used, visibility("default")))') ||
      !probe.includes('AMCL_Api26InputCompileLinkSymbolSurface')) {
    issues.push('API26 native probe symbol surface must survive --gc-sections');
  }
  return issues;
}

/** PC 浮动窗口内 FAB 必须以应用 viewport 为坐标系，不能退回物理 display。 */
export function evaluateDownloadFabWindowContract({
  launcherIndexText, downloadFabText, fabPolicyText,
}) {
  const issues = [];
  const index = String(launcherIndexText ?? '');
  const fab = String(downloadFabText ?? '');
  const policy = String(fabPolicyText ?? '');

  if (!index.includes('getWindowProperties().drawableRect') &&
      !(index.includes('getWindowProperties()') && index.includes('.drawableRect'))) {
    issues.push('launcher FAB viewport must read the current window drawableRect');
  }
  if (!index.includes("on('windowSizeChange'") ||
      !index.includes("off('windowSizeChange'")) {
    issues.push('launcher FAB viewport must subscribe and unsubscribe windowSizeChange');
  }
  if (!index.includes('.onSizeChange(') ||
      !index.includes('queueRootViewportUpdate_')) {
    issues.push('launcher root layout size must backstop first-frame window properties');
  }
  for (const prop of ['viewportWidth:', 'viewportHeight:', 'bottomSafeHeight:']) {
    if (!index.includes(prop)) issues.push(`DownloadFab call missing ${prop}`);
  }
  if (index.includes('display.getDefaultDisplaySync()') ||
      fab.includes('display.getDefaultDisplaySync()')) {
    issues.push('launcher FAB path must not use physical display dimensions');
  }
  if (!fab.includes('DownloadFabLayoutPolicy.finishDrag(') ||
      !fab.includes('this.bottomSafeHeight')) {
    issues.push('DownloadFab drag completion must use the window/dock layout policy');
  }
  for (const symbol of [
    'static initial(', 'static reflow(', 'static finishDrag(',
    'DOWNLOAD_DOCK_TOTAL_HEIGHT', 'clampVerticalCoordinate(',
  ]) {
    if (!policy.includes(symbol)) issues.push(`DownloadFab layout policy missing ${symbol}`);
  }
  return issues;
}

function evaluateDesktopFlagOwnership(moduleProfile) {
  const issues = [];
  for (const target of moduleProfile?.targets ?? []) {
    const args = target?.config?.buildOption?.externalNativeOptions?.arguments;
    if (target?.name === 'desktopLegacy') {
      issues.push('desktopLegacy is retired; remove its target instead of assigning native flags');
    }
    if (target?.name !== 'desktop' &&
        hasCmakeFlag(args, 'AMCL_INPUT_COMPILED_FORMAL_DESKTOP')) {
      issues.push(`${target.name} native arguments must not claim formal desktop compiled identity`);
    }
  }
  for (const option of moduleProfile?.buildOptionSet ?? []) {
    const args = option?.externalNativeOptions?.arguments;
    const owners = (moduleProfile?.buildModeBinder ?? []).flatMap(binder =>
      (binder?.mappings ?? [])
        .filter(mapping => mapping?.buildOptionName === option?.name)
        .map(mapping => mapping?.targetName));
    if (hasCmakeFlag(args, 'AMCL_INPUT_COMPILED_FORMAL_DESKTOP') &&
        (owners.length === 0 || owners.some(owner => owner !== 'desktop'))) {
      issues.push(`${option.name} formal desktop compiled identity must be bound only to desktop`);
    }
  }
  return issues;
}

export function evaluateDesktopBaseline({
  projectProfile, moduleProfile, sdkApi, productName,
  moduleManifestText = '', obsoleteEasyGoExists = false,
  formalControlSurfaceText = '',
}) {
  const issues = [];
  const product = projectProfile?.app?.products?.find(item => item.name === productName);
  if (!product) issues.push(`missing project product=${productName}`);
  if (!findEntryTarget(projectProfile, productName)) {
    issues.push(`entry target is not bound one-to-one to product=${productName}`);
  }
  const target = findModuleTarget(moduleProfile, productName);
  if (!target) issues.push(`missing entry target=${productName}`);
  if (JSON.stringify(target?.config?.deviceType ?? []) !== JSON.stringify(['2in1'])) {
    issues.push(`${productName} deviceType must be exactly ["2in1"]`);
  }
  if (!(target?.source?.sourceRoots ?? []).includes('./src/desktop')) {
    issues.push(`${productName} must include ./src/desktop sourceRoot`);
  }

  if (productName === 'desktop') {
    for (const field of ['compileSdkVersion', 'targetSdkVersion']) {
      if (product?.[field] !== '26.0.0') {
        issues.push(`desktop ${field} must be 26.0.0 (actual=${product?.[field] ?? 'missing'})`);
      }
    }
    if (product?.compatibleSdkVersion !== '6.0.2(22)') issues.push('desktop compatibleSdkVersion must be 6.0.2(22)');
    // The compile SDK remains API 26 so the formal target can type-check the
    // optional raw-input symbols, while the package install floor is API 22.
    // A missing SDK metadata file is unknown rather than a local failure; the
    // actual compiler invocation remains the authoritative check.
    if (Number.isInteger(sdkApi) && sdkApi > 0 && sdkApi < 26) {
      issues.push(`desktop formal build requires API26 SDK (installed=${sdkApi ?? 'unknown'})`);
    }
    const pages = target?.source?.pages ?? [];
    if (!pages.includes('pages/McGamePage') || !pages.includes('pages/Index')) {
      issues.push('desktop formal pages must include Index and McGamePage');
    }
    if (pages.includes('pages/LayoutListPage') || pages.includes('pages/LayoutEditorPage')) {
      issues.push('desktop formal pages must exclude virtual layout pages');
    }
    let manifestHasEasyGo = false;
    if (moduleManifestText) {
      try {
        manifestHasEasyGo = JSON.parse(stripJson5(moduleManifestText))?.module?.easyGo !== undefined;
      } catch {
        issues.push('entry/src/main/module.json5 must remain parseable for desktop baseline audit');
      }
    }
    if (manifestHasEasyGo || obsoleteEasyGoExists) {
      issues.push('desktop formal must not package obsolete easyGo.mouse2Touch profile (API26 schema rejects it)');
    }
    if (/\bGameControls\b/.test(formalControlSurfaceText)) {
      issues.push('desktop formal control surface must not import or compile mobile GameControls');
    }
    const productArgs = target?.config?.buildOption?.externalNativeOptions?.arguments;
    for (const flag of [
      'AMCL_GLFW_TYPED_PHYSICAL_DEFAULT',
      'AMCL_GLFW_RAW_RELATIVE_VERIFIED',
      'AMCL_GLFW_API26_RAW_MOUSE_MOTION',
      'AMCL_INPUT_COMPILED_FORMAL_DESKTOP',
    ]) {
      if (!hasCmakeFlag(productArgs, flag)) {
        issues.push(`desktop target native arguments must enable ${flag} for debug/release`);
      }
    }
    if (!String(productArgs ?? '').split(/\s+/).includes('-DMC_OHOS_BUILD_TESTS=OFF')) {
      issues.push('desktop target native arguments must exclude native test exports');
    }
  } else {
    issues.push(`unsupported product=${productName}`);
  }
  issues.push(...evaluateDesktopFlagOwnership(moduleProfile));
  return issues;
}

function argValue(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : fallback;
}

function readJson5(path) {
  return JSON.parse(stripJson5(readFileSync(path, 'utf8')));
}

function main() {
  const productName = argValue('--product', 'desktop');
  const projectPath = resolve(root, argValue('--project-profile', 'build-profile.json5'));
  const modulePath = resolve(root, argValue('--module-profile', 'entry/build-profile.json5'));
  const sdkRoot = process.env.DEVECO_SDK_HOME ? resolve(process.env.DEVECO_SDK_HOME) : '';
  const sdkMetaPath = sdkRoot ? resolve(sdkRoot, 'default/sdk-pkg.json') : '';
  if (!existsSync(projectPath)) throw new Error(`project profile missing: ${projectPath}`);
  if (!existsSync(modulePath)) throw new Error(`module profile missing: ${modulePath}`);
  let sdkApi = 0;
  if (sdkMetaPath && existsSync(sdkMetaPath)) {
    const sdkMeta = JSON.parse(readFileSync(sdkMetaPath, 'utf8'));
    sdkApi = Number.parseInt(String(sdkMeta?.data?.apiVersion ?? '0'), 10);
  }
  const issues = evaluateDesktopBaseline({
    projectProfile: readJson5(projectPath),
    moduleProfile: readJson5(modulePath),
    sdkApi,
    productName,
    moduleManifestText: readFileSync(
      resolve(root, 'entry/src/main/module.json5'), 'utf8'),
    obsoleteEasyGoExists: existsSync(resolve(
      root, 'entry/src/main/resources/base/profile/easy_go.json')),
    formalControlSurfaceText: readFileSync(resolve(
      root, 'entry/src/desktop/ProductGameControlSurface.ets'), 'utf8'),
  });
  issues.push(...evaluateApi26InputProbeSourceContract({
    nativeCmakeText: readFileSync(resolve(root, 'entry/src/main/cpp/CMakeLists.txt'), 'utf8'),
    probeSourceText: readFileSync(resolve(
      root, 'entry/src/main/cpp/platform/api26_input_link_probe.cpp'), 'utf8'),
  }));
  issues.push(...evaluateDownloadFabWindowContract({
    launcherIndexText: readFileSync(resolve(
      root, 'entry/src/main/ets/pages/Index.ets'), 'utf8'),
    downloadFabText: readFileSync(resolve(
      root, 'entry/src/main/ets/components/DownloadFab.ets'), 'utf8'),
    fabPolicyText: readFileSync(resolve(
      root, 'entry/src/main/ets/window/DownloadFabLayoutPolicy.ets'), 'utf8'),
  }));
  if (issues.length > 0) {
    console.error(`[desktop-baseline] FAIL product=${productName}`);
    for (const issue of issues) console.error(`  - ${issue}`);
    if (productName === 'desktop' && sdkApi > 0 && sdkApi < 26) {
      console.error('  - install Command Line Tools 26.0.0 from the official Huawei download page');
      console.error('  - use a universal product for API20/21 device compatibility');
    }
    process.exit(1);
  }
  console.log(`[desktop-baseline] PASS product=${productName} sdkApi=${sdkApi}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();

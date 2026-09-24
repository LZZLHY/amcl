#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  evaluateApi26InputProbeSourceContract,
  evaluateDownloadFabWindowContract,
  evaluateDesktopBaseline,
} from './check-desktop-api26-baseline.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function fixture(productName, sdkVersion, includeLayouts = false) {
  const product = {
    name: productName,
    compileSdkVersion: productName === 'desktop' ? sdkVersion : undefined,
    targetSdkVersion: sdkVersion,
    compatibleSdkVersion: productName === 'desktop' ? '6.0.2(22)' : sdkVersion,
  };
  const pages = ['pages/Index', 'pages/McGamePage'];
  if (includeLayouts) pages.push('pages/LayoutListPage');
  return {
    projectProfile: {
      app: { products: [product] },
      modules: [{
        name: 'entry',
        targets: [{ name: productName, applyToProducts: [productName] }],
      }],
    },
    moduleProfile: {
      buildOptionSet: [{
        name: 'release',
        externalNativeOptions: {
          arguments: '-DMC_OHOS_BUILD_TESTS=OFF ' +
            '-DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON ' +
            '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON',
        },
      }],
      targets: [{
        name: productName,
        config: {
          deviceType: ['2in1'],
          buildOption: {
            externalNativeOptions: {
              arguments: productName === 'desktop'
                ? '-DMC_OHOS_BUILD_TESTS=OFF ' +
                  '-DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON ' +
                  '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON ' +
                  '-DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON ' +
                  '-DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON'
                : '-DMC_OHOS_BUILD_TESTS=OFF ' +
                  '-DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON ' +
                  '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON ' +
                  '-DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=OFF',
            },
          },
        },
        source: {
          sourceRoots: productName === 'desktopLegacy'
            ? ['./src/desktopLegacy', './src/desktop'] : ['./src/desktop'],
          pages,
        },
      }],
    },
    productName,
  };
}

assert.deepEqual(evaluateDesktopBaseline({ ...fixture('desktop', '26.0.0'), sdkApi: 26 }), []);
assert.ok(evaluateDesktopBaseline({ ...fixture('desktop', '26.0.0'), sdkApi: 24 })
  .some(issue => issue.includes('requires API26 SDK')));
assert.ok(evaluateDesktopBaseline({ ...fixture('desktop', '6.1.0(23)'), sdkApi: 26 })
  .some(issue => issue.includes('targetSdkVersion')));
assert.ok(evaluateDesktopBaseline({ ...fixture('desktop', '26.0.0', true), sdkApi: 26 })
  .some(issue => issue.includes('exclude virtual layout')));

const missingRaw = fixture('desktop', '26.0.0');
missingRaw.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments =
  '-DMC_OHOS_BUILD_TESTS=OFF -DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON ' +
  '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON';
assert.ok(evaluateDesktopBaseline({ ...missingRaw, sdkApi: 26 })
  .some(issue => issue.includes('API26_RAW_MOUSE_MOTION')));

const missingFormalIdentity = fixture('desktop', '26.0.0');
missingFormalIdentity.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments =
  missingFormalIdentity.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments
    .replace(' -DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON', '');
assert.ok(evaluateDesktopBaseline({ ...missingFormalIdentity, sdkApi: 26 })
  .some(issue => issue.includes('AMCL_INPUT_COMPILED_FORMAL_DESKTOP')));

assert.ok(evaluateDesktopBaseline({
  ...fixture('desktop', '26.0.0'), sdkApi: 26,
  moduleManifestText: '{ "module": { "easyGo": "$profile:easy_go" } }',
}).some(issue => issue.includes('must not package obsolete easyGo')));

assert.ok(evaluateDesktopBaseline({
  ...fixture('desktop', '26.0.0'), sdkApi: 26,
  formalControlSurfaceText: "import { GameControls } from '../main/GameControls'",
}).some(issue => issue.includes('must not import or compile mobile GameControls')));

const legacy = fixture('desktopLegacy', '6.1.0(23)');
legacy.projectProfile.app.products[0].compatibleSdkVersion = '6.0.0(20)';
assert.ok(evaluateDesktopBaseline({ ...legacy, sdkApi: 24 }).some(issue => issue.includes('desktopLegacy is retired')));

legacy.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments +=
  ' -DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON';
assert.ok(evaluateDesktopBaseline({ ...legacy, sdkApi: 24 })
  .some(issue => issue.includes('desktopLegacy is retired')));

const legacyMissingCompiledOff = fixture('desktopLegacy', '6.1.0(23)');
legacyMissingCompiledOff.projectProfile.app.products[0].compatibleSdkVersion = '6.0.0(20)';
legacyMissingCompiledOff.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments =
  legacyMissingCompiledOff.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments
    .replace(' -DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=OFF', '');
assert.ok(evaluateDesktopBaseline({ ...legacyMissingCompiledOff, sdkApi: 24 })
  .some(issue => issue.includes('desktopLegacy is retired')));

const legacyClaimsFormal = fixture('desktopLegacy', '6.1.0(23)');
legacyClaimsFormal.projectProfile.app.products[0].compatibleSdkVersion = '6.0.0(20)';
legacyClaimsFormal.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments =
  legacyClaimsFormal.moduleProfile.targets[0].config.buildOption.externalNativeOptions.arguments
    .replace('AMCL_INPUT_COMPILED_FORMAL_DESKTOP=OFF',
      'AMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON');
const legacyFormalIssues = evaluateDesktopBaseline({ ...legacyClaimsFormal, sdkApi: 24 });
assert.ok(legacyFormalIssues.some(issue => issue.includes('must not claim formal desktop')));
assert.ok(legacyFormalIssues.some(issue => issue.includes('desktopLegacy is retired')));

const nativeCmakeText = readFileSync(resolve(root, 'entry/src/main/cpp/CMakeLists.txt'), 'utf8');
const probeSourceText = readFileSync(resolve(
  root, 'entry/src/main/cpp/platform/api26_input_link_probe.cpp'), 'utf8');
assert.deepEqual(evaluateApi26InputProbeSourceContract({
  nativeCmakeText,
  probeSourceText,
}), []);

assert.ok(evaluateApi26InputProbeSourceContract({
  nativeCmakeText: nativeCmakeText.replace(
    'list(APPEND PLATFORM_SOURCES platform/api26_input_link_probe.cpp)', ''),
  probeSourceText,
}).some(issue => issue.includes('probe TU')));

assert.ok(evaluateApi26InputProbeSourceContract({
  nativeCmakeText,
  probeSourceText: `${probeSourceText}\nvoid BadRuntimeProbe() { OH_GameDevice_GetAllDeviceInfos(nullptr); }\n`,
}).some(issue => issue.includes('must not call platform input APIs')));

const launcherIndexText = readFileSync(resolve(
  root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
const downloadFabText = readFileSync(resolve(
  root, 'entry/src/main/ets/components/DownloadFab.ets'), 'utf8');
const fabPolicyText = readFileSync(resolve(
  root, 'entry/src/main/ets/window/DownloadFabLayoutPolicy.ets'), 'utf8');
assert.deepEqual(evaluateDownloadFabWindowContract({
  launcherIndexText, downloadFabText, fabPolicyText,
}), []);
assert.ok(evaluateDownloadFabWindowContract({
  launcherIndexText: launcherIndexText
    .replace('const properties: window.WindowProperties =\n          this.launcherWindow_.getWindowProperties()',
      'const properties: window.WindowProperties = {}')
    .replace('const rect: window.Rect = properties.drawableRect',
      'const rect: window.Rect = display.getDefaultDisplaySync()'),
  downloadFabText,
  fabPolicyText,
}).some(issue => issue.includes('must not use physical display')));
assert.ok(evaluateDownloadFabWindowContract({
  launcherIndexText: launcherIndexText.replace('.onSizeChange(', '.onAreaChange('),
  downloadFabText,
  fabPolicyText,
}).some(issue => issue.includes('first-frame')));

console.log('test-check-desktop-api26-baseline: PASS');

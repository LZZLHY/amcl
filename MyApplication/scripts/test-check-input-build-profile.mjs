#!/usr/bin/env node

import assert from 'node:assert/strict';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  cmakeValueLooksEnabled,
  evaluateInputBuildProfile,
} from './check-input-build-profile.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// The actual profile is parsed by the production gate. This test uses a
// compact fixture to exercise merge precedence and failure cases without an
// SDK or Hvigor installation.
const fixture = {
  buildOption: { externalNativeOptions: { path: './src/main/cpp/CMakeLists.txt', arguments: '' } },
  buildOptionSet: [
    { name: 'debug', externalNativeOptions: { arguments: '-DMC_OHOS_BUILD_TESTS=ON -DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON -DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON -DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON -DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=OFF' } },
    { name: 'release', externalNativeOptions: { arguments: '-DMC_OHOS_BUILD_TESTS=OFF -DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON -DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON -DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON -DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=OFF' } },
  ],
  targets: [
    { name: 'default' },
    { name: 'ohosTest' },
    { name: 'store' },
    { name: 'sideload' },
    { name: 'desktop', config: { buildOption: { externalNativeOptions: { arguments: '-DMC_OHOS_BUILD_TESTS=OFF -DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON -DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON -DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON -DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON' } } } },
  ],
};

for (const target of fixture.targets) {
  const product = target.name === 'ohosTest' ? 'default' : target.name;
  target.config ??= { buildOption: { externalNativeOptions: {} } };
  const native = target.config.buildOption.externalNativeOptions;
  native.arguments ??= fixture.buildOptionSet[0].externalNativeOptions.arguments;
  native.arguments = native.arguments.replace(/-DMC_OHOS_BUILD_TESTS=\S+/, `-DMC_OHOS_BUILD_TESTS=${product === 'default' ? 'AUTO' : 'OFF'}`)
    + ` -DAMCL_BUILD_PRODUCT=${product}`;
}
assert.deepEqual(evaluateInputBuildProfile(fixture), []);

const debugOverrideLost = structuredClone(fixture);
debugOverrideLost.buildOptionSet[0].externalNativeOptions.arguments =
  '-DMC_OHOS_BUILD_TESTS=ON';
assert.ok(evaluateInputBuildProfile(debugOverrideLost)
  .some(issue => issue.includes('buildOptionSet[debug]') && issue.includes('TYPED')));

const targetScalarOverride = structuredClone(fixture);
targetScalarOverride.targets[0].config = {
  buildOption: { externalNativeOptions: { arguments: '-DMC_OHOS_BUILD_TESTS=ON' } },
};
assert.ok(evaluateInputBuildProfile(targetScalarOverride)
  .some(issue => issue.includes('effective default/debug') && issue.includes('TYPED')));

const legacyClaimsFormal = structuredClone(fixture);
legacyClaimsFormal.targets[2].config.buildOption.externalNativeOptions.arguments +=
  ' -DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON';
assert.ok(evaluateInputBuildProfile(legacyClaimsFormal)
  .some(issue => issue.includes('effective store/debug') && issue.includes('exactly once')));

const legacyClaimsRaw = structuredClone(fixture);
legacyClaimsRaw.targets[2].config.buildOption.externalNativeOptions.arguments =
  legacyClaimsRaw.targets[2].config.buildOption.externalNativeOptions.arguments
    .replace('AMCL_GLFW_API26_RAW_MOUSE_MOTION=ON', 'AMCL_GLFW_API26_RAW_MOUSE_MOTION=OFF');
assert.ok(evaluateInputBuildProfile(legacyClaimsRaw)
  .some(issue => issue.includes('effective store/debug') && issue.includes('RAW_MOUSE_MOTION')));

for (const truthy of ['ON', '1', 'TRUE', 'YES', 'Y', '2', '00', 'anything']) {
  assert.equal(cmakeValueLooksEnabled(truthy), true, `CMake truthy ${truthy}`);
  const mobileClaimsRaw = structuredClone(fixture);
  for (const mode of mobileClaimsRaw.buildOptionSet) {
    mode.externalNativeOptions.arguments +=
      ` -DAMCL_GLFW_API26_RAW_MOUSE_MOTION:BOOL=${truthy}`;
  }
  assert.ok(evaluateInputBuildProfile(mobileClaimsRaw)
    .some(issue => issue.includes('buildOptionSet[debug]') &&
      issue.includes('exactly once')),
  `duplicate universal raw truthy ${truthy} must fail closed`);
}

for (const falsey of ['', '0', 'OFF', 'NO', 'FALSE', 'N', 'IGNORE',
  'NOTFOUND', 'SDK-NOTFOUND']) {
  assert.equal(cmakeValueLooksEnabled(falsey), false, `CMake falsey ${falsey}`);
}

const extraTarget = structuredClone(fixture);
extraTarget.targets.push({ name: 'futureDesktop' });
assert.ok(evaluateInputBuildProfile(extraTarget)
  .some(issue => issue.includes('unreviewed target=futureDesktop')));

const duplicateTarget = structuredClone(fixture);
duplicateTarget.targets.push({ name: 'default' });
assert.ok(evaluateInputBuildProfile(duplicateTarget)
  .some(issue => issue.includes('duplicate target=default')));

const extraMode = structuredClone(fixture);
extraMode.buildOptionSet.push({
  name: 'profile', externalNativeOptions: { arguments: '' },
});
assert.ok(evaluateInputBuildProfile(extraMode)
  .some(issue => issue.includes('unreviewed buildOptionSet[profile]')));

const duplicateMode = structuredClone(fixture);
duplicateMode.buildOptionSet.push(structuredClone(duplicateMode.buildOptionSet[0]));
assert.ok(evaluateInputBuildProfile(duplicateMode)
  .some(issue => issue.includes('duplicate buildOptionSet[debug]')));

const undefinesProtectedFlag = structuredClone(fixture);
undefinesProtectedFlag.buildOptionSet[0].externalNativeOptions.arguments +=
  ' -UAMCL_GLFW_TYPED_PHYSICAL_DEFAULT';
assert.ok(evaluateInputBuildProfile(undefinesProtectedFlag)
  .some(issue => issue.includes('must not use CMake -U')));

const preloadOverridesCache = structuredClone(fixture);
preloadOverridesCache.buildOptionSet[0].externalNativeOptions.arguments +=
  ' -Cinput-overrides.cmake';
assert.ok(evaluateInputBuildProfile(preloadOverridesCache)
  .some(issue => issue.includes('must not use a CMake -C')));

console.log('test-check-input-build-profile: route precedence, CMake truth values and target closure passed');

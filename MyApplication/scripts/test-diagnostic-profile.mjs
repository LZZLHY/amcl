import assert from 'node:assert/strict';
import { diagnosticProfile, DIAGNOSTIC_FLAGS } from './diagnostic-profile.mjs';

assert.equal(diagnosticProfile('default').mode, 'debug');
assert.equal(diagnosticProfile('default').mask, 3);
assert.equal(diagnosticProfile('default', 'release').mask, 1);
// 开发身份本身不能开启资源 trace；显式申请在 release/debug 都只增加固定的位 9。
assert.equal(diagnosticProfile('default', 'release').flags.AMCL_VULKAN_WSI_TRACE, 'OFF');
assert.equal(diagnosticProfile('default', 'debug').flags.AMCL_VULKAN_WSI_TRACE, 'OFF');
assert.equal(diagnosticProfile('default', 'release', 'vulkan-trace').mask, 513);
assert.equal(diagnosticProfile('default', 'debug', 'vulkan-trace').mask, 515);
assert.equal(diagnosticProfile('default', 'release', 'vulkan-trace').flags.AMCL_VULKAN_WSI_TRACE, 'ON');
assert.equal(diagnosticProfile('default', 'release', 'tests').flags.MC_OHOS_BUILD_TESTS, 'ON');
assert.equal(diagnosticProfile('default', 'debug', 'mg-exhaustive').flags.AMCL_MG_FRAME_STATS, 'ON');
assert.equal(diagnosticProfile('default', 'debug', 'mg-exhaustive').flags.AMCL_MG_FRAME_STATS_GL_SCOPES, 'ON');
for (const product of ['sideload', 'store', 'desktop']) {
  assert.equal(diagnosticProfile(product).mode, 'release');
  for (const mode of ['debug', 'release']) {
    assert.equal(diagnosticProfile(product, mode).mask, 0);
    for (const requested of Object.keys(DIAGNOSTIC_FLAGS)) {
      assert.throws(() => diagnosticProfile(product, mode, requested), /default-only/);
    }
  }
}
assert.throws(() => diagnosticProfile('default', 'debug', 'typo'), /Unknown diagnostic/);
assert.throws(() => diagnosticProfile('default', 'typo'), /Unknown build mode/);
console.log('diagnostic-profile: product/mode independence, opt-in closure and production rejection PASS');

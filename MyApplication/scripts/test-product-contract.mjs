import assert from 'node:assert/strict';
import { readProductRegistry, assertPublishable } from './product-contract.mjs';
import { evaluateProductRegistry, checkProductSources } from './check-product-contract.mjs';
const registry = readProductRegistry();
assert.deepEqual(evaluateProductRegistry(registry), []);
assert.deepEqual(checkProductSources(), []);
assert.throws(() => assertPublishable('default'), /cannot be published/);
assert.throws(() => assertPublishable('desktopLegacy'), /Unknown product/);
for (const name of ['sideload', 'store', 'desktop']) assert.equal(assertPublishable(name).name, name);
for (const mutate of [
  r => { r.products.default.publishable = true; },
  r => { r.products.sideload.channel = 'store'; },
  r => { r.families.universal.deviceTypes = ['phone', 'tablet']; },
  r => { r.families.universal.legacyCompatibility = false; },
  r => { r.families.universal.touchControls = false; },
  r => { r.products.store.distributionDevices.push('phone'); },
  r => { r.products.store.compatibleSdkVersion = '26.0.0'; },
  r => { r.families.desktop.touchControls = true; },
]) {
  const bad = structuredClone(registry); mutate(bad);
  assert.ok(evaluateProductRegistry(bad).length, 'invalid product must fail closed');
}
console.log('test-product-contract: universal parity, channel/device separation, legacy inclusion and publication guards passed');

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readProductRegistry, assertPublishable, parseJson5 } from './product-contract.mjs';
import { evaluateProductRegistry, checkProductSources, evaluateProductPages } from './check-product-contract.mjs';
const registry = readProductRegistry();
assert.deepEqual(evaluateProductRegistry(registry), []);
assert.deepEqual(checkProductSources(), []);
// 对真实各产品的有效注册表逐个移除两个更新路由，重现发行覆盖清单漏页。
// store 保持原渠道边界；不能通过给商店包加入侧载安装页来掩盖回归。
const module = parseJson5(readFileSync(new URL('../entry/build-profile.json5', import.meta.url), 'utf8'));
const sharedPages = JSON.parse(readFileSync(new URL('../entry/src/main/resources/base/profile/main_pages.json', import.meta.url), 'utf8')).src;
for (const name of ['default', 'sideload', 'desktop']) {
  const target = module.targets.find(item => item.name === name);
  const pages = target.source?.pages ?? sharedPages;
  assert.deepEqual(evaluateProductPages(pages, name), []);
  for (const route of ['pages/SoftwareUpdatePage', 'pages/SideloadUpdatePage']) {
    assert.ok(evaluateProductPages(pages.filter(page => page !== route), name)
      .some(issue => issue.includes(route)), `${name} must reject absent route ${route}`);
  }
  assert.ok(evaluateProductPages([], name).length);
}
assert.deepEqual(evaluateProductPages(module.targets.find(item => item.name === 'store').source.pages, 'store'), []);
assert.ok(evaluateProductPages(undefined, 'sideload').length);
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
console.log('test-product-contract: universal parity, channel/device separation, publication guards and effective update routes passed');

import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inspectSource, buildInventory } from './graphics-profile-inventory.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sample = inspectSource('entry/src/main/cpp/sample.cpp', `
  // setenv("AMCL_FAKE", "1")
  setenv("MOBILEGL_BACKEND_TYPE", "DirectGLES", 1);
  getenv("NEED_OPENGL");
  setSystemProperty(env, "org.lwjgl.vulkan.libname", "libvulkan.so");
  setSystemProperty(env, "amcl.graphics.plan", "v1");
`);
assert.deepEqual(sample.references.map(item => [item.category, item.key]), [
  ['environment-write', 'MOBILEGL_BACKEND_TYPE'],
  ['environment-read', 'NEED_OPENGL'],
  ['property-write', 'org.lwjgl.vulkan.libname'],
  ['property-write', 'amcl.graphics.plan'],
]);
const inventory = buildInventory(root);
assert.equal(inventory.schema, 1);
assert.equal(new Set(inventory.sources.map(item => item.path)).size, inventory.sources.length);
for (const source of ['GraphicsProfileRegistry.ets', 'GraphicsProfileResolver.ets', 'GraphicsSelectionTypes.ets',
  'GraphicsBackendPlan.ets', 'GraphicsCapabilityContract.ets', 'graphics_profile_mirror.generated.h', 'graphics_backend_session.cpp']) {
  assert.ok(inventory.sources.some(item => item.path.endsWith(source) && item.present), source + ' must be inventoried');
}
assert.ok(inventory.sources.some(item => item.path.endsWith('graphics_plan.cpp') && item.present));
assert.ok(inventory.sources.some(item => item.path.endsWith('RendererBackendRegistry.ets')));
assert.ok(inventory.products.some(item => item.product === 'desktop'));
assert.ok(inventory.artifacts.every(item => item.evidence === 'WORKSPACE_FILE_ONLY'));
assert.ok(inventory.limits.some(item => item.includes('do not prove')));
console.log(`test-graphics-profile-inventory PASS (${inventory.sources.length} sources, ${inventory.artifacts.length} workspace artifacts)`);

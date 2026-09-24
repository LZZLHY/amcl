import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PRODUCT_ROOT, productDefinition, readProductRegistry, productMetadataSource, parseJson5, assertPublishable } from './product-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { checkDiagnosticSources } from './diagnostic-source-policy.mjs';
import { auditGraphicsManifest } from './graphics-artifact-manifest.mjs';
import { graphicsBootstrapIssues } from './graphics-bootstrap-contract.mjs';

const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const equal = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
export function evaluateProductRegistry(registry) {
  const issues = [];
  if (registry.schemaVersion !== 1) issues.push('unknown product registry schema');
  for (const name of ['default', 'sideload', 'store']) {
    const p = productDefinition(name, registry);
    if (p.family !== 'universal' || !equal(p.deviceTypes, ['phone', 'tablet', '2in1']) ||
        !p.touchControls || !p.desktopFrontend || !p.legacyCompatibility || !p.runtimeRawMouse) {
      issues.push(`${name} must include all universal frontends and compatibility capabilities`);
    }
  }
  const dev = productDefinition('default', registry);
  const side = productDefinition('sideload', registry);
  const normalized = p => ({ ...p, name: '', publishable: false, developerDiagnostics: false, defaultBuildMode: '' });
  if (!equal(normalized(dev), normalized(side))) issues.push('default/sideload product drift');
  if (dev.publishable || !side.publishable) issues.push('default must not publish; sideload must publish');
  const store = productDefinition('store', registry);
  const universalCore = p => ({ ...normalized(p), channel: '', distributionDevices: [] });
  if (!equal(universalCore(dev), universalCore(store))) issues.push('store must share the universal capability and SDK contract');
  if (store.channel !== 'store' || !equal(store.distributionDevices, ['tablet', '2in1'])) {
    issues.push('store must keep tablet/2in1-only market distribution');
  }
  const desktop = productDefinition('desktop', registry);
  if (desktop.touchControls || desktop.family !== 'desktop' || !equal(desktop.deviceTypes, ['2in1'])) {
    issues.push('desktop-only must exclude touch experience and mobile devices');
  }
  if (registry.products.desktopLegacy || registry.families.desktopLegacy) issues.push('desktopLegacy is retired and must not be generated');
  for (const name of Object.keys(registry.products)) {
    const p = productDefinition(name, registry);
    if (p.graphicsArtifactSet !== 'complete') issues.push(`${name}: graphics artifact policy must be explicit and complete`);
    if (p.developerDiagnostics !== (name === 'default') || p.defaultBuildMode !== (name === 'default' ? 'debug' : 'release')) {
      issues.push(`${name}: developer capability/default build mode drift`);
    }
  }
  return issues;
}

export function evaluateProductHap(buffer, name, publishing = false) {
  const expected = productDefinition(name);
  const module = JSON.parse(readUniqueZipEntry(buffer, 'module.json').toString('utf8'));
  const metadata = JSON.parse(readUniqueZipEntry(buffer, 'resources/rawfile/product-profile.json').toString('utf8'));
  const { schemaVersion, build, ...observed } = metadata;
  const issues = auditGraphicsManifest(buffer, name);
  issues.push(...graphicsBootstrapIssues(module.app));
  if (publishing && build?.nativeGlValidation) issues.push('Native GL validation artifacts cannot be published');
  if (publishing && (module.app.buildMode !== 'release' || module.app.debug !== false)) issues.push('publishing requires a Release HAP');
  if (schemaVersion !== 1 || !equal(observed, expected)) issues.push('HAP product metadata does not match requested product');
  if (!equal([...module.module.deviceTypes].sort(), [...expected.deviceTypes].sort())) issues.push('HAP deviceTypes mismatch');
  const bytecode = readUniqueZipEntry(buffer, 'ets/modules.abc');
  if (!bytecode.includes(Buffer.from('DesktopGameControlSurface'))) issues.push('HAP shared desktop frontend missing');
  if (bytecode.includes(Buffer.from('GameControls')) !== expected.touchControls) issues.push('HAP touch frontend inclusion disagrees with product');
  if (expected.family === 'desktop') {
    const pages = readUniqueZipEntry(buffer, 'resources/base/profile/main_pages.json').toString('utf8');
    if (/LayoutListPage|LayoutEditorPage/.test(pages)) issues.push('desktop HAP still contains mobile layout pages');
    const layoutOpen = (module.module.abilities ?? []).some(ability =>
      (ability.skills ?? []).some(skill => (skill.uris ?? []).some(uri =>
        uri.type === 'general.json' && uri.linkFeature === 'FileOpen')));
    if (layoutOpen) issues.push('desktop HAP still advertises layout JSON FileOpen');
  }
  return issues;
}

export function checkProductSources(root = PRODUCT_ROOT) {
  const registry = readProductRegistry(root);
  const issues = evaluateProductRegistry(registry);
  issues.push(...graphicsBootstrapIssues(parseJson5(readFileSync(resolve(root, 'AppScope/app.json5'), 'utf8')).app));
  issues.push(...checkDiagnosticSources(root));
  const module = parseJson5(readFileSync(resolve(root, 'entry/build-profile.json5'), 'utf8'));
  if (module.targets.some(t => t.name === 'desktopLegacy')) issues.push('retired desktopLegacy target is present');
  for (const name of Object.keys(registry.products)) {
    const p = productDefinition(name, registry);
    const target = module.targets.find(t => t.name === name);
    if (!target || !equal(target.config.deviceType, p.deviceTypes)) issues.push(`${name}: target deviceTypes drift`);
    const metaPath = name === 'default' ? 'entry/src/main/ProductBuildProfile.ets' : `entry/src/${name}/ProductBuildProfile.ets`;
    if (!existsSync(resolve(root, metaPath)) || readFileSync(resolve(root, metaPath), 'utf8').replace(/\r\n/g, '\n') !== productMetadataSource(name, registry)) {
      issues.push(`${name}: generated ArkTS product identity is stale`);
    }
    if (name !== 'default' && !target?.source?.sourceRoots?.includes(`./src/${name}`)) issues.push(`${name}: metadata sourceRoot missing`);
    for (const profilePath of ['build-profile.json5.template', 'build-profile.json5']) {
      if (!existsSync(resolve(root, profilePath))) continue;
      const profile = parseJson5(readFileSync(resolve(root, profilePath), 'utf8'));
      const product = profile.app.products.find(item => item.name === name);
      if (!product || product.targetSdkVersion !== p.targetSdkVersion || product.compatibleSdkVersion !== p.compatibleSdkVersion) issues.push(`${name}: SDK contract drift in ${profilePath}`);
    }
  }
  return issues;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const productIndex = process.argv.indexOf('--product');
    const name = productIndex >= 0 ? process.argv[productIndex + 1] : 'default';
    if (process.argv.includes('--publish')) assertPublishable(name);
    const issues = checkProductSources();
    const hapIndex = process.argv.indexOf('--hap');
    if (hapIndex >= 0) issues.push(...evaluateProductHap(readFileSync(process.argv[hapIndex + 1]), name, process.argv.includes('--publish')));
    if (issues.length) throw new Error(issues.join('\n'));
    console.log(`[product-contract] PASS ${name}${hapIndex >= 0 ? ' artifact' : ' source'}`);
  } catch (error) { console.error(`[product-contract] FAIL: ${error.message}`); process.exitCode = 1; }
}

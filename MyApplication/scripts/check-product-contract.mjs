import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PRODUCT_ROOT, productDefinition, readProductRegistry, productMetadataSource, parseJson5, assertPublishable } from './product-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { checkDiagnosticSources } from './diagnostic-source-policy.mjs';
import { auditGraphicsManifest } from './graphics-artifact-manifest.mjs';
import { graphicsBootstrapIssues } from './graphics-bootstrap-contract.mjs';
import { assertRuntimeHostMirror, validateRuntimeHostMetadata } from './runtime-host-contract.mjs';
import {assertAppRuntimeCoverage,projectLegacyCatalogFromV2} from './runtime-catalog-contract/lib/catalog-v2.mjs';

const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const equal = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));

/** 发行前检查同一HAP的首次启动目录；独立导出便于用真实ZIP字节验证缺失、旧包与资格反例。 */
export function runtimeBootstrapIssues(buffer,metadata,app){
  if(!(metadata.runtimeRequiredMajors??[]).length)return[];
  try{
    const bytes=readUniqueZipEntry(buffer,'resources/rawfile/runtime-catalog/builtin.json');
    if(bytes.length>1048576)throw Error('HAP runtime bootstrap exceeds limit');
    const builtin=JSON.parse(bytes.toString('utf8'));
    if(builtin.schemaVersion!==2)throw Error('HAP runtime bootstrap must use v2');
    assertAppRuntimeCoverage([builtin,projectLegacyCatalogFromV2(builtin)],{...metadata,minApi:app.minAPIVersion%1000,abi:'arm64-v8a'});
    return[];
  }catch(error){return['HAP stable runtime bootstrap is not publication-ready: '+error.message];}
}

/**
 * 核对产品真正生效的页面列表，防止共享清单包含路由、发行目标覆盖清单却遗漏。
 * default/sideload/desktop 均使用侧载更新通道；store 由渠道策略禁用侧载更新，
 * 无须为了通过本门而把安装页加入商店产物。源码门与 HAP 门使用同一契约，
 * 后者必须读取 ZIP 内实际 main_pages，不能拿仓库文件替代产物证明。
 */
export function evaluateProductPages(pages, name) {
  if (!Array.isArray(pages) || pages.some(page => typeof page !== 'string')) {
    return [`${name}: page manifest must contain a string src array`];
  }
  if (productDefinition(name).channel !== 'sideload') return [];
  return ['pages/SoftwareUpdatePage', 'pages/SideloadUpdatePage']
    .filter(page => !pages.includes(page))
    .map(page => `${name}: required update route missing: ${page}`);
}

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

/** 审核实际HAP与请求产品并返回违规项；ZIP结构错误原样抛出，宿主能力单独核对而不混入产品轴。 */
export function evaluateProductHap(buffer, name, publishing = false) {
  const expected = productDefinition(name);
  const module = JSON.parse(readUniqueZipEntry(buffer, 'module.json').toString('utf8'));
  const metadata = JSON.parse(readUniqueZipEntry(buffer, 'resources/rawfile/product-profile.json').toString('utf8'));
  const { schemaVersion, build, sourceRevision, releaseKind, runtimeHostProtocols, runtimePlanProtocol, runtimeCatalogProtocol, runtimeRequiredCapabilities, runtimeRequiredMajors, ...observed } = metadata;
  const issues = auditGraphicsManifest(buffer, name);
  try { validateRuntimeHostMetadata(metadata, module.app.versionName); }
  catch (error) { issues.push(error.message); }
  if(publishing&&(metadata.runtimeRequiredMajors??[]).length){
    // GitHub原件公开之前的本地发行门；不能只依赖后续官网同步才发现初始化目录仍推荐旧包。
    issues.push(...runtimeBootstrapIssues(buffer,metadata,module.app));
  }
  issues.push(...graphicsBootstrapIssues(module.app));
  if (publishing && build?.nativeGlValidation) issues.push('Native GL validation artifacts cannot be published');
  if (publishing && (module.app.buildMode !== 'release' || module.app.debug !== false)) issues.push('publishing requires a Release HAP');
  if (schemaVersion !== 1 || !equal(observed, expected)) issues.push('HAP product metadata does not match requested product');
  // 源码身份为单独的载荷字段，不能混入产品定义比较，也不能接受缺失或任意短标签。
  if (typeof sourceRevision !== 'string' || !/^[0-9a-f]{40}$/.test(sourceRevision)) issues.push('HAP source revision missing or invalid');
  if (!equal([...module.module.deviceTypes].sort(), [...expected.deviceTypes].sort())) issues.push('HAP deviceTypes mismatch');
  const bytecode = readUniqueZipEntry(buffer, 'ets/modules.abc');
  // SDK 会把 target.source.pages 写入包内注册表；编译了页面字节码仍可能没有可达路由。
  const pages = JSON.parse(readUniqueZipEntry(buffer, 'resources/base/profile/main_pages.json').toString('utf8')).src;
  issues.push(...evaluateProductPages(pages, name));
  if (!bytecode.includes(Buffer.from('DesktopGameControlSurface'))) issues.push('HAP shared desktop frontend missing');
  if (bytecode.includes(Buffer.from('GameControls')) !== expected.touchControls) issues.push('HAP touch frontend inclusion disagrees with product');
  if (expected.family === 'desktop') {
    if (pages.some(page => /LayoutListPage|LayoutEditorPage/.test(page))) issues.push('desktop HAP still contains mobile layout pages');
    const layoutOpen = (module.module.abilities ?? []).some(ability =>
      (ability.skills ?? []).some(skill => (skill.uris ?? []).some(uri =>
        uri.type === 'general.json' && uri.linkFeature === 'FileOpen')));
    if (layoutOpen) issues.push('desktop HAP still advertises layout JSON FileOpen');
  }
  return issues;
}

/** 核对产品、SDK与生成镜像；只读取固定源码输入，缺失或漂移不能由旧产物补齐。 */
export function checkProductSources(root = PRODUCT_ROOT) {
  const registry = readProductRegistry(root);
  const issues = evaluateProductRegistry(registry);
  try { assertRuntimeHostMirror(root); }
  catch (error) { issues.push(error.message); }
  issues.push(...graphicsBootstrapIssues(parseJson5(readFileSync(resolve(root, 'AppScope/app.json5'), 'utf8')).app));
  issues.push(...checkDiagnosticSources(root));
  const module = parseJson5(readFileSync(resolve(root, 'entry/build-profile.json5'), 'utf8'));
  const sharedPages = JSON.parse(readFileSync(resolve(root, 'entry/src/main/resources/base/profile/main_pages.json'), 'utf8')).src;
  if (module.targets.some(t => t.name === 'desktopLegacy')) issues.push('retired desktopLegacy target is present');
  for (const name of Object.keys(registry.products)) {
    const p = productDefinition(name, registry);
    const target = module.targets.find(t => t.name === name);
    // 仅未声明覆盖清单的目标继承共享清单；空数组也属于真实覆盖，不能用 truthy 回退掩盖缺页。
    issues.push(...evaluateProductPages(target?.source?.pages ?? sharedPages, name));
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

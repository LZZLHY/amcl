import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { productDefinition, PRODUCT_ROOT } from './product-contract.mjs';
import { parseGraphicsRegistry } from './lib/graphics-profile-registry.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

export function graphicsArtifactManifest(product, root = PRODUCT_ROOT) {
  const definition = productDefinition(product);
  if (definition.graphicsArtifactSet !== 'complete') throw new Error('Unsupported graphics artifact policy');
  const source = fs.readFileSync(path.join(root, 'launch/src/main/ets/GraphicsProfileRegistry.ets'), 'utf8');
  const profiles = parseGraphicsRegistry(source).filter(p => p.lifecycle !== 'retired').map(p => ({
    id: p.id, apiFamily: p.api, abi: 'arm64-v8a', artifactIds: p.artifactIds,
    providers: p.windowProviders, license: p.license,
    requirementIds: [p.requirementId, ...(p.requirementIds ?? [])], requiredCapabilities: p.requiredCapabilities,
    systemLibraries: p.systemLibrary ? [p.glLibName, 'libEGL.so'] : [],
  }));
  return { schemaVersion: 1, artifactSet: definition.graphicsArtifactSet, abi: 'arm64-v8a',
    registrySha256: createHash('sha256').update(source.replace(/\r\n/g, '\n')).digest('hex'),
    availableProfileIds: profiles.map(p => p.id), profiles };
}

export function auditGraphicsManifest(buffer, product) {
  const expected = graphicsArtifactManifest(product);
  const actual = JSON.parse(readUniqueZipEntry(buffer, 'resources/rawfile/graphics-manifest.json'));
  const issues = [];
  if (JSON.stringify(actual) !== JSON.stringify(expected)) issues.push('HAP graphics manifest differs from canonical registry/policy');
  for (const profile of expected.profiles) for (const library of profile.artifactIds) {
    try {
      const bytes = readUniqueZipEntry(buffer, `libs/${expected.abi}/${library}`);
      if (bytes.length < 64 || bytes.toString('hex', 0, 6) !== '7f454c460201' || bytes.readUInt16LE(18) !== 183)
        issues.push(`${profile.id}: ${library} is not ELF64 AArch64`);
    } catch (error) { issues.push(`${profile.id}: artifact-missing ${library}: ${error.message}`); }
  }
  return issues;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const value = flag => process.argv[process.argv.indexOf(flag) + 1];
  const product = process.argv.includes('--product') ? value('--product') : 'default';
  if (process.argv.includes('--hap')) {
    const issues = auditGraphicsManifest(fs.readFileSync(value('--hap')), product);
    if (issues.length) throw new Error(issues.join('\n'));
    console.log('graphics-manifest PASS ' + product + ': declarations + HAP artifacts/ABI');
  } else {
    const target = path.join(PRODUCT_ROOT, 'entry/src/main/resources/rawfile/graphics-manifest.json');
    fs.writeFileSync(target, JSON.stringify(graphicsArtifactManifest(product), null, 2) + '\n');
    console.log('graphics-manifest generated ' + product);
  }
}

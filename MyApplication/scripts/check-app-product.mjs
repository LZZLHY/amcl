import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { PRODUCT_ROOT, assertPublishable } from './product-contract.mjs';
import { evaluateProductHap } from './check-product-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { verifyHapSignature } from './check-mg-build-contract.mjs';
import { archiveNames, verifyNestedPayload, compactJsonFormatting } from './app-product-contract.mjs';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function argument(name) {
  const i = process.argv.indexOf(name);
  if (i < 0 || !process.argv[i + 1] || process.argv[i + 1].startsWith('--')) throw new Error(`${name} is required`);
  return process.argv[i + 1];
}

try {
  const product = assertPublishable(argument('--product'));
  if (product.channel !== 'store') throw new Error('APP distribution requires the store channel');
  const appPath = resolve(argument('--app'));
  const hapPath = resolve(argument('--hap'));
  const provenancePath = resolve(argument('--provenance'));
  const app = readFileSync(appPath), hap = readFileSync(hapPath);
  const provenance = JSON.parse(readFileSync(provenancePath, 'utf8'));
  const modules = archiveNames(app).filter(name => /\.(hap|hsp)$/i.test(name));
  if (modules.length !== 1 || !modules[0].endsWith('.hap')) throw new Error('Current product must package exactly one audited HAP and no HSP');
  const embedded = readUniqueZipEntry(app, modules[0]);
  if (compactJsonFormatting(readUniqueZipEntry(app, 'pack.info')) !==
      compactJsonFormatting(readUniqueZipEntry(embedded, 'pack.info'))) {
    throw new Error('APP pack.info does not match its nested HAP');
  }
  if (provenance.variant?.artifactKind !== 'unsigned') throw new Error('APP binding requires the audited unsigned HAP');
  const payloadSha256 = verifyNestedPayload(embedded, hap);
  if (provenance.variant?.product !== product.name || provenance.variant?.buildMode !== 'release' ||
      provenance.artifacts?.hap?.sha256 !== sha(hap) ||
      !['valid-signature', 'no-valid-signature'].includes(provenance.signatureVerification?.result)) {
    throw new Error('HAP provenance is missing, stale, or bound to another product');
  }
  const issues = evaluateProductHap(embedded, product.name);
  if (issues.length) throw new Error(issues.join('\n'));
  const signature = verifyHapSignature({ root: PRODUCT_ROOT, hapPath: appPath, hapKind: 'signed' });
  if (process.argv.includes('--require-clean') && provenance.source?.superproject?.dirty !== false) {
    throw new Error('Release APP requires a clean immutable HAP source');
  }
  const report = {
    schemaVersion: 1, product: product.name, channel: product.channel,
    supportedDevices: product.deviceTypes, marketDistributionDevices: product.distributionDevices,
    app: { path: appPath, sha256: sha(app) },
    embeddedHap: { name: modules[0], sha256: sha(embedded), payloadSha256,
      referenceSha256: sha(hap), binding: 'all-entries-identical-except-pack-info-whitespace' },
    hapProvenanceSha256: sha(readFileSync(provenancePath)), signature,
    cleanSource: provenance.source?.superproject?.dirty === false,
    marketApprovalVerified: false,
  };
  writeFileSync(resolve(argument('--out')), JSON.stringify(report, null, 2) + '\n');
  console.log(`[app-product] PASS ${product.name}: signed APP, all HAP payloads bound (pack.info formatting normalized), tablet/2in1 market policy`);
} catch (error) {
  console.error(`[app-product] FAIL: ${error.message}`);
  process.exitCode = 1;
}

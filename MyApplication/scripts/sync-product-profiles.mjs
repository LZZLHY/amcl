import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { PRODUCT_ROOT, readProductRegistry, productMetadataSource } from './product-contract.mjs';

const registry = readProductRegistry();
let stale = false;
for (const name of Object.keys(registry.products)) {
  const relative = name === 'default' ? 'entry/src/main/ProductBuildProfile.ets'
    : `entry/src/${name}/ProductBuildProfile.ets`;
  const path = resolve(PRODUCT_ROOT, relative);
  const expected = productMetadataSource(name, registry);
  if (existsSync(path) && readFileSync(path, 'utf8').replace(/\r\n/g, '\n') === expected) continue;
  if (process.argv.includes('--check')) {
    console.error(`[product-profile] stale: ${relative}`);
    stale = true;
  } else {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, expected);
    console.log(`[product-profile] wrote ${relative}`);
  }
}
if (stale) process.exitCode = 1;

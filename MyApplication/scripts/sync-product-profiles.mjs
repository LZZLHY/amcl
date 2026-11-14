/** 根据产品/宿主配置生成纯ArkTS镜像；--check只读并在漂移时失败，普通模式只改对应派生文件。 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { PRODUCT_ROOT, readProductRegistry, productMetadataSource } from './product-contract.mjs';
import { runtimeHostSource } from './runtime-host-contract.mjs';

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
// 宿主能力与产品身份一起生成，源码镜像和产物 JSON 必须来自同一份显式能力集合。
const hostPath = resolve(PRODUCT_ROOT, 'launch/src/main/ets/RuntimeHostCapabilities.ets');
const hostExpected = runtimeHostSource();
if (!existsSync(hostPath) || readFileSync(hostPath, 'utf8').replace(/\r\n/g, '\n') !== hostExpected) {
  if (process.argv.includes('--check')) { console.error('[runtime-host] stale generated ArkTS capability'); stale = true; }
  else { mkdirSync(dirname(hostPath), { recursive: true }); writeFileSync(hostPath, hostExpected); }
}
if (stale) process.exitCode = 1;

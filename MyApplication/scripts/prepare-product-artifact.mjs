import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { PRODUCT_ROOT, productDefinition } from './product-contract.mjs';
import { diagnosticProfile } from './diagnostic-profile.mjs';
import { graphicsArtifactManifest } from './graphics-artifact-manifest.mjs';
import { execFileSync } from 'node:child_process';

const index = process.argv.indexOf('--product');
if (index < 0 || !process.argv[index + 1]) throw new Error('--product is required');
const definition = productDefinition(process.argv[index + 1]);
const rawRoot = resolve(PRODUCT_ROOT, 'entry/src/main/resources/rawfile');
mkdirSync(rawRoot, { recursive: true });
const modeIndex = process.argv.indexOf('--mode');
const build = diagnosticProfile(definition.name, modeIndex < 0 ? 'auto' : process.argv[modeIndex + 1], process.env.AMCL_DIAGNOSTICS ?? 'none');
build.nativeGlValidation = process.env.AMCL_DESKTOP_NATIVE_GL_VALIDATE === '1';
if (build.nativeGlValidation && definition.name !== 'desktop') throw new Error('Native GL validation is desktop-only');
// 用实际源码提交作为编译载荷身份，安装后由新进程与事务中的目标身份核对。
const sourceRevision = execFileSync('git', ['-C', PRODUCT_ROOT, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
writeFileSync(resolve(rawRoot, 'product-profile.json'), JSON.stringify({ schemaVersion: 1, ...definition, build, sourceRevision }, null, 2) + '\n');
writeFileSync(resolve(rawRoot, 'graphics-manifest.json'), JSON.stringify(graphicsArtifactManifest(definition.name), null, 2) + '\n');
console.log(`[product-artifact] ${definition.name}: ${definition.family}/${definition.channel}`);

/**
 * SDK资源准备钩子：生成当前产品、编译模式、真实源码提交、发行类型与宿主能力声明。
 * 镜像不一致或版本非法直接中止构建；不会从环境或远端推荐放宽未实现的JDK协议。
 */
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { PRODUCT_ROOT, productDefinition, parseJson5 } from './product-contract.mjs';
import { assertRuntimeHostMirror, releaseKindForVersion } from './runtime-host-contract.mjs';
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
// 发布类型按真实包版本生成；宿主支持集合按已审核源码生成，预览同 code 也不会混淆能力。
const app = parseJson5(readFileSync(resolve(PRODUCT_ROOT, 'AppScope/app.json5'), 'utf8')).app;
const host = assertRuntimeHostMirror();
const runtimeHostProtocols = host.supportedProtocols, runtimePlanProtocol = host.runtimePlanProtocol;
// 当前解析器与发行门使用独立目录协议，v1旧端供给不再被新App的v2要求挤掉。
const runtimeCatalogProtocol = host.runtimeCatalogProtocol;
const runtimeRequiredCapabilities = host.requiredRuntimeCapabilities, runtimeRequiredMajors = host.requiredRuntimeMajors;
const releaseKind = releaseKindForVersion(app.versionName);
writeFileSync(resolve(rawRoot, 'product-profile.json'), JSON.stringify({ schemaVersion: 1, ...definition, build,
  sourceRevision, releaseKind, runtimeHostProtocols, runtimePlanProtocol, runtimeCatalogProtocol, runtimeRequiredCapabilities, runtimeRequiredMajors }, null, 2) + '\n');
writeFileSync(resolve(rawRoot, 'graphics-manifest.json'), JSON.stringify(graphicsArtifactManifest(definition.name), null, 2) + '\n');
console.log(`[product-artifact] ${definition.name}: ${definition.family}/${definition.channel}`);

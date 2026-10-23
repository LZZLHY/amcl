/** 手机签名入口的可复现编译。只编译AMCL源码，依赖API来自本机SDK；运行时使用固定开源签名器。 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, realpathSync, copyFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { assertExternalOutputPath, resolveWorkspacePath } from './lib/workspace-paths.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'entry/src/main/sideload/AmclSigningRunner.java');
const sdk = process.env.DEVECO_SDK_HOME;
if (!sdk) throw new Error('DEVECO_SDK_HOME is required');
const dependency = join(sdk, 'default/openharmony/toolchains/lib/hap-sign-tool.jar');
const build = process.env.AMCL_SIGNER_BUILD_DIR ? assertExternalOutputPath(process.env.AMCL_SIGNER_BUILD_DIR) : resolveWorkspacePath('build','sideload-signer');
const classes = join(build, 'classes');
const output = join(root, 'entry/src/main/resources/rawfile/sideload/amcl-signing-runner.jar');
// DevEco 会把 JAVA_HOME 指向自带 JBR；它可能有 javac/java，却没有封包所需的 jar。
// 按 JAVA_HOME、PATH 的顺序选择同目录工具齐全的 JDK，避免编译和测试完成后才因缺 jar 失败。
const locateCompiler = () => {
  const name = 'javac';
  const suffix = process.platform === 'win32' ? '.exe' : '';
  // 先解析 javac 的真实路径，再检查同目录工具，兼容 PATH 中指向完整 JDK 的符号链接。
  const completeCompiler = candidate => {
    if (!candidate || !existsSync(candidate)) return undefined;
    const compiler = realpathSync(candidate);
    return ['javac', 'java', 'jar'].every(toolName =>
      existsSync(join(dirname(compiler), toolName + suffix))) ? compiler : undefined;
  };
  const explicit = process.env.JAVA_HOME && completeCompiler(join(process.env.JAVA_HOME, 'bin', name + suffix));
  if (explicit) return explicit;
  let candidates = [];
  try {
    // 必须遍历全部匹配项；IDE 还会将不完整的 JBR/bin 放到 PATH 最前面。
    candidates = execFileSync(process.platform === 'win32' ? 'where' : 'which',
      process.platform === 'win32' ? [name] : ['-a', name], { encoding: 'utf8' }).trim().split(/\r?\n/);
  } catch { /* PATH 中没有 javac 时，统一给出完整工具链的配置提示。 */ }
  for (const candidate of candidates) {
    const compiler = completeCompiler(candidate);
    if (compiler) return compiler;
  }
  throw new Error('Cannot locate a complete JDK (javac/java/jar). Set JAVA_HOME to a full JDK 17+ install, or add its bin directory to PATH.');
};
// 编译、执行测试和封包必须来自同一 JDK，避免 PATH 中 Oracle Java8 与现代 javac 混用。
const compiler = locateCompiler();
const tool = name => {
  const candidate = join(dirname(compiler), name + (process.platform === 'win32' ? '.exe' : ''));
  if (!existsSync(candidate)) throw new Error('Selected JDK is incomplete: ' + name);
  return candidate;
};
mkdirSync(classes, { recursive: true }); mkdirSync(dirname(output), { recursive: true });
// 运行时签名器与已真机验收的固定实现相同；构建时核实摘要后打入 HAP，手机无需再向 GitHub 取工具。
const pin = JSON.parse(readFileSync(join(root,'prebuilt/hap-sign-tool/pin.json'),'utf8'));
// Facade不持有业务常量；从唯一执行所有者核对runtime实际消费的固定签名器pin。
const serviceSource = readFileSync(join(root,'entry/src/main/ets/sideload/SideloadUpdateCoordinator.ets'),'utf8');
if (!serviceSource.includes("const SIGNER_SHA256 = '" + pin.sha256 + "'")) throw new Error('Runtime signer pin is not synchronized');
const pinned = join(build,'hap-sign-tool-' + pin.sha256 + '.jar');
function hash(file) { return createHash('sha256').update(readFileSync(file)).digest('hex'); }
if (!existsSync(pinned) || hash(pinned) !== pin.sha256) {
  const response = await fetch(pin.url, {signal:AbortSignal.timeout(90_000)});
  if (!response.ok || Number(response.headers.get('content-length')) > 48*1024*1024) throw new Error('Pinned signer download failed');
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 48*1024*1024 || createHash('sha256').update(bytes).digest('hex') !== pin.sha256) throw new Error('Pinned signer digest mismatch');
  writeFileSync(pinned,bytes);
}
copyFileSync(pinned,join(dirname(output),'hap-sign-tool.jar'));
copyFileSync(join(root,'prebuilt/hap-sign-tool/LICENSE'),join(dirname(output),'hap-sign-tool-LICENSE.txt'));
execFileSync(tool('javac'), ['--release', '17', '-encoding', 'UTF-8', '-cp', dependency, '-d', classes, source], { stdio: 'inherit' });
// 身份规则必须在真实Java实现中验证；测试class留在外部构建树，打包只包含正式入口class。
execFileSync(tool('javac'), ['--release', '17', '-encoding', 'UTF-8', '-cp', classes + (process.platform === 'win32' ? ';' : ':') + dependency,
  '-d', classes, join(root, 'entry/src/main/sideload/tests/SigningIdentityTest.java')], { stdio: 'inherit' });
execFileSync(tool('java'), ['-cp', classes + (process.platform === 'win32' ? ';' : ':') + dependency, 'SigningIdentityTest'], { stdio: 'inherit' });
// 手动包的真实ZIP边界也必须通过；数据与测试class留外置树，不能进入发布JAR。
execFileSync(tool('javac'), ['--release','17','-encoding','UTF-8','-cp',classes + (process.platform === 'win32' ? ';' : ':') + dependency,
  '-d',classes,join(root,'entry/src/main/sideload/tests/ManualPackageInspectionTest.java')],{stdio:'inherit'});
execFileSync(tool('java'), ['-cp',classes + (process.platform === 'win32' ? ';' : ':') + dependency,'ManualPackageInspectionTest',join(build,'manual-package-tests')],{stdio:'inherit'});
// 固定ZIP日期，不因本机当前时间而制造另一个JAR身份。
execFileSync(tool('jar'), ['--create', '--date=2026-01-01T00:00:00Z', '--file', output, '-C', classes, 'AmclSigningRunner.class'], { stdio: 'inherit' });
writeFileSync(join(build, 'provenance.json'), JSON.stringify({ schema: 1, sourceSha256: hash(source),
  compilerDependencySha256: hash(dependency), runtimeSignerSha256:hash(pinned), jarSha256: hash(output), targetJava: 17 }, null, 2));
console.log('[sideload-signer] source compiled, target Java17, sha256=' + hash(output));

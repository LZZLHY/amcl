/** 手机签名入口的可复现编译。仅编译AMCL源码，API可来自SDK或显式固定公开工具；产物有界外置。 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, realpathSync, copyFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { assertExternalOutputPath, resolveSharedWorkspacePath } from './lib/workspace-paths.mjs';
import { prepareSigningTemplates } from './prepare-signing-templates.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'entry/src/main/sideload/AmclSigningRunner.java');
const sdk = process.env.DEVECO_SDK_HOME;
// 宿主/CI可用同一公开pin编译，不把raw资源目录伪装成SDK；显式输入仍必须核精确摘要。
const explicitDependency=process.env.AMCL_SIGNER_COMPILER_JAR;
if (!sdk&&!explicitDependency) throw new Error('DEVECO_SDK_HOME or AMCL_SIGNER_COMPILER_JAR is required');
const dependency = explicitDependency ? resolve(explicitDependency) : join(sdk, 'default/openharmony/toolchains/lib/hap-sign-tool.jar');
// 签名runner的编译缓存属于固定checkout，任务切换不复制或迁移该输入。
const build = process.env.AMCL_SIGNER_BUILD_DIR ? assertExternalOutputPath(process.env.AMCL_SIGNER_BUILD_DIR) : resolveSharedWorkspacePath('build','sideload-signer');
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
if(explicitDependency&&hash(dependency)!==pin.sha256)throw new Error('Explicit compiler tool differs from the public signer pin');
// Facade不持有业务常量；从唯一执行所有者核对runtime实际消费的固定签名器pin。
const serviceSource = readFileSync(join(root,'entry/src/main/ets/sideload/SideloadUpdateCoordinator.ets'),'utf8');
if (!serviceSource.includes("const SIGNER_SHA256 = '" + pin.sha256 + "'")) throw new Error('Runtime signer pin is not synchronized');
const pinned = join(build,'hap-sign-tool-' + pin.sha256 + '.jar');
function hash(file) { return createHash('sha256').update(readFileSync(file)).digest('hex'); }
if (!existsSync(pinned) || hash(pinned) !== pin.sha256) {
  if(explicitDependency)copyFileSync(dependency,pinned);
  else {
  const response = await fetch(pin.url, {signal:AbortSignal.timeout(90_000)});
  if (!response.ok || Number(response.headers.get('content-length')) > 48*1024*1024) throw new Error('Pinned signer download failed');
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 48*1024*1024 || createHash('sha256').update(bytes).digest('hex') !== pin.sha256) throw new Error('Pinned signer digest mismatch');
  writeFileSync(pinned,bytes);
  }
}
copyFileSync(pinned,join(dirname(output),'hap-sign-tool.jar'));
copyFileSync(join(root,'prebuilt/hap-sign-tool/LICENSE'),join(dirname(output),'hap-sign-tool-LICENSE.txt'));
execFileSync(tool('javac'), ['--release', '17', '-encoding', 'UTF-8', '-cp', dependency, '-d', classes, source], { stdio: 'inherit' });
// 身份规则必须在真实Java实现中验证；测试class留在外部构建树，打包只包含正式入口class。
execFileSync(tool('javac'), ['--release', '17', '-encoding', 'UTF-8', '-cp', classes + (process.platform === 'win32' ? ';' : ':') + dependency,
  '-d', classes, join(root, 'entry/src/main/sideload/tests/SigningIdentityTest.java')], { stdio: 'inherit' });
execFileSync(tool('java'), ['-cp', classes + (process.platform === 'win32' ? ';' : ':') + dependency, 'SigningIdentityTest'], { stdio: 'inherit' });
// 证书续期允许旧叶指纹变化；真实密码学回归验证公钥连续、空证书列表和错误密钥拒绝。
execFileSync(tool('javac'), ['--release', '17', '-encoding', 'UTF-8', '-cp', classes + (process.platform === 'win32' ? ';' : ':') + dependency,
  '-d', classes, join(root, 'entry/src/main/sideload/tests/OriginalSigningRecoveryTest.java')], { stdio: 'inherit' });
execFileSync(tool('java'), ['-Damcl.test.output='+build, '-cp', classes + (process.platform === 'win32' ? ';' : ':') + dependency, 'OriginalSigningRecoveryTest'], { stdio: 'inherit' });
// 手动包的真实ZIP边界也必须通过；数据与测试class留外置树，不能进入发布JAR。
execFileSync(tool('javac'), ['--release','17','-encoding','UTF-8','-cp',classes + (process.platform === 'win32' ? ';' : ':') + dependency,
  '-d',classes,join(root,'entry/src/main/sideload/tests/ManualPackageInspectionTest.java')],{stdio:'inherit'});
execFileSync(tool('java'), ['-cp',classes + (process.platform === 'win32' ? ';' : ':') + dependency,'ManualPackageInspectionTest',join(build,'manual-package-tests')],{stdio:'inherit'});
// 固定ZIP日期，不因本机当前时间而制造另一个JAR身份。
await prepareSigningTemplates({root,build,java:tool('java'),classpath:classes+(process.platform==='win32'?';':':')+dependency});
execFileSync(tool('jar'), ['--create', '--date=2026-01-01T00:00:00Z', '--file', output, '-C', classes, 'AmclSigningRunner.class'], { stdio: 'inherit' });
writeFileSync(join(build, 'provenance.json'), JSON.stringify({ schema: 1, sourceSha256: hash(source),
  compilerDependencySha256: hash(dependency), runtimeSignerSha256:hash(pinned), jarSha256: hash(output), targetJava: 17 }, null, 2));
console.log('[sideload-signer] source compiled, target Java17, sha256=' + hash(output));

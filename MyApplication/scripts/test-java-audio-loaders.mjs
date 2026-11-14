/**
 * 真 Fabric Knot、JDK 命名 ModuleLayer、真 Forge ModuleClassLoader 的有界离线 SPI 验证。
 * 所有输入均为现有、已锁定的仓外文件；--output 是外部任务容器，每次原子分配独占 invocation。
 * 不下载、不启动游戏、不 open 音频设备，不复用或删除容器中其他运行留下的夹具与日志。
 * 每个加载器使用独立 JVM，防止 AudioSystem 缓存前一 TCCL 的 provider 后掩盖下一场景缺口。
 */
import { spawnSync, execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, renameSync, rmSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, resolve, dirname, isAbsolute, delimiter, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
function required(name) {
  const index = args.indexOf(name); const value = index < 0 ? null : args[index + 1];
  if (!value || !isAbsolute(value)) throw new Error(`${name} requires an absolute path`);
  return value;
}
const outputRoot = required('--output'), java = required('--java'), javac = required('--javac');
const jar = required('--jar'), launcher = required('--launcher-jar'), fabric = required('--fabric-jar'), inputs = required('--inputs');
assertExternalOutputPath(outputRoot, { root });
mkdirSync(outputRoot, { recursive: true });
// mkdtemp 的创建是原子的；即便容器已有失败现场或另一调用并发执行，也不会接管已有目录。
// 日志与 result 一并写入该独占目录，不能以复用 --output 为由覆盖先前的失败证据。
const output = mkdtempSync(join(outputRoot, 'invocation-'));
process.stdout.write(`[audio-loader] output=${output}\n`);
const createdFixtures = [];
function createFixtureDirectory(name) {
  const path = join(output, name);
  mkdirSync(path); // 不用 recursive 或 exists 容错；只有本轮成功创建的目录才取得清理资格。
  createdFixtures.push(path); return path;
}
const probe = createFixtureDirectory('probe-classes'), runner = createFixtureDirectory('runner-classes');
const bootProbe = createFixtureDirectory('boot-probe-classes'), forgeProbe = createFixtureDirectory('forge-probe-classes');
const probeJar = join(output, 'probe.jar'), bootProbeJar = join(output, 'boot-probe.jar'), forgeProbeJar = join(output, 'forge-probe.jar');
const shadowSources = ['Unlisted.java', 'OhosClipEvil.java', 'OhosClip$NoSuchNested.java']
  .map(name => join(root, 'JavaApp/test/audio-loader-shadow/com/amcl/audio', name));
execFileSync(javac, ['--release', '17', '-encoding', 'UTF-8', '-d', probe,
  join(root, 'JavaApp/test/audio-loader-probe/module-info.java'),
  join(root, 'JavaApp/test/audio-loader-probe/com/amcl/audioprobe/AudioLoaderProbe.java')], { stdio: 'inherit' });
execFileSync(jar, ['--create', '--file', probeJar, '-C', probe, '.'], { stdio: 'inherit' });
createdFixtures.push(probeJar);
execFileSync(javac, ['--release', '17', '-encoding', 'UTF-8', '-d', bootProbe,
  join(root, 'JavaApp/test/audio-loader-boot-probe/module-info.java'),
  join(root, 'JavaApp/test/audio-loader-probe/com/amcl/audioprobe/AudioLoaderProbe.java'), ...shadowSources], { stdio: 'inherit' });
execFileSync(jar, ['--create', '--file', bootProbeJar, '-C', bootProbe, '.'], { stdio: 'inherit' });
createdFixtures.push(bootProbeJar);
execFileSync(javac, ['--release', '17', '-encoding', 'UTF-8', '-d', forgeProbe,
  join(root, 'JavaApp/test/audio-loader-probe/module-info.java'),
  join(root, 'JavaApp/test/audio-loader-probe/com/amcl/audioprobe/AudioLoaderProbe.java'), ...shadowSources], { stdio: 'inherit' });
execFileSync(jar, ['--create', '--file', forgeProbeJar, '-C', forgeProbe, '.'], { stdio: 'inherit' });
createdFixtures.push(forgeProbeJar);
execFileSync(javac, ['--release', '17', '-encoding', 'UTF-8', '-d', runner,
  join(root, 'JavaApp/test/AudioLoaderQualification.java')], { stdio: 'inherit' });
const base = [runner, launcher].join(delimiter);
const fabricDependencies = ['asm', 'asm-tree', 'asm-commons', 'asm-analysis', 'asm-util'].map(name => join(inputs, `${name}-9.10.1.jar`));
fabricDependencies.push(join(inputs, 'sponge-mixin-0.17.4+mixin.0.8.7.jar'));
const forgeDependencies = ['asm', 'asm-tree', 'asm-commons', 'asm-analysis', 'asm-util'].map(name => join(inputs, `${name}-9.5.jar`));
forgeDependencies.push(args.includes('--forge-jar') ? required('--forge-jar') : join(inputs, 'securejarhandler-2.1.10.jar'));
const systemLoader = args.includes('--system-loader') ? ['-Djava.system.class.loader=com.amcl.launcher.AmclClassLoader'] : [];
const agentIndex = args.indexOf('--audio-service-agent');
const agent = agentIndex < 0 ? null : required('--audio-service-agent');
const agentOptions = agent ? ['-Damcl.audio.enabled=' + !args.includes('--disable-audio'),
  '-Damcl.audio.service.schema=1', '-javaagent:' + agent] : [];
if (agent && args.includes('--double-agent')) agentOptions.push('-javaagent:' + agent);
const commands = [
  { mode: 'knot', args: [...systemLoader, '-cp', [base, fabric, ...fabricDependencies].join(delimiter)] },
  { mode: 'layer', args: [...systemLoader, '-cp', base] },
  // opens/exports 来自同一 Forge47.2.0 官方 version.json，未增加测试独有的 JDK 内部权限。
  ...['forge-boot', 'forge'].map(mode => ({ mode, args: [...systemLoader, '--module-path', forgeDependencies.join(delimiter), '--add-modules', 'ALL-MODULE-PATH',
    '--add-opens', 'java.base/java.util.jar=cpw.mods.securejarhandler',
    '--add-opens', 'java.base/java.lang.invoke=cpw.mods.securejarhandler',
    '--add-exports', 'java.base/sun.security.util=cpw.mods.securejarhandler', '-cp', base] })),
];
const results = [];
const modeIndex = args.indexOf('--modes');
const selectedModes = modeIndex < 0 ? null : args[modeIndex + 1].split(',');
if (selectedModes?.some(mode => !commands.some(command => command.mode === mode))) throw new Error('Unknown loader mode');
for (const command of commands) {
  if (selectedModes && !selectedModes.includes(command.mode)) continue;
  const commandArgs = ['-Xverify:all', ...agentOptions, ...command.args, 'AudioLoaderQualification', command.mode,
    command.mode.startsWith('forge') ? forgeProbeJar : probeJar, bootProbeJar];
  const result = spawnSync(java, commandArgs, { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 });
  const text = (result.stdout || '') + (result.stderr || ''); process.stdout.write(text);
  writeFileSync(join(output, `${command.mode}.log`), text);
  results.push({ mode: command.mode, exitCode: result.status, signal: result.signal, error: result.error?.message,
    passed: result.status === 0, command: [java, ...commandArgs], output: text });
}
const identity = path => ({ path, sha256: createHash('sha256').update(readFileSync(path)).digest('hex') });
const passed = results.every(result => result.passed);
const fixtureIdentity = [probeJar, bootProbeJar, forgeProbeJar].map(identity);
const retireFixtures = passed && !args.includes('--retain-fixtures');
const receipt = { schemaVersion: 1, createdAt: new Date().toISOString(), outputRoot, output,
  ownedFixturePaths: createdFixtures, java, javac,
  launcher: identity(launcher), fabric: identity(fabric), agent: agent ? identity(agent) : null,
  dependencies: [...fabricDependencies, ...forgeDependencies].map(identity),
  fixtureIdentity, storageStatus: retireFixtures ? 'success-fixtures-pending-cleanup' : 'retained-for-failure-or-debug',
  devicesOpened: 0, nativeLoaded: false, scope: 'pre-transform Knot + named JDK layer + actual BOOT default Platform / GAME fallback BOOT; no full game boot', results };
function persistReceipt() {
  // 先完整写独占临时文件再原子替换；第二次更新若失败，首次保存的来源与结果收据仍可恢复。
  const pending = join(output, 'result.next.json');
  writeFileSync(pending, JSON.stringify(receipt, null, 2), { flag: 'wx' });
  renameSync(pending, join(output, 'result.json'));
}
persistReceipt(); // 任何清理前先固定身份、命令、结果及本轮亲建清单，收据失败则保留全部现场。
// 仅本次原子新目录内、创建成功后记入清单的夹具可回收，再核对真实绝对路径属于本轮 invocation。
// 失败和显式调试保留现场；成功所需的来源摘要、日志及命令仍留在小型 result.json。
if (retireFixtures) {
  const physicalRoot = realpathSync(output);
  for (const target of createdFixtures) {
    const within = relative(physicalRoot, realpathSync(target));
    if (!within || within.startsWith('..') || isAbsolute(within)) throw new Error('Refusing fixture cleanup outside owned output');
  }
  for (const target of createdFixtures) rmSync(target, { recursive: true, force: false });
  receipt.storageStatus = 'success-fixtures-retired';
  receipt.cleanupCompletedAt = new Date().toISOString();
  persistReceipt();
}
if (results.some(result => !result.passed)) process.exitCode = 1;

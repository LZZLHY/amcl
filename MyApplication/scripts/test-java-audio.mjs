/**
 * 使用真实 javac/java 运行标准音频接口与生产 provider；输出必须由调用方显式指定到仓库外。
 * 宿主驱动只位于 test 源集，生产服务发现仍检查缺 native 必须真实失败。
 */
import { execFileSync } from 'node:child_process';
import { readdirSync, mkdirSync, copyFileSync, writeFileSync, readFileSync } from 'node:fs';
import { resolve, join, dirname, isAbsolute, delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
function option(name, fallback) { const i = args.indexOf(name); return i < 0 ? fallback : args[i + 1]; }
const out = option('--output');
if (!out || !isAbsolute(out)) throw new Error('--output requires an explicit external absolute directory');
assertExternalOutputPath(out, { root });
const javac = option('--javac', 'javac');
const java = option('--java', 'java');
const launcherJar = option('--launcher-jar');
const classes = join(out, 'classes'); mkdirSync(classes, { recursive: true });
const sourceDir = join(root, 'JavaApp/src/com/amcl/audio');
const sources = launcherJar ? [] : readdirSync(sourceDir).filter(x => x.endsWith('.java')).map(x => join(sourceDir, x));
sources.push(join(root, 'JavaApp/test/com/amcl/audio/OhosAudioContractTest.java'));
execFileSync(javac, ['--release', '8', '-encoding', 'UTF-8', '-d', classes,
  ...(launcherJar ? ['-cp', launcherJar] : []), ...sources], { stdio: 'inherit' });
const service = 'META-INF/services/javax.sound.sampled.spi.MixerProvider';
if (!launcherJar) {
  mkdirSync(dirname(join(classes, service)), { recursive: true });
  copyFileSync(join(root, 'JavaApp/resources', service), join(classes, service));
}
const output = execFileSync(java, [...(args.includes('--system-loader') ? ['-Djava.system.class.loader=com.amcl.launcher.AmclClassLoader'] : []),
  '-cp', launcherJar ? [launcherJar, classes].join(delimiter) : classes,
  'com.amcl.audio.OhosAudioContractTest'], { encoding: 'utf8', timeout: 30000 });
process.stdout.write(output); writeFileSync(join(out, 'contract.log'), output);
if (!launcherJar) {
  const classBytes = readFileSync(join(classes, 'com/amcl/audio/OhosMixerProvider.class'));
  if (classBytes.readUInt16BE(6) !== 52) throw new Error('Provider must use Java 8 bytecode');
}
writeFileSync(join(out, 'result.json'), JSON.stringify({ java, javac, launcherJar, bytecodeMajor: 52, output, service }, null, 2));

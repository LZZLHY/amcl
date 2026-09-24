#!/usr/bin/env node
/**
 * 离线回归真实 VersionParser -> LaunchProfileBuilder 纯参数方法与来源策略。
 * fixture 保留官方 JVM 数组和来源摘要，覆盖未声明/旧默认/新子目录三个世代；
 * 不依赖网络、客户端 JAR、设备或 JVM，OS/文件接口一旦意外触发即失败。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const noIO = () => { throw new Error('参数回归不允许文件或设备调用'); };
class SilentLogger {
  info() {}
  warn() {}
  error() {}
}
const load = makePureEtsLoader({
  '@kit.CoreFileKit': { fileIo: { readTextSync: noIO, statSync: noIO, listFileSync: noIO } },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
  // 本测试的版本投影不含 libraries；若将来调用到 Maven 解析，需显式扩展真实依赖范围。
  '../modloader/MavenUtils': { mavenToRelativePath: noIO },
  commons: { ActivityLogger: SilentLogger, formatError: String },
  feature_core: {},
  account: {},
  mods: {},
  './LaunchNativeBridge': { launchNative: () => ({ getCommonJvmArgs: () => ['-XX:-UseCompressedOops'] }) },
  './GameCompatibility': {},
  './GraphicsProfileRegistry': { GraphicsGameApi: { UNKNOWN: 'unknown' } },
  './GraphicsBackendPlan': { VulkanPolicy: { ALLOW: 'allow' } },
  './GraphicsGameFacts': {},
  './LoaderGenerationResolver': {},
  './LaunchContractPreflight': {},
  './LaunchAgentProbe': {},
});
const { VersionParser } = load('feature_core/src/main/ets/version/VersionParser.ets');
const { LaunchProfileBuilder } = load('launch/src/main/ets/LaunchProfileBuilder.ets');
const { normalizeManifestJnaTmpdir, retainLastJvmArgumentValues, jvmArgumentOverrideKey } =
  load('launch/src/main/ets/RuntimeJvmArgumentPolicy.ets');
const fixture = JSON.parse(fs.readFileSync(new URL('./fixtures/runtime-jvm-manifests.json', import.meta.url), 'utf8'));
assert.deepEqual(fixture.fixtures.map(item => item.case),
  ['no-jna-declaration', 'legacy-default-template', 'jna-subdirectory-template']);

/** 创建实际 builder，只调用无 IO 的解析/过滤/合并方法，不替代其中算法。 */
function builderFor(gameDir, custom = '') {
  const builder = new LaunchProfileBuilder().setMcDir('/fixture/.minecraft').setVersion('fixture').setCustomJvmArgs(custom);
  builder.gameDir = gameDir;
  return builder;
}

let manifestCases = 0;
for (const gameDir of ['/fixture/.minecraft', '/fixture/.minecraft/versions/instance with space']) {
  for (const item of fixture.fixtures) {
    assert.match(item.source.url, /^https:\/\/piston-meta\.mojang\.com\//);
    assert.match(item.source.sha1, /^[0-9a-f]{40}$/);
    const parsed = VersionParser.parseData(structuredClone(item.versionJson));
    const builder = builderFor(gameDir);
    const actual = builder.filterJvmArgs(parsed.jvmArgs, '/fixture/client.jar');
    const jna = actual.filter(arg => arg.startsWith('-Djna.tmpdir'));
    assert.deepEqual(jna, item.case === 'no-jna-declaration' ? [] : ['-Djna.tmpdir=' + gameDir + '/natives/jna']);
    // JNA 适配必须是键级策略：Java 搜索路径、LWJGL 解包与 Netty 工作目录各保留官方后缀。
    for (const arg of parsed.jvmArgs) {
      if (arg.startsWith('-Dorg.lwjgl.system.SharedLibraryExtractPath=') || arg.startsWith('-Dio.netty.native.workdir=')) {
        assert.ok(actual.includes(arg.replaceAll('${natives_directory}', gameDir + '/natives')), arg);
      }
      if (arg.startsWith('-Djava.library.path=')) {
        assert.ok(actual.includes(arg.replace('-Djava.library.path=', '-Damcl.forge.native.path=')
          .replaceAll('${natives_directory}', gameDir + '/natives')), arg);
      }
    }
    manifestCases++;
  }
}

const gameDir = '/fixture/.minecraft/versions/instance';
const correct = '-Djna.tmpdir=' + gameDir + '/natives/jna';
const builder = builderFor(gameDir);
// 明确的加载器绝对目录、额外子目录与未知模板不能冒充官方默认而被静默改写。
for (const [raw, expected] of [
  ['-Djna.tmpdir=/loader/own-temp', '-Djna.tmpdir=/loader/own-temp'],
  ['-Djna.tmpdir=${natives_directory}/custom', '-Djna.tmpdir=' + gameDir + '/natives/custom'],
  ['-Djna.tmpdir=${loader_private_directory}', '-Djna.tmpdir=${loader_private_directory}'],
  ['-Djna.tmpdir', '-Djna.tmpdir'],
  ['-Dorg.lwjgl.opengl.libname=foreign-provider', '-Dorg.lwjgl.opengl.libname=foreign-provider'],
  ['-Damcl.graphics.profile=foreign-profile', '-Damcl.graphics.profile=foreign-profile'],
]) {
  assert.equal(normalizeManifestJnaTmpdir(raw, gameDir), raw, '只识别两个精确的 JNA 默认模板');
  assert.deepEqual(builder.filterJvmArgs([raw], '/fixture/client.jar'), [expected]);
}

// 用户输入在清单过滤后合入。即使长得像官方模板，也不越过来源边界自动展开。
assert.deepEqual(builderFor(gameDir, '-Djna.tmpdir=${natives_directory}/jna').mergeUserJvmArgs([correct]),
  ['-Djna.tmpdir=${natives_directory}/jna']);
assert.deepEqual(builderFor(gameDir, '-Djna.tmpdir=/global ' + correct).mergeUserJvmArgs([correct]), [correct]);
assert.deepEqual(builderFor(gameDir, correct + ' -Djna.tmpdir=/version').mergeUserJvmArgs([correct]), ['-Djna.tmpdir=/version']);
assert.deepEqual(builderFor(gameDir, '-Djna.tmpdir ' + correct).mergeUserJvmArgs([]), [correct]);
assert.deepEqual(builderFor(gameDir, correct + ' -Djna.tmpdir').mergeUserJvmArgs([]), ['-Djna.tmpdir']);
assert.deepEqual(builderFor(gameDir, correct + ' ' + correct).mergeUserJvmArgs([]), [correct]);
assert.deepEqual(builderFor(gameDir, '-Djna.tmpdir="/path with space"').mergeUserJvmArgs([]), ['-Djna.tmpdir=/path with space']);

// 被覆盖的旧保护值不再送往严格冻结，但真正生效的伪造 provider 值必须原样留下供拒绝。
const canonicalGl = '-Dorg.lwjgl.opengl.libname=libamcl_graphics_runtime.so';
assert.deepEqual(builderFor(gameDir, '-Dorg.lwjgl.opengl.libname=old ' + canonicalGl).mergeUserJvmArgs([]), [canonicalGl]);
assert.deepEqual(builderFor(gameDir, canonicalGl + ' -Dorg.lwjgl.opengl.libname=evil').mergeUserJvmArgs([]),
  ['-Dorg.lwjgl.opengl.libname=evil']);
assert.deepEqual(builderFor(gameDir, '-Damcl.graphics.profile=old -Damcl.graphics.profile=evil').mergeUserJvmArgs([]),
  ['-Damcl.graphics.profile=evil']);

const repeatable = ['--add-opens=java.base/java.lang=ALL-UNNAMED', '--add-opens=java.base/java.nio=ALL-UNNAMED',
  '--add-exports=java.base/sun.nio.ch=ALL-UNNAMED', '--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED',
  '-javaagent:/one.jar', '-javaagent:/two.jar'];
const userInput = ['-Xmx1G', '-Dmode=global', ...repeatable, '-Xmx2G', '-Dmode=version'];
const untouched = userInput.slice();
assert.deepEqual(retainLastJvmArgumentValues(userInput), [...repeatable, '-Xmx2G', '-Dmode=version']);
assert.deepEqual(userInput, untouched, '策略不得修改上游输入数组');
assert.deepEqual(builderFor(gameDir, userInput.join(' ')).mergeUserJvmArgs(['-Xmx512m', '-Dmode=manifest', '-Dother=yes']),
  ['-Dother=yes', ...repeatable, '-Xmx2G', '-Dmode=version']);
for (const arg of repeatable) assert.equal(jvmArgumentOverrideKey(arg), '', '可重复选项不按前缀丢弃');
assert.deepEqual(retainLastJvmArgumentValues(['--add-opens', 'java.base/java.lang=ALL-UNNAMED',
  '--add-opens', 'java.base/java.nio=ALL-UNNAMED']), ['--add-opens', 'java.base/java.lang=ALL-UNNAMED',
  '--add-opens', 'java.base/java.nio=ALL-UNNAMED']);
console.log(`PASS runtime JVM argument policy: ${manifestCases} official-manifest/path cases, custom provenance, last-value overrides, repeatable modules and provider negatives`);

/**
 * JDK 运行区间宿主回归：直接转译并执行生产 ArkTS，不复制路由或合并算法。
 * 文件系统只提供内存中的版本清单；安装状态作为外部事实注入，绝不读写用户实例。
 * 同时回放原有 LaunchJdkPolicy Hypium 用例，保护“推荐 17、只有 21 也能用”等合法替代。
 */
import assert from 'node:assert/strict';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const cases = [];
let legacySuite = 'JDK策略';
const versions = new Map();
const noop = () => {};
const dependencies = {
  '@kit.CoreFileKit': { fileIo: { readTextSync: name => {
    if (!versions.has(name)) throw new Error('测试未提供清单：' + name);
    return versions.get(name);
  } } },
  '@kit.PerformanceAnalysisKit': { hilog: { info: noop, warn: noop, error: noop, debug: noop } },
  '@kit.NetworkKit': {},
  '@kit.CryptoArchitectureKit': {},
  './JdkInstaller': {},
  './LaunchNativeBridge': {},
  './LaunchProfileBuilder': {},
  './LaunchContractPreflight': {},
  '../download/DownloadManager': {},
  './MavenSpecBuilder': {},
  'commons': {
    DiagnosticPolicy: { isDeveloperBuild: () => false },
    LogTags: {}, AppLogger: { info: noop, warn: noop, error: noop },
    SUPPORTED_JDK_VERSION: '17', SUPPORTED_JDK_VERSIONS: ['8', '17', '21', '25'],
    JDK_AUTO: 'auto', JDK21_MIN_MC_VERSION: '1.20.5', formatError: error => String(error),
  },
  'mods': {},
  'feature_core': {},
  'launch': {},
  '@ohos/hypium': {
    describe: (_name, fn) => fn(),
    it: (name, _flag, fn) => cases.push({ name: `既有${legacySuite}：` + name, fn, legacy: legacySuite }),
    expect: actual => ({
      assertEqual: expected => assert.equal(actual, expected),
      assertTrue: () => assert.equal(actual, true),
      assertFalse: () => assert.equal(actual, false),
    }),
  },
};
const load = makePureEtsLoader(dependencies);
Object.assign(dependencies.commons, load('commons/src/main/ets/utils/McVersionUtils.ets'));
Object.assign(dependencies.mods, load('mods/src/main/ets/VersionIdUtils.ets'));
// Maven 模块的网络/下载依赖不参与本测试；解析器与合并器仍使用生产 Maven 纯函数。
dependencies['../modloader/MavenUtils'] = load('feature_core/src/main/ets/modloader/MavenUtils.ets');
const parser = load('feature_core/src/main/ets/version/VersionParser.ets').VersionParser;
const merger = load('feature_core/src/main/ets/version/VersionJsonMerger.ets').VersionJsonMerger;
dependencies.feature_core.VersionParser = parser;
dependencies.feature_core.VersionJsonMerger = merger;
dependencies.feature_core.mavenToRelativePath = dependencies['../modloader/MavenUtils'].mavenToRelativePath;
const policy = load('launch/src/main/ets/LaunchJdkPolicy.ets');
const registry = load('launch/src/main/ets/LoaderGenerationRegistry.ets');
const asm = load('launch/src/main/ets/AsmJavaSupport.ets');
const validator = load('launch/src/main/ets/PreLaunchValidator.ets').PreLaunchValidator;
Object.assign(dependencies.launch, policy, registry, asm, { PreLaunchValidator: validator });
const Manager = load('launch/src/main/ets/JdkManager.ets').JdkManager;
load('entry/src/test/LaunchJdkPolicy.test.ets').default();
legacySuite = '版本解析';
load('entry/src/test/VersionParser.test.ets').default();
legacySuite = '版本合并';
load('entry/src/test/VersionJsonMerger.test.ets').default();

const vanilla = 'net.minecraft.client.main.Main';
const bsl = 'cpw.mods.bootstraplauncher.BootstrapLauncher';
const legacyModlauncher = 'cpw.mods.modlauncher.Launcher';
const test = (name, fn) => cases.push({ name, fn, legacy: false });
const manifest = (id, major) => ({
  id, type: 'release', mainClass: vanilla, libraries: [],
  ...(major === undefined ? {} : { javaVersion: { majorVersion: major, component: 'java-runtime-test' } }),
});
const range = (mainClass, major, minimum = 17, era = '17', asmVersion = '9.7.1', availableMajors) => policy.resolveJdkRange({
  mainClass, manifestJavaMajor: major, minRuntimeMajor: minimum, eraIdealJdk: era,
  availableMajors,
  libraryPaths: asmVersion ? [`org/ow2/asm/asm/${asmVersion}/asm-${asmVersion}.jar`] : [],
});
const choose = (r, installed) => policy.resolveJdkPolicy({ range: r, installedMajors: installed, userPreferred: '' });
const managerFor = (json, installed) => {
  versions.clear();
  versions.set('/test/versions/自定义实例/自定义实例.json', JSON.stringify(json));
  const manager = new Manager({ filesDir: '/test-files' });
  // 安装完整性不是本组测试目标；只替换该外部事实查询，不改路由/区间/解析方法。
  manager.isInstalled = version => installed.includes(version);
  return manager;
};

test('解析器保留有效 javaVersion.majorVersion，而非丢弃周快照下限', () => {
  assert.equal(parser.parseData(manifest('24w14a', 21)).javaVersionMajor, 21);
});
test('解析器不把非法、分数、字符串或空 major 变成硬约束', () => {
  for (const value of [undefined, null, '21', 0, -1, 21.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.equal(parser.parseData(manifest('自定义', value)).javaVersionMajor, 0, String(value));
  }
});
test('解析器容忍 javaVersion 整体缺失、null 或非对象', () => {
  for (const value of [undefined, null, 21, '21', [], true]) {
    const json = manifest('自定义');
    json.javaVersion = value;
    assert.equal(parser.parseData(json).javaVersionMajor, 0, String(value));
  }
});
test('24w14a 清单→解析→Manager→策略：只装 8 不得自动选择或声称可用', () => {
  const manager = managerFor(manifest('24w14a', 21), ['8']);
  const decision = manager.jdkPolicyFor('自定义实例', 'auto', '/test');
  assert.equal(decision.range.minMajor, 21);
  assert.equal(decision.range.minimumSource, 'manifest-java-version');
  assert.equal(decision.installed, false);
  assert.notEqual(decision.jdk, '8');
  assert.ok(policy.usable(Number(decision.jdk), decision.range));
});
test('周快照有 21 可用：不能把纪元兜底 25 误变成唯一可用值', () => {
  const manager = managerFor(manifest('24w14a', 21), ['8', '21']);
  assert.equal(manager.jdkPolicyFor('自定义实例', 'auto', '/test').jdk, '21');
});
test('清单有效 major 是事实下限，非目录名/纪元推测的唯一版本', () => {
  const r = range(vanilla, 21, 25, '25', '');
  assert.equal(r.minMajor, 21);
  assert.equal(choose(r, ['21']).jdk, '21');
  assert.equal(policy.classifyJdkChoice(21, r), 'ok-not-preferred');
});
test('缺失或畸形清单保留旧纪元回退，不把未知自定义实例封死', () => {
  for (const value of [undefined, null, '21', -1, 1.5]) {
    assert.equal(range(vanilla, value, 17).minMajor, 17);
  }
  const manager = managerFor(manifest('纯中文实例'), ['8']);
  const decision = manager.jdkPolicyFor('自定义实例', 'auto', '/test');
  assert.equal(decision.range.minMajor, 0);
  assert.equal(decision.installed, true);
  assert.equal(decision.jdk, '8');
});
test('已知 1.19.4 无 manifest major 继续允许只装 JDK 21', () => {
  const json = manifest('1.19.4');
  json.mainClass = bsl;
  json.libraries = [{ name: 'org.ow2.asm:asm:9.7.1' }];
  const decision = managerFor(json, ['21']).jdkPolicyFor('自定义实例', 'auto', '/test');
  assert.equal(decision.jdk, '21');
  assert.equal(decision.installed, true);
  assert.equal(decision.range.maxMajor, 24);
});
test('无 ASM 时较高的清单下限不能被较旧纪元推荐伪造为空区间', () => {
  const r = range(bsl, 21, 17, '17', '');
  assert.equal(r.minMajor, 21);
  assert.equal(r.maxMajor, 21);
  assert.equal(r.ceilingSource, 'generation-fallback');
  assert.equal(r.preferredJdk, '21');
  assert.equal(choose(r, ['21']).jdk, '21');
  assert.equal(choose(r, ['21']).installed, true);
});
test('合并取 loader 更高 Java 下限并保留原版 javaVersion 的其他字段', () => {
  const original = manifest('1.20.1', 17);
  original.javaVersion.vendorHint = 'keep-original';
  const originalMetadata = original.javaVersion;
  const loader = manifest('loader', 21);
  loader.javaVersion.component = 'must-not-replace-original-component';
  const merged = merger.mergeJsonObjects(original, loader, '整合包');
  assert.equal(merged.javaVersion.majorVersion, 21);
  assert.equal(merged.javaVersion.component, 'java-runtime-test');
  assert.equal(merged.javaVersion.vendorHint, 'keep-original');
  assert.equal(merged.clientVersion, '1.20.1');
  assert.equal(parser.parseData(merged).javaVersionMajor, 21);
  assert.equal(originalMetadata.majorVersion, 17, '不得就地改写调用方持有的原始元数据对象');
});
test('较低或非法 loader major 不得降低原版要求', () => {
  for (const lower of [8, undefined, null, -1, '25', 25.5]) {
    const merged = merger.mergeJsonObjects(manifest('26.3', 25), manifest('loader', lower), '整合包');
    assert.equal(merged.javaVersion.majorVersion, 25, String(lower));
  }
});
test('原版无 javaVersion 时可继承 loader 有效下限；双方未知仍未知', () => {
  const merged = merger.mergeJsonObjects(manifest('旧版'), manifest('loader', 17), '整合包');
  assert.equal(parser.parseData(merged).javaVersionMajor, 17);
  const absent = merger.mergeJsonObjects(manifest('自定义'), manifest('loader'), '整合包');
  assert.equal(parser.parseData(absent).javaVersionMajor, 0);
});
test('合并面对畸形原版元数据仍只继承 loader 的有效要求', () => {
  for (const invalid of [null, '17', 17, [], true]) {
    const original = manifest('自定义');
    original.javaVersion = invalid;
    const merged = merger.mergeJsonObjects(original, manifest('loader', 21), '整合包');
    assert.equal(parser.parseData(merged).javaVersionMajor, 21);
  }
});
test('空区间 [25,21] 必须显式拒绝，不能推荐矛盾 JDK 21', () => {
  const r = range(bsl, 25, 25, '25', '9.5');
  const decision = choose(r, ['8', '21', '25']);
  assert.equal(r.minMajor, 25);
  assert.equal(r.maxMajor, 21);
  assert.equal(r.preferredJdk, '');
  assert.equal(policy.isJdkRangeEmpty(r), true);
  assert.equal(decision.jdk, '');
  assert.equal(decision.installed, false);
  assert.equal(decision.reason, 'empty-range');
  assert.equal(policy.classifyJdkChoice(25, r), 'empty-range');
  assert.match(policy.describeEmptyJdkRange(r), /25/);
  assert.match(policy.describeEmptyJdkRange(r), /21/);
  assert.doesNotMatch(policy.describeEmptyJdkRange(r), /请改用 JDK 21/);
});
test('pinned 8 与已声明下限 17 冲突时不能抹掉下限再声称 8 已安装可用', () => {
  const r = range(legacyModlauncher, 17, 8, '8', '7.2');
  assert.equal(r.minMajor, 17);
  assert.equal(r.maxMajor, 8);
  assert.equal(choose(r, ['8', '17']).reason, 'empty-range');
  assert.equal(choose(r, ['8', '17']).jdk, '');
});
test('空区间的所有解释入口都不能再生成换一个矛盾 JDK 的建议', () => {
  const r = range(bsl, 25, 25, '25', '9.5');
  assert.equal(policy.describeAboveMax(r, 25), policy.describeEmptyJdkRange(r));
  assert.equal(policy.describeNotPreferred(r, 21), policy.describeEmptyJdkRange(r));
});
test('真实 runJdk：空区间对空选择、硬覆盖及 accepted 均失败，且不提供伪修复动作', () => {
  const conflicts = [range(bsl, 25, 25, '25', '9.5'), range(legacyModlauncher, 17, 8, '8', '7.2')];
  for (const conflict of conflicts) {
    for (const version of ['', '8', '21', '25']) {
      for (const accepted of [false, true]) {
        const result = validator.runJdk(version, conflict, accepted);
        assert.equal(result.status, 'fail', `区间=${conflict.minMajor}/${conflict.maxMajor} JDK=${version} accepted=${accepted}`);
        assert.equal(result.fixActionKey, '');
        assert.equal(result.detail, policy.describeEmptyJdkRange(conflict));
      }
    }
  }
});
test('区间 [21,24] 只能从可提供集合推荐21，不能推荐没有发布槽的24', () => {
  const r = range(bsl, 21, 21, '25', '9.7.1', ['8', '17', '21', '25']);
  assert.equal(r.preferredJdk, '21');
  assert.equal(choose(r, []).jdk, '21');
  assert.equal(choose(r, []).reason, 'none-installed');
  assert.equal(policy.hasJdkDownloadCandidate(r), true);
});
test('Manager 从真实发布配置提供候选：最低26无已装合法JDK时不得假推荐下载26', () => {
  const manager = managerFor(manifest('未来自定义', 26), ['25']);
  const decision = manager.jdkPolicyFor('自定义实例', 'auto', '/test');
  assert.equal(decision.jdk, '');
  assert.equal(decision.installed, false);
  assert.equal(decision.reason, 'runtime-unavailable');
  assert.equal(decision.range.preferredJdk, '');
  assert.equal(policy.isJdkRangeEmpty(decision.range), false, '不是上下限冲突，而是本产品尚未提供满足要求的JDK');
  assert.equal(policy.hasJdkDownloadCandidate(decision.range), false);
  assert.match(policy.describeUnavailableJdkRuntime(decision.range), /26/);
  assert.doesNotMatch(policy.describeUnavailableJdkRuntime(decision.range), /一同下载|请安装 JDK 26/);
});
test('已有合法自编23即使不在发布集合内仍允许运行，不因停发误拒绝', () => {
  const r = range(bsl, 21, 21, '25', '9.7.1', []);
  const decision = choose(r, ['23']);
  assert.equal(decision.jdk, '23');
  assert.equal(decision.installed, true);
  assert.equal(decision.reason, 'in-range');
  assert.equal(policy.hasJdkDownloadCandidate(r), false);
  assert.equal(policy.classifyJdkChoice(23, r), 'ok-not-preferred');
  assert.doesNotMatch(policy.describeNotPreferred(r, 23), /更贴合的是 JDK/);
});
test('pinned8停止提供但已装完整8仍可用；未装时不伪造下载候选', () => {
  const r = range(legacyModlauncher, 8, 8, '8', '7.2', ['17', '21', '25']);
  assert.equal(choose(r, ['8']).jdk, '8');
  assert.equal(choose(r, ['8']).installed, true);
  assert.equal(choose(r, ['8']).reason, 'pinned');
  assert.equal(choose(r, []).jdk, '');
  assert.equal(choose(r, []).reason, 'runtime-unavailable');
});
test('合法已装候选仍优先于尚未安装的发布推荐', () => {
  const r = range(bsl, 17, 17, '17', '9.7.1', ['21']);
  assert.equal(r.preferredJdk, '21');
  assert.equal(choose(r, ['17']).jdk, '17');
  assert.equal(choose(r, ['17']).installed, true);
  assert.equal(choose(r, []).jdk, '21');
});
test('真实自检区分没有发布候选与合法已装：无选择拒绝、已选择23不误拒绝', () => {
  const unavailable = range(vanilla, 26, 26, '25', '', ['8', '17', '21', '25']);
  for (const accepted of [false, true]) {
    const result = validator.runJdk('', unavailable, accepted);
    assert.equal(result.status, 'fail');
    assert.equal(result.fixActionKey, '');
    assert.equal(result.detail, policy.describeUnavailableJdkRuntime(unavailable));
  }
  const installedOnly = range(bsl, 21, 21, '25', '9.7.1', []);
  assert.equal(validator.runJdk('23', installedOnly, false).status, 'pass');
});

let failed = 0;
for (const item of cases) {
  try { await item.fn(); console.log('PASS ' + item.name); }
  catch (error) { failed++; console.error('FAIL ' + item.name + '\n' + error.stack); }
}
const oldCount = cases.filter(item => item.legacy).length;
const policyCount = cases.filter(item => item.legacy === 'JDK策略').length;
console.log(`JDK 运行契约：${cases.length - failed}/${cases.length} 通过；既有策略 ${policyCount} 例，`
  + `既有解析/合并 ${oldCount - policyCount} 例，新回归 ${cases.length - oldCount} 例。`);
if (failed > 0) process.exitCode = 1;

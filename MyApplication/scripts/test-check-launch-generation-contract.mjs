#!/usr/bin/env node
// scripts/test-check-launch-generation-contract.mjs
//
// `check-launch-generation-contract.mjs` 的自测。
//
// ⭐ **它存在的理由不是"给门禁配个测试"，而是负向验证。**
// 一道全绿的门禁与一道**恒真**的门禁在输出里长得一模一样，而本仓已经因此吃过亏
// （CHANGELOG 1000513：产物那半判据在 CI 上恒真，于是"从不执行"与"全部通过"不可区分）。
// ⇒ 下面每个用例都把真实源码在**内存里**改坏一处，然后断言门禁确实报出对应的错。
// 不落盘、不动工作树。
//
// 其中 `forge-bootstrap-delivery-narrowed` 那一条就是 **2026-09-04 那次故障的最小复现**：
// 它把 Forge 新 bootstrap 的 delivery 改回收窄，门禁必须红。
// 那条用例红得起来，才等于"以后有人再做一次 642edf87，提交前会被挡住"。
//
// 用法：node scripts/test-check-launch-generation-contract.mjs

import url from 'node:url';

import {
  analyze, readAll, PINNED_DELIVERY, DELIVERY_ARG_KEY, PINNED_LEGACY_CLASSPATH,
  PINNED_JDK_CEILING, PINNED_ASM_MAX_JAVA,
} from './check-launch-generation-contract.mjs';

let passed = 0;
let failed = 0;

function check(name, cond, detail = '') {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    console.error(`  ✗ ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

/** 断言改坏之后至少有一条错误命中给定子串。 */
function expectFail(name, mutate, needle) {
  const files = readAll();
  const mutated = mutate(files);
  const r = analyze(mutated);
  const hit = !r.ok && r.errors.some((e) => e.includes(needle));
  check(name, hit,
    r.ok ? '门禁竟然通过了（判据在这条形态上恒真）'
         : `错误里没有 '${needle}'；实际：${JSON.stringify(r.errors)}`);
}

console.log('test-check-launch-generation-contract:');

// ── 0. 基线：未改动的真实源码必须通过 ────────────────────────────────
{
  const r = analyze(readAll());
  check('pristine-sources-pass', r.ok,
    `基线就红了，说明门禁与源码不同步：${JSON.stringify(r.errors)}`);
}

// ── 1. G2 —— 本次故障的最小复现 ──────────────────────────────────────
// 把 forge-bootstrap 那一行的 delivery 从 JvmClasspathFull 改成 AmclLoaderOnly。
// 只替换紧跟在 ForgeBootstrap 之后的那一处，避免误伤别的行。
expectFail('forge-bootstrap-delivery-narrowed（= 642edf87 的最小复现）', (f) => {
  const idx = f.registry.indexOf('LoaderGeneration.ForgeBootstrap,');
  const head = f.registry.slice(0, idx);
  const tail = f.registry.slice(idx).replace(
    'ClasspathDelivery.JvmClasspathFull', 'ClasspathDelivery.AmclLoaderOnly');
  return { ...f, registry: head + tail };
}, "[G2] 世代 'forge-bootstrap'");

// ── 2. G2 —— Fabric 那次（1000576）的同型复现 ────────────────────────
expectFail('fabric-knot-delivery-narrowed（= 1000576 的最小复现）', (f) => {
  const idx = f.registry.indexOf('LoaderGeneration.FabricKnot,');
  const head = f.registry.slice(0, idx);
  const tail = f.registry.slice(idx).replace(
    'ClasspathDelivery.JvmClasspathFull', 'ClasspathDelivery.AmclLoaderOnly');
  return { ...f, registry: head + tail };
}, "[G2] 世代 'fabric-knot'");

// ── 3. G2 —— 反方向：原版被改成完整 classpath ─────────────────────────
// 它的后果是字节码变换静默失效（掉帧而非崩溃），恰恰因为"不崩"才更需要门禁。
expectFail('vanilla-delivery-widened', (f) => {
  const idx = f.registry.indexOf('LoaderGeneration.Vanilla,');
  const head = f.registry.slice(0, idx);
  const tail = f.registry.slice(idx).replace(
    'ClasspathDelivery.AmclLoaderOnly', 'ClasspathDelivery.JvmClasspathFull');
  return { ...f, registry: head + tail };
}, "[G2] 世代 'vanilla'");

// ── 4. G3 —— 新增世代却忘了填契约表 ──────────────────────────────────
// 这是"以后不再重演"的核心不变量：枚举里多一个成员、表里没有对应行 ⇒ 必须红。
expectFail('enum-member-without-contract-row（= G3）', (f) => ({
  ...f,
  registry: f.registry.replace(
    "  Unknown = 'unknown',",
    "  Unknown = 'unknown',\n  QuiltLoader = 'quilt-loader',"),
}), '[G3] 世代 LoaderGeneration.QuiltLoader');

// ── 5. B 组 —— isolationAsserts 与 delivery 不同真 ───────────────────
expectFail('isolation-asserts-inconsistent', (f) => {
  const idx = f.registry.indexOf('LoaderGeneration.Vanilla,');
  const head = f.registry.slice(0, idx);
  const tail = f.registry.slice(idx).replace('isolationAsserts: true', 'isolationAsserts: false');
  return { ...f, registry: head + tail };
}, 'isolationAsserts=false');

// ── 6. C 组 —— mainClass 主键跨行重复 ────────────────────────────────
expectFail('duplicate-main-class-key', (f) => ({
  ...f,
  registry: f.registry.replace(
    "mainClasses: ['net.neoforged.fml.startup.Client'],",
    "mainClasses: ['net.minecraftforge.bootstrap.ForgeBootstrap'],"),
}), '主键必须唯一');

// ── 7. E 组 —— C++ 不再消费 marker（决策没接上执行者）──────────────────
expectFail('native-stops-consuming-marker', (f) => ({
  ...f,
  nativeLauncher: f.nativeLauncher.split(DELIVERY_ARG_KEY).join('-Damcl.somethingElse='),
}), 'delivery 决策没有接上执行者');

// ── 8. E 组 —— C++ 侧丢掉 delivery 字面量 ────────────────────────────
expectFail('native-loses-delivery-literal', (f) => ({
  ...f,
  nativeLauncher: f.nativeLauncher.split('amcl-loader-only').join('amcl-loader-onlyX'),
}), 'C 层判不出该走收窄还是完整 classpath');

// ── 9. E 组 —— Java 侧丢掉 delivery 字面量 ───────────────────────────
expectFail('java-loses-delivery-literal', (f) => ({
  ...f,
  javaLauncher: f.javaLauncher.split('amcl-loader-only').join('amcl-loader-onlyX'),
}), '隔离断言的作用域判据');

// ── 10. 源文件缺失必须 fatal，不得静默当空表 ──────────────────────────
expectFail('missing-registry-is-fatal', (f) => ({ ...f, registry: null }), '源文件缺失');

// ── 11. 门禁必须剥注释：注释里的示例不得被当成枚举成员 ─────────────────
// 规范与注册表的注释里有整张世代表；不剥注释的话下面这段会被解析成一个没有契约行的世代。
{
  const files = readAll();
  files.registry += `\n// export enum LoaderGeneration { Bogus = 'bogus' }\n`
    + `/* generation: LoaderGeneration.Bogus, classpathDelivery: ClasspathDelivery.AmclLoaderOnly */\n`;
  const r = analyze(files);
  check('comments-are-stripped', r.ok,
    `注释里的示例被当成了真条目：${JSON.stringify(r.errors)}`);
}

// ── 12. 钉住表引用的世代被删除也要红 ────────────────────────────────
expectFail('pinned-generation-removed', (f) => ({
  ...f,
  // 把 forge-bootstrap 的枚举值改名 ⇒ 钉住表找不到它。
  registry: f.registry.replace("ForgeBootstrap = 'forge-bootstrap',",
    "ForgeBootstrap = 'forge-bootstrap-renamed',"),
}), '钉住表引用的世代');

// ── 13. 钉住表本身的完整性（它是 G2 的载体，不能空着）─────────────────
check('pinned-table-covers-the-three-measured-generations',
  Object.keys(PINNED_DELIVERY).length >= 3
  && PINNED_DELIVERY['vanilla'] === 'amcl-loader-only'
  && PINNED_DELIVERY['forge-bootstrap'] === 'jvm-classpath-full'
  && PINNED_DELIVERY['fabric-knot'] === 'jvm-classpath-full',
  `实际：${JSON.stringify(PINNED_DELIVERY)}`);

// ── 14. D2 组 —— 把 BSL 的 legacyClassPath 要求改回 true 必须红 ────────
// ⭐ 这条是 **2026-09-04 那次"整代 Forge 1.17–1.20.1 被自己的契约拒绝"的最小复现**：
// 真机上 1.19.4-forge-45.4.5 连试两次都是 fails=1 codes=legacy-classpath-missing，
// 而那份官方 JSON 里该属性 0 次出现、AMCL 也从未注入它。
expectFail('forge-bsl-requires-legacy-classpath-again', (f) => {
  const idx = f.registry.indexOf('LoaderGeneration.ForgeBsl,');
  const head = f.registry.slice(0, idx);
  const tail = f.registry.slice(idx).replace(
    'requiresLegacyClassPathProperty: false', 'requiresLegacyClassPathProperty: true');
  return { ...f, registry: head + tail };
}, "世代 'forge-bsl' 的 requiresLegacyClassPathProperty");

check('legacy-classpath-pin-is-off-for-bsl',
  PINNED_LEGACY_CLASSPATH['forge-bsl'] === false,
  `实际：${JSON.stringify(PINNED_LEGACY_CLASSPATH)}`);

// ── 15. D3 组 —— 把 forge-bsl 的 JDK 上限拆掉必须红 ───────────────────
// ⭐ 这条是 **2026-09-04 "自检全绿然后闪退" 的最小复现**：把上限改成 None，
// 路由就会重新允许向上替换到 JDK 25，而 Forge 自带的 ASM 9.7.1 读不了 v69。
expectFail('forge-bsl-jdk-ceiling-removed', (f) => {
  const idx = f.registry.indexOf('LoaderGeneration.ForgeBsl,');
  const head = f.registry.slice(0, idx);
  const tail = f.registry.slice(idx).replace(
    'jdkCeiling: JdkCeiling.GameEra', 'jdkCeiling: JdkCeiling.None');
  return { ...f, registry: head + tail };
}, "世代 'forge-bsl' 的 jdkCeiling");

// 反方向：原版被加上上限也要红（它会让 26.3 原版在只装了 25 的设备上被判"要装 21"）。
expectFail('vanilla-jdk-ceiling-added', (f) => {
  const idx = f.registry.indexOf('LoaderGeneration.Vanilla,');
  const head = f.registry.slice(0, idx);
  const tail = f.registry.slice(idx).replace(
    'jdkCeiling: JdkCeiling.None', 'jdkCeiling: JdkCeiling.GameEra');
  return { ...f, registry: head + tail };
}, "世代 'vanilla' 的 jdkCeiling");

// 新增世代忘了填 jdkCeiling ⇒ 红（G3 的同形不变量，换一个字段）。
expectFail('new-generation-without-jdk-ceiling', (f) => ({
  ...f,
  registry: f.registry
    .replace("  Unknown = 'unknown',", "  Unknown = 'unknown',\n  QuiltLoader = 'quilt-loader',")
    // 补一行契约但**故意漏掉 jdkCeiling**，其余字段齐全 ⇒ 只应报缺字段那一条。
    .replace('export const LOADER_GENERATION_CONTRACTS: LoaderGenerationContract[] = [',
      'export const LOADER_GENERATION_CONTRACTS: LoaderGenerationContract[] = [\n'
      + '  {\n'
      + '    generation: LoaderGeneration.QuiltLoader,\n'
      + "    mainClasses: ['org.quiltmc.loader.impl.launch.knot.KnotClient'],\n"
      + "    displayName: 'Quilt',\n"
      + '    classpathDelivery: ClasspathDelivery.JvmClasspathFull,\n'
      + '    isolationAsserts: false,\n'
      + '    requiresLegacyClassPathProperty: false,\n'
      + '    requiresUrlClassLoaderSystemLoader: false,\n'
      + "    pinnedJdkMajor: '',\n"
      + "    rationale: 'synthetic row for the gate self-test',\n"
      + '  },'),
}), '缺 jdkCeiling 字段');

// ── 16. D3 组 —— 消费者与第二判定者 ──────────────────────────────────
// 字段有声明但没人读 = 假保护。这条挡的正是 requiresUrlClassLoaderSystemLoader 今天的状态。
expectFail('jdk-ceiling-loses-its-consumer', (f) => ({
  ...f, jdkPolicy: f.jdkPolicy.split('JdkCeiling.GameEra').join('JdkCeiling.GameEraX'),
}), '没有消费 jdkCeiling');

expectFail('jdk-policy-stops-consuming-pin', (f) => ({
  ...f, jdkPolicy: f.jdkPolicy.split('pinnedJdkMajor').join('pinnedJdkMajorX'),
}), '没有消费 pinnedJdkMajor');

// ⭐ 第二判定者复活：JdkManager 又开始用版本名子串判世代（那是本仓第五份 isForge，
// 而它正好决定 JDK 路由）。
expectFail('second-generation-judge-returns', (f) => ({
  ...f,
  jdkManager: f.jdkManager.replace('resolveLaunchJdk(mcVersion: string',
    "isLegacyForge_(v: string): boolean { return v.indexOf('forge') >= 0 }\n"
    + '  resolveLaunchJdk(mcVersion: string'),
}), '世代判定只有一处');

expectFail('router-stops-consuming-policy', (f) => ({
  ...f, jdkManager: f.jdkManager.split('resolveJdkPolicy(').join('resolveJdkPolicyDisabled_('),
}), '路由没接上契约表');

check('jdk-ceiling-pin-covers-the-measured-generations',
  PINNED_JDK_CEILING['vanilla'] === 'None'
  && PINNED_JDK_CEILING['forge-bsl'] === 'GameEra'
  && PINNED_JDK_CEILING['modlauncher-legacy'] === 'GameEra',
  `实际：${JSON.stringify(PINNED_JDK_CEILING)}`);

// ── 17. D3/D4 组 —— 上限的主来源与数据表 ─────────────────────────────
// ⭐ 丢掉 ASM 实读 = 退回"按纪元收紧"，那一版把 JDK 21 这种**合法组合**也拦掉了
// （用户实测被拒启）。这条与 forge-bsl-jdk-ceiling-removed 是**两个方向**的最小复现。
expectFail('asm-derivation-dropped', (f) => ({
  ...f, jdkPolicy: f.jdkPolicy.split('findAsmSupport(').join('findAsmSupportDisabled_('),
}), '没有调用 findAsmSupport');

// 把 9.7.1 的上限改小 ⇒ JDK 21 会重新被拦掉（= 病二复发）。
expectFail('asm-971-ceiling-lowered', (f) => ({
  ...f,
  asmTable: f.asmTable.replace("{ asm: '9.7.1', maxJavaMajor: 24",
    "{ asm: '9.7.1', maxJavaMajor: 17"),
}), 'ASM 9.7.1 的上限是 Java 17');

// 改大 ⇒ JDK 25 会重新被放过（= 病一复发，那是必崩的组合）。
expectFail('asm-971-ceiling-raised', (f) => ({
  ...f,
  asmTable: f.asmTable.replace("{ asm: '9.7.1', maxJavaMajor: 24",
    "{ asm: '9.7.1', maxJavaMajor: 25"),
}), 'ASM 9.7.1 的上限是 Java 25');

// 整条断点被删掉也要红（不是只在数字变了时红）。
expectFail('asm-breakpoint-removed', (f) => ({
  ...f, asmTable: f.asmTable.replace("asm: '9.10'", "asm: '9.10-removed'"),
}), '缺 ASM 9.10 这条断点');

check('asm-pin-covers-the-two-device-correlated-entries',
  PINNED_ASM_MAX_JAVA['9.7.1'] === 24 && PINNED_ASM_MAX_JAVA['9.10'] === 27,
  `实际：${JSON.stringify(PINNED_ASM_MAX_JAVA)}`);

console.log(`\n  ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

#!/usr/bin/env node
// scripts/test-check-launch-agent-probe.mjs
//
// `check-launch-agent-probe.mjs` 的自测（负向验证）。
//
// ⭐ **理由与 test-check-launch-generation-contract.mjs 同源，而且这一轮更硬：**
// 那道门禁的自测第一次运行时就抓出两条**恒真**判据（施工记录 §S02.4），
// 而本门禁的判据全部是"某段源码里有没有某个形状"——正是最容易写成恒真的那一类。
// 下面每条用例把真实源码在**内存里**改坏一处，断言门禁确实报出对应组的错。
// 不落盘、不动工作树。
//
// 用法：node scripts/test-check-launch-agent-probe.mjs

import url from 'node:url';

import {
  analyze, readAll, PROBE_ARG_KEY, PROBE_PROP, PROBE_LOG_ARG_KEY, PROBE_LOG_PROP,
} from './check-launch-agent-probe.mjs';

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

function expectFail(name, mutate, needle) {
  const mutated = mutate(readAll());
  const r = analyze(mutated);
  const hit = !r.ok && r.errors.some((e) => e.includes(needle));
  check(name, hit,
    r.ok ? '门禁竟然通过了（判据在这条形态上恒真）'
         : `错误里没有 '${needle}'；实际：${JSON.stringify(r.errors)}`);
}

console.log('test-check-launch-agent-probe:');

// ── 0. 基线 ──────────────────────────────────────────────────────────
{
  const r = analyze(readAll());
  check('pristine-sources-pass', r.ok,
    `基线就红了，说明门禁与源码不同步：${JSON.stringify(r.errors)}`);
}

// ── A 组：marker 两侧漂移 ────────────────────────────────────────────
expectFail('arkts-marker-renamed', (f) => ({
  ...f, arkts: f.arkts.replace(`'${PROBE_ARG_KEY}'`, `'-Damcl.agentProbeX='`),
}), `[A] launch/src/main/ets/LaunchAgentProbe.ets 里没有 '${PROBE_ARG_KEY}'`);

expectFail('java-marker-renamed', (f) => ({
  ...f, probe: f.probe.replace(`"${PROBE_PROP}"`, '"amcl.agentProbeX"'),
}), `[A] JavaApp/src/com/amcl/launcher/AmclAgentProbe.java 里没有 "${PROBE_PROP}"`);

// 跨局结论文件的两侧对齐（丢了它 = 一次性结论只写进每局被覆盖的 mc_output.log）
expectFail('probe-log-key-renamed-arkts', (f) => ({
  ...f, arkts: f.arkts.replace(`'${PROBE_LOG_ARG_KEY}'`, "'-Damcl.agentProbe.logX='"),
}), `[A] launch/src/main/ets/LaunchAgentProbe.ets 里没有 '${PROBE_LOG_ARG_KEY}'`);

expectFail('probe-log-key-renamed-java', (f) => ({
  ...f, probe: f.probe.replace(`"${PROBE_LOG_PROP}"`, '"amcl.agentProbe.logX"'),
}), '探针结论就只会写进每局被覆盖的 mc_output.log');

// ── B 组：默认开 / 无条件注入 / 第二道门丢失 ─────────────────────────
expectFail('default-flipped-on', (f) => ({
  ...f,
  arkts: f.arkts.replace('AGENT_PROBE_DEFAULT_ON: boolean = false',
    'AGENT_PROBE_DEFAULT_ON: boolean = true'),
}), '[B] ArkTS 侧的 AGENT_PROBE_DEFAULT_ON 不是 false');

expectFail('unconditional-javaagent', (f) => ({
  ...f,
  arkts: f.arkts.replace(/injected \? \['-javaagent:' \+ launcherJarPath\] : \[\]/,
    "['-javaagent:' + launcherJarPath]"),
}), '[B] ArkTS 侧没有"仅在 injected 为真时才产出 -javaagent"这个形状');

expectFail('wiring-dropped', (f) => ({
  ...f, wiring: f.wiring.replace(/resolveAgentProbe\s*\(/g, 'resolveAgentProbeDisabled_('),
}), '没有调用 resolveAgentProbe');

expectFail('premain-guard-after-install', (f) => ({
  ...f,
  // 把 marker 判断整段挪到 addTransformer 之后：Java 侧的第二道门形同虚设。
  probe: f.probe.replace('if (!PROBE_ON.equals(requested)) {', 'if (false) {')
    .replace('instrumentation.addTransformer(new AmclAgentProbe());',
      'instrumentation.addTransformer(new AmclAgentProbe());\n'
      + '            if (!PROBE_ON.equals(requested)) { return; }'),
}), '[B] premain 先 addTransformer 再判 marker');

// ── C 组：C0 开始变换 ────────────────────────────────────────────────
expectFail('transform-returns-bytes', (f) => ({
  ...f,
  probe: f.probe.replace('        if (!isProbeTarget(className)) return null;',
    '        if (!isProbeTarget(className)) return classfileBuffer;'),
}), '[C] transform 有一条非 null 的 return');

expectFail('transform-calls-patcher', (f) => ({
  ...f,
  probe: f.probe.replace('            probeTarget(loader, className, classfileBuffer);',
    '            TerrainCompatibilityPatcher.patchKnownClass(className, classfileBuffer,'
    + ' false, false);\n            probeTarget(loader, className, classfileBuffer);'),
}), '[C] transform 调用了变换入口 patchKnownClass');

// ── D 组：异常被静默 ─────────────────────────────────────────────────
expectFail('no-explicit-catch', (f) => ({
  ...f, probe: f.probe.replace('catch (Throwable failure) {\n            FAILED.incrementAndGet();',
    'catch (RuntimeException failure) {\n            FAILED.incrementAndGet();'),
}), '[D] transform 没有显式 catch (Throwable)');

expectFail('no-failure-counter', (f) => ({
  ...f, probe: f.probe.replace('            FAILED.incrementAndGet();\n', ''),
}), '[D] transform 的失败路径没有单调计数');

// ── E 组：快路径丢了 ─────────────────────────────────────────────────
expectFail('fast-path-removed', (f) => ({
  ...f,
  probe: f.probe.replace('        if (!isProbeTarget(className)) return null;', ''),
}), '[E] transform 里没有快路径过滤');

// ── F 组：方案 §7 的两条"明确不做"────────────────────────────────────
expectFail('asm-introduced', (f) => ({
  ...f, probe: f.probe.replace('import java.lang.instrument.Instrumentation;',
    'import java.lang.instrument.Instrumentation;\nimport org.objectweb.asm.ClassReader;'),
}), '[F] JavaApp/src/com/amcl/launcher/AmclAgentProbe.java 里出现了 org.objectweb.asm');

expectFail('retransform-enabled', (f) => ({
  ...f, probe: f.probe.replace('instrumentation.addTransformer(new AmclAgentProbe());',
    'instrumentation.addTransformer(new AmclAgentProbe(), true);'),
}), '[F] addTransformer 开了 canRetransform');

// ── G 组：清单与入口的配对断了 ───────────────────────────────────────
expectFail('premain-attribute-dropped', (f) => ({
  ...f, builder: f.builder.replace('Premain-Class: ${PREMAIN_CLASS}\\n', ''),
}), '[G] jar 清单文本里没有 Premain-Class 行');

expectFail('premain-method-renamed', (f) => ({
  ...f, probe: f.probe.replace('public static void premain(', 'public static void premainX('),
}), 'premain(...) —— JPLIS 找不到入口');

expectFail('after-redirect-restate-dropped', (f) => ({
  ...f,
  javaLauncher: f.javaLauncher.replace('AmclAgentProbe.reportAfterRedirect();', ''),
}), '没有在换流之后复述 premain 结论');

// ── H 组：只读判据被抄了一份 / 不在 clone 上跑 ───────────────────────
expectFail('criteria-entry-removed', (f) => ({
  ...f,
  patcher: f.patcher.replace('static String probeStructuralCriteria(',
    'static String probeStructuralCriteriaX('),
}), '[H] JavaApp/src/com/amcl/launcher/TerrainCompatibilityPatcher.java 里没有 probeStructuralCriteria');

expectFail('probe-mutates-caller-bytes', (f) => ({
  ...f,
  // 去掉 countInvocations 里的 clone：探针就能改到调用方的字节数组。
  patcher: f.patcher.replace(
    'ClassFile file = new ClassFile(bytes.clone());\n        int reference = file.findMethodReference(owner, name, desc);',
    'ClassFile file = new ClassFile(bytes);\n        int reference = file.findMethodReference(owner, name, desc);'),
}), '[H] countInvocations 没有在 clone 上工作');

// ── I 组：产物里没有探针类 ───────────────────────────────────────────
{
  const files = readAll();
  if (files.jarBytes === null || files.developerProduct === false) {
    console.log('  - jar-missing-probe-class（跳过：产物未构建）');
  } else {
    expectFail('jar-missing-probe-class', (f) => ({
      ...f, jarBytes: Buffer.from(f.jarBytes.toString('latin1')
        .replaceAll('com/amcl/launcher/AmclAgentProbe.class',
          'com/amcl/launcher/AmclAgentProbeXXXXX.clazz'), 'latin1'),
    }), '[I]');
  }
}

// ── 缺文件必须 fatal ─────────────────────────────────────────────────
expectFail('missing-probe-source-is-fatal', (f) => ({ ...f, probe: null }),
  '源文件缺失');

console.log(`\n  ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;

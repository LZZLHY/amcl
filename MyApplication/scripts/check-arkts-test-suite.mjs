#!/usr/bin/env node
// ArkTS 本地单元测试套件的源码契约检查。
//
// 为什么需要它：这套测试曾经整体失效很久而没人发现。三层架构重构把
// entry/src/main/ets/services/* 迁到各个 HAR 之后，30 个测试文件仍引用旧相对路径，
// `hvigorw test` 在 633 个 unresolved-import 处直接停住 —— 结果不是"某几条用例红了"，
// 而是**一条都没跑**，而 CI 里又没有 OHOS SDK 可以跑 hvigor，所以没有任何信号。
//
// 本脚本用纯静态检查覆盖那次事故的三种成因，跑得起来不需要 SDK：
//   1. 相对 import 必须指向真实存在的文件（那次事故的直接原因）。
//   2. 非相对 import 必须是 entry 声明过的依赖或已知平台模块（防止引用一个没在
//      oh-package.json5 里声明的 HAR —— 那种错误只在真机构建时才暴露）。
//   3. 每个 *.test.ets 都必须在 List.test.ets 里既 import 又调用（另一种静默腐烂：
//      文件在、但从来没被执行，看起来"有覆盖"其实没有）。
//
// 边界：它不能替代真的跑测试。它只保证"套件不会因为路径/注册问题而整体不执行"。

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const TEST_DIR = 'entry/src/test';
const AGGREGATOR = 'List.test.ets';

// 平台/工具链提供的模块前缀，不需要出现在 oh-package.json5 里。
const PLATFORM_PREFIXES = ['@kit.', '@ohos.', '@system.', '@arkts.', '@hms.'];
// 由 oh-package devDependencies 或 native 产物提供的固定说明符。
const KNOWN_SPECIFIERS = new Set(['@ohos/hypium', '@ohos/hamock', 'libentry.so']);

function read(root, relative) {
  const target = join(root, relative);
  return existsSync(target) ? readFileSync(target, 'utf8') : null;
}

/** 收集一个 ArkTS 文件里的所有 import 说明符（含 export ... from）。 */
/**
 * 去掉行注释与块注释。
 *
 * 必须做：否则「被注释掉的调用」会被当成真的调用 —— 而临时注释掉一条 suite 调用
 * 恰恰是最常见的人为动作，也正是本门禁要防的"文件在、但从不执行"形态。
 * 这里不处理字符串里出现 `//` 的情形：本门禁只在 import 说明符与函数调用上做判断，
 * 说明符本身在下面用带引号的正则单独采集，不受影响。
 */
function stripComments(text) {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1');
}

/** 单引号与双引号都要认：只认单引号会让同一类断裂在双引号写法下整批漏过。 */
function collectSpecifiers(text) {
  const specifiers = [];
  const quoted = String.raw`'([^']+)'|"([^"]+)"`;
  for (const match of text.matchAll(
      new RegExp(String.raw`(?:^|\n)\s*(?:import|export)[\s\S]*?from\s*(?:${quoted})`, 'g'))) {
    specifiers.push(match[1] ?? match[2]);
  }
  // 副作用式 import（import 'x' / import "x"）也算。
  for (const match of text.matchAll(
      new RegExp(String.raw`(?:^|\n)\s*import\s*(?:${quoted})`, 'g'))) {
    specifiers.push(match[1] ?? match[2]);
  }
  return specifiers;
}

/**
 * 相对说明符能否解析到真实**文件**。ArkTS 省略扩展名，需要逐个候选试。
 *
 * 刻意不把裸目录算作命中：`existsSync('.../components')` 为 true，但没有 index 的
 * 目录 ArkTS 解析不了，那样会把一个真实断裂判成通过。
 *
 * 已知局限：Windows 的 existsSync 大小写不敏感，因此"大小写写错的相对 import"在本机
 * 放行、Linux CI 才会炸。要彻底消掉需要逐层比对真实目录项名，成本不划算；这里明确
 * 记下边界，真正的把关仍是 hvigorw test。
 */
function resolvesOnDisk(root, testRelativeDir, specifier) {
  const base = resolve(join(root, testRelativeDir), specifier);
  const candidates = [
    base, `${base}.ets`, `${base}.ts`, `${base}.d.ts`,
    join(base, 'index.ets'), join(base, 'Index.ets'), join(base, 'index.ts'),
  ];
  return candidates.some(candidate => {
    if (!existsSync(candidate)) return false;
    try {
      return statSync(candidate).isFile();
    } catch {
      return false;
    }
  });
}

export function validateArktsTestSuite(root) {
  const issues = [];

  const testDirAbsolute = join(root, TEST_DIR);
  if (!existsSync(testDirAbsolute)) {
    issues.push(`${TEST_DIR} is missing`);
    return issues;
  }

  const packageText = read(root, 'entry/oh-package.json5');
  const declaredDependencies = new Set();
  if (packageText === null) {
    issues.push('entry/oh-package.json5 is missing');
  } else {
    // oh-package.json5 是 JSON5；只取依赖键名，用正则比引 JSON5 解析器更省依赖。
    const block = /"dependencies"\s*:\s*\{([\s\S]*?)\}/.exec(packageText);
    if (block) {
      for (const match of block[1].matchAll(/"([^"]+)"\s*:/g)) {
        declaredDependencies.add(match[1]);
      }
    }
  }

  const aggregatorText = read(root, `${TEST_DIR}/${AGGREGATOR}`);
  if (aggregatorText === null) {
    issues.push(`${TEST_DIR}/${AGGREGATOR} is missing`);
  }

  const testFiles = readdirSync(testDirAbsolute)
    .filter(name => name.endsWith('.test.ets') && name !== AGGREGATOR)
    .sort();
  if (testFiles.length === 0) {
    issues.push(`${TEST_DIR} contains no *.test.ets files`);
  }

  for (const name of [...testFiles, AGGREGATOR]) {
    const text = read(root, `${TEST_DIR}/${name}`);
    if (text === null) continue;
    for (const specifier of collectSpecifiers(text)) {
      if (specifier.startsWith('.')) {
        if (!resolvesOnDisk(root, TEST_DIR, specifier)) {
          issues.push(
            `${TEST_DIR}/${name} imports '${specifier}', which does not exist on disk`);
        }
        continue;
      }
      if (KNOWN_SPECIFIERS.has(specifier)) continue;
      if (PLATFORM_PREFIXES.some(prefix => specifier.startsWith(prefix))) continue;
      if (!declaredDependencies.has(specifier)) {
        issues.push(
          `${TEST_DIR}/${name} imports '${specifier}', which is not a declared ` +
          'entry dependency (add it to entry/oh-package.json5 or fix the import)');
      }
    }
  }

  // 每个测试文件都必须被聚合器 import 且调用，否则它永远不会执行。
  // 判断前先去注释：`// alphaTest();` 与 `if (false) { alphaTest(); }` 都不算调用。
  if (aggregatorText !== null) {
    const aggregatorCode = stripComments(aggregatorText);
    const imported = new Set();
    for (const match of aggregatorCode.matchAll(
        /import\s+(\w+)\s+from\s*(?:'\.\/([^']+)'|"\.\/([^"]+)")/g)) {
      imported.add(`${match[2] ?? match[3]}.ets`);
    }
    for (const name of testFiles) {
      const moduleName = name.replace(/\.ets$/, '');
      if (!imported.has(name) && !imported.has(`${moduleName}.ets`)) {
        issues.push(
          `${TEST_DIR}/${name} is never imported by ${AGGREGATOR}; it would silently ` +
          'never run');
        continue;
      }
      // 找到 default import 的本地名，再确认它在 testsuite() 体内被真的调用过。
      const escaped = moduleName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const importMatch = new RegExp(
        `import\\s+(\\w+)\\s+from\\s*(?:'\\./${escaped}'|"\\./${escaped}")`)
        .exec(aggregatorCode);
      if (!importMatch) continue;
      const localName = importMatch[1];
      // 在去注释后的代码里、且只看 export default 之后的部分：import 行本身不算调用。
      const bodyIndex = aggregatorCode.indexOf('export default');
      const body = bodyIndex >= 0 ? aggregatorCode.slice(bodyIndex) : '';
      const invoked = new RegExp(`\\b${localName}\\s*\\(`).test(body);
      if (!invoked) {
        issues.push(
          `${AGGREGATOR} imports ${localName} from ${name} but never calls it; the ` +
          'suite would silently never run');
      }
    }
  }

  return issues;
}

const invokedDirectly = process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) {
  const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
  const issues = validateArktsTestSuite(root);
  if (issues.length > 0) {
    for (const issue of issues) console.error(`[check-arkts-test-suite] ${issue}`);
    console.error(
      '[check-arkts-test-suite] the local ArkTS suite would not run as a whole; ' +
      'this is the failure mode that hid 633 unresolved imports before');
    process.exitCode = 1;
  } else {
    const count = readdirSync(join(root, TEST_DIR))
      .filter(name => name.endsWith('.test.ets') && name !== AGGREGATOR).length;
    console.log('[check-arkts-test-suite] PASS');
    console.log(`  suites registered: ${count}`);
    console.log('  checked: relative imports resolve to real files, bare imports name a');
    console.log('           declared entry dependency, every *.test.ets is imported and');
    console.log('           invoked by List.test.ets (comments do not count as a call)');
    // 说清边界，不要让 PASS 被读成"import 的符号都对"。
    console.log('  NOT checked: whether each named symbol is actually exported by that');
    console.log('               module. That needs the real compiler — build-hap.ps1');
    console.log('               runs hvigorw test for it; CI has no OHOS SDK.');
  }
}

#!/usr/bin/env node
// check-arkts-test-suite.mjs 的定向自测。
//
// 门禁写错的失败方式是**静默放行**：套件整体不执行，而检查说 PASS。这正是它要防的
// 那次事故的形态，所以这里用临时 fixture 树逐条证明三种腐烂都会被报出来，
// 并且正常结构不会误报。

import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateArktsTestSuite } from './check-arkts-test-suite.mjs';

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));

function write(root, path, content) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, 'utf8');
}

const TEST_DIR = 'entry/src/test';

/**
 * 建一棵最小 fixture：一个被正确注册的测试、它依赖的源文件、以及 oh-package 依赖声明。
 * options 用来注入各种腐烂形态。
 */
function buildFixture(options) {
  const root = mkdtempSync(join(tmpdir(), 'amcl-arkts-suite-'));
  write(root, 'entry/oh-package.json5', options?.package ?? `{
  "name": "entry",
  "dependencies": {
    "commons": "file:../commons",
    "libentry.so": "file:./src/main/cpp/types/libentry"
  }
}
`);
  write(root, 'commons/Index.ets', 'export const marker = 1;\n');
  write(root, 'entry/src/main/ets/components/Widget.ets', 'export const widget = 1;\n');
  write(root, `${TEST_DIR}/Alpha.test.ets`, options?.alpha ?? `
import { describe } from '@ohos/hypium';
import { marker } from 'commons';
import { widget } from '../main/ets/components/Widget';
export default function alphaTest() { describe('alpha', () => {}); }
`);
  write(root, `${TEST_DIR}/List.test.ets`, options?.aggregator ?? `
import alphaTest from './Alpha.test';
export default function testsuite() {
  alphaTest();
}
`);
  return root;
}

let failures = 0;

function check(label, options, expectation) {
  const root = buildFixture(options);
  try {
    const issues = validateArktsTestSuite(root);
    const problem = expectation(issues);
    if (problem) {
      failures += 1;
      console.error(`[test-check-arkts-test-suite] FAIL: ${label} — ${problem}`);
      console.error(`  issues: ${issues.join(' | ') || '(none)'}`);
    } else {
      console.log(`[test-check-arkts-test-suite] PASS: ${label}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const expectClean = issues => issues.length === 0 ? null : 'expected no issues';
const expectIssue = pattern => issues =>
  issues.some(issue => pattern.test(issue)) ? null : `expected issue matching ${pattern}`;

// 1. 正常结构：不得误报。
check('healthy suite', null, expectClean);

// 2. 相对 import 指向不存在的文件 —— 那次 633 个错误的直接形态。
check('dangling relative import', {
  alpha: `
import { describe } from '@ohos/hypium';
import { gone } from '../main/ets/services/mods/ModTypes';
export default function alphaTest() { describe('alpha', () => {}); }
`,
}, expectIssue(/does not exist on disk/));

// 3. 引用了没在 oh-package.json5 声明的 HAR —— 只在真机构建才暴露的错误。
check('undeclared bare dependency', {
  alpha: `
import { describe } from '@ohos/hypium';
import { thing } from 'feature_core';
export default function alphaTest() { describe('alpha', () => {}); }
`,
}, expectIssue(/not a declared entry dependency/));

// 4. 测试文件存在但聚合器没 import —— 看起来有覆盖，其实从不执行。
check('test file never imported', {
  aggregator: `
export default function testsuite() {}
`,
}, expectIssue(/never imported by List\.test\.ets/));

// 5. 聚合器 import 了却没调用 —— 同样从不执行。
check('imported but never invoked', {
  aggregator: `
import alphaTest from './Alpha.test';
export default function testsuite() {
  // 忘了调用
}
`,
}, expectIssue(/never calls it/));

// 5a. 调用被注释掉 —— 最常见的人为动作，必须算「没有调用」。
check('invocation commented out with //', {
  aggregator: `
import alphaTest from './Alpha.test';
export default function testsuite() {
  // alphaTest();
}
`,
}, expectIssue(/never calls it/));

check('invocation commented out with block comment', {
  aggregator: `
import alphaTest from './Alpha.test';
export default function testsuite() {
  /* alphaTest(); */
}
`,
}, expectIssue(/never calls it/));

// 5b. 双引号说明符必须同样被采集，否则同类断裂在双引号写法下整批漏过。
check('dangling relative import with double quotes', {
  alpha: `
import { describe } from '@ohos/hypium';
import { gone } from "../main/ets/services/mods/ModTypes";
export default function alphaTest() { describe('alpha', () => {}); }
`,
}, expectIssue(/does not exist on disk/));

check('double-quoted aggregator import is recognized', {
  aggregator: `
import alphaTest from "./Alpha.test";
export default function testsuite() {
  alphaTest();
}
`,
}, expectClean);

// 5c. 相对 import 指向一个没有 index 的目录：ArkTS 解析不了，不能算命中。
check('relative import pointing at a bare directory', {
  alpha: `
import { describe } from '@ohos/hypium';
import { widget } from '../main/ets/components';
export default function alphaTest() { describe('alpha', () => {}); }
`,
}, expectIssue(/does not exist on disk/));

// 6. 平台模块（@kit./@ohos.）不需要声明，不得误报。
check('platform module import is allowed', {
  alpha: `
import { describe } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import inputDevice from '@ohos.multimodalInput.inputDevice';
export default function alphaTest() { describe('alpha', () => {}); }
`,
}, expectClean);

// 7. 聚合器缺失。
{
  const root = buildFixture(null);
  try {
    rmSync(join(root, `${TEST_DIR}/List.test.ets`));
    const issues = validateArktsTestSuite(root);
    if (issues.some(issue => /List\.test\.ets is missing/.test(issue))) {
      console.log('[test-check-arkts-test-suite] PASS: missing aggregator');
    } else {
      failures += 1;
      console.error('[test-check-arkts-test-suite] FAIL: missing aggregator not reported');
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// 8. 真实仓库必须通过（保证 fixture 与出货结构没有分叉）。
{
  const issues = validateArktsTestSuite(repoRoot);
  if (issues.length === 0) {
    console.log('[test-check-arkts-test-suite] PASS: real repository suite');
  } else {
    failures += 1;
    console.error('[test-check-arkts-test-suite] FAIL: real repository reported issues');
    for (const issue of issues) console.error(`  ${issue}`);
  }
}

if (failures > 0) {
  console.error(`[test-check-arkts-test-suite] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-arkts-test-suite] ALL PASS');
}

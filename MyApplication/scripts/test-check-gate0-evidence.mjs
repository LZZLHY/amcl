#!/usr/bin/env node
// check-gate0-evidence.mjs 的定向自测。
//
// 为什么需要：门禁脚本本身如果写错（例如把"未批准"也放行），失败方式是**静默放行**，
// 不会有任何构建信号。因此这里用临时 fixture 树逐条证明：合法清单通过，而每一种能
// 绕过 Gate 0 的写法都必须被报出来。

import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateGate0Evidence, MANAGED_CAPABILITIES } from './check-gate0-evidence.mjs';

// fileURLToPath 而不是手撕 URL.pathname：后者只在 Windows 上凑巧成立，POSIX 会得到
// 相对路径，且路径含空格/非 ASCII 时是 percent-encoded，失败形式是难懂的 ENOENT。
const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));

function write(root, path, content) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, 'utf8');
}

function sha256(text) {
  return createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex');
}

// fixture 复用真实的 Gate0Evidence.cmake：门禁行为断言必须打在出货文件上，
// 否则自测只会验证一份复制品。
const realGate = readFileSync(
  join(repoRoot, 'entry/src/main/cpp/input/Gate0Evidence.cmake'), 'utf8');

function optionBlock(capability) {
  return `option(${capability}\n    "fixture" OFF)\n`;
}

const realCmakeSkeleton =
  MANAGED_CAPABILITIES.map(optionBlock).join('\n') +
  'include(${CMAKE_CURRENT_SOURCE_DIR}/input/Gate0Evidence.cmake)\n' +
  'target_compile_definitions(glfw PRIVATE\n' +
  '    AMCL_GATE0_EVIDENCE_IDS="${AMCL_GATE0_EVIDENCE_IDS_STRING}"\n' +
  ')\n';

function unapproved(reason) {
  return {
    approved: false,
    evidenceId: '',
    evidenceDocument: '',
    evidenceSha256: '',
    deviceMatrix: [],
    sdkVersion: '',
    approvedBy: '',
    approvedOn: '',
    independentReviewer: '',
    requires: [],
    blockedBy: reason,
  };
}

const EVIDENCE_TEXT = '# fixture evidence\n\ndevice matrix recorded\n';

function approved(overrides) {
  return Object.assign({
    approved: true,
    evidenceId: 'gate0-fixture-0001',
    evidenceDocument: 'docs/testing/gate0-fixture.md',
    evidenceSha256: sha256(EVIDENCE_TEXT),
    deviceMatrix: ['fixture-device-1'],
    sdkVersion: '6.0.0(20)',
    approvedBy: 'fixture-owner',
    approvedOn: '2026-08-14',
    independentReviewer: 'fixture-reviewer',
    requires: [],
  }, overrides ?? {});
}

/** 写一棵最小 fixture 树；capabilities 由调用方给出。 */
function buildFixture(capabilities, options) {
  const root = mkdtempSync(join(tmpdir(), 'amcl-gate0-'));
  write(root, 'gate0-evidence.lock',
    JSON.stringify({ schemaVersion: 1, capabilities }, null, 2));
  write(root, 'entry/src/main/cpp/input/Gate0Evidence.cmake', realGate);
  write(root, 'entry/src/main/cpp/CMakeLists.txt',
    options?.cmake ?? realCmakeSkeleton);
  write(root, 'entry/build-profile.json5',
    options?.profile ?? '{ "buildOption": { "externalNativeOptions": { "arguments": "" } } }');
  write(root, 'docs/testing/gate0-fixture.md',
    options?.evidence ?? EVIDENCE_TEXT);
  return root;
}

function defaultCapabilities() {
  const capabilities = {};
  for (const capability of MANAGED_CAPABILITIES) {
    capabilities[capability] = unapproved('fixture: no target device');
  }
  return capabilities;
}

let failures = 0;

function check(label, capabilities, options, expectation) {
  const root = buildFixture(capabilities, options);
  try {
    const issues = validateGate0Evidence(root);
    const problem = expectation(issues);
    if (problem) {
      failures += 1;
      console.error(`[test-check-gate0-evidence] FAIL: ${label} — ${problem}`);
      console.error(`  issues: ${issues.join(' | ') || '(none)'}`);
    } else {
      console.log(`[test-check-gate0-evidence] PASS: ${label}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const expectClean = issues =>
  issues.length === 0 ? null : 'expected no issues';
const expectIssue = (pattern) => (issues) =>
  issues.some(issue => pattern.test(issue)) ? null : `expected issue matching ${pattern}`;

// 1. 全部未批准 + 选项默认 OFF：这就是当前仓库状态，必须干净通过。
check('all unapproved with blockedBy reasons', defaultCapabilities(), null, expectClean);

// 2. 未批准条目缺 blockedBy：必须报出来，避免"忘了为什么没开"。
{
  const capabilities = defaultCapabilities();
  capabilities[MANAGED_CAPABILITIES[0]].blockedBy = '';
  check('unapproved without blockedBy', capabilities, null,
    expectIssue(/must record a non-empty 'blockedBy'/));
}

// 3. 缺少某个受管能力条目：新增选项若只加在 CMake 一侧就会绕过门禁。
{
  const capabilities = defaultCapabilities();
  delete capabilities[MANAGED_CAPABILITIES[1]];
  check('missing capability entry', capabilities, null,
    expectIssue(/has no entry for/));
}

// 4. 合法批准（无依赖）：必须通过。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved();
  check('valid approval', capabilities, null, expectClean);
}

// 5. 批准但证据文档哈希不符：防止"先批准空文档，之后再写结论"。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved();
  check('approved with tampered evidence document', capabilities,
    { evidence: EVIDENCE_TEXT + 'tampered\n' },
    expectIssue(/sha256 mismatch/));
}

// 6. 批准但证据文档不存在。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED =
    approved({ evidenceDocument: 'docs/testing/does-not-exist.md' });
  check('approved with missing evidence document', capabilities, null,
    expectIssue(/evidenceDocument does not exist/));
}

// 7. 批准但设备矩阵为空：没有设备标识就无法追溯证据来源。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ deviceMatrix: [] });
  check('approved with empty device matrix', capabilities, null,
    expectIssue(/deviceMatrix must be a non-empty array/));
}

// 8. evidenceId 为占位符。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ evidenceId: 'TODO-later-1' });
  check('approved with placeholder evidenceId', capabilities, null,
    expectIssue(/looks like a placeholder/));
}

// 9. evidenceId 过短。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ evidenceId: 'a1b2' });
  check('approved with too-short evidenceId', capabilities, null,
    expectIssue(/must be >= 8 chars/));
}

// 10. 缺独立复核人：§1.1 第 3/5 条要求施工者不能自证完成。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ independentReviewer: '' });
  check('approved without independent reviewer', capabilities, null,
    expectIssue(/'independentReviewer' must be a non-empty string/));
}

// 11. approvedOn 日期格式非法。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ approvedOn: '2026/08/14' });
  check('approved with malformed date', capabilities, null,
    expectIssue(/must be YYYY-MM-DD/));
}

// 12. 依赖能力未一并批准：native absolute 单独批准发布不出能力位。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED = approved({
    requires: ['AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED'],
  });
  check('approved with unapproved dependency', capabilities, null,
    expectIssue(/dependency AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED is not approved/));
}

// 13. 依赖链完整批准：必须通过。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED = approved({
    evidenceId: 'gate0-fixture-ts01',
  });
  capabilities.AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED = approved({
    evidenceId: 'gate0-fixture-abs1',
    requires: ['AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED'],
  });
  check('approved dependency chain', capabilities, null, expectClean);
}

// 14. 产品构建配置在未批准时打开选项：最容易被顺手改的地方。
//     真值判定必须与 CMake 侧同口径（非明确假值即视为启用），否则 `=2` 之类的写法
//     会在 source gate 静默通过而 CMake 侧当作已启用。
for (const truthy of ['ON', '1', 'TRUE', 'YES', '2', '00', 'anything']) {
  check(`build profile enables unapproved capability via =${truthy}`,
    defaultCapabilities(),
    {
      profile: '{ "buildOption": { "externalNativeOptions": ' +
        `{ "arguments": "-DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=${truthy}" } } }`,
    },
    expectIssue(/build-profile\.json5 enables AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED/));
}

// 14a. 写法集合：CMake 允许类型后缀，JSON5 里的值可能带引号或 JSON 转义。
//      只认裸写法会让这些形态静默通过 —— 与"只认 4 种取值"是同一族缺陷。
for (const form of [
  'AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED:BOOL=ON',
  "AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED='1'",
  'AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=\\\\\\"1\\\\\\"',
]) {
  check(`build profile enables via -D${form}`, defaultCapabilities(),
    {
      profile: '{ "buildOption": { "externalNativeOptions": ' +
        `{ "arguments": "-D${form}" } } }`,
    },
    expectIssue(/build-profile\.json5 enables AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED/));
}

// 14a-2. 带类型后缀的 evidence id 注入同样要拦。
check('build profile forges an evidence id with a type suffix',
  defaultCapabilities(),
  {
    profile: '{ "buildOption": { "externalNativeOptions": ' +
      '{ "cppFlags": "-DAMCL_GATE0_EVIDENCE_IDS:STRING=forged-0001" } } }',
  },
  expectIssue(/defines AMCL_GATE0_EVIDENCE_IDS directly/));

// 14b. 明确的假值不得误报，否则默认配置会被门禁挡住。
for (const falsy of ['OFF', '0', 'NO', 'FALSE', 'IGNORE']) {
  check(`build profile with =${falsy} is not an enablement`, defaultCapabilities(),
    {
      profile: '{ "buildOption": { "externalNativeOptions": ' +
        `{ "arguments": "-DAMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED=${falsy}" } } }`,
    },
    expectClean);
}

// 14c. cppFlags 直接注宏：该字段进编译器命令行，能覆盖 target_compile_definitions
//      给出的 =0，是 static_assert 之外必须由 source gate 兜住的通道。
check('build profile injects the macro through cppFlags', defaultCapabilities(),
  {
    profile: '{ "buildOption": { "externalNativeOptions": ' +
      '{ "cppFlags": "-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=1" } } }',
  },
  expectIssue(/build-profile\.json5 enables AMCL_GLFW_RAW_RELATIVE_VERIFIED/));

// 14d. 手写 evidence id 去满足 static_assert：只有 Gate0Evidence.cmake 可以注入它。
check('build profile forges an evidence id', defaultCapabilities(),
  {
    profile: '{ "buildOption": { "externalNativeOptions": ' +
      '{ "cppFlags": "-DAMCL_GATE0_EVIDENCE_IDS=\\\\\\"forged-id-0001\\\\\\"" } } }',
  },
  expectIssue(/defines AMCL_GATE0_EVIDENCE_IDS directly/));

// 14e. typed 验证包的覆盖残留在出货配置里：必须硬失败。
// ⚠️ 这一条挡的是本门禁此前**结构上看不见**的形状 —— 那行 -D 里既没有 *_VERIFIED
// 也没有 evidence id 字样，14a–14d 五条判据对它全部恒不命中。
{
  const previous = process.env.AMCL_TYPED_VALIDATION;
  delete process.env.AMCL_TYPED_VALIDATION;
  try {
    check('build profile keeps the typed-validation override', defaultCapabilities(),
      {
        profile: '{ "buildOption": { "externalNativeOptions": { "arguments": ' +
          '"-DMC_OHOS_BUILD_TESTS=OFF -DCMAKE_PROJECT_INCLUDE=' +
          '/repo/scripts/typed-validation-inject.cmake" } } }',
      },
      expectIssue(/still carries the typed-validation override/));
    // 只出现 CMAKE_PROJECT_INCLUDE、不含 typed-validation 字样也要拦：任意注入点都能
    // 覆盖任意宏，判据不能依赖文件名（按"效果"而不是按"写法"枚举）。
    check('build profile injects an arbitrary CMAKE_PROJECT_INCLUDE', defaultCapabilities(),
      {
        profile: '{ "buildOption": { "externalNativeOptions": { "arguments": ' +
          '"-DCMAKE_PROJECT_INCLUDE=/tmp/anything.cmake" } } }',
      },
      expectIssue(/still carries the typed-validation override/));
  } finally {
    if (previous === undefined) delete process.env.AMCL_TYPED_VALIDATION;
    else process.env.AMCL_TYPED_VALIDATION = previous;
  }
}

// 14f. 同一份配置 + AMCL_TYPED_VALIDATION=1：那一次构建必须放行，否则验证包出不来。
// 这是这条规则的**正向证据门**：光证明它会失败不够，还要证明它不是恒失败。
{
  const previous = process.env.AMCL_TYPED_VALIDATION;
  process.env.AMCL_TYPED_VALIDATION = '1';
  try {
    check('typed-validation override with the explicit opt-in', defaultCapabilities(),
      {
        profile: '{ "buildOption": { "externalNativeOptions": { "arguments": ' +
          '"-DMC_OHOS_BUILD_TESTS=OFF -DCMAKE_PROJECT_INCLUDE=' +
          '/repo/scripts/typed-validation-inject.cmake" } } }',
      },
      expectClean);
  } finally {
    if (previous === undefined) delete process.env.AMCL_TYPED_VALIDATION;
    else process.env.AMCL_TYPED_VALIDATION = previous;
  }
}

// 15. 已批准时允许产品配置打开（不能误报）。
{
  const capabilities = defaultCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved();
  check('build profile enables approved capability', capabilities,
    {
      profile: '{ "buildOption": { "externalNativeOptions": ' +
        '{ "arguments": "-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON" } } }',
    },
    expectClean);
}

// 16. CMakeLists 没有 include 门禁：门禁文件在但没接线等于没有门禁。
check('cmake does not include the gate', defaultCapabilities(),
  { cmake: MANAGED_CAPABILITIES.map(optionBlock).join('\n') },
  expectIssue(/does not include input\/Gate0Evidence\.cmake/));

// 17. option 默认不是 OFF：默认开启等于绕过门禁的既成事实。
check('option defaults to ON', defaultCapabilities(),
  {
    cmake: 'option(AMCL_GLFW_RAW_RELATIVE_VERIFIED\n    "fixture" ON)\n' +
      optionBlock(MANAGED_CAPABILITIES[1]) + optionBlock(MANAGED_CAPABILITIES[2]) +
      'include(${CMAKE_CURRENT_SOURCE_DIR}/input/Gate0Evidence.cmake)\n' +
      'target_compile_definitions(glfw PRIVATE\n' +
      '    AMCL_GATE0_EVIDENCE_IDS="${AMCL_GATE0_EVIDENCE_IDS_STRING}"\n' +
      ')\n',
  },
  expectIssue(/must default to OFF/));

// 18. 产物没有嵌入 evidence id：无法从 .so 反查是谁授权的。
check('cmake does not embed evidence ids', defaultCapabilities(),
  {
    cmake: MANAGED_CAPABILITIES.map(optionBlock).join('\n') +
      'include(${CMAKE_CURRENT_SOURCE_DIR}/input/Gate0Evidence.cmake)\n',
  },
  expectIssue(/does not embed AMCL_GATE0_EVIDENCE_IDS/));

// 19. schemaVersion 未知：不得把未知 schema 当成批准。
{
  const root = mkdtempSync(join(tmpdir(), 'amcl-gate0-'));
  try {
    write(root, 'gate0-evidence.lock',
      JSON.stringify({ schemaVersion: 2, capabilities: defaultCapabilities() }));
    write(root, 'entry/src/main/cpp/input/Gate0Evidence.cmake', realGate);
    write(root, 'entry/src/main/cpp/CMakeLists.txt', realCmakeSkeleton);
    write(root, 'entry/build-profile.json5', '{}');
    const issues = validateGate0Evidence(root);
    if (issues.some(issue => /schemaVersion must be 1/.test(issue))) {
      console.log('[test-check-gate0-evidence] PASS: unknown schemaVersion');
    } else {
      failures += 1;
      console.error('[test-check-gate0-evidence] FAIL: unknown schemaVersion not reported');
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// 20. 清单缺失。
{
  const root = mkdtempSync(join(tmpdir(), 'amcl-gate0-'));
  try {
    const issues = validateGate0Evidence(root);
    if (issues.some(issue => /gate0-evidence\.lock is missing/.test(issue))) {
      console.log('[test-check-gate0-evidence] PASS: missing manifest');
    } else {
      failures += 1;
      console.error('[test-check-gate0-evidence] FAIL: missing manifest not reported');
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// 21. 真实仓库必须通过（同时保证 fixture 与出货配置没有分叉）。
{
  const issues = validateGate0Evidence(repoRoot);
  if (issues.length === 0) {
    console.log('[test-check-gate0-evidence] PASS: real repository manifest');
  } else {
    failures += 1;
    console.error('[test-check-gate0-evidence] FAIL: real repository reported issues');
    for (const issue of issues) console.error(`  ${issue}`);
  }
}

if (failures > 0) {
  console.error(`[test-check-gate0-evidence] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-check-gate0-evidence] ALL PASS');
}

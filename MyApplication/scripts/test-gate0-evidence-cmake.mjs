#!/usr/bin/env node
// Gate0Evidence.cmake 的行为测试（真实 configure，非文本匹配）。
//
// 为什么必须实测：check-gate0-evidence.mjs 只能证明门禁文件的**文本**里有
// FATAL_ERROR 与哈希校验；它无法证明 CMake 真的会因为"未批准却打开选项"而停下。
// 门禁一旦静默放行，失败方式就是产出一个宣称未验证能力的 .so，没有任何构建信号。
// 因此这里在临时工程里 include 出货的 Gate0Evidence.cmake，逐个场景 configure，
// 并断言成功/失败与失败原因。
//
// 用的是 host CMake，不需要 OHOS 工具链：门禁只读文件、只设变量，不定义任何目标。

import {
  mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, existsSync, cpSync,
} from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
const gateSource = join(repoRoot, 'entry/src/main/cpp/input/Gate0Evidence.cmake');

const CAPABILITIES = [
  'AMCL_GLFW_RAW_RELATIVE_VERIFIED',
  'AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED',
  'AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED',
];

function locateCmake() {
  const candidates = [
    process.env.AMCL_HOST_CMAKE,
    'D:/Huawei/command-line-tools/sdk/default/openharmony/native/build-tools/cmake/bin/cmake.exe',
    'D:/Huawei/DevEco Studio/sdk/default/openharmony/native/build-tools/cmake/bin/cmake.exe',
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  // PATH 兜底
  try {
    execFileSync('cmake', ['--version'], { stdio: 'ignore' });
    return 'cmake';
  } catch {
    // 继续尝试 Visual Studio 自带
  }
  const vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe';
  if (existsSync(vswhere)) {
    try {
      const root = execFileSync(vswhere, [
        '-latest', '-products', '*',
        '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath',
      ], { encoding: 'utf8' }).trim();
      const bundled = join(root,
        'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe');
      if (existsSync(bundled)) return bundled;
    } catch {
      // fall through
    }
  }
  return null;
}

const cmake = locateCmake();
if (!cmake) {
  // 不能验证就不能记通过。这里不做 SKIP：门禁的行为测试缺席时必须显式失败，
  // 否则"没跑"会被误读成"通过"。
  console.error('[test-gate0-evidence-cmake] no host CMake found; set AMCL_HOST_CMAKE');
  process.exitCode = 1;
  process.exit();
}

const EVIDENCE_TEXT = '# fixture evidence\n\ndevice matrix recorded\n';

function sha256(text) {
  return createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex');
}

function write(root, path, content) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, 'utf8');
}

function unapproved(reason) {
  return {
    approved: false, evidenceId: '', evidenceDocument: '', evidenceSha256: '',
    deviceMatrix: [], sdkVersion: '', approvedBy: '', approvedOn: '',
    independentReviewer: '', requires: [], blockedBy: reason,
  };
}

function approved(overrides) {
  return Object.assign({
    approved: true,
    evidenceId: 'gate0-cmake-fixture-1',
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

function baseCapabilities() {
  const capabilities = {};
  for (const capability of CAPABILITIES) {
    capabilities[capability] = unapproved('fixture: no target device');
  }
  return capabilities;
}

/**
 * 建一棵最小 fixture 树：清单 + 证据文档 + 一个只 include 门禁的 CMake 脚本。
 *
 * 用 script 模式（cmake -P）而不是 project()：门禁只读文件、只设变量，不需要
 * generator 也不需要编译器。project() 会强制 CMake 去找 nmake/ninja，在没有装
 * 构建工具的机器上会以一个与门禁无关的原因失败，把"门禁没拦住"和"环境缺工具"
 * 混成同一种结果 —— 那样这个测试就失去了意义。
 *
 * 门禁读的是 AMCL_REPO_ROOT，所以 fixture 根就是"仓库根"。
 */
function buildFixture(capabilities, evidenceText) {
  const root = mkdtempSync(join(tmpdir(), 'amcl-gate0-cmake-'));
  write(root, 'gate0-evidence.lock',
    JSON.stringify({ schemaVersion: 1, capabilities }, null, 2));
  write(root, 'docs/testing/gate0-fixture.md', evidenceText ?? EVIDENCE_TEXT);
  writeProbeScript(root);
  return root;
}

function writeProbeScript(root) {
  mkdirSync(join(root, 'probe/input'), { recursive: true });
  cpSync(gateSource, join(root, 'probe/input/Gate0Evidence.cmake'));
  const posixRoot = root.replace(/\\/g, '/');
  write(root, 'probe/probe.cmake', [
    `set(AMCL_REPO_ROOT "${posixRoot}")`,
    // script 模式下 option() 在变量已由 -D 定义时不覆盖，因此 -D 优先生效。
    ...CAPABILITIES.map(capability => `option(${capability} "fixture" OFF)`),
    `include("${posixRoot}/probe/input/Gate0Evidence.cmake")`,
    // 结果落文件而不是打日志：message(STATUS) 在 script 模式走 stderr，读文件更确定。
    'if(DEFINED PROBE_OUT)',
    '    file(WRITE "${PROBE_OUT}" "${AMCL_GATE0_EVIDENCE_IDS_STRING}")',
    'endif()',
    '',
  ].join('\n'));
}

function configure(root, defines) {
  const outFile = join(root, 'probe-evidence.txt');
  rmSync(outFile, { force: true });
  const args = [];
  for (const [name, value] of Object.entries(defines ?? {})) {
    args.push(`-D${name}=${value}`);
  }
  args.push(`-DPROBE_OUT=${outFile.replace(/\\/g, '/')}`);
  args.push('-P', join(root, 'probe/probe.cmake'));
  try {
    const stdout = execFileSync(cmake, args, { encoding: 'utf8', stdio: 'pipe' });
    const marker = existsSync(outFile) ? readFileSync(outFile, 'utf8') : '';
    return finish(true, `${stdout}\nPROBE_EVIDENCE=${marker}`);
  } catch (error) {
    return finish(false, `${error.stdout ?? ''}${error.stderr ?? ''}`);
  }
}

// CMake 会按终端宽度把 message(FATAL_ERROR) 的文本折行，原始输出里同一句话可能被
// 换行和缩进切断。断言必须打在语义上，而不是恰好的排版上，所以额外提供压缩空白后的
// 视图；否则改一句错误文案的措辞就会让测试以"没匹配到"的形式假失败。
function finish(ok, output) {
  return { ok, output, normalized: output.replace(/\s+/g, ' ') };
}

let failures = 0;

function run(label, capabilities, defines, expectation, evidenceText) {
  const root = buildFixture(capabilities, evidenceText);
  try {
    const result = configure(root, defines);
    const problem = expectation(result);
    if (problem) {
      failures += 1;
      console.error(`[test-gate0-evidence-cmake] FAIL: ${label} — ${problem}`);
      console.error(result.output.split('\n').slice(-25).join('\n'));
    } else {
      console.log(`[test-gate0-evidence-cmake] PASS: ${label}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const expectSuccess = (evidencePattern) => (result) => {
  if (!result.ok) return 'configure failed but should have succeeded';
  if (evidencePattern && !evidencePattern.test(result.normalized)) {
    return `expected evidence marker matching ${evidencePattern}`;
  }
  return null;
};
const expectFailure = (pattern) => (result) => {
  if (result.ok) return 'configure succeeded but should have failed closed';
  if (!pattern.test(result.normalized)) return `expected failure matching ${pattern}`;
  return null;
};

// 1. 默认路径：全部 OFF。必须成功，且产物记录 none（可与"忘记注入"区分）。
run('all options OFF', baseCapabilities(), {},
  expectSuccess(/PROBE_EVIDENCE=none/));

// 2. 未批准却打开：必须 fail closed。这是整条门禁存在的理由。
run('unapproved capability enabled', baseCapabilities(),
  { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
  expectFailure(/marks it approved=false/));

// 3. 清单缺失却打开：不能因为"读不到清单"就放行。
{
  const root = buildFixture(baseCapabilities());
  try {
    rmSync(join(root, 'gate0-evidence.lock'));
    const result = configure(root, { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' });
    if (!result.ok && /evidence manifest not found/.test(result.normalized)) {
      console.log('[test-gate0-evidence-cmake] PASS: missing manifest with option ON');
    } else {
      failures += 1;
      console.error('[test-gate0-evidence-cmake] FAIL: missing manifest did not fail closed');
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// 4. 合法批准：必须成功，并把 evidenceId 带进产物定义。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved();
  run('approved capability enabled', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectSuccess(/PROBE_EVIDENCE=AMCL_GLFW_RAW_RELATIVE_VERIFIED=gate0-cmake-fixture-1/));
}

// 5. 批准后证据文档被改：哈希不符必须 fail closed。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved();
  run('approved but evidence document tampered', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/sha256 mismatch/),
    `${EVIDENCE_TEXT}tampered\n`);
}

// 6. 设备矩阵为空：无法追溯证据来源，必须 fail closed。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ deviceMatrix: [] });
  run('approved with empty device matrix', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/deviceMatrix is empty/));
}

// 7. 占位 evidenceId：必须 fail closed。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ evidenceId: 'TODO-2026-08' });
  run('approved with placeholder evidenceId', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/looks like a placeholder/));
}

// 8. 缺独立复核人：必须 fail closed（§1.1 第 3/5 条）。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ independentReviewer: '' });
  run('approved without independent reviewer', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/field 'independentReviewer' is missing or empty/));
}

// 9. native absolute 只开一半：C++ 侧本来就是 AND，静默无效必须变成显式失败。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED = approved({
    evidenceId: 'gate0-cmake-abs-1',
    requires: ['AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED'],
  });
  capabilities.AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED = approved({
    evidenceId: 'gate0-cmake-ts-1',
  });
  run('native absolute enabled without its timestamp dependency', capabilities,
    { AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED: 'ON' },
    expectFailure(/requires AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED=ON/));
}

// 9b. `requires` 读不到时必须 fail closed，不能静默跳过依赖检查。
//
// 为什么单独测这个：`requires` 曾是 Gate0Evidence.cmake 里唯一 fail-open 的字段
// （`if(NOT requiresError AND ...)`），而它承载的正是「依赖能力只开一半」这条
// configure 层保证。旧写法下那条保证实际依赖 source gate 那一层
// （check-gate0-evidence.mjs 强制 requires 是数组）—— 一层的保证依赖另一层，
// 而三层强度表的全部价值在于每层可被单独信任。
//
// 两个方向都测：键缺失、以及写成非数组（JSON LENGTH 对标量报错）。
// 反向对照由用例 10 提供（`requires: []` 必须仍然合法）。
{
  const capabilities = baseCapabilities();
  const missing = approved({ evidenceId: 'gate0-cmake-req-1' });
  delete missing.requires;
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = missing;
  run('requires key absent must fail closed', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/'requires' is missing or is not an array/));
}
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({
    evidenceId: 'gate0-cmake-req-2',
    requires: 'AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED',
  });
  run('requires as a scalar must fail closed', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/'requires' is missing or is not an array/));
}

// 10. 依赖同时打开且都已批准：必须成功，且两条 evidence 都进产物。
//     顺带覆盖 `requires: []`（用例 9b 的反向对照）—— 显式无依赖必须仍然合法。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED = approved({
    evidenceId: 'gate0-cmake-abs-1',
    requires: ['AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED'],
  });
  capabilities.AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED = approved({
    evidenceId: 'gate0-cmake-ts-1',
  });
  run('native absolute with dependency both enabled', capabilities,
    {
      AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED: 'ON',
      AMCL_GLFW_NATIVE_MOUSE_MONOTONIC_NS_VERIFIED: 'ON',
    },
    expectSuccess(/gate0-cmake-abs-1[\s\S]*gate0-cmake-ts-1|gate0-cmake-ts-1[\s\S]*gate0-cmake-abs-1/));
}

// 11. approvedOn 日期非法。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED = approved({ approvedOn: '14-08-2026' });
  run('approved with malformed date', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/is not YYYY-MM-DD/));
}

// 12. 证据文档不存在。
{
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED =
    approved({ evidenceDocument: 'docs/testing/absent.md' });
  run('approved with missing evidence document', capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/evidenceDocument does not exist/));
}

// 13. 真值写法矩阵。这是最容易出错、后果最严重的一处：门禁判定与宏发布必须是同一次
//     求值。`=1/TRUE/YES/y/on` 都必须被视为"已启用"从而 fail closed；而 `=00/0.0/-0`
//     这类取值 CMake 的 if() 判假、$<BOOL:> 判真，一旦两边不一致就会出现"跳过校验但
//     宏被定义成 1"的产物，且自证字段仍写着 none，事后无法反查。
for (const truthy of ['1', 'TRUE', 'true', 'YES', 'y', 'on', '00', '0.0', '-0', '2']) {
  run(`enabled via -D=${truthy} must fail closed`, baseCapabilities(),
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: truthy },
    expectFailure(/marks it approved=false/));
}

// 14. 明确的假值必须走默认路径，不得误报（否则默认构建会被门禁挡住）。
for (const falsy of ['OFF', '0', 'NO', 'FALSE', 'N', 'IGNORE', 'NOTFOUND']) {
  run(`disabled via -D=${falsy} stays on the default path`, baseCapabilities(),
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: falsy },
    expectSuccess(/PROBE_EVIDENCE=none/));
}

// 15. approved 必须是 JSON 布尔。字符串 "ON" 会被 string(JSON GET) 归一成 ON，
//     仅比较取值就分不清"真批准"和"写了个像布尔的字符串"，所以要查类型。
for (const bogus of ['ON', 'true', 1]) {
  const capabilities = baseCapabilities();
  capabilities.AMCL_GLFW_RAW_RELATIVE_VERIFIED =
    approved({ approved: bogus });
  run(`approved as ${JSON.stringify(bogus)} must be rejected`, capabilities,
    { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' },
    expectFailure(/must be a JSON boolean|marks it approved=false/));
}

// 16. 未知 schemaVersion：不得当成批准。
{
  const root = mkdtempSync(join(tmpdir(), 'amcl-gate0-cmake-'));
  try {
    write(root, 'gate0-evidence.lock',
      JSON.stringify({ schemaVersion: 99, capabilities: baseCapabilities() }));
    write(root, 'docs/testing/gate0-fixture.md', EVIDENCE_TEXT);
    writeProbeScript(root);
    const result = configure(root, { AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON' });
    if (!result.ok && /schemaVersion must be 1/.test(result.normalized)) {
      console.log('[test-gate0-evidence-cmake] PASS: unknown schemaVersion with option ON');
    } else {
      failures += 1;
      console.error('[test-gate0-evidence-cmake] FAIL: unknown schemaVersion did not fail closed');
      console.error(result.output.split('\n').slice(-20).join('\n'));
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// 17. 出货仓库的真实清单 + 全 OFF：确认 fixture 与出货配置没有分叉。
{
  const result = (() => {
    const root = mkdtempSync(join(tmpdir(), 'amcl-gate0-cmake-real-'));
    try {
      cpSync(join(repoRoot, 'gate0-evidence.lock'), join(root, 'gate0-evidence.lock'));
      writeProbeScript(root);
      // 真实清单目前三项全部未批准，因此打开任一项都必须失败。
      const enabled = configure(root, { AMCL_GLFW_NATIVE_ABSOLUTE_VERIFIED: 'ON' });
      const off = configure(root, {});
      return { enabled, off };
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  })();
  if (result.off.ok && /PROBE_EVIDENCE=none/.test(result.off.normalized) &&
      !result.enabled.ok && /approved=false/.test(result.enabled.normalized)) {
    console.log('[test-gate0-evidence-cmake] PASS: shipping manifest rejects enabling today');
  } else {
    failures += 1;
    console.error('[test-gate0-evidence-cmake] FAIL: shipping manifest behavior unexpected');
  }
}

if (failures > 0) {
  console.error(`[test-gate0-evidence-cmake] ${failures} case(s) failed`);
  process.exitCode = 1;
} else {
  console.log('[test-gate0-evidence-cmake] ALL PASS');
  console.log(`  cmake: ${cmake}`);
}

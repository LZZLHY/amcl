#!/usr/bin/env node
// check-product-identity-banner.mjs 的定向自测（正向 + 反向）。
//
// 为什么需要：这道门禁判定的三件事全是"不做也不会有任何信号"的东西，
// 因此门禁本身写错时同样没有信号 —— 它会变成一条恒绿的规则（`AGENTS.md` §二.8）。
// 这里用临时 fixture 树逐条证明：合法的树通过，而**每一种能让 banner 静默失效的写法
// 都必须被报出来**。

import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  validateProductIdentityBanner, parseProfileFields, parseIdentityFieldList,
  parseIdentityInterfaceFields, PRODUCT_PROFILE_FILES,
} from './check-product-identity-banner.mjs';

const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));

let failures = 0;
let checks = 0;
function check(name, fn) {
  checks += 1;
  try {
    fn();
  } catch (error) {
    failures += 1;
    console.error(`  FAIL  ${name}\n        ${error?.message ?? error}`);
  }
}
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function assertIssue(issues, needle, message) {
  assert(issues.some(i => i.includes(needle)),
    `${message}: no issue matching '${needle}' in ${JSON.stringify(issues, null, 1)}`);
}
function assertNoIssues(issues, message) {
  assert(issues.length === 0, `${message}: unexpected issues ${JSON.stringify(issues, null, 1)}`);
}

function write(root, path, content) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, 'utf8');
}

// fixture 复用**真实**的 ProductIdentity.ets 与 DiagnosticPolicy.ets：
// 断言必须打在出货文件上，否则自测只会验证一份复制品（与 test-check-gate0-evidence 同一理由）。
//
// ⚠️ 读进来先把行尾统一成 LF。2026-09-07 踩到过：`ProductIdentity.ets` 被工具链规范成
// CRLF 之后，下面那些内嵌 `\n` 的字符串替换**全部匹配不到** —— 而它们是用来"制造缺陷"的，
// 匹配不到就等于自测在验一份没被改坏的样本，**恒绿**。
// 这次是被 `assert(mutated !== original)` 那句守卫挡住的；行尾归一化是根治。
const readSourceLf = (relative) =>
  readFileSync(join(repoRoot, relative), 'utf8').replace(/\r\n/g, '\n');
const realIdentity = readSourceLf('commons/src/main/ets/common/ProductIdentity.ets');
const realPolicy = readSourceLf('commons/src/main/ets/common/DiagnosticPolicy.ets');

const PROFILE_FIELDS = [
  'product', 'family', 'storeChannel', 'publishable',
  'developerDiagnostics', 'touchControls', 'runtimeRawMouse',
];

function profileSource(fields = PROFILE_FIELDS) {
  const body = fields
    .map(f => `  static readonly ${f}: string = 'x'`)
    .join('\n');
  return `export class ProductBuildProfile {\n${body}\n}\n`;
}

const COLLECTOR_OK = `
import { DiagnosticPolicy } from 'commons';
export function collectProductIdentity() {
  return { capabilities: DiagnosticPolicy.resolvedCapabilities() };
}
`;

const ENTRY_OK = `
export default class EntryAbility {
  onCreate() {
    testNapi.amclLogInit(logDir, 1, 1);
    AppLogger.setNativeLogSink(new EntryNativeLogSink());
    AppLogger.info(TAG, formatProductIdentity(collectProductIdentity()), LOG_DOMAIN_LAUNCH);
  }
}
`;

/** 建一棵合法的最小 fixture 树；options 用来注入单点缺陷。 */
function buildFixture(options = {}) {
  const root = mkdtempSync(join(tmpdir(), 'amcl-identity-'));
  write(root, 'commons/src/main/ets/common/ProductIdentity.ets',
    options.identity ?? realIdentity);
  write(root, 'commons/src/main/ets/common/DiagnosticPolicy.ets',
    options.policy ?? realPolicy);
  write(root, 'entry/src/main/ets/product/ProductIdentityCollector.ets',
    options.collector ?? COLLECTOR_OK);
  write(root, 'entry/src/main/ets/entryability/EntryAbility.ets',
    options.entry ?? ENTRY_OK);
  const profiles = options.profiles ?? {};
  for (const relative of PRODUCT_PROFILE_FILES) {
    if (profiles[relative] === null) continue;   // 刻意不写这一条产品轨
    write(root, relative, profiles[relative] ?? profileSource());
  }
  return root;
}

function withFixture(options, fn) {
  const root = buildFixture(options);
  try {
    fn(validateProductIdentityBanner(root));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// ============================================================
//  解析器（先证明它们真的解析到了东西 —— 解析不到会让后面所有断言恒真）
// ============================================================

check('parseProfileFields 抽得到七个字段', () => {
  const fields = parseProfileFields(profileSource());
  assert(fields.length === PROFILE_FIELDS.length,
    `expected ${PROFILE_FIELDS.length} fields, got ${JSON.stringify(fields)}`);
});
check('parseProfileFields 反向：不是 profile 的文件抽不出字段', () => {
  assert(parseProfileFields('export class Foo { bar() {} }').length === 0, 'must be empty');
});
check('parseIdentityFieldList / parseIdentityInterfaceFields 在真实文件上一致', () => {
  const ordered = parseIdentityFieldList(realIdentity);
  const iface = parseIdentityInterfaceFields(realIdentity);
  assert(ordered !== null && ordered.length > 0, 'ordered list must parse');
  assert(iface !== null && iface.length > 0, 'interface must parse');
  assert(ordered.length === iface.length,
    `ordered(${ordered.length}) vs interface(${iface.length}) length mismatch`);
});

// ============================================================
//  正向
// ============================================================

check('正向：合法的树无 issue', () => {
  withFixture({}, issues => assertNoIssues(issues, 'healthy fixture'));
});

// ============================================================
//  反向 —— 每条对应一种静默失效
// ============================================================

check('反向：banner 排在 setNativeLogSink 之前必须被抓到（落盘窗口）', () => {
  const entryBad = `
export default class EntryAbility {
  onCreate() {
    AppLogger.info(TAG, formatProductIdentity(collectProductIdentity()), LOG_DOMAIN_LAUNCH);
    testNapi.amclLogInit(logDir, 1, 1);
    AppLogger.setNativeLogSink(new EntryNativeLogSink());
  }
}
`;
  withFixture({ entry: entryBad }, issues =>
    assertIssue(issues, 'BEFORE', 'banner before the sink'));
});

check('反向：banner 根本没发出必须被抓到', () => {
  const entryBad = `
export default class EntryAbility {
  onCreate() { AppLogger.setNativeLogSink(new EntryNativeLogSink()); }
}
`;
  withFixture({ entry: entryBad }, issues =>
    assertIssue(issues, 'not emitted', 'missing banner'));
});

check('反向：banner 有两个调用点必须被抓到（会各自漂移）', () => {
  const entryBad = ENTRY_OK.replace(
    'AppLogger.info(TAG, formatProductIdentity(collectProductIdentity()), LOG_DOMAIN_LAUNCH);',
    'AppLogger.info(TAG, formatProductIdentity(a), D);\n    AppLogger.info(TAG, formatProductIdentity(b), D);');
  withFixture({ entry: entryBad }, issues =>
    assertIssue(issues, 'emitted 2 times', 'duplicate call sites'));
});

check('反向：采集侧改读 native 掩码必须被抓到（非 default 产品会记下假能力位）', () => {
  const collectorBad = `
export function collectProductIdentity() {
  return { capabilities: testNapi.getDiagnosticCapabilities() };
}
`;
  withFixture({ collector: collectorBad }, issues => {
    assertIssue(issues, 'raw native mask', 'native mask read');
    assertIssue(issues, 'resolvedCapabilities', 'resolved source missing');
  });
});

check('反向：DiagnosticPolicy 去掉 resolvedCapabilities 必须被抓到', () => {
  const policyBad = realPolicy.replace(/static\s+resolvedCapabilities\s*\(/, 'static removedCapabilities(');
  assert(policyBad !== realPolicy, 'fixture mutation must actually change the text');
  withFixture({ policy: policyBad }, issues =>
    assertIssue(issues, 'single fact source', 'missing resolvedCapabilities'));
});

check('反向：产品轨新增字段但 banner 没跟上必须被抓到', () => {
  const profiles = {};
  profiles[PRODUCT_PROFILE_FILES[0]] = profileSource([...PROFILE_FIELDS, 'brandNewSwitch']);
  withFixture({ profiles }, issues => {
    assertIssue(issues, 'brandNewSwitch is not reported', 'uncovered profile field');
    assertIssue(issues, 'field set differs', 'track field-set drift');
  });
});

check('反向：某条产品轨的 profile 缺失必须被抓到（该轨会绕过门禁）', () => {
  const profiles = {};
  profiles[PRODUCT_PROFILE_FILES[3]] = null;
  withFixture({ profiles }, issues =>
    assertIssue(issues, 'escapes the gate', 'missing product track'));
});

check('反向：接口加了字段但有序清单没加必须被抓到', () => {
  const identityBad = realIdentity.replace(
    '  apiVersion: number;\n}',
    '  apiVersion: number;\n  newlyAddedField: string;\n}');
  assert(identityBad !== realIdentity, 'fixture mutation must actually change the text');
  withFixture({ identity: identityBad }, issues =>
    assertIssue(issues, 'not in PRODUCT_IDENTITY_FIELDS', 'interface/list drift'));
});

check('反向：有序清单列了接口没有的字段必须被抓到', () => {
  const identityBad = realIdentity.replace(
    "  'deviceModel', 'deviceBrand', 'osFullName', 'apiVersion',",
    "  'deviceModel', 'deviceBrand', 'osFullName', 'apiVersion', 'ghostField',");
  assert(identityBad !== realIdentity, 'fixture mutation must actually change the text');
  withFixture({ identity: identityBad }, issues =>
    assertIssue(issues, "'ghostField'", 'list/interface drift'));
});

check('反向：能力位字段被删必须被抓到', () => {
  const identityBad = realIdentity
    .replace("  'capabilities', 'developerBuild', 'testHooks', 'inputTrace',\n", '')
    .replace(/^\s*(capabilities: number;|developerBuild: boolean;|testHooks: boolean;|inputTrace: boolean;)$/gm, '');
  assert(identityBad !== realIdentity, 'fixture mutation must actually change the text');
  withFixture({ identity: identityBad }, issues =>
    assertIssue(issues, 'resolved diagnostic capabilities', 'capability fields removed'));
});

// ============================================================

console.log(`\n[test-check-product-identity-banner] ${checks - failures}/${checks} checks passed`);
if (failures > 0) {
  console.error(`[test-check-product-identity-banner] ${failures} FAILED`);
  process.exitCode = 1;
} else {
  console.log('[test-check-product-identity-banner] PASS');
}

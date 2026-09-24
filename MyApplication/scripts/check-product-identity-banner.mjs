#!/usr/bin/env node
// 产品身份 banner 的源码契约门禁（批次 D8）。
//
// 文档：docs/refactor/测试自动化方案.md §三.8
//       docs/guides/test-automation-contract.md §10.2（产品身份不进日志）
//
// 为什么需要它：这条 banner 的三种失效方式**全都是静默的** ——
//   1. 位置漂到 `setNativeLogSink` 之前 ⇒ 只进 hilog、不落盘（施工记录 §S03.3 的窗口），
//      日志里"看起来有"，拉回文件却没有；
//   2. 字段少一个 ⇒ 报告照常输出，只是再也回答不了那一问；
//   3. 采集侧改读 native 掩码而不是 `DiagnosticPolicy` 解析后的值 ⇒ 非 default 产品上
//      记下一个**假的**能力位（`AGENTS.md` §二.5：声明默认值与产品实际值是两个事实）。
// 三种都不会让任何构建失败。⇒ 把它们变成会失败的断言。
//
// ⚠️ 本门禁的边界（必须写下来，否则会被当成 G1 自检已成立）：
// 它是**源码级**的。`ProductBuildProfile` 每条产品轨各一份，本门禁只能断言
// "各产品的字段集合一致且被 banner 全覆盖"，**断言不了"出货包里读的是对的那一份"**——
// 那需要产物级反查（契约 §5.1 / 判据 G2），属 P2。`AGENTS.md` §二.4：
// 源码级门禁全绿不等于修复在出货链上。

import { readFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 当前产品轨的生成文件；每个产品必须被此门禁覆盖。 */
export const PRODUCT_PROFILE_FILES = [
  'entry/src/main/ProductBuildProfile.ets',
  'entry/src/desktop/ProductBuildProfile.ets',
  'entry/src/store/ProductBuildProfile.ets',
  'entry/src/sideload/ProductBuildProfile.ets',
];

const IDENTITY_FILE = 'commons/src/main/ets/common/ProductIdentity.ets';
const POLICY_FILE = 'commons/src/main/ets/common/DiagnosticPolicy.ets';
const COLLECTOR_FILE = 'entry/src/main/ets/product/ProductIdentityCollector.ets';
const ENTRY_ABILITY_FILE = 'entry/src/main/ets/entryability/EntryAbility.ets';

/** `DiagnosticPolicy` 解析后的三个谓词都必须进 banner，否则能力位只剩一个不可读的整数。 */
const REQUIRED_CAPABILITY_FIELDS = ['capabilities', 'developerBuild', 'testHooks', 'inputTrace'];

function read(root, relative) {
  const target = join(root, relative);
  if (!existsSync(target)) return null;
  return readFileSync(target, 'utf8');
}

/** 从生成的 ProductBuildProfile 里抽静态字段名。 */
export function parseProfileFields(text) {
  const fields = [];
  for (const match of (text ?? '').matchAll(/static\s+readonly\s+([A-Za-z_]\w*)\s*:/g)) {
    fields.push(match[1]);
  }
  return fields;
}

/** 抽 `PRODUCT_IDENTITY_FIELDS` 数组里的字段名（有序）。 */
export function parseIdentityFieldList(text) {
  const block = /PRODUCT_IDENTITY_FIELDS\s*:\s*string\[\]\s*=\s*\[([\s\S]*?)\]/.exec(text ?? '');
  if (!block) return null;
  return [...block[1].matchAll(/'([^']+)'/g)].map(m => m[1]);
}

/** 抽 `export interface ProductIdentity { … }` 的字段名。 */
export function parseIdentityInterfaceFields(text) {
  const block = /export\s+interface\s+ProductIdentity\s*\{([\s\S]*?)\n\}/.exec(text ?? '');
  if (!block) return null;
  const fields = [];
  for (const line of block[1].split('\n')) {
    const match = /^\s*([A-Za-z_]\w*)\s*:/.exec(line);
    if (match) fields.push(match[1]);
  }
  return fields;
}

export function validateProductIdentityBanner(root) {
  const issues = [];

  const identityText = read(root, IDENTITY_FILE);
  if (identityText === null) {
    issues.push(`${IDENTITY_FILE} is missing`);
    return issues;
  }

  const ordered = parseIdentityFieldList(identityText);
  if (ordered === null) {
    issues.push(`${IDENTITY_FILE}: cannot parse PRODUCT_IDENTITY_FIELDS`);
    return issues;
  }
  const interfaceFields = parseIdentityInterfaceFields(identityText);
  if (interfaceFields === null) {
    issues.push(`${IDENTITY_FILE}: cannot parse interface ProductIdentity`);
    return issues;
  }

  // 有序清单与接口必须**互相**覆盖：接口加了字段而清单没加 ⇒ 该字段永远不进 banner，
  // 且没有任何信号（这是本门禁最可能真正拦住的一次回归）。
  for (const field of interfaceFields) {
    if (!ordered.includes(field)) {
      issues.push(`ProductIdentity.${field} is in the interface but not in PRODUCT_IDENTITY_FIELDS`);
    }
  }
  for (const field of ordered) {
    if (!interfaceFields.includes(field)) {
      issues.push(`PRODUCT_IDENTITY_FIELDS lists '${field}', which is not a ProductIdentity field`);
    }
  }

  // 五条产品轨的字段集合必须一致，且全部被 banner 覆盖。
  let reference = null;
  for (const relative of PRODUCT_PROFILE_FILES) {
    const text = read(root, relative);
    if (text === null) {
      issues.push(`${relative} is missing (a product track without this file escapes the gate)`);
      continue;
    }
    const fields = parseProfileFields(text);
    if (fields.length === 0) {
      issues.push(`${relative}: no 'static readonly <name>:' fields parsed`);
      continue;
    }
    if (reference === null) {
      reference = { relative, fields };
    } else {
      const missing = reference.fields.filter(f => !fields.includes(f));
      const extra = fields.filter(f => !reference.fields.includes(f));
      if (missing.length > 0 || extra.length > 0) {
        issues.push(
          `${relative} field set differs from ${reference.relative} ` +
          `(missing: ${missing.join(',') || 'none'}; extra: ${extra.join(',') || 'none'})`);
      }
    }
    for (const field of fields) {
      if (!ordered.includes(field)) {
        issues.push(`${relative}.${field} is not reported by the product identity banner`);
      }
    }
  }

  for (const field of REQUIRED_CAPABILITY_FIELDS) {
    if (!ordered.includes(field)) {
      issues.push(`product identity banner must report '${field}' (resolved diagnostic capabilities)`);
    }
  }

  // 能力位必须有一个"解析后"的读取口，否则采集侧只能去读 native 掩码。
  const policyText = read(root, POLICY_FILE);
  if (policyText === null) {
    issues.push(`${POLICY_FILE} is missing`);
  } else if (!/static\s+resolvedCapabilities\s*\(/.test(policyText)) {
    issues.push(`${POLICY_FILE} must expose resolvedCapabilities() as the single fact source`);
  }

  // 采集侧必须读**解析后**的值，不得直接读 native 掩码。
  const collectorText = read(root, COLLECTOR_FILE);
  if (collectorText === null) {
    issues.push(`${COLLECTOR_FILE} is missing`);
  } else {
    if (!/DiagnosticPolicy\.resolvedCapabilities\s*\(/.test(collectorText)) {
      issues.push(`${COLLECTOR_FILE} must read DiagnosticPolicy.resolvedCapabilities()`);
    }
    if (/getDiagnosticCapabilities\s*\(/.test(collectorText)) {
      issues.push(
        `${COLLECTOR_FILE} reads the raw native mask (getDiagnosticCapabilities); ` +
        'the banner must record the DiagnosticPolicy-resolved value, which differs on ' +
        'non-developer products');
    }
  }

  // ⭐ 顺序：banner 必须在 setNativeLogSink 之后，否则它落进"只进 hilog"的窗口。
  const entryText = read(root, ENTRY_ABILITY_FILE);
  if (entryText === null) {
    issues.push(`${ENTRY_ABILITY_FILE} is missing`);
  } else {
    const sinkAt = entryText.indexOf('AppLogger.setNativeLogSink(');
    const bannerMatches = [...entryText.matchAll(/formatProductIdentity\s*\(/g)];
    if (sinkAt < 0) {
      issues.push(`${ENTRY_ABILITY_FILE}: cannot find AppLogger.setNativeLogSink( — gate cannot judge order`);
    } else if (bannerMatches.length === 0) {
      issues.push(`${ENTRY_ABILITY_FILE}: product identity banner is not emitted`);
    } else {
      if (bannerMatches.length > 1) {
        issues.push(
          `${ENTRY_ABILITY_FILE}: product identity banner is emitted ${bannerMatches.length} times; ` +
          'multiple call sites drift apart');
      }
      if (bannerMatches[0].index < sinkAt) {
        issues.push(
          `${ENTRY_ABILITY_FILE}: product identity banner is emitted BEFORE ` +
          'AppLogger.setNativeLogSink() — it would only reach hilog and never the log file ' +
          '(see 施工记录 §S03.3)');
      }
    }
  }

  return issues;
}

const invokedDirectly = process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) {
  const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
  const issues = validateProductIdentityBanner(root);
  if (issues.length > 0) {
    for (const issue of issues) console.error(`[check-product-identity-banner] ${issue}`);
    process.exitCode = 1;
  } else {
    const fields = parseIdentityFieldList(readFileSync(join(root, IDENTITY_FILE), 'utf8'));
    console.log('[check-product-identity-banner] PASS');
    console.log(`  banner fields: ${fields.length}; product tracks covered: ${PRODUCT_PROFILE_FILES.length}`);
    console.log('  checked here: field-set agreement (interface / ordered list / ' + PRODUCT_PROFILE_FILES.length + ' tracks),');
    console.log('                resolved-capability source, banner emitted once, after setNativeLogSink');
    // 只陈述本脚本实际验证过的事：出货包里读的是哪一份 profile 要产物级反查（P2）。
    console.log('  NOT checked here: which profile the shipped HAP actually compiled in (needs G2 artifact audit)');
  }
}

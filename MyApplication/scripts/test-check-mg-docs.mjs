#!/usr/bin/env node

import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { validateMgDocs } from './check-mg-docs.mjs';

function write(root, path, content) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, 'utf8');
}

function expectIssue(root, pattern, label) {
  const issues = validateMgDocs(root);
  if (!issues.some(issue => pattern.test(issue))) {
    throw new Error(`${label}: expected issue not found; got ${issues.join(' | ')}`);
  }
  console.log(`[test-check-mg-docs] PASS: ${label}`);
}

const root = mkdtempSync(join(tmpdir(), 'amcl-mg-docs-'));
try {
  // Fixture-local heads, deliberately not the ones the real deps.lock pins: the
  // gate must derive them from the lock it is handed, so a self-test carrying
  // the production values would keep passing after the two drifted apart.
  const fixtureSourceHead = 'a'.repeat(40);
  const fixtureForkHead = 'b'.repeat(40);
  const authority = '# MobileGlues\n\n唯一权威文档\n' +
    `${fixtureSourceHead}\n` +
    `${fixtureForkHead}\n`;
  const evidence = '不是第二份 MG 基线权威文档；见 mobileglues-2.0-ohos-governance.md。\n' +
    '设备证据见 mobileglues-ohos-device-validation-runbook.md。\n' +
    '`--hap-kind` 始终必需，`--hap` 只指定文件；toolchain.lock 固定工具链。\n';
  const performance = '不得写“性能等同 Android”；未执行项标为 NOT VERIFIED。\n' +
    '见 mobileglues-ohos-device-validation-runbook.md。\n';
  const deviceValidation = 'NOT_VERIFIED / NO-GO。型号不能代替能力；查询 default display。\n' +
    'IMG-01 CFG-04 FR-01 FR-06 SURF-01 PERF-01。\n' +
    'mobileglues-ohos-device-capability-matrix.csv\n' +
    'mobileglues-ohos-validation-results.csv\n';
  const capabilityTemplate =
    'schema_version,candidate_id,device_id,mg_official_tree,cap_display_change_event,evidence_path,notes\n';
  const resultsTemplate =
    'schema_version,candidate_id,device_id,test_case_id,scheduler_cap_hz,game_fps_limit,evidence_path,notes\n';
  const templatesReadme = '不包含任何预设 PASS；缺失写 NOT_VERIFIED，失败写 QUERY_FAILED。\n';
  const stub = '# MOVED — ARCHIVED\n\n../archive/mobileglues/report.md\n';
  const archive = '> [!CAUTION]\n> **ARCHIVED** historical evidence.\n';
  const lock = `[mobileglues]\n${[
    'source_tree', 'android_renderer_commit',
    'android_plugin_commit', 'release_tag', 'release_commit', 'fork_release_tag',
  ].map(field => `${field} = fixture`).join('\n')}\n` +
    `source_main_commit = ${fixtureSourceHead}\ncommit = ${fixtureForkHead}\n`;

  write(root, 'docs/guides/mobileglues-2.0-ohos-governance.md', authority);
  write(root, 'docs/guides/mobileglues-release-evidence.md', evidence);
  write(root, 'docs/guides/mobileglues-ohos-performance-validation.md', performance);
  write(root, 'docs/guides/mobileglues-ohos-device-validation-runbook.md', deviceValidation);
  write(root, 'docs/testing/templates/mobileglues-ohos-device-capability-matrix.csv',
    capabilityTemplate);
  write(root, 'docs/testing/templates/mobileglues-ohos-validation-results.csv',
    resultsTemplate);
  write(root, 'docs/testing/templates/README.md', templatesReadme);
  write(root, 'docs/release-process.md',
    '# 先形成不可变源码提交，再构建\n\n当前硬阻塞\n\nbuild-app.ps1 app-product-provenance.json 商店发布资格仍需核对\n' +
    'mg-device-validation mobileglues-ohos-device-validation-runbook.md\n');
  write(root, 'docs/release-checklist.md',
    'fork_release_tag toolchain.lock 根目录 `@build-profile.json5` ' +
    'mobileglues-ohos-device-validation-runbook.md docs/testing/templates/\n');
  write(root, 'docs/README.md',
    'guides/mobileglues-2.0-ohos-governance.md\n' +
    'guides/mobileglues-ohos-device-validation-runbook.md\n' +
    'testing/templates/README.md\n');
  write(root, 'docs/self-inspection/2026-08-02_MG_Maleoon渲染性能排查.md', stub);
  write(root, 'docs/archive/mobileglues/2026-08-02_MG_Maleoon渲染性能排查.md', archive);
  write(root, 'docs/guides/mc-launch-fbo-crash-2026-05-16.md',
    '# incident\n\n> [!CAUTION]\n> **HISTORICAL**; mobileglues-2.0-ohos-governance.md\n');
  write(root, 'deps.lock', lock);
  write(root, 'toolchain.lock', JSON.stringify({
    schemaVersion: 1,
    compiler: { sha256: 'a'.repeat(64) },
    hapSignTool: { sha256: 'b'.repeat(64) },
  }));
  write(root, '.github/CODEOWNERS', [
    '/docs/guides/mobileglues-ohos-device-validation-runbook.md @owner',
    '/docs/testing/templates/mobileglues-ohos-* @owner',
    '/entry/src/main/ets/pages/tabs/SettingsTab.ets @owner',
    '/feature_system/src/main/ets/PreferenceManager.ets @owner',
  ].join('\n') + '\n');
  write(root, 'scripts/check-mg-docs.mjs', 'fixture\n');
  write(root, 'scripts/test-check-mg-docs.mjs', 'fixture\n');

  const baseline = validateMgDocs(root);
  if (baseline.length) throw new Error(`valid fixture failed: ${baseline.join(' | ')}`);
  console.log('[test-check-mg-docs] PASS: coherent authority/archive fixture');

  const keyedRecord = {
    compiler: { sha256: 'c'.repeat(64) },
    hapSignTool: { sha256: 'd'.repeat(64) },
  };
  const keyedProducts = Object.fromEntries(
    ['default', 'store', 'sideload', 'desktop']
      .map(product => [product, structuredClone(keyedRecord)]),
  );
  write(root, 'toolchain.lock', JSON.stringify({ schemaVersion: 2, products: keyedProducts }));
  const keyedBaseline = validateMgDocs(root);
  if (keyedBaseline.length) {
    throw new Error(`valid product-keyed lock fixture failed: ${keyedBaseline.join(' | ')}`);
  }
  console.log('[test-check-mg-docs] PASS: product-keyed toolchain lock is accepted');

  delete keyedProducts.desktop;
  write(root, 'toolchain.lock', JSON.stringify({ schemaVersion: 2, products: keyedProducts }));
  expectIssue(root, /key every shipping product/, 'product-keyed lock cannot omit formal desktop');
  write(root, 'toolchain.lock', JSON.stringify({
    schemaVersion: 1,
    compiler: { sha256: 'a'.repeat(64) },
    hapSignTool: { sha256: 'b'.repeat(64) },
  }));

  write(root, 'docs/release-checklist.md', 'android_release_commit = stale\n');
  expectIssue(root, /retired MobileGlues lock field/, 'retired lock field is rejected');
  write(root, 'docs/release-checklist.md',
    'fork_release_tag toolchain.lock 根目录 `@build-profile.json5` ' +
    'mobileglues-ohos-device-validation-runbook.md docs/testing/templates/\n');

  write(root, 'docs/guides/mobileglues-release-evidence.md',
    '不是第二份 MG 基线权威文档；mobileglues-2.0-ohos-governance.md；' +
    'mobileglues-ohos-device-validation-runbook.md；`--hap-kind` 或 `--hap`。\n');
  expectIssue(root, /replace mandatory --hap-kind/, 'artifact-kind ambiguity is rejected');

  write(root, 'docs/guides/mobileglues-release-evidence.md', evidence);
  write(root, 'docs/testing/templates/mobileglues-ohos-device-capability-matrix.csv',
    capabilityTemplate + '1,candidate,device,tree,SUPPORTED,evidence,do-not-prefill\n');
  expectIssue(root, /must remain one empty/, 'prefilled capability template is rejected');
  write(root, 'docs/testing/templates/mobileglues-ohos-device-capability-matrix.csv',
    capabilityTemplate);

  write(root, 'docs/archive/mobileglues/2026-08-02_MG_Maleoon渲染性能排查.md',
    '# old report without warning\n');
  expectIssue(root, /lacks a leading ARCHIVED warning/, 'unmarked archive is rejected');
  write(root, 'docs/archive/mobileglues/2026-08-02_MG_Maleoon渲染性能排查.md', archive);

  // The authority document has to name the heads deps.lock pins. This is the
  // case that the previous hardcoded-hash version of the check could not have:
  // it compared the document against constants in the gate, so a lock that had
  // moved on read as the document being wrong, and a document that had moved on
  // with the lock read as both being wrong.
  write(root, 'docs/guides/mobileglues-2.0-ohos-governance.md',
    '# MobileGlues\n\n唯一权威文档\n' + `${fixtureSourceHead}\n` + `${'c'.repeat(40)}\n`);
  expectIssue(root, /source\/fork heads pinned by deps\.lock/, 'fork head drift is rejected');
  write(root, 'docs/guides/mobileglues-2.0-ohos-governance.md', authority);

  // And the lock itself must carry both as real object names; a placeholder
  // there would make the comparison above vacuous.
  write(root, 'deps.lock', '[mobileglues]\nsource_main_commit = fixture\ncommit = fixture\n');
  expectIssue(root, /does not expose source_main_commit and commit/, 'placeholder lock heads are rejected');
  write(root, 'deps.lock', lock);
} finally {
  rmSync(root, { recursive: true, force: true });
}

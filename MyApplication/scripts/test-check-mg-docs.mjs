#!/usr/bin/env node

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
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

const root = mkdtempSync(join(workspaceTempRoot(), 'amcl-mg-docs-'));
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
    '`--hap-kind` 始终必需，`--hap` 只指定文件；toolchain.lock 固定工具链。\n' +
    '本机 `build-profile.json5` 只用于签名配置。\n';
  const performance = '不得写“性能等同 Android”；未执行项标为 NOT VERIFIED。\n' +
    '见 mobileglues-ohos-device-validation-runbook.md。\n';
  const deviceValidation = 'NOT_VERIFIED / NO-GO。型号不能代替能力；查询 default display。\n' +
    'IMG-01 CFG-04 FR-01 FR-06 SURF-01 PERF-01。\n' +
    'mg-device-validation/<candidate-id>/\n' +
    'mobileglues-ohos-device-capability-matrix.csv\n' +
    'mobileglues-ohos-validation-results.csv\n';
  const capabilityTemplate =
    'schema_version,candidate_id,device_id,mg_official_tree,cap_display_change_event,evidence_path,notes\n';
  const resultsTemplate =
    'schema_version,candidate_id,device_id,test_case_id,scheduler_cap_hz,game_fps_limit,evidence_path,notes\n';
  const templatesReadme = '不包含任何预设 PASS；缺失写 NOT_VERIFIED，失败写 QUERY_FAILED。\n';
  const stub = '# MOVED — ARCHIVED\n\n../archive/mobileglues/report.md\n';
  const archive = '> [!CAUTION]\n> **ARCHIVED** historical evidence.\n';
  const releaseProcessPath = 'docs/release-process.md';
  const releaseChecklistPath = 'docs/release-checklist.md';
  const releaseProcess = '# 发行流程\n\n`amcl-release`。[发布清单](release-checklist.md)\n' +
    '从干净的精确生产提交执行 full/-Release。[构建证据](guides/mobileglues-release-evidence.md)\n' +
    '## AGC 上架\n\n`build-app.ps1 -Release` 生成 `signed.app` 和 `app-product-provenance.json`。\n' +
    'APP 内 HAP 与审计产物逐文件绑定，并验证 APP 签名。构建证据不代替商店资格。\n';
  const releaseChecklist = '# 发行清单\n\n`amcl-release`。[发布流程](release-process.md)\n';
  const index = 'guides/mobileglues-2.0-ohos-governance.md\n' +
    'guides/mobileglues-ohos-device-validation-runbook.md\n' +
    'testing/templates/README.md\n';
  const rootSigningIgnore = '/build-profile.json5\n';
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
  write(root, releaseProcessPath, releaseProcess);
  write(root, releaseChecklistPath, releaseChecklist);
  write(root, 'docs/README.md', index);
  write(root, '.gitignore', rootSigningIgnore);
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

  write(root, releaseChecklistPath, releaseChecklist + 'android_release_commit = stale\n');
  expectIssue(root, /retired MobileGlues lock field/, 'retired lock field is rejected');
  write(root, releaseChecklistPath, releaseChecklist);

  write(root, 'docs/README.md', index.replace('testing/templates/README.md\n', ''));
  expectIssue(root, /does not index the MG device-validation runbook\/templates/, 'device evidence index remains required');
  write(root, 'docs/README.md', index);

  for (const [missing, pattern] of [
    ['`amcl-release`', /amcl-release authority/],
    ['干净的精确生产提交', /clean production source/],
    ['逐文件绑定', /bind the audited APP/],
    ['app-product-provenance.json', /bind the audited APP/],
    ['不代替商店资格', /market eligibility separate/],
  ]) {
    write(root, releaseProcessPath, releaseProcess.replace(missing, ''));
    expectIssue(root, pattern, `missing release contract ${missing}`);
    write(root, releaseProcessPath, releaseProcess);
  }
  write(root, '.gitignore', '/entry/build-profile.json5\n');
  expectIssue(root, /root signing profile must stay ignored/, 'module ignore does not protect the root signing profile');
  write(root, '.gitignore', rootSigningIgnore);

  write(root, 'deps.lock', lock.replace('fork_release_tag = fixture\n', '') + '[other]\nfork_release_tag = fixture\n');
  expectIssue(root, /\[mobileglues\] is missing current field fork_release_tag/, 'fork tag must be locked in the MobileGlues section');
  write(root, 'deps.lock', lock);

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

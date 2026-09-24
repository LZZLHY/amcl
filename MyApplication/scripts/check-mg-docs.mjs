#!/usr/bin/env node
// Fail-closed guard against stale MobileGlues guidance escaping the archive.

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));

function posix(path) {
  return path.split(sep).join('/');
}

function markdownFiles(directory) {
  if (!existsSync(directory)) return [];
  const result = [];
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    const info = statSync(path);
    if (info.isDirectory()) result.push(...markdownFiles(path));
    else if (info.isFile() && name.endsWith('.md')) result.push(path);
  }
  return result;
}

function requireFile(root, relativePath, issues) {
  const path = join(root, relativePath);
  if (!existsSync(path)) {
    issues.push(`missing required documentation path: ${relativePath}`);
    return '';
  }
  return readFileSync(path, 'utf8');
}

export function validateMgDocs(root = DEFAULT_ROOT) {
  const issues = [];
  const authorityPath = 'docs/guides/mobileglues-2.0-ohos-governance.md';
  const evidencePath = 'docs/guides/mobileglues-release-evidence.md';
  const performancePath = 'docs/guides/mobileglues-ohos-performance-validation.md';
  const deviceValidationPath =
    'docs/guides/mobileglues-ohos-device-validation-runbook.md';
  const capabilityTemplatePath =
    'docs/testing/templates/mobileglues-ohos-device-capability-matrix.csv';
  const resultsTemplatePath =
    'docs/testing/templates/mobileglues-ohos-validation-results.csv';
  const stubPath = 'docs/self-inspection/2026-08-02_MG_Maleoon渲染性能排查.md';
  const archivePath = 'docs/archive/mobileglues/2026-08-02_MG_Maleoon渲染性能排查.md';

  const authority = requireFile(root, authorityPath, issues);
  const evidence = requireFile(root, evidencePath, issues);
  const performance = requireFile(root, performancePath, issues);
  const deviceValidation = requireFile(root, deviceValidationPath, issues);
  const capabilityTemplate = requireFile(root, capabilityTemplatePath, issues);
  const resultsTemplate = requireFile(root, resultsTemplatePath, issues);
  const templatesReadme = requireFile(
    root, 'docs/testing/templates/README.md', issues);
  const releaseProcess = requireFile(root, 'docs/release-process.md', issues);
  const releaseChecklist = requireFile(root, 'docs/release-checklist.md', issues);
  const index = requireFile(root, 'docs/README.md', issues);
  const stub = requireFile(root, stubPath, issues);
  const archive = requireFile(root, archivePath, issues);
  const historicalFbo = requireFile(
    root, 'docs/guides/mc-launch-fbo-crash-2026-05-16.md', issues);
  const lock = requireFile(root, 'deps.lock', issues);
  const toolchainLock = requireFile(root, 'toolchain.lock', issues);
  const codeowners = requireFile(root, '.github/CODEOWNERS', issues);
  requireFile(root, 'scripts/check-mg-docs.mjs', issues);
  requireFile(root, 'scripts/test-check-mg-docs.mjs', issues);

  // The two heads are read out of deps.lock rather than hardcoded here. A copy
  // in this script would be a second statement of the same fact: updating the
  // pin and the document would leave the gate asserting the old value, so it
  // would fail on a correct tree and pass on a tree where lock and document had
  // drifted apart -- the exact inversion of what it is for.
  const mgSection = lock.split(/^\[/m).find((part) => part.startsWith('mobileglues]')) ?? '';
  const mgSourceHead = /^source_main_commit\s*=\s*([0-9a-f]{40})\b/m.exec(mgSection)?.[1] ?? '';
  const mgForkHead = /^commit\s*=\s*([0-9a-f]{40})\b/m.exec(mgSection)?.[1] ?? '';
  if (!mgSourceHead || !mgForkHead) {
    issues.push('deps.lock [mobileglues] does not expose source_main_commit and commit as 40-hex heads');
  } else if (!/唯一权威文档/.test(authority) || !authority.includes(mgSourceHead) ||
      !authority.includes(mgForkHead)) {
    issues.push(`${authorityPath} is missing authority markers or the source/fork heads pinned by deps.lock`);
  }
  if (!index.includes('guides/mobileglues-2.0-ohos-governance.md')) {
    issues.push('docs/README.md does not index the MG authority document');
  }
  if (!index.includes('guides/mobileglues-ohos-device-validation-runbook.md') ||
      !index.includes('testing/templates/README.md')) {
    issues.push('docs/README.md does not index the MG device-validation runbook/templates');
  }
  if (!/不是第二份 MG 基线权威文档/.test(evidence) ||
      !evidence.includes('mobileglues-2.0-ohos-governance.md') ||
      !evidence.includes('mobileglues-ohos-device-validation-runbook.md')) {
    issues.push(`${evidencePath} does not defer baseline authority`);
  }
  if (/--hap-kind`?\s*(?:或|or)\s*`?--hap/i.test(evidence)) {
    issues.push(`${evidencePath} incorrectly allows --hap to replace mandatory --hap-kind`);
  }
  if (/三个\s*product/.test(evidence) || !evidence.includes('toolchain.lock')) {
    issues.push(`${evidencePath} has a stale product count or omits the toolchain lock`);
  }
  if (!/不得写[“"]性能等同 Android[”"]/.test(performance) || !/NOT VERIFIED/.test(performance)) {
    issues.push(`${performancePath} does not separate measured evidence from build parity`);
  }
  if (!performance.includes('mobileglues-ohos-device-validation-runbook.md') ||
      /当前应用层尚未把游戏 FPS 设置接到|没有动态刷新率监听器/.test(performance)) {
    issues.push(`${performancePath} is not linked to the current cap/display validation contract`);
  }
  if (!/NOT_VERIFIED/.test(deviceValidation) ||
      !/FR-01/.test(deviceValidation) || !/FR-06/.test(deviceValidation) ||
      !/IMG-01/.test(deviceValidation) || !/CFG-04/.test(deviceValidation) ||
      !/SURF-01/.test(deviceValidation) || !/PERF-01/.test(deviceValidation) ||
      !/default display/.test(deviceValidation) || !/型号.*能力/.test(deviceValidation) ||
      !/NO-GO/.test(deviceValidation) ||
      !deviceValidation.includes('mobileglues-ohos-device-capability-matrix.csv') ||
      !deviceValidation.includes('mobileglues-ohos-validation-results.csv')) {
    issues.push(`${deviceValidationPath} is missing capability/status/test/evidence contracts`);
  }
  const capabilityHeader = capabilityTemplate.trim().split(/\r?\n/);
  if (capabilityHeader.length !== 1 ||
      !capabilityHeader[0].startsWith('schema_version,candidate_id,device_id,') ||
      !capabilityHeader[0].includes('cap_display_change_event') ||
      !capabilityHeader[0].includes('mg_official_tree') ||
      !capabilityHeader[0].endsWith('evidence_path,notes')) {
    issues.push(`${capabilityTemplatePath} must remain one empty, identity-bound template header`);
  }
  const resultsHeader = resultsTemplate.trim().split(/\r?\n/);
  if (resultsHeader.length !== 1 ||
      !resultsHeader[0].startsWith('schema_version,candidate_id,device_id,test_case_id,') ||
      !resultsHeader[0].includes('scheduler_cap_hz') ||
      !resultsHeader[0].includes('game_fps_limit') ||
      !resultsHeader[0].endsWith('evidence_path,notes')) {
    issues.push(`${resultsTemplatePath} must remain one empty, per-run evidence template header`);
  }
  if (!/不包含任何预设 PASS/.test(templatesReadme) ||
      !templatesReadme.includes('NOT_VERIFIED') ||
      !templatesReadme.includes('QUERY_FAILED')) {
    issues.push('MG device-validation template README permits ambiguous or prefilled results');
  }
  if (!/MOVED[\s\S]*ARCHIVED/.test(stub) || stub.length > 2_048 ||
      !stub.includes('../archive/mobileglues/')) {
    issues.push(`${stubPath} must remain a short archived-link compatibility stub`);
  }
  if (!/^> \[!CAUTION\][\s\S]{0,300}ARCHIVED/.test(archive)) {
    issues.push(`${archivePath} lacks a leading ARCHIVED warning`);
  }
  if (!/^# .*\n\n> \[!CAUTION\][\s\S]{0,500}HISTORICAL/.test(historicalFbo) ||
      !historicalFbo.includes('mobileglues-2.0-ohos-governance.md')) {
    issues.push('dated MG FBO incident guide lacks a leading historical-only warning');
  }
  if (!releaseProcess.includes('先形成不可变源码提交，再构建') ||
      !releaseProcess.includes('当前硬阻塞') ||
      !releaseProcess.includes('build-app.ps1') ||
      !releaseProcess.includes('app-product-provenance.json') ||
      !releaseProcess.includes('商店发布资格仍需核对') ||
      !releaseProcess.includes('mg-device-validation') ||
      !releaseProcess.includes('mobileglues-ohos-device-validation-runbook.md')) {
    issues.push('release-process.md must require clean source, audited APP binding and separate market eligibility');
  }
  if (!releaseChecklist.includes('fork_release_tag') ||
      !releaseChecklist.includes('toolchain.lock') ||
      !releaseChecklist.includes('根目录 `@build-profile.json5`') ||
      !releaseChecklist.includes('mobileglues-ohos-device-validation-runbook.md') ||
      !releaseChecklist.includes('docs/testing/templates/')) {
    issues.push('release-checklist.md omits the MG release tag, toolchain lock or root signing profile');
  }
  if (/git check-ignore\s+entry\/build-profile\.json5/.test(releaseChecklist) ||
      /obfuscation\.enable:\s*false/.test(releaseChecklist)) {
    issues.push('release-checklist.md contains retired signing-profile or obfuscation guidance');
  }
  for (const ownedPath of [
    '/docs/guides/mobileglues-ohos-device-validation-runbook.md',
    '/docs/testing/templates/mobileglues-ohos-*',
    '/entry/src/main/ets/pages/tabs/SettingsTab.ets',
    '/feature_system/src/main/ets/PreferenceManager.ets',
  ]) {
    if (!codeowners.includes(ownedPath)) {
      issues.push(`.github/CODEOWNERS omits MG runtime/evidence surface ${ownedPath}`);
    }
  }
  try {
    const parsedToolchain = JSON.parse(toolchainLock);
    let records = [];
    if (parsedToolchain.schemaVersion === 1) {
      // Retain compatibility with the original single-product lock shape.
      records = [parsedToolchain];
    } else if (parsedToolchain.schemaVersion === 2) {
      const requiredProducts = ['default', 'store', 'sideload', 'desktop'];
      const products = parsedToolchain.products;
      if (!products || typeof products !== 'object' || Array.isArray(products) ||
          requiredProducts.some(product => !products[product])) {
        issues.push('toolchain.lock schemaVersion=2 must key every shipping product');
      } else {
        records = requiredProducts.map(product => products[product]);
      }
    } else {
      issues.push('toolchain.lock is missing schema or immutable compiler/verifier hashes');
    }
    if (records.some(record =>
      !/^[0-9a-f]{64}$/.test(record?.compiler?.sha256 ?? '') ||
      !/^[0-9a-f]{64}$/.test(record?.hapSignTool?.sha256 ?? ''))) {
      issues.push('toolchain.lock is missing schema or immutable compiler/verifier hashes');
    }
  } catch (error) {
    issues.push(`toolchain.lock is invalid JSON: ${error.message}`);
  }

  for (const field of ['source_main_commit', 'source_tree', 'android_renderer_commit',
    'android_plugin_commit', 'release_tag', 'release_commit', 'fork_release_tag']) {
    if (!new RegExp(`^${field}\\s*=`, 'm').test(lock)) {
      issues.push(`deps.lock [mobileglues] is missing current field ${field}`);
    }
  }

  const docsRoot = join(root, 'docs');
  for (const path of markdownFiles(docsRoot)) {
    const rel = posix(relative(root, path));
    if (rel.startsWith('docs/archive/') || rel === 'docs/CHANGELOG.md') continue;
    const text = readFileSync(path, 'utf8');
    for (const stale of [
      /\bandroid_release_commit\b/,
      /\bupstream_release\s*=/,
    ]) {
      if (stale.test(text)) issues.push(`${rel} contains retired MobileGlues lock field ${stale}`);
    }
  }
  return issues;
}

function main() {
  const rootArg = process.argv.find(arg => arg.startsWith('--root='));
  const root = rootArg ? resolve(rootArg.slice('--root='.length)) : DEFAULT_ROOT;
  const issues = validateMgDocs(root);
  if (issues.length) {
    for (const issue of issues) console.error(`[check-mg-docs] ERROR: ${issue}`);
    process.exitCode = 1;
    return;
  }
  console.log('[check-mg-docs] PASS');
  console.log('  authority: MobileGlues 2.0/OHOS governance indexed; release/perf/device docs defer');
  console.log('  device evidence: capability and per-run CSV templates are empty, identity-bound contracts');
  console.log('  archive: MG 1.3.5 diagnosis is marked and active docs use current lock fields');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();

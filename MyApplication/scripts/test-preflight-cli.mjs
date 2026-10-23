/** 以真实 CLI 验证只读计划、严格拒绝、仓外收据与缺工具状态；不运行整套预检。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { workspacePath } from './lib/workspace-paths.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const entry = path.join(root, 'scripts/preflight.mjs');
const outputParent = workspacePath('run', 'preflight-cli-tests');
fs.mkdirSync(outputParent, { recursive: true });
const output = fs.mkdtempSync(path.join(outputParent, 'cases-'));
console.error(`Preflight CLI fixture output: ${output}`);

function invoke(args, env = process.env) {
  const result = spawnSync(process.execPath, [entry, ...args], { cwd: root, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.signal, null, result.stderr);
  return { ...result, receipt: JSON.parse(result.stdout) };
}

test('真实完整计划列出原检查及依赖，不调用任何门函数', () => {
  const report = path.join(output, 'all-plan.json');
  const result = invoke(['--plan', '--json', '--report', report]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.receipt.status, 'PLANNED');
  assert.equal(result.receipt.ok, null);
  assert.deepEqual(result.receipt.coverage.executedIds, []);
  assert.ok(result.receipt.coverage.registeredIds.includes('runtime-foundation'));
  assert.ok(result.receipt.coverage.registeredIds.includes('download-system'));
  assert.ok(result.receipt.coverage.registeredIds.includes('workspace-layout'));
  assert.equal(result.receipt.executionOrder.length, result.receipt.coverage.registeredIds.length);
  assert.deepEqual(result.receipt.checks.find(row => row.id === 'java-tests').dependencies, ['java-build']);
  assert.deepEqual(JSON.parse(fs.readFileSync(report, 'utf8')), result.receipt);
});

test('真实 java-tests 选择计划补齐编译，不运行旧 class', () => {
  const result = invoke(['--only=java-tests', '--plan', '--json']);
  assert.equal(result.status, 0);
  assert.deepEqual(result.receipt.executionOrder, ['java-build', 'java-tests']);
  assert.deepEqual(result.receipt.coverage.dependencyAddedIds, ['java-build']);
  assert.deepEqual(result.receipt.coverage.executedIds, []);
});

test('拼错 only/skip、未知参数和全排除均返回失败且零执行', () => {
  const plan = invoke(['--plan', '--json']).receipt;
  for (const args of [
    ['--only=java-test-typo'], ['--skip=missing'], ['--strict'],
    ['--skip=java-build'], [`--skip=${plan.coverage.registeredIds.join(',')}`],
  ]) {
    const result = invoke([...args, '--json']);
    assert.notEqual(result.status, 0, args.join(' '));
    assert.equal(result.receipt.status, 'CONFIGURATION_FAILED');
    assert.deepEqual(result.receipt.coverage.executedIds, []);
    assert.equal(result.receipt.coverage.complete, false);
  }
});

test('选择失败仍可写仓外 JSON；同名收据和仓内路径均在门执行前拒绝', () => {
  const failedReport = path.join(output, 'unknown-plan.json');
  const failed = invoke(['--only=missing', '--json', '--report', failedReport]);
  assert.notEqual(failed.status, 0);
  assert.equal(JSON.parse(fs.readFileSync(failedReport, 'utf8')).error.code, 'UNKNOWN_GATE');
  const sentinel = path.join(output, 'existing.json');
  fs.writeFileSync(sentinel, 'original-receipt', { flag: 'wx' });
  const existing = invoke(['--only=lf-eol', '--json', '--report', sentinel]);
  assert.notEqual(existing.status, 0);
  assert.deepEqual(existing.receipt.coverage.executedIds, []);
  assert.equal(fs.readFileSync(sentinel, 'utf8'), 'original-receipt');
  const inside = invoke(['--plan', '--json', '--report', path.join(root, 'forbidden-preflight-report.json')]);
  assert.notEqual(inside.status, 0);
  assert.deepEqual(inside.receipt.coverage.executedIds, []);
  assert.equal(inside.receipt.coverage.complete, false);
});

test('真实 bash-syntax 缺工具分支报告 SKIPPED 并非 PASS，且退出失败', () => {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => key.toLowerCase() !== 'path'));
  env.PATH = '';
  const result = invoke(['--only=bash-syntax', '--json', '--report', path.join(output, 'missing-bash.json')], env);
  assert.notEqual(result.status, 0);
  assert.equal(result.receipt.status, 'FAILED');
  assert.deepEqual(result.receipt.coverage.skippedIds, ['bash-syntax']);
  assert.deepEqual(result.receipt.coverage.passedIds, []);
  assert.deepEqual(result.receipt.coverage.executedIds, []);
  assert.equal(result.receipt.checks.find(row => row.id === 'bash-syntax').reason, 'MISSING_TOOL');
});

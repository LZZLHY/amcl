/** 用当前真实日志及定向错误验证检查器；临时 CLI 输入成功后由既有生命周期工具回收。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { createHostTestScope } from './lib/host-test-lifecycle.mjs';
import { checkDevelopmentChangelog as check, LABELS, DUPLICATE_RECORDS } from './check-dev-changelog.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const original = fs.readFileSync(path.join(root, 'docs/CHANGELOG.md'), 'utf8');
const lines = original.split(/\r?\n/);
const first = lines.find(line => /^\|\s*\d{7}\s*\|/.test(line));
const max = Math.max(...lines.filter(line => /^\|\s*\d{7}\s*\|/.test(line)).map(line => Number(line.split('|')[1])));
const time = first.split('|')[2].trim();
const row = (id, description = '[修复] **模块：纠正真实错误。**') => `| ${id} | ${time} | ${description} | scripts/example.mjs | Test |`;
const insert = added => original.replace(first, added + '\n' + first);
const rejects = (text, code) => {
  const result = check(text);
  assert.equal(result.ok, false, '真实错误未被拒绝');
  assert.ok(result.errors.some(error => error.code === code), JSON.stringify(result.errors));
};

test('当前真实历史、四条撞号、三条单标签补记和新增工具行可共同通过', () => {
  const result = check(original);
  assert.equal(result.ok, true, JSON.stringify(result.errors));
  assert.equal(result.historicalDuplicateRows, 4);
  assert.ok(result.checkedLabels >= 4);
});

test('七种主类型都接受，旧标签继续兼容', () => {
  for (const label of LABELS) assert.equal(check(insert(row(max + 1, `[${label}] **模块：一个独立成果。**`))).ok, true);
  const legacy = lines.find(line => line.startsWith('| 1001022 |'));
  assert.equal(check(original.replace(legacy, legacy.replace('[改进]', '[历史标签]'))).ok, true);
});

test('多标签、组合标签、同义新标签和缺少加粗标题均拒绝', () => {
  for (const prefix of ['[修复][优化]', '[修复] [优化]', '[修复+优化]', '[修复/优化]', '[改进]', '[补记]']) {
    rejects(insert(row(max + 1, prefix + ' **模块：混杂标签。**')), 'SINGLE_LABEL');
  }
  rejects(insert(row(max + 1, '[修复] 没有加粗标题')), 'SINGLE_LABEL');
});

test('两项独立成果可以使用同一时间戳，编号各自唯一', () => {
  assert.equal(check(insert(row(max + 2, '[新增] **下载：新增入口。**') + '\n' +
    row(max + 1, '[修复] **输入：纠正释放错误。**'))).ok, true);
});

test('新增重复编号、倒序错误和旧号段空隙插入均拒绝', () => {
  rejects(insert(row(max)), 'DUPLICATE_ID');
  rejects(original.replace(first, first + '\n' + row(max + 1)), 'ORDER');
  rejects(insert(row(1001016)), 'HISTORICAL_IDENTITY');
});

test('四条历史例外不是整号豁免，不能删行、改时间或添第三条', () => {
  const old = lines.find(line => line.startsWith('| 1000516 | 2026-08-22 23:39:12 |'));
  rejects(original.replace(old, ''), 'HISTORICAL_IDENTITY');
  rejects(original.replace(old, old.replace('23:39:12', '23:39:13')), 'HISTORICAL_IDENTITY');
  rejects(insert(row(1000516)), 'DUPLICATE_ID');
});

test('原退役删除线和内容丢失占位保留，新行不能借相同标记绕过校验', () => {
  rejects(original.replace('~~1000413~~', '~~1000412~~'), 'HISTORICAL_ANNOTATION');
  rejects(original.replace('1000458 / 1000457', '1000458 / 1000456'), 'HISTORICAL_ANNOTATION');
  rejects(insert(row(max + 1).replace(String(max + 1), `~~${max + 1}~~`)), 'HISTORICAL_ANNOTATION');
});

test('锚点缺失、重复、对调或引用缺失目标均拒绝', () => {
  const a = DUPLICATE_RECORDS[0].anchor, b = DUPLICATE_RECORDS[1].anchor;
  const marker = `<a id="${a}"></a>`;
  rejects(original.replace(marker, ''), 'HISTORICAL_ANCHOR');
  rejects(original.replace(marker, marker + marker), 'HISTORICAL_ANCHOR');
  rejects(original.replace(marker, '<a id="temporary-swap"></a>')
    .replace(`<a id="${b}"></a>`, marker).replace('id="temporary-swap"', `id="${b}"`), 'HISTORICAL_ANCHOR');
  rejects(original.replace(`](#${a})`, '](#cl-missing)'), 'BROKEN_REFERENCE');
});

test('新行必须属于版本五列表，转义竖线不增加列数', () => {
  rejects(row(max + 1) + '\n' + original, 'VERSION_REQUIRED');
  rejects(insert(row(max + 1).replace('| Test |', '|')), 'FIVE_COLUMNS');
  rejects(insert(row(max + 1, '[修复] **模块：裸 | 会新增一列。**')), 'FIVE_COLUMNS');
  assert.equal(check(insert(row(max + 1, '[修复] **模块：转义 \\| 保留在正文。**'))).ok, true);
});

test('编号后缀、过短编号、缺时区和空关联字段不能被解析器跳过', () => {
  rejects(insert(row(max + 1).replace(String(max + 1), `${max + 1}a`)), 'INVALID_ID');
  rejects(insert(row(42)), 'INVALID_ID');
  rejects(insert(row(max + 1).replace(time, '2026-11-15 03:40:05')), 'TIMESTAMP');
  rejects(insert(row(max + 1).replace('scripts/example.mjs', '')), 'EMPTY_FIELD');
});

test('代码围栏内示例不算功能行，未闭合围栏仍拒绝', () => {
  assert.equal(check(original + '\n```markdown\n' + row(max) + '\n```\n').ok, true);
  rejects(original + '\n```markdown\n', 'UNCLOSED_FENCE');
});

test('真实 CLI 成功与失败退出码可靠，参数和读失败不会成为 PASS', () => {
  const scope = createHostTestScope('dev-changelog-');
  const fixture = path.join(scope.directory, 'CHANGELOG.md');
  const script = path.join(root, 'scripts/check-dev-changelog.mjs');
  const invoke = args => spawnSync(process.execPath, [script, ...args], { cwd: root, encoding: 'utf8' });
  fs.writeFileSync(fixture, original);
  const good = invoke(['--file', fixture, '--json']);
  assert.equal(good.status, 0, good.stderr);
  assert.equal(JSON.parse(good.stdout).ok, true);
  fs.writeFileSync(fixture, insert(row(max + 1, '[修复][新增] **不允许。**')));
  const bad = invoke(['--file', fixture, '--json']);
  assert.equal(bad.status, 1);
  assert.equal(JSON.parse(bad.stdout).ok, false);
  for (const args of [['--unknown'], ['--file'], ['--file', path.join(scope.directory, 'absent.md')]]) {
    assert.equal(invoke(args).status, 1);
  }
});

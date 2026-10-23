/**
 * 使用 PowerShell 自身 AST 核对真实入口分支，而不执行任何应用门禁。
 * 旧调用清单只能证明文本保留；本测试补上可达性：quick/full 必须是同一个顶层
 * if/else，旧完整流程不能被放进 quick-only 条件或未调用函数。负控直接改入口文本。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {test} from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'build-hap.ps1'), 'utf8').replace(/\r\n/g, '\n');
const candidates = [process.env.AMCL_POWERSHELL, 'pwsh', ...(process.platform === 'win32' ?
  [path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe')] : [])].filter(Boolean);
const powershell = candidates.find(file => spawnSync(file, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'],
  {encoding:'utf8', timeout:10000}).stdout?.trim() === '7');
if (!powershell) throw new Error('PowerShell 7 is required for dispatch AST verification');

/** 从 stdin 解析真实语法，只提取顶层 try 的直接 if；不执行其命令或载入项目脚本。 */
function branches(text) {
  const result = spawnSync(powershell, ['-NoProfile', '-NonInteractive', '-Command', `
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
    $main=@($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
    if($main.Count -ne 1){throw 'one top-level try required'}
    $split=@($main[0].Body.Statements | Where-Object {$_ -is [System.Management.Automation.Language.IfStatementAst]})
    if($split.Count -ne 1 -or $split[0].Clauses.Count -ne 1 -or !$split[0].ElseClause){throw 'one direct if/else required'}
    @{condition=$split[0].Clauses[0].Item1.Extent.Text;quick=$split[0].Clauses[0].Item2.Extent.Text;full=$split[0].ElseClause.Extent.Text}|ConvertTo-Json -Compress
  `], {input:text, encoding:'utf8', timeout:10000});
  if (result.error || result.status !== 0) throw new Error(result.stderr || result.error?.message);
  return JSON.parse(result.stdout.replace(/^\uFEFF/, ''));
}

/** full 的关键实际调用必须位于分支正文，且没有被隐藏在额外函数或整体条件里。 */
function check(text) {
  const b = branches(text);
  assert.equal(b.condition, "$ValidationProfile -eq 'quick'");
  assert.match(b.quick, /& \$Hvigorw assembleHap/);
  assert.match(b.quick, /scripts\\check-quick-hap\.mjs/);
  for (const name of ['test-sideload-update.mjs', 'check-product-tu-syntax.mjs', 'test-update-dialog-sdk-runtime.mjs',
    'Clear-AmclProductIntermediates', '--write-provenance', '--verify-provenance', '& $Hvigorw test']) {
    assert.ok(b.full.includes(name), 'full missing '+name);
    assert.ok(!b.quick.includes(name), 'quick unexpectedly runs '+name);
  }
  assert.doesNotMatch(b.full, /function\s+[\w-]+\s*\{/i, 'full gates cannot be hidden in an uncalled function');
  assert.doesNotMatch(b.quick, /snapshot|last-full|Invoke-AmclPython|test-[\w-]+\.mjs/);
}

test('真实 quick/full 分派保留完整门禁可达性，quick 不运行回归、单测或 TU', () => check(source));
test('把完整门禁误放进 quick-only 分支必须失败', () => {
  assert.throws(() => check(source.replace("if ($ValidationProfile -eq 'quick') {\n    # 普通", "if ($ValidationProfile -eq 'full') {\n    # 普通")));
});
test('把完整门禁藏进未调用函数必须失败', () => {
  assert.throws(() => check(source.replace('# full 原有门禁整体保留', 'function UncalledFull {\n# full 原有门禁整体保留')
    .replace('$ValidationSucceeded = $true\n}\n} catch', '$ValidationSucceeded = $true\n}\n}\n} catch')));
});

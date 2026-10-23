/**
 * 构建入口完整性回归，只读取目录、基线和入口文本，不运行任何实际业务门禁。
 *
 * 正向校验固定旧调用在包装器归一后仍按原顺序存在，覆盖 foreach、动态参数数组、
 * preflight 回调、Hvigor task 与 CI 内联脚本。负向样本直接撤回当前真实输入中的一项，
 * 证明删除成员、调序、注释伪装或放宽产物缓存不能被静态目录掩盖。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { stripComments, stripStringLiterals } from './lib/source-noise.mjs';
import { exportGateInventory, readGateCatalog, gateCatalogIssues, normalizePowerShellWitness,
  findUnregisteredHapScripts, findUnregisteredCurrentEntryScripts } from './lib/build-gate-inventory.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const baseline = JSON.parse(fs.readFileSync(path.join(ROOT, 'config/build-gate-baseline.json'), 'utf8'));
const catalog = readGateCatalog({ root: ROOT });
const sources = Object.fromEntries(baseline.sourceFiles.map(item => [item.path,
  fs.readFileSync(path.join(ROOT, item.path), 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n')]));
const normalizeJs = text => stripComments(text).replace(/\s+/g, ' ').trim();
const normalizeText = text => text.replace(/\s+/g, ' ').trim();

/**
 * 使用既有共享词法器抹白字符串、正则与注释后配对调用括号，避免把注释或字符串中
 * 的 add('x') 误当实际注册。这里只读取 add 回调，不执行它，也不依赖 TypeScript 安装。
 */
function registeredGroups(text) {
  const code = stripComments(text), skeleton = stripStringLiterals(code);
  const groups = new Map();
  for (const match of code.matchAll(/\badd\s*\(\s*(['"])([^'"]+)\1\s*,/g)) {
    if (!/^add\b/.test(skeleton.slice(match.index))) continue;
    const open = code.indexOf('(', match.index);
    let depth = 0, end = -1;
    for (let index = open; index < skeleton.length; index++) {
      if (skeleton[index] === '(') depth++;
      if (skeleton[index] === ')' && --depth === 0) { end = index + 1; break; }
    }
    if (end < 0) throw new Error(`preflight 注册未闭合：${match[2]}`);
    if (groups.has(match[2])) throw new Error(`preflight 重复注册：${match[2]}`);
    groups.set(match[2], code.slice(match.index, end));
  }
  return groups;
}

/** 检查完整性；返回所有问题供正向断言和定向撤回样本共同使用。 */
function inventoryIssues({ currentCatalog = catalog, currentSources = sources } = {}) {
  const issues = [...gateCatalogIssues(currentCatalog)];
  const gates = new Map(currentCatalog.gates.map(gate => [gate.script, gate]));
  for (const script of baseline.catalogScripts) {
    if (!gates.has(script)) issues.push(`遗漏目录脚本：${script}`);
  }
  const allowedCache = new Set(baseline.pureCacheAllowlist);
  for (const gate of currentCatalog.gates) {
    if (gate.cachePolicy === 'pass' && !allowedCache.has(gate.script)) issues.push(`未批准的缓存：${gate.script}`);
    if (gate.kind === 'artifact' && (gate.cachePolicy !== 'never' || gate.quick !== 'always')) issues.push(`产物门被减弱：${gate.script}`);
  }
  for (const row of baseline.powershellCalls) {
    for (const script of row.scripts) {
      const gate = gates.get(script);
      if (!gate) continue;
      const artifactArguments = /--hap\b|--require-artifact\b|--verify-signature\b|--write-provenance\b|--verify-provenance\b/;
      if (artifactArguments.test(row.text + row.argumentBindings.join('\n')) &&
          (gate.kind !== 'artifact' || gate.quick !== 'always' || gate.cachePolicy !== 'never')) {
        issues.push(`动态产物调用未保持 always/never：${row.id}/${script}`);
      }
    }
  }
  // 原调用作为每个入口的有序子序列；允许新增计时和基础设施回归，不能删除或调换旧调用。
  const cursors = new Map();
  for (const row of baseline.powershellCalls) {
    const actual = normalizePowerShellWitness(currentSources[row.source]);
    let expected = normalizePowerShellWitness(row.text);
    const adapter = baseline.approvedWitnessAdapters.find(item => item.callsite === row.id);
    if (adapter && actual.includes(normalizePowerShellWitness(adapter.invocation))) {
      expected = normalizePowerShellWitness(adapter.invocation);
      for (const fragment of adapter.required) {
        if (!actual.includes(normalizePowerShellWitness(fragment))) issues.push(`验证档透传改变原参数：${row.id}`);
      }
    }
    const cursor = cursors.get(row.source) ?? 0;
    const position = actual.indexOf(expected, cursor);
    if (position < 0) issues.push(`旧调用遗漏或调序：${row.id} ${expected}`);
    else cursors.set(row.source, position + expected.length);
    for (const context of row.contexts) {
      const required = normalizePowerShellWitness(context.kind === 'foreach' ? context.values : context.expression);
      if (!actual.includes(required)) issues.push(`条件或foreach成员缺失：${row.id} ${required}`);
    }
    for (const binding of [...row.argumentBindings, ...(row.selectorWitness ? [row.selectorWitness] : [])]) {
      if (!actual.includes(normalizePowerShellWitness(binding))) issues.push(`动态参数绑定缺失：${row.id}`);
    }
  }
  for (const guard of baseline.inlineGuardWitnesses) {
    const ps = guard.source.endsWith('.ps1');
    const normalize = ps ? normalizePowerShellWitness : normalizeJs;
    const actual = normalize(currentSources[guard.source]);
    for (const fragment of guard.required) {
      if (!actual.includes(normalize(fragment))) issues.push(`入口内联约束缺失：${guard.source}: ${fragment}`);
    }
  }
  const groups = registeredGroups(currentSources['scripts/preflight.mjs']);
  for (const group of baseline.preflightGroups) {
    const current = groups.get(group.id);
    if (!current) { issues.push(`preflight组缺失：${group.id}`); continue; }
    const actual = normalizeJs(current);
    let cursor = 0;
    // 按原 callback 各行比对有序子序列，允许其他已存在任务插入新门禁。
    for (const line of stripComments(group.body).split('\n')) {
      let expected = normalizeText(line);
      if (!expected) continue;
      if (group.id === 'bash-syntax' && expected.includes("summary: 'bash not available, skipped'")) {
        expected = "return { ok: false, status: 'SKIPPED', reason: 'MISSING_TOOL', missingTools: ['bash'], summary: 'bash not available; syntax checks were not executed' };";
      }
      const position = actual.indexOf(expected, cursor);
      if (position < 0) { issues.push(`preflight原回调缺失：${group.id}: ${expected}`); break; }
      cursor = position + expected.length;
    }
  }
  for (const task of baseline.hvigorTasks) {
    const actual = normalizeJs(currentSources[task.source]);
    let cursor = 0;
    for (const line of stripComments(task.body).split('\n')) {
      const expected = normalizeText(line);
      if (!expected) continue;
      const position = actual.indexOf(expected, cursor);
      if (position < 0) { issues.push(`Hvigor任务或前后依赖缺失：${task.id}: ${expected}`); break; }
      cursor = position + expected.length;
    }
  }
  const ci = normalizeText(currentSources['.github/workflows/ci.yml']);
  let ciCursor = 0;
  for (const step of baseline.ciSteps) {
    const name = normalizeText(`- name: ${step.name}`);
    const position = ci.indexOf(name, ciCursor);
    if (position < 0) { issues.push(`CI步骤缺失或调序：${step.id}`); continue; }
    ciCursor = position + name.length;
    let cursor = ciCursor;
    for (const line of (step.run ?? '').split('\n')) {
      if (!line.trim() || line.trimStart().startsWith('#')) continue;
      const required = normalizeText(line), next = ci.indexOf(required, cursor);
      if (next < 0) { issues.push(`CI内联门禁缺失：${step.id}: ${required}`); break; }
      cursor = next + required.length;
    }
    if (step.uses && !ci.includes(`uses: ${step.uses}`)) issues.push(`CI工具来源缺失：${step.id}`);
  }
  return issues;
}

test('实际入口与catalog保留完整基线；只导出清单而不执行gate', () => {
  assert.equal(baseline.schema, 1);
  assert.equal(baseline.sourceCommit, '8ee89d352c13bfb40db9e92773578af3f454b67b');
  assert.equal(baseline.preflightGroups.length, 42);
  assert.equal(baseline.hvigorTasks.length, 5);
  const issues = inventoryIssues();
  assert.deepEqual(issues, [], issues.join('\n'));
  assert.deepEqual(findUnregisteredCurrentEntryScripts({ catalog,
    preflightSource: sources['scripts/preflight.mjs'], ciSource: sources['.github/workflows/ci.yml'] }), [],
  '当前preflight/CI新增显式脚本也必须登记，不能只满足8ee旧调用见证');
  const inventory = exportGateInventory({ catalog });
  assert.equal(inventory.length, catalog.gates.length);
  inventory[0].id = 'local-mutation';
  assert.notEqual(exportGateInventory({ catalog })[0].id, 'local-mutation');
});

test('删除foreach的真实成员会被拒绝', () => {
  const modified = { ...sources, 'build-hap.ps1': sources['build-hap.ps1'].replace("'test-control-groups-editor.mjs',", '') };
  assert(inventoryIssues({ currentSources: modified }).some(issue => issue.includes('foreach成员缺失')));
});

test('交换旧调用、删除命令或只留墓碑注释均不能覆盖原门禁', () => {
  const first = baseline.powershellCalls.find(row => row.text.includes('test-sideload-update.mjs'));
  const second = baseline.powershellCalls.find(row => row.text.includes('test-sideload-recovery.mjs'));
  const currentFirst = first.text.replace('& node', 'Invoke-AmclNode');
  const currentSecond = second.text.replace('& node', 'Invoke-AmclNode');
  const input = sources['build-hap.ps1'];
  const switched = input.replace(currentFirst, '__FIRST_GATE__').replace(currentSecond, currentFirst).replace('__FIRST_GATE__', currentSecond);
  assert(inventoryIssues({ currentSources: { ...sources, 'build-hap.ps1': switched } }).some(issue => issue.includes('遗漏或调序')));
  const commented = input.replace(currentFirst, '# ' + currentFirst);
  assert(inventoryIssues({ currentSources: { ...sources, 'build-hap.ps1': commented } }).some(issue => issue.includes('遗漏或调序')));
});

test('最终HAP/动态provenance不能退化为可缓存或可延期检查', () => {
  const changed = structuredClone(catalog);
  const gate = changed.gates.find(item => item.script === 'scripts/check-diagnostics-contract.mjs');
  gate.kind = 'static'; gate.cachePolicy = 'pass'; gate.quick = 'affected'; gate.deterministic = true;
  gate.inputs = { files: [gate.script] };
  const issues = inventoryIssues({ currentCatalog: changed });
  assert(issues.some(issue => issue.includes('动态产物调用')));
  assert(issues.some(issue => issue.includes('未批准的缓存')));
});

test('目录漏项、重复ID与依赖环均被拒绝', () => {
  const missing = structuredClone(catalog);
  missing.gates = missing.gates.filter(gate => gate.script !== 'scripts/test-control-groups-editor.mjs');
  assert(inventoryIssues({ currentCatalog: missing }).some(issue => issue.includes('遗漏目录脚本')));
  const duplicate = structuredClone(catalog); duplicate.gates.push(structuredClone(duplicate.gates[0]));
  assert(gateCatalogIssues(duplicate).some(issue => issue.includes('重复')));
  const cycle = structuredClone(catalog); cycle.gates[0].dependsOn = [cycle.gates[1].id]; cycle.gates[1].dependsOn = [cycle.gates[0].id];
  assert(gateCatalogIssues(cycle).some(issue => issue.includes('依赖环')));
});

test('清单审计发现未知静态脚本，注释不能制造未知命令；普通quick不运行该审计', () => {
  assert.deepEqual(findUnregisteredHapScripts({ catalog, source: sources['build-hap.ps1'] }), []);
  const added = sources['build-hap.ps1'] + '\nInvoke-AmclNode "$ProjectRoot\\scripts\\test-unregistered-safety.mjs"\n';
  assert.deepEqual(findUnregisteredHapScripts({ catalog, source: added }), ['scripts/test-unregistered-safety.mjs']);
  assert.deepEqual(findUnregisteredHapScripts({ catalog, source: 'Invoke-AmclNode "$ProjectRoot\\scripts\\arbitrary-audit.mjs"' }), ['scripts/arbitrary-audit.mjs']);
  assert.deepEqual(findUnregisteredHapScripts({ catalog, source: sources['build-hap.ps1'] + '\n# node scripts/test-unregistered-safety.mjs\n' }), []);
});

test('原preflight组、Hvigor依赖与CI内联判据都有独立撤回反控', () => {
  const preflight = sources['scripts/preflight.mjs'].replace("add('input-runtime'", "add('removed-input-runtime'");
  assert(inventoryIssues({ currentSources: { ...sources, 'scripts/preflight.mjs': preflight } }).some(issue => issue.includes('preflight组缺失')));
  const hook = sources['entry/hvigorfile.ts'].replace("dependencies: ['prepareProductArtifact']", "dependencies: []");
  assert(inventoryIssues({ currentSources: { ...sources, 'entry/hvigorfile.ts': hook } }).some(issue => issue.includes('Hvigor任务')));
  const ci = sources['.github/workflows/ci.yml'].replace('test -f feature_core/src/main/ets/modloader/ForgelikeInstaller.ets', 'true # removed actual file assertion');
  assert(inventoryIssues({ currentSources: { ...sources, '.github/workflows/ci.yml': ci } }).some(issue => issue.includes('CI内联门禁')));
});

test('当前preflight/CI新增漏项被拒绝，注释/env/lib helper不冒充gate调用', () => {
  // 新SDK测试在主仓与8ee编排投影中均为真实CI调用；撤回登记必须立即暴露漏项。
  const withoutSdkTest = structuredClone(catalog);
  withoutSdkTest.gates = withoutSdkTest.gates.filter(gate => gate.script !== 'scripts/test-sdk-build-inputs.mjs');
  const currentMissing = findUnregisteredCurrentEntryScripts({ catalog: withoutSdkTest,
    preflightSource: sources['scripts/preflight.mjs'], ciSource: sources['.github/workflows/ci.yml'] });
  assert(currentMissing.some(row => row.source === '.github/workflows/ci.yml' &&
    row.script === 'scripts/test-sdk-build-inputs.mjs' && row.evidence === 'explicit-interpreter-command'));
  const preflightSource = `
// add('old', () => spawn('node', ['scripts/test-dead-comment.mjs']));
const helper = 'scripts/lib/not-a-gate.mjs';
const gates = ['scripts/test-current-preflight-missing.mjs'];
`;
  const ciSource = `jobs:
  fixture:
    steps:
      - name: not a run
        env:
          NOTE: node scripts/test-env-is-not-call.mjs
        # run: node scripts/test-yaml-comment.mjs
      - name: current calls
        run: |
          # node scripts/test-shell-comment.mjs
          node scripts/test-current-ci-missing.mjs # python scripts/test-tail-comment.py
          files=(scripts/test-current-table-a.mjs scripts/test-current-table-b.py)
          for script in "\${files[@]}"; do
            python "$script"
          done
`;
  const missing = findUnregisteredCurrentEntryScripts({ catalog, preflightSource, ciSource });
  assert.deepEqual(missing.map(row => row.script).sort(), [
    'scripts/test-current-preflight-missing.mjs', 'scripts/test-current-ci-missing.mjs',
    'scripts/test-current-table-a.mjs', 'scripts/test-current-table-b.py'].sort());
  assert(missing.every(row => row.line > 0));
  const commentsOnly = findUnregisteredCurrentEntryScripts({ catalog,
    preflightSource: '// "scripts/test-removed.mjs"\n', ciSource: 'jobs:\n  x:\n    # run: node scripts/test-removed.mjs\n' });
  assert.deepEqual(commentsOnly, []);
});

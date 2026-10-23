/**
 * 恢复调度工作量回归：直接执行真实Coordinator、账本及文件边界，观察queue发布和目录/清单IO。
 * 8/32/128规模只用于结构计数，不以Node墙钟时间冒充HarmonyOS启动性能。旧分支反控通过
 * 保存的生产方法与SHA-256做AST机械替换，不重写恢复、后继界限或队列提交算法。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const coordinatorPath = 'launch/src/main/ets/SessionRecoveryCoordinator.ets';
const ledgerPath = 'commons/src/main/ets/utils/ActivityLedger.ets';
const legacy = JSON.parse(fs.readFileSync(new URL('./fixtures/session-recovery-scheduling-legacy.json', import.meta.url), 'utf8'));
assert.equal(legacy.schemaVersion, 1);
assert.equal(legacy.sourcePath, coordinatorPath);
assert.equal(legacy.sourceSha256, 'dc953abc924e0d671e26cac55cc75ca1d123daeeacc46b15c30181ab782bb33c');
for (const method of legacy.methods) {
  assert.equal(createHash('sha256').update(method.originalMethod).digest('hex'), method.sha256,
    '反控只使用已保存且摘要匹配的完整旧生产方法');
}

/** 编译器AST仅定位边界；替换的语义逐字来自正式旧源码样本。 */
function withLegacyMethods(source, names) {
  const ast = compiler.createSourceFile(coordinatorPath, source, compiler.ScriptTarget.Latest, true);
  const component = ast.statements.find(node => node.name?.text === 'SessionRecoveryCoordinator');
  assert.ok(component?.members, '必须定位真实生产Coordinator');
  const changes = names.map(name => {
    const member = component.members.find(node => node.name?.text === name && node.body);
    const original = legacy.methods.find(method => method.name === name);
    assert.ok(member && original, name);
    return { start: member.getStart(ast), end: member.end, text: original.originalMethod };
  }).sort((left, right) => right.start - left.start);
  for (const change of changes) source = source.slice(0, change.start) + change.text + source.slice(change.end);
  // 旧recover方法调用原公共后继API；新源码移除该import后反控仍使用真实实现，不造类型桩。
  const imported = ast.statements.some(node => compiler.isImportDeclaration(node)
    && node.moduleSpecifier?.text === 'commons'
    && node.importClause?.namedBindings?.elements?.some(entry => entry.name?.text === 'ledgerNextLaunchAtAsync'));
  if (names.includes('recover_') && !imported) source = "import { ledgerNextLaunchAtAsync } from 'commons';\n" + source;
  return source;
}

/** 正式单局begin/end建立末态和原始元数据；规模创建阶段不计入被测冷调度IO。 */
function fixture(size, oldMethods = []) {
  const runtime = evidenceRuntime({ transform: (absolute, source) => absolute.endsWith('SessionRecoveryCoordinator.ets')
    && oldMethods.length > 0 ? withLegacyMethods(source, oldMethods) : source });
  const ledger = runtime.load(ledgerPath);
  // 单局提交必须真实空闲；持续batch hold隔离保留维护，不以“状态未知”挡住被测commit。
  ledger.configureLedgerMaintenanceOwner(true, () => true);
  ledger.ledgerBeginMaintenanceBatch(runtime.directory);
  ledger.setLedgerProcessRunNonce('scheduling-test');
  const first = Date.now() - 20000;
  const ids = Array.from({ length: size }, (_, index) => first + index * 10);
  for (const id of ids) {
    assert.equal(ledger.ledgerBegin(runtime.directory, id, { category: 'launch', title: 'fixture-' + id,
      gameVersionId: 'fixture-version', mcDir: '/fixture-game' }), true);
    // 明确人工终态排除全文正文成本，完整prepare/commit仍由生产方法执行。
    ledger.ledgerEnd(runtime.directory, id, { state: ledger.LedgerState.SUCCESS,
      source: 'scheduling.fixture', summary: 'completed fixture' });
  }
  const Coordinator = runtime.load(coordinatorPath).SessionRecoveryCoordinator;
  const history = new Map();
  const owner = new Coordinator(runtime.directory, { isIdle: () => true,
    applyHistory: async result => { history.set(result.session.startedAt, result); }, changed() {} });
  const counts = { queuePublishes: 0, ledgerEnumerations: 0, ledgerChildStats: 0, manifestReads: 0 };
  const enumerationOrigins = [];
  const rename = runtime.kitFs.rename, list = runtime.kitFs.listFile, stat = runtime.kitFs.lstat, read = runtime.kitFs.readText;
  runtime.kitFs.rename = async (from, to) => {
    const result = await rename(from, to);
    if (to === runtime.directory + '/logs/recovery/queue.json') counts.queuePublishes++;
    return result;
  };
  runtime.kitFs.listFile = async path => {
    if (path === runtime.directory + '/logs/ledger') {
      counts.ledgerEnumerations++;
      if (enumerationOrigins.length < 3) enumerationOrigins.push(new Error().stack.split('\n').slice(2, 6).join('\n'));
    }
    return list(path);
  };
  runtime.kitFs.lstat = async path => {
    if (new RegExp('[/]logs[/]ledger[/][1-9][0-9]*$').test(path)) counts.ledgerChildStats++;
    return stat(path);
  };
  runtime.kitFs.readText = async path => { if (path.endsWith('/manifest.json')) counts.manifestReads++; return read(path); };
  const clearCounts = () => { for (const key of Object.keys(counts)) counts[key] = 0; enumerationOrigins.length = 0; };
  return { runtime, ledger, owner, ids, history, counts, clearCounts, enumerationOrigins,
    async close() {
      // 生产维护可能由observer排队；先撤销其资格，再等待已发起工作，最后删除隔离夹具。
      ledger.configureLedgerMaintenanceOwner(false);
      await ledger.ledgerEndMaintenanceBatchAsync(runtime.directory);
      await ledger.ledgerFlushMaintenanceAsync(runtime.directory);
      runtime.close();
    } };
}

for (const size of [8, 32, 128]) {
  test('真实bootstrap ' + size + '局按16项批游标发布；旧完整方法逐局发布反控成立', async () => {
    const measured = [];
    for (const oldMethods of [[], ['bootstrap_']]) {
      const f = fixture(size, oldMethods);
      try {
        await f.owner.initialize();
        const old = oldMethods.length > 0;
        const expected = old ? size + 2 : Math.ceil(size / 16) + 2;
        assert.equal(f.counts.queuePublishes, expected, '计数来自真实queue原子rename，包含首尾两次发布');
        assert.equal(f.counts.ledgerEnumerations, 1, '初始化仅一次全根身份发现');
        assert.equal(f.counts.ledgerChildStats, size, '只有一次按目录验证身份');
        assert.ok(f.counts.manifestReads <= 2 * size, '初始化metadata读取不得出现R平方');
        const queue = JSON.parse(fs.readFileSync(f.runtime.directory + '/logs/recovery/queue.json', 'utf8'));
        assert.equal(queue.pendingIds.length, size); assert.equal(queue.bootstrapCursor, 0); assert.deepEqual(queue.bootstrapIds, []);
        measured.push({ size, old, ...f.counts });
      } finally { await f.close(); }
    }
    console.info(JSON.stringify({ scenario: 'production-bootstrap-queue-io', measured }));
  });
}

test('真实128局后继lookup零全根扫描；旧recover完整方法额外产生128次枚举与16384次目录属性反控', async () => {
  const measured = [];
  for (const oldMethods of [[], ['recover_']]) {
    const f = fixture(128, oldMethods);
    try {
      await f.owner.initialize(); f.clearCounts();
      // 只调用真实单局recover，隔离平台发现与批末维护；方法依然实际写原件清单/状态/历史。
      for (const id of f.ids) {
        const manifest = await f.ledger.ledgerManifestAsync(f.runtime.directory, id);
        await f.owner.recover_(manifest);
      }
      const old = oldMethods.length > 0;
      assert.equal(f.counts.ledgerEnumerations, old ? 128 : 0, '全根枚举真实来源：\n' + f.enumerationOrigins.join('\n'));
      // 单局提交仍可lstat本局目录。比较原函数额外工作，不能将合法的单局校验误报全局扫描。
      if (!old) assert.ok(f.counts.ledgerChildStats <= 2 * 128, '本局目录校验只随R线性增长');
      else {
        assert.equal(f.counts.ledgerChildStats - measured[0].ledgerChildStats, 128 * 128);
        assert.equal(f.counts.manifestReads - measured[0].manifestReads, 128 * 127 / 2,
          '旧后继查找额外读取每条更晚launch的原manifest，反控必须实际触发R平方工作');
      }
      assert.equal(f.history.size, 128, '成本优化不能漏掉任何真实活动投影');
      assert.equal(f.owner.stats().consumed, 128);
      measured.push({ size: 128, old, ...f.counts, recovery: f.owner.stats() });
    } finally { await f.close(); }
  }
  console.info(JSON.stringify({ scenario: 'production-next-launch-io', measured }));
});

/**
 * 平台事件恢复的生产函数回归：用真实隔离目录保存活动和事件，只替换 OHOS 文件系统边界。
 * 计数生产函数实际打开 manifest 的次数，证明无归属事件不会再扫描全部历史；原件的保留、
 * 显式身份、时间/PID、迟到修正及写入失败仍由原 ActivityLedger 实现决定。
 * 旧实现对照只加载固定基线的完整源文件，不另写一份匹配算法，也不把宿主耗时当真机耗时。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const ledgerPath = 'commons/src/main/ets/utils/ActivityLedger.ets';
// 精确旧函数作为正式样本随测试交付，公开快照/CI 不需要维护者私有 Git 历史。
const legacy = JSON.parse(fs.readFileSync(new URL('./fixtures/platform-event-recovery-legacy.json', import.meta.url), 'utf8'));
assert.equal(legacy.schemaVersion, 1);
assert.equal(legacy.functionName, 'archivePlatformEventFiles_');
assert.equal(createHash('sha256').update(legacy.originalFunction).digest('hex'), legacy.originalFunctionSha256);

/** AST 只用于机械替换原函数边界；匹配策略完全执行已保存的原生产字节。 */
function withOriginalFunction(source) {
  const ast = compiler.createSourceFile(ledgerPath, source, compiler.ScriptTarget.Latest, true);
  const functions = ast.statements.filter(node => compiler.isFunctionDeclaration(node)
    && node.name?.text === legacy.functionName);
  assert.equal(ast.parseDiagnostics.length, 0);
  assert.equal(functions.length, 1);
  return source.slice(0, functions[0].getStart(ast)) + legacy.originalFunction + source.slice(functions[0].end);
}

/** 每份夹具都有独立文件域；计数器只观察真实 openSync，不改读到的字节、返回值或失败。 */
function fixture(legacy = false) {
  const runtime = evidenceRuntime({ transform: (absolute, source) =>
    legacy && absolute.endsWith('ActivityLedger.ets') ? withOriginalFunction(source) : source });
  const ledger = runtime.load(ledgerPath);
  ledger.setLedgerProcessRunNonce('host-recovery-cost-test');
  const firstId = Date.now() - 120000;
  const ids = Array.from({ length: 8 }, (_, index) => firstId + index * 1000);
  for (const id of ids) {
    assert.equal(ledger.ledgerBegin(runtime.directory, id, { category: 'launch', title: 'fixture',
      gameVersionId: 'fixture-game', mcDir: runtime.directory + '/minecraft' }), true);
  }
  let manifestOpens = 0;
  const originalOpen = runtime.kitFs.openSync;
  runtime.kitFs.openSync = (path, ...args) => {
    if (typeof path === 'string' && path.endsWith('/manifest.json')) manifestOpens++;
    return originalOpen(path, ...args);
  };
  const eventPath = name => runtime.directory + '/logs/platform-events/event-' + name + '.json';
  const writeEvent = (name, event) => runtime.write('logs/platform-events/event-' + name + '.json', JSON.stringify(event));
  return { runtime, ledger, ids, eventPath, writeEvent,
    manifestOpens: () => manifestOpens, resetCount: () => { manifestOpens = 0; },
    archive: () => ledger.archivePlatformEventFiles_(runtime.directory),
    close: () => runtime.close() };
}

test('旧完整实现反例：64个不可归属退出事件扫描512份manifest；修复后零读取且原字节全保留', () => {
  for (const legacy of [true, false]) {
    const f = fixture(legacy);
    try {
      const originals = new Map();
      for (let index = 0; index < 64; index++) {
        const file = f.writeEvent(String(index), { schema: 1, domain: 'OS', name: 'LAST_EXIT_REASON',
          receivedAt: Date.now(), reasonCode: 0, reason: 'UNKNOWN', message: '' });
        originals.set(file, fs.readFileSync(file));
      }
      f.archive();
      assert.equal(f.manifestOpens(), legacy ? 512 : 0,
        '计数必须来自实际生产调用，不能只断言源文本包含提前continue');
      for (const [file, bytes] of originals) assert.deepEqual(fs.readFileSync(file), bytes);
      console.info(JSON.stringify({ scenario: 'unattributable-exit-recovery', legacy,
        pendingEvents: 64, activities: 8, actualManifestOpens: f.manifestOpens() }));
    } finally { f.close(); }
  }
});

test('时间或PID单独缺失时不扫描；receivedAt绝不替代真正事件时间', () => {
  const f = fixture();
  try {
    const files = [
      f.writeEvent('missing-time', { name: 'APP_CRASH', receivedAt: f.ids[0] + 100, params: { pid: 101 } }),
      f.writeEvent('missing-pid', { name: 'APP_CRASH', eventAt: f.ids[0] + 100 }),
    ];
    f.archive();
    assert.equal(f.manifestOpens(), 0);
    for (const file of files) assert.ok(fs.existsSync(file), '证据不足的原件仍留待后续恢复');
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.ids[0]).state, f.ledger.LedgerState.RUNNING);
  } finally { f.close(); }
});

test('没有时间/PID的精确活动主键和nonce仍能归属；错误nonce保留原件', () => {
  const f = fixture();
  try {
    const accepted = f.writeEvent('bound', { name: 'LAST_EXIT_REASON', reason: 'APP_FREEZE',
      activityId: f.ids[0], runNonce: 'host-recovery-cost-test' });
    const rejected = f.writeEvent('wrong-nonce', { name: 'APP_CRASH',
      activityId: f.ids[1], runNonce: 'another-run' });
    f.archive();
    assert.equal(fs.existsSync(accepted), false);
    assert.ok(fs.existsSync(rejected));
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.ids[0]).state, f.ledger.LedgerState.CRASHED);
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.ids[1]).state, f.ledger.LedgerState.RUNNING);
  } finally { f.close(); }
});

test('完整时间/PID按原窗口唯一归属，后写入的有效事件不被前次零候选缓存遮蔽', () => {
  const f = fixture();
  try {
    const pending = f.writeEvent('later', { name: 'APP_CRASH', receivedAt: f.ids[0] + 100 });
    f.archive();
    assert.equal(f.manifestOpens(), 0);
    assert.ok(fs.existsSync(pending));
    f.writeEvent('later', { name: 'APP_CRASH', eventAt: f.ids[0] + 100, params: { pid: 101 } });
    f.archive();
    assert.equal(fs.existsSync(pending), false);
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.ids[0]).outcomeSource, 'platform.APP_CRASH');
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.ids[1]).state, f.ledger.LedgerState.RUNNING);
  } finally { f.close(); }
});

test('迟到精确崩溃纠正JVM退出请求结论；manifest写失败保持原件并可在下一调用重试', () => {
  const f = fixture();
  try {
    f.ledger.ledgerEnd(f.runtime.directory, f.ids[0], { state: f.ledger.LedgerState.SUCCESS,
      source: 'session.jvm-exit', summary: 'JVM退出请求0' });
    const pending = f.writeEvent('late-crash', { name: 'APP_CRASH', activityId: f.ids[0],
      runNonce: 'host-recovery-cost-test' });
    // 只拒绝带 CREATE 的实际写入，READ_ONLY 仍可读取原 manifest；否则测试只是
    // 制造“候选不可读”，没有经过被测归档器的终态保存失败和原件保留接缝。
    f.runtime.control.failWrite = (path, mode) => path.includes('/manifest.json') && (mode & 64) !== 0;
    f.archive();
    assert.ok(fs.existsSync(pending), '未耐久保存终态时不能消费事件');
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.ids[0]).state, f.ledger.LedgerState.SUCCESS);
    f.runtime.control.failWrite = undefined;
    f.archive();
    assert.equal(fs.existsSync(pending), false);
    assert.equal(f.ledger.ledgerManifest(f.runtime.directory, f.ids[0]).state, f.ledger.LedgerState.CRASHED);
  } finally { f.close(); }
});

// Execute the production ArkTS modules with host filesystem/network adapters.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
const fixture = evidenceRuntime();
const temp = fixture.directory;
const load = fixture.load;
let copyFailure = false;
fixture.kitFs.copyFileSync = (from, to) => { if (copyFailure) throw new Error('disk full'); fs.copyFileSync(from, to); };
import path from 'node:path';
try {
  const policy = load('commons/src/main/ets/utils/SessionRetention.ets');
  assert.equal(policy.normalizeSessionRetention(NaN), 5);
  assert.equal(policy.normalizeSessionRetention(0), 5);
  assert.equal(policy.normalizeSessionRetention(101), 100);
  const entries = [];
  for (const versionKey of ['A', 'B']) for (let n = 1; n <= 105; n++) entries.push({ activityId: n + (versionKey === 'B' ? 1000 : 0), category: 'launch', versionKey, running: false, abnormal: false, bytes: 20 * 1024 ** 2, hasGame: true });
  entries.push({ activityId: 9999, category: 'launch', versionKey: 'A', running: true, abnormal: false, bytes: 1, hasGame: false });
  for (let n = 0; n < 120; n++) entries.push({ activityId: 10000 + n, category: n % 2 ? 'download' : 'launch', versionKey: 'A', running: false, abnormal: true, bytes: 2048, hasGame: false });
  for (const limit of [5, 37, 100]) {
    const victims = policy.sessionRetentionVictims(entries, limit, 50, 64 * 1024 ** 2);
    for (const version of ['A', 'B']) assert.equal(entries.filter(e => e.category === 'launch' && e.hasGame && e.versionKey === version && !e.running && !victims.includes(e.activityId)).length, limit);
    assert(!victims.includes(9999));
  }
  // 失败重试不能吞掉完整会话窗口；异常预算也不能因一个超大项连带清空后续小项。
  const mix = Array.from({ length: 10 }, (_, i) => ({ activityId: i + 1, category: 'launch', versionKey: 'A', running: false, abnormal: i >= 5, bytes: 100, hasGame: i < 5 }));
  assert.deepEqual(policy.sessionRetentionVictims(mix, 5, 50, 64 * 1024 ** 2), []);
  const ordinary = [{ activityId: 101, bytes: 65 * 1024 ** 2, abnormal: true },
    { activityId: 103, bytes: 1024 ** 2, abnormal: false }, { activityId: 102, bytes: 1024 ** 2, abnormal: false }]
    .map(e => ({ ...e, category: 'download', versionKey: '', running: false, hasGame: false }));
  assert.deepEqual(policy.sessionRetentionVictims(ordinary, 5, 50, 64 * 1024 ** 2), [101]);
  const ledger = load('commons/src/main/ets/utils/ActivityLedger.ets');
  const paths = load('commons/src/main/ets/utils/GameLogPaths.ets');
  const mc = path.join(temp, 'minecraft').replaceAll('\\', '/');
  fs.mkdirSync(mc);
  const files = path.join(temp, 'app').replaceAll('\\', '/');
  fs.mkdirSync(files);
  const start = Date.now();
  const output = id => `##AMCL-SESSION-BEGIN {"epochMs":${id},"activityId":${id}}\n`;
  const begin = id => ledger.ledgerBegin(files, id, { category: 'launch', title: 'test-version', gameVersionId: 'test-version', mcDir: mc });
  const end = id => ledger.ledgerEnd(files, id, { state: ledger.LedgerState.SUCCESS, source: 'test', summary: 'done' });
  begin(start);
  const full = output(start) + '首部标记\n' + 'x'.repeat(17 * 1024 ** 2) + '\n尾部标记';
  fs.writeFileSync(mc + '/mc_output.log', full);
  end(start);
  fs.writeFileSync(mc + '/mc_output.log', output(start + 1) + 'other session');
  assert.equal(ledger.ledgerRead(files, start, ledger.LedgerPart.GAME), full, 'full archive survives overwrite and 16 MiB boundary');
  assert.equal(ledger.ledgerPartBytes(files, start, ledger.LedgerPart.GAME), Buffer.byteLength(full));
  assert.equal(paths.findSessionLog(mc, 'test-version', start).path, '', 'a different activity never matches via timestamp or mtime');
  const second = start + 2;
  begin(second);
  fs.writeFileSync(mc + '/mc_output.log', output(second) + 'recovery');
  assert.equal(ledger.ledgerPartBytes(files, second, ledger.LedgerPart.GAME), fs.statSync(mc + '/mc_output.log').size, 'running output size');
  ledger.ledgerResolveStale(files);
  assert.equal(ledger.ledgerRead(files, second, ledger.LedgerPart.GAME), output(second) + 'recovery');
  const third = start + 3;
  begin(third);
  fs.writeFileSync(mc + '/mc_output.log', output(third) + 'retry');
  copyFailure = true;
  end(third);
  assert(!fs.existsSync(ledger.ledgerDirOf(files, third) + '/game/mc_output.log'));
  assert(!fs.existsSync(ledger.ledgerDirOf(files, third) + '/game/mc_output.log.partial'));
  copyFailure = false;
  ledger.ledgerArchiveCompletedSessions(files);
  assert.equal(ledger.ledgerRead(files, third, ledger.LedgerPart.GAME), output(third) + 'retry');
  ledger.ledgerSetSessionRetention(files, 100);
  assert.equal(ledger.ledgerSessionRetention(files), 100);
  ledger.ledgerSetSessionRetention(files, 5);
  for (let i = 4; i < 11; i++) { const id = start + i; begin(id); fs.writeFileSync(mc + '/mc_output.log', output(id) + 'session-' + i); end(id); }
  assert.equal(ledger.ledgerList(files).length, 5);
  assert.equal(ledger.ledgerRead(files, start + 6, ledger.LedgerPart.GAME), output(start + 6) + 'session-6');
  begin(start + 11);
  assert.throws(() => ledger.ledgerRemove(files, start + 11), /进行中/);
  assert.throws(() => ledger.ledgerClear(files), /进行中/);
  assert.equal(ledger.ledgerList(files).length, 6, 'clear rejects before deleting anything while a session runs');
  end(start + 11);
  ledger.ledgerClear(files);
  assert.equal(ledger.ledgerList(files).length, 0, 'clear succeeds after the protected activity ends');
  console.log('PASS: production retention policy, 5/37/100 per version, busy activity protection, >16 MiB archive, exact identity, recovery, disk failure, retry, persisted setting and pruning');
} finally {
  fixture.close();
}

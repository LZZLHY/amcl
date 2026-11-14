/**
 * 复现真实游戏scope缺失被host收据掩盖的完整性反例。只适配SDK文件边界，原件/固定SHA
 * 与同步、异步Evidence封账均执行生产实现；不伪造游戏启动成功或新建采集协议。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/** 构造带有完整host收据的隔离原件；可选已启动游戏的stdio与固定归档收据。 */
function fixture(game = false, separate = false) {
  const runtime = evidenceRuntime(), root = runtime.directory;
  const status = { schema: 1, activityId: 123, pid: 101, sealed: true, dropped: 0, writeFailures: 0, truncated: 0 };
  runtime.write('logs/ledger/123/launcher/launcher-host.log', 'HOST_BODY\n');
  runtime.write('logs/ledger/123/capture-host.json', JSON.stringify(status));
  runtime.write('logs/ledger/123/native-io.json', JSON.stringify({ schema: 1, activityId: 123,
    pid: separate ? 202 : 101, consoleReady: true, javaAttached: game, ended: true, ioError: 0, gameStarted: game }));
  if (game) {
    const body = 'GAME_BODY\n', path = runtime.write('logs/ledger/123/game/mc_output.log', body);
    runtime.write('logs/ledger/123/capture-sources.json', JSON.stringify({ schema: 1, activityId: 123, startedAt: 123,
      endedAt: 124, gameDir: '', filesDir: root, appFilesDir: root, jdk: '21', sources: [{ source: path,
        destination: 'game/mc_output.log', baseline: '', captured: 'fixed', state: 'complete', reason: '',
        mode: 'owned', sealed: true, capturedBytes: Buffer.byteLength(body),
        capturedSha256: createHash('sha256').update(body).digest('hex'), attribution: 'exact' }] }));
  }
  return { runtime, root, status, evidence: runtime.load('commons/src/main/ets/utils/SessionEvidence.ets') };
}

test('独立游戏PID与host不同，固定stdout SHA/有序关闭仍不能替代缺失scope，sync/async同为partial且可修复', async () => {
  const f = fixture(true, true);
  try {
    const asyncResult = await f.evidence.refreshSessionEvidenceAsync(f.root, 123, 'sealed', 'complete');
    const syncResult = f.evidence.refreshSessionEvidence(f.root, 123, 'sealed', 'complete');
    assert.equal(asyncResult.integrityState, 'partial'); assert.equal(syncResult.integrityState, 'partial');
    assert.ok(asyncResult.missingReasons.some(reason => reason.includes('游戏进程日志采集收据缺失')));
    assert.deepEqual(syncResult.missingReasons, asyncResult.missingReasons);
    assert.equal(asyncResult.files.find(file => file.path === 'game/mc_output.log').verification, 'verified');
    f.runtime.write('logs/ledger/123/capture-game.json', JSON.stringify({ ...f.status, pid: 202 }));
    const repaired = await f.evidence.refreshSessionEvidenceAsync(f.root, 123, 'sealed', 'complete', asyncResult.missingReasons);
    assert.equal(repaired.integrityState, 'complete');
    assert.ok(!repaired.missingReasons.some(reason => reason.includes('游戏进程日志采集收据缺失')));
  } finally { f.runtime.close(); }
});

test('仅host/同PID早期未进入游戏不要求game收据；独立游戏PID已存在则不能猜完整', async () => {
  for (const separate of [false, true]) {
    const f = fixture(false, separate);
    try {
      const result = await f.evidence.refreshSessionEvidenceAsync(f.root, 123, 'sealed', 'complete');
      assert.equal(result.integrityState, separate ? 'partial' : 'complete');
      assert.equal(result.missingReasons.some(reason => reason.includes('游戏进程日志采集收据缺失')), separate);
    } finally { f.runtime.close(); }
  }
});

test('同PID共享进程gameStarted由完整host收据覆盖，sync/async不误要求capture-game', async () => {
  const f = fixture(true, false);
  try {
    const asynchronous = await f.evidence.refreshSessionEvidenceAsync(f.root, 123, 'sealed', 'complete');
    const synchronous = f.evidence.refreshSessionEvidence(f.root, 123, 'sealed', 'complete');
    assert.equal(asynchronous.files.find(file => file.path === 'game/mc_output.log').verification, 'verified');
    assert.equal(asynchronous.integrityState, 'complete'); assert.equal(synchronous.integrityState, 'complete');
    assert.deepEqual(asynchronous.missingReasons, []); assert.deepEqual(synchronous.missingReasons, []);
  } finally { f.runtime.close(); }
});

test('已进入游戏但host PID未知/收据缺失继续partial，明确game正文也不能用共享PID豁免', async () => {
  for (const mode of ['unknown-host-pid', 'missing-host', 'explicit-game-writer']) {
    const f = fixture(true, false);
    try {
      if (mode === 'unknown-host-pid') {
        const status = { ...f.status }; delete status.pid;
        f.runtime.write('logs/ledger/123/capture-host.json', JSON.stringify(status));
      } else if (mode === 'missing-host') fs.unlinkSync(f.root + '/logs/ledger/123/capture-host.json');
      else f.runtime.write('logs/ledger/123/launcher/launcher-game.log', 'EXPLICIT_GAME_WRITER\n');
      const asynchronous = await f.evidence.refreshSessionEvidenceAsync(f.root, 123, 'sealed', 'complete');
      const synchronous = f.evidence.refreshSessionEvidence(f.root, 123, 'sealed', 'complete');
      assert.equal(asynchronous.integrityState, 'partial', mode); assert.equal(synchronous.integrityState, 'partial', mode);
      assert.ok(asynchronous.missingReasons.some(reason => reason.includes('游戏进程日志采集收据缺失')), mode);
    } finally { f.runtime.close(); }
  }
});

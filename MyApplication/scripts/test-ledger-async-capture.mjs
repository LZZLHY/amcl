/** 真实async生产开账/捕获/Evidence链：拒绝所有SDK Sync边界，证明不是async包装同步大文件工作。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

test('async开账固定启动前baseline，未改旧crash不归本局；新source真异步复制/哈希/封存且不重签损坏', async () => {
  const f = evidenceRuntime();
  const root = f.directory.replaceAll('\\', '/');
  const id = Date.now() - 1000;
  try {
    f.write('minecraft/logs/latest.log', 'PREVIOUS SESSION\n');
    f.write('minecraft/crash-reports/old.txt', 'old crash body');
    const ledger = f.load('commons/src/main/ets/utils/ActivityLedger.ets');
    const capture = f.load('commons/src/main/ets/utils/SessionCapture.ets');
    const evidence = f.load('commons/src/main/ets/utils/SessionEvidence.ets');
    ledger.configureLedgerMaintenanceOwner(true); ledger.ledgerBeginMaintenanceBatch(root);
    const denied = [];
    for (const name of Object.keys(f.kitFs)) if (name.endsWith('Sync') && typeof f.kitFs[name] === 'function') {
      f.kitFs[name] = () => { denied.push(name); assert.fail('异步链调用了SDK同步接口: ' + name); };
    }
    assert.equal(await ledger.ledgerBeginAsync(root, id, { category: 'launch', title: 'async source', gameDir: root + '/minecraft' }), true);
    const baseline = await capture.readSessionCaptureAsync(root, id);
    assert.ok(baseline.sources.find(item => item.destination === 'game/logs/latest.log').baselineDigest);
    await capture.checkpointSessionCaptureAsync(root, id, Date.now() + 1000, 0, true);
    let files = await evidence.listSessionEvidenceAsync(root, id);
    assert.equal(files.find(file => file.path === 'crash-reports/old.txt').state, 'not-produced');
    f.write('minecraft/logs/latest.log', 'CURRENT SESSION\n[INFO] Stopping!\n');
    await capture.checkpointSessionCaptureAsync(root, id, Date.now() + 1000, 0, true);
    await ledger.ledgerEndAsync(root, id, { state: ledger.LedgerState.SUCCESS, source: 'fixture.current', summary: 'done', endedAt: Date.now() },
      { inputKey: 'source-revision-1', capturePrepared: true });
    files = await evidence.listSessionEvidenceAsync(root, id);
    const latest = files.find(file => file.path === 'game/logs/latest.log');
    assert.equal(latest.verification, 'verified'); assert.equal(latest.state, 'complete');
    const expectedHash = latest.rawSha256;
    const original = fs.readFileSync(latest.localPath);
    // 同长度损坏不会被现存文件重新签成complete；固定收据仍保留原SHA。
    fs.writeFileSync(latest.localPath, Buffer.alloc(original.length, 88));
    await capture.checkpointSessionCaptureAsync(root, id, Date.now(), 0, true);
    files = await evidence.listSessionEvidenceAsync(root, id);
    const damaged = files.find(file => file.path === 'game/logs/latest.log');
    assert.equal(damaged.state, 'partial'); assert.equal(damaged.rawSha256, expectedHash);
    assert.deepEqual(denied, []);
  } finally { f.close(); }
});

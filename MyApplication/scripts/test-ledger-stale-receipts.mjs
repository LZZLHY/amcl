/**
 * 执行真实冷启动stale恢复与单局提交。只替换SDK IO，不重写终态校验；
 * 覆盖业务已经完成但canonical尚未提交时的耐久原件，并核对坏身份不能伪造成功。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

/**
 * 无参数建立独立外置磁盘和生产账本，固定runNonce并持真实maintenance batch，避免自动维护干扰故障输入。
 * 返回begin/mod/update/write/close：开账与恢复使用生产实现，mod/update只生成待核验的生产者原件而非canonical终态。
 * override允许用例制造坏nonce/类别/状态；write把JSON写到指定本局原件路径，证据是否有效仍由生产resolver判断。
 * 用例finally await close，先结束并等待真实batch，再只清理本夹具目录；不创建native writer或设备进程。
 */
function fixture() {
  const runtime = evidenceRuntime(), root = runtime.directory.replaceAll('\\', '/');
  const ledger = runtime.load('commons/src/main/ets/utils/ActivityLedger.ets');
  ledger.setLedgerProcessRunNonce('stale-receipt-test'); ledger.configureLedgerMaintenanceOwner(true, () => true);
  ledger.ledgerBeginMaintenanceBatch(root);
  return { runtime, root, ledger,
    begin(id, category) { assert.equal(ledger.ledgerBegin(root, id, { category, title: category }), true); },
    /** 按id生成模组业务完成原件，override用于注入错误身份/结局；record快照不授予canonical写权。 */
    mod(id, override = {}) { return { schema: 1, activityId: id, category: 'mod_install', runNonce: 'stale-receipt-test',
      outcome: { state: ledger.LedgerState.SUCCESS, source: 'modInstall.terminal', summary: 'installed', endedAt: id + 10 },
      record: { arbitrary: '原业务快照不授予canonical权限' }, ...override }; },
    /** 按id生成更新下载完成原件，覆盖字段只作为测试输入；真实恢复须复核同局身份及状态。 */
    update(id, override = {}) { return { schema: 1, activityId: id, category: 'app_update_download', runNonce: 'stale-receipt-test',
      state: ledger.LedgerState.SUCCESS, summary: 'verified', endedAt: id + 10, ...override }; },
    write(id, file, value) { const path = ledger.ledgerDirOf(root, id) + '/' + file; fs.writeFileSync(path, JSON.stringify(value)); return path; },
    async close() { await ledger.ledgerEndMaintenanceBatchAsync(root); runtime.close(); }
  };
}

test('真实Mod/更新下载耐久终态恢复SUCCESS/FAILED/ABORTED，保留原件和真实完成时刻', async () => {
  const f = fixture();
  try {
    f.begin(100, 'mod_install'); f.begin(200, 'app_update_download'); f.begin(300, 'app_update_download');
    const paths = [f.write(100, 'task-terminal.json', f.mod(100)),
      f.write(200, 'update-terminal.json', f.update(200, { state: f.ledger.LedgerState.FAILED })),
      f.write(300, 'update-terminal.json', f.update(300, { state: f.ledger.LedgerState.ABORTED }))];
    const originals = paths.map(path => fs.readFileSync(path));
    assert.equal(await f.ledger.ledgerResolveStaleAsync(f.root), 3);
    assert.equal(f.ledger.ledgerManifest(f.root, 100).state, f.ledger.LedgerState.SUCCESS);
    assert.equal(f.ledger.ledgerManifest(f.root, 100).outcomeSource, 'modInstall.terminal');
    assert.equal(f.ledger.ledgerManifest(f.root, 200).state, f.ledger.LedgerState.FAILED);
    assert.equal(f.ledger.ledgerManifest(f.root, 200).outcomeSource, 'sideload.update');
    assert.equal(f.ledger.ledgerManifest(f.root, 300).state, f.ledger.LedgerState.ABORTED);
    for (const id of [100, 200, 300]) {
      const manifest = f.ledger.ledgerManifest(f.root, id);
      assert.equal(manifest.endedAt, id + 10); assert.equal(manifest.endTimeEstimated, false);
    }
    paths.forEach((path, index) => assert.deepEqual(fs.readFileSync(path), originals[index]));
    assert.equal(await f.ledger.ledgerResolveStaleAsync(f.root), 0);
  } finally { await f.close(); }
});

test('错nonce/category/source/结束时刻/状态或损坏原件不能伪成功；既有终态和更新fence不覆写', async () => {
  const f = fixture();
  try {
    const invalid = [
      f.mod(100, { runNonce: 'other-owner' }), f.mod(200, { category: 'other' }),
      f.mod(300, { outcome: { state: f.ledger.LedgerState.SUCCESS, source: 'forged', summary: 'bad', endedAt: 310 } }),
      f.update(400, { endedAt: Date.now() + 60000 }), f.update(500, { state: f.ledger.LedgerState.RUNNING }),
    ];
    const paths = [];
    for (let index = 0; index < invalid.length; index++) {
      const id = (index + 1) * 100, mod = index < 3;
      f.begin(id, mod ? 'mod_install' : 'app_update_download');
      paths.push(f.write(id, mod ? 'task-terminal.json' : 'update-terminal.json', invalid[index]));
    }
    f.begin(600, 'mod_install'); const broken = f.ledger.ledgerDirOf(f.root, 600) + '/task-terminal.json';
    fs.writeFileSync(broken, '{corrupt'); paths.push(broken);
    f.begin(700, 'app_update'); f.begin(800, 'mod_install');
    await f.ledger.ledgerEndAsync(f.root, 800, { state: f.ledger.LedgerState.FAILED, source: 'existing', summary: 'terminal', endedAt: 810 });
    f.write(800, 'task-terminal.json', f.mod(800));
    const before = paths.map(path => fs.readFileSync(path));
    assert.equal(await f.ledger.ledgerResolveStaleAsync(f.root, [700]), 6);
    for (const id of [100, 200, 300, 400, 500, 600]) assert.equal(f.ledger.ledgerManifest(f.root, id).state, f.ledger.LedgerState.INTERRUPTED);
    assert.equal(f.ledger.ledgerManifest(f.root, 700).state, f.ledger.LedgerState.RUNNING);
    assert.equal(f.ledger.ledgerManifest(f.root, 800).outcomeSource, 'existing');
    paths.forEach((path, index) => assert.deepEqual(fs.readFileSync(path), before[index]));
  } finally { await f.close(); }
});

/** 用API26真实系统事件及账本回归同步/异步恢复；宿主只替换OHOS IO，不另写归属算法。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';

const sample = JSON.parse(fs.readFileSync(new URL('./fixtures/platform-killed-api26.json', import.meta.url), 'utf8'));
const ledgerPath = 'commons/src/main/ets/utils/ActivityLedger.ets';
const clone = value => JSON.parse(JSON.stringify(value));

/** 每例独立目录。成功回收自身夹具，失败保留路径；原事件归档后必须字节不变。 */
async function run(mode, mutate, expected, setup = undefined) {
  const runtime = evidenceRuntime(); let complete = false;
  try {
    const ledger = runtime.load(ledgerPath); const id = sample.manifest.activityId;
    ledger.setLedgerProcessRunNonce('platform-killed-regression');
    assert.equal(ledger.ledgerBegin(runtime.directory, id, { category: 'launch', title: 'platform regression', gameVersionId: 'fixture', mcDir: '/qa' }), true);
    runtime.write(`logs/ledger/${id}/manifest.json`, JSON.stringify(sample.manifest));
    runtime.write(`logs/ledger/${id}/capture-game.json`, JSON.stringify(sample.gameCapture));
    const event = clone(sample.gameEvent); mutate(event);
    if (setup) setup(runtime, ledger, id);
    const raw = JSON.stringify(event); const pending = runtime.write('logs/platform-events/event-real.json', raw);
    if (mode === 'sync') ledger.archivePlatformEventFiles_(runtime.directory);
    else await ledger.archivePlatformEventFilesAsync(runtime.directory);
    const after = ledger.ledgerManifest(runtime.directory, id);
    const archived = `${runtime.directory}/logs/ledger/${id}/system/exit-event-event-real.json`;
    if (expected === 'pending') {
      assert.equal(fs.readFileSync(pending, 'utf8'), raw); assert.ok(!fs.existsSync(archived));
      assert.equal(after.outcomeSource, sample.manifest.outcomeSource);
    } else {
      assert.ok(!fs.existsSync(pending)); assert.equal(fs.readFileSync(archived, 'utf8'), raw);
      if (expected === 'context') {
        assert.equal(after.outcomeSource, sample.manifest.outcomeSource);
        assert.equal(after.endedAt, sample.manifest.endedAt);
      } else {
        assert.equal(after.outcomeSource, 'platform.APP_KILLED');
        assert.equal(after.state, ledger.LedgerState.INTERRUPTED); assert.equal(after.endTimeEstimated, false);
        assert.match(after.outcomeSummary, /常驻内存.*系统阈值/);
        const actualParams = typeof event.params === 'string' ? JSON.parse(event.params) : event.params;
        const details = typeof actualParams.last_exit_detail_info === 'string' ? JSON.parse(actualParams.last_exit_detail_info) : actualParams.last_exit_detail_info;
        assert.equal(after.endedAt, event.eventAt || actualParams.time || Number(details.timestamp));
      }
    }
    // 恢复会排队索引维护；必须等本轮真实IO关闭后再回收夹具，不能与后台写入竞争rmdir。
    await ledger.ledgerFlushMaintenanceAsync(runtime.directory);
    complete = true;
  } finally {
    if (complete) runtime.close();
    else console.error('Retained failed platform fixture:', runtime.directory);
  }
}

for (const mode of ['sync', 'async']) {
  test(`${mode}: 原始嵌套字符串PID事件归属并回读明确RSS终止原因`, () => run(mode, () => {}, 'accepted'));
  test(`${mode}: 官方JSON字符串详情与对象实机形态同义`, () => run(mode, event => { event.params.last_exit_detail_info = JSON.stringify(event.params.last_exit_detail_info); }, 'accepted'));
  test(`${mode}: params本身为JSON字符串`, () => run(mode, event => { event.params = JSON.stringify(event.params); }, 'accepted'));
  test(`${mode}: 旧平铺PID兼容`, () => run(mode, event => { event.params.pid = 49558; delete event.params.last_exit_detail_info; }, 'accepted'));
  test(`${mode}: wrapper时间缺失时使用真实params.time`, () => run(mode, event => { event.eventAt = 0; }, 'accepted'));
  test(`${mode}: 仅详情真实时间戳仍可归属`, () => run(mode, event => { event.eventAt = 0; delete event.params.time; }, 'accepted'));
  test(`${mode}: 只有receivedAt不猜时间`, () => run(mode, event => { delete event.eventAt; delete event.params.time; delete event.params.last_exit_detail_info.timestamp; }, 'pending'));
  test(`${mode}: 两层有效PID冲突不任意选择`, () => run(mode, event => { event.params.pid = 46120; }, 'pending'));
  for (const pid of ['49558junk', '4.9558e4', '-49558', '0', '9007199254740992', '', null, true])
    test(`${mode}: 拒绝非法嵌套PID ${String(pid)}`, () => run(mode, event => { event.params.last_exit_detail_info.pid = pid; }, 'pending'));
  test(`${mode}: 父启动器终止只归档背景证据`, () => run(mode, event => Object.assign(event, clone(sample.hostEvent)), 'context', (runtime, ledger, id) => {
    runtime.write(`logs/ledger/${id}/capture-host.json`, JSON.stringify({ pid: 46120 }));
  }));
  test(`${mode}: 同进程shared游戏仍接受其PID事件`, () => run(mode, () => {}, 'accepted', (runtime, ledger, id) => {
    runtime.write(`logs/ledger/${id}/capture-host.json`, JSON.stringify({ pid: 49558 }));
  }));
  test(`${mode}: 旧记录无capture-game仍按已核owner归属`, () => run(mode, () => {}, 'accepted', (runtime, ledger, id) => {
    fs.unlinkSync(`${runtime.directory}/logs/ledger/${id}/capture-game.json`);
  }));
}

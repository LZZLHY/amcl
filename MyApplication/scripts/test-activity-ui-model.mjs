/** 活动账本 V2 的宿主回归：直接加载生产 ArkTS 纯逻辑和 AI 服务，网络仅使用内存桩。 */
// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const ActivityCategory = { LAUNCH: 'launch', DOWNLOAD: 'download', MOD_INSTALL: 'mod_install', JDK: 'jdk', MODPACK: 'modpack' };
const model = makePureEtsLoader({ feature_core: { ActivityCategory } })('entry/src/main/ets/components/ActivityUiModel.ets');
const record = fields => ({ category: 'launch', status: 'success', startedAt: 1, loaderType: 'fabric',
  versionName: '1.21.1', gameVersion: '1.21.1', ...fields });
const tick = () => new Promise(resolve => setImmediate(resolve));

test('filters use actual categories and do not reclassify successful games', () => {
  assert(model.matchesActivity(record({ category: 'jdk' }), '1.21', model.ActivityFilter.DOWNLOAD));
  assert(!model.matchesActivity(record({ category: 'account' }), '', model.ActivityFilter.DOWNLOAD));
  assert(!model.matchesActivity(record({ status: 'success' }), '', model.ActivityFilter.ABNORMAL));
  assert(model.matchesActivity(record({ errorMessage: 'Missing Fabric API' }), 'fabric api', model.ActivityFilter.GAME));
  assert.equal(model.activityStatusLabel(record({ status: 'aborted' })), '已中断');
  assert.equal(model.activityStatusLabel(record({ category: 'download', status: 'aborted' })), '已取消');
});

test('local-date grouping is newest-first, counts today and does not mutate records', () => {
  const now = new Date(2026, 8, 19, 12).getTime();
  const items = [record({ startedAt: now - 86400000 }), record({ startedAt: now, status: 'failed' }),
    record({ startedAt: now - 60000, status: 'aborted' }), record({ startedAt: now - 120000, status: 'running' })];
  const original = items.map(row => row.startedAt);
  const groups = model.groupActivities(items, now);
  assert.deepEqual(groups.map(group => group.label), ['今天', '昨天']);
  assert.deepEqual(model.activityTodayStats(items, now), { total: 3, completed: 0, interrupted: 1, failed: 1 });
  assert.deepEqual(items.map(row => row.startedAt), original);
});

test('AI preview strips presentation markup, code and executable-looking HTML without another model call', () => {
  const summary = model.aiPreviewText('## **原因**\n可能缺少 `fabric-api`。\n```sh\nrm -rf /example\n```\n[参考](https://example.com)');
  assert.equal(summary, '原因 可能缺少 fabric-api。 参考');
  const text = 'a'.repeat(15) + '😀' + 'b'.repeat(25);
  assert.equal(model.aiPreviewText(text, 16), 'a'.repeat(15) + '…');
});

/** 色轴保留未知状态的份额，不把刻线数量当作活动总数；大数据量节点数有界。 */
test('status rail preserves actual counts, keeps pending neutral and bounds tick nodes', () => {
  assert.deepEqual(model.activityStatusBands({ total: 0, completed: 0, interrupted: 0, failed: 0 }), []);
  const bands = model.activityStatusBands({ total: 103, completed: 99, interrupted: 1, failed: 2 });
  assert.deepEqual(bands.map(band => [band.status, band.count]), [['success', 99], ['interrupted', 1], ['failed', 2], ['other', 1]]);
  assert(bands.every(band => band.ticks.length <= 8));
  assert.equal(bands.reduce((count, band) => count + band.count, 0), 103);
  assert.equal(model.activityClock(new Date(2026, 8, 19, 1, 7).getTime()), '01:07');
  assert.equal(model.activityClock(0), '—');
  assert.equal(model.activityClock(Number.NaN), '—');
});

/** 服务桩只替换网络、磁盘和通知边界，任务表、订阅和迟到回调保护执行真实代码。 */
function serviceFixture() {
  const calls = [], saved = [], messages = [];
  let failSave = false;
  const base = 'https://api.logshare.cn';
  const load = makePureEtsLoader({
    '@kit.AbilityKit': {},
    commons: { AppLogger: { info() {}, warn() {} }, LOG_DOMAIN_UI: 0 },
    './LogShareClient': { LOGSHARE_API_BASE: base,
      streamAiAnalysis: (id, cb) => { calls.push({ id, cb }); return { cancel() { cb.onError('cancelled'); } }; },
      loadShareRecords: async () => calls.map(call => ({ id: call.id, apiBaseUrl: base, activityId: 1, snapshotDigest: 'snapshot-' + call.id })),
    },
    './McSessionSnapshot': { saveSessionAiText: async () => '/fixture/1.md' },
    './AiReportStore': { saveAiReport: (...args) => { if (failSave) throw new Error('disk full'); saved.push(args); } },
    './AppMessageStore': { buildAiDoneMessage: key => ({ key, ok: true }), buildAiFailedMessage: key => ({ key, ok: false }) },
    './AppNotifier': { postAppMessage: async (_ctx, msg) => { messages.push(msg); } },
  });
  return { service: load('entry/src/main/ets/components/AiAnalysisService.ets'), calls, saved, messages, base,
    context: { filesDir: '/fixture' }, failSave: () => { failSave = true; }, recoverSave: () => { failSave = false; } };
}

test('multiple UI observers coexist with the legacy sheet and unsubscribe independently', async () => {
  const f = serviceFixture(), one = [], two = [], legacy = [];
  const a = f.service.subscribeAiTaskChanges(key => one.push(key));
  f.service.subscribeAiTaskChanges(key => two.push(key));
  f.service.startAiAnalysis(f.context, 1, 'abc', 'test');
  f.service.attachAiObserver(1, { onDelta: t => legacy.push(t), onDone() {}, onError() {} });
  f.calls[0].cb.onDelta('公开回答');
  f.service.unsubscribeAiTaskChanges(a);
  const oldCount = one.length;
  f.calls[0].cb.onDelta('第二段');
  assert.equal(one.length, oldCount); assert(two.length > one.length); assert.deepEqual(legacy, ['公开回答', '第二段']);
  f.calls[0].cb.onDone('完整回答'); await tick();
  assert.equal(f.service.getAiTaskSnapshot(1).saved, true);
  assert.equal(f.saved[0][3].snapshotDigest, 'snapshot-abc');
});

test('replacement and explicit cancellation ignore late callbacks and do not publish false failures', async () => {
  const f = serviceFixture();
  f.service.startAiAnalysis(f.context, 1, 'old', 'test');
  f.service.startAiAnalysis(f.context, 1, 'new', 'test');
  f.calls[0].cb.onDone('obsolete'); f.calls[0].cb.onDelta('late');
  assert.equal(f.service.getAiTaskText(1), ''); assert.equal(f.messages.length, 0);
  f.service.cancelAiAnalysis(1); f.calls[1].cb.onDone('cancelled response'); await tick();
  assert.equal(f.saved.length, 0); assert.equal(f.messages.length, 0);
});

test('idempotence and provider guard prevent repeat requests and backup AI', async () => {
  const f = serviceFixture();
  f.service.startAiAnalysis(f.context, 1, 'id', 'test');
  f.service.startAiAnalysis(f.context, 1, 'id', 'test');
  f.service.startAiAnalysis(f.context, 2, 'backup', 'test', 'https://backup.invalid');
  assert.equal(f.calls.length, 1);
  f.failSave(); f.calls[0].cb.onDone('answer'); await tick();
  const snapshot = f.service.getAiTaskSnapshot(1);
  assert.equal(snapshot.state, f.service.AiTaskState.DONE); assert.equal(snapshot.saved, false);
  assert.match(snapshot.saveError, /保存失败/);
  f.recoverSave(); await f.service.retrySaveAiReport(f.context, 1);
  assert.equal(f.service.getAiTaskSnapshot(1).saved, true);
  assert.equal(f.calls.length, 1, '重试本地保存不能重新发出 AI 请求');
});

test('a failing legacy UI callback does not prevent durable report publication', async () => {
  const f = serviceFixture();
  f.service.startAiAnalysis(f.context, 1, 'id', 'test');
  f.service.attachAiObserver(1, { onDelta() { throw new Error('view gone'); },
    onDone() { throw new Error('view gone'); }, onError() {} });
  f.calls[0].cb.onDelta('answer'); f.calls[0].cb.onDone('answer'); await tick();
  assert.equal(f.saved.length, 1); assert.equal(f.service.getAiTaskSnapshot(1).saved, true);
});

/** 队列只影响粗状态；限流冷却在服务层生效，任何 UI 入口都不能绕开。 */
test('AI queue status is coarse and Retry-After blocks repeat requests for the same share', () => {
  const f = serviceFixture();
  f.service.startAiAnalysis(f.context, 1, 'queued-id', 'test');
  f.calls[0].cb.onStatus('queued', 3);
  assert.match(f.service.getAiTaskSnapshot(1).statusText, /排队中/);
  assert.equal(f.service.getAiTaskSnapshot(1).text, '');
  f.calls[0].cb.onRetryAfter(60); f.calls[0].cb.onError('服务繁忙');
  f.service.startAiAnalysis(f.context, 1, 'queued-id', 'test');
  assert.equal(f.calls.length, 1);
  assert(f.service.getAiTaskSnapshot(1).retryAt > Date.now());
});

test('report store binds source and detects tampered or mismatched local bodies', () => {
  const directory = fs.mkdtempSync(path.join(workspaceTempRoot(), 'amcl-ai-report-'));
  const digest = text => crypto.createHash('sha256').update(text).digest('hex');
  const load = makePureEtsLoader({
    '@kit.CoreFileKit': { fileIo: { accessSync: fs.existsSync, statSync: fs.statSync, readTextSync: file => fs.readFileSync(file, 'utf8') } },
    feature_core: { ActivityCategory },
    commons: { ensureDirSync: dir => fs.mkdirSync(dir, { recursive: true }), evidenceTextDigest: digest,
      evidenceFileStamp: file => digest(fs.readFileSync(file)), utf8ByteLength: text => Buffer.byteLength(text),
      writeEvidenceTextAtomic: (file, text) => { fs.writeFileSync(file + '.tmp', text); fs.renameSync(file + '.tmp', file); } },
  });
  try {
    const store = load('entry/src/main/ets/components/AiReportStore.ets');
    const saved = store.saveAiReport(directory, 7, '## 结论\n可能缺少依赖', { shareId: 'abc', apiBaseUrl: 'official', snapshotDigest: 'digest' });
    assert.equal(store.loadAiReport(directory, 7).snapshotDigest, 'digest');
    assert.match(store.loadAiReportBody(directory, saved), /可能缺少依赖/);
    assert.equal(store.loadAiReport(directory, 8), undefined);
    assert.throws(() => store.loadAiReport(directory, -1), /标识无效/);
    fs.writeFileSync(path.join(directory, 'logs/ai/7.report.md'), 'changed');
    assert.throws(() => store.loadAiReport(directory, 7), /未完整保存/);
    fs.writeFileSync(path.join(directory, 'logs/ai/9.report.md'), 'interrupted save');
    assert.throws(() => store.loadAiReport(directory, 9), /索引未完成/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

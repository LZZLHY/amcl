/** 快捷分享专项：执行生产准备/服务与组件方法，所有网络替换成可控边界，不上传真实日志。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import ts from './lib/ets-compiler.mjs';
import { evidenceRuntime } from './lib/evidence-test-runtime.mjs';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const base = 'https://api.logshare.cn';
const tick = () => new Promise(resolve => setImmediate(resolve));
const plan = overrides => ({ apiBaseUrl: base, checkedAt: Date.now(), attempts: [],
  limits: { ok: true, maxBytes: 10485760, maxLines: 50000, storageTimeSec: 1296000 }, ...overrides });
const meta = { launcher: 'AMCL', appVersion: 'test', mcVersion: 'test', loader: '', jdk: '', device: '', osVersion: '', outcome: '' };
function component(names, bindings = {}) {
  const file = 'entry/src/main/ets/components/ActivityShareSheet.ets';
  const source = fs.readFileSync(file, 'utf8'), ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const declaration = ast.statements.find(node => node.name?.getText(ast) === 'ActivityShareSheet');
  const code = names.map(name => { const node = declaration.members.find(member => member.name?.getText(ast) === name); assert(node, name); return node.getText(ast); }).join('\n');
  const output = ts.transpileModule('export class Sheet {\n' + code + '\n}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  const exports = {}; new Function(...Object.keys(bindings), 'exports', output)(...Object.values(bindings), exports);
  return new exports.Sheet();
}
function sheetFixture(options = {}) {
  let sends = 0, disposed = 0, remembers = 0, ai = 0, copies = 0;
  const currentPlan = options.plan ?? plan();
  const record = { id: 'abc1234', url: 'https://logshare.cn/abc1234', token: 'fixture', apiBaseUrl: base, snapshotDigest: 'digest' };
  const p = component(['prepare_', 'send_', 'samePlan_', 'planCaption_', 'release_', 'busy_', 'setPhase_', 'receiptCaption_', 'fits_', 'totalBytes_'], {
    LOGSHARE_API_BASE: base, prepareActivityShare: async () => ({ files: [], digest: 'digest' }),
    prepareLogShare: async () => currentPlan,
    hasQuickShareConsent: async () => options.consent === true, quickShareConsentKey: value => value.apiBaseUrl,
    rememberQuickShareConsent: async () => { remembers++; },
    shareEvidenceSnapshot: async () => { sends++; return record; },
    disposeEvidenceExportSnapshot: () => { disposed++; }, activityShareMetadata: () => meta,
    saveSessionShare: async () => {}, logShareSupportsAi: url => url.startsWith('https://logshare.cn/'),
    logShareSourceLabel: () => 'official',
    logShareExportBudgetBytes: limits => limits.ok ? 12 * 1024 * 1024 : 0,
    DistributionPolicy: { allowPublisherServices: () => true },
  });
  Object.assign(p, { alive: true, generation: 0, advanced: options.advanced ?? false, context: {},
    draft: { selectedFileIds: ['one'], manifest: { title: 'fixture' } }, destination: 'logshare', requestAi: false,
    phase: 'select', onBusyChanged() {}, onShared() {}, copy_: async () => { copies++; },
    startAi_: () => { ai++; }, fail_(e) { throw e; },
  });
  return { p, counts: () => ({ sends, disposed, remembers, ai, copies }) };
}

test('first quick share requires explicit consent; subsequent default share sends once and copies without AI', async () => {
  const first = sheetFixture(); await first.p.prepare_(true);
  assert.equal(first.p.phase, 'review'); assert.equal(first.counts().sends, 0);
  await first.p.send_(true); assert.equal(first.counts().sends, 1); assert.equal(first.counts().remembers, 1);
  const next = sheetFixture({ consent: true }); await next.p.prepare_(true);
  assert.equal(next.p.phase, 'done'); assert.equal(next.counts().sends, 1);
  assert.equal(next.counts().copies, 1); assert.equal(next.counts().ai, 0);
});

test('advanced and backup paths cannot inherit automatic public upload authorization', async () => {
  const advanced = sheetFixture({ advanced: true, consent: true }); await advanced.p.prepare_(true);
  assert.equal(advanced.counts().sends, 0); assert.equal(advanced.p.phase, 'review');
  const backup = sheetFixture({ consent: true, plan: plan({ apiBaseUrl: 'https://amcl.lovedhy.cn/logshare-api' }) });
  backup.p.requestAi = true; await backup.p.prepare_(true);
  assert.equal(backup.counts().sends, 0); assert.equal(backup.p.requestAi, false); assert.match(backup.p.errorText, /不支持 AI/);
});

test('stale preflight with unchanged terms sends once; changed provider requires a fresh confirmation', async () => {
  const same = sheetFixture(); same.p.snapshot = { files: [] }; same.p.phase = 'review';
  same.p.preflight = plan({ checkedAt: Date.now() - 70000 }); await same.p.send_(false);
  assert.equal(same.counts().sends, 1);
  const changed = sheetFixture({ plan: plan({ apiBaseUrl: 'https://amcl.lovedhy.cn/logshare-api' }) });
  changed.p.snapshot = { files: [] }; changed.p.phase = 'review'; changed.p.preflight = plan({ checkedAt: Date.now() - 70000 });
  await changed.p.send_(false); assert.equal(changed.counts().sends, 0); assert.equal(changed.p.phase, 'review');
});

test('quick defaults do not adopt advanced optional files; consent changes with retention and instance', async () => {
  let saved = '[]';
  const load = makePureEtsLoader({ '@kit.AbilityKit': {}, '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async () => saved, put: async (_key, value) => { saved = value; }, flush: async () => {},
  }) } }, commons: { EVIDENCE_REDACTION_VERSION: 'test', evidenceTextDigest: text => text,
    EVIDENCE_EXPORT_FORMAT: 'session-diagnosis-v2', readObservedSessionEnvironment: () => ({ schema: 1, facts: [] }),
    verifySessionCaptureRotations: async () => {}, ledgerManifest: () => ({}), listSessionEvidence: () => [{ fileId: 'default' }, { fileId: 'optional' }],
    defaultEvidenceSelection: () => ['default'], evidenceSelectionOf: () => ({ selectedFileIds: ['optional'], revision: 5, includePublicSummary: false }),
  }, './LogShareClient': {} });
  const preparation = load('entry/src/main/ets/components/ActivitySharePreparation.ets');
  const quick = await preparation.loadActivityShareDraft({ filesDir: '/fixture' }, 1, true);
  const custom = await preparation.loadActivityShareDraft({ filesDir: '/fixture' }, 1, false);
  assert.deepEqual(quick.selectedFileIds, ['default']); assert.equal(quick.includePublicSummary, true);
  assert.deepEqual(custom.selectedFileIds, ['optional']); assert.equal(custom.includePublicSummary, false);
  const key = preparation.quickShareConsentKey(plan());
  assert.notEqual(key, preparation.quickShareConsentKey(plan({ apiBaseUrl: 'backup' })));
  assert.notEqual(key, preparation.quickShareConsentKey(plan({ limits: { storageTimeSec: 604800 } })));
  assert.equal(await preparation.hasQuickShareConsent({}, key), false);
  await preparation.rememberQuickShareConsent({}, key); assert.equal(await preparation.hasQuickShareConsent({}, key), true);
  await preparation.resetQuickShareConsent({}); assert.equal(await preparation.hasQuickShareConsent({}, key), false);
  saved = '{invalid'; assert.equal(await preparation.hasQuickShareConsent({}, key), false);
});

test('advanced selection publishes only after persistence succeeds', () => {
  let fail = false;
  const load = makePureEtsLoader({ '@kit.AbilityKit': {}, '@kit.ArkData': {}, './LogShareClient': {}, commons: {
    setEvidenceSelection: (_dir, _id, ids) => { if (fail) throw new Error('disk full'); return { selectedFileIds: ids, revision: 9 }; },
  } });
  const preparation = load('entry/src/main/ets/components/ActivitySharePreparation.ets');
  const draft = new preparation.ActivityShareDraft(); draft.selectedFileIds = ['first'];
  preparation.persistActivityShareSelection({ filesDir: '/fixture' }, draft, ['second'], false);
  assert.deepEqual(draft.selectedFileIds, ['second']); assert.equal(draft.revision, 9); assert.equal(draft.includePublicSummary, false);
  fail = true; assert.throws(() => preparation.persistActivityShareSelection({ filesDir: '/fixture' }, draft, ['bad'], true));
  assert.deepEqual(draft.selectedFileIds, ['second']); assert.equal(draft.includePublicSummary, false);
});

function snapshot(f, content = 'synthetic log') {
  const name = 'game/logs/latest.log', file = f.write('temp/snapshot/' + name, content);
  return { activityId: 7, revision: 1, createdAt: Date.now(), directory: f.context.tempDir + '/snapshot',
    digest: crypto.createHash('sha256').update(content).digest('hex'), redactionVersion: 'game-v3',
    files: [{ name, path: file, role: 'minecraft-main', bytes: Buffer.byteLength(content), sourceBytes: Buffer.byteLength(content),
      lines: content.split('\n').length, state: 'complete', digest: crypto.createHash('sha256').update(content).digest('hex') }] };
}

test('credentials reach disk before slow metadata and late verification cannot resurrect a revoked share', async () => {
  let releaseMetadata, reads = 0;
  const f = evidenceRuntime({ imports: { '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST', GET: 'GET', DELETE: 'DELETE' },
    createHttp: () => ({ destroy() {}, request: async (_url, options) => {
      if (options.method === 'POST') return { responseCode: 201, result: JSON.stringify({ id: 'abc1234', url: 'https://logshare.cn/abc1234', token: 'fixture-token' }) };
      if (options.method === 'DELETE') return { responseCode: 200, result: JSON.stringify({ success: true, deleted: ['abc1234'], failed: [] }) };
      reads++; return new Promise(resolve => { releaseMetadata = resolve; });
    } }) } } } });
  try {
    const service = f.load('entry/src/main/ets/components/EvidenceShareService.ets');
    const client = f.load('entry/src/main/ets/components/LogShareClient.ets');
    const record = await service.shareEvidenceSnapshot(f.context, snapshot(f), meta, plan());
    assert.equal(reads, 1); assert.equal((await client.loadShareRecords(f.context))[0].token, 'fixture-token');
    await client.revokeShare(f.context, record);
    releaseMetadata({ responseCode: 200, result: JSON.stringify({ id: 'abc1234', files: [{ name: 'game/logs/latest.log' }] }) });
    await tick(); await tick();
    assert.equal((await client.loadShareRecords(f.context)).length, 0);
  } finally { f.close(); }
});

test('unknown upload outcome is remembered on disk and blocks a second quick POST', async () => {
  const f = evidenceRuntime();
  try {
    const service = f.load('entry/src/main/ets/components/EvidenceShareService.ets');
    const snap = snapshot(f); f.control.networkError = true;
    await assert.rejects(service.shareEvidenceSnapshot(f.context, snap, meta, plan()), error => error.stage === 'unknown-outcome');
    f.control.networkError = false;
    await assert.rejects(service.shareEvidenceSnapshot(f.context, snap, meta, plan()), error => error.stage === 'unknown-outcome');
    assert.equal(f.control.requests.filter(request => request.options.method === 'POST').length, 1);
    assert(fs.readdirSync(f.directory + '/logs/share-attempts').some(file => fs.readFileSync(f.directory + '/logs/share-attempts/' + file, 'utf8') === 'pending'));
    await service.shareEvidenceSnapshot(f.context, snap, meta, plan(), true); await tick(); await tick();
    assert.equal(f.control.requests.filter(request => request.options.method === 'POST').length, 2);
  } finally { f.close(); }
});

test('corrupt credential is visible without blocking valid records from revocation', async () => {
  const f = evidenceRuntime();
  try {
    const client = f.load('entry/src/main/ets/components/LogShareClient.ets');
    const record = { id: 'abc1234', url: 'https://logshare.cn/abc1234', token: 'fixture', sharedAt: 1, versionId: 'test' };
    await client.addShareRecord(f.context, record); f.write('logs/share-records/broken.json', '{bad');
    const history = await client.loadShareHistory(f.context);
    assert.equal(history.records.length, 1); assert.equal(history.warnings.length, 1);
    await assert.rejects(client.loadShareRecords(f.context), /部分分享凭据/);
    assert.equal((await client.revokeShare(f.context, record)).ok, true);
    assert.equal((await client.loadShareHistory(f.context)).records.length, 0);
    assert(fs.existsSync(f.directory + '/logs/share-records/broken.json'));
  } finally { f.close(); }
});

test('gzip preparation failure is classified locally and never creates a POST', async () => {
  const f = evidenceRuntime({ imports: { '@kit.BasicServicesKit': { zlib: { createGZipSync: () => ({
    gzopen: async () => { throw new Error('synthetic local compression failure'); }, gzclosew: async () => 0,
  }) } } } });
  try {
    const client = f.load('entry/src/main/ets/components/LogShareClient.ets');
    const result = await client.submitLog('synthetic '.repeat(6000), 'test');
    assert.equal(result.errorStage, 'local-prepare'); assert.equal(f.control.requests.filter(request => request.options.method === 'POST').length, 0);
    assert.doesNotMatch(result.error, /上传结果未知/);
  } finally { f.close(); }
});

test('SSE status exposes only coarse queue progress, never reasoning or tool payloads', () => {
  const Parser = makePureEtsLoader()('entry/src/main/ets/components/LogShareSse.ets').LogShareSseParser;
  const statuses = [], answers = [];
  const parser = new Parser({ onDelta: text => answers.push(text), onDone() {}, onError: error => { throw new Error(error); },
    onStatus: (...args) => statuses.push(args) });
  parser.feed('event: status\ndata: {"type":"queued","position":2}\n\n'
    + 'event: status\ndata: {"type":"thinking","delta":"PRIVATE_REASONING"}\n\n'
    + 'event: status\ndata: {"type":"tool","arguments":{"secret":"PRIVATE_ARGUMENT"}}\n\n'
    + 'data: {"choices":[{"delta":{"content":"公开结论"}}]}\n\nevent: done\ndata: {"status":"completed"}\n\n');
  assert.deepEqual(statuses, [['queued', 2], ['analyzing', 0], ['analyzing', 0]]);
  assert.deepEqual(answers, ['公开结论']);
});

test('AI HTTP errors preserve delayed JSON and Retry-After regardless of event order', async () => {
  for (const code of [404, 429]) {
    for (const bodyFirst of [false, true]) {
      const f = evidenceRuntime({ imports: { '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, createHttp: () => {
        const handlers = new Map();
        return { on: (name, callback) => handlers.set(name, callback), off: name => handlers.delete(name), destroy() {},
          requestInStream: async () => {
            handlers.get('headersReceive')?.({ 'content-type': 'application/json', 'retry-after': '45' });
            const body = () => { handlers.get('dataReceive')?.(new TextEncoder().encode(JSON.stringify({ code,
              error: code === 404 ? 'AI analysis is disabled.' : 'queue full' })).buffer); handlers.get('dataEnd')?.(); };
            if (bodyFirst) body(); else setTimeout(body, 5);
            return code;
          } };
      } } } } });
      try {
        const client = f.load('entry/src/main/ets/components/LogShareClient.ets'); let wait = 0;
        const error = await new Promise(resolve => client.streamAiAnalysis('abc1234', {
          onDelta() { throw new Error('HTTP 错误不得当正文'); }, onDone() { throw new Error('HTTP 错误不得成功'); },
          onRetryAfter: seconds => { wait = seconds; }, onError: resolve,
        }));
        if (code === 404) { assert.match(error, /AI 服务暂未开启/); assert.doesNotMatch(error, /日志不存在或已过期/); }
        else { assert.equal(wait, 45); assert.match(error, /45 秒/); }
      } finally { f.close(); }
    }
  }
});

test('identical selected bytes from different activities never reuse another activity receipt', async () => {
  const f = evidenceRuntime();
  try {
    const service = f.load('entry/src/main/ets/components/EvidenceShareService.ets');
    const first = snapshot(f); await service.shareEvidenceSnapshot(f.context, first, meta, plan()); await tick(); await tick();
    const second = { ...first, activityId: 8 }; f.control.id = f.control.urlId = 'another8';
    const result = await service.shareEvidenceSnapshot(f.context, second, meta, plan()); await tick(); await tick();
    assert.equal(result.activityId, 8); assert.equal(f.control.requests.filter(request => request.options.method === 'POST').length, 2);
  } finally { f.close(); }
});

test('late preview completion cannot reveal old rows or clear the current loading state', async () => {
  const resolvers = [];
  const p = component(['readPreview_']); Object.assign(p, { alive: true, previewGeneration: 0,
    previewModel: { loadEvidence: () => new Promise(resolve => resolvers.push(resolve)), totalCount: () => 0, hasNextPage: false } });
  const first = p.readPreview_({ name: 'one', path: 'one' });
  const second = p.readPreview_({ name: 'two', path: 'two' });
  resolvers[0](true); await first; assert.equal(p.previewReading, true); assert.equal(p.previewName, 'two');
  resolvers[1](true); await second; assert.equal(p.previewReading, false);
});

test('retrying a failed credential write cannot promote an unverified response into share success', async () => {
  const f = evidenceRuntime();
  try {
    const service = f.load('entry/src/main/ets/components/EvidenceShareService.ets');
    f.control.urlId = 'mismatched'; f.control.failWrite = name => name.includes('share-records');
    await assert.rejects(service.shareEvidenceSnapshot(f.context, snapshot(f), meta, plan()), error => error.stage === 'persist');
    f.control.failWrite = undefined;
    await assert.rejects(service.retryPendingEvidenceShare(f.context, 7), error => error.stage === 'verification');
    const client = f.load('entry/src/main/ets/components/LogShareClient.ets');
    assert.equal((await client.loadShareHistory(f.context)).records[0].accepted, false);
    assert.equal(f.control.requests.filter(request => request.options.method === 'POST').length, 1);
  } finally { f.close(); }
});

/**
 * 加速网关客户端的定向宿主回归：执行真实 RelayClient，替换平台 HTTP/密码/日志边界。
 * 覆盖 CDN 自检准入、坏响应、开关代次及资源销毁；不访问网络或真实用户偏好。
 * 定时器只登记在内存，不等待半小时续签；输出必须显式指定仓外路径，成功只留小收据。
 * 该回归不能替代 ArkTS SDK 编译、HAP 或真机网络验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, assertExternalOutputPath } from './lib/workspace-paths.mjs';

const args = process.argv.slice(2);
assert.ok(args.length === 2 || args.length === 4, '需要 --output <仓外收据目录> [--source-ref <真实旧commit>]');
assert.equal(args[0], '--output');
assert.ok(path.isAbsolute(args[1]));
const output = assertExternalOutputPath(args[1], { root: PROJECT_ROOT });
const sourcePath = path.join(PROJECT_ROOT, 'feature_core/src/main/ets/download/RelayClient.ets');
const sourceRef = args.length === 4 ? args[3] : '';
if (sourceRef) assert.equal(args[2], '--source-ref');
// 负控读取真实旧生产类；平台边界完全相同，旧代码必须在状态业务断言处失败。
const sourceBytes = sourceRef ? execFileSync('git', ['-C', PROJECT_ROOT, 'show',
  sourceRef + ':feature_core/src/main/ets/download/RelayClient.ets']) : fs.readFileSync(sourcePath);
const sourceSha256 = crypto.createHash('sha256').update(sourceBytes).digest('hex');
const startedAt = new Date().toISOString();
const compilation = compiler.transpileModule(sourceBytes.toString('utf8'), { fileName: sourcePath,
  reportDiagnostics: true, compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } });
assert.equal((compilation.diagnostics ?? []).filter(item => item.category === compiler.DiagnosticCategory.Error).length, 0);
const device = { deviceId: 'relay-test-device', appVersionCode: 1000910, appVersionName: 'test',
  model: 'host', osVersion: 'host', abi: 'arm64-v8a' };
const ticket = 'synthetic-test-ticket', sessionKey = 'synthetic-test-session-key';
const session = (overrides = {}) => ({ ticket, sessionKey, requireProof: true, expiresIn: 1800, ...overrides });
const response = (data, code = 200) => ({ responseCode: code, result: JSON.stringify(data) });
const verified = () => response({ ok: true, deviceId: device.deviceId });
const passed = [];

/** 每个场景独立加载生产类；HTTP 队列按调用次序返回，不复制客户端业务判定。 */
function harness(replies) {
  const calls = [], requests = [], configured = [], logs = [], timers = new Map();
  let allow = true, cleared = 0, timerId = 0, clock = Date.now(), failStats = false;
  const nativeState = { requests: 0, failures: 0, fallbacks: 0, authRejects: 0, tripped: false, usable: false };
  class Clock extends Date { static now() { return clock; } }
  const http = { RequestMethod: { POST: 'POST', GET: 'GET' }, HttpDataType: { STRING: 'STRING' },
    createHttp() {
      const request = { destroyed: false, destroy() { this.destroyed = true; }, async request(url, options) {
        calls.push({ url, options });
        assert.ok(replies.length > 0, '发生计划外 HTTP 请求');
        const reply = replies.shift();
        return typeof reply === 'function' ? await reply() : reply;
      } };
      requests.push(request);
      return request;
    } };
  const bridge = { configure(...values) { configured.push(values); nativeState.usable = true; nativeState.tripped = false; },
    clear() { cleared++; nativeState.usable = false; },
    stats() { if (failStats) throw Error('controlled native stats error');
      return { ...nativeState, accidentalPrivateField: sessionKey }; } };
  // 使用 Node 密码实现平台的同步接口。buffer 返回独立字节，避免 Node slab 改变摘要输入。
  const cryptoFramework = { createRandom: () => ({ generateRandomSync: length => ({ data: crypto.randomBytes(length) }) }),
    createMd: algorithm => { const digest = crypto.createHash(algorithm.toLowerCase().replace('-', ''));
      return { updateSync: blob => digest.update(blob.data), digestSync: () => ({ data: digest.digest() }) }; },
    createSymKeyGenerator: () => ({ convertKeySync: blob => blob.data }),
    createMac: () => { let mac; return { initSync: key => { mac = crypto.createHmac('sha256', key); },
      updateSync: blob => mac.update(blob.data), doFinalSync: () => ({ data: mac.digest() }) }; } };
  const dependencies = { commons: { DistributionPolicy: { allowPublisherServices: () => allow },
    AppLogger: Object.fromEntries(['info', 'warn', 'error'].map(level => [level, (...values) => logs.push(values)])),
    LOG_DOMAIN_DOWNLOAD: 1 }, '@kit.NetworkKit': { http }, '@kit.CryptoArchitectureKit': { cryptoFramework },
    '@kit.ArkTS': { buffer: { from: (...values) => ({ buffer: Uint8Array.from(Buffer.from(...values)).buffer }) } },
    './RelayNativeBridge': { getRelayNativeBridge: () => bridge } };
  const module = { exports: {} };
  const context = vm.createContext({ module, exports: module.exports, require(name) {
    assert.ok(Object.hasOwn(dependencies, name), '平台依赖必须显式替换'); return dependencies[name]; },
    setTimeout: (callback, delay) => { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id), Date: Clock });
  new vm.Script(compilation.outputText, { filename: 'RelayClient.host.js' }).runInContext(context);
  const client = new module.exports.RelayClient();
  client.setDeviceInfo(device);
  return { client, calls, requests, configured, logs, timers, exports: module.exports,
    denyPublisher: () => { allow = false; }, cleared: () => cleared,
    nativeState, setStatsFailure: value => { failStats = value; },
    fireRenew() { assert.equal(timers.size, 1); const [id, timer] = timers.entries().next().value;
      timers.delete(id); clock += timer.delay + 1; timer.callback(); },
    checkClosed() { assert.ok(requests.every(request => request.destroyed), '所有 HTTP 句柄必须销毁');
      const logged = JSON.stringify(logs); assert.ok(!logged.includes(ticket) && !logged.includes(sessionKey), '凭据不能进入日志'); } };
}

/** 手动挂起 HTTP 边界，使关闭/重开能发生在真实 await 之间。 */
function deferred() { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; }
async function settle() { for (let i = 0; i < 12; i++) await Promise.resolve(); }
async function test(name, action) { await action(); passed.push(name); console.log('PASS ' + name); }

try {
  await test('新域名握手和同入口自检通过后才注入 native，所有请求禁用缓存', async () => {
    const h = harness([response(session({ base: 'https://untrusted.invalid/dl' })), verified()]);
    assert.equal(await h.client.setEnabled(true), true);
    assert.equal(h.configured.length, 1);
    assert.equal(h.configured[0][0], 'https://relay.amcl.lovedhy.cn/dl');
    assert.equal(h.calls.length, 2);
    assert.equal(h.calls[1].url, h.exports.RELAY_BASE + '/api/v1/session/verify');
    for (const { options, url } of h.calls) { assert.ok(url.startsWith(h.exports.RELAY_BASE + '/'));
      assert.equal(options.usingCache, false); assert.equal(options.header['Cache-Control'], 'no-store');
      assert.equal(options.maxLimit, 16384); assert.equal(options.expectDataType, 'STRING'); }
    assert.equal(h.calls[1].options.header.Authorization, 'Bearer ' + ticket);
    assert.equal(h.client.status().active, true);
    assert.equal(await h.client.ensureSession(), true);
    assert.equal(h.calls.length, 2, '有效会话直接复用'); h.checkClosed();
  });
  await test('CDN 票据 IP 不匹配时保持直连并给出可诊断原因', async () => {
    const h = harness([response(session()), response({ error: 'ticket_ip_mismatch' }, 401)]);
    assert.equal(await h.client.setEnabled(true), false); assert.equal(h.configured.length, 0);
    assert.match(h.client.status().lastError, /IP/); assert.equal(h.client.status().active, false); h.checkClosed();
  });
  await test('自检的错误设备、伪成功、HTML 错误页和网络异常均不能激活', async () => {
    for (const reply of [response({ ok: true, deviceId: 'different-device' }), response({ ok: false }),
      { responseCode: 200, result: '<html>edge error</html>' }, () => Promise.reject(new Error('transport failed'))]) {
      const h = harness([response(session()), reply]); assert.equal(await h.client.setEnabled(true), false);
      assert.equal(h.configured.length, 0); h.checkClosed();
    }
  });
  await test('无效凭据及缺失、负数、非数值或过短有效期在自检前拒绝', async () => {
    for (const data of [session({ ticket: 42 }), session({ ticket: 'a'.repeat(4097) }), session({ ticket: 'bad\r\nticket' }),
      session({ sessionKey: 'bad\nkey' }), session({ sessionKey: '' }), session({ requireProof: 'yes' }),
      session({ expiresIn: undefined }), session({ expiresIn: -1 }), session({ expiresIn: '1800' }), session({ expiresIn: 20 })]) {
      const h = harness([response(data)]); assert.equal(await h.client.setEnabled(true), false);
      assert.equal(h.calls.length, 1); assert.equal(h.configured.length, 0); h.checkClosed();
    }
  });
  await test('设备时钟偏差提示校准且不会自动重签循环', async () => {
    const h = harness([response({ error: 'ts_out_of_window', serverTime: Date.now() }, 401)]);
    assert.equal(await h.client.setEnabled(true), false); assert.match(h.client.status().lastError, /校准系统时间/);
    assert.equal(h.calls.length, 1); h.checkClosed();
  });
  await test('关闭发生在 CDN 自检期间时迟到成功不能重新配置', async () => {
    const pending = deferred(), h = harness([response(session()), () => pending.promise]);
    const enabling = h.client.setEnabled(true); await settle(); assert.equal(h.calls.length, 2);
    await h.client.setEnabled(false); pending.resolve(verified()); assert.equal(await enabling, false);
    assert.equal(h.configured.length, 0); assert.equal(h.client.status().active, false); h.checkClosed();
  });
  await test('握手期间关闭后迟到成功不再发送自检或配置 native', async () => {
    const pending = deferred(), h = harness([() => pending.promise]);
    const enabling = h.client.setEnabled(true); await settle(); await h.client.setEnabled(false);
    pending.resolve(response(session())); assert.equal(await enabling, false);
    assert.equal(h.calls.length, 1); assert.equal(h.configured.length, 0); h.checkClosed();
  });
  await test('重开后旧自检失败不能清除新票据或新续签定时器', async () => {
    const pending = deferred(), h = harness([response(session()), () => pending.promise, response(session()), verified()]);
    const old = h.client.setEnabled(true); await settle(); await h.client.setEnabled(false);
    assert.equal(await h.client.setEnabled(true), true); const clears = h.cleared();
    pending.resolve(response({ error: 'ticket_ip_mismatch' }, 401)); assert.equal(await old, false);
    assert.equal(h.cleared(), clears); assert.equal(h.client.status().active, true); assert.equal(h.timers.size, 1); h.checkClosed();
  });
  await test('并发调用复用握手和自检，产品策略拒绝时不发请求', async () => {
    const pending = deferred(), h = harness([() => pending.promise, verified()]);
    const a = h.client.setEnabled(true), b = h.client.ensureSession(); pending.resolve(response(session()));
    assert.equal(await a, true); assert.equal(await b, true); assert.equal(h.calls.length, 2); h.checkClosed();
    const denied = harness([]); denied.denyPublisher(); assert.equal(await denied.client.setEnabled(true), false);
    assert.equal(denied.calls.length, 0); denied.checkClosed();
  });
  await test('Native熔断与恢复由真实状态投影，不以有效票据或初次握手冒充可用', async () => {
    const h = harness([response(session()), verified()]); await h.client.setEnabled(true);
    h.nativeState.usable = false; h.nativeState.tripped = true;
    assert.equal(h.client.status().active, false, '真实旧实现即使Native已熔断仍会错误返回active=true');
    assert.equal(h.client.status().sessionReady, true); assert.equal(h.client.status().usable, false);
    assert.equal(h.client.status().tripped, true); assert.match(h.exports.relayStatusText(h.client.status()), /熔断/);
    const observations = []; const unsubscribe = h.client.subscribeStatus(state => observations.push(state));
    h.nativeState.usable = true; h.nativeState.tripped = false; h.client.refreshStatus();
    assert.equal(observations.at(-1).usable, true); assert.equal(h.exports.relayStatusText(observations.at(-1)), 'ok');
    assert.equal(h.calls.length, 2, '采样只读状态，不能发HTTP或重试下载');
    assert.ok(!JSON.stringify(observations).includes(sessionKey), 'Native额外字段不能进入公开投影');
    unsubscribe(); const count = observations.length; await h.client.setEnabled(false);
    assert.equal(observations.length, count); h.checkClosed();
  });
  await test('订阅故障隔离、独立快照与Native查询失败均不能伪造就绪', async () => {
    const h = harness([response(session()), verified()]); await h.client.setEnabled(true);
    const states = [];
    const one = h.client.subscribeStatus(state => { state.usable = false; state.native.usable = false; throw Error('consumer only'); });
    const two = h.client.subscribeStatus(state => states.push(state));
    h.client.refreshStatus(); assert.equal(states.at(-1).usable, true); assert.equal(states.at(-1).native.usable, true);
    h.setStatsFailure(true); h.client.refreshStatus();
    assert.equal(states.at(-1).usable, false); assert.equal(states.at(-1).native, null);
    assert.match(h.exports.relayStatusText(states.at(-1)), /引擎/);
    one(); two(); h.checkClosed();
  });
  await test('自动续签失败撤销ready并通知，随后显式会话恢复重新发布成功', async () => {
    const h = harness([response(session()), verified(), () => Promise.reject(Error('renew failed')), response(session()), verified()]);
    const states = []; const unsubscribe = h.client.subscribeStatus(state => states.push(state));
    assert.equal(await h.client.setEnabled(true), true); assert.equal(states.at(-1).usable, true);
    h.fireRenew(); await settle();
    assert.equal(h.client.status().usable, false); assert.equal(states.at(-1).usable, false);
    assert.equal(states.at(-1).connecting, false); assert.match(h.exports.relayStatusText(states.at(-1)), /无法连接/);
    assert.equal(h.timers.size, 0, '失败不全局重试下载或无限重新握手');
    assert.equal(await h.client.ensureSession(), true); assert.equal(states.at(-1).usable, true);
    assert.equal(h.calls.length, 5); unsubscribe(); h.checkClosed();
  });
  if (!sourceRef) assert.equal(crypto.createHash('sha256').update(fs.readFileSync(sourcePath)).digest('hex'), sourceSha256, '测试期间源文件必须稳定');
} finally {
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'result-' + process.pid + '.json'), JSON.stringify({ startedAt,
    endedAt: new Date().toISOString(), sourcePath, sourceRef: sourceRef || 'current-worktree', sourceSha256, passed, expectedGroups: 12,
    complete: passed.length === 12, scope: '真实客户端宿主行为；平台边界替换；不代表 SDK/HAP/真机验证',
    fixtures: 'memory-only; no child processes or on-disk fixtures' }, null, 2) + '\n');
}

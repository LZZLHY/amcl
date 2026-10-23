/**
 * 源探测/Relay的真实生产生命周期回归，仅替换HTTP、密码接口及续签timer。
 * 请求结果由deferred主动释放，覆盖旧结果发布权；不访问公网、不生成真实授权。
 */
import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { loader } from '../../scripts/mod-install-test-runtime.mjs';

const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const log = { info() {}, warn() {}, error() {} };
const common = { AppLogger: log, LOG_DOMAIN_DOWNLOAD: 0,
  BMCLAPI_BASE: 'https://mirror.invalid', MOJANG_RESOURCES: 'https://official.invalid' };

export async function runDownloadSourceLifecycleRegression() {
  const cases = [];
  {
    const calls = [];
    const load = loader({ commons: common, './DownloadManager': { DownloadManager: { instance: () => ({
      fetchTextEx(url) { const call = deferred(); calls.push({ url, ...call }); return call.promise; },
    }) } } });
    const source = load('feature_core/src/main/ets/download/SourceProber.ets');
    const first = source.ensureRanking(), same = source.ensureRanking();
    assert.equal(calls.length, 2, '同代次多消费者只启动一对真实探测');
    source.setMcSourcePreference('official');
    calls.slice(0, 2).forEach(call => call.resolve({ statusCode: 200 }));
    await Promise.all([first, same]);
    assert.equal(source.getCachedRanking(), null);
    assert.equal((await source.ensureRanking()).bmclapiFirst, false);
    source.setMcSourcePreference('auto');
    const old = source.ensureRanking(); source.clearCache(); const current = source.ensureRanking();
    assert.equal(calls.length, 6);
    calls.slice(2, 4).forEach(call => call.resolve({ statusCode: 200 })); await old;
    const sharedCurrent = source.ensureRanking(); assert.equal(calls.length, 6, '旧finally不能清掉新inflight');
    calls.slice(4, 6).forEach(call => call.resolve({ statusCode: 200 }));
    const [ranking] = await Promise.all([current, sharedCurrent]);
    assert.equal(source.getCachedRanking(), ranking);
    cases.push('MC probe in-flight deduplication and preference/cache generation reject stale publication');
  }
  {
    const calls = []; let destroyed = 0;
    const load = loader({ commons: common, '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' },
      createHttp() { return { request(url) { const call = deferred(); calls.push({ url, ...call }); return call.promise; },
        destroy() { destroyed++; } }; },
    } } });
    const source = load('mods/src/main/ets/ModSourceProber.ets');
    const old = source.ensureModrinthRanking(); const current = source.refreshModrinthRanking();
    assert.equal(calls.length, 4);
    calls.slice(0, 2).forEach(call => call.resolve({ responseCode: 200 })); await old;
    assert.equal(source.getCachedModRanking(), null);
    const same = source.ensureModrinthRanking(); assert.equal(calls.length, 4);
    calls.slice(2, 4).forEach(call => call.resolve({ responseCode: 200 }));
    const [ranking] = await Promise.all([current, same]); assert.equal(source.getCachedModRanking(), ranking);
    assert.equal(destroyed, 4);
    cases.push('Mod source refresh rejects old cache and old request cleanup cannot clear new in-flight work');
  }
  {
    const calls = [], configured = [], timers = new Map(); let cleared = 0, destroyed = 0, nextTimer = 0, allowed = true;
    const bytes = () => ({ data: new Uint8Array(32) });
    const load = loader({ commons: { ...common, DistributionPolicy: { allowPublisherServices: () => allowed } },
      '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' }, createHttp() { return {
        request() { const call = deferred(); calls.push(call); return call.promise; }, destroy() { destroyed++; },
      }; } } },
      '@kit.CryptoArchitectureKit': { cryptoFramework: {
        createRandom: () => ({ generateRandomSync: bytes }),
        createMd: () => ({ updateSync() {}, digestSync: bytes }),
        createSymKeyGenerator: () => ({ convertKeySync: () => ({}) }),
        createMac: () => ({ initSync() {}, updateSync() {}, doFinalSync: bytes }),
      } },
      '@kit.ArkTS': { buffer: { from: text => Buffer.from(text) }, util: {} },
      './RelayNativeBridge': { getRelayNativeBridge: () => ({ configure(...args) { configured.push(args); },
        clear() { cleared++; }, stats: () => null }) },
    }, { setTimeout(fn) { const id = ++nextTimer; timers.set(id, fn); return id; }, clearTimeout(id) { timers.delete(id); } });
    const { RelayClient } = load('feature_core/src/main/ets/download/RelayClient.ets');
    const relay = new RelayClient();
    relay.setDeviceInfo({ deviceId: 'fixture', appVersionCode: 1, appVersionName: 'fixture', model: 'fixture', osVersion: 'fixture', abi: 'fixture' });
    const first = relay.setEnabled(true); assert.equal(calls.length, 1);
    await relay.setEnabled(false);
    const success = ticket => ({ responseCode: 200, result: JSON.stringify({ ticket, sessionKey: 'fixture-key', expiresIn: 1800 }) });
    calls[0].resolve(success('stale')); assert.equal(await first, false);
    assert.equal(configured.length, 0); assert.equal(relay.status().active, false); assert.equal(timers.size, 0);
    const old = relay.setEnabled(true); await relay.setEnabled(false); const current = relay.setEnabled(true);
    calls[2].resolve(success('current')); assert.equal(await current, true); const clearBeforeOld = cleared;
    calls[1].resolve({ responseCode: 503, result: '{}' }); assert.equal(await old, false);
    assert.equal(cleared, clearBeforeOld); assert.equal(relay.status().active, true);
    assert.equal(configured.length, 1); assert.equal(timers.size, 1); assert.equal(destroyed, 3);
    allowed = false; await relay.setEnabled(true); assert.equal(relay.status().active, false);
    assert.equal(calls.length, 3); assert.equal(timers.size, 0);
    cases.push('Relay disable/re-enable and product policy revoke stale handshake publication without touching newer session');
  }
  return cases;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const cases = await runDownloadSourceLifecycleRegression(); console.log(JSON.stringify({ cases, count: cases.length }, null, 2));
}

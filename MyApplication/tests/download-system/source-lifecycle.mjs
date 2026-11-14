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
    // 在途官方和镜像独立收口；切严格来源后，旧镜像不能发布到新消费者。
    const calls = [], timers = new Map(); let nextTimer = 0;
    const load = loader({ commons: common }, { setTimeout(fn) { const id = ++nextTimer; timers.set(id, fn); return id; },
      clearTimeout(id) { timers.delete(id); } });
    const source = load('feature_core/src/main/ets/download/SourceProber.ets');
    const official = deferred(), mirror = deferred();
    const first = source.fetchMcVersionListSources(() => { calls.push('official'); return official.promise; },
      () => { calls.push('mirror'); return mirror.promise; });
    assert.deepEqual(calls, ['official']);
    [...timers.values()].forEach(run => run());
    assert.deepEqual(calls, ['official', 'mirror']);
    source.setMcSourcePreference('official');
    mirror.resolve('old-mirror'); official.resolve('valid-official');
    assert.equal(await first, 'valid-official');
    assert.equal(timers.size, 0);
    source.setMcSourcePreference('auto');
    const current = source.fetchMcVersionListSources(async () => 'new-official',
      async () => { throw new Error('settled official may not open mirror'); });
    assert.equal(await current, 'new-official');
    assert.equal(timers.size, 0);
    cases.push('MC delayed mirror cannot publish after source changes and successful official cleans timer');
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
    const calls = [], verifications = [], configured = [], timers = new Map(); let cleared = 0, destroyed = 0, nextTimer = 0, allowed = true, nativeUsable = false;
    const bytes = () => ({ data: new Uint8Array(32) });
    const load = loader({ commons: { ...common, DistributionPolicy: { allowPublisherServices: () => allowed } },
      '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST', GET: 'GET' }, HttpDataType: { STRING: 'string' }, createHttp() { return {
        request(url,options) {
          // 当前真实生产协议在握手后还做同入口GET自检；只有本例新一代票据可到达此边界。
          // 保留握手deferred用于控制旧回包顺序，自检另行计数，不能把它吞掉或算成旧请求。
          if(url.endsWith('/api/v1/session/verify')) {
            assert.equal(options.method,'GET');verifications.push(url);
            return Promise.resolve({responseCode:200,result:JSON.stringify({ok:true,deviceId:'fixture'})});
          }
          const call = deferred(); calls.push(call); return call.promise;
        }, destroy() { destroyed++; },
      }; } } },
      '@kit.CryptoArchitectureKit': { cryptoFramework: {
        createRandom: () => ({ generateRandomSync: bytes }),
        createMd: () => ({ updateSync() {}, digestSync: bytes }),
        createSymKeyGenerator: () => ({ convertKeySync: () => ({}) }),
        createMac: () => ({ initSync() {}, updateSync() {}, doFinalSync: bytes }),
      } },
      '@kit.ArkTS': { buffer: { from: text => Buffer.from(text) }, util: {} },
      './RelayNativeBridge': { getRelayNativeBridge: () => ({ configure(...args) { configured.push(args); nativeUsable = true; },
        clear() { cleared++; nativeUsable = false; },
        stats: () => ({ requests: 0, failures: 0, fallbacks: 0, authRejects: 0, tripped: false, usable: nativeUsable }) }) },
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
    calls[2].resolve(success('current')); const currentReady = await current;
    assert.equal(currentReady, true, JSON.stringify(relay.status())); const clearBeforeOld = cleared;
    calls[1].resolve({ responseCode: 503, result: '{}' }); assert.equal(await old, false);
    assert.equal(cleared, clearBeforeOld); assert.equal(relay.status().active, true);
    assert.equal(configured.length, 1); assert.equal(timers.size, 1); assert.equal(verifications.length,1);assert.equal(destroyed, 4);
    nativeUsable = false;
    assert.equal(relay.status().sessionReady, true); assert.equal(relay.status().active, false, '握手票据不能替代Native可用性');
    nativeUsable = true;
    allowed = false; await relay.setEnabled(true); assert.equal(relay.status().active, false);
    assert.equal(calls.length, 3); assert.equal(timers.size, 0);
    cases.push('Relay disable/re-enable and product policy revoke stale handshake publication without touching newer session');
  }
  return cases;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const cases = await runDownloadSourceLifecycleRegression(); console.log(JSON.stringify({ cases, count: cases.length }, null, 2));
}

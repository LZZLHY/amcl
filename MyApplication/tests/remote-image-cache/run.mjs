/**
 * 远程图片资源回归：直接转译并执行生产 .ets 策略/缓存，用可控 SDK 边界替身
 * 验证共享租约、取消、容量、限流、原图兼容和失败释放。无需设备，不生成项目内
 * 中间文件；--typescript 必须指向已安装 SDK 的 TypeScript 包，输出由调用方外置。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const tsPath = process.argv[process.argv.indexOf('--typescript') + 1];
if (!tsPath || !process.argv.includes('--typescript')) throw new Error('需要 --typescript <SDK TypeScript 包路径>');
const ts = require(path.resolve(tsPath));
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const sourceDir = path.join(root, 'commons/src/main/ets/common');
let passed = 0;

/** 使用真实生产代码，仅将不可在宿主执行的 HarmonyOS SDK 模块替换为可观测边界。 */
function loadEts(name, imports = {}) {
  const source = fs.readFileSync(path.join(sourceDir, name + '.ets'), 'utf8');
  const out = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  const exports = {};
  const resolveImport = id => {
    if (!(id in imports)) throw new Error('未提供 SDK 边界替身: ' + id);
    return imports[id];
  };
  new Function('exports', 'require', out.outputText)(exports, resolveImport);
  return exports;
}

/** 每项独立打印真实断言结果；失败立即使进程非零退出。 */
async function check(name, run) {
  await run();
  passed++;
  process.stdout.write('PASS ' + name + '\n');
}

/** 无计时假设的手动门闩，用来观测真实队列的同时运行数量和取消顺序。 */
function latch() {
  let open;
  const promise = new Promise(resolve => { open = resolve; });
  return { promise, open };
}

/** 给 Promise 完成链推进机会，不使用 sleep 猜测并发工作是否已发生。 */
async function settle() { for (let i = 0; i < 16; i++) await Promise.resolve(); }

const policy = loadEts('RemoteImagePolicy');
await check('退休回调成功注册但永不 idle 时有界取消 pin，迟到 idle 不误释放', async () => {
  let released = 0;
  let handedToGc = 0;
  const guard = new policy.RemoteImageRetirementGuard({
    release() { released++; }, releaseToGc() { handedToGc++; },
  }, 5);
  // 不调用 onIdle，模拟注册成功但停帧/无空闲；等待另一个更晚的 timer 保证兜底已派发。
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(handedToGc, 1);
  assert.equal(released, 0);
  // 直接核实生产守卫已移除 payload 强引用：迟到回调仍持有 guard 时也不能保留旧位图。
  assert.equal(guard.lease_, null);
  guard.onIdle(); guard.onIdle(); guard.releaseToGc();
  assert.equal(handedToGc, 1);
  assert.equal(released, 0);
});
await check('正常 idle 完成退休并取消 timer，之后不再降级 GC', async () => {
  let released = 0;
  let handedToGc = 0;
  const guard = new policy.RemoteImageRetirementGuard({
    release() { released++; }, releaseToGc() { handedToGc++; },
  }, 5);
  guard.onIdle(); guard.onIdle();
  assert.equal(guard.lease_, null, '正常退休先移除守卫的 payload 引用');
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(released, 1);
  assert.equal(handedToGc, 0);
});
await check('注册失败立即仅交 GC 并清 timer，后续 idle 不误释放', async () => {
  let released = 0;
  let handedToGc = 0;
  const guard = new policy.RemoteImageRetirementGuard({
    release() { released++; }, releaseToGc() { handedToGc++; },
  }, 5);
  guard.releaseToGc();
  assert.equal(guard.lease_, null, '注册失败也必须立即脱开 payload 引用');
  await new Promise(resolve => setTimeout(resolve, 20));
  guard.onIdle();
  assert.equal(released, 0);
  assert.equal(handedToGc, 1);
});
await check('资源操作重入或抛错前已脱开 payload，迟到回调保持幂等', async () => {
  // 分别覆盖正常 idle 和主动 GC 退化；只读编译后字段验证所有权，不依赖 GC 回收时序。
  for (const gcFallback of [false, true]) {
    let calls = 0;
    let guard;
    const release = () => {
      calls++;
      assert.equal(guard.lease_, null, '外部资源回调执行前必须先清空守卫引用');
      guard.onIdle();
      guard.releaseToGc();
      throw new Error('injected resource release failure');
    };
    guard = new policy.RemoteImageRetirementGuard({ release, releaseToGc: release }, 5);
    assert.throws(() => gcFallback ? guard.releaseToGc() : guard.onIdle(), /injected resource release failure/);
    assert.equal(guard.lease_, null);
    await new Promise(resolve => setTimeout(resolve, 20));
    guard.onIdle(); guard.releaseToGc();
    assert.equal(calls, 1);
  }
});
await check('缩略尺寸保持比例、不放大并钳制输出长边', () => {
  assert.deepEqual(policy.remoteImageDecodeSize(1024, 512, 128), { width: 128, height: 64 });
  assert.deepEqual(policy.remoteImageDecodeSize(8, 16, 256), { width: 8, height: 16 });
  assert.deepEqual(policy.remoteImageDecodeSize(1024, 512, 900), { width: 256, height: 128 });
});
await check('坏图/像素炸弹拒绝，原图像素几何保留', () => {
  for (const size of [[0, 1], [-1, 2], [NaN, 2], [1.5, 2], [8192, 8192]]) {
    assert.equal(policy.remoteImageDecodeSize(...size, 128), null);
  }
  assert.deepEqual(policy.remoteImageDecodeSize(64, 32, 0), { width: 64, height: 32 });
  assert.equal(policy.remoteImageDecodeSize(4096, 64, 0), null);
});
await check('LRU 同时限制字节/数量且只淘汰无人租用项', () => {
  const dropped = [];
  const cache = new policy.RemoteImageMemoryCache(10, 2, value => dropped.push(value));
  const pinned = cache.put('a', 'a', 4, 1);
  cache.put('b', 'b', 4);
  assert.ok(cache.put('c', 'c', 4));
  assert.deepEqual(dropped, ['b']);
  assert.equal(cache.put('too-big', 'no', 11), null);
  cache.unpin(pinned);
  cache.get('c');
  cache.put('d', 'd', 6);
  assert.deepEqual(dropped, ['b', 'a']);
  assert.equal(cache.retainedBytes(), 10);
  assert.equal(cache.retainedCount(), 2);
});
await check('全 pin 容量不足时拒绝新项，旧消费者仍有效', () => {
  const dropped = [];
  const cache = new policy.RemoteImageMemoryCache(8, 2, value => dropped.push(value));
  cache.put('a', 'a', 4, 2);
  cache.put('b', 'b', 4, 1);
  assert.equal(cache.put('c', 'c', 1), null);
  assert.deepEqual(dropped, []);
  assert.equal(cache.retainedBytes(), 8);
});
await check('UIContext 无效的条目只丢强引用，绝不显式销毁', () => {
  let disposed = 0;
  const cache = new policy.RemoteImageMemoryCache(4, 1, () => { disposed++; });
  const old = cache.put('a', {}, 4, 1);
  old.disposeAllowed = false;
  cache.unpin(old);
  cache.put('b', {}, 4);
  assert.equal(disposed, 0);
});
await check('队列限制实际并发和等候数，失败仍继续派发', async () => {
  const queue = new policy.RemoteImageTaskQueue(2, 2);
  const gates = [latch(), latch(), latch(), latch()];
  let active = 0;
  let peak = 0;
  const work = index => queue.run(async () => {
    active++;
    peak = Math.max(peak, active);
    await gates[index].promise;
    active--;
    if (index === 0) throw new Error('bad image');
    return index;
  });
  const jobs = [work(0), work(1), work(2), work(3)];
  assert.equal(await queue.run(async () => 99), null);
  assert.equal(active, 2);
  gates[0].open(); gates[1].open();
  await settle();
  assert.equal(active, 2);
  gates[2].open(); gates[3].open();
  assert.deepEqual(await Promise.all(jobs), [null, 1, 2, 3]);
  assert.equal(peak, 2);
});

/**
 * SDK 替身保留网络/解码异步边界，并记录每次 options、PixelMap/source 释放。
 * 不宣称这些替身能证明系统解码器实际峰值，只证明生产调度和清理路径被执行。
 */
function imageHarness({ width = 1024, height = 512, failDecode = false, gate = null } = {}) {
  const state = { requests: [], destroys: 0, sourcesReleased: 0, maps: [], decoded: 0 };
  const sdkImage = {
    PixelMapFormat: { RGBA_8888: 3 },
    createImageSource() {
      return {
        async getImageInfo() { return { size: { width, height } }; },
        async createPixelMap(options) {
          state.decoded++;
          if (failDecode) throw new Error('invalid compressed pixels');
          const size = options.desiredSize;
          const map = { size, released: 0, getPixelBytesNumber() { return size.width * size.height * 4; },
            async release() { this.released++; } };
          state.maps.push(map);
          return map;
        },
        async release() { state.sourcesReleased++; },
      };
    },
  };
  const http = { RequestMethod: { GET: 1 }, HttpDataType: { ARRAY_BUFFER: 1 }, createHttp() {
    return { async request(url, options) {
      state.requests.push({ url, options });
      if (gate) await gate.promise;
      return { responseCode: 200, result: new ArrayBuffer(32) };
    }, destroy() { state.destroys++; } };
  } };
  globalThis.AppStorage = { get() { return undefined; } };
  const api = loadEts('RemoteImageCache', {
    './DiagnosticPolicy': { DiagnosticPolicy: { isDeveloperBuild() { return false; } } },
    './RemoteImagePolicy': policy,
    '@kit.NetworkKit': { http }, '@kit.ImageKit': { image: sdkImage },
    '@kit.PerformanceAnalysisKit': { hilog: { debug() {}, warn() {} } },
    '@kit.CoreFileKit': { fileIo: {} }, '@kit.AbilityKit': { common: {} },
  });
  return { api, state };
}

await check('相同 URL/规格仅获取一次，单消费者取消不影响共享者', async () => {
  const gate = latch();
  const { api, state } = imageHarness({ gate });
  const cancelled = new api.RemoteImageLoadToken();
  const live = new api.RemoteImageLoadToken();
  const first = api.acquireRemotePixelMap('https://test/icon', 128, cancelled);
  const second = api.acquireRemotePixelMap('https://test/icon', 128, live);
  await settle();
  cancelled.cancel(); gate.open();
  assert.equal(await first, null);
  const lease = await second;
  assert.ok(lease);
  assert.deepEqual(lease.pixelMap.size, { width: 128, height: 64 });
  assert.equal(state.requests.length, 1);
  assert.equal(state.requests[0].options.maxLimit, 2 * 1024 * 1024);
  assert.equal(state.sourcesReleased, 1);
  assert.equal(state.destroys, 1);
  lease.release(); lease.release();
  assert.equal(lease.pixelMap.released, 0);
});
await check('所有消费者取消后跳过网络后的解码', async () => {
  const gate = latch();
  const { api, state } = imageHarness({ gate });
  const token = new api.RemoteImageLoadToken();
  const task = api.acquireRemotePixelMap('https://test/cancel', 128, token);
  await settle(); token.cancel(); gate.open();
  assert.equal(await task, null);
  assert.equal(state.decoded, 0);
  assert.equal(state.destroys, 1);
});
await check('出队前取消的任务不再发起 HTTP', async () => {
  const gate = latch();
  const { api, state } = imageHarness({ gate });
  const tasks = Array.from({ length: 4 }, (_, index) => api.acquireRemotePixelMap(
    'https://test/running-' + index, 128, new api.RemoteImageLoadToken()));
  const token = new api.RemoteImageLoadToken();
  const stale = api.acquireRemotePixelMap('https://test/stale', 128, token);
  await settle();
  assert.equal(state.requests.length, 4);
  token.cancel(); gate.open();
  for (const lease of await Promise.all(tasks)) lease.release();
  assert.equal(await stale, null);
  assert.equal(state.requests.length, 4);
});
await check('坏图解码失败依然释放 ImageSource/HttpRequest', async () => {
  const { api, state } = imageHarness({ failDecode: true });
  assert.equal(await api.acquireRemotePixelMap('https://test/bad', 128, new api.RemoteImageLoadToken()), null);
  assert.equal(state.sourcesReleased, 1);
  assert.equal(state.destroys, 1);
});
await check('源图超像素预算时不调用 createPixelMap，仍释放 ImageSource', async () => {
  const { api, state } = imageHarness({ width: 8192, height: 8192 });
  assert.equal(await api.acquireRemotePixelMap('https://test/bomb', 128, new api.RemoteImageLoadToken()), null);
  assert.equal(state.decoded, 0);
  assert.equal(state.sourcesReleased, 1);
});
await check('相同 URL 的原图和图标保持不同像素规格', async () => {
  const { api, state } = imageHarness();
  const raw = await api.getRemotePixelMap('https://test/texture');
  const small = await api.acquireRemotePixelMap('https://test/texture', 128, new api.RemoteImageLoadToken());
  assert.deepEqual(raw.size, { width: 1024, height: 512 });
  assert.deepEqual(small.pixelMap.size, { width: 128, height: 64 });
  assert.notEqual(raw, small.pixelMap);
  assert.equal(state.requests[0].options.maxLimit, 8 * 1024 * 1024);
  small.release();
});
await check('真实缓存到预算上限后 fallback，归还一个租约即可安全替换', async () => {
  const { api, state } = imageHarness({ width: 256, height: 256 });
  const leases = [];
  for (let i = 0; i < 64; i++) {
    leases.push(await api.acquireRemotePixelMap('https://test/budget-' + i, 256, new api.RemoteImageLoadToken()));
  }
  assert.ok(leases.every(Boolean));
  assert.equal(await api.acquireRemotePixelMap('https://test/overflow', 256, new api.RemoteImageLoadToken()), null);
  assert.equal(state.maps[64].released, 1);
  assert.ok(leases.every(lease => lease.pixelMap.released === 0));
  leases[0].release(); leases[0].release();
  const replacement = await api.acquireRemotePixelMap('https://test/overflow', 256, new api.RemoteImageLoadToken());
  assert.ok(replacement);
  assert.equal(leases[0].pixelMap.released, 1);
  assert.ok(leases.slice(1).every(lease => lease.pixelMap.released === 0));
  replacement.release();
  for (const lease of leases) lease.release();
});
await check('兼容原图超出条目上限会重新获取，外部裸引用仍未被显式 release', async () => {
  const { api, state } = imageHarness({ width: 64, height: 64 });
  const first = await api.getRemotePixelMap('https://test/raw-0');
  for (let i = 1; i <= 32; i++) await api.getRemotePixelMap('https://test/raw-' + i);
  const again = await api.getRemotePixelMap('https://test/raw-0');
  assert.notEqual(first, again);
  assert.equal(state.requests.length, 34);
  assert.ok(state.maps.every(map => map.released === 0));
});

process.stdout.write('REMOTE IMAGE CACHE PASS: ' + passed + ' behavioral cases; real production policy/cache, SDK boundaries mocked.\n');

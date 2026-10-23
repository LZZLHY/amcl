/**
 * 自更新推荐来源回归：直接装载真实 UpdateChecker、通道策略和收据校验器，
 * 同时提取真实 DownloadManager.fetchText 方法与 DownloadFailure，避免测试替身
 * 掩盖 Native HTTP 状态在 ArkTS 包装层丢失的问题。HTTP、安装包信息和活动租约
 * 是宿主边界；本测试不接触网络、签名、HDC 或应用版本号。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import compiler from './lib/ets-compiler.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourceHashes = {};
/** 只替换显式平台依赖；所有生产逻辑原样经 SDK 转译，未声明依赖立即失败。 */
function load(relative, dependencies = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  sourceHashes[relative] = crypto.createHash('sha256').update(source).digest('hex');
  const js = compiler.transpileModule(source, { compilerOptions: {
    module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020,
  } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require(name) {
    assert.ok(name in dependencies, '未声明的生产依赖：' + name);
    return dependencies[name];
  }, Object, Number, Array, RegExp, JSON, Promise, Error, console });
  return exports;
}

const policy = load('update/src/main/ets/AppUpdatePolicy.ets');
const resolver = load('update/src/main/ets/GitHubUpdateAssetResolver.ets', {
  '@kit.NetworkKit': {}, './AppUpdatePolicy': policy,
});
const noteTypes = load('update/src/main/ets/ChangelogTypes.ets');
const downloadPath = 'feature_core/src/main/ets/download/DownloadManager.ets';
const downloadSource = fs.readFileSync(path.join(root, downloadPath), 'utf8');
sourceHashes[downloadPath] = crypto.createHash('sha256').update(downloadSource).digest('hex');
const downloadAst = compiler.createSourceFile('DownloadManager.ets', downloadSource, compiler.ScriptTarget.Latest, true);
const manager = downloadAst.statements.find(node => node.name?.getText(downloadAst) === 'DownloadManager');
const failure = downloadAst.statements.find(node => node.name?.getText(downloadAst) === 'DownloadFailure');
const fetchMethod = manager?.members.find(node => node.name?.getText(downloadAst) === 'fetchText');
assert.ok(failure && fetchMethod, '真实下载包装器必须保留错误类型和 fetchText 方法');
const wrapperCode = compiler.transpileModule(failure.getText(downloadAst) + '\nclass MetadataHarness {\n' +
  'caBundleInitialized_: boolean = true;\n' + fetchMethod.getText(downloadAst) + '\n}\n' +
  'exports.MetadataHarness = MetadataHarness;', { compilerOptions: {
    module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020,
  } }).outputText;

const officialList = ['https://raw.githubusercontent.com/LZZLHY/amcl/main/update.json', 'https://lzzlhy.github.io/amcl/update.json'];
/** 清单始终走真实 fromDelivery；构造器只提供独立输入，不复制校验判据。 */
function ready(versionName, versionCode, channel = 'stable', product = 'sideload') {
  const tag = 'v' + versionName, name = 'amcl-' + tag + '-' + product + '-unsigned.hap', sha256 = 'a'.repeat(64);
  const asset = { tag, versionCode, versionName, product, name, sha256, sizeBytes: 100,
    url: 'https://github.com/LZZLHY/amcl/releases/download/' + tag + '/' + name,
    websiteUrl: 'https://amcl.lovedhy.cn/api/packages/files/' + sha256 + '/' + name,
    mirrors: [{ provider: 'miawa', projectId: 'amcl', ready: true, filePath: 'amcl/' + tag + '/' + name }] };
  return { tag, versionCode, versionName, updateChannel: channel,
    prerelease: policy.AppUpdatePolicy.prerelease(tag), publicationId: 'publication-' + versionName,
    delivery: { schema: 1, ready: true, assets: [asset] } };
}

/** 单个用例独立包装器和请求记录；Native 替身返回真实协议字段而非直接 throw HTTP 错误。 */
function fixture({ installed = '1.0.5', currentCode = 100, channel = 'stable', product = 'sideload',
  official = ready('1.0.6', 101, channel, product), staticHead = ready('1.0.5', 100, channel, product),
  hooks = false, allowed = true, responses = {}, expectedMirrors = [] } = {}) {
  const calls = [], leases = { acquired: 0, released: 0 };
  const officialUrl = 'https://amcl.lovedhy.cn/api/packages/manifest?product=' + product + '&channel=' + channel;
  const exports = {};
  const native = { fetchText: async (url, mirrors, timeout, headers, limit) => {
    calls.push({ url, mirrors, timeout, limit });
    assert.equal(limit, 8191, '每次请求保持 Native 8 KiB 字节上限');
    assert.equal(timeout, 15, '每条单源请求有界为 15 秒');
    assert.deepEqual(Array.from(mirrors), expectedMirrors, '不能由网络层将别源响应冒充当前 URL');
    const value = Object.hasOwn(responses, url) ? responses[url] : url === officialUrl ? official : staticHead;
    if (value?.failure) return { ok: false, statusCode: value.status ?? 0,
      errorKind: value.status ? 'HttpStatus' : 'Timeout', errorMessage: value.status ? 'HTTP ' + value.status : 'request timed out' };
    return { ok: true, statusCode: 200, body: typeof value === 'string' ? value : JSON.stringify(value) };
  } };
  vm.runInNewContext(wrapperCode, { exports, Error, Promise,
    DEFAULT_FETCH_RESPONSE_LIMIT_BYTES: 16 * 1024 * 1024, dlEngine: () => native,
    ProcessActivityCoordinator: { instance: () => ({ acquireFileTask() {
      leases.acquired++; return () => { leases.released++; };
    } }) },
  });
  const wrapper = new exports.MetadataHarness();
  const { UpdateChecker: checker } = load('update/src/main/ets/UpdateChecker.ets', {
    './AppUpdatePolicy': policy, './GitHubUpdateAssetResolver': resolver, './ChangelogTypes': noteTypes,
    '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
      getBundleInfoForSelfSync: () => ({ versionCode: currentCode, versionName: installed }) } },
    commons: { UPDATE_MANIFEST_URLS: officialList, formatError: String, AppLogger: { info() {}, warn() {} },
      DistributionPolicy: { allowSideloadUpdates: () => allowed }, DiagnosticPolicy: { hasTestHooks: () => hooks } },
    feature_core: { DownloadManager: { instance: () => wrapper }, DownloadFailure: exports.DownloadFailure },
  });
  return { checker, calls, leases, officialUrl, channel, product, wrapper };
}

const results = [];
/** 逐项收集断言结果，便于修复前保留全部反例；失败仍使整个命令非零退出。 */
async function test(name, run) {
  try { const evidence = await run(); results.push({ name, passed: true, ...evidence }); console.log('PASS source freshness: ' + name); }
  catch (error) { results.push({ name, passed: false, error: error.stack }); console.error('FAIL source freshness: ' + name + ': ' + error.message); }
}

for (const spec of [
  { name: '合法旧稳定清单不遮蔽官网新头', installed: '1.0.5', stale: '1.0.5', fresh: '1.0.6', staleCode: 100, freshCode: 101, channel: 'stable' },
  { name: '同编号旧预览不遮蔽pre3', installed: '1.0.6-pre2', stale: '1.0.6-pre1', fresh: '1.0.6-pre3', staleCode: 100, freshCode: 100, channel: 'preview' },
  { name: '可更新旧版本也不能遮蔽较新官网头', installed: '1.0.5', stale: '1.0.6', fresh: '1.0.7', staleCode: 101, freshCode: 102, channel: 'stable' },
  { name: '明确回退推荐不被静态更高版本覆盖', installed: '1.0.5', stale: '1.0.7', fresh: '1.0.6', staleCode: 102, freshCode: 101, channel: 'stable' },
  { name: '官网当前无更新也不采用静态更高版本', installed: '1.0.5', stale: '1.0.6', fresh: '1.0.5', staleCode: 101, freshCode: 100, channel: 'stable' },
]) await test(spec.name, async () => {
  const f = fixture({ installed: spec.installed, channel: spec.channel,
    staticHead: ready(spec.stale, spec.staleCode, spec.channel), official: ready(spec.fresh, spec.freshCode, spec.channel) });
  const actual = await f.checker.checkForUpdate(undefined, f.product, f.channel);
  assert.equal(actual.ok, true); assert.equal(actual.manifest?.versionName, spec.fresh);
  assert.equal(actual.hasUpdate, spec.fresh !== spec.installed);
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].url, f.officialUrl);
  assert.equal(f.leases.released, f.leases.acquired);
  return { chosen: actual.manifest.versionName, hasUpdate: actual.hasUpdate, requests: f.calls.map(call => call.url) };
});

for (const [name, official] of [
  ['官网超时回退完整静态快照', { failure: true }],
  ['官网5xx回退完整静态快照', { failure: true, status: 503 }],
  ['官网HTML回退完整静态快照', '<html>invalid</html>'],
  ['官网非法版本元数据回退完整静态快照', { versionCode: 2.5 }],
  ['官网非法版本名回退完整静态快照', { ...ready('1.0.7', 102), versionName: '1.0.7-pre0' }],
  ['官网tag与版本名冲突回退完整静态快照', { ...ready('1.0.7', 102), tag: 'v1.0.8' }],
  ['官网错误通道回退当前通道快照', ready('1.0.7', 102, 'preview')],
]) await test(name, async () => {
  const f = fixture({ official, staticHead: ready('1.0.6', 101) });
  const actual = await f.checker.checkForUpdate();
  assert.equal(actual.hasUpdate, true); assert.equal(actual.manifest?.versionName, '1.0.6');
  assert.equal(f.calls[0].url, f.officialUrl); assert.equal(f.calls.length, 2);
  assert.equal(f.leases.released, f.leases.acquired);
  return { requests: f.calls.map(call => call.url) };
});

for (const [name, channel, status] of [
  ['稳定通道明确404不复活旧静态推荐', 'stable', 404],
  ['预览通道尚无推荐不采用静态preview', 'preview', 404],
  ['官网409明确未就绪不采用旧静态推荐', 'preview', 409],
]) await test(name, async () => {
  const f = fixture({ channel, official: { failure: true, status }, staticHead: ready('1.0.6-pre1', 100, 'preview') });
  const actual = await f.checker.checkForUpdate(undefined, f.product, f.channel);
  assert.equal(actual.hasUpdate, false); assert.equal(actual.manifest, null); assert.match(actual.error, /就绪|同步|推荐/);
  assert.equal(f.calls.length, 1); assert.equal(f.leases.released, 1);
});

for (const damage of ['not-ready', 'wrong-product', 'wrong-hash']) await test('官网合法头的收据损坏不回旧头：' + damage, async () => {
  const official = ready('1.0.6', 101);
  if (damage === 'not-ready') official.delivery.ready = false;
  if (damage === 'wrong-product') official.delivery.assets[0].product = 'desktop';
  if (damage === 'wrong-hash') official.delivery.assets[0].sha256 = 'bad';
  const f = fixture({ official, staticHead: ready('1.0.7', 102) });
  const actual = await f.checker.checkForUpdate();
  assert.equal(actual.hasUpdate, false); assert.equal(actual.manifest, null); assert.match(actual.error, /同步|就绪/);
  assert.equal(f.calls.length, 1);
});

await test('静态缺收据的无更新旧条目不能阻止后续完整快照', async () => {
  const stale = ready('1.0.5', 100); delete stale.delivery;
  const first = policy.AppUpdatePolicy.urls('sideload', 'stable')[0];
  const f = fixture({ official: { failure: true }, staticHead: ready('1.0.6', 101), responses: { [first]: stale } });
  const actual = await f.checker.checkForUpdate();
  assert.equal(actual.hasUpdate, true); assert.equal(actual.manifest?.versionName, '1.0.6'); assert.equal(f.calls.length, 3);
});

await test('所有静态候选缺少完整收据均不能提示或写入缓存', async () => {
  const missing = ready('1.0.6', 101); delete missing.delivery;
  const f = fixture({ official: { failure: true }, staticHead: missing });
  const actual = await f.checker.checkForUpdate();
  assert.equal(actual.hasUpdate, false); assert.equal(actual.manifest, null); assert.match(actual.error, /同步|就绪/);
});

await test('旧稳定官网当前版无收据仍兼容无更新结果', async () => {
  const official = ready('1.0.5', 100); delete official.delivery;
  delete official.updateChannel; delete official.prerelease;
  const f = fixture({ official, staticHead: ready('1.0.6', 101) });
  const actual = await f.checker.checkForUpdate();
  assert.equal(actual.ok, true); assert.equal(actual.hasUpdate, false);
  assert.equal(actual.manifest?.versionName, '1.0.5'); assert.equal(f.calls.length, 1);
});

await test('desktop请求和资产均绑定desktop', async () => {
  const f = fixture({ product: 'desktop' });
  const actual = await f.checker.checkForUpdate(undefined, f.product);
  assert.equal(actual.hasUpdate, true); assert.equal(actual.manifest.delivery.assets[0].product, 'desktop');
  assert.equal(f.calls[0].url, f.officialUrl);
});

await test('预览回退不追加旧稳定update.json', async () => {
  const f = fixture({ channel: 'preview', official: { failure: true }, staticHead: '<html>invalid</html>' });
  const actual = await f.checker.checkForUpdate(undefined, f.product, f.channel);
  assert.equal(actual.hasUpdate, false); assert.equal(actual.manifest, null);
  assert.equal(f.calls.length, 3); assert(f.calls.slice(1).every(call => call.url.endsWith('/sideload/preview.json')));
});

await test('显式注入源顺序及错误JSON回退保持隔离', async () => {
  const urls = ['https://fixture.invalid/bad', 'https://fixture.invalid/good'];
  const f = fixture({ responses: { [urls[0]]: '<html>bad</html>', [urls[1]]: ready('1.0.6', 101) } });
  const actual = await f.checker.checkForUpdate(urls);
  assert.equal(actual.hasUpdate, true); assert.deepEqual(f.calls.map(call => call.url), urls);
});

await test('注入源全部失败不意外进入生产官网', async () => {
  const url = 'https://fixture.invalid/bad', f = fixture({ responses: { [url]: '<html>bad</html>' } });
  const actual = await f.checker.checkForUpdate([url]);
  assert.equal(actual.hasUpdate, false); assert.equal(actual.manifest, null); assert.deepEqual(f.calls.map(call => call.url), [url]);
});

for (const hooks of [true, false]) await test('受控测试收据豁免受诊断开关限制：' + hooks, async () => {
  const url = 'https://amcl.lovedhy.cn/uploads/self-update-tests/' + 'a'.repeat(32) + '/manifest.json';
  const candidate = ready('1.0.6', 101); delete candidate.delivery;
  const f = fixture({ hooks, responses: { [url]: candidate } });
  const actual = await f.checker.checkForUpdate([url]);
  assert.equal(actual.hasUpdate, hooks); assert.equal(actual.manifest !== null, hooks); assert.equal(f.calls.length, 1);
});

await test('商店渠道和空源在联网前拒绝', async () => {
  const store = fixture({ allowed: false }); assert.equal((await store.checker.checkForUpdate()).ok, false); assert.equal(store.calls.length, 0);
  const empty = fixture(); assert.equal((await empty.checker.checkForUpdate([])).ok, false); assert.equal(empty.calls.length, 0);
});

for (const status of [404, 0]) await test('真实fetchText透传错误状态且释放活动租约：' + status, async () => {
  const f = fixture({ official: { failure: true, status } });
  await assert.rejects(f.wrapper.fetchText(f.officialUrl, [], 15, 8191), error => {
    assert.ok(error instanceof Error); assert.equal(error.detail?.httpStatus, status);
    assert.equal(error.detail?.kind, status ? 'HttpStatus' : 'Timeout');
    assert.equal(error.detail?.url, f.officialUrl);
    assert.deepEqual(Array.from(error.detail?.triedUrls ?? []), [f.officialUrl]);
    assert.equal(error.message, status ? '[HttpStatus] HTTP 404 (urls: 1)' : '[Timeout] request timed out (urls: 1)');
    return true;
  });
  assert.equal(f.leases.acquired, 1); assert.equal(f.leases.released, 1);
});

await test('普通多源元数据失败不虚构最终URL及逐源尝试收据', async () => {
  const mirrors = ['https://mirror.invalid/metadata'];
  const f = fixture({ official: { failure: true, status: 503 }, expectedMirrors: mirrors });
  await assert.rejects(f.wrapper.fetchText(f.officialUrl, mirrors, 15, 8191), error => {
    assert.equal(error.detail?.httpStatus, 503); assert.equal(error.detail?.url, '');
    assert.deepEqual(Array.from(error.detail?.triedUrls ?? []), []);
    assert.equal(error.message, '[HttpStatus] HTTP 503 (urls: 2)'); return true;
  });
  assert.equal(f.leases.acquired, f.leases.released);
});

const report = { executedAt: new Date().toISOString(), sourceHashes,
  scope: '真实ArkTS推荐选择、收据校验与fetchText包装；HTTP/包信息/活动租约为宿主边界，无真机安装',
  passed: results.filter(value => value.passed).length, failed: results.filter(value => !value.passed).length, results };
if (process.env.AMCL_TEST_OUTPUT_DIR) {
  fs.mkdirSync(process.env.AMCL_TEST_OUTPUT_DIR, { recursive: true });
  fs.writeFileSync(path.join(process.env.AMCL_TEST_OUTPUT_DIR, 'update-source-freshness-results.json'), JSON.stringify(report, null, 2) + '\n');
}
console.log(JSON.stringify({ suite: 'app-update-source-freshness', passed: report.passed, failed: report.failed }));
if (report.failed) process.exitCode = 1;

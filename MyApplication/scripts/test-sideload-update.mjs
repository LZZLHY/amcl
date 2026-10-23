/** 执行真实ArkTS纯业务实现的负向回归；仅替换平台接口，解析/身份判据不在测试中重写。 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import vm from 'node:vm';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const sdk = process.env.DEVECO_SDK_HOME;
if (!sdk) throw new Error('DEVECO_SDK_HOME is required for SDK transpiler');
const ts = require(resolve(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
/** CommonJS临时加载保持原实现，SDK类型检查仍由正常HarmonyOS构建执行。 */
function load(path, modules = {}) {
  const text = readFileSync(resolve(root, path), 'utf8');
  const js = ts.transpileModule(text, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: name => {
    if (!(name in modules)) throw new Error('Unmocked dependency: ' + name);
    return modules[name];
  }, console, Uint8Array, Object, Number, RegExp, Date, JSON, Observed: value => value,
  // 自动复检使用真实定时器，但未清理的失败用例不能让宿主进程永久驻留。
  setTimeout: (...args) => { const timer = setTimeout(...args); timer.unref(); return timer; }, clearTimeout });
  return exports;
}
const models = load('update/src/main/ets/SideloadUpdateModels.ets');
// 模拟真机重复mkdir的EEXIST：保险库与事务服务共用目录时只能创建一次。
let directoryExists = false, directoryCreates = 0;
const { SideloadFiles: files } = load('entry/src/main/ets/sideload/SideloadFiles.ets', {
  '@kit.CoreFileKit': { fileIo: { accessSync: () => directoryExists,
    mkdirSync: () => { if (directoryExists) throw new Error('File exists'); directoryExists = true; directoryCreates++; } } },
  '@kit.CryptoArchitectureKit': {}, '@kit.ArkTS': {}, commons: {}
});
files.ensureDirectory('/private/update'); files.ensureDirectory('/private/update');
assert.equal(directoryCreates, 1);
// 正式产品由SDK源集覆盖别名；相对main的导入会让store误用default渠道，产物审核亦会拒绝它。
for (const file of ['SideloadUpdateCoordinator.ets', 'SideloadUpdateTestWant.ets']) {
  const code = readFileSync(resolve(root, 'entry/src/main/ets/sideload', file), 'utf8');
  assert.match(code, /from 'entry\/ProductBuildProfile'/);
  assert.doesNotMatch(code, /from '[.][.].*ProductBuildProfile'/);
}
const { GitHubUpdateAssetResolver: resolver } = load('update/src/main/ets/GitHubUpdateAssetResolver.ets', { '@kit.NetworkKit': {}, './AppUpdatePolicy':load('update/src/main/ets/AppUpdatePolicy.ets') });
const manifest = { tag: 'v1.0.6', versionCode: 1000679, versionName: '1.0.6' };
const asset = { name: 'amcl-v1.0.6-sideload-unsigned.hap', size: 9000, digest: 'sha256:' + 'a'.repeat(64),
  browser_download_url: 'https://github.com/LZZLHY/amcl/releases/download/v1.0.6/amcl-v1.0.6-sideload-unsigned.hap' };
const body = { tag_name: manifest.tag, prerelease:false,draft:false,assets: [asset] };
assert.equal(resolver.parse(JSON.stringify(body), manifest, 'sideload').sha256, 'a'.repeat(64));
assert.throws(() => resolver.parse(JSON.stringify(body), manifest, 'desktop'));
assert.throws(() => resolver.parse(JSON.stringify(body), manifest, 'store'));
for (const mutate of [
  value => { value.tag_name = 'v1.0.7'; },
  value => { value.assets.push(structuredClone(asset)); },
  value => { value.assets[0].digest = ''; },
  value => { value.assets[0].browser_download_url = 'https://example.com/payload.hap'; },
  value => { value.assets[0].size = -1; },
  value => { value.assets[0].name = 'amcl-v1.0.6-desktop-unsigned.hap'; }
]) {
  const changed = structuredClone(body); mutate(changed);
  assert.notEqual(JSON.stringify(changed), JSON.stringify(body), 'negative mutation must change input');
  assert.throws(() => resolver.parse(JSON.stringify(changed), manifest, 'sideload'));
}
const { SideloadTransactionPolicy: policy } = load('update/src/main/ets/SideloadTransactionPolicy.ets', { './SideloadUpdateModels': models, './AppUpdatePolicy':load('update/src/main/ets/AppUpdatePolicy.ets') });
const id = 'b'.repeat(32), nonce = 'c'.repeat(32), base = '/private/sideload-update';
const transaction = { schema: 1, id, phase: models.SideloadUpdatePhase.Installing,
  asset: resolver.parse(JSON.stringify(body), manifest, 'sideload'), beforeVersionCode: 1000678, beforeUid: 20020376,
  sameVersionTest: false,
  expectedPayloadIdentity: 'd'.repeat(40), unsignedPath: base + '/tasks/' + id + '/unsigned.hap',
  signedPath: base + '/tasks/' + id + '/signed.hap', signedSha256: 'e'.repeat(64), restartNonce: nonce,
  createdAt: 1, updatedAt: 2, confirmedAt: 0, error: '' };
assert.equal(policy.validate(transaction, base), true);
const args = [transaction, 1000679, 20020376, 'd'.repeat(40), id, nonce];
assert.equal(policy.confirms(...args), true);
// 同版本实验必须经过独立运行时门禁；修改持久化布尔值不能让正式产品接受它。
const replacement = structuredClone(transaction); replacement.sameVersionTest = true; replacement.asset.versionCode = 1000678;
assert.equal(policy.validate(replacement, base), false);
assert.equal(policy.validate(replacement, base, true), true);
assert.equal(policy.confirms(replacement, 1000678, 20020376, 'd'.repeat(40), id, nonce), false);
assert.equal(policy.confirms(replacement, 1000678, 20020376, 'd'.repeat(40), id, nonce, true), true);
for (const [index, wrong] of [[1, 1000678], [2, 20020377], [3, 'f'.repeat(40)], [4, 'a'.repeat(32)], [5, '']]) {
  const bad = args.slice(); bad[index] = wrong; assert.equal(policy.confirms(...bad), false);
}
for (const mutate of [
  t => { t.schema = 2; }, t => { t.signedPath = '/arbitrary/other.hap'; },
  t => { t.id = '../escape'; }, t => { t.updatedAt = 0; }, t => { t.restartNonce = ''; },
  t => { t.asset.versionCode = t.beforeVersionCode; }
]) { const bad = structuredClone(transaction); mutate(bad); assert.equal(policy.validate(bad, base), false); }
// 账户默认alias与更新域alias分别传到HUKS原接口，防止新域改变既有账户密钥身份。
const aliases = [];
const { HuksAesGcm256Provider: Provider } = load('account/src/main/ets/HuksCryptoProvider.ets', {
  '@kit.UniversalKeystoreKit': { huks: { hasKeyItem: async alias => { aliases.push(alias); return true; } } },
  '@kit.CryptoArchitectureKit': {}, commons: { AppLogger: { info() {}, warn() {} } }
});
assert.equal(await new Provider().isAvailable(), true);
assert.equal(await new Provider('amcl_sideload_signing_v1').isAvailable(), true);
assert.deepEqual(aliases, ['amcl_account_master_v1', 'amcl_sideload_signing_v1']);
assert.throws(() => new Provider('../unknown'));
// 真机入口的构造失败也必须形成结果：不能在try外抛出后只留下“启动成功”。
const evidence = new Map();
const fixture = { schema: 1, id: 'test-init-failure', asset: transaction.asset };
const hook = load('entry/src/main/ets/sideload/SideloadUpdateTestWant.ets', {
  '@kit.CoreFileKit': { fileIo: { accessSync: () => true, statSync: () => ({ size: 100, isFile: () => true }), readTextSync: () => JSON.stringify(fixture) } },
  '@kit.ArkUI': { window: { getLastWindow: async () => ({ setWindowKeepScreenOn() {} }) } },
  update: models,
  commons: { DiagnosticPolicy: { hasTestHooks: () => true } },
  'entry/ProductBuildProfile': { ProductBuildProfile: { product: 'default' } },
  './SideloadUpdateService': { SideloadUpdateService: { get: () => { throw new Error('test initialization failure'); } } },
  './SideloadFiles': { SideloadFiles: { write: (path, body) => evidence.set(path, JSON.parse(body)) } }
  , './SideloadFixtureHttp': { SideloadFixtureHttp: class {} }
  , './SideloadUpdateTestSession': { SideloadUpdateTestSession: { clear() {} } }
});
hook.runSideloadUpdateTestWant({ filesDir: '/private/main' }, { parameters: { amclSideloadUpdateTest: 'prepare' } });
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(evidence.get('/private/main/sideload-update-test-ack.json').fixtureExists, true);
assert.equal(evidence.get('/private/main/sideload-update-test-result.json').error, 'test initialization failure');
console.log('sideload-update: asset identity, wrong-product/digest/source rejection, transaction replay/path/version rejection, account HUKS identity passed');

/** 唯一协调器已承接原VM推进逻辑；原并行/取消/后台场景迁入真实Coordinator回归，避免假Service继续验证已删除执行链。 */
await import('./test-sideload-coordinator.mjs');
/** 常规自更新宿主门禁同时执行临时域收尾回归，防止修复后再次积累大体积签名 JAR。 */
await import('./test-host-test-lifecycle.mjs');
/** 官方AuthSession边界仍单独执行，保持服务端认证、取消与过期负向覆盖。 */
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
const settle = async () => { for (let i = 0; i < 15; i++) await Promise.resolve(); };
const testProduct = { product: 'default' };
const testSession = load('entry/src/main/ets/sideload/SideloadUpdateTestSession.ets', {
  commons: { DiagnosticPolicy: { hasTestHooks: () => true }, UPDATE_MANIFEST_URLS: ['https://production.example/update.json'] },
  'entry/ProductBuildProfile': { ProductBuildProfile: testProduct }, update: models,
});

/** 执行真实登录服务，HTTP与HUKS存储只提供固定响应；不会把本地JWT存在当作服务端认证。 */
function authSession(saved, responses) {
  const data = { saved, writes: 0, calls: [] };
  const auth = load('entry/src/main/ets/sideload/DeveloperAuthSession.ets', {
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 1 },
      createHttp: () => ({ destroy() {}, async request(url) {
        data.calls.push(url); const next = responses.shift();
        if (next instanceof Error) throw next;
        if (!next) throw new Error('Unexpected HTTP request');
        return await next;
      } }) } },
    '@kit.ArkTS': { util: { TextDecoder: class { decodeWithStream(bytes) { return new TextDecoder().decode(bytes); } },
      Base64Helper: class { decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); } } } },
    './DeveloperAuthVault': { DeveloperCredentialInvalidError: class extends Error {}, DeveloperAuthVault: class {
      async read() { if (data.saved instanceof Error) throw data.saved; return data.saved; }
      async save(value, current) { if (current()) { data.saved = value; data.writes++; } }
    } },
  });
  const session = new auth.DeveloperAuthSession(); session.initialize({ filesDir: '/private/app' });
  return { session, data, states: auth.DeveloperAuthState };
}
const jwt = 'header.' + Buffer.from(JSON.stringify({ userId: 'test-user', exp: Math.floor(Date.now() / 1000) + 3600 })).toString('base64url') + '.signature';
const credential = { schema: 1, jwt, expiresAt: Date.now() + 3600000, savedAt: Date.now() };
const tokenResponse = { responseCode: 200, result: JSON.stringify({ status: true, userInfo: { accessToken: 'test-only-access' } }) };
const teamResponse = { responseCode: 200, result: JSON.stringify({ teams: [{ id: 'test-team' }] }) };
{
  const f = authSession(undefined, []); assert.equal(await f.session.restore(), f.states.Missing); assert.equal(f.data.calls.length, 0);
}
{
  const f = authSession({ ...credential, expiresAt: 1 }, []);
  assert.equal(await f.session.restore(), f.states.Expired); assert.equal(f.session.signedIn(), false); assert.equal(f.data.calls.length, 0);
}
{
  const f = authSession(credential, [tokenResponse, teamResponse]);
  assert.equal(await f.session.restore(), f.states.Valid); assert.equal(f.session.signedIn(), true); assert.equal(f.data.calls.length, 2);
  f.session.close(); assert.equal(f.session.signedIn(), false); assert.equal(f.data.saved.jwt, jwt);
}
for (const response of [{ responseCode: 401, result: '' }, { responseCode: 200, result: '{"status":false}' }]) {
  const f = authSession(credential, [response]);
  assert.equal(await f.session.restore(), f.states.Expired); assert.equal(f.session.signedIn(), false);
  assert.equal(f.data.saved.jwt, ''); assert.equal(f.data.writes, 1);
}
{
  const f = authSession(credential, [new Error('network offline')]);
  assert.equal(await f.session.restore(), f.states.Unavailable); assert.equal(f.data.saved.jwt, jwt); assert.equal(f.data.writes, 0);
}
{
  const response = deferred(); const f = authSession(credential, [response.promise]);
  const checking = f.session.restore(); await settle(); f.session.close(); response.resolve(tokenResponse);
  assert.equal(await checking, f.states.Cancelled); assert.equal(f.session.signedIn(), false); assert.equal(f.data.writes, 0);
}
console.log('sideload-update: real login restore, local/server expiration, network distinction and cancelled validation passed');

// 存储边界故障保留Unavailable；不能自动冒充登录过期而拉起新的授权。
{
  const f = authSession(new Error('fixture transient HUKS RPC failure'), []);
  assert.equal(await f.session.restore(), f.states.Unavailable); assert.equal(f.data.writes, 0); assert.equal(f.data.calls.length, 0);
}

// 未拥有当前应用身份时只能读取账号信息，不能创建一个同包名的新身份或先创建证书。
{
  const requests = [];
  const { DeveloperSigningService: signing } = load('entry/src/main/ets/sideload/DeveloperSigningService.ets', {
    '@kit.AbilityKit': { bundleManager: { BundleFlag: {}, getBundleInfoForSelfSync: () =>
      ({ name: 'com.amcl.launcher', signatureInfo: { appIdentifier: 'installed-app' } }) } },
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' } } }, '@kit.ArkTS': {}, '@kit.CoreFileKit': {},
    '@kit.CryptoArchitectureKit': {}, 'libentry.so': {}, './DeveloperAuthSession': {}, './SigningVault': {}, './SideloadFiles': {},
  });
  const auth = { teamIds: () => ['team'], async request(path, method) {
    requests.push({ path, method }); return { appInfos: [{ appId: 'different-app' }] };
  } };
  await assert.rejects(signing.prepare({}, auth, {}, 'A'.repeat(64), '', '', '', () => {}), /未找到与当前安装匹配/);
  assert.equal(requests.length, 1); assert.equal(requests[0].method, 'GET');
  assert.throws(() => signing.find([{ id: 'same' }, { id: 'same' }], 'id', 'same'), /重复记录/);
  assert.equal(signing.find([], 'id', 'absent'), undefined);
}
console.log('sideload-update: unmatched cloud identity makes no signing mutations; duplicate material records rejected');

// 测试源只能进入default，本域外URL、跨任务资产和清单身份不匹配均失败；清理恢复正式源。
{
  const session = testSession.SideloadUpdateTestSession;
  const prefix = 'https://amcl.lovedhy.cn/uploads/self-update-tests/' + 'a'.repeat(32) + '/';
  const fixtureAsset = { ...transaction.asset, url: prefix + 'target-unsigned.hap' };
  assert.throws(() => session.configure('https://example.com/manifest.json', fixtureAsset, false));
  assert.throws(() => session.configure(prefix + 'manifest.json', { ...fixtureAsset, url: prefix.replace('a'.repeat(32), 'b'.repeat(32)) + 'target-unsigned.hap' }, false));
  testProduct.product = 'store'; assert.throws(() => session.configure(prefix + 'manifest.json', fixtureAsset, false));
  testProduct.product = 'default'; session.configure(prefix + 'manifest.json', fixtureAsset, true);
  const match = { ok: true, hasUpdate: false, current: fixtureAsset.versionCode, error: '', manifest: { ...manifest, sizeBytes: fixtureAsset.sizeBytes, url: fixtureAsset.url } };
  session.validateResult(match); assert.equal(match.hasUpdate, true);
  const wrong = structuredClone(match); wrong.manifest.tag = 'wrong'; session.validateResult(wrong); assert.equal(wrong.ok, false);
  session.clear(); assert.equal(session.urls()[0], 'https://production.example/update.json');
}
console.log('sideload-update: HTTPS fixture scope, production exclusion and manifest identity binding passed');

// 真实设备曾只返回33字节挑战行；不能把它当成UDID，也不能与有标识的返回混淆。
{
  const { SideloadConnection: connection } = load('entry/src/main/ets/sideload/SideloadConnection.ets', {
    '@kit.NetworkKit': {}, '@kit.ArkTS': {}, '@kit.CoreFileKit': {}, '@kit.BasicServicesKit': {},
    'libentry.so': {}, './SideloadFiles': {},
  });
  assert.equal(connection.parseUdid('udid of current device is:\r\n' + 'a'.repeat(64) + '\r\n'), 'A'.repeat(64));
  assert.equal(connection.parseDiscoveredPort('OHOS HDC-38735'), 38735);
  for (const value of ['OHOS HDC-0', 'OHOS HDC-65536', 'OHOS HDC--1', 'OHOS HDC-38735; id', '38735', 'OHOS HDC-abc']) {
    assert.equal(connection.parseDiscoveredPort(value), 0);
  }
  for (const value of ['', 'b'.repeat(32) + '\n', 'not authorized', 'a'.repeat(63), 'a'.repeat(64) + '\n' + 'b'.repeat(64)]) {
    assert.throws(() => connection.parseUdid(value));
  }
}
console.log('sideload-update: standalone UDID response parsing and nonce-only rejection passed');

// 本机端口提示必须来自生产 Native 发现；TCP 可达也不能跳过后续 HDC 信任验证。
{
  let probed=0, starts=0;
  const {SideloadConnection:Connection}=load('entry/src/main/ets/sideload/SideloadConnection.ets',{
    '@kit.NetworkKit':{socket:{constructTCPSocketInstance:()=>({connect:async o=>{probed=o.address.port;},close:async()=>{}})}},
    '@kit.ArkTS':{},'@kit.CoreFileKit':{fileIo:{accessSync:()=>false}},'./SideloadFiles':{},
    'libentry.so':{default:{discoverSideloadPort:async()=>38735,startSideloadHdc:async()=>{starts++;return -1;}}}
  });
  const connection=new Connection('/private/update');
  await assert.rejects(connection.check(),/无法启动/);assert.equal(probed,38735);assert.equal(starts,1);
  assert.equal(connection.discoveryMethod,'local-discovery');
}
console.log('sideload-update: live discovery replaces stale port without bypassing trusted HDC handshake');
// 授权窗口与取消边界单独控制时间，仍执行真实连接实现；正常构建由本入口自动覆盖。
await import('./test-sideload-authorization.mjs');

// 运行真实传输确认：远端少尾部/摘要错误不能放行，第二次完整传送可恢复，持续错误有界失败。
for (const recoverOnRetry of [true, false]) {
  let response = '', sends = 0, removed = 0;
  const expected = 'a'.repeat(64);
  const { SideloadConnection: Connection } = load('entry/src/main/ets/sideload/SideloadConnection.ets', {
    '@kit.NetworkKit': {}, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'test-transfer' } },
    '@kit.CoreFileKit': { fileIo: {
      accessSync: path => path.includes('/received-'), statSync: () => ({ size: response.length }),
      readTextSync: () => response, unlinkSync: () => { removed++; },
    } },
    'libentry.so': {}, './SideloadFiles': { SideloadFiles: { quote: value => "'" + value + "'" } },
  });
  const connection = new Connection('/private/update');
  connection.command = async args => {
    if (args[0] === 'file') sends++;
    else response = (recoverOnRetry && sends === 2 ? expected : 'b'.repeat(64)) + '  /data/local/tmp/candidate.hap\n';
  };
  if (recoverOnRetry) await connection.sendVerified('/private/signed.hap', '/data/local/tmp/candidate.hap', expected);
  else await assert.rejects(connection.sendVerified('/private/signed.hap', '/data/local/tmp/candidate.hap', expected), /已停止安装/);
  assert.equal(sends, 2); assert.equal(removed, 1);
}
console.log('sideload-update: remote file digest blocks truncation, bounded retransfer and private-output cleanup passed');

// 完整候选绑定与 Runtime 中途换代走真实 Coordinator 回归，随自更新聚合入口长期执行。
await import('./test-app-update-cache-identity.mjs');

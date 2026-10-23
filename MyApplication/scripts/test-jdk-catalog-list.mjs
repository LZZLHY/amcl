/**
 * 直接执行生产 RuntimeCatalogRepository → JdkManager → JdkUpdatePolicy 的列表链路。
 * SDK 文件/网络/加密和安装任务构造器作为边界注入；目录、撤回、内容与更新判定不重写。
 * 夹具仅在内存保存短 ELF/JIMAGE 文件头，不执行候选 JDK，也不产生项目内临时文件。
 * 可选 --source-ref <Git提交> 仅加载该提交的两个原始生产文件，供修复前负对照；
 * 当前默认始终执行工作树源码。宿主通过不代替 OHOS 验签、下载与游戏真机验收。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, sign, verify, createPublicKey } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const managerPath = 'launch/src/main/ets/JdkManager.ets';
const repositoryPath = 'launch/src/main/ets/RuntimeCatalogRepository.ets';
const builtinText = fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json', import.meta.url), 'utf8');
const builtin = JSON.parse(builtinText);
const optionIndex = process.argv.indexOf('--source-ref');
const sourceRef = optionIndex < 0 ? undefined : process.argv[optionIndex + 1];
if (optionIndex >= 0 && !sourceRef) throw new Error('--source-ref 需要明确的 Git 提交');
const overrides = sourceRef === undefined ? {} : Object.fromEntries([managerPath, repositoryPath].map(path =>
  [path, execFileSync('git', ['-C', root, 'show', sourceRef + ':' + path], { encoding: 'utf8', maxBuffer: 1024 * 1024 })]));
const pair = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const trusted = { schemaVersion: 1, keys: [{ kid: 'jdk-list-test', algorithm: 'ES256',
  spki: pair.publicKey.export({ format: 'der', type: 'spki' }).toString('base64') }] };
const cases = [];

/** 使用真实 ES256 签名生产 payload，让仓库读取和网络刷新都经过生产验签器。 */
function envelope(catalog) {
  const header = Buffer.from(JSON.stringify({ alg: 'ES256', typ: 'amcl-runtime-catalog+jws', kid: trusted.keys[0].kid })).toString('base64url');
  const payload = Buffer.from(JSON.stringify(catalog)).toString('base64url');
  const signature = sign('sha256', Buffer.from(header + '.' + payload), { key: pair.privateKey, dsaEncoding: 'ieee-p1363' });
  return JSON.stringify({ protected: header, payload, signature: signature.toString('base64url') });
}

/** 生成结构合法的测试通道；具体包身份沿用随 HAP 交付的目录，不伪造包字节。 */
function catalog(channel, revision = builtin.catalogRevision + 1) {
  const result = structuredClone(builtin);
  result.channel = channel;
  result.catalogRevision = revision;
  if (channel === 'preview') for (const runtime of result.runtimes) {
    const build = result.builds.filter(item => item.runtimeId === runtime.id && item.provenance.kind === 'source-build' && item.status === 'available').at(-1);
    assert(build, '夹具需要同槽位的源码构建候选');
    runtime.recommendedBuildId = build.id;
    runtime.recommendationRevision++;
  }
  return result;
}

/**
 * 每个场景使用全新的生产模块缓存和内存文件系统，避免静态单例与版本数组跨场景串值。
 * 系统边界只提供文件头、真实 OpenSSL 验签和受控 HTTP 结果；未调用的安装生命周期明确拒绝。
 */
function fixture() {
  const files = new Map();
  const handles = new Map();
  const directoryEntries = new Set();
  const calls = { http: [], installers: [], crypto: 0 };
  let nextFd = 0;
  let remote = '';
  const entry = path => { const item = files.get(path); if (!item) throw new Error('ENOENT: ' + path); return item; };
  const put = (path, value, size) => files.set(path, { bytes: Buffer.from(value), size });
  const fileIo = {
    OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    statSync(path) { const item = entry(path); return { size: item.size ?? item.bytes.length, isFile: () => true }; },
    readTextSync: path => entry(path).bytes.toString('utf8'),
    listFileSync(path) { assert.equal(path, '/app/jdk'); return [...directoryEntries]; },
    openSync(path, flags) { if (flags & 1) put(path, ''); else entry(path); const fd = ++nextFd; handles.set(fd, path); return { fd }; },
    readSync(fd, buffer) { const bytes = entry(handles.get(fd)).bytes; const count = Math.min(bytes.length, buffer.byteLength); new Uint8Array(buffer).set(bytes.subarray(0, count)); return count; },
    writeSync(fd, value) { put(handles.get(fd), value); },
    closeSync(file) { handles.delete(typeof file === 'number' ? file : file.fd); },
    fsyncSync() {},
    renameSync(from, to) { files.set(to, entry(from)); files.delete(from); },
  };
  // 常量和槽位语法直接取生产模块；其共享数组由真实 Manager 填充，未复制槽位判定。
  const constants = makePureEtsLoader()('commons/src/main/ets/common/Constants.ets');
  const commons = { ...constants, ensureDirSync() {}, AppLogger: { info() {}, warn() {}, error() {} }, LogTags: { SVC_JDK: 'JdkManager' }, LOG_DOMAIN_LAUNCH: 1 };
  class InstallerBoundary {
    constructor(options) { this.options = options; calls.installers.push(options); }
  }
  const load = makePureEtsLoader({
    commons,
    '@kit.CoreFileKit': { fileIo },
    '@kit.PerformanceAnalysisKit': { hilog: {} },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 20 } },
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes) }) },
      TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text)); } },
      Base64Helper: class { decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {
      createAsyKeyGenerator: () => ({ convertKey: async bytes => ({ pubKey: createPublicKey({ key: Buffer.from(bytes.data), type: 'spki', format: 'der' }) }) }),
      createVerify(algorithm) { assert.equal(algorithm, 'ECC256|SHA256'); let key; return { init: async value => { key = value; },
        verify: async (data, signature) => { calls.crypto++; return verify('sha256', data.data, key, signature.data); } }; },
    } },
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string' },
      createHttp: () => ({ request: async (url, options) => { calls.http.push({ url, options }); return { responseCode: 200, result: remote }; }, destroy() {} }) } },
    // 这些边缘与被测的目录/内容/列表无关。创建安装器只记录冻结入参，不执行下载。
    './JdkInstaller': { JdkInstaller: InstallerBoundary },
    './JdkDirectoryLease': {}, './LaunchJdkPolicy': {}, mods: {}, feature_core: {},
  }, overrides);
  const context = { filesDir: '/app', resourceManager: { getRawFileContentSync: name =>
    new Uint8Array(Buffer.from(name.endsWith('builtin.json') ? builtinText : JSON.stringify(trusted))) } };
  const api = load(managerPath);
  const repository = load(repositoryPath).RuntimeCatalogRepository.instance(context);
  const manager = new api.JdkManager(context);

  /** 仅构造校验器要求的合法短头；size 为受控 stat 元数据，不为测试分配真实兆字节。 */
  function install(major, stamp) {
    directoryEntries.add(major);
    const dir = '/app/jdk/' + major;
    const classic = major === '8';
    const lib = dir + (classic ? '/jre/lib/aarch64/' : '/lib/');
    for (const name of ['server/libjvm.so', 'libjava.so', 'libzip.so', 'libverify.so', 'libnet.so', 'libnio.so', classic ? 'jli/libjli.so' : 'libjli.so']) {
      const bytes = Buffer.alloc(64); bytes.set([127, 69, 76, 70, 2, 1, 1]);
      bytes.writeUInt16LE(3, 16); bytes.writeUInt16LE(183, 18); bytes.writeUInt16LE(64, 52);
      put(lib + name, bytes);
    }
    put(dir + (classic ? '/jre/lib/rt.jar' : '/lib/modules'), classic ? [80, 75, 3, 4] : [218, 218, 254, 202], 1000001);
    put(dir + '/release', 'JAVA_VERSION="' + major + '.0.1"\n');
    put(dir + '/.amcl_release_tag', stamp);
  }
  return { api, manager, repository, calls, files, handles, install, put, directoryEntries,
    setRemote(value) { remote = envelope(value); },
    cache(channel, value) { put('/app/runtime-catalog/' + channel + '.json', envelope(value)); } };
}

/** 每个命名场景结束都检查短文件句柄已关闭；异常保留 Node 的原始断言与堆栈。 */
async function test(name, body) {
  const f = fixture();
  await body(f);
  assert.equal(f.handles.size, 0, '短文件读取与缓存写入没有泄漏句柄');
  cases.push(name);
}

await test('落后于另一通道最高代次的可信缓存只供展示，不创建旧推荐安装器', async f => {
  f.cache('stable', catalog('stable', builtin.catalogRevision + 3));
  f.cache('preview', catalog('preview', builtin.catalogRevision + 2));
  await f.repository.configure('preview', 'github', false);
  const list = f.manager.listVersions();
  assert.equal(list.length, 4, '切换后必须仍显示四个目录槽位，不能只剩本地导入卡片');
  assert.match(list[0].stateText, /落后/);
  assert(list.every(item => !item.available && !item.updateAvailable && item.expectedTag === ''));
  assert.equal(f.manager.createInstaller('8'), null);
});

await test('首次预览无缓存仍展示全部目录槽位，暂停下载且不冒用稳定推荐', async f => {
  await f.repository.configure('preview', 'github', false);
  const list = f.manager.listVersions();
  assert.deepEqual(list.map(item => item.version), ['8', '17', '21', '25']);
  for (const item of list) {
    assert.equal(item.available, false); assert.equal(item.expectedTag, ''); assert.equal(item.updateAvailable, false);
    assert.equal(item.sizeMB, 0); assert.match(item.stateText, /目录尚未获取/);
    assert.equal(f.manager.createInstaller(item.version), null);
  }
  assert.equal(f.calls.installers.length, 0);
});

await test('目录暂不可用时保留合法官方安装、用户导入及目录外数字槽位，过滤非法/损坏目录', async f => {
  f.install('8', 'older-official-eight');
  f.install('17', 'older-official-seventeen');
  f.install('21', 'imported:fixture-21');
  f.install('29', 'imported:fixture-29');
  f.install('30', 'imported:broken');
  f.files.delete('/app/jdk/30/lib/libjava.so');
  f.directoryEntries.add('017'); f.directoryEntries.add('../outside');
  await f.repository.configure('preview', 'github', false);
  const list = f.manager.listVersions();
  assert.deepEqual(list.map(item => item.version), ['8', '17', '21', '25', '29']);
  for (const major of ['8', '17', '21', '29']) assert.equal(list.find(item => item.version === major).installed, true);
  for (const major of ['21', '29']) assert.equal(list.find(item => item.version === major).userImported, true);
  for (const item of list) { assert.equal(item.available, false); assert.equal(item.updateAvailable, false); }
  assert.match(list.find(item => item.version === '21').stateText, /本地导入/);
  assert.equal(f.manager.isInstalled('29'), true);
});

await test('预览目录恢复后可创建冻结下载任务，旧官方项提示更新而导入项不被接管', async f => {
  f.install('17', 'older-official-seventeen'); f.install('21', 'imported:fixture-21'); f.install('29', 'imported:fixture-29');
  f.api.setJdkDownloadSource('gitee');
  await f.repository.configure('preview', 'gitee', false);
  assert.equal(f.manager.listVersions().find(item => item.version === '17').available, false);
  const next = catalog('preview'); f.setRemote(next);
  assert.equal((await f.repository.refresh()).ok, true);
  const list = f.manager.listVersions();
  for (const major of ['8', '17', '21', '25']) assert.equal(list.find(item => item.version === major).available, true);
  assert.equal(list.find(item => item.version === '17').updateAvailable, true);
  assert.equal(list.find(item => item.version === '21').userImported, true);
  assert.equal(list.find(item => item.version === '21').updateAvailable, false);
  assert.equal(list.find(item => item.version === '29').available, false);
  assert.equal(f.manager.createInstaller('29'), null);
  const installer = f.manager.createInstaller('17', true);
  assert(installer); assert.equal(installer.options.forceReinstall, true);
  assert.equal(installer.options.config.build.id, f.repository.buildFor('17').id);
  assert.equal(installer.options.config.downloadSource, 'gitee');
  assert.equal(installer.options.config.webEnabled, false);
  const frozenId = installer.options.config.build.id;
  next.builds.find(item => item.id === frozenId).notes.push('修改测试调用者对象');
  assert(!installer.options.config.build.notes.includes('修改测试调用者对象'));
  assert(f.calls.crypto > 0, '恢复经过了生产 DER 验签入口');
});

await test('过期可信缓存仍展示槽位和导入，暂停新下载且不伪造更新', async f => {
  const expired = catalog('preview'); expired.expiresAt = new Date(Date.now() - 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  f.cache('preview', expired); f.install('17', 'imported:expired-cache');
  await f.repository.configure('preview', 'github', false);
  const list = f.manager.listVersions();
  assert.equal(list.length, 4); assert.match(list[0].stateText, /已过期/);
  assert.equal(list.find(item => item.version === '17').installed, true);
  assert.equal(list.find(item => item.version === '17').userImported, true);
  assert(list.every(item => !item.available && !item.updateAvailable));
  assert.equal(f.manager.createInstaller('17'), null);
});

await test('已验证撤回经 buildFor 和安装器工厂共同生效，通道切换不重新放行', async f => {
  await f.repository.configure('preview', 'github', false);
  const preview = catalog('preview'); f.setRemote(preview);
  assert.equal((await f.repository.refresh()).ok, true);
  const withdrawnId = f.repository.buildFor('17').id;
  const withdrawn = structuredClone(preview); withdrawn.catalogRevision++;
  const runtime = withdrawn.runtimes.find(item => item.javaMajor === 17);
  const fallback = withdrawn.builds.find(item => item.runtimeId === runtime.id && item.provenance.kind === 'legacy');
  runtime.recommendedBuildId = fallback.id; runtime.recommendationRevision++;
  runtime.rollback = { fromBuildIds: [withdrawnId], reason: '回归测试撤回' };
  withdrawn.builds.find(item => item.id === withdrawnId).status = 'withdrawn';
  f.setRemote(withdrawn); assert.equal((await f.repository.refresh()).ok, true);
  assert.equal(f.repository.isBuildAllowed(withdrawnId), false);
  const installer = f.manager.createInstaller('17');
  assert(installer); assert.equal(installer.options.config.build.id, fallback.id);
  assert.notEqual(installer.options.config.build.id, withdrawnId);
  await f.repository.configure('stable', 'github', false);
  assert.equal(f.repository.isBuildAllowed(withdrawnId), false);
  const list = f.manager.listVersions();
  assert.equal(list.length, 4); assert(list.every(item => !item.available));
  assert.equal(f.manager.createInstaller('17'), null);
});

console.log(JSON.stringify({ passed: cases.length, cases, source: sourceRef ?? 'current worktree',
  scope: 'production Repository + Manager + tree/update policies; SDK I/O boundaries; no device execution' }, null, 2));

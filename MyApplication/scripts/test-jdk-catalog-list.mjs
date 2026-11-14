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
import { legacyRuntimeCatalogText } from './lib/legacy-runtime-catalog-fixture.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const managerPath = 'launch/src/main/ets/JdkManager.ets';
const repositoryPath = 'launch/src/main/ets/RuntimeCatalogRepository.ets';
// 换源、防回退和旧收据用例的起点是历史 v1；不把正式随包目录的发布变化误当作管理器回归。
const builtinText = legacyRuntimeCatalogText();
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

/** 生成结构合法的测试通道；具体包身份沿用固定历史目录，不伪造包字节。 */
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
function fixture(requiredCapabilities = [], initialCatalogText = builtinText) {
  const files = new Map();
  const handles = new Map();
  const directories = new Set(['/app']);
  const directoryEntries = new Set();
  const calls = { http: [], installers: [], crypto: 0 };
  let nextFd = 0;
  let remote = '';
  let relayUsable = false;
  const entry = path => { const item = files.get(path); if (!item) throw Object.assign(new Error('ENOENT: ' + path),{code:'ENOENT'}); return item; };
  const put = (path, value, size) => files.set(path, { bytes: Buffer.from(value), size });
  const fileIo = {
    OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    statSync(path) { if(directories.has(path))return{size:0,isFile:()=>false,isDirectory:()=>true};const item = entry(path); return { size: item.size ?? item.bytes.length, isFile: () => true }; },
    readTextSync: path => entry(path).bytes.toString('utf8'),
    listFileSync(path) { assert.equal(path, '/app/jdk'); return [...directoryEntries]; },
    openSync(path, flags) { if (flags & 1) put(path, ''); else if(!directories.has(path))entry(path); const fd = ++nextFd; handles.set(fd, path); return { fd }; },
    readSync(fd, buffer) { const bytes = entry(handles.get(fd)).bytes; const count = Math.min(bytes.length, buffer.byteLength); new Uint8Array(buffer).set(bytes.subarray(0, count)); return count; },
    writeSync(fd, value) { const path=handles.get(fd),bytes=Buffer.from(value);put(path,Buffer.concat([entry(path).bytes,bytes]));return bytes.length; },
    closeSync(file) { handles.delete(typeof file === 'number' ? file : file.fd); },
    fsyncSync() {},
    renameSync(from, to) { files.set(to, entry(from)); files.delete(from); },
  };
  fileIo.lstatSync=fileIo.statSync;
  // 常量和槽位语法直接取生产模块；其共享数组由真实 Manager 填充，未复制槽位判定。
  const constants = makePureEtsLoader()('commons/src/main/ets/common/Constants.ets');
  const commons = { ...constants, ensureDirSync(path) {directories.add(path);}, AppLogger: { info() {}, warn() {}, error() {} }, LogTags: { SVC_JDK: 'JdkManager' }, LOG_DOMAIN_LAUNCH: 1 };
  class InstallerBoundary {
    constructor(options) { this.options = options; calls.installers.push(options); }
  }
  const load = makePureEtsLoader({
    './RuntimeHostProtocol':{runtimeHostProtocols:()=>[1,2],runtimeRequiredCapabilities:()=>requiredCapabilities.slice()},
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
    // 本组外部事实是已提交的静态目录；真实崩溃/锁互操作由 runtime-install 验收。
    './JdkInstallStorage': { JdkInstallStorage: { recoverIfRequired() {}, recoveryRequired: () => false } },
    './JdkDirectoryLease': { JdkDirectoryLease: { reader: () => ({ release() {} }) } }, './LaunchJdkPolicy': {}, mods: {},
    feature_core: { getRelayClient: () => ({ isEnabled: () => relayUsable, status: () => ({ usable: relayUsable }) }),
      DownloadManager: { instance: () => ({ initializeCaBundle() {},
      // 新目录仍走同一受控网络边界；记录Native opt-in入参，实际列表/验签决策不替换。
      async fetchTextEx(url, mirrors, timeout, headers, maxResponseBytes, allowRelay) {
        calls.http.push({ url, options: { maxLimit: maxResponseBytes }, mirrors, timeout, headers, allowRelay });
        return { statusCode: 200, body: remote, headers: {} };
      } }) } },
  }, overrides);
  const context = { filesDir: '/app', resourceManager: { getRawFileContentSync: name =>
    new Uint8Array(Buffer.from(name.endsWith('builtin.json') ? initialCatalogText : JSON.stringify(trusted))) } };
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
    setRelayUsable(value) { relayUsable = value; },
    setRemote(value) { remote = envelope(value); },
    cache(channel, value) { put('/app/runtime-catalog/' + channel + '.json', envelope(value)); } };
}

/** 每个命名场景结束都检查短文件句柄已关闭；异常保留 Node 的原始断言与堆栈。 */
async function test(name, body,requiredCapabilities=[],initialCatalogText=builtinText) {
  const f = fixture(requiredCapabilities,initialCatalogText);
  await body(f);
  assert.equal(f.handles.size, 0, '短文件读取与缓存写入没有泄漏句柄');
  cases.push(name);
}

await test('管理器冻结保存的来源偏好，网关限制与实际竞速由任务路由器决定', async f => {
  await f.repository.configure('stable', 'github', false); f.setRemote(catalog('stable'));
  assert.equal((await f.repository.refresh()).ok, true);
  f.api.setJdkDownloadSource('auto'); f.setRelayUsable(true);
  assert.equal(f.api.isAccelActive(), true, '网关确实可用，负控不能用握手失败绕过旧策略');
  assert.ok(f.manager.createInstaller('17', true));
  assert.equal(f.calls.installers.at(-1).config.downloadSource, 'auto', '可用网关不等于更快，不能过滤Gitee锁定GitHub');
  f.setRelayUsable(false); assert.ok(f.manager.createInstaller('17', true));
  assert.equal(f.api.isAccelActive(), false, '保留Native真实状态查询API，不恢复初次缓存');
  assert.equal(f.calls.installers.at(-1).config.downloadSource, 'auto');
  for (const source of ['github', 'mirror', 'gitee', 'web']) {
    f.api.setJdkDownloadSource(source); f.setRelayUsable(true);
    assert.equal(f.api.getJdkDownloadSource(), source);
    f.setRelayUsable(false); assert.equal(f.api.getJdkDownloadSource(), source);
  }
});

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

await test('新App识别物理完整旧槽为需修复，稳定目录无兼容包时不重下同一坏包也不删除原件',async f=>{
  const old=builtin.builds.find(build=>build.id===builtin.runtimes.find(runtime=>runtime.javaMajor===17).recommendedBuildId);
  f.install('17',old.legacyTags[0]);await f.repository.configure('stable','github',false);
  const state=f.manager.inspect('17');assert.equal(state.installed,false);assert.equal(state.repairRequired,true);assert.match(state.stateText,/ZIP\/JAR/);
  assert.equal(f.manager.createInstaller('17',true),null);assert(f.files.has('/app/jdk/17/.amcl_release_tag'));assert.equal(f.calls.installers.length,0);
},['zipfs-transaction-v1']);
await test('稳定通道就绪后旧官方槽给出修复任务，新包合格后消除需修复状态',async f=>{
  const next=catalog('stable'),runtime=next.runtimes.find(item=>item.javaMajor===17),old=next.builds.find(build=>build.id===runtime.recommendedBuildId);
  const fixed=next.builds.filter(build=>build.runtimeId===runtime.id&&build.provenance.kind==='source-build').at(-1);
  fixed.capabilities=[...fixed.capabilities,'zipfs-transaction-v1'];runtime.recommendedBuildId=fixed.id;runtime.loaderProtocol=2;runtime.recommendationRevision++;
  f.install('17',old.legacyTags[0]);await f.repository.configure('stable','github',false);f.setRemote(next);assert.equal((await f.repository.refresh()).ok,true);f.manager.listVersions();
  let state=f.manager.inspect('17');assert.equal(state.repairRequired,true);assert.equal(state.offerUpdate,true);
  const installer=f.manager.createInstaller('17',true);assert.equal(installer.options.config.build.id,fixed.id);assert.equal(f.repository.snapshot().channel,'stable');
  f.put('/app/jdk/17/amcl-runtime.json',JSON.stringify({schema:1,build:{patches:{'0019-zipfs-permission-copy-transaction.patch':'a'.repeat(64),'0025-ohos-javasound-duplex-host-callbacks.patch':'b'.repeat(64)}}}));
  f.put('/app/jdk/17/.amcl_release_tag',fixed.legacyTags[0]??fixed.id);
  state=f.manager.inspect('17');assert.equal(state.installed,true);assert.equal(state.repairRequired,false);
},['zipfs-transaction-v1']);
await test('不兼容用户导入保留来源且不自动接管，明确改用官方仍由用户操作',async f=>{
  f.install('17','imported:owned');const state=f.manager.inspect('17');assert.equal(state.state,'user-import');assert.equal(state.repairRequired,true);assert.equal(state.offerUpdate,false);
  assert(f.files.has('/app/jdk/17/.amcl_release_tag'));
},['zipfs-transaction-v1']);

// 可选真机旧版收据：原字节输入实际管理器，文件头仍为I/O夹具；设备安装与覆盖另验。
const legacyIndex=process.argv.indexOf('--legacy-receipts');
if(legacyIndex>=0){
  assert.equal(sourceRef,undefined,'真机格式核验只运行当前候选源码');
  const directory=process.argv[legacyIndex+1];assert(directory);
  // 额外信任仅是应用本来携带的生产公钥，使真实旧缓存通过原验签链；不改缓存或用假签名替换。
  trusted.keys.push(...JSON.parse(fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/trusted-keys.json',import.meta.url),'utf8')).keys);
  const cacheRaw=fs.readFileSync(directory+'/stable.json','utf8');
  const cachePayload=JSON.parse(Buffer.from(JSON.parse(cacheRaw).payload,'base64url'));assert.equal(cachePayload.schemaVersion,1);
  // 覆盖升级的起点必须是当前真正随包的v2，而不是历史v1测试夹具。远端也使用同一
  // 当前目录原文，不临时抬高代次来掩盖同代v1缓存→v2的兼容问题。
  const shippingText=fs.readFileSync(new URL('../entry/src/main/resources/rawfile/runtime-catalog/builtin.json',import.meta.url),'utf8');
  const shipping=JSON.parse(shippingText);assert.equal(shipping.schemaVersion,2);assert(shipping.catalogRevision>=cachePayload.catalogRevision);
  for(const major of [8,17,21,25])await test('读取官方1.0.6真机收据并在稳定通道生成修复：'+major,async f=>{
    const raw=fs.readFileSync(directory+'/jdk-'+major+'-receipt.json','utf8'),receipt=JSON.parse(raw);
    assert.equal(receipt.javaMajor,major);assert.equal(receipt.schemaVersion,1);assert.equal(receipt.origin,'catalog');
    const next=structuredClone(shipping),runtime=next.runtimes.find(item=>item.javaMajor===major);
    const fixed=next.builds.find(build=>build.id===runtime.recommendedBuildIds[0]);
    assert.equal(fixed.requiredHostProtocol,2);assert(fixed.capabilities.includes('zipfs-transaction-v1'));
    f.install(String(major),receipt.build.legacyTags[0]);f.put('/app/jdk/'+major+'/.amcl-runtime-receipt.json',raw);
    f.put('/app/runtime-catalog/stable.json',cacheRaw);
    await f.repository.configure('stable','github',false);assert(f.calls.crypto>0,'实际旧缓存必须经过验签');
    f.setRemote(next);assert.equal((await f.repository.refresh()).ok,true);f.manager.listVersions();
    const state=f.manager.inspect(String(major));assert.equal(state.repairRequired,true);assert.equal(state.offerUpdate,true);
    assert.equal(f.manager.createInstaller(String(major),true).options.config.build.id,fixed.id);
    assert.equal(f.repository.snapshot().channel,'stable');
  },['zipfs-transaction-v1'],shippingText);
}

console.log(JSON.stringify({ passed: cases.length, cases, source: sourceRef ?? 'current worktree',
  scope: 'production Repository + Manager + tree/update policies; SDK I/O boundaries; no device execution' }, null, 2));

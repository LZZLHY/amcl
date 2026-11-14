/** 执行真实离线服务/协议；只替换HarmonyOS系统边缘，密码学使用宿主RSA/SHA实现。 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';
import compiler from './lib/ets-compiler.mjs';
import { createWorkspaceTemp } from './lib/workspace-paths.mjs';

const base64 = makePureEtsLoader()('commons/src/main/ets/utils/Base64Util.ets');
const hex = bytes => Buffer.from(bytes).toString('hex');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const commons = { ...base64, evidenceHex: hex };
const protocol = makePureEtsLoader({ commons })('entry/src/main/ets/runtime/OfflineAppearanceProtocol.ets');
const id = 'cdef0123-4567-89ab-cdef-0123456789ab';
const name = '玩家甲';
const png = Buffer.from('89504e470d0a1a0a0000000d4948445200000040000000200806000000', 'hex');
const hash = sha(png);
const asset = { id: hash, kind: 'skin', name: 'fixture.png', sha256: hash,
  relativePath: `account-textures/${hash}.png`, width: 64, height: 32, createdAt: 1 };
assert.equal(protocol.offlineAssetPath('/files', asset.relativePath, hash), `/files/${asset.relativePath}`);
for (const path of ['../escape', `account-textures/../${hash}.png`, `file:///files/${asset.relativePath}`]) {
  assert.throws(() => protocol.offlineAssetPath('/files', path, hash), /引用无效/);
}
assert.equal(protocol.offlineProfileId(id), id.replaceAll('-', ''));
assert.throws(() => protocol.offlineProfileId('invalid'), /UUID/);
const encoded = protocol.offlineTextureValue('http://127.0.0.1:1234/', id, name, 'SLIM', hash, hash, 7);
const payload = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
assert.equal(payload.profileName, name); assert.equal(payload.profileId, id.replaceAll('-', ''));
assert.deepEqual(payload.textures.SKIN.metadata, { model: 'slim' });
assert.ok(payload.textures.CAPE.url.endsWith(hash));
assert.equal(JSON.parse(Buffer.from(protocol.offlineTextureValue('http://127.0.0.1:3/', id, name, 'CLASSIC', '', hash, 9), 'base64')).textures.SKIN, undefined);
const request = Buffer.from(`POST /api/profiles/minecraft HTTP/1.1\r\nContent-Length: ${Buffer.byteLength(JSON.stringify([name]))}\r\n\r\n${JSON.stringify([name])}`);
assert.equal(protocol.parseOfflineHttpRequest(request.subarray(0, request.length - 1)).state, 'pending');
assert.equal(base64.utf8ToString(protocol.parseOfflineHttpRequest(request).body), JSON.stringify([name]));
for (const headers of ['Content-Length: -1', 'Content-Length: 1\r\nContent-Length: 1', 'Transfer-Encoding: chunked', 'Content-Length: 5000']) {
  assert.equal(protocol.parseOfflineHttpRequest(Buffer.from(`POST / HTTP/1.1\r\n${headers}\r\n\r\n`)).state, 'error');
}
assert.equal(protocol.parseOfflineHttpRequest(Buffer.alloc(16385, 65)).state, 'error');

/** 系统替身保留真实字节流和close语义；HTTP client也经过生产TCP解析与路由。 */
function fixture() {
  const files = new Map([[`/files/${asset.relativePath}`, Buffer.from(png)]]), handles = new Map();
  const servers = [], sockets = [], logs = [];
  let nextFd = 1, port = 31000, delayListen, resolveListen;
  const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  class Connection {
    events = new Map(); output = []; closed = false; done;
    on(name, callback) { this.events.set(name, callback); }
    off(name) { this.events.delete(name); }
    async send({ data }) { if (this.closed) throw new Error('closed'); this.output.push(typeof data === 'string' ? Buffer.from(data) : Buffer.from(data)); }
    async close() { this.closed = true; this.events.get('close')?.(); this.done?.(); }
  }
  class Server {
    events = new Map(); closed = false; bound;
    constructor() { servers.push(this); }
    async listen(address) { if (delayListen) await new Promise(resolve => { resolveListen = resolve; }); this.bound = { ...address, port: ++port }; }
    on(name, callback) { assert.ok(this.bound, '官方API要求listen成功后订阅'); this.events.set(name, callback); }
    off(name) { this.events.delete(name); }
    async getLocalAddress() { return this.bound; }
    async close() { this.closed = true; if (this.failClose) throw new Error('listener close failure'); }
  }
  const socket = { constructTCPSocketServerInstance: () => new Server() };
  async function dispatch(target, method = 'GET', body = '') {
    const server = servers.find(s => !s.closed && s.bound && target.startsWith(`http://127.0.0.1:${s.bound.port}/`));
    if (!server) throw new Error('server not listening');
    const connection = new Connection(); sockets.push(connection);
    const completed = new Promise(resolve => { connection.done = resolve; });
    server.events.get('connect')(connection);
    const path = new URL(target).pathname + new URL(target).search;
    const bytes = Buffer.from(`${method} ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    // 故意把正文中的多字节UTF-8也切开，生产解析器必须按字节Content-Length等待。
    for (const part of [bytes.subarray(0, 11), bytes.subarray(11, bytes.length - 2), bytes.subarray(bytes.length - 2)]) {
      connection.events.get('message')?.({ message: part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength) });
    }
    await completed;
    const response = Buffer.concat(connection.output); const split = response.indexOf('\r\n\r\n');
    return { status: Number(response.toString('ascii', 0, 12).split(' ')[1]), body: response.subarray(split + 4),
      head: response.toString('ascii', 0, split) };
  }
  const http = { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string', ARRAY_BUFFER: 'buffer' },
    createHttp: () => ({ async request(url, options) { const response = await dispatch(url); return {
      responseCode: response.status, result: options.expectDataType === 'string' ? response.body.toString('utf8') :
        response.body.buffer.slice(response.body.byteOffset, response.body.byteOffset + response.body.byteLength) }; }, destroy() {} }) };
  const fileIo = {
    OpenMode: { READ_ONLY: 1 },
    lstatSync(path) { if (path === '/files/account-textures') return { isDirectory: () => true, isSymbolicLink: () => false };
      if (!files.has(path)) throw new Error('missing'); return { isFile: () => true, isSymbolicLink: () => false }; },
    openSync(path) { if (!files.has(path)) throw new Error('missing'); const fd = nextFd++; handles.set(fd, { bytes: files.get(path), offset: 0 }); return { fd }; },
    statSync(fd) { return { size: handles.get(fd).bytes.length }; },
    readSync(fd, output) { const f = handles.get(fd), count = Math.min(output.byteLength, f.bytes.length - f.offset, 13);
      new Uint8Array(output).set(f.bytes.subarray(f.offset, f.offset + count)); f.offset += count; return count; },
    closeSync(file) { handles.delete(typeof file === 'number' ? file : file.fd); },
  };
  const cryptoFramework = {
    createAsyKeyGenerator(algorithm) { assert.equal(algorithm, 'RSA2048'); return { async generateKeyPair() {
      return { priKey: pair.privateKey, pubKey: { key: pair.publicKey, getEncoded: () => ({ data: pair.publicKey.export({ type: 'spki', format: 'der' }) }) } }; } }; },
    createSign(algorithm) { assert.equal(algorithm, 'RSA2048|PKCS1|SHA1'); let key; return {
      async init(value) { key = value; }, async sign({ data }) { return { data: crypto.sign('RSA-SHA1', data, key) }; } }; },
    createVerify() { let key; return { async init(value) { key = value.key; }, async verify({ data }, signature) { return crypto.verify('RSA-SHA1', data, key, signature.data); } }; },
    createMd(algorithm) { assert.equal(algorithm, 'SHA256'); const md = crypto.createHash('sha256'); return {
      updateSync({ data }) { md.update(data); }, digestSync() { return { data: md.digest() }; } }; },
  };
  const { OfflineAppearanceServer } = makePureEtsLoader({ commons, account: {}, '@kit.NetworkKit': { socket, http },
    '@kit.CoreFileKit': { fileIo }, '@kit.CryptoArchitectureKit': { cryptoFramework }, '@kit.BasicServicesKit': {} })
    ('entry/src/main/ets/runtime/OfflineAppearanceServer.ets');
  return { service: new OfflineAppearanceServer(message => logs.push(message)), servers, sockets, logs, files, handles, dispatch,
    holdListen() { delayListen = true; }, unblockListen() { resolveListen(); }, listening: () => resolveListen !== undefined,
    openIdle() { const connection = new Connection(); sockets.push(connection); servers.find(server => !server.closed).events.get('connect')(connection); return connection; } };
}

for (const [skin, cape] of [[asset, undefined], [undefined, { ...asset, kind: 'cape' }], [asset, { ...asset, kind: 'cape' }]]) {
  const f = fixture();
  const prepared = await f.service.start('/files', id, name, { revision: 2, model: 'SLIM', skin, cape });
  assert.equal(f.handles.size, 0); assert.equal(f.servers[0].bound.address, '127.0.0.1');
  const root = JSON.parse(Buffer.from(prepared.prefetched, 'base64')); assert.deepEqual(root.skinDomains, ['127.0.0.1']);
  const response = await f.dispatch(prepared.apiRoot + `sessionserver/session/minecraft/profile/${id.replaceAll('-', '')}?unsigned=false`);
  const profile = JSON.parse(response.body); const property = profile.properties[0];
  assert.ok(crypto.verify('RSA-SHA1', Buffer.from(property.value), root.signaturePublickey, Buffer.from(property.signature, 'base64')));
  const textures = JSON.parse(Buffer.from(property.value, 'base64')).textures;
  assert.equal(Boolean(textures.SKIN), Boolean(skin)); assert.equal(Boolean(textures.CAPE), Boolean(cape));
  assert.equal((await f.dispatch(prepared.apiRoot + 'sessionserver/session/minecraft/join', 'POST', '{}')).status, 403);
  assert.equal((await f.dispatch(prepared.apiRoot + 'sessionserver/session/minecraft/hasJoined?username=a')).status, 403);
  assert.equal((await f.dispatch(prepared.apiRoot + 'sessionserver/session/minecraft/profile/' + 'a'.repeat(32))).status, 204);
  const names = await f.dispatch(prepared.apiRoot + 'api/profiles/minecraft', 'POST', JSON.stringify([name, 'unknown']));
  assert.deepEqual(JSON.parse(names.body), [{ id: id.replaceAll('-', ''), name }]);
  assert.equal((await f.dispatch(prepared.apiRoot + 'textures/../secret')).status, 404);
  // 原资产在游戏运行时被移除，不改变已经冻结的本局字节。
  f.files.clear(); const texture = await f.dispatch(prepared.apiRoot + 'textures/' + hash);
  assert.deepEqual(texture.body, png); assert.equal(Number(/Content-Length: ([0-9]+)/.exec(texture.head)[1]), png.length);
  assert.ok(f.service.statistics().textureRequests > 0);
  const idle = f.openIdle(); assert.equal(f.service.statistics().activeConnections, 1);
  await f.service.close(); await f.service.close();
  assert.equal(idle.closed, true, 'stop必须关闭未发送完整请求的已接受连接，不能仅停listener');
  assert.ok(f.servers.every(s => s.closed)); assert.ok(f.sockets.every(s => s.closed));
  assert.equal(f.service.statistics().activeConnections, 0);
}
{
  const f = fixture(); await f.service.start('/files', id, name, { revision: 1, model: 'CLASSIC', skin: asset });
  const idle = f.openIdle(); f.servers[0].failClose = true;
  await assert.rejects(f.service.close(), /资源关闭失败/);
  assert.equal(idle.closed, true, '监听关闭失败不能跳过已接受连接的清理');
  assert.equal(f.service.statistics().activeConnections, 0);
}
{
  const f = fixture(); f.files.set(`/files/${asset.relativePath}`, Buffer.alloc(30));
  await assert.rejects(f.service.start('/files', id, name, { revision: 1, model: 'CLASSIC', skin: asset }), /校验失败/);
  assert.equal(f.servers.length, 0); assert.equal(f.handles.size, 0); await f.service.close();
}
{
  const f = fixture(); f.holdListen();
  const pending = f.service.start('/files', id, name, { revision: 1, model: 'CLASSIC', skin: asset });
  while (!f.listening()) await Promise.resolve();
  const closed = f.service.close(); f.unblockListen(); await assert.rejects(pending, /取消/); await closed;
  assert.ok(f.servers.every(s => s.closed)); assert.equal(f.service.statistics().activeConnections, 0);
}

// 官方JAR身份与运行常量/来源契约必须一致；此检查不以文件名或非空作为版本依据。
const jar = fs.readFileSync(new URL('../entry/src/main/resources/rawfile/authlib-injector.jar', import.meta.url));
assert.equal(sha(jar), '9c7f4343e6c82034958ffb48c14a2cb0c85928be7283103ce17da00c6d5a7b10');
assert.equal(jar.length, 349681);
for (const file of ['../deps.lock', '../entry/src/main/ets/runtime/AuthlibInjectorArtifact.ets']) {
  assert.ok(fs.readFileSync(new URL(file, import.meta.url), 'utf8').includes(sha(jar)));
}

/** 原生产提取器在内存FileIO边界上执行短写、旧版缓存与损坏重提取，不复制提取判定。 */
{
  const files = new Map([['/files/authlib-injector.jar', Buffer.from('old 1.2.7')]]), handles = new Map();
  let fd = 1, rawReads = 0, pendingId = 0;
  const fileIo = { OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    statSync(path) { if (!files.has(path)) throw new Error('missing'); return { isFile: () => true, size: files.get(path).length }; },
    openSync(path) { files.set(path, Buffer.alloc(0)); const opened = { fd: fd++ }; handles.set(opened.fd, path); return opened; },
    writeSync(handle, data) { const path = handles.get(handle), bytes = Buffer.from(data); const count = Math.min(8192, bytes.length);
      files.set(path, Buffer.concat([files.get(path), bytes.subarray(0, count)])); return count; },
    fsyncSync() {}, closeSync(file) { handles.delete(typeof file === 'number' ? file : file.fd); },
    renameSync(from, to) { files.set(to, files.get(from)); files.delete(from); },
    accessSync(path) { return files.has(path); }, unlinkSync(path) { files.delete(path); },
  };
  const cryptoFramework = { createMd() { const hash = crypto.createHash('sha256'); return {
    async update({ data }) { hash.update(data); }, async digest() { return { data: hash.digest() }; } }; } };
  const { ensureAuthlibInjectorArtifact: ensure, AUTHLIB_INJECTOR_SHA256: digest } = makePureEtsLoader({
    commons: { AUTHLIB_INJECTOR_JAR_NAME: 'authlib-injector.jar', evidenceHex: hex, evidenceFileDigestSync: path => sha(files.get(path)) },
    '@kit.AbilityKit': {}, '@kit.CoreFileKit': { fileIo }, '@kit.CryptoArchitectureKit': { cryptoFramework },
    '@kit.ArkTS': { util: { generateRandomUUID: () => String(++pendingId) } },
  })('entry/src/main/ets/runtime/AuthlibInjectorArtifact.ets');
  const context = { resourceManager: { async getRawFileContent() { rawReads++; return jar; } } };
  const path = await ensure(context, '/files');
  assert.equal(path, `/files/authlib-injector-${digest}.jar`); assert.equal(sha(files.get(path)), digest);
  assert.equal(files.get('/files/authlib-injector.jar').toString(), 'old 1.2.7', '旧缓存不覆盖也不被新版本复用');
  await ensure(context, '/files'); assert.equal(rawReads, 1, '精确摘要的已提取原件直接复用');
  files.set(path, Buffer.from('corrupt')); await ensure(context, '/files'); assert.equal(rawReads, 2);
  assert.equal(handles.size, 0); assert.ok([...files.keys()].every(path => !path.includes('.pending-')));
  files.delete(path);
  await assert.rejects(ensure({ resourceManager: { async getRawFileContent() { return new Uint8Array(8); } } }, '/files'), /大小不匹配/);
  assert.equal(files.has(path), false);
}

/** 抽取完整生产setter/注入方法，验证认证互斥和参数语义，不复制其决策实现。 */
{
  const relative = 'launch/src/main/ets/LaunchProfileBuilder.ets';
  const source = fs.readFileSync(new URL('../' + relative, import.meta.url), 'utf8');
  const ast = compiler.createSourceFile(relative, source, compiler.ScriptTarget.Latest, true);
  const owner = ast.statements.find(node => node.name?.getText(ast) === 'LaunchProfileBuilder');
  const selected = ['setAuthlibInjector', 'injectAuthlibArgs'].map(name => owner.members.find(node => node.name?.getText(ast) === name).getText(ast));
  const javascript = compiler.transpileModule('class Builder {\n' + selected.join('\n') + '\n}\nreturn Builder;', {
    compilerOptions: { target: compiler.ScriptTarget.ES2020 },
  }).outputText;
  const Builder = new Function('TAG', 'LOG_DOMAIN_LAUNCH', javascript)('authlib-test', 1);
  const builder = new Builder(); builder.alog = { info() {} }; let trust = 0; builder.injectJvmTrustStore = () => trust++;
  builder.setAuthlibInjector('/files/authlib-injector-hash.jar', 'http://127.0.0.1:2/', 'encoded', true);
  const args = ['-Xmx1G', '-javaagent:/files/cpu-agent.jar']; builder.injectAuthlibArgs(args);
  assert.equal(args.filter(arg => arg.startsWith('-javaagent:') && arg.includes('authlib-injector')).length, 1);
  assert.ok(args.includes('-Dauthlibinjector.yggdrasil.prefetched=encoded'));
  assert.ok(args.includes('-Dauthlibinjector.profileKey=disabled')); assert.equal(trust, 0);
  for (const duplicate of ['-javaagent:/custom/authlib-injector.jar=https://external/', '-Dauthlibinjector.yggdrasil.prefetched=other']) {
    assert.throws(() => builder.injectAuthlibArgs([duplicate]), /重复/);
  }
  builder.setAuthlibInjector('/files/authlib-injector-hash.jar', 'https://skin.example/', 'external');
  const external = []; builder.injectAuthlibArgs(external); assert.equal(trust, 1);
  assert.ok(!external.includes('-Dauthlibinjector.profileKey=disabled'), '第三方功能选项沿原服务，不套本地开关');
}
// 可指定宿主JDK执行官方原agent的真实premain。使用不可连接的API根与完整预取元数据，
// 若premain仍回查本地元数据会失败；不将此宿主证明外推到OHOS libinstrument/游戏纹理。
if (process.env.AMCL_TEST_JAVA) {
  // 官方agent默认把authlib-injector.log写到cwd；宿主测试必须将该原始证据外置，
  // 不能因应用目录忽略*.log而把它留在项目根。目录由现有工作区路由决定。
  const agentRun = createWorkspaceTemp('offline-appearance-premain-', { kind: 'run' });
  const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const metadata = { meta: { serverName: 'AMCL Local Appearance' }, skinDomains: ['127.0.0.1'],
    signaturePublickey: pair.publicKey.export({ type: 'spki', format: 'pem' }) };
  const result = spawnSync(process.env.AMCL_TEST_JAVA, [
    '-javaagent:' + fileURLToPath(new URL('../entry/src/main/resources/rawfile/authlib-injector.jar', import.meta.url)) + '=http://127.0.0.1:1/',
    '-Dauthlibinjector.yggdrasil.prefetched=' + Buffer.from(JSON.stringify(metadata)).toString('base64'),
    '-Dauthlibinjector.mojangNamespace=disabled', '-Dauthlibinjector.profileKey=disabled',
    '-Dauthlibinjector.mojangAntiFeatures=disabled', '-version',
  ], { cwd: agentRun, timeout: 15000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  assert.equal(result.error, undefined); assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout + result.stderr, /authlib-injector/);
  console.log('PASS official agent 1.2.8 real host premain with full prefetched metadata and unreachable API root');
}
console.log('PASS offline appearance: real production parser/service, RSA signed profile, skin/cape independence, loopback probes, UTF-8 fragments, auth rejection, frozen bytes, cancellation cleanup and official agent identity');

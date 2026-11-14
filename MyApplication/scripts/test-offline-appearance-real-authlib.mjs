/**
 * 真Java + 官方agent + Minecraft原版Authlib消费生产OfflineAppearanceServer。
 * 仅把HarmonyOS系统端口映射为宿主net/crypto/fs；profile解析和验签始终由真实Authlib完成。
 * 用法：node scripts/test-offline-appearance-real-authlib.mjs --inputs <锁定输入目录>
 *   --output <仓外输出目录> --java <JDK25/java> --javac <JDK17+/javac> [--manifest 26.2.json]
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { promisify } from 'node:util';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { makePureEtsLoader } from './lib/load-pure-ets.mjs';

const options = new Map();
for (let i = 2; i < process.argv.length; i += 2) options.set(process.argv[i], process.argv[i + 1]);
for (const key of ['--inputs', '--output', '--java', '--javac']) assert.ok(options.get(key), '缺少参数 ' + key);
const repository = fileURLToPath(new URL('..', import.meta.url));
const inputs = path.resolve(options.get('--inputs')), output = path.resolve(options.get('--output'));
assert.ok(!output.toLowerCase().startsWith(repository.toLowerCase()), '编译/日志输出必须位于仓库之外');
fs.mkdirSync(output, { recursive: true });
const digest = (bytes, algorithm = 'sha256') => crypto.createHash(algorithm).update(bytes).digest('hex');
const manifestPath = path.join(inputs, options.get('--manifest') ?? '26.2.json');
const manifestBytes = fs.readFileSync(manifestPath), manifest = JSON.parse(manifestBytes);
const libraries = manifest.libraries.filter(item => /^(com\.mojang:(authlib|logging):|com\.google\.code\.gson:gson:|com\.google\.guava:(guava|failureaccess):|org\.apache\.commons:commons-lang3:|commons-io:commons-io:|org\.slf4j:slf4j-api:|org\.apache\.logging\.log4j:log4j-(api|core|slf4j2-impl):)/.test(item.name));
assert.equal(libraries.filter(item => item.name.startsWith('com.mojang:authlib:')).length, 1);
const verified = libraries.map(item => {
  const artifact = item.downloads.artifact, file = path.join(inputs, 'libraries', artifact.path);
  const bytes = fs.readFileSync(file);
  assert.equal(digest(bytes, 'sha1'), artifact.sha1, 'Mojang版本元数据SHA1不匹配: ' + item.name);
  return { coordinate: item.name, file, bytes: bytes.length, sha1: artifact.sha1, sha256: digest(bytes), source: artifact.url };
});
const agent = path.join(repository, 'entry/src/main/resources/rawfile/authlib-injector.jar');
const agentSha = digest(fs.readFileSync(agent));
assert.equal(agentSha, '9c7f4343e6c82034958ffb48c14a2cb0c85928be7283103ce17da00c6d5a7b10');
const classes = path.join(output, 'classes'); fs.mkdirSync(classes, { recursive: true });
const javaSource = path.join(repository, 'tests/host/offline-appearance/RealAuthlibConsumer.java');
const compile = spawnSync(options.get('--javac'), ['--release', '17', '-d', classes, javaSource], { encoding: 'utf8' });
fs.writeFileSync(path.join(output, 'javac.log'), (compile.stdout ?? '') + (compile.stderr ?? ''));
assert.equal(compile.error, undefined); assert.equal(compile.status, 0, compile.stderr);
const javaVersion = spawnSync(options.get('--java'), ['-version'], { encoding: 'utf8' });
const javacVersion = spawnSync(options.get('--javac'), ['-version'], { encoding: 'utf8' });
assert.equal(javaVersion.status, 0); assert.equal(javacVersion.status, 0);

/** 生成确定的有效RGBA PNG，皮肤64x64、披风64x32；不引入图像依赖或游戏JAR。 */
function png(width, height, color) {
  const chunk = (type, bytes) => {
    const name = Buffer.from(type), body = Buffer.concat([name, bytes]); let crc = 0xffffffff;
    for (const byte of body) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); }
    const size = Buffer.alloc(4), sum = Buffer.alloc(4); size.writeUInt32BE(bytes.length); sum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([size, body, sum]);
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  const pixels = Buffer.alloc(height * (width * 4 + 1));
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) pixels.set(color, y * (width * 4 + 1) + 1 + x * 4);
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(pixels)), chunk('IEND', Buffer.alloc(0))]);
}
const filesDir = path.join(output, 'files'); fs.mkdirSync(path.join(filesDir, 'account-textures'), { recursive: true });
function asset(kind) {
  const width = 64, height = kind === 'skin' ? 64 : 32;
  const bytes = png(width, height, kind === 'skin' ? [59, 130, 246, 255] : [234, 88, 12, 255]);
  const sha256 = digest(bytes), relativePath = 'account-textures/' + sha256 + '.png';
  fs.writeFileSync(path.join(filesDir, relativePath), bytes);
  return { id: sha256, kind, name: kind + '.png', sha256, relativePath, width, height, createdAt: 1 };
}
const skin = asset('skin'), cape = asset('cape');
const traffic = [], servers = [];

/** 映射实际TCP字节流，不能用直接调用respond代替Java/HTTP消费。 */
class Connection {
  constructor(stream) {
    this.stream = stream; this.events = new Map(); this.request = Buffer.alloc(0); this.logged = false;
    stream.on('data', bytes => {
      if (!this.logged) {
        this.request = Buffer.concat([this.request, bytes]);
        if (this.request.includes('\r\n\r\n')) { traffic.push(this.request.toString('utf8').split('\r\n')[0]); this.logged = true; }
      }
      this.events.get('message')?.({ message: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) });
    });
    stream.on('close', () => this.events.get('close')?.());
    stream.on('error', error => this.events.get('error')?.(error));
  }
  on(name, callback) { this.events.set(name, callback); }
  off(name) { this.events.delete(name); }
  send({ data }) { return new Promise((resolve, reject) => this.stream.write(typeof data === 'string' ? data : Buffer.from(data), error => error ? reject(error) : resolve())); }
  close() { return new Promise(resolve => { if (this.stream.destroyed) resolve(); else this.stream.end(() => { this.stream.destroy(); resolve(); }); }); }
}
class Server {
  constructor() {
    this.events = new Map(); this.closed = undefined;
    this.server = net.createServer(stream => { const connection = new Connection(stream); const receiver = this.events.get('connect'); if (receiver) receiver(connection); else stream.destroy(); });
    this.server.on('error', error => this.events.get('error')?.(error)); servers.push(this);
  }
  listen(address) { return new Promise((resolve, reject) => { this.server.once('error', reject); this.server.listen(address.port, address.address, () => { this.server.off('error', reject); resolve(); }); }); }
  on(name, callback) { this.events.set(name, callback); }
  off(name) { this.events.delete(name); }
  async getLocalAddress() { const address = this.server.address(); return { address: address.address, port: address.port, family: 1 }; }
  async close() {
    // 鸿蒙TCPSocketServer.close只停listener，不等待已接受连接；Node的完成回调另留给测试收尾。
    this.closed = new Promise((resolve, reject) => this.server.close(error => error ? reject(error) : resolve()));
  }
}
const socket = { constructTCPSocketServerInstance: () => new Server() };
const nativeHttp = { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string', ARRAY_BUFFER: 'buffer' }, createHttp: () => ({
  request(url, options) { return new Promise((resolve, reject) => { const request = http.get(url, response => {
    const buffers = []; response.on('data', bytes => buffers.push(bytes)); response.on('error', reject);
    response.on('end', () => { const bytes = Buffer.concat(buffers); resolve({ responseCode: response.statusCode,
      result: options.expectDataType === 'string' ? bytes.toString('utf8') : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) }); });
  }); request.setTimeout(3000, () => request.destroy(new Error('HTTP probe timeout'))); request.on('error', reject); }); }, destroy() {},
}) };
const fileIo = { OpenMode: { READ_ONLY: fs.constants.O_RDONLY }, lstatSync: path => fs.lstatSync(path),
  openSync: (path, flags) => ({ fd: fs.openSync(path, flags) }), statSync: file => typeof file === 'number' ? fs.fstatSync(file) : fs.statSync(file),
  readSync: (fd, output, options) => fs.readSync(fd, Buffer.from(output), 0, options.length, null),
  closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd) };
const cryptoFramework = {
  createAsyKeyGenerator: () => ({ async generateKeyPair() { const pair = await promisify(crypto.generateKeyPair)('rsa', { modulusLength: 2048 }); return {
    priKey: pair.privateKey, pubKey: { key: pair.publicKey, getEncoded: () => ({ data: pair.publicKey.export({ type: 'spki', format: 'der' }) }) } }; } }),
  createSign: algorithm => { assert.equal(algorithm, 'RSA2048|PKCS1|SHA1'); let key; return { async init(value) { key = value; },
    async sign({ data }) { return { data: crypto.sign('RSA-SHA1', data, key) }; } }; },
  createVerify: algorithm => { assert.equal(algorithm, 'RSA2048|PKCS1|SHA1'); let key; return { async init(value) { key = value.key; },
    async verify({ data }, signed) { return crypto.verify('RSA-SHA1', data, key, signed.data); } }; },
  createMd: algorithm => { assert.equal(algorithm, 'SHA256'); const hash = crypto.createHash('sha256'); return {
    updateSync({ data }) { hash.update(data); }, digestSync() { return { data: hash.digest() }; } }; },
};
const base64 = makePureEtsLoader()('commons/src/main/ets/utils/Base64Util.ets');
const { OfflineAppearanceServer } = makePureEtsLoader({ commons: { ...base64, evidenceHex: bytes => Buffer.from(bytes).toString('hex') },
  account: {}, '@kit.NetworkKit': { socket, http: nativeHttp }, '@kit.CoreFileKit': { fileIo },
  '@kit.CryptoArchitectureKit': { cryptoFramework }, '@kit.BasicServicesKit': {},
})('entry/src/main/ets/runtime/OfflineAppearanceServer.ets');

/** 异步启动Java使宿主事件循环继续服务TCP；期限失败杀本次测试子进程，finally仍停原服务。 */
function runJava(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(options.get('--java'), args, { cwd: output, windowsHide: true }); let stdout = '', stderr = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error('真实Authlib验证超过30秒')); }, 30000);
    child.stdout.on('data', bytes => { stdout += bytes; }); child.stderr.on('data', bytes => { stderr += bytes; });
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}
const receipts = [];
try {
  for (const mode of ['classic', 'slim', 'cape-only']) {
    const logs = [], service = new OfflineAppearanceServer(message => logs.push(message));
    const uuid = 'cdef0123-4567-89ab-cdef-0123456789ab', name = 'AMCL_Local';
    const appearance = { revision: 1, model: mode === 'slim' ? 'SLIM' : 'CLASSIC', skin: mode === 'cape-only' ? undefined : skin, cape };
    const startTraffic = traffic.length;
    try {
      const launch = await service.start(filesDir, uuid, name, appearance);
      const root = JSON.parse(Buffer.from(launch.prefetched, 'base64'));
      const publicKey = root.signaturePublickey.replace(/-----[^-]+-----|\s/g, '');
      const result = await runJava(['-javaagent:' + agent + '=' + launch.apiRoot,
        '-Dauthlibinjector.yggdrasil.prefetched=' + launch.prefetched, '-Dauthlibinjector.mojangNamespace=disabled',
        '-Dauthlibinjector.profileKey=disabled', '-Dauthlibinjector.mojangAntiFeatures=disabled',
        '-cp', [classes, ...verified.map(item => item.file)].join(path.delimiter), 'RealAuthlibConsumer',
        uuid, name, mode === 'slim' ? 'slim' : 'default', appearance.skin?.sha256 ?? '', cape.sha256, publicKey]);
      fs.writeFileSync(path.join(output, mode + '.java.log'), result.stdout + '\nSTDERR:\n' + result.stderr);
      const stats = service.statistics();
      receipts.push({ mode, apiRoot: launch.apiRoot, stats, requests: traffic.slice(startTraffic),
        javaExitCode: result.code, result: result.code === 0 ? 'PASS' : 'FAIL' });
      assert.equal(result.code, 0, result.stdout + result.stderr);
      assert.match(result.stdout, /PASS real Authlib consumer/);
      assert.ok(stats.profileRequests >= 3); assert.ok(stats.textureRequests > 2);
      console.log('PASS real Authlib ' + manifest.id + ' ' + mode + ': ' + JSON.stringify(stats));
    } finally { await service.close(); fs.writeFileSync(path.join(output, mode + '.service.log'), logs.join('\n')); }
  }
} finally {
  await Promise.all(servers.map(server => server.closed).filter(Boolean));
  fs.writeFileSync(path.join(output, 'http-requests.log'), traffic.join('\n'));
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ time: new Date().toISOString(), minecraft: manifest.id,
    versionMetadata: { file: manifestPath, sha256: digest(manifestBytes) }, libraries: verified, agent: { file: agent, sha256: agentSha },
    java: { file: options.get('--java'), version: javaVersion.stdout + javaVersion.stderr },
    javac: { file: options.get('--javac'), version: javacVersion.stdout + javacVersion.stderr }, cases: receipts }, null, 2));
}

/** R0回归执行真实原子writer/HUKS/Vault，只有FileIO和硬件密钥接口替换；不触及真实密钥或账号。 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import compiler from './lib/ets-compiler.mjs';
import { PROJECT_ROOT, workspaceTempRoot } from './lib/workspace-paths.mjs';

/** 每个夹具拥有唯一外置目录；短写/同步错误仅作用于受控平台接口，生产业务从源码直接加载。 */
function fixture({ shortWrite = Infinity, failAt = '', randomId } = {}) {
  const parent = workspaceTempRoot();
  const directory = fs.mkdtempSync(path.join(parent, 'amcl-update-storage-')).replaceAll('\\', '/');
  const modules = new Map(), keyMap = new Map(), sessions = new Map();
  const directoryDescriptors = new Map();
  let nextDirectoryDescriptor = -100;
  const state = { writeCount: 0, renamed: 0, generated: 0, aborted: 0, hasFailure: false, finishFailure: false, observed: [] };
  const files = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 64, NOFOLLOW: 131072 },
    accessSync: fs.existsSync, readTextSync: p => fs.readFileSync(p, 'utf8'),
    statSync(p) { const s = directoryDescriptors.has(p) ? fs.statSync(directoryDescriptors.get(p)) : typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p); return { size: s.size, isFile: () => s.isFile() }; },
    mkdirSync(p, recursive = false) { fs.mkdirSync(p, { recursive }); },
    openSync(p, mode = 0) {
      // Windows不能用Node打开目录fd；这里只替换OHOS明确支持的目录I/O边界，失败仍可单独注入。
      if (fs.existsSync(p) && fs.statSync(p).isDirectory()) { const fd = nextDirectoryDescriptor--; directoryDescriptors.set(fd, p); return { fd }; }
      return { fd: fs.openSync(p, mode === 0 ? 'r' : 'w') };
    },
    closeSync(f) { const fd = typeof f === 'number' ? f : f.fd; if (directoryDescriptors.has(fd)) directoryDescriptors.delete(fd); else fs.closeSync(fd); },
    writeSync(fd, data) {
      state.writeCount++;
      if (failAt === 'write') throw new Error('ENOSPC');
      if (failAt === 'zero') return 0;
      const bytes = Buffer.from(data);
      return fs.writeSync(fd, bytes, 0, Math.min(bytes.length, shortWrite));
    },
    fsyncSync(fd) {
      const dir = directoryDescriptors.has(fd);
      if (failAt === (dir ? 'directory-sync' : 'file-sync')) throw new Error('EIO');
      if (!dir) fs.fsyncSync(fd);
    },
    renameSync(a, b) { if (failAt === 'rename') throw new Error('EIO'); fs.renameSync(a, b); state.renamed++; },
    unlinkSync: fs.unlinkSync, rmdirSync: fs.rmdirSync, listFileSync: fs.readdirSync,
  };
  const HuksTag = { HUKS_TAG_ALGORITHM: 1, HUKS_TAG_KEY_SIZE: 2, HUKS_TAG_PURPOSE: 3, HUKS_TAG_BLOCK_MODE: 4,
    HUKS_TAG_PADDING: 5, HUKS_TAG_DIGEST: 6, HUKS_TAG_NONCE: 7, HUKS_TAG_AE_TAG: 8, HUKS_TAG_KEY_OVERRIDE: 9 };
  const property = (options, tag) => options.properties.find(p => p.tag === tag)?.value;
  const huks = { HuksTag, HuksKeyAlg: { HUKS_ALG_AES: 1 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 }, HuksCipherMode: { HUKS_MODE_GCM: 1 },
    HuksKeyPadding: { HUKS_PADDING_NONE: 0 }, HuksKeyDigest: { HUKS_DIGEST_NONE: 0 },
    async hasKeyItem(alias) { if (state.hasFailure) { state.hasFailure = false; throw Object.assign(new Error('IPC failure'), { code: 12000005 }); } return keyMap.has(alias); },
    async generateKeyItem(alias, options) {
      state.observed.push(options);
      assert.equal(property(options, HuksTag.HUKS_TAG_KEY_OVERRIDE), false, 'production must disable alias overwrite');
      if (keyMap.has(alias)) throw new Error('Alias already exists');
      state.generated++; keyMap.set(alias, crypto.randomBytes(32));
    },
    async initSession(alias) { if (!keyMap.has(alias)) throw new Error('Key missing'); const handle = sessions.size + 1; sessions.set(handle, alias); return { handle }; },
    async finishSession(handle, options) {
      if (state.finishFailure) throw new Error('Hardware temporary failure');
      const alias = sessions.get(handle), key = keyMap.get(alias), nonce = Buffer.from(property(options, HuksTag.HUKS_TAG_NONCE));
      const input = Buffer.from(options.inData);
      const decrypt = property(options, HuksTag.HUKS_TAG_PURPOSE) === 2;
      const cipher = decrypt ? crypto.createDecipheriv('aes-256-gcm', key, nonce) : crypto.createCipheriv('aes-256-gcm', key, nonce);
      if (decrypt) cipher.setAuthTag(Buffer.from(property(options, HuksTag.HUKS_TAG_AE_TAG)));
      let output = Buffer.concat([cipher.update(input), cipher.final()]);
      if (!decrypt) output = Buffer.concat([output, cipher.getAuthTag()]);
      sessions.delete(handle); return { outData: new Uint8Array(output) };
    },
    async abortSession(handle) { sessions.delete(handle); state.aborted++; },
  };
  const logger = { info() {}, warn() {}, error() {} };
  const digestKit = { createRandom: () => ({ generateRandomSync: count => ({ data: new Uint8Array(crypto.randomBytes(count)) }) }),
    createMd: algorithm => { const hash = crypto.createHash(algorithm.toLowerCase()); return { async update({ data }) { hash.update(data); }, async digest() { return { data: new Uint8Array(hash.digest()) }; } }; } };
  function load(relative) {
    if (modules.has(relative)) return modules.get(relative);
    const source = fs.readFileSync(path.join(PROJECT_ROOT, relative), 'utf8');
    const js = compiler.transpileModule(source, { compilerOptions: { module: compiler.ModuleKind.CommonJS, target: compiler.ScriptTarget.ES2020 } }).outputText;
    const exports = {}; modules.set(relative, exports);
    const require = name => {
      if (name === '@kit.CoreFileKit') return { fileIo: files };
      if (name === '@kit.ArkTS') return { util: { generateRandomUUID: randomId ?? (() => crypto.randomUUID()) } };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: digestKit };
      if (name === '@kit.UniversalKeystoreKit') return { huks };
      if (name === '@kit.AbilityKit') return {};
      if (name === 'commons') return { ...load('commons/src/main/ets/utils/Base64Util.ets'), ...load('commons/src/main/ets/utils/AtomicFileWriter.ets'), AppLogger: logger };
      if (name === 'account') return load('account/src/main/ets/HuksCryptoProvider.ets');
      if (name.startsWith('.')) return load(path.relative(PROJECT_ROOT, path.resolve(PROJECT_ROOT, path.dirname(relative), name + '.ets')).replaceAll('\\', '/'));
      throw new Error('Unmocked dependency: ' + name);
    };
    new Function('exports', 'require', js)(exports, require);
    return exports;
  }
  return { directory, files, state, keyMap, sessions, load,
    close() {
      // Windows递归清理只限mkdtemp独占的测试子目录，先核对物理绝对父路径与前缀。
      const resolved = fs.realpathSync(directory), base = fs.realpathSync(parent);
      assert.equal(path.dirname(resolved), base); assert(path.basename(resolved).startsWith('amcl-update-storage-'));
      fs.rmSync(resolved, { recursive: true, force: true });
    },
  };
}

test('actual writer completes short UTF-8 writes and respects binary subview boundaries', () => {
  const f = fixture({ shortWrite: 3 });
  try {
    const { AtomicFileWriter } = f.load('commons/src/main/ets/utils/AtomicFileWriter.ets');
    const output = f.directory + '/record.json';
    AtomicFileWriter.write(output, '中文🙂完整');
    assert.equal(fs.readFileSync(output, 'utf8'), '中文🙂完整'); assert(f.state.writeCount > 1);
    AtomicFileWriter.write(output, new Uint8Array([9, 1, 2, 3, 9]).subarray(1, 4));
    assert.deepEqual([...fs.readFileSync(output)], [1, 2, 3]);
    assert.deepEqual(fs.readdirSync(f.directory), ['record.json']);
  } finally { f.close(); }
});

for (const failAt of ['write', 'zero', 'file-sync', 'rename', 'directory-sync']) {
  test('actual writer classifies ' + failAt + ' without inventing a rollback', () => {
    const f = fixture({ failAt });
    try {
      const { AtomicFileWriter, AtomicWriteError } = f.load('commons/src/main/ets/utils/AtomicFileWriter.ets');
      const output = f.directory + '/record.json'; fs.writeFileSync(output, 'OLD');
      assert.throws(() => AtomicFileWriter.write(output, 'NEW'), e => e instanceof AtomicWriteError &&
        e.kind === (failAt === 'directory-sync' ? 'durability-unknown' : 'not-committed'));
      assert.equal(fs.readFileSync(output, 'utf8'), failAt === 'directory-sync' ? 'NEW' : 'OLD');
    } finally { f.close(); }
  });
}

test('temporary namespace collision preserves the other writer files', () => {
  const f = fixture({ randomId: () => 'fixed-owned-id' });
  try {
    const namespace = f.directory + '/record.json.fixed-owned-id.pending-dir'; fs.mkdirSync(namespace);
    fs.writeFileSync(namespace + '/content.pending', 'OTHER');
    const { AtomicFileWriter } = f.load('commons/src/main/ets/utils/AtomicFileWriter.ets');
    assert.throws(() => AtomicFileWriter.write(f.directory + '/record.json', 'NEW'));
    assert.equal(fs.readFileSync(namespace + '/content.pending', 'utf8'), 'OTHER');
  } finally { f.close(); }
});

test('transient HUKS existence fault never generates and later reuse decrypts the same key', async () => {
  const f = fixture();
  try {
    const { HuksAesGcm256Provider: Provider } = f.load('account/src/main/ets/HuksCryptoProvider.ets');
    const alias = 'amcl_sideload_signing_v1', old = crypto.randomBytes(32); f.keyMap.set(alias, old);
    const provider = new Provider(alias); f.state.hasFailure = true;
    assert.equal(await provider.isAvailable(), false); assert.equal(f.state.generated, 0); assert.equal(f.keyMap.get(alias), old);
    assert.equal(await provider.isAvailable(), true);
    const encrypted = await provider.encrypt('旧私钥仍可恢复', false);
    assert.equal(await new Provider(alias).decrypt(encrypted), '旧私钥仍可恢复'); assert.equal(f.state.generated, 0);
  } finally { f.close(); }
});

test('concurrent providers create once and decrypt with missing key never creates', async () => {
  const f = fixture();
  try {
    const { HuksAesGcm256Provider: Provider } = f.load('account/src/main/ets/HuksCryptoProvider.ets');
    const providers = Array.from({ length: 8 }, () => new Provider('amcl_sideload_auth_v1'));
    assert.deepEqual(await Promise.all(providers.map(p => p.isAvailable())), Array(8).fill(true)); assert.equal(f.state.generated, 1);
    await assert.rejects(new Provider('amcl_missing_key').decrypt({ iv: 'x', tag: 'x', ciphertext: 'x' }), /原密钥不存在/);
    assert.equal(f.state.generated, 1);
  } finally { f.close(); }
});

test('failed finish aborts its actual hardware session and preserves the old key', async () => {
  const f = fixture();
  try {
    const { HuksAesGcm256Provider: Provider } = f.load('account/src/main/ets/HuksCryptoProvider.ets');
    const provider = new Provider('amcl_sideload_signing_v1'); await provider.isAvailable(); f.state.finishFailure = true;
    await assert.rejects(provider.encrypt('私有测试数据'));
    assert.equal(f.state.aborted, 1); assert.equal(f.sessions.size, 0); assert.equal(f.state.generated, 1);
  } finally { f.close(); }
});

test('only verified fresh login recovers a definitely missing auth key and preserves the old ciphertext', async () => {
  const f = fixture();
  try {
    const { DeveloperAuthVault } = f.load('entry/src/main/ets/sideload/DeveloperAuthVault.ets');
    const alias = 'amcl_sideload_auth_v1';
    const credential = { schema: 1, jwt: 'fixture-verified-jwt', expiresAt: Date.now() + 60000, savedAt: Date.now() };
    const first = new DeveloperAuthVault({ filesDir: f.directory });
    await first.save(credential, () => true, true);
    const original = fs.readFileSync(f.directory + '/sideload-update/developer-auth.json', 'utf8');
    f.keyMap.delete(alias);
    const restored = new DeveloperAuthVault({ filesDir: f.directory });
    await assert.rejects(restored.save({ ...credential, jwt: '' }, () => true));
    assert.equal(f.state.generated, 1);
    assert.equal(fs.readFileSync(f.directory + '/sideload-update/developer-auth.json', 'utf8'), original);
    f.state.hasFailure = true;
    await assert.rejects(restored.save(credential, () => true, true), /IPC failure/);
    assert.equal(f.state.generated, 1);
    await restored.save(credential, () => true, true);
    assert.equal(f.state.generated, 2);
    assert.equal((await restored.read()).jwt, credential.jwt);
    const backups = fs.readdirSync(f.directory + '/sideload-update').filter(name => name.includes('.retired-'));
    assert.equal(backups.length, 1);
    assert.equal(fs.readFileSync(f.directory + '/sideload-update/' + backups[0], 'utf8'), original);
    const current = fs.readFileSync(f.directory + '/sideload-update/developer-auth.json', 'utf8');
    await restored.save({ ...credential, jwt: 'late-cancelled' }, () => false, true);
    assert.equal(fs.readFileSync(f.directory + '/sideload-update/developer-auth.json', 'utf8'), current);
  } finally { f.close(); }
});

test('user import cannot forge cloud provenance and internal binding survives actual encryption', async () => {
  const f = fixture();
  try {
    const { SigningVault } = f.load('entry/src/main/ets/sideload/SigningVault.ets');
    const vault = new SigningVault({ filesDir: f.directory });
    const material = { schema: 1, keyAlias: 'test', keyPassword: 'fake-only', storePassword: 'fake-only', signAlg: 'SHA256withECDSA',
      p12Base64: Buffer.from('test-p12').toString('base64'), certificateBase64: Buffer.from('test-cert').toString('base64'), profileBase64: Buffer.from('test-profile').toString('base64'),
      origin: 'cloud-bound', appIdentifier: 'forged' };
    await vault.importBundle(JSON.stringify(material));
    const imported = await vault.readProof(); assert.equal(imported.origin, 'imported'); assert.equal(imported.appIdentifier, '');
    const binding = { teamId: 'verified-team', appIdentifier: 'verified-app', bundleName: 'com.amcl.launcher', verifiedAt: Date.now() };
    await vault.storeVerifiedCloudMaterial(material, binding);
    const bound = await vault.readProof(); assert.equal(bound.origin, 'cloud-bound'); assert.equal(bound.appIdentifier, 'verified-app');
    assert.notEqual(imported.revision, bound.revision);
    const extracted = await vault.materialize(f.directory + '/private');
    assert.equal(extracted.revision, bound.revision);
    const config = JSON.parse(fs.readFileSync(f.directory + '/private/config.json', 'utf8'));
    assert.equal(config.materialOrigin, 'cloud-bound'); assert.equal(config.cloudProfileSha256, bound.profileSha256);
    assert.match(config.materialRecordId, /^[0-9a-f]{32}$/); assert.equal(config.materialRecordId, bound.recordId);
    assert(fs.readdirSync(f.directory + '/sideload-update').some(name => name.includes('.retired-')));
    vault.clearTemporary(f.directory + '/private'); assert(!fs.existsSync(f.directory + '/private/config.json'));
    await assert.rejects(vault.storeVerifiedCloudMaterial(material, binding, () => { throw new Error('已取消'); }), /取消/);
    assert.equal((await vault.readProof()).revision, bound.revision);
  } finally { f.close(); }
});

test('same public certificates with new private signing configuration always change the stored revision', async () => {
  const f = fixture();
  try {
    const { SigningVault } = f.load('entry/src/main/ets/sideload/SigningVault.ets');
    const vault = new SigningVault({ filesDir: f.directory });
    const material = { schema: 1, keyAlias: 'first', keyPassword: 'fixture-only-first', storePassword: 'fixture-only-first', signAlg: 'SHA256withECDSA',
      p12Base64: Buffer.from('first test p12').toString('base64'), certificateBase64: Buffer.from('same cert').toString('base64'), profileBase64: Buffer.from('same profile').toString('base64') };
    await vault.importBundle(JSON.stringify(material)); const first = await vault.readProof();
    assert.equal((await vault.readProof()).revision, first.revision, 'read must not manufacture a new revision');
    await vault.importBundle(JSON.stringify({ ...material, keyAlias: 'second', keyPassword: 'fixture-only-second', p12Base64: Buffer.from('second test p12').toString('base64') }));
    const second = await vault.readProof();
    assert.equal(second.certificateSha256, first.certificateSha256); assert.equal(second.profileSha256, first.profileSha256);
    assert.notEqual(second.revision, first.revision); assert.notEqual(second.recordId, first.recordId);
    let checks = 0;
    await assert.rejects(vault.saveDraft({ schema: 1, id: 'a'.repeat(32), p12Base64: material.p12Base64, csr: 'fixture' }, () => { if (++checks > 1) throw new Error('已取消草稿提交'); }), /取消/);
    assert.equal(fs.existsSync(f.directory + '/sideload-update/signing-draft.json'), false);
  } finally { f.close(); }
});

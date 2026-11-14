#!/usr/bin/env node
/**
 * quick HAP 轻量校验的边界回归。所有 ZIP/ELF 均为小型人工样本，验签通过注入替身，
 * 不调用真实 SDK、Java 或构建；CLI 参数仍单独验证没有验签绕过入口。
 * 样本保留在统一外置运行目录，便于复核失败载荷，不在工程内生成临时文件。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { checkQuickHap, quickHapArguments } from './check-quick-hap.mjs';
import { readRuntimeHostConfiguration } from './runtime-host-contract.mjs';
import { createWorkspaceTemp } from './lib/workspace-paths.mjs';
import { elfAbiFixture, entryAbiFixture, providerFixtureSymbols } from './fixtures/elf-abi-fixture.mjs';
// 既有 full 基础设施入口同时覆盖 ABI 字节反例；quick 构建本身只运行当前产物检查。
import './test-check-application-abi.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// 正向产物按本次源码声明生成，避免协议升级后仍在更早的元数据断言失败，
// 从而掩盖该用例真正要验证的ABI、签名或文件替换分支。负例在fixture参数中显式覆盖。
const runtimeHost = readRuntimeHostConfiguration(ROOT);
const fixtures = createWorkspaceTemp('quick-hap-fixtures-', { kind: 'run', root: ROOT });
/**
 * 调用方先解析真实路径，再判定是否位于工程内。Windows跨盘relative返回绝对路径，
 * 不能只用“是否以..开头”判断；名为..cache的真实子目录也必须保留工程保护。
 */
function insideDirectory(parent, candidate, paths = path) {
  const relative = paths.relative(parent, candidate);
  return relative === '' || (!paths.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + paths.sep));
}
// node:test 完成并决定退出码后再收尾；失败保留夹具，成功保存小收据后只清本轮mkdtemp。
process.once('exit', code => {
  if (code !== 0) return;
  const owned = fs.realpathSync(fixtures), expectedParent = fs.realpathSync(path.dirname(fixtures));
  if (fs.lstatSync(fixtures).isSymbolicLink() || path.dirname(owned) !== expectedParent ||
      insideDirectory(fs.realpathSync(ROOT), owned)) throw new Error('Unsafe quick HAP fixture cleanup target');
  fs.writeFileSync(owned + '.receipt.json', JSON.stringify({ schemaVersion: 1, ok: true,
    observedAt: new Date().toISOString(), scope: 'quick HAP production validation with signature fixture boundary' }) + '\n', { flag: 'wx' });
  fs.rmSync(owned, { recursive: true });
});
test('清理归属区分跨盘外部目录、工程本身和点号前缀子目录', () => {
  for (const [candidate, expected] of [['D:\\repo', true], ['D:\\repo\\child', true], ['D:\\repo\\..cache', true],
    ['D:\\outside', false], ['D:\\repo-old\\child', false], ['E:\\fixtures\\owned', false]]) {
    assert.equal(insideDirectory('D:\\repo', candidate, path.win32), expected, candidate);
  }
  assert.equal(insideDirectory('/repo', '/repo/..cache', path.posix), true);
  assert.equal(insideDirectory('/repo', '/outside', path.posix), false);
});
fs.mkdirSync(path.join(fixtures, 'config'));
fs.copyFileSync(path.join(ROOT, 'config/products.json'), path.join(fixtures, 'config/products.json'));
fs.copyFileSync(path.join(ROOT, 'config/runtime-host.json'), path.join(fixtures, 'config/runtime-host.json'));
let caseNumber = 0;
const provider = elfAbiFixture(providerFixtureSymbols);
fs.mkdirSync(path.join(fixtures, 'entry/libs/arm64-v8a'), { recursive: true });
fs.writeFileSync(path.join(fixtures, 'entry/libs/arm64-v8a/libc++_shared.so'), provider);
fs.mkdirSync(path.join(fixtures, 'prebuilt/abi'), { recursive: true });
fs.writeFileSync(path.join(fixtures, 'prebuilt/abi/build-provenance.json'), JSON.stringify({
  artifactSha256: createHash('sha256').update(provider).digest('hex'), artifactBytes: provider.length }));
const nativeDirectory = path.join(fixtures, 'entry/build/default/intermediates/cmake/default/obj/arm64-v8a');
fs.mkdirSync(nativeDirectory, { recursive: true });
fs.writeFileSync(path.join(nativeDirectory, 'libentry.so'), entryAbiFixture());

/** 构造 stored ZIP 的必要结构；保留重复条目的能力，专门验证唯一性拒绝路径。 */
function zip(entries) {
  const locals = [], centrals = []; let offset = 0;
  for (const [entryName, value] of entries) {
    const name = Buffer.from(entryName), data = Buffer.from(value), local = Buffer.alloc(30), central = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4);
    local.writeUInt32LE(data.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(name.length, 26);
    const record = Buffer.concat([local, name, data]); locals.push(record);
    central.writeUInt32LE(0x02014b50); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6);
    central.writeUInt32LE(data.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(name.length, 28); central.writeUInt32LE(offset, 42);
    centrals.push(Buffer.concat([central, name])); offset += record.length;
  }
  const central = Buffer.concat(centrals), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(central.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, central, end]);
}

/** 最小 ELF64/AArch64 元数据；测试只验证轻量身份/ABI 门禁，不伪装成可运行共享库。 */
function elf() {
  return entryAbiFixture();
}

/** 每个样本独占 HAP/收据目录；不复用上一个失败或成功样本的文件。 */
function fixture({ moduleMode = 'debug', product = 'default', profileMode = 'debug', sourceRevision = 'a'.repeat(40), runtimeHostProtocols = runtimeHost.supportedProtocols, runtimePlanProtocol = runtimeHost.runtimePlanProtocol, runtimeCatalogProtocol = runtimeHost.runtimeCatalogProtocol, releaseKind = 'stable', abc = Buffer.from('PANDA-fixture'), entries: transform = x => x, bytes, hapKind = 'signed' } = {}) {
  const directory = path.join(fixtures, String(++caseNumber)); fs.mkdirSync(directory);
  const entries = transform([['module.json', JSON.stringify({ app: { buildMode: moduleMode, versionName: '1.0.6' } })],
    ['ets/modules.abc', abc], ['resources/rawfile/product-profile.json', JSON.stringify({ schemaVersion: 1, name: product, build: { mode: profileMode }, sourceRevision, runtimeHostProtocols, runtimePlanProtocol,runtimeCatalogProtocol,
      runtimeRequiredCapabilities:runtimeHost.requiredRuntimeCapabilities,runtimeRequiredMajors:runtimeHost.requiredRuntimeMajors,releaseKind })],
    ['libs/arm64-v8a/libentry.so', elf()], ['libs/arm64-v8a/libc++_shared.so', provider]]);
  const options = { root: fixtures, product: 'default', mode: 'debug', hapKind,
    hap: path.join(directory, `entry-default-${hapKind}.hap`), receipt: path.join(directory, `quick-build-receipt-${hapKind}.json`) };
  fs.writeFileSync(options.hap, bytes ?? zip(entries)); return options;
}

/** 假验签只用于 API 测试，并断言实际路径和 artifact kind 已完整传给边界。 */
const verify = ({ root, hapPath, hapKind }) => {
  assert.equal(root, fixtures); assert(path.isAbsolute(hapPath)); assert(fs.existsSync(hapPath));
  return { artifactKind: hapKind, result: hapKind === 'signed' ? 'valid-signature' : 'no-valid-signature', verifier: 'fixture-only' };
};

test('合法signed/unsigned样本签发专用收据，明确不具full资格', () => {
  for (const hapKind of ['signed', 'unsigned']) {
    const options = fixture({ hapKind }), receipt = checkQuickHap(options, { verifySignature: verify });
    assert.equal(receipt.schema, 1); assert.equal(receipt.purpose, 'quick-development-build');
    assert.equal(receipt.validationProfile, 'quick'); assert.equal(receipt.fullQualified, false);
    assert.equal(receipt.product, 'default'); assert.equal(receipt.mode, 'debug');
    assert.match(receipt.hapSha256, /^[0-9a-f]{64}$/); assert.equal(receipt.hapPath, options.hap);
    assert.equal(receipt.hapBytes, fs.statSync(options.hap).size);
    assert(receipt.checks.every(row => row.state === 'PASS'));
    assert.deepEqual(JSON.parse(fs.readFileSync(options.receipt)), receipt);
  }
});

test('缺失/重复/空ABC及重复module/profile条目均不能签发收据', () => {
  const cases = [fixture({ entries: rows => rows.filter(([name]) => name !== 'ets/modules.abc') }), fixture({ abc: Buffer.alloc(0) })];
  for (const name of ['ets/modules.abc', 'module.json', 'resources/rawfile/product-profile.json']) {
    cases.push(fixture({ entries: rows => [...rows, rows.find(([entry]) => entry === name)] }));
  }
  for (const options of cases) {
    assert.throws(() => checkQuickHap(options, { verifySignature: () => { throw Error('structural failure must precede verification'); } }), /exactly once|must not be empty/);
    assert(!fs.existsSync(options.receipt));
  }
});

test('错产品/编译模式/源身份与损坏ZIP失败，不制造当前PASS', () => {
  const cases = [fixture({ product: 'store' }), fixture({ moduleMode: 'release' }), fixture({ profileMode: 'release' }),
    fixture({ sourceRevision: 'dirty' }), fixture({ sourceRevision: 'g'.repeat(40) }), fixture({ runtimeHostProtocols: [1, 3] }),
    fixture({ runtimeHostProtocols: [] }), fixture({ runtimePlanProtocol: 0 }),
    fixture({ runtimePlanProtocol: runtimeHost.runtimePlanProtocol + 1 }),
    fixture({ releaseKind: 'developer' }), fixture({ bytes: Buffer.alloc(0) }), fixture({ bytes: Buffer.from('broken zip') })];
  for (const options of cases) {
    assert.throws(() => checkQuickHap(options, { verifySignature: verify }));
    assert(!fs.existsSync(options.receipt));
  }
});

test('libentry缺失或错ABI失败，ABI检查不要求无关图形库存在', () => {
  const missing = fixture({ entries: rows => rows.filter(([name]) => name !== 'libs/arm64-v8a/libentry.so') });
  assert.throws(() => checkQuickHap(missing, { verifySignature: verify }), /exactly once/);
  const wrong = fixture({ entries: rows => rows.map(([name, bytes]) => [name, name.endsWith('/libentry.so') ? Buffer.alloc(64) : bytes]) });
  assert.throws(() => checkQuickHap(wrong, { verifySignature: verify }), /AArch64/);
  const withoutGraphics = checkQuickHap(fixture(), { verifySignature: verify });
  assert.equal(withoutGraphics.fullQualified, false);
});

test('验签失败/错误artifact kind/验签中HAP替换均失败且不写收据', () => {
  for (const verifier of [() => { throw Error('fixture signature failure'); },
    () => ({ artifactKind: 'unsigned', result: 'no-valid-signature' }), () => ({ artifactKind: 'signed', result: 'invalid' }),
    args => { fs.appendFileSync(args.hapPath, 'changed'); return verify(args); }]) {
    const options = fixture(); assert.throws(() => checkQuickHap(options, { verifySignature: verifier }), /signature|artifact kind|changed/);
    assert(!fs.existsSync(options.receipt));
  }
});

test('收据文件名保护full proof，CLI拒绝未知/重复参数和验签绕过', () => {
  const options = fixture(); options.receipt = path.join(path.dirname(options.receipt), 'development-build-provenance-signed.json');
  fs.writeFileSync(options.receipt, 'preserved-full-proof');
  assert.throws(() => checkQuickHap(options, { verifySignature: verify }), /dedicated/);
  assert.equal(fs.readFileSync(options.receipt, 'utf8'), 'preserved-full-proof');
  const argv = ['--root', fixtures, '--product', 'default', '--mode', 'debug', '--hap-kind', 'signed', '--hap', options.hap, '--receipt', options.receipt];
  assert.equal(quickHapArguments(argv).hapKind, 'signed');
  for (const bad of [[], [...argv, '--skip-signature', 'true'], [...argv, '--mode', 'debug'], argv.slice(0, -1)]) assert.throws(() => quickHapArguments(bad));
});

console.log(`quick-hap fixture directory: ${fixtures}`);

#!/usr/bin/env node
/**
 * quick 开发构建的轻量产物检查。只读取明确选中的 HAP、产品配置和官方验签器，
 * 不扫描源码、SDK 内容树或宿主工具链，不建立/借用 full 资格，也不写 full provenance。
 * 真实命令行始终调用既有密码学验签；仅导出的函数允许测试注入验签边界。
 */
import { createHash } from 'node:crypto';
import { lstatSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readProductRegistry, productDefinition } from './product-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { verifyHapSignature } from './check-mg-build-contract.mjs';

/** 只对当前包字节计算身份；不把 Git HEAD 或旧构建收据当成本轮内容。 */
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

/** JSON 载荷必须是对象；损坏或空载荷直接失败，不以缺字段的默认值补齐。 */
function objectEntry(bytes, name) {
  const value = JSON.parse(readUniqueZipEntry(bytes, name).toString('utf8'));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${name}: JSON object required`);
  return value;
}

/**
 * 仅核对所需 ABI 的最小 ELF 文件头，不展开图形库、动态符号或全部链接闭包。
 * 本检查证明 libentry 是 ELF64 little-endian AArch64 DYN，不能替代 full 的 DSO 审计。
 */
function entryElf(bytes) {
  if (bytes.length < 64 || !bytes.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46])) ||
      bytes[4] !== 2 || bytes[5] !== 1 || bytes[6] !== 1 || bytes.readUInt16LE(16) !== 3 ||
      bytes.readUInt16LE(18) !== 183 || bytes.readUInt32LE(20) !== 1 || bytes.readUInt16LE(52) !== 64) {
    throw new Error('libentry.so: expected ELF64 little-endian AArch64 DYN header');
  }
  return { abi: 'arm64-v8a', elfClass: 64, endianness: 'little', machine: 183, type: 'DYN', bytes: bytes.length };
}

/**
 * 检查并签发本轮 quick 收据。receipt 只能使用专用文件名，避免调用方误覆盖 full proof。
 * 验签后再次绑定 HAP 字节，防止 verifier 读取路径期间文件被替换后仍签发旧摘要。
 * 所有检查通过后才写成功收据；任一异常原样抛出，由构建入口阻断本轮成功。
 */
export function checkQuickHap(options, { verifySignature = verifyHapSignature } = {}) {
  for (const name of ['root', 'product', 'mode', 'hapKind', 'hap', 'receipt']) {
    if (typeof options?.[name] !== 'string' || !options[name]) throw new Error(`${name} is required`);
  }
  const { product, mode, hapKind } = options;
  if (!['debug', 'release'].includes(mode)) throw new Error('mode must be debug or release');
  if (!['signed', 'unsigned'].includes(hapKind)) throw new Error('hapKind must be signed or unsigned');
  const root = resolve(options.root), hapPath = resolve(root, options.hap), receiptPath = resolve(root, options.receipt);
  if (basename(receiptPath) !== `quick-build-receipt-${hapKind}.json`) throw new Error('receipt must use the dedicated quick-build-receipt filename');
  try {
    if (lstatSync(receiptPath).isSymbolicLink()) throw new Error('quick receipt must not be a symbolic link');
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const definition = productDefinition(product, readProductRegistry(root));
  const bytes = readFileSync(hapPath), hapSha256 = sha256(bytes), checks = [];
  // 既有 ZIP 读取器内部以 Buffer.from 建视图；传精确 ArrayBuffer 可避免每取一个小条目
  // 都复制整份大型 HAP。小文件若来自 Buffer 池，只在这里截取一次准确的字节范围。
  const archive = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes.buffer
    : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const pass = (id, details = {}) => checks.push({ id, state: 'PASS', ...details });
  const module = objectEntry(archive, 'module.json');
  pass('unique-module-json');
  if (module.app?.buildMode !== mode) throw new Error('module.app.buildMode does not match requested mode');
  pass('module-build-mode', { mode });
  const abc = readUniqueZipEntry(archive, 'ets/modules.abc');
  if (abc.length === 0) throw new Error('ets/modules.abc must not be empty');
  pass('unique-nonempty-abc', { bytes: abc.length });
  const metadata = objectEntry(archive, 'resources/rawfile/product-profile.json');
  if (metadata.schemaVersion !== 1 || metadata.name !== definition.name) throw new Error('product-profile product does not match requested product');
  if (metadata.build?.mode !== mode) throw new Error('product-profile build mode does not match requested mode');
  if (typeof metadata.sourceRevision !== 'string' || !/^[0-9a-f]{40}$/.test(metadata.sourceRevision)) throw new Error('product-profile source revision must be a 40-hex identity');
  pass('product-profile', { product, mode, sourceRevision: metadata.sourceRevision });
  pass('libentry-elf64-aarch64', entryElf(readUniqueZipEntry(archive, 'libs/arm64-v8a/libentry.so')));
  const signatureVerification = verifySignature({ root, hapPath, hapKind });
  const expectedResult = hapKind === 'signed' ? 'valid-signature' : 'no-valid-signature';
  if (signatureVerification?.artifactKind !== hapKind || signatureVerification?.result !== expectedResult) throw new Error('signature verification did not confirm the selected artifact kind');
  pass('hap-signature', { artifactKind: hapKind, result: signatureVerification.result });
  if (sha256(readFileSync(hapPath)) !== hapSha256) throw new Error('HAP bytes changed during signature verification');
  pass('stable-hap-bytes');
  const receipt = { schema: 1, purpose: 'quick-development-build', validationProfile: 'quick', fullQualified: false,
    product, mode, hapKind, hapSha256, hapPath, hapBytes: bytes.length, checkedAtUTC: new Date().toISOString(),
    signatureVerification, checks };
  mkdirSync(dirname(receiptPath), { recursive: true });
  writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + '\n');
  return receipt;
}

/** 严格具名 CLI：所有参数必须显式传递，未知/重复参数及任何验签绕过开关均拒绝。 */
export function quickHapArguments(argv) {
  const names = new Map([['--root', 'root'], ['--product', 'product'], ['--mode', 'mode'],
    ['--hap-kind', 'hapKind'], ['--hap', 'hap'], ['--receipt', 'receipt']]);
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = names.get(argv[index]), value = argv[index + 1];
    if (!name || Object.hasOwn(options, name) || !value || value.startsWith('--')) throw new Error(`Invalid, duplicate or missing CLI argument: ${argv[index]}`);
    options[name] = value;
  }
  for (const name of names.values()) if (!options[name]) throw new Error(`${name} is required`);
  return options;
}

// import 只暴露函数；正式 CLI 不接受注入函数，不读取任何测试验签环境变量。
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const receipt = checkQuickHap(quickHapArguments(process.argv.slice(2)));
    console.log(`[quick-hap] PASS ${receipt.product}/${receipt.mode}/${receipt.hapKind} sha256=${receipt.hapSha256}; fullQualified=false`);
  } catch (error) { console.error(`[quick-hap] FAIL: ${error.message}`); process.exitCode = 1; }
}

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { diagnosticProfile, DIAGNOSTIC_FLAGS } from './diagnostic-profile.mjs';
import { evaluateDiagnosticGetter, evaluateDiagnosticHap } from './check-diagnostics-contract.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

assert.equal(diagnosticProfile('default').mode, 'debug');
assert.equal(diagnosticProfile('default').mask, 3);
assert.equal(diagnosticProfile('default', 'release').mask, 1);
// 开发身份本身不能开启资源 trace；显式申请在 release/debug 都只增加固定的位 9。
assert.equal(diagnosticProfile('default', 'release').flags.AMCL_VULKAN_WSI_TRACE, 'OFF');
assert.equal(diagnosticProfile('default', 'debug').flags.AMCL_VULKAN_WSI_TRACE, 'OFF');
assert.equal(diagnosticProfile('default', 'release', 'vulkan-trace').mask, 513);
assert.equal(diagnosticProfile('default', 'debug', 'vulkan-trace').mask, 515);
assert.equal(diagnosticProfile('default', 'release', 'vulkan-trace').flags.AMCL_VULKAN_WSI_TRACE, 'ON');
assert.equal(diagnosticProfile('default', 'release', 'tests').flags.MC_OHOS_BUILD_TESTS, 'ON');
assert.equal(diagnosticProfile('default', 'debug', 'mg-exhaustive').flags.AMCL_MG_FRAME_STATS, 'ON');
assert.equal(diagnosticProfile('default', 'debug', 'mg-exhaustive').flags.AMCL_MG_FRAME_STATS_GL_SCOPES, 'ON');
for (const product of ['sideload', 'store', 'desktop']) {
  assert.equal(diagnosticProfile(product).mode, 'release');
  for (const mode of ['debug', 'release']) {
    assert.equal(diagnosticProfile(product, mode).mask, 0);
    for (const requested of Object.keys(DIAGNOSTIC_FLAGS)) {
      assert.throws(() => diagnosticProfile(product, mode, requested), /default-only/);
    }
  }
}
assert.throws(() => diagnosticProfile('default', 'debug', 'typo'), /Unknown diagnostic/);
assert.throws(() => diagnosticProfile('default', 'typo'), /Unknown build mode/);
console.log('diagnostic-profile: product/mode independence, opt-in closure and production rejection PASS');

// 只测试原HAP门的metadata/unique-member选择，不把下面的最小ZIP字节说成ELF、
// 真实SDK/HAP或运行ABI。真实CMake宏与逐字callback对象另由test-diagnostics-cmake编译。
function fixtureZip(entries) {
  const locals = [], centrals = []; let offset = 0;
  for (const [path, bytes] of entries) {
    const name = Buffer.from(path), data = Buffer.from(bytes), local = Buffer.alloc(30), central = Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22); local.writeUInt16LE(name.length, 26);
    const record = Buffer.concat([local, name, data]); locals.push(record);
    central.writeUInt32LE(0x02014b50); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6);
    central.writeUInt32LE(data.length, 20); central.writeUInt32LE(data.length, 24); central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42); centrals.push(Buffer.concat([central, name])); offset += record.length;
  }
  const directory = Buffer.concat(centrals), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}
function fixtureHap(product, requested, { glfwTrace, entryTrace = false, duplicateGlfw = false, vmaTrace = false } = {}) {
  const build = diagnosticProfile(product, 'release', requested), developer = product === 'default';
  const marker = `AMCL_DIAGNOSTICS_V1:product=${product};mask=${build.mask};`;
  const trace = 'AMCL_LOOK_GLFW obs=';
  const jar = fixtureZip([['META-INF/MANIFEST.MF', `Manifest-Version: 1.0\n${developer ? 'Premain-Class: example.AmclAgentProbe\n' : ''}`],
    ...(developer ? [['example/AmclAgentProbe.class', 'unit member']] : [])]);
  const glfw = marker + (developer ? 'mg_multidraw_bench_run\0mg_multidraw_bench_progress\0glfwAMCLMobileGluesBenchmarkRunV1\0' : '')
    + (glfwTrace ?? (build.flags.AMCL_INPUT_TRACE === 'ON') ? trace : '');
  const entries = [
    ['resources/rawfile/product-profile.json', JSON.stringify({ name: product, developerDiagnostics: developer,
      build: { ...build, nativeGlValidation: false } })],
    ['module.json', JSON.stringify({ app: { buildMode: 'release', debug: false } })],
    ['libs/arm64-v8a/libentry.so', marker + (entryTrace ? trace : '')],
    ['libs/arm64-v8a/libglfw.so', glfw], ['libs/arm64-v8a/libamcl_vulkan_wsi.so', marker],
    ['libs/arm64-v8a/liblwjgl_vma.so', vmaTrace ? '[AMCL_VULKAN_VMA] create_buffer' : 'quiet VMA fixture'],
    ['resources/rawfile/amcl-launcher.jar', jar],
    ['resources/base/profile/main_pages.json', '[]'], ['ets/modules.abc', 'unit bytes'],
  ];
  if (duplicateGlfw) entries.push(['libs/arm64-v8a/libglfw.so', glfw]);
  return fixtureZip(entries);
}
const missing = ['GLFW producer AMCL_INPUT_TRACE inclusion mismatch: expected present=true'];
const retained = ['GLFW producer AMCL_INPUT_TRACE inclusion mismatch: expected present=false'];
assert.deepEqual(evaluateDiagnosticHap(fixtureHap('default', 'input-trace'), 'default', 'release', 'input-trace'), []);
assert.deepEqual(evaluateDiagnosticHap(fixtureHap('default', 'none'), 'default', 'release'), []);
assert.deepEqual(evaluateDiagnosticHap(fixtureHap('store', 'none'), 'store', 'release'), []);
// 其它宿主mask正确也不能掩盖旧VMA；所有产品消费同一静默native契约。
for (const product of ['default', 'sideload', 'desktop', 'store']) {
  assert.match(evaluateDiagnosticHap(fixtureHap(product, 'none', { vmaTrace: true }), product, 'release').join('\n'),
    /VMA: synchronous allocation trace/);
}
// mask/metadata均正确，仅实际GLFW成员的正文错误；其它DSO有同文字不能代证它。
assert.deepEqual(evaluateDiagnosticHap(fixtureHap('default', 'input-trace', { glfwTrace: false }), 'default', 'release', 'input-trace'), missing);
assert.deepEqual(evaluateDiagnosticHap(fixtureHap('default', 'none', { glfwTrace: true }), 'default', 'release'), retained);
assert.deepEqual(evaluateDiagnosticHap(fixtureHap('store', 'none', { glfwTrace: true }), 'store', 'release'), retained);
assert.deepEqual(evaluateDiagnosticHap(fixtureHap('default', 'input-trace', { glfwTrace: false, entryTrace: true }), 'default', 'release', 'input-trace'), missing);
assert.throws(() => evaluateDiagnosticHap(fixtureHap('default', 'input-trace', { duplicateGlfw: true }), 'default', 'release', 'input-trace'), /exactly once/);
console.log('diagnostic artifact member: ON/OFF/store, missing/retained/wrong-image/duplicate negatives PASS');

// 独立测试真实ELF元数据判据，保留上面的plain ZIP/metadata夹具及其原有范围。
// 下面是自足的小型ELF结构夹具：有相互对应的program header、dynamic、dynsym、
// dynstr、可执行节与versym。它没有GNU hash/完整运行链接契约，也不执行机器码，
// 不能称为真实GLFW、真实SDK/HAP、dlsym可调用正例或getter返回值/provider资格。
// 合成ELF只负责可复现地改变一个字段，防止“有同名字串就当作动态导出”的假绿。
const GETTER_NAME = 'amclDiagnosticBuildIdentity';
const CREATOR_NAME = 'glfwCreateWindow';
const ELF_FIXTURE = Object.freeze({
  base: 0x10000, dynamic: 0x100, text: 0x180, dynstr: 0x1a0,
  dynsym: 0x280, versym: 0x2f0, shstr: 0x300, stringTrap: 0x380,
  sections: 0x400, sectionCount: 7, symbolSize: 24,
});
const fixtureSection = index => ELF_FIXTURE.sections + index * 64;
const fixtureSymbol = index => ELF_FIXTURE.dynsym + index * ELF_FIXTURE.symbolSize;
const fixtureDynamicTag = index => ELF_FIXTURE.dynamic + index * 16;
function fixtureGetterElf({ versionIndex = 1, symbolName = GETTER_NAME, duplicate = false, versions = true } = {}) {
  const p = ELF_FIXTURE;
  const bytes = Buffer.alloc(p.sections + p.sectionCount * 64);
  const u64 = (offset, value) => bytes.writeBigUInt64LE(BigInt(value), offset);
  Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]).copy(bytes);
  bytes.writeUInt16LE(3, 16); // ET_DYN
  bytes.writeUInt16LE(183, 18); // EM_AARCH64
  bytes.writeUInt32LE(1, 20);
  u64(32, 64); u64(40, p.sections);
  bytes.writeUInt16LE(64, 52); bytes.writeUInt16LE(56, 54); bytes.writeUInt16LE(2, 56);
  bytes.writeUInt16LE(64, 58); bytes.writeUInt16LE(p.sectionCount, 60); bytes.writeUInt16LE(6, 62);

  // PT_LOAD覆盖全部文件与.text代码地址；PT_DYNAMIC使用同一个虚拟地址映射。
  bytes.writeUInt32LE(1, 64); bytes.writeUInt32LE(5, 68); // PF_R | PF_X
  u64(72, 0); u64(80, p.base); u64(88, p.base);
  u64(96, bytes.length); u64(104, bytes.length); u64(112, 0x1000);
  bytes.writeUInt32LE(2, 120); bytes.writeUInt32LE(4, 124);
  u64(128, p.dynamic); u64(136, p.base + p.dynamic); u64(144, p.base + p.dynamic);

  const dynstr = Buffer.from(`\0libglfw.so\0${GETTER_NAME}\0${CREATOR_NAME}\0_Z27${GETTER_NAME}v\0unrelatedFunction\0`);
  dynstr.copy(bytes, p.dynstr);
  const stringIndex = name => dynstr.indexOf(Buffer.from(`${name}\0`));
  assert.ok(stringIndex(symbolName) > 0, 'ELF fixture symbol must have an explicit dynstr entry');
  const symbolCount = duplicate ? 4 : 3;
  const tags = [
    [5, p.base + p.dynstr], [10, dynstr.length], // DT_STRTAB / DT_STRSZ
    [6, p.base + p.dynsym], [11, 24], // DT_SYMTAB / DT_SYMENT
    [14, stringIndex('libglfw.so')], ...(versions ? [[0x6ffffff0, p.base + p.versym]] : []), [0, 0],
  ];
  u64(152, tags.length * 16); u64(160, tags.length * 16); u64(168, 8);
  tags.forEach(([tag, value], index) => { u64(fixtureDynamicTag(index), tag); u64(fixtureDynamicTag(index) + 8, value); });

  Buffer.from('1f2003d5', 'hex').copy(bytes, p.text); // 仅作.text非零内容，不执行。
  for (let index = 1; index < symbolCount; index += 1) {
    const record = fixtureSymbol(index);
    const creator = index === 2;
    bytes.writeUInt32LE(stringIndex(creator ? CREATOR_NAME : symbolName), record);
    bytes[record + 4] = 0x12; // STB_GLOBAL / STT_FUNC
    bytes[record + 5] = 0; // STV_DEFAULT
    bytes.writeUInt16LE(1, record + 6); // 已定义于.text
    u64(record + 8, p.base + p.text + (creator ? 4 : 0)); u64(record + 16, 4);
    bytes.writeUInt16LE(versionIndex, p.versym + index * 2);
  }

  const shstr = Buffer.from('\0.text\0.dynstr\0.dynsym\0.gnu.version\0.dynamic\0.shstrtab\0');
  shstr.copy(bytes, p.shstr);
  function section(index, name, type, flags, offset, size, link, entrySize, alignment) {
    const header = fixtureSection(index);
    bytes.writeUInt32LE(shstr.indexOf(Buffer.from(`${name}\0`)), header);
    bytes.writeUInt32LE(type, header + 4); u64(header + 8, flags);
    u64(header + 16, flags & 2 ? p.base + offset : 0);
    u64(header + 24, offset); u64(header + 32, size);
    bytes.writeUInt32LE(link, header + 40); u64(header + 48, alignment); u64(header + 56, entrySize);
  }
  section(1, '.text', 1, 6, p.text, 16, 0, 0, 4);
  section(2, '.dynstr', 3, 2, p.dynstr, dynstr.length, 0, 0, 1);
  section(3, '.dynsym', 11, 2, p.dynsym, symbolCount * 24, 2, 24, 8);
  bytes.writeUInt32LE(1, fixtureSection(3) + 44); // sh_info: null符号之后均为global。
  if (versions) section(4, '.gnu.version', 0x6fffffff, 2, p.versym, symbolCount * 2, 3, 2, 2);
  section(5, '.dynamic', 6, 2, p.dynamic, tags.length * 16, 2, 16, 8);
  section(6, '.shstrtab', 3, 0, p.shstr, shstr.length, 0, 0, 1);
  // 故意在dynstr之外留同名NUL文本，供“跨表扫字符串”负例使用。
  Buffer.from(`${GETTER_NAME}\0`).copy(bytes, p.stringTrap);
  return bytes;
}
function changedGetterElf(change) {
  const bytes = fixtureGetterElf();
  change(bytes);
  return bytes;
}
let getterPositiveControls = 0, getterNegativeControls = 0, getterOldHapControls = 0;
function assertGetterEvidenceBound(result, label) {
  // 检查实际资格边界而不逐字复刻整条message；尤其不能遗漏未核hash/未跑runtime。
  for (const scope of [/dynamic-export/, /VERSYM/, /default bit/, /no hash-table validation/,
    /no .*runtime lookup\/return\/provider qualification/]) {
    assert.match(result.errorBound, scope, `${label}: artifact qualification scope must remain explicit`);
  }
}
// index0=VER_NDX_LOCAL，不能误称可导出的“无版本”正例；index1=VER_NDX_GLOBAL。
// index2仅核VERSYM的default/hidden位，不造VERDEF，也不授予version definition资格。
for (const [label, options, versionIndex] of [
  ['global unversioned index1', { versionIndex: 1 }, 1],
  ['visible default version index2 (bit predicate only)', { versionIndex: 2 }, 2],
  ['no VERSYM table', { versions: false }, 1],
]) {
  const result = evaluateDiagnosticGetter(fixtureGetterElf(options));
  assert.deepEqual(result.issues, [], `${label} must pass metadata gate`);
  assertGetterEvidenceBound(result, label);
  assert.equal(result.symbol?.name, GETTER_NAME);
  assert.equal(result.symbol?.versionIndex, versionIndex);
  assert.equal(result.symbol?.versionHidden, false);
  assert.ok(result.symbol?.value, 'positive control must report its nonzero code address');
  // getter存在不能补creator，creator存在也不能补getter；这里逐字段核两个独立出口。
  assert.deepEqual(result.symbols?.[GETTER_NAME], result.symbol);
  const creator = result.symbols?.[CREATOR_NAME];
  assert.equal(creator?.name, CREATOR_NAME);
  assert.equal(creator?.bind, 1); assert.equal(creator?.type, 2); assert.equal(creator?.visibility, 0);
  assert.equal(creator?.shndx, 1); assert.equal(creator?.value, `0x${(ELF_FIXTURE.base + ELF_FIXTURE.text + 4).toString(16)}`);
  assert.equal(creator?.nonzero, true); assert.equal(creator?.executable, true);
  assert.equal(creator?.versionIndex, versionIndex); assert.equal(creator?.versionHidden, false);
  getterPositiveControls += 1;
}
const getterNegatives = [
  ['plain marker/getter text', Buffer.from(`AMCL_DIAGNOSTICS_V1:product=default;mask=7;\0${GETTER_NAME}\0`)],
  ['getter text exists but dynsym name missing', fixtureGetterElf({ symbolName: 'unrelatedFunction' })],
  ['only mangled dynsym name', fixtureGetterElf({ symbolName: `_Z27${GETTER_NAME}v` })],
  ['LOCAL', changedGetterElf(b => { b[fixtureSymbol(1) + 4] = 0x02; })],
  ['UND', changedGetterElf(b => { b.writeUInt16LE(0, fixtureSymbol(1) + 6); })],
  ['HIDDEN', changedGetterElf(b => { b[fixtureSymbol(1) + 5] = 2; })],
  ['INTERNAL', changedGetterElf(b => { b[fixtureSymbol(1) + 5] = 1; })],
  ['PROTECTED is not the required DEFAULT ABI', changedGetterElf(b => { b[fixtureSymbol(1) + 5] = 3; })],
  ['OBJECT', changedGetterElf(b => { b[fixtureSymbol(1) + 4] = 0x11; })],
  ['zero code value', changedGetterElf(b => { b.writeBigUInt64LE(0n, fixtureSymbol(1) + 8); })],
  ['non-executable section', changedGetterElf(b => { b.writeBigUInt64LE(2n, fixtureSection(1) + 8); })],
  ['non-executable LOAD', changedGetterElf(b => { b.writeUInt32LE(4, 68); })],
  ['code outside executable mapping', changedGetterElf(b => { b.writeBigUInt64LE(0x900000n, fixtureSymbol(1) + 8); })],
  ['invalid definition index', changedGetterElf(b => { b.writeUInt16LE(9, fixtureSymbol(1) + 6); })],
  ['truncated section table', fixtureGetterElf().subarray(0, fixtureSection(6) + 8)],
  ['dynstr index escapes into same-name text elsewhere', changedGetterElf(b => { b.writeUInt32LE(ELF_FIXTURE.stringTrap - ELF_FIXTURE.dynstr, fixtureSymbol(1)); })],
  ['getter lacks in-table NUL', changedGetterElf(b => {
    const start = b.readUInt32LE(fixtureSymbol(1));
    b.writeBigUInt64LE(BigInt(start + GETTER_NAME.length), fixtureSection(2) + 32);
    b.writeBigUInt64LE(BigInt(start + GETTER_NAME.length), fixtureDynamicTag(1) + 8);
  })],
  ['version hidden bit', fixtureGetterElf({ versionIndex: 0x8001 })],
  ['VER_NDX_LOCAL index0', fixtureGetterElf({ versionIndex: 0 })],
  ['duplicate getter definitions', fixtureGetterElf({ duplicate: true })],
  ['getter valid but creator missing', changedGetterElf(b => { b.writeUInt32LE(0, fixtureSymbol(2)); })],
  ['getter valid but creator LOCAL', changedGetterElf(b => { b[fixtureSymbol(2) + 4] = 0x02; })],
  ['getter valid but creator OBJECT', changedGetterElf(b => { b[fixtureSymbol(2) + 4] = 0x11; })],
  ['getter valid but creator UND', changedGetterElf(b => { b.writeUInt16LE(0, fixtureSymbol(2) + 6); })],
  ['getter valid but creator HIDDEN', changedGetterElf(b => { b[fixtureSymbol(2) + 5] = 2; })],
  ['getter valid but creator version index0', changedGetterElf(b => { b.writeUInt16LE(0, ELF_FIXTURE.versym + 4); })],
  ['wrong ELF class', changedGetterElf(b => { b[4] = 1; })],
  ['wrong ELF endian', changedGetterElf(b => { b[5] = 2; })],
  ['not ET_DYN', changedGetterElf(b => { b.writeUInt16LE(2, 16); })],
  ['wrong machine', changedGetterElf(b => { b.writeUInt16LE(62, 18); })],
  ['wrong SONAME', changedGetterElf(b => { b[ELF_FIXTURE.dynstr + 1] = 0x78; })],
  ['invalid dynsym string table link', changedGetterElf(b => { b.writeUInt32LE(1, fixtureSection(3) + 40); })],
  ['invalid dynsym item size', changedGetterElf(b => { b.writeBigUInt64LE(16n, fixtureSection(3) + 56); })],
  ['dynamic SYMTAB does not address selected dynsym', changedGetterElf(b => { b.writeBigUInt64LE(BigInt(ELF_FIXTURE.base + ELF_FIXTURE.text), fixtureDynamicTag(2) + 8); })],
  ['dynamic STRTAB does not address selected dynstr', changedGetterElf(b => { b.writeBigUInt64LE(BigInt(ELF_FIXTURE.base + ELF_FIXTURE.stringTrap), fixtureDynamicTag(0) + 8); })],
  ['dynamic SYMENT differs from ELF64 symbol size', changedGetterElf(b => { b.writeBigUInt64LE(16n, fixtureDynamicTag(3) + 8); })],
];
for (const [label, bytes] of getterNegatives) {
  const result = evaluateDiagnosticGetter(bytes);
  assert.ok(result.issues.length > 0, `${label}: ELF getter must fail closed`);
  assertGetterEvidenceBound(result, label);
  getterNegativeControls += 1;
}

// 明确指定旧HAP时才读本机原资产；默认CI不依赖维护者D盘、archive或任何设备。
// 唯一ZIP member和SHA先绑定已知旧GLFW，随后确认新导出门拒绝它，不能用另外的
// 同名文件/源码字串/其它DSO替代该反例，也不把拒绝扩展为已安装映像的执行结论。
const oldHapFlag = process.argv.indexOf('--old-glfw-hap');
if (oldHapFlag >= 0) {
  assert.equal(process.argv.filter(arg => arg === '--old-glfw-hap').length, 1, '--old-glfw-hap must be supplied once');
  const hapPath = process.argv[oldHapFlag + 1];
  assert.ok(hapPath && !hapPath.startsWith('--'), '--old-glfw-hap requires an explicit HAP path');
  const glfw = readUniqueZipEntry(readFileSync(resolve(hapPath)), 'libs/arm64-v8a/libglfw.so');
  const glfwSha256 = createHash('sha256').update(glfw).digest('hex');
  assert.equal(glfwSha256, 'da390ff7a39534fc6b93119d3dec1d1dc8388d1c3b5d55fe4533d6410a0b9206', 'old GLFW artifact identity must match the explicitly selected HAP');
  const result = evaluateDiagnosticGetter(glfw);
  assert.ok(result.issues.length > 0, 'known old GLFW with a local getter must be rejected');
  assertGetterEvidenceBound(result, 'known old HAP');
  getterOldHapControls += 1;
  console.log(`diagnostic getter old-HAP negative: sha256=${glfwSha256} PASS`);
}
console.log(`diagnostic getter ELF metadata: positive=${getterPositiveControls} negative=${getterNegativeControls} oldHap=${getterOldHapControls} PASS`);

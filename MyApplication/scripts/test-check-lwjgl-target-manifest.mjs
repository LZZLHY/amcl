#!/usr/bin/env node
// Directed, offline fixtures for check-lwjgl-target-manifest.mjs. Every state
// and every fail-closed edge is exercised without contacting Mojang.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  analyzeLwjglTargetManifestCoverage,
  hasBootstrapLibraryName,
  isLibraryAllowed,
  loadDefaultCoverageInputs,
  LWJGL_COVERAGE_TARGETS,
  metadataPayload,
  metadataSha1,
  validateFallbackEvidence,
  verifyHapArtifacts,
  verifyHapProviderNativeSurfaces,
  verifyReadelfDefinedExports,
  verifyTargetClient,
} from './check-lwjgl-target-manifest.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const NEGATIVE_PATH = join(
  SCRIPT_DIR,
  'fixtures',
  'lwjgl-target-manifests',
  'unclassified-module.negative.json',
);
const FALLBACK_PATH = join(
  SCRIPT_DIR,
  'fixtures',
  'lwjgl-target-manifests',
  'lwjgl-jemalloc-intentional-fallback.json',
);
// 旧负向夹具继续针对 pre-1（含 spng）；正式 26.3 有单独的基线与身份测试。
const base = loadDefaultCoverageInputs(undefined, '26.3-pre-1');

function clone(value) {
  return structuredClone(value);
}

function analyze(changes = {}) {
  return analyzeLwjglTargetManifestCoverage({
    ...base,
    ...changes,
  });
}

function expectFailure(label, result, pattern) {
  const output = result.problems.join('\n');
  assert.equal(result.ok, false, `${label}: expected failure, got PASS`);
  assert.match(output, pattern, `${label}: wrong diagnostic\n${output}`);
  console.log(`[test-lwjgl-target-manifest] PASS negative: ${label}`);
}

function expectUnsupportedRule(label, rule, pattern) {
  const problems = [];
  const allowed = isLibraryAllowed({ rules: [rule] }, base.descriptor.ruleEnvironment,
    `synthetic ${label}`, problems);
  assert.equal(allowed, false, `${label}: unsupported rule must not select the library`);
  assert.match(problems.join('\n'), pattern, `${label}: wrong diagnostic`);
  console.log(`[test-lwjgl-target-manifest] PASS rules fail-closed: ${label}`);
}

function changedMetadata(mutator, descriptorMutator = () => {}) {
  const metadata = JSON.parse(metadataPayload(base.metadataText));
  mutator(metadata);
  const metadataText = JSON.stringify(metadata);
  const descriptor = clone(base.descriptor);
  descriptor.metadataSha1 = metadataSha1(metadataText);
  descriptorMutator(descriptor);
  // Synthetic metadata cases deliberately establish their own audited identity;
  // descriptor-only mutations below keep the real policy unchanged and therefore
  // exercise the independent-identity rejection path.
  const policy = clone(base.policy);
  const audited = policy.auditedTargets.find((target) => target.versionId === descriptor.versionId);
  audited.metadataSha1 = descriptor.metadataSha1;
  audited.clientSha1 = descriptor.clientSha1;
  audited.classSha256 = descriptor.clientBootstrap.classSha256;
  audited.eagerNativeModules = clone(descriptor.clientBootstrap.eagerNativeModules);
  return { metadataText, descriptor, policy };
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function makeAarch64Elf() {
  const bytes = Buffer.alloc(128);
  bytes[0] = 0x7f;
  bytes[1] = 0x45;
  bytes[2] = 0x4c;
  bytes[3] = 0x46;
  bytes[4] = 2;
  bytes[5] = 1;
  bytes.writeUInt16LE(3, 16);
  bytes.writeUInt16LE(183, 18);
  Buffer.from('fixture_export\0', 'utf8').copy(bytes, 64);
  return bytes;
}

function readelfFixture(symbolLines = [
  '1: 0000000000001000 16 FUNC GLOBAL DEFAULT 7 fixture_export',
]) {
  return {
    headerText: [
      'ELF Header:',
      '  Class:                             ELF64',
      "  Data:                              2's complement, little endian",
      '  Type:                              DYN (Shared object file)',
      '  Machine:                           AArch64',
    ].join('\n'),
    dynamicText: [
      'Dynamic section at offset 0x100 contains 2 entries:',
      '  0x0000000000000001 (NEEDED) Shared library: [libc.so]',
    ].join('\n'),
    symbolsText: [
      "Symbol table '.dynsym' contains 2 entries:",
      '   Num:    Value          Size Type    Bind   Vis       Ndx Name',
      ...symbolLines,
    ].join('\n'),
  };
}

function makeZip(entries) {
  const locals = [];
  const centrals = [];
  let localOffset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const data = Buffer.from(entry.data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    const localRecord = Buffer.concat([local, name, data]);
    locals.push(localRecord);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(localOffset, 42);
    centrals.push(Buffer.concat([central, name]));
    localOffset += localRecord.length;
  }
  const centralBytes = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBytes.length, 12);
  eocd.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...locals, centralBytes, eocd]);
}

const baseline = analyze();
assert.equal(baseline.ok, true, baseline.problems.join('\n'));
console.log('[test-lwjgl-target-manifest] PASS baseline: frozen 26.3-pre-1 fixture');

// 默认导出必须选择正式版，CLI 默认目标集同时保留 pre-1。两者的需求集合与
// bootstrap 身份必须独立；正式版删除 spng 不意味着可删除旧消费者仍需的适配库。
assert.deepEqual(LWJGL_COVERAGE_TARGETS, ['26.3', '26.3-pre-1', '26.4-snapshot-1']);
const releaseInputs = loadDefaultCoverageInputs();
const release = analyzeLwjglTargetManifestCoverage(releaseInputs);
assert.equal(release.ok, true, release.problems.join('\n'));
assert.equal(release.versionId, '26.3');
assert.equal(release.effectiveEntries, 21);
assert.equal(release.javaModules.includes('lwjgl-spng'), false);
assert.notEqual(releaseInputs.descriptor.clientBootstrap.classSha256, base.descriptor.clientBootstrap.classSha256);
expectFailure('正式版不得复用 pre-1 元数据',
  analyzeLwjglTargetManifestCoverage({ ...releaseInputs, metadataText: base.metadataText }), /target metadata SHA-1 mismatch/);
assert.throws(() => loadDefaultCoverageInputs(undefined, '../not-a-target'), /unaudited LWJGL target/);
console.log('[test-lwjgl-target-manifest] PASS baseline: 独立冻结正式 26.3，保留 pre-1');

// 26.4 首个快照虽沿用同一 bootstrap 和模块表，也必须有自己的官方清单/客户端身份。
const snapshot264Inputs = loadDefaultCoverageInputs(undefined, '26.4-snapshot-1');
const snapshot264 = analyzeLwjglTargetManifestCoverage(snapshot264Inputs);
assert.equal(snapshot264.ok, true, snapshot264.problems.join('\n'));
assert.deepEqual(snapshot264.javaModules, release.javaModules);
assert.equal(snapshot264Inputs.descriptor.clientBootstrap.classSha256, releaseInputs.descriptor.clientBootstrap.classSha256);
assert.notEqual(snapshot264Inputs.descriptor.clientSha1, releaseInputs.descriptor.clientSha1);
expectFailure('26.4 不得借用 26.3 清单',
  analyzeLwjglTargetManifestCoverage({ ...snapshot264Inputs, metadataText: releaseInputs.metadataText }), /target metadata SHA-1 mismatch/);
console.log('[test-lwjgl-target-manifest] PASS baseline: 独立冻结 26.4 Snapshot 1');

// 属性路由已迁至 JVM 创建前的纯数据表。检查器必须拒绝注释、晚置属性与错误值，
// 不能因“文件里还能找到 libSDL3.so 字符串”把退回旧的抢先初始化路径判成通过。
const bootstrapTable = `inline std::vector<BootstrapProperty> RuntimeBootstrapProperties() {
    std::vector<BootstrapProperty> result{
        {"org.lwjgl.sdl.libname", "libSDL3.so"}
    };
    return result;
}`;
assert.equal(hasBootstrapLibraryName(bootstrapTable, 'org.lwjgl.sdl.libname', 'libSDL3.so'), true);
assert.equal(hasBootstrapLibraryName(bootstrapTable, 'org.lwjgl.sdl.libname', 'libWrong.so'), false);
assert.equal(hasBootstrapLibraryName('/*' + bootstrapTable + '*/', 'org.lwjgl.sdl.libname', 'libSDL3.so'), false);
assert.equal(hasBootstrapLibraryName(bootstrapTable.replace('RuntimeBootstrapProperties', 'unusedFunction'),
  'org.lwjgl.sdl.libname', 'libSDL3.so'), false);
assert.equal(hasBootstrapLibraryName('setSystemProperty(env, "org.lwjgl.sdl.libname", "libSDL3.so");',
  'org.lwjgl.sdl.libname', 'libSDL3.so'), false);

// 客户端附加校验的可失败测试：完整 JAR hash 与 bootstrap class hash 各自独立，
// 同名条目或只把 descriptor 改成“看起来匹配”的值不能替代实际字节。
const clientClass = Buffer.from('fixture-bootstrap-class');
const clientZip = makeZip([{ name: 'fixture/Bootstrap.class', data: clientClass }]);
const clientDescriptor = {
  versionId: 'fixture', clientSha1: createHash('sha1').update(clientZip).digest('hex'),
  clientBootstrap: { class: 'fixture/Bootstrap.class', classSha256: sha256(clientClass) },
};
const validClient = [];
verifyTargetClient(clientZip, clientDescriptor, validClient);
assert.deepEqual(validClient, []);
const wrongClient = [];
verifyTargetClient(clientZip, { ...clientDescriptor, clientSha1: '0'.repeat(40) }, wrongClient);
assert.match(wrongClient.join('\n'), /actual client SHA-1/);
const wrongBootstrap = [];
verifyTargetClient(clientZip, { ...clientDescriptor,
  clientBootstrap: { ...clientDescriptor.clientBootstrap, classSha256: '0'.repeat(64) } }, wrongBootstrap);
assert.match(wrongBootstrap.join('\n'), /actual bootstrap class SHA-256/);
const absentBootstrap = [];
verifyTargetClient(makeZip([]), clientDescriptor, absentBootstrap);
assert.match(absentBootstrap.join('\n'), /cannot read actual bootstrap class/);

const negative = JSON.parse(readFileSync(NEGATIVE_PATH, 'utf8'));
assert.equal(negative.schema, 1);
const unknown = changedMetadata(
  (metadata) => metadata.libraries.push(negative.library),
  (descriptor) => {
    descriptor.expectedEffectiveEntryCount += 1;
    descriptor.expectedJavaModules.push('lwjgl-future');
    descriptor.expectedJavaModules.sort();
  },
);
expectFailure(
  'new effective module is unclassified',
  analyze(unknown),
  new RegExp(negative.expectedError),
);

const windowsOnly = clone(negative.library);
windowsOnly.name = 'org.lwjgl:lwjgl-windows-only:9.9.9';
windowsOnly.rules = [{ action: 'allow', os: { name: 'windows' } }];
const filtered = changedMetadata((metadata) => metadata.libraries.push(windowsOnly));
const filteredResult = analyze(filtered);
assert.equal(filteredResult.ok, true, filteredResult.problems.join('\n'));
console.log('[test-lwjgl-target-manifest] PASS rules: Windows-only artifact is excluded on OHOS/Linux');

const matchingDisallowProblems = [];
const matchingDisallowAllowed = isLibraryAllowed({
  rules: [
    { action: 'allow', os: { name: 'linux' } },
    { action: 'disallow', os: { name: 'linux' } },
    { action: 'allow', os: { name: 'linux' } },
  ],
}, base.descriptor.ruleEnvironment, 'synthetic matching disallow', matchingDisallowProblems);
assert.equal(matchingDisallowAllowed, false,
  'both shipping evaluators must preserve a matching disallow despite a later allow');
assert.deepEqual(matchingDisallowProblems, []);
console.log('[test-lwjgl-target-manifest] PASS rules: matching disallow is a shared veto');

const evaluatorDisagreementProblems = [];
const evaluatorDisagreementAllowed = isLibraryAllowed({
  rules: [
    { action: 'disallow', os: { name: 'windows' } },
  ],
}, base.descriptor.ruleEnvironment, 'synthetic nonmatching disallow', evaluatorDisagreementProblems);
assert.equal(evaluatorDisagreementAllowed, false,
  'a disagreement between shipping evaluators must fail closed');
assert.match(evaluatorDisagreementProblems.join('\n'),
  /shipping rule evaluators disagree \(VersionParser=true, McDownloader=false\)/);
console.log('[test-lwjgl-target-manifest] PASS rules fail-closed: shipping evaluators disagree');

expectUnsupportedRule('os.arch',
  { action: 'allow', os: { name: 'linux', arch: 'aarch64' } }, /rule\.os\.arch is unsupported/);
expectUnsupportedRule('os.version',
  { action: 'allow', os: { name: 'linux', version: '5\\.10' } }, /rule\.os\.version is unsupported/);
expectUnsupportedRule('features',
  { action: 'allow', features: { has_custom_resolution: true } }, /feature-dependent LWJGL rule is unsupported/);
expectUnsupportedRule('unknown rule key',
  { action: 'allow', futureCondition: true }, /unsupported rule keys futureCondition/);
expectUnsupportedRule('unknown os key',
  { action: 'allow', os: { name: 'linux', family: 'mobile' } }, /unsupported rule\.os keys family/);

const missingJar = clone(base.modernManifest);
missingJar.jars = missingJar.jars.filter((jar) => jar.name !== 'lwjgl-spng.jar');
expectFailure(
  'provided Java artifact is absent',
  analyze({ modernManifest: missingJar }),
  /lwjgl-spng\.jar must appear exactly once/,
);

const missingNative = clone(base.modernManifest);
missingNative.natives = missingNative.natives.filter((native) => native.name !== 'liblwjgl_spng.so');
expectFailure(
  'provided eager native artifact is absent',
  analyze({ modernManifest: missingNative }),
  /liblwjgl_spng\.so must appear exactly once/,
);

const forgedJarLock = clone(base.modernManifest);
forgedJarLock.jars.find((jar) => jar.name === 'lwjgl-spng.jar').size = 1;
expectFailure(
  'modern JAR manifest cannot replace actual-byte verification',
  analyze({ modernManifest: forgedJarLock }),
  /prebuilt lwjgl-spng\.jar size mismatch/,
);

const unlockedBundle = clone(base.policy);
delete unlockedBundle.modules.find((entry) => entry.name === 'lwjgl-freetype').native.size;
expectFailure(
  'bundle-file provider requires a locked size and SHA-256',
  analyze({ policy: unlockedBundle }),
  /bundle native .* must lock a positive size and lowercase SHA-256/,
);

const missingLibraryRoute = clone(base.policy);
delete missingLibraryRoute.modules.find((entry) => entry.name === 'lwjgl-sdl').native.libraryName;
expectFailure(
  'bundle-file provider requires its active library-name route',
  analyze({ policy: missingLibraryRoute }),
  /bundle-file provider requires a libraryName route/,
);

const missingRequiredSymbols = clone(base.policy);
delete missingRequiredSymbols.modules.find((entry) => entry.name === 'lwjgl-freetype').native.requiredSymbols;
expectFailure(
  'bundle/CMake providers require a non-empty exported-symbol contract',
  analyze({ policy: missingRequiredSymbols }),
  /native provider requiredSymbols must be a non-empty string array/,
);

const absentSourceSymbol = clone(base.policy);
absentSourceSymbol.modules.find((entry) => entry.name === 'lwjgl-freetype').native.requiredSymbols =
  ['AMCL_fixture_symbol_that_does_not_exist'];
expectFailure(
  'bundle source ELF must define every required dynamic export',
  analyze({ policy: absentSourceSymbol }),
  /bundle native .* required symbol AMCL_fixture_symbol_that_does_not_exist is not a defined GLOBAL\/WEAK dynamic export/,
);

const forgedCmakeArtifact = clone(base.policy);
forgedCmakeArtifact.modules.find((entry) => entry.name === 'lwjgl-openal').native.artifact = 'not-openal.so';
expectFailure(
  'cmake-output provider cannot name an arbitrary artifact',
  analyze({ policy: forgedCmakeArtifact }),
  /cmake-output artifact must be libopenal\.so/,
);

const emptyCmakeContracts = clone(base.policy);
emptyCmakeContracts.modules.find((entry) => entry.name === 'lwjgl-openal').native.contracts = [];
expectFailure(
  'cmake-output provider requires active build contracts',
  analyze({ policy: emptyCmakeContracts }),
  /cmake-output provider has no build contracts/,
);

const fallbackJarPresent = clone(base.modernManifest);
fallbackJarPresent.jars.push({ name: 'lwjgl-jemalloc.jar', size: 1, sha256: '0'.repeat(64) });
expectFailure(
  'intentional fallback is invalidated by adding the allocator JAR',
  analyze({ modernManifest: fallbackJarPresent }),
  /lwjgl-jemalloc\.jar must stay absent/,
);

const missingEvidence = clone(base.policy);
missingEvidence.modules.find((entry) => entry.name === 'lwjgl-jemalloc').evidence =
  'scripts/fixtures/lwjgl-target-manifests/does-not-exist.json';
expectFailure(
  'intentional fallback has no frozen evidence',
  analyze({ policy: missingEvidence }),
  /fallback evidence fixture is missing/,
);

const fallbackEvidence = JSON.parse(readFileSync(FALLBACK_PATH, 'utf8'));
const validFallbackProblems = [];
assert.equal(validateFallbackEvidence(fallbackEvidence, 'lwjgl-jemalloc', validFallbackProblems), true);
assert.deepEqual(validFallbackProblems, []);
for (const [field, pattern] of [
  ['omittedJar', /omittedJar must be lwjgl-jemalloc\.jar/],
  ['coreJar', /coreJar must be a plain JAR name/],
  ['classEntry', /classEntry must name a class file/],
  ['classSha256', /classSha256 is malformed/],
  ['requiredClassConstants', /requiredClassConstants must be a non-empty string array/],
  ['absentClassEntry', /absentClassEntry must name a distinct class file/],
]) {
  const malformed = clone(fallbackEvidence);
  delete malformed[field];
  const problems = [];
  assert.equal(validateFallbackEvidence(malformed, 'lwjgl-jemalloc', problems), false,
    `missing fallback field ${field} must fail closed`);
  assert.match(problems.join('\n'), pattern);
}
console.log('[test-lwjgl-target-manifest] PASS fallback: every evidence field is mandatory');

const eagerFallback = clone(base.policy);
const spngFallback = eagerFallback.modules.find((entry) => entry.name === 'lwjgl-spng');
spngFallback.state = 'intentional-fallback';
spngFallback.reason = 'synthetic negative';
spngFallback.evidence = 'scripts/fixtures/lwjgl-target-manifests/lwjgl-jemalloc-intentional-fallback.json';
delete spngFallback.native;
expectFailure(
  'bootstrap-eager module cannot claim intentional fallback',
  analyze({ policy: eagerFallback }),
  /lwjgl-spng: eager bootstrap module cannot use intentional-fallback/,
);

const unsupported = clone(base.policy);
const unsupportedSpng = unsupported.modules.find((entry) => entry.name === 'lwjgl-spng');
unsupportedSpng.state = 'unsupported';
unsupportedSpng.reason = 'synthetic unsupported fixture';
delete unsupportedSpng.native;
expectFailure(
  'unsupported target module fails closed',
  analyze({ policy: unsupported }),
  /lwjgl-spng: unsupported for target 26\.3-pre-1: synthetic unsupported fixture/,
);

const unknownState = clone(base.policy);
unknownState.modules.find((entry) => entry.name === 'lwjgl-spng').state = 'maybe';
expectFailure(
  'unknown policy state fails closed',
  analyze({ policy: unknownState }),
  /lwjgl-spng: unknown coverage state maybe/,
);

const weakenedUnsupportedPolicy = clone(base.policy);
weakenedUnsupportedPolicy.unsupportedStatePolicy = 'pass-with-a-reason';
expectFailure(
  'unsupported cannot become passable without a precise prelaunch contract',
  analyze({ policy: weakenedUnsupportedPolicy }),
  /unsupportedStatePolicy must be build-blocking-until-precise-prelaunch-contract/,
);

const forgedBootstrapIdentity = clone(base.descriptor);
forgedBootstrapIdentity.clientBootstrap.classSha256 = '0'.repeat(64);
expectFailure(
  'descriptor cannot forge the audited bootstrap class hash',
  analyze({ descriptor: forgedBootstrapIdentity }),
  /descriptor bootstrap classSha256 does not match audited target/,
);

const missingEagerIdentity = clone(base.descriptor);
missingEagerIdentity.clientBootstrap.eagerNativeModules =
  missingEagerIdentity.clientBootstrap.eagerNativeModules.filter((module) => module !== 'lwjgl-spng');
expectFailure(
  'descriptor cannot silently delete an audited eager module',
  analyze({ descriptor: missingEagerIdentity }),
  /descriptor\/audited eagerNativeModules mismatch/,
);

const staleDescriptor = clone(base.descriptor);
staleDescriptor.metadataSha1 = '0'.repeat(40);
expectFailure(
  'frozen metadata identity drift',
  analyze({ descriptor: staleDescriptor }),
  /target metadata SHA-1 mismatch/,
);

const fakeJar = Buffer.from('fake-modern-jar', 'utf8');
const fakeElf = makeAarch64Elf();
// Model Hvigor's packaging strip: valid ELF/symbol surface, different bytes from
// the source-side manifest lock.
const fakeStrippedElf = Buffer.concat([fakeElf, Buffer.from('strip-delta', 'utf8')]);
const fakeModernManifest = {
  jars: [{ name: 'lwjgl-spng.jar', size: fakeJar.length, sha256: sha256(fakeJar) }],
  natives: [{ name: 'liblwjgl_spng.so', size: fakeElf.length, sha256: sha256(fakeElf) }],
};
const fakePolicy = {
  modules: [
    { name: 'lwjgl-spng', state: 'provided', native: { kind: 'modern-slot', artifact: 'liblwjgl_spng.so' } },
    {
      name: 'lwjgl-sdl', state: 'provided', native: {
        kind: 'bundle-file', artifact: 'entry/libs/arm64-v8a/libSDL3.so',
        size: fakeElf.length, sha256: sha256(fakeElf), requiredSymbols: ['fixture_export'],
      },
    },
    {
      name: 'lwjgl-openal', state: 'provided',
      native: { kind: 'cmake-output', artifact: 'libopenal.so', requiredSymbols: ['fixture_export'] },
    },
  ],
};
const fakeHapEntries = [
  { name: 'resources/rawfile/lwjgl/lwjgl-spng.jar', data: fakeJar },
  { name: 'libs/arm64-v8a/liblwjgl_spng.so', data: fakeStrippedElf },
  { name: 'libs/arm64-v8a/libSDL3.so', data: fakeElf },
  { name: 'libs/arm64-v8a/libopenal.so', data: fakeElf },
];
const fakeHapProblems = [];
verifyHapArtifacts(makeZip(fakeHapEntries), fakePolicy, fakeModernManifest, fakeHapProblems);
verifyHapProviderNativeSurfaces(
  makeZip(fakeHapEntries), fakePolicy, fakeHapProblems,
  { inspectReadelf: () => readelfFixture() },
);
assert.deepEqual(fakeHapProblems, []);
const missingHapProblems = [];
verifyHapArtifacts(makeZip(fakeHapEntries.slice(1)), fakePolicy, fakeModernManifest, missingHapProblems);
assert.match(missingHapProblems.join('\n'), /required HAP entry resources\/rawfile\/lwjgl\/lwjgl-spng\.jar/);
const tamperedHapEntries = clone(fakeHapEntries);
tamperedHapEntries[0].data = Buffer.from('fake-modern-JAR', 'utf8');
const tamperedHapProblems = [];
verifyHapArtifacts(makeZip(tamperedHapEntries), fakePolicy, fakeModernManifest, tamperedHapProblems);
assert.match(tamperedHapProblems.join('\n'), /HAP .*lwjgl-spng\.jar SHA-256 mismatch/);
const missingSymbolPolicy = clone(fakePolicy);
missingSymbolPolicy.modules.find((entry) => entry.name === 'lwjgl-openal').native.requiredSymbols =
  ['fixture_missing_export'];
const missingSymbolProblems = [];
verifyHapProviderNativeSurfaces(
  makeZip(fakeHapEntries), missingSymbolPolicy, missingSymbolProblems,
  { inspectReadelf: () => readelfFixture() },
);
assert.match(missingSymbolProblems.join('\n'),
  /libopenal\.so: required symbol fixture_missing_export is not a defined GLOBAL\/WEAK dynamic export/);

const undefinedExportProblems = [];
verifyReadelfDefinedExports(
  readelfFixture(['1: 0000000000000000 0 FUNC GLOBAL DEFAULT UND fixture_export']),
  ['fixture_export'], 'synthetic UND provider', undefinedExportProblems,
);
assert.match(undefinedExportProblems.join('\n'),
  /fixture_export is not a defined GLOBAL\/WEAK dynamic export/,
  'an undefined dynsym must not satisfy requiredSymbols');

const rodataOnlyProblems = [];
const rodataOnly = readelfFixture([]);
rodataOnly.rodataText = 'fixture_export\0';
verifyReadelfDefinedExports(
  rodataOnly, ['fixture_export'], 'synthetic rodata-only provider', rodataOnlyProblems,
);
assert.match(rodataOnlyProblems.join('\n'),
  /fixture_export is not a defined GLOBAL\/WEAK dynamic export/,
  'an unrelated NUL-terminated byte string must not satisfy requiredSymbols');

const shortElfEntries = clone(fakeHapEntries);
shortElfEntries.find((entry) => entry.name.endsWith('/libSDL3.so')).data =
  Buffer.from([0x7f, 0x45, 0x4c, 0x46]);
const shortElfProblems = [];
verifyHapArtifacts(makeZip(shortElfEntries), fakePolicy, fakeModernManifest, shortElfProblems);
assert.match(shortElfProblems.join('\n'), /HAP .*libSDL3\.so is not an ELF artifact/,
  'a short magic-only pseudo-ELF must fail closed');
const wrongArchElf = Buffer.from(fakeElf);
wrongArchElf.writeUInt16LE(62, 18);
const wrongArchPolicy = clone(fakePolicy);
const wrongArchBundle = wrongArchPolicy.modules.find((entry) => entry.name === 'lwjgl-sdl').native;
wrongArchBundle.sha256 = sha256(wrongArchElf);
const wrongArchEntries = clone(fakeHapEntries);
wrongArchEntries.find((entry) => entry.name.endsWith('/libSDL3.so')).data = wrongArchElf;
const wrongArchProblems = [];
verifyHapArtifacts(makeZip(wrongArchEntries), wrongArchPolicy, fakeModernManifest, wrongArchProblems);
assert.match(wrongArchProblems.join('\n'), /libSDL3\.so must be little-endian ELF64 ET_DYN for AArch64/);
console.log('[test-lwjgl-target-manifest] PASS HAP: real readelf semantics reject UND/rodata/short/wrong-arch providers');

console.log('[test-lwjgl-target-manifest] all directed fixtures passed');

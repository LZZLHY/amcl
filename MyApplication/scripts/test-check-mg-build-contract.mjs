#!/usr/bin/env node
// Regression fixtures for variant-binding false greens. These tests do not
// require DevEco, CMake, Git or a real ELF and therefore run on hosted CI.

import { mkdtempSync } from 'node:fs';
import {
  mkdirSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import {
  classifyMobileGluesCompileRows,
  ContractError,
  effectiveCompileFlagIssues,
  extractFinalLinkFlags,
  fileRecord,
  finalLinkFlagIssues,
  inspectNestedSubmodules,
  isExplicitUnsignedVerifierFailure,
  provenanceComparisonIssues,
  REQUIRED_TRANSLATOR_EVIDENCE,
  releaseInputPlaneIssues,
  resolveEvidencePaths,
  sanitizeRemoteIdentity,
  sdkApiLevel,
  toolchainLockIssues,
  translatorEvidenceIssues,
  validateVariantBinding,
} from './check-mg-build-contract.mjs';

let crcTable;
function crc32(buffer) {
  if (!crcTable) {
    crcTable = Array.from({ length: 256 }, (_, index) => {
      let value = index;
      for (let bit = 0; bit < 8; bit += 1) {
        value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
      }
      return value >>> 0;
    });
  }
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function storedZip(entryMap) {
  const locals = [];
  const centrals = [];
  let localOffset = 0;
  for (const [name, value] of Object.entries(entryMap)) {
    const nameBytes = Buffer.from(name);
    const data = Buffer.isBuffer(value) ? value : Buffer.from(value);
    const crc = crc32(data);
    const local = Buffer.alloc(30 + nameBytes.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    nameBytes.copy(local, 30);
    locals.push(local, data);

    const central = Buffer.alloc(46 + nameBytes.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x800, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(localOffset, 42);
    nameBytes.copy(central, 46);
    centrals.push(central);
    localOffset += local.length + data.length;
  }
  const centralBytes = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(centrals.length, 8);
  eocd.writeUInt16LE(centrals.length, 10);
  eocd.writeUInt32LE(centralBytes.length, 12);
  eocd.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...locals, centralBytes, eocd]);
}

function ensureParent(path) {
  mkdirSync(dirname(path), { recursive: true });
}

const fixtureRoot = resolve(mkdtempSync(join(tmpdir(), 'amcl-mg-contract-')));
const options = {
  root: fixtureRoot,
  product: 'default',
  target: 'default',
  mode: 'release',
  abi: 'arm64-v8a',
  hapKind: 'unsigned',
};
const paths = resolveEvidencePaths(options);
// The synthetic images carry the same evidence literals a real library must, so
// the fixture represents a compliant artifact. Building them by concatenating
// REQUIRED_TRANSLATOR_EVIDENCE rather than by pasting the strings means adding a
// pass to that list does not silently turn this fixture into a non-compliant one
// -- which would make every other case in this file fail for an unrelated reason.
const evidenceRodata = Buffer.from(
  REQUIRED_TRANSLATOR_EVIDENCE.map(entry => entry.literal).join('\0') + '\0',
  'utf8',
);
const unstripped = Buffer.concat([Buffer.from('fixture-unstripped-library'), evidenceRodata]);
const stripped = Buffer.concat([Buffer.from('fixture-stripped-library'), evidenceRodata]);

function moduleJson(overrides = {}) {
  return JSON.stringify({
    app: {
      buildMode: 'release',
      debug: false,
      compileSdkVersion: '6.1.1.115',
      targetAPIVersion: 60100023,
      minAPIVersion: 60000020,
      ...overrides,
    },
    module: { name: 'entry' },
  });
}

function writeFixture({
  buildType = 'Release',
  compileDirectory = paths.buildDir,
  embedded = stripped,
  module = moduleJson(),
  staleHap = false,
  effectiveTargetSdk = '6.1.0(23)',
  effectiveCompatibleSdk = '6.0.0(20)',
  templateTargetSdk = '6.1.0(23)',
  templateCompatibleSdk = '6.0.0(20)',
  routeCache = {},
  metadataDefinitions = [
    '-DMC_OHOS_BUILD_TESTS=OFF',
    '-DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON',
    '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON',
    '-DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON',
  ],
} = {}) {
  for (const path of [
    paths.compileDb,
    paths.cachePath,
    paths.ninjaPath,
    paths.metadataCommandPath,
    paths.cmakeSo,
    paths.stagedSo,
    paths.strippedSo,
    paths.hapPath,
    paths.profilePath,
    paths.profileTemplatePath,
    paths.toolchainLockPath,
  ]) ensureParent(path);
  writeFileSync(paths.compileDb, JSON.stringify([{
    directory: compileDirectory,
    command: 'C:/fake/clang++.exe --target=aarch64-linux-ohos -O2 -c source.cpp',
    file: join(fixtureRoot, 'source.cpp'),
    output: 'CMakeFiles/fixture.o',
  }]));
  writeFileSync(paths.cachePath, [
    `CMAKE_BUILD_TYPE:STRING=${buildType}`,
    'CMAKE_OHOS_ARCH_ABI:UNINITIALIZED=arm64-v8a',
    'OHOS_ARCH:UNINITIALIZED=arm64-v8a',
    `MC_OHOS_BUILD_TESTS:BOOL=${routeCache.MC_OHOS_BUILD_TESTS ?? 'OFF'}`,
    `AMCL_GLFW_TYPED_PHYSICAL_DEFAULT:BOOL=${
      routeCache.AMCL_GLFW_TYPED_PHYSICAL_DEFAULT ?? 'ON'}`,
    `AMCL_GLFW_RAW_RELATIVE_VERIFIED:BOOL=${
      routeCache.AMCL_GLFW_RAW_RELATIVE_VERIFIED ?? 'ON'}`,
    `AMCL_GLFW_API26_RAW_MOUSE_MOTION:BOOL=${
      routeCache.AMCL_GLFW_API26_RAW_MOUSE_MOTION ?? 'ON'}`,
    `AMCL_INPUT_COMPILED_FORMAL_DESKTOP:BOOL=${
      routeCache.AMCL_INPUT_COMPILED_FORMAL_DESKTOP ?? 'OFF'}`,
    `mc_ohos_native_BINARY_DIR:STATIC=${paths.buildDir}`,
    `CMAKE_HOME_DIRECTORY:INTERNAL=${join(fixtureRoot, 'entry/src/main/cpp')}`,
  ].join('\n'));
  writeFileSync(paths.ninjaPath, [
    `cmake_ninja_workdir = ${paths.buildDir.replaceAll('\\', '/')}/`,
    `build libglfw.so: phony ${paths.cmakeSo.replaceAll('\\', '/')}`,
  ].join('\n'));
  writeFileSync(paths.metadataCommandPath, [
    'C:/fake/cmake.exe',
    ...metadataDefinitions,
    `-B${paths.buildDir}`,
    '-DCMAKE_BUILD_TYPE=Release',
  ].join('\n'));
  writeFileSync(paths.cmakeSo, unstripped);
  writeFileSync(paths.stagedSo, unstripped);
  writeFileSync(paths.strippedSo, stripped);
  const profileFor = (signingConfigs, targetSdkVersion, compatibleSdkVersion) => ({
    app: {
      signingConfigs,
      products: [{
        name: 'default',
        signingConfig: 'default',
        targetSdkVersion,
        compatibleSdkVersion,
        runtimeOS: 'HarmonyOS',
        buildOption: {
          nativeCompiler: 'BiSheng',
          strictMode: { caseSensitiveCheck: true, useNormalizedOHMUrl: true },
        },
      }],
      buildModeSet: [{ name: 'debug' }, { name: 'release' }],
    },
    modules: [{
      name: 'entry',
      targets: [{ name: 'default', applyToProducts: ['default'] }],
    }],
  });
  writeFileSync(paths.profilePath, JSON.stringify(profileFor(
    [{ name: 'default', type: 'HarmonyOS', material: { signAlg: 'SHA256withECDSA' } }],
    effectiveTargetSdk,
    effectiveCompatibleSdk,
  )));
  writeFileSync(paths.profileTemplatePath, JSON.stringify(profileFor(
    [],
    templateTargetSdk,
    templateCompatibleSdk,
  )));
  writeFileSync(paths.toolchainLockPath, '{}');
  writeFileSync(paths.hapPath, storedZip({
    'module.json': module,
    'libs/arm64-v8a/libglfw.so': embedded,
  }));

  const now = Date.now();
  const setTime = (path, milliseconds) => utimesSync(path, milliseconds / 1000, milliseconds / 1000);
  for (const path of [
    paths.compileDb,
    paths.cachePath,
    paths.ninjaPath,
    paths.metadataCommandPath,
  ]) setTime(path, now - 8_000);
  setTime(paths.cmakeSo, now - 6_000);
  setTime(paths.stagedSo, now - 5_000);
  setTime(paths.strippedSo, now - 4_000);
  setTime(paths.hapPath, staleHap ? now - 8_000 : now - 2_000);
}

function pass(label, callback) {
  callback();
  console.log(`[test-check-mg-build-contract] PASS: ${label}`);
}

function reject(label, pattern, callback) {
  let error;
  try {
    callback();
  } catch (caught) {
    error = caught;
  }
  if (!(error instanceof ContractError) || !pattern.test(error.message)) {
    throw new Error(`${label}: expected ContractError matching ${pattern}, got ${error?.stack ?? error}`);
  }
  console.log(`[test-check-mg-build-contract] PASS: ${label}`);
}

try {
  pass('legacy and API26 SDK strings map to their exact packed HAP API values', () => {
    if (sdkApiLevel('6.1.0(23)') !== 60_100_023) {
      throw new Error('legacy 6.1.0(23) SDK spelling was not preserved');
    }
    if (sdkApiLevel('26.0.0') !== 260_000_026) {
      throw new Error('API26 26.0.0 SDK spelling did not map to 260000026');
    }
    for (const invalid of ['6.1.0', '25.0.0', '26.0.1', '26.0.0-preview', '26']) {
      if (sdkApiLevel(invalid) !== null) {
        throw new Error(`malformed/unsupported SDK spelling must fail closed: ${invalid}`);
      }
    }
  });

  writeFixture();
  pass('one coherent release product/mode/ABI fixture passes binding', () => {
    validateVariantBinding(options);
  });

  const api26Module = moduleJson({
    compileSdkVersion: '26.0.0.105',
    targetAPIVersion: 260_000_026,
    minAPIVersion: 260_000_026,
  });
  writeFixture({
    module: api26Module,
    effectiveTargetSdk: '26.0.0',
    effectiveCompatibleSdk: '26.0.0',
    templateTargetSdk: '26.0.0',
    templateCompatibleSdk: '26.0.0',
  });
  pass('known-good API26 profile/HAP fixture passes binding', () => {
    validateVariantBinding(options);
  });

  writeFixture({
    module: moduleJson({
      compileSdkVersion: '26.0.0.105',
      targetAPIVersion: 60_100_023,
      minAPIVersion: 260_000_026,
    }),
    effectiveTargetSdk: '26.0.0',
    effectiveCompatibleSdk: '26.0.0',
    templateTargetSdk: '26.0.0',
    templateCompatibleSdk: '26.0.0',
  });
  reject('known-bad API26 HAP numeric target cannot false-green', /targetSdkVersion=26\.0\.0/, () => {
    validateVariantBinding(options);
  });

  writeFixture({
    routeCache: { AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: 'OFF' },
  });
  reject('mobile Release cache must use the shipping typed input plane', /release input plane.*TYPED.*OFF/, () => {
    validateVariantBinding(options);
  });

  writeFixture({
    metadataDefinitions: [
      '-DMC_OHOS_BUILD_TESTS=OFF',
      '-DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON',
    ],
  });
  reject('Release configure metadata must explicitly enable the relative route', /metadata.*RAW_RELATIVE/, () => {
    validateVariantBinding(options);
  });

  const desktopMetadata = [
    '-DMC_OHOS_BUILD_TESTS=OFF',
    '-DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON',
    '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON',
    '-DAMCL_GLFW_API26_RAW_MOUSE_MOTION=ON',
    '-DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON',
  ].join('\n');
  const desktopCache = new Map([
    ['MC_OHOS_BUILD_TESTS', 'OFF'],
    ['AMCL_GLFW_TYPED_PHYSICAL_DEFAULT', 'ON'],
    ['AMCL_GLFW_RAW_RELATIVE_VERIFIED', 'ON'],
    ['AMCL_GLFW_API26_RAW_MOUSE_MOTION', 'ON'],
    ['AMCL_INPUT_COMPILED_FORMAL_DESKTOP', 'ON'],
  ]);
  pass('formal desktop Release route requires the API26 raw plane', () => {
    if (releaseInputPlaneIssues('desktop', desktopCache, desktopMetadata).length) {
      throw new Error('known-good formal desktop input plane was rejected');
    }
    const missingRaw = new Map(desktopCache);
    missingRaw.set('AMCL_GLFW_API26_RAW_MOUSE_MOTION', 'OFF');
    if (!releaseInputPlaneIssues('desktop', missingRaw, desktopMetadata)
      .some(issue => /API26_RAW_MOUSE_MOTION=OFF/.test(issue))) {
      throw new Error('formal desktop without API26 raw must fail closed');
    }
    const missingFormalIdentity = new Map(desktopCache);
    missingFormalIdentity.set('AMCL_INPUT_COMPILED_FORMAL_DESKTOP', 'OFF');
    if (!releaseInputPlaneIssues('desktop', missingFormalIdentity, desktopMetadata)
      .some(issue => /COMPILED_FORMAL_DESKTOP=OFF.*expected ON/.test(issue))) {
      throw new Error('formal desktop cache without its compiled identity must fail closed');
    }
    const desktopMetadataWithoutIdentity = desktopMetadata
      .replace('-DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON\n', '')
      .replace('\n-DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=ON', '');
    if (!releaseInputPlaneIssues('desktop', desktopCache, desktopMetadataWithoutIdentity)
      .some(issue => /metadata.*COMPILED_FORMAL_DESKTOP=ON/.test(issue))) {
      throw new Error('formal desktop configure metadata must declare its compiled identity');
    }
    const legacyCache = new Map(desktopCache);
    legacyCache.set('AMCL_GLFW_API26_RAW_MOUSE_MOTION', 'OFF');
    legacyCache.set('AMCL_INPUT_COMPILED_FORMAL_DESKTOP', 'OFF');
    const legacyMetadata = [
      '-DMC_OHOS_BUILD_TESTS=OFF',
      '-DAMCL_GLFW_TYPED_PHYSICAL_DEFAULT=ON',
      '-DAMCL_GLFW_RAW_RELATIVE_VERIFIED=ON',
      '-DAMCL_INPUT_COMPILED_FORMAL_DESKTOP=OFF',
    ].join('\n');
    if (!releaseInputPlaneIssues('desktopLegacy', legacyCache, legacyMetadata)
      .some(issue => /no release input-plane contract/.test(issue))) {
      throw new Error('retired desktopLegacy must not have a release route');
    }
  });

  writeFixture({ module: moduleJson({ buildMode: 'debug', debug: true }) });
  reject('Debug HAP with the same embedded library cannot false-green', /buildMode=debug|debug=true/, () => {
    validateVariantBinding(options);
  });

  writeFixture({ buildType: 'Debug' });
  reject('Release path containing a Debug CMake cache is rejected', /CMAKE_BUILD_TYPE=Debug/, () => {
    validateVariantBinding(options);
  });

  writeFixture({ compileDirectory: join(fixtureRoot, 'entry/.cxx/default/default/debug/arm64-v8a') });
  reject('compile database from another mode is rejected', /another build directory/, () => {
    validateVariantBinding(options);
  });

  writeFixture({ embedded: Buffer.from('different-library') });
  reject('HAP and stripped intermediate hash mismatch is rejected', /HAP libglfw hash/, () => {
    validateVariantBinding(options);
  });

  writeFixture({ staleHap: true });
  reject('HAP older than the selected stripped intermediate is rejected', /HAP predates/, () => {
    validateVariantBinding(options);
  });

  writeFixture();
  const outsideHap = join(fixtureRoot, 'entry/build/default/outputs/debug/debug.hap');
  reject('explicit HAP outside the selected target output is rejected', /must exactly match artifactKind/, () => {
    validateVariantBinding({ ...options, hapPath: outsideHap });
  });

  reject('HAP basename cannot contradict its explicit artifact kind', /must exactly match artifactKind=signed/, () => {
    validateVariantBinding({ ...options, hapKind: 'signed', hapPath: paths.hapPath });
  });

  let missingKind;
  try {
    validateVariantBinding({ ...options, hapKind: undefined });
  } catch (error) {
    missingKind = error;
  }
  if (!/hapKind is required/.test(missingKind?.message ?? '')) {
    throw new Error(`missing explicit kind should fail, got ${missingKind?.stack ?? missingKind}`);
  }
  console.log('[test-check-mg-build-contract] PASS: artifact kind is mandatory even with an explicit path');

  writeFixture({
    effectiveCompatibleSdk: '6.1.0(23)',
    module: moduleJson({ minAPIVersion: 60100023 }),
  });
  reject('effective non-secret SDK/compiler projection must equal tracked template', /differs from tracked non-secret template/, () => {
    validateVariantBinding(options);
  });

  const nestedLock = {
    nested_spirv_cross_commit: '1'.repeat(40),
    nested_glslang_commit: '2'.repeat(40),
    nested_perfetto_commit: '3'.repeat(40),
    nested_xxhash_commit: '4'.repeat(40),
    nested_ska_commit: '5'.repeat(40),
  };
  const optionalPerfetto = [
    ` ${'1'.repeat(40)} MobileGlues-cpp/3rdparty/SPIRV-Cross`,
    ` ${'2'.repeat(40)} MobileGlues-cpp/3rdparty/glslang`,
    `-${'3'.repeat(40)} MobileGlues-cpp/3rdparty/perfetto`,
    ` ${'4'.repeat(40)} MobileGlues-cpp/3rdparty/xxhash`,
    ` ${'5'.repeat(40)} MobileGlues-cpp/include/ska`,
  ].join('\n');
  const optionalInspection = inspectNestedSubmodules(optionalPerfetto, nestedLock);
  if (optionalInspection.issues.length ||
      optionalInspection.nested.find(item => item.path.endsWith('perfetto'))?.state !== 'unavailable') {
    throw new Error(`optional uninitialized perfetto should be recorded, not rejected: ${optionalInspection.issues}`);
  }
  console.log('[test-check-mg-build-contract] PASS: optional uninitialized perfetto is recorded without failure');

  const missingGlslang = optionalPerfetto.replace(
    ` ${'2'.repeat(40)} MobileGlues-cpp/3rdparty/glslang`,
    `-${'2'.repeat(40)} MobileGlues-cpp/3rdparty/glslang`,
  );
  const requiredInspection = inspectNestedSubmodules(missingGlslang, nestedLock);
  if (!requiredInspection.issues.some(issue => /glslang/.test(issue))) {
    throw new Error('required uninitialized glslang should be rejected');
  }
  console.log('[test-check-mg-build-contract] PASS: required uninitialized glslang is rejected');

  for (const remote of [
    'https://user:secret-token@github.com/Owner/Source.git',
    'git@github.com:Owner/Source.git',
  ]) {
    const sanitized = sanitizeRemoteIdentity(remote);
    if (sanitized !== 'github.com/Owner/Source' || /user|secret-token|git@/.test(sanitized)) {
      throw new Error(`remote credentials were not sanitized: ${sanitized}`);
    }
  }
  if (sanitizeRemoteIdentity('D:\\private\\source') !== 'non-network-remote') {
    throw new Error('Windows local remote path must not enter provenance');
  }
  console.log('[test-check-mg-build-contract] PASS: remote provenance strips userinfo and tokens');

  const coreFlags = [
    '-O2', '-g', '-DNDEBUG', '-flto=thin', '-fvisibility=hidden',
    '-ffunction-sections', '-fdata-sections',
  ];
  const goodCompile = `clang++ ${coreFlags.join(' ')} -c source.cpp`;
  if (effectiveCompileFlagIssues(goodCompile, coreFlags).length) {
    throw new Error('effective compile flag baseline should pass');
  }
  const conflictingCompile = `${goodCompile} -O0 -g0 -UNDEBUG -fno-lto ` +
    '-fvisibility=default -fno-function-sections -fno-data-sections';
  const conflictingIssues = effectiveCompileFlagIssues(conflictingCompile, coreFlags);
  if (conflictingIssues.length !== coreFlags.length) {
    throw new Error(`later conflicting flags must all fail closed: ${conflictingIssues}`);
  }
  console.log('[test-check-mg-build-contract] PASS: later conflicting compile flags cannot false-green');

  const mgRoot = 'D:/repo/prebuilt/mobileglues/mg_src/MobileGlues-cpp';
  const classified = classifyMobileGluesCompileRows([
    {
      file: `${mgRoot}/config/cJSON.c`,
      output: 'mobileglues/CMakeFiles/mobileglues_core.dir/config/cJSON.c.o',
    },
    {
      file: `${mgRoot}/gl/enable.cpp`,
      output: 'mobileglues/CMakeFiles/mobileglues_core.dir/gl/enable.cpp.o',
    },
    {
      file: `${mgRoot}/config/cJSON.c`,
      output: 'CMakeFiles/amcl_mg_config_json.dir/config/cJSON.c.o',
    },
  ]);
  if (classified.core.length !== 2 || classified.hostHelper.length !== 1 ||
      classified.core.includes(classified.hostHelper[0])) {
    throw new Error('private host cJSON row must not inflate or weaken the 38-row MG core contract');
  }
  console.log('[test-check-mg-build-contract] PASS: private host helper is distinct from MG core rows');

  const versionScript = join(fixtureRoot, 'entry/src/main/cpp/glfw/glfw_mg.version');
  const finalSo = join(fixtureRoot, 'entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libglfw.so');
  const goodLinkFlags = `-Wl,--version-script=${versionScript} -Wl,-Bsymbolic-functions ` +
    '-Wl,--gc-sections -flto=thin';
  const linkNinja = [
    'build unrelated.so: CXX_SHARED_LIBRARY_LINKER__other',
    `  LINK_FLAGS = ${goodLinkFlags}`,
    `build ${finalSo.replaceAll('\\', '/').replace(':', '$:')}: CXX_SHARED_LIBRARY_LINKER__glfw_Release objects.o`,
    '  LINK_FLAGS = -Wl,--no-gc-sections -fno-lto',
  ].join('\n');
  const selectedFlags = extractFinalLinkFlags(linkNinja, finalSo);
  const selectedIssues = finalLinkFlagIssues(selectedFlags, versionScript);
  if (!selectedIssues.some(issue => /section GC/.test(issue)) ||
      !selectedIssues.some(issue => /LTO/.test(issue)) ||
      !selectedIssues.some(issue => /version script/.test(issue))) {
    throw new Error(`flags on an unrelated Ninja edge must not satisfy libglfw: ${selectedIssues}`);
  }
  if (finalLinkFlagIssues(goodLinkFlags, versionScript).length) {
    throw new Error('bound final-link flag baseline should pass');
  }
  console.log('[test-check-mg-build-contract] PASS: final link flags are bound to the libglfw Ninja edge');

  const explicitUnsigned = {
    status: 1,
    stdout: 'Verify Hap failed, signature not found.',
    stderr: 'verify: No Hap Signing Block before ZIP Central Directory',
  };
  if (!isExplicitUnsignedVerifierFailure(explicitUnsigned) ||
      isExplicitUnsignedVerifierFailure({ status: 2, stderr: 'usage error' }) ||
      isExplicitUnsignedVerifierFailure({ status: 1, error: new Error('spawn failed'), stderr: explicitUnsigned.stderr }) ||
      isExplicitUnsignedVerifierFailure({ ...explicitUnsigned, status: 0 })) {
    throw new Error('unsigned signature classification must accept only the explicit no-signature diagnostic');
  }
  console.log('[test-check-mg-build-contract] PASS: verifier usage/crash errors cannot masquerade as unsigned');

  const lockedToolchain = {
    schemaVersion: 1,
    platform: 'win32-x64',
    compileSdkVersion: 'sdk',
    targetAPIVersion: 23,
    minAPIVersion: 20,
    nativeCompiler: 'BiSheng',
    signingAlgorithm: 'SHA256withECDSA',
    compiler: { versionFirstLine: 'clang', sha256: 'a' },
    cmake: { versionFirstLine: 'cmake', sha256: 'b' },
    hvigor: { version: '1', launcherSha256: 'c' },
    toolchainFile: { sha256: 'd' },
    hapSignTool: { sha256: 'e' },
  };
  if (toolchainLockIssues(lockedToolchain, structuredClone(lockedToolchain)).length) {
    throw new Error('matching toolchain lock should pass');
  }
  const driftedToolchain = structuredClone(lockedToolchain);
  driftedToolchain.compiler.sha256 = 'replaced';
  if (!toolchainLockIssues(lockedToolchain, driftedToolchain)
    .some(issue => /compiler\.sha256/.test(issue))) {
    throw new Error('replaced compiler binary must fail the toolchain lock');
  }
  console.log('[test-check-mg-build-contract] PASS: legacy flat toolchain lock remains compatible and fail-closed');

  const api26Toolchain = {
    ...structuredClone(lockedToolchain),
    compileSdkVersion: '26.0.0.105',
    targetAPIVersion: 260_000_026,
    minAPIVersion: 260_000_026,
    hvigor: { version: '6.26.4', launcherSha256: 'desktop-launcher' },
  };
  delete api26Toolchain.schemaVersion;
  const mobileToolchain = structuredClone(lockedToolchain);
  delete mobileToolchain.schemaVersion;
  const productLock = {
    schemaVersion: 2,
    products: {
      default: mobileToolchain,
      desktop: api26Toolchain,
    },
  };
  const actualApi26 = { schemaVersion: 1, ...structuredClone(api26Toolchain) };
  if (toolchainLockIssues(productLock, actualApi26, 'desktop').length) {
    throw new Error('matching API26 product-keyed lock should pass');
  }
  if (!toolchainLockIssues(productLock, actualApi26, 'missing')
    .some(issue => /no immutable record/.test(issue))) {
    throw new Error('an unregistered product must fail schemaVersion=2 closed');
  }
  if (!toolchainLockIssues(productLock, actualApi26, 'default')
    .some(issue => /compileSdkVersion|targetAPIVersion|hvigor/.test(issue))) {
    throw new Error('API26 artifact must not pass with the mobile product lock');
  }
  if (!toolchainLockIssues(productLock, actualApi26)
    .some(issue => /explicit product key/.test(issue))) {
    throw new Error('schemaVersion=2 must never guess a product lock');
  }
  console.log('[test-check-mg-build-contract] PASS: product-keyed API26 lock selects exactly one product');

  writeFixture();
  const firstRecord = fileRecord(fixtureRoot, paths.hapPath);
  utimesSync(paths.hapPath, Date.now() / 1000 + 60, Date.now() / 1000 + 60);
  const copiedRecord = fileRecord(fixtureRoot, paths.hapPath);
  if (JSON.stringify(firstRecord) !== JSON.stringify(copiedRecord)) {
    throw new Error('persistent file evidence must not depend on transport-mutated mtime');
  }
  const recorded = {
    schemaVersion: 2,
    generatedAt: '2026-08-10T00:00:00.000Z',
    artifacts: { hap: firstRecord },
  };
  const current = { ...recorded, generatedAt: '2026-08-11T00:00:00.000Z' };
  if (provenanceComparisonIssues(recorded, current).length) {
    throw new Error('valid generatedAt differences must not invalidate portable provenance');
  }
  if (!provenanceComparisonIssues({ ...recorded, generatedAt: 'invalid' }, current)
    .some(issue => /invalid generatedAt/.test(issue))) {
    throw new Error('invalid provenance timestamp must fail closed');
  }
  console.log('[test-check-mg-build-contract] PASS: provenance survives artifact mtime changes');

  // Behavioural translator passes are asserted from the artifact's .rodata,
  // because the source tree staying self-consistent is exactly what let one of
  // them disappear from the shipped library unnoticed.
  const evidenceFixture = [
    { literal: 'FlattenedFixtureMarker', pass: 'fixture pass', source: 'fixture.cpp' },
  ];
  const withMarker = Buffer.concat([
    Buffer.from([0x7f, 0x45, 0x4c, 0x46]),
    Buffer.from('...FlattenedFixtureMarker\0...', 'utf8'),
  ]);
  if (translatorEvidenceIssues(withMarker, evidenceFixture).length) {
    throw new Error('an image carrying the evidence literal must pass');
  }
  const withoutMarker = Buffer.from('an image built without that pass\0', 'utf8');
  const missing = translatorEvidenceIssues(withoutMarker, evidenceFixture);
  if (missing.length !== 1 || !/missing the evidence literal for fixture pass/.test(missing[0])) {
    throw new Error(`a stripped-out pass must be reported once: ${JSON.stringify(missing)}`);
  }
  // The real list must not be empty, or the check above would be decoration.
  if (!translatorEvidenceIssues(Buffer.alloc(0)).length) {
    throw new Error('REQUIRED_TRANSLATOR_EVIDENCE is empty; the artifact check asserts nothing');
  }
  console.log('[test-check-mg-build-contract] PASS: a translator pass missing from the artifact is rejected');
} finally {
  const temp = resolve(tmpdir());
  const rel = resolve(fixtureRoot).slice(temp.length);
  if (!rel.startsWith('\\') && !rel.startsWith('/')) {
    throw new Error(`refusing to remove fixture outside temp: ${fixtureRoot}`);
  }
  rmSync(fixtureRoot, { recursive: true, force: true });
}

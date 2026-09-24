#!/usr/bin/env node
// Fail-closed audit for the MobileGlues release variant and the HAP that is
// actually shipped. The exported binding validator is intentionally free of
// toolchain/Git dependencies so false-green cases can be covered by fixtures.

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { inflateRawSync } from 'node:zlib';
import process from 'node:process';
import { computeMgSourceIdentity } from './compute-mg-source-identity.mjs';
import { productDefinition } from './product-contract.mjs';

const SCRIPT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SCHEMA_VERSION = 2;
const TOKEN = /^[A-Za-z0-9_.-]+$/;
const SHA1 = /^[0-9a-f]{40}$/;
const FRESHNESS_TOLERANCE_MS = 2_000;

const CORE_FLAGS = [
  '-O2',
  '-g',
  '-DNDEBUG',
  '-flto=thin',
  '-fvisibility=hidden',
  '-ffunction-sections',
  '-fdata-sections',
];
const SHADER_FLAGS = ['-O2', '-g', '-DNDEBUG', '-ffunction-sections', '-fdata-sections'];
const HOST_HELPER_FLAGS = [
  '-O2',
  '-DNDEBUG',
  '-fvisibility=hidden',
  '-ffunction-sections',
  '-fdata-sections',
];
const LINK_FLAGS = [
  '-Wl,--version-script=',
  '-Wl,-Bsymbolic-functions',
  '-Wl,--gc-sections',
  '-flto=thin',
];

const SHIPPING_PRODUCTS = new Set([
  'default',
  'store',
  'sideload',
  'desktop',
]);
const RELEASE_INPUT_PLANE = {
  MC_OHOS_BUILD_TESTS: 'OFF',
  AMCL_GLFW_TYPED_PHYSICAL_DEFAULT: 'ON',
  AMCL_GLFW_RAW_RELATIVE_VERIFIED: 'ON',
};

const ALLOWED_MG_EXPORTS = new Set([
  'mg_initialize_v1',
  'mg_get_init_report_v1',
  'mg_angle_in_use',
  'mg_multidraw_bench_progress',
  'mg_multidraw_bench_run',
  'mg_glMultiDrawElementsBaseVertex_indirect',
  'mg_glMultiDrawElementsBaseVertex_multiindirect',
  'mg_glMultiDrawElementsBaseVertex_basevertex',
  'mg_glMultiDrawElementsBaseVertex_drawelements',
  'mg_glMultiDrawElementsBaseVertex_compute',
  'mg_glMultiDrawElementsBaseVertex_multibasevertex',
  'mg_glMultiDrawElements_indirect',
  'mg_glMultiDrawElements_multiindirect',
  'mg_glMultiDrawElements_basevertex',
  'mg_glMultiDrawElements_drawelements',
  'mg_glMultiDrawElements_compute',
  'mg_glMultiDrawElements_multibasevertex',
  'mg_glMultiDrawElements_multiarrays',
  'mg_glMultiDrawArrays_unroll',
  'mg_glMultiDrawArrays_multiarrays',
  'mg_glMultiDrawArrays_multiindirect',
]);
const REQUIRED_AMCL_EXPORTS = new Set([
  'glfwAMCLMobileGluesBenchmarkRunV1',
]);

export function productBenchmarkIssues(product, compileRows, exportedNames) {
  const developer = productDefinition(product).developerDiagnostics;
  const issues = [];
  const benchmarkCompiled = compileRows.some(row => /[/\\]bench[/\\]multidraw_bench\.cpp$/.test(row.file));
  if (benchmarkCompiled !== developer) issues.push(`benchmark translation unit expected present=${developer} for ${product}`);
  for (const name of ['mg_multidraw_bench_progress', 'mg_multidraw_bench_run', ...REQUIRED_AMCL_EXPORTS]) {
    if (exportedNames.has(name) !== developer) issues.push(`benchmark ABI ${name} expected present=${developer} for ${product}`);
  }
  return issues;
}

export function productVersionScript(source, product) {
  return productDefinition(product).developerDiagnostics ? source
    : source.replace(/[ \t]*mg_multidraw_bench_(progress|run);\r?\n/g, '');
}

// Translator passes that change what a shader compiles to must be provable from
// the shipped artifact, not from the source tree.
//
// This exists because the ESSL conformance rewrite for dynamically indexed
// fragment output arrays was lost once already: MG f37e20d fixed MC 26.3 on a
// device, the 2026-08-10 move to the 2.0 baseline dropped it, and every existing
// gate stayed green -- the source tree was self-consistent, the pin matched the
// gitlink, and the diff whitelist simply did not mention the file. The only
// observable difference was on a device, weeks later.
//
// A symbol-name probe cannot serve as the check: these passes have internal
// linkage and ThinLTO may inline them away. Their log literals sit in .rodata,
// which survives both inlining and strip, so the literal is the durable
// evidence. Removing a pass therefore requires removing its entry here, which
// is a reviewable act rather than a silent omission.
export const REQUIRED_TRANSLATOR_EVIDENCE = [
  {
    literal: 'Flattened dynamically indexed fragment output array',
    pass: 'ESSL dynamic fragment-output-array flattening (ESSL 4.3.6, MC 26.3 OIT)',
    source: 'MobileGlues-cpp/gl/glsl/glsl_for_es.cpp',
  },
  {
    // The literal has to be a run of bytes the compiler puts in .rodata as one
    // piece, so it is the part of the LOG_I format string before the first `%`.
    // LOG_I is unconditional; LOG_W and LOG_E compile to nothing unless DEBUG or
    // GLOBAL_DEBUG is set (gl/log.h), which is why they cannot carry evidence.
    literal: 'Token-aware uniform initializer pass',
    pass: 'ESSL uniform-initializer stripping, token-aware and fail-closed (ESSL 4.3.5)',
    source: 'MobileGlues-cpp/gl/glsl/uniform_initializer_core.h',
  },
];

export class ContractError extends Error {
  constructor(issues) {
    super(issues.join('\n'));
    this.name = 'ContractError';
    this.issues = issues;
  }
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

function slash(value) {
  return resolve(value).replaceAll('\\', '/').replace(/\/$/, '');
}

function comparablePath(value) {
  const normalized = slash(value);
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized;
}

function relativePosix(root, path) {
  return relative(root, path).replaceAll('\\', '/');
}

function assertContained(path, parent, label, issues) {
  const rel = relative(parent, path);
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    issues.push(`${label} escapes expected variant directory: ${path}`);
  }
}

export function fileRecord(root, path, extra = {}) {
  const data = readFileSync(path);
  return {
    path: relativePosix(root, path),
    size: data.length,
    sha256: sha256(data),
    ...extra,
  };
}

function stripJson5(text) {
  let result = '';
  let quote = '';
  let escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];
    if (quote) {
      result += char;
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      result += char;
      continue;
    }
    if (char === '/' && next === '/') {
      while (index < text.length && text[index] !== '\n') index += 1;
      result += '\n';
      continue;
    }
    if (char === '/' && next === '*') {
      index += 2;
      while (index < text.length && !(text[index] === '*' && text[index + 1] === '/')) {
        if (text[index] === '\n') result += '\n';
        index += 1;
      }
      index += 1;
      continue;
    }
    result += char;
  }
  // The tracked profile template uses JSON keys and double-quoted strings; the
  // only JSON5 syntax that remains after comments is a trailing comma.
  return result.replace(/,\s*([}\]])/g, '$1');
}

function parseJson5File(path) {
  return JSON.parse(stripJson5(readFileSync(path, 'utf8')));
}

function parseCache(text) {
  const values = new Map();
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^([^#/:][^:]*):[^=]*=(.*)$/);
    if (match) values.set(match[1], match[2]);
  }
  return values;
}

export function releaseInputPlaneIssues(product, cache, metadataText) {
  const issues = [];
  if (!SHIPPING_PRODUCTS.has(product)) {
    return [`no release input-plane contract is registered for product=${product}`];
  }
  const expected = {
    ...RELEASE_INPUT_PLANE,
    AMCL_GLFW_API26_RAW_MOUSE_MOTION: 'ON',
    AMCL_INPUT_COMPILED_FORMAL_DESKTOP: product === 'desktop' ? 'ON' : 'OFF',
  };
  for (const [key, value] of Object.entries(expected)) {
    const observed = cache.get(key);
    if (observed !== value) {
      issues.push(
        `release input plane ${key}=${observed ?? 'missing'} in CMakeCache; ` +
        `expected ${value} for product=${product}`,
      );
    }

    const pattern = new RegExp(`^-D${key}(?::[^=]+)?=(.+)$`, 'gm');
    const definitions = [...String(metadataText).matchAll(pattern)].map(match => match[1].trim());
    // Every enabled route and the tests=OFF exclusion must come from this
    // configure invocation, not merely from a CMake default or a stale cache.
    const mustBeExplicit = value === 'ON' || key === 'MC_OHOS_BUILD_TESTS' ||
      (key === 'AMCL_INPUT_COMPILED_FORMAL_DESKTOP' &&
        product === 'desktop');
    if (mustBeExplicit && definitions.length === 0) {
      issues.push(`release configure metadata is missing explicit -D${key}=${value}`);
    } else if (definitions.length > 0 && definitions.at(-1) !== value) {
      issues.push(
        `release configure metadata ends with -D${key}=${definitions.at(-1)}; expected ${value}`,
      );
    }
  }
  return issues;
}

export function sdkApiLevel(version) {
  const text = String(version);
  const legacy = text.match(/^(\d+)\.(\d+)\.(\d+)\((\d+)\)$/);
  if (legacy) {
    const packed = Number(legacy[1]) * 10_000_000 + Number(legacy[2]) * 100_000 +
      Number(legacy[3]) * 1_000 + Number(legacy[4]);
    return Number.isSafeInteger(packed) ? packed : null;
  }

  // HarmonyOS API 26 changed the public target/compatible SDK spelling from
  // the legacy "6.1.0(23)" shape to "26.0.0".  The HAP still carries the
  // packed numeric representation and repeats the API level in the low digits:
  // 26.0.0 -> 260000026.  Keep this strict so malformed or pre-26 bare
  // versions cannot be mistaken for a valid product/HAP match.
  const modern = text.match(/^(\d+)\.0\.0$/);
  if (!modern) return null;
  const api = Number(modern[1]);
  if (!Number.isSafeInteger(api) || api < 26) return null;
  const packed = api * 10_000_000 + api;
  return Number.isSafeInteger(packed) ? packed : null;
}

export function sanitizedProfileProjection(profile, productName, targetName) {
  const product = profile?.app?.products?.find(item => item.name === productName);
  if (!product) throw new Error(`profile has no product=${productName}`);
  const target = profile?.modules
    ?.find(item => item.name === 'entry')
    ?.targets?.find(item => item.name === targetName);
  if (!target) throw new Error(`profile has no entry target=${targetName}`);
  const strict = product.buildOption?.strictMode ?? {};
  return {
    product: {
      name: product.name,
      targetSdkVersion: product.targetSdkVersion ?? null,
      compatibleSdkVersion: product.compatibleSdkVersion ?? null,
      runtimeOS: product.runtimeOS ?? null,
      nativeCompiler: product.buildOption?.nativeCompiler ?? null,
      strictMode: {
        caseSensitiveCheck: strict.caseSensitiveCheck ?? null,
        useNormalizedOHMUrl: strict.useNormalizedOHMUrl ?? null,
      },
    },
    buildModes: (profile?.app?.buildModeSet ?? []).map(item => item.name).sort(),
    entryTarget: {
      name: target.name,
      applyToProducts: [...(target.applyToProducts ?? [])].sort(),
    },
  };
}

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

// HAP is a ZIP container. Reading it directly avoids a platform-dependent tar
// command and lets the guard detect duplicate module/library entries.
export function readZipEntries(archive) {
  const minimum = Math.max(0, archive.length - 65_557);
  let eocd = -1;
  for (let offset = archive.length - 22; offset >= minimum; offset -= 1) {
    if (archive.readUInt32LE(offset) === 0x06054b50) {
      eocd = offset;
      break;
    }
  }
  if (eocd < 0) throw new Error('ZIP end-of-central-directory record is missing');
  if (archive.readUInt16LE(eocd + 4) !== 0 || archive.readUInt16LE(eocd + 6) !== 0) {
    throw new Error('multi-disk HAP archives are unsupported');
  }
  const entryCount = archive.readUInt16LE(eocd + 10);
  let offset = archive.readUInt32LE(eocd + 16);
  const entries = [];
  for (let index = 0; index < entryCount; index += 1) {
    if (offset + 46 > archive.length || archive.readUInt32LE(offset) !== 0x02014b50) {
      throw new Error(`invalid ZIP central entry ${index}`);
    }
    const flags = archive.readUInt16LE(offset + 8);
    const method = archive.readUInt16LE(offset + 10);
    const expectedCrc = archive.readUInt32LE(offset + 16);
    const compressedSize = archive.readUInt32LE(offset + 20);
    const uncompressedSize = archive.readUInt32LE(offset + 24);
    const nameLength = archive.readUInt16LE(offset + 28);
    const extraLength = archive.readUInt16LE(offset + 30);
    const commentLength = archive.readUInt16LE(offset + 32);
    const localOffset = archive.readUInt32LE(offset + 42);
    const name = archive.subarray(offset + 46, offset + 46 + nameLength).toString('utf8');
    if (flags & 1) throw new Error(`encrypted HAP entry is unsupported: ${name}`);
    if (localOffset + 30 > archive.length || archive.readUInt32LE(localOffset) !== 0x04034b50) {
      throw new Error(`invalid local ZIP entry: ${name}`);
    }
    const localNameLength = archive.readUInt16LE(localOffset + 26);
    const localExtraLength = archive.readUInt16LE(localOffset + 28);
    const dataOffset = localOffset + 30 + localNameLength + localExtraLength;
    const compressed = archive.subarray(dataOffset, dataOffset + compressedSize);
    let data;
    if (method === 0) data = Buffer.from(compressed);
    else if (method === 8) data = inflateRawSync(compressed);
    else throw new Error(`unsupported ZIP method ${method} for ${name}`);
    if (data.length !== uncompressedSize || crc32(data) !== expectedCrc) {
      throw new Error(`corrupt HAP entry: ${name}`);
    }
    entries.push({ name, data });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

function archiveEntry(entries, name, issues) {
  const matches = entries.filter(entry => entry.name === name);
  if (matches.length !== 1) {
    issues.push(`HAP must contain exactly one ${name}; got ${matches.length}`);
    return Buffer.alloc(0);
  }
  return matches[0].data;
}

function expectedTargetTriple(abi) {
  if (abi === 'arm64-v8a') return 'aarch64-linux-ohos';
  if (abi === 'x86_64') return 'x86_64-linux-ohos';
  throw new Error(`unsupported ABI in MG release contract: ${abi}`);
}

export function resolveEvidencePaths(options = {}) {
  const root = resolve(options.root ?? SCRIPT_ROOT);
  const product = options.product ?? 'default';
  const target = options.target ?? product;
  const mode = String(options.mode ?? 'release').toLowerCase();
  const abi = options.abi ?? 'arm64-v8a';
  if (!options.hapKind) throw new Error('hapKind is required; select signed or unsigned explicitly');
  const hapKind = options.hapKind;
  for (const [label, value] of Object.entries({ product, target, mode, abi, hapKind })) {
    if (!TOKEN.test(value)) throw new Error(`invalid ${label}: ${value}`);
  }
  if (mode !== 'release') throw new Error(`MG shipping contract only accepts mode=release, got ${mode}`);
  if (!['signed', 'unsigned'].includes(hapKind)) throw new Error(`invalid HAP kind: ${hapKind}`);
  expectedTargetTriple(abi);

  const buildDir = resolve(root, 'entry', '.cxx', product, target, mode, abi);
  const outputDir = resolve(root, 'entry', 'build', product, 'outputs', target);
  const expectedHapPath = resolve(outputDir, `entry-${target}-${hapKind}.hap`);
  const hapPath = resolve(options.hapPath ?? expectedHapPath);
  if (comparablePath(hapPath) !== comparablePath(expectedHapPath)) {
    throw new ContractError([
      `selected HAP path must exactly match artifactKind=${hapKind}: ${expectedHapPath}; got ${hapPath}`,
    ]);
  }
  return {
    root,
    product,
    target,
    mode,
    abi,
    hapKind,
    buildDir,
    outputDir,
    compileDb: join(buildDir, 'compile_commands.json'),
    cachePath: join(buildDir, 'CMakeCache.txt'),
    ninjaPath: join(buildDir, 'build.ninja'),
    metadataCommandPath: join(buildDir, 'metadata_generation_command.txt'),
    cmakeSo: resolve(
      root,
      'entry', 'build', product, 'intermediates', 'cmake', target, 'obj', abi, 'libglfw.so',
    ),
    stagedSo: resolve(
      root,
      'entry', 'build', product, 'intermediates', 'libs', target, abi, 'libglfw.so',
    ),
    strippedSo: resolve(
      root,
      'entry', 'build', product, 'intermediates', 'stripped_native_libs', target, abi,
      'libglfw.so',
    ),
    cmakeGlHostSo: resolve(
      root, 'entry', 'build', product, 'intermediates', 'cmake', target, 'obj', abi, 'libamcl_gl_host.so',
    ),
    stagedGlHostSo: resolve(
      root, 'entry', 'build', product, 'intermediates', 'libs', target, abi, 'libamcl_gl_host.so',
    ),
    strippedGlHostSo: resolve(
      root, 'entry', 'build', product, 'intermediates', 'stripped_native_libs', target, abi,
      'libamcl_gl_host.so',
    ),
    hapPath,
    profilePath: resolve(root, 'build-profile.json5'),
    profileTemplatePath: resolve(root, 'build-profile.json5.template'),
    toolchainLockPath: resolve(root, 'toolchain.lock'),
    mgRoot: resolve(root, 'prebuilt', 'mobileglues', 'mg_src'),
  };
}

function checkFreshness(paths, issues) {
  const graphTime = Math.max(
    statSync(paths.compileDb).mtimeMs,
    statSync(paths.cachePath).mtimeMs,
    statSync(paths.ninjaPath).mtimeMs,
    statSync(paths.metadataCommandPath).mtimeMs,
  );
  const cmakeTime = statSync(paths.cmakeSo).mtimeMs;
  const stagedTime = statSync(paths.stagedSo).mtimeMs;
  const strippedTime = statSync(paths.strippedSo).mtimeMs;
  const hapTime = statSync(paths.hapPath).mtimeMs;
  if (cmakeTime + FRESHNESS_TOLERANCE_MS < graphTime) {
    issues.push('unstripped libglfw.so predates the selected Release compile graph (stale artifact)');
  }
  if (stagedTime + FRESHNESS_TOLERANCE_MS < cmakeTime) {
    issues.push('staged libglfw.so predates the selected CMake output');
  }
  if (strippedTime + FRESHNESS_TOLERANCE_MS < stagedTime) {
    issues.push('stripped libglfw.so predates the staged unstripped library');
  }
  if (hapTime + FRESHNESS_TOLERANCE_MS < strippedTime) {
    issues.push('HAP predates the selected stripped libglfw.so (stale package)');
  }
  if (paths.glHostSplit) {
    const hostCmakeTime = statSync(paths.cmakeGlHostSo).mtimeMs;
    const hostStagedTime = statSync(paths.stagedGlHostSo).mtimeMs;
    const hostStrippedTime = statSync(paths.strippedGlHostSo).mtimeMs;
    if (hostCmakeTime + FRESHNESS_TOLERANCE_MS < graphTime) issues.push('unstripped libamcl_gl_host.so predates the selected Release compile graph');
    if (hostStagedTime + FRESHNESS_TOLERANCE_MS < hostCmakeTime) issues.push('staged libamcl_gl_host.so predates the selected CMake output');
    if (hostStrippedTime + FRESHNESS_TOLERANCE_MS < hostStagedTime) issues.push('stripped libamcl_gl_host.so predates the selected staged library');
    if (hapTime + FRESHNESS_TOLERANCE_MS < hostStrippedTime) issues.push('HAP predates the selected stripped libamcl_gl_host.so');
  }
}

// Establishes that every artifact belongs to one product/target/mode/ABI before
// the more expensive compiler, symbol, source-pin and provenance checks run.
export function validateVariantBinding(options = {}) {
  const paths = resolveEvidencePaths(options);
  // New graphs place MobileGlues::Core in libamcl_gl_host.so. Older fixture
  // graphs intentionally model the historical monolithic libglfw contract.
  paths.glHostSplit = existsSync(paths.ninjaPath) &&
    /(?:libamcl_gl_host\.so|amcl_gl_host\.dir)/i.test(readFileSync(paths.ninjaPath, 'utf8'));
  const issues = [];
  assertContained(paths.buildDir, resolve(paths.root, 'entry', '.cxx'), 'build directory', issues);
  assertContained(paths.hapPath, paths.outputDir, 'HAP', issues);
  const required = [
    [paths.compileDb, 'Release compile database'],
    [paths.cachePath, 'Release CMake cache'],
    [paths.ninjaPath, 'Release Ninja graph'],
    [paths.metadataCommandPath, 'Release CMake configure metadata'],
    [paths.cmakeSo, 'CMake unstripped libglfw.so'],
    [paths.stagedSo, 'staged unstripped libglfw.so'],
    [paths.strippedSo, 'stripped libglfw.so'],
    ...(paths.glHostSplit ? [
      [paths.cmakeGlHostSo, 'CMake unstripped libamcl_gl_host.so'],
      [paths.stagedGlHostSo, 'staged unstripped libamcl_gl_host.so'],
      [paths.strippedGlHostSo, 'stripped libamcl_gl_host.so'],
    ] : []),
    [paths.hapPath, `${paths.hapKind} HAP`],
    [paths.profilePath, 'effective build-profile.json5'],
    [paths.profileTemplatePath, 'tracked build-profile.json5.template'],
    [paths.toolchainLockPath, 'tracked toolchain.lock'],
  ];
  for (const [path, label] of required) {
    if (!existsSync(path)) issues.push(`${label} missing: ${path}`);
  }
  if (issues.length) throw new ContractError(issues);

  let compileRows;
  try {
    compileRows = JSON.parse(readFileSync(paths.compileDb, 'utf8'));
  } catch (error) {
    issues.push(`cannot parse compile database: ${error.message}`);
  }
  if (!Array.isArray(compileRows) || compileRows.length === 0) {
    issues.push('compile database must be a non-empty array');
    compileRows = [];
  }
  const expectedDir = comparablePath(paths.buildDir);
  const triple = expectedTargetTriple(paths.abi);
  for (const [index, row] of compileRows.entries()) {
    const directory = comparablePath(row.directory ?? paths.root);
    if (directory !== expectedDir) {
      issues.push(`compile row ${index} belongs to another build directory: ${row.directory}`);
      break;
    }
    if (!String(row.command ?? '').includes(`--target=${triple}`)) {
      issues.push(`compile row ${index} does not target ${triple}`);
      break;
    }
    if (row.output) {
      const output = resolve(row.directory, row.output);
      assertContained(output, paths.buildDir, `compile row ${index} output`, issues);
    }
  }

  const cacheText = readFileSync(paths.cachePath, 'utf8');
  const cache = parseCache(cacheText);
  const cacheChecks = [
    ['CMAKE_BUILD_TYPE', 'Release'],
    ['CMAKE_OHOS_ARCH_ABI', paths.abi],
    ['OHOS_ARCH', paths.abi],
  ];
  for (const [key, expected] of cacheChecks) {
    if (cache.get(key) !== expected) issues.push(`CMake cache ${key}=${cache.get(key)}; expected ${expected}`);
  }
  for (const [key, expected] of [
    ['mc_ohos_native_BINARY_DIR', paths.buildDir],
    ['CMAKE_HOME_DIRECTORY', resolve(paths.root, 'entry', 'src', 'main', 'cpp')],
  ]) {
    if (comparablePath(cache.get(key) ?? paths.root) !== comparablePath(expected)) {
      issues.push(`CMake cache ${key} belongs to another tree: ${cache.get(key)}`);
    }
  }
  const metadataText = readFileSync(paths.metadataCommandPath, 'utf8');
  issues.push(...releaseInputPlaneIssues(paths.product, cache, metadataText));

  const ninja = readFileSync(paths.ninjaPath, 'utf8');
  const normalizedNinja = ninja.replaceAll('$:', ':').replaceAll('\\', '/').toLowerCase();
  for (const [label, path] of [
    ['build directory', paths.buildDir],
    ['final unstripped libglfw.so', paths.cmakeSo],
  ]) {
    if (!normalizedNinja.includes(slash(path).toLowerCase())) {
      issues.push(`Ninja graph does not reference selected ${label}: ${path}`);
    }
  }

  let profile;
  try {
    profile = parseJson5File(paths.profilePath);
  } catch (error) {
    issues.push(`cannot parse effective build-profile.json5: ${error.message}`);
    profile = {};
  }
  const productProfile = profile?.app?.products?.find(item => item.name === paths.product);
  if (!productProfile) issues.push(`effective build profile has no product=${paths.product}`);
  const signingName = productProfile?.signingConfig;
  const signingConfig = profile?.app?.signingConfigs?.find(item => item.name === signingName);
  if (!signingName || !signingConfig) {
    issues.push(`product=${paths.product} does not resolve to an effective signing config`);
  }
  if (signingConfig?.type !== 'HarmonyOS') {
    issues.push(`effective signing config type=${signingConfig?.type}; expected HarmonyOS`);
  }
  if (signingConfig?.material?.signAlg !== 'SHA256withECDSA') {
    issues.push(
      `effective signing algorithm=${signingConfig?.material?.signAlg}; expected SHA256withECDSA`,
    );
  }
  let templateProfile = {};
  try {
    templateProfile = parseJson5File(paths.profileTemplatePath);
  } catch (error) {
    issues.push(`cannot parse tracked build-profile.json5.template: ${error.message}`);
  }
  let profileProjection;
  let templateProjection;
  try {
    profileProjection = sanitizedProfileProjection(profile, paths.product, paths.target);
    templateProjection = sanitizedProfileProjection(templateProfile, paths.product, paths.target);
    if (JSON.stringify(profileProjection) !== JSON.stringify(templateProjection)) {
      issues.push(
        `effective product/buildMode profile differs from tracked non-secret template: ` +
        `effective=${JSON.stringify(profileProjection)} template=${JSON.stringify(templateProjection)}`,
      );
    }
  } catch (error) {
    issues.push(`cannot project product/buildMode profile contract: ${error.message}`);
  }

  let entries = [];
  try {
    entries = readZipEntries(readFileSync(paths.hapPath));
  } catch (error) {
    issues.push(`cannot read HAP: ${error.message}`);
  }
  const moduleBytes = archiveEntry(entries, 'module.json', issues);
  let moduleJson = {};
  if (moduleBytes.length) {
    try {
      moduleJson = JSON.parse(moduleBytes.toString('utf8'));
    } catch (error) {
      issues.push(`HAP module.json is invalid: ${error.message}`);
    }
  }
  if (moduleJson?.app?.buildMode !== 'release') {
    issues.push(`HAP module.json app.buildMode=${moduleJson?.app?.buildMode}; expected release`);
  }
  if (moduleJson?.app?.debug !== false) {
    issues.push(`HAP module.json app.debug=${moduleJson?.app?.debug}; expected false`);
  }
  if (moduleJson?.module?.name !== 'entry') {
    issues.push(`HAP module.json module.name=${moduleJson?.module?.name}; expected entry`);
  }
  if (productProfile) {
    const targetApi = sdkApiLevel(productProfile.targetSdkVersion);
    const compatibleApi = sdkApiLevel(productProfile.compatibleSdkVersion);
    if (targetApi === null || targetApi !== moduleJson?.app?.targetAPIVersion) {
      issues.push(
        `effective product targetSdkVersion=${productProfile.targetSdkVersion} does not match ` +
        `HAP targetAPIVersion=${moduleJson?.app?.targetAPIVersion}`,
      );
    }
    if (compatibleApi === null || compatibleApi !== moduleJson?.app?.minAPIVersion) {
      issues.push(
        `effective product compatibleSdkVersion=${productProfile.compatibleSdkVersion} does not match ` +
        `HAP minAPIVersion=${moduleJson?.app?.minAPIVersion}`,
      );
    }
  }

  const embeddedPath = `libs/${paths.abi}/libglfw.so`;
  const embeddedSo = archiveEntry(entries, embeddedPath, issues);
  const embeddedGlHostPath = `libs/${paths.abi}/libamcl_gl_host.so`;
  const embeddedGlHostSo = paths.glHostSplit ? archiveEntry(entries, embeddedGlHostPath, issues) : Buffer.alloc(0);
  const allEmbeddedGlfw = entries.filter(entry => /(?:^|\/)libglfw\.so$/.test(entry.name));
  if (allEmbeddedGlfw.length !== 1) {
    issues.push(`HAP must contain one libglfw.so image across all paths; got ${allEmbeddedGlfw.length}`);
  }
  if (paths.glHostSplit) {
    const allEmbeddedGlHost = entries.filter(entry => /(?:^|\/)libamcl_gl_host\.so$/.test(entry.name));
    if (allEmbeddedGlHost.length !== 1) issues.push(`HAP must contain one libamcl_gl_host.so image; got ${allEmbeddedGlHost.length}`);
  }
  const duplicateMobileGlues = entries.filter(entry => /(?:^|\/)libmobileglues\.so$/.test(entry.name));
  if (duplicateMobileGlues.length) issues.push('HAP contains forbidden standalone libmobileglues.so');

  const cmakeBytes = readFileSync(paths.cmakeSo);
  const stagedBytes = readFileSync(paths.stagedSo);
  const strippedBytes = readFileSync(paths.strippedSo);
  const cmakeGlHostBytes = paths.glHostSplit ? readFileSync(paths.cmakeGlHostSo) : Buffer.alloc(0);
  const stagedGlHostBytes = paths.glHostSplit ? readFileSync(paths.stagedGlHostSo) : Buffer.alloc(0);
  const strippedGlHostBytes = paths.glHostSplit ? readFileSync(paths.strippedGlHostSo) : Buffer.alloc(0);
  if (sha256(cmakeBytes) !== sha256(stagedBytes)) {
    issues.push('staged unstripped libglfw.so hash differs from the selected CMake output');
  }
  if (embeddedSo.length && sha256(strippedBytes) !== sha256(embeddedSo)) {
    issues.push(
      `HAP libglfw hash ${sha256(embeddedSo)} != stripped intermediate ${sha256(strippedBytes)}`,
    );
  }
  if (paths.glHostSplit) {
    if (sha256(cmakeGlHostBytes) !== sha256(stagedGlHostBytes)) issues.push('staged libamcl_gl_host.so hash differs from the selected CMake output');
    if (embeddedGlHostSo.length && sha256(strippedGlHostBytes) !== sha256(embeddedGlHostSo)) {
      issues.push(`HAP libamcl_gl_host.so hash ${sha256(embeddedGlHostSo)} != stripped intermediate ${sha256(strippedGlHostBytes)}`);
    }
    for (const [name, bytes] of [['CMake unstripped libamcl_gl_host.so', cmakeGlHostBytes], ['staged libamcl_gl_host.so', stagedGlHostBytes], ['stripped libamcl_gl_host.so', strippedGlHostBytes], ['HAP libamcl_gl_host.so', embeddedGlHostSo]]) {
      try {
        const identity = readElfIdentity(bytes);
        if (identity.type !== 3 || identity.machine !== 183 || identity.soname !== 'libamcl_gl_host.so' || !identity.buildId) issues.push(`${name} has invalid GL host ELF identity`);
      } catch (error) { issues.push(`${name} ELF identity failed: ${error.message}`); }
    }
    issues.push(...translatorEvidenceIssues(strippedGlHostBytes));
  }
  // Checked against the stripped image, which the hash comparison above has
  // already bound to the one inside the HAP: this asserts the pass is in the
  // library that ships, not merely in one that was built along the way.
  if (!paths.glHostSplit) issues.push(...translatorEvidenceIssues(strippedBytes));
  // File mtimes are meaningful only on the build host. Artifact download,
  // extraction and copying legitimately rewrite them, so persistent evidence
  // is re-verified by hashes, sizes and ELF identities instead.
  if (!options.verifyProvenance) checkFreshness(paths, issues);

  if (issues.length) throw new ContractError(issues);
  return {
    paths,
    compileRows,
    cache,
    cacheText,
    metadataText,
    ninja,
    profile,
    templateProfile,
    profileProjection,
    productProfile,
    signingConfig,
    moduleJson,
    moduleBytes,
    embeddedPath,
    embeddedSo,
    embeddedGlHostPath,
    embeddedGlHostSo,
    cmakeBytes,
    stagedBytes,
    strippedBytes,
    cmakeGlHostBytes,
    stagedGlHostBytes,
    strippedGlHostBytes,
  };
}

function u64(buffer, offset) {
  const value = buffer.readBigUInt64LE(offset);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('ELF offset exceeds safe integer range');
  return Number(value);
}

function readNotes(buffer, offset, size) {
  let cursor = offset;
  const end = offset + size;
  while (cursor + 12 <= end && cursor + 12 <= buffer.length) {
    const nameSize = buffer.readUInt32LE(cursor);
    const descSize = buffer.readUInt32LE(cursor + 4);
    const type = buffer.readUInt32LE(cursor + 8);
    cursor += 12;
    const name = buffer.subarray(cursor, cursor + nameSize).toString('ascii').replace(/\0+$/, '');
    cursor += (nameSize + 3) & ~3;
    const description = buffer.subarray(cursor, cursor + descSize);
    cursor += (descSize + 3) & ~3;
    if (name === 'GNU' && type === 3 && description.length) return description.toString('hex');
  }
  return null;
}

// Parse identity directly from all four buffers. This prevents a copied old
// compile database from being paired with a newer Release library that merely
// has the same filename.
// Pure so the self-test can drive it with synthetic buffers instead of needing a
// real build. Takes the image bytes and reports one issue per missing pass.
export function translatorEvidenceIssues(imageBytes, expected = REQUIRED_TRANSLATOR_EVIDENCE) {
  const issues = [];
  for (const entry of expected) {
    if (!imageBytes.includes(entry.literal)) {
      issues.push(
        `shipped libglfw.so is missing the evidence literal for ${entry.pass}: ` +
        `${JSON.stringify(entry.literal)} (expected from ${entry.source}). ` +
        'Either the pass is not compiled into the artifact, or it was removed ' +
        'without updating REQUIRED_TRANSLATOR_EVIDENCE.',
      );
    }
  }
  return issues;
}

export function readElfIdentity(buffer) {
  if (buffer.length < 64 || !buffer.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]))) {
    throw new Error('not an ELF file');
  }
  if (buffer[4] !== 2 || buffer[5] !== 1) throw new Error('ELF must be 64-bit little-endian');
  const type = buffer.readUInt16LE(16);
  const machine = buffer.readUInt16LE(18);
  const phoff = u64(buffer, 32);
  const phentsize = buffer.readUInt16LE(54);
  const phnum = buffer.readUInt16LE(56);
  const loads = [];
  const notes = [];
  let dynamic = null;
  for (let index = 0; index < phnum; index += 1) {
    const offset = phoff + index * phentsize;
    if (offset + 56 > buffer.length) throw new Error('truncated ELF program header');
    const segmentType = buffer.readUInt32LE(offset);
    const segment = {
      offset: u64(buffer, offset + 8),
      virtualAddress: u64(buffer, offset + 16),
      fileSize: u64(buffer, offset + 32),
    };
    if (segmentType === 1) loads.push(segment);
    else if (segmentType === 2) dynamic = segment;
    else if (segmentType === 4) notes.push(segment);
  }
  let buildId = null;
  for (const note of notes) buildId ??= readNotes(buffer, note.offset, note.fileSize);
  let soname = null;
  if (dynamic) {
    let stringAddress;
    let stringSize;
    let sonameOffset;
    for (let offset = dynamic.offset; offset + 16 <= dynamic.offset + dynamic.fileSize; offset += 16) {
      const tag = Number(buffer.readBigInt64LE(offset));
      const value = u64(buffer, offset + 8);
      if (tag === 0) break;
      if (tag === 5) stringAddress = value;
      else if (tag === 10) stringSize = value;
      else if (tag === 14) sonameOffset = value;
    }
    if (stringAddress !== undefined && sonameOffset !== undefined) {
      const load = loads.find(item =>
        stringAddress >= item.virtualAddress && stringAddress < item.virtualAddress + item.fileSize,
      );
      if (load) {
        const stringTable = load.offset + (stringAddress - load.virtualAddress);
        const start = stringTable + sonameOffset;
        const maximum = Math.min(buffer.length, stringTable + (stringSize ?? buffer.length));
        let end = start;
        while (end < maximum && buffer[end] !== 0) end += 1;
        soname = buffer.subarray(start, end).toString('utf8');
      }
    }
  }
  return {
    class: 'ELF64',
    endian: 'little',
    type,
    machine,
    abi: machine === 183 ? 'AArch64' : `machine-${machine}`,
    soname,
    buildId,
  };
}

export function readElfSectionNames(buffer) {
  if (buffer.length < 64 || !buffer.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]))) {
    throw new Error('not an ELF file');
  }
  if (buffer[4] !== 2 || buffer[5] !== 1) throw new Error('ELF must be 64-bit little-endian');
  const sectionOffset = u64(buffer, 40);
  const sectionEntrySize = buffer.readUInt16LE(58);
  const sectionCount = buffer.readUInt16LE(60);
  const stringTableIndex = buffer.readUInt16LE(62);
  if (sectionOffset === 0 || sectionEntrySize === 0 || sectionCount === 0) return [];
  if (stringTableIndex >= sectionCount) throw new Error('invalid ELF section string table index');
  const stringHeader = sectionOffset + stringTableIndex * sectionEntrySize;
  if (stringHeader + 64 > buffer.length) throw new Error('truncated ELF section string table header');
  const stringOffset = u64(buffer, stringHeader + 24);
  const stringSize = u64(buffer, stringHeader + 32);
  if (stringOffset + stringSize > buffer.length) throw new Error('truncated ELF section string table');

  const names = [];
  for (let index = 0; index < sectionCount; index += 1) {
    const header = sectionOffset + index * sectionEntrySize;
    if (header + 64 > buffer.length) throw new Error('truncated ELF section header');
    const nameOffset = buffer.readUInt32LE(header);
    if (nameOffset >= stringSize) throw new Error('invalid ELF section name offset');
    let end = stringOffset + nameOffset;
    while (end < stringOffset + stringSize && buffer[end] !== 0) end += 1;
    names.push(buffer.subarray(stringOffset + nameOffset, end).toString('utf8'));
  }
  return names;
}

const COMPILE_FLAG_FAMILIES = new Map([
  ['-O2', { label: 'optimization', pattern: '-O(?:0|1|2|3|s|z|g|fast)' }],
  ['-g', { label: 'debug info', pattern: '-g(?:0|1|2|3|line-tables-only)?' }],
  ['-DNDEBUG', { label: 'NDEBUG', pattern: '-(?:D|U)NDEBUG' }],
  ['-flto=thin', { label: 'LTO', pattern: '-(?:flto(?:=(?:thin|full|auto|jobserver|[0-9]+))?|fno-lto)' }],
  ['-fvisibility=hidden', {
    label: 'visibility', pattern: '-fvisibility=(?:default|hidden|internal|protected)',
  }],
  ['-ffunction-sections', {
    label: 'function sections', pattern: '-f(?:no-)?function-sections',
  }],
  ['-fdata-sections', { label: 'data sections', pattern: '-f(?:no-)?data-sections' }],
]);

function lastFlagInFamily(command, pattern) {
  const matches = [...String(command).matchAll(new RegExp(`(?:^|\\s)(${pattern})(?=\\s|$)`, 'g'))];
  return matches.at(-1)?.[1] ?? null;
}

export function effectiveCompileFlagIssues(command, requiredFlags) {
  const issues = [];
  for (const expected of requiredFlags) {
    const family = COMPILE_FLAG_FAMILIES.get(expected);
    if (!family) throw new Error(`no effective-flag family configured for ${expected}`);
    const actual = lastFlagInFamily(command, family.pattern);
    if (actual !== expected) {
      issues.push(`${family.label} effective flag=${actual ?? 'missing'}; expected ${expected}`);
    }
  }
  return issues;
}

function assertRows(rows, label, expectedCount, flags, issues) {
  if (rows.length !== expectedCount) {
    issues.push(`${label}: expected ${expectedCount} compile rows, got ${rows.length}`);
  }
  const failures = new Map();
  for (const row of rows) {
    for (const issue of effectiveCompileFlagIssues(row.command, flags)) {
      failures.set(issue, (failures.get(issue) ?? 0) + 1);
    }
  }
  for (const [issue, count] of failures) {
    issues.push(`${label}: ${count}/${rows.length} rows violate ${issue}`);
  }
}

export function classifyMobileGluesCompileRows(compileRows) {
  const posix = value => String(value).replaceAll('\\', '/');
  const mgMarker = '/prebuilt/mobileglues/mg_src/MobileGlues-cpp/';
  const core = compileRows.filter(row => {
    const file = `/${posix(row.file)}`;
    const output = `/${posix(row.output ?? '')}`;
    return file.includes(mgMarker) && !file.includes('/3rdparty/') &&
      output.includes('/mobileglues/CMakeFiles/mobileglues_core.dir/');
  });
  const hostHelper = compileRows.filter(row => {
    const file = `/${posix(row.file)}`;
    const output = `/${posix(row.output ?? '')}`;
    return file.endsWith(`${mgMarker}config/cJSON.c`) &&
      output.includes('/CMakeFiles/amcl_mg_config_json.dir/');
  });
  return { core, hostHelper };
}

export function extractFinalLinkFlags(ninja, outputPath) {
  const normalize = value => {
    const normalized = String(value).replaceAll('$:', ':').replaceAll('\\', '/');
    return process.platform === 'win32' ? normalized.toLowerCase() : normalized;
  };
  const expectedPrefix = normalize(`build ${slash(outputPath)}:`);
  const lines = String(ninja).split(/\r?\n/);
  const edge = lines.findIndex(line => normalize(line).startsWith(expectedPrefix));
  if (edge < 0 || /:\s+phony(?:\s|$)/.test(lines[edge])) return null;
  for (let index = edge + 1; index < lines.length && /^\s+\S/.test(lines[index]); index += 1) {
    const match = lines[index].match(/^\s+LINK_FLAGS\s*=\s*(.*)$/);
    if (match) return match[1];
  }
  return null;
}

export function finalLinkFlagIssues(flags, versionScriptPath, requireLto = true) {
  const issues = [];
  if (flags === null) return ['cannot resolve LINK_FLAGS from the final libglfw.so Ninja edge'];
  const lto = lastFlagInFamily(flags, '-(?:flto(?:=(?:thin|full|auto|jobserver|[0-9]+))?|fno-lto)');
  if (requireLto && lto !== '-flto=thin') issues.push(`final-link LTO effective flag=${lto ?? 'missing'}; expected -flto=thin`);
  const gc = lastFlagInFamily(flags, '-Wl,--(?:no-)?gc-sections');
  if (gc !== '-Wl,--gc-sections') {
    issues.push(`final-link section GC effective flag=${gc ?? 'missing'}; expected -Wl,--gc-sections`);
  }
  const versionScript = lastFlagInFamily(flags, '-Wl,--version-script=[^\\s]+');
  const expectedScript = comparablePath(versionScriptPath);
  const actualScript = versionScript
    ? comparablePath(versionScript.slice('-Wl,--version-script='.length).replace(/^"|"$/g, ''))
    : null;
  if (actualScript !== expectedScript) {
    issues.push(`final-link version script=${actualScript ?? 'missing'}; expected ${expectedScript}`);
  }
  if (lastFlagInFamily(flags, '-Wl,-Bsymbolic-functions') !== '-Wl,-Bsymbolic-functions') {
    issues.push('final-link missing -Wl,-Bsymbolic-functions');
  }
  return issues;
}

function executableFromCommand(command) {
  const match = String(command).match(/^\s*(?:"([^"]+)"|(\S+))/);
  return match?.[1] ?? match?.[2] ?? null;
}

function runOrThrow(executable, args, cwd, options = {}) {
  const result = spawnSync(executable, args, {
    cwd,
    encoding: options.binary ? null : 'utf8',
    maxBuffer: options.maxBuffer ?? 32 * 1024 * 1024,
    windowsVerbatimArguments: options.windowsVerbatimArguments ?? false,
  });
  if (result.error || result.status !== 0) {
    throw new Error(
      `${executable} ${args.join(' ')} failed: ` +
      `${result.error?.message ?? String(result.stderr || result.stdout).trim()}`,
    );
  }
  return result.stdout;
}

export function runVersionCommand(executable, args, cwd) {
  if (process.platform === 'win32' && /\.(?:bat|cmd)$/i.test(executable)) {
    const quote = value => `"${String(value).replaceAll('"', '""')}"`;
    // `cmd /s /c ""path with spaces" ..."` is parsed inconsistently when
    // supplied through CreateProcess. `call` with one /c command string is the
    // normal batch-file form and preserves the wrapper's exit status.
    const commandLine = ['call', quote(executable), ...args.map(quote)].join(' ');
    return runOrThrow(process.env.ComSpec ?? 'cmd.exe',
      ['/d', '/c', commandLine], cwd, { windowsVerbatimArguments: true });
  }
  return runOrThrow(executable, args, cwd);
}

function decodePropertiesPath(value) {
  return value.trim().replace(/\\\\/g, '\\').replace(/\\:/g, ':');
}

/** 共享官方验签工具定位：兼容 SDK 根、local.properties 与本机受控工具包入口。 */
export function findHapSignTool(root) {
  const sdkRoots = [process.env.DEVECO_SDK_HOME ?? '', process.env.OHOS_SDK_HOME ?? ''];
  const properties = join(root, 'local.properties');
  if (existsSync(properties)) {
    const match = readFileSync(properties, 'utf8').match(/^\s*hwsdk\.dir\s*=\s*(.+)\s*$/m);
    if (match !== null) sdkRoots.push(decodePropertiesPath(match[1]));
  }
  if (process.platform === 'win32') {
    sdkRoots.push('D:\\Huawei\\command-line-tools\\sdk', 'D:\\Huawei\\DevEco Studio\\sdk');
  }
  const candidates = [];
  for (const sdkRoot of [...new Set(sdkRoots.filter(Boolean))]) {
    candidates.push(
      join(sdkRoot, 'toolchains', 'lib', 'hap-sign-tool.jar'),
      join(sdkRoot, 'default', 'openharmony', 'toolchains', 'lib', 'hap-sign-tool.jar'),
    );
  }
  return candidates.find(candidate => existsSync(candidate)) ?? '';
}

export function isExplicitUnsignedVerifierFailure(result) {
  if (!Number.isInteger(result?.status) || result.status === 0 || result.error) return false;
  const diagnostic = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  return /signature not found/i.test(diagnostic) &&
    /No Hap Signing Block before ZIP Central Directory/i.test(diagnostic);
}

export function verifyHapSignature(paths) {
  const verifier = findHapSignTool(paths.root);
  if (!verifier) throw new Error('hap-sign-tool.jar not found in the configured DevEco SDK');
  const javaProbe = spawnSync('java', ['-version'], { encoding: 'utf8' });
  if (javaProbe.error || javaProbe.status !== 0) throw new Error('java is unavailable for HAP verification');

  const temp = mkdtempSync(join(workspaceTempRoot(), 'amcl-hap-signature-'));
  try {
    const certificate = join(temp, 'certificate-chain.cer');
    const profile = join(temp, 'profile.p7b');
    const result = spawnSync('java', [
      '-jar', verifier, 'verify-app',
      '-inForm', 'zip',
      '-inFile', paths.hapPath,
      '-outCertChain', certificate,
      '-outProfile', profile,
    ], { cwd: temp, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
    if (result.error) throw new Error(`HAP signature verifier failed to start: ${result.error.message}`);

    if (paths.hapKind === 'signed') {
      if (result.status !== 0) {
        throw new Error(`signed HAP failed cryptographic verification (exit ${result.status})`);
      }
      if (!existsSync(certificate) || statSync(certificate).size === 0 ||
          !existsSync(profile) || statSync(profile).size === 0) {
        throw new Error('signed HAP verification did not extract a certificate chain and profile');
      }
      return {
        artifactKind: 'signed',
        result: 'valid-signature',
        verifier: 'hap-sign-tool.jar',
        verifierSha256: sha256(readFileSync(verifier)),
        certificateChainSha256: sha256(readFileSync(certificate)),
        profileSha256: sha256(readFileSync(profile)),
      };
    }

    if (result.status === 0) {
      throw new Error('unsigned HAP unexpectedly passed cryptographic signature verification');
    }
    if (!isExplicitUnsignedVerifierFailure(result)) {
      throw new Error(
        `unsigned HAP verifier failed without an explicit no-signature result (exit ${result.status})`,
      );
    }
    return {
      artifactKind: 'unsigned',
      result: 'no-valid-signature',
      verifier: 'hap-sign-tool.jar',
      verifierSha256: sha256(readFileSync(verifier)),
      certificateChainSha256: null,
      profileSha256: null,
    };
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

function git(root, args) {
  return String(runOrThrow('git', args, root)).replace(/\r?\n$/, '');
}

function readLockSection(path, sectionName) {
  const result = {};
  let active = false;
  for (const raw of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (line === `[${sectionName}]`) {
      active = true;
      continue;
    }
    if (line.startsWith('[')) active = false;
    if (!active || !line || line.startsWith('#')) continue;
    const match = line.match(/^([^=]+?)\s*=\s*(.*?)\s*(?:#.*)?$/);
    if (match) result[match[1].trim()] = match[2].trim();
  }
  return result;
}

export function sanitizeRemoteIdentity(value) {
  const raw = String(value).trim();
  if (raw.includes('://')) {
    try {
      const parsed = new URL(raw);
      if (!['https:', 'http:', 'ssh:', 'git:'].includes(parsed.protocol)) return 'non-network-remote';
      return `${parsed.hostname.toLowerCase()}/${parsed.pathname.replace(/^\/+|\/+$/g, '').replace(/\.git$/i, '')}`;
    } catch {
      return 'non-network-remote';
    }
  }
  if (/^[A-Za-z]:[\\/]/.test(raw)) return 'non-network-remote';
  const scp = raw.match(/^(?:[^@\s/:]+@)?([A-Za-z0-9.-]+):([^\s]+)$/);
  if (scp) return `${scp[1].toLowerCase()}/${scp[2].replace(/^\/+|\/+$/g, '').replace(/\.git$/i, '')}`;
  return 'non-network-remote';
}

const REQUIRED_NESTED = new Set([
  'MobileGlues-cpp/3rdparty/SPIRV-Cross',
  'MobileGlues-cpp/3rdparty/glslang',
  'MobileGlues-cpp/3rdparty/xxhash',
  'MobileGlues-cpp/include/ska',
]);

export function inspectNestedSubmodules(output, lock = {}) {
  const issues = [];
  const nestedLocks = new Map([
    ['MobileGlues-cpp/3rdparty/SPIRV-Cross', lock.nested_spirv_cross_commit],
    ['MobileGlues-cpp/3rdparty/glslang', lock.nested_glslang_commit],
    ['MobileGlues-cpp/3rdparty/perfetto', lock.nested_perfetto_commit],
    ['MobileGlues-cpp/3rdparty/xxhash', lock.nested_xxhash_commit],
    ['MobileGlues-cpp/include/ska', lock.nested_ska_commit],
  ]);
  const nested = output ? output.split(/\r?\n/).filter(Boolean).map(line => {
    const match = line.match(/^(.)([0-9a-f]{40})\s+(.+?)(?:\s+\(.*\))?$/);
    if (!match) {
      issues.push(`cannot parse nested submodule status: ${line}`);
      return { path: line, commit: null, lockedCommit: null, state: 'invalid', available: false };
    }
    const path = match[3];
    const marker = match[1];
    const required = REQUIRED_NESTED.has(path);
    const available = marker !== '-';
    if ((required && marker !== ' ') || (!required && marker !== ' ' && marker !== '-')) {
      issues.push(`nested dependency is not at its recorded commit: ${path} (state=${marker})`);
    }
    const lockedCommit = nestedLocks.get(path) ?? null;
    if (!SHA1.test(lockedCommit ?? '') || lockedCommit !== match[2]) {
      issues.push(`nested dependency pin mismatch for ${path}: lock=${lockedCommit}, gitlink=${match[2]}`);
    }
    return {
      path,
      commit: match[2],
      lockedCommit,
      state: marker === ' ' ? 'pinned' : marker === '-' ? 'unavailable' : marker,
      available,
      required,
    };
  }) : [];
  for (const required of REQUIRED_NESTED) {
    const item = nested.find(candidate => candidate.path === required);
    if (!item || !item.available) issues.push(`required nested dependency is not initialized: ${required}`);
  }
  return { nested, issues };
}

const MG_BUILD_IDENTITY_OPTION_KEYS = [
  'AMCL_MG_FRAME_STATS',
  'AMCL_MG_FRAME_STATS_EXHAUSTIVE',
  'AMCL_MG_UPLOAD_SCHEDULER_LAB',
  'AMCL_MG_BUFFER_UPLOAD_MODE_OVERRIDE',
  'AMCL_MG_EMBED_BUILD_STANDALONE',
  'AMCL_MG_EMBED_AUTO_INIT',
  'AMCL_MG_EMBED_PROFILING',
  'MOBILEGLUES_LTO_MODE',
  'CMAKE_BUILD_TYPE',
];

function mgBuildIdentityOptions(cache, issues) {
  const options = {};
  for (const key of MG_BUILD_IDENTITY_OPTION_KEYS) {
    const value = cache.get(key);
    if (value === undefined || value === '') {
      issues.push(`CMake cache is missing MG build identity option ${key}`);
    }
    options[key] = value ?? '';
  }
  return options;
}

function sourceEvidence(context, options, issues) {
  const requireClean = options.requireClean ?? false;
  const allowDirtyMg = options.allowDirtyMg ?? false;
  const { root, mgRoot } = context.paths;
  const lock = readLockSection(join(root, 'deps.lock'), 'mobileglues');
  const superprojectCommit = git(root, ['rev-parse', 'HEAD']).trim();
  const superprojectStatus = git(root, ['status', '--porcelain=v1', '--untracked-files=all']);
  const mgCommit = git(mgRoot, ['rev-parse', 'HEAD']).trim();
  const mgStatus = git(mgRoot, ['status', '--porcelain=v1', '--untracked-files=all']);
  const gitlinkLine = git(root, ['ls-files', '--stage', '--', 'prebuilt/mobileglues/mg_src']);
  const gitlink = gitlinkLine.match(/^160000\s+([0-9a-f]{40})\s/)?.[1];
  const androidReleaseCommit = lock.android_renderer_commit ?? lock.android_release_commit;
  const upstreamRelease = lock.release_tag ?? lock.upstream_release;
  for (const [label, value] of [
    ['deps.lock commit', lock.commit],
    ['deps.lock base_commit', lock.base_commit],
    ['deps.lock Android renderer commit', androidReleaseCommit],
    ['deps.lock android_plugin_commit', lock.android_plugin_commit],
    ['MobileGlues HEAD', mgCommit],
    ['superproject MG gitlink', gitlink],
  ]) {
    if (!SHA1.test(value ?? '')) issues.push(`${label} is not a full commit: ${value}`);
  }
  if (lock.commit !== mgCommit || lock.commit !== gitlink) {
    issues.push(`MobileGlues pin mismatch: lock=${lock.commit}, gitlink=${gitlink}, HEAD=${mgCommit}`);
  }
  if (mgStatus && !allowDirtyMg) {
    issues.push(`MobileGlues source or nested dependencies are dirty (use --allow-dirty-mg only for a non-release diagnostic build):\n${mgStatus}`);
  }
  if (requireClean && allowDirtyMg) {
    issues.push('--require-clean and --allow-dirty-mg are mutually exclusive');
  }
  if (requireClean && superprojectStatus) {
    issues.push('superproject is dirty while --require-clean is active');
  }

  const nestedOutput = git(mgRoot, ['submodule', 'status', '--recursive']);
  const nestedInspection = inspectNestedSubmodules(nestedOutput, lock);
  issues.push(...nestedInspection.issues);
  const nested = nestedInspection.nested;
  const mgSourceIdentity = computeMgSourceIdentity({
    repo: mgRoot,
    options: mgBuildIdentityOptions(context.cache, issues),
  });
  if (mgSourceIdentity.sourceCommit !== mgCommit) {
    issues.push(`computed MG identity commit ${mgSourceIdentity.sourceCommit} != inspected HEAD ${mgCommit}`);
  }
  if (mgSourceIdentity.worktreeDirty !== Boolean(mgStatus)) {
    issues.push(`computed MG dirty state ${mgSourceIdentity.worktreeDirty} != Git status ${Boolean(mgStatus)}`);
  }

  const remotesText = git(root, ['remote', '-v']);
  const remotes = remotesText
    ? [...new Set(remotesText.split(/\r?\n/).map(line => sanitizeRemoteIdentity(line.split(/\s+/)[1])))]
    : [];
  const dirtyCount = superprojectStatus ? superprojectStatus.split(/\r?\n/).filter(Boolean).length : 0;
  return {
    superproject: {
      commit: superprojectCommit,
      dirty: Boolean(superprojectStatus),
      dirtyCount,
      dirtyStatusSha256: superprojectStatus ? sha256(superprojectStatus) : null,
      remotes,
    },
    mobileglues: {
      commit: mgCommit,
      gitlink,
      lockedCommit: lock.commit,
      baseCommit: lock.base_commit,
      upstreamRelease,
      androidReleaseCommit,
      pluginCommit: lock.android_plugin_commit,
      repo: lock.repo,
      branch: lock.branch,
      nested,
      dirty: Boolean(mgStatus),
      worktreeSha256: mgSourceIdentity.worktreeSha256,
      dirtyStatusSha256: mgSourceIdentity.dirtyStatusSha256,
      untrackedFileCount: mgSourceIdentity.untrackedFileCount,
      buildOptionsSha256: mgSourceIdentity.buildOptionsSha256,
      buildOptions: mgSourceIdentity.options,
      buildIdentity: mgSourceIdentity.buildIdentity,
    },
  };
}

function auditCompileAndAbi(context, issues) {
  const developer = productDefinition(context.paths.product).developerDiagnostics;
  const posix = value => String(value).replaceAll('\\', '/');
  const mgMarker = '/prebuilt/mobileglues/mg_src/MobileGlues-cpp/';
  const classifiedMgRows = classifyMobileGluesCompileRows(context.compileRows);
  const mgRows = classifiedMgRows.core;
  assertRows(mgRows, 'MobileGlues core', developer ? 38 : 37, CORE_FLAGS, issues);
  const hostHelperRows = classifiedMgRows.hostHelper;
  assertRows(hostHelperRows, 'libentry private MG config helper', 1, HOST_HELPER_FLAGS, issues);
  if (mgRows.some(row => /[/\\]init\.cpp$/.test(row.file))) {
    issues.push('init.cpp entered the embedded core (constructor initialization regression)');
  }
  for (const source of [
    'config/stats.cpp',
    'egl/context.cpp',
    'gl/enable.cpp',
    'gl/restart.cpp',
    'gl/transfer.cpp',
  ]) {
    if (!mgRows.some(row => posix(row.file).endsWith(`/MobileGlues-cpp/${source}`))) {
      issues.push(`MobileGlues 2.0 source missing from compile database: ${source}`);
    }
  }
  const glslangRows = context.compileRows.filter(row =>
    posix(row.file).includes(`${mgMarker.slice(1)}3rdparty/glslang/`),
  );
  const spirvCrossRows = context.compileRows.filter(row =>
    posix(row.file).includes(`${mgMarker.slice(1)}3rdparty/SPIRV-Cross/`),
  );
  assertRows(glslangRows, 'glslang release stack', 47, SHADER_FLAGS, issues);
  assertRows(spirvCrossRows, 'SPIRV-Cross minimal stack', 6, SHADER_FLAGS, issues);
  for (const pattern of [
    /spirv_cross_hlsl\.cpp$/,
    /spirv_cross_msl\.cpp$/,
    /spirv_cross_cpp\.cpp$/,
    /spirv_reflect\.cpp$/,
  ]) {
    if (context.compileRows.some(row => pattern.test(posix(row.file)))) {
      issues.push(`disabled SPIRV-Cross backend compiled: ${pattern}`);
    }
  }
  if (context.cache.get('MOBILEGLUES_LTO_MODE') !== 'thin') {
    issues.push('CMake cache does not record MOBILEGLUES_LTO_MODE=thin');
  }
  const sourceVersionScriptPath = resolve(
    context.paths.root, 'entry', 'src', 'main', 'cpp', 'glfw', 'glfw_mg.version',
  );
  const versionScriptPath = developer ? sourceVersionScriptPath
    : resolve(context.paths.buildDir, 'glfw_mg_product.version');
  if (!existsSync(versionScriptPath) || readFileSync(versionScriptPath, 'utf8').replaceAll('\r\n', '\n') !==
      productVersionScript(readFileSync(sourceVersionScriptPath, 'utf8'), context.paths.product).replaceAll('\r\n', '\n')) {
    issues.push('effective product version script does not match the allowed benchmark-only projection');
  }
  const finalLinkFlags = extractFinalLinkFlags(context.ninja, context.paths.cmakeSo);
  // libglfw is now a small facade and does not own the MG core's LTO link.
  issues.push(...finalLinkFlagIssues(finalLinkFlags, versionScriptPath, false));
  if (context.paths.glHostSplit) {
    const hostSourceVersionScriptPath = resolve(context.paths.root, 'entry', 'src', 'main', 'cpp', 'platform', 'gl_host.version');
    const hostVersionScriptPath = developer ? hostSourceVersionScriptPath
      : resolve(context.paths.buildDir, 'gl_host_product.version');
    if (!existsSync(hostVersionScriptPath) || readFileSync(hostVersionScriptPath, 'utf8').replaceAll('\r\n', '\n') !==
        productVersionScript(readFileSync(hostSourceVersionScriptPath, 'utf8'), context.paths.product).replaceAll('\r\n', '\n')) {
      issues.push('effective GL host version script does not match the allowed benchmark projection');
    }
    const hostLinkFlags = extractFinalLinkFlags(context.ninja, context.paths.cmakeGlHostSo);
    // Core objects retain the checked ThinLTO compile flags. The provider DSO
    // link itself is a facade link and must still be checked for GC, symbolic
    // binding and its own version script; it does not require a second LTO
    // decision separate from the core object contract.
    issues.push(...finalLinkFlagIssues(hostLinkFlags, hostVersionScriptPath, false));
  }

  const identities = {};
  const sections = {};
  for (const [name, bytes] of [
    ['cmakeUnstripped', context.cmakeBytes],
    ['stagedUnstripped', context.stagedBytes],
    ['stripped', context.strippedBytes],
    ['hapEmbedded', context.embeddedSo],
  ]) {
    try {
      identities[name] = readElfIdentity(bytes);
      sections[name] = readElfSectionNames(bytes);
      const identity = identities[name];
      if (identity.type !== 3) issues.push(`${name} is not an ELF shared object`);
      if (identity.machine !== 183) issues.push(`${name} is not AArch64`);
      if (identity.soname !== 'libglfw.so') issues.push(`${name} SONAME=${identity.soname}; expected libglfw.so`);
      if (!identity.buildId) issues.push(`${name} has no GNU build-id`);
    } catch (error) {
      issues.push(`${name} ELF identity failed: ${error.message}`);
    }
  }
  for (const name of ['cmakeUnstripped', 'stagedUnstripped']) {
    const names = sections[name] ?? [];
    if (!names.includes('.symtab')) issues.push(`${name} is missing .symtab before stripping`);
    if (!names.some(section => section === '.debug_info' || section.startsWith('.debug_'))) {
      issues.push(`${name} is missing DWARF debug sections before stripping`);
    }
  }
  for (const name of ['stripped', 'hapEmbedded']) {
    const names = sections[name] ?? [];
    if (names.includes('.symtab')) issues.push(`${name} still contains forbidden .symtab`);
    const debugSections = names.filter(section => section === '.debug_info' || section.startsWith('.debug_'));
    if (debugSections.length) {
      issues.push(`${name} still contains debug sections: ${debugSections.join(', ')}`);
    }
  }
  const buildIds = new Set(Object.values(identities).map(item => item.buildId).filter(Boolean));
  if (buildIds.size !== 1 || Object.keys(identities).length !== 4) {
    issues.push(`unstripped/stripped/HAP GNU build-id mismatch: ${[...buildIds].join(', ')}`);
  }

  const cppRow = mgRows.find(row => String(row.file).endsWith('.cpp'));
  const compiler = executableFromCommand(cppRow?.command);
  if (!compiler || !existsSync(compiler)) issues.push(`cannot resolve compiler from compile database: ${compiler}`);
  const toolDir = compiler ? dirname(compiler) : '';
  const suffix = process.platform === 'win32' ? '.exe' : '';
  const llvmNm = join(toolDir, `llvm-nm${suffix}`);
  if (!existsSync(llvmNm)) issues.push(`llvm-nm missing: ${llvmNm}`);
  if (existsSync(llvmNm)) {
    try {
      const output = runOrThrow(
        llvmNm,
        ['-D', '--defined-only', '--format=posix', context.paths.strippedSo],
        context.paths.root,
      );
      const symbols = output.split(/\r?\n/).filter(Boolean).map(line => {
        const fields = line.trim().split(/\s+/);
        return { name: fields[0].replace(/@.*$/, ''), type: fields[1] ?? '' };
      });
      const names = new Set(symbols.map(symbol => symbol.name));
      issues.push(...productBenchmarkIssues(context.paths.product, mgRows, names));
      const mgNames = context.paths.glHostSplit
        ? new Set(runOrThrow(llvmNm, ['-D', '--defined-only', '--format=posix', context.paths.strippedGlHostSo], context.paths.root)
          .split(/\r?\n/).filter(Boolean).map(line => line.trim().split(/\s+/)[0].replace(/@.*$/, '')))
        : names;
      for (const expected of ALLOWED_MG_EXPORTS) {
        if (!developer && expected.startsWith('mg_multidraw_bench_')) continue;
        if (!mgNames.has(expected)) issues.push(`required MobileGlues ABI symbol missing: ${expected}`);
      }
      for (const expected of REQUIRED_AMCL_EXPORTS) {
        if (!developer) continue;
        if (!names.has(expected)) issues.push(`required AMCL/MobileGlues ABI symbol missing: ${expected}`);
      }
      const unexpected = [...mgNames].filter(name => name.startsWith('mg_') && !ALLOWED_MG_EXPORTS.has(name));
      if (unexpected.length) issues.push(`unexpected MobileGlues ABI exports: ${unexpected.join(', ')}`);
      for (const forbidden of [
        'proc_init', 'egl', 'gles', 'gl_state', 'global_settings', 'glsl_cache_file_path',
        'mg_directory_path',
      ]) {
        if (names.has(forbidden)) issues.push(`internal data/function leaked into public ABI: ${forbidden}`);
      }
      const dataExports = symbols.filter(symbol => /^[BbDdGgRrSsVv]$/.test(symbol.type));
      if (dataExports.length) {
        issues.push(`dynamic data exports are forbidden: ${dataExports.map(item => item.name).join(', ')}`);
      }
    } catch (error) {
      issues.push(error.message);
    }
  }
  return {
    mgRows, hostHelperRows, glslangRows, spirvCrossRows,
    identities, sections, finalLinkFlags, compiler,
  };
}

const TOOLCHAIN_RECORD_FIELDS = [
  'platform',
  'compileSdkVersion',
  'targetAPIVersion',
  'minAPIVersion',
  'nativeCompiler',
  'signingAlgorithm',
  'compiler.versionFirstLine',
  'compiler.sha256',
  'cmake.versionFirstLine',
  'cmake.sha256',
  'hvigor.version',
  'hvigor.launcherSha256',
  'toolchainFile.sha256',
  'hapSignTool.sha256',
];
const LEGACY_TOOLCHAIN_LOCK_FIELDS = ['schemaVersion', ...TOOLCHAIN_RECORD_FIELDS];

function nestedValue(value, path) {
  return path.split('.').reduce((current, key) => current?.[key], value);
}

export function toolchainLockIssues(lock, actual, product) {
  const issues = [];
  let expectedRecord;
  let fields;
  let label;
  if (lock?.schemaVersion === 1) {
    // Backward compatibility for repositories that still ship one flat lock.
    // It remains fail-closed when used against another product because all
    // target/min/tool hashes are compared exactly.
    expectedRecord = lock;
    fields = LEGACY_TOOLCHAIN_LOCK_FIELDS;
    label = 'toolchain.lock';
  } else if (lock?.schemaVersion === 2) {
    if (typeof product !== 'string' || !product) {
      return ['toolchain.lock schemaVersion=2 requires an explicit product key'];
    }
    if (!lock.products || typeof lock.products !== 'object' || Array.isArray(lock.products)) {
      return ['toolchain.lock schemaVersion=2 is missing its products object'];
    }
    expectedRecord = lock.products[product];
    if (!expectedRecord || typeof expectedRecord !== 'object' || Array.isArray(expectedRecord)) {
      return [`toolchain.lock has no immutable record for product=${product}`];
    }
    fields = TOOLCHAIN_RECORD_FIELDS;
    label = `toolchain.lock products.${product}`;
  } else {
    return [`unsupported toolchain.lock schemaVersion=${lock?.schemaVersion ?? 'missing'}; expected 1 or 2`];
  }

  for (const field of fields) {
    const expected = nestedValue(expectedRecord, field);
    const observed = nestedValue(actual, field);
    if (expected === undefined) {
      issues.push(`${label} is missing ${field}`);
    } else if (expected !== observed) {
      issues.push(
        `toolchain drift product=${product ?? 'legacy'} ${field}: ` +
        `actual=${observed ?? 'missing'} expected=${expected}`,
      );
    }
  }
  return issues;
}

function buildProvenance(context, audit, source, signature, issues, options) {
  const { paths } = context;
  const cache = context.cache;
  const cmake = cache.get('CMAKE_COMMAND');
  const toolchainFile = cache.get('CMAKE_TOOLCHAIN_FILE');
  let compilerVersion = null;
  let cmakeVersion = null;
  let hvigorVersion = null;
  try {
    compilerVersion = String(runOrThrow(audit.compiler, ['--version'], paths.root))
      .split(/\r?\n/)
      .filter(line => !/^InstalledDir:/i.test(line))
      .join('\n')
      .trim();
  } catch (error) {
    issues.push(`cannot record compiler version: ${error.message}`);
  }
  try {
    cmakeVersion = String(runOrThrow(cmake, ['--version'], paths.root)).trim();
  } catch (error) {
    issues.push(`cannot record CMake version: ${error.message}`);
  }
  if (options.hvigor) {
    const hvigor = resolve(options.hvigor);
    if (!existsSync(hvigor)) {
      issues.push(`explicit hvigor path does not exist: ${hvigor}`);
    } else {
      try {
        hvigorVersion = String(runVersionCommand(
          hvigor, ['--version', '--no-daemon'], paths.root)).trim();
      } catch (error) {
        issues.push(`cannot record hvigor version: ${error.message}`);
      }
    }
  } else {
    issues.push('build provenance requires explicit --hvigor <path>');
  }
  let toolchainLock = {};
  let toolchainLockSha256 = null;
  try {
    const lockBytes = readFileSync(paths.toolchainLockPath);
    toolchainLockSha256 = sha256(lockBytes);
    toolchainLock = JSON.parse(lockBytes.toString('utf8'));
  } catch (error) {
    issues.push(`cannot read toolchain.lock: ${error.message}`);
  }
  const hashFile = path => path && existsSync(path) ? sha256(readFileSync(path)) : null;
  const actualToolchain = {
    schemaVersion: 1,
    platform: `${process.platform}-${process.arch}`,
    compileSdkVersion: context.moduleJson.app.compileSdkVersion,
    targetAPIVersion: context.moduleJson.app.targetAPIVersion,
    minAPIVersion: context.moduleJson.app.minAPIVersion,
    nativeCompiler: context.productProfile?.buildOption?.nativeCompiler ?? null,
    signingAlgorithm: context.signingConfig?.material?.signAlg ?? null,
    compiler: {
      versionFirstLine: compilerVersion?.split(/\r?\n/)[0] ?? null,
      sha256: hashFile(audit.compiler),
    },
    cmake: {
      versionFirstLine: cmakeVersion?.split(/\r?\n/)[0] ?? null,
      sha256: hashFile(cmake),
    },
    hvigor: {
      version: hvigorVersion,
      launcherSha256: hashFile(options.hvigor ? resolve(options.hvigor) : null),
    },
    toolchainFile: { sha256: hashFile(toolchainFile) },
    hapSignTool: { sha256: signature?.verifierSha256 ?? null },
  };
  issues.push(...toolchainLockIssues(toolchainLock, actualToolchain, paths.product));
  const signingMaterial = context.signingConfig?.material ?? {};
  const signingFilesPresent = ['certpath', 'profile', 'storeFile'].every(key =>
    typeof signingMaterial[key] === 'string' && existsSync(signingMaterial[key]),
  );
  if (!signingFilesPresent) issues.push('effective signing config references missing certificate/profile/store files');

  const identityExtra = name => ({
    buildId: audit.identities[name]?.buildId ?? null,
    abi: audit.identities[name]?.abi ?? null,
    soname: audit.identities[name]?.soname ?? null,
  });
  // Never hash or serialize the ignored profile itself: it contains encrypted
  // passwords and machine-local certificate paths. Hash only this allow-listed
  // effective build projection.
  const sanitizedProfile = context.profileProjection;
  return {
    schemaVersion: SCHEMA_VERSION,
    generatedAt: new Date().toISOString(),
    evidencePolicy: {
      buildTimeOrderValidatedBeforeWrite: true,
      persistentVerification: 'sha256+size+elf-build-id',
    },
    variant: {
      product: paths.product,
      target: paths.target,
      buildMode: paths.mode,
      cmakeBuildType: context.cache.get('CMAKE_BUILD_TYPE'),
      abi: paths.abi,
      artifactKind: paths.hapKind,
    },
    source,
    effectiveProfile: {
      sanitizedSha256: sha256(JSON.stringify(sanitizedProfile)),
      ...sanitizedProfile,
      signing: {
        type: context.signingConfig?.type ?? null,
        signAlg: context.signingConfig?.material?.signAlg ?? null,
      },
      hap: {
        buildMode: context.moduleJson.app.buildMode,
        debug: context.moduleJson.app.debug,
        compileSdkVersion: context.moduleJson.app.compileSdkVersion,
        targetAPIVersion: context.moduleJson.app.targetAPIVersion,
        minAPIVersion: context.moduleJson.app.minAPIVersion,
      },
    },
    toolchain: {
      lockFile: relativePosix(paths.root, paths.toolchainLockPath),
      lockFileSha256: toolchainLockSha256,
      lockSchemaVersion: toolchainLock?.schemaVersion ?? null,
      lockProduct: toolchainLock?.schemaVersion === 2 ? paths.product : null,
      compileSdkVersion: context.moduleJson.app.compileSdkVersion,
      targetAPIVersion: context.moduleJson.app.targetAPIVersion,
      minAPIVersion: context.moduleJson.app.minAPIVersion,
      toolchainFile: toolchainFile ? basename(toolchainFile) : null,
      toolchainFileSha256: toolchainFile && existsSync(toolchainFile)
        ? sha256(readFileSync(toolchainFile))
        : null,
      compiler: audit.compiler ? basename(audit.compiler) : null,
      compilerVersion,
      compilerSha256: actualToolchain.compiler.sha256,
      cmake: cmake ? basename(cmake) : null,
      cmakeVersion,
      cmakeSha256: actualToolchain.cmake.sha256,
      hvigorVersion,
      hvigorLauncherSha256: actualToolchain.hvigor.launcherSha256,
    },
    signatureVerification: signature ?? {
      artifactKind: paths.hapKind,
      result: 'not-requested',
      verifier: null,
      verifierSha256: null,
      certificateChainSha256: null,
      profileSha256: null,
    },
    flagsContract: {
      mobilegluesCore: CORE_FLAGS,
      shaderDependencies: SHADER_FLAGS,
      finalLink: LINK_FLAGS,
      mobilegluesLtoMode: context.cache.get('MOBILEGLUES_LTO_MODE'),
      sourceCounts: {
        mobilegluesCore: audit.mgRows.length,
        mobilegluesHostHelper: audit.hostHelperRows.length,
        glslang: audit.glslangRows.length,
        spirvCross: audit.spirvCrossRows.length,
      },
    },
    artifacts: {
      compileDatabase: fileRecord(paths.root, paths.compileDb),
      cmakeCache: fileRecord(paths.root, paths.cachePath),
      cmakeConfigureMetadata: fileRecord(paths.root, paths.metadataCommandPath),
      ninjaGraph: fileRecord(paths.root, paths.ninjaPath),
      cmakeUnstripped: fileRecord(paths.root, paths.cmakeSo, identityExtra('cmakeUnstripped')),
      stagedUnstripped: fileRecord(paths.root, paths.stagedSo, identityExtra('stagedUnstripped')),
      stripped: fileRecord(paths.root, paths.strippedSo, identityExtra('stripped')),
      hap: fileRecord(paths.root, paths.hapPath),
      moduleJson: {
        archive: relativePosix(paths.root, paths.hapPath),
        entry: 'module.json',
        size: context.moduleBytes.length,
        sha256: sha256(context.moduleBytes),
      },
      embeddedLibglfw: {
        archive: relativePosix(paths.root, paths.hapPath),
        entry: context.embeddedPath,
        size: context.embeddedSo.length,
        sha256: sha256(context.embeddedSo),
        ...identityExtra('hapEmbedded'),
      },
      ...(paths.glHostSplit ? {
        cmakeGlHost: fileRecord(paths.root, paths.cmakeGlHostSo),
        stagedGlHost: fileRecord(paths.root, paths.stagedGlHostSo),
        strippedGlHost: fileRecord(paths.root, paths.strippedGlHostSo),
        embeddedGlHost: {
          archive: relativePosix(paths.root, paths.hapPath),
          entry: context.embeddedGlHostPath,
          size: context.embeddedGlHostSo.length,
          sha256: sha256(context.embeddedGlHostSo),
        },
      } : {}),
    },
  };
}

function comparableProvenance(value) {
  const clone = structuredClone(value);
  delete clone.generatedAt;
  return clone;
}

export function provenanceComparisonIssues(recorded, current) {
  const issues = [];
  if (recorded?.schemaVersion !== SCHEMA_VERSION) {
    issues.push(`provenance schemaVersion=${recorded?.schemaVersion}; expected ${SCHEMA_VERSION}`);
  }
  if (!Number.isFinite(Date.parse(recorded?.generatedAt))) {
    issues.push('provenance has an invalid generatedAt timestamp');
  }
  if (JSON.stringify(comparableProvenance(recorded)) !==
      JSON.stringify(comparableProvenance(current))) {
    issues.push('provenance does not match the current source/profile/toolchain/build/HAP evidence');
  }
  return issues;
}

function verifyProvenanceFile(path, current, issues) {
  let recorded;
  try {
    recorded = JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    issues.push(`cannot read provenance ${path}: ${error.message}`);
    return;
  }
  issues.push(...provenanceComparisonIssues(recorded, current.provenance));
}

export function auditRelease(options = {}) {
  const context = validateVariantBinding(options);
  const issues = [];
  const audit = auditCompileAndAbi(context, issues);
  let source;
  let signature = null;
  try {
    source = sourceEvidence(context, options, issues);
  } catch (error) {
    issues.push(`cannot collect source provenance: ${error.message}`);
    source = {};
  }
  const embeddedMgIdentity = source?.mobileglues?.buildIdentity;
  if (embeddedMgIdentity &&
      context.embeddedSo.indexOf(Buffer.from(embeddedMgIdentity, 'utf8')) < 0) {
    issues.push('embedded libglfw.so does not contain the current content-addressed MG build identity');
  }
  if (options.verifySignature) {
    try {
      signature = verifyHapSignature(context.paths);
    } catch (error) {
      issues.push(`HAP signature verification failed: ${error.message}`);
    }
  } else {
    issues.push('build provenance requires --verify-signature');
  }
  const provenance = buildProvenance(context, audit, source, signature, issues, options);
  if (issues.length) throw new ContractError(issues);
  return { ...context, audit, source, provenance };
}

function usage() {
  console.log(`Usage: node scripts/check-mg-build-contract.mjs [options]

Options:
  --root <path>                 superproject root (default: script parent)
  --product <name>             Hvigor product (default: default)
  --target <name>              entry target (default: product)
  --mode release               shipping mode; debug is always rejected
  --abi <name>                 native ABI (default: arm64-v8a)
  --hap-kind signed|unsigned   required, exact HAP output kind
  --hap <path>                 explicit HAP inside the selected output directory
  --write-provenance <path>    write and immediately re-verify JSON evidence
  --verify-provenance <path>   re-verify existing JSON evidence
  --hvigor <path>              explicit hvigorw executable for stable provenance
  --verify-signature           cryptographically verify signed/unsigned artifact kind
  --require-clean              reject a dirty superproject (formal CI/release)
  --allow-dirty-mg             allow content-addressed dirty MG only for diagnostic builds
`);
}

function parseArguments(argv) {
  const options = {};
  const valueOptions = new Map([
    ['--root', 'root'],
    ['--product', 'product'],
    ['--target', 'target'],
    ['--mode', 'mode'],
    ['--abi', 'abi'],
    ['--hap-kind', 'hapKind'],
    ['--hap', 'hapPath'],
    ['--write-provenance', 'writeProvenance'],
    ['--verify-provenance', 'verifyProvenance'],
    ['--hvigor', 'hvigor'],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h') return { help: true };
    if (argument === '--require-clean') {
      options.requireClean = true;
      continue;
    }
    if (argument === '--allow-dirty-mg') {
      options.allowDirtyMg = true;
      continue;
    }
    if (argument === '--verify-signature') {
      options.verifySignature = true;
      continue;
    }
    const key = valueOptions.get(argument);
    if (!key || index + 1 >= argv.length) throw new Error(`unknown or incomplete argument: ${argument}`);
    options[key] = argv[index + 1];
    index += 1;
  }
  if (options.requireClean && options.allowDirtyMg) {
    throw new Error('--require-clean and --allow-dirty-mg are mutually exclusive');
  }
  if (options.writeProvenance && options.verifyProvenance) {
    throw new Error('--write-provenance and --verify-provenance are mutually exclusive');
  }
  return options;
}

function provenancePath(options, result, key) {
  const path = resolve(options[key]);
  const issues = [];
  assertContained(path, result.paths.outputDir, 'provenance', issues);
  if (issues.length) throw new ContractError(issues);
  return path;
}

function main() {
  try {
    const options = parseArguments(process.argv.slice(2));
    if (options.help) {
      usage();
      return;
    }
    if (!options.hapKind) {
      throw new Error(
        'select the actual shipping artifact explicitly with required --hap-kind signed|unsigned',
      );
    }
    const result = auditRelease(options);
    if (options.writeProvenance) {
      const path = provenancePath(options, result, 'writeProvenance');
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, `${JSON.stringify(result.provenance, null, 2)}\n`);
      const verificationIssues = [];
      verifyProvenanceFile(path, result, verificationIssues);
      if (verificationIssues.length) throw new ContractError(verificationIssues);
      console.log(`  provenance: ${path}`);
    } else if (options.verifyProvenance) {
      const path = provenancePath(options, result, 'verifyProvenance');
      const verificationIssues = [];
      verifyProvenanceFile(path, result, verificationIssues);
      if (verificationIssues.length) throw new ContractError(verificationIssues);
      console.log(`  provenance verified: ${path}`);
    }
    console.log('[check-mg-build-contract] PASS');
    console.log('  variant: module.json release/debug=false; profile SDK and product bound');
    console.log('  graph: compile DB + cache + Ninja + unstripped/staged/stripped freshness bound');
    console.log('  ELF: one AArch64 libglfw.so, SONAME/build-id preserved through HAP');
    if (result.provenance.signatureVerification.result !== 'not-requested') {
      console.log(`  signature: ${result.provenance.signatureVerification.result}`);
    }
    console.log(`  embedded sha256: ${sha256(result.embeddedSo)}`);
  } catch (error) {
    const issues = error instanceof ContractError ? error.issues : [error.stack ?? error.message];
    for (const issue of issues) console.error(`[check-mg-build-contract] ERROR: ${issue}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();

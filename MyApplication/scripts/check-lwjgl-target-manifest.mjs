#!/usr/bin/env node
// 离线核对被 AMCL modern 槽位替换的官方 org.lwjgl 依赖；每个被审计客户端均保留
// 独立清单/字节身份。新增 26.4 Snapshot 1 不替换正式 26.3 和已承诺的 pre-1。
// Usage:
//   node scripts/check-lwjgl-target-manifest.mjs
//   node scripts/check-lwjgl-target-manifest.mjs --hap <selected-output.hap>
//   node scripts/check-lwjgl-target-manifest.mjs --target 26.3 --client <official-client.jar>

// 临时夹具及其清理边界统一使用外部宿主测试区，不修改系统 TEMP，也不回退到源码目录。
import { workspaceTempRoot } from './lib/workspace-paths.mjs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { stripComments } from './lib/source-noise.mjs';
import { locateReadelf, runNativeSurfaceCheck } from './check-lwjgl-native-surface.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, '..');
export const LWJGL_COVERAGE_TARGETS = ['26.3', '26.3-pre-1', '26.4-snapshot-1'];
const POLICY_PATH = join(ROOT, 'prebuilt', 'lwjgl3', 'target-manifest-coverage.json');
const MODERN_MANIFEST_PATH = join(ROOT, 'prebuilt', 'lwjgl3', 'modern-slot.manifest.json');
const STATES = new Set(['provided', 'intentional-fallback', 'unsupported']);
const UNSUPPORTED_POLICY = 'build-blocking-until-precise-prelaunch-contract';
const HAP_MODERN_JAR_DIR = 'resources/rawfile/lwjgl';
const HAP_NATIVE_DIR = 'libs/arm64-v8a';

function digest(algorithm, input) {
  return createHash(algorithm).update(input).digest('hex');
}

export function metadataPayload(text) {
  if (text.endsWith('\r\n')) return text.slice(0, -2);
  if (text.endsWith('\n')) return text.slice(0, -1);
  return text;
}

export function metadataSha1(text) {
  return digest('sha1', Buffer.from(metadataPayload(text), 'utf8'));
}

function parseJson(text, label, problems) {
  try {
    return JSON.parse(text);
  } catch (error) {
    problems.push(`${label} is not valid JSON: ${error.message}`);
    return null;
  }
}

function sortedUnique(values, label, problems) {
  if (!Array.isArray(values) || values.some((value) => typeof value !== 'string' || value.length === 0)) {
    problems.push(`${label} must be an array of non-empty strings`);
    return [];
  }
  const sorted = [...values].sort();
  if (new Set(sorted).size !== sorted.length) problems.push(`${label} contains duplicates`);
  return sorted;
}

function sameList(actual, expected, label, problems) {
  if (actual.join('|') !== expected.join('|')) {
    problems.push(`${label} mismatch: expected=${expected.join(',')} actual=${actual.join(',')}`);
  }
}

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function resolveRepositoryPath(root, repositoryPath, label, problems) {
  if (typeof repositoryPath !== 'string' || repositoryPath.length === 0) {
    problems.push(`${label} must be a non-empty repository-relative path`);
    return null;
  }
  const rootPath = resolve(root);
  const path = resolve(rootPath, ...repositoryPath.split('/'));
  const rel = relative(rootPath, path);
  if (rel.length === 0 || rel.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) ||
      rel === '..' || isAbsolute(rel)) {
    problems.push(`${label} escapes the repository: ${repositoryPath}`);
    return null;
  }
  return path;
}

function validLockedArtifact(item, label, problems) {
  if (!item || !Number.isSafeInteger(item.size) || item.size <= 0 ||
      typeof item.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(item.sha256)) {
    problems.push(`${label} must lock a positive size and lowercase SHA-256`);
    return false;
  }
  return true;
}

function verifyLockedBytes(bytes, item, label, problems) {
  if (!validLockedArtifact(item, label, problems)) return;
  if (bytes.length !== item.size) {
    problems.push(`${label} size mismatch: expected=${item.size} actual=${bytes.length}`);
  }
  const actualSha256 = digest('sha256', bytes);
  if (actualSha256 !== item.sha256) {
    problems.push(`${label} SHA-256 mismatch: expected=${item.sha256} actual=${actualSha256}`);
  }
}

function verifyLockedFile(path, item, label, problems) {
  if (!validLockedArtifact(item, label, problems)) return null;
  if (!existsSync(path)) {
    problems.push(`${label} is missing: ${path}`);
    return null;
  }
  const bytes = readFileSync(path);
  verifyLockedBytes(bytes, item, label, problems);
  return bytes;
}

function verifyAarch64Elf(bytes, label, problems) {
  if (!bytes || bytes.length < 64 || bytes[0] !== 0x7f || bytes[1] !== 0x45 ||
      bytes[2] !== 0x4c || bytes[3] !== 0x46) {
    problems.push(`${label} is not an ELF artifact`);
    return;
  }
  if (bytes[4] !== 2 || bytes[5] !== 1 || bytes.readUInt16LE(16) !== 3 ||
      bytes.readUInt16LE(18) !== 183) {
    problems.push(`${label} must be little-endian ELF64 ET_DYN for AArch64`);
  }
}

function parseDynamicSymbols(symbolsText) {
  const symbols = [];
  for (const rawLine of String(symbolsText).split(/\r?\n/)) {
    const fields = rawLine.trim().split(/\s+/);
    if (fields.length < 8 || !/^\d+:$/.test(fields[0])) continue;
    symbols.push({
      type: fields[3],
      bind: fields[4],
      visibility: fields[5],
      section: fields[6],
      name: fields[7].split('@', 1)[0],
    });
  }
  return symbols;
}

/**
 * Validate real readelf output for a HAP-native provider. Keeping this parser
 * pure lets the self-test distinguish a defined export from an UND entry or an
 * unrelated byte string without needing a host-native OHOS fixture DSO.
 */
export function verifyReadelfDefinedExports(
  inspection, requiredSymbols, label, problems = [],
) {
  if (!inspection || typeof inspection.headerText !== 'string' ||
      typeof inspection.dynamicText !== 'string' ||
      typeof inspection.symbolsText !== 'string') {
    problems.push(`${label}: readelf inspection is incomplete`);
    return { needed: [] };
  }
  const header = inspection.headerText;
  if (!/Class:\s+ELF64\b/.test(header) ||
      !/Data:\s+2's complement, little endian\b/.test(header) ||
      !/Type:\s+DYN\b/.test(header) ||
      !/Machine:\s+AArch64\b/.test(header)) {
    problems.push(`${label}: readelf header must describe little-endian ELF64 ET_DYN for AArch64`);
  }
  const dynamic = inspection.dynamicText;
  if (!/Dynamic section\b/.test(dynamic)) {
    problems.push(`${label}: readelf found no dynamic section`);
  }
  const needed = [...dynamic.matchAll(/Shared library: \[([^\]]+)\]/g)]
    .map((match) => match[1]);
  const symbolsText = inspection.symbolsText;
  if (!/Symbol table ['"]?\.dynsym['"]?/.test(symbolsText)) {
    problems.push(`${label}: readelf found no dynamic symbol table`);
  }
  const symbols = parseDynamicSymbols(symbolsText);
  for (const required of requiredSymbols) {
    const definedExport = symbols.some((symbol) =>
      symbol.name === required &&
      (symbol.type === 'FUNC' || symbol.type === 'IFUNC') &&
      (symbol.bind === 'GLOBAL' || symbol.bind === 'WEAK') &&
      (symbol.visibility === 'DEFAULT' || symbol.visibility === 'PROTECTED') &&
      symbol.section !== 'UND');
    if (!definedExport) {
      problems.push(`${label}: required symbol ${required} is not a defined GLOBAL/WEAK dynamic export`);
    }
  }
  return { needed };
}

function inspectElfFile(readelf, path) {
  return {
    headerText: execFileSync(readelf, ['-h', path], { encoding: 'utf8' }),
    dynamicText: execFileSync(readelf, ['-d', path], { encoding: 'utf8' }),
    symbolsText: execFileSync(readelf, ['--dyn-syms', '--wide', path], { encoding: 'utf8' }),
  };
}

let cachedReadelf = '';
const fileInspectionCache = new Map();

function inspectRepositoryElf(path, label, problems) {
  if (fileInspectionCache.has(path)) return fileInspectionCache.get(path);
  try {
    if (!cachedReadelf) cachedReadelf = locateReadelf();
    const inspection = inspectElfFile(cachedReadelf, path);
    fileInspectionCache.set(path, inspection);
    return inspection;
  } catch (error) {
    problems.push(`${label}: readelf inspection failed: ${error.message}`);
    return null;
  }
}

function validateRequiredSymbols(native, module, problems) {
  if (!Array.isArray(native.requiredSymbols) || native.requiredSymbols.length === 0 ||
      native.requiredSymbols.some((symbol) => typeof symbol !== 'string' || symbol.length === 0)) {
    problems.push(`${module}: native provider requiredSymbols must be a non-empty string array`);
    return false;
  }
  if (new Set(native.requiredSymbols).size !== native.requiredSymbols.length) {
    problems.push(`${module}: native provider requiredSymbols contains duplicates`);
    return false;
  }
  return true;
}

function verifyAuditedTarget(policy, descriptor, problems) {
  if (policy.unsupportedStatePolicy !== UNSUPPORTED_POLICY) {
    problems.push(`coverage policy unsupportedStatePolicy must be ${UNSUPPORTED_POLICY}`);
  }
  if (!Array.isArray(policy.auditedTargets)) {
    problems.push('coverage policy auditedTargets must be an array');
    return;
  }
  const byVersion = new Map();
  for (const target of policy.auditedTargets) {
    if (!target || typeof target.versionId !== 'string' || target.versionId.length === 0) {
      problems.push('coverage policy contains an audited target without versionId');
      continue;
    }
    if (byVersion.has(target.versionId)) {
      problems.push(`coverage policy duplicates audited target ${target.versionId}`);
    }
    byVersion.set(target.versionId, target);
    if (!/^[0-9a-f]{40}$/.test(target.metadataSha1 || '')) {
      problems.push(`${target.versionId}: audited metadataSha1 is malformed`);
    }
    if (!/^[0-9a-f]{40}$/.test(target.clientSha1 || '')) {
      problems.push(`${target.versionId}: audited clientSha1 is malformed`);
    }
    if (!/^[0-9a-f]{64}$/.test(target.classSha256 || '')) {
      problems.push(`${target.versionId}: audited bootstrap classSha256 is malformed`);
    }
    sortedUnique(target.eagerNativeModules,
      `${target.versionId}: audited eagerNativeModules`, problems);
  }
  const audited = byVersion.get(descriptor.versionId);
  if (!audited) {
    problems.push(`target ${descriptor.versionId} has no independent auditedTargets identity`);
    return;
  }
  if (descriptor.metadataSha1 !== audited.metadataSha1) {
    problems.push(`${descriptor.versionId}: descriptor metadataSha1 does not match audited target`);
  }
  if (descriptor.clientSha1 !== audited.clientSha1) {
    problems.push(`${descriptor.versionId}: descriptor clientSha1 does not match audited target`);
  }
  if (descriptor.clientBootstrap?.classSha256 !== audited.classSha256) {
    problems.push(`${descriptor.versionId}: descriptor bootstrap classSha256 does not match audited target`);
  }
  const descriptorEager = sortedUnique(descriptor.clientBootstrap?.eagerNativeModules,
    `${descriptor.versionId}: descriptor eagerNativeModules`, problems);
  const auditedEager = sortedUnique(audited.eagerNativeModules,
    `${descriptor.versionId}: audited eagerNativeModules`, problems);
  sameList(descriptorEager, auditedEager,
    `${descriptor.versionId}: descriptor/audited eagerNativeModules`, problems);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function validateLibraryRule(rule, label, problems) {
  if (!rule || typeof rule !== 'object') {
    problems.push(`${label}: rule must be an object`);
    return false;
  }
  const knownRuleKeys = new Set(['action', 'os', 'features']);
  const unknownRuleKeys = Object.keys(rule).filter((key) => !knownRuleKeys.has(key));
  if (unknownRuleKeys.length > 0) {
    problems.push(`${label}: unsupported rule keys ${unknownRuleKeys.join(',')}`);
    return false;
  }
  if (hasOwn(rule, 'features')) {
    problems.push(`${label}: feature-dependent LWJGL rule is unsupported by this offline gate`);
    return false;
  }
  if (!hasOwn(rule, 'os')) return true;
  if (!rule.os || typeof rule.os !== 'object' || Array.isArray(rule.os)) {
    problems.push(`${label}: rule.os must be an object`);
    return false;
  }
  const knownOsKeys = new Set(['name', 'arch', 'version']);
  const unknownOsKeys = Object.keys(rule.os).filter((key) => !knownOsKeys.has(key));
  if (unknownOsKeys.length > 0) {
    problems.push(`${label}: unsupported rule.os keys ${unknownOsKeys.join(',')}`);
    return false;
  }
  // The shipping VersionParser/McDownloader library-rule path currently evaluates
  // only os.name. Do not model arch/version/features here and silently certify a
  // different effective set; a target using those conditions stops the build.
  if (hasOwn(rule.os, 'arch')) {
    problems.push(`${label}: rule.os.arch is unsupported by the shipping library-rule path`);
    return false;
  }
  if (hasOwn(rule.os, 'version')) {
    problems.push(`${label}: rule.os.version is unsupported by the shipping library-rule path`);
    return false;
  }
  if (hasOwn(rule.os, 'name') &&
      (typeof rule.os.name !== 'string' || rule.os.name.length === 0)) {
    problems.push(`${label}: rule.os.name must be a non-empty string`);
    return false;
  }
  return true;
}

// Mechanical mirror of VersionParser.checkLibraryRules. Do not "simplify" this
// into Mojang's canonical last-match algorithm: the gate must certify the code
// that AMCL actually ships, including its current matching-disallow veto.
function evaluateVersionParserLibraryRules(rules, osName) {
  if (rules.length === 0) return true;
  let dominated = false;
  let dominatedByAllow = false;
  for (const rule of rules) {
    if (rule.os && rule.os.name) {
      const osMatch = rule.os.name === osName;
      if (rule.action === 'allow') {
        if (osMatch) dominatedByAllow = true;
        dominated = true;
      } else if (rule.action === 'disallow' && osMatch) {
        return false;
      }
    } else {
      if (rule.action === 'allow') dominatedByAllow = true;
      dominated = true;
    }
  }
  return dominated ? dominatedByAllow : true;
}

// Mechanical mirror of McDownloader.filterLibraries (excluding its unrelated
// java-objc-bridge special case; this gate only receives org.lwjgl entries).
function evaluateMcDownloaderLibraryRules(rules, osName) {
  let dominatedAllow = false;
  let dominatedDisallow = false;
  for (const rule of rules) {
    if (rule.action === 'allow') {
      if (!rule.os || rule.os.name === osName) dominatedAllow = true;
    } else if (rule.action === 'disallow') {
      if (rule.os && rule.os.name === osName) dominatedDisallow = true;
    }
  }
  return dominatedAllow && !dominatedDisallow;
}

export function isLibraryAllowed(library, environment, label, problems) {
  if (library.rules === undefined) return true;
  if (!Array.isArray(library.rules)) {
    problems.push(`${label}: rules must be an array`);
    return false;
  }
  if (!environment || environment.os !== 'linux') {
    problems.push(`${label}: shipping library rule environment must be linux`);
    return false;
  }
  const before = problems.length;
  for (const rule of library.rules) {
    if (rule.action !== 'allow' && rule.action !== 'disallow') {
      problems.push(`${label}: unknown rule action ${String(rule.action)}`);
      continue;
    }
    validateLibraryRule(rule, label, problems);
  }
  if (problems.length !== before) return false;

  const parserAllowed = evaluateVersionParserLibraryRules(library.rules, environment.os);
  const downloaderAllowed = evaluateMcDownloaderLibraryRules(library.rules, environment.os);
  if (parserAllowed !== downloaderAllowed) {
    problems.push(`${label}: shipping rule evaluators disagree `
      + `(VersionParser=${parserAllowed}, McDownloader=${downloaderAllowed})`);
    return false;
  }
  return parserAllowed;
}

function parseCoordinate(name, label, problems) {
  if (typeof name !== 'string') {
    problems.push(`${label}: library name must be a string`);
    return null;
  }
  const parts = name.split(':');
  if (parts.length !== 3 && parts.length !== 4) {
    problems.push(`${label}: unsupported Maven coordinate ${name}`);
    return null;
  }
  const [group, artifact, version, classifier = ''] = parts;
  if (group !== 'org.lwjgl' || !artifact.startsWith('lwjgl') || !version) {
    problems.push(`${label}: invalid org.lwjgl coordinate ${name}`);
    return null;
  }
  if (classifier && !classifier.startsWith('natives-')) {
    problems.push(`${label}: unsupported LWJGL classifier ${classifier}`);
    return null;
  }
  return { artifact, version, classifier };
}

function effectiveModules(metadata, descriptor, problems) {
  if (!Array.isArray(metadata.libraries)) {
    problems.push('target metadata libraries must be an array');
    return { entries: [], javaModules: [], nativeModules: [] };
  }
  const environment = descriptor.ruleEnvironment || {};
  for (const key of ['os', 'arch', 'version']) {
    if (typeof environment[key] !== 'string' || environment[key].length === 0) {
      problems.push(`descriptor ruleEnvironment.${key} must be a non-empty string`);
    }
  }
  const entries = [];
  metadata.libraries.forEach((library, index) => {
    if (typeof library?.name !== 'string' || !library.name.startsWith('org.lwjgl:')) return;
    const label = `libraries[${index}] ${library.name}`;
    const coordinate = parseCoordinate(library.name, label, problems);
    if (!coordinate || !isLibraryAllowed(library, environment, label, problems)) return;
    const artifact = library.downloads?.artifact;
    if (!artifact || typeof artifact.path !== 'string' || !/^[0-9a-f]{40}$/.test(artifact.sha1 || '')) {
      problems.push(`${label}: downloads.artifact path/SHA-1 is missing or malformed`);
      return;
    }
    entries.push({ ...coordinate, name: library.name });
  });

  const byModule = new Map();
  for (const entry of entries) {
    if (!byModule.has(entry.artifact)) byModule.set(entry.artifact, { java: [], native: [] });
    byModule.get(entry.artifact)[entry.classifier ? 'native' : 'java'].push(entry);
  }
  for (const [module, value] of byModule) {
    if (value.java.length !== 1) {
      problems.push(`${descriptor.versionId}: ${module} must have exactly one effective Java artifact (actual=${value.java.length})`);
    }
    if (value.native.length > 1) {
      problems.push(`${descriptor.versionId}: ${module} has multiple effective native artifacts`);
    }
  }
  return {
    entries,
    javaModules: [...byModule].filter(([, value]) => value.java.length > 0).map(([name]) => name).sort(),
    nativeModules: [...byModule].filter(([, value]) => value.native.length > 0).map(([name]) => name).sort(),
  };
}

function verifyLibraryNameContract(root, contract, module, problems) {
  if (!contract || typeof contract.source !== 'string' || typeof contract.key !== 'string' ||
      typeof contract.value !== 'string') {
    problems.push(`${module}: malformed libraryName contract`);
    return;
  }
  const path = resolveRepositoryPath(root, contract.source, `${module}: libraryName source`, problems);
  if (!path) return;
  if (!existsSync(path)) {
    problems.push(`${module}: libraryName source is missing: ${contract.source}`);
    return;
  }
  if (!hasBootstrapLibraryName(readFileSync(path, 'utf8'), contract.key, contract.value)) {
    problems.push(`${module}: active library-name route ${contract.key}=${contract.value} is missing`);
  }
}

/**
 * 核对 JVM 创建前的属性表，不再要求晚置 setSystemProperty（其时 LWJGL/agent 已可能
 * 缓存错误值）。仅接受 RuntimeBootstrapProperties 的 result 初始化表内精确键值对；
 * 注释、别的函数或仅出现一个相同字符串均不能满足这个来源契约。冻结与创建顺序
 * 由运行时 bootstrap 的行为测试负责，本门禁只证明 provider 路由表确实包含该值。
 */
export function hasBootstrapLibraryName(source, key, value) {
  const code = stripComments(source, { lang: 'c' });
  const body = /\bRuntimeBootstrapProperties\s*\([^)]*\)\s*\{\s*std::vector<BootstrapProperty>\s+result\s*\{([\s\S]*?)\n\s*\};/.exec(code);
  if (!body) return false;
  const pair = new RegExp(`\\{\\s*"${escapeRegExp(key)}"\\s*,\\s*"${escapeRegExp(value)}"\\s*\\}`);
  return pair.test(body[1]);
}

function activeCmakeText(text) {
  return text.split(/\r?\n/).map((line) => line.replace(/#.*$/, '')).join('\n');
}

function uniqueManifestItem(items, name, label, problems) {
  if (!Array.isArray(items)) {
    problems.push(`${label} manifest list is missing`);
    return null;
  }
  const matches = items.filter((candidate) => candidate?.name === name);
  if (matches.length !== 1) {
    problems.push(`${label} must appear exactly once in modern-slot.manifest.json (actual=${matches.length})`);
    return null;
  }
  return matches[0];
}

function verifyModernJarProvider(root, module, modernManifest, problems) {
  const jarName = `${module}.jar`;
  const item = uniqueManifestItem(modernManifest.jars, jarName, `${module}: ${jarName}`, problems);
  if (!item) return;
  const prebuiltPath = join(root, 'prebuilt', 'lwjgl3', 'jars', jarName);
  const rawfilePath = join(root, 'entry', 'src', 'main', 'resources', 'rawfile', 'lwjgl', jarName);
  verifyLockedFile(prebuiltPath, item, `${module}: prebuilt ${jarName}`, problems);
  verifyLockedFile(rawfilePath, item, `${module}: shipping rawfile ${jarName}`, problems);
}

function verifyModernNativeProvider(root, module, native, modernManifest, problems) {
  if (typeof native.artifact !== 'string' || !/^lib[^/\\]+\.so$/.test(native.artifact)) {
    problems.push(`${module}: modern-slot native artifact must be a plain lib*.so name`);
    return;
  }
  const item = uniqueManifestItem(modernManifest.natives, native.artifact,
    `${module}: ${native.artifact}`, problems);
  if (!item) return;
  const path = join(root, 'entry', 'libs', 'arm64-v8a', native.artifact);
  const bytes = verifyLockedFile(path, item, `${module}: modern native ${native.artifact}`, problems);
  if (bytes) verifyAarch64Elf(bytes, `${module}: modern native ${native.artifact}`, problems);
}

function verifyNativeProvider(root, module, native, modernManifest, problems) {
  if (!native || typeof native !== 'object' || Array.isArray(native)) {
    problems.push(`${module}: provided native module has no concrete provider`);
    return;
  }
  if (native.kind === 'modern-slot') {
    verifyModernNativeProvider(root, module, native, modernManifest, problems);
  } else if (native.kind === 'bundle-file') {
    const symbolsValid = validateRequiredSymbols(native, module, problems);
    if (typeof native.artifact !== 'string' ||
        !/^entry\/libs\/arm64-v8a\/lib[^/]+\.so$/.test(native.artifact)) {
      problems.push(`${module}: bundle-file artifact must be entry/libs/arm64-v8a/lib*.so`);
      return;
    }
    const path = resolveRepositoryPath(root, native.artifact, `${module}: bundle-file artifact`, problems);
    const bytes = path
      ? verifyLockedFile(path, native, `${module}: bundle native ${native.artifact}`, problems)
      : null;
    if (bytes) {
      verifyAarch64Elf(bytes, `${module}: bundle native ${native.artifact}`, problems);
      if (symbolsValid) {
        const label = `${module}: bundle native ${native.artifact}`;
        const inspection = inspectRepositoryElf(path, label, problems);
        if (inspection) verifyReadelfDefinedExports(
          inspection, native.requiredSymbols, label, problems);
      }
    }
    if (!native.libraryName) {
      problems.push(`${module}: bundle-file provider requires a libraryName route`);
    } else {
      verifyLibraryNameContract(root, native.libraryName, module, problems);
    }
  } else if (native.kind === 'cmake-output') {
    validateRequiredSymbols(native, module, problems);
    const suffix = module === 'lwjgl' ? 'lwjgl' : module.replace(/^lwjgl-/, '');
    const expectedArtifact = `lib${suffix}.so`;
    if (native.artifact !== expectedArtifact) {
      problems.push(`${module}: cmake-output artifact must be ${expectedArtifact}`);
    }
    if (!Array.isArray(native.contracts) || native.contracts.length === 0) {
      problems.push(`${module}: cmake-output provider has no build contracts`);
      return;
    }
    for (const contract of native.contracts) {
      if (!contract || typeof contract.source !== 'string' || contract.source.length === 0 ||
          typeof contract.contains !== 'string' || contract.contains.length === 0) {
        problems.push(`${module}: malformed CMake output contract`);
        continue;
      }
      const path = resolveRepositoryPath(root, contract.source, `${module}: CMake contract source`, problems);
      if (!path || !existsSync(path) || !activeCmakeText(readFileSync(path, 'utf8')).includes(contract.contains)) {
        problems.push(`${module}: active CMake contract is missing: ${contract.source} -> ${contract.contains}`);
      }
    }
  } else {
    problems.push(`${module}: unknown native provider kind ${String(native.kind)}`);
  }
}

export function validateFallbackEvidence(evidence, module, problems) {
  const before = problems.length;
  if (!evidence || typeof evidence !== 'object' || Array.isArray(evidence) ||
      evidence.schema !== 1 || evidence.module !== module) {
    problems.push(`${module}: fallback evidence schema/module mismatch`);
    return false;
  }
  if (evidence.omittedJar !== `${module}.jar`) {
    problems.push(`${module}: fallback evidence omittedJar must be ${module}.jar`);
  }
  if (typeof evidence.coreJar !== 'string' || !/^[^/\\]+\.jar$/.test(evidence.coreJar)) {
    problems.push(`${module}: fallback evidence coreJar must be a plain JAR name`);
  }
  if (typeof evidence.classEntry !== 'string' || evidence.classEntry.startsWith('/') ||
      evidence.classEntry.includes('..') || !evidence.classEntry.endsWith('.class')) {
    problems.push(`${module}: fallback evidence classEntry must name a class file`);
  }
  if (!/^[0-9a-f]{64}$/.test(evidence.classSha256 || '')) {
    problems.push(`${module}: fallback evidence classSha256 is malformed`);
  }
  if (!Array.isArray(evidence.requiredClassConstants) || evidence.requiredClassConstants.length === 0 ||
      evidence.requiredClassConstants.some((value) => typeof value !== 'string' || value.length === 0)) {
    problems.push(`${module}: fallback evidence requiredClassConstants must be a non-empty string array`);
  } else if (new Set(evidence.requiredClassConstants).size !== evidence.requiredClassConstants.length) {
    problems.push(`${module}: fallback evidence requiredClassConstants contains duplicates`);
  }
  if (typeof evidence.absentClassEntry !== 'string' || evidence.absentClassEntry.startsWith('/') ||
      evidence.absentClassEntry.includes('..') || !evidence.absentClassEntry.endsWith('.class') ||
      evidence.absentClassEntry === evidence.classEntry) {
    problems.push(`${module}: fallback evidence absentClassEntry must name a distinct class file`);
  }
  return problems.length === before;
}

function verifyFallback(root, module, entry, modernManifest, problems) {
  if (typeof entry.reason !== 'string' || entry.reason.trim().length === 0 ||
      typeof entry.evidence !== 'string' || entry.evidence.length === 0) {
    problems.push(`${module}: intentional-fallback requires a reason and frozen evidence fixture`);
    return;
  }
  const evidencePath = resolveRepositoryPath(root, entry.evidence,
    `${module}: fallback evidence path`, problems);
  if (!evidencePath) return;
  if (!existsSync(evidencePath)) {
    problems.push(`${module}: fallback evidence fixture is missing: ${entry.evidence}`);
    return;
  }
  const evidence = parseJson(readFileSync(evidencePath, 'utf8'), entry.evidence, problems);
  if (!evidence) return;
  if (!validateFallbackEvidence(evidence, module, problems)) return;
  const jars = new Set((modernManifest.jars || []).map((jar) => jar.name));
  if (jars.has(evidence.omittedJar)) {
    problems.push(`${module}: ${evidence.omittedJar} must stay absent for the audited fallback`);
  }
  if (!jars.has(evidence.coreJar)) {
    problems.push(`${module}: fallback evidence core JAR is not in the modern slot: ${evidence.coreJar}`);
    return;
  }
  const corePath = join(root, 'prebuilt', 'lwjgl3', 'jars', evidence.coreJar);
  if (!existsSync(corePath)) {
    problems.push(`${module}: fallback evidence core JAR is missing: ${corePath}`);
    return;
  }
  let classBytes;
  try {
    classBytes = readUniqueZipEntry(readFileSync(corePath), evidence.classEntry);
  } catch (error) {
    problems.push(`${module}: cannot read audited fallback class: ${error.message}`);
    return;
  }
  if (digest('sha256', classBytes) !== evidence.classSha256) {
    problems.push(`${module}: audited fallback class object changed; re-audit before updating the fixture`);
  }
  for (const constant of evidence.requiredClassConstants || []) {
    if (!classBytes.includes(Buffer.from(constant, 'utf8'))) {
      problems.push(`${module}: audited fallback class is missing constant ${constant}`);
    }
  }
  try {
    readUniqueZipEntry(readFileSync(corePath), evidence.absentClassEntry);
    problems.push(`${module}: allocator implementation unexpectedly exists in the core JAR`);
  } catch (error) {
    const expectedMissing = `ZIP entry ${evidence.absentClassEntry} must appear exactly once (actual=0)`;
    if (!String(error.message).includes(expectedMissing)) {
      problems.push(`${module}: could not prove allocator class absence: ${error.message}`);
    }
  }
}

function readRequiredHapEntry(hapBytes, entryName, label, problems) {
  try {
    return readUniqueZipEntry(hapBytes, entryName);
  } catch (error) {
    problems.push(`${label}: required HAP entry ${entryName} is missing or invalid: ${error.message}`);
    return null;
  }
}

/**
 * Product-mode half of the coverage contract. Source declarations are not enough:
 * the selected HAP must contain the exact modern JAR/native bytes and every native
 * provider that the target policy relies on.
 */
export function verifyHapArtifacts(hapBytes, policy, modernManifest, problems = []) {
  if (!Buffer.isBuffer(hapBytes) && !(hapBytes instanceof Uint8Array)) {
    problems.push('HAP verification requires archive bytes');
    return problems;
  }
  if (!Array.isArray(modernManifest?.jars) || !Array.isArray(modernManifest?.natives)) {
    problems.push('HAP verification requires modern-slot JAR/native manifests');
    return problems;
  }

  for (const jar of modernManifest.jars) {
    if (typeof jar?.name !== 'string' || !/^[^/\\]+\.jar$/.test(jar.name)) {
      problems.push(`modern-slot manifest has invalid JAR name ${String(jar?.name)}`);
      continue;
    }
    const entryName = `${HAP_MODERN_JAR_DIR}/${jar.name}`;
    const bytes = readRequiredHapEntry(hapBytes, entryName, `modern JAR ${jar.name}`, problems);
    if (bytes) verifyLockedBytes(bytes, jar, `HAP ${entryName}`, problems);
  }

  for (const native of modernManifest.natives) {
    if (typeof native?.name !== 'string' || !/^lib[^/\\]+\.so$/.test(native.name)) {
      problems.push(`modern-slot manifest has invalid native name ${String(native?.name)}`);
      continue;
    }
    const entryName = `${HAP_NATIVE_DIR}/${native.name}`;
    const bytes = readRequiredHapEntry(hapBytes, entryName,
      `modern native ${native.name}`, problems);
    if (bytes) {
      // Hvigor strips native DSOs while packaging, so source size/SHA cannot be
      // compared with HAP bytes. Architecture plus the full JNI/NEEDED audit below
      // are the product-level identity.
      verifyAarch64Elf(bytes, `HAP ${entryName}`, problems);
    }
  }

  if (!Array.isArray(policy?.modules)) {
    problems.push('HAP verification requires coverage policy modules');
    return problems;
  }
  const checkedNativeEntries = new Set(modernManifest.natives.map((native) =>
    `${HAP_NATIVE_DIR}/${native.name}`));
  for (const entry of policy.modules) {
    if (entry?.state !== 'provided' || !entry.native ||
        (entry.native.kind !== 'bundle-file' && entry.native.kind !== 'cmake-output')) continue;
    if (typeof entry.native.artifact !== 'string' || entry.native.artifact.length === 0) {
      problems.push(`${String(entry?.name)}: HAP native provider has no artifact name`);
      continue;
    }
    const entryName = `${HAP_NATIVE_DIR}/${basename(entry.native.artifact)}`;
    if (checkedNativeEntries.has(entryName)) continue;
    checkedNativeEntries.add(entryName);
    const bytes = readRequiredHapEntry(hapBytes, entryName,
      `${entry.name}: ${entry.native.kind} provider`, problems);
    if (!bytes) continue;
    validateRequiredSymbols(entry.native, entry.name, problems);
    verifyAarch64Elf(bytes, `HAP ${entryName}`, problems);
  }
  return problems;
}

/**
 * Product-level proof for bundle-file/cmake-output providers. Hvigor may strip
 * these DSOs, so source hashes cannot bind the packaged bytes; readelf must
 * successfully parse the packaged ELF and find each required function as a
 * defined dynamic export. NEEDED is reported but deliberately not allowlisted
 * here because these external providers have different, already-shipping
 * dependency sets.
 */
export function verifyHapProviderNativeSurfaces(
  hapBytes, policy, problems = [], { inspectReadelf } = {},
) {
  if (!Array.isArray(policy?.modules)) return problems;
  const providers = policy.modules.filter((entry) =>
    entry?.state === 'provided' && entry.native &&
    (entry.native.kind === 'bundle-file' || entry.native.kind === 'cmake-output'));
  let tempPath = '';
  let readelf = '';
  const tempBase = resolve(workspaceTempRoot());
  try {
    if (typeof inspectReadelf !== 'function') {
      tempPath = mkdtempSync(join(tempBase, 'amcl-lwjgl-provider-hap-'));
      readelf = locateReadelf();
    }
    for (const entry of providers) {
      if (!validateRequiredSymbols(entry.native, entry.name, problems)) continue;
      const artifact = basename(String(entry.native.artifact || ''));
      if (!/^lib[^/\\]+\.so$/.test(artifact)) continue;
      const entryName = `${HAP_NATIVE_DIR}/${artifact}`;
      let bytes;
      try {
        bytes = readUniqueZipEntry(hapBytes, entryName);
      } catch {
        // verifyHapArtifacts owns the precise missing/duplicate-entry diagnostic.
        continue;
      }
      const label = `HAP ${entryName}`;
      let inspection;
      try {
        if (typeof inspectReadelf === 'function') {
          inspection = inspectReadelf({ bytes, entryName, module: entry.name });
        } else {
          const path = join(tempPath, artifact);
          writeFileSync(path, bytes);
          inspection = inspectElfFile(readelf, path);
        }
      } catch (error) {
        problems.push(`${label}: readelf inspection failed: ${error.message}`);
        continue;
      }
      const beforeInspection = problems.length;
      const report = verifyReadelfDefinedExports(
        inspection, entry.native.requiredSymbols, label, problems);
      if (typeof inspectReadelf !== 'function' && problems.length === beforeInspection) {
        console.log(`[lwjgl-target-manifest] HAP provider ${artifact} OK: ` +
          `NEEDED=${report.needed.join(',') || '(none)'}`);
      }
    }
  } finally {
    if (tempPath) {
      const rel = relative(tempBase, resolve(tempPath));
      if (rel.length > 0 && rel !== '..' &&
          !rel.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) &&
          !isAbsolute(rel) && basename(tempPath).startsWith('amcl-lwjgl-provider-hap-')) {
        rmSync(tempPath, { recursive: true, force: true });
      } else {
        problems.push(`refusing to remove unsafe HAP provider temp path: ${tempPath}`);
      }
    }
  }
  return problems;
}

function verifyHapModernNativeSurface(hapBytes, modernManifest, problems) {
  if (!Array.isArray(modernManifest?.natives)) return;
  const tempBase = resolve(workspaceTempRoot());
  const tempPath = mkdtempSync(join(tempBase, 'amcl-lwjgl-hap-'));
  let complete = true;
  try {
    for (const native of modernManifest.natives) {
      if (typeof native?.name !== 'string' || !/^lib[^/\\]+\.so$/.test(native.name)) {
        complete = false;
        continue;
      }
      try {
        const bytes = readUniqueZipEntry(hapBytes, `${HAP_NATIVE_DIR}/${native.name}`);
        writeFileSync(join(tempPath, native.name), bytes);
      } catch {
        // verifyHapArtifacts already emits the precise missing/duplicate entry.
        complete = false;
      }
    }
    if (complete) {
      try {
        runNativeSurfaceCheck({ output: tempPath });
      } catch (error) {
        problems.push(`HAP modern native surface audit failed: ${error.message}`);
      }
    }
  } finally {
    const rel = relative(tempBase, resolve(tempPath));
    if (rel.length > 0 && rel !== '..' && !rel.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) &&
        !isAbsolute(rel) && basename(tempPath).startsWith('amcl-lwjgl-hap-')) {
      rmSync(tempPath, { recursive: true, force: true });
    } else {
      problems.push(`refusing to remove unsafe HAP native temp path: ${tempPath}`);
    }
  }
}

export function analyzeLwjglTargetManifestCoverage({
  root = ROOT,
  metadataText,
  descriptor,
  policy,
  modernManifest,
  hapBytes,
  clientBytes,
} = {}) {
  const problems = [];
  if (!descriptor || descriptor.schema !== 1) problems.push('unsupported target coverage descriptor schema');
  if (!policy || policy.schema !== 1 || policy.slot !== 'modern') problems.push('unsupported target coverage policy schema');
  if (!modernManifest || modernManifest.schema !== 1 || modernManifest.slot !== 'modern') {
    problems.push('unsupported modern-slot manifest schema');
  }
  const metadata = typeof metadataText === 'string'
    ? parseJson(metadataPayload(metadataText), 'target metadata fixture', problems)
    : null;
  if (!metadata || !descriptor || !policy || !modernManifest) return { ok: false, problems };

  verifyAuditedTarget(policy, descriptor, problems);

  if (metadataSha1(metadataText) !== descriptor.metadataSha1) {
    problems.push(`target metadata SHA-1 mismatch: expected=${descriptor.metadataSha1} actual=${metadataSha1(metadataText)}`);
  }
  if (metadata.id !== descriptor.versionId) {
    problems.push(`target version mismatch: descriptor=${descriptor.versionId} metadata=${String(metadata.id)}`);
  }
  const clientSha1 = metadata.downloads?.client?.sha1;
  if (clientSha1 !== descriptor.clientSha1) {
    problems.push(`target client SHA-1 mismatch: descriptor=${descriptor.clientSha1} metadata=${String(clientSha1)}`);
  }
  if (!descriptor.clientBootstrap || !/^[0-9a-f]{64}$/.test(descriptor.clientBootstrap.classSha256 || '')) {
    problems.push('descriptor clientBootstrap class object is missing or malformed');
  }
  if (clientBytes !== undefined) verifyTargetClient(clientBytes, descriptor, problems);

  const effective = effectiveModules(metadata, descriptor, problems);
  if (effective.entries.length !== descriptor.expectedEffectiveEntryCount) {
    problems.push(`effective org.lwjgl entry count mismatch: expected=${descriptor.expectedEffectiveEntryCount} actual=${effective.entries.length}`);
  }
  const expectedJava = sortedUnique(descriptor.expectedJavaModules, 'expectedJavaModules', problems);
  const expectedNative = sortedUnique(descriptor.expectedLinuxNativeModules, 'expectedLinuxNativeModules', problems);
  sameList(effective.javaModules, expectedJava, 'effective Java module set', problems);
  sameList(effective.nativeModules, expectedNative, 'effective Linux native module set', problems);
  const eager = sortedUnique(descriptor.clientBootstrap?.eagerNativeModules,
    'clientBootstrap.eagerNativeModules', problems);
  for (const module of eager) {
    if (!effective.javaModules.includes(module)) problems.push(`${module}: eager module has no effective Java artifact`);
  }

  const policyByModule = new Map();
  if (!Array.isArray(policy.modules)) {
    problems.push('coverage policy modules must be an array');
  } else {
    for (const entry of policy.modules) {
      if (!entry || typeof entry.name !== 'string' || entry.name.length === 0) {
        problems.push('coverage policy contains an unnamed module');
        continue;
      }
      if (policyByModule.has(entry.name)) problems.push(`coverage policy duplicates ${entry.name}`);
      policyByModule.set(entry.name, entry);
      if (!STATES.has(entry.state)) problems.push(`${entry.name}: unknown coverage state ${String(entry.state)}`);
    }
  }

  for (const module of effective.javaModules) {
    const entry = policyByModule.get(module);
    if (!entry) {
      problems.push(`${module} is unclassified (target ${descriptor.versionId})`);
      continue;
    }
    if (entry.state === 'provided') {
      verifyModernJarProvider(root, module, modernManifest, problems);
      if (effective.nativeModules.includes(module) || eager.includes(module)) {
        verifyNativeProvider(root, module, entry.native, modernManifest, problems);
      } else if (entry.native) {
        verifyNativeProvider(root, module, entry.native, modernManifest, problems);
      }
    } else if (entry.state === 'intentional-fallback') {
      if (eager.includes(module)) {
        problems.push(`${module}: eager bootstrap module cannot use intentional-fallback`);
      }
      verifyFallback(root, module, entry, modernManifest, problems);
    } else if (entry.state === 'unsupported') {
      // `unsupported` is deliberately a build-stopping state, not a completed
      // third delivery state. It may become passable only after a separately
      // verified version+module prelaunch rejection and accurate user message exist.
      const reason = typeof entry.reason === 'string' && entry.reason.length > 0 ? entry.reason : 'no reason supplied';
      problems.push(`${module}: unsupported for target ${descriptor.versionId}: ${reason}`);
    }
  }

  if (hapBytes !== undefined) {
    verifyHapArtifacts(hapBytes, policy, modernManifest, problems);
    verifyHapProviderNativeSurfaces(hapBytes, policy, problems);
    verifyHapModernNativeSurface(hapBytes, modernManifest, problems);
  }

  return {
    ok: problems.length === 0,
    problems,
    versionId: descriptor.versionId,
    effectiveEntries: effective.entries.length,
    javaModules: effective.javaModules,
    nativeModules: effective.nativeModules,
    states: Object.fromEntries(effective.javaModules.map((module) => [module, policyByModule.get(module)?.state || 'unclassified'])),
  };
}

/**
 * 可选客户端身份校验：同时验证完整官方 JAR 与实际 bootstrap class，不能仅信任
 * JSON 中自报的客户端 hash。该步骤只解析 ZIP 字节，不执行或初始化 Minecraft 类。
 * 默认构建使用已冻结描述符；提供 --client 时验证本次取证/交付所使用的真实客户端。
 */
export function verifyTargetClient(clientBytes, descriptor, problems = []) {
  if (digest('sha1', clientBytes) !== descriptor.clientSha1) {
    problems.push(`${descriptor.versionId}: actual client SHA-1 does not match frozen target`);
  }
  try {
    const classBytes = readUniqueZipEntry(clientBytes, descriptor.clientBootstrap.class);
    if (digest('sha256', classBytes) !== descriptor.clientBootstrap.classSha256) {
      problems.push(`${descriptor.versionId}: actual bootstrap class SHA-256 does not match frozen target`);
    }
  } catch (error) {
    problems.push(`${descriptor.versionId}: cannot read actual bootstrap class: ${error.message}`);
  }
}

/** 加载指定已冻结目标；默认正式版，拒绝路径穿越和未审查的任意目标名称。 */
export function loadDefaultCoverageInputs(root = ROOT, versionId = '26.3') {
  if (!LWJGL_COVERAGE_TARGETS.includes(versionId)) throw new Error(`unaudited LWJGL target: ${versionId}`);
  const descriptorPath = join(root, 'scripts', 'fixtures', 'lwjgl-target-manifests', `${versionId}.coverage.json`);
  const descriptor = JSON.parse(readFileSync(descriptorPath, 'utf8'));
  const metadataPath = join(dirname(descriptorPath), descriptor.metadata);
  return {
    root,
    metadataText: readFileSync(metadataPath, 'utf8'),
    descriptor,
    policy: JSON.parse(readFileSync(POLICY_PATH.replace(ROOT, root), 'utf8')),
    modernManifest: JSON.parse(readFileSync(MODERN_MANIFEST_PATH.replace(ROOT, root), 'utf8')),
  };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const targetIndex = process.argv.indexOf('--target');
  const targetArg = targetIndex >= 0 ? process.argv[targetIndex + 1] : undefined;
  if (targetIndex >= 0 && (!targetArg || targetArg.startsWith('--'))) throw new Error('--target requires an audited version');
  const targets = targetArg ? [targetArg] : LWJGL_COVERAGE_TARGETS;
  let hapBytes;
  const hapIndex = process.argv.indexOf('--hap');
  if (hapIndex >= 0) {
    const hapArg = process.argv[hapIndex + 1];
    if (!hapArg || hapArg.startsWith('--')) {
      throw new Error('--hap requires the selected signed/unsigned HAP path');
    }
    const hapPath = resolve(hapArg);
    if (!existsSync(hapPath)) throw new Error(`selected HAP is missing: ${hapPath}`);
    hapBytes = readFileSync(hapPath);
  }
  let clientBytes;
  const clientIndex = process.argv.indexOf('--client');
  if (clientIndex >= 0) {
    const clientArg = process.argv[clientIndex + 1];
    if (!targetArg) throw new Error('--client requires an explicit --target; clients are not interchangeable');
    if (!clientArg || clientArg.startsWith('--')) throw new Error('--client requires an official client JAR');
    clientBytes = readFileSync(resolve(clientArg));
  }
  const results = targets.map((target) => analyzeLwjglTargetManifestCoverage({
    ...loadDefaultCoverageInputs(ROOT, target), hapBytes, clientBytes,
  }));
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify({ ok: results.every((result) => result.ok), targets: results }, null, 2));
  } else {
    for (const result of results) {
      for (const problem of result.problems) console.error(`[lwjgl-target-manifest] FAIL ${problem}`);
      if (result.ok) {
        const summary = Object.entries(result.states).map(([module, state]) => `${module}=${state}`).join(', ');
        const hapSummary = hapIndex >= 0 ? ', HAP artifacts=verified' : '';
        const clientSummary = clientIndex >= 0 ? ', actual client/bootstrap identity=verified' : '';
        console.log(`[lwjgl-target-manifest] OK ${result.versionId}: ${summary}${hapSummary}${clientSummary}`);
      }
    }
  }
  process.exitCode = results.every((result) => result.ok) ? 0 : 1;
}

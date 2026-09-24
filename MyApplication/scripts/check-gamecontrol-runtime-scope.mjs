#!/usr/bin/env node
// gamecontrol is a HAR whose module-level runtime singletons are safe only while
// entry is its sole consumer module. The desktop GameAbility has its own
// process-local runtime and initialization; no HAR singleton is shared by IPC.
// Additional processes still fail this gate. This does not approve an HSP move.

import {
  existsSync, readFileSync, readdirSync,
} from 'node:fs';
import { dirname, relative, resolve, sep } from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE_EXTENSIONS = ['.ets', '.ts', '.js', '.mjs', '.cjs'];
const IGNORED_DIRECTORIES = new Set([
  '.git', '.hvigor', '.idea', '.cxx', 'build', 'node_modules', 'oh_modules',
  'libs', 'generated', 'intermediates',
]);
const DEPENDENCY_SECTIONS = [
  'dependencies', 'devDependencies', 'dynamicDependencies',
];

function relativePosix(root, target) {
  return relative(root, target).split(sep).join('/');
}

function isInside(root, target) {
  const rootPrefix = resolve(root) + sep;
  const absolute = resolve(target);
  return absolute === resolve(root) || absolute.startsWith(rootPrefix);
}

/** Remove JSON5 comments without treating comment markers inside strings as syntax. */
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
      while (index < text.length &&
             !(text[index] === '*' && text[index + 1] === '/')) {
        if (text[index] === '\n') result += '\n';
        index += 1;
      }
      index += 1;
      continue;
    }
    result += char;
  }
  return result.replace(/,\s*([}\]])/g, '$1');
}

function parseJson5File(root, path, label, issues) {
  if (!existsSync(path)) {
    issues.push(`${label} is missing (${relativePosix(root, path)})`);
    return null;
  }
  try {
    return JSON.parse(stripJson5(readFileSync(path, 'utf8')));
  } catch (error) {
    issues.push(`${label} is not parseable: ${relativePosix(root, path)} (${error.message})`);
    return null;
  }
}

function moduleDescriptors(root, issues) {
  const profilePath = resolve(root, 'build-profile.json5');
  const profile = parseJson5File(root, profilePath, 'project build-profile.json5', issues);
  if (!profile) return [];
  if (!Array.isArray(profile.modules)) {
    issues.push('project build-profile.json5 must contain a modules array');
    return [];
  }

  const modules = [];
  const names = new Set();
  const paths = new Set();
  for (const item of profile.modules) {
    const name = typeof item?.name === 'string' ? item.name.trim() : '';
    const srcPath = typeof item?.srcPath === 'string' ? item.srcPath.trim() : '';
    if (!name || !srcPath) {
      issues.push('every project module needs non-empty name and srcPath');
      continue;
    }
    const moduleRoot = resolve(root, srcPath);
    if (!isInside(root, moduleRoot)) {
      issues.push(`module ${name} srcPath escapes repository root (${srcPath})`);
      continue;
    }
    if (names.has(name)) issues.push(`duplicate project module name: ${name}`);
    if (paths.has(moduleRoot)) {
      issues.push(`multiple project modules resolve to ${relativePosix(root, moduleRoot)}`);
    }
    names.add(name);
    paths.add(moduleRoot);
    modules.push({ name, root: moduleRoot });
  }
  if (!names.has('entry')) issues.push('project module graph is missing entry');
  if (!names.has('gamecontrol')) issues.push('project module graph is missing gamecontrol');
  return modules;
}

function dependencyEntries(packageJson, moduleRoot, gamecontrolRoot) {
  const entries = [];
  for (const section of DEPENDENCY_SECTIONS) {
    const dependencies = packageJson?.[section];
    if (dependencies === undefined) continue;
    if (!dependencies || typeof dependencies !== 'object' || Array.isArray(dependencies)) {
      entries.push({ section, name: '<malformed>', value: dependencies, targetsGamecontrol: false });
      continue;
    }
    for (const [name, value] of Object.entries(dependencies)) {
      let targetsGamecontrol = name === 'gamecontrol';
      if (typeof value === 'string') {
        const rawPath = value.startsWith('file:') ? value.slice(5) : value;
        if (rawPath.startsWith('.') || rawPath.startsWith('/') || /^[A-Za-z]:[\\/]/.test(rawPath)) {
          targetsGamecontrol ||= resolve(moduleRoot, rawPath) === gamecontrolRoot;
        }
      }
      entries.push({ section, name, value, targetsGamecontrol });
    }
  }
  return entries;
}

function sourceFiles(root, repoRoot, moduleName, issues) {
  const files = [];
  if (!existsSync(root)) {
    issues.push(`module ${moduleName} root is missing (${relativePosix(repoRoot, root)})`);
    return files;
  }
  const visit = directory => {
    let children = [];
    try {
      children = readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      issues.push(`cannot scan ${relativePosix(repoRoot, directory)} (${error.message})`);
      return;
    }
    for (const child of children) {
      const path = resolve(directory, child.name);
      if (child.isDirectory()) {
        if (!IGNORED_DIRECTORIES.has(child.name)) visit(path);
        continue;
      }
      if (!child.isFile()) continue;
      if (SOURCE_EXTENSIONS.some(extension => child.name.endsWith(extension))) files.push(path);
    }
  };
  visit(root);
  return files;
}

function lineOf(text, index) {
  return text.slice(0, index).split(/\r?\n/).length;
}

/** A minimal lexer: comments and string contents cannot forge an import token. */
function sourceTokens(text) {
  const tokens = [];
  let index = 0;
  while (index < text.length) {
    const char = text[index];
    const next = text[index + 1];
    if (/\s/.test(char)) {
      index += 1;
      continue;
    }
    if (char === '/' && next === '/') {
      index += 2;
      while (index < text.length && text[index] !== '\n') index += 1;
      continue;
    }
    if (char === '/' && next === '*') {
      index += 2;
      while (index < text.length &&
             !(text[index] === '*' && text[index + 1] === '/')) index += 1;
      index = Math.min(text.length, index + 2);
      continue;
    }
    if (char === '`') {
      index += 1;
      let escaped = false;
      while (index < text.length) {
        const current = text[index];
        if (escaped) escaped = false;
        else if (current === '\\') escaped = true;
        else if (current === '`') {
          index += 1;
          break;
        }
        index += 1;
      }
      continue;
    }
    if (char === '"' || char === "'") {
      const start = index;
      const quote = char;
      let value = '';
      index += 1;
      while (index < text.length) {
        const current = text[index];
        if (current === '\\' && index + 1 < text.length) {
          value += text[index + 1];
          index += 2;
          continue;
        }
        if (current === quote) {
          index += 1;
          break;
        }
        value += current;
        index += 1;
      }
      tokens.push({ type: 'string', value, index: start });
      continue;
    }
    if (/[A-Za-z_$]/.test(char)) {
      const start = index;
      index += 1;
      while (index < text.length && /[A-Za-z0-9_$]/.test(text[index])) index += 1;
      tokens.push({ type: 'identifier', value: text.slice(start, index), index: start });
      continue;
    }
    tokens.push({ type: 'punctuation', value: char, index });
    index += 1;
  }
  return tokens;
}

export function collectGamecontrolImports(text) {
  const tokens = sourceTokens(String(text ?? ''));
  const imports = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token.type !== 'identifier' || (token.value !== 'import' && token.value !== 'export')) {
      continue;
    }
    const next = tokens[index + 1];
    if (token.value === 'import' && next?.type === 'string') {
      if (next.value === 'gamecontrol') imports.push(next.index);
      continue;
    }
    if (token.value === 'import' && next?.value === '(' &&
        tokens[index + 2]?.type === 'string') {
      if (tokens[index + 2].value === 'gamecontrol') imports.push(tokens[index + 2].index);
      continue;
    }
    if (token.value === 'import' && next?.value === '.') continue;
    if (token.value === 'export') {
      const typeExport = next?.type === 'identifier' && next.value === 'type';
      const exportShape = typeExport ? tokens[index + 2]?.value : next?.value;
      if (exportShape !== '*' && exportShape !== '{') continue;
    }
    for (let cursor = index + 1; cursor < tokens.length; cursor += 1) {
      const candidate = tokens[cursor];
      if (candidate.value === ';' ||
          (candidate.type === 'identifier' &&
           (candidate.value === 'import' || candidate.value === 'export'))) break;
      if (candidate.type === 'identifier' && candidate.value === 'from') {
        const specifier = tokens[cursor + 1];
        if (specifier?.type === 'string' && specifier.value === 'gamecontrol') {
          imports.push(specifier.index);
        }
        break;
      }
    }
  }
  return imports.map(index => ({ index, line: lineOf(text, index) }));
}

function moduleManifests(moduleRoot, repoRoot, moduleName, issues) {
  const manifests = [];
  const sourceRoot = resolve(moduleRoot, 'src');
  if (!existsSync(sourceRoot)) return manifests;
  const visit = directory => {
    let children = [];
    try {
      children = readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      issues.push(`cannot scan ${moduleName} manifests at ${relativePosix(repoRoot, directory)} (${error.message})`);
      return;
    }
    for (const child of children) {
      const path = resolve(directory, child.name);
      if (child.isDirectory()) {
        if (!IGNORED_DIRECTORIES.has(child.name)) visit(path);
      } else if (child.isFile() && child.name === 'module.json5') {
        manifests.push(path);
      }
    }
  };
  visit(sourceRoot);
  return manifests;
}

function collectProcessRisks(value, objectPath = '$', risks = []) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      collectProcessRisks(value[index], `${objectPath}[${index}]`, risks);
    }
    return risks;
  }
  if (!value || typeof value !== 'object') return risks;
  for (const [key, nested] of Object.entries(value)) {
    const path = `${objectPath}.${key}`;
    if (key === 'process' && (typeof nested !== 'string' || nested.trim() !== '')) {
      risks.push(`${path} declares process=${JSON.stringify(nested)}`);
    } else if (key === 'isolationProcess' && nested === true) {
      risks.push(`${path} enables an isolated process`);
    } else if (key === 'extensionProcessMode' && nested !== undefined && nested !== 'bundle') {
      risks.push(`${path} declares extensionProcessMode=${JSON.stringify(nested)}`);
    }
    collectProcessRisks(nested, path, risks);
  }
  return risks;
}

/** One named private game process, conditioned on its separate runtime wiring. */
function desktopProcessManifest(root, moduleName, manifestPath, manifest) {
  if (moduleName !== 'entry' || relativePosix(root, manifestPath) !== 'entry/src/main/module.json5') return manifest;
  const game = manifest.module?.abilities?.find(a => a.name === 'GameAbility');
  if (game?.process !== ':game' || game?.launchType !== 'singleton' || game?.exported !== false ||
      game?.srcEntry !== './ets/gameability/GameAbility.ets') return manifest;
  for (const [path, required] of [
    ['entry/src/main/ets/gameability/GameAbility.ets', ['desktopGameProcessState', 'initializeGameProcess', 'mcForceExit']],
    ['entry/src/main/ets/runtime/ProcessRuntime.ets', ['setControlNativeSink', 'setDownloadNativeEngine', 'setRelayNativeBridge', 'setForgeNativeBridge', 'setSystemNativeBridge', 'setLaunchNativeBridge', 'DiagnosticPolicy . configure', 'DistributionPolicy . configure', 'ProductInputProfile . initialize', 'amclLogInit']],
  ]) {
    const file = resolve(root, path);
    if (!existsSync(file)) return manifest;
    const code = sourceTokens(readFileSync(file, 'utf8')).map(t => t.type === 'string' ? '<string>' : t.value).join(' ');
    if (required.some(name => !code.includes(name + ' ('))) return manifest;
  }
  const copy = structuredClone(manifest);
  delete copy.module.abilities.find(a => a.name === 'GameAbility').process;
  return copy;
}

export function auditGamecontrolRuntimeScope(root) {
  const absoluteRoot = resolve(root);
  const issues = [];
  const modules = moduleDescriptors(absoluteRoot, issues);
  const gamecontrol = modules.find(module => module.name === 'gamecontrol');
  const entry = modules.find(module => module.name === 'entry');
  const gamecontrolRoot = gamecontrol?.root ?? resolve(absoluteRoot, 'gamecontrol');
  const dependencyOwners = [];
  const consumerFiles = [];
  let manifestCount = 0;

  if (gamecontrol) {
    const manifestPath = resolve(gamecontrol.root, 'src/main/module.json5');
    const manifest = parseJson5File(
      absoluteRoot, manifestPath, 'gamecontrol runtime manifest', issues);
    if (manifest && manifest.module?.type !== 'har') {
      issues.push('gamecontrol runtime-scope gate expects module.type="har"; update the contract during HSP migration');
    }
  }

  for (const module of modules) {
    const packagePath = resolve(module.root, 'oh-package.json5');
    const packageJson = parseJson5File(
      absoluteRoot, packagePath, `${module.name} oh-package.json5`, issues);
    if (!packageJson) continue;
    const entries = dependencyEntries(packageJson, module.root, gamecontrolRoot);
    for (const dependency of entries) {
      if (dependency.name === '<malformed>') {
        issues.push(`${module.name} ${dependency.section} must be an object`);
        continue;
      }
      if (!dependency.targetsGamecontrol) continue;
      dependencyOwners.push(module.name);
      if (module.name !== 'entry') {
        issues.push(`${module.name}/${dependency.section} depends on gamecontrol; entry must be its sole consumer module`);
      }
    }
    if (module.name === 'entry') {
      const runtimeDependency = packageJson.dependencies?.gamecontrol;
      if (typeof runtimeDependency !== 'string') {
        issues.push('entry/dependencies must declare gamecontrol as a runtime dependency');
      } else if (!runtimeDependency.startsWith('file:') ||
                 resolve(module.root, runtimeDependency.slice(5)) !== gamecontrolRoot) {
        issues.push(`entry gamecontrol dependency must resolve to the project HAR (${runtimeDependency})`);
      }
    }

    for (const path of sourceFiles(module.root, absoluteRoot, module.name, issues)) {
      const text = readFileSync(path, 'utf8');
      const imports = collectGamecontrolImports(text);
      if (imports.length === 0) continue;
      consumerFiles.push({ module: module.name, path });
      if (module.name !== 'entry' && module.name !== 'gamecontrol') {
        for (const occurrence of imports) {
          issues.push(`${relativePosix(absoluteRoot, path)}:${occurrence.line} imports 'gamecontrol' outside entry/gamecontrol`);
        }
      }
    }
  }

  const consumerModules = new Set(consumerFiles.map(file => file.module));
  for (const module of modules) {
    if (!consumerModules.has(module.name)) continue;
    const manifests = moduleManifests(module.root, absoluteRoot, module.name, issues);
    if (manifests.length === 0 && module.name !== 'gamecontrol') {
      issues.push(`${module.name} imports gamecontrol but has no source module.json5 to prove process scope`);
    }
    for (const manifestPath of manifests) {
      manifestCount += 1;
      const manifest = parseJson5File(
        absoluteRoot, manifestPath, `${module.name} module manifest`, issues);
      if (!manifest) continue;
      for (const risk of collectProcessRisks(desktopProcessManifest(absoluteRoot, module.name, manifestPath, manifest))) {
        issues.push(`${relativePosix(absoluteRoot, manifestPath)}: ${risk}; separate process runtime contract is missing or not approved`);
      }
    }
  }

  if (entry && !consumerModules.has('entry')) {
    issues.push('entry declares gamecontrol but no entry source imports it; runtime ownership contract is disconnected');
  }

  return {
    issues,
    moduleCount: modules.length,
    dependencyOwners: [...new Set(dependencyOwners)].sort(),
    consumerFileCount: consumerFiles.length,
    manifestCount,
  };
}

export function validateGamecontrolRuntimeScope(root) {
  return auditGamecontrolRuntimeScope(root).issues;
}

function main() {
  const result = auditGamecontrolRuntimeScope(REPO_ROOT);
  if (result.issues.length > 0) {
    console.error('[gamecontrol-runtime-scope] FAIL');
    for (const issue of result.issues) console.error(`  - ${issue}`);
    process.exitCode = 1;
    return;
  }
  console.log('[gamecontrol-runtime-scope] PASS');
  console.log(`  modules: ${result.moduleCount}`);
  console.log(`  dependency owner: ${result.dependencyOwners.join(', ')}`);
  console.log(`  source consumers: ${result.consumerFileCount}`);
  console.log(`  consumer manifests: ${result.manifestCount}`);
}

const invokedDirectly = process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) main();

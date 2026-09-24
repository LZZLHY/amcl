// Verify that the post-processed LWJGL modern slot is one indivisible release.
// Usage:
//   node scripts/check-lwjgl-modern-slot.mjs
//   node scripts/check-lwjgl-modern-slot.mjs --require-source

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, '..');
const MANIFEST_PATH = join(ROOT, 'prebuilt', 'lwjgl3', 'modern-slot.manifest.json');
const PREBUILT_DIR = join(ROOT, 'prebuilt', 'lwjgl3', 'jars');
const RAWFILE_DIR = join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'lwjgl');
const NATIVE_DIR = join(ROOT, 'entry', 'libs', 'arm64-v8a');
const RUNTIME_CONTRACT = join(ROOT, 'launch', 'src', 'main', 'ets', 'LwjglModernSlot.ets');
const DEPS_LOCK = join(ROOT, 'deps.lock');
const SOURCE_DIR = join(ROOT, 'prebuilt', 'lwjgl3', 'lwjgl3_src');

function fail(message) {
  throw new Error(message);
}

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function exactJarNames(dir) {
  if (!existsSync(dir)) fail(`missing directory: ${dir}`);
  return readdirSync(dir).filter((name) => name.endsWith('.jar')).sort();
}

function verifyDirectory(dir, expected) {
  const actualNames = exactJarNames(dir);
  const expectedNames = expected.map((jar) => jar.name).sort();
  if (actualNames.join('|') !== expectedNames.join('|')) {
    fail(`${dir}: jar set mismatch\nexpected=${expectedNames.join(',')}\nactual=${actualNames.join(',')}`);
  }
  for (const jar of expected) {
    const path = join(dir, jar.name);
    const size = statSync(path).size;
    if (size !== jar.size) fail(`${path}: size ${size}, expected ${jar.size}`);
    const digest = sha256File(path);
    if (digest !== jar.sha256) fail(`${path}: sha256 ${digest}, expected ${jar.sha256}`);
  }
}

function section(text, name) {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === `[${name}]`);
  if (start < 0) fail(`deps.lock missing [${name}]`);
  const out = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\s*\[/.test(lines[i])) break;
    out.push(lines[i]);
  }
  return out.join('\n');
}

function field(sectionText, key) {
  for (const line of sectionText.split('\n')) {
    const equals = line.indexOf('=');
    if (equals < 0 || line.slice(0, equals).trim() !== key) continue;
    return line.slice(equals + 1).split('#', 1)[0].trim();
  }
  return '';
}

const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8'));
if (manifest.schema !== 1 || manifest.slot !== 'modern') fail('unsupported modern-slot manifest schema');
if (manifest.deploymentDirectory !== 'lwjgl-ohos' || manifest.nativeSuffix !== '') {
  fail('3.4.2 must replace the unversioned modern slot; do not create a parallel 342 slot');
}
if (!Array.isArray(manifest.jars) || manifest.jars.length !== 15) fail('modern slot must contain exactly 15 jars');
// 15 不是 16：lwjgl-jemalloc 被刻意排除，见 deps.lock [lwjgl-jars] 的说明。
if (manifest.jars.some((jar) => jar.name === 'lwjgl-jemalloc.jar')) {
  fail('lwjgl-jemalloc.jar must stay out of the modern slot: no OHOS libjemalloc.so exists and LWJGL 3.4.2+ cannot fall back once the nested allocator instantiates');
}
if (!manifest.jars.some((jar) => jar.name === 'lwjgl-sdl.jar')) fail('modern slot must include lwjgl-sdl.jar');
if (!manifest.jars.some((jar) => jar.name === 'lwjgl-spng.jar')) fail('modern slot must include lwjgl-spng.jar');
if (!Array.isArray(manifest.natives) || manifest.natives.length !== 6) fail('modern slot must contain exactly 6 LWJGL natives');
if (!manifest.natives.some((native) => native.name === 'liblwjgl_spng.so')) fail('modern slot must include liblwjgl_spng.so');

const sorted = [...manifest.jars].sort((a, b) => a.name.localeCompare(b.name));
const payload = sorted.map((jar) => `${jar.name}|${jar.size}|${jar.sha256}`).join('\n') + '\n';
const entryDigest = createHash('sha256').update(payload, 'utf8').digest('hex');
if (entryDigest !== manifest.manifestEntrySha256) {
  fail(`manifestEntrySha256=${manifest.manifestEntrySha256}, calculated=${entryDigest}`);
}

verifyDirectory(PREBUILT_DIR, sorted);
verifyDirectory(RAWFILE_DIR, sorted);
for (const native of manifest.natives) {
  const path = join(NATIVE_DIR, native.name);
  if (!existsSync(path)) fail(`missing modern native: ${path}`);
  const size = statSync(path).size;
  if (size !== native.size) fail(`${path}: size ${size}, expected ${native.size}`);
  const digest = sha256File(path);
  if (digest !== native.sha256) fail(`${path}: sha256 ${digest}, expected ${native.sha256}`);
}

const runtimeText = readFileSync(RUNTIME_CONTRACT, 'utf8');
for (const value of [manifest.version, manifest.sourceCommit, manifest.manifestEntrySha256]) {
  if (!runtimeText.includes(value)) fail(`runtime contract is stale; missing ${value}`);
}
const runtimeEntries = [...runtimeText.matchAll(/\{ name: '([^']+)', size: (\d+), sha256: '([0-9a-f]{64})' \}/g)]
  .map((match) => ({ name: match[1], size: Number(match[2]), sha256: match[3] }))
  .sort((a, b) => a.name.localeCompare(b.name));
if (JSON.stringify(runtimeEntries) !== JSON.stringify(sorted.map(({ name, size, sha256 }) => ({ name, size, sha256 })))) {
  fail('launch/LwjglModernSlot.ets does not exactly match modern-slot.manifest.json');
}

const lockText = readFileSync(DEPS_LOCK, 'utf8');
const jarsLock = section(lockText, 'lwjgl-jars');
const nativesLock = section(lockText, 'lwjgl-natives');
if (field(jarsLock, 'version') !== manifest.version) fail('deps.lock [lwjgl-jars].version mismatch');
if (field(nativesLock, 'tag') !== manifest.sourceTag) fail('deps.lock [lwjgl-natives].tag mismatch');
if (field(nativesLock, 'commit') !== manifest.sourceCommit) fail('deps.lock [lwjgl-natives].commit mismatch');
for (const native of manifest.natives) {
  const stem = native.name.replace(/^lib/, 'lib').replace(/\.so$/, '');
  if (field(nativesLock, `${stem}_size`) !== String(native.size)) fail(`deps.lock ${stem}_size mismatch`);
  if (field(nativesLock, `${stem}_sha256`) !== native.sha256) fail(`deps.lock ${stem}_sha256 mismatch`);
}
const modules = field(jarsLock, 'modules').split(',').filter(Boolean).sort();
const manifestModules = sorted.map((jar) => jar.name.replace(/\.jar$/, '')).sort();
if (modules.join('|') !== manifestModules.join('|')) fail('deps.lock modules do not exactly match the modern-slot jar set');

if (process.argv.includes('--require-source')) {
  if (!existsSync(join(SOURCE_DIR, '.git'))) fail('LWJGL source submodule is not initialized');
  const head = execFileSync('git', ['-C', SOURCE_DIR, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  if (head !== manifest.sourceCommit) fail(`LWJGL source HEAD=${head}, expected=${manifest.sourceCommit}`);
}

console.log(`[lwjgl-modern-slot] OK ${manifest.version}: ${sorted.length} jars, manifest ${entryDigest}`);

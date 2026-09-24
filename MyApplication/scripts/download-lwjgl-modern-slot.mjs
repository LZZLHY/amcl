#!/usr/bin/env node
// Materialize the locked LWJGL modern slot as one release.
//
// The stable paths are deliberately unversioned:
//   prebuilt/lwjgl3/jars -> rawfile/lwjgl -> device lwjgl-ohos
// 3.4.2 replaces 3.4.1 in this slot. LWJGL 3.2.3 (_v322/lwjgl-ohos-322) and
// LWJGL 2 are separate compatibility slots and are never touched here.

import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import {
  copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync,
  rmSync, statSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDir, '..');
const lockPath = join(root, 'deps.lock');
const manifestPath = join(root, 'prebuilt/lwjgl3/modern-slot.manifest.json');
const prebuilt = join(root, 'prebuilt/lwjgl3/jars');
const rawfile = join(root, 'entry/src/main/resources/rawfile/lwjgl');
const token = `${process.pid}-${Date.now()}`;
const stage = join(dirname(prebuilt), `.modern-slot-stage-${token}`);
const rawStage = join(dirname(rawfile), `.lwjgl-stage-${token}`);
const prebuiltBackup = join(dirname(prebuilt), `.modern-slot-backup-${token}`);
const rawBackup = join(dirname(rawfile), `.lwjgl-backup-${token}`);
const force = process.argv.includes('--force');
const inspectFinal = process.argv.includes('--inspect-final');
const upstreamDirIndex = process.argv.indexOf('--upstream-dir');
const upstreamDir = upstreamDirIndex >= 0
  ? resolve(process.argv[upstreamDirIndex + 1] || fail('--upstream-dir requires a path'))
  : null;

function fail(message) { throw new Error(message); }
function sha256(path) { return createHash('sha256').update(readFileSync(path)).digest('hex'); }
function run(file, args) { execFileSync(file, args, { cwd: root, stdio: 'inherit' }); }

function lockSection(text, name) {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === `[${name}]`);
  if (start < 0) fail(`deps.lock missing [${name}]`);
  const values = new Map();
  for (let i = start + 1; i < lines.length && !/^\s*\[/.test(lines[i]); i++) {
    const equals = lines[i].indexOf('=');
    if (equals < 0) continue;
    values.set(lines[i].slice(0, equals).trim(), lines[i].slice(equals + 1).split('#', 1)[0].trim());
  }
  return values;
}

function locatePython() {
  const candidates = process.env.AMCL_PYTHON
    ? [{ file: process.env.AMCL_PYTHON, prefix: [] }]
    : process.platform === 'win32'
      ? [{ file: 'py', prefix: ['-3'] }, { file: 'python3', prefix: [] }, { file: 'python', prefix: [] }]
      : [{ file: 'python3', prefix: [] }, { file: 'python', prefix: [] }];
  for (const candidate of candidates) {
    if (spawnSync(candidate.file, [...candidate.prefix, '--version']).status === 0) return candidate;
  }
  fail('Python 3 is required for deterministic LWJGL jar post-processing');
}

async function download(url, target) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    const part = `${target}.part-${attempt}`;
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(60_000) });
      if (!response.ok) fail(`download failed (${response.status}): ${url}`);
      writeFileSync(part, Buffer.from(await response.arrayBuffer()), { flag: 'wx' });
      renameSync(part, target);
      return;
    } catch (error) {
      rmSync(part, { force: true });
      lastError = error;
      console.warn(`[download-lwjgl-modern-slot] retry ${attempt}/3: ${error.message}`);
    }
  }
  throw lastError;
}

function verifyFinalDirectory(dir, jars) {
  const actual = readdirSync(dir).filter((name) => name.endsWith('.jar')).sort();
  const expected = jars.map((jar) => jar.name).sort();
  if (actual.join('|') !== expected.join('|')) fail(`staged jar set mismatch: ${actual.join(',')}`);
  for (const jar of jars) {
    const path = join(dir, jar.name);
    if (statSync(path).size !== jar.size || sha256(path) !== jar.sha256) {
      fail(`post-processed artifact mismatch: ${jar.name}`);
    }
  }
}

function copyExact(from, to, jars) {
  mkdirSync(to, { recursive: true });
  for (const jar of jars) copyFileSync(join(from, jar.name), join(to, jar.name));
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const lock = lockSection(readFileSync(lockPath, 'utf8'), 'lwjgl-jars');
if (manifest.version !== lock.get('version')) fail('manifest/deps.lock LWJGL version mismatch');
if (manifest.deploymentDirectory !== 'lwjgl-ohos' || manifest.nativeSuffix !== '') {
  fail('modern LWJGL must replace the unversioned slot; a parallel 342 slot is forbidden');
}

if (!force) {
  const current = spawnSync(process.execPath, [join(scriptDir, 'check-lwjgl-modern-slot.mjs')], {
    cwd: root, stdio: 'inherit',
  });
  if (current.status === 0) {
    console.log('[download-lwjgl-modern-slot] already exact; no download or rewrite');
    process.exit(0);
  }
}

const modules = lock.get('modules').split(',').filter(Boolean);
const expectedNames = manifest.jars.map((jar) => jar.name).sort();
const moduleNames = modules.map((module) => `${module}.jar`).sort();
if (expectedNames.join('|') !== moduleNames.join('|')) fail('deps.lock modules do not match modern manifest');

mkdirSync(stage, { recursive: false });
try {
  for (const module of modules) {
    const artifact = `${module}-${manifest.version}.jar`;
    const url = `${lock.get('maven_base')}/${module}/${manifest.version}/${artifact}`;
    const target = join(stage, `${module}.jar`);
    if (upstreamDir) {
      const source = join(upstreamDir, `${module}.jar`);
      if (!existsSync(source)) fail(`upstream baseline missing: ${source}`);
      copyFileSync(source, target);
      console.log(`[download-lwjgl-modern-slot] ${module} ${manifest.version} (verified local baseline)`);
    } else {
      console.log(`[download-lwjgl-modern-slot] ${module} ${manifest.version}`);
      await download(url, target);
    }
    const expected = lock.get(`${module}_sha256`);
    const actual = sha256(target);
    if (!expected || actual !== expected) fail(`${module} upstream sha256=${actual}, expected=${expected || '<missing>'}`);
  }

  const python = locatePython();
  run(python.file, [...python.prefix, join(scriptDir, 'patch-lwjgl-module-info.py'), stage]);
  run(python.file, [...python.prefix, join(scriptDir, 'patch-lwjgl-modulepackages.py'), join(stage, 'lwjgl.jar')]);
  run(process.execPath, [join(scriptDir, 'lwjgl-stack-backfill/apply.mjs'), stage]);
  // Order is part of the locked ZIP identity, including bridge and TinyFD metadata.
  run(process.execPath, [join(scriptDir, 'build-prebuilt-jars.mjs'), '--force', '--lwjgl-dir', stage]);
  run(python.file, [...python.prefix, join(scriptDir, 'lwjgl-stb-compat/prepare.py'), '--jar-dir', stage, '--module', 'stb']);
  run(python.file, [...python.prefix, join(scriptDir, 'finalize-lwjgl-native-hashes.py'), '--jar-dir', stage]);
  run(python.file, [...python.prefix, join(scriptDir, 'lwjgl-stb-compat/prepare.py'), '--jar-dir', stage, '--module', 'tinyfd']);
  if (inspectFinal) {
    const report = readdirSync(stage).filter((name) => name.endsWith('.jar')).sort().map((name) => ({
      name,
      size: statSync(join(stage, name)).size,
      sha256: sha256(join(stage, name)),
    }));
    console.log('[download-lwjgl-modern-slot] FINAL-REPORT');
    console.log(JSON.stringify(report, null, 2));
  } else {
    verifyFinalDirectory(stage, manifest.jars);
    copyExact(stage, rawStage, manifest.jars);

    let prebuiltSwapped = false;
    let rawSwapped = false;
    try {
      if (existsSync(prebuilt)) renameSync(prebuilt, prebuiltBackup);
      renameSync(stage, prebuilt);
      prebuiltSwapped = true;
      if (existsSync(rawfile)) renameSync(rawfile, rawBackup);
      renameSync(rawStage, rawfile);
      rawSwapped = true;
      run(process.execPath, [join(scriptDir, 'check-lwjgl-modern-slot.mjs')]);
    } catch (error) {
      if (rawSwapped && existsSync(rawfile)) rmSync(rawfile, { recursive: true, force: true });
      if (existsSync(rawBackup)) renameSync(rawBackup, rawfile);
      if (prebuiltSwapped && existsSync(prebuilt)) rmSync(prebuilt, { recursive: true, force: true });
      if (existsSync(prebuiltBackup)) renameSync(prebuiltBackup, prebuilt);
      throw error;
    }
    rmSync(prebuiltBackup, { recursive: true, force: true });
    rmSync(rawBackup, { recursive: true, force: true });
    console.log(`[download-lwjgl-modern-slot] installed ${manifest.version} into the existing modern slot`);
  }
} finally {
  rmSync(stage, { recursive: true, force: true });
  rmSync(rawStage, { recursive: true, force: true });
}

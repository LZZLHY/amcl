// Build AMCL-owned bridge classes, normalize the modern LWJGL jars, sync them
// into rawfile, then enforce the locked 3.4.2 manifest as one atomic slot.

import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, '..');
const PREBUILT = join(ROOT, 'prebuilt', 'lwjgl3', 'jars');
const RAWFILE = join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'lwjgl');
const CHECKER = join(SCRIPT_DIR, 'check-lwjgl-modern-slot.mjs');

function run(command, args) {
  execFileSync(command, args, { cwd: ROOT, stdio: 'inherit' });
}

function syncExact() {
  mkdirSync(RAWFILE, { recursive: true });
  const expected = readdirSync(PREBUILT).filter((name) => name.endsWith('.jar')).sort();
  for (const name of readdirSync(RAWFILE)) {
    if (name.endsWith('.jar') && !expected.includes(name)) rmSync(join(RAWFILE, name), { force: true });
  }
  for (const name of expected) copyFileSync(join(PREBUILT, name), join(RAWFILE, name));
}

function checkQuietly() {
  const result = spawnSync(process.execPath, [CHECKER], { cwd: ROOT, encoding: 'utf8' });
  return result.status === 0;
}

function locatePython() {
  const configured = process.env.AMCL_PYTHON;
  const candidates = configured
    ? [{ command: configured, prefix: [] }]
    : process.platform === 'win32'
      ? [
          { command: 'py', prefix: ['-3'] },
          { command: 'python3', prefix: [] },
          { command: 'python', prefix: [] },
        ]
      : [
          { command: 'python3', prefix: [] },
          { command: 'python', prefix: [] },
        ];
  for (const candidate of candidates) {
    const probe = spawnSync(candidate.command, [...candidate.prefix, '--version'], { encoding: 'utf8' });
    if (probe.status === 0) return candidate;
  }
  throw new Error('Python 3 is required to post-process freshly downloaded LWJGL jars. Set AMCL_PYTHON to its executable.');
}

run(process.execPath, [join(SCRIPT_DIR, 'build-prebuilt-jars.mjs')]);
syncExact();

// The common incremental path is already byte-exact and avoids touching the jars.
// A fresh Maven download needs every normalization and compatibility pass below.
if (!checkQuietly()) {
  const python = locatePython();
  run(python.command, [...python.prefix, join(SCRIPT_DIR, 'patch-lwjgl-module-info.py'), PREBUILT]);
  run(python.command, [...python.prefix, join(SCRIPT_DIR, 'patch-lwjgl-modulepackages.py'), join(PREBUILT, 'lwjgl.jar')]);
  run(process.execPath, [join(SCRIPT_DIR, 'lwjgl-stack-backfill', 'apply.mjs'), PREBUILT]);
  run(process.execPath, [join(SCRIPT_DIR, 'build-prebuilt-jars.mjs'), '--force']);
  run(python.command, [...python.prefix, join(SCRIPT_DIR, 'lwjgl-stb-compat', 'prepare.py'), '--module', 'stb']);
  run(python.command, [...python.prefix, join(SCRIPT_DIR, 'finalize-lwjgl-native-hashes.py')]);
  run(python.command, [...python.prefix, join(SCRIPT_DIR, 'lwjgl-stb-compat', 'prepare.py'), '--module', 'tinyfd']);
  syncExact();
}

const checkArgs = [CHECKER];
if (process.argv.includes('--require-source')) checkArgs.push('--require-source');
run(process.execPath, checkArgs);
run(process.execPath, [join(SCRIPT_DIR, 'check-lwjgl-native-surface.mjs'), join(ROOT, 'entry', 'libs', 'arm64-v8a')]);
console.log('[prepare-lwjgl-modern-slot] modern slot ready');

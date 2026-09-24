#!/usr/bin/env node
// Verify the shipped SDL3 binary against its provenance lock and LWJGL contract.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';
import {
  artifactEmbedsSdl3Patchset,
  computeSdl3PatchsetDigest,
  sdl3PatchsetMarker,
} from './sdl3-patchset-digest.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDir, '..');
const soIndex = process.argv.indexOf('--so');
const so = soIndex >= 0 ? resolve(process.argv[soIndex + 1]) : join(root, 'entry/libs/arm64-v8a/libSDL3.so');
const hapIndex = process.argv.indexOf('--hap');
const hap = hapIndex >= 0 ? resolve(process.argv[hapIndex + 1]) : '';
const provenanceOnly = process.argv.includes('--provenance-only');
if (!existsSync(so)) throw new Error(`SDL3 artifact missing: ${so}`);

const lines = readFileSync(join(root, 'deps.lock'), 'utf8').split(/\r?\n/);
const start = lines.findIndex((line) => line.trim() === '[sdl3-native]');
if (start < 0) throw new Error('deps.lock missing [sdl3-native]');
const lock = new Map();
for (let i = start + 1; i < lines.length && !/^\s*\[/.test(lines[i]); i++) {
  const equals = lines[i].indexOf('=');
  if (equals < 0) continue;
  lock.set(lines[i].slice(0, equals).trim(), lines[i].slice(equals + 1).split('#', 1)[0].trim());
}

const soBytes = readFileSync(so);
const size = statSync(so).size;
const digest = createHash('sha256').update(soBytes).digest('hex');
if (size !== Number(lock.get('size'))) throw new Error(`libSDL3.so size=${size}, expected=${lock.get('size')}`);
if (digest !== lock.get('sha256')) throw new Error(`libSDL3.so sha256=${digest}, expected=${lock.get('sha256')}`);
const expectedPatchset = lock.get('patchset_sha256') ?? '';
if (!/^[0-9a-f]{64}$/.test(expectedPatchset)) {
  throw new Error('deps.lock [sdl3-native].patchset_sha256 must be 64 lowercase hex characters');
}
const actualPatchset = computeSdl3PatchsetDigest(root).sha256;
if (actualPatchset !== expectedPatchset) {
  throw new Error(`SDL3 patchset sha256=${actualPatchset}, expected=${expectedPatchset}`);
}
const patchsetMarker = sdl3PatchsetMarker(expectedPatchset);
if (!artifactEmbedsSdl3Patchset(soBytes, expectedPatchset)) {
  throw new Error(`libSDL3.so does not embed ordered patchset identity ${patchsetMarker}`);
}

if (hap) {
  if (!existsSync(hap)) throw new Error(`HAP artifact missing: ${hap}`);
  const embedded = readUniqueZipEntry(
    readFileSync(hap), 'libs/arm64-v8a/libSDL3.so');
  const embeddedDigest = createHash('sha256').update(embedded).digest('hex');
  const expectedHapSize = Number(lock.get('hap_size'));
  const expectedHapDigest = lock.get('hap_sha256') ?? '';
  if (!Number.isSafeInteger(expectedHapSize) || expectedHapSize <= 0 ||
      !/^[0-9a-f]{64}$/.test(expectedHapDigest)) {
    throw new Error('deps.lock SDL3 HAP stripped size/hash contract is missing or malformed');
  }
  if (embedded.length !== expectedHapSize ||
      embeddedDigest !== expectedHapDigest ||
      !artifactEmbedsSdl3Patchset(embedded, expectedPatchset)) {
    throw new Error(`HAP libSDL3.so drifted: size=${embedded.length} sha256=${embeddedDigest}; expected stripped size=${expectedHapSize} sha256=${expectedHapDigest}`);
  }
}

if (!provenanceOnly) {
  execFileSync(process.execPath, [
    join(scriptDir, 'check-sdl3-surface.mjs'),
    '--so', so,
    '--jar', join(root, 'prebuilt/lwjgl3/jars/lwjgl-sdl.jar'),
  ], { cwd: root, stdio: 'inherit' });
  execFileSync(process.execPath, [join(scriptDir, 'check-sdl3-launch-contract.mjs')], {
    cwd: root,
    stdio: 'inherit',
  });
// The ELF hash proves which locked binary is shipped; the source contract
// proves that its reproducible patch recipe still contains the hybrid-window
// mechanism needed by Snapshot 9+ (and rejects title/version/hash selectors).
// Applied-source validation runs in build-sdl3-ohos.ps1 after patching.
  execFileSync(process.execPath, [
    join(scriptDir, 'check-sdl3-multiwindow-contract.mjs'),
    '--patch-series', join(root, 'prebuilt/sdl3/patches/series'),
  ], { cwd: root, stdio: 'inherit' });
  execFileSync(process.execPath, [
    join(scriptDir, 'check-sdl3-text-session-contract.mjs'),
  ], { cwd: root, stdio: 'inherit' });
}

console.log(`[sdl3-artifact] PASS ${size} bytes ${digest} patchset=${actualPatchset}${hap ? ' hap-embedded=match' : ''}`);

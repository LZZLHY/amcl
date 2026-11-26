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
import { readSdl3ArtifactLock } from './lib/sdl3-artifact-lock.mjs';
import { readUniqueZipEntry } from './zip-entry-buffer.mjs';
import { verifySdl2GamepadArtifacts } from './lib/sdl2-gamepad-artifacts.mjs';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(scriptDir, '..');
const controller = process.argv.includes('--controller');
const name = controller ? 'libamcl_sdl_controller.so' : 'libSDL3.so';
const proofName = controller ? 'controller-build-provenance.json' : 'build-provenance.json';
const soIndex = process.argv.indexOf('--so');
const so = soIndex >= 0 ? resolve(process.argv[soIndex + 1]) : join(root, 'entry/libs/arm64-v8a', name);
const hapIndex = process.argv.indexOf('--hap');
const hap = hapIndex >= 0 ? resolve(process.argv[hapIndex + 1]) : '';
const provenanceOnly = process.argv.includes('--provenance-only');
if (!existsSync(so)) throw new Error(`SDL3 artifact missing: ${so}`);

const lock = readSdl3ArtifactLock(root, controller);

// 构建来源记录同样指向正在交付的 recipe、原 ELF 和 SDK strip 两种字节身份。
const proof = JSON.parse(readFileSync(join(root, 'prebuilt/sdl3', proofName), 'utf8'));
if (proof.source?.commit !== lock.get('commit') || proof.recipe?.patchsetSha256 !== lock.get('patchset_sha256') ||
    proof.artifacts?.raw?.size !== Number(lock.get('size')) || proof.artifacts?.raw?.sha256 !== lock.get('sha256') ||
    proof.artifacts?.sdkStripAll?.size !== Number(lock.get('hap_size')) || proof.artifacts?.sdkStripAll?.sha256 !== lock.get('hap_sha256')) {
  throw new Error(proofName + ' differs from locked SDL artifact ' + name);
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
const actualPatchset = computeSdl3PatchsetDigest(root, controller).sha256;
if (actualPatchset !== expectedPatchset) {
  throw new Error(`SDL3 patchset sha256=${actualPatchset}, expected=${expectedPatchset}`);
}
const patchsetMarker = sdl3PatchsetMarker(expectedPatchset);
if (!artifactEmbedsSdl3Patchset(soBytes, expectedPatchset)) {
  throw new Error(`libSDL3.so does not embed ordered patchset identity ${patchsetMarker}`);
}

if (controller && soIndex < 0) verifySdl2GamepadArtifacts(root, null);
if (hap) {
  if (!existsSync(hap)) throw new Error(`HAP artifact missing: ${hap}`);
  const hapBytes = readFileSync(hap);
  if (controller && soIndex < 0) verifySdl2GamepadArtifacts(root, hapBytes);
  const embedded = readUniqueZipEntry(hapBytes, 'libs/arm64-v8a/' + name);
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
    '--so', so, ...(controller ? ['--controller'] : []),
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

// 默认交付门同时核两个实际 HAP 成员。显式 --so 仅针对调用者提供的那一个制品。
if (!controller && soIndex < 0) {
  execFileSync(process.execPath, [process.argv[1], '--controller', ...process.argv.slice(2)], {cwd: root, stdio: 'inherit'});
}
console.log(`[sdl3-artifact] PASS ${size} bytes ${digest} patchset=${actualPatchset}${hap ? ' hap-embedded=match' : ''}`);

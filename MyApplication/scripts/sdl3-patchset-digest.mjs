#!/usr/bin/env node
// Canonical digest for the ordered SDL patch recipe.  This is intentionally
// byte-sensitive: changing a patch, its name, or its position creates a new
// build identity which must be embedded in and locked beside libSDL3.so.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DOMAIN = Buffer.from('AMCL-SDL3-PATCHSET-V1\0', 'utf8');
const ZERO = Buffer.from([0]);

export function parseSdl3PatchSeries(seriesText) {
  const names = String(seriesText ?? '').split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !line.startsWith('#'));
  const seen = new Set();
  for (const name of names) {
    if (!/^\d{4}-[A-Za-z0-9._-]+\.patch$/.test(name) ||
        name.includes('..') || name.includes('/') || name.includes('\\')) {
      throw new Error(`invalid SDL patch-series entry: ${name}`);
    }
    if (seen.has(name)) throw new Error(`duplicate SDL patch-series entry: ${name}`);
    seen.add(name);
  }
  if (names.length === 0) throw new Error('SDL patch series is empty');
  return names;
}

export function digestSdl3PatchTexts(seriesText, patchTexts) {
  const names = parseSdl3PatchSeries(seriesText);
  const hash = createHash('sha256');
  hash.update(DOMAIN);
  for (const name of names) {
    const bytes = patchTexts instanceof Map
      ? patchTexts.get(name) : patchTexts?.[name];
    if (bytes === undefined) throw new Error(`missing SDL patch bytes: ${name}`);
    hash.update(Buffer.from(name, 'utf8'));
    hash.update(ZERO);
    hash.update(Buffer.isBuffer(bytes) ? bytes : Buffer.from(String(bytes), 'utf8'));
    hash.update(ZERO);
  }
  return { sha256: hash.digest('hex'), names };
}

export function computeSdl3PatchsetDigest(root = ROOT) {
  const patchRoot = join(root, 'prebuilt', 'sdl3', 'patches');
  const seriesText = readFileSync(join(patchRoot, 'series'), 'utf8');
  const names = parseSdl3PatchSeries(seriesText);
  const patchTexts = new Map(names.map(name => [
    name, readFileSync(join(patchRoot, name)),
  ]));
  return digestSdl3PatchTexts(seriesText, patchTexts);
}

export function sdl3PatchsetMarker(sha256) {
  if (!/^[0-9a-f]{64}$/.test(String(sha256 ?? ''))) {
    throw new Error('SDL patchset marker requires 64 lowercase hex characters');
  }
  return Buffer.from(`amclps${sha256}`, 'ascii');
}

export function artifactEmbedsSdl3Patchset(bytes, sha256) {
  return Buffer.from(bytes).includes(sdl3PatchsetMarker(sha256));
}

if (process.argv[1] && resolve(process.argv[1]) ===
    resolve(fileURLToPath(import.meta.url))) {
  const report = computeSdl3PatchsetDigest();
  if (process.argv.includes('--json')) console.log(JSON.stringify(report));
  else console.log(report.sha256);
}

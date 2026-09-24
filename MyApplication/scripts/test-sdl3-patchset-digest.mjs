#!/usr/bin/env node
import assert from 'node:assert/strict';
import {
  artifactEmbedsSdl3Patchset,
  digestSdl3PatchTexts,
  parseSdl3PatchSeries,
  sdl3PatchsetMarker,
} from './sdl3-patchset-digest.mjs';

const series = '0001-a.patch\n0002-b.patch\n';
const patches = new Map([
  ['0001-a.patch', Buffer.from('alpha\n')],
  ['0002-b.patch', Buffer.from('beta\n')],
]);
const baseline = digestSdl3PatchTexts(series, patches).sha256;
assert.match(baseline, /^[0-9a-f]{64}$/);
assert.equal(digestSdl3PatchTexts(series, patches).sha256, baseline);

const changedBytes = new Map(patches);
changedBytes.set('0002-b.patch', Buffer.from('beta changed\n'));
assert.notEqual(digestSdl3PatchTexts(series, changedBytes).sha256, baseline);
assert.notEqual(digestSdl3PatchTexts(
  '0002-b.patch\n0001-a.patch\n', patches).sha256, baseline);
const marker = sdl3PatchsetMarker(baseline);
assert.equal(artifactEmbedsSdl3Patchset(
  Buffer.concat([Buffer.from('prefix'), marker, Buffer.from('suffix')]), baseline), true);
assert.equal(artifactEmbedsSdl3Patchset(Buffer.from('no marker'), baseline), false);

assert.throws(() => parseSdl3PatchSeries('../escape.patch\n'), /invalid/);
assert.throws(() => parseSdl3PatchSeries('0001-a.patch\n0001-a.patch\n'),
  /duplicate/);
assert.throws(() => digestSdl3PatchTexts(series,
  new Map([['0001-a.patch', 'alpha']])), /missing SDL patch bytes/);

console.log('test-sdl3-patchset-digest: deterministic/name/order/content/fail-closed cases passed');

#!/usr/bin/env node
import assert from 'node:assert/strict';
import { compareJniSurface, lwjglSourceIdentityProblems } from './check-lwjgl-native-surface.mjs';

// 身份负控不污染真实子仓：生产入口自己调用 git，纯判据只在这里接受明确夹具输入。
const sourceCommit = '32593afe25e2f1394c3425673f1b71a0122f5cd4';
assert.deepEqual(lwjglSourceIdentityProblems(sourceCommit, sourceCommit, ''), []);
assert.match(lwjglSourceIdentityProblems(sourceCommit, '0'.repeat(40), '').join(), /HEAD=/);
assert.match(lwjglSourceIdentityProblems(sourceCommit, sourceCommit, ' M modules/lwjgl/shaderc/src/generated/java/Shaderc.java\n').join(), /source is dirty/);
assert.match(lwjglSourceIdentityProblems('not-a-commit', sourceCommit, '').join(), /sourceCommit is malformed/);

const ordinary = 'Java_fixture_regularEntry';
const mandatory = new Map([
  ['liblwjgl_nanovg.so', 'Java_org_lwjgl_nanovg_LibNanoVG_setupMalloc'],
  ['liblwjgl_stb.so', 'Java_org_lwjgl_stb_LibSTB_setupMalloc'],
  ['liblwjgl_spng.so', 'Java_org_lwjgl_util_spng_LibSPNG_setupMalloc'],
  ['liblwjgl_vma.so', 'Java_org_lwjgl_util_vma_LibVma_setupMalloc'],
]);

for (const [library, setupMalloc] of mandatory) {
  const exact = compareJniSurface(library, new Set([ordinary]), new Set([ordinary, setupMalloc]));
  assert.deepEqual(exact, { missing: [], extra: [] }, `${library}: exact surface must pass`);

  const absent = compareJniSurface(library, new Set([ordinary]), new Set([ordinary]));
  assert.deepEqual(absent.missing, [setupMalloc], `${library}: missing setupMalloc must fail closed`);
  assert.deepEqual(absent.extra, []);
}

const foreign = compareJniSurface(
  'liblwjgl_spng.so',
  new Set([ordinary]),
  new Set([ordinary, mandatory.get('liblwjgl_stb.so'), mandatory.get('liblwjgl_spng.so')]),
);
assert.deepEqual(foreign.missing, []);
assert.deepEqual(foreign.extra, [mandatory.get('liblwjgl_stb.so')],
  'a setupMalloc entry is allowed only in its owning DSO');

const unexpected = compareJniSurface('liblwjgl.so', new Set([ordinary]),
  new Set([ordinary, 'Java_fixture_unexpected']));
assert.deepEqual(unexpected.missing, []);
assert.deepEqual(unexpected.extra, ['Java_fixture_unexpected']);

console.log('[test-lwjgl-native-surface] required setupMalloc and unexpected-extra cases passed');

#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { analyzePresentationPatch, loadPresentationPatch, analyzePresentationSources, loadPresentationSources } from './check-sdl3-presentation-contract.mjs';
import { extractPresentationHeader } from './extract-sdl3-presentation-header.mjs';
const real = loadPresentationPatch();
assert.equal(analyzePresentationPatch(real).ok, true);
const mutations = [
  ['broker->structSize >= AMCL_PRESENTATION_BROKER_SIZE', 'true'],
  ['broker->claimPresentation(native_window, generation, 1u, &token)', '(token = 3u)'],
  ['if (!destroy(context, surface))', 'if (false)'],
  ['owner->surfaces[i].native_window != native_window', 'false'],
  ['AMCL_PresentationLive(owner) != 0u', 'false'],
  ['AMCL_PresentationOwner presentation;', 'void *presentation;'],
  ['eglDestroySurface(_this->egl_data->egl_display, (EGLSurface)surface) != EGL_TRUE', 'eglDestroySurface(_this->egl_data->egl_display, (EGLSurface)surface) == EGL_TRUE'],
  ['owns_new_reference && !already_pending', 'owns_new_reference'],
  ['data->egl_surface = OPENHARMONY_AMCL_CreatePresentedSurface(_this, window, data, data);', 'data->egl_surface = SDL_EGL_CreateSurface(_this, window, data->native_window);'],
  ['new_surface = OPENHARMONY_AMCL_CreatePresentedSurface(_this, window, data, &candidate);', 'new_surface = SDL_EGL_CreateSurface(_this, window, candidate.native_window);'],
];
for (const [before, after] of mutations) {
  assert.ok(real.includes(before), 'negative fixture anchor exists: ' + before);
  assert.equal(analyzePresentationPatch(real.replaceAll(before, after)).ok, false, before);
}
const header = extractPresentationHeader(real);
assert.ok(header.includes('AMCL_PresentationRetire'));
assert.throws(() => extractPresentationHeader(real.replace('+++ b/src/video/openharmony/SDL_amclpresentation.h', '+++ b/other.h')));
assert.throws(() => extractPresentationHeader(real.replace('--- /dev/null', '--- a/old.h')));
const repoIndex = process.argv.indexOf('--repo');
if (repoIndex >= 0) {
  const repo = path.resolve(process.argv[repoIndex + 1]);
  const sources = loadPresentationSources(repo);
  assert.equal(analyzePresentationSources(sources).ok, true);
  assert.equal(header, fs.readFileSync(path.join(repo, 'src/video/openharmony/SDL_amclpresentation.h'), 'utf8'));
}
console.log('SDL presentation recipe negative fixtures and canonical header extraction PASS');
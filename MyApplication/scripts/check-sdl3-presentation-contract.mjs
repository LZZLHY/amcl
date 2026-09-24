#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { extractPresentationHeader } from './extract-sdl3-presentation-header.mjs';
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = fs.existsSync(path.resolve(scriptDir, '../../scripts/lib/source-noise.mjs'))
  ? path.resolve(scriptDir, '../..') : path.resolve(scriptDir, '..');
const { stripComments, stripStringLiterals } = await import(pathToFileURL(path.join(repoRoot, 'scripts/lib/source-noise.mjs')).href);
const paths = ['SDL_amclpresentation.h', 'SDL_openharmonyamcl.c', 'SDL_openharmonyamcl.h', 'SDL_openharmonywindow.c', 'SDL_openharmonywindow.h'];
export function loadPresentationSources(repo) {
  return new Map(paths.map((name) => [name, fs.readFileSync(path.join(repo, 'src/video/openharmony', name), 'utf8')]));
}
function functionBody(files, name) {
  for (const text of files.values()) {
    const code = stripComments(text, { lang: 'c' });
    const mask = stripStringLiterals(code, { lang: 'c' });
    const signature = new RegExp('\\b' + name + '\\s*\\([^;{}]*\\)\\s*\\{').exec(mask);
    if (!signature) continue;
    const open = signature.index + signature[0].length - 1;
    let depth = 1, end = open + 1;
    while (end < mask.length && depth) {
      if (mask[end] === '{') depth++;
      if (mask[end] === '}') depth--;
      end++;
    }
    if (depth) throw new Error('Unclosed function: ' + name);
    return code.slice(open, end);
  }
  throw new Error('Missing production function: ' + name);
}
export function analyzePresentationSources(files) {
  const failures = [];
  const passed = [];
  function check(name, condition) { (condition ? passed : failures).push(name); }
  try {
    for (const name of paths) if (!files.has(name)) throw new Error('Missing source: ' + name);
    const header = stripComments(files.get('SDL_openharmonywindow.h'), { lang: 'c' });
    const valid = functionBody(files, 'AMCL_PresentationBrokerValid');
    const create = functionBody(files, 'AMCL_PresentationCreate');
    const retire = functionBody(files, 'AMCL_PresentationRetire');
    const move = functionBody(files, 'AMCL_PresentationMove');
    const release = functionBody(files, 'AMCL_PresentationRelease');
    const bridge = functionBody(files, 'OPENHARMONY_AMCL_CreatePresentedSurface');
    const callback = functionBody(files, 'OPENHARMONY_AMCL_DestroySurfaceCallback');
    const construct = functionBody(files, 'OPENHARMONY_CreateWindow');
    const teardown = functionBody(files, 'OPENHARMONY_DestroyWindow');
    const recovery = functionBody(files, 'OPENHARMONY_AMCL_SyncBrokerWindow');
    const leaseRelease = functionBody(files, 'OPENHARMONY_AMCL_ReleaseNativeWindowLease');
    check('private-session-state', /AMCL_PresentationOwner\s+presentation\s*;/.test(header));
    check('append-only-tail-checked', valid.includes('structSize >= AMCL_PRESENTATION_BROKER_SIZE')
      && valid.includes('claimPresentation') && valid.includes('movePresentation') && valid.includes('releasePresentation'));
    check('claim-before-real-create', create.indexOf('claimPresentation(') >= 0
      && create.indexOf('claimPresentation(') < create.indexOf('create(context, native_window)'));
    check('real-create-bridge', bridge.includes('AMCL_PresentationCreate(&data->presentation')
      && bridge.includes('OPENHARMONY_AMCL_CreateSurfaceCallback'));
    check('driver-retirement-result', /eglDestroySurface\([^;]+\)\s*!=\s*EGL_TRUE/.test(callback));
    check('record-retired-after-driver', retire.indexOf('if (!destroy(context, surface))') >= 0
      && retire.indexOf('if (!destroy(context, surface))') < retire.indexOf('owner->surfaces[i].surface = NULL'));
    check('move-refuses-live-old-window', move.includes('owner->surfaces[i].native_window != native_window')
      && move.indexOf('owner->surfaces[i].native_window != native_window') < move.indexOf('movePresentation('));
    check('release-refuses-live-resources', release.includes('AMCL_PresentationLive(owner) != 0u')
      && release.indexOf('AMCL_PresentationLive(owner) != 0u') < release.indexOf('releasePresentation('));
    check('lease-copy-does-not-release-token', !/presentation|Presentation/.test(leaseRelease));
    const initialCreate = construct.indexOf('OPENHARMONY_AMCL_CreatePresentedSurface(');
    check('only-presented-gl-creates', initialCreate >= 0 && construct.indexOf('SDL_EGL_CreateOffscreenSurface(') < initialCreate
      && construct.lastIndexOf('if (window->flags & SDL_WINDOW_OPENGL)', initialCreate) >= 0);
    const lastRetire = recovery.lastIndexOf('OPENHARMONY_AMCL_RetireRecoverySurface(_this, data, old_surface');
    const lastMove = recovery.lastIndexOf('OPENHARMONY_AMCL_MovePresentation(data, candidate.native_window, generation)');
    const publish = recovery.lastIndexOf('data->native_window = candidate.native_window;');
    check('retire-move-publish-order', lastRetire >= 0 && lastRetire < lastMove && lastMove < publish);
    check('recovery-has-no-untracked-window-surfaces', !recovery.includes('SDL_EGL_CreateSurface(') && !recovery.includes('SDL_EGL_DestroySurface('));
    check('teardown-retire-release-lease-order',
      teardown.indexOf('OPENHARMONY_AMCL_RetirePresentedSurface(') >= 0
      && teardown.indexOf('OPENHARMONY_AMCL_RetirePresentedSurface(') < teardown.indexOf('OPENHARMONY_AMCL_ReleasePresentation(')
      && teardown.indexOf('OPENHARMONY_AMCL_ReleasePresentation(') < teardown.indexOf('OPENHARMONY_AMCL_ReleasePendingNativeWindowLease('));
    check('rollback-unbind-is-checked', recovery.includes('if (!SDL_EGL_MakeCurrent(_this, NULL, NULL))')
      && recovery.includes('OPENHARMONY_AMCL_AbortRecovery('));
    const preserve = functionBody(files, 'OPENHARMONY_AMCL_PreserveRecoveryCandidate');
    check('pending-reference-not-released-twice', preserve.includes('already_pending') && preserve.includes('owns_new_reference && !already_pending'));
    return { ok: failures.length === 0, passed, failures };
  } catch (error) { return { ok: false, passed, failures: [...failures, error.message] }; }
}
export function analyzePresentationPatch(patch) {
  const passed = [], failures = [];
  const check = (name, condition) => (condition ? passed : failures).push(name);
  try {
    const files = new Map([['header', extractPresentationHeader(patch)]]);
    const create = functionBody(files, 'AMCL_PresentationCreate');
    const retire = functionBody(files, 'AMCL_PresentationRetire');
    const move = functionBody(files, 'AMCL_PresentationMove');
    const release = functionBody(files, 'AMCL_PresentationRelease');
    const valid = functionBody(files, 'AMCL_PresentationBrokerValid');
    const added = stripComments(patch.split(/\r?\n/).filter((line) => line.startsWith('+') && !line.startsWith('+++'))
      .map((line) => line.slice(1)).join('\n'), { lang: 'c' });
    check('tail-size-check', valid.includes('structSize >= AMCL_PRESENTATION_BROKER_SIZE'));
    check('claim-before-create', create.indexOf('claimPresentation(') >= 0
      && create.indexOf('claimPresentation(') < create.indexOf('create(context, native_window)'));
    check('real-retire-before-record-removal', retire.indexOf('if (!destroy(context, surface))') >= 0
      && retire.indexOf('if (!destroy(context, surface))') < retire.indexOf('owner->surfaces[i].surface = NULL'));
    check('move-checks-old-resources', move.includes('owner->surfaces[i].native_window != native_window'));
    check('release-checks-live-resources', release.includes('AMCL_PresentationLive(owner) != 0u'));
    check('window-session-field', added.includes('AMCL_PresentationOwner presentation;'));
    check('initial-EGL-route', added.includes('data->egl_surface = OPENHARMONY_AMCL_CreatePresentedSurface(_this, window, data, data);'));
    check('recovery-EGL-route', added.includes('new_surface = OPENHARMONY_AMCL_CreatePresentedSurface(_this, window, data, &candidate);'));
    check('destroy-result-checked', /eglDestroySurface\([^;]+\)\s*!=\s*EGL_TRUE/.test(added));
    check('teardown-guard', added.includes('!OPENHARMONY_AMCL_RetirePresentedSurface(_this, data, data->egl_surface)')
      && added.includes('!OPENHARMONY_AMCL_ReleasePresentation(data)'));
    check('lease-preservation-guard', added.includes('owns_new_reference && !already_pending'));
    const oldRetire = added.lastIndexOf('OPENHARMONY_AMCL_RetireRecoverySurface(_this, data, old_surface');
    const transfer = added.lastIndexOf('OPENHARMONY_AMCL_MovePresentation(data, candidate.native_window, generation)');
    check('retire-before-transfer', oldRetire >= 0 && transfer > oldRetire);
    return { ok: failures.length === 0, passed, failures };
  } catch (error) { return { ok: false, passed, failures: [...failures, error.message] }; }
}
export function loadPresentationPatch(seriesPath = path.join(repoRoot, 'prebuilt/sdl3/patches/series')) {
  const names = fs.readFileSync(seriesPath, 'utf8').split(/\r?\n/).map((name) => name.trim())
    .filter((name) => name && !name.startsWith('#'));
  const selected = [];
  for (const name of names) {
    if (!/^\d{4}-[A-Za-z0-9._-]+\.patch$/.test(name) || name.includes('..')) throw new Error('Invalid patch-series name');
    const patch = fs.readFileSync(path.join(path.dirname(seriesPath), name), 'utf8');
    if (!patch.includes('+++ b/src/video/openharmony/SDL_amclpresentation.h')) continue;
    selected.push(patch);
  }
  if (!selected.length) throw new Error('Presentation session patch is missing from the SDL recipe');
  // 抽取器严格校验“唯一创建 + 按序修改”，允许新增能力以独立 follow-up patch 演进。
  const combined = selected.join('\n');
  extractPresentationHeader(combined);
  return combined;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const pos = process.argv.indexOf('--repo');
  const result = pos >= 0
    ? analyzePresentationSources(loadPresentationSources(path.resolve(process.argv[pos + 1])))
    : analyzePresentationPatch(loadPresentationPatch());
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.ok ? 0 : 1);
}

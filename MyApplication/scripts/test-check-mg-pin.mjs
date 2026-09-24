#!/usr/bin/env node
// Object-level fixture tests for scripts/check-mg-pin.mjs. The fixture creates
// four local bare repositories so provenance checks never depend on GitHub.

import { execFileSync, spawnSync } from 'node:child_process';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const SOURCE_GUARD = join(SCRIPT_DIR, 'check-mg-pin.mjs');
const LOCK_SOURCE = 'https://github.com/MobileGL-Dev/MobileGlues.git';
const LOCK_PLUGIN = 'https://github.com/MobileGL-Dev/MobileGlues-plugin.git';
const LOCK_RELEASE = 'https://github.com/MobileGL-Dev/MobileGlues-release.git';
const LOCK_FORK = 'https://github.com/LZZLHY/MobileGlues.git';
const BRANCH = 'amcl/2.0-ohos';
const FORK_TAG = 'amcl/mobileglues-2.0.0-ohos-r1';
const NO_PUSH = 'https://invalid.invalid/AMCL-DO-NOT-PUSH-OFFICIAL-MobileGlues.git';
// Mirrors REQUIRED_DIFF in check-mg-pin.mjs. Kept as [added, removed] pairs;
// the fixture materialises `removed` baseline lines and rewrites them with
// `added` new lines so `git diff --numstat` reproduces exactly these counts.
const PATCH_DIFF = new Map([
  ['MobileGlues-cpp/tests/buffer_readback_stub_before.inc', [12, 0]],
  ['MobileGlues-cpp/tests/buffer_readback_test.cpp.in', [107, 0]],
  ['MobileGlues-cpp/gl/buffer_readback_core.h', [42, 0]],
  ['MobileGlues-cpp/CMakeLists.txt', [165, 124]],
  ['MobileGlues-cpp/config/settings.cpp', [48, 4]],
  ['MobileGlues-cpp/config/settings.h', [25, 0]],
  ['MobileGlues-cpp/egl/context.cpp', [7, 0]],
  ['MobileGlues-cpp/egl/context.h', [19, 2]],
  ['MobileGlues-cpp/egl/egl.cpp', [376, 7]],
  ['MobileGlues-cpp/egl/loader.cpp', [11, 2]],
  ['MobileGlues-cpp/egl/loader.h', [1, 1]],
  ['MobileGlues-cpp/gl/ExtWrappers/DSAWrapper.cpp', [33, 8]],
  ['MobileGlues-cpp/gl/ExtWrappers/DSAWrapper.h', [2, 1]],
  ['MobileGlues-cpp/gl/FSR1/FSR1.cpp', [353, 353]],
  ['MobileGlues-cpp/gl/FSR1/FSR1.h', [26, 26]],
  ['MobileGlues-cpp/gl/buffer.cpp', [827, 32]],
  ['MobileGlues-cpp/gl/buffer.h', [17, 0]],
  ['MobileGlues-cpp/gl/buffer_contract_core.h', [124, 0]],
  ['MobileGlues-cpp/gl/drawing.cpp', [140, 259]],
  ['MobileGlues-cpp/gl/drawing.h', [1, 0]],
  ['MobileGlues-cpp/gl/frame_stats.h', [176, 0]],
  ['MobileGlues-cpp/gl/frame_stats_core.h', [617, 0]],
  ['MobileGlues-cpp/gl/framebuffer.cpp', [158, 184]],
  ['MobileGlues-cpp/gl/framebuffer.h', [3, 0]],
  ['MobileGlues-cpp/gl/getter.cpp', [47, 33]],
  ['MobileGlues-cpp/gl/gl.cpp', [21, 5]],
  ['MobileGlues-cpp/gl/gl_native.cpp', [19, 13]],
  ['MobileGlues-cpp/gl/gl_stub.cpp', [3, 4]],
  ['MobileGlues-cpp/gl/glsl/cache.cpp', [48, 31]],
  ['MobileGlues-cpp/gl/glsl/cache.h', [5, 1]],
  ['MobileGlues-cpp/gl/glsl/glsl_for_es.cpp', [532, 115]],
  ['MobileGlues-cpp/gl/glsl/glsl_for_es.h', [5, 3]],
  ['MobileGlues-cpp/gl/glsl/translation_state.h', [19, 0]],
  ['MobileGlues-cpp/gl/glsl/uniform_initializer_core.h', [588, 0]],
  ['MobileGlues-cpp/gl/index_rebase_core.h', [34, 0]],
  ['MobileGlues-cpp/gl/indirect_ring_core.h', [45, 0]],
  ['MobileGlues-cpp/gl/log.h', [22, 2]],
  ['MobileGlues-cpp/gl/mg.h', [7, 3]],
  ['MobileGlues-cpp/gl/multidraw.cpp', [168, 197]],
  ['MobileGlues-cpp/gl/pixel.cpp', [16, 34]],
  ['MobileGlues-cpp/gl/program.cpp', [283, 193]],
  ['MobileGlues-cpp/gl/program.h', [3, 0]],
  ['MobileGlues-cpp/gl/restart.cpp', [7, 29]],
  ['MobileGlues-cpp/gl/restart.h', [0, 4]],
  ['MobileGlues-cpp/gl/shader.cpp', [218, 102]],
  ['MobileGlues-cpp/gl/shader.h', [43, 11]],
  ['MobileGlues-cpp/gl/terrain_upload_core.h', [23, 0]],
  ['MobileGlues-cpp/gl/texture.cpp', [11, 3]],
  ['MobileGlues-cpp/gl/transfer.cpp', [131, 0]],
  ['MobileGlues-cpp/gl/upload_scheduler_core.h', [218, 0]],
  ['MobileGlues-cpp/gles/gles.h', [9, 0]],
  ['MobileGlues-cpp/gles/loader.cpp', [108, 3]],
  ['MobileGlues-cpp/gles/loader.h', [29, 4]],
  ['MobileGlues-cpp/glx/lookup.cpp', [49, 2]],
  ['MobileGlues-cpp/include/MG/init.h', [60, 0]],
  ['MobileGlues-cpp/includes.h', [3, 2]],
  ['MobileGlues-cpp/init.cpp', [4, 2]],
  ['MobileGlues-cpp/main.cpp', [123, 8]],
  ['MobileGlues-cpp/platform/driver_profile.cpp', [52, 0]],
  ['MobileGlues-cpp/platform/driver_profile.h', [19, 0]],
  ['MobileGlues-cpp/platform/driver_profile_core.h', [148, 0]],
  ['MobileGlues-cpp/tests/CMakeLists.txt', [50, 0]],
  ['MobileGlues-cpp/tests/framebuffer_shuffle_test.cpp', [63, 6]],
  ['MobileGlues-cpp/tests/pixel_size_test.cpp', [12, 0]],
  ['MobileGlues-cpp/tests/render_context_resources_test.cpp', [192, 0]],
  ['MobileGlues-cpp/tests/render_fsr_test.cpp', [415, 0]],
  ['MobileGlues-cpp/tests/render_resource_test.cpp', [179, 0]],
  ['MobileGlues-cpp/tests/render_shader_test.cpp', [426, 0]],
]);

function git(cwd, args) {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
}

function configureIdentity(repo) {
  git(repo, ['config', 'user.name', 'CI Fixture']);
  git(repo, ['config', 'user.email', 'ci-fixture@example.invalid']);
}

function initBare(path, sourceRepo, refspecs) {
  git(dirname(path), ['init', '--bare', '--quiet', path]);
  const remote = `fixture-${Math.random().toString(16).slice(2)}`;
  git(sourceRepo, ['remote', 'add', remote, path]);
  for (const refspec of refspecs) git(sourceRepo, ['push', '--quiet', '--force', remote, refspec]);
  git(sourceRepo, ['remote', 'remove', remote]);
  git(dirname(path), ['--git-dir', path, 'config', 'uploadpack.allowReachableSHA1InWant', 'true']);
  git(dirname(path), ['--git-dir', path, 'config', 'uploadpack.allowAnySHA1InWant', 'true']);
  git(dirname(path), ['--git-dir', path, 'config', 'remote.origin.url', path]);
}

function createNested(parent, relative, index) {
  const path = join(parent, ...relative.split('/'));
  mkdirSync(path, { recursive: true });
  git(path, ['init', '--quiet']);
  configureIdentity(path);
  writeFileSync(join(path, 'fixture.txt'), `nested ${index}\n`);
  git(path, ['add', 'fixture.txt']);
  git(path, ['commit', '--quiet', '-m', `nested ${index}`]);
  return git(path, ['rev-parse', 'HEAD']);
}

function writeChangedLines(root, path, count, prefix) {
  const target = join(root, ...path.split('/'));
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, Array.from({ length: count }, (_, index) =>
    `${prefix}-${path}-${index}\n`).join(''));
}

function expectStatus(result, expected, label, pattern) {
  const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (result.status !== expected || (pattern && !pattern.test(output))) {
    throw new Error(
      `${label}: expected status ${expected}${pattern ? ` and ${pattern}` : ''}, got ${result.status}\n${output}`,
    );
  }
  console.log(`[test-check-mg-pin] PASS: ${label}`);
}

function modulesText(branch = BRANCH) {
  return `[submodule "prebuilt/mobileglues/mg_src"]\n` +
    `\tpath = prebuilt/mobileglues/mg_src\n` +
    `\turl = ${LOCK_FORK}\n` +
    `\tbranch = ${branch}\n`;
}

function lockText(state, overrides = {}) {
  const v = { ...state, ...overrides };
  return `[mobileglues]
upstream = ${LOCK_SOURCE}
repo = ${LOCK_FORK}
branch = ${v.branch ?? BRANCH}
commit = ${v.commit}
base_commit = ${v.sourceMain}
source_branch = main
source_main_commit = ${v.sourceMain}
source_tree = ${v.sourceTree}
source_release_tag = none
android_renderer_commit = ${v.renderer}
android_plugin_repo = ${LOCK_PLUGIN}
android_plugin_branch = dev
android_plugin_commit = ${v.pluginCommit}
android_plugin_main_commit = ${v.pluginMain}
android_plugin_renderer_path = MobileGlues
release_repo = ${LOCK_RELEASE}
release_tag = V2.0.0
release_commit = ${v.releaseCommit}
nested_spirv_cross_commit = ${v.nested[0]}
nested_glslang_commit = ${v.nested[1]}
nested_perfetto_commit = ${v.nested[2]}
nested_xxhash_commit = ${v.nested[3]}
nested_ska_commit = ${v.nested[4]}
fork_release_tag = ${FORK_TAG}
fork_release_tag_commit = ${v.commit}
`;
}

const fixtureRoot = resolve(mkdtempSync(join(tmpdir(), 'amcl-mg-pin-')));
const submodule = join(fixtureRoot, 'prebuilt', 'mobileglues', 'mg_src');
const pluginWork = join(fixtureRoot, 'plugin-work');
const releaseWork = join(fixtureRoot, 'release-work');
const auditCache = join(fixtureRoot, 'audit-cache');
const remotes = {
  source: join(auditCache, 'source.git'),
  plugin: join(auditCache, 'plugin.git'),
  release: join(auditCache, 'release.git'),
  fork: join(auditCache, 'fork.git'),
};

let state;
let auditEnv;

function runGuard(args = [], extraEnv = {}) {
  return spawnSync(process.execPath, [join(fixtureRoot, 'scripts', 'check-mg-pin.mjs'), ...args], {
    cwd: fixtureRoot,
    encoding: 'utf8',
    env: { ...process.env, ...auditEnv, ...extraEnv },
  });
}

function lockedRemoteRewriteEnv() {
  const pairs = [
    [LOCK_SOURCE, remotes.source],
    [LOCK_PLUGIN, remotes.plugin],
    [LOCK_RELEASE, remotes.release],
    [LOCK_FORK, remotes.fork],
  ];
  const env = {
    MG_PIN_SOURCE_REMOTE: '',
    MG_PIN_PLUGIN_REMOTE: '',
    MG_PIN_RELEASE_REMOTE: '',
    MG_PIN_FORK_REMOTE: '',
    GIT_CONFIG_COUNT: String(pairs.length),
  };
  pairs.forEach(([locked, local], index) => {
    env[`GIT_CONFIG_KEY_${index}`] = `url.${pathToFileURL(local).href}.insteadOf`;
    env[`GIT_CONFIG_VALUE_${index}`] = locked;
  });
  return env;
}

try {
  mkdirSync(join(fixtureRoot, 'scripts'), { recursive: true });
  mkdirSync(join(fixtureRoot, 'prebuilt', 'mobileglues', 'patches'), { recursive: true });
  mkdirSync(submodule, { recursive: true });
  mkdirSync(pluginWork, { recursive: true });
  mkdirSync(releaseWork, { recursive: true });
  mkdirSync(auditCache, { recursive: true });
  copyFileSync(SOURCE_GUARD, join(fixtureRoot, 'scripts', 'check-mg-pin.mjs'));
  writeFileSync(join(fixtureRoot, 'prebuilt', 'mobileglues', 'patches', 'series'), '# fork model\n');
  writeFileSync(
    join(fixtureRoot, '.gitignore'),
    '/audit-cache/\n/plugin-work/\n/release-work/\n/source-super.git/\n/shallow-mg/\n',
  );

  git(fixtureRoot, ['init', '--quiet']);
  configureIdentity(fixtureRoot);
  git(submodule, ['init', '--quiet']);
  configureIdentity(submodule);
  git(submodule, ['remote', 'add', 'origin', LOCK_FORK]);

  const nestedPaths = [
    'MobileGlues-cpp/3rdparty/SPIRV-Cross',
    'MobileGlues-cpp/3rdparty/glslang',
    'MobileGlues-cpp/3rdparty/perfetto',
    'MobileGlues-cpp/3rdparty/xxhash',
    'MobileGlues-cpp/include/ska',
  ];
  const nested = nestedPaths.map((path, index) => createNested(submodule, path, index));
  mkdirSync(join(submodule, 'MobileGlues-cpp'), { recursive: true });
  writeFileSync(join(submodule, 'MobileGlues-cpp', 'fixture.txt'), 'renderer baseline\n');
  for (const [path, [, removed]] of PATCH_DIFF) {
    writeChangedLines(submodule, path, removed, 'old');
  }
  git(submodule, ['add', 'MobileGlues-cpp']);
  git(submodule, ['commit', '--quiet', '-m', 'renderer 2.0.0']);
  const renderer = git(submodule, ['rev-parse', 'HEAD']);
  git(submodule, ['commit', '--quiet', '--allow-empty', '-m', 'source main merge']);
  const sourceMain = git(submodule, ['rev-parse', 'HEAD']);
  const sourceTree = git(submodule, ['rev-parse', 'HEAD^{tree}']);

  const patchGroups = Array.from({ length: 26 }, () => []);
  [...PATCH_DIFF.entries()].forEach((entry, index) => patchGroups[index % patchGroups.length].push(entry));
  patchGroups.forEach((group, groupIndex) => {
    for (const [path, [added]] of group) writeChangedLines(submodule, path, added, 'new');
    git(submodule, ['add', '--', ...group.map(([path]) => path)]);
    git(submodule, ['commit', '--quiet', '-m', `downstream OHOS patch ${groupIndex + 1}`]);
  });
  const forkCommit = git(submodule, ['rev-parse', 'HEAD']);

  initBare(remotes.source, submodule, [`${sourceMain}:refs/heads/main`]);
  initBare(remotes.fork, submodule, [`${forkCommit}:refs/heads/${BRANCH}`]);

  git(pluginWork, ['init', '--quiet']);
  configureIdentity(pluginWork);
  git(pluginWork, ['update-index', '--add', '--cacheinfo', `160000,${renderer},MobileGlues`]);
  git(pluginWork, ['commit', '--quiet', '-m', 'plugin release 2.0.0']);
  const pluginCommit = git(pluginWork, ['rev-parse', 'HEAD']);
  git(pluginWork, ['commit', '--quiet', '--allow-empty', '-m', 'merge plugin dev']);
  const pluginMain = git(pluginWork, ['rev-parse', 'HEAD']);
  initBare(remotes.plugin, pluginWork, [
    `${pluginCommit}:refs/heads/dev`,
    `${pluginMain}:refs/heads/main`,
  ]);

  git(releaseWork, ['init', '--quiet']);
  configureIdentity(releaseWork);
  writeFileSync(join(releaseWork, 'README.md'), 'release index\n');
  git(releaseWork, ['add', 'README.md']);
  git(releaseWork, ['commit', '--quiet', '-m', 'release index 2.0.0']);
  const releaseCommit = git(releaseWork, ['rev-parse', 'HEAD']);
  git(releaseWork, ['tag', 'V2.0.0']);
  initBare(remotes.release, releaseWork, [
    `${releaseCommit}:refs/heads/main`,
    'refs/tags/V2.0.0:refs/tags/V2.0.0',
  ]);

  state = { commit: forkCommit, sourceMain, sourceTree, renderer, pluginCommit, pluginMain, releaseCommit, nested };
  auditEnv = {
    MG_PIN_SOURCE_REMOTE: remotes.source,
    MG_PIN_PLUGIN_REMOTE: remotes.plugin,
    MG_PIN_RELEASE_REMOTE: remotes.release,
    MG_PIN_FORK_REMOTE: remotes.fork,
  };
  writeFileSync(join(fixtureRoot, 'deps.lock'), lockText(state));
  writeFileSync(join(fixtureRoot, '.gitmodules'), modulesText());
  git(fixtureRoot, ['update-index', '--add', '--cacheinfo', `160000,${state.commit},prebuilt/mobileglues/mg_src`]);

  expectStatus(runGuard(), 0, 'online exact-object provenance succeeds', /source\/plugin\/renderer\/release provenance verified/);
  expectStatus(runGuard(['--require-release-tag']), 1, 'planned fork tag is required only on demand', /not published/);

  writeFileSync(join(fixtureRoot, 'deps.lock'), lockText(state, { sourceTree: '1'.repeat(40) }));
  expectStatus(runGuard(), 1, 'wrong locked source tree is rejected', /source tree .* != locked source_tree/);
  writeFileSync(join(fixtureRoot, 'deps.lock'), lockText(state));

  const badNested = [...nested];
  badNested[2] = '2'.repeat(40);
  writeFileSync(join(fixtureRoot, 'deps.lock'), lockText({ ...state, nested: badNested }));
  expectStatus(runGuard(), 1, 'nested gitlink drift is rejected', /perfetto gitlink .* != deps\.lock/);
  writeFileSync(join(fixtureRoot, 'deps.lock'), lockText(state));

  git(pluginWork, ['update-index', '--cacheinfo', `160000,${sourceMain},MobileGlues`]);
  git(pluginWork, ['commit', '--quiet', '-m', 'bad renderer link']);
  const badPlugin = git(pluginWork, ['rev-parse', 'HEAD']);
  git(pluginWork, ['commit', '--quiet', '--allow-empty', '-m', 'bad plugin merge']);
  const badPluginMain = git(pluginWork, ['rev-parse', 'HEAD']);
  git(pluginWork, ['push', '--quiet', '--force', remotes.plugin, `${badPlugin}:refs/heads/dev`]);
  git(pluginWork, ['push', '--quiet', '--force', remotes.plugin, `${badPluginMain}:refs/heads/main`]);
  writeFileSync(join(fixtureRoot, 'deps.lock'), lockText({ ...state, pluginCommit: badPlugin, pluginMain: badPluginMain }));
  expectStatus(runGuard(), 1, 'plugin to renderer relationship is object-verified', /links renderer .* expected/);
  git(pluginWork, ['push', '--quiet', '--force', remotes.plugin, `${pluginCommit}:refs/heads/dev`]);
  git(pluginWork, ['push', '--quiet', '--force', remotes.plugin, `${pluginMain}:refs/heads/main`]);
  writeFileSync(join(fixtureRoot, 'deps.lock'), lockText(state));

  git(fixtureRoot, ['--git-dir', remotes.fork, 'update-ref', `refs/heads/${BRANCH}`, renderer]);
  expectStatus(runGuard(), 1, 'fork branch must advertise pinned head', /fork branch .* advertises/);
  git(fixtureRoot, ['--git-dir', remotes.fork, 'update-ref', `refs/heads/${BRANCH}`, state.commit]);

  const setPinnedFixture = (commit) => {
    git(submodule, ['checkout', '--quiet', '--detach', commit]);
    git(submodule, ['push', '--quiet', '--force', remotes.fork, `${commit}:refs/heads/${BRANCH}`]);
    git(fixtureRoot, ['update-index', '--add', '--cacheinfo', `160000,${commit},prebuilt/mobileglues/mg_src`]);
    writeFileSync(join(fixtureRoot, 'deps.lock'), lockText({ ...state, commit }));
  };

  const oneShortCommit = git(submodule, ['rev-parse', `${state.commit}~1`]);
  setPinnedFixture(oneShortCommit);
  expectStatus(runGuard(), 1, 'one fewer downstream commit is rejected', /exactly 26 commits; got 25/);

  const lastGroup = patchGroups[patchGroups.length - 1];
  for (const [path, [added]] of lastGroup) writeChangedLines(submodule, path, added, 'new');
  writeChangedLines(submodule, 'MobileGlues-cpp/unreviewed.cpp', 1, 'unexpected');
  git(submodule, ['add', '--', ...lastGroup.map(([path]) => path), 'MobileGlues-cpp/unreviewed.cpp']);
  git(submodule, ['commit', '--quiet', '-m', 'downstream patch with unreviewed path']);
  const extraPathCommit = git(submodule, ['rev-parse', 'HEAD']);
  setPinnedFixture(extraPathCommit);
  expectStatus(runGuard(), 1, 'an unreviewed baseline path is rejected', /baseline changed files must be exactly/);

  git(submodule, ['checkout', '--quiet', '--detach', state.commit]);
  git(submodule, ['commit', '--quiet', '--allow-empty', '-m', 'unexpected extra downstream commit']);
  const oneOverCommit = git(submodule, ['rev-parse', 'HEAD']);
  setPinnedFixture(oneOverCommit);
  expectStatus(runGuard(), 1, 'one extra downstream commit is rejected', /exactly 26 commits; got 27/);
  setPinnedFixture(state.commit);

  const untracked = join(submodule, 'MobileGlues-cpp', 'untracked.h');
  writeFileSync(untracked, '// local only\n');
  expectStatus(runGuard(), 1, 'dirty MG source is rejected', /modified or untracked files/);
  expectStatus(runGuard(['--allow-dirty']), 0, '--allow-dirty is explicit', /dirty allowed/);
  rmSync(untracked);

  expectStatus(runGuard(['--offline']), 1, 'offline without cache is explicitly unverified', /UNVERIFIED/);
  expectStatus(
    runGuard(['--offline', `--audit-cache=${auditCache}`]),
    0,
    'offline cache verifies objects and refs',
    /mode=offline-cache/,
  );

  git(submodule, ['tag', '-a', FORK_TAG, '-m', 'immutable fixture release', state.commit]);
  git(submodule, ['push', '--quiet', remotes.fork, `refs/tags/${FORK_TAG}:refs/tags/${FORK_TAG}`]);
  expectStatus(runGuard(['--require-release-tag']), 0, 'annotated immutable fork tag is peeled and verified', /\[check-mg-pin] OK/);

  writeFileSync(join(fixtureRoot, '.gitmodules'), modulesText('wrong/branch'));
  expectStatus(runGuard(), 1, 'wrong submodule branch is rejected', /\.gitmodules branch/);
  writeFileSync(join(fixtureRoot, '.gitmodules'), modulesText());

  const gitMarker = join(submodule, '.git');
  const savedGitMarker = join(submodule, '.git.fixture-saved');
  renameSync(gitMarker, savedGitMarker);
  expectStatus(runGuard(), 1, 'missing submodule .git cannot fall back to parent', /is not initialized/);
  renameSync(savedGitMarker, gitMarker);

  git(submodule, ['remote', 'add', 'upstream', LOCK_SOURCE]);
  git(submodule, ['remote', 'set-url', '--push', 'upstream', NO_PUSH]);
  git(fixtureRoot, ['add', '.gitignore', '.gitmodules', 'deps.lock', 'scripts/check-mg-pin.mjs', 'prebuilt/mobileglues/patches/series']);
  git(fixtureRoot, ['commit', '--quiet', '-m', 'fixture superproject']);
  const superHead = git(fixtureRoot, ['rev-parse', 'HEAD']);
  const sourceSuper = join(fixtureRoot, 'source-super.git');
  initBare(sourceSuper, fixtureRoot, [`${superHead}:refs/heads/main`]);
  git(fixtureRoot, ['remote', 'add', 'origin', sourceSuper]);
  git(fixtureRoot, ['checkout', '--quiet', '--detach', superHead]);
  expectStatus(runGuard(['--release']), 1,
    'release mode rejects local audit-transport overrides', /--release forbids audit transport overrides/);
  const releaseEnv = lockedRemoteRewriteEnv();
  expectStatus(runGuard(['--release'], releaseEnv), 0,
    'detached immutable source commit is valid when origin/main matches', /mode=release/);

  git(fixtureRoot, ['remote', 'set-url', 'origin', 'https://github.com/LZZLHY/amcl.git']);
  expectStatus(runGuard(['--release'], releaseEnv), 1,
    'distribution repository cannot be the source origin', /distribution repository/);
  git(fixtureRoot, ['remote', 'set-url', 'origin', sourceSuper]);
  git(fixtureRoot, ['commit', '--quiet', '--allow-empty', '-m', 'unpublished source commit']);
  expectStatus(runGuard(['--release'], releaseEnv), 1,
    'detached source commit must be advertised by canonical main', /source origin main advertises/);

  const shallow = join(fixtureRoot, 'shallow-mg');
  git(fixtureRoot, ['clone', '--quiet', '--depth=1', '--branch', BRANCH, pathToFileURL(remotes.fork).href, shallow]);
  const originalGit = join(submodule, '.git.original');
  renameSync(join(submodule, '.git'), originalGit);
  renameSync(join(shallow, '.git'), join(submodule, '.git'));
  expectStatus(runGuard(), 1, 'shallow checkout missing renderer object fails with fetch guidance', /renderer.*(unavailable|fetch|failed)/i);
  renameSync(join(submodule, '.git'), join(shallow, '.git'));
  renameSync(originalGit, join(submodule, '.git'));
} finally {
  const tempRoot = resolve(tmpdir()).toLowerCase();
  if (!fixtureRoot.toLowerCase().startsWith(`${tempRoot}\\`) &&
      !fixtureRoot.toLowerCase().startsWith(`${tempRoot}/`)) {
    throw new Error(`refusing to remove fixture outside OS temp: ${fixtureRoot}`);
  }
  rmSync(fixtureRoot, { recursive: true, force: true });
}

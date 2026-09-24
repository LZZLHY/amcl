#!/usr/bin/env node
// Fail-closed provenance and checkout guard for the embedded MobileGlues fork.
//
// Normal mode validates the locked source/plugin/release object relationships,
// fork branch, gitlink, checked-out HEAD and worktree. Remote object audits are
// online by default. `--offline --audit-cache=<dir>` requires four auditable
// bare repositories: source.git, plugin.git, release.git and fork.git.
//
// `--release` adds publication requirements: the planned immutable MG fork tag
// must exist, and this superproject must be a clean `main` checkout published to
// a real source remote (never the separate LZZLHY/amcl distribution repository).

import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(SCRIPT_DIR, '..');
const SUBMODULE_PATH = 'prebuilt/mobileglues/mg_src';
const SUBMODULE_DIR = join(PROJECT_ROOT, ...SUBMODULE_PATH.split('/'));
const REQUIRED_BRANCH = 'amcl/2.0-ohos';
const REQUIRED_SOURCE_BRANCH = 'main';
const REQUIRED_RELEASE_TAG = 'V2.0.0';
// Six build/embed/toolchain commits, two in the GLSL-to-ESSL translator,
// and one reviewed OHOS buffer-lifecycle/diagnostics commit. The translator pair
// provides ESSL conformance for dynamically indexed fragment output arrays and
// keys persisted translations on translator behaviour. The ninth commit adds
// requested/effective buffer contracts, generation-safe lifecycle tracking,
// selective frame statistics, a fail-closed default-off upload scheduler seam,
// an indirect-buffer ring, and explicit OHOS/provider identity. The tenth
// classifies glClientWaitSync by timeout/flags/result (frame statistics
// schema 4, compiled out when AMCL_MG_FRAME_STATS is off). The eleventh adds
// opt-in present pacing consumed from AMCL_MG_FRAME_PACING_FPS at the shared
// present boundary, with a one-shot effective-value readback log. The twelfth
// advertises GL_ARB_draw_indirect / GL_ARB_multi_draw_indirect (capability-
// gated) so RenderPearl can use batched terrain submission;
// AMCL_MG_EXPOSE_INDIRECT_DRAW=0 is the A/B kill switch. The thirteenth
// completes the trio: GL_ARB_base_instance is advertised only when native
// GL_EXT_base_instance and its three entry points exist, the draw family then
// forwards nonzero baseinstance instead of dropping it, and the
// [MG-BASE-INSTANCE] probe line prints unconditionally;
// AMCL_MG_EXPOSE_BASE_INSTANCE=0 is the kill switch. The fourteenth adds the
// "force" state to that switch (advertise on resolved EXT symbols even when
// the driver omits the extension string -- Maleoon does exactly that); the
// default remains string-gated auto. The fifteenth makes frame statistics able
// to attribute a slow frame on a pre-1.20 client: Category::BufferAllocation
// moves from the causal set to the always-on set (glBufferData and friends gain
// the explicit scope the other buffer entries already had), and presentEnd()
// gains a fifth arming trigger -- the slow frame itself -- because the other
// four are GL event driven and such a client produces none of them. The arming
// bound is unchanged, so this cannot become exhaustive timing. The sixteenth is
// diagnostic only and is the first commit to touch gl/transfer.cpp: it counts the
// (format, type) pairs arriving at mg_upload_fix_t so the two upload paths can be
// told apart on a real client -- the fast one hands the caller's pointer to the
// driver untouched, the conversion one runs a per-pixel loop plus twelve
// glPixelStorei calls. It reads no clock, allocates nothing and issues no GL call.
// The seventeenth separates the two things AMCL_MG_FRAME_STATS used to control at
// once, whose cost differs by three to five orders of magnitude: the
// present-boundary ledger (one clock pair per frame) and the scope LOG() installs
// on every GL wrapper. AMCL_MG_FRAME_STATS_GL_SCOPES=0 deletes the wrapper scopes
// while the report keeps emitting fps and frame-time, which is what makes an A/B of
// the observer possible -- turning the whole thing off also removed the frame rate
// it would be measured against, so it never was. What went unmeasured: presentEnd()
// arms the causal window on any frame >= 25 ms, so below 40 fps every frame re-arms
// it, and always-selected BufferAllocation has no window at all (fifteen strcmp
// plus two clock reads per glBufferData, the whole per-frame buffer path on a
// pre-1.20 client). The sixteenth commit's probe gets the same switch, and its
// "cannot become an observer effect" note is withdrawn: per-call cheapness is not
// freeness when the multiplier is every texture upload. Shipping default for both
// new switches is off; the exhaustive mode plus scopes=0 is a compile error rather
// than a silent resolution.
// The nineteenth is the third commit in the GLSL-to-ESSL translator, and the
// first one that fixes a defect this fork introduced nothing of:
// process_uniform_declarations() matched `uniform` as a substring at any
// character position and called any `=` before the next `;` an initializer, so
// on SPIRV-Cross output it started inside `_uniform_instance_00_01`, accepted
// the `==` of an `if` condition, and deleted the condition together with the
// first local declaration of the branch. That is twelve unusable terrain
// fragment programs on Minecraft 26.3 snapshot 9 and an immediate exit, from
// shaders that contained no uniform initializer at all. The rewriter is now a
// linear lexer in the new gl/glsl/uniform_initializer_core.h that only touches
// what it can prove: `uniform` as a whole identifier token, global scope only
// (brace/paren/bracket depth), a simple declarator, a lone `=` at exactly the
// next token position rather than anywhere in the text, and the terminating `;`
// found with the same lexer. Everything else is left byte for byte and counted
// by reason. It carries no platform, driver or application condition and is an
// upstream candidate. GLSL_TRANSLATOR_REVISION goes 1 -> 2 because the corrupted
// translations are already persisted on devices, and its evidence literal is
// enforced by check-mg-build-contract.mjs. This commit is why the diff surface
// below has 37 files rather than 36.
//
// The exact diff surface below is intentionally exhaustive: increasing the
// commit count must never let an unreviewed path enter beside the approved work.
// 第26个提交补齐真实GPU buffer读回；核心、ARB与DSA共用有界资源生命周期。
const REQUIRED_PATCH_COUNT = '26';
const OFFICIAL_SOURCE = 'https://github.com/mobilegl-dev/mobileglues';
const OFFICIAL_PLUGIN = 'https://github.com/mobilegl-dev/mobileglues-plugin';
const OFFICIAL_RELEASE = 'https://github.com/mobilegl-dev/mobileglues-release';
const AMCL_FORK = 'https://github.com/lzzlhy/mobileglues';
const DISTRIBUTION_REPO = 'https://github.com/lzzlhy/amcl';
const UPSTREAM_NO_PUSH = 'https://invalid.invalid/AMCL-DO-NOT-PUSH-OFFICIAL-MobileGlues.git';
const REQUIRED_DIFF = new Map([
  ['MobileGlues-cpp/tests/buffer_readback_stub_before.inc', '12\t0'],
  ['MobileGlues-cpp/tests/buffer_readback_test.cpp.in', '107\t0'],
  ['MobileGlues-cpp/gl/buffer_readback_core.h', '42\t0'],
  ['MobileGlues-cpp/CMakeLists.txt', '165\t124'],
  ['MobileGlues-cpp/config/settings.cpp', '48\t4'],
  ['MobileGlues-cpp/config/settings.h', '25\t0'],
  ['MobileGlues-cpp/egl/context.cpp', '7\t0'],
  ['MobileGlues-cpp/egl/context.h', '19\t2'],
  ['MobileGlues-cpp/egl/egl.cpp', '376\t7'],
  ['MobileGlues-cpp/egl/loader.cpp', '11\t2'],
  ['MobileGlues-cpp/egl/loader.h', '1\t1'],
  ['MobileGlues-cpp/gl/ExtWrappers/DSAWrapper.cpp', '33\t8'],
  ['MobileGlues-cpp/gl/ExtWrappers/DSAWrapper.h', '2\t1'],
  ['MobileGlues-cpp/gl/FSR1/FSR1.cpp', '353\t353'],
  ['MobileGlues-cpp/gl/FSR1/FSR1.h', '26\t26'],
  ['MobileGlues-cpp/gl/buffer.cpp', '827\t32'],
  ['MobileGlues-cpp/gl/buffer.h', '17\t0'],
  ['MobileGlues-cpp/gl/buffer_contract_core.h', '124\t0'],
  ['MobileGlues-cpp/gl/drawing.cpp', '140\t259'],
  ['MobileGlues-cpp/gl/drawing.h', '1\t0'],
  ['MobileGlues-cpp/gl/frame_stats.h', '176\t0'],
  ['MobileGlues-cpp/gl/frame_stats_core.h', '617\t0'],
  ['MobileGlues-cpp/gl/framebuffer.cpp', '158\t184'],
  ['MobileGlues-cpp/gl/framebuffer.h', '3\t0'],
  ['MobileGlues-cpp/gl/getter.cpp', '47\t33'],
  ['MobileGlues-cpp/gl/gl.cpp', '21\t5'],
  ['MobileGlues-cpp/gl/gl_native.cpp', '19\t13'],
  ['MobileGlues-cpp/gl/gl_stub.cpp', '3\t4'],
  ['MobileGlues-cpp/gl/glsl/cache.cpp', '48\t31'],
  ['MobileGlues-cpp/gl/glsl/cache.h', '5\t1'],
  ['MobileGlues-cpp/gl/glsl/glsl_for_es.cpp', '532\t115'],
  ['MobileGlues-cpp/gl/glsl/glsl_for_es.h', '5\t3'],
  ['MobileGlues-cpp/gl/glsl/translation_state.h', '19\t0'],
  ['MobileGlues-cpp/gl/glsl/uniform_initializer_core.h', '588\t0'],
  ['MobileGlues-cpp/gl/index_rebase_core.h', '34\t0'],
  ['MobileGlues-cpp/gl/indirect_ring_core.h', '45\t0'],
  ['MobileGlues-cpp/gl/log.h', '22\t2'],
  ['MobileGlues-cpp/gl/mg.h', '7\t3'],
  ['MobileGlues-cpp/gl/multidraw.cpp', '168\t197'],
  ['MobileGlues-cpp/gl/pixel.cpp', '16\t34'],
  ['MobileGlues-cpp/gl/program.cpp', '283\t193'],
  ['MobileGlues-cpp/gl/program.h', '3\t0'],
  ['MobileGlues-cpp/gl/restart.cpp', '7\t29'],
  ['MobileGlues-cpp/gl/restart.h', '0\t4'],
  ['MobileGlues-cpp/gl/shader.cpp', '218\t102'],
  ['MobileGlues-cpp/gl/shader.h', '43\t11'],
  ['MobileGlues-cpp/gl/terrain_upload_core.h', '23\t0'],
  ['MobileGlues-cpp/gl/texture.cpp', '11\t3'],
  ['MobileGlues-cpp/gl/transfer.cpp', '131\t0'],
  ['MobileGlues-cpp/gl/upload_scheduler_core.h', '218\t0'],
  ['MobileGlues-cpp/gles/gles.h', '9\t0'],
  ['MobileGlues-cpp/gles/loader.cpp', '108\t3'],
  ['MobileGlues-cpp/gles/loader.h', '29\t4'],
  ['MobileGlues-cpp/glx/lookup.cpp', '49\t2'],
  ['MobileGlues-cpp/include/MG/init.h', '60\t0'],
  ['MobileGlues-cpp/includes.h', '3\t2'],
  ['MobileGlues-cpp/init.cpp', '4\t2'],
  ['MobileGlues-cpp/main.cpp', '123\t8'],
  ['MobileGlues-cpp/platform/driver_profile.cpp', '52\t0'],
  ['MobileGlues-cpp/platform/driver_profile.h', '19\t0'],
  ['MobileGlues-cpp/platform/driver_profile_core.h', '148\t0'],
  ['MobileGlues-cpp/tests/CMakeLists.txt', '50\t0'],
  ['MobileGlues-cpp/tests/framebuffer_shuffle_test.cpp', '63\t6'],
  ['MobileGlues-cpp/tests/pixel_size_test.cpp', '12\t0'],
  ['MobileGlues-cpp/tests/render_context_resources_test.cpp', '192\t0'],
  ['MobileGlues-cpp/tests/render_fsr_test.cpp', '415\t0'],
  ['MobileGlues-cpp/tests/render_resource_test.cpp', '179\t0'],
  ['MobileGlues-cpp/tests/render_shader_test.cpp', '426\t0'],
]);
const NESTED_PATHS = new Map([
  ['nested_spirv_cross_commit', 'MobileGlues-cpp/3rdparty/SPIRV-Cross'],
  ['nested_glslang_commit', 'MobileGlues-cpp/3rdparty/glslang'],
  ['nested_perfetto_commit', 'MobileGlues-cpp/3rdparty/perfetto'],
  ['nested_xxhash_commit', 'MobileGlues-cpp/3rdparty/xxhash'],
  ['nested_ska_commit', 'MobileGlues-cpp/include/ska'],
]);

const cli = process.argv.slice(2);
const ALLOW_DIRTY = cli.includes('--allow-dirty');
const OFFLINE = cli.includes('--offline');
const RELEASE_MODE = cli.includes('--release');
const REQUIRE_RELEASE_TAG = RELEASE_MODE || cli.includes('--require-release-tag');
const cacheArg = cli.find(arg => arg.startsWith('--audit-cache='));
const AUDIT_CACHE = cacheArg?.slice('--audit-cache='.length) || process.env.MG_PIN_AUDIT_CACHE || '';
const knownArgs = new Set(['--allow-dirty', '--offline', '--release', '--require-release-tag']);
for (const arg of cli) {
  if (!knownArgs.has(arg) && !arg.startsWith('--audit-cache=')) {
    console.error(`[check-mg-pin] ERROR: unknown argument: ${arg}`);
    process.exitCode = 1;
  }
}
const REMOTE_OVERRIDE_ENV = [
  'MG_PIN_SOURCE_REMOTE',
  'MG_PIN_PLUGIN_REMOTE',
  'MG_PIN_RELEASE_REMOTE',
  'MG_PIN_FORK_REMOTE',
];
if (RELEASE_MODE) {
  const activeOverrides = REMOTE_OVERRIDE_ENV.filter(name => process.env[name]?.trim());
  if (activeOverrides.length) {
    console.error(
      `[check-mg-pin] ERROR: --release forbids audit transport overrides: ${activeOverrides.join(', ')}`,
    );
    process.exitCode = 1;
  }
}

function fail(message) {
  console.error(`[check-mg-pin] ERROR: ${message}`);
  process.exitCode = 1;
}

function warn(message) {
  console.warn(`[check-mg-pin] WARNING: ${message}`);
}

function gitResult(args, cwd = PROJECT_ROOT, childEnv = process.env) {
  const result = spawnSync('git', args, {
    cwd,
    env: childEnv,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return {
    ok: result.status === 0,
    stdout: (result.stdout ?? '').trim(),
    stderr: (result.stderr ?? '').trim(),
    status: result.status,
  };
}

function git(args, cwd = PROJECT_ROOT, label = `git ${args.join(' ')}`) {
  const result = gitResult(args, cwd);
  if (!result.ok) {
    fail(`${label} failed: ${result.stderr || `exit ${result.status}`}`);
    return '';
  }
  return result.stdout;
}

function parseSection(text, sectionName) {
  const values = new Map();
  let inSection = false;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    const section = line.match(/^\[([^\]]+)]$/);
    if (section) {
      inSection = section[1] === sectionName;
      continue;
    }
    if (!inSection || line === '' || line.startsWith('#')) continue;
    const match = rawLine.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*(?:#.*)?$/);
    if (match) values.set(match[1], match[2].trim());
  }
  return values;
}

function canonicalGitUrl(value) {
  return value
    .trim()
    .replace(/^git@github\.com:/i, 'https://github.com/')
    .replace(/\\/g, '/')
    .replace(/\.git$/i, '')
    .replace(/\/$/, '')
    .toLowerCase();
}

function sourceRemoteAuthEnvironment(origin) {
  const token = process.env.AMCL_SOURCE_READ_TOKEN?.trim();
  if (!token) return process.env;
  const expectedRepository = process.env.AMCL_EXPECTED_SOURCE_REPOSITORY?.trim();
  if (!expectedRepository || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(expectedRepository)) {
    fail('AMCL_SOURCE_READ_TOKEN requires a valid AMCL_EXPECTED_SOURCE_REPOSITORY=owner/repo');
    return process.env;
  }
  const expectedUrl = `https://github.com/${expectedRepository}`;
  if (canonicalGitUrl(origin) !== canonicalGitUrl(expectedUrl) ||
      !/^https:\/\/github\.com\//i.test(origin)) {
    fail('refusing to send source read credentials to a remote other than the expected HTTPS GitHub source repository');
    return process.env;
  }

  const childEnv = { ...process.env };
  delete childEnv.AMCL_SOURCE_READ_TOKEN;
  delete childEnv.AMCL_EXPECTED_SOURCE_REPOSITORY;
  const parsedCount = Number.parseInt(childEnv.GIT_CONFIG_COUNT ?? '0', 10);
  const configCount = Number.isInteger(parsedCount) && parsedCount >= 0 ? parsedCount : 0;
  childEnv.GIT_CONFIG_COUNT = String(configCount + 1);
  childEnv[`GIT_CONFIG_KEY_${configCount}`] = `http.${origin}.extraHeader`;
  childEnv[`GIT_CONFIG_VALUE_${configCount}`] =
    `AUTHORIZATION: basic ${Buffer.from(`x-access-token:${token}`).toString('base64')}`;
  return childEnv;
}

function requireField(section, key) {
  const value = section.get(key) ?? '';
  if (value === '' || value === 'PENDING') fail(`deps.lock [mobileglues].${key} is empty or PENDING`);
  return value;
}

function requireSha(name, value) {
  if (!/^[0-9a-f]{40}$/.test(value)) {
    fail(`deps.lock [mobileglues].${name} is not a lowercase 40-character SHA-1: ${value}`);
  }
}

function parseGitlink(line, expectedPath, label) {
  const match = line.match(/^160000 commit ([0-9a-f]{40})\t(.+)$/);
  if (!match || match[2] !== expectedPath) {
    fail(`${label} is not a gitlink at ${expectedPath}: ${line || '(missing)'}`);
    return '';
  }
  return match[1];
}

function bareGit(gitDir, args, label) {
  return git(['--git-dir', gitDir, ...args], PROJECT_ROOT, label);
}

function inspectSourceObjects(read, label, lock) {
  const sourceType = read(['cat-file', '-t', `${lock.sourceMainCommit}^{commit}`], `${label} source commit`);
  const rendererType = read(['cat-file', '-t', `${lock.rendererCommit}^{commit}`], `${label} renderer commit`);
  if (sourceType !== 'commit') fail(`${label} source object is not a commit: ${sourceType || '(missing)'}`);
  if (rendererType !== 'commit') fail(`${label} renderer object is not a commit: ${rendererType || '(missing)'}`);

  const sourceTree = read(['rev-parse', `${lock.sourceMainCommit}^{tree}`], `${label} source tree`);
  const rendererTree = read(['rev-parse', `${lock.rendererCommit}^{tree}`], `${label} renderer tree`);
  if (sourceTree !== lock.sourceTree) {
    fail(`${label} source tree ${sourceTree || '(missing)'} != locked source_tree ${lock.sourceTree}`);
  }
  if (rendererTree !== lock.sourceTree) {
    fail(`${label} renderer tree ${rendererTree || '(missing)'} != locked source_tree ${lock.sourceTree}`);
  }

  const parentLine = read(
    ['rev-list', '--parents', '-n', '1', lock.sourceMainCommit],
    `${label} source parent relationship`,
  );
  if (!parentLine.split(/\s+/).slice(1).includes(lock.rendererCommit)) {
    fail(`${label} source main ${lock.sourceMainCommit} does not have renderer ${lock.rendererCommit} as a parent`);
  }

  for (const [field, path] of NESTED_PATHS) {
    const actual = parseGitlink(
      read(['ls-tree', lock.sourceMainCommit, '--', path], `${label} nested gitlink ${path}`),
      path,
      `${label} nested dependency`,
    );
    if (actual && actual !== lock.section.get(field)) {
      fail(`${label} ${path} gitlink ${actual} != deps.lock ${field} ${lock.section.get(field)}`);
    }
  }
}

function inspectPluginObjects(read, label, lock) {
  for (const commit of [lock.pluginCommit, lock.pluginMainCommit]) {
    const type = read(['cat-file', '-t', `${commit}^{commit}`], `${label} plugin commit ${commit}`);
    if (type !== 'commit') fail(`${label} plugin object ${commit} is not a commit`);
    const actual = parseGitlink(
      read(['ls-tree', commit, '--', lock.pluginRendererPath], `${label} plugin renderer gitlink`),
      lock.pluginRendererPath,
      `${label} plugin renderer`,
    );
    if (actual && actual !== lock.rendererCommit) {
      fail(`${label} plugin ${commit} links renderer ${actual}, expected ${lock.rendererCommit}`);
    }
  }
  const releaseTree = read(['rev-parse', `${lock.pluginCommit}^{tree}`], `${label} plugin release tree`);
  const mainTree = read(['rev-parse', `${lock.pluginMainCommit}^{tree}`], `${label} plugin main tree`);
  if (releaseTree !== mainTree) {
    fail(`${label} plugin release tree ${releaseTree} != plugin main merge tree ${mainTree}`);
  }
}

function remoteOverride(envName, lockedUrl) {
  const override = process.env[envName]?.trim();
  if (override) {
    warn(`${envName} overrides audit transport only; deps.lock provenance remains ${lockedUrl}`);
    return override;
  }
  return lockedUrl;
}

function remoteTagCommit(url, tag, label) {
  const result = gitResult(['ls-remote', '--tags', url, `refs/tags/${tag}`, `refs/tags/${tag}^{}`]);
  if (!result.ok) {
    fail(`${label} remote audit failed: ${result.stderr || `exit ${result.status}`}`);
    return '';
  }
  const refs = new Map(result.stdout.split(/\r?\n/).filter(Boolean).map(line => {
    const [sha, ref] = line.split(/\s+/);
    return [ref, sha];
  }));
  return refs.get(`refs/tags/${tag}^{}`) || refs.get(`refs/tags/${tag}`) || '';
}

function remoteHead(url, ref, label, allowMissing = false, childEnv = process.env) {
  const result = gitResult(['ls-remote', url, ref], PROJECT_ROOT, childEnv);
  if (!result.ok) {
    fail(`${label} remote audit failed: ${result.stderr || `exit ${result.status}`}`);
    return '';
  }
  const sha = result.stdout.split(/\s+/)[0] || '';
  if (!sha && !allowMissing) fail(`${label} does not advertise ${ref}`);
  return sha;
}

function validateAuditRemote(gitDir, expectedUrl, label) {
  const actual = bareGit(gitDir, ['config', '--get', 'remote.origin.url'], `${label} cache origin`);
  if (actual && canonicalGitUrl(actual) !== canonicalGitUrl(expectedUrl)) {
    fail(`${label} cache origin ${actual} != expected audit transport ${expectedUrl}`);
  }
}

function cachedRefCommit(gitDir, ref) {
  const result = gitResult(['--git-dir', gitDir, 'rev-parse', '--verify', `${ref}^{commit}`]);
  return result.ok ? result.stdout : '';
}

function auditFromCache(lock, remotes) {
  if (!AUDIT_CACHE) {
    fail('offline mode is UNVERIFIED without --audit-cache=<dir> (or MG_PIN_AUDIT_CACHE)');
    return;
  }
  const cacheRoot = resolve(AUDIT_CACHE);
  const dirs = {
    source: join(cacheRoot, 'source.git'),
    plugin: join(cacheRoot, 'plugin.git'),
    release: join(cacheRoot, 'release.git'),
    fork: join(cacheRoot, 'fork.git'),
  };
  for (const [name, path] of Object.entries(dirs)) {
    if (!existsSync(path)) fail(`offline audit cache is missing ${name}.git: ${path}`);
  }
  if (process.exitCode) return;

  validateAuditRemote(dirs.source, remotes.source, 'source');
  validateAuditRemote(dirs.plugin, remotes.plugin, 'plugin');
  validateAuditRemote(dirs.release, remotes.release, 'release-index');
  validateAuditRemote(dirs.fork, remotes.fork, 'fork');
  inspectSourceObjects((args, label) => bareGit(dirs.source, args, label), 'cached official', lock);
  inspectPluginObjects((args, label) => bareGit(dirs.plugin, args, label), 'cached official', lock);

  const officialTag = cachedRefCommit(dirs.release, `refs/tags/${lock.releaseTag}`);
  if (officialTag !== lock.releaseCommit) {
    fail(`cached release tag ${lock.releaseTag} resolves to ${officialTag || '(missing)'}, expected ${lock.releaseCommit}`);
  }
  const forkHead = cachedRefCommit(dirs.fork, `refs/heads/${lock.branch}`);
  if (forkHead !== lock.commit) {
    fail(`cached fork branch ${lock.branch} resolves to ${forkHead || '(missing)'}, expected ${lock.commit}`);
  }
  const forkTag = cachedRefCommit(dirs.fork, `refs/tags/${lock.forkReleaseTag}`);
  validateForkTag(forkTag, lock);
}

function initAuditRepo(root, name, url, commits) {
  const gitDir = join(root, `${name}.git`);
  git(['init', '--bare', '--quiet', gitDir], PROJECT_ROOT, `initialize ${name} audit repository`);
  bareGit(gitDir, ['remote', 'add', 'origin', url], `${name} audit origin`);
  const fetch = gitResult([
    '--git-dir', gitDir,
    'fetch', '--quiet', '--no-tags', '--depth=2', '--filter=blob:none',
    'origin', ...commits,
  ]);
  if (!fetch.ok) {
    fail(
      `${name} exact-object fetch failed (${url}): ${fetch.stderr || `exit ${fetch.status}`}. ` +
      'For an auditable offline run, prepare the documented four-repository cache and use --offline.',
    );
  }
  return gitDir;
}

function validateForkTag(actual, lock) {
  if (!actual) {
    const message = `planned immutable fork tag ${lock.forkReleaseTag} is not published`;
    if (REQUIRE_RELEASE_TAG) fail(`${message}; create it at ${lock.forkReleaseCommit} before release`);
    else warn(`${message}; development pin is valid, --release will require it`);
  } else if (actual !== lock.forkReleaseCommit) {
    fail(`fork tag ${lock.forkReleaseTag} resolves to ${actual}, expected ${lock.forkReleaseCommit}`);
  }
}

function auditOnline(lock, remotes) {
  let auditRoot = '';
  try {
    auditRoot = mkdtempSync(join(tmpdir(), 'amcl-mg-pin-audit-'));
    const sourceGit = initAuditRepo(
      auditRoot,
      'source',
      remotes.source,
      [lock.sourceMainCommit, lock.rendererCommit],
    );
    const pluginGit = initAuditRepo(
      auditRoot,
      'plugin',
      remotes.plugin,
      [lock.pluginCommit, lock.pluginMainCommit],
    );
    if (!process.exitCode) {
      inspectSourceObjects((args, label) => bareGit(sourceGit, args, label), 'remote official', lock);
      inspectPluginObjects((args, label) => bareGit(pluginGit, args, label), 'remote official', lock);
    }

    const releaseCommit = remoteTagCommit(remotes.release, lock.releaseTag, 'official release-index');
    if (releaseCommit !== lock.releaseCommit) {
      fail(`official release-index tag ${lock.releaseTag} resolves to ${releaseCommit || '(missing)'}, expected ${lock.releaseCommit}`);
    }

    const sourceHead = remoteHead(remotes.source, `refs/heads/${lock.sourceBranch}`, 'official source');
    if (sourceHead && sourceHead !== lock.sourceMainCommit) {
      warn(
        `official source ${lock.sourceBranch} moved from locked 2.0 baseline ${lock.sourceMainCommit} to ${sourceHead}; ` +
        'this is drift to evaluate, not a mutation of the locked release',
      );
    }
    for (const [ref, expected, label] of [
      [`refs/heads/${lock.pluginBranch}`, lock.pluginCommit, 'plugin release branch'],
      ['refs/heads/main', lock.pluginMainCommit, 'plugin main'],
    ]) {
      const current = remoteHead(remotes.plugin, ref, label);
      if (current && current !== expected) {
        warn(`${label} moved from observed baseline ${expected} to ${current}; exact plugin objects remain verified`);
      }
    }

    const forkHead = remoteHead(remotes.fork, `refs/heads/${lock.branch}`, 'MG fork');
    if (forkHead !== lock.commit) {
      fail(`fork branch ${lock.branch} advertises ${forkHead || '(missing)'}, expected pinned commit ${lock.commit}`);
    }
    const forkTag = remoteTagCommit(remotes.fork, lock.forkReleaseTag, 'MG fork');
    validateForkTag(forkTag, lock);
  } finally {
    if (auditRoot) {
      const resolvedTemp = resolve(tmpdir()).toLowerCase();
      const resolvedAudit = resolve(auditRoot).toLowerCase();
      if (resolvedAudit.startsWith(`${resolvedTemp}\\`) || resolvedAudit.startsWith(`${resolvedTemp}/`)) {
        rmSync(auditRoot, { recursive: true, force: true });
      } else {
        fail(`refusing to clean audit directory outside OS temp: ${auditRoot}`);
      }
    }
  }
}

function checkSuperprojectTopology() {
  // Read the stored identity, not `git remote get-url`, because Git applies
  // url.*.insteadOf transport rewrites to the latter. Transport rewrites may
  // select an authenticated mirror, but they must not change repository
  // provenance or make a local mirror look like the configured origin.
  const originResult = gitResult(['config', '--get', 'remote.origin.url']);
  const origin = originResult.ok ? originResult.stdout : '';
  if (!origin) {
    const message = 'superproject has no source origin; local development is possible but publication provenance is incomplete';
    if (RELEASE_MODE) fail(message);
    else warn(message);
    return;
  }
  if (canonicalGitUrl(origin) === DISTRIBUTION_REPO) {
    fail(
      `superproject origin ${origin} is the public distribution repository, not a source repository; ` +
      'LZZLHY/amcl contains website/update/HAP assets and must never receive this source history',
    );
  }
  if (!RELEASE_MODE) return;
  const branch = git(['rev-parse', '--abbrev-ref', 'HEAD']);
  if (branch !== 'main' && branch !== 'HEAD') {
    fail(`release source checkout must be canonical branch main or its detached immutable commit; got ${branch}`);
  }
  const head = git(['rev-parse', 'HEAD']);
  const remoteMain = remoteHead(
    origin,
    'refs/heads/main',
    'superproject source origin',
    false,
    sourceRemoteAuthEnvironment(origin),
  );
  if (remoteMain !== head) {
    fail(`source origin main advertises ${remoteMain || '(missing)'}, but release checkout is ${head}`);
  }
  const dirty = git(['status', '--porcelain=v1', '--untracked-files=all']);
  if (dirty) fail(`release superproject is not clean:\n${dirty}`);
}

function main() {
  if (process.exitCode) return;
  if (RELEASE_MODE && OFFLINE) {
    fail('--release cannot run offline: publication requires live source/fork/tag advertisements');
    return;
  }
  const lockPath = join(PROJECT_ROOT, 'deps.lock');
  const modulesPath = join(PROJECT_ROOT, '.gitmodules');
  if (!existsSync(lockPath)) fail('deps.lock is missing');
  if (!existsSync(modulesPath)) fail('.gitmodules is missing');
  if (process.exitCode) return;

  const section = parseSection(readFileSync(lockPath, 'utf8'), 'mobileglues');
  const lock = {
    section,
    commit: requireField(section, 'commit'),
    baseCommit: requireField(section, 'base_commit'),
    branch: requireField(section, 'branch'),
    repo: requireField(section, 'repo'),
    upstream: requireField(section, 'upstream'),
    sourceBranch: requireField(section, 'source_branch'),
    sourceMainCommit: requireField(section, 'source_main_commit'),
    sourceTree: requireField(section, 'source_tree'),
    sourceReleaseTag: requireField(section, 'source_release_tag'),
    rendererCommit: requireField(section, 'android_renderer_commit'),
    pluginRepo: requireField(section, 'android_plugin_repo'),
    pluginBranch: requireField(section, 'android_plugin_branch'),
    pluginCommit: requireField(section, 'android_plugin_commit'),
    pluginMainCommit: requireField(section, 'android_plugin_main_commit'),
    pluginRendererPath: requireField(section, 'android_plugin_renderer_path'),
    releaseRepo: requireField(section, 'release_repo'),
    releaseTag: requireField(section, 'release_tag'),
    releaseCommit: requireField(section, 'release_commit'),
    forkReleaseTag: requireField(section, 'fork_release_tag'),
    forkReleaseCommit: requireField(section, 'fork_release_tag_commit'),
  };
  for (const field of NESTED_PATHS.keys()) requireField(section, field);
  for (const [name, value] of [
    ['commit', lock.commit],
    ['base_commit', lock.baseCommit],
    ['source_main_commit', lock.sourceMainCommit],
    ['source_tree', lock.sourceTree],
    ['android_renderer_commit', lock.rendererCommit],
    ['android_plugin_commit', lock.pluginCommit],
    ['android_plugin_main_commit', lock.pluginMainCommit],
    ['release_commit', lock.releaseCommit],
    ['fork_release_tag_commit', lock.forkReleaseCommit],
    ...[...NESTED_PATHS.keys()].map(field => [field, section.get(field)]),
  ]) requireSha(name, value);

  if (lock.baseCommit !== lock.sourceMainCommit) {
    fail(`base_commit ${lock.baseCommit} != source_main_commit ${lock.sourceMainCommit}`);
  }
  if (lock.forkReleaseCommit !== lock.commit) {
    fail(`fork_release_tag_commit ${lock.forkReleaseCommit} != fork head commit ${lock.commit}`);
  }
  if (lock.sourceBranch !== REQUIRED_SOURCE_BRANCH) fail(`source_branch must be ${REQUIRED_SOURCE_BRANCH}`);
  if (lock.sourceReleaseTag !== 'none') fail('source_release_tag must be none; official source has no V2.0.0 tag');
  if (lock.releaseTag !== REQUIRED_RELEASE_TAG) fail(`release_tag must be ${REQUIRED_RELEASE_TAG}`);
  if (lock.pluginRendererPath !== 'MobileGlues') fail('android_plugin_renderer_path must be MobileGlues');
  if (canonicalGitUrl(lock.upstream) !== OFFICIAL_SOURCE) fail(`upstream is not official source: ${lock.upstream}`);
  if (canonicalGitUrl(lock.pluginRepo) !== OFFICIAL_PLUGIN) fail(`android_plugin_repo is not official plugin: ${lock.pluginRepo}`);
  if (canonicalGitUrl(lock.releaseRepo) !== OFFICIAL_RELEASE) fail(`release_repo is not official release-index: ${lock.releaseRepo}`);
  if (canonicalGitUrl(lock.repo) !== AMCL_FORK) fail(`repo is not the AMCL MobileGlues fork: ${lock.repo}`);
  if (lock.branch !== REQUIRED_BRANCH) fail(`branch must be ${REQUIRED_BRANCH}; got ${lock.branch}`);
  if (!/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/.test(lock.forkReleaseTag) || lock.forkReleaseTag.includes('..')) {
    fail(`fork_release_tag is unsafe: ${lock.forkReleaseTag}`);
  }

  const patchDir = join(PROJECT_ROOT, 'prebuilt', 'mobileglues', 'patches');
  const seriesPath = join(patchDir, 'series');
  if (!existsSync(seriesPath)) {
    fail('prebuilt/mobileglues/patches/series is missing');
  } else {
    const active = readFileSync(seriesPath, 'utf8').split(/\r?\n/).filter(line => !/^\s*(?:#.*)?$/.test(line));
    const patchFiles = readdirSync(patchDir).filter(name => name.endsWith('.patch'));
    if (active.length) fail('MG fork model requires an empty/comment-only patches/series');
    if (patchFiles.length) fail(`MG fork model forbids local patch files: ${patchFiles.join(', ')}`);
  }

  const stageLine = git(['ls-files', '--stage', '--', SUBMODULE_PATH]);
  const [mode, gitlink] = stageLine.split(/\s+/);
  if (mode !== '160000' || !/^[0-9a-f]{40}$/.test(gitlink ?? '')) {
    fail(`${SUBMODULE_PATH} is not a valid tracked submodule gitlink`);
  } else if (gitlink !== lock.commit) {
    fail(`gitlink ${gitlink} != deps.lock [mobileglues].commit ${lock.commit}`);
  }

  const moduleMatches = git([
    'config', '-f', '.gitmodules', '--get-regexp', '^submodule\..*\.path$', `^${SUBMODULE_PATH}$`,
  ]).split(/\r?\n/).filter(Boolean);
  if (moduleMatches.length !== 1) {
    fail(`.gitmodules must have exactly one ${SUBMODULE_PATH} entry; found ${moduleMatches.length}`);
    return;
  }
  const moduleName = moduleMatches[0].split(/\s+/)[0].replace(/^submodule\./, '').replace(/\.path$/, '');
  const moduleUrl = git(['config', '-f', '.gitmodules', '--get', `submodule.${moduleName}.url`]);
  const moduleBranch = git(['config', '-f', '.gitmodules', '--get', `submodule.${moduleName}.branch`]);
  if (canonicalGitUrl(moduleUrl) !== canonicalGitUrl(lock.repo)) fail(`.gitmodules URL ${moduleUrl} != ${lock.repo}`);
  if (moduleBranch !== lock.branch) fail(`.gitmodules branch ${moduleBranch || '(missing)'} != ${lock.branch}`);

  if (!existsSync(join(SUBMODULE_DIR, '.git'))) {
    fail(`${SUBMODULE_PATH} is not initialized; run git submodule update --init --depth 1 -- ${SUBMODULE_PATH}`);
    return;
  }
  const top = git(['rev-parse', '--show-toplevel'], SUBMODULE_DIR);
  if (resolve(top).toLowerCase() !== resolve(SUBMODULE_DIR).toLowerCase()) {
    fail(`Git resolved ${SUBMODULE_PATH} to the wrong repository root: ${top}`);
    return;
  }
  const head = git(['rev-parse', 'HEAD'], SUBMODULE_DIR);
  if (head !== lock.commit) fail(`checked-out MG HEAD ${head} != pinned commit ${lock.commit}`);

  const missingLockedObjects = [lock.sourceMainCommit, lock.rendererCommit]
    .filter(commit => !gitResult(['cat-file', '-e', `${commit}^{commit}`], SUBMODULE_DIR).ok);
  if (missingLockedObjects.length) {
    fail(
      `local MG checkout is too shallow or incomplete; locked source/renderer object(s) unavailable: ` +
      `${missingLockedObjects.join(', ')}. Run ` +
      `git -C ${SUBMODULE_PATH} fetch --no-tags upstream ${missingLockedObjects.join(' ')} ` +
      '(setup_deps.sh performs this exact-object hydration).',
    );
    return;
  }
  inspectSourceObjects((args, label) => git(args, SUBMODULE_DIR, label), 'local', lock);
  const commitType = git(['cat-file', '-t', `${lock.commit}^{commit}`], SUBMODULE_DIR);
  if (commitType !== 'commit') fail(`pinned fork object ${lock.commit} is not a commit`);

  if (lock.baseCommit !== lock.commit) {
    const commitCount = git(['rev-list', '--count', `${lock.baseCommit}..${lock.commit}`], SUBMODULE_DIR);
    if (commitCount !== REQUIRED_PATCH_COUNT) {
      fail(`MG integration must contain exactly ${REQUIRED_PATCH_COUNT} commits; got ${commitCount}`);
    }
    const actualDiff = new Map();
    const numstat = git(['diff', '--numstat', `${lock.baseCommit}..${lock.commit}`], SUBMODULE_DIR);
    for (const line of numstat.split(/\r?\n/).filter(Boolean)) {
      const [added, removed, path] = line.split('\t');
      actualDiff.set(path, `${added}\t${removed}`);
    }
    const expectedPaths = [...REQUIRED_DIFF.keys()].sort();
    const actualPaths = [...actualDiff.keys()].sort();
    if (JSON.stringify(actualPaths) !== JSON.stringify(expectedPaths)) {
      fail(`MG baseline changed files must be exactly ${expectedPaths.join(', ')}; got ${actualPaths.join(', ')}`);
    }
    for (const [path, counts] of REQUIRED_DIFF) {
      if (actualDiff.get(path) !== counts) fail(`MG baseline diff for ${path} must be ${counts}; got ${actualDiff.get(path) ?? 'missing'}`);
    }
  }

  const origin = git(['config', '--get', 'remote.origin.url'], SUBMODULE_DIR);
  if (canonicalGitUrl(origin) !== canonicalGitUrl(lock.repo)) fail(`MG origin ${origin} != ${lock.repo}`);
  const upstreamResult = gitResult(['config', '--get', 'remote.upstream.url'], SUBMODULE_DIR);
  if (!upstreamResult.ok) {
    const message = 'MG upstream fetch remote is not configured; setup_deps.sh will add the official read-only role';
    if (RELEASE_MODE) fail(message); else warn(message);
  } else {
    if (canonicalGitUrl(upstreamResult.stdout) !== canonicalGitUrl(lock.upstream)) {
      fail(`MG upstream fetch URL ${upstreamResult.stdout} != official ${lock.upstream}`);
    }
    const pushUrl = gitResult(['config', '--get', 'remote.upstream.pushurl'], SUBMODULE_DIR);
    if (!pushUrl.ok || pushUrl.stdout !== UPSTREAM_NO_PUSH) {
      const message = `MG upstream push URL must be the no-push sentinel ${UPSTREAM_NO_PUSH}`;
      if (RELEASE_MODE) fail(message); else warn(`${message}; setup_deps.sh will enforce it`);
    }
  }

  const dirty = git(['status', '--porcelain=v1', '--untracked-files=all'], SUBMODULE_DIR);
  if (dirty && !ALLOW_DIRTY) {
    fail(`MG submodule has modified or untracked files:\n${dirty}`);
  } else if (dirty) {
    warn(`--allow-dirty accepted local-only MG changes:\n${dirty}`);
  }

  const remotes = {
    source: remoteOverride('MG_PIN_SOURCE_REMOTE', lock.upstream),
    plugin: remoteOverride('MG_PIN_PLUGIN_REMOTE', lock.pluginRepo),
    release: remoteOverride('MG_PIN_RELEASE_REMOTE', lock.releaseRepo),
    fork: remoteOverride('MG_PIN_FORK_REMOTE', lock.repo),
  };
  if (OFFLINE) auditFromCache(lock, remotes); else auditOnline(lock, remotes);
  checkSuperprojectTopology();

  if (process.exitCode) return;
  console.log(
    `[check-mg-pin] OK (mode=${RELEASE_MODE ? 'release' : OFFLINE ? 'offline-cache' : 'development'}, ` +
    `branch=${lock.branch}, commit=${lock.commit}, source/plugin/renderer/release provenance verified, ` +
    `gitlink/head/worktree consistent${ALLOW_DIRTY ? ', dirty allowed' : ', clean'})`,
  );
}

main();

#!/usr/bin/env node
// Source contract for rollback-safe OHOS runtime optimizations.

import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));

function read(path) {
  return readFileSync(join(root, path), 'utf8');
}

function fail(message) {
  console.error(`[check-ohos-runtime-optimizations] ${message}`);
  process.exitCode = 1;
}

function requireMatch(text, pattern, label) {
  if (!pattern.test(text)) fail(`missing ${label}`);
}

function maskCppTrivia(text) {
  const masked = [...text];
  const blank = (from, to) => {
    for (let i = from; i < to; i++) {
      if (masked[i] !== '\n' && masked[i] !== '\r') masked[i] = ' ';
    }
  };
  for (let i = 0; i < text.length;) {
    if (text.startsWith('//', i)) {
      const end = text.indexOf('\n', i + 2);
      const limit = end < 0 ? text.length : end;
      blank(i, limit);
      i = limit;
      continue;
    }
    if (text.startsWith('/*', i)) {
      const end = text.indexOf('*/', i + 2);
      const limit = end < 0 ? text.length : end + 2;
      blank(i, limit);
      i = limit;
      continue;
    }
    if (text.startsWith('R"', i)) {
      const delimiterEnd = text.indexOf('(', i + 2);
      if (delimiterEnd >= 0) {
        const delimiter = text.slice(i + 2, delimiterEnd);
        const terminator = `)${delimiter}"`;
        const end = text.indexOf(terminator, delimiterEnd + 1);
        const limit = end < 0 ? text.length : end + terminator.length;
        blank(i, limit);
        i = limit;
        continue;
      }
    }
    if (text[i] === '"' || text[i] === "'" || text[i] === '`') {
      const quote = text[i];
      let end = i + 1;
      for (; end < text.length; end++) {
        if (text[end] === '\\') {
          end++;
        } else if (text[end] === quote) {
          end++;
          break;
        }
      }
      blank(i, end);
      i = end;
      continue;
    }
    i++;
  }
  return masked.join('');
}

function functionBody(text, signaturePattern, label) {
  const code = maskCppTrivia(text);
  const signature = signaturePattern.exec(code);
  if (!signature) {
    fail(`missing ${label} function`);
    return '';
  }
  let opening = signature.index + signature[0].length;
  while (/\s/.test(code[opening] ?? '')) opening++;
  // A declaration followed by ';' must never borrow a later unrelated block.
  if (code[opening] !== '{') {
    fail(`missing ${label} function definition`);
    return '';
  }
  let depth = 0;
  for (let i = opening; i < code.length; i++) {
    if (code[i] === '{') depth++;
    if (code[i] === '}' && --depth === 0) return code.slice(opening, i + 1);
  }
  fail(`unterminated ${label} function body`);
  return '';
}

function requireFunctionBodyMatch(text, signaturePattern, bodyPattern, label) {
  const body = functionBody(text, signaturePattern, label);
  if (body && !bodyPattern.test(body)) fail(`missing ${label}`);
}

function forbidMatch(text, pattern, label) {
  if (pattern.test(text)) fail(`forbidden ${label}`);
}

const cmake = read('entry/src/main/cpp/CMakeLists.txt');
const benchmark = read('entry/src/main/cpp/glfw/mg_benchmark_cache.cpp');
const benchmarkHeader = read('entry/src/main/cpp/glfw/mg_benchmark_cache.h');
const mgSourceIdentity = read('scripts/compute-mg-source-identity.mjs');
const launcherBuilder = read('scripts/build-amcl-launcher.mjs');
const glfwCompat = read('entry/src/main/cpp/glfw/glfw_compat.cpp');
const frame = read('entry/src/main/cpp/platform/ohos_frame_rate_hint.cpp');
const frameHeader = read('entry/src/main/cpp/platform/ohos_frame_rate_hint.h');
const xcomponent = read('entry/src/main/cpp/platform/xcomponent.cpp');
const nativeWindow = read('entry/src/main/cpp/platform/ohos_native_window_telemetry.cpp');
const mgConfig = read('entry/src/main/cpp/platform/mg_config.cpp');
const mgConfigMigration = read('entry/src/main/cpp/platform/mg_config_migration.cpp');
const mgConfigMigrationHeader = read(
  'entry/src/main/cpp/platform/mg_config_migration.h');
const mgConfigMigrationTest = read(
  'entry/src/main/cpp/tests/host/mg_config_migration_test.cpp');
const runtimePolicyTest = read(
  'entry/src/main/cpp/tests/host/mg_benchmark_cache_policy_test.cpp');
const entryAbility = read('entry/src/main/ets/entryability/EntryAbility.ets');
const gameAbility = read('entry/src/main/ets/gameability/GameAbility.ets');
const gamePage = read('entry/src/main/ets/pages/McGamePage.ets');
const settingsPage = read('entry/src/main/ets/pages/tabs/SettingsTab.ets');
const indexPage = read('entry/src/main/ets/pages/Index.ets');
const preferences = read('feature_system/src/main/ets/PreferenceManager.ets');
const declarations = read('entry/src/main/cpp/types/libentry/index.d.ts');
const versionScript = read('entry/src/main/cpp/glfw/glfw_mg.version');
const buildTemplate = read('build-profile.json5.template');

requireMatch(cmake, /glfw\/mg_benchmark_cache\.cpp/, 'benchmark source in libglfw');
requireMatch(cmake, /platform\/ohos_native_window_telemetry\.cpp/,
  'NativeWindow telemetry source in libentry');
requireMatch(cmake, /platform\/mg_config_migration\.cpp/,
  'MG config migration source in libentry');
requireMatch(cmake, /amcl_mg_config_json[\s\S]*config\/cJSON\.c/,
  'private pinned cJSON object for MG config migration');
requireMatch(versionScript, /glfw\[A-Z\]\*/, 'versioned GLFW extension allowlist');

requireMatch(benchmarkHeader, /glfwAMCLMobileGluesBenchmarkRunV1/,
  'versioned benchmark ABI');
requireMatch(benchmark, /EnvEnabled\("AMCL_MG_MULTIDRAW_BENCH"\)/,
  'explicit benchmark environment gate');
requireMatch(benchmark, /GLFW_AMCL_MG_BENCHMARK_DISPOSABLE_CONTEXT/,
  'disposable-context acknowledgement');
requireMatch(benchmark, /glfwGetCurrentContext\(\) != nullptr/,
  'live GLFW context rejection');
requireMatch(benchmark, /std::try_to_lock/, 'non-waiting concurrent-run guard');
requireMatch(benchmark, /"gpuRenderer"[\s\S]*"driver"[\s\S]*"mobileGluesVersion"/,
  'renderer/driver/MG cache identity');
requireMatch(benchmark,
  /AMCL_MG_BUILD_IDENTITY[\s\S]*"mobileGluesBuildIdentity"/,
  'content-addressed MG benchmark cache identity');
requireMatch(benchmark,
  /AMCL_HOST_BUILD_IDENTITY[\s\S]*"hostBuildIdentity"/,
  'host source/toolchain cache identity');
for (const [pattern, label] of [
  [/AMCL_HOST_BUILD_IDENTITY/, 'host build identity definition'],
  [/CMAKE_CXX_COMPILER_ID/, 'host compiler identity component'],
  [/AMCL_HOST_SOURCE_STATE/, 'host clean/dirty identity component'],
  // The present-boundary ledger is OFF as of 1000591. Its CPU cost was measured
  // and was fine; its LOG VOLUME cost never was, and that is the one that ships:
  // 6 lines / 2,322 B per second into mc_output.log, MG/latest.log and (via
  // logTailThread) hilog. On a real user log that is 66.5% of the file, and the
  // 32 KB tail the crash classifier reads covers only the last ~14 seconds --
  // all of it telemetry. Full measurement in
  // docs/reports/2026-09-05_LOGGING_SYSTEM_FULL_SURVEY.md §6.
  //
  // This gate holds OFF so that turning it back ON arrives with a solution to
  // the volume problem attached (separate sink / noise rule / sampling), not as
  // an edited comment. Local render work uses -DAMCL_MG_FRAME_STATS=ON.
  [/option\(AMCL_MG_FRAME_STATS "[^\n]*" OFF\)/,
    'MG present-boundary frame statistics stay out of shipping builds'],
  // Both branches must define it: the header defaults it to 0, so an OFF option
  // would ship correctly by omission -- but then the build log could not answer
  // "is telemetry in this HAP", which is how the volume cost stayed unpriced.
  [/AMCL_MG_FRAME_STATS=1[\s\S]{0,200}AMCL_MG_FRAME_STATS=0/,
    'frame statistics switch passed explicitly in both branches'],
  // The per-GL-call scopes stay off. They are three to five orders of magnitude
  // more frequent than the frame boundary, and the selective mode is not as cheap
  // as its name promised: the causal window arms on any frame >= 25 ms (so every
  // frame below 40 fps) and always-selected BufferAllocation has no window at all.
  // 1000551 already priced observer self-perturbation at 59.53 -> 27.59 FPS, and
  // the rule it produced is that a resident observer must be selective.
  //
  // What this gate does NOT claim: that turning these off makes anything faster.
  // The A/B was run on 2026-08-30 (Maleoon 920, MC 1.18.2 vanilla, one yardstick
  // over active-world windows) and said the opposite of the hypothesis -- the
  // session with almost no instrumentation (observed_calls peak 2) was the slowest
  // at p50 23.39, everything-on reached p50 43.89, and scopes-off landed at 39.54.
  // The default is off because an unmeasured resident cost should not ship, not
  // because it was the frame-rate problem. Turning it back on is arguable now, and
  // the gate holds the value so that argument arrives with its own A/B attached
  // instead of as an edited comment.
  [/option\(AMCL_MG_FRAME_STATS_GL_SCOPES[\s\S]{0,160}?" OFF\)/,
    'per-GL-call timing scopes stay out of shipping builds'],
  [/option\(AMCL_MG_FRAME_STATS_EXHAUSTIVE[^\n]*OFF\)/,
    'exhaustive MG frame statistics remain lab-only'],
  // Reached on every texture upload (~60/frame on 1.18.2) to answer a question
  // that does not change while a client runs.
  [/option\(AMCL_MG_UPLOAD_PROBE[^\n]*OFF\)/,
    'texture upload enum probe stays out of shipping builds'],
  // The header defaults GL_SCOPES to 1, so an OFF option that is never passed
  // through would silently ship as ON. Both branches must define it explicitly.
  [/AMCL_MG_FRAME_STATS_GL_SCOPES=1[\s\S]{0,200}AMCL_MG_FRAME_STATS_GL_SCOPES=0/,
    'GL scope switch passed explicitly in both branches'],
  [/AMCL_MG_UPLOAD_PROBE=1[\s\S]{0,200}AMCL_MG_UPLOAD_PROBE=0/,
    'upload probe switch passed explicitly in both branches'],
  [/set\(AMCL_MG_IDENTITY_SCRIPT[^\n]*compute-mg-source-identity\.mjs/,
    'MG content identity generator path'],
  [/add_custom_target\(amcl_mg_source_identity[\s\S]*AMCL_MG_IDENTITY_SCRIPT/,
    'build-time MG content identity generation'],
  [/add_dependencies\(glfw amcl_mg_source_identity\)/,
    'MG identity generation before libglfw compilation'],
]) {
  requireMatch(cmake, pattern, label);
}
for (const [pattern, label] of [
  [/diff[^\n]*--binary[^\n]*--no-ext-diff/, 'tracked binary diff identity input'],
  [/ls-files[^\n]*--others[^\n]*--exclude-standard/, 'untracked byte identity input'],
  [/submodule[^\n]*status[^\n]*--recursive/, 'recursive submodule identity input'],
  [/createHash\('sha256'\)/, 'SHA-256 source identity'],
  [/AMCL_MG_WORKTREE_SHA256[\s\S]*AMCL_MG_BUILD_IDENTITY/,
    'generated worktree and build identity macros'],
]) {
  requireMatch(mgSourceIdentity, pattern, label);
}
requireMatch(launcherBuilder,
  /inputSha256[\s\S]*jarSha256[\s\S]*BUILD_MANIFEST/,
  'content-addressed Java launcher JAR manifest');
forbidMatch(launcherBuilder, /mtimeMs/, 'mtime-only Java launcher JAR freshness');
requireMatch(benchmark, /"selectionApplied"[\s\S]*false/,
  'measurement-only result contract');
requireMatch(benchmark, /"upstream-config"/, 'upstream-default fallback marker');
forbidMatch(benchmark, /prepareMobileGluesRuntime|glfwInit\s*\(|glfwCreateWindow\s*\(/,
  'benchmark call from startup/window lifecycle');
requireMatch(glfwCompat, /logRuntimeImageIdentity\(\)[\s\S]*\/proc\/self\/maps/,
  'per-image linker-namespace diagnostic');
requireMatch(glfwCompat,
  /mappedImages[\s\S]*AMCL_MG_SOURCE_COMMIT[\s\S]*AMCL_MG_WORKTREE_SHA256[\s\S]*AMCL_MG_BUILD_IDENTITY[\s\S]*AMCL_HOST_BUILD_IDENTITY/,
  'runtime image count, MG content identity and host build identity log');
requireFunctionBodyMatch(glfwCompat, /\bint\s+glfwInit\s*\([^)]*\)/,
  /logRuntimeImageIdentity\(\)/,
  'runtime image diagnostic before per-DSO initialization');
requireFunctionBodyMatch(glfwCompat,
  /\buint64_t\s+glfwOHOS_PublishNativeWindow\s*\([^)]*\)/,
  /amclWindowHostPublish\s*\([\s\S]*publishInputBindingsBeforeCommit[\s\S]*if\s*\(\s*generation\s*==\s*0\s*\)/,
  'XComponent producer delegates generation validation and input publication to the WindowHost transaction');

requireMatch(frameHeader, /fpsCap[\s\S]*active/, 'cap-aware pure policy');
requireMatch(frame, /foregroundSources/, 'Ability foreground source mask');
requireMatch(frameHeader,
  /return state\.surfaceReady && state\.focused &&\s*state\.foregroundSources != 0;/,
  'surface, foreground and focus activation gate');
requireMatch(frame, /IsFrameRateLifecycleActive\(state\.lifecycle\)/,
  'runtime use of pure lifecycle activation gate');
requireMatch(frame, /AMCL_OHOS_FRAME_RATE_CAP/, 'environment cap rollback input');
requireMatch(frameHeader, /RefreshExpectedFrameRateHint/,
  'display-change refresh policy declaration');
requireFunctionBodyMatch(frame,
  /\bbool\s+RefreshExpectedFrameRateHint\s*\([^)]*\)/,
  /return\s+RefreshExpectedFrameRateHintForDisplayRate\(0,\s*lifecycleStage\)/,
  'display-change compatibility refresh query path');
requireFunctionBodyMatch(frame,
  /\bbool\s+RefreshExpectedFrameRateHintForDisplayRate\s*\([^)]*\)/,
  /component\s*==\s*nullptr[\s\S]*!g_frameRateController\.lifecycle\.surfaceReady[\s\S]*ApplyControllerLocked\(lifecycleStage,\s*true,\s*false,\s*displayRate\)/,
  'display-change explicit-rate refresh apply path');
requireMatch(xcomponent, /RegisterFocusEventCallback/, 'XComponent focus callback');
requireMatch(xcomponent, /RegisterBlurEventCallback/, 'XComponent blur callback');
requireMatch(xcomponent, /SetFrameRateSurfaceReady\(component, false/,
  'surface destruction deactivation');
forbidMatch(xcomponent, /RegisterOnFrameCallback/, 'second XComponent frame loop');
forbidMatch(xcomponent,
  /OnSurfaceChanged[\s\S]*?LogNativeWindowSnapshot[\s\S]*?OnSurfaceDestroyed/,
  'non-thread-safe NativeWindow query during active resize');

for (const [name, ability, source] of [
  ['EntryAbility', entryAbility, 'FRAME_RATE_FOREGROUND_SOURCE_ENTRY'],
  ['GameAbility', gameAbility, 'FRAME_RATE_FOREGROUND_SOURCE_GAME'],
]) {
  requireMatch(ability, new RegExp(`setOhosFrameRateForeground\\(${source}, true\\)`),
    `${name} foreground handoff`);
  requireMatch(ability, new RegExp(`setOhosFrameRateForeground\\(${source}, false\\)`),
    `${name} background handoff`);
}
requireMatch(declarations, /setOhosFrameRateForeground/, 'ArkTS foreground ABI declaration');
requireMatch(declarations, /setOhosFrameRateCap/, 'ArkTS cap ABI declaration');
requireMatch(declarations, /refreshOhosFrameRateHint/, 'ArkTS display refresh ABI declaration');
requireMatch(xcomponent,
  /"refreshOhosFrameRateHint"[\s\S]*RefreshOhosFrameRateHint/,
  'display refresh N-API descriptor');
requireMatch(preferences,
  /get ohosFrameRateCap\(\)[\s\S]*normalizeOhosFrameRateCap[\s\S]*OHOS_FRAME_RATE_CAP_MAX/,
  'persistent normalized OHOS frame-rate cap');
requireMatch(settingsPage,
  /系统调度帧率上限[\s\S]*FrameRateCapChip\(0, '自动'\)[\s\S]*onOhosFrameRateCapChange/,
  'explicit scheduler-cap settings UI');
requireMatch(indexPage,
  /ohosFrameRateCap: this\.ohosFrameRateCap[\s\S]*prefManager\.ohosFrameRateCap = fpsCap[\s\S]*setOhosFrameRateCap\(fpsCap\)/,
  'settings state, persistence and immediate native handoff');
requireMatch(gamePage,
  /applyOhosFrameRatePreference[\s\S]*setOhosFrameRateCap\(fpsCap\)/,
  'launch-time persisted cap injection');
requireMatch(gamePage,
  /display\.on\('change', this\.displayChangeListener\)[\s\S]*display\.off\('change', this\.displayChangeListener\)/,
  'balanced display-change listener lifecycle');
requireFunctionBodyMatch(gamePage,
  /\bprivate\s+displayChangeListener\s*:\s*Callback<number>\s*=\s*\([^)]*\)\s*:\s*void\s*=>/,
  /gameWindowCoordinator\.snapshot\(\)[\s\S]*syncInputSurfaceContext\(snapshot,/,
  'display-change Window snapshot refresh');
requireFunctionBodyMatch(gamePage,
  /\bprivate\s+syncInputSurfaceContext\s*\([^)]*\)\s*:\s*void/,
  /getInputSurfaceContextStore\(\)\.snapshot\(\)[\s\S]*snapshot\.contextGeneration\s*!==\s*context\.generation[\s\S]*publishStoredInputSurfaceContext\(context,\s*reason\)/,
  'display-change generation-coherent surface-context handoff');
requireFunctionBodyMatch(gamePage,
  /\bprivate\s+publishStoredInputSurfaceContext\s*\([^)]*\)\s*:\s*void/,
  /context\.has\(INPUT_SURFACE_FIELD_REFRESH_RATE\)[\s\S]*refreshOhosFrameRateHint\(context\.refreshRateHz\)/,
  'display-change native policy refresh');
forbidMatch(gamePage,
  /AMCL_OHOS_FRAME_RATE_CAP|options\.txt[\s\S]*setOhosFrameRateCap/,
  'environment or Minecraft-options coupling in the app cap path');
for (const fixture of ['kAuto120', 'kCapped60', 'kCapAboveDisplay',
  'kInactiveCapped', 'kOneForegroundSourceRemains']) {
  requireMatch(runtimePolicyTest, new RegExp(`\\b${fixture}\\b`),
    `frame-rate policy ${fixture} fixture`);
}

for (const operation of ['GET_BUFFER_GEOMETRY', 'GET_FORMAT', 'GET_USAGE',
  'GET_SWAP_INTERVAL', 'GET_BUFFERQUEUE_SIZE']) {
  requireMatch(nativeWindow, new RegExp(`\\b${operation}\\b`),
    `NativeWindow ${operation} telemetry`);
}
forbidMatch(nativeWindow,
  /\b(?:SET_[A-Z0-9_]+|OH_NativeWindow_PreAllocBuffers|OH_NativeWindow_NativeWindowRequestBuffer|OH_NativeWindow_NativeWindowFlushBuffer)\b/,
  'NativeWindow mutation/dequeue/preallocation');
requireMatch(mgConfig, /config\.json\.amcl-pre-2\.0-v1\.bak/,
  'one-time pre-2.0 config backup');
requireMatch(mgConfig, /AMCL_MG_CONFIG_MIGRATION/,
  'explicit config-migration rollback gate');
requireMatch(mgConfig, /ConfigActionNeedsBackup[\s\S]*EnsureBackup[\s\S]*AtomicWrite/,
  'backup-before-atomic-replacement ordering');
// 校验的是"preset id 带版本号"，而不是某一个具体版本。写死 `-v1` 会让每次改 preset
// 内容（那正是必须递增版本号的时候）都在一棵正确的树上假红，同时对"内容改了却忘记
// 递增版本"这个真正要防的错误毫无察觉 —— 与 check-mg-docs.mjs 曾把 MG commit 哈希
// 写死在脚本里是同一个形状。
requireMatch(mgConfigMigrationHeader,
  /mobileglues-2\.0-android-parity-ohos-v\d+/,
  'versioned Android-parity OHOS config schema');
requireMatch(mgConfigMigration, /"enableANGLE"[\s\S]*2/,
  'OHOS ANGLE force-disable platform rule');
for (const fixture of ['absent', 'legacy', 'malformed', 'invalidCurrent',
  'validOverride']) {
  requireMatch(mgConfigMigrationTest, new RegExp(`\\b${fixture}\\b`),
    `MG config ${fixture} fixture`);
}
requireMatch(buildTemplate, /"compatibleSdkVersion"\s*:\s*"6\.0\.0\(20\)"/,
  'API 20 compatibility baseline');

if (!process.exitCode) {
  console.log('[check-ohos-runtime-optimizations] PASS');
  console.log('  benchmark: explicit + disposable-context gated, identity cache, no auto selection');
  console.log('  image probe: producer + consumer DSO paths log address/path/dev/inode + content identity');
  console.log('  frame hint: persisted cap + display-change refresh + lifecycle policy; no second frame loop');
  console.log('  NativeWindow: API-20-safe GET telemetry only; no prealloc/usage mutation');
  console.log('  MG config: current schema preserved; legacy/malformed backed up and normalized');
}

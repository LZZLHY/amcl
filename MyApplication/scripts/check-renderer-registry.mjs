#!/usr/bin/env node
// Canonical profile source consistency. Artifact and device admission remain separate.
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { stripComments, langForPath } from './lib/source-noise.mjs';
import { parseGraphicsRegistry, renderGraphicsProfileMirror } from './lib/graphics-profile-registry.mjs';
export { stripComments } from './lib/source-noise.mjs';
const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
export const SOURCES = {
  registry: 'launch/src/main/ets/GraphicsProfileRegistry.ets',
  resolver: 'launch/src/main/ets/GraphicsProfileResolver.ets',
  legacyRegistry: 'launch/src/main/ets/RendererBackendRegistry.ets',
  legacyResolver: 'launch/src/main/ets/RendererBackendResolver.ets',
  plan: 'launch/src/main/ets/GraphicsBackendPlan.ets',
  nativeMirror: 'entry/src/main/cpp/platform/graphics_profile_mirror.generated.h',
  legacyNative: 'entry/src/main/cpp/platform/renderer_backend_ids.h',
  profileBuilder: 'launch/src/main/ets/LaunchProfileBuilder.ets',
  settings: 'entry/src/main/ets/components/MobileglRendererSettings.ets',
  capabilityAdapter: 'entry/src/main/ets/runtime/GraphicsCapabilityAdapter.ets',
  gamePage: 'entry/src/main/ets/pages/McGamePage.ets',
};
export const TOLERATED_PLACEHOLDER_LIFECYCLES = ['retired-pending-decision'];
export function readAll(root = ROOT) {
  return Object.fromEntries(Object.entries(SOURCES).map(([key, rel]) =>
    [key, fs.existsSync(path.join(root, rel)) ? fs.readFileSync(path.join(root, rel), 'utf8') : null]));
}
export function analyze(texts) {
  const problems = [], notes = [];
  const result = (fatal = null, profiles = []) => ({
    ok: fatal === null && problems.length === 0, fatal, problems, notes,
    arkBackends: profiles.map((p) => p.id),
    nativeBackends: profiles.filter((p) => p.lifecycle !== 'retired').map((p) => p.id),
    ruleReturns: profiles.filter((p) => p.lifecycle !== 'retired').map((p) => p.id),
  });
  for (const [key, rel] of Object.entries(SOURCES)) {
    if (typeof texts[key] !== 'string') return result('源文件缺失: ' + rel);
  }
  let profiles;
  try { profiles = parseGraphicsRegistry(texts.registry); }
  catch (error) { return result('解析不到 canonical GRAPHICS_PROFILES: ' + error.message); }
  const code = Object.fromEntries(Object.entries(SOURCES).map(([key, rel]) =>
    [key, stripComments(texts[key], { lang: langForPath(rel) })]));
  if (!code.nativeMirror.includes('kGraphicsProfiles[]')) return result('解析不到 native kGraphicsProfiles', profiles);
  const requiredStrings = ['id', 'displayName', 'nativeRoute', 'implementationChain', 'startupDomain', 'resourceOwner', 'gameMinimum', 'requirementId', 'rationale', 'license'];
  const enums = {
    api: ['OPENGL', 'VULKAN'], transport: ['YES', 'NO', 'UNKNOWN'],
    lifecycle: ['default', 'platform-default', 'forced-by-version', 'optional', 'experimental', 'candidate', 'retired'],
    selectionRole: ['default', 'fixed-function', 'desktop-default', 'explicit', 'game-vulkan', 'retired'],
    admission: ['LEGACY', 'VALIDATION', 'VERIFIED'], capabilityKind: ['legacy', 'native-gl', 'vulkan'],
    windowAcquisition: ['none', 'current-context', 'native-window-lease'],
    contextApi: ['desktop-gl', 'gles', 'none'],
    glfwSharedContext: ['supported', 'unsupported', 'probe-required'],
    glfwAuxiliaryWindow: ['supported', 'unsupported', 'probe-required'],
    sdlAuxiliaryWindow: ['supported', 'unsupported'],
    parkingContext: ['supported', 'unsupported'],
  };
  const seen = new Set();
  for (const p of profiles) {
    // 推荐起点允许空串，但禁止把缺字段/非版本字符串解释成“适用所有版本”。
    if (typeof p.autoPreferredFrom !== 'string' || (p.autoPreferredFrom && !/^\d+(?:\.\d+)+$/.test(p.autoPreferredFrom))) {
      problems.push(`${p.id}: invalid autoPreferredFrom`);
    }
    if (!Array.isArray(p.artifactIds) || (p.lifecycle !== 'retired' && !p.artifactIds.length)
        || p.artifactIds.some(id => !/^lib[a-zA-Z0-9_+.-]+\.so$/.test(id))) problems.push(p.id + ': invalid artifactIds');
    if (!Array.isArray(p.requiredCapabilities) || !p.requiredCapabilities.length) problems.push(p.id + ': missing capability requirements');
    for (const field of requiredStrings) {
      if (typeof p[field] !== 'string' || !p[field].length) problems.push(p.id + ': required field is empty: ' + field);
    }
    for (const [field, values] of Object.entries(enums)) {
      if (!values.includes(p[field])) problems.push(p.id + ': invalid ' + field + '=' + p[field]);
    }
    for (const field of ['systemLibrary', 'ownsEgl', 'ownsPresent', 'userSelectable', 'restartRequired']) {
      if (typeof p[field] !== 'boolean') problems.push(p.id + ': required boolean ' + field);
    }
    if (typeof p.id !== 'string' || !/^[a-z0-9-]+$/.test(p.id)) problems.push(p.id + ': id 必须小写');
    if (p.id?.includes('mgl')) problems.push(p.id + ': forbidden mgl abbreviation');
    if (seen.has(p.id)) problems.push('duplicate id: ' + p.id);
    seen.add(p.id);
    for (const [field, allowed] of [['windowProviders', ['GLFW', 'SDL3']], ['platforms', ['MOBILE', 'DESKTOP']]]) {
      if (!Array.isArray(p[field]) || !p[field].length || p[field].some((v) => !allowed.includes(v))
          || new Set(p[field]).size !== p[field].length) problems.push(p.id + ': invalid ' + field);
    }
    if (['candidate', 'forced-by-version', 'retired'].includes(p.lifecycle) && p.userSelectable !== false) {
      problems.push(p.id + ': lifecycle=' + p.lifecycle + ' requires userSelectable=false');
    }
    if (p.ownsPresent && p.windowAcquisition !== 'native-window-lease') problems.push(p.id + ': ownsPresent requires NativeWindowLease');
    if (typeof p.glLibName !== 'string' || (p.api === 'OPENGL' ? !p.glLibName.length : p.glLibName.length !== 0)) {
      problems.push(p.id + ': OpenGL requires glLibName; Vulkan must have an empty GL library name');
    }
    if (p.api === 'VULKAN' && (p.transport !== 'YES' || p.capabilityKind !== 'vulkan' || p.admission === 'LEGACY')) {
      problems.push(p.id + ': Vulkan requires explicit transport, capability and non-legacy admission');
    }
    if (p.lifecycle === 'retired') notes.push(p.id + ': 已退役，native 镜像不含墓碑');
  }
  const defaults = profiles.filter((p) => p.lifecycle === 'default');
  const defaultRoles = profiles.filter((p) => p.selectionRole === 'default');
  if (defaults.length !== 1 || defaultRoles.length !== 1 || defaults[0]?.id !== defaultRoles[0]?.id) {
    problems.push('必须有且仅有一个 default profile，且 lifecycle 与 selectionRole 一致');
  }
  for (const role of ['fixed-function', 'desktop-default', 'game-vulkan']) {
    if (profiles.filter((p) => p.selectionRole === role).length !== 1) problems.push('canonical role must be unique: ' + role);
  }
  try {
    if (texts.nativeMirror.replace(/\r\n/g, '\n') !== renderGraphicsProfileMirror(profiles)) {
      problems.push('native generated mirror differs from canonical metadata; run generate-graphics-profile-mirror.mjs');
    }
  } catch (error) { problems.push('cannot generate native mirror: ' + error.message); }
  if (!code.legacyRegistry.includes('GRAPHICS_PROFILES.filter(') || /\bRENDERER_BACKENDS[^=]*=\s*\[/.test(code.legacyRegistry)
      || /\bid\s*:\s*['"]/.test(code.legacyRegistry)) problems.push('legacy registry must be a derived OpenGL view, not a second table');
  if (!code.legacyResolver.includes('resolveGraphicsProfile(canonicalInput)') || /\bRENDERER_RULES\b/.test(code.legacyResolver)
      || /rendererBackendById|graphicsProfileById/.test(code.legacyResolver)) problems.push('legacy resolver must only delegate to the canonical resolver');
  if (/from\s+['"].*RendererBackend(?:Registry|Resolver)['"]/.test(code.resolver)) problems.push('canonical resolver must not depend on legacy registry/resolver');
  if (code.resolver.includes('input.requiresNativeGl') || code.resolver.includes('spec.platforms.indexOf('))
    problems.push('graphics admission must not use product/platform exclusivity');
  if (!code.settings.includes('listGraphicsProfileAvailability(') || !code.settings.includes('prepareGraphicsProfileInput(')
      || !code.gamePage.includes('prepareGraphicsProfileInput(') || !code.gamePage.includes('.setGraphicsEnvironment('))
    problems.push('settings and launch must consume the shared graphics environment and canonical admission');
  if (code.settings.includes('ProductBuildProfile') || code.capabilityAdapter.includes('ProductBuildProfile'))
    problems.push('graphics availability must not derive capability from product identity');
  if (/graphicsProfileById|graphicsProviderForVersion/.test(code.plan) || !code.plan.includes('selected.profile')
      || !code.plan.includes('selected.providerVariant')) problems.push('plan must consume the selected candidate metadata without re-resolving');
  if (!code.legacyNative.includes('amcl::graphics::kLegacyGlLibraries') || /\{\s*"[^"]+"\s*,\s*"[^"]+"\s*,\s*(true|false)/.test(code.legacyNative)) {
    problems.push('legacy native table must be derived from the generated canonical mirror');
  }
  if (/-Damcl\.gl\.backend=[a-z0-9]/.test(code.profileBuilder)) problems.push('builder contains a hardcoded legacy backend injection');
  if (!code.profileBuilder.includes('graphicsPlan.legacyGlBackendMarker.length > 0')
      || !code.profileBuilder.includes('-Damcl.gl.backend=${graphicsPlan.legacyGlBackendMarker}')) {
    problems.push('builder must derive its optional legacy GL marker from the selected plan');
  }
  if (/\bminimumGameVersion\b|graphicsProviderForVersion/.test(code.registry)) problems.push('window provider must come from manifest facts, not version guesses');
  return result(null, profiles);
}
function main() {
  const report = analyze(readAll());
  if (process.argv.includes('--json')) console.log(JSON.stringify(report, null, 2));
  else {
    for (const note of report.notes) console.log('[check-renderer-registry] note ' + note);
    if (report.ok) console.log('[check-renderer-registry] PASS canonical profiles + generated native mirror: ' + report.arkBackends.join(', '));
    else console.error('[check-renderer-registry] FAIL ' + (report.fatal || report.problems.join('\n')));
  }
  process.exit(report.ok ? 0 : report.fatal ? 2 : 1);
}
if (import.meta.url === url.pathToFileURL(process.argv[1] || '').href) main();

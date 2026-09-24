#!/usr/bin/env node
import assert from 'node:assert/strict';
import { analyze, readAll, stripComments } from './check-renderer-registry.mjs';
import { parseGraphicsRegistry, renderGraphicsProfileMirror } from './lib/graphics-profile-registry.mjs';
const real = readAll();
let tests = 0;
function rejected(name, report, pattern) {
  assert.equal(report.ok, false, name);
  if (pattern) assert.match([report.fatal, ...report.problems].join('\n'), pattern, name);
  tests++;
}
function mutate(key, from, to) {
  assert.ok(real[key].includes(from), 'mutation fixture is present: ' + from);
  return { ...real, [key]: real[key].replace(from, to) };
}
function consistentMutation(from, to) {
  const input = mutate('registry', from, to);
  input.nativeMirror = renderGraphicsProfileMirror(parseGraphicsRegistry(input.registry));
  return input;
}
const valid = analyze(real);
assert.equal(valid.ok, true, JSON.stringify(valid));
assert.ok(valid.nativeBackends.includes('minecraft-vulkan'));
assert.ok(!valid.nativeBackends.includes('zink'));
assert.ok(valid.notes.some((note) => /zink.*退役/.test(note)));
tests++;
rejected('missing source', analyze({ ...real, registry: null }), /缺失/);
rejected('no table declaration', analyze({ ...real, registry: 'export const NOTHING = 1;' }), /解析不到/);
rejected('type annotation alone cannot be a table', analyze({ ...real, registry: 'const x: GraphicsProfileSpec[] = 1;' }), /解析不到/);
rejected('unrecognised enum value', analyze(mutate('registry', 'GraphicsWindowProvider.GLFW', 'GraphicsWindowProvider.DESKTOP')), /unknown registry value/);
rejected('nondeclarative table cannot execute', analyze(mutate('registry', "id: 'mobileglues'", "id: process.exit(0)")), /Non-declarative/);
rejected('missing generated table', analyze({ ...real, nativeMirror: '#define NOTHING 1' }), /kGraphicsProfiles/);
rejected('Vulkan row omitted', analyze(mutate('nativeMirror', '    {"minecraft-vulkan", "VULKAN"', '    {"deleted-vulkan", "VULKAN"')), /mirror differs/);
rejected('Vulkan requirement drift', analyze(mutate('nativeMirror', '"minecraft-26.2-conservative-v1"', '"unknown-requirement"')), /mirror differs/);
rejected('Vulkan API drift', analyze(mutate('nativeMirror', '"minecraft-vulkan", "VULKAN"', '"minecraft-vulkan", "OPENGL"')), /mirror differs/);
rejected('GL library drift', analyze(mutate('nativeMirror', '"libgl4es.so"', '"libwrong.so"')), /mirror differs/);
rejected('default drift', analyze(mutate('nativeMirror', 'kDefaultGraphicsProfileId = "mobileglues"', 'kDefaultGraphicsProfileId = "gl4es"')), /mirror differs/);
rejected('duplicate default lifecycle', analyze(consistentMutation('lifecycle: RendererBackendLifecycle.ForcedByVersion', 'lifecycle: RendererBackendLifecycle.Default')), /有且仅有一个 default/);
rejected('uppercase id', analyze(consistentMutation("id: 'gl4es'", "id: 'GL4ES'")), /必须小写/);
rejected('candidate made user selectable', analyze(mutate('registry',
  'lifecycle: RendererBackendLifecycle.Optional', 'lifecycle: RendererBackendLifecycle.Candidate')), /userSelectable=false/);
rejected('present owner lacks lease', analyze(consistentMutation(
  'ownsEgl: false, ownsPresent: true,\n    windowAcquisition: RendererWindowAcquisition.NativeWindowLease',
  'ownsEgl: false, ownsPresent: true,\n    windowAcquisition: RendererWindowAcquisition.None')), /NativeWindowLease/);
rejected('Vulkan given a GL library', analyze(consistentMutation("glLibName: '', systemLibrary: false", "glLibName: 'libglfw.so', systemLibrary: false")), /Vulkan must have an empty/);
rejected('desktop forged as window API', analyze(consistentMutation(
  "SDL3 = 'SDL3', UNKNOWN = 'UNKNOWN'", "SDL3 = 'DESKTOP', UNKNOWN = 'UNKNOWN'")), /invalid windowProviders/);
rejected('legacy registry duplicated', analyze({ ...real, legacyRegistry: real.legacyRegistry + "\nconst other = { id: 'other' };" }), /second table/);
rejected('legacy resolver policy duplicated', analyze({ ...real, legacyResolver: real.legacyResolver + '\nconst RENDERER_RULES = [];' }), /only delegate/);
rejected('canonical depends on legacy resolver', analyze({ ...real, resolver: real.resolver + "\nimport { foo } from './RendererBackendResolver';" }), /must not depend on legacy/);
rejected('product used as device capability', analyze({ ...real, settings: real.settings + "\nconst desktop = ProductBuildProfile.product === 'desktop';" }), /product identity/);
rejected('old platform exclusion restored', analyze({ ...real, resolver: real.resolver + "\nspec.platforms.indexOf(platform);" }), /exclusivity/);
rejected('UI replaced with a second resolver', analyze(mutate('settings', 'listGraphicsProfileAvailability(this.lastInput)', 'localAvailability(this.lastInput)')), /shared graphics environment/);
rejected('plan resolves profile again', analyze({ ...real, plan: real.plan + '\ngraphicsProfileById(plan.profile);' }), /without re-resolving/);
rejected('legacy native rows duplicated', analyze({ ...real, legacyNative: real.legacyNative + '\n{"other", "other.so", true, nullptr};' }), /must be derived/);
rejected('legacy marker injection hardcoded', analyze({ ...real, profileBuilder: real.profileBuilder + "\nparsed.jvmArgs.push('-Damcl.gl.backend=minecraft-vulkan');" }), /hardcoded legacy/);
rejected('legacy marker guard removed', analyze(mutate('profileBuilder', 'graphicsPlan.legacyGlBackendMarker.length > 0', 'true')), /optional legacy GL marker/);
assert.equal(analyze({ ...real, registry: real.registry + "\n// historical id: 'ghost', graphicsProviderForVersion\n" }).ok, true);
assert.ok(stripComments("const url = 'https://example.com'; // discarded").includes('https://example.com'));
assert.ok(!stripComments("const number = 1; // discarded").includes('discarded'));
assert.equal(stripComments('a\n// comment\nb').split('\n').length, 3);
assert.equal(stripComments('const template = ' + String.fromCharCode(96) + 'a//b' + String.fromCharCode(96) + ';').includes('a//b'), true);
console.log('Canonical registry gate: ' + tests + ' positive/negative cases and comment parsing PASS');

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { stripComments, langForPath } from './lib/source-noise.mjs';
import { readElfIdentity } from './check-mg-build-contract.mjs';
import { assertExternalOutputPath } from './lib/workspace-paths.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourcePaths = [
  'launch/src/main/ets/GraphicsProfileRegistry.ets',
  'launch/src/main/ets/GraphicsProfileResolver.ets',
  'launch/src/main/ets/GraphicsSelectionTypes.ets',
  'launch/src/main/ets/GraphicsBackendPlan.ets',
  'launch/src/main/ets/GraphicsCapabilityContract.ets',
  'launch/src/main/ets/RendererBackendRegistry.ets',
  'launch/src/main/ets/RendererBackendResolver.ets',
  'launch/src/main/ets/LaunchProfileBuilder.ets',
  'entry/src/main/cpp/platform/renderer_backend_ids.h',
  'entry/src/main/cpp/platform/graphics_profile_mirror.generated.h',
  'entry/src/main/cpp/jvm/mc_launcher.cpp',
  'entry/src/main/cpp/jvm/jvm_launcher.cpp',
  'entry/src/main/cpp/platform/vulkan_probe.cpp',
  'entry/src/main/cpp/platform/graphics_plan.h',
  'entry/src/main/cpp/platform/graphics_plan.cpp',
  'entry/src/main/cpp/platform/graphics_backend_session.h',
  'entry/src/main/cpp/platform/graphics_backend_session.cpp',
  'entry/src/main/cpp/glfw/amcl_native_window_lease_broker_abi.h',
  'entry/src/main/cpp/glfw/glfw_vulkan_wsi.h',
  'entry/src/main/cpp/glfw/glfw_vulkan.cpp',
  'entry/src/main/cpp/glfw/amcl_native_window_lease_ledger.h',
  'entry/src/main/cpp/glfw/glfw_egl.cpp',
  'entry/src/main/cpp/glfw/desktop_egl.cpp',
  'entry/src/main/cpp/glfw/glfw_compat.cpp',
];
const relevantEnv = /^(?:AMCL_(?:GL|GRAPHICS|NATIVE_WINDOW|FORCE_VULKAN)|MOBILEGL_|SDL_(?:OPENGL|EGL|VULKAN)_LIBRARY|NEED_OPENGL|LIBGL_)/;
const relevantProperty = /^(?:amcl\.(?:gl|graphics|sdl)|org\.lwjgl\.(?:opengl|glfw|sdl|vulkan|shaderc|spvc|vma))/;
const sha = value => createHash('sha256').update(value).digest('hex');

// This inventory records source references; a reference is not proof of an executed writer.
export function inspectSource(relative, source) {
  const code = stripComments(source, { lang: langForPath(relative) });
  const references = [];
  const collect = (pattern, category, keyIndex = 1) => {
    for (const match of code.matchAll(pattern)) {
      const key = match[keyIndex];
      if (!(category.startsWith('environment') ? relevantEnv : relevantProperty).test(key)) continue;
      references.push({ category, key, line: code.slice(0, match.index).split('\n').length });
    }
  };
  collect(/\bsetenv\s*\(\s*"([^"]+)"/g, 'environment-write');
  collect(/\bunsetenv\s*\(\s*"([^"]+)"/g, 'environment-clear');
  collect(/\bgetenv\s*\(\s*"([^"]+)"/g, 'environment-read');
  collect(/\bsetSystemProperty\s*\(\s*env\s*,\s*"([^"]+)"/g, 'property-write');
  collect(/-D((?:amcl|org\.lwjgl)\.[A-Za-z0-9_.]+)=/g, 'property-argument');
  return { path: relative, sha256: sha(source), references };
}

export function buildInventory(root = ROOT, sourceRoot = root) {
  const sources = sourcePaths.map(relative => {
    const file = path.join(sourceRoot, relative);
    if (!fs.existsSync(file)) return { path: relative, present: false, sha256: null, references: [] };
    return { present: true, ...inspectSource(relative, fs.readFileSync(file, 'utf8')) };
  });
  const build = JSON.parse(fs.readFileSync(path.join(root, 'entry/build-profile.json5'), 'utf8'));
  const products = build.targets.filter(target => target.name !== 'ohosTest').map(target => ({
    product: target.name,
    declaredArguments: target.config?.buildOption?.externalNativeOptions?.arguments ?? '',
    sourceRoots: target.source?.sourceRoots ?? [],
    effectiveBuildEvidence: 'NOT_CHECKED',
  }));
  const nativeDir = path.join(root, 'entry/libs/arm64-v8a');
  const artifacts = fs.readdirSync(nativeDir).filter(name =>
    /^lib(?:glfw|gl4es|mobilegl|GLv4|EGL|GLESv3|vulkan|shaderc|spirv-cross|SDL3|lwjgl)/.test(name)
      && name.endsWith('.so')).sort().map(name => {
    const bytes = fs.readFileSync(path.join(nativeDir, name));
    return { path: `entry/libs/arm64-v8a/${name}`, size: bytes.length, sha256: sha(bytes),
      elf: readElfIdentity(bytes), evidence: 'WORKSPACE_FILE_ONLY' };
  });
  const moduleManifest = 'prebuilt/lwjgl3/target-manifest-coverage.json';
  return { schema: 1, capturedAt: new Date().toISOString(),
    head: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(),
    sourceRoot: path.resolve(sourceRoot), sources, products, artifacts,
    nativeModuleManifest: { path: moduleManifest, sha256: sha(fs.readFileSync(path.join(root, moduleManifest))) },
    limits: ['Static references do not prove execution or provider identity.',
      'Workspace native files do not prove HAP inclusion, ABI compatibility, or device availability.',
      'Product arguments are declarations; effective compiler arguments and HAP need separate verification.',
      'This inventory does not include credentials, full launch arguments, or user options.'] };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const arg = flag => { const at = process.argv.indexOf(flag); return at < 0 ? '' : process.argv[at + 1]; };
    // 报告是本次宿主运行输出；在读取/审计前拒绝仓内显式路径，避免重建 diagnostics/.tmp。
    const output = arg('--out') ? assertExternalOutputPath(arg('--out')) : '';
    const result = buildInventory(ROOT, arg('--source-root') ? path.resolve(arg('--source-root')) : ROOT);
    const json = JSON.stringify(result, null, 2) + '\n';
    if (arg('--out')) {
      // 全新 checkout 不包含本机报告目录；输出前创建父目录，不把旧报告当作输入。
      fs.mkdirSync(path.dirname(output), { recursive: true });
      fs.writeFileSync(output, json);
    }
    else process.stdout.write(json);
    if (arg('--out')) console.log(`Graphics inventory: ${result.sources.length} sources, ${result.artifacts.length} workspace artifacts; no runtime verdict`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}

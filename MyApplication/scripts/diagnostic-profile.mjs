import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { productDefinition } from './product-contract.mjs';

export const DIAGNOSTIC_FLAGS = {
  tests: 'MC_OHOS_BUILD_TESTS',
  'input-trace': 'AMCL_INPUT_TRACE',
  'mg-frames': 'AMCL_MG_FRAME_STATS',
  'mg-gl': 'AMCL_MG_FRAME_STATS_GL_SCOPES',
  'mg-exhaustive': 'AMCL_MG_FRAME_STATS_EXHAUSTIVE',
  'mg-upload': 'AMCL_MG_UPLOAD_PROBE',
  stack: 'AMCL_STACK_SAMPLER',
  'gate0': 'AMCL_INPUT_GATE0_TELEMETRY',
  // 只在末尾追加诊断位：Vulkan 资源 trace 为位 9，必须与 CMake/原生纯策略保持一致。
  'vulkan-trace': 'AMCL_VULKAN_WSI_TRACE',
};

export function diagnosticProfile(product, mode = 'auto', requested = 'none') {
  const definition = productDefinition(product);
  if (mode === 'auto') mode = definition.defaultBuildMode;
  if (!['debug', 'release'].includes(mode)) throw new Error(`Unknown build mode: ${mode}`);
  const selected = new Set(String(requested).split(',').filter(x => x && x !== 'none'));
  for (const name of selected) {
    if (!Object.hasOwn(DIAGNOSTIC_FLAGS, name)) throw new Error(`Unknown diagnostic: ${name}`);
  }
  if (selected.size && !definition.developerDiagnostics) {
    throw new Error(`Diagnostics are default-only; ${product}/${mode} cannot enable ${[...selected]}`);
  }
  if (selected.has('mg-exhaustive')) selected.add('mg-gl');
  if (selected.has('mg-gl')) selected.add('mg-frames');
  const flags = {};
  let mask = definition.developerDiagnostics ? 1 : 0;
  Object.entries(DIAGNOSTIC_FLAGS).forEach(([name, flag], index) => {
    const enabled = selected.has(name) || (name === 'tests' && definition.developerDiagnostics && mode === 'debug');
    flags[flag] = enabled ? 'ON' : 'OFF';
    if (enabled) mask |= 1 << (index + 1);
  });
  return { mode, diagnostics: [...selected].sort(), mask, flags };
}

export function diagnosticArguments(product, mode, requested) {
  const profile = diagnosticProfile(product, mode, requested);
  return Object.entries(profile.flags).map(([key, value]) => `-D${key}=${value}`).join(' ');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const value = (flag, fallback) => { const i = process.argv.indexOf(flag); return i < 0 ? fallback : process.argv[i + 1]; };
  try {
    const product = value('--product', 'default');
    const mode = value('--mode', 'auto');
    const requested = value('--diagnostics', process.env.AMCL_DIAGNOSTICS ?? 'none');
    console.log(process.argv.includes('--arguments') ? diagnosticArguments(product, mode, requested)
      : JSON.stringify(diagnosticProfile(product, mode, requested)));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}

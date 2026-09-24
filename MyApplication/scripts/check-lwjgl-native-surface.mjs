// Validate the LWJGL 3.4.2 OHOS native build before it replaces the modern slot.
// Compares exported Java_* entry points with the exact pinned source tree and
// enforces AArch64/ELF/NEEDED/C++ ABI rules.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, '..');
const SOURCE_ROOT = join(ROOT, 'prebuilt', 'lwjgl3', 'lwjgl3_src', 'modules', 'lwjgl');

function fail(message) { throw new Error(message); }

export function locateReadelf() {
  if (process.env.OHOS_LLVM_READELF && existsSync(process.env.OHOS_LLVM_READELF)) {
    return process.env.OHOS_LLVM_READELF;
  }
  const localProperties = join(ROOT, 'local.properties');
  if (existsSync(localProperties)) {
    const match = /^hwsdk\.dir=(.+)$/m.exec(readFileSync(localProperties, 'utf8'));
    if (match) {
      const sdk = match[1].trim().replace(/\\\\/g, '\\');
      const exe = process.platform === 'win32' ? 'llvm-readelf.exe' : 'llvm-readelf';
      const candidate = join(sdk, 'native', 'llvm', 'bin', exe);
      if (existsSync(candidate)) return candidate;
    }
  }
  for (const candidate of ['llvm-readelf', 'readelf']) {
    try {
      execFileSync(candidate, ['--version'], { stdio: 'ignore' });
      return candidate;
    } catch {}
  }
  fail('cannot locate llvm-readelf/readelf; set OHOS_LLVM_READELF');
}

function files(dir, extension, filter = () => true) {
  return readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(extension) && filter(entry.name))
    .map((entry) => join(dir, entry.name));
}

function javaSymbolsFromSources(paths) {
  const symbols = new Set();
  for (const path of paths) {
    const text = readFileSync(path, 'utf8');
    for (const match of text.matchAll(/\bJava_[A-Za-z0-9_]+(?=\s*\()/g)) symbols.add(match[0]);
  }
  return symbols;
}

function setDifference(a, b) {
  return [...a].filter((value) => !b.has(value)).sort();
}

const requiredGeneratedEntries = new Map([
  ['liblwjgl_stb.so', new Set(['Java_org_lwjgl_stb_LibSTB_setupMalloc'])],
  ['liblwjgl_spng.so', new Set(['Java_org_lwjgl_util_spng_LibSPNG_setupMalloc'])],
  ['liblwjgl_vma.so', new Set(['Java_org_lwjgl_util_vma_LibVma_setupMalloc'])],
]);

export function compareJniSurface(name, expectedInput, actualInput) {
  const expected = new Set(expectedInput);
  const actual = new Set(actualInput);
  const required = requiredGeneratedEntries.get(name) || new Set();
  const missing = [...new Set([
    ...setDifference(expected, actual),
    ...setDifference(required, actual),
  ])].sort();
  const extra = setDifference(actual, expected).filter((symbol) => !required.has(symbol));
  return { missing, extra };
}

function moduleSourceMap(sourceRoot) {
  const coreMainNames = new Set([
    'common_tools.c',
    'org_lwjgl_system_MemoryUtil.c',
    'org_lwjgl_system_SharedLibraryUtil.c',
    'org_lwjgl_system_ThreadLocalUtil.c',
    'org_lwjgl_system_Upcalls.c',
    'org_lwjgl_system_Callback.c',
  ]);
  return new Map([
    ['liblwjgl.so', [
      ...files(join(sourceRoot, 'core', 'src', 'main', 'c'), '.c', (name) => coreMainNames.has(name)),
      ...files(join(sourceRoot, 'core', 'src', 'generated', 'c'), '.c'),
      ...files(join(sourceRoot, 'core', 'src', 'generated', 'c', 'linux'), '.c', (name) => !name.includes('liburing')),
    ]],
    ['liblwjgl_opengl.so', files(join(sourceRoot, 'opengl', 'src', 'generated', 'c'), '.c', (name) => name !== 'org_lwjgl_opengl_WGL.c')],
    ['liblwjgl_stb.so', files(join(sourceRoot, 'stb', 'src', 'generated', 'c'), '.c')],
    ['liblwjgl_spng.so', files(join(sourceRoot, 'spng', 'src', 'generated', 'c'), '.c')],
    ['liblwjgl_tinyfd.so', [join(sourceRoot, 'tinyfd', 'src', 'generated', 'c', 'org_lwjgl_util_tinyfd_TinyFileDialogs.c')]],
    ['liblwjgl_vma.so', files(join(sourceRoot, 'vma', 'src', 'generated', 'c'), '.cpp')],
  ]);
}

export function runNativeSurfaceCheck({ sourceRoot = SOURCE_ROOT, output } = {}) {
  const outputDir = resolve(output || join(ROOT, 'docker', 'output', 'lwjgl342'));
  const readelf = locateReadelf();
  for (const [name, sourcePaths] of moduleSourceMap(sourceRoot)) {
    const library = join(outputDir, name);
    if (!existsSync(library) || statSync(library).size <= 0) fail(`missing native output: ${library}`);

    const header = execFileSync(readelf, ['-h', library], { encoding: 'utf8' });
    if (!/Class:\s+ELF64/.test(header) || !/Machine:\s+AArch64/.test(header) || !/Type:\s+DYN/.test(header)) {
      fail(`${name}: expected ELF64 AArch64 shared object`);
    }
    const dynamic = execFileSync(readelf, ['-d', library], { encoding: 'utf8' });
    const needed = [...dynamic.matchAll(/Shared library: \[([^\]]+)\]/g)].map((match) => match[1]);
    const badNeeded = needed.filter((dep) => dep !== 'libc.so' && dep !== 'libc++_shared.so');
    if (badNeeded.length > 0) fail(`${name}: unexpected NEEDED ${badNeeded.join(', ')}`);

    const symbolsText = execFileSync(readelf, ['--dyn-syms', '--wide', library], { encoding: 'utf8' });
    if (/\bUND\b[^\n]*(?:ffi_|\bvk[A-Z]|NSt3__1)/.test(symbolsText)) {
      fail(`${name}: forbidden unresolved ffi/vulkan/std::__1 symbol`);
    }
    if (name === 'liblwjgl_vma.so' && /NSt3__1/.test(symbolsText)) {
      fail('liblwjgl_vma.so was built against std::__1 instead of OHOS std::__n1');
    }

    const actual = new Set([...symbolsText.matchAll(/\bJava_[A-Za-z0-9_]+\b/g)].map((match) => match[0]));
    const expected = javaSymbolsFromSources(sourcePaths);
    if (name === 'liblwjgl_stb.so') {
      const legacy = javaSymbolsFromSources([join(ROOT, 'prebuilt', 'lwjgl3', 'compat', 'stb-v1', 'org_lwjgl_stb_STBImageResize.c')]);
      for (const symbol of legacy) expected.add(symbol.replace('Java_org_lwjgl_stb_STBImageResize_', 'Java_org_lwjgl_stb_STBImageResizeV1_'));
    }
    // VMA exposes Win32-only functions in generated source under preprocessor guards.
    if (name === 'liblwjgl_vma.so') {
      expected.delete('Java_org_lwjgl_util_vma_Vma_nvmaGetMemoryWin32Handle');
      expected.delete('Java_org_lwjgl_util_vma_Vma_nvmaGetMemoryWin32Handle2');
    }
    const { missing, extra } = compareJniSurface(name, expected, actual);
    if (missing.length > 0 || extra.length > 0) {
      fail(`${name}: JNI surface mismatch; missing=${missing.join(',')} extra=${extra.join(',')}`);
    }
    console.log(`[lwjgl-native-surface] ${basename(library)} OK: JNI=${actual.size}, NEEDED=${needed.join(',') || '(none)'}`);
  }
  console.log('[lwjgl-native-surface] all 3.4.2 modern native modules passed');
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) runNativeSurfaceCheck({ output: process.argv[2] });

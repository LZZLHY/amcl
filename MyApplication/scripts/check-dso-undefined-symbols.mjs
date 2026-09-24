#!/usr/bin/env node
/**
 * check-dso-undefined-symbols.mjs — 产物级检查：`libglfw.so` 不得引用本仓自己的符号
 * 而不把定义编进来。
 *
 * ⭐ 为什么需要它（2026-08-23，计划 §86.1）：
 *
 * 本仓的 DSO 依赖是**单向**的 `libentry → libglfw`（`input_bridge_ohos.c` 自述"本库是
 * 宿主 libentry 的 DT_NEEDED 依赖"），`target_link_libraries(glfw ...)` 不含 entry。
 * 于是 libglfw 里任何对 libentry 符号的**按名引用**都是错的，而它**不会在构建期报错**：
 * glfw 目标的 `target_link_options` 没有 `--no-undefined` ⇒ 符号留成 UND、链接静默通过、
 * 加载期才炸。
 *
 * 这个形状已经真实发生过一次：commit `1a27b6c` 把 `GlfwScrollFromWheelPx` 的定义只放进
 * `PLATFORM_SOURCES`（libentry），而 `glfw_compat.cpp` 的 `typedWheelSink` 调它 ⇒
 * libglfw 里留下 `_ZN4amcl5input21GlfwScrollFromWheelPxE...` 一个 UND。
 * **当时四条门禁全绿**：host 断言 30/30、aarch64 交叉编译 PASS、preflight 全绿、
 * `check-product-tu-syntax.mjs` 76/76 —— 因为它们全都只做**编译**，而这是**链接**问题。
 *
 * 判据：`libglfw.so` 的 undefined 符号里**不得出现**本仓自己的命名空间/前缀
 * （`amcl::` / `amcl_` / `ohos_` / `inputBridge_`）。实测干净基线是 **0 个**
 * （297 个 UND 全部是 libc/libc++/EGL/GLES/hilog 之类的系统符号），所以这条判据不需要
 * 白名单，也就没有"白名单越加越松"的退化路径。
 *
 * ⚠️ 边界（刻意的）：
 *   1. 需要一次已完成的构建产出 `.so`。找不到时**硬失败**（exit 2），不静默通过 ——
 *      "没有产物"与"检查通过"必须可区分。这与 `check-product-tu-syntax.mjs` 同一条纪律。
 *   2. 产物可能过期。脚本报出 mtime，但无法判断它是否对应当前源码。
 *   3. 只查 libglfw。libentry 反向依赖 libglfw 是**合法**的（那是 DT_NEEDED 方向），
 *      所以 libentry 的 UND 里出现 `inputBridge_*` 是预期的，不是缺陷。
 */
import { existsSync, readFileSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readElfIdentity } from './check-mg-build-contract.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const PRODUCT = arg('product', 'default');
const TARGET = arg('target', 'default');
const SO_CANDIDATES = [
  `entry/build/${PRODUCT}/intermediates/cmake/${TARGET}/obj/arm64-v8a/libglfw.so`,
  `entry/build/${PRODUCT}/intermediates/libs/${TARGET}/arm64-v8a/libglfw.so`,
  `entry/build/${PRODUCT}/intermediates/stripped_native_libs/${TARGET}/arm64-v8a/libglfw.so`,
];

const NM_CANDIDATES = [
  'D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin/llvm-nm.exe',
  'D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin/llvm-nm',
  '/usr/bin/llvm-nm',
  'llvm-nm',
];

// 本仓自己的符号形状。libglfw 里出现这些的 UND ⇒ 引用了它没有链接的 DSO。
const OWN_SYMBOL_PATTERNS = [/amcl/i, /^ohos_/, /^inputBridge_/, /^pojav/];

function firstExisting(candidates, relativeToRoot) {
  for (const candidate of candidates) {
    const absolute = relativeToRoot ? join(ROOT, candidate) : candidate;
    if (existsSync(absolute)) return absolute;
  }
  return null;
}

function resolveNm() {
  const direct = firstExisting(NM_CANDIDATES.slice(0, -1), false);
  if (direct) return direct;
  // 最后一项是裸名，交给 PATH。探一次版本以确认可用。
  try {
    execFileSync('llvm-nm', ['--version'], { stdio: 'pipe' });
    return 'llvm-nm';
  } catch {
    return null;
  }
}

// --so 供真实 ELF 正反例及指定产物复验；缺失路径同样硬失败，不回退到别的旧产物。
const so = arg('so', firstExisting(SO_CANDIDATES, true));
if (!so || !existsSync(so)) {
  console.error('[check-dso-undefined-symbols] FAIL: 找不到已构建的 libglfw.so');
  for (const candidate of SO_CANDIDATES) console.error(`    ${candidate}`);
  console.error('  先跑一次完整构建再跑本门禁。');
  console.error('  ⚠️ 刻意硬失败：「没有产物」不得被读成「检查通过」。');
  process.exit(2);
}

const nm = resolveNm();
if (!nm) {
  console.error('[check-dso-undefined-symbols] FAIL: 找不到 llvm-nm');
  console.error('  ⚠️ 刻意硬失败（fail-closed）：找不到工具不等于没有问题。');
  process.exit(2);
}

let raw = '';
try {
  raw = execFileSync(nm, ['--undefined-only', '--dynamic', so], {
    stdio: 'pipe', maxBuffer: 64 * 1024 * 1024,
  }).toString();
} catch (error) {
  console.error('[check-dso-undefined-symbols] FAIL: llvm-nm 执行失败');
  console.error(String(error.stderr ?? error.message).slice(0, 2000));
  process.exit(2);
}

const undefinedSymbols = raw.split(/\r?\n/)
  .map((line) => line.trim().split(/\s+/).pop() ?? '')
  .filter((name) => name.length > 0);

// A first-party symbol may live in a separately linked graphics runtime. Its
// actual DT_NEEDED edge and dynamic definition must both exist in this variant;
// a name prefix or a source-level CMake declaration alone is not evidence.
const linkedGraphics = new Set();
const readelf = nm.replace(/llvm-nm(?=\.exe$|$)/, 'llvm-readelf');
const dynamic = execFileSync(readelf, ['-d', so], { encoding: 'utf8' });
const needed = [...dynamic.matchAll(/\(NEEDED\).*?\[([^\]]+)\]/g)].map((m) => m[1]);
for (const library of ['libamcl_vulkan_wsi.so', 'libamcl_window_host.so', 'libamcl_gl_host.so', 'libamcl_graphics_runtime.so']) {
  if (!needed.includes(library)) continue;
  const provider = join(dirname(so), library);
  if (!existsSync(provider)) continue;
  const providerIdentity = readElfIdentity(readFileSync(provider));
  if (providerIdentity.soname !== library) continue;
  const defined = execFileSync(nm, ['--defined-only', '--dynamic', provider], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  for (const line of defined.split(/\r?\n/)) {
    const symbol = (line.trim().split(/\s+/).pop() ?? '').split('@')[0];
    if ((library === 'libamcl_vulkan_wsi.so' && /^amclVulkan/.test(symbol)) ||
        (library === 'libamcl_window_host.so' && /^amclWindowHost/.test(symbol)) ||
        (library === 'libamcl_gl_host.so' && /^amclGlHost/.test(symbol)) ||
        (library === 'libamcl_gl_host.so' && /^(?:gl|egl)[A-Z]/.test(symbol)) ||
        (library === 'libamcl_gl_host.so' && /^mg_/.test(symbol)) ||
        // 公共图形运行时既有 C ABI，也有 BackendSession 等跨 DSO C++ 接口。
        // 必须同时存在实际 DT_NEEDED、正确 SONAME 和动态定义，名字前缀本身不能放行。
        (library === 'libamcl_graphics_runtime.so' && (/^amclGraphics/.test(symbol) || /^_Z.*4amcl8graphics/.test(symbol)))) linkedGraphics.add(symbol);
  }
}
const offenders = [...new Set(
  undefinedSymbols.filter((name) => OWN_SYMBOL_PATTERNS.some((p) => p.test(name))),
)].filter((name) => !linkedGraphics.has(name.split('@')[0])).sort();

console.log('[check-dso-undefined-symbols]');
console.log(`  variant: product=${PRODUCT} target=${TARGET}`);
console.log(`  产物: ${so.slice(ROOT.length + 1).replace(/\\/g, '/')}`);
console.log(`  构建于: ${statSync(so).mtime.toISOString()}（过期则不反映当前源码）`);
console.log(`  undefined 符号 ${undefinedSymbols.length} 个，其中本仓符号 ${offenders.length} 个`);

if (offenders.length === 0) {
  console.log('  PASS: libglfw.so 没有引用任何未链接的本仓符号');
  console.log('  ⚠️ 产物可能过期；它只证明「这次构建的 .so 是干净的」。');
  process.exit(0);
}

console.error('\n[check-dso-undefined-symbols] FAIL: libglfw.so 引用了它没有链接的本仓符号');
for (const name of offenders) console.error(`    ${name}`);
console.error('\n  成因几乎总是同一个：某个 TU 的定义只进了 PLATFORM_SOURCES（libentry），');
console.error('  而 libglfw 里的代码按名字调它。依赖方向是 libentry → libglfw，反向不通。');
console.error('  两条修法：① 把那个 TU 也加进 add_library(glfw SHARED ...)（纯函数 TU 适用）；');
console.error('  ② 改用既有的反向 env trampoline 机制（有状态 / 需要 libentry 全局时适用）。');
console.error('  ⚠️ 这类缺陷不会被任何**编译**面门禁抓到，只有产物级检查能抓（计划 §86.1）。');
process.exit(1);

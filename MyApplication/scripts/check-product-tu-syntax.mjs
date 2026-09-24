#!/usr/bin/env node
/**
 * check-product-tu-syntax.mjs — 对**产品 TU**做 aarch64 `-fsyntax-only` 复核。
 *
 * ⭐ 为什么需要它（2026-08-23，计划 §83.9）：
 *
 * 本仓此前的原生验证面有两条，而它们**都不编译产品 TU**：
 *   - `run-host-tests-msvc.ps1` / `run-host-tests-docker.sh` 编译的是
 *     `tests/host/CMakeLists.txt` 里那份**独立目标集**，`glfw_compat.cpp`、
 *     `touch_input.cpp` 这类 2000+ 行的 OHOS TU 根本拉不进来；
 *   - `check-host-tests-crosscompile.ps1` 只是把**同一批 host 目标**换成
 *     aarch64 再编一遍，覆盖面完全相同。
 *
 * 后果实测过一次：commit `7dc3200` 在 `glfw_compat.cpp` 里调用了
 * `amcl::input::GlfwScrollFromWheelPx()` 却**忘了 include 那个头**。29/29 host
 * 断言全绿、交叉编译全绿、preflight 全绿 —— 因为没有任何一条门禁编译过这个文件。
 * 缺陷只会在下一次完整 HAP 构建时才暴露。这是计划 §82.4「从未被执行的代码不是
 * 能工作的代码」的**编译面同型**：从未被编译的代码不是能编译的代码。
 *
 * 做法：复用上一次真实构建留下的 `compile_commands.json`，逐条把 `-c -o` 换成
 * `-fsyntax-only` 重跑。因此它**不是**从零构建，代价只有前端解析。
 *
 * ⚠️ 边界（刻意的，不要误读）：
 *   1. 依赖一次已完成的构建产出 compile db。db 不存在时**硬失败**，不静默通过 ——
 *      "没有 db" 与 "全部通过" 必须可区分。
 *   2. db 可能过期：新增的 TU 不在里面。脚本会报出 db 的时间戳与条目数，但无法
 *      判断"该有的 TU 是不是都在"。它是回归网，不是完整性证明。
 *   3. `-fsyntax-only` 不做代码生成 ⇒ 抓不到链接错误、也抓不到只在实例化后
 *      才失败的模板问题。
 *
 * 用法：
 *   node scripts/check-product-tu-syntax.mjs                # 全部产品 TU
 *   node scripts/check-product-tu-syntax.mjs input platform # 只查路径含关键字的
 *   node scripts/check-product-tu-syntax.mjs --product desktop --target desktop \
 *     --mode release --abi arm64-v8a                         # 精确绑定本轮构建
 */
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

const DB_CANDIDATES = [
  'entry/.cxx/desktop/desktop/release/arm64-v8a/compile_commands.json',
  'entry/.cxx/store/store/release/arm64-v8a/compile_commands.json',
  'entry/.cxx/sideload/sideload/release/arm64-v8a/compile_commands.json',
  'entry/.cxx/default/default/release/arm64-v8a/compile_commands.json',
  'entry/.cxx/default/default/debug/arm64-v8a/compile_commands.json',
];

// 第三方源码不是本仓的责任面，且它们的告警会淹没真信号。
// ⚠️ 归一化后 `'\\build\\'` 与 `'/build/'` 完全等价，留一条即可（上一版两条并存是死项）。
const SKIPPED = ['third_party', 'openal-soft', '/build/', 'mobileglues'];

// 完整性交叉核对用：**按设计**不该出现在产品 compile db 里的源码。
// 只有这份清单之外的缺失才算 db 过期/漏编 —— 否则这个检查会被一堆预期缺失淹没。
const NOT_IN_PRODUCT_DB = [
  // host 测试有自己的 CMakeLists（tests/host/CMakeLists.txt），不属于产品目标。
  { prefix: 'tests/host/', reason: 'host 测试目标，独立 CMakeLists' },
  // MC_OHOS_BUILD_TESTS=OFF（release 显式传，见 CHANGELOG 1000518）。
  { prefix: 'tests/', reason: 'MC_OHOS_BUILD_TESTS=OFF' },
  { prefix: 'download/tests/', reason: 'MC_OHOS_BUILD_TESTS=OFF' },
  // AMCL_INPUT_GATE0_TELEMETRY option 默认 OFF，TU 不参与编译。
  { prefix: 'platform/gate0_input_telemetry.cpp', reason: 'AMCL_INPUT_GATE0_TELEMETRY=OFF' },
  // API22 desktop now disables the optional API26 strong-link probe too.
  { prefix: 'platform/api26_input_link_probe.cpp', reason: '实际 AMCL_API26_LINK_PROBE=OFF',
    flag: 'AMCL_API26_LINK_PROBE', omitValue: false,
    omitUnlessProduct: 'desktop' },
  ...['glfw/glfw_egl.cpp', 'glfw/mg_benchmark_cache.cpp',
    'platform/mg_config.cpp', 'platform/mg_config_migration.cpp'].map(prefix => ({
      prefix, reason: '系统桌面 GL 不编译移动 EGL/MG', flag: 'AMCL_NATIVE_DESKTOP_ONLY', omitValue: true,
    })),
  { prefix: 'glfw/desktop_egl.cpp', reason: '非独立桌面使用移动/兼容 EGL',
    flag: 'AMCL_NATIVE_DESKTOP_ONLY', omitValue: false },
  // The desktop fallback provider is a reference implementation; desktop
  // products route directly through SystemEgl/NativeGl and do not build this TU.
  { prefix: 'platform/gl_host.cpp', reason: '桌面产品 AMCL_NATIVE_DESKTOP_ONLY=ON，不构建 MobileGlues GL host fallback',
    flag: 'AMCL_NATIVE_DESKTOP_ONLY', omitValue: true },
  { prefix: 'platform/gl_host_desktop.cpp', reason: '桌面产品直接使用 SystemEgl/NativeGl，未收录 GL host fallback' },
];

/** 当前产品里，source 是否按设计不进入产品 compile db。未知产品保持 fail-closed。 */
function isExpectedProductDbOmission(source, productName, flags) {
  return NOT_IN_PRODUCT_DB.some((rule) => {
    if (rule.prefix.endsWith('/') ? !source.startsWith(rule.prefix) : source !== rule.prefix) return false;
    if (rule.flag) {
      if (flags[rule.flag] !== undefined) return flags[rule.flag] === rule.omitValue;
      if (!rule.omitUnlessProduct) return false; // Missing cache is not permission to omit.
    }
    if (!rule.omitUnlessProduct) return true;
    return Boolean(productName) && productName !== rule.omitUnlessProduct;
  });
}

/** 枚举 entry/src/main/cpp 下的第一方源文件（相对路径）。 */
function collectFirstPartySources() {
  const base = join(ROOT, 'entry/src/main/cpp');
  const out = [];
  const walk = (absolute, relative) => {
    for (const item of readdirSync(absolute, { withFileTypes: true })) {
      const next = relative ? `${relative}/${item.name}` : item.name;
      if (item.isDirectory()) {
        if (SKIPPED.some((token) => `/${next}/`.toLowerCase().includes(token))) continue;
        if (next.startsWith('openal/openal-soft')) continue;
        walk(join(absolute, item.name), next);
        continue;
      }
      if (item.isFile() && /\.(c|cc|cpp)$/.test(item.name)) out.push(next);
    }
  };
  if (!existsSync(base)) return out;
  walk(base, '');
  return out;
}

function parseArguments(argv) {
  const options = { filters: [] };
  const names = new Map([
    ['--product', 'product'],
    ['--target', 'target'],
    ['--mode', 'mode'],
    ['--abi', 'abi'],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const key = names.get(argv[index]);
    if (!key) {
      if (argv[index].startsWith('--')) throw new Error(`unknown option: ${argv[index]}`);
      options.filters.push(argv[index]);
      continue;
    }
    if (index + 1 >= argv.length) throw new Error(`incomplete option: ${argv[index]}`);
    const value = argv[++index];
    if (!/^[A-Za-z0-9_.-]+$/.test(value)) throw new Error(`invalid ${key}: ${value}`);
    options[key] = value;
  }
  if (options.product) {
    options.target ??= options.product;
    options.mode ??= 'release';
    options.abi ??= 'arm64-v8a';
  } else if (options.target || options.mode || options.abi) {
    throw new Error('--target/--mode/--abi require --product');
  }
  return options;
}

function findDb(options) {
  if (options.product) {
    const relative = [
      'entry/.cxx', options.product, options.target, options.mode, options.abi,
      'compile_commands.json',
    ].join('/');
    const absolute = join(ROOT, relative);
    return existsSync(absolute)
      ? { relative, absolute, product: options.product }
      : { relative, absolute, product: options.product, missing: true };
  }
  for (const relative of DB_CANDIDATES) {
    const absolute = join(ROOT, relative);
    if (existsSync(absolute)) {
      const product = relative.split('/')[2];
      return { relative, absolute, product };
    }
  }
  return null;
}

/**
 * compile db 的 command 是一整串 **shell 命令**；拆成 argv 并做 POSIX 双引号去引。
 *
 * ⚠️ 去引这一步是必需的，不是整洁问题：`execFileSync` 不经 shell，引号会原样进到
 * 编译器。db 里同时存在两种形状 ——
 *   `-DAL_API=""`      shell 会去掉引号 ⇒ 宏值为**空**；不去引就变成字面量 `""`，
 *                      于是 `"" void alEnable(...)` 报 expected unqualified-id；
 *   `-DFOO=\"none\"`   shell 只吃掉反斜杠 ⇒ 宏值是**字符串字面量** `"none"`。
 *   `--sysroot="... DevEco Studio/..."` 的引号嵌在参数中间，空格仍属于同一个 argv。
 * 所以规则是：`\"` 还原成 `"`，裸 `"` 删掉。两者必须在同一遍里处理，分两次会互相破坏。
 */
function toArgv(entry) {
  if (!entry.command && Array.isArray(entry.arguments)) return [...entry.arguments];

  const raw = entry.command ?? '';
  const tokens = [];
  let token = '';
  let inDoubleQuote = false;
  for (let i = 0; i < raw.length; i++) {
    const char = raw[i];
    if (char === '\\' && raw[i + 1] === '"') {
      token += '"';
      i++;
      continue;
    }
    if (char === '"') {
      inDoubleQuote = !inDoubleQuote;
      continue;
    }
    if (/\s/.test(char) && !inDoubleQuote) {
      if (token) {
        tokens.push(token);
        token = '';
      }
      continue;
    }
    token += char;
  }
  if (inDoubleQuote) throw new Error('unterminated double quote in compile command');
  if (token) tokens.push(token);
  return tokens;
}

let cli;
try {
  cli = parseArguments(process.argv.slice(2));
} catch (error) {
  console.error(`[check-product-tu-syntax] FAIL: ${error.message}`);
  process.exit(2);
}
const db = findDb(cli);
if (!db || db.missing) {
  console.error('[check-product-tu-syntax] FAIL: 找不到 compile_commands.json');
  console.error('  查找过的位置：');
  if (db?.missing) console.error(`    ${db.relative}`);
  else for (const relative of DB_CANDIDATES) console.error(`    ${relative}`);
  console.error('  先跑一次完整构建（或 hvigor assembleHap）生成它，再跑本门禁。');
  console.error('  ⚠️ 刻意硬失败：「没有 compile db」不得被读成「全部通过」。');
  process.exit(2);
}

const entries = JSON.parse(readFileSync(db.absolute, 'utf8'));
const cachePath = join(dirname(db.absolute), 'CMakeCache.txt');
const buildFlags = {};
if (existsSync(cachePath)) {
  for (const [, name, value] of readFileSync(cachePath, 'utf8').matchAll(/^(AMCL_NATIVE_DESKTOP_ONLY|AMCL_API26_LINK_PROBE):BOOL=(.*)$/gm)) {
    if (/^(ON|TRUE|1)$/i.test(value.trim())) buildFlags[name] = true;
    else if (/^(OFF|FALSE|0)$/i.test(value.trim())) buildFlags[name] = false;
  }
}
const filters = cli.filters;
const selected = entries.filter((entry) => {
  const file = entry.file.replace(/\\/g, '/');
  if (SKIPPED.some((token) => file.toLowerCase().includes(token.replace(/\\/g, '/')))) {
    return false;
  }
  if (!file.includes('/entry/src/main/cpp/')) return false;
  if (filters.length === 0) return true;
  return filters.some((filter) => file.includes(filter));
});

console.log('[check-product-tu-syntax]');
console.log(`  compile db: ${db.relative}`);
console.log(`  db 生成于: ${statSync(db.absolute).mtime.toISOString()}（过期则新 TU 不在其中）`);
console.log(`  db 条目 ${entries.length}，本次检查 ${selected.length}`);
if (filters.length) console.log(`  过滤器: ${filters.join(' ')}`);
if (selected.length === 0) {
  console.error('  FAIL: 选中 0 个 TU —— 过滤器写错了，或者 db 的路径形状变了。');
  process.exit(2);
}

const failures = [];
for (const entry of selected) {
  const short = entry.file.replace(/\\/g, '/').split('/entry/src/main/cpp/')[1] ?? entry.file;
  const argv = toArgv(entry);
  const args = [];
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === '-o') { i++; continue; }
    if (argv[i] === '-c') continue;
    args.push(argv[i]);
  }
  args.push('-fsyntax-only');
  try {
    execFileSync(argv[0], args, { cwd: entry.directory, stdio: 'pipe' });
  } catch (error) {
    const text = String(error.stderr ?? error.stdout ?? error.message);
    failures.push({ short, text });
    console.log(`  FAIL  ${short}`);
  }
}

// ⭐ 完整性交叉核对。上一版把"db 会过期"只写成一句备注，而这条边界的第一个受害者就是
// 同一批新增的唯一产品 TU（`glfw_typed_look_route.cpp`）—— 门禁绿 + 一句备注等于没闭合。
// 只在无过滤器（全量模式）下做：带过滤器时"缺失"没有意义。
const stale = [];
if (filters.length === 0) {
  const inDb = new Set(entries
    .map((entry) => entry.file.replace(/\\/g, '/').split('/entry/src/main/cpp/')[1])
    .filter(Boolean));
  for (const source of collectFirstPartySources()) {
    if (inDb.has(source)) continue;
    if (isExpectedProductDbOmission(source, db.product, buildFlags)) continue;
    stale.push(source);
  }
}

if (failures.length === 0 && stale.length === 0) {
  console.log(`  PASS: ${selected.length} 个产品 TU 前端解析通过（aarch64）`);
  if (filters.length === 0) console.log('  完整性交叉核对: 没有源文件缺席 compile db');
  console.log('  ⚠️ -fsyntax-only 不做代码生成 ⇒ 链接错误与部分模板实例化问题抓不到。');
  console.log('  ⚠️ 链接面由 check-dso-undefined-symbols.mjs 覆盖（产物级，需已构建的 .so）。');
  process.exit(0);
}

if (stale.length > 0) {
  console.error(`\n[check-product-tu-syntax] FAIL: ${stale.length} 个第一方源文件不在 compile db 里`);
  for (const source of stale) console.error(`    ${source}`);
  console.error('\n  两种成因，处置不同：');
  console.error('  ① db 过期（新增 TU 之后没重新构建）⇒ 重跑一次构建刷新 db。');
  console.error('  ② 该 TU 根本没被任何 add_library 收录 ⇒ 真缺陷，它从未被编译过。');
  console.error('  若它是**按设计**不进产品构建的（条件编译 / 测试专用），加进脚本里的');
  console.error('  NOT_IN_PRODUCT_DB 并写清理由 —— 不要为了让门禁变绿而放宽枚举范围。');
}

if (failures.length > 0) {
  console.error(`\n[check-product-tu-syntax] FAIL: ${failures.length} 个 TU 解析失败`);
  for (const failure of failures) {
    console.error(`\n===== ${failure.short} =====`);
    console.error(failure.text.split('\n').filter((line) => /error:/.test(line)).join('\n')
      || failure.text.slice(0, 2000));
  }
}
process.exit(1);

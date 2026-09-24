#!/usr/bin/env node
// scripts/check-glfw-surface.mjs
//
// GLFW native 符号覆盖检查（方案 B）。
//
// 方案 B：lwjgl-glfw.jar 用 LWJGL **上游原版** GLFW.class（252 方法全在），GLFW 的 C 符号
// 由 libglfw.so 导出（标准 GLFW C ABI），上游 Java 绑定经 org.lwjgl.glfw.libname + libffi 直接调。
// 风险点：libglfw.so 若缺某个上游会查的 C 符号 → GLFW 类初始化（必需符号）或调用时（Optional
// 符号被调用，如 MC 26.1 的 IME 回调）抛异常崩溃。
//
// 本脚本核对：上游 generated GLFW.java 里 apiGetFunctionAddress[Optional](GLFW, "glfwXxx") 列出的
// 全部 C 符号（118 必需 + 7 Optional），是否都在 entry/src/main/cpp/glfw/*.{cpp,c} 里实现。
//   - 必需符号缺失 → 一定崩（类初始化），硬失败。
//   - Optional 符号缺失 → 被实际调用时才崩（MC 26.1 IME NPE 就是这么来的），默认也按硬失败处理
//     （阈值 --max-optional-missing 控制；方案 B 下应 0）。
// 另外校验 native glfw_compat.cpp 的 glfwGetVersionString 版本号与 deps.lock 部署版本一致。
//
// 退出码：0 = 通过；非 0 = 超阈值。
// 用法：
//   node scripts/check-glfw-surface.mjs
//   node scripts/check-glfw-surface.mjs --list      # 打印完整缺失清单
//   node scripts/check-glfw-surface.mjs --json       # 机器可读输出
//   node scripts/check-glfw-surface.mjs --max-native-missing=0 --max-optional-missing=0

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

const argv = process.argv.slice(2);
const hasFlag = (k) => argv.includes(`--${k}`);
const optNum = (k, def) => {
  const m = argv.find((a) => a.startsWith(`--${k}=`));
  return m ? parseInt(m.slice(k.length + 3), 10) : def;
};

// 默认阈值：方案 B 要求 native 导出全部 GLFW 符号（必需 + Optional 都 0 缺失）。
const DEFAULTS = {
  maxNativeMissing: optNum('max-native-missing', 0),
  maxOptionalMissing: optNum('max-optional-missing', 0),
};

const UPSTREAM_GLFW = path.join(
  ROOT,
  'prebuilt/lwjgl3/lwjgl3_src/modules/lwjgl/glfw/src/generated/java/org/lwjgl/glfw/GLFW.java',
);
const NATIVE_GLFW_DIR = path.join(ROOT, 'entry/src/main/cpp/glfw');
const NATIVE_COMPAT = path.join(NATIVE_GLFW_DIR, 'glfw_compat.cpp');

function color(s, c) {
  return process.stdout.isTTY ? `\x1b[${c}m${s}\x1b[0m` : s;
}
const red = (s) => color(s, 31);
const green = (s) => color(s, 32);
const yellow = (s) => color(s, 33);
const dim = (s) => color(s, 90);

function readOrDie(p, label) {
  if (!fs.existsSync(p)) {
    console.error(red(`[check-glfw-surface] missing ${label}: ${p}`));
    console.error(dim('  (submodule not checked out? run `git submodule update --init`)'));
    process.exit(2);
  }
  return fs.readFileSync(p, 'utf8');
}

// ── 上游 distinct glfw* 公共方法名（仅供信息展示）──────────────
function upstreamMethods(text) {
  const set = new Set();
  const re = /public static\b[^\n;{]*?\b(glfw[A-Za-z0-9_]+)\s*\(/g;
  let m;
  while ((m = re.exec(text))) set.add(m[1]);
  return set;
}

// ── 上游必需 / 可选 C 符号 ──────────────────────────────────────
function upstreamSymbols(text) {
  const required = new Set();
  const optional = new Set();
  const reReq = /apiGetFunctionAddress\(\s*GLFW\s*,\s*"(glfw[A-Za-z0-9_]+)"\s*\)/g;
  const reOpt = /apiGetFunctionAddressOptional\(\s*GLFW\s*,\s*"(glfw[A-Za-z0-9_]+)"\s*\)/g;
  let m;
  while ((m = reReq.exec(text))) required.add(m[1]);
  while ((m = reOpt.exec(text))) optional.add(m[1]);
  // reReq 锚定 "apiGetFunctionAddress("，不会命中 "...Optional("；保险起见从 required 剔除 optional。
  for (const o of optional) required.delete(o);
  return { required, optional };
}

// ── native 实现的 C 符号（定义或前向声明都算"可导出"）──────────
function nativeImplementedSymbols(dir) {
  const set = new Set();
  const files = fs.readdirSync(dir).filter((f) => /\.(c|cpp)$/.test(f));
  const reAny = /\b(glfw[A-Za-z0-9_]+)\s*\(/g;
  for (const f of files) {
    const txt = fs.readFileSync(path.join(dir, f), 'utf8');
    let m;
    while ((m = reAny.exec(txt))) set.add(m[1]);
  }
  return set;
}

// native glfw_compat.cpp 的版本串
function nativeVersionNum() {
  if (!fs.existsSync(NATIVE_COMPAT)) return { str: null, num: null };
  const txt = fs.readFileSync(NATIVE_COMPAT, 'utf8');
  const m = txt.match(/glfwGetVersionString\(void\)\s*\{\s*return\s*"([^"]+)"/);
  const str = m ? m[1] : null;
  const num = str ? (str.match(/\d+\.\d+\.\d+/) || [null])[0] : null;
  return { str, num };
}

// deps.lock [lwjgl-jars].version
function deployedVersion() {
  try {
    const t = fs.readFileSync(path.join(ROOT, 'deps.lock'), 'utf8');
    return (t.match(/\[lwjgl-jars\][\s\S]*?^\s*version\s*=\s*([0-9.]+)/im) || [, null])[1];
  } catch {
    return null;
  }
}

// ── run ────────────────────────────────────────────────────────
const upstreamText = readOrDie(UPSTREAM_GLFW, 'upstream GLFW.java (submodule)');

const upMethods = upstreamMethods(upstreamText);
const { required, optional } = upstreamSymbols(upstreamText);
const nativeSyms = nativeImplementedSymbols(NATIVE_GLFW_DIR);

const nativeMissing = [...required].filter((x) => !nativeSyms.has(x)).sort();
const nativeOptMissing = [...optional].filter((x) => !nativeSyms.has(x)).sort();
const nv = nativeVersionNum();
const depVer = deployedVersion();

const result = {
  deployedVersion: depVer,
  upstreamDistinctMethods: upMethods.size,
  requiredSymbolCount: required.size,
  optionalSymbolCount: optional.size,
  nativeMissingRequiredCount: nativeMissing.length,
  nativeMissingRequired: nativeMissing,
  nativeMissingOptionalCount: nativeOptMissing.length,
  nativeMissingOptional: nativeOptMissing,
  nativeVersion: nv.str,
  nativeVersionNum: nv.num,
  thresholds: DEFAULTS,
};

if (hasFlag('json')) {
  console.log(JSON.stringify(result, null, 2));
}

const reqOk = nativeMissing.length <= DEFAULTS.maxNativeMissing;
const optOk = nativeOptMissing.length <= DEFAULTS.maxOptionalMissing;
const versionMismatch = depVer && nv.num && depVer !== nv.num;
const ok = reqOk && optOk; // 版本不一致只 WARN，不阻断（升级中途允许临时不一致）

if (!hasFlag('json')) {
  console.log(`\n=== GLFW Surface Check (Plan B) ===\n`);
  console.log(`deployed version (deps.lock): ${depVer}`);
  console.log(`upstream (submodule): ${UPSTREAM_GLFW.replace(ROOT + path.sep, '')}`);
  console.log(`  distinct glfw* methods : ${upMethods.size}`);
  console.log(`  required C symbols     : ${required.size}`);
  console.log(`  optional C symbols     : ${optional.size}`);
  console.log('');
  console.log(
    `${reqOk ? green(' OK ') : red('FAIL')}  native-required    : 缺 ${nativeMissing.length} / ${required.size} 必需符号 (阈值 ${DEFAULTS.maxNativeMissing})`,
  );
  console.log(
    `${optOk ? green(' OK ') : red('FAIL')}  native-optional    : 缺 ${nativeOptMissing.length} / ${optional.size} Optional 符号 (阈值 ${DEFAULTS.maxOptionalMissing})`,
  );
  console.log(
    `${versionMismatch ? yellow('WARN') : green(' OK ')}  version-sync       : deps.lock=${depVer}  native="${nv.str}" (${nv.num})`,
  );
  if (versionMismatch) {
    console.log(yellow(`       ⚠️ native 版本串与 deps.lock 部署版本不一致，升级时需同步刷新 glfw_compat.cpp。`));
  }

  if (hasFlag('list')) {
    if (nativeMissing.length) {
      console.log(`\n${red('native 缺失的必需 C 符号:')}`);
      for (const m of nativeMissing) console.log(`  - ${m}`);
    }
    if (nativeOptMissing.length) {
      console.log(`\n${yellow('native 缺失的 Optional C 符号（被调用即崩，方案 B 也应补全）:')}`);
      for (const m of nativeOptMissing) console.log(`  - ${m}`);
    }
  } else if (nativeMissing.length || nativeOptMissing.length) {
    console.log(dim(`\n  (加 --list 查看完整缺失清单)`));
  }

  console.log(`\n=== ${ok ? green('PASS') : red('FAIL')} ===\n`);
}

process.exit(ok ? 0 : 1);

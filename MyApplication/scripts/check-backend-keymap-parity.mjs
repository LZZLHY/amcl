#!/usr/bin/env node
// scripts/check-backend-keymap-parity.mjs
//
// ============================ 它挡的是什么 ============================
//
// 迁移的核心命题：**新的"一步"映射必须与旧的"两步"逐条相同。**
//
// 旧架构里物理键要翻两次：
//   OHOS keyCode --(1)--> GLFW key --(2)--> 后端编码
//   (1) = `glfw_input_adapter.cpp` 的 `MapOhosKey`
//   (2) = LWJGL2: `AMCLDisplay.glfwToLwjgl2Key`（Java，DirectInput 扫描码）
//        SDL3 : SDL patch 的 `OPENHARMONY_ScancodeFromGlfwKey`（`SDL_Scancode`）
// 新架构里只翻一次：OHOS keyCode --> 后端编码，由本仓的 `backend_keymaps.cpp` 负责。
//
// ⭐ 于是"切过去行为一模一样"这句话第一次成为**可判定命题**：
//        新表[ohos] == 第二步[第一步[ohos]]   对定义域内每一个 ohos 都成立
// 这比"我照着抄了一遍"强得多 —— 抄错一个键，两步复合会把它揪出来。
//
// ============================ 为什么这道门禁必须在删掉两步之前存在 ============================
//
// 两步那条链现在**是工作的**（LWJGL2/SDL3 今天就靠它，在 bit10 打开之前）。所以它是
// 迁移期唯一的"已知正确"参考。等新表上线、外部 .so 改完之后，两步链才会被删 —— 而删掉
// 那一刻本门禁会失去参考侧，必须同时把它改成"新表自己的回归基线"（届时用
// `--update-baseline` 冻结一次），不能让它静默退化成永绿。**这条转换是有意留在这里的
// 待办，而不是等人发现。**
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不证明任何一份表本身是对的（是否符合 DirectInput / USB HID 规范），只证明**三份表
//    互相一致**。旧表错了，新表会被要求一起错 —— 这是刻意的：迁移不该顺手改行为。
// ❌ 不覆盖鼠标按钮（三个后端的按钮域各不相同，不是同一张表的三份）。
// ❌ 不覆盖 `scanCode`/`rawcode` 的取值（原理性不等价，见计划 §93.5）。
// ❌ 不覆盖 modifier / lockState 推导。
//
// 用法：
//   node scripts/check-backend-keymap-parity.mjs           # 门禁
//   node scripts/check-backend-keymap-parity.mjs --json
//   node scripts/check-backend-keymap-parity.mjs --emit=lwjgl2   # 生成 C++ switch 体
//   node scripts/check-backend-keymap-parity.mjs --emit=sdl3

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

export const SOURCES = {
  ohosToGlfw: 'entry/src/main/cpp/input/adapters/glfw_input_adapter.cpp',
  glfwToLwjgl2: 'prebuilt/lwjgl2/patches/java/org/lwjgl/opengl/AMCLDisplay.java',
  glfwToSdlSymbolic: 'prebuilt/sdl3/patches/0001-openharmony-host-window-input-and-backend-fixes.patch',
  sdlScancodeValues: 'prebuilt/lwjgl3/lwjgl3_src/modules/lwjgl/sdl/src/generated/java/org/lwjgl/sdl/SDLScancode.java',
  backendKeymaps: 'entry/src/main/cpp/input/adapters/backend_keymaps.cpp',
};

class ParityError extends Error {}

function readAll(root = ROOT) {
  const out = {};
  for (const [key, rel] of Object.entries(SOURCES)) {
    const abs = path.join(root, rel);
    if (!fs.existsSync(abs)) {
      out[key] = null;  // 缺文件由 analyze 报成 fatal，不静默当空表
      continue;
    }
    out[key] = fs.readFileSync(abs, 'utf8');
  }
  return out;
}

function bracedBody(text, openIndex, what) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    else if (text[i] === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(openIndex + 1, i);
    }
  }
  throw new ParityError(`${what}: 花括号不配对`);
}

/** 取函数体，剥注释、空白归一。`stripPlus` 用于 patch（行首 `+`）。 */
function functionBody(text, marker, what, stripPlus = false) {
  if (text === null) throw new ParityError(`${what}: 源文件不存在`);
  const src = stripPlus ? text.replace(/^\+/gm, '') : text;
  const at = src.indexOf(marker);
  if (at < 0) throw new ParityError(`${what}: 找不到锚点 ${JSON.stringify(marker)}`);
  const open = src.indexOf('{', at);
  if (open < 0) throw new ParityError(`${what}: 锚点之后没有 {`);
  return bracedBody(src, open, what)
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function setEntry(map, key, value, side) {
  if (map.has(key)) {
    throw new ParityError(`${side}: ${key} 出现两次（${map.get(key)} 与 ${value}）`);
  }
  map.set(key, value);
}

/** OHOS keyCode → GLFW key（C++，区间 + case，与 check-keymap-parity 同一形状）。 */
export function parseOhosToGlfw(text) {
  const body = functionBody(text, 'bool MapOhosKey(', 'MapOhosKey');
  const table = new Map();
  let rest = body.replace(
    /(?:else if|if) \(physicalKey >= (\d+)u && physicalKey <= (\d+)u\) \{ mapped = (\d+) \+ static_cast<int32_t>\(physicalKey - (\d+)u\); \}/g,
    (_m, lo, hi, base, offsetBase) => {
      if (offsetBase !== lo) throw new ParityError(`MapOhosKey: 区间基准不自洽 ${lo}/${offsetBase}`);
      for (let v = Number(lo); v <= Number(hi); v += 1) {
        setEntry(table, v, Number(base) + (v - Number(lo)), 'OHOS→GLFW');
      }
      return ' ';
    });
  rest = rest.replace(/case (\d+)u: mapped = (\d+); break;/g, (_m, k, v) => {
    setEntry(table, Number(k), Number(v), 'OHOS→GLFW');
    return ' ';
  });
  if (!/default: return false;/.test(rest)) {
    throw new ParityError('MapOhosKey: 兜底语义变了');
  }
  if (/mapped = /.test(rest.replace(/mapped = 0;/g, ' ')) || /case \d+u/.test(rest)) {
    throw new ParityError(`MapOhosKey: 有未识别的写法: ${rest.slice(0, 200)}`);
  }
  return table;
}

/** GLFW key → LWJGL2（Java，一行可有多个 case，值是十六进制）。 */
export function parseGlfwToLwjgl2(text) {
  const body = functionBody(text, 'private static int glfwToLwjgl2Key(int g)', 'glfwToLwjgl2Key');
  const table = new Map();
  const rest = body.replace(/case (\d+): return (0x[0-9A-Fa-f]+);/g, (_m, k, v) => {
    setEntry(table, Number(k), Number(v), 'GLFW→LWJGL2');
    return ' ';
  });
  if (!/default: return 0;/.test(rest)) {
    throw new ParityError('glfwToLwjgl2Key: 兜底语义变了（期望 default: return 0）');
  }
  if (/case \d+:/.test(rest)) {
    throw new ParityError(`glfwToLwjgl2Key: 有未识别的 case: ${rest.slice(0, 200)}`);
  }
  return table;
}

/** SDL_SCANCODE_* 符号 → 数值。 */
export function parseSdlScancodeValues(text) {
  if (text === null) throw new ParityError('SDLScancode.java: 源文件不存在');
  const out = new Map();
  const re = /(SDL_SCANCODE_\w+)\s*=\s*(\d+)/g;
  let m;
  while ((m = re.exec(text)) !== null) out.set(m[1], Number(m[2]));
  if (out.size === 0) throw new ParityError('SDLScancode.java: 没解析出任何常量');
  return out;
}

/** GLFW key → SDL_Scancode 数值（patch 内符号表 + 上面的数值表）。 */
export function parseGlfwToSdl(patchText, values) {
  const body = functionBody(
    patchText, 'static SDL_Scancode OPENHARMONY_ScancodeFromGlfwKey(int key)',
    'OPENHARMONY_ScancodeFromGlfwKey', true);
  const table = new Map();
  const rest = body.replace(/case (\d+): return (SDL_SCANCODE_\w+);/g, (_m, k, sym) => {
    if (!values.has(sym)) throw new ParityError(`GLFW→SDL: 未知 scancode 符号 ${sym}`);
    setEntry(table, Number(k), values.get(sym), 'GLFW→SDL');
    return ' ';
  });
  if (!/default: return SDL_SCANCODE_UNKNOWN;/.test(rest)) {
    throw new ParityError('OPENHARMONY_ScancodeFromGlfwKey: 兜底语义变了');
  }
  if (/case \d+:/.test(rest)) {
    throw new ParityError(`OPENHARMONY_ScancodeFromGlfwKey: 未识别 case: ${rest.slice(0, 200)}`);
  }
  return table;
}

/** 新的一步表（C++，纯 case 列表 —— 目标编码不连续，刻意不用区间）。 */
export function parseOneStep(text, fnName) {
  const body = functionBody(text, `bool ${fnName}(`, fnName);
  const table = new Map();
  const rest = body.replace(/case (\d+)u: mapped = (\d+); break;/g, (_m, k, v) => {
    setEntry(table, Number(k), Number(v), fnName);
    return ' ';
  });
  if (!/default: return false;/.test(rest)) {
    throw new ParityError(`${fnName}: 兜底语义变了（期望 default: return false;）`);
  }
  if (/mapped = /.test(rest.replace(/mapped = 0;/g, ' ')) || /case \d+u/.test(rest)) {
    throw new ParityError(`${fnName}: 有未识别的写法: ${rest.slice(0, 200)}`);
  }
  return table;
}

function comparePlane(name, oneStep, ohosToGlfw, glfwToTarget, report) {
  const expected = new Map();
  for (const [ohos, glfw] of ohosToGlfw) {
    const target = glfwToTarget.get(glfw);
    // 第二步没有这个 GLFW 键 ⇒ 旧链在这里也发不出东西，新表必须同样不映射它。
    if (target === undefined || target === 0) continue;
    expected.set(ohos, target);
  }
  const plane = { name, expected: expected.size, actual: oneStep.size, missing: [], extra: [], mismatch: [] };
  for (const [ohos, want] of expected) {
    if (!oneStep.has(ohos)) plane.missing.push({ ohos, expected: want });
    else if (oneStep.get(ohos) !== want) {
      plane.mismatch.push({ ohos, expected: want, actual: oneStep.get(ohos) });
    }
  }
  for (const [ohos, got] of oneStep) {
    if (!expected.has(ohos)) plane.extra.push({ ohos, actual: got });
  }
  report.planes.push(plane);
  return plane.missing.length === 0 && plane.extra.length === 0 && plane.mismatch.length === 0;
}

export function analyze(texts) {
  const report = { ok: false, ohosToGlfw: 0, planes: [], fatal: null };
  try {
    const ohosToGlfw = parseOhosToGlfw(texts.ohosToGlfw);
    const glfwToLwjgl2 = parseGlfwToLwjgl2(texts.glfwToLwjgl2);
    const sdlValues = parseSdlScancodeValues(texts.sdlScancodeValues);
    const glfwToSdl = parseGlfwToSdl(texts.glfwToSdlSymbolic, sdlValues);
    const lwjgl2OneStep = parseOneStep(texts.backendKeymaps, 'Lwjgl2MapOhosKey');
    const sdl3OneStep = parseOneStep(texts.backendKeymaps, 'Sdl3MapOhosKey');
    report.ohosToGlfw = ohosToGlfw.size;
    const a = comparePlane('lwjgl2', lwjgl2OneStep, ohosToGlfw, glfwToLwjgl2, report);
    const b = comparePlane('sdl3', sdl3OneStep, ohosToGlfw, glfwToSdl, report);
    report.ok = a && b && ohosToGlfw.size > 0;
  } catch (e) {
    if (e instanceof ParityError) { report.fatal = e.message; return report; }
    throw e;
  }
  return report;
}

/** `--emit=` 模式：按两步复合生成一步表的 C++ switch 体。 */
function emit(which, texts) {
  const ohosToGlfw = parseOhosToGlfw(texts.ohosToGlfw);
  const target = which === 'lwjgl2'
    ? parseGlfwToLwjgl2(texts.glfwToLwjgl2)
    : parseGlfwToSdl(texts.glfwToSdlSymbolic, parseSdlScancodeValues(texts.sdlScancodeValues));
  const rows = [...ohosToGlfw.entries()]
    .map(([ohos, glfw]) => [ohos, target.get(glfw)])
    .filter(([, v]) => v !== undefined && v !== 0)
    .sort((x, y) => x[0] - y[0]);
  for (const [ohos, value] of rows) {
    process.stdout.write(`            case ${ohos}u: mapped = ${value}; break;\n`);
  }
  process.stderr.write(`[emit ${which}] ${rows.length} entries\n`);
}

function main() {
  const texts = readAll();
  const emitArg = process.argv.find((a) => a.startsWith('--emit='));
  if (emitArg) { emit(emitArg.slice('--emit='.length), texts); return; }
  const report = analyze(texts);
  if (process.argv.includes('--json')) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } else if (report.fatal) {
    console.error(`FATAL ${report.fatal}`);
  } else if (report.ok) {
    const sizes = report.planes.map((p) => `${p.name}=${p.actual}`).join(' ');
    console.log(`OK backend keymap parity: OHOS->GLFW ${report.ohosToGlfw} keys; one-step ${sizes}`);
  } else {
    for (const p of report.planes) {
      for (const d of p.mismatch) {
        console.error(`MISMATCH ${p.name} ohos=${d.ohos} expected=${d.expected} actual=${d.actual}`);
      }
      for (const d of p.missing) console.error(`MISSING  ${p.name} ohos=${d.ohos} -> ${d.expected}`);
      for (const d of p.extra) console.error(`EXTRA    ${p.name} ohos=${d.ohos} -> ${d.actual}`);
    }
  }
  process.exit(report.ok ? 0 : 1);
}

export { readAll };

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url))) {
  main();
}

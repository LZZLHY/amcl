#!/usr/bin/env node
// scripts/check-keymap-parity.mjs
//
// ============================ 它挡的是什么 ============================
//
// 物理键盘的 OHOS keyCode → GLFW key 映射在本仓写了**两遍**，一份 ArkTS 一份 C++：
//   · legacy 平面：`gamecontrol/src/main/ets/KeyMap.ets` 的 `glfwKeyFromOhos`
//     （ArkTS 先算好 glfwKey，作为 `physicalKeyTransaction` 的 mappedKey 实参过界）
//   · typed  平面：`entry/src/main/cpp/input/adapters/glfw_input_adapter.cpp` 的 `MapOhosKey`
//     （typed adapter 拿 raw physicalKey 自己再翻一次）
//
// ⚠️ 键盘**没有** native 事件源：两条平面吃的是**同一个** ArkTS 事件、同一次 NAPI 调用，
// 分叉发生在 ingress 之后。所以两份表一旦不一致，**同一次按键在两条平面上会变成不同的
// GLFW 键** —— 而在此之前没有任何机制会提示：两侧各自编译通过、各自的测试也全绿，
// 因为分叉落在两个语言的缝里（与 §91 那条"拒绝路径余量处置"同一形状：
// 穷举了每一层，没穷举它们的组合）。
//
// 2026-08-24 首次执行时两份表**逐条一致**（106 键）。所以这道门禁不是在修一个缺陷，
// 是把"当前恰好一致"这个事实钉住 —— 它的价值全在将来某人只改一侧的那一天。
//
// ============================ 为什么是门禁而不是 codegen ============================
//
// 原计划是"从一份 keymap.json codegen 两侧"，并把 `joystick_sector` 当先例。**先例是假的**：
// 那里没有机器可读的源、没有生成脚本、也没有跨侧比对，只有两处注释里的规格表 + 两侧各自
// 按纸面表断言，同步靠人。codegen 还要额外背一道"产物过期"门禁，否则它自己就是新的分叉源。
// 门禁直接判定要防的那件事（两侧数值必须相同），不引入生成物，代价小一个量级。
//
// ============================ 它不能证明什么 ============================
//
// ❌ 不覆盖 `scanCode`。那是**原理性**不等价（legacy 源头恒 0 → `dispatchAggregateKey` 兜底成
//    key；typed 带真 `hardwareScanCode`），已被 `glfw_source_plane_aggregate_test` 固化成期望。
//    任何键的双平面差分命题都必须显式排除它。
// ❌ 不覆盖鼠标按钮表。`glfwMouseFromOhos`（ArkUI 顺序枚举 N→N−1）与 `MapOhosButton`
//    （OH_NativeXComponent 位标识 1/2/4/8/16）**输入域根本不同**，不是同一张表的两份。
// ❌ 不覆盖 fallback 语义差异（ArkTS 返回 0 哨兵 / C++ 返回 false + unsupportedMapping 诊断）。
//    这里只判定"被支持的那些键映射到同一个值"与"支持集合相同"。
// ❌ 不覆盖 `mods` 与 lockState 组装、`isPrintableOhosKey` / `ohosKeyToCodepoint`（ArkTS 独有）。
// ❌ 不证明映射本身是对的（是否符合 GLFW 3.x 与 SDK 真值）。它只证明两侧**一致**。
// ❌ `entry/oh_modules/gamecontrol/**` 那份物理副本不查：它是安装期生成、不进 git。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

export const SOURCES = {
  ohosKeyCodes: 'gamecontrol/src/main/ets/OhosKeyCodes.ets',
  glfwKeys: 'gamecontrol/src/main/ets/GlfwKeys.ets',
  keyMap: 'gamecontrol/src/main/ets/KeyMap.ets',
  adapter: 'entry/src/main/cpp/input/adapters/glfw_input_adapter.cpp',
};

class ParityError extends Error {}

/** `export const NAME = 123` / `= 0x10`，允许 `=` 两侧任意空白。 */
function parseExportedConstants(text, prefix) {
  const out = new Map();
  const re = new RegExp(`^export const (${prefix}\\w+)\\s*=\\s*(0[xX][0-9a-fA-F]+|-?\\d+)`, 'gm');
  let m;
  while ((m = re.exec(text)) !== null) {
    out.set(m[1], Number(m[2]));
  }
  return out;
}

/** 取 `openIndex` 处 `{` 配对的 `}`，返回体内文本。花括号不配对时硬失败。 */
function bracedBody(text, openIndex) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    else if (text[i] === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(openIndex + 1, i);
    }
  }
  throw new ParityError(`unbalanced braces from index ${openIndex}`);
}

/** 从 `marker` 之后的第一个 `{` 起取函数体，注释剥掉、空白归一。 */
function normalizedFunctionBody(text, marker, what) {
  const at = text.indexOf(marker);
  if (at < 0) throw new ParityError(`${what}: 找不到锚点 ${JSON.stringify(marker)}`);
  const open = text.indexOf('{', at);
  if (open < 0) throw new ParityError(`${what}: 锚点之后没有 {`);
  return bracedBody(text, open)
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** 逐段 exec，把命中的原文从 body 里挖掉，剩下的交给残留检查。 */
function consume(body, re, onMatch) {
  let count = 0;
  const rest = body.replace(re, (...args) => {
    onMatch(args);
    count += 1;
    return ' ';
  });
  return { rest, count };
}

function addEntry(map, ohos, glfw, side) {
  if (map.has(ohos)) {
    throw new ParityError(`${side}: OHOS ${ohos} 被映射了两次（${map.get(ohos)} 与 ${glfw}）`);
  }
  map.set(ohos, glfw);
}

function expandRange(map, ohosLo, ohosHi, glfwBase, side) {
  if (!(ohosHi >= ohosLo)) {
    throw new ParityError(`${side}: 区间上下界颠倒 ${ohosLo}..${ohosHi}`);
  }
  for (let v = ohosLo; v <= ohosHi; v += 1) {
    addEntry(map, v, glfwBase + (v - ohosLo), side);
  }
}

/** ArkTS 侧：常量名 → 值靠 OhosKeyCodes.ets / GlfwKeys.ets 解析，解析不到即硬失败。 */
function parseArkTsTable({ ohosKeyCodesText, glfwKeysText, keyMapText }) {
  const ohos = parseExportedConstants(ohosKeyCodesText, 'OHOS_');
  const glfw = parseExportedConstants(glfwKeysText, 'GLFW_');
  if (ohos.size === 0) throw new ParityError('OhosKeyCodes.ets 没解析出任何 OHOS_ 常量');
  if (glfw.size === 0) throw new ParityError('GlfwKeys.ets 没解析出任何 GLFW_ 常量');

  // KeyMap.ets 内部把 SSOT 常量再别名一次：`const OHOS_KEYCODE_X = OHOS_X`。
  const alias = new Map();
  // 行尾允许带注释（`= OHOS_DEL // Backspace`），所以不锚 `$`。
  const aliasRe = /^const (OHOS_KEYCODE_\w+)\s*=\s*(OHOS_\w+)/gm;
  let am;
  while ((am = aliasRe.exec(keyMapText)) !== null) alias.set(am[1], am[2]);

  const ohosValue = (name) => {
    const target = alias.get(name) ?? name;
    if (!ohos.has(target)) throw new ParityError(`ArkTS: OHOS 常量无法解析: ${name}`);
    return ohos.get(target);
  };
  const glfwValue = (name) => {
    if (!glfw.has(name)) throw new ParityError(`ArkTS: GLFW 常量无法解析: ${name}`);
    return glfw.get(name);
  };

  const body = normalizedFunctionBody(
    keyMapText,
    'export function glfwKeyFromOhos(ohosKey: number): number',
    'KeyMap.ets/glfwKeyFromOhos',
  );

  const table = new Map();
  const ranges = consume(
    body,
    /if \(ohosKey >= (\w+) && ohosKey <= (\w+)\) \{ return (\w+) \+ \(ohosKey - (\w+)\) \}/g,
    ([, lo, hi, base, offsetBase]) => {
      if (offsetBase !== lo) {
        throw new ParityError(`ArkTS: 区间基准不自洽（下界 ${lo}，减的是 ${offsetBase}）`);
      }
      expandRange(table, ohosValue(lo), ohosValue(hi), glfwValue(base), 'ArkTS');
    },
  );
  const cases = consume(ranges.rest, /case (\w+): return (\w+)/g, ([, k, v]) => {
    addEntry(table, ohosValue(k), glfwValue(v), 'ArkTS');
  });

  if (!/default: return 0/.test(cases.rest)) {
    throw new ParityError('ArkTS: 没找到 `default: return 0` 兜底 —— fallback 语义可能变了');
  }
  // 残留检查：任何没被上面两条规则认出来的映射写法都必须让门禁失败，
  // 否则新增一种写法时它会静默漏掉（本仓为"永远为绿的门禁"付过多次学费）。
  const residual = cases.rest.replace(/default: return 0/g, ' ');
  if (/return GLFW_/.test(residual) || /case OHOS/.test(residual)) {
    throw new ParityError(`ArkTS: 函数体里有未被识别的映射写法: ${residual.slice(0, 300)}`);
  }
  return { table, ranges: ranges.count, cases: cases.count };
}

/** C++ 侧：全裸字面量，无常量可解析。 */
function parseCppTable({ adapterText }) {
  const body = normalizedFunctionBody(adapterText, 'bool MapOhosKey(', 'glfw_input_adapter.cpp/MapOhosKey');

  const table = new Map();
  const ranges = consume(
    body,
    /(?:else if|if) \(physicalKey >= (\d+)u && physicalKey <= (\d+)u\) \{ mapped = (\d+) \+ static_cast<int32_t>\(physicalKey - (\d+)u\); \}/g,
    ([, lo, hi, base, offsetBase]) => {
      if (offsetBase !== lo) {
        throw new ParityError(`C++: 区间基准不自洽（下界 ${lo}，减的是 ${offsetBase}）`);
      }
      expandRange(table, Number(lo), Number(hi), Number(base), 'C++');
    },
  );
  const cases = consume(ranges.rest, /case (\d+)u: mapped = (\d+); break;/g, ([, k, v]) => {
    addEntry(table, Number(k), Number(v), 'C++');
  });

  if (!/default: return false;/.test(cases.rest)) {
    throw new ParityError('C++: 没找到 `default: return false;` 兜底 —— fallback 语义可能变了');
  }
  // `mapped` 必须真的成为出参，否则这张表解析出来也不代表运行时行为。
  if (!/outKey->key = mapped;/.test(cases.rest)) {
    throw new ParityError('C++: 没找到 `outKey->key = mapped;` —— 解析出的表可能不是实际出参');
  }
  const residual = cases.rest.replace(/mapped = 0;/g, ' ');
  if (/mapped = /.test(residual) || /case \d+u/.test(residual)) {
    throw new ParityError(`C++: 函数体里有未被识别的映射写法: ${residual.slice(0, 300)}`);
  }
  return { table, ranges: ranges.count, cases: cases.count };
}

export function analyze(texts) {
  const report = {
    ok: false,
    arkTsKeys: 0,
    cppKeys: 0,
    onlyInArkTs: [],
    onlyInCpp: [],
    valueMismatch: [],
    fatal: null,
  };
  let ark;
  let cpp;
  try {
    ark = parseArkTsTable(texts);
    cpp = parseCppTable(texts);
  } catch (e) {
    if (e instanceof ParityError) {
      report.fatal = e.message;
      return report;
    }
    throw e;
  }

  report.arkTsKeys = ark.table.size;
  report.cppKeys = cpp.table.size;
  report.arkTsShape = { ranges: ark.ranges, cases: ark.cases };
  report.cppShape = { ranges: cpp.ranges, cases: cpp.cases };

  for (const [k, v] of ark.table) {
    if (!cpp.table.has(k)) report.onlyInArkTs.push({ ohos: k, glfw: v });
    else if (cpp.table.get(k) !== v) {
      report.valueMismatch.push({ ohos: k, arkTs: v, cpp: cpp.table.get(k) });
    }
  }
  for (const [k, v] of cpp.table) {
    if (!ark.table.has(k)) report.onlyInCpp.push({ ohos: k, glfw: v });
  }
  // ArkTS 的 0 是"不支持"哨兵：任何真实条目映射到 0 会让两种情况不可区分。
  const zeroTargets = [...ark.table].filter(([, v]) => v === 0).map(([k]) => k);
  if (zeroTargets.length) report.fatal = `ArkTS: ${zeroTargets.join(',')} 映射到 0（与不支持哨兵撞车）`;

  report.ok = !report.fatal
    && report.onlyInArkTs.length === 0
    && report.onlyInCpp.length === 0
    && report.valueMismatch.length === 0
    && report.arkTsKeys > 0;
  return report;
}

export function readSources(root = ROOT) {
  return {
    ohosKeyCodesText: fs.readFileSync(path.join(root, SOURCES.ohosKeyCodes), 'utf8'),
    glfwKeysText: fs.readFileSync(path.join(root, SOURCES.glfwKeys), 'utf8'),
    keyMapText: fs.readFileSync(path.join(root, SOURCES.keyMap), 'utf8'),
    adapterText: fs.readFileSync(path.join(root, SOURCES.adapter), 'utf8'),
  };
}

function main() {
  const asJson = process.argv.includes('--json');
  const report = analyze(readSources());
  if (asJson) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } else if (report.fatal) {
    console.error(`FATAL ${report.fatal}`);
  } else if (report.ok) {
    console.log(`OK keymap parity: ${report.arkTsKeys} keys identical on both planes`);
  } else {
    for (const d of report.valueMismatch) {
      console.error(`MISMATCH ohos=${d.ohos} arkTs=${d.arkTs} cpp=${d.cpp}`);
    }
    for (const d of report.onlyInArkTs) console.error(`ONLY-ARKTS ohos=${d.ohos} -> ${d.glfw}`);
    for (const d of report.onlyInCpp) console.error(`ONLY-CPP   ohos=${d.ohos} -> ${d.glfw}`);
  }
  process.exit(report.ok ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url))) {
  main();
}

#!/usr/bin/env node
// scripts/check-typed-sink-wiring.mjs
//
// ============================ 它挡的是什么 ============================
//
// **typed 生产者活着、消费端没接线**，而两侧都不会有任何提示。
//
// `GlfwInputSink` 是一张**普通函数表**（刻意的：不让 C++ 闭包跨将来的动态库接缝）。
// 没赋值的字段就是 `nullptr`，而 adapter 对 `nullptr` sink 的处理是**静默跳过** ——
// 那是对的（一个陌生能力不该拆掉不相关的持有态），但代价是"忘了接一根线"与"刻意不接
// 这根线"在代码里长得**完全一样**。
//
// 2026-09-01 desktop API26 批次已经把 GLFW 的 capture，以及 pull 后端的 focus/capture
// 接通；这里的腐烂检查会确保旧例外在接线落地后不能继续伪装成现状。
//
// ⇒ 判据：**新增一个 typed 事件种类时，必须显式回答"谁消费它"，`nullptr` 不是答案。**
//
// ============================ 它不能证明什么 ============================
//
// ❌ **不判定 sink 实现得对不对**，只判定"这根线接了 / 或被声明为刻意不接"。
// ❌ **不覆盖 ring 失明**（计划 §96.3：typed 边沿不进 legacy ring ⇒ SDL3/LWJGL2 两个
//    现成读序列结构性收不到物理键/按钮/滚轮）。那件事要跨 TU 调用图可达性，本仓至今
//    没有符号级可达性分析（提案第 8 批盲区 2），文本手段答不了。**这道门禁刻意只做
//    那件事里可机械化的一小块**，不要把它读成"§96.3 已解决"。
// ❌ 不检查 core → adapter 那一段；这里只看 sink 表本身。DEVICE_CHANGED 现在既在
//    adapter 内部清 owner，也按“release 后 device”顺序进入可选 device sink。
// ❌ 不检查 `GlfwInputMapper`（那张表只有三个字段，且缺任一个都会立刻功能全死）。
//
// ============================ 2026-08-24：从一个装配点扩到两个 ============================
//
// 本门禁最初只看 `typedInputSink()`。同一天新增的 `backend_input_bridge.cpp` 的 `SinkFor()`
// 是第二个装配点，而**本门禁看不见它** —— 而那次真正的缺陷（滚轮量纲从未换过，计划 §102.1）
// 恰好就在第二个装配点里。⇒ 判据：**一道门禁的覆盖边界写在注释里不等于它不会咬人；
// 边界本身要随被检查对象的数量一起长。**
//
// 扩容的形状是 `SITES`：**每个装配点各一张例外清单**。此前拒绝扩容的理由是"只有一张全局
// 清单、两条会互相污染"，那个理由成立 —— 所以解法是把清单按站点分开，而不是放宽判据。
// ⇒ 附带买到一件事：`SinkFor()` 那 8 条不接的理由从一句注释（且注释里的数还是错的：
// 写"四条"而实际 8 个字段）变成了**按字段逐条声明**，腐烂检测对两个站点同时生效。

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

export const SOURCES = {
  header: 'entry/src/main/cpp/input/adapters/glfw_input_adapter.h',
  wiring: 'entry/src/main/cpp/glfw/glfw_compat.cpp',
  bridge: 'entry/src/main/cpp/input/adapters/backend_input_bridge.cpp',
};

// 装配点表。**每个站点各一张例外清单** —— 合成一张会让两个站点的理由互相污染
// （每个后端对 absolute/enter/surface 的理由仍各自独立）。
//
// 刻意不接的字段：每条都要写清"为什么"与"翻开它的条件"。
// ⚠️ 往任一张清单里加一行是一个**决定**，不是一次修复 —— 加之前先回答：那个事件的生产者
// 是活的吗？它被丢掉之后，有没有别的机制兜住它想表达的语义？
export const SITES = {
  typedInputSink: {
    source: 'wiring',
    marker: 'GlfwInputSink typedInputSink()',
    what: 'GLFW3 后端（libglfw 运行期状态）',
    unwired: {
      device: {
        reason: 'GLFW3 公共输入 ABI 没有 mouse added/removed 或 MouseID；adapter 已在'
          + ' DEVICE_REMOVED 上按 deviceId 清理 held owner，继续调用 GLFW sink 无语义可落。',
        unblockedBy: 'GLFW 公共 ABI 增加可表达的物理指针设备生命周期。',
        coveredMeanwhileBy: 'GlfwInputAdapter::ClearDeviceLocked；SDL3 pull 通道的 DeviceSink。',
      },
    },
  },
  SinkFor: {
    source: 'bridge',
    // ⚠️ 匿名 namespace 内 + 文件顶部有 `using amcl::input::GlfwInputSink;` ⇒ 签名文本
    // 不带命名空间前缀。定义在唯一调用点之前，所以 indexOf 命中的是定义。
    marker: 'GlfwInputSink SinkFor(',
    what: 'LWJGL2 / SDL3 两个后端共用的 pull 通道',
    unwired: {
      absolute: {
        reason: '菜单光标由宿主的 grab 状态与 look 漏斗提供，两个后端读的是 '
          + 'inputBridge_getCursorSnapshot；从这里再送一份会出现两个真相源。',
        unblockedBy: '把光标真相源收敛成一个（宿主漏斗退役，或后端改读本通道）。',
        coveredMeanwhileBy: 'inputBridge_getCursorSnapshot（两个后端现用的那条）。',
      },
      enter: {
        reason: '进入/离开窗口不是 focus：两个后端没有独立 enter 消费语义。',
        unblockedBy: '后端长出独立 cursor-enter 状态消费者。',
        coveredMeanwhileBy: '无（该语义当前对两个后端都不产生行为）。',
      },
      surface: {
        reason: '只有 typed 绝对路由需要 surface 几何，而本通道结构上不带绝对坐标'
          + '（absolute 也没接）⇒ 接上它会得到一个没有消费者的字段。',
        unblockedBy: 'absolute 接上的那一天（两者是一对，surface 是它的授权前提）。',
        coveredMeanwhileBy: '不适用 —— 本通道没有需要 surface 校验的事件。',
      },
      unsupportedMapping: {
        reason: '它是**诊断**而不是输入。接进一条事件队列会让"未映射键"在消费者看来'
          + '像一个输入事件，而消费者没有区分手段。',
        unblockedBy: '本通道长出一条与输入分开的诊断出口（当前 ABI 只有一种事件流）。',
        coveredMeanwhileBy: 'GLFW 那条已接（typedUnsupportedMappingSink），'
          + '同一份 core 事件在那里被计数 ⇒ 未映射键在全局仍然可观测。',
      },
      diagnosticDrop: {
        reason: '同 unsupportedMapping：诊断不得混进输入流。',
        unblockedBy: '同上。',
        coveredMeanwhileBy: 'GLFW 那条已接（typedDiagnosticDropSink）。',
      },
    },
  },
};

class WiringError extends Error {}

/** 取 `openIndex` 处 `{` 配对的 `}`。 */
function bracedBody(text, openIndex, what) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    else if (text[i] === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(openIndex + 1, i);
    }
  }
  throw new WiringError(`${what}: 花括号不配对`);
}

function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

/** `struct GlfwInputSink { ... }` 里的函数指针字段名（`context` 不算 sink）。 */
export function parseSinkFields(headerText) {
  // ⚠️ 锚点必须精确到 `{`：`indexOf('struct GlfwInputSink')` 是**前缀匹配**，
  // 改名成 `GlfwInputSinkV2` 照样命中 ⇒ 门禁会去解析一个错的结构然后报全绿。
  // 这一条是自测第 7 例抓出来的（它当时是唯一失败的用例）。
  const anchor = /struct\s+GlfwInputSink\s*\{/.exec(headerText);
  if (!anchor) throw new WiringError('找不到 struct GlfwInputSink { —— 结构改名了？');
  const at = anchor.index;
  const body = stripComments(bracedBody(headerText, headerText.indexOf('{', at), 'GlfwInputSink'));
  const fields = [];
  const re = /(\w+)\s+(\w+)\s*=\s*nullptr\s*;/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    const [, type, name] = m;
    if (name === 'context') continue;
    // sink 字段一律是 `Glfw*SinkFn` 形状；别的类型出现说明结构长出了新东西，硬失败。
    if (!/^Glfw\w*SinkFn$/.test(type)) {
      throw new WiringError(`GlfwInputSink 里有未预期的字段类型: ${type} ${name}`);
    }
    fields.push(name);
  }
  if (fields.length === 0) throw new WiringError('GlfwInputSink 没解析出任何 sink 字段');
  return fields;
}

/** 某个装配点里 `sink.<field> = ...` 的赋值集合。 */
export function parseWiredFields(text, marker = SITES.typedInputSink.marker, label = null) {
  const what = label ?? marker;
  const at = text.indexOf(marker);
  if (at < 0) throw new WiringError(`找不到 ${marker} —— 装配函数改名了？`);
  const body = stripComments(bracedBody(text, text.indexOf('{', at), what));
  const wired = new Set();
  const re = /\bsink\.(\w+)\s*=\s*([A-Za-z_]\w*)/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    // 赋 nullptr 不算接线：那与不写这一行等价，而"看起来接了"更糟。
    if (m[2] === 'nullptr') continue;
    // `context` 不是 sink 字段（`SinkFor` 会赋它），门禁按字段表过滤即可，这里先收。
    wired.add(m[1]);
  }
  if (wired.size === 0) throw new WiringError(`${what} 里没解析出任何 sink 赋值`);
  return wired;
}

export function analyze({ headerText, wiringText, bridgeText }) {
  const report = {
    ok: false, sinkFields: 0, wired: 0, declaredUnwired: 0, slots: 0,
    sites: [], missing: [], staleAllowlist: [], fatal: null,
  };
  const texts = { wiring: wiringText, bridge: bridgeText };
  let fields;
  const perSite = [];
  try {
    fields = parseSinkFields(headerText);
    for (const [id, site] of Object.entries(SITES)) {
      const text = texts[site.source];
      // ⚠️ 源文件缺失必须 fatal 而不是当成"这个站点没有缺失"—— 那正是本门禁要挡的
      // "沉默即通过"。
      if (typeof text !== 'string') {
        throw new WiringError(`装配点 ${id} 的源文件（SOURCES.${site.source}）没读到`);
      }
      perSite.push([id, site, parseWiredFields(text, site.marker, id)]);
    }
  } catch (e) {
    if (e instanceof WiringError) { report.fatal = e.message; return report; }
    throw e;
  }

  report.sinkFields = fields.length;
  // 每个站点 × 每个字段 = 一个必须被回答的槽位。聚合数字按槽位算，否则"11/12"这种读法
  // 在两个站点下会变成一句没有含义的话。
  report.slots = fields.length * perSite.length;

  for (const [id, site, wired] of perSite) {
    const unwired = site.unwired ?? {};
    const entry = {
      id, what: site.what, wired: 0, declaredUnwired: Object.keys(unwired).length,
      missing: [], staleAllowlist: [],
    };
    entry.wired = [...wired].filter((f) => fields.includes(f)).length;

    for (const f of fields) {
      if (wired.has(f)) continue;
      if (Object.prototype.hasOwnProperty.call(unwired, f)) continue;
      entry.missing.push(f);
      report.missing.push(`${id}.${f}`);
    }
    // 清单腐烂同样要红：某条例外已经接上了，那条理由就成了假话（本仓最贵的那一族）。
    for (const f of Object.keys(unwired)) {
      if (!fields.includes(f)) {
        entry.staleAllowlist.push({ field: f, why: 'GlfwInputSink 里已经没有这个字段' });
      } else if (wired.has(f)) {
        entry.staleAllowlist.push({ field: f, why: '已经接线了，应从清单移除' });
      }
    }
    // 赋值了但结构里没有 —— 只可能是我这份解析漏了字段，宁可红。
    // `context` 例外：它是 sink 表里的一个真实成员，但不是 sink 字段（`SinkFor` 要赋它）。
    for (const f of wired) {
      if (f === 'context') continue;
      if (!fields.includes(f)) {
        entry.staleAllowlist.push({ field: f, why: `${id} 赋了值但结构里没有该字段` });
      }
    }
    for (const s of entry.staleAllowlist) {
      report.staleAllowlist.push({ field: `${id}.${s.field}`, why: s.why });
    }
    report.wired += entry.wired;
    report.declaredUnwired += entry.declaredUnwired;
    report.sites.push(entry);
  }

  report.ok = !report.fatal && report.missing.length === 0
    && report.staleAllowlist.length === 0 && report.sinkFields > 0
    && report.sites.length === Object.keys(SITES).length;
  return report;
}

export function readSources(root = ROOT) {
  return {
    headerText: fs.readFileSync(path.join(root, SOURCES.header), 'utf8'),
    wiringText: fs.readFileSync(path.join(root, SOURCES.wiring), 'utf8'),
    bridgeText: fs.readFileSync(path.join(root, SOURCES.bridge), 'utf8'),
  };
}

function main() {
  const report = analyze(readSources());
  if (process.argv.includes('--json')) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } else if (report.fatal) {
    console.error(`FATAL ${report.fatal}`);
  } else if (report.ok) {
    console.log(`OK typed sink wiring: ${report.wired}/${report.slots} slots wired across `
      + `${report.sites.length} assembly point(s), ${report.declaredUnwired} declared-unwired`);
    for (const s of report.sites) {
      console.log(`  ${s.id}: ${s.wired} wired / ${s.declaredUnwired} declared-unwired`
        + ` of ${report.sinkFields}  (${s.what})`);
    }
  } else {
    for (const f of report.missing) {
      console.error(`UNWIRED sink.${f} —— 接上它，或在 SITES.<站点>.unwired 里写明理由`);
    }
    for (const s of report.staleAllowlist) console.error(`STALE ${s.field}: ${s.why}`);
  }
  process.exit(report.ok ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url))) {
  main();
}

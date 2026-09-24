#!/usr/bin/env node
// scripts/check-log-channels.mjs
//
// 日志系统重构 · P3「通道注册表」门禁。
//
// 管一件事：**通道必须是被登记的，不能是 fopen 出来的。**
//
// 背景（施工记录 §S03.2）：2026-09-06 真机实测数出 10 条日志通道，
// 而 2026-09-05 那份**专门做全链路普查**的调研报告只列了 6 条 —— 漏了
// agent-probe.log、logs/ai/、mg-render-probe/、账本目录。
// 连专门数的人都会漏 4 条 ⇒ 靠人普查不是解法，得让它在提交前就红。
//
// 漏登记的代价是实的：MG/latest.log 存在很久，但任何读取 / 导出 / 清理路径都不碰它。
//
// ─────────────────────────── 检测器的诚实边界 ───────────────────────────
// `fopen` 在本仓大量用于**非日志**用途（jvm.options、fml.toml、/proc/meminfo、
// class 文件、marker、benchmark cache）。所以本门禁**不**拦所有 fopen，
// 只拦「路径表达式看起来是日志」的那些 —— 判据见 LOGISH。
//
// ⚠️ 这类判据最容易写成恒真（什么都没匹配到 ⇒ 0 个违规 ⇒ 通过）。
// 所以有一条**阳性对照**（AGENTS §二.8：判定工具本身要先在已知含有它的样本上验证过）：
// 检测器必须在已知的 sink 创建点上真的命中，命中数为 0 一律**硬失败**。
//
// 用法：
//   node scripts/check-log-channels.mjs
//   node scripts/test-check-log-channels.mjs

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const REGISTRY_PATH = 'config/log-channels.json';

/** 只扫第一方模块根（与 audit-logging.mjs 同一口径）。 */
const SOURCE_ROOTS = [
  'account', 'commons', 'entry', 'feature_core', 'feature_system',
  'gamecontrol', 'launch', 'mods', 'update', 'JavaApp',
];
const SKIP_DIRS = new Set([
  'build', '.hvigor', '.cxx', 'oh_modules', 'node_modules',
  'test', '.test', 'ohosTest', 'mock', '.preview', 'tests',
]);

/** 创建/打开文件的调用。三种语言各一组。 */
const SINK_CALL_RE =
  /\b(?:fopen|freopen)\s*\(|\bopen\s*\([^;]*O_CREAT|\bnew\s+(?:FileOutputStream|FileWriter|PrintStream)\s*\(|\bfileIo\.(?:open|createStream)\s*\(|\bfs\.(?:open|createStream)Sync?\s*\(/;

/**
 * 「这个落点是日志」的判据。刻意保守：宁可漏掉一个可疑写法，
 * 也不要把整仓的 fopen 都拖进来 —— 那样门禁会被噪声淹掉然后被摘掉，
 * 这正是 audit-logging 这条门禁存在三个月却没人接的死法。
 */
const LOGISH = /\.log\b|logs\/|logPath|logFile|logDir|stderrFile|LOG_NAME|latest\.log|_log\b/i;

/** 行内出现这些就不算日志 sink：读取模式、探测、注释掉的例子。 */
const NOT_A_SINK = /"r"|'r'|"rb"|'rb'|\/proc\/|\/sys\/|^\s*(?:\/\/|\*|#)/;

function relPath(abs) {
  return path.relative(ROOT, abs).replace(/\\/g, '/');
}

function walk(dir, exts, out) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const ent of ents) {
    if (ent.isDirectory()) {
      if (SKIP_DIRS.has(ent.name)) continue;
      walk(path.join(dir, ent.name), exts, out);
    } else if (ent.isFile() && exts.some((e) => ent.name.endsWith(e))) {
      out.push(path.join(dir, ent.name));
    }
  }
}

export function collectFiles() {
  const out = [];
  for (const root of SOURCE_ROOTS) {
    const abs = path.join(ROOT, root);
    if (!fs.existsSync(abs)) continue;
    walk(abs, ['.ets', '.cpp', '.h', '.hpp', '.c', '.cc', '.java'], out);
  }
  return out;
}

/** 调用的第一个实参若是个标识符，把它取出来（用于回看它是在哪儿被赋值的）。 */
const FIRST_ARG_IDENT =
  /(?:fopen|freopen|open|createStream|FileOutputStream|FileWriter|PrintStream)\s*\(\s*([A-Za-z_]\w*)\s*[,)]/;

/** 回看几行找变量赋值。3 行是权衡：够覆盖 `let p = …; open(p)`，又不至于跨到别的逻辑块。 */
const LOOKBACK_LINES = 3;

/**
 * 找出一个文件里所有「疑似创建日志 sink」的行。
 *
 * ⚠️ **这是行局部的判据，不是数据流分析。** 两步：
 *   1. 本行既有创建调用、又提到日志路径 ⇒ 命中；
 *   2. 本行只有创建调用，则取第一个实参的标识符，回看 3 行 —— 若它在那几行里
 *      被赋成一个日志路径，也算命中（`let p = dir + '/logs/x.log'; open(p)` 这种）。
 *
 * 仍然抓不到的形状：路径来自函数返回值、来自更远的赋值、或跨函数传参。
 * 这一条写在这里是因为**门禁的边界必须可读** —— 下一个人应当知道它保证了什么、
 * 没保证什么，而不是以为它是完备的。兜底靠 analyze() 里的阳性对照。
 */
export function findSinkSites(text, rel) {
  const hits = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (NOT_A_SINK.test(line)) continue;
    if (!SINK_CALL_RE.test(line)) continue;

    let logish = LOGISH.test(line);
    if (!logish) {
      const m = FIRST_ARG_IDENT.exec(line);
      if (m) {
        const ident = m[1];
        const assignRe = new RegExp(`\\b${ident}\\b\\s*(?::[^=]*)?=`);
        for (let k = Math.max(0, i - LOOKBACK_LINES); k < i; k++) {
          if (assignRe.test(lines[k]) && LOGISH.test(lines[k]) && !NOT_A_SINK.test(lines[k])) {
            logish = true;
            break;
          }
        }
      }
    }
    if (!logish) continue;
    hits.push({ rel, line: i + 1, text: line.trim().slice(0, 120) });
  }
  return hits;
}

export function readSources() {
  const files = collectFiles();
  const texts = new Map();
  for (const f of files) texts.set(relPath(f), fs.readFileSync(f, 'utf8'));
  return {
    registryText: fs.readFileSync(path.join(ROOT, REGISTRY_PATH), 'utf8'),
    texts,
  };
}

export function analyze(sources) {
  const result = { ok: false, fatal: null, channels: 0, sites: 0, schema: [], unregistered: [], positiveControl: [] };

  let doc;
  try {
    doc = JSON.parse(sources.registryText);
  } catch (e) {
    result.fatal = `${REGISTRY_PATH} 不是合法 JSON：${e.message}`;
    return result;
  }
  if (!Array.isArray(doc.channels) || doc.channels.length === 0) {
    result.fatal = `${REGISTRY_PATH} 里没解析出任何通道`;
    return result;
  }
  result.channels = doc.channels.length;

  // — schema
  const ids = new Set();
  const writerToChannel = new Map();
  for (const c of doc.channels) {
    if (!c.id) { result.schema.push('有通道缺 id'); continue; }
    if (ids.has(c.id)) result.schema.push(`id 重复：${c.id}`);
    ids.add(c.id);
    if (!c.path) result.schema.push(`${c.id}: 缺 path`);
    if (!c.producer) result.schema.push(`${c.id}: 缺 producer —— 写不出「谁产生这些行」就不该登记`);
    if (typeof c.thirdParty !== 'boolean') result.schema.push(`${c.id}: thirdParty 必须是布尔`);
    if (!Array.isArray(c.writers)) { result.schema.push(`${c.id}: writers 必须是数组`); continue; }
    // testOnly = 写入方在 tests/ 下（只有诊断构建才编进去），不在本门禁扫描面内。
    // 单列一个标志而不是放宽规则：否则「第一方却没人写」这条判据会被悄悄架空。
    if (!c.thirdParty && !c.testOnly && c.writers.length === 0) {
      result.schema.push(`${c.id}: 声明是第一方却没有 writers —— 那它到底谁写的？`);
    }
    if (!c.export || typeof c.export.diagnosticBundle !== 'boolean') {
      result.schema.push(`${c.id}: 缺 export.diagnosticBundle`);
    }
    if (!('retention' in c)) result.schema.push(`${c.id}: 缺 retention（没有策略就显式写 null 并在 gap 里说明）`);
    if (!('gap' in c)) result.schema.push(`${c.id}: 缺 gap 字段（没有缺口就写 null）`);
    for (const w of c.writers) {
      if (!sources.texts.has(w)) {
        result.schema.push(`${c.id}: writer 指向不存在的文件 ${w}`);
        continue;
      }
      if (!writerToChannel.has(w)) writerToChannel.set(w, []);
      writerToChannel.get(w).push(c.id);
    }
  }

  // — 扫描：任何疑似日志 sink 创建点，其文件必须是某条通道声明的 writer
  const allSites = [];
  for (const [rel, text] of sources.texts) {
    const hits = findSinkSites(text, rel);
    for (const h of hits) {
      allSites.push(h);
      if (!writerToChannel.has(rel)) result.unregistered.push(h);
    }
  }
  result.sites = allSites.length;

  // — 阳性对照：检测器必须在已知 sink 上真的命中。
  //   命中数为 0 说明检测器坏了（正则失效 / 作用域改窄），那是**静默恒绿**，
  //   比有违规更危险。
  const MUST_HIT = [
    'entry/src/main/cpp/utils/amcl_log.cpp',
    'entry/src/main/cpp/jvm/mc_launcher.cpp',
  ];
  for (const m of MUST_HIT) {
    const n = allSites.filter((s) => s.rel === m).length;
    if (n === 0) {
      result.positiveControl.push(`检测器在已知 sink 文件 ${m} 上一个都没命中 —— 判据失效了`);
    }
  }
  if (allSites.length === 0) {
    result.positiveControl.push('全仓一个 sink 创建点都没扫到 —— 检测器必然是坏的');
  }

  result.ok = result.schema.length === 0
    && result.unregistered.length === 0
    && result.positiveControl.length === 0;
  return result;
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url));

if (isMain) {
  const r = analyze(readSources());
  if (r.fatal) {
    console.error(`❌ check-log-channels: ${r.fatal}`);
    process.exit(1);
  }
  const dump = (label, arr, fmt) => {
    if (arr.length === 0) return;
    console.error(`\n--- ${label}（${arr.length}）---`);
    for (const x of arr) console.error(`  ${fmt ? fmt(x) : x}`);
  };
  dump('注册表 schema', r.schema);
  dump('检测器阳性对照', r.positiveControl);
  dump('未登记的日志落点', r.unregistered,
    (x) => `${x.rel}:${x.line}\n      ${x.text}\n      ⇒ 要么把它登记进 ${REGISTRY_PATH} 的某条通道的 writers，要么它不该写日志文件`);

  if (r.ok) {
    console.log(`✅ check-log-channels: ${r.channels} 条通道已登记，${r.sites} 个 sink 创建点全部有归属`);
    process.exit(0);
  }
  console.error(`\n❌ check-log-channels 未通过`);
  process.exit(1);
}

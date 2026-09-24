#!/usr/bin/env node
// scripts/check-log-noise-rules.mjs
//
// 日志系统重构 · 批次 A 的门禁。管三件事：
//
//   1. **镜像一致**：`config/log-noise-rules.json`（事实源）与
//      `commons/src/main/ets/utils/LogNoiseFilter.ets` 的 NOISE_RULES（运行时镜像）
//      逐字段相等，顺序也相等。
//   2. **规则质量**：id 唯一、needle 全小写且足够长、reason / evidence 非空。
//      过宽的 needle 会吃掉别人的真实错误，而那种误杀在日志里是**看不见的**。
//   3. **语料回归**：在 scripts/fixtures/log-noise/cases.json 上跑正反两向。
//      正向 = 调研 §6.3 那批「剥完仍被判成错误、但一行都不是错误」的行；
//      反向 = 真实的启动失败必须**仍然**被判成有错误信号。
//
// ⚠️ 关于「等价模型」的诚实说明（AGENTS §二.4：源码级门禁全绿 ≠ 修复在出货链上）：
//   本脚本在 Node 里复现的只有**控制流**（逐行、剥离、判定）。所有**判据字面量**
//   —— 噪声 needle、错误级别标记、Java 异常顶行正则、崩溃标记 —— 都是从 .ets 源码里
//   **抽出来直接用**的，不是在这里另写一份。所以「判据改了但门禁没跟上」这种漂移
//   不可能发生；能漂移的只剩控制流，而控制流由 §4 的结构断言钉住。
//   真正的运行时行为仍然要靠 ArkTS 单测（LogErrorSignal.test.ets，设备上跑）。
//
// 用法：
//   node scripts/check-log-noise-rules.mjs
//   node scripts/test-check-log-noise-rules.mjs   # 自测：制造分叉，要求本门禁真的红

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), '..');

const JSON_PATH = 'config/log-noise-rules.json';
const NOISE_ETS_PATH = 'commons/src/main/ets/utils/LogNoiseFilter.ets';
const SIGNAL_ETS_PATH = 'commons/src/main/ets/utils/LogErrorSignal.ets';
const CASES_PATH = 'scripts/fixtures/log-noise/cases.json';

/** needle 短于这个长度几乎必然过宽。'libflite' 是 8，当前最短的合法值。 */
const MIN_NEEDLE_LEN = 8;

export function readSources() {
  const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');
  return {
    jsonText: read(JSON_PATH),
    noiseEtsText: read(NOISE_ETS_PATH),
    signalEtsText: read(SIGNAL_ETS_PATH),
    casesText: read(CASES_PATH),
  };
}

// ============================================================
//  1. 从 .ets 源码里抽出判据字面量
// ============================================================

/** 抽 `const NAME: string[] = ['a', 'b'];` 里的数组。 */
function extractStringArray(text, name) {
  const re = new RegExp(`const\\s+${name}\\s*:\\s*string\\[\\]\\s*=\\s*\\[([\\s\\S]*?)\\]\\s*;`);
  const m = re.exec(text);
  if (!m) return null;
  const out = [];
  const itemRe = /'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"/g;
  let it;
  while ((it = itemRe.exec(m[1])) !== null) {
    out.push(it[1] !== undefined ? it[1] : it[2]);
  }
  return out;
}

/** 抽 `const NAME =\n  /regex/flags;` 并在 Node 里重建成同一个 RegExp。 */
function extractRegex(text, name) {
  const re = new RegExp(`const\\s+${name}\\s*=\\s*\\r?\\n?\\s*/(.+?)/([gimsuy]*)\\s*;`);
  const m = re.exec(text);
  if (!m) return null;
  try {
    return new RegExp(m[1], m[2]);
  } catch {
    return null;
  }
}

/** 抽 LogNoiseFilter.ets 的 NOISE_RULES 数组。 */
function extractNoiseRulesFromEts(text) {
  const start = text.indexOf('const NOISE_RULES: LogNoiseRule[] = [');
  if (start < 0) return null;
  const end = text.indexOf('\n];', start);
  if (end < 0) return null;
  const body = text.slice(start, end);

  const rules = [];
  // 每条规则是一个 `{ ... }` 块；块内的注释可能含 `{`，所以按 `id:` 锚点切。
  const blockRe = /\{[\s\S]*?\n\s*\}/g;
  let b;
  while ((b = blockRe.exec(body)) !== null) {
    const block = b[0];
    const id = /\bid:\s*'([^']+)'/.exec(block);
    const needle = /\bneedle:\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")/.exec(block);
    const dropStack = /\bdropStack:\s*(true|false)/.exec(block);
    if (!id || !needle || !dropStack) continue;
    rules.push({
      id: id[1],
      needle: needle[1] !== undefined ? needle[1] : needle[2],
      dropStack: dropStack[1] === 'true',
    });
  }
  return rules;
}

// ============================================================
//  2. 等价模型：控制流在这里，判据全部来自上面抽出来的字面量
// ============================================================

function isStackContinuation(line) {
  const t = line.trim();
  if (t.length === 0) return false;
  if (t.indexOf('at ') === 0) return true;
  if (t.indexOf('... ') === 0 && t.indexOf('more') > 0) return true;
  if (t.indexOf('Caused by:') === 0) return true;
  if (t.indexOf('Suppressed:') === 0) return true;
  return false;
}

function stripLogNoise(text, rules) {
  const lines = text.split('\n');
  const kept = [];
  let skippingStack = false;
  for (const line of lines) {
    if (skippingStack && isStackContinuation(line)) continue;
    skippingStack = false;
    const low = line.toLowerCase();
    const hit = rules.find((r) => low.indexOf(r.needle) >= 0);
    if (hit) {
      if (hit.dropStack) skippingStack = true;
      continue;
    }
    kept.push(line);
  }
  return kept.join('\n');
}

function makeSignalModel(sig) {
  const lineHasErrorLevelMarker = (line) => {
    const low = line.toLowerCase();
    return sig.errorLevelMarkers.some((m) => low.indexOf(m) >= 0);
  };
  const lineIsCrashMarker = (line) => {
    const low = line.toLowerCase();
    return sig.crashMarkers.some((m) => low.indexOf(m) >= 0);
  };
  const lineIsJavaThrowableTopLine = (line) => {
    const t = line.trim();
    if (t.length === 0) return false;
    if (sig.bareErrorPrefix.test(t)) return true;
    return sig.javaThrowableTopLine.test(t);
  };
  const lineLooksLikeError = (line) =>
    lineHasErrorLevelMarker(line) || lineIsCrashMarker(line) || lineIsJavaThrowableTopLine(line);
  const hasErrorSignal = (text) => {
    if (!text || text.length === 0) return false;
    return text.split('\n').some(lineLooksLikeError);
  };
  return { lineLooksLikeError, hasErrorSignal };
}

// ============================================================
//  3. 分析
// ============================================================

export function analyze(sources) {
  const result = {
    ok: false,
    fatal: null,
    ruleCount: 0,
    caseCount: 0,
    schema: [],
    mirror: [],
    fixtures: [],
    structure: [],
  };

  // — 解析。任何一步解析不出来一律**硬失败**，不许退化成「0 个分歧 ⇒ 通过」。
  let doc, cases;
  try {
    doc = JSON.parse(sources.jsonText);
  } catch (e) {
    result.fatal = `${JSON_PATH} 不是合法 JSON：${e.message}`;
    return result;
  }
  try {
    cases = JSON.parse(sources.casesText);
  } catch (e) {
    result.fatal = `${CASES_PATH} 不是合法 JSON：${e.message}`;
    return result;
  }
  if (!Array.isArray(doc.rules) || doc.rules.length === 0) {
    result.fatal = `${JSON_PATH} 里没解析出任何规则`;
    return result;
  }
  if (!Array.isArray(cases.cases) || cases.cases.length === 0) {
    result.fatal = `${CASES_PATH} 里没解析出任何用例`;
    return result;
  }

  const etsRules = extractNoiseRulesFromEts(sources.noiseEtsText);
  if (!etsRules || etsRules.length === 0) {
    result.fatal = `${NOISE_ETS_PATH} 里没解析出 NOISE_RULES（写法变了？解析器必须跟着改，不能静默放行）`;
    return result;
  }

  const sig = {
    errorLevelMarkers: extractStringArray(sources.signalEtsText, 'ERROR_LEVEL_MARKERS'),
    crashMarkers: extractStringArray(sources.signalEtsText, 'CRASH_MARKERS'),
    javaThrowableTopLine: extractRegex(sources.signalEtsText, 'JAVA_THROWABLE_TOP_LINE'),
    bareErrorPrefix: extractRegex(sources.signalEtsText, 'BARE_ERROR_PREFIX'),
  };
  for (const [k, v] of Object.entries(sig)) {
    if (!v || (Array.isArray(v) && v.length === 0)) {
      result.fatal = `${SIGNAL_ETS_PATH} 里没解析出 ${k}（写法变了？）`;
      return result;
    }
  }

  result.ruleCount = doc.rules.length;
  result.caseCount = cases.cases.length;

  // — 规则质量
  const seen = new Set();
  for (const r of doc.rules) {
    if (seen.has(r.id)) result.schema.push(`id 重复：${r.id}`);
    seen.add(r.id);
    if (typeof r.needle !== 'string' || r.needle.length === 0) {
      result.schema.push(`${r.id}: needle 为空`);
      continue;
    }
    if (r.needle !== r.needle.toLowerCase()) {
      result.schema.push(`${r.id}: needle 必须全小写（匹配方先 toLowerCase）：${r.needle}`);
    }
    if (r.needle.length < MIN_NEEDLE_LEN) {
      result.schema.push(`${r.id}: needle 只有 ${r.needle.length} 字符，过宽的规则会静默吃掉真实错误：${r.needle}`);
    }
    if (typeof r.dropStack !== 'boolean') result.schema.push(`${r.id}: dropStack 必须是布尔`);
    if (!r.reason) result.schema.push(`${r.id}: reason 为空 —— 写不出「为什么它在能正常游玩的会话里也出现」就不该加这条`);
    if (!r.evidence) result.schema.push(`${r.id}: evidence 为空 —— 前提变了要能回来重标`);
  }

  // — 镜像一致
  if (etsRules.length !== doc.rules.length) {
    result.mirror.push(`条数不等：JSON ${doc.rules.length} vs ETS ${etsRules.length}`);
  }
  const n = Math.min(etsRules.length, doc.rules.length);
  for (let i = 0; i < n; i++) {
    const j = doc.rules[i];
    const e = etsRules[i];
    if (j.id !== e.id) result.mirror.push(`第 ${i + 1} 条 id 不等：JSON ${j.id} vs ETS ${e.id}`);
    else if (j.needle !== e.needle) result.mirror.push(`${j.id}: needle 不等：JSON ${JSON.stringify(j.needle)} vs ETS ${JSON.stringify(e.needle)}`);
    else if (j.dropStack !== e.dropStack) result.mirror.push(`${j.id}: dropStack 不等：JSON ${j.dropStack} vs ETS ${e.dropStack}`);
  }

  // — 结构断言：控制流没被换掉（等价模型只在控制流上可能漂移）
  const structureExpect = [
    [NOISE_ETS_PATH, sources.noiseEtsText, 'lowerLine.indexOf(rule.needle)', '噪声匹配仍是整行小写子串'],
    [NOISE_ETS_PATH, sources.noiseEtsText, 'if (rule.dropStack) skippingStack = true', 'dropStack 语义仍在'],
    [SIGNAL_ETS_PATH, sources.signalEtsText, 'export function hasErrorSignal', '错误信号入口仍在'],
    [SIGNAL_ETS_PATH, sources.signalEtsText, 'lineLooksLikeError(lines[i])', 'hasErrorSignal 仍是逐行判定'],
  ];
  for (const [file, text, needle, label] of structureExpect) {
    if (text.indexOf(needle) < 0) {
      result.structure.push(`${file}: 找不到「${label}」的写法（${needle}）—— 控制流变了，等价模型可能已经不等价`);
    }
  }

  // — 语料回归
  const model = makeSignalModel(sig);
  for (const c of cases.cases) {
    const text = Array.isArray(c.lines) ? c.lines.join('\n') : c.line;
    if (typeof text !== 'string') {
      result.fixtures.push(`${c.name}: 既没有 line 也没有 lines`);
      continue;
    }
    const stripped = stripLogNoise(text, doc.rules);
    const gotNoise = stripped.trim().length === 0;
    const gotSignal = model.hasErrorSignal(stripped);
    if (gotNoise !== c.expectNoise) {
      result.fixtures.push(`${c.name}: expectNoise=${c.expectNoise} 实际=${gotNoise}（${c.why}）`);
    }
    if (gotSignal !== c.expectErrorSignal) {
      result.fixtures.push(`${c.name}: expectErrorSignal=${c.expectErrorSignal} 实际=${gotSignal}（${c.why}）`);
    }
  }

  result.ok = result.schema.length === 0 && result.mirror.length === 0
    && result.fixtures.length === 0 && result.structure.length === 0;
  return result;
}

// ============================================================
//  4. CLI
// ============================================================

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url));

if (isMain) {
  const r = analyze(readSources());
  if (r.fatal) {
    console.error(`❌ check-log-noise-rules: ${r.fatal}`);
    process.exit(1);
  }
  const dump = (label, arr) => {
    if (arr.length === 0) return;
    console.error(`\n--- ${label}（${arr.length}）---`);
    for (const x of arr) console.error(`  ${x}`);
  };
  dump('规则质量', r.schema);
  dump('JSON ↔ ETS 镜像', r.mirror);
  dump('结构断言', r.structure);
  dump('语料回归', r.fixtures);

  if (r.ok) {
    console.log(`✅ check-log-noise-rules: ${r.ruleCount} 条规则镜像一致，${r.caseCount} 条语料全过`);
    process.exit(0);
  }
  console.error(`\n❌ check-log-noise-rules 未通过`);
  process.exit(1);
}
